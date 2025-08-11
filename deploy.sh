#!/usr/bin/env bash
set -euo pipefail

# Defaults (overridable via flags or env)
HOST=""                       # e.g. root@10.0.0.159
PREFIX="${PREFIX:-/storage}"  # install root on the device
MUSIC_DIR="${MUSIC_DIR:-/storage/audio}"
TARGET=""                     # auto-detected from remote uname -m unless set
USE_SERVICE=0
DRY_RUN=0
SKIP_BUILD=0
BIN_JW_LOCAL="target/XXX/release/jack-watcher"  # resolved after target chosen
BIN_MC_LOCAL="scripts/musicctl.sh"                 # your local musicctl; or embedded below
BIN_JW_REMOTE=""                                # computed from $PREFIX
BIN_MC_REMOTE=""
SSH_OPTS=${SSH_OPTS:-}

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
  --uninstall            Remove installed files and (if present) systemd unit
  -h, --help             Show this help
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
do_ssh() { [ "$DRY_RUN" -eq 1 ] && { echo "ssh $SSH_OPTS $HOST $*"; return; } ; ssh $SSH_OPTS "$HOST" "$@"; }
do_scp()  { [ "$DRY_RUN" -eq 1 ] && { echo "scp $SSH_OPTS $1 $HOST:$2"; return; } ; scp $SSH_OPTS "$1" "$HOST:$2"; }

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
    --uninstall) UNINSTALL=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown arg: $1";;
  esac
done

[ -n "$HOST" ] || { usage; die "--host is required"; }

# Paths on device
BIN_DIR="$PREFIX/bin"
RUN_DIR="$PREFIX/run"   # for PID if you prefer under PREFIX (or keep /run)
BIN_JW_REMOTE="$BIN_DIR/jack-watcher"
BIN_MC_REMOTE="$BIN_DIR/musicctl"
UNIT_PATH="/etc/systemd/system/jack-watcher.service"

if [ "$UNINSTALL" -eq 1 ]; then
  do_ssh "set -e; systemctl stop jack-watcher 2>/dev/null || true; systemctl disable jack-watcher 2>/dev/null || true; \
          rm -f '$UNIT_PATH' 2>/dev/null || true; \
          rm -f '$BIN_JW_REMOTE' '$BIN_MC_REMOTE' 2>/dev/null || true; \
          echo 'Uninstalled jack-watcher and musicctl from $PREFIX/bin (if present).'; \
          systemctl daemon-reload 2>/dev/null || true"
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
    *) die "Unsupported remote arch '$REMOTE_UNAME'. Use --target to override."; ;;
  esac
fi
echo "   build target: $TARGET"

BIN_JW_LOCAL="target/$TARGET/release/jack-watcher"

if [ "$SKIP_BUILD" -eq 0 ]; then
  echo ">> Building jack-watcher…"
  if command -v cross >/dev/null 2>&1; then
    CMD="cross build --release --target $TARGET"
  else
    # ensure target is available
    rustup target add "$TARGET" >/dev/null 2>&1 || true
    CMD="cargo build --release --target $TARGET"
  fi
  echo "   $CMD"
  [ "$DRY_RUN" -eq 1 ] || eval "$CMD"
fi

[ -f "$BIN_JW_LOCAL" ] || die "Local binary not found: $BIN_JW_LOCAL (did build succeed?)"

echo ">> Creating install dirs on device ($BIN_DIR)…"
do_ssh "mkdir -p '$BIN_DIR' '$RUN_DIR'"

echo ">> Copying binaries…"
do_scp "$BIN_JW_LOCAL" "$BIN_JW_REMOTE"
do_scp "$BIN_MC_LOCAL" "$BIN_MC_REMOTE"

echo ">> Finalizing install on device…"
# Inject MUSIC_DIR default into musicctl and set modes
do_ssh "set -e
  sed -i \"s|^DIR=\"\\\${MUSIC_DIR:-/storage/audio}\"|DIR=\"$MUSIC_DIR\"|\" '$BIN_MC_REMOTE' || true
  chmod +x '$BIN_JW_REMOTE' '$BIN_MC_REMOTE'
"

if [ "$USE_SERVICE" -eq 1 ]; then
  echo ">> Installing systemd service (best-effort)…"
  SERVICE_CONTENT="[Unit]
Description=Headphone jack watcher
After=multi-user.target

[Service]
Type=simple
ExecStart=$BIN_JW_REMOTE --watch --exec
Restart=always

[Install]
WantedBy=multi-user.target
"
  # Try to write unit (may fail on read-only /etc; that's OK)
  do_ssh "bash -c 'cat >\"$UNIT_PATH\" <<EOF
$SERVICE_CONTENT
EOF
systemctl daemon-reload || true
systemctl enable --now jack-watcher || true
true' " || echo "   (Could not install service; filesystem may be read-only. You can run '$BIN_JW_REMOTE --watch --exec' via your firmware's autostart instead.)"
fi

echo ">> Smoke test:"
do_ssh "$BIN_JW_REMOTE --list || true"

echo ">> Done.
- jack-watcher: $BIN_JW_REMOTE
- musicctl:     $BIN_MC_REMOTE
- music dir:    $MUSIC_DIR
$( [ $USE_SERVICE -eq 1 ] && echo '- systemd:     installed (if supported)' || echo '- systemd:     skipped' )
"
