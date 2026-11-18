import Testing
@testable import SkylightMenuCore

@MainActor
private final class SaveTransport {
    var sent: [String] = []
    var reply: CheckedContinuation<String?, Never>?
    var arrival: CheckedContinuation<Void, Never>?
    func send(_ value: String) async -> String? {
        sent.append(value)
        return await withCheckedContinuation { continuation in
            reply = continuation
            arrival?.resume()
            arrival = nil
        }
    }
    func waitForSend() async {
        if reply != nil { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func finish(_ error: String? = nil) { let current = reply; reply = nil; current?.resume(returning: error) }
}

@Test @MainActor func savesAreOrderedAndNewerIntentSurvivesOlderFailure() async {
    let store = SettingsStore()
    let transport = SaveTransport()
    store.save(key: "keyboard", value: "false", label: "Keyboard", send: { await transport.send("false") })
    await transport.waitForSend()
    store.save(key: "keyboard", value: "true", label: "Keyboard", send: { await transport.send("true") })
    #expect(transport.sent == ["false"])
    transport.finish("disk unavailable")
    await transport.waitForSend()
    #expect(transport.sent == ["false", "true"])
    #expect(store.failures.isEmpty)
    #expect(store.pending.contains("keyboard"))
    transport.finish()
    await store.waitForPendingSaves()
    #expect(store.values["keyboard"] == "true")
    #expect(store.pending.isEmpty)
}

@Test @MainActor func rejectedSavePreservesValueAndRetryPublishesAcknowledgement() async {
    let store = SettingsStore()
    store.applySnapshot(["output_name": "old"], startedAt: store.revision)
    var attempts = 0
    var completions: [Bool] = []
    store.save(key: "output_name", value: "", label: "Display", send: {
        attempts += 1
        return attempts == 1 ? "Could not write settings" : nil
    }, completion: { success, _ in completions.append(success) })
    await store.waitForPendingSaves()
    #expect(store.values["output_name"] == "old")
    #expect(store.failures["output_name"]?.label == "Display")
    store.retry(key: "output_name")
    await store.waitForPendingSaves()
    #expect(store.values["output_name"] == "")
    #expect(store.failures.isEmpty)
    #expect(completions == [false, true]) // Retry runs the original UI completion again.
}

@Test @MainActor func staleConfigurationReadCannotUndoAcknowledgedSave() async {
    let store = SettingsStore()
    let revision = store.revision
    store.save(key: "web_ui_enabled", value: "true", label: "Web page", send: { nil })
    await store.waitForPendingSaves()
    store.applySnapshot(["web_ui_enabled": "false", "port": "47989"], startedAt: revision)
    #expect(store.values["web_ui_enabled"] == "true")
    #expect(store.values["port"] == "47989")
    store.applySnapshot(["web_ui_enabled": "false"], startedAt: store.revision)
    #expect(store.values["web_ui_enabled"] == "false")
}

@Test @MainActor func staleReadDuringPendingSaveAndNewerDraftArePreserved() async {
    let store = SettingsStore()
    let transport = SaveTransport()
    store.applySnapshot(["sunshine_name": "Original"], startedAt: store.revision)
    store.save(key: "sunshine_name", value: "First edit", label: "Name", send: { await transport.send("First edit") })
    await transport.waitForSend()
    store.applySnapshot(["sunshine_name": "Original"], startedAt: store.revision)
    #expect(store.values["sunshine_name"] == "Original")
    #expect(!SettingsStore.shouldClearDraft(current: "Newer edit", submitted: "First edit"))
    #expect(SettingsStore.shouldClearDraft(current: "First edit", submitted: "First edit"))
    transport.finish()
    await store.waitForPendingSaves()
    #expect(store.values["sunshine_name"] == "First edit")
}
