import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// System Settings–style window: a sidebar of panes, each a grouped form.
struct SettingsView: View {
    @ObservedObject var store: GitIslandStore
    let onSignIn: () -> Void
    @State private var selection: SettingsPane = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    SettingsIcon(symbol: pane.symbol, tint: pane.tint, size: 22)
                }
                .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            detail(for: selection)
                .navigationTitle(selection.title)
        }
        .frame(minWidth: 720, minHeight: 500)
    }

    @ViewBuilder
    private func detail(for pane: SettingsPane) -> some View {
        switch pane {
        case .general:
            GeneralSettingsPane(store: store, onSignIn: onSignIn)
        case .appearance:
            AppearanceSettingsPane(store: store)
        case .sounds:
            SoundSettingsPane(store: store)
        case .refresh:
            RefreshSettingsPane(store: store)
        case .repositories:
            RepositorySettingsPane(store: store)
        }
    }
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case appearance
    case sounds
    case refresh
    case repositories

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .sounds: "Sounds"
        case .refresh: "Refresh"
        case .repositories: "Repositories"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintbrush.fill"
        case .sounds: "speaker.wave.2.fill"
        case .refresh: "arrow.clockwise"
        case .repositories: "folder.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .appearance: .indigo
        case .sounds: .pink
        case .refresh: .green
        case .repositories: .blue
        }
    }
}

/// The rounded-square glyph System Settings uses for rows and panes.
private struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @ObservedObject var store: GitIslandStore
    let onSignIn: () -> Void

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AccountAvatar(login: store.isAuthenticated ? store.githubLogin : nil)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.isAuthenticated ? (store.githubLogin ?? "Connected") : "Not signed in")
                            .font(.title3.weight(.semibold))
                        Text(store.isAuthenticated ? "GitHub account" : "Sign in to load your pull requests.")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if store.isAuthenticated {
                        Button("Sign Out") {
                            store.signOut()
                            onSignIn()
                        }
                    } else {
                        Button("Sign in with GitHub") {
                            onSignIn()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.vertical, 4)
            }

            if let error = store.credentialStorageError {
                Section("Credential storage") {
                    Text(error).foregroundStyle(.red)
                    Button(TokenStore.cleanupPending ? "Retry credential removal" : "Retry credential access") {
                        store.retryCredentialStorage()
                    }
                }
            }

            LaunchAtLoginSection()

            Section("Status") {
                LabeledContent("Inbox", value: store.inboxSummary.isEmpty ? "Clear" : store.inboxSummary)
                LabeledContent("Island", value: store.islandVisibilityStatus)
                LabeledContent("Data source", value: store.dataSourceStatus)
            }

            Section {
                LabeledContent("Build", value: GitIslandStore.buildStamp)
            }
        }
        .formStyle(.grouped)
    }
}

struct LaunchAtLoginSection: View {
    @State private var status = SMAppService.mainApp.status
    @State private var isUpdating = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            Toggle("Launch at login", isOn: Binding(
                get: { status == .enabled || status == .requiresApproval },
                set: { setEnabled($0) }
            ))
            .disabled(isUpdating)

            if status == .requiresApproval {
                Text("Allow Git Island in System Settings → General → Login Items to finish enabling launch at login.")
                    .foregroundStyle(.secondary)
                Button("Open Login Items…") {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
        } footer: {
            Text("Automatically open Git Island when you sign in to your Mac.")
        }
        .onAppear {
            status = SMAppService.mainApp.status
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = SMAppService.mainApp.status
        }
    }

    private func setEnabled(_ enabled: Bool) {
        guard !isUpdating else { return }
        isUpdating = true
        errorMessage = nil

        Task { @MainActor in
            defer {
                status = SMAppService.mainApp.status
                isUpdating = false
            }

            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try await SMAppService.mainApp.unregister()
                }
            } catch {
                errorMessage = "Couldn’t change launch at login. \(error.localizedDescription)"
            }
        }
    }
}

/// GitHub serves every account's avatar at github.com/<login>.png.
private struct AccountAvatar: View {
    let login: String?
    private let size: CGFloat = 48

