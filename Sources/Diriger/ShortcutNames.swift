import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    private static let profilePrefix = "profile_"
    static let maxSlots = 10

    static func forProfile(_ directoryName: String) -> KeyboardShortcuts.Name {
        KeyboardShortcuts.Name("\(profilePrefix)\(directoryName)")
    }
}
