import SwiftUI
import KeyboardShortcuts

@MainActor
@Observable
final class ProfileManager {
    var profiles: [ChromeProfile] = []

    init() {
        loadProfiles()
    }

    func loadProfiles() {
        profiles = ChromeProfileService.loadProfiles()
        registerShortcuts()
    }

    private func registerShortcuts() {
        KeyboardShortcuts.removeAllHandlers()

        for profile in profiles.prefix(KeyboardShortcuts.Name.maxSlots) {
            let name = KeyboardShortcuts.Name.forProfile(profile.directoryName)
            KeyboardShortcuts.onKeyUp(for: name) {
                ChromeLauncher.switchToProfile(profile)
            }
        }
    }
}

@main
struct DirigerApp: App {
    @State private var profileManager = ProfileManager()

    var body: some Scene {
        MenuBarExtra("Diriger", systemImage: "globe") {
            MenuBarView(
                profiles: profileManager.profiles,
                onRefresh: { profileManager.loadProfiles() }
            )
        }

        Settings {
            SettingsView(profiles: profileManager.profiles)
        }
    }
}
