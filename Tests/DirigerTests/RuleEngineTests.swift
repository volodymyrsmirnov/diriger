import XCTest
@testable import Diriger

// MARK: - Helpers

private func makeProfile(
    directory: String,
    display: String = "Test",
    email: String = ""
) -> ChromeProfile {
    ChromeProfile(directoryName: directory, displayName: display, email: email)
}

private func makeRule(
    kind: RuleKind,
    pattern: String,
    profileIdentity: ProfileIdentity
) -> RoutingRule {
    RoutingRule(kind: kind, pattern: pattern, profileIdentity: profileIdentity)
}

private func url(_ string: String) -> URL {
    URL(string: string)!
}

// MARK: - RuleEngineTests

final class RuleEngineTests: XCTestCase {
    // MARK: Private helpers

    private let anyIdentity = ProfileIdentity.directory("P")

    private func domainRule(_ pattern: String) -> RoutingRule {
        makeRule(kind: .domain, pattern: pattern, profileIdentity: anyIdentity)
    }

    private func regexRule(_ pattern: String) -> RoutingRule {
        makeRule(kind: .regex, pattern: pattern, profileIdentity: anyIdentity)
    }

    private func sourceRule(_ pattern: String) -> RoutingRule {
        makeRule(kind: .source, pattern: pattern, profileIdentity: anyIdentity)
    }

    // MARK: firstMatch — ordering and resolution

    func test_firstMatch_returnsFirstMatchingRulesProfile_whenMultipleRulesMatch() {
        let profiles = [
            makeProfile(directory: "Profile 1"),
            makeProfile(directory: "Profile 2")
        ]
        let rules = [
            makeRule(kind: .domain, pattern: "example.com", profileIdentity: .directory("Profile 1")),
            makeRule(kind: .domain, pattern: "example.com", profileIdentity: .directory("Profile 2"))
        ]
        let result = RuleEngine.firstMatch(
            in: rules,
            url: url("https://example.com/page"),
            sourceBundleID: nil,
            availableProfiles: profiles
        )
        XCTAssertEqual(result?.directoryName, "Profile 1")
    }

    func test_firstMatch_skipsRuleWhoseProfileIdentityDoesNotResolve() {
        let profiles = [makeProfile(directory: "Profile 2")]
        let rules = [
            makeRule(kind: .domain, pattern: "example.com", profileIdentity: .directory("Missing")),
            makeRule(kind: .domain, pattern: "example.com", profileIdentity: .directory("Profile 2"))
        ]
        let result = RuleEngine.firstMatch(
            in: rules,
            url: url("https://example.com"),
            sourceBundleID: nil,
            availableProfiles: profiles
        )
        XCTAssertEqual(result?.directoryName, "Profile 2")
    }

    func test_firstMatch_returnsNil_whenNoRuleMatches() {
        let profiles = [makeProfile(directory: "Profile 1")]
        let rules = [
            makeRule(kind: .domain, pattern: "other.com", profileIdentity: .directory("Profile 1"))
        ]
        let result = RuleEngine.firstMatch(
            in: rules,
            url: url("https://example.com"),
            sourceBundleID: nil,
            availableProfiles: profiles
        )
        XCTAssertNil(result)
    }

    func test_firstMatch_returnsNil_whenProfilesListIsEmpty() {
        let rules = [
            makeRule(kind: .domain, pattern: "example.com", profileIdentity: .directory("Profile 1"))
        ]
        let result = RuleEngine.firstMatch(
            in: rules,
            url: url("https://example.com"),
            sourceBundleID: nil,
            availableProfiles: []
        )
        XCTAssertNil(result)
    }

    func test_firstMatch_resolvesEmailIdentityToProfileWithDifferentDirectoryName() {
        // The rule carries .email("jane@x.com"); the profile lives at directory "Profile 17".
        // firstMatch must resolve through the email field, not any literal stored on the rule.
        let profiles = [makeProfile(directory: "Profile 17", display: "Jane", email: "jane@x.com")]
        let rules = [
            makeRule(kind: .domain, pattern: "example.com", profileIdentity: .email("jane@x.com"))
        ]
        let result = RuleEngine.firstMatch(
            in: rules,
            url: url("https://example.com"),
            sourceBundleID: nil,
            availableProfiles: profiles
        )
        XCTAssertEqual(result?.directoryName, "Profile 17")
    }

