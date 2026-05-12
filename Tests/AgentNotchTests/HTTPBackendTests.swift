import XCTest
@testable import AgentNotch

/// `HTTPBackend` tests using a custom `URLProtocol` to stub every
/// network call. No real socket is opened — every assertion is
/// hermetic.
final class HTTPBackendTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.responses.removeAll()
        StubURLProtocol.recordedRequests.removeAll()
        // `recordedBodies` is part of the same global stub state as
        // `recordedRequests`; without clearing it here, leftovers
        // from the previous test (e.g. testLoadAndSavePrefs's
        // `{"density":"comfortable"}`) leak into the next test's
        // assertions. CI happened to run the tests in an order where
        // this never bit, but local runs hit it.
        StubURLProtocol.recordedBodies.removeAll()
    }

    // MARK: - sendMessage

    func testSendMessagePostsJSONBody() async throws {
        StubURLProtocol.responses[NotchEndpoints.send] = .success(Data())
        let backend = HTTPBackend(session: Self.stubSession())

        try await backend.sendMessage("ciao")

        let req = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        // URLProtocol stub does not preserve httpBody on a copied request;
        // recordedBodies captures it instead.
        let body = try XCTUnwrap(StubURLProtocol.recordedBodies.first)
        let decoded = try JSONDecoder().decode([String: String].self, from: body)
        XCTAssertEqual(decoded, ["text": "ciao"])
    }

    func testSendMessageThrowsOn500() async {
        StubURLProtocol.responses[NotchEndpoints.send] = .status(500, body: Data("nope".utf8))
        let backend = HTTPBackend(session: Self.stubSession())

        do {
            try await backend.sendMessage("ciao")
            XCTFail("expected throw on 500")
        } catch NotchBackendError.http(let status, let body) {
            XCTAssertEqual(status, 500)
            XCTAssertEqual(body, "nope")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - listSessions

    func testListSessionsDecodesArray() async throws {
        let json = #"""
        [{"pid":1,"repo":"a","status":"working","conflict":null},
         {"pid":2,"repo":"b","status":"idle","conflict":null}]
        """#
        StubURLProtocol.responses[NotchEndpoints.localSessions] =
            .success(Data(json.utf8))

        let backend = HTTPBackend(session: Self.stubSession())
        let sessions = try await backend.listSessions()

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.first?.pid, 1)
        XCTAssertEqual(sessions.last?.status, "idle")
    }

    func testListSessionsDecodeFailureSurfacedAsDecodeError() async {
        StubURLProtocol.responses[NotchEndpoints.localSessions] =
            .success(Data("not json".utf8))

        let backend = HTTPBackend(session: Self.stubSession())
        do {
            _ = try await backend.listSessions()
            XCTFail("expected decode throw")
        } catch NotchBackendError.decodeFailure {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - abort

    func testAbortPostsEmptyBody() async throws {
        StubURLProtocol.responses[NotchEndpoints.abort] = .success(Data())
        let backend = HTTPBackend(session: Self.stubSession())

        try await backend.abort()

        let req = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url, NotchEndpoints.abort)
    }

    // MARK: - completeTodo

    func testCompleteTodoHitsCorrectURL() async throws {
        let url = NotchEndpoints.todoComplete(id: "AAA-42")
        StubURLProtocol.responses[url] = .success(Data())
        let backend = HTTPBackend(session: Self.stubSession())

        try await backend.completeTodo(id: "AAA-42")

        let req = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
        XCTAssertEqual(req.url, url)
    }

    // MARK: - prefs

    func testLoadAndSavePrefs() async throws {
        let prefsURL = NotchEndpoints.prefs
        StubURLProtocol.responses[prefsURL] =
            .success(Data(#"{"density":"compact"}"#.utf8))

        let backend = HTTPBackend(session: Self.stubSession())
        let prefs = try await backend.loadPrefs()
        let decoded = try JSONDecoder().decode([String: String].self, from: prefs)
        XCTAssertEqual(decoded["density"], "compact")

        // Same URL is used for POST; switch response and call savePrefs.
        StubURLProtocol.recordedRequests.removeAll()
        StubURLProtocol.recordedBodies.removeAll()
        StubURLProtocol.responses[prefsURL] = .success(Data())

        let patch = Data(#"{"density":"comfortable"}"#.utf8)
        try await backend.savePrefs(patch)

        let req = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
        XCTAssertEqual(req.httpMethod, "POST")
        let body = try XCTUnwrap(StubURLProtocol.recordedBodies.first)
        XCTAssertEqual(body, patch)
    }

    // MARK: - Test infra

    private static func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - StubURLProtocol

/// Per-URL canned responses for `HTTPBackendTests`. Concurrency-safe
/// across the test bundle as long as tests don't run truly in parallel
/// against the same URL — XCTest defaults to serial within a class.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Stub {
        case success(Data)
        case status(Int, body: Data)
        case error(Error)
    }

    nonisolated(unsafe) static var responses: [URL: Stub] = [:]
    nonisolated(unsafe) static var recordedRequests: [URLRequest] = []
    nonisolated(unsafe) static var recordedBodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubURLProtocol.recordedRequests.append(request)
        // URLProtocol does not give us httpBody on the request copy when
        // the caller used URLSession.upload-like paths; capture it from
        // the bodyStream when present, otherwise from httpBody.
        if let body = request.httpBody {
            StubURLProtocol.recordedBodies.append(body)
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = Data()
            let bufSize = 4096
            var temp = [UInt8](repeating: 0, count: bufSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&temp, maxLength: bufSize)
                if read <= 0 { break }
                buffer.append(temp, count: read)
            }
            StubURLProtocol.recordedBodies.append(buffer)
        }

        guard let url = request.url,
              let stub = StubURLProtocol.responses[url] else {
            // No stub configured — fail with notConnectedToInternet so the
            // test sees a clean URLError instead of hanging on a real
            // socket lookup.
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        switch stub {
        case .success(let data):
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .status(let code, let body):
            let resp = HTTPURLResponse(url: url, statusCode: code, httpVersion: "1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .error(let err):
            client?.urlProtocol(self, didFailWithError: err)
        }
    }

    override func stopLoading() { /* no-op */ }
}
