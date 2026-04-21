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
                Task { @MainActor in
                    do {
                        try await ChromeLauncher.switchToProfile(profile)
                    } catch {
                        Log.chrome.error("switchToProfile failed: \(error.localizedDescription, privacy: .public)")
                        ErrorAlert.present(error)
                    }
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let profileManager: ProfileManager
    let ruleStore: RuleStore
    let linkPicker: LinkPickerController

    override init() {
        let pm = ProfileManager()
        self.profileManager = pm
        self.ruleStore = RuleStore()
        self.linkPicker = LinkPickerController(profileManager: pm)
        super.init()
    }

    nonisolated func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSAppleEventManager.shared().setEventHandler(
                self,
                andSelector: #selector(handleURL(event:replyEvent:)),
                forEventClass: AEEventClass(kInternetEventClass),
                andEventID: AEEventID(kAEGetURL)
            )
        }
    }

    @objc
    func handleURL(event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            Log.app.info("Ignoring non-http(s) URL event")
            return
        }

        let sourcePID = event
            .attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?
            .int32Value
        let sourceBundleID = sourcePID.flatMap {
            NSRunningApplication(processIdentifier: pid_t($0))?.bundleIdentifier
        }

        if let profile = RuleEngine.firstMatch(
            in: ruleStore.rules,
            url: url,
            sourceBundleID: sourceBundleID,
            availableProfiles: profileManager.profiles
        ) {
            Task {
                do {
                    try await ChromeLauncher.openURL(url, in: profile)
                } catch {
                    Log.chrome.error("openURL failed: \(error.localizedDescription, privacy: .public)")
                    ErrorAlert.present(error)
                }
            }
        } else {
            linkPicker.present(url: url)
        }
    }
}

@main
struct DirigerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Diriger", systemImage: "globe") {
            MenuBarView(onRefresh: { appDelegate.profileManager.loadProfiles() })
                .environment(appDelegate.profileManager)
        }

        Settings {
            SettingsView()
                .environment(appDelegate.profileManager)
                .environment(appDelegate.ruleStore)
        }
    }
}
