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
        case .moveToApplications: "Drag Moonwalk Host into Applications, then open that copy."
        case .creatingConfiguration: "Preparing settings for this Mac."
        case .registerService: "Setting up the background streaming service."
        case .approveService: "Turn on Moonwalk Host in Login Items so it can start the streaming service."
        case .waitingForHost: "Waiting for the streaming service to start."
        case .permissions: "Allow Screen Recording to share the desktop and Accessibility to use the keyboard and mouse from another device."
        case .readyToPair: "Open Moonwalk on Linux or a Moonlight client on another device. Select “\(host.advertisedName)” there to get a PIN. Then click Pair a Device here."
        case .failed(let detail): detail
        case .complete: "You can connect from a paired device on your network."
        case .evaluating: "Checking the streaming service and macOS permissions."
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
            Link("Get Moonwalk for Linux", destination: URL(string:
                "https://github.com/joaodriessen/moonwalk/blob/main/docs/guides/getting-started.md#install-moonwalk")!)
                .font(.footnote)
            Text("You can also pair later from the Moonwalk Host menu.").font(.footnote).foregroundStyle(.secondary)
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
