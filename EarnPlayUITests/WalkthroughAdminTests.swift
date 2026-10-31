import XCTest

/// Admin-app feature walkthrough (issue #71): drives the PRODUCTION
/// admin UI from this same UI-test target via its bundle identifier.
/// Tab order walked: Progress -> Policy -> Sessions -> Auditor ->
/// Version. Reachable steps assert the expected screen and FAIL when a
/// screen cannot be reached; states that need live-synced sessions are
/// recorded as named gaps with reasons, never skipped.
final class WalkthroughAdminTests: WalkthroughTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    /// Launches the admin app and opens the named tab, failing when
    /// the tab bar never appears.
    func openTab(_ app: XCUIApplication, _ name: String) {
        XCTAssertTrue(
            app.tabBars.firstMatch.waitForExistence(timeout: 30),
            "Admin: tab bar did not appear after launch"
        )
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(
            tab.waitForExistence(timeout: 10),
            "Admin: '\(name)' tab is missing"
        )
        tab.tap()
    }

    // MARK: - Dashboard: empty state (reachable)

    /// Progress tab with no synced sessions shows the explicit empty
    /// state, never zeroes.
    func testWalkthroughAdmin01_DashboardEmpty() {
        let app = Walkthrough.launchAdmin()
        openTab(app, "Progress")
        let empty = app.descendants(matching: .any)["dashboard-empty-state"].firstMatch
        XCTAssertTrue(
            empty.waitForExistence(timeout: 10),
            "Admin01: dashboard empty state did not appear"
        )
        XCTAssertTrue(
            app.staticTexts["No synced sessions yet"].exists,
            "Admin01: empty-state title is missing"
        )
        walkthroughScreenshot(app, named: "admin-dashboard-empty-step01")
    }

    // MARK: - Dashboard: filled-state gap

    /// Gap DASHBOARD-FILLED: the fixture-seeded filled dashboard needs
    /// synced sessions, which only live child sync delivers.
    func testWalkthroughAdmin02_DashboardFilledGap() {
        let app = Walkthrough.launchAdmin()
        openTab(app, "Progress")
        let empty = app.descendants(matching: .any)["dashboard-empty-state"].firstMatch
        XCTAssertTrue(
            empty.waitForExistence(timeout: 10),
            "Gap DASHBOARD-FILLED: dashboard empty state did not appear"
        )
        walkthroughScreenshot(app, named: "admin-dashboard-blocked-step02")
        recordGap(
            id: "DASHBOARD-FILLED",
            feature: "Dashboard fixture-seeded filled state",
            reached: "Empty state only; no sessions ever sync in.",
            reason: "Every dashboard number is computed from SessionLogStore.allLogs, which " +
                "fills only via live Bluetooth sync from the child. The child cannot produce " +
                "sessions (setup cannot complete on the simulator; gap SETUP-COMPLETION), and " +
                "fixtures live in the test target only, never in production code.",
            unblock: "Unblock child setup + practice and pair the devices (manual T5.4/T7.5), " +
                "then re-walk the Progress tab with synced sessions."
        )
    }

    // MARK: - Policy editor: every section + save

    /// Policy tab: walks every section including below-the-fold ones,
    /// stocks one example chore from SeededChorePool, saves, and
    /// asserts the save status. Re-runnable: the appended row is
    /// identified by exclusion (never by predicting its label) and
    /// the version relatively.
    func testWalkthroughAdmin03_PolicyEditor() {
        XCTAssertNil(
            SeededChorePool.validationError(),
            "Admin03: seeded chore pool is invalid"
        )
        let app = Walkthrough.launchAdmin()
        openTab(app, "Policy")
        XCTAssertTrue(
            app.navigationBars["Policy Editor"].waitForExistence(timeout: 10),
            "Admin03: policy editor did not appear"
        )
        let versionLine = textStartingWith(app, "Current version:")
        XCTAssertTrue(
            versionLine.waitForExistence(timeout: 10),
            "Admin03: version section is missing"
        )
        // Every LLD section header, top to bottom; the later ones are
        // below the fold and only appear after scrolling.
        let sections = [
            "Always allowed",
            "Unblockable",
            "Never-unlockable overrides",
            "Unlock durations",
            "Effort floor",
            "Trade caps",
            "Chore pool",
            "Movement trade",
        ]
        for header in sections {
            let element = sectionHeader(app, header)
            scrollIntoView(element, in: app)
            XCTAssertTrue(element.exists, "Admin03: '\(header)' section is missing")
        }
        walkthroughScreenshot(app, named: "admin-policy-sections-step03")

        // Stock one example chore from the seeded pool. A fresh row is
        // labelled "Chore N" (positional: N is the pool size after the
        // append); typing a name relabels it to the name. The pool may
        // already hold saved chores under ANY name from earlier runs,
        // and the Form recycles off-screen rows, so the appended row
        // is identified by exclusion — the one "Chore " label that was
        // not visible before the tap — never by predicting N from
        // visible-label counts. Appending never relabels the existing
        // rows, so exactly one such label appears.
        let seededName = SeededChorePool.entries[0].chore
        let addChore = app.buttons["policyAddChoreButton"]
        scrollIntoView(addChore, in: app)
        XCTAssertTrue(addChore.waitForExistence(timeout: 10), "Admin03: Add chore button is missing")
        let unnamedRows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Chore "))
        let beforeLabels = Set(unnamedRows.allElementsBoundByIndex.map(\.label))
        addChore.tap()
        let appended = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "count == %d", beforeLabels.count + 1),
                object: unnamedRows
            )],
            timeout: 10
        )
        XCTAssertTrue(
            appended == .completed,
            "Admin03: appended chore row did not appear"
        )
        let freshRows = unnamedRows.allElementsBoundByIndex.filter {
            !beforeLabels.contains($0.label)
        }
        XCTAssertEqual(
            freshRows.count, 1,
            "Admin03: expected exactly one appended chore row"
        )
        guard let newRow = freshRows.first else { return }
        let newRowLabel = newRow.label
        newRow.tap()
        let nameField = app.textFields["policyChoreNameField"].firstMatch
        XCTAssertTrue(
            nameField.waitForExistence(timeout: 10),
            "Admin03: chore name field did not appear"
        )
        nameField.tap()
        nameField.typeText(SeededChorePool.entries[0].chore)
        dismissKeyboardIfPresent(app)
        XCTAssertTrue(
            textStartingWith(app, "Unlock minutes:").waitForExistence(timeout: 10),
            "Admin03: chore unlock-minutes stepper is missing"
        )
        // The appended row must now carry the seeded name: its old
        // "Chore N" label is gone and the name field holds the typed
        // name. Checked while the row is on screen, before scrolling
        // to Save (the Form recycles off-screen rows).
        XCTAssertEqual(
            nameField.value as? String, seededName,
            "Admin03: chore name field does not hold the seeded name"
        )
        let relabeled = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"),
                object: app.buttons[newRowLabel]
            )],
            timeout: 10
        )
        XCTAssertTrue(
            relabeled == .completed,
            "Admin03: appended row '\(newRowLabel)' did not relabel to the seeded name"
        )
        walkthroughScreenshot(app, named: "admin-policy-chore-step03")

        // Save and assert the save status (relative: any new version).
        let save = app.buttons["policySaveButton"]
        scrollIntoView(save, in: app)
        XCTAssertTrue(save.waitForExistence(timeout: 10), "Admin03: save button is missing")
        XCTAssertTrue(waitForEnabled(save, timeout: 10), "Admin03: save button never enabled")
        save.tap()
        let status = app.staticTexts["policySaveStatus"]
        XCTAssertTrue(
            status.waitForExistence(timeout: 10),
            "Admin03: save status did not appear"
        )
        XCTAssertTrue(
            status.label.hasPrefix("Saved version"),
            "Admin03: save did not succeed: \(status.label)"
        )
        XCTAssertFalse(
            app.staticTexts["policySaveError"].exists,
            "Admin03: save error is showing"
        )
        walkthroughScreenshot(app, named: "admin-policy-saved-step03")
    }

    // MARK: - Sessions: sync surface, pairing screen, code

    /// Sessions tab: sync status, unpaired line, this device's pairing
    /// code (format-checked), peer-code field with Pair validation, and
    /// the empty sessions list. Live pairing completion stays manual.
    func testWalkthroughAdmin04_SessionsAndPairing() {
        let app = Walkthrough.launchAdmin()
        openTab(app, "Sessions")
        XCTAssertTrue(
            app.navigationBars["Sessions"].waitForExistence(timeout: 10),
            "Admin04: sessions screen did not appear"
        )
        XCTAssertTrue(
            textContaining(app, "Sync started").waitForExistence(timeout: 10),
            "Admin04: sync status line is missing"
        )
        XCTAssertTrue(
            textContaining(app, "Paired: no").exists,
            "Admin04: unpaired sync line is missing"
        )
        let localCode = textStartingWith(app, "This device pairing code:")
        XCTAssertTrue(
            localCode.waitForExistence(timeout: 10),
            "Admin04: this-device pairing code row is missing"
        )
        XCTAssertNotNil(
            Walkthrough.trailingPairingCode(in: localCode.label),
            "Admin04: pairing-code row has no trailing 6-digit code"
        )
        let peerField = app.textFields["Code shown on child"]
        XCTAssertTrue(peerField.waitForExistence(timeout: 10), "Admin04: peer-code field is missing")
        let pair = app.buttons["Pair"]
        XCTAssertTrue(pair.exists, "Admin04: Pair button is missing")
        XCTAssertFalse(pair.isEnabled, "Admin04: Pair is enabled with a blank code")
        peerField.tap()
        peerField.typeText("abc")
        XCTAssertTrue(waitForEnabled(pair, timeout: 10), "Admin04: Pair never enabled")
        pair.tap()
        dismissKeyboardIfPresent(app)
        XCTAssertTrue(
            textContaining(app, "looking for child nearby").waitForExistence(timeout: 10),
            "Admin04: pairing-attempt status did not appear"
        )
        walkthroughScreenshot(app, named: "admin-sessions-pairing-step04")
        XCTAssertTrue(app.buttons["Retry sync now"].exists, "Admin04: retry-sync button is missing")
        XCTAssertTrue(app.buttons["Reset / Unpair"].exists, "Admin04: reset/unpair button is missing")
        let emptySessions = app.staticTexts["No sessions yet"]
        scrollIntoView(emptySessions, in: app)
        XCTAssertTrue(emptySessions.exists, "Admin04: empty sessions list is missing")
        walkthroughScreenshot(app, named: "admin-sessions-list-step04")
    }

    // MARK: - Auditor: clean state (reachable)

    /// Auditor tab with no synced sessions: "No open findings", and a
    /// manual run reports 0 open findings.
    func testWalkthroughAdmin05_AuditorClean() {
        let app = Walkthrough.launchAdmin()
        openTab(app, "Auditor")
        XCTAssertTrue(
            app.navigationBars["Auditor"].waitForExistence(timeout: 10),
            "Admin05: auditor screen did not appear"
        )
        let run = app.buttons["Run auditor over synced sessions"]
        XCTAssertTrue(run.waitForExistence(timeout: 10), "Admin05: run-auditor button is missing")
        run.tap()
        XCTAssertTrue(
            textContaining(app, "Auditor run complete. 0 open finding(s)").waitForExistence(timeout: 15),
            "Admin05: clean auditor run status did not appear"
        )
        XCTAssertTrue(
            app.staticTexts["No open findings"].exists,
            "Admin05: clean-state findings line is missing"
        )
        walkthroughScreenshot(app, named: "admin-auditor-clean-step05")
    }

    // MARK: - Auditor: staged-finding gap

    /// Gap AUDITOR-FINDING: the staged leniency finding needs synced
    /// sessions. The T5.4-moment-4 staging spec it will use is
    /// validated here so it is ready when sync delivers sessions.
    func testWalkthroughAdmin06_AuditorFindingGap() {
        XCTAssertNil(
            StagedLeniencySession.validationError(),
            "Gap AUDITOR-FINDING: staged leniency session is invalid"
        )
        let app = Walkthrough.launchAdmin()
        openTab(app, "Auditor")
        XCTAssertTrue(
            app.navigationBars["Auditor"].waitForExistence(timeout: 10),
            "Gap AUDITOR-FINDING: auditor screen did not appear"
        )
        // The empty-findings section header. iOS 18 exposes List
        // section headers differently than iOS 26+ (see
        // sectionHeader), and may announce the header grouped with
        // its content, so match the exact "Findings (0)" label or any
        // label containing it (no other element on this screen
        // contains that literal). Then pin the section's clean-state
        // row with its exact query as well.
        let findingsHeader = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "Findings (0)", "FINDINGS (0)")
        ).firstMatch
        scrollIntoView(findingsHeader, in: app)
        XCTAssertTrue(
            findingsHeader.waitForExistence(timeout: 10),
            "Gap AUDITOR-FINDING: empty findings section is missing"
        )
        XCTAssertTrue(
            app.staticTexts["No open findings"].exists,
            "Gap AUDITOR-FINDING: clean-state findings row is missing"
        )
        walkthroughScreenshot(app, named: "admin-auditor-blocked-step06")
        recordGap(
            id: "AUDITOR-FINDING",
            feature: "Auditor staged-finding state",
            reached: "Clean state only (0 findings); nothing to stage into.",
            reason: "Findings come from auditing synced session logs, which only live child " +
                "sync delivers (see gap DASHBOARD-FILLED). Engine behavior for the staged " +
                "leniency shape is already pinned by EarnPlayCoreTests/AuditorEngineTests; " +
                "only UI delivery is missing.",
            unblock: "Unblock child setup + practice and pair the devices (manual T5.4/T7.5), " +
                "sync a StagedLeniencySession-shaped set (>= 3 grants, falling effort, " +
                "latest <= first - 4), then re-walk the Auditor tab."
        )
    }

    // MARK: - Version registry (reachable)

    /// Version tab: persisted-registry heading, active bundle (or the
    /// honest load-failure line), rollback operator buttons (asserted
    /// present, never tapped), registered bundles, known limits.
    func testWalkthroughAdmin07_VersionRegistry() {
        let app = Walkthrough.launchAdmin()
        openTab(app, "Version")
        XCTAssertTrue(
            app.staticTexts["Running version (persisted registry)"].waitForExistence(timeout: 10),
            "Admin07: version registry heading is missing"
        )
        let activeBundle = textStartingWith(app, "Active bundle:")
        let loadFailure = textStartingWith(app, "Version unavailable")
        scrollIntoView(activeBundle, in: app)
        XCTAssertTrue(
            activeBundle.exists || loadFailure.exists,
            "Admin07: neither the active bundle nor the honest load-failure line shows"
        )
        XCTAssertTrue(
            app.staticTexts["Rollback operator controls"].exists,
            "Admin07: rollback controls heading is missing"
        )
        XCTAssertTrue(
            app.buttons["Register active bundle as previous known-good"].exists,
            "Admin07: register-known-good button is missing (it must stay untapped)"
        )
        XCTAssertTrue(
            app.buttons["Roll back to previous known-good"].exists,
            "Admin07: rollback button is missing (it must stay untapped)"
        )
        XCTAssertTrue(
            app.buttons["Roll forward to current"].exists,
            "Admin07: roll-forward button is missing (it must stay untapped)"
        )
        let bundles = textStartingWith(app, "Registered bundles:")
        scrollIntoView(bundles, in: app)
        XCTAssertTrue(bundles.exists, "Admin07: registered-bundles line is missing")
        let limits = app.staticTexts["Known limits"]
        scrollIntoView(limits, in: app)
        XCTAssertTrue(limits.exists, "Admin07: known-limits section is missing")
        walkthroughScreenshot(app, named: "admin-version-step07")
    }

    // MARK: - Sessions: filled-list gap

    /// Gap SESSIONS-FILLED: a populated sessions list needs live-synced
    /// sessions.
    func testWalkthroughAdmin08_SessionsFilledGap() {
        let app = Walkthrough.launchAdmin()
        openTab(app, "Sessions")
        XCTAssertTrue(
            app.navigationBars["Sessions"].waitForExistence(timeout: 10),
            "Gap SESSIONS-FILLED: sessions screen did not appear"
        )
        let emptySessions = app.staticTexts["No sessions yet"]
        scrollIntoView(emptySessions, in: app)
        XCTAssertTrue(
            emptySessions.exists,
            "Gap SESSIONS-FILLED: empty sessions list is missing"
        )
        walkthroughScreenshot(app, named: "admin-sessions-blocked-step08")
        recordGap(
            id: "SESSIONS-FILLED",
            feature: "Sessions list with synced sessions",
            reached: "Empty list only ('No sessions yet').",
            reason: "Sessions arrive only via live Bluetooth sync from the child, which " +
                "cannot produce them (setup cannot complete on the simulator; gap " +
                "SETUP-COMPLETION), and live pairing stays a manual T5.4/T7.5 item.",
            unblock: "Unblock child setup + practice and pair the devices (manual T5.4/T7.5), " +
                "then re-walk the Sessions tab."
        )
    }
}
