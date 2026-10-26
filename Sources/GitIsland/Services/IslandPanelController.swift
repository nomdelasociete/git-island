import AppKit
import Combine
import SwiftUI

@MainActor
final class IslandPanelController {
    /// Width of each menu-bar wing flanking the physical notch (not the full auxiliary area).
    private static let wingWidth: CGFloat = 92

    private let store: GitIslandStore
    private let panel: IslandPanel
    private let mergeConfettiController = MergeConfettiController()
    private let statusChangeCueController = StatusChangeCueController()
    private weak var hostingView: IslandHostingView<IslandHostView>?
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var dataObserver: NSObjectProtocol?
    private var localMouseMonitor: Any?
    private var hoverPollTimer: Timer?
    private var pointerOutsideSince: Date?
    private var passiveHoverSuppressedUntil: Date?
    private var passiveHoverSuppressionOrigin: NSPoint?
    private var lastHoverTarget: HoverTarget?
    private var frameUpdateTask: Task<Void, Never>?

    private let collapseDelay: TimeInterval = 0.28
    private let passiveHoverSuppressionDuration: TimeInterval = 1.6
    private let passiveHoverMovementThreshold: CGFloat = 8

    init(store: GitIslandStore) {
        self.store = store
        self.panel = IslandPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        configurePanel()
        configureContent()
        bindStore()
        observeScreenChanges()
        observePullRequestChanges()
        updateFrame()
    }

    func show() {
        guard store.shouldShowIsland, targetScreen() != nil else {
            store.resetPanelPresentationState()
            panel.orderOut(nil)
            stopPointerTracking()
            return
        }

        updateFrame()
        panel.orderFrontRegardless()
        startPointerTracking()
        updateMouseRouting()
    }

    private func syncIslandVisibility() {
        if store.shouldShowIsland {
            show()
        } else {
            store.collapse()
            store.resetPanelPresentationState()
            panel.orderOut(nil)
            stopPointerTracking()
        }
    }

    func close() {
        frameUpdateTask?.cancel()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let dataObserver {
            NotificationCenter.default.removeObserver(dataObserver)
        }
        stopPointerTracking()
        mergeConfettiController.close()
        statusChangeCueController.close()
        panel.close()
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.updateMouseRouting(isExpanded: store.isExpanded, pointerInsideSurface: isPointerInsideVisibleIsland())
        panel.acceptsMouseMovedEvents = true
        panel.isMovable = false
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
    }

    private func configureContent() {
        let rootView = IslandHostView(store: store)
        let hostingView = IslandHostingView(rootView: rootView)
        // AppKit owns this top-anchored frame; SwiftUI only animates its contents.
        hostingView.sizingOptions = []
        hostingView.interactionStore = store
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        hostingView.onMouseMoved = { [weak self] event in
            self?.handleHover(event)
        }
        hostingView.onMouseExited = { [weak self] in
            self?.updateMouseRouting()
            self?.scheduleCollapseIfOutside()
        }
        hostingView.onMouseEntered = { [weak self] in
            self?.resetOutsideTracking()
        }
        hostingView.onMouseDown = { [weak self] event in
            self?.handleClick(event)
        }
        self.hostingView = hostingView
        panel.contentView = hostingView
    }

    private func bindStore() {
        store.$isAuthenticated
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.syncIslandVisibility()
            }
            .store(in: &cancellables)

        store.$pullRequests
            .combineLatest(store.$lastRefreshDate)
            .sink { [weak self] _, _ in
                self?.syncIslandVisibility()
            }
            .store(in: &cancellables)

        store.$isExpanded
            .removeDuplicates()
            .sink { [weak self] isExpanded in
                // @Published sends the new value before the store is updated.
                self?.updateMouseRouting(isExpanded: isExpanded)
                self?.hostingView?.refreshTrackingAreas()
                if !isExpanded {
                    self?.lastHoverTarget = nil
                    self?.resetOutsideTracking()
                }
            }
            .store(in: &cancellables)

