import XCTest
import EarnPlayCore
@testable import EarnPlay

/// T2.4 fix round 2 (issue #15) — selecting a cached demo flow refreshes
/// it. The demo flows share one `ShieldManager`, so unlocking B replaces
/// A's window; re-selecting A must immediately show A's shield instead of
/// stale unlocked state (no timer tick required).
final class SimulatedShieldDemoStateTests: XCTestCase {
    @MainActor
    func testReselectingCachedFlowShowsShieldImmediately() throws {
        let demo = SimulatedShieldDemoState()
        let game = "earnplay.demo.game"
        let video = "earnplay.demo.video"

        // Unlock A.
        demo.select(game, isSimulatedMode: true)
        let flowA = try XCTUnwrap(demo.flow(for: game, isSimulatedMode: true))
        recordPassingEffort(on: flowA)
        XCTAssertEqual(flowA.finishChallenge().decision, .granted)
        XCTAssertFalse(flowA.isShieldPresented)

        // Unlock B: the shared manager replaces A's window.
        demo.select(video, isSimulatedMode: true)
        let flowB = try XCTUnwrap(demo.flow(for: video, isSimulatedMode: true))
        XCTAssertTrue(flowB.isShieldPresented)
        recordPassingEffort(on: flowB)
        XCTAssertEqual(flowB.finishChallenge().decision, .granted)
        XCTAssertFalse(flowB.isShieldPresented)

        // Re-select A: shielded immediately, no stale unlocked state.
        demo.select(game, isSimulatedMode: true)
        XCTAssertTrue(flowA.isShieldPresented)
        XCTAssertEqual(flowA.managedSettingsCallCount, 0)
    }

    /// Enough effort to clear any per-session threshold draw (8...14):
    /// 5 attempts (10 pts) + 5 hints (10 pts) = 20.
    @MainActor
    private func recordPassingEffort(on flow: SimulatedShieldFlow) {
        for _ in 0..<5 { flow.submitAttempt(answer: "practice try") }
        for _ in 0..<5 { flow.useHint() }
    }
}
