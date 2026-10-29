import XCTest
import EarnPlayCore
@testable import EarnPlay

/// App-target coverage for T3.1 fix round 1 (issue #17 review): the
/// accept-path provider selection and the preview session identity.
/// Both live in the EarnPlay target (they touch CoreMotion/UIDevice and
/// the simulator environment), so they are tested here, inside the app
/// host, rather than in the package suite.
final class MovementTradePreviewTests: XCTestCase {

    // MARK: - Finding 1: on-device provider selection

    func testUseFixtureReplayTruthTable() {
        XCTAssertTrue(MotionProviderFactory.useFixtureReplay(isSimulator: true, fixtureOverride: false))
        XCTAssertTrue(MotionProviderFactory.useFixtureReplay(isSimulator: true, fixtureOverride: true))
        XCTAssertTrue(MotionProviderFactory.useFixtureReplay(isSimulator: false, fixtureOverride: true))
        XCTAssertFalse(MotionProviderFactory.useFixtureReplay(isSimulator: false, fixtureOverride: false))
    }

    func testSimulatorAcceptUsesFixtureReplay() {
        let provider = MotionProviderFactory.makeAcceptProvider(
            isSimulator: true, fixtureOverride: false,
            replayProvider: FixtureReplayProvider())
        XCTAssertTrue(provider is FixtureReplayProvider)
    }

    func testDeviceTestModeAcceptUsesFixtureReplay() {
        let provider = MotionProviderFactory.makeAcceptProvider(
            isSimulator: false, fixtureOverride: true,
            replayProvider: FixtureReplayProvider())
        XCTAssertTrue(provider is FixtureReplayProvider)
    }

    func testDeviceAcceptUsesCoreMotion() {
        let provider = MotionProviderFactory.makeAcceptProvider(
            isSimulator: false, fixtureOverride: false,
            replayProvider: FixtureReplayProvider())
        XCTAssertTrue(provider is CoreMotionSampleProvider)
    }

    func testProductionEntryUsesSimulatorReplay() {
        // This suite runs on the simulator, where the demo must keep
        // replaying fixtures.
        XCTAssertTrue(MotionProviderFactory.isSimulator)
        let provider = MotionProviderFactory.makeAcceptProvider(
            replayProvider: FixtureReplayProvider())
        XCTAssertTrue(provider is FixtureReplayProvider)
    }

    // MARK: - Finding 5: fresh preview session IDs

    func testPreviewSessionsMintFreshIds() {
        XCTAssertNotEqual(PreviewSession().id, PreviewSession().id)
    }

    func testPreviewSessionIdIsStableUntilRenewed() {
        var session = PreviewSession()
        let first = session.id
        XCTAssertEqual(session.id, first)
        session.startNewSession()
        XCTAssertNotEqual(session.id, first)
    }

    func testDistinctSessionsHaveIndependentQuotas() {
        // The mechanism the fresh-ID fix relies on: a terminal trade in
        // one session never blocks the gate for another session ID.
        var history = MovementTradeHistory()
        history.entries = [MovementTradeHistoryEntry(
            sessionId: PreviewSession().id, activity: .jumpingJacks,
            offeredAt: Date(), outcome: .declined,
            verifiedReps: 0, targetReps: 10)]
        let freshId = PreviewSession().id
        XCTAssertEqual(history.offersInSession(freshId), 0)
        let context = MovementOfferContext(
            initiation: .aiLowMotivation,
            signals: EffortSignals(activeSeconds: 120, genuineAttempts: 2, hintInteractions: 1),
            sessionOffersUsed: history.offersInSession(freshId))
        guard case .offer = MovementTradeManager.decide(
            context: context, policy: .defaultPolicy) else {
            return XCTFail("fresh session refused after another session's terminal trade")
        }
    }
}
