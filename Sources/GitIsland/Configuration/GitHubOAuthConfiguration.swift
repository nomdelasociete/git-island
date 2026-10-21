import Foundation

enum GitHubOAuthConfiguration {
    /// The app's public OAuth client ID — registered once by the Git Island publisher.
    /// End users never see or configure this. Create the OAuth app at
    /// https://github.com/settings/applications/new with Device Flow enabled,
    /// then paste the Client ID here before shipping.
    private static let publishedClientID = "Ov23liKEybGZIaD2jr6h"

    /// Local development override. Not required for end users.
    private static let developmentClientID = ProcessInfo.processInfo.environment["GITHUB_OAUTH_CLIENT_ID"]

    static var clientID: String {
        #if DEBUG
        if let developmentClientID, !developmentClientID.isEmpty {
            return developmentClientID
        }
        #endif
        return publishedClientID
    }

    static let scopes = "read:user repo"

    static var isConfigured: Bool {
        !clientID.isEmpty
    }
}