#!/usr/bin/env bash
# =============================================================================
# llama-server launcher with model config support
# =============================================================================
# Usage:
#   ./start.sh                          # Start default model from config
#   ./start.sh --model <model-id>       # Start specific model
#   ./start.sh --list                   # List available models
#   ./start.sh --short                  # Lightweight context for current model
# =============================================================================

set -euo pipefail

# ─── Paths ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LLAMA_SERVER="/Users/rajat/code/hf/official-llama.cpp/build/bin/llama-server"
CONFIG_FILE="$SCRIPT_DIR/models.json"
PIDFILE="$HOME/.cache/llama-server.pid"
PROXY_PIDFILE="$HOME/.cache/llama-proxy.pid"
LOGFILE="$HOME/.cache/llama-server.log"

# ─── Default values ─────────────────────────────────────────────────────────
PORT=8080
PROXY_PORT=8081
HOST="127.0.0.1"
NO_PROXY=0
MODEL_ID=""
SHORT_CTX=8192

# ─── Parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)                MODEL_ID="$2";     shift 2 ;;
    --port)                 PORT="$2";         shift 2 ;;
    --short)                SHORT_CTX_FLAG=1;  shift 1 ;;
    --no-proxy)             NO_PROXY=1;        shift 1 ;;
    --list)                 LIST_MODE=1;       shift 1 ;;
    --help|-h)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --model ID        Model ID from config (default: from config)"
      echo "  --list            List available models"
      echo "  --short           Use lightweight context (8192)"
      echo "  --no-proxy        Skip proxy startup"
      echo "  --port PORT       Server port (default: 8080)"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ─── List mode ───────────────────────────────────────────────────────────────
if [[ "${LIST_MODE:-0}" -eq 1 ]]; then
  "$SCRIPT_DIR/discover_models.sh"
  exit 0
fi

# ─── Load config ─────────────────────────────────────────────────────────────
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "❌ Config file not found: $CONFIG_FILE"
  exit 1
fi

# Get default model if not specified
if [[ -z "$MODEL_ID" ]]; then
  MODEL_ID=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['default_model'])")
fi

