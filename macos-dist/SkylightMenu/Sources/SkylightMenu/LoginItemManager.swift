import Observation
import ServiceManagement
import SwiftUI

/// "Open at Login" for the menubar app, via `SMAppService.mainApp` (macOS 13+). This registers
/// the app bundle ITSELF as a login item — it does NOT itself launch or supervise the streaming
/// daemon's `com.lumen.sunshine` LaunchAgent (design decision D3: the app attaches to the daemon
/// over XPC, on-demand, rather than spawning it directly).
///
/// NOTE (superseded, docs/design/2026-07-19-daemon-lifecycle-coupling.md §5a): this used to say
/// "two independent lifecycles" -- true of registration mechanics, but no longer true of runtime
/// behavior. The daemon now demand-launches on this app's XPC connect, captures/streams only
/// while a validated menu is attached, and self-terminates (ending any active stream) the moment
/// this app quits, crashes, or is force-killed (see `HostConnection.shutdownHost()`/
/// `menuHeartbeat()` and the daemon's `validated_menu_attached` authority). Quitting the menu now
/// ends the stream and the daemon too.
///
/// Registration only works for a properly-installed, LaunchServices-known bundle (i.e. the app
/// living in ~/Applications, not a throwaway build-dir run) — see macos-dist/SkylightMenu/build.sh
/// `install`.
@MainActor
@Observable
final class LoginItemManager {
    enum State { case enabled, disabled, requiresApproval, unavailable }
    private(set) var state: State = .disabled
    var isEnabled: Bool { state == .enabled || state == .requiresApproval }
    var requiresApproval: Bool { state == .requiresApproval }

    init() {
        refresh()
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled: state = .enabled
        case .requiresApproval: state = .requiresApproval
        case .notRegistered: state = .disabled
        case .notFound: state = .unavailable
        @unknown default: state = .unavailable
        }
    }

    /// Turn "Open at Login" on/off. Returns an error message on failure, nil on success.
    @discardableResult
    func setEnabled(_ enable: Bool) -> String? {
        do {
            if enable {
                if SMAppService.mainApp.status == .notRegistered || SMAppService.mainApp.status == .notFound {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
            refresh()
            return nil
        } catch {
            refresh()
            return error.localizedDescription
        }
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    /// On the first run after install, enable auto-start once. The user can toggle it off later
    /// and that choice is respected (we never re-enable after this one-time default).
    ///
    /// The "already configured" flag is persisted ONLY after a SUCCESSFUL registration — a failed
    /// attempt (e.g. running from a build dir LaunchServices doesn't know, before `build.sh
    /// install`) must not mark itself done, or the real installed launch would never retry.
    func enableOnFirstRunIfNeeded() {
        let key = "didConfigureLoginItemDefault"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        if setEnabled(true) == nil {
            UserDefaults.standard.set(true, forKey: key)
        }
    }
}
