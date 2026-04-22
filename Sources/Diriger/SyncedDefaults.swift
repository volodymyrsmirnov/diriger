import Foundation
import AppKit
import KeyboardShortcuts

/// Identifies one UserDefaults key that is mirrored to iCloud KVS.
struct SyncedKey: Hashable, Sendable {
    let name: String
    let ownedByApp: Bool

    static let routingRules = SyncedKey(name: "routing_rules", ownedByApp: true)

    fileprivate static let profileShortcutKeyNamePrefix = "KeyboardShortcuts_profile_shortcut_"

    static func profileShortcut(for identity: ProfileIdentity) -> SyncedKey {
        let shortcutName = KeyboardShortcuts.Name.forProfile(identity).rawValue
        // Matches KeyboardShortcuts library's internal UserDefaults key format: "KeyboardShortcuts_<name>".
        return SyncedKey(name: "KeyboardShortcuts_\(shortcutName)", ownedByApp: false)
    }

    static func isProfileShortcutKeyName(_ name: String) -> Bool {
        name.hasPrefix(profileShortcutKeyNamePrefix)
    }
}

/// Protocol abstraction over `NSUbiquitousKeyValueStore` so tests can substitute a fake.
/// Cloud-write arrival is signalled via `NSUbiquitousKeyValueStore.didChangeExternallyNotification`
/// posted on `NotificationCenter.default`, not through a protocol method.
protocol KVSBackend: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    @discardableResult
    func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KVSBackend {}

@MainActor
final class SyncedDefaults {
    /// A value-plus-mtime tuple for one side of the reconcile comparison.
    /// `value` is an opaque property-list-compatible payload for the caller
    /// (e.g. `Data` for routing rules, `String`/`Bool` for KeyboardShortcuts-owned keys);
    /// only `mtime` (seconds since Unix epoch) influences the reconcile decision.
    struct Entry {
        let value: Any
        let mtime: Double
    }

    enum Decision: Equatable {
        case pushLocalToCloud
        case pullCloudToLocal
        case noAction
    }

    static let metadataKey = "_diriger_sync_metadata"
    static let toggleKey = "icloud_sync_enabled"

    private let local: UserDefaults
    private let cloud: KVSBackend
    private let clock: () -> Double
    private var registered: Set<SyncedKey> = []
    /// Counts pending cloud→local KVO echoes we should swallow, per key. A counter
    /// (not a Set) is required because two cloud pulls can land before the first
    /// KVO fires — a set would coalesce them and leak the second echo as a spurious push.
    private var suppressKVOFor: [String: Int] = [:]
    private let debounce: TimeInterval
    private var pendingWork: [String: DispatchWorkItem] = [:]

    init(
        local: UserDefaults = .standard,
        cloud: KVSBackend = NSUbiquitousKeyValueStore.default,
        clock: @escaping () -> Double = { Date().timeIntervalSince1970 },
        debounce: TimeInterval = 0.5
    ) {
        self.local = local
        self.cloud = cloud
        self.clock = clock
        self.debounce = debounce
    }

    // No deinit cleanup: Swift 6 strict concurrency disallows touching @MainActor-isolated
    // observer tokens from a nonisolated deinit, and this class is app-lifetime. The
    // notification closures use [weak self] so any post-deallocation firing is a no-op.

    var isEnabled: Bool {
        local.bool(forKey: Self.toggleKey)
    }

    /// Call once at app startup after migration. No-op if sync is disabled.
    /// Attaches notification observers and runs an initial reconcile pass against
    /// whatever's currently in KVS.
    func start() {
        guard isEnabled else { return }
        attachNotifications()
        _ = cloud.synchronize()
        reconcileAll()
    }

    func setEnabled(_ enabled: Bool) {
        let wasEnabled = isEnabled
        local.set(enabled, forKey: Self.toggleKey)
        switch (wasEnabled, enabled) {
        case (false, true):
            attachNotifications()
            _ = cloud.synchronize()
            reconcileAll()
        case (true, false):
            detachNotifications()
        default:
            break
        }
    }

