import os

/// Native refactor Wave 2: os.Logger surfaces for silent failure paths that previously discarded
/// their errors entirely (XPC decode failures, swallowed proxy errors, launchctl shell-out
/// failures). Deliberately sparse -- only real error/fault paths plus a couple of `.info`
/// lifecycle milestones (connect/invalidate), not a chatty per-call trace.
enum SkylightLog {
    private static let subsystem = "com.example.skylight.menu"

    /// XPC connection lifecycle, proxy errors, and reply-payload decode failures.
    static let xpc = Logger(subsystem: subsystem, category: "xpc")
    /// App/daemon lifecycle milestones (connect, invalidate, launch-agent state).
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    /// UI-level failures surfaced to the user (currently unused; reserved for Wave 2+ UI errors).
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
