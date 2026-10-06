import AppKit

@MainActor
enum AccessibilityPermission {
    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

/// macOS 27 locks Chrome's data folder; the user grants access in
/// Privacy & Security → Files & Folders → Diriger.app → Google Chrome.app.
/// The grant only takes effect after Diriger restarts.
@MainActor
enum ChromeDataAccess {
    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
        else { return }
        NSWorkspace.shared.open(url)
    }

    static func relaunchDiriger() {
        // A detached shell waits for this process to exit before reopening the
        // bundle, so the new instance doesn't hand off to the old one.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
            Bundle.main.bundlePath,
            String(ProcessInfo.processInfo.processIdentifier)
        ]
        do {
            try process.run()
        } catch {
            Log.app.error("Relaunch failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        NSApplication.shared.terminate(nil)
    }
}

@MainActor
enum ErrorAlert {
    static func present(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning

        if let localized = error as? LocalizedError {
            alert.messageText = localized.errorDescription ?? "An error occurred"
            if let suggestion = localized.recoverySuggestion {
                alert.informativeText = suggestion
            }
        } else {
            alert.messageText = "An error occurred"
            alert.informativeText = error.localizedDescription
        }

        if case ChromeLauncher.LaunchError.accessibilityDenied = error {
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                AccessibilityPermission.openSystemSettings()
            }
            return
        }

        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
