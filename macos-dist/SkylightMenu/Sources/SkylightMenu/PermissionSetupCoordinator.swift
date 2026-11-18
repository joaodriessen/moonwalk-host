import Observation
import SkylightMenuCore

@MainActor
@Observable
final class PermissionSetupCoordinator {
    private(set) var state = PermissionSetupState()
    private(set) var attemptedScreenRecording = false
    private(set) var attemptedAccessibility = false
    private(set) var requestingScreenRecording = false
    private(set) var requestingAccessibility = false
    private let restartVerification = RestartVerification()
    var awaitingReconnect: Bool { restartVerification.awaitingReconnect }
    var restartError: String? { restartVerification.error }

    private var refreshInFlight = false
    private var refreshPending = false
    private var restartQueued = false
    private let restartCommand: @MainActor (@escaping @MainActor (HostProcessActions.ActionResult) -> Void) -> Void

    init(restart: @escaping @MainActor (@escaping @MainActor (HostProcessActions.ActionResult) -> Void) -> Void = HostProcessActions.restartHost) {
        restartCommand = restart
    }

    var firstRunPermissionState: PermissionState {
        guard !state.verifyingRestart, !awaitingReconnect, restartError == nil else {
            return PermissionState()
        }
        return PermissionState(
            screenRecording: state.completionScreen,
            accessibility: state.completionAccessibility
        )
    }

    func requestScreenRecording(host: HostConnection) {
        attemptedScreenRecording = true
        requestingScreenRecording = true
        Task {
            _ = await host.requestScreenRecording()
            await refresh(host: host)
            requestingScreenRecording = false
        }
    }

    func requestAccessibility(host: HostConnection) {
        attemptedAccessibility = true
        requestingAccessibility = true
        Task {
            _ = await host.requestAccessibility()
            await refresh(host: host)
            requestingAccessibility = false
        }
    }

    func hostStatusChanged(from oldStatus: HostStatus, to newStatus: HostStatus, host: HostConnection) {
        if awaitingReconnect, newStatus != .connected {
            restartVerification.observedDisconnect()
            host.markPermissionsChecking()
        }
        guard newStatus == .connected else { return }
        Task {
            _ = await refresh(host: host)
        }
    }

    @discardableResult
    func refresh(host: HostConnection) async -> Bool {
        guard host.status == .connected else { return false }
        if refreshInFlight {
            refreshPending = true
            return false
        }
        refreshInFlight = true
        defer {
            refreshInFlight = false
            if refreshPending {
                refreshPending = false
                Task { _ = await self.refresh(host: host) }
            }
        }
        guard let snapshot = await host.fetchPermissionState() else { return false }
        for effect in state.reduce(event: .observed(
            screen: snapshot.state.screenRecording,
            accessibility: snapshot.state.accessibility
        )) {
            if effect == .restartHost { restartHost(host: host) }
        }
        if restartVerification.verify(generation: snapshot.generation) {
            _ = state.reduce(event: .hostRestarted)
        }
        return true
    }

    func retryRestart(host: HostConnection) {
        restartHost(host: host)
    }

    private func restartHost(host: HostConnection) {
        guard !awaitingReconnect, !restartQueued else { return }
        restartQueued = true
        HostProcessActions.restartAfterSaving(host.settings, restart: { [self] completed in
            restartQueued = false
            // The reconnect deadline measures the restart, not time spent draining saves.
            let attempt = restartVerification.begin(after: host.connectionGeneration) { [weak self] in
                _ = self?.state.reduce(event: .hostRestarted)
            }
            host.markPermissionsChecking()
            restartCommand { result in
                if !result.success {
                    let message = result.output.isEmpty ? "Moonwalk Host could not restart. Try again." : result.output
                    if self.restartVerification.commandFailed(message, attempt: attempt) {
                        _ = self.state.reduce(event: .hostRestarted)
                    }
                }
                completed(result)
            }
        }, completion: { _ in })
    }
}
