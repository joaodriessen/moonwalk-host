import SwiftUI
import AppKit
import SkylightMenuCore

/// The `.menu`-style `MenuBarExtra` content (Tahoe-native redesign, docs/design/
/// 2026-07-15-tahoe-native-redesign.md §1, owner-amended). Replaces the retired `ContentView`'s
/// custom `.window`-style popover: a one-line quick glance plus three plain actions -- all
/// richness that used to live in the popover (live session stats, the equalizer animation, the
/// footer health text, Restart) moved to the Settings window (design §1.2's disposition table).
///
/// Owner amendments (override the design doc where they differ):
///   1. NO keyboard-shortcut glyphs anywhere -- a menu-bar widget can't honor them globally, so
///      none of these rows carry `.keyboardShortcut`.
///   2. NO Hide Cursor control anywhere in this app -- removed end-to-end (this menu, and the
///      XPC client calls in `HostConnection`/`SkylightControlProtocol`; the daemon keeps its
///      handler).
///   4. (REVISED 2026-07-18, docs/design/2026-07-18-pairing-attached-to-settings.md, owner
///      request) Pairing is back to a `.sheet` hosted on the Settings window, per the ORIGINAL
///      Tahoe-native design intent -- this row now calls `pairing.present(using:)`, which opens
///      Settings (via `WindowActivator`, same fronting dance as every other window here) and then
///      arms the sheet one run-loop tick later. The standalone `Window` scene this amendment used
///      to describe rested on a mistaken belief: a `.menu`-style `MenuBarExtra` has no popover to
///      host a sheet from, true, but a sheet's host is the Settings window, not the menu popover.
///      The owner lived with the standalone window and rejected it (modeless, competed for window
///      management); this reverts to the sheet, now that belief is corrected.
///   5. Pairing is now strictly OWNER-INITIATED (S3 pairing-DoS/hijack fix). This row used to
///      auto-raise the pairing UI the instant `richStatus.pendingPairing` went true --
///      but that signal fires for ANY pending `getservercert` session on the unauthenticated
///      `/pair` listener, eligible or not (see `nvhttp::has_pending_pair_request()`), so an
///      attacker's phantom session could pop the owner's pairing UI unprompted. The row is now a
///      plain action the owner clicks; `pendingPairing` only lights a passive badge (see
///      `pairRowTitle`) -- informational awareness, never an auto-presented sheet. Presenting the
///      sheet is what arms the host's eligibility window (`PairingSheet.onAppear` ->
///      `HostConnection.beginPairingWindow()`), so nothing here -- including amendment 4's
///      Settings-opening hop -- should pre-empt that owner action by setting `pairing.isPresented`
///      on its own.
struct MenuContent: View {
    var host: HostConnection
    var pairing: PairingPresentation
    var firstRun: FirstRunCoordinator
    var permissionSetup: PermissionSetupCoordinator
    var quitConfirmation: QuitConfirmation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            // Row 1: disabled, one-line status (design §1.1/§5.1) -- info, not action, so it's
            // rendered as a disabled control (HIG's dimmed/disabled convention for an
            // info-only menu row), not a plain enabled Button.
            Button(statusLine) {}
                .disabled(true)

            Divider()

            Button(setupActionTitle) {
                if firstRun.isComplete {
                    pairing.present(using: openWindow)
                } else {
                    WindowActivator.open(id: SkylightMenuApp.firstRunWindowID, using: openWindow)
                }
            }
            .accessibilityLabel(setupActionAccessibilityLabel)

            Button("Settings…") {
                WindowActivator.open(id: SkylightMenuApp.settingsWindowID, using: openWindow)
            }

            Divider()

