#!/usr/bin/env bash
# Discover available models from llama-server cache
# Outputs JSON array of model IDs that are both cached and configured

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/models.json"
LLAMA_SERVER="/Users/rajat/code/hf/official-llama.cpp/build/bin/llama-server"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "[]" 
  exit 0
fi

# Get cached models
CACHE_LIST=$($LLAMA_SERVER --cache-list 2>/dev/null | tail -n +2)

# Get configured models from JSON
CONFIGURED_MODELS=$(python3 -c "
import json, sys
with open('$CONFIG_FILE') as f:
    cfg = json.load(f)
    models = list(cfg.get('models', {}).keys())
    print(json.dumps(models))
")

# Find intersection
AVAILABLE=$(python3 -c "
import json, sys
cached = '''$CACHE_LIST'''.strip().split('\n')
cached = [line.strip().split('. ', 1)[-1].strip() for line in cached if line.strip()]
configured = json.loads('''$CONFIGURED_MODELS''')
available = [m for m in configured if m in cached]
print(json.dumps(available))
")

echo "$AVAILABLE"
