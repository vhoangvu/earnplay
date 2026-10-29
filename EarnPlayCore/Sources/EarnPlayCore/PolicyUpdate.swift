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

/// The T4.1 save pipeline: draft → versioned update → admin-local
/// persistence + pending queue for T4.6 sync.
///
/// The editor edits a full `Policy` value as its draft — never a
/// parallel struct with a subset of fields — so no LLD §2.1 field can
/// be silently dropped on save: every field the draft carries is
/// carried into the update. `save` stamps `baseVersion + 1` whatever
/// version the draft itself holds, persists the update as the admin's
/// current policy, and appends it to the pending queue in creation
/// order. T4.6 drains the queue; this task only enqueues.
public enum PolicyEditorSave {
    /// Builds the versioned update for a draft edited over `baseVersion`.
    public static func updatedPolicy(draft: Policy, baseVersion: Int) -> PolicyUpdate {
        draft.withVersion(baseVersion + 1)
    }

    /// Saves a draft: bumps the version, persists the update as the
    /// admin's current policy, enqueues it for sync, and returns the
    /// update together with its serialized form.
    ///
    /// - Parameters:
    ///   - draft: The edited policy. Its own `version` is ignored; the
    ///     update is stamped `adminStore.storedVersion + 1`.
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
        let update = updatedPolicy(draft: draft, baseVersion: adminStore.storedVersion)
        let data = try PolicyUpdateCodec.encode(update)
        // Persist first so a queue-write failure still leaves the
        // admin's current policy advanced; the queue write then makes
        // the update deliverable. `apply` cannot reject here: the
        // update is by construction one version above the store.
        _ = adminStore.apply(update)
        try queue.enqueue(update)
        return (update, data)
    }
}
