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

final class ReconcileTests: XCTestCase {
    private let v1 = Data("v1".utf8)
    private let v2 = Data("v2".utf8)

    func test_bothAbsent() {
        XCTAssertEqual(
            SyncedDefaults.reconcile(local: nil, cloud: nil),
            .noAction
        )
    }

    func test_localPresentCloudAbsent() {
        XCTAssertEqual(
            SyncedDefaults.reconcile(
                local: .init(value: v1, mtime: 10),
                cloud: nil
            ),
            .pushLocalToCloud
        )
    }

    func test_cloudPresentLocalAbsent() {
        XCTAssertEqual(
            SyncedDefaults.reconcile(
                local: nil,
                cloud: .init(value: v1, mtime: 10)
            ),
            .pullCloudToLocal
        )
    }

    func test_localNewerThanCloud() {
        XCTAssertEqual(
            SyncedDefaults.reconcile(
                local: .init(value: v2, mtime: 20),
                cloud: .init(value: v1, mtime: 10)
            ),
            .pushLocalToCloud
        )
    }

    func test_cloudNewerThanLocal() {
        XCTAssertEqual(
            SyncedDefaults.reconcile(
                local: .init(value: v1, mtime: 10),
                cloud: .init(value: v2, mtime: 20)
            ),
            .pullCloudToLocal
        )
    }

    func test_equalMtimesNoAction() {
        XCTAssertEqual(
            SyncedDefaults.reconcile(
                local: .init(value: v1, mtime: 10),
                cloud: .init(value: v2, mtime: 10)
            ),
            .noAction
        )
    }
}
