import Foundation

/// Hint ladder (T1.3, issue #6; LLD-hintevent, SSOT-canonical-facts-
/// questions-and-hints, APP-how-it-works).
///
/// Three hint levels — nudge, then strategy, then one worked step —
/// offered while the child is working on one verified question. Each
/// Hint tap delivers exactly one ladder level as a tutor message in
/// the chat thread (`TutorMessage`, kind `.hint`, the T1.8 shape from
/// `ReadAloudService.swift`); a fourth tap shows no new level and logs
/// no duplicate event.
///
/// Consumes T1.2, never re-implements it: the ladder is built from a
/// `VerifiedQuestion` plus the `ProposedProblem` it was verified from
/// (both carried by `QuestionGenerationResult`). Hint content is
/// computed deterministically from the proposal's structured values,
/// and the worked step is checked against `SolverService`'s answer
/// for those same values, so a hint can never teach a wrong result.
/// No model inference is used.
///
/// Every hint shown is recorded as a `HintEvent` (level shown,
/// timestamp, question it belongs to). The event also tracks whether
/// the next answer changed: `recordAnswerSubmission(_:)` resolves
/// every still-pending event against the answer snapshot taken when
/// that hint was shown. One ladder instance serves one question; the
/// caller creates a fresh ladder per question (T1.8 wiring).
public enum HintLevel: Int, Codable, Equatable, Sendable, CaseIterable {
    /// Gentle redirection; never reveals the answer or a computation.
    case nudge = 1
    /// Names a strategy for this problem; still no computed result.
    case strategy = 2
    /// One worked step whose arithmetic lands on the solver's answer.
    case workedStep = 3

    public var next: HintLevel? {
        HintLevel(rawValue: rawValue + 1)
    }
}

/// One delivered hint: the ladder level plus its chat-thread message.
public struct Hint: Equatable, Sendable {
    public let level: HintLevel
    public let questionId: String
    public let text: String

    public init(level: HintLevel, questionId: String, text: String) {
        self.level = level
        self.questionId = questionId
        self.text = text
    }

    /// Chat-thread delivery: one tutor message per Hint tap.
    public var tutorMessage: TutorMessage {
        TutorMessage(id: "\(questionId)-hint-\(level.rawValue)", text: text, kind: .hint)
    }
}

/// Log record for one hint use (LLD-hintevent).
///
/// `followedByChangedAnswer` is nil while the hint is still awaiting
/// the child's next answer, then `recordAnswerSubmission(_:)` sets it
/// on the first answer submitted after the hint: true when that answer
/// differs from `answerBeforeHint` (the last answer submitted before
/// the hint, if any), false when it is the same — or when there was no
/// earlier answer to change from, since a first answer is not a
/// revision. `nextAnswer` keeps that resolving answer for audit.
public struct HintEvent: Codable, Equatable, Sendable {
    public let questionId: String
    public let level: HintLevel
    public let hintText: String
    public let shownAt: Date
    /// Last answer submitted before this hint, if any.
    public let answerBeforeHint: String?
    public internal(set) var followedByChangedAnswer: Bool?
    public internal(set) var nextAnswer: String?

    public init(questionId: String, level: HintLevel, hintText: String,
                shownAt: Date, answerBeforeHint: String?) {
        self.questionId = questionId
        self.level = level
        self.hintText = hintText
        self.shownAt = shownAt
        self.answerBeforeHint = answerBeforeHint
        self.followedByChangedAnswer = nil
        self.nextAnswer = nil
    }
}

/// Sink for hint events, mirroring `HintListenEventSink`. The ladder
/// calls it when a hint is shown and again when that event resolves
/// (upsert by `questionId` + `level`), so a persistent log observes
/// the changed-answer outcome, not just the showing.
public protocol HintEventSink: AnyObject {
    func recordHintEvent(_ event: HintEvent)
}

/// Stateful three-level ladder for one verified question.
public final class HintLadder: @unchecked Sendable {
    public let question: VerifiedQuestion
    public let proposal: ProposedProblem