# Get model config
MODEL_CONFIG=$(python3 -c "
import json
with open('$CONFIG_FILE') as f:
    cfg = json.load(f)
    model = cfg['models'].get('$MODEL_ID')
    if not model:
        print('ERROR: Model not found in config')
        exit(1)
    print(json.dumps(model))
")

if [[ "$MODEL_CONFIG" == *"ERROR"* ]]; then
  echo "❌ $MODEL_CONFIG"
  exit 1
fi

# Parse config values
MODEL_NAME=$(python3 -c "import json; print(json.loads('$MODEL_CONFIG')['name'])")
CTX_SIZE=$(python3 -c "import json; print(json.loads('$MODEL_CONFIG')['ctx_size'])")
NGL=$(python3 -c "import json; print(json.loads('$MODEL_CONFIG')['ngl'])")
BATCH_SIZE=$(python3 -c "import json; print(json.loads('$MODEL_CONFIG')['batch_size'])")
UBATCH_SIZE=$(python3 -c "import json; print(json.loads('$MODEL_CONFIG')['ubatch_size'])")
NEEDS_PROXY=$(python3 -c "import json; print(json.loads('$MODEL_CONFIG').get('needs_proxy', False))")
PROXY_INJECTION=$(python3 -c "import json; print(json.loads('$MODEL_CONFIG').get('proxy_injection', ''))")

# Apply short context override
if [[ "${SHORT_CTX_FLAG:-0}" -eq 1 ]]; then
  CTX_SIZE=$SHORT_CTX
fi

# Resolve model file path from HF cache
MODEL_FILE=$(python3 -c "
import os, json
model_id = '$MODEL_ID'
# Convert model ID to cache path
# unsloth/Muse-Glimmer-30B-GGUF:BF16 -> models--unsloth--Muse-Glimmer-30B-GGUF
parts = model_id.split(':')
repo = parts[0]
quant = parts[1] if len(parts) > 1 else 'Q4_K_M'
cache_base = os.path.expanduser('~/.cache/huggingface/hub')
# Find the model directory
import glob
pattern = os.path.join(cache_base, f'models--*')
matches = glob.glob(pattern)
# Simplified: assume model file is in BF16 or first subdir
# This is a simplification - in practice you'd need better resolution
print('$HOME/.cache/huggingface/hub/models--unsloth--Muse-Glimmer-30B-GGUF/snapshots/faa5b025c584459c13febfa5c59883516710ae39/BF16/Muse-Glimmer-30B-BF16-00001-of-00002.gguf')
" 2>/dev/null || echo "")

# For now, use hardcoded path for Glimmer (will be improved)
if [[ "$MODEL_ID" == *"Muse-Glimmer"* ]]; then
  MODEL_FILE="$HOME/.cache/huggingface/hub/models--unsloth--Muse-Glimmer-30B-GGUF/snapshots/faa5b025c584459c13febfa5c59883516710ae39/BF16/Muse-Glimmer-30B-BF16-00001-of-00002.gguf"
  MMPROJ="$HOME/.cache/huggingface/hub/models--unsloth--Muse-Glimmer-30B-GGUF/snapshots/faa5b025c584459c13febfa5c59883516710ae39/mmproj-Muse-Glimmer-30B-BF16.gguf"
fi

if [[ ! -f "$MODEL_FILE" ]]; then
  echo "❌ Model file not found: $MODEL_FILE"
  exit 1
fi

# ─── Pre-flight checks ──────────────────────────────────────────────────────
if [[ ! -x "$LLAMA_SERVER" ]]; then
  echo "❌ llama-server not found"
  exit 1
fi

if [[ -f "$PIDFILE" ]]; then
  OLD_PID=$(cat "$PIDFILE")
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "⚠️  Already running (PID $OLD_PID). Stop first: ./stop.sh"
    exit 1
  else
    rm -f "$PIDFILE"
  fi
fi

# ─── Launch ─────────────────────────────────────────────────────────────────
echo "🚀 Starting $MODEL_NAME..."
echo "   Model ID:  $MODEL_ID"
echo "   Port:      $PORT"
echo "   Context:   $CTX_SIZE"
echo "   GPU Lrs:   $NGL"
echo "   Batch:     $BATCH_SIZE / $UBATCH_SIZE"
echo "   Proxy:     $([[ $NEEDS_PROXY == True && $NO_PROXY -eq 0 ]] && echo 'on' || echo 'off')"
echo ""

nohup "$LLAMA_SERVER" \
  --model "$MODEL_FILE" \
  ${MMPROJ:+--mmproj "$MMPROJ"} \
  --host "$HOST" \
  --port "$PORT" \
  --ctx-size "$CTX_SIZE" \
  --n-gpu-layers "$NGL" \
  --threads 12 \
  --batch-size "$BATCH_SIZE" \
  --ubatch-size "$UBATCH_SIZE" \
  --parallel 1 \
  --flash-attn on \
  --reasoning-preserve \
  --metrics \
  --log-disable \
  >> "$LOGFILE" 2>&1 &

SERVER_PID=$!
echo "$SERVER_PID" > "$PIDFILE"

echo "⏳ Waiting for server..."
for i in $(seq 1 60); do
  if curl -s "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    echo "✅ Server ready! (PID $SERVER_PID, port $PORT)"
    break
  fi
  sleep 1
done

# Launch proxy if needed
if [[ "$NEEDS_PROXY" == True && $NO_PROXY -eq 0 ]]; then
  # Update proxy with injection string
  if [[ -n "$PROXY_INJECTION" ]]; then
    # Create model-specific proxy config
    sed -i '' "s/DEFAULT_REASONING = \".*\"/DEFAULT_REASONING = \"$PROXY_INJECTION\"/" "$SCRIPT_DIR/proxy.py" 2>/dev/null || true
  fi
  nohup python3 "$SCRIPT_DIR/proxy.py" >> "$LOGFILE" 2>&1 &
  PROXY_PID=$!
  echo "$PROXY_PID" > "$PROXY_PIDFILE"
  echo "✅ Proxy ready! (PID $PROXY_PID, port $PROXY_PORT)"
  echo "   Pi connects to: http://127.0.0.1:$PROXY_PORT/v1"
else
  echo "   Proxy skipped"
  echo "   Direct: http://127.0.0.1:$PORT/v1"
fi
