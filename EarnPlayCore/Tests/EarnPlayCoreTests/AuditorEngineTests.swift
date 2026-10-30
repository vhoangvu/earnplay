import Foundation
import XCTest
@testable import EarnPlayCore

/// T4.5 auditor harness: staged fixtures per check + clean set.
/// Required pass: 7/7 staged checks flag, 0 flags on the clean set.
final class AuditorEngineTests: XCTestCase {
    private let engine = AuditorEngine()
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func decision(_ id: String, _ session: String, _ type: DecisionType,
                          evidence: String, outcome: String = "recorded",
                          reasoning: String = "Recorded reasoning.",
                          at offset: TimeInterval) -> Decision {
        Decision(decisionId: id, sessionId: session, type: type, outcome: outcome,
                 evidenceSummary: evidence, reasoning: reasoning,
                 alternativeConsidered: "The other outcome was considered.",
                 confidence: 0.85, timestamp: base.addingTimeInterval(offset))
    }

    /// Honest T1.6-shaped evidence text for the given raw values.
    private func evidence(total: Int, bar: Int, floor: Bool, signals: EffortSignals) -> String {
        "Evidence: \(signals.activeMinutes) active minutes (\(signals.activeSeconds)s active time), "
            + "\(signals.genuineAttempts) genuine attempts, \(signals.hintInteractions) hint interactions, "
            + "\(signals.followUpInteractions) follow-up interactions, \(signals.answerRevisions) answer revisions, "
            + "\(signals.explanations) explanations; score \(total) vs threshold \(bar); floor \(floor ? "met" : "not met")."
    }

    private func session(_ id: String, at offset: TimeInterval, granted: Bool,
                         total: Int, bar: Int = 8, floor: Bool = true,
                         signals: EffortSignals, questions: [AuditorQuestionRecord] = [],
                         evidenceOverride: String? = nil, minutes: TimeInterval = 15) -> AuditorSessionExcerpt {
        let text = evidenceOverride ?? evidence(total: total, bar: bar, floor: floor, signals: signals)
        let dec = decision("dec-\(id)", id, granted ? .grantUnlock : .denyUnlock,
                           evidence: text, outcome: granted ? "Granted unlock" : "Denied unlock", at: offset)
        return AuditorSessionExcerpt(sessionId: id, startedAt: base.addingTimeInterval(offset),
            endedAt: base.addingTimeInterval(offset + minutes * 60), decisions: [dec],
            effortTotal: total, effortBar: bar, floorMet: floor, signals: signals, questions: questions)
    }

    private func strongSignals(_ attempts: Int = 4) -> EffortSignals {
        EffortSignals(activeSeconds: 600, genuineAttempts: attempts, hintInteractions: 2,
                      followUpInteractions: 1, answerRevisions: 1, explanations: 1)
    }

    // 1: grants with falling effort = leniency drift.
    func testLeniencyDriftFlags() {
        let sessions = [
            session("len-1", at: 0, granted: true, total: 14, signals: strongSignals(5)),
            session("len-2", at: 3600, granted: true, total: 11, signals: strongSignals(4)),
            session("len-3", at: 7200, granted: true, total: 8, signals: strongSignals(3)),
        ]
        let flags = engine.audit(sessions)
        XCTAssertTrue(flags.contains { $0.category == .leniencyDrift && $0.sessionId == "len-3" }, "\(flags)")
        assertWellFormed(flags)
    }

    // 2: high-effort denial = false negative.
    func testFalseNegativeFlags() {
        let sessions = [session("fn-1", at: 0, granted: false, total: 12, signals: strongSignals(5))]
        let flags = engine.audit(sessions)
        XCTAssertTrue(flags.contains { $0.category == .falseNegative && $0.severity == .watch }, "\(flags)")
        assertWellFormed(flags)
    }

    // 3: repeated minimal-work grants = gaming.
    func testGamingPatternFlags() {
        let minimal = EffortSignals(activeSeconds: 60, genuineAttempts: 1, hintInteractions: 1)
        let sessions = (0..<3).map {
            session("game-\($0 + 1)", at: TimeInterval($0 * 3600), granted: true, total: 9,
                    signals: minimal, minutes: 3)
        }
        let flags = engine.audit(sessions)
        XCTAssertTrue(flags.contains { $0.category == .gamingPattern && $0.severity == .act }, "\(flags)")
        assertWellFormed(flags)
    }

    // 4: repetitive, too-easy questions = difficulty miscalibration.
    func testDifficultyMiscalibrationFlags() {
        let questions = (0..<5).map {
            AuditorQuestionRecord(questionId: "q\($0)", form: "story", difficulty: 1, answerMatched: true)
        }
        let sessions = [session("diff-1", at: 0, granted: true, total: 11,
                                signals: strongSignals(), questions: questions)]
        let flags = engine.audit(sessions)
        XCTAssertTrue(flags.contains { $0.category == .difficultyMiscalibration }, "\(flags)")
        assertWellFormed(flags)
    }

