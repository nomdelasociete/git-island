import Foundation
import CryptoKit

actor GitHubPullRequestService {
    private let client: GitHubAPIClient

    static func uncachedSession() -> URLSession {
        GitHubTransport.session()
    }

    init(session: URLSession = GitHubPullRequestService.uncachedSession()) {
        client = GitHubAPIClient(session: session)
    }
    private let tokenProvider = GitHubTokenProvider()
    private var defaultMergeMethodCache: [String: PullRequestMergeMethod] = [:]

    // ETag + value cache for conditional GETs (304 Not Modified support)
    private var etagCache: [String: String] = [:]
    private var responseCache: [String: Any] = [:]
    private(set) var last304HitCount: Int = 0

    static func accountCacheKey(_ resource: String, token: String) -> String {
        let fingerprint = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        return fingerprint + ":" + resource
    }

    func reset304Count() {
        last304HitCount = 0
    }

    func fetchPullRequests(
        currentLogin preferredLogin: String? = nil,
        repositoryFullNames: [String]? = nil
    ) async throws -> [PullRequest] {
        let token = try tokenProvider.token()
        let repositoryFullNames = repositoryFullNames.map(Self.normalizedRepositoryFullNames)
        if repositoryFullNames?.isEmpty == true {
            return []
        }

        let currentLogin = try await currentLogin(preferredLogin, token: token)
        reset304Count()

        // Prefer the batch GraphQL path; fall back to REST whenever it cannot
        // return the complete inbox.
        if let pullRequests = try? await fetchPullRequestsViaGraphQL(
            currentLogin: currentLogin,
            repositoryFullNames: repositoryFullNames,
            token: token
        ) {
            return pullRequests
        }

        let candidates = try await fetchPullRequestInboxCandidates(
            currentLogin: currentLogin,
            repositoryFullNames: repositoryFullNames,
            token: token
        )

        return try await withThrowingTaskGroup(of: PullRequest?.self) { group in
            for candidate in candidates {
                group.addTask {
                    try await self.buildPullRequest(
                        from: candidate,
                        currentLogin: currentLogin,
                        token: token
                    )
                }
            }

            var pullRequests: [PullRequest] = []
            pullRequests.reserveCapacity(candidates.count)

            for try await pullRequest in group {
                if let pullRequest {
                    pullRequests.append(pullRequest)
                }
            }

            return pullRequests
        }
    }

    func fetchRepositories() async throws -> [String] {
        let token = try tokenProvider.token()
        var repositories: [GitHubRepository] = []
        var page = 1

        while true {
            var components = URLComponents(string: "https://api.github.com/user/repos")!
            components.queryItems = [
                URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member"),
                URLQueryItem(name: "visibility", value: "all"),
                URLQueryItem(name: "sort", value: "full_name"),
                URLQueryItem(name: "direction", value: "asc"),
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: String(page))
            ]

            let (pageRepositories, _): ([GitHubRepository], String?) = try await client.get(components.url!, token: token)
            repositories.append(contentsOf: pageRepositories.filter { $0.archived != true })

            guard pageRepositories.count == 100 else {
                break
            }

            page += 1
        }

        return Self.normalizedRepositoryFullNames(repositories.map(\.fullName))
    }

    /// Performs a GET with ETag conditional support. On 304 returns the previously cached value (if any).
    /// Updates caches on success. Falls back to unconditional fetch if no cache hit on 304.
    func getWithETag<T: Decodable>(_ url: URL, token: String) async throws -> T {
        let key = Self.accountCacheKey(url.absoluteString, token: token)
        let prevETag = etagCache[key]

        do {
            let (value, etag): (T, String?) = try await client.get(url, token: token, ifNoneMatch: prevETag)
            if let etag {
                etagCache[key] = etag
                responseCache[key] = value
            }
            return value
        } catch let error as GitHubServiceError where error.isNotModified {
            last304HitCount += 1
            if let etag = error.notModifiedETag {
                etagCache[key] = etag
            }
            if let cached = responseCache[key] as? T {
                return cached
            }
            // No cache hit on 304 — fall back to full fetch
            let (value, etag): (T, String?) = try await client.get(url, token: token, ifNoneMatch: nil)
            if let etag {
                etagCache[key] = etag
                responseCache[key] = value
            }
            return value
        }
    }

    func merge(_ pullRequest: PullRequest) async throws {
        guard let method = pullRequest.defaultMergeMethod else {
            throw GitHubServiceError.mergeUnavailable
        }

        let token = try tokenProvider.token()
        let url = URL(
            string: "https://api.github.com/repos/\(pullRequest.repositoryFullName)/pulls/\(pullRequest.number)/merge"
        )!
        let response: GitHubMergeResponse = try await client.put(
            url,
            token: token,
            body: GitHubMergeRequest(
                sha: pullRequest.headSHA,
                mergeMethod: method.rawValue
            )
        )

        guard response.merged else {
            throw GitHubServiceError.api(
                statusCode: 422,
                message: response.message,
                retryAfterDate: nil
            )
        }
    }

    func updateBranch(_ pullRequest: PullRequest) async throws {
        guard pullRequest.canUpdateBranch else {
            throw GitHubServiceError.branchUpdateUnavailable
        }

        let token = try tokenProvider.token()
        let url = URL(
            string: "https://api.github.com/repos/\(pullRequest.repositoryFullName)/pulls/\(pullRequest.number)/update-branch"
        )!
        let _: GitHubUpdateBranchResponse = try await client.put(
            url,
            token: token,
            body: GitHubUpdateBranchRequest(expectedHeadSHA: pullRequest.headSHA)
        )
    }

    private func fetchPullRequestInboxCandidates(
        currentLogin: String,
        repositoryFullNames: [String]?,
        token: String
    ) async throws -> [GitHubPullRequestCandidate] {
        var seenURLs = Set<URL>()
        var candidates: [GitHubPullRequestCandidate] = []

        let queries = Self.inboxCandidateQueries(for: currentLogin, repositoryFullNames: repositoryFullNames)
        let maxPages = 3  // up to 300 results per query type for robustness

        // Run searches (with pagination) concurrently
        try await withThrowingTaskGroup(of: [GitHubSearchIssue].self) { group in
            for query in queries {
                group.addTask {
                    var all: [GitHubSearchIssue] = []
                    for page in 1...maxPages {
                        let pageItems = try await self.searchPullRequests(query: query, token: token, page: page)
                        all.append(contentsOf: pageItems)
                        if pageItems.count < 100 { break }
                    }
                    return all
                }
            }

            for try await issues in group {
                for issue in issues {
                    guard let url = issue.pullRequest?.url, !seenURLs.contains(url) else {
                        continue
                    }

                    seenURLs.insert(url)
                    candidates.append(
                        GitHubPullRequestCandidate(
                            url: url,
                            repository: Self.repository(fromPullRequestAPIURL: url),
                            updatedAt: issue.updatedAt
                        )
                    )
                }
            }
        }

        return candidates
    }

    private func currentLogin(_ preferredLogin: String?, token: String) async throws -> String {
        if let preferredLogin, !preferredLogin.isEmpty {
            return preferredLogin
        }

        let currentUser: GitHubUser = try await getWithETag(
            URL(string: "https://api.github.com/user")!,
            token: token
        )
        return currentUser.login
    }

    /// Batch GraphQL fetch for the inbox: one request replaces the per-PR REST
    /// calls. Throws when it cannot return the complete inbox, so the caller
    /// falls back to the REST path.
    private func fetchPullRequestsViaGraphQL(currentLogin: String, repositoryFullNames: [String]?, token: String) async throws -> [PullRequest] {
        let searchQueries = Self.graphQLInboxSearchQueries(for: currentLogin, repositoryFullNames: repositoryFullNames)
        guard !searchQueries.isEmpty, searchQueries.count <= Self.maxGraphQLInboxSearches else {
            throw GitHubServiceError.invalidResponse
        }

        let request = GitHubGraphQLRequest(
            query: Self.graphQLInboxQuery(searchCount: searchQueries.count),
            variables: Dictionary(
                uniqueKeysWithValues: searchQueries.enumerated().map { ("q\($0.offset)", $0.element) }
            )
        )

        let response: GitHubGraphQLResponse<GitHubInboxGraphQLData> = try await client.post(
            URL(string: "https://api.github.com/graphql")!,
            token: token,
            body: request
        )

        guard response.errors?.isEmpty != false,
              let data = response.data,
              data.isComplete else {
            throw GitHubServiceError.invalidResponse
        }

        for pullRequest in data.pullRequests {
            if let repository = pullRequest.repository,
               let method = PullRequestMergeMethod.githubDefault(repository.viewerDefaultMergeMethod) {
                defaultMergeMethodCache[Self.accountCacheKey(repository.nameWithOwner, token: token)] = method
            }
        }

        return inboxPullRequests(from: data, currentLogin: currentLogin)
    }

    nonisolated func inboxPullRequests(
        from data: GitHubInboxGraphQLData,
        currentLogin: String,
        now: Date = Date()
    ) -> [PullRequest] {
        var seenIDs = Set<Int>()

        return data.pullRequests.compactMap { gqlPR -> PullRequest? in
            guard gqlPR.state == "OPEN",
                  gqlPR.repository?.isArchived != true,
                  seenIDs.insert(gqlPR.databaseId).inserted,
                  let repository = gqlPR.repository else {
                return nil
            }

            let restRepository = GitHubRepository(
                fullName: repository.nameWithOwner,
                name: repository.name,
                archived: repository.isArchived
            )
            let details = GitHubPullRequestDetails(
                id: gqlPR.databaseId,
                number: gqlPR.number,
                title: gqlPR.title,
                state: gqlPR.state.lowercased(),
                draft: gqlPR.isDraft,
                htmlURL: gqlPR.url,
                mergeable: gqlPR.restMergeable,
                mergeableState: gqlPR.mergeStateStatus,
                user: gqlPR.author ?? GitHubUser(login: ""),
                head: GitHubPullRequestHead(sha: gqlPR.headRefOid, repo: restRepository),
                requestedReviewers: gqlPR.requestedReviewerLogins.map { GitHubUser(login: $0) }
            )
            let reviews = (gqlPR.reviews?.nodes ?? []).compactMap { review -> GitHubPullRequestReview? in
                guard let review else {
                    return nil
                }

                return GitHubPullRequestReview(state: review.state, user: review.author, submittedAt: review.submittedAt)
            }
            let headCommit = gqlPR.commits?.nodes?.compactMap { $0?.commit }.last
            let readiness = GitHubPullRequestMergeReadiness(
                reviewDecision: gqlPR.reviewDecision,
                mergeStateStatus: gqlPR.mergeStateStatus,
                mergeable: gqlPR.mergeable,
                statusCheckRollupState: headCommit?.statusCheckRollup?.state,
                viewerPermission: repository.viewerPermission,
                viewerCanMergeAsAdmin: gqlPR.viewerCanMergeAsAdmin
            )

            guard let classification = classify(
                details: details,
                reviews: reviews,
                mergeReadiness: readiness,
                pipeline: headCommit?.pipeline ?? GitHubPipelineState(checkRuns: nil, combinedStatus: nil),
                currentLogin: currentLogin
            ) else {
                return nil
            }

            let canMerge = classification.group == .ready || classification.canMergeAsAdmin

            return PullRequest(
                id: details.id,
                repository: repository.name,
                repositoryFullName: repository.nameWithOwner,
                number: details.number,
                title: details.title,
                group: classification.group,
                reason: classification.reason,
                statusLabel: classification.statusLabel,
                needsUserAction: classification.needsUserAction,
                age: Self.ageString(from: gqlPR.updatedAt, now: now),
                url: details.htmlURL,
                headSHA: details.head.sha,
                defaultMergeMethod: canMerge
                    ? PullRequestMergeMethod.githubDefault(repository.viewerDefaultMergeMethod)
                    : nil,
                canUpdateBranch: classification.canUpdateBranch,
                canMergeAsAdmin: classification.canMergeAsAdmin
            )
        }
    }

    private func searchPullRequests(query: String, token: String, page: Int = 1) async throws -> [GitHubSearchIssue] {
        var components = URLComponents(string: "https://api.github.com/search/issues")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "order", value: "desc")
        ]

        let response: GitHubSearchIssuesResponse = try await getWithETag(components.url!, token: token)
        return response.items
    }

    private func buildPullRequest(
        from candidate: GitHubPullRequestCandidate,
        currentLogin: String,
        token: String
    ) async throws -> PullRequest? {
        let details: GitHubPullRequestDetails = try await getWithETag(candidate.url, token: token)

        guard details.state == "open" else {
            return nil
        }

        if let classification = earlyClassification(details: details, currentLogin: currentLogin) {
            return await makePullRequest(
                details: details,
                candidate: candidate,
                classification: classification,
                token: token
            )
        }

        async let reviews = fetchReviews(for: candidate, token: token)
        async let mergeReadiness = fetchMergeReadiness(for: details, repository: candidate.repository, token: token)
        async let pipeline = fetchPipelineState(for: details, fallbackRepository: candidate.repository, token: token)

        guard let classification = classify(
            details: details,
            reviews: await reviews,
            mergeReadiness: await mergeReadiness,
            pipeline: await pipeline,
            currentLogin: currentLogin
        ) else {
            return nil
        }

        return await makePullRequest(
            details: details,
            candidate: candidate,
            classification: classification,
            token: token
        )
    }

    private func fetchReviews(
        for candidate: GitHubPullRequestCandidate,
        token: String
    ) async -> [GitHubPullRequestReview] {
        let reviewsURL = candidate.url.appendingPathComponent("reviews")
        return (try? await getWithETag(reviewsURL, token: token) as [GitHubPullRequestReview]) ?? []
    }

    private func makePullRequest(
        details: GitHubPullRequestDetails,
        candidate: GitHubPullRequestCandidate,
        classification: PullRequestClassification,
        token: String
    ) async -> PullRequest {
        let defaultMergeMethod = classification.group == .ready || classification.canMergeAsAdmin
            ? await defaultMergeMethod(for: candidate.repository, token: token)
            : nil

        return PullRequest(
            id: details.id,
            repository: candidate.repository.name,
            repositoryFullName: candidate.repository.fullName,
            number: details.number,
            title: details.title,
            group: classification.group,
            reason: classification.reason,
            statusLabel: classification.statusLabel,
            needsUserAction: classification.needsUserAction,
            age: Self.ageString(from: candidate.updatedAt),
            url: details.htmlURL,
            headSHA: details.head.sha,
            defaultMergeMethod: defaultMergeMethod,
            canUpdateBranch: classification.canUpdateBranch,
            canMergeAsAdmin: classification.canMergeAsAdmin
        )
    }

    private func earlyClassification(
        details: GitHubPullRequestDetails,
        currentLogin: String
    ) -> PullRequestClassification? {
        let isAuthor = details.user.login == currentLogin

        if details.draft {
            return PullRequestClassification(
                group: .blocked,
                reason: "Draft PR",
                statusLabel: isAuthor ? "Your turn" : "Draft",
                needsUserAction: isAuthor
            )
        }

        if details.hasMergeConflict {
            return PullRequestClassification(
                group: .blocked,
                reason: "Merge conflict",
                statusLabel: isAuthor ? "Your turn" : "Conflict",
                needsUserAction: isAuthor
            )
        }

        return nil
    }

    private func defaultMergeMethod(
        for repository: GitHubRepository,
        token: String
    ) async -> PullRequestMergeMethod? {
        if let cachedMethod = defaultMergeMethodCache[Self.accountCacheKey(repository.fullName, token: token)] {
            return cachedMethod
        }

        guard let ownerAndName = Self.ownerAndName(from: repository.fullName) else {
            return nil
        }

        let request = GitHubGraphQLRequest(
            query: """
            query ViewerDefaultMergeMethod($owner: String!, $name: String!) {
              repository(owner: $owner, name: $name) {
                viewerDefaultMergeMethod
              }
            }
            """,
            variables: GitHubRepositoryGraphQLVariables(
                owner: ownerAndName.owner,
                name: ownerAndName.name
            )
        )

        do {
            let response: GitHubGraphQLResponse<GitHubViewerDefaultMergeMethodData> = try await client.post(
                URL(string: "https://api.github.com/graphql")!,
                token: token,
                body: request
            )
            guard let method = PullRequestMergeMethod.githubDefault(
                response.data?.repository?.viewerDefaultMergeMethod
            ) else {
                return nil
            }

            defaultMergeMethodCache[Self.accountCacheKey(repository.fullName, token: token)] = method
            return method
        } catch {
            return nil
        }
    }

    private func fetchMergeReadiness(
        for details: GitHubPullRequestDetails,
        repository: GitHubRepository,
        token: String
    ) async -> GitHubPullRequestMergeReadiness? {
        guard let ownerAndName = Self.ownerAndName(from: repository.fullName) else {
            return nil
        }

        let request = GitHubGraphQLRequest(
            query: """
            query PullRequestMergeReadiness($owner: String!, $name: String!, $number: Int!) {
              repository(owner: $owner, name: $name) {
                viewerPermission
                pullRequest(number: $number) {
                  reviewDecision
                  mergeStateStatus
                  mergeable
                  viewerCanMergeAsAdmin
                  reviews(last: 30) {
                    nodes {
                      state
                      author { login }
                      submittedAt
                    }
                  }
                  commits(last: 1) {
                    nodes {
                      commit {
                        statusCheckRollup {
                          state
                        }
                        checkSuites(first: 10) {
                          nodes {
                            checkRuns(first: 20) {
                              nodes {
                                name
                                status
                                conclusion
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
            """,
            variables: GitHubPullRequestGraphQLVariables(
                owner: ownerAndName.owner,
                name: ownerAndName.name,
                number: details.number
            )
        )

        do {
            let response: GitHubGraphQLResponse<GitHubPullRequestMergeReadinessData> = try await client.post(
                URL(string: "https://api.github.com/graphql")!,
                token: token,
                body: request
            )
            guard let repository = response.data?.repository,
                  var mergeReadiness = repository.pullRequest else {
                return nil
            }

            mergeReadiness.viewerPermission = repository.viewerPermission
            return mergeReadiness
        } catch {
            return nil
        }
    }

    private func fetchPipelineState(
        for details: GitHubPullRequestDetails,
        fallbackRepository: GitHubRepository,
        token: String
    ) async -> GitHubPipelineState {
        let fullName = details.head.repo?.fullName ?? fallbackRepository.fullName
        let sha = details.head.sha

        let checkRunsURL = URL(string: "https://api.github.com/repos/\(fullName)/commits/\(sha)/check-runs?per_page=100")!
        let statusURL = URL(string: "https://api.github.com/repos/\(fullName)/commits/\(sha)/status")!

        async let checkRuns: GitHubCheckRunsResponse? = try? getWithETag(checkRunsURL, token: token)
        async let status: GitHubCombinedStatusResponse? = try? getWithETag(statusURL, token: token)

        return await GitHubPipelineState(checkRuns: checkRuns, combinedStatus: status)
    }

    nonisolated func classify(
        details: GitHubPullRequestDetails,
        reviews: [GitHubPullRequestReview],
        mergeReadiness: GitHubPullRequestMergeReadiness?,
        pipeline: GitHubPipelineState,
        currentLogin: String
    ) -> PullRequestClassification? {
        let latestReviewStates = latestReviewStatesByUser(from: reviews)
        let hasBlockingReview = mergeReadiness.map(\.hasBlockingReview)
            ?? latestReviewStates.values.contains("CHANGES_REQUESTED")
        let hasApproval = mergeReadiness.map(\.hasApproval)
            ?? latestReviewStates.values.contains("APPROVED")
        let isAuthor = details.user.login == currentLogin
        let isRequestedReviewer = details.requestedReviewers.contains { $0.login == currentLogin }
        let pipelineFailureReason = pipeline.failureReason
        let pipelinePendingReason = pipeline.pendingReason
        let pipelineHasFreshConclusion = pipelineFailureReason != nil || pipeline.isSuccessful
        let canBypassProtectionAsAdmin = mergeReadiness?.canBypassProtectionAsAdmin == true

        if details.draft {
            return PullRequestClassification(
                group: .blocked,
                reason: "Draft PR",
                statusLabel: isAuthor ? "Your turn" : "Draft",
                needsUserAction: isAuthor
            )
        }

        if details.hasMergeConflict || mergeReadiness?.hasMergeConflict == true {
            return PullRequestClassification(
                group: .blocked,
                reason: "Merge conflict",
                statusLabel: isAuthor ? "Your turn" : "Conflict",
                needsUserAction: isAuthor
            )
        }

        if let failureReason = pipelineFailureReason {
            return PullRequestClassification(
                group: .blocked,
                reason: failureReason,
                statusLabel: isAuthor ? "Your turn" : "CI failed",
                needsUserAction: isAuthor
            )
        }

        if let pendingReason = pipelinePendingReason {
            return PullRequestClassification(
                group: .testing,
                reason: pendingReason,
                statusLabel: "Checks running",
                needsUserAction: false
            )
        }

        if mergeReadiness?.hasPendingStatusCheckRollup == true && !pipelineHasFreshConclusion {
            return PullRequestClassification(
                group: .testing,
                reason: "Checks running",
                statusLabel: "Checks running",
                needsUserAction: false
            )
        }

        if hasBlockingReview {
            return PullRequestClassification(
                group: .blocked,
                reason: "Changes requested",
                statusLabel: isAuthor ? "Your turn" : "Review needed",
                needsUserAction: isAuthor
            )
        }

        if mergeReadiness?.hasFailingStatusCheckRollup == true && !pipeline.isSuccessful {
            return PullRequestClassification(
                group: .blocked,
                reason: "CI failed",
                statusLabel: isAuthor ? "Your turn" : "CI failed",
                needsUserAction: isAuthor
            )
        }

        if mergeReadiness?.requiresReview == true {
            return PullRequestClassification(
                group: .waiting,
                reason: isRequestedReviewer ? "Review requested" : "Waiting for review",
                statusLabel: isRequestedReviewer ? "Your review" : "Awaiting review",
                needsUserAction: isRequestedReviewer,
                canMergeAsAdmin: canBypassProtectionAsAdmin
            )
        }

        if mergeReadiness?.isMergeabilityPending == true {
            return PullRequestClassification(
                group: .testing,
                reason: "Mergeability pending",
                statusLabel: "Checking mergeability",
                needsUserAction: false
            )
        }

        let onlyNeedsBranchUpdate = mergeReadiness?.isBehind == true
            && mergeReadiness?.requiresReview != true
            && mergeReadiness?.hasBlockingReview != true
            && mergeReadiness?.hasMergeConflict != true

        if onlyNeedsBranchUpdate {
            return PullRequestClassification(
                group: .ready,
                reason: "Branch behind",
                statusLabel: "Update branch",
                needsUserAction: isAuthor || isRequestedReviewer,
                canUpdateBranch: true
            )
        }

        if let blockedReason = mergeReadiness?.blockedReason {
            return PullRequestClassification(
                group: .blocked,
                reason: blockedReason,
                statusLabel: isAuthor ? "Your turn" : "Blocked",
                needsUserAction: isAuthor,
                canMergeAsAdmin: canBypassProtectionAsAdmin
            )
        }

        if isReadyToMerge(details: details, mergeReadiness: mergeReadiness, pipeline: pipeline, hasApproval: hasApproval) {
            if mergeReadiness?.viewerCanMerge == false {
                return PullRequestClassification(
                    group: .waiting,
                    reason: "Waiting for maintainer",
                    statusLabel: "Maintainer",
                    needsUserAction: false
                )
            }

            return PullRequestClassification(
                group: .ready,
                reason: hasApproval ? "Approved and green" : "Ready to merge",
                statusLabel: "Ready to merge",
                needsUserAction: isAuthor || isRequestedReviewer
            )
        }

        if isRequestedReviewer {
            return PullRequestClassification(
                group: .waiting,
                reason: "Review requested",
                statusLabel: "Your review",
                needsUserAction: true
            )
        }

        return PullRequestClassification(
            group: .waiting,
            reason: "Waiting for review",
            statusLabel: "Awaiting review",
            needsUserAction: false
        )
    }

    nonisolated private func isReadyToMerge(
        details: GitHubPullRequestDetails,
        mergeReadiness: GitHubPullRequestMergeReadiness?,
        pipeline: GitHubPipelineState,
        hasApproval: Bool
    ) -> Bool {
        if mergeReadiness?.isMergeabilityPending == true {
            return false
        }

        if mergeReadiness?.isReadyToMerge == true {
            return true
        }

        if details.hasCleanMergeState || details.hasMergeableWithoutKnownState {
            return pipeline.hasSignals ? pipeline.isSuccessful || hasApproval : true
        }

        return hasApproval && pipeline.isSuccessful
    }

    nonisolated private func latestReviewStatesByUser(from reviews: [GitHubPullRequestReview]) -> [String: String] {
        let sortedReviews = reviews.sorted { lhs, rhs in
            (lhs.submittedAt ?? .distantPast) < (rhs.submittedAt ?? .distantPast)
        }
        var statesByUser: [String: String] = [:]

        for review in sortedReviews {
            guard let login = review.user?.login else {
                continue
            }

            statesByUser[login] = review.state
        }

        return statesByUser
    }

    private static func ageString(from date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))

        if seconds < 60 {
            return "now"
        }

        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return "\(minutes)m"
        }

        let hours = Int(seconds / 3_600)
        if hours < 24 {
            return "\(hours)h"
        }

        let days = Int(seconds / 86_400)
        if days < 14 {
            return "\(days)d"
        }

        return "\(max(1, days / 7))w"
    }

    private static func inboxCandidateQueries(
        for login: String,
        repositoryFullNames: [String]?
    ) -> [String] {
        let openPullRequests = "is:pr is:open archived:false"
        let baseQueries = [
            "\(openPullRequests) author:\(login)",
            "\(openPullRequests) review-requested:\(login) -draft:true"
        ]

        guard let repositoryFullNames else {
            return baseQueries
        }

        return repositoryFullNames.flatMap { repositoryFullName in
            baseQueries.map { "\($0) repo:\(repositoryFullName)" }
        }
    }

    /// Search's limit on query length; longer queries are rejected.
    private static let maxSearchQueryLength = 256
    /// Keeps one inbox request cheap in GraphQL rate-limit points; a larger
    /// inbox falls back to REST.
    private static let maxGraphQLInboxSearches = 8
    static let graphQLInboxPageSize = 50
    static let graphQLCheckContextPageSize = 50

    /// Same scope as `inboxCandidateQueries`, but packs several `repo:`
    /// qualifiers (ORed by search) into each query.
    static func graphQLInboxSearchQueries(
        for login: String,
        repositoryFullNames: [String]?
    ) -> [String] {
        let openPullRequests = "is:pr is:open archived:false"
        let baseQueries = [
            "\(openPullRequests) author:\(login)",
            "\(openPullRequests) review-requested:\(login) -draft:true"
        ]

        guard let repositoryFullNames else {
            return baseQueries
        }

        return baseQueries.flatMap { baseQuery in
            var queries: [String] = []
            var current = baseQuery

            for repositoryFullName in repositoryFullNames {
                let qualifier = " repo:\(repositoryFullName)"
                if current != baseQuery,
                   current.count + qualifier.count > maxSearchQueryLength {
                    queries.append(current)
                    current = baseQuery
                }
                current += qualifier
            }

            queries.append(current)
            return queries
        }
    }

    static func graphQLInboxQuery(searchCount: Int) -> String {
        let variables = (0..<searchCount).map { "$q\($0): String!" }.joined(separator: ", ")
        let searches = (0..<searchCount).map { index in
            """
              s\(index): search(query: $q\(index), type: ISSUE, first: \(graphQLInboxPageSize)) {
                issueCount
                nodes {
                  ... on PullRequest {
                    ...InboxPullRequest
                  }
                }
              }
            """
        }.joined(separator: "\n")

        return """
        query Inbox(\(variables)) {
        \(searches)
        }
        fragment InboxPullRequest on PullRequest {
          databaseId
          number
          title
          url
          state
          isDraft
          updatedAt
          author { login }
          headRefOid
          repository {
            nameWithOwner
            name
            isArchived
            viewerPermission
            viewerDefaultMergeMethod
          }
          reviewDecision
          mergeStateStatus
          mergeable
          viewerCanMergeAsAdmin
          reviewRequests(first: 20) {
            nodes {
              requestedReviewer {
                ... on User { login }
              }
            }
          }
          reviews(last: 30) {
            nodes {
              state
              author { login }
              submittedAt
            }
          }
          commits(last: 1) {
            nodes {
              commit {
                statusCheckRollup {
                  state
                  contexts(first: \(graphQLCheckContextPageSize)) {
                    totalCount
                    nodes {
                      __typename
                      ... on CheckRun { name status conclusion }
                      ... on StatusContext { state }
                    }
                  }
                }
              }
            }
          }
        }
        """
    }

    private static func repository(fromPullRequestAPIURL url: URL) -> GitHubRepository {
        let components = url.pathComponents

        guard
            let reposIndex = components.firstIndex(of: "repos"),
            components.indices.contains(reposIndex + 2)
        else {
            return GitHubRepository(fullName: "unknown/unknown", name: "unknown", archived: nil)
        }

        let owner = components[reposIndex + 1]
        let name = components[reposIndex + 2]
        return GitHubRepository(fullName: "\(owner)/\(name)", name: name, archived: nil)
    }

    private static func ownerAndName(from fullName: String) -> (owner: String, name: String)? {
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return nil
        }

        return (owner: parts[0], name: parts[1])
    }

    private static func normalizedRepositoryFullNames(_ values: [String]) -> [String] {
        Array(Set(values.compactMap(UserPreferences.normalizedRepositoryFullName))).sorted()
    }
}

