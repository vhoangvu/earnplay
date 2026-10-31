import XCTest

/// Shared helpers for the issue #71 feature-walkthrough suite.
///
/// Conventions (see Docs/Walkthrough.md):
/// - Every step launches its app fresh (order-independent, re-runnable
///   on a dirty simulator) and captures at least one screenshot
///   artifact named `<app>-<screen>-step<NN>`.
/// - Screenshot capture never fails a test: the capture helper asserts
///   nothing and throws nothing, and issues recorded while it runs
///   are suppressed by WalkthroughTestCase (see below).
/// - Reachable steps assert the expected screen/element and FAIL when a
///   screen cannot be reached. Unreachable features are recorded with
///   `recordGap` (reason + unblock path), never silently skipped.
/// - No test ever taps the model-download button or waits for a
///   download. Model-ready child launches set `EARNPLAY_MODEL_PATH` to
///   a nonexistent path, which the production readiness gate resolves
///   through its legacy env-override path (existence is never checked
///   for the override) without any network I/O.
enum Walkthrough {
    static let childBundleID = "com.vhoangvu.earnplay"
    static let adminBundleID = "com.vhoangvu.earnplay.admin"

    /// Dummy model path for model-ready child launches. It MUST NOT
    /// exist: the production registry validation then throws and the
    /// gate falls through to the legacy override path, which reports
    /// ready without hashing or downloading anything. It must also
    /// differ from the downloader's destination so the pinned
    /// size+SHA fast path never applies.
    static let dummyModelPath = "/tmp/earnplay-walkthrough-no-such-model.gguf"

    /// Launches the child app with the model gate satisfied (no
    /// download). Reaches the setup wizard on a simulator that has
    /// never completed setup.
    static func launchChildModelReady() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["EARNPLAY_MODEL_PATH"] = dummyModelPath
        app.launch()
        return app
    }

    /// Launches the child app with any inherited model-path override
    /// neutralized, so the first-launch download gate shows. BOTH
    /// supported override keys are cleared: production
    /// `ModelRuntime.defaultModelURL` consults `EARNPLAY_MODEL_PATH`
    /// then `SIMCTL_CHILD_EARNPLAY_MODEL_PATH`, and an inherited
    /// `SIMCTL_CHILD_` value would otherwise satisfy the gate. (The
    /// model-ready launcher needs no such clearing: its non-empty
    /// plain key is consulted first and always wins.)
    static func launchChildFresh() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["EARNPLAY_MODEL_PATH"] = ""
        app.launchEnvironment["SIMCTL_CHILD_EARNPLAY_MODEL_PATH"] = ""
        app.launch()
        return app
    }

    /// Launches the admin app from this same UI-test target. The
    /// EarnPlay scheme builds EarnPlayAdmin (see project.yml) so the
    /// test run installs it alongside the child app.
    static func launchAdmin() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: adminBundleID)
        app.launch()
        return app
    }

    /// Extracts a trailing 6-digit pairing code from a label of the
    /// form "<prefix>: 123456". Returns nil for any other shape, so
    /// tests pin the format without pinning the random value.
    static func trailingPairingCode(in label: String) -> String? {
        guard let range = label.range(of: ": ") else { return nil }
        let tail = label[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard tail.count == 6 else { return nil }
        for character in tail {
            guard character.isNumber else { return nil }
        }
        return tail
    }
}

/// Base class for the walkthrough test cases. `app.screenshot()` is
/// an XCTest automation operation: a capture-only IPC failure would
/// otherwise record an issue on the test, and with
/// `continueAfterFailure = false` that would stop the test — even
/// though the capture helper asserts nothing. While the helper runs
/// it raises `suppressingCaptureIssues`, and the overrides below
/// drop any issue recorded in that window, so a capture problem can
/// neither fail nor stop the suite. (An Objective-C exception raised
/// out of the capture IPC itself is not catchable in Swift and
/// remains a residual risk; no such failure has been observed.)
class WalkthroughTestCase: XCTestCase {
    /// While true, issues recorded on this test are capture-only
    /// noise from `walkthroughScreenshot` and are dropped.
    var suppressingCaptureIssues = false

    override func record(_ issue: XCTIssue) {
        if suppressingCaptureIssues { return }
        super.record(issue)
    }

