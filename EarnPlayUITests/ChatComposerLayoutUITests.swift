import XCTest

/// Issue #77: two-row chat composer layout. Launches the child app with the
/// `--earnplay-ui-chat` preview flag (which bypasses the model gate and
/// setup wizard — the chat is otherwise unreachable on the simulator,
/// see gap PRACTICE) and pins the mockup geometry: the answer field spans
/// row 1 full width, and Hint (left) / Send (right) share row 2
/// space-between. A second test drives both submit paths through the
/// rendered controls.
final class ChatComposerLayoutUITests: WalkthroughTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    /// Launches the child app straight into the practice chat.
    private func launchChat() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("--earnplay-ui-chat")
        app.launch()
        return app
    }

    /// Locates the composer controls. By label/placeholder rather than
    /// by identifier: the root view's `chatConversationView` identifier
    /// overrides the descendants' own identifiers in the XCUITest tree
    /// (pre-existing SwiftUI grouping behavior, verified on the base
    /// commit too — the number-pad cells keep theirs because LazyVGrid
    /// breaks the group). The code identifiers stay as the contract.
    private func requireChatComposer(_ app: XCUIApplication) -> (field: XCUIElement, hint: XCUIElement, send: XCUIElement) {
        let chat = app.descendants(matching: .any)["chatConversationView"].firstMatch
        XCTAssertTrue(
            chat.waitForExistence(timeout: 30),
            "Composer: chat UI did not appear with --earnplay-ui-chat"
        )
        let field = app.textFields.firstMatch
        let hint = app.buttons["Hint"].firstMatch
        let send = app.buttons["Send"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Composer: answer field is missing")
        XCTAssertTrue(hint.waitForExistence(timeout: 10), "Composer: Hint button is missing")
        XCTAssertTrue(send.waitForExistence(timeout: 10), "Composer: Send button is missing")
        return (field, hint, send)
    }

    // MARK: - Two-row geometry

    /// Row 1 is the full-width answer field; row 2 holds Hint on the
    /// left and Send on the right.
    func testTwoRowComposerLayout() {
        let app = launchChat()
        let (field, hint, send) = requireChatComposer(app)
        XCTAssertEqual(
            field.placeholderValue, "Type your answer",
            "Composer: answer field placeholder changed"
        )
        let fieldFrame = field.frame
        let hintFrame = hint.frame
        let sendFrame = send.frame
        let geometry = "field=\(fieldFrame) hint=\(hintFrame) send=\(sendFrame)"

        // The field sits above the Hint/Send row with no vertical overlap
        // (1pt tolerance for pixel rounding).
        XCTAssertLessThanOrEqual(
            fieldFrame.maxY, hintFrame.minY + 1.0,
            "Composer: field must sit above Hint (\(geometry))"
        )
        XCTAssertLessThanOrEqual(
            fieldFrame.maxY, sendFrame.minY + 1.0,
            "Composer: field must sit above Send (\(geometry))"
        )

        // Hint is left of Send with a gap between them (space-between).
        XCTAssertLessThan(
            hintFrame.maxX, sendFrame.minX,
            "Composer: Hint must be left of Send (\(geometry))"
        )

        // Hint and Send share row 2: their vertical centers align.
        XCTAssertLessThan(
            abs(hintFrame.midY - sendFrame.midY), 20.0,
            "Composer: Hint and Send must share one row (\(geometry))"
        )

        // The field spans (nearly) the full composer width: its edges
        // align with the row-2 extremes within padding tolerance.
        let rowMinX = min(hintFrame.minX, sendFrame.minX)
        let rowMaxX = max(hintFrame.maxX, sendFrame.maxX)
        XCTAssertLessThan(
            abs(fieldFrame.minX - rowMinX), 24.0,
            "Composer: field left edge must align with the button row (\(geometry))"
        )
        XCTAssertLessThan(
            abs(fieldFrame.maxX - rowMaxX), 24.0,
            "Composer: field right edge must align with the button row (\(geometry))"
        )
        // And the field is wider than either button (previously the
        // field was squeezed between the two buttons).
        XCTAssertGreaterThan(
            fieldFrame.width, hintFrame.width,
            "Composer: field must be wider than Hint (\(geometry))"
        )
        XCTAssertGreaterThan(
            fieldFrame.width, sendFrame.width,
            "Composer: field must be wider than Send (\(geometry))"
        )

        // Chrome contract: Hint stays visible and enabled.
        XCTAssertTrue(hint.isEnabled, "Composer: Hint must never be disabled")

        walkthroughScreenshot(app, named: "child-composer-tworow")
    }

    // MARK: - Submit paths through the rendered controls

    /// Both draft-entry paths submit through the rendered Send
    /// button: the draft is filled via the number pad first (no
    /// keyboard, so Send stays tappable), then by typing in the field
    /// itself. Each submission renders a child bubble with the typed
    /// content. (Keyboard Return inserts a newline in the vertical-axis
    /// field rather than submitting — unchanged pre-existing behavior,
    /// so the field entry submits via Send after dismissing the
    /// keyboard.) Answers follow the deterministic demo script: demo-q1
    /// is 7x8=56 (number-pad composer), demo-q2's answer is 54.
    func testComposerSubmitPaths() {
        let app = launchChat()
        let (field, _, send) = requireChatComposer(app)

        // Path 1: number-pad draft + rendered Send button.
        let key5 = app.descendants(matching: .any)["chatNumberPad_5"].firstMatch
        let key6 = app.descendants(matching: .any)["chatNumberPad_6"].firstMatch
        XCTAssertTrue(key5.waitForExistence(timeout: 10), "Composer: number-pad key 5 is missing")
        XCTAssertTrue(key6.waitForExistence(timeout: 10), "Composer: number-pad key 6 is missing")
        key5.tap()
        key6.tap()
        XCTAssertTrue(send.isHittable, "Composer: Send must be tappable")
        send.tap()
        let firstChild = app.descendants(matching: .any)["childMessage_c1"].firstMatch
        XCTAssertTrue(
            firstChild.waitForExistence(timeout: 10),
            "Composer: Send did not submit the draft (no child bubble)"
        )
        XCTAssertTrue(
            firstChild.label.contains("56"),
            "Composer: first bubble must hold the number-pad draft, got: \(firstChild.label)"
        )

        // Path 2: type in the field, dismiss the keyboard, Send submits
        // the field's content.
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Composer: answer field is missing")
        field.tap()
        field.typeText("54")
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 10),
            "Composer: keyboard did not appear"
        )
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        XCTAssertTrue(
            send.waitForExistence(timeout: 10) && send.isHittable,
            "Composer: Send must be tappable after keyboard dismissal"
        )
        send.tap()
        let secondChild = app.descendants(matching: .any)["childMessage_c2"].firstMatch
        XCTAssertTrue(
            secondChild.waitForExistence(timeout: 10),
            "Composer: Send did not submit the typed draft (no child bubble)"
        )
        XCTAssertTrue(
            secondChild.label.contains("54"),
            "Composer: second bubble must hold the typed draft, got: \(secondChild.label)"
        )

        walkthroughScreenshot(app, named: "child-composer-submit")
    }
}
