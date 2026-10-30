import Foundation
import XCTest
@testable import EarnPlayCore

/// T4.5 fix round 1 repro/fix tests (PR #61 items 1,6,7,8,9,10,11 + helpers).
final class AuditorFixRound1Tests: XCTestCase {
    private let engine = AuditorEngine()
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func dec(_ id: String, _ s: String, _ t: DecisionType, _ ev: String, at o: TimeInterval, outcome: String = "recorded") -> Decision {
        Decision(decisionId: id, sessionId: s, type: t, outcome: outcome, evidenceSummary: ev, reasoning: "r", alternativeConsidered: "a", confidence: 0.85, timestamp: base.addingTimeInterval(o))
    }
    private func ev(total: Int, bar: Int, floor: Bool, _ s: EffortSignals) -> String {
        "Evidence: \(s.activeMinutes) active minutes (\(s.activeSeconds)s active time), \(s.genuineAttempts) genuine attempts, \(s.hintInteractions) hint interactions, \(s.followUpInteractions) follow-up interactions, \(s.answerRevisions) answer revisions, \(s.explanations) explanations; score \(total) vs threshold \(bar); floor \(floor ? "met" : "not met")."
    }
    private func strong(_ a: Int = 4) -> EffortSignals { EffortSignals(activeSeconds: 600, genuineAttempts: a, hintInteractions: 2, followUpInteractions: 1, answerRevisions: 1, explanations: 1) }

