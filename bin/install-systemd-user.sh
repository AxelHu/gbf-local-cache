#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/gbf-local-cache.service"

command -v systemctl >/dev/null 2>&1 || {
  echo "systemd/systemctl is unavailable" >&2
  exit 1
}

mkdir -p "$UNIT_DIR"

# Stop an older nohup/start.sh instance before systemd takes ownership.
if [[ -s "$ROOT/.state/service.pid" ]]; then
  OLD_PID="$(cat "$ROOT/.state/service.pid" 2>/dev/null || true)"
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    kill -TERM -- "-$OLD_PID" 2>/dev/null || kill -TERM "$OLD_PID" 2>/dev/null || true
    for _ in {1..50}; do
      kill -0 "$OLD_PID" 2>/dev/null || break
      sleep 0.1
    done
  fi
  rm -f "$ROOT/.state/service.pid"
fi

cat >"$UNIT" <<EOF
[Unit]
Description=GBF Local Static Asset Cache
After=network.target

[Service]
Type=simple
WorkingDirectory=$ROOT
ExecStart=$ROOT/bin/run.sh
Restart=always
RestartSec=2
Environment=HOME=$HOME

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now gbf-local-cache.service
echo "installed and started: $UNIT"
systemctl --user --no-pager --full status gbf-local-cache.service | sed -n '1,12p'
