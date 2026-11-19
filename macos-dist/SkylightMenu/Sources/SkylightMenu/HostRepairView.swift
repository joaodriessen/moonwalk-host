import SwiftUI

struct HostRepairView: View {
    var host: HostConnection
    @State private var confirm = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = host.startupError {
                Text("Startup error: \(error)").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            Text("Checks the installation and starts the background service again. Your settings and paired devices are kept.")
                .font(.caption).foregroundStyle(.secondary)
            Button(host.repairingService ? "Repairing Host…" : "Repair Streaming Host…") {
                confirm = true
            }.disabled(host.repairingService)
            if host.repairingService { ProgressView().controlSize(.small) }
            if let message = host.repairMessage { Text(message).font(.callout).textSelection(.enabled) }
        }
        .alert("Repair the streaming host?", isPresented: $confirm) {
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
            Button("Repair and Restart", role: .destructive) { Task { await host.repairHostService() } }
        } message: {
            Text("Repair restarts the streaming service and ends any active stream. Your settings and paired devices are kept.")
        }
    }
}
