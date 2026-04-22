import XCTest
@testable import Diriger

final class RoutingRuleMigrationTests: XCTestCase {
    func test_decodesLegacyProfileDirectoryAsDirectoryIdentity() throws {
        let json = Data("""
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301",
         "kind":"domain","pattern":"github.com",
         "profileDirectory":"Profile 1"}
        """.utf8)
        let rule = try JSONDecoder().decode(RoutingRule.self, from: json)
        XCTAssertEqual(rule.profileIdentity, .directory("Profile 1"))
    }

    func test_decodesNewProfileIdentityField() throws {
        let json = Data("""
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301",
         "kind":"domain","pattern":"github.com",
         "profileIdentity":{"email":"jane@x.com"}}
        """.utf8)
        let rule = try JSONDecoder().decode(RoutingRule.self, from: json)
        XCTAssertEqual(rule.profileIdentity, .email("jane@x.com"))
    }

    func test_roundTripsProfileIdentity() throws {
        let rule = RoutingRule(
            id: UUID(),
            kind: .regex,
            pattern: "^https://mail\\.google\\.com/",
            profileIdentity: .email("jane@x.com")
        )
        let data = try JSONEncoder().encode(rule)
        let restored = try JSONDecoder().decode(RoutingRule.self, from: data)
        XCTAssertEqual(restored, rule)
    }

    func test_missingIdentityDecodesAsEmptyDirectory() throws {
        let json = Data("""
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301",
         "kind":"domain","pattern":"github.com"}
        """.utf8)
        let rule = try JSONDecoder().decode(RoutingRule.self, from: json)
        XCTAssertEqual(rule.profileIdentity, .directory(""))
    }

    func test_decodePrefersProfileIdentityOverLegacyProfileDirectory() throws {
        let json = Data("""
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301",
         "kind":"domain","pattern":"github.com",
         "profileIdentity":{"email":"jane@x.com"},
         "profileDirectory":"Profile 999"}
        """.utf8)
        let rule = try JSONDecoder().decode(RoutingRule.self, from: json)
        XCTAssertEqual(rule.profileIdentity, .email("jane@x.com"))
    }
}
