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
/// then the initial policy (version `storedVersion + 1`) is written to
/// `PolicyStore`, then the enumeration is handed to `ShieldManager`, which
/// shields every enumerated app except the allowlist (enumeration-first)
/// with the picked categories as the backstop for newly installed apps.
/// Abandoning the flow before that commit leaves no policy, no persisted
/// enumeration, and no shields behind: an incomplete flow stays incomplete
/// and claims no protection. Once a policy exists, unknown apps are
/// governed by T2.5's default-deny rule (a later task; only the handoff is
/// stated here).
///
/// A completed setup survives relaunch: a new `SetupFlow` over the same
/// stores starts at `complete` and re-applies the persisted enumeration to
/// its `ShieldManager`, so shields are active again without re-running
/// the picker.
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
/// The enumeration is written once, at the completion commit, and reloaded
/// to restore shields after a relaunch without re-running the picker.
/// Production uses `FileSetupEnumerationStore`; tests use the same file
/// store over a temporary directory.
public protocol SetupEnumerationStore: Sendable {
    func loadEnumeration() -> ShieldEnumeration?
    func saveEnumeration(_ enumeration: ShieldEnumeration) throws
    func clearEnumeration() throws
}

/// File-backed setup-enumeration store (JSON in a directory, atomic write).
///
/// Follows the `PolicyStore` precedent. A missing or corrupt file loads as
/// no enumeration, which restores as an incomplete flow — never as
/// completed with unknown shielding.
public final class FileSetupEnumerationStore: SetupEnumerationStore, @unchecked Sendable {
    public static let enumerationFileName = "setup-enumeration.json"

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

    /// Creates a flow over the given stores.
    ///
    /// - `shieldManager` must be constructed with an empty enumeration on
    ///   a fresh install, so shields are inactive until this flow
    ///   completes and hands over the real enumeration.
    /// - `authorized` seeds the in-memory authorization flag (the app
    ///   passes the current system status at launch); it never marks an
    ///   incomplete flow complete.
    ///
    /// Restore: when the policy store already holds a policy
    /// (`storedVersion > 0`) AND a non-empty enumeration was persisted,
    /// this starts at `complete` and re-applies the persisted enumeration
    /// to `shieldManager` so shields are active again. Any other
    /// combination — including a policy without an enumeration or an
    /// enumeration without a policy — restores as incomplete and claims
    /// no protection.
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
        if policyStore.storedVersion > 0,
           let persisted,
           !persisted.apps.isEmpty || !persisted.categories.isEmpty {
            self.step = .complete
            self.stagedEnumeration = persisted
            shieldManager.updateEnumeration(persisted)
        } else {
            self.step = .authorization
        }
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
    /// commit: an incomplete flow — including one abandoned mid-flow —
    /// claims no protection.
    public var claimsProtection: Bool {
        lock.lock()
        defer { lock.unlock() }
        return step == .complete
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
    /// A grant advances `authorization` to `enumeration`. A denial leaves
    /// the step — and everything else — untouched, so the flow cannot
    /// proceed without authorization. No-op once complete.
    public func recordAuthorization(granted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard step != .complete else { return }
        authorized = granted
        if granted, step == .authorization {
            step = .enumeration
        }
    }

    /// Submits the FamilyActivityPicker enumeration.
    ///
    /// Requires the `enumeration` step with authorization recorded, and a
    /// non-empty enumeration (at least one app or one category — an empty
    /// pick shields nothing, so it cannot complete setup). On success the
    /// enumeration is staged in memory (persisted only at the completion
    /// commit) and the flow advances to `selection`. Returns false without
    /// changing any state otherwise; shields stay inactive either way.
    @discardableResult
    public func submitEnumeration(_ enumeration: ShieldEnumeration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard step == .enumeration, authorized else { return false }
        guard !enumeration.apps.isEmpty || !enumeration.categories.isEmpty else {
            return false
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
    /// persist the enumeration, write the initial policy (version
    /// `storedVersion + 1`; allowlist = built-in defaults plus the staged
    /// allowlist; unblockable = the staged set; no never-unlockable
    /// overrides — the admin app may add those later), then hand the
    /// enumeration to `ShieldManager`, which applies the shields.
    ///
    /// - `.finished`: committed; the flow is complete and claims
    ///   protection (subject to the entitlement honesty note above).
    /// - `.notReady`: called out of order or with missing prerequisites;
    ///   nothing was written or applied.
    /// - `.persistenceFailed`: the enumeration or the policy could not be
    ///   persisted; nothing advances, shields stay inactive, and the
    ///   caller may retry this method.
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
        let policy = Policy(
            version: policyStore.storedVersion + 1,
            alwaysAllowed: [.phone, .messages, .earnPlaySelf]
                + allowlist.sorted(by: { $0.id < $1.id }),
            unblockable: unblockable.sorted(by: { $0.id < $1.id }),
            neverUnlockableOverrides: [],
            unlockDurations: .default,
            effortFloorSettings: .default,
            tradeCaps: .default,
            chorePool: [],
            movementSettings: .default
        )
        do {
            try enumerationStore.saveEnumeration(enumeration)
        } catch {
            return .persistenceFailed
        }
        guard policyStore.apply(policy) == .applied else {
            return .persistenceFailed
        }
        shieldManager.updateEnumeration(enumeration)
        step = .complete
        return .finished
    }

    /// Abandons an in-progress setup run.
    ///
    /// Clears the in-memory authorization flag, staged enumeration, and
    /// staged selections, and returns to the `authorization` step. Nothing
    /// is written: no policy, no persisted enumeration, no shield change —
    /// an abandoned flow stays incomplete and claims no protection.
    /// No-op once complete (a committed setup is not un-committed).
    public func abandon() {
        lock.lock()
        defer { lock.unlock() }
        guard step != .complete else { return }
        authorized = false
        stagedEnumeration = nil
        stagedAllowlist = nil
        stagedUnblockable = nil
        step = .authorization
    }
}
