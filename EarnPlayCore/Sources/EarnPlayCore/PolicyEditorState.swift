import Foundation

/// Load/save state behind the admin `PolicyEditorView` (T4.1).
///
/// The view keeps this as `@State` and renders it. The procedures live
/// here — rather than inline in the view — so the failure-refresh
/// behavior is unit-testable in `EarnPlayCoreTests`: on a failed save
/// the committed version and pending count refresh from durable state,
/// the previous success status clears, and the draft is kept for the
/// retry instead of being discarded.
public struct PolicyEditorState: Sendable {
    public var draft: Policy = .defaultPolicy
    public var baseVersion: Int = 0
    public var pendingCount: Int = 0
    public var statusText: String = ""
    public var errorText: String = ""
    public var isLoaded: Bool = false

    public init() {}

    /// Loads the last-saved policy into the draft, recovering any save
    /// interrupted between the policy write and the queue write first
    /// (relaunch recovery, no manual re-save needed).
    public mutating func reload(
        adminStore: PolicyStore,
        queue: PolicyUpdateQueue
    ) {
        PolicyEditorSave.recoverInterruptedSave(adminStore: adminStore, queue: queue)
        let current = adminStore.currentPolicy
        draft = current
        baseVersion = current.version
        pendingCount = queue.pendingUpdates().count
        errorText = ""
        isLoaded = true
    }

    /// Saves the draft: bumps the version, persists the admin's copy,
    /// and queues the update for sync.
    ///
    /// On failure the committed version and pending count still refresh
    /// from durable state — the store may have advanced before the
    /// failure (e.g. the policy write succeeded and only enqueueing
    /// threw), so showing the stale pre-save version would promise a
    /// version the retry cannot create. The previous success status
    /// clears; the draft is kept untouched for the retry.
    public mutating func save(
        adminStore: PolicyStore,
        queue: PolicyUpdateQueue
    ) {
        errorText = ""
        do {
            let (update, _) = try PolicyEditorSave.save(
                draft: draft, adminStore: adminStore, queue: queue
            )
            draft = update
            baseVersion = update.version
            pendingCount = queue.pendingUpdates().count
            statusText = "Saved version \(update.version) — queued for sync (\(pendingCount) pending)."
        } catch {
            // The store may have advanced before the failure (the
            // policy write succeeded and only enqueueing threw), so
            // refresh from durable state instead of showing the stale
            // pre-save version; the draft is kept untouched for the
            // retry and the previous success status clears.
            baseVersion = adminStore.reloadFromDisk().version
            pendingCount = queue.pendingUpdates().count
            statusText = ""
            errorText = "Save failed: \(String(describing: error))"
        }
    }
}
