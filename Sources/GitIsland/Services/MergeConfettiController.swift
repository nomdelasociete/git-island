import AppKit
import SwiftUI

@MainActor
final class MergeConfettiController {
    private static let overlayLevel = NSWindow.Level.popUpMenu

    private var panel: NSPanel?
    private var cleanupTask: Task<Void, Never>?
    private lazy var gitMarkImage: Image? = {
        guard let sourceURL = Bundle.main.url(forResource: "git-merge-mark", withExtension: "svg"),
              let sourceImage = NSImage(contentsOf: sourceURL)
        else {
            return nil
        }

        return Image(nsImage: sourceImage)
    }()

    func show(
        on screen: NSScreen,
        islandFrame: NSRect,
        notchCenterX: CGFloat,
        topBandHeight: CGFloat,
        crazyAnimationsEnabled: Bool,
        eventID: UUID
    ) {
        close()

        let profile = MergeConfettiAnimationProfile(crazyAnimationsEnabled: crazyAnimationsEnabled)
        // NSWindow clips all drawing to its frame. Cover the target display so
        // particles disappear only at the physical screen edges, not at an
        // artificial celebration viewport around the notch.
        let frame = screen.frame
        let origin = confettiOrigin(
            in: frame,
            islandFrame: islandFrame,
            notchCenterX: notchCenterX,
            topBandHeight: topBandHeight
        )
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = false
        panel.isMovable = false
        panel.level = Self.overlayLevel
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        let rootView = MergeConfettiOverlayView(
            eventID: eventID,
            origin: origin,
            profile: profile,
            gitMarkImage: gitMarkImage
        )
            .frame(width: frame.width, height: frame.height)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView

        self.panel = panel
        panel.orderFrontRegardless()

        cleanupTask = Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(nanoseconds: profile.cleanupDelay)
            guard !Task.isCancelled else {
                return
            }

            panel?.orderOut(nil)
            panel?.close()
            self?.panel = nil
            self?.cleanupTask = nil
        }
    }

    func close() {
        cleanupTask?.cancel()
        cleanupTask = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    private func confettiOrigin(
        in overlayFrame: NSRect,
        islandFrame: NSRect,
        notchCenterX: CGFloat,
        topBandHeight: CGFloat
    ) -> CGPoint {
        let islandTopBandCenterY = islandFrame.maxY - topBandHeight * 0.55
        let originY = overlayFrame.maxY - islandTopBandCenterY

        return CGPoint(
            x: notchCenterX - overlayFrame.minX,
            y: min(max(originY, 18), overlayFrame.height * 0.36)
        )
    }
}

private struct MergeConfettiAnimationProfile: Sendable {
    let cleanupDelay: UInt64
    let animationDuration: TimeInterval
    let particleCount: Int
    let speedScale: CGFloat
    let sizeScale: CGFloat
    let gravity: CGFloat
    let maxDelay: CGFloat
    let burstTravel: CGFloat
    let burstOpacity: CGFloat
    let secondaryBurstDelay: CGFloat?

    init(crazyAnimationsEnabled: Bool) {
        self = crazyAnimationsEnabled ? .crazy : .calm
    }

    private static let calm = MergeConfettiAnimationProfile(
        cleanupDelay: 1_800_000_000,
        animationDuration: 1.45,
        particleCount: 26,
        speedScale: 1,
        sizeScale: 1,
        gravity: 390,
        maxDelay: 0.14,
        burstTravel: 42,
        burstOpacity: 0.36,
        secondaryBurstDelay: nil
    )

    private static let crazy = MergeConfettiAnimationProfile(
        cleanupDelay: 2_900_000_000,
        animationDuration: 2.25,
        particleCount: 82,
        speedScale: 1.42,
        sizeScale: 1.55,
        gravity: 320,
        maxDelay: 0.28,
        burstTravel: 96,
        burstOpacity: 0.58,
        secondaryBurstDelay: 0.11
    )

    private init(
        cleanupDelay: UInt64,
        animationDuration: TimeInterval,
        particleCount: Int,
        speedScale: CGFloat,
        sizeScale: CGFloat,
        gravity: CGFloat,
        maxDelay: CGFloat,
        burstTravel: CGFloat,
        burstOpacity: CGFloat,
        secondaryBurstDelay: CGFloat?
    ) {
        self.cleanupDelay = cleanupDelay
        self.animationDuration = animationDuration
        self.particleCount = particleCount
        self.speedScale = speedScale
        self.sizeScale = sizeScale
        self.gravity = gravity
        self.maxDelay = maxDelay
        self.burstTravel = burstTravel
        self.burstOpacity = burstOpacity
        self.secondaryBurstDelay = secondaryBurstDelay
    }
}

