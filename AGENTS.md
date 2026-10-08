# Agent Guide for llama-bar

LlamaBar runs one local LLM server on this Mac and shows it in the menu bar. A Swift menu bar app (no Xcode project, built with `swiftc`) drives shell scripts that start `llama-server` (llama.cpp) or `mtplx serve` (MLX) on port 8080, plus an OpenAI-compatible proxy on port 8081 that clients such as pi connect to.

`CLAUDE.md` links here. Keep agent guidance in this file.

## Components

| Path | Role |
| --- | --- |
| `LlamaBar/main.swift` | AppKit status item and menu. Polls the server on a background queue every 2 s and renders on the main thread. Not unit-tested. |
| `LlamaBar/ModelLogic.swift` | Pure, AppKit-free logic: `models.json` decoding, discovery parsing, running-model resolution, menu bar labels, tok/s and busy parsing, switch decisions. Unit-tested. |
| `LlamaBar/Shell.swift` | `runCapturing(_:timeout:)`, the only way the app runs a subprocess and reads its output. Unit-tested. |
| `LlamaBar/build.sh` | Compiles the three Swift files into `LlamaBar/LlamaBar.app` (ad-hoc signed, `LSUIElement`). `--relaunch` quits the running app and opens the new build. |
| `start.sh` | Resolves a model id to a GGUF (or MTPLX pack), computes `ctx`/`ngl` with `llama-fit-params` when unset, launches the server, waits for `/health` and a real completion, then starts the proxy. `--dry-run`, `--list`, `--model ID`. |
| `stop.sh` / `status.sh` | Stop server and proxy (waits for exit) / print status. |
| `discover_models.sh` | JSON array of launchable ids: `llama-server --cache-list` plus `mtplx list`. This, not `models.json`, defines the model menu. |
| `proxy.py` | :8081 → :8080. Injects a reasoning system prompt for `needs_proxy` models, serves `/v1/models` from the catalog, normalizes tool transcripts. |
| `models.json` | `default_model` plus optional per-model overrides (see below). |
| `launchd/` | Optional headless LaunchAgent. **Not installed**: it conflicts with the app (see Lifecycle). |
| `tests/`, `run_tests.sh` | Python tests for config, discovery, `start.sh`, proxy; Swift tests for `ModelLogic.swift` + `Shell.swift`; type-check of the whole app. |
| `docs/plans/` | Design notes for past features (frontmatter: title, date, status, PR). |

Untracked image-generation experiments live in the repo root (`imagegen.py`, `maskgen.py`, `maskpaint.py`, `add_hair.py`, `sd.sh`, `banks/`, `*.png`). They are unrelated to LlamaBar; leave them alone.

## Runtime

- **Ports:** 8080 is the model server, 8081 the proxy. Both belong to LlamaBar; use other ports for experiments.
- **State files:** `~/.cache/llama-server.pid`, `~/.cache/llama-proxy.pid`; logs `~/.cache/llama-server.log`, `~/.cache/llama-proxy.log` (both append forever, so old errors persist).
- **Model ids:** `owner/repo:QUANT` for a GGUF in the HF cache (`~/.cache/huggingface/hub`), `owner/repo:MTPLX` for an MTPLX pack in `~/.mtplx/models`.
- **Hard-coded paths:** the app assumes the repo is at `~/code/personal/llama-bar`; `start.sh` and `discover_models.sh` use `~/code/hf/official-llama.cpp/build/bin/llama-server`.
- **Memory:** a large model uses most of the 128 GB machine. Never start a second server to test while LlamaBar's is loaded; use `./start.sh --dry-run`.

### Lifecycle: the app owns the server

The app registers itself as a login item (`SMAppService`). On launch, if the server is down, it starts the selected model (`default_model` on first load). Menu Start/Stop/model switches run `start.sh` / `stop.sh`; a switch runs `stop.sh; start.sh --model ID` in one shell.

Do not load `launchd/com.llama-server.glimmer.plist` while the app is in use. With `KeepAlive` it re-runs `start.sh` every ~10 s forever: "Stop Server" never sticks (launchd restarts the default), a model switch can race it and come up as the default model, and `~/.cache/llama-server-launch.log` grows without bound. It is only for headless use without the app.

## How the app works

`main.swift` is top-level code: it builds the status item and menu, schedules a 2 s timer, calls `schedulePoll()`, and enters `app.run()`.

1. `schedulePoll()` (main thread) starts at most one poll. On `pollQueue` it curls `/health`, then `/metrics` and `/props` (llama-server) or `/health` (MTPLX) for `model_path`, and on demand runs `discover_models.sh`. It packs the results into a `Snapshot`.
2. `apply(_:)` (main thread) reloads `models.json` if its mtime changed, resolves the running model id, updates busy state and tok/s, and advances the `State` machine: `stopped` → `starting(target)` → `running`. While starting a switch, it waits until the server reports the *target* model, because the old model keeps answering until `stop.sh` lands.
3. `render()` sets the menu bar title (status glyph only — no model text) and the menu items.

Rules that keep the menu bar alive:

