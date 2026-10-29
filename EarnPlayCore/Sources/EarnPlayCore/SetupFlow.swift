import Foundation

/// Guided first-run setup flow for the child device (T2.3).
///
/// Walks a fresh install through the ordered steps the Demo requires:
///
/// 1. `authorization` — FamilyControls authorization in Screen Time.
/// 2. `enumeration` — FamilyActivityPicker enumeration of the apps (and
///    categories) on the device.
/// 3. `selection` — the parent splits the enumerated apps into the
///    allowlist (never blocked) and the unblockable list (a completed
///    challenge may open them). Everything else enumerated stays blocked
///    with no challenge offered.
/// 4. `preventDeletingGuidance` — prevent-deleting-apps guidance so the
///    child app cannot simply be removed.
/// 5. `complete` — the initial policy is written and shields are applied.
///
/// The machine is strictly ordered: no step can be skipped. Every mutating
/// method reports whether it advanced the flow and leaves all state
/// untouched when its prerequisites are unmet — in particular, advancing
/// without authorization is impossible, and shields stay inactive until
/// the flow completes.
///
/// Completion is a single atomic commit: the enumeration is persisted,
/// then the initial policy (version snapshot + 1, keeping every existing
/// field except the setup selections) is written to `PolicyStore`, then
/// the enumeration is handed to `ShieldManager`, which shields every
/// enumerated app except the allowlist (enumeration-first) with the picked
/// categories as the backstop for newly installed apps. The commit also
/// clears the incomplete restrictive record below: the staged enumeration
/// replaces all prior incomplete restrictions.
/// If the policy write fails, the just-written enumeration is rolled back
/// (the previous content, if any, is restored), so a failed commit never
/// leaves a policy/enumeration pair behind that a relaunch could mistake
/// for a completed setup.
/// Before that commit, every accepted enumeration is persisted (merged
/// with prior incomplete picks) as a distinctly-incomplete restrictive
/// record, and abandoning merges the staged enumeration forward into that
/// record and applies the merged configuration (default-deny — every
/// picked app shielded under the current policy), so terminating the app
/// or abandoning mid-flow never loses protection and an aborted retry
/// never loosens prior restrictions. The incomplete record is restored on
/// relaunch (shields applied, flow still incomplete) and can never confer
/// completion: persisting over a stored policy is refused, and completing
/// still requires the completion enumeration plus a stored policy. An
/// incomplete flow never claims the protection of a completed one. Once a
/// policy exists, unknown apps are governed by T2.5's default-deny rule (a
/// later task; only the handoff is stated here).
///
/// A completed setup survives relaunch, but only while Screen Time access
/// is still approved: a new `SetupFlow` over the same stores starts at
/// `complete` and re-applies the persisted enumeration to its
/// `ShieldManager` only when the `authorized` seed (the app's current
/// system status at launch) confirms access. With a committed
/// policy/enumeration pair on disk but no current approval, the flow
/// starts at `authorization` with `needsReauthorization` true and applies
/// no shields; re-granting restores completion without re-running the
/// picker, and abandoning never destroys the committed pair.
///
/// ## Framework-free boundary and verification status
///
/// Like `ShieldManager`, this file has no FamilyControls /
/// ManagedSettings dependency: authorization results and picker output
/// arrive as plain values (`recordAuthorization(granted:)`,
/// `submitEnumeration(_:)`), so the state machine runs in host tests
/// without any entitlement. The child app owns the mapping from picker
/// tokens to `AppRef` identifiers and drives this machine from its UI.
///
/// Demo verification runs against a simulated `ShieldBackend` (see
/// `SetupFlowTests`) — the simulated path T2.4 provides. The
/// FamilyControls distribution entitlement is NOT filed, so real
/// authorization cannot be granted on device and real shield enforcement
/// is NOT verified by this task and must never be claimed as working
/// without the entitlement.
public enum SetupStep: String, Codable, Equatable, Sendable {
    /// Awaiting FamilyControls authorization.
    case authorization
    /// Awaiting FamilyActivityPicker enumeration.
    case enumeration
    /// Awaiting the allowlist / unblockable split of the enumerated apps.
    case selection
    /// Awaiting acknowledgement of the prevent-deleting-apps guidance.
    case preventDeletingGuidance
    /// Initial policy written and shields applied.
    case complete
}

