import XCTest
@testable import Diriger

final class ProfileIdentityTests: XCTestCase {
    func test_encodesEmailCase() throws {
        let data = try JSONEncoder().encode(ProfileIdentity.email("a@b.com"))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(json, #"{"email":"a@b.com"}"#)
    }

    func test_encodesDirectoryCase() throws {
        let data = try JSONEncoder().encode(ProfileIdentity.directory("Profile 1"))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(json, #"{"directory":"Profile 1"}"#)
    }

    func test_decodesEmailCase() throws {
        let json = Data(#"{"email":"a@b.com"}"#.utf8)
        let decoded = try JSONDecoder().decode(ProfileIdentity.self, from: json)
        XCTAssertEqual(decoded, .email("a@b.com"))
    }

    func test_decodesDirectoryCase() throws {
        let json = Data(#"{"directory":"Profile 1"}"#.utf8)
        let decoded = try JSONDecoder().decode(ProfileIdentity.self, from: json)
        XCTAssertEqual(decoded, .directory("Profile 1"))
    }

    func test_decodeFailsOnEmptyObject() {
        let json = Data("{}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ProfileIdentity.self, from: json))
    }

    func test_storageKeyIsUniquePerIdentity() {
        XCTAssertNotEqual(
            ProfileIdentity.email("a@b.com").storageKey,
            ProfileIdentity.directory("a@b.com").storageKey
        )
    }

    func test_decodePrefersEmailWhenBothKeysPresent() throws {
        let json = Data(#"{"email":"a@b.com","directory":"Profile 1"}"#.utf8)
        let decoded = try JSONDecoder().decode(ProfileIdentity.self, from: json)
        XCTAssertEqual(decoded, .email("a@b.com"))
    }
}

final class ProfileIdentityResolverTests: XCTestCase {
    private func profile(_ dir: String, _ display: String, _ email: String = "") -> ChromeProfile {
        ChromeProfile(directoryName: dir, displayName: display, email: email)
    }

    func test_identityForProfilePrefersEmail() {
        let p = profile("Profile 1", "Jane", "jane@x.com")
        XCTAssertEqual(ProfileIdentity.forProfile(p), .email("jane@x.com"))
    }

    func test_identityForProfileFallsBackToDirectory() {
        let p = profile("Default", "Guest")
        XCTAssertEqual(ProfileIdentity.forProfile(p), .directory("Default"))
    }

    func test_resolveEmailToLocalDirectory() {
        let profiles = [
            profile("Profile 2", "Work", "work@x.com"),
            profile("Profile 1", "Home", "home@x.com")
        ]
        XCTAssertEqual(
            ProfileIdentity.email("work@x.com").directoryName(in: profiles),
            "Profile 2"
        )
    }

    func test_resolveEmailReturnsNilWhenNotPresent() {
        let profiles = [profile("Profile 1", "Home", "home@x.com")]
        XCTAssertNil(ProfileIdentity.email("other@x.com").directoryName(in: profiles))
    }

    func test_resolveDirectoryReturnsDirectoryWhenProfilePresent() {
        let profiles = [profile("Default", "Guest")]
        XCTAssertEqual(
            ProfileIdentity.directory("Default").directoryName(in: profiles),
            "Default"
        )
    }

    func test_resolveDirectoryReturnsNilWhenProfileAbsent() {
        let profiles = [profile("Default", "Guest")]
        XCTAssertNil(ProfileIdentity.directory("Missing").directoryName(in: profiles))
    }

    // MARK: profile(in:)

    func test_profileInReturnsMatchForEmailIdentity() {
        let target = profile("Profile 2", "Work", "work@x.com")
        let profiles = [profile("Profile 1", "Home", "home@x.com"), target]
        XCTAssertEqual(ProfileIdentity.email("work@x.com").profile(in: profiles), target)
    }

    func test_profileInReturnsNilForUnknownEmail() {
        let profiles = [profile("Profile 1", "Home", "home@x.com")]
        XCTAssertNil(ProfileIdentity.email("other@x.com").profile(in: profiles))
    }

    func test_profileInReturnsMatchForDirectoryIdentity() {
        let target = profile("Default", "Guest")
        let profiles = [target, profile("Profile 1", "Home")]
        XCTAssertEqual(ProfileIdentity.directory("Default").profile(in: profiles), target)
    }

    func test_profileInReturnsNilForUnknownDirectory() {
        let profiles = [profile("Default", "Guest")]
        XCTAssertNil(ProfileIdentity.directory("Missing").profile(in: profiles))
    }

    func test_profileInReturnsNilForEmptyProfileList() {
        XCTAssertNil(ProfileIdentity.email("x@y.com").profile(in: []))
        XCTAssertNil(ProfileIdentity.directory("Default").profile(in: []))
    }
}
