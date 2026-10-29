import EarnPlayCore
import Foundation

/// T5.1 eval harness CLI.
///
/// One command (from the repo root):
///   swift run --package-path EarnPlayCore eval-harness
///
/// Runs all five scripted personas, prints the per-criterion scorecard,
/// writes the report next to the baseline, and fails (exit 1) on any
/// criterion failure or any regression versus the baseline.

let defaultBaselinePath = "EarnPlayCore/EvalHarness/baseline.json"
let defaultReportPath = "EarnPlayCore/EvalHarness/eval-report-latest.json"
let defaultRedTeamReportPath = "EarnPlayCore/RedTeam/red-team-report-latest.json"

func printUsage() {
    print("""
    Usage: eval-harness [--baseline PATH] [--report PATH] [--write-baseline] [--help]

      Runs the five T5.1 scripted personas (good-faith, guessing, idling,
      manipulative, struggling child), prints the per-criterion scorecard,
      writes the JSON report, and compares against the baseline.

      --baseline PATH   Baseline report for regression comparison
                        (default: \(defaultBaselinePath))
      --report PATH     Where to write this run's report
                        (default: \(defaultReportPath))
      --write-baseline  Store this run's report as the new baseline instead
                        of comparing (refuses when the run fails overall)
      --red-team        Run the T5.2 red-team battery instead of the
                        persona eval (see Docs/RedTeaming.md)
      --red-team-report PATH
                        Where to write the red-team report
                        (default: \(defaultRedTeamReportPath))
      --help            Print this help

    Exit codes: 0 = pass with no regressions; 1 = criterion failure or
    regression; 2 = usage or I/O error (including a missing baseline).
    """)
}

func fail(_ message: String) -> Never {
    if let data = ("eval-harness: \(message)\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
    exit(2)
}

var baselinePath = defaultBaselinePath
var reportPath = defaultReportPath
var writeBaseline = false
var redTeam = false
var redTeamReportPath = defaultRedTeamReportPath
var index = 1
while index < CommandLine.arguments.count {
    let arg = CommandLine.arguments[index]
    switch arg {
    case "--help", "-h":
        printUsage()
        exit(0)
    case "--write-baseline":
        writeBaseline = true
    case "--red-team":
        redTeam = true
    case "--red-team-report":
        index += 1
        guard index < CommandLine.arguments.count else {
            fail("--red-team-report needs a path")
        }
        redTeamReportPath = CommandLine.arguments[index]
    case "--baseline":
        index += 1
        guard index < CommandLine.arguments.count else {
            fail("--baseline needs a path")
        }
        baselinePath = CommandLine.arguments[index]
    case "--report":
        index += 1
        guard index < CommandLine.arguments.count else {
            fail("--report needs a path")
        }
        reportPath = CommandLine.arguments[index]
    default:
        printUsage()
        fail("unknown argument: \(arg)")
    }
    index += 1
}

if redTeam {
    let runner = RedTeamRunner()
    print("Red-team battery T5.2 (threshold \(EvalHarness.harnessThreshold); stub-only, no inference)")
    var caseResults: [RedTeamCaseResult] = []
    for testCase in RedTeamBattery.cases {
        let result = runner.runCase(testCase)
        caseResults.append(result)
        print("  [\(result.id)] \(result.outcome)")
    }
    let batteryReport = runner.report(for: caseResults)
    print("")
    print(RedTeamScorecard.render(batteryReport))
    do {
        let data = try RedTeamReportIO.encode(batteryReport)
        let reportURL = URL(fileURLWithPath: redTeamReportPath)
        let parent = reportURL.deletingLastPathComponent()
        if !parent.path.isEmpty {
            try FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true)
        }
        try data.write(to: reportURL, options: [.atomic])
        print("")
        print("Report written to \(redTeamReportPath)")
    } catch {
        fail("could not write red-team report to \(redTeamReportPath): \(error)")
    }
    if batteryReport.overall != "pass" {
        print("Overall: FAIL")
        exit(1)
    }
    print("Overall: PASS")
    exit(0)
}

