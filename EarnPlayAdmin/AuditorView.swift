import SwiftUI
import Combine
import EarnPlayCore

/// App-scope auditor (T4.5): runs the separate admin-app auditor over
/// synced session logs. Advisory only — it never edits policy, grants,
/// or thresholds. Dismiss clears a flag; Act records the parent's
/// choice and routes to the existing Policy tab, applying nothing.
final class AdminAuditorController: ObservableObject {
    let runtime = AuditorRuntime.adminDefault()
    let engine: AuditorEngine
    let flagManager = AuditFlagManager()
    private let sessionStore: SessionLogStore
    private let performer = AuditRunPerformer()
    private let completionLock = NSLock()
    private var pendingCompletions: [() -> Void] = []
    @Published private(set) var openFlags: [AuditFlag] = []

    init(sessionStore: SessionLogStore) {
        self.sessionStore = sessionStore
        self.engine = AuditorEngine(runtime: runtime)
    }

    /// Runs at sync time and on demand from the Auditor tab. Every
    /// call path (the app's `onSessionStored` callback on the MCSession
    /// delegate queue and the Auditor tab button on the main queue)
    /// funnels through here: the audit work runs off the main queue so
    /// navigation and policy editing stay responsive, only publishing
    /// to `@Published` state hops to the main queue, and a request
    /// arriving mid-audit coalesces into one rerun so no stored session
    /// goes unaudited (round 3, items 1-3). The optional completion
    /// runs on the main queue after the final publish.
    func runAudit(completion: (() -> Void)? = nil) {
        if let completion {
            completionLock.lock()
            pendingCompletions.append(completion)
            completionLock.unlock()
        }
        performer.request(work: { [weak self] in
            guard let self else { return }
            let excerpts = self.sessionStore.allLogs.map(AuditorSessionExcerpt.init(sessionLog:))
            self.flagManager.recordRun(self.engine.audit(excerpts))
        }, publish: { [weak self] in
            self?.refresh()
        }, settled: { [weak self] in
            guard let self else { return }
            self.completionLock.lock()
            let completions = self.pendingCompletions
            self.pendingCompletions = []
            self.completionLock.unlock()
            completions.forEach { $0() }
        })
    }

    func refresh() { openFlags = flagManager.openFlags }

    func excerpt(for sessionId: String) -> AuditorSessionExcerpt? {
        sessionStore.allLogs.first { $0.sessionId == sessionId }
            .map(AuditorSessionExcerpt.init(sessionLog:))
    }

    func log(for sessionId: String) -> SessionLog? {
        sessionStore.allLogs.first { $0.sessionId == sessionId }
    }

    /// Every session cited by a flag (item 2), own session first.
    func citedSessionIds(for flag: AuditFlag) -> [String] {
        flag.citedSessionIds(knownSessionIds: sessionStore.allLogs.map(\.sessionId))
    }
}

struct AuditorView: View {
    @ObservedObject var auditor: AdminAuditorController
    var onOpenPolicy: () -> Void = {}
    @State private var selected: AuditFlag?
    @State private var status = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Auditor") {
                    Text("Findings from the separate auditor on this device. The auditor advises only — it changes nothing by itself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Run auditor over synced sessions") {
                        auditor.runAudit {
                            status = AuditorRunStatus.completionMessage(
                                openCount: auditor.openFlags.count,
                                persistenceError: auditor.flagManager.lastPersistenceError)
                        }
                    }
                    if !status.isEmpty {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Findings (\(auditor.openFlags.count))") {
                    if auditor.openFlags.isEmpty {
                        Text("No open findings").foregroundStyle(.secondary)
                    }
                    ForEach(auditor.openFlags) { flag in
                        Button { selected = flag } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(flag.category.rawValue)
                                    .font(.body)
                                Text("Severity: \(flag.severity.rawValue) · Session \(flag.sessionId)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(AuditorScoreFreeText.make(flag.evidence))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Auditor")
            .onAppear { auditor.refresh() }
            .sheet(item: $selected) { flag in
                AuditFlagDetailView(flag: flag, auditor: auditor, onOpenPolicy: onOpenPolicy) {
                    auditor.refresh()
                }
            }
        }
    }
}

