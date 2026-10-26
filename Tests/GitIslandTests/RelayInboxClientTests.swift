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
    func testNativeWriteBackoffDoesNotBlockRelayReads() {
        let deadline = Date().addingTimeInterval(900)
        var backoff = InboxRefreshBackoff(githubUntil: deadline)
        XCTAssertNil(backoff.readDeadline(serverInbox: true))
        XCTAssertEqual(backoff.readDeadline(serverInbox: false), deadline)
        let relayDeadline = Date().addingTimeInterval(60)
        backoff.relayUntil = relayDeadline
        XCTAssertEqual(backoff.readDeadline(serverInbox: true), relayDeadline)
        XCTAssertEqual(backoff.githubUntil, deadline)
        backoff.relayUntil = nil
        XCTAssertNil(backoff.readDeadline(serverInbox: true))
        XCTAssertEqual(backoff.readDeadline(serverInbox: false), deadline)
    }

    func testMissingSearchCannotEraseInbox() async throws {
        for data in ["{}", "{\"s1\":{\"issueCount\":0,\"nodes\":[]}}", "{\"s0\":null}"] {
            let client = RelayInboxClient(configuration: configuration, send: { _ in
                let json = """
                {"schema":1,"subject":"10","login":"example-user","updatedAt":\(Date().timeIntervalSince1970),"revision":"one","data":\(data)}
                """
                return RelayHTTPReply(status: 200, data: Data(json.utf8))
            })
            do {
                _ = try await client.fetch(login: "example-user", subject: "10")
                XCTFail("Missing s0 must be rejected")
            } catch is DecodingError { }
        }
    }

    func testAuthorizationWaitsForValidatedSnapshot() async throws {
        let replies = InboxAuthorizationReplies()
        let client = RelayInboxClient(configuration: configuration, send: { _ in await replies.next() })
        try await client.waitForAuthorization(login: "example-user", subject: "10", pause: {})
        let requests = await replies.count
        XCTAssertEqual(requests, 2)
    }

    func testUnfinishedAuthorizationTimesOutWithoutSuccess() async throws {
        let client = RelayInboxClient(configuration: configuration, send: { _ in
            RelayHTTPReply(status: 428, data: Data())
        })
        do {
            try await client.waitForAuthorization(login: "example-user", subject: "10", attempts: 2, pause: {})
            XCTFail("Opening a browser is not authorization")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
    }

    func testCanceledAuthorizationDoesNotEnableSync() async throws {
        let client = RelayInboxClient(configuration: configuration, send: { _ in
            RelayHTTPReply(status: 428, data: Data())
        })
        do {
            try await client.waitForAuthorization(login: "example-user", subject: "10", pause: { throw CancellationError() })
            XCTFail("Cancellation must propagate")
        } catch is CancellationError { }
    }

}


private actor InboxAuthorizationReplies {
    var count = 0
    func next() -> RelayHTTPReply {
        count += 1
        guard count > 1 else { return RelayHTTPReply(status: 428, data: Data()) }
        let json = """
        {"schema":1,"subject":"10","login":"example-user","updatedAt":\(Date().timeIntervalSince1970),"revision":"one","data":{"s0":{"issueCount":0,"nodes":[]}}}
        """
        return RelayHTTPReply(status: 200, data: Data(json.utf8))
    }
}
