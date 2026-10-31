import Foundation
import XCTest
@testable import EarnPlayCore

/// Issue #63 — child-side practice pipeline.
///
/// Scripted session with hand math, normalization edges, decode
/// regressions (decisions-only + auditor-only), queue round-trip, and
/// empty-session behavior. All expectations are hand-computed below, never
/// produced by the code under test.
final class PracticeSessionRecordingTests: XCTestCase {

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    private func tempDir() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue63-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: - Scripted session (hand math)

    /// Timeline (seconds, `startedAt` = 0, scorer threshold 10):
    /// - q1 mult: start 0, hint 5, correct 10, end 10.
    /// - q2 mult: start 10, incorrect("computation") 12, probe reply 15,
    ///   correct(revision) 25, end 25.
    /// - q3 division: start 25, hint 30, incorrect("computation") 35, end 60.
    ///
    /// Per-question activeMs (20s idle cap):
    /// - q1: gaps 5,5 = 10s = 10000ms.
    /// - q2: gaps 2,3,10 = 15s = 15000ms.
    /// - q3: gaps 5,5,25->20 = 30s = 30000ms.
    ///
    /// Hints: q1 1, q2 0, q3 1. Correct: true, true (final), false.
    /// Error: q1 nil, q2 nil (final correct drops the earlier type), q3
    /// "computation" (recorded source supplied).
    ///
    /// T1.4 signals at 60: active 55s (gaps 5,5,2,3,10,5,5,20; 0 active
    /// minutes), 4 genuine attempts, 2 hints, 1 follow-up, 1 revision, 1
    /// explanation. Score = 0 + 8 + 4 + 1 + 1 + 2 = 16 vs threshold 10,
    /// floor met (4 attempts, 3 hint/follow-up).
    func testScriptedSessionMatchesHandMath() {
        let recorder = PracticeSessionRecorder(sessionId: "s-hand", startedAt: date(0))
        let scorer = EffortScorer(threshold: 10)

        recorder.startQuestion(questionId: "q1", skill: "multiplicationFacts", at: date(0))
        recorder.recordHint(questionId: "q1", at: date(5))
        recorder.recordAnswer(questionId: "q1", correct: true, isRevision: false,
                              isGenuine: true, at: date(10))
        recorder.finishQuestion(questionId: "q1", at: date(10))

        recorder.startQuestion(questionId: "q2", skill: "multiplicationFacts", at: date(10))
        recorder.recordAnswer(questionId: "q2", correct: false, errorType: "computation",
                              isRevision: false, isGenuine: true, at: date(12))
        recorder.recordProbeReply(questionId: "q2", at: date(15))
        recorder.recordAnswer(questionId: "q2", correct: true, isRevision: true,
                              isGenuine: true, at: date(25))
        recorder.finishQuestion(questionId: "q2", at: date(25))

        recorder.startQuestion(questionId: "q3", skill: "division", at: date(25))
        recorder.recordHint(questionId: "q3", at: date(30))
        recorder.recordAnswer(questionId: "q3", correct: false, errorType: "computation",
                              isRevision: false, isGenuine: true, at: date(35))
        // q3 left unfinished: auto-ends at the session end.

        let finished = recorder.finishSession(at: date(60), scorer: scorer)
        XCTAssertEqual(finished.endedAt, date(60))
        XCTAssertEqual(finished.questionRecords, [
            SessionQuestionRecord(questionId: "q1", skill: "multiplicationFacts",
                                  correct: true, activeMs: 10000, hintsUsed: 1),
            SessionQuestionRecord(questionId: "q2", skill: "multiplicationFacts",
                                  correct: true, activeMs: 15000, hintsUsed: 0),
            SessionQuestionRecord(questionId: "q3", skill: "division",
                                  correct: false, activeMs: 30000, hintsUsed: 1,
                                  errorType: "computation"),
        ])
        XCTAssertEqual(finished.effort, SessionEffortRecord(score: 16, threshold: 10))

        // The snapshot equals the T1.4 evaluation of the recorded session.
        let evaluated = scorer.evaluate(recorder.effortRecorder.signals(at: date(60)))
        XCTAssertEqual(evaluated.score, 16)
        XCTAssertEqual(evaluated.threshold, 10)
        XCTAssertTrue(evaluated.floorMet)
        XCTAssertEqual(finished.effort?.score, evaluated.score)
        XCTAssertEqual(finished.effort?.threshold, evaluated.threshold)
    }

