import Combine
import Foundation
#if DIRECT_DISTRIBUTION && !DEBUG
import Sparkle
#endif

/// Only Developer ID builds contain an active updater. TestFlight builds do not
/// link Sparkle at all; Debug builds never check the production update feed.
@MainActor
final class AppUpdateService: ObservableObject {
    static let shared = AppUpdateService()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyDownloads = false
    @Published private(set) var error: String?

#if DIRECT_DISTRIBUTION && !DEBUG
    let isAvailable = true
    private var controller: SPUStandardUpdaterController?
#else
    let isAvailable = false
#endif

    func start() {
#if DIRECT_DISTRIBUTION && !DEBUG
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloads)
        do {
            try updater.start()
        } catch {
            self.error = "Updates could not start: \(error.localizedDescription)"
        }
#endif
    }

    func checkForUpdates() {
#if DIRECT_DISTRIBUTION && !DEBUG
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
#endif
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
#if DIRECT_DISTRIBUTION && !DEBUG
        controller?.updater.automaticallyChecksForUpdates = enabled
#endif
    }

    func setAutomaticallyDownloads(_ enabled: Bool) {
#if DIRECT_DISTRIBUTION && !DEBUG
        controller?.updater.automaticallyDownloadsUpdates = enabled
#endif
    }
}
