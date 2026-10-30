import SwiftUI
import EarnPlayCore

/// App-scope auditor (T4.5): runs the separate admin-app auditor over
/// synced session logs. Advisory only — it never edits policy, grants,
/// or thresholds. Dismiss clears a flag; Act records the parent's
/// choice and routes to the existing Policy tab, applying nothing.
final class AdminAuditorController {
    let runtime = AuditorRuntime.adminDefault()
    lazy var engine = AuditorEngine(runtime: runtime)
    let flagManager = AuditFlagManager()
    private let sessionStore: SessionLogStore

    init(sessionStore: SessionLogStore) {
        self.sessionStore = sessionStore
    }

    /// Runs at sync time and on demand from the Auditor tab.
    func runAudit() {
        let excerpts = sessionStore.allLogs.map(AuditorSessionExcerpt.init(sessionLog:))
        flagManager.recordRun(engine.audit(excerpts))
    }

    func excerpt(for sessionId: String) -> AuditorSessionExcerpt? {
        sessionStore.allLogs.first { $0.sessionId == sessionId }
            .map(AuditorSessionExcerpt.init(sessionLog:))
    }

    func log(for sessionId: String) -> SessionLog? {
        sessionStore.allLogs.first { $0.sessionId == sessionId }
    }
}

struct AuditorView: View {
    let auditor: AdminAuditorController
    @State private var flags: [AuditFlag] = []
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
                        refresh()
                        status = "Auditor run complete. \(flags.count) open finding(s)."
                    }
                    if !status.isEmpty {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Findings (\(flags.count))") {
                    if flags.isEmpty {
                        Text("No open findings").foregroundStyle(.secondary)
                    }
                    ForEach(flags) { flag in
                        Button { selected = flag } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(flag.category.rawValue)
                                    .font(.body)
                                Text("Severity: \(flag.severity.rawValue) · Session \(flag.sessionId)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(flag.evidence)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Auditor")
            .onAppear { refresh() }
            .sheet(item: $selected) { flag in
                AuditFlagDetailView(flag: flag, auditor: auditor) {
                    refresh()
                }
            }
        }
    }

    private func refresh() { flags = auditor.flagManager.openFlags }
}

/// Staged flag detail (Demo): severity, concrete evidence, suggested
/// action, the session excerpt, and the decision justification shown
/// with the flag. Full T4.3/T4.4 viewers are v1.
struct AuditFlagDetailView: View {
    let flag: AuditFlag
    let auditor: AdminAuditorController
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
                    Text(flag.evidence)
                }
                Section("Suggested action") {
                    Text(flag.suggestedAction)
                }
                if let excerpt = auditor.excerpt(for: flag.sessionId) {
                    Section("Session excerpt") {
                        Text("Started: \(excerpt.startedAt.formatted())")
                        Text("Ended: \(excerpt.endedAt.formatted())")
                        if let total = excerpt.effortTotal {
                            Text("effortTotal: \(total)")
                        }
                        if let bar = excerpt.effortBar {
                            Text("effortBar: \(bar)")
                        }
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
                    Section("Justification shown with this flag") {
                        ForEach(excerpt.decisions, id: \.decisionId) { decision in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(decision.type.rawValue).font(.headline)
                                Text("Outcome: \(decision.outcome)")
                                Text("Evidence: \(decision.evidenceSummary)")
                                Text("Reasoning: \(decision.reasoning)")
                                Text("Alternative considered: \(decision.alternativeConsidered)")
                            }
                            .font(.caption)
                        }
                    }
                }
                Section("Parent actions") {
                    Button("Dismiss this finding") {
                        auditor.flagManager.dismiss(flagId: flag.flagId)
                        note = "Dismissed. Policy is unchanged."
                        onChange()
                    }
                    Button("Act on this finding") {
                        _ = auditor.flagManager.markActed(flagId: flag.flagId)
                        note = "Recorded as acted. Nothing was applied for you — open the Policy tab to make and save any change yourself."
                        onChange()
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
