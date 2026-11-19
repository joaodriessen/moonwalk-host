import SwiftUI
import AppKit
import SkylightMenuCore

/// Menu-bar status and actions. Pairing opens as a sheet in Settings after the
/// user chooses Pair New Device. A pending request only updates the menu label.
struct MenuContent: View {
    var host: HostConnection
    var pairing: PairingPresentation
    var firstRun: FirstRunCoordinator
    var permissionSetup: PermissionSetupCoordinator
    var quitConfirmation: QuitConfirmation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            // This row reports status and has no action.
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
                // Request a graceful shutdown before quitting the menu app.
                // The daemon also shuts down when it loses its validated peer.
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
            NotificationManager.shared.observe(newValue)
        }
    }

    /// The label reports pending requests. Opening the sheet arms pairing.
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

    /// Keep the menu status on one line. Settings shows full session details.
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
