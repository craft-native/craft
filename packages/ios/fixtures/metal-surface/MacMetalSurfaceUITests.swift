import AppKit
import CoreImage
import ImageIO
import XCTest

final class MacMetalSurfaceUITests: XCTestCase {
    func testDisplayedNativeFramesResizeResumeAndDispose() throws {
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        let status = app.staticTexts["metal-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        expectation(for: NSPredicate { _, _ in status.value as? String == "Verified frame 60" || status.label == "Verified frame 60" }, evaluatedWith: status)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(app.webViews.count, 0)
        let canvas = app.images["metal-canvas"]
        XCTAssertTrue(canvas.exists)
        XCTAssertEqual(canvas.frame.width, 256, accuracy: 0.1)
        try compareDisplayedPixels(canvas, name: "macOS Metal initial frame")
        app.buttons["metal-resize"].click()
        expectation(for: NSPredicate { _, _ in abs(canvas.frame.width - 160) < 0.1 && abs(canvas.frame.height - 120) < 0.1 }, evaluatedWith: canvas)
        waitForExpectations(timeout: 10)
        try compareDisplayedPixels(canvas, name: "macOS Metal resized frame")
        let before = String(describing: status.value)
        app.buttons["metal-hide"].click()
        expectation(for: NSPredicate { _, _ in app.state == .runningBackground }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        app.activate()
        expectation(for: NSPredicate { _, _ in String(describing: status.value) != before }, evaluatedWith: status)
        waitForExpectations(timeout: 10)
        try compareDisplayedPixels(canvas, name: "macOS Metal resumed frame")
        app.buttons["metal-close"].click()
        expectation(for: NSPredicate { _, _ in status.value as? String == "Disposed native surface" || status.label == "Disposed native surface" }, evaluatedWith: status)
        waitForExpectations(timeout: 10)
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