    /// The same scripted session built into a `SessionLog` via
    /// `SessionLog.make` with a real `DecisionLogger` (no unlock context,
    /// so no decisions) and enqueued: the queue carries the exact hand
    /// values.
    func testScriptedSessionLogConstructionAndEnqueue() throws {
        let loggerDir = tempDir()
        let queueDir = tempDir()
        let logger = DecisionLogger(directory: loggerDir)
        let queue = SessionLogQueue(directory: queueDir)
        let recorder = PracticeSessionRecorder(sessionId: "s-log", startedAt: date(0))
        let scorer = EffortScorer(threshold: 10)

        recorder.startQuestion(questionId: "q1", skill: "multiplicationFacts", at: date(0))
        recorder.recordHint(questionId: "q1", at: date(5))
        recorder.recordAnswer(questionId: "q1", correct: true, at: date(10))
        recorder.finishQuestion(questionId: "q1", at: date(10))
        recorder.startQuestion(questionId: "q2", skill: "division", at: date(10))
        recorder.recordAnswer(questionId: "q2", correct: false, errorType: "computation",
                              at: date(35))

        let log = recorder.makeSessionLog(endedAt: date(60), logger: logger,
                                          policyVersion: 7, scorer: scorer)
        XCTAssertEqual(log.sessionId, "s-log")
        XCTAssertEqual(log.startedAt, date(0))
        XCTAssertEqual(log.endedAt, date(60))
        XCTAssertEqual(log.policyVersion, 7)
        XCTAssertTrue(log.decisions.isEmpty)
        XCTAssertEqual(log.questionRecords.count, 2)
        XCTAssertEqual(log.questionRecords[0].activeMs, 10000)
        // q2: start 10, answer 35, end 60 — gaps 25->20, 25->20 = 40s.
        XCTAssertEqual(log.questionRecords[1].activeMs, 40000)
        XCTAssertEqual(log.effort?.score, 6)
        XCTAssertEqual(log.effort?.threshold, 10)

        try queue.enqueue(log)
        XCTAssertEqual(queue.pending(), [log])
    }

    /// Unlock path routes through the session-decision boundary: the grant
    /// decision is persisted before returning, and the log carries it plus
    /// the hand detail.
    func testUnlockPathLogsDecisionAndCarriesDetail() throws {
        let logger = DecisionLogger(directory: tempDir())
        let recorder = PracticeSessionRecorder(sessionId: "s-unlock", startedAt: date(0))
        let scorer = EffortScorer(threshold: 8)

        recorder.startQuestion(questionId: "q1", skill: "division", at: date(0))
        recorder.recordHint(questionId: "q1", at: date(5))
        recorder.recordAnswer(questionId: "q1", correct: true, at: date(10))

        let done = try recorder.logUnlockAndMakeSessionLog(
            endedAt: date(60), scorer: scorer, logger: logger, policyVersion: 3,
            appId: "com.test.app", durationMinutes: 15)
        // Signals: 1 attempt, 1 hint, 0 elsewhere, 30s active (gaps
        // 5,5,50->20) = 0 minutes. Score = 0 + 2 + 2 = 4 vs 8, floor met
        // (1 attempt, 1 hint) but below threshold: deny.
        XCTAssertEqual(done.score?.score, 4)
        XCTAssertEqual(done.score?.threshold, 8)
        XCTAssertEqual(done.decision?.type, .denyUnlock)
        XCTAssertEqual(done.log.effort, SessionEffortRecord(score: 4, threshold: 8))
        XCTAssertEqual(done.log.questionRecords.count, 1)
        XCTAssertEqual(done.log.decisions.count, 1)
        XCTAssertEqual(logger.decisions(for: "s-unlock").count, 1)
    }