/// Outcome of acknowledging the prevent-deleting-apps guidance, which is
/// the commit point of the setup flow.
public enum SetupFinishResult: Equatable, Sendable {
    /// The enumeration was persisted, the initial policy was written, and
    /// shields were applied. The flow is now complete.
    case finished
    /// A prerequisite was missing (wrong step, no authorization, or no
    /// staged enumeration/selections). Nothing was written or applied.
    case notReady
    /// The enumeration or the policy could not be persisted. The flow
    /// stays incomplete and claims no protection; the caller may retry.
    case persistenceFailed
}

/// Persistence seam for the enumeration captured at setup.
///
/// The completion enumeration is written once, at the completion commit,
/// and reloaded to restore shields after a relaunch without re-running
/// the picker. Separately, every accepted enumeration is also persisted
/// (merged with prior incomplete picks) as a distinctly-incomplete
/// restrictive record, so terminating the app before setup finishes loses
/// nothing: a relaunch restores those shields while staying incomplete.
/// The incomplete record can never confer completion — completing still
/// requires the completion enumeration plus a stored policy — and the
/// commit clears it once the staged enumeration replaces it.
/// Production uses `FileSetupEnumerationStore`; tests use the same file
/// store over a temporary directory.
public protocol SetupEnumerationStore: Sendable {
    func loadEnumeration() -> ShieldEnumeration?
    func saveEnumeration(_ enumeration: ShieldEnumeration) throws
    func clearEnumeration() throws
    func loadIncompleteEnumeration() -> ShieldEnumeration?
    func saveIncompleteEnumeration(_ enumeration: ShieldEnumeration) throws
    func clearIncompleteEnumeration() throws
}

/// File-backed setup-enumeration store (JSON in a directory, atomic write).
///
/// Follows the `PolicyStore` precedent. A missing or corrupt file loads as
/// no enumeration, which restores as an incomplete flow — never as
/// completed with unknown shielding.
public final class FileSetupEnumerationStore: SetupEnumerationStore, @unchecked Sendable {
    public static let enumerationFileName = "setup-enumeration.json"
    /// The distinctly-incomplete restrictive record (fix round 4): merged
    /// picks of runs that never committed. Never confers completion.
    public static let incompleteEnumerationFileName = "setup-enumeration-incomplete.json"

    private let directory: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Default store directory, shared with `PolicyStore`.
    public convenience init(fileManager: FileManager = .default) {
        self.init(
            directory: PolicyStore.defaultDirectory(fileManager: fileManager),
            fileManager: fileManager
        )
    }

    public func loadEnumeration() -> ShieldEnumeration? {
        lock.lock()
        defer { lock.unlock() }
        let url = directory.appendingPathComponent(Self.enumerationFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(ShieldEnumeration.self, from: data)
    }

    public func saveEnumeration(_ enumeration: ShieldEnumeration) throws {
        lock.lock()
        defer { lock.unlock() }
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(enumeration)
        try data.write(
            to: directory.appendingPathComponent(Self.enumerationFileName),
            options: [.atomic]
        )
    }

    public func clearEnumeration() throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            try fileManager.removeItem(
                at: directory.appendingPathComponent(Self.enumerationFileName)
            )
        } catch {
            let code = (error as NSError).code
            let domain = (error as NSError).domain
            if domain == NSCocoaErrorDomain && code == NSFileNoSuchFileError {
                return
            }
            if let cocoa = error as? CocoaError, cocoa.code == .fileNoSuchFile {
                return
            }
            throw error
        }
    }

    /// Loads the incomplete restrictive record; a missing or corrupt file
    /// loads as no record (never as completed protection).
    public func loadIncompleteEnumeration() -> ShieldEnumeration? {
        loadFile(named: Self.incompleteEnumerationFileName)
    }

    public func saveIncompleteEnumeration(_ enumeration: ShieldEnumeration) throws {
        try saveFile(enumeration, named: Self.incompleteEnumerationFileName)
    }

    public func clearIncompleteEnumeration() throws {
        try clearFile(named: Self.incompleteEnumerationFileName)
    }

    private func loadFile(named fileName: String) -> ShieldEnumeration? {
        lock.lock()
        defer { lock.unlock() }
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(ShieldEnumeration.self, from: data)
    }

    private func saveFile(_ enumeration: ShieldEnumeration, named fileName: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(enumeration)
        try data.write(
            to: directory.appendingPathComponent(fileName),
            options: [.atomic]
        )
    }

    private func clearFile(named fileName: String) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            try fileManager.removeItem(
                at: directory.appendingPathComponent(fileName)
            )
        } catch {
            let code = (error as NSError).code
            let domain = (error as NSError).domain
            if domain == NSCocoaErrorDomain && code == NSFileNoSuchFileError {
                return
            }
            if let cocoa = error as? CocoaError, cocoa.code == .fileNoSuchFile {
                return
            }
            throw error
        }
    }
}

