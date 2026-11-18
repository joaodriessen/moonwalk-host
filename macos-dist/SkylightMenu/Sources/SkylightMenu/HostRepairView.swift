import SwiftUI

struct HostRepairView: View {
    var host: HostConnection
    @State private var confirm = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = host.startupError {
                Text("Observed startup error: \(error)").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            Text("Checks the installed host and background registration, then waits for a fresh connection. Settings and paired devices are kept. An unavailable XPC connection alone does not identify its cause.")
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
            Text("Checks the current installation and registration, then restarts the streaming host. Any current stream ends. Your settings and paired devices are kept.")
        }
    }
}
