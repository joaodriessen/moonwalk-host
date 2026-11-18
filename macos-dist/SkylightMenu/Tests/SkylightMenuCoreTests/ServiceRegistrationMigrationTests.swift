import Testing
@testable import SkylightMenuCore

@Test func registeredServiceRefreshesWhenExecutablePathChanges() {
    #expect(ServiceRegistrationMigration.shouldRefresh(
        registered: true,
        recordedPath: "Contents/Resources/Helpers/sunshine",
        currentPath: "Contents/Resources/Helpers/Skylight"
    ))
    #expect(ServiceRegistrationMigration.shouldRefresh(
        registered: true,
        recordedPath: nil,
        currentPath: "Contents/Resources/Helpers/Skylight"
    ))
}

@Test func freshOrCurrentServiceDoesNotRefresh() {
    #expect(!ServiceRegistrationMigration.shouldRefresh(
        registered: false,
        recordedPath: nil,
        currentPath: "Contents/Resources/Helpers/Skylight"
    ))
    #expect(!ServiceRegistrationMigration.shouldRefresh(
        registered: true,
        recordedPath: "Contents/Resources/Helpers/Skylight",
        currentPath: "Contents/Resources/Helpers/Skylight"
    ))
}

@Test func interruptedRefreshRetriesWhenOldPathIsStillRecorded() {
    #expect(ServiceRegistrationMigration.shouldRefresh(
        registered: false,
        recordedPath: "Contents/Resources/Helpers/sunshine",
        currentPath: "Contents/Resources/Helpers/Skylight"
    ))
}

@Test func interruptedFirstMigrationRetriesWithPendingMarker() {
    #expect(ServiceRegistrationMigration.shouldRefresh(
        registered: false,
        recordedPath: nil,
        currentPath: "Contents/Resources/Helpers/Skylight",
        migrationPending: true
    ))
}

@Test func retryAfterSuccessfulUnregisterSkipsASecondUnregister() throws {
    var calls: [String] = []

    let refreshed = try ServiceRegistrationMigration.refreshIfNeeded(
        registered: false,
        recordedPath: "Contents/Resources/Helpers/sunshine",
        currentPath: "Contents/Resources/Helpers/Skylight",
        unregister: { calls.append("unregister") },
        register: { calls.append("register") }
    )

    #expect(refreshed)
    #expect(calls == ["register"])
}

@Test func pendingFirstMigrationRetriesRegistrationWithoutUnregisteringAgain() throws {
    var calls: [String] = []

    let refreshed = try ServiceRegistrationMigration.refreshIfNeeded(
        registered: false,
        recordedPath: nil,
        currentPath: "Contents/Resources/Helpers/Skylight",
        migrationPending: true,
        unregister: { calls.append("unregister") },
        register: { calls.append("register") }
    )

    #expect(refreshed)
    #expect(calls == ["register"])
}

@Test func successfulFreshRegistrationIsCurrentOnNextLaunch() {
    #expect(!ServiceRegistrationMigration.shouldRefresh(
        registered: true,
        recordedPath: "Contents/Resources/Helpers/Skylight",
        currentPath: "Contents/Resources/Helpers/Skylight"
    ))
}

@Test func failedRegistrationDoesNotReportACompletedRefresh() {
    enum ExpectedFailure: Error { case register }
    var calls: [String] = []

    #expect(throws: ExpectedFailure.self) {
        try ServiceRegistrationMigration.refreshIfNeeded(
            registered: true,
            recordedPath: "Contents/Resources/Helpers/sunshine",
            currentPath: "Contents/Resources/Helpers/Skylight",
            unregister: { calls.append("unregister") },
            register: {
                calls.append("register")
                throw ExpectedFailure.register
            }
        )
    }
    #expect(calls == ["unregister", "register"])
}
