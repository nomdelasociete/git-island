import SwiftUI

/// Inbox moments that can play a sound. When one refresh carries several,
/// only the most important one plays.
enum IslandSoundEvent: String, CaseIterable, Identifiable {
    case newPullRequest
    case becameReady
    case becameBlocked
    case becameWaiting
    case becameTesting
    case merged

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newPullRequest: "New pull request"
        case .becameReady: "Ready to merge"
        case .becameBlocked: "Blocked"
        case .becameWaiting: "Waiting for review"
        case .becameTesting: "Checks running"
        case .merged: "Merged"
        }
    }

    var detail: String {
        switch self {
        case .newPullRequest: "A pull request enters your inbox"
        case .becameReady: "Approved and green"
        case .becameBlocked: "Changes requested, failing checks or conflicts"
        case .becameWaiting: "A review is requested"
        case .becameTesting: "New checks start"
        case .merged: "You merge from the island"
        }
    }

    var symbol: String {
        switch self {
        case .newPullRequest: "sparkles"
        case .becameReady: "checkmark"
        case .becameBlocked: "xmark"
        case .becameWaiting: "eye"
        case .becameTesting: "arrow.triangle.2.circlepath"
        case .merged: "arrow.triangle.merge"
        }
    }

    var tint: Color {
        switch self {
        case .newPullRequest: Color(red: 0.33, green: 0.78, blue: 0.84)
        case .becameReady: PullRequestGroup.ready.tint
        case .becameBlocked: PullRequestGroup.blocked.tint
        case .becameWaiting: PullRequestGroup.waiting.tint
        case .becameTesting: PullRequestGroup.testing.tint
        case .merged: Color(red: 0.64, green: 0.52, blue: 0.96)
        }
    }

    static func statusChange(to group: PullRequestGroup) -> IslandSoundEvent {
        switch group {
        case .ready: .becameReady
        case .blocked: .becameBlocked
        case .waiting: .becameWaiting
        case .testing: .becameTesting
        }
    }

    /// Higher wins when one refresh produces several events.
    var priority: Int {
        switch self {
        case .merged: 5
        case .becameBlocked: 4
        case .becameReady: 3
        case .newPullRequest: 2
        case .becameWaiting: 1
        case .becameTesting: 0
        }
    }
}

enum IslandSoundChoice: Hashable {
    case none
    /// A sound shipped with macOS in /System/Library/Sounds, by name.
    case system(String)
    /// A file the user imported into the app's sound folder, by file name.
    case custom(String)

    init(storageValue: String) {
        if let name = storageValue.dropPrefix("system:") {
            self = .system(name)
        } else if let name = storageValue.dropPrefix("custom:") {
            self = .custom(name)
        } else {
            self = .none
        }
    }

    var storageValue: String {
        switch self {
        case .none: ""
        case .system(let name): "system:\(name)"
        case .custom(let name): "custom:\(name)"
        }
    }

    var label: String {
        switch self {
        case .none: "None"
        case .system(let name): name
        case .custom(let name): (name as NSString).deletingPathExtension
        }
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix), count > prefix.count else { return nil }
        return String(dropFirst(prefix.count))
    }
}
