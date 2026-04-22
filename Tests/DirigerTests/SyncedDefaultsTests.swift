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

// FakeKVS — minimal in-memory implementation of KVSBackend.
@MainActor
final class FakeKVS: @MainActor KVSBackend {
    var store: [String: Any] = [:]
    var syncCallCount = 0

    func object(forKey key: String) -> Any? { store[key] }
    func set(_ value: Any?, forKey key: String) {
        if let value { store[key] = value } else { store.removeValue(forKey: key) }
    }
    func removeObject(forKey key: String) { store.removeValue(forKey: key) }
    @discardableResult
    func synchronize() -> Bool { syncCallCount += 1; return true }
}

@MainActor
final class SyncedDefaultsInstanceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var kvs: FakeKVS!
    private var clock: Double = 100
    private var sut: SyncedDefaults!

    override func setUp() async throws {
        try await super.setUp()
        let suite = "tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        kvs = FakeKVS()
        sut = SyncedDefaults(
            local: defaults,
            cloud: kvs,
            clock: { [unowned self] in self.clock }
        )
    }

    func test_disabledByDefault() {
        XCTAssertFalse(sut.isEnabled)
    }

    func test_toggleIsPersisted() {
        sut.setEnabled(true)
        XCTAssertTrue(sut.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: "icloud_sync_enabled"))
        sut.setEnabled(false)
        XCTAssertFalse(sut.isEnabled)
    }

    func test_reconcile_localOnly_pushesWhenEnabled() {
        defaults.set(Data("local".utf8), forKey: "routing_rules")
        clock = 500
        sut.recordLocalWrite(.routingRules)  // stamps mtime
        sut.register(.routingRules)

        sut.setEnabled(true)
        sut.reconcile(.routingRules)

        XCTAssertEqual(kvs.store["routing_rules"] as? Data, Data("local".utf8))
        let cloudMeta = kvs.store["_diriger_sync_metadata"] as? [String: Double]
        XCTAssertEqual(cloudMeta?["routing_rules"], 500)
    }

    func test_reconcile_cloudOnly_pullsWhenEnabled() {
        kvs.store["routing_rules"] = Data("cloud".utf8)
        kvs.store["_diriger_sync_metadata"] = ["routing_rules": 800.0]
        sut.register(.routingRules)

        sut.setEnabled(true)
        sut.reconcile(.routingRules)

        XCTAssertEqual(defaults.data(forKey: "routing_rules"), Data("cloud".utf8))
        let localMeta = defaults.dictionary(forKey: "_diriger_sync_metadata") as? [String: Double]
        XCTAssertEqual(localMeta?["routing_rules"], 800)
    }

    func test_reconcile_cloudNewer_overwritesLocal() {
        defaults.set(Data("local".utf8), forKey: "routing_rules")
        clock = 100
        sut.recordLocalWrite(.routingRules)
        sut.register(.routingRules)

        kvs.store["routing_rules"] = Data("cloud".utf8)
        kvs.store["_diriger_sync_metadata"] = ["routing_rules": 900.0]

        sut.setEnabled(true)
        sut.reconcile(.routingRules)

        XCTAssertEqual(defaults.data(forKey: "routing_rules"), Data("cloud".utf8))
    }

    func test_disabled_isInert() {
        defaults.set(Data("local".utf8), forKey: "routing_rules")
        clock = 500
        sut.recordLocalWrite(.routingRules)
        sut.register(.routingRules)

        sut.reconcile(.routingRules)  // enabled == false

        XCTAssertNil(kvs.store["routing_rules"])
    }
}

@MainActor
final class SyncedDefaultsLifecycleTests: XCTestCase {
    private var defaults: UserDefaults!
    private var kvs: FakeKVS!
    private var clock: Double = 100
    private var sut: SyncedDefaults!

    override func setUp() async throws {
        try await super.setUp()
        let suite = "tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        kvs = FakeKVS()
        sut = SyncedDefaults(
            local: defaults,
            cloud: kvs,
            clock: { [unowned self] in self.clock }
        )
    }

    func test_reconcileAll_visitsEveryRegisteredKey() {
        defaults.set(Data("r".utf8), forKey: "routing_rules")
        clock = 500
        sut.recordLocalWrite(.routingRules)
        defaults.set(Data("s".utf8), forKey: "KeyboardShortcuts_profile_shortcut_email:a@b.com")
        sut.recordLocalWrite(.profileShortcut(for: .email("a@b.com")))

        sut.register(.routingRules)
        sut.register(.profileShortcut(for: .email("a@b.com")))
        sut.setEnabled(true)

        sut.reconcileAll()

        XCTAssertEqual(kvs.store["routing_rules"] as? Data, Data("r".utf8))
        XCTAssertEqual(
            kvs.store["KeyboardShortcuts_profile_shortcut_email:a@b.com"] as? Data,
            Data("s".utf8)
        )
    }

    func test_enable_triggersReconcileAll() {
        defaults.set(Data("r".utf8), forKey: "routing_rules")
        clock = 500
        sut.recordLocalWrite(.routingRules)
        sut.register(.routingRules)

        sut.setEnabled(true)  // should reconcile

        XCTAssertEqual(kvs.store["routing_rules"] as? Data, Data("r".utf8))
    }

    func test_handleExternalChange_reconcilesOnlyChangedKeys() {
        defaults.set(Data("old".utf8), forKey: "routing_rules")
        clock = 100
        sut.recordLocalWrite(.routingRules)
        sut.register(.routingRules)
        sut.setEnabled(true)

        kvs.store["routing_rules"] = Data("new".utf8)
        kvs.store["_diriger_sync_metadata"] = ["routing_rules": 900.0]

        sut.handleExternalChange(changedKeys: ["routing_rules"])

        XCTAssertEqual(defaults.data(forKey: "routing_rules"), Data("new".utf8))
    }

    func test_handleExternalChange_ignoresUnregisteredKeys() {
        sut.register(.routingRules)
        sut.setEnabled(true)
        kvs.store["unrelated"] = Data("x".utf8)

        sut.handleExternalChange(changedKeys: ["unrelated"])
        XCTAssertNil(defaults.data(forKey: "unrelated"))
    }
}
