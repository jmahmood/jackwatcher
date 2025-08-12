#!/bin/sh
set -eu

DIR="/storage/audio"
PLAYLIST="$DIR/.playlist.m3u"
PIDFILE="/run/musicctl.pid"
KILL_THESE="retroarch emulationstation simplemenu gmu.bin"

# inside musicctl (top)
SOCK="/run/musicctl.sock"   # used when mpv is selected
FIFO="/run/musicctl.fifo"   # used when mplayer is selected
RESUME_DB="${RESUME_DB:-/storage/jackwatcher/resume.db}"
LAST_FILE="${LAST_FILE:-/storage/jackwatcher/last.txt}"
MPVLOG_PID="/run/mpvlog.pid"

BTN_PID="/run/btn-watcher.pid"

LOG="${LOG:-/storage/jw.start.log}"

log() {
  # timestamped single-line log
  printf '%s %s\n' "$(date +'%F %T')" "$*" >> "$LOG"
}

# Query current playback position (seconds, float). Returns empty if unavailable.
mpv_get_timepos() {
  local out pos i=0
  while [ $i -lt 10 ]; do
    out=$(printf '%s\n' '{"command":["get_property","time-pos"]}' | mpv_ipc) || out=""
    pos=$(printf '%s' "$out" | sed -n 's/.*"data":\([0-9.]\+\).*/\1/p')
    [ -n "$pos" ] && { printf '%s\n' "$pos"; return 0; }
    sleep 0.05; i=$((i+1))
  done
  return 1
}

# Write last.txt as: <path>\t<pos>
write_last() {
  # $1=abs path, $2=pos float
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  mkdir -p "$(dirname "$LAST_FILE")" 2>/dev/null || true
  # Use printf to ensure TAB and newline are correct
  printf '%s\t%s\n' "$1" "$2" > "$LAST_FILE"
}


# Wait until the IPC socket accepts and mpv replies to a trivial query
wait_ipc_ready() {
  local i=0 out
  while [ $i -lt 50 ]; do   # ~5s max
    out=$(printf '%s\n' '{"command":["get_property","mpv-version"]}' | mpv_ipc) || out=""
    echo "$out" | grep -q '"error":"success"' && return 0
    sleep 0.1; i=$((i+1))
  done
  return 1
}

mpv_ipc_json() {
  # log the exact JSON we send over IPC, then send it
  # usage: mpv_ipc_json '{"command":["playlist-next"]}'
  local json="$1"
  log "ipc -> $json"
  printf '%s\n' "$json" | mpv_ipc >/dev/null 2>&1
}


mpv_ipc() { socat - UNIX-CONNECT:"$SOCK" 2>/dev/null; }
# get current path from mpv; retries for up to ~2s
mpv_get_path() {
  local i=0 out path
  while [ $i -lt 20 ]; do
    out=$(printf '%s\n' '{"command":["get_property","path"]}' | mpv_ipc) || out=""
    # extract "data": "...."
    path=$(printf '%s' "$out" | sed -n 's/.*"data":"\([^"]*\)".*/\1/p')
    [ -n "$path" ] && { printf '%s\n' "$path"; return 0; }
    sleep 0.1; i=$((i+1))
  done
  return 1
}


seek() {
  # $1 like +5 or -30
  [ -n "${1:-}" ] || { echo "musicctl: seek requires +/-seconds"; return 2; }
  local secs="$1"

  case "$(choose_player)" in
    mpv)
      # JSON numbers cannot have a leading '+'
      local jsecs="${secs#+}"

      # Get current path and pre-seek position (best-effort)
      local cur_path cur_before cur_after
      cur_path="$(mpv_get_path 2>/dev/null || true)"
      cur_before="$(mpv_get_timepos 2>/dev/null || true)"

      # Issue the seek (relative)
      printf '{"command":["seek",%s,"relative"]}\n' "$jsecs" | mpv_ipc >/dev/null 2>&1 || true

      # Give mpv a moment to apply, then read the *actual* position
      sleep 0.05
      cur_after="$(mpv_get_timepos 2>/dev/null || true)"

      # If we have a path and a position, persist immediately
      if [ -n "$cur_path" ] && [ -n "$cur_after" ]; then
        write_last "$cur_path" "$cur_after"
      elif [ -n "$cur_path" ] && [ -n "$cur_before" ]; then
        # Fallback: compute (clamped) if post-read failed
        # Note: no duration clamp here; mpv will clamp internally on next update
        # Remove '+' if present and do a simple shell addition via awk
        local delta="${jsecs#+}"
        local est
        est="$(awk -v a="$cur_before" -v d="$delta" 'BEGIN{printf("%.3f", a + d)}')"
        write_last "$cur_path" "$est"
      fi
      ;;
    mplayer)
      # mplayer expects a plain integer (no '+') anyway
      secs="${secs#+}"
      echo "seek $secs 0" > "$FIFO" 2>/dev/null || true
      ;;
    *)
      :
      ;;
  esac
}

