import XCTest
@testable import GitIsland

final class InboxFilterTests: XCTestCase {
    func testAllModeDropsMutedRepositoriesAndHiddenPullRequests() {
        let hidden = pullRequest(id: 2, repository: "team/app", reason: "Review required")
        let visible = InboxFilter.visible(
            [
                pullRequest(id: 1, repository: "Team/App"),
                hidden,
                pullRequest(id: 3, repository: "other/tool"),
                pullRequest(id: 4, repository: "not-a-repo"),
                pullRequest(id: 5, repository: "team/web")
            ],
            mode: .all,
            selectedRepositories: [],
            mutedRepositories: ["OTHER/tool"],
            hiddenPullRequests: [HiddenPullRequest(pullRequest: hidden)],
            suppressedIDs: [1]
        )

        XCTAssertEqual(visible.map(\.id), [5])
    }

    func testSelectedModeKeepsOnlyTheAllowlistUnlessMuted() {
        let visible = InboxFilter.visible(
            [
                pullRequest(id: 1, repository: "team/app"),
                pullRequest(id: 2, repository: "team/web"),
                pullRequest(id: 3, repository: "outside/lib")
            ],
            mode: .selected,
            selectedRepositories: ["Team/App", "team/web"],
            mutedRepositories: ["team/web"],
            hiddenPullRequests: []
        )

        XCTAssertEqual(visible.map(\.id), [1])
    }

    func testChangedSignatureDropsTheHideButMissingPullRequestKeepsIt() {
        let hidden = HiddenPullRequest(pullRequest: pullRequest(id: 7, repository: "team/app", reason: "Review required"))
        let changed = pullRequest(id: 7, repository: "team/app", reason: "CI failed", group: .blocked, headSHA: "abc")
        let kept = pullRequest(id: 8, repository: "team/app", reason: "Review required")

        let reconciled = InboxFilter.reconciledHiddenPullRequests(
            [hidden, HiddenPullRequest(pullRequest: kept), HiddenPullRequest(pullRequest: pullRequest(id: 9, repository: "team/app"))],
            fetched: [changed, kept]
        )

        XCTAssertEqual(reconciled.map(\.id), [8, 9])
        XCTAssertEqual(
            InboxFilter.visible(
                [changed, kept],
                mode: .all,
                selectedRepositories: [],
                mutedRepositories: [],
                hiddenPullRequests: reconciled
            ).map(\.id),
            [7]
        )
    }

    func testHiddenPullRequestStaysHiddenAfterMissingRefreshesUntilItChanges() {
        let original = pullRequest(id: 7, repository: "team/app")
        let hidden = [HiddenPullRequest(pullRequest: original)]
        let unrelated = pullRequest(id: 8, repository: "other/tool")
        var reconciled = InboxFilter.reconciledHiddenPullRequests(hidden, fetched: [])
        reconciled = InboxFilter.reconciledHiddenPullRequests(reconciled, fetched: [unrelated])
        reconciled = InboxFilter.reconciledHiddenPullRequests(reconciled, fetched: [original, unrelated])

        XCTAssertEqual(reconciled, hidden)
        XCTAssertEqual(
            InboxFilter.visible(
                [original, unrelated],
                mode: .all,
                selectedRepositories: [],
                mutedRepositories: [],
                hiddenPullRequests: reconciled
            ).map(\.id),
            [8]
        )

        let changed = pullRequest(id: 7, repository: "team/app", headSHA: "new-head")
        XCTAssertTrue(InboxFilter.reconciledHiddenPullRequests(reconciled, fetched: [changed]).isEmpty)
    }

    private func pullRequest(
        id: Int,
        repository: String,
        reason: String = "Review required",
        group: PullRequestGroup = .waiting,
        headSHA: String = "head"
    ) -> PullRequest {
        let parts = repository.split(separator: "/")
        return PullRequest(
            id: id,
            repository: parts.last.map(String.init) ?? repository,
            repositoryFullName: repository,
            number: id,
            title: "Change \(id)",
            group: group,
            reason: reason,
            statusLabel: reason,
            needsUserAction: false,
            age: "1h",
            url: URL(string: "https://example.test/pull/\(id)")!,
            headSHA: headSHA,
            defaultMergeMethod: nil,
            canUpdateBranch: false,
            canMergeAsAdmin: false
        )
    }
}
