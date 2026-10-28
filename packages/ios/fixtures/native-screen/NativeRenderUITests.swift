import XCTest

final class NativeRenderUITests: XCTestCase {
    func testCheckpointBurstBackgroundSaveAndDeletionSurviveProcessRelaunch() {
        let app = XCUIApplication()
        func openCheckpoint() {
            let open = app.buttons["open-checkpoint"]
            XCTAssertTrue(open.waitForExistence(timeout: 15))
            open.tap()
            XCTAssertTrue(app.staticTexts["checkpoint-status"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.webViews.firstMatch.exists)
        }
        app.launch()
        openCheckpoint()
        let originalSession = app.staticTexts["checkpoint-session"].label
        XCTAssertFalse(originalSession.isEmpty)
        app.buttons["checkpoint-reset"].tap()
        waitForLabel(app.staticTexts["checkpoint-status"], "Checkpoint absent")
        app.buttons["checkpoint-save"].tap()
        waitForLabel(app.staticTexts["checkpoint-status"], "Recovered: 32 (burst)")

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        waitForLabel(app.staticTexts["checkpoint-status"], "Recovered: 33 (background)")
        // This kills the app process, not just its screen/JS context. The next
        // public snapshot read must come from disk, not the shared native cache.
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        app.launch()
        openCheckpoint()
        XCTAssertNotEqual(app.staticTexts["checkpoint-session"].label, originalSession)
        waitForLabel(app.staticTexts["checkpoint-status"], "Recovered: 33 (background)")
        let recovered = XCTAttachment(screenshot: app.screenshot())
        recovered.name = "Native checkpoint recovered after background save and process relaunch"
        recovered.lifetime = .keepAlways
        add(recovered)

        app.buttons["checkpoint-reset"].tap()
        waitForLabel(app.staticTexts["checkpoint-status"], "Checkpoint absent")
        app.terminate()
        app.launch()
        openCheckpoint()
        waitForLabel(app.staticTexts["checkpoint-status"], "Checkpoint absent")
    }

    func testSolidSwitchTapsDragsAndControlledEchoAvoidUIKitTracking() {
        let app = XCUIApplication()
        app.launch()
        let open = app.buttons["open-solid"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()
        let toggle = app.descendants(matching: .any).matching(identifier: "solid-switch").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        waitForValue(toggle, "1")
        waitForLabel(app.staticTexts["solid-result"], "Solid on: 1")
        toggle.tap()
        waitForValue(toggle, "0")
        waitForLabel(app.staticTexts["solid-result"], "Solid off: 2")
        let left = toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        let right = toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        left.press(forDuration: 0.1, thenDragTo: right)
        waitForValue(toggle, "1")
        waitForLabel(app.staticTexts["solid-result"], "Solid on: 3")
        let image = XCTAttachment(screenshot: toggle.screenshot())
        image.lifetime = .keepAlways
        add(image)
        right.press(forDuration: 0.1, thenDragTo: left)
        waitForValue(toggle, "0")
        waitForLabel(app.staticTexts["solid-result"], "Solid off: 4")
        app.buttons["disable-solid"].tap()
        XCTAssertFalse(toggle.isEnabled)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForLabel(app.staticTexts["solid-result"], "Solid off: 4")
        app.buttons["restore-native"].tap()
        let native = app.switches["solid-switch"]
        XCTAssertTrue(native.waitForExistence(timeout: 5))
        native.tap()
        waitForLabel(app.staticTexts["solid-result"], "Solid on: 5")
    }

    /// Record this alongside testSwitchTapChangesUIKitStateAndDeliversValueChange
    /// when investigating animation artifacts. A final value assertion alone
    /// cannot prove the thumb was visible in every intermediate frame.
    func testUnmodifiedUIKitSwitchRespondsToTheSameTap() {
        let app = XCUIApplication()
        app.launchArguments = ["--reference-switch"]
        app.launch()
        let toggle = app.switches["reference-switch"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap()
        waitForValue(toggle, "1")
        toggle.tap()
        waitForValue(toggle, "0")
    }

    private func keyboardIsVisible(_ app: XCUIApplication) -> Bool {
        app.keyboards.firstMatch.waitForExistence(timeout: 5)
    }

    /// Event synthesis, the native accessibility snapshot, and the script's
    /// derived label settle separately. Await the complete native value as
    /// well as its echo: a partial value must never satisfy either check.
    @discardableResult
    private func waitForValue(_ element: XCUIElement, _ expected: String, timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let matched = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: element)], timeout: timeout) == .completed
        XCTAssertTrue(matched, "\(element.identifier) reads \"\(String(describing: element.value))\", not \"\(expected)\", \(timeout)s after input", file: file, line: line)
        return matched
    }

