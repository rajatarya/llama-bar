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
    --dry-run)              DRY_RUN=1;         shift 1 ;;
    --list)                 LIST_MODE=1;       shift 1 ;;
    --help|-h)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --model ID        Model ID from config (default: from config)"
      echo "  --list            List available models"
      echo "  --short           Use lightweight context (8192)"
      echo "  --no-proxy        Skip proxy startup"
      echo "  --dry-run         Resolve + print launch plan, launch nothing"
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

# Parse config values (via env var to avoid shell-escaping issues)
export MODEL_CONFIG
MODEL_NAME=$(python3 -c "import json,os; print(json.loads(os.environ['MODEL_CONFIG'])['name'])")
CTX_SIZE=$(python3 -c "import json,os; print(json.loads(os.environ['MODEL_CONFIG'])['ctx_size'])")
NGL=$(python3 -c "import json,os; print(json.loads(os.environ['MODEL_CONFIG'])['ngl'])")
BATCH_SIZE=$(python3 -c "import json,os; print(json.loads(os.environ['MODEL_CONFIG'])['batch_size'])")
UBATCH_SIZE=$(python3 -c "import json,os; print(json.loads(os.environ['MODEL_CONFIG'])['ubatch_size'])")
NEEDS_PROXY=$(python3 -c "import json,os; print(json.loads(os.environ['MODEL_CONFIG']).get('needs_proxy', False))")
PROXY_INJECTION=$(python3 -c "import json,os; print(json.loads(os.environ['MODEL_CONFIG']).get('proxy_injection', ''))")
DRAFT_MODEL=$(python3 -c "import json,os; print(json.loads(os.environ['MODEL_CONFIG']).get('draft_model', ''))")
SPEC_TYPE=$(python3 -c "import json,os; print(json.loads(os.environ['MODEL_CONFIG']).get('spec_type', ''))")
REASONING=$(python3 -c "import json,os; print(json.loads(os.environ['MODEL_CONFIG']).get('reasoning', ''))")
TEMPLATE_KWARGS=$(python3 -c "import json,os; print(json.loads(os.environ['MODEL_CONFIG']).get('chat_template_kwargs', ''))")
TEMP=$(python3 -c "import json,os; print(json.loads(os.environ['MODEL_CONFIG']).get('temp', ''))")
TOP_P=$(python3 -c "import json,os; print(json.loads(os.environ['MODEL_CONFIG']).get('top_p', ''))")
MIN_P=$(python3 -c "import json,os; print(json.loads(os.environ['MODEL_CONFIG']).get('min_p', ''))")

# Apply short context override
if [[ "${SHORT_CTX_FLAG:-0}" -eq 1 ]]; then
  CTX_SIZE=$SHORT_CTX
fi

