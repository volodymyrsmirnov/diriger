import SwiftUI
import AppKit

enum ProfileAvatarShape {
    case circle
    case roundedRect(cornerRadius: CGFloat)
}

struct ProfileAvatar: View {
    let profile: ChromeProfile
    var shape: ProfileAvatarShape = .circle
    var size: CGFloat = 32

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(clipShape)
    }

    @ViewBuilder
    private var content: some View {
        if let url = ChromeProfileService.profilePictureURL(for: profile),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
        } else {
            ZStack {
                Rectangle().fill(profile.fallbackColor)
                Text(profile.initial)
                    .font(.system(size: size * 0.44, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }

    private var clipShape: AnyShape {
        switch shape {
        case .circle:
            AnyShape(Circle())
        case .roundedRect(let cornerRadius):
            AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

extension ProfileAvatar {
    /// Rasterize the avatar for AppKit surfaces that need `NSImage`
    /// (e.g. `MenuBarExtra` content that funnels through `Image`).
    @MainActor
    func rasterized(scale: CGFloat = 2) -> NSImage? {
        let renderer = ImageRenderer(content: self)
        renderer.scale = scale
        return renderer.nsImage
    }
}
