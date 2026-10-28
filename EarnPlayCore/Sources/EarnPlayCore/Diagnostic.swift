import Foundation

/// Diagnostic engine (T1.1, LLD TutorEngine: "runs the diagnostic at
/// session start"; HLD: diagnostic "sets the starting difficulty for
/// math and reading"; LLD S5 demo content: "The diagnostic item set is
/// 10 minutes across facts fluency, fractions, word problems, reading
/// fluency, and comprehension.").
///
/// Design:
/// - Deterministic. Every presented item is verified through
///   `SolverService` (T0.3) before presentation; an item the solver
///   rejects is skipped, never presented. No model inference is used:
///   T1.2 owns model-proposed generation; the diagnostic uses the
///   pre-written grade-4 bank below as its safe item set (LLD S5 step 6
///   pattern), each item still re-verified at session start.
/// - Adaptive staircase per area: difficulty 1...3, correct steps up,
///   incorrect steps down. The resulting `recommendedDifficulty` is the
///   starting difficulty the tutor (T1.2) uses.
/// - Time-boxed: `timeBudgetSeconds` defaults to 600 (10 minutes).
///   When the budget is exhausted the session finishes with whatever
///   areas were assessed; unassessed areas stay `.notAssessed`.
///
/// Profile schema note: the LLD names `Session.skillProfileSnapshot`
/// (a Record copy + `grade`) but defines no field list for the profile
/// itself. `SkillProfile` below is that missing schema, kept
/// grade-agnostic per LLD S2 ("supporting a new grade means adding a
/// content pack, not schema changes"). See Docs/Diagnostic.md.
public enum DiagnosticArea: String, Codable, Sendable, CaseIterable {
    case factsFluency
    case fractions
    case wordProblems
    case readingFluency
    case comprehension

    /// Solver skills this area probes. Reading areas both use the
    /// passage-supported reading skill; they differ in what is scored
    /// (fluency weights response latency, comprehension does not).
    public var solverSkills: [SolverSkill] {
        switch self {
        case .factsFluency: return [.multiplicationFacts]
        case .fractions: return [.fractionComparison, .fractionAddition]
        case .wordProblems: return [.wordProblem]
        case .readingFluency, .comprehension: return [.readingComprehension]
        }
    }

    /// True when response latency is part of the proficiency judgement.
    public var isFluencyTimed: Bool { self == .factsFluency || self == .readingFluency }
}

public enum DiagnosticLevel: String, Codable, Sendable {
    case notAssessed
    case emerging
    case developing
    case proficient
}

/// Per-area estimate inside a `SkillProfile`.
public struct SkillEstimate: Codable, Equatable, Sendable {
    public var area: DiagnosticArea
    public var level: DiagnosticLevel
    /// Accuracy 0...1 over attempted items; 0 when nothing attempted.
    public var accuracy: Double
    public var itemsAttempted: Int
    public var itemsCorrect: Int
    /// Median response latency in ms; nil when nothing attempted.
    public var medianResponseMs: Int?
    /// Staircase difficulty the tutor should start from (1...3);
    /// 1 when not assessed.
    public var recommendedDifficulty: Int

    public init(area: DiagnosticArea, level: DiagnosticLevel = .notAssessed,
                accuracy: Double = 0, itemsAttempted: Int = 0, itemsCorrect: Int = 0,
                medianResponseMs: Int? = nil, recommendedDifficulty: Int = 1) {
        self.area = area
        self.level = level
        self.accuracy = accuracy
        self.itemsAttempted = itemsAttempted
        self.itemsCorrect = itemsCorrect
        self.medianResponseMs = medianResponseMs
        self.recommendedDifficulty = recommendedDifficulty
    }
}

/// The skill profile the diagnostic produces and the tutor reads.
///
/// `grade` is a content parameter, not a schema assumption (LLD S2):
/// demo value "4". `estimates` always contains all five areas after a
/// completed (or partially completed) session; areas never reached
/// keep `.notAssessed` so downstream code can tell "weak" from
/// "unknown" and must not treat unknown as weak.
public struct SkillProfile: Codable, Equatable, Sendable {
    public var grade: String
    public var estimates: [SkillEstimate]
    public var diagnosticSessionId: String
    public var completedAt: Date
    /// False when the session ended early (time budget or abandon):
    /// some areas may be `.notAssessed`.
    public var isComplete: Bool

