import Foundation

public struct DiagnosticsSnapshot: Sendable {
    public let facts: String
    public let settingNames: [String]
    public let log: URL
    public init(facts: String, settingNames: [String], log: URL) {
        self.facts = facts; self.settingNames = settingNames; self.log = log
    }
}

public enum DiagnosticsArchive {
    public typealias Archiver = @Sendable (URL, URL) async throws -> Void

    /// The snapshot contains no UI or live host objects. All file work runs off MainActor.
    public static func export(
        _ snapshot: DiagnosticsSnapshot, to destination: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        archive: @escaping Archiver = { source, output in
            try await AsyncCommand.run(URL(fileURLWithPath: "/usr/bin/ditto"),
                                       arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, output.path])
        }
    ) async throws -> URL {
        let worker = Task.detached(priority: .utility) {
            let files = FileManager.default
            let root = temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let folder = root.appendingPathComponent("Moonwalk Host Diagnostics")
            let compressed = root.appendingPathComponent("diagnostics.zip")
            let staged = destination.deletingLastPathComponent().appendingPathComponent(".Moonwalk-Host-Diagnostics-\(UUID().uuidString).zip")
            try Task.checkCancellation()
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? files.removeItem(at: root); try? files.removeItem(at: staged) }
            try snapshot.facts.write(to: folder.appendingPathComponent("system.txt"), atomically: true, encoding: .utf8)
            try snapshot.settingNames.sorted().joined(separator: "\n").write(
                to: folder.appendingPathComponent("setting-names.txt"), atomically: true, encoding: .utf8)
            if let text = try? BoundedLog.utf8Tail(snapshot.log) {
                try DiagnosticRedactor.redact(text).write(to: folder.appendingPathComponent("host-log.txt"), atomically: true, encoding: .utf8)
            }
            try manifest.write(to: folder.appendingPathComponent("MANIFEST.txt"), atomically: true, encoding: .utf8)
            try Task.checkCancellation()
            try await archive(folder, compressed)
            try Task.checkCancellation()
            // Copy to a unique sibling first. A failed/cancelled copy never replaces the chosen file.
            try files.copyItem(at: compressed, to: staged)
            try Task.checkCancellation()
            if files.fileExists(atPath: destination.path) {
                _ = try files.replaceItemAt(destination, withItemAt: staged)
            } else { try files.moveItem(at: staged, to: destination) }
            return destination
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    private static let manifest = """
    system.txt — app, OS, architecture, service, and permission state
    setting-names.txt — setting names only; no values
    host-log.txt — optional final 1 MiB of the host log, redacted

    No Keychain data, certificates, configuration values, screen contents, or unrelated system logs are collected.
    """
}
