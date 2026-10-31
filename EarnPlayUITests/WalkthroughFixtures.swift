import XCTest

/// Walkthrough fixtures and seeds (issue #71). Everything in this file
/// lives in the TEST target only — no fixture data in production code.
///
/// - `SeededChorePool` stocks the admin policy editor's chore pool in
///   the policy-editor walkthrough step (real UI input, example data).
/// - `ScriptedPracticeSession` is the deterministic question/answer
///   script the practice walkthrough step WILL drive once setup
///   completion unblocks the chat UI (gap PRACTICE). Every string is
///   pinned to production behavior (DemoTutorEngine +
///   FallbackQuestionBank.demo + HintLadder + ChatConversationView).
/// - `StagedLeniencySession` is the auditor finding-staging spec
///   matching the T5.4 demo-staging moment (Docs/Auditor.md check 1):
///   the session shape the auditor walkthrough step WILL sync once
///   live sync delivers sessions (gap AUDITOR-FINDING).
enum WalkthroughFixtures {}

// MARK: - Seeded chore pool

/// Example parent-stocked chores. The policy-editor step types
/// `entries[0].chore` into a new chore row and saves; the rest
/// documents the pool the child chore-trade step will offer from once
/// that surface is reachable (gap CHORE-TRADE).
struct SeededChorePool {
    struct Entry {
        var chore: String
        var unlockMinutes: Int
        var weeklyCap: Int
        var verification: String

        init(chore: String, unlockMinutes: Int, weeklyCap: Int, verification: String) {
            self.chore = chore
            self.unlockMinutes = unlockMinutes
            self.weeklyCap = weeklyCap
            self.verification = verification
        }
    }

    static let entries: [Entry] = [
        Entry(chore: "Tidy your bedroom", unlockMinutes: 10, weeklyCap: 2,
              verification: "parent-confirm"),
        Entry(chore: "Take out the recycling", unlockMinutes: 15, weeklyCap: 3,
              verification: "parent-confirm"),
    ]

    /// Structural check against the production editor ranges
    /// (unlockMinutes 1...240, weeklyCap 0...21). Returns nil when valid.
    static func validationError() -> String? {
        if entries.isEmpty {
            return "seeded chore pool is empty"
        }
        for entry in entries {
            if entry.chore.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "seeded chore entry has a blank name"
            }
            if !(1 ... 240).contains(entry.unlockMinutes) {
                return "seeded chore '\(entry.chore)' has out-of-range minutes: \(entry.unlockMinutes)"
            }
            if !(0 ... 21).contains(entry.weeklyCap) {
                return "seeded chore '\(entry.chore)' has out-of-range weekly cap: \(entry.weeklyCap)"
            }
            if entry.verification != "parent-confirm" && entry.verification != "photo-async" {
                return "seeded chore '\(entry.chore)' has unknown verification: \(entry.verification)"
            }
        }
        return nil
    }
}

// MARK: - Scripted practice session

/// The deterministic practice script: 3 verified fallback questions
/// (DemoTutorEngine serves FallbackQuestionBank.demo in order,
/// question ids demo-q1...demo-q3, number-pad composer for all three).
///
/// Script flow per the task: question presented -> hint requested from
/// the ladder -> a wrong answer followed by a probe -> explanation ->
/// correct answers -> session completion.
struct ScriptedPracticeSession {
    struct Question {
        var id: String
        var prompt: String
        var correctAnswer: String

        init(id: String, prompt: String, correctAnswer: String) {
            self.id = id
            self.prompt = prompt
            self.correctAnswer = correctAnswer
        }
    }

    static let questions: [Question] = [
        Question(
            id: "demo-q1",
            prompt: "A farmer packs 7 eggs in each carton. She fills 8 cartons for the market. How many eggs did she pack in all?",
            correctAnswer: "56"
        ),
        Question(
            id: "demo-q2",
            prompt: "Three friends solved 6 × 9. Ana says 54, Ben says 56, and Cy says 45. Which answer is correct?",
            correctAnswer: "54"
        ),
        Question(
            id: "demo-q3",
            prompt: "About how many is 11 × 9? First round 11 to 10 and estimate, then give the exact answer.",
            correctAnswer: "99"
        ),
    ]

    /// Ladder level-1 (nudge) hint for demo-q1, per HintLadder
    /// multiplication text with operands [7, 8].
    static let firstHintText =
        "Look again at 7 × 8: picture the equal groups in the problem before you answer."