    // MARK: - Empty sessions (never invented)

    func testSessionsWithoutPracticeProduceEmptyDetailAndNilEffort() {
        // No questions at all.
        let empty = PracticeSessionRecorder(sessionId: "s-empty", startedAt: date(0))
        let finishedEmpty = empty.finishSession(at: date(60), scorer: EffortScorer(threshold: 10))
        XCTAssertTrue(finishedEmpty.questionRecords.isEmpty)
        XCTAssertNil(finishedEmpty.effort)

        // Presented but never answered: no record, no effort.
        let presented = PracticeSessionRecorder(sessionId: "s-presented", startedAt: date(0))
        presented.startQuestion(questionId: "q1", skill: "division", at: date(0))
        let finishedPresented = presented.finishSession(at: date(60), scorer: EffortScorer(threshold: 10))
        XCTAssertTrue(finishedPresented.questionRecords.isEmpty)
        XCTAssertNil(finishedPresented.effort)

        // Hint without a graded answer: no verdict exists, so no record
        // and nil effort (never invented).
        let hinted = PracticeSessionRecorder(sessionId: "s-hinted", startedAt: date(0))
        hinted.startQuestion(questionId: "q1", skill: "division", at: date(0))
        hinted.recordHint(questionId: "q1", at: date(5))
        let finishedHinted = hinted.finishSession(at: date(60), scorer: EffortScorer(threshold: 10))
        XCTAssertTrue(finishedHinted.questionRecords.isEmpty)
        XCTAssertNil(finishedHinted.effort)

        // No scorer: even practised questions carry nil effort.
        let unscored = PracticeSessionRecorder(sessionId: "s-unscored", startedAt: date(0))
        unscored.startQuestion(questionId: "q1", skill: "division", at: date(0))
        unscored.recordAnswer(questionId: "q1", correct: true, at: date(10))
        let finishedUnscored = unscored.finishSession(at: date(60), scorer: nil)
        XCTAssertEqual(finishedUnscored.questionRecords.count, 1)
        XCTAssertNil(finishedUnscored.effort)
    }

    func testUnlockPathWithNoPracticeLogsNothing() throws {
        let logger = DecisionLogger(directory: tempDir())
        let recorder = PracticeSessionRecorder(sessionId: "s-no-practice", startedAt: date(0))
        let done = try recorder.logUnlockAndMakeSessionLog(
            endedAt: date(60), scorer: EffortScorer(threshold: 8), logger: logger,
            policyVersion: 1, appId: "com.test.app", durationMinutes: 10)
        XCTAssertTrue(done.log.questionRecords.isEmpty)
        XCTAssertNil(done.log.effort)
        XCTAssertNil(done.score)
        XCTAssertNil(done.decision)
        XCTAssertTrue(logger.decisions(for: "s-no-practice").isEmpty)
    }

    // MARK: - Normalization edges

    func testRecordNormalizationEdges() {
        // Direct initializer: clamps, trims, blank-to-nil, drop-when-correct.
        let clamped = SessionQuestionRecord(questionId: "q", skill: "division",
                                            correct: false, activeMs: -5000,
                                            hintsUsed: -2, errorType: "computation")
        XCTAssertEqual(clamped.activeMs, 0)
        XCTAssertEqual(clamped.hintsUsed, 0)

        let trimmed = SessionQuestionRecord(questionId: "q", skill: "  division  ",
                                            correct: false, activeMs: 1000,
                                            hintsUsed: 0, errorType: " computation ")
        XCTAssertEqual(trimmed.skill, "division")
        XCTAssertEqual(trimmed.errorType, "computation")

        let blank = SessionQuestionRecord(questionId: "q", skill: "division",
                                          correct: false, activeMs: 1000,
                                          hintsUsed: 0, errorType: "   ")
        XCTAssertNil(blank.errorType)

        let dropped = SessionQuestionRecord(questionId: "q", skill: "division",
                                            correct: true, activeMs: 1000,
                                            hintsUsed: 0, errorType: "computation")
        XCTAssertNil(dropped.errorType)
    }

