import Foundation
import SkylightMenuCore

@MainActor
enum UninstallCoordinator {
    /// Latched after login startup is retired, before host unregister runs, so convergence
    /// cannot recreate the service while removal is in progress. Any first-run pass that races in
    /// during (or after) the unregister sees it immediately, not just once removal completes.
    /// In-memory only, never persisted: a relaunched app SHOULD go through guided first run
    /// again (e.g. after a plain "Remove Background Service" that leaves config/state intact,
    /// or after any future relaunch) -- this latch only needs to survive for the remainder of
    /// *this* process's life, to stop *this* process from undoing its own uninstall.
    /// `FirstRunCoordinator` reads this to gate its silent re-seed effects.
    private(set) static var didRemoveService = false

    static func removeService(deleteData: Bool) throws {
        try RemovalTransaction.run(removeLogin: {
            if let message = LoginItemManager().setEnabled(false) {
                throw RemovalTransaction.Failure(errorDescription: message)
            }
        }, removeHost: {
            didRemoveService = true
            try HostServiceManager().unregister()
        }, removeData: {
            guard deleteData else { return }
            let files = FileManager.default
            try SkylightDataPaths.removeOwnedData(home: files.homeDirectoryForCurrentUser, files: files)
            // A later deliberate reinstall must return to guided first run.
            // Keep-data removal retains this bookkeeping and the user's login preference.
            // Delete-data removal clears completion and registration keys together.
            removePersistentDomain()
        })
    }

    /// I2 fix: wipes the app's UserDefaults persistent domain. Called once above as the last
    /// step of a delete-data removal, and callable again standalone immediately before the app
    /// terminates -- `StatusPaneView`'s delete-data flow does exactly that, as a final safety
    /// net against anything that could repopulate the domain in the gap between this call and
    /// `removeService(deleteData:)`'s own call to it above, up until the process actually exits.
    /// M7 correction: that gap is pre-terminate only. AppKit's window-frame-restoration write
    /// happens *during* `terminate(nil)`, after this second call already ran, so it is not what
    /// this second call guards against -- and it cannot repopulate `skylight.firstRunComplete`
    /// or the registration keys anyway, since their only writers (`FirstRunCoordinator.perform`)
    /// are latched off by `didRemoveService` above for the remainder of this process (I4 fix).
    /// A post-terminate `NSWindow Frame` key rewrite, if it happens, is cosmetic window-position
    /// state, not a contract key, and the process exits moments later regardless.
    static func removePersistentDomain() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
    }

    /// Result of the trash-the-bundle step of `uninstall()`. Never fatal to the uninstall as a
    /// whole -- by the time this step runs, `removeService(deleteData: true)` has already
    /// unregistered the service and deleted data, and that is not undone whichever case comes
    /// back. `.skipped`/`.failed` exist purely so the caller can fall back to the older "drag it
    /// to the Trash yourself" copy instead of claiming a trash that didn't happen.
    enum TrashOutcome {
        case trashed
        case skipped
        case failed
    }

    /// Full one-click uninstall. Order matters: service unregister and data removal run FIRST
    /// (via `removeService(deleteData: true)`, unchanged above) because they need the running
    /// app's own identity -- bundle ID for the UserDefaults domain, an XPC connection to the
    /// daemon for unregister -- which a bundle sitting in the Trash can no longer reliably supply.
    /// Only once that's done does this move the bundle itself to the Trash, last, right before the
    /// caller quits the app.
    ///
    /// A running app CAN trash its own bundle. `FileManager.trashItem` unlinks/moves the bundle
    /// directory on disk, but this process's already-mapped executable image stays valid -- the
    /// kernel holds the backing inode open -- until the process actually exits, so nothing here
    /// crashes or misbehaves in the moments between this call and the quit that follows it.
    static func uninstall() throws -> TrashOutcome {
        try removeService(deleteData: true)
        return trashAppBundle()
    }

    /// Only trashes the bundle when it lives under /Applications or ~/Applications -- never a dev
    /// build directory (SwiftPM `.build/`, an Xcode DerivedData product, a worktree checkout)
    /// someone might be running this very code from. Outside that guard, or if `trashItem` itself
    /// throws (unusual install location, permission denied, bundle already gone), this returns
    /// `.skipped`/`.failed` rather than throwing -- a failed trash step must not read as a failed
    /// uninstall when the data removal above already succeeded.
    private static func trashAppBundle() -> TrashOutcome {
        let bundleURL = Bundle.main.bundleURL
        let files = FileManager.default
        let applicationsDirs = [
            URL(fileURLWithPath: "/Applications"),
            files.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]
        let isUnderApplications = applicationsDirs.contains { dir in
            bundleURL.path.hasPrefix(dir.path + "/")
        }
        guard isUnderApplications else { return .skipped }
        do {
            try files.trashItem(at: bundleURL, resultingItemURL: nil)
            return .trashed
        } catch {
            return .failed
        }
    }
}
