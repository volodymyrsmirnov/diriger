import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let kindWidth: CGFloat = 130
private let profileWidth: CGFloat = 170
private let pillCornerRadius: CGFloat = 6
private let pillHeight: CGFloat = 26
private let pillHorizontalPadding: CGFloat = 8

struct RulesTableView: View {
    @Environment(RuleStore.self) private var store
    @Environment(ProfileManager.self) private var profileManager

    var body: some View {
        if store.rules.isEmpty {
            emptyState
        } else {
            rowsList
        }
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            Button {
                appendRule()
            } label: {
                Label("Add rule", systemImage: "plus")
            }
            .controlSize(.regular)
            Spacer()
        }
        .padding(.vertical, 18)
    }

    private var rowsList: some View {
        VStack(spacing: 6) {
            ForEach(Array(store.rules.enumerated()), id: \.element.id) { index, rule in
                RuleRow(
                    rule: rule,
                    profiles: profileManager.profiles,
                    canMoveUp: index > 0,
                    canMoveDown: index < store.rules.count - 1,
                    onChange: { store.update($0) },
                    onRemove: { store.remove(id: rule.id) },
                    onAddAfter: { addAfter(id: rule.id) },
                    onMoveUp: {
                        store.move(
                            fromOffsets: IndexSet(integer: index),
                            toOffset: index - 1
                        )
                    },
                    onMoveDown: {
                        store.move(
                            fromOffsets: IndexSet(integer: index),
                            toOffset: index + 2
                        )
                    }
                )
            }
        }
    }

    private func appendRule() {
        let identity = profileManager.profiles.first.map(ProfileIdentity.forProfile) ?? .directory("")
        store.add(RoutingRule(profileIdentity: identity))
    }

    private func addAfter(id: RoutingRule.ID) {
        guard let index = store.rules.firstIndex(where: { $0.id == id }) else {
            appendRule()
            return
        }
        let identity = profileManager.profiles.first.map(ProfileIdentity.forProfile) ?? .directory("")
        store.insert(RoutingRule(profileIdentity: identity), at: index + 1)
    }
}

private struct RuleRow: View {
    let rule: RoutingRule
    let profiles: [ChromeProfile]
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onChange: (RoutingRule) -> Void
    let onRemove: () -> Void
    let onAddAfter: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    private var isIdentityUnset: Bool {
        switch rule.profileIdentity {
        case .directory(let value): return value.isEmpty
        case .email(let value): return value.isEmpty
        }
    }

    private var profileMissing: Bool {
        !isIdentityUnset && rule.profileIdentity.directoryName(in: profiles) == nil
    }

