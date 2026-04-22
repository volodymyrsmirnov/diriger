import SwiftUI
import AppKit

struct ProfileAvatar: View {
    let profile: ChromeProfile
    // nil means circular (cornerRadius = size / 2)
    var cornerRadius: CGFloat?
    var size: CGFloat = 32

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? size / 2, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        if let url = ChromeProfileService.profilePictureURL(for: profile),
           let image = NSImage(contentsOf: url)
        {
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
}

// MARK: - Rasterization

@MainActor private let avatarImageCache = NSCache<NSString, NSImage>()

extension ProfileAvatar {
    /// Rasterize the avatar for AppKit surfaces that need `NSImage`
    /// (e.g. `MenuBarExtra` content that funnels through `Image`).
    @MainActor
    func rasterized(scale: CGFloat = 2) -> NSImage? {
        let key = "\(profile.id)-\(size)-\(scale)" as NSString
        if let cached = avatarImageCache.object(forKey: key) {
            return cached
        }
        let renderer = ImageRenderer(content: self)
        renderer.scale = scale
        guard let image = renderer.nsImage else { return nil }
        avatarImageCache.setObject(image, forKey: key)
        return image
    }
}
