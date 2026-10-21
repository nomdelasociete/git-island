import SwiftUI

enum IslandDesignSystem {
    static let contentAnimation = Animation.easeInOut(duration: 0.16)
    static let controlAnimation = Animation.smooth(duration: 0.22)

    static let surfaceFill = Color.black

    static let titlePrimary = Color.white.opacity(0.92)
    static let metaSecondary = Color.white.opacity(0.62)
    static let metaTertiary = Color.white.opacity(0.48)
    static let divider = Color.white.opacity(0.07)

    static let bottomCornerRadius: CGFloat = 28
    static let compactBottomCornerRadius: CGFloat = 12
    static let minimumCompactBandHeight: CGFloat = 30
    static let maximumCompactBandHeight: CGFloat = 44
    static let notchVerticalBleed: CGFloat = 1
    static let counterSize: CGFloat = 28
    static let counterHitRadius: CGFloat = 18
    static let counterSpacing: CGFloat = 3
    static let compactSurfacePadding: CGFloat = 8
    /// How far the compact surface extends past the physical notch so its
    /// status outline stays visible beside and below the hardware cutout.
    static let compactOutlineOutset: CGFloat = 3
    /// Dynamic Island–style morph: width and height run on separate springs,
    /// staged so the island widens before dropping and rises before narrowing.
    static let morphAnimation = Animation.spring(response: 0.39, dampingFraction: 0.62)
    static let morphOpenHeightDelay: TimeInterval = 0.09
    static let morphCloseWidthDelay: TimeInterval = 0.12
    /// Extra host room so the springs can overshoot without being clipped.
    static let surfaceOvershootHeadroom: CGFloat = 20
    static let surfaceOvershootInset: CGFloat = 8
    /// Loose spring so status boundaries wobble slightly as they settle.
    static let outlineAnimation = Animation.spring(response: 0.43, dampingFraction: 0.38)
    static let outlineSweepDuration: TimeInterval = 0.9
    static let crazyOutlineSweepDuration: TimeInterval = 1.4
    static let rowHeight: CGFloat = 68
    static let expandedSummaryHeight: CGFloat = 28
    static let expandedBodySpacing: CGFloat = 4
    static let panelHorizontalInset: CGFloat = 14
    static let panelTopInset: CGFloat = 8
    /// Room for the expanded body outside the notch-adjacent wings, including
    /// `surfaceOvershootInset` so the width spring can overshoot.
    static let expandedSideInset: CGFloat = 44
    static let maxVisibleRows = 5
    static let statusColumnWidth: CGFloat = 68

    static func expandedHeight(
        rowCount: Int,
        topBandHeight: CGFloat,
        showsMessageBody: Bool = false,
        showsSummaryBar: Bool = false
    ) -> CGFloat {
        let bodyHeight = showsMessageBody
            ? 56
            : CGFloat(min(max(rowCount, 0), maxVisibleRows)) * rowHeight
        let summaryHeight = showsSummaryBar ? expandedSummaryHeight + expandedBodySpacing : 0
        let chrome = topBandHeight + panelTopInset + 8
        return chrome + summaryHeight + bodyHeight + 8
    }

    struct CounterPlacement: Identifiable {
        let group: PullRequestGroup
        let x: CGFloat

        var id: String { group.id }
    }

    static func counterPlacements(
        groups: [PullRequestGroup],
        counts: [PullRequestGroup: Int],
        leftWingWidth: CGFloat,
        gapWidth: CGFloat,
        rightWingWidth: CGFloat
    ) -> [CounterPlacement] {
        let visible = groups
            .filter { (counts[$0] ?? 0) > 0 }
            .sorted { $0.compactPriority < $1.compactPriority }

        let leftGroups = visible.filter { $0 == .ready }
        let rightGroups = visible.filter { $0 != .ready }
        var placements: [CounterPlacement] = []

        if !leftGroups.isEmpty {
            let clusterWidth = compactCounterClusterWidth(forCounterCount: leftGroups.count)
            let edgeInset = compactCounterEdgeInset(
                forCounterCount: leftGroups.count,
                wingWidth: leftWingWidth
            )
            let clusterEndX = leftWingWidth - edgeInset
            var x = clusterEndX - clusterWidth + (counterSize / 2)

            for group in leftGroups {
                placements.append(CounterPlacement(group: group, x: x))
                x += counterSize + counterSpacing
            }
        }

        if !rightGroups.isEmpty {
            let edgeInset = compactCounterEdgeInset(
                forCounterCount: rightGroups.count,
                wingWidth: rightWingWidth
            )
            let clusterStartX = leftWingWidth + gapWidth + edgeInset
            var x = clusterStartX + (counterSize / 2)

            for group in rightGroups {
                placements.append(CounterPlacement(group: group, x: x))
                x += counterSize + counterSpacing
            }
        }

        return placements.map {
            CounterPlacement(group: $0.group, x: $0.x + expandedSideInset)
        }
    }