struct PullRequestClassification {
    let group: PullRequestGroup
    let reason: String
    let statusLabel: String
    let needsUserAction: Bool
    let canUpdateBranch: Bool
    let canMergeAsAdmin: Bool

    init(
        group: PullRequestGroup,
        reason: String,
        statusLabel: String,
        needsUserAction: Bool,
        canUpdateBranch: Bool = false,
        canMergeAsAdmin: Bool = false
    ) {
        self.group = group
        self.reason = reason
        self.statusLabel = statusLabel
        self.needsUserAction = needsUserAction
        self.canUpdateBranch = canUpdateBranch
        self.canMergeAsAdmin = canMergeAsAdmin
    }
}

private struct GitHubPullRequestCandidate {
    let url: URL
    let repository: GitHubRepository
    let updatedAt: Date
}

private struct GitHubGraphQLRequest<Variables: Encodable>: Encodable {
    let query: String
    let variables: Variables
}

private struct GitHubRepositoryGraphQLVariables: Encodable {
    let owner: String
    let name: String
}

private struct GitHubPullRequestGraphQLVariables: Encodable {
    let owner: String
    let name: String
    let number: Int
}

private struct GitHubGraphQLResponse<ResponseData: Decodable>: Decodable {
    let data: ResponseData?
    let errors: [GitHubGraphQLError]?
}

