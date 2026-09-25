#!/usr/bin/env python3
"""Tiny proxy that injects reasoning-strength system prompt into chat requests.

Listens on 8081, forwards to llama-server on 8080.
Only modifies /v1/chat/completions — everything else passes through untouched.

/v1/models is served locally from models.json (the full LlamaBar catalog), so
clients like omp can discover every model LlamaBar offers — not just the one
currently loaded in llama-server. Each entry carries metadata under "llamabar"
(loaded / quant / ctx_size / reasoning) plus standard "context_length" and
"max_model_len" fields so OpenAI-compatible discovery picks up the context
window. The live llama-server id is appended
as an alias when reachable, so requests naming the on-disk path still route.

Error handling: upstream errors are passed through with their real status code
and body (not masked as 502), and logged to ~/.cache/llama-proxy.log so
failures are diagnosable after the fact.
"""

import http.server
import json
import os
import re
import sys
import subprocess
import time
import urllib.request
import urllib.error

UPSTREAM = "http://127.0.0.1:8080"
LISTEN_PORT = 8081
DEFAULT_REASONING = "Reasoning strength: xhigh"
LOG_FILE = os.path.expanduser("~/.cache/llama-proxy.log")
MODELS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "models.json")

HOP_BY_HOP = {"host", "connection", "proxy-connection", "keep-alive", "transfer-encoding"}


def log(msg: str):
    """Append a line to the proxy log file (crash-safe)."""
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}\n")
    except OSError:
        pass


def _hf_repo(model_id: str) -> str:
    return model_id.split(":", 1)[0]


def _hf_quant(model_id: str) -> str:
    return model_id.split(":", 1)[1] if ":" in model_id else "latest"


def _matches_loaded(hf_model_id: str, loaded_path: str) -> bool:
    """True if the HF-style id names the snapshot the server has loaded.

    Resolved GGUF paths look like
    ``.../models--<owner>--<repo>/snapshots/<rev>[/<quant>]/<file>.gguf``.
    The HF cache stores a revision dir (hash or ref); unsloth-style repos put
    the quant in a subdir beneath it. Owner and repo must match exactly; the
    configured quant must appear somewhere below the snapshot rev so two
    quants of one repo never cross-match.
    """
    if not loaded_path:
        return False
    m = re.search(r"models--([^/]+)--(.+)/snapshots/(.+)", loaded_path)
    if not m:
        return os.path.basename(loaded_path) == hf_model_id
    owner, repo, tail = m.group(1), m.group(2), m.group(3)
    cfg_repo = _hf_repo(hf_model_id)  # "owner/repo"
    if "/" not in cfg_repo:
        return False
    cfg_owner, cfg_name = cfg_repo.split("/", 1)
    if owner != cfg_owner or repo != cfg_name:
        return False
    quant = _hf_quant(hf_model_id).lower()
    return quant in tail.lower()


def discover_models():
    """Model IDs available to llama-server (HF cache), via discover_models.sh."""
    script = os.path.join(os.path.dirname(MODELS_FILE), "discover_models.sh")
    try:
        out = subprocess.run(["bash", script], capture_output=True, text=True, timeout=30)
        return json.loads(out.stdout) if out.returncode == 0 else []
    except Exception:
        return []


def catalog_models():
    """OpenAI-style /v1/models payload: cache-discovered models + live server."""
    loaded_path = ""
    try:
        with urllib.request.urlopen(f"{UPSTREAM}/props", timeout=2) as r:
            loaded_path = json.load(r).get("model_path", "") or ""
    except Exception:
        pass  # server down — advertise catalog without a loaded model

    with open(MODELS_FILE) as f:
        cfg = json.load(f)
    default_id = cfg.get("default_model", "")
    overrides = cfg.get("models", {})
    discovered = discover_models() or list(overrides)  # fall back to config if cache listing fails

    data = []
    loaded_ctx = None
    for mid in discovered:
        m = overrides.get(mid, {})
        loaded = bool(loaded_path) and _matches_loaded(mid, loaded_path)
        ctx = m.get("ctx_size")
        entry = {
            "id": mid,
            "object": "model",
            "created": 0,
            "owned_by": "llama-bar",
            # Standard fields so OpenAI-compatible clients (omp model discovery,
            # etc.) learn the context window without parsing the llamabar block.
            "context_length": ctx,
            "max_model_len": ctx,
            "llamabar": {
                "loaded": loaded,
                "default": mid == default_id,
                "quant": _hf_quant(mid),
                "ctx_size": ctx,
                "reasoning": m.get("reasoning", "off") == "on",
            },
        }
        if loaded:
            entry["alias"] = os.path.basename(loaded_path)
            loaded_ctx = ctx
        data.append(entry)

    # Keep the raw llama-server id routable (e.g. curl examples, old configs).
    if loaded_path and not any(d["id"] == os.path.basename(loaded_path) for d in data):
        alias_entry = {
            "id": os.path.basename(loaded_path),
            "object": "model",
            "created": 0,
            "owned_by": "llama-bar",
            "llamabar": {"loaded": True},
        }
        if loaded_ctx:
            alias_entry["context_length"] = loaded_ctx
            alias_entry["max_model_len"] = loaded_ctx
        data.append(alias_entry)

    return {"object": "list", "data": data}


def normalize_messages(messages):
    """Flatten tool-call transcripts for models with strict chat templates.

    Some templates (unsloth Qwen3-Next, gemma) raise
    "Conversation roles must alternate user/assistant/..." on tool roles or
    consecutive same-role turns. Tool results are folded into the *following*
    assistant message as labelled text; any other consecutive same-role pair is
    concatenated. User/assistant alternation is preserved for everything else.
    """
    if not messages:
        return messages

    # 1) Fold tool messages into the next assistant turn.
    pending_tools = []
    folded = []
    for m in messages:
        role = m.get("role")
        if role == "tool":
            name = m.get("name") or m.get("tool_call_id") or "tool"
            pending_tools.append(f"[tool:{name}] {m.get('content', '')}")
            continue
        if role == "assistant" and pending_tools:
            content = "\n".join(pending_tools)
            if m.get("content"):
                content += "\n" + m["content"]
            folded.append({**m, "content": content})
            pending_tools = []
            continue
        if pending_tools:
            # Tool results not followed by an assistant turn (rare): emit as user.
            folded.append({"role": "user", "content": "\n".join(pending_tools)})
            pending_tools = []
        folded.append(m)
    if pending_tools:
        folded.append({"role": "user", "content": "\n".join(pending_tools)})

    # 2) Merge consecutive same-role messages (system excluded — clients put it first).
    merged = []
    for m in folded:
        if (merged and m.get("role") == merged[-1].get("role")
                and m.get("role") != "system"):
            prev = merged[-1]
            prev["content"] = (str(prev.get("content") or "") + "\n" + str(m.get("content") or "")).strip()
        else:
            merged.append(dict(m))
    return merged


class Proxy(http.server.BaseHTTPRequestHandler):
    # Silence the default per-request stderr logging
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path.rstrip("/").endswith("/v1/models"):
            try:
                payload = json.dumps(catalog_models()).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            except Exception as e:  # models.json missing/unparseable
                log(f"ERROR catalog: {e}")
                body = json.dumps({"error": {"code": 500, "message": f"catalog error: {e}"}}).encode()
                self.send_response(500)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(body)
            return
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

                req["messages"] = normalize_messages(messages)
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
    print(f"[proxy] Catalog: {MODELS_FILE}")
    print(f"[proxy] Log: {LOG_FILE}")
    http.server.ThreadingHTTPServer(("127.0.0.1", LISTEN_PORT), Proxy).serve_forever()
