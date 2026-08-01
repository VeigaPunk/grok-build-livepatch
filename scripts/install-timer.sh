#!/usr/bin/env bash
# Install a user systemd timer that runs check-and-patch.sh every 6 hours.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install-timer.sh [--help|-h] [--status]

Install a user systemd timer that runs check-and-patch.sh every 6 hours.
Copies units under ~/.config/systemd/user and enables the timer (local only;
no network from this script).

  --help, -h   Print this help and exit 0.
  --status     Print preferred root + installed ExecStart; exit 0 (no changes).

Root resolution (first match wins):
  1) GROK_LIVEPATCH_ROOT if it contains scripts/check-and-patch.sh
  2) ~/.local/state/grok-build-livepatch/preferred-install-root (if still valid)
  3) directory of this script (the checkout you ran)

Successful install writes preferred-install-root so later installs from a
plugin/marketplace copy keep the timer on the preferred checkout unless you
export GROK_LIVEPATCH_ROOT or delete the stamp.
EOF
}

STATE_DIR="${GROK_LIVEPATCH_STATE:-$HOME/.local/state/grok-build-livepatch}"
PREF_FILE="$STATE_DIR/preferred-install-root"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="$UNIT_DIR/grok-build-livepatch.service"
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

resolve_root() {
  local cand
  if [[ -n "${GROK_LIVEPATCH_ROOT:-}" && -x "${GROK_LIVEPATCH_ROOT}/scripts/check-and-patch.sh" ]]; then
    printf '%s\n' "$(cd "$GROK_LIVEPATCH_ROOT" && pwd)"
    return
  fi
  if [[ -f "$PREF_FILE" ]]; then
    cand=$(tr -d '\r\n' <"$PREF_FILE" || true)
    if [[ -n "$cand" && -x "$cand/scripts/check-and-patch.sh" ]]; then
      printf '%s\n' "$cand"
      return
    fi
  fi
  printf '%s\n' "$SCRIPT_ROOT"
}

print_status() {
  local root exec_line
  root=$(resolve_root)
  echo "preferred/resolved ROOT=$root"
  echo "SCRIPT_ROOT=$SCRIPT_ROOT"
  echo "PREF_FILE=$PREF_FILE"
  if [[ -f "$PREF_FILE" ]]; then
    echo "stamp=$(tr -d '\r\n' <"$PREF_FILE")"
  else
    echo "stamp=(none)"
  fi
  if [[ -f "$UNIT" ]]; then
    exec_line=$(grep -E '^ExecStart=' "$UNIT" | head -1 || true)
    echo "unit=$UNIT"
    echo "  $exec_line"
    grep -E '^WorkingDirectory=' "$UNIT" || true
  else
    echo "unit=(not installed)"
  fi
  systemctl --user is-enabled grok-build-livepatch.timer 2>/dev/null || true
  systemctl --user is-active grok-build-livepatch.timer 2>/dev/null || true
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
  --status)
    print_status
    exit 0
    ;;
  "")
    ;;
  *)
    echo "Unknown option: $1" >&2
    usage >&2
    exit 1
    ;;
esac

ROOT=$(resolve_root)
mkdir -p "$STATE_DIR" "$UNIT_DIR"

PREV_EXEC=""
if [[ -f "$UNIT" ]]; then
  PREV_EXEC=$(grep -E '^ExecStart=' "$UNIT" | head -1 || true)
fi

# Units always come from the resolved ROOT so PATH/CARGO match that tree.
cp -f "$ROOT/systemd/grok-build-livepatch.service" "$UNIT_DIR/"
cp -f "$ROOT/systemd/grok-build-livepatch.timer" "$UNIT_DIR/"

# Rewrite WorkingDirectory / ExecStart to absolute path
sed -i "s|@ROOT@|$ROOT|g" "$UNIT"

NEW_EXEC=$(grep -E '^ExecStart=' "$UNIT" | head -1 || true)
if [[ -n "$PREV_EXEC" && "$PREV_EXEC" != "$NEW_EXEC" ]]; then
  echo "NOTE: replaced prior unit ExecStart:"
  echo "  was: $PREV_EXEC"
  echo "  now: $NEW_EXEC"
fi

# Stamp preferred root so plugin reinstalls keep this checkout (if they honor stamp).
# When installing from SCRIPT_ROOT, always refresh stamp to this checkout.
# When SCRIPT_ROOT differs but stamp already preferred this ROOT, keep stamp.
if [[ "$SCRIPT_ROOT" == "$ROOT" ]] || [[ ! -f "$PREF_FILE" ]] || [[ -n "${GROK_LIVEPATCH_ROOT:-}" ]]; then
  printf '%s\n' "$ROOT" >"$PREF_FILE"
  echo "stamped preferred-install-root → $ROOT"
elif [[ "$(tr -d '\r\n' <"$PREF_FILE" 2>/dev/null || true)" != "$ROOT" ]]; then
  # Resolved via stamp already; leave stamp
  echo "keeping preferred-install-root → $ROOT"
fi

systemctl --user daemon-reload
systemctl --user enable --now grok-build-livepatch.timer
systemctl --user start grok-build-livepatch.service || true
systemctl --user list-timers --all | grep -i grok-build || true
echo "Installed from ROOT=$ROOT"
echo "  $NEW_EXEC"
echo "Logs: journalctl --user -u grok-build-livepatch.service -f"
echo "State:  $STATE_DIR"
echo "Status: $0 --status"
