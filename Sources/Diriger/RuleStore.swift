import Foundation

@MainActor
@Observable
final class RuleStore {
    private static let defaultsKey = "routing_rules"

    private(set) var rules: [RoutingRule]

    init() {
        self.rules = Self.load()
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

    private func persist() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private static func load() -> [RoutingRule] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([RoutingRule].self, from: data)
        else { return [] }
        return decoded
    }
}
