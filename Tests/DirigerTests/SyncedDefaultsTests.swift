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

        let packed = kvs.store["routing_rules"] as? [String: Any]
        XCTAssertEqual(packed?["v"] as? Data, Data("local".utf8))
        XCTAssertEqual(packed?["m"] as? Double, 500)
    }

    func test_reconcile_cloudOnly_pullsWhenEnabled() {
        kvs.store["routing_rules"] = ["v": Data("cloud".utf8), "m": 800.0] as [String: Any]
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

        kvs.store["routing_rules"] = ["v": Data("cloud".utf8), "m": 900.0] as [String: Any]

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

        let packedRules = kvs.store["routing_rules"] as? [String: Any]
        XCTAssertEqual(packedRules?["v"] as? Data, Data("r".utf8))
        let packedShortcut = kvs.store["KeyboardShortcuts_profile_shortcut_email:a@b.com"] as? [String: Any]
        XCTAssertEqual(packedShortcut?["v"] as? Data, Data("s".utf8))
    }

    func test_enable_triggersReconcileAll() {
        defaults.set(Data("r".utf8), forKey: "routing_rules")
        clock = 500
        sut.recordLocalWrite(.routingRules)
        sut.register(.routingRules)

        sut.setEnabled(true)  // should reconcile

        let packed = kvs.store["routing_rules"] as? [String: Any]
        XCTAssertEqual(packed?["v"] as? Data, Data("r".utf8))
    }

    func test_handleExternalChange_reconcilesOnlyChangedKeys() {
        defaults.set(Data("old".utf8), forKey: "routing_rules")
        clock = 100
        sut.recordLocalWrite(.routingRules)
        sut.register(.routingRules)
        sut.setEnabled(true)

        kvs.store["routing_rules"] = ["v": Data("new".utf8), "m": 900.0] as [String: Any]

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

    func test_setEnabled_doesNotReFireWhenAlreadyEnabled() {
        sut.register(.routingRules)
        sut.setEnabled(true)
        let countAfterFirst = kvs.syncCallCount

        sut.setEnabled(true)

        XCTAssertEqual(kvs.syncCallCount, countAfterFirst)
    }

    func test_reconcileAll_isInertWhenDisabled() {
        defaults.set(Data("r".utf8), forKey: "routing_rules")
        clock = 500
        sut.recordLocalWrite(.routingRules)
        sut.register(.routingRules)

        sut.reconcileAll()  // isEnabled == false

        XCTAssertNil(kvs.store["routing_rules"])
    }

    func test_handleExternalChange_isInertWhenDisabled() {
        kvs.store["routing_rules"] = ["v": Data("new".utf8), "m": 900.0] as [String: Any]
        sut.register(.routingRules)

        sut.handleExternalChange(changedKeys: ["routing_rules"])  // isEnabled == false

        XCTAssertNil(defaults.data(forKey: "routing_rules"))
    }

    func test_start_reconcilesWhenEnabledAtLaunch() {
        // Simulate a relaunch: isEnabled is already true in UserDefaults, and there's
        // existing local data plus an existing cloud snapshot.
        defaults.set(Data("r".utf8), forKey: "routing_rules")
        clock = 500
        sut.recordLocalWrite(.routingRules)
        defaults.set(true, forKey: "icloud_sync_enabled")  // enabled from prior session
        sut.register(.routingRules)

        kvs.store["routing_rules"] = ["v": Data("cloudy".utf8), "m": 900.0] as [String: Any]

        sut.start()

        XCTAssertEqual(defaults.data(forKey: "routing_rules"), Data("cloudy".utf8))
    }

    func test_start_isNoOpWhenDisabled() {
        defaults.set(Data("r".utf8), forKey: "routing_rules")
        clock = 500
        sut.recordLocalWrite(.routingRules)
        sut.register(.routingRules)

        sut.start()  // isEnabled == false

        XCTAssertNil(kvs.store["routing_rules"])
    }
}

