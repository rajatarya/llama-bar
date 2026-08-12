---
title: Model Config-Driven Menu Bar
date: 2026-08-12
pr: https://github.com/rajatarya/llama-bar/pull/1
status: merged
---

# Plan: Model Config-Driven Menu Bar

## Goal
Make LlamaBar extensible to support multiple local models with per-model configuration, dynamic discovery via `llama-server --cache-list`, and optional proxy injection for reasoning models.

## Design Principles
- **Minimal complexity**: Config file + dynamic discovery, no database
- **Maintainable**: One config file, one script, clear separation
- **Testable**: Unit tests for config parsing, model discovery, and menu generation

## Architecture

### 1. Config File: `models.json`
Location: `~/code/personal/llama-bar/models.json`

```json
{
  "default_model": "unsloth/Muse-Glimmer-30B-GGUF:BF16",
  "models": {
    "unsloth/Muse-Glimmer-30B-GGUF:BF16": {
      "name": "Muse-Glimmer-30B-BF16",
      "ctx_size": 262144,
      "ngl": 64,
      "batch_size": 256,
      "ubatch_size": 256,
      "needs_proxy": true,
      "proxy_injection": "Reasoning strength: xhigh",
      "description": "Coding and analysis, 30B BF16"
    },
    "unsloth/Qwen3.6-35B-A3B-GGUF:BF16": {
      "name": "Qwen3.6-35B-A3B",
      "ctx_size": 131072,
      "ngl": 64,
      "batch_size": 512,
      "ubatch_size": 512,
      "needs_proxy": false,
      "description": "General purpose"
    }
  }
}
```

### 2. Dynamic Model Discovery
- Script: `discover_models.sh`
- Runs `llama-server --cache-list`
- Parses output to get list of available models
- Cross-references with `models.json` config
- Only shows models that have config entries

### 3. Updated Scripts
- `start.sh` now accepts `--model <id>` argument
- Reads config for model-specific parameters
- Conditionally starts proxy if `needs_proxy: true`
- `stop.sh` unchanged

### 4. Menu Bar App Updates
- Read `models.json` on launch
- Run `discover_models.sh` to get available models
- Build menu dynamically:
  - Model submenu with available models
  - Shows current model, allows switching
  - Start/Stop controls
  - Status with uptime/tokens

### 5. Testing Strategy
- Unit tests for config parsing (JSON validation)
- Unit tests for model discovery parsing
- Unit tests for menu generation
- Integration test for start/stop with different models

## Files to Create/Modify

1. `models.json` - New config file
2. `discover_models.sh` - New discovery script
3. `start.sh` - Modify to accept model arg and read config
4. `LlamaBar/main.swift` - Rewrite to read config and discover models
5. `tests/` - New test directory
   - `test_config.py`
   - `test_discovery.py`
   - `test_menu.py`

## Implementation Steps

1. Create `models.json` with Glimmer config
2. Create `discover_models.sh`
3. Update `start.sh` to read config and accept model arg
4. Rewrite menu bar app to be config-driven
5. Add unit tests
6. Test with Glimmer + one other model
7. Update README

## Complexity Constraints
- No external dependencies beyond Swift stdlib and bash
- Config file is human-editable JSON
- No database, no network calls in menu bar app
- Tests run with `swift test` or `bash tests/`
