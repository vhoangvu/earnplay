import Foundation

/// Production `QuestionProposing` source (T1.2): asks the T0.2
/// `ModelRuntime` for one structured problem proposal and parses the
/// reply. The model's own stated answer is never requested and never
/// read — the parser has no answer field for the computed skills, and
/// the reading candidate answer is kept only as the solver's input to
/// its passage-support check (LLD Section 5 steps 1-3).
///
/// An unparseable reply returns nil, which the generation loop counts
/// as one failed attempt. Nothing here presents anything: only
/// `QuestionGenerator`, after solver verification, may do that.
public final class ModelQuestionProposer: QuestionProposing, @unchecked Sendable {
    /// Prompt-set version for question proposals (LLD 10.3 versioning).
    /// Bump the major number on any wording change.
    public static let promptVersion = "question-gen-v1"

    private let generateText: @Sendable (String) throws -> String

    /// Designated initializer: any text generator (kept injectable so the
    /// parser path is testable without a loaded model).
    public init(generateText: @escaping @Sendable (String) throws -> String) {
        self.generateText = generateText
    }

    /// Production initializer over the T0.2 runtime. Each proposal is one
    /// prompt-to-response round-trip, fully on-device.
    public convenience init(runtime: ModelRuntime) {
        self.init(generateText: { prompt in
            try runtime.generate(prompt: prompt, maxTokens: 256).response
        })
    }

    public func propose(request: QuestionGenerationRequest) throws -> ProposedProblem? {
        let response = try generateText(Self.prompt(for: request))
        return ProposedProblemParser.parse(response)
    }

    /// Fixed-structure proposal prompt (LLD 10.1 shape: fixed instruction
    /// block, then the per-call session data). Asks for exactly the
    /// structured fields of `ProposedProblem`, in a varied non-textbook
    /// form, and forbids the model from stating the final answer.
    public static func prompt(for request: QuestionGenerationRequest) -> String {
        let form = (request.formHint ?? .story).rawValue
        return """
        You are a tutor for a grade \(request.grade) child. Propose ONE new practice problem as JSON only, with no other text.

        Rules:
        - Use skill "\(request.skill.rawValue)" and form "\(form)".
        - The form must be a real-world story or puzzle, never a plain textbook drill.
        - Write a short, kind question in "promptText" that matches the values exactly.
        - Do NOT state the final answer anywhere. The answer is computed by a separate checker.
        - For fraction skills, give "fractions" as strings like "3/4".
        - For word problems, give "operation" as one of: add, subtract, multiply, divide.
        - For reading, give a short "passage" and a "candidateAnswer" copied word for word from the passage.
        - Stay inside grade \(request.grade) ranges (multiplication facts up to 12x12).

        Reply with only this JSON shape:
        {"skill":"\(request.skill.rawValue)","form":"\(form)","operands":[0,0],"fractions":[],"operation":null,"irrelevantValues":[],"passage":null,"candidateAnswer":null,"promptText":"...","difficulty":\(request.difficulty),"grade":"\(request.grade)"}
        """
    }
}

/// Parses model text into a `ProposedProblem`. Finds the first balanced
/// JSON object in the text (models often wrap JSON in prose) and decodes
/// it. Returns nil for anything that is not a well-formed proposal with
/// a known skill and form; nil is a failed attempt, never a question.
public enum ProposedProblemParser {
    private struct DTO: Decodable {
        let skill: String
        let form: String
        let operands: [Int]?
        let fractions: [String]?
        let operation: String?
        let irrelevantValues: [Int]?
        let passage: String?
        let candidateAnswer: String?
        let promptText: String
        let difficulty: Int?
        let grade: String?
    }

    public static func parse(_ text: String) -> ProposedProblem? {
        guard let json = firstJSONObject(in: text),
              let data = json.data(using: .utf8),
              let dto = try? JSONDecoder().decode(DTO.self, from: data),
              let skill = SolverSkill(rawValue: dto.skill),
              let form = SolverForm(rawValue: dto.form) else {
            return nil
        }
        var fractions: [SolverFraction] = []
        for raw in dto.fractions ?? [] {
            guard let fraction = SolverFraction(parsing: raw) else { return nil }
            fractions.append(fraction)
        }
        let operation = dto.operation.flatMap { WordOperation(rawValue: $0) }
        if dto.operation != nil, operation == nil { return nil }
        return ProposedProblem(
            skill: skill, form: form, operands: dto.operands ?? [],
            fractions: fractions, operation: operation,
            irrelevantValues: dto.irrelevantValues ?? [],
            passage: dto.passage, candidateAnswer: dto.candidateAnswer,
            promptText: dto.promptText,
            difficulty: dto.difficulty ?? 1, grade: dto.grade ?? "4")
    }

    /// Returns the first balanced `{...}` span, respecting JSON strings
    /// and escapes, or nil when there is no complete object.
    static func firstJSONObject(in text: String) -> String? {
        let chars = Array(text)
        guard let start = chars.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for index in start..<chars.count {
            let c = chars[index]
            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                continue
            }
            switch c {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(chars[start...index]) }
            default: break
            }
        }
        return nil
    }
}
