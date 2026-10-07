import XCTest

final class NativeRenderUITests: XCTestCase {
    private func keyboardIsVisible(_ app: XCUIApplication) -> Bool {
        app.keyboards.firstMatch.waitForExistence(timeout: 5)
    }

    func testTypingAndButtonUpdatesDoNotDropTheKeyboard() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertFalse(app.webViews.firstMatch.exists, "native mode created a WebView")
        let field = app.textFields["name-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("Ada")
        XCTAssertEqual(app.staticTexts["name"].label, "Hello Ada")
        XCTAssertTrue(keyboardIsVisible(app))

        for count in 1...3 {
            app.buttons["increment"].tap()
            XCTAssertEqual(app.staticTexts["count"].label, "Count: \(count)")
            XCTAssertTrue(
                keyboardIsVisible(app),
                "state update \(count) dismissed the keyboard"
            )
            field.typeText("x")
            XCTAssertEqual(field.value as? String, "Ada" + String(repeating: "x", count: count))
            XCTAssertEqual(app.staticTexts["name"].label, "Hello Ada" + String(repeating: "x", count: count))
        }
    }
}
