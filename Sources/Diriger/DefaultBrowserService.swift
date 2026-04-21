import AppKit
import Foundation

enum DefaultBrowserService {
    // macOS keeps http and https in sync for the web-browser role; setting
    // both in succession triggers NSFileReadUnknownError on the second call,
    // so we only set http and let the system propagate to https.
    private static let writeScheme = "http"
    private static let probeURL = URL(string: "https://example.com")!

    private static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "tech.inkhorn.diriger"
    }

    static func isDefaultBrowser() -> Bool {
        currentHandlerBundleID() == bundleID
    }

    static func currentHandlerURL() -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: probeURL)
    }

    static func currentHandlerBundleID() -> String? {
        guard let url = currentHandlerURL() else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    static func currentHandlerDisplayName() -> String? {
        guard let url = currentHandlerURL() else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    static func register() async throws {
        try await setDefault(appURL: Bundle.main.bundleURL)
    }

    struct NoFallbackBrowserError: LocalizedError {
        var errorDescription: String? {
            "No other web browser is installed to hand the default role back to."
        }
    }

    static func unregister() async throws {
        guard let fallback = fallbackHandlerURL() else {
            throw NoFallbackBrowserError()
        }
        try await setDefault(appURL: fallback)
    }

    private static func setDefault(appURL: URL) async throws {
        do {
            try await NSWorkspace.shared.setDefaultApplication(
                at: appURL,
                toOpenURLsWithScheme: writeScheme
            )
        } catch {
            let ns = error as NSError
            Log.browser.error(
                "setDefaultApplication failed for scheme=\(writeScheme, privacy: .public) at=\(appURL.path, privacy: .public) domain=\(ns.domain, privacy: .public) code=\(ns.code) reason=\(ns.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    private static func fallbackHandlerURL() -> URL? {
        let handlers = NSWorkspace.shared.urlsForApplications(toOpen: probeURL)
        return handlers.first { url in
            guard let id = Bundle(url: url)?.bundleIdentifier else { return false }
            return id != bundleID
        }
    }
}
