import XCTest
@testable import Diriger

// LaunchError is nested inside @MainActor enum ChromeLauncher, so this entire
// test class must be isolated to the main actor to satisfy Swift 6 concurrency.
@MainActor
final class ErrorDescriptionTests: XCTestCase {

    // MARK: - Helpers

    private typealias LaunchError = ChromeLauncher.LaunchError

    /// An NSError whose localizedDescription is a known string, used to verify
    /// that chromeLaunchFailed embeds the underlying error's description.
    private func knownError(description: String) -> NSError {
        NSError(
            domain: "DirigerTestDomain",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    // MARK: - chromeNotInstalled

    func test_chromeNotInstalled_hasNonNilNonEmptyErrorDescription() {
        let error = LaunchError.chromeNotInstalled
        let desc = error.errorDescription
        XCTAssertNotNil(desc)
        XCTAssertFalse(desc!.isEmpty)
    }

    func test_chromeNotInstalled_hasNonNilNonEmptyRecoverySuggestion() {
        let error = LaunchError.chromeNotInstalled
        let suggestion = error.recoverySuggestion
        XCTAssertNotNil(suggestion)
        XCTAssertFalse(suggestion!.isEmpty)
    }

    // MARK: - accessibilityDenied

    func test_accessibilityDenied_hasNonNilNonEmptyErrorDescription() {
        let error = LaunchError.accessibilityDenied
        let desc = error.errorDescription
        XCTAssertNotNil(desc)
        XCTAssertFalse(desc!.isEmpty)
    }

    func test_accessibilityDenied_hasNonNilNonEmptyRecoverySuggestion() {
        let error = LaunchError.accessibilityDenied
        let suggestion = error.recoverySuggestion
        XCTAssertNotNil(suggestion)
        XCTAssertFalse(suggestion!.isEmpty)
    }

    // MARK: - profileItemNotFound

    func test_profileItemNotFound_hasNonNilNonEmptyErrorDescription() {
        let error = LaunchError.profileItemNotFound(displayName: "Work")
        let desc = error.errorDescription
        XCTAssertNotNil(desc)
        XCTAssertFalse(desc!.isEmpty)
    }

    func test_profileItemNotFound_descriptionEmbedsDisplayNameInQuotes() {
        let error = LaunchError.profileItemNotFound(displayName: "Work")
        // Source produces: Couldn't find "Work" in Chrome's Profiles menu.
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(
            desc.contains("\"Work\""),
            "Expected description to contain '\"Work\"' in quotes, got: \(desc)"
        )
    }

    func test_profileItemNotFound_hasNonNilNonEmptyRecoverySuggestion() {
        let error = LaunchError.profileItemNotFound(displayName: "Work")
        let suggestion = error.recoverySuggestion
        XCTAssertNotNil(suggestion)
        XCTAssertFalse(suggestion!.isEmpty)
    }

    // MARK: - chromeLaunchFailed

    func test_chromeLaunchFailed_hasNonNilNonEmptyErrorDescription() {
        let error = LaunchError.chromeLaunchFailed(underlying: knownError(description: "boom"))
        let desc = error.errorDescription
        XCTAssertNotNil(desc)
        XCTAssertFalse(desc!.isEmpty)
    }

    func test_chromeLaunchFailed_recoverySuggestionEqualsUnderlyingLocalizedDescription() {
        let underlying = knownError(description: "boom")
        let error = LaunchError.chromeLaunchFailed(underlying: underlying)
        // recoverySuggestion returns error.localizedDescription of the underlying error.
        XCTAssertEqual(error.recoverySuggestion, "boom")
    }

    func test_chromeLaunchFailed_hasNonEmptyRecoverySuggestion() {
        let error = LaunchError.chromeLaunchFailed(underlying: knownError(description: "network timeout"))
        let suggestion = error.recoverySuggestion
        XCTAssertNotNil(suggestion)
        XCTAssertFalse(suggestion!.isEmpty)
    }

    // MARK: - NoFallbackBrowserError

    func test_noFallbackBrowserError_hasNonNilNonEmptyErrorDescription() {
        let error = DefaultBrowserService.NoFallbackBrowserError()
        let desc = error.errorDescription
        XCTAssertNotNil(desc)
        XCTAssertFalse(desc!.isEmpty)
    }

    func test_noFallbackBrowserError_recoverySuggestionIsNil() {
        // NoFallbackBrowserError defines only errorDescription; the default
        // LocalizedError implementation returns nil for recoverySuggestion.
        let error = DefaultBrowserService.NoFallbackBrowserError()
        XCTAssertNil(error.recoverySuggestion)
    }
}
