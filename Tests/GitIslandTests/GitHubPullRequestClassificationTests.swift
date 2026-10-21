import Foundation
import XCTest
@testable import GitIsland

final class GitHubPullRequestClassificationTests: XCTestCase {
    private let service = GitHubPullRequestService()
    private let currentLogin = "example-user"

    func testActionRequiredCheckWinsOverGenericBlockedMergeState() {
        let classification = classify(
            mergeReadiness: readiness(
                reviewDecision: "REVIEW_REQUIRED",
                mergeStateStatus: "BLOCKED"
            ),
            pipeline: pipeline(
                checkRuns: [
                    GitHubCheckRun(
                        name: "Example Review",
                        status: "completed",
                        conclusion: "action_required"
                    )
                ]
            )
        )

        XCTAssertEqual(classification.group, .blocked)
        XCTAssertEqual(classification.reason, "Example Review failed")
        XCTAssertEqual(classification.statusLabel, "Your turn")
        XCTAssertTrue(classification.needsUserAction)
    }

    func testPendingCheckWinsOverGenericBlockedMergeState() {
        let classification = classify(
            mergeReadiness: readiness(
                reviewDecision: "APPROVED",
                mergeStateStatus: "BLOCKED"
            ),
            pipeline: pipeline(
                checkRuns: [
                    GitHubCheckRun(
                        name: "ci/woodpecker/pr/typecheck",
                        status: "in_progress",
                        conclusion: nil
                    )
                ]
            )
        )

        XCTAssertEqual(classification.group, .testing)
        XCTAssertEqual(classification.reason, "ci/woodpecker/pr/typecheck running")
        XCTAssertEqual(classification.statusLabel, "Checks running")
        XCTAssertFalse(classification.needsUserAction)
    }

    func testFreshFailedCheckWinsOverStalePendingRollup() {
        let classification = classify(
            mergeReadiness: readiness(
                reviewDecision: "CHANGES_REQUESTED",
                mergeStateStatus: "UNSTABLE",
                statusCheckRollupState: "PENDING"
            ),
            pipeline: pipeline(
                checkRuns: [
                    GitHubCheckRun(
                        name: "ci/woodpecker/pr/build",
                        status: "completed",
                        conclusion: "failure"
                    )
                ],
                combinedState: "failure"
            )
        )

        XCTAssertEqual(classification.group, .blocked)
        XCTAssertEqual(classification.reason, "ci/woodpecker/pr/build failed")
        XCTAssertEqual(classification.statusLabel, "Your turn")
        XCTAssertTrue(classification.needsUserAction)
    }

    func testFreshSuccessfulPipelineWinsOverStalePendingRollup() {
        let classification = classify(
            mergeReadiness: readiness(
                reviewDecision: "APPROVED",
                mergeStateStatus: "CLEAN",
                statusCheckRollupState: "PENDING"
            ),
            pipeline: successfulPipeline()
        )

        XCTAssertEqual(classification.group, .ready)
        XCTAssertEqual(classification.reason, "Approved and green")
        XCTAssertEqual(classification.statusLabel, "Ready to merge")
        XCTAssertTrue(classification.needsUserAction)
    }

    func testPendingRollupIsTestingWhenNoConcretePipelineSignalsAreAvailable() {
        let classification = classify(
            mergeReadiness: readiness(
                reviewDecision: "APPROVED",
                mergeStateStatus: "CLEAN",
                statusCheckRollupState: "PENDING"
            ),
            pipeline: pipeline()
        )

        XCTAssertEqual(classification.group, .testing)
        XCTAssertEqual(classification.reason, "Checks running")
        XCTAssertEqual(classification.statusLabel, "Checks running")
        XCTAssertFalse(classification.needsUserAction)
    }

    func testAllKnownPendingCheckStatusesAreTesting() {
        for status in ["requested", "queued", "in_progress", "waiting", "pending"] {
            let classification = classify(
                mergeReadiness: readiness(
                    reviewDecision: "APPROVED",
                    mergeStateStatus: "BLOCKED"
                ),
                pipeline: pipeline(
                    checkRuns: [
                        GitHubCheckRun(
                            name: "ci/woodpecker/pr/\(status)",
                            status: status,
                            conclusion: nil
                        )
                    ]
                )
            )

            XCTAssertEqual(classification.group, .testing, status)
            XCTAssertEqual(classification.statusLabel, "Checks running", status)
        }
    }

