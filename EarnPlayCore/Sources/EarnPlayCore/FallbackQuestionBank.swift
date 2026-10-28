import Foundation

/// Pre-verified safe fallback bank (T1.2, LLD Section 5 step 6).
///
/// Every entry is a hand-written `ProposedProblem` whose prompt text and
/// values were checked by hand, and the bank keeps an entry only after
/// `SolverService` verifies it at bank construction. An entry the solver
/// rejects is dropped, never served. Serving re-verifies through the
/// solver (see `QuestionGenerator`), so a fallback question reaches the
/// child by exactly the same verified path as a model proposal.
///
/// Coverage: every diagnostic skill area from the LLD demo content
/// (multiplication facts to 12x12, multi-digit multiplication, division,
/// fraction comparison and addition, word problems, reading), each in
/// varied real-world or puzzle-like forms. No entry uses `.direct`
/// (plain textbook) form.
public struct FallbackQuestionBank: Equatable, Sendable {
    /// Verified entries, grouped for deterministic round-robin serving.
    public let entries: [ProposedProblem]

    /// Builds a bank, keeping only proposals the solver verifies and only
    /// presentable (non-textbook) forms. Unverifiable or textbook-form
    /// entries are dropped at construction, so they can never be served.
    public init(proposals: [ProposedProblem], solver: SolverService = SolverService()) {
        self.entries = proposals.filter { proposal in
            guard QuestionForms.isPresentable(proposal.form) else { return false }
            guard !proposal.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            if case .success = solver.verify(proposal, questionId: "bank-check") {
                return true
            }
            return false
        }
    }

    public var skillsCovered: Set<SolverSkill> { Set(entries.map(\.skill)) }

    public func entries(for skill: SolverSkill) -> [ProposedProblem] {
        entries.filter { $0.skill == skill }
    }

    /// Deterministic round-robin pick for a skill. Returns nil when the
    /// bank holds no verified entry for the skill.
    public func proposal(for skill: SolverSkill, rotationIndex: Int) -> ProposedProblem? {
        let matching = entries(for: skill)
        guard !matching.isEmpty else { return nil }
        return matching[((rotationIndex % matching.count) + matching.count) % matching.count]
    }

    // MARK: - Demo bank (grade 4)

    public static let demo = FallbackQuestionBank(proposals: demoProposals)

