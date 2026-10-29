import XCTest
@testable import EarnPlayCore

/// T1.5 stalling probes. The three fixture tests below are the task's
/// automated acceptance test (3/3 must pass); the rest pin the
/// at-most-once-per-episode rule and each firing rule from the LLD.
final class StallingDetectionTests: XCTestCase {

    private func session(start: Date = Date(timeIntervalSince1970: 10_000)) -> StallProbeSession {
        StallProbeSession(startedAt: start)
    }

    // MARK: Automated acceptance (3/3)

    /// Fixture 1: 3 identical wrong answers, no revision — exactly one
    /// probe fires.
    func testIdenticalWrongAnswersWithNoRevisionFireExactlyOneProbe() {
        let start = Date(timeIntervalSince1970: 10_000)
        let session = session(start: start)
        XCTAssertNil(session.recordAttempt(
            answer: "12", isCorrect: false, at: start.addingTimeInterval(5)))
        XCTAssertNil(session.recordAttempt(
            answer: " 12 ", isCorrect: false, at: start.addingTimeInterval(15)))
        let probe = session.recordAttempt(
            answer: "12", isCorrect: false, at: start.addingTimeInterval(25))
        XCTAssertNotNil(probe)
        XCTAssertEqual(session.probesFired.count, 1)
        XCTAssertEqual(probe?.signals, [.repeatedIdenticalAnswers])
        XCTAssertEqual(probe?.prompt, .showOneStep)
        XCTAssertTrue(probe?.message.text.lowercased().contains("show me one step") ?? false)
        XCTAssertEqual(probe?.message.kind, .probe)
        XCTAssertEqual(session.classification, .stalling)
    }

    /// Fixture 2: a varied-attempt stream — no probe fires.
    func testVariedAttemptStreamFiresNoProbe() {
        let start = Date(timeIntervalSince1970: 20_000)
        let session = session(start: start)
        XCTAssertNil(session.recordAttempt(
            answer: "12", isCorrect: false, at: start.addingTimeInterval(5)))
        session.recordRevision(at: start.addingTimeInterval(12))
        XCTAssertNil(session.recordAttempt(
            answer: "14", isCorrect: false, at: start.addingTimeInterval(30)))
        XCTAssertNil(session.recordAttempt(
            answer: "13", isCorrect: false, at: start.addingTimeInterval(60)))
        XCTAssertTrue(session.probesFired.isEmpty)
        XCTAssertNil(session.pendingProbe)
        XCTAssertEqual(session.classification, .trying)
    }

    /// Fixture 3: a substantive probe reply is recorded as T1.4 effort.
    func testSubstantiveProbeReplyIsRecordedAsEffort() {
        let start = Date(timeIntervalSince1970: 30_000)
        let session = session(start: start)
        session.recordAttempt(answer: "12", isCorrect: false,
                              at: start.addingTimeInterval(5))
        session.recordAttempt(answer: "12", isCorrect: false,
                              at: start.addingTimeInterval(15))
        session.recordAttempt(answer: "12", isCorrect: false,
                              at: start.addingTimeInterval(25))
        XCTAssertNotNil(session.pendingProbe)

        let before = session.signals(at: start.addingTimeInterval(26))
        XCTAssertEqual(before.followUpInteractions, 0)
        XCTAssertEqual(before.explanations, 0)

        let outcome = session.submitProbeReply(
            "I tried adding the tops first", at: start.addingTimeInterval(40))
        XCTAssertEqual(outcome, .substantive(probeSequenceNumber: 1))

        let after = session.signals(at: start.addingTimeInterval(41))
        XCTAssertEqual(after.followUpInteractions, 1)
        XCTAssertEqual(after.explanations, 1)
        XCTAssertNil(session.pendingProbe)
        XCTAssertEqual(session.classification, .trying)
    }

    // MARK: At most once per episode

