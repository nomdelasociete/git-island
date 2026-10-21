import SwiftUI

struct IslandOutlineConfiguration: Equatable {
    let segments: [IslandDesignSystem.OutlineSegment]
    let laneStyle: OutlineLaneStyle
    let pulse: PullRequestArrivalPulse?
    let usesCrazyAnimations: Bool
    let accessibilityLabel: String
}

/// A ring around the island with one lane per pull request. Each status owns
/// a share of the ring proportional to its count and draws its lanes there,
/// hugging the notch and stacking outward; the ring morphs with the surface.
struct IslandStatusOutline: View {
    let shape: NotchIslandShape
    let configuration: IslandOutlineConfiguration

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cue: OutlineCue?

    private var style: OutlineLaneStyle { configuration.laneStyle }
    private var laneWidth: CGFloat { style.width }

    var body: some View {
        TimelineView(.animation(paused: cue == nil)) { timeline in
            let elapsed = cue.map { timeline.date.timeIntervalSince($0.startDate) }

            ZStack {
                // Black backing first so the surface grows only as far as the lanes do.
                ForEach(lanes) { lane in
                    OutlineLaneShape(base: shape, lane: lane, style: style)
                        .stroke(IslandDesignSystem.surfaceFill, lineWidth: style.pitch + laneWidth)
                }

                ForEach(lanes) { lane in
                    OutlineLaneShape(base: shape, lane: lane, style: style)
                        .stroke(lane.group.tint, lineWidth: width(of: lane) + thickening(of: lane.group, elapsed: elapsed))
                }

                if let cue, let elapsed {
                    Canvas { context, size in
                        drawCue(cue, elapsed: elapsed, in: &context, size: size)
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : IslandDesignSystem.outlineAnimation, value: configuration.segments)
        .animation(reduceMotion ? nil : IslandDesignSystem.outlineAnimation, value: style)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(configuration.accessibilityLabel)
        .onChange(of: configuration.pulse?.id) { _, _ in
            guard let pulse = configuration.pulse else { return }
            playCue(for: pulse)
        }
    }

    /// Lanes of the non-empty segments, each knowing how many lanes it shares
    /// with its neighbours so the extra ones can bend onto the last shared lane.
    private var lanes: [OutlineLane] {
        let visible = configuration.segments.filter { $0.lanes > 0 }
        return visible.indices.flatMap { index in
            let segment = visible[index]
            let previous = index > visible.startIndex ? visible[index - 1] : nil
            let next = index < visible.endIndex - 1 ? visible[index + 1] : nil
            return (0..<segment.lanes).map { lane in
                OutlineLane(
                    group: segment.group,
                    index: lane,
                    start: segment.start,
                    end: segment.end,
                    sharedWithPrevious: previous.map { min($0.lanes, segment.lanes) },
                    sharedWithNext: next.map { min($0.lanes, segment.lanes) },
                    isFused: segment.isFused
                )
            }
        }
    }

    /// Fused lanes widen to the full pitch, overlapping slightly so no seam shows.
    private func width(of lane: OutlineLane) -> CGFloat {
        lane.isFused ? style.pitch + 0.5 : laneWidth
    }

    private func playCue(for pulse: PullRequestArrivalPulse) {
        let next = OutlineCue(
            id: pulse.id,
            groups: pulse.groups,
            sweeps: pulse.sweeps,
            startDate: Date(),
            isCrazy: configuration.usesCrazyAnimations
        )
        cue = next

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(next.duration + 0.1))
            if cue?.id == next.id {
                cue = nil
            }
        }
    }

    /// The destination segment swells briefly while the sheen reaches it.
    private func thickening(of group: PullRequestGroup, elapsed: TimeInterval?) -> CGFloat {
        guard let cue, let elapsed, !reduceMotion, cue.groups.contains(group) else { return 0 }
        return (cue.isCrazy ? 4 : 2.5) * bell(CGFloat(elapsed / cue.duration), peak: 0.35)
    }

    private func drawCue(_ cue: OutlineCue, elapsed: TimeInterval, in context: inout GraphicsContext, size: CGSize) {
        let progress = min(1, CGFloat(elapsed / cue.duration))
        guard progress < 1 else { return }
        let rect = CGRect(origin: .zero, size: size)
        let ring = shape.outlinePath(in: rect, inset: style.inset(ofLane: 0))

        if reduceMotion {
            // Opacity only: the changed segments brighten, nothing travels.
            for segment in configuration.segments where cue.groups.contains(segment.group) && segment.end > segment.start {
                context.stroke(
                    ring.trimmedPath(from: segment.start, to: segment.end),
                    with: .color(.white.opacity(0.5 * bell(progress, peak: 0.2))),
                    lineWidth: laneWidth
                )
            }
            return
        }

        context.addFilter(.shadow(color: .white.opacity(0.8), radius: cue.isCrazy ? 6 : 4))
        // Crazy mode chases the first sheen with a second one.
        let passes: [CGFloat] = cue.isCrazy ? [0, 0.22] : [0]
        for sweep in cue.sweeps {
            for delay in passes {
                let local = min(1, max(0, (progress - delay) / (1 - delay)))
                guard local > 0, local < 1 else { continue }
                let head = sweep.from + (sweep.to - sweep.from) * easeOut(local)
                let tail = sweep.from + (sweep.to - sweep.from) * easeOut(max(0, local - 0.25))
                let lower = min(1, max(0, min(head, tail)))
                let upper = min(1, max(0, max(head, tail)))
                guard upper > lower else { continue }

                context.stroke(
                    ring.trimmedPath(from: lower, to: upper),
                    with: .color(.white.opacity(0.9 * (1 - local))),
                    style: StrokeStyle(lineWidth: laneWidth + (cue.isCrazy ? 1.5 : 0.5), lineCap: .round)
                )
            }
        }
    }

    private func easeOut(_ progress: CGFloat) -> CGFloat {
        1 - pow(1 - min(1, max(0, progress)), 3)
    }

    /// Rises to 1 at `peak`, then falls back to 0 at 1.
    private func bell(_ progress: CGFloat, peak: CGFloat) -> CGFloat {
        let t = min(1, max(0, progress))
        return min(1, t / peak) * (1 - max(0, (t - peak) / (1 - peak)))
    }
}

private struct OutlineLane: Identifiable, Equatable {
    let group: PullRequestGroup
    let index: Int
    let start: CGFloat
    let end: CGFloat
    /// Lanes in common with the neighbouring segment, nil at the ring's ends.
    let sharedWithPrevious: Int?
    let sharedWithNext: Int?
    let isFused: Bool