- **No I/O on the main thread.** Never call `runCapturing`, curl, or a script from `render`, `apply`, or a menu action. Menu actions launch scripts with `run(_:)` (fire and forget) and then call `schedulePoll()`.
- **Never `waitUntilExit()`.** It spins the current run loop, so the 2 s timer re-enters the poll. Never read a pipe after waiting for exit: output above the 64 KB pipe buffer deadlocks the child (curl blocks writing a large MTPLX `/metrics` body). `runCapturing` drains the pipe while waiting on semaphores and kills the process at its timeout.
- **Nothing synchronous before `app.run()`.** The app only finishes launching, and the status item only appears, once `app.run()` starts.

**Running-model resolution** (`ModelsConfig.modelId(forRunningPath:candidates:)`): MTPLX reports its pack directory, matched exactly. llama-server reports the GGUF path; the `models--owner--repo` segment pins the repo, then the file name picks the quant (longest quant first). Several repos share quants (`Q8_0`, `Q4_K_M`), so never match by quant alone when the path is in the HF cache.

**Busy detection** (`/metrics`): llama.cpp's `requests_processing` gauge, else growth of `tokens_predicted_total`; for MTPLX, a change in the latest request's identity. The first poll after the server comes up is never busy.

## `models.json`

Entries are optional overrides; any discovered model can be launched without one. `ctx_size`, `ngl`, `batch_size`, `ubatch_size` must be positive integers when present (`tests/test_config.py`). A `backend` of `mtplx` must pair with an id ending `:MTPLX`.

| Field | Read by | Notes |
| --- | --- | --- |
| `name`, `short_name`, `description` | app, proxy | The menu bar shows only the status icon now; `short_name` survives as a display name in the dropdown/tooltip. Keep labels short: shared with the notch. |
| `ctx_size`, `ngl` | `start.sh` | Unset → `llama-fit-params` computes them at launch. Fit prints `-ngl -1` for "all layers"; pin `99` instead (the schema test rejects `-1`). |
| `batch_size`, `ubatch_size` | `start.sh` | Default 256. |
| `backend` | `start.sh`, app | `llamacpp` (default) or `mtplx`. MTPLX honours only `ctx_size`, `reasoning`, `temp`, `top_p`, `top_k`. |
| `reasoning`, `chat_template_kwargs`, `temp`, `top_p`, `top_k`, `min_p`, `presence_penalty`, `repetition_penalty` | `start.sh` | Passed to llama-server as defaults. |
| `draft_model`, `spec_type` | `start.sh` | DSpark speculative decoding; `auto` scans the cache for a `dflash` GGUF. |
| `needs_proxy`, `proxy_injection` | `start.sh`, proxy | `start.sh` rewrites `DEFAULT_REASONING` in `proxy.py` **in place**, so `proxy.py` can show as modified in git after a launch. Don't commit that edit. |

To add a model, download it into the HF cache (`hf download owner/repo --include "QUANT/*"` plus any `mmproj-*`). It then appears in the menu automatically. Add a `models.json` entry only for overrides, and check it with `./start.sh --dry-run --model ID`.

Some HF-cache entries are symlinks that look broken but aren't: hand-made shims into `~/code/hf/models`, or (hf-xet ≥ 1.7) links into the shared `~/.cache/huggingface/hub/blobs/` store. `readlink -f` before deleting anything.

## Build, test, run

Run from the repository root.

| Command | Purpose |
| --- | --- |
| `./run_tests.sh` | All tests, including the app type-check. Run before every commit. |
| `./LlamaBar/build.sh --relaunch` | Build the app and replace the running one. A failed compile leaves the old app in place. |
| `./start.sh --dry-run [--model ID]` | Print the resolved launch command without launching anything. |
| `./start.sh --list` | Print discovered model ids. |
| `./stop.sh && ./start.sh --model ID` | Switch models from the shell, as the menu does. |

The Python tests are integration tests against this machine: they read the real `models.json` and run `discover_models.sh` and `start.sh --dry-run` against the local HF cache and MTPLX store. A model removed from the cache can fail them without a code change.

`LlamaBar/LlamaBar.app` is build output and is gitignored. Do not commit it.

### Verifying an app change

Unit tests don't cover `main.swift`, so check the running app:

- **Menu bar:** `screencapture -x -R <x>,0,<w>,34 /tmp/menubar.png`, then look at the image. On macOS 26 every status item is drawn by Control Center, so `CGWindowListCopyWindowInfo` shows no windows for LlamaBar even when its item is visible. Don't use window lists to decide whether the item exists.
- **Main thread:** `sample $(pgrep -x LlamaBar) 1`. The main thread should sit in `-[NSApplication run]` → `_DPSNextEvent`. A main thread blocked under `schedulePoll`/`apply`/`render`, or stuck before `NSApplication run`, is a regression.
- **Children:** `pgrep -lP $(pgrep -x LlamaBar)` should show nothing or a curl that is seconds old. Long-lived curls mean a pipe or timeout bug.
- **Busy spinner:** send a long completion to :8081 and screenshot the menu bar while it generates.

## Conventions

- One branch and PR per change against `main` on `rajatarya/llama-bar`. Larger features get a plan in `docs/plans/`.
- Put new pure logic in `ModelLogic.swift` (or `Shell.swift` for process handling) with tests in `tests/test_model_logic.swift`. Keep both files AppKit-free so the tests compile without the app.
- When `start.sh` grows a `models.json` field, add it to the table above, and to `ModelConfig` if the app needs it.
