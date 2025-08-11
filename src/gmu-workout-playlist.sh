#!/bin/sh
set -eu

SRC_DIR="/storage/audio"
OUT="/storage/.config/gmu/playlists/Training.m3u"

mkdir -p "$(dirname "$OUT")"
printf "#EXTM3U\n" >"$OUT"
# Add audio files; name-sort works well if you prefix with YYYY-MM-DD in downloads
find "$SRC_DIR" -type f \( -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.ogg' -o -iname '*.opus' \) \
  | sort >>"$OUT"
