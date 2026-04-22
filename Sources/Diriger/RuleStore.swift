import Foundation

@MainActor
@Observable
final class RuleStore {
    static let defaultsKey = "routing_rules"

    private(set) var rules: [RoutingRule]
    private var remoteObserver: NSObjectProtocol?

    init() {
        self.rules = Self.load()
        SyncedDefaults.shared.register(.routingRules)
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
        rules = Self.load()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(rules)
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            SyncedDefaults.shared.recordLocalWrite(.routingRules)
            SyncedDefaults.shared.pushWrite(.routingRules)
        } catch {
            Log.rules.error("Failed to persist rules: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load() -> [RoutingRule] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
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
