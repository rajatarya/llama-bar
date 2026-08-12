#!/usr/bin/env bash
# Stop llama-server + proxy
PIDFILE="$HOME/.cache/llama-server.pid"
PROXY_PIDFILE="$HOME/.cache/llama-proxy.pid"

stopped=0

# Stop server
if [[ -f "$PIDFILE" ]]; then
  PID=$(cat "$PIDFILE")
  if kill -0 "$PID" 2>/dev/null; then
    kill "$PID"
    echo "✅ Stopped llama-server (PID $PID)"
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
  pkill -f "proxy.py" 2>/dev/null && echo "✅ Stopped lingering proxy"
fi
