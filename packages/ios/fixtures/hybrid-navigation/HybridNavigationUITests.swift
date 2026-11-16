import XCTest

final class HybridNavigationUITests: XCTestCase {
    private enum PageColor { case home, second, blank }

    private func visiblePage(_ screenshot: XCUIScreenshot) -> PageColor {
        guard let image = screenshot.image.cgImage else { return .blank }
        let x = max(0, min(image.width - 1, Int(CGFloat(image.width) * 0.5)))
        let y = max(0, min(image.height - 1, Int(CGFloat(image.height) * 0.5)))
        guard let sample = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return .blank }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        if pixel[0] > 180 && pixel[1] < 140 && pixel[2] < 140 { return .home }
        if pixel[2] > 150 && pixel[0] < 120 && pixel[1] < 170 { return .second }
        return .blank
    }

    func testShellWebPushKeepsTheOutgoingPageVisible() {
        let app = XCUIApplication()
        app.launch()
        let open = app.buttons["Open second"]
        // Cold WebKit accessibility initialization on a hosted simulator can
        // lag the painted page. Match the unit fixture's initial readiness
        // budget; the transition and destination deadlines below stay strict.
        XCTAssertTrue(open.waitForExistence(timeout: 120))
        // The button in the accessibility tree does not mean the page has
        // been painted: on a runner 209 s into testing, the tree came first
        // and the one frame sampled was blank (#550). Wait for the home page's
        // colour before the tap, bounded like the button. This is the case's
        // precondition; the checks after the tap stay strict.
        var screenshot = XCUIScreen.main.screenshot()
        let painted = Date().addingTimeInterval(30)
        while visiblePage(screenshot) != .home && Date() < painted {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            screenshot = XCUIScreen.main.screenshot()
        }
        if visiblePage(screenshot) != .home {
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "Home page not painted before the push"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(visiblePage(screenshot), .home)

        open.tap()
        // XCTest can finish its tap after the router has already painted the
        // incoming page. Either page is valid; a black slot is never valid.
        // Check every sampled frame, rather than passing after one red frame
        // or calling a completed blue transition a blank outgoing page.
        let deadline = Date().addingTimeInterval(1)
        repeat {
            XCTAssertNotEqual(visiblePage(XCUIScreen.main.screenshot()), .blank,
                              "the web page went blank during the hybrid push")
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        print("Hybrid navigation accessibility tree: \(app.debugDescription)")
        XCTAssertTrue(app.buttons["Back home"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Hybrid second"].waitForExistence(timeout: 10))
    }
}
