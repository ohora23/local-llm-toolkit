#!/usr/bin/env python3
"""memgarden-shim — Ollama-API front for memgarden that runs its LLM calls on hrvl.

memgarden only speaks Ollama (`POST /api/generate` non-streaming with a JSON-schema `format`,
`GET /api/version` probe). hrvl's llama.cpp speaks OpenAI. This shim listens on 127.0.0.1:11435:
  - if hrvl is attached (no ~/.local/state/llm/hrvl-detached) and its /health answers, translate
    /api/generate into /v1/chat/completions (thinking off, schema enforced as json_schema grammar)
    and hand the reply back in Ollama shape (response / done_reason / eval_count);
  - otherwise (detached, unreachable, or an hrvl error) pass the request through to the local
    Ollama on :11434 untouched. So memgarden works with or without hrvl, and a reboot on either
    side needs no reconfiguration.
When the route flips to hrvl the local Ollama model is asked to unload (keep_alive 0), so the
RTX 5080 is free for other work (mujoco, RL) instead of holding a 12 GB model for memgarden.
Config via env: SHIM_PORT, HRVL_URL (http://hrvl-server.local:8080), OLLAMA_URL (http://127.0.0.1:11434).
"""
import json, os, sys, time, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("SHIM_PORT", "11435"))
HRVL = os.environ.get("HRVL_URL", "http://hrvl-server.local:8080").rstrip("/")
OLLAMA = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434").rstrip("/")
FLAG = os.path.expanduser("~/.local/state/llm/hrvl-detached")
_route = {"t": 0.0, "hrvl": False}
_last_route = None

def log(*a):
    print(time.strftime("%H:%M:%S"), *a, file=sys.stderr, flush=True)

def hrvl_ok():
    """cached (5 s) attach+health check"""
    now = time.time()
    if now - _route["t"] < 5:
        return _route["hrvl"]
    ok = False
    if not os.path.exists(FLAG):
        try:
            with urllib.request.urlopen(HRVL + "/health", timeout=1) as r:
                ok = b'"ok"' in r.read()
        except Exception:
            ok = False
    _route.update(t=now, hrvl=ok)
    return ok

def http_json(url, body=None, timeout=300, method=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method or ("POST" if data else "GET"),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read()

def unload_local(model):
    """ask the local Ollama to drop the model now (not after keep_alive) — frees the 5080"""
    try:
        http_json(OLLAMA + "/api/generate", {"model": model, "keep_alive": 0}, timeout=10)
        log("local ollama: unloaded", model)
    except Exception as e:
        log("local ollama unload skipped:", e)

def to_hrvl(req):
    """Ollama /api/generate body -> OpenAI chat body for llama.cpp"""
    opts = req.get("options") or {}
    msgs = []
    if req.get("system"):
        msgs.append({"role": "system", "content": req["system"]})
    msgs.append({"role": "user", "content": req.get("prompt", "")})
    body = {"model": "local", "messages": msgs, "stream": False,
            "temperature": opts.get("temperature", 0.1),
            "max_tokens": int(opts.get("num_predict", 2048)),
            "chat_template_kwargs": {"enable_thinking": False}}
    fmt = req.get("format")
    if isinstance(fmt, dict):
        body["response_format"] = {"type": "json_schema", "json_schema": {"name": "memgarden", "schema": fmt}}
    elif fmt == "json":
        body["response_format"] = {"type": "json_object"}
    return body

def from_hrvl(req, resp, t0):
    ch = resp["choices"][0]
    usage = resp.get("usage") or {}
    ns = int((time.time() - t0) * 1e9)
    return {"model": req.get("model", "hrvl"), "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "response": ch["message"].get("content") or "", "done": True,
            "done_reason": "length" if ch.get("finish_reason") == "length" else "stop",
            "context": [], "total_duration": ns, "load_duration": 0,
            "prompt_eval_count": usage.get("prompt_tokens", 0), "prompt_eval_duration": 0,
            "eval_count": usage.get("completion_tokens", 0), "eval_duration": ns}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet default access log
        pass

    def _send(self, status, payload):
        data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _proxy(self, body=None):
        try:
            st, data = http_json(OLLAMA + self.path, body, timeout=300, method=self.command)
            self._send(st, data)
        except urllib.error.HTTPError as e:
            self._send(e.code, e.read())
        except Exception as e:
            self._send(502, {"error": f"local ollama unreachable: {e}"})

    _last_get_log = 0.0
    def do_GET(self):
        if self.path.startswith("/v1/"):  # e.g. /v1/models from OpenAI-style clients
            return self._proxy()
        # memgarden probes /api/version every 30 s; log it at most once per 5 min so the journal shows liveness
        now = time.time()
        if now - H._last_get_log > 300:
            H._last_get_log = now
            log("probe", self.path, "->", "hrvl" if hrvl_ok() else "local")
        if self.path.startswith("/api/version") and hrvl_ok():
            return self._send(200, {"version": "0.21.2-hrvl-shim"})
        self._proxy()

    def do_POST(self):
        global _last_route
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b"{}"
        try:
            req = json.loads(raw or b"{}")
        except Exception:
            req = {}
        # OpenAI-style callers (agentmemory: OPENAI_BASE_URL=http://127.0.0.1:11435/v1) — same routing,
        # body passes through untouched except thinking off + model name on the hrvl side
        if self.path.startswith("/v1/"):
            if hrvl_ok() and self.path.startswith("/v1/chat/completions") and not req.get("stream"):
                if _last_route != "hrvl":
                    log("route -> hrvl (openai)"); _last_route = "hrvl"
                    if req.get("model"): unload_local(req["model"])
                body = dict(req); body["model"] = "local"
                body.setdefault("chat_template_kwargs", {})["enable_thinking"] = False
                t0 = time.time()
                try:
                    st, data = http_json(HRVL + self.path, body, timeout=290)
                    log(f"hrvl openai {time.time()-t0:.1f}s")
                    return self._send(st, data)
                except Exception as e:
                    log("hrvl openai failed, falling back to local ollama:", e)
                    _route.update(t=time.time(), hrvl=False)
            return self._proxy(req if req else None)
        use_hrvl = self.path.startswith("/api/generate") and not req.get("stream") and hrvl_ok()
        route = "hrvl" if use_hrvl else "local"
        if route != _last_route:
            log("route ->", route)
            if route == "hrvl" and req.get("model"):
                unload_local(req["model"])
            _last_route = route
        if not use_hrvl:
            return self._proxy(req if req else None)
        t0 = time.time()
        try:
            st, data = http_json(HRVL + "/v1/chat/completions", to_hrvl(req), timeout=290)
            out = from_hrvl(req, json.loads(data), t0)
            log(f"hrvl generate {time.time()-t0:.1f}s prompt={out['prompt_eval_count']} out={out['eval_count']} {out['done_reason']}")
            self._send(200, out)
        except Exception as e:
            log("hrvl failed, falling back to local ollama:", e)
            _route.update(t=time.time(), hrvl=False)  # avoid re-trying hrvl for the next 5 s
            self._proxy(req)

if __name__ == "__main__":
    log(f"memgarden-shim on 127.0.0.1:{PORT}  hrvl={HRVL}  ollama={OLLAMA}")
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
