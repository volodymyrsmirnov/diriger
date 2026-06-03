import AppKit
import Foundation
import UniformTypeIdentifiers

enum DefaultBrowserService {
    // macOS keeps http and https in sync for the web-browser role; setting
    // both in succession triggers NSFileReadUnknownError on the second call,
    // so we only set http and let the system propagate to https.
    private static let writeScheme = "http"
    private static let probeURL = URL(string: "https://example.com")!

    static func isDefaultBrowser() -> Bool {
        currentHandlerBundleID() == AppInfo.bundleID
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
        return FileManager.default.appDisplayName(atPath: url.path)
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
        await setDefaultHTMLHandler(appURL: appURL)
    }

    // Local .html files are routed by their content-type handler, which is separate
    // from the http(s) scheme handler above. Claiming it alongside the browser role
    // lets Diriger show the picker for HTML files too. Best-effort: a failure here
    // shouldn't roll back the primary default-browser change.
    private static func setDefaultHTMLHandler(appURL: URL) async {
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: .html)
        } catch {
            let ns = error as NSError
            Log.browser.error(
                "setDefaultApplication for public.html failed at=\(appURL.path, privacy: .public) domain=\(ns.domain, privacy: .public) code=\(ns.code) reason=\(ns.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func fallbackHandlerURL() -> URL? {
        let handlers = NSWorkspace.shared.urlsForApplications(toOpen: probeURL)
        return handlers.first { url in
            guard let id = Bundle(url: url)?.bundleIdentifier else { return false }
            return id != AppInfo.bundleID
        }
    }
}
