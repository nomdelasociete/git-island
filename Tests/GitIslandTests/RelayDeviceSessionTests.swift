import Foundation
import XCTest
@testable import GitIsland

private actor RelayReplies {
    var replies: [RelayHTTPReply]
    var requests: [URLRequest] = []
    var githubRequests: [URLRequest] = []
    var subject = "100"
    var nativeID: Int64 = 100
    var identityStatus = 200
    var delayIdentity = false
    var identityStarted = false
    func delayIdentityResponse() { delayIdentity = true }
    func setIdentity(subject: String = "100", nativeID: Int64 = 100, status: Int = 200) {
        self.subject = subject; self.nativeID = nativeID; self.identityStatus = status
    }
    init(_ replies: [RelayHTTPReply]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> RelayHTTPReply {
        if request.url?.host == "api.github.com" { githubRequests.append(request); return RelayHTTPReply(status: 200, data: Data("{\"id\":\(nativeID)}".utf8)) }
        if request.url?.path == "/computers/identity" {
            identityStarted = true
            if delayIdentity { try? await Task.sleep(for: .milliseconds(100)) }
            return RelayHTTPReply(status: identityStatus, data: Data("{\"subject\":\"\(subject)\"}".utf8)) }
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.networkConnectionLost) }
        return replies.removeFirst()
    }
}

@MainActor
private final class RelayVault {
    var value: String?
    var writes = 0
    var failWrite: Int?
    init(_ value: String? = nil) { self.value = value }
    func save(_ value: String) throws {
        writes += 1
        if writes == failWrite { throw URLError(.cannotWriteToFile) }
        self.value = value
    }
}

@MainActor
final class RelayDeviceSessionTests: XCTestCase {
    private let origin = "https://relay.example"
    private func response(_ status: Int, _ json: String = "") -> RelayHTTPReply {
        RelayHTTPReply(status: status, data: Data(json.utf8))
    }
    private let grant = #"{"device_code":"one-use-code","verification_uri":"https://auth.example/enroll?code=public-code","expires_in":600}"#
    private let tokens = #"{"access_token":"v2.new","refresh_token":"refresh-new","expires_in":900,"computer_id":"computer-A","installations":["123"]}"#
    private let rotated = #"{"access_token":"v2.rotated","refresh_token":"refresh-rotated","expires_in":900,"computer_id":"computer-A"}"#

