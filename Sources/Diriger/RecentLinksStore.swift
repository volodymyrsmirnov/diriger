import Foundation

@MainActor
@Observable
final class RecentLinksStore {
    private(set) var links: [URL] = []
    private let maxCount = 10

    func record(_ url: URL) {
        links.removeAll { $0 == url }
        links.insert(url, at: 0)
        if links.count > maxCount {
            links.removeLast(links.count - maxCount)
        }
    }
}
