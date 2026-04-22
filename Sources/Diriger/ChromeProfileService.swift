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

    nonisolated static func loadProfiles() async -> [ChromeProfile] {
        let url = localStateURL
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            Log.chrome
                .error(
                    "Failed to read Chrome Local State at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            return []
        }

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
