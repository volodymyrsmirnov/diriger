import AppKit
@preconcurrency import ApplicationServices

@MainActor
enum ChromeLauncher {
    static let chromeBundleID = "com.google.Chrome"

    enum LaunchError: LocalizedError {
        case chromeNotInstalled
        case accessibilityDenied
        case profilesMenuNotFound
        case profileItemNotFound(displayName: String)
        case chromeLaunchFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .chromeNotInstalled:
                return "Google Chrome is not installed."
            case .accessibilityDenied:
                return "Diriger needs Accessibility permission to switch Chrome profiles."
            case .profilesMenuNotFound:
                return "Couldn't find Chrome's Profiles menu."
            case .profileItemNotFound(let name):
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
            case .profilesMenuNotFound:
                return "Diriger supports English-language Chrome only. Make sure Chrome is running and its menu bar uses English."
            case .profileItemNotFound:
                return "The profile may have been renamed or removed in Chrome. Use Refresh Profiles in the menu bar."
            case .chromeLaunchFailed(let error):
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
            return
        } catch {
            Log.chrome.error("Direct Chrome spawn failed, falling back to NSWorkspace: \(error.localizedDescription, privacy: .public)")
        }

        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--profile-directory=\(profile.directoryName)"]
        do {
            _ = try await NSWorkspace.shared.open(
                [url],
                withApplicationAt: chromeURL,
                configuration: config
            )
        } catch {
            throw LaunchError.chromeLaunchFailed(underlying: error)
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

        let chromeApp = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == chromeBundleID
        }

        guard let chromeApp else {
            try await launchChrome(at: chromeURL, profile: profile)
            return
        }

        chromeApp.activate()
        try await selectProfileFromMenu(profile, pid: chromeApp.processIdentifier)
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

    private static func selectProfileFromMenu(_ profile: ChromeProfile, pid: pid_t) async throws {
        let app = AXUIElementCreateApplication(pid)

        let profilesItem = await AXPoll.wait { () -> AXUIElement? in
            guard let menuBar: AXUIElement = axAttribute(of: app, key: kAXMenuBarAttribute),
                  let items: [AXUIElement] = axAttribute(of: menuBar, key: kAXChildrenAttribute)
            else { return nil }
            return items.first { axTitle(of: $0) == "Profiles" }
        }
        guard let profilesItem else {
            throw LaunchError.profilesMenuNotFound
        }

        AXUIElementPerformAction(profilesItem, kAXPressAction as CFString)

        let targetItem = await AXPoll.wait { () -> AXUIElement? in
            guard let menus: [AXUIElement] = axAttribute(of: profilesItem, key: kAXChildrenAttribute),
                  let menu = menus.first,
                  let menuItems: [AXUIElement] = axAttribute(of: menu, key: kAXChildrenAttribute),
                  !menuItems.isEmpty
            else { return nil }
            return menuItems.first { axTitle(of: $0)?.contains(profile.displayName) == true }
        }
        guard let targetItem else {
            // Dismiss the opened menu so we don't leave Chrome in a weird state.
            AXUIElementPerformAction(profilesItem, kAXCancelAction as CFString)
            throw LaunchError.profileItemNotFound(displayName: profile.displayName)
        }

        AXUIElementPerformAction(targetItem, kAXPressAction as CFString)
    }

    // MARK: - Accessibility helpers

    private static func axAttribute<T>(of element: AXUIElement, key: String) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &ref) == .success else { return nil }
        return ref as? T
    }

    private static func axTitle(of element: AXUIElement) -> String? {
        axAttribute(of: element, key: kAXTitleAttribute)
    }
}
