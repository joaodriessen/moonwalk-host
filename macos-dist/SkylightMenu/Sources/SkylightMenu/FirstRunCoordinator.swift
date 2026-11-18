import AppKit
import Foundation
import Observation
import SkylightMenuCore

@MainActor
@Observable
final class FirstRunCoordinator {
    private(set) var state = FirstRunState()
    private let service: HostServiceManaging
    private let files: FileManager
    private let defaults: UserDefaults
    private static let completionKey = "skylight.firstRunComplete"
    private(set) var isComplete: Bool

    init(
        service: HostServiceManaging = HostServiceManager(),
        files: FileManager = .default,
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.files = files
        self.defaults = defaults
        self.isComplete = defaults.bool(forKey: Self.completionKey)
    }

    var shouldPresent: Bool {
        !isComplete
    }

    func refresh(permissionState: PermissionState, hostAvailability: FirstRunEnvironment.HostAvailability) {
        // I4/M6: refresh() is the chokepoint every *silent* re-seed pass runs through --
        // `MenuContent.onAppear` calls it unconditionally on every menu open, with no user
        // action involved. If this process has just performed an uninstall
        // (`UninstallCoordinator.removeService`), that uninstall must not be silently undone by
        // this process's own first-run convergence the next time the menu happens to open --
        // e.g. re-registering the service `removeService` just unregistered. Explicit user
        // actions taken from the status pane (Remove Background Service, Delete Skylight Data,
        // Restart Skylight, etc.) remain available regardless; only this coordinator's
        // autonomous convergence is suppressed. (`perform()` is guarded too, below, since
        // `retry()` also routes through it and can independently replay `.registerService`.)
        guard !UninstallCoordinator.didRemoveService else { return }
        let environment = FirstRunEnvironment(
            installedInApplications: InstallationLocation.isInstalled(Bundle.main.bundleURL, home: files.homeDirectoryForCurrentUser),
            configExists: files.fileExists(atPath: configDirectory.appendingPathComponent("sunshine.conf").path),
            service: service.status,
            hostAvailability: hostAvailability,
            screenRecording: permissionState.screenRecording,
            accessibility: permissionState.accessibility
        )
        perform(state.reduce(event: .observed(environment)), permissionState: permissionState, hostAvailability: hostAvailability)
        if state.phase == .readyToPair, isComplete {
            _ = state.reduce(event: .finish)
        }
    }

    func retry(permissionState: PermissionState, hostAvailability: FirstRunEnvironment.HostAvailability) {
        perform(state.reduce(event: .retry), permissionState: permissionState, hostAvailability: hostAvailability)
    }

    func finish() {
        perform(state.reduce(event: .finish), permissionState: .init(), hostAvailability: .connected)
    }

    func openApplications() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
    }

    func openApprovalSettings() { service.openApprovalSettings() }

    private var configDirectory: URL {
        SkylightDataPaths.configuration(home: files.homeDirectoryForCurrentUser)
    }

    private func perform(_ effects: [FirstRunState.Effect], permissionState: PermissionState, hostAvailability: FirstRunEnvironment.HostAvailability) {
        // I4/M6: `refresh()` above guards the silent `.onAppear` path, but `perform()` is not
        // reached only through `refresh()` -- `retry()` and `finish()` call it directly, and
        // `retry()` in particular can replay a `.registerService` effect from `FirstRunState`'s
        // `retryEffects` on its own (`FirstRunState.reduce(.retry)`), independent of `refresh()`.
        // Guarding here too closes that path without duplicating the guard in every caller.
        guard !UninstallCoordinator.didRemoveService else { return }
        for effect in effects {
            do {
                switch effect {
                case .offerMoveToApplications:
                    break
                case .createDefaultConfiguration:
                    try createDefaultConfiguration()
                    refresh(permissionState: permissionState, hostAvailability: hostAvailability)
                case .registerService:
                    try service.register()
                    refresh(permissionState: permissionState, hostAvailability: hostAvailability)
                case .persistCompletion:
                    defaults.set(true, forKey: Self.completionKey)
                    isComplete = true
                }
            } catch {
                _ = state.reduce(event: .operationFailed(error.localizedDescription))
            }
        }
    }

    private func createDefaultConfiguration() throws {
        guard let resources = Bundle.main.resourceURL else { throw CocoaError(.fileNoSuchFile) }
        try SkylightDataPaths.prepare(
            home: files.homeDirectoryForCurrentUser,
            legacyInstallation: SkylightDataPaths.isLegacyInstallation(defaults: defaults),
            defaultsDirectory: resources.appendingPathComponent("Defaults"), files: files
        )
    }
}
