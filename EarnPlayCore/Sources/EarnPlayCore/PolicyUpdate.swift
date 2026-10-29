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
    /// A previous save's intent is still unresolved: version
    /// `intentVersion` is durable in (or owed to) the store but not
    /// yet durably queued, and recovery could not finish it because a
    /// write is still failing. The new save is aborted before
    /// journaling anything, so it cannot overwrite the only record of
    /// the missing version. Fix the underlying failure and retry —
    /// recovery delivers the pending version first.
    case unresolvedIntent(intentVersion: Int)
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
/// and the queue write is recovered by `recoverInterruptedSave`
/// (run at editor launch and at the start of every save) instead of
/// needing another manual save.
public enum PolicyEditorSave {
    /// Builds the versioned update for a draft edited over `baseVersion`.
    public static func updatedPolicy(draft: Policy, baseVersion: Int) -> PolicyUpdate {
        draft.withVersion(baseVersion + 1)
    }

    /// Recovers an interrupted save, if any. Best-effort and never
    /// throws: failures leave the intent journal for a later attempt,
    /// and the caller's own writes will surface persistent breakage.
    ///
    /// The whole recovery runs inside the queue's save-transaction
    /// lock, serialized with every save over the same directory, and
    /// compares against the durable store (re-read from disk, never
    /// the instance cache):
    ///
    /// - An intent older than the store is obsolete (a later save
    ///   superseded it) and is dropped without enqueueing.
    /// - An intent newer than the store means the stop happened
    ///   before (or during) the policy write: the store catches up
    ///   first, and the intent is queued only after the store
    ///   confirms it — never before, so a store write that never
    ///   persisted is never deliverable.
    /// - An intent equal to the store version merges only when its
    ///   full policy equals the durable policy (the stop happened
    ///   between the policy write and the queue write). A
    ///   same-version intent with different content is a stale
    ///   instance's rejected save and is discarded without merging.
    public static func recoverInterruptedSave(
        adminStore: PolicyStore,
        queue: PolicyUpdateQueue
    ) {
        // A transaction that cannot even start (lock file unusable)
        // leaves the intent for a later attempt, like any failure.
        try? queue.withSaveTransaction {
            recoverLocked(adminStore: adminStore, queue: queue)
        }
    }

    /// Recovery body; the caller holds the queue's save-transaction
    /// lock (taken once — the lock is not re-entrant).
    private static func recoverLocked(
        adminStore: PolicyStore,
        queue: PolicyUpdateQueue
    ) {
        guard let intent = queue.loadSaveIntent() else { return }
        let durable = adminStore.reloadFromDisk()
        if intent.version < durable.version {
            queue.clearSaveIntent(matching: intent)
            return
        }
        if intent.version == durable.version {
            guard intent == durable else {
                queue.clearSaveIntent(matching: intent)
                return
            }
            guard (try? queue.enqueue(intent)) != nil else { return }
            queue.clearSaveIntent(matching: intent)
            return
        }
        switch adminStore.apply(intent) {
        case .applied:
            break
        case .rejectedStaleVersion:
            // A writer outside the save pipeline advanced the store
            // past the intent between our reload and the apply (every
            // pipeline writer holds the transaction): re-read before
            // deciding. Only this exact committed payload still needs
            // queueing; anything else is obsolete or conflicting.
            if intent == adminStore.reloadFromDisk() {
                guard (try? queue.enqueue(intent)) != nil else { return }
            }
            queue.clearSaveIntent(matching: intent)
            return
        case .persistenceFailed:
            return
        }
        guard (try? queue.enqueue(intent)) != nil else { return }
        queue.clearSaveIntent(matching: intent)
    }

    /// Saves a draft: bumps the version, persists the update as the
    /// admin's current policy, enqueues it for sync, and returns the
    /// update together with its serialized form.
    ///
    /// The update is stamped one above the higher of the durable
    /// admin store version and the durable latest pending queue
    /// version, both re-read inside the save transaction, so two
    /// saves over the same directory never stamp the same version.
    /// Normally those agree and this is exactly `storedVersion + 1`;
    /// the queue side only matters after a recovered crash left the
    /// queue ahead of the store with its intent lost, where
    /// re-stamping the store version would reuse a version the child
    /// may already hold.
    ///
    /// The update is journaled before the store write and the store
    /// result is required to be `.applied` before enqueueing: a stale
    /// or failed policy write throws `PolicyEditorSaveError` without
    /// queueing anything, so the next save stamps the same version
    /// again instead of letting the child reject later edits as
    /// stale. A queue-write failure throws with the journal left
    /// behind, so relaunch recovery still delivers the saved version.
    /// If a previous save's intent is still unresolved after recovery
    /// (a write is still failing), the save aborts with
    /// `unresolvedIntent` before journaling anything, preserving the
    /// only record of the missing version.
    ///
    /// The whole save — recovery, version allocation, journaling,
    /// store application, enqueueing, and cleanup — runs inside the
    /// queue's save-transaction lock, serialized with every other
    /// save and recovery over the same directory.
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
        try queue.withSaveTransaction {
            try saveLocked(draft: draft, adminStore: adminStore, queue: queue)
        }
    }

    /// Save body; the caller holds the queue's save-transaction lock
    /// (taken once — the lock is not re-entrant).
    private static func saveLocked(
        draft: Policy,
        adminStore: PolicyStore,
        queue: PolicyUpdateQueue
    ) throws -> (update: PolicyUpdate, serialized: Data) {
        recoverLocked(adminStore: adminStore, queue: queue)
        // Recovery that could not finish (a write is still failing)
        // leaves the intent behind: abort before journaling so the new
        // version cannot overwrite the only record of it.
        if let intent = queue.loadSaveIntent() {
            throw PolicyEditorSaveError.unresolvedIntent(
                intentVersion: intent.version
            )
        }
        let stored = adminStore.reloadFromDisk().version
        let pending = try queue.latestDurablePendingVersion() ?? 0
        let base = max(stored, pending)
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