private struct GitHubGraphQLError: Decodable {
    let message: String?
}

struct GitHubInboxGraphQLData: Decodable {
    /// Search results keyed by alias (`s0`, `s1`, ...), in alias order.
    let searches: [GitHubGraphQLSearch]

    init(searches: [GitHubGraphQLSearch]) {
        self.searches = searches
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: GitHubGraphQLAliasKey.self)
        searches = try container.allKeys
            .sorted { $0.stringValue.localizedStandardCompare($1.stringValue) == .orderedAscending }
            .map { try container.decode(GitHubGraphQLSearch.self, forKey: $0) }
    }

    var pullRequests: [GitHubGraphQLPullRequest] {
        searches.flatMap { $0.nodes.compactMap { $0 } }
    }

    /// False when a search, or a PR's check contexts, spans more than one page.
    var isComplete: Bool {
        searches.allSatisfy { $0.issueCount <= $0.nodes.count }
            && pullRequests.allSatisfy(\.hasCompleteChecks)
    }
}

private struct GitHubGraphQLAliasKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}

struct GitHubGraphQLSearch: Decodable {
    let issueCount: Int
    let nodes: [GitHubGraphQLPullRequest?]
}

struct GitHubGraphQLPullRequest: Decodable {
    let databaseId: Int
    let number: Int
    let title: String
    let url: URL
    let state: String
    let isDraft: Bool
    let updatedAt: Date
    let author: GitHubUser?
    let headRefOid: String
    let repository: GitHubGraphQLRepository?
    let reviewDecision: String?
    let mergeStateStatus: String?
    let mergeable: String?
    let viewerCanMergeAsAdmin: Bool?
    let reviewRequests: GitHubGraphQLReviewRequestConnection?
    let reviews: GitHubGraphQLReviewConnection?
    let commits: GitHubGraphQLCommitConnection?

