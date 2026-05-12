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
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

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

    # ── GET ────────────────────────────────────────────────────────────

    def do_GET(self) -> None:
        path = self.path

        if path == "/api/notch/stream":
            return self._stream_sse()

        if path == "/api/local-sessions":
            return self._send_json(200, FAKE_SESSIONS)

        if path == "/api/notch/prefs":
            return self._send_json(200, {})

        if path.startswith("/api/todos/"):
            todo_id = path.split("/api/todos/", 1)[1].split("/")[0]
            todo = next((t for t in FAKE_TODOS if t["id"] == todo_id), None)
            if todo is None:
                return self._send_json(404, {"error": "not found"})
            return self._send_json(200, todo)

        if path.startswith("/notch/orb"):
            body = PLACEHOLDER_ORB_HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

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

            # Periodic heartbeat: every 5 s rotate session statuses
            # AND emit a state.change / message.in so more of the HUD
            # surface gets exercised (orb aura, peek bubble).
            flip = 0
            states = ["idle", "thinking", "responding"]
            statuses = ["working", "tool_pending", "awaiting_user_input"]
            fake_messages = [
                "Sto ragionando sul prossimo step...",
                "Ho aperto il file e leggo il diff.",
                "Devo confermare prima di procedere.",
            ]
            while True:
                time.sleep(5)
                flip = (flip + 1) % 3
                FAKE_SESSIONS[0]["status"] = statuses[flip]
                send("sessions:update", {
                    "pids": [s["pid"] for s in FAKE_SESSIONS],
                    "ts": int(time.time() * 1000),
                    "sessions": FAKE_SESSIONS,
                })
                # Rotate the high-level agent state — drives the orb's
                # idle/thinking/responding visual.
                send("state.change", {"state": states[flip]})
                # Periodic incoming message so the peek bubble has
                # something to show.
                send("message.in", {"text": fake_messages[flip]})
        except (BrokenPipeError, ConnectionResetError):
            sys.stderr.write("[mock] SSE client disconnected\n")


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
