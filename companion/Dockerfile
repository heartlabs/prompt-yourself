# Runtime-only image. The release binary is built in CI
# (.github/release-companion.yml) and scp'd into the build context as
# ./companion-server before `docker compose build` runs on the server.
# There is intentionally NO Rust toolchain in this image — the container build
# only copies files and installs nginx, so deploys stay fast.
FROM debian:bookworm-slim

# nginx serves the PWA on :80 and proxies /api/* to the backend on :4000.
# curl is used by the compose healthcheck. The stock default site is removed
# so our nginx.conf (below) owns port 80. ca-certificates is REQUIRED: the
# push server must validate Apple's TLS cert (web.push.apple.com), and
# neither nginx nor curl depend on it — without it every push fails with
# "Unspecified" (TLS handshake can't be verified) and container curl dies
# with "error setting certificate file".
RUN apt-get update \
    && apt-get install -y --no-install-recommends nginx curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/nginx/sites-enabled/default

# Frontend (static PWA) and prebuilt backend binary
COPY app /srv/app
COPY companion-server /usr/local/bin/companion-server

# nginx serves the frontend on :80; entrypoint starts both processes
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Backend state (VAPID keys, subscription, schedule) lives in CWD — mount a
# volume here. The server finds the static app at ../app (== /srv/app), see
# the app-dir lookup in server/src/main.rs.
WORKDIR /srv/state
ENV PORT=4000

EXPOSE 80 4000

ENTRYPOINT ["/entrypoint.sh"]
