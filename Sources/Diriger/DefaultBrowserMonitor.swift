import AppKit
import Foundation

@MainActor
@Observable
final class DefaultBrowserMonitor {
    private(set) var isDefault: Bool
    private(set) var currentName: String?
    var error: String?

    private var activationObserver: NSObjectProtocol?

    init() {
        self.isDefault = DefaultBrowserService.isDefaultBrowser()
        self.currentName = DefaultBrowserService.currentHandlerDisplayName()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        isDefault = DefaultBrowserService.isDefaultBrowser()
        currentName = DefaultBrowserService.currentHandlerDisplayName()
    }
}