    /// Wrong first answer for demo-q1 (SolverService verdict:
    /// incorrect), which triggers the encouragement + probe pair.
    static let wrongAnswer = "55"

    /// Engine encouragement after the first wrong attempt.
    static let wrongAttemptEncouragement = "Good trying. Let's look at it another way."

    /// Probe the engine appends after the first wrong attempt. The
    /// next submission answers it (acknowledged, never graded).
    static let probeText = "Show me one step: what did you try first?"

    /// Substantive probe explanation (StallingDetector treats a
    /// multi-word explanation as substantive).
    static let probeReply = "I multiplied 7 by 8 and got 55, then I got stuck."

    /// Engine acknowledgement of the probe explanation.
    static let probeAcknowledgement =
        "Thanks for showing your thinking. Try the question again when you are ready."

    /// Engine encouragement after each correct non-final answer.
    static let correctEncouragement = "Nice work. Let's try another one."

    /// Engine encouragement after the final correct answer.
    static let finalEncouragement = "Nice work. That was a good practice session."

    /// Session-complete composer state (ChatConversationView).
    static let sessionCompleteTitle = "Practice complete. Nice work."
    static let sessionCompleteRestart = "Start again"

    /// Structural check: 3 ordered questions with non-blank prompts
    /// and answers, a wrong answer that differs from the correct one,
    /// and non-blank engine lines. Returns nil when valid.
    static func validationError() -> String? {
        if questions.count != 3 {
            return "script must hold exactly 3 questions, found \(questions.count)"
        }
        for (offset, question) in questions.enumerated() {
            let expectedID = "demo-q\(offset + 1)"
            if question.id != expectedID {
                return "question \(offset) has id \(question.id), expected \(expectedID)"
            }
            if question.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "question \(question.id) has a blank prompt"
            }
            if question.correctAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "question \(question.id) has a blank correct answer"
            }
        }
        if wrongAnswer == questions[0].correctAnswer {
            return "wrong answer must differ from the correct answer"
        }
        let lines = [firstHintText, wrongAttemptEncouragement, probeText, probeReply,
                     probeAcknowledgement, correctEncouragement, finalEncouragement,
                     sessionCompleteTitle, sessionCompleteRestart]
        for line in lines {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "script has a blank engine line"
            }
        }
        return nil
    }
}

// MARK: - Staged leniency session

/// Auditor finding-staging spec matching the T5.4 demo-staging moment
/// (Docs/Auditor.md check 1, leniency-drift): grants with falling
/// effort, latest <= first - 4. The auditor step WILL sync sessions in
/// this shape and expect one leniency-drift finding (severity watch)
/// once live sync delivers sessions (gap AUDITOR-FINDING).
///
/// Engine behavior for this shape is already pinned in the core
/// package (EarnPlayCoreTests/AuditorEngineTests
/// testLeniencyDriftFlags); this spec pins what the walkthrough feeds
/// the admin UI, in the UI-test target only.
struct StagedLeniencySession {
    /// Minimum grant decisions in the staged set (doc: >= 3 grants).
    static let minimumGrants = 3

    /// Minimum effort drop from first to latest grant (doc: latest <=
    /// first - 4).
    static let minimumEffortDrop = 4

    /// Expected flag for the staged set.
    static let expectedCategory = "leniency-drift"
    static let expectedSeverity = "watch"

    /// Example staged effort totals (falling, latest <= first - 4).
    static let stagedEffortTotals = [12, 9, 6, 4]

    /// Structural check against the documented check-1 rule. Returns
    /// nil when valid.
    static func validationError() -> String? {
        if minimumGrants < 3 {
            return "leniency staging needs >= 3 grants"
        }
        if stagedEffortTotals.count < minimumGrants {
            return "staged totals hold \(stagedEffortTotals.count) grants, need \(minimumGrants)"
        }
        for offset in 1 ..< stagedEffortTotals.count {
            if stagedEffortTotals[offset] >= stagedEffortTotals[offset - 1] {
                return "staged effort totals must fall monotonically"
            }
        }
        let first = stagedEffortTotals.first ?? 0
        let latest = stagedEffortTotals.last ?? 0
        if latest > first - minimumEffortDrop {
            return "staged latest (\(latest)) must be <= first (\(first)) - \(minimumEffortDrop)"
        }
        if expectedCategory != "leniency-drift" || expectedSeverity != "watch" {
            return "staged expectation must be leniency-drift/watch"
        }
        return nil
    }
}
