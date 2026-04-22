import Foundation

enum AppInfo {
    static let bundleID: String = Bundle.main.bundleIdentifier ?? "tech.inkhorn.diriger"
}

extension FileManager {
    /// Display name with the ".app" extension stripped when present.
    func appDisplayName(atPath path: String) -> String {
        let name = displayName(atPath: path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
