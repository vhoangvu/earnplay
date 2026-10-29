import SwiftUI
import EarnPlayCore

// MARK: - Turn stream (rendering only)

/// One entry in the chat thread. Every entry comes from the tutor
/// engine's turn stream; the view adds, removes, and decides nothing.
enum ChatTurn: Identifiable, Equatable {
    case tutor(TutorMessage)
    case child(id: String, text: String, isRevision: Bool)

    var id: String {
        switch self {
        case .tutor(let message): return "tutor-\(message.id)"
        case .child(let id, _, _): return "child-\(id)"
        }
    }

    var tutorMessage: TutorMessage? {
        if case .tutor(let message) = self { return message }
        return nil
    }

    var displayedText: String {
        switch self {
        case .tutor(let message): return message.text
        case .child(_, let text, _): return text
        }
    }

    var isTutor: Bool { tutorMessage != nil }
}

/// How the composer collects an answer for the current question.
/// Supplied by the engine with each update, matched to the question
/// type and grade band; the view only renders the supplied form.
enum ChatComposerSpec: Equatable {
    case text
    case numberPad
    case choices([String])
    /// The engine reports the session finished: the view renders a
    /// completion state with a restart action instead of an editable
    /// composer, and the view model refuses further submissions.
    case sessionComplete
}

/// Star progress for the slim header: one star per question, filled as
/// each question is attempted. Counts supplied by the engine.
struct ChatProgress: Equatable {
    var totalQuestions: Int = 0
    var attemptedQuestions: Int = 0
}

/// One engine update applied verbatim by the view model.
struct ChatEngineUpdate: Equatable {
    var turns: [ChatTurn] = []
    var progress: ChatProgress? = nil
    var composer: ChatComposerSpec? = nil
    /// Engine's label for the child's just-submitted turn: true when
    /// the engine treats that submission as a revision of an earlier
    /// answer. The view renders the echo with this label verbatim.
    var submittedTurnIsRevision: Bool = false
}

/// The tutor-engine boundary the chat renders. Implementations own
/// every decision (question flow, answer checking, hints, probes);
/// the view only forwards raw child input and renders returned turns.
///
/// Child input crosses this boundary as plain data (`String`) only.
/// It is never interpreted as instructions by the view, never used to
/// build a prompt in the view, and never rendered as anything other
/// than text (SwiftUI `Text` with a `String` is not executable).
protocol ChatTutorEngine: AnyObject {
    func startSession() -> ChatEngineUpdate
    func submitAnswer(_ plainText: String) -> ChatEngineUpdate
    func requestHint() -> ChatEngineUpdate
}

// MARK: - Untrusted child input

/// Fail-closed handling for child free-text before it leaves the view.
/// Control characters are dropped, length is capped, and the result is
/// still only ever data: a child bubble's text or an engine argument.
/// Unknown or hostile content is never passed through as a command.
enum ChildTextSanitizer {
    static let maxLength = 500

    static func plainText(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) || scalar == "\n" || scalar == "\t"
        }
        let cleaned = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(maxLength))
    }
}

// MARK: - Design tokens (SSOT palette; Band B, grade 4)

enum ChatDesign {
    static let primary = Color(red: 0x43 / 255, green: 0x61 / 255, blue: 0xEE / 255)
    static let secondary = Color(red: 0xFF / 255, green: 0xB7 / 255, blue: 0x03 / 255)
    static let background = Color(red: 0xF7 / 255, green: 0xF8 / 255, blue: 0xFC / 255)
    static let surface = Color.white
    static let text = Color(red: 0x1B / 255, green: 0x1B / 255, blue: 0x2F / 255)
    static let textSecondary = Color(red: 0x6C / 255, green: 0x6C / 255, blue: 0x80 / 255)
    static let cardRadius: CGFloat = 14
    static let buttonRadius: CGFloat = 10
}

// MARK: - View model (no behaviour logic)

/// Holds the rendered thread and forwards intents to the engine.
/// It contains no scoring, timing, answer-checking, hint, probe, or
/// pass/fail logic of any kind.
@MainActor
final class ChatConversationViewModel: ObservableObject {
    @Published private(set) var messages: [ChatTurn] = []
    @Published private(set) var progress = ChatProgress()
    @Published private(set) var composer: ChatComposerSpec = .text
    @Published var draft = ""

    let speech: ReadAloudService
    private let engine: any ChatTutorEngine
    private var childSequence = 0
    private var started = false

