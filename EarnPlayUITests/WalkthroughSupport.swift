import XCTest

/// Shared helpers for the issue #71 feature-walkthrough suite.
///
/// Conventions (see Docs/Walkthrough.md):
/// - Every step launches its app fresh (order-independent, re-runnable
///   on a dirty simulator) and captures at least one screenshot
///   artifact named `<app>-<screen>-step<NN>`.
/// - Screenshot capture never fails a test: the capture helper asserts
///   nothing and throws nothing.
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
    /// neutralized, so the first-launch download gate shows.
    static func launchChildFresh() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["EARNPLAY_MODEL_PATH"] = ""
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

extension XCTestCase {
    /// Captures a screenshot test artifact. Asserts nothing: a capture
    /// problem must never fail the suite.
    func walkthroughScreenshot(_ app: XCUIApplication, named name: String) {
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

    /// Scrolls up until the element is hittable (or the swipe budget
    /// runs out). For top-to-bottom forms and below-the-fold sections.
    func scrollIntoView(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 14) {
        var swipes = 0
        while !element.isHittable && swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
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
