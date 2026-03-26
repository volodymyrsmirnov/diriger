import Foundation
import AppKit

struct ChromeProfileService {
    static let chromeLocalStatePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Google/Chrome/Local State"
    }()

    static func loadProfiles() -> [ChromeProfile] {
        guard let data = FileManager.default.contents(atPath: chromeLocalStatePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let infoCache = profile["info_cache"] as? [String: Any]
        else {
            return []
        }

        return infoCache.compactMap { (directoryName, value) -> ChromeProfile? in
            guard let info = value as? [String: Any],
                  let displayName = info["name"] as? String
            else {
                return nil
            }
            let email = info["user_name"] as? String ?? ""
            return ChromeProfile(
                directoryName: directoryName,
                displayName: displayName,
                email: email
            )
        }
        .sorted { $0.directoryName.localizedStandardCompare($1.directoryName) == .orderedAscending }
    }

    static func chromeURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")
    }

    static func profilePicturePath(for profile: ChromeProfile) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Google/Chrome/\(profile.directoryName)/Google Profile Picture.png"
    }
}
