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
        let verified = NSPredicate { _, _ in status.label.hasPrefix("Verified frame ") }
        XCTAssertTrue(verifiedFrame(60, in: app).waitForExistence(timeout: 10),
                      "The native surface must acknowledge exactly frame 60 within ten seconds; \(observedStatus(app))")
        XCTAssertEqual(app.webViews.count, 0)
        let canvas = app.otherElements["metal-canvas"]
        XCTAssertTrue(canvas.exists)
        try compareScreenPixels(canvas, app: app, name: "Native Metal initial frame")
        app.buttons["metal-resize"].tap()
        expectation(for: NSPredicate { _, _ in abs(canvas.frame.width - 160) < 0.1 }, evaluatedWith: canvas)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(verified.evaluate(with: status), status.label)
        try compareScreenPixels(canvas, app: app, name: "Native Metal resized frame")
        let before = status.label
        XCUIDevice.shared.press(.home)
        app.activate()
        expectation(for: NSPredicate { _, _ in status.label.hasPrefix("Verified frame ") && status.label != before }, evaluatedWith: status)
        waitForExpectations(timeout: 10)
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
