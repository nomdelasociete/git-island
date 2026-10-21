import Foundation
import Security

enum KeychainTokenStore {
    private static let service = Bundle.main.bundleIdentifier ?? "com.nomdelasociete.GitIsland.dev"
    private static let account = "github-access-token"

    static func save(_ token: String, account: String = account) throws {
        let data = Data(token.utf8)
        let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainTokenStoreError.saveFailed(updateStatus)
            }
            return
        }

        guard status == errSecItemNotFound else {
            throw KeychainTokenStoreError.readFailed(status)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = accessibility

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainTokenStoreError.saveFailed(addStatus)
        }
    }

    static func token(account: String = account) -> String? {
        try? storedToken(account: account)
    }

    static func storedToken(account: String = account) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw KeychainTokenStoreError.readFailed(status)
        }
        return token
    }

    static func delete(account: String = account) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainTokenStoreError.deleteFailed(status)
        }
    }
}

enum KeychainTokenStoreError: LocalizedError {
    case saveFailed(OSStatus)
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            "Could not save token to Keychain (status \(status))."
        case .deleteFailed(let status):
            "Could not remove token from Keychain (status \(status))."
        case .readFailed(let status):
            "Could not read token from Keychain (status \(status))."
        }
    }
}
