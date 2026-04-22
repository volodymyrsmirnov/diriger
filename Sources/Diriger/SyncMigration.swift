import Foundation
import KeyboardShortcuts

enum SyncMigration {
    static let schemaVersionKey = "sync_schema_version"
    static let currentSchemaVersion = 1

    @MainActor
    static func runIfNeeded(
        defaults: UserDefaults = .standard,
        loadProfiles: @Sendable () async -> [ChromeProfile] = { await ChromeProfileService.loadProfiles() }
    ) async {
        guard defaults.integer(forKey: schemaVersionKey) < currentSchemaVersion else { return }
        let profiles = await loadProfiles()
        performMigration(defaults: defaults, profiles: profiles)
        markSchemaApplied(defaults: defaults)
    }

    /// Performs the one-shot transformation. Idempotent. Exposed for tests.
    @MainActor
    static func performMigration(defaults: UserDefaults, profiles: [ChromeProfile]) {
        migrateRules(defaults: defaults, profiles: profiles)
        migrateShortcuts(defaults: defaults, profiles: profiles)
    }

    @MainActor
    static func markSchemaApplied(defaults: UserDefaults) {
        defaults.set(currentSchemaVersion, forKey: schemaVersionKey)
    }

    // MARK: - Rules

    @MainActor
    private static func migrateRules(defaults: UserDefaults, profiles: [ChromeProfile]) {
        guard let data = defaults.data(forKey: RuleStore.defaultsKey) else { return }
        guard var rules = try? JSONDecoder().decode([RoutingRule].self, from: data) else { return }

        var didChange = false
        for (index, rule) in rules.enumerated() {
            if case .directory(let name) = rule.profileIdentity,
               let match = profiles.first(where: { $0.directoryName == name }),
               !match.email.isEmpty {
                var copy = rule
                copy.profileIdentity = .email(match.email)
                rules[index] = copy
                didChange = true
            }
        }

        guard didChange else { return }
        if let encoded = try? JSONEncoder().encode(rules) {
            defaults.set(encoded, forKey: RuleStore.defaultsKey)
        }
    }

    // MARK: - Shortcuts

    @MainActor
    private static func migrateShortcuts(defaults: UserDefaults, profiles: [ChromeProfile]) {
        let legacyPrefix = "KeyboardShortcuts_profile_"
        let allKeys = defaults.dictionaryRepresentation().keys
        for defaultsKey in allKeys where defaultsKey.hasPrefix(legacyPrefix)
            && !defaultsKey.hasPrefix("KeyboardShortcuts_profile_shortcut_") {
            let legacyName = String(defaultsKey.dropFirst("KeyboardShortcuts_".count))
            let directoryName = String(legacyName.dropFirst("profile_".count))
            let oldName = KeyboardShortcuts.Name(legacyName)
            let shortcut = KeyboardShortcuts.getShortcut(for: oldName)

            let identity: ProfileIdentity
            if let match = profiles.first(where: { $0.directoryName == directoryName }), !match.email.isEmpty {
                identity = .email(match.email)
            } else {
                identity = .directory(directoryName)
            }
            let newName = KeyboardShortcuts.Name.forProfile(identity)

            KeyboardShortcuts.setShortcut(shortcut, for: newName)
            KeyboardShortcuts.reset([oldName])
        }
    }
}
