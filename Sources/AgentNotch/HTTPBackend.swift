import Foundation

/// `URLSession`-backed implementation of `NotchBackend`.
///
/// Wraps every imperative call the notch needs to make against the
/// router HTTP API. URL routes are resolved through `NotchEndpoints`,
/// which itself reads the configured backend host from `AppConfig`
/// when present (and falls back to the legacy
/// `AGENT_NOTCH_BACKEND_URL` env var).
///
/// The session is injectable so tests can supply a session backed by a
/// `URLProtocol` stub. Default is `URLSession.shared`.
public final class HTTPBackend: NotchBackend, @unchecked Sendable {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    // MARK: - Routes (computed each call so config refresh is honoured)

    /// Resolves the URL at call time, not at init, so a backend created
    /// before `AppConfigStore.update { ... }` still routes to the new
    /// host on the next call.
    private func url(_ keyPath: () -> URL) -> URL { keyPath() }

    // MARK: - NotchBackend

    public func sendMessage(_ text: String) async throws {
        let body = try encoder.encode(["text": text])
        _ = try await post(NotchEndpoints.send, body: body, contentType: "application/json")
    }

    public func abort() async throws {
        _ = try await post(NotchEndpoints.abort, body: Data(), contentType: "application/json")
    }

    public func uploadVoice(_ data: Data) async throws -> VoiceUploadResult {
        // Multipart upload, matching `/api/notch/voice` (POST multipart).
        let boundary = "agent-notch-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".utf8data)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"voice.wav\"\r\n".utf8data)
        body.append("Content-Type: audio/wav\r\n\r\n".utf8data)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".utf8data)
        let voiceURL = URL(string: "\(NotchEndpoints.host)/api/notch/voice")!
        let respData = try await post(
            voiceURL,
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
        do {
            return try decoder.decode(VoiceUploadResult.self, from: respData)
        } catch {
            throw NotchBackendError.decodeFailure(reason: "\(error)")
        }
    }

    public func listSessions() async throws -> [SessionStatusEntry] {
        let data = try await get(NotchEndpoints.localSessions)
        do {
            return try decoder.decode([SessionStatusEntry].self, from: data)
        } catch {
            throw NotchBackendError.decodeFailure(reason: "\(error)")
        }
    }

    public func completeTodo(id: String) async throws {
        _ = try await post(NotchEndpoints.todoComplete(id: id), body: Data(), contentType: "application/json")
    }

    public func loadPrefs() async throws -> Data {
        return try await get(NotchEndpoints.prefs)
    }

    public func savePrefs(_ patch: Data) async throws {
        _ = try await post(NotchEndpoints.prefs, body: patch, contentType: "application/json")
    }

    // MARK: - Helpers

    private func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        return try await perform(req)
    }

    private func post(_ url: URL, body: Data, contentType: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return try await perform(req)
    }

    private func perform(_ req: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw NotchBackendError.unreachable(reason: "non-HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                let bodyText = String(data: data, encoding: .utf8)
                throw NotchBackendError.http(status: http.statusCode, body: bodyText)
            }
            return data
        } catch let e as NotchBackendError {
            throw e
        } catch let e as URLError where e.code == .cancelled {
            throw NotchBackendError.cancelled
        } catch let e as URLError {
            throw NotchBackendError.unreachable(reason: e.localizedDescription)
        }
    }
}

// MARK: - String → Data convenience

private extension String {
    var utf8data: Data { Data(self.utf8) }
}
