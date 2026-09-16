#!/usr/bin/env bash
set -euo pipefail

UNIT="$HOME/.config/systemd/user/gbf-local-cache.service"
systemctl --user disable --now gbf-local-cache.service 2>/dev/null || true
rm -f "$UNIT"
systemctl --user daemon-reload
echo "removed user systemd service"
