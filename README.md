# llama-bar

A macOS menu bar app for managing local llama-server instances with automatic startup, health monitoring, and reasoning injection proxy.

## What it does

**llama-bar** is a lightweight menu bar utility that lets you run, monitor, and control local Large Language Model servers directly from your macOS menu bar. It provides:

- **One-click start/stop** for llama-server instances
- **Model picker** — browse your locally configured models from the menu bar and switch with one click (stop + restart)
- **Visual status** with live uptime, tokens/sec, and slot usage
- **Automatic startup** on login
- **Reasoning proxy** that injects model-specific system prompts (e.g., "Reasoning strength: xhigh") so pi and other OpenAI-compatible clients work seamlessly with reasoning models
- **Health monitoring** with audible notification when model becomes ready

Perfect for developers running Muse-Glimmer, DeepSeek, or other local models for coding/analysis work.

## Features

### Menu Bar App
- The menu bar shows the status and the running model, e.g. `● Flash-Next Coder IQ1_M`: ● running, ○ stopped, ◐ starting up *or* generating (the glyph cycles while the model is generating). The label is the model's `short_name` from `models.json`.
- Click to open menu with start/stop/quit controls
- **Models ▸** submenu lists every model discovered in the HF cache and MTPLX store; ✓ marks the loaded model, clicking another one switches to it
- Live tok/s from the server's `/metrics` (llama.cpp Prometheus or MTPLX JSON)
- Audible notification when model loads
- Auto-starts server on launch, registers as login item

### Server Management
- `start.sh` launches llama-server with optimal config (flash-attn, GPU layers, context size), or `mtplx serve` for MTPLX packs
- `proxy.py` injects reasoning prompts transparently
- `stop.sh` / `status.sh` for control
- A LaunchAgent (`launchd/`) for headless use *without* the app. Don't install it alongside the app: it restarts the server every ~10 s, so Stop and model switches stop working.

### Backends: llama.cpp and MTPLX
Each model runs on one of two backends, both served on port 8080 behind the same proxy and menu:
- **llama.cpp** (default): GGUFs from the HF cache, ids like `unsloth/Qwen3.8-Flash-Next-GGUF:IQ4_XS`.
- **MTPLX**: [MTPLX](https://github.com/youssofal/MTPLX) packs (MLX weights + the model's native MTP heads for speculative decoding), ids like `Youssofal/Qwen3.8-Flash-Next-MTPLX-Optimized-Speed:MTPLX`. Installed packs (`mtplx list`) appear in the Models menu automatically. Install with `uv tool install mtplx` and add packs with `mtplx pull <repo> --json`.

In `models.json`, `"backend": "mtplx"` (paired with the `:MTPLX` id tag) selects MTPLX. MTPLX honours `ctx_size` (`--context-window`), `reasoning`, `temp`, `top_p`, `top_k`; `ngl`, batch sizes, `min_p`, penalties, `chat_template_kwargs` and DSpark drafts are llama.cpp-only. On an M5 Max, MTPLX runs Qwen3.8-Flash-Next at ~95 tok/s (4K context) vs ~47 for llama.cpp's IQ4_XS.

### Reusable Design
While built for Muse-Glimmer-30B-BF16, the setup is model-agnostic:
- Any GGUF downloaded into the HF cache shows up in the Models menu; `models.json` only holds per-model overrides
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
./LlamaBar/build.sh --relaunch   # builds LlamaBar/LlamaBar.app and (re)opens it
```

The app auto-registers as a login item on first launch.

### Configure for your model
1. Download the model into the HF cache, e.g. `hf download owner/repo --include "QUANT/*"`. It appears in the Models menu automatically.
2. Optionally add an entry to `models.json` for overrides: `short_name` (menu bar label), sampling, `ctx_size`/`ngl` (otherwise computed by `llama-fit-params` at launch). Check it with `./start.sh --dry-run --model owner/repo:QUANT`.
3. Set `default_model` to the model to start at login.
4. Update `proxy.py` if your model needs different reasoning injection, and point `~/.pi/agent/models.json` at `http://localhost:8081/v1`.

## Project Structure

```
llama-bar/
├── LlamaBar/              # Swift menu bar app
│   ├── main.swift        # Status item, menu, background polling
│   ├── ModelLogic.swift  # Pure config/switching/label logic (unit-testable)
│   ├── Shell.swift       # Subprocess runner with timeout (unit-testable)
│   └── build.sh          # Compile to .app bundle
├── run_tests.sh          # One-command test suite
├── start.sh              # Launch llama-server (or mtplx serve) + proxy
├── stop.sh               # Stop services
├── status.sh             # Health check
├── discover_models.sh    # List launchable models (HF cache + MTPLX)
├── proxy.py              # Reasoning prompt injection, /v1/models catalog
├── models.json           # Default model + per-model overrides
├── tests/                # Python + Swift tests
├── launchd/              # LaunchAgent for headless use (not with the app)
├── AGENTS.md             # Developer/agent guide
├── BENCHMARK.md          # Performance benchmarks
└── README.md
```

## Tests

```bash
./run_tests.sh
```

Runs config, discovery (including MTPLX pack merging), start.sh (including
`--dry-run` resolution of every model on both backends), proxy model matching,
the Swift model-logic and process-runner tests, and a type-check of the app.
See [AGENTS.md](AGENTS.md) for how the app works and how to verify changes.

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