    // MARK: matches — .source

    func test_source_matchesWhenBundleIDEqualsPattern() {
        XCTAssertTrue(
            RuleEngine.matches(
                rule: sourceRule("com.apple.safari"),
                url: url("https://x.com"),
                sourceBundleID: "com.apple.safari"
            )
        )
    }

    func test_source_noMatchWhenBundleIDsDiffer() {
        XCTAssertFalse(
            RuleEngine.matches(
                rule: sourceRule("com.apple.safari"),
                url: url("https://x.com"),
                sourceBundleID: "com.google.chrome"
            )
        )
    }

    func test_source_noMatchWhenSourceBundleIDIsNil() {
        XCTAssertFalse(
            RuleEngine.matches(
                rule: sourceRule("com.apple.safari"),
                url: url("https://x.com"),
                sourceBundleID: nil
            )
        )
    }

    func test_source_noMatchWhenPatternIsEmpty() {
        XCTAssertFalse(
            RuleEngine.matches(
                rule: sourceRule(""),
                url: url("https://x.com"),
                sourceBundleID: "com.apple.safari"
            )
        )
    }

    // MARK: matches — .domain exact and www. equivalence

    func test_domain_exactHostMatch() {
        XCTAssertTrue(
            RuleEngine.matches(rule: domainRule("example.com"), url: url("https://example.com/path"), sourceBundleID: nil)
        )
    }

    func test_domain_noMatchWhenHostDiffers() {
        XCTAssertFalse(
            RuleEngine.matches(rule: domainRule("example.com"), url: url("https://other.com"), sourceBundleID: nil)
        )
    }

    func test_domain_patternWithoutWww_matchesBareHost() {
        XCTAssertTrue(
            RuleEngine.matches(rule: domainRule("example.com"), url: url("https://example.com"), sourceBundleID: nil)
        )
    }

    func test_domain_patternWithoutWww_matchesWwwHost() {
        // pattern "example.com" is elastic: host "www.example.com" should match.
        XCTAssertTrue(
            RuleEngine.matches(rule: domainRule("example.com"), url: url("https://www.example.com"), sourceBundleID: nil)
        )
    }

    func test_domain_patternWithWww_matchesWwwHostExactly() {
        // pattern "www.example.com" matches host "www.example.com" via exact match.
        XCTAssertTrue(
            RuleEngine.matches(
                rule: domainRule("www.example.com"),
                url: url("https://www.example.com"),
                sourceBundleID: nil
            )
        )
    }

    func test_domain_patternWithWww_doesNotMatchBareHost() {
        // pattern "www.example.com" does NOT match bare host "example.com".
        // The second guard fires only when the pattern does NOT start with "www.".
        XCTAssertFalse(
            RuleEngine.matches(rule: domainRule("www.example.com"), url: url("https://example.com"), sourceBundleID: nil)
        )
    }

    // MARK: matches — .domain case-insensitivity and whitespace

    func test_domain_caseInsensitivePatternAndHost() {
        XCTAssertTrue(
            RuleEngine.matches(
                rule: domainRule("ExAmPlE.CoM"),
                url: url("https://EXAMPLE.COM/path"),
                sourceBundleID: nil
            )
        )
    }

    func test_domain_leadingAndTrailingWhitespaceInPatternIsTrimmed() {
        XCTAssertTrue(
            RuleEngine.matches(rule: domainRule("  example.com  "), url: url("https://example.com"), sourceBundleID: nil)
        )
    }

    // MARK: matches — .domain empty pattern / no host

    func test_domain_emptyPatternReturnsFalse() {
        XCTAssertFalse(
            RuleEngine.matches(rule: domainRule(""), url: url("https://example.com"), sourceBundleID: nil)
        )
    }

    func test_domain_urlWithNoHostReturnsFalse() {
        // "data:text/plain,hello" has no host component.
        XCTAssertFalse(
            RuleEngine.matches(rule: domainRule("example.com"), url: url("data:text/plain,hello"), sourceBundleID: nil)
        )
    }

    // MARK: matches — .domain wildcard

    func test_domain_wildcardMatchesSubdomain() {
        XCTAssertTrue(
            RuleEngine.matches(rule: domainRule("*.example.com"), url: url("https://sub.example.com"), sourceBundleID: nil)
        )
    }

