import Foundation
import XCTest
@testable import GitIsland

final class RelayInboxClientTests: XCTestCase {
    private var configuration: RelayConfiguration { RelayConfiguration(origin: UserPreferences.officialRelayOrigin, token: "v2.synthetic")! }

    func testInboxUsesOnlyRelayAccessAtTrustedAuthority() async throws {
        let client = RelayInboxClient(configuration: configuration, send: { request in
            XCTAssertEqual(request.url?.host, "access.relay.nomdelasociete.com")
            XCTAssertEqual(request.url?.path, "/inbox")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer v2.synthetic")
            let json = """
            {"schema":1,"subject":"10","login":"example-user","updatedAt":\(Date().timeIntervalSince1970),"revision":"one","data":{"s0":{"issueCount":0,"nodes":[]}}}
            """
            return RelayHTTPReply(status: 200, data: Data(json.utf8))
        })
        let snapshot = try await client.fetch(login: "example-user", subject: "10")
        XCTAssertTrue(snapshot.data.pullRequests.isEmpty)
        do {
            _ = try await client.fetch(login: "example-user", subject: "11")
            XCTFail("Another identity must not be accepted")
        } catch RelayInboxError.invalidResponse { }
    }

    func testProviderBackoffDoesNotCallGitHub() async throws {
        let client = RelayInboxClient(configuration: configuration, send: { request in
            XCTAssertEqual(request.url?.host, "access.relay.nomdelasociete.com")
            return RelayHTTPReply(status: 503, data: Data(), retryAfter: 3600)
        })
        do { _ = try await client.fetch(login: "example-user", subject: "10"); XCTFail("Should pause") }
        catch RelayInboxError.unavailable(let date) { XCTAssertGreaterThan(date.timeIntervalSinceNow, 3500) }
    }

    func testAuthorizationRejectsUntrustedBrowserDestination() async throws {
        let client = RelayInboxClient(configuration: configuration, send: { _ in
            RelayHTTPReply(status: 200, data: Data("{\"verification_uri\":\"https://untrusted.invalid/inbox/authorize\"}".utf8))
        })
        do { _ = try await client.authorizationURL(); XCTFail("Should reject") }
        catch RelayInboxError.invalidResponse { }
    }

    func testExplicitRefreshStillUsesRelay() async throws {
        let client = RelayInboxClient(configuration: configuration, send: { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.host, "access.relay.nomdelasociete.com")
            return RelayHTTPReply(status: 428, data: Data())
        })
        do { _ = try await client.fetch(login: "example-user", subject: "10", refresh: true); XCTFail("Should request consent") }
        catch RelayInboxError.authorizationRequired { }
    }
}