    func reconcileAll() {
        guard isEnabled else { return }
        for key in registered {
            reconcile(key)
        }
    }

    func handleExternalChange(changedKeys: [String]) {
        guard isEnabled else { return }
        for key in registered where changedKeys.contains(key.name) {
            reconcile(key)
        }
    }

    func register(_ key: SyncedKey) {
        registered.insert(key)
    }

    nonisolated static func reconcile(local: Entry?, cloud: Entry?) -> Decision {
        switch (local, cloud) {
        case (nil, nil): return .noAction
        case (_?, nil): return .pushLocalToCloud
        case (nil, _?): return .pullCloudToLocal
        case (let l?, let c?):
            if l.mtime > c.mtime { return .pushLocalToCloud }
            if c.mtime > l.mtime { return .pullCloudToLocal }
            return .noAction
        }
    }

    /// Stamps the local mtime for `key` regardless of `isEnabled`. Intentional:
    /// we want a meaningful mtime to exist as soon as the user enables sync,
    /// otherwise two Macs starting from pre-existing data (both mtime 0) would
    /// reconcile as `.noAction` and their divergence would persist silently.
    func recordLocalWrite(_ key: SyncedKey) {
        var map = (local.dictionary(forKey: Self.metadataKey) as? [String: Double]) ?? [:]
        map[key.name] = clock()
        local.set(map, forKey: Self.metadataKey)
    }

    func reconcile(_ key: SyncedKey) {
        guard isEnabled else { return }

        let localEntry = readEntry(from: local, key: key)
        let cloudEntry = readEntry(from: cloud, key: key)

        switch Self.reconcile(local: localEntry, cloud: cloudEntry) {
        case .noAction:
            return
        case .pushLocalToCloud:
            guard let entry = localEntry else { return }
            write(entry: entry, to: cloud, key: key)
        case .pullCloudToLocal:
            guard let entry = cloudEntry else { return }
            write(entry: entry, to: local, key: key)
            NotificationCenter.default.post(
                name: Self.keyDidChangeRemotelyNotification,
                object: nil,
                userInfo: ["key": key.name]
            )
        }
    }

    func pushWrite(_ key: SyncedKey) {
        guard isEnabled else { return }

        if debounce <= 0 {
            reconcile(key)
            return
        }

        pendingWork[key.name]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.pendingWork[key.name] = nil
                self.reconcile(key)
            }
        }
        pendingWork[key.name] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    static let keyDidChangeRemotelyNotification =
        Notification.Name("tech.inkhorn.diriger.SyncedDefaults.keyDidChangeRemotely")

    // MARK: - notification observers

    private var kvsObserver: NSObjectProtocol?
    private var appActiveObserver: NSObjectProtocol?
    private var libraryObservers: [SyncedKey: DefaultsKVO] = [:]

    private func attachNotifications() {
        // Idempotent: if either observer is already installed, leave both in place.
        // Prevents observer leaks if `start()` and `setEnabled(true)` ever race.
        guard kvsObserver == nil, appActiveObserver == nil else { return }
        kvsObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud as? NSUbiquitousKeyValueStore,
            queue: .main
        ) { [weak self] note in
            let changed = (note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]) ?? []
            MainActor.assumeIsolated {
                self?.handleExternalChange(changedKeys: changed)
            }
        }
        appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileAll() }
        }
    }

    private func detachNotifications() {
        if let kvsObserver { NotificationCenter.default.removeObserver(kvsObserver) }
        if let appActiveObserver { NotificationCenter.default.removeObserver(appActiveObserver) }
        kvsObserver = nil
        appActiveObserver = nil
    }

    // MARK: - storage helpers

    private func readEntry(from defaults: UserDefaults, key: SyncedKey) -> Entry? {
        // Use object(forKey:) rather than data(forKey:): KeyboardShortcuts stores
        // shortcuts as String (JSON-encoded) and Bool false for disabled slots,
        // so data(forKey:) would return nil for library-owned keys.
        guard let value = defaults.object(forKey: key.name) else { return nil }
        let map = (defaults.dictionary(forKey: Self.metadataKey) as? [String: Double]) ?? [:]
        let mtime = map[key.name] ?? 0
        return Entry(value: value, mtime: mtime)
    }

    private func readEntry(from cloud: KVSBackend, key: SyncedKey) -> Entry? {
        guard let packed = cloud.object(forKey: key.name) as? [String: Any],
              let value = packed["v"],
              let mtime = packed["m"] as? Double
        else { return nil }
        return Entry(value: value, mtime: mtime)
    }

    private func write(entry: Entry, to defaults: UserDefaults, key: SyncedKey) {
        // Suppress the KVO echo for library-owned keys ONLY when the write is going
        // to change the stored value — otherwise UserDefaults may not fire KVO at
        // all (equal-value writes are commonly filtered), leaving the flag stale
        // and silently swallowing the user's next genuine edit.
        if !key.ownedByApp, !plistValue(defaults.object(forKey: key.name), equals: entry.value) {
            suppressKVOFor[key.name, default: 0] += 1
        }
        defaults.set(entry.value, forKey: key.name)
        var map = (defaults.dictionary(forKey: Self.metadataKey) as? [String: Double]) ?? [:]
        map[key.name] = entry.mtime
        defaults.set(map, forKey: Self.metadataKey)
    }

    private func write(entry: Entry, to cloud: KVSBackend, key: SyncedKey) {
        cloud.set(["v": entry.value, "m": entry.mtime] as [String: Any], forKey: key.name)
    }

    /// Property-list value equality via NSObject bridging. `Data`, `String`, `Bool`,
    /// `NSNumber`, arrays, and dictionaries all compare correctly via `isEqual(_:)`.
    private func plistValue(_ lhs: Any?, equals rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (nil, _?), (_?, nil): return false
        case let (l?, r?): return (l as AnyObject).isEqual(r as AnyObject)
        }
    }
}

