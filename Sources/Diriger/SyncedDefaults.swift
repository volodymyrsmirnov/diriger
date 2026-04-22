import Foundation
import KeyboardShortcuts

/// Identifies one UserDefaults key that is mirrored to iCloud KVS.
struct SyncedKey: Hashable, Sendable {
    let name: String
    let ownedByApp: Bool

    static let routingRules = SyncedKey(name: "routing_rules", ownedByApp: true)

    static func profileShortcut(for identity: ProfileIdentity) -> SyncedKey {
        let shortcutName = KeyboardShortcuts.Name.forProfile(identity).rawValue
        return SyncedKey(name: "KeyboardShortcuts_\(shortcutName)", ownedByApp: false)
    }
}

/// Protocol abstraction over `NSUbiquitousKeyValueStore` so tests can substitute a fake.
protocol KVSBackend: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    @discardableResult
    func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KVSBackend {}
