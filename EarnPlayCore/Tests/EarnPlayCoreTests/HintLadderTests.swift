import XCTest
@testable import EarnPlayCore

/// T1.3 (issue #6): hint ladder. Content is always re-checked against
/// `SolverService` — no test trusts the ladder's own word for an answer.
final class HintLadderTests: XCTestCase {
    private let solver = SolverService()
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Fixtures

    private struct Fixture {
        let proposal: ProposedProblem
        let expectedAnswer: String
        /// Hand-computed worked-step fragment; must appear verbatim in
        /// the level-3 hint and end at the solver's answer.
        let workedFragment: String
    }

    private var fixtures: [Fixture] {
        [
            Fixture(proposal: ProposedProblem(
                skill: .multiplicationFacts, form: .story, operands: [7, 8],
                promptText: "7 cartons of 8 eggs. How many eggs?"),
                    expectedAnswer: "56",
                    workedFragment: "7 × 8 = 7 × 7 + 7 = 49 + 7 = 56"),
            Fixture(proposal: ProposedProblem(
                skill: .multiplicationFacts, form: .story, operands: [6, 9],
                promptText: "6 bags of 9 marbles. How many marbles?"),
                    expectedAnswer: "54",
                    workedFragment: "6 × 9 = 6 × 8 + 6 = 48 + 6 = 54"),
            Fixture(proposal: ProposedProblem(
                skill: .multiDigitMultiplication, form: .story, operands: [24, 13],
                promptText: "24 pages for each of 13 classes. How many pages?"),
                    expectedAnswer: "312",
                    workedFragment: "24 × 13 = 24 × 12 + 24 = 288 + 24 = 312"),
            Fixture(proposal: ProposedProblem(
                skill: .division, form: .story, operands: [48, 8],
                promptText: "48 apples in boxes of 8. How many boxes?"),
                    expectedAnswer: "6",
                    workedFragment: "48 ÷ 8 = 6"),
            Fixture(proposal: ProposedProblem(
                skill: .division, form: .story, operands: [17, 5],
                promptText: "17 cookies shared among 5 friends."),
                    expectedAnswer: "3 r 2",
                    workedFragment: "17 ÷ 5 = 3 r 2"),
            Fixture(proposal: ProposedProblem(
                skill: .fractionAddition, form: .story,
                fractions: [SolverFraction(numerator: 1, denominator: 4)!,
                            SolverFraction(numerator: 1, denominator: 2)!],
                promptText: "1/4 cup plus 1/2 cup. How much in all?"),
                    expectedAnswer: "3/4",
                    workedFragment: "1/4 + 1/2 = 1/4 + 2/4 = 3/4"),
            Fixture(proposal: ProposedProblem(
                skill: .fractionComparison, form: .story,
                fractions: [SolverFraction(numerator: 3, denominator: 4)!,
                            SolverFraction(numerator: 1, denominator: 2)!],
                promptText: "Compare 3/4 and 1/2."),
                    expectedAnswer: ">",
                    workedFragment: "3/4 > 1/2"),
            Fixture(proposal: ProposedProblem(
                skill: .wordProblem, form: .story, operands: [15, 27], operation: .add,
                promptText: "15 ribbons Monday, 27 Tuesday. How many?"),
                    expectedAnswer: "42",
                    workedFragment: "15 + 27 = 42"),
            Fixture(proposal: ProposedProblem(
                skill: .wordProblem, form: .story, operands: [6, 7], operation: .multiply,
                promptText: "6 rows of 7 tulips. How many tulips?"),
                    expectedAnswer: "42",
                    workedFragment: "6 × 7 = 6 × 6 + 6 = 36 + 6 = 42"),
            Fixture(proposal: ProposedProblem(
                skill: .wordProblem, form: .story, operands: [50, 18], operation: .subtract,
                promptText: "50 muffins, 18 sold. How many left?"),
                    expectedAnswer: "32",
                    workedFragment: "50 − 18 = 32"),
        ]
    }

    /// Builds a ladder the way production does: solver-verify first,
    /// with a deterministic clock ticking one minute per call.
    private func makeLadder(_ proposal: ProposedProblem,
                            questionId: String = "q-fixture") -> HintLadder {
        guard case .success(let question) = solver.verify(proposal, questionId: questionId) else {
            XCTFail("fixture must verify: \(proposal)")
            fatalError("unreachable")
        }
        var tick = 0
        return HintLadder(question: question, proposal: proposal, now: { [baseDate] in
            defer { tick += 1 }
            return baseDate.addingTimeInterval(Double(tick) * 60)
        })
    }

