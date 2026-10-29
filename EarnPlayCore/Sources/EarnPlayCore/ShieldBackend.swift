import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Shield-application types for T2.2 — framework-free, like `Policy`.
///
/// No FamilyControls / ManagedSettings type appears here. Apps and
/// categories are opaque identifiers (`AppRef`, `AppCategoryRef`); the
/// setup flow (T2.3) owns the mapping from picker tokens to these
/// identifiers, and a real ManagedSettings backend (v1) owns the mapping
/// back to tokens. Keeping this layer framework-free lets the shared
/// package and its host tests run without any entitlement, and lets
/// T2.4 substitute a simulated backend without changing callers.
///
/// Verification status: Demo behaviour is verified only against a
/// simulated backend (see `ShieldManagerTests`). Real shield
/// enforcement is v1, gated on the FamilyControls entitlement, and is
/// NOT verified by this task. The on-device enumeration prototype is
/// confirmation-only; absence from public docs is not proof either way.

/// Opaque reference to an activity category named at setup.
public struct AppCategoryRef: Codable, Equatable, Hashable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

/// One app enumerated via FamilyActivityPicker at setup (T2.3 supplies
/// these), with the category it was enumerated under, if known.
public struct EnumeratedApp: Codable, Equatable, Hashable, Sendable {
    public var app: AppRef
    public var category: AppCategoryRef?

    public init(app: AppRef, category: AppCategoryRef? = nil) {
        self.app = app
        self.category = category
    }
}

/// The enumeration captured at setup: every picked app, plus every
/// picked category. Categories are the backstop for apps installed
/// after setup that have not been enumerated yet.
public struct ShieldEnumeration: Codable, Equatable, Sendable {
    public var apps: [EnumeratedApp]
    public var categories: Set<AppCategoryRef>

    public init(apps: [EnumeratedApp], categories: Set<AppCategoryRef> = []) {
        self.apps = apps
        self.categories = categories
    }

    public static let empty = ShieldEnumeration(apps: [], categories: [])
}

/// The shield state the manager asks a backend to apply.
///
/// Enumeration-first, with a category backstop and *no* per-app
/// exemption field: there is deliberately no `except` / allowlist field
/// here, so no caller or backend can express "shield this category
/// except this app". An app stays unshielded only because it is absent
/// from `shieldedApplications` and its category is absent from
/// `shieldedCategories` — the manager guarantees that by withholding
/// categories that contain an always-allowed or currently unlocked
/// app (see `ShieldManager`). That withholding also means lifting a
/// category for an unlock temporarily lifts its backstop; the unlock
/// path accepts that coarse trade-off instead of relying on an
/// exemption overriding a category shield.
public struct ShieldConfiguration: Codable, Equatable, Sendable {
    /// Enumerated, non-allowlist apps to shield individually.
    public var shieldedApplications: Set<AppRef>
    /// Categories to shield as a backstop for unenumerated apps.
    public var shieldedCategories: Set<AppCategoryRef>

    public init(
        shieldedApplications: Set<AppRef>,
        shieldedCategories: Set<AppCategoryRef>
    ) {
        self.shieldedApplications = shieldedApplications
        self.shieldedCategories = shieldedCategories
    }

    public static let none = ShieldConfiguration(
        shieldedApplications: [], shieldedCategories: []
    )

    /// Effective shielding under the backend contract: an app is
    /// shielded when it is shielded individually, or when its category
    /// is shielded. No exemption overrides either condition.
    public func isShielded(app: AppRef, category: AppCategoryRef?) -> Bool {
        if shieldedApplications.contains(app) { return true }
        if let category, shieldedCategories.contains(category) { return true }
        return false
    }
}

/// Backend that applies a `ShieldConfiguration`.
///
/// T2.4 will provide the simulated-shield backend behind this same
/// protocol; v1 provides the real ManagedSettings backend. Callers
/// (`ShieldManager`) do not change when the backend is substituted.
public protocol ShieldBackend: AnyObject, Sendable {
    /// Applies `configuration`, replacing any previously applied state.
    func applyShieldConfiguration(_ configuration: ShieldConfiguration)
    /// The most recently applied configuration.
    var currentShieldConfiguration: ShieldConfiguration { get }
    /// Effective shielding for `app` (optionally known `category`).
    func isShielded(app: AppRef, category: AppCategoryRef?) -> Bool
}

