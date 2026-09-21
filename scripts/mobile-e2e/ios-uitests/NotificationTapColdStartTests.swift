import XCTest

/// Taps a pushed notification that launches the probe app, then has a second
/// push arrive while it is open, and reports what its page was handed each
/// time (#255, #256).
///
/// A person's sequence, end to end: the app asks for permission and is
/// allowed, the app is killed, a real push arrives through `simctl push`, and
/// the notification is tapped. With the app now in front, another push arrives.
/// `simctl` runs on the host, so the test prints `CRAFT-E2E-PUSH-READY cold`
/// once the app is gone and `CRAFT-E2E-PUSH-READY foreground` once the page
/// is listening, and the harness sends each push when it reads the line.
///
/// As with the deep-link test, no assertions about the answer live here. The
/// page's report is printed and `scripts/mobile-e2e/protocol.ts` judges it.
final class NotificationTapColdStartTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment
    private var bundleId: String { environment["PROBE_BUNDLE_ID"] ?? "" }
    private var permissionLink: String { environment["PROBE_NOTIFY_LINK"] ?? "" }
    private var pushBody: String { environment["PROBE_PUSH_BODY"] ?? "" }

    override func setUp() {
        // Each step stands on the one before it; carrying on past a failure
        // would only bury it under the ones it causes.
        continueAfterFailure = false
    }

    func testPushesReachThePage() throws {
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

        // The prompt, or an answer without one. iOS can remember a grant for
        // a bundle across its reinstall, so the previous leg's Allow may still
        // stand and no prompt appears; the page's answer is what counts.
        let allow = springboard.alerts.buttons["Allow"]
        let permission = app.staticTexts
            .containing(NSPredicate(format: "label BEGINSWITH 'CRAFT-E2E-NOTIFY-PERMISSION '"))
            .firstMatch
        let deadline = Date().addingTimeInterval(90)
        while !permission.exists && Date() < deadline {
            if allow.exists { allow.tap() } else { _ = permission.waitForExistence(timeout: 1) }
        }
        XCTAssertTrue(permission.exists, "the page never said how the notification permission request ended")
        XCTAssertEqual(permission.label, "CRAFT-E2E-NOTIFY-PERMISSION granted")

        // Killed, so the tap below is what starts it. A running app would be
        // handed the tap by a Coordinator that already exists, which is the
        // case that always worked.
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "the app did not stop, so this would not be a cold start")
        tapColdPush(springboard, app: app)

        let report = app.staticTexts
            .containing(NSPredicate(format: "label BEGINSWITH 'CRAFT-E2E-NOTIFICATION '"))
            .firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 120), "the page never reported what it was handed")
        print("CRAFT-E2E-NOTIFICATION-RESULT \(report.label)")

        // The app is in front and the page has subscribed, since it reported
        // above. A push now is one it can only hear about through onReceive.
        // The page's receipt report is there from the moment it subscribed,
        // and rewritten once an arrival has settled. Whatever it says after a
        // generous wait is printed, including nothing arriving at all, so the
        // harness can say which it was rather than only that time ran out.
        print("CRAFT-E2E-PUSH-READY foreground")
        let receipts = app.staticTexts
            .containing(NSPredicate(format: "label BEGINSWITH 'CRAFT-E2E-NOTIFICATION-RECEIVED '"))
            .firstMatch
        XCTAssertTrue(receipts.waitForExistence(timeout: 30), "the page never reported what onReceive handed it")
        let arrived = app.staticTexts
            .containing(NSPredicate(format: "label BEGINSWITH 'CRAFT-E2E-NOTIFICATION-RECEIVED ' AND label CONTAINS %@", "\"received\":[{"))
            .firstMatch
        _ = arrived.waitForExistence(timeout: 30)
        print("CRAFT-E2E-NOTIFICATION-RECEIVED-RESULT \(receipts.label)")
    }

    /// Asks the host for the cold push and taps its banner.
    ///
    /// The banner, not Notification Center: on iOS 26 Notification Center is
    /// pulled down as the Lock Screen, and a tap there only offers Open. The
    /// banner is found by this run's text, so a notification left over from
    /// an earlier run cannot be the one tapped.
    ///
    /// iOS takes a banner down after a few seconds, and a tap first waits for
    /// SpringBoard to go idle and then looks the banner up again, about a
    /// second on CI. On a machine at a load average of 16 that was once long
    /// enough for the banner to go, and the test fails saying the tap could
    /// not find it. There is no retrying around that: a tap that misses ends
    /// the test method, even inside XCTExpectFailure.
    private func tapColdPush(_ springboard: XCUIApplication, app: XCUIApplication) {
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", pushBody))
            .firstMatch
        print("CRAFT-E2E-PUSH-READY cold")
        XCTAssertTrue(banner.waitForExistence(timeout: 120), "no banner for the push ever appeared")
        banner.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60), "tapping the banner did not start the app")
    }
}
