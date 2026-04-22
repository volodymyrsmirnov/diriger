import XCTest
@testable import Diriger

// MARK: - Helpers

private func makeRule(
    id: UUID = UUID(),
    pattern: String = "example.com",
    kind: RuleKind = .domain
) -> RoutingRule {
    RoutingRule(id: id, kind: kind, pattern: pattern, profileIdentity: .directory("Default"))
}

private func encodeRules(_ rules: [RoutingRule]) -> Data {
    try! JSONEncoder().encode(rules)
}

// MARK: - RuleStoreTests

@MainActor
final class RuleStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var kvs: FakeKVS!
    private var sync: SyncedDefaults!
    private var suite: String!

    override func setUp() async throws {
        try await super.setUp()
        suite = "tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        kvs = FakeKVS()
        sync = SyncedDefaults(local: defaults, cloud: kvs, clock: { 100 }, debounce: 0)
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: suite)
        defaults = nil
        sync = nil
        kvs = nil
        try await super.tearDown()
    }

    private func makeStore() -> RuleStore {
        RuleStore(defaults: defaults, sync: sync)
    }

    private func persistedRules() -> [RoutingRule] {
        guard let data = defaults.data(forKey: RuleStore.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([RoutingRule].self, from: data)) ?? []
    }

    // MARK: Init / load

    func test_init_emptyDefaults_rulesIsEmpty() {
        XCTAssertTrue(makeStore().rules.isEmpty)
    }

    func test_init_withPersistedValidJSON_rulesPopulated() {
        let rule = makeRule(pattern: "github.com")
        defaults.set(encodeRules([rule]), forKey: RuleStore.defaultsKey)

        let store = makeStore()

        XCTAssertEqual(store.rules.count, 1)
        XCTAssertEqual(store.rules.first?.id, rule.id)
        XCTAssertEqual(store.rules.first?.pattern, "github.com")
    }

    func test_init_withMultiplePersistedRules_allLoaded() {
        let rules = [
            makeRule(pattern: "alpha.com"),
            makeRule(pattern: "beta.com"),
            makeRule(pattern: "gamma.com"),
        ]
        defaults.set(encodeRules(rules), forKey: RuleStore.defaultsKey)

        let store = makeStore()

        XCTAssertEqual(store.rules.map(\.pattern), ["alpha.com", "beta.com", "gamma.com"])
    }

    func test_init_withCorruptData_rulesEmpty() {
        defaults.set(Data("{not valid json".utf8), forKey: RuleStore.defaultsKey)
        XCTAssertTrue(makeStore().rules.isEmpty)
    }

    func test_init_registersRoutingRulesKeyWithSync() {
        // Enable sync, pre-populate cloud with newer data, then the store's init must
        // have registered the key so reconcileAll can find it.
        defaults.set(Data("older".utf8), forKey: RuleStore.defaultsKey)
        kvs.store["routing_rules"] = ["v": Data("newer".utf8), "m": 900.0] as [String: Any]

        _ = makeStore()  // registers .routingRules
        sync.setEnabled(true)  // triggers reconcileAll

        XCTAssertEqual(defaults.data(forKey: "routing_rules"), Data("newer".utf8))
    }

    // MARK: add(_:)

    func test_add_appendsAndPersists() {
        let store = makeStore()
        let rule = makeRule(pattern: "add.com")

        store.add(rule)

        XCTAssertEqual(store.rules, [rule])
        XCTAssertEqual(persistedRules(), [rule])
    }

    func test_add_multipleRules_appendsInOrder() {
        let store = makeStore()
        let r1 = makeRule(pattern: "first.com")
        let r2 = makeRule(pattern: "second.com")
        let r3 = makeRule(pattern: "third.com")

        store.add(r1); store.add(r2); store.add(r3)

        XCTAssertEqual(store.rules.map(\.pattern), ["first.com", "second.com", "third.com"])
        XCTAssertEqual(persistedRules().map(\.pattern), ["first.com", "second.com", "third.com"])
    }

    // MARK: insert(_:at:)

    func test_insert_atValidIndex_insertsAtPosition() {
        let store = makeStore()
        store.add(makeRule(pattern: "r1.com"))
        store.add(makeRule(pattern: "r2.com"))

        store.insert(makeRule(pattern: "mid.com"), at: 1)

        XCTAssertEqual(store.rules.map(\.pattern), ["r1.com", "mid.com", "r2.com"])
        XCTAssertEqual(persistedRules().map(\.pattern), ["r1.com", "mid.com", "r2.com"])
    }

    func test_insert_negativeIndex_clampsToZero() {
        let store = makeStore()
        store.add(makeRule(pattern: "existing.com"))

        store.insert(makeRule(pattern: "head.com"), at: -5)

        XCTAssertEqual(store.rules.first?.pattern, "head.com")
    }

    func test_insert_indexBeyondCount_clampsToEnd() {
        let store = makeStore()
        store.add(makeRule(pattern: "r1.com"))

        store.insert(makeRule(pattern: "tail.com"), at: 999)

        XCTAssertEqual(store.rules.last?.pattern, "tail.com")
    }

    func test_insert_atZeroIntoEmpty_prepends() {
        let store = makeStore()
        store.insert(makeRule(pattern: "solo.com"), at: 0)
        XCTAssertEqual(store.rules.map(\.pattern), ["solo.com"])
    }

    // MARK: update(_:)

    func test_update_knownId_replacesAndPersists() {
        let store = makeStore()
        let id = UUID()
        store.add(makeRule(id: id, pattern: "old.com"))

        let updated = RoutingRule(id: id, kind: .regex, pattern: "new.com", profileIdentity: .directory("Default"))
        store.update(updated)

        XCTAssertEqual(store.rules, [updated])
        XCTAssertEqual(persistedRules(), [updated])
    }

    func test_update_unknownId_isNoOp() {
        let store = makeStore()
        let keeper = makeRule(pattern: "keep.com")
        store.add(keeper)
        let dataBefore = defaults.data(forKey: RuleStore.defaultsKey)

        store.update(RoutingRule(id: UUID(), kind: .domain, pattern: "stranger.com", profileIdentity: .directory("Default")))

        XCTAssertEqual(store.rules, [keeper])
        XCTAssertEqual(defaults.data(forKey: RuleStore.defaultsKey), dataBefore)
    }

    // MARK: remove(id:)

    func test_remove_knownId_removesAndPersists() {
        let store = makeStore()
        let id = UUID()
        store.add(makeRule(id: id, pattern: "gone.com"))
        store.add(makeRule(pattern: "stay.com"))

        store.remove(id: id)

        XCTAssertEqual(store.rules.map(\.pattern), ["stay.com"])
        XCTAssertEqual(persistedRules().map(\.pattern), ["stay.com"])
    }

    func test_remove_unknownId_isNoOp() {
        let store = makeStore()
        store.add(makeRule(pattern: "keep.com"))
        let dataBefore = defaults.data(forKey: RuleStore.defaultsKey)

        store.remove(id: UUID())

        XCTAssertEqual(store.rules.count, 1)
        XCTAssertEqual(defaults.data(forKey: RuleStore.defaultsKey), dataBefore)
    }

    // MARK: move(fromOffsets:toOffset:)

    func test_move_reordersAndPersists() {
        let store = makeStore()
        store.add(makeRule(pattern: "zero.com"))
        store.add(makeRule(pattern: "one.com"))
        store.add(makeRule(pattern: "two.com"))

        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)

        XCTAssertEqual(store.rules.map(\.pattern), ["one.com", "zero.com", "two.com"])
        XCTAssertEqual(persistedRules().map(\.pattern), ["one.com", "zero.com", "two.com"])
    }

    func test_move_matchesStandardLibrarySemantics() {
        let store = makeStore()
        let patterns = ["p0.com", "p1.com", "p2.com", "p3.com"]
        for p in patterns { store.add(makeRule(pattern: p)) }

        let offsets = IndexSet([1, 2])
        store.move(fromOffsets: offsets, toOffset: 0)

        var reference = patterns
        reference.move(fromOffsets: offsets, toOffset: 0)
        XCTAssertEqual(store.rules.map(\.pattern), reference)
        XCTAssertEqual(persistedRules().map(\.pattern), reference)
    }

    // MARK: Sync integration via injected SyncedDefaults

    func test_persist_recordsLocalWriteOnInjectedSync() {
        let store = makeStore()
        sync.setEnabled(true)  // so pushWrite actually mirrors

        store.add(makeRule(pattern: "mirror.com"))

        // The metadata dictionary must carry an mtime for routing_rules.
        let meta = defaults.dictionary(forKey: "_diriger_sync_metadata") as? [String: Double]
        XCTAssertEqual(meta?["routing_rules"], 100, "persist must call recordLocalWrite on the injected sync")
        // And the cloud must have received the write (debounce is 0 in this sync).
        let packed = kvs.store["routing_rules"] as? [String: Any]
        XCTAssertNotNil(packed?["v"] as? Data)
    }

    // MARK: Remote-change observer — notification fires reload

    private func pumpMainQueue() {
        let exp = expectation(description: "main queue turn")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }

    func test_remoteChangeNotification_matchingKey_reloadsRules() {
        let store = makeStore()
        XCTAssertTrue(store.rules.isEmpty)

        defaults.set(encodeRules([makeRule(pattern: "remote.com")]), forKey: RuleStore.defaultsKey)

        NotificationCenter.default.post(
            name: SyncedDefaults.keyDidChangeRemotelyNotification,
            object: nil,
            userInfo: ["key": RuleStore.defaultsKey]
        )
        pumpMainQueue()

        XCTAssertEqual(store.rules.map(\.pattern), ["remote.com"])
    }

    func test_remoteChangeNotification_differentKey_doesNotReload() {
        let store = makeStore()
        store.add(makeRule(pattern: "original.com"))

        defaults.set(encodeRules([makeRule(pattern: "sneaky.com")]), forKey: RuleStore.defaultsKey)

        NotificationCenter.default.post(
            name: SyncedDefaults.keyDidChangeRemotelyNotification,
            object: nil,
            userInfo: ["key": "some_other_key"]
        )
        pumpMainQueue()

        XCTAssertEqual(store.rules.first?.pattern, "original.com")
    }

    func test_remoteChangeNotification_missingUserInfo_doesNotReload() {
        let store = makeStore()
        store.add(makeRule(pattern: "stable.com"))

        defaults.set(encodeRules([makeRule(pattern: "overwrite.com")]), forKey: RuleStore.defaultsKey)

        NotificationCenter.default.post(
            name: SyncedDefaults.keyDidChangeRemotelyNotification,
            object: nil,
            userInfo: nil
        )
        pumpMainQueue()

        XCTAssertEqual(store.rules.first?.pattern, "stable.com")
    }

    func test_remoteChangeNotification_emptyUserInfo_doesNotReload() {
        let store = makeStore()
        store.add(makeRule(pattern: "intact.com"))

        defaults.set(encodeRules([makeRule(pattern: "replacement.com")]), forKey: RuleStore.defaultsKey)

        NotificationCenter.default.post(
            name: SyncedDefaults.keyDidChangeRemotelyNotification,
            object: nil,
            userInfo: [:]
        )
        pumpMainQueue()

        XCTAssertEqual(store.rules.first?.pattern, "intact.com")
    }

    // MARK: Persistence round-trip fidelity

    func test_persistedData_roundTripsAllRuleKinds() {
        let store = makeStore()
        let domainRule = RoutingRule(id: UUID(), kind: .domain, pattern: "domain.com", profileIdentity: .email("a@b.com"))
        let sourceRule = RoutingRule(id: UUID(), kind: .source, pattern: "source.app", profileIdentity: .directory("Profile 1"))
        let regexRule  = RoutingRule(id: UUID(), kind: .regex,  pattern: "^https://.*", profileIdentity: .email("c@d.org"))

        store.add(domainRule); store.add(sourceRule); store.add(regexRule)

        XCTAssertEqual(persistedRules(), [domainRule, sourceRule, regexRule])
    }
}
