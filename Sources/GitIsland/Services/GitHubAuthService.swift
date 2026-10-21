import Foundation

actor GitHubAuthService {
    private let network: URLSession
    init(session: URLSession = GitHubTransport.session()) { network = session }


    func startDeviceFlow() async throws -> GitHubDeviceFlowSession {
        guard GitHubOAuthConfiguration.isConfigured else {
            throw GitHubAuthError.missingClientID
        }

        var request = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = GitHubTransport.formBody([
            "client_id": GitHubOAuthConfiguration.clientID,
            "scope": GitHubOAuthConfiguration.scopes
        ])

        let (data, response) = try await network.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubAuthError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw GitHubAuthError.api(message: "GitHub could not complete the request (HTTP \(httpResponse.statusCode)).")
        }

        let payload = try JSONDecoder().decode(GitHubDeviceCodeResponse.self, from: data)
        guard GitHubTransport.permits(payload.verificationURI, host: "github.com"),
              payload.verificationURI.path == "/login/device", payload.verificationURI.query == nil,
              !payload.deviceCode.isEmpty, !payload.userCode.isEmpty,
              (1...3600).contains(payload.expiresIn), (1...60).contains(payload.interval) else {
            throw GitHubAuthError.invalidResponse
        }
        return GitHubDeviceFlowSession(
            deviceCode: payload.deviceCode,
            userCode: payload.userCode,
            verificationURI: payload.verificationURI,
            expiresAt: Date().addingTimeInterval(TimeInterval(payload.expiresIn)),
            pollInterval: TimeInterval(payload.interval)
        )
    }

    func pollForToken(session: GitHubDeviceFlowSession) async throws -> String {
        var session = session

        while Date() < session.expiresAt {
            try await Task.sleep(nanoseconds: UInt64(session.pollInterval * 1_000_000_000))

            var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = GitHubTransport.formBody([
                "client_id": GitHubOAuthConfiguration.clientID,
                "device_code": session.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ])

            let (data, response) = try await network.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw GitHubAuthError.invalidResponse
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                throw GitHubAuthError.api(message: "GitHub could not complete the request (HTTP \(httpResponse.statusCode)).")
            }

            let payload = try JSONDecoder().decode(GitHubDeviceTokenPollResponse.self, from: data)

            if let error = payload.error {
                switch error {
                case "authorization_pending":
                    continue
                case "slow_down":
                    session.pollInterval += 5
                    continue
                case "expired_token":
                    throw GitHubAuthError.expired
                case "access_denied":
                    throw GitHubAuthError.denied
                default:
                    throw GitHubAuthError.api(message: "GitHub could not complete sign-in. Start again.")
                }
            }

            guard let accessToken = payload.accessToken, !accessToken.isEmpty else {
                throw GitHubAuthError.invalidResponse
            }

            try Task.checkCancellation()
            return accessToken
        }

        throw GitHubAuthError.expired
    }

    func currentLogin(token: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Git-Island", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await network.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
            throw GitHubServiceError.api(statusCode: 401, message: "GitHub authorization expired. Please sign in again.", retryAfterDate: nil)
        }
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw GitHubAuthError.invalidResponse
        }

        let user = try JSONDecoder().decode(GitHubAuthUser.self, from: data)
        return user.login
    }


}

struct GitHubDeviceFlowSession {
    let deviceCode: String
    let userCode: String
    let verificationURI: URL
    let expiresAt: Date
    var pollInterval: TimeInterval
}

enum GitHubAuthError: LocalizedError {
    case missingClientID
    case invalidResponse
    case expired
    case denied
    case api(message: String)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            "GitHub sign-in is not configured in this build."
        case .invalidResponse:
            "GitHub returned an invalid response."
        case .expired:
            "The sign-in code expired. Start again."
        case .denied:
            "GitHub sign-in was cancelled."
        case .api(let message):
            "GitHub sign-in failed: \(message)"
        }
    }
}

private struct GitHubDeviceCodeResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: URL
    let expiresIn: Int
    let interval: Int

    private enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct GitHubDeviceTokenPollResponse: Decodable {
    let accessToken: String?
    let error: String?
    let errorDescription: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case error
        case errorDescription = "error_description"
    }
}

private struct GitHubAuthUser: Decodable {
    let login: String
}