    func testRecorderPassesNormalizationThrough() {
        // Padded skill trims, blank error becomes nil, correct drops error.
        let recorder = PracticeSessionRecorder(sessionId: "s-norm", startedAt: date(0))
        recorder.startQuestion(questionId: "q1", skill: "  division  ", at: date(0))
        recorder.recordAnswer(questionId: "q1", correct: false, errorType: "   ",
                              at: date(10))
        recorder.startQuestion(questionId: "q2", skill: "division", at: date(10))
        recorder.recordAnswer(questionId: "q2", correct: true, errorType: "computation",
                              at: date(20))
        let finished = recorder.finishSession(at: date(60), scorer: EffortScorer(threshold: 10))
        XCTAssertEqual(finished.questionRecords[0].skill, "division")
        XCTAssertNil(finished.questionRecords[0].errorType)
        XCTAssertNil(finished.questionRecords[1].errorType)
    }

    // MARK: - Decode regressions

    func testDecodeDecisionsOnlyLogUnchanged() throws {
        let json = """
        {"decisions":[{"alternativeConsidered":"alt","confidence":0.9,\
        "decisionId":"d1","evidenceSummary":"ev","outcome":"done",\
        "reasoning":"why","sessionId":"s-1",\
        "timestamp":721692800.0,"type":"session-judgment"}],\
        "endedAt":721693400.0,"policyVersion":3,"sessionId":"s-1",\
        "startedAt":721692800.0}
        """
        let decoded = try SessionLogCodec.decode(Data(json.utf8))
        XCTAssertEqual(decoded.sessionId, "s-1")
        XCTAssertEqual(decoded.decisions.count, 1)
        XCTAssertNil(decoded.questions)
        XCTAssertNil(decoded.rawSignals)
        XCTAssertNil(decoded.rawEffortTotal)
        XCTAssertNil(decoded.rawEffortBar)
        XCTAssertNil(decoded.rawFloorMet)
        XCTAssertTrue(decoded.questionRecords.isEmpty)
        XCTAssertNil(decoded.effort)
    }

    func testDecodeAuditorOnlyLogUnchanged() throws {
        let json = """
        {"decisions":[{"alternativeConsidered":"alt","confidence":0.9,\
        "decisionId":"d1","evidenceSummary":"ev","outcome":"done",\
        "reasoning":"why","sessionId":"s-a",\
        "timestamp":721692800.0,"type":"session-judgment"}],\
        "endedAt":721693400.0,"policyVersion":3,\
        "questions":[{"answerMatched":true,"difficulty":2,\
        "form":"story","questionId":"aq0"}],\
        "rawEffortBar":10,"rawEffortTotal":9,"rawFloorMet":true,\
        "rawSignals":{"activeSeconds":120,"answerRevisions":1,\
        "explanations":0,"followUpInteractions":1,"genuineAttempts":2,\
        "hintInteractions":1},\
        "sessionId":"s-a","startedAt":721692800.0}
        """
        let decoded = try SessionLogCodec.decode(Data(json.utf8))
        XCTAssertEqual(decoded.sessionId, "s-a")
        XCTAssertEqual(decoded.questions, [
            AuditorQuestionRecord(questionId: "aq0", form: "story",
                                  difficulty: 2, answerMatched: true),
        ])
        XCTAssertEqual(decoded.rawSignals, EffortSignals(
            activeSeconds: 120, genuineAttempts: 2, hintInteractions: 1,
            followUpInteractions: 1, answerRevisions: 1, explanations: 0))
        XCTAssertEqual(decoded.rawEffortTotal, 9)
        XCTAssertEqual(decoded.rawEffortBar, 10)
        XCTAssertEqual(decoded.rawFloorMet, true)
        XCTAssertTrue(decoded.questionRecords.isEmpty)
        XCTAssertNil(decoded.effort)
    }

