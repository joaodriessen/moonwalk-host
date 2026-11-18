import SwiftUI

/// Presentation-only coordinator for the pairing sheet (docs/design/
/// 2026-07-18-pairing-attached-to-settings.md §2.1). Bridges the menu-bar trigger (`MenuContent`,
/// a different scene) to the sheet's actual host (`SettingsView`'s window) -- mirroring how
/// `RestartCoordinator` is declared once in `SkylightMenuApp` and shared into `SettingsView`
/// (`SkylightMenuApp.swift`, `SettingsView.swift`).
///
/// Deliberately minimal: a single `isPresented` flag driving `.sheet(isPresented:)` on the
/// Settings window. NO pairing logic lives here -- that stays entirely in `PairingReducer`/
/// `PairingState`/`PairingModel`, which this coordinator never touches or wraps.
@MainActor
@Observable
final class PairingPresentation {
    var isPresented = false

    /// Owner-initiated open from a scene other than Settings (the menu's "Pair New Device…" row).
    /// Opens/fronts the Settings window first, THEN arms the sheet one run-loop tick later --
    /// design §2.3/§3.4: setting `isPresented` in the SAME turn as `openWindow` can fire before
    /// SwiftUI has instantiated the Settings scene, so its `.sheet` modifier isn't in the view
    /// tree yet to observe the change. This is the same one-tick `DispatchQueue.main.async` hop
    /// `WindowActivator.open` already relies on for its own key/activate dance
    /// (`WindowActivator.swift`) -- proven-idiomatic in this codebase, not a new technique.
    func present(using openWindow: OpenWindowAction) {
        WindowActivator.open(id: SkylightMenuApp.settingsWindowID, using: openWindow)
        DispatchQueue.main.async {
            self.isPresented = true
        }
    }
}
