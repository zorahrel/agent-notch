import SwiftUI
import AppKit
import AVFoundation
import Speech

/// Standalone notch process. Spawned by the menu-bar host.app via launchctl or
/// direct `Process`, lives in `/Applications/AgentNotch.app`. Keeps the
/// DynamicNotchKit + WKWebView + CGEventTap + mic capture OFF the
/// menubar process so a notch crash doesn't take the tray with it.
///
/// Communication with the rest of the backend happens exclusively through the
/// router (localhost:3340): prefs via `/api/notch/prefs`, voice uploads
/// via `/api/notch/voice`, SSE stream via `/api/notch/stream`. No XPC, no
/// shared memory — the router already is our IPC bus.
/// Minimal NSApplicationDelegate to pin the activation policy to
/// `.accessory` at startup. Without this, a SwiftUI App whose only Scene
/// is `Settings { EmptyView() }` starts in `.regular` and macOS never
/// orders the DynamicNotchKit panel front — the notch exists but is
/// invisible because the app is effectively "not on screen". LSUIElement
/// in Info.plist should do this too, but the SwiftUI scene lifecycle
/// overrides it, so we force it programmatically.
final class NotchAppDelegate: NSObject, NSApplicationDelegate {
    private let launchedAt = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Surface where the on-disk config lives + which backend URL
        // the process ended up using. Users following the README to
        // change the backend port want a single log line telling them
        // whether their edit landed.
        let cfg = AppConfigStore.shared.config
        NotchLogger.shared.log(
            "info",
            "[config] file=\(AppConfig.configFileURL.path) backend=\(cfg.backendURL) schema=\(cfg.schemaVersion)"
        )
        NotchLogger.shared.log(
            "info",
            "[lifecycle] launched pid=\(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundleIdentifier ?? "(no bundle)")"
        )

        // Trigger TCC prompts upfront so the first hover doesn't fail
        // silently. SFSpeechRecognizer + Microphone are needed for the
        // realtime Apple-on-device transcription that powers the live
        // bubble in compact mode. Doing this here (vs lazy on first
        // hover) gives the user a chance to grant before they actually
        // try to talk.
        SFSpeechRecognizer.requestAuthorization { status in
            NotchLogger.shared.log("info", "[perm] speech=\(status.rawValue)")
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            NotchLogger.shared.log("info", "[perm] mic=\(granted)")
        }
    }

    /// Log a single line on graceful exit so post-mortem debugging
    /// can tell "quit cleanly after 4 min" apart from "crashed at 4
    /// min". The runtime guarantees this fires for SIGTERM, Cmd+Q,
    /// and `NSApp.terminate(_:)`; it does NOT fire on SIGKILL or
    /// fatal crash (use the .ips report for those).
    func applicationWillTerminate(_ notification: Notification) {
        let uptime = Date().timeIntervalSince(launchedAt)
        NotchLogger.shared.log(
            "info",
            "[lifecycle] terminating uptime=\(String(format: "%.1f", uptime))s pid=\(ProcessInfo.processInfo.processIdentifier)"
        )
        // Best-effort: tear down notch controller resources before the
        // process exits so timers/monitors don't leak across a quick
        // relaunch.
        NotchController.shared.shutdown()
    }
}

@main
struct AgentNotchApp: App {
    @NSApplicationDelegateAdaptor(NotchAppDelegate.self) var delegate

    init() {
        // Defer the notch mount by one run-loop tick so NSScreen reports
        // the safe area insets correctly.
        DispatchQueue.main.async {
            NotchController.shared.mount()
        }
    }

    /// No UI scene — this process is headless except for the notch panel.
    /// `Settings` (empty) satisfies the App protocol's "at least one scene"
    /// requirement; a `MenuBarExtra` here would double-render the menubar
    /// owned by the menu-bar host.
    var body: some Scene {
        Settings { EmptyView() }
    }
}
