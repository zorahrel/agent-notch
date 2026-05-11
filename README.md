<div align="center">
  <img src="./assets/logo.svg" alt="agent-notch logo" width="160" height="160"/>

  # agent-notch

  **Live AI coding sessions, in your MacBook Pro dynamic notch.**

  Always-on HUD over the macOS dynamic notch + menu-bar surface. Shows which sessions are awaiting your input, which are stuck on a tool call, and your top open todos — without flipping windows.

  <p>
    <a href="https://github.com/zorahrel/agent-notch/releases"><img src="https://img.shields.io/badge/version-0.2.0-a78bfa?style=flat-square" alt="version"/></a>
    <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-22c55e?style=flat-square" alt="license"/></a>
    <a href="https://github.com/zorahrel/agent-notch/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/zorahrel/agent-notch/ci.yml?branch=main&label=ci&style=flat-square" alt="ci"/></a>
    <img src="https://img.shields.io/badge/tests-10%20green-22c55e?style=flat-square" alt="tests"/>
    <img src="https://img.shields.io/badge/multi--provider-yes-a78bfa?style=flat-square" alt="multi-provider"/>
    <img src="https://img.shields.io/badge/swift-5.9+-f97316?style=flat-square" alt="swift"/>
    <img src="https://img.shields.io/badge/macOS-14+-0f172a?style=flat-square" alt="macos"/>
  </p>
</div>

---

## What it shows

When you hover the notch, you get an expanded HUD with:

- **Sessions sidebar (right peek)** — every live AI coding agent session your machine is running. Each row shows:
  - **Outer ring colour** = provider (Claude orange-amber, Aider green, Cursor blue, ChatGPT teal-green, custom = grey)
  - **Inner dot colour** = refined status (`awaiting_user_input` orange, `tool_pending` blue, `crashed` red, `working` green, `idle` grey)
  - **Tooltip** = provider display name (e.g. "Claude Code")
  - **Click** → opens the orchestrator dashboard tab focused on that pid
- **Todo strip (thin row, top or bottom)** — top-3 open todos from your Apple Reminders list. Tap = mark complete. Long-press = reassign to a different session.
- **Aura + Orb visualisations** — voice activity feedback (driven by SSE events).
- **Live transcription bubble** — local on-device Apple speech recognition during voice input.

The notch widget is built on [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit), the de-facto Swift API for the M3+ MacBook Pro dynamic notch.

## Why a standalone app

It started as Phase 2 of an internal multi-channel router (Jarvis). Extracted because the HUD is genuinely reusable — anyone running multiple AI coding agents in parallel benefits from a unified notch surface, regardless of which backend orchestrates the sessions. Two consumers planned:

- **Jarvis Router** — current default backend. HTTP at `localhost:3340`.
- **Topics App** — future consumer. Will run its own backend.
- **Standalone with `agent-conductor`** — planned for v0.2. The CLI in [`agent-conductor`](https://github.com/zorahrel/agent-conductor) will gain a `watch` subcommand that streams JSON-Lines on stdout; this app will spawn it as a subprocess. Zero HTTP, zero ports, zero config.

## Install

Build a real `.app` bundle (Info.plist + TCC usage strings + ad-hoc
codesign) and drop it into `/Applications`:

```bash
git clone https://github.com/zorahrel/agent-notch.git
cd agent-notch
./scripts/build-app.sh --install
```

The output lands at `dist/AgentNotch.app` (and at
`/Applications/AgentNotch.app` when `--install` is passed). Double-
click to launch, or:

```bash
open /Applications/AgentNotch.app
```

A Developer-ID-signed + notarized bundle and a Homebrew Cask are on
the v0.2 release plan.

### Old recipe (plain executable, no bundle)

```bash
swift build -c release
cp .build/release/agent-notch /Applications/agent-notch
```

This still works but skips TCC usage strings, so the first
Microphone / Speech-Recognition prompt won't show a friendly message
and `LSUIElement` won't be set (the executable runs with a Dock
icon). Use the `.app` recipe above for everything except quick
development iteration.

## Configuration

The app reads its backend URL from an environment variable.

```bash
# Default (matches Jarvis Router setup):
AGENT_NOTCH_BACKEND_URL=http://localhost:3340

# Topics App on a different port:
AGENT_NOTCH_BACKEND_URL=http://localhost:4200

# Remote backend (over an SSH tunnel, e.g.):
AGENT_NOTCH_BACKEND_URL=http://127.0.0.1:9999
```

