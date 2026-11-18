import AppKit
import Foundation
import SkylightMenuCore

@MainActor
enum DiagnosticsExporter {
    static func chooseDestination() async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Moonwalk-Host-Diagnostics-\(timestamp()).zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                panel.begin { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            }
        } onCancel: {
            Task { @MainActor in panel.cancel(nil) }
        }
    }

    static func save(
        to destination: URL,
        settingNames: [String],
        session: RichStatus,
        service: FirstRunEnvironment.Service,
        permissions: PermissionState
    ) async throws -> URL {
        let facts = """
        Skylight \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
        menu-source \(Bundle.main.object(forInfoDictionaryKey: "SkylightSourceRevision") as? String ?? "unknown")
        host-version \(session.appVersion.isEmpty ? "unknown" : session.appVersion)
        host-source \(session.sourceRevision.isEmpty ? "unknown" : session.sourceRevision)
        streaming \(session.streaming)
        session \(session.width)x\(session.height) @ \(session.fps) fps, \(session.bitrateKbps) Kbps negotiated
        configured-encoder \(session.encoder)
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        architecture \(machineArchitecture())
        service \(String(describing: service))
        screen-recording \(permissionDescription(permissions.screenRecording))
        accessibility \(permissionDescription(permissions.accessibility))
        """
        let hostLog = SkylightDataPaths.configuration(home: FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("sunshine.log")
        return try await DiagnosticsArchive.export(
            DiagnosticsSnapshot(facts: facts, settingNames: settingNames, log: hostLog), to: destination)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func permissionDescription(_ state: PermissionGrantState) -> String {
        switch state {
        case .checking: "checking"
        case .required: "not-granted"
        case .granted: "granted"
        }
    }

    private static func machineArchitecture() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
