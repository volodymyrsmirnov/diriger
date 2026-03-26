import AppKit
import ApplicationServices

struct ChromeLauncher {
    static func switchToProfile(_ profile: ChromeProfile) {
        guard let chromeURL = ChromeProfileService.chromeURL() else { return }

        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            return
        }

        let chromeApp = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.google.Chrome"
        }

        if let chromeApp {
            chromeApp.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                selectProfileFromMenu(profile, pid: chromeApp.processIdentifier)
            }
        } else {
            launchChrome(at: chromeURL, with: profile)
        }
    }

    private static func launchChrome(at chromeURL: URL, with profile: ChromeProfile) {
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--profile-directory=\(profile.directoryName)"]
        NSWorkspace.shared.openApplication(at: chromeURL, configuration: config)
    }

    private static func selectProfileFromMenu(_ profile: ChromeProfile, pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)

        guard let menuBar = axAttribute(of: app, key: kAXMenuBarAttribute) as AXUIElement?,
              let menuBarItems: [AXUIElement] = axAttribute(of: menuBar, key: kAXChildrenAttribute),
              let profilesItem = menuBarItems.first(where: { axTitle(of: $0) == "Profiles" })
        else { return }

        AXUIElementPerformAction(profilesItem, kAXPressAction as CFString)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let menus: [AXUIElement] = axAttribute(of: profilesItem, key: kAXChildrenAttribute),
                  let menu = menus.first,
                  let menuItems: [AXUIElement] = axAttribute(of: menu, key: kAXChildrenAttribute),
                  let match = menuItems.first(where: { axTitle(of: $0)?.contains(profile.displayName) == true })
            else { return }

            AXUIElementPerformAction(match, kAXPressAction as CFString)
        }
    }

    // MARK: - Accessibility Helpers

    private static func axAttribute<T>(of element: AXUIElement, key: String) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &ref) == .success else { return nil }
        return ref as? T
    }

    private static func axTitle(of element: AXUIElement) -> String? {
        axAttribute(of: element, key: kAXTitleAttribute)
    }
}