    func testAllKnownFailingCheckConclusionsAreBlocked() {
        for conclusion in ["action_required", "timed_out", "cancelled", "failure", "startup_failure", "stale"] {
            let classification = classify(
                mergeReadiness: readiness(
                    reviewDecision: "APPROVED",
                    mergeStateStatus: "BLOCKED"
                ),
                pipeline: pipeline(
                    checkRuns: [
                        GitHubCheckRun(
                            name: "ci/woodpecker/pr/\(conclusion)",
                            status: "completed",
                            conclusion: conclusion
                        )
                    ]
                )
            )

            XCTAssertEqual(classification.group, .blocked, conclusion)
            XCTAssertEqual(classification.reason, "ci/woodpecker/pr/\(conclusion) failed", conclusion)
            XCTAssertEqual(classification.statusLabel, "Your turn", conclusion)
        }
    }

    func testKnownSuccessfulCheckConclusionsCanBeReady() {
        for conclusion in ["neutral", "skipped", "success"] {
            let classification = classify(
                mergeReadiness: readiness(
                    reviewDecision: "APPROVED",
                    mergeStateStatus: "CLEAN"
                ),
                pipeline: pipeline(
                    checkRuns: [
                        GitHubCheckRun(
                            name: "ci/woodpecker/pr/\(conclusion)",
                            status: "completed",
                            conclusion: conclusion
                        )
                    ]
                )
            )

            XCTAssertEqual(classification.group, .ready, conclusion)
            XCTAssertEqual(classification.statusLabel, "Ready to merge", conclusion)
        }
    }

    func testBehindBranchStaysReadyWhenApprovedAndGreen() {
        let classification = classify(
            mergeReadiness: readiness(
                reviewDecision: "APPROVED",
                mergeStateStatus: "BEHIND"
            ),
            pipeline: successfulPipeline()
        )

        XCTAssertEqual(classification.group, .ready)
        XCTAssertEqual(classification.reason, "Branch behind")
        XCTAssertEqual(classification.statusLabel, "Update branch")
        XCTAssertTrue(classification.needsUserAction)
        XCTAssertTrue(classification.canUpdateBranch)
    }

    func testBehindBranchDoesNotBypassRequiredReview() {
        let classification = classify(
            mergeReadiness: readiness(
                reviewDecision: "REVIEW_REQUIRED",
                mergeStateStatus: "BEHIND"
            ),
            pipeline: successfulPipeline()
        )

        XCTAssertEqual(classification.group, .waiting)
        XCTAssertEqual(classification.reason, "Waiting for review")
        XCTAssertEqual(classification.statusLabel, "Awaiting review")
        XCTAssertFalse(classification.canUpdateBranch)
    }

    func testBehindBranchDoesNotBypassMergeConflict() {
        let classification = classify(
            details: details(mergeable: false, mergeableState: "dirty"),
            mergeReadiness: readiness(
                reviewDecision: "APPROVED",
                mergeStateStatus: "BEHIND",
                mergeable: "CONFLICTING"
            ),
            pipeline: successfulPipeline()
        )

        XCTAssertEqual(classification.group, .blocked)
        XCTAssertEqual(classification.reason, "Merge conflict")
        XCTAssertEqual(classification.statusLabel, "Your turn")
        XCTAssertFalse(classification.canUpdateBranch)
    }

    func testUnknownMergeStateIsTestingNotReady() {
        let classification = classify(
            mergeReadiness: readiness(
                reviewDecision: "APPROVED",
                mergeStateStatus: "UNKNOWN"
            ),
            pipeline: successfulPipeline()
        )

        XCTAssertEqual(classification.group, .testing)
        XCTAssertEqual(classification.reason, "Mergeability pending")
        XCTAssertEqual(classification.statusLabel, "Checking mergeability")
        XCTAssertFalse(classification.needsUserAction)
    }

    func testUnknownMergeableStateIsTestingNotReady() {
        let classification = classify(
            mergeReadiness: readiness(
                reviewDecision: "APPROVED",
                mergeStateStatus: nil,
                mergeable: "UNKNOWN"
            ),
            pipeline: successfulPipeline()
        )

        XCTAssertEqual(classification.group, .testing)
        XCTAssertEqual(classification.reason, "Mergeability pending")
        XCTAssertEqual(classification.statusLabel, "Checking mergeability")
    }

