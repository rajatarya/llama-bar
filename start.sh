#!/usr/bin/env bash
# =============================================================================
# llama-server launcher for Muse-Glimmer-30B-BF16
# =============================================================================
# Benchmarked 2025-08-11: ~10.3 tok/s. See BENCHMARK.md for full results.
#
# IMPORTANT: Sampling params (temp, top_p, top_k) are CLIENT-SIDE.
# Official recommendation: temp=1.0, top_p=0.95, top_k=64
# Must use /v1/chat/completions endpoint with system prompt:
#   {"role": "system", "content": "Reasoning strength: xhigh"}
#
# Usage:
#   ./start.sh                  # Maxed out (ctx=262144, xhigh recommended)
#   ./start.sh --short          # Lightweight (ctx=8192)
#   ./start.sh --ctx 65536      # Custom context size
#   ./start.sh --port 9000      # Custom port
# =============================================================================

set -euo pipefail

# ─── Paths ───────────────────────────────────────────────────────────────────
LLAMA_SERVER="/Users/rajat/code/hf/official-llama.cpp/build/bin/llama-server"
MODEL_DIR="$HOME/.cache/huggingface/hub/models--unsloth--Muse-Glimmer-30B-GGUF/snapshots/faa5b025c584459c13febfa5c59883516710ae39/BF16"
MODEL_FILE="$MODEL_DIR/Muse-Glimmer-30B-BF16-00001-of-00002.gguf"
MMPROJ="$HOME/.cache/huggingface/hub/models--unsloth--Muse-Glimmer-30B-GGUF/snapshots/faa5b025c584459c13febfa5c59883516710ae39/mmproj-Muse-Glimmer-30B-BF16.gguf"
PIDFILE="$HOME/.cache/llama-server.pid"
PROXY_PIDFILE="$HOME/.cache/llama-proxy.pid"
LOGFILE="$HOME/.cache/llama-server.log"

# ─── Server defaults ────────────────────────────────────────────────────────
CTX_SIZE=262144
SHORT_CTX=8192
NGL=64
THREADS=12
BATCH_SIZE=256
UBATCH_SIZE=256
FLASH_ATTN="on"
PORT=8080
PROXY_PORT=8081
HOST="127.0.0.1"
NO_PROXY=0

# ─── Parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctx|--ctx-size)       CTX_SIZE="$2";     shift 2 ;;
    --ngl|--n-gpu-layers)   NGL="$2";          shift 2 ;;
    --threads)              THREADS="$2";      shift 2 ;;
    --port)                 PORT="$2";         shift 2 ;;
    --batch-size)           BATCH_SIZE="$2";   shift 2 ;;
    --ubatch-size)          UBATCH_SIZE="$2";  shift 2 ;;
    --flash-attn)           FLASH_ATTN="$2";   shift 2 ;;
    --no-flash-attn)        FLASH_ATTN="off";  shift 1 ;;
    --no-proxy)            NO_PROXY=1;         shift 1 ;;
    --help|-h)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Muse-Glimmer-30B-BF16 server (~10.3 tok/s, 256K ctx default):"
      echo "  --ctx SIZE        Context size (default: 262144, min: 8192)"
      echo "  --short           Alias for --ctx 8192"
      echo "  --ngl LAYERS      GPU layers (default: 64, don't go below 56)"
      echo "  --threads N       CPU threads (default: 12)"
      echo "  --port PORT       Server port (default: 8080)"
      echo "  --batch-size N    Batch size (default: 256, tuned for 256K ctx)"
      echo "  --ubatch-size N   Micro-batch size (default: 256)"
      echo ""
      echo "Client-side (set in request, not here):"
      echo "  temp=1.0, top_p=0.95, top_k=64"
      echo "  System prompt: Reasoning strength: xhigh (model card recommendation)"
      echo ""
      echo "Stop:    ./stop.sh"
      echo "Status:  ./status.sh"
      echo "Report:  cat BENCHMARK.md"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ─── Pre-flight checks ──────────────────────────────────────────────────────
if [[ ! -x "$LLAMA_SERVER" ]]; then
  echo "❌ llama-server not found at: $LLAMA_SERVER"
  echo "   Build: cd ~/code/hf/official-llama.cpp && cmake -B build && cmake --build build --config Release"
  exit 1
fi

if [[ ! -f "$MODEL_FILE" ]]; then
  echo "❌ Model file not found: $MODEL_FILE"
  exit 1
fi

if [[ -f "$PIDFILE" ]]; then
  OLD_PID=$(cat "$PIDFILE")
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "⚠️  Already running (PID $OLD_PID on port $PORT). Stop: ./stop.sh"
    exit 1
  else
    rm -f "$PIDFILE"
  fi
fi

# ─── Launch ─────────────────────────────────────────────────────────────────
echo "🚀 Starting Muse-Glimmer-30B-BF16 server..."
echo "   Port:      $PORT"
echo "   Context:   $CTX_SIZE"
echo "   GPU Lrs:   $NGL / 64"
echo "   Threads:   $THREADS"
echo "   Batch:     $BATCH_SIZE / $UBATCH_SIZE"
echo "   FlashAttn: $FLASH_ATTN"
echo "   Log:       $LOGFILE"
echo ""
echo "   ⚠️  Sampling: temp=1.0, top_p=0.95, top_k=64 (client-side)"
echo "   ⚠️  Model card recommends: Reasoning strength: xhigh for coding"
echo ""

nohup "$LLAMA_SERVER" \
  --model "$MODEL_FILE" \
  --mmproj "$MMPROJ" \
  --host "$HOST" \
  --port "$PORT" \
  --ctx-size "$CTX_SIZE" \
  --n-gpu-layers "$NGL" \
  --threads "$THREADS" \
  --batch-size "$BATCH_SIZE" \
  --ubatch-size "$UBATCH_SIZE" \
  --parallel 1 \
  --flash-attn "$FLASH_ATTN" \
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

# ─── Launch proxy ───────────────────────────────────────────────────────────
if [[ $NO_PROXY -eq 0 ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  nohup python3 "$SCRIPT_DIR/proxy.py" >> "$LOGFILE" 2>&1 &
  PROXY_PID=$!
  echo "$PROXY_PID" > "$PROXY_PIDFILE"
  echo "✅ Proxy ready! (PID $PROXY_PID, port $PROXY_PORT)"
  echo "   Injects: Reasoning strength: xhigh"
  echo ""
  echo "   Pi connects to: http://127.0.0.1:$PROXY_PORT/v1"
  echo "   Direct:          http://127.0.0.1:$PORT/v1"
  echo "   API docs:        http://127.0.0.1:$PORT/docs"
else
  echo "   (proxy skipped — use /v1/chat/completions directly)"
  echo "   Remember: include Reasoning strength: xhigh in system prompt!"
fi
