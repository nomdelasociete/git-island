import AppKit
import SwiftUI

/// Crazy mode only: the status outline sends waves of the changed status color
/// out into the desktop. They follow the island's own shape, so they read as
/// the ring itself resonating rather than an unrelated effect.
@MainActor
final class StatusChangeCueController {
    private static let margin: CGFloat = 90
    private static let duration: TimeInterval = 1.5

    private var panel: NSPanel?
    private var cleanupTask: Task<Void, Never>?

    /// - Parameter outline: the island outline in top-down island coordinates.
    func show(
        on screen: NSScreen,
        islandFrame: NSRect,
        outline: Path,
        group: PullRequestGroup,
        eventID: UUID
    ) {
        close()

        let margin = Self.margin
        let frame = NSRect(
            x: islandFrame.minX - margin,
            y: screen.frame.maxY - (islandFrame.height + margin),
            width: islandFrame.width + margin * 2,
            height: islandFrame.height + margin
        ).intersection(screen.frame)
        let offset = CGPoint(x: islandFrame.minX - frame.minX, y: screen.frame.maxY - frame.maxY)
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
        // Below the island so the waves emerge from behind its edge.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        let rootView = StatusChangeCueOverlayView(
            eventID: eventID,
            group: group,
            outline: outline.offsetBy(dx: offset.x, dy: offset.y),
            duration: Self.duration
        )
        .frame(width: frame.width, height: frame.height)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView

        self.panel = panel
        panel.orderFrontRegardless()

        cleanupTask = Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(for: .seconds(Self.duration + 0.2))
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
}

private struct StatusChangeCueOverlayView: View {
    let eventID: UUID
    let group: PullRequestGroup
    let outline: Path
    let duration: TimeInterval

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startDate = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(startDate))
            Canvas(rendersAsynchronously: true) { context, _ in
                draw(in: &context, progress: min(1, CGFloat(elapsed / duration)))
            }
        }
        .allowsHitTesting(false)
        .onAppear { startDate = Date() }
        .onChange(of: eventID) { _, _ in startDate = Date() }
    }

    private func draw(in context: inout GraphicsContext, progress: CGFloat) {
        guard progress < 1 else { return }

        // A soft halo of the status color hugs the ring.
        let halo = smoothstep(min(1, progress / 0.12)) * (1 - smoothstep(progress))
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 10))
            glow.stroke(outline, with: .color(group.tint.opacity(0.7 * halo)), lineWidth: 8)
        }

        // Reduced Motion keeps only the halo: no expanding waves.
        guard !reduceMotion else { return }

        // Three staggered waves grow outward from the ring. A thick stroke
        // centered on the outline reaches `radius` past the edge; the island
        // above hides the inner half.
        for index in 0..<3 {
            let phase = (progress - CGFloat(index) * 0.14) / 0.7
            guard phase > 0, phase < 1 else { continue }
            let travel = 1 - pow(1 - phase, 3)
            let radius = 4 + 70 * travel
            let alpha = smoothstep(min(1, phase / 0.08)) * pow(1 - phase, 1.6)

            context.drawLayer { wave in
                wave.addFilter(.blur(radius: 2 + 6 * travel))
                wave.stroke(
                    outline,
                    with: .color(group.tint.opacity(0.35 * alpha)),
                    lineWidth: radius * 2
                )
            }
            // Crisp leading edge of the wave.
            context.drawLayer { edge in
                edge.addFilter(.blur(radius: 1.5))
                edge.stroke(
                    outline.strokedPath(StrokeStyle(lineWidth: radius * 2)),
                    with: .color(Color.white.mix(with: group.tint, by: 0.5).opacity(0.6 * alpha)),
                    lineWidth: 1.2
                )
            }
        }
    }

    private func smoothstep(_ progress: CGFloat) -> CGFloat {
        let t = min(1, max(0, progress))
        return t * t * (3 - 2 * t)
    }
}
