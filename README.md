# llama-bar

macOS menu bar app for managing local llama-server instances.

## Features

- Menu bar icon shows server status: ○ stopped, ◐ starting, ● running
- Auto-starts llama-server on launch (with proxy for reasoning injection)
- Shows uptime, tokens/s, and slot usage from Prometheus metrics
- Dings when model becomes ready
- Start/Stop/Quit controls in menu
- Registers as login item

## Quick start

```bash
cd llama-bar
./MenuBar/build.sh
open MenuBar/GlimmerBar.app
```

## Structure

- `MenuBar/` - Swift menu bar app
- `start.sh` / `stop.sh` / `status.sh` - Server control scripts
- `proxy.py` - Injects reasoning strength into OpenAI-compatible requests
- `launchd/` - Optional LaunchAgent for headless operation
- `BENCHMARK.md` - Performance benchmarks

## Configuration

Edit `start.sh` for your model path, port, and context size. The menu bar app will automatically launch the server on startup.
