import XCTest
@testable import AgentNotch

/// Extra decode-path coverage for `NotchEvent` Codable conformance.
///
/// The original `NotchEventDecoderTests` covers the happy paths and one
/// unknown-type case. These tests pin the failure modes a malicious or
/// buggy backend can produce so we don't crash the runtime on bad SSE
/// frames in production.
final class NotchEventDecoderEdgeTests: XCTestCase {
    /// Missing `type` key — must throw, not crash.
    func testMissingTypeThrows() {
        let json = #"{"data":{}}"#
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(NotchEvent.self, from: data))
    }

    /// `type` present but `data` missing for a known type — must throw,
    /// not crash. Production callers wrap with `try?` and skip.
    func testKnownTypeMissingDataThrows() {
        let json = #"{"type":"sessions:update"}"#
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(NotchEvent.self, from: data))
    }

    /// `sessions:update` with malformed inner payload (wrong field type)
    /// — must throw, not crash.
    func testSessionsUpdateMalformedPayloadThrows() {
        let json = #"""
        {"type":"sessions:update","data":{"pids":"not-an-array","ts":0}}
        """#
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(NotchEvent.self, from: data))
    }

    /// Empty JSON object — must throw, not crash.
    func testEmptyObjectThrows() {
        let json = "{}"
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(NotchEvent.self, from: data))
    }

    /// Random bytes — must throw, not crash.
    func testGarbagePayloadThrows() {
        let data = Data([0xFF, 0xFE, 0x00, 0x42, 0xAA])
        XCTAssertThrowsError(try JSONDecoder().decode(NotchEvent.self, from: data))
    }

    /// `sessions:update` with optional `sessions` field absent — must
    /// succeed (the field is `Optional<[SessionStatusEntry]>`).
    func testSessionsUpdateWithoutSessionsArraySucceeds() throws {
        let json = #"{"type":"sessions:update","data":{"pids":[1],"ts":0}}"#
        let data = json.data(using: .utf8)!
        let event = try JSONDecoder().decode(NotchEvent.self, from: data)
        guard case .sessionsUpdate(let payload) = event else {
            return XCTFail("expected .sessionsUpdate case")
        }
        XCTAssertEqual(payload.pids, [1])
        XCTAssertNil(payload.sessions)
    }

    /// `todos:update` with optional `topThree` absent — must succeed.
    func testTodosUpdateWithoutTopThreeSucceeds() throws {
        let json = #"{"type":"todos:update","data":{"count":0,"ts":0}}"#
        let data = json.data(using: .utf8)!
        let event = try JSONDecoder().decode(NotchEvent.self, from: data)
        guard case .todosUpdate(let payload) = event else {
            return XCTFail("expected .todosUpdate case")
        }
        XCTAssertEqual(payload.count, 0)
        XCTAssertNil(payload.topThree)
    }

    /// `SessionStatusEntry` with explicit null `conflict` decodes the
    /// field as nil.
    func testSessionsEntryNullConflictDecodesAsNil() throws {
        let json = #"""
        {"type":"sessions:update","data":{"pids":[5],"ts":0,
         "sessions":[{"pid":5,"repo":"x","status":"idle","conflict":null}]}}
        """#
        let data = json.data(using: .utf8)!
        let event = try JSONDecoder().decode(NotchEvent.self, from: data)
        guard case .sessionsUpdate(let payload) = event else {
            return XCTFail("expected .sessionsUpdate case")
        }
        XCTAssertEqual(payload.sessions?.first?.conflict, nil)
    }
}
