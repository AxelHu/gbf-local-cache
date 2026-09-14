#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${GBF_CACHE_STATE_DIR:-$ROOT/.state}"
PIDFILE="$STATE/service.pid"
if [[ -s "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "running pid=$(cat "$PIDFILE")"
else
  echo "stopped"
fi
curl -fsS --max-time 1 "http://127.0.0.1:${GBF_CACHE_PAC_PORT:-18124}/proxy.pac" | sed -n '1,12p' || true
