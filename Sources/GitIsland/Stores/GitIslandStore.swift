import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class GitIslandStore: ObservableObject {
    static let shared = GitIslandStore()

    @Published var isExpanded = false
    @Published var selectedGroup: PullRequestGroup = .blocked
    @Published var notchGapWidth: CGFloat = 220
    @Published var topBandHeight: CGFloat = 38
    @Published private(set) var showsAllPullRequests = false
    @Published private(set) var pullRequests: [PullRequest] = []
    @Published private(set) var isLoading = false
    @Published private(set) var mergingPullRequestIDs = Set<Int>()
    @Published private(set) var updatingBranchPullRequestIDs = Set<Int>()
    @Published private(set) var arrivalPulse: PullRequestArrivalPulse?
    @Published private(set) var mergeCelebration: PullRequestMergeCelebration?
    @Published private(set) var lastError: String?
    @Published private(set) var credentialStorageError: String?
    @Published private(set) var lastRefreshDate: Date?
    @Published private(set) var isAuthenticated = false
    @Published private(set) var githubAuthorizationRequired = false
    @Published private(set) var githubLogin: String?
    @Published private(set) var retainedPanelChromeHeight: CGFloat?
    @Published private(set) var expandedSessionPanelChromeHeight: CGFloat?
    @Published var refreshIntervalSeconds = UserPreferences.refreshIntervalSeconds
    @Published var repositoryFilterMode = UserPreferences.repositoryFilterMode
    @Published var crazyAnimationsEnabled = UserPreferences.crazyAnimationsEnabled
    @Published private(set) var eventSounds = UserPreferences.eventSounds
    @Published private(set) var outlineLaneStyle = UserPreferences.outlineLaneStyle
    @Published private(set) var selectedRepositoryFullNames = UserPreferences.selectedRepositoryFullNames
    @Published private(set) var mutedRepositoryFullNames = UserPreferences.mutedRepositoryFullNames
    @Published private(set) var hiddenPullRequests = UserPreferences.hiddenPullRequests
    @Published private(set) var refreshDiagnostics = RefreshDiagnostics()

#if DEBUG
    @Published private(set) var debugRipplePreviewGroup: PullRequestGroup?
#endif

    @Published var leftWingWidth: CGFloat = 72
    @Published var rightWingWidth: CGFloat = 72

    private var service = GitHubPullRequestService()
    private let authService = GitHubAuthService()
    private var accountGeneration = UUID()
    private var refreshTask: Task<Void, Never>?
    private var refreshRequestID: UUID?
    @Published private(set) var relayConnectionState: RelayConnectionState = .inactive
    var relayConnected: Bool { relayConnectionState == .connected }
    var hasRelayConfiguration: Bool {
        !UserPreferences.relayOrigin.isEmpty &&
        (relayConfiguration != nil || relayDevice.hasSavedEnrollment || relayDevice.legacyExpired)
    }
    @Published private(set) var relayInboxEnabled = UserPreferences.relayInboxEnabled
    @Published private(set) var relayInboxSetupBusy = false
    private var relayInboxAuthorizationTask: Task<Void, Never>?
    private var relayInboxAuthorizationID: UUID?
    var relayInboxAuthorizationPending: Bool { relayInboxAuthorizationID != nil }
    let relayDevice = RelayDeviceSession()
    private var relayDeviceObservation: AnyCancellable?
    var currentRelayConfiguration: RelayConfiguration? {
        relayDevice.configuration(origin: UserPreferences.relayOrigin)
    }

    var githubRefreshPaused: Bool {
        nextAllowedRefreshDate.map { $0 > Date() } ?? false
    }

    var automaticRefreshTitle: String {
        if isAuthenticated && githubRefreshPaused { return relayInboxEnabled ? "Inbox sync paused" : "Waiting for GitHub’s rate limit" }
        guard isAuthenticated else { return "Sign in to enable updates" }
        switch relayConnectionState {
        case .connected: return "Live updates active"
        case .connecting: return "Connecting to live updates"
        case .reconnecting: return "Checking every minute"
        case .inactive: return "Automatic checks active"
        case .authorizationRequired: return relayDevice.isBusy ? "Updating live authorization" : "Live updates need authorization"
        }
    }

    var automaticRefreshDetail: String {
        guard isAuthenticated else { return "Connect your GitHub account to keep your inbox updated." }
        if githubRefreshPaused, let nextAllowedRefreshDate {
            let retry = Self.timeFormatter.string(from: nextAllowedRefreshDate)
            if relayInboxEnabled { return "Server synchronization will retry after \(retry). This Mac keeps its last inbox and does not fall back to GitHub reads." }
            return relayConnected
                ? "Live updates are connected, but GitHub reads are paused until \(retry). Notifications cannot bypass this limit."
                : "GitHub reads are paused until \(retry). Automatic checks will resume after this limit clears."
        }
        if relayInboxEnabled { return "Relay synchronizes your inbox, including repositories without live events. This Mac reads Relay; merge and branch-update actions go directly to GitHub." }
        switch relayConnectionState {
        case .connected:
            return "A live notification triggers a fresh read from GitHub. Scheduled checks are paused while connected."
        case .connecting:
            return "Opening the live connection. Git Island checks GitHub every minute until it connects."
        case .reconnecting:
            return "The live connection is unavailable. Git Island checks GitHub every minute and reconnects automatically."
        case .authorizationRequired:
            return "Git Island checks GitHub every minute while live authorization is unavailable."
        case .inactive:
            return "Live updates are not configured. Git Island checks GitHub automatically, more often after activity or while checks are running."
        }
    }
    private let relayStream = RelayStream()
    private var autoRefreshEnabled = false
    private var relayDemand = RelayRefreshDemand()
    private var relayRetryTask: Task<Void, Never>?
    private var relayConfiguration: RelayConfiguration?

    private var autoRefreshTask: Task<Void, Never>?
    private var arrivalPulseClearTask: Task<Void, Never>?
    private var mergeCelebrationClearTask: Task<Void, Never>?
    private var presentedChromeHeight: CGFloat?
    private var presentedWidthProgress: CGFloat?
    private var pendingExpansionTask: Task<Void, Never>?
    private var lastRefreshAttemptDate: Date?
    private var nextAllowedRefreshDate: Date?
    private var highFrequencyRefreshUntil: Date?
    private var locallyHiddenPullRequestIDs = Set<Int>()
    private var locallyHiddenPullRequestClearTasks = [Int: Task<Void, Never>]()
    private var optimisticMergeBackups = [Int: PullRequest]()

    private static let minimumRefreshSpacing: TimeInterval = 15
    private static let highFrequencyRefreshSpacing: TimeInterval = 15
    private static let testingRefreshSpacing: TimeInterval = 15
    private static let highFrequencyRefreshWindow: TimeInterval = 2 * 60
    private static let rateLimitFallbackBackoff: TimeInterval = 15 * 60
    private static let locallyHiddenPullRequestTTL: UInt64 = 15 * 60 * 1_000_000_000

    private init() {
        relayDevice.githubToken = { TokenStore.token() }
        relayDeviceObservation = relayDevice.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        relayDevice.onChange = { [weak self] in
            guard let self, self.autoRefreshEnabled else { return }
            self.relayStream.stop()
            self.startRelay()
            self.scheduleNextAutoRefresh()
        }
        restoreAuthenticationState()
    }

    var menuBarTitle: String {
        if !isAuthenticated {
            return "Sign in"
        }

        let parts = PullRequestGroup.allCases.compactMap { group -> String? in
            let count = count(for: group)
            guard count > 0 else {
                return nil
            }

            let suffix: String
            switch group {
            case .blocked: suffix = "B"
            case .waiting: suffix = "W"
            case .testing: suffix = "T"
            case .ready: suffix = "R"
            }
            return "\(count)\(suffix)"
        }

        return parts.isEmpty ? "Clear" : parts.joined(separator: " ")
    }

    var selectedPullRequests: [PullRequest] {
        if showsAllPullRequests {
            return allPullRequests
        }

        return pullRequests(for: selectedGroup)
    }

    var dataSourceStatus: String {
        if !isAuthenticated {
            return "Not signed in"
        }

        if isLoading {
            return "Refreshing GitHub"
        }

        if lastRefreshDate != nil {
            return "GitHub PR inbox"
        }

        return "GitHub not loaded"
    }

    var refreshStatus: String {
        if !isAuthenticated {
            return "Sign in to load pull requests"
        }

        if isLoading {
            return "Refreshing GitHub..."
        }

        if let nextAllowedRefreshDate, Date() < nextAllowedRefreshDate {
            return "Next refresh after \(Self.timeFormatter.string(from: nextAllowedRefreshDate))"
        }

        if let lastError {
            return Self.userFacingRefreshError(lastError)
        }

        guard let lastRefreshDate else {
            return "Waiting for first refresh"
        }

        let seconds = max(0, Int(Date().timeIntervalSince(lastRefreshDate)))
        if seconds < 5 {
            return "Updated just now"
        }
        if seconds < 60 {
            return "Updated \(seconds)s ago"
        }

        let minutes = seconds / 60
        return "Updated \(minutes)m ago"
    }

    var refreshActionTitle: String {
        isLoading ? "Restart refresh" : "Refresh now"
    }

    var refreshSettingsStatus: String {
        if !isAuthenticated {
            return "Sign in required"
        }

        if isLoading {
            return "Refreshing GitHub"
        }

        if let nextAllowedRefreshDate, Date() < nextAllowedRefreshDate {
            return "Waiting for GitHub"
        }

        if lastError != nil {
            return "Refresh failed"
        }

        if lastRefreshDate == nil {
            return "Not refreshed yet"
        }

        return "Up to date"
    }

    var refreshSettingsDetail: String {
        if !isAuthenticated {
            return "Connect GitHub to load pull requests."
        }

        if isLoading {
            return "Fetching the PR inbox now."
        }

        if let nextAllowedRefreshDate, Date() < nextAllowedRefreshDate {
            return "Next retry after \(Self.timeFormatter.string(from: nextAllowedRefreshDate))."
        }

        if let lastError {
            return Self.userFacingRefreshError(lastError)
        }

        guard let lastRefreshDate else {
            return "Refresh now to load the inbox."
        }

        let seconds = max(0, Int(Date().timeIntervalSince(lastRefreshDate)))
        if seconds < 5 {
            return "Updated just now."
        }
        if seconds < 60 {
            return "Updated \(seconds)s ago."
        }

        return "Updated \(seconds / 60)m ago."
    }

    var nextAutomaticRefreshStatus: String {
        refreshDiagnostics.nextScheduledText
    }

    var activeGroupCount: Int {
        PullRequestGroup.allCases.filter { count(for: $0) > 0 }.count
    }

    /// iOS Live Activity: nothing live → nothing shown.
    var shouldShowIsland: Bool {
#if DEBUG
        if debugRipplePreviewGroup != nil {
            return true
        }
#endif

        return isAuthenticated && lastRefreshDate != nil && activeGroupCount > 0
    }

    var islandVisibilityStatus: String {
        if !isAuthenticated {
            return "Sign in required"
        }
        if lastRefreshDate == nil {
            return "Waiting for first refresh"
        }
        if activeGroupCount == 0 {
            return "Hidden — no live PR activity"
        }
        return "Active — \(inboxSummary)"
    }

    var inboxSummary: String {
        PullRequestGroup.allCases.compactMap { group in
            let count = count(for: group)
            return count > 0 ? "\(group.rawValue) \(count)" : nil
        }.joined(separator: " · ")
    }

    var repositoryScopeStatus: String {
        switch repositoryFilterMode {
        case .all:
            let mutedCount = mutedRepositoryFullNames.count
            return mutedCount == 0 ? "All repositories" : "All repositories, \(mutedCount) muted"
        case .selected:
            let count = selectedRepositoryFullNames.count
            return count == 0 ? "No repositories selected" : "\(count) selected"
        }
    }

    var counterCounts: [PullRequestGroup: Int] {
        var counts = PullRequestGroup.allCases.reduce(into: [:]) { counts, group in
            counts[group] = count(for: group)
        }

#if DEBUG
        if activeGroupCount == 0, let debugRipplePreviewGroup {
            counts[debugRipplePreviewGroup] = 1
        }
#endif

        return counts
    }

    func counterPlacements() -> [IslandDesignSystem.CounterPlacement] {
        IslandDesignSystem.counterPlacements(
            groups: PullRequestGroup.allCases.sorted { $0.compactPriority < $1.compactPriority },
            counts: counterCounts,
            leftWingWidth: leftWingWidth,
            gapWidth: notchGapWidth,
            rightWingWidth: rightWingWidth
        )
    }

    func compactSurfaceFrame(panelHeight: CGFloat? = nil) -> CGRect {
        IslandDesignSystem.compactSurfaceFrame(
            leftWingWidth: leftWingWidth,
            gapWidth: notchGapWidth,
            compactHeight: collapsedHeight,
            panelHeight: panelHeight ?? visibleHeight
        )
    }

    var outlineSegments: [IslandDesignSystem.OutlineSegment] {
        IslandDesignSystem.outlineSegments(counts: counterCounts, maxLanes: outlineLaneStyle.maxLanes)
    }

    var showsExpandedBody: Bool {
        isExpanded && (showsBlockingError || isLoading || !selectedPullRequests.isEmpty)
    }

    var showsBlockingError: Bool {
        lastError != nil && pullRequests.isEmpty
    }

    var islandWidth: CGFloat {
        leftWingWidth + notchGapWidth + rightWingWidth + IslandDesignSystem.expandedSideInset * 2
    }

    var notchMinX: CGFloat {
        IslandDesignSystem.expandedSideInset + leftWingWidth
    }

    /// AppKit points are bottom-up; the shared surface path is top-down.
    func islandContains(_ point: CGPoint, panelHeight: CGFloat) -> Bool {
        let topDownPoint = CGPoint(x: point.x, y: panelHeight - point.y)
        guard topDownPoint.y >= 0, topDownPoint.y <= visibleHeight else {
            return false
        }

        return islandShape(bodyBottomY: visibleHeight, widthProgress: visibleWidthProgress)
        .path(in: CGRect(x: 0, y: 0, width: islandWidth, height: visibleHeight))
        .contains(topDownPoint)
    }

    func islandShape(bodyBottomY: CGFloat, widthProgress: CGFloat) -> NotchIslandShape {
        NotchIslandShape(
            topBandHeight: compactBandHeight,
            compactHeight: collapsedHeight,
            bodyBottomY: bodyBottomY,
            widthProgress: widthProgress,
            compactSurfaceFrame: compactSurfaceFrame()
        )
    }

    /// 0 = notch width, 1 = expanded width. Animated independently of height.
    var visibleWidthProgress: CGFloat {
        presentedWidthProgress ?? (isExpanded ? 1 : 0)
    }

    func updatePresentedWidthProgress(_ progress: CGFloat) {
        presentedWidthProgress = progress
    }

    /// Collapsed island height: the notch band plus the outline outset below it.
    var collapsedHeight: CGFloat {
        compactBandHeight + IslandDesignSystem.compactOutlineOutset
    }

    var compactBandHeight: CGFloat {
        let clampedHeight = min(
            max(IslandDesignSystem.minimumCompactBandHeight, topBandHeight),
            IslandDesignSystem.maximumCompactBandHeight
        )
        return clampedHeight + IslandDesignSystem.notchVerticalBleed
    }

    var expandedContentHeight: CGFloat {
        if showsBlockingError {
            return IslandDesignSystem.expandedHeight(
                rowCount: 0,
                topBandHeight: compactBandHeight,
                showsMessageBody: true
            )
        }

        if isLoading && selectedPullRequests.isEmpty {
            return IslandDesignSystem.expandedHeight(
                rowCount: 1,
                topBandHeight: compactBandHeight,
                showsMessageBody: false
            )
        }

        return IslandDesignSystem.expandedHeight(
            rowCount: selectedPullRequests.count,
            topBandHeight: compactBandHeight,
            showsMessageBody: false,
            showsSummaryBar: !selectedPullRequests.isEmpty
        )
    }

    var chromeHeight: CGFloat {
        guard isExpanded, showsExpandedBody else {
            return collapsedHeight
        }
        return expandedContentHeight
    }

    var visibleHeight: CGFloat {
        presentedChromeHeight ?? chromeHeight
    }

    func updatePresentedChromeHeight(_ height: CGFloat) {
        presentedChromeHeight = min(panelChromeHeight, max(collapsedHeight, height))
    }

    func completeCollapsePresentation() {
        guard !isExpanded, pendingExpansionTask == nil else { return }
        presentedChromeHeight = collapsedHeight
        presentedWidthProgress = 0
        clearRetainedPanelHeight()
    }

    var panelChromeHeight: CGFloat {
        max(
            chromeHeight,
            retainedPanelChromeHeight ?? 0,
            expandedSessionPanelChromeHeight ?? 0
        )
    }

    /// Decorative room below the surface is never part of pointer hit testing.
    var panelFrameSize: CGSize {
        CGSize(width: islandWidth, height: panelChromeHeight + outlineLaneRoom)
    }

    var outlineLaneRoom: CGFloat {
        outlineLaneStyle.room(laneCount: outlineSegments.map(\.lanes).max() ?? 0)
    }

    static let buildStamp = "2026-06-28a"

    var currentIslandSize: CGSize {
        panelFrameSize
    }

    var needsSignIn: Bool {
        !isAuthenticated
    }

    func count(for group: PullRequestGroup) -> Int {
        pullRequests(for: group).count
    }

    /// Oldest first. GitHub pull request IDs grow with creation time.
    func pullRequests(for group: PullRequestGroup) -> [PullRequest] {
        pullRequests
            .filter { $0.group == group }
            .sorted { $0.id < $1.id }
    }

    /// Grouped in the outline's left-to-right color order, oldest first in each.
    private var allPullRequests: [PullRequest] {
        IslandDesignSystem.outlineOrder.flatMap(pullRequests(for:))
    }

    func open(_ group: PullRequestGroup) {
        let resolvedGroup = resolvedGroup(for: group)
        if selectedGroup != resolvedGroup {
            selectedGroup = resolvedGroup
        }
        if showsAllPullRequests {
            showsAllPullRequests = false
        }
        retainExpandedSessionPanelHeight()
        beginExpansion()
    }

    func select(_ group: PullRequestGroup) {
        guard showsAllPullRequests || selectedGroup != group else {
            return
        }

        if selectedGroup != group {
            selectedGroup = group
        }
        if showsAllPullRequests {
            showsAllPullRequests = false
        }
        retainExpandedSessionPanelHeight()
    }

    func expand() {
        guard activeGroupCount > 0 else {
            return
        }
        let resolvedGroup = primaryActiveGroup ?? selectedGroup
        if selectedGroup != resolvedGroup {
            selectedGroup = resolvedGroup
        }
        if showsAllPullRequests {
            showsAllPullRequests = false
        }
        retainExpandedSessionPanelHeight()
        beginExpansion()
    }

    func expandAllPullRequests() {
        guard activeGroupCount > 0 else {
            return
        }

        if !showsAllPullRequests {
            showsAllPullRequests = true
        }

        retainExpandedSessionPanelHeight()

        if isExpanded {
            return
        }

        beginExpansion()
    }

    func toggle(_ group: PullRequestGroup) {
        if isExpanded && !showsAllPullRequests && selectedGroup == group {
            collapse()
        } else {
            open(group)
        }
    }

    func collapse() {
        pendingExpansionTask?.cancel()
        pendingExpansionTask = nil
        if isExpanded {
            retainPanelHeightForCollapse()
        } else if visibleHeight <= collapsedHeight {
            clearRetainedPanelHeight()
        }
        expandedSessionPanelChromeHeight = nil
        isExpanded = false
    }

    func resetPanelPresentationState() {
        pendingExpansionTask?.cancel()
        pendingExpansionTask = nil
        clearRetainedPanelHeight()
        expandedSessionPanelChromeHeight = nil
        presentedChromeHeight = nil
        presentedWidthProgress = nil
    }

    private func beginExpansion() {
        guard activeGroupCount > 0 else {
            return
        }

        if isExpanded {
            refreshAfterUserInteraction()
            return
        }

        if pendingExpansionTask != nil {
            preparePanelHeightForExpansion()
            return
        }

        preparePanelHeightForExpansion()
        pendingExpansionTask = Task { [weak self] in
            await Task.yield()

            await MainActor.run {
                guard let self, !Task.isCancelled else {
                    return
                }

                self.isExpanded = true
                self.clearRetainedPanelHeight()
                self.retainExpandedSessionPanelHeight()
                self.refreshAfterUserInteraction()
                self.pendingExpansionTask = nil
            }
        }
    }

    private func preparePanelHeightForExpansion() {
        let targetHeight = maximumExpandedContentHeight + IslandDesignSystem.surfaceOvershootHeadroom
        guard targetHeight > collapsedHeight + 1 else {
            clearRetainedPanelHeight()
            expandedSessionPanelChromeHeight = nil
            return
        }

        expandedSessionPanelChromeHeight = max(expandedSessionPanelChromeHeight ?? 0, targetHeight)
        retainedPanelChromeHeight = targetHeight
    }

    private func retainPanelHeightForCollapse() {
        let height = panelChromeHeight
        guard height > collapsedHeight + 1 else {
            return
        }

        retainedPanelChromeHeight = height
    }

    private func clearRetainedPanelHeight() {
        retainedPanelChromeHeight = nil
    }

    func restoreAuthenticationState() {
        let restoredToken: String?
        do {
            restoredToken = try TokenStore.storedToken()
            credentialStorageError = nil
        } catch {
            credentialStorageError = TokenStore.cleanupPending
                ? CredentialStorageError.cleanupFailed.localizedDescription
                : "Stored credentials could not be read or migrated safely. Unlock your Mac and retry, or sign in again."
            isAuthenticated = false
            githubLogin = nil
            return
        }
        guard let token = restoredToken, !token.isEmpty else {
            isAuthenticated = false
            githubLogin = nil
            return
        }

        isAuthenticated = true
        Task {
            await loadGitHubIdentity(token: token)
        }
    }

    func retryCredentialStorage() {
        // Restoration retries pending deletion only after an explicit sign-out.
        // A transient read error must never turn into a destructive retry.
        restoreAuthenticationState()
        if isAuthenticated { startAutoRefresh() }
    }

    func beginDeviceSignIn() async throws -> GitHubDeviceFlowSession {
        try await authService.startDeviceFlow()
    }

    func completeDeviceSignIn(session: GitHubDeviceFlowSession) async throws {
        let generation = accountGeneration
        let token = try await authService.pollForToken(session: session)
        try Task.checkCancellation()
        guard generation == accountGeneration else { throw CancellationError() }
        signOut()
        try TokenStore.save(token)
        credentialStorageError = nil
        githubAuthorizationRequired = false
        lastRefreshDate = nil
        isAuthenticated = true
        lastError = nil
        let signedInGeneration = accountGeneration
        await loadGitHubIdentity(token: token)
        guard signedInGeneration == accountGeneration, isAuthenticated else { return }
        startAutoRefresh()
    }

    func signOut() {
        cancelRelayInboxAuthorization()
        accountGeneration = UUID()
        service = GitHubPullRequestService()
        stopAutoRefresh()
        do {
            try TokenStore.delete()
            credentialStorageError = nil
        } catch {
            credentialStorageError = CredentialStorageError.cleanupFailed.localizedDescription
        }
        isAuthenticated = false
        githubLogin = nil
        pullRequests = []
        updatingBranchPullRequestIDs = []
        selectedRepositoryFullNames = []
        UserPreferences.selectedRepositoryFullNames = []
        mutedRepositoryFullNames = []
        UserPreferences.mutedRepositoryFullNames = []
        hiddenPullRequests = []
        UserPreferences.hiddenPullRequests = []
        repositoryFilterMode = .all
        UserPreferences.repositoryFilterMode = .all
        mergingPullRequestIDs = []
        showsAllPullRequests = false
        locallyHiddenPullRequestIDs = []
        optimisticMergeBackups = [:]
        locallyHiddenPullRequestClearTasks.values.forEach { $0.cancel() }
        locallyHiddenPullRequestClearTasks = [:]
        arrivalPulse = nil
        arrivalPulseClearTask?.cancel()
        arrivalPulseClearTask = nil
        mergeCelebration = nil
        mergeCelebrationClearTask?.cancel()
        mergeCelebrationClearTask = nil
        pendingExpansionTask?.cancel()
        pendingExpansionTask = nil
        presentedChromeHeight = nil
        presentedWidthProgress = nil
        retainedPanelChromeHeight = nil
        expandedSessionPanelChromeHeight = nil
        lastRefreshDate = nil
        lastError = nil
        refreshDiagnostics = RefreshDiagnostics()
        isExpanded = false
    }

    func updateRefreshInterval(_ seconds: Int) {
        guard RefreshIntervalOption(rawValue: seconds) != nil else {
            return
        }

        refreshIntervalSeconds = seconds
        UserPreferences.refreshIntervalSeconds = seconds
        restartAutoRefresh()
    }

    func updateCrazyAnimationsEnabled(_ enabled: Bool) {
        guard crazyAnimationsEnabled != enabled else {
            return
        }

        crazyAnimationsEnabled = enabled
        UserPreferences.crazyAnimationsEnabled = enabled
    }

    func updateOutlineLaneStyle(_ style: OutlineLaneStyle) {
        let clamped = style.clamped()
        guard outlineLaneStyle != clamped else { return }
        outlineLaneStyle = clamped
        UserPreferences.outlineLaneStyle = clamped
    }

    func sound(for event: IslandSoundEvent) -> IslandSoundChoice {
        eventSounds[event] ?? .none
    }

    func updateSound(_ choice: IslandSoundChoice, for event: IslandSoundEvent) {
        eventSounds[event] = choice
        UserPreferences.eventSounds = eventSounds
    }

    /// Events pointing at a deleted custom sound fall back to none.
    func deleteCustomSound(named fileName: String) {
        IslandSoundPlayer.shared.deleteCustomSound(named: fileName)
        for (event, choice) in eventSounds where choice == .custom(fileName) {
            eventSounds[event] = IslandSoundChoice.none
        }
        UserPreferences.eventSounds = eventSounds
    }

    private func playSound(for event: IslandSoundEvent?) {
        guard let event else { return }
        IslandSoundPlayer.shared.play(sound(for: event))
    }

    func updateRepositoryFilterMode(_ mode: RepositoryFilterMode) {
        guard repositoryFilterMode != mode else {
            return
        }

        repositoryFilterMode = mode
        UserPreferences.repositoryFilterMode = mode
        applyRepositoryFilterToLoadedPullRequests()
        refreshAfterRepositoryScopeChange()
    }

    func isRepositorySelected(_ fullName: String) -> Bool {
        guard let normalized = UserPreferences.normalizedRepositoryFullName(fullName) else {
            return false
        }

        return selectedRepositoryFullNames.contains(normalized)
    }

    func addSelectedRepository(_ fullName: String) {
        guard let normalized = UserPreferences.normalizedRepositoryFullName(fullName) else {
            return
        }

        var changed = false
        if mutedRepositoryFullNames.contains(normalized) {
            mutedRepositoryFullNames.removeAll { $0 == normalized }
            UserPreferences.mutedRepositoryFullNames = mutedRepositoryFullNames
            changed = true
        }

        if !selectedRepositoryFullNames.contains(normalized) {
            selectedRepositoryFullNames.append(normalized)
            selectedRepositoryFullNames.sort()
            UserPreferences.selectedRepositoryFullNames = selectedRepositoryFullNames
            changed = true
        }

        if repositoryFilterMode != .selected {
            repositoryFilterMode = .selected
            UserPreferences.repositoryFilterMode = .selected
            changed = true
        }

        guard changed else {
            return
        }

        applyRepositoryFilterToLoadedPullRequests()
        refreshAfterRepositoryScopeChange()
    }

    func muteRepository(_ fullName: String) {
        guard let normalized = UserPreferences.normalizedRepositoryFullName(fullName) else {
            return
        }

        if !mutedRepositoryFullNames.contains(normalized) {
            mutedRepositoryFullNames.append(normalized)
            mutedRepositoryFullNames.sort()
            UserPreferences.mutedRepositoryFullNames = mutedRepositoryFullNames
        }

        if selectedRepositoryFullNames.contains(normalized) {
            selectedRepositoryFullNames.removeAll { $0 == normalized }
            UserPreferences.selectedRepositoryFullNames = selectedRepositoryFullNames
        }

        applyRepositoryFilterToLoadedPullRequests()
    }

    func unmuteRepository(_ fullName: String) {
        guard let normalized = UserPreferences.normalizedRepositoryFullName(fullName),
              mutedRepositoryFullNames.contains(normalized)
        else {
            return
        }

        mutedRepositoryFullNames.removeAll { $0 == normalized }
        UserPreferences.mutedRepositoryFullNames = mutedRepositoryFullNames
        guard isAuthenticated else {
            return
        }
        refresh(force: true, reason: .repositoryScope)
    }

    func hidePullRequest(_ pullRequest: PullRequest) {
        hiddenPullRequests.removeAll { $0.id == pullRequest.id }
        hiddenPullRequests.append(HiddenPullRequest(pullRequest: pullRequest))
        UserPreferences.hiddenPullRequests = hiddenPullRequests
        hiddenPullRequests = UserPreferences.hiddenPullRequests
        applyRepositoryFilterToLoadedPullRequests()
    }

    func showHiddenPullRequest(id: Int) {
        guard hiddenPullRequests.contains(where: { $0.id == id }) else {
            return
        }

        hiddenPullRequests.removeAll { $0.id == id }
        UserPreferences.hiddenPullRequests = hiddenPullRequests
        hiddenPullRequests = UserPreferences.hiddenPullRequests
        guard isAuthenticated else {
            return
        }
        refresh(force: true, reason: .repositoryScope)
    }

    func removeSelectedRepository(_ fullName: String) {
        guard let normalized = UserPreferences.normalizedRepositoryFullName(fullName) else {
            return
        }

        selectedRepositoryFullNames.removeAll { $0 == normalized }
        UserPreferences.selectedRepositoryFullNames = selectedRepositoryFullNames
        applyRepositoryFilterToLoadedPullRequests()
        refreshAfterRepositoryScopeChange()
    }

    func configureRelay(origin: String) throws {
        let origin = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !relayDevice.isBusy, origin.isEmpty || RelayDeviceSession.origin(origin) == RelayDeviceSession.origin(UserPreferences.officialRelayOrigin) else {
            throw URLError(.badURL)
        }
        UserPreferences.relayOrigin = origin
        if autoRefreshEnabled { restartAutoRefresh() }
    }

    func cancelRelayInboxAuthorization() {
        guard relayInboxAuthorizationID != nil else { return }
        relayInboxAuthorizationTask?.cancel()
        relayInboxAuthorizationTask = nil
        relayInboxAuthorizationID = nil
        relayInboxSetupBusy = false
    }

    func authorizeRelayInbox() {
        guard let configuration = currentRelayConfiguration, let login = githubLogin,
              let subject = relayDevice.inboxSubject, !relayInboxSetupBusy else { return }
        let generation = accountGeneration
        let requestID = UUID()
        relayInboxAuthorizationID = requestID
        relayInboxSetupBusy = true
        relayInboxAuthorizationTask = Task {
            defer {
                if relayInboxAuthorizationID == requestID {
                    relayInboxAuthorizationTask = nil
                    relayInboxAuthorizationID = nil
                    relayInboxSetupBusy = false
                }
            }
            do {
                let client = RelayInboxClient(configuration: configuration)
                let url = try await client.authorizationURL()
                try Task.checkCancellation()
                guard accountGeneration == generation, currentRelayConfiguration == configuration else { return }
                guard NSWorkspace.shared.open(url) else { throw RelayInboxError.invalidResponse }
                try await client.waitForAuthorization(login: login, subject: subject)
                try Task.checkCancellation()
                guard accountGeneration == generation, currentRelayConfiguration == configuration,
                      relayInboxAuthorizationID == requestID else { return }
                relayInboxEnabled = true
                UserPreferences.relayInboxEnabled = true
                nextAllowedRefreshDate = nil
                restartAutoRefresh()
                refresh(force: true)
            } catch {
                if !Task.isCancelled, accountGeneration == generation,
                   relayInboxAuthorizationID == requestID { lastError = error.localizedDescription }
            }
        }
    }

    func disableRelayInbox() {
        cancelRelayInboxAuthorization()
        relayInboxEnabled = false
        UserPreferences.relayInboxEnabled = false
        nextAllowedRefreshDate = nil
        restartAutoRefresh()
        refresh(force: true)
    }

    func revokeRelayInbox() {
        guard let configuration = currentRelayConfiguration, !relayInboxSetupBusy else { return }
        let generation = accountGeneration
        relayInboxSetupBusy = true
        Task {
            defer { relayInboxSetupBusy = false }
            do {
                try await RelayInboxClient(configuration: configuration).revoke()
                guard accountGeneration == generation, currentRelayConfiguration == configuration else { return }
                disableRelayInbox()
            } catch {
                if accountGeneration == generation {
                    lastError = "Server inbox deletion was not confirmed. You can still disable sync on this Mac. " + error.localizedDescription
                }
            }
        }
    }

    private func startRelay() {
        relayDevice.activate(origin: UserPreferences.relayOrigin)
        relayConfiguration = currentRelayConfiguration
        guard let relayConfiguration else {
            relayConnectionState = hasRelayConfiguration ? .authorizationRequired : .inactive
            return
        }
        relayConnectionState = .connecting
        relayStream.start(configuration: relayConfiguration, inbox: relayInboxEnabled) { [weak self] event in
            guard let self, self.autoRefreshEnabled else { return }
            if event == .expired {
                self.relayStream.stop()
                self.relayConnectionState = .authorizationRequired
                self.scheduleNextAutoRefresh()
                self.relayDevice.accessExpired()
                return
            }
            if event == .connected {
                self.relayConnectionState = .connected
                self.scheduleNextAutoRefresh()
            } else if event == nil {
                self.relayConnectionState = .reconnecting
                // Repeated failed handshakes must not postpone the fallback poll.
                if self.autoRefreshTask == nil { self.scheduleNextAutoRefresh() }
                return
            }
            self.relayDemand.request()
            self.drainRelayRefresh()
        }
    }

    private func drainRelayRefresh() {
        guard autoRefreshEnabled, relayDemand.isPending, !isLoading else { return }
        relayRetryTask?.cancel()
        if let date = nextAllowedRefreshDate, date > Date() {
            relayRetryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(date.timeIntervalSinceNow))
                guard !Task.isCancelled else { return }
                self?.drainRelayRefresh()
            }
            return
        }
        guard relayDemand.take(isLoading: isLoading, now: Date(), notBefore: nextAllowedRefreshDate) else { return }
        refresh(reason: .relay)
    }

    func startAutoRefresh() {
        guard isAuthenticated else {
            return
        }

        guard !autoRefreshEnabled else {
            return
        }

        autoRefreshEnabled = true
        startRelay()
        refresh(reason: .initialLoad)
        scheduleNextAutoRefresh()
    }

    func restartAutoRefresh() {
        guard isAuthenticated else {
            return
        }

        stopAutoRefresh()
        startAutoRefresh()
    }

    func stopAutoRefresh() {
        autoRefreshEnabled = false
        relayDevice.suspend()
        relayStream.stop()
        relayConnectionState = .inactive
        relayDemand = RelayRefreshDemand()
        relayRetryTask?.cancel()
        relayRetryTask = nil

        refreshTask?.cancel()
        autoRefreshTask?.cancel()
        refreshTask = nil
        refreshRequestID = nil
        autoRefreshTask = nil
        highFrequencyRefreshUntil = nil
        isLoading = false
        refreshDiagnostics = refreshDiagnostics.stopped()
    }

    func refreshAfterUserInteraction() {
        markHighFrequencyRefresh()
        rescheduleAutoRefreshIfRunning()
        refresh(reason: .userInteraction)
    }

    func refreshAfterSystemEvent() {
        guard isAuthenticated else {
            return
        }

        markHighFrequencyRefresh()
        rescheduleAutoRefreshIfRunning()
        refresh(reason: .systemEvent)
    }

    private func scheduleNextAutoRefresh() {
        autoRefreshTask?.cancel()

        guard isAuthenticated, autoRefreshEnabled, !relayConnected || relayInboxEnabled else {
            autoRefreshTask = nil
            refreshDiagnostics = refreshDiagnostics.withNextScheduledRefresh(nil)
            return
        }

        let delay = nextAutoRefreshDelay()
        let nextFireDate = Date().addingTimeInterval(delay)
        refreshDiagnostics = refreshDiagnostics.withNextScheduledRefresh(nextFireDate)
        autoRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            await MainActor.run {
                guard let self, !Task.isCancelled else {
                    return
                }

                self.autoRefreshTask = nil
                self.refresh(reason: .timer)
                self.scheduleNextAutoRefresh()
            }
        }
    }

    private func rescheduleAutoRefreshIfRunning() {
        guard autoRefreshTask != nil else {
            return
        }

        scheduleNextAutoRefresh()
    }

    private func nextAutoRefreshDelay(now: Date = Date()) -> TimeInterval {
        if let nextAllowedRefreshDate, nextAllowedRefreshDate > now {
            return max(Self.minimumRefreshSpacing, nextAllowedRefreshDate.timeIntervalSince(now))
        }

        if relayInboxEnabled { return 30 }
        if hasRelayConfiguration { return 60 }

        let hasTesting = pullRequests.contains(where: { $0.group == .testing })

        if isHighFrequencyRefreshWindowActive(now: now) || isExpanded || hasTesting {
            return Self.highFrequencyRefreshSpacing
        }

        return max(Self.minimumRefreshSpacing, TimeInterval(refreshIntervalSeconds))
    }

    private func isHighFrequencyRefreshWindowActive(now: Date = Date()) -> Bool {
        guard let highFrequencyRefreshUntil else {
            return false
        }

        if highFrequencyRefreshUntil > now {
            return true
        }

        self.highFrequencyRefreshUntil = nil
        return false
    }

    private func markHighFrequencyRefresh(now: Date = Date()) {
        let refreshUntil = now.addingTimeInterval(Self.highFrequencyRefreshWindow)
        highFrequencyRefreshUntil = max(highFrequencyRefreshUntil ?? refreshUntil, refreshUntil)
    }

