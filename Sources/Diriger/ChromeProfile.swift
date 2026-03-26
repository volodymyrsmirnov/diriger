import Foundation

struct ChromeProfile: Identifiable, Hashable {
    let directoryName: String
    let displayName: String
    let email: String

    var id: String { directoryName }
}
