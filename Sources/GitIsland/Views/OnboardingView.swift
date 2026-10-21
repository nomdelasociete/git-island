import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var store: GitIslandStore
    let onDismiss: () -> Void
    let onComplete: () -> Void

    @AppStorage("onboardingCompleted") private var onboardingCompleted = false
    @State private var actionTask: Task<Void, Never>?
    @State private var verificationStarted = Date()
    @State private var inboxVerificationSucceeded = false
    @State private var returningUser = false
    @State private var step: OnboardingStep = .welcome
    @State private var signInPhase: SignInPhase = .ready
    @State private var userCode = ""
    @State private var deviceSession: GitHubDeviceFlowSession?
    @State private var isSigningIn = false
    @State private var signInError: String?
    @State private var didCopyCode = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            OnboardingBrandPanel()
            VStack(alignment: .leading, spacing: 0) {
                header

                Group {
                    switch step {
                    case .welcome:
                        welcomeStep
                    case .permissions:
                        permissionsStep
                    case .signIn:
                        signInStep
                    case .verify:
                        ScrollView { verificationStep }
                    case .appearance:
                        appearanceStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 28)
                .padding(.bottom, 28)

                footer
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OnboardingDesign.paper)
        }
        .frame(width: OnboardingDesign.windowSize.width, height: OnboardingDesign.windowSize.height)
        .foregroundStyle(OnboardingDesign.pine)
        .tint(OnboardingDesign.pine)
        .preferredColorScheme(.light)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: step)
        .onAppear {
            returningUser = onboardingCompleted
            if store.isAuthenticated && !store.githubAuthorizationRequired {
                step = .verify
                store.refresh(force: true)
            } else if returningUser {
                step = .signIn
            }
        }
        .onDisappear { actionTask?.cancel() }
        .onExitCommand(perform: dismissOnboarding)
        .onChange(of: store.githubAuthorizationRequired) { _, required in
            if required {
                inboxVerificationSucceeded = false
                resetSignInState()
                step = .signIn
            }
        }
        .onChange(of: store.isAuthenticated) { _, authenticated in
            if !authenticated {
                actionTask?.cancel()
                inboxVerificationSucceeded = false
                resetSignInState()
                step = .signIn
            }
        }
        .onChange(of: store.lastRefreshDate) { _, date in
            // Only a completed inbox read can verify this onboarding attempt.
            guard let date else {
                inboxVerificationSucceeded = false
                return
            }
            if date >= verificationStarted, store.isAuthenticated,
                store.lastError == nil, !store.githubAuthorizationRequired
            {
                inboxVerificationSucceeded = true
            }
        }
        .onChange(of: store.lastError) { _, error in
            if error != nil { inboxVerificationSucceeded = false }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(returningUser ? "Welcome back" : "Let’s get you settled")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(OnboardingDesign.pine.opacity(0.6))
                .padding(.bottom, 10)

            Text(step.title)
                .font(.system(size: 28, weight: .semibold))
                .tracking(-0.8)

            Text(step.subtitle(signInPhase: signInPhase))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28)
        .padding(.top, 48)
        .padding(.bottom, 20)
    }

    private var welcomeStep: some View { OnboardingWelcomeContent() }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            permissionRow(
                title: "Read your profile",
                detail: "Identify which pull requests belong to you."
            )
            permissionRow(
                title: "Repository read and write access",
                detail:
                    "GitHub’s repo scope includes private repositories and write access. Repository filters only limit what Git Island displays."
            )

            Text(
                "Git Island reads your PRs and review requests directly from GitHub. Merging or updating a branch only happens when you choose that action in the app. Your token stays in the macOS Keychain."
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        }
    }

    private var signInStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !GitHubOAuthConfiguration.isConfigured {
                Text("GitHub sign-in is not available in this build yet.")
                    .font(.system(size: 13, weight: .semibold))

                Text(
                    "If you are installing a release build, the publisher still needs to finish OAuth setup."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            } else if signInPhase == .ready {
                Text(
                    "Git Island will give you a one-time code to paste on GitHub. Your password never goes through the app."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

                if let signInError {
                    Text(signInError)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            } else {
                Text(signInInstruction)
                    .font(.system(size: 13, weight: .medium))

                Text(userCode)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                Button(didCopyCode ? "Copied" : "Copy code") {
                    copyCode()
                }
                .buttonStyle(.bordered)

                if signInPhase == .waiting {
                    Text("Paste the code on GitHub and approve access. We’ll check your connection next.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text("After copying, open GitHub and paste this code on the device authorization page.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                if let signInError {
                    Text(signInError)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var githubVerified: Bool {
        inboxVerificationSucceeded && store.isAuthenticated
            && store.lastRefreshDate != nil && !store.githubAuthorizationRequired
    }

    private var verificationStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            featureRow(
                symbol: githubVerified ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath",
                title: githubVerified ? "GitHub inbox verified" : "Checking your GitHub inbox",
                detail: githubVerified
                    ? "Loaded \(store.pullRequests.count) pull requests from GitHub. An empty inbox is a successful connection too."
                    : "We’re checking that Git Island can actually read your pull requests.")
            if let error = store.lastError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if !githubVerified {
                Button(store.isLoading ? "Checking…" : "Retry GitHub check") {
                    inboxVerificationSucceeded = false
                    verificationStarted = Date()
                    store.refresh(force: true)
                }
                .disabled(store.isLoading)
            }
            Divider()
            featureRow(
                symbol: store.relayConnected ? "bolt.fill" : "clock",
                title: store.relayConnected ? "Live updates connected" : "Using periodic refresh",
                detail: store.relayConnected
                    ? "The live connection is active. GitHub remains the source of your PR data."
                    : "Your inbox still refreshes automatically. Connect live updates to hear about changes sooner."
            )
            if !store.relayConnected {
                Button(
                    store.relayDevice.isEnrolling ? "Waiting for browser approval…" : "Connect live updates"
                ) {
                    store.relayDevice.enroll(origin: UserPreferences.relayOrigin)
                }.disabled(store.relayDevice.isBusy || store.relayDevice.isEnrolling)
                if store.relayDevice.isEnrolling {
                    Button("Cancel live connection") { store.relayDevice.cancelEnrollment() }
                }
            }
            if let message = store.relayDevice.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Text(
                "Live updates are optional. You can continue once GitHub is verified and connect them later in Settings."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var appearanceStep: some View {
        Form {
            Section {
                LabeledContent("Outline width") {
                    Slider(value: laneSelection(\.width), in: OutlineLaneStyle.widthRange)
                }
                LabeledContent("Line spacing") {
                    Slider(value: laneSelection(\.gap), in: OutlineLaneStyle.gapRange)
                }
                Toggle(
                    "Crazy animations",
                    isOn: Binding(
                        get: { store.crazyAnimationsEnabled }, set: { store.updateCrazyAnimationsEnabled($0) }))
            } footer: {
                Text(
                    "These settings apply to your actual island at the top of the screen. With no open PRs, it stays hidden. Motion follows your Mac’s Reduce Motion setting."
                )
            }
            Section {
                Picker(
                    "New PR sound",
                    selection: Binding(
                        get: { store.sound(for: .newPullRequest) },
                        set: { store.updateSound($0, for: .newPullRequest) })
                ) {
                    Text("Silent").tag(IslandSoundChoice.none)
                    Text("Glass").tag(IslandSoundChoice.system("Glass"))
                    if store.sound(for: .newPullRequest) != .none
                        && store.sound(for: .newPullRequest) != .system("Glass")
                    {
                        Text(store.sound(for: .newPullRequest).label).tag(store.sound(for: .newPullRequest))
                    }
                }
            }
            LaunchAtLoginSection()
        }.formStyle(.grouped)
            .scrollContentBackground(.hidden)
    }

    private func laneSelection(_ keyPath: WritableKeyPath<OutlineLaneStyle, CGFloat>) -> Binding<
        CGFloat
    > {
        Binding(
            get: { store.outlineLaneStyle[keyPath: keyPath] },
            set: { value in
                var style = store.outlineLaneStyle
                style[keyPath: keyPath] = value
                store.updateOutlineLaneStyle(style)
            })
    }

    private var signInInstruction: String {
        switch signInPhase {
        case .ready:
            ""
        case .codeReady:
            "Copy this code before opening GitHub."
        case .waiting:
            "Waiting for GitHub approval..."
        }
    }

    private func dismissOnboarding() {
        actionTask?.cancel()
        actionTask = nil
        onDismiss()
    }

    private var footer: some View {
        HStack {
            Button("Set up later", action: dismissOnboarding)
                .keyboardShortcut("w", modifiers: .command)
                .help("Close setup. You can return from the Git Island menu.")

            if step == .permissions || (step == .signIn && !returningUser) {
                Button("Back") {
                    resetSignInState()
                    signInError = nil
                    step = step.previous
                }
                .disabled(isSigningIn)
            }

            Spacer()

            Button(primaryButtonTitle) {
                actionTask = Task { await handlePrimaryAction() }
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(primaryButtonDisabled)
            .opacity(primaryButtonDisabled ? 0.45 : 1)
        }
    }

    private var primaryButtonTitle: String {
        switch step {
        case .welcome:
            "Set up Git Island"
        case .permissions:
            "Continue to GitHub"
        case .verify:
            returningUser ? "Back to my island" : "Make it yours"
        case .appearance:
            "Start using Git Island"
        case .signIn:
            switch signInPhase {
            case .ready:
                "Get sign-in code"
            case .codeReady:
                "Open GitHub page"
            case .waiting:
                "Waiting for GitHub..."
            }
        }
    }

    private var primaryButtonDisabled: Bool {
        if step == .verify { return !githubVerified }
        if step == .signIn {
            if !GitHubOAuthConfiguration.isConfigured {
                return true
            }
            return signInPhase == .waiting || isSigningIn
        }
        return false
    }

    private func handlePrimaryAction() async {
        switch step {
        case .welcome:
            step = .permissions
        case .permissions:
            step = .signIn
        case .signIn:
            await handleSignInAction()
        case .verify:
            if returningUser { onComplete() } else { step = .appearance }
        case .appearance:
            onboardingCompleted = true
            onComplete()
        }
    }

    private func handleSignInAction() async {
        switch signInPhase {
        case .ready:
            await fetchSignInCode()
        case .codeReady:
            await openGitHubAndWait()
        case .waiting:
            break
        }
    }

    private func fetchSignInCode() async {
        signInError = nil
        isSigningIn = true
        defer { isSigningIn = false }

        do {
            let session = try await store.beginDeviceSignIn()
            try Task.checkCancellation()
            deviceSession = session
            userCode = session.userCode
            signInPhase = .codeReady
            didCopyCode = false
        } catch {
            signInError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func openGitHubAndWait() async {
        guard let session = deviceSession else {
            signInError = "Sign-in session expired. Get a new code."
            resetSignInState()
            return
        }

        signInError = nil
        isSigningIn = true
        signInPhase = .waiting
        guard NSWorkspace.shared.open(session.verificationURI) else {
            isSigningIn = false
            signInPhase = .codeReady
            signInError = "Couldn’t open your browser. Try opening GitHub again."
            return
        }

        do {
            inboxVerificationSucceeded = false
            verificationStarted = Date()
            try await store.completeDeviceSignIn(session: session)
            try Task.checkCancellation()
            isSigningIn = false
            guard !store.githubAuthorizationRequired else {
                resetSignInState()
                step = .signIn
                signInError = "GitHub couldn’t validate this authorization. Please sign in again."
                return
            }
            step = .verify
            store.refresh(force: true)
        } catch {
            signInError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isSigningIn = false
            resetSignInState()
        }
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(userCode, forType: .string)
        didCopyCode = true
    }

    private func resetSignInState() {
        signInPhase = .ready
        userCode = ""
        deviceSession = nil
        isSigningIn = false
        didCopyCode = false
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

    private func permissionRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private enum SignInPhase {
    case ready
    case codeReady
    case waiting
}

private enum OnboardingStep {
    case welcome
    case permissions
    case signIn
    case verify
    case appearance

    var title: String {
        switch self {
        case .welcome:
            "Welcome to your island."
        case .permissions:
            "Your GitHub. Your choice."
        case .signIn:
            "Connect GitHub"
        case .verify:
            "Let’s check the connection."
        case .appearance:
            "A few finishing touches."
        }
    }

    func subtitle(signInPhase: SignInPhase) -> String {
        switch self {
        case .welcome:
            "Your pull requests, right beside your MacBook’s notch. Here’s how it works."
        case .permissions:
            "Before you connect, here’s exactly what you’ll authorize."
        case .verify:
            "We’ll confirm your inbox is reachable. Live updates are optional."
        case .appearance:
            "A few first choices. Everything stays adjustable in Settings."
        case .signIn:
            switch signInPhase {
            case .ready:
                "First you'll copy a one-time code. Then you'll paste it on GitHub."
            case .codeReady:
                "Copy the code, then open GitHub to paste it."
            case .waiting:
                "Approve Git Island in your browser to finish."
            }
        }
    }

    var previous: OnboardingStep {
        switch self {
        case .welcome:
            .welcome
        case .permissions:
            .welcome
        case .signIn:
            .permissions
        case .verify:
            .signIn
        case .appearance:
            .verify
        }
    }
}