    public init(grade: String, estimates: [SkillEstimate], diagnosticSessionId: String,
                completedAt: Date, isComplete: Bool) {
        self.grade = grade
        self.estimates = estimates
        self.diagnosticSessionId = diagnosticSessionId
        self.completedAt = completedAt
        self.isComplete = isComplete
    }

    public func estimate(for area: DiagnosticArea) -> SkillEstimate {
        estimates.first { $0.area == area } ?? SkillEstimate(area: area)
    }

    /// Weakest assessed area — the tutor's next focus. Nil when no
    /// area was assessed (empty session): the tutor must re-run or
    /// start the diagnostic, not guess a focus.
    public var nextFocusArea: DiagnosticArea? {
        let assessed = estimates.filter { $0.level != .notAssessed }
        // Rank by proficiency level first (weakest level wins), then by
        // accuracy: latency can make an all-correct area `developing`
        // while another all-correct area is `proficient`.
        func rank(_ level: DiagnosticLevel) -> Int {
            switch level {
            case .emerging: return 0
            case .developing: return 1
            case .proficient: return 2
            case .notAssessed: return 3
            }
        }
        return assessed.min(by: {
            let lhs = rank($0.level), rhs = rank($1.level)
            if lhs != rhs { return lhs < rhs }
            return $0.accuracy < $1.accuracy
        })?.area
    }

    /// Starting difficulty for T1.2 question generation in `area`.
    public func recommendedDifficulty(for area: DiagnosticArea) -> Int {
        estimate(for: area).recommendedDifficulty
    }
}

/// One bank item before solver verification.
public struct DiagnosticBankItem: Sendable {
    public var area: DiagnosticArea
    public var problem: ProposedProblem
    public init(area: DiagnosticArea, problem: ProposedProblem) {
        self.area = area
        self.problem = problem
    }
}

/// A presented diagnostic item: solver-verified, safe to show.
public struct DiagnosticItem: Equatable, Sendable {
    public var question: VerifiedQuestion
    public var area: DiagnosticArea
    public var difficulty: Int
}

/// Recorded response to one presented item.
public struct DiagnosticResponse: Equatable, Sendable {
    public var questionId: String
    public var area: DiagnosticArea
    public var difficulty: Int
    public var correct: Bool
    public var responseMs: Int
}

public enum DiagnosticSessionState: Equatable, Sendable {
    case notStarted
    case inProgress
    case completed
    case abandoned
}

/// Session flow for one ~10-minute diagnostic.
///
/// Usage: `start()` -> repeat `currentItem` / `submit(answer:responseMs:)`
/// until `state == .completed`, then `profile()`. `abandon()` ends
/// early and `profile()` still returns the partial profile.
/// Time is injected (`now`) so tests drive the budget deterministically.
public final class DiagnosticSession: @unchecked Sendable {
    public let sessionId: String
    public let grade: String
    public let timeBudgetSeconds: Int
    public private(set) var state: DiagnosticSessionState = .notStarted
    public private(set) var responses: [DiagnosticResponse] = []

    private let solver: SolverService
    private let bank: [DiagnosticBankItem]
    private let now: () -> Date
    private var startedAt: Date?
    private var queues: [DiagnosticArea: [DiagnosticItem]] = [:]
    private var staircase: [DiagnosticArea: Int] = [:]
    private var pending: DiagnosticItem?
    /// Index into `DiagnosticArea.allCases` where the next `advance()`
    /// starts scanning; rotated after each selection (round-robin).
    private var nextAreaIndex: Int = 0
    /// Items required per area for the session to count as complete.
    public let itemsPerArea: [DiagnosticArea: Int]

