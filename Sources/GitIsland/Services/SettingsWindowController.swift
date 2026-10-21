import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func present(store: GitIslandStore, onSignIn: @escaping () -> Void) {
        if let window {
            bringToFront(window)
            return
        }

        let contentView = SettingsView(store: store, onSignIn: onSignIn)
        let hostingController = NSHostingController(rootView: contentView)
        hostingController.sizingOptions = [.minSize]

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Git Island Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 820, height: 600))
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.setFrameAutosaveName("GitIslandSettings")
        window.center()

        self.window = window
        bringToFront(window)
    }

    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKey()

        Task { @MainActor in
            window.orderFrontRegardless()
            window.makeKey()
        }
    }
}
