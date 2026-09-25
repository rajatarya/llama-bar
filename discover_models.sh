#!/usr/bin/env bash
# Discover models LlamaBar can launch: every model in the HF cache (llama.cpp)
# plus every installed MTPLX pack. Outputs a JSON array of model IDs
# ("repo:QUANT", or "repo:MTPLX" for MTPLX packs). models.json only decorates
# these with tuning overrides; it no longer gates what is advertised.

set -euo pipefail

LLAMA_SERVER="${LLAMA_SERVER:-/Users/rajat/code/hf/official-llama.cpp/build/bin/llama-server}"
MTPLX_BIN="${MTPLX_BIN:-$HOME/.local/bin/mtplx}"

{
  if [[ -x "$LLAMA_SERVER" ]]; then
    "$LLAMA_SERVER" --cache-list 2>/dev/null | tail -n +2 | sed 's/^ *[0-9]*\. *//' || true
  fi
  # MTPLX packs (MLX weights + native MTP heads) are launched by start.sh with
  # `mtplx serve` instead of llama-server.
  if [[ -x "$MTPLX_BIN" ]]; then
    "$MTPLX_BIN" list --json 2>/dev/null | python3 -c "
import json, sys
try:
    models = json.load(sys.stdin).get('models', [])
except Exception:
    models = []
for m in models:
    if m.get('repo_id') and m.get('has_config', True):
        print(m['repo_id'] + ':MTPLX')
" || true
  fi
} | python3 -c "import sys, json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))"
