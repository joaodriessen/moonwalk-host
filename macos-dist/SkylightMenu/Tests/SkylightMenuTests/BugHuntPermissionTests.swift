import Testing
@testable import SkylightMenu
@testable import SkylightMenuCore

@MainActor private final class PermissionSaveGate {
    var waiting: CheckedContinuation<String?, Never>?
    func send() async -> String? { await withCheckedContinuation { waiting = $0 } }
    func release() { let reply = waiting; waiting = nil; reply?.resume(returning: nil) }
}

@Test @MainActor func permissionRestartWaitsForAcknowledgedSavesBeforeArmingReconnect() async {
    let host = HostConnection(connectImmediately: false)
    let gate = PermissionSaveGate()
    var commands = 0
    let coordinator = PermissionSetupCoordinator(restart: { reply in
        commands += 1
        reply(HostProcessActions.ActionResult(success: false, output: "Inert restart fixture"))
    })
    host.settings.save(key: "sunshine_name", value: "Kept", label: "Name", send: { await gate.send() })
    while gate.waiting == nil { await Task.yield() }
    coordinator.retryRestart(host: host)
    // This is the real coordinator with a real SettingsStore and an inert restart command.
    // A second click must not enqueue another restart while the save is suspended.
    coordinator.retryRestart(host: host)
    await Task.yield()
    #expect(commands == 0)
    #expect(!coordinator.awaitingReconnect)
    gate.release()
    await host.settings.waitForPendingSaves()
    for _ in 0..<100 where commands == 0 { await Task.yield() }
    #expect(commands == 1)
    #expect(host.settings.values["sunshine_name"] == "Kept")
    #expect(coordinator.restartError == "Inert restart fixture")
}
