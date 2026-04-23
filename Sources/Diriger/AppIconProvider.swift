import AppKit

@MainActor
enum AppIconProvider {
    private static var cache: [String: NSImage] = [:]

    static func icon(forBundleID bundleID: String, size: NSSize? = nil) -> NSImage? {
        let base: NSImage
        if let cached = cache[bundleID] {
            base = cached
        } else {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return nil
            }
            base = NSWorkspace.shared.icon(forFile: url.path)
            cache[bundleID] = base
        }
        guard let size else { return base }
        // NSWorkspace returns a shared NSImage; mutate a copy so other consumers
        // at different sizes aren't affected.
        let sized = base.copy() as? NSImage ?? base
        sized.size = size
        return sized
    }
}
