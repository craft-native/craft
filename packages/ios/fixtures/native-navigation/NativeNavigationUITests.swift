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
        let scroll = app.scrollViews["native-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["disabled-button"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["disabled-button"].isEnabled)
        let image = app.images["native-image"]
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        XCTAssertEqual(image.label, "Native pixel")
        image.tap()
        XCTAssertEqual(app.staticTexts["native-caption"].label, "Image taps: 1")
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

        let link = app.buttons["native-link"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        XCTAssertEqual(link.label, "Open native link")
        link.tap()
        XCTAssertTrue(app.staticTexts["link pressed"].waitForExistence(timeout: 5))

        let toggle = app.switches["native-switch"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap()
        XCTAssertTrue(app.staticTexts["switch on"].waitForExistence(timeout: 5))

        let slider = app.sliders["native-slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.adjust(toNormalizedSliderPosition: 0.8)
        XCTAssertTrue(app.staticTexts["slider moved"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["slider-value"].label, "0.8")

        XCTAssertTrue(app.activityIndicators["native-indicator"].waitForExistence(timeout: 5))

        let wrapped = app.otherElements["layout-wrap"]
        XCTAssertTrue(wrapped.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["layout measured"].waitForExistence(timeout: 5), "native onLayout did not report a frame")
        let bounded = app.staticTexts["layout-min"]
        XCTAssertTrue(bounded.exists)
        XCTAssertEqual(bounded.frame.width, 140, accuracy: 2, "maxWidth was not applied")
        let absolute = app.otherElements["layout-absolute"]
        XCTAssertTrue(absolute.exists)
        XCTAssertGreaterThanOrEqual(absolute.frame.minX, wrapped.frame.minX)
        XCTAssertGreaterThanOrEqual(absolute.frame.minY, wrapped.frame.minY)

        let field = app.textFields["name-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("Ada")
        XCTAssertEqual(app.staticTexts["greeting"].label, "Hello Ada")
        field.typeText("\n")
        XCTAssertEqual(app.staticTexts["name-submits"].label, "Submits: 1")
        app.buttons["increment"].tap()
        app.buttons["increment"].tap()
        XCTAssertEqual(app.staticTexts["count"].label, "Count: 2")

        app.buttons["open-details"].tap()
        XCTAssertTrue(app.staticTexts["details-title"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["details-title"].label, "Details for Ada")
        XCTAssertEqual(app.staticTexts["details-count"].label, "Count: 2")
        let people = app.collectionViews["people-list"]
        XCTAssertTrue(people.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["people-header"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["person-input-person-0"].waitForExistence(timeout: 5))
        app.buttons["shuffle-people"].tap()
        let firstPerson = app.staticTexts["person-label-person-0"]
        XCTAssertTrue(waitForLabel(firstPerson, "1: Person zero updated"))
        let peopleCount = app.staticTexts["people-count"]
        for _ in 0..<30 where peopleCount.label == "People: 40; events: 1" {
            people.swipeUp()
        }
        XCTAssertTrue(
            waitForLabel(peopleCount, "People: 41; events: 2"),
            "FlatList did not report its data end; found \(peopleCount.label)"
        )
        app.buttons["clear-people"].tap()
        XCTAssertTrue(app.staticTexts["people-empty"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["people-footer"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(peopleCount, "People: 0; events: 3"))
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
