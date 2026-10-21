import SwiftUI

struct OnboardingWelcomeContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            featureRow(
                symbol: "circle.grid.2x2.fill",
                title: "Four states. One quiet island.",
                detail:
                    "Blocked, waiting, testing, and ready — around your MacBook’s notch when you have open PRs."
            )
            featureRow(
                symbol: "hand.point.up.left.fill",
                title: "Hover to expand",
                detail: "Glance at your most urgent pull requests without leaving your flow."
            )
            featureRow(
                symbol: "arrow.up.forward.app",
                title: "Click to open on GitHub",
                detail: "Jump straight into the PR when something needs attention."
            )
        }
    }

    private func featureRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

}
