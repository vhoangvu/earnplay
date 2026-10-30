import Foundation
import XCTest
@testable import EarnPlayCore

/// T4.5 fix round 2 repro/fix tests (PR #61 review on 611324a, items 1-6).
final class AuditorFixRound2Tests: XCTestCase {
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

    // Item 3: an actual mismatch flag's "raw log field ... is N" evidence must be redacted.
    func testItem3ActualMismatchEvidenceRedacted() {
        let claimed = EffortSignals(activeSeconds: 600, genuineAttempts: 4, hintInteractions: 2, followUpInteractions: 1, answerRevisions: 1, explanations: 1)
        let d = dec("dec-mmx", "mmx", .grantUnlock, ev(total: 14, bar: 9, floor: true, claimed), at: 0)
        let ex = AuditorSessionExcerpt(sessionId: "mmx", startedAt: base, endedAt: base.addingTimeInterval(900), decisions: [d], effortTotal: 3, effortBar: 8, floorMet: true, signals: claimed)
        let flag = engine.audit([ex]).first { $0.category == .justificationMismatch }
        let mismatch = try! XCTUnwrap(flag, "expected mismatch flag")
        XCTAssertTrue(mismatch.evidence.contains("raw log field effortTotal is 3"), mismatch.evidence)
        let shown = AuditorScoreFreeText.make(mismatch.evidence)
        XCTAssertFalse(shown.contains("is 3"), shown)
        XCTAssertFalse(shown.contains("is 8"), shown)
        XCTAssertFalse(shown.contains("14"), shown)
        XCTAssertFalse(shown.contains("effortTotal is"), shown)
        XCTAssertFalse(shown.contains("effortBar is"), shown)
        // Direct prompt examples.
        XCTAssertFalse(AuditorScoreFreeText.make("raw log field effortTotal is 3").contains("3"))
        XCTAssertFalse(AuditorScoreFreeText.make("raw log field effortBar is 8").contains("8"))
    }

    // Item 4: later descending streak flags even when an earlier grant breaks the global sequence.
    func testItem4LaterDriftFlagsDespiteEarlierRise() {
        let sessions = [granted("lenA", 0, 10, strong(5)), granted("lenB", 3600, 14, strong(5)),
                        granted("lenC", 7200, 11, strong(4)), granted("lenD", 10800, 8, strong(3))]
        let flags = engine.audit(sessions)
        XCTAssertTrue(flags.contains { $0.category == .leniencyDrift }, "\(flags.map(\.category))")
    }

    // Item 5: shift in the fourth of five sessions flags, not only shifts in the last.
    func testItem5EarlierShiftInBacklogFlags() {
        var sessions = (0..<3).map { granted("shf\($0)", TimeInterval($0 * 3600), 11, strong(5)) }
        sessions.append(AuditorSessionExcerpt(sessionId: "shf3", startedAt: base.addingTimeInterval(10800), endedAt: base.addingTimeInterval(11700),
            decisions: [dec("d-shf3", "shf3", .denyUnlock, ev(total: 2, bar: 8, floor: false, EffortSignals(activeSeconds: 30)), at: 10800)],
            effortTotal: 2, effortBar: 8, floorMet: false, signals: EffortSignals(activeSeconds: 30, genuineAttempts: 0)))
        sessions.append(granted("shf4", 14400, 11, strong(5)))
        let flags = engine.audit(sessions)
        XCTAssertTrue(flags.contains { $0.category == .behaviorShift && $0.sessionId == "shf3" }, "\(flags)")
    }

    // Item 6: previously open findings survive a later run that omits them.
    func testItem6PreviouslyOpenPreservedAcrossRuns() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AudR2-6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let m = AuditFlagManager(directory: dir)
        let f1 = AuditFlag(flagId: "audit-false-negative-keep1", sessionId: "keep1", category: .falseNegative, severity: .watch, evidence: "Session keep1: x", suggestedAction: "a")
        let f2 = AuditFlag(flagId: "audit-false-negative-keep2", sessionId: "keep2", category: .falseNegative, severity: .watch, evidence: "Session keep2: x", suggestedAction: "a")
        XCTAssertTrue(m.recordRun([f1]))
        XCTAssertTrue(m.recordRun([f2]), "run omitting keep1 must succeed")
        XCTAssertTrue(m.openFlags.contains { $0.flagId == f1.flagId }, "previously open finding silently deleted: \(m.openFlags)")
        XCTAssertTrue(m.openFlags.contains { $0.flagId == f2.flagId })
        // Only parent action removes it.
        XCTAssertTrue(m.dismiss(flagId: f1.flagId))
        XCTAssertTrue(m.recordRun([]))
        XCTAssertFalse(m.openFlags.contains { $0.flagId == f1.flagId })
        XCTAssertTrue(m.openFlags.contains { $0.flagId == f2.flagId })
        XCTAssertEqual(m.allFlags.first { $0.flagId == f1.flagId }?.status, .dismissed)
    }

    // Item 1: overlapping audit runs are rejected until the running one ends.
    func testItem1RunGateRejectsOverlap() {
        let gate = AuditRunGate()
        XCTAssertTrue(gate.tryBegin())
        XCTAssertFalse(gate.tryBegin(), "second overlapping run must be rejected")
        XCTAssertTrue(gate.isRunning)
        gate.end()
        XCTAssertFalse(gate.isRunning)
        XCTAssertTrue(gate.tryBegin())
        gate.end()
    }

    // Item 2: completion message reflects persistence; success only after durable write.
    func testItem2CompletionMessageReflectsPersistence() {
        let ok = AuditorRunStatus.completionMessage(openCount: 2, persistenceError: nil)
        XCTAssertTrue(ok.contains("Auditor run complete"), ok)
        XCTAssertTrue(ok.contains("2 open finding(s)"), ok)
        let bad = AuditorRunStatus.completionMessage(openCount: 2, persistenceError: "disk full")
        XCTAssertTrue(bad.lowercased().contains("could not save"), bad)
        XCTAssertTrue(bad.lowercased().contains("again"), bad)
        XCTAssertFalse(bad.contains("Auditor run complete"), bad)
    }
}
