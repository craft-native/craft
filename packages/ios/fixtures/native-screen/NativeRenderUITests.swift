import XCTest

final class NativeRenderUITests: XCTestCase {
    /// How long to wait for the system document or photo picker to present.
    ///
    /// How quickly that sheet appears is not ours to control, and on a loaded
    /// runner it has taken longer than the waits here allowed: fifteen seconds
    /// was not enough for the Cancel button in
    /// testDocumentPickerUserCancelSettlesOnceAndCanRetryFileAndVideo, on a
    /// commit with nothing wrong with it.
    ///
    /// One constant because the same condition had two different patiences —
    /// some sites allowed fifteen seconds and others ten, for the identical
    /// "has the picker shown its Cancel button yet". Nothing asserted changes:
    /// the sheet must still present, and must still be cancellable.
    private let systemSheetTimeout: TimeInterval = 30

    func testNativeChartTouchSelectionAndVerticalScroll() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["open-chart"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["open-chart"].tap()
        let chart = app.descendants(matching: .any).matching(identifier: "native-chart").firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 10), app.debugDescription)
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.7)).tap()
        XCTAssertTrue(NSPredicate(format: "value CONTAINS %@", "57 ms").evaluate(with: chart), app.debugDescription)
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.7)).press(forDuration: 0.1, thenDragTo: chart.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.7)))
        XCTAssertTrue(NSPredicate(format: "value CONTAINS %@", "61 ms").evaluate(with: chart), app.debugDescription)
        let readout = XCTAttachment(screenshot: app.screenshot())
        readout.name = "Native chart selection"; readout.lifetime = .keepAlways; add(readout)
        let before = chart.frame.minY
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).press(forDuration: 0.05, thenDragTo: chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        XCTAssertLessThan(chart.frame.minY, before - 40, "The chart captured a vertical page scroll")
        XCTAssertEqual(app.webViews.count, 0)
    }

    func testFloatingActionOutsideNestedEmptyWrappersRemainsAccessible() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["open-overflow"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["open-picker"].exists, app.debugDescription)
        app.buttons["open-overflow"].tap()
        XCTAssertTrue(app.staticTexts["overflow-result"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["clip-overflow"].exists, app.debugDescription)
        XCTAssertTrue(app.otherElements["overflow-decoration"].exists, app.debugDescription)
        let action = app.buttons["overflow-action"]
        XCTAssertTrue(action.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(action.label, "Resume saved workout")
        tapWhenHittable(action, "floating recovery action")
        waitForLabel(app.staticTexts["overflow-result"], "Resumed once")
        app.buttons["clip-overflow"].tap()
        XCTAssertTrue(action.waitForNonExistence(timeout: 5), "Clipped overflow must not become a VoiceOver stop")
        app.buttons["reveal-overflow"].tap()
        XCTAssertTrue(action.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.webViews.count, 0)
    }

    func testSegmentOptionsExposeStableIdentityAndSelectedState() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.buttons["open-overflow"].tap()
        let all = app.buttons["library-source-all"]
        let own = app.buttons["library-source-own"]
        let coach = app.buttons["library-source-coach"]
        XCTAssertTrue(own.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(all.isSelected)
        XCTAssertFalse(own.isSelected)
        XCTAssertFalse(coach.isEnabled)
        tapWhenHittable(own, "own source segment")
        waitForLabel(app.staticTexts["source-result"], "Source own")
        XCTAssertTrue(own.isSelected)
        XCTAssertFalse(all.isSelected)
        XCTAssertEqual(app.webViews.count, 0)
    }

    private func waitForBackground(_ app: XCUIApplication) {
        // Read the state itself. An expectation on a predicate over the app
        // describes the app each time the predicate is false, and describing
        // an app that iOS suspends meanwhile blocked for nine seconds on CI:
        // the state was read once in the ten seconds allowed, 1.5 s after
        // Home, and never again (run 43236065505). The limit is unchanged.
        //
        // That state comes from testmanagerd, and it can lag. In run
        // 43820852205, runningboardd failed to suspend the photos picker and
        // then went silent for 20 s. SpringBoard had the app in the
        // background 1.5 s after Home, but testmanagerd still said
        // foreground (#555). SpringBoard's home screen is read through its
        // own accessibility tree, so 3 s of it also counts. One sighting is
        // not enough: it appears during Home's animation, before the app is
        // in the background.
        let homeScreen = XCUIApplication(bundleIdentifier: "com.apple.springboard").otherElements["Home screen icons"]
        let deadline = Date().addingTimeInterval(10)
        var homeScreenSince: Date?
        while Date() < deadline {
            if app.state == .runningBackground || app.state == .runningBackgroundSuspended { return }
            if !homeScreen.exists {
                homeScreenSince = nil
            } else if let since = homeScreenSince {
                if Date().timeIntervalSince(since) >= 3 { return }
            } else {
                homeScreenSince = Date()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Home must background the app, including when iOS has already suspended it; its state is \(app.state.rawValue), and the home screen is \(homeScreen.exists ? "showing" : "not showing")")
    }

    private func backgroundAfterObservingPicker(_ app: XCUIApplication) {
        // The fixture arms API_CANCEL or NAVIGATE_REPLACE for APP_STATE.
        // The caller must first establish that the real system picker exists.
        // Do not race that observation against an autonomous JS timer.
        XCUIDevice.shared.press(.home)
        waitForBackground(app)
        app.activate()
    }

    func testLibraryPickerUserCancelAndRetryPhotoAndVideo() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.buttons["open-picker"].tap()
        for (index, mode) in ["photo", "library-video", "photo"].enumerated() {
            app.buttons["picker-\(mode)"].tap()
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: systemSheetTimeout), app.debugDescription)
            XCTAssertEqual(app.webViews.count, 0)
            tapWhenHittable(cancel, "picker Cancel")
            waitForLabel(app.staticTexts["picker-status"], "Answer \(index + 1): null")
        }
    }

    func testLibraryPickerAbortAndScreenDisposalReleaseBusySlot() {
        continueAfterFailure = false
        let app = XCUIApplication()
        for mode in ["photo-abort", "library-video-replace"] {
            app.launch()
            app.buttons["open-picker"].tap()
            let session = app.staticTexts["picker-session"].label
            app.buttons["picker-\(mode)"].tap()
            let cancel = app.buttons["Cancel"].firstMatch
            // The system picker runs out of process: on a loaded CI simulator
            // it has taken about five seconds to show its Cancel button, and
            // this wait failed on main CI when it allowed only 5 s. Every
            // picker appearance in this file now shares systemSheetTimeout.
            XCTAssertTrue(cancel.waitForExistence(timeout: systemSheetTimeout), app.debugDescription)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "System media picker before \(mode)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            backgroundAfterObservingPicker(app)
            XCTAssertTrue(cancel.waitForNonExistence(timeout: 15))
            waitForLabel(app.staticTexts["picker-status"], mode == "photo-abort" ? "Aborted; answers 0" : "Picker ready")
            if mode == "library-video-replace" { XCTAssertNotEqual(app.staticTexts["picker-session"].label, session) }
            app.buttons["picker-photo"].tap()
            XCTAssertTrue(cancel.waitForExistence(timeout: systemSheetTimeout))
            tapWhenHittable(cancel, "picker Cancel")
            waitForLabel(app.staticTexts["picker-status"], "Answer 1: null")
            app.terminate()
        }
    }

    func testDocumentPickerUserCancelSettlesOnceAndCanRetryFileAndVideo() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.buttons["open-picker"].tap()
        let status = app.staticTexts["picker-status"]
        waitForLabel(status, "Picker ready")
        for (index, mode) in ["file", "video", "file"].enumerated() {
            app.buttons["picker-\(mode)"].tap()
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: systemSheetTimeout), app.debugDescription)
            XCTAssertEqual(app.webViews.count, 0)
            tapWhenHittable(cancel, "picker Cancel")
            waitForLabel(status, "Answer \(index + 1): \(mode == "video" ? "null" : "[]")")
        }
    }

    func testDocumentPickerRequestCancellationDismissesAndReleasesBusySlot() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.buttons["open-picker"].tap()
        app.buttons["picker-abort"].tap()
        // During cold Files startup, Cancel can still be a placeholder rather
        // than an accessible button. Programmatic cancellation needs the real
        // presented controller, not that unrelated action's loading state.
        let picker = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        XCTAssertTrue(picker.waitForExistence(timeout: systemSheetTimeout), app.debugDescription)
        backgroundAfterObservingPicker(app)
        XCTAssertTrue(picker.waitForNonExistence(timeout: 15))
        waitForLabel(app.staticTexts["picker-status"], "Aborted; answers 0")
        app.buttons["picker-file"].tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: systemSheetTimeout))
        tapWhenHittable(cancel, "picker Cancel")
        waitForLabel(app.staticTexts["picker-status"], "Answer 1: []")
    }

    func testDocumentPickerScreenReplacementDismissesAndNewScreenCanRetry() {
        continueAfterFailure = false
        for round in 1...3 {
            let app = XCUIApplication()
            app.launch()
            app.buttons["open-picker"].tap()
            let session = app.staticTexts["picker-session"].label
            app.buttons["picker-replace"].tap()
            let picker = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
            XCTAssertTrue(picker.waitForExistence(timeout: systemSheetTimeout), app.debugDescription)
            backgroundAfterObservingPicker(app)
            XCTAssertTrue(picker.waitForNonExistence(timeout: 15))
            waitForLabel(app.staticTexts["picker-status"], "Picker ready")
            XCTAssertNotEqual(app.staticTexts["picker-session"].label, session)
            let retry = app.buttons["picker-file"]
            XCTAssertTrue(retry.isHittable, app.debugDescription)
            retry.tap()
            waitForLabel(app.staticTexts["picker-status"], "Opening file")
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: systemSheetTimeout), app.debugDescription)
            tapWhenHittable(cancel, "picker Cancel")
            waitForLabel(app.staticTexts["picker-status"], "Answer 1: []")
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Document picker retry after native screen disposal, round \(round)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()
        }
    }

    func testCheckpointInterruptedBeforeAtomicReplacementPreservesPreviousAndCanRetry() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--checkpoint-interruption"]
        app.launch()
        let status = app.staticTexts["interrupted-checkpoint-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        let session = app.staticTexts["interrupted-checkpoint-session"].label
        app.buttons["checkpoint-seed"].tap()
        waitForLabel(status, "Recovered complete checkpoint 1")
        app.buttons["checkpoint-interrupt"].tap()
        // This label is emitted only from the intercepted real rename, after
        // validating the full staged payload and unchanged destination bytes.
        waitForLabel(status, "Staged 2; disk still 1; replacement blocked")
        let staged = XCTAttachment(screenshot: app.screenshot())
        staged.name = "Foundation replacement blocked with complete staged checkpoint and intact previous value"
        staged.lifetime = .keepAlways
        add(staged)
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        app.launch()
        waitForLabel(status, "Recovered complete checkpoint 1")
        XCTAssertNotEqual(app.staticTexts["interrupted-checkpoint-session"].label, session)
        app.buttons["checkpoint-retry"].tap()
        waitForLabel(status, "Recovered complete checkpoint 3")
        app.terminate()
        app.launch()
        waitForLabel(status, "Recovered complete checkpoint 3")
        let recovered = XCTAttachment(screenshot: app.screenshot())
        recovered.name = "Checkpoint retry recovered in another process after interrupted atomic replacement"
        recovered.lifetime = .keepAlways
        add(recovered)
    }

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
        waitForBackground(app)
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
    // Ten seconds, the same patience `waitForLabel` already allows. Both ask
    // the same question -- has the interface settled after input -- and three
    // seconds was the odd one out. A loaded CI simulator spent longer than that
    // delivering a switch's new value, which failed
    // testUnmodifiedUIKitSwitchRespondsToTheSameTap on an otherwise sound
    // commit. What is asserted is unchanged: the value must still become
    // exactly `expected`, and a control that never responds still fails.
    /// Tap a system sheet's button once it can actually take the tap.
    ///
    /// `waitForExistence` only says the element is in the hierarchy. A picker
    /// still animating in is there and not yet hittable, and a tap synthesized
    /// at that moment lands on nothing: XCTest reports the event as sent, the
    /// sheet stays up, and the page never answers. The deadline is unchanged -
    /// this waits for the condition that was always meant, inside the patience
    /// the sheet already had.
    private func tapWhenHittable(_ element: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(systemSheetTimeout)
        while !element.isHittable && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(element.isHittable, "\(what) never became hittable", file: file, line: line)
        element.tap()
    }

    private func waitForValue(_ element: XCUIElement, _ expected: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        // Predicate expectations poll coarsely enough to miss a value already
        // committed inside the 1.5-second consent deadline. Observe the actual
        // value with that same deadline and exactly the original input gesture.
        let deadline = Date().addingTimeInterval(timeout)
        var matched = false
        repeat {
            matched = element.value as? String == expected
            if matched { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline
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
        // A drag across most of the page, not swipeLeft/Right: on a loaded
        // runner a synthesized swipe arrived too short or slow to page, and
        // the pager rightly settled back (#559). Past half its width it pages
        // whatever the speed.
        func page(_ toward: CGFloat) {
            let from = pager.coordinate(withNormalizedOffset: CGVector(dx: 0.5 + 0.35 * toward, dy: 0.5))
            from.press(forDuration: 0.05, thenDragTo: pager.coordinate(withNormalizedOffset: CGVector(dx: 0.5 - 0.35 * toward, dy: 0.5)), withVelocity: .fast, thenHoldForDuration: 0)
        }
        page(1)
        waitForLabel(status, "Page 2 of 3")
        XCTAssertTrue(app.staticTexts["pager-page-1"].isHittable)
        XCTAssertFalse(app.staticTexts["pager-page-0"].exists)
        app.buttons["pager-last"].tap()
        waitForLabel(status, "Page 3 of 3")
        XCTAssertTrue(app.staticTexts["pager-page-2"].isHittable)
        XCTAssertFalse(app.staticTexts["pager-page-1"].exists)
        page(-1)
        waitForLabel(status, "Page 2 of 3")
        XCTAssertTrue(app.staticTexts["pager-page-1"].isHittable)
        XCTAssertFalse(app.staticTexts["pager-page-2"].exists)
    }

    /// stx's overlays suite, launched sideways: a dialog that closes on a tap
    /// outside it, and a second one opened from inside it. Each page sheet
    /// spanned the whole width, so the tap beside it landed on the sheet and
    /// neither closed (#561). Each one is as wide as it is upright, with room
    /// beside it, and a tap there closes the top one.
    func testSidewaysNestedSheetsLeaveRoomToTapOutsideThem() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("Compact height is a phone held sideways") }
        // The fixture's menu runs past a sideways screen, so it is opened
        // upright; both sheets are first presented with the phone sideways.
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        let solid = app.buttons["open-solid"]
        XCTAssertTrue(solid.waitForExistence(timeout: 15), app.debugDescription)
        solid.tap()
        let open = app.buttons["open-sheets"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), app.debugDescription)
        open.tap()
        let status = app.staticTexts["sheet-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), app.debugDescription)
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock {
            XCUIDevice.shared.orientation = .portrait
            let upright = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.height > app.frame.width }, object: nil)
            _ = XCTWaiter.wait(for: [upright], timeout: 10)
        }
        let sideways = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
        wait(for: [sideways], timeout: 10)
        app.buttons["open-outer"].tap()
        waitForLabel(status, "Outer open")
        let outer = app.staticTexts["outer-content"]
        XCTAssertTrue(outer.waitForExistence(timeout: 10), app.debugDescription)
        // Upright width centred in a sideways screen starts a quarter of the
        // way in; spanning the screen it starts at the safe-area margin.
        let window = app.frame
        XCTAssertGreaterThan(outer.frame.minX, window.width / 4, "the outer sheet leaves room beside it: \(outer.frame) in \(window)\n\(app.debugDescription)")
        app.buttons["open-inner"].tap()
        waitForLabel(status, "Both open")
        let inner = app.staticTexts["inner-content"]
        XCTAssertTrue(inner.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertGreaterThan(inner.frame.minX, window.width / 4, "the inner sheet leaves room beside it: \(inner.frame) in \(window)\n\(app.debugDescription)")
        let beside = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        beside.tap()
        waitForLabel(status, "Outer open")
        XCTAssertTrue(outer.waitForExistence(timeout: 5), "only the inner dialog closed")
        beside.tap()
        waitForLabel(status, "Closed")
    }

    /// stx's forms suite, sideways with the keyboard up: each 55-point drag of
    /// the root ScrollView carried the password field about 280 points and
    /// back, never stopping in the strip above the keyboard (#562). Nothing
    /// in the host scrolls it: an XCUITest drag released after a hold still
    /// ends at the speed it was dragged (a synthesized hold sends no touches,
    /// so UIKit's velocity is the last movement's), and the scroll view
    /// coasts on it, upright as well. Dragged slowly, it stops where the
    /// finger did: the host leaves the page where it was dragged to, with
    /// the keyboard up and the phone on its side. (The drags start beside
    /// the fields: a slow press on the focused one can become a caret drag.)
    func testASlowDragAboveTheKeyboardLeavesTheFormWhereTheFingerStopped() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        let open = app.buttons["open-form"]
        XCTAssertTrue(open.waitForExistence(timeout: 15), app.debugDescription)
        open.tap()
        let email = app.textFields["form-email"]
        XCTAssertTrue(email.waitForExistence(timeout: 10), app.debugDescription)
        XCUIDevice.shared.orientation = .landscapeLeft
        // Upright again before the next test launches: one that starts while
        // the simulator is still turning finds its controls off the screen.
        addTeardownBlock {
            XCUIDevice.shared.orientation = .portrait
            let upright = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.height > app.frame.width }, object: nil)
            _ = XCTWaiter.wait(for: [upright], timeout: 10)
        }
        let sideways = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
        wait(for: [sideways], timeout: 10)
        email.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10), "the keyboard came up")
        Thread.sleep(forTimeInterval: 1)
        let password = app.secureTextFields["form-password"]
        XCTAssertTrue(password.exists, app.debugDescription)

        // stx's GateSettings.reach: a drag inside the strip between the top of
        // the screen and the keyboard, under half of it, held 0.3 s.
        let frame = app.frame
        let top = frame.minY + min(110, frame.height * 0.25)
        let bottom = keyboard.frame.minY
        let span = max(48, bottom - top)
        let upper = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: top + span * 0.2))
        let lower = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: top + span * 0.6))
        let distance = span * 0.4
        var trail = ["keyboard \(keyboard.frame), app \(frame), drag \(distance) pt, password at \(password.frame.minY)"]
        // Up, then back down. A third slow drag from the same point did not
        // scroll at all under XCUITest, though its pan was recognized; that
        // is recorded on #562 rather than asserted here.
        for step in 0..<2 {
            let up = step % 2 == 0
            let before = password.frame.minY
            let (from, to) = up ? (lower, upper) : (upper, lower)
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: XCUIGestureVelocity(40), thenHoldForDuration: 0.3)
            Thread.sleep(forTimeInterval: 1)
            let after = password.frame.minY
            trail.append("drag \(up ? "up" : "down"): password \(before) → \(after)")
            let moved = up ? before - after : after - before
            XCTAssertEqual(moved, distance, accuracy: 24, "a \(distance)-point slow drag moved the form \(moved) points: \(trail.joined(separator: "; "))")
        }
        let record = XCTAttachment(string: trail.joined(separator: "\n"))
        record.name = "Slow drags above the keyboard"
        record.lifetime = .keepAlways
        add(record)
    }

    /// stx's forms suite, sideways: after the keyboard went away, the root
    /// ScrollView stopped about 32 points short of its last line, which sat
    /// below the scroll view's bottom edge however far it was dragged. The
    /// end of a form can be scrolled into view once the keyboard is gone.
    func testTheEndOfASidewaysFormCanBeReachedAfterTheKeyboardGoesAway() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        let open = app.buttons["open-form"]
        XCTAssertTrue(open.waitForExistence(timeout: 15), app.debugDescription)
        open.tap()
        let email = app.textFields["form-email"]
        XCTAssertTrue(email.waitForExistence(timeout: 10), app.debugDescription)
        XCUIDevice.shared.orientation = .landscapeLeft
        // Upright again before the next test launches: one that starts while
        // the simulator is still turning finds its controls off the screen.
        addTeardownBlock {
            XCUIDevice.shared.orientation = .portrait
            let upright = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.height > app.frame.width }, object: nil)
            _ = XCTWaiter.wait(for: [upright], timeout: 10)
        }
        let sideways = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
        wait(for: [sideways], timeout: 10)
        let scroll = app.scrollViews["form-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10), app.debugDescription)
        email.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard came up")
        email.typeText("ada@example.com")
        let end = app.staticTexts["form-end"]
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "End of the form: ada@example.com"), object: end)
        wait(for: [typed], timeout: 10)
        email.typeText("\n")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !app.keyboards.firstMatch.exists }, object: nil)
        wait(for: [gone], timeout: 10)
        // Then a menu and a segment, as stx's form is filled in: the last line
        // changes once more after the keyboard has gone.
        let sport = app.buttons["form-sport"]
        XCTAssertTrue(sport.waitForExistence(timeout: 10), app.debugDescription)
        sport.tap()
        let ride = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Ride", "form-sport")).firstMatch
        XCTAssertTrue(ride.waitForExistence(timeout: 10), app.debugDescription)
        ride.tap()
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "End of the form: ride"), object: end)], timeout: 10)
        let month = app.buttons["This month"]
        XCTAssertTrue(month.waitForExistence(timeout: 10), app.debugDescription)
        month.tap()
        // A fling past the end comes to rest at the scroll view's last offset.
        for _ in 0..<4 { scroll.swipeUp(velocity: .fast) }
        Thread.sleep(forTimeInterval: 2)
        let record = XCTAttachment(string: "scroll \(scroll.frame), end \(end.frame), app \(app.frame)")
        record.name = "The end of the form after the keyboard"
        record.lifetime = .keepAlways
        add(record)
        XCTAssertLessThanOrEqual(end.frame.maxY, scroll.frame.maxY + 0.5, "the last line is below the scroll view at its last offset: end \(end.frame), scroll \(scroll.frame)")
        XCTAssertTrue(end.isHittable, "the last line can be reached: end \(end.frame), scroll \(scroll.frame)")
    }

    /// #562, from stx's forms suite sideways: with a field focused and the
    /// keyboard up, each 55-point drag of the root ScrollView was reported to
    /// move the form about 280 points and back. A drag moves the content by
    /// about as far as the finger went, and it stays, whether it starts on
    /// the page or on the focused field. (XCUITest's default-speed drag
    /// flings about 270 points here even after a hold, keyboard or none, so
    /// these are slow.)
    func testADragOfASidewaysFormWithTheKeyboardUpMovesItAsFarAsTheFinger() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        let open = app.buttons["open-form"]
        XCTAssertTrue(open.waitForExistence(timeout: 15), app.debugDescription)
        open.tap()
        let email = app.textFields["form-email"]
        XCTAssertTrue(email.waitForExistence(timeout: 10), app.debugDescription)
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock {
            XCUIDevice.shared.orientation = .portrait
            let upright = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.height > app.frame.width }, object: nil)
            _ = XCTWaiter.wait(for: [upright], timeout: 10)
        }
        let sideways = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
        wait(for: [sideways], timeout: 10)
        let scroll = app.scrollViews["form-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10), app.debugDescription)
        email.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard came up")
        let password = app.secureTextFields["form-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10), app.debugDescription)
        Thread.sleep(forTimeInterval: 1)

        // Pressed, dragged, held so nothing coasts, as stx's suite does: the
        // first three from the page, the last three from the focused field.
        var moves: [String] = []
        for (step, dy) in [(1, -55.0), (2, 55.0), (3, -55.0), (4, 55.0), (5, -55.0), (6, 55.0)] as [(Int, CGFloat)] {
            let before = password.frame.minY
            let start = step <= 3
                ? scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                : email.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)), withVelocity: .slow, thenHoldForDuration: 0.3)
            Thread.sleep(forTimeInterval: 0.8)
            let after = password.frame.minY
            Thread.sleep(forTimeInterval: 1)
            let settled = password.frame.minY
            moves.append("drag \(step) \(Int(dy)): \(Int(before)) -> \(Int(after)) -> \(Int(settled))")
            // Toward the finger, by no more than it went (less at an end).
            XCTAssertEqual((after - before).sign, dy.sign, "drag \(step) moved the form the wrong way: \(moves)")
            XCTAssertLessThanOrEqual(abs(after - before), abs(dy) + 12, "drag \(step) moved the form further than the finger: \(moves)")
            XCTAssertEqual(settled, after, accuracy: 2, "drag \(step): the form moved again after the finger let go: \(moves)")
            XCTAssertEqual(email.value(forKey: "hasKeyboardFocus") as? Bool, true, "drag \(step) took the focus off the field: \(moves)")
        }
        let record = XCTAttachment(string: moves.joined(separator: "\n"))
        record.name = "Sideways drags with the keyboard up"
        record.lifetime = .keepAlways
        add(record)
    }

    /// #573: a drag that began on a field that was not focused did not
    /// scroll the form, and the field took the focus when the finger lifted.
    /// A drag from an unfocused field scrolls toward the finger, slow or
    /// quick, and the field that had the focus keeps it.
    func testADragFromAnUnfocusedFieldScrollsAndLeavesTheFocusWhereItWas() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        let open = app.buttons["open-form"]
        XCTAssertTrue(open.waitForExistence(timeout: 15), app.debugDescription)
        open.tap()
        let email = app.textFields["form-email"]
        XCTAssertTrue(email.waitForExistence(timeout: 10), app.debugDescription)
        let password = app.secureTextFields["form-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10), app.debugDescription)
        email.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard came up")
        Thread.sleep(forTimeInterval: 1)

        var moves: [String] = []
        // Slow, held so nothing coasts; then quick, which flings.
        let scroll = app.scrollViews["form-scroll"]
        for (step, dy, quick) in [(1, -55.0, false), (2, 55.0, false), (3, -55.0, true), (4, 55.0, true)] as [(Int, CGFloat, Bool)] {
            // An unfocused field wholly on screen, wherever the last fling left the form.
            let visible = scroll.frame
            let field = [password] + (0..<8).map { app.textFields["form-extra-\($0)"] }
            let from = try XCTUnwrap(field.first { $0.exists && visible.contains($0.frame) }, "no unfocused field on screen: \(moves)")
            let before = from.frame.minY
            let start = from.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            if quick {
                start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)), withVelocity: .default, thenHoldForDuration: 0.3)
                Thread.sleep(forTimeInterval: 2)
            } else {
                start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)), withVelocity: .slow, thenHoldForDuration: 0.3)
                Thread.sleep(forTimeInterval: 0.8)
            }
            let after = from.frame.minY
            let focused = [email, password].first { ($0.value(forKey: "hasKeyboardFocus") as? Bool) == true }?.identifier ?? "none"
            moves.append("drag \(step) \(Int(dy))\(quick ? " quick" : "") from \(from.identifier): \(Int(before)) -> \(Int(after)), focus \(focused)")
            XCTAssertGreaterThan((after - before) * (dy > 0 ? 1 : -1), 10, "drag \(step) did not scroll the form toward the finger: \(moves)")
            XCTAssertEqual(focused, "form-email", "drag \(step) moved the focus: \(moves)")
        }
        let record = XCTAttachment(string: moves.joined(separator: "\n"))
        record.name = "Drags from an unfocused field"
        record.lifetime = .keepAlways
        add(record)
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

    func testScrolledAgreementDeliversExactlyOneChangePerConsentTap() {
        for kind in ["native", "solid"] {
            let app = XCUIApplication()
            app.launch()
            let open = app.buttons["open-agreement-\(kind)"]
            XCTAssertTrue(open.waitForExistence(timeout: 15))
            open.tap()
            let scroll = app.scrollViews["agreement-scroll"]
            let health = app.descendants(matching: .any).matching(identifier: "agree-health").firstMatch
            let data = app.descendants(matching: .any).matching(identifier: "agree-data").firstMatch
            XCTAssertTrue(scroll.waitForExistence(timeout: 5))
            XCTAssertFalse(scroll.frame.contains(health.frame), "fixture must actually require scrolling")
            for _ in 0..<4 {
                if scroll.frame.contains(health.frame) && scroll.frame.contains(data.frame) { break }
                scroll.swipeUp()
            }
            XCTAssertTrue(scroll.frame.contains(health.frame))
            XCTAssertTrue(scroll.frame.contains(data.frame))
            XCTAssertTrue(health.isHittable && data.isHittable)
            XCTAssertEqual(health.value as? String, "0")
            XCTAssertEqual(data.value as? String, "0")
            XCTAssertFalse(app.buttons["agreement-continue"].isEnabled)
            health.tap() // Exactly one physical gesture; never retry a missing change.
            waitForValue(health, "1", timeout: 1.5)
            waitForLabel(app.staticTexts["agreement-events"], "Health: 1; Data: 0")
            XCTAssertEqual(data.value as? String, "0")
            XCTAssertFalse(app.buttons["agreement-continue"].isEnabled)
            data.tap()
            waitForValue(data, "1", timeout: 1.5)
            waitForLabel(app.staticTexts["agreement-events"], "Health: 1; Data: 1")
            XCTAssertTrue(app.buttons["agreement-continue"].isEnabled)
            // A viewport change must neither toggle again nor reset the echo.
            scroll.swipeDown()
            scroll.swipeUp()
            XCTAssertEqual(health.value as? String, "1")
            XCTAssertEqual(data.value as? String, "1")
            XCTAssertEqual(app.staticTexts["agreement-events"].label, "Health: 1; Data: 1")
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Scrolled agreement after single taps (\(kind))"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
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
