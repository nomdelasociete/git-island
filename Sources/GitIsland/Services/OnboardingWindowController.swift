import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: OnboardingWindow?
    private(set) var dismissedByUser = false

    func present(store: GitIslandStore, automatically: Bool = false, onComplete: @escaping () -> Void) {
        guard !automatically || !dismissedByUser else { return }
        if window?.isVisible == true {
            bringToFront()
            return
        }

        let contentView = OnboardingView(
            store: store,
            onDismiss: { [weak self] in self?.dismiss() },
            onComplete: { [weak self] in
                self?.dismiss()
                onComplete()
            }
        )

        let window = OnboardingWindow(
            contentRect: NSRect(origin: .zero, size: OnboardingDesign.windowSize)
        )
        window.delegate = self
        window.title = "Git Island"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        window.contentView = NSHostingView(rootView: contentView)
        self.window = window
        bringToFront()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        dismissedByUser = true
        // Retain the host until the SwiftUI action and AppKit close callback return.
        DispatchQueue.main.async { [weak self, closingWindow] in
            closingWindow.contentView = nil
            if self?.window === closingWindow { self?.window = nil }
        }
    }

    func bringToFront() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        window?.close()
    }
}

private final class OnboardingWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        level = .normal
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}
