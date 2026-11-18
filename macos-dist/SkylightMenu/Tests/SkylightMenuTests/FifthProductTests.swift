import Foundation
import Testing
@testable import SkylightMenu
@testable import SkylightMenuCore

@MainActor private final class RepairServiceFixture: HostServiceManaging {
    var status: FirstRunEnvironment.Service = .notRegistered
    var registrations = 0
    var approvalOpens = 0
    var failRegistration = false
    func register() throws {
        registrations += 1
        if failRegistration { throw NSError(domain: "Observed registration failure", code: 99) }
    }
    func unregister() throws { Issue.record("Repair must never uninstall the service") }
    func openApprovalSettings() { approvalOpens += 1 }
}

@Test @MainActor func repairPreparationUsesObservedServiceStateAndDoesNotInventXPCDiagnosis() throws {
    let service = RepairServiceFixture()
    var refreshes = 0
    #expect(try HostRepairPreparation.prepare(installed: false, executablePresent: true, service: service, refreshRegistered: {}) != nil)
    #expect(service.registrations == 0)
    #expect(try HostRepairPreparation.prepare(installed: true, executablePresent: false, service: service, refreshRegistered: {}) != nil)
    #expect(service.registrations == 0)
    service.status = .requiresApproval
    #expect(try HostRepairPreparation.prepare(installed: true, executablePresent: true, service: service, refreshRegistered: {}) != nil)
    #expect(service.approvalOpens == 1 && service.registrations == 0)
    service.status = .notRegistered
    #expect(try HostRepairPreparation.prepare(installed: true, executablePresent: true, service: service, refreshRegistered: { refreshes += 1 }) == nil)
    #expect(service.registrations == 1 && refreshes == 0)
    service.status = .registered
    #expect(try HostRepairPreparation.prepare(installed: true, executablePresent: true, service: service, refreshRegistered: { refreshes += 1 }) == nil)
    #expect(refreshes == 1)
    service.status = .notRegistered; service.failRegistration = true
    #expect(throws: Error.self) {
        try HostRepairPreparation.prepare(installed: true, executablePresent: true, service: service, refreshRegistered: {})
    }
}

@Test @MainActor func conflictResolutionKeepsOtherDraftsAndChoosesOnlyTheSelectedValue() {
    let store = SettingsStore()
    store.applyExternalSnapshot(["port": "47989", "encoder": "videotoolbox"], running: [:], revision: "one", startedAt: 0)
    store.drafts = ["port": "48000", "encoder": "software"]
    store.applyExternalSnapshot(["port": "48010", "encoder": "videotoolbox"], running: [:], revision: "two", startedAt: store.revision)
    #expect(store.conflicts.count == 1)
    #expect(store.keepLocalValue(for: "port") == "48000")
    #expect(store.drafts["encoder"] == "software")
    #expect(store.drafts["port"] == "48000")
}
