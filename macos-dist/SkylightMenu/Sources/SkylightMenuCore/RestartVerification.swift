import Foundation
import Observation

/// One bounded restart attempt. Tokens prevent an old command result or timer from affecting a retry.
@MainActor @Observable
public final class RestartVerification {
    public private(set) var awaitingReconnect = false
    public private(set) var error: String?
    private var token: UUID?
    private var deadline: Task<Void, Never>?
    private var minimumGeneration = 0
    private var sawDisconnect = false
    public init() {}

    @discardableResult
    public func begin(after generation: Int, timeout: Duration = .seconds(20), onExpiry: @escaping @MainActor () -> Void) -> UUID {
        cancel()
        let attempt = UUID()
        token = attempt
        minimumGeneration = generation + 1
        awaitingReconnect = true
        error = nil
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, token == attempt else { return }
            finish(error: "Moonwalk Host’s streaming service did not reconnect after restarting. Try again, or save diagnostics from Status.")
            onExpiry()
        }
        return attempt
    }

    public func observedDisconnect() { if awaitingReconnect { sawDisconnect = true } }

    @discardableResult
    public func verify(generation: Int) -> Bool {
        guard awaitingReconnect, sawDisconnect, generation >= minimumGeneration else { return false }
        finish(error: nil)
        return true
    }

    @discardableResult
    public func commandFailed(_ message: String, attempt: UUID) -> Bool {
        guard token == attempt else { return false }
        finish(error: message)
        return true
    }

    public func cancel() {
        deadline?.cancel()
        deadline = nil
        token = nil
        awaitingReconnect = false
        sawDisconnect = false
    }

    private func finish(error: String?) {
        cancel()
        self.error = error
    }
}
