import Foundation
import XCTest
@testable import GitIsland

private final class AccountProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let isAlice = request.value(forHTTPHeaderField: "Authorization") == "Bearer alice"
        // Model a resource whose ETag is shared between users. Bob must never
        // be allowed to reuse Alice's cached representation.
        let conditional = request.value(forHTTPHeaderField: "If-None-Match") != nil
        let status = conditional ? 304 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["ETag": "same-etag"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !conditional {
            client?.urlProtocol(self, didLoad: Data((isAlice ? "[\"private-alice\"]" : "[\"public-bob\"]").utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class AccountCacheIsolationTests: XCTestCase {
    func testConditionalResponsesCannotReuseAnotherAccountsData() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AccountProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let service = GitHubPullRequestService(session: session)
        let url = URL(string: "https://api.github.com/repos/example/project")!
        let alice: [String] = try await service.getWithETag(url, token: "alice")
        let bob: [String] = try await service.getWithETag(url, token: "bob")
        let aliceAgain: [String] = try await service.getWithETag(url, token: "alice")
        XCTAssertEqual(alice, ["private-alice"])
        XCTAssertEqual(bob, ["public-bob"])
        XCTAssertEqual(aliceAgain, ["private-alice"])
    }
}
