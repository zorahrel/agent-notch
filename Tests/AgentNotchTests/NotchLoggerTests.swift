import XCTest
@testable import AgentNotch

/// Smoke tests for `NotchLogger`. `os.Logger` itself is not
/// observable from the test process (entries land in the unified
/// logging subsystem, not in the test runner's stdout), so these
/// tests pin the contract that matters to callers:
///
///   - The singleton exists.
///   - `log(_:_:)` is callable from any thread without crashing
///     across the full level spectrum.
///   - Unknown levels degrade gracefully (default `.log` tier).
///
/// What the unified logging tier did with each line is checked
/// out-of-process with `log show --predicate ...` in CI; we do not
/// scrape the subsystem from a unit test.
final class NotchLoggerTests: XCTestCase {
    func testSingletonReachable() {
        XCTAssertNotNil(NotchLogger.shared)
    }

    func testKnownLevelsDoNotCrash() {
        let l = NotchLogger.shared
        l.log("debug", "[test] debug line")
        l.log("info",  "[test] info line")
        l.log("warn",  "[test] warn line")
        l.log("warning", "[test] warning line (alias)")
        l.log("error", "[test] error line")
        l.log("fault", "[test] fault line")
    }

    func testUnknownLevelDoesNotCrash() {
        NotchLogger.shared.log("banana", "[test] unfamiliar level")
    }

    /// Logger must be safe to call from background queues —
    /// nothing in the implementation should require MainActor.
    func testConcurrentLoggingFromBackgroundQueues() {
        let exp = expectation(description: "all background log calls returned")
        exp.expectedFulfillmentCount = 16
        for i in 0..<16 {
            DispatchQueue.global(qos: .userInitiated).async {
                NotchLogger.shared.log("info", "[test] concurrent line #\(i)")
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 2.0)
    }
}
