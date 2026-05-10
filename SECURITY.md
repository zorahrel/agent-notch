# Security Policy

## Supported Versions

| Version  | Supported          |
| -------- | ------------------ |
| 0.3.x    | ✅ Active           |
| 0.2.x    | ⚠️ Security fixes only until 2026-08 |
| < 0.2    | ❌ Not supported    |

## Reporting a Vulnerability

If you find a security issue, **please do not open a public GitHub issue**.

Instead, use [GitHub Private Vulnerability Reporting](https://github.com/zorahrel/agent-notch/security/advisories/new) to disclose the issue confidentially.

When reporting, please include:

- A description of the issue and its impact
- Steps to reproduce (or a proof-of-concept)
- Any suggested mitigation, if you have one
- Your preferred attribution in a future advisory (name, handle, or anonymous)

You can expect:

- An acknowledgement within **3 business days**
- A triage decision within **7 business days**
- A patch released or a clear timeline within **30 business days** for high-severity issues

## Threat model

`agent-notch` operates locally on the user's machine and talks only to the configured backend URL. The main attack surfaces:

1. **Backend SSE stream** — the HUD subscribes to `/api/notch/stream` and renders events. Mitigations:
   - Strict `Codable` decoding per event (unknown fields ignored, malformed lines dropped)
   - Reconnect with exponential backoff (no DoS via crash loop)
   - The view layer never `eval`s any string — events are data only
2. **WKWebView (Orb HTML)** — we render a small React app inside a sandboxed `WKWebView` for visual flair. Mitigations:
   - `Orb/` resource ships with the app bundle; the WebView loads from `bundle://` not network
   - `WKWebView` is configured with `javaScriptEnabled: true` but the page has no fetch / XHR to external origins
   - No file:// access; no inter-origin messaging
3. **Voice / audio capture** — `AVCaptureDevice` is requested only after the user grants the TCC prompt. Mitigations:
   - Audio is uploaded to the configured backend URL only, and only when the user explicitly triggers hover-record
   - Local transcription via Apple's on-device `SFSpeechRecognizer` (no third-party model, no network)
4. **CGEventTap** — the HUD installs a global event tap to detect notch-area hovers. Mitigations:
   - Tap is mouse-events-only (no keyboard, no clipboard)
   - All events are throttled to 60Hz before reaching the HUD
   - The tap is torn down on app quit / sleep

We do not currently ship code-signing, notarisation, or SBOM. All three are on the v0.2 → v0.4 roadmap.

## Out of scope

- Issues in dependencies' dependencies (file those upstream)
- Anything requiring physical access to an already-compromised machine
- Theoretical issues without a proof-of-concept

Thank you for helping keep `agent-notch` and its users safe.
