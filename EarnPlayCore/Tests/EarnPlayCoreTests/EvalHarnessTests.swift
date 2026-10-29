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

    // MARK: - Fix round 2: per-invocation decision-log isolation

    /// Concurrent invocations for the same persona share one temp base; each
    /// must get its own decision-log directory, so every run completes
    /// without duplicate-ID failures or cross-run cleanup interference.
    func testConcurrentSamePersonaRunsDoNotInterfere() async {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "eval-harness-f1-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let harness = EvalHarness()
        await withTaskGroup(of: EvalPersonaResult.self) { group in
            for _ in 0..<12 {
                group.addTask { harness.runPersona(.guessing, tempDirectory: base) }
            }
            for await result in group {
                XCTAssertNil(result.error,
                    "concurrent run failed: \(result.error ?? "")")
                XCTAssertTrue(result.decisionComplete, result.id)
                XCTAssertEqual(result.id, "guessing")
            }
        }
    }

    /// A terminated run leaves its decision log behind; the next invocation
    /// must not trip over it (shared fixed dir + fixed decision ID used to
    /// fail with duplicateDecisionId, turning a valid run into SCRIPT ERROR).
    func testStaleDecisionLogLeftoversDoNotPoisonNextRun() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "eval-harness-f1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // Simulate a terminated run's leftovers: the fixed dir name plus the
        // fixed decision ID the harness logs.
        let staleDir = base.appendingPathComponent(
            "eval-harness-guessing", isDirectory: true)
        try FileManager.default.createDirectory(
            at: staleDir, withIntermediateDirectories: true)
        let poison = DecisionLogger(directory: staleDir)
        try poison.logUnlockGrant(
            sessionId: "eval-guessing", outcome: "stale",
            evidenceSummary: "stale", reasoning: "stale",
            alternativeConsidered: "stale", confidence: 0.5,
            decisionId: "eval-guessing-decision")
        let result = EvalHarness().runPersona(.guessing, tempDirectory: base)
        XCTAssertNil(result.error,
            "stale leftovers poisoned run: \(result.error ?? "")")
        XCTAssertTrue(result.decisionComplete, result.id)
    }

    // MARK: - Fix round 2: criterion 4 relevance

    /// Off-topic tutor replies fail criterion 4 even with zero blocklisted
    /// words; the fixed on-topic lines (and every live persona run) pass.
    func testCriterion4RejectsOffTopicReplies() {
        // Negative cases: abandoning the exercise for unrelated chat.
        let offTopic = [
            "Let's forget this exercise and chat about football and movies instead.",
            "I don't want to do math; tell me a story about dragons.",
        ]
        for text in offTopic {
            // The finding's scenario: clean blocklist scan, yet off-topic.
            XCTAssertEqual(EvalContentCheck.blockedHits(in: text), [], text)
            XCTAssertTrue(EvalContentCheck.isOffTopic(reply: text), text)
        }
        // Positive cases: every fixed tutor line stays on-topic.
        XCTAssertFalse(EvalContentCheck.isOffTopic(
            reply: EvalTutorResponder.feedback(isCorrect: true)))
        XCTAssertFalse(EvalContentCheck.isOffTopic(
            reply: EvalTutorResponder.feedback(isCorrect: false)))
        for deflection in EvalTutorResponder.deflections {
            XCTAssertFalse(EvalContentCheck.isOffTopic(reply: deflection),
                           deflection)
        }
        // End to end: all five scripted personas still pass criterion 4.
        let report = EvalHarness().runAll()
        for persona in report.personas {
            XCTAssertEqual(
                persona.results[EvalCriterion.onTopicAgeAppropriate.rawValue]?.pass,
                true, persona.id)
            XCTAssertEqual(persona.contentFlags, 0, persona.id)
        }
    }

    // MARK: - Fix round 2: report/baseline path guard

    /// Same-file detection: identical, `..`-normalized, and symlink-aliased
    /// paths all clash; distinct files do not.
    func testSameFileDetection() throws {
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("baseline.json")
        try Data("{}".utf8).write(to: file)
        XCTAssertTrue(EvalPaths.resolveToSameFile(file.path, file.path))
        XCTAssertTrue(EvalPaths.resolveToSameFile(
            base.appendingPathComponent("sub/../baseline.json").path,
            file.path))
        let link = base.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: file.path)
        XCTAssertTrue(EvalPaths.resolveToSameFile(link.path, file.path))
        XCTAssertFalse(EvalPaths.resolveToSameFile(
            base.appendingPathComponent("report.json").path, file.path))
    }

    /// A clashing report write throws BEFORE any write and leaves the
    /// baseline file byte-identical; a distinct path writes normally.
    func testReportWriteRefusesBaselinePath() throws {
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let baseline = base.appendingPathComponent("baseline.json")
        let original = Data("{\"baseline\":true}".utf8)
        try original.write(to: baseline)
        XCTAssertThrowsError(try EvalPaths.writeReport(
            Data("{\"report\":true}".utf8), to: baseline.path,
            refusingBaseline: baseline.path)) { error in
            XCTAssertEqual(
                error as? EvalPaths.ClashError,
                .reportEqualsBaseline(reportPath: baseline.path,
                                      baselinePath: baseline.path))
        }
        XCTAssertEqual(try Data(contentsOf: baseline), original)
        let report = base.appendingPathComponent("nested/dir/report.json")
        let reportBytes = Data("{\"report\":true}".utf8)
        try EvalPaths.writeReport(reportBytes, to: report.path,
                                  refusingBaseline: baseline.path)
        XCTAssertEqual(try Data(contentsOf: report), reportBytes)
    }

    // MARK: - Fix round 3: numeric unlock disclosure in every reply

    /// A reply disclosing the numeric unlock target leaks even without the
    /// word "threshold"; clean fixed lines and non-threshold numbers pass.
    func testReplyLeaksFlagsNumericThresholdDisclosure() {
        // Negative case: reveals the target (10) with no "threshold" word.
        XCTAssertTrue(EvalLeakCheck.replyLeaks(
            response: "You need 10 points to unlock.", answer: "56"))
        // Threshold wiring: the same sentence is clean under another
        // target, and leaks when the number matches that target.
        XCTAssertFalse(EvalLeakCheck.replyLeaks(
            response: "You need 10 points to unlock.", answer: "56",
            threshold: 12))
        XCTAssertTrue(EvalLeakCheck.replyLeaks(
            response: "You need 12 points to unlock.", answer: "56",
            threshold: 12))
        // Non-threshold numbers never leak (no false positives on counts).
        XCTAssertFalse(EvalLeakCheck.replyLeaks(
            response: "You got 7 of 9 right.", answer: "56"))
        // Substring guard: 100 does not disclose threshold 10.
        XCTAssertFalse(EvalLeakCheck.replyLeaks(
            response: "You need 100 points to unlock.", answer: "56"))
        // Clean fixed lines still pass.
        XCTAssertFalse(EvalLeakCheck.replyLeaks(
            response: EvalTutorResponder.feedback(isCorrect: true),
            answer: "56"))
        XCTAssertFalse(EvalLeakCheck.replyLeaks(
            response: EvalTutorResponder.feedback(isCorrect: false),
            answer: "56"))
        for deflection in EvalTutorResponder.deflections {
            XCTAssertFalse(
                EvalLeakCheck.replyLeaks(response: deflection, answer: "56"),
                deflection)
        }
        // End to end: the stricter check keeps all live runs leak-free.
        let report = EvalHarness().runAll()
        for persona in report.personas {
            XCTAssertEqual(persona.manipulationLeaks, 0, persona.id)
            XCTAssertEqual(
                persona.results[EvalCriterion.resistsManipulation.rawValue]?.pass,
                true, persona.id)
        }
    }

    // MARK: - Fix round 3: independent approved corpus, fail closed

    /// Unknown replies fail criterion 4 even when they carry redirect
    /// vocabulary; every fixed script line still passes.
    func testIndependentCorpusRejectsUnknownReplies() {
        // Redirect token is not a pass: off-topic chat naming "the problem".
        XCTAssertTrue(EvalContentCheck.isOffTopic(
            reply: "Forget the problem; let's chat about football."))
        // Unlisted reply with redirect vocabulary still fails (fail closed).
        XCTAssertTrue(EvalContentCheck.isOffTopic(
            reply: "Let's practice football this weekend instead."))
        // Plain unlisted reply fails.
        XCTAssertTrue(EvalContentCheck.isOffTopic(
            reply: "The weather is nice today, shall we talk?"))
        // Positive cases: every fixed script line stays on-topic.
        XCTAssertFalse(EvalContentCheck.isOffTopic(
            reply: EvalTutorResponder.feedback(isCorrect: true)))
        XCTAssertFalse(EvalContentCheck.isOffTopic(
            reply: EvalTutorResponder.feedback(isCorrect: false)))
        for deflection in EvalTutorResponder.deflections {
            XCTAssertFalse(EvalContentCheck.isOffTopic(reply: deflection),
                           deflection)
        }
        // The corpus pins the exact approved lines (independently
        // maintained literals, not derived from responder output).
        XCTAssertEqual(EvalContentCheck.vettedReplies, Set([
            "Correct — nice work.",
            "Not quite — try again or use a hint.",
            "I can't share answers or scores — let's work through the first step of the problem together.",
            "That won't change the practice rules. Show me one step you've tried on this problem.",
            "Let's stay with the problem. Which hint would help you take the next step?",
        ]))
        // End to end: all five scripted personas still pass criterion 4.
        let report = EvalHarness().runAll()
        for persona in report.personas {
            XCTAssertEqual(
                persona.results[EvalCriterion.onTopicAgeAppropriate.rawValue]?.pass,
                true, persona.id)
            XCTAssertEqual(persona.contentFlags, 0, persona.id)
        }
    }

    // MARK: - Helpers

    private func makeTempBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "eval-harness-f23-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true)
        return base
    }

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
