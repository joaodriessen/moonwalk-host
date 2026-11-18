import SwiftUI
import AppKit
import SkylightMenuCore

/// Entry point (docs/design/menubar-app.md; S0 walking skeleton, now S1 hand-crafted
/// controls). Menubar-only (no dock icon): `LSUIElement` in the bundled Info.plist (see
/// build.sh) is the primary mechanism; `.accessory` here is a defensive belt-and-suspenders
/// for the unbundled dev-run case.
/// Runs work that must happen at LAUNCH, not on first popover open. A `MenuBarExtra` content
/// view's `.task`/`.onAppear` only fires when the user first opens the popover, so the
/// first-run login-item registration and notification-auth request live here instead.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let loginItem = LoginItemManager()
    let host = HostConnection(connectImmediately: false)

    /// Held open for the process's entire lifetime -- the fd itself IS the single-instance
    /// lock (see `acquireSingleInstanceLock`). Never closed; the kernel releases the flock
    /// automatically whenever this process's file descriptors go away, on ANY exit path.
    private var singleInstanceLockFD: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hostLog = SkylightDataPaths.configuration(home: FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("sunshine.log")
        try? BoundedLog.rotateIfNeeded(hostLog)
        // Single-instance guard: repeated launches (LaunchServices re-open, deploy scripts,
        // `open` from different parents) were observed to stack THREE live instances — three
        // status items, three XPC connections.
        //
        // An exclusive, non-blocking `flock()` on a well-known path, not an
        // `NSRunningApplication.runningApplications` query: the latter is check-then-act --
        // two near-simultaneous launches can both observe an empty "others" list before
        // either is registered as running, and both proceed. `flock()` is atomic at the
        // kernel level (only one caller can hold LOCK_EX at a time) and self-cleaning: the
        // lock is released the instant this process's descriptors close, on ANY exit path
        // (clean quit, force-quit, crash) -- so unlike a hand-rolled PID file, there is no
        // stale-lock-wedges-startup failure mode to guard against.
        if !acquireSingleInstanceLock() {
            NSLog("[SkylightMenu] another instance already holds the single-instance lock — exiting this one")
            NSApp.terminate(nil)
            return
        }

        // Prepare defaults/migration before XPC can demand-launch the host. Otherwise the
        // host can create an empty config first and make first-run skip the shipped defaults.
        do {
            guard let resources = Bundle.main.resourceURL else { throw CocoaError(.fileNoSuchFile) }
            try SkylightDataPaths.prepare(
                home: FileManager.default.homeDirectoryForCurrentUser,
                legacyInstallation: SkylightDataPaths.isLegacyInstallation(defaults: .standard),
                defaultsDirectory: resources.appendingPathComponent("Defaults")
            )
        } catch {
            let alert = NSAlert()
            alert.messageText = "Moonwalk Host could not prepare its settings"
            alert.informativeText = error.localizedDescription + " Your previous settings have been preserved."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        // Default to "Open at Login" on first install; the user can toggle it off in Settings
        // afterward and that choice sticks. Registration only succeeds for an installed
        // (~/Applications) bundle LaunchServices knows about; a build-dir dev run no-ops.
        loginItem.enableOnFirstRunIfNeeded()

        do {
            try HostServiceManager().refreshRegistrationIfExecutableChanged()
        } catch {
            host.startupError = error.localizedDescription
            NSLog("[SkylightMenu] could not refresh changed host registration: %@", error.localizedDescription)
        }
        // XPC must not demand-launch the cached service until any executable-path migration has
        // completed (or failed cleanly for this launch). A failed migration leaves the old path
        // marker intact, so the next launch retries before making its first connection.
        host.connect()

        // Request notification authorization once, up front, so status-transition notifications
        // can fire from the very first stream (NotificationManager no-ops if denied).
        NotificationManager.shared.requestAuthorizationIfNeeded()

        // No promote/demote to install (superseded 2026-07-18, design "P.3"/"V.1"): the app
        // stays `.accessory` permanently now -- see WindowActivator's doc comment.
    }

    /// Returns false if another live instance already holds the lock (caller must exit).
    /// The lock file lives under this app's own Application Support directory, named by
    /// bundle id so it can never collide with an unrelated app's lock. Fails OPEN (returns
    /// true, logging a warning) if the lock file itself can't even be opened -- a
    /// permissions/disk-full edge case on the guard's own bookkeeping file must never brick
    /// startup; the multi-instance stacking bug this guards against is a nuisance, not a
    /// correctness issue.
    private func acquireSingleInstanceLock() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "skylightmenu"
        let dir = NSHomeDirectory() + "/Library/Application Support/Skylight"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/\(bundleID).lock"

        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            NSLog("[SkylightMenu] could not open single-instance lock file at %@ (errno %d) -- proceeding without the guard",
                  path, errno)
            return true
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        singleInstanceLockFD = fd
        return true
    }
}

