# Host install (timer + CLI ban)

Canonical packaging lives in this public repo. xbgst-stack may vendor a
`livepatch/` copy; prefer this checkout when both exist.

## One-shot (recommended)

```bash
cd ~/Projects/grok-build-livepatch   # or git clone …
chmod +x scripts/*.sh
./scripts/gates.sh                  # offline health
./scripts/check-and-patch.sh        # first build (network + cargo)
./scripts/install-timer.sh          # 6h timer → this ROOT; REPLACE_BIN=1 on unit
./scripts/install-timer.sh --status # ExecStart, ban_in_binary, active_cli
# after upgrades, keep marketplace/plugin copies aligned:
./scripts/sync-stack-livepatch.sh   # sync scripts + rewrite install-host + rebind timer
```

## Root resolution (`install-timer.sh`)

| Priority | When |
|----------|------|
| `GROK_LIVEPATCH_ROOT` | Explicit path with `scripts/check-and-patch.sh` |
| stamp file | Only if `GROK_LIVEPATCH_KEEP_STAMP=1` |
| script checkout | Directory of the `install-timer.sh` you ran |

Install **always** rewrites  
`~/.local/state/grok-build-livepatch/preferred-install-root`.

Reclaim after a plugin stole the unit:

```bash
cd ~/Projects/grok-build-livepatch && ./scripts/install-timer.sh
```

## xbgst-stack `install-host.sh`

Should prefer `$HOME/Projects/grok-build-livepatch` when present.
Force the stack copy with `GROK_LIVEPATCH_FORCE_STACK_LP=1`.

If install-host was rebased to marketplace-first, re-run Projects
`install-timer.sh` (SCRIPT_ROOT wins over a stale stamp).

## Active CLI

Unit defaults `Environment=GROK_LIVEPATCH_REPLACE_BIN=1` so
`~/.grok/bin/grok` → `~/.local/opt/grok-build-livepatch/grok`.
Opt out: set `REPLACE_BIN=0` on the user unit.

```bash
./scripts/install-timer.sh --link-bin   # manual symlink
./scripts/gates.sh                      # fails if install binary lacks ban string
```