    // Item 1: two mismatch findings in one session must have unique ids, and recordRun must not trap.
    func testItem1UniqueMismatchIdsAndRecordRunNoTrap() throws {
        let bad1 = Decision(decisionId: "d1", sessionId: "dup-1", type: .grantUnlock, outcome: "", evidenceSummary: "", reasoning: "", alternativeConsidered: "", confidence: 2, timestamp: base)
        let bad2 = Decision(decisionId: "d2", sessionId: "dup-1", type: .denyUnlock, outcome: "", evidenceSummary: "", reasoning: "", alternativeConsidered: "", confidence: 2, timestamp: base.addingTimeInterval(10))
        let ex = AuditorSessionExcerpt(sessionId: "dup-1", startedAt: base, endedAt: base.addingTimeInterval(900), decisions: [bad1, bad2], effortTotal: 5, effortBar: 8, floorMet: true, signals: strong())
        let flags = engine.audit([ex])
        let mm = flags.filter { $0.category == .justificationMismatch }
        XCTAssertEqual(mm.count, 2, "\(flags)")
        XCTAssertEqual(Set(mm.map(\.flagId)).count, mm.count, "duplicate flagIds: \(mm.map(\.flagId))")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AudR1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let m = AuditFlagManager(directory: dir); m.recordRun(flags); m.recordRun(flags)
        XCTAssertEqual(m.openFlags.count, mm.count)
        if let f = mm.first { m.dismiss(flagId: f.flagId); XCTAssertFalse(m.openFlags.contains { $0.flagId == f.flagId }); XCTAssertTrue(m.openFlags.contains { $0.flagId != f.flagId }) }
    }
    // Item 1b: already-persisted duplicates must not trap on next recordRun.
    func testItem1PersistedDuplicatesDeduped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AudR1b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let f = AuditFlag(flagId: "audit-justification-mismatch-dupX", sessionId: "dupX", category: .justificationMismatch, severity: .act, evidence: "Session dupX: x", suggestedAction: "a")
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        try enc.encode([f, f]).write(to: dir.appendingPathComponent(AuditFlagManager.fileName))
        let m = AuditFlagManager(directory: dir); m.recordRun([f]) // must not trap
        XCTAssertFalse(m.allFlags.isEmpty)
    }
    // Item 8: deny-then-grant honest session must not flag earlier denial.
    func testItem8DenyThenGrantNoFalseMismatch() {
        let denySig = EffortSignals(activeSeconds: 120, genuineAttempts: 1, hintInteractions: 0)
        let grantSig = strong(5)
        let dDeny = dec("dd", "dg-1", .denyUnlock, ev(total: 3, bar: 8, floor: false, denySig), at: 0)
        let dGrant = dec("dg", "dg-1", .grantUnlock, ev(total: 12, bar: 8, floor: true, grantSig), at: 600)
        let ex = AuditorSessionExcerpt(sessionId: "dg-1", startedAt: base, endedAt: base.addingTimeInterval(900), decisions: [dDeny, dGrant], effortTotal: 12, effortBar: 8, floorMet: true, signals: grantSig)
        let flags = engine.audit([ex])
        XCTAssertFalse(flags.contains { $0.category == .justificationMismatch }, "\(flags)")
    }
    // Item 9: wrong hint/follow-up/revision/explanation counts must flag.
    func testItem9AllSixSignalsValidated() {
        let raw = EffortSignals(activeSeconds: 600, genuineAttempts: 4, hintInteractions: 0, followUpInteractions: 0, answerRevisions: 0, explanations: 0)
        let claimed = EffortSignals(activeSeconds: 600, genuineAttempts: 4, hintInteractions: 2, followUpInteractions: 3, answerRevisions: 2, explanations: 2)
        let d = dec("d9", "six-1", .grantUnlock, ev(total: 10, bar: 8, floor: true, claimed), at: 0)
        let ex = AuditorSessionExcerpt(sessionId: "six-1", startedAt: base, endedAt: base.addingTimeInterval(900), decisions: [d], effortTotal: 10, effortBar: 8, floorMet: true, signals: raw)
        XCTAssertTrue(engine.audit([ex]).contains { $0.category == .justificationMismatch }, "\(engine.audit([ex]))")
    }
    // Item 10: differing bars, each outcome follows own bar -> no inconsistency. Plus boundary.
    func testItem10EligibilityConsistentNoInconsistency() {
        func sess(_ id: String, _ o: TimeInterval, _ g: Bool, _ t: Int, _ b: Int) -> AuditorSessionExcerpt {
            let d = dec("d-\(id)", id, g ? .grantUnlock : .denyUnlock, ev(total: t, bar: b, floor: true, strong()), at: o)
            return AuditorSessionExcerpt(sessionId: id, startedAt: base.addingTimeInterval(o), endedAt: base.addingTimeInterval(o + 900), decisions: [d], effortTotal: t, effortBar: b, floorMet: true, signals: strong())
        }
        XCTAssertFalse(engine.audit([sess("bar-1", 0, true, 10, 8), sess("bar-2", 3600, false, 10, 14)]).contains { $0.category == .inconsistency })
        XCTAssertFalse(engine.audit([sess("bnd-1", 0, true, 8, 8), sess("bnd-2", 3600, false, 7, 8)]).contains { $0.category == .inconsistency })
        // True inconsistency still flags: same bar, close totals, opposite outcomes not explained by bar.
        XCTAssertTrue(engine.audit([sess("inc-1", 0, true, 10, 8), sess("inc-2", 3600, false, 11, 8)]).contains { $0.category == .inconsistency })
    }
    // Item 6: SessionLog-derived excerpt self-compares -> no mismatch (limitation), documented.
    func testItem6SessionLogSelfComparisonLimitation() {
        let lying = ev(total: 99, bar: 8, floor: true, strong(9))
        let d = dec("d6", "self-1", .grantUnlock, lying, at: 0)
        let log = SessionLog(sessionId: "self-1", startedAt: base, endedAt: base.addingTimeInterval(900), decisions: [d], policyVersion: 1)
        let ex = AuditorSessionExcerpt(sessionLog: log)
        XCTAssertFalse(ex.hasIndependentSnapshot)
        XCTAssertFalse(engine.audit([ex]).contains { $0.category == .justificationMismatch })
    }
    // Item 7: SessionLog with question detail must reach difficulty check.
    func testItem7SessionLogQuestionsReachCheck() {
        let qs = (0..<5).map { AuditorQuestionRecord(questionId: "q\($0)", form: "story", difficulty: 1, answerMatched: true) }
        let d = dec("d7", "q-1", .grantUnlock, ev(total: 11, bar: 8, floor: true, strong()), at: 0)
        let log = SessionLog(sessionId: "q-1", startedAt: base, endedAt: base.addingTimeInterval(900), decisions: [d], policyVersion: 1, questions: qs, rawSignals: strong(), rawEffortTotal: 11, rawEffortBar: 8, rawFloorMet: true)
        let ex = AuditorSessionExcerpt(sessionLog: log)
        XCTAssertEqual(ex.questions.count, 5)
        XCTAssertTrue(ex.hasIndependentSnapshot)
        XCTAssertTrue(engine.audit([ex]).contains { $0.category == .difficultyMiscalibration }, "\(engine.audit([ex]))")
        // And independent raw that contradicts claim must flag mismatch (item 6 fix path).
        let lying = ev(total: 99, bar: 8, floor: true, strong(9))
        let d2 = dec("d7b", "q-2", .grantUnlock, lying, at: 0)
        let log2 = SessionLog(sessionId: "q-2", startedAt: base, endedAt: base.addingTimeInterval(900), decisions: [d2], policyVersion: 1, rawSignals: strong(), rawEffortTotal: 11, rawEffortBar: 8, rawFloorMet: true)
        XCTAssertTrue(engine.audit([AuditorSessionExcerpt(sessionLog: log2)]).contains { $0.category == .justificationMismatch })
    }
    // Item 3 helper + Item 2 helper
    func testItem3ScoreFreePresentation() {
        let raw = "Evidence: 10 active minutes (600s active time), 4 genuine attempts, 2 hint interactions; score 12 vs threshold 8; floor met. Granted unlock (score 12 vs threshold 8)"
        let out = AuditorScoreFreeText.make(raw)
        XCTAssertFalse(out.contains("12"), out); XCTAssertFalse(out.lowercased().contains("score"), out); XCTAssertFalse(out.lowercased().contains("threshold"), out)
        XCTAssertTrue(out.contains("4 genuine attempts"), out); XCTAssertTrue(out.contains("2 hint interactions"), out)
        let out2 = AuditorScoreFreeText.make("Session s: effortTotal 12, effortBar 8, floorMet true, genuineAttempts 4")
        XCTAssertFalse(out2.contains("12"), out2); XCTAssertTrue(out2.contains("genuineAttempts 4"), out2)
    }
    func testItem2CitedSessions() {
        let f = AuditFlag(flagId: "x", sessionId: "inc-2", category: .inconsistency, severity: .watch, evidence: "Session inc-2: a. Earlier session inc-1: b.", suggestedAction: "Open both session excerpts")
        XCTAssertEqual(f.citedSessionIds(knownSessionIds: ["inc-1", "inc-2", "other"]), ["inc-2", "inc-1"])
    }
    // Item 5: audit hook fires after a session is successfully stored.
    func testItem5AuditHookOnStoredSession() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AudR5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let (at, _, _) = InMemorySyncTransport.pair()
        let admin = AdminSyncService(policyQueue: PolicyUpdateQueue(directory: dir.appendingPathComponent("q")), sessionStore: SessionLogStore(directory: dir.appendingPathComponent("s")), transport: at)
        var stored: [String] = []
        admin.onSessionStored = { stored.append($0.sessionId) }
        admin.start()
        let d = dec("d5", "recv-1", .denyUnlock, ev(total: 12, bar: 8, floor: true, strong(5)), at: 0)
        let log = SessionLog(sessionId: "recv-1", startedAt: base, endedAt: base.addingTimeInterval(900), decisions: [d], policyVersion: 1)
        admin.handleReceived(try SyncMessageCodec.encode(.sessionLog(log)))
        XCTAssertEqual(stored, ["recv-1"])
        admin.handleReceived(try SyncMessageCodec.encode(.sessionLog(log)))
        XCTAssertEqual(stored, ["recv-1"], "duplicate must not re-audit")
    }
    // Item 11: failing writer -> dismiss/act report failure, flag stays open, no success.
    func testItem11PersistenceFailurePropagates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AudR11-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        struct WErr: Error {}
        // First write succeeds to seed, then fail.
        var fail = false
        let m = AuditFlagManager(directory: dir, dataWriter: { data, url in if fail { throw WErr() }; try data.write(to: url, options: [.atomic]) })
        let d = dec("d11", "fn-11", .denyUnlock, ev(total: 12, bar: 8, floor: true, strong(5)), at: 0)
        let ex = AuditorSessionExcerpt(sessionId: "fn-11", startedAt: base, endedAt: base.addingTimeInterval(900), decisions: [d], effortTotal: 12, effortBar: 8, floorMet: true, signals: strong(5))
        XCTAssertTrue(m.recordRun(engine.audit([ex])))
        let flag = try XCTUnwrap(m.openFlags.first)
        fail = true
        XCTAssertFalse(m.dismiss(flagId: flag.flagId))
        XCTAssertTrue(m.openFlags.contains { $0.flagId == flag.flagId }, "choice lost on failed write")
        XCTAssertNotNil(m.lastPersistenceError)
        XCTAssertNil(m.markActed(flagId: flag.flagId))
        XCTAssertTrue(m.openFlags.contains { $0.flagId == flag.flagId })
    }
}
