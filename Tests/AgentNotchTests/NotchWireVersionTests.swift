import XCTest
@testable import AgentNotch

/// Schema-version forward-compat tests.
///
/// The contract is:
///   - Older backends omit `wireVersion`. Decoder must succeed and
///     leave the field nil (no log, no warning counter bump).
///   - Backends at the current version send `wireVersion = 1`.
///     Decoder succeeds, no warning counter bump.
///   - Future backends send `wireVersion > maxSupported`. Decoder
///     still succeeds (extra fields ignored), warning counter bumps.
final class NotchWireVersionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        NotchWireVersion._resetForTesting()
    }

    func testCurrentMaxSupportedIsOne() {
        XCTAssertEqual(NotchWireVersion.maxSupported, 1)
        XCTAssertEqual(NotchWireVersion.sessionsUpdate, 1)
        XCTAssertEqual(NotchWireVersion.todosUpdate, 1)
    }

    /// Missing field → nil. No counter bump.
    func testSessionsPayloadWithoutWireVersionDecodes() throws {
        let json = #"{"pids":[1],"ts":0}"#
        let p = try JSONDecoder().decode(SessionsUpdatePayload.self, from: Data(json.utf8))
        XCTAssertNil(p.wireVersion)
    }

    /// Current version → decodes, counter NOT bumped.
    func testSessionsPayloadV1DecodesQuietly() throws {
        let json = #"{"pids":[1],"ts":0,"wireVersion":1}"#
        let event = try JSONDecoder().decode(NotchEvent.self,
            from: Data(#"{"type":"sessions:update","data":\#(json)}"#.utf8))
        guard case .sessionsUpdate(let p) = event else {
            return XCTFail("expected sessionsUpdate")
        }
        XCTAssertEqual(p.wireVersion, 1)
        XCTAssertEqual(NotchWireVersion.futureVersionsSeen, 0,
            "v1 payloads must not bump the future-version counter")
    }

    /// Future version → decodes optimistically, counter bumps.
    func testFutureSessionsVersionDecodesAndBumpsWarning() throws {
        let json = #"{"pids":[1],"ts":0,"wireVersion":99}"#
        let event = try JSONDecoder().decode(NotchEvent.self,
            from: Data(#"{"type":"sessions:update","data":\#(json)}"#.utf8))
        guard case .sessionsUpdate(let p) = event else {
            return XCTFail("expected sessionsUpdate")
        }
        XCTAssertEqual(p.wireVersion, 99)
        XCTAssertEqual(NotchWireVersion.futureVersionsSeen, 1)
    }

    /// Same for todos:update.
    func testFutureTodosVersionDecodesAndBumpsWarning() throws {
        let json = #"{"count":0,"ts":0,"wireVersion":42}"#
        let event = try JSONDecoder().decode(NotchEvent.self,
            from: Data(#"{"type":"todos:update","data":\#(json)}"#.utf8))
        guard case .todosUpdate(let p) = event else {
            return XCTFail("expected todosUpdate")
        }
        XCTAssertEqual(p.wireVersion, 42)
        XCTAssertEqual(NotchWireVersion.futureVersionsSeen, 1)
    }

    /// Unknown extra fields in a future-version payload must be ignored,
    /// not throw. The whole point of optimistic decode is to survive
    /// additive backend changes.
    func testFuturePayloadWithExtraFieldsStillDecodes() throws {
        let json = #"""
        {"pids":[1],"ts":0,"wireVersion":2,"newFancyField":"hello"}
        """#
        let p = try JSONDecoder().decode(SessionsUpdatePayload.self,
            from: Data(json.utf8))
        XCTAssertEqual(p.wireVersion, 2)
    }

    /// Codable round-trip preserves the version field.
    func testCodableRoundTripPreservesWireVersion() throws {
        let original = SessionsUpdatePayload(pids: [1], ts: 0, sessions: nil, wireVersion: 1)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionsUpdatePayload.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