    private let solver: SolverService
    private let now: () -> Date
    private let eventSink: (any HintEventSink)?

    private let lock = NSLock()
    private var _events: [HintEvent] = []
    private var _shownHints: [Hint] = []
    private var lastSubmittedAnswer: String?

    public init(question: VerifiedQuestion, proposal: ProposedProblem,
                solver: SolverService = SolverService(),
                now: @escaping () -> Date = Date.init,
                eventSink: (any HintEventSink)? = nil) {
        self.question = question
        self.proposal = proposal
        self.solver = solver
        self.now = now
        self.eventSink = eventSink
    }

    /// Convenience for the T1.2 call site: build from a whole
    /// generation result, which already pairs question and proposal.
    public convenience init(result: QuestionGenerationResult,
                            solver: SolverService = SolverService(),
                            now: @escaping () -> Date = Date.init,
                            eventSink: (any HintEventSink)? = nil) {
        self.init(question: result.question, proposal: result.proposal,
                  solver: solver, now: now, eventSink: eventSink)
    }

    /// Every hint event so far, in shown order. Resolved events carry
    /// their `followedByChangedAnswer` outcome.
    public var events: [HintEvent] {
        lock.lock(); defer { lock.unlock() }; return _events
    }

    /// Tutor messages delivered so far, for the chat thread.
    public var tutorMessages: [TutorMessage] {
        lock.lock(); defer { lock.unlock() }; return _shownHints.map(\.tutorMessage)
    }

    /// Level the next Hint tap would show; nil once the ladder is
    /// exhausted (a later level is never offered before earlier ones).
    public var nextLevel: HintLevel? {
        lock.lock(); defer { lock.unlock() }
        return HintLevel(rawValue: _events.count + 1)
    }

    public var hasMoreHints: Bool { nextLevel != nil }

    /// Shows the next ladder level and logs one `HintEvent`.
    ///
    /// Returns nil — logging nothing — when the ladder is already
    /// exhausted (fourth and later taps) or when the solver cannot
    /// verify the proposal's values (no hint may teach from values
    /// the solver rejects; such a question should never have been
    /// presented, and the ladder fails closed rather than guessing).
    @discardableResult
    public func requestHint() -> Hint? {
        lock.lock(); defer { lock.unlock() }
        guard let level = HintLevel(rawValue: _events.count + 1) else { return nil }
        guard case .verified(let verifiedAnswer) = solver.solve(proposal) else { return nil }
        let text = Self.hintText(level: level, proposal: proposal,
                                 verifiedAnswer: verifiedAnswer, solver: solver)
        let hint = Hint(level: level, questionId: question.questionId, text: text)
        let event = HintEvent(questionId: question.questionId, level: level,
                              hintText: text, shownAt: now(),
                              answerBeforeHint: lastSubmittedAnswer)
        _events.append(event)
        _shownHints.append(hint)
        eventSink?.recordHintEvent(event)
        return hint
    }

    /// Records an answer the child submitted. The first submission
    /// after one or more hints resolves those pending hint events:
    /// each compares the submission with its own pre-hint snapshot.
    /// Submissions made before any hint simply set the baseline the
    /// next hint snapshots.
    ///
    /// - Returns: Whether this answer changed from the previous
    ///   submitted answer; false for the first-ever submission.
    @discardableResult
    public func recordAnswerSubmission(_ answer: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let changed = lastSubmittedAnswer.map { !Self.answersMatch($0, answer) } ?? false
        var resolved: [HintEvent] = []
        for index in _events.indices where _events[index].followedByChangedAnswer == nil {
            _events[index].followedByChangedAnswer =
                _events[index].answerBeforeHint.map { !Self.answersMatch($0, answer) } ?? false
            _events[index].nextAnswer = answer
            resolved.append(_events[index])
        }
        lastSubmittedAnswer = answer
        for event in resolved { eventSink?.recordHintEvent(event) }
        return changed
    }