    /// REST's `mergeable`: nil while GitHub is still computing it.
    var restMergeable: Bool? {
        switch mergeable?.uppercased() {
        case "MERGEABLE":
            true
        case "CONFLICTING":
            false
        default:
            nil
        }
    }

    var hasCompleteChecks: Bool {
        let contexts = commits?.nodes?.compactMap { $0?.commit }.last?.statusCheckRollup?.contexts
        return (contexts?.totalCount ?? 0) <= (contexts?.nodes?.count ?? 0)
    }

    var requestedReviewerLogins: [String] {
        (reviewRequests?.nodes ?? []).compactMap { $0?.requestedReviewer?.login }
    }
}

struct GitHubGraphQLRepository: Decodable {
    let nameWithOwner: String
    let name: String
    let isArchived: Bool?
    let viewerPermission: String?
    let viewerDefaultMergeMethod: String?
}

struct GitHubGraphQLReviewRequestConnection: Decodable {
    let nodes: [GitHubGraphQLReviewRequest?]?
}

struct GitHubGraphQLReviewRequest: Decodable {
    /// Empty for team requests, which the `... on User` spread does not match.
    let requestedReviewer: GitHubGraphQLRequestedReviewer?
}

struct GitHubGraphQLRequestedReviewer: Decodable {
    let login: String?
}

