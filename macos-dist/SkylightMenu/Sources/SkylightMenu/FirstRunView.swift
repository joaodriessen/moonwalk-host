import AppKit
import SwiftUI
import SkylightMenuCore

struct FirstRunView: View {
    var coordinator: FirstRunCoordinator
    var host: HostConnection
    var pairing: PairingPresentation
    var permissionSetup: PermissionSetupCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.semibold))
            Text(message).foregroundStyle(.secondary)
            action
        }
        .padding(24)
        .frame(width: 420)
        .background(WindowRestorationDisabler())
        .task {
            refreshFirstRun()
            if host.status == .connected {
                _ = await permissionSetup.refresh(host: host)
                refreshFirstRun()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                if host.status == .connected { _ = await permissionSetup.refresh(host: host) }
                refreshFirstRun()
            }
        }
        .onChange(of: host.status) { oldValue, status in
            Task {
                permissionSetup.hostStatusChanged(from: oldValue, to: status, host: host)
                if status == .connected { _ = await permissionSetup.refresh(host: host) }
                refreshFirstRun()
            }
        }
        .onChange(of: permissionSetup.firstRunPermissionState) { _, _ in
            refreshFirstRun()
        }
    }

    private var title: String {
        switch coordinator.state.phase {
        case .moveToApplications: "Move Moonwalk Host to Applications"
        case .creatingConfiguration: "Preparing Moonwalk Host"
        case .registerService: "Starting the streaming host"
        case .approveService: "Allow Moonwalk Host in Login Items"
        case .waitingForHost: "Starting Moonwalk Host"
        case .permissions: "Allow Moonwalk Host"
        case .readyToPair: "Pair your first device"
        case .failed: "Setup needs attention"
        case .complete: "Moonwalk Host is ready"
        case .evaluating: "Checking Moonwalk Host"
        }
    }

    private var message: String {
        switch coordinator.state.phase {
        case .moveToApplications: "Drag Moonwalk Host into Applications, then open that copy. This lets macOS manage its background service reliably."
        case .creatingConfiguration: "Creating private defaults without replacing any existing settings."
        case .registerService: "Registering the bundled, on-demand host. It runs only when Moonwalk Host needs it."
        case .approveService: "macOS needs your approval before Moonwalk Host can start its bundled host."
        case .waitingForHost: "Waiting for the signed streaming host to connect."
        case .permissions: "Moonwalk Host needs Screen Recording and Accessibility to stream and control this Mac."
        case .readyToPair: "On your other device, open Moonwalk or Moonlight on the same local network. Select “\(host.advertisedName)”, choose Pair, then enter the PIN on this Mac. If it does not appear, use Add Host on the client with this Mac’s local network address."
        case .failed(let detail): detail
        case .complete: "Setup is complete."
        case .evaluating: "Checking the app, host, and permissions."
        }
    }

    @ViewBuilder private var action: some View {
        switch coordinator.state.phase {
        case .moveToApplications:
            Button("Open Applications") { coordinator.openApplications() }
        case .approveService:
            Button("Open Login Items") { coordinator.openApprovalSettings() }
        case .permissions:
            PermissionChecklistView(host: host, coordinator: permissionSetup)
        case .readyToPair:
            ConnectionHandoffView(host: host)
            HStack {
                Button("Finish Setup") {
                    coordinator.finish()
                    dismissWindow(id: SkylightMenuApp.firstRunWindowID)
                }
                Button("Pair a Device") {
                    coordinator.finish()
                    pairing.present(using: openWindow)
                    dismissWindow(id: SkylightMenuApp.firstRunWindowID)
                }.keyboardShortcut(.defaultAction)
            }
            Text("This Mac is ready. You can pair a device later from the Moonwalk Host menu.")
                .font(.footnote).foregroundStyle(.secondary)
        case .failed:
            HostRepairView(host: host)
            Button("Try Again") {
                host.connect()
                coordinator.retry(permissionState: permissionSetup.firstRunPermissionState, hostAvailability: host.firstRunAvailability)
                refreshFirstRun()
            }
        case .complete:
            Button("Done") { dismissWindow(id: SkylightMenuApp.firstRunWindowID) }
        case .waitingForHost:
            HStack {
                ProgressView().controlSize(.small)
                Button("Try Again") {
                    host.connect()
                    refreshFirstRun()
                }
            }
        default:
            ProgressView().controlSize(.small)
        }
    }

    private func refreshFirstRun() {
        let availability: FirstRunEnvironment.HostAvailability = permissionSetup.awaitingReconnect
            ? .connecting
            : host.firstRunAvailability
        coordinator.refresh(
            permissionState: permissionSetup.firstRunPermissionState,
            hostAvailability: availability
        )
    }
}