    func testRepeatedIdenticalAnswersAfterProbeDoNotSpamFurtherProbes() {
        let start = Date(timeIntervalSince1970: 40_000)
        let session = session(start: start)
        for offset in [5, 15, 25] {
            session.recordAttempt(answer: "12", isCorrect: false,
                                  at: start.addingTimeInterval(TimeInterval(offset)))
        }
        XCTAssertEqual(session.probesFired.count, 1)
        // Same episode, still stalling: three more identical answers fire
        // nothing further.
        for offset in [35, 45, 55] {
            XCTAssertNil(session.recordAttempt(
                answer: "12", isCorrect: false,
                at: start.addingTimeInterval(TimeInterval(offset))))
        }
        XCTAssertEqual(session.probesFired.count, 1)
        XCTAssertNotNil(session.pendingProbe)
    }

    func testNewEpisodeAfterSubstantiveReplyMayProbeAgainWithOtherPrompt() {
        let start = Date(timeIntervalSince1970: 50_000)
        let session = session(start: start)
        for offset in [5, 15, 25] {
            session.recordAttempt(answer: "12", isCorrect: false,
                                  at: start.addingTimeInterval(TimeInterval(offset)))
        }
        XCTAssertEqual(session.probesFired.count, 1)
        session.submitProbeReply("I added 7 and 5 to get 12",
                                 at: start.addingTimeInterval(40))
        XCTAssertNil(session.pendingProbe)
        // A second stalling episode later in the session probes again,
        // alternating to the other prompt.
        for offset in [100, 110, 120] {
            session.recordAttempt(answer: "9", isCorrect: false,
                                  at: start.addingTimeInterval(TimeInterval(offset)))
        }
        XCTAssertEqual(session.probesFired.count, 2)
        XCTAssertEqual(session.probesFired[1].prompt, .whatHaveYouTried)
        XCTAssertTrue(session.probesFired[1].message.text.lowercased()
            .contains("what have you tried") ?? false)
    }

    func testRevisionClosesEpisodeAndBreaksIdenticalRun() {
        let start = Date(timeIntervalSince1970: 60_000)
        let session = session(start: start)
        session.recordAttempt(answer: "12", isCorrect: false,
                              at: start.addingTimeInterval(5))
        session.recordAttempt(answer: "12", isCorrect: false,
                              at: start.addingTimeInterval(15))
        session.recordRevision(at: start.addingTimeInterval(20))
        // The run broke: this third "12" is only the first of a new run.
        XCTAssertNil(session.recordAttempt(
            answer: "12", isCorrect: false, at: start.addingTimeInterval(30)))
        XCTAssertTrue(session.probesFired.isEmpty)
        XCTAssertEqual(session.classification, .trying)
    }

    func testVariedAnswerClosesOpenEpisodeWithoutNewProbe() {
        let start = Date(timeIntervalSince1970: 70_000)
        let session = session(start: start)
        for offset in [5, 15, 25] {
            session.recordAttempt(answer: "12", isCorrect: false,
                                  at: start.addingTimeInterval(TimeInterval(offset)))
        }
        XCTAssertNotNil(session.pendingProbe)
        // Trying again with a new answer closes the episode (no spam) and
        // fires nothing on its own.
        XCTAssertNil(session.recordAttempt(
            answer: "14", isCorrect: false, at: start.addingTimeInterval(45)))
        XCTAssertNil(session.pendingProbe)
        XCTAssertEqual(session.probesFired.count, 1)
        XCTAssertEqual(session.classification, .trying)
    }

    func testCorrectAnswerClosesEpisodeWithoutFiring() {
        let start = Date(timeIntervalSince1970: 80_000)
        let session = session(start: start)
        for offset in [5, 15, 25] {
            session.recordAttempt(answer: "12", isCorrect: false,
                                  at: start.addingTimeInterval(TimeInterval(offset)))
        }
        XCTAssertNotNil(session.pendingProbe)
        XCTAssertNil(session.recordAttempt(
            answer: "56", isCorrect: true, at: start.addingTimeInterval(60)))
        XCTAssertNil(session.pendingProbe)
        XCTAssertEqual(session.probesFired.count, 1)
        XCTAssertEqual(session.classification, .trying)
    }

    // MARK: Response-time pattern (rapid guessing)