    func testHasHooksMergeStateCanBeReadyWhenApprovedAndGreen() {
        let classification = classify(
            mergeReadiness: readiness(
                reviewDecision: "APPROVED",
                mergeStateStatus: "HAS_HOOKS"
            ),
            pipeline: successfulPipeline()
        )

        XCTAssertEqual(classification.group, .ready)
        XCTAssertEqual(classification.reason, "Approved and green")
    }

    func testUnstableMergeStateIsBlockedWhenNoConcreteCheckFailureIsAvailable() {
        let classification = classify(
            mergeReadiness: readiness(
                reviewDecision: "APPROVED",
                mergeStateStatus: "UNSTABLE"
            ),
            pipeline: pipeline()
        )

        XCTAssertEqual(classification.group, .blocked)
        XCTAssertEqual(classification.reason, "CI failed")
        XCTAssertEqual(classification.statusLabel, "Your turn")
    }

    func testCombinedStatusPendingIsTesting() {
        let classification = classify(
            mergeReadiness: readiness(
                reviewDecision: "APPROVED",
                mergeStateStatus: "BLOCKED"
            ),
            pipeline: pipeline(combinedState: "pending")
        )

        XCTAssertEqual(classification.group, .testing)
        XCTAssertEqual(classification.reason, "Checks running")
        XCTAssertEqual(classification.statusLabel, "Checks running")
    }

    func testCombinedStatusExpectedIsTesting() {
        let classification = classify(
            mergeReadiness: readiness(
                reviewDecision: "APPROVED",
                mergeStateStatus: "BLOCKED"
            ),
            pipeline: pipeline(combinedState: "expected")
        )

        XCTAssertEqual(classification.group, .testing)
        XCTAssertEqual(classification.reason, "Checks running")
        XCTAssertEqual(classification.statusLabel, "Checks running")
    }

    func testCombinedStatusFailureIsBlockedBeforeGenericBlockedState() {
        let classification = classify(
            mergeReadiness: readiness(
                reviewDecision: "APPROVED",
                mergeStateStatus: "BLOCKED"
            ),
            pipeline: pipeline(combinedState: "failure")
        )

        XCTAssertEqual(classification.group, .blocked)
        XCTAssertEqual(classification.reason, "CI failed")
        XCTAssertEqual(classification.statusLabel, "Your turn")
    }

    func testFailingRollupBlocksWhenNoPendingRollupIsAvailable() {
        let classification = classify(
            mergeReadiness: readiness(
                reviewDecision: "APPROVED",
                mergeStateStatus: "CLEAN",
                statusCheckRollupState: "FAILURE"
            ),
            pipeline: pipeline()
        )

        XCTAssertEqual(classification.group, .blocked)
        XCTAssertEqual(classification.reason, "CI failed")
        XCTAssertEqual(classification.statusLabel, "Your turn")
    }

    func testChangesRequestedWinsOverFallbackReviewState() {
        let classification = classify(
            reviews: [
                review(state: "APPROVED", user: "reviewer-a", submittedAt: Date(timeIntervalSince1970: 1)),
                review(state: "CHANGES_REQUESTED", user: "reviewer-b", submittedAt: Date(timeIntervalSince1970: 2))
            ],
            mergeReadiness: nil,
            pipeline: successfulPipeline()
        )

        XCTAssertEqual(classification.group, .blocked)
        XCTAssertEqual(classification.reason, "Changes requested")
        XCTAssertEqual(classification.statusLabel, "Your turn")
    }

    func testApprovedCleanGreenPullRequestIsReady() {
        let classification = classify(
            mergeReadiness: readiness(
                reviewDecision: "APPROVED",
                mergeStateStatus: "CLEAN"
            ),
            pipeline: successfulPipeline()
        )

        XCTAssertEqual(classification.group, .ready)
        XCTAssertEqual(classification.reason, "Approved and green")
        XCTAssertEqual(classification.statusLabel, "Ready to merge")
        XCTAssertTrue(classification.needsUserAction)
    }

    func testDraftPullRequestIsBlockedAndNeedsAuthorAction() {
        let classification = classify(
            details: details(draft: true),
            mergeReadiness: readiness(
                reviewDecision: nil,
                mergeStateStatus: "DRAFT"
            ),
            pipeline: pipeline()
        )

        XCTAssertEqual(classification.group, .blocked)
        XCTAssertEqual(classification.reason, "Draft PR")
        XCTAssertEqual(classification.statusLabel, "Your turn")
        XCTAssertTrue(classification.needsUserAction)
    }

