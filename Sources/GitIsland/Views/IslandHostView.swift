import AppKit
import SwiftUI

struct IslandHostView: View {
    @ObservedObject var store: GitIslandStore

    var body: some View {
        IslandChromeView(store: store)
            .frame(
                width: store.panelFrameSize.width,
                height: store.panelFrameSize.height,
                alignment: .top
            )
    }
}

private struct IslandChromeView: View {
    @ObservedObject var store: GitIslandStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var surfaceHeight: CGFloat
    @State private var surfaceWidthProgress: CGFloat
    @State private var surfaceAnimationID = UUID()
    @State private var morphTask: Task<Void, Never>?
    @Namespace private var counterGlass

    init(store: GitIslandStore) {
        self.store = store
        _surfaceHeight = State(initialValue: store.chromeHeight)
        _surfaceWidthProgress = State(initialValue: store.isExpanded ? 1 : 0)
    }

    private var morphTarget: MorphTarget {
        MorphTarget(isExpanded: store.isExpanded, height: store.chromeHeight)
    }

    private var placements: [IslandDesignSystem.CounterPlacement] {
        store.counterPlacements()
    }

    private var detailIdentity: String {
        store.showsAllPullRequests ? "all" : store.selectedGroup.id
    }

    private var detailFadeAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.10) : IslandDesignSystem.contentAnimation
    }

    var body: some View {
        chromeLayer
        .frame(
            width: store.panelFrameSize.width,
            height: store.panelFrameSize.height,
            alignment: .topLeading
        )
        .environment(\.colorScheme, .dark)
        // This utility stays interactive while another app owns the key window.
        .environment(\.appearsActive, true)
        .onChange(of: morphTarget) { previous, target in
            morph(from: previous, to: target)
        }
        .onChange(of: reduceMotion) { _, _ in
            morph(from: morphTarget, to: morphTarget)
        }
    }

    private var chromeLayer: some View {
        ZStack(alignment: .topLeading) {
            // Counters are detail: they only appear once hover expands the island.
            GlassEffectContainer(spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if store.isExpanded {
                        ForEach(placements) { placement in
                            counterButton(for: placement)
                        }
                        .transition(.opacity)
                    }
                }
                .frame(width: store.panelFrameSize.width, height: store.compactBandHeight)
            }
            .animation(reduceMotion ? nil : IslandDesignSystem.controlAnimation, value: detailIdentity)
            .animation(detailFadeAnimation, value: store.isExpanded)

            ZStack(alignment: .topLeading) {
                if store.showsExpandedBody {
                    GlassEffectContainer(spacing: 8) {
                        detailPanel
                    }
                    .id(detailIdentity)
                    .transition(.opacity)
                }
            }
            .frame(width: store.panelFrameSize.width - bodyHorizontalInset * 2, alignment: .topLeading)
            .offset(
                x: bodyHorizontalInset,
                y: store.compactBandHeight + IslandDesignSystem.panelTopInset
            )
            .animation(detailFadeAnimation, value: detailIdentity)
            .animation(detailFadeAnimation, value: store.showsExpandedBody)
        }
        .frame(
            width: store.panelFrameSize.width,
            height: store.panelFrameSize.height,
            alignment: .topLeading
        )
        .modifier(
            IslandSurfacePresentation(
                height: surfaceHeight,
                widthProgress: surfaceWidthProgress,
                topBandHeight: store.compactBandHeight,
                compactHeight: store.collapsedHeight,
                compactSurfaceFrame: store.compactSurfaceFrame(),
                outline: IslandOutlineConfiguration(
                    segments: store.outlineSegments,
                    laneStyle: store.outlineLaneStyle,
                    pulse: store.arrivalPulse,
                    usesCrazyAnimations: store.crazyAnimationsEnabled,
                    accessibilityLabel: outlineAccessibilityLabel
                ),
                onHeightChange: store.updatePresentedChromeHeight,
                onWidthProgressChange: store.updatePresentedWidthProgress
            )
        )
    }

    private var outlineAccessibilityLabel: String {
        IslandDesignSystem.outlineOrder
            .filter { store.count(for: $0) > 0 }
            .map { "\($0.rawValue), \(store.count(for: $0))" }
            .joined(separator: "; ")
    }

    private var bodyHorizontalInset: CGFloat {
        IslandDesignSystem.surfaceOvershootInset + IslandDesignSystem.panelHorizontalInset
    }

    /// Opening widens first, then drops; closing rises first, then narrows.
    /// Collapse presentation completes when the last (width) spring settles.
    private func morph(from previous: MorphTarget, to target: MorphTarget) {
        morphTask?.cancel()
        let animationID = UUID()
        surfaceAnimationID = animationID
        let widthTarget: CGFloat = target.isExpanded ? 1 : 0

        guard !reduceMotion else {
            surfaceWidthProgress = widthTarget
            surfaceHeight = target.height
            if !target.isExpanded {
                store.completeCollapsePresentation()
            }
            return
        }

        if target.isExpanded, !previous.isExpanded {
            animateWidth(to: widthTarget, animationID: animationID)
            morphTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(IslandDesignSystem.morphOpenHeightDelay))
                guard !Task.isCancelled else { return }
                withAnimation(IslandDesignSystem.morphAnimation) {
                    surfaceHeight = target.height
                }
            }
        } else if !target.isExpanded, previous.isExpanded {
            withAnimation(IslandDesignSystem.morphAnimation) {
                surfaceHeight = target.height
            }
            morphTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(IslandDesignSystem.morphCloseWidthDelay))
                guard !Task.isCancelled else { return }
                animateWidth(to: widthTarget, animationID: animationID)
            }
        } else {
            withAnimation(IslandDesignSystem.morphAnimation) {
                surfaceHeight = target.height
            }
            animateWidth(to: widthTarget, animationID: animationID)
        }
    }

    private func animateWidth(to progress: CGFloat, animationID: UUID) {
        withAnimation(IslandDesignSystem.morphAnimation, completionCriteria: .removed) {
            surfaceWidthProgress = progress
        } completion: {
            guard surfaceAnimationID == animationID else { return }
            store.completeCollapsePresentation()
        }
    }

    private func counterButton(for placement: IslandDesignSystem.CounterPlacement) -> some View {
        let group = placement.group

        return Button {
            store.toggle(group)
        } label: {
            StatusCounter(
                group: group,
                count: store.count(for: group),
                size: IslandDesignSystem.counterSize,
                isSelected: store.isExpanded && !store.showsAllPullRequests && store.selectedGroup == group,
                glassNamespace: counterGlass,
                pulseID: activeCounterPulseID(for: group),
                usesCrazyAnimations: store.crazyAnimationsEnabled
            )
        }
        .buttonStyle(IslandContentButtonStyle(isCounter: true))
        .position(x: placement.x, y: store.compactBandHeight / 2)
        .accessibilityLabel("\(group.rawValue), \(store.count(for: group))")
    }

    @ViewBuilder
    private var detailPanel: some View {
        if store.showsBlockingError, let lastError = store.lastError {
            IslandMessagePanel(
                message: lastError,
                actionTitle: "Retry",
                action: { store.refresh(force: true) }
            )
        } else if store.isLoading && store.selectedPullRequests.isEmpty {
            IslandLoadingPanel()
        } else {
            VStack(spacing: IslandDesignSystem.expandedBodySpacing) {
                PullRequestSummaryBar(
                    title: store.showsAllPullRequests ? "Pull requests" : store.selectedGroup.rawValue,
                    count: store.selectedPullRequests.count,
                    showsAllAction: !store.showsAllPullRequests && store.activeGroupCount > 1,
                    showAll: store.expandAllPullRequests
                )
                    .frame(height: IslandDesignSystem.expandedSummaryHeight)

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(store.selectedPullRequests.enumerated()), id: \.element.id) { index, pullRequest in
                            PullRequestActionRow(pullRequest: pullRequest, store: store)
                                .overlay(alignment: .top) {
                                    if index > 0 {
                                        Rectangle()
                                            .fill(IslandDesignSystem.divider)
                                            .frame(height: 0.5)
                                            .padding(.leading, 32)
                                            .padding(.trailing, 8)
                                    }
                                }
                        }
                    }
                }
                .frame(height: listHeight)
            }
        }
    }

    private var listHeight: CGFloat {
        let rows = min(store.selectedPullRequests.count, IslandDesignSystem.maxVisibleRows)
        return CGFloat(rows) * IslandDesignSystem.rowHeight
    }

    private func activeCounterPulseID(for group: PullRequestGroup) -> UUID? {
        guard let pulse = store.arrivalPulse, pulse.groups.contains(group) else {
            return nil
        }

        return pulse.id
    }
}

