import Foundation
import os

/// Lifecycle events and errors from the menu's connection to the host.
enum SkylightLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "Moonwalk Host"

    /// XPC connection lifecycle, proxy errors, and reply-payload decode failures.
    static let xpc = Logger(subsystem: subsystem, category: "xpc")
    /// App/daemon lifecycle milestones (connect, invalidate, launch-agent state).
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
}
