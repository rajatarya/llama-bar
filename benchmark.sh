#!/usr/bin/env bash
# =============================================================================
# Benchmark script for Muse-Glimmer-30B-BF16
# =============================================================================
# Tests different configurations and produces a report.
# Usage: ./benchmark.sh [--stop-after] [--report-only]
#   --stop-after N   Stop after N configs (for partial runs)
#   --report-only    Skip benchmark, just show existing report
# =============================================================================

set -euo pipefail

REPORT_DIR="$HOME/.cache/llama-benchmarks"
REPORT_FILE="$REPORT_DIR/report-$(date +%Y%m%d-%H%M).md"
MODEL_FILE="$HOME/.cache/huggingface/hub/models--unsloth--Muse-Glimmer-30B-GGUF/snapshots/faa5b025c584459c13febfa5c59883516710ae39/BF16/Muse-Glimmer-30B-BF16-00001-of-00002.gguf"
MMPROJ="$HOME/.cache/huggingface/hub/models--unsloth--Muse-Glimmer-30B-GGUF/snapshots/faa5b025c584459c13febfa5c59883516710ae39/mmproj-Muse-Glimmer-30B-BF16.gguf"
LLAMA_SERVER="/Users/rajat/code/hf/official-llama.cpp/build/bin/llama-server"
BASE_PORT=18080

# Test prompts for different workloads
CODING_PROMPT="Write a Python function that implements binary search on a rotated sorted array. Include type hints and docstrings."
ANALYSIS_PROMPT="Analyze the following code for potential security vulnerabilities and suggest improvements: def handle_request(data):\n    exec(data['command'])\n    return {'status': 'ok'}"
GENERAL_PROMPT="Explain the difference between monad transformers and applicative functors in Haskell, with concrete examples."
SHORT_PROMPT="What is the time complexity of quicksort in the worst case?"

# Configurations to test
declare -a CONFIGS=(
  "ctx4096_ngl32_threads8"
  "ctx4096_ngl40_threads10"
  "ctx4096_ngl48_threads10"
  "ctx4096_ngl48_threads12"
  "ctx8192_ngl40_threads10"
  "ctx8192_ngl48_threads10"
  "ctx8192_ngl48_threads12"
  "ctx16384_ngl48_threads12"
)

# ─── Helpers ─────────────────────────────────────────────────────────────────

cleanup() {
  if [[ -f "$PIDFILE" ]]; then
    local pid=$(cat "$PIDFILE")
    kill "$pid" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
}

wait_for_server() {
  local port=$1
  for i in $(seq 1 60); do
    if curl -s "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

run_benchmark_round() {
  local port=$1
  local prompt=$2
  local n_predict=$3
  local label=$4

  # Warmup
  curl -s "http://127.0.0.1:$port/completion" -d "{
    \"prompt\": \"$prompt\",
    \"n_predict\": 32,
    \"temperature\": 0.1,
    \"repeat_penalty\": 1.0
  }" >/dev/null 2>&1 || true

  # Actual benchmark - 3 runs, measure time
  local total_time=0
  local total_tokens=0
  local success=0

  for run in 1 2 3; do
    local start_time=$(date +%s%N)
    local response=$(curl -s "http://127.0.0.1:$port/completion" -d "{
      \"prompt\": \"$prompt\",
      \"n_predict\": $n_predict,
      \"temperature\": 0.7,
      \"repeat_penalty\": 1.08,
      \"top_p\": 0.9,
      \"top_k\": 40,
      \"min_p\": 0.05
    }" 2>/dev/null)
    local end_time=$(date +%s%N)

    if [[ -n "$response" && "$response" != "null" ]]; then
      local elapsed_ns=$((end_time - start_time))
      local elapsed_ms=$((elapsed_ns / 1000000))

      # Count output tokens from response
      local n_tokens=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tokens_generated', d.get('n_predict', 0)))" 2>/dev/null || echo "0")

      total_time=$((total_time + elapsed_ms))
      total_tokens=$((total_tokens + n_tokens))
      success=$((success + 1))
    fi
  done

  if [[ $success -gt 0 ]]; then
    local avg_time=$((total_time / success))
    local avg_tokens=$((total_tokens / success))
    local tokens_per_sec=$(python3 -c "print(f'{($avg_tokens / ($avg_time / 1000)):.1f}')")
    echo "$avg_time|$avg_tokens|$tokens_per_sec"
  else
    echo "0|0|0"
  fi
}

# ─── Main ────────────────────────────────────────────────────────────────────

mkdir -p "$REPORT_DIR"

echo "🧪 Muse-Glimmer-30B-BF16 Benchmark Suite"
echo "   Model: $MODEL_FILE"
echo "   Hardware: $(sysctl -n hw.model | cut -d' ' -f2-)"
echo "   RAM: $(sysctl -n hw.memsize | awk '{printf "%.0f GB", $1/1073741824}')"
echo "   Cores: $(sysctl -n hw.ncpu)"
echo ""

