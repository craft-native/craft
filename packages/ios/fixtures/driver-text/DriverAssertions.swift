import XCTest

extension DriverTests {
    func testOptionalDismissalNeverTapsMatchingBodyControls() {
        bundledJourney = true
        app.launchArguments = ["dismiss-prompt"]
        defer { app.terminate(); app.launchArguments = [] }
        app.launch()
        XCTAssertTrue(identified("present-prompt").waitForExistence(timeout: 10))
        run("dismiss")
        XCTAssertEqual(identified("body-taps").label, "Body taps: 0")
        for _ in 0..<2 {
            run("tapid present-prompt")
            run("dismiss")
            let evidence = XCTAttachment(string: app.debugDescription)
            evidence.name = "modal-dismissal-tree"
            evidence.lifetime = .keepAlways
            add(evidence)
            print("MODAL_DISMISSAL_TREE \(app.debugDescription)")
            run("absent Save Password?")
            XCTAssertEqual(identified("body-taps").label, "Body taps: 0")
        }
    }

    private func retainFocusEvidence(_ name: String, immediateValue: String?) -> [[String: Any]] {
        let evidence = identified("focus-evidence").value as? String ?? "missing focus evidence"
        let receipt = "Immediate accessibility value: \(String(describing: immediateValue))\n\(evidence)"
        print("FOCUS_EVIDENCE \(name) \(receipt)")
        let attachment = XCTAttachment(string: receipt + "\n" + app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let data = evidence.data(using: .utf8),
              let events = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            XCTFail("Missing native focus event receipt")
            return []
        }
        return events
    }

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
        let immediateValue = identified("delayed-field").value as? String
        // typeText returning does not make the cross-process accessibility
        // value atomic: a cold run observed "Gr" while UIKit received "Grüße".
        // Observe completion without sending another gesture or text payload.
        run("valueid delayed-field Grüße")
        let events = retainFocusEvidence("native-focus-after-type", immediateValue: immediateValue)
        let edits = events.filter { $0["event"] as? String == "editingChanged" }
        XCTAssertEqual(edits.last?["text"] as? String, "Grüße")
        XCTAssertTrue(edits.allSatisfy { $0["focused"] as? Bool == true })
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

        // A field can hold focus and receive the keyboard events while its
        // delegate rejects the text. The bounded value check must still fail.
        app.launchArguments = ["browser-focus", "discard-input"]
        app.launch()
        XCTAssertTrue(identified("delayed-field").waitForExistence(timeout: 10))
        run("tap Delayed field")
        run("type Grüße")
        XCTAssertTrue(hasKeyboardFocus(identified("delayed-field")))
        let rejectedValue = identified("delayed-field").value as? String
        let rejected = XCTExpectedFailure.Options()
        rejected.isStrict = true
        rejected.issueMatcher = { $0.compactDescription.contains("valueid delayed-field Grüße") }
        XCTExpectFailure("Focused input rejection must fail value acceptance", options: rejected) {
            run("valueid delayed-field Grüße")
        }
        let rejectedEvents = retainFocusEvidence("native-rejected-input", immediateValue: rejectedValue)
        let rejectedEdits = rejectedEvents.filter { $0["event"] as? String == "rejectedChange" }
        XCTAssertFalse(rejectedEdits.isEmpty)
        XCTAssertTrue(rejectedEdits.allSatisfy { $0["focused"] as? Bool == true })
        XCTAssertFalse(rejectedEvents.contains { $0["event"] as? String == "editingChanged" })
        XCTAssertEqual(identified("delayed-field").value as? String ?? "", "")
    }
}
