import Foundation

// Thrown by `withTimeout` when `operation` doesn't finish within the budget.
struct TimedOutError: Error {}

// Runs `operation` but guarantees the caller is unblocked within `timeout`.
//
// On timeout the operation's Task is cancelled - so a *cooperative* hang (one
// that polls `Task.checkCancellation()`, like FluidAudio's TDT decode loop)
// unwinds at its next check - and then ABANDONED, so even a *non-cooperative*
// hang (a CoreML / ANE `prediction()` that never returns) can't keep the caller
// frozen. That abandonment is the difference from MeetingSummarizer's plain
// cancel-then-await watchdog, which would still wait on a non-cancellable hang.
func withTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let work = Task { try await operation() }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let gate = ResumeGate()
            // Operation path.
            Task {
                do {
                    let value = try await work.value
                    if gate.claim() { continuation.resume(returning: value) }
                } catch {
                    if gate.claim() { continuation.resume(throwing: error) }
                }
            }
            // Deadline path: cancel the (possibly stuck) work and time out.
            Task {
                try? await Task.sleep(for: timeout)
                if gate.claim() {
                    work.cancel()
                    continuation.resume(throwing: TimedOutError())
                }
            }
        }
    } onCancel: {
        work.cancel()
    }
}

// One-shot guard so exactly one racer resolves the continuation. NSLock keeps it
// synchronous (an actor would force a Task hop inside the continuation body).
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resolved { return false }
        resolved = true
        return true
    }
}
