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
  MAIN_PID="$(systemctl --user show -p MainPID --value gbf-local-cache.service)"
  echo "running systemd pid=$MAIN_PID"
elif [[ -s "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "running pid=$(cat "$PIDFILE")"
else
  echo "stopped"
fi
curl -fsS --max-time 1 "http://127.0.0.1:${GBF_CACHE_PAC_PORT:-18124}/proxy.pac" | sed -n '1,12p' || true
if [[ -n "${GBF_ACGPOWER_COMPAT_PAC_PORT:-}" ]]; then
  echo "acgpower-compat=http://127.0.0.1:${GBF_ACGPOWER_COMPAT_PAC_PORT}/proxy.pac"
  curl -fsS --max-time 1 "http://127.0.0.1:${GBF_ACGPOWER_COMPAT_PAC_PORT}/proxy.pac" | sed -n '1,9p' || true
fi