    public init(sessionId: String = UUID().uuidString, grade: String = "4",
                solver: SolverService = SolverService(),
                bank: [DiagnosticBankItem] = DiagnosticBank.grade4,
                timeBudgetSeconds: Int = 600,
                itemsPerArea: [DiagnosticArea: Int] = DiagnosticSession.defaultItemsPerArea,
                now: @escaping () -> Date = Date.init) {
        self.sessionId = sessionId
        self.grade = grade
        self.solver = solver
        self.bank = bank
        self.timeBudgetSeconds = timeBudgetSeconds
        self.itemsPerArea = itemsPerArea
        self.now = now
    }

    public static let defaultItemsPerArea: [DiagnosticArea: Int] = [
        .factsFluency: 6, .fractions: 5, .wordProblems: 4,
        .readingFluency: 3, .comprehension: 4,
    ]

    /// Verifies the whole bank through the solver and builds per-area
    /// queues ordered easy -> hard. Unverifiable items are dropped.
    public func start() {
        guard state == .notStarted else { return }
        startedAt = now()
        for area in DiagnosticArea.allCases {
            staircase[area] = 2
            var verified: [DiagnosticItem] = []
            for item in bank where item.area == area {
                let qid = "\(sessionId)-\(area.rawValue)-\(verified.count)"
                if case .success(let q) = solver.verify(item.problem, questionId: qid) {
                    verified.append(DiagnosticItem(question: q, area: area, difficulty: item.problem.difficulty))
                }
            }
            queues[area] = verified.sorted { $0.difficulty < $1.difficulty }
        }
        state = .inProgress
        advance()
    }

    /// The item awaiting an answer; nil when finished.
    public var currentItem: DiagnosticItem? { pending }

    public var isTimeExhausted: Bool {
        guard let startedAt else { return false }
        return now().timeIntervalSince(startedAt) >= Double(timeBudgetSeconds)
    }

    /// Deadline-aware completion path: callers (e.g. a UI timer) can
    /// finish the session when the budget expires without answering
    /// the pending item. Returns true only when this call completed
    /// the session; a no-op (false) when not expired or not in progress.
    @discardableResult
    public func expireIfNeeded() -> Bool {
        guard state == .inProgress, isTimeExhausted else { return false }
        pending = nil
        state = .completed
        return true
    }

    /// Judges the answer against the solver-verified answer (never a
    /// model answer), records it, steps the staircase, and advances.
    /// Submissions after the time budget are rejected before grading
    /// or any profile update, and complete the session instead.
    @discardableResult
    public func submit(answer: String, responseMs: Int) -> Bool {
        guard state == .inProgress, let item = pending else { return false }
        guard !expireIfNeeded() else { return false }
        let correct = solver.checkAnswer(item.question, proposedAnswer: answer) == .correct
        responses.append(DiagnosticResponse(questionId: item.question.questionId,
                                            area: item.area, difficulty: item.difficulty,
                                            correct: correct, responseMs: max(0, responseMs)))
        let step = correct ? 1 : -1
        staircase[item.area] = min(3, max(1, (staircase[item.area] ?? 2) + step))
        pending = nil
        advance()
        return correct
    }

    /// Ends the session early; `profile()` returns partial results.
    public func abandon() {
        guard state == .inProgress || state == .notStarted else { return }
        pending = nil
        state = .abandoned
    }

    private func needsMore(_ area: DiagnosticArea) -> Bool {
        let done = responses.count { $0.area == area }
        return done < (itemsPerArea[area] ?? 0) && !(queues[area] ?? []).isEmpty
    }

    private func advance() {
        if expireIfNeeded() { return }
        // Round-robin across areas so a time cut still samples broadly:
        // start scanning at `nextAreaIndex` and rotate it past the area
        // just selected, so each eligible area gets a turn before repeating.
        let areas = DiagnosticArea.allCases
        for offset in 0..<areas.count {
            let areaIndex = (nextAreaIndex + offset) % areas.count
            let area = areas[areaIndex]
            guard needsMore(area) else { continue }
            guard var queue = queues[area], !queue.isEmpty else { continue }
            let target = staircase[area] ?? 2
            let index = queue.indices.min(by: {
                abs(queue[$0].difficulty - target) < abs(queue[$1].difficulty - target)
            }) ?? 0
            pending = queue.remove(at: index)
            queues[area] = queue
            nextAreaIndex = (areaIndex + 1) % areas.count
            return
        }
        state = .completed
        pending = nil
    }