    func test_domain_wildcardMatchesBareApexDomain() {
        // host == suffix branch: host "example.com" equals the suffix "example.com".
        XCTAssertTrue(
            RuleEngine.matches(rule: domainRule("*.example.com"), url: url("https://example.com"), sourceBundleID: nil)
        )
    }

    func test_domain_wildcardDoesNotMatchAdjacentDomain() {
        XCTAssertFalse(
            RuleEngine.matches(rule: domainRule("*.example.com"), url: url("https://evilexample.com"), sourceBundleID: nil)
        )
    }

    func test_domain_wildcardWithEmptySuffixReturnsFalse() {
        // Pattern "*." has an empty suffix.
        XCTAssertFalse(
            RuleEngine.matches(rule: domainRule("*."), url: url("https://example.com"), sourceBundleID: nil)
        )
    }

    func test_domain_wildcardWithStarInSuffixReturnsFalse() {
        // Pattern "*.*.com" — suffix itself contains '*'.
        XCTAssertFalse(
            RuleEngine.matches(rule: domainRule("*.*.com"), url: url("https://anything.com"), sourceBundleID: nil)
        )
    }

    func test_domain_strayStarNotAtPrefixReturnsFalse() {
        // Pattern "ex*.com" — '*' is not a wildcard prefix, hits the non-wildcard stray-star guard.
        XCTAssertFalse(
            RuleEngine.matches(rule: domainRule("ex*.com"), url: url("https://example.com"), sourceBundleID: nil)
        )
    }

    // MARK: matches — .regex

    func test_regex_matchesWhenPatternMatchesAbsoluteString() {
        XCTAssertTrue(
            RuleEngine.matches(
                rule: regexRule("^https://example\\.com/"),
                url: url("https://example.com/page"),
                sourceBundleID: nil
            )
        )
    }

    func test_regex_caseInsensitiveMatch() {
        // The regex engine is initialised with .caseInsensitive.
        XCTAssertTrue(
            RuleEngine.matches(
                rule: regexRule("EXAMPLE\\.COM"),
                url: url("https://example.com/"),
                sourceBundleID: nil
            )
        )
    }

    func test_regex_invalidPatternReturnsFalse() {
        XCTAssertFalse(
            RuleEngine.matches(rule: regexRule("[invalid("), url: url("https://example.com"), sourceBundleID: nil)
        )
    }

    func test_regex_emptyPatternReturnsFalse() {
        XCTAssertFalse(
            RuleEngine.matches(rule: regexRule(""), url: url("https://example.com"), sourceBundleID: nil)
        )
    }

    func test_regex_nonMatchingPatternReturnsFalse() {
        XCTAssertFalse(
            RuleEngine.matches(
                rule: regexRule("^https://other\\.com/"),
                url: url("https://example.com/page"),
                sourceBundleID: nil
            )
        )
    }

    // MARK: isValidRegex

    func test_isValidRegex_trueForValidPattern() {
        XCTAssertTrue(RuleEngine.isValidRegex("^https://.*\\.example\\.com/"))
    }

    func test_isValidRegex_falseForInvalidPattern() {
        XCTAssertFalse(RuleEngine.isValidRegex("[invalid("))
    }

    func test_isValidRegex_falseForEmptyPattern() {
        XCTAssertFalse(RuleEngine.isValidRegex(""))
    }

    // MARK: isValidDomain — parameterised

    func test_isValidDomain_validInputs() {
        let cases = [
            "example.com",
            "a.b.c",
            "*.example.com",
            "EXAMPLE.COM"       // lowercased internally — still valid
        ]
        for input in cases {
            XCTAssertTrue(RuleEngine.isValidDomain(input), "Expected true for: \(input)")
        }
    }

    func test_isValidDomain_invalidInputs() {
        let cases: [String] = [
            "",                  // empty
            "   ",               // whitespace-only
            "exam ple.com",      // space in non-wildcard pattern
            "ex*.com",           // stray * not at prefix
            "*.*.com",           // * inside wildcard suffix
            "*.",                // bare *. — empty suffix
            "*.foo bar.com"      // space inside wildcard suffix
        ]
        for input in cases {
            XCTAssertFalse(RuleEngine.isValidDomain(input), "Expected false for: \(input)")
        }
    }
}
