import Testing
@testable import SkylightMenuCore

@MainActor private final class PendingSaveGate {
    var reply: CheckedContinuation<String?, Never>?
    func send() async -> String? { await withCheckedContinuation { reply = $0 } }
    func finish(_ error: String? = nil) { let current = reply; reply = nil; current?.resume(returning: error) }
}

@Test @MainActor func compoundCompletionKeepsLaterSingleKeyWriteProtectedFromRefresh() async {
    let store = SettingsStore()
    let first = PendingSaveGate(), second = PendingSaveGate()
    store.save(values: ["hevc_mode": "0", "av1_mode": "0"], operationKey: "video_codec", label: "Codec", send: { await first.send() })
    while first.reply == nil { await Task.yield() }
    store.save(key: "hevc_mode", value: "3", label: "HEVC", send: { await second.send() })
    first.finish()
    while second.reply == nil { await Task.yield() }
    let protected = store.pending.contains("hevc_mode")
    store.applyExternalSnapshot(["hevc_mode": "1", "av1_mode": "0"], running: [:], revision: "outside", startedAt: store.revision)
    let observed = store.values["hevc_mode"]
    second.finish()
    await store.waitForPendingSaves()
    #expect(protected)
    #expect(observed == "0") // First acknowledged result remains until the second write replies.
    #expect(store.values["hevc_mode"] == "3")
    #expect(store.pending.isEmpty)
}

@Test @MainActor func singleKeyCompletionKeepsLaterCompoundWriteProtectedFromRefresh() async {
    let store = SettingsStore()
    let first = PendingSaveGate(), second = PendingSaveGate()
    store.save(key: "hevc_mode", value: "3", label: "HEVC", send: { await first.send() })
    while first.reply == nil { await Task.yield() }
    store.save(values: ["hevc_mode": "0", "av1_mode": "0"], operationKey: "video_codec", label: "Codec", send: { await second.send() })
    first.finish("Temporary write failure")
    while second.reply == nil { await Task.yield() }
    let protected = store.pending.contains("hevc_mode")
    second.finish()
    await store.waitForPendingSaves()
    #expect(protected)
    #expect(store.values["hevc_mode"] == "0")
    #expect(store.pending.isEmpty)
}