    init(engine: any ChatTutorEngine, speech: ReadAloudService) {
        self.engine = engine
        self.speech = speech
    }

    // MARK: Rendering state for tests and the view

    /// Tutor messages in thread order; the view renders one
    /// `SpeakerButton` for each entry of this list.
    var tutorMessages: [TutorMessage] { messages.compactMap(\.tutorMessage) }

    /// Message ids that must carry a speaker button, in thread order.
    var speakerMessageIDs: [String] { tutorMessages.map(\.id) }

    /// True once the engine reports the session complete. The
    /// composer is then replaced by the completion state and every
    /// submission path below refuses to run.
    var isSessionComplete: Bool { composer == .sessionComplete }

    /// Every string the screen renders as text, in layout order:
    /// header is graphical (stars only), then message texts, then
    /// composer chrome. Used by tests to prove no score is displayed.
    var visibleTextStrings: [String] {
        var strings = messages.map(\.displayedText)
        if isSessionComplete {
            strings.append("Practice complete. Nice work.")
            strings.append("Start again")
            return strings
        }
        strings.append("Hint")
        strings.append("Send")
        if case .choices(let options) = composer { strings.append(contentsOf: options) }
        return strings
    }

    // MARK: Lifecycle and intents

    func startIfNeeded() {
        guard !started else { return }
        started = true
        apply(engine.startSession())
    }

    /// Forwards the current draft (or a tapped choice / number-pad
    /// submission) to the engine as plain data and renders its reply.
    func submitDraft() {
        let text = ChildTextSanitizer.plainText(draft)
        guard !text.isEmpty else { return }
        draft = ""
        submit(text: text)
    }

    func submitChoice(_ choice: String) {
        let text = ChildTextSanitizer.plainText(choice)
        guard !text.isEmpty else { return }
        draft = ""
        submit(text: text)
    }

    /// Starts a fresh session after completion: clears the thread
    /// and renders the engine's opening update. The engine owns the
    /// reset of its own question state in `startSession()`.
    func restartSession() {
        guard isSessionComplete else { return }
        messages = []
        draft = ""
        childSequence = 0
        apply(engine.startSession())
    }

    private func submit(text: String) {
        // A completed session has no editable composer; refuse here
        // too so no orphan child bubble can appear behind it.
        guard !isSessionComplete else { return }
        childSequence += 1
        // The child's own words appear in the thread exactly as data.
        // Whether the submission counts as a revision is the engine's
        // call, returned in its update and used as the echo's label.
        let update = engine.submitAnswer(text)
        messages.append(.child(id: "c\(childSequence)", text: text,
                               isRevision: update.submittedTurnIsRevision))
        apply(update)
    }

    /// Hint button: always visible beside the composer while the
    /// session is active, never disabled in the view. Once the
    /// session is complete the button is not rendered, and a stray
    /// call here is refused instead of silently doing nothing.
    func requestHint() {
        guard !isSessionComplete else { return }
        apply(engine.requestHint())
    }

    func apply(_ update: ChatEngineUpdate) {
        for turn in update.turns {
            if case .tutor(let message) = turn {
                // SpeakerButton's integration contract: a NEW
                // question starts a new item, so any reading of the
                // previous question or hint stops before this turn
                // renders. Repeats/updates of a turn already in the
                // thread, and new non-question turns, leave the
                // current reading alone.
                let isNewTurn = !messages.contains(where: { $0.id == turn.id })
                if isNewTurn && message.kind == .question {
                    speech.startNewItem()
                }
                speech.messageDidAppear(message)
                if let index = messages.firstIndex(where: { $0.id == turn.id }) {
                    messages[index] = turn
                    continue
                }
            }
            messages.append(turn)
        }
        if let progress = update.progress { self.progress = progress }
        if let composer = update.composer { self.composer = composer }
    }

    /// Direct scripted-stream entry used by tests and previews: renders
    /// the supplied turns in order, with no engine involvement.
    func apply(turns: [ChatTurn], progress: ChatProgress? = nil, composer: ChatComposerSpec? = nil) {
        apply(ChatEngineUpdate(turns: turns, progress: progress, composer: composer))
    }

    func handleDisappeared() {
        speech.handleViewDisappeared()
    }
}

// MARK: - View (Band B layout per HLD)

struct ChatConversationView: View {
    @StateObject private var viewModel: ChatConversationViewModel

