import XCTest

final class NativeRenderUITests: XCTestCase {
    func testTypingAndButtonUpdatesDoNotDropTheKeyboard() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertFalse(app.webViews.firstMatch.exists, "native mode created a WebView")
        let field = app.textFields["name-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("Ada")
        XCTAssertEqual(app.staticTexts["name"].label, "Hello Ada")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))

        for count in 1...3 {
            app.buttons["increment"].tap()
            XCTAssertEqual(app.staticTexts["count"].label, "Count: \(count)")
            XCTAssertTrue(
                app.keyboards.firstMatch.waitForExistence(timeout: 5),
                "state update \(count) dismissed the keyboard"
            )
            field.typeText("x")
            XCTAssertEqual(field.value as? String, "Ada" + String(repeating: "x", count: count))
            XCTAssertEqual(app.staticTexts["name"].label, "Hello Ada" + String(repeating: "x", count: count))
        }
    }
}