// Refuse a --report that resolves to the baseline file BEFORE any work:
// the report is written before the baseline is read, so writing first
// would silently replace the baseline and then self-compare (always pass).
if EvalPaths.resolveToSameFile(reportPath, baselinePath) {
    fail("--report (\(reportPath)) resolves to the same file as"
        + " --baseline (\(baselinePath)); refusing to overwrite the baseline")
}

let harness = EvalHarness()
print("Eval harness T5.1 (threshold \(EvalHarness.harnessThreshold); stub-only, no inference)")
var personaResults: [EvalPersonaResult] = []
for persona in EvalPersona.allCases {
    let result = harness.runPersona(persona)
    personaResults.append(result)
    let floor = result.floorMet ? "floor met" : "floor not met"
    print("  [\(persona.rawValue)] \(result.unlockDecision)"
        + " (score \(result.score) vs \(result.threshold), \(floor),"
        + " \(result.questionsPresented) questions, wrong taught \(result.wrongAnswersTaught))")
}

// Score the collected results into a report exactly as runAll() would.
let collected = harness.report(for: personaResults)
print("")
print(EvalScorecard.render(collected))

// Write this run's report next to the baseline.
let reportData: Data
do {
    reportData = try EvalBaseline.encode(collected)
} catch {
    fail("could not encode report: \(error)")
}
do {
    try EvalPaths.writeReport(reportData, to: reportPath,
                              refusingBaseline: baselinePath)
    print("")
    print("Report written to \(reportPath)")
} catch EvalPaths.ClashError.reportEqualsBaseline(let report, let baseline) {
    fail("--report (\(report)) resolves to the same file as"
        + " --baseline (\(baseline)); refusing to overwrite the baseline")
} catch {
    fail("could not write report to \(reportPath): \(error)")
}

if writeBaseline {
    guard collected.overall == "pass" else {
        print("Baseline NOT written: run failed overall — fix first, then re-run.")
        exit(1)
    }
    do {
        let baselineURL = URL(fileURLWithPath: baselinePath)
        let parent = baselineURL.deletingLastPathComponent()
        if !parent.path.isEmpty {
            try FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true)
        }
        try reportData.write(to: baselineURL, options: [.atomic])
        print("Baseline written to \(baselinePath)")
    } catch {
        fail("could not write baseline to \(baselinePath): \(error)")
    }
    exit(0)
}

let baselineData: Data
do {
    baselineData = try Data(contentsOf: URL(fileURLWithPath: baselinePath))
} catch {
    fail("could not read baseline at \(baselinePath) (run from the repo root,"
        + " or create it with --write-baseline): \(error)")
}
let baseline: EvalReport
do {
    baseline = try EvalBaseline.decode(baselineData)
} catch {
    fail("could not decode baseline at \(baselinePath): \(error)")
}
guard baseline.schemaVersion == EvalReport.currentSchemaVersion else {
    fail("baseline schema v\(baseline.schemaVersion) != harness v\(EvalReport.currentSchemaVersion);"
        + " re-establish with --write-baseline")
}
let comparison = EvalBaseline.compare(baseline: baseline, current: collected)
print("")
if comparison.hasRegression {
    print("Baseline \(baselinePath): REGRESSIONS (\(comparison.criterionRegressions.count)):")
    for line in comparison.criterionRegressions.prefix(30) {
        print("  - \(line)")
    }
} else {
    print("Baseline \(baselinePath): no criterion regressed versus baseline.")
}
for line in comparison.improvements.prefix(10) {
    print("  improvement: \(line)")
}
for line in comparison.otherChanges.prefix(10) {
    print("  drift: \(line)")
}

if collected.overall != "pass" {
    print("Overall: FAIL")
    exit(1)
}
if comparison.hasRegression {
    print("Overall: FAIL (regression)")
    exit(1)
}
print("Overall: PASS")
exit(0)
