import XCTest

/// T7.8 theme-picker UI tests: both apps launch cleanly, both pickers
/// list all 16 theme names, switching re-renders, and relaunch keeps
/// the selection.
///
/// State: each test normalizes its app to Light Pink rounded on entry
/// (tapping the row when a previous run persisted another selection),
/// so reruns on a dirty simulator still exercise switch + persist;
/// the fresh-install default is asserted only when already selected.
/// The child leg additionally requires the download gate (erased sim
/// for reruns, like the walkthrough child steps).
final class ThemePickerUITests: WalkthroughTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    static let themeNames = [
        "Calm Forest, rounded",
        "Calm Forest, sharp",
        "Warm Playful, rounded",
        "Warm Playful, sharp",
        "Sky Blueprint, rounded",
        "Sky Blueprint, sharp",
        "System Native, rounded",
        "System Native, sharp",
        "Canonical (design docs), rounded",
        "Canonical (design docs), sharp",
        "Blush Pink, rounded",
        "Blush Pink, sharp",
        "Hot Pink, rounded",
        "Hot Pink, sharp",
        "Light Pink, rounded",
        "Light Pink, sharp",
    ]

    static let themeIDs = [
        "calm-forest-rounded",
        "calm-forest-sharp",
        "warm-playful-rounded",
        "warm-playful-sharp",
        "sky-blueprint-rounded",
        "sky-blueprint-sharp",
        "system-native-rounded",
        "system-native-sharp",
        "canonical-rounded",
        "canonical-sharp",
        "blush-pink-rounded",
        "blush-pink-sharp",
        "hot-pink-rounded",
        "hot-pink-sharp",
        "light-pink-rounded",
        "light-pink-sharp",
    ]

    // MARK: - Child (About screen on the download gate)

    func testChildThemePickerListsSwitchesAndPersists() {
        let app = Walkthrough.launchChildFresh()
        requireChildDownloadGate(
            app,
            label: "ThemePicker-Child",
            missingMessage: "ThemePicker-Child: download gate did not appear on fresh launch"
        )
        XCTAssertTrue(
            app.staticTexts["Download tutor model"].waitForExistence(timeout: 10),
            "ThemePicker-Child: gate title is missing (app did not launch cleanly)"
        )

        let pickerTitle = app.descendants(matching: .any)["themePickerTitle"].firstMatch
        scrollIntoView(pickerTitle, in: app)
        XCTAssertTrue(
            pickerTitle.waitForExistence(timeout: 10),
            "ThemePicker-Child: theme picker is missing from the About screen"
        )
        assertAll16Rows(app, label: "ThemePicker-Child")

        // Normalize to Light Pink rounded (fresh sims already select it,
        // which asserts the default; reruns tap it explicitly).
        normalizeSelection(app, label: "ThemePicker-Child")
        assertSelected(app, id: "light-pink-rounded", label: "ThemePicker-Child")

        // Switch: tapping Hot Pink sharp re-renders (preview label +
        // row values flip to the new selection).
        selectRow(app, id: "hot-pink-sharp", label: "ThemePicker-Child")
        assertSelected(app, id: "hot-pink-sharp", label: "ThemePicker-Child")
        assertPreview(app, name: "Hot Pink, sharp", label: "ThemePicker-Child")
        walkthroughScreenshot(app, named: "child-theme-switched")

        // Relaunch keeps the selection (same simulator, app data kept).
        app.terminate()
        let relaunched = Walkthrough.launchChildFresh()
        requireChildDownloadGate(
            relaunched,
            label: "ThemePicker-Child",
            missingMessage: "ThemePicker-Child: download gate did not appear after relaunch"
        )
        let pickerTitleAgain = relaunched.descendants(matching: .any)["themePickerTitle"].firstMatch
        scrollIntoView(pickerTitleAgain, in: relaunched)
        XCTAssertTrue(
            pickerTitleAgain.waitForExistence(timeout: 10),
            "ThemePicker-Child: theme picker is missing after relaunch"
        )
        assertSelected(relaunched, id: "hot-pink-sharp", label: "ThemePicker-Child-relaunch")
        assertPreview(relaunched, name: "Hot Pink, sharp", label: "ThemePicker-Child-relaunch")
        walkthroughScreenshot(relaunched, named: "child-theme-relaunched")
    }

    // MARK: - Admin (Version tab)

    func testAdminThemePickerListsSwitchesAndPersists() {
        let app = Walkthrough.launchAdmin()
        XCTAssertTrue(
            app.tabBars.firstMatch.waitForExistence(timeout: 30),
            "ThemePicker-Admin: tab bar did not appear after launch"
        )
        let versionTab = app.tabBars.buttons["Version"]
        XCTAssertTrue(
            versionTab.waitForExistence(timeout: 10),
            "ThemePicker-Admin: 'Version' tab is missing"
        )
        versionTab.tap()

        let pickerTitle = app.descendants(matching: .any)["themePickerTitle"].firstMatch
        scrollIntoView(pickerTitle, in: app)
        XCTAssertTrue(
            pickerTitle.waitForExistence(timeout: 10),
            "ThemePicker-Admin: theme picker is missing from the Version tab"
        )
        assertAll16Rows(app, label: "ThemePicker-Admin")

        normalizeSelection(app, label: "ThemePicker-Admin")
        assertSelected(app, id: "light-pink-rounded", label: "ThemePicker-Admin")

        // Switch to a different theme than the child leg, proving the
        // apps persist their own selections independently.
        selectRow(app, id: "blush-pink-sharp", label: "ThemePicker-Admin")
        assertSelected(app, id: "blush-pink-sharp", label: "ThemePicker-Admin")
        assertPreview(app, name: "Blush Pink, sharp", label: "ThemePicker-Admin")
        walkthroughScreenshot(app, named: "admin-theme-switched")

        app.terminate()
        let relaunched = Walkthrough.launchAdmin()
        XCTAssertTrue(
            relaunched.tabBars.firstMatch.waitForExistence(timeout: 30),
            "ThemePicker-Admin: tab bar did not appear after relaunch"
        )
        relaunched.tabBars.buttons["Version"].tap()
        let pickerTitleAgain = relaunched.descendants(matching: .any)["themePickerTitle"].firstMatch
        scrollIntoView(pickerTitleAgain, in: relaunched)
        XCTAssertTrue(
            pickerTitleAgain.waitForExistence(timeout: 10),
            "ThemePicker-Admin: theme picker is missing after relaunch"
        )
        assertSelected(relaunched, id: "blush-pink-sharp", label: "ThemePicker-Admin-relaunch")
        assertPreview(relaunched, name: "Blush Pink, sharp", label: "ThemePicker-Admin-relaunch")
        walkthroughScreenshot(relaunched, named: "admin-theme-relaunched")
    }

    // MARK: - Helpers

    /// Every one of the 16 exact names renders as a picker row. The
    /// pickers live in eager ScrollViews (never lazy), so every row
    /// exists in the tree without scrolling.
    private func assertAll16Rows(_ app: XCUIApplication, label: String) {
        XCTAssertEqual(Self.themeNames.count, 16)
        XCTAssertEqual(Self.themeIDs.count, 16)
        for (name, id) in zip(Self.themeNames, Self.themeIDs) {
            let row = app.descendants(matching: .any)["themeRow_\(id)"].firstMatch
            XCTAssertTrue(
                row.waitForExistence(timeout: 10),
                "\(label): picker row '\(name)' (themeRow_\(id)) is missing"
            )
            XCTAssertEqual(row.label, name, "\(label): row themeRow_\(id) has the wrong label")
        }
    }

    /// Normalizes the selection to Light Pink rounded. On a fresh
    /// install it is already selected (asserting the default); on a
    /// rerun the persisted row is tapped back explicitly.
    private func normalizeSelection(_ app: XCUIApplication, label: String) {
        let defaultRow = app.descendants(matching: .any)["themeRow_light-pink-rounded"].firstMatch
        XCTAssertTrue(
            defaultRow.waitForExistence(timeout: 10),
            "\(label): light-pink-rounded row is missing"
        )
        if (defaultRow.value as? String) != "selected" {
            NSLog("THEME-PICKER %@: normalizing a persisted selection back to Light Pink rounded", label)
            scrollIntoView(defaultRow, in: app)
            defaultRow.tap()
        }
        XCTAssertEqual(
            defaultRow.value as? String, "selected",
            "\(label): Light Pink, rounded is not the selected theme"
        )
    }

    private func selectRow(_ app: XCUIApplication, id: String, label: String) {
        let row = app.descendants(matching: .any)["themeRow_\(id)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(label): row themeRow_\(id) is missing")
        scrollIntoView(row, in: app)
        row.tap()
    }

    /// Exactly one row reports selected: the picked id.
    private func assertSelected(_ app: XCUIApplication, id selectedID: String, label: String) {
        for id in Self.themeIDs {
            let row = app.descendants(matching: .any)["themeRow_\(id)"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "\(label): row themeRow_\(id) is missing")
            XCTAssertEqual(
                row.value as? String, id == selectedID ? "selected" : "not selected",
                "\(label): row themeRow_\(id) selection state is wrong"
            )
        }
    }

    /// The live preview re-renders with the selection's name.
    private func assertPreview(_ app: XCUIApplication, name: String, label: String) {
        let preview = app.descendants(matching: .any)["themePreview"].firstMatch
        XCTAssertTrue(
            preview.waitForExistence(timeout: 10),
            "\(label): theme preview is missing"
        )
        XCTAssertEqual(preview.label, "Theme preview: \(name)", "\(label): preview did not re-render")
    }
}
