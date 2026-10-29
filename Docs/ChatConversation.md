# Chat conversation UI (T1.8)

Child app's main practice screen: a chat thread with the AI tutor.
Band B (grade 4) only for the Demo; Band A read-aloud/voice input is
v1 scope and is not built here.

## What was built

- `EarnPlay/ChatConversation.swift` — `ChatConversationView`, its
  view model, and the turn-stream types it renders (`ChatTurn`,
  `ChatComposerSpec`, `ChatProgress`, `ChatEngineUpdate`,
  `ChatTutorEngine`). The view holds no behaviour logic: it renders
  the engine's turn stream in order, forwards the child's raw input
  and Hint taps to the engine, and renders whatever turns come back.
  No scoring, timing, answer-checking, or pass/fail logic lives in
  the view or view model, and no score, timer, or countdown is
  rendered anywhere (header is star progress only).
- Layout per HLD: slim session header with one star per question
  (filled as each is attempted), scrolling tutor/child bubbles,
  composer at the bottom with text input plus choice buttons or a
  number pad as supplied by the engine for the current question,
  and a Hint button beside the composer that is always visible and
  never disabled. Every tutor message renders the T1.7
  `SpeakerButton` with the shared `ReadAloudService`; leaving the
  screen calls `handleViewDisappeared()`. Design tokens follow the
  SSOT palette, type, spacing, and corner radii (`ChatDesign`).
- `EarnPlay/DemoTutorEngine.swift` — the Demo engine behind the
  `ChatTutorEngine` boundary. It owns all session decisions using
  the merged APIs: questions are T1.2 fallback-bank proposals
  re-verified through `SolverService` (an unverified proposal is
  dropped, never shown), answers are checked by
  `SolverService.checkAnswer`, hints are T1.3 `HintLadder` levels
  for the current verified question, and a non-matching answer gets
  canned encouragement plus a "show me one step" probe as tutor
  messages. A changed resubmission is labelled a revision by the
  engine in its update.
- Wiring: after setup completes, `ContentView` shows the chat as the
  main screen. Earlier preview harnesses remain reachable in code
  for their own manual tests.

## Untrusted child input

Child free-text is data only. `ChildTextSanitizer` drops control
characters and caps length before the text leaves the view; the
sanitized string is shown as a plain SwiftUI `Text` child bubble
and passed to the engine as an answer string, where the Demo engine
only compares it with the solver's verified answer. It is never
interpreted as a command, never used to build a prompt in the view,
and tutor/model text is likewise rendered only as `Text` (never
executable, never linked). A test drives injection-shaped input
through the view and asserts the scripted tutor stream is unchanged.

## Automated test

`EarnPlayTests/ChatConversationTests.swift` (XCTest):

- Scripted stream question → wrong answer → encouragement → hint →
  probe → revision through `ChatConversationViewModel`; asserts
  thread order matches the stream, every tutor message id appears
  in `speakerMessageIDs` (one speaker button per tutor message),
  and no rendered string matches a score/timer/pass-fail pattern
  (0 score strings visible).
- Injection-shaped child text stays a plain bubble, is sanitized,
  and does not alter the tutor stream.
- The real `DemoTutorEngine` opens with a verified question, serves
  a hint-ladder message, and answers a wrong answer with a probe.

## Manual test (PR-ready notes)

Simulator/device, Band B (grade 4):

1. Finish setup so the app reaches the main screen — the chat opens
   with the tutor's first question as a message, with a speaker
   button on it and star outlines in the slim header.
2. Answer with a value that does not match (type it or use the
   number pad, then Send) — encouragement arrives as a tutor
   message, followed by a "show me one step" probe. No failure
   state, score, or timer appears; the first star fills.
3. Tap Hint (always visible beside the composer) — the next
   hint-ladder level arrives as a tutor message in the thread.
4. Tap a speaker button on any tutor message — the message is read
   aloud on-device; tapping the same button again stops it.
5. Answer matching the question — a tutor encouragement message
   arrives and the next question follows in the same thread.

Expected: the whole session happens in the thread; nothing looks
like a quiz form.

## Scope limits

- No TutorEngine exists on this branch yet; the chat renders the
  `ChatTutorEngine` turn-stream boundary, and `DemoTutorEngine` is
  the Demo implementation over T1.2/T1.3. The real TutorEngine
  adopts the same boundary when it lands.
- No ManagedSettings/FamilyControls or real enforcement is wired
  (T2.4 simulated shield remains the Demo enforcement surface).
- Local gates cannot prove CI passes (CI pins Xcode 16.4 / iOS 18.5
  SDK); only APIs present in that SDK are used.