    var body: some View {
        Group {
            if let login, let url = URL(string: "https://github.com/\(login).png?size=\(Int(size * 3))") {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(.separator)
        }
    }

    private var placeholder: some View {
        Image(systemName: login == nil ? "person.crop.circle.badge.questionmark" : "person.crop.circle.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.secondary)
    }
}

// MARK: - Appearance

private struct AppearanceSettingsPane: View {
    @ObservedObject var store: GitIslandStore

    var body: some View {
        Form {
            IslandAppearanceSections(store: store)
        }
        .formStyle(.grouped)
    }
}

/// Used by both first-run setup and Settings so every style and control stays available.
struct IslandAppearanceSections: View {
    @ObservedObject var store: GitIslandStore
    @State private var previewSample: OutlinePreviewSample = .each

    private var crazyAnimationsSelection: Binding<Bool> {
        Binding(
            get: { store.crazyAnimationsEnabled },
            set: { store.updateCrazyAnimationsEnabled($0) }
        )
    }

    private func laneSelection<Value>(_ keyPath: WritableKeyPath<OutlineLaneStyle, Value>) -> Binding<Value> {
        Binding(
            get: { store.outlineLaneStyle[keyPath: keyPath] },
            set: { value in
                var style = store.outlineLaneStyle
                style[keyPath: keyPath] = value
                store.updateOutlineLaneStyle(style)
            }
        )
    }

    private var previewCounts: [PullRequestGroup: Int] {
        switch previewSample {
        case .inbox:
            store.counterCounts
        case .busy:
            [.ready: 3, .blocked: 1, .waiting: 2, .testing: 7]
        case .calm:
            [.ready: 1, .waiting: 1]
        case .each:
            [.ready: 1, .blocked: 1, .waiting: 1, .testing: 1]
        case .oneBlocked:
            [.blocked: 1]
        case .manyBlocked:
            [.blocked: 5]
        case .manyReady:
            [.ready: 5]
        case .manyTesting:
            [.testing: 5]
        case .dominant:
            [.ready: 1, .blocked: 6, .waiting: 1, .testing: 1]
        case .balanced:
            [.ready: 3, .blocked: 3, .waiting: 3, .testing: 3]
        case .empty:
            [:]
        }
    }

    var body: some View {
        Group {
            Section {
                VStack(spacing: 12) {
                    OutlinePreview(counts: previewCounts, style: store.outlineLaneStyle)
                        .frame(maxWidth: 320)
                        .frame(maxWidth: .infinity)

                    Picker("Preview", selection: $previewSample) {
                        ForEach(OutlinePreviewSample.allCases) { sample in
                            Text(sample.label).tag(sample)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 320)

                    HStack(spacing: 12) {
                        ForEach(IslandDesignSystem.outlineOrder) { group in
                            Text("\(previewCounts[group, default: 0]) \(group.rawValue)")
                                .foregroundStyle(group.tint)
                        }
                    }
                    .font(.caption)
                }
                .padding(.vertical, 6)
            }

            Section {
                Picker("Style", selection: laneSelection(\.appearance)) {
                    ForEach(IslandOutlineAppearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)

                if store.outlineLaneStyle.appearance == .halo {
                    LabeledContent("Halo strength") {
                        SliderValue(
                            value: laneSelection(\.haloStrength), range: 0...1,
                            label: percent(store.outlineLaneStyle.haloStrength), step: 0.01
                        )
                    }
                    LabeledContent("Transparency") {
                        SliderValue(
                            value: laneSelection(\.haloTransparency), range: 0...1,
                            label: percent(store.outlineLaneStyle.haloTransparency), step: 0.01
                        )
                    }
                }

                if store.outlineLaneStyle.appearance == .lines {
                    LabeledContent("Line width") {
                        SliderValue(
                            value: laneSelection(\.width),
                            range: OutlineLaneStyle.widthRange,
                            label: points(store.outlineLaneStyle.width)
                        )
                    }

                    LabeledContent("Spacing") {
                        SliderValue(
                            value: laneSelection(\.gap),
                            range: OutlineLaneStyle.gapRange,
                            label: store.outlineLaneStyle.gap == 0 ? "None" : points(store.outlineLaneStyle.gap)
                        )
                    }

                    LabeledContent("Maximum lines") {
                        Stepper(value: laneSelection(\.maxLanes), in: OutlineLaneStyle.maxLanesRange) {
                            Text("\(store.outlineLaneStyle.maxLanes)")
                                .monospacedDigit()
                        }
                    }
                }
            } header: {
                Text("Outline")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text(store.outlineLaneStyle.appearance == .lines
                         ? "Each pull request draws one line in its status color. Past the maximum, the lines merge into one thick line."
                         : "Colors show the share of each status, not the total number of pull requests. Hover the notch to see counts.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Defaults") {
                        store.updateOutlineLaneStyle(resetStyle)
                    }
                    .disabled(store.outlineLaneStyle == resetStyle)
                }
            }

            Section {
                Toggle(isOn: crazyAnimationsSelection) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Crazy animations")
                        Text("Double sheen and color waves when a status changes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Animations")
            }
        }
    }

    private var resetStyle: OutlineLaneStyle {
        var style = OutlineLaneStyle.standard
        style.appearance = store.outlineLaneStyle.appearance
        return style
    }

    private func points(_ value: CGFloat) -> String {
        "\(Double(value).formatted(.number.precision(.fractionLength(0...2)))) pt"
    }

    private func percent(_ value: CGFloat) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

private enum OutlinePreviewSample: String, CaseIterable, Identifiable {
    case inbox
    case busy
    case calm
    case each, oneBlocked, manyBlocked, manyReady, manyTesting, dominant, balanced, empty

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inbox: "My inbox"
        case .busy: "Busy"
        case .calm: "Calm"
        case .each: "One of each status"
        case .oneBlocked: "One blocked"
        case .manyBlocked: "Five blocked"
        case .manyReady: "Five ready"
        case .manyTesting: "Five testing"
        case .dominant: "Mostly blocked"
        case .balanced: "Three of each status"
        case .empty: "No pull requests"
        }
    }
}

private struct SliderValue: View {
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let label: String
    var step: CGFloat = 0.25

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: range, step: step)
                .frame(width: 180)
            Text(label)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

/// The compact island over a menu bar, using the live outline, scaled to
/// fill the pane width so it never pushes the form wider.
private struct OutlinePreview: View {
    let counts: [PullRequestGroup: Int]
    let style: OutlineLaneStyle

    private let canvas = CGSize(width: 300, height: 112)
    private let notchWidth: CGFloat = 170
    private let bandHeight: CGFloat = 30

    var body: some View {
        GeometryReader { proxy in
            scene(scale: proxy.size.width / canvas.width)
        }
        .aspectRatio(canvas.width / canvas.height, contentMode: .fit)
    }

    private func scene(scale: CGFloat) -> some View {
        let outset = IslandDesignSystem.compactOutlineOutset
        let compactHeight = bandHeight + outset
        let shape = NotchIslandShape(
            topBandHeight: bandHeight,
            compactHeight: compactHeight,
            bodyBottomY: compactHeight,
            widthProgress: 0,
            compactSurfaceFrame: CGRect(
                x: (canvas.width - notchWidth) / 2 - outset,
                y: 0,
                width: notchWidth + outset * 2,
                height: compactHeight
            )
        )
        let total = counts.values.reduce(0, +)

        return ZStack(alignment: .top) {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color(red: 0.55, green: 0.47, blue: 0.38), Color(red: 0.27, green: 0.33, blue: 0.26), Color(red: 0.36, green: 0.43, blue: 0.25)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: bandHeight)
                Color(red: 0.69, green: 0.60, blue: 0.71)
            }

            shape.fill(IslandDesignSystem.surfaceFill)

            IslandStatusOutline(
                shape: shape,
                configuration: IslandOutlineConfiguration(
                    segments: IslandDesignSystem.outlineSegments(counts: counts, maxLanes: style.maxLanes),
                    laneStyle: style,
                    pulse: nil,
                    usesCrazyAnimations: false,
                    accessibilityLabel: "Outline preview"
                )
            )

            if total == 0 {
                Text("No pull requests")
                    .font(.system(size: 7, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 11)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: canvas.width * scale, height: canvas.height * scale, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator)
        }
    }
}

// MARK: - Sounds

private struct SoundSettingsPane: View {
    @ObservedObject var store: GitIslandStore
    @State private var customSounds: [String] = []
    @State private var importError: String?

