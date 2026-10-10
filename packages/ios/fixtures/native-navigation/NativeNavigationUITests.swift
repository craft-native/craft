import XCTest

final class NativeNavigationUITests: XCTestCase {
    private func waitForLabel(
        _ element: XCUIElement,
        _ label: String,
        timeout: TimeInterval = 10
    ) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForLayoutIncrease(
        _ element: XCUIElement,
        from baseline: Int,
        timeout: TimeInterval = 10
    ) -> Bool {
        let predicate = NSPredicate { object, _ in
            guard let candidate = object as? XCUIElement else { return false }
            return Int(candidate.label.split(separator: ":").last ?? "0") ?? 0 > baseline
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForLayoutDecrease(
        _ element: XCUIElement,
        from baseline: CGFloat,
        timeout: TimeInterval = 10
    ) -> Bool {
        let predicate = NSPredicate { object, _ in
            guard let candidate = object as? XCUIElement else { return false }
            return candidate.frame.width < baseline - 20
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func openCapabilities(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["open-capabilities"].waitForExistence(timeout: 15))
        app.buttons["open-capabilities"].tap()
        XCTAssertTrue(app.staticTexts["capabilities-title"].waitForExistence(timeout: 10))
    }

    func testCapabilityPersistenceAndNotificationsAcrossRelaunch() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertFalse(app.webViews.firstMatch.exists, "capability screen created a WebView")
        openCapabilities(app)
        XCTAssertEqual(app.staticTexts["capabilities-platform"].label, "Platform: ios")
        XCTAssertEqual(app.staticTexts["capabilities-state"].label, "App state: active")

        app.buttons["save-capabilities"].tap()
        let status = app.staticTexts["capabilities-status"]
        XCTAssertTrue(waitForLabel(status, "Saved Ada and Grace"), "found \(status.label)")
        app.terminate()
        app.launch()
        openCapabilities(app)
        app.buttons["load-capabilities"].tap()
        XCTAssertTrue(waitForLabel(status, "Loaded Ada and Grace"), "found \(status.label)")

        addUIInterruptionMonitor(withDescription: "Notification permission") { alert in
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
            return false
        }
        app.buttons["test-notifications"].tap()
        app.tap()
        XCTAssertTrue(waitForLabel(
            status,
            "Notifications scheduled and cancelled"
        ), "found \(status.label)")

        app.buttons["test-secure-storage"].tap()
        XCTAssertTrue(waitForLabel(status, "Secure storage roundtrip"), "found \(status.label)")
    }

    func testPushNativeBackSwipeReplaceAndRetainedHomeState() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertFalse(app.webViews.firstMatch.exists, "native navigation created a WebView")
        let rootScroll = app.scrollViews["native-root-scroll"]
        XCTAssertTrue(rootScroll.waitForExistence(timeout: 15))
        let scroll = app.scrollViews["native-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let image = app.images["native-image"]
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(image.frame.minY, scroll.frame.minY + 12, "ScrollView contentContainerStyle did not add top padding")
        XCTAssertEqual(app.staticTexts["home-title"].label, "Home")
        XCTAssertTrue(app.buttons["disabled-button"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["disabled-button"].isEnabled)
        XCTAssertEqual(image.label, "Native pixel")
        XCTAssertTrue(app.staticTexts["image loaded"].waitForExistence(timeout: 5))
        image.tap()
        XCTAssertEqual(app.staticTexts["native-caption"].label, "Image taps: 1")
        XCTAssertTrue(app.images["unsupported-image"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["image failed"].waitForExistence(timeout: 5))
        app.buttons["toggle-image-source"].tap()
        XCTAssertTrue(app.staticTexts["image loaded"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.images["unsupported-image"].label, "Unsupported image")
        app.buttons["toggle-image-tint"].tap()
        XCTAssertTrue(app.staticTexts["image tint off"].waitForExistence(timeout: 5))
        let unsupportedValue = (app.images["unsupported-image"].value as? String) ?? ""
        XCTAssertEqual(unsupportedValue.components(separatedBy: "Unsupported image source").count - 1, 0)
        let styleToggle = app.buttons["toggle-button-style"]
        XCTAssertFalse(styleToggle.isSelected)
        styleToggle.tap()
        XCTAssertTrue(app.staticTexts["button style accented"].waitForExistence(timeout: 5))
        XCTAssertTrue(styleToggle.isSelected)
        XCTAssertTrue(app.buttons["toggle-panel-style"].waitForExistence(timeout: 5))
        app.buttons["toggle-panel-style"].tap()
        XCTAssertTrue(app.staticTexts["panel style off"].waitForExistence(timeout: 5))
        app.buttons["toggle-panel-style"].tap()
        XCTAssertTrue(app.staticTexts["panel style on"].waitForExistence(timeout: 5))
        let nullWidthText = app.staticTexts["null-width-text"]
        XCTAssertTrue(nullWidthText.waitForExistence(timeout: 5))
        let explicitTextWidth = nullWidthText.frame.width
        XCTAssertGreaterThan(explicitTextWidth, 150)
        let nullWidthToggle = app.buttons["toggle-null-width"]
        XCTAssertTrue(nullWidthToggle.waitForExistence(timeout: 5))
        XCTAssertTrue(nullWidthToggle.isHittable, "null-width toggle should remain visible near the top of the native fixture")
        nullWidthToggle.tap()
        XCTAssertTrue(waitForLayoutDecrease(nullWidthText, from: explicitTextWidth), "null width should restore intrinsic text sizing")
        let scrollEnd = app.staticTexts["scroll-end"]
        XCTAssertFalse(scrollEnd.isHittable)
        scroll.swipeUp()
        XCTAssertTrue(scrollEnd.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollEnd.isHittable, "native ScrollView did not reveal overflow content")

        let grid = app.otherElements["grid-wrap"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        let gridFirst = app.staticTexts["grid-first"]
        let gridSecond = app.staticTexts["grid-second"]
        let gridThird = app.staticTexts["grid-third"]
        XCTAssertTrue(gridFirst.exists && gridSecond.exists && gridThird.exists)
        XCTAssertEqual(gridFirst.frame.minY, gridSecond.frame.minY, accuracy: 2, "grid tracks did not share a row")
        XCTAssertGreaterThan(gridSecond.frame.minX, gridFirst.frame.minX, "grid columns did not lay out side by side")
        XCTAssertGreaterThan(gridThird.frame.minY, gridFirst.frame.minY, "grid rows did not advance after the first track")
        let growFirst = app.staticTexts["flex-grow-first"]
        let growSecond = app.staticTexts["flex-grow-second"]
        XCTAssertTrue(growFirst.waitForExistence(timeout: 5))
        XCTAssertTrue(growSecond.exists)
        XCTAssertGreaterThan(growFirst.frame.width, growSecond.frame.width, "flexGrow did not consume remaining main-axis space")

        let link = app.buttons["native-link"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        XCTAssertEqual(link.label, "Open native link")
        XCTAssertEqual(link.value as? String, "ready")
        link.tap()
        XCTAssertTrue(app.staticTexts["link pressed"].waitForExistence(timeout: 5))
        let accessibilityToggle = app.buttons["toggle-link-accessibility"]
        XCTAssertTrue(accessibilityToggle.waitForExistence(timeout: 5))
        accessibilityToggle.tap()
        XCTAssertTrue(app.staticTexts["link accessibility disabled"].waitForExistence(timeout: 5))
        XCTAssertFalse(link.isEnabled)
        accessibilityToggle.tap()
        XCTAssertTrue(app.staticTexts["link accessibility enabled"].waitForExistence(timeout: 5))

        let panel = app.otherElements["native-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        panel.tap()
        XCTAssertTrue(app.staticTexts["panel pressed"].waitForExistence(timeout: 5))
        app.buttons["toggle-panel-accessibility"].tap()
        XCTAssertTrue(app.staticTexts["panel accessibility disabled"].waitForExistence(timeout: 5))
        app.buttons["toggle-panel-accessibility"].tap()
        XCTAssertTrue(app.staticTexts["panel accessibility enabled"].waitForExistence(timeout: 5))
        panel.tap()
        XCTAssertTrue(app.staticTexts["panel pressed"].waitForExistence(timeout: 5))
        let pressable = app.otherElements["native-pressable"]
        XCTAssertTrue(pressable.waitForExistence(timeout: 5))
        pressable.tap()
        XCTAssertTrue(app.staticTexts["pressable pressed"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["pressable-lifecycle"].label, "Press lifecycle: 1/1")
        let disabledPressable = app.otherElements["disabled-pressable"]
        XCTAssertTrue(disabledPressable.waitForExistence(timeout: 5))
        XCTAssertFalse(disabledPressable.isEnabled)
        let longPressPanel = app.otherElements["long-press-panel"]
        XCTAssertTrue(longPressPanel.waitForExistence(timeout: 5))
        longPressPanel.press(forDuration: 1)
        XCTAssertTrue(app.staticTexts["panel long pressed"].waitForExistence(timeout: 5))
        app.buttons["toggle-long-press-accessibility"].tap()
        XCTAssertTrue(app.staticTexts["long press disabled"].waitForExistence(timeout: 5))
        XCTAssertFalse(longPressPanel.isHittable)
        app.buttons["toggle-long-press-accessibility"].tap()
        XCTAssertTrue(app.staticTexts["long press enabled"].waitForExistence(timeout: 5))
        longPressPanel.press(forDuration: 1)
        XCTAssertTrue(app.staticTexts["panel long pressed"].waitForExistence(timeout: 5))
        XCTAssertTrue(link.isEnabled)
        link.tap()
        XCTAssertTrue(app.staticTexts["link pressed"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["justified-text"].waitForExistence(timeout: 5))

        let toggle = app.switches["native-switch"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertTrue(toggle.isEnabled)
        XCTAssertEqual(app.switches["nullable-switch"].value as? String, "1")
        toggle.tap()
        XCTAssertTrue(app.staticTexts["switch on"].waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")

        XCTAssertTrue(app.otherElements["native-picker"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["picker-value"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["picker-value"].label, "one")
        app.buttons["toggle-modal"].tap()
        XCTAssertTrue(app.otherElements["native-modal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["modal-content"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["modal shown"].waitForExistence(timeout: 5))
        app.buttons["toggle-modal"].tap()
        XCTAssertTrue(app.staticTexts["modal dismissed"].waitForExistence(timeout: 5))

        let slider = app.sliders["native-slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.adjust(toNormalizedSliderPosition: 0.8)
        XCTAssertTrue(app.staticTexts["slider moved"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["slider-value"].label, "0.8")
        XCTAssertEqual(app.staticTexts["slider-completions"].label, "Slider completions: 1")

        XCTAssertTrue(app.activityIndicators["native-indicator"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.activityIndicators["stopped-indicator"].waitForExistence(timeout: 5))

        let wrapped = app.otherElements["layout-wrap"]
        XCTAssertTrue(wrapped.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Layout width: 240"].waitForExistence(timeout: 5), "native onLayout did not report a frame")
        app.buttons["toggle-layout-width"].tap()
        XCTAssertTrue(app.staticTexts["Layout width: 180"].waitForExistence(timeout: 5), "native onLayout did not report the responsive width")
        let bounded = app.staticTexts["layout-min"]
        XCTAssertTrue(bounded.exists)
        XCTAssertEqual(bounded.frame.width, 140, accuracy: 2, "maxWidth was not applied")
        let absolute = app.otherElements["layout-absolute"]
        XCTAssertTrue(absolute.exists)
        XCTAssertLessThanOrEqual(absolute.frame.maxX, wrapped.frame.maxX - 8)
        XCTAssertLessThanOrEqual(absolute.frame.maxY, wrapped.frame.maxY - 8)

        let field = app.textFields["name-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        XCTAssertTrue(field.isEnabled)
        let notes = app.textViews["notes-input"]
        XCTAssertTrue(notes.waitForExistence(timeout: 5), "multiline TextInput did not render as UITextView")
        XCTAssertTrue(notes.isEnabled)
        XCTAssertEqual(notes.value as? String, "Draft", "defaultValue was not applied to the native text view")
        let readonly = app.textFields["readonly-input"]
        XCTAssertTrue(readonly.waitForExistence(timeout: 5))
        XCTAssertFalse(readonly.isEnabled)
        XCTAssertEqual(readonly.value as? String, "Read only")
        let password = app.secureTextFields["password-input"]
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        app.buttons["toggle-input-colors"].tap()
        XCTAssertTrue(app.staticTexts["input colors off"].waitForExistence(timeout: 5))
        XCTAssertTrue(field.exists, "removing input colors replaced the native field")
        app.buttons["toggle-input-colors"].tap()
        XCTAssertTrue(app.staticTexts["input colors on"].waitForExistence(timeout: 5))
        XCTAssertTrue(field.exists, "restoring input colors replaced the native field")
        field.tap()
        XCTAssertTrue(app.staticTexts["Focuses: 1"].waitForExistence(timeout: 5))
        field.typeText("Ada")
        XCTAssertEqual(app.staticTexts["greeting"].label, "Hello Ada")
        field.typeText("\n")
        XCTAssertEqual(app.staticTexts["name-submits"].label, "Submits: 1")
        notes.tap()
        XCTAssertTrue(app.staticTexts["notes-focus-text"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["notes-focus-text"].label, "Notes focus: Draft")
        let nameBlurs = app.staticTexts["name-blurs"]
        XCTAssertTrue(nameBlurs.waitForExistence(timeout: 5))
        XCTAssertEqual(nameBlurs.label, "Blurs: 1")
        let nameEndEditings = app.staticTexts["name-end-editings"]
        XCTAssertTrue(nameEndEditings.waitForExistence(timeout: 5))
        XCTAssertEqual(nameEndEditings.label, "End edits: 1")
        app.buttons["toggle-name-mode"].tap()
        let multilineField = app.textViews["name-input"]
        XCTAssertTrue(multilineField.waitForExistence(timeout: 5))
        XCTAssertEqual(multilineField.value as? String, "Ada")
        XCTAssertEqual(app.staticTexts["name-mode"].label, "multiline")
        app.buttons["toggle-name-mode"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Ada")
        XCTAssertEqual(app.staticTexts["name-mode"].label, "single-line")
        notes.typeText("Note")
        notes.typeText("\n")
        XCTAssertEqual(app.staticTexts["name-submits"].label, "Submits: 2")
        app.buttons["increment"].tap()
        let notesBlurs = app.staticTexts["notes-blurs"]
        XCTAssertTrue(notesBlurs.waitForExistence(timeout: 5))
        XCTAssertEqual(notesBlurs.label, "Notes blurs: 1")
        let notesEndEditings = app.staticTexts["notes-end-editings"]
        XCTAssertTrue(notesEndEditings.waitForExistence(timeout: 5))
        XCTAssertEqual(notesEndEditings.label, "Notes end edits: 1")
        app.buttons["increment"].tap()
        XCTAssertEqual(app.staticTexts["count"].label, "Count: 2")

        app.buttons["open-details"].tap()
        XCTAssertTrue(app.staticTexts["details-title"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["details-title"].label, "Details for Ada")
        XCTAssertEqual(app.staticTexts["details-count"].label, "Count: 2")
        let people = app.collectionViews["people-list"]
        XCTAssertTrue(people.waitForExistence(timeout: 10))
        let peopleCount = app.staticTexts["people-count"]
        people.swipeDown()
        XCTAssertTrue(waitForLabel(peopleCount, "People: 40; events: 1"), "FlatList pull-to-refresh did not invoke onRefresh")
        let peopleHeader = app.staticTexts["people-header"]
        XCTAssertTrue(peopleHeader.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(peopleHeader.frame.minY, people.frame.minY + 8, "FlatList contentContainerStyle did not add top padding")
        let peopleLayouts = app.staticTexts["people-layout-status"]
        XCTAssertTrue(peopleLayouts.waitForExistence(timeout: 5))
        let initialRowLayouts = Int(peopleLayouts.label.split(separator: ":").last ?? "0") ?? 0
        XCTAssertGreaterThan(initialRowLayouts, 0)
        XCTAssertTrue(app.textFields["person-input-person-0"].waitForExistence(timeout: 5))
        let personInput = app.textFields["person-input-person-0"]
        personInput.tap()
        personInput.typeText("draft")
        app.buttons["shuffle-people"].tap()
        let firstPerson = app.staticTexts["person-label-person-0"]
        XCTAssertTrue(waitForLabel(firstPerson, "1: Person zero updated"))
        XCTAssertEqual(personInput.value as? String, "draft")
        for _ in 0..<30 where peopleCount.label == "People: 40; events: 2" {
            people.swipeUp()
        }
        XCTAssertTrue(
            waitForLabel(peopleCount, "People: 41; events: 3"),
            "FlatList did not report its data end; found \(peopleCount.label)"
        )
        XCTAssertTrue(
            waitForLayoutIncrease(peopleLayouts, from: initialRowLayouts),
            "FlatList did not report a row layout after recycling; found \(peopleLayouts.label)"
        )
        people.swipeDown()
        let recycledPersonInput = app.textFields["person-input-person-0"]
        XCTAssertTrue(recycledPersonInput.waitForExistence(timeout: 5))
        XCTAssertEqual(recycledPersonInput.value as? String, "draft")
        app.buttons["clear-people"].tap()
        XCTAssertTrue(app.staticTexts["people-empty"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["people-footer"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(peopleCount, "People: 0; events: 4"))
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.exists, "UIKit did not provide a back button")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "Ada")
        XCTAssertEqual(app.staticTexts["count"].label, "Count: 2")

        app.buttons["open-details"].tap()
        XCTAssertTrue(app.staticTexts["details-title"].waitForExistence(timeout: 10))
        app.buttons["details-back"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "Ada")

        app.buttons["open-details"].tap()
        XCTAssertTrue(app.staticTexts["details-title"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 5))
        for y in [0.2, 0.5, 0.8] where !field.exists {
            let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: y))
            let farEdge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: y))
            edge.press(forDuration: 0.1, thenDragTo: farEdge)
            if field.waitForExistence(timeout: 3) { break }
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5), "edge-swipe did not navigate back")
        XCTAssertEqual(field.value as? String, "Ada")

        app.buttons["open-details"].tap()
        XCTAssertTrue(app.staticTexts["details-title"].waitForExistence(timeout: 10))
        app.buttons["open-summary"].tap()
        XCTAssertTrue(app.staticTexts["summary-title"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["summary-title"].label, "Summary for Ada")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 10), "replace left details on the stack")
        XCTAssertEqual(field.value as? String, "Ada")
        XCTAssertEqual(app.staticTexts["count"].label, "Count: 2")
    }
}
