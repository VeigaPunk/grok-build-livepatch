#!/usr/bin/env bash
# Install a user systemd timer that runs check-and-patch.sh every 6 hours.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install-timer.sh [--help|-h] [--status] [--link-bin]

Install a user systemd timer that runs check-and-patch.sh every 6 hours.
Copies units under ~/.config/systemd/user and enables the timer (local only;
no network from this script).

  --help, -h   Print this help and exit 0.
  --status     Print preferred root, unit ExecStart, and whether the active
               ~/.grok/bin/grok is the livepatch build (no changes).
  --link-bin   Symlink ~/.grok/bin/grok → ~/.local/opt/grok-build-livepatch/grok
               if that binary exists (opt-in; timer unit defaults REPLACE_BIN=1).

Install root resolution (first match wins):
  1) GROK_LIVEPATCH_ROOT if it contains scripts/check-and-patch.sh
  2) preferred-install-root stamp ONLY if GROK_LIVEPATCH_KEEP_STAMP=1
  3) directory of this script (the checkout you ran) — always wins over a
     stale stamp so re-running install-timer from Projects reclaims the unit

Successful install always rewrites preferred-install-root to the resolved ROOT.
EOF
}

STATE_DIR="${GROK_LIVEPATCH_STATE:-$HOME/.local/state/grok-build-livepatch}"
PREF_FILE="$STATE_DIR/preferred-install-root"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="$UNIT_DIR/grok-build-livepatch.service"
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${GROK_LIVEPATCH_INSTALL:-$HOME/.local/opt/grok-build-livepatch}"
BIN_LINK="${GROK_BIN_LINK:-$HOME/.grok/bin/grok}"
LIVE_BIN="$INSTALL_DIR/grok"

# Install path: explicit ROOT, optional KEEP_STAMP, else the checkout that ran this script.
resolve_root() {
  local cand
  if [[ -n "${GROK_LIVEPATCH_ROOT:-}" && -x "${GROK_LIVEPATCH_ROOT}/scripts/check-and-patch.sh" ]]; then
    printf '%s\n' "$(cd "$GROK_LIVEPATCH_ROOT" && pwd)"
    return
  fi
  if [[ "${GROK_LIVEPATCH_KEEP_STAMP:-}" == "1" && -f "$PREF_FILE" ]]; then
    cand=$(tr -d '\r\n' <"$PREF_FILE" || true)
    if [[ -n "$cand" && -x "$cand/scripts/check-and-patch.sh" ]]; then
      printf '%s\n' "$cand"
      return
    fi
  fi
  printf '%s\n' "$SCRIPT_ROOT"
}

print_bin_status() {
  local active live
  echo "livepatch_bin=$LIVE_BIN"
  if [[ -x "$LIVE_BIN" ]]; then
    echo "livepatch_bin_present=yes"
    # Cheap probe: patched tool schema string (not mangled Rust symbol).
    if grep -aobF 'are banned and will be rejected' "$LIVE_BIN" >/dev/null 2>&1; then
      echo "ban_in_binary=yes"
    else
      echo "ban_in_binary=no (rebuild with check-and-patch; stock binary lacks ban)"
    fi
  else
    echo "livepatch_bin_present=no (run check-and-patch to build)"
    echo "ban_in_binary=unknown"
  fi
  if [[ -e "$BIN_LINK" || -L "$BIN_LINK" ]]; then
    active=$(readlink -f "$BIN_LINK" 2>/dev/null || true)
    echo "active_grok_link=$BIN_LINK"
    echo "active_grok_realpath=${active:-?}"
    live=$(readlink -f "$LIVE_BIN" 2>/dev/null || true)
    if [[ -n "$active" && -n "$live" && "$active" == "$live" ]]; then
      echo "active_cli=livepatch"
    else
      echo "active_cli=stock-or-other (ban not active in CLI until --link-bin or REPLACE_BIN=1 build)"
    fi
  else
    echo "active_grok_link=(missing)"
    echo "active_cli=none"
  fi
  if [[ -f "$STATE_DIR/last-result" ]]; then
    echo "last-result=$(tr -d '\r\n' <"$STATE_DIR/last-result")"
  fi
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
    grep -E '^Environment=GROK_LIVEPATCH_REPLACE_BIN=' "$UNIT" || echo "  Environment=GROK_LIVEPATCH_REPLACE_BIN=(unset)"
  else
    echo "unit=(not installed)"
  fi
  systemctl --user is-enabled grok-build-livepatch.timer 2>/dev/null || true
  systemctl --user is-active grok-build-livepatch.timer 2>/dev/null || true
  print_bin_status
}

link_livepatch_bin() {
  if [[ ! -x "$LIVE_BIN" ]]; then
    echo "FAIL: livepatch binary missing at $LIVE_BIN" >&2
    echo "Build first: ./scripts/check-and-patch.sh  (or FORCE=1)" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$BIN_LINK")"
  ln -sfn "$LIVE_BIN" "$BIN_LINK"
  echo "linked $BIN_LINK → $LIVE_BIN"
  print_bin_status
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
  --link-bin)
    link_livepatch_bin
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

# Always stamp the ROOT we just installed (reclaim-friendly).
printf '%s\n' "$ROOT" >"$PREF_FILE"
echo "stamped preferred-install-root → $ROOT"

systemctl --user daemon-reload
systemctl --user enable --now grok-build-livepatch.timer
# Do not start the oneshot service here — it may cargo-build for minutes.
# Timer fires on schedule; run check-and-patch manually for an immediate apply.
systemctl --user list-timers --all | grep -i grok-build || true
echo "Installed from ROOT=$ROOT"
echo "  $NEW_EXEC"
echo "Logs: journalctl --user -u grok-build-livepatch.service -f"
echo "State:  $STATE_DIR"
echo "Immediate apply: $ROOT/scripts/check-and-patch.sh"
echo "Status: $0 --status"
print_bin_status
