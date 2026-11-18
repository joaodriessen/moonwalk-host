import Foundation
import SkylightMenuCore

/// Shared by the actual repair button and inert native tests. No uninstall or reset
/// operation is part of repair, even when registration fails halfway through.
@MainActor enum HostRepairPreparation {
    static func prepare(installed: Bool, executablePresent: Bool, service: HostServiceManaging,
                        refreshRegistered: () throws -> Void) throws -> String? {
        guard installed else { return "Open the installed copy of Moonwalk Host in Applications, then repair the host." }
        guard executablePresent else { return "The bundled streaming host is missing or is not executable. Install a complete copy of Moonwalk Host to repair it. Your settings and devices are kept." }
        switch service.status {
        case .requiresApproval:
            service.openApprovalSettings()
            return "Allow Moonwalk Host in Login Items, then try again."
        case .notRegistered: try service.register()
        case .registered: try refreshRegistered()
        }
        return nil
    }
}
