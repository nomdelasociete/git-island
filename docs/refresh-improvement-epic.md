# Epic: Improve PR Inbox Refresh Freshness & Efficiency

**Goal**: Make state changes (CI progress, review submissions, mergeability) visible in the island typically within 15-30s instead of 1-2+ minutes. Do it efficiently so we don't burn rate limits or battery/network.

**Current problems (diagnosed 2026-07-03)**:
- Every refresh does 2 (seq) REST searches + N*(PR details + reviews + 1 GraphQL + 2 status/checks) HTTP calls. For 10-15 PRs this is easily 30-60 roundtrips + several seconds of wall time.
- No ETags / conditional requests → every call pays full latency + quota.
- Candidate discovery relies on `/search/issues?sort=updated` (30 req/min separate limit, only top 100 per query, no pagination). Quiet long-running CI PRs or review-only changes can be slow to reappear or reclassified.
- Adaptive logic (20s high-freq window, 30s while `.testing`) helps but is insufficient: phase misalignment + fetch cost + search lag + default 60s idle = user-visible 60-120s+ delays.
- GraphQL is already used (per-PR) but not leveraged for batching the list + data.
- Diagnostics exist but lack timings, call counts, 304 savings, effective next delay root cause.
- No special treatment when user expands a testing group.

**Non-goals** (per AGENTS.md + product):
- No backend/webhook relay (local-only, privacy).
- No change to notch geometry / hover / UI surface for this epic (unless incidental).
- Keep exact classification semantics (tests must continue to pass).
- Stay within existing token scopes ("read:user repo").

**Success metrics (observable)**:
- Typical full refresh for active inbox with 1-2 testing PRs completes in <1.5s network time.
- While any PR is `.testing`, auto cadence stays <=20s (respecting 15s min gate).
- On CI start/finish or review submit (simulated), counter + list update within one poll cycle + fetch.
- 304s are used for stable resources (visible in new diagnostics).
- Search quota headroom remains comfortable even during focus/wake bursts.
- All existing `GitHubPullRequestClassificationTests` + `RefreshGateTests` pass unchanged.
- Manual "Refresh now" feels instant (cancels in-flight).

**Overall approach**:
1. Make *existing* REST path much cheaper with conditionals + parallelism (quick wins).
2. Make candidate collection more robust.
3. Tighten the adaptive scheduler with better signals.
4. Move the heavy read path to 1-2 GraphQL queries (big latency win) while keeping REST for writes and detailed check names.
5. Improve observability so future tuning is data-driven.
6. Small vertical slices, each with tests + build validation.

Use `jb/` branches for implementation PRs. Update `docs/implementation-status.md` on the slices that ship. Run `xcodegen generate --spec project.yml && xcodebuild ... CODE_SIGNING_ALLOWED=NO` for compile checks.

---

## Vertical slice / sub-issue breakdown (recommended order)

### 1. ETag / conditional requests for REST fetches (high ROI, low risk)
- Extend `GitHubAPIClient`:
  - Accept/return ETag.
  - On GET, if we have prior ETag for the resource key (URL or URL+sha), add `If-None-Match`.
  - Handle 304 Not Modified: return previous successful value (or a "not modified" signal) without consuming full quota/time.
- Add a tiny in-actor cache in `GitHubPullRequestService` (or dedicated ETagStore) keyed appropriately. Persist only for the duration of the process (no UserDefaults).
- Apply immediately to:
  - PR details
  - /reviews
  - /check-runs
  - /status
  - search responses (if stable)
- Keep full re-fetch path for first time / errors.
- Update `send()` and callers gracefully (try? paths already tolerant).
- Add basic test coverage (unit for client or via service actor tests if easy).
- Acceptance: stable PRs cause mostly 304s on repeated refreshes; refresh duration visibly drops in diagnostics; no behavior change.

**Files touched**: `GitHubPullRequestService.swift` (client + service), new or extended tests, diagnostics if we log hits.