chapter_next() { printf '{"command":["add","chapter",1]}\n'  | socat - UNIX-CONNECT:"$SOCK" 2>/dev/null || true; }
chapter_prev() { printf '{"command":["add","chapter",-1]}\n' | socat - UNIX-CONNECT:"$SOCK" 2>/dev/null || true; }
chapter_goto() {
  [ -n "${1:-}" ] || { echo "usage: musicctl chapter-goto <index>"; return 2; }
  printf '{"command":["set","chapter",%s]}\n' "$1" | socat - UNIX-CONNECT:"$SOCK" 2>/dev/null || true
}


start_btn() {
  # JW_CMD is already known (this script)
  JW_CMD="$0" nohup /storage/bin/btn-watcher >/dev/null 2>&1 &
  echo $! > "$BTN_PID"
}

stop_btn() {
  if [ -f "$BTN_PID" ] && kill -0 "$(cat "$BTN_PID")" 2>/dev/null; then
    kill -TERM "$(cat "$BTN_PID")" 2>/dev/null || true
    rm -f "$BTN_PID"
  else
    pkill -TERM -f '/storage/bin/btn-watcher' 2>/dev/null || true
  fi
}


next() {
  if command -v mpv >/dev/null 2>&1; then
    printf '{"command":["playlist-next"]}\n' | socat - UNIX-CONNECT:"$SOCK" 2>/dev/null || true
  elif command -v mplayer >/dev/null 2>&1; then
    echo "pt_step 1"  > "$FIFO" 2>/dev/null || true
  else
    # crude fallback: kill current player; your loop/playlist will advance
    pkill -TERM mpv mplayer mpg123 ffplay 2>/dev/null || true
  fi
}
prev() {
  if command -v mpv >/dev/null 2>&1; then
    printf '{"command":["playlist-prev"]}\n' | socat - UNIX-CONNECT:"$SOCK" 2>/dev/null || true
  elif command -v mplayer >/dev/null 2>&1; then
    echo "pt_step -1" > "$FIFO" 2>/dev/null || true
  else
    pkill -TERM mpv mplayer mpg123 ffplay 2>/dev/null || true
  fi
}


