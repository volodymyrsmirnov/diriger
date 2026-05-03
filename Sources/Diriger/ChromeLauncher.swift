import AppKit
// AX C APIs (AXUIElementCopyAttributeValue, AXUIElementPerformAction, etc.) are
// thread-safe per Apple's documentation, but ApplicationServices ships without
// full Sendable annotations. Drop @preconcurrency once the SDK adopts them.
@preconcurrency import ApplicationServices

@MainActor
enum ChromeLauncher {
    static let chromeBundleID = "com.google.Chrome"

    enum LaunchError: LocalizedError {
        case chromeNotInstalled
        case accessibilityDenied
        case profileItemNotFound(displayName: String)
        case chromeLaunchFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .chromeNotInstalled:
                return "Google Chrome is not installed."
            case .accessibilityDenied:
                return "Diriger needs Accessibility permission to switch Chrome profiles."
            case let .profileItemNotFound(name):
                return "Couldn't find \"\(name)\" in Chrome's Profiles menu."
            case .chromeLaunchFailed:
                return "Failed to launch Google Chrome."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .chromeNotInstalled:
                return "Install Google Chrome from google.com/chrome."
            case .accessibilityDenied:
                return "Grant permission in System Settings › Privacy & Security › Accessibility."
            case .profileItemNotFound:
                return "The profile may have been renamed or removed in Chrome. The profile list updates automatically when Chrome changes."
            case let .chromeLaunchFailed(error):
                return error.localizedDescription
            }
        }
    }

    static func openURL(_ url: URL, in profile: ChromeProfile) async throws {
        guard let chromeURL = ChromeProfileService.chromeURL() else {
            throw LaunchError.chromeNotInstalled
        }
        let binaryURL = chromeURL.appendingPathComponent("Contents/MacOS/Google Chrome")

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = [
            "--profile-directory=\(profile.directoryName)",
            url.absoluteString
        ]
        do {
            try process.run()
            await raiseProfileWindow(profile)
            return
        } catch {
            Log.chrome
                .error(
                    "Direct Chrome spawn failed, falling back to NSWorkspace: \(error.localizedDescription, privacy: .public)"
                )
        }

        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--profile-directory=\(profile.directoryName)"]
        do {
            _ = try await NSWorkspace.shared.open(
                [url],
                withApplicationAt: chromeURL,
                configuration: config
            )
            await raiseProfileWindow(profile)
        } catch {
            throw LaunchError.chromeLaunchFailed(underlying: error)
        }
    }

    // Activating Chrome alone can leave a different profile's window frontmost;
    // clicking the Profiles menu item is what raises the target profile's window.
    // Best-effort: if AX isn't granted or Chrome isn't listed yet, we only log.
    private static func raiseProfileWindow(_ profile: ChromeProfile) async {
        guard AXIsProcessTrusted(), let chromeApp = findAndActivateChrome() else { return }
        do {
            try await selectProfileFromMenu(profile, pid: chromeApp.processIdentifier)
        } catch {
            Log.chrome.error(
                "raiseProfileWindow AX click failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    static func switchToProfile(_ profile: ChromeProfile) async throws {
        guard let chromeURL = ChromeProfileService.chromeURL() else {
            throw LaunchError.chromeNotInstalled
        }

        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            throw LaunchError.accessibilityDenied
        }

        guard let chromeApp = findAndActivateChrome() else {
            try await launchChrome(at: chromeURL, profile: profile)
            return
        }

        try await selectProfileFromMenu(profile, pid: chromeApp.processIdentifier)
    }

    private static func findAndActivateChrome() -> NSRunningApplication? {
        guard let chromeApp = NSWorkspace.shared.runningApplications.first(
            where: { $0.bundleIdentifier == chromeBundleID }
        ) else { return nil }
        chromeApp.activate()
        return chromeApp
    }

    private static func launchChrome(at chromeURL: URL, profile: ChromeProfile) async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--profile-directory=\(profile.directoryName)"]
        do {
            _ = try await NSWorkspace.shared.openApplication(at: chromeURL, configuration: config)
        } catch {
            throw LaunchError.chromeLaunchFailed(underlying: error)
        }
    }

    // AX traversal hops off MainActor: AXUIElement* APIs are thread-safe and the
    // cross-process IPC for menu walking can take tens of ms, which would otherwise
    // stall the UI.
    nonisolated private static func selectProfileFromMenu(_ profile: ChromeProfile, pid: pid_t) async throws {
        let app = AXUIElementCreateApplication(pid)
        guard let menuBar: AXUIElement = axAttribute(of: app, key: kAXMenuBarAttribute) else {
            throw LaunchError.profileItemNotFound(displayName: profile.displayName)
        }

        var target: AXUIElement?
        walkMenuTree(menuBar) { element in
            guard target == nil,
                  axIdentifier(of: element) == profileMenuItemIdentifier,
                  axTitle(of: element)?.contains(profile.displayName) == true
            else { return }
            target = element
        }

        guard let target else {
            throw LaunchError.profileItemNotFound(displayName: profile.displayName)
        }
        AXUIElementPerformAction(target, kAXPressAction as CFString)
    }

    nonisolated private static func walkMenuTree(_ element: AXUIElement, visit: (AXUIElement) -> Void) {
        visit(element)
        guard let children: [AXUIElement] = axAttribute(of: element, key: kAXChildrenAttribute) else {
            return
        }
        for child in children {
            walkMenuTree(child, visit: visit)
        }
    }

    nonisolated private static let profileMenuItemIdentifier = "switchToProfileFromMenu:"

    // MARK: - Accessibility helpers

    nonisolated private static func axAttribute<T>(of element: AXUIElement, key: String) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &ref) == .success else { return nil }
        return ref as? T
    }

    nonisolated private static func axTitle(of element: AXUIElement) -> String? {
        axAttribute(of: element, key: kAXTitleAttribute)
    }

    nonisolated private static func axIdentifier(of element: AXUIElement) -> String? {
        axAttribute(of: element, key: kAXIdentifierAttribute)
    }
}
