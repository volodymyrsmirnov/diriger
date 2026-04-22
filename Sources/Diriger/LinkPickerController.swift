import AppKit
import SwiftUI
import KeyboardShortcuts

@MainActor
@Observable
final class LinkPickerState {
    var profiles: [ChromeProfile] = []
    var url: URL?
    var selection: Int = 0
}

@MainActor
final class LinkPickerController {
    private let profileManager: ProfileManager
    private let state = LinkPickerState()
    private var panel: LinkPickerPanel?
    private var globalClickMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var hostingView: NSHostingView<PickerRoot>?

    init(profileManager: ProfileManager) {
        self.profileManager = profileManager
    }

    func present(url: URL) {
        let profiles = Array(profileManager.profiles.prefix(KeyboardShortcuts.Name.maxSlots))
        guard !profiles.isEmpty else {
            Log.picker.warning("present() called with no profiles; dropping \(url.absoluteString, privacy: .public)")
            return
        }

        state.profiles = profiles
        state.url = url
        state.selection = 0

        let panel = ensurePanel()
        layoutContent(into: panel)
        positionPanel(panel, near: NSEvent.mouseLocation)

        panel.orderFrontRegardless()
        panel.makeKey()

        installGlobalMonitors(for: panel)
    }

    private func ensurePanel() -> LinkPickerPanel {
        if let existing = panel { return existing }
        let panel = LinkPickerPanel()

        let container: NSView
        if #available(macOS 26, *) {
            let plain = NSView()
            plain.wantsLayer = true
            plain.autoresizingMask = [.width, .height]
            container = plain
        } else {
            let visual = NSVisualEffectView()
            visual.material = .hudWindow
            visual.blendingMode = .behindWindow
            visual.state = .active
            visual.wantsLayer = true
            visual.layer?.cornerRadius = 16
            visual.layer?.masksToBounds = true
            visual.autoresizingMask = [.width, .height]
            container = visual
        }
        panel.contentView = container

        let hosting = NSHostingView(rootView: PickerRoot(
            state: state,
            activate: { [weak self] index in self?.activate(index: index) }
        ))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        hostingView = hosting

        panel.onCancel = { [weak self] in self?.cancel() }
        panel.onCommit = { [weak self] in self?.commitSelected() }
        panel.onCopy = { [weak self] in self?.copy() }
        panel.onSelectPrev = { [weak self] in self?.move(by: -1) }
        panel.onSelectNext = { [weak self] in self?.move(by: +1) }
        panel.onSelectIndex = { [weak self] index in self?.selectIndex(index) }

        self.panel = panel
        return panel
    }

    private func layoutContent(into panel: LinkPickerPanel) {
        guard let hosting = hostingView else { return }
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let width = max(LinkPickerView.panelWidth, fitting.width)
        let height = max(140, fitting.height)
        var frame = panel.frame
        frame.size = NSSize(width: width, height: height)
        panel.setFrame(frame, display: false)
    }

    private func positionPanel(_ panel: LinkPickerPanel, near cursor: NSPoint) {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let size = panel.frame.size
        var origin = NSPoint(x: cursor.x - size.width / 2, y: cursor.y - size.height / 2)

        let visible = screen.visibleFrame
        let padding: CGFloat = 8
        origin.x = max(visible.minX + padding, min(origin.x, visible.maxX - size.width - padding))
        origin.y = max(visible.minY + padding, min(origin.y, visible.maxY - size.height - padding))

        panel.setFrameOrigin(origin)
    }

    private func installGlobalMonitors(for panel: LinkPickerPanel) {
        removeGlobalMonitors()

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }
    }

    private func removeGlobalMonitors() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let observer = resignObserver {
            NotificationCenter.default.removeObserver(observer)
            resignObserver = nil
        }
    }

    private func hide() {
        removeGlobalMonitors()
        panel?.orderOut(nil)
    }

    private func cancel() {
        hide()
    }

    private func commitSelected() {
        activate(index: state.selection)
    }

    private func activate(index: Int) {
        guard state.profiles.indices.contains(index), let url = state.url else { return }
        let profile = state.profiles[index]
        hide()
        Task {
            do {
                try await ChromeLauncher.openURL(url, in: profile)
            } catch {
                Log.chrome.error("openURL failed: \(error.localizedDescription, privacy: .public)")
                ErrorAlert.present(error)
            }
        }
    }

    private func copy() {
        guard let url = state.url else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
        hide()
    }

    private func move(by delta: Int) {
        guard !state.profiles.isEmpty else { return }
        let count = state.profiles.count
        state.selection = ((state.selection + delta) % count + count) % count
    }

    private func selectIndex(_ index: Int) {
        guard state.profiles.indices.contains(index) else { return }
        activate(index: index)
    }
}

struct PickerRoot: View {
    @Bindable var state: LinkPickerState
    let activate: (Int) -> Void

    var body: some View {
        if let url = state.url {
            LinkPickerView(
                profiles: state.profiles,
                url: url,
                selection: $state.selection,
                onActivate: activate
            )
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }
}
