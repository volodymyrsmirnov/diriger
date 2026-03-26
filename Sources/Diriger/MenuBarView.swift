import SwiftUI
import KeyboardShortcuts

struct MenuBarView: View {
    let profiles: [ChromeProfile]
    let onRefresh: () -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if profiles.isEmpty {
            Text("No Chrome profiles found")
                .foregroundStyle(.secondary)
        } else {
            ForEach(profiles) { profile in
                Button {
                    ChromeLauncher.switchToProfile(profile)
                } label: {
                    Label {
                        Text(profileLabel(for: profile))
                    } icon: {
                        profileImage(for: profile)
                    }
                }
                .badge(shortcutLabel(for: profile))
            }
        }

        Divider()

        Button("Refresh Profiles") {
            onRefresh()
        }

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
        if profile.email.isEmpty {
            return profile.displayName
        }
        return "\(profile.displayName) (\(profile.email))"
    }

    private func profileImage(for profile: ChromeProfile) -> Image {
        let path = ChromeProfileService.profilePicturePath(for: profile)
        if let nsImage = NSImage(contentsOfFile: path) {
            return Image(nsImage: circularImage(nsImage, size: 18))
        }
        return Image(systemName: "person.circle.fill")
    }

    private func circularImage(_ source: NSImage, size: CGFloat) -> NSImage {
        let result = NSImage(size: NSSize(width: size, height: size))
        result.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        NSBezierPath(ovalIn: rect).addClip()
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        result.unlockFocus()
        result.isTemplate = false
        return result
    }
}