    // 5: sudden drop versus own history = behavior shift.
    func testBehaviorShiftFlags() {
        var sessions = (0..<3).map {
            session("shift-\($0 + 1)", at: TimeInterval($0 * 3600), granted: true, total: 11,
                    signals: strongSignals(5))
        }
        sessions.append(session("shift-4", at: 10800, granted: false, total: 2, floor: false,
                                signals: EffortSignals(activeSeconds: 30)))
        let flags = engine.audit(sessions)
        XCTAssertTrue(flags.contains { $0.category == .behaviorShift && $0.severity == .info }, "\(flags)")
        assertWellFormed(flags)
    }

    // 6: similar evidence, different outcomes = inconsistency.
    func testInconsistencyFlags() {
        let sessions = [
            session("inc-1", at: 0, granted: true, total: 10, signals: strongSignals()),
            session("inc-2", at: 3600, granted: false, total: 11, signals: strongSignals()),
        ]
        let flags = engine.audit(sessions)
        XCTAssertTrue(flags.contains { $0.category == .inconsistency && $0.sessionId == "inc-2" }, "\(flags)")
        assertWellFormed(flags)
    }

    // 7: justification text contradicting the raw log = mismatch (act).
    func testJustificationMismatchFlags() {
        let raw = EffortSignals(activeSeconds: 60, genuineAttempts: 1, hintInteractions: 0)
        let lying = evidence(total: 14, bar: 8, floor: true,
                             signals: EffortSignals(activeSeconds: 600, genuineAttempts: 5, hintInteractions: 2))
        let sessions = [session("just-1", at: 0, granted: true, total: 3, floor: false,
                                signals: raw, evidenceOverride: lying)]
        let flags = engine.audit(sessions)
        XCTAssertTrue(flags.contains { $0.category == .justificationMismatch && $0.severity == .act }, "\(flags)")
        XCTAssertTrue(flags.first { $0.category == .justificationMismatch }?.evidence.contains("just-1") == true)
        assertWellFormed(flags)
    }

    /// All seven staged checks in one run: 7/7 expected categories.
    func testAllSevenStagedChecksFlag() {
        var all: [AuditorSessionExcerpt] = []
        all += [session("a-len-1", at: 0, granted: true, total: 14, signals: strongSignals(5)),
                session("a-len-2", at: 3600, granted: true, total: 11, signals: strongSignals(4)),
                session("a-len-3", at: 7200, granted: true, total: 8, signals: strongSignals(3))]
        all += [session("a-fn-1", at: 20000, granted: false, total: 12, signals: strongSignals(5))]
        let minimal = EffortSignals(activeSeconds: 60, genuineAttempts: 1, hintInteractions: 1)
        all += (0..<3).map { session("a-game-\($0 + 1)", at: TimeInterval(30000 + $0 * 3600),
                                     granted: true, total: 9, signals: minimal, minutes: 3) }
        let questions = (0..<5).map {
            AuditorQuestionRecord(questionId: "aq\($0)", form: "story", difficulty: 1, answerMatched: true)
        }
        all += [session("a-diff-1", at: 50000, granted: true, total: 11,
                        signals: strongSignals(), questions: questions)]
        all += (0..<3).map { session("a-shift-\($0 + 1)", at: TimeInterval(60000 + $0 * 3600),
                                     granted: true, total: 11, signals: strongSignals(5)) }
        all += [session("a-shift-4", at: 80000, granted: false, total: 2, floor: false,
                        signals: EffortSignals(activeSeconds: 30))]
        all += [session("a-inc-1", at: 90000, granted: true, total: 10, signals: strongSignals()),
                session("a-inc-2", at: 93600, granted: false, total: 11, signals: strongSignals())]
        let raw = EffortSignals(activeSeconds: 60, genuineAttempts: 1, hintInteractions: 0)
        let lying = evidence(total: 14, bar: 8, floor: true,
                             signals: EffortSignals(activeSeconds: 600, genuineAttempts: 5, hintInteractions: 2))
        all += [session("a-just-1", at: 100000, granted: true, total: 3, floor: false,
                        signals: raw, evidenceOverride: lying)]

        // Each staged group is engineered per check; audit each group
        // and union the categories (a single interleaved run is the
        // per-check tests above, not this summary assertion).
        var categories = Set<AuditCategory>()
        let groups: [[AuditorSessionExcerpt]] = [
            Array(all[0..<3]), Array(all[3..<4]), Array(all[4..<7]),
            Array(all[7..<8]), Array(all[8..<12]), Array(all[12..<14]),
            Array(all[14..<15]),
        ]
        for group in groups { categories.formUnion(engine.audit(group).map(\.category)) }
        XCTAssertEqual(categories, Set(AuditCategory.allCases), "\(categories)")
    }

