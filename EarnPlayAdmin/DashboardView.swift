import SwiftUI
import EarnPlayCore

/// T4.2 parent dashboard: progress at a glance from synced session logs.
///
/// Every number on this screen is computed from
/// `SessionLogStore.allLogs` via `Dashboard.compute` — there is no
/// sample, fixture, or hard-coded data anywhere in this view. With no
/// synced logs the screen shows an explicit empty state, never zeroes.
/// Per-card gaps (a skill with no questions this week, no recorded
/// mistakes) likewise render as "not yet" words, never zero-like data.
///
/// User-visible language follows the product rules: plain words, no
/// effort numbers, no pass/fail language, no timers or countdowns.
/// Trying over time is shown as a direction plus relative bars with
/// dates — never raw numbers.
struct DashboardView: View {
    let controller: AdminSyncController
    @State private var report: Dashboard.Report

    init(controller: AdminSyncController) {
        self.controller = controller
        _report = State(initialValue: Dashboard.compute(
            logs: controller.sessionStore.allLogs, now: Date()))
    }

    private static let shortDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if report.isEmpty {
                        emptyState
                    } else {
                        header
                        accuracyCard
                        activeTimeCard
                        hintCard
                        errorCard
                        effortCard
                        tradeCard
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Progress")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh") { reload() }
                }
            }
            .onAppear { reload() }
        }
    }

    private func reload() {
        report = Dashboard.compute(logs: controller.sessionStore.allLogs, now: Date())
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No synced sessions yet")
                .font(.title2.bold())
            Text("Progress appears here after the child's device syncs. " +
                 "Open EarnPlay on the child's device and EarnPlayAdmin here, " +
                 "pair them in Sessions, then run a practice session.")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("Nothing here is estimated or filled in: every number on " +
                 "this screen comes from synced sessions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("dashboard-empty-state")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(report.sessionCount) synced \(report.sessionCount == 1 ? "session" : "sessions")")
                .font(.headline)
            Text("Every number below is computed from those synced sessions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("dashboard-header")
    }

    // MARK: - Aggregate 1: accuracy per skill, this week vs last

    private var accuracyCard: some View {
        dashboardCard(title: "Correct answers by skill", subtitle: "This week vs last week") {
            if report.skillAccuracies.isEmpty {
                Text(Dashboard.noRecentQuestionsMessage)
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(report.skillAccuracies, id: \.skill) { skill in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(humanizeSkill(skill.skill))
                            .font(.body.bold())
                        Text("This week: \(weekLine(correct: skill.thisWeekCorrect, total: skill.thisWeekTotal, rate: skill.thisWeekAccuracy))")
                            .font(.body)
                        Text("Last week: \(weekLine(correct: skill.lastWeekCorrect, total: skill.lastWeekTotal, rate: skill.lastWeekAccuracy))")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func weekLine(correct: Int, total: Int, rate: Double?) -> String {
        guard let rate else { return "no questions yet" }
        return "\(wholePercent(rate))% (\(correct) of \(total))"
    }

    private func wholePercent(_ rate: Double) -> Int {
        Int((rate * 100).rounded())
    }

    private func humanizeSkill(_ skill: String) -> String {
        skill.replacingOccurrences(of: "-", with: " ")
    }

    // MARK: - Aggregate 2: active time per question

    private var activeTimeCard: some View {
        dashboardCard(title: "Time on each question", subtitle: "Average active time") {
            if let average = report.activeTime.averageSecondsPerQuestion {
                Text("About \(formatDuration(average)) per question " +
                     "(\(report.activeTime.questionCount) \(report.activeTime.questionCount == 1 ? "question" : "questions") total)")
                    .font(.body)
            } else {
                Text("No questions synced yet.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let remainder = total % 60
        if minutes == 0 { return "\(remainder) s" }
        if remainder == 0 { return "\(minutes) min" }
        return "\(minutes) min \(remainder) s"
    }

    // MARK: - Aggregate 3: hint rate

    private var hintCard: some View {
        dashboardCard(title: "Hint use", subtitle: "Questions where a hint was used") {
            if let rate = report.hintRate.rate {
                Text("Hints used on \(report.hintRate.questionsWithHints) of " +
                     "\(report.hintRate.questionCount) questions (\(wholePercent(rate))%)")
                    .font(.body)
            } else {
                Text("No questions synced yet.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Aggregate 4: most common error type

    private var errorCard: some View {
        dashboardCard(title: "Most common mistake", subtitle: "Across synced sessions") {
            if let top = report.topError {
                Text("\(top.errorType) — seen \(top.count) \(top.count == 1 ? "time" : "times")")
                    .font(.body)
            } else if report.activeTime.questionCount == 0 {
                Text("No questions synced yet.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                Text(Dashboard.noMistakeTypesMessage)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Aggregate 5: effort-score trend (direction only, no numbers)

    private var effortCard: some View {
        dashboardCard(title: "Trying over time", subtitle: "Genuine engagement across sessions") {
            let trend = report.effortTrend
            if let direction = trend.direction {
                Text(directionLine(direction))
                    .font(.body.bold())
                effortBars(trend.points)
            } else if trend.points.isEmpty {
                Text("No trying snapshots yet.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                Text("Trying trend appears after 2 sessions with practice.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func directionLine(_ direction: Dashboard.EffortDirection) -> String {
        switch direction {
        case .rising: return "Trying is rising."
        case .steady: return "Trying is holding steady."
        case .dipping: return "Trying has dipped lately."
        }
    }

    /// Relative per-session bars: width carries the shape, dates carry
    /// identity — no raw numbers are shown, per the no-scores rule.
    /// Each row is one accessibility element labelled with its date plus
    /// its engagement relative to the preceding session, so VoiceOver
    /// perceives the same rises and dips the bars show visually.
    private func effortBars(_ points: [Dashboard.EffortPoint]) -> some View {
        let maxScore = max(1, points.map(\.score).max() ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(points.indices, id: \.self) { index in
                let point = points[index]
                let dateText = Self.shortDayFormatter.string(from: point.startedAt)
                HStack(spacing: 8) {
                    Text(dateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                    GeometryReader { geometry in
                        let fraction = max(0.06, Double(point.score) / Double(maxScore))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(0.7))
                            .frame(width: geometry.size.width * fraction)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 12)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Dashboard.effortBarAccessibilityLabel(
                    dateText: dateText,
                    score: point.score,
                    previousScore: index > 0 ? points[index - 1].score : nil))
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Aggregate 6: trade frequency

    private var tradeCard: some View {
        dashboardCard(title: "Trades", subtitle: "Trades offered across sessions") {
            let trades = report.tradeFrequency
            if trades.totalTrades == 0 {
                Text("No trades offered yet across \(trades.sessionCount) " +
                     "\(trades.sessionCount == 1 ? "session" : "sessions").")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(trades.totalTrades) \(trades.totalTrades == 1 ? "trade" : "trades") offered " +
                     "across \(trades.sessionCount) \(trades.sessionCount == 1 ? "session" : "sessions")")
                    .font(.body)
                Text("Movement: \(trades.movementTrades) · Chores: \(trades.choreTrades)" +
                     (trades.otherTrades > 0 ? " · Other: \(trades.otherTrades)" : ""))
                    .font(.body)
                    .foregroundStyle(.secondary)
                if let perSession = trades.tradesPerSession {
                    Text("About \(formatRate(perSession)) per session")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func formatRate(_ rate: Double) -> String {
        if rate == floor(rate) { return "\(Int(rate))" }
        return String(format: "%.1f", rate)
    }

    // MARK: - Card chrome

    private func dashboardCard<Content: View>(title: String, subtitle: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
