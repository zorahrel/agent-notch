import Foundation

/// Wire-format versions for every Codable payload that crosses the
/// backend → notch boundary.
///
/// Every payload carries an OPTIONAL `wireVersion: Int?` field. Older
/// backends that pre-date schema versioning omit the field, and the
/// decoder treats `nil` as "version 1" — the baseline shape this
/// release shipped with.
///
/// ### Why "optional" instead of "required"
///
/// agent-notch lives downstream of multiple backends (Jarvis Router,
/// Topics App, agent-conductor). We don't control all of them. Making
/// the field required would mean a backend forgetting to add it breaks
/// the notch entirely; making it optional means missing → fall back to
/// v1 semantics, present → branch on the value.
///
/// ### Forward-compat contract
///
/// If the decoder sees a `wireVersion` GREATER than the constant in
/// `NotchWireVersion.maxSupported`, the payload is still decoded
/// (extra fields are ignored by `JSONDecoder`) but a warning is logged
/// via `NotchLogger`. Callers can read `NotchWireVersion.warnings` to
/// detect the situation programmatically — useful for the
/// Preferences pane to surface "your backend is newer than this
/// agent-notch build, please upgrade".
public enum NotchWireVersion {
    /// Version of the `sessions:update` payload format we expect.
    /// Bump when fields are renamed / removed.
    public static let sessionsUpdate: Int = 1

    /// Version of the `todos:update` payload format we expect.
    public static let todosUpdate: Int = 1

    /// Highest payload version this build can interpret. When a
    /// decoded payload reports a version > this, we still try to use
    /// it but emit a warning so the operator knows the backend is
    /// ahead of the client.
    public static let maxSupported: Int = 1

    /// In-process counter of "I saw a newer-than-supported version"
    /// events. Cheap to read from a Preferences pane or test. NSLock
    /// keeps it well-defined under Swift strict concurrency.
    public static var futureVersionsSeen: Int {
        warningLock.lock(); defer { warningLock.unlock() }
        return _futureVersionsSeen
    }

    static func notePotentialFutureVersion(_ seen: Int, kind: String) {
        warningLock.lock()
        _futureVersionsSeen += 1
        warningLock.unlock()
        NotchLogger.shared.log(
            "warn",
            "[wire] backend sent \(kind) wireVersion=\(seen), max supported=\(maxSupported); decoding optimistically"
        )
    }

    // Reset is test-only — never call from production code.
    static func _resetForTesting() {
        warningLock.lock()
        _futureVersionsSeen = 0
        warningLock.unlock()
    }

    nonisolated(unsafe) private static var _futureVersionsSeen: Int = 0
    private static let warningLock = NSLock()
}
