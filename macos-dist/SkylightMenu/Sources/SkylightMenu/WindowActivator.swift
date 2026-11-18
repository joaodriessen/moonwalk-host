import AppKit
import SwiftUI

/// Reliably brings a SwiftUI `Window` scene to the front for an `.accessory`/`LSUIElement` app.
///
/// HISTORY (superseded 2026-07-18, docs/design/design-native-first.md "P.3"/"V.1"): this used to
/// flip the app's activation policy `.accessory` -> `.regular` (a real Dock icon appearing) and
/// force-activate with `ignoringOtherApps: true` on every window open, demoting back to
/// `.accessory` only once every window closed -- an "Owner-approved trade (O-1)" the owner has
/// since explicitly REJECTED after living with it (dossier-pairing-bugs.md D: it seized focus
/// from whatever app the owner was using and made "couldn't get back to what I was doing" the
/// dominant complaint about the pairing flow). That trade is gone: the app now STAYS
/// `.accessory` permanently -- no Dock icon ever appears for Settings/Pairing/Onboarding.
///
/// A plain titled `NSWindow` (what every `Window` scene in this app produces) can become key and
/// accept keyboard input for an `.accessory` app with no special shim -- `canBecomeKey` only
/// defaults to `false` for borderless windows, which none of ours are. The ORIGINAL "opens
/// behind/greyed out" bug this file existed to fix (see the SEQUENCING note below) was an
/// activation-ordering race, not a consequence of the Dock icon being absent -- so the fix that
/// actually matters is the hop-sequenced `activate()`/`makeKeyAndOrderFront()` dance, kept below,
/// minus the policy flip and minus `ignoringOtherApps: true`.
///
/// SEQUENCING (2026-07-17 origin fix — the window used to open BEHIND/greyed and never become
/// key): an `activate()`/`openWindow` issued in the same run-loop turn as each other can land
/// before AppKit has registered the new window, leaving nothing to key. The reliable dance is:
/// activate → open the window → let a run-loop turn pass → key it and re-activate once more. Each
/// hop gives AppKit/WindowServer the chance to commit the previous step.
@MainActor
enum WindowActivator {
    /// Opens the window identified by `id`.
    ///
    /// Activation is COOPERATIVE ONLY (`NSApp.activate()`, never `ignoringOtherApps: true`) --
    /// the owner just clicked our menu-bar item or a button inside a window we already own, so
    /// this app is typically already active; cooperative activation is enough to bring our own
    /// window forward without yanking focus away from whatever else the owner was doing.
    ///
    /// WINDOW LEVEL (2026-07-18, second fix): every window this opens is `.normal` level. An
    /// earlier revision leveled the pairing window to `.floating` -- but `.floating` is
    /// system-wide always-on-top: it sits above EVERY other app's windows and stays there when
    /// the owner switches away, which reproduced the exact "the pairing window holds attention, I
    /// can't get back to anything / can't quit" takeover it was meant to avoid (the menu-bar
    /// Quit menu could even be occluded by it). Bringing the window forward once on open (the
    /// activate/key dance below) is all that's needed; it must then behave like any ordinary
    /// window -- freely switched-away-from, closable, never trapping the owner. The level is set
    /// explicitly (not just left defaulted) because SwiftUI reuses the same NSWindow across
    /// opens, so a window that was ever floated must be reset back to `.normal`.
    static func open(id: String, using openWindow: OpenWindowAction) {
        NSApp.activate()
        openWindow(id: id)

        // Let AppKit register the freshly-opened window before keying it -- the activation and
        // the window's existence don't reliably land in the same run-loop turn.
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == id })
                ?? NSApp.windows.last(where: { $0.isVisible && !$0.isSheet }) else {
                return
            }
            window.level = .normal
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }
}
