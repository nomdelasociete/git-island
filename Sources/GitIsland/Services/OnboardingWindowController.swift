import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: OnboardingPanel?

    func present(store: GitIslandStore, onComplete: @escaping () -> Void) {
        if window?.isVisible == true {
            bringToFront()
            return
        }

        let contentView = OnboardingView(
            store: store,
            onBrowserOpened: { [weak self] in
                self?.bringToFront()
            },
            onComplete: { [weak self] in
                self?.dismiss()
                onComplete()
            }
        )

        let window = OnboardingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640)
        )
        window.delegate = self
        window.title = "Git Island"
        window.center()
        window.contentView = NSHostingView(rootView: contentView)
        self.window = window
        bringToFront()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        // Retain the host until the SwiftUI action and AppKit close callback return.
        DispatchQueue.main.async { [weak self, closingWindow] in
            closingWindow.contentView = nil
            if self?.window === closingWindow { self?.window = nil }
        }
    }

    func bringToFront() {
        window?.orderFrontRegardless()
    }

    func dismiss() {
        window?.close()
    }
}

private final class OnboardingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}