import Foundation
import Testing
@testable import SkylightMenu
@testable import SkylightMenuCore

@MainActor private final class RepairSaveGate {
    var reply: CheckedContinuation<String?, Never>?
    func send() async -> String? { await withCheckedContinuation { reply = $0 } }
    func finish(_ error: String? = nil) { let current = reply; reply = nil; current?.resume(returning: error) }
}

@Test @MainActor func repairWaitsForSaveBeforeRegistrationAndRestart() async {
    let host = HostConnection(connectImmediately: false)
    let gate = RepairSaveGate()
    var preparations = 0, restarts = 0
    host.settings.save(key: "sunshine_name", value: "Kept", label: "Name", send: { await gate.send() })
    while gate.reply == nil { await Task.yield() }
    let repair = Task {
        await host.repairHostService(prepare: { preparations += 1; return nil }, restart: { reply in
            restarts += 1
            reply(HostProcessActions.ActionResult(success: false, output: "Inert restart fixture"))
        })
    }
    for _ in 0..<20 { await Task.yield() }
    let beforePrepare = preparations, beforeRestart = restarts
    gate.finish()
    await repair.value
    #expect(beforePrepare == 0)
    #expect(beforeRestart == 0)
    #expect(preparations == 1 && restarts == 1)
    #expect(host.settings.values["sunshine_name"] == "Kept")
    #expect(host.repairMessage == "Inert restart fixture")
}

@Test @MainActor func repairKeepsFailedSaveRecoverableWhileAllowingHostRecovery() async {
    let host = HostConnection(connectImmediately: false)
    var attempts = 0, preparations = 0, restarts = 0
    host.settings.save(key: "sunshine_name", value: "Kept", label: "Name", send: {
        attempts += 1
        return attempts == 1 ? "Disk unavailable" : nil
    })
    await host.settings.waitForPendingSaves()
    await host.repairHostService(prepare: { preparations += 1; return nil }, restart: { reply in
        restarts += 1; reply(HostProcessActions.ActionResult(success: false, output: "Inert restart fixture"))
    })
    #expect(preparations == 1 && restarts == 1)
    #expect(host.repairMessage?.contains("Retry") == true)
    #expect(host.settings.failures["sunshine_name"] != nil)
    host.settings.retry(key: "sunshine_name")
    await host.settings.waitForPendingSaves()
    await host.repairHostService(prepare: { preparations += 1; return nil }, restart: { reply in
        restarts += 1; reply(HostProcessActions.ActionResult(success: false, output: "Inert restart fixture"))
    })
    #expect(preparations == 2 && restarts == 2)
    #expect(host.settings.values["sunshine_name"] == "Kept")
}

@Test @MainActor func failedRevisionRefreshPreservesEditsAndRetryClearsVisibleError() async throws {
    let host = HostConnection(connectImmediately: false)
    host.settings.applyExternalSnapshot(["port": "47989"], running: ["port": "47989"], revision: "original", startedAt: 0)
    host.settings.drafts["port"] = "48000"
    var stateReads = 0
    await host.refreshExternalConfiguration(force: true, connected: { true }, readRevision: { nil }, readState: {
        stateReads += 1; return nil
    })
    #expect(host.externalRefreshError != nil)
    #expect(host.settings.fileRevision == "original")
    #expect(host.settings.drafts["port"] == "48000")
    #expect(stateReads == 0)
    let json = #"{"revision":"new","values":{"port":"48010"},"runningValues":{"port":"47989"},"snapshotKeys":["port"]}"#
    await host.refreshExternalConfiguration(force: true, connected: { true }, readRevision: { "new" }, readState: { json })
    #expect(host.externalRefreshError == nil)
    #expect(host.settings.fileRevision == "new")
    #expect(host.settings.conflicts["port"]?.local == "48000")
    #expect(host.settings.conflicts["port"]?.external == "48010")
}

@Test @MainActor func offlineRefreshReportsUnavailableWithoutReadingOrDiscardingDrafts() async {
    let host = HostConnection(connectImmediately: false)
    host.settings.drafts["sunshine_name"] = "Still typing"
    var reads = 0
    await host.refreshExternalConfiguration(force: true, connected: { false }, readRevision: { reads += 1; return nil }, readState: { reads += 1; return nil })
    #expect(host.externalRefreshError != nil)
    #expect(reads == 0)
    #expect(host.settings.drafts["sunshine_name"] == "Still typing")
}

@Test @MainActor func automaticRefreshRetriesStateAfterFailureWithUnchangedFingerprint() async {
    let host = HostConnection(connectImmediately: false)
    let json = #"{"revision":"same","values":{"port":"47989"},"runningValues":{"port":"47989"},"snapshotKeys":["port"]}"#
    await host.refreshExternalConfiguration(force: true, connected: { true }, readRevision: { "same" }, readState: { json })
    await host.refreshExternalConfiguration(force: true, connected: { true }, readRevision: { "same" }, readState: { nil })
    #expect(host.externalRefreshError != nil)
    var retryReads = 0
    await host.refreshExternalConfiguration(force: false, connected: { true }, readRevision: { "same" }, readState: {
        retryReads += 1; return json
    })
    #expect(retryReads == 1)
    #expect(host.externalRefreshError == nil)
}
