import Foundation
import KeyboardShortcuts

/// Identifies one UserDefaults key that is mirrored to iCloud KVS.
struct SyncedKey: Hashable, Sendable {
    let name: String
    let ownedByApp: Bool

    static let routingRules = SyncedKey(name: "routing_rules", ownedByApp: true)

    static func profileShortcut(for identity: ProfileIdentity) -> SyncedKey {
        let shortcutName = KeyboardShortcuts.Name.forProfile(identity).rawValue
        // Matches KeyboardShortcuts library's internal UserDefaults key format: "KeyboardShortcuts_<name>".
        return SyncedKey(name: "KeyboardShortcuts_\(shortcutName)", ownedByApp: false)
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
    /// `value` is opaque payload for the caller; only `mtime` (seconds since Unix epoch)
    /// influences the reconcile decision.
    struct Entry: Equatable {
        let value: Data
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

    init(
        local: UserDefaults = .standard,
        cloud: KVSBackend = NSUbiquitousKeyValueStore.default,
        clock: @escaping () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.local = local
        self.cloud = cloud
        self.clock = clock
    }

    var isEnabled: Bool {
        local.bool(forKey: Self.toggleKey)
    }

    func setEnabled(_ enabled: Bool) {
        local.set(enabled, forKey: Self.toggleKey)
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

    static let keyDidChangeRemotelyNotification =
        Notification.Name("tech.inkhorn.diriger.SyncedDefaults.keyDidChangeRemotely")

    // MARK: - storage helpers

    private func readEntry(from defaults: UserDefaults, key: SyncedKey) -> Entry? {
        guard let value = defaults.data(forKey: key.name) else { return nil }
        let map = (defaults.dictionary(forKey: Self.metadataKey) as? [String: Double]) ?? [:]
        let mtime = map[key.name] ?? 0
        return Entry(value: value, mtime: mtime)
    }

    private func readEntry(from cloud: KVSBackend, key: SyncedKey) -> Entry? {
        guard let value = cloud.object(forKey: key.name) as? Data else { return nil }
        let map = (cloud.object(forKey: Self.metadataKey) as? [String: Double]) ?? [:]
        let mtime = map[key.name] ?? 0
        return Entry(value: value, mtime: mtime)
    }

    private func write(entry: Entry, to defaults: UserDefaults, key: SyncedKey) {
        defaults.set(entry.value, forKey: key.name)
        var map = (defaults.dictionary(forKey: Self.metadataKey) as? [String: Double]) ?? [:]
        map[key.name] = entry.mtime
        defaults.set(map, forKey: Self.metadataKey)
    }

    private func write(entry: Entry, to cloud: KVSBackend, key: SyncedKey) {
        cloud.set(entry.value, forKey: key.name)
        var map = (cloud.object(forKey: Self.metadataKey) as? [String: Double]) ?? [:]
        map[key.name] = entry.mtime
        cloud.set(map, forKey: Self.metadataKey)
    }
}
