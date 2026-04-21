import Foundation

struct RuleEngine {
    static func firstMatch(
        in rules: [RoutingRule],
        url: URL,
        sourceBundleID: String?,
        availableProfiles: [ChromeProfile]
    ) -> ChromeProfile? {
        for rule in rules {
            guard let profile = availableProfiles.first(
                where: { $0.directoryName == rule.profileDirectory }
            ) else { continue }

            guard matches(rule: rule, url: url, sourceBundleID: sourceBundleID) else { continue }

            return profile
        }
        return nil
    }

    static func matches(
        rule: RoutingRule,
        url: URL,
        sourceBundleID: String?
    ) -> Bool {
        switch rule.kind {
        case .source:
            guard !rule.pattern.isEmpty, let sourceBundleID else { return false }
            return sourceBundleID == rule.pattern
        case .domain:
            return domainMatches(pattern: rule.pattern, url: url)
        case .regex:
            return regexMatches(pattern: rule.pattern, url: url)
        }
    }

    private static func domainMatches(pattern raw: String, url: URL) -> Bool {
        let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !pattern.isEmpty, let host = url.host?.lowercased() else { return false }

        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2))
            guard !suffix.isEmpty, !suffix.contains("*") else { return false }
            return host == suffix || host.hasSuffix("." + suffix)
        }

        guard !pattern.contains("*") else { return false }
        return host == pattern
    }

    private static func regexMatches(pattern: String, url: URL) -> Bool {
        guard !pattern.isEmpty,
              let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return false }
        let target = url.absoluteString
        let range = NSRange(target.startIndex..., in: target)
        return regex.firstMatch(in: target, options: [], range: range) != nil
    }

    static func isValidRegex(_ pattern: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        return (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) != nil
    }

    static func isValidDomain(_ raw: String) -> Bool {
        let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !pattern.isEmpty else { return false }
        if pattern.hasPrefix("*.") {
            let suffix = pattern.dropFirst(2)
            return !suffix.isEmpty && !suffix.contains("*") && !suffix.contains(" ")
        }
        return !pattern.contains("*") && !pattern.contains(" ")
    }
}