    func testMergeConflictIsBlockedAndNeedsAuthorAction() {
        let classification = classify(
            details: details(mergeable: false, mergeableState: "dirty"),
            mergeReadiness: readiness(
                reviewDecision: "APPROVED",
                mergeStateStatus: "DIRTY",
                mergeable: "CONFLICTING"
            ),
            pipeline: successfulPipeline()
        )

        XCTAssertEqual(classification.group, .blocked)
        XCTAssertEqual(classification.reason, "Merge conflict")
        XCTAssertEqual(classification.statusLabel, "Your turn")
        XCTAssertTrue(classification.needsUserAction)
    }

    func testReviewRequiredWinsOverGenericBlockedMergeState() {
        let classification = classify(
            mergeReadiness: readiness(
                reviewDecision: "REVIEW_REQUIRED",
                mergeStateStatus: "BLOCKED"
            ),
            pipeline: pipeline()
        )

        XCTAssertEqual(classification.group, .waiting)
        XCTAssertEqual(classification.reason, "Waiting for review")
        XCTAssertEqual(classification.statusLabel, "Awaiting review")
        XCTAssertFalse(classification.canUpdateBranch)
    }

    func testRequestedReviewerStaysWaitingAndNeedsUserActionWhenMergeStateIsBlocked() {
        let classification = classify(
            details: details(author: "teammate", requestedReviewers: [currentLogin]),
            mergeReadiness: readiness(
                reviewDecision: "REVIEW_REQUIRED",
                mergeStateStatus: "BLOCKED"
            ),
            pipeline: pipeline()
        )

        XCTAssertEqual(classification.group, .waiting)
        XCTAssertEqual(classification.reason, "Review requested")
        XCTAssertEqual(classification.statusLabel, "Your review")
        XCTAssertTrue(classification.needsUserAction)
    }

    func testRequestedReviewerWithGreenChecksIsWaitingForYourReview() {
        let classification = classify(
            details: details(author: "dependabot[bot]", requestedReviewers: [currentLogin]),
            mergeReadiness: readiness(
                reviewDecision: "REVIEW_REQUIRED",
                mergeStateStatus: "BLOCKED",
                statusCheckRollupState: "SUCCESS"
            ),
            pipeline: successfulPipeline()
        )

        XCTAssertEqual(classification.group, .waiting)
        XCTAssertEqual(classification.reason, "Review requested")
        XCTAssertEqual(classification.statusLabel, "Your review")
        XCTAssertTrue(classification.needsUserAction)
    }

    func testCleanPullRequestWaitsForMaintainerWhenViewerCannotMerge() {
        let classification = classify(
            mergeReadiness: readiness(
                reviewDecision: nil,
                mergeStateStatus: "CLEAN",
                viewerPermission: "READ"
            ),
            pipeline: successfulPipeline()
        )

        XCTAssertEqual(classification.group, .waiting)
        XCTAssertEqual(classification.reason, "Waiting for maintainer")
        XCTAssertFalse(classification.needsUserAction)
        XCTAssertFalse(classification.canMergeAsAdmin)
    }

    func testCleanPullRequestIsReadyWhenViewerCanWrite() {
        let classification = classify(
            mergeReadiness: readiness(
                reviewDecision: "APPROVED",
                mergeStateStatus: "CLEAN",
                viewerPermission: "WRITE"
            ),
            pipeline: successfulPipeline()
        )

        XCTAssertEqual(classification.group, .ready)
        XCTAssertFalse(classification.canMergeAsAdmin)
    }

    func testAdminCanBypassRequiredReview() {
        let classification = classify(
            mergeReadiness: readiness(
                reviewDecision: "REVIEW_REQUIRED",
                mergeStateStatus: "BLOCKED",
                viewerPermission: "ADMIN",
                viewerCanMergeAsAdmin: true
            ),
            pipeline: successfulPipeline()
        )

        XCTAssertEqual(classification.group, .waiting)
        XCTAssertEqual(classification.reason, "Waiting for review")
        XCTAssertTrue(classification.canMergeAsAdmin)
    }

    func testAdminCanBypassGenericBranchProtection() {
        let classification = classify(
            mergeReadiness: readiness(
                reviewDecision: "APPROVED",
                mergeStateStatus: "BLOCKED",
                viewerPermission: "ADMIN",
                viewerCanMergeAsAdmin: true
            ),
            pipeline: successfulPipeline()
        )

        XCTAssertEqual(classification.group, .blocked)
        XCTAssertEqual(classification.reason, "Blocked by GitHub")
        XCTAssertTrue(classification.canMergeAsAdmin)
    }