    func testThreeRapidAnswersFireRapidGuessingProbe() {
        let start = Date(timeIntervalSince1970: 90_000)
        let session = session(start: start)
        XCTAssertNil(session.recordAttempt(
            answer: "10", isCorrect: false, at: start.addingTimeInterval(5)))
        XCTAssertNil(session.recordAttempt(
            answer: "11", isCorrect: false, at: start.addingTimeInterval(5.8)))
        let probe = session.recordAttempt(
            answer: "13", isCorrect: false, at: start.addingTimeInterval(6.5))
        XCTAssertNotNil(probe)
        XCTAssertEqual(session.probesFired.count, 1)
        XCTAssertTrue(probe?.signals.contains(.rapidGuessing) ?? false)
    }

    func testThinkingRangeGapsBreakRapidRun() {
        let start = Date(timeIntervalSince1970: 100_000)
        let session = session(start: start)
        session.recordAttempt(answer: "10", isCorrect: false,
                              at: start.addingTimeInterval(5))
        session.recordAttempt(answer: "11", isCorrect: false,
                              at: start.addingTimeInterval(5.8))
        // A thinking-range gap breaks the rapid run: no probe.
        XCTAssertNil(session.recordAttempt(
            answer: "13", isCorrect: false, at: start.addingTimeInterval(30)))
        XCTAssertTrue(session.probesFired.isEmpty)
    }

    // MARK: Hint used as an answer key

    func testHintThenInstantCorrectAnswerFiresAnswerKeyProbe() {
        let start = Date(timeIntervalSince1970: 110_000)
        let session = session(start: start)
        session.recordAttempt(answer: "12", isCorrect: false,
                              at: start.addingTimeInterval(5))
        session.recordHintInteraction(at: start.addingTimeInterval(20))
        let probe = session.recordAttempt(
            answer: "56", isCorrect: true, at: start.addingTimeInterval(23))
        XCTAssertNotNil(probe)
        XCTAssertEqual(probe?.signals, [.hintUsedAsAnswerKey])
        XCTAssertEqual(session.probesFired.count, 1)
    }

    func testHintThenChangedAnswerAfterTimeFiresNoProbe() {
        let start = Date(timeIntervalSince1970: 120_000)
        let session = session(start: start)
        session.recordAttempt(answer: "12", isCorrect: false,
                              at: start.addingTimeInterval(5))
        session.recordHintInteraction(at: start.addingTimeInterval(20))
        // Changed answer after real work time: the hint was help, not a key.
        XCTAssertNil(session.recordAttempt(
            answer: "56", isCorrect: true, at: start.addingTimeInterval(90)))
        XCTAssertTrue(session.probesFired.isEmpty)
        XCTAssertEqual(session.classification, .trying)
    }

    func testHintThenRevisionThenCorrectAnswerFiresNoProbe() {
        let start = Date(timeIntervalSince1970: 130_000)
        let session = session(start: start)
        session.recordHintInteraction(at: start.addingTimeInterval(20))
        session.recordRevision(at: start.addingTimeInterval(22))
        XCTAssertNil(session.recordAttempt(
            answer: "56", isCorrect: true, at: start.addingTimeInterval(23)))
        XCTAssertTrue(session.probesFired.isEmpty)
    }

    // MARK: Reply handling

    func testNonSubstantiveReplyRecordsNoEffortAndKeepsProbePending() {
        let start = Date(timeIntervalSince1970: 140_000)
        let session = session(start: start)
        for offset in [5, 15, 25] {
            session.recordAttempt(answer: "12", isCorrect: false,
                                  at: start.addingTimeInterval(TimeInterval(offset)))
        }
        XCTAssertNotNil(session.pendingProbe)
        XCTAssertEqual(session.submitProbeReply(
            "  ", at: start.addingTimeInterval(40)), .notSubstantive)
        XCTAssertEqual(session.submitProbeReply(
            "ok", at: start.addingTimeInterval(41)), .notSubstantive)
        let signals = session.signals(at: start.addingTimeInterval(42))
        XCTAssertEqual(signals.followUpInteractions, 0)
        XCTAssertEqual(signals.explanations, 0)
        XCTAssertNotNil(session.pendingProbe)
        XCTAssertEqual(session.classification, .stalling)
        // The child can still answer properly afterwards.
        XCTAssertEqual(session.submitProbeReply(
            "I counted on from 7", at: start.addingTimeInterval(50)),
            .substantive(probeSequenceNumber: 1))
        XCTAssertNil(session.pendingProbe)
    }