/// The island surface: a top-anchored rectangle with rounded bottom corners that
/// grows from the notch to the expanded panel. Width and height morph on
/// separate springs; the top edge never moves.
struct NotchIslandShape: Shape {
    let topBandHeight: CGFloat
    /// Height of the collapsed surface; corner rounding interpolates from here.
    let compactHeight: CGFloat
    let bodyBottomY: CGFloat
    /// 0 = compact notch width, 1 = expanded width. May overshoot while springing.
    let widthProgress: CGFloat
    let compactSurfaceFrame: CGRect

    func path(in rect: CGRect) -> Path {
        var path = outlinePath(in: rect)
        path.closeSubpath()
        return path
    }

    /// The visible edge without the screen-top segment, drawn left to right:
    /// down the left side, across the bottom, and up the right side. A positive
    /// `inset` traces a parallel line inside the edge (a stroke's centerline).
    func outlinePath(in rect: CGRect, inset: CGFloat = 0) -> Path {
        let outerBottom = min(max(bodyBottomY, compactHeight), rect.maxY)
        let heightProgress = min(1, max(0, (outerBottom - compactHeight) / 60))
        let expandedLeft = rect.minX + IslandDesignSystem.surfaceOvershootInset
        let expandedRight = rect.maxX - IslandDesignSystem.surfaceOvershootInset
        let compactLeft = max(rect.minX, compactSurfaceFrame.minX)
        let compactRight = min(rect.maxX, compactSurfaceFrame.maxX)
        let outerLeft = max(rect.minX, compactLeft + (expandedLeft - compactLeft) * widthProgress)
        let outerRight = min(rect.maxX, compactRight + (expandedRight - compactRight) * widthProgress)
        let compactRadius = min(IslandDesignSystem.compactBottomCornerRadius, topBandHeight * 0.48)
        let outerRadius = min(
            compactRadius + (IslandDesignSystem.bottomCornerRadius - compactRadius) * heightProgress,
            (outerRight - outerLeft) / 2,
            outerBottom
        )
        let left = outerLeft + inset
        let right = outerRight - inset
        let bottom = outerBottom - inset
        let radius = max(0, outerRadius - inset)

        var path = Path()
        path.move(to: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: bottom - radius))
        path.addCurve(
            to: CGPoint(x: left + radius, y: bottom),
            control1: CGPoint(x: left, y: bottom - radius * 0.45),
            control2: CGPoint(x: left + radius * 0.45, y: bottom)
        )
        path.addLine(to: CGPoint(x: right - radius, y: bottom))
        path.addCurve(
            to: CGPoint(x: right, y: bottom - radius),
            control1: CGPoint(x: right - radius * 0.45, y: bottom),
            control2: CGPoint(x: right, y: bottom - radius * 0.45)
        )
        path.addLine(to: CGPoint(x: right, y: rect.minY))
        return path
    }
}

