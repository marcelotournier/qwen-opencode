#!/usr/bin/env python3
"""Front-door proxy for ollama that suppresses Qwen 3.5 thinking on every endpoint.

Why this exists: ollama 0.22 has no working `think: false` toggle on the
OpenAI-compatible /v1/chat/completions endpoint. opencode (and anything
else built on the AI-SDK openai-compatible provider) only speaks /v1, so
on this 16 GB M4 a single opencode turn would burn 4-5 minutes on hidden
<think> tokens.

What we do:
  POST /v1/chat/completions  -> translate to /api/chat (think:false),
                                fake-stream the response back as SSE
                                (heartbeat ': keepalive' comments while
                                ollama generates, then content+finish in
                                one chunk + [DONE]).
  POST /api/chat             -> inject "think": false if not present.
  POST /api/generate         -> inject "think": false if not present.
  everything else            -> transparent passthrough.

Tool calls are converted in both directions (ollama returns `arguments`
as a parsed object; OpenAI SDK callers expect a JSON string).

Stdlib only. Threaded server, one thread per request. Bind 0.0.0.0:11434.
Forwards to 127.0.0.1:11435 where the real ollama lives.
"""

from __future__ import annotations

import http.client
import http.server
import json
import os
import socketserver
import sys
import threading
import time
import uuid

