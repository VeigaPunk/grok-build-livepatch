# grok-build-livepatch

**Hard-ban Grok Build's `general-purpose` and `explore` subagents in the CLI itself** — and keep that ban alive across upstream releases.

xAI's public tree (`xai-org/grok-build`) is source-transparent and **does not accept external PRs**. This repo is the practical path:

1. Track a minimal patch that removes those built-ins from the advertised roster and **rejects them at spawn validation**.
2. Every **6 hours**, check whether upstream moved; re-apply the patch; run unit smoke; optionally rebuild the binary.
3. Ship as a **public installable** (git clone + timer, or GitHub Actions watch).

## What the patch does

| Change | Effect |
|--------|--------|
| `BUILTIN_SUBAGENTS` → only `plan` | Model no longer sees `general-purpose` / `explore` |
| `subagent_variants()` → only `Plan` | Discovery matches |
| `default_subagent_type()` → `plan` | Omitted type is no longer GP |
| `is_banned_subagent_type()` + gate | Spawn of banned names hard-fails even if shadowed |
| Unit test `banned_subagent_types_are_recognized` | Smoke |

Upstream constants for GP/explore prompts remain for legacy rendering only; they are **not** advertised and **cannot spawn**.

## Quick install (local, every 6h)

```bash
git clone https://github.com/VeigaPunk/grok-build-livepatch.git
cd grok-build-livepatch
chmod +x scripts/*.sh
./scripts/check-and-patch.sh --help   # usage only; no network
./scripts/install-timer.sh --help
./scripts/check-and-patch.sh          # first run (clone/fetch + cargo — network-heavy)
./scripts/install-timer.sh            # systemd --user timer @ 6h
```

There is **no dry-run** that skips network on the zero-arg path; only `--help`/`-h` exits before clone/build.

Optional: replace the installed `grok` binary after a successful build:

```bash
GROK_LIVEPATCH_REPLACE_BIN=1 ./scripts/check-and-patch.sh
```

State + logs: `~/.local/state/grok-build-livepatch/` (`last-result` may be `ok`, `noop`, `already-applied`, `needs-rebase`, or `fail`).

**Already-applied:** the watcher treats reverse-`git apply --check` success as idempotent success (exit 0). A bare forward `git apply --check` on an already-patched working tree is expected to fail and is **not** the ship gate — use a clean upstream clone for integrity checks.

## Musketeer / Grok scheduler (6h prompt)

If you prefer Grok-native scheduling (or [the-musketeer](https://github.com/search?q=the-musketeer) web bridge) instead of systemd:

```text
Every 6 hours: run the grok-build-livepatch watcher.

cd ~/Projects/grok-build-livepatch && ./scripts/check-and-patch.sh
Report: last-result, whether patch applied, whether cargo test banned_subagent passed.
If exit 2 (needs-rebase), open/refresh the livepatch-break issue and draft a rebased patch.
Do not spawn general-purpose or explore subagents while doing this.
```

In Grok Build TUI:

```text
/loop 6h cd ~/Projects/grok-build-livepatch && ./scripts/check-and-patch.sh; tail -20 ~/.local/state/grok-build-livepatch/watch.log
```

## GitHub Actions

`.github/workflows/watch-release.yml` runs on a **6h cron**, applies the patch to a fresh clone of `xai-org/grok-build`, runs `cargo test -p xai-tool-types banned_subagent`, and opens a `livepatch-break` issue if the patch no longer applies.

## Publish this repo (maintainers)

If `gh` is not logged in but SSH works (`ssh -T git@github.com` → `Hi VeigaPunk!`), create the public repo with a PAT then push over SSH. Exact steps: **[docs/PUBLISH.md](docs/PUBLISH.md)**. Helper: `GH_TOKEN=… ./scripts/publish.sh`.

## Marketplace-friendly layout

```
marketplace/   # plugin.json + install note; agents/ may be empty (no bundled agents)
patches/       # 0001-ban-generic-subagents.patch
scripts/       # check-and-patch.sh, install-timer.sh
systemd/       # user timer units
```

`marketplace/` is **metadata + install note only** — it does not ship specialist agents. `marketplace/agents/` can be empty. The livepatch itself is the parent repo (`scripts/`, `patches/`, timer). Plugin discovery:

```bash
# optional: register local marketplace path / install plugin metadata
grok plugin marketplace add ./marketplace
# or
grok plugin install ./marketplace --trust
```

## Relation to xbgst

xbgst / xbrd godspeed walks should spawn **specialists** (`the-planner`, `scout`, `executor`, …), not Grok's generic built-ins. This livepatch enforces that at the **CLI validation layer**, not via a skill prompt.

## License

Patches against Apache-2.0 `xai-org/grok-build`. This packaging is **MIT OR Apache-2.0** (see [LICENSE-MIT](LICENSE-MIT) and [LICENSE-APACHE](LICENSE-APACHE)).
