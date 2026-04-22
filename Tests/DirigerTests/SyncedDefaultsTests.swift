import XCTest
@testable import Diriger

final class SyncedKeyTests: XCTestCase {
    func test_routingRulesKeyIsAppOwned() {
        let key = SyncedKey.routingRules
        XCTAssertEqual(key.name, "routing_rules")
        XCTAssertTrue(key.ownedByApp)
    }

    func test_profileShortcutKeyIsLibraryOwned() {
        let key = SyncedKey.profileShortcut(for: .email("jane@x.com"))
        XCTAssertEqual(key.name, "KeyboardShortcuts_profile_shortcut_email:jane@x.com")
        XCTAssertFalse(key.ownedByApp)
    }
}
