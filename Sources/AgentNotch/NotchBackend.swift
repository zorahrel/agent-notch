import Foundation

// MARK: - NotchBackend protocol

/// Transport abstraction for the operations agent-notch performs on its
/// backend.
///
/// Wave 1 / Wave 2 (today) — there is only one implementation,
/// `HTTPBackend`, which is a thin wrapper over `URLSession` against the
/// endpoints documented in the README. Wave 3 will add a second
/// implementation, `OrchestratorBackend`, that spawns
/// `agent-conductor watch --format json-lines` as a subprocess and
/// pipes its stdout into the event bus, eliminating the need for a
/// running HTTP server.
///
/// **Scope** — the protocol covers the imperative operations
/// (send a message, abort, upload a voice blob, mark a todo done).
/// It does NOT cover the SSE event stream — that stays on
/// `NotchEventBus`, which is the in-process fan-out layer. The backend
/// is the transport; the bus is the distribution. The two are
/// deliberately orthogonal so a subprocess backend can simply publish
/// into the bus from a stdout reader without growing a new subscriber
/// API.
///
/// **Concurrency** — every method is `async throws` so backends are
/// free to do real network calls, subprocess pipes, or in-memory work.
/// Conformers must be `Sendable` so they can be passed across actors
/// (typical caller is the main-actor `NotchController`).
public protocol NotchBackend: Sendable {
    /// Submit a user-typed message to the chat backend.
    func sendMessage(_ text: String) async throws

    /// Cancel the in-flight LLM call. No-op if nothing is in flight.
    func abort() async throws

    /// Upload a recorded audio blob and return the server's
    /// transcription result. The blob is whatever the recorder writes
    /// to disk (currently 16 kHz mono Int16 WAV).
    func uploadVoice(_ data: Data) async throws -> VoiceUploadResult

    /// List live AI coding sessions known to the backend.
    func listSessions() async throws -> [SessionStatusEntry]

    /// Mark a todo done.
    func completeTodo(id: String) async throws

    /// Read user preferences as a raw JSON blob. The notch panel
    /// merges this with its own SwiftUI defaults; we don't try to
    /// model the schema here.
    func loadPrefs() async throws -> Data

    /// Write a JSON patch back to the preferences endpoint. The
    /// payload is whatever the controller assembled (typically a
    /// `{"key": value}` patch object).
    func savePrefs(_ patch: Data) async throws
}

// MARK: - VoiceUploadResult

/// Server response for a voice upload — the transcript plus an
/// optional confidence score (some backends provide it, some don't).
public struct VoiceUploadResult: Codable, Equatable, Sendable {
    public let transcript: String
    public let confidence: Double?

    public init(transcript: String, confidence: Double? = nil) {
        self.transcript = transcript
        self.confidence = confidence
    }
}

// MARK: - NotchBackendError

/// Error type that backend implementations throw. Conformers can wrap
/// transport-specific errors (`URLError`, `Process.TerminationReason`)
/// into one of these cases so the controller has a small, stable set
/// of failure modes to display.
public enum NotchBackendError: Error, Equatable, Sendable {
    /// Network / pipe unreachable.
    case unreachable(reason: String)
    /// Backend responded but with a non-2xx status code.
    case http(status: Int, body: String?)
    /// Decoding the backend's response failed.
    case decodeFailure(reason: String)
    /// Operation was cancelled before completing.
    case cancelled
}
