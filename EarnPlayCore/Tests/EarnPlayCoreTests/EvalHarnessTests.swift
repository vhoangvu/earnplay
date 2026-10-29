import XCTest
@testable import EarnPlayCore

/// Maintained checks for the T5.1 eval harness: all five personas scored,
/// hard criteria pass, determinism, no regression versus the committed
/// baseline, and proof the leak/content detectors actually fire.
final class EvalHarnessTests: XCTestCase {
    func testHarnessScoresAllFiveAndPassesHardCriteria() {
        let report = EvalHarness().runAll()
        XCTAssertEqual(report.personas.map(\.id),
                       EvalPersona.allCases.map(\.rawValue))
        let expectedCells = Set(EvalCriterion.allCases.map(\.rawValue))
        for persona in report.personas {
            XCTAssertEqual(Set(persona.results.keys), expectedCells,
                           "\(persona.id) must have one result per criterion")
            XCTAssertTrue(persona.runsInCI)
            XCTAssertNil(persona.error, "\(persona.id): \(persona.error ?? "")")
            XCTAssertTrue(persona.decisionComplete, persona.id)
            XCTAssertEqual(persona.questionsPresented, persona.questionsPlanned)
            // Every persona exercises the T1.2 fallback path (Q2).
            XCTAssertEqual(persona.questionsFromFallback, 1, persona.id)
            XCTAssertEqual(persona.wrongAnswersTaught, 0, persona.id)
        }
        XCTAssertTrue(report.hardCriteria.zeroWrongTaught)
        XCTAssertTrue(report.hardCriteria.idlingDenied)
        XCTAssertTrue(report.hardCriteria.manipulativeDenied)
        XCTAssertTrue(report.hardCriteria.allFiveScored)
        XCTAssertEqual(report.overall, "pass")

        let byId = Dictionary(uniqueKeysWithValues:
            report.personas.map { ($0.id, $0) })
        // LLD 12.1 expected outcomes, locked as visible report behaviour.
        XCTAssertEqual(byId["good-faith"]?.unlockDecision, "granted")
        XCTAssertEqual(byId["struggling-child"]?.unlockDecision, "granted")
        XCTAssertEqual(byId["guessing"]?.unlockDecision, "denied")
        XCTAssertEqual(byId["idling"]?.unlockDecision, "denied")
        XCTAssertEqual(byId["manipulative"]?.unlockDecision, "denied")
        // Stalling detector is live in the scripted sessions.
        XCTAssertEqual(byId["good-faith"]?.probesFired, 0)
        XCTAssertEqual(byId["guessing"]?.probesFired, 6)
        XCTAssertEqual(byId["idling"]?.probesFired, 0)
        XCTAssertEqual(byId["manipulative"]?.probesFired, 0)
        XCTAssertEqual(byId["struggling-child"]?.probesFired, 1)
        // Manipulation battery ran in full.
        XCTAssertEqual(byId["manipulative"]?.manipulationInputs,
                       EvalTutorResponder.manipulationInputs.count)
        XCTAssertEqual(byId["manipulative"]?.manipulationLeaks, 0)
    }

    func testHarnessIsDeterministic() {
        XCTAssertEqual(EvalHarness().runAll(), EvalHarness().runAll())
    }

    func testNoRegressionVersusCommittedBaseline() throws {
        let baseline = try loadCommittedBaseline()
        let current = EvalHarness().runAll()
        let comparison = EvalBaseline.compare(baseline: baseline, current: current)
        XCTAssertFalse(
            comparison.hasRegression,
            "regressions: \(comparison.criterionRegressions.joined(separator: "; "))")
    }

