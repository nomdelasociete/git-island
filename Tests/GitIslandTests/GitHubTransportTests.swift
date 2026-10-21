import Foundation
import XCTest
@testable import GitIsland

private final class AuthFailureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("private-token-and-repository".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class GitHubTransportTests: XCTestCase {
    func testAPIRequestRejectsCredentialDestinationsBeforeSending() async {
        let service = GitHubPullRequestService()
        for value in ["https://attacker.example/repos/a/b", "http://api.github.com/user",
                      "https://api.github.com.attacker.example/user", "https://user:pass@api.github.com/user",
                      "https://api.github.com:8443/user", "https://api.github.com/user#fragment"] {
            do {
                let _: [String] = try await service.getWithETag(URL(string: value)!, token: "test-token")
                XCTFail("Untrusted destination accepted")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .badURL)
            }
        }
    }

    func testFormEncodingRoundTripsReservedCharacters() {
        let value = "a+b&c=d?e/#% é"
        let body = String(decoding: GitHubTransport.formBody(["key&name": value]), as: UTF8.self)
        XCTAssertFalse(body.contains("+"))
        let fields = body.split(separator: "=")
        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(String(fields[0]).removingPercentEncoding, "key&name")
        XCTAssertEqual(String(fields[1]).removingPercentEncoding, value)
    }

    func testSensitiveSessionRejectsRedirectAndDoesNotCache() {
        let session = GitHubTransport.session()
        defer { session.invalidateAndCancel() }
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertEqual(session.configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        let delegate = session.delegate as? RelaySessionDelegate
        XCTAssertNotNil(delegate)
        let request = URLRequest(url: URL(string: "https://attacker.example")!)
        let response = HTTPURLResponse(url: URL(string: "https://api.github.com/user")!, statusCode: 302,
                                       httpVersion: nil, headerFields: ["Location": request.url!.absoluteString])!
        let task = session.dataTask(with: URL(string: "https://api.github.com/user")!)
        delegate?.urlSession(session, task: task, willPerformHTTPRedirection: response,
                             newRequest: request, completionHandler: { XCTAssertNil($0) })
        task.cancel()
    }

    func testAuthErrorDoesNotExposeResponseBody() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthFailureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await GitHubAuthService(session: session).startDeviceFlow()
            XCTFail("Expected failure")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("private-token"))
            XCTAssertTrue(error.localizedDescription.contains("500"))
        }
    }

    func testDiagnosticExportOmitsFreeFormServerText() {
        var diagnostics = RefreshDiagnostics()
        diagnostics.lastMessage = "private-token-and-repository"
        diagnostics.refreshBreakdown = "private-title"
        XCTAssertFalse(diagnostics.debugText.contains("private-"))
        XCTAssertTrue(diagnostics.debugText.contains("Omitted for privacy"))
    }
}
