#!/usr/bin/env bash
# grok-build-livepatch — check for a new Grok Build CLI release and re-apply
# the ban-generic-subagents patch on the fly.
#
# Exit codes:
#   0  up to date / patched OK / no action needed
#   1  failure
#   2  new release detected but patch did not apply cleanly (needs human)
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: check-and-patch.sh [--help|-h]

Check for a new Grok Build CLI release and re-apply the ban-generic-subagents
livepatch (clone/fetch, cargo build — network-heavy).

  --help, -h   Print this help and exit 0 (no network, no clone).

Zero-arg path runs the full check (may network). There is no dry-run flag;
only --help skips network without other flags.

Env:
  GROK_LIVEPATCH_STATE, GROK_BUILD_SRC, GROK_LIVEPATCH_INSTALL,
  GROK_LIVEPATCH_FORCE=1, GROK_LIVEPATCH_REPLACE_BIN=1
EOF
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${GROK_LIVEPATCH_STATE:-$HOME/.local/state/grok-build-livepatch}"
SRC_DIR="${GROK_BUILD_SRC:-$HOME/Projects/grok-build}"
PATCH="$ROOT/patches/0001-ban-generic-subagents.patch"
LOG="$STATE_DIR/watch.log"
VERSION_FILE="$HOME/.grok/version.json"
BIN_LINK="$HOME/.grok/bin/grok"
INSTALL_DIR="${GROK_LIVEPATCH_INSTALL:-$HOME/.local/opt/grok-build-livepatch}"

mkdir -p "$STATE_DIR" "$INSTALL_DIR"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(ts)] $*" | tee -a "$LOG"; }

current_installed() {
  if [[ -x "$BIN_LINK" ]]; then
    "$BIN_LINK" --version 2>/dev/null | head -1 | sed -E 's/.*([0-9]+\.[0-9]+\.[0-9]+).*/\1/' || true
  fi
  if [[ -f "$VERSION_FILE" ]]; then
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("stable_version") or json.load(open(sys.argv[1])).get("version",""))' "$VERSION_FILE" 2>/dev/null || true
  fi
}

# Latest public release tag on xai-org/grok-build (or VERSION from install channel)
fetch_upstream_version() {
  # Prefer GitHub tags on the open-source tree
  local tag
  tag=$(git ls-remote --tags --refs https://github.com/xai-org/grok-build.git 2>/dev/null \
    | awk -F/ '{print $NF}' | grep -E '^[0-9]' | sort -V | tail -1 || true)
  if [[ -n "${tag:-}" ]]; then
    echo "$tag"
    return
  fi
  # Fallback: grok update check leaves version.json
  if [[ -f "$VERSION_FILE" ]]; then
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("stable_version") or d.get("version",""))' "$VERSION_FILE"
    return
  fi
  echo ""
}

last_patched() {
  cat "$STATE_DIR/last-patched-version" 2>/dev/null || true
}

ensure_source() {
  if [[ ! -d "$SRC_DIR/.git" ]]; then
    log "cloning xai-org/grok-build → $SRC_DIR"
    mkdir -p "$(dirname "$SRC_DIR")"
    git clone --depth 1 https://github.com/xai-org/grok-build.git "$SRC_DIR"
  fi
  log "fetching upstream in $SRC_DIR"
  git -C "$SRC_DIR" fetch --tags --force origin 2>&1 | tee -a "$LOG" || true
  # Prefer main/synced tip
  git -C "$SRC_DIR" checkout -f main 2>/dev/null || git -C "$SRC_DIR" checkout -f master 2>/dev/null || true
  if ! git -C "$SRC_DIR" reset --hard origin/main 2>/dev/null \
    && ! git -C "$SRC_DIR" reset --hard origin/master 2>/dev/null; then
    log "WARN: reset --hard origin/main|master failed; trying pull --ff-only"
    git -C "$SRC_DIR" pull --ff-only 2>&1 | tee -a "$LOG" || log "WARN: source reset/pull failed — working tree may be stale"
  fi
}

# Sets APPLY_STATUS: applied | already-applied | three-way | needs-rebase | fail
apply_patch() {
  APPLY_STATUS=fail
  cd "$SRC_DIR"
  # clean any previous livepatch branch
  git checkout -B livepatch/ban-generic-subagents
  # 1) clean apply
  if git apply --check "$PATCH" 2>"$STATE_DIR/apply-check.err"; then
    git apply "$PATCH"
    log "patch applied cleanly"
    APPLY_STATUS=applied
    return 0
  fi
  # 2) already applied only if reverse --check succeeds (do not OR-grep symbols alone)
  if git apply --reverse --check "$PATCH" 2>"$STATE_DIR/apply-reverse-check.err"; then
    log "patch already present (reverse-check OK) — already-applied"
    APPLY_STATUS=already-applied
    return 0
  fi
  if git grep -q 'is_banned_subagent_type' -- '*.rs' 2>/dev/null; then
    log "WARN: ban symbols present but reverse --check failed — trying 3-way"
  fi
  # 3) try 3-way
  if git apply --3way "$PATCH" 2>"$STATE_DIR/apply-3way.err"; then
    log "patch applied with 3-way merge"
    APPLY_STATUS=three-way
    return 0
  fi
  # 4) needs human
  log "PATCH FAILED — needs human rebase"
  APPLY_STATUS=needs-rebase
  cat "$STATE_DIR/apply-check.err" >>"$LOG" || true
  cat "$STATE_DIR/apply-reverse-check.err" >>"$LOG" 2>/dev/null || true
  cat "$STATE_DIR/apply-3way.err" >>"$LOG" || true
  return 2
}