    var id: String { "\(group.id)-\(index)" }
}

private struct OutlineLaneShape: Shape {
    let base: NotchIslandShape
    var lane: OutlineLane
    let style: OutlineLaneStyle
    var start: CGFloat
    var end: CGFloat

    init(base: NotchIslandShape, lane: OutlineLane, style: OutlineLaneStyle) {
        self.base = base
        self.lane = lane
        self.style = style
        start = lane.start
        end = lane.end
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(start, end) }
        set {
            start = newValue.first
            end = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let track = OutlineTrack(base.outlinePath(in: rect))
        // The boundary spring can overshoot past the ring's ends.
        let lower = min(1, max(0, start)) * track.length
        let upper = min(1, max(0, end)) * track.length
        guard upper > lower else { return Path() }

        var path = Path()
        var distance = lower
        path.move(to: track.point(at: distance, inset: inset(at: distance, lower: lower, upper: upper)))
        while distance < upper {
            distance = min(upper, distance + 1)
            path.addLine(to: track.point(at: distance, inset: inset(at: distance, lower: lower, upper: upper)))
        }
        return path
    }

    /// Lanes the neighbour lacks bend onto the last shared lane near the boundary.
    private func inset(at distance: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        let length = upper - lower
        var inset = laneInset(lane.index)
        if let shared = lane.sharedWithPrevious, lane.index >= shared {
            let target = laneInset(shared - 1)
            inset = target + (inset - target) * smoothstep((distance - lower) / ramp(beyond: shared, length: length))
        }
        if let shared = lane.sharedWithNext, lane.index >= shared {
            let target = laneInset(shared - 1)
            inset = target + (inset - target) * smoothstep((upper - distance) / ramp(beyond: shared, length: length))
        }
        return inset
    }

