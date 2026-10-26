import SwiftUI

struct CheckForAppUpdatesButton: View {
    @ObservedObject private var updates = AppUpdateService.shared

    var body: some View {
        if updates.isAvailable {
            Button("Check for Updates…", action: updates.checkForUpdates)
                .disabled(!updates.canCheckForUpdates)
        }
    }
}

struct AppUpdateSettings: View {
    @ObservedObject private var updates = AppUpdateService.shared

    var body: some View {
        if updates.isAvailable {
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updates.automaticallyChecks },
                set: { updates.setAutomaticallyChecks($0) }
            ))
            Toggle("Automatically download and install updates", isOn: Binding(
                get: { updates.automaticallyDownloads },
                set: { updates.setAutomaticallyDownloads($0) }
            ))
            .disabled(!updates.automaticallyChecks)
            Text("Updates install when Git Island quits. If it stays open, you’ll be prompted to restart.")
                .font(.caption)
                .foregroundStyle(.secondary)
            CheckForAppUpdatesButton()
            if let error = updates.error {
                Text(error).foregroundStyle(.red)
            }
        }
    }
}
