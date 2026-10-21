import Foundation

/// Operations are injected so failure/restart behavior can be checked without
/// reading the developer's Keychain or deleting real credentials.
struct GitHubCredentialStorage {
    var read: () throws -> String?
    var write: (String) throws -> Void
    var remove: () throws -> Void
    var readLegacy: () throws -> String?
    var removeLegacy: () throws -> Void
    var isSignedOut: () -> Bool
    var setSignedOut: (Bool) -> Void
    var cleanupPending: () -> Bool
    var setCleanupPending: (Bool) -> Void

    func token(environment: String? = nil) throws -> String? {
        if isSignedOut() {
            if cleanupPending() { try delete() }
            return nil
        }
        // Never fall back to plaintext after a Keychain read error.
        if let token = try read(), !token.isEmpty {
            try removeLegacy()
            return token
        }
        if let legacy = try readLegacy(), !legacy.isEmpty {
            try write(legacy)
            try removeLegacy()
            return legacy
        }
        return environment
    }

    func save(_ token: String) throws {
        setSignedOut(true)
        try write(token)
        try removeLegacy()
        setCleanupPending(false)
        setSignedOut(false)
    }

    func delete() throws {
        // Persist the sign-out decision before attempting fallible cleanup.
        // A retained secret must not restore authentication after a restart.
        setSignedOut(true)
        setCleanupPending(true)
        var failed = false
        do { try remove() } catch { failed = true }
        do { try removeLegacy() } catch { failed = true }
        guard !failed else { throw CredentialStorageError.cleanupFailed }
        setCleanupPending(false)
    }
}

enum CredentialStorageError: LocalizedError {
    case cleanupFailed
    var errorDescription: String? {
        "Signed out, but stored credentials could not be fully removed. Retry credential removal in Settings after unlocking your Mac."
    }
}

enum TokenStore {
    private static let signedOutKey = "githubExplicitlySignedOut"
    private static let cleanupKey = "githubCredentialCleanupPending"
    private static var legacyFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(legacyDirectory, isDirectory: true)
            .appendingPathComponent("github-token")
    }

    private static var legacyDirectory: String {
        #if DEBUG
        return "Git Island Dev"
        #else
        return "Git Island"
        #endif
    }

    static var cleanupPending: Bool { UserDefaults.standard.bool(forKey: cleanupKey) }

    private static var storage: GitHubCredentialStorage {
        GitHubCredentialStorage(
            read: { try KeychainTokenStore.storedToken() },
            write: { try KeychainTokenStore.save($0) },
            remove: { try KeychainTokenStore.delete() },
            readLegacy: {
                do {
                    let value = try String(contentsOf: legacyFileURL, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return value.isEmpty ? nil : value
                } catch CocoaError.fileReadNoSuchFile { return nil }
            },
            removeLegacy: {
                do { try FileManager.default.removeItem(at: legacyFileURL) }
                catch CocoaError.fileNoSuchFile { }
            },
            isSignedOut: { UserDefaults.standard.bool(forKey: signedOutKey) },
            setSignedOut: { UserDefaults.standard.set($0, forKey: signedOutKey) },
            cleanupPending: { cleanupPending },
            setCleanupPending: { UserDefaults.standard.set($0, forKey: cleanupKey) })
    }

    static func save(_ token: String) throws { try storage.save(token) }
    static func storedToken() throws -> String? { try storage.token(environment: environmentToken) }
    static func token() -> String? { try? storedToken() }
    static func delete() throws { try storage.delete() }

    private static var environmentToken: String? {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let value = environment["GITHUB_TOKEN"] ?? environment["GH_TOKEN"]
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
        #else
        return nil
        #endif
    }
}