The backend must expose:

| Endpoint | Method | Purpose |
|---|---|---|
| `/api/notch/stream` | `GET` (SSE) | Push channel for all real-time events (sessions, todos, voice) |
| `/api/notch/send` | `POST` | Submit a user-typed message to the chat backend |
| `/api/notch/prefs` | `GET`/`POST` | Read & persist user preferences (UI density, theme) |
| `/api/notch/voice` | `POST` (multipart) | Upload an audio blob, returns transcription |
| `/api/notch/abort` | `POST` | Cancel the in-flight LLM call |
| `/api/local-sessions` | `GET` | List live AI coding sessions (drives the sidebar) |
| `/api/todos/<id>` | `GET`/`PATCH` | Read / reassign a todo |
| `/api/todos/<id>/complete` | `POST` | Mark a todo done |

Reference implementations live in [`jarvis-claudecode`](https://github.com/zorahrel/jarvis-claudecode) (router/dashboard) and the `examples/` folder of [`agent-conductor`](https://github.com/zorahrel/agent-conductor).

## Roadmap

### v0.2 — Subprocess backend (planned)

- [ ] `OrchestratorBackend` Swift class that spawns `agent-conductor watch --format json-lines` and pipes stdout into the event bus
- [ ] `NotchBackend` protocol so users can pick HTTP vs subprocess in the Preferences pane
- [ ] Drop the `AGENT_NOTCH_BACKEND_URL` env var as the only config — add a `~/Library/Application Support/agent-notch/config.json`
- [ ] Pre-built signed `.app` bundle via GitHub Releases

### v0.3 — Multi-provider chat surface

- [ ] `ChatProvider` protocol: ClaudeChatProvider, OpenAIChatProvider
- [ ] Subscription-based auth (Claude.ai web session, ChatGPT web session) — no per-token API keys required for users with a subscription
- [ ] Per-provider chat tab in the expanded notch view
- [ ] Tool exposure: `agent-conductor` primitives (`snapshot`, `inject`, `todos`) become callable tools that any chat provider can invoke through function calling / MCP

### v0.4 — Polish

- [ ] Homebrew Cask: `brew install --cask agent-notch`
- [ ] Auto-update via Sparkle
- [ ] Localisation (it, fr, de, ja, zh)
- [ ] Accessibility: VoiceOver labels for every HUD element

### Maybe-someday

- [ ] iOS companion (notch on iPhone shows the same view via Bonjour)
- [ ] System extensions for non-notch Macs (M1 / Intel / external displays) → menu-bar window equivalent
- [ ] Plug-in API: third-party views render as widgets inside the expanded notch

## Architecture

```
┌─────────────────────────────────────────────────┐
│  agent-notch.app  (this repo)                   │
│                                                 │
│   ┌──────────────────┐    ┌──────────────────┐  │
│   │  NotchController │ ←→ │   NotchEventBus  │  │
│   └────────┬─────────┘    └────────┬─────────┘  │
│            │                       │            │
│            ▼                       ▼            │
│   ┌──────────────────┐    ┌──────────────────┐  │
│   │ DynamicNotchKit  │    │  HTTP / SSE      │  │
│   │   panels +       │    │  client          │  │
│   │   SwiftUI views  │    │ (Wave 2:         │  │
│   └──────────────────┘    │  subprocess too) │  │
│                           └──────────────────┘  │
└─────────────────────────────────────────────────┘
            │                       ▲
            │                       │
            ▼                       │
  ┌─────────────────┐   HTTP / SSE  │
  │  Your backend   │ ──────────────┘
  │                 │
  │  jarvis-router  │  ← default consumer today
  │  topics-app     │  ← future consumer
  │  agent-conductor│  ← future, via subprocess (Wave 2)
  └─────────────────┘
```

## Development

```bash
git clone https://github.com/zorahrel/agent-notch.git
cd agent-notch
swift build
swift test
swift run agent-notch              # foreground run with logs
```

The notch will appear as soon as you hover the top centre of your screen. Quit via the menu-bar host or `pkill agent-notch`.

## Privacy & data

- No telemetry. No analytics. No network calls except to the backend URL you configure.
- Voice transcription is on-device (Apple's `SFSpeechRecognizer` framework).
- Audio data is only uploaded to your backend if you explicitly trigger a voice command via hover-record.
- No PII in any committed fixture or test.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). Bug reports and feature requests via [GitHub issues](https://github.com/zorahrel/agent-notch/issues).

## License

[MIT](./LICENSE)
