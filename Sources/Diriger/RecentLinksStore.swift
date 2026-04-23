import Foundation

struct RecentLink: Hashable {
    let url: URL
    let sourceBundleID: String?
}

@MainActor
@Observable
final class RecentLinksStore {
    private(set) var links: [RecentLink] = []
    private let maxCount = 10

    func record(_ url: URL, sourceBundleID: String?) {
        links.removeAll { $0.url == url }
        links.insert(RecentLink(url: url, sourceBundleID: sourceBundleID), at: 0)
        if links.count > maxCount {
            links.removeLast(links.count - maxCount)
        }
    }
}
