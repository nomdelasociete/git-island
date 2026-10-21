import Foundation
import XCTest
@testable import GitIsland

/// Operator-only: requires an authorized browser enrollment and a dedicated
/// test GitHub account. Never reads the native application's credential item.
@MainActor
final class RelayLiveAcceptanceTests: XCTestCase {
    func testProductionLifecycle() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["RELAY_LIVE_VALIDATION_DIR"],
              let nativeToken = environment["RELAY_LIVE_GITHUB_TOKEN"], !nativeToken.isEmpty else {
            throw XCTSkip("Live acceptance requires an authorized enrollment window and a dedicated test-account token")
        }
        let account = "relay-live-test-" + UUID().uuidString
        let origin = UserPreferences.officialRelayOrigin
        let runDirectory = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(account)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let urlFile = runDirectory.appendingPathComponent("browser-url")
        var clients: [RelayDeviceSession] = []
        defer {
            clients.forEach { $0.suspend() }
            try? FileManager.default.removeItem(at: urlFile)
        }
        func make() -> RelayDeviceSession {
            let session = RelayDeviceSession(read: { try KeychainTokenStore.storedToken(account: account) },
                save: { try KeychainTokenStore.save($0, account: account) }, legacy: { nil },
                openBrowser: { url in
                    do {
                        try Data(url.absoluteString.utf8).write(to: urlFile, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: urlFile.path)
                        return true
                    } catch { return false }
                }, removeLegacy: { }) // Never touch the real app's legacy item.
            session.githubToken = { nativeToken }
            clients.append(session)
            return session
        }
        func finish(_ client: RelayDeviceSession) async throws {
            let deadline = Date().addingTimeInterval(610)
            while client.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            guard !client.isBusy else { throw URLError(.timedOut) }
        }
        func verified(_ client: RelayDeviceSession) async throws -> RelayConfiguration {
            client.activate(origin: origin)
            for _ in 0..<100 {
                if let config = client.configuration(origin: origin) { return config }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw URLError(.userAuthenticationRequired)
        }
        // Capture thrown failures, then attempt remote cleanup before rethrowing.
        var failure: Error?
        do {
            let client = make()
            client.enroll(origin: origin)
            try await finish(client)
            guard client.canRevoke else { throw URLError(.userAuthenticationRequired) }
            client.suspend()
            let restored = make()
            let first = try await verified(restored)
            restored.accessExpired()
            try await finish(restored)
            let renewed = try await verified(restored)
            XCTAssertTrue(renewed.token != first.token, "Rotation must replace the access credential")
            let network = GitHubTransport.session()
            defer { network.invalidateAndCancel() }
            let (bytes, response) = try await network.bytes(for: renewed.request(path: "stream"))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            var lines = bytes.lines.makeAsyncIterator()
            let connected = try await lines.next()
            XCTAssertTrue(connected == ": connected", "Expected the stream handshake")
            bytes.task.cancel()
            restored.revoke()
            try await finish(restored)
            XCTAssertTrue(restored.credentials?.isCleared == true)
            XCTAssertNil(restored.configuration(origin: origin))
            let (_, rejected) = try await network.data(for: renewed.request(path: "stream"))
            XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 401)
        } catch { failure = error }

        clients.forEach { $0.suspend() }
        // Wait for in-flight rotation so cleanup reads the newest persisted pair.
        for client in clients {
            if client.isEnrolling { client.cancelEnrollment() }
            try? await finish(client)
        }
        let cleanup = make()
        if cleanup.canRevoke || cleanup.credentials?.pendingRevocation == true {
            cleanup.revoke()
            try? await finish(cleanup)
        }
        if cleanup.credentials?.isCleared == true || !cleanup.hasSavedEnrollment {
            try KeychainTokenStore.delete(account: account)
            try? FileManager.default.removeItem(at: runDirectory)
        } else {
            // Keep retry credentials in Keychain and a non-secret recovery pointer.
            try Data(account.utf8).write(to: runDirectory.appendingPathComponent("recovery-account"), options: .atomic)
            XCTFail("Live cleanup remains pending. Retry revocation using the isolated Keychain item identified in the private validation directory; do not delete it first.")
        }
        if let failure { throw failure }
    }
}