UPSTREAM_HOST = os.environ.get("OLLAMA_PROXY_UPSTREAM_HOST", "127.0.0.1")
UPSTREAM_PORT = int(os.environ.get("OLLAMA_PROXY_UPSTREAM_PORT", "11435"))
LISTEN_HOST = os.environ.get("OLLAMA_PROXY_LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("OLLAMA_PROXY_LISTEN_PORT", "11434"))
HEARTBEAT_INTERVAL = float(os.environ.get("OLLAMA_PROXY_HEARTBEAT_S", "1.0"))
UPSTREAM_TIMEOUT = float(os.environ.get("OLLAMA_PROXY_UPSTREAM_TIMEOUT_S", "600"))


def log(msg: str) -> None:
    sys.stderr.write(f"[{time.strftime('%H:%M:%S')}] {msg}\n")
    sys.stderr.flush()


def gen_chat_id() -> str:
    return f"chatcmpl-{uuid.uuid4().hex[:24]}"


def gen_call_id() -> str:
    return f"call_{uuid.uuid4().hex[:24]}"


def convert_tool_calls_ollama_to_openai(tool_calls):
    """ollama returns arguments as parsed object; OpenAI expects a JSON string."""
    out = []
    for i, tc in enumerate(tool_calls or []):
        fn = tc.get("function", {}) or {}
        args = fn.get("arguments", {})
        if not isinstance(args, str):
            args = json.dumps(args)
        out.append({
            "index": i,
            "id": tc.get("id") or gen_call_id(),
            "type": "function",
            "function": {
                "name": fn.get("name", ""),
                "arguments": args,
            },
        })
    return out


def translate_messages_openai_to_ollama(messages: list) -> list:
    """ollama /api/chat expects tool_call arguments as parsed objects.
    OpenAI clients (opencode, AI-SDK) send them as JSON strings. Convert."""
    out = []
    for m in messages or []:
        m = dict(m) if isinstance(m, dict) else m
        if isinstance(m, dict) and m.get("role") == "assistant" and m.get("tool_calls"):
            new_tcs = []
            for tc in m["tool_calls"]:
                tc = dict(tc)
                fn = dict(tc.get("function", {}) or {})
                args = fn.get("arguments")
                if isinstance(args, str):
                    try:
                        fn["arguments"] = json.loads(args) if args.strip() else {}
                    except Exception:
                        # Leave as-is if it's not parseable; ollama will complain.
                        pass
                tc["function"] = fn
                new_tcs.append(tc)
            m["tool_calls"] = new_tcs
        out.append(m)
    return out


def build_ollama_request_from_openai(req: dict) -> dict:
    """Translate an OpenAI /v1/chat/completions body into an ollama /api/chat body."""
    out = {
        "model": req["model"],
        "messages": translate_messages_openai_to_ollama(req.get("messages", [])),
        "stream": False,
        "think": False,
    }
    if "tools" in req:
        out["tools"] = req["tools"]
    # Translate sampling params into ollama options
    options = {}
    pass_through_options = {
        "temperature": "temperature",
        "top_p": "top_p",
        "frequency_penalty": "frequency_penalty",
        "presence_penalty": "presence_penalty",
        "seed": "seed",
        "stop": "stop",
    }
    for openai_key, ollama_key in pass_through_options.items():
        if openai_key in req:
            options[ollama_key] = req[openai_key]
    if "max_tokens" in req:
        options["num_predict"] = req["max_tokens"]
    if "max_completion_tokens" in req:
        options["num_predict"] = req["max_completion_tokens"]
    if options:
        out["options"] = options
    return out


def call_upstream_chat(ollama_req: dict) -> dict:
    """Blocking call to upstream /api/chat. Returns parsed response or raises."""
    body = json.dumps(ollama_req).encode()
    conn = http.client.HTTPConnection(UPSTREAM_HOST, UPSTREAM_PORT, timeout=UPSTREAM_TIMEOUT)
    try:
        conn.request("POST", "/api/chat", body=body, headers={"Content-Type": "application/json"})
        resp = conn.getresponse()
        raw = resp.read()
        if resp.status != 200:
            raise RuntimeError(f"upstream {resp.status}: {raw.decode(errors='replace')[:500]}")
        return json.loads(raw.decode())
    finally:
        conn.close()


def usage_block_from_ollama(d: dict) -> dict:
    pt = d.get("prompt_eval_count", 0) or 0
    ct = d.get("eval_count", 0) or 0
    return {"prompt_tokens": pt, "completion_tokens": ct, "total_tokens": pt + ct}


class Handler(http.server.BaseHTTPRequestHandler):
    timeout = 600
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        # Quiet by default; set OLLAMA_PROXY_VERBOSE=1 for access logs.
        if os.environ.get("OLLAMA_PROXY_VERBOSE") == "1":
            sys.stderr.write(f"[{time.strftime('%H:%M:%S')}] {self.address_string()} {fmt % args}\n")

    # ---- HTTP method dispatch ----
    def do_GET(self): self._dispatch("GET")
    def do_DELETE(self): self._dispatch("DELETE")
    def do_HEAD(self): self._dispatch("HEAD")
    def do_PUT(self): self._dispatch("PUT")
    def do_PATCH(self): self._dispatch("PATCH")
    def do_OPTIONS(self): self._dispatch("OPTIONS")

    def do_POST(self):
        body = self._read_body()
        if self.path == "/v1/chat/completions":
            self._handle_chat_completions(body)
            return
        if self.path in ("/api/chat", "/api/generate"):
            body = self._inject_think_false(body)
        self._proxy(method="POST", body=body)

    def _read_body(self) -> bytes:
        n = int(self.headers.get("Content-Length", "0") or "0")
        return self.rfile.read(n) if n > 0 else b""

    def _inject_think_false(self, body: bytes) -> bytes:
        if not body:
            return body
        try:
            j = json.loads(body)
        except Exception:
            return body
        if isinstance(j, dict) and "think" not in j:
            j["think"] = False
            return json.dumps(j).encode()
        return body

    def _dispatch(self, method: str):
        body = self._read_body() if method in ("PUT", "PATCH") else b""
        self._proxy(method=method, body=body)

    # ---- transparent passthrough ----
    def _proxy(self, method: str, body: bytes):
        try:
            conn = http.client.HTTPConnection(UPSTREAM_HOST, UPSTREAM_PORT, timeout=UPSTREAM_TIMEOUT)
        except Exception as e:
            self._send_error(502, f"connect upstream failed: {e}")
            return
        try:
            headers = {h: v for h, v in self.headers.items()
                       if h.lower() not in ("host", "content-length", "connection")}
            if body:
                headers["Content-Length"] = str(len(body))
            conn.request(method, self.path, body=body if body else None, headers=headers)
            resp = conn.getresponse()
            self.send_response(resp.status, resp.reason)
            for h, v in resp.getheaders():
                if h.lower() in ("transfer-encoding", "connection", "content-length"):
                    continue
                self.send_header(h, v)
            # Use chunked for streamed bodies; we don't know length up-front when ollama streams.
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            while True:
                chunk = resp.read(4096)
                if not chunk:
                    break
                if not self._write_chunked(chunk):
                    return
            self._write_chunked(b"")  # terminator
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception as e:
            log(f"proxy error on {self.path}: {e}")
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def _write_chunked(self, data: bytes) -> bool:
        try:
            self.wfile.write(f"{len(data):x}\r\n".encode())
            self.wfile.write(data)
            self.wfile.write(b"\r\n")
            self.wfile.flush()
            return True
        except (BrokenPipeError, ConnectionResetError):
            return False

    def _send_error(self, status: int, msg: str):
        try:
            body = msg.encode()
            self.send_response(status)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except Exception:
            pass

    # ---- /v1/chat/completions translation ----
    def _handle_chat_completions(self, body: bytes):
        try:
            req = json.loads(body)
        except Exception as e:
            self._send_error(400, f"invalid json: {e}")
            return
        if not isinstance(req, dict) or "model" not in req or "messages" not in req:
            self._send_error(400, "expected {model, messages, ...}")
            return

        is_streaming = bool(req.get("stream", False))
        ollama_req = build_ollama_request_from_openai(req)
        model_name = req["model"]

        if is_streaming:
            self._fake_stream(ollama_req, model_name)
        else:
            self._non_stream(ollama_req, model_name)

    def _non_stream(self, ollama_req: dict, model_name: str):
        try:
            d = call_upstream_chat(ollama_req)
        except Exception as e:
            self._send_error(502, f"upstream error: {e}")
            return

        msg = d.get("message", {}) or {}
        tool_calls = convert_tool_calls_ollama_to_openai(msg.get("tool_calls"))
        out_msg = {"role": "assistant", "content": msg.get("content", "") or ""}
        if tool_calls:
            # OpenAI shape: tool_calls don't carry "index" at the message level
            out_msg["tool_calls"] = [{k: v for k, v in tc.items() if k != "index"} for tc in tool_calls]

        response = {
            "id": gen_chat_id(),
            "object": "chat.completion",
            "created": int(time.time()),
            "model": model_name,
            "choices": [{
                "index": 0,
                "message": out_msg,
                "finish_reason": "tool_calls" if tool_calls else "stop",
            }],
            "usage": usage_block_from_ollama(d),
        }
        body = json.dumps(response).encode()
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _fake_stream(self, ollama_req: dict, model_name: str):
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
        except (BrokenPipeError, ConnectionResetError):
            return

        result_holder = {}
        error_holder = []

        def runner():
            try:
                result_holder["data"] = call_upstream_chat(ollama_req)
            except Exception as e:
                error_holder.append(str(e))

        t = threading.Thread(target=runner, daemon=True)
        t.start()

        try:
            # Heartbeat while waiting. SSE comments are ignored by parsers.
            while t.is_alive():
                if not self._sse_write(b": keepalive\n\n"):
                    return
                t.join(timeout=HEARTBEAT_INTERVAL)

            if error_holder:
                err_chunk = self._mk_chunk(model_name, delta={"content": f"[proxy upstream error] {error_holder[0]}"}, finish_reason="stop")
                self._sse_write_event(err_chunk)
                self._sse_write(b"data: [DONE]\n\n")
                self._end_chunked()
                return

            d = result_holder["data"]
            msg = d.get("message", {}) or {}
            content = msg.get("content", "") or ""
            tool_calls = convert_tool_calls_ollama_to_openai(msg.get("tool_calls"))

            chat_id = gen_chat_id()
            created = int(time.time())

            # 1) role chunk
            self._sse_write_event(self._mk_chunk(model_name, delta={"role": "assistant", "content": ""},
                                                 chat_id=chat_id, created=created))
            # 2) content chunk (skip if empty and there are tool calls)
            if content:
                self._sse_write_event(self._mk_chunk(model_name, delta={"content": content},
                                                     chat_id=chat_id, created=created))
            # 3) tool_calls chunk (one event with all tool_calls, indexed)
            finish_reason = "stop"
            if tool_calls:
                self._sse_write_event(self._mk_chunk(model_name, delta={"tool_calls": tool_calls},
                                                     chat_id=chat_id, created=created))
                finish_reason = "tool_calls"
            # 4) finish chunk with usage
            final = self._mk_chunk(model_name, delta={}, finish_reason=finish_reason,
                                   chat_id=chat_id, created=created)
            final["usage"] = usage_block_from_ollama(d)
            self._sse_write_event(final)
            self._sse_write(b"data: [DONE]\n\n")
            self._end_chunked()
        except (BrokenPipeError, ConnectionResetError):
            return

    def _mk_chunk(self, model_name: str, delta: dict, finish_reason=None,
                  chat_id=None, created=None) -> dict:
        return {
            "id": chat_id or gen_chat_id(),
            "object": "chat.completion.chunk",
            "created": created or int(time.time()),
            "model": model_name,
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish_reason}],
        }

    def _sse_write_event(self, payload: dict) -> bool:
        return self._sse_write(f"data: {json.dumps(payload)}\n\n".encode())

    def _sse_write(self, raw: bytes) -> bool:
        return self._write_chunked(raw)

    def _end_chunked(self):
        self._write_chunked(b"")


class ThreadingServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64


def main():
    log(f"ollama-fakestream proxy: {LISTEN_HOST}:{LISTEN_PORT} -> {UPSTREAM_HOST}:{UPSTREAM_PORT}")
    log("  /v1/chat/completions   -> translates to /api/chat (think:false), SSE-fakes streaming")
    log("  /api/chat,/api/generate -> injects think:false if absent")
    log("  *                       -> transparent passthrough")
    server = ThreadingServer((LISTEN_HOST, LISTEN_PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("shutting down")
        server.server_close()


if __name__ == "__main__":
    main()