    func testReplyWithNoProbePendingRecordsNothing() {
        let start = Date(timeIntervalSince1970: 150_000)
        let session = session(start: start)
        session.recordAttempt(answer: "12", isCorrect: false,
                              at: start.addingTimeInterval(5))
        XCTAssertEqual(session.submitProbeReply(
            "I tried adding the tops", at: start.addingTimeInterval(10)),
            .noProbePending)
        let signals = session.signals(at: start.addingTimeInterval(11))
        XCTAssertEqual(signals.followUpInteractions, 0)
        XCTAssertEqual(signals.explanations, 0)
    }

    // MARK: Classification and T1.4 wiring

    func testFreshSessionIsUncertain() {
        XCTAssertEqual(session().classification, .uncertain)
    }

    func testAttemptsFlowToT14RecorderUnchanged() {
        let start = Date(timeIntervalSince1970: 160_000)
        let session = session(start: start)
        session.recordAttempt(answer: "12", isCorrect: false,
                              at: start.addingTimeInterval(5))
        session.recordHintInteraction(at: start.addingTimeInterval(10))
        session.recordRevision(at: start.addingTimeInterval(15))
        let signals = session.signals(at: start.addingTimeInterval(16))
        XCTAssertEqual(signals.genuineAttempts, 1)
        XCTAssertEqual(signals.hintInteractions, 1)
        XCTAssertEqual(signals.answerRevisions, 1)
        // The T1.4 scorer consumes the same signals object.
        let result = session.evaluate(EffortScorer(threshold: 8))
        XCTAssertTrue(result.floorMet)
    }

    func testProbeReplyHelpsFloorViaFollowUpInteraction() {
        let start = Date(timeIntervalSince1970: 170_000)
        let session = session(start: start)
        for offset in [5, 15, 25] {
            session.recordAttempt(answer: "12", isCorrect: false,
                                  at: start.addingTimeInterval(TimeInterval(offset)))
        }
        XCTAssertFalse(session.evaluate(EffortScorer(threshold: 8)).floorMet)
        session.submitProbeReply("I tried multiplying 7 by 8",
                                 at: start.addingTimeInterval(40))
        // Attempts (genuine) + probe-reply follow-up: floor met.
        XCTAssertTrue(session.evaluate(EffortScorer(threshold: 8)).floorMet)
    }

    func testCaseAndWhitespaceVariantsCountAsIdentical() {
        let start = Date(timeIntervalSince1970: 180_000)
        let session = session(start: start)
        session.recordAttempt(answer: "Twelve", isCorrect: false,
                              at: start.addingTimeInterval(5))
        session.recordAttempt(answer: "twelve ", isCorrect: false,
                              at: start.addingTimeInterval(15))
        let probe = session.recordAttempt(
            answer: " TWELVE", isCorrect: false, at: start.addingTimeInterval(25))
        XCTAssertNotNil(probe)
        XCTAssertEqual(probe?.signals, [.repeatedIdenticalAnswers])
    }

    // MARK: Fix round 1 regressions (issue #8 review)

    /// A varied answer that continues the rapid-guessing pattern keeps the
    /// episode open: fourth and fifth rapid varied answers fire nothing and
    /// leave the pending probe untouched (at most once per episode).
    func testContinuedRapidVariedAnswersDoNotReplacePendingProbe() {
        let start = Date(timeIntervalSince1970: 190_000)
        let session = session(start: start)
        XCTAssertNil(session.recordAttempt(
            answer: "10", isCorrect: false, at: start.addingTimeInterval(5)))
        XCTAssertNil(session.recordAttempt(
            answer: "11", isCorrect: false, at: start.addingTimeInterval(5.8)))
        let probe = session.recordAttempt(
            answer: "13", isCorrect: false, at: start.addingTimeInterval(6.5))
        XCTAssertNotNil(probe)
        XCTAssertEqual(session.probesFired.count, 1)
        XCTAssertNil(session.recordAttempt(
            answer: "14", isCorrect: false, at: start.addingTimeInterval(7.2)))
        XCTAssertNil(session.recordAttempt(
            answer: "15", isCorrect: false, at: start.addingTimeInterval(7.9)))
        XCTAssertEqual(session.probesFired.count, 1)
        XCTAssertEqual(session.pendingProbe, probe)
        XCTAssertEqual(session.pendingProbe?.sequenceNumber, 1)
        XCTAssertEqual(session.classification, .stalling)
    }

