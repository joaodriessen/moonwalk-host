import Foundation

/// Completes a callback operation once, even if the peer stays silent or replies after cancel.
/// The timer and cancellation resume the continuation directly, independent of actor progress.
public final class BoundedReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var result: Value?
    private var continuation: CheckedContinuation<Value, Never>?
    private var deadline: DispatchWorkItem?

    public init() {}

    @discardableResult
    public func resolve(_ value: Value) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        finished = true
        result = value
        let waiting = continuation
        continuation = nil
        let timer = deadline
        deadline = nil
        lock.unlock()
        timer?.cancel()
        waiting?.resume(returning: value)
        return true
    }

    public func value(
        timeout: TimeInterval, fallback: Value,
        isolation: isolated (any Actor)? = #isolation,
        onTimeout: @escaping @Sendable () -> Void = {},
        send: ( @escaping @Sendable (Value) -> Void) -> Void
    ) async -> Value {
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiting in
                lock.lock()
                if finished {
                    let resolved = result!
                    lock.unlock()
                    waiting.resume(returning: resolved)
                    return
                }
                continuation = waiting
                let timer = DispatchWorkItem { [weak self] in
                    if self?.resolve(fallback) == true { onTimeout() }
                }
                deadline = timer
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                send { [self] value in resolve(value) }
            }
        } onCancel: {
            self.resolve(fallback)
        }
    }
}
