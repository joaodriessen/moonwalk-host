import AppKit
import SwiftUI
import SkylightMenuCore

struct SoundTestView: View {
    var host: HostConnection
    var source: String
    @State private var permission = "unknown"
    @State private var token: String?
    @State private var result: SoundTestResult?
    @State private var error: String?
    @State private var requesting = false

    private var systemSource: Bool { source.isEmpty || ["system", "desktop", "screencapturekit"].contains(source.lowercased()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !systemSource, permission != "granted" {
                Text(permission == "restricted" ? "Microphone access is restricted for this Mac account." : "This input needs microphone access for the streaming host.").font(.callout)
                if permission == "notDetermined" {
                    Button(requesting ? "Waiting for permission…" : "Allow Microphone") {
                        requesting = true
                        Task { permission = await host.microphonePermission(request: true); requesting = false }
                    }.disabled(requesting || host.status != .connected)
                } else {
                    Button("Open Microphone Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                }
            }
            HStack {
                Button(token == nil ? "Test Sound" : "Testing…") { startTest() }
                    .disabled(token != nil || host.status != .connected || host.richStatus.streaming || (!systemSource && permission != "granted"))
                if let token {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { Task { await host.cancelSoundTest(token: token) } }
                }
            }
            if host.richStatus.streaming { Text("End the current stream before testing a sound source.").font(.caption).foregroundStyle(.secondary) }
            if let result {
                Text(result.source).font(.caption.weight(.semibold))
                Text(result.message).font(.callout)
                if let peak = result.peak { ProgressView(value: Double(min(1, max(0, peak)))).accessibilityLabel("Peak sound level") }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.orange) }
            Text("Plays nothing and saves no recording. Tests the selected source for two seconds after opening it; silent audio is reported separately from a permission or capture failure.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: source) { permission = await host.microphonePermission(); result = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { permission = await host.microphonePermission() }
        }
        .onDisappear { if let token { Task { await host.cancelSoundTest(token: token) } } }
    }

    private func startTest() {
        guard token == nil else { return }
        let id = UUID().uuidString
        let requested = source
        token = id; error = nil; result = nil
        Task {
            let reply = await host.testSound(source: requested, token: id)
            guard token == id else { return }
            token = nil
            result = requested == source ? reply : nil
            if reply == nil { error = "The sound test did not finish. Check the host connection and try again." }
        }
    }
}
