import AppKit
import SwiftUI

struct GitIslandMenuView: View {
    @ObservedObject var store: GitIslandStore
    let onSignIn: () -> Void
    let onOpenSettings: () -> Void

#if DEBUG
    private var crazyAnimationsSelection: Binding<Bool> {
        Binding(
            get: {
                store.crazyAnimationsEnabled
            },
            set: { enabled in
                store.updateCrazyAnimationsEnabled(enabled)
            }
        )
    }
#endif

    var body: some View {
        if store.isAuthenticated {
            Button(store.isExpanded ? "Collapse Island" : "Open Island") {
                if store.isExpanded {
                    store.collapse()
                } else {
                    store.open(.blocked)
                }
            }

            Divider()

            Button(store.isLoading ? "Restart GitHub Refresh" : "Refresh GitHub") {
                store.refresh(force: true)
            }

            Text(store.refreshStatus)

            Divider()

            ForEach(PullRequestGroup.allCases.sorted { $0.compactPriority < $1.compactPriority }) { group in
                Button("\(group.rawValue) \(store.count(for: group))") {
                    store.open(group)
                }
            }

            Divider()

            Button("Settings...") {
                onOpenSettings()
            }

            Button("Sign out") {
                store.signOut()
                onSignIn()
            }

            Divider()
        } else {
            Button("Sign in with GitHub...") {
                onSignIn()
            }

            Divider()

            Button("Settings...") {
                onOpenSettings()
            }

            Divider()
        }

#if DEBUG
        Toggle("Crazy Animations", isOn: crazyAnimationsSelection)

        Button("Preview PR Change Cue") {
            store.triggerDebugStatusChangeCue()
        }

        Button("Preview Merge Confetti") {
            store.triggerDebugMergeCelebration()
        }

        Divider()
#endif

        Button("Quit Git Island") {
            NSApplication.shared.terminate(nil)
        }
    }
}
