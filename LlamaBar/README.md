# LlamaBar

Menu bar app for the local model server. Shows the status and the running model, e.g. `● Flash-Next Coder IQ1_M` (● running, ○ stopped, ◐ starting or generating).

## Build

```bash
./build.sh             # build LlamaBar.app (the old build stays if compilation fails)
./build.sh --relaunch  # build, quit the running LlamaBar, open the new one
```

`LlamaBar.app` is build output and is not committed. The app registers itself as a login item on first launch.

See [../AGENTS.md](../AGENTS.md) for how the app works and how to verify changes.
