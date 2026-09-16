#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

STATE="${GBF_CACHE_STATE_DIR:-$ROOT/.state}"
PIDFILE="$STATE/service.pid"
USER_UNIT="$HOME/.config/systemd/user/gbf-local-cache.service"

if [[ -f "$USER_UNIT" ]] && command -v systemctl >/dev/null 2>&1 \
   && systemctl --user is-active --quiet gbf-local-cache.service; then
  systemctl --user stop gbf-local-cache.service
  rm -f "$PIDFILE"
  echo "stopped systemd service"
  exit 0
fi

if [[ ! -s "$PIDFILE" ]]; then
  echo "not running"
  exit 0
fi
PID="$(cat "$PIDFILE")"
if kill -0 "$PID" 2>/dev/null; then
  kill -TERM -- "-$PID" 2>/dev/null || kill -TERM "$PID" 2>/dev/null || true
  for _ in {1..50}; do
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.1
  done
fi
rm -f "$PIDFILE"
echo "stopped"
