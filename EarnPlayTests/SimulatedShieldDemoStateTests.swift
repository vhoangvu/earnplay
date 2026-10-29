import Foundation
import XCTest
import EarnPlayCore
@testable import EarnPlay

/// T2.4 fix round 2 (issue #15) — selecting a cached demo flow refreshes
/// it. The demo flows share one `ShieldManager`, so unlocking B replaces
/// A's window; re-selecting A must immediately show A's shield instead of
/// stale unlocked state (no timer tick required).
///
/// Fix round 3: every demo here roots in a unique temporary directory
/// (removed in teardown), so the suite never grants unlocks into the
/// demo's persistent data and never inherits an existing demo policy.
final class SimulatedShieldDemoStateTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatedShieldDemoStateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    @MainActor
    func testReselectingCachedFlowShowsShieldImmediately() throws {
        let demo = SimulatedShieldDemoState(directory: directory)
        let game = "earnplay.demo.game"
        let video = "earnplay.demo.video"

        // Unlock A.
        demo.select(game, isSimulatedMode: true)
        let flowA = try XCTUnwrap(demo.flow(for: game, isSimulatedMode: true))
        recordPassingEffort(on: flowA)
        XCTAssertEqual(flowA.finishChallenge()?.decision, .granted)
        XCTAssertFalse(flowA.isShieldPresented)

        // Unlock B: the shared manager replaces A's window.
        demo.select(video, isSimulatedMode: true)
        let flowB = try XCTUnwrap(demo.flow(for: video, isSimulatedMode: true))
        XCTAssertTrue(flowB.isShieldPresented)
        recordPassingEffort(on: flowB)
        XCTAssertEqual(flowB.finishChallenge()?.decision, .granted)
        XCTAssertFalse(flowB.isShieldPresented)

        // Re-select A: shielded immediately, no stale unlocked state.
        demo.select(game, isSimulatedMode: true)
        XCTAssertTrue(flowA.isShieldPresented)
        XCTAssertEqual(flowA.managedSettingsCallCount, 0)
    }

    /// An unlock granted in one directory never leaks into a demo
    /// rooted elsewhere: a fresh isolated demo still shows the app
    /// locked.
    @MainActor
    func testIsolatedDirectoriesDoNotShareUnlockState() throws {
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatedShieldDemoStateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: other) }

        let game = "earnplay.demo.game"
        let demo = SimulatedShieldDemoState(directory: directory)
        demo.select(game, isSimulatedMode: true)
        let flow = try XCTUnwrap(demo.flow(for: game, isSimulatedMode: true))
        recordPassingEffort(on: flow)
        XCTAssertEqual(flow.finishChallenge()?.decision, .granted)
        XCTAssertFalse(flow.isShieldPresented)

        let isolated = SimulatedShieldDemoState(directory: other)
        isolated.select(game, isSimulatedMode: true)
        let isolatedFlow = try XCTUnwrap(isolated.flow(for: game, isSimulatedMode: true))
        XCTAssertTrue(isolatedFlow.isShieldPresented)
        XCTAssertEqual(isolatedFlow.managedSettingsCallCount, 0)
    }

    /// Enough effort to clear any per-session threshold draw (8...14):
    /// 5 attempts (10 pts) + 5 hints (10 pts) = 20.
    @MainActor
    private func recordPassingEffort(on flow: SimulatedShieldFlow) {
        for _ in 0..<5 { flow.submitAttempt(answer: "practice try") }
        for _ in 0..<5 { flow.useHint() }
    }
}
