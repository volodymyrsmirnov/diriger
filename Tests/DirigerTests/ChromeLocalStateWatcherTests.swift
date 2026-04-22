import XCTest
@testable import Diriger

@MainActor
final class ChromeLocalStateWatcherTests: XCTestCase {
    private var tempDir: URL!
    private var fireCount: Int = 0

    override func setUp() async throws {
        try await super.setUp()
        fireCount = 0
        let uniqueDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: uniqueDir, withIntermediateDirectories: true)
        tempDir = uniqueDir
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeWatcher(directory: URL? = nil) -> ChromeLocalStateWatcher {
        let dir = directory ?? tempDir!
        let watcher = ChromeLocalStateWatcher(directoryURL: dir)
        watcher.onChange = { [weak self] in
            self?.fireCount += 1
        }
        return watcher
    }

    private func writeFile(name: String = "Local State", to directory: URL? = nil) throws {
        let dir = directory ?? tempDir!
        try Data().write(to: dir.appendingPathComponent(name))
    }

    private func deleteFile(name: String = "Local State", in directory: URL? = nil) throws {
        let dir = directory ?? tempDir!
        try FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }

    // MARK: - Test 1: onChange fires after a file write inside the directory

    func test_onChangeFiresAfterFileWriteInsideDirectory() async throws {
        let watcher = makeWatcher()
        watcher.start()

        try writeFile()

        // Wait 700 ms — well past the 400 ms debounce.
        let exp = expectation(description: "onChange fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 1.5)

        XCTAssertGreaterThanOrEqual(fireCount, 1, "onChange should have fired at least once")
        watcher.stop()
    }

    // MARK: - Test 2: Rapid burst of writes is coalesced into a single callback

    func test_onChangeCoalescesBurstIntoOneFire() async throws {
        let watcher = makeWatcher()
        watcher.start()

        // Write 5 files in quick succession — all within one debounce window.
        for i in 0 ..< 5 {
            try writeFile(name: "burst_\(i)")
        }

        // Wait 700 ms for the single debounced fire.
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(fireCount, 1, "Burst of writes should coalesce into exactly one onChange call")
        watcher.stop()
    }

    // MARK: - Test 3: start() is idempotent — calling it twice does not double-fire

    func test_startIsIdempotent() async throws {
        let watcher = makeWatcher()
        watcher.start()
        watcher.start() // second call must be a no-op

        try writeFile()

        try await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(fireCount, 1, "Double start() should not cause onChange to fire more than once per event")
        watcher.stop()
    }

    // MARK: - Test 4: Non-existent directory — start() silently no-ops

    func test_nonExistentDirectory_startIsNoOp() async throws {
        // Point at a path that does not exist.
        let ghost = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let watcher = makeWatcher(directory: ghost)
        watcher.start() // open() returns -1 → early return

        // Now create the directory and write a file. The watcher gave up at start(),
        // so it must NOT see these events.
        try FileManager.default.createDirectory(at: ghost, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ghost) }

        try writeFile(to: ghost)

        try await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(fireCount, 0, "Watcher on non-existent dir must not fire even after dir is created later")
        watcher.stop()
    }

    // MARK: - Test 5: stop() cancels the pending debounced Task

    func test_stopCancelsPendingDebouncedFire() async throws {
        let watcher = makeWatcher()
        watcher.start()

        try writeFile()

        // Let the kevent arrive and enqueue the debounce Task, but stop before 400 ms.
        try await Task.sleep(for: .milliseconds(100))
        watcher.stop()

        // Wait long enough that the debounce *would* have fired if not cancelled.
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(fireCount, 0, "stop() must cancel the pending debounced callback")
    }

    // MARK: - Test 6: stop() after start() with no events does not crash

    func test_stopAfterStartWithNoEvents_doesNotCrash() {
        let watcher = makeWatcher()
        watcher.start()
        watcher.stop()
        // Reaching here without a crash is the assertion.
    }

    // MARK: - Test 7: Deleting a file inside the directory triggers onChange

    func test_fileDeleteTriggersCallback() async throws {
        // Pre-create a file so we can delete it after start.
        try writeFile(name: "Local State")

        let watcher = makeWatcher()
        watcher.start()

        try deleteFile(name: "Local State")

        let exp = expectation(description: "onChange fires after delete")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 1.5)

        XCTAssertGreaterThanOrEqual(fireCount, 1, "Deleting a file must trigger onChange")
        watcher.stop()
    }

    // MARK: - Test 8: deinit cancels the source — no callback fires after the watcher is released

    func test_deinitCancelsSource() async throws {
        do {
            let watcher = makeWatcher()
            watcher.start()
            try writeFile(name: "deinit_probe")
            // Give the event a moment to enqueue the debounce Task, then drop the watcher.
            try await Task.sleep(for: .milliseconds(50))
        }
        // watcher is now deinitialized; source?.cancel() ran in deinit.

        // Wait well past the debounce window to confirm no callback fires.
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(fireCount, 0, "No onChange should fire after the watcher has been deinitialized")
    }
}
