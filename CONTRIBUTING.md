# Contributing to agent-notch

Thanks for considering a contribution. Quick guide below; the philosophy is the same as in [`agent-conductor`](https://github.com/zorahrel/agent-conductor): small focused PRs, tests with every behaviour change, no surprise dependencies.

## Quick start

```bash
git clone https://github.com/zorahrel/agent-notch.git
cd agent-notch
swift build              # debug
swift test               # XCTest suite (10 specs)
swift run agent-notch    # foreground run
```

## What gets merged faster

- **UI improvements** for the sidebar / todo strip / aura — clearer info hierarchy, better motion, accessibility (VoiceOver labels)
- **macOS sandbox / TCC entitlement fixes** — anything that smooths the install experience
- **New backend implementations** under `NotchBackend` (planned Wave 2 contract). Today only HTTP exists.
- **Tests for edge cases** — disconnect/reconnect, malformed SSE, missing tmux pane

## What needs discussion first

- Any new SwiftPM dependency (each one slows builds, eats binary size). Open an issue with the trade-off.
- Anything that adds a network call by default (no telemetry).
- API changes to `NotchEndpoints` — these are consumed by backends; bumping the major minor must be coordinated.

## Code style

- Swift 5.9, strict concurrency where practical
- SwiftUI for new views; no UIKit / AppKit unless the API requires it
- File header docs: 1-3 lines explaining the purpose of the file
- Public symbols: only mark `public` when something is actually consumed across modules. In the Wave 1 single-target layout, almost everything is internal.

## Commits

Conventional Commits, loosely:

```
feat(notch): add dim-when-fullscreen behaviour
fix(events): SSE reconnect now replays last snapshot
docs(readme): clarify AGENT_NOTCH_BACKEND_URL examples
refactor(views): split NotchViews.swift by mode
test(bus): cover graceful disconnect mid-stream
chore(deps): bump DynamicNotchKit to 1.2.0
```

Squash-merge is the default.

## Code review

Maintainers look for:

- `swift test` GREEN
- `swift build -c release` succeeds without warnings on macOS 14+
- No PII or user-specific paths in new fixtures
- No leftover Jarvis-/Topics-/agent-conductor-specific hardcoding
- Public API (`NotchEndpoints`) hasn't grown accidentally

Expect a turnaround within a week.

## Security

See [SECURITY.md](./SECURITY.md). Do not file security issues publicly.

## License

MIT, per [LICENSE](./LICENSE).
