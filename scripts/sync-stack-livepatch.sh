#!/usr/bin/env bash
# Sync this public livepatch tree into local xbgst-stack copies and rebind timer.
# Local-only; no network (except if you later run check-and-patch).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sync-stack-livepatch.sh [--help|-h] [--no-timer]

Copy scripts/, systemd/, patches/ from this repo into known local stack
livepatch trees, rewrite xbgst-stack install-host.sh to prefer Projects,
and re-run install-timer from this checkout (unless --no-timer).

Targets (if present):
  ~/Projects/grok-marketplace/plugins/xbgst-stack/livepatch
  ~/.grok/installed-plugins/xbgst-stack-*/livepatch
  matching install-host.sh next to those trees
EOF
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
esac

NO_TIMER=0
case "${1:-}" in
  --no-timer) NO_TIMER=1 ;;
  "") ;;
  *)
    echo "Unknown option: $1" >&2
    usage >&2
    exit 1
    ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANON="$ROOT"

sync_tree() {
  local dest="$1"
  [[ -d "$dest" ]] || return 0
  mkdir -p "$dest/scripts" "$dest/systemd" "$dest/patches"
  cp -a "$ROOT/scripts/"*.sh "$dest/scripts/"
  cp -a "$ROOT/systemd/"* "$dest/systemd/" 2>/dev/null || true
  cp -a "$ROOT/patches/"* "$dest/patches/" 2>/dev/null || true
  chmod +x "$dest/scripts/"*.sh
  echo "synced → $dest"
}

# Prefer-Projects install-host body for the livepatch block (idempotent rewrite of timer section).
patch_install_host() {
  local host="$1"
  [[ -f "$host" ]] || return 0
  if grep -q 'prefer canonical Projects livepatch' "$host" 2>/dev/null \
    && grep -q 'GROK_LIVEPATCH_FORCE_STACK_LP' "$host" 2>/dev/null; then
    echo "install-host already Projects-prefer: $host"
    return 0
  fi
  # Full replace of file is safer than fragile sed; keep agents/skills/commands copy logic.
  cat >"$host" <<'HOSTEOF'
#!/usr/bin/env bash
# Wire xbgst-stack + livepatch on this host (idempotent).
# Managed/synced by grok-build-livepatch scripts/sync-stack-livepatch.sh
#
# Timer root (local-first when Projects clone exists):
#   1) GROK_LIVEPATCH_ROOT if set
#   2) KEEP_STAMP=1 → honor preferred-install-root stamp
#   3) $HOME/Projects/grok-build-livepatch if install-timer exists
#   4) else this stack's livepatch/ (or FORCE_STACK_LP=1)
set -euo pipefail
STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LP="$STACK_ROOT/livepatch"
GROK_HOME="${GROK_HOME:-$HOME/.grok}"
CANON="${HOME}/Projects/grok-build-livepatch"

echo "→ xbgst-stack root: $STACK_ROOT"

mkdir -p "$GROK_HOME/agents" "$GROK_HOME/skills" "$GROK_HOME/commands"
if [[ -d "$STACK_ROOT/agents" ]]; then
  cp -a "$STACK_ROOT/agents/"*.md "$GROK_HOME/agents/" 2>/dev/null || true
  echo "✓ agents → $GROK_HOME/agents"
fi
if [[ -d "$STACK_ROOT/skills" ]]; then
  for d in "$STACK_ROOT/skills"/*; do
    [[ -d "$d" ]] || continue
    name=$(basename "$d")
    rm -rf "$GROK_HOME/skills/$name"
    cp -a "$d" "$GROK_HOME/skills/$name"
  done
  echo "✓ skills → $GROK_HOME/skills"
fi
if [[ -d "$STACK_ROOT/commands" ]]; then
  cp -a "$STACK_ROOT/commands/"*.md "$GROK_HOME/commands/" 2>/dev/null || true
  if [[ -d "$STACK_ROOT/commands/references" ]]; then
    mkdir -p "$GROK_HOME/commands/references"
    cp -a "$STACK_ROOT/commands/references/"* "$GROK_HOME/commands/references/" 2>/dev/null || true
  fi
  echo "✓ commands → $GROK_HOME/commands"
fi

if [[ -d "$LP/scripts" ]]; then
  chmod +x "$LP/scripts/"*.sh
  if [[ -n "${GROK_LIVEPATCH_ROOT:-}" ]]; then
    echo "→ install-timer with GROK_LIVEPATCH_ROOT=$GROK_LIVEPATCH_ROOT"
    if [[ -x "${GROK_LIVEPATCH_ROOT}/scripts/install-timer.sh" ]]; then
      bash "${GROK_LIVEPATCH_ROOT}/scripts/install-timer.sh"
    else
      bash "$LP/scripts/install-timer.sh"
    fi
  elif [[ "${GROK_LIVEPATCH_KEEP_STAMP:-}" == "1" ]]; then
    echo "→ install-timer honoring preferred-install-root stamp (KEEP_STAMP=1)"
    GROK_LIVEPATCH_KEEP_STAMP=1 bash "$LP/scripts/install-timer.sh"
  elif [[ "${GROK_LIVEPATCH_FORCE_STACK_LP:-}" != "1" && -x "$CANON/scripts/install-timer.sh" ]]; then
    echo "→ prefer canonical Projects livepatch: $CANON"
    bash "$CANON/scripts/install-timer.sh"
  else
    echo "→ install-timer binding ROOT to stack livepatch: $LP"
    bash "$LP/scripts/install-timer.sh"
  fi
  UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/grok-build-livepatch.service"
  if [[ -f "$UNIT" ]] && grep -qE '^Environment=GROK_LIVEPATCH_REPLACE_BIN=1' "$UNIT"; then
    echo "  note: unit REPLACE_BIN=1 (active CLI gets ban; set =0 on unit to opt out)"
  fi
  if [[ -x "$CANON/scripts/install-timer.sh" ]]; then
    bash "$CANON/scripts/install-timer.sh" --status || true
  else
    bash "$LP/scripts/install-timer.sh" --status || true
  fi
  echo "✓ livepatch timer enabled"
else
  echo "⚠ livepatch/ missing under stack"
fi

echo "✓ xbgst-stack host install complete"
HOSTEOF
  chmod +x "$host"
  echo "rewrote install-host → $host"
}

# --- targets ---
MKT_LP="$HOME/Projects/grok-marketplace/plugins/xbgst-stack/livepatch"
MKT_HOST="$HOME/Projects/grok-marketplace/plugins/xbgst-stack/scripts/install-host.sh"
sync_tree "$MKT_LP"
patch_install_host "$MKT_HOST"

shopt -s nullglob
for d in "$HOME"/.grok/installed-plugins/xbgst-stack-*/livepatch; do
  sync_tree "$d"
  host="$(dirname "$d")/scripts/install-host.sh"
  patch_install_host "$host"
done
shopt -u nullglob

if [[ "$NO_TIMER" -eq 0 ]]; then
  echo "→ rebind timer from $CANON"
  bash "$CANON/scripts/install-timer.sh"
  bash "$CANON/scripts/install-timer.sh" --status || true
fi

echo "SYNC_OK"
