import SwiftUI

struct LiveSessionActionsView: View {
    var host: HostConnection
    @State private var target: RichStatus?
    @State private var ending = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if host.richStatus.streaming {
                if !host.richStatus.clientUUID.isEmpty, host.richStatus.sessionId > 0 {
                    Button(ending ? "Ending Session…" : "End Current Session…") { target = host.richStatus }
                        .disabled(ending || host.status != .connected)
                } else {
                    Text("The active device identity is unavailable. Restart or quit the host to end the connection.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.orange) }
        }
        .alert("End this connection?", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
            Button("Cancel", role: .cancel) { target = nil }.keyboardShortcut(.defaultAction)
            Button("End Session", role: .destructive) {
                guard let selected = target else { return }
                target = nil; ending = true
                Task {
                    let success = await host.endSession(sessionId: selected.sessionId, deviceUUID: selected.clientUUID)
                    ending = false
                    error = success ? nil : "The active session changed or could not be ended. Refresh Status and try again."
                }
            }
        } message: {
            Text("Disconnects \(target?.clientName.isEmpty == false ? target!.clientName : "this device"). Moonwalk Host stays ready for another connection and keeps device pairings.")
        }
    }
}