    @discardableResult
    private func waitForLabel(_ element: XCUIElement, _ expected: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let matched = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: element)], timeout: timeout) == .completed
        XCTAssertTrue(matched, "\(element.identifier) reads \(String(reflecting: element.label)), not \(String(reflecting: expected)), \(timeout)s after input", file: file, line: line)
        return matched
    }

    func testNativePagerFingerSwipesAndControlledSelectionExposeOnlyCurrentPage() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertFalse(app.webViews.firstMatch.exists)
        let open = app.buttons["open-pager"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()
        let status = app.staticTexts["pager-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        waitForLabel(status, "Page 1 of 3")
        let pager = app.scrollViews["native-pager"]
        XCTAssertTrue(pager.exists)
        XCTAssertTrue(app.staticTexts["pager-page-0"].isHittable)
        XCTAssertFalse(app.staticTexts["pager-page-1"].exists, "Off-screen page should not enter the accessibility tree")
        pager.swipeLeft()
        waitForLabel(status, "Page 2 of 3")
        XCTAssertTrue(app.staticTexts["pager-page-1"].isHittable)
        XCTAssertFalse(app.staticTexts["pager-page-0"].exists)
        app.buttons["pager-last"].tap()
        waitForLabel(status, "Page 3 of 3")
        XCTAssertTrue(app.staticTexts["pager-page-2"].isHittable)
        XCTAssertFalse(app.staticTexts["pager-page-1"].exists)
        pager.swipeRight()
        waitForLabel(status, "Page 2 of 3")
        XCTAssertTrue(app.staticTexts["pager-page-1"].isHittable)
        XCTAssertFalse(app.staticTexts["pager-page-2"].exists)
    }

    func testTypingAndButtonUpdatesDoNotDropTheKeyboard() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertFalse(app.webViews.firstMatch.exists, "native mode created a WebView")
        let field = app.textFields["name-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("Ada")
        waitForValue(field, "Ada")
        waitForLabel(app.staticTexts["name"], "Hello Ada")
        XCTAssertTrue(keyboardIsVisible(app))

        for count in 1...3 {
            app.buttons["increment"].tap()
            waitForLabel(app.staticTexts["count"], "Count: \(count)")
            XCTAssertTrue(
                keyboardIsVisible(app),
                "state update \(count) dismissed the keyboard"
            )
            field.typeText("x")
            waitForValue(field, "Ada" + String(repeating: "x", count: count))
            waitForLabel(app.staticTexts["name"], "Hello Ada" + String(repeating: "x", count: count))
        }
    }

    /// A multiline TextInput is a text view to UI tests and VoiceOver, and
    /// takes the keyboard: its accessibility traits must keep UITextView's own.
    func testMultilineTextInputTakesTyping() throws {
        let app = XCUIApplication()
        app.launch()
        let notes = app.textViews["notes-input"]
        XCTAssertTrue(notes.waitForExistence(timeout: 15), "the multiline input is not exposed as a text view")
        notes.tap()
        XCTAssertTrue(keyboardIsVisible(app))
        notes.typeText("Easy run")
        waitForValue(notes, "Easy run")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "typing dismissed the native keyboard")
        waitForLabel(app.staticTexts["notes"], "Notes: Easy run")
    }

    func testSwitchTapChangesUIKitStateAndDeliversValueChange() throws {
        let app = XCUIApplication()
        app.launch()
        let toggle = app.switches["native-switch"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap()
        // UIKit's accessibility snapshot and the script-thread echo settle
        // independently. One tap must reach both states, without retrying it.
        let nativeChanged = waitForValue(toggle, "1")
        let modelChanged = waitForLabel(app.staticTexts["switch-result"], "Switch on")
        if !nativeChanged || !modelChanged {
            XCTContext.runActivity(named: "Switch state after one tap") { context in
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.lifetime = .keepAlways
                context.add(screenshot)
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.lifetime = .keepAlways
                context.add(hierarchy)
            }
        }
        // A controlled echo must leave the same control able to toggle back;
        // verify both directions rather than just the first settled frame.
        toggle.tap()
        waitForValue(toggle, "0")
        waitForLabel(app.staticTexts["switch-result"], "Switch off")
    }

    func testSwitchInsideScrollViewTakesOneTap() throws {
        let app = XCUIApplication()
        app.launch()
        let toggle = app.switches["scroll-switch"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap()
        // UIKit's accessibility snapshot and the script-thread echo settle
        // independently. One tap must reach both states, without retrying it.
        let nativeChanged = waitForValue(toggle, "1")
        let modelChanged = waitForLabel(app.staticTexts["switch-result"], "Switch on")
        if !nativeChanged || !modelChanged {
            XCTContext.runActivity(named: "Switch state after one tap") { context in
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.lifetime = .keepAlways
                context.add(screenshot)
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.lifetime = .keepAlways
                context.add(hierarchy)
            }
        }
    }

    /// A drag that starts on a button scrolls the page, and presses nothing.
    /// UIKit leaves a touch with the control it began on unless the scroll
    /// view cancels it, so on a page made of buttons - a trail page's map
    /// controls, a form's pickers - a drag from most places did nothing.
    func testADragThatStartsOnAButtonScrolls() throws {
        let app = XCUIApplication()
        app.launch()
        let first = app.buttons["scroll-button-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        let before = first.frame.minY
        let start = app.buttons["scroll-button-2"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -100)), withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertLessThan(first.frame.minY, before - 40, "a drag from a button did not scroll its scroll view")
        XCTAssertEqual(app.staticTexts["scroll-presses"].label, "Scroll presses: 0", "the drag pressed the button it started on")
        // A tap still presses one.
        app.buttons["scroll-button-3"].tap()
        XCTAssertEqual(app.staticTexts["scroll-presses"].label, "Scroll presses: 1")
    }
}
