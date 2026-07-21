import Foundation

/// Serializes async operations into a single-flight chain: each call awaits its
/// predecessor before running, so at most one runs at a time — even when the
/// caller is an actor whose reentrancy would otherwise admit overlapping work.
///
/// Why this exists (#80, verify findings F1/F2): the MCP SDK dispatches every
/// request in its own `Task`, and `BestASRMCPServer`'s actor isolation is
/// released at each `await`. Without an explicit gate, N pipelined `transcribe`
/// calls run truly concurrently against the one shared engine — and
/// `CreateOnceStore.retainOnly` then evicts each other's in-flight model,
/// breaking the "one model resident at a time" invariant (OOM), while two
/// same-model calls reenter one shared pipeline. Routing only `transcribe`
/// through this gate keeps read-only tools (`list_*`, `recommend`) concurrent.
actor SingleFlight {
    /// Tail of the chain. Each new operation awaits the current tail, then
    /// installs itself as the new tail. The seed `Task {}` is already complete,
    /// so the first caller runs without waiting.
    private var tail: Task<Void, Never> = Task {}

    func run<T: Sendable>(_ operation: @Sendable @escaping () async throws -> T) async throws -> T {
        let predecessor = tail
        let task = Task { () async throws -> T in
            await predecessor.value
            return try await operation()
        }
        // Advance the tail synchronously — this runs before the `await` below,
        // so the actor cannot admit another `run` between the read of `tail`
        // and this write. The next caller therefore chains behind this task.
        // We swallow the result/error here; the caller observes them through
        // its own `task.value` await, and a failed operation must not wedge the
        // queue for the next one.
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
