import SwiftUI
import AppKit
import KeyboardShortcuts
import ServiceManagement

struct SettingsView: View {
    @Environment(ProfileManager.self) private var profileManager
    @Environment(RuleStore.self) private var ruleStore

    @State private var launchAtLogin = SettingsView.readLaunchAtLogin()
    @State private var launchAtLoginError: String?
    @State private var isDefaultBrowser = DefaultBrowserService.isDefaultBrowser()
    @State private var currentBrowserName = DefaultBrowserService.currentHandlerDisplayName()
    @State private var defaultBrowserError: String?

    var body: some View {
        Form {
            launchAtLoginSection
            profileShortcutsSection
            defaultBrowserSection
            rulesSection
        }
        .formStyle(.grouped)
        .frame(width: 760, height: 720)
        .onAppear {
            launchAtLogin = SettingsView.readLaunchAtLogin()
            refreshDefaultBrowserState()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            refreshDefaultBrowserState()
        }
    }

    private var launchAtLoginSection: some View {
        Section {
            Toggle("Launch at login", isOn: launchAtLoginBinding)
            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var profileShortcutsSection: some View {
        Section("Profile Shortcuts") {
            if profileManager.profiles.isEmpty {
                Text("No Chrome profiles found.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(profileManager.profiles.prefix(KeyboardShortcuts.Name.maxSlots)) { profile in
                    HStack {
                        ProfileAvatar(profile: profile, size: 32)

                        VStack(alignment: .leading) {
                            Text(profile.displayName)
                                .font(.headline)
                            if !profile.email.isEmpty {
                                Text(profile.email)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        KeyboardShortcuts.Recorder(for: .forProfile(profile.directoryName))
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var defaultBrowserSection: some View {
        Section {
            Toggle(isOn: defaultBrowserBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use Diriger to open web links")
                    Text("Current default: \(currentBrowserName ?? "Unknown"). Turning this off hands the role back to another installed browser.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let defaultBrowserError {
                Text(defaultBrowserError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Link Handling")
        }
    }

    private var rulesSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("When a URL matches a rule, it opens directly in the selected profile, bypassing the picker. The first match in the list wins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                RulesTableView()
            }
            .opacity(isDefaultBrowser ? 1.0 : 0.5)
            .disabled(!isDefaultBrowser)
        } header: {
            Text("Routing Rules")
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in applyLaunchAtLogin(newValue) }
        )
    }

    private var defaultBrowserBinding: Binding<Bool> {
        Binding(
            get: { isDefaultBrowser },
            set: { newValue in applyDefaultBrowser(newValue) }
        )
    }

    private func applyLaunchAtLogin(_ newValue: Bool) {
        do {
            if newValue {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            Log.app.error("Launch at login toggle failed: \(error.localizedDescription, privacy: .public)")
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SettingsView.readLaunchAtLogin()
    }

    private func applyDefaultBrowser(_ newValue: Bool) {
        defaultBrowserError = nil
        Task {
            do {
                if newValue {
                    try await DefaultBrowserService.register()
                } else {
                    try await DefaultBrowserService.unregister()
                }
            } catch {
                Log.browser.error("Default browser toggle failed: \(error.localizedDescription, privacy: .public)")
                defaultBrowserError = error.localizedDescription
            }
            refreshDefaultBrowserState()
        }
    }

    private func refreshDefaultBrowserState() {
        isDefaultBrowser = DefaultBrowserService.isDefaultBrowser()
        currentBrowserName = DefaultBrowserService.currentHandlerDisplayName()
    }

    private static func readLaunchAtLogin() -> Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }
}
