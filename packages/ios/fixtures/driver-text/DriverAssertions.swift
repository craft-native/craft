import XCTest

extension DriverTests {
    func testUnresponsiveSwitchesFailAcceptance() {
        bundledJourney = true
        app.launch()
        XCTAssertTrue(identified("frozen-button").waitForExistence(timeout: 10))
        XCTAssertEqual(identified("frozen-button").elementType, .button)
        for id in ["frozen-native", "frozen-solid", "frozen-button"] {
            XCTAssertTrue(identified(id).waitForExistence(timeout: 10))
            XCTAssertEqual(identified(id).value as? String, "0")
            let options = XCTExpectedFailure.Options()
            options.isStrict = true
            options.issueMatcher = { $0.compactDescription.contains("tapid \(id) flips the switch") }
            XCTExpectFailure("An unresponsive toggle must fail tap acceptance", options: options) {
                run("tapid \(id)")
            }
        }
        app.terminate()
    }

    func testOneTapWaitsForFocusAcrossNativeAndWebFields() {
        bundledJourney = true
        app.launchArguments = ["browser-focus"]
        defer { app.terminate(); app.launchArguments = [] }
        app.launch()
        XCTAssertTrue(identified("delayed-field").waitForExistence(timeout: 10))
        run("tap Delayed field")
        run("type Grüße")
        XCTAssertEqual(identified("delayed-field").value as? String, "Grüße")
        run("tap Card number")
        run("type 4242424242424242")
        run("expect Entered: 4242424242424242 | 10")
        let options = XCTExpectedFailure.Options()
        options.isStrict = true
        options.issueMatcher = { $0.compactDescription.contains("type into Refused field takes keyboard focus") }
        XCTExpectFailure("A refused focus must fail after one gesture", options: options) {
            run("tap Refused field")
            run("type must not reach another field")
        }
        XCTAssertFalse(hasKeyboardFocus(identified("refused-field")))
        XCTAssertEqual(identified("refused-field").value as? String ?? "", "")
        app.terminate()
    }
}
