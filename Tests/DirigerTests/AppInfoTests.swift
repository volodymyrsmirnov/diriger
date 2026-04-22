import XCTest
@testable import Diriger

final class AppInfoTests: XCTestCase {

    // MARK: - Temp directory management

    private var tempDirectories: [String] = []

    /// Creates a directory at the given path relative to the system temp directory
    /// and registers it for clean-up in tearDown.
    private func makeTempDir(named name: String) throws -> String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "DirigerAppInfoTests_\(UUID().uuidString)_\(name)"
        )
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true
        )
        tempDirectories.append(path)
        return path
    }

    override func tearDown() {
        super.tearDown()
        for path in tempDirectories {
            try? FileManager.default.removeItem(atPath: path)
        }
        tempDirectories.removeAll()
    }

    // MARK: - appDisplayName(atPath:)

    func test_appDisplayName_stripsAppExtension() throws {
        // A directory whose last component ends in ".app" should have the suffix stripped.
        let path = try makeTempDir(named: "TestApp.app")
        let result = FileManager.default.appDisplayName(atPath: path)
        XCTAssertFalse(result.hasSuffix(".app"),
                       "Expected '.app' suffix to be stripped, got: \(result)")
        XCTAssertFalse(result.isEmpty)
    }

    func test_appDisplayName_doesNotStripNonAppExtension() throws {
        // A directory with no ".app" suffix should return whatever FileManager.displayName gives.
        let path = try makeTempDir(named: "PlainName")
        let result = FileManager.default.appDisplayName(atPath: path)
        let rawDisplayName = FileManager.default.displayName(atPath: path)
        XCTAssertEqual(result, rawDisplayName)
    }

    func test_appDisplayName_doesNotCrashForNonExistentPath() {
        let bogusPath = "/tmp/this_path_does_not_exist_diriger_test_\(UUID().uuidString)"
        let result = FileManager.default.appDisplayName(atPath: bogusPath)
        // FileManager.displayName returns the last path component for missing paths.
        XCTAssertFalse(result.isEmpty)
    }

    func test_appDisplayName_returnsNonEmptyForRootPath() {
        // Sanity check: even a well-known path returns something.
        let result = FileManager.default.appDisplayName(atPath: "/Applications")
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - AppInfo.bundleID

    func test_bundleID_isNonEmpty() {
        XCTAssertFalse(AppInfo.bundleID.isEmpty)
    }
}
