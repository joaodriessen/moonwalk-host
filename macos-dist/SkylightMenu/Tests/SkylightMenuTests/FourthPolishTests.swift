import Foundation
import Testing
@testable import SkylightMenu
@testable import SkylightMenuCore

@Test func acceptsBothApplicationsLocationsWithoutPrefixConfusion() {
    let home = URL(fileURLWithPath: "/Users/tester")
    #expect(InstallationLocation.isInstalled(URL(fileURLWithPath: "/Applications/Skylight.app"), home: home))
    #expect(InstallationLocation.isInstalled(home.appendingPathComponent("Applications/Skylight.app"), home: home))
    #expect(!InstallationLocation.isInstalled(home.appendingPathComponent("Applications-backup/Skylight.app"), home: home))
    #expect(!InstallationLocation.isInstalled(home.appendingPathComponent("Downloads/Skylight.app"), home: home))
    #expect(!InstallationLocation.isInstalled(URL(fileURLWithPath: "/Applications/../Downloads/Skylight.app"), home: home))
}

@MainActor private final class PairingHostFixture: PairingHost {
    var clients = [PairedClient(name: "Existing", uuid: "existing")]
    var outcomes: [HostConnection.PairOutcomeReply] = []
    var listReads = 0
    var outcomeTargets: [String] = []
    func beginPairingWindow() {}
    func fetchPendingPairings(completion: @escaping ([PendingPairing]?) -> Void) {
        completion([PendingPairing(uniqueid: "target", sourceIp: "192.0.2.1", ageSec: 0)])
    }
    func fetchPairedClients() {}
    func fetchPairedClientsList(completion: @escaping ([PairedClient]?) -> Void) { listReads += 1; completion(clients) }
    func fetchPairOutcome(forUniqueid target: String, completion: @escaping (HostConnection.PairOutcomeReply) -> Void) {
        outcomeTargets.append(target)
        completion(outcomes.isEmpty ? .waiting : outcomes.removeFirst())
    }
    func pair(pin: String, name: String, target: String, completion: @escaping (Bool, String) -> Void) { completion(true, "accepted") }
}

@MainActor private func verifyingModel(_ host: PairingHostFixture) -> PairingModel {
    let model = PairingModel(host: host)
    model.send(.sheetOpened)
    model.send(.deviceSelected("target"))
    model.send(.pinChanged("1234"))
    model.send(.deviceNameChanged("Intended device"))
    model.send(.submitRequested)
    return model
}

@Test @MainActor func unrelatedPairedListGrowthCannotConfirmSelectedDevice() {
    let host = PairingHostFixture()
    let model = verifyingModel(host)
    defer { model.send(.denyRequested) }
    host.clients.append(PairedClient(name: "Another device", uuid: "unrelated"))
    model.checkOutcome(generation: model.state.generation, target: "target", baseline: ["existing"], deadline: .distantFuture)
    guard case .verifying = model.state.step else { Issue.record("Unrelated growth confirmed the selected device"); return }
    #expect(host.listReads == 1) // Only the pre-submit availability snapshot.
    host.outcomes = [.complete(false)]
    model.checkOutcome(generation: model.state.generation, target: "target", baseline: ["existing"], deadline: .distantFuture)
    #expect(model.state.step == .picking(.didntPair))
    #expect(host.outcomeTargets.allSatisfy { $0 == "target" })
}

@Test @MainActor func targetSuccessWorksWithoutListGrowthAndFinalPollUsesTarget() {
    let host = PairingHostFixture()
    let model = verifyingModel(host)
    defer { model.send(.denyRequested) }
    host.outcomes = [.waiting, .complete(true)]
    model.checkOutcome(generation: model.state.generation, target: "target", baseline: ["existing"], deadline: .distantPast)
    #expect(model.state.step == .paired)
    #expect(host.listReads == 1)
}

@Test @MainActor func targetWaitingExpiresWithoutTreatingGrowthAsSuccess() {
    let host = PairingHostFixture()
    let model = verifyingModel(host)
    defer { model.send(.denyRequested) }
    host.clients.append(PairedClient(name: "Another", uuid: "new"))
    model.checkOutcome(generation: model.state.generation, target: "target", baseline: ["existing"], deadline: .distantPast)
    #expect(model.state.step == .picking(.verificationExpired))
}

