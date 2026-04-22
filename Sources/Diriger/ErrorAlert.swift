import AppKit

@MainActor
enum AccessibilityPermission {
    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
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