build_and_install() {
  cd "$SRC_DIR"
  log "cargo build --release (xai-tool-types + grok binary if present)"
  # Build the whole workspace release binary if there is a default bin
  if cargo metadata --no-deps --format-version 1 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(any(p.get("name")=="xai-grok-pager-bin" or "grok" in p.get("name","") for p in d.get("packages",[])))' | grep -q True; then
    cargo build --release -p xai-tool-types 2>&1 | tee -a "$LOG"
    # Prefer pager-bin if exists
    if cargo build --release -p xai-grok-pager-bin 2>&1 | tee -a "$LOG"; then
      :
    else
      cargo build --release 2>&1 | tee -a "$LOG" || true
    fi
  else
    cargo build --release -p xai-tool-types 2>&1 | tee -a "$LOG"
  fi

  # Find built grok binary
  local bin
  bin=$(find "$SRC_DIR/target/release" -maxdepth 1 -type f -executable \( -name 'grok' -o -name 'xai-grok*' -o -name 'grok-build*' \) 2>/dev/null | head -1 || true)
  if [[ -n "${bin:-}" ]]; then
    install -m 755 "$bin" "$INSTALL_DIR/grok"
    # Side-install: do NOT clobber official install unless explicitly requested
    if [[ "${GROK_LIVEPATCH_REPLACE_BIN:-0}" == "1" ]]; then
      mkdir -p "$(dirname "$BIN_LINK")"
      ln -sfn "$INSTALL_DIR/grok" "$BIN_LINK"
      log "replaced $BIN_LINK → $INSTALL_DIR/grok"
    else
      log "built binary at $INSTALL_DIR/grok (set GROK_LIVEPATCH_REPLACE_BIN=1 to replace ~/.grok/bin/grok)"
    fi
  else
    log "no release binary found; library patch validated via cargo build -p xai-tool-types only"
  fi
}

run_unit_smoke() {
  cd "$SRC_DIR"
  cargo test -p xai-tool-types banned_subagent -- --nocapture 2>&1 | tee -a "$LOG" || {
    log "unit smoke failed"
    return 1
  }
}

main() {
  log "=== livepatch check start ==="
  local installed upstream last
  installed=$(current_installed | head -1)
  upstream=$(fetch_upstream_version)
  last=$(last_patched)
  log "installed=${installed:-?} upstream=${upstream:-?} last_patched=${last:-none}"

  ensure_source

  # Always re-apply on tip when upstream tag/version advances OR force
  if [[ "${GROK_LIVEPATCH_FORCE:-0}" != "1" && -n "$upstream" && "$upstream" == "$last" ]]; then
    # still ensure working tree has ban constants if source drifted
    if git -C "$SRC_DIR" grep -q 'is_banned_subagent_type' -- '*.rs' 2>/dev/null; then
      log "already patched for $upstream — noop"
      echo "noop" >"$STATE_DIR/last-result"
      exit 0
    fi
    log "version match but ban symbols missing — re-applying"
  fi

  APPLY_STATUS=fail
  set +e
  apply_patch
  rc=$?
  set -e
  if [[ $rc -eq 2 ]]; then
    echo "needs-rebase" >"$STATE_DIR/last-result"
    log "=== livepatch needs human rebase ==="
    exit 2
  fi
  if [[ $rc -ne 0 ]]; then
    echo "fail" >"$STATE_DIR/last-result"
    exit 1
  fi

  # Full reverse-clean already-applied: integrity already proven; skip heavy rebuild
  if [[ "${APPLY_STATUS:-}" == "already-applied" ]]; then
    echo "${upstream:-$(ts)}" >"$STATE_DIR/last-patched-version"
    echo "already-applied $(ts)" >"$STATE_DIR/last-result"
    log "=== livepatch already-applied (noop rebuild) ==="
    exit 0
  fi

  run_unit_smoke
  build_and_install

  echo "${upstream:-$(ts)}" >"$STATE_DIR/last-patched-version"
  echo "ok $(ts)" >"$STATE_DIR/last-result"
  log "=== livepatch OK ==="
}

main "$@"
