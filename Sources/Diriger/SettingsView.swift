import SwiftUI
import AppKit
import KeyboardShortcuts
import ServiceManagement

struct SettingsView: View {
    let profiles: [ChromeProfile]
    let ruleStore: RuleStore

    @State private var launchAtLogin = {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }()
    @State private var isDefaultBrowser = DefaultBrowserService.isDefaultBrowser()
    @State private var currentBrowserName = DefaultBrowserService.currentHandlerDisplayName()

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            print("Launch at login failed: \(error)")
                        }
                        let status = SMAppService.mainApp.status
                        launchAtLogin = status == .enabled || status == .requiresApproval
                    }
                ))
            }

            Section("Profile Shortcuts") {
                if profiles.isEmpty {
                    Text("No Chrome profiles found.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(profiles.prefix(KeyboardShortcuts.Name.maxSlots)) { profile in
                        HStack {
                            ProfileIcon(profile: profile)
                                .frame(width: 32, height: 32)

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

            Section {
                Toggle(isOn: Binding(
                    get: { isDefaultBrowser },
                    set: { newValue in
                        if newValue {
                            DefaultBrowserService.register { _ in refreshDefaultBrowserState() }
                        } else {
                            DefaultBrowserService.unregister { _ in refreshDefaultBrowserState() }
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use Diriger to open web links")
                        Text("Current default: \(currentBrowserName ?? "Unknown"). Turning this off hands the role back to another installed browser.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Link Handling")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("When a URL matches a rule, it opens directly in the selected profile, bypassing the picker. The first match in the list wins.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    RulesTableView(store: ruleStore, profiles: profiles)
                }
                .opacity(isDefaultBrowser ? 1.0 : 0.5)
                .disabled(!isDefaultBrowser)
            } header: {
                Text("Routing Rules")
            }
        }
        .formStyle(.grouped)
        .frame(width: 760, height: 720)
        .onAppear {
            let status = SMAppService.mainApp.status
            launchAtLogin = status == .enabled || status == .requiresApproval
            refreshDefaultBrowserState()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            refreshDefaultBrowserState()
        }
    }

    private func refreshDefaultBrowserState() {
        isDefaultBrowser = DefaultBrowserService.isDefaultBrowser()
        currentBrowserName = DefaultBrowserService.currentHandlerDisplayName()
    }
}

struct ProfileIcon: View {
    let profile: ChromeProfile

    var body: some View {
        let path = ChromeProfileService.profilePicturePath(for: profile)
        if let nsImage = NSImage(contentsOfFile: path) {
            Image(nsImage: nsImage)
                .resizable()
                .clipShape(Circle())
        } else {
            Circle()
                .fill(colorForProfile(profile))
                .overlay {
                    Text(String(profile.displayName.prefix(1)).uppercased())
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
        }
    }

    private func colorForProfile(_ profile: ChromeProfile) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .red, .teal, .indigo, .mint, .cyan]
        let hash = profile.directoryName.utf8.reduce(0) { ($0 &+ Int($1)) & 0x7FFFFFFF }
        return colors[hash % colors.count]
    }
}