    /// Builds the profile. Callable in any state; before `start()` it
    /// returns an all-`.notAssessed`, incomplete profile (empty session).
    public func profile() -> SkillProfile {
        var estimates: [SkillEstimate] = []
        for area in DiagnosticArea.allCases {
            let rs = responses.filter { $0.area == area }
            guard !rs.isEmpty else {
                estimates.append(SkillEstimate(area: area))
                continue
            }
            let correct = rs.count { $0.correct }
            let accuracy = Double(correct) / Double(rs.count)
            let sortedMs = rs.map(\.responseMs).sorted()
            // Even-sized samples average the two middle values.
            let median = sortedMs.count % 2 == 1
                ? sortedMs[sortedMs.count / 2]
                : (sortedMs[sortedMs.count / 2 - 1] + sortedMs[sortedMs.count / 2]) / 2
            estimates.append(SkillEstimate(
                area: area, level: Self.level(area: area, accuracy: accuracy, medianMs: median),
                accuracy: accuracy, itemsAttempted: rs.count, itemsCorrect: correct,
                medianResponseMs: median,
                recommendedDifficulty: staircase[area] ?? 1))
        }
        // Complete only when every area met its quota; merely having
        // been assessed once (e.g. a timeout or a solver-reduced bank)
        // is not completion.
        let complete = state == .completed && estimates.allSatisfy {
            $0.itemsAttempted >= (itemsPerArea[$0.area] ?? 0)
        }
        return SkillProfile(grade: grade, estimates: estimates,
                            diagnosticSessionId: sessionId, completedAt: now(),
                            isComplete: complete)
    }

    /// Proficiency thresholds. Fluency areas additionally require the
    /// median response to be brisk; slow-but-accurate is `developing`,
    /// because fluency means accurate *and* fluent.
    static func level(area: DiagnosticArea, accuracy: Double, medianMs: Int) -> DiagnosticLevel {
        guard accuracy >= 0.5 else { return .emerging }
        if accuracy >= 0.8 {
            if area.isFluencyTimed && medianMs > 8_000 { return .developing }
            return .proficient
        }
        return .developing
    }
}

// MARK: - Persistence

public protocol SkillProfileStore: Sendable {
    func save(_ profile: SkillProfile) throws
    func load() throws -> SkillProfile?
}

/// File-backed profile store (JSON, on-device only per LLD S13).
public struct FileSkillProfileStore: SkillProfileStore {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func save(_ profile: SkillProfile) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(profile)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
    }

    public func load() throws -> SkillProfile? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SkillProfile.self, from: data)
    }
}

// MARK: - Grade-4 bank (pre-written safe items; solver re-verifies each)

public enum DiagnosticBank {
    private static func p(_ skill: SolverSkill, _ area: DiagnosticArea,
                          operands: [Int] = [], fractions: [SolverFraction] = [],
                          operation: WordOperation? = nil, passage: String? = nil,
                          candidate: String? = nil, prompt: String,
                          difficulty: Int) -> DiagnosticBankItem {
        DiagnosticBankItem(area: area, problem: ProposedProblem(
            skill: skill, operands: operands, fractions: fractions, operation: operation,
            passage: passage, candidateAnswer: candidate,
            promptText: prompt, difficulty: difficulty, grade: "4"))
    }

    private static func f(_ n: Int, _ d: Int) -> SolverFraction {
        SolverFraction(numerator: n, denominator: d)!
    }

    static let passageA = "Mia planted 12 tomato seeds in her garden. After two weeks, 9 of the seeds had sprouted. She watered the garden every morning before school."
    static let passageB = "The class library has 48 books on the top shelf. Mr. Lee moved 16 of them to a reading corner so students could reach them easily."

