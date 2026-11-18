import Foundation
import Testing
@testable import SkylightMenuCore

@Test @MainActor func externalRefreshPreservesDraftAndReportsRealConflict() {
    let store = SettingsStore()
    store.applyExternalSnapshot(["encoder": "videotoolbox", "port": "47989"], running: ["port": "47989"], revision: "one", startedAt: 0)
    store.drafts["port"] = "48000"
    store.applyExternalSnapshot(["encoder": "software", "port": "48010"], running: ["port": "47989"], revision: "two", startedAt: store.revision)
    #expect(store.values["encoder"] == "software")
    #expect(store.drafts["port"] == "48000")
    #expect(store.conflicts["port"]?.external == "48010")
    #expect(store.restartKeys.contains("port"))
    store.useExternalValue(for: "port")
    #expect(store.drafts["port"] == nil)
    #expect(store.values["port"] == "48010")
    #expect(store.conflicts.isEmpty)
}

@Test @MainActor func staleExternalReadCannotOverwriteNewerAcknowledgedSave() async {
    let store = SettingsStore()
    store.applyExternalSnapshot(["encoder": "videotoolbox"], running: [:], revision: "one", startedAt: 0)
    let before = store.revision
    store.save(key: "encoder", value: "software", label: "Encoder", send: { nil })
    await store.waitForPendingSaves()
    store.applyExternalSnapshot(["encoder": "videotoolbox"], running: [:], revision: "two", startedAt: before)
    #expect(store.values["encoder"] == "software")
}

@Test func snapshotRoundTripAndDiffKeepAbsentKeysDistinctFromEmpty() throws {
    let snapshot = ConfigurationSnapshot(name: "Known good", values: ["encoder": "software", "output_name": ""])
    let copy = try JSONDecoder().decode(ConfigurationSnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(copy == snapshot)
    let changes = snapshot.changes(from: ["encoder": "videotoolbox", "port": "48000"], keys: ["encoder", "port", "output_name"])
    #expect(changes.map(\.key) == ["encoder", "output_name", "port"])
    #expect(changes.first(where: { $0.key == "port" })?.after == nil)
    #expect(changes.first(where: { $0.key == "output_name" })?.after == "")
}

@Test func snapshotFilesAreAtomicAndIsolatedFromDeviceData() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshots = ConfigurationSnapshots(directory: directory)
    let value = ConfigurationSnapshot(name: "Work", values: ["encoder": "software"])
    try snapshots.save(value)
    #expect(try snapshots.load() == [value])
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [value.id + ".json"])
    let malformed = directory.appendingPathComponent("bad.json")
    try Data("not a snapshot".utf8).write(to: malformed)
    #expect(try snapshots.load() == [value])
}

@Test func connectionHandoffUsesEffectivePortAndBracketsIPv6() {
    #expect(ConnectionAddress(interface: "en0", address: "192.0.2.1").hostValue(port: 47989) == "192.0.2.1")
    #expect(ConnectionAddress(interface: "utun1", address: "fd00::1").hostValue(port: 48000) == "[fd00::1]:48000")
}

@Test func snapshotSaveRejectsLinkedStorageWithoutWritingThroughIt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("unrelated")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let link = root.appendingPathComponent("settings-snapshots")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(throws: Error.self) { try ConfigurationSnapshots(directory: link).save(ConfigurationSnapshot(name: "Work", values: [:])) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
}
