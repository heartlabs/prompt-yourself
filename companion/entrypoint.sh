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

# TLS trust store: the server validates push endpoints (Apple's
# web.push.apple.com) with its vendored OpenSSL. Point it at the system
# bundle explicitly — an unset or missing store means every push fails with
# "Unspecified" and curl with "error setting certificate file".
export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"
export SSL_CERT_DIR="${SSL_CERT_DIR:-/etc/ssl/certs}"

exec /usr/local/bin/companion-server
