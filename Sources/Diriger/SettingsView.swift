import SwiftUI
import AppKit
import ApplicationServices
import KeyboardShortcuts
import ServiceManagement

struct SettingsView: View {
    @Environment(ProfileManager.self) private var profileManager
    @Environment(RuleStore.self) private var ruleStore
    @Environment(DefaultBrowserMonitor.self) private var browserMonitor

    @State private var launchAtLogin = SettingsView.readLaunchAtLogin()
    @State private var launchAtLoginError: String?
    @State private var axGranted = AXIsProcessTrusted()
    @State private var syncEnabled = SyncedDefaults.shared.isEnabled
    @State private var iCloudSignedIn = FileManager.default.ubiquityIdentityToken != nil

    var body: some View {
        Form {
            generalSection
            profileShortcutsSection
            defaultBrowserSection
            rulesSection
            versionFooter
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(minWidth: 540, idealWidth: 540, minHeight: 520, idealHeight: 720)
        .background(SettingsWindowConfigurator())
        .onAppear {
            launchAtLogin = SettingsView.readLaunchAtLogin()
            browserMonitor.refresh()
            iCloudSignedIn = FileManager.default.ubiquityIdentityToken != nil
            // Diriger is LSUIElement so `NSApplication.didBecomeActiveNotification`
            // rarely fires; Settings-open is our deterministic pull-on-foreground trigger.
            if syncEnabled {
                SyncedDefaults.shared.reconcileAll()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            browserMonitor.refresh()
            axGranted = AXIsProcessTrusted()
            iCloudSignedIn = FileManager.default.ubiquityIdentityToken != nil
        }
    }

    private var iCloudToggleBinding: Binding<Bool> {
        Binding(
            get: { syncEnabled && iCloudSignedIn },
            set: { newValue in
                // Never turn sync ON while iCloud is signed out — the write would
                // silently no-op, and the UI would lie. We still honor OFF from any state.
                let target = newValue && iCloudSignedIn
                SyncedDefaults.shared.setEnabled(target)
                syncEnabled = SyncedDefaults.shared.isEnabled
            }
        )
    }

    private var generalSection: some View {
        Section {
            Toggle("Launch at login", isOn: launchAtLoginBinding)
            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Toggle("Sync settings via iCloud", isOn: iCloudToggleBinding)
                .disabled(!iCloudSignedIn)
            if !iCloudSignedIn {
                Text("Not signed into iCloud on this Mac. Sign in via System Settings to enable syncing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Accessibility permission")
                Spacer()
                if axGranted {
                    Text("Granted")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not granted")
                        .foregroundStyle(.red)
                    Button("Grant…") {
                        AccessibilityPermission.openSystemSettings()
                    }
                }
            }
        } header: {
            Text("General")
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

                        KeyboardShortcuts.Recorder(for: .forProfile(ProfileIdentity.forProfile(profile)))
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
                    Text(
                        "Current default: \(browserMonitor.currentName ?? "Unknown"). Turning this off hands the role back to another installed browser."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            if let error = browserMonitor.error {
                Text(error)
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
                Text(
                    "When a URL matches a rule, it opens directly in the selected profile, bypassing the picker. The first match in the list wins."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                RulesTableView()
            }
            .opacity(browserMonitor.isDefault ? 1.0 : 0.5)
            .disabled(!browserMonitor.isDefault)
        } header: {
            Text("Routing Rules")
        }
    }

    private var versionFooter: some View {
        Section {
            HStack {
                Spacer()
                Text("Version \(AppInfo.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
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
            get: { browserMonitor.isDefault },
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
        browserMonitor.error = nil
        Task {
            var capturedError: String?
            do {
                if newValue {
                    try await DefaultBrowserService.register()
                } else {
                    try await DefaultBrowserService.unregister()
                }
            } catch {
                Log.browser.error("Default browser toggle failed: \(error.localizedDescription, privacy: .public)")
                capturedError = error.localizedDescription
            }
            browserMonitor.refresh()
            browserMonitor.error = capturedError
        }
    }

    private static func readLaunchAtLogin() -> Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }
}

/// Hooks into the Settings NSWindow once SwiftUI mounts the view: centers it,
/// floats it above other windows for the lifetime of the session, and installs
/// a translucent vibrancy backdrop so the form sections sit on a soft material.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // .window is nil at makeNSView time; defer to the next runloop turn.
        Task { @MainActor in
            guard let window = view.window else { return }
            configure(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    @MainActor
    private func configure(_ window: NSWindow) {
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        installBackdrop(in: window)
        // Center on the screen the window currently lives on.
        window.center()
    }

    @MainActor
    private func installBackdrop(in window: NSWindow) {
        guard let contentView = window.contentView else { return }
        let identifier = NSUserInterfaceItemIdentifier("diriger.settings.backdrop")
        if contentView.subviews.contains(where: { $0.identifier == identifier }) { return }

        let backdrop = NSVisualEffectView()
        backdrop.identifier = identifier
        backdrop.material = .windowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(backdrop, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: contentView.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
    }
}