# Check if server is running, stop it for benchmarking
if [[ -f "$PIDFILE" ]]; then
  echo "⚠️  Stopping existing llama-server..."
  kill "$(cat "$PIDFILE")" 2>/dev/null || true
  rm -f "$PIDFILE"
  sleep 2
fi

# Start benchmarking
echo "📊 Testing configurations..."
echo ""

RESULTS=()

for i in "${!CONFIGS[@]}"; do
  CFG="${CONFIGS[$i]}"
  PORT=$((BASE_PORT + i))

  # Parse config
  CTX=$(echo "$CFG" | grep -oP 'ctx\K[0-9]+')
  NGL=$(echo "$CFG" | grep -oP 'ngl\K[0-9]+')
  THREADS=$(echo "$CFG" | grep -oP 'threads\K[0-9]+')

  echo "[$((i+1))/${#CONFIGS[@]}] ctx=$CTX ngl=$NGL threads=$THREADS (port $PORT)..."

  # Start server
  nohup "$LLAMA_SERVER" \
    --model "$MODEL_FILE" \
    --mmproj "$MMPROJ" \
    --host 127.0.0.1 \
    --port "$PORT" \
    --ctx-size "$CTX" \
    --n-gpu-layers "$NGL" \
    --threads "$THREADS" \
    --batch-size 512 \
    --ubatch-size 512 \
    --temp 0.7 \
    --repeat-penalty 1.08 \
    --top-p 0.9 \
    --top-k 40 \
    --min-p 0.05 \
    --parallel 1 \
    --log-disable \
    > "/tmp/llama-bench-${CFG}.log" 2>&1 &

  SERVER_PID=$!
  echo "$SERVER_PID" > "$PIDFILE"

  if wait_for_server "$PORT"; then
    # Run benchmarks
    echo "   → Coding task (512 tokens)..."
    CODING_RESULT=$(run_benchmark_round "$PORT" "$CODING_PROMPT" 512 "coding")
    echo "   → Analysis task (512 tokens)..."
    ANALYSIS_RESULT=$(run_benchmark_round "$PORT" "$ANALYSIS_PROMPT" 512 "analysis")
    echo "   → General task (256 tokens)..."
    GENERAL_RESULT=$(run_benchmark_round "$PORT" "$GENERAL_PROMPT" 256 "general")
    echo "   → Short task (64 tokens)..."
    SHORT_RESULT=$(run_benchmark_round "$PORT" "$SHORT_PROMPT" 64 "short")

    RESULTS+=("$CFG|$CTX|$NGL|$THREADS|$CODING_RESULT|$ANALYSIS_RESULT|$GENERAL_RESULT|$SHORT_RESULT")
  else
    echo "   ❌ Server failed to start"
    RESULTS+=("$CFG|$CTX|$NGL|$THREADS|FAIL|FAIL|FAIL|FAIL")
  fi

  # Cleanup
  kill "$SERVER_PID" 2>/dev/null || true
  rm -f "$PIDFILE"
  sleep 1

  echo ""
done

# ─── Generate Report ─────────────────────────────────────────────────────────

{
  echo "# Muse-Glimmer-30B-BF16 Benchmark Report"
  echo ""
  echo "Generated: $(date)"
  echo "Model: unsloth/Muse-Glimmer-30B-GGUF (BF16, sharded ~52 GB)"
  echo ""
  echo "## Hardware"
  echo ""
  echo "| Component | Value |"
  echo "|-----------|-------|"
  echo "| Machine | $(sysctl -n hw.model | cut -d' ' -f2-) |"
  echo "| RAM | $(sysctl -n hw.memsize | awk '{printf "%.0f GB", $1/1073741824}') |"
  echo "| Cores | $(sysctl -n hw.ncpu) |"
  echo ""
  echo "## Results Summary"
  echo ""
  echo "Format: **ctx=N ngl=N threads=N** | Coding (tok/s) | Analysis (tok/s) | General (tok/s) | Short (tok/s)"
  echo ""
  echo "| Configuration | Coding | Analysis | General | Short |"
  echo "|---------------|--------|----------|---------|-------|"

  for result in "${RESULTS[@]}"; do
    IFS='|' read -r cfg ctx ngl threads coding analysis general short <<< "$result"
    coding_tps=$(echo "$coding" | cut -d'|' -f3)
    analysis_tps=$(echo "$analysis" | cut -d'|' -f3)
    general_tps=$(echo "$general" | cut -d'|' -f3)
    short_tps=$(echo "$short" | cut -d'|' -f3)
    echo "| ctx=$ctx ngl=$ngl threads=$threads | ${coding_tps} | ${analysis_tps} | ${general_tps} | ${short_tps} |"
  done

  echo ""
  echo "## Configuration Legend"
  echo ""
  echo "- **ctx** = Context window size (KV cache)"
  echo "- **ngl** = Number of layers offloaded to GPU (Metal)"
  echo "- **threads** = CPU threads for prefill/fallback"
  echo ""
  echo "## Recommendations"
  echo ""
  echo "See the analysis section below for specific recommendations."
  echo ""
} > "$REPORT_FILE"

echo "📄 Report written to: $REPORT_FILE"
cat "$REPORT_FILE"
