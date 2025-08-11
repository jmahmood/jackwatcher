#!/bin/sh
set -eu

DIR="/storage/audio"
PLAYLIST="$DIR/.playlist.m3u"
PIDFILE="/run/musicctl.pid"
KILL_THESE="retroarch emulationstation simplemenu gmu.bin"

# inside musicctl (top)
SOCK="/run/musicctl.sock"   # used when mpv is selected
FIFO="/run/musicctl.fifo"   # used when mplayer is selected

BTN_PID="/run/btn-watcher.pid"


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
      nohup mpv --no-video --really-quiet --shuffle --loop-playlist=inf --playlist="$PLAYLIST" --input-ipc-server="$SOCK" \
        >/dev/null 2>&1 &
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
  *) echo "usage: $0 {start|stop|next|prev}"; exit 2;;
esac