# Resolve model file path from HF cache by scanning for matching GGUF files
MODEL_FILE=""
MMPROJ=""
if [[ "$MODEL_ID" == *":BF16"* ]]; then
  # Sharded BF16: find all shards in the snapshot, build list
  MODELS_DIR=$(python3 -c "
import os
model_id = '$MODEL_ID'
repo = model_id.split(':')[0]
cache_base = os.path.expanduser('~/.cache/huggingface/hub')
# Convert repo to cache dir name: unsloth/Muse-Glimmer-30B-GGUF -> models--unsloth--Muse-Glimmer-30B-GGUF
cache_dir = os.path.join(cache_base, 'models--' + repo.replace('/', '--'))
print(cache_dir if os.path.isdir(cache_dir) else '')
")
  if [[ -n "$MODELS_DIR" ]]; then
    SNAP=$(ls -d "$MODELS_DIR"/snapshots/*/ | head -1)
    MODEL_FILE=$(find "$SNAP" -name "*.gguf" ! -name "*mmproj*" | sort | head -1)
    MMPROJ=$(find "$MODELS_DIR" -name "mmproj*" ! -name "*.incomplete" | head -1)
  fi
else
  # Match GGUF by quant. Single-file: prefer largest. Sharded (NNN-of-MMM):
  # llama.cpp requires the first shard to auto-discover the rest.
  MODEL_FILE=$(python3 -c "
import os, glob
model_id = '$MODEL_ID'
repo = model_id.split(':')[0]
quant = model_id.split(':')[1] if ':' in model_id else ''
cache_base = os.path.expanduser('~/.cache/huggingface/hub')
cache_dir = os.path.join(cache_base, 'models--' + repo.replace('/', '--'))
matches = []
for snap in glob.glob(os.path.join(cache_dir, 'snapshots', '*')):
    for f in glob.glob(os.path.join(snap, '**', '*.gguf'), recursive=True):
        if 'mmproj' in f.lower(): continue
        base = os.path.basename(f)
        if quant and quant.lower() in base.lower():
            matches.append(f)
first = next((f for f in matches if '-00001-of-' in os.path.basename(f)), '')
print(first if first else (max(matches, key=os.path.getsize) if matches else ''))
")
  MMPROJ=$(python3 -c "
import os, glob
model_id = '$MODEL_ID'
repo = model_id.split(':')[0]
cache_base = os.path.expanduser('~/.cache/huggingface/hub')
cache_dir = os.path.join(cache_base, 'models--' + repo.replace('/', '--'))
for snap in glob.glob(os.path.join(cache_dir, 'snapshots', '*')):
    for f in glob.glob(os.path.join(snap, '**', 'mmproj*'), recursive=True):
        if not f.endswith('.incomplete'):
            print(f); exit()
print('')
")
fi

if [[ ! -f "$MODEL_FILE" ]]; then
  echo "❌ Model file not found: $MODEL_FILE"
  exit 1
fi

# Resolve DSpark drafter (speculative decoding): 'auto' scans HF cache for a
# llama.cpp-standardized dflash GGUF (e.g. ...-dflash.gguf)
if [[ "$DRAFT_MODEL" == "auto" ]]; then
  DRAFT_MODEL=$(python3 -c "
import os, glob
cache = os.path.expanduser('~/.cache/huggingface/hub')
# Prefer llama.cpp-standardized drafter with a real vocab (mask token required
# by DSpark). GaelicThunder's 'mainline' file carries tokenizer.ggml.mask_token_id
# with gpt2 vocab; no-vocab drafters (tokenizer.ggml.model=none) fail silently.
cands = []
for snap in glob.glob(os.path.join(cache, 'models--*', 'snapshots', '*')):
    for f in glob.glob(os.path.join(snap, '**', '*.gguf'), recursive=True):
        if f.endswith('.incomplete'): continue
        if 'dflash' in os.path.basename(f).lower():
            cands.append(f)
if cands:
    cands.sort(key=lambda f: (0 if 'mainline' in os.path.basename(f).lower() else 1, os.path.getmtime(f)))
    print(cands[0])
")
fi
if [[ -n "$DRAFT_MODEL" && ! -f "$DRAFT_MODEL" ]]; then
  echo "⚠️  Draft model not found, continuing without DSpark: $DRAFT_MODEL"
  DRAFT_MODEL=""
fi

# ─── Dry run: print resolved launch plan, launch nothing ───────────────────
if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
  echo "DRY-RUN model=$MODEL_ID"
  echo "MODEL_FILE=$MODEL_FILE"
  echo "MMPROJ=$MMPROJ"
  echo "CTX_SIZE=$CTX_SIZE"
  echo "NGL=$NGL BATCH_SIZE=$BATCH_SIZE UBATCH_SIZE=$UBATCH_SIZE"
  echo "PROXY=$NEEDS_PROXY"
  echo "PROXY_INJECTION=$PROXY_INJECTION"
  echo "DRAFT_MODEL=$DRAFT_MODEL"
  echo "SPEC_TYPE=$SPEC_TYPE REASONING=$REASONING TEMPLATE=$TEMPLATE_KWARGS TEMP=$TEMP TOP_P=$TOP_P MIN_P=$MIN_P"
  echo "COMMAND=$LLAMA_SERVER --model $MODEL_FILE" \
       "${MMPROJ:+--mmproj $MMPROJ} --host $HOST --port $PORT" \
       "--ctx-size $CTX_SIZE --n-gpu-layers $NGL --threads 12" \
       "--batch-size $BATCH_SIZE --ubatch-size $UBATCH_SIZE --parallel 1 --flash-attn on" \
       "${DRAFT_MODEL:+--spec-draft-model $DRAFT_MODEL --spec-draft-n-max 3}" \
       "${SPEC_TYPE:+--spec-type $SPEC_TYPE}" \
       "${REASONING:+--reasoning $REASONING}" \
       "${TEMPLATE_KWARGS:+--chat-template-kwargs $TEMPLATE_KWARGS}" \
       "${TEMP:+--temp $TEMP} ${TOP_P:+--top-p $TOP_P} ${MIN_P:+--min-p $MIN_P}" \
       "--reasoning-preserve --metrics --log-disable"
  exit 0
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
echo "   DSpark:    $([[ -n $DRAFT_MODEL ]] && echo "on ($DRAFT_MODEL)" || echo 'off')"
echo "   Reasoning: ${REASONING:-auto}"
echo "   Template:  ${TEMPLATE_KWARGS:-default}"
echo "   Sampling:  ${TEMP:-default} / top-p ${TOP_P:-default} / min-p ${MIN_P:-default}"
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
  ${DRAFT_MODEL:+--spec-draft-model "$DRAFT_MODEL" --spec-draft-n-max 3} \
  ${SPEC_TYPE:+--spec-type "$SPEC_TYPE"} \
  ${REASONING:+--reasoning "$REASONING"} \
  ${TEMPLATE_KWARGS:+--chat-template-kwargs "$TEMPLATE_KWARGS"} \
  ${TEMP:+--temp "$TEMP"} \
  ${TOP_P:+--top-p "$TOP_P"} \
  ${MIN_P:+--min-p "$MIN_P"} \
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
