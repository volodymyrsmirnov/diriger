import SwiftUI
import AppKit
import KeyboardShortcuts

@MainActor
@Observable
final class ProfileManager {
    var profiles: [ChromeProfile] = []

    private let watcher: ChromeLocalStateWatcher
    private var remoteObserver: NSObjectProtocol?
    private var registeredShortcutKeys: Set<SyncedKey> = []

    init() {
        let watcher = ChromeLocalStateWatcher()
        self.watcher = watcher
        watcher.onChange = { [weak self] in
            Task { @MainActor in await self?.loadProfiles() }
        }
        Task { await loadProfiles() }
        watcher.start()

        remoteObserver = NotificationCenter.default.addObserver(
            forName: SyncedDefaults.keyDidChangeRemotelyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let name = (note.userInfo?["key"] as? String) ?? ""
            MainActor.assumeIsolated {
                guard name.hasPrefix("KeyboardShortcuts_profile_shortcut_") else { return }
                self?.registerShortcuts()
            }
        }
    }

    // No deinit cleanup: Swift 6 strict concurrency disallows touching @MainActor-isolated
    // observer tokens from a nonisolated deinit, and this class is app-lifetime. The
    // notification closure uses [weak self] so post-deallocation firings are no-ops.

    func loadProfiles() async {
        profiles = await ChromeProfileService.loadProfiles()
        updateSyncedShortcutRegistrations()
        registerShortcuts()
    }

    private func updateSyncedShortcutRegistrations() {
        let desired: Set<SyncedKey> = Set(
            profiles.prefix(KeyboardShortcuts.Name.maxSlots).map { profile in
                SyncedKey.profileShortcut(for: ProfileIdentity.forProfile(profile))
            }
        )

        for key in desired.subtracting(registeredShortcutKeys) {
            SyncedDefaults.shared.register(key)
            SyncedDefaults.shared.observeLibraryOwnedKey(key)
        }
        for key in registeredShortcutKeys.subtracting(desired) {
            SyncedDefaults.shared.stopObservingLibraryOwnedKey(key)
        }
        registeredShortcutKeys = desired
    }

    private func registerShortcuts() {
        KeyboardShortcuts.removeAllHandlers()

        for profile in profiles.prefix(KeyboardShortcuts.Name.maxSlots) {
            let identity = ProfileIdentity.forProfile(profile)
            let name = KeyboardShortcuts.Name.forProfile(identity)
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
        MenuBarExtra("Diriger", systemImage: "wand.and.outline") {
            MenuBarView()
                .environment(appDelegate.profileManager)
        }

        Settings {
            SettingsView()
                .environment(appDelegate.profileManager)
                .environment(appDelegate.ruleStore)
        }
    }
}
