import SwiftUI
import AppKit
import KeyboardShortcuts

struct MenuBarView: View {
    @Environment(ProfileManager.self) private var profileManager
    @Environment(RecentLinksStore.self) private var recentLinks
    @Environment(DefaultBrowserMonitor.self) private var browserMonitor
    @Environment(\.openSettings) private var openSettings

    let openInPicker: (URL) -> Void

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

        if browserMonitor.isDefault {
            Divider()

            Section("Recent Links") {
                if recentLinks.links.isEmpty {
                    Text("No recent links")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recentLinks.links, id: \.self) { url in
                        Button {
                            openInPicker(url)
                        } label: {
                            Label {
                                Text(recentLinkLabel(for: url))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 380, alignment: .leading)
                            } icon: {
                                Image(systemName: "link")
                            }
                        }
                    }
                }
            }
        }

        Divider()

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
        let name = KeyboardShortcuts.Name.forProfile(ProfileIdentity.forProfile(profile))
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

    private func recentLinkLabel(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = nil
        let raw = components?.string ?? url.absoluteString
        return raw.hasPrefix("//") ? String(raw.dropFirst(2)) : raw
    }
}
