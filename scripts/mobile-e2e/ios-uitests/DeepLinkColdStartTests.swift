import XCTest

/// Cold-starts the probe app through a deep link and reports what its page saw.
///
/// An XCUITest rather than `simctl openurl`, for two reasons. iOS asks
/// "Open in …?" before handing a custom scheme to an app, and simctl has no
/// way to answer; a UI test can tap the button. And an app SpringBoard
/// launches has no console the harness can read, while a UI test can read the
/// page's own text.
///
/// No assertions about the answer live here. The test prints the page's report
/// and `scripts/mobile-e2e/protocol.ts` judges it, where the rule is unit
/// tested and shared with the rest of the suite.
final class DeepLinkColdStartTests: XCTestCase {
    private let bundleId = ProcessInfo.processInfo.environment["PROBE_BUNDLE_ID"] ?? ""
    private let linkBase = ProcessInfo.processInfo.environment["PROBE_LINK"] ?? ""

    func testSubscribeOnly() throws {
        try coldStart(receive: "subscribe")
    }

    func testGetInitialURLAndSubscribe() throws {
        try coldStart(receive: "both")
    }

    private func coldStart(receive: String) throws {
        XCTAssertFalse(bundleId.isEmpty, "PROBE_BUNDLE_ID is not set")
        XCTAssertFalse(linkBase.isEmpty, "PROBE_LINK is not set")

        let app = XCUIApplication(bundleIdentifier: bundleId)
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "the app did not stop, so this would not be a cold start")

        let link = "\(linkBase)&receive=\(receive)"
        XCUIDevice.shared.system.open(URL(string: link)!)

        // Only the first open of a scheme asks, so the prompt is optional.
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 5) { open.tap() }

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60), "the link did not start the app")

        let report = app.staticTexts
            .containing(NSPredicate(format: "label BEGINSWITH 'CRAFT-E2E-DEEPLINK '"))
            .firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 120), "the page never reported what it received")
        print("CRAFT-E2E-DEEPLINK-RESULT \(receive) \(link) \(report.label)")
    }
}
