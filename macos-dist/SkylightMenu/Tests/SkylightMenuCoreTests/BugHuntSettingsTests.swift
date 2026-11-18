import Testing
@testable import SkylightMenuCore

@Test @MainActor func convergedOutsideValueRemovesObsoleteConflictWithoutDiscardingDraft() {
    let store = SettingsStore()
    store.applyExternalSnapshot(["port": "47989"], running: [:], revision: "one", startedAt: 0)
    store.drafts["port"] = "48000"
    store.applyExternalSnapshot(["port": "48010"], running: [:], revision: "two", startedAt: store.revision)
    #expect(store.conflicts["port"]?.external == "48010")
    store.applyExternalSnapshot(["port": "48000"], running: [:], revision: "three", startedAt: store.revision)
    #expect(store.conflicts["port"] == nil)
    #expect(store.drafts["port"] == "48000")
}

@Test @MainActor func existingConflictReflectsNewDraftEvenWhenOutsideValueIsUnchanged() {
    let store = SettingsStore()
    store.applyExternalSnapshot(["port": "47989"], running: [:], revision: "one", startedAt: 0)
    store.drafts["port"] = "48000"
    store.applyExternalSnapshot(["port": "48010"], running: [:], revision: "two", startedAt: store.revision)
    store.drafts["port"] = "48020"
    store.applyExternalSnapshot(["port": "48010"], running: [:], revision: "two", startedAt: store.revision)
    #expect(store.conflicts["port"]?.local == "48020")
    #expect(store.conflicts["port"]?.external == "48010")
}

@Test @MainActor func restoredLiveSettingsRemainPendingUntilActualRuntimeMatches() {
    let store = SettingsStore()
    let desired = ["virtual_display": "disabled", "quit_app_on_disconnect": "enabled", "minimum_fps_target": "30"]
    let running = ["virtual_display": "enabled", "quit_app_on_disconnect": "disabled", "minimum_fps_target": "0"]
    store.applyExternalSnapshot(desired, running: running, revision: "restored", startedAt: 0)
    #expect(store.restartKeys == Set(desired.keys))
    #expect(store.values == desired)
    store.applyExternalSnapshot(desired, running: desired, revision: "restored", startedAt: store.revision)
    #expect(store.restartKeys.isEmpty)
}

@Test @MainActor func liveRuntimeComparisonUsesCompiledDefaultsAndEquivalentScalarValues() {
    let store = SettingsStore()
    store.applyExternalSnapshot([:], running: ["virtual_display": "enabled", "quit_app_on_disconnect": "disabled", "minimum_fps_target": "0.000000"], revision: "defaults", startedAt: 0)
    #expect(store.restartKeys.isEmpty)
    store.applyExternalSnapshot(["virtual_display": "enabled", "quit_app_on_disconnect": "yes", "minimum_fps_target": "30.0"], running: ["virtual_display": "enabled", "quit_app_on_disconnect": "enabled", "minimum_fps_target": "30.000000"], revision: "equivalent", startedAt: store.revision)
    #expect(store.restartKeys.isEmpty)
}

@Test @MainActor func conflictSelectionCannotBorrowRevisionFromANewerOutsideValue() {
    let store = SettingsStore()
    store.applyExternalSnapshot(["port": "47989"], running: [:], revision: "one", startedAt: 0)
    store.drafts["port"] = "48000"
    store.applyExternalSnapshot(["port": "48010"], running: [:], revision: "two", startedAt: store.revision)
    let selected = store.conflicts["port"]!
    #expect(store.canResolve(selected, originalDraft: "48000"))
    store.applyExternalSnapshot(["port": "48020"], running: [:], revision: "three", startedAt: store.revision)
    #expect(store.fileRevision == "three")
    #expect(!store.canResolve(selected, originalDraft: "48000"))
    let refreshed = store.conflicts["port"]!
    store.drafts["port"] = "48030"
    #expect(!store.canResolve(refreshed, originalDraft: "48000"))
}

@Test @MainActor func staleExternalReadCannotCreateConflictOrChangeItsResolutionRevision() async {
    let store = SettingsStore()
    store.applyExternalSnapshot(["port": "47989"], running: [:], revision: "one", startedAt: 0)
    let startedAt = store.revision
    store.save(key: "port", value: "48000", label: "Port", send: { nil })
    await store.waitForPendingSaves()
    store.drafts["port"] = "48030"
    store.applyExternalSnapshot(["port": "48020"], running: [:], revision: "stale", startedAt: startedAt)
    #expect(store.conflicts.isEmpty)
    #expect(store.fileRevision == "one")
    #expect(store.values["port"] == "48000")
}
