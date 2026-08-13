---
title: Menu Bar Model Picker
date: 2026-08-12
status: in-progress
branch: feat/menu-bar-model-picker
---

# Plan: Menu Bar Model Picker

## Goal
Let the LlamaBar menu show the selection of locally configured models and switch between them — no terminal needed. Clicking a model starts it if stopped, or restarts the server with it if running.

## Why now
`start.sh` already supports `--model <id>` and `models.json` already holds per-model config (name, ctx, quant, proxy, sampling). The only missing piece is UI: `main.swift` hard-codes `Start → default_model`, has no model picker, and its pure logic is welded to AppKit (untestable). This plan extracts that logic, adds a model submenu, and makes switching testable end-to-end without launching a multi-GB model.

## Design Principles (from project conventions)
- **Config is the source of truth** — `models.json` defines what appears in the menu; `start.sh` validates files at launch. No new config file.
- **Zero new dependencies** — pure Swift logic compiled with `swiftc`, no SwiftPM, no frameworks.
- **Conciseness** — one new Swift file (~80 lines), one new bash flag, minimal diff to `main.swift`.
- **Testable** — pure logic is AppKit-free so `swiftc` tests can exercise it; `--dry-run` lets tests verify model resolution without launching servers.
- **No feature bloat** — switching = stop/start. No background polling, no per-model favorites, no download manager.

## Architecture

### 1. Pure logic layer: `LlamaBar/ModelLogic.swift` (new)
AppKit-free `import Foundation` only. Contents:

- `ModelConfig` / `ModelsConfig` Codable structs (moved out of `main.swift`). Unknown JSON keys (e.g. `draft_model`, `temp`) are ignored by Codable, so adding sampling keys later needs no Swift change.
- `ModelsConfig.load(from path:) -> ModelsConfig?` — reads + decodes `models.json`.
- `sortedModelIDs() -> [String]` — deterministic, name-sorted list for stable menu order.
- `modelId(forRunningPath:) -> String?` — the existing "match loaded model_path → config id by quant" logic, now pure.
- `displayTitle(for:) -> String` — the existing `Model: name • repo quant` formatting.
- `parseDiscoveredModels(_:) -> Set<String>` — parses `discover_models.sh` JSON array (kept for CLI/tests; **not** used to filter the menu, see Alternatives).
- `enum SwitchAction { none, start(String), restart(String) }` + `switchAction(selected:current:isRunning:)` — the decision: same model → nothing; stopped → start; running → stop+start.

### 2. Menu bar app: `LlamaBar/main.swift` (modified)
Keep the existing title/status/stats items, Start/Stop, health polling. Add:

```
LlamaBar
Model: Muse-Glimmer-30B Q4_K_M • bartowski Q4_K_M   (current model)
Running · up 12m 34s
12.3 tok/s
─────────────────────
Models                                    ← NEW submenu
    ✓ Muse-Glimmer-30B Q4_K_M
      Muse-Glimmer-30B Q5_K_M
      Muse-Glimmer-30B BF16
      DeepSeek-V4-Flash-0731 UD-Q2_K_XL   (tooltip = description)
─────────────────────
Start Server
Stop Server
─────────────────────
Quit
```

Behavior:
- Checkmark (`state = .on`) on `currentModelId` — the loaded model while running (synced from `/props`), last selection while stopped.
- Clicking a checked model: no-op. Clicking another: `switchAction` decides; restart runs `stop.sh; start.sh --model <id>` in one shell (sequential, no PID-file race).
- `Start Server` launches the **selected** model (was: `default_model`).
- Model items are disabled while state is `.starting` (no mid-boot switches).
- Submenu is rebuilt only when `currentModelId` or config changes (fingerprint) — avoids menu flicker during the 2s refresh loop.
- Tooltip on each model = its `description` from config.

### 3. Launcher: `start.sh` (modified)
Add a `--dry-run` flag: resolve everything (model file, mmproj, draft, sampling flags) and print the resolved launch plan, then exit 0. Placed after file resolution but before pre-flight checks, so tests get real resolution without touching the running server, PID files, proxy, or `sed` on `proxy.py`.

## Data flow

```
models.json ──► ModelLogic.load ──► submenu items + display title
select(model) ─► switchAction(selected, current, isRunning)
   .start(id)    → bash: start.sh --model <id>
   .restart(id)  → bash: stop.sh; start.sh --model <id>
   .none         → refresh only
running server ─► /props model_path ─► modelId(forRunningPath:) ─► currentModelId (synced)
```

## Error handling
- Config missing/corrupt → menu shows no models, existing `Stopped` state (current behavior).
- Selected model files missing → `start.sh` fails loudly with `❌ Model file not found` (existing check, now reachable from the menu).
- Switching mid-start → ignored (items disabled).
- Unknown running model (not in config) → display keeps last known id, shows `Unknown` (existing behavior).

## Testing strategy
Match the repo's lightweight style: bash-run tests, no frameworks.

- `tests/test_model_logic.swift` (new) — Swift assertions over the real `models.json` + pure functions: config decodes, default resolves, quant matching (Q4/Q5/BF16/DeepSeek), unknown → nil, display formatting, switch decisions, deterministic ordering.
- `tests/test_start.py` (modified) — for **every** configured model: `start.sh --model <id> --dry-run` exits 0, reports a resolvable `MODEL_FILE` that exists on disk, and prints the launch plan. Also default-model dry-run + `--help` mentions the flag.
- `run_tests.sh` (new, repo root) — one command: `./run_tests.sh` runs config, discovery, start, and Swift logic tests; nonzero on any failure.
- Existing `test_config.py` / `test_discovery.py` stay untouched.
- Manual: build + open app; visual check left to the user (the live server is not disturbed by tests).

## Files
| Action | File | Why |
|---|---|---|
| Create | `docs/plans/feature-model-picker.md` | this plan |
| Create | `LlamaBar/ModelLogic.swift` | pure logic |
| Create | `tests/test_model_logic.swift` | Swift tests |
| Create | `run_tests.sh` | test runner |
| Modify | `LlamaBar/main.swift` | submenu + switching |
| Modify | `LlamaBar/build.sh` | compile both Swift files |
| Modify | `start.sh` | `--dry-run` |
| Modify | `tests/test_start.py` | dry-run coverage |

## Alternatives considered
- **Discovery-based filtering** (`discover_models.sh` decides menu items): rejected — `llama-server --cache-list` is fragile (misses DeepSeek because configured `UD-Q2_K_XL` ≠ cached `Q2_K_XL`; lists unrelated models). Config as source of truth is simpler and reliable.
- **SwiftPM package + XCTest**: rejected — adds a manifest and dependency graph to a single-file app for marginal test ergonomics; the repo convention is `swiftc` scripts.
- **Switch = stop only, user presses Start**: rejected — two clicks for one action; combined restart is one click and unambiguous.

## Implementation steps
1. Add `ModelLogic.swift` + `tests/test_model_logic.swift` (tests first), verify red → green via `swiftc`.
2. Add `--dry-run` to `start.sh` (+ help text); extend `tests/test_start.py`; verify.
3. Rewire `main.swift` (submenu, switching, selected-model Start); update `build.sh`; `./LlamaBar/build.sh` must compile.
4. Add `run_tests.sh`; run full suite until green.
5. Commit conventional messages per step; update README feature list.
