import SwiftUI
import AppKit
import KeyboardShortcuts

struct MenuBarView: View {
    let onRefresh: () -> Void

    @Environment(ProfileManager.self) private var profileManager
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if profileManager.profiles.isEmpty {
            Text("No Chrome profiles found")
                .foregroundStyle(.secondary)
        } else {
            ForEach(profileManager.profiles) { profile in
                Button {
                    Task {
                        do {
                            try await ChromeLauncher.switchToProfile(profile)
                        } catch {
                            Log.chrome.error("switchToProfile failed: \(error.localizedDescription, privacy: .public)")
                            ErrorAlert.present(error)
                        }
                    }
                } label: {
                    Label {
                        Text(profileLabel(for: profile))
                    } icon: {
                        menuIcon(for: profile)
                    }
                }
                .badge(shortcutLabel(for: profile))
            }
        }

        Divider()

        Button("Refresh Profiles", action: onRefresh)

        Button("Settings...") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func shortcutLabel(for profile: ChromeProfile) -> Text {
        let name = KeyboardShortcuts.Name.forProfile(profile.directoryName)
        if let shortcut = KeyboardShortcuts.getShortcut(for: name) {
            return Text(shortcut.description)
        }
        return Text("")
    }

    private func profileLabel(for profile: ChromeProfile) -> String {
        profile.email.isEmpty
            ? profile.displayName
            : "\(profile.displayName) (\(profile.email))"
    }

    @ViewBuilder
    private func menuIcon(for profile: ChromeProfile) -> some View {
        if let image = ProfileAvatar(profile: profile, size: 18).rasterized() {
            Image(nsImage: image)
        } else {
            Image(systemName: "person.circle.fill")
        }
    }
}
