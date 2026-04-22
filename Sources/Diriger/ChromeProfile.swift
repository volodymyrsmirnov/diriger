import Foundation
import SwiftUI

struct ChromeProfile: Identifiable, Hashable {
    let directoryName: String
    let displayName: String
    let email: String

    var id: String {
        directoryName
    }
}

extension ChromeProfile {
    var initial: String {
        String(displayName.prefix(1)).uppercased()
    }

    var fallbackColor: Color {
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .red, .teal, .indigo, .mint, .cyan]
        let hash = directoryName.utf8.reduce(0) { ($0 &+ Int($1)) & 0x7FFF_FFFF }
        return palette[hash % palette.count]
    }
}
