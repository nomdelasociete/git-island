import AppKit
import SwiftUI

/// Shared coastal palette for first launch and the website's installer artwork.
enum OnboardingDesign {
    static let sea = Color(red: 0.863, green: 0.902, blue: 0.906)
    static let paper = Color(red: 0.965, green: 0.976, blue: 0.969)
    static let pine = Color(red: 0.09, green: 0.22, blue: 0.21)
    static let moss = Color(red: 0.455, green: 0.525, blue: 0.416)
    static let windowSize = CGSize(width: 820, height: 660)
}

struct OnboardingBrandPanel: View {
    var resourceDirectory: URL? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                resourceImage("git-island-logo")
                    .scaledToFit().frame(width: 38, height: 38)
                Text("git island.")
                    .font(.system(size: 21, weight: .bold))
                    .tracking(-0.8)
            }
            .padding(.bottom, 52)

            Text("Your work.\nA little\nmore clear.")
                .font(.system(size: 39, weight: .semibold))
                .tracking(-1.8)
                .lineSpacing(-1)
                .fixedSize(horizontal: false, vertical: true)
            Text("Less checking.\nMore making.")
                .font(.system(size: 14))
                .lineSpacing(5)
                .foregroundStyle(OnboardingDesign.pine.opacity(0.72))
                .padding(.top, 18)
            Spacer(minLength: 12)
            resourceImage("onboarding-island")
                .scaledToFit()
                .frame(width: 294)
                .padding(.horizontal, -24)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0), .init(color: .black, location: 0.15),
                            .init(color: .black, location: 0.85), .init(color: .clear, location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                )
                .accessibilityHidden(true)
            Spacer(minLength: 12)
            Label("At home on your Mac.", systemImage: "laptopcomputer")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(OnboardingDesign.pine.opacity(0.7))
        }
        .padding(.horizontal, 30)
        .padding(.top, 46)
        .padding(.bottom, 28)
        .frame(width: 306)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(OnboardingDesign.pine)
        .background(OnboardingDesign.sea)
    }

    @ViewBuilder
    private func resourceImage(_ name: String) -> some View {
        if let url = resourceDirectory?.appendingPathComponent("\(name).png")
            ?? Bundle.main.url(forResource: name, withExtension: "png"),
            let image = NSImage(contentsOf: url)
        {
            Image(nsImage: image).resizable()
        }
    }
}

struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 20)
            .frame(minHeight: 42)
            .foregroundStyle(.white)
            .background(OnboardingDesign.pine.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .contentShape(Capsule())
    }
}