    // MARK: - Acceptance: 10 fixtures × hints 1–3, 30 events

    func testTenFixturesHintsInOrderWorkedStepMatchesSolverThirtyEvents() {
        var totalEvents = 0
        for (index, fixture) in fixtures.enumerated() {
            // Independent oracle: the solver's answer for these values.
            XCTAssertEqual(solver.solve(fixture.proposal),
                           .verified(verifiedAnswer: fixture.expectedAnswer),
                           "fixture \(index): solver answer mismatch")
            let ladder = makeLadder(fixture.proposal, questionId: "q-\(index)")

            let hint1 = ladder.requestHint()
            let hint2 = ladder.requestHint()
            let hint3 = ladder.requestHint()

            XCTAssertEqual(hint1?.level, .nudge, "fixture \(index): first tap must be the nudge")
            XCTAssertEqual(hint2?.level, .strategy, "fixture \(index): second tap must be the strategy")
            XCTAssertEqual(hint3?.level, .workedStep, "fixture \(index): third tap must be the worked step")
            XCTAssertEqual(Set([hint1?.text, hint2?.text, hint3?.text]).count, 3,
                           "fixture \(index): each level must show distinct content")

            // Worked step arithmetically matches the solver's answer.
            XCTAssertTrue(hint3?.text.contains(fixture.workedFragment) == true,
                          "fixture \(index): worked step \(hint3?.text ?? "nil") must contain \(fixture.workedFragment)")

            // One HintEvent written per level, in order, for this question.
            XCTAssertEqual(ladder.events.map(\.level), [.nudge, .strategy, .workedStep],
                           "fixture \(index)")
            XCTAssertEqual(ladder.events.map(\.questionId),
                           Array(repeating: "q-\(index)", count: 3), "fixture \(index)")
            XCTAssertEqual(ladder.events.map(\.hintText),
                           [hint1?.text, hint2?.text, hint3?.text].map { $0 ?? "" },
                           "fixture \(index): event must record what was offered")
            XCTAssertEqual(ladder.events.map(\.shownAt),
                           [baseDate, baseDate.addingTimeInterval(60), baseDate.addingTimeInterval(120)],
                           "fixture \(index): event must record when")
            totalEvents += ladder.events.count
        }
        XCTAssertEqual(fixtures.count, 10)
        XCTAssertEqual(totalEvents, 30, "10 problems × 3 levels must log 30 HintEvents")
    }

    // MARK: - Ordering and exhaustion

    func testLaterLevelIsNeverOfferedBeforeEarlierOnes() {
        let ladder = makeLadder(fixtures[0].proposal)
        XCTAssertEqual(ladder.nextLevel, .nudge)
        XCTAssertEqual(ladder.requestHint()?.level, .nudge)
        XCTAssertEqual(ladder.nextLevel, .strategy)
        XCTAssertEqual(ladder.requestHint()?.level, .strategy)
        XCTAssertEqual(ladder.nextLevel, .workedStep)
        XCTAssertEqual(ladder.requestHint()?.level, .workedStep)
        XCTAssertNil(ladder.nextLevel)
        XCTAssertFalse(ladder.hasMoreHints)
    }

    func testFourthHintRequestShowsNoNewLevelAndLogsNoDuplicateEvent() {
        let ladder = makeLadder(fixtures[0].proposal)
        _ = ladder.requestHint(); _ = ladder.requestHint(); _ = ladder.requestHint()
        let eventsBefore = ladder.events
        let messagesBefore = ladder.tutorMessages

        XCTAssertNil(ladder.requestHint(), "fourth tap must show no new level")
        XCTAssertNil(ladder.requestHint(), "fifth tap must also show nothing")
        XCTAssertEqual(ladder.events, eventsBefore, "no duplicate event may be logged")
        XCTAssertEqual(ladder.events.count, 3)
        XCTAssertEqual(ladder.tutorMessages, messagesBefore, "no new chat message may be delivered")
    }

