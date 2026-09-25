#!/usr/bin/env bash
# Stop the model server (llama-server or mtplx serve) + proxy
PIDFILE="$HOME/.cache/llama-server.pid"
PROXY_PIDFILE="$HOME/.cache/llama-proxy.pid"

stopped=0

# Wait for a PID to exit so a following start.sh gets the port and the
# (tens of GiB of) model memory back. MTPLX can take a few seconds to unwind.
wait_gone() {
  local pid=$1
  for _ in $(seq 1 60); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.5
  done
  echo "⚠️  PID $pid still running after 30s"
}

# Stop server
if [[ -f "$PIDFILE" ]]; then
  PID=$(cat "$PIDFILE")
  if kill -0 "$PID" 2>/dev/null; then
    kill "$PID"
    wait_gone "$PID"
    echo "✅ Stopped server (PID $PID)"
    stopped=1
  else
    echo "ℹ️  Server PID $PID not running"
  fi
  rm -f "$PIDFILE"
fi

# Stop proxy
if [[ -f "$PROXY_PIDFILE" ]]; then
  PID=$(cat "$PROXY_PIDFILE")
  if kill -0 "$PID" 2>/dev/null; then
    kill "$PID"
    echo "✅ Stopped proxy (PID $PID)"
    stopped=1
  else
    echo "ℹ️  Proxy PID $PID not running"
  fi
  rm -f "$PROXY_PIDFILE"
fi

if [[ $stopped -eq 0 ]]; then
  # Fallback: kill by name
  pkill -f "llama-server" 2>/dev/null && echo "✅ Stopped lingering llama-server"
  # Only LlamaBar's own mtplx server (port 8080), not other MTPLX sessions.
  # `mtplx serve` re-execs as `python -m mtplx.server.openai`, so match both.
  pkill -f "mtplx( serve|\.server\.openai) .*--port 8080" 2>/dev/null && echo "✅ Stopped lingering mtplx server"
  pkill -f "proxy.py" 2>/dev/null && echo "✅ Stopped lingering proxy"
fi
