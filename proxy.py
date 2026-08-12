#!/usr/bin/env python3
"""Tiny proxy that injects reasoning-strength system prompt for Muse-Glimmer.

Listens on 8081, forwards to llama-server on 8080.
Only modifies /v1/chat/completions — everything else passes through untouched.
"""

import http.server
import json
import urllib.request
import sys

UPSTREAM = "http://127.0.0.1:8080"
LISTEN_PORT = 8081
DEFAULT_REASONING = "xhigh"


class Proxy(http.server.BaseHTTPRequestHandler):
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

                # Find or create system message
                sys_msg = next((m for m in messages if m.get("role") == "system"), None)
                prefix = f"Reasoning strength: {DEFAULT_REASONING}\n\n"

                if sys_msg:
                    content = sys_msg.get("content", "")
                    if not content.startswith("Reasoning strength:"):
                        sys_msg["content"] = prefix + content
                else:
                    messages.insert(0, {"role": "system", "content": prefix.strip()})

                req["messages"] = messages
                body = json.dumps(req).encode("utf-8")
                self.headers["Content-Length"] = str(len(body))
            except (json.JSONDecodeError, KeyError):
                pass  # forward as-is if we can't parse

        url = f"{UPSTREAM}{self.path}"
        req = urllib.request.Request(url, data=body, method=method)

        # Copy headers except hop-by-hop
        skip = {"host", "connection", "proxy-connection", "keep-alive", "transfer-encoding"}
        for k, v in self.headers.items():
            if k.lower() not in skip:
                req.add_header(k, v)

        try:
            resp = urllib.request.urlopen(req, timeout=300)
            self.send_response(resp.status)
            for k, v in resp.headers.items():
                if k.lower() not in skip:
                    self.send_header(k, v)
            self.end_headers()
            self.wfile.write(resp.read())
        except Exception as e:
            self.send_response(502)
            self.end_headers()
            self.wfile.write(json.dumps({"error": str(e)}).encode())

    def log_message(self, format, *args):
        # Only log chat completions
        if "/v1/chat/completions" in (args[0] if args else ""):
            print(f"[proxy] {args[0]}", file=sys.stderr)


if __name__ == "__main__":
    print(f"[proxy] Muse-Glimmer proxy: 0.0.0.0:{LISTEN_PORT} → {UPSTREAM}")
    print(f"[proxy] Injecting 'Reasoning strength: {DEFAULT_REASONING}' into system prompt")
    http.server.HTTPServer(("127.0.0.1", LISTEN_PORT), Proxy).serve_forever()
