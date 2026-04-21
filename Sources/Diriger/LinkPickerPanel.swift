import AppKit
import SwiftUI

final class LinkPickerPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onCommit: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSelectPrev: (() -> Void)?
    var onSelectNext: (() -> Void)?
    var onSelectIndex: ((Int) -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = mods.contains(.command)

        switch event.keyCode {
        case 53:
            onCancel?()
            return
        case 36, 76:
            onCommit?()
            return
        case 123, 126:
            onSelectPrev?()
            return
        case 124, 125:
            onSelectNext?()
            return
        default:
            break
        }

        if cmd, let chars = event.charactersIgnoringModifiers, chars == "c" {
            onCopy?()
            return
        }

        if let chars = event.charactersIgnoringModifiers, chars.count == 1,
           let scalar = chars.unicodeScalars.first,
           let digit = Int(String(scalar)),
           !cmd {
            let index = digit == 0 ? 9 : digit - 1
            onSelectIndex?(index)
            return
        }

        super.keyDown(with: event)
    }
}

struct LinkPickerView: View {
    let profiles: [ChromeProfile]
    let url: URL
    @Binding var selection: Int
    let onActivate: (Int) -> Void

    static let panelWidth: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 2) {
                ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                    ProfileRow(
                        profile: profile,
                        number: index + 1,
                        isSelected: index == selection
                    )
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { selection = index }
                    }
                    .onTapGesture {
                        onActivate(index)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)

            Divider()
                .padding(.top, 10)
                .padding(.horizontal, 16)

            Text(url.absoluteString)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: LinkPickerView.panelWidth, alignment: .leading)
    }
}

struct ProfileRow: View {
    let profile: ChromeProfile
    let number: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            profileImage
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(profile.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(numberLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(isSelected ? 0.18 : 0.10))
                )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.14 : 0.0))
        )
    }

    private var numberLabel: String {
        number == 10 ? "0" : String(number)
    }

    private var hint: String {
        if !profile.email.isEmpty {
            return profile.email
        }
        return "Press \(numberLabel) or ⏎ to open"
    }

    @ViewBuilder
    private var profileImage: some View {
        let path = ChromeProfileService.profilePicturePath(for: profile)
        if let nsImage = NSImage(contentsOfFile: path) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(fallbackColor)
                Text(String(profile.displayName.prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }

    private var fallbackColor: Color {
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .red, .teal, .indigo, .mint, .cyan]
        let hash = profile.directoryName.utf8.reduce(0) { ($0 &+ Int($1)) & 0x7FFFFFFF }
        return palette[hash % palette.count]
    }
}
