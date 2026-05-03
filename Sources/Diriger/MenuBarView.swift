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
                    ForEach(recentLinks.links, id: \.self) { link in
                        Button {
                            openInPicker(link.url)
                        } label: {
                            Label {
                                Text(recentLinkLabel(for: link.url))
                            } icon: {
                                recentLinkIcon(for: link)
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

    private func shortcutLabel(for profile: ChromeProfile) -> Text? {
        let name = KeyboardShortcuts.Name.forProfile(ProfileIdentity.forProfile(profile))
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return nil }
        return Text(shortcut.description)
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

    @ViewBuilder
    private func recentLinkIcon(for link: RecentLink) -> some View {
        if let bundleID = link.sourceBundleID,
           let image = AppIconProvider.icon(forBundleID: bundleID, size: NSSize(width: 18, height: 18)) {
            Image(nsImage: image)
        } else {
            Image(systemName: "link")
        }
    }

    private func recentLinkLabel(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = nil
        let raw = components?.string ?? url.absoluteString
        let stripped = raw.hasPrefix("//") ? String(raw.dropFirst(2)) : raw
        return truncateMiddle(stripped, limit: 60)
    }

    private func truncateMiddle(_ s: String, limit: Int) -> String {
        guard s.count > limit else { return s }
        let keep = limit - 1
        let head = keep / 2 + keep % 2
        let tail = keep / 2
        return s.prefix(head) + "…" + s.suffix(tail)
    }
}