@MainActor
final class SyncedDefaultsDebounceTests: XCTestCase {
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
            clock: { [unowned self] in self.clock },
            debounce: 0  // synchronous in tests
        )
        sut.register(.routingRules)
        sut.setEnabled(true)
    }

    override func tearDown() async throws {
        sut?.setEnabled(false)
        sut = nil
        try await super.tearDown()
    }

    func test_pushWrite_withZeroDebounceMirrorsImmediately() {
        defaults.set(Data("v".utf8), forKey: "routing_rules")
        clock = 200
        sut.recordLocalWrite(.routingRules)
        sut.pushWrite(.routingRules)

        let packed = kvs.store["routing_rules"] as? [String: Any]
        XCTAssertEqual(packed?["v"] as? Data, Data("v".utf8))
    }

    func test_pushWrite_coalescesBurst() {
        // Switch to a non-zero debounce to exercise coalescing.
        sut = SyncedDefaults(
            local: defaults,
            cloud: kvs,
            clock: { [unowned self] in self.clock },
            debounce: 0.05
        )
        sut.register(.routingRules)
        sut.setEnabled(true)

        defaults.set(Data("a".utf8), forKey: "routing_rules")
        clock = 201; sut.recordLocalWrite(.routingRules); sut.pushWrite(.routingRules)
        defaults.set(Data("b".utf8), forKey: "routing_rules")
        clock = 202; sut.recordLocalWrite(.routingRules); sut.pushWrite(.routingRules)
        defaults.set(Data("c".utf8), forKey: "routing_rules")
        clock = 203; sut.recordLocalWrite(.routingRules); sut.pushWrite(.routingRules)

        let exp = expectation(description: "debounce fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        let packed = kvs.store["routing_rules"] as? [String: Any]
        XCTAssertEqual(packed?["v"] as? Data, Data("c".utf8))
        XCTAssertEqual(packed?["m"] as? Double, 203)
    }

    func test_libraryOwnedStringValue_pushesToCloudAsString() {
        // KeyboardShortcuts persists shortcuts to UserDefaults as a JSON-encoded String
        // (not Data). Regression guard: readEntry must observe the String via
        // object(forKey:), not data(forKey:), so the push reaches the cloud.
        let shortcutKey = SyncedKey.profileShortcut(for: .email("a@b.com"))
        defaults.set("{\"carbonKeyCode\":1,\"carbonModifiers\":0}", forKey: shortcutKey.name)
        clock = 400
        sut.recordLocalWrite(shortcutKey)
        sut.register(shortcutKey)

        sut.reconcile(shortcutKey)

        let packed = kvs.store[shortcutKey.name] as? [String: Any]
        XCTAssertEqual(packed?["v"] as? String, "{\"carbonKeyCode\":1,\"carbonModifiers\":0}")
        XCTAssertEqual(packed?["m"] as? Double, 400)
    }

    func test_libraryOwnedBoolValue_pushesToCloudAsBool() {
        // KeyboardShortcuts persists a disabled shortcut as Bool false.
        let shortcutKey = SyncedKey.profileShortcut(for: .email("a@b.com"))
        defaults.set(false, forKey: shortcutKey.name)
        clock = 500
        sut.recordLocalWrite(shortcutKey)
        sut.register(shortcutKey)

        sut.reconcile(shortcutKey)

        let packed = kvs.store[shortcutKey.name] as? [String: Any]
        XCTAssertEqual(packed?["v"] as? Bool, false)
    }

    func test_libraryOwnedStringValue_pullsFromCloudIntoDefaults() {
        // Inverse of the push test: cloud carries a String shortcut; local must receive it.
        let shortcutKey = SyncedKey.profileShortcut(for: .email("a@b.com"))
        kvs.store[shortcutKey.name] = [
            "v": "{\"carbonKeyCode\":2,\"carbonModifiers\":512}",
            "m": 900.0,
        ] as [String: Any]
        sut.register(shortcutKey)

        sut.reconcile(shortcutKey)

        XCTAssertEqual(
            defaults.string(forKey: shortcutKey.name),
            "{\"carbonKeyCode\":2,\"carbonModifiers\":512}"
        )
    }

    func test_cloudPullForLibraryOwnedKey_doesNotEchoBackToCloud() {
        let shortcutKey = SyncedKey.profileShortcut(for: .email("a@b.com"))
        sut.register(shortcutKey)

        // Simulate a cloud write of a shortcut landing on this Mac.
        kvs.store[shortcutKey.name] = ["v": Data("cloud".utf8), "m": 900.0] as [String: Any]
        sut.observeLibraryOwnedKey(shortcutKey)

        // Receive the change notification and wait for the debounce window to clear.
        sut.handleExternalChange(changedKeys: [shortcutKey.name])
        let exp = expectation(description: "debounce window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        // Cloud mtime must still be 900 (no echo push has overwritten it).
        let packed = kvs.store[shortcutKey.name] as? [String: Any]
        XCTAssertEqual(packed?["m"] as? Double, 900.0)
    }
}
