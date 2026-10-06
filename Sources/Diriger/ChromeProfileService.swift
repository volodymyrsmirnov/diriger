import Foundation
import AppKit

enum ChromeProfileService {
    private static var chromeSupportDirectory: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
    }

    private static var localStateURL: URL {
        chromeSupportDirectory.appendingPathComponent("Local State", isDirectory: false)
    }

    struct LoadResult: Sendable {
        let profiles: [ChromeProfile]
        /// macOS refused to let Diriger read Chrome's data folder. On macOS 27+ the
        /// user must allow Diriger.app → Google Chrome.app in Privacy & Security →
        /// Files & Folders, then relaunch Diriger.
        let accessDenied: Bool
    }

    nonisolated static func loadProfiles() async -> LoadResult {
        load(localStateURL: localStateURL)
    }

    nonisolated static func loadProfiles(localStateURL url: URL) async -> [ChromeProfile] {
        loadProfilesSync(localStateURL: url)
    }

    /// Synchronous variant for startup-critical paths (e.g. `SyncMigration` running
    /// before `RuleStore` initializes). Reads the same JSON payload from disk;
    /// the `async` variant exists only so callers can schedule it off the main thread.
    nonisolated static func loadProfilesSync(localStateURL url: URL = localStateURL) -> [ChromeProfile] {
        load(localStateURL: url).profiles
    }

    nonisolated static func load(localStateURL url: URL) -> LoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            Log.chrome
                .error(
                    "Failed to read Chrome Local State at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            return LoadResult(profiles: [], accessDenied: isAccessDenied(error))
        }
        return LoadResult(profiles: parseProfiles(from: data), accessDenied: false)
    }

    /// True for permission failures (as opposed to Chrome simply not being installed).
    nonisolated static func isAccessDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(nsError.code) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isAccessDenied(underlying)
        }
        return false
    }

    /// Parse a Chrome `Local State` JSON payload into `ChromeProfile` values.
    /// Returns an empty array on any structural or parse error.
    nonisolated static func parseProfiles(from data: Data) -> [ChromeProfile] {
        let infoCache: [String: Any]
        do {
            let parsed = try JSONSerialization.jsonObject(with: data)
            guard let root = parsed as? [String: Any],
                  let profile = root["profile"] as? [String: Any],
                  let cache = profile["info_cache"] as? [String: Any]
            else {
                Log.chrome.error("Chrome Local State has unexpected structure")
                return []
            }
            infoCache = cache
        } catch {
            Log.chrome.error("Failed to parse Chrome Local State JSON: \(error.localizedDescription, privacy: .public)")
            return []
        }

        return infoCache.compactMap { directoryName, value -> ChromeProfile? in
            guard let info = value as? [String: Any],
                  let displayName = info["name"] as? String
            else { return nil }
            let email = info["user_name"] as? String ?? ""
            return ChromeProfile(
                directoryName: directoryName,
                displayName: displayName,
                email: email
            )
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    static func chromeURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")
    }

    static func profilePictureURL(for profile: ChromeProfile) -> URL? {
        let url = chromeSupportDirectory
            .appendingPathComponent(profile.directoryName, isDirectory: true)
            .appendingPathComponent("Google Profile Picture.png", isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