    private static func compactCounterClusterWidth(forCounterCount count: Int) -> CGFloat {
        guard count > 0 else {
            return 0
        }

        return CGFloat(count) * counterSize
            + CGFloat(max(0, count - 1)) * counterSpacing
    }

    private static func compactCounterEdgeInset(forCounterCount count: Int, wingWidth: CGFloat) -> CGFloat {
        guard count > 0 else {
            return 0
        }

        let remainingWidth = wingWidth - compactCounterClusterWidth(forCounterCount: count)
        guard remainingWidth > 0 else {
            return 0
        }

        return min(compactSurfacePadding, remainingWidth / 2)
    }

    /// Compact state is the physical notch plus a thin outset that carries the
    /// status outline. Frame is expressed in bottom-up coordinates when
    /// `panelHeight` is the AppKit panel height.
    static func compactSurfaceFrame(
        leftWingWidth: CGFloat,
        gapWidth: CGFloat,
        compactHeight: CGFloat,
        panelHeight: CGFloat
    ) -> CGRect {
        CGRect(
            x: expandedSideInset + leftWingWidth - compactOutlineOutset,
            y: panelHeight - compactHeight,
            width: gapWidth + compactOutlineOutset * 2,
            height: compactHeight
        )
    }

    struct OutlineSegment: Identifiable, Equatable {
        let group: PullRequestGroup
        let start: CGFloat
        let end: CGFloat
        let lanes: Int
        let isFused: Bool

        var id: String { group.id }
        var midpoint: CGFloat { (start + end) / 2 }
    }

    /// Left-to-right order around the notch outline. Every group is always
    /// present so a segment can grow from, or shrink to, zero length.
    static let outlineOrder: [PullRequestGroup] = [.ready, .blocked, .waiting, .testing]

    static func outlineSegments(counts: [PullRequestGroup: Int], maxLanes: Int) -> [OutlineSegment] {
        let total = outlineOrder.reduce(0) { $0 + max(0, counts[$1] ?? 0) }
        var start: CGFloat = 0

        return outlineOrder.map { group in
            let count = max(0, counts[group] ?? 0)
            let share = total > 0 ? CGFloat(count) / CGFloat(total) : 0
            let end = min(1, start + share)
            defer { start = end }
            return OutlineSegment(
                group: group,
                start: start,
                end: end,
                lanes: min(count, maxLanes),
                isFused: count > maxLanes
            )
        }
    }

}

/// Each pull request draws one lane: the first hugs the notch, the rest stack
/// outward, so a status's thickness shows its absolute count. Past `maxLanes`
/// a status's lanes fuse into one band of the same footprint. All three
/// values are user settings.
struct OutlineLaneStyle: Equatable {
    static let widthRange: ClosedRange<CGFloat> = 0.75...3
    static let gapRange: ClosedRange<CGFloat> = 0...3
    static let maxLanesRange = 1...10
    static let standard = OutlineLaneStyle(width: 1.5, gap: 1, maxLanes: 5)

    var width: CGFloat
    var gap: CGFloat
    var maxLanes: Int

    var pitch: CGFloat { width + gap }

    func clamped() -> OutlineLaneStyle {
        OutlineLaneStyle(
            width: min(Self.widthRange.upperBound, max(Self.widthRange.lowerBound, width)),
            gap: min(Self.gapRange.upperBound, max(Self.gapRange.lowerBound, gap)),
            maxLanes: min(Self.maxLanesRange.upperBound, max(Self.maxLanesRange.lowerBound, maxLanes))
        )
    }

    /// Distance from the surface edge to a lane's centerline, positive inward.
    /// Lane 0 hugs the physical notch; later lanes sit outside the surface.
    func inset(ofLane index: Int) -> CGFloat {
        IslandDesignSystem.compactOutlineOutset - width / 2 - CGFloat(index) * pitch
    }

    /// Host room needed below the surface for the outermost lane and the
    /// black backing that follows it.
    func room(laneCount: Int) -> CGFloat {
        guard laneCount > 1 else { return 0 }
        let backingHalfWidth = (pitch + width) / 2
        return max(0, (backingHalfWidth - inset(ofLane: laneCount - 1)).rounded(.up))
    }
}