private struct RemovalTestError: Error {}

@Test @MainActor func removalRetiresLoginBeforeHostAndPreservesDataOnPartialFailure() throws {
    var operations: [String] = []
    try RemovalTransaction.run(removeLogin: { operations.append("login") },
                               removeHost: { operations.append("host") },
                               removeData: { operations.append("data") })
    #expect(operations == ["login", "host", "data"])
    for failed in ["login", "host", "data"] {
        operations = []
        do {
            try RemovalTransaction.run(removeLogin: {
                operations.append("login"); if failed == "login" { throw RemovalTestError() }
            }, removeHost: {
                operations.append("host"); if failed == "host" { throw RemovalTestError() }
            }, removeData: {
                operations.append("data"); if failed == "data" { throw RemovalTestError() }
            })
            Issue.record("Expected a partial-removal failure")
        } catch {
            #expect(error.localizedDescription.contains(failed == "data" ? "some data" : "data was kept") ||
                    (failed == "login" && error.localizedDescription.contains("data were kept")))
        }
        #expect(operations == (failed == "login" ? ["login"] : failed == "host" ? ["login", "host"] : ["login", "host", "data"]))
    }
}

@Test @MainActor func activeAndUnknownQuitCanCancelWhileIdleQuitsImmediately() {
    let quit = QuitConfirmation()
    var shutdowns = 0
    quit.request(streaming: true, stateKnown: true) { shutdowns += 1 }
    #expect(quit.isPresented && shutdowns == 0)
    quit.cancel()
    quit.confirm()
    #expect(shutdowns == 0)
    quit.request(streaming: false, stateKnown: false) { shutdowns += 1 }
    #expect(quit.isPresented && shutdowns == 0)
    quit.confirm()
    quit.confirm()
    #expect(shutdowns == 1)
    quit.request(streaming: false, stateKnown: true) { shutdowns += 1 }
    #expect(!quit.isPresented && shutdowns == 2)
}

@Test @MainActor func permissionRestartWithoutReconnectEndsInRetryableError() async {
    let restart = RestartVerification()
    let expired = BoundedReply<Bool>()
    restart.begin(after: 7, timeout: .milliseconds(20)) { expired.resolve(true) }
    #expect(await expired.value(timeout: 1, fallback: false) { _ in })
    #expect(!restart.awaitingReconnect)
    #expect(restart.error?.contains("did not reconnect") == true)
}

@Test @MainActor func permissionRestartRejectsOldGenerationsCallbacksAndCancelledDeadlines() async {
    let restart = RestartVerification()
    let unwanted = BoundedReply<Bool>()
    let old = restart.begin(after: 7, timeout: .milliseconds(20)) { unwanted.resolve(true) }
    restart.cancel()
    restart.begin(after: 8, timeout: .milliseconds(30)) { unwanted.resolve(true) }
    #expect(!restart.commandFailed("old command failure", attempt: old))
    restart.observedDisconnect()
    #expect(!restart.verify(generation: 8))
    #expect(restart.verify(generation: 9))
    #expect(!restart.awaitingReconnect && restart.error == nil)
    #expect(!(await unwanted.value(timeout: 0.08, fallback: false) { _ in }))
}