    /// Hand-written, hand-checked entries. The verified answer noted for
    /// each entry is what `SolverService` computes from the values; the
    /// bank tests assert the two agree for every entry.
    public static let demoProposals: [ProposedProblem] = [
        // Multiplication facts to 12x12 — 7 x 8 = 56.
        ProposedProblem(
            skill: .multiplicationFacts, form: .story, operands: [7, 8],
            promptText: "A farmer packs 7 eggs in each carton. She fills 8 cartons for the market. How many eggs did she pack in all?",
            difficulty: 1),
        // Multiplication facts — 6 x 9 = 54; two of the three claims are wrong.
        ProposedProblem(
            skill: .multiplicationFacts, form: .whichIsWrong, operands: [6, 9],
            promptText: "Three friends solved 6 × 9. Ana says 54, Ben says 56, and Cy says 45. Which answer is correct?",
            difficulty: 1),
        // Multiplication facts — 11 x 9 = 99, estimate first.
        ProposedProblem(
            skill: .multiplicationFacts, form: .estimation, operands: [11, 9],
            promptText: "About how many is 11 × 9? First round 11 to 10 and estimate, then give the exact answer.",
            difficulty: 2),

        // Multi-digit multiplication — 24 x 13 = 312.
        ProposedProblem(
            skill: .multiDigitMultiplication, form: .story, operands: [24, 13],
            promptText: "A school prints 24 pages of a workbook for each of its 13 classes. How many pages does it print in all?",
            difficulty: 2),
        // Multi-digit multiplication — 105 x 6 = 630, estimate first.
        ProposedProblem(
            skill: .multiDigitMultiplication, form: .estimation, operands: [105, 6],
            promptText: "A train carries 105 passengers on each trip and makes 6 trips today. About how many passengers is that? Estimate first, then give the exact answer.",
            difficulty: 2),

        // Division — 48 / 8 = 6, worked backwards from the total.
        ProposedProblem(
            skill: .division, form: .reverse, operands: [48, 8],
            promptText: "Leo picked 48 apples and packed 8 into every box, filling each box completely. Work backwards from the total: how many boxes did he fill?",
            difficulty: 1),
        // Division with remainder — 17 / 5 = 3 r 2.
        ProposedProblem(
            skill: .division, form: .story, operands: [17, 5],
            promptText: "Seventeen cookies are shared equally among 5 friends. How many cookies does each friend get, and how many are left over? Answer like: 3 r 2.",
            difficulty: 2),

        // Fraction comparison — 3/4 > 1/2.
        ProposedProblem(
            skill: .fractionComparison, form: .story,
            fractions: [SolverFraction(numerator: 3, denominator: 4)!,
                        SolverFraction(numerator: 1, denominator: 2)!],
            promptText: "Nora ate 3/4 of a small pizza and Sam ate 1/2 of an identical pizza. Who ate more? Answer with <, >, or = comparing 3/4 and 1/2.",
            difficulty: 1),
        // Fraction comparison — 1/3 < 2/3, spot the wrong claim.
        ProposedProblem(
            skill: .fractionComparison, form: .whichIsWrong,
            fractions: [SolverFraction(numerator: 1, denominator: 3)!,
                        SolverFraction(numerator: 2, denominator: 3)!],
            promptText: "Two same-size pies are each cut into 3 equal slices. One friend took 1/3 of a pie and another took 2/3. A classmate says 1/3 is bigger because 3 is the bottom number. Compare 1/3 and 2/3: answer <, >, or =.",
            difficulty: 2),

        // Fraction addition — 1/4 + 1/2 = 3/4.
        ProposedProblem(
            skill: .fractionAddition, form: .story,
            fractions: [SolverFraction(numerator: 1, denominator: 4)!,
                        SolverFraction(numerator: 1, denominator: 2)!],
            promptText: "For a recipe, Priya pours 1/4 cup of milk and then 1/2 cup of milk into a bowl. How much milk is in the bowl in all? Answer as a fraction like 3/4.",
            difficulty: 1),
        // Fraction addition — 1/6 + 1/3 = 1/2; the ribbon length is a distractor.
        ProposedProblem(
            skill: .fractionAddition, form: .irrelevantNumbers,
            fractions: [SolverFraction(numerator: 1, denominator: 6)!,
                        SolverFraction(numerator: 1, denominator: 3)!],
            irrelevantValues: [7],
            promptText: "Tom has a ribbon that is 7 feet long. He drinks 1/6 of a bottle of water in the morning and 1/3 of the bottle in the afternoon. Ignoring the ribbon, how much of the bottle did he drink in all? Answer as a fraction.",
            difficulty: 2),

        // Word problem, multiply — 6 x 7 = 42.
        ProposedProblem(
            skill: .wordProblem, form: .story, operands: [6, 7], operation: .multiply,
            promptText: "A gardener plants 6 rows of tulips with 7 tulips in each row. How many tulips did the gardener plant?",
            difficulty: 1),
        // Word problem, add — 15 + 27 = 42; the 99 stickers are a distractor.
        ProposedProblem(
            skill: .wordProblem, form: .irrelevantNumbers, operands: [15, 27],
            operation: .add, irrelevantValues: [99],
            promptText: "Mia has 99 stickers in a drawer at home. At the fair she wins 15 ribbons on Monday and 27 ribbons on Tuesday. Ignoring the stickers, how many ribbons did she win at the fair?",
            difficulty: 1),
        // Word problem, divide — 36 / 4 = 9, worked backwards from the total.
        ProposedProblem(
            skill: .wordProblem, form: .reverse, operands: [36, 4], operation: .divide,
            promptText: "A teacher shares 36 pencils equally among 4 tables so every table gets the same number. Work backwards from the total: how many pencils does each table get?",
            difficulty: 1),
        // Word problem, subtract — 50 - 18 = 32.
        ProposedProblem(
            skill: .wordProblem, form: .story, operands: [50, 18], operation: .subtract,
            promptText: "A baker made 50 muffins in the morning. By lunch, 18 had been sold. How many muffins were left?",
            difficulty: 1),

        // Reading — the candidate answer is a span of the passage (the
        // solver keeps it only because the passage supports it).
        ProposedProblem(
            skill: .readingComprehension, form: .story,
            passage: "Maya planted twelve sunflower seeds in the garden. Every morning she watered them before school. After three weeks, the first green sprout appeared.",
            candidateAnswer: "twelve sunflower seeds",
            promptText: "Read: Maya planted twelve sunflower seeds in the garden. Every morning she watered them before school. After three weeks, the first green sprout appeared. What did Maya plant in the garden?",
            difficulty: 1),
        // Reading — second passage, answer supported word for word.
        ProposedProblem(
            skill: .readingComprehension, form: .story,
            passage: "The library gave Leo eight new books for the summer. He kept them in a blue box by his bed. He read one book every week.",
            candidateAnswer: "eight new books",
            promptText: "Read: The library gave Leo eight new books for the summer. He kept them in a blue box by his bed. He read one book every week. What did the library give Leo?",
            difficulty: 1),
    ]
}
