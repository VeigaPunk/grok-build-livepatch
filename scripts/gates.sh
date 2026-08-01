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
  - --help on check-and-patch, install-timer, publish, gates
  - install-timer --status (non-fatal if systemd missing)

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
echo "  ok help"

echo "== install-timer --status =="
./scripts/install-timer.sh --status || true

if [[ "$WITH_PATCH" -eq 1 ]]; then
  echo "== patch apply --check (network) =="
  PATCH="$ROOT/patches/0001-ban-generic-subagents.patch"
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  git clone --depth 1 https://github.com/xai-org/grok-build.git "$TMP/g"
  git -C "$TMP/g" apply --check "$PATCH"
  echo "  ok apply-check @ $(git -C "$TMP/g" rev-parse --short HEAD)"
fi

echo "GATES_OK"
