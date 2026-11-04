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
            XCTAssertEqual(lastBooleanTap?["id"] as? String, id)
            XCTAssertEqual(lastBooleanTap?["gestures"] as? Int, 1)
            XCTAssertEqual(lastBooleanTap?["enabledBefore"] as? Bool, false)
            XCTAssertEqual(lastBooleanTap?["enabledAfter"] as? Bool, false)
            XCTAssertEqual(lastBooleanTap?["valueBefore"] as? String, "0")
            XCTAssertEqual(lastBooleanTap?["valueAfter"] as? String, "0")
            XCTAssertEqual(lastBooleanTap?["flipped"] as? Bool, false)
        }
        app.terminate()
        app.launchArguments = ["invalid-toggle-evidence"]
        defer { app.terminate(); app.launchArguments = [] }
        app.launch()
        for id in ["missing-value", "unknown-value"] {
            let target = identified(id)
            XCTAssertTrue(target.waitForExistence(timeout: 10))
            XCTAssertEqual(target.elementType, .button)
            XCTAssertTrue(target.isEnabled)
            XCTAssertEqual(target.value as? String, "0")
            let options = XCTExpectedFailure.Options()
            options.isStrict = true
            options.issueMatcher = { $0.compactDescription.contains("tapid \(id) flips the switch") }
            XCTExpectFailure("A delivered tap without a Boolean transition is not a verified flip", options: options) {
                run("tapid \(id)")
            }
            XCTAssertEqual(identified("\(id)-count").label, "Taps: 1")
            XCTAssertEqual(lastBooleanTap?["gestures"] as? Int, 1)
            XCTAssertEqual(lastBooleanTap?["enabledBefore"] as? Bool, true)
            XCTAssertEqual(lastBooleanTap?["enabledAfter"] as? Bool, true)
            XCTAssertEqual(lastBooleanTap?["valueBefore"] as? String, "0")
            let observed = target.value as? String
            if id == "missing-value" {
                // XCTest may normalize an absent UIKit accessibility value to "".
                XCTAssertTrue(observed == nil || observed == "")
            } else {
                XCTAssertEqual(observed, "unavailable")
            }
            XCTAssertEqual(lastBooleanTap?["valueAfter"] as? String, observed ?? "unknown")
            XCTAssertEqual(lastBooleanTap?["flipped"] as? Bool, false)
        }
        // A Boolean-valued button which really flips still passes after one tap.
        XCTAssertEqual(identified("valid-value").elementType, .button)
        run("tapid valid-value")
        XCTAssertEqual(identified("valid-value-count").label, "Taps: 1")
        XCTAssertEqual(lastBooleanTap?["flipped"] as? Bool, true)
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
