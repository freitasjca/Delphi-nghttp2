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

# Wait for the published port to accept a TCP connection.
for _ in $(seq 1 50); do
  if (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then
    exec 3>&- 2>/dev/null || true
    echo "READY ${PORT}"
    exit 0
  fi
  sleep 0.2
done

echo "SKIP: peer did not become ready on ${PORT}"
docker logs "$NAME" 2>&1 | tail -20
docker rm -f "$NAME" >/dev/null 2>&1 || true
exit 3
