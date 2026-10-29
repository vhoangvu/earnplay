import Foundation
import XCTest
@testable import EarnPlayCore

/// T1.6 decision logger: every consequential decision writes a complete
/// Decision record before its effect is applied.
///
/// The required automated test is
/// `testUnlockGrantDenyAndDifficultyChangeProduceThreeCompleteRecordsInOrder`:
/// fixture grant + deny (both through the live `evaluateAndLog` unlock path)
/// + difficulty change (through the typed seam — test-only, no live
/// difficulty engine exists yet). Each record must carry all five
/// justification fields non-empty, the correct type, and ordered timestamps;
/// an empty-field record fails. Trade (`logTradeOffer`) and
/// session-judgment (`logSessionJudgment`) seams are covered as test-only
/// too: no T3.x / TutorEngine callers exist yet and none are invented here.
final class DecisionLoggerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DecisionLoggerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    // MARK: - Required automated test (grant + deny + difficulty)

    func testUnlockGrantDenyAndDifficultyChangeProduceThreeCompleteRecordsInOrder() throws {
        let logger = DecisionLogger(directory: directory)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // Fixture 1: genuinely-trying session (T1.4 fixture a) -> grant.
        let grantScorer = EffortScorer(threshold: 14)
        let grantSignals = EffortSignals(activeSeconds: 360, genuineAttempts: 3,
                                         hintInteractions: 1, followUpInteractions: 0,
                                         answerRevisions: 1, explanations: 1)
        let grant = try logger.evaluateAndLog(signals: grantSignals, scorer: grantScorer,
                                              sessionId: "session-grant",
                                              appId: "com.example.game", durationMinutes: 30,
                                              timestamp: base, decisionId: "decision-grant")
        XCTAssertEqual(grant.score.decision, .granted)
        XCTAssertTrue(grant.score.unlockGranted)

        // Fixture 2: idle session (T1.4 fixture b) -> deny.
        let denyScorer = EffortScorer(threshold: 8)
        let denySignals = EffortSignals(activeSeconds: ActiveTimeTracker.activeSeconds(
            interactionOffsets: [], startedAt: 0, evaluatedAt: 300))
        let deny = try logger.evaluateAndLog(signals: denySignals, scorer: denyScorer,
                                             sessionId: "session-deny",
                                             appId: "com.example.game", durationMinutes: 30,
                                             timestamp: base.addingTimeInterval(1),
                                             decisionId: "decision-deny")
        XCTAssertEqual(deny.score.decision, .denied)
        XCTAssertFalse(deny.score.unlockGranted)

        // Fixture 3: difficulty change via the typed seam (test-only: no live
        // difficulty engine exists yet, so the justification is fixture text).
        let difficulty = try logger.logDifficultyChange(
            sessionId: "session-difficulty",
            outcome: "Changed difficulty from 2 to 1 for fractions after 3 supported attempts.",
            evidenceSummary: "3 genuine attempts, 2 hint interactions, 0 correct, median response 45s.",
            reasoning: "Repeated supported failure at 2 shows the level is too hard to learn from.",
            alternativeConsidered: "Staying at 2 was rejected: more failure without progress.",
            confidence: 0.78,
            timestamp: base.addingTimeInterval(2),
            decisionId: "decision-difficulty")

        // 3/3 records exist.
        XCTAssertEqual(logger.decisions.count, 3)
        XCTAssertEqual(logger.decisions.map(\.decisionId),
                       ["decision-grant", "decision-deny", "decision-difficulty"])

        // Correct decision types.
        XCTAssertEqual(grant.decision.type, .grantUnlock)
        XCTAssertEqual(deny.decision.type, .denyUnlock)
        XCTAssertEqual(difficulty.type, .difficultyChange)

        // All five justification fields non-empty on every record.
        for record in logger.decisions {
            assertComplete(record)
        }

        // Timestamps in order.
        let stamps = logger.decisions.map(\.timestamp)
        XCTAssertLessThanOrEqual(stamps[0], stamps[1])
        XCTAssertLessThanOrEqual(stamps[1], stamps[2])
        XCTAssertEqual(stamps[0], base)
        XCTAssertEqual(stamps[1], base.addingTimeInterval(1))
        XCTAssertEqual(stamps[2], base.addingTimeInterval(2))
    }

    // MARK: - Justification content (live unlock path)

    func testUnlockEvidenceNamesWhatTheChildActuallyDid() throws {
        let logger = DecisionLogger(directory: directory)
        let scorer = EffortScorer(threshold: 14)
        let signals = EffortSignals(activeSeconds: 360, genuineAttempts: 3,
                                    hintInteractions: 1, answerRevisions: 1, explanations: 1)
        let result = try logger.evaluateAndLog(signals: signals, scorer: scorer,
                                               sessionId: "s1", appId: "com.example.game",
                                               durationMinutes: 30)
        let evidence = result.decision.evidenceSummary
        XCTAssertTrue(evidence.contains("6 active minutes"), evidence)
        XCTAssertTrue(evidence.contains("3 genuine attempts"), evidence)
        XCTAssertTrue(evidence.contains("1 hint interaction"), evidence)
        XCTAssertTrue(evidence.contains("1 answer revision"), evidence)
        XCTAssertTrue(evidence.contains("1 explanation"), evidence)
        XCTAssertTrue(evidence.contains("score 17 vs threshold 14"), evidence)
        assertComplete(result.decision)
    }

    func testGrantAndDenyJustificationsAreDistinctTexts() throws {
        let logger = DecisionLogger(directory: directory)
        let grant = try logger.evaluateAndLog(
            signals: EffortSignals(activeSeconds: 360, genuineAttempts: 3, hintInteractions: 1,
                                   answerRevisions: 1, explanations: 1),
            scorer: EffortScorer(threshold: 14),
            sessionId: "s-grant", appId: "com.example.game", durationMinutes: 30)
        let deny = try logger.evaluateAndLog(
            signals: EffortSignals(activeSeconds: 20),
            scorer: EffortScorer(threshold: 8),
            sessionId: "s-deny", appId: "com.example.game", durationMinutes: 30)
        // A deny entry must carry its own justification, not a copy of grant text.
        XCTAssertNotEqual(grant.decision.outcome, deny.decision.outcome)
        XCTAssertNotEqual(grant.decision.reasoning, deny.decision.reasoning)
        XCTAssertNotEqual(grant.decision.alternativeConsidered, deny.decision.alternativeConsidered)
        XCTAssertTrue(grant.decision.outcome.contains("Granted"), grant.decision.outcome)
        XCTAssertTrue(deny.decision.outcome.contains("Denied"), deny.decision.outcome)
    }

    func testDenyBelowThresholdNamesShortfallWhileFloorMet() throws {
        let logger = DecisionLogger(directory: directory)
        // Floor met (1 attempt + 1 hint) but score 5 < threshold 8.
        let result = try logger.evaluateAndLog(
            signals: EffortSignals(activeSeconds: 60, genuineAttempts: 1, hintInteractions: 1),
            scorer: EffortScorer(threshold: 8),
            sessionId: "s-below", appId: "com.example.game", durationMinutes: 30)
        XCTAssertEqual(result.decision.type, .denyUnlock)
        XCTAssertTrue(result.decision.reasoning.contains("below threshold"), result.decision.reasoning)
        XCTAssertTrue(result.decision.outcome.contains("floor met"), result.decision.outcome)
        assertComplete(result.decision)
    }

    func testDenyBelowFloorNamesMissingFloor() throws {
        let logger = DecisionLogger(directory: directory)
        // Long active time but no hint interaction: floor not met.
        let result = try logger.evaluateAndLog(
            signals: EffortSignals(activeSeconds: 3600, genuineAttempts: 3),
            scorer: EffortScorer(threshold: 8),
            sessionId: "s-floor", appId: "com.example.game", durationMinutes: 30)
        XCTAssertEqual(result.decision.type, .denyUnlock)
        XCTAssertTrue(result.decision.reasoning.contains("Floor not met"), result.decision.reasoning)
        XCTAssertTrue(result.decision.outcome.contains("floor not met"), result.decision.outcome)
        assertComplete(result.decision)
    }

    func testUnlockConfidenceStaysWithinZeroToOne() throws {
        let logger = DecisionLogger(directory: directory)
        let wide = try logger.evaluateAndLog(
            signals: EffortSignals(activeSeconds: 3600, genuineAttempts: 10, hintInteractions: 5),
            scorer: EffortScorer(threshold: 8),
            sessionId: "s-wide", appId: "a", durationMinutes: 30)
        let narrow = try logger.evaluateAndLog(
            signals: EffortSignals(activeSeconds: 60, genuineAttempts: 1, hintInteractions: 1),
            scorer: EffortScorer(threshold: 8),
            sessionId: "s-narrow", appId: "a", durationMinutes: 30)
        let floorMiss = try logger.evaluateAndLog(
            signals: EffortSignals(activeSeconds: 3600),
            scorer: EffortScorer(threshold: 8),
            sessionId: "s-floormiss", appId: "a", durationMinutes: 30)
        for decision in [wide.decision, narrow.decision, floorMiss.decision] {
            XCTAssertTrue(decision.confidence.isFinite)
            XCTAssertGreaterThanOrEqual(decision.confidence, 0)
            XCTAssertLessThanOrEqual(decision.confidence, 1)
        }
    }

    func testUnlockJustificationIsDeterministic() throws {
        let scorer = EffortScorer(threshold: 14)
        let signals = EffortSignals(activeSeconds: 360, genuineAttempts: 3, hintInteractions: 1,
                                    answerRevisions: 1, explanations: 1)
        let score = scorer.evaluate(signals)
        let first = try DecisionLogger.unlockJustification(for: score, appId: "a", durationMinutes: 30)
        let second = try DecisionLogger.unlockJustification(for: score, appId: "a", durationMinutes: 30)
        XCTAssertEqual(first.type, second.type)
        XCTAssertEqual(first.outcome, second.outcome)
        XCTAssertEqual(first.evidenceSummary, second.evidenceSummary)
        XCTAssertEqual(first.reasoning, second.reasoning)
        XCTAssertEqual(first.alternativeConsidered, second.alternativeConsidered)
        XCTAssertEqual(first.confidence, second.confidence)
    }

    // MARK: - Test-only seams (trade / session-judgment; no live callers yet)

    func testTradeOfferSeamProducesCompleteRecordForFutureT3xCallers() throws {
        let logger = DecisionLogger(directory: directory)
        let record = try logger.logTradeOffer(
            sessionId: "session-trade",
            outcome: "Offered 15 jumping jacks for a 15-minute trade unlock.",
            evidenceSummary: "Low motivation to continue practising, still wants the unlock.",
            reasoning: "Patience exhausted but unlock still wanted, so a movement trade fits.",
            alternativeConsidered: "No offer was rejected: child would stall without progress.",
            confidence: 0.7)
        XCTAssertEqual(record.type, .offerTrade)
        assertComplete(record)
        XCTAssertEqual(logger.decisions.count, 1)
    }

    func testSessionJudgmentSeamProducesCompleteRecord() throws {
        let logger = DecisionLogger(directory: directory)
        let record = try logger.logSessionJudgment(
            sessionId: "session-judgment",
            outcome: "Judged patience exhausted though effort was genuine.",
            evidenceSummary: "Genuine attempts with rising idle gaps and declining replies.",
            reasoning: "Effort genuine but continuation unlikely, so record the judgment.",
            alternativeConsidered: "Continuing practice was rejected: likely stall.",
            confidence: 0.65)
        XCTAssertEqual(record.type, .sessionJudgment)
        assertComplete(record)
    }

    // MARK: - Validation: empty fields and bad confidence fail the write

    func testBlankJustificationFieldThrowsAndAppendsNothing() throws {
        let logger = DecisionLogger(directory: directory)
        XCTAssertThrowsError(try logger.logDifficultyChange(
            sessionId: "s", outcome: "   ", evidenceSummary: "e", reasoning: "r",
            alternativeConsidered: "a", confidence: 0.5)) { error in
            XCTAssertEqual(error as? DecisionLogError, .incompleteJustification(field: "outcome"))
        }
        XCTAssertThrowsError(try logger.logDifficultyChange(
            sessionId: "s", outcome: "o", evidenceSummary: "", reasoning: "r",
            alternativeConsidered: "a", confidence: 0.5)) { error in
            XCTAssertEqual(error as? DecisionLogError, .incompleteJustification(field: "evidenceSummary"))
        }
        XCTAssertThrowsError(try logger.logDifficultyChange(
            sessionId: "", outcome: "o", evidenceSummary: "e", reasoning: "r",
            alternativeConsidered: "a", confidence: 0.5)) { error in
            XCTAssertEqual(error as? DecisionLogError, .incompleteJustification(field: "sessionId"))
        }
        XCTAssertTrue(logger.decisions.isEmpty)
    }

    func testConfidenceOutsideZeroToOneThrows() {
        let logger = DecisionLogger(directory: directory)
        for bad in [-0.1, 1.1, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertThrowsError(try logger.logDifficultyChange(
                sessionId: "s", outcome: "o", evidenceSummary: "e", reasoning: "r",
                alternativeConsidered: "a", confidence: bad),
                "confidence \(bad) must throw") { error in
                XCTAssertEqual(error as? DecisionLogError, .confidenceOutOfRange)
            }
        }
        XCTAssertTrue(logger.decisions.isEmpty)
        // Boundaries are valid.
        XCTAssertNoThrow(try logger.logDifficultyChange(
            sessionId: "s", outcome: "o", evidenceSummary: "e", reasoning: "r",
            alternativeConsidered: "a", confidence: 0, decisionId: "c0"))
        XCTAssertNoThrow(try logger.logDifficultyChange(
            sessionId: "s", outcome: "o", evidenceSummary: "e", reasoning: "r",
            alternativeConsidered: "a", confidence: 1, decisionId: "c1"))
    }

    func testDuplicateDecisionIdThrowsAndKeepsOriginal() throws {
        let logger = DecisionLogger(directory: directory)
        let first = try logger.logDifficultyChange(
            sessionId: "s", outcome: "o", evidenceSummary: "e", reasoning: "r",
            alternativeConsidered: "a", confidence: 0.5, decisionId: "dup")
        XCTAssertThrowsError(try logger.logDifficultyChange(
            sessionId: "s", outcome: "other", evidenceSummary: "e2", reasoning: "r2",
            alternativeConsidered: "a2", confidence: 0.6, decisionId: "dup")) { error in
            XCTAssertEqual(error as? DecisionLogError, .duplicateDecisionId)
        }
        XCTAssertEqual(logger.decisions, [first])
    }

    func testUnlockWithBlankAppOrNonPositiveDurationThrows() {
        let logger = DecisionLogger(directory: directory)
        let score = EffortScorer(threshold: 8).evaluate(EffortSignals(
            activeSeconds: 360, genuineAttempts: 3, hintInteractions: 1))
        XCTAssertThrowsError(try logger.logUnlock(evaluation: score, sessionId: "s",
                                                  appId: "  ", durationMinutes: 30)) { error in
            XCTAssertEqual(error as? DecisionLogError, .incompleteJustification(field: "appId"))
        }
        XCTAssertThrowsError(try logger.logUnlock(evaluation: score, sessionId: "s",
                                                  appId: "a", durationMinutes: 0)) { error in
            XCTAssertEqual(error as? DecisionLogError, .incompleteJustification(field: "durationMinutes"))
        }
        XCTAssertTrue(logger.decisions.isEmpty)
    }

    func testIncompleteRecordIsFlaggedByIsComplete() {
        let record = Decision(decisionId: "d", sessionId: "s", type: .denyUnlock,
                              outcome: "", evidenceSummary: "e", reasoning: "r",
                              alternativeConsidered: "a", confidence: 0.5, timestamp: Date())
        XCTAssertFalse(record.isComplete)
        XCTAssertEqual(record.incompleteFields, ["outcome"])
        let badConfidence = Decision(decisionId: "d", sessionId: "s", type: .denyUnlock,
                                     outcome: "o", evidenceSummary: "e", reasoning: "r",
                                     alternativeConsidered: "a", confidence: 2,
                                     timestamp: Date())
        XCTAssertFalse(badConfidence.isComplete)
        XCTAssertTrue(badConfidence.incompleteFields.contains("confidence"))
    }

    // MARK: - Append-only persisted log

    func testLogPersistsAcrossReloadAndNewInstances() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let logger = DecisionLogger(directory: directory)
        _ = try logger.evaluateAndLog(
            signals: EffortSignals(activeSeconds: 360, genuineAttempts: 3, hintInteractions: 1),
            scorer: EffortScorer(threshold: 8),
            sessionId: "s-persist", appId: "a", durationMinutes: 30,
            timestamp: base, decisionId: "persist-1")
        XCTAssertEqual(logger.reloadFromDisk().count, 1)

        // A new instance over the same directory sees the same record.
        let reopened = DecisionLogger(directory: directory)
        XCTAssertEqual(reopened.decisions.count, 1)
        XCTAssertEqual(reopened.decisions.first?.decisionId, "persist-1")
        assertComplete(reopened.decisions.first!)

        // Appends accumulate; nothing is overwritten.
        _ = try reopened.logDifficultyChange(
            sessionId: "s-persist", outcome: "o", evidenceSummary: "e", reasoning: "r",
            alternativeConsidered: "a", confidence: 0.5,
            timestamp: base.addingTimeInterval(1), decisionId: "persist-2")
        XCTAssertEqual(DecisionLogger(directory: directory).decisions.map(\.decisionId),
                       ["persist-1", "persist-2"])
    }

    func testCorruptPrimaryFallsBackToBackup() throws {
        let logger = DecisionLogger(directory: directory)
        _ = try logger.logDifficultyChange(
            sessionId: "s", outcome: "o", evidenceSummary: "e", reasoning: "r",
            alternativeConsidered: "a", confidence: 0.5, decisionId: "backup-kept")
        // Corrupt the primary; the backup written alongside it still loads.
        let primary = directory.appendingPathComponent(DecisionLogger.decisionsFileName)
        try "not-json{".data(using: .utf8)!.write(to: primary, options: [.atomic])
        XCTAssertEqual(DecisionLogger(directory: directory).decisions.map(\.decisionId),
                       ["backup-kept"])
    }

    func testPersistenceFailureAppendsNothing() {
        let failing = DecisionLogger(directory: directory, dataWriter: { _, _ in
            throw NSError(domain: "test", code: 1)
        })
        let score = EffortScorer(threshold: 8).evaluate(EffortSignals(
            activeSeconds: 360, genuineAttempts: 3, hintInteractions: 1))
        XCTAssertThrowsError(try failing.logUnlock(evaluation: score, sessionId: "s",
                                                   appId: "a", durationMinutes: 30)) { error in
            XCTAssertEqual(error as? DecisionLogError, .persistenceFailed)
        }
        XCTAssertTrue(failing.decisions.isEmpty)
        // Nothing reached disk either: a fresh reader sees an empty log.
        XCTAssertTrue(DecisionLogger(directory: directory).decisions.isEmpty)
    }

    func testDecisionsForSessionFiltersWithoutReordering() throws {
        let logger = DecisionLogger(directory: directory)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try logger.logDifficultyChange(
            sessionId: "s-a", outcome: "o1", evidenceSummary: "e", reasoning: "r",
            alternativeConsidered: "a", confidence: 0.5,
            timestamp: base, decisionId: "1")
        _ = try logger.logDifficultyChange(
            sessionId: "s-b", outcome: "o2", evidenceSummary: "e", reasoning: "r",
            alternativeConsidered: "a", confidence: 0.5,
            timestamp: base.addingTimeInterval(1), decisionId: "2")
        _ = try logger.logDifficultyChange(
            sessionId: "s-a", outcome: "o3", evidenceSummary: "e", reasoning: "r",
            alternativeConsidered: "a", confidence: 0.5,
            timestamp: base.addingTimeInterval(2), decisionId: "3")
        XCTAssertEqual(logger.decisions(for: "s-a").map(\.decisionId), ["1", "3"])
        XCTAssertEqual(logger.decisions(for: "s-b").map(\.decisionId), ["2"])
    }

    func testSyncPayloadRoundTripsLLDSchema() throws {
        let logger = DecisionLogger(directory: directory)
        let record = try logger.logDifficultyChange(
            sessionId: "s-sync", outcome: "o", evidenceSummary: "e", reasoning: "r",
            alternativeConsidered: "a", confidence: 0.5, decisionId: "sync-1")
        let payload = try logger.encodedForSync()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        XCTAssertEqual(try decoder.decode([Decision].self, from: payload), [record])
        // LLD-exact keys survive the sync encoding.
        let json = try JSONSerialization.jsonObject(with: payload) as! [[String: Any]]
        XCTAssertEqual(json.count, 1)
        for key in ["decisionId", "sessionId", "type", "outcome", "evidenceSummary",
                    "reasoning", "alternativeConsidered", "confidence", "timestamp"] {
            XCTAssertNotNil(json[0][key], "missing LLD key \(key)")
        }
        XCTAssertEqual(json[0]["type"] as? String, "difficulty-change")
    }

    // MARK: - Routine one-line reasons (not Decisions)

    func testRoutineReasonCollapsesToOneLineAndLogsNothing() {
        XCTAssertEqual(DecisionLogger.routineReason("  Presented  hint\nlevel 2\tto child  "),
                       "Presented hint level 2 to child")
        XCTAssertEqual(DecisionLogger.routineReason("single line"), "single line")
        let logger = DecisionLogger(directory: directory)
        XCTAssertEqual(logger.routineReason("line one\nline two"), "line one line two")
        XCTAssertTrue(logger.decisions.isEmpty)
    }

    // MARK: - Helpers

    /// Fails unless all five justification fields are non-empty and valid:
    /// outcome, evidenceSummary, reasoning, alternativeConsidered, confidence.
    private func assertComplete(_ record: Decision,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(record.outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "empty outcome in \(record.decisionId)", file: file, line: line)
        XCTAssertFalse(record.evidenceSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "empty evidenceSummary in \(record.decisionId)", file: file, line: line)
        XCTAssertFalse(record.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "empty reasoning in \(record.decisionId)", file: file, line: line)
        XCTAssertFalse(record.alternativeConsidered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "empty alternativeConsidered in \(record.decisionId)", file: file, line: line)
        XCTAssertTrue(record.confidence.isFinite
            && record.confidence >= 0 && record.confidence <= 1,
            "bad confidence \(record.confidence) in \(record.decisionId)",
            file: file, line: line)
        XCTAssertTrue(record.isComplete,
                      "incomplete fields \(record.incompleteFields) in \(record.decisionId)",
                      file: file, line: line)
    }
}