    init(viewModel: ChatConversationViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    init(engine: any ChatTutorEngine) {
        _viewModel = StateObject(wrappedValue: ChatConversationViewModel(
            engine: engine, speech: ReadAloudService(band: GradeBand(grade: "4"))))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            thread
            composerBar
        }
        .background(ChatDesign.background)
        .accessibilityIdentifier("chatConversationView")
        .onAppear { viewModel.startIfNeeded() }
        .onDisappear { viewModel.handleDisappeared() }
    }

    // Slim header: star progress only. No score, clock, or text count.
    private var header: some View {
        HStack(spacing: 4) {
            ForEach(0..<max(0, viewModel.progress.totalQuestions), id: \.self) { index in
                Image(systemName: index < viewModel.progress.attemptedQuestions ? "star.fill" : "star")
                    .foregroundStyle(index < viewModel.progress.attemptedQuestions ? ChatDesign.secondary : ChatDesign.textSecondary)
                    .accessibilityHidden(true)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(ChatDesign.surface)
        .accessibilityIdentifier("chatSessionHeader")
        .accessibilityLabel("Session progress")
        .accessibilityValue("\(viewModel.progress.attemptedQuestions) of \(viewModel.progress.totalQuestions) questions started")
    }

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.messages) { turn in
                        row(for: turn).id(turn.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: viewModel.messages.count) {
                if let last = viewModel.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .accessibilityIdentifier("chatThread")
    }

    @ViewBuilder
    private func row(for turn: ChatTurn) -> some View {
        switch turn {
        case .tutor(let message):
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    // Plain String Text: tutor/model text is data, never
                    // interpreted, linked, or executed.
                    Text(message.text)
                        .font(message.kind == .question ? .title3.weight(.semibold) : .body)
                        .foregroundStyle(ChatDesign.text)
                }
                Spacer(minLength: 8)
                SpeakerButton(message: message, service: viewModel.speech)
            }
            .padding(12)
            .background(ChatDesign.surface)
            .clipShape(RoundedRectangle(cornerRadius: ChatDesign.cardRadius))
            .accessibilityIdentifier("tutorMessage_\(message.id)")
        case .child(let id, let text, _):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(ChatDesign.primary)
                    .clipShape(RoundedRectangle(cornerRadius: ChatDesign.cardRadius))
            }
            .accessibilityIdentifier("childMessage_\(id)")
        }
    }

    @ViewBuilder
    private var composerBar: some View {
        if viewModel.isSessionComplete {
            completionBar
        } else {
            activeComposerBar
        }
    }

    // Session-complete state: no editable composer, no Hint/Send.
    // The only action offered starts a fresh session.
    private var completionBar: some View {
        VStack(spacing: 8) {
            Text("Practice complete. Nice work.")
                .font(.body.weight(.semibold))
                .foregroundStyle(ChatDesign.text)
            Button("Start again") { viewModel.restartSession() }
                .buttonStyle(.borderedProminent)
                .tint(ChatDesign.primary)
                .frame(minHeight: 44)
                .accessibilityIdentifier("chatRestartButton")
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(ChatDesign.surface)
        .accessibilityIdentifier("chatSessionComplete")
    }

    private var activeComposerBar: some View {
        VStack(spacing: 8) {
            if case .choices(let options) = viewModel.composer {
                HStack(spacing: 8) {
                    ForEach(options, id: \.self) { option in
                        Button(option) { viewModel.submitChoice(option) }
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("chatChoice_\(option)")
                    }
                }
            }
            if viewModel.composer == .numberPad {
                numberPad
            }
            HStack(alignment: .bottom, spacing: 8) {
                // Hint is always visible beside the composer, never disabled.
                Button {
                    viewModel.requestHint()
                } label: {
                    Label("Hint", systemImage: "lightbulb")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(ChatDesign.primary)
                .accessibilityIdentifier("chatHintButton")

                TextField("Type your answer", text: $viewModel.draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("chatComposerField")
                    .onSubmit { viewModel.submitDraft() }

                Button("Send") { viewModel.submitDraft() }
                    .buttonStyle(.borderedProminent)
                    .tint(ChatDesign.primary)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("chatSendButton")
            }
        }
        .padding(12)
        .background(ChatDesign.surface)
    }

    private var numberPad: some View {
        let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "/", "0", "⌫"]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
            ForEach(keys, id: \.self) { key in
                Button(key) {
                    if key == "⌫" {
                        if !viewModel.draft.isEmpty { viewModel.draft.removeLast() }
                    } else {
                        viewModel.draft += key
                    }
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityIdentifier("chatNumberPad_\(key)")
            }
        }
        .accessibilityIdentifier("chatNumberPad")
    }
}
