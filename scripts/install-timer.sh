#!/usr/bin/env bash
# Install a user systemd timer that runs check-and-patch.sh every 6 hours.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$UNIT_DIR"

cp -f "$ROOT/systemd/grok-build-livepatch.service" "$UNIT_DIR/"
cp -f "$ROOT/systemd/grok-build-livepatch.timer" "$UNIT_DIR/"

# Rewrite WorkingDirectory / ExecStart to absolute path
sed -i "s|@ROOT@|$ROOT|g" "$UNIT_DIR/grok-build-livepatch.service"

systemctl --user daemon-reload
systemctl --user enable --now grok-build-livepatch.timer
systemctl --user start grok-build-livepatch.service || true
systemctl --user list-timers --all | grep -i grok-build || true
echo "Installed. Logs: journalctl --user -u grok-build-livepatch.service -f"
echo "State:  ~/.local/state/grok-build-livepatch/"
