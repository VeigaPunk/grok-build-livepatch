# grok-build-livepatch

Hard-ban Grok Build general-purpose/explore, hard-kill workflows, hard-kill foreign CLI settings clones (Cursor/Claude/Codex).

## Patches (applied in order)

| Patch | Effect |
|-------|--------|
| 0001-ban-generic-subagents.patch | GP/explore hard-ban at spawn |
| 0002-kill-workflows.patch | resolve_workflows() always false |
| 0003-kill-foreign-cli-compat.patch | resolve_compat_config() all cells false |

Native `.grok` / `.agents` discovery is unaffected.

## Install

```bash
git clone https://github.com/VeigaPunk/grok-build-livepatch.git
cd grok-build-livepatch
./scripts/check-and-patch.sh
./scripts/install-timer.sh --link-bin
```

Config: [docs/cli-config.toml](docs/cli-config.toml)

## License

MIT OR Apache-2.0