make_playlist() {
  mkdir -p "$DIR" /run
  printf "#EXTM3U\n" >"$PLAYLIST"
  find "$DIR" -type f \( -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.ogg' -o -iname '*.opus' -o -iname '*.flac' \) \
    | sort >>"$PLAYLIST"
}

choose_player() {
  command -v mpv     >/dev/null 2>&1 && { echo mpv; return; }
  command -v mplayer >/dev/null 2>&1 && { echo mplayer; return; }
  command -v mpg123  >/dev/null 2>&1 && { echo mpg123; return; }
  command -v ffplay  >/dev/null 2>&1 && { echo ffplay; return; }
  echo none
}

read_last() {
  # prints "path<TAB>pos" if present
  [ -f "$LAST_FILE" ] || return 1
  awk -F '\t' 'NR==1{print $1 "\t" $2}' "$LAST_FILE"
}

start() {
  make_playlist

  # take foreground by stopping common front-ends
  for p in $KILL_THESE; do pkill -TERM "$p" 2>/dev/null || true; done

  # route to headphones if mixers exist
  amixer sset 'Headphone' 100% unmute >/dev/null 2>&1 || true
  amixer sset 'Speaker'   mute        >/dev/null 2>&1 || true

  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && exit 0

  case "$(choose_player)" in
    mpv)
      rm -f "$SOCK"

      # Phase 1: start mpv idle (no playlist yet → nothing races us)
      MPV_CMD='mpv --no-video --really-quiet --idle=yes --loop-playlist=inf --input-ipc-server="'"$SOCK"'"'
      # (loop-playlist stays enabled; list will be appended in phase 2)
      log "exec: $MPV_CMD"
      nohup sh -c "$MPV_CMD" >/dev/null 2>&1 &

      # Ensure IPC is responsive
      log "waiting for IPC readiness"
      if ! wait_ipc_ready; then
        log "IPC not ready; continuing anyway"
      fi

      # Phase 2: authoritative resume, then enqueue & shuffle playlist
      if [ -f "$LAST_FILE" ]; then
        last_path="$(awk -F '\t' 'NR==1{print $1}' "$LAST_FILE")"
        last_pos="$(awk -F '\t' 'NR==1{print $2}' "$LAST_FILE")"
        log "last.txt parsed: path='${last_path:-}' pos='${last_pos:-}'"
        if [ -n "${last_path:-}" ] && [ -n "${last_pos:-}" ] && [ -f "$last_path" ]; then
          json=$(printf '{"command":["loadfile","%s","replace","start=%s"]}' "$last_path" "$last_pos")
          log "ipc -> $json"
          printf '%s\n' "$json" | mpv_ipc >/dev/null 2>&1
          log "RESUME(last) path=$last_path pos=$last_pos"
        else
          log "last.txt unusable (missing/invalid or file not found)"
        fi
      else
        log "no last.txt present"
      fi

      # Append playlist and shuffle (current playing entry stays as-is)
      json=$(printf '{"command":["loadlist","%s","append"]}' "$PLAYLIST")
      log "ipc -> $json"
      printf '%s\n' "$json" | mpv_ipc >/dev/null 2>&1

      json='{"command":["playlist-shuffle"]}'
      log "ipc -> '"$json"'"
      printf '%s\n' "$json" | mpv_ipc >/dev/null 2>&1

      # Start logger

      log "starting mpvlog env: MPV_SOCKET='$SOCK' JW_RESUME_DB='$RESUME_DB' JW_LAST_FILE='$LAST_FILE'"
      MPV_SOCKET="$SOCK" JW_RESUME_DB="$RESUME_DB" JW_LAST_FILE="$LAST_FILE" JW_DEBUG=1 \
        nohup /storage/bin/mpvlog >/storage/jw.mpvlog.log 2>&1 & echo $! > "$MPVLOG_PID"

      sleep 1
      if ! kill -0 "$(cat "$MPVLOG_PID" 2>/dev/null)" 2>/dev/null; then
        log "ERROR: mpvlog failed to start; see /storage/jw.mpvlog.log"
      fi
      ;;


    mplayer)
      nohup mplayer -really-quiet -shuffle -loop 0 -playlist "$PLAYLIST" -slave -input file="$FIFO" \
        >/dev/null 2>&1 &
      ;;
    mpg123)
      nohup sh -c "while :; do mpg123 -q -Z -@ '$PLAYLIST' || true; done" \
        >/dev/null 2>&1 &
      ;;
    ffplay)
      nohup sh -c "while :; do awk 'NR>1' '$PLAYLIST' | shuf | \
        while IFS= read -r f; do ffplay -nodisp -autoexit -hide_banner -loglevel error \"$f\"; done; done" \
        >/dev/null 2>&1 &
      ;;
    *)
      echo "musicctl: no player found (need mpv/mplayer/mpg123/ffplay)"; exit 1
      ;;
  esac
  echo $! >"$PIDFILE"
  start_btn

}

stop() {
  stop_btn
  [ -f "$MPVLOG_PID" ] && kill -TERM "$(cat "$MPVLOG_PID")" 2>/dev/null || true
  rm -f "$MPVLOG_PID"

  amixer sset 'Speaker' 80% unmute >/dev/null 2>&1 || true
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    kill -TERM "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  else
    pkill -TERM mpv     2>/dev/null || true
    pkill -TERM mplayer 2>/dev/null || true
    pkill -TERM mpg123  2>/dev/null || true
    pkill -TERM ffplay  2>/dev/null || true
  fi
}

case "${1:-}" in
  start) start;;
  stop)  stop;;
  next)  next;;
  prev)  prev;;
  seek)  shift; seek "${1:-}";;
  chapter-next) chapter_next;;
  chapter-prev) chapter_prev;;
  chapter-goto) shift; chapter_goto "${1:-}";;
  *) echo "usage: $0 {start|stop|next|prev|seek +/-secs|chapter-next|chapter-prev|chapter-goto <idx>}"; exit 2;;
esac
