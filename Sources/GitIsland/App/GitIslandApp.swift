import AppKit
import Combine
import Network
import SwiftUI

@main
struct GitIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = GitIslandStore.shared

    var body: some Scene {
        MenuBarExtra {
            GitIslandMenuView(
                store: store,
                onSignIn: appDelegate.showOnboarding,
                onOpenSettings: appDelegate.showSettings
            )
        } label: {
            Label {
                Text(store.menuBarTitle)
            } icon: {
                GitIslandMenuBarIcon()
            }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(store: store, onSignIn: appDelegate.showOnboarding)
        }
    }
}

private struct GitIslandMenuBarIcon: View {
    var body: some View {
        Image(nsImage: Self.image)
            .accessibilityHidden(true)
    }

    @MainActor
    private static let image: NSImage = {
        let canvasSize = NSSize(width: 18, height: 18)
        let fallback = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Git Island")
            ?? NSImage(size: canvasSize)

        let sourceURL = Bundle.main.url(forResource: "git-island-menu-bar", withExtension: "svg")

        guard let sourceURL,
            let sourceImage = NSImage(contentsOf: sourceURL)
        else {
            fallback.size = canvasSize
            fallback.isTemplate = true
            return fallback
        }

        let image = NSImage(size: canvasSize)
        image.lockFocus()

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: canvasSize).fill()

        let sourceSize = sourceImage.size
        let aspectRatio = max(sourceSize.width, 1) / max(sourceSize.height, 1)
        let drawWidth = canvasSize.width
        let drawHeight = min(canvasSize.height, drawWidth / aspectRatio)
        let drawRect = NSRect(
            x: (canvasSize.width - drawWidth) / 2,
            y: (canvasSize.height - drawHeight) / 2,
            width: drawWidth,
            height: drawHeight
        )

        sourceImage.draw(
            in: drawRect,
            from: NSRect(origin: .zero, size: sourceSize),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )

        image.unlockFocus()
        image.isTemplate = true
        return image
    }()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var connectionObservations = Set<AnyCancellable>()
    private var islandController: IslandPanelController?
    private let onboardingController = OnboardingWindowController()
    private let settingsController = SettingsWindowController()
    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "GitIsland.NetworkMonitor")
    private var lastForegroundRefresh: Date?
    private var lastNetworkStatus: NWPath.Status?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureAuthenticatedExperience()
        let store = GitIslandStore.shared
        // @Published emits every assignment, including true -> true. Do not
        // deduplicate: another 401 must reopen recovery after the user closes it.
        store.$githubAuthorizationRequired.filter { $0 }
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.showOnboarding() }
            .store(in: &connectionObservations)
        store.$isAuthenticated.removeDuplicates().filter { $0 }
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.presentIsland() }
            .store(in: &connectionObservations)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        startNetworkMonitoring()
    }

    @objc private func applicationDidBecomeActive() {
        guard GitIslandStore.shared.isAuthenticated else {
            return
        }

        if let lastForegroundRefresh,
           Date().timeIntervalSince(lastForegroundRefresh) < 10 {
            return
        }

        lastForegroundRefresh = Date()
        GitIslandStore.shared.refreshAfterUserInteraction()
    }

    @objc private func systemDidWake() {
        GitIslandStore.shared.refreshAfterSystemEvent()
    }

    func applicationWillTerminate(_ notification: Notification) {
        GitIslandStore.shared.stopAutoRefresh()
        networkMonitor.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        islandController?.close()
    }

    func showOnboarding() {
        onboardingController.present(store: GitIslandStore.shared) { [weak self] in
            self?.onboardingDidComplete()
        }
    }

    func showSettings() {
        settingsController.present(store: GitIslandStore.shared, onSignIn: showOnboarding)
    }

    private func configureAuthenticatedExperience() {
        let store = GitIslandStore.shared

        if store.isAuthenticated {
            presentIsland()
            store.startAutoRefresh()
            if !UserDefaults.standard.bool(forKey: "onboardingCompleted") { showOnboarding() }
        } else {
            showOnboarding()
        }
    }

    private func presentIsland() {
        if islandController == nil {
            islandController = IslandPanelController(store: GitIslandStore.shared)
        }

        islandController?.show()
    }

    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else {
                    return
                }

                let previousStatus = self.lastNetworkStatus
                self.lastNetworkStatus = path.status

                guard previousStatus != nil,
                      previousStatus != .satisfied,
                      path.status == .satisfied
                else {
                    return
                }

                GitIslandStore.shared.refreshAfterSystemEvent()
            }
        }

        networkMonitor.start(queue: networkMonitorQueue)
    }
}

extension AppDelegate {
    func onboardingDidComplete() {
        onboardingController.dismiss()
        presentIsland()
        GitIslandStore.shared.startAutoRefresh()
    }
}
