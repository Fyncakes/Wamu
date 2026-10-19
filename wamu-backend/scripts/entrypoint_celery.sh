#!/bin/sh
# Cloud Run Celery worker/beat — Celery in background + tiny HTTP health on $PORT.
# Usage: entrypoint_celery.sh worker | beat
set -eu

ROLE="${1:-worker}"
PORT="${PORT:-8080}"

case "$ROLE" in
  worker)
    celery -A app.workers.celery_app.celery_app worker -l info &
    ;;
  beat)
    celery -A app.workers.celery_app.celery_app beat -l info &
    ;;
  *)
    echo "usage: $0 worker|beat" >&2
    exit 1
    ;;
esac

CELERY_PID=$!

python - <<PY &
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *_args):
        pass

HTTPServer(("0.0.0.0", int(os.environ.get("PORT", "8080"))), H).serve_forever()
PY

wait "$CELERY_PID"