    func testHintsAreDeliveredAsTutorMessagesOneLevelPerTap() {
        let ladder = makeLadder(fixtures[0].proposal, questionId: "q-chat")
        let first = ladder.requestHint()
        XCTAssertEqual(ladder.tutorMessages.count, 1, "one tap delivers exactly one message")
        let second = ladder.requestHint()
        XCTAssertEqual(ladder.tutorMessages.count, 2)
        XCTAssertEqual(ladder.tutorMessages.map(\.kind), [.hint, .hint])
        XCTAssertEqual(ladder.tutorMessages.map(\.id), ["q-chat-hint-1", "q-chat-hint-2"])
        XCTAssertEqual(ladder.tutorMessages.map(\.text), [first?.text ?? "", second?.text ?? ""])
        XCTAssertTrue(ladder.tutorMessages.allSatisfy(\.isHint))
    }

    func testNudgeAndStrategyDoNotRevealTheAnswer() {
        // Integer-answer fixtures: the final number must not appear in
        // levels 1–2 (word boundaries, so operands do not false-hit).
        for (index, fixture) in fixtures.enumerated()
        where Int(fixture.expectedAnswer) != nil {
            let ladder = makeLadder(fixture.proposal, questionId: "q-leak-\(index)")
            for level in [HintLevel.nudge, .strategy] {
                let hint = ladder.requestHint()
                XCTAssertEqual(hint?.level, level)
                XCTAssertFalse(Self.containsNumber(hint?.text ?? "", fixture.expectedAnswer),
                               "fixture \(index) level \(level) leaks answer: \(hint?.text ?? "")")
            }
        }
    }

    private static func containsNumber(_ text: String, _ number: String) -> Bool {
        text.split { !$0.isNumber }.map(String.init).contains(number)
    }

    // MARK: - Hint → changed-answer tracking

    func testHintFollowedByChangedAnswerIsRecorded() {
        let ladder = makeLadder(fixtures[0].proposal, questionId: "q-change")
        ladder.recordAnswerSubmission("48")
        let hint = ladder.requestHint()
        XCTAssertEqual(hint?.level, .nudge)
        XCTAssertEqual(ladder.events.first?.answerBeforeHint, "48")
        XCTAssertNil(ladder.events.first?.followedByChangedAnswer,
                     "unresolved until the next answer arrives")

        let changed = ladder.recordAnswerSubmission("56")
        XCTAssertTrue(changed)
        XCTAssertEqual(ladder.events.first?.followedByChangedAnswer, true,
                       "a different answer after the hint must be flagged as changed")
        XCTAssertEqual(ladder.events.first?.nextAnswer, "56")
    }

    func testHintFollowedBySameAnswerIsRecordedAsUnchanged() {
        let ladder = makeLadder(fixtures[0].proposal)
        ladder.recordAnswerSubmission("48")
        _ = ladder.requestHint()
        let changed = ladder.recordAnswerSubmission("48")
        XCTAssertFalse(changed)
        XCTAssertEqual(ladder.events.first?.followedByChangedAnswer, false)
        XCTAssertEqual(ladder.events.first?.nextAnswer, "48")
    }

    func testEquivalentFractionReTypeIsNotAChangedAnswer() {
        let ladder = makeLadder(fixtures[5].proposal)
        ladder.recordAnswerSubmission("2/4")
        _ = ladder.requestHint()
        _ = ladder.requestHint()
        ladder.recordAnswerSubmission("1/2")
        XCTAssertEqual(ladder.events.map(\.followedByChangedAnswer), [false, false],
                       "same value respelled must not count as a revision")
    }

    func testMultipleHintsBeforeNextAnswerResolveTogetherAgainstTheirSnapshots() {
        let ladder = makeLadder(fixtures[0].proposal)
        ladder.recordAnswerSubmission("10")
        _ = ladder.requestHint()
        _ = ladder.requestHint()
        ladder.recordAnswerSubmission("20")
        XCTAssertEqual(ladder.events.map(\.followedByChangedAnswer), [true, true])
        // A later answer must not rewrite already-resolved events.
        ladder.recordAnswerSubmission("10")
        XCTAssertEqual(ladder.events.map(\.followedByChangedAnswer), [true, true])
        XCTAssertEqual(ladder.events.map(\.nextAnswer), ["20", "20"])
    }

