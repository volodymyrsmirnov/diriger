import Foundation

enum ProfileIdentity: Hashable, Codable, Sendable {
    case email(String)
    case directory(String)

    private enum CodingKeys: String, CodingKey {
        case email
        case directory
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // email takes precedence when both keys are present
        if let value = try container.decodeIfPresent(String.self, forKey: .email) {
            self = .email(value)
            return
        }
        if let value = try container.decodeIfPresent(String.self, forKey: .directory) {
            self = .directory(value)
            return
        }
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "ProfileIdentity must have 'email' or 'directory'.")
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .email(let value):
            try container.encode(value, forKey: .email)
        case .directory(let value):
            try container.encode(value, forKey: .directory)
        }
    }

    /// String form safe to use as a suffix in UserDefaults/KVS keys.
    var storageKey: String {
        switch self {
        case .email(let value): return "email:\(value)"
        case .directory(let value): return "dir:\(value)"
        }
    }
}

extension ProfileIdentity {
    static func forProfile(_ profile: ChromeProfile) -> ProfileIdentity {
        if !profile.email.isEmpty {
            return .email(profile.email)
        }
        return .directory(profile.directoryName)
    }

    /// Returns the matching profile's current `directoryName`, or `nil` if the
    /// profile isn't present on this Mac. For `.directory`, this is a liveness
    /// check — it returns the same string searched for when the profile exists,
    /// or `nil` when it doesn't.
    func directoryName(in profiles: [ChromeProfile]) -> String? {
        profile(in: profiles)?.directoryName
    }

    /// Resolve this identity to the matching `ChromeProfile`, or `nil` if
    /// no profile currently matches.
    func profile(in profiles: [ChromeProfile]) -> ChromeProfile? {
        switch self {
        case .email(let value):
            return profiles.first(where: { $0.email == value })
        case .directory(let value):
            return profiles.first(where: { $0.directoryName == value })
        }
    }
}
