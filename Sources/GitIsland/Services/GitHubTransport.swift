import Foundation

/// Credential-bearing GitHub traffic never follows redirects or uses disk cache.
enum GitHubTransport {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration, delegate: RelaySessionDelegate(), delegateQueue: nil)
    }

    static func permits(_ url: URL, host: String) -> Bool {
        url.scheme == "https" && url.host == host &&
        (url.port == nil || url.port == 443) && url.user == nil &&
        url.password == nil && url.fragment == nil
    }

    static func formBody(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let encoded = values.keys.sorted().map { key in
            let name = key.addingPercentEncoding(withAllowedCharacters: allowed)!
            let value = values[key]!.addingPercentEncoding(withAllowedCharacters: allowed)!
            return "\(name)=\(value)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }
}
