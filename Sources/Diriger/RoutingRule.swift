import Foundation

enum RuleKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case source
    case domain
    case regex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .source: return "Source"
        case .domain: return "Domain"
        case .regex: return "RegEx"
        }
    }
}

struct RoutingRule: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var kind: RuleKind
    var pattern: String
    var sourceName: String?
    var profileDirectory: String

    init(
        id: UUID = UUID(),
        kind: RuleKind = .domain,
        pattern: String = "",
        sourceName: String? = nil,
        profileDirectory: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.pattern = pattern
        self.sourceName = sourceName
        self.profileDirectory = profileDirectory
    }
}