    /// Answer equivalence for the changed-answer comparison: same
    /// value, not just same spelling (an unreduced `2/4` after `1/2`
    /// is a retype, not a revision).
    static func answersMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if a == b { return true }
        if let fa = SolverFraction(parsing: a), let fb = SolverFraction(parsing: b) {
            return fa == fb
        }
        return false
    }

    // MARK: - Hint content (deterministic, from the structured values)

    static func hintText(level: HintLevel, proposal: ProposedProblem,
                         verifiedAnswer: String, solver: SolverService) -> String {
        switch proposal.skill {
        case .multiplicationFacts, .multiDigitMultiplication:
            guard proposal.operands.count == 2 else { return genericText(level) }
            return multiplicationText(level: level, a: proposal.operands[0],
                                      b: proposal.operands[1], answer: verifiedAnswer)
        case .division:
            guard proposal.operands.count == 2 else { return genericText(level) }
            return divisionText(level: level, dividend: proposal.operands[0],
                                divisor: proposal.operands[1], answer: verifiedAnswer)
        case .fractionComparison:
            guard proposal.fractions.count == 2 else { return genericText(level) }
            return fractionComparisonText(level: level, f1: proposal.fractions[0],
                                          f2: proposal.fractions[1], answer: verifiedAnswer)
        case .fractionAddition:
            guard proposal.fractions.count == 2 else { return genericText(level) }
            return fractionAdditionText(level: level, f1: proposal.fractions[0],
                                        f2: proposal.fractions[1], answer: verifiedAnswer)
        case .wordProblem:
            return wordProblemText(level: level, proposal: proposal, answer: verifiedAnswer)
        case .readingComprehension:
            return readingText(level: level, proposal: proposal,
                               answer: verifiedAnswer, solver: solver)
        }
    }

    private static func genericText(_ level: HintLevel) -> String {
        switch level {
        case .nudge: return "Take another look at the problem and read it once more, slowly."
        case .strategy: return "Think about what the problem gives you and what it asks you to find, then pick one first step."
        case .workedStep: return "Work through the problem one small step at a time, checking each step as you go."
        }
    }

    private static func multiplicationText(level: HintLevel, a: Int, b: Int, answer: String) -> String {
        switch level {
        case .nudge:
            return "Look again at \(a) × \(b): that means \(b) equal groups of \(a). Picture the groups before you answer."
        case .strategy:
            return "Strategy: split the second number into two easier parts, multiply \(a) by each part, then add the two parts together."
        case .workedStep:
            if b >= 2 {
                return "Worked step: \(a) × \(b) = \(a) × \(b - 1) + \(a) = \(a * (b - 1)) + \(a) = \(answer)."
            }
            return "Worked step: \(a) × \(b) = \(answer)."
        }
    }

    private static func divisionText(level: HintLevel, dividend: Int, divisor: Int, answer: String) -> String {
        switch level {
        case .nudge:
            return "Look again at \(dividend) ÷ \(divisor): how many equal groups of \(divisor) fit into \(dividend)?"
        case .strategy:
            return "Strategy: guess a number, multiply it by \(divisor), and check how close you get to \(dividend). Adjust your guess until the leftover is smaller than \(divisor)."
        case .workedStep:
            let quotient = divisor == 0 ? 0 : dividend / divisor
            let remainder = divisor == 0 ? dividend : dividend % divisor
            if remainder == 0 {
                return "Worked step: \(divisor) × \(quotient) = \(divisor * quotient), so \(dividend) ÷ \(divisor) = \(answer)."
            }
            return "Worked step: \(divisor) × \(quotient) = \(divisor * quotient) with \(remainder) left over, so \(dividend) ÷ \(divisor) = \(answer)."
        }
    }

    private static func fractionComparisonText(level: HintLevel, f1: SolverFraction,
                                               f2: SolverFraction, answer: String) -> String {
        let common = lcm(f1.denominator, f2.denominator)
        let c1 = f1.numerator * (common / f1.denominator)
        let c2 = f2.numerator * (common / f2.denominator)
        switch level {
        case .nudge:
            return "Look again at \(f1) and \(f2): the bottom numbers name the size of each piece. Which pieces are bigger?"
        case .strategy:
            return "Strategy: rewrite both fractions with the same bottom number (\(common)), then compare just the top numbers."
        case .workedStep:
            return "Worked step: \(f1) = \(c1)/\(common) and \(f2) = \(c2)/\(common), so \(f1) \(answer) \(f2)."
        }
    }

    private static func fractionAdditionText(level: HintLevel, f1: SolverFraction,
                                             f2: SolverFraction, answer: String) -> String {
        let common = lcm(f1.denominator, f2.denominator)
        let c1 = f1.numerator * (common / f1.denominator)
        let c2 = f2.numerator * (common / f2.denominator)
        switch level {
        case .nudge:
            return "Look again at \(f1) + \(f2): you can only add pieces that are the same size."
        case .strategy:
            return "Strategy: rewrite both fractions with the same bottom number (\(common)) first, then add the top numbers and keep that bottom number."
        case .workedStep:
            let rawSum = "\(c1 + c2)/\(common)"
            if rawSum == answer {
                return "Worked step: \(f1) + \(f2) = \(c1)/\(common) + \(c2)/\(common) = \(answer)."
            }
            return "Worked step: \(f1) + \(f2) = \(c1)/\(common) + \(c2)/\(common) = \(rawSum) = \(answer)."
        }
    }

    private static func wordProblemText(level: HintLevel, proposal: ProposedProblem, answer: String) -> String {
        guard let operation = proposal.operation, proposal.operands.count >= 2 else {
            return genericText(level)
        }
        switch operation {
        case .multiply:
            return multiplicationText(level: level, a: proposal.operands[0],
                                      b: proposal.operands[1], answer: answer)
        case .divide:
            return divisionText(level: level, dividend: proposal.operands[0],
                                divisor: proposal.operands[1], answer: answer)
        case .add:
            let list = proposal.operands.map { "\($0)" }.joined(separator: " + ")
            switch level {
            case .nudge:
                return "Look again for the numbers you actually need, and ignore any number the story does not ask about."
            case .strategy:
                return "Strategy: this problem joins amounts together, so add the amounts the question asks about, one at a time."
            case .workedStep:
                return "Worked step: \(list) = \(answer)."
            }
        case .subtract:
            let first = proposal.operands[0]
            let rest = proposal.operands.dropFirst()
            let expression = ([first] + Array(rest)).map { "\($0)" }.joined(separator: " − ")
            switch level {
            case .nudge:
                return "Look again: something starts at \(first) and some is taken away. What is left?"
            case .strategy:
                return "Strategy: start from \(first) and subtract each taken-away amount in turn."
            case .workedStep:
                if rest.count == 1, let taken = rest.first {
                    let tens = (taken / 10) * 10
                    if tens > 0, taken - tens > 0, first - tens >= 0 {
                        return "Worked step: \(first) − \(tens) = \(first - tens), then \(first - tens) − \(taken - tens) = \(answer), so \(expression) = \(answer)."
                    }
                }
                return "Worked step: \(expression) = \(answer)."
            }
        }
    }

    private static func readingText(level: HintLevel, proposal: ProposedProblem,
                                    answer: String, solver: SolverService) -> String {
        switch level {
        case .nudge:
            return "Re-read the passage slowly and look for the sentence that tells you what the question asks about."
        case .strategy:
            return "Strategy: find the sentence in the passage that talks about the same thing as the question, then answer using the words from that sentence."
        case .workedStep:
            if let passage = proposal.passage,
               case .supported(let evidence) = solver.verifyReadingSupport(passage: passage, proposedAnswer: answer) {
                return "Worked step: the passage says \u{201C}\(evidence)\u{201D} — so the answer is \(answer)."
            }
            return "Worked step: the answer is in the passage: \(answer)."
        }
    }

    private static func lcm(_ a: Int, _ b: Int) -> Int {
        a / SolverFraction.gcd(a, b) * b
    }
}
