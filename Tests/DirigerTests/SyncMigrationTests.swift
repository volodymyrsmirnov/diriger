import XCTest
import KeyboardShortcuts
@testable import Diriger

@MainActor
final class SyncMigrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        try await super.setUp()
        suite = "tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    private func encodeRules(_ rules: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: rules)
    }

    func test_migrationRewritesDirectoryIdentityToEmailWhenProfileHasEmail() async {
        let legacy: [[String: Any]] = [[
            "id": "AC72AEB5-9C65-4FB3-9C92-1E0D4B4B9D11",
            "kind": "domain",
            "pattern": "github.com",
            "profileDirectory": "Profile 1"
        ]]
        defaults.set(encodeRules(legacy), forKey: RuleStore.defaultsKey)
        let profiles = [ChromeProfile(directoryName: "Profile 1", displayName: "Jane", email: "jane@x.com")]

        SyncMigration.performMigration(defaults: defaults, profiles: profiles)

        let data = defaults.data(forKey: RuleStore.defaultsKey)!
        let rules = try! JSONDecoder().decode([RoutingRule].self, from: data)
        XCTAssertEqual(rules.first?.profileIdentity, .email("jane@x.com"))
    }

    func test_migrationKeepsDirectoryWhenProfileHasNoEmail() async {
        let legacy: [[String: Any]] = [[
            "id": "AC72AEB5-9C65-4FB3-9C92-1E0D4B4B9D11",
            "kind": "domain",
            "pattern": "github.com",
            "profileDirectory": "Default"
        ]]
        defaults.set(encodeRules(legacy), forKey: RuleStore.defaultsKey)
        let profiles = [ChromeProfile(directoryName: "Default", displayName: "Guest", email: "")]

        SyncMigration.performMigration(defaults: defaults, profiles: profiles)

        let rules = try! JSONDecoder().decode([RoutingRule].self, from: defaults.data(forKey: RuleStore.defaultsKey)!)
        XCTAssertEqual(rules.first?.profileIdentity, .directory("Default"))
    }

    func test_migrationKeepsDirectoryWhenProfileNotPresent() async {
        let legacy: [[String: Any]] = [[
            "id": "AC72AEB5-9C65-4FB3-9C92-1E0D4B4B9D11",
            "kind": "domain",
            "pattern": "github.com",
            "profileDirectory": "Profile 1"
        ]]
        defaults.set(encodeRules(legacy), forKey: RuleStore.defaultsKey)
        let profiles: [ChromeProfile] = []

        SyncMigration.performMigration(defaults: defaults, profiles: profiles)

        let rules = try! JSONDecoder().decode([RoutingRule].self, from: defaults.data(forKey: RuleStore.defaultsKey)!)
        XCTAssertEqual(rules.first?.profileIdentity, .directory("Profile 1"))
    }

    func test_runIfNeededBumpsSchemaVersion() async {
        XCTAssertEqual(defaults.integer(forKey: SyncMigration.schemaVersionKey), 0)
        SyncMigration.performMigration(defaults: defaults, profiles: [])
        SyncMigration.markSchemaApplied(defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: SyncMigration.schemaVersionKey), 1)
    }

    func test_runIfNeededSkipsWhenSchemaAlreadyCurrent() async {
        defaults.set(1, forKey: SyncMigration.schemaVersionKey)
        defaults.set(encodeRules([[
            "id": "AC72AEB5-9C65-4FB3-9C92-1E0D4B4B9D11",
            "kind": "domain",
            "pattern": "github.com",
            "profileDirectory": "Profile 1"
        ]]), forKey: RuleStore.defaultsKey)
        let profiles = [ChromeProfile(directoryName: "Profile 1", displayName: "Jane", email: "jane@x.com")]

        await SyncMigration.runIfNeeded(
            defaults: defaults,
            loadProfiles: { profiles }
        )

        let rules = try! JSONDecoder().decode([RoutingRule].self, from: defaults.data(forKey: RuleStore.defaultsKey)!)
        XCTAssertEqual(rules.first?.profileIdentity, .directory("Profile 1"))
    }

    func test_migrationRewritesShortcutKeyFromDirectoryToEmail() {
        let legacyKey = "KeyboardShortcuts_profile_Profile 1"
        let payload = Data([0x01, 0x02, 0x03])
        defaults.set(payload, forKey: legacyKey)
        let profiles = [ChromeProfile(directoryName: "Profile 1", displayName: "Jane", email: "jane@x.com")]

        SyncMigration.performMigration(defaults: defaults, profiles: profiles)

        XCTAssertNil(defaults.object(forKey: legacyKey))
        XCTAssertEqual(
            defaults.data(forKey: "KeyboardShortcuts_profile_shortcut_email:jane@x.com"),
            payload
        )
    }

    func test_migrationLeavesAlreadyIdentityKeyedShortcutsAlone() {
        let alreadyMigratedKey = "KeyboardShortcuts_profile_shortcut_email:already@x.com"
        let payload = Data([0xAA, 0xBB])
        defaults.set(payload, forKey: alreadyMigratedKey)

        SyncMigration.performMigration(defaults: defaults, profiles: [])

        XCTAssertEqual(defaults.data(forKey: alreadyMigratedKey), payload)
    }
}
