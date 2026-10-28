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
            XCTAssertTrue(s.submit(answer: item.question.verifiedAnswer, responseMs: ms, questionId: item.question.questionId))
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
            XCTAssertFalse(s.submit(answer: "definitely-wrong", responseMs: 3_000, questionId: item.question.questionId))
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
        _ = s.submit(answer: first.question.verifiedAnswer, responseMs: 1_500, questionId: first.question.questionId)
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
        _ = s.submit(answer: first.question.verifiedAnswer, responseMs: 1_000, questionId: first.question.questionId)
        clock = clock.addingTimeInterval(61)
        // Next advance happens on submit; force by answering current item.
        if let item = s.currentItem {
            _ = s.submit(answer: item.question.verifiedAnswer, responseMs: 1_000, questionId: item.question.questionId)
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
            _ = s.submit(answer: item.question.verifiedAnswer, responseMs: 1_000, questionId: item.question.questionId)
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
        XCTAssertTrue(s.submit(answer: first.question.verifiedAnswer, responseMs: 1_000, questionId: first.question.questionId))
        let responsesBefore = s.responses.count
        let attemptedBefore = s.profile().estimates.map(\.itemsAttempted)
        clock = clock.addingTimeInterval(61)
        let pending = try! XCTUnwrap(s.currentItem)
        XCTAssertFalse(s.submit(answer: pending.question.verifiedAnswer, responseMs: 1_000, questionId: pending.question.questionId))
        XCTAssertEqual(s.responses.count, responsesBefore)
        XCTAssertEqual(s.profile().estimates.map(\.itemsAttempted), attemptedBefore)
        XCTAssertEqual(s.state, .completed)
        XCTAssertNil(s.currentItem)
    }

    func testExpireIfNeededCompletesWithoutAnswering() {
        let s = makeSession(budget: 60)
        s.start()
        let first = try! XCTUnwrap(s.currentItem)
        XCTAssertTrue(s.submit(answer: first.question.verifiedAnswer, responseMs: 1_000, questionId: first.question.questionId))
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
            XCTAssertTrue(s.submit(answer: item.question.verifiedAnswer, responseMs: 1_000, questionId: item.question.questionId))
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
            XCTAssertTrue(s.submit(answer: item.question.verifiedAnswer, responseMs: 1_000, questionId: item.question.questionId))
        }
        clock = clock.addingTimeInterval(61)
        if let item = s.currentItem {
            _ = s.submit(answer: item.question.verifiedAnswer, responseMs: 1_000, questionId: item.question.questionId)
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
            XCTAssertTrue(s.submit(answer: item.question.verifiedAnswer, responseMs: ms, questionId: item.question.questionId))
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

    // MARK: - Copilot round-2 regression tests

    /// Thread-safe clock for concurrency tests.
    private final class Round2Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ date: Date) { self.date = date }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
        func advance(_ seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }; date = date.addingTimeInterval(seconds)
        }
    }

    /// Runs a session containing only the bank item whose prompt
    /// contains `needle`, and submits `answer` to it.
    private func submitSingleItem(promptContaining needle: String, answer: String) -> Bool {
        let bankItem = try! XCTUnwrap(
            DiagnosticBank.grade4.first { $0.problem.promptText.contains(needle) },
            "no bank item containing \(needle)")
        var quotas = Dictionary(uniqueKeysWithValues: DiagnosticArea.allCases.map { ($0, 0) })
        quotas[bankItem.area] = 1
        let s = DiagnosticSession(sessionId: "diag-r2-single", solver: SolverService(),
                                  bank: [bankItem], timeBudgetSeconds: 600,
                                  itemsPerArea: quotas, now: { self.clock })
        s.start()
        let presented = try! XCTUnwrap(s.currentItem)
        return s.submit(answer: answer, responseMs: 1_000, questionId: presented.question.questionId)
    }

    private func bankItem(promptContaining needle: String) -> DiagnosticBankItem {
        try! XCTUnwrap(DiagnosticBank.grade4.first { $0.problem.promptText.contains(needle) })
    }

    func testPassageBFluencyItemAsksBeforeMoveAndVerifies48() {
        let item = bankItem(promptContaining: "top shelf")
        // Unambiguous wording: explicitly asks about BEFORE the move.
        XCTAssertTrue(item.problem.promptText.lowercased().contains("before"),
                      "prompt must ask before the move: \(item.problem.promptText)")
        let solver = SolverService()
        guard case .success(let q) = solver.verify(item.problem, questionId: "r2-f2") else {
            return XCTFail("reworded item must verify")
        }
        XCTAssertEqual(q.verifiedAnswer, "48")
        XCTAssertTrue(submitSingleItem(promptContaining: "top shelf", answer: "48"))
        XCTAssertFalse(submitSingleItem(promptContaining: "top shelf", answer: "32"))
    }

    func testComprehensionWhenItemAcceptsPassagePhrasings() {
        for phrasing in ["every morning", "before school", "every morning before school"] {
            XCTAssertTrue(submitSingleItem(promptContaining: "When did Mia water", answer: phrasing),
                          "should accept: \(phrasing)")
        }
        XCTAssertFalse(submitSingleItem(promptContaining: "When did Mia water", answer: "every evening"))
        XCTAssertFalse(submitSingleItem(promptContaining: "When did Mia water", answer: "after dinner"))
    }

    func testComprehensionWhereItemAcceptsAReadingCorner() {
        for phrasing in ["reading corner", "a reading corner"] {
            XCTAssertTrue(submitSingleItem(promptContaining: "Where did Mr. Lee move", answer: phrasing),
                          "should accept: \(phrasing)")
        }
        XCTAssertFalse(submitSingleItem(promptContaining: "Where did Mr. Lee move", answer: "the garden"))
        XCTAssertFalse(submitSingleItem(promptContaining: "Where did Mr. Lee move", answer: "the top shelf"))
    }

    func testConcurrentSubmitsRecordEachItemAtMostOnce() {
        for _ in 0..<10 {
            let s = makeSession()
            s.start()
            DispatchQueue.concurrentPerform(iterations: 100) { _ in
                if let item = s.currentItem {
                    _ = s.submit(answer: item.question.verifiedAnswer, responseMs: 1_000, questionId: item.question.questionId)
                }
            }
            let ids = s.responses.map(\.questionId)
            XCTAssertEqual(ids.count, Set(ids).count, "duplicate recorded items: \(ids)")
        }
    }

    func testConcurrentSubmitAndExpireCannotDoubleRecord() {
        let box = Round2Clock(Date(timeIntervalSince1970: 2_000_000))
        let s = DiagnosticSession(sessionId: "diag-r2-race", solver: SolverService(),
                                  bank: DiagnosticBank.grade4, timeBudgetSeconds: 60,
                                  now: { box.now() })
        s.start()
        let first = try! XCTUnwrap(s.currentItem)
        XCTAssertTrue(s.submit(answer: first.question.verifiedAnswer, responseMs: 1_000, questionId: first.question.questionId))
        box.advance(61)
        DispatchQueue.concurrentPerform(iterations: 100) { i in
            if i % 2 == 0 {
                if let item = s.currentItem {
                    _ = s.submit(answer: item.question.verifiedAnswer, responseMs: 1_000, questionId: item.question.questionId)
                }
            } else {
                _ = s.expireIfNeeded()
            }
        }
        XCTAssertEqual(s.state, .completed)
        let ids = s.responses.map(\.questionId)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate recorded items: \(ids)")
        // Expiry already completed the session: no late recording.
        XCTAssertFalse(s.submit(answer: "48", responseMs: 1_000, questionId: first.question.questionId))
        XCTAssertEqual(s.responses.map(\.questionId), ids)
    }

    func testPairedAllCorrectVsFractionsOnlyWrong() {
        let allCorrect = makeSession()
        allCorrect.start()
        answerAllCorrectly(allCorrect)
        let correctProfile = allCorrect.profile()

        let fractionsWrong = DiagnosticSession(
            sessionId: "diag-r2-fractions", solver: SolverService(),
            bank: DiagnosticBank.grade4, timeBudgetSeconds: 600, now: { self.clock })
        fractionsWrong.start()
        var guardCount = 0
        while let item = fractionsWrong.currentItem, guardCount < 100 {
            if item.area == .fractions {
                XCTAssertFalse(fractionsWrong.submit(answer: "definitely-wrong", responseMs: 2_000, questionId: item.question.questionId))
            } else {
                XCTAssertTrue(fractionsWrong.submit(answer: item.question.verifiedAnswer, responseMs: 2_000, questionId: item.question.questionId))
            }
            guardCount += 1
        }
        let wrongProfile = fractionsWrong.profile()

        // Exact per-area levels: all-correct run.
        for area in DiagnosticArea.allCases {
            XCTAssertEqual(correctProfile.estimate(for: area).level, .proficient, "all-correct \(area)")
            XCTAssertEqual(correctProfile.estimate(for: area).accuracy, 1.0, "all-correct \(area)")
        }
        // Exact per-area levels: fractions-only-wrong run.
        XCTAssertEqual(wrongProfile.estimate(for: .fractions).level, .emerging)
        XCTAssertEqual(wrongProfile.estimate(for: .fractions).accuracy, 0.0)
        XCTAssertEqual(wrongProfile.estimate(for: .fractions).itemsCorrect, 0)
        XCTAssertGreaterThan(wrongProfile.estimate(for: .fractions).itemsAttempted, 0)
        for area in DiagnosticArea.allCases where area != .fractions {
            XCTAssertEqual(wrongProfile.estimate(for: area).level, .proficient, "fractions-wrong \(area)")
            XCTAssertEqual(wrongProfile.estimate(for: area).accuracy, 1.0, "fractions-wrong \(area)")
        }
        XCTAssertEqual(wrongProfile.nextFocusArea, .fractions)
    }

    func testPersistenceSecondProfileFullyReplacesFirst() throws {
        // First profile: all-correct.
        let firstSession = DiagnosticSession(
            sessionId: "diag-r2-first", solver: SolverService(),
            bank: DiagnosticBank.grade4, timeBudgetSeconds: 600, now: { self.clock })
        firstSession.start()
        answerAllCorrectly(firstSession)
        let firstProfile = firstSession.profile()

        // Second profile: fractions-only-wrong, distinct session id.
        let secondSession = DiagnosticSession(
            sessionId: "diag-r2-second", solver: SolverService(),
            bank: DiagnosticBank.grade4, timeBudgetSeconds: 600, now: { self.clock })
        secondSession.start()
        var guardCount = 0
        while let item = secondSession.currentItem, guardCount < 100 {
            _ = secondSession.submit(
                answer: item.area == .fractions ? "definitely-wrong" : item.question.verifiedAnswer,
                responseMs: 2_000, questionId: item.question.questionId)
            guardCount += 1
        }
        let secondProfile = secondSession.profile()
        XCTAssertNotEqual(firstProfile, secondProfile)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-r2-\(UUID().uuidString)/profile.json")
        let store = FileSkillProfileStore(fileURL: url)
        try store.save(firstProfile)
        XCTAssertEqual(try store.load(), firstProfile)
        try store.save(secondProfile)
        let loaded = try store.load()
        XCTAssertEqual(loaded, secondProfile)
        XCTAssertEqual(loaded?.diagnosticSessionId, "diag-r2-second")
        XCTAssertEqual(loaded?.estimate(for: .fractions).level, .emerging)
        XCTAssertNotEqual(loaded?.estimate(for: .fractions).level,
                          firstProfile.estimate(for: .fractions).level)
    }

    // MARK: - Copilot round-3 regression tests

    func testMathItemAlternateAnswerDoesNotBypassSolver() {
        // 3 x 4 with acceptableAnswers ["99"]: 99 must be marked wrong;
        // math grading goes through the solver, never unverified alternates.
        let item = DiagnosticBankItem(
            area: .factsFluency,
            problem: ProposedProblem(skill: .multiplicationFacts, operands: [3, 4],
                                     promptText: "3 × 4 = ?", difficulty: 1),
            acceptableAnswers: ["99"])
        var quotas = Dictionary(uniqueKeysWithValues: DiagnosticArea.allCases.map { ($0, 0) })
        quotas[.factsFluency] = 1
        func freshSession() -> DiagnosticSession {
            DiagnosticSession(sessionId: "diag-r3-math", solver: SolverService(),
                              bank: [item], timeBudgetSeconds: 600,
                              itemsPerArea: quotas, now: { self.clock })
        }
        let wrong = freshSession()
        wrong.start()
        XCTAssertNotNil(wrong.currentItem)
        XCTAssertFalse(wrong.submit(answer: "99", responseMs: 1_000, questionId: wrong.currentItem?.question.questionId ?? ""),
                       "unverified alternate 99 must not be accepted for 3 x 4")
        XCTAssertEqual(wrong.responses.first?.correct, false)
        let correct = freshSession()
        correct.start()
        XCTAssertTrue(correct.submit(answer: "12", responseMs: 1_000, questionId: correct.currentItem?.question.questionId ?? ""))
        XCTAssertEqual(correct.responses.first?.correct, true)
    }

    func testReadingComprehensionAlternateStillAcceptedRound3() {
        // Legitimate passage-supported alternate must still be accepted.
        XCTAssertTrue(submitSingleItem(promptContaining: "When did Mia water", answer: "before school"))
        XCTAssertTrue(submitSingleItem(promptContaining: "Where did Mr. Lee move", answer: "a reading corner"))
    }

    func testStaleSubmissionIsRejectedWithoutGradingOrAdvancing() {
        let s = makeSession()
        s.start()
        // Two callers read the same presented item.
        let presented = try! XCTUnwrap(s.currentItem)
        let callerAItem = presented
        let callerBItem = presented
        XCTAssertEqual(callerAItem.question.questionId, callerBItem.question.questionId)
        // First caller submits and advances the session.
        XCTAssertTrue(s.submit(answer: callerAItem.question.verifiedAnswer, responseMs: 1_000, questionId: callerAItem.question.questionId))
        let nextItem = try! XCTUnwrap(s.currentItem)
        XCTAssertNotEqual(nextItem.question.questionId, presented.question.questionId)
        let responsesBefore = s.responses
        let attemptedBefore = s.profile().estimates.map(\.itemsAttempted)
        // Second caller submits its stale answer for the first item.
        XCTAssertFalse(s.submit(answer: callerBItem.question.verifiedAnswer, responseMs: 1_000, questionId: callerBItem.question.questionId))
        XCTAssertEqual(s.responses, responsesBefore, "stale submission must not be graded/recorded")
        XCTAssertEqual(s.profile().estimates.map(\.itemsAttempted), attemptedBefore)
        XCTAssertEqual(s.currentItem?.question.questionId, nextItem.question.questionId,
                       "stale submission must not advance the session")
    }

    func testCorruptProfileFileThrowsOnLoad() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-bad-\(UUID().uuidString)/profile.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try FileSkillProfileStore(fileURL: url).load())
    }

    // MARK: - Copilot round-4 regression tests

    func testProfilePersistencePreservesFractionalSeconds() throws {
        // Millisecond-aligned fractional date: ISO8601 fractional
        // formatting preserves it exactly, whole-second does not.
        let profile = SkillProfile(
            grade: "4",
            estimates: [SkillEstimate(area: .fractions, level: .proficient, accuracy: 1.0,
                                      itemsAttempted: 5, itemsCorrect: 5,
                                      medianResponseMs: 2_000, recommendedDifficulty: 2)],
            diagnosticSessionId: "diag-r4-fractional",
            completedAt: Date(timeIntervalSince1970: 1_700_000_000.123),
            isComplete: true)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-r4-\(UUID().uuidString)/profile.json")
        let store = FileSkillProfileStore(fileURL: url)
        try store.save(profile)
        let loaded = try store.load()
        XCTAssertEqual(loaded?.completedAt, profile.completedAt)
        XCTAssertEqual(loaded, profile)
    }

    func testProfilePersistenceDecodesLegacyWholeSecondISO8601() throws {
        // Profiles persisted before the fractional-second fix carry a
        // whole-second ISO8601 completedAt; they must still decode.
        let legacyJSON = """
        {"completedAt":"2023-11-14T22:13:20Z","diagnosticSessionId":"diag-r4-legacy","estimates":[{"accuracy":1,"area":"fractions","itemsAttempted":5,"itemsCorrect":5,"level":"proficient","medianResponseMs":2000,"recommendedDifficulty":2}],"grade":"4","isComplete":true}
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-r4-legacy-\(UUID().uuidString)/profile.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(legacyJSON.utf8).write(to: url)
        let loaded = try FileSkillProfileStore(fileURL: url).load()
        let expected = SkillProfile(
            grade: "4",
            estimates: [SkillEstimate(area: .fractions, level: .proficient, accuracy: 1.0,
                                      itemsAttempted: 5, itemsCorrect: 5,
                                      medianResponseMs: 2_000, recommendedDifficulty: 2)],
            diagnosticSessionId: "diag-r4-legacy",
            completedAt: Date(timeIntervalSince1970: 1_700_000_000),
            isComplete: true)
        XCTAssertEqual(loaded?.completedAt, expected.completedAt)
        XCTAssertEqual(loaded, expected)
    }
}
