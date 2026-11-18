import AppKit
import SwiftUI
import SkylightMenuCore

struct PermissionChecklistView: View {
    var host: HostConnection
    var coordinator: PermissionSetupCoordinator

    private static let screenRecordingURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    private static let accessibilityURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            permissionRow(
                title: "Screen Recording",
                detail: "Streams what is on this Mac.",
                state: coordinator.state.screen,
                attempted: coordinator.attemptedScreenRecording,
                requesting: coordinator.requestingScreenRecording,
                allow: { coordinator.requestScreenRecording(host: host) },
                settingsURL: Self.screenRecordingURL
            )
            Divider()
            permissionRow(
                title: "Accessibility",
                detail: "Passes through keyboard and mouse input.",
                state: coordinator.state.accessibility,
                attempted: coordinator.attemptedAccessibility,
                requesting: coordinator.requestingAccessibility,
                allow: { coordinator.requestAccessibility(host: host) },
                settingsURL: Self.accessibilityURL
            )

            if coordinator.state.verifyingRestart || coordinator.awaitingReconnect {
                Label("Restarting the streaming host, then checking again…", lucide: .rotateCW, size: 14)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if host.status != .connected {
                Label("Starting Moonwalk Host before checking permissions…", lucide: .hourglass, size: 14)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let restartError = coordinator.restartError {
                Label(restartError, lucide: .triangleAlert, size: 14)
                    .font(.callout)
                    .foregroundStyle(.orange)
                Button("Try Restart Again") { coordinator.retryRestart(host: host) }
            }
        }
        .task { _ = await coordinator.refresh(host: host) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { _ = await coordinator.refresh(host: host) }
        }
        .onChange(of: host.status) { oldStatus, newStatus in
            coordinator.hostStatusChanged(from: oldStatus, to: newStatus, host: host)
        }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        detail: String,
        state: PermissionGrantState,
        attempted: Bool,
        requesting: Bool,
        allow: @escaping () -> Void,
        settingsURL: URL
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            LucideIcon(state == .granted ? .circleCheck : .circle, size: 20)
                .foregroundStyle(state == .granted ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                if state == .required, attempted {
                    Text("In System Settings, turn on Moonwalk Host.")
                        .font(.callout)
                    Button("Open System Settings") { NSWorkspace.shared.open(settingsURL) }
                        .buttonStyle(.link)
                }
            }
            Spacer(minLength: 12)
            switch state {
            case .checking:
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Checking \(title)")
            case .required:
                if requesting {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Requesting \(title)")
                } else {
                    Button("Allow", action: allow)
                        .disabled(host.status != .connected)
                        .accessibilityLabel("Allow \(title)")
                }
            case .granted:
                Text("Granted").font(.callout.weight(.semibold)).foregroundStyle(.green)
            }
        }
    }

}