/// Staged flag detail (Demo): severity, concrete evidence, suggested
/// action, an excerpt section for EVERY cited session, and the
/// decision justification shown with the flag. All presented text is
/// score-free (item 3); stored records keep their values.
struct AuditFlagDetailView: View {
    let flag: AuditFlag
    @ObservedObject var auditor: AdminAuditorController
    var onOpenPolicy: () -> Void = {}
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Finding") {
                    Text("Kind: \(flag.category.rawValue)")
                    Text("Severity: \(flag.severity.rawValue)")
                    Text("Session: \(flag.sessionId)")
                        .font(.body.monospaced())
                }
                Section("Evidence (from the raw log)") {
                    Text(AuditorScoreFreeText.make(flag.evidence))
                }
                Section("Suggested action") {
                    Text(AuditorScoreFreeText.make(flag.suggestedAction))
                }
                ForEach(auditor.citedSessionIds(for: flag), id: \.self) { sessionId in
                    if let excerpt = auditor.excerpt(for: sessionId) {
                        Section("Session excerpt — \(sessionId)") {
                            Text("Started: \(excerpt.startedAt.formatted())")
                            Text("Ended: \(excerpt.endedAt.formatted())")
                            if let floor = excerpt.floorMet {
                                Text("floorMet: \(floor ? "true" : "false")")
                            }
                            if let signals = excerpt.signals {
                                Text("genuineAttempts: \(signals.genuineAttempts)")
                                Text("activeSeconds: \(signals.activeSeconds)")
                                Text("hintInteractions: \(signals.hintInteractions)")
                                Text("followUpInteractions: \(signals.followUpInteractions)")
                                Text("answerRevisions: \(signals.answerRevisions)")
                                Text("explanations: \(signals.explanations)")
                            }
                        }
                        if !excerpt.questions.isEmpty {
                            Section("Questions recorded — \(sessionId)") {
                                ForEach(excerpt.questions, id: \.questionId) { q in
                                    Text("\(q.questionId): form \(q.form), difficulty \(q.difficulty), answer matched: \(q.answerMatched.map { $0 ? "yes" : "no" } ?? "not recorded")")
                                        .font(.caption)
                                }
                            }
                        }
                        Section("Justification shown with this flag — \(sessionId)") {
                            ForEach(excerpt.decisions, id: \.decisionId) { decision in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(decision.type.rawValue).font(.headline)
                                    Text("Outcome: \(AuditorScoreFreeText.make(decision.outcome))")
                                    Text("Evidence: \(AuditorScoreFreeText.make(decision.evidenceSummary))")
                                    Text("Reasoning: \(AuditorScoreFreeText.make(decision.reasoning))")
                                    Text("Alternative considered: \(AuditorScoreFreeText.make(decision.alternativeConsidered))")
                                }
                                .font(.caption)
                            }
                        }
                    }
                }
                Section("Parent actions") {
                    Button("Dismiss this finding") {
                        if auditor.flagManager.dismiss(flagId: flag.flagId) {
                            note = "Dismissed. Policy is unchanged."
                            onChange()
                        } else {
                            note = "Could not save that choice\(auditor.flagManager.lastPersistenceError.map { " (\($0))" } ?? ""). The finding is still open — try again."
                        }
                    }
                    Button("Act on this finding") {
                        if let route = auditor.flagManager.markActed(flagId: flag.flagId) {
                            onChange()
                            switch route {
                            case .openPolicyEditor:
                                dismiss()
                                onOpenPolicy()
                            case .openSession:
                                note = "Recorded as acted. Nothing was applied for you."
                            }
                        } else {
                            note = "Could not save that choice\(auditor.flagManager.lastPersistenceError.map { " (\($0))" } ?? ""). The finding is still open — try again."
                        }
                    }
                    if !note.isEmpty {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Finding detail")
            .toolbar {
                Button("Close") { dismiss() }
            }
        }
    }
}