### 2. Parallelize searches + paginate / robust candidate discovery
- Turn the `for query in inboxCandidateQueries` sequential awaits into concurrent (`async let` + task group or array of tasks).
- Add pagination loop for search (page 1..N while results==100 and total < e.g. 300). Respect the "seen by PR URL".
- When in `.selected` repo mode, still append `repo:` qualifiers (current behavior).
- Optional: after collecting from search, also ensure any PRs that were present in the *previous* refresh are re-included for at least one cycle (prevents quiet PRs from disappearing from polling).
- Keep `GitHubPullRequestCandidate` (url + repo + updatedAt).
- Acceptance: two searches run concurrently; >100 matching PRs are handled (rare but correct); logs/diagnostics show candidate count.

**Files**: `GitHubPullRequestService.swift`, possibly store for previous IDs.

### 3. Richer refresh diagnostics + rate-limit visibility
- Expand `RefreshDiagnostics` (and published state):
  - searchDuration, buildDuration, totalNetworkEst
  - numCandidates, num304s, numFullFetches
  - lastSearchRemaining (parse `X-RateLimit-Remaining` for search resource when available)
  - effectiveNextDelay reason ("testing: 30s", "highfreq", "idle: userPref")
- Capture response headers in client for rate info (non-error path too).
- Surface more in SettingsView "Refresh" section and the debug text.
- Keep existing fields.
- Acceptance: after a refresh you can see "12 candidates, 7x 304, search 180ms, build 420ms, next=20s (testing)" etc. Helps prove improvements.

**Files**: `GitIslandStore.swift`, `GitHubPullRequestService.swift`, `SettingsView.swift`, tests if diagnostics tested.

### 4. Cadence & triggering improvements (make adaptive actually feel live)
- Change constants / logic:
  - While `pullRequests` contains `.testing` (or recently had pending checks), use 15-20s (align high-freq + testing).
  - Extend high-freq window on *any* group signature change for existing PRs (headSHA, reason, statusLabel) — already partially done.
  - On expand of a group that has testing/waiting items, do a `refresh(force: true)` (capped by gate).
  - Consider a short "just became testing" burst.
- Respect min spacing and rate-limit backoff strictly.
- Make sure `rescheduleAutoRefreshIfRunning()` after every relevant event.
- Update `nextAutoRefreshDelay`, `markHighFrequencyRefresh`, and related comments.
- Acceptance: with a testing PR present, timer fires ~every 15-20s (observed via diagnostics); focus/expand on testing group triggers prompt update; no regression on rate limit handling or gate tests.

**Files**: `GitIslandStore.swift` (main), `GitIslandApp.swift` (maybe one more trigger), `RefreshGateTests.swift` updates if rules change, docs.

### 5. GraphQL inbox fetch (core efficiency win)
- Add a new path (or replace inside `fetchPullRequests`) that:
  - Does 1 viewer query for authored open PRs (with rich nested fields: reviews(last:30), commits(last:1){commit{statusCheckRollup, checkSuites/checkRuns for names}}, reviewDecision, mergeStateStatus, mergeable, head, etc.).
  - Does 1 GraphQL search (or equivalent) for `review-requested:me -author:me ...` with same fragments.
  - Dedup by ID/global_id or URL.
  - Apply repo filter client-side or via qualifiers.
  - Extract enough to build `GitHubPullRequestDetails` + `reviews` + `GitHubPullRequestMergeReadiness` + `GitHubPipelineState` equivalents (or evolve internal models).
  - Fall back to or supplement with the existing check-runs REST only when we need the exact "first pending name" that summary doesn't give.
- Keep the old per-candidate REST path temporarily (feature flag or progressive) or delete after tests pass.
- Update `buildPullRequest`, `classify` call sites if needed (ideally feed same shapes so classify() is untouched).
- Handle `updatedAt` (PR has its own).
- For earlyClassification (draft/conflict) we can often get from the list query too.
- Cost: one or two GraphQL calls (points) instead of dozens of REST.
- Acceptance: same PRs and same buckets as before for all cases in `GitHubPullRequestClassificationTests`. Manual verification on real data. Refresh time << previous.