#if DEBUG
    func triggerDebugArrivalRipple() {
        let visibleGroups = Set(PullRequestGroup.allCases.filter { count(for: $0) > 0 })
        let fallbackGroup = selectedGroup
        let groups = visibleGroups.isEmpty ? Set([fallbackGroup]) : visibleGroups

        if let group = groups.sorted(by: { $0.compactPriority < $1.compactPriority }).first {
            selectedGroup = group
        }
        showsAllPullRequests = false
        debugRipplePreviewGroup = visibleGroups.isEmpty ? fallbackGroup : nil
        isExpanded = false
        publishArrivalPulse(PullRequestArrivalPulse(groups: groups))
    }

    func triggerDebugStatusChangeCue() {
        triggerDebugArrivalRipple()
    }

    func triggerDebugMergeCelebration() {
        publishMergeCelebration(for: -1)
    }
#endif

    func refresh(force: Bool = false, reason: RefreshReason = .manual) {
        let now = Date()
        let startDecision = RefreshGate.startDecision(
            isAuthenticated: isAuthenticated,
            isLoading: isLoading,
            force: force,
            now: now,
            nextAllowedRefreshDate: nextAllowedRefreshDate,
            lastRefreshAttemptDate: lastRefreshAttemptDate,
            minimumSpacing: reason == .relay ? 0 : Self.minimumRefreshSpacing
        )

        switch startDecision {
        case .skipUnauthenticated:
            lastError = "Sign in to load pull requests"
            refreshDiagnostics = refreshDiagnostics.withLastMessage(lastError)
            return
        case .skipLoading:
            refreshDiagnostics = refreshDiagnostics.withLastMessage("Refresh skipped: request already running")
            return
        case .skipRateLimited:
            guard let nextAllowedRefreshDate else {
                return
            }
            lastError = relayInboxEnabled ? "Relay inbox sync is paused until the next allowed retry." : Self.rateLimitMessage(until: nextAllowedRefreshDate)
            refreshDiagnostics = refreshDiagnostics
                .withNextScheduledRefresh(nextAllowedRefreshDate)
                .withLastMessage(lastError)
            return
        case .skipMinimumSpacing:
            refreshDiagnostics = refreshDiagnostics.withLastMessage("Refresh skipped: minimum spacing")
            return
        case .cancelInFlightAndStart:
            refreshTask?.cancel()
            refreshTask = nil
            refreshRequestID = nil
            isLoading = false
        case .start:
            break
        }

        if force {
            markHighFrequencyRefresh()
            rescheduleAutoRefreshIfRunning()
        }

        isLoading = true
        lastError = nil
        lastRefreshAttemptDate = now
        refreshDiagnostics = refreshDiagnostics.started(at: now, reason: reason)
        let requestID = UUID()
        refreshRequestID = requestID
        let currentLogin = githubLogin
        let repositoryFullNames = repositoryFilterMode == .selected ? selectedRepositoryFullNames : nil

        let inboxEnabled = relayInboxEnabled
        let inboxConfiguration = currentRelayConfiguration
        let inboxSubject = relayDevice.inboxSubject
        refreshTask = Task { [service, currentLogin, repositoryFullNames] in
            do {
                let fetchStart = Date()
                let pullRequests: [PullRequest]
                if inboxEnabled {
                    guard let inboxConfiguration, let currentLogin, let inboxSubject else { throw RelayInboxError.deviceNotReady }
                    let snapshot = try await RelayInboxClient(configuration: inboxConfiguration).fetch(login: currentLogin, subject: inboxSubject, refresh: reason == .merge || reason == .updateBranch || reason == .manual)
                    let inbox = service.inboxPullRequests(from: snapshot.data, currentLogin: snapshot.login)
                    if let repositoryFullNames {
                        let names = Set(repositoryFullNames.map { $0.lowercased() })
                        pullRequests = inbox.filter { names.contains($0.repositoryFullName.lowercased()) }
                    } else { pullRequests = inbox }
                } else {
                    pullRequests = try await service.fetchPullRequests(currentLogin: currentLogin, repositoryFullNames: repositoryFullNames)
                }
                let fetchEnd = Date()
                let fetchDuration = fetchEnd.timeIntervalSince(fetchStart)
                let hits304 = await service.last304HitCount

                await MainActor.run {
                    guard self.refreshRequestID == requestID else {
                        return
                    }

                    let previousSignature = self.inboxSignature(from: self.pullRequests)
                    self.reconcileHiddenPullRequests(with: pullRequests)
                    let visiblePullRequests = self.visiblePullRequests(from: pullRequests)
                    let nextSignature = self.inboxSignature(from: visiblePullRequests)
                    let arrivalPulse = self.arrivalPulse(for: visiblePullRequests)
                    let soundEvent = self.soundEvent(for: visiblePullRequests)
                    self.clearConfirmedHiddenPullRequests(from: pullRequests)
                    self.pullRequests = visiblePullRequests
                    self.isLoading = false
                    self.refreshTask = nil
                    self.refreshRequestID = nil
                    self.nextAllowedRefreshDate = nil
                    let finishedAt = Date()
                    self.lastRefreshDate = finishedAt
                    var diags = self.refreshDiagnostics.finished(
                        at: finishedAt,
                        startedAt: now,
                        message: "Loaded \(visiblePullRequests.count) PRs"
                    )
                    diags = diags.withNumCandidates(pullRequests.count)
                        .with304Hits(hits304)
                        .withBreakdown("fetch: \(String(format: "%.2fs", fetchDuration))")
                    self.refreshDiagnostics = diags
                    self.selectedGroup = self.preferredGroup(requested: self.selectedGroup)

                    if pullRequests.isEmpty {
                        self.isExpanded = false
                        self.showsAllPullRequests = false
                        self.resetPanelPresentationState()
                    } else if self.isExpanded {
                        self.retainExpandedSessionPanelHeight()
                    }

                    if previousSignature != nextSignature || visiblePullRequests.contains(where: { $0.group == .testing }) {
                        self.markHighFrequencyRefresh()
                    }

                    self.publishArrivalPulse(arrivalPulse)
                    self.playSound(for: soundEvent)
                    self.rescheduleAutoRefreshIfRunning()
                    self.drainRelayRefresh()
                    NotificationCenter.default.post(name: .gitIslandPullRequestsDidChange, object: nil)
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self.refreshRequestID == requestID else {
                        return
                    }

                    self.isLoading = false
                    self.refreshTask = nil
                    self.refreshRequestID = nil
                    self.refreshDiagnostics = self.refreshDiagnostics.cancelled()
                    self.drainRelayRefresh()
                }
            } catch {
                await MainActor.run {
                    guard self.refreshRequestID == requestID else {
                        return
                    }

                    self.isLoading = false
                    self.refreshTask = nil
                    self.refreshRequestID = nil
                    let finishedAt = Date()
                    if let relayError = error as? RelayInboxError {
                        switch relayError {
                        case .deviceExpired: self.relayDevice.accessExpired()
                        case .unavailable(let date): self.nextAllowedRefreshDate = date
                        case .authorizationRequired, .deviceNotReady, .invalidResponse: break
                        }
                    }
                    if let gitHubError = error as? GitHubServiceError,
                       gitHubError.isRateLimited {
                        let minimumRetryDate = Date().addingTimeInterval(Self.minimumRefreshSpacing)
                        let retryDate = gitHubError.retryAfterDate ?? Date().addingTimeInterval(Self.rateLimitFallbackBackoff)
                        self.nextAllowedRefreshDate = max(retryDate, minimumRetryDate)
                        if self.relayConfiguration != nil { self.relayDemand.request() }
                    }
                    if case .api(statusCode: 401, message: _, retryAfterDate: _) = error as? GitHubServiceError {
                        self.signOut()
                        self.githubAuthorizationRequired = true
                    }
                    self.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.refreshDiagnostics = self.refreshDiagnostics.finished(
                        at: finishedAt,
                        startedAt: now,
                        message: self.lastError
                    )
                    if let nextAllowedRefreshDate = self.nextAllowedRefreshDate {
                        self.refreshDiagnostics = self.refreshDiagnostics.withNextScheduledRefresh(nextAllowedRefreshDate)
                    }
                    self.rescheduleAutoRefreshIfRunning()
                    self.drainRelayRefresh()
                }
            }
        }
    }

    func isMerging(_ pullRequest: PullRequest) -> Bool {
        mergingPullRequestIDs.contains(pullRequest.id)
    }

    func isUpdatingBranch(_ pullRequest: PullRequest) -> Bool {
        updatingBranchPullRequestIDs.contains(pullRequest.id)
    }

    func merge(_ pullRequest: PullRequest) {
        guard pullRequest.defaultMergeMethod != nil else {
            lastError = GitHubServiceError.mergeUnavailable.errorDescription
            return
        }

        guard !mergingPullRequestIDs.contains(pullRequest.id) else {
            return
        }

        publishMergeCelebration(for: pullRequest.id)
        playSound(for: .merged)
        mergingPullRequestIDs.insert(pullRequest.id)
        markHighFrequencyRefresh()
        rescheduleAutoRefreshIfRunning()
        optimisticallyHideMergedPullRequest(pullRequest)
        lastError = nil

        let generation = accountGeneration
        Task { [service] in
            do {
                try await service.merge(pullRequest)

                await MainActor.run {
                    guard self.accountGeneration == generation, self.isAuthenticated else { return }
                    self.mergingPullRequestIDs.remove(pullRequest.id)
                    self.optimisticMergeBackups[pullRequest.id] = nil
                    self.scheduleLocalHiddenPullRequestClear(for: pullRequest.id)
                    self.selectedGroup = self.preferredGroup(requested: self.selectedGroup)
                    self.refresh(force: true, reason: .merge)
                }
            } catch {
                await MainActor.run {
                    guard self.accountGeneration == generation, self.isAuthenticated else { return }
                    self.mergingPullRequestIDs.remove(pullRequest.id)
                    self.restoreOptimisticallyHiddenPullRequest(id: pullRequest.id)
                    if let gitHubError = error as? GitHubServiceError,
                       gitHubError.isRateLimited {
                        let minimumRetryDate = Date().addingTimeInterval(Self.minimumRefreshSpacing)
                        let retryDate = gitHubError.retryAfterDate ?? Date().addingTimeInterval(Self.rateLimitFallbackBackoff)
                        self.nextAllowedRefreshDate = max(retryDate, minimumRetryDate)
                    }
                    if case .api(statusCode: 401, message: _, retryAfterDate: _) = error as? GitHubServiceError {
                        self.signOut()
                        self.githubAuthorizationRequired = true
                    }
                    self.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func publishMergeCelebration(for pullRequestID: Int) {
        mergeCelebrationClearTask?.cancel()
        mergeCelebration = PullRequestMergeCelebration(pullRequestID: pullRequestID)
        mergeCelebrationClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else {
                return
            }

            mergeCelebration = nil
            mergeCelebrationClearTask = nil
        }
    }

    func updateBranch(_ pullRequest: PullRequest) {
        guard pullRequest.canUpdateBranch else {
            lastError = GitHubServiceError.branchUpdateUnavailable.errorDescription
            return
        }

        guard !updatingBranchPullRequestIDs.contains(pullRequest.id) else {
            return
        }

        updatingBranchPullRequestIDs.insert(pullRequest.id)
        markHighFrequencyRefresh()
        rescheduleAutoRefreshIfRunning()
        lastError = nil

        let generation = accountGeneration
        Task { [service] in
            do {
                try await service.updateBranch(pullRequest)

                await MainActor.run {
                    guard self.accountGeneration == generation, self.isAuthenticated else { return }
                    self.updatingBranchPullRequestIDs.remove(pullRequest.id)
                    self.markBranchUpdateQueued(pullRequest)
                    self.refresh(force: true, reason: .updateBranch)
                }
            } catch {
                await MainActor.run {
                    guard self.accountGeneration == generation, self.isAuthenticated else { return }
                    self.updatingBranchPullRequestIDs.remove(pullRequest.id)
                    if let gitHubError = error as? GitHubServiceError,
                       gitHubError.isRateLimited {
                        let minimumRetryDate = Date().addingTimeInterval(Self.minimumRefreshSpacing)
                        let retryDate = gitHubError.retryAfterDate ?? Date().addingTimeInterval(Self.rateLimitFallbackBackoff)
                        self.nextAllowedRefreshDate = max(retryDate, minimumRetryDate)
                    }
                    if case .api(statusCode: 401, message: _, retryAfterDate: _) = error as? GitHubServiceError {
                        self.signOut()
                        self.githubAuthorizationRequired = true
                    }
                    self.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func visiblePullRequests(from fetchedPullRequests: [PullRequest]) -> [PullRequest] {
        InboxFilter.visible(
            fetchedPullRequests,
            mode: repositoryFilterMode,
            selectedRepositories: selectedRepositoryFullNames,
            mutedRepositories: mutedRepositoryFullNames,
            hiddenPullRequests: hiddenPullRequests,
            suppressedIDs: locallyHiddenPullRequestIDs
        )
    }

    private func reconcileHiddenPullRequests(with fetchedPullRequests: [PullRequest]) {
        let reconciled = InboxFilter.reconciledHiddenPullRequests(
            hiddenPullRequests,
            fetched: fetchedPullRequests
        )
        guard reconciled != hiddenPullRequests else {
            return
        }

        hiddenPullRequests = reconciled
        UserPreferences.hiddenPullRequests = reconciled
        hiddenPullRequests = UserPreferences.hiddenPullRequests
    }

    private func applyRepositoryFilterToLoadedPullRequests() {
        pullRequests = visiblePullRequests(from: pullRequests)
        selectedGroup = preferredGroup(requested: selectedGroup)

        if pullRequests.isEmpty {
            isExpanded = false
            showsAllPullRequests = false
            resetPanelPresentationState()
        } else if isExpanded {
            retainExpandedSessionPanelHeight()
        }
    }

    private func refreshAfterRepositoryScopeChange() {
        guard isAuthenticated else {
            return
        }

        locallyHiddenPullRequestIDs = []
        locallyHiddenPullRequestClearTasks.values.forEach { $0.cancel() }
        locallyHiddenPullRequestClearTasks = [:]
        optimisticMergeBackups = [:]
        refresh(force: true, reason: .repositoryScope)
    }

    private func inboxSignature(from pullRequests: [PullRequest]) -> Set<PullRequestSignature> {
        Set(
            pullRequests.map {
                PullRequestSignature(
                    id: $0.id,
                    group: $0.group,
                    headSHA: $0.headSHA,
                    reason: $0.reason,
                    statusLabel: $0.statusLabel
                )
            }
        )
    }

    private func optimisticallyHideMergedPullRequest(_ pullRequest: PullRequest) {
        locallyHiddenPullRequestIDs.insert(pullRequest.id)
        optimisticMergeBackups[pullRequest.id] = pullRequest
        pullRequests.removeAll { $0.id == pullRequest.id }
        selectedGroup = preferredGroup(requested: selectedGroup)

        if pullRequests.isEmpty {
            isExpanded = false
            showsAllPullRequests = false
            resetPanelPresentationState()
        } else if isExpanded {
            retainExpandedSessionPanelHeight()
        }
    }

    private func markBranchUpdateQueued(_ pullRequest: PullRequest) {
        guard let index = pullRequests.firstIndex(where: { $0.id == pullRequest.id }) else {
            return
        }

        pullRequests[index] = pullRequests[index].branchUpdateQueued()
        selectedGroup = preferredGroup(requested: selectedGroup)

        if isExpanded {
            retainExpandedSessionPanelHeight()
        }
    }

    private func restoreOptimisticallyHiddenPullRequest(id: Int) {
        locallyHiddenPullRequestIDs.remove(id)
        locallyHiddenPullRequestClearTasks[id]?.cancel()
        locallyHiddenPullRequestClearTasks[id] = nil

        guard let pullRequest = optimisticMergeBackups.removeValue(forKey: id) else {
            return
        }

        if !pullRequests.contains(where: { $0.id == id }) {
            pullRequests.append(pullRequest)
        }

        selectedGroup = preferredGroup(requested: selectedGroup)
    }

    private func clearConfirmedHiddenPullRequests(from fetchedPullRequests: [PullRequest]) {
        let fetchedIDs = Set(fetchedPullRequests.map(\.id))
        let confirmedHiddenIDs = locallyHiddenPullRequestIDs.filter {
            !fetchedIDs.contains($0) && !mergingPullRequestIDs.contains($0)
        }

        for id in confirmedHiddenIDs {
            locallyHiddenPullRequestIDs.remove(id)
            locallyHiddenPullRequestClearTasks[id]?.cancel()
            locallyHiddenPullRequestClearTasks[id] = nil
        }
    }

    private func scheduleLocalHiddenPullRequestClear(for id: Int) {
        locallyHiddenPullRequestClearTasks[id]?.cancel()
        locallyHiddenPullRequestClearTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.locallyHiddenPullRequestTTL)

            await MainActor.run {
                self?.locallyHiddenPullRequestIDs.remove(id)
                self?.locallyHiddenPullRequestClearTasks[id] = nil
            }
        }
    }

    func updateNotchMetrics(
        leftWingWidth: CGFloat,
        rightWingWidth: CGFloat,
        gapWidth: CGFloat,
        topBandHeight: CGFloat
    ) {
        let safeGap = max(gapWidth, 40)
        let safeHeight = min(
            max(IslandDesignSystem.minimumCompactBandHeight, topBandHeight),
            IslandDesignSystem.maximumCompactBandHeight
        )

        if self.leftWingWidth != leftWingWidth {
            self.leftWingWidth = leftWingWidth
        }

        if self.rightWingWidth != rightWingWidth {
            self.rightWingWidth = rightWingWidth
        }

        if notchGapWidth != safeGap {
            notchGapWidth = safeGap
        }

        if self.topBandHeight != safeHeight {
            self.topBandHeight = safeHeight
        }
    }

    private func loadGitHubIdentity(token providedToken: String? = nil) async {
        guard let token = providedToken ?? TokenStore.token() else {
            return
        }

        let generation = accountGeneration
        do {
            let login = try await authService.currentLogin(token: token)
            guard generation == accountGeneration, isAuthenticated else { return }
            githubLogin = login
        } catch {
            guard generation == accountGeneration, isAuthenticated else { return }
            if case .api(statusCode: 401, message: _, retryAfterDate: _) = error as? GitHubServiceError {
                signOut()
                githubAuthorizationRequired = true
            }
            githubLogin = nil
        }
    }

    private var primaryActiveGroup: PullRequestGroup? {
        [.blocked, .waiting, .testing, .ready].first { count(for: $0) > 0 }
    }

    private var maximumExpandedContentHeight: CGFloat {
        if showsBlockingError {
            return IslandDesignSystem.expandedHeight(
                rowCount: 0,
                topBandHeight: compactBandHeight,
                showsMessageBody: true
            )
        }

        if isLoading && pullRequests.isEmpty {
            return IslandDesignSystem.expandedHeight(
                rowCount: 1,
                topBandHeight: compactBandHeight,
                showsMessageBody: false
            )
        }

        let largestGroupCount = PullRequestGroup.allCases
            .map { count(for: $0) }
            .max() ?? 0
        let maxSelectableCount = max(largestGroupCount, allPullRequests.count)

        return IslandDesignSystem.expandedHeight(
            rowCount: maxSelectableCount,
            topBandHeight: compactBandHeight,
            showsMessageBody: false,
            showsSummaryBar: maxSelectableCount > 0
        )
    }

    private func retainExpandedSessionPanelHeight() {
        let targetHeight = maximumExpandedContentHeight + IslandDesignSystem.surfaceOvershootHeadroom
        guard targetHeight > collapsedHeight + 1 else {
            expandedSessionPanelChromeHeight = nil
            return
        }

        expandedSessionPanelChromeHeight = max(
            expandedSessionPanelChromeHeight ?? 0,
            targetHeight,
            chromeHeight
        )
    }

    private func resolvedGroup(for group: PullRequestGroup) -> PullRequestGroup {
        count(for: group) > 0 ? group : (primaryActiveGroup ?? group)
    }

    private func preferredGroup(requested group: PullRequestGroup) -> PullRequestGroup {
        resolvedGroup(for: group)
    }

    private func arrivalPulse(for newPullRequests: [PullRequest]) -> PullRequestArrivalPulse? {
        guard lastRefreshDate != nil else { return nil }
        let previousGroups = Dictionary(uniqueKeysWithValues: pullRequests.map { ($0.id, $0.group) })
        let changes = newPullRequests.filter { previousGroups[$0.id] != $0.group }

        guard !changes.isEmpty else {
            return nil
        }

        let oldSegments = outlineSegments
        let newCounts = Dictionary(grouping: newPullRequests, by: \.group).mapValues(\.count)
        let newSegments = IslandDesignSystem.outlineSegments(counts: newCounts, maxLanes: outlineLaneStyle.maxLanes)
        var sweeps: [PullRequestOutlineSweep] = []

        for pullRequest in changes {
            let candidates: [PullRequestOutlineSweep]
            if let previousGroup = previousGroups[pullRequest.id],
               let origin = oldSegments.first(where: { $0.group == previousGroup }),
               let destination = newSegments.first(where: { $0.group == pullRequest.group }) {
                candidates = [PullRequestOutlineSweep(from: origin.midpoint, to: destination.midpoint)]
            } else {
                candidates = PullRequestOutlineSweep.arrival
            }

            for sweep in candidates where !sweeps.contains(sweep) {
                sweeps.append(sweep)
            }
        }

        return PullRequestArrivalPulse(
            groups: Set(changes.map(\.group)),
            sweeps: Array(sweeps.prefix(4))
        )
    }

    /// Same change detection as the arrival pulse: nothing on the first load.
    private func soundEvent(for newPullRequests: [PullRequest]) -> IslandSoundEvent? {
        guard lastRefreshDate != nil else { return nil }
        let previousGroups = Dictionary(uniqueKeysWithValues: pullRequests.map { ($0.id, $0.group) })

        return newPullRequests
            .compactMap { pullRequest -> IslandSoundEvent? in
                guard let previousGroup = previousGroups[pullRequest.id] else {
                    return .newPullRequest
                }
                return previousGroup == pullRequest.group ? nil : .statusChange(to: pullRequest.group)
            }
            .max { $0.priority < $1.priority }
    }

    private func publishArrivalPulse(_ pulse: PullRequestArrivalPulse?) {
        guard let pulse else {
            return
        }

        arrivalPulse = pulse
        arrivalPulseClearTask?.cancel()
        arrivalPulseClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)

            await MainActor.run {
                guard self?.arrivalPulse?.id == pulse.id else {
                    return
                }

                self?.arrivalPulse = nil
                self?.arrivalPulseClearTask = nil
#if DEBUG
                self?.debugRipplePreviewGroup = nil
#endif
            }
        }
    }

    private static func rateLimitMessage(until date: Date) -> String {
        "GitHub rate limit reached. Next refresh after \(timeFormatter.string(from: date))."
    }

    private static func userFacingRefreshError(_ message: String) -> String {
        let lowercasedMessage = message.lowercased()

        if lowercasedMessage.contains("rate limit") {
            return "GitHub is limiting requests. The app will retry automatically."
        }

        if lowercasedMessage.contains("bad credentials") || lowercasedMessage.contains("401") {
            return "GitHub sign-in expired. Sign in again."
        }

        if lowercasedMessage.contains("403") {
            return "GitHub refused this request. The app will retry automatically."
        }

        return "GitHub refresh failed. Try again."
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

extension Notification.Name {
    static let gitIslandPullRequestsDidChange = Notification.Name("gitIslandPullRequestsDidChange")
}

enum RefreshStartDecision: Equatable {
    case start
    case cancelInFlightAndStart
    case skipUnauthenticated
    case skipLoading
    case skipRateLimited
    case skipMinimumSpacing
}

struct RefreshGate {
    static func startDecision(
        isAuthenticated: Bool,
        isLoading: Bool,
        force: Bool,
        now: Date,
        nextAllowedRefreshDate: Date?,
        lastRefreshAttemptDate: Date?,
        minimumSpacing: TimeInterval
    ) -> RefreshStartDecision {
        guard isAuthenticated else {
            return .skipUnauthenticated
        }

        if let nextAllowedRefreshDate, now < nextAllowedRefreshDate {
            return .skipRateLimited
        }

        if isLoading {
            return force ? .cancelInFlightAndStart : .skipLoading
        }

        if !force,
           let lastRefreshAttemptDate,
           now.timeIntervalSince(lastRefreshAttemptDate) < minimumSpacing {
            return .skipMinimumSpacing
        }

        return .start
    }
}

enum RelayConnectionState {
    case authorizationRequired
    case inactive
    case connecting
    case connected
    case reconnecting
}

enum RefreshReason: Equatable {
    case relay
    case initialLoad
    case timer
    case manual
    case userInteraction
    case systemEvent
    case repositoryScope
    case merge
    case updateBranch

    var label: String {
        switch self {
        case .relay:
            "Relay wake"
        case .initialLoad:
            "Initial load"
        case .timer:
            "Timer"
        case .manual:
            "Manual"
        case .userInteraction:
            "Interaction"
        case .systemEvent:
            "System event"
        case .repositoryScope:
            "Repository scope"
        case .merge:
            "Merge"
        case .updateBranch:
            "Update branch"
        }
    }
}

struct RefreshDiagnostics: Equatable {
    var lastStartedAt: Date?
    var lastFinishedAt: Date?
    var lastDuration: TimeInterval?
    var nextScheduledAt: Date?
    var reason: RefreshReason?
    var isInFlight = false
    var lastMessage: String?
    var numCandidates: Int?
    var num304Hits: Int?
    var refreshBreakdown: String?

    var inFlightText: String {
        isInFlight ? "Yes" : "No"
    }

    var reasonText: String {
        reason?.label ?? "None"
    }

    var lastStartedText: String {
        Self.format(lastStartedAt)
    }

    var lastFinishedText: String {
        Self.format(lastFinishedAt)
    }

    var lastDurationText: String {
        guard let lastDuration else {
            return "None"
        }

        if lastDuration < 1 {
            return String(format: "%.2fs", lastDuration)
        }

        return String(format: "%.1fs", lastDuration)
    }

    var nextScheduledText: String {
        Self.format(nextScheduledAt, empty: "Not scheduled")
    }

    var lastMessageText: String {
        lastMessage ?? "None"
    }

    var debugText: String {
        [
            "In flight: \(inFlightText)",
            "Reason: \(reasonText)",
            "Last started: \(lastStartedText)",
            "Last finished: \(lastFinishedText)",
            "Last duration: \(lastDurationText)",
            "Next scheduled: \(nextScheduledText)",
            "Last message: \(lastMessage == nil ? "None" : "Omitted for privacy")",
            "Candidates: \(numCandidates.map(String.init) ?? "None")",
            "304 hits: \(num304Hits.map(String.init) ?? "None")",
            "Breakdown: \(refreshBreakdown == nil ? "None" : "Omitted for privacy")"
        ].joined(separator: "\n")
    }

    func started(at date: Date, reason: RefreshReason) -> RefreshDiagnostics {
        var diagnostics = self
        diagnostics.lastStartedAt = date
        diagnostics.reason = reason
        diagnostics.isInFlight = true
        diagnostics.lastMessage = "Refresh started"
        return diagnostics
    }

    func finished(at finishedAt: Date, startedAt: Date, message: String?) -> RefreshDiagnostics {
        var diagnostics = self
        diagnostics.lastFinishedAt = finishedAt
        diagnostics.lastDuration = max(0, finishedAt.timeIntervalSince(startedAt))
        diagnostics.isInFlight = false
        diagnostics.lastMessage = message
        return diagnostics
    }

    func cancelled() -> RefreshDiagnostics {
        var diagnostics = self
        diagnostics.isInFlight = false
        diagnostics.lastMessage = "Refresh cancelled"
        return diagnostics
    }

    func stopped() -> RefreshDiagnostics {
        var diagnostics = self
        diagnostics.isInFlight = false
        diagnostics.nextScheduledAt = nil
        diagnostics.lastMessage = "Refresh stopped"
        return diagnostics
    }

    func withNextScheduledRefresh(_ date: Date?) -> RefreshDiagnostics {
        var diagnostics = self
        diagnostics.nextScheduledAt = date
        return diagnostics
    }

    func withLastMessage(_ message: String?) -> RefreshDiagnostics {
        var diagnostics = self
        diagnostics.lastMessage = message
        return diagnostics
    }

    func withNumCandidates(_ count: Int?) -> RefreshDiagnostics {
        var diagnostics = self
        diagnostics.numCandidates = count
        return diagnostics
    }

    func with304Hits(_ count: Int?) -> RefreshDiagnostics {
        var diagnostics = self
        diagnostics.num304Hits = count
        return diagnostics
    }

    func withBreakdown(_ breakdown: String?) -> RefreshDiagnostics {
        var diagnostics = self
        diagnostics.refreshBreakdown = breakdown
        return diagnostics
    }

    private static func format(_ date: Date?, empty: String = "Never") -> String {
        guard let date else {
            return empty
        }

        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}

private struct PullRequestSignature: Hashable {
    let id: Int
    let group: PullRequestGroup
    let headSHA: String
    let reason: String
    let statusLabel: String
}
