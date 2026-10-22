import Foundation

/// A pull request hidden until its group, head SHA, or reason changes.
struct HiddenPullRequest: Codable, Equatable, Identifiable, Hashable {
    let id: Int
    let group: String
    let headSHA: String
    let reason: String
    let repositoryFullName: String
    let number: Int

    init(pullRequest: PullRequest) {
        id = pullRequest.id
        group = pullRequest.group.rawValue
        headSHA = pullRequest.headSHA
        reason = pullRequest.reason
        repositoryFullName = UserPreferences.normalizedRepositoryFullName(pullRequest.repositoryFullName)
            ?? pullRequest.repositoryFullName.lowercased()
        number = pullRequest.number
    }

    func matches(_ pullRequest: PullRequest) -> Bool {
        id == pullRequest.id
            && group == pullRequest.group.rawValue
            && headSHA == pullRequest.headSHA
            && reason == pullRequest.reason
    }
}

enum InboxFilter {
    static func visible(
        _ pullRequests: [PullRequest],
        mode: RepositoryFilterMode,
        selectedRepositories: [String],
        mutedRepositories: [String],
        hiddenPullRequests: [HiddenPullRequest],
        suppressedIDs: Set<Int> = []
    ) -> [PullRequest] {
        let selected = repositoryNames(selectedRepositories)
        let muted = repositoryNames(mutedRepositories)

        return pullRequests.filter { pullRequest in
            guard !suppressedIDs.contains(pullRequest.id),
                  let repository = UserPreferences.normalizedRepositoryFullName(pullRequest.repositoryFullName),
                  !muted.contains(repository)
            else {
                return false
            }

            if mode == .selected, !selected.contains(repository) {
                return false
            }

            return !hiddenPullRequests.contains { $0.matches(pullRequest) }
        }
    }

    /// Drop a hide once its pull request leaves the inbox or its signature changes.
    static func reconciledHiddenPullRequests(
        _ hiddenPullRequests: [HiddenPullRequest],
        fetched: [PullRequest]
    ) -> [HiddenPullRequest] {
        let byID = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        return hiddenPullRequests.filter { hidden in
            guard let pullRequest = byID[hidden.id] else {
                return false
            }
            return hidden.matches(pullRequest)
        }
    }

    private static func repositoryNames(_ values: [String]) -> Set<String> {
        Set(values.compactMap(UserPreferences.normalizedRepositoryFullName))
    }
}
