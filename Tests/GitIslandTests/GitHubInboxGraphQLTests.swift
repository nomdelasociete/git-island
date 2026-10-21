import Foundation
import XCTest
@testable import GitIsland

final class GitHubInboxGraphQLTests: XCTestCase {
    private let service = GitHubPullRequestService()
    private let currentLogin = "example-user"
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testSearchQueriesMatchRestScopeWithoutRepositoryFilter() {
        XCTAssertEqual(
            GitHubPullRequestService.graphQLInboxSearchQueries(for: currentLogin, repositoryFullNames: nil),
            [
                "is:pr is:open archived:false author:example-user",
                "is:pr is:open archived:false review-requested:example-user -draft:true"
            ]
        )
    }

    func testSearchQueriesPackRepositoriesUnderSearchLengthLimit() {
        let repositories = (0..<30).map { "example-owner/repository-\($0)" }
        let queries = GitHubPullRequestService.graphQLInboxSearchQueries(
            for: currentLogin,
            repositoryFullNames: repositories
        )

        XCTAssertGreaterThan(queries.count, 2)
        XCTAssertTrue(queries.allSatisfy { $0.count <= 256 })
        for repository in repositories {
            XCTAssertEqual(queries.filter { $0.contains(" repo:\(repository) ") || $0.hasSuffix(" repo:\(repository)") }.count, 2)
        }
    }

    func testQueryDeclaresOneVariablePerSearch() {
        let query = GitHubPullRequestService.graphQLInboxQuery(searchCount: 2)

        XCTAssertTrue(query.contains("query Inbox($q0: String!, $q1: String!)"))
        XCTAssertTrue(query.contains("s1: search(query: $q1"))
        XCTAssertFalse(query.contains("$q2"))
    }

    func testInboxResponseDecodesAndClassifiesLikeRestPath() throws {
        let data = try decode(Self.inboxResponse)
        XCTAssertTrue(data.isComplete)

        let pullRequests = service.inboxPullRequests(from: data, currentLogin: currentLogin, now: now)
        let byNumber = Dictionary(uniqueKeysWithValues: pullRequests.map { ($0.number, $0) })

        XCTAssertEqual(pullRequests.count, 4, "The PR returned by both searches is listed once")

        let readOnly = try XCTUnwrap(byNumber[1])
        XCTAssertEqual(readOnly.id, 1001)
        XCTAssertEqual(readOnly.repositoryFullName, "upstream/tool")
        XCTAssertEqual(readOnly.group, .waiting)
        XCTAssertEqual(readOnly.reason, "Waiting for maintainer")
        XCTAssertNil(readOnly.defaultMergeMethod)
        XCTAssertEqual(readOnly.age, "1h")

        let draft = try XCTUnwrap(byNumber[2])
        XCTAssertEqual(draft.group, .blocked)
        XCTAssertEqual(draft.reason, "Draft PR")

        let statusFailure = try XCTUnwrap(byNumber[3])
        XCTAssertEqual(statusFailure.group, .blocked)
        XCTAssertEqual(statusFailure.reason, "CI failed")

        let reviewRequested = try XCTUnwrap(byNumber[4])
        XCTAssertEqual(reviewRequested.group, .ready)
        XCTAssertEqual(reviewRequested.defaultMergeMethod, .squash)
        XCTAssertTrue(reviewRequested.needsUserAction)
    }

    func testTruncatedCheckContextsAreIncomplete() throws {
        let truncated = Self.pullRequest(
            id: 1005,
            number: 5,
            repository: "team/app",
            permission: "ADMIN",
            contextsTotalCount: 51,
            contexts: Self.successfulCheck
        )
        let data = try decode(#"{"s0": {"issueCount": 1, "nodes": ["# + truncated + "]}}")

        XCTAssertFalse(data.isComplete)
    }

    func testTruncatedSearchIsIncomplete() throws {
        let data = try decode(#"{"s0": {"issueCount": 101, "nodes": []}}"#)

        XCTAssertFalse(data.isComplete)
    }

    private func decode(_ json: String) throws -> GitHubInboxGraphQLData {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubInboxGraphQLData.self, from: Data(json.utf8))
    }

    private static func pullRequest(
        id: Int,
        number: Int,
        repository: String,
        permission: String,
        isDraft: Bool = false,
        author: String = "example-user",
        reviewDecision: String = "null",
        mergeStateStatus: String = "CLEAN",
        contextsTotalCount: Int? = nil,
        contexts: String = "[]",
        reviewRequests: String = "[]"
    ) -> String {
        """
        {
          "databaseId": \(id),
          "number": \(number),
          "title": "PR \(number)",
          "url": "https://github.com/\(repository)/pull/\(number)",
          "state": "OPEN",
          "isDraft": \(isDraft),
          "updatedAt": "2026-09-21T13:13:20Z",
          "author": { "login": "\(author)" },
          "headRefOid": "abc\(number)",
          "repository": {
            "nameWithOwner": "\(repository)",
            "name": "\(repository.split(separator: "/").last!)",
            "isArchived": false,
            "viewerPermission": "\(permission)",
            "viewerDefaultMergeMethod": "SQUASH"
          },
          "reviewDecision": \(reviewDecision),
          "mergeStateStatus": "\(mergeStateStatus)",
          "mergeable": "MERGEABLE",
          "viewerCanMergeAsAdmin": false,
          "reviewRequests": { "nodes": \(reviewRequests) },
          "reviews": { "nodes": [] },
          "commits": {
            "nodes": [
              {
                "commit": {
                  "statusCheckRollup": { "state": null, "contexts": { "totalCount": \(contextsTotalCount.map(String.init) ?? "null"), "nodes": \(contexts) } }
                }
              }
            ]
          }
        }
        """
    }

    private static let successfulCheck = #"[{ "__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS" }]"#

    private static var inboxResponse: String {
        let readOnly = pullRequest(id: 1001, number: 1, repository: "upstream/tool", permission: "READ", contexts: successfulCheck)
        let draft = pullRequest(id: 1002, number: 2, repository: "team/app", permission: "ADMIN", isDraft: true)
        let statusFailure = pullRequest(
            id: 1003,
            number: 3,
            repository: "team/app",
            permission: "ADMIN",
            mergeStateStatus: "UNSTABLE",
            contexts: #"[{ "__typename": "StatusContext", "state": "SUCCESS" }, { "__typename": "StatusContext", "state": "FAILURE" }]"#
        )
        let reviewRequested = pullRequest(
            id: 1004,
            number: 4,
            repository: "team/app",
            permission: "WRITE",
            author: "teammate",
            reviewDecision: #""APPROVED""#,
            contexts: successfulCheck,
            reviewRequests: #"[ { "requestedReviewer": { "login": "example-user" } }, { "requestedReviewer": {} } ]"#
        )

        return """
        {
          "s0": { "issueCount": 3, "nodes": [\(readOnly), \(draft), \(statusFailure)] },
          "s1": { "issueCount": 2, "nodes": [\(reviewRequested), \(readOnly)] }
        }
        """
    }
}
