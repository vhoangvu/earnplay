import XCTest

/// Child-app feature walkthrough (issue #71): drives the PRODUCTION
/// child UI in fixed step order. Reachable steps assert the expected
/// screen and FAIL when a screen cannot be reached; unreachable
/// features are recorded as named gaps with reasons, never skipped.
///
/// No test taps the download button or waits for a download. Steps
/// past the model gate launch with EARNPLAY_MODEL_PATH pointed at a
/// nonexistent path (see Walkthrough.dummyModelPath).
final class WalkthroughChildTests: WalkthroughTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    // MARK: - Step 1: first launch + model-download gate

    /// Fresh launch shows the model-download gate (title, Wi-Fi-only
    /// copy, download button) plus the pre-invite pairing-code row.
    /// The download button is asserted present and NEVER tapped.
    func testWalkthroughChild01_ModelDownloadGate() {
        let app = Walkthrough.launchChildFresh()
        requireChildDownloadGate(
            app,
            label: "Step 1",
            missingMessage: "Step 1: model-download gate did not appear on fresh launch"
        )
        XCTAssertTrue(
            app.staticTexts["Download tutor model"].waitForExistence(timeout: 10),
            "Step 1: gate title is missing"
        )
        XCTAssertTrue(
            app.buttons["Download over Wi-Fi"].exists,
            "Step 1: download button is missing (it must stay untapped)"
        )
        let code = textStartingWith(app, "Pairing code (show to admin):")
        XCTAssertTrue(
            code.waitForExistence(timeout: 10),
            "Step 1: pre-invite pairing-code row is missing"
        )
        XCTAssertNotNil(
            Walkthrough.trailingPairingCode(in: code.label),
            "Step 1: pairing-code row has no trailing 6-digit code: \(code.label)"
        )
        walkthroughScreenshot(app, named: "child-gate-step01")
    }

    // MARK: - Step 7 (on the gate): About + Llama attribution

    /// The gate's About section shows the "Built with Llama" label,
    /// the shipped Notice text, and the bundled Llama 3.2 Community
    /// License behind its disclosure. (Step 7 of the task order runs
    /// here because About lives on the gate screen.)
    func testWalkthroughChild02_AboutAndLicense() {
        let app = Walkthrough.launchChildFresh()
        requireChildDownloadGate(
            app,
            label: "Step 7",
            missingMessage: "Step 7: model-download gate did not appear on fresh launch"
        )
        XCTAssertTrue(
            app.staticTexts["About"].waitForExistence(timeout: 10),
            "Step 7: About header is missing from the gate"
        )
        let builtWith = app.staticTexts["Built with Llama"]
        scrollIntoView(builtWith, in: app)
        XCTAssertTrue(builtWith.exists, "Step 7: 'Built with Llama' label is missing")
        let notice = textContaining(
            app, "Llama 3.2 is licensed under the Llama 3.2 Community License")
        scrollIntoView(notice, in: app)
        XCTAssertTrue(
            notice.exists,
            "Step 7: bundled Notice attribution sentence is missing"
        )
        walkthroughScreenshot(app, named: "child-about-step02")
        // The DisclosureGroup exposes as a button; the Notice caption
        // carries similar words, so match buttons only.
        let disclosure = app.buttons["Llama 3.2 Community License"]
        scrollIntoView(disclosure, in: app)
        XCTAssertTrue(
            disclosure.waitForExistence(timeout: 10),
            "Step 7: license disclosure is missing"
        )
        disclosure.tap()
        let licenseBody = textContaining(app, "LLAMA 3.2 COMMUNITY LICENSE AGREEMENT")
        XCTAssertTrue(
            licenseBody.waitForExistence(timeout: 10),
            "Step 7: expanded license text is missing"
        )
        walkthroughScreenshot(app, named: "child-about-license-step02")
    }

    // MARK: - Step 2: setup flow (authorization step)

    /// Model-ready launch reaches the setup wizard's authorization
    /// step. Requesting authorization on the simulator fails with the
    /// honest no-Screen-Time error and the wizard stays put.
    func testWalkthroughChild03_SetupAuthorization() {
        let app = Walkthrough.launchChildModelReady()
        XCTAssertTrue(
            app.navigationBars["Set up EarnPlay"].waitForExistence(timeout: 30),
            "Step 2: setup wizard did not appear on model-ready launch"
        )
        XCTAssertTrue(
            app.staticTexts["Allow Screen Time access"].waitForExistence(timeout: 10),
            "Step 2: authorization step header is missing"
        )
        let request = app.buttons["Request Screen Time access"]
        XCTAssertTrue(request.exists, "Step 2: authorization request button is missing")
        request.tap()
        let error = textContaining(app, "simulator has no Screen Time authorization")
        XCTAssertTrue(
            error.waitForExistence(timeout: 20),
            "Step 2: expected the honest simulator authorization error"
        )
        XCTAssertTrue(
            app.staticTexts["Allow Screen Time access"].exists,
            "Step 2: wizard left the authorization step after a denial"
        )
        walkthroughScreenshot(app, named: "child-setup-auth-step03")
    }

    // MARK: - Step 2 (rest): setup completion gap

    /// Gap SETUP-COMPLETION: enumeration, selection, delete-prevention
    /// guidance, and the completion summary are unreachable — setup
    /// cannot advance past authorization on the simulator.
    func testWalkthroughChild04_SetupCompletionGap() {
        let app = Walkthrough.launchChildModelReady()
        XCTAssertTrue(
            app.navigationBars["Set up EarnPlay"].waitForExistence(timeout: 30),
            "Gap SETUP-COMPLETION: setup wizard did not appear"
        )
        XCTAssertTrue(
            app.staticTexts["Allow Screen Time access"].exists,
            "Gap SETUP-COMPLETION: authorization step is not showing"
        )
        walkthroughScreenshot(app, named: "child-setup-blocked-step04")
        recordGap(
            id: "SETUP-COMPLETION",
            feature: "Setup flow start to finish",
            reached: "Authorization step only (request fails honestly on simulator).",
            reason: "The simulator has no Screen Time authorization (requesting fails; " +
                "the FamilyControls entitlement is not filed), and production wires the real " +
                "authorization service with no test seam. The FamilyActivityPicker enumeration " +
                "step is likewise unusable on the simulator.",
            unblock: "Run on a device with the FamilyControls entitlement, or make the " +
                "product decision to add a test-only setup path (an app behavior change, " +
                "out of scope for this task)."
        )
    }

    // MARK: - Step 3: practice session gap

    /// Gap PRACTICE: the full practice session (question, hint, wrong
    /// answer + probe, completion) is unreachable — the chat UI needs
    /// setup completion. The deterministic script it will drive is
    /// validated here so it is ready when setup unblocks.
    func testWalkthroughChild05_PracticeSessionGap() {
        XCTAssertNil(
            ScriptedPracticeSession.validationError(),
            "Gap PRACTICE: scripted practice session is invalid"
        )
        let app = Walkthrough.launchChildModelReady()
        XCTAssertTrue(
            app.navigationBars["Set up EarnPlay"].waitForExistence(timeout: 30),
            "Gap PRACTICE: setup wizard did not appear"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["chatConversationView"].waitForExistence(timeout: 5),
            "Gap PRACTICE: chat UI is unexpectedly reachable"
        )
        walkthroughScreenshot(app, named: "child-practice-blocked-step05")
        recordGap(
            id: "PRACTICE",
            feature: "Full practice session with example data",
            reached: "Nothing past setup; the chat screen never appears.",
            reason: "ChatConversationView renders only when setup.step == .complete, and " +
                "setup cannot complete on the simulator (gap SETUP-COMPLETION). The practice " +
                "engine itself needs no model inference (verified fallback bank), so setup " +
                "completion is the only blocker.",
            unblock: "Unblock gap SETUP-COMPLETION, then drive ScriptedPracticeSession " +
                "(test target): Q1 presented -> Hint -> wrong answer '55' -> probe -> " +
                "explanation -> '56' -> '54' -> '99' -> 'Practice complete. Nice work.'."
        )
    }

    // MARK: - Step 4: unlock-path gaps

    /// Gap EFFORT-UNLOCK: the effort-based unlock earned through
    /// practice has no reachable production UI surface.
    func testWalkthroughChild06_EffortUnlockGap() {
        let app = Walkthrough.launchChildModelReady()
        XCTAssertTrue(
            app.navigationBars["Set up EarnPlay"].waitForExistence(timeout: 30),
            "Gap EFFORT-UNLOCK: setup wizard did not appear"
        )
        walkthroughScreenshot(app, named: "child-effort-unlock-blocked-step06")
        recordGap(
            id: "EFFORT-UNLOCK",
            feature: "Effort-based unlock earned through practice",
            reached: "Nothing: practice itself is blocked (gap PRACTICE).",
            reason: "No production screen after practice completion offers an unlock: the " +
                "chat completion state offers only 'Start again'. Unlock duration settings " +
                "exist only in the admin policy editor (driven in Admin03).",
            unblock: "Unblock gap PRACTICE and add a production post-practice unlock " +
                "surface (an app behavior change, out of scope for this task)."
        )
    }

    /// Gap MOVEMENT-TRADE: the movement trade (offer, accept,
    /// completion) is unreachable — its only view is a DEBUG-only
    /// preview in the dead harness.
    func testWalkthroughChild07_MovementTradeGap() {
        let app = Walkthrough.launchChildModelReady()
        XCTAssertTrue(
            app.navigationBars["Set up EarnPlay"].waitForExistence(timeout: 30),
            "Gap MOVEMENT-TRADE: setup wizard did not appear"
        )
        walkthroughScreenshot(app, named: "child-movement-trade-blocked-step07")
        recordGap(
            id: "MOVEMENT-TRADE",
            feature: "Movement trade (offer, accept, completion)",
            reached: "Nothing: no production screen presents a movement trade.",
            reason: "MovementTradePreviewView is an explicit T3.1 preview harness with a " +
                "DEBUG-only simulate trigger, reachable only from ContentView.previewHarnesses, " +
                "which is dead code (never rendered). Production offers arrive only via the " +
                "tutor's presentOffer call, which no reachable screen makes.",
            unblock: "Wire trade offers into the production practice flow (an app behavior " +
                "change, out of scope); the simulator already replays fixture motion."
        )
    }

    /// Gap CHORE-TRADE: the chore trade (offer, accept, confirm,
    /// granted) is unreachable — its only view is a placeholder host
    /// in the dead harness. The seeded pool it will offer from is
    /// validated here (and stocked through the admin editor in
    /// Admin03).
    func testWalkthroughChild08_ChoreTradeGap() {
        XCTAssertNil(
            SeededChorePool.validationError(),
            "Gap CHORE-TRADE: seeded chore pool is invalid"
        )
        let app = Walkthrough.launchChildModelReady()
        XCTAssertTrue(
            app.navigationBars["Set up EarnPlay"].waitForExistence(timeout: 30),
            "Gap CHORE-TRADE: setup wizard did not appear"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["offerCard"].waitForExistence(timeout: 5),
            "Gap CHORE-TRADE: chore offer card is unexpectedly reachable"
        )
        walkthroughScreenshot(app, named: "child-chore-trade-blocked-step08")
        recordGap(
            id: "CHORE-TRADE",
            feature: "Chore trade (offer, accept, confirm, granted)",
            reached: "Nothing: no production screen presents a chore trade.",
            reason: "ChoreTradeView is a placeholder host ('the chat view will inject its " +
                "recorder') reachable only from ContentView.previewHarnesses, which is dead " +
                "code (never rendered).",
            unblock: "Wire the chore trade into the production practice flow (an app " +
                "behavior change, out of scope), then drive offer -> Accept -> Done -> " +
                "'Parent: Confirm completion' -> granted text with SeededChorePool."
        )
    }

    // MARK: - Step 5: simulated-shield gap

    /// Gap SHIELDS: the simulated shield (ON state, challenge,
    /// countdown) is unreachable — its only view lives in the dead
    /// harness and nothing reachable consumes the force flag.
    func testWalkthroughChild09_SimulatedShieldGap() {
        let app = Walkthrough.launchChildModelReady()
        XCTAssertTrue(
            app.navigationBars["Set up EarnPlay"].waitForExistence(timeout: 30),
            "Gap SHIELDS: setup wizard did not appear"
        )
        walkthroughScreenshot(app, named: "child-shields-blocked-step09")
        recordGap(
            id: "SHIELDS",
            feature: "Simulated shield (ON state, challenge, countdown)",
            reached: "Nothing: no production screen shows shield state.",
            reason: "SimulatedShieldDemoView is reachable only from " +
                "ContentView.previewHarnesses, which is dead code (never rendered), and " +
                "SimulatedShieldMode.isForced() is consumed only by that demo view. Real " +
                "FamilyControls shields are out of scope for this task.",
            unblock: "Add a production shield surface that consumes the simulated-shield " +
                "mode (an app behavior change, out of scope), then drive ON state -> " +
                "challenge -> countdown."
        )
    }

    // MARK: - Step 6: pairing sheet gap

    /// Gap PAIRING-SHEET: the pre-invite code row is reachable, but
    /// the pairing sheet (and its decline path) needs a live incoming
    /// invitation, which stays a manual item.
    func testWalkthroughChild10_PairingSheetGap() {
        let app = Walkthrough.launchChildFresh()
        requireChildDownloadGate(
            app,
            label: "Gap PAIRING-SHEET",
            missingMessage: "Gap PAIRING-SHEET: model-download gate did not appear"
        )
        let code = textStartingWith(app, "Pairing code (show to admin):")
        XCTAssertTrue(
            code.waitForExistence(timeout: 10),
            "Gap PAIRING-SHEET: pre-invite pairing-code row is missing"
        )
        XCTAssertNotNil(
            Walkthrough.trailingPairingCode(in: code.label),
            "Gap PAIRING-SHEET: pairing-code row has no trailing 6-digit code"
        )
        XCTAssertFalse(
            app.buttons["Accept pairing"].waitForExistence(timeout: 5),
            "Gap PAIRING-SHEET: a pairing sheet is unexpectedly showing"
        )
        walkthroughScreenshot(app, named: "child-pairing-code-step10")
        recordGap(
            id: "PAIRING-SHEET",
            feature: "Pairing sheet presentation and decline path",
            reached: "Pre-invite code row only; no sheet without a live invitation.",
            reason: "ChildPairingRequestSheet presents only when the sync controller holds " +
                "a pending untrusted pairing request, which needs a live admin peer inviting " +
                "over Bluetooth. Full two-device live pairing stays a manual T5.4/T7.5 item " +
                "and is not attempted here.",
            unblock: "Manual two-device pairing rehearsal (T5.4/T7.5), which exercises " +
                "the sheet's Accept/Decline paths."
        )
    }
}
