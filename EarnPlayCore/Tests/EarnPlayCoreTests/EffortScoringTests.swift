import XCTest
@testable import EarnPlayCore

/// T1.4 effort scoring. Scripted-session fixtures are the acceptance
/// fixtures: a change that breaks either outcome fails acceptance.
final class EffortScoringTests: XCTestCase {

    // MARK: Scripted fixture (a) — genuinely trying, wrong answers, passes

    /// Wrong-answer correctness is never an input to the scorer, so this
    /// session passes purely on effort. Uses the worst-case threshold.
    func testScriptedTryingSessionWithWrongAnswersUnlocksAtMaxThreshold() {
        let scorer = EffortScorer(threshold: 14)
        let signals = EffortSignals(
            activeSeconds: 360, genuineAttempts: 3, hintInteractions: 1,
            followUpInteractions: 0, answerRevisions: 1, explanations: 1)
        let result = scorer.evaluate(signals)
        // 6 active min (6) + 3 attempts (6) + 1 hint (2) + 1 revision (1) + 1 explanation (2)
        XCTAssertEqual(result.score, 17)
        XCTAssertEqual(result.threshold, 14)
        XCTAssertTrue(result.floorMet)
        XCTAssertTrue(result.unlockGranted)
        XCTAssertEqual(result.decision, .granted)
    }

    func testGrantedNarrationNamesSpecificEffortObserved() {
        let scorer = EffortScorer(threshold: 14)
        let result = scorer.evaluate(EffortSignals(
            activeSeconds: 360, genuineAttempts: 3, hintInteractions: 1,
            followUpInteractions: 0, answerRevisions: 1, explanations: 1))
        XCTAssertTrue(result.narration.contains("earned this unlock"), result.narration)
        XCTAssertTrue(result.narration.contains("6 active minutes"), result.narration)
        XCTAssertTrue(result.narration.contains("trying 3 times"), result.narration)
        XCTAssertTrue(result.narration.contains("hint"), result.narration)
        XCTAssertTrue(result.narration.contains("revising"), result.narration)
        XCTAssertTrue(result.narration.contains("explaining your thinking"), result.narration)
    }

    // MARK: Scripted fixture (b) — idle session fails, score frozen while idle

    func testScriptedIdleSessionDeniedAndScoreDoesNotRiseWhileIdle() {
        let scorer = EffortScorer(threshold: 8)
        // No interactions after start: evaluated at 30s, 5 min, 20 min.
        let early = scorer.evaluate(EffortSignals(activeSeconds:
            ActiveTimeTracker.activeSeconds(interactionOffsets: [], startedAt: 0, evaluatedAt: 30)))
        let later = scorer.evaluate(EffortSignals(activeSeconds:
            ActiveTimeTracker.activeSeconds(interactionOffsets: [], startedAt: 0, evaluatedAt: 300)))
        let latest = scorer.evaluate(EffortSignals(activeSeconds:
            ActiveTimeTracker.activeSeconds(interactionOffsets: [], startedAt: 0, evaluatedAt: 1200)))
        XCTAssertEqual(early.score, later.score)
        XCTAssertEqual(later.score, latest.score)
        XCTAssertEqual(latest.score, 0)
        XCTAssertFalse(latest.floorMet)
        XCTAssertFalse(latest.unlockGranted)
        XCTAssertEqual(latest.decision, .denied)
    }

    // MARK: Scripted fixture (c) — below floor, long time never unlocks

    func testAttemptsBelowFloorWithLongElapsedTimeDenied() {
        let scorer = EffortScorer(threshold: 8)
        // 60 active minutes alone scores far above threshold, but no
        // hint/follow-up interaction means the floor is not met.
        let noHint = scorer.evaluate(EffortSignals(
            activeSeconds: 3600, genuineAttempts: 3, hintInteractions: 0,
            followUpInteractions: 0, answerRevisions: 2, explanations: 1))
        XCTAssertGreaterThanOrEqual(noHint.score, noHint.threshold)
        XCTAssertFalse(noHint.floorMet)
        XCTAssertFalse(noHint.unlockGranted)
        // No genuine attempt, even with hints and long time.
        let noAttempt = scorer.evaluate(EffortSignals(
            activeSeconds: 3600, genuineAttempts: 0, hintInteractions: 2,
            followUpInteractions: 1, answerRevisions: 0, explanations: 1))
        XCTAssertFalse(noAttempt.floorMet)
        XCTAssertFalse(noAttempt.unlockGranted)
    }

