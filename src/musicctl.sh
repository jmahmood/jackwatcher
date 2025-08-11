#!/bin/sh
set -eu

DIR="/storage/audio"                     # set your source dir
PLAYLIST="$DIR/Training.m3u"
PIDFILE="/run/musicctl.pid"
KILL_THESE="retroarch emulationstation simplemenu gmu.bin"

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
      nohup mpv --no-video --really-quiet --shuffle --loop-playlist=inf --playlist="$PLAYLIST" \
        >/dev/null 2>&1 &
      ;;
    mplayer)
      nohup mplayer -really-quiet -shuffle -loop 0 -playlist "$PLAYLIST" \
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
}

stop() {
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
  *) echo "usage: $0 {start|stop}"; exit 2;;
esac