**Files**: `GitHubPullRequestService.swift` (new query builder + response decodables + fetcher), possibly small model additions. Keep REST client for other uses (repos list, merge, update-branch, detailed checks).

Suggested minimal GraphQL shape (to be refined in impl):
```graphql
query Inbox($login: String!) {
  viewer {
    pullRequests(first: 50, states: [OPEN], orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes { ...PRInboxFragment }
    }
  }
  search(query: "is:pr is:open review-requested:$login -draft:true", type: ISSUE, first: 50) {
    nodes {
      ... on PullRequest { ...PRInboxFragment }
    }
  }
}
fragment PRInboxFragment on PullRequest {
  id, number, title, url, state, isDraft
  author { login }
  headRefOid
  headRepository { nameWithOwner }
  repository { nameWithOwner }
  # requestedReviewers, reviews(last:30){...}, commits(last:1){... statusCheckRollup + checkRuns}, reviewDecision, mergeStateStatus, mergeable, ...
}
```
Plus per-repo default merge method query remains (cached).

### 6. Wire new fetcher, preserve behavior, update tests + gates
- Make `fetchPullRequests` (or a new internal) use the GraphQL path by default.
- Ensure repository scoping, locally hidden, optimistic, arrival pulse, signature all continue to work.
- Run full classification test matrix against data produced by new path (add a test helper that feeds GraphQL-shaped data into classify if needed).
- Remove or comment old heavy per-PR paths once confident.
- Update any early exits and pipeline state construction.
- Acceptance: all unit tests green; `xcodebuild` clean; no change in produced `PullRequest.group/reason/statusLabel` for the known cases.

### 7. Docs, README, status, Settings polish + final validation
- Update `docs/implementation-status.md` (mark refresh as improved).
- Update README refresh paragraph.
- Add brief note in Settings "Refresh" about faster updates for active PRs.
- Possibly expose "last GitHub response code / 304 ratio" in advanced diagnostics.
- Manual test on notched hardware: start a real CI on a PR in the app's scope, watch counter flip testing→ready with <30s lag.
- Build validation command documented in the slice.
- Close the loop on any secondary rate limit observations.

---

## Implementation guidelines (for the PRs)
- Small PRs preferred. Each slice above can be a PR (or split 5 further if huge).
- Update worktree (`git fetch --all --prune`), be on `jb/something`.
- After code: `xcodegen generate --spec project.yml && xcodebuild -project GitIsland.xcodeproj -scheme GitIsland -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`
- Run the test target.
- For anything touching UI timing or hover retention: re-verify the "no top detach" invariants (but this epic is data-layer heavy).
- Never bypass RefreshGate.
- Log using existing style (no new stdlib logging if structlog-like isn't used; here it's simple).
- When a slice ships, update the plan doc + status doc.
- Manual refresh must still cancel in-flight.
- Keep "no PRs → no island", arrival ripple only for new arrivals (not state changes unless we decide later).

## Out of scope for this epic (future)
- Per-PR targeted polling (more complex state machine).
- Local persistent ETag cache across restarts.
- User-facing "refresh interval while checks running" picker (current adaptive is good enough once efficient).
- Webhooks / relay.
- Sparkle / other.

## References
- Current code: `Sources/GitIsland/Stores/GitIslandStore.swift`, `Sources/GitIsland/Services/GitHubPullRequestService.swift`
- Tests: `Tests/GitIslandTests/GitHubPullRequestClassificationTests.swift`, `RefreshGateTests.swift`
- GitHub docs (as of 2026): rate limits (search=30/min, core=5k/hr, GraphQL points=5k/hr), conditional requests (304s don't count), best practices (avoid polling → we still poll but make it cheap + batched).
- Existing GraphQL usage in service (per-PR merge readiness + default method) is the pattern to extend.

This plan was produced after full code read + GitHub API doc review on 2026-07-03.

Next step after issues filed: pick first slice, branch, implement, test on real notched Mac + live PRs.
