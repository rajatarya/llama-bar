# llama-bar

A macOS menu bar app for managing local llama-server instances with automatic startup, health monitoring, and reasoning injection proxy.

## What it does

**llama-bar** is a lightweight menu bar utility that lets you run, monitor, and control local Large Language Model servers directly from your macOS menu bar. It provides:

- **One-click start/stop** for llama-server instances
- **Visual status** with live uptime, tokens/sec, and slot usage
- **Automatic startup** on login
- **Reasoning proxy** that injects model-specific system prompts (e.g., "Reasoning strength: xhigh") so pi and other OpenAI-compatible clients work seamlessly with reasoning models
- **Health monitoring** with audible notification when model becomes ready

Perfect for developers running Muse-Glimmer, DeepSeek, or other local models for coding/analysis work.

## Features

### Menu Bar App
- ● Green dot = running, ○ grey = stopped, ◐ spinning = starting
- Click to open menu with start/stop/quit controls
- Live stats from Prometheus metrics endpoint
- Audible notification when model loads
- Auto-starts server on launch, registers as login item

### Server Management
- `start.sh` launches llama-server with optimal config (flash-attn, GPU layers, context size)
- `proxy.py` injects reasoning prompts transparently
- `stop.sh` / `status.sh` for control
- LaunchAgent support for headless operation

### Reusable Design
While built for Muse-Glimmer-30B-BF16, the setup is model-agnostic:
- Edit `start.sh` for your model path and parameters
- Update `proxy.py` if your model needs different system prompt injection
- Pi provider config in `~/.pi/agent/models.json` points to the proxy

## Quick Start

### Prerequisites
- macOS with Apple Silicon
- Swift toolchain (`swiftc`)
- llama.cpp built with Metal support
- Local model files (GGUF format)

### Build & Install
```bash
git clone <repo>
cd llama-bar
./LlamaBar/build.sh
open LlamaBar/GlimmerBar.app
```

The app auto-registers as a login item on first launch.

### Configure for your model
1. Edit `start.sh`:
   - `MODEL_FILE` path to your GGUF
   - `--ctx-size`, `--n-gpu-layers`, `--batch-size` for your hardware
2. Update `proxy.py` if your model needs different reasoning injection
3. Update `~/.pi/agent/models.json` to point to `http://localhost:8081/v1`

## Project Structure

```
llama-bar/
├── LlamaBar/              # Swift menu bar app
│   ├── main.swift        # Status item, menu, health checks
│   └── build.sh          # Compile to .app bundle
├── start.sh              # Launch llama-server + proxy
├── stop.sh               # Stop services
├── status.sh             # Health check
├── proxy.py              # Reasoning prompt injection
├── launchd/              # LaunchAgent for headless use
├── BENCHMARK.md          # Performance benchmarks
└── README.md
```

## Performance

Benchmarked on MacBook Pro M4 Max (128GB RAM):
- **10.3 tok/s** with Muse-Glimmer-30B-BF16
- 256K context with zero speed penalty
- 56.7GB RSS at max context
- `flash-attn=on` provides 5× speed multiplier

See `BENCHMARK.md` for full results.

## Requirements

- macOS 13+
- Apple Silicon (Metal)
- llama.cpp built with Metal support
- ~52GB RAM for 30B BF16 model

## License

Apache 2.0 — see [LICENSE](LICENSE)

## Why this exists

Running local LLMs is powerful but fiddly. This project makes it:
- **Persistent**: auto-starts on login
- **Visible**: always know if it's running
- **Usable**: pi and other tools work without manual prompt injection
- **Fast**: optimized for Apple Silicon

Built for personal use, released for anyone running local models on macOS.
