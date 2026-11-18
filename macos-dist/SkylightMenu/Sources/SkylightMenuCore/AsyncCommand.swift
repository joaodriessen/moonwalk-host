import Foundation

/// Runs a bounded child away from UI actors, and reaps it before cancellation returns.
public enum AsyncCommand {
    public static func run(_ executable: URL, arguments: [String], timeout: TimeInterval = 30) async throws {
        let operation = CommandOperation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        try operation.run(executable, arguments: arguments, timeout: timeout)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { operation.cancel() }
    }
}

private final class CommandOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var cancelled = false

    func run(_ executable: URL, arguments: [String], timeout: TimeInterval) throws {
        lock.lock()
        guard !cancelled else { lock.unlock(); throw CancellationError() }
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() }
        catch { lock.unlock(); throw error }
        lock.unlock()
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            stop()
            exited.wait()
        }
        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        if timedOut { throw CommandError(message: "Diagnostics archiving timed out. Try saving to a local folder.") }
        guard process.terminationStatus == 0 else {
            throw CommandError(message: "Diagnostics could not be archived (exit \(process.terminationStatus)). Try a local folder with available space.")
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        stop()
    }

    private func stop() {
        lock.lock()
        if process.isRunning { process.terminate() }
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            lock.lock()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            lock.unlock()
        }
    }
}

private struct CommandError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}
