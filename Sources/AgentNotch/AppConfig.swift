import Foundation

/// Persistent user configuration for agent-notch.
///
/// Before v0.2 the only knob was the `AGENT_NOTCH_BACKEND_URL` env var.
/// That was hostile to non-developer users: setting an env var on
/// macOS requires `launchctl setenv` or a custom `LaunchAgents` plist,
/// neither of which lend themselves to a friendly Preferences pane.
///
/// `AppConfig` is the on-disk replacement, stored as a JSON document in
/// the standard macOS Application Support directory:
///
///     ~/Library/Application Support/agent-notch/config.json
///
/// ### Precedence
///
/// 1. `AGENT_NOTCH_BACKEND_URL` env var, if set (back-compat with
///    Wave 1 / scripted launches like Jarvis).
/// 2. Value read from `config.json`.
/// 3. Built-in default (`http://localhost:3340`).
///
/// ### Schema version
///
/// `schemaVersion` lets future builds detect old on-disk shapes and
/// either migrate or fall back to defaults instead of crashing on a
/// `JSONDecoder` mismatch. Current version: 1.
public struct AppConfig: Codable, Equatable {
    /// Wire-format version. Bump when fields are renamed or removed so
    /// older agent-notch builds reading a newer file can fall back
    /// gracefully instead of throwing on decode.
    public var schemaVersion: Int

    /// Base origin the HTTP / SSE backend lives on. Used by
    /// `NotchEndpoints` to build every URL the controller talks to.
    public var backendURL: String

    /// Sensible defaults for a fresh install. Matches the Wave 1
    /// `AGENT_NOTCH_BACKEND_URL` fallback so existing users see no
    /// behaviour change on upgrade.
    public static let `default` = AppConfig(
        schemaVersion: 1,
        backendURL: "http://localhost:3340"
    )

    // MARK: - Disk layout

    /// `~/Library/Application Support/agent-notch/`.
    public static var supportDirectoryURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("agent-notch", isDirectory: true)
    }

    /// `~/Library/Application Support/agent-notch/config.json`.
    public static var configFileURL: URL {
        supportDirectoryURL.appendingPathComponent("config.json", isDirectory: false)
    }

    // MARK: - Load / save

    /// Read `config.json` from disk and apply the env-var override. If
    /// the file does not exist we write the defaults and return them so
    /// the next launch already has a discoverable file on disk that the
    /// user (or a Preferences pane) can edit by hand.
    ///
    /// Decoding failures fall back to the defaults rather than throw,
    /// so a corrupt file never blocks app startup. The corrupt file is
    /// renamed to `config.broken.<timestamp>.json` so the user can
    /// recover their settings post-mortem.
    @discardableResult
    public static func load() -> AppConfig {
        var loaded = AppConfig.default

        if FileManager.default.fileExists(atPath: configFileURL.path) {
            do {
                let data = try Data(contentsOf: configFileURL)
                loaded = try JSONDecoder().decode(AppConfig.self, from: data)
            } catch {
                // Quarantine the bad file so the user can inspect it,
                // then carry on with defaults.
                let ts = Int(Date().timeIntervalSince1970)
                let broken = supportDirectoryURL
                    .appendingPathComponent("config.broken.\(ts).json")
                try? FileManager.default.moveItem(at: configFileURL, to: broken)
                NSLog("[agent-notch] config.json unreadable (\(error)); moved to \(broken.lastPathComponent), using defaults")
            }
        } else {
            // First launch — try to write defaults so the user has a
            // template to edit. Ignore write errors; we still return
            // the in-memory defaults.
            try? AppConfig.default.save()
        }

        return loaded.applyingEnvironmentOverrides()
    }

    /// Write the current value to disk as pretty-printed JSON. Creates
    /// the support directory if it does not exist.
    public func save() throws {
        try FileManager.default.createDirectory(
            at: Self.supportDirectoryURL,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: Self.configFileURL, options: .atomic)
    }

    // MARK: - Environment overrides

    /// Returns a copy with any matching env-var overrides applied.
    /// Logs a warning when the env value differs from the file value
    /// so the user notices when a leftover `launchctl setenv` setting
    /// is silently winning over their edited `config.json`. (Default-
    /// value first launches don't log — the two values match by
    /// construction.) Kept pure-ish: only side effect is the log.
    func applyingEnvironmentOverrides() -> AppConfig {
        var copy = self
        let env = ProcessInfo.processInfo.environment
        if let override = env["AGENT_NOTCH_BACKEND_URL"], !override.isEmpty {
            if override != self.backendURL {
                NotchLogger.shared.log(
                    "warn",
                    "[config] AGENT_NOTCH_BACKEND_URL env var (\(override)) is overriding config.json value (\(self.backendURL)); unset the env var or edit ~/Library/LaunchAgents to make the file value win"
                )
            }
            copy.backendURL = override
        }
        return copy
    }
}

/// Process-wide cached view onto `AppConfig`.
///
/// `AppConfig.load()` touches the filesystem; we read once at process
/// start and hold the resulting value here so the per-URL accessors in
/// `NotchEndpoints` stay zero-cost. Mutating helpers (`update(_:)`,
/// `reload()`) re-serialize and refresh the cached value.
@MainActor
public final class AppConfigStore {
    public static let shared = AppConfigStore()

    public private(set) var config: AppConfig

    private init() {
        self.config = AppConfig.load()
    }

    /// Replace the in-memory config and persist it to disk. Throws if
    /// the write fails; the in-memory value is updated regardless so
    /// the running process picks up the new value immediately. Also
    /// refreshes `NotchEndpoints.host` so subsequent URL builds use
    /// the new backend.
    ///
    /// MainActor-isolated by virtue of the enclosing class, so the
    /// (mutate → save → refresh) sequence is atomic from any other
    /// MainActor caller's perspective. `NotchEndpoints.refresh(host:)`
    /// receives the already-resolved URL — no extra disk read.
    public func update(_ mutate: (inout AppConfig) -> Void) throws {
        var next = config
        mutate(&next)
        // Apply env overrides AFTER the mutation so the URL we hand
        // to NotchEndpoints matches what AppConfig.load() would return
        // on next launch.
        let resolved = next.applyingEnvironmentOverrides()
        config = next
        try next.save()
        NotchEndpoints.refresh(host: resolved.backendURL)
    }

    /// Re-read the config from disk and re-apply env overrides. Useful
    /// after an external edit of `config.json`.
    public func reload() {
        config = AppConfig.load()
        NotchEndpoints.refresh(host: config.backendURL)
    }
}
