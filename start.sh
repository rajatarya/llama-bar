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
# Absolute default: launchd's PATH does not include ~/.local/bin.
MTPLX_BIN="${MTPLX_BIN:-$HOME/.local/bin/mtplx}"
MTPLX_MODELS_DIR="${MTPLX_MODELS_DIR:-$HOME/.mtplx/models}"
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

# ─── Load config (overrides only; model list comes from the cache) ─────────
if [[ -z "$MODEL_ID" ]]; then
  if [[ -f "$CONFIG_FILE" ]]; then
    MODEL_ID=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('default_model',''))")
  fi
fi
if [[ -z "$MODEL_ID" ]]; then
  echo "❌ No model specified and no default_model in $CONFIG_FILE"
  exit 1
fi

# Model config is optional tuning overrides; absent → empty (fit-params defaults).
MODEL_CONFIG=$(MODEL_ID="$MODEL_ID" CONFIG_FILE="$CONFIG_FILE" python3 -c "
import json, os
path = os.environ['CONFIG_FILE']
cfg = json.load(open(path)) if os.path.exists(path) else {}
print(json.dumps(cfg.get('models', {}).get(os.environ['MODEL_ID'], {})))
")

# Parse config values (via env var to avoid shell-escaping issues). Empty
# ctx_size/ngl signal "compute with llama-fit-params at launch".
export MODEL_CONFIG MODEL_ID
IFS='|' read -r -d '' -a FIELDS < <(python3 -c "
import json, os
m = json.loads(os.environ['MODEL_CONFIG'])
fallback_name = os.environ['MODEL_ID'].split(':')[0].split('/')[-1]
vals = [m.get('name') or fallback_name, m.get('ctx_size', ''), m.get('ngl', ''),
        m.get('batch_size') or 256, m.get('ubatch_size') or 256,
        m.get('needs_proxy', False), m.get('proxy_injection') or '',
        m.get('draft_model') or '', m.get('spec_type') or '',
        m.get('reasoning') or '', m.get('chat_template_kwargs') or '',
        m.get('temp', ''), m.get('top_p', ''), m.get('top_k', ''),
        m.get('min_p', ''), m.get('presence_penalty', ''),
        m.get('repetition_penalty', ''),
        # Discovered MTPLX packs launch with mtplx even without a config entry.
        m.get('backend') or ('mtplx' if os.environ['MODEL_ID'].endswith(':MTPLX') else 'llamacpp')]
assert not any('|' in str(v) or '\n' in str(v) for v in vals), 'illegal delimiter in config value'
print('|'.join(str(v) for v in vals), end='')
") || true
MODEL_NAME=${FIELDS[0]:-} CTX_SIZE=${FIELDS[1]:-} NGL=${FIELDS[2]:-} BATCH_SIZE=${FIELDS[3]:-256} UBATCH_SIZE=${FIELDS[4]:-256} NEEDS_PROXY=${FIELDS[5]:-False} PROXY_INJECTION=${FIELDS[6]:-} DRAFT_MODEL=${FIELDS[7]:-} SPEC_TYPE=${FIELDS[8]:-} REASONING=${FIELDS[9]:-} TEMPLATE_KWARGS=${FIELDS[10]:-} TEMP=${FIELDS[11]:-} TOP_P=${FIELDS[12]:-} TOP_K=${FIELDS[13]:-} MIN_P=${FIELDS[14]:-} PRESENCE_PENALTY=${FIELDS[15]:-} REPETITION_PENALTY=${FIELDS[16]:-} BACKEND=${FIELDS[17]:-llamacpp}


# Apply short context override
if [[ "${SHORT_CTX_FLAG:-0}" -eq 1 ]]; then
  CTX_SIZE=$SHORT_CTX
fi

# ─── MTPLX backend: MLX pack served by `mtplx serve` on the same port ──────
# Packs live in MTPLX's own model store, not the HF cache. mtplx takes only the
# sampling/reasoning defaults below; min_p, penalties, template kwargs and
# DSpark are llama.cpp-only.
if [[ "$BACKEND" == "mtplx" ]]; then
  MTPLX_REPO="${MODEL_ID%%:*}"
  MODEL_DIR="$MTPLX_MODELS_DIR/${MTPLX_REPO//\//--}"
  if [[ ! -d "$MODEL_DIR" ]]; then
    echo "❌ MTPLX pack not installed: $MODEL_DIR (run: mtplx pull $MTPLX_REPO --json)"
    exit 1
  fi
  SERVER_CMD=("$MTPLX_BIN" serve --model "$MTPLX_REPO" --host "$HOST" --port "$PORT" --no-auth --yes
    ${CTX_SIZE:+--context-window "$CTX_SIZE"}
    ${REASONING:+--reasoning "$REASONING"}
    ${TEMP:+--temperature "$TEMP"} ${TOP_P:+--top-p "$TOP_P"} ${TOP_K:+--top-k "$TOP_K"})
else
# ─── llama.cpp backend (unindented to keep the resolution logic diff-free) ──

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

# ─── Fit params to free memory (llama-fit-params) ─────────────────────────
# Models without explicit ctx_size/ngl in models.json get optimal values
# computed from live device memory at launch. llama-fit-params prints fitted
# "-c N -ngl M" args; it needs the first shard, which MODEL_FILE already is.
FIT_PARAMS=""
if [[ -z "$CTX_SIZE" || -z "$NGL" ]]; then
  FIT_BIN="$(dirname "$LLAMA_SERVER")/llama-fit-params"
  if [[ -x "$FIT_BIN" ]]; then
    FIT_PARAMS=$("$FIT_BIN" --model "$MODEL_FILE" 2>/dev/null | grep -E '^-c [0-9]+ -ngl (-?[0-9]+)$' || true)
  fi
  if [[ -z "$FIT_PARAMS" ]]; then
    echo "⚠️  llama-fit-params unavailable; using defaults ctx=8192 ngl=64" >&2
    FIT_PARAMS="-c 8192 -ngl 64"
  fi
  [[ -z "$CTX_SIZE" ]] && CTX_SIZE=$(echo "$FIT_PARAMS" | sed -E 's/^-c ([0-9]+).*/\1/')
  [[ -z "$NGL" ]] && NGL=$(echo "$FIT_PARAMS" | sed -E 's/.*-ngl (-?[0-9]+)$/\1/')
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

fi # ─── end llama.cpp backend ───────────────────────────────────────────────

# ─── Dry run: print resolved launch plan, launch nothing ───────────────────
if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
  echo "DRY-RUN model=$MODEL_ID"
  echo "BACKEND=$BACKEND"
  if [[ "$BACKEND" == "mtplx" ]]; then
    echo "MODEL_DIR=$MODEL_DIR"
    echo "CTX_SIZE=$CTX_SIZE"
    echo "PROXY=$NEEDS_PROXY"
    echo "REASONING=$REASONING TEMP=$TEMP TOP_P=$TOP_P TOP_K=$TOP_K"
    echo "COMMAND=${SERVER_CMD[*]}"
    exit 0
  fi
  echo "MODEL_FILE=$MODEL_FILE"
  echo "MMPROJ=$MMPROJ"
  echo "CTX_SIZE=$CTX_SIZE"
  echo "NGL=$NGL BATCH_SIZE=$BATCH_SIZE UBATCH_SIZE=$UBATCH_SIZE"
  echo "PROXY=$NEEDS_PROXY"
  echo "PROXY_INJECTION=$PROXY_INJECTION"
  echo "DRAFT_MODEL=$DRAFT_MODEL"
  echo "SPEC_TYPE=$SPEC_TYPE REASONING=$REASONING TEMPLATE=$TEMPLATE_KWARGS TEMP=$TEMP TOP_P=$TOP_P TOP_K=$TOP_K MIN_P=$MIN_P PRESENCE=$PRESENCE_PENALTY REPEAT=$REPETITION_PENALTY"
  echo "COMMAND=$LLAMA_SERVER --model $MODEL_FILE" \
       "${MMPROJ:+--mmproj $MMPROJ} --host $HOST --port $PORT" \
       "--ctx-size $CTX_SIZE --n-gpu-layers $NGL --threads 12" \
       "--batch-size $BATCH_SIZE --ubatch-size $UBATCH_SIZE --parallel 1 --flash-attn on" \
       "${DRAFT_MODEL:+--spec-draft-model $DRAFT_MODEL --spec-draft-n-max 3}" \
       "${SPEC_TYPE:+--spec-type $SPEC_TYPE}" \
       "${REASONING:+--reasoning $REASONING}" \
       "${TEMPLATE_KWARGS:+--chat-template-kwargs $TEMPLATE_KWARGS}" \
       "${TEMP:+--temp $TEMP} ${TOP_P:+--top-p $TOP_P} ${TOP_K:+--top-k $TOP_K} ${MIN_P:+--min-p $MIN_P} ${PRESENCE_PENALTY:+--presence-penalty $PRESENCE_PENALTY} ${REPETITION_PENALTY:+--repeat-penalty $REPETITION_PENALTY}" \
       "--reasoning-preserve --metrics"
  exit 0
fi

# ─── Pre-flight checks ──────────────────────────────────────────────────────
if [[ "$BACKEND" == "mtplx" ]]; then
  SERVER_LABEL="mtplx serve"
  if [[ ! -x "$MTPLX_BIN" ]]; then
    echo "❌ mtplx not found at $MTPLX_BIN (install: uv tool install mtplx)"
    exit 1
  fi
else
  SERVER_LABEL="llama-server"
  if [[ ! -x "$LLAMA_SERVER" ]]; then
    echo "❌ llama-server not found"
    exit 1
  fi
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
echo "   Backend:   $SERVER_LABEL"
echo "   Port:      $PORT"
echo "   Context:   ${CTX_SIZE:-default}"
echo "   Proxy:     $([[ $NEEDS_PROXY == True && $NO_PROXY -eq 0 ]] && echo 'on' || echo 'off')"
echo "   Reasoning: ${REASONING:-auto}"
if [[ "$BACKEND" == "mtplx" ]]; then
  echo "   Sampling:  ${TEMP:-default} / top-p ${TOP_P:-default} / top-k ${TOP_K:-default}"
  echo ""
  nohup "${SERVER_CMD[@]}" >> "$LOGFILE" 2>&1 &
else
echo "   GPU Lrs:   $NGL"
echo "   Batch:     $BATCH_SIZE / $UBATCH_SIZE"
echo "   DSpark:    $([[ -n $DRAFT_MODEL ]] && echo "on ($DRAFT_MODEL)" || echo 'off')"
echo "   Template:  ${TEMPLATE_KWARGS:-default}"
echo "   Sampling:  ${TEMP:-default} / top-p ${TOP_P:-default} / top-k ${TOP_K:-default} / min-p ${MIN_P:-default} / presence ${PRESENCE_PENALTY:-default} / rep-pen ${REPETITION_PENALTY:-default}"
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
  ${TOP_K:+--top-k "$TOP_K"} \
  ${MIN_P:+--min-p "$MIN_P"} \
  ${PRESENCE_PENALTY:+--presence-penalty "$PRESENCE_PENALTY"} \
  ${REPETITION_PENALTY:+--repeat-penalty "$REPETITION_PENALTY"} \
  --reasoning-preserve \
  --metrics \
  >> "$LOGFILE" 2>&1 &
fi

SERVER_PID=$!
echo "$SERVER_PID" > "$PIDFILE"

echo "⏳ Waiting for server (up to 15 min for large models)..."
READY=0
for i in $(seq 1 900); do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "❌ $SERVER_LABEL died during startup (PID $SERVER_PID). Last log lines:"
    tail -n 40 "$LOGFILE"
    rm -f "$PIDFILE"
    exit 1
  fi
  if curl -s -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    READY=1
    echo "✅ Server ready after ${i}s (PID $SERVER_PID, port $PORT)"
    break
  fi
  sleep 1
done

if [[ "$READY" -ne 1 ]]; then
  echo "❌ Server did not become healthy within 900s. Last log lines:"
  tail -n 40 "$LOGFILE"
  exit 1
fi

# Verify the model actually generates. /health responds while the model is
# still loading (chat returns 503 "Loading model"), so retry until a real
# completion comes back or we time out.
echo "🧪 Verifying model generation (retries while weights load)..."
VERIFIED=0
for i in $(seq 1 90); do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "❌ $SERVER_LABEL died while loading (PID $SERVER_PID). Last log lines:"
    tail -n 40 "$LOGFILE"
    rm -f "$PIDFILE"
    exit 1
  fi
  VERIFY=$(curl -s -m 120 -X POST "http://127.0.0.1:$PORT/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"local","messages":[{"role":"user","content":"Reply with exactly: ok"}],"max_tokens":8}' 2>&1)
  if echo "$VERIFY" | grep -q '"content"'; then
    VERIFIED=1
    ANSWER=$(echo "$VERIFY" | python3 -c "import json,sys; print(json.load(sys.stdin)['choices'][0]['message']['content'][:60])" 2>/dev/null || echo "?")
    echo "✅ Model verified after ~$((i*10))s — response: $ANSWER"
    break
  fi
  if ! echo "$VERIFY" | grep -q '503\|Loading model'; then
    # Not a loading-state response: real error, fail fast
    echo "❌ Verification request failed. Response:"
    echo "$VERIFY" | head -c 2000
    echo ""
    echo "Last log lines:"
    tail -n 40 "$LOGFILE"
    exit 1
  fi
  sleep 10
done

if [[ "$VERIFIED" -ne 1 ]]; then
  echo "❌ Model did not produce a completion within ~15 min. Last log lines:"
  tail -n 40 "$LOGFILE"
  exit 1
fi

# Launch proxy (always, unless --no-proxy): serves the full LlamaBar model
# catalog on /v1/models for client discovery, and injects reasoning strength
# into chat requests when the model needs it.
if [[ $NO_PROXY -eq 0 ]]; then
  # Update proxy with injection string
  if [[ "$NEEDS_PROXY" == True && -n "$PROXY_INJECTION" ]]; then
    # Create model-specific proxy config
    sed -i '' "s/DEFAULT_REASONING = \".*\"/DEFAULT_REASONING = \"$PROXY_INJECTION\"/" "$SCRIPT_DIR/proxy.py" 2>/dev/null || true
  fi
  nohup python3 "$SCRIPT_DIR/proxy.py" >> "$LOGFILE" 2>&1 &
  PROXY_PID=$!
  echo "$PROXY_PID" > "$PROXY_PIDFILE"
  echo "✅ Proxy ready! (PID $PROXY_PID, port $PROXY_PORT)"
  echo "   Pi connects to: http://127.0.0.1:$PROXY_PORT/v1"
else
  echo "   Proxy skipped (--no-proxy)"
  echo "   Direct: http://127.0.0.1:$PORT/v1"
fi
