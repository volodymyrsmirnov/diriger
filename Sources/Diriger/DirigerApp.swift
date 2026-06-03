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
                guard SyncedKey.isProfileShortcutKeyName(name) else { return }
                // Precondition: SyncedDefaults.reconcile() writes the new value into
                // UserDefaults BEFORE posting this notification, so registerShortcuts()
                // re-reading from UserDefaults sees the fresh value.
                self?.registerShortcuts()
            }
        }
    }

    // No deinit cleanup: Swift 6 strict concurrency disallows touching @MainActor-isolated
    // observer tokens from a nonisolated deinit, and this class is app-lifetime. The
    // notification closure uses [weak self] so post-deallocation firings are no-ops.

    func loadProfiles() async {
        profiles = await ChromeProfileService.loadProfiles()
        ProfileAvatar.invalidateImageCache()
        updateSyncedShortcutRegistrations()
        registerShortcuts()
    }

    private func updateSyncedShortcutRegistrations() {
        let desired: Set<SyncedKey> = Set(
            profiles.prefix(KeyboardShortcuts.Name.maxSlots).map { profile in
                SyncedKey.profileShortcut(for: ProfileIdentity.forProfile(profile))
            }
        )

        let added = desired.subtracting(registeredShortcutKeys)
        for key in added {
            SyncedDefaults.shared.register(key)
            SyncedDefaults.shared.observeLibraryOwnedKey(key)
        }
        for key in registeredShortcutKeys.subtracting(desired) {
            SyncedDefaults.shared.stopObservingLibraryOwnedKey(key)
        }
        registeredShortcutKeys = desired

        // Shortcut keys are registered lazily after Chrome profiles load, which can
        // happen AFTER SyncedDefaults.start() at launch. Trigger a reconcile now so
        // newly-registered keys get their initial cloud pull. No-op when sync is off.
        if !added.isEmpty {
            SyncedDefaults.shared.reconcileAll()
        }
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
    let recentLinks: RecentLinksStore
    let browserMonitor: DefaultBrowserMonitor

    override init() {
        // Migration MUST run before RuleStore initializes — RuleStore caches rules
        // from UserDefaults in memory at init, so any post-init migration would be
        // overwritten by the first user edit.
        SyncMigration.runIfNeeded()
        let pm = ProfileManager()
        self.profileManager = pm
        self.ruleStore = RuleStore()
        self.linkPicker = LinkPickerController(profileManager: pm)
        self.recentLinks = RecentLinksStore()
        self.browserMonitor = DefaultBrowserMonitor()
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
            SyncedDefaults.shared.start()
        }
    }

    // http(s) URLs from other apps arrive as GURL Apple Events (our custom handler,
    // installed above). Local files opened from Finder — e.g. an .html document when
    // Diriger is the handler — arrive instead through AppKit's kAEOpenDocuments path,
    // delivered here. Both funnel into route(urls:sourceBundleID:).
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
        route(urls: [url], sourceBundleID: senderBundleID(of: event))
    }

    nonisolated func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            let fileURLs = urls.filter(\.isFileURL)
            guard !fileURLs.isEmpty else { return }
            // The kAEOpenDocuments event being processed carries the sending app's PID,
            // so source-based rules (e.g. "files from Finder") still apply.
            let sourceBundleID = NSAppleEventManager.shared().currentAppleEvent
                .flatMap(senderBundleID(of:))
            route(urls: fileURLs, sourceBundleID: sourceBundleID)
        }
    }

    private func senderBundleID(of event: NSAppleEventDescriptor) -> String? {
        guard let pid = event
            .attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?
            .int32Value
        else { return nil }
        return NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier
    }

    private func route(urls: [URL], sourceBundleID: String?) {
        let bypassRules = NSEvent.modifierFlags.contains(.shift)
        var unmatched: [URL] = []
        for url in urls {
            recentLinks.record(url, sourceBundleID: sourceBundleID)
            let matched = bypassRules ? nil : RuleEngine.firstMatch(
                in: ruleStore.rules,
                url: url,
                sourceBundleID: sourceBundleID,
                availableProfiles: profileManager.profiles
            )
            if let profile = matched {
                openInProfile([url], profile)
            } else {
                unmatched.append(url)
            }
        }
        if !unmatched.isEmpty {
            linkPicker.present(urls: unmatched)
        }
    }

    private func openInProfile(_ urls: [URL], _ profile: ChromeProfile) {
        Task {
            do {
                try await ChromeLauncher.openURLs(urls, in: profile)
            } catch {
                Log.chrome.error("openURL failed: \(error.localizedDescription, privacy: .public)")
                ErrorAlert.present(error)
            }
        }
    }
}

@main
struct DirigerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Diriger", systemImage: "wand.and.outline") {
            MenuBarView(openInPicker: { [linkPicker = appDelegate.linkPicker] url in
                linkPicker.present(url: url)
            })
                .environment(appDelegate.profileManager)
                .environment(appDelegate.recentLinks)
                .environment(appDelegate.browserMonitor)
        }

        Settings {
            SettingsView()
                .environment(appDelegate.profileManager)
                .environment(appDelegate.ruleStore)
                .environment(appDelegate.browserMonitor)
        }
    }
}
