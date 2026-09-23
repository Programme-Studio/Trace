import Foundation

/// Runs `operation`, returning `fallback` if it hasn't finished within `seconds`.
///
/// A hard deadline: the caller gets `fallback` on time whatever `operation` is
/// doing, and `operation` is *not* cancelled — it runs to completion in the
/// background, so any side effect it has (caching an answer) still happens.
/// The earlier version raced the two in a task group, which can only return
/// once every child has finished, so the deadline held only as far as the
/// operation noticed cancellation.
func withDeadline<T: Sendable>(
    seconds: Double,
    fallback: T,
    operation: @escaping @Sendable () async -> T
) async -> T {
    let race = DeadlineRace<T>()
    return await withCheckedContinuation { continuation in
        race.continuation = continuation
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            race.finish(fallback)
        }
        Task {
            race.finish(await operation())
            timer.cancel()
        }
    }
}

/// Resumes the caller exactly once, with whichever result arrives first.
private final class DeadlineRace<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<T, Never>?

    var continuation: CheckedContinuation<T, Never>? {
        get { lock.withLock { pending } }
        set { lock.withLock { pending = newValue } }
    }

    func finish(_ value: T) {
        let waiting: CheckedContinuation<T, Never>? = lock.withLock {
            defer { pending = nil }
            return pending
        }
        waiting?.resume(returning: value)
    }
}
