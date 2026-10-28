import XCTest
@testable import EarnPlayCore

final class DiagnosticTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    private func makeSession(bank: [DiagnosticBankItem] = DiagnosticBank.grade4,
                             budget: Int = 600) -> DiagnosticSession {
        DiagnosticSession(sessionId: "diag-test", solver: SolverService(), bank: bank,
                          timeBudgetSeconds: budget, now: { self.clock })
    }

    /// Answers every item correctly by reading the solver-verified answer.
    private func answerAllCorrectly(_ s: DiagnosticSession, ms: Int = 2_000) {
        var guardCount = 0
        while let item = s.currentItem, guardCount < 100 {
            XCTAssertTrue(s.submit(answer: item.question.verifiedAnswer, responseMs: ms))
            guardCount += 1
        }
    }

    func testFullCorrectRunCompletesWithProficientProfile() {
        let s = makeSession()
        s.start()
        answerAllCorrectly(s)
        XCTAssertEqual(s.state, .completed)
        let profile = s.profile()
        XCTAssertTrue(profile.isComplete)
        XCTAssertEqual(profile.grade, "4")
        XCTAssertEqual(profile.estimates.count, 5)
        for area in DiagnosticArea.allCases {
            XCTAssertEqual(profile.estimate(for: area).level, .proficient, "\(area)")
            XCTAssertEqual(profile.estimate(for: area).accuracy, 1.0, "\(area)")
        }
        XCTAssertNotNil(profile.nextFocusArea)
    }

    func testAllWrongRunYieldsEmergingAndDifficultyStepsDown() {
        let s = makeSession()
        s.start()
        var guardCount = 0
        while let item = s.currentItem, guardCount < 100 {
            _ = item
            XCTAssertFalse(s.submit(answer: "definitely-wrong", responseMs: 3_000))
            guardCount += 1
        }
        XCTAssertEqual(s.state, .completed)
        let profile = s.profile()
        for area in DiagnosticArea.allCases {
            XCTAssertEqual(profile.estimate(for: area).level, .emerging, "\(area)")
            XCTAssertEqual(profile.recommendedDifficulty(for: area), 1, "\(area)")
        }
    }

    func testSlowAccurateFluencyIsDevelopingNotProficient() {
        let s = makeSession()
        s.start()
        answerAllCorrectly(s, ms: 20_000)
        let profile = s.profile()
        XCTAssertEqual(profile.estimate(for: .factsFluency).level, .developing)
        XCTAssertEqual(profile.estimate(for: .readingFluency).level, .developing)
        // Non-fluency areas are not latency-penalised.
        XCTAssertEqual(profile.estimate(for: .fractions).level, .proficient)
    }

    func testEmptySessionProfileIsAllNotAssessed() {
        let s = makeSession()
        let profile = s.profile()
        XCTAssertFalse(profile.isComplete)
        XCTAssertNil(profile.nextFocusArea)
        for area in DiagnosticArea.allCases {
            XCTAssertEqual(profile.estimate(for: area).level, .notAssessed)
            XCTAssertEqual(profile.estimate(for: area).itemsAttempted, 0)
        }
    }

    func testPartialCompletionAfterAbandonKeepsAssessedAreas() {
        let s = makeSession()
        s.start()
        // Answer only the first item, then abandon.
        let first = try! XCTUnwrap(s.currentItem)
        _ = s.submit(answer: first.question.verifiedAnswer, responseMs: 1_500)
        s.abandon()
        XCTAssertEqual(s.state, .abandoned)
        let profile = s.profile()
        XCTAssertFalse(profile.isComplete)
        let assessed = profile.estimates.filter { $0.level != .notAssessed }
        XCTAssertEqual(assessed.count, 1)
        XCTAssertEqual(assessed.first?.itemsAttempted, 1)
    }

    func testTimeBudgetCutEndsSessionWithPartialProfile() {
        let s = makeSession(budget: 60)
        s.start()
        let first = try! XCTUnwrap(s.currentItem)
        _ = s.submit(answer: first.question.verifiedAnswer, responseMs: 1_000)
        clock = clock.addingTimeInterval(61)
        // Next advance happens on submit; force by answering current item.
        if let item = s.currentItem {
            _ = s.submit(answer: item.question.verifiedAnswer, responseMs: 1_000)
        }
        XCTAssertEqual(s.state, .completed)
        XCTAssertFalse(s.profile().isComplete)
    }

    func testUnverifiableBankItemsAreNeverPresented() {
        // 13x3 is outside the solver's 12x12 facts range: must be dropped.
        let bad = DiagnosticBankItem(area: .factsFluency, problem: ProposedProblem(
            skill: .multiplicationFacts, operands: [13, 3], promptText: "13 × 3 = ?", difficulty: 1))
        let s = makeSession(bank: [bad] + DiagnosticBank.grade4)
        s.start()
        var seen = 0
        while let item = s.currentItem, seen < 100 {
            XCTAssertNotEqual(item.question.promptText, "13 × 3 = ?")
            _ = s.submit(answer: item.question.verifiedAnswer, responseMs: 1_000)
            seen += 1
        }
        XCTAssertGreaterThan(seen, 0)
    }

    func testEveryBankItemPassesSolverVerification() {
        let solver = SolverService()
        for item in DiagnosticBank.grade4 {
            guard case .success = solver.verify(item.problem, questionId: "check") else {
                return XCTFail("bank item failed verification: \(item.problem.promptText)")
            }
        }
    }

    func testProfilePersistenceRoundTrip() throws {
        let s = makeSession()
        s.start()
        answerAllCorrectly(s)
        let profile = s.profile()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-test-\(UUID().uuidString)/profile.json")
        let store = FileSkillProfileStore(fileURL: url)
        XCTAssertNil(try store.load())
        try store.save(profile)
        let loaded = try store.load()
        XCTAssertEqual(loaded, profile)
        // Tutor read-back: difficulty + focus survive persistence.
        XCTAssertEqual(loaded?.recommendedDifficulty(for: .fractions),
                       profile.recommendedDifficulty(for: .fractions))
        XCTAssertEqual(loaded?.nextFocusArea, profile.nextFocusArea)
    }

    // MARK: - Copilot round-1 regression tests

    func testNextFocusAreaRanksByLevelBeforeAccuracy() {
        // Copilot F1 scenario: all accuracies 1, facts fast/proficient,
        // reading fluency slow/developing -> focus must be reading fluency.
        func est(_ area: DiagnosticArea, _ level: DiagnosticLevel, _ ms: Int) -> SkillEstimate {
            SkillEstimate(area: area, level: level, accuracy: 1.0,
                          itemsAttempted: 3, itemsCorrect: 3, medianResponseMs: ms,
                          recommendedDifficulty: 2)
        }
        let profile = SkillProfile(
            grade: "4",
            estimates: [
                est(.factsFluency, .proficient, 2_000),
                est(.fractions, .proficient, 2_000),
                est(.wordProblems, .proficient, 2_000),
                est(.readingFluency, .developing, 20_000),
                est(.comprehension, .proficient, 2_000),
            ],
            diagnosticSessionId: "diag-focus", completedAt: clock, isComplete: true)
        XCTAssertEqual(profile.nextFocusArea, .readingFluency)
        // Accuracy still breaks ties within the same level.
        let tie = SkillProfile(
            grade: "4",
            estimates: [
                SkillEstimate(area: .factsFluency, level: .developing, accuracy: 0.9,
                              itemsAttempted: 10, itemsCorrect: 9, medianResponseMs: 2_000),
                SkillEstimate(area: .fractions, level: .developing, accuracy: 0.6,
                              itemsAttempted: 10, itemsCorrect: 6, medianResponseMs: 2_000),
            ],
            diagnosticSessionId: "diag-focus-tie", completedAt: clock, isComplete: false)
        XCTAssertEqual(tie.nextFocusArea, .fractions)
    }

    func testExpiredSubmitIsRejectedAndDoesNotTouchProfile() {
        let s = makeSession(budget: 60)
        s.start()
        let first = try! XCTUnwrap(s.currentItem)
        XCTAssertTrue(s.submit(answer: first.question.verifiedAnswer, responseMs: 1_000))
        let responsesBefore = s.responses.count
        let attemptedBefore = s.profile().estimates.map(\.itemsAttempted)
        clock = clock.addingTimeInterval(61)
        let pending = try! XCTUnwrap(s.currentItem)
        XCTAssertFalse(s.submit(answer: pending.question.verifiedAnswer, responseMs: 1_000))
        XCTAssertEqual(s.responses.count, responsesBefore)
        XCTAssertEqual(s.profile().estimates.map(\.itemsAttempted), attemptedBefore)
        XCTAssertEqual(s.state, .completed)
        XCTAssertNil(s.currentItem)
    }

    func testExpireIfNeededCompletesWithoutAnswering() {
        let s = makeSession(budget: 60)
        s.start()
        let first = try! XCTUnwrap(s.currentItem)
        XCTAssertTrue(s.submit(answer: first.question.verifiedAnswer, responseMs: 1_000))
        let responsesBefore = s.responses.count
        clock = clock.addingTimeInterval(61)
        XCTAssertTrue(s.expireIfNeeded())
        XCTAssertEqual(s.state, .completed)
        XCTAssertNil(s.currentItem)
        XCTAssertEqual(s.responses.count, responsesBefore)
        // Not expired / already finished: no-op.
        XCTAssertFalse(s.expireIfNeeded())
    }

    func testAdvanceRoundRobinsAcrossAreas() {
        let s = makeSession()
        s.start()
        var areas: [DiagnosticArea] = []
        var guardCount = 0
        while let item = s.currentItem, guardCount < 100 {
            areas.append(item.area)
            XCTAssertTrue(s.submit(answer: item.question.verifiedAnswer, responseMs: 1_000))
            guardCount += 1
        }
        XCTAssertEqual(s.state, .completed)
        // Each eligible area gets a turn before any area repeats.
        XCTAssertEqual(Array(areas.prefix(DiagnosticArea.allCases.count)), DiagnosticArea.allCases)
        XCTAssertEqual(Set(areas.prefix(DiagnosticArea.allCases.count)).count, DiagnosticArea.allCases.count)
    }

    func testBudgetCutAfterRoundRobinStillAssessesEveryArea() {
        let s = makeSession(budget: 60)
        s.start()
        // One full round-robin cycle: one item per area.
        for _ in 0..<DiagnosticArea.allCases.count {
            let item = try! XCTUnwrap(s.currentItem)
            XCTAssertTrue(s.submit(answer: item.question.verifiedAnswer, responseMs: 1_000))
        }
        clock = clock.addingTimeInterval(61)
        if let item = s.currentItem {
            _ = s.submit(answer: item.question.verifiedAnswer, responseMs: 1_000)
        }
        XCTAssertEqual(s.state, .completed)
        let profile = s.profile()
        for area in DiagnosticArea.allCases {
            XCTAssertGreaterThanOrEqual(profile.estimate(for: area).itemsAttempted, 1, "\(area)")
        }
    }

    func testEvenSizedMedianAveragesTwoMiddleValues() {
        // Copilot F4 values: 2,2,2,10,10,10 s -> median 6 s, level stays proficient.
        let factsBank = DiagnosticBank.grade4.filter { $0.area == .factsFluency }
        XCTAssertEqual(factsBank.count, 6)
        let quotas: [DiagnosticArea: Int] = [
            .factsFluency: 6, .fractions: 0, .wordProblems: 0,
            .readingFluency: 0, .comprehension: 0,
        ]
        let s = DiagnosticSession(sessionId: "diag-median", solver: SolverService(),
                                  bank: factsBank, timeBudgetSeconds: 600,
                                  itemsPerArea: quotas, now: { self.clock })
        s.start()
        for ms in [2_000, 2_000, 2_000, 10_000, 10_000, 10_000] {
            let item = try! XCTUnwrap(s.currentItem)
            XCTAssertTrue(s.submit(answer: item.question.verifiedAnswer, responseMs: ms))
        }
        XCTAssertEqual(s.state, .completed)
        let estimate = s.profile().estimate(for: .factsFluency)
        XCTAssertEqual(estimate.medianResponseMs, 6_000)
        XCTAssertEqual(estimate.level, .proficient)
    }

    func testProfileNotCompleteWhenQuotasUnmetDespiteEveryAreaAssessed() {
        // One item per area (bank reduced, e.g. by solver rejections):
        // every area assessed, but default quotas (6/5/4/3/4) unmet.
        var bank: [DiagnosticBankItem] = []
        for area in DiagnosticArea.allCases {
            if let first = DiagnosticBank.grade4.first(where: { $0.area == area }) {
                bank.append(first)
            }
        }
        XCTAssertEqual(bank.count, DiagnosticArea.allCases.count)
        let s = makeSession(bank: bank)
        s.start()
        answerAllCorrectly(s)
        XCTAssertEqual(s.state, .completed)
        let profile = s.profile()
        for area in DiagnosticArea.allCases {
            XCTAssertEqual(profile.estimate(for: area).itemsAttempted, 1, "\(area)")
        }
        XCTAssertFalse(profile.isComplete)
    }

    func testProfileCompleteWhenQuotasMet() {
        let s = makeSession()
        s.start()
        answerAllCorrectly(s)
        XCTAssertEqual(s.state, .completed)
        let profile = s.profile()
        for area in DiagnosticArea.allCases {
            XCTAssertEqual(profile.estimate(for: area).itemsAttempted,
                           DiagnosticSession.defaultItemsPerArea[area], "\(area)")
        }
        XCTAssertTrue(profile.isComplete)
    }

    func testCorruptProfileFileThrowsOnLoad() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-bad-\(UUID().uuidString)/profile.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try FileSkillProfileStore(fileURL: url).load())
    }
}