extension ShieldBackend {
    public func isShielded(app: AppRef, category: AppCategoryRef?) -> Bool {
        currentShieldConfiguration.isShielded(app: app, category: category)
    }
}

/// Monotonic clock source for unlock timers (LLD unlock timers).
///
/// Values are seconds on a suspend-inclusive monotonic clock that only
/// moves forward at real-time rate, keeps counting across system sleep,
/// and is unaffected by device wall-clock changes. Unlock expiry is
/// computed only from this source, never from `Date`.
public protocol MonotonicClock: Sendable {
    var nowUptime: TimeInterval { get }
}

/// Production monotonic clock: suspend-inclusive continuous time.
///
/// Uses `mach_continuous_time` (Darwin), which keeps counting while the
/// device sleeps, so an unlock cannot retain unused time after the phone
/// has slept past its real-time deadline. `ProcessInfo.systemUptime`
/// measures awake time only and must not be used here.
///
/// Resets when the device reboots; `ShieldManager` binds each window to
/// a boot-session identifier and re-locks fail-closed on a reboot or an
/// uptime regression rather than extending a window on a fresh boot.
public struct SystemUptimeClock: MonotonicClock {
    public init() {}

    public var nowUptime: TimeInterval {
        #if canImport(Darwin)
        var info = mach_timebase_info(numer: 0, denom: 0)
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else {
            return ProcessInfo.processInfo.systemUptime
        }
        let ticks = mach_continuous_time()
        let nanos = Double(ticks) * Double(info.numer) / Double(info.denom)
        return nanos / 1_000_000_000
        #else
        return ProcessInfo.processInfo.systemUptime
        #endif
    }
}

/// Boot-session identifier source for unlock windows.
///
/// Each boot has a distinct identifier; `ShieldManager` persists the
/// grant-time identifier with the window and fails closed when the
/// reloaded identifier differs or cannot be verified, so a reboot can
/// never resume an old window even when the new boot's uptime falls
/// inside the old grant-expiry interval. `nil` means unverifiable.
public protocol BootSessionProvider: Sendable {
    var currentBootSessionID: String? { get }
}

/// Production boot-session provider: `kern.bootsessionuuid` when
/// available, otherwise unverifiable (`nil`).
///
/// There is deliberately no `kern.boottime` fallback: boottime is
/// wall-clock-derived and shifts when the system clock is adjusted, so
/// an ID derived from it would change on a clock jump and the manager
/// would wrongly revoke an unexpired unlock as a spurious reboot. With
/// `nil` the manager instead keeps the unlock mid-process (remaining
/// time is unaffected by wall-clock jumps) and fails closed on reload.
public struct SystemBootSessionProvider: BootSessionProvider {
    public init() {}

    public var currentBootSessionID: String? {
        #if canImport(Darwin)
        return Self.resolveBootSessionID(
            uuid: Self.sysctlString("kern.bootsessionuuid")
        )
        #else
        return nil
        #endif
    }

    /// Resolves the boot-session identifier from a `kern.bootsessionuuid`
    /// value: the trimmed UUID, or `nil` when missing or blank (never a
    /// wall-clock-derived substitute). Extracted as a seam so tests can
    /// pin the no-fallback contract without touching sysctls.
    static func resolveBootSessionID(uuid: String?) -> String? {
        if let uuid, !uuid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "bootsessionuuid:\(uuid.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return nil
    }

    #if canImport(Darwin)
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        let sized = name.withCString { sysctlbyname($0, nil, &size, nil, 0) }
        guard sized == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size + 1)
        let read = name.withCString { cString in
            buffer.withUnsafeMutableBytes { raw in
                sysctlbyname(cString, raw.baseAddress, &size, nil, 0)
            }
        }
        guard read == 0 else { return nil }
        let bytes = buffer.prefix(size).map { UInt8(bitPattern: $0) }
        let content = bytes.prefix(while: { $0 != 0 })
        return String(bytes: content, encoding: .utf8)
    }
    #endif
}
