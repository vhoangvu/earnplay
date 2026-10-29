import Foundation
#if canImport(Combine)
import Combine
#endif

#if canImport(Combine)
// MARK: - Observable session driver

/// Presentation driver for one AI-initiated movement trade (T3.1).
///
/// Lives in EarnPlayCore following the `ReadAloudService` precedent: a
/// `@MainActor` `ObservableObject` the SwiftUI offer card and live counter
/// bind to, with all counting, gating, and recording done by the
/// deterministic types in `MovementTrade.swift`.
///
/// The ONLY production entry point is `presentOffer(_:sessionId:weeklyCap:sessionCap:)`,
/// called by the tutor when the AI initiates a trade moment (future
/// TutorEngine/T3.3 — the app's DEBUG preview simulates that event). No
/// menu, button, or child action presents an offer; the offer gate itself
/// (`MovementTradeManager.decide`) additionally refuses anything not
/// AI-initiated. On accept, samples flow from the provider into the
/// session's verified counter and `verifiedCount` drives the live counter.
@MainActor
public final class MovementTradeViewModel: ObservableObject {
    public enum Screen: Equatable, Sendable {
        case none
        case offered
        case active
        case finished
    }

    @Published public private(set) var screen: Screen = .none
    @Published public private(set) var activityName = ""
    @Published public private(set) var targetReps = 0
    @Published public private(set) var unlockMinutes = 0
    @Published public private(set) var verifiedCount = 0
    @Published public private(set) var statusText = ""

    public private(set) var lastRecord: MovementTradeRecord?
    public var grantMinutes: Int? { lastRecord?.unlockMinutesGranted }

    private var tradeSession: MovementTradeSession?
    private var provider: MotionSampleProvider?
    private let historyStore: MovementTradeHistoryStore
    /// Device carry confidence from the app (iPad has no pocket carry).
    private let verificationConfidence: MovementVerificationConfidence
    /// Weekly cap the presented offer reserved against; reused to
    /// revalidate the cap atomically before granting.
    private var weeklyCap: Int = TradeCaps.default.weeklyMaxMovementTrades

    public init(historyStore: MovementTradeHistoryStore = MovementTradeHistoryStore(),
                verificationConfidence: MovementVerificationConfidence = .full) {
        self.historyStore = historyStore
        self.verificationConfidence = verificationConfidence
    }

    /// Presents an AI-initiated offer. Returns false unless idle — one
    /// offer per trade moment. Presenting atomically reserves one slot
    /// against both the weekly cap and the session cap (the policy's
    /// `maxTradesPerSession`), so a recreated UI for the same session
    /// sees the pending offer, two presentations for one session cannot
    /// both reserve, and overlapping sessions cannot exceed the weekly
    /// cap; completion finalizes the reservation to its terminal outcome
    /// instead of appending a second entry. Returns false without
    /// changing state when no slot is free or the reservation cannot be
    /// persisted — no offer is ever backed only by this instance's cache.
    @discardableResult
    public func presentOffer(_ offer: MovementTradeOffer, sessionId: String,
                             weeklyCap: Int = TradeCaps.default.weeklyMaxMovementTrades,
                             sessionCap: Int = TradeCaps.default.maxTradesPerSession) -> Bool {
        guard screen == .none else { return false }
        let session = MovementTradeSession(sessionId: sessionId, offer: offer)
        let reserved = historyStore.tryRecordOffer(
            MovementTradeHistoryEntry(
                tradeId: session.tradeId, sessionId: sessionId,
                activity: offer.activity, offeredAt: session.offeredAt,
                outcome: .offered, verifiedReps: 0, targetReps: offer.targetReps),
            weeklyCap: weeklyCap, sessionCap: sessionCap)
        guard reserved == .reserved else { return false }
        self.weeklyCap = weeklyCap
        tradeSession = session
        activityName = Self.displayName(offer.activity)
        targetReps = offer.targetReps
        unlockMinutes = offer.unlockMinutes
        verifiedCount = 0
        statusText = ""
        lastRecord = nil
        screen = .offered
        return true
    }

