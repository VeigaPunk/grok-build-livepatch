# Musketeer + 6h livepatch task

[the-musketeer](file:///.codex/plugins/cache/ds4cc/the-musketeer) is a Grok **web UI** bridge (CDP + agent-browser). Use it when you want SuperGrok web to host the recurring check; otherwise prefer systemd or Grok Build `/loop`.

## Option A — Grok Build native (recommended)

In a durable Grok session (or orchestrator):

```
/loop 6h Run livepatch: bash ~/Projects/grok-build-livepatch/scripts/check-and-patch.sh ; echo EXIT:$? ; tail -30 ~/.local/state/grok-build-livepatch/watch.log
```

Cancel with `scheduler_delete` using the job id printed by `/loop`.

## Option B — Musketeer web bridge

1. Install musketeer adapter (`install.sh` from the plugin).
2. Paste this into SuperGrok on a recurring cadence (manual or browser automation):

```
You are the grok-build-livepatch watcher.
Shell: bash ~/Projects/grok-build-livepatch/scripts/check-and-patch.sh
If exit 2: report needs-rebase and summarize reject files.
If exit 0: report last-patched-version + last-result.
Never use subagent types general-purpose or explore.
```

## Option C — systemd (optional, always-on)

```bash
./scripts/install-timer.sh
journalctl --user -u grok-build-livepatch.service -n 50
```