        // Outline settings change only the decorative room below the surface.
        store.$outlineLaneStyle
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.scheduleFrameUpdate()
            }
            .store(in: &cancellables)

        store.$leftWingWidth
            .combineLatest(store.$rightWingWidth, store.$notchGapWidth, store.$topBandHeight)
            .sink { [weak self] _, _, _, _ in
                self?.scheduleFrameUpdate()
            }
            .store(in: &cancellables)

        store.$isExpanded
            .combineLatest(store.$selectedGroup, store.$pullRequests, store.$lastError)
            .sink { [weak self] _, _, _, _ in
                self?.hostingView?.refreshTrackingAreas()
                self?.scheduleFrameUpdate()
            }
            .store(in: &cancellables)

        store.$showsAllPullRequests
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.hostingView?.refreshTrackingAreas()
                self?.scheduleFrameUpdate()
            }
            .store(in: &cancellables)

        store.$isLoading
            .sink { [weak self] _ in
                self?.hostingView?.refreshTrackingAreas()
                self?.scheduleFrameUpdate()
            }
            .store(in: &cancellables)

        store.$retainedPanelChromeHeight
            .sink { [weak self] _ in
                self?.hostingView?.refreshTrackingAreas()
                self?.scheduleFrameUpdate()
            }
            .store(in: &cancellables)

        store.$expandedSessionPanelChromeHeight
            .sink { [weak self] _ in
                self?.hostingView?.refreshTrackingAreas()
                self?.scheduleFrameUpdate()
            }
            .store(in: &cancellables)

        store.$arrivalPulse
            .sink { [weak self] pulse in
                guard let pulse else {
                    return
                }

                self?.suppressPassiveHover()
                self?.presentStatusChangeCue(for: pulse)
            }
            .store(in: &cancellables)

        store.$mergeCelebration
            .sink { [weak self] celebration in
                guard let celebration else {
                    return
                }

                self?.presentMergeConfetti(for: celebration)
            }
            .store(in: &cancellables)
    }

    private func handleHover(_ event: NSEvent) {
        updateMouseRouting()
        guard !isPassiveHoverSuppressed() else {
            return
        }

        resetOutsideTracking()

        applyHoverTarget(at: event.locationInWindow)
    }

    private func applyHoverTarget(at point: NSPoint) {
        guard let target = hoverTarget(at: point) else {
            return
        }

        if target == lastHoverTarget, hoverTargetMatchesCurrentPresentation(target) {
            return
        }

        lastHoverTarget = target

        switch target {
        case .group(let group):
            if store.isExpanded {
                store.select(group)
            } else {
                store.open(group)
            }
        case .all:
            store.expandAllPullRequests()
        case .compactSurface:
            if !store.isExpanded {
                store.expand()
            }
        }
    }

    private func hoverTarget(at point: NSPoint) -> HoverTarget? {
        // Collapsed, the island is only the notch outline: any hover opens everything.
        guard store.isExpanded else {
            return compactSurfaceContains(point) ? .all : nil
        }

        if let group = counterGroup(at: point) {
            return .group(group)
        }

        if isInPhysicalNotchGap(point) {
            return .all
        }

        if compactSurfaceContains(point) {
            return .compactSurface
        }

        return nil
    }

    private func hoverTargetMatchesCurrentPresentation(_ target: HoverTarget) -> Bool {
        switch target {
        case .group(let group):
            store.isExpanded && !store.showsAllPullRequests && store.selectedGroup == group
        case .all:
            store.isExpanded && store.showsAllPullRequests
        case .compactSurface:
            store.isExpanded
        }
    }

    private func handleClick(_ event: NSEvent) {
        resetOutsideTracking()

        let point = event.locationInWindow

        if let group = counterGroup(at: point) {
            store.toggle(group)
            return
        }

        // Let SwiftUI rows receive the full click sequence. Collapsing on
        // mouseDown removes the row before its Button action can open the PR.
    }

    private func counterGroup(at point: NSPoint) -> PullRequestGroup? {
        // Counters are only drawn, and so only hittable, while expanded.
        guard store.isExpanded, isInTopBand(point) else {
            return nil
        }

        let centerY = store.panelFrameSize.height - (store.compactBandHeight / 2)
        let hitRadius = IslandDesignSystem.counterHitRadius

        for placement in store.counterPlacements() {
            let dx = point.x - placement.x
            let dy = point.y - centerY
            if (dx * dx) + (dy * dy) <= hitRadius * hitRadius {
                return placement.group
            }
        }

        return nil
    }

    private func isInTopBand(_ point: NSPoint) -> Bool {
        let panelHeight = store.panelFrameSize.height
        return point.y <= panelHeight
            && point.y >= panelHeight - store.compactBandHeight - 4
    }

    private func compactSurfaceContains(_ point: NSPoint) -> Bool {
        store.compactSurfaceFrame(panelHeight: store.panelFrameSize.height).contains(CGPoint(x: point.x, y: point.y))
    }

    private func isInPhysicalNotchGap(_ point: NSPoint) -> Bool {
        guard isInTopBand(point) else {
            return false
        }

        let notchMinX = store.notchMinX
        let notchMaxX = notchMinX + store.notchGapWidth
        return point.x >= notchMinX && point.x <= notchMaxX
    }

    private func scheduleCollapseIfOutside() {
        evaluatePointerForCollapse()
    }

    private func resetOutsideTracking() {
        pointerOutsideSince = nil
    }

    private func suppressPassiveHover() {
        passiveHoverSuppressedUntil = Date().addingTimeInterval(passiveHoverSuppressionDuration)
        passiveHoverSuppressionOrigin = NSEvent.mouseLocation
    }

    private func isPassiveHoverSuppressed() -> Bool {
        guard let suppressedUntil = passiveHoverSuppressedUntil else {
            return false
        }

        let now = Date()
        guard now < suppressedUntil else {
            passiveHoverSuppressedUntil = nil
            passiveHoverSuppressionOrigin = nil
            return false
        }

        if let origin = passiveHoverSuppressionOrigin {
            let location = NSEvent.mouseLocation
            let dx = location.x - origin.x
            let dy = location.y - origin.y
            if sqrt((dx * dx) + (dy * dy)) > passiveHoverMovementThreshold {
                passiveHoverSuppressedUntil = nil
                passiveHoverSuppressionOrigin = nil
                return false
            }
        }

        return true
    }

    private func isPointerInsideVisibleIsland() -> Bool {
        let location = NSEvent.mouseLocation
        return store.islandContains(
            CGPoint(x: location.x - panel.frame.minX, y: location.y - panel.frame.minY),
            panelHeight: panel.frame.height
        )
    }

    private func updateMouseRouting(isExpanded: Bool? = nil) {
        panel.updateMouseRouting(
            isExpanded: isExpanded ?? store.isExpanded,
            pointerInsideSurface: isPointerInsideVisibleIsland()
        )
    }

    private func startPointerTracking() {
        guard hoverPollTimer == nil else { return }

        schedulePointerPoll()

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            Task { @MainActor in
                self?.handleGlobalMouse(event)
            }
            return event
        }
    }

    private func schedulePointerPoll() {
        guard panel.isVisible else { return }
        // Keep fast click release near the island; avoid 60 Hz work while idle.
        let nearby = panel.frame.insetBy(dx: -80, dy: -80).contains(NSEvent.mouseLocation)
        let interval = nearby || store.isExpanded ? 1.0 / 60.0 : 0.1
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] firedTimer in
            let firedTimerID = ObjectIdentifier(firedTimer)
            MainActor.assumeIsolated {
                guard let self else { return }
                // Keep the token during synchronous callbacks: show() must not
                // install another polling chain or overwrite the mouse monitor.
                guard self.hoverPollTimer.map(ObjectIdentifier.init) == firedTimerID else { return }
                self.evaluatePointerForHoverAndCollapse()
                if self.hoverPollTimer.map(ObjectIdentifier.init) == firedTimerID && self.panel.isVisible && self.store.shouldShowIsland {
                    self.schedulePointerPoll()
                }
            }
        }
        hoverPollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPointerTracking() {
        resetOutsideTracking()
        hoverPollTimer?.invalidate()
        hoverPollTimer = nil

        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
    }

    private func evaluatePointerForCollapse() {
        guard store.isExpanded else {
            resetOutsideTracking()
            return
        }

        if isPointerInsideVisibleIsland() {
            resetOutsideTracking()
            return
        }

        let now = Date()
        if pointerOutsideSince == nil {
            pointerOutsideSince = now
        }

        if let started = pointerOutsideSince,
           now.timeIntervalSince(started) >= collapseDelay {
            pointerOutsideSince = nil
            store.collapse()
        }
    }

    private func evaluatePointerForHoverAndCollapse() {
        guard panel.isVisible, store.shouldShowIsland else { return }
        // Release clicks outside the drawn surface before the visual collapse delay.
        // A nil NSView hitTest does not forward a click to an underlying app.
        updateMouseRouting()
        guard store.isExpanded else {
            resetOutsideTracking()
            guard !isPassiveHoverSuppressed(), NSEvent.pressedMouseButtons == 0 else { return }
            let location = NSEvent.mouseLocation
            let point = NSPoint(x: location.x - panel.frame.minX, y: location.y - panel.frame.minY)
            if store.compactSurfaceFrame(panelHeight: panel.frame.height).contains(point) {
                applyHoverTarget(at: point)
            }
            return
        }

        guard isPointerInsideVisibleIsland() else {
            evaluatePointerForCollapse()
            return
        }

        if !isPassiveHoverSuppressed() {
            let location = NSEvent.mouseLocation
            let point = NSPoint(
                x: location.x - panel.frame.minX,
                y: location.y - panel.frame.minY
            )
            applyHoverTarget(at: point)
        }

        evaluatePointerForCollapse()
    }

    private func handleGlobalMouse(_ event: NSEvent) {
        guard store.isExpanded else {
            return
        }

        if event.type == .leftMouseDown, !isPointerInsideVisibleIsland() {
            resetOutsideTracking()
            store.collapse()
            return
        }

        evaluatePointerForCollapse()
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncIslandVisibility()
            }
        }
    }

    private func observePullRequestChanges() {
        dataObserver = NotificationCenter.default.addObserver(
            forName: .gitIslandPullRequestsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncIslandVisibility()
                self?.hostingView?.needsDisplay = true
            }
        }
    }

    private func scheduleFrameUpdate() {
        guard frameUpdateTask == nil else { return }
        // @Published emits before its stored value changes. Read the completed
        // group/retention update together, never an intermediate smaller height.
        frameUpdateTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.frameUpdateTask = nil
            self.hostingView?.refreshTrackingAreas()
            self.updateFrame()
        }
    }

    private func updateFrame() {
        guard let screen = targetScreen(), let notch = notchGeometry(on: screen) else {
            store.resetPanelPresentationState()
            panel.orderOut(nil)
            stopPointerTracking()
            return
        }

        store.updateNotchMetrics(
            leftWingWidth: notch.leftWingWidth,
            rightWingWidth: notch.rightWingWidth,
            gapWidth: notch.gapWidth,
            topBandHeight: notch.topBandHeight
        )

        let targetSize = store.panelFrameSize
        let topY = max(notch.topY, screen.frame.maxY)
        let targetFrame = NSRect(
            x: notch.originX - IslandDesignSystem.expandedSideInset,
            y: topY - targetSize.height,
            width: targetSize.width,
            height: targetSize.height
        )

        applyPanelFrame(targetFrame, size: targetSize)
        updateMouseRouting()

        if store.shouldShowIsland {
            panel.orderFrontRegardless()
        }
    }

    private func applyPanelFrame(_ frame: NSRect, size: CGSize) {
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        panel.minSize = size
        panel.maxSize = size
        panel.setFrame(frame, display: true, animate: false)
    }

    private func targetScreen() -> NSScreen? {
        let notchedScreens = NSScreen.screens.filter(isNotchedScreen)

        if let mouseScreen = notchedScreens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            return mouseScreen
        }

        if let main = NSScreen.main, isNotchedScreen(main) {
            return main
        }

        return notchedScreens.first
    }

    private func presentMergeConfetti(for celebration: PullRequestMergeCelebration) {
        guard let screen = targetScreen() else {
            return
        }

        updateFrame()

        let notchCenterX = panel.frame.minX + store.notchMinX + store.notchGapWidth / 2
        mergeConfettiController.show(
            on: screen,
            islandFrame: panel.frame,
            notchCenterX: notchCenterX,
            topBandHeight: store.compactBandHeight,
            crazyAnimationsEnabled: store.crazyAnimationsEnabled,
            eventID: celebration.id
        )
    }

    /// The outline sheen is drawn inside the island. Crazy mode adds waves of
    /// the changed status color radiating from the outline into the desktop.
    private func presentStatusChangeCue(for pulse: PullRequestArrivalPulse) {
        guard
            store.crazyAnimationsEnabled,
            let screen = targetScreen(),
            let group = IslandDesignSystem.outlineOrder.first(where: { pulse.groups.contains($0) })
        else {
            return
        }

        updateFrame()

        let outline = store
            .islandShape(bodyBottomY: store.visibleHeight, widthProgress: store.visibleWidthProgress)
            .outlinePath(in: CGRect(x: 0, y: 0, width: store.islandWidth, height: store.visibleHeight))

        statusChangeCueController.show(
            on: screen,
            islandFrame: panel.frame,
            outline: outline,
            group: group,
            eventID: pulse.id
        )
    }

    private func isNotchedScreen(_ screen: NSScreen) -> Bool {
        notchGeometry(on: screen) != nil
    }

    private func notchGeometry(on screen: NSScreen) -> NotchGeometry? {
        guard
            let leftArea = screen.auxiliaryTopLeftArea,
            let rightArea = screen.auxiliaryTopRightArea
        else {
            return nil
        }

        let gap = rightArea.minX - leftArea.maxX
        guard gap >= 40 else {
            return nil
        }

        let notchLeftEdge = leftArea.maxX
        return NotchGeometry(
            originX: notchLeftEdge - Self.wingWidth,
            leftWingWidth: Self.wingWidth,
            rightWingWidth: Self.wingWidth,
            gapWidth: gap,
            topBandHeight: max(leftArea.height, rightArea.height),
            topY: max(leftArea.maxY, rightArea.maxY)
        )
    }
}

