#!/usr/bin/env bash
# Create/push public GitHub repo. Prefer a fresh classic PAT with `repo` scope:
#   export GH_TOKEN=ghp_...
#   ./scripts/publish.sh
# Or: op run -- GH_TOKEN=op://Personal/<item>/credential ./scripts/publish.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "GH_TOKEN not set. Example:"
  echo "  GH_TOKEN=\$(op read 'op://Personal/YOUR_PAT_ITEM/credential') $0"
  exit 1
fi

gh auth status
if ! gh repo view VeigaPunk/grok-build-livepatch >/dev/null 2>&1; then
  gh repo create VeigaPunk/grok-build-livepatch \
    --public \
    --source=. \
    --remote=origin \
    --description "Livepatch Grok Build CLI: hard-ban general-purpose/explore; 6h upstream re-apply" \
    --push
else
  git remote remove origin 2>/dev/null || true
  git remote add origin git@github.com:VeigaPunk/grok-build-livepatch.git
  git push -u origin main
fi
gh repo view VeigaPunk/grok-build-livepatch --web
