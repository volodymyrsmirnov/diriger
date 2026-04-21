import SwiftUI
import AppKit
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

@MainActor
final class AppServices {
    static let shared = AppServices()

    let profileManager: ProfileManager
    let ruleStore: RuleStore
    let linkPicker: LinkPickerController

    private init() {
        let manager = ProfileManager()
        self.profileManager = manager
        self.ruleStore = RuleStore()
        self.linkPicker = LinkPickerController(profileManager: manager)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURL(event:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc
    func handleURL(event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString)
        else { return }

        let sourcePID = event.attributeDescriptor(
            forKeyword: AEKeyword(keySenderPIDAttr)
        )?.int32Value
        let sourceBundleID = sourcePID.flatMap {
            NSRunningApplication(processIdentifier: pid_t($0))?.bundleIdentifier
        }

        Task { @MainActor in
            let services = AppServices.shared
            if let profile = RuleEngine.firstMatch(
                in: services.ruleStore.rules,
                url: url,
                sourceBundleID: sourceBundleID,
                availableProfiles: services.profileManager.profiles
            ) {
                ChromeLauncher.openURL(url, in: profile)
            } else {
                services.linkPicker.present(url: url, source: sourceBundleID)
            }
        }
    }
}

@main
struct DirigerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let services = AppServices.shared

    var body: some Scene {
        MenuBarExtra("Diriger", systemImage: "globe") {
            MenuBarView(
                profiles: services.profileManager.profiles,
                onRefresh: { services.profileManager.loadProfiles() }
            )
        }

        Settings {
            SettingsView(
                profiles: services.profileManager.profiles,
                ruleStore: services.ruleStore
            )
        }
    }
}
