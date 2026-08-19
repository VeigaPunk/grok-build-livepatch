# grok-build-livepatch (plugin)

Metadata + install note only. **`agents/` may be empty** — this package does not ship specialist agents.

Install the watcher from the **parent** repo:

```bash
git clone https://github.com/VeigaPunk/grok-build-livepatch.git
cd grok-build-livepatch
./scripts/install-timer.sh   # optional timer wiring if you want scheduled re-apply
```

`plugin.json` exists so `grok plugin install` / marketplace add can discover the package; the livepatch scripts and patch live one level up.
