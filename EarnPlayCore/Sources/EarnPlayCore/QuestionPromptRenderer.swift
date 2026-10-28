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
            let (product, productOverflow) = a.multipliedReportingOverflow(by: b)
            guard !productOverflow else { return nil }
            return formText(
                problem,
                base: "A stall packs \(a) items in each of \(b) boxes. How many items are there in all?",
                estimation: "About how many is \(a) × \(b)? First estimate by rounding, then give the exact answer.",
                claims: intClaims(
                    intro: "Three friends solved \(a) × \(b).",
                    correct: product))
        case .division:
            guard problem.operands.count == 2, problem.operands[1] != 0 else { return nil }
            let (dividend, divisor) = (problem.operands[0], problem.operands[1])
            let q = dividend / divisor
            let exact = dividend % divisor == 0
            return formText(
                problem,
                base: exact
                    ? "\(dividend) cookies are shared equally among \(divisor) friends. How many cookies does each friend get? Answer with just the quotient as a number."
                    : "\(dividend) cookies are shared equally among \(divisor) friends. How many cookies does each friend get, and how many are left over? Answer as quotient r remainder.",
                reverseBase: exact
                    ? "Work backwards from the total: \(dividend) apples are packed \(divisor) into every box, filling each box completely. How many boxes are filled? Answer with just the quotient as a number."
                    : "Work backwards from the total: \(dividend) apples are packed \(divisor) into every box, filling each box completely. How many boxes are filled, and how many apples are left over? Answer as quotient r remainder.",
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
            var wrongs: [String] = []
            for offset in [1, 2, -1, -2, 3, -3] {
                let (numerator, overflow) = sum.numerator.addingReportingOverflow(offset)
                guard !overflow,
                      let wrong = SolverFraction(numerator: numerator, denominator: sum.denominator),
                      wrong != sum, !wrongs.contains(wrong.description) else { continue }
                wrongs.append(wrong.description)
                if wrongs.count == 2 { break }
            }
            guard wrongs.count == 2 else { return nil }
            return formText(
                problem,
                base: "For a recipe, Priya pours \(f1) cup of milk and then \(f2) cup of milk into a bowl. How much milk is in the bowl in all? Answer as a fraction.",
                estimation: "First estimate the total, then work out \(f1) + \(f2) exactly. Answer as a fraction.",
                claims: "Three friends worked out \(f1) + \(f2). Ana says \(sum.description), Ben says \(wrongs[0]), and Cy says \(wrongs[1]). Which answer is correct?")
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
            let (product, productOverflow) = values[0].multipliedReportingOverflow(by: values[1])
            guard !productOverflow else { return nil }
            return formText(
                problem,
                base: "A gardener plants \(values[0]) rows with \(values[1]) flowers in each row. How many flowers are there in all?",
                estimation: "About how many is \(values[0]) × \(values[1])? First estimate by rounding, then give the exact answer.",
                claims: intClaims(intro: "Three friends solved \(values[0]) × \(values[1]).", correct: product))
        case .divide:
            guard values.count == 2, values[1] != 0 else { return nil }
            let exact = values[0] % values[1] == 0
            return formText(
                problem,
                base: exact
                    ? "\(values[0]) pencils are shared equally among \(values[1]) tables. How many pencils does each table get? Answer with just the quotient as a number."
                    : "\(values[0]) pencils are shared equally among \(values[1]) tables. How many pencils does each table get, and how many are left over? Answer as quotient r remainder.",
                estimation: "About how many is \(values[0]) ÷ \(values[1])? First estimate, then give the exact answer. If there is a remainder, answer as quotient r remainder.",
                claims: intClaims(intro: "Three friends solved \(values[0]) ÷ \(values[1]).", correct: values[0] / values[1],
                                  correctText: SolverService().solve(problem).verifiedText))
        case .add:
            guard values.count >= 2 else { return nil }
            var total = 0
            for value in values {
                let (next, overflow) = total.addingReportingOverflow(value)
                guard !overflow else { return nil }
                total = next
            }
            let list = values.map { "\($0)" }.joined(separator: ", ")
            return formText(
                problem,
                base: "Mia collects shells in rounds of \(list). How many shells does she collect in all?",
                estimation: "First estimate the total, then add \(list) exactly. How many in all?",
                claims: intClaims(intro: "Three friends added \(list).", correct: total))
        case .subtract:
            guard values.count >= 2 else { return nil }
            var result = values[0]
            for value in values.dropFirst() {
                let (next, overflow) = result.subtractingReportingOverflow(value)
                guard !overflow, next >= 0 else { return nil }
                result = next
            }
            let rest = values.dropFirst().map { "\($0)" }.joined(separator: " and then ")
            return formText(
                problem,
                base: "A baker made \(values[0]) muffins. Then \(rest) muffins were sold. How many muffins are left?",
                estimation: "First estimate, then work out \(values[0]) minus \(rest) exactly. How many are left?",
                claims: intClaims(intro: "Three friends worked out \(values[0]) minus \(rest).",
                                  correct: result))
        }
    }

    private static func formText(_ problem: ProposedProblem, base: String,
                                 reverseBase: String? = nil,
                                 estimation: String, claims: String?) -> String? {
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

    private static func intClaims(intro: String, correct: Int, correctText: String? = nil) -> String? {
        var wrongs: [Int] = []
        for offset in [2, 10, -1, 1, -2, 3, -3, 20, -10] {
            let (candidate, overflow) = correct.addingReportingOverflow(offset)
            guard !overflow, candidate >= 0, candidate != correct,
                  !wrongs.contains(candidate) else { continue }
            wrongs.append(candidate)
            if wrongs.count == 2 { break }
        }
        guard wrongs.count == 2 else { return nil }
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
