#!/usr/bin/env bash
# Cheap health gates for grok-build-livepatch (local or CI).
# Default: bash -n + --help only (no network).
# Optional: --with-patch  shallow-clone xai-org/grok-build + git apply --check
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: gates.sh [--help|-h] [--with-patch]

Run local health gates:
  - bash -n on scripts/*.sh
  - --help on check-and-patch, install-timer, publish, gates, sync-stack
  - install-timer --status (non-fatal if systemd missing)
  - ban_in_binary if install binary exists
  - user unit ExecStart bound to this ROOT (skip if unit absent — e.g. CI)

  --with-patch   Also shallow-clone upstream and git apply --check the livepatch
                 (network). Default path is offline.
EOF
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WITH_PATCH=0
case "${1:-}" in
  --with-patch) WITH_PATCH=1 ;;
  "") ;;
  *)
    echo "Unknown option: $1" >&2
    usage >&2
    exit 1
    ;;
esac

echo "== bash -n =="
for s in scripts/*.sh; do
  bash -n "$s"
  echo "  ok $s"
done

echo "== --help =="
./scripts/check-and-patch.sh --help >/dev/null
./scripts/install-timer.sh --help >/dev/null
./scripts/publish.sh --help >/dev/null
./scripts/gates.sh --help >/dev/null
./scripts/sync-stack-livepatch.sh --help >/dev/null
echo "  ok help"

echo "== install-timer --status =="
./scripts/install-timer.sh --status || true

echo "== ban_in_binary (if install binary present) =="
LIVE_BIN="${GROK_LIVEPATCH_INSTALL:-$HOME/.local/opt/grok-build-livepatch}/grok"
if [[ -x "$LIVE_BIN" ]]; then
  if grep -aobF 'are banned and will be rejected' "$LIVE_BIN" >/dev/null 2>&1; then
    echo "  ok ban_in_binary=yes"
  else
    echo "  FAIL ban_in_binary=no ($LIVE_BIN lacks patched tool schema)" >&2
    exit 1
  fi
else
  echo "  skip (no $LIVE_BIN — run check-and-patch once)"
fi

echo "== unit ExecStart bound to a livepatch ROOT (if unit installed) =="
UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/grok-build-livepatch.service"
if [[ -f "$UNIT" ]]; then
  exec_line=$(grep -E '^ExecStart=' "$UNIT" | head -1 || true)
  wd_line=$(grep -E '^WorkingDirectory=' "$UNIT" | head -1 || true)
  unit_wd=${wd_line#WorkingDirectory=}
  if [[ "$exec_line" == *"$ROOT"* ]] && [[ "$wd_line" == *"$ROOT"* ]]; then
    echo "  ok unit bound to this ROOT=$ROOT"
  elif [[ -n "$unit_wd" && -x "$unit_wd/scripts/check-and-patch.sh" && "$exec_line" == *"$unit_wd"* ]]; then
    # Peer livepatch tree (e.g. marketplace) may own the unit — require scripts match this tip.
    drift=0
    for rel in scripts/check-and-patch.sh scripts/install-timer.sh scripts/gates.sh patches/0001-ban-generic-subagents.patch patches/0002-kill-workflows.patch; do
      if [[ -f "$ROOT/$rel" && -f "$unit_wd/$rel" ]]; then
        if ! cmp -s "$ROOT/$rel" "$unit_wd/$rel"; then
          echo "  FAIL peer unit ROOT has drifted file: $rel" >&2
          echo "    this: $ROOT/$rel" >&2
          echo "    peer: $unit_wd/$rel" >&2
          drift=1
        fi
      elif [[ -f "$ROOT/$rel" && ! -f "$unit_wd/$rel" ]]; then
        echo "  FAIL peer unit ROOT missing: $rel" >&2
        drift=1
      fi
    done
    if [[ "$drift" -ne 0 ]]; then
      echo "    fix: ./scripts/sync-stack-livepatch.sh  (or bind unit to this tree)" >&2
      exit 1
    fi
    echo "  ok unit bound to peer livepatch ROOT=$unit_wd (scripts match this tree)"
  else
    echo "  FAIL unit not bound to a valid livepatch checkout:" >&2
    echo "    $exec_line" >&2
    echo "    $wd_line" >&2
    echo "    this tree ROOT=$ROOT" >&2
    echo "    fix: ./scripts/install-timer.sh  or  ./scripts/sync-stack-livepatch.sh" >&2
    exit 1
  fi
else
  echo "  skip (no user unit — OK for CI / pre-install)"
fi

if [[ "$WITH_PATCH" -eq 1 ]]; then
  echo "== patch apply --check (network) =="
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  git clone --depth 1 https://github.com/xai-org/grok-build.git "$TMP/g"
  ok=1
  for p in "$ROOT/patches/"*.patch; do
    if git -C "$TMP/g" apply --check "$p"; then
      echo "  ok apply-check $(basename "$p") @ $(git -C "$TMP/g" rev-parse --short HEAD)"
    else
      echo "  FAIL apply-check $(basename "$p")" >&2
      ok=0
    fi
  done
  if [[ "$ok" -ne 1 ]]; then
    exit 1
  fi
  # Apply in order to prove the series is independent + sequential.
  for p in "$ROOT/patches/"*.patch; do
    git -C "$TMP/g" apply "$p"
  done
  echo "  ok series-applied @ $(git -C "$TMP/g" rev-parse --short HEAD)"
fi

echo "GATES_OK"
