import Foundation

/// A policy update queued for sync to the child app (LLD §8.1, T4.1).
///
/// Per LLD §8.1 a `PolicyUpdate` is the full `Policy` record with its
/// version — not a diff. The child applies it only when its version is
/// higher than the stored version (`PolicyStore.apply`), so the save
/// pipeline below always stamps `baseVersion + 1` and never reuses a
/// version (LLD §8.2).
public typealias PolicyUpdate = Policy

/// Encoding for `PolicyUpdate` payloads handed to sync (T4.6).
///
/// Uses the same `Codable` representation and date strategy as
/// `PolicyStore` (`.deferredToDate`, which preserves fractional seconds
/// in chore expiries), so anything this codec writes the child's store
/// can read back. Keys are sorted for stable, diffable output.
public enum PolicyUpdateCodec {
    /// Serializes a policy update for the sync queue / transport.
    public static func encode(_ update: PolicyUpdate) throws -> Data {
        try encodeValue(update)
    }

    /// Serializes a list of updates (the persisted queue file).
    public static func encode(_ updates: [PolicyUpdate]) throws -> Data {
        try encodeValue(updates)
    }

    private static func encodeValue(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    /// Decodes a policy update produced by `encode(_:)`.
    public static func decode(_ data: Data) throws -> PolicyUpdate {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return try decoder.decode(PolicyUpdate.self, from: data)
    }
}

/// Failures of `PolicyEditorSave.save` that originate in the admin
/// `PolicyStore` write. Queue-write failures propagate as the
/// underlying file error, with the save-intent journal left behind
/// for relaunch recovery.
public enum PolicyEditorSaveError: Error, Equatable {
    /// Another live store instance advanced the persisted policy past
    /// the stamped version (stale in-memory read): nothing was queued
    /// and the store is unchanged by this save. Reload and retry.
    case staleVersion(currentVersion: Int, attemptedVersion: Int)
    /// The update was newer but could not be persisted: nothing was
    /// queued and the store still holds `currentVersion`, so retrying
    /// the same draft re-stamps the same version instead of skipping.
    case persistenceFailed(currentVersion: Int, attemptedVersion: Int)
}

/// The T4.1 save pipeline: draft → versioned update → admin-local
/// persistence + pending queue for T4.6 sync.
///
/// The editor edits a full `Policy` value as its draft — never a
/// parallel struct with a subset of fields — so no LLD §2.1 field can
/// be silently dropped on save: every field the draft carries is
/// carried into the update. `save` stamps one above the highest
/// version it can see, persists the update as the admin's current
/// policy, and appends it to the pending queue in creation order.
/// T4.6 drains the queue; this task only enqueues.
///
/// Durability: the update is journaled to the queue's save-intent
/// file before the store write, so a stop between the policy write
/// and the queue write recovers on relaunch (the next queue opened
/// over the directory re-merges the intent) instead of needing
/// another manual save. See `recoverInterruptedSave`.
public enum PolicyEditorSave {
    /// Builds the versioned update for a draft edited over `baseVersion`.
    public static func updatedPolicy(draft: Policy, baseVersion: Int) -> PolicyUpdate {
        draft.withVersion(baseVersion + 1)
    }

    /// Recovers an interrupted save, if any. Best-effort and never
    /// throws: failures leave the intent journal for a later attempt,
    /// and the caller's own writes will surface persistent breakage.
    ///
    /// - An intent older than the store is obsolete (a later save
    ///   superseded it) and is dropped without enqueueing.
    /// - An intent newer than the store means the stop happened before
    ///   the policy write: the store catches up first, so the queue
    ///   never runs ahead of the policy it delivers.
    /// - An intent equal to the store means the stop happened between
    ///   the policy write and the queue write: the intent is merged
    ///   into the queue, then cleared.
    public static func recoverInterruptedSave(
        adminStore: PolicyStore,
        queue: PolicyUpdateQueue
    ) {
        guard let intent = queue.loadSaveIntent() else { return }
        let stored = adminStore.storedVersion
        if intent.version < stored {
            queue.clearSaveIntent(matching: intent)
            return
        }
        if intent.version > stored {
            let result = adminStore.apply(intent)
            guard result == .applied else {
                // Stale (a concurrent save advanced past the intent):
                // obsolete, drop it. Persistence still failing: leave
                // the intent for a later attempt.
                if case .rejectedStaleVersion = result {
                    queue.clearSaveIntent(matching: intent)
                }
                return
            }
        }
        guard (try? queue.enqueue(intent)) != nil else { return }
        queue.clearSaveIntent(matching: intent)
    }

    /// Saves a draft: bumps the version, persists the update as the
    /// admin's current policy, enqueues it for sync, and returns the
    /// update together with its serialized form.
    ///
    /// The update is stamped one above the higher of the admin store
    /// version and the latest pending queue version. Normally those
    /// agree and this is exactly `storedVersion + 1`; the queue side
    /// only matters after a recovered crash left the queue ahead of
    /// the store with its intent lost, where re-stamping the store
    /// version would reuse a version the child may already hold.
    ///
    /// The update is journaled before the store write and the store
    /// result is required to be `.applied` before enqueueing: a stale
    /// or failed policy write throws `PolicyEditorSaveError` without
    /// queueing anything, so the next save stamps the same version
    /// again instead of letting the child reject later edits as
    /// stale. A queue-write failure throws with the journal left
    /// behind, so relaunch recovery still delivers the saved version.
    ///
    /// - Parameters:
    ///   - draft: The edited policy. Its own `version` is ignored.
    ///   - adminStore: The admin app's local policy record (the authored
    ///     policy; the child never edits policy).
    ///   - queue: The pending-update queue T4.6 drains.
    /// - Returns: The versioned update and its serialized bytes.
    @discardableResult
    public static func save(
        draft: Policy,
        adminStore: PolicyStore,
        queue: PolicyUpdateQueue
    ) throws -> (update: PolicyUpdate, serialized: Data) {
        recoverInterruptedSave(adminStore: adminStore, queue: queue)
        let base = max(adminStore.storedVersion, queue.latestPendingVersion ?? 0)
        let update = updatedPolicy(draft: draft, baseVersion: base)
        let data = try PolicyUpdateCodec.encode(update)
        try queue.writeSaveIntent(update)
        switch adminStore.apply(update) {
        case .applied:
            break
        case .rejectedStaleVersion(let current):
            queue.clearSaveIntent(matching: update)
            throw PolicyEditorSaveError.staleVersion(
                currentVersion: current, attemptedVersion: update.version
            )
        case .persistenceFailed(let current):
            queue.clearSaveIntent(matching: update)
            throw PolicyEditorSaveError.persistenceFailed(
                currentVersion: current, attemptedVersion: update.version
            )
        }
        do {
            try queue.enqueue(update)
        } catch {
            // The policy is durable but not yet queued: leave the
            // intent journal so relaunch recovery delivers it.
            throw error
        }
        queue.clearSaveIntent(matching: update)
        return (update, data)
    }
}
