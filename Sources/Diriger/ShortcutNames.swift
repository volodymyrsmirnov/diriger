import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    private static let profilePrefix = "profile_shortcut_"
    static let maxSlots = 10

    static func forProfile(_ identity: ProfileIdentity) -> KeyboardShortcuts.Name {
        KeyboardShortcuts.Name("\(profilePrefix)\(identity.storageKey)")
    }
}
