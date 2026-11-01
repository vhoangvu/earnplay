import SwiftUI
import Combine
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
    /// Ends the active session (the practice view disappeared): the
    /// engine finalizes any unfinished recording. Default is a no-op.
    func endSession()
    /// Resumes after reappearance (round 2 item 3): the engine starts a
    /// fresh recording session for the continued run when the prior one
    /// was finalized mid-run via `endSession`. No-op when recording is
    /// disabled, already active, or the session is complete (restart
    /// owns that). Default is a no-op.
    func resumeSession()
    /// Composer activity (a keystroke, number-pad tap, or draft edit):
    /// the engine records a timing anchor on the current question, never
    /// an attempt or hint count. Default is a no-op.
    func recordComposerActivity()
    /// The CURRENT session's hint-listen sink (round 2 item 5, round 3
    /// item 2): the live session recorder while a session is actively
    /// recording, nil when recording is disabled, no session is active,
    /// input is blocked awaiting persistence, or the session already
    /// finished — so a stale recorder never receives events for
    /// a new session. Default is nil.
    var currentHintListenSink: (any HintListenEventSink)? { get }
    /// True while the engine blocks input awaiting persistence (round 3
    /// item 1): a mid-run resume whose pending-log retry still failed. The
    /// view model renders the session-complete state (which refuses all
    /// submissions) until the block lifts. Default is false.
    var isInputBlocked: Bool { get }
}

extension ChatTutorEngine {
    func endSession() {}
    func resumeSession() {}
    func recordComposerActivity() {}
    var currentHintListenSink: (any HintListenEventSink)? { nil }
    var isInputBlocked: Bool { false }
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

// MARK: - Design tokens (T7.8)
//
// Colors and radii come from the switchable `DesignSystem` theme in
// EarnPlayCore (SSOT); no hardcoded color literal may live in this
// target. The view renders `theme` (default Canonical rounded): callers
// pass the app ThemeStore's current theme for live switching.

// MARK: - View model (no behaviour logic)

/// Forwards hint-listen events to the engine's CURRENT session recorder
/// (round 2 item 5). Retained by the view model and installed as the
/// speech service's (weak) sink; every event resolves the live session
/// at delivery time, so a stale recorder never receives events for a new
/// session across restarts, and an ended session receives nothing.
private final class CurrentSessionHintListenForwarder: HintListenEventSink {
    private let resolve: () -> (any HintListenEventSink)?
    init(resolve: @escaping () -> (any HintListenEventSink)?) {
        self.resolve = resolve
    }
    func recordHintListen(_ event: HintListenEvent) {
        resolve()?.recordHintListen(event)
    }
}

/// Holds the rendered thread and forwards intents to the engine.
/// It contains no scoring, timing, answer-checking, hint, probe, or
/// pass/fail logic of any kind.
@MainActor
final class ChatConversationViewModel: ObservableObject {
    @Published private(set) var messages: [ChatTurn] = []
    @Published private(set) var progress = ChatProgress()
    @Published private(set) var composer: ChatComposerSpec = .text
    /// Every mutation (typing, number-pad taps, backspace, the
    /// submit clear) is composer activity: forwarded to the engine as a
    /// timing anchor. The submit clear coincides with the submission's
    /// own anchor, so it adds no time.
    @Published var draft = "" {
        didSet { engine.recordComposerActivity() }
    }
    /// Mirrors `speech.isVoiceUnavailable` so the thread can show a
    /// plain notice when no bundled voice is available.
    @Published private(set) var isVoiceUnavailable = false

    let speech: ReadAloudService
    private let engine: any ChatTutorEngine
    private var childSequence = 0
    private var started = false
    /// Set when the view disappears mid-session (round 2 item 3): the
    /// next appearance resumes a fresh recording session for the
    /// continued run, so no answer is accepted without an active
    /// recording. Never set for a completed session (restart owns that).
    private var needsResumeAfterDisappear = false
    private let hintListenForwarder: CurrentSessionHintListenForwarder
    private var cancellable: AnyCancellable?

    init(engine: any ChatTutorEngine, speech: ReadAloudService) {
        self.engine = engine
        self.speech = speech
        // Round 2 item 5, round 3 item 2: successful hint playback reaches
        // the CURRENT session's recorder (question timing anchor + listen
        // effort; the recorder's `recordHintListen` never touches
        // `hintsUsed`, which stays tied to ladder-show events). The
        // forwarder resolves the live session per event, tracking restarts
        // with no manual re-wiring and never delivering to a stale recorder.
        let forwarder = CurrentSessionHintListenForwarder { [engine] in
            engine.currentHintListenSink
        }
        self.hintListenForwarder = forwarder
        speech.hintListenSink = forwarder
        cancellable = speech.$isVoiceUnavailable.sink { [weak self] in self?.isVoiceUnavailable = $0 }
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
        if isVoiceUnavailable { strings.append("Reading is unavailable on this device right now. You can still read the messages.") }
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
        if started {
            // Reappearance after a mid-session disappearance (round 2
            // item 3, round 3 item 1): resume a fresh recording session
            // for the continued run. A drained resume is recording-only —
            // no thread/progress/composer change — so the decision stays
            // at the engine/view-model boundary and the view holds no
            // behavior logic. A resume whose persistence retry still fails
            // blocks input instead: the completion state refuses every
            // submission until a later retry observes the drain (the
            // restart action replays the retry).
            if needsResumeAfterDisappear {
                needsResumeAfterDisappear = false
                if !isSessionComplete {
                    engine.resumeSession()
                    if engine.isInputBlocked {
                        apply(ChatEngineUpdate(composer: .sessionComplete))
                    }
                }
            }
            return
        }
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
        needsResumeAfterDisappear = false
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

    /// The practice view disappeared: end the engine session (it
    /// finalizes any unfinished recording) and stop any reading. A
    /// mid-session disappearance arms a recording resume for the next
    /// appearance (round 2 item 3); a completed session needs none.
    func handleDisappeared() {
        engine.endSession()
        speech.handleViewDisappeared()
        if !isSessionComplete {
            needsResumeAfterDisappear = true
        }
    }

    /// Scene-phase transitions (round 4 item 1): backgrounding the app does
    /// NOT trigger `onDisappear` on the root chat view, so without this the
    /// partial session stayed only in memory and an iOS termination lost it
    /// even with healthy storage. Background finalizes exactly like a
    /// disappearance (the engine's `endSession` hook, idempotent via its
    /// ended guard — a second finalize is a no-op, never a second log — and
    /// a failed enqueue arms the round-3 blocked state on resume instead of
    /// resuming live). Foreground re-enters the existing reappearance path
    /// (`startIfNeeded`, which resumes a fresh recording session). A
    /// transient `.inactive` (notification shade, control center) is not a
    /// backgrounding and does nothing. The view forwards the phase here;
    /// every decision stays at this engine/view-model boundary.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            handleDisappeared()
        case .active:
            startIfNeeded()
        case .inactive:
            break
        @unknown default:
            break
        }
    }
}