    private func existing(expires: Date = Date().addingTimeInterval(900), pending: Bool = false) throws -> String {
        let pair = try JSONDecoder().decode(RelayTokenPair.self, from: Data(tokens.utf8))
        let credentials = RelayDeviceCredentials(origin: origin, pair: pair, expiresAt: expires, requiresEnrollment: pending, authorityOrigin: "https://access.example")
        return String(decoding: try JSONEncoder().encode(credentials), as: UTF8.self)
    }
    private func session(_ vault: RelayVault, _ server: RelayReplies,
                         removeLegacy: @escaping () throws -> Void = { },
                         browser: @escaping (URL) -> Bool = { _ in true }) -> RelayDeviceSession {
        let client = RelayDeviceSession(read: { vault.value }, save: { try vault.save($0) }, legacy: { "v1.legacy" },
            send: { try await server.send($0) }, openBrowser: browser, authorityOrigin: { "https://access.example" }, browserOrigin: { "https://auth.example" }, permittedOrigin: { "https://relay.example" }, removeLegacy: removeLegacy, sleep: { _ in await Task.yield() })
        client.githubToken = { "native-test-token" }
        return client
    }
    private func assertVerified(_ client: RelayDeviceSession, token: String, origin: String) async {
        client.activate(origin: origin)
        for _ in 0..<500 {
            if client.configuration(origin: origin)?.token == token { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(client.configuration(origin: origin)?.token, token)
        client.suspend()
    }
    private func finish(_ session: RelayDeviceSession) async throws {
        for _ in 0..<1000 {
            if !session.isBusy { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Relay operation did not finish")
    }

    func testEnrollmentSurvivesReloadInDeviceKeychain() async throws {
        let account = "relay-integration-test-" + UUID().uuidString
        defer { try? KeychainTokenStore.delete(account: account) }
        let server = RelayReplies([response(201, grant), response(200, tokens)])
        func makeSession() -> RelayDeviceSession {
            let client = RelayDeviceSession(
                read: { try KeychainTokenStore.storedToken(account: account) },
                save: { try KeychainTokenStore.save($0, account: account) },
                legacy: { "v1.legacy" }, send: { try await server.send($0) },
                openBrowser: { _ in true }, authorityOrigin: { "https://access.example" },
                browserOrigin: { "https://auth.example" }, permittedOrigin: { "https://relay.example" }, removeLegacy: { }, sleep: { _ in await Task.yield() })
            client.githubToken = { "native-test-token" }
            return client
        }
        let client = makeSession()
        client.enroll(origin: origin)
        try await finish(client)
        XCTAssertTrue(client.canRevoke)
        let restored = makeSession()
        XCTAssertTrue(restored.canRevoke)
        await assertVerified(restored, token: "v2.new", origin: origin)
        XCTAssertNil(restored.configuration(origin: "https://another-relay.example"))
    }

    func testFailedEnrollmentRestartsInterruptedRestoredVerification() async throws {
        let server = RelayReplies([response(503)])
        await server.delayIdentityResponse()
        let client = session(RelayVault(try existing()), server)
        client.activate(origin: origin)
        defer { client.suspend() }
        while !(await server.identityStarted) { await Task.yield() }
        client.enroll(origin: origin)
        try await finish(client)
        for _ in 0..<500 {
            if client.configuration(origin: origin)?.token == "v2.new" { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(client.configuration(origin: origin)?.token, "v2.new")
    }

    func testIdentityRequestSetsGitHubUserAgent() async throws {
        let server = RelayReplies([])
        let client = session(RelayVault(try existing()), server)
        await assertVerified(client, token: "v2.new", origin: origin)
        let requests = await server.githubRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "User-Agent"), "Git-Island")
    }

    func testRenewalVerifiesNewTokenWithoutActivationCallback() async throws {
        let server = RelayReplies([response(200, rotated)])
        let client = session(RelayVault(try existing()), server)
        client.activate(origin: origin)
        defer { client.suspend() }
        for _ in 0..<500 {
            if client.configuration(origin: origin) != nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(client.configuration(origin: origin)?.token, "v2.new")
        client.renew()
        try await finish(client)
        for _ in 0..<500 {
            if client.configuration(origin: origin)?.token == "v2.rotated" { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(client.configuration(origin: origin)?.token, "v2.rotated")
    }

    func testFailedEnrollmentSavePreservesVerifiedConnection() async throws {
        let vault = RelayVault(try existing())
        let replacement = tokens.replacingOccurrences(of: "v2.new", with: "v2.replacement")
        let server = RelayReplies([response(201, grant), response(200, replacement)])
        let client = session(vault, server)
        client.activate(origin: origin)
        defer { client.suspend() }
        for _ in 0..<500 {
            if client.configuration(origin: origin) != nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(client.configuration(origin: origin)?.token, "v2.new")
        vault.failWrite = 1
        client.enroll(origin: origin)
        try await finish(client)
        XCTAssertEqual(client.credentials?.pair.access_token, "v2.new")
        XCTAssertEqual(client.configuration(origin: origin)?.token, "v2.new")
    }

    func testRotationReplacesInFlightIdentityCheck() async throws {
        let server = RelayReplies([response(200, rotated)])
        await server.delayIdentityResponse()
        let client = session(RelayVault(try existing()), server)
        client.activate(origin: origin)
        defer { client.suspend() }
        while !(await server.identityStarted) { await Task.yield() }
        client.renew()
        try await finish(client)
        for _ in 0..<500 {
            if client.configuration(origin: origin)?.token == "v2.rotated" { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(client.configuration(origin: origin)?.token, "v2.rotated")
    }

    func testMultipleAccountsSurviveRenewalAndRestore() async throws {
        let vault = RelayVault()
        let multiple = tokens.replacingOccurrences(of: "[\"123\"]", with: "[\"123\",\"456\"]")
        let server = RelayReplies([response(201, grant), response(200, multiple), response(200, rotated)])
        let client = session(vault, server)
        client.enroll(origin: origin)
        try await finish(client)
        XCTAssertEqual(client.installationCount, 2)
        client.renew()
        try await finish(client)
        XCTAssertEqual(client.credentials?.pair.installations, ["123", "456"])
        let restored = session(vault, RelayReplies([]))
        XCTAssertEqual(restored.installationCount, 2)
        await assertVerified(restored, token: "v2.rotated", origin: origin)
    }

    func testUnavailableEnrollmentPreservesLegacyAndNeverOpensBrowser() async throws {
        for status in [404, 503, 429] {
            let vault = RelayVault()
            let server = RelayReplies([response(status)])
            var opened = false
            let client = session(vault, server, browser: { _ in opened = true; return true })
            client.enroll(origin: origin)
            try await finish(client)
            XCTAssertFalse(opened)
            XCTAssertNil(vault.value)
            XCTAssertNil(client.configuration(origin: origin))
            let requests = await server.requests
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests[0].url?.path, "/devices")
            XCTAssertEqual(requests[0].url?.host, "access.example")
            XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: XCTUnwrap(requests[0].httpBody)), ["app":"5332457"])
            XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testBrowserEnrollmentPollsPendingThenAtomicallyStoresBothTokens() async throws {
        let vault = RelayVault()
        let server = RelayReplies([response(201, grant), response(202), response(200, tokens)])
        var opened: URL?
        let client = session(vault, server, browser: { opened = $0; return true })
        client.enroll(origin: origin)
        try await finish(client)
        XCTAssertEqual(opened?.host, "auth.example")
        XCTAssertEqual(vault.writes, 1)
        XCTAssertEqual(client.configuration(origin: origin)?.token, "v2.new")
        XCTAssertEqual(client.credentials?.pair.refresh_token, "refresh-new")
        XCTAssertEqual(client.credentials?.pair.computer_id, "computer-A")
        XCTAssertEqual(client.credentials?.pair.installations, ["123"])
        let requests = await server.requests
        XCTAssertEqual(requests.map { $0.url!.path }, ["/devices", "/devices/token", "/devices/token"])
        for request in requests.dropFirst() {
            XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: XCTUnwrap(request.httpBody)), ["device_code": "one-use-code"])
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testRefusedCodeStopsPollingWithoutReplacingLegacy() async throws {
        let vault = RelayVault()
        let server = RelayReplies([response(201, grant), response(401)])
        let client = session(vault, server)
        client.enroll(origin: origin)
        try await finish(client)
        XCTAssertNil(vault.value)
        XCTAssertNil(client.configuration(origin: origin))
        let count = await server.requests.count
        XCTAssertEqual(count, 2)
    }

    func testInvalidBrowserURLIsNotOpened() async throws {
        let vault = RelayVault()
        let server = RelayReplies([response(201, grant.replacingOccurrences(of: "https://auth", with: "http://auth"))])
        var opened = false
        let client = session(vault, server, browser: { _ in opened = true; return true })
        client.enroll(origin: origin)
        try await finish(client)
        XCTAssertFalse(opened)
        XCTAssertNil(vault.value)
    }


    func testUntrustedHTTPSBrowserOriginIsNeverOpened() async throws {
        let vault = RelayVault()
        let server = RelayReplies([response(201, grant.replacingOccurrences(of: "auth.example", with: "attacker.example"))])
        var opened = false
        let client = session(vault, server, browser: { _ in opened = true; return true })
        client.enroll(origin: origin)
        try await finish(client)
        XCTAssertFalse(opened)
        XCTAssertNil(vault.value)
    }

    func testTransientKeychainFailureRecoversWithoutRelaunch() async throws {
        let stored = try existing()
        var locked = true
        let client = RelayDeviceSession(read: {
            if locked { throw URLError(.cannotOpenFile) }
            return stored
        }, save: { _ in }, legacy: { "v1.legacy" }, send: { request in
                RelayHTTPReply(status: 200, data: Data((request.url?.host == "api.github.com" ? #"{"id":100}"# : #"{"subject":"100"}"#).utf8))
            }, openBrowser: { _ in true },
            authorityOrigin: { "https://access.example" }, browserOrigin: { "https://auth.example" }, permittedOrigin: { "https://relay.example" }, removeLegacy: { })
        XCTAssertNil(client.configuration(origin: origin))
        client.githubToken = { "native-test-token" }
        locked = false
        client.activate(origin: origin)
        await assertVerified(client, token: "v2.new", origin: origin)
        client.suspend()
    }

    func testInvalidRevocationCredentialDoesNotBlockEnrollment() async throws {
        let vault = RelayVault(try existing())
        let server = RelayReplies([response(401), response(201, grant), response(200, tokens)])
        let client = session(vault, server)
        client.revoke()
        try await finish(client)
        XCTAssertNil(client.credentials?.pendingRevocation)
        XCTAssertNil(client.configuration(origin: origin))
        client.enroll(origin: origin)
        try await finish(client)
        await assertVerified(client, token: "v2.new", origin: origin)
        let count = await server.requests.count
        XCTAssertEqual(count, 3)
    }

    func testShortLivedAccessDoesNotScheduleImmediateRotationLoop() async throws {
        var saved = try JSONDecoder().decode(RelayDeviceCredentials.self, from: Data(existing().utf8))
        saved.pair = RelayTokenPair(access_token: "v2.short", refresh_token: "refresh-short", expires_in: 1, computer_id: "computer-A")
        saved.expiresAt = Date().addingTimeInterval(1)
        let vault = RelayVault(String(decoding: try JSONEncoder().encode(saved), as: UTF8.self))
        let server = RelayReplies([response(200, tokens)])
        let client = session(vault, server)
        client.activate(origin: origin)
        try await Task.sleep(for: .milliseconds(100))
        client.suspend()
        let count = await server.requests.count
        XCTAssertEqual(count, 0)
    }

    func testRejectedAccessCannotReconnectOrBypassRenewalBackoff() async throws {
        let vault = RelayVault(try existing())
        let server = RelayReplies([response(503)])
        let client = session(vault, server)
        client.onChange = { XCTAssertNil(client.configuration(origin: self.origin)) }
        client.accessExpired()
        try await finish(client)
        for _ in 0..<10 { client.accessExpired(); client.renew() }
        try await finish(client)
        let count = await server.requests.count
        XCTAssertEqual(count, 1)
        XCTAssertNil(client.configuration(origin: origin))
        let restored = session(vault, server)
        XCTAssertNil(restored.configuration(origin: origin), "A pending rotation must not revive rejected access")
        client.onChange = nil
        client.suspend()
    }

    func testRejectedAccessStaysBlockedWhenRetryMarkerCannotBeSaved() async throws {
        let vault = RelayVault(try existing())
        vault.failWrite = 1
        let server = RelayReplies([response(200, rotated)])
        let client = session(vault, server)
        client.accessExpired()
        try await finish(client)
        client.accessExpired()
        try await finish(client)
        let count = await server.requests.count
        XCTAssertEqual(count, 0)
        XCTAssertNil(client.configuration(origin: origin))
    }

    func testConcurrentRenewalTriggersOnlyOneRotationAndPreservesInstallations() async throws {
        let vault = RelayVault(try existing())
        let server = RelayReplies([response(200, rotated)])
        let client = session(vault, server)
        client.renew()
        client.renew()
        client.accessExpired()
        try await finish(client)
        let requests = await server.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.path, "/tokens/refresh")
        XCTAssertEqual(requests[0].url?.host, "access.example")
        let payload = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(requests[0].httpBody))
        XCTAssertEqual(payload["refresh_token"], "refresh-new")
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(payload["request_id"])))
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(client.credentials?.pair.installations, ["123"])
        await assertVerified(client, token: "v2.rotated", origin: origin)
        let restored = session(vault, server)
        XCTAssertEqual(restored.credentials?.pair.refresh_token, "refresh-rotated")
        XCTAssertEqual(vault.writes, 2) // marker then complete new pair
    }

    func testLostRotationResponseRetriesSameRequestAfterRestart() async throws {
        let vault = RelayVault(try existing())
        let lost = RelayReplies([])
        let client = session(vault, lost)
        client.renew()
        try await finish(client)
        XCTAssertFalse(client.needsEnrollment)
        let server = RelayReplies([response(200, rotated)])
        let restored = session(vault, server)
        restored.renew()
        try await finish(restored)
        let first = await lost.requests
        let retried = await server.requests
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(retried.count, 1)
        let initialBody = try JSONDecoder().decode([String:String].self, from: XCTUnwrap(first[0].httpBody))
        let retryBody = try JSONDecoder().decode([String:String].self, from: XCTUnwrap(retried[0].httpBody))
        XCTAssertEqual(initialBody, retryBody)
        await assertVerified(restored, token: "v2.rotated", origin: origin)
    }

    func testRefusedRefreshRequiresEnrollmentAndDoesNotRetry() async throws {
        let vault = RelayVault(try existing())
        let server = RelayReplies([response(401)])
        let client = session(vault, server)
        client.accessExpired()
        try await finish(client)
        client.accessExpired()
        XCTAssertTrue(client.needsEnrollment)
        XCTAssertNil(client.configuration(origin: origin))
        let count = await server.requests.count
        XCTAssertEqual(count, 1)
    }

    func testRefusedRefreshRetriesLegacyCleanupAfterRestart() async throws {
        let vault = RelayVault(try existing())
        let server = RelayReplies([response(401), response(401)])
        let client = session(vault, server, removeLegacy: { throw URLError(.cannotRemoveFile) })
        client.accessExpired()
        try await finish(client)
        client.suspend()
        XCTAssertNotNil(client.credentials?.pendingRefreshID)
        XCTAssertNil(client.configuration(origin: origin))
        var removed = false
        let restored = session(vault, server, removeLegacy: { removed = true })
        restored.renew()
        try await finish(restored)
        XCTAssertTrue(removed)
        XCTAssertTrue(restored.credentials?.isCleared == true)
    }

    func testFailedMarkerWriteDoesNotSendRefreshToken() async throws {
        let vault = RelayVault(try existing())
        vault.failWrite = 1
        let server = RelayReplies([response(200, rotated)])
        let client = session(vault, server)
        client.renew()
        try await finish(client)
        let count = await server.requests.count
        XCTAssertEqual(count, 0)
        await assertVerified(client, token: "v2.new", origin: origin)
    }

    func testFailedPairWritePreservesSameRotationForRetry() async throws {
        let vault = RelayVault(try existing())
        vault.failWrite = 2
        let server = RelayReplies([response(200, rotated), response(200, rotated)])
        let client = session(vault, server)
        client.renew()
        try await finish(client)
        let restored = session(vault, server)
        XCTAssertFalse(restored.needsEnrollment)
        restored.renew()
        try await finish(restored)
        let requests = await server.requests
        XCTAssertEqual(requests.count, 2)
        let first = try JSONDecoder().decode([String:String].self, from: XCTUnwrap(requests[0].httpBody))
        let second = try JSONDecoder().decode([String:String].self, from: XCTUnwrap(requests[1].httpBody))
        XCTAssertEqual(first, second)
        await assertVerified(restored, token: "v2.rotated", origin: origin)
    }

    func testCredentialsAreBoundToOrigin() async throws {
        let client = session(RelayVault(try existing()), RelayReplies([]))
        XCTAssertNil(client.configuration(origin: "https://other.example"))
        await assertVerified(client, token: "v2.new", origin: origin + "/")
    }

    func testRevocationUsesRefreshCredentialAndKeepsRevokedMarker() async throws {
        let vault = RelayVault(try existing())
        let server = RelayReplies([response(204)])
        let client = session(vault, server)
        client.revoke()
        try await finish(client)
        let requests = await server.requests
        XCTAssertEqual(requests[0].url?.path, "/computers/revoke")
        XCTAssertEqual(requests[0].url?.host, "access.example")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertNotNil(requests[0].httpBody)
        XCTAssertTrue(session(vault, server).needsEnrollment)
        XCTAssertNil(client.configuration(origin: origin))
    }

    func testRevocationWorksWithoutRenewingExpiredAccess() async throws {
        let vault = RelayVault(try existing(expires: Date().addingTimeInterval(-1)))
        let server = RelayReplies([response(204)])
        let client = session(vault, server)
        client.revoke()
        try await finish(client)
        let requests = await server.requests
        XCTAssertEqual(requests.map { $0.url!.path }, ["/computers/revoke"])
    }

    func testPendingRevocationSurvivesRestart() async throws {
        let vault = RelayVault(try existing())
        let server = RelayReplies([response(503), response(204)])
        let first = session(vault, server)
        first.revoke()
        try await finish(first)
        XCTAssertEqual(first.credentials?.pendingRevocation, true)
        XCTAssertNil(first.configuration(origin: origin))
        let restarted = session(vault, server)
        restarted.revoke()
        try await finish(restarted)
        XCTAssertNil(restarted.credentials?.pendingRevocation)
        let requests = await server.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
    }

    func testLegacyExpirationDoesNotAttemptRefreshOrRevocation() async throws {
        let vault = RelayVault()
        let server = RelayReplies([])
        let client = session(vault, server)
        client.accessExpired()
        client.revoke()
        XCTAssertNil(client.configuration(origin: origin))
        XCTAssertNil(vault.value)
        let count = await server.requests.count
        XCTAssertEqual(count, 0)
    }

    func testSuspendDoesNotEraseEnrollment() throws {
        let vault = RelayVault(try existing())
        let client = session(vault, RelayReplies([]))
        client.activate(origin: origin)
        client.suspend()
        XCTAssertNil(client.configuration(origin: origin))
        XCTAssertEqual(vault.writes, 0)
    }

    func testExpiredAccessRenewsAutomaticallyOnActivation() async throws {
        let vault = RelayVault(try existing(expires: Date().addingTimeInterval(-1)))
        let server = RelayReplies([response(200, rotated)])
        let client = session(vault, server)
        client.activate(origin: origin)
        for _ in 0..<1000 {
            if client.credentials?.pair.access_token == "v2.rotated" { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        client.suspend()
        XCTAssertNil(client.configuration(origin: origin))
        let count = await server.requests.count
        XCTAssertEqual(count, 1)
    }

    func testSuspendingAnExpiredSessionPreventsScheduledRenewal() async throws {
        let vault = RelayVault(try existing(expires: Date().addingTimeInterval(-1)))
        let server = RelayReplies([response(200, rotated)])
        let client = session(vault, server)
        client.activate(origin: origin)
        client.suspend()
        try await Task.sleep(for: .milliseconds(10))
        let count = await server.requests.count
        XCTAssertEqual(count, 0)
    }

    func testEnrollmentWriteFailurePreservesLegacy() async throws {
        let vault = RelayVault()
        vault.failWrite = 1
        let server = RelayReplies([response(201, grant), response(200, tokens)])
        let client = session(vault, server)
        client.enroll(origin: origin)
        try await finish(client)
        XCTAssertNil(vault.value)
        XCTAssertNil(client.configuration(origin: origin))
    }

    func testCancellationBeforeSetupDoesNotMakeNetworkRequest() async throws {
        let vault = RelayVault()
        let server = RelayReplies([response(201, grant)])
        let client = session(vault, server)
        client.enroll(origin: origin)
        client.cancelEnrollment()
        try await finish(client)
        let count = await server.requests.count
        XCTAssertEqual(count, 0)
        XCTAssertNil(client.configuration(origin: origin))
    }

    func testUnreadableSavedEnrollmentDoesNotFallBackToLegacy() {
        let client = session(RelayVault("invalid saved record"), RelayReplies([]))
        XCTAssertNil(client.configuration(origin: origin))
        XCTAssertTrue(client.needsEnrollment)
    }
    func testBrowserAccountMismatchCannotInstallEnrollment() async throws {
        let vault = RelayVault()
        let server = RelayReplies([response(201, grant), response(200, tokens)])
        await server.setIdentity(subject: "200")
        let client = session(vault, server)
        client.enroll(origin: origin)
        try await finish(client)
        XCTAssertNil(vault.value)
        XCTAssertNil(client.configuration(origin: origin))
        XCTAssertTrue(client.message?.contains("different GitHub account") == true)
    }

    func testRestoredPairingIsBlockedUntilIdentityMatchesAndAfterAccountSwitch() async throws {
        let server = RelayReplies([])
        let client = session(RelayVault(try existing()), server)
        var nativeToken: String? = "alice"
        client.githubToken = { nativeToken }
        XCTAssertNil(client.configuration(origin: origin))
        client.activate(origin: origin)
        for _ in 0..<500 {
            if client.configuration(origin: origin) != nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertNotNil(client.configuration(origin: origin))
        nativeToken = "bob"
        XCTAssertNil(client.configuration(origin: origin), "Account replacement must stop access synchronously")
        await server.setIdentity(nativeID: 200)
        client.activate(origin: origin)
        for _ in 0..<500 {
            if client.message?.contains("different GitHub account") == true { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertNil(client.configuration(origin: origin))
        XCTAssertTrue(client.message?.contains("different GitHub account") == true)
        nativeToken = nil
        XCTAssertNil(client.configuration(origin: origin))
        client.suspend()
    }

    func testUnavailableIdentityEndpointFailsClosed() async throws {
        let vault = RelayVault()
        let server = RelayReplies([response(201, grant), response(200, tokens)])
        await server.setIdentity(status: 503)
        let client = session(vault, server)
        client.enroll(origin: origin)
        try await finish(client)
        XCTAssertNil(vault.value)
        XCTAssertNil(client.configuration(origin: origin))
    }

    func testLateIdentityResponseCannotRestoreSignedOutSession() async throws {
        let server = RelayReplies([])
        await server.delayIdentityResponse()
        let client = session(RelayVault(try existing()), server)
        var token: String? = "alice"
        client.githubToken = { token }
        client.activate(origin: origin)
        for _ in 0..<500 {
            if await server.identityStarted { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let started = await server.identityStarted
        XCTAssertTrue(started)
        token = nil
        client.suspend()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(client.configuration(origin: origin))
    }

    func testEnrollmentCannotAssociateOfficialCredentialsWithAnotherRelay() async throws {
        let vault = RelayVault()
        let server = RelayReplies([response(201, grant), response(200, tokens)])
        let client = session(vault, server)
        client.enroll(origin: "https://attacker.example")
        try await finish(client)
        let requests = await server.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertNil(vault.value)
    }

    func testRestoredUntrustedRelayCannotVerifyOrRenewCredentials() async throws {
        let poisoned = try existing().replacingOccurrences(of: "relay.example", with: "attacker.example")
        let server = RelayReplies([])
        let client = session(RelayVault(poisoned), server)
        client.activate(origin: "https://attacker.example")
        client.renew()
        try await finish(client)
        XCTAssertNil(client.configuration(origin: "https://attacker.example"))
        let requests = await server.requests
        let githubRequests = await server.githubRequests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(githubRequests.isEmpty)
        client.suspend()
    }

    func testConfirmedRevocationErasesSecretsButKeepsNonSecretTombstone() async throws {
        let vault = RelayVault(try existing())
        let client = session(vault, RelayReplies([response(204)]))
        client.revoke()
        try await finish(client)
        let saved = try XCTUnwrap(vault.value)
        XCTAssertFalse(saved.contains("refresh-new"))
        XCTAssertFalse(saved.contains("v2.new"))
        XCTAssertTrue(client.credentials?.isCleared == true)
        let restored = session(vault, RelayReplies([]))
        XCTAssertTrue(restored.needsEnrollment)
        XCTAssertFalse(restored.canRevoke)
    }

    func testFailedRevocationCleanupKeepsRetryMaterialUntilConfirmed() async throws {
        let vault = RelayVault(try existing())
        vault.failWrite = 2 // Pending marker succeeds; the scrubbed record fails.
        let server = RelayReplies([response(204), response(401)])
        let client = session(vault, server)
        client.revoke()
        try await finish(client)
        XCTAssertTrue(client.credentials?.pendingRevocation == true)
        XCTAssertNil(client.configuration(origin: origin))
        let restored = session(vault, server)
        restored.revoke()
        try await finish(restored)
        XCTAssertTrue(restored.credentials?.isCleared == true)
        XCTAssertFalse(try XCTUnwrap(vault.value).contains("refresh-new"))
    }

}
