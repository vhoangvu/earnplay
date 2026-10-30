import Foundation
import XCTest
@testable import EarnPlayCore

/// T4.5 fix round 3 repro/fix tests (PR #61 review on 02ecd83, items 1-5).
final class AuditorFixRound3Tests: XCTestCase {
    private let engine = AuditorEngine()
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func dec(_ id: String, _ s: String, _ t: DecisionType, _ ev: String, at o: TimeInterval) -> Decision {
        Decision(decisionId: id, sessionId: s, type: t, outcome: "recorded", evidenceSummary: ev, reasoning: "r", alternativeConsidered: "a", confidence: 0.85, timestamp: base.addingTimeInterval(o))
    }
    private func ev(total: Int, bar: Int, floor: Bool, _ s: EffortSignals) -> String {
        "Evidence: \(s.activeMinutes) active minutes (\(s.activeSeconds)s active time), \(s.genuineAttempts) genuine attempts, \(s.hintInteractions) hint interactions, \(s.followUpInteractions) follow-up interactions, \(s.answerRevisions) answer revisions, \(s.explanations) explanations; score \(total) vs threshold \(bar); floor \(floor ? "met" : "not met")."
    }
    private func strong(_ a: Int = 4) -> EffortSignals { EffortSignals(activeSeconds: 600, genuineAttempts: a, hintInteractions: 2, followUpInteractions: 1, answerRevisions: 1, explanations: 1) }
    private func granted(_ id: String, _ o: TimeInterval, _ total: Int, _ sig: EffortSignals) -> AuditorSessionExcerpt {
        AuditorSessionExcerpt(sessionId: id, startedAt: base.addingTimeInterval(o), endedAt: base.addingTimeInterval(o + 900),
            decisions: [dec("d-\(id)", id, .grantUnlock, ev(total: total, bar: 8, floor: true, sig), at: o)],
            effortTotal: total, effortBar: 8, floorMet: true, signals: sig)
    }

    // Item 4: attempts [nil, 5, 5, 5, 0] — one missing observation must
    // not disable the check; the drop after three usable baselines flags.
    func testItem4MissingObservationDoesNotDisableShiftDetection() {
        var sessions: [AuditorSessionExcerpt] = [
            AuditorSessionExcerpt(sessionId: "sh0", startedAt: base, endedAt: base.addingTimeInterval(900),
                decisions: [dec("d-sh0", "sh0", .sessionJudgment, ev(total: 11, bar: 8, floor: true, strong(5)), at: 0)],
                effortTotal: 11, effortBar: 8, floorMet: true, signals: nil),
        ]
        for i in 1...3 {
            sessions.append(granted("sh\(i)", TimeInterval(i * 3600), 11, strong(5)))
        }
        sessions.append(AuditorSessionExcerpt(sessionId: "sh4", startedAt: base.addingTimeInterval(14400), endedAt: base.addingTimeInterval(15300),
            decisions: [dec("d-sh4", "sh4", .denyUnlock, ev(total: 2, bar: 8, floor: false, EffortSignals(activeSeconds: 30)), at: 14400)],
            effortTotal: 2, effortBar: 8, floorMet: false, signals: EffortSignals(activeSeconds: 30, genuineAttempts: 0)))
        let flags = engine.audit(sessions)
        XCTAssertTrue(flags.contains { $0.category == .behaviorShift && $0.sessionId == "sh4" },
                      "drop after three usable baselines must flag despite one missing observation: \(flags)")
    }

    // Item 5: a session with raw effort values but no unlock decision
    // (only a session judgment) must never be compared as if denied.
    func testItem5AbsentUnlockDecisionIsNotADenial() {
        let grant = granted("inc-g", 0, 10, strong(5))
        let noDecision = AuditorSessionExcerpt(sessionId: "inc-n", startedAt: base.addingTimeInterval(3600), endedAt: base.addingTimeInterval(4500),
            decisions: [dec("d-inc-n", "inc-n", .sessionJudgment, ev(total: 10, bar: 8, floor: true, strong(5)), at: 3600)],
            effortTotal: 10, effortBar: 8, floorMet: true, signals: strong(5))
        XCTAssertNil(noDecision.unlockDecision)
        XCTAssertFalse(noDecision.hasUnlockDecision)
        let flags = engine.audit([grant, noDecision])
        XCTAssertFalse(flags.contains { $0.category == .inconsistency },
                       "absent decision misreported as denial: \(flags)")
    }

