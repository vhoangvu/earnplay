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
/// The ONLY production entry point is `presentOffer(_:sessionId:)`, called
/// by the tutor when the AI initiates a trade moment (future
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

    public init(historyStore: MovementTradeHistoryStore = MovementTradeHistoryStore()) {
        self.historyStore = historyStore
    }

    /// Presents an AI-initiated offer. Returns false unless idle — one
    /// offer per trade moment; the session cap is enforced by the offer
    /// gate.
    @discardableResult
    public func presentOffer(_ offer: MovementTradeOffer, sessionId: String) -> Bool {
        guard screen == .none else { return false }
        tradeSession = MovementTradeSession(sessionId: sessionId, offer: offer)
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
    public func accept(with provider: MotionSampleProvider) {
        guard var session = tradeSession, session.accept() else { return }
        tradeSession = session
        self.provider = provider
        screen = .active
        provider.startUpdates { [weak self] sample in
            Task { @MainActor [weak self] in self?.ingest(sample) }
        }
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

    private func finish(_ session: MovementTradeSession) {
        provider?.stopUpdates()
        provider = nil
        lastRecord = session.makeRecord()
        if let entry = session.makeHistoryEntry() {
            historyStore.record(entry)
        }
        switch session.outcome {
        case .granted:
            statusText = "Unlock granted: \(session.offer.unlockMinutes) minutes. Nice work!"
        case .declined:
            statusText = "No problem — back to practice."
        case .abandoned:
            statusText = "Trade ended — no unlock this time. Practice still counts!"
        case .none:
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
