import Foundation

struct RelayConfiguration: Equatable, Sendable {
    let origin: URL
    let token: String

    init?(origin: String, token: String?) {
        guard let url = URL(string: origin), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              let token, (token.hasPrefix("v1.") || token.hasPrefix("v2.")), !token.contains(where: \.isWhitespace)
        else { return nil }
        self.origin = url
        self.token = token
    }

    func request(path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: origin.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}

struct RelayEventParser {
    enum Event: Equatable, Sendable { case connected, wake, expired }
    private var event = ""
    private var connected = false

    mutating func consume(_ line: String) -> Event? {
        if line == ": connected", !connected {
            connected = true
            return .connected
        }
        if line.isEmpty {
            defer { event = "" }
            if event == "expired" { return .expired }
            return connected && event == "wake" ? .wake : nil
        }
        if line.hasPrefix("event:") {
            event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

/// Credentials never follow redirects, including redirects to another origin.
final class RelaySessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class RelayStream {
    private var task: Task<Void, Never>?
    private var session: URLSession?
    private var generation: UUID?

    func start(configuration: RelayConfiguration, inbox: Bool = false, receive: @escaping @MainActor @Sendable (RelayEventParser.Event?) -> Void) {
        stop()
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 65
        settings.timeoutIntervalForResource = 60 * 60 * 24 * 31
        let session = URLSession(configuration: settings, delegate: RelaySessionDelegate(), delegateQueue: nil)
        self.session = session
        let generation = UUID()
        self.generation = generation
        let deliver: @MainActor @Sendable (RelayEventParser.Event?) -> Void = { [weak self] event in
            guard self?.generation == generation else { return }
            receive(event)
        }
        task = Task.detached {
            var retry: Double = 2
            while !Task.isCancelled {
                do {
                    var request = configuration.request(path: "stream")
                    if inbox { request.setValue("1", forHTTPHeaderField: "X-Relay-Inbox") }
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await session.bytes(for: request)
                    defer { bytes.task.cancel() }
                    try Task.checkCancellation()
                    if (response as? HTTPURLResponse)?.statusCode == 401 {
                        await deliver(.expired)
                        return
                    }
                    guard let http = response as? HTTPURLResponse,
                          Self.accepts(http) else { throw URLError(.badServerResponse) }
                    var parser = RelayEventParser()
                    var line = [UInt8]()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if byte == 10 {
                            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .newlines)
                            line.removeAll(keepingCapacity: true)
                            if let event = parser.consume(text) {
                                if event == .connected { retry = 2 }
                                await deliver(event)
                                if event == .expired { return }
                            }
                        } else {
                            guard line.count < 65_536 else { throw URLError(.dataLengthExceedsMaximum) }
                            line.append(byte)
                        }
                    }
                } catch { /* Disconnection uses polling and bounded reconnect backoff. */ }
                guard !Task.isCancelled else { return }
                await deliver(nil)
                do { try await Task.sleep(for: .seconds(Double.random(in: (retry * 0.5)...retry))) } catch { return }
                retry = min(60, retry * 2)
            }
        }
    }

    nonisolated static func accepts(_ response: HTTPURLResponse) -> Bool {
        response.statusCode == 200 && response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "text/event-stream"
    }

    func stop() {
        generation = nil
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }
}

struct RelayHook: Decodable, Sendable {
    let url: URL
    let secret: String
}

struct RelayHookClient {
    let configuration: RelayConfiguration

    func create() async throws -> RelayHook {
        let (data, response) = try await send(configuration.request(path: "hooks", method: "POST"))
        guard response.statusCode == 201 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(RelayHook.self, from: data)
    }

    func revoke(url: URL) async throws {
        guard url.scheme == configuration.origin.scheme, url.host == configuration.origin.host,
              url.port == configuration.origin.port, url.path.hasPrefix("/hooks/"),
              url.pathComponents.count == 3, url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil else { throw URLError(.badURL) }
        let (_, response) = try await send(configuration.request(path: String(url.path.dropFirst()), method: "DELETE"))
        guard response.statusCode == 204 || response.statusCode == 404 else { throw URLError(.badServerResponse) }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let session = URLSession(configuration: .ephemeral, delegate: RelaySessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// One bit of demand is enough: every GitHub read returns the current inbox.
struct RelayRefreshDemand {
    private(set) var isPending = false

    mutating func request() { isPending = true }

    mutating func take(isLoading: Bool, now: Date, notBefore: Date?) -> Bool {
        guard isPending, !isLoading, notBefore.map({ now >= $0 }) ?? true else { return false }
        isPending = false
        return true
    }
}