struct GitHubGraphQLReviewConnection: Decodable {
    let nodes: [GitHubGraphQLReview?]?
}

struct GitHubGraphQLReview: Decodable {
    let state: String
    let author: GitHubUser?
    let submittedAt: Date?
}

struct GitHubGraphQLCommitConnection: Decodable {
    let nodes: [GitHubGraphQLCommitNode?]?
}

struct GitHubGraphQLCommitNode: Decodable {
    let commit: GitHubGraphQLCommit?
}

struct GitHubGraphQLCommit: Decodable {
    let statusCheckRollup: GitHubGraphQLStatusCheckRollup?

    /// The same signals the REST path reads from check runs and the combined
    /// status: the rollup lists the latest check run per name plus each commit
    /// status context.
    var pipeline: GitHubPipelineState {
        let contexts = (statusCheckRollup?.contexts?.nodes ?? []).compactMap { $0 }
        let checkRuns = contexts.compactMap { context -> GitHubCheckRun? in
            guard context.typename == "CheckRun",
                  let name = context.name,
                  let status = context.status else {
                return nil
            }

            return GitHubCheckRun(name: name, status: status, conclusion: context.conclusion)
        }
        let statuses = contexts.compactMap { context -> GitHubCommitStatus? in
            guard context.typename == "StatusContext", let state = context.state else {
                return nil
            }

            return GitHubCommitStatus(state: state)
        }

        return GitHubPipelineState(
            checkRuns: GitHubCheckRunsResponse(totalCount: checkRuns.count, checkRuns: checkRuns),
            combinedStatus: statuses.isEmpty
                ? nil
                : GitHubCombinedStatusResponse(state: Self.combinedState(of: statuses), statuses: statuses)
        )
    }

