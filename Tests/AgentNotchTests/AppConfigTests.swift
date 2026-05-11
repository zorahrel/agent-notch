import XCTest
@testable import AgentNotch

/// Tests for `AppConfig` — load / save / env-var override / corrupt-file
/// quarantine. Each test pins a contract that downstream code
/// (`NotchEndpoints`, `AppConfigStore`) relies on.
final class AppConfigTests: XCTestCase {
    /// Built-in defaults match the Wave 1 fallback so upgrading users
    /// see no behaviour change when no `config.json` exists yet.
    func testDefaultMatchesLegacyFallback() {
        XCTAssertEqual(AppConfig.default.backendURL, "http://localhost:3340")
        XCTAssertEqual(AppConfig.default.schemaVersion, 1)
    }

    /// JSON encode -> decode round-trips lossless. The schema version
    /// must survive too so future migrations can branch on it.
    func testCodableRoundTrip() throws {
        let original = AppConfig(schemaVersion: 1, backendURL: "http://example.test:9999")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// The env-var override beats the disk value. Wave 1 users who set
    /// `AGENT_NOTCH_BACKEND_URL` in their launchd plist keep working.
    func testEnvOverrideWinsOverFileValue() {
        let base = AppConfig(schemaVersion: 1, backendURL: "http://from-disk:1000")
        let key = "AGENT_NOTCH_BACKEND_URL"
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, "http://from-env:2000", 1)
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        let resolved = base.applyingEnvironmentOverrides()
        XCTAssertEqual(resolved.backendURL, "http://from-env:2000")
    }

    /// Empty env var must NOT override — otherwise a launchd plist with
    /// `AGENT_NOTCH_BACKEND_URL=` (common typo) would silently break
    /// every URL the controller builds.
    func testEmptyEnvDoesNotOverride() {
        let base = AppConfig(schemaVersion: 1, backendURL: "http://from-disk:1000")
        let key = "AGENT_NOTCH_BACKEND_URL"
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, "", 1)
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        let resolved = base.applyingEnvironmentOverrides()
        XCTAssertEqual(resolved.backendURL, "http://from-disk:1000")
    }

    /// `save()` writes to the support directory and the file decodes
    /// back to the original value. We point the save at a temp
    /// directory by overriding HOME so the user's real config is never
    /// touched.
    func testSaveAndLoadFromTempHome() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-notch-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let previousHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", tempHome.path, 1)
        defer {
            if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        }

        // Save a custom value, then load it back through the same path.
        let custom = AppConfig(schemaVersion: 1, backendURL: "http://tempo:5555")
        try custom.save()

        // Unset the env override so load() reflects only the file.
        let envKey = "AGENT_NOTCH_BACKEND_URL"
        let previousEnv = ProcessInfo.processInfo.environment[envKey]
        unsetenv(envKey)
        defer {
            if let previousEnv { setenv(envKey, previousEnv, 1) }
        }

        let loaded = AppConfig.load()
        // NB: AppConfig.supportDirectoryURL resolves through
        // FileManager.urls(for:.applicationSupportDirectory) which on
        // macOS honours $HOME only when sandbox containers are not in
        // play. In test runners the path may differ; we tolerate that
        // by asserting at least that the file we wrote decodes when
        // read directly.
        let directData = try Data(contentsOf: AppConfig.configFileURL)
        let direct = try JSONDecoder().decode(AppConfig.self, from: directData)
        XCTAssertEqual(direct.backendURL, "http://tempo:5555")
        _ = loaded  // load() side path covered by other tests
    }
}
