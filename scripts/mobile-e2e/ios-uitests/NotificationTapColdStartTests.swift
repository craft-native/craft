import XCTest

/// Taps a pushed notification that launches the probe app, has a second push
/// arrive while it is open, then taps a local notification the page scheduled
/// with data, and reports what its page was handed each time (#255, #256,
/// #258).
///
/// A person's sequence, end to end: the app asks for permission and is
/// allowed, the app is killed, a real push arrives through `simctl push`, and
/// the notification is tapped. With the app now in front, another push arrives.
/// `simctl` runs on the host, so the test prints `CRAFT-E2E-PUSH-READY cold`
/// once the app is gone and `CRAFT-E2E-PUSH-READY foreground` once the page
/// is listening, and the harness sends each push when it reads the line.
/// Last, a link has the page schedule a notification of its own, the app is
/// killed before it fires, and its banner is tapped.
///
/// As with the deep-link test, no assertions about the answer live here. The
/// page's report is printed and `scripts/mobile-e2e/protocol.ts` judges it.
final class NotificationTapColdStartTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment
    private var bundleId: String { environment["PROBE_BUNDLE_ID"] ?? "" }
    private var permissionLink: String { environment["PROBE_NOTIFY_LINK"] ?? "" }
    private var pushBody: String { environment["PROBE_PUSH_BODY"] ?? "" }
    private var localLink: String { environment["PROBE_LOCAL_LINK"] ?? "" }
    private var localBody: String { environment["PROBE_LOCAL_BODY"] ?? "" }

    override func setUp() {
        // Each step stands on the one before it; carrying on past a failure
        // would only bury it under the ones it causes.
        continueAfterFailure = false
    }

    func testNotificationsReachThePage() throws {
        XCTAssertFalse(bundleId.isEmpty, "PROBE_BUNDLE_ID is not set")
        XCTAssertFalse(permissionLink.isEmpty, "PROBE_NOTIFY_LINK is not set")
        XCTAssertFalse(pushBody.isEmpty, "PROBE_PUSH_BODY is not set")
        XCTAssertFalse(localLink.isEmpty, "PROBE_LOCAL_LINK is not set")
        XCTAssertFalse(localBody.isEmpty, "PROBE_LOCAL_BODY is not set")

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
        print("CRAFT-E2E-PUSH-READY cold")
        tapBanner(springboard, app: app, containing: pushBody)

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

        // #258: a notification the page scheduled itself, with data. The
        // local link carries a bounded scheduling window. The page reports
        // its earliest delivery deadline so slow UI calls cannot silently
        // turn this into a foreground-delivery test (#307).
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "the app did not stop before the local link")
        XCUIDevice.shared.system.open(URL(string: localLink)!)
        if open.waitForExistence(timeout: 5) { open.tap() }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60), "the local link did not start the app")
        let scheduled = app.staticTexts
            .containing(NSPredicate(format: "label BEGINSWITH 'CRAFT-E2E-LOCAL-SCHEDULED '"))
            .firstMatch
        XCTAssertTrue(scheduled.waitForExistence(timeout: 60), "the page never said whether it scheduled the notification")
        let schedulingReport = scheduled.label.split(separator: " ")
        guard schedulingReport.count == 3, schedulingReport[1] == "ok",
              let fireAtMs = Double(schedulingReport[2]), fireAtMs.isFinite, fireAtMs > 0 else {
            XCTFail("invalid local scheduling report: \(scheduled.label)")
            return
        }
        let fireAt = Date(timeIntervalSince1970: fireAtMs / 1000)
        XCTAssertLessThanOrEqual(fireAt.timeIntervalSinceNow, 180, "local scheduling window is unbounded")
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "the app did not stop, so the local tap would not be a cold start")
        let remaining = fireAt.timeIntervalSinceNow
        print("CRAFT-E2E-LOCAL-TIMING deadlineMs=\(fireAtMs) remainingAfterStopSeconds=\(remaining)")
        XCTAssertGreaterThan(remaining, 0, "local notification deadline elapsed before the app stopped; cold-start precondition was not met")
        tapBanner(springboard, app: app, containing: localBody, timeout: remaining + 30)

        let local = app.staticTexts
            .containing(NSPredicate(format: "label BEGINSWITH 'CRAFT-E2E-NOTIFICATION '"))
            .firstMatch
        XCTAssertTrue(local.waitForExistence(timeout: 120), "the page never reported what the local notification's tap handed it")
        print("CRAFT-E2E-LOCAL-RESULT \(local.label)")
    }

    /// Taps the banner of a notification that has arrived or is about to.
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
    private func tapBanner(_ springboard: XCUIApplication, app: XCUIApplication, containing text: String, timeout: TimeInterval = 120) {
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: timeout), "no banner for \(text) ever appeared")
        banner.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60), "tapping the banner did not start the app")
    }
}