/// The T2.3 setup state machine. See the `SetupStep` documentation for the
/// step order, the no-skip rule, and the verification status.
public final class SetupFlow: @unchecked Sendable {
    private let policyStore: PolicyStore
    private let shieldManager: ShieldManager
    private let enumerationStore: any SetupEnumerationStore

    private let lock = NSLock()
    private var step: SetupStep
    private var authorized: Bool
    private var stagedEnumeration: ShieldEnumeration?
    private var stagedAllowlist: Set<AppRef>?
    private var stagedUnblockable: Set<AppRef>?
    /// A committed enumeration waiting for Screen Time access to be
    /// approved again (see `needsReauthorization`). Set only at init when
    /// a committed policy/enumeration pair exists on disk without current
    /// approval; consumed only by a re-grant. While set, the flow can only
    /// return to `complete` via `recordAuthorization(granted: true)` —
    /// no step can be submitted, and `abandon()` preserves the pair.
    private var pendingCommittedEnumeration: ShieldEnumeration?

    /// Creates a flow over the given stores.
    ///
    /// - `shieldManager` must be constructed with an empty enumeration on
    ///   a fresh install, so shields are inactive until this flow
    ///   completes and hands over the real enumeration.
    /// - `authorized` seeds the in-memory authorization flag (the app
    ///   passes the current system status at launch). It gates the
    ///   restore below: a committed setup restores as active protection
    ///   only with current approval.
    ///
    /// Restore: when the policy store already holds a policy
    /// (`storedVersion > 0`) AND a non-empty enumeration was persisted,
    /// this starts at `complete` and re-applies the persisted enumeration
    /// to `shieldManager` so shields are active again — but only when
    /// `authorized` is true. With a committed pair but no current
    /// approval, this starts at `authorization` with
    /// `needsReauthorization` true and applies no shields; re-granting
    /// restores completion without re-running the picker.
    /// Otherwise the flow restores as incomplete (claiming no completed
    /// protection) with the merged incomplete restrictive record applied:
    /// the completion file without a policy (an abandoned run's record
    /// from before the incomplete file existed, or a commit interrupted
    /// before its policy write) plus the incomplete file. A policy
    /// without any persisted record restores as incomplete with no
    /// shields applied.
    public init(
        policyStore: PolicyStore,
        shieldManager: ShieldManager,
        enumerationStore: any SetupEnumerationStore,
        authorized: Bool = false
    ) {
        self.policyStore = policyStore
        self.shieldManager = shieldManager
        self.enumerationStore = enumerationStore
        self.authorized = authorized
        let persisted = enumerationStore.loadEnumeration()
        let persistedIsNonEmpty = persisted.map {
            !$0.apps.isEmpty || !$0.categories.isEmpty
        } ?? false
        if policyStore.storedVersion > 0, let persisted, persistedIsNonEmpty {
            if authorized {
                self.step = .complete
                self.stagedEnumeration = persisted
                shieldManager.updateEnumeration(persisted)
            } else {
                self.step = .authorization
                self.pendingCommittedEnumeration = persisted
            }
        } else {
            self.step = .authorization
            let incomplete = Self.mergedRestrictiveRecord(
                [persisted, enumerationStore.loadIncompleteEnumeration()].compactMap { $0 }
            )
            if !incomplete.apps.isEmpty || !incomplete.categories.isEmpty {
                shieldManager.updateEnumeration(incomplete)
            }
        }
    }

