#!/usr/bin/env python3
"""
Mock backend for agent-notch.

Mimics the minimum surface the notch needs so you can launch the app
and see the HUD populate with fake data — no Jarvis Router, no
agent-conductor, no real LLM. Zero external dependencies; uses only
Python 3 standard library shipped with macOS.

Endpoints implemented:

    GET  /api/notch/stream       (Server-Sent Events; pushes fake
                                  sessions + todos every few seconds)
    GET  /api/local-sessions     returns 2 fake sessions
    GET  /api/notch/prefs        returns {}
    POST /api/notch/prefs        accepts patch, logs it
    POST /api/notch/send         logs the message, 204
    POST /api/notch/abort        204
    POST /api/notch/voice        returns a fake transcript
    GET  /api/todos/<id>         returns a fake todo
    PATCH/POST /api/todos/<id>*  204
    GET  /notch/orb/notch.html   serves a tiny placeholder HTML

Run on the default port 3340:

    python3 scripts/mock-backend.py

Run on a different port (must match config.json `backendURL`):

    python3 scripts/mock-backend.py --port 4200

Press Ctrl+C to stop.
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

# Repo-relative path to the BUILT orb assets (notch.html + JS/CSS
# bundles + VAD wasm + vendor libs). The mock serves these directly
# so the WKWebView gets the real React app instead of a placeholder
# div. Falls back to the inline placeholder if the directory is
# absent (running the script standalone).
ORB_DIR = (Path(__file__).resolve().parent.parent / "Sources" / "AgentNotch" / "Orb").resolve()

# ─── Fake state ─────────────────────────────────────────────────────────

FAKE_SESSIONS: list[dict[str, Any]] = [
    {
        "pid": 1001,
        "repo": "agent-notch",
        "status": "working",
        "conflict": None,
        "provider": "claude-code",
    },
    {
        "pid": 2002,
        "repo": "topics-app",
        "status": "awaiting_user_input",
        "conflict": None,
        "provider": "aider",
    },
]

FAKE_TODOS: list[dict[str, Any]] = [
    {"id": "T-1", "title": "Wire orchestrator backend", "pid": 1001, "phase": "plan"},
    {"id": "T-2", "title": "Add subprocess transport",  "pid": 1001, "phase": "build"},
    {"id": "T-3", "title": "Sign the .app bundle",      "pid": None, "phase": None},
]

# ─── SSE broadcast queue ────────────────────────────────────────────────
#
# POST /api/notch/send must trigger an SSE `message.out` echo so the
# user sees a response in the chat — otherwise the app feels "deaf"
# even when the mic picked up the message correctly.
#
# Each active SSE connection registers its OWN inbound queue. The
# send handler appends events to every queue so all connected clients
# (real app + curl test + dev tools) see the same broadcast. Previous
# "single shared queue + drain" lost events to whichever client
# drained first.
SSE_CLIENTS_LOCK = threading.Lock()
SSE_CLIENT_QUEUES: list[list[dict[str, Any]]] = []

def register_sse_client() -> list[dict[str, Any]]:
    """Create a new per-client queue and return it."""
    q: list[dict[str, Any]] = []
    with SSE_CLIENTS_LOCK:
        SSE_CLIENT_QUEUES.append(q)
    return q

def unregister_sse_client(q: list[dict[str, Any]]) -> None:
    with SSE_CLIENTS_LOCK:
        try:
            SSE_CLIENT_QUEUES.remove(q)
        except ValueError:
            pass

def enqueue_event(event_type: str, data: dict[str, Any]) -> None:
    """Broadcast an event to every registered client queue."""
    with SSE_CLIENTS_LOCK:
        for q in SSE_CLIENT_QUEUES:
            q.append({"type": event_type, "data": data})

PLACEHOLDER_ORB_HTML = """<!doctype html>
<html><head><meta charset="utf-8"><title>orb (mock)</title>
<style>
  html,body { margin:0; padding:0; background:#0b0b0e; color:#cfcfd6;
              font: 13px/1.4 -apple-system, system-ui, sans-serif;
              height:100%; display:flex; align-items:center; justify-content:center; }
  div { text-align:center; opacity:.7; }
  b { color:#a78bfa; }
</style></head>
<body>
  <div>
    <b>mock backend</b><br/>
    notch orb placeholder<br/>
    replace with real backend when ready
  </div>
</body></html>
"""


# ─── HTTP handler ───────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    # Quieter than the default `BaseHTTPRequestHandler.log_message`.
    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write(f"[mock] {self.address_string()} - {fmt % args}\n")

    # ── helpers ────────────────────────────────────────────────────────

    def _send_json(self, status: int, payload: Any) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _send_204(self) -> None:
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0") or "0")
        return self.rfile.read(length) if length > 0 else b""

    def _serve_orb(self, path: str) -> None:
        """Serve files from the built Orb resources directory.

        Strips the `/notch/orb/` prefix; bare `/notch/orb` (no slash,
        no trailing path) maps to `notch.html`. Anything outside
        ORB_DIR is refused with 403 to dodge path-traversal attempts.
        Falls back to the inline placeholder if the resource is
        missing.
        """
        rel = path[len("/notch/orb"):].lstrip("/")
        if rel == "":
            rel = "notch.html"
        # Normalise + guard against `..` escape.
        target = (ORB_DIR / rel).resolve()
        try:
            target.relative_to(ORB_DIR)
        except ValueError:
            self.send_response(403)
            self.end_headers()
            return
        if not target.is_file():
            # Resource missing — fall back to a clearly visible
            # placeholder so the user knows the WebView is alive but
            # the orb sources weren't found.
            body = PLACEHOLDER_ORB_HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        # Real file → infer Content-Type from extension. Fall back
        # to octet-stream so unknown WASM/font types still load.
        ctype, _ = mimetypes.guess_type(target.name)
        if ctype is None:
            if target.suffix == ".wasm":
                ctype = "application/wasm"
            elif target.suffix == ".woff":
                ctype = "font/woff"
            elif target.suffix == ".woff2":
                ctype = "font/woff2"
            elif target.suffix == ".mjs":
                ctype = "application/javascript"
            else:
                ctype = "application/octet-stream"
        data = target.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    # ── GET ────────────────────────────────────────────────────────────

    def do_GET(self) -> None:
        path = self.path

        if path == "/api/notch/stream":
            return self._stream_sse()

        if path == "/api/local-sessions":
            return self._send_json(200, FAKE_SESSIONS)

        if path == "/api/notch/prefs":
            # Default prefs returned to fresh clients. hoverRecord ON
            # by default so the user can talk to the notch without
            # first finding and toggling the setting buried in the
            # toolbar.
            return self._send_json(200, {
                "hoverRecord": True,
                "mute": False,
                "model": "sonnet",
            })

        if path.startswith("/api/notch/history"):
            # React app fetches chat history on mount. Mock with a
            # couple of seed messages so the chat log isn't blank.
            return self._send_json(200, {
                "messages": [
                    {"role": "assistant", "text": "Mock backend ready. Try typing something.", "ts": int(time.time() * 1000) - 60000},
                    {"role": "user", "text": "ciao", "ts": int(time.time() * 1000) - 30000},
                    {"role": "assistant", "text": "Ricevuto. Sto pensando... (mock response)", "ts": int(time.time() * 1000) - 28000},
                ]
            })

        if path.startswith("/api/todos/"):
            todo_id = path.split("/api/todos/", 1)[1].split("/")[0]
            todo = next((t for t in FAKE_TODOS if t["id"] == todo_id), None)
            if todo is None:
                return self._send_json(404, {"error": "not found"})
            return self._send_json(200, todo)

        if path.startswith("/notch/orb"):
            return self._serve_orb(path)

        # Browser auto-fetches for favicon / apple-touch-icon. Return
        # 204 (no content) instead of 404 so the mock log doesn't fill
        # with red error lines every time a sidebar click opens the
        # browser to our fake /orchestrator URL.
        if path in (
            "/favicon.ico",
            "/apple-touch-icon.png",
            "/apple-touch-icon-precomposed.png",
        ):
            return self._send_204()

        # Anything that looks like the orchestrator dashboard route —
        # we don't actually render a dashboard, but returning a small
        # HTML stub beats a 404 page in the browser when the user
        # clicks a sidebar session.
        if path.startswith("/orchestrator"):
            stub = (
                "<!doctype html><html><head><meta charset=\"utf-8\">"
                "<title>orchestrator (mock)</title>"
                "<style>body{background:#0b0b0e;color:#cfcfd6;"
                "font:14px/1.4 -apple-system,system-ui,sans-serif;"
                "padding:32px;}b{color:#a78bfa;}</style></head>"
                "<body><b>mock backend</b><br/>"
                f"Would open orchestrator tab for path: <code>{path}</code><br/>"
                "Wire up a real backend (e.g. Jarvis Router) to see "
                "the actual dashboard here.</body></html>"
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(stub)))
            self.end_headers()
            self.wfile.write(stub)
            return

        return self._send_json(404, {"error": "not found", "path": path})

    # ── POST / PATCH ───────────────────────────────────────────────────

    def do_POST(self) -> None:
        path = self.path
        body = self._read_body()

        if path == "/api/notch/send":
            try:
                msg = json.loads(body or b"{}").get("text", "")
            except Exception:
                msg = ""
            sys.stderr.write(f"[mock] send: {msg!r}\n")
            # Echo back a fake assistant response over SSE so the user
            # actually sees the agent "reply" instead of an inert chat.
            # Wrap in a tiny state.change + delay so the orb visually
            # transitions through thinking → responding → idle.
            def fake_response(text: str) -> None:
                time.sleep(0.4)
                enqueue_event("state.change", {"state": "thinking"})
                time.sleep(0.6)
                enqueue_event("state.change", {"state": "responding"})
                reply = f"(mock) Ho ricevuto: «{text}». Risponderei qui, ma sono un backend finto."
                enqueue_event("message.out", {"text": reply, "from": "assistant"})
                time.sleep(0.6)
                enqueue_event("state.change", {"state": "idle"})
            threading.Thread(target=fake_response, args=(msg,), daemon=True).start()
            return self._send_204()

        if path == "/api/notch/abort":
            sys.stderr.write("[mock] abort\n")
            return self._send_204()

        if path == "/api/notch/prefs":
            sys.stderr.write(f"[mock] prefs PATCH: {body!r}\n")
            return self._send_204()

        if path == "/api/notch/voice":
            return self._send_json(200, {
                "transcript": "ciao questo è un transcript finto",
                "confidence": 0.92,
            })

        if path.endswith("/complete"):
            sys.stderr.write(f"[mock] todo complete: {path}\n")
            return self._send_204()

        return self._send_json(404, {"error": "not found", "path": path})

    def do_PATCH(self) -> None:
        sys.stderr.write(f"[mock] PATCH {self.path}: {self._read_body()!r}\n")
        return self._send_204()

    # ── HEAD ───────────────────────────────────────────────────────────
    #
    # Sidebar click probes the orchestrator URL with HEAD before
    # opening the browser. BaseHTTPRequestHandler's default do_HEAD
    # returns 501, which the probe reads as "unreachable" → the
    # click silently no-ops. Mirror do_GET's routing but return only
    # status + headers (no body).
    def do_HEAD(self) -> None:
        path = self.path
        if (
            path in (
                "/api/local-sessions",
                "/api/notch/prefs",
                "/favicon.ico",
                "/apple-touch-icon.png",
                "/apple-touch-icon-precomposed.png",
            )
            or path.startswith("/api/todos/")
            or path.startswith("/notch/orb")
            or path.startswith("/orchestrator")
        ):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            return
        self.send_response(404)
        self.end_headers()

    # ── SSE stream ─────────────────────────────────────────────────────

    def _stream_sse(self) -> None:
        # Send the SSE headers and keep the connection open.
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()

        # Each SSE connection gets its own pending queue so a /send
        # POST gets fanned out to every connected client (not raced).
        client_queue = register_sse_client()

        def send(event_type: str, data: dict[str, Any]) -> None:
            try:
                line = "data: " + json.dumps({"type": event_type, "data": data}) + "\n\n"
                self.wfile.write(line.encode("utf-8"))
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                raise

        # Initial state burst — populate the HUD immediately so the
        # user sees something the moment the notch expands.
        try:
            send("sessions:update", {
                "pids": [s["pid"] for s in FAKE_SESSIONS],
                "ts": int(time.time() * 1000),
                "sessions": FAKE_SESSIONS,
            })
            send("todos:update", {
                "count": len(FAKE_TODOS),
                "ts": int(time.time() * 1000),
                "topThree": FAKE_TODOS,
            })

            # Periodic heartbeat. Two clocks:
            #   - Every 5 s: rotate the first session's status so the
            #     sidebar shows colour reactivity (cheap, useful).
            #   - Every 60 s: rotate the high-level agent state +
            #     emit ONE message.in so the chat / peek bubble has
            #     periodic life without spamming the same line on
            #     every tick (the 5-second cadence felt like the
            #     mock was screaming at you).
            flip = 0
            tick = 0
            states = ["idle", "thinking", "responding"]
            statuses = ["working", "tool_pending", "awaiting_user_input"]
            fake_messages = [
                "Sto ragionando sul prossimo step...",
                "Ho aperto il file e leggo il diff.",
                "Devo confermare prima di procedere.",
            ]
            while True:
                # Poll this client's pending queue every 200 ms so
                # async /api/notch/send replies reach the client fast.
                for _ in range(25):  # 25 * 0.2 = 5 s, then heartbeat
                    time.sleep(0.2)
                    # Drain the per-client queue under the lock so
                    # the POST thread can't append while we iterate.
                    with SSE_CLIENTS_LOCK:
                        pending = list(client_queue)
                        client_queue.clear()
                    for evt in pending:
                        send(evt["type"], evt["data"])
                tick += 1
                flip = (flip + 1) % 3
                FAKE_SESSIONS[0]["status"] = statuses[flip]
                send("sessions:update", {
                    "pids": [s["pid"] for s in FAKE_SESSIONS],
                    "ts": int(time.time() * 1000),
                    "sessions": FAKE_SESSIONS,
                })
                # state.change every 15 s (every 3rd tick) so the
                # ModeBadge cycles visibly. Removed periodic
                # message.in spam — replies now come from real
                # POST /api/notch/send echos via enqueue_event.
                if tick % 3 == 0:
                    send("state.change", {"state": states[flip]})
        except (BrokenPipeError, ConnectionResetError):
            sys.stderr.write("[mock] SSE client disconnected\n")
        finally:
            unregister_sse_client(client_queue)


# ─── Entry point ────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description="Mock backend for agent-notch")
    parser.add_argument("--port", type=int, default=3340, help="port to bind (default 3340)")
    parser.add_argument("--host", type=str, default="127.0.0.1", help="host to bind")
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    sys.stderr.write(f"[mock] listening on http://{args.host}:{args.port}\n")
    sys.stderr.write("[mock] Ctrl+C to stop\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.stderr.write("\n[mock] shutting down\n")
        server.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
