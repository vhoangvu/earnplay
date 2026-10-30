import SwiftUI
import Combine
import EarnPlayCore

/// App-scope auditor (T4.5): runs the separate admin-app auditor over
/// synced session logs. Advisory only — it never edits policy, grants,
/// or thresholds. Dismiss clears a flag; Act records the parent's
/// choice and routes to the existing Policy tab, applying nothing.
final class AdminAuditorController: ObservableObject {
    let runtime = AuditorRuntime.adminDefault()
    lazy var engine = AuditorEngine(runtime: runtime)
    let flagManager = AuditFlagManager()
    private let sessionStore: SessionLogStore
    private let runGate = AuditRunGate()
    @Published private(set) var openFlags: [AuditFlag] = []

    init(sessionStore: SessionLogStore) {
        self.sessionStore = sessionStore
    }

    /// Runs at sync time and on demand from the Auditor tab. The
    /// production transport invokes this from its MCSession delegate
    /// callback, off the main queue, so the work hops to the main
    /// queue before touching @Published state, and a run requested
    /// while another is in flight is skipped (round 2, item 1).
    func runAudit() {
        guard runGate.tryBegin() else { return }
        let gate = runGate
        let work = { [weak self] in
            guard let self else { gate.end(); return }
            defer { gate.end() }
            let excerpts = self.sessionStore.allLogs.map(AuditorSessionExcerpt.init(sessionLog:))
            self.flagManager.recordRun(self.engine.audit(excerpts))
            self.refresh()
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
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
                        auditor.runAudit()
                        status = AuditorRunStatus.completionMessage(
                            openCount: auditor.openFlags.count,
                            persistenceError: auditor.flagManager.lastPersistenceError)
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