    /// GitHub's combined status: any error or failure fails, then any pending.
    private static func combinedState(of statuses: [GitHubCommitStatus]) -> String {
        let states = Set(statuses.map { $0.state.lowercased() })
        if !states.isDisjoint(with: ["error", "failure"]) {
            return "failure"
        }
        if !states.isDisjoint(with: ["expected", "pending"]) {
            return "pending"
        }
        return "success"
    }
}

struct GitHubGraphQLStatusCheckRollup: Decodable {
    let state: String?
    let contexts: GitHubGraphQLCheckContextConnection?
}

struct GitHubGraphQLCheckContextConnection: Decodable {
    let totalCount: Int?
    let nodes: [GitHubGraphQLCheckContext?]?
}

/// A `CheckRun` or a `StatusContext`, told apart by `__typename`.
struct GitHubGraphQLCheckContext: Decodable {
    let typename: String
    let name: String?
    let status: String?
    let conclusion: String?
    let state: String?

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case name
        case status
        case conclusion
        case state
    }
}

private struct GitHubViewerDefaultMergeMethodData: Decodable {
    let repository: GitHubViewerDefaultMergeMethodRepository?
}

private struct GitHubViewerDefaultMergeMethodRepository: Decodable {
    let viewerDefaultMergeMethod: String?
}

private struct GitHubPullRequestMergeReadinessData: Decodable {
    let repository: GitHubPullRequestMergeReadinessRepository?
}

private struct GitHubPullRequestMergeReadinessRepository: Decodable {
    let viewerPermission: String?
    let pullRequest: GitHubPullRequestMergeReadiness?
}

struct GitHubPullRequestMergeReadiness: Decodable {
    let reviewDecision: String?
    let mergeStateStatus: String?
    let mergeable: String?
    let statusCheckRollupState: String?
    let viewerCanMergeAsAdmin: Bool?
    /// Repository-level permission; filled in from the enclosing repository node.
    var viewerPermission: String?

    init(
        reviewDecision: String?,
        mergeStateStatus: String?,
        mergeable: String?,
        statusCheckRollupState: String? = nil,
        viewerPermission: String? = nil,
        viewerCanMergeAsAdmin: Bool? = nil
    ) {
        self.reviewDecision = reviewDecision
        self.mergeStateStatus = mergeStateStatus
        self.mergeable = mergeable
        self.statusCheckRollupState = statusCheckRollupState
        self.viewerPermission = viewerPermission
        self.viewerCanMergeAsAdmin = viewerCanMergeAsAdmin
    }

    private enum CodingKeys: String, CodingKey {
        case reviewDecision
        case mergeStateStatus
        case mergeable
        case viewerCanMergeAsAdmin
        case commits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reviewDecision = try container.decodeIfPresent(String.self, forKey: .reviewDecision)
        mergeStateStatus = try container.decodeIfPresent(String.self, forKey: .mergeStateStatus)
        mergeable = try container.decodeIfPresent(String.self, forKey: .mergeable)
        viewerCanMergeAsAdmin = try container.decodeIfPresent(Bool.self, forKey: .viewerCanMergeAsAdmin)

        let commits = try container.decodeIfPresent(GitHubPullRequestCommitConnection.self, forKey: .commits)
        statusCheckRollupState = commits?.latestStatusCheckRollupState
    }

    var requiresReview: Bool {
        normalizedReviewDecision == "REVIEW_REQUIRED"
    }

    var hasBlockingReview: Bool {
        normalizedReviewDecision == "CHANGES_REQUESTED"
    }

