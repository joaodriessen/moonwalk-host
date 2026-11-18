public enum ServiceRegistrationMigration {
    public static func shouldRefresh(
        registered: Bool,
        recordedPath: String?,
        currentPath: String,
        migrationPending: Bool = false
    ) -> Bool {
        if migrationPending { return true }
        if registered { return recordedPath != currentPath }
        return recordedPath != nil && recordedPath != currentPath
    }

    @discardableResult
    public static func refreshIfNeeded(
        registered: Bool,
        recordedPath: String?,
        currentPath: String,
        migrationPending: Bool = false,
        unregister: () throws -> Void,
        register: () throws -> Void
    ) throws -> Bool {
        guard shouldRefresh(
            registered: registered,
            recordedPath: recordedPath,
            currentPath: currentPath,
            migrationPending: migrationPending
        ) else { return false }

        if registered { try unregister() }
        try register()
        return true
    }
}
