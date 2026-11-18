import Foundation
@preconcurrency import UserNotifications

/// S3 "native touches" -- UserNotifications (docs/design/menubar-app.md "S3"). Requests
/// authorization once, then raises local notifications for:
///   1. A streaming-state TRANSITION (idle -> streaming) or a new client while already
///      streaming, derived from `HostConnection`'s periodic `richStatus` poll.
///   2. The outcome of a Restart Host / Run Rescue action (`HostProcessActions`).
///
/// HONESTY (per the design brief): "Full host-push event channel over XPC is nice-to-have; for
/// S3, deriving from the existing status poll is acceptable and honest." No new host-push
/// surface was added for this -- everything here is derived client-side from data the app
/// already pulls, not a daemon-originated event.
///
/// Workstream D adds a third transition to the same poll-derived pattern: a pairing request
/// (idle -> pendingPairing) fires one notification on the rising edge, mirroring how streaming
/// transitions are detected below -- no daemon-side push, no new mechanism.
@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private var authorized = false
    private var lastStreaming = false
    private var lastClientName = ""
    private var lastPendingPairing = false

    private init() {}

    /// Call once on app launch. Requests authorization only if the user has never been asked
    /// (`.notDetermined`) -- never re-prompts, and gracefully leaves `authorized == false` if
    /// the user denies or has denied previously, so every notification call below silently
    /// no-ops rather than erroring.
    func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    Task { @MainActor in self.authorized = granted }
                }
            case .authorized, .provisional:
                Task { @MainActor in self.authorized = true }
            case .denied, .ephemeral:
                fallthrough
            @unknown default:
                Task { @MainActor in self.authorized = false }
            }
        }
    }

    /// Feed every `richStatus` update through here (see `ContentView`'s `onChange`). Raises
    /// "Streaming started" on an idle -> streaming transition, "Client connected" if the client
    /// name changes while already streaming, and "A device wants to pair" on a pairing-request
    /// rising edge (workstream D). Never fabricates an event the poll didn't actually observe --
    /// a poll gap (e.g. host briefly offline) just means a transition might be missed, not that a
    /// false one is invented.
    func observe(_ status: RichStatus) {
        defer {
            lastStreaming = status.streaming
            lastClientName = status.clientName
            lastPendingPairing = status.pendingPairing
        }
        guard authorized else { return }

        if status.pendingPairing, !lastPendingPairing {
            notify(title: "A device wants to pair", body: "Open Moonwalk Host to enter the PIN.")
        }

        if status.streaming, !lastStreaming {
            let body = status.clientName.isEmpty ? "A client connected." : "\(status.clientName) connected."
            notify(title: "Streaming started", body: body)
        } else if status.streaming, lastStreaming,
                  !status.clientName.isEmpty, status.clientName != lastClientName {
            notify(title: "Client connected", body: status.clientName)
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
