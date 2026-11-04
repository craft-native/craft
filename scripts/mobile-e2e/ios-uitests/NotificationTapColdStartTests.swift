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
@MainActor
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

    /// Resolve the short-lived button before synthesizing input. The resulting
    /// coordinate belongs to SpringBoard, not to the alert: if the alert goes
    /// away during input dispatch there is no stale Allow element to resolve.
    /// The page's reply below, never the tap itself, proves permission succeeded.
    private func permissionCoordinate(_ allow: XCUIElement, in springboard: XCUIApplication,
                                      timeout: TimeInterval) -> XCUICoordinate? {
        // Querying isHittable itself records an XCTest failure while SpringBoard
        // is animating an otherwise valid Allow button (invalid activation point).
        // Resolve an enabled snapshot instead, then validate its visible geometry.
        guard allow.waitForExistence(timeout: timeout),
              let snapshot = try? allow.snapshot(), snapshot.isEnabled else { return nil }
        let frame = snapshot.frame
        guard Self.permissionFrameIsVisible(frame, screen: springboard.frame) else { return nil }
        let origin = springboard.coordinate(withNormalizedOffset: .zero)
        let point = origin.screenPoint
        return origin.withOffset(CGVector(dx: frame.midX - point.x, dy: frame.midY - point.y))
    }

    private static func permissionFrameIsVisible(_ frame: CGRect, screen: CGRect) -> Bool {
        !frame.isEmpty && !frame.isNull && !frame.isInfinite
            && frame.midX.isFinite && frame.midY.isFinite
            && !screen.isEmpty && screen.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    func testPermissionCoordinatesRejectMissingAndOffscreenFrames() {
        let screen = CGRect(x: 0, y: 0, width: 402, height: 874)
        XCTAssertTrue(Self.permissionFrameIsVisible(CGRect(x: 210, y: 420, width: 100, height: 44), screen: screen))
        for frame in [CGRect.zero, CGRect.null, CGRect.infinite,
                      CGRect(x: 500, y: 420, width: 100, height: 44),
                      CGRect(x: 10, y: -100, width: 100, height: 44)] {
            XCTAssertFalse(Self.permissionFrameIsVisible(frame, screen: screen))
        }
    }

    /// The same deadline covers both waits; every unresolved iteration yields,
    /// including one that dispatched input. A vanished prompt is not a grant.
    private func waitForPermission<Target>(timeout: TimeInterval, now: () -> TimeInterval,
                                          hasReply: () -> Bool, resolveAllow: (TimeInterval) -> Target?,
                                          tap: (Target) -> Void, waitForReply: (TimeInterval) -> Bool) -> Bool {
        let deadline = now() + timeout
        while !hasReply() {
            let remaining = deadline - now()
            guard remaining > 0 else { return false }
            if let target = resolveAllow(min(1, remaining)), !hasReply(), now() < deadline {
                tap(target)
            }
            let replyBudget = min(1, deadline - now())
            if replyBudget > 0, waitForReply(replyBudget) { return true }
        }
        return true
    }

    func testRememberedPermissionNeedsNoPromptOrTap() {
        let result: Bool = waitForPermission(timeout: 90, now: { 0 }, hasReply: { true },
            resolveAllow: { _ -> Int? in XCTFail("already answered"); return nil },
            tap: { _ in XCTFail("already answered") },
            waitForReply: { _ in XCTFail("already answered"); return false })
        XCTAssertTrue(result)
    }

    func testPermissionAnswerArrivingDuringResolutionAvoidsAnotherTap() {
        var answered = false
        XCTAssertTrue(waitForPermission(timeout: 90, now: { 0 }, hasReply: { answered },
            resolveAllow: { _ -> Int? in answered = true; return 1 },
            tap: { _ in XCTFail("the request has already completed") },
            waitForReply: { _ in answered }))
    }

    func testDisappearingPermissionPromptStillWaitsForThePage() {
        for resolved in [false, true] {
            var clock: TimeInterval = 0
            var taps = 0
            var yields = 0
            var answered = false
            XCTAssertTrue(waitForPermission(timeout: 90, now: { clock }, hasReply: { answered },
                resolveAllow: { _ -> Int? in clock += 0.1; return resolved ? 1 : nil },
                tap: { _ in taps += 1 },
                waitForReply: { budget in
                    XCTAssertGreaterThan(budget, 0)
                    clock += budget
                    yields += 1
                    answered = true
                    return answered
                }))
            XCTAssertEqual(taps, resolved ? 1 : 0)
            XCTAssertEqual(yields, 1, "the tap branch must yield too")
        }
    }

    func testUnansweredPermissionKeepsTheOriginalDeadlineAndYieldsAfterEveryTap() {
        for resolved in [false, true] {
            var clock: TimeInterval = 0
            var attempts = 0
            var taps = 0
            var yields = 0
            XCTAssertFalse(waitForPermission(timeout: 90, now: { clock }, hasReply: { false },
                resolveAllow: { budget -> Int? in
                    XCTAssertLessThanOrEqual(budget, 1)
                    clock += 0.25
                    attempts += 1
                    return resolved ? attempts : nil
                },
                tap: { _ in taps += 1 },
                waitForReply: { budget in
                    XCTAssertGreaterThan(budget, 0)
                    XCTAssertLessThanOrEqual(budget, 1)
                    clock += budget
                    yields += 1
                    return false
                }))
            XCTAssertEqual(clock, 90)
            XCTAssertEqual(yields, attempts)
            XCTAssertEqual(taps, resolved ? attempts : 0)
        }
    }

    func testMissingPermissionSnapshotIsRecoverable() {
        let missing = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .buttons["craft-permission-missing-\(UUID().uuidString)"]
        XCTAssertNil(try? missing.snapshot(), "disappearance must be a thrown resolution error, not a test failure")
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
        let answered = waitForPermission(
            timeout: 90,
            now: { ProcessInfo.processInfo.systemUptime },
            hasReply: { permission.exists },
            resolveAllow: { timeout in self.permissionCoordinate(allow, in: springboard, timeout: timeout) },
            tap: { $0.tap() },
            waitForReply: { permission.waitForExistence(timeout: $0) }
        )
        XCTAssertTrue(answered, "the page never said how the notification permission request ended")
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

    /// Preserve the original single gesture and 10 + 50 second foreground
    /// budget. Observations must never turn a stopped app into a passing launch.
    private func observeNotificationTap(tap: () -> Void, state: () -> XCUIApplication.State,
                                        waitForForeground: (TimeInterval) -> Bool, activate: () -> Void,
                                        observe: (String, XCUIApplication.State) -> Void) -> Bool {
        observe("before-tap", state())
        tap()
        observe("after-tap", state())
        if waitForForeground(10) { observe("foreground", state()); return true }
        let afterInitialWait = state()
        observe("after-initial-wait", afterInitialWait)
        if afterInitialWait == .runningBackground { activate(); observe("after-activate", state()) }
        let foreground = waitForForeground(50)
        observe("after-final-wait", state())
        return foreground
    }

    func testNotificationTapNeverLaunchesAStoppedAppOrRetriesItsGesture() {
        var taps = 0
        var waits: [TimeInterval] = []
        var phases: [String] = []
        XCTAssertFalse(observeNotificationTap(tap: { taps += 1 }, state: { .notRunning },
            waitForForeground: { waits.append($0); return false },
            activate: { XCTFail("a stopped app must never be activated as a fallback") },
            observe: { phase, state in phases.append(phase); XCTAssertEqual(state, .notRunning) }))
        XCTAssertEqual(taps, 1)
        XCTAssertEqual(waits, [10, 50])
        XCTAssertEqual(phases, ["before-tap", "after-tap", "after-initial-wait", "after-final-wait"])
    }

    func testNotificationTapRecordsForegroundAndBackgroundTransitionsWithoutExtendingTheBudget() {
        for immediate in [false, true] {
            var taps = 0
            var activations = 0
            var waits: [TimeInterval] = []
            var state: XCUIApplication.State = .notRunning
            XCTAssertTrue(observeNotificationTap(tap: { taps += 1; state = .runningBackground }, state: { state },
                waitForForeground: { seconds in
                    waits.append(seconds)
                    if immediate || activations == 1 { state = .runningForeground; return true }
                    return false
                }, activate: { activations += 1 }, observe: { _, _ in }))
            XCTAssertEqual(taps, 1)
            XCTAssertEqual(activations, immediate ? 0 : 1)
            XCTAssertEqual(waits, immediate ? [10] : [10, 50])
        }
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
        let began = ProcessInfo.processInfo.systemUptime
        var evidence: [String: Any] = ["notificationText": text, "gestureCount": 1]
        // Retain the actual resolved target before input. The original #450
        // artifact named NotificationShortLookView but retained no target frame.
        if let snapshot = try? banner.snapshot() {
            let frame = snapshot.frame
            var target: [String: Any] = ["identifier": snapshot.identifier, "label": snapshot.label,
                "elementType": snapshot.elementType.rawValue, "enabled": snapshot.isEnabled]
            let coordinates = [frame.origin.x, frame.origin.y, frame.width, frame.height]
            if coordinates.allSatisfy({ $0.isFinite }) { target["frame"] = coordinates }
            else { target["invalidFrame"] = true }
            evidence["target"] = target
        } else { evidence["snapshotUnavailable"] = true }
        if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]) {
            let target = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            target.name = "Notification banner resolved before tap"
            target.lifetime = .keepAlways
            add(target)
        }
        var observations: [[String: Any]] = []
        let foreground = observeNotificationTap(tap: { banner.tap() }, state: { app.state },
            waitForForeground: { app.wait(for: .runningForeground, timeout: $0) },
            activate: { app.activate() }, observe: { phase, state in
                observations.append(["phase": phase, "state": state.rawValue,
                    "milliseconds": (ProcessInfo.processInfo.systemUptime - began) * 1000])
            })
        evidence["observations"] = observations
        evidence["foreground"] = foreground
        if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "Notification banner target and application states"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("CRAFT-E2E-BANNER-OBSERVATION \(String(data: data, encoding: .utf8) ?? "")")
        }
        if !foreground {
            let screenshot = XCTAttachment(screenshot: springboard.screenshot())
            screenshot.name = "SpringBoard after the notification foreground deadline"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let hierarchy = XCTAttachment(string: springboard.debugDescription)
            hierarchy.name = "SpringBoard hierarchy after the notification foreground deadline"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(foreground, "tapping the banner did not start the app")
    }
}