    /// Merges enumerations into one restrictive record: the union of apps
    /// (by id; later arguments win per-app category metadata) and the
    /// union of categories. Callers pass persisted records first and the
    /// staged (freshest) enumeration last, so a re-pick's known category
    /// replaces a stale unknown one. Deterministic: first-seen app order
    /// with latest metadata.
    private static func mergedRestrictiveRecord(
        _ enumerations: [ShieldEnumeration]
    ) -> ShieldEnumeration {
        var appsByID: [String: EnumeratedApp] = [:]
        var appOrder: [String] = []
        var categories: Set<AppCategoryRef> = []
        for enumeration in enumerations {
            for entry in enumeration.apps {
                if appsByID[entry.app.id] == nil {
                    appOrder.append(entry.app.id)
                }
                appsByID[entry.app.id] = entry
            }
            categories.formUnion(enumeration.categories)
        }
        return ShieldEnumeration(
            apps: appOrder.compactMap { appsByID[$0] },
            categories: categories
        )
    }

    /// The current step. Moves forward only; never skips.
    public var currentStep: SetupStep {
        lock.lock()
        defer { lock.unlock() }
        return step
    }

    /// Whether FamilyControls authorization has been recorded as granted
    /// for this run of the flow.
    public var isAuthorized: Bool {
        lock.lock()
        defer { lock.unlock() }
        return authorized
    }

