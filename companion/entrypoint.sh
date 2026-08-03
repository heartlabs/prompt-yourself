#!/bin/sh
# Companion container entrypoint — starts both apps:
#   nginx            → frontend on :80  (static PWA + /api proxy to :4000)
#   companion-server → backend on :4000 (Web Push, schedule, state file)
#
# The backend runs in the foreground (exec) so docker stop/restart signals
# reach it; nginx runs in the background and is torn down with the container.
set -e

nginx -g 'daemon off;' &

# State file (companion-state.json) is written to the mounted volume at CWD;
# the server finds the static app at ../app (== /srv/app).
cd /srv/state
exec /usr/local/bin/companion-server
