import XCTest
import EarnPlayCore

/// App-target coverage for T3.1: the view model the offer card and live
/// counter drive, exercised with injected fixture streams (the simulator has
/// no motion sensor). The offer gate, rep counter, and caps themselves are
/// covered in EarnPlayCoreTests; these tests prove the app layer wires them
/// correctly: genuine motion grants, unverified motion never grants, decline
/// ends the moment, and terminal trades reach history.
@MainActor
final class MovementTradeAppTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MovementTradeAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    private func makeModel() -> MovementTradeViewModel {
        MovementTradeViewModel(historyStore: MovementTradeHistoryStore(directory: directory))
    }

    private func realOffer() -> MovementTradeOffer {
        let context = MovementOfferContext(
            initiation: .aiLowMotivation,
            signals: EffortSignals(activeSeconds: 120, genuineAttempts: 2, hintInteractions: 1))
        guard case .offer(let offer) = MovementTradeManager.decide(
            context: context, policy: .defaultPolicy) else {
            XCTFail("gate refused the fixture offer")
            return MovementTradeOffer(activity: .jumpingJacks, targetReps: 10,
                                      unlockMinutes: 15, taperApplied: false)
        }
        return offer
    }

    func testAcceptGenuineFixtureGrantsFifteenMinutes() {
        let model = makeModel()
        XCTAssertTrue(model.presentOffer(realOffer(), sessionId: "app-s1"))
        XCTAssertEqual(model.screen, .offered)
        let provider = StubMotionProvider()
        model.accept(with: provider)
        XCTAssertEqual(model.screen, .active)
        XCTAssertTrue(provider.started)
        model.ingest(MotionFixtures.genuineJumpingJacks(repCount: 12))
        XCTAssertEqual(model.screen, .finished)
        XCTAssertEqual(model.grantMinutes, 15)
        XCTAssertTrue(provider.stopped)
        XCTAssertEqual(model.lastRecord?.outcome, .granted)
    }

    func testDeclineEndsOfferAndBlocksSecondPresent() {
        let model = makeModel()
        XCTAssertTrue(model.presentOffer(realOffer(), sessionId: "app-s1"))
        model.decline()
        XCTAssertEqual(model.screen, .finished)
        XCTAssertNil(model.grantMinutes)
        XCTAssertFalse(model.presentOffer(realOffer(), sessionId: "app-s1"))
    }

    func testShakingFixtureNeverGrantsThroughViewModel() {
        let model = makeModel()
        model.presentOffer(realOffer(), sessionId: "app-s1")
        model.accept(with: StubMotionProvider())
        model.ingest(MotionFixtures.shakingInHand())
        XCTAssertEqual(model.screen, .active)
        XCTAssertEqual(model.verifiedCount, 0)
        XCTAssertNil(model.grantMinutes)
        model.ingest(MotionFixtures.phoneOnTable())
        XCTAssertEqual(model.screen, .active)
        XCTAssertNil(model.grantMinutes)
    }

    func testTerminalTradeReachesHistory() {
        let model = makeModel()
        model.presentOffer(realOffer(), sessionId: "app-s1")
        model.accept(with: StubMotionProvider())
        model.ingest(MotionFixtures.genuineJumpingJacks(repCount: 12))
        let history = MovementTradeHistoryStore(directory: directory).history
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries.first?.outcome, .granted)
        XCTAssertEqual(history.entries.first?.sessionId, "app-s1")
        XCTAssertEqual(history.completionsInTrailingWeek(), 1)
    }
}

/// Synchronous stub provider: records start/stop; samples are fed directly
/// through `MovementTradeViewModel.ingest(_:)` for determinism.
private final class StubMotionProvider: MotionSampleProvider {
    var isAvailable: Bool { true }
    private(set) var started = false
    private(set) var stopped = false

    func startUpdates(handler _: @escaping @Sendable (MotionSample) -> Void) {
        started = true
    }

    func stopUpdates() {
        stopped = true
    }
}
