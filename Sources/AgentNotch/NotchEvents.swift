import Foundation

// MARK: - Agent state model

/// High-level state machine the assistant exposes to the notch UI.
/// Mirrored from the router via SSE `state.change` events.
enum NotchAgentState: String {
    case idle
    case thinking
    case responding
}

// MARK: - Orchestrator payloads (Phase 2 Plan 02-03)

/// Single session entry inside a `sessions:update` payload. Mirrors the
/// shape emitted by the backend's snapshot bridge.
///
/// The `provider` field is OPTIONAL — backends that haven't been updated for
/// the multi-provider model just omit it, and the sidebar falls back to
/// treating every session as the default (Claude Code). Backends running
/// `agent-conductor` v0.4+ will set it to one of: `claude-code`, `aider`,
/// `cursor-cli`, or a custom provider name.
public struct SessionStatusEntry: Codable, Equatable {
    public let pid: Int
    public let repo: String
    public let status: String  // "awaiting_user_input" | "tool_pending" | "crashed" | "working" | "idle"
    public let conflict: Int?
    /// Provider identifier (e.g. `"claude-code"`, `"aider"`, `"cursor-cli"`).
    /// Drives badge colour in the sidebar; falls back to a neutral colour
    /// if the field is missing (older backends).
    public let provider: String?

    public init(pid: Int, repo: String, status: String, conflict: Int?, provider: String? = nil) {
        self.pid = pid
        self.repo = repo
        self.status = status
        self.conflict = conflict
        self.provider = provider
    }
}

/// Snapshot delta carried by a `sessions:update` event. `pids` + `ts` are
/// always present (cheap to construct router-side); `sessions` is the rich
/// payload populated by the snapshot bridge — Swift consumers should prefer
/// it when present and fall back to displaying the raw pids otherwise.
///
/// `wireVersion` is the optional schema-version marker — see
/// `NotchWireVersion`. Missing field → treat as v1 (baseline). A value
/// greater than `NotchWireVersion.maxSupported` triggers a warning log
/// but decoding still proceeds optimistically.
public struct SessionsUpdatePayload: Codable, Equatable {
    public let pids: [Int]
    public let ts: Int64
    public let sessions: [SessionStatusEntry]?
    public let wireVersion: Int?

    public init(pids: [Int], ts: Int64, sessions: [SessionStatusEntry]?, wireVersion: Int? = nil) {
        self.pids = pids
        self.ts = ts
        self.sessions = sessions
        self.wireVersion = wireVersion
    }
}

/// One todo summary inside a `todos:update` payload. `pid` and `phase` come
/// from the metadata line parsed by `services/reminders/metadata.ts` —
/// `nil` when the todo body has no metadata block.
public struct TodoSummary: Codable, Equatable {
    public let id: String
    public let title: String
    public let pid: Int?
    public let phase: String?

    public init(id: String, title: String, pid: Int?, phase: String?) {
        self.id = id
        self.title = title
        self.pid = pid
        self.phase = phase
    }
}

/// Aggregated `todos:update` payload — `count` is the total open todos,
/// `topThree` is the slice rendered by `TodoStripView`.
///
/// `wireVersion` is the optional schema-version marker — see
/// `NotchWireVersion`. Same semantics as `SessionsUpdatePayload`.
public struct TodosUpdatePayload: Codable, Equatable {
    public let count: Int
    public let ts: Int64
    public let topThree: [TodoSummary]?
    public let wireVersion: Int?

    public init(count: Int, ts: Int64, topThree: [TodoSummary]?, wireVersion: Int? = nil) {
        self.count = count
        self.ts = ts
        self.topThree = topThree
        self.wireVersion = wireVersion
    }
}

// MARK: - NotchEvent union

/// Domain events the SSE bus emits to the controller. Models a (small)
/// subset of router events relevant to the notch UI.
///
/// Plan 02-03 adds two orchestrator-side cases (`sessionsUpdate` +
/// `todosUpdate`) and a custom `Codable` conformance so the wire shape
/// `{"type": "...", "data": {...}}` round-trips through `JSONDecoder` for
/// the new cases. Existing cases stay un-Codable (they are produced by the
/// `NotchEventBus.parse(line:)` ad-hoc parser, not by `JSONDecoder.decode`).
enum NotchEvent {
    case stateChange(NotchAgentState)
    case messageIn(String)
    case messageOut(String, String)
    case messageChunk(String)
    case toolRunning(String)
    case agentMeta(String)
    case ttsSpeak(String, String?)  // text, voice identifier (optional)
    case ttsStop
    // Plan 02-03 — orchestrator HUD events.
    case sessionsUpdate(SessionsUpdatePayload)
    case todosUpdate(TodosUpdatePayload)
}

// MARK: - Codable for orchestrator events

/// Decoding contract for `sessions:update` + `todos:update` only. The
/// existing cases are not part of this `Codable` conformance — they are
/// produced by `NotchEventBus.parse(line:)` from raw JSON dictionaries.
extension NotchEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case data
    }

    /// Errors thrown during decode of a NotchEvent JSON payload.
    enum DecodeError: Error {
        case unknownType(String)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "sessions:update":
            let payload = try container.decode(SessionsUpdatePayload.self, forKey: .data)
            // Note newer-than-supported wire versions but decode optimistically;
            // JSONDecoder ignores unknown fields by default so a v2 payload
            // with extra columns degrades gracefully into v1 shape.
            if let v = payload.wireVersion, v > NotchWireVersion.maxSupported {
                NotchWireVersion.notePotentialFutureVersion(v, kind: "sessions:update")
            }
            self = .sessionsUpdate(payload)
        case "todos:update":
            let payload = try container.decode(TodosUpdatePayload.self, forKey: .data)
            if let v = payload.wireVersion, v > NotchWireVersion.maxSupported {
                NotchWireVersion.notePotentialFutureVersion(v, kind: "todos:update")
            }
            self = .todosUpdate(payload)
        default:
            // Unknown future event types throw — callers in production code
            // use `try?` so they decay to nil instead of crashing. The
            // decoder test asserts non-crashing behavior for unknown types.
            throw DecodeError.unknownType(type)
        }
    }
}