private struct MergeConfettiOverlayView: View {
    let eventID: UUID
    let origin: CGPoint
    let profile: MergeConfettiAnimationProfile
    let gitMarkImage: Image?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startDate = Date()

    private let particles: [MergeConfettiParticle]

    init(eventID: UUID, origin: CGPoint, profile: MergeConfettiAnimationProfile, gitMarkImage: Image?) {
        self.eventID = eventID
        self.origin = origin
        self.profile = profile
        self.gitMarkImage = gitMarkImage
        particles = Self.makeParticles(seed: Self.seed(from: eventID), profile: profile)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 30.0 : 1.0 / 60.0)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(startDate))

            Canvas(rendersAsynchronously: true) { context, size in
                if reduceMotion {
                    drawReducedMotionSuccess(in: &context, elapsed: elapsed)
                } else {
                    let resolvedGitMark = gitMarkImage.map { context.resolve($0) }
                    drawConfetti(
                        in: &context,
                        size: size,
                        elapsed: elapsed,
                        gitMark: resolvedGitMark
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            startDate = Date()
        }
        .onChange(of: eventID) { _, _ in
            startDate = Date()
        }
    }

    private func drawConfetti(
        in context: inout GraphicsContext,
        size: CGSize,
        elapsed: TimeInterval,
        gitMark: GraphicsContext.ResolvedImage?
    ) {
        drawBurstRing(in: &context, elapsed: elapsed)

        guard let gitMark else {
            return
        }

        for particle in particles {
            let localElapsed = elapsed - particle.delay
            guard localElapsed >= 0 else {
                continue
            }

            let time = CGFloat(localElapsed)
            let progress = min(1, CGFloat(localElapsed / profile.animationDuration))
            let fade = 1 - smoothstep(normalized(progress, start: 0.68, end: 1.0))
            let birth = smoothstep(normalized(progress, start: 0.0, end: 0.08))
            let opacity = Double(max(0, min(1, fade * birth)))
            guard opacity > 0 else {
                continue
            }

            let drag = max(0.72, 1 - time * 0.12)
            let x = origin.x + particle.offset.x + particle.velocity.dx * time * drag
            let y = origin.y + particle.offset.y + particle.velocity.dy * time + 0.5 * profile.gravity * time * time

            guard x > -24, x < size.width + 24, y > -40, y < size.height + 44 else {
                continue
            }

            var localContext = context
            localContext.opacity = opacity
            localContext.translateBy(x: x, y: y)
            localContext.rotate(by: .radians(Double(particle.rotation + particle.spin * time)))

            let rect = CGRect(
                x: -particle.size / 2,
                y: -particle.size / 2,
                width: particle.size,
                height: particle.size
            )

            localContext.draw(gitMark, in: rect)
        }
    }

    private func drawBurstRing(in context: inout GraphicsContext, elapsed: TimeInterval) {
        drawBurstRing(in: &context, elapsed: elapsed, delay: 0, travel: profile.burstTravel, opacity: profile.burstOpacity)

        if let secondaryBurstDelay = profile.secondaryBurstDelay {
            drawBurstRing(
                in: &context,
                elapsed: elapsed,
                delay: TimeInterval(secondaryBurstDelay),
                travel: profile.burstTravel * 0.68,
                opacity: profile.burstOpacity * 0.62
            )
        }
    }

    private func drawBurstRing(
        in context: inout GraphicsContext,
        elapsed: TimeInterval,
        delay: TimeInterval,
        travel: CGFloat,
        opacity: CGFloat
    ) {
        guard elapsed >= delay else {
            return
        }

        let progress = normalized(CGFloat(elapsed - delay), start: 0, end: 0.34)
        guard progress < 1 else {
            return
        }

        let eased = easeOutCubic(progress)
        let radius = 12 + travel * eased
        let opacity = Double((1 - eased) * opacity)
        let ringRect = CGRect(
            x: origin.x - radius,
            y: origin.y - radius,
            width: radius * 2,
            height: radius * 2
        )

        context.stroke(
            Path(ellipseIn: ringRect),
            with: .color(Color.white.opacity(opacity)),
            lineWidth: profile.sizeScale > 1 ? 2.2 : 1.4
        )
    }

    private func drawReducedMotionSuccess(in context: inout GraphicsContext, elapsed: TimeInterval) {
        let progress = normalized(CGFloat(elapsed), start: 0, end: 0.72)
        guard progress < 1 else {
            return
        }

        let eased = easeOutCubic(progress)
        let ringRadius = 16 + 28 * eased
        let ringOpacity = Double((1 - eased) * 0.28)
        let checkOpacity = Double(1 - smoothstep(normalized(progress, start: 0.72, end: 1.0)))
        let ringRect = CGRect(
            x: origin.x - ringRadius,
            y: origin.y - ringRadius,
            width: ringRadius * 2,
            height: ringRadius * 2
        )

        context.stroke(
            Path(ellipseIn: ringRect),
            with: .color(PullRequestGroup.ready.tint.opacity(ringOpacity)),
            lineWidth: 2
        )

        var checkPath = Path()
        checkPath.move(to: CGPoint(x: origin.x - 9, y: origin.y - 1))
        checkPath.addLine(to: CGPoint(x: origin.x - 2, y: origin.y + 7))
        checkPath.addLine(to: CGPoint(x: origin.x + 11, y: origin.y - 8))

        context.stroke(
            checkPath,
            with: .color(PullRequestGroup.ready.tint.opacity(checkOpacity)),
            style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
        )
    }

    private static func makeParticles(seed: UInt64, profile: MergeConfettiAnimationProfile) -> [MergeConfettiParticle] {
        var generator = SeededNumberGenerator(seed: seed)

        return (0..<profile.particleCount).map { index in
            let isWideParticle = index.isMultiple(of: 6)
            let angleDegrees: CGFloat
            if isWideParticle {
                angleDegrees = generator.nextBool()
                    ? generator.next(in: -176 ... -128)
                    : generator.next(in: -52 ... -4)
            } else {
                angleDegrees = generator.next(in: -154 ... -26)
            }
            let speed = generator.next(in: isWideParticle ? 240 ... 380 : 175 ... 335) * profile.speedScale
            let angle = angleDegrees * .pi / 180

            return MergeConfettiParticle(
                id: index,
                size: generator.next(in: 16 ... 22) * profile.sizeScale,
                offset: CGPoint(
                    x: generator.next(in: -10 ... 10) * profile.sizeScale,
                    y: generator.next(in: -4 ... 7) * profile.sizeScale
                ),
                velocity: CGVector(
                    dx: cos(angle) * speed,
                    dy: sin(angle) * speed
                ),
                rotation: generator.next(in: 0 ... (.pi * 2)),
                spin: generator.next(in: -4.5 ... 4.5) * profile.speedScale,
                delay: TimeInterval(generator.next(in: 0 ... profile.maxDelay))
            )
        }
    }

    private static func seed(from id: UUID) -> UInt64 {
        id.uuidString.utf8.reduce(0xcbf2_9ce4_8422_2325) { partialResult, byte in
            (partialResult ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
    }

    private func normalized(_ value: CGFloat, start: CGFloat, end: CGFloat) -> CGFloat {
        guard end > start else {
            return 1
        }

        return min(1, max(0, (value - start) / (end - start)))
    }

    private func smoothstep(_ progress: CGFloat) -> CGFloat {
        let t = min(1, max(0, progress))
        return t * t * (3 - 2 * t)
    }

    private func easeOutCubic(_ progress: CGFloat) -> CGFloat {
        let t = min(1, max(0, progress))
        let inverse = 1 - t
        return 1 - inverse * inverse * inverse
    }
}

private struct MergeConfettiParticle: Identifiable {
    let id: Int
    let size: CGFloat
    let offset: CGPoint
    let velocity: CGVector
    let rotation: CGFloat
    let spin: CGFloat
    let delay: TimeInterval
}

private struct SeededNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x4d59_5df4_d0f3_3173 : seed
    }

    mutating func next(in range: ClosedRange<CGFloat>) -> CGFloat {
        range.lowerBound + (range.upperBound - range.lowerBound) * nextUnit()
    }

    mutating func nextBool() -> Bool {
        nextUnit() >= 0.5
    }

    private mutating func nextUnit() -> CGFloat {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat(Double(state >> 11) / Double(UInt64.max >> 11))
    }
}
