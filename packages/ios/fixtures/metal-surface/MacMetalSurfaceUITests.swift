import AppKit
import CoreImage
import ImageIO
import XCTest

final class MacMetalSurfaceUITests: XCTestCase {
    /// What the status element actually reads, for a failure message.
    ///
    /// The iOS half of this fixture gained this for #452, whose single
    /// retained attempt carried no observed label: establishing what the
    /// label said took a 136MB artifact and a frame-by-frame read of the
    /// screen recording, and the answer was that it had read the wanted
    /// string since 1.2 seconds before the wait began. This half had the same
    /// blindness for the same reason and now reports the same way.
    ///
    /// Both attributes, because a macOS static text may carry its string in
    /// `value` rather than `label`, and a message that printed only one of
    /// them could say "" about an element that was reading correctly.
    ///
    /// Read after the deadline has passed, so it describes the app when the
    /// failure is reported rather than implying it is what the wait saw.
    private func observedStatus(_ app: XCUIApplication) -> String {
        let status = app.staticTexts["metal-status"]
        guard status.exists else { return "no \"metal-status\" element was present when this was reported" }
        return "the status element read label \"\(status.label)\" value \"\(String(describing: status.value))\" when this was reported"
    }

    /// The status element, matched only when it already reads `text`.
    ///
    /// Identity and reading come from the same remote snapshot. The block
    /// predicates this replaces re-queried `status.value` *and* `status.label`
    /// on every evaluation — two fresh queries onto the app's main run loop
    /// per poll — which is the operation #452 showed can stall and lose a
    /// valid observation. A format predicate is evaluated against the
    /// snapshot instead, so one poll is one query.
    private func statusReading(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(identifier: "metal-status")
            .matching(NSPredicate(format: "label == %@ OR value == %@", text, text))
            .firstMatch
    }

    /// Wait on a condition that is not a snapshot attribute, with a message.
    ///
    /// `waitForExpectations(timeout:)` takes no message, so a timeout reported
    /// only the predicate's own description — the blindness this issue is
    /// about. The expectation is constructed directly rather than through
    /// `expectation(for:evaluatedWith:)` so that it is not also registered
    /// with the test case, which must not be waited on twice.
    private func waitFor(_ description: String, in app: XCUIApplication, timeout: TimeInterval = 10,
                         file: StaticString = #filePath, line: UInt = #line, until condition: @escaping () -> Bool) {
        let wanted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        if XCTWaiter().wait(for: [wanted], timeout: timeout) != .completed {
            XCTFail("\(description) within \(Int(timeout)) seconds; \(observedStatus(app))", file: file, line: line)
        }
    }

    func testDisplayedNativeFramesResizeResumeAndDispose() throws {
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        let status = app.staticTexts["metal-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10),
                      "The status element must appear within ten seconds; \(observedStatus(app))")
        XCTAssertTrue(statusReading("Verified frame 60", in: app).waitForExistence(timeout: 10),
                      "The native surface must acknowledge exactly frame 60 within ten seconds; \(observedStatus(app))")
        XCTAssertEqual(app.webViews.count, 0)
        let canvas = app.images["metal-canvas"]
        XCTAssertTrue(canvas.exists, "The native canvas must exist; \(observedStatus(app))")
        XCTAssertEqual(canvas.frame.width, 256, accuracy: 0.1)
        try compareDisplayedPixels(canvas, name: "macOS Metal initial frame")
        app.buttons["metal-resize"].click()
        waitFor("The resize must reach 160x120", in: app) {
            abs(canvas.frame.width - 160) < 0.1 && abs(canvas.frame.height - 120) < 0.1
        }
        try compareDisplayedPixels(canvas, name: "macOS Metal resized frame")
        let before = String(describing: status.value)
        app.buttons["metal-hide"].click()
        waitFor("Hiding must background the app", in: app) { app.state == .runningBackground }
        app.activate()
        waitFor("Resuming must advance the status past \"\(before)\"", in: app) {
            String(describing: status.value) != before
        }
        try compareDisplayedPixels(canvas, name: "macOS Metal resumed frame")
        app.buttons["metal-close"].click()
        XCTAssertTrue(statusReading("Disposed native surface", in: app).waitForExistence(timeout: 10),
                      "Closing must dispose the native surface within ten seconds; \(observedStatus(app))")
    }

    private func compareDisplayedPixels(_ canvas: XCUIElement, name: String) throws {
        // Capture only the owned native view, not the rest of the desktop.
        let screenshot = canvas.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let image = try XCTUnwrap(CGImageSourceCreateWithData(screenshot.pngRepresentation as CFData, nil))
        let pixels = try XCTUnwrap(CGImageSourceCreateImageAtIndex(image, 0, nil))
        XCTAssertGreaterThan(pixels.width, 0)
        XCTAssertGreaterThan(pixels.height, 0)
        let native = CIImage(cgImage: pixels)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = CIContext()
        let expected = [[224, 32, 64], [32, 192, 96], [32, 64, 224], [208, 160, 32]]
        for (index, color) in expected.enumerated() {
            let x = CGFloat(pixels.width) * (index % 2 == 0 ? 0.25 : 0.75)
            let top = CGFloat(pixels.height) * (index < 2 ? 0.25 : 0.75)
            var bytes: [UInt8] = [0, 0, 0, 0]
            context.render(native, toBitmap: &bytes, rowBytes: 4,
                           bounds: CGRect(x: floor(x), y: CGFloat(pixels.height) - floor(top) - 1, width: 1, height: 1),
                           format: .RGBA8, colorSpace: space)
            for channel in 0..<3 {
                XCTAssertLessThanOrEqual(abs(Int(bytes[channel]) - color[channel]), 3,
                                         "Displayed quadrant \(index), channel \(channel): \(bytes), expected \(color)")
            }
            XCTAssertEqual(bytes[3], 255)
        }
    }
}
