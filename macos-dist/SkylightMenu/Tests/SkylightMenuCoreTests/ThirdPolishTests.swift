import Foundation
import Testing
@testable import SkylightMenuCore

@Test func unchangedReturnPreservesOverrideAndIntentionalBlankClears() {
    #expect(SettingsStore.submittedDraft(nil) == nil)
    #expect(SettingsStore.submittedDraft("") == "")
    #expect(SettingsStore.submittedDraft("new value") == "new value")
}

@Test func correctingMiddlePINPreservesOtherPositions() {
    var entry = PINEntry()
    entry.replace(at: 0, with: "1234")
    entry.replace(at: 1, with: "")
    #expect(entry.slots == ["1", "", "3", "4"])
    #expect(entry.pin.isEmpty)
    entry.replace(at: 1, with: "9")
    #expect(entry.pin == "1934")
    entry.replace(at: 0, with: "")
    #expect(entry.slots == ["", "9", "3", "4"])
    entry.replace(at: 0, with: "8")
    #expect(entry.pin == "8934")
}

@Test func pinPasteAndNoncontiguousEntryAreSafe() {
    var entry = PINEntry()
    entry.replace(at: 3, with: "4")
    #expect(entry.pin.isEmpty)
    #expect(entry.slots == ["", "", "", "4"])
    entry.replace(at: 2, with: "1a2３34")
    #expect(entry.pin == "1234")
    entry.replace(at: 1, with: "abc")
    #expect(entry.pin.isEmpty)
}

@Test func missingDisplaySelectionSurvivesUnplugAndReplug() {
    let monitor = CaptureDisplay(id: "42", name: "Studio Display")
    #expect(CaptureDisplay.options([monitor], selected: "42").map(\.id) == ["", "42"])
    let unplugged = CaptureDisplay.options([], selected: "42")
    #expect(unplugged.last?.id == "42")
    #expect(unplugged.last?.name.contains("Unavailable") == true)
    #expect(CaptureDisplay.options([monitor], selected: "42").last?.name == "Studio Display")
}

@Test @MainActor func compositeCodecFailureRetriesWholePairAndProtectsSnapshot() async {
    let store = SettingsStore()
    store.applySnapshot(["hevc_mode": "2", "av1_mode": "1"], startedAt: 0)
    let revision = store.revision
    var attempts = 0
    let pair = ["hevc_mode": "0", "av1_mode": "2"]
    store.save(values: pair, operationKey: "video_codec", label: "Video codec", send: {
        attempts += 1
        return attempts == 1 ? "atomic write failed" : nil
    })
    #expect(!store.acceptsSnapshot(key: "hevc_mode", startedAt: store.revision))
    #expect(!store.acceptsSnapshot(key: "av1_mode", startedAt: store.revision))
    await store.waitForPendingSaves()
    #expect(store.values["hevc_mode"] == "2")
    #expect(store.values["av1_mode"] == "1")
    #expect(store.failures.count == 1)
    store.retry(key: "video_codec")
    await store.waitForPendingSaves()
    #expect(store.values == pair)
    #expect(store.failures.isEmpty)
    store.applySnapshot(["hevc_mode": "2", "av1_mode": "1"], startedAt: revision)
    #expect(store.values == pair)
    #expect(attempts == 2)
}

@Test func diagnosticTailPreservesRecentUTF8AndDoesNotRotateOversizedLog() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let marker = "🔥 recent error 🪟"
    let data = Data((String(repeating: "a", count: 9 * 1024 * 1024) + marker).utf8)
    try data.write(to: url)
    // Start two bytes inside the first four-byte emoji.
    let tail = try BoundedLog.utf8Tail(url, maximumBytes: marker.utf8.count - 2)
    #expect(tail == " recent error 🪟")
    #expect(tail.utf8.count <= marker.utf8.count - 2)
    #expect(try Data(contentsOf: url) == data)
    #expect(!FileManager.default.fileExists(atPath: url.path + ".1"))
}

@Test func silentCallbackHasRealDeadlineAndLateReplyLoses() async {
    let box = BoundedReply<String>()
    let start = ContinuousClock.now
    let result = await box.value(timeout: 0.02, fallback: "timeout") { _ in }
    #expect(result == "timeout")
    #expect(start.duration(to: .now) < .seconds(1))
    #expect(!box.resolve("late reply"))
}

@Test func callbackReplyWinsExactlyOnce() async {
    let box = BoundedReply<Int>()
    let result = await box.value(timeout: 0.1, fallback: -1) { reply in
        reply(7)
        reply(8)
    }
    #expect(result == 7)
    #expect(!box.resolve(9))
}

@Test func cancellationBeforeInstallationDoesNotSend() async {
    let box = BoundedReply<Int>()
    #expect(box.resolve(-1))
    let result = await box.value(timeout: 5, fallback: -1) { _ in
        Issue.record("cancelled operation must not send")
    }
    #expect(result == -1)
}

@Test func cancellingSilentChildMakesStructuredQuitBounded() async {
    let box = BoundedReply<Bool>()
    let start = ContinuousClock.now
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            _ = await box.value(timeout: 10, fallback: false) { _ in }
        }
        group.addTask { try? await Task.sleep(for: .milliseconds(20)) }
        await group.next()
        group.cancelAll()
    }
    #expect(start.duration(to: .now) < .seconds(1))
    #expect(!box.resolve(true))
}

@Test @MainActor func stalledSaveCannotBlockNextSaveOrRestartWait() async {
    let store = SettingsStore()
    store.save(key: "first", value: "1", label: "First", send: {
        await BoundedReply<String?>().value(timeout: 0.02, fallback: "Timed out") { _ in }
    })
    store.save(key: "second", value: "2", label: "Second", send: { nil })
    await store.waitForPendingSaves()
    #expect(store.failures["first"]?.message == "Timed out")
    #expect(store.values["second"] == "2")
    #expect(store.pending.isEmpty)
}

@Test @MainActor func encoderAndCodecRestartOnlyAfterAcknowledgementIncludingRetry() async {
    for key in ["encoder", "hevc_mode"] {
        let store = SettingsStore()
        let restart = RestartCoordinator()
        var attempts = 0
        store.save(key: key, value: "new", label: "Video", send: {
            attempts += 1
            return attempts == 1 ? "write failed" : nil
        }, completion: { success, _ in
            if success { restart.markPersistedChange(key: key) }
        })
        await store.waitForPendingSaves()
        #expect(!restart.pendingRestart)
        store.retry(key: key)
        await store.waitForPendingSaves()
        #expect(restart.pendingRestart)
        #expect(RestartCoordinator.requiresConfirmation(streaming: true))
    }
}
