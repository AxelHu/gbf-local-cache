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
LOG="$STATE/service.log"
USER_UNIT="$HOME/.config/systemd/user/gbf-local-cache.service"
mkdir -p "$STATE"

# Keep unattended use from growing one log forever. One previous 10 MiB log is
# retained; cache bodies themselves are managed separately.
if [[ -f "$LOG" ]] && (( $(stat -c '%s' "$LOG") > 10485760 )); then
  mv -f "$LOG" "$LOG.1"
fi

if [[ -s "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "already running pid=$(cat "$PIDFILE")"
  exit 0
fi

if [[ -f "$USER_UNIT" ]] && command -v systemctl >/dev/null 2>&1; then
  systemctl --user start gbf-local-cache.service
  for _ in {1..80}; do
    if systemctl --user is-active --quiet gbf-local-cache.service \
       && curl -fsS --max-time 1 "http://127.0.0.1:${GBF_CACHE_PAC_PORT:-18124}/proxy.pac" >/dev/null 2>&1 \
       && (echo >"/dev/tcp/127.0.0.1/${GBF_CACHE_PROXY_PORT:-18123}") >/dev/null 2>&1; then
      MAIN_PID="$(systemctl --user show -p MainPID --value gbf-local-cache.service)"
      echo "started by systemd pid=$MAIN_PID"
      exit 0
    fi
    sleep 0.1
  done
  systemctl --user status --no-pager gbf-local-cache.service >&2 || true
  exit 1
fi

nohup setsid "$ROOT/bin/run.sh" >>"$LOG" 2>&1 </dev/null &
PID=$!
echo "$PID" >"$PIDFILE"

for _ in {1..80}; do
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "service exited during startup; tail follows" >&2
    tail -80 "$LOG" >&2 || true
    exit 1
  fi
  COMPAT_OK=1
  if [[ -n "${GBF_ACGPOWER_COMPAT_PAC_PORT:-}" ]]; then
    (echo >"/dev/tcp/127.0.0.1/${GBF_ACGPOWER_COMPAT_PAC_PORT}") >/dev/null 2>&1 || COMPAT_OK=0
  fi
  if [[ "$COMPAT_OK" -eq 1 ]] \
     && curl -fsS --max-time 1 "http://127.0.0.1:${GBF_CACHE_PAC_PORT:-18124}/proxy.pac" >/dev/null 2>&1 \
     && (echo >"/dev/tcp/127.0.0.1/${GBF_CACHE_PROXY_PORT:-18123}") >/dev/null 2>&1; then
    sleep 0.25
    kill -0 "$PID" 2>/dev/null || continue
    echo "started pid=$PID log=$LOG"
    exit 0
  fi
  sleep 0.1
done

echo "failed to become ready; tail follows" >&2
tail -80 "$LOG" >&2 || true
exit 1
