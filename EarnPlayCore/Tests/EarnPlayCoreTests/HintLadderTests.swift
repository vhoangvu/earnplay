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
        /// Hand-computed intermediate-step fragment; must appear
        /// verbatim in the level-3 hint, which must stop short of
        /// `expectedAnswer` (issue #6 acceptance).
        let workedFragment: String
    }

    private var fixtures: [Fixture] {
        [
            Fixture(proposal: ProposedProblem(
                skill: .multiplicationFacts, form: .story, operands: [7, 8],
                promptText: "7 cartons of 8 eggs. How many eggs?"),
                    expectedAnswer: "56",
                    workedFragment: "7 × 8 = 7 × 7 + 7 = 49 + 7"),
            Fixture(proposal: ProposedProblem(
                skill: .multiplicationFacts, form: .story, operands: [6, 9],
                promptText: "6 bags of 9 marbles. How many marbles?"),
                    expectedAnswer: "54",
                    workedFragment: "6 × 9 = 6 × 8 + 6 = 48 + 6"),
            Fixture(proposal: ProposedProblem(
                skill: .multiDigitMultiplication, form: .story, operands: [24, 13],
                promptText: "24 pages for each of 13 classes. How many pages?"),
                    expectedAnswer: "312",
                    workedFragment: "24 × 13 = 24 × 12 + 24 = 288 + 24"),
            Fixture(proposal: ProposedProblem(
                skill: .division, form: .story, operands: [48, 8],
                promptText: "48 apples in boxes of 8. How many boxes?"),
                    expectedAnswer: "6",
                    workedFragment: "8 × 5 = 40, and 48 − 40 = 8"),
            Fixture(proposal: ProposedProblem(
                skill: .division, form: .story, operands: [17, 5],
                promptText: "17 cookies shared among 5 friends."),
                    expectedAnswer: "3 r 2",
                    workedFragment: "5 × 2 = 10, and 17 − 10 = 7"),
            Fixture(proposal: ProposedProblem(
                skill: .fractionAddition, form: .story,
                fractions: [SolverFraction(numerator: 1, denominator: 4)!,
                            SolverFraction(numerator: 1, denominator: 2)!],
                promptText: "1/4 cup plus 1/2 cup. How much in all?"),
                    expectedAnswer: "3/4",
                    workedFragment: "1/4 + 1/2 = 1/4 + 2/4"),
            Fixture(proposal: ProposedProblem(
                skill: .fractionComparison, form: .story,
                fractions: [SolverFraction(numerator: 3, denominator: 4)!,
                            SolverFraction(numerator: 1, denominator: 2)!],
                promptText: "Compare 3/4 and 1/2."),
                    expectedAnswer: ">",
                    workedFragment: "3/4 with bottom number 4 is 3/4, and 1/2 with bottom number 4 is 2/4"),
            Fixture(proposal: ProposedProblem(
                skill: .wordProblem, form: .story, operands: [15, 27], operation: .add,
                promptText: "15 ribbons Monday, 27 Tuesday. How many?"),
                    expectedAnswer: "42",
                    workedFragment: "10 + 20 = 30, then the ones, 5 + 7 = 12"),
            Fixture(proposal: ProposedProblem(
                skill: .wordProblem, form: .story, operands: [6, 7], operation: .multiply,
                promptText: "6 rows of 7 tulips. How many tulips?"),
                    expectedAnswer: "42",
                    workedFragment: "6 × 7 = 6 × 6 + 6 = 36 + 6"),
            Fixture(proposal: ProposedProblem(
                skill: .wordProblem, form: .story, operands: [50, 18], operation: .subtract,
                promptText: "50 muffins, 18 sold. How many left?"),
                    expectedAnswer: "32",
                    workedFragment: "50 − 10 = 40"),
            Fixture(proposal: ProposedProblem(
                skill: .fractionComparison, form: .story,
                fractions: [SolverFraction(numerator: 1, denominator: 2)!,
                            SolverFraction(numerator: 2, denominator: 4)!],
                promptText: "Compare 1/2 and 2/4."),
                    expectedAnswer: "=",
                    workedFragment: "both fractions already have bottom number 2"),
            Fixture(proposal: ProposedProblem(
                skill: .fractionComparison, form: .story,
                fractions: [SolverFraction(numerator: 1, denominator: 4_000_000_000)!,
                            SolverFraction(numerator: 1, denominator: 4_000_000_001)!],
                promptText: "Compare 1/4000000000 and 1/4000000001."),
                    expectedAnswer: ">",
                    workedFragment: "1 × 4000000001 makes 4000000001, and 1 × 4000000000 makes 4000000000"),
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

    // MARK: - Acceptance: 12 fixtures × hints 1–3, 36 events

    func testTwelveFixturesHintsInOrderWorkedStepStopsShortThirtySixEvents() {
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

            // Worked step shows the hand-computed intermediate fragment.
            XCTAssertTrue(hint3?.text.contains(fixture.workedFragment) == true,
                          "fixture \(index): worked step \(hint3?.text ?? "nil") must contain \(fixture.workedFragment)")

            // No level — especially the third — may reveal the answer.
            for (hint, level) in [(hint1, HintLevel.nudge), (hint2, .strategy), (hint3, .workedStep)] {
                assertHintHidesAnswer(hint?.text ?? "", fixture: fixture, level: level, index: index)
            }

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
        XCTAssertEqual(fixtures.count, 12)
        XCTAssertEqual(totalEvents, 36, "12 problems × 3 levels must log 36 HintEvents")
    }

    /// Acceptance-critical (issue #6): fails if any hint — at any level —
    /// reveals the final answer. Comparison hints must contain neither
    /// the completed verdict nor any comparison symbol; every other
    /// skill must not contain the solver's answer string.
    private func assertHintHidesAnswer(_ text: String, fixture: Fixture,
                                      level: HintLevel, index: Int,
                                      file: StaticString = #filePath, line: UInt = #line) {
        switch fixture.proposal.skill {
        case .fractionComparison:
            let f1 = fixture.proposal.fractions[0]
            let f2 = fixture.proposal.fractions[1]
            XCTAssertFalse(text.contains("\(f1) \(fixture.expectedAnswer) \(f2)"),
                           "fixture \(index) level \(level): reveals the verdict: \(text)",
                           file: file, line: line)
            for symbol in ["<", ">", "="] {
                XCTAssertFalse(text.contains(symbol),
                               "fixture \(index) level \(level): leaks comparison symbol \(symbol): \(text)",
                               file: file, line: line)
            }
        default:
            XCTAssertFalse(text.contains(fixture.expectedAnswer),
                           "fixture \(index) level \(level) reveals the answer: \(text)",
                           file: file, line: line)
        }
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

    func testChangedAnswerFollowsSkillSpecificEquivalence() {
        // Reading: case and punctuation do not make a new answer.
        let reading = ProposedProblem(
            skill: .readingComprehension, form: .story,
            passage: "Maya planted twelve sunflower seeds in the garden.",
            candidateAnswer: "Maya",
            promptText: "Read: Maya planted twelve sunflower seeds in the garden. Who planted the seeds?")
        let readingLadder = makeLadder(reading, questionId: "q-equiv-read")
        readingLadder.recordAnswerSubmission("Maya")
        _ = readingLadder.requestHint()
        XCTAssertFalse(readingLadder.recordAnswerSubmission("maya."),
                       "grading-equivalent reading answer must not count as changed")
        XCTAssertEqual(readingLadder.events.map(\.followedByChangedAnswer), [false])
        XCTAssertEqual(readingLadder.events.first?.nextAnswer, "maya.")
        // A genuinely different reading answer still counts as changed.
        _ = readingLadder.requestHint()
        XCTAssertTrue(readingLadder.recordAnswerSubmission("garden"))
        XCTAssertEqual(readingLadder.events.map(\.followedByChangedAnswer), [false, true])

        // Comparison: "==" is grading-identical to "=".
        let comparisonLadder = makeLadder(fixtures[10].proposal, questionId: "q-equiv-cmp")
        comparisonLadder.recordAnswerSubmission("=")
        _ = comparisonLadder.requestHint()
        XCTAssertFalse(comparisonLadder.recordAnswerSubmission("=="),
                       "grading-equivalent comparison answer must not count as changed")
        XCTAssertEqual(comparisonLadder.events.map(\.followedByChangedAnswer), [false])
        _ = comparisonLadder.requestHint()
        XCTAssertTrue(comparisonLadder.recordAnswerSubmission(">"))
        XCTAssertEqual(comparisonLadder.events.map(\.followedByChangedAnswer), [false, true])
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
        ladder.waitForSinkDelivery()
        XCTAssertEqual(sink.events.count, 1)
        XCTAssertNil(sink.events.first?.followedByChangedAnswer)
        ladder.recordAnswerSubmission("2")
        ladder.waitForSinkDelivery()
        XCTAssertEqual(sink.events.count, 2, "resolution is reported as an upsert of the same event")
        XCTAssertEqual(sink.events.last?.questionId, "q-sink")
        XCTAssertEqual(sink.events.last?.level, .nudge)
        XCTAssertEqual(sink.events.last?.followedByChangedAnswer, true)
    }

    /// A synchronous sink that reads ladder state back on every
    /// notification — delivery must not hold the ladder lock, or this
    /// re-entrant read deadlocks the Hint tap.
    private final class ReentrantReadingSink: HintEventSink {
        weak var ladder: HintLadder?
        private(set) var delivered: [HintEvent] = []
        func recordHintEvent(_ event: HintEvent) {
            _ = ladder?.events
            _ = ladder?.nextLevel
            _ = ladder?.tutorMessages
            _ = ladder?.hasMoreHints
            delivered.append(event)
        }
    }

    func testSynchronousSinkReadingLadderStateDoesNotDeadlock() {
        let sink = ReentrantReadingSink()
        guard case .success(let question) = solver.verify(fixtures[0].proposal, questionId: "q-reentrant") else {
            return XCTFail("fixture must verify")
        }
        let ladder = HintLadder(question: question, proposal: fixtures[0].proposal,
                                now: { self.baseDate }, eventSink: sink)
        sink.ladder = ladder
        _ = ladder.requestHint()
        _ = ladder.requestHint()
        ladder.recordAnswerSubmission("56")
        _ = ladder.requestHint()
        ladder.waitForSinkDelivery()
        // Showing order preserved, then resolutions in shown order.
        XCTAssertEqual(sink.delivered.map(\.level),
                       [.nudge, .strategy, .nudge, .strategy, .workedStep])
        XCTAssertEqual(sink.delivered.map(\.followedByChangedAnswer),
                       [nil, nil, false, false, nil],
                       "first answer resolves pending hints as unchanged, not revisions")
        XCTAssertEqual(sink.delivered.map(\.nextAnswer),
                       [nil, nil, "56", "56", nil])
    }

    // MARK: - Reading and fail-closed behaviour

    func testReadingWorkedStepBlanksTheAnswerButKeepsEvidence() {
        let proposal = ProposedProblem(
            skill: .readingComprehension, form: .story,
            passage: "Maya planted twelve sunflower seeds in the garden. Every morning she watered them before school.",
            candidateAnswer: "twelve sunflower seeds",
            promptText: "Read: Maya planted twelve sunflower seeds in the garden. Every morning she watered them before school. What did Maya plant?")
        XCTAssertEqual(solver.solve(proposal), .verified(verifiedAnswer: "twelve sunflower seeds"))
        let ladder = makeLadder(proposal)
        let hint1 = ladder.requestHint()
        let hint2 = ladder.requestHint()
        let worked = ladder.requestHint()
        XCTAssertEqual(worked?.level, .workedStep)
        XCTAssertTrue(worked?.text.contains("Maya planted ___ in the garden.") == true,
                      "reading worked step must quote its evidence with the answer blanked: \(worked?.text ?? "")")
        for (hint, name) in [(hint1, "nudge"), (hint2, "strategy"), (worked, "worked step")] {
            XCTAssertFalse(hint?.text.contains("twelve sunflower seeds") == true,
                           "reading \(name) must not reveal the answer: \(hint?.text ?? "")")
        }
    }

    func testHugeDenominatorComparisonUsesCrossMultiplicationWithoutTrap() {
        let f1 = SolverFraction(numerator: 1, denominator: 4_000_000_000)!
        let f2 = SolverFraction(numerator: 1, denominator: 4_000_000_001)!
        // Precondition: consecutive denominators are coprime, so the LCM
        // is their product — which overflows Int — while the solver's
        // cross-products still fit and verify.
        XCTAssertEqual(SolverFraction.gcd(4_000_000_000, 4_000_000_001), 1)
        XCTAssertTrue(4_000_000_000.multipliedReportingOverflow(by: 4_000_000_001).overflow)
        let proposal = ProposedProblem(
            skill: .fractionComparison, form: .story, fractions: [f1, f2],
            promptText: "Compare 1/4000000000 and 1/4000000001.")
        XCTAssertEqual(solver.solve(proposal), .verified(verifiedAnswer: ">"))
        let ladder = makeLadder(proposal, questionId: "q-huge")
        let hint1 = ladder.requestHint()
        let hint2 = ladder.requestHint()
        let hint3 = ladder.requestHint()
        XCTAssertEqual([hint1?.level, hint2?.level, hint3?.level],
                       [.nudge, .strategy, .workedStep])
        XCTAssertTrue(hint2?.text.contains("cross-multiply") == true,
                      "strategy must fall back to cross-multiplication: \(hint2?.text ?? "")")
        XCTAssertTrue(hint3?.text.contains("4000000001 and 4000000000") == true,
                      "worked step must show the cross-products: \(hint3?.text ?? "")")
        for symbol in ["<", ">", "="] {
            XCTAssertFalse(hint3?.text.contains(symbol) == true,
                           "worked step must not state the verdict: \(hint3?.text ?? "")")
        }
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

    func testMismatchedProposalAndQuestionPairIsRejected() {
        // A verified 7 × 8 question paired with a valid 6 × 9 proposal:
        // the proposal verifies on its own, but not to this question.
        XCTAssertEqual(solver.solve(fixtures[1].proposal), .verified(verifiedAnswer: "54"))
        guard case .success(let question78) = solver.verify(fixtures[0].proposal, questionId: "q-78") else {
            return XCTFail("control fixture must verify")
        }
        let mismatched = HintLadder(question: question78, proposal: fixtures[1].proposal,
                                    now: { self.baseDate })
        XCTAssertNil(mismatched.requestHint(), "a mismatched pair must show no hint")
        XCTAssertTrue(mismatched.events.isEmpty)
        XCTAssertTrue(mismatched.tutorMessages.isEmpty)

        // Same answer, different problem: still rejected (the whole
        // question must match, not just the answer).
        let swapped = ProposedProblem(
            skill: .multiplicationFacts, form: .story, operands: [8, 7],
            promptText: "8 cartons of 7 eggs. How many eggs?")
        XCTAssertEqual(solver.solve(swapped), .verified(verifiedAnswer: "56"))
        let swappedLadder = HintLadder(question: question78, proposal: swapped,
                                       now: { self.baseDate })
        XCTAssertNil(swappedLadder.requestHint())
        XCTAssertTrue(swappedLadder.events.isEmpty)
    }

    func testLaddersForDifferentQuestionsDoNotShareState() {
        let first = makeLadder(fixtures[0].proposal, questionId: "q-a")
        let second = makeLadder(fixtures[1].proposal, questionId: "q-b")
        _ = first.requestHint(); _ = first.requestHint()
        XCTAssertEqual(second.nextLevel, .nudge)
        XCTAssertTrue(second.events.isEmpty)
        XCTAssertEqual(first.events.map(\.questionId), ["q-a", "q-a"])
    }

    // MARK: - Fix round 2 (a): verified-question / proposal operand binding

    func testSamePromptSameAnswerDifferentOperandsAreRejected() {
        // 6×6 and 9×4 both verify to 36: with the same prompt text the old
        // `rechecked == question` guard accepted the mismatched pair and
        // hinted one problem under another question's id.
        let prompt = "Bags of marbles. How many marbles in all?"
        let from66 = ProposedProblem(skill: .multiplicationFacts, form: .story,
                                     operands: [6, 6], promptText: prompt)
        let from94 = ProposedProblem(skill: .multiplicationFacts, form: .story,
                                     operands: [9, 4], promptText: prompt)
        XCTAssertEqual(solver.solve(from66), .verified(verifiedAnswer: "36"))
        XCTAssertEqual(solver.solve(from94), .verified(verifiedAnswer: "36"))
        guard case .success(let question66) = solver.verify(from66, questionId: "q-bind") else {
            return XCTFail("control proposal must verify")
        }
        let mismatched = HintLadder(question: question66, proposal: from94,
                                    now: { self.baseDate })
        XCTAssertNil(mismatched.requestHint(),
                     "same prompt+answer with different operands must show no hint")
        XCTAssertTrue(mismatched.events.isEmpty)
        XCTAssertTrue(mismatched.tutorMessages.isEmpty)
    }

    func testSameOperandsDifferentOperationAreRejected() {
        // 2+2 and 2×2 both verify to 4: the binding must include the operation.
        let prompt = "Two and two. How many?"
        let add = ProposedProblem(skill: .wordProblem, form: .story, operands: [2, 2],
                                  operation: .add, promptText: prompt)
        let multiply = ProposedProblem(skill: .wordProblem, form: .story, operands: [2, 2],
                                       operation: .multiply, promptText: prompt)
        XCTAssertEqual(solver.solve(add), .verified(verifiedAnswer: "4"))
        XCTAssertEqual(solver.solve(multiply), .verified(verifiedAnswer: "4"))
        guard case .success(let addQuestion) = solver.verify(add, questionId: "q-op") else {
            return XCTFail("control proposal must verify")
        }
        let mismatched = HintLadder(question: addQuestion, proposal: multiply,
                                    now: { self.baseDate })
        XCTAssertNil(mismatched.requestHint(),
                     "same operands with a different operation must show no hint")
        XCTAssertTrue(mismatched.events.isEmpty)
        XCTAssertTrue(mismatched.tutorMessages.isEmpty)
    }

    // MARK: - Fix round 2 (c): addition partial-sum reveal

    func testSingleDigitAdditionWorkedStepStopsShortOfAnswer() {
        // [6,7]: the old tens/ones split showed "6 + 7 = 13" — the answer.
        let proposal = ProposedProblem(skill: .wordProblem, form: .story,
                                       operands: [6, 7], operation: .add,
                                       promptText: "6 ribbons Monday, 7 Tuesday. How many?")
        XCTAssertEqual(solver.solve(proposal), .verified(verifiedAnswer: "13"))
        let ladder = makeLadder(proposal, questionId: "q-add67")
        _ = ladder.requestHint(); _ = ladder.requestHint()
        let worked = ladder.requestHint()
        XCTAssertEqual(worked?.level, .workedStep)
        XCTAssertFalse(worked?.text.contains("13") == true,
                       "worked step must not reveal the answer: \(worked?.text ?? "")")
        XCTAssertTrue(worked?.text.contains("split 6 into 3 + 3") == true,
                      "degenerate addition must split one addend: \(worked?.text ?? "")")
        XCTAssertTrue(worked?.text.contains("you get 10") == true,
                      "split step must show the short-of-answer partial: \(worked?.text ?? "")")
    }

    func testRoundNumberAdditionWorkedStepStopsShortOfAnswer() {
        // [20,30]: the old tens/ones split showed "20 + 30 = 50" — the answer.
        let proposal = ProposedProblem(skill: .wordProblem, form: .story,
                                       operands: [20, 30], operation: .add,
                                       promptText: "20 shells, then 30 more. How many?")
        XCTAssertEqual(solver.solve(proposal), .verified(verifiedAnswer: "50"))
        let ladder = makeLadder(proposal, questionId: "q-add2030")
        _ = ladder.requestHint(); _ = ladder.requestHint()
        let worked = ladder.requestHint()
        XCTAssertEqual(worked?.level, .workedStep)
        XCTAssertFalse(worked?.text.contains("50") == true,
                       "worked step must not reveal the answer: \(worked?.text ?? "")")
        XCTAssertTrue(worked?.text.contains("split 20 into 10 + 10") == true,
                      "degenerate addition must split one addend: \(worked?.text ?? "")")
        XCTAssertTrue(worked?.text.contains("you get 40") == true,
                      "split step must show the short-of-answer partial: \(worked?.text ?? "")")
    }

    // MARK: - Fix round 2 (d): zero-subtraction reveal

    func testZeroTakeawayIsIgnoredBeforeChoosingWorkedStep() {
        // [50,18,0]: the old multi-operand step showed "50 − 18 = 32" — the answer.
        let proposal = ProposedProblem(skill: .wordProblem, form: .story,
                                       operands: [50, 18, 0], operation: .subtract,
                                       promptText: "50 muffins, 18 sold. How many left?")
        XCTAssertEqual(solver.solve(proposal), .verified(verifiedAnswer: "32"))
        let ladder = makeLadder(proposal, questionId: "q-sub0")
        _ = ladder.requestHint(); _ = ladder.requestHint()
        let worked = ladder.requestHint()
        XCTAssertEqual(worked?.level, .workedStep)
        XCTAssertFalse(worked?.text.contains("32") == true,
                       "worked step must not reveal the answer: \(worked?.text ?? "")")
        XCTAssertTrue(worked?.text.contains("50 − 10 = 40") == true,
                      "a single meaningful subtraction must use the split step: \(worked?.text ?? "")")
    }

    func testLeadingZeroTakeawayIsIgnored() {
        // [50,0,18]: a zero take-away first must not produce "50 − 0 = 50".
        let proposal = ProposedProblem(skill: .wordProblem, form: .story,
                                       operands: [50, 0, 18], operation: .subtract,
                                       promptText: "50 muffins, 18 sold. How many left?")
        XCTAssertEqual(solver.solve(proposal), .verified(verifiedAnswer: "32"))
        let ladder = makeLadder(proposal, questionId: "q-sub0lead")
        _ = ladder.requestHint(); _ = ladder.requestHint()
        let worked = ladder.requestHint()
        XCTAssertTrue(worked?.text.contains("50 − 10 = 40") == true,
                      "a single meaningful subtraction must use the split step: \(worked?.text ?? "")")
        XCTAssertFalse(worked?.text.contains("50 − 0") == true,
                       "zero take-aways must never be worked: \(worked?.text ?? "")")
    }

    func testAllZeroTakeawaysExplainTakingNothing() {
        // [50,0]: the only take-away is zero — explain without stating 50.
        let proposal = ProposedProblem(skill: .wordProblem, form: .story,
                                       operands: [50, 0], operation: .subtract,
                                       promptText: "50 muffins, none sold. How many left?")
        XCTAssertEqual(solver.solve(proposal), .verified(verifiedAnswer: "50"))
        let ladder = makeLadder(proposal, questionId: "q-sub00")
        _ = ladder.requestHint(); _ = ladder.requestHint()
        let worked = ladder.requestHint()
        XCTAssertFalse(worked?.text.contains("50") == true,
                       "worked step must not reveal the answer: \(worked?.text ?? "")")
        XCTAssertTrue(worked?.text.contains("taking away 0") == true,
                      "all-zero take-aways must keep the taking-nothing step: \(worked?.text ?? "")")
    }

    // MARK: - Fix round 2 (e): normalized-answer blanking

    func testReadingWorkedStepBlanksEverySpellingOfTheAnswer() {
        // Evidence holds both "blue box" and "blue-box": both normalize to the
        // accepted answer, so both must be blanked.
        let passage = "The blue box sat by the blue-box shed."
        let proposal = ProposedProblem(skill: .readingComprehension, form: .story,
                                       passage: passage, candidateAnswer: "blue box",
                                       promptText: "Read: \(passage) Where did the box sit?")
        XCTAssertEqual(solver.solve(proposal), .verified(verifiedAnswer: "blue box"))
        let ladder = makeLadder(proposal, questionId: "q-blank2")
        _ = ladder.requestHint(); _ = ladder.requestHint()
        let worked = ladder.requestHint()
        XCTAssertTrue(worked?.text.contains("___") == true,
                      "must quote blanked evidence: \(worked?.text ?? "")")
        XCTAssertFalse(worked?.text.lowercased().contains("blue box") == true,
                       "no accepted spelling may stay visible: \(worked?.text ?? "")")
        XCTAssertFalse(worked?.text.lowercased().contains("blue-box") == true,
                       "no accepted spelling may stay visible: \(worked?.text ?? "")")
    }

    func testReadingWorkedStepBlanksAnswerWithTrailingPunctuation() {
        // Verified answer "blue box!": normalization strips the "!", so the
        // evidence span must still be found and blanked (old code fell back).
        let passage = "The blue box is by the bed."
        let proposal = ProposedProblem(skill: .readingComprehension, form: .story,
                                       passage: passage, candidateAnswer: "blue box!",
                                       promptText: "Read: \(passage) What is by the bed?")
        XCTAssertEqual(solver.solve(proposal), .verified(verifiedAnswer: "blue box!"))
        let ladder = makeLadder(proposal, questionId: "q-blankbang")
        _ = ladder.requestHint(); _ = ladder.requestHint()
        let worked = ladder.requestHint()
        XCTAssertTrue(worked?.text.contains("___") == true,
                      "must quote blanked evidence, not fall back: \(worked?.text ?? "")")
        XCTAssertFalse(worked?.text.contains("blue box") == true,
                       "the answer span must be blanked: \(worked?.text ?? "")")
    }

    // MARK: - Fix round 2 (f): division nonnegative leftover

    func testDivisionStrategyRequiresNonnegativeLeftover() {
        // 17÷5, guess 4 leaves −3 < 5: the strategy must demand 0-or-more too.
        let proposal = ProposedProblem(skill: .division, form: .story, operands: [17, 5],
                                       promptText: "17 cookies shared among 5 friends.")
        XCTAssertEqual(solver.solve(proposal), .verified(verifiedAnswer: "3 r 2"))
        let ladder = makeLadder(proposal, questionId: "q-divstrat")
        _ = ladder.requestHint()
        let strategy = ladder.requestHint()
        XCTAssertEqual(strategy?.level, .strategy)
        XCTAssertTrue(strategy?.text.contains("0 or more") == true,
                      "strategy must require a nonnegative leftover: \(strategy?.text ?? "")")
        XCTAssertTrue(strategy?.text.contains("smaller than 5") == true,
                      "strategy must keep the smaller-than-divisor bound: \(strategy?.text ?? "")")
        XCTAssertFalse(strategy?.text.contains("3 r 2") == true,
                       "strategy must not reveal the answer: \(strategy?.text ?? "")")
    }

    // MARK: - Fix round 2 (g): reading-evidence relevance

    func testReadingWorkedStepQuotesSentenceThatAnswersTheQuestion() {
        // Both sentences contain "red"; only the fox sentence answers the question.
        let passage = "Maya wore a red hat. A red fox ran past."
        let proposal = ProposedProblem(skill: .readingComprehension, form: .story,
                                       passage: passage, candidateAnswer: "red",
                                       promptText: "Read: \(passage) What color was the fox?")
        XCTAssertEqual(solver.solve(proposal), .verified(verifiedAnswer: "red"))
        let ladder = makeLadder(proposal, questionId: "q-fox")
        _ = ladder.requestHint(); _ = ladder.requestHint()
        let worked = ladder.requestHint()
        XCTAssertTrue(worked?.text.contains("A ___ fox ran past.") == true,
                      "must quote the fox sentence with the answer blanked: \(worked?.text ?? "")")
        XCTAssertFalse(worked?.text.contains("hat") == true,
                       "must not quote the hat sentence: \(worked?.text ?? "")")
    }

    func testReadingWorkedStepAvoidsQuotingWhenEvidenceIsAmbiguous() {
        // Both sentences match the question equally: quote neither.
        let passage = "A red hat sat here. A red mat sat there."
        let proposal = ProposedProblem(skill: .readingComprehension, form: .story,
                                       passage: passage, candidateAnswer: "red",
                                       promptText: "Read: \(passage) What sat?")
        XCTAssertEqual(solver.solve(proposal), .verified(verifiedAnswer: "red"))
        let ladder = makeLadder(proposal, questionId: "q-ambig")
        _ = ladder.requestHint(); _ = ladder.requestHint()
        let worked = ladder.requestHint()
        XCTAssertFalse(worked?.text.contains("___") == true,
                       "must not quote ambiguous evidence: \(worked?.text ?? "")")
        XCTAssertTrue(worked?.text.contains("point to the exact sentence") == true,
                      "must fall back to pointing at the passage: \(worked?.text ?? "")")
    }

    // MARK: - Fix round 2 (b): notification ordering and serialization

    /// Slow thread-safe sink that records every delivery in arrival order
    /// plus the maximum number of concurrent in-flight deliveries. The
    /// sleep widens the race window: pre-fix, concurrent Hint taps
    /// overlapped inside the sink (maxActive 3) and resolutions could land
    /// before their own showings.
    private final class ConcurrencyProbingSink: HintEventSink, @unchecked Sendable {
        private let lock = NSLock()
        private var _active = 0
        private var _maxActive = 0
        private var _delivered: [HintEvent] = []
        var maxActive: Int { lock.withLock { _maxActive } }
        var delivered: [HintEvent] { lock.withLock { _delivered } }
        func recordHintEvent(_ event: HintEvent) {
            lock.withLock {
                _active += 1
                _maxActive = max(_maxActive, _active)
            }
            Thread.sleep(forTimeInterval: 0.005)
            lock.withLock {
                _active -= 1
                _delivered.append(event)
            }
        }
    }

    func testConcurrentHintTapsDeliverSeriallyInStateChangeOrder() {
        guard case .success(let question) = solver.verify(fixtures[0].proposal,
                                                          questionId: "q-conc") else {
            return XCTFail("fixture must verify")
        }
        let sink = ConcurrencyProbingSink()
        let ladder = HintLadder(question: question, proposal: fixtures[0].proposal,
                                now: { self.baseDate }, eventSink: sink)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            _ = ladder.requestHint()
        }
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            ladder.recordAnswerSubmission("7")
        }
        ladder.waitForSinkDelivery()

        let delivered = sink.delivered
        XCTAssertEqual(delivered.count, 6, "three showings plus three resolutions")
        XCTAssertEqual(sink.maxActive, 1, "sink deliveries must never overlap")
        // State-change order: every showing in ladder order first (all
        // showings precede the resolving answer), then every resolution in
        // shown order — an older unresolved event never overwrites its own
        // resolution.
        XCTAssertEqual(delivered.map(\.level),
                       [.nudge, .strategy, .workedStep, .nudge, .strategy, .workedStep])
        XCTAssertEqual(delivered.map(\.followedByChangedAnswer),
                       [nil, nil, nil, false, false, false],
                       "first answer with no baseline resolves as unchanged, not a revision")
        XCTAssertEqual(delivered.map(\.nextAnswer),
                       [nil, nil, nil, "7", "7", "7"])
    }

    // MARK: - Fix round 3

    func testSharedSinkConcurrentDeliveryIsSerialized() {
        guard case .success(let q1) = solver.verify(fixtures[0].proposal, questionId: "q-shared-1"),
              case .success(let q2) = solver.verify(fixtures[1].proposal, questionId: "q-shared-2") else {
            return XCTFail("fixtures must verify")
        }
        let sink = ConcurrencyProbingSink()
        let ladder1 = HintLadder(question: q1, proposal: fixtures[0].proposal,
                                 now: { self.baseDate }, eventSink: sink)
        let ladder2 = HintLadder(question: q2, proposal: fixtures[1].proposal,
                                 now: { self.baseDate }, eventSink: sink)
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            if i % 2 == 0 {
                _ = ladder1.requestHint()
            } else {
                _ = ladder2.requestHint()
            }
        }
        ladder1.waitForSinkDelivery()
        ladder2.waitForSinkDelivery()
        XCTAssertEqual(sink.delivered.count, 6, "three showings per ladder sharing one sink")
        XCTAssertEqual(sink.maxActive, 1, "shared sink deliveries must never overlap")
        XCTAssertEqual(sink.delivered.filter { $0.questionId == "q-shared-1" }.count, 3)
        XCTAssertEqual(sink.delivered.filter { $0.questionId == "q-shared-2" }.count, 3)
    }

    func testMultiplicationNudgeDoesNotAssertOperandOrientation() {
        let proposal = ProposedProblem(skill: .wordProblem, form: .story,
                                       operands: [6, 7], operation: .multiply,
                                       promptText: "6 rows of 7 tulips. How many tulips?")
        XCTAssertEqual(solver.solve(proposal), .verified(verifiedAnswer: "42"))
        let ladder = makeLadder(proposal, questionId: "q-orient")
        let nudge = ladder.requestHint()
        XCTAssertEqual(nudge?.level, .nudge)
        // Rendered form is six rows with seven flowers each (6 groups of 7);
        // the nudge must not reverse it to seven groups of six.
        XCTAssertFalse(nudge?.text.contains("7 equal groups of 6") == true,
                       "nudge reverses the rendered groups: \(nudge?.text ?? "")")
        XCTAssertFalse(nudge?.text.contains("groups of 6") == true,
                       "nudge must not assert an operand orientation: \(nudge?.text ?? "")")
        XCTAssertFalse(nudge?.text.contains("groups of 7") == true,
                       "nudge must not assert an operand orientation: \(nudge?.text ?? "")")
        XCTAssertTrue(nudge?.text.contains("6 × 7") == true,
                      "nudge must name the problem: \(nudge?.text ?? "")")
        XCTAssertTrue(nudge?.text.contains("equal groups") == true,
                      "nudge must still point at the groups: \(nudge?.text ?? "")")
    }

    func testZeroProductWorkedStepDoesNotRevealAnswer() {
        let proposal = ProposedProblem(skill: .multiplicationFacts, form: .story,
                                       operands: [0, 7], promptText: "0 bags of 7 marbles. How many?")
        XCTAssertEqual(solver.solve(proposal), .verified(verifiedAnswer: "0"))
        let ladder = makeLadder(proposal, questionId: "q-zero")
        _ = ladder.requestHint(); _ = ladder.requestHint()
        let worked = ladder.requestHint()
        XCTAssertEqual(worked?.level, .workedStep)
        // Old template showed 0 × 7 = 0 × 6 + 0 = 0 + 0, whose partial is the answer.
        XCTAssertFalse(worked?.text.contains("0 + 0") == true,
                       "zero-product partial already equals the answer: \(worked?.text ?? "")")
        XCTAssertFalse(worked?.text.contains("0 × 6") == true,
                       "must not use the near-complete-product template: \(worked?.text ?? "")")
        XCTAssertFalse(worked?.text.contains("= 0 + ") == true,
                       "must not show a computed zero partial: \(worked?.text ?? "")")
        XCTAssertTrue(worked?.text.contains("How many") == true || worked?.text.contains("altogether") == true,
                      "child must still finish the step: \(worked?.text ?? "")")
    }

    func testQuotientOneDivisionDoesNotRevealRemainingGroups() {
        let proposal = ProposedProblem(skill: .division, form: .story,
                                       operands: [5, 5], promptText: "5 cookies shared among 5 friends.")
        XCTAssertEqual(solver.solve(proposal), .verified(verifiedAnswer: "1"))
        let ladder = makeLadder(proposal, questionId: "q-quot1")
        _ = ladder.requestHint(); _ = ladder.requestHint()
        let worked = ladder.requestHint()
        XCTAssertEqual(worked?.level, .workedStep)
        // Old wording stated exactly one more group fits, giving 0 + 1 = 1.
        XCTAssertFalse(worked?.text.contains("exactly one more") == true,
                       "must not state the remaining groups: \(worked?.text ?? "")")
        XCTAssertTrue(worked?.text.contains("How many more groups") == true,
                      "child must determine the remaining groups: \(worked?.text ?? "")")
        XCTAssertTrue(worked?.text.contains("how many groups is that altogether") == true,
                      "child must still count the total: \(worked?.text ?? "")")
        XCTAssertFalse(worked?.text.contains("1") == true,
                       "worked step must not reveal the quotient: \(worked?.text ?? "")")
    }

    func testSameDenominatorAdditionHasWorkedStep() {
        let f1 = SolverFraction(numerator: 1, denominator: 5)!
        let f2 = SolverFraction(numerator: 2, denominator: 5)!
        let proposal = ProposedProblem(skill: .fractionAddition, form: .story,
                                       fractions: [f1, f2], promptText: "1/5 cup plus 2/5 cup. How much?")
        XCTAssertEqual(solver.solve(proposal), .verified(verifiedAnswer: "3/5"))
        let ladder = makeLadder(proposal, questionId: "q-sameden-add")
        _ = ladder.requestHint(); _ = ladder.requestHint()
        let worked = ladder.requestHint()
        XCTAssertEqual(worked?.level, .workedStep)
        XCTAssertFalse(worked?.text.contains("1/5 + 2/5 = 1/5 + 2/5") == true,
                       "must not merely repeat the original values: \(worked?.text ?? "")")
        XCTAssertTrue(worked?.text.contains("already have bottom number 5") == true,
                      "must make same-denominator progress: \(worked?.text ?? "")")
        XCTAssertFalse(worked?.text.contains("3/5") == true,
                       "must not reveal the sum: \(worked?.text ?? "")")
    }

    func testSameDenominatorComparisonHasWorkedStep() {
        let f1 = SolverFraction(numerator: 1, denominator: 5)!
        let f2 = SolverFraction(numerator: 2, denominator: 5)!
        let proposal = ProposedProblem(skill: .fractionComparison, form: .story,
                                       fractions: [f1, f2], promptText: "Compare 1/5 and 2/5.")
        XCTAssertEqual(solver.solve(proposal), .verified(verifiedAnswer: "<"))
        let ladder = makeLadder(proposal, questionId: "q-sameden-cmp")
        _ = ladder.requestHint(); _ = ladder.requestHint()
        let worked = ladder.requestHint()
        XCTAssertEqual(worked?.level, .workedStep)
        XCTAssertFalse(worked?.text.contains("with bottom number 5 is 1/5") == true,
                       "must not merely repeat the conversion: \(worked?.text ?? "")")
        XCTAssertTrue(worked?.text.contains("already have bottom number 5") == true,
                      "must make same-denominator progress: \(worked?.text ?? "")")
        for symbol in ["<", ">", "="] {
            XCTAssertFalse(worked?.text.contains(symbol) == true,
                           "must not state the verdict: \(worked?.text ?? "")")
        }
    }

    func testFoxHenEvidenceSelectsVerifiedSentence() {
        let passage = "The large fox chased a red hen. The fox was red."
        let proposal = ProposedProblem(skill: .readingComprehension, form: .story,
                                       passage: passage, candidateAnswer: "red",
                                       promptText: "Read: \(passage) What color was the large fox?")
        XCTAssertEqual(solver.solve(proposal), .verified(verifiedAnswer: "red"))
        let ladder = makeLadder(proposal, questionId: "q-foxhen")
        _ = ladder.requestHint(); _ = ladder.requestHint()
        let worked = ladder.requestHint()
        XCTAssertEqual(worked?.level, .workedStep)
        // Overlap picks the first sentence (large+fox) and blanks the hen;
        // the verified relationship (fox was red) is the second sentence.
        XCTAssertTrue(worked?.text.contains("The fox was ___") == true,
                      "must quote the fox sentence with the answer blanked: \(worked?.text ?? "")")
        XCTAssertFalse(worked?.text.contains("hen") == true,
                       "must not quote the hen sentence: \(worked?.text ?? "")")
    }
}