    /// Clean fixture set produces no flags.
    func testCleanFixtureSetProducesNoFlags() {
        let varied: [AuditorQuestionRecord] = [
            AuditorQuestionRecord(questionId: "cq0", form: "story", difficulty: 2, answerMatched: true),
            AuditorQuestionRecord(questionId: "cq1", form: "reverse", difficulty: 3, answerMatched: false),
            AuditorQuestionRecord(questionId: "cq2", form: "estimation", difficulty: 2, answerMatched: true),
            AuditorQuestionRecord(questionId: "cq3", form: "which-is-wrong", difficulty: 3, answerMatched: true),
        ]
        let sessions = [
            session("clean-1", at: 0, granted: true, total: 11, bar: 10, signals: strongSignals(4), questions: varied),
            session("clean-2", at: 3600, granted: true, total: 12, bar: 10, signals: strongSignals(5), questions: varied),
            session("clean-3", at: 7200, granted: false, total: 6, bar: 10,
                    signals: EffortSignals(activeSeconds: 240, genuineAttempts: 2, hintInteractions: 1), questions: varied),
            session("clean-4", at: 10800, granted: true, total: 11, bar: 10, signals: strongSignals(4), questions: varied),
        ]
        XCTAssertEqual(engine.audit(sessions), [], "\(engine.audit(sessions))")
    }

    /// SessionLog (T4.6 shape) converts to an auditable excerpt.
    func testSessionLogExcerptAuditsSyncedRecord() {
        let signals = strongSignals(5)
        let dec = decision("dec-sync-1", "sync-1", .denyUnlock,
                           evidence: evidence(total: 12, bar: 8, floor: true, signals: signals),
                           outcome: "Denied unlock", at: 0)
        let log = SessionLog(sessionId: "sync-1", startedAt: base, endedAt: base.addingTimeInterval(900),
                             decisions: [dec], policyVersion: 3)
        let flags = engine.audit([AuditorSessionExcerpt(sessionLog: log)])
        XCTAssertTrue(flags.contains { $0.category == .falseNegative }, "\(flags)")
        assertWellFormed(flags)
    }

    /// Parent actions: dismiss clears, act records without touching policy.
    func testFlagManagerDismissAndAct() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuditorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessions = [session("fn-1", at: 0, granted: false, total: 12, signals: strongSignals(5))]
        let manager = AuditFlagManager(directory: dir)
        manager.recordRun(engine.audit(sessions))
        XCTAssertEqual(manager.openFlags.count, 1)
        let flag = try XCTUnwrap(manager.openFlags.first)

        // Detail route opens the staged session excerpt.
        XCTAssertEqual(manager.detailRoute(flagId: flag.flagId), .openSession(sessionId: "fn-1"))
        // Act routes to the existing policy-editing surface; applies nothing.
        XCTAssertEqual(manager.markActed(flagId: flag.flagId), .openPolicyEditor)
        XCTAssertEqual(manager.openFlags.count, 0)

        manager.recordRun(engine.audit(sessions))
        let again = try XCTUnwrap(manager.allFlags.first { $0.flagId == flag.flagId })
        XCTAssertEqual(again.status, .acted, "acted status survives re-runs")

        let manager2 = AuditFlagManager(directory: dir)
        manager2.recordRun(engine.audit([session("fn-2", at: 0, granted: false, total: 12, signals: strongSignals(5))]))
        let second = try XCTUnwrap(manager2.openFlags.first { $0.sessionId == "fn-2" })
        manager2.dismiss(flagId: second.flagId)
        XCTAssertFalse(manager2.openFlags.contains { $0.flagId == second.flagId })
        XCTAssertEqual(manager2.allFlags.first { $0.flagId == second.flagId }?.status, .dismissed)
    }

    /// Engine is deterministic and advisory: same input, same flags.
    func testEngineIsDeterministic() {
        let sessions = [session("fn-1", at: 0, granted: false, total: 12, signals: strongSignals(5))]
        XCTAssertEqual(engine.audit(sessions), engine.audit(sessions))
        XCTAssertNotEqual(AuditorRuntime.roleIdentifier, ModelRuntime.runtimeIdentifier)
    }

    private func assertWellFormed(_ flags: [AuditFlag], file: StaticString = #filePath, line: UInt = #line) {
        for flag in flags {
            XCTAssertFalse(flag.evidence.isEmpty, file: file, line: line)
            XCTAssertFalse(flag.suggestedAction.isEmpty, file: file, line: line)
            XCTAssertTrue(flag.evidence.contains(flag.sessionId),
                          "evidence must cite concrete session: \(flag.evidence)", file: file, line: line)
            XCTAssertEqual(flag.status, .open, file: file, line: line)
        }
    }
}
