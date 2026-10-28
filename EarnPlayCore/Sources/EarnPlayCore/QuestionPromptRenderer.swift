import Foundation

/// Renders the displayed question text from validated structured values
/// (Copilot round-1 F1). The generation loop never presents a proposer's
/// free-form `promptText` for a computed skill: it presents only text
/// rendered here from the same operands/fractions the solver computes
/// from, so displayed wording and verified answer cannot diverge.
/// Returns nil when the proposal shape cannot be rendered (invalid
/// operand/fraction counts — the solver then rejects it) and for
/// reading, where the loop instead enforces that the presented text
/// contains the supporting passage verbatim.
public enum QuestionPromptRenderer {
    public static func render(_ problem: ProposedProblem) -> String? {
        switch problem.skill {
        case .readingComprehension:
            return nil
        case .multiplicationFacts, .multiDigitMultiplication:
            guard problem.operands.count == 2 else { return nil }
            let (a, b) = (problem.operands[0], problem.operands[1])
            return formText(
                problem,
                base: "A stall packs \(a) items in each of \(b) boxes. How many items are there in all?",
                estimation: "About how many is \(a) × \(b)? First estimate by rounding, then give the exact answer.",
                claims: intClaims(
                    intro: "Three friends solved \(a) × \(b).",
                    correct: a * b))
        case .division:
            guard problem.operands.count == 2, problem.operands[1] != 0 else { return nil }
            let (dividend, divisor) = (problem.operands[0], problem.operands[1])
            let q = dividend / divisor
            return formText(
                problem,
                base: "\(dividend) cookies are shared equally among \(divisor) friends. How many cookies does each friend get, and how many are left over? Answer as quotient r remainder.",
                reverseBase: "Work backwards from the total: \(dividend) apples are packed \(divisor) into every box, filling each box completely. How many boxes are filled, and how many apples are left over? Answer as quotient r remainder.",
                estimation: "About how many is \(dividend) ÷ \(divisor)? First estimate, then give the exact answer. If there is a remainder, answer as quotient r remainder.",
                claims: intClaims(
                    intro: "Three friends solved \(dividend) ÷ \(divisor).",
                    correct: q,
                    correctText: SolverService().solve(problem).verifiedText))
        case .fractionComparison:
            guard problem.fractions.count == 2 else { return nil }
            let (f1, f2) = (problem.fractions[0].description, problem.fractions[1].description)
            return formText(
                problem,
                base: "Nora ate \(f1) of a small pizza and Sam ate \(f2) of an identical pizza. Who ate more? Answer with <, >, or = comparing \(f1) and \(f2).",
                estimation: "First estimate which fraction is larger, then compare \(f1) and \(f2). Answer with <, >, or =.",
                claims: "A classmate says the first fraction is always bigger because of its bottom number. Compare \(f1) and \(f2): answer with <, >, or =.")
        case .fractionAddition:
            guard problem.fractions.count == 2,
                  let sum = problem.fractions[0] + problem.fractions[1] else { return nil }
            let (f1, f2) = (problem.fractions[0].description, problem.fractions[1].description)
            let wrong1 = SolverFraction(numerator: sum.numerator + 1, denominator: sum.denominator)?.description ?? f1
            let wrong2 = SolverFraction(numerator: sum.numerator + 2, denominator: sum.denominator)?.description ?? f2
            return formText(
                problem,
                base: "For a recipe, Priya pours \(f1) cup of milk and then \(f2) cup of milk into a bowl. How much milk is in the bowl in all? Answer as a fraction.",
                estimation: "First estimate the total, then work out \(f1) + \(f2) exactly. Answer as a fraction.",
                claims: "Three friends worked out \(f1) + \(f2). Ana says \(sum.description), Ben says \(wrong1), and Cy says \(wrong2). Which answer is correct?")
        case .wordProblem:
            guard let operation = problem.operation else { return nil }
            return wordText(problem, operation: operation)
        }
    }

    private static func wordText(_ problem: ProposedProblem, operation: WordOperation) -> String? {
        let values = problem.operands
        switch operation {
        case .multiply:
            guard values.count == 2 else { return nil }
            return formText(
                problem,
                base: "A gardener plants \(values[0]) rows with \(values[1]) flowers in each row. How many flowers are there in all?",
                estimation: "About how many is \(values[0]) × \(values[1])? First estimate by rounding, then give the exact answer.",
                claims: intClaims(intro: "Three friends solved \(values[0]) × \(values[1]).", correct: values[0] * values[1]))
        case .divide:
            guard values.count == 2, values[1] != 0 else { return nil }
            return formText(
                problem,
                base: "\(values[0]) pencils are shared equally among \(values[1]) tables. How many pencils does each table get, and how many are left over? Answer as quotient r remainder.",
                estimation: "About how many is \(values[0]) ÷ \(values[1])? First estimate, then give the exact answer. If there is a remainder, answer as quotient r remainder.",
                claims: intClaims(intro: "Three friends solved \(values[0]) ÷ \(values[1]).", correct: values[0] / values[1],
                                  correctText: SolverService().solve(problem).verifiedText))
        case .add:
            guard values.count >= 2 else { return nil }
            let list = values.map { "\($0)" }.joined(separator: ", ")
            return formText(
                problem,
                base: "Mia collects shells in rounds of \(list). How many shells does she collect in all?",
                estimation: "First estimate the total, then add \(list) exactly. How many in all?",
                claims: intClaims(intro: "Three friends added \(list).", correct: values.reduce(0, +)))
        case .subtract:
            guard values.count >= 2 else { return nil }
            let rest = values.dropFirst().map { "\($0)" }.joined(separator: " and then ")
            return formText(
                problem,
                base: "A baker made \(values[0]) muffins. Then \(rest) muffins were sold. How many muffins are left?",
                estimation: "First estimate, then work out \(values[0]) minus \(rest) exactly. How many are left?",
                claims: intClaims(intro: "Three friends worked out \(values[0]) minus \(rest).",
                                  correct: values.dropFirst().reduce(values[0], -)))
        }
    }

    private static func formText(_ problem: ProposedProblem, base: String,
                                 reverseBase: String? = nil,
                                 estimation: String, claims: String) -> String {
        switch problem.form {
        case .story, .direct:
            return base
        case .reverse:
            return reverseBase ?? "Work backwards. \(base)"
        case .estimation:
            return estimation
        case .whichIsWrong:
            return claims
        case .irrelevantNumbers:
            guard !problem.irrelevantValues.isEmpty else { return base }
            let distractors = problem.irrelevantValues.map { "\($0)" }.joined(separator: ", ")
            return "There are \(distractors) unrelated items on the table. Ignore them. \(base)"
        }
    }

    private static func intClaims(intro: String, correct: Int, correctText: String? = nil) -> String {
        var wrongs: [Int] = []
        for candidate in [correct + 2, correct + 10, correct - 1, correct + 1, correct - 2]
        where candidate >= 0 && candidate != correct && !wrongs.contains(candidate) {
            wrongs.append(candidate)
            if wrongs.count == 2 { break }
        }
        let correctShown = correctText ?? "\(correct)"
        return "\(intro) Ana says \(correctShown), Ben says \(wrongs[0]), and Cy says \(wrongs[1]). Which answer is correct?"
    }
}

private extension SolverOutcome {
    var verifiedText: String? {
        if case .verified(let answer) = self { return answer }
        return nil
    }
}