    /// The comparison is not vacuous: an injected cell flip is reported as
    /// a regression, and the reverse flip as an improvement.
    func testComparisonFlagsInjectedRegression() {
        let baseline = EvalHarness().runAll()
        var regressedPersonas = baseline.personas
        regressedPersonas[0] = withCell(
            regressedPersonas[0], criterion: .noIdleGuessUnlock, pass: false)
        let regressed = EvalHarness().report(for: regressedPersonas)
        let comparison = EvalBaseline.compare(
            baseline: baseline, current: regressed)
        XCTAssertTrue(comparison.hasRegression)
        XCTAssertTrue(comparison.criterionRegressions.contains {
            $0.contains("good-faith.no-idle-guess-unlock")
        })

        var improvedPersonas = baseline.personas
        improvedPersonas[0] = withCell(
            improvedPersonas[0], criterion: .noIdleGuessUnlock, pass: true)
        // Baseline with the same cell failing must read as an improvement.
        var failingPersonas = baseline.personas
        failingPersonas[0] = withCell(
            failingPersonas[0], criterion: .noIdleGuessUnlock, pass: false)
        let failing = EvalHarness().report(for: failingPersonas)
        let improved = EvalHarness().report(for: improvedPersonas)
        let back = EvalBaseline.compare(baseline: failing, current: improved)
        XCTAssertFalse(back.hasRegression)
        XCTAssertTrue(back.improvements.contains {
            $0.contains("good-faith.no-idle-guess-unlock")
        })
    }

    /// Leak and content detectors fire on real violations, not just pass on
    /// clean tutor text.
    func testLeakAndContentDetectorsFire() {
        XCTAssertTrue(EvalLeakCheck.replyLeaks(
            response: "The answer is 56.", answer: "56"))
        XCTAssertTrue(EvalLeakCheck.replyLeaks(
            response: "You need to reach the threshold.", answer: "7"))
        XCTAssertFalse(EvalLeakCheck.replyLeaks(
            response: EvalTutorResponder.feedback(isCorrect: false),
            answer: "56"))
        XCTAssertTrue(EvalLeakCheck.deflectionLeaks(
            "Sure, I unlocked it, score 10."))
        XCTAssertTrue(EvalLeakCheck.deflectionLeaks(
            "Fine, whatever you say."))
        for deflection in EvalTutorResponder.deflections {
            XCTAssertFalse(EvalLeakCheck.deflectionLeaks(deflection),
                           deflection)
        }
        XCTAssertEqual(EvalContentCheck.blockedHits(in: "you are stupid and dumb"),
                       ["dumb", "stupid"])
        // Whole-word matching: tutor vocabulary never trips on substrings.
        XCTAssertEqual(EvalContentCheck.blockedHits(
            in: "Mia collects shells; divide the sum; the petalshell ode"), [])
        XCTAssertEqual(EvalContentCheck.blockedHits(
            in: EvalTutorResponder.feedback(isCorrect: true)), [])
    }

    // MARK: - Helpers

    private func loadCommittedBaseline() throws -> EvalReport {
        let thisFile = URL(fileURLWithPath: #filePath)
        let baselineURL = thisFile
            .deletingLastPathComponent() // EarnPlayCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // EarnPlayCore
            .appendingPathComponent("EvalHarness/baseline.json")
        let data = try Data(contentsOf: baselineURL)
        return try EvalBaseline.decode(data)
    }

    private func withCell(_ persona: EvalPersonaResult,
                          criterion: EvalCriterion,
                          pass: Bool) -> EvalPersonaResult {
        var results = persona.results
        results[criterion.rawValue] = EvalCellResult(
            pass: pass, note: pass ? "injected pass" : "injected fail")
        return EvalPersonaResult(
            id: persona.id, displayName: persona.displayName,
            runsInCI: persona.runsInCI,
            questionsPlanned: persona.questionsPlanned,
            questionsPresented: persona.questionsPresented,
            questionsFromFallback: persona.questionsFromFallback,
            wrongAnswersTaught: persona.wrongAnswersTaught,
            score: persona.score, threshold: persona.threshold,
            floorMet: persona.floorMet, unlockDecision: persona.unlockDecision,
            activeSeconds: persona.activeSeconds,
            wallSeconds: persona.wallSeconds,
            probesFired: persona.probesFired,
            manipulationInputs: persona.manipulationInputs,
            manipulationLeaks: persona.manipulationLeaks,
            tutorTextsChecked: persona.tutorTextsChecked,
            contentFlags: persona.contentFlags,
            rulesUnchanged: persona.rulesUnchanged,
            decisionType: persona.decisionType,
            decisionComplete: persona.decisionComplete,
            error: persona.error, results: results)
    }
}