    var body: some View {
        HStack(spacing: 10) {
            kindMenu
                .frame(width: kindWidth)

            patternField
                .frame(maxWidth: .infinity)

            profileMenu
                .frame(width: profileWidth)

            HStack(spacing: 4) {
                actionButton(
                    systemName: "arrow.up.circle.fill",
                    help: "Move up",
                    enabled: canMoveUp,
                    action: onMoveUp
                )
                actionButton(
                    systemName: "arrow.down.circle.fill",
                    help: "Move down",
                    enabled: canMoveDown,
                    action: onMoveDown
                )
                actionButton(
                    systemName: "minus.circle.fill",
                    help: "Remove rule",
                    enabled: true,
                    action: onRemove
                )
                actionButton(
                    systemName: "plus.circle.fill",
                    help: "Add rule below",
                    enabled: true,
                    action: onAddAfter
                )
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func actionButton(
        systemName: String,
        help: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .foregroundStyle(.secondary)
                .font(.system(size: 15))
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    private var kindMenu: some View {
        PillMenu(
            text: rule.kind.label,
            items: RuleKind.allCases.map { kind in
                PillMenuItem(title: kind.label) {
                    var copy = rule
                    copy.kind = kind
                    if copy.kind != .source { copy.sourceName = nil }
                    if copy.kind != rule.kind { copy.pattern = "" }
                    onChange(copy)
                }
            }
        )
    }

    private var profileMenu: some View {
        PillMenu(
            text: profileLabel,
            textColor: profileMissing ? .red : .primary,
            items: profiles.map { profile in
                PillMenuItem(title: profile.displayName) {
                    var copy = rule
                    copy.profileIdentity = ProfileIdentity.forProfile(profile)
                    onChange(copy)
                }
            }
        )
    }

    private var profileLabel: String {
        if let directory = rule.profileIdentity.directoryName(in: profiles),
           let profile = profiles.first(where: { $0.directoryName == directory }) {
            return profile.displayName
        }
        return isIdentityUnset ? "Select profile" : "Missing"
    }

    @ViewBuilder
    private var patternField: some View {
        switch rule.kind {
        case .source:
            SourcePattern(rule: rule, onChange: onChange)
        case .domain:
            PillTextField(
                text: patternBinding,
                isInvalid: !rule.pattern.isEmpty && !RuleEngine.isValidDomain(rule.pattern)
            )
        case .regex:
            PillTextField(
                text: patternBinding,
                isInvalid: !rule.pattern.isEmpty && !RuleEngine.isValidRegex(rule.pattern)
            )
        }
    }

    private var patternBinding: Binding<String> {
        Binding(
            get: { rule.pattern },
            set: { newValue in
                var copy = rule
                copy.pattern = newValue
                onChange(copy)
            }
        )
    }
}

// MARK: - Pill-styled controls

private struct PillMenuItem {
    let title: String
    let action: () -> Void
}

private struct PillMenu: View {
    let text: String
    var textColor: Color = .primary
    let items: [PillMenuItem]

    var body: some View {
        Menu {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button(item.title) { item.action() }
            }
        } label: {
            PillChrome {
                HStack(spacing: 6) {
                    Text(text)
                        .foregroundStyle(textColor)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

private struct PillTextField: View {
    @Binding var text: String
    let isInvalid: Bool

    @State private var isFocused: Bool = false

    var body: some View {
        EditableField(
            text: $text,
            isFocused: $isFocused
        )
        .frame(maxWidth: .infinity, minHeight: pillHeight)
        .background(
            RoundedRectangle(cornerRadius: pillCornerRadius, style: .continuous)
                .fill(isFocused ? pillFocusedFillColor : pillFillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: pillCornerRadius, style: .continuous)
                .stroke(
                    isInvalid ? Color.red.opacity(0.85) : pillBorderColor,
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        )
    }
}

private struct SourcePattern: View {
    let rule: RoutingRule
    let onChange: (RoutingRule) -> Void

    var body: some View {
        Button {
            pickApp()
        } label: {
            PillChrome {
                HStack(spacing: 6) {
                    appIcon
                        .frame(width: 16, height: 16)

                    Text(label)
                        .foregroundStyle(rule.pattern.isEmpty ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var label: String {
        if rule.pattern.isEmpty { return "Choose app…" }
        return rule.sourceName ?? rule.pattern
    }

    @ViewBuilder
    private var appIcon: some View {
        if !rule.pattern.isEmpty,
           let image = AppIconProvider.icon(forBundleID: rule.pattern)
        {
            Image(nsImage: image)
                .resizable()
        } else {
            Image(systemName: "app.dashed")
                .foregroundStyle(.secondary)
        }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
            var copy = rule
            copy.pattern = id
            copy.sourceName = FileManager.default.appDisplayName(atPath: url.path)
            onChange(copy)
        }
    }
}

// MARK: - Shared chrome

private struct PillChrome<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, pillHorizontalPadding)
            .frame(maxWidth: .infinity, minHeight: pillHeight)
            .background(
                RoundedRectangle(cornerRadius: pillCornerRadius, style: .continuous)
                    .fill(pillFillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: pillCornerRadius, style: .continuous)
                    .stroke(pillBorderColor, lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .contentShape(Rectangle())
    }
}

private var pillFillColor: Color {
    Color(nsColor: .controlBackgroundColor)
}

private var pillFocusedFillColor: Color {
    Color(nsColor: .selectedContentBackgroundColor).opacity(0.25)
}

private var pillBorderColor: Color {
    Color.primary.opacity(0.18)
}

// MARK: - Editable NSTextField wrapper

private final class PaddedTextFieldCell: NSTextFieldCell {
    static let horizontalInset: CGFloat = pillHorizontalPadding

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var r = rect
        r.origin.x += Self.horizontalInset
        r.size.width -= Self.horizontalInset * 2
        let font = self.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let lineHeight = ceil(font.ascender + abs(font.descender) + font.leading)
        r.origin.y = rect.origin.y + (rect.size.height - lineHeight) / 2
        r.size.height = lineHeight
        return r
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        return titleRect(forBounds: rect)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: titleRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: titleRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }
}

private final class PaddedTextField: NSTextField {
    override static var cellClass: AnyClass? {
        get { PaddedTextFieldCell.self }
        set { _ = newValue }
    }
}

private struct EditableField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = PaddedTextField(frame: .zero)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.alignment = .left
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.lineBreakMode = .byClipping
        field.delegate = context.coordinator
        field.stringValue = text
        applyFont(to: field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
        applyFont(to: field)
        context.coordinator.binding = $text
        context.coordinator.focusBinding = $isFocused
    }

    private func applyFont(to field: NSTextField) {
        let font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
        if field.font != font {
            field.font = font
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(binding: $text, focusBinding: $isFocused)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var binding: Binding<String>
        var focusBinding: Binding<Bool>

        init(binding: Binding<String>, focusBinding: Binding<Bool>) {
            self.binding = binding
            self.focusBinding = focusBinding
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            binding.wrappedValue = field.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            Task { @MainActor in self.focusBinding.wrappedValue = true }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            Task { @MainActor in self.focusBinding.wrappedValue = false }
        }
    }
}
