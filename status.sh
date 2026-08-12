#!/usr/bin/env bash
# Status of llama-server
PIDFILE="$HOME/.cache/llama-server.pid"
LOGFILE="$HOME/.cache/llama-server.log"

if [[ -f "$PIDFILE" ]]; then
  PID=$(cat "$PIDFILE")
  if kill -0 "$PID" 2>/dev/null; then
    echo "✅ llama-server is running (PID $PID)"
    echo ""
    echo "--- Health Check ---"
    curl -s "http://127.0.0.1:8080/health" 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "(health check failed)"
    echo ""
    echo "--- Recent Log ---"
    tail -n 10 "$LOGFILE" 2>/dev/null || echo "(no log file)"
  else
    echo "❌ llama-server is NOT running (stale PID $PID)"
    rm -f "$PIDFILE"
  fi
else
  echo "❌ llama-server is NOT running (no PID file)"
fi
