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
/// computed deterministically from the proposal's structured values.
/// The worked step shows one correct intermediate step — cross-checked
/// against `SolverService`'s answer for those same values — and stops
/// short of the final answer, so a hint can never teach a wrong result
/// or give the solution away. No model inference is used.
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
    /// One worked intermediate step that stops short of the answer.
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
///
/// Delivery is asynchronous but ordered per ladder and serialized across
/// all ladders: notifications are queued under each ladder's state lock
/// in state-change order and drained serially on one shared queue, so an
/// older unresolved event can never overwrite its own resolution and
/// callbacks never overlap — even when successive questions share one
/// session log sink. A sink need not be thread-safe. Delivery holds no
/// ladder lock, so a sink may safely read ladder state back from its
/// callback.
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
    /// Sink notifications queued under `lock` in state-change order.
    private var _pendingSinkEvents: [HintEvent] = []
    /// Serial drain for sink delivery, shared by all ladders: every
    /// mutation schedules one async drain, which takes its ladder's batch
    /// under that ladder's `lock` and delivers it with no lock held. The
    /// async boundary keeps lock order flat (the drain never blocks a
    /// state change), so re-entrant sink reads cannot deadlock while
    /// deliveries stay serial and ordered per ladder. One shared queue —
    /// not one per ladder — so two ladders for successive questions that
    /// share a session log sink can never call it concurrently.
    private static let sharedSinkQueue = DispatchQueue(label: "com.earnplay.HintLadder.sink")

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
    /// exhausted (fourth and later taps), when the solver cannot
    /// verify the proposal's values, when the proposal does not
    /// re-verify to exactly the supplied question (no hint may teach
    /// from values the solver rejects, or hint one problem under
    /// another question's id; such a question should never have been
    /// presented, and the ladder fails closed rather than guessing),
    /// or — for reading — when the proposal fails T1.2's presentation
    /// gate (prompt must contain the trimmed passage and the
    /// question/answer pair must satisfy `ReadingPresentationVerifier`,
    /// since solver containment alone does not mean the answer
    /// addresses the question).
    @discardableResult
    public func requestHint() -> Hint? {
        lock.lock()
        guard let level = HintLevel(rawValue: _events.count + 1) else {
            lock.unlock()
            return nil
        }
        // Solving the proposal alone would hint a mismatched problem
        // (a valid 6 × 9 proposal paired with a verified 7 × 8
        // question): re-verify and require the exact supplied question.
        // `VerifiedQuestion` carries its source operands, fractions, and
        // operation, so this equality also rejects same-prompt,
        // same-answer collisions from different values (6×6 vs 9×4).
        guard case .success(let rechecked) = solver.verify(proposal, questionId: question.questionId),
              rechecked == question else {
            lock.unlock()
            return nil
        }
        if proposal.skill == .readingComprehension {
            guard let passage = proposal.passage else {
                lock.unlock()
                return nil
            }
            let trimmed = passage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  proposal.promptText.contains(trimmed),
                  ReadingPresentationVerifier.isVerified(proposal) else {
                lock.unlock()
                return nil
            }
        }
        let text = Self.hintText(level: level, proposal: proposal,
                                 verifiedAnswer: rechecked.verifiedAnswer, solver: solver)
        let hint = Hint(level: level, questionId: question.questionId, text: text)
        let event = HintEvent(questionId: question.questionId, level: level,
                              hintText: text, shownAt: now(),
                              answerBeforeHint: lastSubmittedAnswer)
        _events.append(event)
        _shownHints.append(hint)
        _pendingSinkEvents.append(event)
        lock.unlock()
        scheduleSinkDrain()
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
        lock.lock()
        let skill = proposal.skill
        let changed = lastSubmittedAnswer.map { !Self.answersMatch($0, answer, skill: skill) } ?? false
        var resolved: [HintEvent] = []
        for index in _events.indices where _events[index].followedByChangedAnswer == nil {
            _events[index].followedByChangedAnswer =
                _events[index].answerBeforeHint.map { !Self.answersMatch($0, answer, skill: skill) } ?? false
            _events[index].nextAnswer = answer
            resolved.append(_events[index])
        }
        lastSubmittedAnswer = answer
        _pendingSinkEvents.append(contentsOf: resolved)
        lock.unlock()
        if !resolved.isEmpty { scheduleSinkDrain() }
        return changed
    }

    /// Schedules one serial drain of the queued sink notifications. The
    /// block retains the ladder until its batch is delivered, so events
    /// are never dropped when the caller releases the ladder first.
    private func scheduleSinkDrain() {
        guard eventSink != nil else { return }
        Self.sharedSinkQueue.async { [self] in self.drainSinkEvents() }
    }

    /// Delivers one queued batch, in queue order, with no ladder lock held
    /// (a synchronous sink may read ladder state back). Runs only on the
    /// shared queue, so deliveries are serial across all caller threads
    /// and across all ladders sharing a sink.
    private func drainSinkEvents() {
        lock.lock()
        guard !_pendingSinkEvents.isEmpty else {
            lock.unlock()
            return
        }
        let batch = _pendingSinkEvents
        _pendingSinkEvents = []
        let sink = eventSink
        lock.unlock()
        for event in batch { sink?.recordHintEvent(event) }
    }

    /// Blocks until every scheduled sink delivery has finished. For tests
    /// only — production code treats delivery as fire-and-forget ordered.
    /// Must not be called from inside a sink callback (same-queue sync).
    func waitForSinkDelivery() {
        Self.sharedSinkQueue.sync {}
    }

    /// Answer equivalence for the changed-answer comparison, mirroring
    /// the solver's grading for the current skill: same value, not just
    /// same spelling. Reading ignores case and punctuation (`Maya` vs
    /// `maya.`), comparison treats `==` as `=` (the grading spelling),
    /// and addition compares fraction values (an unreduced `2/4` after
    /// `1/2` is a retype, not a revision). Every other skill compares
    /// the trimmed text exactly, as grading does.
    static func answersMatch(_ lhs: String, _ rhs: String, skill: SolverSkill) -> Bool {
        let a = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if a == b { return true }
        switch skill {
        case .readingComprehension:
            return SolverService.normalizeForSupport(a) == SolverService.normalizeForSupport(b)
        case .fractionComparison:
            return a.replacingOccurrences(of: "==", with: "=")
                == b.replacingOccurrences(of: "==", with: "=")
        case .fractionAddition:
            if let fa = SolverFraction(parsing: a), let fb = SolverFraction(parsing: b) {
                return fa == fb
            }
            return false
        default:
            return false
        }
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
            // No operand orientation asserted: the rendered story uses
            // a-groups-of-b for word problems but b-groups-of-a for
            // multiplication facts, so naming either direction reverses
            // one of them ([6,7] renders as six rows of seven).
            return "Look again at \(a) × \(b): picture the equal groups in the problem before you answer."
        case .strategy:
            return "Strategy: split the second number into two easier parts, multiply \(a) by each part, then add the two parts together."
        case .workedStep:
            // Zero product: the near-complete template would show
            // 0 × 7 = 0 × 6 + 0 = 0 + 0, whose partial already equals
            // the answer. Use a conceptual step instead, with no group
            // count or size: word problems render a-groups-of-b while
            // multiplication facts render b-groups-of-a, so naming
            // either direction reverses one of them.
            if a == 0, b >= 2 {
                return "Worked step: \(a) × \(b) means every part is empty — there is nothing to count in any part. How many is that altogether?"
            }
            // One step short of the answer: the near-complete product,
            // leaving the final addition to the child. The completion
            // must equal the solver's answer or nothing is shown.
            if b >= 2 {
                let (partial, o1) = a.multipliedReportingOverflow(by: b - 1)
                let (total, o2) = partial.addingReportingOverflow(a)
                guard !o1, !o2, "\(total)" == answer else { return genericText(level) }
                return "Worked step: \(a) × \(b) = \(a) × \(b - 1) + \(a) = \(partial) + \(a). Now add \(partial) + \(a) yourself to finish."
            }
            if b == 1 {
                return "Worked step: \(a) × 1 means the amount appears just once. How many is that altogether?"
            }
            if b == 0 {
                return "Worked step: \(a) × 0 means every part is empty — there is nothing to count in any part. How many is that altogether?"
            }
            return genericText(level)
        }
    }

    private static func divisionText(level: HintLevel, dividend: Int, divisor: Int, answer: String) -> String {
        switch level {
        case .nudge:
            return "Look again at \(dividend) ÷ \(divisor): how many equal groups of \(divisor) fit into \(dividend)?"
        case .strategy:
            return "Strategy: guess a number, multiply it by \(divisor), and subtract that from \(dividend) to get the leftover. Keep adjusting your guess until the leftover is 0 or more but still smaller than \(divisor)."
        case .workedStep:
            guard divisor > 0, dividend >= 0 else { return genericText(level) }
            let quotient = dividend / divisor
            let remainder = dividend % divisor
            // All but the last group is worked; the child counts the
            // total (products stay within the dividend, so no overflow).
            if remainder == 0, quotient >= 1 {
                let shown = quotient - 1
                let used = divisor * shown
                guard used + divisor == dividend, "\(quotient)" == answer else {
                    return genericText(level)
                }
                // Quotient one: shown is zero, so stating "exactly one
                // more fits" gives 0 + 1 = 1 away. Leave the remaining
                // groups for the child to determine.
                if quotient == 1 {
                    return "Worked step: \(divisor) × 0 = 0, and \(dividend) − 0 = \(dividend). How many more groups of \(divisor) fit, and how many groups is that altogether?"
                }
                return "Worked step: \(divisor) × \(shown) = \(used), and \(dividend) − \(used) = \(divisor), so exactly one more group of \(divisor) fits. How many groups is that altogether?"
            }
            if remainder != 0, quotient >= 1 {
                let shown = quotient - 1
                let used = divisor * shown
                let left = dividend - used
                guard used + left == dividend, "\(quotient) r \(remainder)" == answer else {
                    return genericText(level)
                }
                return "Worked step: \(divisor) × \(shown) = \(used), and \(dividend) − \(used) = \(left). \(left) still holds more groups of \(divisor) — how many groups in all, and what is left over?"
            }
            guard quotient == 0 else { return genericText(level) }
            let expected = remainder == 0 ? "\(quotient)" : "\(quotient) r \(remainder)"
            guard expected == answer else { return genericText(level) }
            return "Worked step: \(divisor) × 1 = \(divisor). Compare that with \(dividend) to decide how many full groups fit, then find any remainder."
        }
    }

    private static func fractionComparisonText(level: HintLevel, f1: SolverFraction,
                                               f2: SolverFraction, answer _: String) -> String {
        // Checked LCM: the common denominator can overflow Int on pairs
        // the solver still verifies (safe comparison cross-products,
        // huge LCM), so this must never trap — not even on the nudge.
        // (The solver's answer is not quoted: the step stops short.)
        if let common = checkedLCM(f1.denominator, f2.denominator),
           let c1 = checkedConvert(f1, common: common),
           let c2 = checkedConvert(f2, common: common) {
            switch level {
            case .nudge:
                return "Look again at \(f1) and \(f2): the bottom numbers name the size of each piece. Which pieces are bigger?"
            case .strategy:
                return "Strategy: rewrite both fractions with the same bottom number (\(common)), then compare just the top numbers."
            case .workedStep:
                // Same denominator: conversion would merely repeat the
                // originals (1/5 and 2/5 with bottom number 5). Name that
                // no rewriting is needed and leave the verdict to the
                // child. No comparison symbol appears anywhere here.
                if f1.denominator == f2.denominator, f1.denominator == common {
                    return "Worked step: both fractions already have bottom number \(common), so the pieces are the same size. Compare just the top numbers, \(c1) and \(c2): which is bigger — or are they the same?"
                }
                // Converted but not compared: the child makes the final
                // call. No comparison symbol appears anywhere here.
                return "Worked step: \(f1) with bottom number \(common) is \(c1)/\(common), and \(f2) with bottom number \(common) is \(c2)/\(common). Now compare just the top numbers, \(c1) and \(c2): which is bigger — or are they the same?"
            }
        }
        // LCM overflow: cross-multiplication. The solver verified these
        // cross-products fit when it solved the proposal.
        let (p1, o1) = f1.numerator.multipliedReportingOverflow(by: f2.denominator)
        let (p2, o2) = f2.numerator.multipliedReportingOverflow(by: f1.denominator)
        guard !o1, !o2 else { return genericText(level) }
        switch level {
        case .nudge:
            return "Look again at \(f1) and \(f2): the bottom numbers name the size of each piece. Which pieces are bigger?"
        case .strategy:
            return "Strategy: cross-multiply — multiply the top of each fraction by the bottom of the other — then compare those two whole numbers."
        case .workedStep:
            return "Worked step: cross-multiply: \(f1.numerator) × \(f2.denominator) makes \(p1), and \(f2.numerator) × \(f1.denominator) makes \(p2). Now compare \(p1) and \(p2) — which fraction is greater, or are they equal?"
        }
    }

    private static func fractionAdditionText(level: HintLevel, f1: SolverFraction,
                                             f2: SolverFraction, answer _: String) -> String {
        guard let common = checkedLCM(f1.denominator, f2.denominator),
              let c1 = checkedConvert(f1, common: common),
              let c2 = checkedConvert(f2, common: common) else {
            return genericText(level)
        }
        switch level {
        case .nudge:
            return "Look again at \(f1) + \(f2): you can only add pieces that are the same size."
        case .strategy:
            return "Strategy: rewrite both fractions with the same bottom number (\(common)) first, then add the top numbers and keep that bottom number."
        case .workedStep:
            // Same denominator: conversion would merely repeat the
            // originals (1/5 + 2/5 = 1/5 + 2/5). Name that no rewriting
            // is needed and leave the sum to the child.
            if f1.denominator == f2.denominator, f1.denominator == common {
                return "Worked step: both fractions already have bottom number \(common), so no rewriting is needed. Add the top numbers (\(c1) + \(c2)) yourself and keep the bottom number \(common) — what is the total?"
            }
            // Converted but not summed: the child adds the top numbers.
            return "Worked step: \(f1) + \(f2) = \(c1)/\(common) + \(c2)/\(common). Now add the top numbers (\(c1) + \(c2)) and keep the bottom number \(common)."
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
            switch level {
            case .nudge:
                return "Look again for the numbers you actually need, and ignore any number the story does not ask about."
            case .strategy:
                return "Strategy: this problem joins amounts together, so add the amounts the question asks about, one at a time."
            case .workedStep:
                // Tens and ones separately, checked against the solver's
                // answer; the child puts the two parts together.
                var tensSum = 0
                var onesSum = 0
                for n in proposal.operands {
                    let (t, o1) = tensSum.addingReportingOverflow((n / 10) * 10)
                    let (o, o2) = onesSum.addingReportingOverflow(n % 10)
                    guard !o1, !o2 else { return genericText(level) }
                    tensSum = t
                    onesSum = o
                }
                let (total, o3) = tensSum.addingReportingOverflow(onesSum)
                guard !o3, "\(total)" == answer else { return genericText(level) }
                // Degenerate split: all single-digit (tens add to 0) or all
                // multiples of ten (ones add to 0) would state the full
                // answer as one partial sum ([6,7] gives 6 + 7 = 13).
                // Split one addend instead so the shown step stops short.
                if tensSum == 0 || onesSum == 0 {
                    return additionSplitStep(operands: proposal.operands,
                                             total: total, answer: answer)
                }
                let tensList = proposal.operands.map { "\(($0 / 10) * 10)" }.joined(separator: " + ")
                let onesList = proposal.operands.map { "\($0 % 10)" }.joined(separator: " + ")
                return "Worked step: add the tens first, \(tensList) = \(tensSum), then the ones, \(onesList) = \(onesSum). Now put \(tensSum) and \(onesSum) together to finish."
            }
        case .subtract:
            let first = proposal.operands[0]
            // Ignore zero take-aways: subtracting nothing changes nothing,
            // and keeping a zero can make the multi-operand step show the
            // full answer ([50,18,0] would show 50 − 18 = 32). When every
            // take-away is zero, keep one so the single-subtraction branch
            // still explains that taking away nothing changes nothing.
            let rest = Array(proposal.operands.dropFirst())
            let nonZero = rest.filter { $0 != 0 }
            let takes = nonZero.isEmpty ? Array(rest.prefix(1)) : nonZero
            switch level {
            case .nudge:
                return "Look again: something starts at \(first) and some is taken away. What is left?"
            case .strategy:
                return "Strategy: start from \(first) and subtract each taken-away amount in turn."
            case .workedStep:
                if takes.count == 1, let taken = takes.first, taken >= 0, first >= taken {
                    // Split one take-away into two smaller subtractions
                    // and work only the first; the child finishes.
                    let tens = (taken / 10) * 10
                    let part: Int?
                    if tens > 0, taken - tens > 0 {
                        part = tens
                    } else if taken > 1 {
                        part = taken / 2
                    } else {
                        part = nil
                    }
                    if let part, part > 0, part < taken {
                        let mid = first - part
                        let second = taken - part
                        guard "\(mid - second)" == answer else { return genericText(level) }
                        return "Worked step: \(first) − \(part) = \(mid), then subtract \(second) more from \(mid). What do you get?"
                    }
                    if taken == 1 {
                        return "Worked step: count back 1 from \(first) — what number comes just before \(first)?"
                    }
                    if taken == 0 {
                        return "Worked step: taking away 0 leaves the start unchanged — what did you start with?"
                    }
                    return genericText(level)
                }
                if takes.count > 1, let firstTaken = takes.first, firstTaken >= 0, first >= firstTaken {
                    // Work only the first subtraction; the child continues.
                    let mid = first - firstTaken
                    return "Worked step: \(first) − \(firstTaken) = \(mid). Now keep subtracting the rest from \(mid), one amount at a time."
                }
                return genericText(level)
            }
        }
    }

    /// Worked step for degenerate additions (all single-digit or all
    /// multiples of ten). Prefers a problem-specific partial that stops
    /// short of the solver's total, failing closed to a generic step only
    /// when every numeric partial would restate the answer:
    /// - all zeros: a number-free step (any digit would be the answer);
    /// - three or more addends: work the sum of all but one addend and
    ///   leave that addend unfinished (1+1+1 works 1+1=2);
    /// - a zero among the addends: adding zero changes nothing, so the
    ///   total is the other amount — without naming that amount, which
    ///   already equals the total ([0,7]);
    /// - two ones: count on from 1 (1+1=2 would be the answer);
    /// - otherwise: split one addend into two positive parts, work the
    ///   sum of everything except the second part, and leave the final
    ///   addition to the child.
    private static func additionSplitStep(operands: [Int], total: Int, answer: String) -> String {
        if total == 0 {
            return "Worked step: adding nothing to nothing still leaves nothing — how many is that?"
        }
        if operands.count >= 3 {
            for index in operands.indices.reversed() where operands[index] > 0 {
                let remaining = operands[index]
                let (partial, overflow) = total.subtractingReportingOverflow(remaining)
                guard !overflow, partial >= 0, partial != total else { continue }
                var others = operands
                others.remove(at: index)
                let list = others.map { "\($0)" }.joined(separator: " + ")
                let step = "Worked step: add all but one amount first: \(list) = \(partial). Now add \(remaining) more to \(partial) yourself to finish."
                if !step.contains(answer) {
                    return step
                }
            }
        }
        if total > 0, operands.contains(0) {
            return "Worked step: adding 0 changes nothing — the total is the other amount. Which amount did you start with besides zero?"
        }
        if operands.count == 2, operands.allSatisfy({ $0 == 1 }) {
            return "Worked step: start at 1 and count one more — what comes next?"
        }
        if let value = operands.first(where: { $0 >= 2 }) {
            let firstPart = value / 2
            let secondPart = value - firstPart
            let (partial, overflow) = total.subtractingReportingOverflow(secondPart)
            if !overflow {
                let step = "Worked step: split \(value) into \(firstPart) + \(secondPart). Add everything except \(secondPart) first: you get \(partial). Now add \(secondPart) more to \(partial) yourself to finish."
                // Fail closed: restating an operand that already equals the
                // total would show the answer.
                if !step.contains(answer) {
                    return step
                }
            }
        }
        return "Worked step: add the amounts together one at a time, starting from the first amount. What do you get?"
    }

    private static func readingText(level: HintLevel, proposal: ProposedProblem,
                                    answer: String, solver: SolverService) -> String {
        switch level {
        case .nudge:
            return "Re-read the passage slowly and look for the sentence that tells you what the question asks about."
        case .strategy:
            return "Strategy: find the sentence in the passage that talks about the same thing as the question, then answer using the words from that sentence."
        case .workedStep:
            // Quote the evidence sentence with the answer blanked out:
            // the child fills the blank instead of reading the answer.
            if let passage = proposal.passage,
               let evidence = Self.evidenceSentence(passage: passage,
                                                    promptText: proposal.promptText,
                                                    answer: answer, solver: solver),
               let blanked = Self.blankAnswerSpan(in: evidence, answer: answer) {
                return "Worked step: re-read this sentence from the passage: \u{201C}\(blanked)\u{201D} Which words go in the blank to answer the question?"
            }
            return "Worked step: point to the exact sentence in the passage that answers the question, then read it once more and pick out which words are the answer."
        }
    }

    /// Picks the passage sentence to quote. The solver's support verdict
    /// stays the gate (T1.2 owns support); when exactly one sentence holds
    /// the answer span, that sentence is quoted. When several do, the
    /// verified question–answer relationship decides first: the first
    /// candidate (in passage order) satisfying the generation verifier
    /// (`ReadingPresentationVerifier`) is quoted — every verifying
    /// sentence independently supports the answer, so any is valid
    /// evidence. Word overlap alone can pick a sentence that
    /// merely mentions the questioned words ("The large fox chased a red
    /// hen." for "What color was the large fox?", where the verifier
    /// passes via "The fox was red."). When no candidate verifies (a
    /// shape the verifier does not support), the one sharing the most
    /// content words with the question is quoted — the first
    /// answer-containing sentence may answer a different question
    /// ("Maya wore a red hat. A red fox ran past." / "What color was the
    /// fox?"). Returns nil when the choice is ambiguous (a tie for best,
    /// or no question-word overlap at all), so the caller points at the
    /// passage instead of quoting the wrong sentence.
    private static func evidenceSentence(passage: String, promptText: String,
                                         answer: String, solver: SolverService) -> String? {
        guard case .supported(let firstEvidence) =
                solver.verifyReadingSupport(passage: passage, proposedAnswer: answer) else {
            return nil
        }
        let normalizedAnswer = SolverService.normalizeForSupport(answer)
        guard !normalizedAnswer.isEmpty else { return nil }
        let answerSpan = " \(normalizedAnswer) "
        let candidates = SolverService.passageSentences(passage).filter {
            " \(SolverService.normalizeForSupport($0)) ".contains(answerSpan)
        }
        guard candidates.count > 1 else { return firstEvidence }
        if let question = questionText(in: promptText, passage: passage) {
            let verifying = candidates.filter { candidate in
                let single = ProposedProblem(
                    skill: .readingComprehension, form: .story,
                    passage: candidate, candidateAnswer: answer,
                    promptText: "Read: \(candidate) \(question)")
                return ReadingPresentationVerifier.isVerified(single)
            }
            if let evidence = verifying.first { return evidence }
        }
        let answerTokens = Set(normalizedAnswer.split(separator: " ").map(String.init))
        let questionWords = contentWords(questionText(in: promptText, passage: passage) ?? "",
                                         excluding: answerTokens)
        guard !questionWords.isEmpty else { return nil }
        var best = 0
        var bestScore = 0
        var tied = true
        for (index, sentence) in candidates.enumerated() {
            let sentenceWords = Set(SolverService.normalizeForSupport(sentence)
                .split(separator: " ").map(String.init))
            let score = questionWords.intersection(sentenceWords).count
            if score > bestScore {
                best = index
                bestScore = score
                tied = false
            } else if score == bestScore {
                tied = true
            }
        }
        guard bestScore > 0, !tied else { return nil }
        return candidates[best]
    }

    /// The question part of a reading prompt: everything after the passage
    /// (prompts render as "Read: <passage> <question>"). Matches the
    /// trimmed passage, as the generation verifier does: T1.2 accepts a
    /// trimmed passage in the prompt while retaining the original in the
    /// proposal, so an untrimmed lookup fails on surrounding whitespace.
    private static func questionText(in promptText: String, passage: String) -> String? {
        let trimmed = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let range = promptText.range(of: trimmed) else { return nil }
        let rest = promptText[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }

    /// Function words that carry no topic signal for evidence selection.
    private static let questionStopwords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "been",
        "do", "does", "did", "what", "which", "who", "whom", "whose",
        "when", "where", "why", "how", "many", "much", "there", "that",
        "this", "these", "those", "it", "its", "of", "in", "on", "at",
        "to", "for", "and", "or", "but", "not", "no", "so", "as", "by",
        "from", "with", "than", "then", "he", "she", "they", "them",
        "his", "her", "their", "you", "your", "we", "our", "i", "my",
        "me", "him", "us", "have", "has", "had", "can", "could", "would",
        "should", "will", "shall", "may", "might", "must", "s", "t", "d",
        "ll", "re", "ve", "m",
    ]

    /// Normalized content words of `text`: lowercased whole tokens without
    /// stopwords or answer tokens.
    private static func contentWords(_ text: String, excluding answerTokens: Set<String>) -> Set<String> {
        Set(SolverService.normalizeForSupport(text).split(separator: " ").map(String.init))
            .subtracting(questionStopwords)
            .subtracting(answerTokens)
    }

    /// Returns `evidence` with every normalized whole-token occurrence of
    /// the answer replaced by a blank, or nil when no occurrence can be
    /// located (the caller falls back instead of quoting it whole).
    /// Matching follows the reading grader's normalization, so every
    /// accepted spelling is blanked ("blue box" and "blue-box" alike) and
    /// a punctuated verified answer ("blue box!") still finds its span.
    private static func blankAnswerSpan(in evidence: String, answer: String) -> String? {
        let normalizedAnswer = SolverService.normalizeForSupport(answer)
        guard !normalizedAnswer.isEmpty else { return nil }
        let answerTokens = normalizedAnswer.split(separator: " ").map(String.init)
        let spans = normalizedTokenSpans(in: evidence)
        guard answerTokens.count <= spans.count else { return nil }
        // Whole-token matches as token-index intervals, merging overlaps
        // so one blank covers one contiguous span.
        var merged: [Range<Int>] = []
        for start in 0...(spans.count - answerTokens.count) {
            guard spans[start..<(start + answerTokens.count)]
                .map(\.token).elementsEqual(answerTokens) else { continue }
            let match = start..<(start + answerTokens.count)
            if let last = merged.last, match.lowerBound < last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, match.upperBound)
            } else {
                merged.append(match)
            }
        }
        guard !merged.isEmpty else { return nil }
        var blanked = evidence
        for match in merged.reversed() {
            let range = spans[match.lowerBound].range.lowerBound..<spans[match.upperBound - 1].range.upperBound
            blanked.replaceSubrange(range, with: "___")
        }
        return blanked
    }

    /// Tokenizes `text` into normalized tokens with their original ranges,
    /// mirroring `SolverService.normalizeForSupport` (lowercase, split on
    /// non-alphanumeric boundaries, numeric punctuation kept inside a
    /// number, thousands commas dropped). Each token is lowercased
    /// individually rather than as part of the whole string; the two agree
    /// except for context-sensitive Unicode case mappings.
    private static func normalizedTokenSpans(in text: String) -> [(token: String, range: Range<String.Index>)] {
        var raw: [(String, Range<String.Index>)] = []
        var current = ""
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            let nextIndex = text.index(after: index)
            let next: Character? = nextIndex < text.endIndex ? text[nextIndex] : nil
            if c.isLetter || c.isNumber {
                if start == nil { start = index }
                current.append(c)
            } else if (c == "." || c == "/" || c == ","),
                      current.last?.isNumber == true,
                      let nx = next, nx.isNumber {
                current.append(c)
            } else if let s = start {
                raw.append((current, s..<index))
                current = ""
                start = nil
            }
            index = nextIndex
        }
        if let s = start { raw.append((current, s..<text.endIndex)) }
        var out: [(String, Range<String.Index>)] = []
        for (tok, range) in raw {
            let lowered = tok.lowercased()
            guard lowered.contains(",") else {
                out.append((lowered, range))
                continue
            }
            if SolverService.isThousandsGroupedNumber(lowered) {
                out.append((lowered.filter { $0 != "," }, range))
                continue
            }
            var subStart = range.lowerBound
            var sub = ""
            var subIndex = range.lowerBound
            while subIndex < range.upperBound {
                if text[subIndex] == "," {
                    if !sub.isEmpty {
                        out.append((sub.lowercased(), subStart..<subIndex))
                        sub = ""
                    }
                    subIndex = text.index(after: subIndex)
                    subStart = subIndex
                } else {
                    sub.append(text[subIndex])
                    subIndex = text.index(after: subIndex)
                }
            }
            if !sub.isEmpty { out.append((sub.lowercased(), subStart..<range.upperBound)) }
        }
        return out
    }

    /// Least common multiple that returns nil instead of trapping when
    /// the result overflows Int (denominators are always positive, so
    /// the division is exact and cannot overflow).
    private static func checkedLCM(_ a: Int, _ b: Int) -> Int? {
        let divisor = SolverFraction.gcd(a, b)
        guard divisor != 0 else { return nil }
        let (result, overflow) = (a / divisor).multipliedReportingOverflow(by: b)
        return overflow ? nil : result
    }

    /// Converts `fraction` to `common` denominator, nil on overflow.
    private static func checkedConvert(_ fraction: SolverFraction, common: Int) -> Int? {
        let (scaled, overflow) = fraction.numerator
            .multipliedReportingOverflow(by: common / fraction.denominator)
        return overflow ? nil : scaled
    }
}