private struct IslandMessagePanel: View {
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Text(message)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(IslandDesignSystem.metaSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(IslandGlassButtonStyle())
                    .controlSize(.small)
                    .buttonBorderShape(.capsule)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IslandDesignSystem.titlePrimary)
            }
        }
        .frame(minHeight: 56, alignment: .center)
    }
}

private struct IslandLoadingPanel: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(IslandDesignSystem.metaSecondary)

            Text("Refreshing GitHub")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IslandDesignSystem.metaSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: IslandDesignSystem.rowHeight, alignment: .leading)
    }
}

private struct PullRequestSummaryBar: View {
    let title: String
    let count: Int
    let showsAllAction: Bool
    let showAll: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IslandDesignSystem.titlePrimary)

            Text(count, format: .number)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(IslandDesignSystem.metaSecondary)

            Spacer()

            if showsAllAction {
                Button("Show all", action: showAll)
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(IslandGlassButtonStyle())
                .controlSize(.mini)
                .buttonBorderShape(.capsule)
                .accessibilityLabel("Show all pull requests")
            }
        }
        .padding(.horizontal, 8)
    }
}

/// Explicit contrast keeps this floating utility legible outside the key window.
private struct IslandGlassButtonStyle: ButtonStyle {
    var isProminent = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = isEnabled && configuration.isPressed
        configuration.label
            .foregroundStyle(isProminent ? Color.black : Color.white)
            .padding(.horizontal, 10)
            .frame(height: isProminent ? 28 : 22)
            .background(isProminent ? Color.white.opacity(0.9) : Color.white.opacity(0.08), in: .capsule)
            .glassEffect(.regular.interactive(isEnabled), in: .capsule)
            .modifier(IslandControlHoverFeedback())
            .scaleEffect(isPressed && !reduceMotion ? 0.95 : 1)
            .opacity(!isEnabled ? 0.45 : isPressed ? 0.8 : 1)
            .animation(IslandDesignSystem.controlAnimation, value: isPressed)
    }
}

