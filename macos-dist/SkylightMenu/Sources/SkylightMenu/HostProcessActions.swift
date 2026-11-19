import Foundation
import SkylightMenuCore

/// Restart and recovery run in the menu user's service session, since a
/// restart would interrupt a reply from the daemon itself.
enum HostProcessActions {
    struct ActionResult: Sendable {
        let success: Bool
        /// Trimmed combined stdout+stderr tail, or a Swift-side error description. Always
        /// human-readable; empty only if the process produced no output.
        let output: String
    }

    /// Both restart and display recovery wait for acknowledged saves before replacing XPC.
    @MainActor @discardableResult
    static func restartAfterSaving(
        _ settings: SettingsStore,
        restart: @escaping @MainActor (@escaping @MainActor (ActionResult) -> Void) -> Void = restartHost,
        completion: @escaping @MainActor (ActionResult) -> Void
    ) -> Task<Void, Never> {
        Task {
            await settings.waitForPendingSaves()
            restart(completion)
        }
    }

    /// Ask launchd to replace the running daemon using its configured service label.
    @MainActor
    static func restartHost(completion: @escaping @MainActor (ActionResult) -> Void) {
        let label = (GeneratedIdentity.launchAgentPlistName as NSString).deletingPathExtension
        run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"], timeout: 10, completion: completion)
    }

    /// Performs the same `launchctl kickstart -k` as `restartHost` above. `macos-dist/skylight-rescue.sh`
    /// is separate, manual dev-machine tooling -- this action does not shell out to it.
    @MainActor
    static func runRescue(completion: @escaping @MainActor (ActionResult) -> Void) {
        let label = (GeneratedIdentity.launchAgentPlistName as NSString).deletingPathExtension
        run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"], completion: completion)
    }

    /// Accumulates pipe output from the `readabilityHandler`'s background-queue callback while
    /// the run loop below reads it back out after exit. `@unchecked Sendable` + `NSLock` since
    /// the two sides run on different queues concurrently -- same pattern as
    /// `HostConnection.ResumeOnce`.
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }
        var snapshot: Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    /// Shells a single executable out on a background queue and reports the result back on the
    /// main queue. Internal (not `private`) so other callers can reuse the exact same
    /// run-a-script-and-report pattern rather than duplicating it -- one process-running helper
    /// for the whole app, not a parallel copy.
    ///
    /// `completion` is `@MainActor`-isolated (not `@Sendable`) on purpose: every caller today is a
    /// `@MainActor` view/manager that mutates `@State`/`@Observable` state directly inside the
    /// callback (ContentView, SettingsView). Marking the parameter `@Sendable`
    /// instead would force every call site to become thread-safe/non-isolated, which is a much
    /// bigger, unscoped change -- this narrower fix satisfies strict concurrency at the actual
    /// crossing point (this function hopping off the MainActor to a background queue) without
    /// touching any caller.
    ///
    /// `timeout` defaults generously (5 min): `runRescue`/`restartHost` finish in well under a
    /// second, but some scripts can legitimately take a while -- the deadline only needs to catch
    /// a genuinely wedged script (network hang, blocked prompt despite `--yes`), not a
    /// slow-but-progressing one.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 300, completion: @escaping @MainActor (ActionResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: executable)
            task.arguments = arguments
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe

            // Drain the pipe continuously via a readability handler instead of blocking on
            // `readDataToEndOfFile()` up front: a timeout has to be enforceable independent of
            // whether/when the child produces output, and a single blocking read can't be raced
            // against a deadline. This still avoids the 64 KiB pipe-buffer deadlock the old
            // blocking-read-then-wait ordering existed to prevent -- draining now happens as
            // data arrives rather than only after exit.
            let collected = OutputBox()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                collected.append(chunk)
            }

            let exited = DispatchSemaphore(value: 0)
            task.terminationHandler = { _ in exited.signal() }

            let result: ActionResult
            do {
                try task.run()

                // Time out stalled child processes, allow a short graceful
                // exit, and reap the child after escalating if necessary.
                var timedOut = false
                if exited.wait(timeout: .now() + timeout) == .timedOut {
                    timedOut = true
                    SkylightLog.lifecycle.error("\(executable, privacy: .public) exceeded \(Int(timeout))s timeout -- sending SIGTERM")
                    task.terminate()
                    if exited.wait(timeout: .now() + 1.0) == .timedOut {
                        SkylightLog.lifecycle.error("\(executable, privacy: .public) ignored SIGTERM -- sending SIGKILL")
                        kill(task.processIdentifier, SIGKILL)
                        exited.wait()
                    }
                }

                pipe.fileHandleForReading.readabilityHandler = nil
                let data = collected.snapshot
                let output = (String(data: data, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if timedOut {
                    result = ActionResult(
                        success: false,
                        output: "Timed out after \(Int(timeout))s and was terminated. Partial output: \(output)"
                    )
                } else {
                    result = ActionResult(success: task.terminationStatus == 0, output: output)
                }
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                result = ActionResult(success: false, output: error.localizedDescription)
            }

            Task { @MainActor in completion(result) }
        }
    }
}
