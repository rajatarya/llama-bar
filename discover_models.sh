#!/usr/bin/env bash
# Discover models available to llama-server: every model in the HF cache.
# Outputs a JSON array of model IDs ("repo:QUANT"). models.json only decorates
# these with tuning overrides; it no longer gates what is advertised.

set -euo pipefail

LLAMA_SERVER="${LLAMA_SERVER:-/Users/rajat/code/hf/official-llama.cpp/build/bin/llama-server}"

if [[ ! -x "$LLAMA_SERVER" ]]; then
  echo "[]"
  exit 0
fi

"$LLAMA_SERVER" --cache-list 2>/dev/null | tail -n +2 | sed 's/^ *[0-9]*\. *//' | grep -v '^$' |
  python3 -c "import sys, json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))"