private struct IslandControlHoverFeedback: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var isHighlighted: Bool { isEnabled && isHovered }

    func body(content: Content) -> some View {
        content
            .overlay {
                Capsule()
                    .fill(.white.opacity(isHighlighted ? 0.08 : 0))
                    .overlay {
                        Capsule().strokeBorder(.white.opacity(isHighlighted ? 0.2 : 0), lineWidth: 0.75)
                    }
                    .allowsHitTesting(false)
            }
            .scaleEffect(isHighlighted && !reduceMotion ? 1.035 : 1)
            .animation(IslandDesignSystem.controlAnimation, value: isHighlighted)
            .overlay {
                if isEnabled { PointingHandCursorRegion() }
            }
            .onHover { isHovered = $0 }
    }
}

private struct IslandContentButtonStyle: ButtonStyle {
    var isCounter = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = isEnabled && configuration.isPressed
        Group {
            if isCounter {
                configuration.label
                    .modifier(IslandControlHoverFeedback())
                    .scaleEffect(isPressed && !reduceMotion ? 0.94 : 1)
            } else {
                configuration.label
            }
        }
        .opacity(isPressed ? 0.7 : 1)
        .animation(IslandDesignSystem.controlAnimation, value: isPressed)
    }
}

private struct PullRequestActionRow: View {
    let pullRequest: PullRequest
    @ObservedObject var store: GitIslandStore
    @State private var isHovered = false
    @State private var isConfirmingMerge = false
    @State private var confirmationResetTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            pullRequestLinkButton

