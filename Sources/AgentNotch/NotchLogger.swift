import Foundation
import os.log

/// Process-wide logger for agent-notch.
///
/// Previously wrote to a per-launch truncated file at
/// `~/.claude/jarvis/logs/notch.log` and mirrored to stderr. That file
/// was specific to the original Jarvis layout, leaked across users
/// (`/Users/<other>/.claude/...` would never be readable), and
/// silently dropped output when the home directory was sandboxed or
/// read-only — exactly the case where the user most needed the log.
///
/// This implementation uses Apple's unified logging system
/// (`os.Logger`). Benefits:
///
/// - **Discoverable**: every log line is queryable via
///   `Console.app` (filter by Subsystem
///   `io.armonia.agent-notch`) or from the terminal:
///
///       log stream --predicate 'subsystem == "io.armonia.agent-notch"'
///       log show --predicate 'subsystem == "io.armonia.agent-notch"' --last 1h
///
/// - **Per-level filtering**: macOS persists `error` and `fault`
///   indefinitely, `info` for ~24 h, and `debug` only when streamed.
///   Storage cost stays bounded without us managing rotation.
///
/// - **Privacy classification**: each interpolated value is marked
///   `.public` so log messages stay legible on a release build (the
///   default in `os.Logger` redacts dynamic strings to `<private>`).
///   We intentionally don't log secrets, so making them visible is
///   the correct default for this app.
///
/// - **Stderr mirror**: kept so `swift run agent-notch` from a
///   terminal still shows live logs without needing `log stream` in
///   another window. The mirror is fire-and-forget on stderr; no
///   file handles, no rotation, no failure modes.
///
/// The public `log(_:_:)` signature is unchanged from the old
/// implementation so the ~65 call sites across the codebase keep
/// working without edits.
final class NotchLogger: @unchecked Sendable {
    static let shared = NotchLogger()

    private let logger: Logger
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    init() {
        // Subsystem mirrors the app bundle identifier; category is
        // intentionally coarse — finer-grained categories per file
        // would require touching every call site and breaks the
        // back-compat signature.
        self.logger = Logger(subsystem: "io.armonia.agent-notch", category: "notch")
    }

    /// Log a single line. `level` is one of `debug`, `info`, `warn`,
    /// `error` (anything else maps to the default `.log` level so we
    /// don't lose unfamiliar callers).
    func log(_ level: String, _ text: String) {
        // Stderr mirror so foreground runs see the log live without
        // needing `log stream`. Date prefix keeps parity with the
        // previous formatter so existing log-scraping scripts that
        // grep for `HH:MM:SS.mmm` keep working.
        let ts = dateFormatter.string(from: Date())
        let line = "\(ts) [\(level)] \(text)\n"
        FileHandle.standardError.write(Data(line.utf8))

        // Unified logging dispatch by level.
        switch level.lowercased() {
        case "debug":
            logger.debug("\(text, privacy: .public)")
        case "info":
            logger.info("\(text, privacy: .public)")
        case "warn", "warning":
            logger.notice("\(text, privacy: .public)")  // os.Logger uses `notice` as the warning tier
        case "error":
            logger.error("\(text, privacy: .public)")
        case "fault":
            logger.fault("\(text, privacy: .public)")
        default:
            logger.log("\(text, privacy: .public)")
        }
    }
}
