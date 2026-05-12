import XCTest
@testable import AgentNotch

/// Token-based subscribe / unsubscribe contract for `NotchEventBus`.
///
/// Pre-PR-1 the unsubscribe closure was a no-op
/// (`removeAll(where: { _ in false })`). PR #1 replaced the closure list
/// with a `[Int: closure]` dictionary keyed by a monotonic token, and the
/// returned unsubscribe closure removes the exact token, is idempotent,
/// and is safe to call after the bus has been torn down.
///
/// These tests pin the contract so a future refactor cannot quietly
/// regress it.
final class NotchEventBusSubscribeTests: XCTestCase {
    @MainActor
    override func setUp() {
        super.setUp()
        NotchEventBus.shared.resetForTesting()
    }

    /// Sanity: subscribe → publish → handler fires.
    @MainActor
    func testSubscribeReceivesEvent() {
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        let unsubscribe = NotchEventBus.shared.subscribe { _ in counter.n += 1 }
        defer { unsubscribe() }

        NotchEventBus.shared.publishForTesting(.todosUpdate(
            TodosUpdatePayload(count: 0, ts: 0, topThree: nil)
        ))

        XCTAssertEqual(counter.n, 1, "handler should fire exactly once per publish")
    }

    /// Unsubscribe actually unsubscribes. Calling the returned closure
    /// must stop further events from reaching the handler. This is the
    /// regression test for the PR-1 leak fix — pre-fix this assertion
    /// would have failed (handler kept firing forever).
    @MainActor
    func testUnsubscribeStopsDelivery() async {
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        let unsubscribe = NotchEventBus.shared.subscribe { _ in counter.n += 1 }

        NotchEventBus.shared.publishForTesting(.todosUpdate(
            TodosUpdatePayload(count: 1, ts: 0, topThree: nil)
        ))
        XCTAssertEqual(counter.n, 1)

        unsubscribe()
        // The unsubscribe closure hops onto the MainActor via Task to
        // perform the actual dictionary removal — give that hop a chance
        // to run before we publish again.
        await Task.yield()

        NotchEventBus.shared.publishForTesting(.todosUpdate(
            TodosUpdatePayload(count: 2, ts: 0, topThree: nil)
        ))
        XCTAssertEqual(counter.n, 1, "post-unsubscribe events must not reach the handler")
    }

    /// Calling unsubscribe twice is idempotent (no crash, no second
    /// dictionary access mishap).
    @MainActor
    func testDoubleUnsubscribeIsIdempotent() async {
        let unsubscribe = NotchEventBus.shared.subscribe { _ in }
        unsubscribe()
        await Task.yield()
        unsubscribe()
        await Task.yield()
        // Surviving without crash is the assertion.
    }

    /// Two independent subscribers each get their own token; unsubscribing
    /// one must NOT affect the other.
    @MainActor
    func testIndependentTokensPerSubscriber() async {
        final class Counter: @unchecked Sendable { var a = 0; var b = 0 }
        let counter = Counter()
        let unsubA = NotchEventBus.shared.subscribe { _ in counter.a += 1 }
        let unsubB = NotchEventBus.shared.subscribe { _ in counter.b += 1 }

        NotchEventBus.shared.publishForTesting(.todosUpdate(
            TodosUpdatePayload(count: 0, ts: 0, topThree: nil)
        ))
        XCTAssertEqual(counter.a, 1)
        XCTAssertEqual(counter.b, 1)

        unsubA()
        await Task.yield()

        NotchEventBus.shared.publishForTesting(.todosUpdate(
            TodosUpdatePayload(count: 0, ts: 0, topThree: nil)
        ))
        XCTAssertEqual(counter.a, 1, "A unsubscribed — must not fire")
        XCTAssertEqual(counter.b, 2, "B must keep firing")

        unsubB()
        await Task.yield()
    }

    /// A subscriber that unsubscribes itself mid-dispatch must not
    /// crash. PR-1 wraps the broadcast in `Array(values)` precisely so
    /// this re-entrant pattern is safe.
    @MainActor
    func testReentrantUnsubscribeDuringDispatch() async {
        final class Box: @unchecked Sendable { var unsub: (() -> Void)? }
        let box = Box()
        var fired = 0

        box.unsub = NotchEventBus.shared.subscribe { _ in
            fired += 1
            box.unsub?()  // self-unsubscribe from inside the handler
        }

        NotchEventBus.shared.publishForTesting(.todosUpdate(
            TodosUpdatePayload(count: 0, ts: 0, topThree: nil)
        ))
        // First publish: handler fires once and self-unsubscribes.
        XCTAssertEqual(fired, 1)
        await Task.yield()

        NotchEventBus.shared.publishForTesting(.todosUpdate(
            TodosUpdatePayload(count: 0, ts: 0, topThree: nil)
        ))
        XCTAssertEqual(fired, 1, "self-unsubscribed handler must not fire a second time")
    }

    /// `subscribe` replays cached snapshots so a late-arriving view
    /// materializes immediately. The replay is dispatched via
    /// `DispatchQueue.main.async`, so we await the hop.
    @MainActor
    func testSubscribeReplaysLastSessionsSnapshot() {
        // Seed a snapshot into the bus's cache.
        let payload = SessionsUpdatePayload(
            pids: [7],
            ts: 0,
            sessions: [.init(pid: 7, repo: "lucky", status: "working", conflict: nil)]
        )
        NotchEventBus.shared.publishForTesting(.sessionsUpdate(payload))

        final class Box: @unchecked Sendable { var seen: [Int] = [] }
        let box = Box()
        let unsubscribe = NotchEventBus.shared.subscribe { event in
            if case .sessionsUpdate(let p) = event {
                box.seen = p.pids
            }
        }
        defer { unsubscribe() }

        // Drain the async hop the bus uses for replay.
        let exp = expectation(description: "replay landed")
        DispatchQueue.main.async {
            DispatchQueue.main.async { exp.fulfill() }
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(box.seen, [7], "new subscriber must receive the cached snapshot")
    }
}