    // MARK: - Queue round-trip

    func testQueueRoundTrip() throws {
        let queue = SessionLogQueue(directory: tempDir())
        XCTAssertTrue(queue.isEmpty)
        let log = SessionLog(
            sessionId: "s-q", startedAt: date(0), endedAt: date(60),
            decisions: [], policyVersion: 1,
            questionRecords: [SessionQuestionRecord(
                questionId: "q1", skill: "division", correct: true,
                activeMs: 10000, hintsUsed: 1)],
            effort: SessionEffortRecord(score: 9, threshold: 10))
        try queue.enqueue(log)
        XCTAssertEqual(queue.pending(), [log])
        XCTAssertFalse(queue.isEmpty)
        try queue.removeDelivered(sessionIds: ["s-q"])
        XCTAssertTrue(queue.pending().isEmpty)
        XCTAssertTrue(queue.isEmpty)
    }

    // MARK: - Hint-listen attribution (round 4 item 3)

    /// A hint listen resolves through the hint-show map to its originating
    /// question: the replayed earlier hint anchors Q1 (out-of-window there,
    /// so no time), Q2 keeps its single capped gap, and the session-level
    /// listen event is still recorded. A message id with no map entry falls
    /// back to the current question (the pre-round-4 behavior, pinned).
    func testHintListenAttributesToOriginatingQuestionWithCurrentFallback() {
        let recorder = PracticeSessionRecorder(sessionId: "s-hintmap", startedAt: date(0))
        let scorer = EffortScorer(threshold: 10)
        recorder.startQuestion(questionId: "q1", skill: "multiplicationFacts", at: date(0))
        recorder.recordHint(questionId: "q1", at: date(5), hintMessageID: "q1-hint-1")
        recorder.recordAnswer(questionId: "q1", correct: true, at: date(10))
        recorder.finishQuestion(questionId: "q1", at: date(10))
        recorder.startQuestion(questionId: "q2", skill: "multiplicationFacts", at: date(10))
        // Q1's hint replayed at 40 while Q2 is current.
        recorder.recordHintListen(HintListenEvent(
            messageID: "q1-hint-1", messageText: "hint", emittedAt: date(40)))
        recorder.recordAnswer(questionId: "q2", correct: true, at: date(70))
        // An unmapped listen at 75 anchors the current question (fallback).
        recorder.recordHintListen(HintListenEvent(
            messageID: "unknown-hint", messageText: "hint", emittedAt: date(75)))
        let finished = recorder.finishSession(at: date(80), scorer: scorer)

        // Q1: gaps 5,5 = 10s; the replayed listen is out-of-window there.
        XCTAssertEqual(finished.questionRecords.first?.activeMs, 10000)
        XCTAssertEqual(finished.questionRecords.first?.hintsUsed, 1)
        // Q2: start 10, answer 70, fallback listen 75, end 80. The Q1 replay
        // adds nothing; the unmapped listen splits the tail: gaps 60->20,
        // 5, 5 = 30s.
        XCTAssertEqual(finished.questionRecords.last?.activeMs, 30000)
        // Session level: both listens recorded as hint interactions
        // (1 show + 2 listens = 3 hints -> 6 points, 2 attempts -> 4 points,
        // 60s active (5+5+20+20+5+5) = 1 minute -> 1 point): 6+4+1 = 11.
        XCTAssertEqual(finished.effort, SessionEffortRecord(score: 11, threshold: 10))
    }
}