// MARK: - View (Band B layout per HLD)

struct ChatConversationView: View {
    @StateObject private var viewModel: ChatConversationViewModel
    @Environment(\.scenePhase) private var scenePhase
    var theme: DesignSystem.Theme = DesignSystem.defaultTheme

    init(viewModel: ChatConversationViewModel, theme: DesignSystem.Theme = DesignSystem.defaultTheme) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.theme = theme
    }

    init(engine: any ChatTutorEngine, theme: DesignSystem.Theme = DesignSystem.defaultTheme) {
        _viewModel = StateObject(wrappedValue: ChatConversationViewModel(
            engine: engine, speech: ReadAloudService(band: GradeBand(grade: "4"))))
        self.theme = theme
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if viewModel.isVoiceUnavailable {
                voiceUnavailableNotice
            }
            thread
            composerBar
        }
        .background(theme.tokens.background.color)
        .accessibilityIdentifier("chatConversationView")
        .onAppear { viewModel.startIfNeeded() }
        .onDisappear { viewModel.handleDisappeared() }
        // Round 4 item 1: backgrounding finalizes the active session
        // (backgrounding never triggers onDisappear on this root view),
        // and foregrounding resumes recording — the same two view-model
        // hooks as disappear/reappear, so no new finalization path.
        .onChange(of: scenePhase) { _, newPhase in
            viewModel.handleScenePhase(newPhase)
        }
    }

    // Slim header: star progress only. No score, clock, or text count.
    private var header: some View {
        HStack(spacing: 4) {
            ForEach(0..<max(0, viewModel.progress.totalQuestions), id: \.self) { index in
                if index < viewModel.progress.attemptedQuestions {
                    // Filled star keeps its star-fill token, backed by a
                    // larger accent star so the star's defining
                    // outline meets 3:1 against the header
                    // (the fill alone is ~1.75:1 in Canonical).
                    // Shapes never change by theme: filled is always
                    // star.fill, empty is always the star outline, and
                    // the header keeps its progress label and value.
                    ZStack {
                        Image(systemName: "star.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(theme.tokens.accent.color)
                        Image(systemName: "star.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(theme.tokens.starFill.color)
                    }
                    .accessibilityHidden(true)
                } else {
                    Image(systemName: "star")
                        .foregroundStyle(theme.tokens.starEmpty.color)
                        .accessibilityHidden(true)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.tokens.tutorBackground.color)
        .accessibilityIdentifier("chatSessionHeader")
        .accessibilityLabel("Session progress")
        .accessibilityValue("\(viewModel.progress.attemptedQuestions) of \(viewModel.progress.totalQuestions) questions started")
    }

    // Fixed chrome below the header: stays in the visible viewport
    // however far the thread below it has scrolled.
    private var voiceUnavailableNotice: some View {
        Text("Reading is unavailable on this device right now. You can still read the messages.")
            .font(.body)
            .foregroundStyle(theme.tokens.tutorText.color)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.tokens.tutorBackground.color)
            .accessibilityIdentifier("chatVoiceUnavailableNotice")
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
                        .foregroundStyle(theme.tokens.tutorText.color)
                }
                Spacer(minLength: 8)
                SpeakerButton(message: message, service: viewModel.speech, theme: theme)
            }
            .padding(12)
            .background(theme.tokens.tutorBackground.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.bubbleRadius))
            .accessibilityIdentifier("tutorMessage_\(message.id)")
        case .child(let id, let text, _):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .font(.body)
                    .foregroundStyle(theme.tokens.childText.color)
                    .padding(12)
                    .background(theme.tokens.childBackground.color)
                    .clipShape(RoundedRectangle(cornerRadius: theme.bubbleRadius))
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
                .foregroundStyle(theme.tokens.tutorText.color)
            Button("Start again") { viewModel.restartSession() }
                .buttonStyle(.borderedProminent)
                .tint(theme.tokens.accent.color)
                .frame(minHeight: 44)
                .accessibilityIdentifier("chatRestartButton")
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(theme.tokens.tutorBackground.color)
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
                .tint(theme.tokens.accent.color)
                .accessibilityIdentifier("chatHintButton")

                TextField("Type your answer", text: $viewModel.draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("chatComposerField")
                    .onSubmit { viewModel.submitDraft() }

                Button("Send") { viewModel.submitDraft() }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.tokens.accent.color)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("chatSendButton")
            }
        }
        .padding(12)
        .background(theme.tokens.tutorBackground.color)
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
