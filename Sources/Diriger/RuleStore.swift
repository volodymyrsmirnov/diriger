import Foundation

@MainActor
@Observable
final class RuleStore {
    static let defaultsKey = "routing_rules"

    private(set) var rules: [RoutingRule]
    private let defaults: UserDefaults
    private let sync: SyncedDefaults
    private var remoteObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, sync: SyncedDefaults = .shared) {
        self.defaults = defaults
        self.sync = sync
        self.rules = Self.load(from: defaults)
        sync.register(.routingRules)
        remoteObserver = NotificationCenter.default.addObserver(
            forName: SyncedDefaults.keyDidChangeRemotelyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let key = note.userInfo?["key"] as? String
            MainActor.assumeIsolated {
                guard key == Self.defaultsKey else { return }
                self?.reloadFromDefaults()
            }
        }
    }

    // No deinit cleanup: Swift 6 strict concurrency disallows touching @MainActor-isolated
    // observer tokens from a nonisolated deinit, and this class is app-lifetime. The
    // notification closure uses [weak self] so post-deallocation firings are no-ops.

    func add(_ rule: RoutingRule) {
        rules.append(rule)
        persist()
    }

    func insert(_ rule: RoutingRule, at index: Int) {
        let clamped = max(0, min(index, rules.count))
        rules.insert(rule, at: clamped)
        persist()
    }

    func update(_ rule: RoutingRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        persist()
    }

    func remove(id: RoutingRule.ID) {
        rules.removeAll { $0.id == id }
        persist()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func reloadFromDefaults() {
        rules = Self.load(from: defaults)
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(rules)
            defaults.set(data, forKey: Self.defaultsKey)
            sync.recordLocalWrite(.routingRules)
            sync.pushWrite(.routingRules)
        } catch {
            Log.rules.error("Failed to persist rules: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load(from defaults: UserDefaults) -> [RoutingRule] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        do {
            return try JSONDecoder().decode([RoutingRule].self, from: data)
        } catch {
            Log.rules.error(
                "Failed to decode persisted rules; starting empty: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }
}