    func testFirstAnswerAfterHintWithNoPriorAnswerIsNotAChange() {
        let ladder = makeLadder(fixtures[0].proposal)
        _ = ladder.requestHint()
        XCTAssertNil(ladder.events.first?.answerBeforeHint)
        ladder.recordAnswerSubmission("56")
        XCTAssertEqual(ladder.events.first?.followedByChangedAnswer, false,
                       "a first answer is a submission, not a revision")
    }

    func testAnswerSubmittedWithNoHintDoesNotCreateEvents() {
        let ladder = makeLadder(fixtures[0].proposal)
        ladder.recordAnswerSubmission("48")
        ladder.recordAnswerSubmission("56")
        XCTAssertTrue(ladder.events.isEmpty)
        XCTAssertTrue(ladder.tutorMessages.isEmpty)
    }

    // MARK: - Event sink

    private final class RecordingHintEventSink: HintEventSink {
        private(set) var events: [HintEvent] = []
        func recordHintEvent(_ event: HintEvent) { events.append(event) }
    }

    func testSinkReceivesShowingAndResolutionForEveryEvent() {
        let sink = RecordingHintEventSink()
        guard case .success(let question) = solver.verify(fixtures[0].proposal, questionId: "q-sink") else {
            return XCTFail("fixture must verify")
        }
        let ladder = HintLadder(question: question, proposal: fixtures[0].proposal,
                                now: { self.baseDate }, eventSink: sink)
        ladder.recordAnswerSubmission("1")
        _ = ladder.requestHint()
        XCTAssertEqual(sink.events.count, 1)
        XCTAssertNil(sink.events.first?.followedByChangedAnswer)
        ladder.recordAnswerSubmission("2")
        XCTAssertEqual(sink.events.count, 2, "resolution is reported as an upsert of the same event")
        XCTAssertEqual(sink.events.last?.questionId, "q-sink")
        XCTAssertEqual(sink.events.last?.level, .nudge)
        XCTAssertEqual(sink.events.last?.followedByChangedAnswer, true)
    }

    // MARK: - Reading and fail-closed behaviour

    func testReadingWorkedStepQuotesPassageEvidenceAndSolverAnswer() {
        let proposal = ProposedProblem(
            skill: .readingComprehension, form: .story,
            passage: "Maya planted twelve sunflower seeds in the garden. Every morning she watered them before school.",
            candidateAnswer: "twelve sunflower seeds",
            promptText: "Read: Maya planted twelve sunflower seeds in the garden. Every morning she watered them before school. What did Maya plant?")
        let ladder = makeLadder(proposal)
        _ = ladder.requestHint(); _ = ladder.requestHint()
        let worked = ladder.requestHint()
        XCTAssertEqual(worked?.level, .workedStep)
        XCTAssertTrue(worked?.text.contains("twelve sunflower seeds") == true,
                      "reading worked step must land on the solver-verified answer: \(worked?.text ?? "")")
        XCTAssertTrue(worked?.text.contains("Maya planted twelve sunflower seeds") == true,
                      "reading worked step must quote its passage evidence: \(worked?.text ?? "")")
        XCTAssertEqual(solver.solve(proposal), .verified(verifiedAnswer: "twelve sunflower seeds"))
    }

    func testSolverRejectedProposalYieldsNoHintAndNoEvent() {
        let invalid = ProposedProblem(
            skill: .multiplicationFacts, form: .story, operands: [99, 99],
            promptText: "Out of range; the solver rejects this.")
        guard case .success(let question) = solver.verify(fixtures[0].proposal, questionId: "q-bad") else {
            return XCTFail("control fixture must verify")
        }
        let ladder = HintLadder(question: question, proposal: invalid, now: { self.baseDate })
        XCTAssertNil(ladder.requestHint())
        XCTAssertTrue(ladder.events.isEmpty)
        XCTAssertTrue(ladder.tutorMessages.isEmpty)
    }

    func testLaddersForDifferentQuestionsDoNotShareState() {
        let first = makeLadder(fixtures[0].proposal, questionId: "q-a")
        let second = makeLadder(fixtures[1].proposal, questionId: "q-b")
        _ = first.requestHint(); _ = first.requestHint()
        XCTAssertEqual(second.nextLevel, .nudge)
        XCTAssertTrue(second.events.isEmpty)
        XCTAssertEqual(first.events.map(\.questionId), ["q-a", "q-a"])
    }
}