    var hasApproval: Bool {
        normalizedReviewDecision == "APPROVED"
    }

    var hasMergeConflict: Bool {
        normalizedMergeStateStatus == "DIRTY" || normalizedMergeable == "CONFLICTING"
    }

    var isBehind: Bool {
        normalizedMergeStateStatus == "BEHIND"
    }

    /// A missing permission means the query could not tell, so keep the
    /// previous behaviour and let GitHub reject the merge if needed.
    var viewerCanMerge: Bool {
        guard let permission = normalized(viewerPermission) else {
            return true
        }

        return ["ADMIN", "MAINTAIN", "WRITE"].contains(permission)
    }

    /// Only branch protection stands in the way, and the viewer may override it.
    var canBypassProtectionAsAdmin: Bool {
        viewerCanMergeAsAdmin == true && normalizedMergeStateStatus == "BLOCKED" && !hasBlockingReview
    }

    var isMergeabilityPending: Bool {
        normalizedMergeStateStatus == "UNKNOWN" || normalizedMergeable == "UNKNOWN"
    }

    var hasPendingStatusCheckRollup: Bool {
        ["EXPECTED", "PENDING"].contains(normalizedStatusCheckRollupState)
    }

    var hasFailingStatusCheckRollup: Bool {
        ["ERROR", "FAILURE"].contains(normalizedStatusCheckRollupState)
    }

    var isReadyToMerge: Bool {
        guard !requiresReview, !hasBlockingReview, !hasMergeConflict, !isMergeabilityPending, blockedReason == nil else {
            return false
        }

        if let normalizedMergeStateStatus,
           ["CLEAN", "HAS_HOOKS"].contains(normalizedMergeStateStatus) {
            return true
        }

        return normalizedMergeable == "MERGEABLE" && normalizedMergeStateStatus == nil
    }

    var blockedReason: String? {
        switch normalizedMergeStateStatus {
        case "BEHIND":
            "Branch behind"
        case "BLOCKED":
            requiresReview ? nil : "Blocked by GitHub"
        case "DRAFT":
            "Draft PR"
        case "DIRTY":
            "Merge conflict"
        case "UNSTABLE":
            "CI failed"
        default:
            nil
        }
    }

    private var normalizedReviewDecision: String? {
        normalized(reviewDecision)
    }

    private var normalizedMergeStateStatus: String? {
        normalized(mergeStateStatus)
    }

    private var normalizedMergeable: String? {
        normalized(mergeable)
    }

    private var normalizedStatusCheckRollupState: String? {
        normalized(statusCheckRollupState)
    }

    private func normalized(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }

        return value.uppercased()
    }
}

private struct GitHubPullRequestCommitConnection: Decodable {
    let nodes: [GitHubPullRequestCommitNode?]?

    var latestStatusCheckRollupState: String? {
        nodes?
            .compactMap { $0?.commit?.statusCheckRollup?.state }
            .last
    }
}

private struct GitHubPullRequestCommitNode: Decodable {
    let commit: GitHubPullRequestCommit?
}

private struct GitHubPullRequestCommit: Decodable {
    let statusCheckRollup: GitHubStatusCheckRollup?
}

private struct GitHubStatusCheckRollup: Decodable {
    let state: String
}

private struct GitHubMergeRequest: Encodable {
    let sha: String
    let mergeMethod: String

    private enum CodingKeys: String, CodingKey {
        case sha
        case mergeMethod = "merge_method"
    }
}

private struct GitHubMergeResponse: Decodable {
    let merged: Bool
    let message: String
}

private struct GitHubUpdateBranchRequest: Encodable {
    let expectedHeadSHA: String

    private enum CodingKeys: String, CodingKey {
        case expectedHeadSHA = "expected_head_sha"
    }
}

private struct GitHubUpdateBranchResponse: Decodable {
    let message: String?
}

struct GitHubPipelineState {
    let checkRuns: GitHubCheckRunsResponse?
    let combinedStatus: GitHubCombinedStatusResponse?

    var hasSignals: Bool {
        (checkRuns?.totalCount ?? 0) > 0 || combinedStatus?.statuses.isEmpty == false
    }

    var pendingReason: String? {
        if let pendingCheck = checkRuns?.checkRuns.first(where: { $0.isPending }) {
            return "\(pendingCheck.name) running"
        }

        if let combinedStatus,
           !combinedStatus.statuses.isEmpty,
           combinedStatus.isPending {
            return "Checks running"
        }

        return nil
    }

    var isSuccessful: Bool {
        let checkRunsAreSuccessful = (checkRuns?.totalCount ?? 0) > 0
            && checkRuns?.checkRuns.allSatisfy(\.isSuccessful) == true
        let statusesAreSuccessful = combinedStatus?.statuses.isEmpty == false
            && combinedStatus?.isSuccessful == true

        return checkRunsAreSuccessful || statusesAreSuccessful
    }

    var failureReason: String? {
        if let failingCheck = checkRuns?.checkRuns.first(where: { $0.isFailing }) {
            return "\(failingCheck.name) failed"
        }

        if let combinedStatus,
           !combinedStatus.statuses.isEmpty,
           combinedStatus.isFailing {
            return "CI failed"
        }

        return nil
    }
}

private struct GitHubAPIClient {
    let session: URLSession
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)

            if let date = GitHubDateParser.date(from: string) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid GitHub date: \(string)"
            )
        }
        return decoder
    }()

    func get<T: Decodable>(_ url: URL, token: String, ifNoneMatch: String? = nil) async throws -> (value: T, etag: String?) {
        var req = try Self.request(url: url, method: "GET", token: token)
        if let etag = ifNoneMatch {
            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        return try await send(req)
    }

    func post<Body: Encodable, T: Decodable>(_ url: URL, token: String, body: Body) async throws -> T {
        var request = try Self.request(url: url, method: "POST", token: token)
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (value, _): (T, String?) = try await send(request)
        return value
    }

    func put<Body: Encodable, T: Decodable>(_ url: URL, token: String, body: Body) async throws -> T {
        var request = try Self.request(url: url, method: "PUT", token: token)
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (value, _): (T, String?) = try await send(request)
        return value
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> (value: T, etag: String?) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubServiceError.invalidResponse
        }

        if httpResponse.statusCode == 304 {
            let etag = Self.headerValue("ETag", in: httpResponse)
            throw GitHubServiceError.notModified(etag: etag)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = try? decoder.decode(GitHubErrorResponse.self, from: data)
            throw GitHubServiceError.api(
                statusCode: httpResponse.statusCode,
                message: apiError?.message ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
                retryAfterDate: Self.retryAfterDate(from: httpResponse)
            )
        }

        let value = try decoder.decode(T.self, from: data)
        let etag = Self.headerValue("ETag", in: httpResponse)
        return (value, etag)
    }

    private static func request(url: URL, method: String, token: String) throws -> URLRequest {
        guard GitHubTransport.permits(url, host: "api.github.com") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Git-Island", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func retryAfterDate(from response: HTTPURLResponse) -> Date? {
        if let retryAfter = headerValue("Retry-After", in: response),
           let seconds = TimeInterval(retryAfter) {
            return Date().addingTimeInterval(seconds)
        }

        if let reset = headerValue("X-RateLimit-Reset", in: response),
           let timestamp = TimeInterval(reset) {
            return Date(timeIntervalSince1970: timestamp)
        }

        return nil
    }

    private static func headerValue(_ name: String, in response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            guard String(describing: key).caseInsensitiveCompare(name) == .orderedSame else {
                continue
            }

            return String(describing: value)
        }

        return nil
    }
}

