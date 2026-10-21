import Foundation
import XCTest
@testable import GitIsland

final class CredentialStorageTests: XCTestCase {
    private final class Vault {
        var keychain: String?
        var legacy: String?
        var signedOut = false
        var pending = false
        var failRead = false
        var failWrite = false
        var failDelete = false
        var failLegacyDelete = false
        var legacyReads = 0
        var storage: GitHubCredentialStorage {
            GitHubCredentialStorage(read: {
                if self.failRead { throw URLError(.cannotOpenFile) }
                return self.keychain
            }, write: {
                if self.failWrite { throw URLError(.cannotWriteToFile) }
                self.keychain = $0
            }, remove: {
                if self.failDelete { throw URLError(.cannotRemoveFile) }
                self.keychain = nil
            }, readLegacy: {
                self.legacyReads += 1
                return self.legacy
            }, removeLegacy: {
                if self.failLegacyDelete { throw URLError(.cannotRemoveFile) }
                self.legacy = nil
            }, isSignedOut: { self.signedOut }, setSignedOut: { self.signedOut = $0 },
               cleanupPending: { self.pending }, setCleanupPending: { self.pending = $0 })
        }
    }

    func testFailedDeletionCannotRestoreAfterRestartIncludingEnvironmentToken() throws {
        let vault = Vault()
        vault.keychain = "old-token"
        vault.legacy = "old-plaintext"
        vault.failDelete = true
        XCTAssertThrowsError(try vault.storage.delete())
        XCTAssertTrue(vault.signedOut)
        XCTAssertTrue(vault.pending)
        XCTAssertNil(vault.legacy, "Attempt both removals even when Keychain is unavailable")
        XCTAssertThrowsError(try vault.storage.token(environment: "environment-token"))
        vault.failDelete = false
        XCTAssertNil(try vault.storage.token(environment: "environment-token"))
        XCTAssertNil(vault.keychain)
        XCTAssertFalse(vault.pending)
        XCTAssertTrue(vault.signedOut)
    }

    func testFailedMigrationDoesNotReturnPlaintext() throws {
        let vault = Vault()
        vault.legacy = "legacy-token"
        vault.failWrite = true
        XCTAssertThrowsError(try vault.storage.token())
        XCTAssertEqual(vault.legacy, "legacy-token")
        vault.failWrite = false
        XCTAssertEqual(try vault.storage.token(), "legacy-token")
        XCTAssertNil(vault.legacy)
    }

    func testMigrationCleanupFailureRemainsBlockedOnSubsequentRead() throws {
        let vault = Vault()
        vault.legacy = "legacy-token"
        vault.failLegacyDelete = true
        XCTAssertThrowsError(try vault.storage.token())
        XCTAssertEqual(vault.keychain, "legacy-token")
        XCTAssertThrowsError(try vault.storage.token())
        vault.failLegacyDelete = false
        XCTAssertEqual(try vault.storage.token(), "legacy-token")
        XCTAssertNil(vault.legacy)
    }

    func testLockedKeychainDoesNotFallBackToLegacy() {
        let vault = Vault()
        vault.legacy = "legacy-token"
        vault.failRead = true
        XCTAssertThrowsError(try vault.storage.token())
        XCTAssertEqual(vault.legacyReads, 0)
    }

    func testRetryAfterUnlockPreservesStoredCredentials() throws {
        let vault = Vault()
        vault.keychain = "valid-token"
        vault.failRead = true
        XCTAssertThrowsError(try vault.storage.token())
        XCTAssertFalse(vault.signedOut)
        vault.failRead = false
        XCTAssertEqual(try vault.storage.token(), "valid-token")
        XCTAssertEqual(vault.keychain, "valid-token")
        XCTAssertFalse(vault.signedOut)
    }

    func testNewLoginMustFinishCleanupBeforeReenablingAuthentication() throws {
        let vault = Vault()
        vault.failLegacyDelete = true
        XCTAssertThrowsError(try vault.storage.save("new-token"))
        XCTAssertNil(try vault.storage.token())
        vault.failLegacyDelete = false
        try vault.storage.save("new-token")
        XCTAssertEqual(try vault.storage.token(environment: "other-account"), "new-token")
        XCTAssertFalse(vault.signedOut)
    }

    func testDeletionRemovesKeychainEvenIfLegacyRemovalFails() {
        let vault = Vault()
        vault.keychain = "token"
        vault.legacy = "legacy"
        vault.failLegacyDelete = true
        XCTAssertThrowsError(try vault.storage.delete())
        XCTAssertNil(vault.keychain)
        XCTAssertTrue(vault.signedOut)
        XCTAssertTrue(vault.pending)
    }
}