    var body: some View {
        Form {
            Section {
                ForEach(IslandSoundEvent.allCases) { event in
                    soundRow(event)
                }
            } header: {
                Text("Events")
            } footer: {
                Text("When one refresh brings several changes, only the most important one plays.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if customSounds.isEmpty {
                    Text("Import an audio file to use it for any event.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(customSounds, id: \.self) { fileName in
                        HStack {
                            Image(systemName: "waveform")
                                .foregroundStyle(.secondary)
                            Text(IslandSoundChoice.custom(fileName).label)
                            Spacer()
                            Button {
                                IslandSoundPlayer.shared.play(.custom(fileName))
                            } label: {
                                Image(systemName: "play.fill")
                            }
                            .buttonStyle(.borderless)
                            .help("Play")
                            Button(role: .destructive) {
                                store.deleteCustomSound(named: fileName)
                                reloadCustomSounds()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                        }
                    }
                }

                if let importError {
                    Text(importError)
                        .foregroundStyle(.red)
                }
            } header: {
                HStack {
                    Text("Your sounds")
                    Spacer()
                    Button("Import…") {
                        importSound(for: nil)
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            reloadCustomSounds()
        }
    }

    private func soundRow(_ event: IslandSoundEvent) -> some View {
        let choice = store.sound(for: event)

        return HStack(spacing: 12) {
            SettingsIcon(symbol: event.symbol, tint: event.tint)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                Text(event.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                IslandSoundPlayer.shared.play(choice)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(choice == .none)
            .help("Play")

            soundMenu(for: event, choice: choice)
                .frame(width: 150, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    private func soundMenu(for event: IslandSoundEvent, choice: IslandSoundChoice) -> some View {
        Menu {
            soundOption(.none, for: event, current: choice)

            Section("macOS") {
                ForEach(IslandSoundPlayer.shared.systemSoundNames, id: \.self) { name in
                    soundOption(.system(name), for: event, current: choice)
                }
            }

            if !customSounds.isEmpty {
                Section("Your sounds") {
                    ForEach(customSounds, id: \.self) { fileName in
                        soundOption(.custom(fileName), for: event, current: choice)
                    }
                }
            }

            Divider()

            Button("Choose a File…") {
                importSound(for: event)
            }
        } label: {
            Text(choice.label)
        }
        .fixedSize()
    }

    /// Picking a sound plays it, so the menu doubles as a preview.
    private func soundOption(_ option: IslandSoundChoice, for event: IslandSoundEvent, current: IslandSoundChoice) -> some View {
        Button {
            store.updateSound(option, for: event)
            IslandSoundPlayer.shared.play(option)
        } label: {
            if option == current {
                Label(option.label, systemImage: "checkmark")
            } else {
                Text(option.label)
            }
        }
    }

    private func reloadCustomSounds() {
        customSounds = IslandSoundPlayer.shared.customSoundFileNames()
    }

    private func importSound(for event: IslandSoundEvent?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = event.map { "Choose a sound for \($0.title.lowercased())" } ?? "Choose a sound to import"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let fileName = try IslandSoundPlayer.shared.importCustomSound(from: url)
            reloadCustomSounds()
            importError = nil
            if let event {
                store.updateSound(.custom(fileName), for: event)
            }
            IslandSoundPlayer.shared.play(.custom(fileName))
        } catch {
            importError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

// MARK: - Refresh

private struct RelaySettingsSection: View {
    @ObservedObject var store: GitIslandStore
    @State private var origin = UserPreferences.relayOrigin
    @State private var message: String?
    @AppStorage("relayHookURL") private var hookURL = ""
    @State private var hook: RelayHook?
    @State private var hookBusy = false

    private var hookClient: RelayHookClient? {
        guard let configuration = store.currentRelayConfiguration else { return nil }
        return RelayHookClient(configuration: configuration)
    }

    var body: some View {
        Section {
            DisclosureGroup("Advanced live update settings") {
                Text("Connection settings for this Mac. A saved token is kept in Keychain and is never displayed here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Relay origin", text: $origin)
                Text("This build only sends live credentials to its official relay service.").font(.caption)
                Button("Save") {
                    do {
                        try store.configureRelay(origin: origin)
                        message = "Saved. Clear the origin to disable live updates."
                    } catch {
                        message = "Could not save. Use the official relay address, or clear it to disable live updates. Wait for any authorization in progress."
                    }
                }
                .disabled(store.relayDevice.isBusy)
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Divider()
                Text("External services")
                    .font(.headline)
                Text("Wake hooks let another service request an inbox refresh. They are not needed for GitHub updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let savedHookURL = URL(string: hookURL), !hookURL.isEmpty {
                    LabeledContent("Hook URL") { Text(savedHookURL.absoluteString).textSelection(.enabled) }
                    if let hook {
                        LabeledContent("Hook secret") { Text(hook.secret).textSelection(.enabled) }
                        Text("Save this secret now. Relay only returns it once.").font(.caption)
                    }
                    Button("Revoke hook", role: .destructive) {
                        guard let client = hookClient else { return }
                        hookBusy = true
                        Task {
                            defer { hookBusy = false }
                            do {
                                try await client.revoke(url: savedHookURL)
                                self.hook = nil
                                hookURL = ""
                                message = "Hook revoked."
                            } catch { message = "Could not revoke hook." }
                        }
                    }.disabled(hookBusy)
                    Button("Forget saved hook") {
                        hook = nil
                        hookURL = ""
                        message = "Forgotten on this Mac. The remote hook remains active."
                    }.disabled(hookBusy)
                    Text("Forgetting removes the saved URL from this Mac without revoking the remote hook.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Create wake hook") {
                        guard let client = hookClient else { return }
                        hookBusy = true
                        Task {
                            defer { hookBusy = false }
                            do {
                                let created = try await client.create()
                                hook = created
                                hookURL = created.url.absoluteString
                            }
                            catch { message = "Could not create hook." }
                        }
                    }.disabled(hookBusy || hookClient == nil)
                }
            }
        }
    }
}

private struct RelayAuthorizationSection: View {
    @ObservedObject var device: RelayDeviceSession
    @State private var confirmRevoke = false

    var body: some View {
        Section("This Mac") {
            if let credentials = device.credentials {
                DisclosureGroup("Authorization details") {
                    LabeledContent("Computer", value: credentials.pair.computer_id)
                    if let installations = credentials.pair.installations {
                        LabeledContent("GitHub installations", value: installations.joined(separator: ", "))
                    }
                    LabeledContent("Relay", value: credentials.origin)
                }
            }
            if device.canRevoke {
                Text("Live access renews automatically. Signing out of GitHub keeps this Mac’s authorization.")
                    .foregroundStyle(.secondary)
                Button("Revoke this Mac’s live access", role: .destructive) { confirmRevoke = true }
                    .disabled(device.isBusy)
                    .confirmationDialog("Revoke live access for this Mac?", isPresented: $confirmRevoke) {
                        Button("Revoke access", role: .destructive) { device.revoke() }
                    } message: {
                        Text("Other computers keep their access. This Mac will use periodic checks until you authorize it again.")
                    }
            }
            Group {
                Button(device.isBusy ? "Waiting for authorization…" : (device.canRevoke ? "Manage connected GitHub accounts…" : "Authorize this Mac for live updates")) {
                    device.enroll(origin: UserPreferences.relayOrigin)
                }
                .disabled(device.isBusy || UserPreferences.relayOrigin.isEmpty)
                Text(device.canRevoke
                     ? "Select all the GitHub accounts and organizations you want in your browser. The new selection replaces the previous one only after authorization succeeds."
                     : "Select the GitHub accounts and organizations you want to connect in your browser.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if device.isEnrolling {
                Button("Cancel setup") { device.cancelEnrollment() }
            }
            if let message = device.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct RefreshSettingsPane: View {
    @ObservedObject var store: GitIslandStore

    private var intervalSelection: Binding<RefreshIntervalOption> {
        Binding(
            get: { RefreshIntervalOption(rawValue: store.refreshIntervalSeconds) ?? .oneMinute },
            set: { store.updateRefreshInterval($0.rawValue) }
        )
    }

    var body: some View {
        Form {
            Section {
                Label(store.automaticRefreshTitle,
                      systemImage: store.relayConnected ? "bolt.horizontal.circle.fill" : "arrow.clockwise.circle")
                    .font(.headline)
                Text(store.automaticRefreshDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.isAuthenticated && store.relayConnected && !store.githubRefreshPaused {
                    LabeledContent("If the connection drops", value: "Check GitHub every minute")
                }
            } header: {
                Text("How your inbox stays updated")
            }

            Section {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.refreshSettingsStatus)
                        Text(store.refreshSettingsDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button(store.refreshActionTitle) {
                        store.refresh(force: true)
                    }
                    .disabled(!store.isAuthenticated)
                }
                .padding(.vertical, 2)
            } header: {
                Text("Status")
            }

            if store.isAuthenticated && !store.relayConnected {
                Section {
                    if store.hasRelayConfiguration {
                        if !store.githubRefreshPaused {
                            LabeledContent("Check GitHub", value: "Every minute until reconnected")
                        }
                    } else {
                        Picker("Idle check interval", selection: intervalSelection) {
                            ForEach(RefreshIntervalOption.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                    }
                    LabeledContent("Next scheduled check", value: store.nextAutomaticRefreshStatus)
                } header: {
                    Text("Scheduled checks")
                }
            }

            RelayAuthorizationSection(device: store.relayDevice)
            RelaySettingsSection(store: store)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Repositories

private struct RepositorySettingsPane: View {
    @ObservedObject var store: GitIslandStore
    @State private var repositoryInput = ""

    private var modeSelection: Binding<RepositoryFilterMode> {
        Binding(
            get: { store.repositoryFilterMode },
            set: { store.updateRepositoryFilterMode($0) }
        )
    }

    private var normalizedRepositoryInput: String? {
        UserPreferences.normalizedRepositoryFullName(repositoryInput)
    }

    private var canAddRepositoryInput: Bool {
        guard let normalizedRepositoryInput else { return false }
        return !store.isRepositorySelected(normalizedRepositoryInput)
    }

    var body: some View {
        Form {
            Section {
                Picker("Show pull requests from", selection: modeSelection) {
                    ForEach(RepositoryFilterMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(!store.isAuthenticated)

                LabeledContent("Selection", value: store.repositoryScopeStatus)
            } header: {
                Text("Scope")
            }

            if store.repositoryFilterMode == .selected {
                Section {
                    HStack(spacing: 8) {
                        TextField("owner/repository", text: $repositoryInput)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addRepositoryFromInput)

                        Button("Add") {
                            addRepositoryFromInput()
                        }
                        .disabled(!canAddRepositoryInput)
                    }
                    .disabled(!store.isAuthenticated)

                    if store.selectedRepositoryFullNames.isEmpty {
                        Text("No repositories selected")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.selectedRepositoryFullNames, id: \.self) { repositoryFullName in
                            namedRow(repositoryFullName, actionTitle: "Remove") {
                                store.removeSelectedRepository(repositoryFullName)
                            }
                        }
                    }
                } header: {
                    Text("Selected")
                } footer: {
                    Text("GitHub search includes only these repositories.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if store.mutedRepositoryFullNames.isEmpty {
                    Text("No muted repositories")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.mutedRepositoryFullNames, id: \.self) { repositoryFullName in
                        namedRow(repositoryFullName, actionTitle: "Unmute") {
                            store.unmuteRepository(repositoryFullName)
                        }
                    }
                }
            } header: {
                Text("Muted")
            } footer: {
                Text("Right-click a pull request to mute its repository. Muted repositories stay out of the inbox.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if store.hiddenPullRequests.isEmpty {
                    Text("No hidden pull requests")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.hiddenPullRequests) { pullRequest in
                        HStack(spacing: 8) {
                            Text("\(pullRequest.repositoryFullName) #\(pullRequest.number)")
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            Button("Show") {
                                store.showHiddenPullRequest(id: pullRequest.id)
                            }
                            .disabled(!store.isAuthenticated)
                        }
                    }
                }
            } header: {
                Text("Hidden")
            } footer: {
                Text("Right-click a pull request to hide it. It comes back when its status, head, or reason changes.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func namedRow(
        _ repositoryFullName: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            repositoryLabel(repositoryFullName)
            Spacer(minLength: 0)
            Button(actionTitle, action: action)
                .disabled(!store.isAuthenticated)
        }
    }

    private func repositoryLabel(_ repositoryFullName: String) -> some View {
        let parts = repositoryFullName.split(separator: "/", maxSplits: 1).map(String.init)
        return HStack(spacing: 0) {
            if parts.count == 2 {
                Text(parts[0] + "/")
                    .foregroundStyle(.secondary)
                Text(parts[1])
            } else {
                Text(repositoryFullName)
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }

    private func addRepositoryFromInput() {
        guard let normalizedRepositoryInput else { return }
        store.addSelectedRepository(normalizedRepositoryInput)
        repositoryInput = ""
    }
}
