import AppKit
import Foundation

struct DefaultBrowserService {
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

    static func register(completion: @escaping (Bool) -> Void) {
        guard let appURL = Bundle.main.bundleURL as URL? else {
            completion(false)
            return
        }
        setDefault(appURL: appURL, completion: completion)
    }

    static func unregister(completion: @escaping (Bool) -> Void) {
        guard let fallback = fallbackHandlerURL() else {
            completion(false)
            return
        }
        setDefault(appURL: fallback, completion: completion)
    }

    private static func setDefault(appURL: URL, completion: @escaping (Bool) -> Void) {
        let group = DispatchGroup()
        var success = true

        for scheme in schemes {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(
                at: appURL,
                toOpenURLsWithScheme: scheme
            ) { error in
                if error != nil { success = false }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(success)
        }
    }

    private static func fallbackHandlerURL() -> URL? {
        let handlers = NSWorkspace.shared.urlsForApplications(toOpen: probeURL)
        for url in handlers {
            guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
            if id != bundleID { return url }
        }
        return nil
    }
}