extension SyncedDefaults {
    static let shared = SyncedDefaults()
}

extension SyncedDefaults {
    /// For library-owned keys we don't write ourselves (e.g., KeyboardShortcuts),
    /// install a KVO observer on the local UserDefaults so we can stamp mtime and push.
    func observeLibraryOwnedKey(_ key: SyncedKey) {
        precondition(!key.ownedByApp)
        let obs = DefaultsKVO(defaults: local, key: key.name) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Consume one pending cloud-origin suppression — this KVO fire is the
                // echo of our own cloud→local write, not a user edit.
                if let count = self.suppressKVOFor[key.name], count > 0 {
                    if count == 1 { self.suppressKVOFor.removeValue(forKey: key.name) }
                    else { self.suppressKVOFor[key.name] = count - 1 }
                    return
                }
                self.recordLocalWrite(key)
                self.pushWrite(key)
            }
        }
        libraryObservers[key] = obs
    }

    func stopObservingLibraryOwnedKey(_ key: SyncedKey) {
        libraryObservers[key] = nil
    }
}

// Small KVO wrapper — lifetime tied to this object, which is stored in the dictionary above.
@MainActor
private final class DefaultsKVO: NSObject {
    nonisolated let key: String
    // `nonisolated(unsafe)` so `deinit` (which Swift 6 runs outside the main actor) can
    // remove the observer. Access is in practice confined to the main actor via
    // `SyncedDefaults`, and `deinit` runs exactly once after the last release.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let onChange: @MainActor () -> Void

    init(defaults: UserDefaults, key: String, onChange: @escaping @MainActor () -> Void) {
        self.defaults = defaults
        self.key = key
        self.onChange = onChange
        super.init()
        defaults.addObserver(self, forKeyPath: key, options: [.new], context: nil)
    }

    deinit {
        defaults.removeObserver(self, forKeyPath: key)
    }

    override func observeValue(
        forKeyPath _: String?,
        of _: Any?,
        change _: [NSKeyValueChangeKey: Any]?,
        context _: UnsafeMutableRawPointer?
    ) {
        Task { @MainActor in self.onChange() }
    }
}
