#!/usr/bin/env python3
"""Tiny proxy that injects reasoning-strength system prompt into chat requests.

Listens on 8081, forwards to llama-server on 8080.
Only modifies /v1/chat/completions — everything else passes through untouched.

Error handling: upstream errors are passed through with their real status code
and body (not masked as 502), and logged to ~/.cache/llama-proxy.log so
failures are diagnosable after the fact.
"""

import http.server
import json
import os
import sys
import time
import urllib.request
import urllib.error

UPSTREAM = "http://127.0.0.1:8080"
LISTEN_PORT = 8081
DEFAULT_REASONING = "Reasoning strength: xhigh"
LOG_FILE = os.path.expanduser("~/.cache/llama-proxy.log")

HOP_BY_HOP = {"host", "connection", "proxy-connection", "keep-alive", "transfer-encoding"}


def log(msg: str):
    """Append a line to the proxy log file (crash-safe)."""
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}\n")
    except OSError:
        pass


class Proxy(http.server.BaseHTTPRequestHandler):
    # Silence the default per-request stderr logging
    def log_message(self, *args):
        pass

    def do_GET(self):
        self._proxy("GET")

    def do_POST(self):
        self._proxy("POST")

    def do_OPTIONS(self):
        self._proxy("OPTIONS")

    def _proxy(self, method):
        body = None
        content_length = int(self.headers.get("Content-Length", 0))
        if content_length > 0:
            body = self.rfile.read(content_length)

        # Inject reasoning strength into system prompt for chat completions
        if self.path.rstrip("/").endswith("/v1/chat/completions") and body:
            try:
                req = json.loads(body)
                messages = req.get("messages", [])

                sys_msg = next((m for m in messages if m.get("role") == "system"), None)
                prefix = f"{DEFAULT_REASONING}\n\n"

                if sys_msg:
                    content = sys_msg.get("content", "")
                    if not content.startswith(f"{DEFAULT_REASONING}"):
                        sys_msg["content"] = prefix + content
                else:
                    messages.insert(0, {"role": "system", "content": DEFAULT_REASONING})

                req["messages"] = messages
                body = json.dumps(req).encode("utf-8")
                self.headers["Content-Length"] = str(len(body))
            except (json.JSONDecodeError, KeyError, TypeError):
                pass  # forward as-is if we can't parse
                log(f"WARN: could not parse chat request body ({len(body)} bytes)")

        url = f"{UPSTREAM}{self.path}"
        upstream_req = urllib.request.Request(url, data=body, method=method)
        for k, v in self.headers.items():
            if k.lower() not in HOP_BY_HOP:
                upstream_req.add_header(k, v)

        try:
            resp = urllib.request.urlopen(upstream_req, timeout=300)
            payload = resp.read()
            self.send_response(resp.status)
            for k, v in resp.headers.items():
                if k.lower() not in HOP_BY_HOP:
                    self.send_header(k, v)
            self.end_headers()
            self.wfile.write(payload)
            log(f"OK {method} {self.path} -> {resp.status} ({len(payload)} bytes)")
        except urllib.error.HTTPError as e:
            # Upstream responded with an error — pass it through verbatim.
            error_body = e.read() if hasattr(e, "read") else b""
            log(f"UPSTREAM_ERROR {method} {self.path} -> {e.code} {error_body.decode('utf-8', 'replace')[:500]}")
            self.send_response(e.code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(error_body)
        except urllib.error.URLError as e:
            # Upstream unreachable — server likely down.
            log(f"UPSTREAM_DOWN {method} {self.path} -> {e.reason}")
            self.send_response(503)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "error": {
                    "code": 503,
                    "message": f"llama-server unreachable: {e.reason}",
                    "type": "upstream_down",
                }
            }).encode())
        except (TimeoutError, OSError) as e:
            log(f"UPSTREAM_TIMEOUT {method} {self.path} -> {e}")
            self.send_response(504)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "error": {"code": 504, "message": f"llama-server timeout: {e}", "type": "upstream_timeout"}
            }).encode())


if __name__ == "__main__":
    print(f"[proxy] LlamaBar proxy: 0.0.0.0:{LISTEN_PORT} → {UPSTREAM}")
    print(f"[proxy] Injecting '{DEFAULT_REASONING}' into system prompt")
    print(f"[proxy] Log: {LOG_FILE}")
    http.server.ThreadingHTTPServer(("127.0.0.1", LISTEN_PORT), Proxy).serve_forever()
