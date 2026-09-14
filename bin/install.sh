#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "created $ROOT/.env from .env.example"
  echo "edit GBF_LEGACY_CACHE_ROOTS if this machine uses different/no ACGPower cache paths"
fi

if [[ ! -x .venv/bin/python ]]; then
  if command -v uv >/dev/null 2>&1; then
    uv venv .venv
  elif python3 -m venv .venv >/dev/null 2>&1; then
    :
  else
    cat >&2 <<'EOF'
Could not create .venv.
Install `uv`, or install the OS package that provides `python3 -m venv`
(for Ubuntu this is usually python3-venv), then rerun ./bin/install.sh.
EOF
    exit 1
  fi
fi

.venv/bin/python -m pip install -r requirements.txt
./bin/start.sh

CA="$ROOT/.state/mitmproxy/mitmproxy-ca-cert.cer"
if [[ ! -f "$CA" ]]; then
  echo "proxy started but CA certificate was not generated at $CA" >&2
  exit 1
fi

POWERSHELL=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
CMD=/mnt/c/Windows/System32/cmd.exe
if [[ -x "$POWERSHELL" && -x "$CMD" ]]; then
  WIN_USER="$($CMD /d /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r' | tail -1)"
  if [[ -n "$WIN_USER" ]]; then
    WIN_STATE="/mnt/c/Users/$WIN_USER/AppData/Local/GBFLocalCache"
    mkdir -p "$WIN_STATE"
    cp -f "$CA" "$WIN_STATE/mitmproxy-ca-cert.cer"
    echo "copied CA certificate to C:\\Users\\$WIN_USER\\AppData\\Local\\GBFLocalCache\\mitmproxy-ca-cert.cer"
  fi
fi

cat <<EOF

WSL service is ready.

Next, from Windows PowerShell, enable the GBF-only PAC and trust this install's
local CA (the first CA install may show a Windows trust confirmation):

  powershell.exe -ExecutionPolicy Bypass -File "$(wslpath -w "$ROOT/windows/enable.ps1" 2>/dev/null || echo "$ROOT/windows/enable.ps1")"

Then fully restart Chrome once. See docs/deployment.md for verification,
autostart, legacy-cache configuration, and rollback.
EOF
