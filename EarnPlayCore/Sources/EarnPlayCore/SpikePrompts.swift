/// The 5 fixed prompts for the T0.2 model-runtime spike (task-card input).
///
/// They are deliberately short tutor-style prompts so a spike run stays
/// fast on CPU. Later tasks replace them with the real prompt structure
/// in LLD section 10; the spike only proves prompt-to-response works.
///
/// Prompt version scheme (T5.3): a prompt set is identified as
/// `"<set-id>-v<major>"`. Bump the major number on any wording or rule
/// change to the set — a changed prompt under an old version makes
/// session stamps and rollback meaningless. Sessions stamp `version`
/// at start (LLD sections 2.2 and 10.3).
public enum SpikePrompts {
    /// Version of this prompt set, stamped on every session record.
    public static let version = "spike-v1"
    public static let all: [String] = [
        "Explain in one short sentence for a 4th grader what a fraction is.",
        "Write a one-sentence story problem about sharing 12 apples equally among 4 friends.",
        "Give one hint, without giving the answer, for solving 7 times 8.",
        "Say one encouraging sentence to a child who tried hard on a difficult problem.",
        "In one sentence, what is 3/4 plus 1/4? Explain simply why.",
    ]
}
