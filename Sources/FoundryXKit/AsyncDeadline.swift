// AsyncDeadline — race an async leg against a wall-clock deadline.
//
// Extracted from `SpeakerConfirmFlow.withDeadline` (which now delegates here) so the SAME
// bounded-wait primitive can guard every background door leg — the speaker-confirm ship AND
// the pending-remote-delete drain (field hang, build 286: `retryPendingDeletes` paid a full
// URLSession timeout PER pending delete against an unreachable door, on every 5s drain).
//
// Deliberately UNSTRUCTURED (the adversarial-review P1 finding that shaped the original): a
// task group cannot return until its children finish, so a leg parked on a non-cancellable
// continuation (the relay mux turn — the b230 lost-response hang) would defeat a group-based
// race and leave a forever-spinner. Here the deadline resumes the caller REGARDLESS; the
// orphaned work task resolves (or is torn down with the transport) later and its late result
// is discarded. Every caller's intent is durable on disk and idempotent, so nothing is lost.

import Foundation

public enum AsyncDeadline {
    /// Thrown when `race` gives up on `work`. Callers that classify errors treat it as a
    /// TRANSIENT failure (the intent stays queued and is retried), never a rejection.
    public struct Exceeded: Error { public init() {} }

    /// Run `work`, but never wait longer than `seconds` (floored at 50ms). On the deadline
    /// the `timeoutError` is thrown and the work task is cancelled best-effort.
    public static func race<T: Sendable>(
        _ seconds: TimeInterval,
        timeoutError: @escaping @Sendable () -> Error = { Exceeded() },
        work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let once = ResumeOnce<T>()
        return try await withCheckedThrowingContinuation { cont in
            let workTask = Task {
                do {
                    let value = try await work()
                    await once.resume(cont, with: .success(value))
                } catch {
                    await once.resume(cont, with: .failure(error))
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0.05, seconds) * 1_000_000_000))
                await once.resume(cont, with: .failure(timeoutError()))
                workTask.cancel()   // best-effort; a non-cancellable leg just gets orphaned
            }
        }
    }

    /// Single-resume gate for the race — whichever side finishes first wins; the loser's
    /// result is discarded (never a double resume).
    private actor ResumeOnce<T: Sendable> {
        private var resumed = false
        func resume(_ cont: CheckedContinuation<T, Error>, with result: Result<T, Error>) {
            guard !resumed else { return }
            resumed = true
            cont.resume(with: result)
        }
    }
}
