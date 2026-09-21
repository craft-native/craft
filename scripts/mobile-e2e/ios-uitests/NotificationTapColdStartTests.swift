import XCTest

/// Taps a pushed notification that launches the probe app, and reports what
/// its page was handed (#255).
///
/// A person's sequence, end to end: the app asks for permission and is
/// allowed, the app is killed, a real push arrives through `simctl push`, and
/// the banner is tapped. `simctl` runs on the host, so the test prints
/// `CRAFT-E2E-PUSH-READY` once the app is gone and the harness sends the push
/// when it reads that line.
///
/// As with the deep-link test, no assertions about the answer live here. The
/// page's report is printed and `scripts/mobile-e2e/protocol.ts` judges it.
final class NotificationTapColdStartTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment
    private var bundleId: String { environment["PROBE_BUNDLE_ID"] ?? "" }
    private var permissionLink: String { environment["PROBE_NOTIFY_LINK"] ?? "" }
    private var pushBody: String { environment["PROBE_PUSH_BODY"] ?? "" }

    func testTapOnAPushLaunchesTheApp() throws {
        XCTAssertFalse(bundleId.isEmpty, "PROBE_BUNDLE_ID is not set")
        XCTAssertFalse(permissionLink.isEmpty, "PROBE_NOTIFY_LINK is not set")
        XCTAssertFalse(pushBody.isEmpty, "PROBE_PUSH_BODY is not set")

        let app = XCUIApplication(bundleIdentifier: bundleId)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        // Permission, answered the way a person answers it. Without it iOS
        // accepts the push and shows nothing, so there is no banner to tap.
        app.terminate()
        XCUIDevice.shared.system.open(URL(string: permissionLink)!)
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 5) { open.tap() }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60), "the permission link did not start the app")

        let allow = springboard.alerts.buttons["Allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 60), "the page never asked for notification permission")
        allow.tap()
        let permission = app.staticTexts
            .containing(NSPredicate(format: "label BEGINSWITH 'CRAFT-E2E-NOTIFY-PERMISSION '"))
            .firstMatch
        XCTAssertTrue(permission.waitForExistence(timeout: 30), "the page never said how the permission request ended")
        XCTAssertEqual(permission.label, "CRAFT-E2E-NOTIFY-PERMISSION granted")

        // Killed, so the tap below is what starts it. A running app would be
        // handed the tap by a Coordinator that already exists, which is the
        // case that always worked.
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "the app did not stop, so this would not be a cold start")
        print("CRAFT-E2E-PUSH-READY")

        // The banner, found by this run's body so a notification left over
        // from an earlier run cannot be the one tapped.
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", pushBody))
            .firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 120), "no banner for the push ever appeared")
        banner.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60), "tapping the banner did not start the app")

        let report = app.staticTexts
            .containing(NSPredicate(format: "label BEGINSWITH 'CRAFT-E2E-NOTIFICATION '"))
            .firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 120), "the page never reported what it was handed")
        print("CRAFT-E2E-NOTIFICATION-RESULT \(report.label)")
    }
}
