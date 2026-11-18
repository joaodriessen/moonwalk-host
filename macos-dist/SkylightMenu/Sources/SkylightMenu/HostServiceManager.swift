import Foundation
import ServiceManagement
import SkylightMenuCore

@MainActor
protocol HostServiceManaging {
    var status: FirstRunEnvironment.Service { get }
    func register() throws
    func unregister() throws
    func openApprovalSettings()
}

@MainActor
final class HostServiceManager: HostServiceManaging {
    private static let registeredExecutablePathKey = "skylight.registeredHostExecutablePath"
    private static let registrationMigrationPendingKey = "skylight.hostRegistrationMigrationPending"
    private var service: SMAppService { .agent(plistName: GeneratedIdentity.launchAgentPlistName) }

    var status: FirstRunEnvironment.Service {
        switch service.status {
        case .enabled: .registered
        case .requiresApproval: .requiresApproval
        case .notFound, .notRegistered: .notRegistered
        @unknown default: .notRegistered
        }
    }

    func register() throws {
        try service.register()
        recordSuccessfulRegistration()
    }

    func refreshRegistrationIfExecutableChanged(defaults: UserDefaults = .standard) throws {
        let registered = service.status != .notRegistered && service.status != .notFound
        let migrationPending = defaults.bool(forKey: Self.registrationMigrationPendingKey)
        let shouldRefresh = ServiceRegistrationMigration.shouldRefresh(
            registered: registered,
            recordedPath: defaults.string(forKey: Self.registeredExecutablePathKey),
            currentPath: GeneratedIdentity.hostExecutableRelativePath,
            migrationPending: migrationPending
        )
        guard shouldRefresh else { return }

        // Persist intent before the destructive half of migration. If unregister succeeds but
        // registration fails, the next launch retries registration even when this upgrade is
        // the first version to introduce the recorded-path key.
        defaults.set(true, forKey: Self.registrationMigrationPendingKey)
        let refreshed = try ServiceRegistrationMigration.refreshIfNeeded(
            registered: registered,
            recordedPath: defaults.string(forKey: Self.registeredExecutablePathKey),
            currentPath: GeneratedIdentity.hostExecutableRelativePath,
            migrationPending: migrationPending,
            unregister: { try unregister() },
            // Bookkeeping is committed after the whole migration below, so a failure at any
            // point leaves the pending marker intact for the next launch.
            register: { try service.register() }
        )
        guard refreshed else { return }
        recordSuccessfulRegistration(defaults: defaults)
    }

    func unregister() throws {
        guard service.status != .notRegistered else { return }
        try service.unregister()
    }

    private func recordSuccessfulRegistration(defaults: UserDefaults = .standard) {
        defaults.set(GeneratedIdentity.hostExecutableRelativePath, forKey: Self.registeredExecutablePathKey)
        defaults.removeObject(forKey: Self.registrationMigrationPendingKey)
    }

    func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }
}
