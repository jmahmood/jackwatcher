#!/usr/bin/env bash
set -euo pipefail

# Defaults (overridable via flags or env)
HOST=""                                # e.g. root@10.0.0.159
PREFIX="${PREFIX:-/storage}"           # install root on the device
MUSIC_DIR="${MUSIC_DIR:-/storage/audio}"
TARGET=""                               # auto-detected from remote uname -m unless set
USE_SERVICE=0
DRY_RUN=0
SKIP_BUILD=0
MAKE_COMPAT_SYMLINK=1                  # create /storage/musicctl.sh -> $BIN_MC_REMOTE
BIN_JW_LOCAL="target/XXX/release/jack-watcher"  # resolved after target chosen
BIN_MC_LOCAL="scripts/musicctl.sh"               # your local musicctl
BIN_JW_REMOTE=""                        # computed from $PREFIX
BIN_MC_REMOTE=""
BIN_DIR=""
SSH_OPTS=${SSH_OPTS:-}

BIN_BW_LOCAL="" # we set these later.
BIN_BW_REMOTE=""

usage() {
  cat <<EOF
Usage: $0 --host <user@ip> [options]

Options:
  --host <user@ip>       SSH target (required)
  --prefix <dir>         Install prefix on device (default: ${PREFIX})
  --music-dir <dir>      Directory to scan for audio (default: ${MUSIC_DIR})
  --target <triple>      Rust target triple override (auto-detected otherwise)
  --service              Install & enable systemd service (best-effort)
  --dry-run              Print actions without executing
  --skip-build           Don't build (use existing local binaries)
  --ssh-opts "<opts>"    Extra SSH/SCP options (e.g., -i ~/.ssh/id_rsa -p 2222)
  --no-compat-symlink    Do not create /storage/musicctl.sh symlink
  --uninstall            Remove installed files and (if present) systemd unit
  -h, --help             Show this help
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
do_ssh() { [ "$DRY_RUN" -eq 1 ] && { echo "ssh $SSH_OPTS $HOST $*"; return; } ; ssh $SSH_OPTS "$HOST" "$@"; }
do_scp() { [ "$DRY_RUN" -eq 1 ] && { echo "scp $SSH_OPTS $1 $HOST:$2"; return; } ; scp $SSH_OPTS "$1" "$HOST:$2"; }

UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --prefix) PREFIX="$2"; shift 2;;
    --music-dir) MUSIC_DIR="$2"; shift 2;;
    --target) TARGET="$2"; shift 2;;
    --service) USE_SERVICE=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --skip-build) SKIP_BUILD=1; shift;;
    --ssh-opts) SSH_OPTS="$2"; shift 2;;
    --no-compat-symlink) MAKE_COMPAT_SYMLINK=0; shift;;
    --uninstall) UNINSTALL=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown arg: $1";;
  esac
done

[ -n "$HOST" ] || { usage; die "--host is required"; }

# Paths on device
BIN_DIR="$PREFIX/bin"
BIN_JW_REMOTE="$BIN_DIR/jack-watcher"
BIN_MC_REMOTE="$BIN_DIR/musicctl"
BIN_BW_REMOTE="$BIN_DIR/btn-watcher"
WRAPPER_REMOTE="$BIN_DIR/jack-watcher-run"
UNIT_PATH="/etc/systemd/system/jack-watcher.service"
COMPAT_SYMLINK="/storage/musicctl.sh"

if [ "$UNINSTALL" -eq 1 ]; then
  do_ssh "set -e
    systemctl stop jack-watcher 2>/dev/null || true
    systemctl disable jack-watcher 2>/dev/null || true
    rm -f '$UNIT_PATH' 2>/dev/null || true
    rm -f '$BIN_JW_REMOTE' '$BIN_MC_REMOTE' '$WRAPPER_REMOTE' 2>/dev/null || true
    [ -L '$COMPAT_SYMLINK' ] && rm -f '$COMPAT_SYMLINK' || true
    systemctl daemon-reload 2>/dev/null || true
    echo 'Uninstalled jack-watcher, musicctl, wrapper, and unit (if present).'
  "
  exit 0
fi

echo ">> Probing remote architecture…"
REMOTE_UNAME=$(do_ssh "uname -m")
echo "   remote uname -m: $REMOTE_UNAME"

if [ -z "$TARGET" ]; then
  case "$REMOTE_UNAME" in
    aarch64) TARGET="aarch64-unknown-linux-gnu" ;;
    armv7l)  TARGET="armv7-unknown-linux-gnueabihf" ;;
    armhf)   TARGET="arm-unknown-linux-gnueabihf" ;;
    *) die "Unsupported remote arch '$REMOTE_UNAME'. Use --target to override." ;;
  esac
fi
echo "   build target: $TARGET"

BIN_JW_LOCAL="target/$TARGET/release/jack-watcher"
BIN_BW_LOCAL="target/$TARGET/release/btn-watcher"


if [ "$SKIP_BUILD" -eq 0 ]; then
  echo ">> Building jack-watcher…"
  if command -v cross >/dev/null 2>&1; then
    CMD="cross build --release --target $TARGET"
  else
    rustup target add "$TARGET" >/dev/null 2>&1 || true
    CMD="cargo build --release --target $TARGET"
  fi
  echo "   $CMD"
  [ "$DRY_RUN" -eq 1 ] || eval "$CMD"
fi

[ -f "$BIN_JW_LOCAL" ] || die "Local binary not found: $BIN_JW_LOCAL (did build succeed?)"
[ -f "$BIN_MC_LOCAL" ] || die "Local controller script not found: $BIN_MC_LOCAL"

echo ">> Creating install dirs on device ($BIN_DIR)…"
do_ssh "mkdir -p '$BIN_DIR'"

