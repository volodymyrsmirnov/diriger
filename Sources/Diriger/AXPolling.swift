import Foundation

@MainActor
enum AXPoll {
    static func wait<T>(
        timeout: Duration = .milliseconds(1500),
        interval: Duration = .milliseconds(25),
        probe: () -> T?
    ) async -> T? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let value = probe() { return value }
            try? await Task.sleep(for: interval)
        }
        return probe()
    }
}