    /// Outer lanes bend over a longer run so the merge fans out.
    private func ramp(beyond shared: Int, length: CGFloat) -> CGFloat {
        max(0.01, min(length / 2, 5 + 4 * CGFloat(lane.index - shared + 1)))
    }

    /// The stacked lanes fold onto the innermost one as the island expands.
    private func laneInset(_ index: Int) -> CGFloat {
        let innermost = style.inset(ofLane: 0)
        let spread = 1 - min(1, max(0, base.widthProgress))
        return innermost + (style.inset(ofLane: index) - innermost) * spread
    }

    private func smoothstep(_ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
}

/// The surface edge flattened into a polyline that can be walked by distance,
/// so a lane can sit at an inset that varies along the ring.
private struct OutlineTrack {
    private static let curveSteps = 32
    private var points: [CGPoint] = []
    private var distances: [CGFloat] = []

    init(_ path: Path) {
        var current = CGPoint.zero
        path.forEach { element in
            switch element {
            case .move(let to):
                append(to)
                current = to
            case .line(let to):
                append(to)
                current = to
            case .quadCurve(let to, let control):
                let from = current
                for step in 1...Self.curveSteps {
                    let t = CGFloat(step) / CGFloat(Self.curveSteps)
                    let u = 1 - t
                    let a: CGFloat = u * u
                    let b: CGFloat = 2 * u * t
                    let c: CGFloat = t * t
                    let x: CGFloat = a * from.x + b * control.x + c * to.x
                    let y: CGFloat = a * from.y + b * control.y + c * to.y
                    append(CGPoint(x: x, y: y))
                }
                current = to
            case .curve(let to, let control1, let control2):
                let from = current
                for step in 1...Self.curveSteps {
                    let t = CGFloat(step) / CGFloat(Self.curveSteps)
                    let u = 1 - t
                    let a: CGFloat = u * u * u
                    let b: CGFloat = 3 * u * u * t
                    let c: CGFloat = 3 * u * t * t
                    let d: CGFloat = t * t * t
                    let x: CGFloat = a * from.x + b * control1.x + c * control2.x + d * to.x
                    let y: CGFloat = a * from.y + b * control1.y + c * control2.y + d * to.y
                    append(CGPoint(x: x, y: y))
                }
                current = to
            case .closeSubpath:
                break
            }
        }
    }

    var length: CGFloat { distances.last ?? 0 }

    /// The point `distance` along the edge, moved `inset` toward the inside.
    func point(at distance: CGFloat, inset: CGFloat) -> CGPoint {
        guard points.count > 1 else { return points.first ?? .zero }
        let distance = min(length, max(0, distance))
        var low = 1
        var high = distances.count - 1
        while low < high {
            let middle = (low + high) / 2
            if distances[middle] < distance {
                low = middle + 1
            } else {
                high = middle
            }
        }

        let from = points[low - 1]
        let to = points[low]
        let span = distances[low] - distances[low - 1]
        let t = (distance - distances[low - 1]) / span
        let dx = (to.x - from.x) / span
        let dy = (to.y - from.y) / span
        // The edge runs down, across and up, so the inside is the tangent's left.
        return CGPoint(
            x: from.x + (to.x - from.x) * t + dy * inset,
            y: from.y + (to.y - from.y) * t - dx * inset
        )
    }

    private mutating func append(_ point: CGPoint) {
        guard let last = points.last else {
            points.append(point)
            distances.append(0)
            return
        }
        let step = hypot(point.x - last.x, point.y - last.y)
        guard step > 0.001 else { return }
        points.append(point)
        distances.append(distances[distances.count - 1] + step)
    }
}

private struct OutlineCue: Equatable {
    let id: UUID
    let groups: Set<PullRequestGroup>
    let sweeps: [PullRequestOutlineSweep]
    let startDate: Date
    let isCrazy: Bool

    var duration: TimeInterval {
        isCrazy ? IslandDesignSystem.crazyOutlineSweepDuration : IslandDesignSystem.outlineSweepDuration
    }
}
