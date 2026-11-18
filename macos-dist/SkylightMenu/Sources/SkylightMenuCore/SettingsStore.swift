import Foundation
import Observation

/// Serializes saves in user order, publishes only acknowledged values, and keeps failed
/// requests available for Retry. Shared by generic configuration and dedicated live setters.
@MainActor
@Observable
public final class SettingsStore {
    public struct Failure: Identifiable, Equatable {
        public var id: String { key }
        public let key: String
        public let label: String
        public let message: String
    }

    public private(set) var values: [String: String] = [:]
    public private(set) var failures: [String: Failure] = [:]
    public private(set) var pending: Set<String> = []
    public private(set) var revision = 0
    public var drafts: [String: String] = [:]
    public struct Conflict: Identifiable, Equatable {
        public var id: String { key }
        public let key: String
        public let local: String
        public let external: String?
    }
    public private(set) var conflicts: [String: Conflict] = [:]
    public private(set) var fileRevision = ""
    public private(set) var restartKeys: Set<String> = []
    private var serverValues: [String: String]?
    private var intents: [String: String] = [:]
    private var touched: [String: Int] = [:]
    private var latest: [String: Int] = [:]
    private var pendingOwners: [String: Set<Int>] = [:]
    private var tail: Task<Void, Never>?
    private var retries: [String: () -> Void] = [:]

    public init() {}

    public func acceptsSnapshot(key: String, startedAt: Int) -> Bool {
        !pending.contains(key) && (touched[key] ?? 0) <= startedAt
    }

    /// A read begun before a save must not overwrite its acknowledged result or pending edit.
    public func applySnapshot(_ snapshot: [String: String], startedAt: Int) {
        for key in Set(values.keys).union(snapshot.keys) where acceptsSnapshot(key: key, startedAt: startedAt) {
            values[key] = snapshot[key]
        }
    }

    /// External snapshots share the normal generation barrier, with visible conflicts for
    /// local drafts or pending writes. A refresh must never silently replace an edit.
    public func applyExternalSnapshot(_ snapshot: [String: String], running: [String: String],
                                      revision fileRevision: String, startedAt: Int) {
        guard startedAt == revision else {
            applySnapshot(snapshot, startedAt: startedAt)
            return
        }
        for key in Set(snapshot.keys).union(serverValues?.keys ?? Dictionary<String, String>().keys).union(conflicts.keys) {
            let local = drafts[key] ?? (pending.contains(key) ? intents[key] : nil)
            guard let local, local != snapshot[key] else {
                conflicts[key] = nil
                continue
            }
            if conflicts[key] != nil || (serverValues != nil && serverValues?[key] != snapshot[key]) {
                conflicts[key] = Conflict(key: key, local: local, external: snapshot[key])
            }
        }
        applySnapshot(snapshot, startedAt: startedAt)
        // Only a snapshot that began after our writes can describe the current file.
        if startedAt == revision {
            self.fileRevision = fileRevision
            serverValues = snapshot
            restartKeys = Set(snapshot.keys).union(running.keys)
                .intersection(RestartCoordinator.persistOnlyKeys.union(RestartCoordinator.liveConfigurationKeys))
                .filter { RestartCoordinator.configurationDiffers(key: $0, saved: snapshot[$0], running: running[$0]) }
        }
    }

    /// A refresh may have replaced the row or the user may have typed during its await.
    /// Never authorize an old choice using the newer configuration's revision.
    public func canResolve(_ selection: Conflict, originalDraft: String?) -> Bool {
        conflicts[selection.key] == selection && drafts[selection.key] == originalDraft
    }

    public func useExternalValue(for key: String) {
        guard let conflict = conflicts.removeValue(forKey: key) else { return }
        drafts[key] = nil
        values[key] = conflict.external
    }

    public func keepLocalValue(for key: String) -> String? {
        conflicts.removeValue(forKey: key)?.local
    }

    public func save(
        key: String, value: String, label: String,
        send: @escaping @MainActor () async -> String?,
        completion: @escaping @MainActor (Bool, String) -> Void = { _, _ in }
    ) {
        save(values: [key: value], operationKey: key, label: label, send: send, completion: completion)
    }

    /// One user choice can own several backing keys, with one transport outcome and Retry.
    public func save(
        values updates: [String: String], operationKey: String, label: String,
        send: @escaping @MainActor () async -> String?,
        completion: @escaping @MainActor (Bool, String) -> Void = { _, _ in }
    ) {
        revision += 1
        let token = revision
        latest[operationKey] = token
        let ownedKeys = Set(updates.keys).union([operationKey])
        for key in updates.keys { touched[key] = revision; intents[key] = updates[key] }
        for key in ownedKeys {
            pendingOwners[key, default: []].insert(token)
            pending.insert(key)
        }
        failures[operationKey] = nil
        retries[operationKey] = { [weak self] in
            self?.save(values: updates, operationKey: operationKey, label: label, send: send, completion: completion)
        }
        let previous = tail
        tail = Task {
            await previous?.value
            let error = await send()
            revision += 1
            for key in updates.keys { touched[key] = revision }
            if error == nil { values.merge(updates) { _, new in new } }
            // A compound save and a later single-key save can own the same key.
            // Only the last outstanding owner may release its snapshot barrier.
            for key in ownedKeys {
                pendingOwners[key]?.remove(token)
                if pendingOwners[key]?.isEmpty == true {
                    pendingOwners[key] = nil
                    pending.remove(key)
                }
            }
            if latest[operationKey] == token {
                failures[operationKey] = error.map { Failure(key: operationKey, label: label, message: $0) }
                if error == nil { retries[operationKey] = nil }
            }
            completion(error == nil, error ?? "")
        }
    }

    public func retry(key: String) { retries[key]?() }
    public func waitForPendingSaves() async {
        // An edit can be queued while an earlier save is suspended. Drain that new tail too.
        while !pending.isEmpty { await tail?.value }
    }

    /// Submit only an edited field; an explicit empty draft still means clear the override.
    nonisolated public static func submittedDraft(_ draft: String?) -> String? { draft }

    /// Clearing an older acknowledged draft must not discard text typed during that save.
    public static func shouldClearDraft(current: String?, submitted: String) -> Bool {
        current == submitted
    }
}