@Test @MainActor func displayRecoveryRestartWaitsForSaveAcknowledgement() async {
    let store = SettingsStore()
    let saveGate = BoundedReply<Bool>()
    let started = BoundedReply<Bool>()
    var order: [String] = []
    store.save(key: "encoder", value: "software", label: "Video engine", send: {
        started.resolve(true)
        _ = await saveGate.value(timeout: 2, fallback: false) { _ in }
        order.append("save")
        return nil
    })
    #expect(await started.value(timeout: 1, fallback: false) { _ in })
    let task = HostProcessActions.restartAfterSaving(store, restart: { completion in
        order.append("restart")
        completion(.init(success: true, output: ""))
    }, completion: { result in #expect(result.success) })
    await Task.yield()
    #expect(order.isEmpty)
    saveGate.resolve(true)
    await task.value
    #expect(order == ["save", "restart"])
}

private func archiveFixture() throws -> (root: URL, snapshot: DiagnosticsSnapshot, destination: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let log = root.appendingPathComponent("private.log")
    try "A recoverable error\n".write(to: log, atomically: true, encoding: .utf8)
    return (root, DiagnosticsSnapshot(facts: "private test snapshot", settingNames: ["encoder"], log: log), root.appendingPathComponent("result.zip"))
}

@Test @MainActor func diagnosticsCancellationLeavesDestinationAndMainActorResponsive() async throws {
    let fixture = try archiveFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = Data("existing diagnostics".utf8)
    try original.write(to: fixture.destination)
    let entered = BoundedReply<Bool>()
    let childStarted = fixture.root.appendingPathComponent("child-started")
    let operation = Task {
        try await DiagnosticsArchive.export(fixture.snapshot, to: fixture.destination, temporaryDirectory: fixture.root) { _, output in
            entered.resolve(true)
            try await AsyncCommand.run(URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf ready > \"$1\"; exec /bin/sleep 20", "archive-test", childStarted.path], timeout: 30)
            try Data("should never be published".utf8).write(to: output)
        }
    }
    #expect(await entered.value(timeout: 2, fallback: false) { _ in })
    let startupDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !FileManager.default.fileExists(atPath: childStarted.path), ContinuousClock.now < startupDeadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(FileManager.default.fileExists(atPath: childStarted.path))
    // This MainActor job must run while the archive child is still waiting, like the heartbeat.
    let heartbeat = Task { @MainActor in true }
    #expect(await heartbeat.value)
    let start = ContinuousClock.now
    operation.cancel()
    do { _ = try await operation.value; Issue.record("Expected cancellation") }
    catch is CancellationError {} // Child has exited/reaped before the worker returns.
    #expect(start.duration(to: .now) < .seconds(3))
    try FileManager.default.removeItem(at: childStarted)
    #expect(try Data(contentsOf: fixture.destination) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted() == ["private.log", "result.zip"])
}

@Test func diagnosticsArchivePublishesCompleteZipAndReplacesExistingFile() async throws {
    let fixture = try archiveFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try Data("old file".utf8).write(to: fixture.destination)
    let result = try await DiagnosticsArchive.export(fixture.snapshot, to: fixture.destination, temporaryDirectory: fixture.root)
    #expect(result == fixture.destination)
    let signature = try Data(contentsOf: result).prefix(2)
    #expect(signature == Data([0x50, 0x4b]))
    try await AsyncCommand.run(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-t", result.path])
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted() == ["private.log", "result.zip"])
}

@Test func diagnosticsArchiveFailureKeepsExistingDestination() async throws {
    let fixture = try archiveFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try Data("old file".utf8).write(to: fixture.destination)
    await #expect(throws: (any Error).self) {
        _ = try await DiagnosticsArchive.export(fixture.snapshot, to: fixture.destination, temporaryDirectory: fixture.root) { _, _ in
            throw RemovalTestError()
        }
    }
    #expect(try String(contentsOf: fixture.destination, encoding: .utf8) == "old file")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted() == ["private.log", "result.zip"])
}

@Test func diagnosticsArchiveChildHasBoundedDeadline() async {
    let start = ContinuousClock.now
    await #expect(throws: (any Error).self) {
        try await AsyncCommand.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], timeout: 0.02)
    }
    #expect(start.duration(to: .now) < .seconds(3))
}

@Test @MainActor func restartAlsoWaitsForEditsQueuedDuringTheInitialSave() async {
    let store = SettingsStore()
    let firstGate = BoundedReply<Bool>()
    let secondGate = BoundedReply<Bool>()
    let secondStarted = BoundedReply<Bool>()
    var restarted = false
    store.save(key: "first", value: "1", label: "First", send: {
        _ = await firstGate.value(timeout: 2, fallback: false) { _ in }
        return nil
    })
    let restart = HostProcessActions.restartAfterSaving(store, restart: { reply in
        restarted = true
        reply(.init(success: true, output: ""))
    }, completion: { _ in })
    await Task.yield()
    store.save(key: "second", value: "2", label: "Second", send: {
        secondStarted.resolve(true)
        _ = await secondGate.value(timeout: 2, fallback: false) { _ in }
        return nil
    })
    firstGate.resolve(true)
    #expect(await secondStarted.value(timeout: 1, fallback: false) { _ in })
    await Task.yield()
    #expect(!restarted)
    secondGate.resolve(true)
    await restart.value
    #expect(restarted)
    #expect(store.values["second"] == "2")
}