    override func recordFailure(
        withDescription description: String,
        inFile filePath: String,
        atLine lineNumber: Int,
        expected: Bool
    ) {
        if suppressingCaptureIssues { return }
        super.recordFailure(
            withDescription: description,
            inFile: filePath,
            atLine: lineNumber,
            expected: expected
        )
    }
}

extension XCTestCase {
    /// Captures a screenshot test artifact. Asserts nothing, and any
    /// XCTest issue recorded by the capture itself is suppressed (see
    /// WalkthroughTestCase): a capture problem must never fail the
    /// suite.
    func walkthroughScreenshot(_ app: XCUIApplication, named name: String) {
        // Both walkthrough classes inherit WalkthroughTestCase, so
        // this cast succeeds on every call site; without the flag the
        // capture still proceeds, only unsuppressed.
        let walkthroughCase = self as? WalkthroughTestCase
        walkthroughCase?.suppressingCaptureIssues = true
        defer { walkthroughCase?.suppressingCaptureIssues = false }
        XCTContext.runActivity(named: "screenshot \(name)") { activity in
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    /// Records a walkthrough gap as a named activity with an attached
    /// report plus a log line, so the gap is visible in test results
    /// without failing the suite. Asserts nothing.
    func recordGap(id: String, feature: String, reached: String, reason: String, unblock: String) {
        let report = """
        WALKTHROUGH GAP \(id): \(feature)
        Reached in production UI: \(reached)
        Why the rest is unreachable: \(reason)
        What unblocks it: \(unblock)
        """
        XCTContext.runActivity(named: "gap \(id) \(feature)") { activity in
            let attachment = XCTAttachment(string: report)
            attachment.name = "gap-\(id)"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        NSLog("WALKTHROUGH-GAP %@: %@ | %@", id, feature, reason)
    }

    /// First static text whose label contains the substring.
    func textContaining(_ app: XCUIApplication, _ substring: String) -> XCUIElement {
        return app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", substring)
        ).firstMatch
    }

    /// First static text whose label starts with the prefix.
    func textStartingWith(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        return app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", prefix)
        ).firstMatch
    }

    /// Scrolls up in small steps until the element is hittable (or
    /// the step budget runs out). For top-to-bottom forms and
    /// below-the-fold sections.
    ///
    /// Small press-drags instead of full `swipeUp` flicks: one flick
    /// can traverse several Form sections (flick distance differs
    /// between iOS 18's table-backed Form and iOS 26+'s
    /// collection-backed one), so a flick-then-check loop can stride
    /// clean over its target between two checks while Form recycling
    /// removes the target from the tree (issue #71 fix-1: CI-only
    /// Admin03 failure on "Unlock durations"). Each step here moves
    /// ~1/3 of the screen, so any target stays observable across
    /// several consecutive checks, and slow drags carry no flick
    /// momentum for a check to race with.
    func scrollIntoView(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 24) {
        var swipes = 0
        while !element.isHittable && swipes < maxSwipes {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.1, thenDragTo: end)
            swipes += 1
        }
    }

    /// Section-header element tolerant of iOS-version AX variance.
    /// iOS 26+ exposes SwiftUI `Section` headers as StaticText with
    /// the exact string; iOS 18 (table-backed Form/List) may expose
    /// the same header as a non-StaticText element or with a
    /// transformed label (issue #71 fix-1: CI-only Admin06 failure on
    /// "Findings (0)", which renders but never matches `staticTexts`
    /// on iOS 18). Matches the exact label or its UPPERCASE variant
    /// across any element type, so callers keep asserting the same
    /// production string. No CONTAINS fallback here: some headers
    /// ("Movement trade") are prefixes of row labels.
    func sectionHeader(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        return app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR label == %@", name, name.uppercased())
        ).firstMatch
    }

    /// Waits for an element to become enabled (e.g. a button gated on
    /// an async load). Returns false on timeout instead of failing.
    func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Dismisses the software keyboard via Return when it is up.
    /// Best-effort and assertion-free; callers proceed regardless.
    func dismissKeyboardIfPresent(_ app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 2) else { return }
        let candidates: [XCUIElement] = [
            app.keyboards.buttons["return"].firstMatch,
            app.keyboards.buttons["Return"].firstMatch,
            app.keyboards.keys["return"].firstMatch,
            app.keys["return"].firstMatch,
        ]
        for key in candidates {
            if key.exists && key.isHittable {
                key.tap()
                return
            }
        }
    }
}