    func testFollowUpInteractionAloneSatisfiesHintSideOfFloor() {
        let scorer = EffortScorer(threshold: 8)
        let result = scorer.evaluate(EffortSignals(
            activeSeconds: 120, genuineAttempts: 1, hintInteractions: 0,
            followUpInteractions: 1, answerRevisions: 0, explanations: 0))
        XCTAssertTrue(result.floorMet)
    }

    func testFloorSettingsFromPolicyAreRespected() {
        let floor = EffortFloorSettings(minGenuineAttempts: 2, minHintOrFollowUpInteractions: 1)
        let scorer = EffortScorer(threshold: 8, floorSettings: floor)
        let oneAttempt = scorer.evaluate(EffortSignals(
            activeSeconds: 600, genuineAttempts: 1, hintInteractions: 1))
        XCTAssertFalse(oneAttempt.floorMet)
        XCTAssertFalse(oneAttempt.unlockGranted)
    }

    // MARK: Active-time accounting (~20s idle pause)

    func testActiveTimePausesAfterAboutTwentySecondsWithoutInteraction() {
        // One interaction at t=0, then silence: only the grace window counts.
        XCTAssertEqual(ActiveTimeTracker.activeSeconds(
            interactionOffsets: [0], startedAt: 0, evaluatedAt: 600), 20)
        // No interaction at all: same cap from session start.
        XCTAssertEqual(ActiveTimeTracker.activeSeconds(
            interactionOffsets: [], startedAt: 0, evaluatedAt: 600), 20)
    }

    func testActiveTimeCountsContinuousInteractionInFull() {
        let every10s = stride(from: 0.0, through: 300.0, by: 10.0).map { $0 }
        XCTAssertEqual(ActiveTimeTracker.activeSeconds(
            interactionOffsets: every10s, startedAt: 0, evaluatedAt: 300), 300)
    }

    func testActiveTimeResumesAfterIdleGapWithoutCountingGap() {
        // Busy 0-60s, idle until 600, busy again to 660.
        var times = stride(from: 0.0, through: 60.0, by: 10.0).map { $0 }
        times += stride(from: 600.0, through: 660.0, by: 10.0).map { $0 }
        // 60 busy + 20 grace after t=60 + 60 busy (eval at last interaction).
        XCTAssertEqual(ActiveTimeTracker.activeSeconds(
            interactionOffsets: times, startedAt: 0, evaluatedAt: 660), 140)
    }

    func testCustomIdlePauseIsRespected() {
        XCTAssertEqual(ActiveTimeTracker.activeSeconds(
            interactionOffsets: [], startedAt: 0, evaluatedAt: 600, idlePauseSeconds: 5), 5)
    }

    // MARK: Each signal contributes (Band B weights)

    func testEachSignalContributesToScore() {
        let scorer = EffortScorer(threshold: 14)
        let base = scorer.evaluate(EffortSignals(activeSeconds: 0)).score
        XCTAssertEqual(scorer.evaluate(EffortSignals(activeSeconds: 120)).score, base + 2)
        XCTAssertEqual(scorer.evaluate(EffortSignals(activeSeconds: 0, genuineAttempts: 1)).score, base + 2)
        XCTAssertEqual(scorer.evaluate(EffortSignals(activeSeconds: 0, hintInteractions: 1)).score, base + 2)
        XCTAssertEqual(scorer.evaluate(EffortSignals(activeSeconds: 0, followUpInteractions: 1)).score, base + 1)
        XCTAssertEqual(scorer.evaluate(EffortSignals(activeSeconds: 0, answerRevisions: 1)).score, base + 1)
        XCTAssertEqual(scorer.evaluate(EffortSignals(activeSeconds: 0, explanations: 1)).score, base + 2)
        // Partial minutes do not count; negative inputs clamp to zero.
        XCTAssertEqual(scorer.evaluate(EffortSignals(activeSeconds: 59)).score, base)
        XCTAssertEqual(scorer.evaluate(EffortSignals(
            activeSeconds: -300, genuineAttempts: -2, hintInteractions: -1,
            followUpInteractions: -1, answerRevisions: -1, explanations: -1)).score, 0)
    }

    func testLegacyPointsUsesBandBAttemptWeight() {
        XCTAssertEqual(EffortScorer(threshold: 8).points(activeSeconds: 300, attempts: 2), 9)
        XCTAssertEqual(EffortScorer(threshold: 8).points(activeSeconds: 0, attempts: 0), 0)
        XCTAssertEqual(EffortScorer(threshold: 8).points(activeSeconds: -120, attempts: -1), 0)
    }

    // MARK: Variable threshold 8-14