    /// Accepts the offer and starts counting from `provider` (production:
    /// the app's CoreMotion provider; simulator preview: fixture replay).
    /// When motion is unavailable the trade never goes `.active`: the
    /// weekly reservation is released as a declined offer and a recovery
    /// message is shown instead of a permanently zero counter. A
    /// mid-stream provider failure likewise finalizes the active trade
    /// (releasing its reservation) with a recovery message instead of
    /// hanging with a live reservation and no samples.
    public func accept(with provider: MotionSampleProvider) {
        guard var session = tradeSession else { return }
        guard provider.isAvailable else {
            _ = session.decline()
            tradeSession = session
            if let entry = session.makeHistoryEntry() {
                _ = historyStore.tryFinalize(entry, weeklyCap: weeklyCap)
            }
            lastRecord = session.makeRecord(verificationConfidence: verificationConfidence)
            statusText = "Motion unavailable on this device — back to practice. "
                + "No reps were counted and no unlock was granted."
            screen = .finished
            return
        }
        guard session.accept() else { return }
        tradeSession = session
        self.provider = provider
        screen = .active
        provider.startUpdates(handler: { [weak self] sample in
            Task { @MainActor [weak self] in self?.ingest(sample) }
        }, onFailure: { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleStreamFailure() }
        })
    }

    /// Direct sample feed (synchronous paths and tests).
    public func ingest(_ sample: MotionSample) {
        guard var session = tradeSession, !session.isTerminal else { return }
        verifiedCount = session.ingest(sample)
        tradeSession = session
        if session.isTerminal { finish(session) }
    }

    public func ingest(_ samples: [MotionSample]) {
        for sample in samples {
            ingest(sample)
            if tradeSession?.isTerminal == true { break }
        }
    }

    public func decline() {
        guard var session = tradeSession, session.decline() else { return }
        tradeSession = session
        finish(session)
    }

    public func abandon() {
        guard var session = tradeSession, session.abandon() else { return }
        tradeSession = session
        finish(session)
    }

    /// Finalizes an active trade whose motion stream failed: stops the
    /// provider, releases the weekly reservation as an abandoned trade,
    /// and shows a recovery message. Ignored unless a trade is active.
    private func handleStreamFailure() {
        guard var session = tradeSession, session.phase == .active else { return }
        _ = session.abandon()
        tradeSession = session
        provider?.stopUpdates()
        provider = nil
        if let entry = session.makeHistoryEntry() {
            _ = historyStore.tryFinalize(entry, weeklyCap: weeklyCap)
        }
        lastRecord = session.makeRecord(verificationConfidence: verificationConfidence)
        statusText = "Motion stopped unexpectedly — back to practice. "
            + "No unlock was granted."
        screen = .finished
    }

    private func finish(_ session: MovementTradeSession) {
        provider?.stopUpdates()
        provider = nil
        if let entry = session.makeHistoryEntry() {
            let finalized = historyStore.tryFinalize(entry, weeklyCap: weeklyCap)
            // Grants fail closed: the cap is revalidated atomically before
            // granting, and a grant that cannot be persisted is reported as
            // a failure — never as a success backed only by this cache.
            // (Declined/abandoned outcomes finalize without a cap check;
            // a missed write there only leaves the reservation held, which
            // still blocks further offers and grants nothing.)
            if session.outcome == .granted, finalized != .finalized {
                lastRecord = nil
                switch finalized {
                case .weeklyCapExceeded:
                    statusText = "Weekly trade limit reached — no unlock this time. "
                        + "Practice still counts!"
                case .persistenceFailed:
                    statusText = "Couldn't save the trade — no unlock this time. "
                        + "Please try again."
                case .finalized:
                    statusText = ""
                }
                screen = .finished
                return
            }
        }
        lastRecord = session.makeRecord(verificationConfidence: verificationConfidence)
        switch session.outcome {
        case .granted:
            statusText = "Unlock granted: \(session.offer.unlockMinutes) minutes. Nice work!"
        case .declined:
            statusText = "No problem — back to practice."
        case .abandoned:
            statusText = "Trade ended — no unlock this time. Practice still counts!"
        case .offered, .none:
            // Unreachable: finish runs only for terminal sessions, whose
            // outcome is never the `.offered` reservation state.
            statusText = ""
        }
        screen = .finished
    }

    private static func displayName(_ activity: MovementActivity) -> String {
        switch activity {
        case .jumpingJacks: return "Jumping jacks"
        case .runningInPlace: return "Running in place"
        case .squats: return "Squats"
        case .marchingInPlace: return "Marching in place"
        }
    }
}
#endif
