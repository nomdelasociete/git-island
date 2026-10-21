import Foundation
import SwiftUI

enum PullRequestGroup: String, CaseIterable, Identifiable {
    case waiting = "Waiting"
    case testing = "Testing"
    case blocked = "Blocked"
    case ready = "Ready"

    var id: String { rawValue }

    var compactTitle: String {
        rawValue
    }

    var compactPriority: Int {
        switch self {
        case .blocked:
            0
        case .waiting:
            1
        case .testing:
            2
        case .ready:
            3
        }
    }

    var tint: Color {
        switch self {
        case .waiting:
            Color(red: 0.91, green: 0.58, blue: 0.20)
        case .testing:
            Color(red: 0.45, green: 0.67, blue: 0.95)
        case .blocked:
            Color(red: 0.98, green: 0.45, blue: 0.42)
        case .ready:
            Color(red: 0.43, green: 0.82, blue: 0.56)
        }
    }

    var symbolName: String {
        switch self {
        case .waiting:
            "clock"
        case .testing:
            "arrow.triangle.2.circlepath"
        case .blocked:
            "exclamationmark"
        case .ready:
            "checkmark"
        }
    }

    var emptyMessage: String {
        switch self {
        case .waiting:
            "Nothing is waiting for review."
        case .testing:
            "No checks running."
        case .blocked:
            "Nothing is blocked."
        case .ready:
            "Nothing is ready to merge."
        }
    }
}

enum PullRequestMergeMethod: String, Hashable {
    case merge
    case squash
    case rebase

    var title: String {
        switch self {
        case .merge:
            "Merge"
        case .squash:
            "Squash"
        case .rebase:
            "Rebase"
        }
    }

    static func githubDefault(_ value: String?) -> PullRequestMergeMethod? {
        switch value?.uppercased() {
        case "MERGE":
            .merge
        case "SQUASH":
            .squash
        case "REBASE":
            .rebase
        default:
            nil
        }
    }
}

struct PullRequest: Identifiable, Hashable {
    let id: Int
    let repository: String
    let repositoryFullName: String
    let number: Int
    let title: String
    let group: PullRequestGroup
    let reason: String
    let statusLabel: String
    let needsUserAction: Bool
    let age: String
    let url: URL
    let headSHA: String
    let defaultMergeMethod: PullRequestMergeMethod?
    let canUpdateBranch: Bool
    /// The viewer is an admin who can merge past branch protection.
    let canMergeAsAdmin: Bool

    func branchUpdateQueued() -> PullRequest {
        PullRequest(
            id: id,
            repository: repository,
            repositoryFullName: repositoryFullName,
            number: number,
            title: title,
            group: .testing,
            reason: "Branch update queued",
            statusLabel: "Updating branch",
            needsUserAction: false,
            age: age,
            url: url,
            headSHA: headSHA,
            defaultMergeMethod: nil,
            canUpdateBranch: false,
            canMergeAsAdmin: false
        )
    }
}

struct PullRequestArrivalPulse: Identifiable, Equatable {
    let id: UUID
    let groups: Set<PullRequestGroup>
    /// Highlights to run along the status outline, as outline fractions.
    let sweeps: [PullRequestOutlineSweep]

    init(id: UUID = UUID(), groups: Set<PullRequestGroup>, sweeps: [PullRequestOutlineSweep]? = nil) {
        self.id = id
        self.groups = groups
        self.sweeps = sweeps ?? PullRequestOutlineSweep.arrival
    }
}

/// A sheen travelling along the outline from one fraction to another: from the
/// old status segment to the new one, or across the whole ring for a new PR.
struct PullRequestOutlineSweep: Hashable {
    let from: CGFloat
    let to: CGFloat

    static let arrival = [
        PullRequestOutlineSweep(from: 0, to: 1),
        PullRequestOutlineSweep(from: 1, to: 0)
    ]
}

struct PullRequestMergeCelebration: Identifiable, Equatable {
    let id: UUID
    let pullRequestID: Int

    init(id: UUID = UUID(), pullRequestID: Int) {
        self.id = id
        self.pullRequestID = pullRequestID
    }
}