    func testThresholdDrawnIsWithinRangeAndVariesAcross20Runs() {
        var rng = EffortSeededRNG(seed: 42)
        var drawn: [Int] = []
        for _ in 0..<20 {
            drawn.append(EffortScorer.drawThreshold(using: &rng))
        }
        XCTAssertTrue(drawn.allSatisfy { (8...14).contains($0) }, "\(drawn)")
        XCTAssertGreaterThan(Set(drawn).count, 1, "threshold must vary per session: \(drawn)")
        // Seeded draws are reproducible from the fixture.
        var replay = EffortSeededRNG(seed: 42)
        let redrawn = (0..<20).map { _ in EffortScorer.drawThreshold(using: &replay) }
        XCTAssertEqual(drawn, redrawn)
    }

    func testDefaultScorerThresholdIsWithinRangeAcross20Runs() {
        let thresholds = (0..<20).map { _ in EffortScorer().threshold }
        XCTAssertTrue(thresholds.allSatisfy { (8...14).contains($0) }, "\(thresholds)")
        XCTAssertGreaterThan(Set(thresholds).count, 1, "\(thresholds)")
    }

    func testExplicitThresholdIsClampedToRange() {
        XCTAssertEqual(EffortScorer(threshold: 1).threshold, 8)
        XCTAssertEqual(EffortScorer(threshold: 99).threshold, 14)
    }

    func testBelowThresholdWithFloorMetIsDenied() {
        let scorer = EffortScorer(threshold: 8)
        let below = scorer.evaluate(EffortSignals(
            activeSeconds: 60, genuineAttempts: 1, hintInteractions: 1))
        XCTAssertLessThan(below.score, below.threshold)
        XCTAssertTrue(below.floorMet)
        XCTAssertFalse(below.unlockGranted)
        XCTAssertFalse(below.narration.contains("earned this unlock"), below.narration)
    }

    // MARK: Recorder (recorded interactions -> signals, incl. hint listens)

    func testRecorderBuildsSignalsAndCountsHintListenAsHintInteraction() {
        var now = Date(timeIntervalSince1970: 1_000)
        let recorder = EffortSessionRecorder(startedAt: now, now: { now })
        recorder.recordAttempt()
        now.addTimeInterval(10); recorder.recordInteraction()
        now.addTimeInterval(10)
        recorder.recordHintListen(HintListenEvent(messageID: "h1", messageText: "hint", emittedAt: now))
        now.addTimeInterval(10); recorder.recordAnswerRevision()
        now.addTimeInterval(10); recorder.recordExplanation()
        now.addTimeInterval(10); recorder.recordFollowUpInteraction()
        let signals = recorder.signals()
        XCTAssertEqual(signals.genuineAttempts, 1)
        XCTAssertEqual(signals.hintInteractions, 1)
        XCTAssertEqual(signals.followUpInteractions, 1)
        XCTAssertEqual(signals.answerRevisions, 1)
        XCTAssertEqual(signals.explanations, 1)
        XCTAssertEqual(signals.activeSeconds, 50)
        let result = recorder.evaluate(EffortScorer(threshold: 8))
        XCTAssertTrue(result.floorMet)
    }

    func testRecorderScoreDoesNotRiseWhileIdle() {
        var now = Date(timeIntervalSince1970: 2_000)
        let recorder = EffortSessionRecorder(startedAt: now, now: { now })
        recorder.recordAttempt()
        recorder.recordHintInteraction()
        now.addTimeInterval(30)
        let at30 = recorder.evaluate(EffortScorer(threshold: 8))
        now.addTimeInterval(600)
        let at630 = recorder.evaluate(EffortScorer(threshold: 8))
        XCTAssertEqual(at30.score, at630.score)
        XCTAssertEqual(recorder.signals().activeSeconds, 20)
    }

    // MARK: Fix round 1 — minima cannot disable the mandatory floor (review #1)

    func testZeroMinimaCannotDisableMandatoryFloor() {
        let floor = EffortFloorSettings(minGenuineAttempts: 0, minHintOrFollowUpInteractions: 0)
        let scorer = EffortScorer(threshold: 8, floorSettings: floor)
        // 480 active seconds = 8 minutes = 8 points: at threshold, but
        // with no attempt and no hint the mandatory floor must still deny.
        let result = scorer.evaluate(EffortSignals(activeSeconds: 480))
        XCTAssertEqual(result.score, 8)
        XCTAssertFalse(result.floorMet)
        XCTAssertFalse(result.unlockGranted)
        XCTAssertEqual(result.decision, .denied)
    }