            Button("Quit Moonwalk Host") {
                // Daemon lifecycle coupling (docs/design/2026-07-19-daemon-lifecycle-coupling.md
                // §3 "Quit flow", owner-confirmed §5a): quitting the menu now ends any active
                // stream and terminates the daemon too -- the two are no longer independent
                // lifecycles. shutdownHost() is best-effort and bounded to ~1s (see its doc
                // comment), so an unreachable daemon never delays this app's own quit; the
                // daemon's own NOTE_EXIT/presence-window backstop tears it down independently
                // either way.
                let stateKnown = host.status == .connected && !host.richStatus.appVersion.isEmpty
                let streaming = host.richStatus.streaming
                let request: @MainActor @Sendable () -> Void = {
                    quitConfirmation.request(streaming: streaming, stateKnown: stateKnown) {
                        Task {
                            await host.shutdownHost()
                            NSApplication.shared.terminate(nil)
                        }
                    }
                }
                if streaming || !stateKnown {
                    // A menu has no presenting window. Front Settings, then present on the
                    // next turn, matching the existing pairing presentation sequence.
                    WindowActivator.open(id: SkylightMenuApp.settingsWindowID, using: openWindow)
                    DispatchQueue.main.async(execute: request)
                } else { request() }
            }
        }
        .onAppear {
            host.connect()
            firstRun.refresh(
                permissionState: permissionSetup.firstRunPermissionState,
                hostAvailability: host.firstRunAvailability
            )
        }
        .onChange(of: host.richStatus) { _, newValue in
            // S3 notifications: derive "Streaming started" / "Client connected" purely from
            // this poll-driven transition -- see NotificationManager's doc comment for why no
            // new host-push channel was added for this. (design §7 O-2: still lives on the menu
            // content's `.onChange`, not moved to `HostConnection` -- deferred, not dropped.)
            NotificationManager.shared.observe(newValue)
        }
        // NOTE: this used to be `.onChange(of: host.richStatus.pendingPairing)` auto-raising the
        // pairing window on the false -> true transition (workstream D). Removed as part of the
        // S3 pairing-DoS/hijack fix (see this struct's doc comment, amendment 5): that transition
        // fires for ANY pending session, including an attacker's phantom on the unauthenticated
        // `/pair` listener, which could pop the owner's pairing UI with no owner action at all.
        // `pendingPairing` now only drives the passive `pairRowTitle` badge below.
    }

    /// Passive badge (S3 pairing-DoS/hijack fix, amendment 5): a small suffix marking that at
    /// least one pairing request is currently pending, WITHOUT opening anything automatically.
    /// `host.richStatus.pendingPairing` mirrors `nvhttp::has_pending_pair_request()`, which counts
    /// ANY pending session (eligible or not) -- an attacker's background phantom can still light
    /// this badge, but that's informational awareness only now, never an auto-triggered window;
    /// clicking the row is what actually arms the eligibility window that makes a real pairing
    /// possible (`PairingSheet.onAppear` -> `HostConnection.beginPairingWindow()`).
    private var setupActionTitle: String {
        SetupMenuAction.title(
            setupComplete: firstRun.isComplete,
            pendingPairing: host.richStatus.pendingPairing
        )
    }

    private var setupActionAccessibilityLabel: String {
        guard firstRun.isComplete else { return "Finish Setup" }
        return host.richStatus.pendingPairing
            ? "Pair New Device — a device is waiting to pair"
            : "Pair New Device"
    }

    /// Design §1.1/§5.1's exact one-line status copy -- leads with the streaming client's name
    /// (falls back to a generic "Streaming" when the host hasn't reported one yet) plus res+codec
    /// while streaming (the full `<duration> · <resolution><fps> · <codec> · <Mbps>` line moved to
    /// the Settings window's Status pane so it fits the menu at any width).
    private var statusLine: String {
        MenuStatusLine.text(
            phase: host.status.menuPhase,
            streaming: host.richStatus.streaming,
            clientName: host.richStatus.clientName,
            height: host.richStatus.height,
            fps: host.richStatus.fps,
            encoder: host.richStatus.encoder,
            resumable: host.richStatus.resumable
        )
    }
}