    func testAdminBypassIsNotOfferedWhenChangesAreRequested() {
        let classification = classify(
            mergeReadiness: readiness(
                reviewDecision: "CHANGES_REQUESTED",
                mergeStateStatus: "BLOCKED",
                viewerPermission: "ADMIN",
                viewerCanMergeAsAdmin: true
            ),
            pipeline: successfulPipeline()
        )

        XCTAssertEqual(classification.group, .blocked)
        XCTAssertFalse(classification.canMergeAsAdmin)
    }

    func testAdminBypassIsNotOfferedWhenChecksFail() {
        let classification = classify(
            mergeReadiness: readiness(
                reviewDecision: "APPROVED",
                mergeStateStatus: "UNSTABLE",
                viewerPermission: "ADMIN",
                viewerCanMergeAsAdmin: true
            ),
            pipeline: pipeline()
        )

        XCTAssertEqual(classification.group, .blocked)
        XCTAssertEqual(classification.reason, "CI failed")
        XCTAssertFalse(classification.canMergeAsAdmin)
    }

    private func classify(
        details: GitHubPullRequestDetails? = nil,
        reviews: [GitHubPullRequestReview] = [],
        mergeReadiness: GitHubPullRequestMergeReadiness?,
        pipeline: GitHubPipelineState
    ) -> PullRequestClassification {
        let classification = service.classify(
            details: details ?? self.details(),
            reviews: reviews,
            mergeReadiness: mergeReadiness,
            pipeline: pipeline,
            currentLogin: currentLogin
        )

        XCTAssertNotNil(classification)
        return classification!
    }

    private func details(
        author: String = "example-user",
        requestedReviewers: [String] = [],
        draft: Bool = false,
        mergeable: Bool? = true,
        mergeableState: String? = "clean"
    ) -> GitHubPullRequestDetails {
        GitHubPullRequestDetails(
            id: 42,
            number: 42,
            title: "Add example preferences",
            state: "open",
            draft: draft,
            htmlURL: URL(string: "https://github.com/example-owner/example-repo/pull/42")!,
            mergeable: mergeable,
            mergeableState: mergeableState,
            user: GitHubUser(login: author),
            head: GitHubPullRequestHead(
                sha: "0123456789abcdef0123456789abcdef01234567",
                repo: GitHubRepository(
                    fullName: "example-owner/example-repo",
                    name: "example-repo",
                    archived: false
                )
            ),
            requestedReviewers: requestedReviewers.map { GitHubUser(login: $0) }
        )
    }

    private func review(state: String, user: String, submittedAt: Date) -> GitHubPullRequestReview {
        GitHubPullRequestReview(
            state: state,
            user: GitHubUser(login: user),
            submittedAt: submittedAt
        )
    }

    private func readiness(
        reviewDecision: String?,
        mergeStateStatus: String?,
        mergeable: String? = "MERGEABLE",
        statusCheckRollupState: String? = nil,
        viewerPermission: String? = nil,
        viewerCanMergeAsAdmin: Bool? = nil
    ) -> GitHubPullRequestMergeReadiness {
        GitHubPullRequestMergeReadiness(
            reviewDecision: reviewDecision,
            mergeStateStatus: mergeStateStatus,
            mergeable: mergeable,
            statusCheckRollupState: statusCheckRollupState,
            viewerPermission: viewerPermission,
            viewerCanMergeAsAdmin: viewerCanMergeAsAdmin
        )
    }

    private func successfulPipeline() -> GitHubPipelineState {
        pipeline(
            checkRuns: [
                GitHubCheckRun(
                    name: "ci/woodpecker/pr/build",
                    status: "completed",
                    conclusion: "success"
                )
            ],
            combinedState: "success"
        )
    }

    private func pipeline(
        checkRuns: [GitHubCheckRun] = [],
        combinedState: String? = nil
    ) -> GitHubPipelineState {
        GitHubPipelineState(
            checkRuns: GitHubCheckRunsResponse(
                totalCount: checkRuns.count,
                checkRuns: checkRuns
            ),
            combinedStatus: combinedState.map {
                GitHubCombinedStatusResponse(
                    state: $0,
                    statuses: [GitHubCommitStatus(state: $0)]
                )
            }
        )
    }
}