    /// A varied answer after a thinking-range gap still closes the episode
    /// (genuine trying), even mid-rapid-run: only continued rapid guessing
    /// keeps it open.
    func testVariedAnswerAfterThinkingGapStillClosesRapidEpisode() {
        let start = Date(timeIntervalSince1970: 191_000)
        let session = session(start: start)
        session.recordAttempt(answer: "10", isCorrect: false,
                              at: start.addingTimeInterval(5))
        session.recordAttempt(answer: "11", isCorrect: false,
                              at: start.addingTimeInterval(5.8))
        XCTAssertNotNil(session.recordAttempt(
            answer: "13", isCorrect: false, at: start.addingTimeInterval(6.5)))
        XCTAssertNotNil(session.pendingProbe)
        XCTAssertNil(session.recordAttempt(
            answer: "14", isCorrect: false, at: start.addingTimeInterval(60)))
        XCTAssertNil(session.pendingProbe)
        XCTAssertEqual(session.probesFired.count, 1)
        XCTAssertEqual(session.classification, .trying)
    }

    /// Punctuation-only replies ("...", "???") are not substantive: no
    /// follow-up/explanation effort, probe stays pending.
    func testPunctuationOnlyRepliesAreNotSubstantive() {
        let start = Date(timeIntervalSince1970: 192_000)
        let session = session(start: start)
        for offset in [5, 15, 25] {
            session.recordAttempt(answer: "12", isCorrect: false,
                                  at: start.addingTimeInterval(TimeInterval(offset)))
        }
        XCTAssertNotNil(session.pendingProbe)
        XCTAssertFalse(session.detector.isSubstantiveReply("..."))
        XCTAssertFalse(session.detector.isSubstantiveReply("???"))
        XCTAssertFalse(session.detector.isSubstantiveReply("!!!"))
        XCTAssertTrue(session.detector.isSubstantiveReply("yes"))
        XCTAssertTrue(session.detector.isSubstantiveReply("I counted 7"))
        for reply in ["...", "???", "!!!", ". . .", "?!?"] {
            XCTAssertEqual(session.submitProbeReply(
                reply, at: start.addingTimeInterval(40)), .notSubstantive)
        }
        let signals = session.signals(at: start.addingTimeInterval(41))
        XCTAssertEqual(signals.followUpInteractions, 0)
        XCTAssertEqual(signals.explanations, 0)
        XCTAssertNotNil(session.pendingProbe)
        XCTAssertEqual(session.classification, .stalling)
        XCTAssertEqual(session.submitProbeReply(
            "I counted on from 7", at: start.addingTimeInterval(50)),
            .substantive(probeSequenceNumber: 1))
        XCTAssertNil(session.pendingProbe)
    }

    /// A substantive reply clears the pending hint check: hint, then an
    /// explanation in the probe reply, then a correct answer within the
    /// window fires no answer-key probe — the reply was the work shown.
    func testSubstantiveReplyClearsPendingHintCheck() {
        let start = Date(timeIntervalSince1970: 193_000)
        let session = session(start: start)
        for offset in [5, 15, 25] {
            session.recordAttempt(answer: "12", isCorrect: false,
                                  at: start.addingTimeInterval(TimeInterval(offset)))
        }
        XCTAssertNotNil(session.pendingProbe)
        session.recordHintInteraction(at: start.addingTimeInterval(40))
        XCTAssertEqual(session.submitProbeReply(
            "I multiplied 7 by 4 then doubled",
            at: start.addingTimeInterval(45)),
            .substantive(probeSequenceNumber: 1))
        XCTAssertNil(session.pendingProbe)
        XCTAssertNil(session.recordAttempt(
            answer: "56", isCorrect: true, at: start.addingTimeInterval(48)))
        XCTAssertEqual(session.probesFired.count, 1)
        XCTAssertNil(session.pendingProbe)
        XCTAssertEqual(session.classification, .trying)
    }
}
