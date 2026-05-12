import XCTest
@testable import AgentNotch

/// Contract tests for `NotchController.shutdown()`.
///
/// `NotchController.shared` is a process-wide singleton wired into the
/// dynamic-notch panel, NSEvent monitors, and a CGEvent tap. Touching
/// it from tests risks bleeding state across unrelated test cases, so
/// these tests deliberately stay on the public surface: we verify
/// `shutdown()` is callable, idempotent, and does not crash regardless
/// of how many times it is invoked.
///
/// The deeper guarantees (Task cancellation, NSEvent removeMonitor,
/// CGEventTap teardown) are integration-test territory and need a
/// running app harness to assert meaningfully — out of scope for the
/// SwiftPM test bundle.
final class NotchControllerShutdownTests: XCTestCase {
    /// `shutdown()` must be safe to call even when nothing was ever
    /// `mount()`ed. The fresh-process case: tests run before
    /// AgentNotchApp launches the controller, so every Task slot is nil
    /// and there is no NSEvent monitor to remove.
    @MainActor
    func testShutdownOnFreshControllerIsSafe() {
        // We deliberately do NOT touch `mount()`; we just call shutdown
        // and assert no crash. This is the contract: shutdown must
        // tolerate a never-started controller.
        NotchController.shared.shutdown()
    }

    /// Idempotence: calling `shutdown()` twice in a row must not crash
    /// or assert. The deinit path also calls the same cleanup, so we
    /// want the cleanup itself to be re-entrant-safe.
    @MainActor
    func testShutdownIsIdempotent() {
        NotchController.shared.shutdown()
        NotchController.shared.shutdown()
    }
}