private struct NotchGeometry {
    let originX: CGFloat
    let leftWingWidth: CGFloat
    let rightWingWidth: CGFloat
    let gapWidth: CGFloat
    let topBandHeight: CGFloat
    let topY: CGFloat
}

private enum HoverTarget: Equatable {
    case group(PullRequestGroup)
    case all
    case compactSurface
}

final class IslandPanel: NSPanel {
    func updateMouseRouting(isExpanded: Bool, pointerInsideSurface: Bool) {
        // Gate the entire WindowServer window, not just its SwiftUI subviews.
        // Compact hover is polled; only the expanded visible surface owns clicks.
        ignoresMouseEvents = !isExpanded || !pointerInsideSurface
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class IslandHostingView<Content: View>: NSHostingView<Content> {
    weak var interactionStore: GitIslandStore?
    var onMouseMoved: ((NSEvent) -> Void)?
    var onMouseExited: (() -> Void)?
    var onMouseEntered: (() -> Void)?
    var onMouseDown: ((NSEvent) -> Void)?

    private var trackingAreaRef: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let store = interactionStore else {
            return super.hitTest(point)
        }

        guard store.islandContains(point, panelHeight: bounds.height) else {
            return nil
        }

        return super.hitTest(point)
    }

    func refreshTrackingAreas() {
        updateTrackingAreas()
    }

    private var visibleTrackingRect: NSRect {
        guard let store = interactionStore else {
            return bounds
        }

        let height = min(store.visibleHeight, bounds.height)
        return NSRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
    }

    override func updateTrackingAreas() {
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingArea = NSTrackingArea(
            rect: visibleTrackingRect,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        trackingAreaRef = trackingArea
        addTrackingArea(trackingArea)
        super.updateTrackingAreas()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(event)
        super.mouseDown(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onMouseEntered?()
        onMouseMoved?(event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouseMoved?(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseExited?()
    }
}
