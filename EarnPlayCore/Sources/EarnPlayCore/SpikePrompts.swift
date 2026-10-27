/// The 5 fixed prompts for the T0.2 model-runtime spike (task-card input).
///
/// They are deliberately short tutor-style prompts so a spike run stays
/// fast on CPU. Later tasks replace them with the real prompt structure
/// in LLD section 10; the spike only proves prompt-to-response works.
public enum SpikePrompts {
    public static let all: [String] = [
        "Explain in one short sentence for a 4th grader what a fraction is.",
        "Write a one-sentence story problem about sharing 12 apples equally among 4 friends.",
        "Give one hint, without giving the answer, for solving 7 times 8.",
        "Say one encouraging sentence to a child who tried hard on a difficult problem.",
        "In one sentence, what is 3/4 plus 1/4? Explain simply why.",
    ]
}
