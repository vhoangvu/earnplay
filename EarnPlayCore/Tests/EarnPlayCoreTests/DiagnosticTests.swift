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

    func testCorruptProfileFileThrowsOnLoad() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-bad-\(UUID().uuidString)/profile.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try FileSkillProfileStore(fileURL: url).load())
    }
}
