import XCTest
import KeyboardShortcuts
@testable import Diriger

final class ShortcutNamesTests: XCTestCase {

    // MARK: - forProfile raw values

    func test_forProfile_emailIdentity_producesExpectedRawValue() {
        let name = KeyboardShortcuts.Name.forProfile(.email("jane@x.com"))
        XCTAssertEqual(name.rawValue, "profile_shortcut_email:jane@x.com")
    }

    func test_forProfile_directoryIdentity_producesExpectedRawValue() {
        let name = KeyboardShortcuts.Name.forProfile(.directory("Profile 1"))
        XCTAssertEqual(name.rawValue, "profile_shortcut_dir:Profile 1")
    }

    // MARK: - maxSlots

    func test_maxSlots_equalsTen() {
        XCTAssertEqual(KeyboardShortcuts.Name.maxSlots, 10)
    }

    // MARK: - Uniqueness and stability

    func test_differentIdentities_produceDifferentRawValues() {
        let emailName = KeyboardShortcuts.Name.forProfile(.email("jane@x.com"))
        let dirName = KeyboardShortcuts.Name.forProfile(.directory("jane@x.com"))
        // Even though the payload string is identical, the storage keys differ.
        XCTAssertNotEqual(emailName.rawValue, dirName.rawValue)
    }

    func test_differentEmailAddresses_produceDifferentRawValues() {
        let name1 = KeyboardShortcuts.Name.forProfile(.email("alice@x.com"))
        let name2 = KeyboardShortcuts.Name.forProfile(.email("bob@x.com"))
        XCTAssertNotEqual(name1.rawValue, name2.rawValue)
    }

    func test_sameIdentity_producesStableRawValue() {
        let identity = ProfileIdentity.email("jane@x.com")
        let first = KeyboardShortcuts.Name.forProfile(identity).rawValue
        let second = KeyboardShortcuts.Name.forProfile(identity).rawValue
        XCTAssertEqual(first, second)
    }

    func test_sameDirectoryIdentity_producesStableRawValue() {
        let identity = ProfileIdentity.directory("Profile 1")
        let first = KeyboardShortcuts.Name.forProfile(identity).rawValue
        let second = KeyboardShortcuts.Name.forProfile(identity).rawValue
        XCTAssertEqual(first, second)
    }

    // MARK: - Prefix structure

    func test_rawValue_alwaysContainsProfileShortcutPrefix() {
        let names: [KeyboardShortcuts.Name] = [
            .forProfile(.email("a@b.com")),
            .forProfile(.directory("Default")),
            .forProfile(.email("")),
            .forProfile(.directory(""))
        ]
        for name in names {
            XCTAssertTrue(
                name.rawValue.hasPrefix("profile_shortcut_"),
                "Expected prefix 'profile_shortcut_' in: \(name.rawValue)"
            )
        }
    }
}