            if showsActionButton {
                primaryActionButton
            } else if showsAdminMergeButton {
                AdminMergeHoldButton(
                    isMerging: store.isMerging(pullRequest),
                    onComplete: { store.merge(pullRequest) }
                )
                .frame(width: IslandDesignSystem.statusColumnWidth)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(height: IslandDesignSystem.rowHeight, alignment: .center)
        .background(isHovered ? Color.white.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(IslandDesignSystem.contentAnimation, value: isHovered)
        .onHover { isHovering in
            isHovered = isHovering
            if !isHovering {
                resetMergeConfirmation()
            }
        }
        .onDisappear {
            confirmationResetTask?.cancel()
        }
        .contextMenu {
            Button("Hide until it changes") {
                store.hidePullRequest(pullRequest)
            }
            Button("Mute repository") {
                store.muteRepository(pullRequest.repositoryFullName)
            }
        }
        .accessibilityAction(named: Text("Hide until it changes")) {
            store.hidePullRequest(pullRequest)
        }
        .accessibilityAction(named: Text("Mute repository")) {
            store.muteRepository(pullRequest.repositoryFullName)
        }
    }

    private var pullRequestLinkButton: some View {
        Button {
            if GitHubTransport.permits(pullRequest.url, host: "github.com") {
                NSWorkspace.shared.open(pullRequest.url)
            }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                PullRequestStateGlyph(group: pullRequest.group)
                pullRequestText
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(PointingHandCursorRegion())
        }
        .buttonStyle(IslandContentButtonStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("\(pullRequest.title)\n\(pullRequest.repositoryFullName) #\(pullRequest.number)\n\(pullRequest.reason) · \(pullRequest.age)\nRight-click to hide this pull request or mute its repository.")
        .accessibilityAddTraits(.isLink)
        .contextMenu {
            Button("Hide until it changes") {
                store.hidePullRequest(pullRequest)
            }
            Button("Mute repository") {
                store.muteRepository(pullRequest.repositoryFullName)
            }
        }
    }

    private var pullRequestText: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(pullRequest.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(IslandDesignSystem.titlePrimary)
                .lineLimit(2)
                .help(pullRequest.title)

            HStack(spacing: 5) {
                Text("\(pullRequest.repository) #\(pullRequest.number)")
                    .foregroundStyle(IslandDesignSystem.metaSecondary)

                Circle()
                    .fill(IslandDesignSystem.metaTertiary)
                    .frame(width: 3, height: 3)

                Text(pullRequest.reason)
                    .foregroundStyle(IslandDesignSystem.metaSecondary)
            }
            .font(.system(size: 11, weight: .regular))
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var showsMergeButton: Bool {
        pullRequest.group == .ready && pullRequest.defaultMergeMethod != nil && !pullRequest.canUpdateBranch
    }

    private var showsUpdateBranchButton: Bool {
        pullRequest.canUpdateBranch
    }

    private var showsAdminMergeButton: Bool {
        pullRequest.canMergeAsAdmin && pullRequest.defaultMergeMethod != nil
    }

    private var showsActionButton: Bool {
        showsMergeButton || showsUpdateBranchButton
    }

    private var primaryActionButton: some View {
        Button {
            if showsUpdateBranchButton {
                store.updateBranch(pullRequest)
            } else if showsMergeButton {
                if isConfirmingMerge {
                    resetMergeConfirmation()
                    store.merge(pullRequest)
                } else {
                    beginMergeConfirmation()
                }
            }
        } label: {
            ZStack {
                Text(actionButtonTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .opacity(actionButtonDisabled ? 0 : 1)

                if actionButtonDisabled {
                    ProgressView()
                        .controlSize(.mini)
                        .transition(.opacity)
                }
            }
            .frame(minWidth: 44, minHeight: 16)
            .accessibilityLabel(actionButtonTitle)
        }
        .buttonStyle(IslandGlassButtonStyle(isProminent: true))
        .controlSize(.regular)
        .buttonBorderShape(.capsule)
        .overlay {
            Capsule()
                .strokeBorder(PullRequestGroup.ready.tint.opacity(isConfirmingMerge ? 0.7 : 0), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .frame(width: IslandDesignSystem.statusColumnWidth)
        .animation(IslandDesignSystem.contentAnimation, value: isConfirmingMerge)
        .animation(IslandDesignSystem.contentAnimation, value: actionButtonDisabled)
        .disabled(actionButtonDisabled)
        .help(actionButtonHelp)
    }

    private var actionButtonTitle: String {
        if showsUpdateBranchButton {
            return store.isUpdatingBranch(pullRequest) ? "Updating" : "Update"
        }

        if store.isMerging(pullRequest) {
            return "Merging"
        }
        if isConfirmingMerge {
            return "Confirm"
        }
        return pullRequest.defaultMergeMethod?.title ?? "Merge"
    }

    private var actionButtonDisabled: Bool {
        if showsUpdateBranchButton {
            return store.isUpdatingBranch(pullRequest)
        }

        return store.isMerging(pullRequest)
    }

    private var actionButtonHelp: String {
        if showsUpdateBranchButton {
            return "Update branch from the base branch"
        }

        return isConfirmingMerge ? "Confirm merge" : "Merge with GitHub's default method"
    }

    private func beginMergeConfirmation() {
        isConfirmingMerge = true
        confirmationResetTask?.cancel()
        confirmationResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else {
                return
            }

            isConfirmingMerge = false
            confirmationResetTask = nil
        }
    }

    private func resetMergeConfirmation() {
        confirmationResetTask?.cancel()
        confirmationResetTask = nil
        isConfirmingMerge = false
    }
}

/// Merges past branch protection only after a deliberate press-and-hold,
/// so an admin bypass never fires from a stray click.
private struct AdminMergeHoldButton: View {
    let isMerging: Bool
    let onComplete: () -> Void

    @State private var progress: CGFloat = 0

    private static let holdDuration: Double = 1.5

    var body: some View {
        ZStack {
            Text(isMerging ? "Merging" : "Bypass")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .opacity(isMerging ? 0 : 1)

            if isMerging {
                ProgressView()
                    .controlSize(.mini)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 44, minHeight: 16)
        .foregroundStyle(Color.white)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Color.white.opacity(0.08)
                    PullRequestGroup.ready.tint.opacity(0.55)
                        .frame(width: proxy.size.width * progress)
                }
            }
            .clipShape(.capsule)
        }
        .overlay {
            Capsule()
                .strokeBorder(PullRequestGroup.ready.tint.opacity(0.7), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .glassEffect(.regular.interactive(!isMerging), in: .capsule)
        .modifier(IslandControlHoverFeedback())
        .contentShape(.capsule)
        .onLongPressGesture(minimumDuration: Self.holdDuration) {
            progress = 0
            onComplete()
        } onPressingChanged: { isPressing in
            guard !isMerging else {
                return
            }

            if isPressing {
                withAnimation(.linear(duration: Self.holdDuration)) {
                    progress = 1
                }
            } else {
                withAnimation(IslandDesignSystem.controlAnimation) {
                    progress = 0
                }
            }
        }
        .disabled(isMerging)
        .help("Hold to merge as admin, bypassing branch protection")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Merge as admin")
        .accessibilityHint("Bypasses branch protection")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            onComplete()
        }
    }
}

private struct PullRequestStateGlyph: View {
    let group: PullRequestGroup

    var body: some View {
        Image(systemName: group.symbolName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(group.tint)
            .frame(width: 14, height: 20)
            .accessibilityLabel(group.rawValue)
    }
}

private struct PointingHandCursorRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorRegionView {
        CursorRegionView()
    }

    func updateNSView(_ nsView: CursorRegionView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

private final class CursorRegionView: NSView {
    private var trackingArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
    }
}

private struct StatusCounter: View {
    let group: PullRequestGroup
    let count: Int
    let size: CGFloat
    var isSelected = false
    let glassNamespace: Namespace.ID
    var pulseID: UUID?
    var usesCrazyAnimations = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseScale: CGFloat = 1
    @State private var pulseGlow: CGFloat = 0

    private var usesEmphasizedPulse: Bool {
        usesCrazyAnimations && !reduceMotion
    }

    var body: some View {
        HStack(spacing: 3) {
            Group {
                if group == .testing && count > 0 {
                    Image(systemName: group.symbolName)
                        .modifier(SlowRotation(isActive: true))
                } else {
                    Image(systemName: group.symbolName)
                }
            }
            .font(.system(size: 10, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(group.tint)

            Text(count, format: .number)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .foregroundStyle(count > 0 ? group.tint : IslandDesignSystem.metaTertiary)
        .lineLimit(1)
        .minimumScaleFactor(0.78)
        .frame(width: size, height: 22)
        .glassEffect(
            isSelected ? .regular.tint(group.tint.opacity(0.2)).interactive() : .identity,
            in: .capsule
        )
        .glassEffectID(group.id, in: glassNamespace)
        .glassEffectTransition(.materialize)
        .overlay(
            Capsule()
                .stroke(
                    group.tint.opacity((usesEmphasizedPulse ? 0.52 : 0.34) * pulseGlow),
                    lineWidth: usesEmphasizedPulse ? 1.8 : 1.2
                )
                .scaleEffect(reduceMotion ? 1 : 1 + (usesEmphasizedPulse ? 0.52 : 0.26) * pulseGlow)
        )
        .scaleEffect(reduceMotion ? 1 : pulseScale)
        .contentShape(Capsule())
        .animation(reduceMotion ? nil : IslandDesignSystem.contentAnimation, value: count)
        .animation(
            usesEmphasizedPulse
                ? .spring(duration: 0.32, bounce: 0.3)
                : IslandDesignSystem.controlAnimation,
            value: pulseScale
        )
        .animation(.easeOut(duration: usesEmphasizedPulse ? 0.72 : 0.42), value: pulseGlow)
        .onChange(of: pulseID) { _, nextPulseID in
            guard nextPulseID != nil else {
                return
            }

            playPulse()
        }
    }

    private func playPulse() {
        if reduceMotion {
            pulseGlow = 1
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 260_000_000)
                pulseGlow = 0
            }
            return
        }

        let isCrazy = usesEmphasizedPulse
        pulseScale = isCrazy ? 1.3 : 1.06
        pulseGlow = 1

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: isCrazy ? 135_000_000 : 85_000_000)
            pulseScale = isCrazy ? 0.96 : 1
            try? await Task.sleep(nanoseconds: isCrazy ? 175_000_000 : 105_000_000)
            pulseScale = 1
            pulseGlow = 0
        }
    }
}

/// A single interpolated height drives both the fill and clipping mask.
/// Publishing no observable state here keeps pointer geometry in sync without
/// invalidating the entire view tree on every animation frame.
private struct IslandSurfacePresentation: @MainActor AnimatableModifier {
    var height: CGFloat
    var widthProgress: CGFloat
    let topBandHeight: CGFloat
    let compactHeight: CGFloat
    let compactSurfaceFrame: CGRect
    let outline: IslandOutlineConfiguration
    let onHeightChange: (CGFloat) -> Void
    let onWidthProgressChange: (CGFloat) -> Void

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(height, widthProgress) }
        set {
            height = newValue.first
            widthProgress = newValue.second
        }
    }

    func body(content: Content) -> some View {
        let shape = NotchIslandShape(
            topBandHeight: topBandHeight,
            compactHeight: compactHeight,
            bodyBottomY: height,
            widthProgress: widthProgress,
            compactSurfaceFrame: compactSurfaceFrame
        )
        content
            .background(shape.fill(IslandDesignSystem.surfaceFill))
            .clipShape(shape)
            // The outline morphs with the surface; its sweep may glow past the edge.
            .overlay { IslandStatusOutline(shape: shape, configuration: outline) }
            .onChange(of: height, initial: true) { _, height in
                onHeightChange(height)
            }
            .onChange(of: widthProgress, initial: true) { _, progress in
                onWidthProgressChange(progress)
            }
    }
}

private struct MorphTarget: Equatable {
    let isExpanded: Bool
    let height: CGFloat
}

private struct SlowRotation: ViewModifier {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: !isActive || reduceMotion)) { timeline in
            let angle = isActive && !reduceMotion
                ? Angle.degrees(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2 * 360)
                : .zero
            content.rotationEffect(angle)
        }
    }
}