    func testMutatedZeroMinimaCannotDisableMandatoryFloor() {
        var floor = EffortFloorSettings(minGenuineAttempts: 1, minHintOrFollowUpInteractions: 1)
        floor.minGenuineAttempts = 0
        floor.minHintOrFollowUpInteractions = 0
        let scorer = EffortScorer(threshold: 8, floorSettings: floor)
        let result = scorer.evaluate(EffortSignals(activeSeconds: 480))
        XCTAssertFalse(result.floorMet)
        XCTAssertFalse(result.unlockGranted)
    }

    func testNegativeMinimaCannotDisableMandatoryFloor() {
        let floor = EffortFloorSettings(minGenuineAttempts: -2, minHintOrFollowUpInteractions: -5)
        let scorer = EffortScorer(threshold: 8, floorSettings: floor)
        let result = scorer.evaluate(EffortSignals(activeSeconds: 480))
        XCTAssertFalse(result.floorMet)
        XCTAssertFalse(result.unlockGranted)
    }

    func testFloorSettingsConstructionAndDecodingClampMinimaToOne() {
        let built = EffortFloorSettings(minGenuineAttempts: 0, minHintOrFollowUpInteractions: -3)
        XCTAssertEqual(built.minGenuineAttempts, 1)
        XCTAssertEqual(built.minHintOrFollowUpInteractions, 1)
        let json = #"{"minGenuineAttempts":0,"minHintOrFollowUpInteractions":-2}"#.data(using: .utf8)!
        let decoded = try! JSONDecoder().decode(EffortFloorSettings.self, from: json)
        XCTAssertEqual(decoded.minGenuineAttempts, 1)
        XCTAssertEqual(decoded.minHintOrFollowUpInteractions, 1)
    }

    // MARK: Fix round 1 — event counts scoped to the session interval (review #2)

    func testPreSessionEventsDoNotContributeToScoreOrFloor() {
        let start = Date(timeIntervalSince1970: 1_000)
        let now = start.addingTimeInterval(200)
        let recorder = EffortSessionRecorder(startedAt: start, now: { now })
        let before = start.addingTimeInterval(-50)
        recorder.recordAttempt(at: before)
        recorder.recordHintInteraction(at: before)
        recorder.recordHintInteraction(at: before)
        recorder.recordHintInteraction(at: before)
        let signals = recorder.signals()
        XCTAssertEqual(signals.genuineAttempts, 0)
        XCTAssertEqual(signals.hintInteractions, 0)
        let result = recorder.evaluate(EffortScorer(threshold: 8))
        XCTAssertFalse(result.floorMet)
        XCTAssertEqual(result.decision, .denied)
    }

    func testEventsAfterEvaluationDoNotContribute() {
        // Review counterexample: one attempt + three hints at t=100, then
        // querying at session start must deny, not score 8 with floor met.
        let start = Date(timeIntervalSince1970: 5_000)
        let recorder = EffortSessionRecorder(startedAt: start)
        let later = start.addingTimeInterval(100)
        recorder.recordAttempt(at: later)
        recorder.recordHintInteraction(at: later)
        recorder.recordHintInteraction(at: later)
        recorder.recordHintInteraction(at: later)
        let signals = recorder.signals(at: start)
        XCTAssertEqual(signals.genuineAttempts, 0)
        XCTAssertEqual(signals.hintInteractions, 0)
        XCTAssertEqual(signals.activeSeconds, 0)
        let result = EffortScorer(threshold: 8).evaluate(signals)
        XCTAssertEqual(result.score, 0)
        XCTAssertFalse(result.floorMet)
        XCTAssertEqual(result.decision, .denied)
    }

    // MARK: Fix round 2 — evaluations before session start grant nothing (review #3)

    func testEvaluationBeforeSessionStartReturnsEmptySignals() {
        // Review counterexample: one attempt + three hints at startedAt,
        // querying at startedAt - 1 must deny, not score 8 with floor met.
        let start = Date(timeIntervalSince1970: 9_000)
        let recorder = EffortSessionRecorder(startedAt: start)
        recorder.recordAttempt(at: start)
        recorder.recordHintInteraction(at: start)
        recorder.recordHintInteraction(at: start)
        recorder.recordHintInteraction(at: start)
        let signals = recorder.signals(at: start.addingTimeInterval(-1))
        XCTAssertEqual(signals, EffortSignals())
        let result = EffortScorer(threshold: 8).evaluate(signals)
        XCTAssertEqual(result.score, 0)
        XCTAssertFalse(result.floorMet)
        XCTAssertEqual(result.decision, .denied)
    }
}
