import XCTest
@testable import Diriger

final class ChromeProfileServiceTests: XCTestCase {
    // MARK: - parseProfiles(from:)

    private func jsonData(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    func test_parseProfiles_parsesWellFormedLocalState() {
        let data = jsonData([
            "profile": [
                "info_cache": [
                    "Profile 1": ["name": "Work", "user_name": "work@x.com"],
                    "Default":   ["name": "Home", "user_name": "home@x.com"],
                ]
            ]
        ])

        let profiles = ChromeProfileService.parseProfiles(from: data)

        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles.map(\.displayName), ["Home", "Work"])  // localized sort
        XCTAssertEqual(profiles.first { $0.directoryName == "Profile 1" }?.email, "work@x.com")
    }

    func test_parseProfiles_missingUserName_yieldsEmptyEmail() {
        let data = jsonData([
            "profile": ["info_cache": ["Default": ["name": "Guest"]]]
        ])

        let profiles = ChromeProfileService.parseProfiles(from: data)

        XCTAssertEqual(profiles.first?.email, "")
        XCTAssertEqual(profiles.first?.displayName, "Guest")
    }

    func test_parseProfiles_skipsEntriesWithoutName() {
        let data = jsonData([
            "profile": [
                "info_cache": [
                    "Profile 1": ["user_name": "a@b.com"],       // missing name
                    "Profile 2": ["name": "Valid"],
                ]
            ]
        ])

        let profiles = ChromeProfileService.parseProfiles(from: data)

        XCTAssertEqual(profiles.map(\.directoryName), ["Profile 2"])
    }

    func test_parseProfiles_sortsByDisplayNameLocalized() {
        let data = jsonData([
            "profile": [
                "info_cache": [
                    "A": ["name": "Zeta"],
                    "B": ["name": "alpha"],
                    "C": ["name": "Beta"],
                ]
            ]
        ])

        let profiles = ChromeProfileService.parseProfiles(from: data)

        // localizedStandardCompare is case-insensitive by default, so: alpha, Beta, Zeta
        XCTAssertEqual(profiles.map(\.displayName), ["alpha", "Beta", "Zeta"])
    }

    func test_parseProfiles_invalidJSON_returnsEmpty() {
        XCTAssertTrue(ChromeProfileService.parseProfiles(from: Data("not json".utf8)).isEmpty)
    }

    func test_parseProfiles_missingProfileKey_returnsEmpty() {
        let data = jsonData(["other": ["info_cache": [:]]])
        XCTAssertTrue(ChromeProfileService.parseProfiles(from: data).isEmpty)
    }

    func test_parseProfiles_missingInfoCache_returnsEmpty() {
        let data = jsonData(["profile": ["something_else": [:]]])
        XCTAssertTrue(ChromeProfileService.parseProfiles(from: data).isEmpty)
    }

    func test_parseProfiles_rootIsArray_returnsEmpty() {
        let data = try! JSONSerialization.data(withJSONObject: ["not", "an", "object"])
        XCTAssertTrue(ChromeProfileService.parseProfiles(from: data).isEmpty)
    }

    func test_parseProfiles_emptyInfoCache_returnsEmpty() {
        let data = jsonData(["profile": ["info_cache": [String: Any]()]])
        XCTAssertTrue(ChromeProfileService.parseProfiles(from: data).isEmpty)
    }

    // MARK: - loadProfiles(localStateURL:)

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func test_loadProfiles_fromValidFile() async {
        let url = tempDir.appendingPathComponent("Local State")
        let data = jsonData([
            "profile": ["info_cache": ["Profile 1": ["name": "X", "user_name": "x@y.com"]]]
        ])
        try! data.write(to: url)

        let profiles = await ChromeProfileService.loadProfiles(localStateURL: url)

        XCTAssertEqual(profiles.map(\.email), ["x@y.com"])
    }

    func test_loadProfiles_missingFile_returnsEmpty() async {
        let url = tempDir.appendingPathComponent("does-not-exist")
        let profiles = await ChromeProfileService.loadProfiles(localStateURL: url)
        XCTAssertTrue(profiles.isEmpty)
    }
}
