# Changelog

All notable changes to `agent-notch` are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/).

## [0.1.0] — 2026-05-11

### Added

- **Initial extraction** from [`jarvis-claudecode`](https://github.com/zorahrel/jarvis-claudecode) Phase 2 (`tray-app/Sources/JarvisNotch/`).
- **Dynamic notch HUD** built on [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit):
  - Sessions sidebar (right peek) showing live AI coding sessions with colour-coded status badges
  - Top-3 todo strip with tap-to-complete and long-press-to-reassign gestures
  - Aura + Orb visualisations driven by SSE events
  - Live on-device transcription bubble (Apple `SFSpeechRecognizer`)
- **Backend abstraction (Wave 1)**: HTTP-only via `AGENT_NOTCH_BACKEND_URL` env var. All endpoints centralised in `NotchEndpoints`.
- **10 XCTest specs covering**:
  - `NotchEventDecoder` for `sessions:update` / `todos:update` events (3)
  - `SessionsSidebarView` rendering + bus subscription (3)
  - `TodoStripView` top-3 ordering, tap, long-press picker (3)
  - `NotchEventBus` reconnect replay (1)
- **Sanitised**: all PII / brand-specific references replaced with brand-neutral placeholders. Original Jarvis hardcoded paths removed.

### Notes

- Wave 1 ships HTTP-only. Wave 2 will add an `OrchestratorBackend` that consumes `agent-conductor watch --format json-lines` as a subprocess.
- Distributed as a single executable for now (Swift Package Manager build from source). v0.2 will add a signed `.app` bundle and Homebrew Cask.
- The 67MB `Orb-src/` React source directory from the original repo was excluded — only the built `Orb/` resource (consumed via `Bundle.copy("Orb")`) is committed.

### Removed (vs. extraction source)

- `JarvisTrayApp.swift` and related menu-bar files. These remain in `jarvis-claudecode/tray-app/` as Jarvis-specific (manage launchd services).
- All hardcoded `localhost:3340` URLs. The single source of truth is now `NotchEndpoints.host` with the env-var override.