    // Item 5 control: a genuine grant vs a genuine denial on close
    // evidence still flags, so the fix does not silence the check.
    func testItem5GenuineGrantVsDenialStillFlags() {
        let grant = granted("inc-g2", 0, 10, strong(5))
        let deny = AuditorSessionExcerpt(sessionId: "inc-d2", startedAt: base.addingTimeInterval(3600), endedAt: base.addingTimeInterval(4500),
            decisions: [dec("d-inc-d2", "inc-d2", .denyUnlock, ev(total: 10, bar: 8, floor: true, strong(5)), at: 3600)],
            effortTotal: 10, effortBar: 8, floorMet: true, signals: strong(5))
        XCTAssertTrue(deny.hasUnlockDecision)
        let flags = engine.audit([grant, deny])
        XCTAssertTrue(flags.contains { $0.category == .inconsistency && $0.sessionId == "inc-d2" }, "\(flags)")
    }

    // Item 3 (gate seam): a request arriving mid-run coalesces into one
    // rerun instead of being dropped.
    func testItem3GateCoalescesRequestDuringRun() {
        let gate = AuditRunGate()
        XCTAssertTrue(gate.beginOrMarkDirty(), "first request starts the run")
        XCTAssertFalse(gate.beginOrMarkDirty(), "request during a run must not start a parallel run")
        XCTAssertTrue(gate.hasPendingRerun, "request during a run must be remembered, not dropped")
        XCTAssertTrue(gate.finish(), "finishing with a pending request must ask for exactly one rerun")
        XCTAssertTrue(gate.isRunning, "the rerun keeps the run in flight")
        XCTAssertFalse(gate.hasPendingRerun)
        XCTAssertFalse(gate.finish(), "no further request arrived, so the run ends")
        XCTAssertFalse(gate.isRunning)
    }

    // Items 1-3 (performer seam): audit work runs off the main queue,
    // publishing hops to the main queue, and a request stored mid-audit
    // is audited by one coalesced rerun.
    func testItems123PerformerOffMainWorkMainPublishCoalescedRerun() {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var workCount = 0
            var publishCount = 0
            var workOnMain: [Bool] = []
            var publishOnMain: [Bool] = []
            func snapshot() -> (Int, Int, [Bool], [Bool]) {
                lock.lock(); defer { lock.unlock() }
                return (workCount, publishCount, workOnMain, publishOnMain)
            }
        }
        let box = Box()
        let performer = AuditRunPerformer(workQueue: DispatchQueue(label: "test.audit.work"))
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        performer.request(work: {
            box.lock.lock(); box.workCount += 1; box.workOnMain.append(Thread.isMainThread); let n = box.workCount; box.lock.unlock()
            if n == 1 { started.signal(); _ = release.wait(timeout: .now() + 5) }
        }, publish: {
            box.lock.lock(); box.publishCount += 1; box.publishOnMain.append(Thread.isMainThread); box.lock.unlock()
        })
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success, "first audit work never started")
        // A session stored while the first audit is in flight.
        performer.request(work: {
            box.lock.lock(); box.workCount += 1; box.workOnMain.append(Thread.isMainThread); box.lock.unlock()
        }, publish: {
            box.lock.lock(); box.publishCount += 1; box.publishOnMain.append(Thread.isMainThread); box.lock.unlock()
        })
        release.signal()
        // Publishing hops to the main queue, so pump the main run loop
        // until the coalesced rerun has published (or time out).
        let deadline = Date().addingTimeInterval(5)
        while box.snapshot().1 < 2 && Date() < deadline {
            _ = RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let snap = box.snapshot()
        XCTAssertEqual(snap.0, 2, "mid-audit request must be audited by one rerun, not dropped")
        XCTAssertEqual(snap.1, 2)
        XCTAssertEqual(snap.2, [false, false], "audit work must stay off the main queue")
        XCTAssertEqual(snap.3, [true, true], "publishing must hop to the main queue")
        XCTAssertFalse(performer.isRunning)
    }
}