    /// True only after the completion commit (or a restore of one).
    public var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return step == .complete
    }

    /// Whether the flow claims any protection. False until the completion
    /// commit: an incomplete flow — including one abandoned mid-flow or
    /// one waiting for reauthorization — claims no completed protection.
    /// (An abandoned run still shields its picked apps restrictively, but
    /// that is default-deny, not a completed setup.)
    public var claimsProtection: Bool {
        lock.lock()
        defer { lock.unlock() }
        return step == .complete
    }

    /// True when a committed setup exists on disk but Screen Time access
    /// is not currently approved, so active protection was NOT restored.
    /// The committed policy/enumeration pair is intact: re-granting
    /// authorization (see `recordAuthorization(granted:)`) restores
    /// completion without re-running the picker.
    public var needsReauthorization: Bool {
        lock.lock()
        defer { lock.unlock() }
        return step == .authorization && pendingCommittedEnumeration != nil
    }

    /// The staged enumeration, if one has been submitted this run (or was
    /// restored from a completed setup).
    public var pendingEnumeration: ShieldEnumeration? {
        lock.lock()
        defer { lock.unlock() }
        return stagedEnumeration
    }

    /// Records a FamilyControls authorization result.
    ///
    /// A grant advances `authorization` to `enumeration` — except when a
    /// committed setup is waiting for reauthorization (see
    /// `needsReauthorization`): then the grant restores `complete`
    /// directly, re-applying the committed enumeration, without
    /// re-running the picker. A denial leaves the step — and everything
    /// else — untouched, so the flow cannot proceed without authorization.
    /// No-op once complete.
    public func recordAuthorization(granted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard step != .complete else { return }
        authorized = granted
        if granted, step == .authorization {
            if let pending = pendingCommittedEnumeration,
               policyStore.storedVersion > 0 {
                pendingCommittedEnumeration = nil
                stagedEnumeration = pending
                shieldManager.updateEnumeration(pending)
                step = .complete
            } else {
                pendingCommittedEnumeration = nil
                step = .enumeration
            }
        }
    }

    /// Submits the FamilyActivityPicker enumeration.
    ///
    /// Requires the `enumeration` step with authorization recorded, and a
    /// non-empty enumeration (at least one app or one category — an empty
    /// pick shields nothing, so it cannot complete setup). On success the
    /// enumeration is staged in memory and persisted (merged with any
    /// prior incomplete picks) as the distinctly-incomplete restrictive
    /// record, and the flow advances to `selection`. Returns false without
    /// changing any state otherwise; shields stay inactive either way.
    ///
    /// The incomplete persist is required — not best-effort — when no
    /// policy is stored yet: if it fails, the submit fails and the flow
    /// stays at `enumeration` with nothing staged, so the flow never
    /// advances on a promise of restoration it cannot deliver. Persisting
    /// is still refused over a stored policy (an incomplete record must
    /// never forge a policy/enumeration pair); that path stages in memory
    /// only. Shields are not applied here: the live run applies them at
    /// abandon/commit, and a relaunch applies this record while staying
    /// incomplete — so terminating the app from the selection or guidance
    /// step loses nothing and claims no completed protection.
    @discardableResult
    public func submitEnumeration(_ enumeration: ShieldEnumeration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard step == .enumeration, authorized else { return false }
        guard !enumeration.apps.isEmpty || !enumeration.categories.isEmpty else {
            return false
        }
        if policyStore.storedVersion == 0 {
            let merged = Self.mergedRestrictiveRecord(
                [
                    enumerationStore.loadEnumeration(),
                    enumerationStore.loadIncompleteEnumeration(),
                    enumeration,
                ].compactMap { $0 }
            )
            do {
                try enumerationStore.saveIncompleteEnumeration(merged)
            } catch {
                return false
            }
        }
        stagedEnumeration = enumeration
        step = .selection
        return true
    }

    /// Submits the allowlist / unblockable split of the enumerated apps.
    ///
    /// Requires the `selection` step with authorization recorded and a
    /// staged enumeration. Either set may be empty (the parent may allow
    /// nothing beyond the built-in defaults); apps named in both are
    /// sanitized to the allowlist, matching
    /// `Policy.isChallengeUnlockable` precedence. On success the flow
    /// advances to `preventDeletingGuidance`. Returns false without
    /// changing any state otherwise.
    @discardableResult
    public func submitSelections(allowlist: Set<AppRef>, unblockable: Set<AppRef>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard step == .selection, authorized, stagedEnumeration != nil else {
            return false
        }
        stagedAllowlist = allowlist
        stagedUnblockable = unblockable.subtracting(allowlist)
        step = .preventDeletingGuidance
        return true
    }

    /// Returns an authorized flow from `selection` to `enumeration` so the
    /// parent can re-pick (the re-pick T2.2's `updateEnumeration` exists
    /// for). Clears the staged enumeration and selections; the
    /// authorization record is kept. Requires the `selection` step with
    /// authorization recorded; returns false without changing any state
    /// otherwise. This is not skipping: the flow still passes through
    /// every later step in order before it can complete.
    @discardableResult
    public func restartEnumeration() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard step == .selection, authorized else { return false }
        stagedEnumeration = nil
        stagedAllowlist = nil
        stagedUnblockable = nil
        step = .enumeration
        return true
    }

    /// Acknowledges the prevent-deleting-apps guidance and commits setup.
    ///
    /// Requires the `preventDeletingGuidance` step with authorization
    /// recorded and staged enumeration/selections. The commit, in order:
    /// persist the enumeration, write the policy (version snapshot + 1 —
    /// the bump applies to the snapshot being edited, so a policy that an
    /// admin sync applied concurrently wins over this stale commit instead
    /// of being overwritten by it — starting from the current policy so
    /// existing overrides, chore pool, durations, caps, and settings are
    /// preserved; only the setup selections change — allowlist = built-in
    /// defaults plus the staged allowlist, unblockable = the staged set),
    /// clear the incomplete restrictive record (the staged enumeration
    /// replaces all prior incomplete restrictions), then hand the
    /// enumeration to `ShieldManager`, which applies the shields.
    /// Policy construction reads only the policy store and the staged
    /// selections — never the saved enumeration — so the write order is
    /// free; enumeration-first is kept so a failed policy write can roll
    /// the enumeration back without consuming a policy version.
    ///
    /// - `.finished`: committed; the flow is complete and claims
    ///   protection (subject to the entitlement honesty note above).
    /// - `.notReady`: called out of order or with missing prerequisites;
    ///   nothing was written or applied.
    /// - `.persistenceFailed`: the enumeration or the policy could not be
    ///   persisted. On a policy failure the just-written enumeration is
    ///   rolled back (the previous content, if any, is restored), so no
    ///   uncommitted enumeration data survives and a relaunch cannot
    ///   mistake the failed setup for a completed one. Nothing advances,
    ///   and the caller may retry this method.
    @discardableResult
    public func acknowledgePreventDeletingGuidance() -> SetupFinishResult {
        lock.lock()
        defer { lock.unlock() }
        guard step == .preventDeletingGuidance,
              authorized,
              let enumeration = stagedEnumeration,
              let allowlist = stagedAllowlist,
              let unblockable = stagedUnblockable
        else {
            return .notReady
        }
        var policy = policyStore.currentPolicy
        // The bump applies to the snapshot being edited — never to a
        // separately re-read version. A second `storedVersion` read here
        // could observe a newer policy that an admin sync applied between
        // the two reads; the stale snapshot would then take (newer + 1)
        // and `apply` would accept it, destroying the newer overrides,
        // chore pool, and settings. With `+= 1` a stale snapshot's version
        // no longer exceeds the newer stored version, so `apply` rejects
        // it (`.rejectedStaleVersion`) and the caller retries against the
        // newer policy.
        policy.version += 1
        policy.alwaysAllowed = [.phone, .messages, .earnPlaySelf]
            + allowlist.sorted(by: { $0.id < $1.id })
        policy.unblockable = unblockable.sorted(by: { $0.id < $1.id })
        let previousEnumeration = enumerationStore.loadEnumeration()
        do {
            try enumerationStore.saveEnumeration(enumeration)
        } catch {
            return .persistenceFailed
        }
        guard policyStore.apply(policy) == .applied else {
            if let previousEnumeration {
                try? enumerationStore.saveEnumeration(previousEnumeration)
            } else {
                try? enumerationStore.clearEnumeration()
            }
            return .persistenceFailed
        }
        // The merge ends at commit: the staged enumeration replaces all
        // prior incomplete restrictions. Best-effort: a clear failure
        // leaves a stale incomplete record next to the completed pair,
        // which restore ignores (completion reads only the completion
        // file plus the stored policy).
        try? enumerationStore.clearIncompleteEnumeration()
        shieldManager.updateEnumeration(enumeration)
        step = .complete
        return .finished
    }

    /// Abandons an in-progress setup run.
    ///
    /// Clears the in-memory authorization flag, staged enumeration, and
    /// staged selections, and returns to the `authorization` step. No full
    /// policy is committed — but when an enumeration was staged, it is
    /// merged forward with the previously persisted restrictions and the
    /// merged configuration is applied to the `ShieldManager` as a
    /// restrictive incomplete-setup configuration (default-deny: every
    /// picked app shielded under the current policy) and persisted to the
    /// distinctly-incomplete record regardless of policy version — the
    /// incomplete file can never confer completion (restore reads only the
    /// completion file plus the stored policy), so a relaunch stays
    /// incomplete with the picked apps still shielded and an aborted retry
    /// never loosens prior restrictions.
    /// No-op once complete (a committed setup is not un-committed), and a
    /// no-op while a committed setup waits for reauthorization (the pair
    /// and the reauthorization path survive abandoning).
    public func abandon() {
        lock.lock()
        defer { lock.unlock() }
        guard step != .complete else { return }
        guard pendingCommittedEnumeration == nil else { return }
        if let staged = stagedEnumeration,
           !staged.apps.isEmpty || !staged.categories.isEmpty {
            let merged = Self.mergedRestrictiveRecord(
                [
                    enumerationStore.loadEnumeration(),
                    enumerationStore.loadIncompleteEnumeration(),
                    staged,
                ].compactMap { $0 }
            )
            try? enumerationStore.saveIncompleteEnumeration(merged)
            shieldManager.updateEnumeration(merged)
        }
        authorized = false
        stagedEnumeration = nil
        stagedAllowlist = nil
        stagedUnblockable = nil
        step = .authorization
    }
}
