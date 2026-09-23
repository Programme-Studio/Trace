import XCTest

/// The lookup deadline is what stops a slow Dropbox holding a click hostage, and
/// its second job is quieter: a lookup that misses it keeps going, so its
/// answer is cached for the next click. Both fail silently if they regress.
final class DeadlineTests: XCTestCase {

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    func testReturnsTheResultWhenInTime() async {
        let result = await withDeadline(seconds: 2, fallback: "late") { "fast" }
        XCTAssertEqual(result, "fast")
    }

    func testReturnsTheFallbackOnTimeEvenIfTheOperationIgnoresCancellation() async {
        let started = Date()
        let result = await withDeadline(seconds: 0.2, fallback: "late") {
            // Blocks a thread without ever checking for cancellation — the
            // shape of the work that used to hold the old deadline open.
            Thread.sleep(forTimeInterval: 1.5)
            return "slow"
        }
        XCTAssertEqual(result, "late")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0,
                          "the caller waited for the operation instead of the deadline")
    }

    func testTheOperationRunsOnPastTheDeadline() async throws {
        let finished = Flag()
        _ = await withDeadline(seconds: 0.1, fallback: 0) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            // Would be skipped if timing out cancelled the operation.
            if !Task.isCancelled { finished.set() }
            return 1
        }
        XCTAssertFalse(finished.isSet)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertTrue(finished.isSet, "a timed-out lookup must still finish, so it can be cached")
    }
}
