import AppKit
import Foundation

enum DefaultBrowserService {
    private static let schemes = ["http", "https"]
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
        try await withThrowingTaskGroup(of: Void.self) { group in
            for scheme in schemes {
                group.addTask {
                    try await NSWorkspace.shared.setDefaultApplication(
                        at: appURL,
                        toOpenURLsWithScheme: scheme
                    )
                }
            }
            try await group.waitForAll()
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
