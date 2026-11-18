import SwiftUI
import SkylightMenuCore

struct ConfigurationSnapshotsView: View {
    var host: HostConnection
    @State private var snapshots: [ConfigurationSnapshot] = []
    @State private var name = ""
    @State private var preview: ConfigurationSnapshot?
    @State private var previewRevision = ""
    @State private var previewChanges: [ConfigurationSnapshot.Change] = []
    @State private var busy = false
    @State private var message: String?

    private var files: ConfigurationSnapshots {
        ConfigurationSnapshots(directory: SkylightDataPaths.configuration(home: FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("settings-snapshots", isDirectory: true))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Setup name", text: $name)
                .textFieldStyle(.roundedBorder)
            Button("Save Current Setup") { Task { await save() } }
                .disabled(busy || host.status != .connected || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ForEach(snapshots) { item in
                HStack {
                    VStack(alignment: .leading) {
                        Text(item.name)
                        Text(Date(timeIntervalSince1970: item.createdAt), style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Review Restore…") { Task { await review(item) } }.disabled(busy || host.status != .connected)
                }
            }
            if snapshots.isEmpty { Text("No saved setups yet.").font(.callout).foregroundStyle(.secondary) }
            if busy { ProgressView().controlSize(.small) }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            Text("Saves host settings only. Paired devices, certificates, credentials, commands and unrelated files are kept separate. Restoring makes a recovery snapshot first; restart the host to apply saved changes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { reload() }
        .sheet(item: $preview) { item in
            VStack(alignment: .leading, spacing: 14) {
                Text("Restore “\(item.name)”?").font(.title2)
                Text("Review the saved configuration changes. A missing value restores the host default. Current device pairings are kept.").foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(previewChanges) { change in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(change.key).font(.headline)
                                Text("\(display(change.before)) → \(display(change.after))").textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if previewChanges.isEmpty { Text("This setup already matches the saved configuration.") }
                HStack {
                    Button("Cancel", role: .cancel) { preview = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Restore Setup") { Task { await restore(item) } }
                        .disabled(busy || previewChanges.isEmpty)
                }
            }.padding(24).frame(width: 560, height: 440)
        }
    }

    private func display(_ value: String?) -> String { value.map { $0.isEmpty ? "Empty" : $0 } ?? "Default" }
    private func reload() {
        do { snapshots = try files.load() }
        catch { message = "Couldn’t read saved setups: \(error.localizedDescription)" }
    }
    private func prepare() async -> Bool {
        await host.settings.waitForPendingSaves()
        await host.refreshExternalConfiguration(force: true)
        guard host.status == .connected, host.externalRefreshError == nil, !host.settings.fileRevision.isEmpty, !host.snapshotKeys.isEmpty else {
            message = "Settings are unavailable. Refresh and try again."; return false
        }
        guard host.settings.drafts.isEmpty, host.settings.conflicts.isEmpty else {
            message = "Finish or resolve your current edits first. Your edits have been kept."; return false
        }
        return true
    }
    private func save() async {
        busy = true; defer { busy = false }
        guard await prepare() else { return }
        do {
            let snapshot = ConfigurationSnapshot(name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)),
                values: host.configValues.filter { host.snapshotKeys.contains($0.key) })
            try files.save(snapshot); name = ""; message = "Setup saved."; reload()
        } catch { message = "Couldn’t save the setup: \(error.localizedDescription)" }
    }
    private func review(_ item: ConfigurationSnapshot) async {
        busy = true; defer { busy = false }
        guard await prepare() else { return }
        previewRevision = host.settings.fileRevision
        previewChanges = item.changes(from: host.configValues, keys: host.snapshotKeys)
        preview = item
    }
    private func restore(_ item: ConfigurationSnapshot) async {
        busy = true; defer { busy = false; reload() }
        let error = await host.restoreConfiguration(item, expectedRevision: previewRevision)
        preview = nil
        message = error ?? "Setup restored. A “Before restore” recovery setup was saved. Restart Moonwalk Host to apply any pending changes."
    }
}
