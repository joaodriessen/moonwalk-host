import Foundation

/// Retire auto-start before removing the service it would recreate on the next login.
@MainActor
public enum RemovalTransaction {
    public struct Failure: LocalizedError {
        public let errorDescription: String?
        public init(errorDescription: String) { self.errorDescription = errorDescription }
    }

    public static func run(
        removeLogin: () throws -> Void,
        removeHost: () throws -> Void,
        removeData: () throws -> Void
    ) throws {
        do { try removeLogin() }
        catch { throw Failure(errorDescription: "Couldn’t turn off Open at Login. The background service and data were kept. \(error.localizedDescription)") }
        do { try removeHost() }
        catch { throw Failure(errorDescription: "Open at Login is off, but the background service could not be removed. Your data was kept. \(error.localizedDescription)") }
        do { try removeData() }
        catch { throw Failure(errorDescription: "Open at Login and the background service were removed, but some data could not be deleted. Try uninstalling again. \(error.localizedDescription)") }
    }
}
