import CoreImage
import XCTest

final class MetalSurfaceUITests: XCTestCase {
    /// What the status label actually reads, for a failure message.
    ///
    /// Read after the deadline has passed, so it describes the app when the
    /// failure is reported rather than when the expectation gave up — and it
    /// says which, because on an app that has gone idle those are the same
    /// reading and on a busy one they are not.
    ///
    /// Worth the line because #452's single attempt carried no observed
    /// label: the debug attachment holds the query chain and nothing else, so
    /// establishing what the label said took the 136MB artifact and a
    /// frame-by-frame read of the screen recording. It had read the wanted
    /// string since 1.2 seconds before the wait began.
    private func observedStatus(_ app: XCUIApplication) -> String {
        let status = app.staticTexts["metal-status"]
        guard status.exists else { return "no \"metal-status\" element was present when this was reported" }
        return "the status label read \"\(status.label)\" when this was reported"
    }

    /// The status element, matched only when its label satisfies `predicate`.
    ///
    /// Same single-snapshot rule as `verifiedFrame`: identity and reading come
    /// from one remote query. A block predicate reading `status.label` runs
    /// locally and queries the app again on every evaluation, which is the
    /// operation #452 showed can stall and lose a valid observation.
    private func statusMatching(_ predicate: NSPredicate, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(identifier: "metal-status").matching(predicate).firstMatch
    }

    /// Wait on a condition that is not a snapshot attribute, with a message.
    ///
    /// `waitForExpectations(timeout:)` takes no message, so a timeout reported
    /// only the predicate's own description — the blindness this issue is
    /// about, which the frame acknowledgements were given a cure for while
    /// these waits kept it. The expectation is built directly rather than
    /// through `expectation(for:evaluatedWith:)`, which would also register it
    /// with the test case and must not then be waited on twice.
    private func waitFor(_ description: String, in app: XCUIApplication, timeout: TimeInterval = 10,
                         file: StaticString = #filePath, line: UInt = #line, until condition: @escaping () -> Bool) {
        let wanted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        if XCTWaiter().wait(for: [wanted], timeout: timeout) != .completed {
            XCTFail("\(description) within \(Int(timeout)) seconds; \(observedStatus(app))", file: file, line: line)
        }
    }

    private func verifiedFrame(_ frame: UInt32, in app: XCUIApplication) -> XCUIElement {
        // Match identity and acknowledgement in the same remote snapshot. In
        // #452 the existence query already returned frame 60; a second query
        // stalled on the app's main run loop and lost that valid observation.
        app.staticTexts.matching(identifier: "metal-status")
            .matching(NSPredicate(format: "label == %@", "Verified frame \(frame)"))
            .firstMatch
    }

    func testPenultimateFrameCannotSatisfyFinalAcknowledgement() {
        let app = XCUIApplication()
        app.launchArguments = ["--craft-metal-hold-penultimate"]
        app.launch()
        XCTAssertTrue(verifiedFrame(59, in: app).waitForExistence(timeout: 10),
                      "The held fixture must acknowledge frame 59 within ten seconds; \(observedStatus(app))")
        XCTAssertFalse(verifiedFrame(60, in: app).waitForExistence(timeout: 1),
                       "An existing status element at frame 59 must not acknowledge frame 60; \(observedStatus(app))")
        // The existing resize action submits and verifies the next real frame.
        app.buttons["metal-resize"].tap()
        XCTAssertTrue(verifiedFrame(60, in: app).waitForExistence(timeout: 10),
                      "The resize must submit frame 60 within ten seconds; \(observedStatus(app))")
        XCTAssertFalse(verifiedFrame(59, in: app).exists,
                       "Frame 59 must not still be acknowledged after the resize; \(observedStatus(app))")
    }

    func testDisplayedPixelsResizeAndBackgroundResume() throws {
        let app = XCUIApplication()
        app.launch()
        let status = app.staticTexts["metal-status"]
        let acknowledged = NSPredicate(format: "label BEGINSWITH %@", "Verified frame ")
        XCTAssertTrue(verifiedFrame(60, in: app).waitForExistence(timeout: 10),
                      "The native surface must acknowledge exactly frame 60 within ten seconds; \(observedStatus(app))")
        XCTAssertEqual(app.webViews.count, 0)
        let canvas = app.otherElements["metal-canvas"]
        XCTAssertTrue(canvas.exists, "The native canvas must exist; \(observedStatus(app))")
        try compareScreenPixels(canvas, app: app, name: "Native Metal initial frame")
        app.buttons["metal-resize"].tap()
        // The canvas width is not a snapshot attribute a format predicate can
        // read, so this one stays a block — it does not touch the status
        // element, which is what must not be re-queried.
        waitFor("The resize must reach 160 points wide", in: app) { abs(canvas.frame.width - 160) < 0.1 }
        XCTAssertTrue(statusMatching(acknowledged, in: app).exists,
                      "The resize must keep a frame acknowledged; \(observedStatus(app))")
        try compareScreenPixels(canvas, app: app, name: "Native Metal resized frame")
        let before = status.label
        XCUIDevice.shared.press(.home)
        app.activate()
        // One snapshot decides both halves: still acknowledging, and a
        // different frame from the one before backgrounding.
        let advanced = NSPredicate(format: "label BEGINSWITH %@ AND label != %@", "Verified frame ", before)
        XCTAssertTrue(statusMatching(advanced, in: app).waitForExistence(timeout: 10),
                      "Resuming must acknowledge a frame after \"\(before)\" within ten seconds; \(observedStatus(app))")
        try compareScreenPixels(canvas, app: app, name: "Native Metal resumed frame")
    }

    private func compareScreenPixels(_ canvas: XCUIElement, app: XCUIApplication, name: String) throws {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        let native = CIImage(cgImage: image)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = CIContext()
        let expected = [[224, 32, 64], [32, 192, 96], [32, 64, 224], [208, 160, 32]]
        for (index, color) in expected.enumerated() {
            let x = (canvas.frame.minX + canvas.frame.width * (index % 2 == 0 ? 0.25 : 0.75)) * scale
            let y = (canvas.frame.minY + canvas.frame.height * (index < 2 ? 0.25 : 0.75)) * scale
            var bytes: [UInt8] = [0, 0, 0, 0]
            context.render(native, toBitmap: &bytes, rowBytes: 4,
                           bounds: CGRect(x: floor(x), y: CGFloat(image.height) - floor(y) - 1, width: 1, height: 1),
                           format: .RGBA8, colorSpace: space)
            for channel in 0..<3 {
                XCTAssertLessThanOrEqual(abs(Int(bytes[channel]) - color[channel]), 3,
                                         "Displayed quadrant \(index), channel \(channel): \(bytes), expected \(color)")
            }
            XCTAssertEqual(bytes[3], 255)
        }
    }
}
