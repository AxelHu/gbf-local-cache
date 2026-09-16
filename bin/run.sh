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
CONF="$STATE/mitmproxy"
PROXY_PORT="${GBF_CACHE_PROXY_PORT:-18123}"
PAC_PORT="${GBF_CACHE_PAC_PORT:-18124}"
BROWSER_FALLBACK="${GBF_BROWSER_FALLBACK_PROXY:-DIRECT}"
ACGPOWER_COMPAT_PAC_PORT="${GBF_ACGPOWER_COMPAT_PAC_PORT:-}"
MITM_MODE="regular"
if [[ -n "${GBF_UPSTREAM_PROXY:-}" ]]; then
  MITM_MODE="upstream:${GBF_UPSTREAM_PROXY}"
fi

export GBF_CACHE_ROOT="${GBF_CACHE_ROOT:-$HOME/.cache/gbf-local-cache/gbf}"
export GBF_LEGACY_CACHE_ROOTS="${GBF_LEGACY_CACHE_ROOTS:-}"
export GBF_CACHE_FRESH_SECONDS="${GBF_CACHE_FRESH_SECONDS:-21600}"
export PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONUNBUFFERED=1

mkdir -p "$STATE" "$CONF" "$GBF_CACHE_ROOT"

"$ROOT/.venv/bin/python" "$ROOT/tools/pac_server.py" \
  --host 0.0.0.0 --port "$PAC_PORT" --proxy-port "$PROXY_PORT" \
  --browser-fallback "$BROWSER_FALLBACK" &
PAC_PID=$!
COMPAT_PAC_PID=""
MITM_PID=""
cleanup() {
  [[ -n "$MITM_PID" ]] && kill "$MITM_PID" 2>/dev/null || true
  [[ -n "$COMPAT_PAC_PID" ]] && kill "$COMPAT_PAC_PID" 2>/dev/null || true
  kill "$PAC_PID" 2>/dev/null || true
  wait "$MITM_PID" 2>/dev/null || true
  wait "$COMPAT_PAC_PID" 2>/dev/null || true
  wait "$PAC_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if [[ -n "$ACGPOWER_COMPAT_PAC_PORT" ]]; then
  "$ROOT/.venv/bin/python" "$ROOT/tools/pac_server.py" \
    --host 0.0.0.0 --port "$ACGPOWER_COMPAT_PAC_PORT" --proxy-port "$PROXY_PORT" \
    --browser-fallback "$BROWSER_FALLBACK" --root-browser-pac &
  COMPAT_PAC_PID=$!
fi

"$ROOT/.venv/bin/mitmdump" \
  --mode "$MITM_MODE" \
  --listen-host 0.0.0.0 \
  --listen-port "$PROXY_PORT" \
  --set "confdir=$CONF" \
  --set connection_strategy=lazy \
  --set flow_detail=0 \
  -s "$ROOT/gbf_cache/addon.py" &
MITM_PID=$!
wait "$MITM_PID"