echo ">> Stopping running watcher (if any)…"
do_ssh 'sh -c "
  set -e
  if command -v systemctl >/dev/null 2>&1; then
    # Don’t block on stop; kill first, then stop/reset.
    systemctl kill -s TERM jack-watcher 2>/dev/null || true
    sleep 0.2
    systemctl kill -s KILL jack-watcher 2>/dev/null || true
    systemctl stop jack-watcher 2>/dev/null || true
    systemctl reset-failed jack-watcher 2>/dev/null || true
  fi

  # Also kill any ad-hoc runs by **name** (no -f)
  pkill -x jack-watcher      2>/dev/null || true
  pkill -x btn-watcher       2>/dev/null || true
  pkill -x jack-watcher-run  2>/dev/null || true

"'

echo '>> Copying binaries atomically…'
tmp_jw="$BIN_JW_REMOTE.new.$$"
tmp_mc="$BIN_MC_REMOTE.new.$$"
tmp_bw="$BIN_BW_REMOTE.new.$$"

do_scp "$BIN_JW_LOCAL" "$tmp_jw"
do_scp "$BIN_MC_LOCAL" "$tmp_mc"
do_scp "$BIN_BW_LOCAL" "$tmp_bw"

do_ssh "set -e
  # Inject music dir and set modes on temp files
  if grep -qE '^DIR=' '$tmp_mc' 2>/dev/null; then
    sed -i -E 's|^DIR=.*$|DIR=\"$MUSIC_DIR\"|' '$tmp_mc'
  else
    printf '\nDIR=\"$MUSIC_DIR\"\n' >> '$tmp_mc'
  fi
  chmod 0755 '$tmp_jw' '$tmp_mc' '$tmp_bw'

  # Rotate into place atomically
  mv -f '$tmp_jw' '$BIN_JW_REMOTE'
  mv -f '$tmp_mc' '$BIN_MC_REMOTE'
  mv -f '$tmp_bw' '$BIN_BW_REMOTE'
"
do_ssh "chmod +x '$BIN_BW_REMOTE'"


echo ">> Finalizing install on device…"
do_ssh "set -e
  # Ensure controller uses the desired music dir
  if grep -qE '^DIR=' '$BIN_MC_REMOTE' 2>/dev/null; then
    sed -i -E 's|^DIR=.*$|DIR=\"$MUSIC_DIR\"|' '$BIN_MC_REMOTE'
  else
    printf '\nDIR=\"$MUSIC_DIR\"\n' >> '$BIN_MC_REMOTE'
  fi
  chmod +x '$BIN_JW_REMOTE' '$BIN_MC_REMOTE'

  # Create wrapper that pins JW_CMD to the installed controller
  cat > '$WRAPPER_REMOTE' <<WRAP
#!/bin/sh
export JW_CMD=\"$BIN_MC_REMOTE\"
exec \"$BIN_JW_REMOTE\" --watch --exec "\$@"
WRAP
  chmod +x '$WRAPPER_REMOTE'

  # Optional compatibility symlink for older builds that expect /storage/musicctl.sh
  if [ $MAKE_COMPAT_SYMLINK -eq 1 ]; then
    ln -sf '$BIN_MC_REMOTE' '$COMPAT_SYMLINK' 2>/dev/null || true
  fi
"

# Warn if no player present on the device
echo ">> Checking for available players on device…"
if ! do_ssh "command -v mpv >/dev/null 2>&1 || command -v mplayer >/dev/null 2>&1 || command -v mpg123 >/dev/null 2>&1 || command -v ffplay >/dev/null 2>&1"; then
  echo "   WARNING: No mpv/mplayer/mpg123/ffplay found on device; musicctl will print 'no player found'."
fi

if [ "$USE_SERVICE" -eq 1 ]; then
  echo ">> Installing service…"
  UNIT_DIR=$(do_ssh 'if command -v systemctl >/dev/null 2>&1; then
                       if [ -d /etc/systemd/system ] && [ -w /etc/systemd/system ]; then
                         echo /etc/systemd/system
                       else
                         echo /storage/.config/system.d
                       fi
                     else
                       echo NOSYSTEMD
                     fi')

  if [ "$UNIT_DIR" = "NOSYSTEMD" ]; then
    echo "   Systemd not found; skipping service. Use $WRAPPER_REMOTE in autostart."
  else
    echo "   Using unit dir: $UNIT_DIR"
    SERVICE_CONTENT="[Unit]
Description=Headphone jack watcher
After=multi-user.target

[Service]
Type=simple
Environment=JW_CMD=$BIN_MC_REMOTE
ExecStart=$BIN_JW_REMOTE --watch --exec
Restart=always

[Install]
WantedBy=multi-user.target
"
    do_ssh "mkdir -p '$UNIT_DIR'"
    do_ssh "bash -c 'cat >\"$UNIT_DIR/jack-watcher.service\" <<EOF
$SERVICE_CONTENT
EOF
systemctl daemon-reload || true
systemctl enable --now jack-watcher || true'"

    echo "   Verify: systemctl status jack-watcher"
  fi
fi


echo ">> Smoke test:"
do_ssh "$BIN_JW_REMOTE --list || true"

echo ">> Done.
- jack-watcher:     $BIN_JW_REMOTE
- musicctl:         $BIN_MC_REMOTE
- wrapper (run me): $WRAPPER_REMOTE
- music dir:        $MUSIC_DIR
$( [ $USE_SERVICE -eq 1 ] && echo '- systemd:          installed (if supported)' || echo '- systemd:          skipped' )
$( [ $MAKE_COMPAT_SYMLINK -eq 1 ] && echo '- compat symlink:   /storage/musicctl.sh -> musicctl' || echo '- compat symlink:   disabled' )
"