private enum GitHubDateParser {
    static func date(from string: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = fractionalFormatter.date(from: string) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

private struct GitHubTokenProvider {
    func token() throws -> String {
        if let token = try TokenStore.storedToken(), !token.isEmpty {
            return token
        }

        throw GitHubServiceError.missingToken
    }
}

enum GitHubServiceError: LocalizedError {
    case missingToken
    case invalidResponse
    case mergeUnavailable
    case branchUpdateUnavailable
    case api(statusCode: Int, message: String, retryAfterDate: Date?)
    case notModified(etag: String?)

    var isRateLimited: Bool {
        if case .api(let statusCode, let message, _) = self {
            return Self.isRateLimit(statusCode: statusCode, message: message)
        }

        return false
    }

    var retryAfterDate: Date? {
        if case .api(_, _, let retryAfterDate) = self {
            return retryAfterDate
        }

        return nil
    }

    var isNotModified: Bool {
        if case .notModified = self { return true }
        return false
    }

    var notModifiedETag: String? {
        if case .notModified(let etag) = self { return etag }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "GitHub token missing. Sign in through Git Island onboarding."
        case .invalidResponse:
            return "GitHub returned an invalid response."
        case .mergeUnavailable:
            return "GitHub merge method is unavailable for this pull request."
        case .branchUpdateUnavailable:
            return "GitHub branch update is unavailable for this pull request."
        case .api(let statusCode, let message, let retryAfterDate):
            if Self.isRateLimit(statusCode: statusCode, message: message) {
                if let retryAfterDate {
                    return "GitHub rate limit reached. Next refresh after \(Self.timeFormatter.string(from: retryAfterDate))."
                }

                return "GitHub rate limit reached. Refresh is paused for a few minutes."
            }

            return "GitHub API \(statusCode): \(message)"
        case .notModified:
            return "Not modified (304 from GitHub)"
        }
    }

    private static func isRateLimit(statusCode: Int, message: String) -> Bool {
        statusCode == 429 || message.localizedCaseInsensitiveContains("rate limit")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

private struct GitHubErrorResponse: Decodable {
    let message: String
}

private struct GitHubSearchIssuesResponse: Decodable {
    let items: [GitHubSearchIssue]
}

private struct GitHubSearchIssue: Decodable {
    let updatedAt: Date
    let pullRequest: GitHubSearchPullRequest?

    private enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case pullRequest = "pull_request"
    }
}

private struct GitHubSearchPullRequest: Decodable {
    let url: URL
}

struct GitHubRepository: Decodable {
    let fullName: String
    let name: String
    let archived: Bool?

    private enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case name
        case archived
    }
}

struct GitHubUser: Decodable {
    let login: String
}

struct GitHubPullRequestDetails: Decodable {
    let id: Int
    let number: Int
    let title: String
    let state: String
    let draft: Bool
    let htmlURL: URL
    let mergeable: Bool?
    let mergeableState: String?
    let user: GitHubUser
    let head: GitHubPullRequestHead
    let requestedReviewers: [GitHubUser]

    private enum CodingKeys: String, CodingKey {
        case id
        case number
        case title
        case state
        case draft
        case htmlURL = "html_url"
        case mergeable
        case mergeableState = "mergeable_state"
        case user
        case head
        case requestedReviewers = "requested_reviewers"
    }
}

private extension GitHubPullRequestDetails {
    var hasMergeConflict: Bool {
        mergeable == false || normalizedMergeableState == "DIRTY"
    }

    var hasCleanMergeState: Bool {
        guard let normalizedMergeableState else {
            return false
        }

        return ["CLEAN", "HAS_HOOKS"].contains(normalizedMergeableState)
    }

    var hasMergeableWithoutKnownState: Bool {
        mergeable == true && normalizedMergeableState == nil
    }

    private var normalizedMergeableState: String? {
        guard let mergeableState, !mergeableState.isEmpty else {
            return nil
        }

        return mergeableState.uppercased()
    }
}

struct GitHubPullRequestHead: Decodable {
    let sha: String
    let repo: GitHubRepository?
}

struct GitHubPullRequestReview: Decodable {
    let state: String
    let user: GitHubUser?
    let submittedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case state
        case user
        case submittedAt = "submitted_at"
    }
}

struct GitHubCheckRunsResponse: Decodable {
    let totalCount: Int
    let checkRuns: [GitHubCheckRun]

    private enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case checkRuns = "check_runs"
    }
}

struct GitHubCheckRun: Decodable {
    let name: String
    let status: String
    let conclusion: String?

    var isPending: Bool {
        ["queued", "in_progress", "waiting", "requested", "pending"].contains(normalizedStatus)
    }

    var isFailing: Bool {
        guard normalizedStatus == "completed" else {
            return false
        }

        return [
            "action_required",
            "cancelled",
            "failure",
            "stale",
            "startup_failure",
            "timed_out"
        ].contains(normalizedConclusion ?? "")
    }

    var isSuccessful: Bool {
        normalizedStatus == "completed"
            && [
                "neutral",
                "skipped",
                "success"
            ].contains(normalizedConclusion ?? "")
    }

    private var normalizedStatus: String {
        status.lowercased()
    }

    private var normalizedConclusion: String? {
        conclusion?.lowercased()
    }
}

struct GitHubCombinedStatusResponse: Decodable {
    let state: String
    let statuses: [GitHubCommitStatus]

    var isPending: Bool {
        ["expected", "pending"].contains(normalizedState)
    }

    var isSuccessful: Bool {
        normalizedState == "success"
    }

    var isFailing: Bool {
        ["error", "failure"].contains(normalizedState)
    }

    private var normalizedState: String {
        state.lowercased()
    }
}

struct GitHubCommitStatus: Decodable {
    let state: String
}
