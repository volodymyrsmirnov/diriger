import Foundation

enum RuleKind: String, Codable, CaseIterable, Identifiable {
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

struct RoutingRule: Identifiable, Codable, Hashable {
    var id: UUID
    var kind: RuleKind
    var pattern: String
    var sourceName: String?
    var profileIdentity: ProfileIdentity

    init(
        id: UUID = UUID(),
        kind: RuleKind = .domain,
        pattern: String = "",
        sourceName: String? = nil,
        profileIdentity: ProfileIdentity = .directory("")
    ) {
        self.id = id
        self.kind = kind
        self.pattern = pattern
        self.sourceName = sourceName
        self.profileIdentity = profileIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, pattern, sourceName
        case profileIdentity
        case profileDirectory  // legacy
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.kind = try c.decode(RuleKind.self, forKey: .kind)
        self.pattern = try c.decode(String.self, forKey: .pattern)
        self.sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName)
        if let identity = try c.decodeIfPresent(ProfileIdentity.self, forKey: .profileIdentity) {
            self.profileIdentity = identity
        } else {
            let legacy = (try c.decodeIfPresent(String.self, forKey: .profileDirectory)) ?? ""
            self.profileIdentity = .directory(legacy)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(pattern, forKey: .pattern)
        try c.encodeIfPresent(sourceName, forKey: .sourceName)
        try c.encode(profileIdentity, forKey: .profileIdentity)
    }
}
