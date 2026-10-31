import XCTest

/// Child-app smoke tests (issue #69). Launch + first-screen gate ONLY —
/// full coverage of chat, trades, shields, pairing, dashboard, and
/// auditor is explicitly out of scope.
///
/// These tests never start the ~800 MB first-launch model download:
/// they assert the download gate appears, never download completion.
final class EarnPlayUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    /// The child app launches and reaches the foreground without crashing.
    func testAppLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 30),
            "Child app did not reach the foreground after launch"
        )
    }

    /// On a fresh simulator the first screen is the model-download gate
    /// (see ModelDownloadView): it is shown instead of the tutor UI
    /// until the readiness gate resolves a usable model. This test
    /// waits for the gate and asserts its stable handles — it never
    /// taps the download button and never blocks on a download.
    func testFirstLaunchShowsModelDownloadGate() {
        let app = XCUIApplication()
        app.launch()
        let gate = app.descendants(matching: .any)["modelDownloadView"].firstMatch
        XCTAssertTrue(
            gate.waitForExistence(timeout: 30),
            "Model-download gate did not appear on fresh launch"
        )
        XCTAssertTrue(
            app.staticTexts["Download tutor model"].exists,
            "Model-download gate title is missing"
        )
    }
}
