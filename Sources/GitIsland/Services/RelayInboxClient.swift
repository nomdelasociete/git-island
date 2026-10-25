import Foundation

struct RelayInboxSnapshot: Decodable {
    let schema: Int
    let subject: String
    let login: String
    let updatedAt: TimeInterval
    let revision: String
    let data: GitHubInboxGraphQLData
}

enum RelayInboxError: LocalizedError {
    case authorizationRequired
    case deviceNotReady
    case deviceExpired
    case unavailable(Date)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .authorizationRequired: "Authorize inbox sync in Settings → Refresh to let Relay read your pull requests."
        case .deviceNotReady: "Waiting for this Mac’s Relay identity verification."
        case .deviceExpired: "Relay device authorization is renewing. Your inbox will retry automatically."
        case .unavailable: "Relay inbox sync is temporarily paused. Your last inbox remains visible."
        case .invalidResponse: "Relay returned an incomplete or mismatched inbox."
        }
    }
}

struct RelayInboxClient {
    let configuration: RelayConfiguration
    var send: RelayDeviceAPI.Send = { request in
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 30
        settings.timeoutIntervalForResource = 30
        let session = URLSession(configuration: settings, delegate: RelaySessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayInboxError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 8 * 1024 * 1024 else { throw RelayInboxError.invalidResponse }
            data.append(byte)
        }
        let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        return RelayHTTPReply(status: http.statusCode, data: data,
            retryAfter: retry.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
    }

    private func request(path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: URL(string: UserPreferences.relayAuthorityOrigin)!.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    func fetch(login: String, subject: String, refresh: Bool = false) async throws -> RelayInboxSnapshot {
        let response = try await send(request(path: "inbox", method: refresh ? "POST" : "GET"))
        try Task.checkCancellation()
        switch response.status {
        case 401: throw RelayInboxError.deviceExpired
        case 428: throw RelayInboxError.authorizationRequired
        case 200: break
        default: throw RelayInboxError.unavailable(Date().addingTimeInterval(max(5, response.retryAfter ?? 60)))
        }
        guard response.data.count <= 8 * 1024 * 1024 else { throw RelayInboxError.invalidResponse }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(RelayInboxSnapshot.self, from: response.data)
        guard snapshot.schema == 1, !snapshot.login.isEmpty,
              snapshot.subject == subject, !snapshot.revision.isEmpty,
              snapshot.updatedAt <= Date().timeIntervalSince1970 + 60,
              snapshot.updatedAt >= Date().timeIntervalSince1970 - 300,
              snapshot.data.isComplete else { throw RelayInboxError.invalidResponse }
        return snapshot
    }

    func authorizationURL() async throws -> URL {
        let response = try await send(request(path: "inbox/authorization", method: "POST"))
        guard response.status == 200 else { throw RelayInboxError.unavailable(Date().addingTimeInterval(60)) }
        struct Reply: Decodable { let verification_uri: URL }
        let url = try JSONDecoder().decode(Reply.self, from: response.data).verification_uri
        let trusted = URL(string: UserPreferences.relayBrowserOrigin)!
        guard url.scheme == trusted.scheme, url.host == trusted.host, url.port == trusted.port,
              url.path == "/inbox/authorize", url.user == nil, url.password == nil, url.fragment == nil
        else { throw RelayInboxError.invalidResponse }
        return url
    }

    func revoke() async throws {
        let response = try await send(request(path: "inbox", method: "DELETE"))
        guard response.status == 204 else { throw RelayInboxError.unavailable(Date().addingTimeInterval(60)) }
    }
}
