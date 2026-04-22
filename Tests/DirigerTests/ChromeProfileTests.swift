import XCTest
import SwiftUI
@testable import Diriger

final class ChromeProfileTests: XCTestCase {

    // MARK: - Helpers

    private func makeProfile(
        directoryName: String = "Default",
        displayName: String = "Jane",
        email: String = ""
    ) -> ChromeProfile {
        ChromeProfile(directoryName: directoryName, displayName: displayName, email: email)
    }

    // MARK: - id

    func test_id_equalsDirectoryName() {
        let profile = makeProfile(directoryName: "Profile 1")
        XCTAssertEqual(profile.id, "Profile 1")
    }

    // MARK: - initial

    func test_initial_returnsUppercasedFirstChar() {
        let profile = makeProfile(displayName: "Jane")
        XCTAssertEqual(profile.initial, "J")
    }

    func test_initial_uppercasesLowercaseFirstChar() {
        let profile = makeProfile(displayName: "alice")
        XCTAssertEqual(profile.initial, "A")
    }

    func test_initial_singleCharacterDisplayName() {
        let profile = makeProfile(displayName: "z")
        XCTAssertEqual(profile.initial, "Z")
    }

    func test_initial_emptyDisplayNameReturnsEmptyString() {
        let profile = makeProfile(displayName: "")
        // Must not crash and should produce an empty string.
        XCTAssertEqual(profile.initial, "")
    }

    // MARK: - fallbackColor

    func test_fallbackColor_isDeterministic() {
        let profile = makeProfile(directoryName: "Default")
        let first = profile.fallbackColor
        let second = profile.fallbackColor
        XCTAssertEqual(first, second)
    }

    func test_fallbackColor_variesBetweenDifferentDirectoryNames() {
        // "Profile 1" hashes to index 2 (orange); "Profile 2" hashes to index 3 (purple).
        let p1 = makeProfile(directoryName: "Profile 1").fallbackColor
        let p2 = makeProfile(directoryName: "Profile 2").fallbackColor
        // These two directory names produce different palette indices.
        XCTAssertNotEqual(p1, p2)
    }

    func test_fallbackColor_returnsColorWithoutCrashForSeveralInputs() {
        let names = ["Default", "Profile 1", "Profile 2", "Work", "Personal", ""]
        for name in names {
            _ = makeProfile(directoryName: name).fallbackColor
        }
        // Reaching here means no crash for any input.
    }

    // "Default" → UTF-8 sum 709 → 709 % 10 = 9 → .cyan
    func test_fallbackColor_selectsExpectedPaletteIndexForKnownInput() {
        let profile = makeProfile(directoryName: "Default")
        XCTAssertEqual(profile.fallbackColor, Color.cyan)
    }

    // "Profile 1" → UTF-8 sum 802 → 802 % 10 = 2 → .orange
    func test_fallbackColor_selectsOrangeForProfile1() {
        let profile = makeProfile(directoryName: "Profile 1")
        XCTAssertEqual(profile.fallbackColor, Color.orange)
    }

    // MARK: - Equatable / Hashable

    func test_equalProfiles_areEqual() {
        let a = makeProfile(directoryName: "Default", displayName: "Jane", email: "j@x.com")
        let b = makeProfile(directoryName: "Default", displayName: "Jane", email: "j@x.com")
        XCTAssertEqual(a, b)
    }

    func test_profilesWithDifferentDirectoryName_areNotEqual() {
        let a = makeProfile(directoryName: "Default")
        let b = makeProfile(directoryName: "Profile 1")
        XCTAssertNotEqual(a, b)
    }

    func test_equalProfiles_haveEqualHashValues() {
        let a = makeProfile(directoryName: "Default", displayName: "Jane", email: "j@x.com")
        let b = makeProfile(directoryName: "Default", displayName: "Jane", email: "j@x.com")
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func test_profileUsableAsSetElement() {
        let a = makeProfile(directoryName: "Default", displayName: "Jane")
        let b = makeProfile(directoryName: "Default", displayName: "Jane")
        let set: Set<ChromeProfile> = [a, b]
        XCTAssertEqual(set.count, 1)
    }

    func test_profileUsableAsDictionaryKey() {
        let profile = makeProfile(directoryName: "Default")
        var dict: [ChromeProfile: String] = [:]
        dict[profile] = "value"
        XCTAssertEqual(dict[profile], "value")
    }
}
