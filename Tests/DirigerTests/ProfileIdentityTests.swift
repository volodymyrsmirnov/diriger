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
}
