import Foundation
import os

/// Watches the Chrome support *directory* rather than the Local State file directly,
/// because Chrome writes Local State atomically via rename — which invalidates a
/// file-level file descriptor and would cause the source to go silent.
@MainActor
final class ChromeLocalStateWatcher {
    private let directoryURL: URL
    var onChange: (@MainActor () -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var pendingReload: Task<Void, Never>?

    init(
        directoryURL: URL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
    ) {
        self.directoryURL = directoryURL
    }

    func start() {
        // Idempotent: already watching.
        guard source == nil else { return }

        let newFD = directoryURL.path.withCString { open($0, O_EVTONLY) }

        guard newFD >= 0 else {
            // Chrome not installed or directory not yet present — not an error condition.
            Log.chrome.info("ChromeLocalStateWatcher: directory not found, skipping watch")
            return
        }

        // Dispatch events on the main queue so the handler runs on the main actor's
        // executor. Hopping via `Task { @MainActor }` from .global() crashes under
        // Swift 6 (dispatch_assert_queue fails during runtime isolation check).
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: newFD,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )

        newSource.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduleDebouncedFire()
            }
        }

        newSource.setCancelHandler { [fd = newFD] in
            close(fd)
        }

        source = newSource
        newSource.resume()
    }

    func stop() {
        pendingReload?.cancel()
        pendingReload = nil
        source?.cancel()
        source = nil
    }

    deinit {
        // Task and DispatchSource are Sendable; safe to touch from nonisolated deinit.
        source?.cancel()
    }

    private func scheduleDebouncedFire() {
        pendingReload?.cancel()
        pendingReload = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.onChange?()
        }
    }
}