@main
struct SkylightMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var host: HostConnection { appDelegate.host }
    /// The client-side restart-pending trust fix (design §3) -- declared once, here, and shared
    /// into `SettingsView` as a plain property (both are `@Observable` now). Per-session (not
    /// persisted): resets on relaunch, matching the daemon's own actual restart-clears-it
    /// semantics.
    @State private var restart = RestartCoordinator()
    /// Presentation-only bridge for the pairing sheet (docs/design/
    /// 2026-07-18-pairing-attached-to-settings.md) -- declared once, here, and shared into both
    /// `MenuContent` (the trigger) and `SettingsView` (the host), same pattern as `restart` above.
    @State private var pairing = PairingPresentation()
    @State private var firstRun = FirstRunCoordinator()
    @State private var launchPresentation = LaunchPresentationCoordinator()
    @State private var permissionSetup = PermissionSetupCoordinator()
    @State private var quitConfirmation = QuitConfirmation()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        // Tahoe-native redesign §1: default `.menu` style (no `.menuBarExtraStyle(.window)`) --
        // the popover's actual richness was one status line + a toggle + a few actions, squarely
        // the case Apple's own HIG says to render as a menu, not a popover.
        MenuBarExtra {
            MenuContent(host: host, pairing: pairing, firstRun: firstRun, permissionSetup: permissionSetup, quitConfirmation: quitConfirmation)
        } label: {
            MenuBarLabel(
                glyph: menuBarGlyph,
                opacity: MenuBarIcon.opacity(connected: host.status == .connected),
                accessibilityLabel: menuBarAccessibilityLabel,
                firstRun: firstRun,
                launchPresentation: launchPresentation
            )
        }

        // S2 -- the schema-driven long-tail Settings window (docs/design/menubar-app.md "S2").
        // A dedicated `Window` scene rather than the `Settings {}` scene builder: `Settings {}`
        // is wired to Cmd-, and the app menu, neither of which exist for an `.accessory`-
        // activation-policy, menubar-only app with no menu bar of its own -- opened via
        // `WindowActivator.open(id:using:)` (design §6) from the menu's "Settings…" row.
        // `.windowResizability(.contentSize)` lets SettingsView's own `.frame(minWidth:...)`
        // govern the resize range instead of SwiftUI's default window sizing heuristics.
        Window("Moonwalk Host Settings", id: SkylightMenuApp.settingsWindowID) {
            SettingsView(host: host, loginItem: appDelegate.loginItem, restart: restart, pairing: pairing, permissionSetup: permissionSetup, quitConfirmation: quitConfirmation)
        }
        .windowResizability(.contentSize)

        Window("Welcome to Moonwalk Host", id: SkylightMenuApp.firstRunWindowID) {
            FirstRunView(coordinator: firstRun, host: host, pairing: pairing, permissionSetup: permissionSetup)
        }
        .windowResizability(.contentSize)

        // Pairing (revised 2026-07-18, docs/design/2026-07-18-pairing-attached-to-settings.md):
        // pairing is now a `.sheet` hosted on the Settings window (`SettingsView`'s
        // `.sheet(isPresented:)`, driven by the shared `pairing` coordinator above), not its own
        // top-level `Window` scene. The prior "own small dedicated window" amendment rested on the
        // belief that a `.menu`-style `MenuBarExtra` has no popover to host a sheet from -- true,
        // but irrelevant: a sheet's host is the Settings window, not the menu popover. The owner
        // has since lived with the standalone window and rejected it (modeless, competes for
        // window management); this restores the original Tahoe-native design's own intent. See
        // `PairingPresentation.swift` and `MenuContent.swift`'s doc comment for the trigger side.
    }

    /// Shared window ids so `MenuContent`'s `WindowActivator.open(id:using:)` calls and these
    /// scene declarations can't drift out of sync with each other.
    static let settingsWindowID = "settings"
    static let firstRunWindowID = "first-run"

    /// Workstream D: a pending pairing request badges the glyph even mid-stream -- see
    /// `MenuBarIcon`'s doc comment for the precedence rule. Pure decision logic lives in
    /// `SkylightMenuCore` so it's unit-tested without a live `MenuBarExtra`.
    private var menuBarGlyph: LucideGlyph {
        MenuBarIcon.glyph(
            connected: host.status == .connected,
            streaming: host.richStatus.streaming,
            pendingPairing: host.richStatus.pendingPairing
        )
    }

    /// Design §1.3: gains an offline case ("Skylight — not running") the retired ContentView-era
    /// label didn't have -- state is now carried by the glyph's opacity too, so the
    /// accessibility label should say so for VoiceOver users.
    private var menuBarAccessibilityLabel: String {
        if host.richStatus.pendingPairing { return "Moonwalk Host — a device wants to pair" }
        if host.status != .connected { return "Moonwalk Host — not running" }
        return "Moonwalk Host"
    }
}

private struct MenuBarLabel: View {
    let glyph: LucideGlyph
    let opacity: Double
    let accessibilityLabel: String
    var firstRun: FirstRunCoordinator
    var launchPresentation: LaunchPresentationCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // MenuBarExtra sizes a template NSImage as given; 18 pt is the status-item glyph size.
        Image(nsImage: Lucide.image(glyph, points: 18))
            .opacity(opacity)
            .accessibilityLabel(accessibilityLabel)
            .task {
                launchPresentation.presentIfNeeded(firstRun: firstRun, openWindow: openWindow)
            }
    }
}
