#!/bin/sh
# Pin controller path via env and start the watcher
export JW_CMD="${PREFIX}/bin/musicctl"
exec "${PREFIX}/bin/jack-watcher" --watch --exec "$@"