    public static let grade4: [DiagnosticBankItem] = [
        // Facts fluency (multiplication facts to 12x12)
        p(.multiplicationFacts, .factsFluency, operands: [3, 4], prompt: "3 × 4 = ?", difficulty: 1),
        p(.multiplicationFacts, .factsFluency, operands: [6, 5], prompt: "6 × 5 = ?", difficulty: 1),
        p(.multiplicationFacts, .factsFluency, operands: [7, 8], prompt: "7 × 8 = ?", difficulty: 2),
        p(.multiplicationFacts, .factsFluency, operands: [9, 6], prompt: "9 × 6 = ?", difficulty: 2),
        p(.multiplicationFacts, .factsFluency, operands: [8, 8], prompt: "8 × 8 = ?", difficulty: 3),
        p(.multiplicationFacts, .factsFluency, operands: [12, 7], prompt: "12 × 7 = ?", difficulty: 3),
        // Fractions (comparison + addition)
        p(.fractionComparison, .fractions, fractions: [f(1, 2), f(1, 4)], prompt: "Which is larger, 1/2 or 1/4? Answer <, >, or =", difficulty: 1),
        p(.fractionAddition, .fractions, fractions: [f(1, 4), f(1, 4)], prompt: "1/4 + 1/4 = ?", difficulty: 1),
        p(.fractionComparison, .fractions, fractions: [f(2, 3), f(3, 4)], prompt: "Which is larger, 2/3 or 3/4? Answer <, >, or =", difficulty: 2),
        p(.fractionAddition, .fractions, fractions: [f(1, 3), f(1, 6)], prompt: "1/3 + 1/6 = ?", difficulty: 2),
        p(.fractionAddition, .fractions, fractions: [f(3, 8), f(1, 4)], prompt: "3/8 + 1/4 = ?", difficulty: 3),
        // Word problems
        p(.wordProblem, .wordProblems, operands: [24, 18], operation: .add, prompt: "Sam had 24 marbles and bought 18 more. How many marbles does Sam have now?", difficulty: 1),
        p(.wordProblem, .wordProblems, operands: [56, 19], operation: .subtract, prompt: "A baker made 56 rolls and sold 19. How many rolls are left?", difficulty: 1),
        p(.wordProblem, .wordProblems, operands: [7, 6], operation: .multiply, prompt: "There are 7 bags with 6 oranges in each bag. How many oranges are there in all?", difficulty: 2),
        p(.wordProblem, .wordProblems, operands: [48, 6], operation: .divide, prompt: "48 stickers are shared equally among 6 friends. How many stickers does each friend get?", difficulty: 2),
        // Reading fluency (literal recall, latency scored)
        p(.readingComprehension, .readingFluency, passage: passageA, candidate: "12", prompt: "Read: \(passageA)\nHow many tomato seeds did Mia plant?", difficulty: 1),
        p(.readingComprehension, .readingFluency, passage: passageA, candidate: "9", prompt: "Read: \(passageA)\nHow many seeds had sprouted after two weeks?", difficulty: 2),
        p(.readingComprehension, .readingFluency, passage: passageB, candidate: "48", prompt: "Read: \(passageB)\nHow many books are on the top shelf?", difficulty: 1),
        // Comprehension (passage-supported answers)
        p(.readingComprehension, .comprehension, passage: passageA, candidate: "every morning", prompt: "Read: \(passageA)\nWhen did Mia water the garden?", difficulty: 1),
        p(.readingComprehension, .comprehension, passage: passageB, candidate: "16", prompt: "Read: \(passageB)\nHow many books did Mr. Lee move?", difficulty: 1),
        p(.readingComprehension, .comprehension, passage: passageB, candidate: "reading corner", prompt: "Read: \(passageB)\nWhere did Mr. Lee move the books?", difficulty: 2),
        p(.readingComprehension, .comprehension, passage: passageA, candidate: "tomato seeds", prompt: "Read: \(passageA)\nWhat did Mia plant in her garden?", difficulty: 2),
    ]
}
