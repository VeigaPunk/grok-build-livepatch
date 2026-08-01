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

Exit codes:
  0  ok / noop / already-applied / ok-reassert
  1  failure
  2  needs human rebase (patch does not apply)

last-result tokens (under GROK_LIVEPATCH_STATE):
  ok | ok-reassert | noop | already-applied | needs-rebase | fail

Env:
  GROK_LIVEPATCH_STATE, GROK_BUILD_SRC, GROK_LIVEPATCH_INSTALL,
  GROK_LIVEPATCH_FORCE=1, GROK_LIVEPATCH_REPLACE_BIN=1

When upstream version matches last-patched and FORCE is unset: reverse-check
noop, or clean re-apply + unit smoke with optional skip of release rebuild
(if install binary already present). Full cargo rebuild on version advance.
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

# Read version.json without requiring python3 (jq preferred; python3 fallback).
read_version_json() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r '.stable_version // .version // empty' "$f" 2>/dev/null || true
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("stable_version") or d.get("version") or "")' "$f" 2>/dev/null || true
  fi
}

current_installed() {
  if [[ -x "$BIN_LINK" ]]; then
    "$BIN_LINK" --version 2>/dev/null | head -1 | sed -E 's/.*([0-9]+\.[0-9]+\.[0-9]+).*/\1/' || true
  fi
  read_version_json "$VERSION_FILE"
}

# Latest public release tag on xai-org/grok-build (or VERSION from install channel)
fetch_upstream_version() {
  # Prefer GitHub tags on the open-source tree
  local tag
  tag=$(git ls-remote --tags --refs https://github.com/xai-org/grok-build.git 2>/dev/null \
    | awk -F/ '{print $NF}' | grep -E '^[0-9]' | sort -V | tail -1 || true)
  tag=$(printf '%s' "${tag:-}" | tr -d '[:space:]')
  if [[ -n "${tag:-}" ]]; then
    echo "$tag"
    return
  fi
  # Fallback: grok update check leaves version.json
  local v
  v=$(read_version_json "$VERSION_FILE" | head -1 | tr -d '[:space:]')
  if [[ -n "${v:-}" ]]; then
    echo "$v"
    return
  fi
  echo ""
}

last_patched() {
  # Trim whitespace/newlines so version-match compares cleanly against tags.
  tr -d '\r\n' <"$STATE_DIR/last-patched-version" 2>/dev/null | head -c 128 || true
}

ensure_source() {
  if [[ ! -d "$SRC_DIR/.git" ]]; then
    log "cloning xai-org/grok-build → $SRC_DIR"
    mkdir -p "$(dirname "$SRC_DIR")"
    git clone --depth 1 https://github.com/xai-org/grok-build.git "$SRC_DIR"
  fi
  log "fetching upstream in $SRC_DIR"
  # Shallow-safe: advance origin/main (or master) explicitly, then tags.
  # Bare `fetch --tags` alone can leave origin/main stale on depth-1 clones.
  if ! git -C "$SRC_DIR" fetch --depth 1 --force origin main:refs/remotes/origin/main 2>&1 | tee -a "$LOG"; then
    git -C "$SRC_DIR" fetch --depth 1 --force origin master:refs/remotes/origin/master 2>&1 | tee -a "$LOG" \
      || git -C "$SRC_DIR" fetch --force origin 2>&1 | tee -a "$LOG" \
      || log "WARN: fetch origin failed"
  fi
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
  # No python/jq probe: always build the typed crate, then best-effort binary packages.
  cargo build --release -p xai-tool-types 2>&1 | tee -a "$LOG"
  if ! cargo build --release -p xai-grok-pager-bin 2>&1 | tee -a "$LOG"; then
    cargo build --release 2>&1 | tee -a "$LOG" || true
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
  log "ROOT=$ROOT SRC_DIR=$SRC_DIR INSTALL_DIR=$INSTALL_DIR"
  log "PATCH=$PATCH"
  local installed upstream last
  installed=$(current_installed | head -1)
  upstream=$(fetch_upstream_version)
  last=$(last_patched)
  log "installed=${installed:-?} upstream=${upstream:-?} last_patched=${last:-none}"

  if [[ ! -f "$PATCH" ]]; then
    log "FAIL: patch missing at $PATCH"
    echo "fail" >"$STATE_DIR/last-result"
    exit 1
  fi

  ensure_source

  # Version-match fast path (!FORCE): cheap re-assert without full release rebuild.
  # 1) reverse-check OK → already-applied tree (e.g. failed reset) → pure noop
  # 2) forward --check OK → clean tip after reset → apply + unit smoke; skip binary
  #    rebuild unless install missing, FORCE, or REPLACE_BIN (user wants refresh)
  # Else fall through to full apply/rebuild (true drift / conflict).
  if [[ "${GROK_LIVEPATCH_FORCE:-0}" != "1" && -n "$upstream" && "$upstream" == "$last" ]]; then
    if git -C "$SRC_DIR" apply --reverse --check "$PATCH" 2>"$STATE_DIR/apply-reverse-check.err"; then
      log "already patched for $upstream (reverse-check OK) — noop"
      echo "noop" >"$STATE_DIR/last-result"
      exit 0
    fi
    if git -C "$SRC_DIR" apply --check "$PATCH" 2>"$STATE_DIR/apply-check.err"; then
      log "version match: clean tip — re-assert patch + unit smoke (light path)"
      git -C "$SRC_DIR" checkout -B livepatch/ban-generic-subagents
      git -C "$SRC_DIR" apply "$PATCH"
      run_unit_smoke
      if [[ -x "$INSTALL_DIR/grok" && "${GROK_LIVEPATCH_REPLACE_BIN:-0}" != "1" ]]; then
        echo "${upstream}" >"$STATE_DIR/last-patched-version"
        echo "ok-reassert $(ts)" >"$STATE_DIR/last-result"
        log "=== livepatch OK (reassert; skipped release rebuild) ==="
        exit 0
      fi
      log "install binary missing or REPLACE_BIN=1 — building"
      build_and_install
      echo "${upstream}" >"$STATE_DIR/last-patched-version"
      echo "ok $(ts)" >"$STATE_DIR/last-result"
      log "=== livepatch OK ==="
      exit 0
    fi
    if git -C "$SRC_DIR" grep -q 'is_banned_subagent_type' -- '*.rs' 2>/dev/null; then
      log "WARN: version match + ban symbols but neither reverse nor forward clean — full re-apply"
    else
      log "version match but tree not apply-clean — full re-apply"
    fi
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
