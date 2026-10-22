#!/usr/bin/env bash
# ============================================================================
#  peer.sh - CL5.5 STRESS-1 independent HTTP/2 peer (Linux/FPC side).
#
#  Runs nginx (h2c) in a Docker container as the independent peer for
#  Nghttp2ClientStress (stage 4t). NOTHING is committed as a Dockerfile or a
#  mounted .conf: the repo normalises every non-.sh file to CRLF, and a stray
#  CR in a Dockerfile RUN/heredoc or an nginx directive breaks the peer
#  silently. Instead the whole server is a single `docker run ... sh -c <script>`
#  where <script> (writes the conf + a 4 MiB flow-control file, then execs
#  nginx) is built HERE with LF newlines and passed as one argument.
#
#    peer.sh start [PORT] [BIND]   run, wait for the port, print "READY PORT"
#    peer.sh stop  [PORT]          remove the container
#
#  BIND is the host interface the container publishes on (default 127.0.0.1).
#  Pass 0.0.0.0 when the peer must be reachable from outside this netns - e.g.
#  from a Windows process when Docker runs inside WSL (localhost-forwarding).
#
#  Exit 0 = ready (start) / removed (stop); exit 3 = SKIP (no docker, or the
#  peer never came up). The caller treats exit 3 as "skip the stage loudly",
#  never as a pass.
# ============================================================================
set -u

NAME="nghttp2-stress-peer"
IMAGE="nginx:1.27-alpine"
ACTION="${1:-start}"
PORT="${2:-19340}"
BIND="${3:-127.0.0.1}"

if [ "$ACTION" = "stop" ]; then
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  exit 0
fi

if ! docker info >/dev/null 2>&1; then
  echo "SKIP: docker is not available (daemon not reachable)"
  exit 3
fi

docker rm -f "$NAME" >/dev/null 2>&1 || true

# The container-side script. keepalive_requests 5 makes nginx send GOAWAY every
# 5 requests per HTTP/2 connection; /small returns a tiny body; /big.bin is a
# 4 MiB file (far past the HTTP/2 flow-control window).
SCRIPT="set -e
head -c $((4*1024*1024)) /dev/zero > /usr/share/nginx/html/big.bin
cat > /etc/nginx/nginx.conf <<'CONF'
worker_processes 1;
error_log /dev/stderr warn;
events { worker_connections 1024; }
http {
  access_log off;
  keepalive_requests 5;
  server {
    listen ${PORT};
    http2 on;
    root /usr/share/nginx/html;
    location = /small { return 200 'ok'; }
    location / { }
  }
}
CONF
exec nginx -g 'daemon off;'"

if ! docker run -d --name "$NAME" -p "${BIND}:${PORT}:${PORT}" \
     "$IMAGE" sh -c "$SCRIPT" >/dev/null 2>&1; then
  echo "SKIP: docker run failed (image pull or port bind)"
  exit 3
fi

# Wait until nginx is actually SERVING, not merely until Docker's published-port
# proxy accepts a TCP connection. That proxy accepts BEFORE the container's nginx
# has started (the script first writes a 4 MiB file and the conf, then execs
# nginx), so a TCP-only readiness check declared READY too early and the gate's
# first request failed with "send failed during FlushSession" (0 passed) - a
# race that Windows usually won and Linux/WSL, with a slower cold start, often
# lost. Poll a real GET /small until it answers 'ok'. nginx serves HTTP/1.1 on
# this listener too, so a plain curl is enough; without curl on the host, ask
# busybox wget INSIDE the container (it hits nginx's own 127.0.0.1:PORT).
for _ in $(seq 1 100); do
  if command -v curl >/dev/null 2>&1; then
    if [ "$(curl -fsS -m 2 "http://127.0.0.1:${PORT}/small" 2>/dev/null)" = "ok" ]; then
      echo "READY ${PORT}"
      exit 0
    fi
  elif [ "$(docker exec "$NAME" wget -q -O- "http://127.0.0.1:${PORT}/small" 2>/dev/null)" = "ok" ]; then
    echo "READY ${PORT}"
    exit 0
  fi
  sleep 0.2
done

echo "SKIP: peer did not become ready on ${PORT}"
docker logs "$NAME" 2>&1 | tail -20
docker rm -f "$NAME" >/dev/null 2>&1 || true
exit 3
