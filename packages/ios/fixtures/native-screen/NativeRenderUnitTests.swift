import Combine
import UIKit
import MapKit
import CoreLocation
import XCTest
@testable import NativeRender

private final class UnitLocationManager: CLLocationManager {
    var state: CLAuthorizationStatus = .notDetermined
    var whenInUseRequests = 0
    var alwaysRequests = 0
    var fixRequests = 0
    var onAuthorizationRequest: (() -> Void)?
    override var authorizationStatus: CLAuthorizationStatus { state }
    override func requestWhenInUseAuthorization() { whenInUseRequests += 1; onAuthorizationRequest?() }
    override func requestAlwaysAuthorization() { alwaysRequests += 1; onAuthorizationRequest?() }
    override func requestLocation() { fixRequests += 1 }
}

@MainActor
final class NativeRenderUnitTests: XCTestCase {
    func testPresenterRectRejectsBooleanCoordinatesAndNonFiniteNumbers() {
        XCTAssertNil(CraftPresenter.rect(["x": true, "y": 20, "width": 30, "height": 40]))
        XCTAssertNil(CraftPresenter.rect(["x": 10, "y": false, "width": 30, "height": 40]))
        XCTAssertNil(CraftPresenter.rect(["x": Double.nan, "y": 20, "width": 30, "height": 40]))
        XCTAssertEqual(CraftPresenter.rect(["x": 10, "y": 20, "width": 30, "height": 40]), CGRect(x: 10, y: 20, width: 30, height: 40))
        XCTAssertEqual(CraftPresenter.rect(["x": 10, "y": 20, "width": true, "height": false]), CGRect(x: 10, y: 20, width: 0, height: 0))
    }

    func testOneShotLocationWaitsForPermissionBeforeStartingItsFixAndTimeout() throws {
        var config = CraftConfig()
        config.enableGeolocation = true
        config.enableBackgroundLocation = true
        let manager = UnitLocationManager()
        let coordinator = CraftWebView.Coordinator(config: config, locationManager: manager)
        let previous = CraftSwiftShim.coordinator
        CraftSwiftShim.coordinator = coordinator
        defer { CraftSwiftShim.coordinator = previous }
        let permission = expectation(description: "foreground location permission requested")
        manager.onAuthorizationRequest = { permission.fulfill() }
        let completed = expectation(description: "authorized native fix delivered")
        var answer: Result<Any, CraftNativeActionError>?
        CraftWebServices.perform(action: "getCurrentPosition", body: ["timeout": 20]) { result in
            answer = result
            completed.fulfill()
        }
        wait(for: [permission], timeout: 2)
        XCTAssertEqual(manager.whenInUseRequests, 1)
        XCTAssertEqual(manager.alwaysRequests, 0, "One foreground fix does not ask for background access")
        XCTAssertEqual(manager.fixRequests, 0)
        coordinator.locationManager(manager, didFailWithError: NSError(domain: kCLErrorDomain, code: CLError.Code.denied.rawValue))
        let deciding = expectation(description: "person is still reading the permission sheet")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { deciding.fulfill() }
        wait(for: [deciding], timeout: 2)
        XCTAssertNil(answer, "The acquisition timeout excludes time spent deciding permission")
        manager.state = .authorizedWhenInUse
        coordinator.locationManagerDidChangeAuthorization(manager)
        XCTAssertEqual(manager.fixRequests, 1)
        coordinator.locationManagerDidChangeAuthorization(manager)
        XCTAssertEqual(manager.fixRequests, 1, "Repeated authorization notifications do not restart acquisition")
        coordinator.locationManager(manager, didUpdateLocations: [CLLocation(latitude: 34, longitude: -118)])
        wait(for: [completed], timeout: 2)
        guard case .success(let value)? = answer else { return XCTFail("Expected an authorized native fix") }
        XCTAssertEqual((value as? [String: Any])?["latitude"] as? Double, 34)
    }

    func testOneShotLocationRejectsDeniedPermissionWithoutRequestingAFix() {
        for status in [CLAuthorizationStatus.denied, .restricted] {
            var config = CraftConfig()
            config.enableGeolocation = true
            let manager = UnitLocationManager()
            manager.state = status
            let coordinator = CraftWebView.Coordinator(config: config, locationManager: manager)
            let previous = CraftSwiftShim.coordinator
            CraftSwiftShim.coordinator = coordinator
            let completed = expectation(description: "denied native request settled")
            CraftWebServices.perform(action: "getCurrentPosition", body: [:]) { result in
                guard case .failure(let error) = result else { completed.fulfill(); return XCTFail("Denied permission returned a fix") }
                XCTAssertEqual(error.code, "PERMISSION_DENIED")
                completed.fulfill()
            }
            wait(for: [completed], timeout: 2)
            XCTAssertEqual(manager.fixRequests, 0)
            XCTAssertEqual(manager.whenInUseRequests, 0)
            CraftSwiftShim.coordinator = previous
        }
    }

    func testOneShotLocationRejectsWhenPermissionPromptIsDeclined() {
        var config = CraftConfig()
        config.enableGeolocation = true
        let manager = UnitLocationManager()
        let coordinator = CraftWebView.Coordinator(config: config, locationManager: manager)
        let previous = CraftSwiftShim.coordinator
        CraftSwiftShim.coordinator = coordinator
        defer { CraftSwiftShim.coordinator = previous }
        let permission = expectation(description: "foreground permission requested")
        manager.onAuthorizationRequest = { permission.fulfill() }
        let completed = expectation(description: "declined native request settled")
        CraftWebServices.perform(action: "getCurrentPosition", body: [:]) { result in
            guard case .failure(let error) = result else { completed.fulfill(); return XCTFail("Declined permission returned a fix") }
            XCTAssertEqual(error.code, "PERMISSION_DENIED")
            completed.fulfill()
        }
        wait(for: [permission], timeout: 2)
        manager.state = .denied
        coordinator.locationManagerDidChangeAuthorization(manager)
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(manager.fixRequests, 0)
    }

    func testPanProgressDoesNotInvalidateTheWholeChrome() {
        let chrome = CraftChrome.shared
        let tabs = chrome.tabs
        let selected = chrome.selected
        defer {
            chrome.cancelTabSwipe()
            chrome.tabs = tabs
            chrome.selected = selected
        }
        chrome.tabs = [CraftChrome.Tab(id: "/today", title: "Today", symbol: "house", badge: nil), CraftChrome.Tab(id: "/health", title: "Health", symbol: "heart", badge: nil)]
        chrome.selected = "/today"
        chrome.beginTabSwipe(to: "/health", from: "/today")
        var chromeChanges = 0
        var indicatorChanges = 0
        let chromeSubscription = chrome.objectWillChange.sink { chromeChanges += 1 }
        let indicatorSubscription = chrome.tabSwipeProgress.objectWillChange.sink { indicatorChanges += 1 }
        defer { chromeSubscription.cancel(); indicatorSubscription.cancel() }
        for frame in 1...120 { chrome.updateTabSwipe(progress: CGFloat(frame) / 120) }
        XCTAssertEqual(chromeChanges, 0, "tracking must leave tab content, material and splash alone")
        XCTAssertEqual(indicatorChanges, 120)
        XCTAssertEqual(chrome.tabSwipePosition, 1)
        chrome.updateTabSwipe(progress: 1)
        XCTAssertEqual(indicatorChanges, 120, "equal pan positions do not redraw")
        chrome.cancelTabSwipe()
        XCTAssertNil(chrome.tabSwipePosition)
        XCTAssertEqual(chrome.selected, "/today")
    }

    func testTabSelectionCornerRadiusIsOptionalAndValidated() {
        let chrome = CraftChrome.shared
        let tabs = chrome.tabs
        let selected = chrome.selected
        defer {
            chrome.handle(["type": "tabBar", "tabs": []])
            chrome.tabs = tabs
            chrome.selected = selected
        }

        let payload: [String: Any] = [
            "type": "tabBar",
            "tabs": [["id": "/today", "title": "Today", "symbol": "house"]],
            "selection": ["cornerRadius": 6.0],
        ]
        chrome.handle(payload)
        XCTAssertEqual(chrome.tabSelectionCornerRadius, 6)

        chrome.handle(["type": "tabBar", "tabs": payload["tabs"] as Any])
        XCTAssertNil(chrome.tabSelectionCornerRadius, "omitting selection keeps the default capsule")

        chrome.handle([
            "type": "tabBar",
            "tabs": payload["tabs"] as Any,
            "selection": ["cornerRadius": -1.0],
        ])
        XCTAssertNil(chrome.tabSelectionCornerRadius, "negative radii are ignored")
    }

    func testLiveTabReadingPublishesOnceAndEqualReadingsDoNotRedrawChrome() {
        let chrome = CraftChrome.shared
        let previous = chrome.tabs
        defer { chrome.tabs = previous }
        chrome.tabs = [CraftChrome.Tab(id: "/health", title: "Health", symbol: "heart", badge: nil)]
        var publications = 0
        let subscription = chrome.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        let reading: [String: Any] = ["id": "/health", "title": "123 bpm", "iconText": NSNull(), "iconTint": "#ff3b30", "iconPulse": true, "accessibilityLabel": "Health, 123 bpm"]
        chrome.updateTab(reading)
        XCTAssertEqual(publications, 1, "all fields of one reading are committed together")
        for _ in 0..<120 { chrome.updateTab(reading) }
        XCTAssertEqual(publications, 1, "repeated readings must not invalidate SwiftUI during scrolling")
        chrome.updateTab(["id": "/health", "title": NSNull(), "iconTint": NSNull(), "iconPulse": false, "accessibilityLabel": NSNull()])
        XCTAssertEqual(publications, 2)
        XCTAssertEqual(chrome.tabs[0].displayTitle, "Health")
        XCTAssertFalse(chrome.tabs[0].iconPulse)
    }

    func testConfiguredHomeShortcutUsesTheNativeAppDestination() throws {
        let shortcut = try XCTUnwrap(UIApplication.shared.shortcutItems?.first { $0.type == "saved" })
        XCTAssertEqual(shortcut.localizedTitle, "Saved trails")
        XCTAssertEqual(shortcut.userInfo?["url"] as? String, "craft-fixture://saved")
    }

    func testCelebrationStopsWhenARetainedNativeScreenLosesFocus() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        controller.loadViewIfNeeded()
        controller.render(["id": "root-node", "type": "View", "children": [["id": "card-node", "type": "View", "props": ["key": "celebrating-card", "celebration": ["replay": 0]], "style": ["width": 320, "height": 240]]]])
        window.isHidden = false
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        let card = try XCTUnwrap(find(UIView.self, key: "celebrating-card", below: controller.view))
        card.layoutIfNeeded()
        if !UIAccessibility.isReduceMotionEnabled {
            XCTAssertNotNil(card.layer.animation(forKey: "craft.celebration.entrance"))
        }
        controller.screenVisibilityChanged(false)
        XCTAssertNil(card.layer.animation(forKey: "craft.celebration.entrance"))
        XCTAssertFalse(window.layer.sublayers?.contains { $0.name == "craft.celebration.confetti" } == true)
        controller.screenVisibilityChanged(true)
        card.layoutIfNeeded()
        XCTAssertNil(card.layer.animation(forKey: "craft.celebration.entrance"), "returning to a tab must not replay")
        _ = try controller.applyMutation(batch(1, [
            ["op": "updateNode", "id": "card-node", "patch": ["props": ["celebration": ["replay": 1]]]],
        ]))
        card.layoutIfNeeded()
        XCTAssertTrue(card === find(UIView.self, key: "celebrating-card", below: controller.view), "replay retains the card")
        let confetti = window.layer.sublayers?.first { $0.name == "craft.celebration.confetti" }
        if !UIAccessibility.isReduceMotionEnabled {
            XCTAssertNotNil(card.layer.animation(forKey: "craft.celebration.entrance"), "a native prop update starts the next reveal")
            XCTAssertNotNil(confetti)
        }
        _ = try controller.applyMutation(batch(2, [
            ["op": "updateNode", "id": "card-node", "patch": ["props": ["celebration": ["replay": 1]]]],
        ]))
        card.layoutIfNeeded()
        XCTAssertTrue(confetti === window.layer.sublayers?.first { $0.name == "craft.celebration.confetti" }, "an unchanged replay prop keeps the current run")
        controller.screenVisibilityChanged(false)
        XCTAssertFalse(window.layer.sublayers?.contains { $0.name == "craft.celebration.confetti" } == true)
    }

    func testCelebrationRequiresAnExplicitFiniteReplay() {
        XCTAssertNil(CraftNativeCelebrationSpec(nil))
        XCTAssertNil(CraftNativeCelebrationSpec(["replay": true]))
        XCTAssertNil(CraftNativeCelebrationSpec(["replay": -1]))
        XCTAssertNil(CraftNativeCelebrationSpec(["replay": Double.infinity]))
        XCTAssertEqual(CraftNativeCelebrationSpec(["replay": 0])?.enabled, true)
        XCTAssertEqual(CraftNativeCelebrationSpec(["replay": 0, "enabled": false])?.enabled, false)
    }

    func testCelebrationReplaysOnlyOnRequestAndCleansUpForReducedMotionAndBackground() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        window.isHidden = false
        defer { window.isHidden = true }
        let card = UIView(frame: CGRect(x: 24, y: 180, width: 342, height: 280))
        window.rootViewController?.view.addSubview(card)
        let celebration = CraftNativeCelebration(view: card)
        celebration.configure(["replay": 0])
        celebration.layout(reduceMotion: false)
        XCTAssertEqual(celebration.starts, 1)
        XCTAssertTrue(celebration.isRunning)
        XCTAssertNotNil(card.layer.animation(forKey: "craft.celebration.entrance"))
        XCTAssertTrue(window.layer.sublayers?.contains { $0.name == "craft.celebration.confetti" && $0.sublayers?.count == 52 } == true)
        celebration.configure(["replay": 0])
        celebration.layout(reduceMotion: false)
        XCTAssertEqual(celebration.starts, 1, "unrelated reconciliation must not replay")
        celebration.stop()
        XCTAssertFalse(celebration.isRunning)
        XCTAssertNil(card.layer.animation(forKey: "craft.celebration.entrance"))
        XCTAssertFalse(window.layer.sublayers?.contains { $0.name == "craft.celebration.confetti" } == true)
        celebration.configure(["replay": 1])
        celebration.layout(reduceMotion: true)
        XCTAssertEqual(celebration.starts, 1, "Reduce Motion displays the full card without effects")
        celebration.layout(reduceMotion: false)
        XCTAssertEqual(celebration.starts, 1, "changing the preference must not replay a consumed request")
        celebration.configure(["replay": 2])
        celebration.layout(reduceMotion: false)
        XCTAssertEqual(celebration.starts, 2)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertFalse(celebration.isRunning)
        celebration.configure(["replay": 3, "enabled": false])
        celebration.layout(reduceMotion: false)
        XCTAssertEqual(celebration.starts, 2)
        celebration.configure(["replay": 4])
        celebration.layout(reduceMotion: false)
        XCTAssertTrue(celebration.isRunning)
        try await Task.sleep(nanoseconds: 3_200_000_000)
        XCTAssertFalse(celebration.isRunning, "all decoration is removed after the finite reveal")
    }

    func testALiveReadingFillsTheTabIconSelectedOrNotAndGivesItBack() throws {
        let chrome = CraftChrome.shared
        let previous = chrome.tabs
        let selected = chrome.selected
        defer { chrome.tabs = previous; chrome.selected = selected }
        chrome.tabs = [CraftChrome.Tab(id: "/health", title: "Health", symbol: "heart", badge: nil)]
        chrome.selected = "/m"
        // A strap's reading: a red, filled, pulsing heart with the bpm, open or not.
        chrome.updateTab(["id": "/health", "symbol": "heart.fill", "title": "145 bpm", "iconTint": "#ff3b30", "iconPulse": true])
        for open in [false, true] {
            let look = chrome.tabs[0].iconAppearance(selected: open, motionAllowed: true)
            XCTAssertEqual(look.symbol, "heart.fill")
            XCTAssertEqual(look.tint, "#ff3b30")
            XCTAssertTrue(look.pulse)
        }
        XCTAssertEqual(chrome.tabs[0].displayTitle, "145 bpm")
        // The reading goes: the configured heart, plain, open or not.
        chrome.updateTab(["id": "/health", "symbol": NSNull(), "title": NSNull(), "iconTint": NSNull(), "iconPulse": false])
        for open in [false, true] {
            let look = chrome.tabs[0].iconAppearance(selected: open, motionAllowed: true)
            XCTAssertEqual(look.symbol, "heart")
            XCTAssertNil(look.tint)
            XCTAssertFalse(look.pulse)
        }
        XCTAssertEqual(chrome.tabs[0].displayTitle, "Health")
    }

    func testSelectedTabIconPolicySurvivesLiveCaptionCleanupAndResetsExplicitly() throws {
        let configured = try JSONDecoder().decode(CraftConfig.Tab.self, from: Data(##"{"id":"/health","title":"Health","symbol":"heart","selectedSymbol":"heart.fill","selectedIconTint":"#ff3b30","selectedIconPulse":false}"##.utf8))
        XCTAssertEqual(configured.selectedSymbol, "heart.fill")
        XCTAssertEqual(configured.selectedIconTint, "#ff3b30")
        XCTAssertEqual(configured.selectedIconPulse, false)
        let chrome = CraftChrome.shared
        let previous = chrome.tabs
        let selected = chrome.selected
        defer { chrome.tabs = previous; chrome.selected = selected }
        chrome.tabs = [CraftChrome.Tab(id: "/health", title: "Health", symbol: "heart", badge: "2")]
        chrome.selected = "/health"
        chrome.updateTab(["id": "/health", "selectedSymbol": "heart.fill", "selectedIconTint": "#ff3b30", "selectedIconPulse": true])
        var active = chrome.tabs[0].iconAppearance(selected: chrome.selected == "/health", motionAllowed: true)
        XCTAssertEqual(active.symbol, "heart.fill")
        XCTAssertEqual(active.tint, "#ff3b30")
        XCTAssertTrue(active.pulse, "selection must work without a heart-rate sensor")
        let inactive = chrome.tabs[0].iconAppearance(selected: false, motionAllowed: true)
        XCTAssertEqual(inactive.symbol, "heart")
        XCTAssertNil(inactive.tint)
        XCTAssertFalse(inactive.pulse)
        XCTAssertFalse(chrome.tabs[0].iconAppearance(selected: true, motionAllowed: false).pulse, "Reduce Motion, hidden bars and inactive scenes stop animation")
        chrome.updateTab(["id": "/health", "selectedSymbol": " \n "])
        XCTAssertNil(chrome.tabs[0].selectedSymbol, "blank overrides restore the base symbol on both platforms")
        chrome.updateTab(["id": "/health", "selectedSymbol": " heart.fill "])
        XCTAssertEqual(chrome.tabs[0].selectedSymbol, "heart.fill")
        chrome.updateTab(["id": "/health", "title": "145 bpm", "iconTint": "#ff3b30", "iconPulse": true])
        chrome.updateTab(["id": "/health", "title": NSNull(), "iconTint": NSNull(), "iconPulse": false])
        active = chrome.tabs[0].iconAppearance(selected: true, motionAllowed: true)
        XCTAssertEqual(active.symbol, "heart.fill")
        XCTAssertTrue(active.pulse, "stale live-reading cleanup must preserve selected styling")
        XCTAssertEqual(chrome.tabs[0].displayTitle, "Health")
        XCTAssertEqual(chrome.tabs[0].badge, "2")
        XCTAssertEqual(chrome.selected, "/health")
        chrome.updateTab(["id": "/health", "iconPulse": true, "selectedIconPulse": false])
        XCTAssertFalse(chrome.tabs[0].iconAppearance(selected: true, motionAllowed: true).pulse, "false overrides the legacy pulse")
        chrome.updateTab(["id": "/health", "selectedSymbol": NSNull(), "selectedIconTint": "invalid", "selectedIconPulse": NSNull()])
        active = chrome.tabs[0].iconAppearance(selected: true, motionAllowed: true)
        XCTAssertEqual(active.symbol, "heart")
        XCTAssertNil(active.tint)
        XCTAssertTrue(active.pulse, "null restores the legacy pulse")
    }

    func testTabUpdatesKeepTheIconAndSelectionWhileChangingItsLiveCaption() {
        let chrome = CraftChrome.shared
        let previous = chrome.tabs
        let selected = chrome.selected
        defer { chrome.tabs = previous; chrome.selected = selected }
        chrome.tabs = [CraftChrome.Tab(id: "/health", title: "Health", symbol: "heart", badge: "2")]
        chrome.selected = "/other"
        chrome.updateTab(["id": "/health", "title": "123 bpm", "iconText": NSNull(), "iconTint": "#ff3b30", "iconPulse": true, "accessibilityLabel": "Health, live heart rate, 123 bpm"])
        XCTAssertEqual(chrome.tabs[0].displayTitle, "123 bpm")
        XCTAssertEqual(chrome.tabs[0].symbol, "heart")
        XCTAssertNil(chrome.tabs[0].iconText)
        XCTAssertEqual(chrome.tabs[0].iconTint, "#ff3b30")
        XCTAssertTrue(chrome.tabs[0].iconPulse)
        XCTAssertEqual(chrome.tabs[0].badge, "2")
        XCTAssertEqual(chrome.selected, "/other")
        chrome.updateTab(["id": "/health", "title": NSNull(), "iconTint": NSNull(), "iconPulse": false, "accessibilityLabel": NSNull()])
        XCTAssertEqual(chrome.tabs[0].displayTitle, "Health")
        XCTAssertNil(chrome.tabs[0].iconTint)
        XCTAssertNil(chrome.tabs[0].accessibilityLabel)
        XCTAssertFalse(chrome.tabs[0].iconPulse)
        chrome.updateTab(["id": "/missing", "title": "Ignored", "iconPulse": true])
        XCTAssertEqual(chrome.tabs[0].displayTitle, "Health")
    }

    func testInitialLinkWaitsForLaunchIntentInsteadOfScreenReadiness() {
        let launch = CraftInitialLinkState()
        var answers: [URL?] = []
        launch.resolve { answers.append($0) }
        XCTAssertTrue(answers.isEmpty)
        let url = URL(string: "https://hq.training/diego-ruiz")!
        launch.receive(url)
        XCTAssertEqual(answers, [url])
        launch.resolve { answers.append($0) }
        XCTAssertEqual(answers, [url, url])
        launch.receive(URL(string: "https://hq.training/pawel")!)
        XCTAssertEqual(launch.url, url)
    }

    func testActivationWithoutALaunchLinkDoesNotClaimTheFirstWarmLink() {
        let launch = CraftInitialLinkState()
        var answers: [URL?] = []
        launch.resolve { answers.append($0) }
        launch.settle()
        launch.receive(URL(string: "https://hq.training/pawel")!)
        launch.resolve { answers.append($0) }
        XCTAssertTrue(launch.settled)
        XCTAssertNil(launch.url)
        XCTAssertEqual(answers.count, 2)
        XCTAssertTrue(answers.allSatisfy { $0 == nil })
    }

    private func capability(
        _ module: String,
        _ method: String,
        _ args: [Any] = [],
        config: CraftConfig = CraftConfig()
    ) async -> Result<Any, CraftNativeActionError> {
        await withCheckedContinuation { continuation in
            CraftNativeActions.perform(
                requestToken: UUID().uuidString,
                version: craftNativeCapabilityProtocolVersion,
                module: module,
                method: method,
                args: args,
                config: config
            ) { continuation.resume(returning: $0) }
        }
    }

    private func assertInvalidFetch(_ options: [String: Any], line: UInt = #line) async {
        guard case .failure(let error) = await capability("Network", "fetch", [options]) else {
            return XCTFail("malformed fetch options unexpectedly succeeded", file: #filePath, line: line)
        }
        XCTAssertEqual(error.code, "INVALID_ARGUMENT", file: #filePath, line: line)
    }

    private func batch(
        _ revision: Int,
        _ operations: [[String: Any]],
        version: Int = 1,
        baseRevision: Int? = nil
    ) -> [String: Any] {
        [
            "version": version,
            "batchId": "batch-\(revision)",
            "baseRevision": baseRevision ?? revision - 1,
            "revision": revision,
            "operations": operations,
        ]
    }

    private func node(_ type: String, key: String, text: String? = nil, style: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = ["type": type, "props": ["key": key], "style": style]
        if let text = text { result["children"] = [text] }
        return result
    }

    private func document(_ children: [[String: Any]]) -> [String: Any] {
        ["type": "View", "children": children]
    }

    private func find<T: UIView>(_ type: T.Type, key: String, below view: UIView) -> T? {
        if let match = view as? T, match.accessibilityIdentifier == key { return match }
        for child in view.subviews {
            if let match = find(type, key: key, below: child) { return match }
        }
        return nil
    }

    func testKeyedViewsKeepIdentityAcrossUpdatesAndMoves() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([
            node("Text", key: "count", text: "Count: 0"),
            node("Button", key: "increment", text: "Increment"),
            node("TextInput", key: "name-input", style: ["width": 140]),
            node("Text", key: "name", text: "Hello"),
        ]))

        let field = try XCTUnwrap(find(UITextField.self, key: "name-input", below: controller.view))
        let count = try XCTUnwrap(find(UILabel.self, key: "count", below: controller.view))
        let button = try XCTUnwrap(find(UIButton.self, key: "increment", below: controller.view))
        field.text = "Ada"
        let caret = try XCTUnwrap(field.position(from: field.beginningOfDocument, offset: 2))
        field.selectedTextRange = field.textRange(from: caret, to: caret)

        controller.render(document([
            node("Text", key: "count", text: "Count: 1"),
            node("Button", key: "increment", text: "Again"),
            node("TextInput", key: "name-input", style: ["width": 180]),
            node("Text", key: "name", text: "Hello Ada"),
        ]))
        XCTAssertTrue(field === find(UITextField.self, key: "name-input", below: controller.view))
        XCTAssertTrue(count === find(UILabel.self, key: "count", below: controller.view))
        XCTAssertTrue(button === find(UIButton.self, key: "increment", below: controller.view))
        XCTAssertEqual(field.text, "Ada")
        let selection = try XCTUnwrap(field.selectedTextRange)
        XCTAssertEqual(field.offset(from: field.beginningOfDocument, to: selection.start), 2)
        XCTAssertEqual(count.text, "Count: 1")
        XCTAssertEqual(button.title(for: .normal), "Again")
        XCTAssertEqual(field.constraints.first(where: { $0.firstAttribute == .width && $0.isActive })?.constant, 180)

        controller.render(document([
            node("TextInput", key: "name-input"),
            node("Text", key: "count", text: "Count: 2"),
            node("Button", key: "increment", text: "Again"),
        ]))
        XCTAssertTrue(field === find(UITextField.self, key: "name-input", below: controller.view))
        let root = try XCTUnwrap(find(UIStackView.self, key: "root", below: controller.view))
        XCTAssertTrue(root.arrangedSubviews.first === field)
        XCTAssertFalse(field.constraints.contains(where: { $0.firstAttribute == .width && $0.isActive }))

        controller.render(document([node("Text", key: "name-input", text: "Replaced")]))
        XCTAssertNil(field.superview)
        XCTAssertNotNil(find(UILabel.self, key: "name-input", below: controller.view))
    }

    func testNativeTextScalesWithTheScreenContentSizeTrait() throws {
        let host = UIViewController()
        let controller = CraftNativeScreenController(config: CraftConfig())
        host.addChild(controller)
        host.view.addSubview(controller.view)
        host.setOverrideTraitCollection(
            UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge),
            forChild: controller
        )
        controller.didMove(toParent: host)
        controller.render(document([node("Text", key: "dynamic-text", text: "Dynamic", style: ["fontSize": 16])]))

        let label = try XCTUnwrap(find(UILabel.self, key: "dynamic-text", below: controller.view))
        let expected = UIFontMetrics(forTextStyle: .body).scaledValue(
            for: 16,
            compatibleWith: controller.traitCollection
        )
        XCTAssertEqual(label.font.pointSize, expected, accuracy: 0.1)
        XCTAssertGreaterThan(label.font.pointSize, 16)
    }

    func testItalicNativeTextKeepsDynamicTypeScaling() throws {
        let host = UIViewController()
        let controller = CraftNativeScreenController(config: CraftConfig())
        host.addChild(controller)
        host.view.addSubview(controller.view)
        host.setOverrideTraitCollection(
            UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge),
            forChild: controller
        )
        controller.didMove(toParent: host)
        controller.render(document([node(
            "Text",
            key: "italic-dynamic-text",
            text: "Italic",
            style: ["fontSize": 16, "fontStyle": "italic"]
        )]))

        let label = try XCTUnwrap(find(UILabel.self, key: "italic-dynamic-text", below: controller.view))
        let expected = UIFontMetrics(forTextStyle: .body).scaledValue(
            for: 16,
            compatibleWith: controller.traitCollection
        )
        XCTAssertEqual(label.font.pointSize, expected, accuracy: 0.1)
        XCTAssertTrue(label.font.fontDescriptor.symbolicTraits.contains(.traitItalic))
    }

    func testTextInputTraitsFollowHostNeutralProps() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([
            [
                "type": "TextInput",
                "props": [
                    "key": "single",
                    "keyboardType": "email-address",
                    "returnKeyType": "done",
                    "autoCapitalize": "characters",
                    "autoCorrect": false,
                    "secureTextEntry": true,
                    "editable": false,
                ],
            ],
            [
                "type": "TextInput",
                "props": [
                    "key": "multi",
                    "multiline": true,
                    "keyboardType": "decimal-pad",
                    "returnKeyType": "send",
                    "autoCapitalize": "words",
                ],
            ],
        ]))

        let single = try XCTUnwrap(find(UITextField.self, key: "single", below: controller.view))
        XCTAssertEqual(single.keyboardType, .emailAddress)
        XCTAssertEqual(single.returnKeyType, .done)
        XCTAssertEqual(single.autocapitalizationType, .allCharacters)
        XCTAssertEqual(single.autocorrectionType, .no)
        XCTAssertTrue(single.isSecureTextEntry)
        XCTAssertFalse(single.isEnabled)

        let multi = try XCTUnwrap(find(UITextView.self, key: "multi", below: controller.view))
        XCTAssertEqual(multi.keyboardType, .decimalPad)
        XCTAssertEqual(multi.returnKeyType, .send)
        XCTAssertEqual(multi.autocapitalizationType, .words)
        XCTAssertEqual(multi.autocorrectionType, .default)
    }

    func testTextInputAccessibilityValueRestoresNativeValueWhenPropIsRemoved() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([[
            "type": "TextInput",
            "props": ["key": "field", "value": "Draft", "accessibilityValue": "Custom value"],
        ]]))

        let field = try XCTUnwrap(find(UITextField.self, key: "field", below: controller.view))
        XCTAssertEqual(field.accessibilityValue, "Custom value")

        controller.render(document([[
            "type": "TextInput",
            "props": ["key": "field", "value": "Draft"],
        ]]))
        // UIKit's own value again: what a field holding the same text says
        // (its text, on current iOS), never the authored one.
        let native = UITextField()
        native.text = "Draft"
        XCTAssertNotEqual(field.accessibilityValue, "Custom value")
        XCTAssertEqual(field.accessibilityValue, native.accessibilityValue)
    }

    func testPersistentStorageAndDatabaseCapabilitiesRoundTripJSONValues() async throws {
        _ = await capability("Storage", "clear")
        let stored = await capability("Storage", "set", ["profile", ["name": "Ada", "visits": 2]])
        guard case .success = stored else { return XCTFail("storage set failed") }
        guard case .success(let value) = await capability("Storage", "get", ["profile"]),
              let profile = value as? [String: Any] else { return XCTFail("storage get failed") }
        XCTAssertEqual(profile["name"] as? String, "Ada")
        XCTAssertEqual(profile["visits"] as? Int, 2)

        var config = CraftConfig()
        config.enableLocalDatabase = true
        let table = "capability_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        guard case .success = await capability("Database", "execute", [
            "CREATE TABLE \(table) (id INTEGER PRIMARY KEY, name TEXT NOT NULL)", [],
        ], config: config) else { return XCTFail("database create failed") }
        guard case .success = await capability("Database", "beginTransaction", [], config: config) else {
            return XCTFail("database transaction failed")
        }
        _ = await capability("Database", "execute", ["INSERT INTO \(table) (name) VALUES (?)", ["Grace"]], config: config)
        _ = await capability("Database", "commit", [], config: config)
        guard case .success(let rows) = await capability("Database", "query", [
            "SELECT name FROM \(table)", [],
        ], config: config), let first = (rows as? [[String: Any]])?.first else {
            return XCTFail("database query failed")
        }
        XCTAssertEqual(first["name"] as? String, "Grace")
    }

    func testFetchRejectsMalformedOptionsBeforeOpeningNetwork() async {
        XCTAssertTrue(CraftNativeActions.capabilities(config: CraftConfig()).contains("fetch"))
        await assertInvalidFetch(["url": "/api/activities"])
        await assertInvalidFetch([
            "url": "http://127.0.0.1/api/activities",
            "method": "GET",
            "body": "not allowed",
        ])
        await assertInvalidFetch([
            "url": "http://127.0.0.1/api/activities",
            "body": 42,
        ])
        await assertInvalidFetch([
            "url": "http://127.0.0.1/api/activities",
            "headers": ["X-Native-Test": 42],
        ])
    }

    func testUnkeyedChildrenReusePositionAndRemovedChildrenDetach() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([
            ["type": "Text", "children": ["First"]],
            ["type": "Text", "children": ["Second"]],
        ]))
        let first = try XCTUnwrap(find(UILabel.self, key: "root.0", below: controller.view))
        let second = try XCTUnwrap(find(UILabel.self, key: "root.1", below: controller.view))
        controller.render(document([["type": "Text", "children": ["Updated"]]]))
        XCTAssertTrue(first === find(UILabel.self, key: "root.0", below: controller.view))
        XCTAssertEqual(first.text, "Updated")
        XCTAssertNil(second.superview)
    }

    func testImageAndScrollViewAreNativeAccessibleAndStable() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        let pixel = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let image: [String: Any] = [
            "type": "Image",
            "props": ["key": "avatar", "source": ["uri": pixel], "accessibilityLabel": "Profile photo", "accessibilityRole": "image"],
            "style": ["width": 24, "height": 24, "resizeMode": "cover"]
        ]
        let scroll: [String: Any] = [
            "type": "ScrollView", "props": ["key": "feed"], "style": ["height": 80, "gap": 6],
            "children": [image, node("Text", key: "caption", text: "Native content")]
        ]
        controller.render(document([scroll]))

        let scrollView = try XCTUnwrap(find(UIScrollView.self, key: "feed", below: controller.view))
        let imageView = try XCTUnwrap(find(UIImageView.self, key: "avatar", below: controller.view))
        XCTAssertNotNil(imageView.image)
        XCTAssertEqual(imageView.accessibilityLabel, "Profile photo")
        XCTAssertTrue(imageView.accessibilityTraits.contains(.image))
        XCTAssertEqual(imageView.contentMode, .scaleAspectFill)

        controller.render(document([scroll]))
        XCTAssertTrue(scrollView === find(UIScrollView.self, key: "feed", below: controller.view))
        XCTAssertTrue(imageView === find(UIImageView.self, key: "avatar", below: controller.view))
    }

    /// Calendar may retarget a retained screen twice in one update: an
    /// animated week-top request, then its actual nonanimated selected day.
    /// Sticky geometry must follow the final viewport without a JS onScroll.
    func testStickyHeaderTracksRetargetedDaysAndReactiveReconciliation() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = try hostWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()

        func calendar(target: String, key: Int, animated: Bool, revision: Int) -> [String: Any] {
            ["id": "calendar-root", "type": "View", "style": ["flex": 1], "children": [[
                "id": "calendar-scroll", "type": "ScrollView",
                "props": ["key": "calendar-scroll", "stickyHeaderIndices": [1],
                          "scrollTarget": ["id": target, "key": key, "animated": animated]],
                "style": ["flex": 1],
                "children": [
                    ["id": "calendar-top", "type": "View", "props": ["key": "calendar-top"], "style": ["height": 160]],
                    ["id": "week-header", "type": "View", "props": ["key": "week-header"],
                     "style": ["height": 80, "backgroundColor": "#f8fafc"],
                     "children": [node("Text", key: "week-label", text: "Week revision \(revision)")]],
                    ["id": "day-26", "type": "View", "props": ["key": "day-26"], "style": ["height": 360],
                     "children": [node("Text", key: "day-26-label", text: "Monday, October 26: \(revision)")]],
                    ["id": "day-27", "type": "View", "props": ["key": "day-27"], "style": ["height": 360]],
                    ["id": "day-28", "type": "View", "props": ["key": "day-28"], "style": ["height": 360],
                     "children": [node("Text", key: "day-28-label", text: "Wednesday, October 28: \(revision)")]],
                    ["id": "trailing", "type": "View", "props": ["key": "trailing"], "style": ["height": 1000]],
                ],
            ]]]
        }

        // One normal layout consumes a pending target. Run the main loop
        // afterwards rather than forcing another scroll layout to repair it.
        func settle() {
            controller.view.layoutIfNeeded()
            let deadline = Date().addingTimeInterval(0.2)
            while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        controller.render(calendar(target: "day-26", key: 1, animated: false, revision: 0))
        settle()
        let scroll = try XCTUnwrap(find(UIScrollView.self, key: "calendar-scroll", below: controller.view))
        let header = try XCTUnwrap(find(UIView.self, key: "week-header", below: scroll))
        let content = try XCTUnwrap(header.superview)
        let naturalCenter = header.center
        let naturalBounds = header.bounds
        XCTAssertGreaterThan(scroll.bounds.height, 0)
        XCTAssertEqual(naturalCenter.y - naturalBounds.height / 2, 160, accuracy: 0.5)
        XCTAssertEqual(naturalBounds.height, 80, accuracy: 0.5)

        func assertSelectedDay(_ id: String, line: UInt = #line) throws {
            let day = try XCTUnwrap(find(UIView.self, key: id, below: scroll), file: #filePath, line: line)
            XCTAssertTrue(scroll === find(UIScrollView.self, key: "calendar-scroll", below: controller.view), file: #filePath, line: line)
            XCTAssertTrue(header === find(UIView.self, key: "week-header", below: scroll), file: #filePath, line: line)
            XCTAssertTrue(header.superview === content, file: #filePath, line: line)
            let visibleTop = scroll.contentOffset.y + scroll.adjustedContentInset.top
            let headerRect = header.convert(header.bounds, to: scroll)
            let dayRect = day.convert(day.bounds, to: scroll)
            XCTAssertEqual(headerRect.minY, visibleTop, accuracy: 0.5, "The sticky header follows this viewport, not the previous target", file: #filePath, line: line)
            XCTAssertEqual(dayRect.minY, headerRect.maxY, accuracy: 0.5, "The selected day starts below the sticky header", file: #filePath, line: line)
            XCTAssertEqual(header.center.x, naturalCenter.x, accuracy: 0.5, file: #filePath, line: line)
            XCTAssertEqual(header.center.y, naturalCenter.y, accuracy: 0.5, file: #filePath, line: line)
            XCTAssertEqual(header.bounds, naturalBounds, file: #filePath, line: line)
        }
        try assertSelectedDay("day-26")
        let mondayOffset = scroll.contentOffset.y

        controller.render(calendar(target: "calendar-top", key: 2, animated: true, revision: 1))
        controller.view.layoutIfNeeded()
        controller.render(calendar(target: "day-28", key: 3, animated: false, revision: 2))
        settle()
        try assertSelectedDay("day-28")
        XCTAssertEqual(scroll.contentOffset.y - mondayOffset, 720, accuracy: 0.5)

        // A later data response reconciles the same keyed header and days,
        // without changing the target key or emitting any JS scroll handler.
        controller.render(calendar(target: "day-28", key: 3, animated: false, revision: 3))
        settle()
        try assertSelectedDay("day-28")

        controller.render(calendar(target: "day-26", key: 4, animated: false, revision: 4))
        settle()
        try assertSelectedDay("day-26")
        XCTAssertEqual(scroll.contentOffset.y, mondayOffset, accuracy: 0.5)
    }

    func testHeaderAccessibilityRoleMapsToUIKitTrait() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([[
            "type": "Text",
            "props": ["key": "header", "accessibilityRole": "header"],
            "children": ["People directory"],
        ]]))

        let header = try XCTUnwrap(find(UILabel.self, key: "header", below: controller.view))
        XCTAssertTrue(header.accessibilityTraits.contains(.header))
    }

    func testButtonRowWithoutALabelReadsItsText() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([
            [
                "type": "View",
                "props": ["key": "email-row", "accessibilityRole": "button"],
                "children": [
                    ["type": "Image", "props": ["key": "avatar", "accessibilityLabel": "Diego Ruiz"], "children": []],
                    ["type": "Text", "props": ["key": "name"], "children": ["Diego Ruiz"]],
                    ["type": "View", "props": ["key": "inner"], "children": [
                        ["type": "Text", "props": ["key": "email"], "children": ["diego@example.org"]],
                    ]],
                    ["type": "Icon", "props": ["key": "chevron", "name": "chevron-right"], "children": []],
                ],
            ],
            [
                "type": "View",
                "props": ["key": "labelled", "accessibilityRole": "button", "accessibilityLabel": "Sign out"],
                "children": [["type": "Text", "props": ["key": "inside"], "children": ["Log out"]]],
            ],
            [
                "type": "View",
                "props": ["key": "plain"],
                "children": [["type": "Text", "props": ["key": "loose"], "children": ["Not grouped"]]],
            ],
        ]))

        let row = try XCTUnwrap(find(UIView.self, key: "email-row", below: controller.view))
        XCTAssertTrue(row.isAccessibilityElement)
        XCTAssertEqual(row.accessibilityLabel, "Diego Ruiz, diego@example.org")
        XCTAssertTrue(row.accessibilityTraits.contains(.button))
        XCTAssertEqual(try XCTUnwrap(find(UIView.self, key: "labelled", below: controller.view)).accessibilityLabel, "Sign out")
        XCTAssertNil(try XCTUnwrap(find(UIView.self, key: "plain", below: controller.view)).accessibilityLabel)
        // The chevron is decoration: no stop of its own, nothing said.
        let chevron = try XCTUnwrap(find(UIImageView.self, key: "chevron", below: controller.view))
        XCTAssertFalse(chevron.isAccessibilityElement)
        XCTAssertNil(chevron.accessibilityLabel)
    }

    func testALabelledIconIsReadAndAnUnlabelledOneIsNot() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([
            ["type": "Icon", "props": ["key": "labelled", "name": "heart.fill", "accessibilityLabel": "Favourite"], "children": []],
            ["type": "Icon", "props": ["key": "plain", "name": "heart.fill"], "children": []],
        ]))
        let labelled = try XCTUnwrap(find(UIImageView.self, key: "labelled", below: controller.view))
        XCTAssertTrue(labelled.isAccessibilityElement)
        XCTAssertEqual(labelled.accessibilityLabel, "Favourite")
        let plain = try XCTUnwrap(find(UIImageView.self, key: "plain", below: controller.view))
        XCTAssertFalse(plain.isAccessibilityElement)
        XCTAssertNil(plain.accessibilityLabel)
    }

    func testSharedLayoutColorAndTextStylesMapToUIKit() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        let first = node("Text", key: "first", text: "first", style: [
            "color": "#123456", "fontSize": 21, "fontWeight": "700", "fontStyle": "italic",
            "textAlign": "right", "letterSpacing": 2, "lineHeight": 28, "textTransform": "uppercase",
            "textDecorationLine": "underline"
        ])
        let second = node("Text", key: "second", text: "second")
        controller.render(document([[
            "type": "View", "props": ["key": "styled"],
            "style": [
                "flexDirection": "row-reverse", "alignItems": "center", "justifyContent": "center",
                "gap": 7, "paddingHorizontal": 11, "paddingVertical": 5,
                "width": 240, "height": 80, "backgroundColor": "#abcdef", "opacity": 0.75,
                "borderWidth": 3, "borderColor": "#654321", "borderRadius": 9, "overflow": "hidden"
            ],
            "children": [first, second]
        ]]))

        let stack = try XCTUnwrap(find(UIStackView.self, key: "styled", below: controller.view))
        let label = try XCTUnwrap(find(UILabel.self, key: "first", below: controller.view))
        XCTAssertEqual(stack.axis, .horizontal)
        XCTAssertEqual(stack.alignment, .center)
        XCTAssertEqual(stack.spacing, 7)
        XCTAssertEqual(stack.layoutMargins.left, 11)
        XCTAssertEqual(stack.layoutMargins.top, 5)
        XCTAssertEqual(stack.arrangedSubviews.compactMap { $0.accessibilityIdentifier }, ["second", "first"])
        XCTAssertEqual(stack.alpha, 0.75)
        XCTAssertEqual(stack.layer.borderWidth, 3)
        XCTAssertEqual(stack.layer.cornerRadius, 9)
        XCTAssertTrue(stack.clipsToBounds)
        XCTAssertEqual(label.text, "FIRST")
        XCTAssertEqual(label.font.pointSize, 21)
        XCTAssertTrue(label.font.fontDescriptor.symbolicTraits.contains(.traitItalic))
        XCTAssertEqual(label.textAlignment, .right)
        XCTAssertEqual(label.attributedText?.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat, 2)
        XCTAssertNotNil(label.attributedText?.attribute(.underlineStyle, at: 0, effectiveRange: nil))
    }

    func testKeptPrivateImageLoadsOfflineAndDoesNotSurviveSourceReplacement() throws {
        let address = "https://kept-image.invalid/\(UUID().uuidString).png"
        let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: location)
            try? FileManager.default.removeItem(at: CraftNativeMedia.file(for: address))
        }
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 7, height: 5)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 7, height: 5))
        }.pngData())
        try png.write(to: location)
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: address)!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Length": String(png.count)]))
        if case .failure(let error) = CraftNativeMedia.store(address, at: location, response: response) {
            return XCTFail("Could not seed kept image: \(error.message)")
        }
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        func render(_ uri: String) {
            controller.render(document([["type": "Image", "props": ["key": "kept",
                "source": ["uri": uri, "headers": ["Authorization": "Bearer private-fixture"]]]]]))
        }
        render(address)
        let image = try XCTUnwrap(find(UIImageView.self, key: "kept", below: controller.view))
        let deadline = Date().addingTimeInterval(3)
        while image.image == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        let decoded = try XCTUnwrap(image.image, "HTTPS .invalid cannot supply this image: the kept copy must be read")
        XCTAssertEqual(decoded.size.width / decoded.size.height, 7.0 / 5.0, accuracy: 0.001)
        XCTAssertNil(image.accessibilityValue)

        // A kept copy is not permission to load arbitrary filesystem URLs.
        render(CraftNativeMedia.file(for: address).absoluteString)
        XCTAssertNil(image.image)
        XCTAssertEqual(image.accessibilityValue, "Unsupported image source")

        // Queue a local decode then replace its source before the main queue
        // can deliver it. Late pixels must not overwrite the replacement.
        render(address)
        render("data:image/png;base64,invalid")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNil(image.image)
        XCTAssertEqual(image.accessibilityValue, "Image data is invalid")

        // A second mount must re-read kept bytes, not a global decoded cache.
        try Data([1, 2, 3]).write(to: CraftNativeMedia.file(for: address))
        render(address)
        let failureDeadline = Date().addingTimeInterval(3)
        while image.accessibilityValue == nil && Date() < failureDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertNil(image.image)
        XCTAssertEqual(image.accessibilityValue, "Kept image is unavailable or invalid")
    }

    func testImageFailuresAreExplicitAndClearStaleContent() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([[
            "type": "Image", "props": ["key": "broken", "source": ["uri": "data:image/png;base64,invalid"]]
        ]]))
        let image = try XCTUnwrap(find(UIImageView.self, key: "broken", below: controller.view))
        XCTAssertNil(image.image)
        XCTAssertEqual(image.accessibilityValue, "Image data is invalid")

        controller.render(document([[
            "type": "Image", "props": ["key": "broken", "source": ["uri": "http://example.com/image.png"]]
        ]]))
        XCTAssertEqual(image.accessibilityValue, "Unsupported image source")

        controller.render(document([["type": "Image", "props": ["key": "broken"]]]))
        XCTAssertEqual(image.accessibilityValue, "Image source is missing")

        controller.render(document([["type": "Text", "props": ["key": "status"], "children": ["Updated"]], [
            "type": "Image", "props": ["key": "broken", "source": ["uri": "http://example.com/image.png"]]
        ]]))
        XCTAssertEqual(image.accessibilityValue, "Unsupported image source")

        controller.render(document([[
            "type": "Image",
            "props": [
                "key": "broken",
                "source": ["uri": "http://example.com/image.png"],
                "accessibilityValue": "ready",
            ],
        ]]))
        XCTAssertEqual(image.accessibilityValue, "ready, Unsupported image source")
    }

    func testMutationBatchesPreserveControlsFocusScrollAndHandlers() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(["id": "root-node", "type": "View", "children": []])
        try controller.applyMutation(batch(1, [
            ["op": "createNode", "id": "field-node", "node": [
                "type": "TextInput", "props": ["testID": "field"], "events": ["onChange": "changed"]
            ]],
            ["op": "createNode", "id": "scroll-node", "node": [
                "type": "ScrollView", "props": ["testID": "scroll"], "style": ["height": 40]
            ]],
            ["op": "createNode", "id": "label-node", "node": [
                "type": "Text", "props": ["testID": "label", "accessibilityLabel": "Before"],
                "style": ["color": "#ff0000"],
                "children": ["Before"]
            ]],
            ["op": "insertChild", "parentId": "scroll-node", "childId": "label-node", "index": 0],
            ["op": "insertChild", "parentId": "root-node", "childId": "field-node", "index": 0],
            ["op": "insertChild", "parentId": "root-node", "childId": "scroll-node", "index": 1],
        ]))

        let field = try XCTUnwrap(find(UITextField.self, key: "field", below: controller.view))
        let scroll = try XCTUnwrap(find(UIScrollView.self, key: "scroll", below: controller.view))
        let label = try XCTUnwrap(find(UILabel.self, key: "label", below: controller.view))
        field.text = "draft"
        let caret = try XCTUnwrap(field.position(from: field.beginningOfDocument, offset: 3))
        field.selectedTextRange = field.textRange(from: caret, to: caret)
        scroll.contentOffset = CGPoint(x: 0, y: 17)

        let update = try controller.applyMutation(batch(2, [
            ["op": "updateNode", "id": "label-node", "patch": [
                "children": ["After"],
                "props": ["accessibilityLabel": "After"],
                "style": ["fontSize": 18],
                "events": ["onPress": "pressed"],
            ]],
        ]))
        XCTAssertFalse(update.requiresFullRender)
        XCTAssertEqual(update.updatedNodeIds, ["label-node"])

        XCTAssertTrue(field === find(UITextField.self, key: "field", below: controller.view))
        XCTAssertTrue(scroll === find(UIScrollView.self, key: "scroll", below: controller.view))
        XCTAssertTrue(label === find(UILabel.self, key: "label", below: controller.view))
        XCTAssertEqual(field.text, "draft")
        let selection = try XCTUnwrap(field.selectedTextRange)
        XCTAssertEqual(field.offset(from: field.beginningOfDocument, to: selection.start), 3)
        XCTAssertEqual(scroll.contentOffset.y, 17)
        XCTAssertEqual(label.text, "After")
        XCTAssertEqual(label.accessibilityLabel, "After")
        XCTAssertEqual(label.textColor, UIColor.red)
        XCTAssertEqual(label.font.pointSize, 18)

        let move = try controller.applyMutation(batch(3, [
            ["op": "moveChild", "parentId": "root-node", "childId": "scroll-node", "index": 0],
        ]))
        XCTAssertFalse(move.requiresFullRender)
        XCTAssertEqual(move.affectedNodeIds, ["root-node"])
        XCTAssertTrue(field === find(UITextField.self, key: "field", below: controller.view))
        XCTAssertTrue(scroll === find(UIScrollView.self, key: "scroll", below: controller.view))
    }

    func testReparentedInputKeepsNativeIdentityAndSelection() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render([
            "id": "root-node", "type": "View", "children": [
                ["id": "source-node", "type": "ScrollView", "style": ["height": 80], "children": [
                    ["id": "popup-node", "type": "View", "props": ["testID": "popup"], "style": ["height": 160], "children": [
                        ["id": "popup-field", "type": "TextInput", "props": ["testID": "popup-field"], "children": []],
                    ]],
                ]],
                ["id": "destination-node", "type": "View", "props": ["testID": "destination"], "children": []],
            ],
        ])
        let scroll = try XCTUnwrap(find(UIScrollView.self, key: "source-node", below: controller.view))
        scroll.contentOffset = CGPoint(x: 0, y: 40)
        let field = try XCTUnwrap(find(UITextField.self, key: "popup-field", below: controller.view))
        field.text = "draft"
        let caret = try XCTUnwrap(field.position(from: field.beginningOfDocument, offset: 3))
        field.selectedTextRange = field.textRange(from: caret, to: caret)

        let result = try controller.applyMutation(batch(1, [
            ["op": "reparentChild", "parentId": "destination-node", "childId": "popup-node", "index": 0],
        ]))
        XCTAssertTrue(result.requiresFullRender)

        let retained = try XCTUnwrap(find(UITextField.self, key: "popup-field", below: controller.view))
        XCTAssertTrue(field === retained)
        XCTAssertEqual(retained.text, "draft")
        let selection = try XCTUnwrap(retained.selectedTextRange)
        XCTAssertEqual(retained.offset(from: retained.beginningOfDocument, to: selection.start), 3)
        XCTAssertEqual(scroll.contentOffset.y, 40)
        let destination = try XCTUnwrap(find(UIView.self, key: "destination", below: controller.view))
        XCTAssertTrue(try XCTUnwrap(find(UIView.self, key: "popup", below: controller.view)).superview === destination)
    }

    func testMutationPreservesAuthoredKeysAcrossImportCreationUpdatesAndMoves() throws {
        let document = CraftNativeMutationDocument()
        document.replace(with: [
            "id": "root", "type": "View", "key": "root-key", "children": [
                ["id": "existing", "type": "TextInput", "key": "draft-key", "props": ["value": "draft"]],
            ],
        ])
        XCTAssertEqual(document.node("existing")?["key"] as? String, "draft-key")
        let result = try document.apply(batch(1, [
            ["op": "createNode", "id": "created", "node": ["type": "View", "key": "created-key"]],
            ["op": "insertChild", "parentId": "root", "childId": "created", "index": 1],
            ["op": "updateNode", "id": "existing", "patch": ["props": ["value": "edited"]]],
            ["op": "moveChild", "parentId": "root", "childId": "created", "index": 0],
        ]))
        let rendered = try XCTUnwrap(result.document)
        let children = try XCTUnwrap(rendered["children"] as? [[String: Any]])
        XCTAssertEqual(rendered["key"] as? String, "root-key")
        XCTAssertEqual(children[0]["key"] as? String, "created-key")
        XCTAssertEqual(children[1]["key"] as? String, "draft-key")
        XCTAssertEqual((document.node("existing")?["props"] as? [String: Any])?["value"] as? String, "edited")
    }

    func testReparentChildMovesAcrossParentsAtomically() throws {
        let document = CraftNativeMutationDocument()
        _ = try document.apply(batch(1, [
            ["op": "createNode", "id": "root", "root": true, "node": ["type": "View"]],
            ["op": "createNode", "id": "source", "node": ["type": "View"]],
            ["op": "createNode", "id": "destination", "node": ["type": "View"]],
            ["op": "createNode", "id": "popup", "node": ["type": "TextInput", "key": "popup"]],
            ["op": "insertChild", "parentId": "root", "childId": "source", "index": 0],
            ["op": "insertChild", "parentId": "root", "childId": "destination", "index": 1],
            ["op": "insertChild", "parentId": "source", "childId": "popup", "index": 0],
        ]))
        let result = try document.apply(batch(2, [
            ["op": "reparentChild", "parentId": "destination", "childId": "popup", "index": 0],
        ]))
        XCTAssertEqual(document.parentId(of: "popup"), "destination")
        XCTAssertEqual(result.affectedNodeIds, ["destination", "source"])
        XCTAssertTrue(result.requiresFullRender)
        let child = try XCTUnwrap((document.node("destination")?["children"] as? [[String: Any]])?.first)
        XCTAssertEqual(child["id"] as? String, "popup")
    }

    func testReplaceChildrenReconcilesKeyedRowsAtomically() throws {
        let document = CraftNativeMutationDocument()
        _ = try document.apply(batch(1, [
            ["op": "createNode", "id": "root", "root": true, "node": ["type": "View"]],
            ["op": "createNode", "id": "list", "node": ["type": "FlatList"]],
            ["op": "createNode", "id": "first", "node": ["type": "Text", "key": "first", "children": ["First"]]],
            ["op": "createNode", "id": "second", "node": ["type": "Text", "key": "second", "children": ["Second"]]],
            ["op": "createNode", "id": "third", "node": ["type": "Text", "key": "third", "children": ["Third"]]],
            ["op": "insertChild", "parentId": "root", "childId": "list", "index": 0],
            ["op": "replaceChildren", "parentId": "list", "children": ["first", "second", "third"]],
        ]))

        let result = try document.apply(batch(2, [
            ["op": "replaceChildren", "parentId": "list", "children": ["third", "first"]],
        ]))
        XCTAssertEqual(result.affectedNodeIds, ["list"])
        XCTAssertFalse(result.requiresFullRender)
        let rows = try XCTUnwrap((document.node("list")?["children"] as? [[String: Any]])?.compactMap { $0["id"] as? String })
        XCTAssertEqual(rows, ["third", "first"])
        XCTAssertNil(document.node("second"))

        XCTAssertThrowsError(try document.apply(batch(3, [
            ["op": "replaceChildren", "parentId": "list", "children": ["first", "first"]],
        ]))) { error in
            XCTAssertEqual((error as? CraftNativeMutationFailure)?.code, "DUPLICATE_CHILD")
            XCTAssertEqual(document.revision, 2)
            XCTAssertEqual(document.parentId(of: "third"), "list")
        }
    }

    func testEveryContainerTheRendererDrawsTakesChildrenAndALeafDoesNot() throws {
        for type in CraftNativeMutationDocument.containerTypes.sorted() + ["svg", "pressable"] {
            let document = CraftNativeMutationDocument()
            XCTAssertNoThrow(try document.apply(batch(1, [
                ["op": "createNode", "id": "root", "root": true, "node": ["type": "View"]],
                ["op": "createNode", "id": "container", "node": ["type": type]],
                ["op": "createNode", "id": "child", "node": ["type": "View"]],
                ["op": "insertChild", "parentId": "root", "childId": "container", "index": 0],
                ["op": "insertChild", "parentId": "container", "childId": "child", "index": 0],
            ])), type)
            XCTAssertEqual(document.parentId(of: "child"), "container", type)
        }
        for type in ["Text", "Image", "Icon", "TextInput", "Button"] {
            let document = CraftNativeMutationDocument()
            XCTAssertThrowsError(try document.apply(batch(1, [
                ["op": "createNode", "id": "root", "root": true, "node": ["type": "View"]],
                ["op": "createNode", "id": "leaf", "node": ["type": type]],
                ["op": "createNode", "id": "child", "node": ["type": "View"]],
                ["op": "insertChild", "parentId": "root", "childId": "leaf", "index": 0],
                ["op": "insertChild", "parentId": "leaf", "childId": "child", "index": 0],
            ]))) { error in
                XCTAssertEqual((error as? CraftNativeMutationFailure)?.code, "INVALID_PARENT", type)
            }
        }
    }

    func testMapOverlayMutationStaysAddressableToItsMap() throws {
        let document = CraftNativeMutationDocument()
        XCTAssertNoThrow(try document.apply(batch(1, [
            ["op": "createNode", "id": "root", "root": true, "node": ["type": "View"]],
            ["op": "createNode", "id": "map", "node": ["type": "Map"]],
            ["op": "createNode", "id": "route", "node": [
                "type": "MapPolyline", "props": ["geometry": [47.0, 11.0, 47.1, 11.2]],
            ]],
            ["op": "insertChild", "parentId": "root", "childId": "map", "index": 0],
            ["op": "insertChild", "parentId": "map", "childId": "route", "index": 0],
        ])))
        XCTAssertEqual(document.parentId(of: "route"), "map")

        let update = try document.apply(batch(2, [
            ["op": "updateNode", "id": "route", "patch": [
                "props": ["geometry": [47.0, 11.0, 47.2, 11.4]],
            ]],
        ]))
        XCTAssertEqual(update.updatedNodeIds, ["route"])
        XCTAssertEqual(update.affectedNodeIds, ["route"])
        XCTAssertFalse(update.requiresFullRender)
    }

    func testMapMarkerPhotoCropsUpdatesAndFallsBackWithoutReplacingAnnotation() throws {
        let address = "https://marker-photo.invalid/\(UUID().uuidString).png"
        let file = CraftNativeMedia.file(for: address)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file) }
        try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }.pngData()).write(to: file)
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        func render(_ url: String, _ size: Double, _ shape: String, sizeKey: String = "imageSize", shapeKey: String = "imageShape") {
            controller.render(["type": "Map", "props": ["key": "photos"], "style": ["width": 320, "height": 320],
                "children": [["type": "MapMarker", "props": ["id": "runner", "title": "Ada", "geometry": [37.7, -119.5],
                    "image": url, sizeKey: size, shapeKey: shape], "events": ["onPress": "runner-tap"]]]])
        }
        render(address, 30, "circle")
        let map = try XCTUnwrap(find(MKMapView.self, key: "photos", below: controller.view))
        let annotation = try XCTUnwrap(map.annotations.first)
        func photo(_ expectedSize: CGFloat) throws -> UIImage {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if let image = map.delegate?.mapView?(map, viewFor: annotation)?.image, image.size.width == expectedSize { return image }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            throw NSError(domain: "Marker photo did not load", code: 1)
        }
        func alpha(_ image: UIImage, x: Int, y: Int) throws -> UInt8 {
            let cg = try XCTUnwrap(image.cgImage)
            var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: cg.width, height: cg.height,
                    bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            }
            return pixels[(y * cg.width + x) * 4 + 3]
        }
        let circle = try photo(30)
        XCTAssertEqual(try alpha(circle, x: 0, y: 0), 0)
        XCTAssertEqual(try alpha(circle, x: circle.cgImage!.width / 2, y: circle.cgImage!.height / 2), 255)
        render(address, 500, "square")
        let square = try photo(96)
        XCTAssertEqual(try alpha(square, x: 0, y: 0), 255)
        render(address, 40, "square", sizeKey: "imagesize", shapeKey: "imageshape")
        XCTAssertEqual(try alpha(photo(40), x: 0, y: 0), 255)
        render(address, 42, "square", sizeKey: "image-size", shapeKey: "image-shape")
        XCTAssertEqual(try alpha(photo(42), x: 0, y: 0), 255)
        XCTAssertTrue(map.annotations.first === annotation)
        controller.evaluateScript("globalThis.__photoTap = ''; globalThis.__stxNativeCallback = function(json) { const m = JSON.parse(json); if (m.type === 'EVENT') globalThis.__photoTap = m.payload.handlerName + ':' + m.payload.nativeEvent.id; };")
        map.delegate?.mapView?(map, didSelect: annotation)
        let deadline = Date().addingTimeInterval(2)
        while controller.evaluateScript("globalThis.__photoTap")?.toString() != "runner-tap:runner", Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(controller.evaluateScript("globalThis.__photoTap")?.toString(), "runner-tap:runner")
        render("http://marker-photo.invalid/avatar.png", 30, "circle")
        XCTAssertEqual(map.delegate?.mapView?(map, viewFor: annotation)?.image?.size.width, 28)
        render(address, 40, "circle")
        render("file:///private/avatar.png", 30, "circle")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(map.delegate?.mapView?(map, viewFor: annotation)?.image?.size.width, 28, "late photo replaced fallback")
    }

    func testMapExplorationCameraAndDirectionMarker() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = try hostWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        controller.render([
            "type": "Map", "props": ["key": "explorer", "showsCompass": true, "showsScale": true, "cameraPitch": 30, "cameraHeading": 90,
                "region": ["center": ["latitude": 37.7, "longitude": -119.5], "span": ["latitudeDelta": 0.01, "longitudeDelta": 0.01]]],
            "style": ["width": 320, "height": 320],
            "children": [["type": "MapMarker", "props": ["id": "direction", "geometry": [37.7, -119.5], "bearing": 180]]],
        ])
        controller.view.layoutIfNeeded()
        let map = try XCTUnwrap(find(MKMapView.self, key: "explorer", below: controller.view))
        XCTAssertTrue(map.showsCompass)
        XCTAssertTrue(map.showsScale)
        XCTAssertEqual(map.camera.heading, 90, accuracy: 1)
        // MapKit can cap larger pitches at this altitude. Thirty degrees is
        // within its supported range and still catches a camera applied before layout.
        XCTAssertEqual(map.camera.pitch, 30, accuracy: 1)
        let annotation = try XCTUnwrap(map.annotations.first)
        let marker = try XCTUnwrap(map.delegate?.mapView?(map, viewFor: annotation))
        let image = try XCTUnwrap(marker.image)
        XCTAssertEqual(image.renderingMode, .alwaysOriginal, "MapKit must preserve the arrow's contrasting palette")
        XCTAssertLessThanOrEqual(image.size.width, 24, "Direction signs must leave the route visible in compact maps")
        XCTAssertEqual(marker.accessibilityIdentifier, "direction")
        XCTAssertEqual(marker.transform.b, 1, accuracy: 0.02)
    }

    /// A pin's press handler arrives after the pin itself (stx sends the
    /// handler id in a later `updateNode`, as it does for a pin in a `:for`).
    /// Tapping the pin must still reach the screen: Explore's trail card
    /// never opened because it did not.
    func testAPinsPressHandlerPatchedInLaterStillReachesTheScreen() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = try hostWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        controller.render([
            "id": "map-node", "type": "Map", "props": ["key": "pins", "region": ["center": ["latitude": 37.7, "longitude": -119.5], "span": ["latitudeDelta": 0.05, "longitudeDelta": 0.05]]],
            "style": ["width": 320, "height": 320],
            "children": [["id": "pin-node", "type": "MapMarker", "props": ["id": "trail-21", "geometry": [37.7, -119.5], "title": "Craggy Gardens"]]],
        ])
        controller.view.layoutIfNeeded()
        _ = try controller.applyMutation(batch(1, [
            ["op": "updateNode", "id": "pin-node", "patch": ["events": ["onPress": "h31"]]],
        ]))
        controller.view.layoutIfNeeded()
        controller.evaluateScript("globalThis.__pinPress = ''; globalThis.__stxNativeCallback = function(json) { const message = JSON.parse(json); if (message.type === 'EVENT') globalThis.__pinPress = message.payload.handlerName + ':' + message.payload.nativeEvent.id; };")
        let map = try XCTUnwrap(find(MKMapView.self, key: "pins", below: controller.view))
        // A map with no handler of its own still pans, zooms and takes taps
        // on its pins: it was switched off, as a container without one is.
        XCTAssertTrue(map.isUserInteractionEnabled, "a map owns its touches")
        let annotation = try XCTUnwrap(map.annotations.first)
        let pin = try XCTUnwrap(map.delegate?.mapView?(map, viewFor: annotation))
        XCTAssertEqual(pin.zPriority, .max, "a trail's pin sits above the user's own location dot")
        XCTAssertTrue(pin.accessibilityTraits.contains(.button))
        // Activated, as VoiceOver does, it presses like a tap.
        XCTAssertTrue(pin.accessibilityActivate())
        let activated = Date().addingTimeInterval(2)
        while controller.evaluateScript("globalThis.__pinPress")?.toString() != "h31:trail-21", Date() < activated {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(controller.evaluateScript("globalThis.__pinPress")?.toString(), "h31:trail-21")
        controller.evaluateScript("globalThis.__pinPress = ''")
        map.delegate?.mapView?(map, didSelect: annotation)
        let deadline = Date().addingTimeInterval(2)
        while controller.evaluateScript("globalThis.__pinPress")?.toString() != "h31:trail-21", Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(controller.evaluateScript("globalThis.__pinPress")?.toString(), "h31:trail-21")
    }

    /// A wheel picker is not a UIControl either, and was switched off the
    /// same way: it could not be spun.
    func testAWheelPickerTakesTouchesWithoutAPressHandler() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(["type": "Picker", "props": ["key": "wheel", "items": [["label": "One", "value": 1], ["label": "Two", "value": 2]], "selectedValue": 1], "style": ["width": 320, "height": 200]])
        controller.view.layoutIfNeeded()
        let picker = try XCTUnwrap(find(UIPickerView.self, key: "wheel", below: controller.view))
        XCTAssertTrue(picker.isUserInteractionEnabled)
    }

    func testMapDirectionSignsKeepALightBackdropAndTheAuthoredColor() throws {
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            let controller = CraftNativeScreenController(config: CraftConfig())
            controller.overrideUserInterfaceStyle = appearance
            controller.loadViewIfNeeded()
            controller.render([
                "type": "Map", "props": ["key": "contrast-map"],
                "style": ["width": 320, "height": 320],
                "children": [["type": "MapMarker", "props": ["id": "direction", "geometry": [37.7, -119.5], "bearing": 90, "pinColor": "#365b2d"]]],
            ])
            let map = try XCTUnwrap(find(MKMapView.self, key: "contrast-map", below: controller.view))
            let annotation = try XCTUnwrap(map.annotations.first)
            let marker = try XCTUnwrap(map.delegate?.mapView?(map, viewFor: annotation))
            let image = try XCTUnwrap(marker.image)
            let raster = UIGraphicsImageRenderer(size: image.size).image { _ in image.draw(at: .zero) }
            let cgImage = try XCTUnwrap(raster.cgImage)
            var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: cgImage.width, height: cgImage.height,
                    bitsPerComponent: 8, bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            }
            var opaque = 0
            var light = 0
            var authored = 0
            for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset + 3] > 240 {
                opaque += 1
                let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
                if red > 235 && green > 235 && blue > 235 { light += 1 }
                if abs(red - 54) < 12 && abs(green - 91) < 12 && abs(blue - 45) < 12 { authored += 1 }
            }
            XCTAssertGreaterThan(opaque, 50)
            XCTAssertGreaterThan(light, opaque / 3, "direction signs need an opaque light backdrop over the basemap")
            XCTAssertGreaterThan(authored, 10, "the native direction sign ignored its authored pinColor")
        }
    }

    func testMapPreservesAuthoredPolylineOrderAcrossUpdatesAndMoves() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = try hostWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        func document(_ casingWidth: Double, reversed: Bool = false) -> [String: Any] {
            let casing: [String: Any] = ["type": "MapPolyline", "props": ["id": "casing", "geometry": [37.7, -119.5, 37.71, -119.51], "strokeColor": "#365b2d", "strokeWidth": casingWidth]]
            let route: [String: Any] = ["type": "MapPolyline", "props": ["id": "route", "geometry": [37.7, -119.5, 37.71, -119.51], "strokeColor": "#91e86b", "strokeWidth": 5]]
            return ["type": "Map", "props": ["key": "ordered-map"],
                    "style": ["width": 320, "height": 320],
                    "children": reversed ? [route, casing] : [casing, route]]
        }
        controller.render(document(9))
        controller.view.layoutIfNeeded()
        let map = try XCTUnwrap(find(MKMapView.self, key: "ordered-map", below: controller.view))
        func widths() throws -> [CGFloat] {
            try map.overlays.compactMap { $0 as? MKPolyline }.map { line in
                let renderer = try XCTUnwrap(map.delegate?.mapView?(map, rendererFor: line) as? MKPolylineRenderer)
                return renderer.lineWidth
            }
        }
        XCTAssertEqual(try widths(), [9, 5], "the bright route draws above its wider casing")
        let foreground = try XCTUnwrap(map.overlays.compactMap { $0 as? MKPolyline }.last)

        // Replacing a lower overlay must not move it above an unchanged line.
        controller.render(document(11))
        controller.view.layoutIfNeeded()
        XCTAssertTrue(map === find(MKMapView.self, key: "ordered-map", below: controller.view))
        XCTAssertEqual(try widths(), [11, 5])
        XCTAssertTrue(map.overlays.compactMap { $0 as? MKPolyline }.last === foreground)

        // Child moves are draw-order changes even when geometry is unchanged.
        controller.render(document(11, reversed: true))
        controller.view.layoutIfNeeded()
        XCTAssertEqual(try widths(), [5, 11])
        controller.render(document(11))
        controller.view.layoutIfNeeded()
        XCTAssertEqual(try widths(), [11, 5])
    }

    func testMapUpdatesNativePinColorAndTiltGestureWithoutReplacingTheMarker() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = try hostWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        func document(_ color: String, _ pitch: Bool) -> [String: Any] {
            ["type": "Map", "props": ["key": "colored-map", "pitchEnabled": pitch],
             "style": ["width": 320, "height": 320],
             "children": [["type": "MapMarker", "props": ["id": "start", "geometry": [37.7, -119.5], "pinColor": color]]]]
        }
        controller.render(document("#24724b", false))
        controller.view.layoutIfNeeded()
        let map = try XCTUnwrap(find(MKMapView.self, key: "colored-map", below: controller.view))
        let annotation = try XCTUnwrap(map.annotations.first)
        let marker = try XCTUnwrap(map.delegate?.mapView?(map, viewFor: annotation))
        XCTAssertFalse(map.isPitchEnabled)
        XCTAssertEqual(marker.tintColor, UIColor(red: 36 / 255, green: 114 / 255, blue: 75 / 255, alpha: 1))
        XCTAssertEqual(marker.image?.renderingMode, .alwaysOriginal)
        controller.render(document("#2878c8", true))
        controller.view.layoutIfNeeded()
        XCTAssertTrue(map.isPitchEnabled)
        XCTAssertTrue(map.annotations.first === annotation)
        let updated = try XCTUnwrap(map.delegate?.mapView?(map, viewFor: annotation))
        XCTAssertEqual(updated.tintColor, UIColor(red: 40 / 255, green: 120 / 255, blue: 200 / 255, alpha: 1))
    }

    func testMapUsesNativeTopographicTilesWithAttribution() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render([
            "type": "Map", "props": ["key": "topo-map", "edgePadding": ["bottom": 160], "tileOverlay": ["urlTemplate": "https://example.org/tiles/{z}/{y}/{x}.png", "attribution": "Test map data"]],
            "style": ["width": 320, "height": 480],
            "children": [["type": "MapPolyline", "props": ["geometry": [37.7, -119.5, 37.72, -119.49]]]],
        ])
        let map = try XCTUnwrap(find(MKMapView.self, key: "topo-map", below: controller.view))
        let tiles = try XCTUnwrap(map.overlays.first as? MKTileOverlay)
        XCTAssertTrue(tiles.canReplaceMapContent)
        XCTAssertTrue(map.delegate?.mapView?(map, rendererFor: tiles) is MKTileOverlayRenderer)
        XCTAssertTrue(map.overlays.last is MKPolyline, "The route must remain above the basemap")
        controller.view.layoutIfNeeded()
        map.layoutIfNeeded()
        let credit = try XCTUnwrap(map.subviews.compactMap { $0 as? UILabel }.first { $0.text == "Test map data" && !$0.isHidden })
        XCTAssertLessThanOrEqual(credit.frame.maxY, map.bounds.height - 160, "The floating profile must not cover map attribution")
    }

    func testMapAttributionFollowsLightAndDarkTraits() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = try hostWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        controller.render([
            "type": "Map", "props": ["key": "trait-map", "tileOverlay": ["urlTemplate": "https://example.org/tiles/{z}/{y}/{x}.png", "attribution": "Trait map data"]],
            "style": ["width": 320, "height": 480],
            "children": [["type": "MapMarker", "props": ["id": "trait-marker", "geometry": [37.7, -119.5], "pinColor": "label"]]],
        ])
        controller.view.layoutIfNeeded()
        let map = try XCTUnwrap(find(MKMapView.self, key: "trait-map", below: controller.view))
        let credit = try XCTUnwrap(map.subviews.compactMap { $0 as? UILabel }.first { $0.text == "Trait map data" && !$0.isHidden })
        let annotation = try XCTUnwrap(map.annotations.first)
        let marker = try XCTUnwrap(map.delegate?.mapView?(map, viewFor: annotation))
        let lightTrait = UITraitCollection(userInterfaceStyle: .light)
        let darkTrait = UITraitCollection(userInterfaceStyle: .dark)
        let lightText = try XCTUnwrap(credit.textColor).resolvedColor(with: lightTrait)
        let darkText = try XCTUnwrap(credit.textColor).resolvedColor(with: darkTrait)
        let lightBackground = try XCTUnwrap(credit.backgroundColor).resolvedColor(with: lightTrait)
        let darkBackground = try XCTUnwrap(credit.backgroundColor).resolvedColor(with: darkTrait)
        XCTAssertNotEqual(lightText, darkText)
        XCTAssertNotEqual(lightBackground, darkBackground)
        map.overrideUserInterfaceStyle = .dark
        let darkMarker = try XCTUnwrap(map.delegate?.mapView?(map, viewFor: annotation))
        XCTAssertEqual(darkMarker.tintColor?.resolvedColor(with: darkTrait), UIColor.label.resolvedColor(with: darkTrait))
        XCTAssertNotNil(darkMarker.image, "retained map markers must remain configured after a changed color trait")
    }

    func testMapReservesRoomForFloatingControls() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = try hostWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        controller.render([
            "type": "Map", "props": ["key": "padded-map", "fitToBounds": true,
                "edgePadding": ["top": 40, "bottom": 160, "left": 32, "right": 32]],
            "style": ["width": 320, "height": 480],
            "children": [["type": "MapPolyline", "props": ["geometry": [37.7, -119.5, 37.72, -119.49]]]],
        ])
        controller.view.layoutIfNeeded()
        let map = try XCTUnwrap(find(MKMapView.self, key: "padded-map", below: controller.view))
        for coordinate in [CLLocationCoordinate2D(latitude: 37.7, longitude: -119.5), CLLocationCoordinate2D(latitude: 37.72, longitude: -119.49)] {
            let point = map.convert(coordinate, toPointTo: map)
            XCTAssertGreaterThanOrEqual(point.x, 30)
            XCTAssertLessThanOrEqual(point.x, map.bounds.width - 30)
            XCTAssertGreaterThanOrEqual(point.y, 38)
            XCTAssertLessThanOrEqual(point.y, map.bounds.height - 158)
        }
    }

    func testMapFitRetriesAfterItsViewportIsMeasured() {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render([
            "type": "View",
            "children": [[
                "type": "Map",
                "props": ["key": "map", "fitToBounds": true],
                "style": ["width": 320, "height": 240],
                "children": [[
                    "type": "MapPolyline",
                    "props": ["geometry": [47.0, 11.0, 47.1, 11.2]],
                ]],
            ]],
        ])
        controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        let map = find(MKMapView.self, key: "map", below: controller.view)

        XCTAssertTrue(
            map?.visibleMapRect.contains(MKMapPoint(CLLocationCoordinate2D(latitude: 47.0, longitude: 11.0))) == true,
            "fitToBounds did not retry after the map received a real viewport"
        )
    }

    func testMapIgnoresBooleanNumericCoordinates() {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render([
            "type": "View",
            "children": [[
                "type": "Map",
                "props": [
                    "key": "boolean-map",
                    "region": [
                        "center": ["latitude": true, "longitude": 11.0],
                        "span": ["latitudeDelta": 1.0, "longitudeDelta": 1.0],
                    ],
                ],
                "style": ["width": 320, "height": 240],
                "children": [[
                    "type": "MapPolyline",
                    "props": ["geometry": [true, 11.0, 47.1, 11.2]],
                ]],
            ]],
        ])
        let map = find(MKMapView.self, key: "boolean-map", below: controller.view)
        XCTAssertEqual(map?.overlays.count, 0, "Boolean map coordinates were treated as numeric")
    }

    func testSvgIgnoresBooleanNumericGeometry() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.render([
            "type": "View",
            "children": [[
                "type": "Svg",
                "props": ["testID": "boolean-svg", "viewBox": [true, 0, 24, 24]],
                "style": ["width": 40],
            ]],
        ])
        controller.view.layoutIfNeeded()
        let svg = try XCTUnwrap(find(UIView.self, key: "boolean-svg", below: controller.view))
        XCTAssertLessThanOrEqual(svg.frame.height, 1, "Boolean SVG viewBox values were treated as numeric")
    }

    func testSvgGroupsAndTextDrawIntoTheNativeView() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.render([
            "type": "Svg",
            "props": ["key": "svg-text", "viewBox": [0, 0, 24, 24]],
            "style": ["width": 120, "height": 80],
            "children": [[
                "type": "G",
                "props": ["fill": "#2563eb"],
                "children": [[
                    "type": "SvgText",
                    "props": ["x": 12, "y": 14, "textAnchor": "middle", "fontSize": 8],
                    "children": ["STX"],
                ]],
            ]],
        ])
        controller.view.layoutIfNeeded()
        let svg = try XCTUnwrap(find(UIView.self, key: "svg-text", below: controller.view))
        let image = UIGraphicsImageRenderer(size: svg.bounds.size).image { context in
            svg.layer.render(in: context.cgContext)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: cgImage.width, height: cgImage.height,
                bitsPerComponent: 8, bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        let bluePixels = stride(from: 0, to: pixels.count, by: 4).filter { offset in
            pixels[offset + 3] > 20 && pixels[offset + 2] > pixels[offset] + 20
        }
        XCTAssertGreaterThan(bluePixels.count, 5, "SVG group/text did not draw its inherited fill")
    }

    func testADrawingRevealedAfterTheFirstPaintTakesItsShapesInPlace() throws {
        // A chart behind an `:if` (stx): the drawing and its shapes arrive in
        // one batch after the first paint. The shapes were refused as
        // INVALID_PARENT and the screen drawn again from scratch.
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(["id": "root-node", "type": "View", "children": [
            ["id": "label-node", "type": "Text", "props": ["testID": "label"], "children": ["Heart rate"]],
        ]])
        let label = try XCTUnwrap(find(UILabel.self, key: "label", below: controller.view))

        let reveal = try controller.applyMutation(batch(1, [
            ["op": "createNode", "id": "chart-node", "node": [
                "type": "Svg", "props": ["testID": "chart", "viewBox": [0, 0, 10, 10]], "style": ["width": 40, "height": 40],
            ]],
            ["op": "createNode", "id": "line-node", "node": [
                "type": "Path", "props": ["d": "M0 0L10 10", "geometry": [["M", 0, 0], ["L", 10, 10]], "stroke": "#ff0000"],
            ]],
            ["op": "insertChild", "parentId": "chart-node", "childId": "line-node", "index": 0],
            ["op": "insertChild", "parentId": "root-node", "childId": "chart-node", "index": 1],
        ]))
        XCTAssertFalse(reveal.requiresFullRender)
        XCTAssertEqual(reveal.affectedNodeIds, ["chart-node", "root-node"])
        let chart = try XCTUnwrap(find(UIView.self, key: "chart", below: controller.view))
        XCTAssertEqual(String(describing: type(of: chart)), "CraftNativeSvgView")
        XCTAssertTrue(label === find(UILabel.self, key: "label", below: controller.view))

        // A shape's new outline redraws its drawing, which stays the same view.
        _ = try controller.applyMutation(batch(2, [
            ["op": "updateNode", "id": "line-node", "patch": ["props": ["d": "M0 10L10 0", "geometry": [["M", 0, 10], ["L", 10, 0]]]]],
        ]))
        XCTAssertTrue(chart === find(UIView.self, key: "chart", below: controller.view))
    }

    func testMutationValidationIsAtomicAndDeterministic() throws {
        let document = CraftNativeMutationDocument()
        XCTAssertThrowsError(try document.apply(batch(1, [
            ["op": "createNode", "id": "root", "root": true, "node": ["type": "View"]],
            ["op": "removeNode", "id": "missing"],
        ]))) { error in
            XCTAssertEqual(error as? CraftNativeMutationFailure, CraftNativeMutationFailure(
                "UNKNOWN_NODE", "node missing does not exist", operationIndex: 1
            ))
        }
        XCTAssertEqual(document.revision, 0)

        _ = try document.apply(batch(1, [
            ["op": "createNode", "id": "root", "root": true, "node": ["type": "View"]],
        ]))
        XCTAssertThrowsError(try document.apply(batch(2, [
            ["op": "updateNode", "id": "root", "patch": ["type": "Text"]],
        ]))) { error in
            XCTAssertEqual(error as? CraftNativeMutationFailure, CraftNativeMutationFailure(
                "INVALID_PATCH", "unsupported patch field type", operationIndex: 0
            ))
        }
        XCTAssertThrowsError(try document.apply(batch(2, [
            ["op": "removeNode", "id": "root"],
        ], version: 2, baseRevision: 1))) { error in
            XCTAssertEqual((error as? CraftNativeMutationFailure)?.code, "UNSUPPORTED_VERSION")
        }
        XCTAssertEqual(document.revision, 1)
    }

    func testMutationRejectsInvalidTreeShapesWithoutAdvancingRevision() throws {
        let document = CraftNativeMutationDocument()
        _ = try document.apply(batch(1, [
            ["op": "createNode", "id": "root", "root": true, "node": ["type": "View"]],
        ]))

        XCTAssertThrowsError(try document.apply(batch(2, [
            ["op": "createNode", "id": "orphan", "node": ["type": "Text"]],
        ]))) { error in
            XCTAssertEqual(error as? CraftNativeMutationFailure, CraftNativeMutationFailure(
                "INVALID_TREE", "all nodes must be reachable from the root"
            ))
        }
        XCTAssertEqual(document.revision, 1)
        XCTAssertNil(document.node("orphan"))

        XCTAssertThrowsError(try document.apply(batch(2, [
            ["op": "createNode", "id": "parent", "node": ["type": "View"]],
            ["op": "insertChild", "parentId": "parent", "childId": "root", "index": 0],
        ]))) { error in
            XCTAssertEqual(error as? CraftNativeMutationFailure, CraftNativeMutationFailure(
                "INVALID_TREE", "root node must not have a parent"
            ))
        }
        XCTAssertEqual(document.revision, 1)
        XCTAssertNil(document.node("parent"))

        XCTAssertThrowsError(try document.apply(batch(2, [
            ["op": "createNode", "id": "child", "node": ["type": "Text"]],
            ["op": "insertChild", "parentId": "root", "childId": "child", "index": 2],
        ]))) { error in
            XCTAssertEqual((error as? CraftNativeMutationFailure)?.code, "INVALID_INDEX")
            XCTAssertEqual((error as? CraftNativeMutationFailure)?.operationIndex, 1)
        }
        XCTAssertEqual(document.revision, 1)
        XCTAssertNil(document.node("child"))

        XCTAssertThrowsError(try document.apply(batch(2, [
            ["op": "removeNode", "id": "root"],
        ], baseRevision: 0))) { error in
            XCTAssertEqual((error as? CraftNativeMutationFailure)?.code, "REVISION_MISMATCH")
            XCTAssertNil((error as? CraftNativeMutationFailure)?.operationIndex)
        }
        XCTAssertEqual(document.revision, 1)
    }

    func testFlatListRecyclesTenThousandKeyedRowsAndKeepsItsViewport() {
        let list = CraftNativeFlatList()
        list.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        let rows: [[String: Any]] = (0..<10_000).map { index in
            ["id": "row-\(index)", "type": "Text", "children": ["Row \(index)"]]
        }
        var rendered: [String: UIView] = [:]
        var renderCount = 0
        let render: CraftNativeFlatList.RenderItem = { node, identity, previous in
            renderCount += 1
            if let previous = previous { return previous }
            let label = UILabel()
            label.text = (node["children"] as? [String])?.first
            rendered[identity] = label
            return label
        }

        list.apply(
            nodes: rows,
            horizontal: false,
            columns: 1,
            inverted: false,
            endReachedThreshold: 0.1,
            renderItem: render,
            recycleItem: { _ in },
            removeItem: { _ in },
            endReached: nil
        )
        list.layoutIfNeeded()
        XCTAssertEqual(list.numberOfItems(inSection: 0), 10_000)
        XCTAssertGreaterThan(renderCount, 0)
        XCTAssertLessThan(renderCount, 100)

        list.contentOffset = CGPoint(x: 0, y: 240)
        list.layoutIfNeeded()
        let retainedAnchor = list.visibleItemIdentities.first
        let moved = [rows[1], rows[0]] + Array(rows.dropFirst(2))
        list.apply(
            nodes: moved,
            horizontal: false,
            columns: 1,
            inverted: false,
            endReachedThreshold: 0.1,
            renderItem: render,
            recycleItem: { _ in },
            removeItem: { _ in },
            endReached: nil
        )
        list.layoutIfNeeded()
        XCTAssertEqual(list.numberOfItems(inSection: 0), 10_000)
        XCTAssertNotNil(retainedAnchor)
        XCTAssertTrue(retainedAnchor.map(list.visibleItemIdentities.contains) ?? false)
        XCTAssertLessThan(rendered.count, 100)
    }

    func testFlatListDoesNotPrepareDuplicateRowsOrReapplyUnchangedSnapshots() {
        let list = CraftNativeFlatList()
        list.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        XCTAssertFalse(list.isPrefetchingEnabled, "a keyed row owns one native view; speculative cells must not take it")
        let rows: [[String: Any]] = (0..<200).map { ["id": "row-\($0)", "type": "Text", "children": ["Row \($0)"]] }
        var renders = 0
        let render: CraftNativeFlatList.RenderItem = { node, _, previous in
            renders += 1
            let label = (previous as? UILabel) ?? UILabel()
            label.text = (node["children"] as? [String])?.first
            return label
        }
        func apply() {
            list.apply(nodes: rows, horizontal: false, columns: 1, inverted: false, endReachedThreshold: 0.1, renderItem: render, recycleItem: { _ in }, removeItem: { _ in }, endReached: nil)
            list.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        apply()
        list.contentOffset = CGPoint(x: 0, y: 180)
        list.layoutIfNeeded()
        let before = renders
        let offset = list.contentOffset
        for _ in 0..<5 { apply() }
        XCTAssertEqual(renders, before, "an unrelated screen update must not rebuild cells or interrupt scrolling")
        XCTAssertEqual(list.contentOffset, offset)
        list.discardAll()
        list.apply(nodes: [], horizontal: false, columns: 1, inverted: false, endReachedThreshold: 0.1, renderItem: render, recycleItem: { _ in }, removeItem: { _ in }, endReached: nil)
        list.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(list.numberOfItems(inSection: 0), 0, "a recycled list rebound empty must clear its old UIKit snapshot")
    }

    /// A screen keeps one view per row, so a second cell UIKit prepares for a
    /// row on screen (a prefetch, an update) takes that view from the cell
    /// showing it. That cell stayed on screen at the row's height with nothing
    /// in it (HQ's Discover: a blank card where the search and chips were, a
    /// gap between two people).
    func testFlatListRowsOnScreenTakeTheirViewsBackFromASecondCell() throws {
        let list = CraftNativeFlatList()
        list.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        let rows: [[String: Any]] = (0..<6).map { ["id": "row-\($0)", "type": "Text", "children": ["Row \($0)"]] }
        var views: [String: UIView] = [:]
        let render: CraftNativeFlatList.RenderItem = { node, identity, _ in
            if let view = views[identity] { return view }
            let label = UILabel()
            label.text = (node["children"] as? [String])?.first
            views[identity] = label
            return label
        }
        list.apply(nodes: rows, horizontal: false, columns: 1, inverted: false, endReachedThreshold: 0.1, renderItem: render, recycleItem: { _ in }, removeItem: { _ in }, endReached: nil)
        list.layoutIfNeeded()
        XCTAssertTrue(list.visibleRowsShowTheirViews)
        let shown = try XCTUnwrap(list.cellForItem(at: IndexPath(item: 0, section: 0)))
        XCTAssertTrue(try XCTUnwrap(views["row-0"]).isDescendant(of: shown))

        let second = try XCTUnwrap(list.dataSource?.collectionView(list, cellForItemAt: IndexPath(item: 0, section: 0)))
        XCTAssertFalse(second === shown)
        XCTAssertTrue(try XCTUnwrap(views["row-0"]).isDescendant(of: second), "the row's one view went to the second cell")
        XCTAssertFalse(list.visibleRowsShowTheirViews, "the cell on screen lost it")

        list.setNeedsLayout()
        list.layoutIfNeeded()
        XCTAssertTrue(list.visibleRowsShowTheirViews)
        XCTAssertTrue(try XCTUnwrap(views["row-0"]).isDescendant(of: shown), "the cell on screen has its row back")
    }

    /// The accessory beside the tab pill (HQ's Messages button) stays drawn
    /// while one screen hands over to the next: taken off when a screen went
    /// away, the pill stretched across the bar and back while the next screen
    /// (Messages opened from it, Me opened for the first time) started up.
    func testTheTabAccessoryStaysWhileTheNextScreenStartsAndGoesWhenItIsNotWanted() throws {
        let chrome = CraftChrome.shared
        let accessory = #"{"path":"/m/messages","title":"Messages","symbol":"bubble.left"}"#
        func settle(until done: () -> Bool = { false }) {
            let deadline = Date().addingTimeInterval(1)
            while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        // The fixture's script draws its screen as it loads; that lands before
        // each step, so a step never races a draw (the order once depended on
        // how warm the shared virtual machine was).
        func screen() -> CraftNativeScreenController {
            let controller = CraftNativeScreenController(config: CraftConfig())
            controller.loadViewIfNeeded()
            settle()
            return controller
        }
        func declare(_ controller: CraftNativeScreenController, _ json: String, until done: @escaping () -> Bool) {
            controller.evaluateScript("craftNativePostMessage(JSON.stringify({ type: 'NAVIGATION_SET_OPTIONS', payload: { tabAccessory: \(json) } }))")
            settle(until: done)
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let stack = UINavigationController()
        window.rootViewController = stack
        window.makeKeyAndVisible()
        defer { window.isHidden = true; chrome.updateTabAccessory(nil) }

        // Handing over: a screen going away gives its accessory up without
        // taking it off; only one nobody claims comes off.
        let owner = NSObject()
        chrome.updateTabAccessory(["path": "/m/messages", "title": "Messages"], owner: owner)
        chrome.clearUnclaimedTabAccessory()
        XCTAssertEqual(chrome.tabAccessory?.id, "/m/messages", "a claimed accessory stays")
        chrome.releaseTabAccessory(ownedBy: NSObject())
        chrome.clearUnclaimedTabAccessory()
        XCTAssertEqual(chrome.tabAccessory?.id, "/m/messages", "only its owner gives it up")
        chrome.releaseTabAccessory(ownedBy: owner)
        XCTAssertEqual(chrome.tabAccessory?.id, "/m/messages", "kept while the next screen starts")
        chrome.clearUnclaimedTabAccessory()
        XCTAssertNil(chrome.tabAccessory)

        let today = screen()
        stack.setViewControllers([today], animated: false)
        stack.view.layoutIfNeeded()
        declare(today, accessory) { chrome.tabAccessory != nil }
        XCTAssertEqual(chrome.tabAccessory?.id, "/m/messages")

        // The next screen asked for the same as its script started: one
        // accessory all along, through the push.
        let messages = screen()
        declare(messages, accessory) { true }
        XCTAssertEqual(chrome.tabAccessory?.id, "/m/messages", "a screen not on top changes nothing yet")
        stack.pushViewController(messages, animated: false)
        stack.view.layoutIfNeeded()
        settle()
        XCTAssertEqual(chrome.tabAccessory?.id, "/m/messages")

        // A screen that drew without one takes it off.
        let bare = screen()
        stack.pushViewController(bare, animated: false)
        stack.view.layoutIfNeeded()
        settle { chrome.tabAccessory == nil }
        XCTAssertNil(chrome.tabAccessory, "a screen that drew without one wants none")

        // An explicit no takes it off at once.
        let again = screen()
        stack.setViewControllers([again], animated: false)
        stack.view.layoutIfNeeded()
        declare(again, accessory) { chrome.tabAccessory != nil }
        XCTAssertNotNil(chrome.tabAccessory)
        declare(again, "null") { chrome.tabAccessory == nil }
        XCTAssertNil(chrome.tabAccessory)
    }

    func testFlatListForwardsScrollAndMomentumCallbacks() {
        let list = CraftNativeFlatList()
        list.frame = CGRect(x: 0, y: 0, width: 320, height: 160)
        var scrollCount = 0
        var beginDragCount = 0
        var endDragCount = 0
        var momentumBeginCount = 0
        var momentumEndCount = 0
        list.onScrollEvent = { _ in scrollCount += 1 }
        list.onScrollBeginDrag = { _ in beginDragCount += 1 }
        list.onScrollEndDrag = { _ in endDragCount += 1 }
        list.onMomentumScrollBegin = { _ in momentumBeginCount += 1 }
        list.onMomentumScrollEnd = { _ in momentumEndCount += 1 }
        let rows = (0..<20).map { index in
            ["id": "row-\(index)", "type": "Text", "children": ["Row \(index)"]] as [String: Any]
        }
        let render: CraftNativeFlatList.RenderItem = { _, _, previous in previous ?? UILabel() }
        list.apply(
            nodes: rows,
            horizontal: false,
            columns: 1,
            inverted: false,
            endReachedThreshold: 0.1,
            renderItem: render,
            recycleItem: { _ in },
            removeItem: { _ in },
            endReached: nil
        )
        list.layoutIfNeeded()
        list.scrollViewWillBeginDragging(list)
        list.scrollViewDidScroll(list)
        list.scrollViewDidEndDragging(list, willDecelerate: true)
        list.scrollViewWillBeginDecelerating(list)
        list.scrollViewDidEndDecelerating(list)
        XCTAssertEqual(scrollCount, 1)
        XCTAssertEqual(beginDragCount, 1)
        XCTAssertEqual(endDragCount, 1)
        XCTAssertEqual(momentumBeginCount, 1)
        XCTAssertEqual(momentumEndCount, 1)
    }

    /// A row's own side margins inset it in the list, as a column's child is
    /// inset (HQ's Discover results ran to the screen's edges).
    func testFlatListRowsKeepTheirOwnSideMargins() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let row: (String, [String: Any]) -> [String: Any] = { key, style in
            ["id": key, "type": "View", "props": ["key": key], "style": style, "children": [["type": "Text", "children": ["Row"]]]]
        }
        controller.render(document([[
            "type": "FlatList",
            "props": ["key": "list"],
            "style": ["flex": 1],
            "children": [
                row("card", ["marginTop": 12, "marginHorizontal": 16, "padding": 16, "backgroundColor": "#ffffff"]),
                row("first", ["overflow": "hidden", "marginHorizontal": 16, "backgroundColor": "#ffffff", "borderTopLeftRadius": 10, "borderTopRightRadius": 10]),
                row("next", ["overflow": "hidden", "marginHorizontal": 16, "backgroundColor": "#ffffff"]),
            ],
        ]]))
        controller.view.layoutIfNeeded()
        let list = try XCTUnwrap(find(CraftNativeFlatList.self, key: "list", below: controller.view))
        list.layoutIfNeeded()
        for key in ["card", "first", "next"] {
            let view = try XCTUnwrap(find(UIView.self, key: key, below: list), key)
            let frame = view.convert(view.bounds, to: list)
            XCTAssertEqual(frame.minX, 16, accuracy: 0.5, "\(key) left inset")
            XCTAssertEqual(frame.maxX, list.bounds.width - 16, accuracy: 0.5, "\(key) right inset")
        }
        let card = try XCTUnwrap(find(UIView.self, key: "card", below: list))
        XCTAssertEqual(card.convert(card.bounds, to: list).minY, 12, accuracy: 0.5, "the card's top margin")

        // A style update moves the same row in place.
        controller.render(document([[
            "type": "FlatList",
            "props": ["key": "list"],
            "style": ["flex": 1],
            "children": [row("next", ["overflow": "hidden", "marginHorizontal": 24, "backgroundColor": "#ffffff"])],
        ]]))
        // A snapshot applied while the last one finishes lands a turn later.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        controller.view.layoutIfNeeded()
        list.layoutIfNeeded()
        let next = try XCTUnwrap(find(UIView.self, key: "next", below: list))
        XCTAssertEqual(next.convert(next.bounds, to: list).minX, 24, accuracy: 0.5)
        XCTAssertEqual(next.convert(next.bounds, to: list).maxX, list.bounds.width - 24, accuracy: 0.5)
    }

    /// SMIL path keyframes (stx `Animate`: HQ's moving exercise figures)
    /// play between the frames either side of now, at their key times.
    func testSvgKeyframesPlayBetweenTheirKeyTimes() throws {
        let props: [String: Any] = [
            "attributeName": "d", "duration": 2, "repeatCount": "indefinite",
            "frames": [[0, 0, 0, 1, 10, 0], [0, 0, 0, 1, 20, 10], [0, 0, 0, 1, 10, 0]],
            "frameTimes": [0, 0.25, 1],
        ]
        func outline(_ at: CFTimeInterval, _ props: [String: Any] = props) -> [CGFloat]? {
            CraftNativeSvgView.keyframe(props, at: at)?.compactMap { ($0 as? CGFloat) ?? ($0 as? NSNumber).map { CGFloat(truncating: $0) } }
        }
        XCTAssertEqual(outline(0), [0, 0, 0, 1, 10, 0])
        // Half way to the second key time (0.25 of 2 s).
        XCTAssertEqual(outline(0.25), [0, 0, 0, 1, 15, 5])
        XCTAssertEqual(outline(0.5), [0, 0, 0, 1, 20, 10])
        // A repetition later, the same.
        XCTAssertEqual(outline(2.25), [0, 0, 0, 1, 15, 5])
        var once = props
        once["repeatCount"] = 1
        XCTAssertNil(outline(2.25, once), "a finished animation draws the shape's own outline")
        var other = props
        other["attributeName"] = "cx"
        XCTAssertNil(outline(0.25, other))
        // Different commands cannot be blended: the earlier frame holds.
        XCTAssertEqual(CraftNativeSvgView.interpolate([0, 0, 0, 1, 1, 1], [0, 0, 0, 2, 1, 1, 2, 2, 3, 3], 0.5), [0, 0, 0, 1, 1, 1])
        XCTAssertEqual(CraftNativeSvgView.interpolate([0, 0, 0, 3, 2, 2, 4, 4], [0, 2, 2, 3, 4, 4, 6, 6], 0.5), [0, 1, 1, 3, 3, 3, 5, 5])
    }

    /// A shape takes its `Animate` as a child through the mutation protocol,
    /// so an exercise row's keyframes arrive without drawing the screen again.
    func testAShapeTakesItsAnimationAsAChild() throws {
        let document = CraftNativeMutationDocument()
        let result = try document.apply(batch(1, [
            ["op": "createNode", "id": "root", "root": true, "node": ["type": "View"]],
            ["op": "createNode", "id": "art", "node": ["type": "Svg"]],
            ["op": "createNode", "id": "limb", "node": ["type": "Path", "props": ["geometry": [0, 0, 0, 1, 1, 1]]]],
            ["op": "createNode", "id": "move", "node": ["type": "Animate", "props": ["attributeName": "d", "duration": 1, "frames": [[0, 0, 0, 1, 1, 1], [0, 0, 0, 1, 2, 2]]]]],
            ["op": "insertChild", "parentId": "root", "childId": "art", "index": 0],
            ["op": "insertChild", "parentId": "art", "childId": "limb", "index": 0],
            ["op": "insertChild", "parentId": "limb", "childId": "move", "index": 0],
        ]))
        XCTAssertNotNil(result.document)
        XCTAssertEqual(document.parentId(of: "move"), "limb")
    }

    func testAnimatedSvgAsksForFramesOnlyWhileOnScreen() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        let figure: (String, Bool) -> [String: Any] = { key, moving in
            let animate: [String: Any] = ["id": "\(key)-move", "type": "Animate", "props": ["attributeName": "d", "duration": 2.4, "frames": [[0, 0, 0, 1, 10, 0], [0, 0, 0, 1, 20, 10]], "frameTimes": [0, 1]]]
            let limb: [String: Any] = ["id": "\(key)-limb", "type": "Path", "props": ["geometry": [0, 0, 0, 1, 10, 0]], "children": moving ? [animate] : []]
            return ["id": key, "type": "Svg", "props": ["key": key, "viewBox": [0, 0, 128, 128]], "style": ["width": 48, "height": 48], "children": [limb]]
        }
        controller.render(document([figure("moving", true), figure("still", false)]))
        controller.view.layoutIfNeeded()
        let moving = try XCTUnwrap(find(CraftNativeSvgView.self, key: "moving", below: controller.view))
        let still = try XCTUnwrap(find(CraftNativeSvgView.self, key: "still", below: controller.view))
        XCTAssertEqual(moving.isAnimating, !UIAccessibility.isReduceMotionEnabled)
        XCTAssertFalse(still.isAnimating, "a drawing without keyframes asks for no frames")
        if !UIAccessibility.isReduceMotionEnabled { XCTAssertTrue(CraftNativeFrameClock.shared.isRunning) }
        moving.isHidden = true
        XCTAssertFalse(moving.isAnimating)
        moving.isHidden = false
        moving.removeFromSuperview()
        XCTAssertFalse(moving.isAnimating, "out of the window, no frames")
    }

    /// A tab opened for the first time mounts in the window. The bar its
    /// script asks for before it has appeared (HQ's Me: a title, a large
    /// title) is in place from the first frame; once the screen has appeared,
    /// a change to the bar animates as before.
    func testABarAskedForBeforeTheScreenAppearsDoesNotSlideIn() throws {
        let window = try hostWindow()
        let screen = CraftNativeScreenController(config: CraftConfig())
        let stack = UINavigationController(rootViewController: screen)
        stack.setNavigationBarHidden(true, animated: false)
        window.rootViewController = stack
        defer { window.isHidden = true }
        screen.loadViewIfNeeded()
        window.makeKeyAndVisible()
        stack.view.layoutIfNeeded()
        if screen.view.window != nil, !screen.animatesNavigationBarChanges {
            screen.evaluateScript("craftNativePostMessage(JSON.stringify({ type: 'NAVIGATION_SET_OPTIONS', payload: { title: 'Me', largeTitle: true } }))")
            XCTAssertFalse(stack.isNavigationBarHidden, "the bar it asked for")
            XCTAssertTrue(stack.navigationBar.layer.animationKeys()?.isEmpty ?? true, "there, not sliding in")
        }
        screen.viewDidAppear(false)
        XCTAssertTrue(screen.animatesNavigationBarChanges, "after appearing, a change animates")
    }

    func testFlatListScrollIndicatorsAndBounceAxesFollowProps() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([[
            "type": "FlatList",
            "props": [
                "key": "list",
                "horizontal": true,
                "showsVerticalScrollIndicator": false,
                "showsHorizontalScrollIndicator": true,
                "alwaysBounceVertical": true,
                "alwaysBounceHorizontal": false,
            ],
            "children": [["id": "row", "type": "Text", "children": ["Row"]]],
        ]]))

        let list = try XCTUnwrap(find(CraftNativeFlatList.self, key: "list", below: controller.view))
        XCTAssertFalse(list.showsVerticalScrollIndicator)
        XCTAssertTrue(list.showsHorizontalScrollIndicator)
        XCTAssertTrue(list.alwaysBounceVertical)
        XCTAssertFalse(list.alwaysBounceHorizontal)

        controller.render(document([[
            "type": "FlatList",
            "props": ["key": "list"],
            "children": [["id": "row", "type": "Text", "children": ["Row"]]],
        ]]))
        XCTAssertTrue(list.showsVerticalScrollIndicator)
        XCTAssertTrue(list.showsHorizontalScrollIndicator)
        XCTAssertTrue(list.alwaysBounceVertical)
        XCTAssertFalse(list.alwaysBounceHorizontal)
    }

    func testFlatListPagingFollowsProps() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([[
            "type": "FlatList",
            "props": ["key": "list", "pagingEnabled": true],
            "children": [["id": "row", "type": "Text", "children": ["Row"]]],
        ]]))
        let list = try XCTUnwrap(find(CraftNativeFlatList.self, key: "list", below: controller.view))
        XCTAssertTrue(list.isPagingEnabled)

        controller.render(document([[
            "type": "FlatList",
            "props": ["key": "list"],
            "children": [["id": "row", "type": "Text", "children": ["Row"]]],
        ]]))
        XCTAssertFalse(list.isPagingEnabled)
    }

    func testFlatListScrollTargetIsAccepted() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([[
            "type": "FlatList",
            "props": ["key": "list", "scrollTarget": ["id": "row", "animated": false, "key": "first"]],
            "children": [["id": "row", "type": "Text", "props": ["testID": "row"], "children": ["Row"]]],
        ]]))
        let list = try XCTUnwrap(find(CraftNativeFlatList.self, key: "list", below: controller.view))
        list.layoutIfNeeded()
        XCTAssertTrue(list.contentOffset.x.isFinite)
        XCTAssertTrue(list.contentOffset.y.isFinite)
    }

    /// A row as tall as a multi-paragraph reply or a card: far past the 44pt
    /// estimate rows start from.
    private final class TallRow: UIView {
        let height: CGFloat
        init(height: CGFloat) {
            self.height = height
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }
        override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: height) }
        override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: height) }
    }

    private func tallRowList(height: CGFloat = 480) -> (CraftNativeFlatList, UIWindow, ([[String: Any]]) -> Void) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: height))
        let list = CraftNativeFlatList()
        list.frame = window.bounds
        list.contentInsetAdjustmentBehavior = .never
        list.setContentContainerStyle(["paddingBottom": 16])
        window.addSubview(list)
        window.isHidden = false
        var views: [String: UIView] = [:]
        let render: CraftNativeFlatList.RenderItem = { node, identity, _ in
            if let view = views[identity] { return view }
            let props = node["props"] as? [String: Any] ?? [:]
            let view = TallRow(height: CGFloat((props["height"] as? NSNumber)?.doubleValue ?? 44))
            views[identity] = view
            return view
        }
        let apply: ([[String: Any]]) -> Void = { rows in
            list.apply(nodes: rows, horizontal: false, columns: 1, inverted: false, endReachedThreshold: 0.1, renderItem: render, recycleItem: { _ in }, removeItem: { _ in }, endReached: nil)
        }
        return (list, window, apply)
    }

    private func tallRows(_ count: Int, height: Double = 320) -> [[String: Any]] {
        (0..<count).map { ["id": "row-\($0)", "type": "View", "props": ["testID": "row-\($0)", "height": height]] }
    }

    private func settle(_ list: CraftNativeFlatList, seconds: TimeInterval = 0.3) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        list.layoutIfNeeded()
    }

    private func assertAtTrueEnd(_ list: CraftNativeFlatList, lastRow: Int, rowHeight: CGFloat, file: StaticString = #filePath, line: UInt = #line) throws {
        let bottom = max(-list.adjustedContentInset.top, list.contentSize.height + list.adjustedContentInset.bottom - list.bounds.height)
        XCTAssertEqual(list.contentOffset.y, bottom, accuracy: 0.5, "the list stopped short of its end", file: file, line: line)
        let last = try XCTUnwrap(list.layoutAttributesForItem(at: IndexPath(item: lastRow, section: 0)), file: file, line: line)
        XCTAssertEqual(last.frame.height, rowHeight, accuracy: 0.5, "the last row measured itself", file: file, line: line)
        // The last row's bottom sits just above the bottom padding, on screen.
        XCTAssertEqual(last.frame.maxY + list.adjustedContentInset.bottom, list.contentOffset.y + list.bounds.height, accuracy: 0.5, file: file, line: line)
    }

    /// HQ's chat: one render appends tall replies and moves the target to the
    /// new last row. Aimed before the snapshot landed, the list went to the
    /// old end; aimed from 44pt estimates, it stopped short of the real one.
    func testFlatListScrollTargetReachesTheTrueEndOfTallRowsAddedWithIt() throws {
        let (list, window, apply) = tallRowList()
        defer { window.isHidden = true }
        apply(tallRows(3))
        list.setScrollTarget(["id": "row-2", "animated": false])
        settle(list)
        try assertAtTrueEnd(list, lastRow: 2, rowHeight: 320)

        apply(tallRows(24))
        list.setScrollTarget(["id": "row-23", "animated": false])
        settle(list)
        XCTAssertEqual(list.numberOfItems(inSection: 0), 24)
        try assertAtTrueEnd(list, lastRow: 23, rowHeight: 320)
    }

    /// A target set while a second update waits behind the one landing aims
    /// at the rows of that second update.
    func testFlatListScrollTargetWaitsForAQueuedUpdate() throws {
        let (list, window, apply) = tallRowList()
        defer { window.isHidden = true }
        apply(tallRows(2))
        apply(tallRows(18))
        list.setScrollTarget(["id": "row-17", "animated": false])
        settle(list)
        XCTAssertEqual(list.numberOfItems(inSection: 0), 18)
        try assertAtTrueEnd(list, lastRow: 17, rowHeight: 320)
    }

    /// An animated scroll to the last row lands on the true end too.
    func testFlatListAnimatedScrollTargetLandsOnTheTrueEnd() throws {
        let (list, window, apply) = tallRowList()
        defer { window.isHidden = true }
        apply(tallRows(2))
        settle(list)
        apply(tallRows(16, height: 260))
        list.setScrollTarget(["id": "row-15", "animated": true])
        settle(list, seconds: 1.2)
        try assertAtTrueEnd(list, lastRow: 15, rowHeight: 260)
    }

    /// A row near the end cannot come to the top; the list stops at its true
    /// end. A row that can still comes to the top, as before.
    func testFlatListScrollTargetNearTheEndStopsAtTheTrueEnd() throws {
        // Taller than the last two rows: the second to last cannot reach the top.
        let (list, window, apply) = tallRowList(height: 800)
        defer { window.isHidden = true }
        apply(tallRows(2))
        settle(list)
        apply(tallRows(20))
        list.setScrollTarget(["id": "row-4", "animated": false])
        settle(list)
        let fourth = try XCTUnwrap(list.layoutAttributesForItem(at: IndexPath(item: 4, section: 0)))
        XCTAssertEqual(list.contentOffset.y, fourth.frame.minY - list.adjustedContentInset.top, accuracy: 0.5)

        list.setScrollTarget(["id": "row-18", "animated": false])
        settle(list)
        try assertAtTrueEnd(list, lastRow: 19, rowHeight: 320)
    }

    /// The end is held only until the finger takes the list.
    func testFlatListStopsHoldingTheEndOnceTheUserDrags() throws {
        let (list, window, apply) = tallRowList()
        defer { window.isHidden = true }
        apply(tallRows(2))
        settle(list)
        apply(tallRows(12))
        list.setScrollTarget(["id": "row-11", "animated": false])
        // Once the target lands, before the passes that check the end again.
        let deadline = Date().addingTimeInterval(1)
        while list.contentOffset.y < 1, Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        XCTAssertGreaterThan(list.contentOffset.y, 1000)
        list.scrollViewWillBeginDragging(list)
        list.contentOffset = CGPoint(x: 0, y: 100)
        settle(list)
        XCTAssertEqual(list.contentOffset.y, 100, accuracy: 0.5, "a correction fought the finger")
    }

    func testFlatListRefreshControlForwardsAndTracksControlledState() {
        let list = CraftNativeFlatList()
        // A refresh control only begins refreshing inside a window.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        list.frame = window.bounds
        window.addSubview(list)
        window.isHidden = false
        defer { window.isHidden = true }
        var refreshCount = 0
        list.setRefreshHandler({ refreshCount += 1 }, refreshing: false)

        let control = try! XCTUnwrap(list.refreshControl)
        control.sendActions(for: .valueChanged)
        XCTAssertEqual(refreshCount, 1)

        list.setRefreshHandler({ refreshCount += 1 }, refreshing: true)
        XCTAssertTrue(control.isRefreshing)
        list.setRefreshAppearance(["tintColor": "#22c55e"])
        XCTAssertEqual(control.tintColor, UIColor(hex: "#22c55e"))
        list.setRefreshAppearance([:])
        XCTAssertNil(control.tintColor)
        list.setRefreshHandler({ refreshCount += 1 }, refreshing: false)
        XCTAssertFalse(control.isRefreshing)
        list.setRefreshHandler(nil, refreshing: false)
        XCTAssertNil(list.refreshControl)
    }

    func testImageBackgroundTintFollowsStyle() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        let backgroundNode: ([String: Any]) -> [String: Any] = { style in
            [
                "type": "ImageBackground",
                "props": ["key": "background"],
                "style": style,
            ]
        }

        controller.render(document([backgroundNode(["tintColor": "#2563eb"])]))
        let background = try XCTUnwrap(find(UIImageView.self, key: "background", below: controller.view))
        XCTAssertEqual(background.tintColor, UIColor(hex: "#2563eb"))

        controller.render(document([backgroundNode([:])]))
        // Clearing an explicit tint restores UIKit's inherited tint. The
        // getter returns that resolved colour rather than nil on iOS 27.
        XCTAssertEqual(background.tintColor, background.superview?.tintColor)
    }

    func testFlatListControllerLaysOutAndMovesMulticolumnRowsWithoutReentrantInvalidation() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let rows: [[String: Any]] = (0..<40).map { index in
            [
                "id": "row-\(index)",
                "type": "View",
                "props": ["key": "row-\(index)", "listRole": "item"],
                "children": [[
                    "id": "label-\(index)", "type": "Text",
                    "props": ["testID": "label-\(index)"], "children": ["Row \(index)"],
                ]],
            ]
        }
        func document(_ children: [[String: Any]]) -> [String: Any] {
            [
                "id": "root-node", "type": "View", "children": [[
                    "id": "list-node", "type": "FlatList",
                    "props": ["testID": "grid", "numColumns": 2],
                    "style": ["height": 300], "children": children,
                ]],
            ]
        }

        controller.render(document(rows))
        controller.view.layoutIfNeeded()
        let list = try XCTUnwrap(find(CraftNativeFlatList.self, key: "grid", below: controller.view))
        list.layoutIfNeeded()
        XCTAssertEqual(list.numberOfItems(inSection: 0), 40)
        XCTAssertNotNil(find(UILabel.self, key: "label-0", below: controller.view))

        controller.render(document(Array(rows.reversed())))
        controller.view.layoutIfNeeded()
        list.layoutIfNeeded()
        XCTAssertEqual(list.numberOfItems(inSection: 0), 40)
    }

    func testFlatListUsesIntrinsicHeightsForVariableRows() throws {
        let list = CraftNativeFlatList()
        list.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        let rows: [[String: Any]] = [
            ["id": "short", "type": "Text", "children": ["Short"]],
            ["id": "tall", "type": "Text", "children": ["Tall\nrow\ncontent\ncontent"]],
        ]
        let render: CraftNativeFlatList.RenderItem = { node, _, previous in
            let label = (previous as? UILabel) ?? UILabel()
            label.numberOfLines = 0
            label.font = .systemFont(ofSize: 16)
            label.text = (node["children"] as? [String])?.first
            return label
        }

        list.apply(
            nodes: rows,
            horizontal: false,
            columns: 1,
            inverted: false,
            endReachedThreshold: 0.1,
            renderItem: render,
            recycleItem: { _ in },
            removeItem: { _ in },
            endReached: nil
        )
        list.layoutIfNeeded()

        let short = try XCTUnwrap(list.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
        let tall = try XCTUnwrap(list.layoutAttributesForItem(at: IndexPath(item: 1, section: 0)))
        XCTAssertGreaterThan(tall.size.height, short.size.height + 20)
    }

    func testFlatListKeepsHorizontalRowsIntrinsicallySized() throws {
        let list = CraftNativeFlatList()
        list.frame = CGRect(x: 0, y: 0, width: 320, height: 80)
        let rows: [[String: Any]] = [
            ["id": "short", "type": "Text", "children": ["short"]],
            ["id": "long", "type": "Text", "children": ["a much longer horizontal row"]],
        ]
        let render: CraftNativeFlatList.RenderItem = { node, _, previous in
            let label = (previous as? UILabel) ?? UILabel()
            label.numberOfLines = 1
            label.font = .systemFont(ofSize: 16)
            label.text = (node["children"] as? [String])?.first
            return label
        }

        list.apply(
            nodes: rows,
            horizontal: true,
            columns: 1,
            inverted: false,
            endReachedThreshold: 0.1,
            renderItem: render,
            recycleItem: { _ in },
            removeItem: { _ in },
            endReached: nil
        )
        list.layoutIfNeeded()

        let short = try XCTUnwrap(list.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
        let long = try XCTUnwrap(list.layoutAttributesForItem(at: IndexPath(item: 1, section: 0)))
        XCTAssertLessThan(short.size.width, list.bounds.width)
        XCTAssertGreaterThan(long.size.width, short.size.width + 20)
    }

    func testFlatListCoalescesAnEndReachedRenderDuringSnapshotApplication() {
        let list = CraftNativeFlatList()
        list.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        let first = (0..<2).map { index in
            ["id": "row-\(index)", "type": "Text", "children": ["Row \(index)"]] as [String: Any]
        }
        let appended = first + [["id": "row-2", "type": "Text", "children": ["Row 2"]]]
        let render: CraftNativeFlatList.RenderItem = { _, _, previous in previous ?? UILabel() }
        var endReachedCount = 0
        let endReached = expectation(description: "end reached after initial snapshot")

        list.apply(
            nodes: first,
            horizontal: false,
            columns: 1,
            inverted: false,
            endReachedThreshold: 0.1,
            renderItem: render,
            recycleItem: { _ in },
            removeItem: { _ in },
            endReached: {
                endReachedCount += 1
                list.apply(
                    nodes: appended,
                    horizontal: false,
                    columns: 1,
                    inverted: false,
                    endReachedThreshold: 0.1,
                    renderItem: render,
                    recycleItem: { _ in },
                    removeItem: { _ in },
                    endReached: nil
                )
                endReached.fulfill()
            }
        )
        list.layoutIfNeeded()
        wait(for: [endReached], timeout: 2)
        list.layoutIfNeeded()

        XCTAssertEqual(endReachedCount, 1)
        XCTAssertEqual(list.numberOfItems(inSection: 0), 3)

        let changedMiddle = expectation(description: "end reached after a middle row changes")
        list.apply(
            nodes: [
                first[0],
                ["id": "row-1", "type": "Text", "children": ["Updated row 1"]],
                appended[2],
            ],
            horizontal: false,
            columns: 1,
            inverted: false,
            endReachedThreshold: 0.1,
            renderItem: render,
            recycleItem: { _ in },
            removeItem: { _ in },
            endReached: { changedMiddle.fulfill() }
        )
        list.layoutIfNeeded()
        wait(for: [changedMiddle], timeout: 2)

        let chromeOnlyEndReached = expectation(description: "chrome-only list does not reach data end")
        chromeOnlyEndReached.isInverted = true
        let chromeOnly: [[String: Any]] = [
            ["id": "header", "type": "Text", "props": ["listRole": "header"]],
            ["id": "empty", "type": "Text", "props": ["listRole": "empty"]],
            ["id": "footer", "type": "Text", "props": ["listRole": "footer"]],
        ]
        list.apply(
            nodes: chromeOnly,
            horizontal: false,
            columns: 1,
            inverted: false,
            endReachedThreshold: 0.1,
            renderItem: render,
            recycleItem: { _ in },
            removeItem: { _ in },
            endReached: { chromeOnlyEndReached.fulfill() }
        )
        list.layoutIfNeeded()
        wait(for: [chromeOnlyEndReached], timeout: 0.2)
    }

    func testFlatListRetainsAHorizontalViewportAcrossInvertedMoves() throws {
        let list = CraftNativeFlatList()
        list.frame = CGRect(x: 0, y: 0, width: 320, height: 160)
        let header: [String: Any] = [
            "id": "header", "type": "Text", "props": ["listRole": "header"],
        ]
        let footer: [String: Any] = [
            "id": "footer", "type": "Text", "props": ["listRole": "footer"],
        ]
        let rows: [[String: Any]] = (0..<8).map { index in
            ["id": "row-\(index)", "type": "Text", "children": ["Row \(index)"]]
        }
        let render: CraftNativeFlatList.RenderItem = { _, _, previous in previous ?? UILabel() }
        func apply(_ data: [[String: Any]]) {
            list.apply(
                nodes: [header] + data + [footer],
                horizontal: true,
                columns: 1,
                inverted: true,
                endReachedThreshold: 0.1,
                renderItem: render,
                recycleItem: { _ in },
                removeItem: { _ in },
                endReached: nil
            )
            let settled = expectation(description: "horizontal snapshot settled")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { settled.fulfill() }
            wait(for: [settled], timeout: 1)
            list.layoutIfNeeded()
        }

        apply(rows)
        let layout = try XCTUnwrap(list.collectionViewLayout as? UICollectionViewFlowLayout)
        XCTAssertEqual(layout.scrollDirection, .horizontal)
        XCTAssertEqual(list.numberOfItems(inSection: 0), 10)
        XCTAssertEqual(list.visibleItemIdentities.first, "footer")

        list.scrollToItem(at: IndexPath(item: 4, section: 0), at: .left, animated: false)
        list.layoutIfNeeded()
        let retainedAnchor = try XCTUnwrap(list.visibleItemIdentities.first)
        let moved = [rows[1], rows[0]] + Array(rows.dropFirst(2))
        apply(moved)

        XCTAssertTrue(list.visibleItemIdentities.contains(retainedAnchor))
    }

    /// requestAnimationFrame rides the display (CraftNativeFrameClock): a run
    /// of frames in order, a cancelled callback skipped, a throwing one not
    /// stopping the rest, a hidden screen waiting until it is shown, and the
    /// display link stopping once nobody waits.
    func testAnimationFramesComeFromTheDisplayAndWaitWhileHidden() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        func number(_ script: String) -> Double { controller.evaluateScript(script)?.toDouble() ?? .nan }
        func wait(_ what: String, _ check: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !check() {
                if Date() > deadline { XCTFail("Timed out waiting for \(what)"); return }
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
        }

        controller.evaluateScript("""
            globalThis.__frames = [];
            (function tick(time) { __frames.push(time); if (__frames.length < 20) requestAnimationFrame(tick); })(0);
        """)
        wait("twenty frames") { number("__frames.length") == 20 }
        XCTAssertEqual(controller.evaluateScript("__frames.every(function(t, i) { return i === 0 || t > __frames[i - 1]; })")?.toBool(), true)
        wait("the display link to stop") { !CraftNativeFrameClock.shared.isRunning }
        XCTAssertEqual(CraftNativeFrameClock.shared.waitingCount, 0)

        controller.evaluateScript("""
            globalThis.__hits = 0;
            var gone = requestAnimationFrame(function() { __hits += 100; });
            requestAnimationFrame(function() { throw new Error('one callback failing'); });
            requestAnimationFrame(function() { __hits += 1; });
            cancelAnimationFrame(gone);
        """)
        wait("the frame") { number("__hits") == 1 }

        controller.screenVisibilityChanged(false)
        controller.evaluateScript("globalThis.__shown = 0; requestAnimationFrame(function() { __shown = 1; });")
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(number("__shown"), 0, "a hidden screen's frame waits")
        XCTAssertEqual(CraftNativeFrameClock.shared.waitingCount, 0)
        controller.screenVisibilityChanged(true)
        wait("the frame once shown") { number("__shown") == 1 }
    }

    /// A window in the test host's scene: one made with only a frame is in
    /// no scene, so nothing in it can take the keyboard.
    private func hostWindow() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        return window
    }

    /// Runs the main queue past everything already on it. A screen keeps a
    /// caret in view on the next turn of the run loop, and a fixed wait can
    /// end before that turn while a loaded simulator brings its keyboard up:
    /// the test then measured a text view not yet laid out for its new text.
    /// Suspending releases the main actor; a synchronous XCTest wait inside
    /// a main-queue block cannot drain another block queued on that queue.
    private func drainMainQueue() async {
        let drained = expectation(description: "the main queue reached this block")
        DispatchQueue.main.async { drained.fulfill() }
        let result = await XCTWaiter.fulfillment(of: [drained], timeout: 5)
        XCTAssertEqual(result, .completed, "the main queue reached this block")
    }

    func testImagesLoadOverHttpOnlyFromThisMachine() {
        for address in ["https://example.com/a.png", "http://localhost:3130/assets/a.png", "http://127.0.0.1:3130/a.png", "http://[::1]:3130/a.png", "http://hq.localhost/a.png"] {
            XCTAssertTrue(CraftNativeScreenController.loadsImage(from: URL(string: address)!), address)
        }
        for address in ["http://example.com/a.png", "http://localhost.example.com/a.png", "ftp://localhost/a.png", "file:///tmp/a.png"] {
            XCTAssertFalse(CraftNativeScreenController.loadsImage(from: URL(string: address)!), address)
        }
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([[
            "type": "Image", "props": ["key": "local", "source": ["uri": "http://localhost:9/missing.png"]]
        ]]))
        let image = find(UIImageView.self, key: "local", below: controller.view)
        XCTAssertNotEqual(image?.accessibilityValue, "Unsupported image source")
    }

    func testMultilineRendersPreserveCompositionAndApplyTypographyAfterCommit() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = try hostWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func content(_ value: String, fontSize: Int, caption: String) -> [String: Any] {
            document([
                ["type": "TextInput", "props": ["key": "claim-proof", "multiline": true, "value": value], "style": ["fontSize": fontSize]],
                node("Text", key: "caption", text: caption),
            ])
        }
        controller.render(content("", fontSize: 16, caption: "Before"))
        let proof = try XCTUnwrap(find(UITextView.self, key: "claim-proof", below: controller.view))
        XCTAssertTrue(proof.becomeFirstResponder())
        proof.setMarkedText("ラン", selectedRange: NSRange(location: 2, length: 0))
        let marked = try XCTUnwrap(proof.markedTextRange)
        XCTAssertEqual(proof.text(in: marked), "ラン")

        controller.render(content("", fontSize: 16, caption: "Unrelated caption changed"))
        XCTAssertNotNil(proof.markedTextRange, "An unchanged input must keep its composing range")
        XCTAssertEqual(proof.text, "ラン")
        controller.render(content("", fontSize: 22, caption: "Updated while composing"))

        XCTAssertTrue(proof === find(UITextView.self, key: "claim-proof", below: controller.view))
        XCTAssertTrue(proof.isFirstResponder)
        XCTAssertEqual(proof.text, "ラン")
        let retained = try XCTUnwrap(proof.markedTextRange, "A reactive render must not commit or discard the keyboard's composition")
        XCTAssertEqual(proof.text(in: retained), "ラン")
        proof.unmarkText()
        proof.insertText(" club")
        controller.render(content("ラン club", fontSize: 22, caption: "Committed"))
        XCTAssertEqual(proof.text, "ラン club")
        XCTAssertNil(proof.markedTextRange)
        XCTAssertEqual(proof.font?.pointSize, 22)
    }

    func testRetainedRowButtonStillDispatchesAfterItsPreviousSiblingIsRemoved() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.evaluateScript("globalThis.__rowPress = ''; globalThis.__stxNativeCallback = function(json) { const message = JSON.parse(json); if (message.type === 'EVENT') globalThis.__rowPress = message.payload.handlerName; };")
        func row(_ id: String) -> [String: Any] {
            ["id": "row-\(id)", "type": "View", "props": ["key": id], "children": [
                ["id": "input-\(id)", "type": "TextInput", "props": ["key": "input-\(id)", "defaultValue": "Draft"]],
                ["id": "button-\(id)", "type": "Button", "props": ["key": "button-\(id)", "title": "Select row"], "events": ["onPress": "select-\(id)"]],
            ]]
        }
        controller.render(document([row("a"), row("b")]))
        let button = try XCTUnwrap(find(UIButton.self, key: "button-b", below: controller.view))
        controller.render(document([row("b"), row("c")]))
        XCTAssertTrue(button === find(UIButton.self, key: "button-b", below: controller.view))
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(controller.evaluateScript("__rowPress")?.toString(), "select-b")
    }

    func testScrollCanCancelButtonAndFieldTrackingWithoutTakingValueControls() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([[
            "type": "ScrollView", "props": ["key": "form"], "style": ["height": 300], "children": [
                ["type": "Button", "props": ["key": "action", "title": "Save"]],
                ["type": "Slider", "props": ["key": "position", "value": 0.5]],
                ["type": "Switch", "props": ["key": "toggle", "value": false]],
                ["type": "TextInput", "props": ["key": "draft", "value": "Draft"]],
            ],
        ]]))
        let form = try XCTUnwrap(find(UIScrollView.self, key: "form", below: controller.view))
        XCTAssertTrue(form.touchesShouldCancel(in: try XCTUnwrap(find(UIButton.self, key: "action", below: controller.view))))
        XCTAssertFalse(form.touchesShouldCancel(in: try XCTUnwrap(find(UISlider.self, key: "position", below: controller.view))))
        XCTAssertFalse(form.touchesShouldCancel(in: try XCTUnwrap(find(UISwitch.self, key: "toggle", below: controller.view))))
        XCTAssertTrue(form.touchesShouldCancel(in: try XCTUnwrap(find(UITextField.self, key: "draft", below: controller.view))))
    }

    /// A multiline input grows up to its `maxHeight` and then scrolls inside
    /// itself: HQ's long workout comment was cut off with no way to reach the
    /// rest. A short one still sizes to its text, without scrolling.
    func testAMultilineInputScrollsInsideItselfPastItsMaxHeight() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = try hostWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let long = (1...14).map { "\($0)) an answer to the coach's question" }.joined(separator: "\n")
        controller.render(document([
            ["type": "ScrollView", "props": ["key": "form"], "style": ["flex": 1], "children": [
                ["type": "TextInput", "props": ["key": "long", "multiline": true, "value": long], "style": ["maxHeight": 140, "fontSize": 17]],
                ["type": "TextInput", "props": ["key": "short", "multiline": true, "value": "Fine"], "style": ["maxHeight": 140, "fontSize": 17]],
            ]],
        ]))
        controller.view.layoutIfNeeded()
        let longInput = try XCTUnwrap(find(UITextView.self, key: "long", below: controller.view))
        let shortInput = try XCTUnwrap(find(UITextView.self, key: "short", below: controller.view))
        longInput.layoutIfNeeded()
        shortInput.layoutIfNeeded()
        XCTAssertLessThanOrEqual(longInput.bounds.height, 140.5)
        XCTAssertTrue(longInput.isScrollEnabled, "the rest of the text is reachable")
        longInput.layoutIfNeeded()
        XCTAssertGreaterThan(longInput.contentSize.height, longInput.bounds.height, "scrolling, it reaches the last line")
        XCTAssertFalse(shortInput.isScrollEnabled)
        XCTAssertLessThan(shortInput.bounds.height, 140)
    }

    /// The caret stays where it can be seen as an input at the bottom of a
    /// screen grows: only the field was scrolled into view, when editing
    /// began, so the words typed after that went under the keyboard.
    func testTheCaretStaysInViewAsAnInputGrows() async throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = try hostWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.render(document([
            ["type": "ScrollView", "props": ["key": "form"], "style": ["height": 400], "children": [
                ["type": "View", "props": ["key": "above"], "style": ["height": 360]],
                ["type": "TextInput", "props": ["key": "comment", "multiline": true], "style": ["fontSize": 17]],
            ]],
        ]))
        controller.view.layoutIfNeeded()
        let form = try XCTUnwrap(find(UIScrollView.self, key: "form", below: controller.view))
        let input = try XCTUnwrap(find(UITextView.self, key: "comment", below: controller.view))
        XCTAssertTrue(input.becomeFirstResponder())
        input.text = (1...10).map { "line \($0)" }.joined(separator: "\n")
        input.selectedRange = NSRange(location: (input.text as NSString).length, length: 0)
        input.delegate?.textViewDidChange?(input)
        await drainMainQueue()
        let end = try XCTUnwrap(input.selectedTextRange?.end)
        let caret = input.convert(input.caretRect(for: end), to: form)
        let visible = form.bounds.inset(by: form.adjustedContentInset)
        XCTAssertTrue(visible.contains(caret), "caret \(caret) in \(visible)")
    }

    /// HQ's "Editing your comment": a long multiline input with no max
    /// height in the screen's scroll view, focused with the caret at the end
    /// of its text. Taller than the part the keyboard leaves, only its top
    /// was scrolled into view, so its last lines and the caret stayed under
    /// the keyboard. The caret is above the keyboard when it comes up, and
    /// after a line is typed.
    func testALongInputWithoutAMaxHeightKeepsItsCaretAboveTheKeyboard() async throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = try hostWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let long = (1...30).map { "\($0)) an answer to the coach's question" }.joined(separator: "\n")
        controller.render(document([
            ["type": "ScrollView", "props": ["key": "workout"], "style": ["flex": 1], "children": [
                ["type": "View", "props": ["key": "above"], "style": ["height": 240]],
                ["type": "TextInput", "props": ["key": "comment", "multiline": true, "value": long], "style": ["fontSize": 17]],
                ["type": "View", "props": ["key": "below"], "style": ["height": 120]],
            ]],
        ]))
        controller.view.layoutIfNeeded()
        let input = try XCTUnwrap(find(UITextView.self, key: "comment", below: controller.view))
        XCTAssertFalse(input.isScrollEnabled, "with no max height it grows with its text")
        let form = try XCTUnwrap(find(UIScrollView.self, key: "workout", below: controller.view))
        let keyboard = CGRect(x: 0, y: window.bounds.height - 336, width: window.bounds.width, height: 336)
        var currentKeyboard = keyboard
        // Becoming first responder also schedules UIKit's real keyboard. Its
        // later frame can replace the synthetic one while this test yields.
        // Observe that frame independently of Craft's layout, in window space.
        let keyboardObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
        ) { notification in
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
            currentKeyboard = window.convert(frame.cgRectValue, from: nil)
        }
        defer { NotificationCenter.default.removeObserver(keyboardObserver) }
        XCTAssertTrue(input.becomeFirstResponder())
        input.selectedRange = NSRange(location: (input.text as NSString).length, length: 0)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [
            UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: window.convert(keyboard, to: nil)),
            UIResponder.keyboardAnimationDurationUserInfoKey: 0,
            UIResponder.keyboardAnimationCurveUserInfoKey: 0,
        ])
        controller.view.layoutIfNeeded()
        await drainMainQueue()
        XCTAssertTrue(window.bounds.intersects(currentKeyboard), "the observed keyboard covers part of this window")
        XCTAssertGreaterThan(input.bounds.height, currentKeyboard.minY - window.safeAreaInsets.top, "taller than the part the keyboard leaves")
        func caret() throws -> CGRect {
            let end = try XCTUnwrap(input.selectedTextRange?.end)
            return input.convert(input.caretRect(for: end), to: window)
        }
        var shown = try caret()
        XCTAssertLessThanOrEqual(shown.maxY, currentKeyboard.minY + 0.5, "caret \(shown) above the keyboard at \(currentKeyboard.minY)")
        XCTAssertGreaterThanOrEqual(shown.minY, window.safeAreaInsets.top - 0.5, "caret \(shown) on screen")

        input.text = long + "\n31) and one more line"
        input.selectedRange = NSRange(location: (input.text as NSString).length, length: 0)
        input.delegate?.textViewDidChange?(input)
        await drainMainQueue()
        shown = try caret()
        XCTAssertLessThanOrEqual(shown.maxY, currentKeyboard.minY + 0.5, "typed: caret \(shown) above the keyboard at \(currentKeyboard.minY)")
        XCTAssertGreaterThanOrEqual(shown.minY, window.safeAreaInsets.top - 0.5, "typed: caret \(shown) on screen")

        // A larger edit must reveal the caret again, even if a keyboard
        // frame change made the viewport taller during the first edit.
        let offsetBeforeTyping = form.contentOffset.y
        input.text += "\n" + (32...41).map { "\($0)) continuing the answer" }.joined(separator: "\n")
        input.selectedRange = NSRange(location: (input.text as NSString).length, length: 0)
        input.delegate?.textViewDidChange?(input)
        await drainMainQueue()
        shown = try caret()
        XCTAssertTrue(window.bounds.intersects(currentKeyboard))
        XCTAssertLessThanOrEqual(shown.maxY, currentKeyboard.minY + 0.5, "continued: caret \(shown) above the keyboard at \(currentKeyboard.minY)")
        XCTAssertGreaterThanOrEqual(shown.minY, window.safeAreaInsets.top - 0.5, "continued: caret \(shown) on screen")
        XCTAssertGreaterThan(form.contentOffset.y, offsetBeforeTyping + 0.5, "typing beyond the viewport actually scrolls the caret into view")
    }

    func testScrollKeyboardTapPreservesTextAreaFocusAndSelectionButDismissesBackground() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = try hostWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.render(document([
            ["type": "ScrollView", "props": ["key": "form"], "style": ["height": 300], "children": [
                ["type": "TextInput", "props": ["key": "review", "multiline": true, "value": "A beautiful ridge"], "style": ["height": 120]],
            ]],
        ]))
        let form = try XCTUnwrap(find(UIScrollView.self, key: "form", below: controller.view))
        let review = try XCTUnwrap(find(UITextView.self, key: "review", below: controller.view))
        XCTAssertTrue(review.becomeFirstResponder())
        review.selectedRange = NSRange(location: 2, length: 9)
        let selectionSurface = UIView()
        selectionSurface.addGestureRecognizer(UITapGestureRecognizer())
        review.addSubview(selectionSurface)
        var forgotFocus = false
        for policy in ["never", "handled", "always"] {
            craftHandleKeyboardTap(in: form, hit: selectionSurface, persistTaps: policy) { forgotFocus = true }
            XCTAssertTrue(review.isFirstResponder, policy)
            XCTAssertEqual(review.selectedRange, NSRange(location: 2, length: 9), policy)
            XCTAssertFalse(forgotFocus, policy)
        }
        craftHandleKeyboardTap(in: form, hit: form, persistTaps: "never") { forgotFocus = true }
        XCTAssertFalse(review.isFirstResponder)
        XCTAssertTrue(forgotFocus)
    }

    func testPlainTextInputKeepsItsPlaceholderWithoutACustomColor() throws {
        let screen = CraftNativeScreenController(config: CraftConfig())
        screen.loadViewIfNeeded()
        func document(_ placeholder: String?, color: String? = nil) -> [String: Any] {
            var props: [String: Any] = ["key": "email"]
            props["placeholder"] = placeholder
            props["placeholderTextColor"] = color
            return ["type": "TextInput", "props": props, "style": ["height": 48, "width": 300]]
        }
        screen.render(document("Email"))
        let input = try XCTUnwrap(find(UITextField.self, key: "email", below: screen.view))
        XCTAssertEqual(input.placeholder, "Email", "A normal HTML input has no custom placeholder color")
        screen.render(document("Updated email", color: "#ff0000"))
        XCTAssertTrue(input === find(UITextField.self, key: "email", below: screen.view))
        XCTAssertEqual(input.placeholder, "Updated email")
        XCTAssertEqual(input.attributedPlaceholder?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor, .red)
        screen.render(document("Email"))
        XCTAssertEqual(input.placeholder, "Email", "Removing a custom color restores the system placeholder")
        XCTAssertNotEqual(input.attributedPlaceholder?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor, .red)
        screen.render(document(nil))
        XCTAssertNil(input.placeholder)
    }

    func testTextInputsPadTheirTextAndAskForAutofill() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([
            ["type": "TextInput", "props": ["key": "email", "textContentType": "username", "placeholder": "Email"], "style": ["paddingHorizontal": 16, "height": 48, "width": 300]],
            ["type": "TextInput", "props": ["key": "password", "autoComplete": "current-password", "secureTextEntry": true], "style": ["paddingLeft": 12, "paddingRight": 4]],
            ["type": "TextInput", "props": ["key": "code", "textContentType": "oneTimeCode", "keyboardType": "number-pad"]],
            ["type": "TextInput", "props": ["key": "notes", "multiline": true], "style": ["padding": 10]],
        ]))
        let email = try XCTUnwrap(find(CraftNativeTextField.self, key: "email", below: controller.view))
        let password = try XCTUnwrap(find(CraftNativeTextField.self, key: "password", below: controller.view))
        let code = try XCTUnwrap(find(CraftNativeTextField.self, key: "code", below: controller.view))
        let notes = try XCTUnwrap(find(UITextView.self, key: "notes", below: controller.view))
        XCTAssertEqual(email.padding, UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16))
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 48)
        XCTAssertGreaterThanOrEqual(email.textRect(forBounds: bounds).minX, 16)
        XCTAssertGreaterThanOrEqual(email.placeholderRect(forBounds: bounds).minX, 16)
        XCTAssertLessThanOrEqual(email.editingRect(forBounds: bounds).maxX, 284)
        XCTAssertEqual(email.textContentType, .username)
        XCTAssertEqual(password.textContentType, .password)
        XCTAssertTrue(password.isSecureTextEntry)
        XCTAssertEqual(password.padding.left, 12)
        XCTAssertEqual(code.textContentType, .oneTimeCode)
        XCTAssertEqual(code.keyboardType, .numberPad)
        XCTAssertEqual(notes.textContainerInset, UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10))
        XCTAssertEqual(CraftNativeScreenController.textContentType(["autoComplete": "new-password"]), .newPassword)
        XCTAssertEqual(CraftNativeScreenController.textContentType(["textContentType": "emailAddress"]), .emailAddress)
        XCTAssertNil(CraftNativeScreenController.textContentType(["autoComplete": "off"]))
    }

    func testDelayedInputAcknowledgementDoesNotStealFocusFromTheNextField() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = try hostWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.render(document([
            ["type": "TextInput", "props": ["key": "name"], "events": ["onChangeText": "nameChanged"]],
            ["type": "TextInput", "props": ["key": "email"]],
        ]))
        let name = try XCTUnwrap(find(UITextField.self, key: "name", below: controller.view))
        let email = try XCTUnwrap(find(UITextField.self, key: "email", below: controller.view))
        XCTAssertTrue(name.becomeFirstResponder())
        name.text = "Runner"
        name.sendActions(for: .editingChanged)
        XCTAssertTrue(email.becomeFirstResponder())
        let settled = expectation(description: "input acknowledgement settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertTrue(email.isFirstResponder, "The previous field's delayed acknowledgement must respect the newer focus")
        XCTAssertFalse(name.isFirstResponder)
    }

    func testDelayedInputAcknowledgementDoesNotReopenADismissedKeyboard() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = try hostWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.render(document([
            ["type": "TextInput", "props": ["key": "name"], "events": ["onChangeText": "nameChanged"]],
        ]))
        let name = try XCTUnwrap(find(UITextField.self, key: "name", below: controller.view))
        XCTAssertTrue(name.becomeFirstResponder())
        name.text = "Runner"
        name.sendActions(for: .editingChanged)
        controller.forgetFocusedInput(name)
        window.endEditing(true)
        let settled = expectation(description: "dismissed input acknowledgement settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertFalse(name.isFirstResponder, "A completed edit must not undo an explicit keyboard dismissal")
    }

    func testReturnOnANextFieldMovesToTheNextOne() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = try hostWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.render(document([
            ["type": "TextInput", "props": ["key": "email", "returnKeyType": "next"]],
            ["type": "Text", "props": ["key": "between"], "children": ["Password"]],
            ["type": "TextInput", "props": ["key": "password", "returnKeyType": "go"], "events": ["onSubmitEditing": "signIn"]],
        ]))
        let email = try XCTUnwrap(find(UITextField.self, key: "email", below: controller.view))
        let password = try XCTUnwrap(find(UITextField.self, key: "password", below: controller.view))
        XCTAssertTrue(controller.inputAfter(email) === password)
        XCTAssertNil(controller.inputAfter(password))
        // Return stays in the form (the keyboard is kept), and focus moves on.
        XCTAssertFalse(controller.textFieldShouldReturn(email))
        // `go` with a handler of its own ends editing and fires it, as before.
        XCTAssertTrue(controller.textFieldShouldReturn(password))
    }

    func testAScrollViewInsetsForTheKeyboardAndShowsTheFocusedField() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = try hostWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.render(document([[
            "type": "ScrollView", "props": ["key": "form"], "style": ["flex": 1],
            "children": [
                ["type": "View", "props": ["key": "spacer"], "style": ["height": 700]],
                ["type": "TextInput", "props": ["key": "password"], "style": ["height": 44]],
            ],
        ]]))
        controller.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(find(UIScrollView.self, key: "form", below: controller.view))
        let password = try XCTUnwrap(find(UITextField.self, key: "password", below: controller.view))
        let keyboard = CGRect(x: 0, y: 500, width: 390, height: 344)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [
            UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: keyboard),
            UIResponder.keyboardAnimationDurationUserInfoKey: 0,
            UIResponder.keyboardAnimationCurveUserInfoKey: 0,
        ])
        controller.view.layoutIfNeeded()
        // The focused field scrolls into view (focus itself needs a running
        // keyboard, which a unit test host does not have).
        controller.scrollIntoView(password, animated: false)
        // Whatever the shrunken safe area does not cover, the inset does, and
        // the field sits above the keyboard.
        let field = password.convert(password.bounds, to: window)
        XCTAssertLessThanOrEqual(field.maxY, keyboard.minY + 0.5)
        XCTAssertGreaterThanOrEqual(scroll.contentInset.bottom, 0)
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil, userInfo: [
            UIResponder.keyboardAnimationDurationUserInfoKey: 0,
            UIResponder.keyboardAnimationCurveUserInfoKey: 0,
        ])
        XCTAssertEqual(scroll.contentInset.bottom, 0)
    }

    /// A scroll view the keyboard covers the end of keeps its keyboard inset
    /// as a layout moves it: a footer under a form shrank while the keyboard
    /// was up, the form grew down under the keyboard, and the inset measured
    /// where it used to end left its last fields there with nothing to scroll.
    func testAScrollViewKeepsItsKeyboardInsetAsALayoutMovesIt() async throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = try hostWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        // The inset follows a layout once its pass is over, on the main
        // queue: each check drains it first.
        func screen(footer: CGFloat) -> [[String: Any]] {
            [["type": "KeyboardAvoidingView", "props": ["key": "avoid", "keyboardVerticalOffset": 100], "style": ["flex": 1], "children": [
                ["type": "ScrollView", "props": ["key": "form"], "style": ["flex": 1], "children": [
                    ["type": "View", "props": ["key": "fields"], "style": ["height": 900]],
                ]],
                ["type": "View", "props": ["key": "footer"], "style": ["height": footer]],
            ]]]
        }
        controller.render(document(screen(footer: 120)))
        controller.view.layoutIfNeeded()
        let form = try XCTUnwrap(find(UIScrollView.self, key: "form", below: controller.view))
        // Nothing has focus, so no keyboard of UIKit's own replaces this one.
        let keyboard = CGRect(x: 0, y: window.bounds.height - 336, width: window.bounds.width, height: 336)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [
            UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: window.convert(keyboard, to: nil)),
            UIResponder.keyboardAnimationDurationUserInfoKey: 0,
            UIResponder.keyboardAnimationCurveUserInfoKey: 0,
        ])
        controller.view.layoutIfNeeded()
        await drainMainQueue()
        func covered() -> CGFloat { max(0, form.convert(form.bounds, to: window).maxY - keyboard.minY) }
        XCTAssertEqual(form.contentInset.bottom, covered(), accuracy: 0.5, "inset for what the keyboard covers")

        controller.render(document(screen(footer: 0)))
        controller.view.layoutIfNeeded()
        await drainMainQueue()
        XCTAssertGreaterThan(covered(), 50, "the form now ends under the keyboard")
        XCTAssertEqual(form.contentInset.bottom, covered(), accuracy: 0.5, "the inset follows the form to where it ends now")
        XCTAssertEqual(form.verticalScrollIndicatorInsets.bottom, covered(), accuracy: 0.5)

        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil, userInfo: [
            UIResponder.keyboardAnimationDurationUserInfoKey: 0,
            UIResponder.keyboardAnimationCurveUserInfoKey: 0,
        ])
        controller.render(document(screen(footer: 120)))
        controller.view.layoutIfNeeded()
        await drainMainQueue()
        XCTAssertEqual(form.contentInset.bottom, 0, "no keyboard, no inset")
    }

    func testFlatListContentInsetsRejectBooleanNumbers() {
        let list = CraftNativeFlatList()
        list.setContentContainerStyle(["padding": true, "paddingBottom": false])
        XCTAssertEqual(list.contentInset, .zero)
    }

    func testScreenNumericStylesRejectBooleanNumbers() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([node(
            "View",
            key: "boolean-style",
            style: ["width": true, "height": false, "borderWidth": true, "opacity": false]
        )]))

        let view = try XCTUnwrap(find(UIView.self, key: "boolean-style", below: controller.view))
        XCTAssertFalse(view.constraints.contains { $0.isActive && $0.firstAttribute == .width }, "Boolean width was treated as numeric")
        XCTAssertFalse(view.constraints.contains { $0.isActive && $0.firstAttribute == .height }, "Boolean height was treated as numeric")
        XCTAssertEqual(view.layer.borderWidth, 0, "Boolean border width was treated as numeric")
        XCTAssertEqual(view.alpha, 1, accuracy: 0.001, "Boolean opacity changed the native view")
    }

    func testAPressableWithPressFeedbackStillTakesItsPress() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([
            [
                "type": "Pressable", "props": ["key": "pressable"], "style": ["height": 24],
                "events": ["onPress": "pressed", "onPressIn": "pressIn", "onPressOut": "pressOut"],
                "children": [node("Text", key: "label", text: "Press")],
            ],
            [
                "type": "Pressable", "props": ["key": "disabled", "disabled": true], "style": ["height": 24],
                "events": ["onPress": "pressed"],
                "children": [node("Text", key: "disabled-label", text: "Disabled")],
            ],
        ]))
        let pressable = try XCTUnwrap(find(UIView.self, key: "pressable", below: controller.view))
        let recognizers = pressable.gestureRecognizers ?? []
        let tap = try XCTUnwrap(recognizers.first { $0 is UITapGestureRecognizer })
        let feedback = try XCTUnwrap(recognizers.first { ($0 as? UILongPressGestureRecognizer)?.minimumPressDuration == 0 })
        // The feedback begins as the finger lands; it must not take the touch
        // from the tap that is onPress.
        XCTAssertEqual(feedback.delegate?.gestureRecognizer?(feedback, shouldRecognizeSimultaneouslyWith: tap), true)
        let disabled = try XCTUnwrap(find(UIView.self, key: "disabled", below: controller.view))
        XCTAssertFalse(disabled.isUserInteractionEnabled)
        XCTAssertTrue(disabled.accessibilityTraits.contains(.notEnabled))
    }

    func testModalCloseRequestAndDismissAreIndependentVisibilityEvents() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.evaluateScript("globalThis.__modalEvents = []; globalThis.__stxNativeCallback = function(json) { const message = JSON.parse(json); if (message.type === 'EVENT') { const p = message.payload; __modalEvents.push(p.handlerName + (p.nativeEvent.reason ? ':' + p.nativeEvent.reason : '')); } };")
        controller.render(document([[
            "id": "modal-node", "type": "Modal",
            "props": ["key": "modal", "visible": false, "animationType": "none"],
            "events": ["onShow": "shown", "onRequestClose": "requested", "onDismiss": "dismissed"],
        ]]))
        XCTAssertEqual(controller.evaluateScript("__modalEvents.join('|')")?.toString(), "")
        _ = try controller.applyMutation(batch(1, [
            ["op": "updateNode", "id": "modal-node", "patch": ["props": ["visible": true]]],
        ]))
        let modal = try XCTUnwrap(find(UIView.self, key: "modal", below: controller.view))
        XCTAssertTrue(modal.isUserInteractionEnabled)
        let backdropAction = NSSelectorFromString("backdropTapped")
        XCTAssertTrue(modal.responds(to: backdropAction))
        modal.perform(backdropAction)
        XCTAssertEqual(controller.evaluateScript("__modalEvents.join('|')")?.toString(), "shown|requested:backdrop")
        XCTAssertFalse(modal.isHidden, "A close request waits for the owner's visibility update")
        _ = try controller.applyMutation(batch(2, [
            ["op": "updateNode", "id": "modal-node", "patch": ["props": ["visible": false]]],
        ]))
        XCTAssertTrue(modal.isHidden)
        XCTAssertEqual(controller.evaluateScript("__modalEvents.join('|')")?.toString(), "shown|requested:backdrop|dismissed")
        _ = try controller.applyMutation(batch(3, [
            ["op": "updateNode", "id": "modal-node", "patch": ["props": ["visible": false]]],
        ]))
        XCTAssertEqual(controller.evaluateScript("__modalEvents.length")?.toInt32(), 3, "An unchanged hidden state does not dismiss twice")
        _ = try controller.applyMutation(batch(4, [
            ["op": "updateNode", "id": "modal-node", "patch": ["props": ["visible": true]]],
        ]))
        XCTAssertTrue(modal.isUserInteractionEnabled)
        _ = try controller.applyMutation(batch(5, [
            ["op": "updateNode", "id": "modal-node", "patch": ["props": ["visible": false]]],
        ]))
        XCTAssertEqual(controller.evaluateScript("__modalEvents.join('|')")?.toString(), "shown|requested:backdrop|dismissed|shown|dismissed")
    }

    /// A form in a modal whose fields fit the screen until the keyboard
    /// rises: the button at the end has to scroll up above the keyboard. A
    /// trail review's Save sat under the keyboard with nothing to scroll.
    func testAModalFormScrollsItsLastButtonAboveTheKeyboard() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = try hostWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.render(document([
            ["id": "composer", "type": "Modal", "props": ["key": "composer", "visible": true, "animationType": "none"], "children": [
                ["type": "KeyboardAvoidingView", "props": ["key": "avoid"], "style": ["flex": 1], "children": [
                    ["type": "ScrollView", "props": ["key": "form", "testID": "form"], "style": ["flex": 1], "children": [
                        ["type": "View", "props": ["key": "fields"], "style": ["height": 520]],
                        ["type": "TextInput", "props": ["key": "review", "testID": "review", "multiline": true], "style": ["height": 96]],
                        ["type": "Button", "props": ["key": "save", "testID": "save"], "style": ["height": 50], "children": ["Save review"]],
                    ]],
                ]],
            ]],
        ]))
        controller.view.layoutIfNeeded()
        let form = try XCTUnwrap(find(UIScrollView.self, key: "form", below: controller.view))
        let input = try XCTUnwrap(find(UITextView.self, key: "review", below: controller.view))
        let save = try XCTUnwrap(find(UIButton.self, key: "save", below: controller.view))
        XCTAssertTrue(input.becomeFirstResponder())

        let screen = window.bounds
        let keyboard = CGRect(x: 0, y: screen.height - 336, width: screen.width, height: 336)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [
            UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: keyboard),
            UIResponder.keyboardAnimationDurationUserInfoKey: 0,
            UIResponder.keyboardAnimationCurveUserInfoKey: 0,
        ])
        controller.view.layoutIfNeeded()
        form.layoutIfNeeded()

        // As far as the form scrolls.
        let end = max(-form.adjustedContentInset.top, form.contentSize.height + form.adjustedContentInset.bottom - form.bounds.height)
        form.setContentOffset(CGPoint(x: 0, y: end), animated: false)
        form.layoutIfNeeded()
        let saveFrame = save.convert(save.bounds, to: window)
        XCTAssertLessThanOrEqual(saveFrame.maxY, keyboard.minY + 0.5, "Save review cannot be scrolled out from under the keyboard (form \(form.frame), content \(form.contentSize), inset \(form.adjustedContentInset))")
    }

    func testHidingAModalDismissesItsKeyboardWithoutRestoringHiddenInputFocus() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = try hostWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.render(document([
            ["type": "TextInput", "props": ["key": "outside"]],
            ["id": "review-modal", "type": "Modal", "props": ["key": "modal", "visible": true, "animationType": "none"],
                "children": [["type": "TextInput", "props": ["key": "review", "multiline": true], "events": ["onChangeText": "reviewChanged"]]]],
        ]))
        controller.view.layoutIfNeeded()
        let input = try XCTUnwrap(find(UITextView.self, key: "review", below: controller.view))
        XCTAssertTrue(input.becomeFirstResponder())
        input.text = "A trail review"
        controller.textViewDidChange(input)
        _ = try controller.applyMutation(batch(1, [
            ["op": "updateNode", "id": "review-modal", "patch": ["props": ["visible": false]]],
        ]))
        XCTAssertFalse(input.isFirstResponder, "Saving or cancelling a modal must dismiss its keyboard")
        let settled = expectation(description: "hidden modal input acknowledgement settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertFalse(input.isFirstResponder, "A delayed input acknowledgement cannot reopen the keyboard")
        _ = try controller.applyMutation(batch(2, [
            ["op": "updateNode", "id": "review-modal", "patch": ["props": ["visible": true]]],
        ]))
        XCTAssertFalse(input.isFirstResponder, "Reopening the modal waits for an explicit focus")
        XCTAssertTrue(input.becomeFirstResponder())
        let outside = try XCTUnwrap(find(UITextField.self, key: "outside", below: controller.view))
        XCTAssertTrue(outside.becomeFirstResponder())
        _ = try controller.applyMutation(batch(3, [
            ["op": "updateNode", "id": "review-modal", "patch": ["props": ["visible": false]]],
        ]))
        XCTAssertTrue(outside.isFirstResponder, "Hiding a modal must not dismiss another field's keyboard")
    }

    func testAShownModalInAScrollViewCoversTheScreenAndTakesItsTouches() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = try hostWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.render(document([[
            "type": "ScrollView", "props": ["key": "page"], "style": ["flex": 1],
            "children": [
                ["type": "View", "props": ["key": "spacer"], "style": ["height": 2000]],
                [
                    "type": "Modal", "props": ["key": "modal", "visible": true, "transparent": true, "animationType": "none"],
                    "children": [["type": "Button", "props": ["key": "close"], "events": ["onPress": "close"], "children": ["Close"]]],
                ],
            ],
        ]]))
        controller.view.layoutIfNeeded()
        let page = try XCTUnwrap(find(UIScrollView.self, key: "page", below: controller.view))
        page.setContentOffset(CGPoint(x: 0, y: 1200), animated: false)
        controller.view.layoutIfNeeded()
        let modal = try XCTUnwrap(find(UIView.self, key: "modal", below: controller.view))
        // Over the screen, not over the scroll content wherever it scrolled.
        XCTAssertTrue(modal.superview === controller.view)
        XCTAssertEqual(modal.frame, controller.view.bounds)
        XCTAssertTrue(modal.isUserInteractionEnabled)
        let close = try XCTUnwrap(find(UIButton.self, key: "close", below: modal))
        modal.layoutIfNeeded()
        let center = close.convert(CGPoint(x: close.bounds.midX, y: close.bounds.midY), to: controller.view)
        XCTAssertTrue(controller.view.bounds.contains(center))
        XCTAssertTrue(controller.view.hitTest(center, with: nil) === close)
    }

    func testANonModalOverlayLetsOutsideTouchesReachTheScreen() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = try hostWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.render(document([
            ["type": "Button", "props": ["key": "underlay"], "style": ["width": 390, "height": 844]],
            ["type": "Modal", "props": ["key": "popup", "visible": true, "nonModal": true, "animationType": "none"],
             "children": [["type": "Button", "props": ["key": "popup-action"], "style": ["width": 120, "height": 44], "children": ["Popup"]]]],
        ]))
        controller.view.layoutIfNeeded()
        let underlay = try XCTUnwrap(find(UIButton.self, key: "underlay", below: controller.view))
        let popup = try XCTUnwrap(find(UIView.self, key: "popup", below: controller.view))
        let popupAction = try XCTUnwrap(find(UIButton.self, key: "popup-action", below: popup))
        let popupPoint = popupAction.convert(CGPoint(x: popupAction.bounds.midX, y: popupAction.bounds.midY), to: controller.view)
        XCTAssertTrue(controller.view.hitTest(popupPoint, with: nil) === popupAction)
        let outside = CGPoint(x: min(underlay.bounds.maxX - 10, 300), y: min(underlay.bounds.maxY - 10, 700))
        XCTAssertTrue(controller.view.hitTest(outside, with: nil) === underlay)
    }

    func testANonModalOverlayUsesItsViewportFrame() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = try hostWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.render(document([
            ["type": "View", "props": ["key": "page"], "style": ["flex": 1]],
            ["type": "Modal", "props": ["key": "popup", "visible": true, "nonModal": true, "animationType": "none"],
             "style": ["position": "absolute", "left": 24, "top": 36, "width": 180, "height": 72],
             "children": [["type": "Text", "props": ["key": "label"], "children": ["Popup"]]]],
        ]))
        controller.view.layoutIfNeeded()
        let popup = try XCTUnwrap(find(UIView.self, key: "popup", below: controller.view))
        XCTAssertEqual(popup.frame.origin.x, 24, accuracy: 0.5)
        XCTAssertEqual(popup.frame.origin.y, 36, accuracy: 0.5)
        XCTAssertEqual(popup.frame.size.width, 180, accuracy: 0.5)
        XCTAssertEqual(popup.frame.size.height, 72, accuracy: 0.5)
        XCTAssertNotEqual(popup.frame, controller.view.bounds)
    }

    func testPopupMovedOutOfScrollViewKeepsLiveInputIdentityAndSelection() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(["id": "root", "type": "View", "children": [[
            "id": "page", "type": "ScrollView", "props": ["key": "page"], "style": ["height": 120],
            "children": [
                ["id": "spacer", "type": "View", "props": ["key": "spacer"], "style": ["height": 800]],
                ["id": "popup", "type": "Modal", "props": ["key": "popup", "visible": true, "nonModal": true, "animationType": "none"],
                 "children": [["id": "popup-field", "type": "TextInput", "props": ["key": "popup-field"]]]],
            ],
        ]]])

        let field = try XCTUnwrap(find(UITextField.self, key: "popup-field", below: controller.view))
        field.text = "draft"
        let caret = try XCTUnwrap(field.position(from: field.beginningOfDocument, offset: 3))
        field.selectedTextRange = field.textRange(from: caret, to: caret)

        controller.render(["id": "root", "type": "View", "children": [
            ["id": "page", "type": "ScrollView", "props": ["key": "page"], "style": ["height": 120],
             "children": [["id": "spacer", "type": "View", "props": ["key": "spacer"], "style": ["height": 800]]]],
            ["id": "popup", "type": "Modal", "props": ["key": "popup", "visible": true, "nonModal": true, "animationType": "none"],
             "children": [["id": "popup-field", "type": "TextInput", "props": ["key": "popup-field"]]]],
        ]])

        let retained = try XCTUnwrap(find(UITextField.self, key: "popup-field", below: controller.view))
        XCTAssertTrue(field === retained)
        XCTAssertEqual(retained.text, "draft")
        let selection = try XCTUnwrap(retained.selectedTextRange)
        XCTAssertEqual(retained.offset(from: retained.beginningOfDocument, to: selection.start), 3)
    }

    func testPopupReparentingAcrossOpenCloseCyclesRetainsInputIdentity() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        let pageWithoutPopup: [String: Any] = [
            "id": "page", "type": "ScrollView", "props": ["key": "page"],
            "style": ["height": 120], "children": [["id": "spacer", "type": "View", "props": ["key": "spacer"], "style": ["height": 800]]],
        ]
        let popup: [String: Any] = [
            "id": "popup", "type": "Modal", "props": ["key": "popup", "visible": true, "nonModal": true, "animationType": "none"],
            "children": [["id": "popup-field", "type": "TextInput", "props": ["key": "popup-field"]]],
        ]
        let pageWithPopup: [String: Any] = [
            "id": "page", "type": "ScrollView", "props": ["key": "page"],
            "style": ["height": 120], "children": [
                ["id": "spacer", "type": "View", "props": ["key": "spacer"], "style": ["height": 800]], popup,
            ],
        ]
        func insideDocument() -> [String: Any] {
            ["id": "root", "type": "View", "children": [pageWithPopup]]
        }
        func openDocument() -> [String: Any] {
            ["id": "root", "type": "View", "children": [pageWithoutPopup, popup]]
        }

        controller.render(insideDocument())
        let original = try XCTUnwrap(find(UITextField.self, key: "popup-field", below: controller.view))
        original.text = "draft"
        let caret = try XCTUnwrap(original.position(from: original.beginningOfDocument, offset: 3))
        original.selectedTextRange = original.textRange(from: caret, to: caret)

        for _ in 0..<3 {
            controller.render(openDocument())
            let opened = try XCTUnwrap(find(UITextField.self, key: "popup-field", below: controller.view))
            XCTAssertTrue(opened === original)
            XCTAssertEqual(opened.text, "draft")
            let openedSelection = try XCTUnwrap(opened.selectedTextRange)
            XCTAssertEqual(opened.offset(from: opened.beginningOfDocument, to: openedSelection.start), 3)

            controller.render(insideDocument())
            let closed = try XCTUnwrap(find(UITextField.self, key: "popup-field", below: controller.view))
            XCTAssertTrue(closed === original)
        }

        controller.render(["id": "root", "type": "View", "children": [pageWithoutPopup]])
        XCTAssertNil(find(UITextField.self, key: "popup-field", below: controller.view))
    }

    func testANonModalOverlayDoesNotDismissABlockingModalBelowIt() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = try hostWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.evaluateScript("globalThis.__dismissed = 0; globalThis.__stxNativeCallback = function(json) { const message = JSON.parse(json); if (message.type === 'EVENT' && message.payload.handlerName === 'underlyingDismissed') __dismissed++; };")
        controller.render(document([
            ["type": "Modal", "props": ["key": "underlying", "visible": true, "animationType": "none"],
             "events": ["onRequestClose": "underlyingDismissed"]],
            ["type": "Modal", "props": ["key": "popup", "visible": true, "nonModal": true, "animationType": "none"],
             "style": ["position": "absolute", "left": 24, "top": 36, "width": 160, "height": 72],
             "children": [["type": "Text", "props": ["key": "label"], "children": ["Popup"]]]],
        ]))
        controller.view.layoutIfNeeded()
        let popup = try XCTUnwrap(find(UIView.self, key: "popup", below: controller.view))
        let outside = CGPoint(x: controller.view.bounds.maxX - 20, y: controller.view.bounds.maxY - 20)
        XCTAssertTrue(controller.view.hitTest(outside, with: nil) === popup)
        XCTAssertEqual(controller.evaluateScript("__dismissed")?.toInt32(), 0)
    }

    func testASliderReportsTheDecimalItShows() {
        // UISlider keeps a Float; the script hears the number, not its
        // binary neighbour.
        XCTAssertEqual(CraftNativeScreenController.sliderEventValue(0.8), 0.8)
        XCTAssertEqual(CraftNativeScreenController.sliderEventValue(Float(0.3)), 0.3)
        XCTAssertEqual(CraftNativeScreenController.sliderEventValue(42), 42)
        // Nine steps of 0.1 in Floats is 0.90000004; the step says one place.
        XCTAssertEqual(CraftNativeScreenController.sliderEventValue(Float(0.1) * 9, step: 0.1), 0.9)
        XCTAssertEqual(CraftNativeScreenController.sliderEventValue(Float(0.25) * 3, step: 0.25), 0.75)
        XCTAssertEqual(CraftNativeScreenController.sliderEventValue(7, step: 1), 7)
    }

    func testAScrollDragCanCancelButtonsAndFieldsWhileValueControlsKeepTracking() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([[
            "type": "ScrollView", "props": ["key": "page"], "style": ["height": 120],
            "children": [
                ["type": "Button", "props": ["key": "button"], "children": ["Tap or drag"]],
                ["type": "Checkbox", "props": ["key": "checkbox"]],
                ["type": "Slider", "props": ["key": "slider"]],
                ["type": "Switch", "props": ["key": "switch"]],
                ["type": "TextInput", "props": ["key": "field"]],
                ["type": "DatePicker", "props": ["key": "date"]],
            ],
        ]]))
        let scroll = try XCTUnwrap(find(UIScrollView.self, key: "page", below: controller.view))
        XCTAssertFalse(scroll.delaysContentTouches, "ordinary taps still reach controls immediately")
        for key in ["button", "checkbox"] {
            let button = try XCTUnwrap(find(UIButton.self, key: key, below: scroll))
            XCTAssertTrue(scroll.touchesShouldCancel(in: button), "\(key) must yield to a scroll drag")
        }
        let field = try XCTUnwrap(find(UITextField.self, key: "field", below: scroll))
        XCTAssertTrue(scroll.touchesShouldCancel(in: field), "a drag over a row's field must scroll its page")
        for key in ["slider", "switch", "date"] {
            let control = try XCTUnwrap(find(UIControl.self, key: key, below: scroll))
            XCTAssertFalse(scroll.touchesShouldCancel(in: control), "\(key) retains its tracking gesture")
        }
    }

    func testANestedScrollViewsDragDoesNotScrollItsParent() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = try hostWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.render(document([[
            "type": "ScrollView", "props": ["key": "page"], "style": ["flex": 1],
            "children": [
                ["type": "ScrollView", "props": ["key": "strip"], "style": ["height": 72], "children": [
                    ["type": "View", "props": ["key": "tall"], "style": ["height": 600]],
                ]],
                ["type": "FlatList", "props": ["key": "list"], "style": ["height": 72], "children": [
                    ["type": "Text", "props": ["key": "row"], "children": ["Row"]],
                ]],
                ["type": "View", "props": ["key": "spacer"], "style": ["height": 1200]],
            ],
        ]]))
        controller.view.layoutIfNeeded()
        let page = try XCTUnwrap(find(UIScrollView.self, key: "page", below: controller.view))
        let strip = try XCTUnwrap(find(UIScrollView.self, key: "strip", below: controller.view))
        let list = try XCTUnwrap(find(UIScrollView.self, key: "list", below: controller.view))
        for (inner, name) in [(strip, "ScrollView"), (list, "FlatList")] {
            let delegate = try XCTUnwrap(inner.panGestureRecognizer.delegate, name)
            // UIKit gives a drag to one of the two; answering yes scrolled both.
            XCTAssertEqual(delegate.gestureRecognizer?(inner.panGestureRecognizer, shouldRecognizeSimultaneouslyWith: page.panGestureRecognizer), false, name)
            XCTAssertEqual(page.panGestureRecognizer.delegate?.gestureRecognizer?(page.panGestureRecognizer, shouldRecognizeSimultaneouslyWith: inner.panGestureRecognizer), false, name)
            // Other gestures, the back-swipe's and the tab swipe's among them,
            // still decide for themselves alongside a scroll view's pan.
            let other = UIPanGestureRecognizer()
            controller.view.addGestureRecognizer(other)
            defer { controller.view.removeGestureRecognizer(other) }
            XCTAssertEqual(delegate.gestureRecognizer?(inner.panGestureRecognizer, shouldRecognizeSimultaneouslyWith: other), true, name)
        }
    }

    func testADatePickerPicksADayOrAClassTime() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([
            ["type": "DatePicker", "props": ["key": "time", "mode": "time", "value": "07:30", "minuteInterval": 5], "events": ["onValueChange": "picked"]],
            ["type": "DatePicker", "props": ["key": "day", "value": "2026-10-12", "minimumDate": "2026-10-01", "maximumDate": "2026-12-31"]],
            ["type": "DatePicker", "props": ["key": "invalid-interval", "mode": "time", "minuteInterval": true]],
        ]))
        let time = try XCTUnwrap(find(UIDatePicker.self, key: "time", below: controller.view))
        let day = try XCTUnwrap(find(UIDatePicker.self, key: "day", below: controller.view))
        let invalid = try XCTUnwrap(find(UIDatePicker.self, key: "invalid-interval", below: controller.view))
        XCTAssertEqual(time.datePickerMode, .time)
        XCTAssertEqual(time.preferredDatePickerStyle, .compact)
        XCTAssertEqual(time.minuteInterval, 5)
        XCTAssertEqual(invalid.minuteInterval, 1)
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time.date)
        XCTAssertEqual(parts.hour, 7)
        XCTAssertEqual(parts.minute, 30)
        XCTAssertEqual(day.datePickerMode, .date)
        XCTAssertEqual(CraftNativeScreenController.datePickerEvent(day.date, mode: .date)["value"] as? String, "2026-10-12")
        XCTAssertNotNil(day.minimumDate)
        XCTAssertEqual(CraftNativeScreenController.datePickerEvent(time.date, mode: .time)["value"] as? String, "07:30")
        XCTAssertEqual(CraftNativeScreenController.pickerDate("2026-10-12T07:30:00Z")?.timeIntervalSince1970, 1_791_790_200)
        XCTAssertEqual(CraftNativeScreenController.pickerDate(1_791_790_200_000 as NSNumber)?.timeIntervalSince1970, 1_791_790_200)
        XCTAssertNil(CraftNativeScreenController.pickerDate("soon"))
        XCTAssertNil(CraftNativeScreenController.countdownDuration("1:x:3"))
    }

    func testSwitchKeepsItsControlAndUserValueWhenTheScriptAcknowledgesATap() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        func screen(_ value: Bool, _ label: String) -> [String: Any] {
            document([
                ["type": "Switch", "props": ["key": "consent", "value": value], "events": ["onValueChange": "consentChanged"]],
                ["type": "Text", "children": [label]],
            ])
        }
        controller.render(screen(false, "Confirm both"))
        let toggle = try XCTUnwrap(find(UISwitch.self, key: "consent", below: controller.view))
        toggle.setOn(true, animated: true)
        toggle.sendActions(for: .valueChanged)
        controller.render(screen(true, "Ready"))
        XCTAssertTrue(toggle === find(UISwitch.self, key: "consent", below: controller.view))
        XCTAssertTrue(toggle.isOn)
        controller.render(screen(true, "Saving"))
        XCTAssertTrue(toggle.isOn)
        // A document refresh still clears consent when the script asks it to.
        controller.render(screen(false, "Read the updated documents"))
        XCTAssertFalse(toggle.isOn)
    }

    func testControlledSwitchDoesNotInterruptTheNativeTapAnimation() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        let screen: ([String: Any]) -> [String: Any] = { props in
            self.document([[
                "type": "Switch",
                "props": ["key": "consent", "value": props["value"] as Any],
                "events": ["onValueChange": "consentChanged"],
            ]])
        }

        controller.render(screen(["value": false]))
        let toggle = try XCTUnwrap(find(UISwitch.self, key: "consent", below: controller.view))
        toggle.setOn(true, animated: true)
        toggle.sendActions(for: .valueChanged)
        controller.render(screen(["value": true]))

        XCTAssertTrue(toggle.isOn)
        XCTAssertEqual(toggle.layer.animationKeys() ?? [], [], "the reconciliation must not add a second switch animation")
    }

    func testSwitchReceivesNativeTouchesWhenMountedInAFlowView() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = try hostWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        controller.render(document([[
            "type": "View",
            "props": ["key": "root"],
            "children": [["type": "Switch", "props": ["testID": "native-switch"]]],
        ]]))
        // Hit testing needs the same mounted, laid-out hierarchy as a real
        // screen. An unattached controller can still have a zero-sized root.
        controller.view.layoutIfNeeded()
        let toggle = try XCTUnwrap(find(UISwitch.self, key: "native-switch", below: controller.view))
        XCTAssertTrue(toggle.isUserInteractionEnabled)
        XCTAssertTrue(toggle.isEnabled)
        XCTAssertGreaterThan(toggle.bounds.width, 0)
        XCTAssertGreaterThan(toggle.bounds.height, 0)
        let point = toggle.convert(CGPoint(x: toggle.bounds.midX, y: toggle.bounds.midY), to: controller.view)
        XCTAssertTrue(controller.view.bounds.contains(point))
        let hit = controller.view.hitTest(point, with: nil)
        XCTAssertTrue(hit === toggle || hit?.isDescendant(of: toggle) == true)
    }

    func testUncontrolledSwitchKeepsItsNativeValueAcrossReconciliation() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        let screen = document([[
            "type": "Switch",
            "props": ["key": "uncontrolled-switch"],
        ]])
        controller.render(screen)
        let toggle = try XCTUnwrap(find(UISwitch.self, key: "uncontrolled-switch", below: controller.view))
        toggle.setOn(true, animated: false)
        controller.render(screen)
        XCTAssertTrue(toggle.isOn)
    }

    func testNativeControlAccessibilityKeepsInteractionTraitsWithoutAuthoredRoles() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([
            ["type": "Switch", "props": ["key": "toggle", "value": true]],
            ["type": "Slider", "props": ["key": "slider", "value": 0.5]],
            ["type": "Picker", "props": ["key": "picker", "items": [["label": "One", "value": "one"]]]],
            ["type": "DatePicker", "props": ["key": "date"]],
        ]))

        let toggle = try XCTUnwrap(find(UISwitch.self, key: "toggle", below: controller.view))
        let slider = try XCTUnwrap(find(UISlider.self, key: "slider", below: controller.view))
        let picker = try XCTUnwrap(find(UIPickerView.self, key: "picker", below: controller.view))
        let date = try XCTUnwrap(find(UIDatePicker.self, key: "date", below: controller.view))
        XCTAssertEqual(toggle.accessibilityTraits, UISwitch().accessibilityTraits)
        XCTAssertTrue(slider.accessibilityTraits.contains(.adjustable))
        let referencePicker = UIPickerView()
        XCTAssertEqual(picker.isAccessibilityElement, referencePicker.isAccessibilityElement)
        XCTAssertEqual(picker.accessibilityTraits, referencePicker.accessibilityTraits)
        XCTAssertEqual(picker.accessibilityContainerType, referencePicker.accessibilityContainerType)
        XCTAssertTrue(date.accessibilityTraits.contains(.adjustable))
    }

    func testTouchableAccessibilityInfersDestinationsAndPreservesAuthoredRoles() throws {
        for type in ["Pressable", "TouchableOpacity", "TouchableHighlight"] {
            let controller = CraftNativeScreenController(config: CraftConfig())
            controller.loadViewIfNeeded()
            controller.render(document([
                ["type": type, "props": ["key": "plain"]],
                ["type": type, "props": ["key": "linked", "href": "/details"]],
                ["type": type, "props": ["key": "authored", "href": "/details", "accessibilityRole": "button"]],
            ]))
            let plain = try XCTUnwrap(find(UIView.self, key: "plain", below: controller.view))
            let linked = try XCTUnwrap(find(UIView.self, key: "linked", below: controller.view))
            let authored = try XCTUnwrap(find(UIView.self, key: "authored", below: controller.view))
            XCTAssertTrue(plain.isAccessibilityElement)
            XCTAssertTrue(plain.accessibilityTraits.contains(.button))
            XCTAssertTrue(linked.accessibilityTraits.contains(.link))
            XCTAssertFalse(linked.accessibilityTraits.contains(.button))
            XCTAssertTrue(authored.accessibilityTraits.contains(.button))
            XCTAssertFalse(authored.accessibilityTraits.contains(.link))
            controller.render(document([
                ["type": type, "props": ["key": "plain", "to": "/details"]],
                ["type": type, "props": ["key": "linked"]],
                ["type": type, "props": ["key": "authored", "href": "/details", "accessibilityRole": "button"]],
            ]))
            XCTAssertTrue(plain === find(UIView.self, key: "plain", below: controller.view))
            XCTAssertTrue(plain.accessibilityTraits.contains(.link))
            XCTAssertTrue(linked.accessibilityTraits.contains(.button))
            XCTAssertFalse(linked.accessibilityTraits.contains(.link))
        }
    }

    func testListsExposeSharedListAccessibilityRoleWithoutOverridingAuthoredRoles() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([
            ["type": "FlatList", "props": ["key": "flat"]],
            ["type": "SectionList", "props": ["key": "section"]],
            ["type": "FlatList", "props": ["key": "authored", "accessibilityRole": "region"]],
        ]))

        let flat = try XCTUnwrap(find(UIView.self, key: "flat", below: controller.view))
        let section = try XCTUnwrap(find(UIView.self, key: "section", below: controller.view))
        let authored = try XCTUnwrap(find(UIView.self, key: "authored", below: controller.view))
        XCTAssertFalse(flat.isAccessibilityElement)
        XCTAssertFalse(section.isAccessibilityElement)
        XCTAssertEqual(authored.accessibilityContainerType, .none)
    }

    func testSwitchAccessibilityMatchesUIKitAcrossValueAndEnabledChanges() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        let reference = UISwitch()
        for (value, disabled) in [(false, false), (true, false), (true, true), (false, false)] {
            reference.isOn = value
            reference.isEnabled = !disabled
            controller.render(document([[
                "type": "Switch",
                "props": ["key": "native-toggle", "value": value, "disabled": disabled],
            ]]))
            let toggle = try XCTUnwrap(find(UISwitch.self, key: "native-toggle", below: controller.view))
            XCTAssertEqual(toggle.isOn, reference.isOn)
            XCTAssertEqual(toggle.isEnabled, reference.isEnabled)
            XCTAssertEqual(toggle.accessibilityTraits.rawValue, reference.accessibilityTraits.rawValue,
                           "Craft replaced the system switch's native accessibility identity")
        }
    }

    func testPickerBooleanValuesFallBackToTheirLabels() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.evaluateScript("globalThis.__picked = null; globalThis.__stxNativeCallback = function(json) { const message = JSON.parse(json); if (message.payload && message.payload.handlerName === 'picked') globalThis.__picked = message.payload.nativeEvent.value; };")
        controller.render(document([[
            "type": "Picker",
            "props": [
                "key": "boolean-picker",
                "items": [["label": "Boolean option", "value": true], ["label": "String option", "value": "string"]],
            ],
            "events": ["onValueChange": "picked"],
        ]]))

        let picker = try XCTUnwrap(find(UIPickerView.self, key: "boolean-picker", below: controller.view))
        controller.pickerView(picker, didSelectRow: 0, inComponent: 0)
        XCTAssertEqual(controller.evaluateScript("__picked")?.toString(), "Boolean option")
    }

    func testTheScriptHearsNewParamsAndTheScreenComingBack() throws {
        let controller = CraftNativeScreenController(config: CraftConfig(), routeName: "Messages", routeParams: ["person": "4"])
        controller.loadViewIfNeeded()
        controller.evaluateScript("globalThis.__heard = []; globalThis.__stxNativeCallback = function(json) { var m = JSON.parse(json); if (m.type === 'ROUTE_PARAMS' || m.type === 'SCREEN_FOCUS') __heard.push(m.type + ':' + (m.type === 'ROUTE_PARAMS' ? m.payload.params.person : m.payload.focused)); };")
        controller.receiveRouteParams(["person": "8", "path": "/m/messages?person=8"])
        XCTAssertEqual(controller.evaluateScript("__stxNativeParams.person")?.toString(), "8")
        // The first showing is the mount; after that, away and back are news.
        controller.screenVisibilityChanged(true)
        controller.screenVisibilityChanged(false)
        controller.screenVisibilityChanged(true)
        controller.screenVisibilityChanged(true)
        XCTAssertEqual(controller.evaluateScript("__heard.join('|')")?.toString(), "ROUTE_PARAMS:8|SCREEN_FOCUS:false|SCREEN_FOCUS:true")
    }

    /// The shell prepares an adjacent tab hidden, ahead of a swipe. That
    /// screen's script must not take itself to be in front: a prepared Record
    /// tab's sign-in guard pushed Login over the Feed at launch.
    func testAScreenPreparedHiddenIsToldSoAndItsFirstShowingIsNews() throws {
        let listen = "globalThis.__heard = []; globalThis.__stxNativeCallback = function(json) { var m = JSON.parse(json); if (m.type === 'SCREEN_FOCUS') __heard.push(String(m.payload.focused)); };"

        // Hidden before its script ran: the script reads it as it starts.
        let early = CraftNativeScreenController(config: CraftConfig(), routeName: "Record")
        early.screenVisibilityChanged(false)
        early.loadViewIfNeeded()
        XCTAssertEqual(early.evaluateScript("String(globalThis.__stxNativeFocused)")?.toString(), "false")
        early.evaluateScript(listen)
        early.screenVisibilityChanged(true)
        XCTAssertEqual(early.evaluateScript("__heard.join('|')")?.toString(), "true")

        // Hidden after its script ran: it hears so, then hears the showing.
        let prepared = CraftNativeScreenController(config: CraftConfig(), routeName: "Menu")
        prepared.loadViewIfNeeded()
        XCTAssertEqual(prepared.evaluateScript("String(globalThis.__stxNativeFocused)")?.toString(), "undefined")
        prepared.evaluateScript(listen)
        prepared.screenVisibilityChanged(false)
        prepared.screenVisibilityChanged(true)
        XCTAssertEqual(prepared.evaluateScript("__heard.join('|')")?.toString(), "false|true")
    }

    func testAVideoTakesItsSourceFromSrcToo() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([[
            "type": "Video", "props": ["key": "clip", "src": "https://example.com/a.mp4", "controls": true], "style": ["height": 200], "events": ["onEnd": "ended"]
        ]]))
        XCTAssertNotNil(find(UIView.self, key: "clip", below: controller.view))
    }

    func testNativeBadgeDoesNotDependOnNotificationCapability() async {
        XCTAssertTrue(CraftNativeActions.capabilities(config: CraftConfig()).contains("badge"))
        guard case .success = await capability("Badge", "set", [3]) else {
            return XCTFail("native badge set failed")
        }
        guard case .success = await capability("Badge", "clear") else {
            return XCTFail("native badge clear failed")
        }
        guard case .failure(let error) = await capability("Badge", "set", [-1]) else {
            return XCTFail("negative badge unexpectedly succeeded")
        }
        XCTAssertEqual(error.code, "INVALID_ARGUMENT")
    }

    func testASharedLinkIsCopiedAsTextAndSentAsALink() throws {
        let url = try XCTUnwrap(URL(string: "https://wildloop.org/trail/21"))
        let link = CraftShareLink(url: url, title: "Craggy Gardens Trail")
        let sheet = UIActivityViewController(activityItems: [link], applicationActivities: nil)
        // Copy: the address as text, which UIPasteboard.string and every
        // paste target read. A URL-only item there pastes as nothing.
        XCTAssertEqual(link.activityViewController(sheet, itemForActivityType: .copyToPasteboard) as? String, url.absoluteString)
        // Everywhere else it stays a URL, for the rich link preview.
        XCTAssertEqual(link.activityViewController(sheet, itemForActivityType: .message) as? URL, url)
        XCTAssertEqual(link.activityViewController(sheet, itemForActivityType: .airDrop) as? URL, url)
        XCTAssertEqual(link.activityViewController(sheet, itemForActivityType: nil) as? URL, url)
        XCTAssertEqual(link.activityViewControllerPlaceholderItem(sheet) as? URL, url)
    }

    func testDecodesStreamedTextAcrossSplitCharacters() {
        let bytes = Array("data: đ✓\n".utf8)
        let (first, rest) = CraftNativeEventStreams.decodeUTF8(Data(bytes[0..<7]))
        XCTAssertEqual(first, "data: ")
        let (second, tail) = CraftNativeEventStreams.decodeUTF8(rest + Data(bytes[7...]))
        XCTAssertEqual(first + second, "data: đ✓\n")
        XCTAssertTrue(tail.isEmpty)
    }
}

/// Shared stx controls must terminate in UIKit controls, rather than a picture
/// of one. Kept in the maintained native renderer fixture and exercised on iOS.
@MainActor
final class NativePlatformControlTests: XCTestCase {
    private func find<T: UIView>(_ type: T.Type, below view: UIView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.compactMap { find(type, below: $0) }.first
    }

    private func identified(_ id: String, below view: UIView) -> UIView? {
        if view.accessibilityIdentifier == id { return view }
        return view.subviews.lazy.compactMap { self.identified(id, below: $0) }.first
    }

    private func pagerDocument(index: Int, count: Int) -> [String: Any] {
        ["id": "pager", "type": "ScrollView",
         "props": ["key": "pager", "horizontal": true, "pagingEnabled": true, "pageIndex": index, "alwaysBounceHorizontal": false],
         "style": ["width": "100%", "height": 180],
         "events": ["onPageSelected": "page-selected"],
         "children": (0..<count).map { number in
            ["id": "page-\(number)", "type": "View", "props": ["key": "page-\(number)", "testID": "page-\(number)"],
             "style": ["width": 37, "height": 22],
             "children": [["type": "Text", "children": ["Page \(number + 1)"]]]] as [String: Any]
         }]
    }

    private func waitForPager(_ screen: CraftNativeScreenController, index: Int, count: Int) {
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            screen.evaluateScript("Boolean(pages.length && pages[pages.length - 1].index === \(index) && pages[pages.length - 1].count === \(count))")?.toBool() == true
        }, object: nil)
        wait(for: [settled], timeout: 3)
    }

    func testPagerUsesWholeViewportRetainsPagesAndResizesAtItsSelectedPage() throws {
        let screen = CraftNativeScreenController(config: CraftConfig())
        screen.loadViewIfNeeded()
        screen.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        screen.evaluateScript("globalThis.pages = []; globalThis.__stxNativeCallback = function(json) { const m = JSON.parse(json); if (m.type === 'EVENT' && m.payload.handlerName === 'page-selected') pages.push(m.payload.nativeEvent); };")
        screen.render(pagerDocument(index: 1, count: 3))
        screen.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(find(UIScrollView.self, below: screen.view))
        scroll.layoutIfNeeded()
        waitForPager(screen, index: 1, count: 3)
        XCTAssertTrue(scroll.isPagingEnabled)
        XCTAssertFalse(scroll.alwaysBounceHorizontal, "Restoring the pager axis must preserve authored bounce options")
        XCTAssertEqual(scroll.bounds.width, 320, accuracy: 0.5)
        XCTAssertEqual(scroll.contentSize.width, 3 * scroll.bounds.width, accuracy: 0.5)
        XCTAssertEqual(scroll.contentOffset.x, scroll.bounds.width, accuracy: 0.5)
        let pages = try (0..<3).map { try XCTUnwrap(identified("page-\($0)", below: scroll)) }
        for (index, page) in pages.enumerated() {
            XCTAssertEqual(page.frame.width, scroll.bounds.width, accuracy: 0.5, "Page must fill its viewport despite authored intrinsic width")
            XCTAssertEqual(page.frame.minX, CGFloat(index) * scroll.bounds.width, accuracy: 0.5)
            XCTAssertEqual(page.accessibilityElementsHidden, index != 1, "VoiceOver must not read off-screen pages")
        }
        let reported = screen.evaluateScript("pages.length")?.toInt32()
        screen.render(pagerDocument(index: 1, count: 3))
        screen.view.layoutIfNeeded()
        scroll.layoutIfNeeded()
        XCTAssertEqual(screen.evaluateScript("pages.length")?.toInt32(), reported, "Reconciliation is not a second page selection")
        XCTAssertTrue(pages[1] === identified("page-1", below: scroll))

        screen.view.frame.size.width = 480
        screen.view.setNeedsLayout()
        screen.view.layoutIfNeeded()
        scroll.layoutIfNeeded()
        XCTAssertEqual(scroll.bounds.width, 480, accuracy: 0.5)
        XCTAssertEqual(scroll.contentOffset.x, 480, accuracy: 0.5, "Rotation preserves the selected page")
        XCTAssertEqual(scroll.contentSize.width, 1440, accuracy: 0.5)
        XCTAssertEqual(pages[2].frame.width, 480, accuracy: 0.5)
        XCTAssertEqual(screen.evaluateScript("pages.length")?.toInt32(), reported, "Resizing is not another selection")
    }

    func testPagerControlledCommandsAndSettledNativeScrollClampAndDeduplicateEvents() throws {
        let screen = CraftNativeScreenController(config: CraftConfig())
        screen.loadViewIfNeeded()
        screen.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        screen.evaluateScript("globalThis.pages = []; globalThis.__stxNativeCallback = function(json) { const m = JSON.parse(json); if (m.type === 'EVENT' && m.payload.handlerName === 'page-selected') pages.push(m.payload.nativeEvent); };")
        screen.render(pagerDocument(index: 0, count: 3))
        screen.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(find(UIScrollView.self, below: screen.view))
        scroll.layoutIfNeeded()
        waitForPager(screen, index: 0, count: 3)
        screen.render(pagerDocument(index: 2, count: 3))
        screen.view.layoutIfNeeded()
        scroll.layoutIfNeeded()
        waitForPager(screen, index: 2, count: 3)
        XCTAssertEqual(scroll.contentOffset.x, scroll.bounds.width * 2, accuracy: 0.5)
        // UIKit supplies these settled callbacks after a drag. The UI fixture
        // separately proves an actual synthesized finger swipe reaches them.
        scroll.setContentOffset(CGPoint(x: scroll.bounds.width, y: 0), animated: false)
        screen.scrollViewDidEndDragging(scroll, willDecelerate: false)
        waitForPager(screen, index: 1, count: 3)
        let reports = screen.evaluateScript("pages.length")?.toInt32()
        screen.scrollViewDidEndDecelerating(scroll)
        scroll.delegate?.scrollViewDidEndScrollingAnimation?(scroll)
        XCTAssertEqual(screen.evaluateScript("pages.length")?.toInt32(), reports)
        XCTAssertFalse(try XCTUnwrap(identified("page-1", below: scroll)).accessibilityElementsHidden)
        XCTAssertTrue(try XCTUnwrap(identified("page-2", below: scroll)).accessibilityElementsHidden)
        screen.render(pagerDocument(index: 99, count: 1))
        screen.view.layoutIfNeeded()
        scroll.layoutIfNeeded()
        waitForPager(screen, index: 0, count: 1)
        XCTAssertEqual(scroll.contentOffset.x, 0, accuracy: 0.5)
        XCTAssertNil(identified("page-1", below: scroll))
        screen.render(pagerDocument(index: -1, count: 0))
        screen.view.layoutIfNeeded()
        scroll.layoutIfNeeded()
        waitForPager(screen, index: 0, count: 0)
        XCTAssertEqual(scroll.contentSize.width, 0, accuracy: 0.5)
    }

    func testPagerReconciliationDuringAnimationDoesNotPublishAnIntermediatePage() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        let screen = CraftNativeScreenController(config: CraftConfig())
        window.rootViewController = screen
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        screen.evaluateScript("globalThis.pages = []; globalThis.__stxNativeCallback = function(json) { const m = JSON.parse(json); if (m.type === 'EVENT' && m.payload.handlerName === 'page-selected') pages.push(m.payload.nativeEvent); };")
        screen.render(pagerDocument(index: 0, count: 3))
        screen.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(find(UIScrollView.self, below: screen.view))
        scroll.layoutIfNeeded()
        waitForPager(screen, index: 0, count: 3)
        let before = screen.evaluateScript("pages.length")?.toInt32()
        XCTAssertTrue(UIView.areAnimationsEnabled)
        XCTAssertFalse(UIAccessibility.isReduceMotionEnabled, "The maintained fixture keeps animations enabled")
        screen.render(pagerDocument(index: 2, count: 3))
        screen.view.layoutIfNeeded()
        scroll.layoutIfNeeded()
        let deadline = Date().addingTimeInterval(3)
        func isBetweenPages() -> Bool { scroll.contentOffset.x > 1 && scroll.contentOffset.x < scroll.bounds.width * 2 - 1 }
        while !isBetweenPages() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(isBetweenPages(), "The real UIKit scroll must be observed during its animation")
        // An unrelated update while UIKit animates still carries the same
        // controlled target. It must not adopt the in-between viewport.
        screen.render(pagerDocument(index: 2, count: 3))
        screen.view.layoutIfNeeded()
        scroll.layoutIfNeeded()
        XCTAssertEqual(screen.evaluateScript("pages.length")?.toInt32(), before)
        XCTAssertEqual(screen.evaluateScript("pages[pages.length - 1].index")?.toInt32(), 0)
        waitForPager(screen, index: 2, count: 3)
        XCTAssertEqual(screen.evaluateScript("pages.length")?.toInt32(), (before ?? 0) + 1)
        XCTAssertEqual(scroll.contentOffset.x, scroll.bounds.width * 2, accuracy: 0.5)
    }

    func testCSSGenericFontFallbacksProduceNativeFamiliesAndPreserveTraits() throws {
        let screen = CraftNativeScreenController(config: CraftConfig())
        screen.loadViewIfNeeded()
        func font(_ family: String, type: String = "Text", weight: String = "700", italic: Bool = true) throws -> UIFont {
            screen.render(["type": type, "props": ["key": "sample", "value": "111 WWW"],
                "style": ["fontFamily": family, "fontWeight": weight, "fontStyle": italic ? "italic" : "normal", "fontSize": 19],
                "children": ["111 WWW"]])
            if type == "TextInput" { return try XCTUnwrap(find(UITextField.self, below: screen.view)?.font) }
            return try XCTUnwrap(find(UILabel.self, below: screen.view)?.font)
        }
        for family in ["monospace", "ui-monospace", "'Definitely Missing Font', ui-monospace, serif"] {
            for type in ["Text", "TextInput"] {
                let actual = try font(family, type: type)
                XCTAssertTrue(actual.fontDescriptor.symbolicTraits.contains(.traitMonoSpace), family)
                XCTAssertTrue(actual.fontDescriptor.symbolicTraits.contains(.traitBold), family)
                XCTAssertTrue(actual.fontDescriptor.symbolicTraits.contains(.traitItalic), family)
                XCTAssertGreaterThan(actual.pointSize, 0)
            }
        }
        let sans = try font("system-ui", italic: false)
        XCTAssertFalse(sans.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        let serif = try font("'Missing Font', ui-serif", italic: false)
        XCTAssertNotEqual(serif.familyName, sans.familyName)
        let custom = try XCTUnwrap(UIFont(name: "Helvetica", size: 19))
        for type in ["Text", "TextInput"] {
            let selected = try font("Helvetica, monospace", type: type)
            XCTAssertEqual(selected.familyName, custom.familyName, "First available custom family wins over generic fallback: \(type)")
            XCTAssertTrue(selected.fontDescriptor.symbolicTraits.contains(.traitBold), type)
            XCTAssertTrue(selected.fontDescriptor.symbolicTraits.contains(.traitItalic), type)
        }
    }

    func testSegmentsAreUIKitControlsAndReconcileWithoutFalseChanges() throws {
        let screen = CraftNativeScreenController(config: CraftConfig())
        screen.loadViewIfNeeded()
        screen.evaluateScript("globalThis.changes = []; globalThis.__stxNativeCallback = function(json) { const m = JSON.parse(json); if (m.type === 'EVENT') changes.push(m.payload.nativeEvent.value); };")
        func document(_ value: String, _ items: [[String: Any]]) -> [String: Any] {
            ["type": "SegmentedControl", "props": ["key": "period", "accessibilityLabel": "Period", "value": value, "items": items], "events": ["onValueChange": "selected"], "style": ["height": 32, "color": "#123456"]]
        }
        let items: [[String: Any]] = [["value": "day", "label": "Day"], ["value": "week", "label": "Week", "spoken": "This week, seven days"], ["value": "month", "label": "Month", "disabled": true]]
        screen.render(document("day", items))
        let control = try XCTUnwrap(find(UISegmentedControl.self, below: screen.view))
        XCTAssertEqual(control.numberOfSegments, 3)
        XCTAssertEqual(control.selectedSegmentIndex, 0)
        XCTAssertFalse(control.isEnabledForSegment(at: 2))
        XCTAssertTrue(control.isUserInteractionEnabled)
        XCTAssertEqual(screen.evaluateScript("changes.length")?.toInt32(), 0)
        XCTAssertFalse(control.isAccessibilityElement, "A labelled group must not hide its individual segments")
        let accessible = try XCTUnwrap(control.accessibilityElements as? [UIAccessibilityElement])
        XCTAssertEqual(accessible[1].accessibilityLabel, "This week, seven days")
        XCTAssertTrue(accessible[0].accessibilityTraits.contains(.selected))
        XCTAssertTrue(accessible[2].accessibilityTraits.contains(.notEnabled))
        XCTAssertFalse(accessible[2].accessibilityActivate())
        XCTAssertTrue(accessible[1].accessibilityActivate())
        XCTAssertTrue(accessible[1].accessibilityTraits.contains(.selected))
        XCTAssertFalse(accessible[0].accessibilityTraits.contains(.selected))
        XCTAssertEqual(screen.evaluateScript("changes.join('|')")?.toString(), "week")
        screen.render(document("week", [["value": "week", "label": "This week"], ["value": "all", "label": "All time"]]))
        XCTAssertTrue(control === find(UISegmentedControl.self, below: screen.view))
        XCTAssertEqual(control.numberOfSegments, 2)
        XCTAssertEqual(control.titleForSegment(at: 0), "This week")
        XCTAssertEqual(control.selectedSegmentIndex, 0)
        XCTAssertEqual(screen.evaluateScript("changes.length")?.toInt32(), 1)
        screen.render(document("", [["value": "", "label": "Any day"], ["value": "week", "label": "Week"]]))
        XCTAssertEqual(control.selectedSegmentIndex, 0, "An empty string is a valid shared option value")
    }

    func testNativeClearEditsTheFieldExactlyOnce() throws {
        let screen = CraftNativeScreenController(config: CraftConfig())
        screen.loadViewIfNeeded()
        screen.evaluateScript("globalThis.edits = []; globalThis.__stxNativeCallback = function(json) { const m = JSON.parse(json); if (m.type === 'EVENT') edits.push(m.payload.nativeEvent); };")
        screen.render(["type": "TextInput", "props": ["value": "Training", "clearButtonMode": "while-editing"], "events": ["onChangeText": "edited"]])
        let input = try XCTUnwrap(find(UITextField.self, below: screen.view))
        XCTAssertEqual(input.clearButtonMode, .whileEditing)
        XCTAssertFalse(screen.textFieldShouldClear(input))
        XCTAssertEqual(input.text, "")
        XCTAssertEqual(screen.evaluateScript("edits.length")?.toInt32(), 1)
        XCTAssertEqual(screen.evaluateScript("edits[0].text")?.toString(), "")
        XCTAssertEqual(screen.evaluateScript("edits[0].clear")?.toBool(), true)
        screen.render(["type": "TextInput", "props": ["value": ""], "events": ["onChangeText": "edited"]])
        XCTAssertEqual(input.clearButtonMode, .never, "A retained input forgets a removed affordance")
    }

    func testPageSheetUsesSystemDetentsAndDismissesWithTheOwner() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let screen = CraftNativeScreenController(config: CraftConfig())
        window.rootViewController = screen
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func document(_ visible: Bool) -> [String: Any] {
            ["type": "Modal", "props": ["key": "sheet", "visible": visible, "animationType": "none", "presentationStyle": "pageSheet", "sheetDetents": ["medium", "large"], "selectedDetent": "medium"], "events": ["onRequestClose": "closed"], "children": [["type": "TextInput", "props": ["key": "sheet-field", "value": "Hello"], "style": ["height": 44]]]]
        }
        screen.render(document(true))
        let presented = expectation(description: "UIKit presents the native sheet")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { presented.fulfill() }
        wait(for: [presented], timeout: 3)
        let controller = try XCTUnwrap(screen.presentedViewController)
        let sheet = try XCTUnwrap(controller.sheetPresentationController)
        XCTAssertEqual(sheet.detents.map(\.identifier), [.medium, .large])
        XCTAssertEqual(sheet.selectedDetentIdentifier, .medium)
        XCTAssertTrue(sheet.prefersGrabberVisible)
        XCTAssertFalse(controller.isModalInPresentation)
        let input = try XCTUnwrap(find(UITextField.self, below: controller.view))
        XCTAssertEqual(input.text, "Hello")
        XCTAssertNotNil(input.craftScreenController, "Input services still resolve their owning screen inside the sheet")
        screen.render(document(false))
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in screen.presentedViewController == nil }, object: nil)
        wait(for: [dismissed], timeout: 3)
        XCTAssertNil(screen.presentedViewController)
    }
}

@MainActor
final class NativeTypingEventTests: XCTestCase {
    private func find<T: UIView>(_ type: T.Type, below view: UIView) -> T? {
        if let found = view as? T { return found }
        return view.subviews.lazy.compactMap { self.find(type, below: $0) }.first
    }

    func testDelayedControlledEchoCannotEraseLaterEditsButCurrentResetCan() throws {
        let previousThread = CraftNativeScriptThread.isBackground
        defer { CraftNativeScriptThread.isBackground = previousThread }
        for background in [false, true] {
            CraftNativeScriptThread.isBackground = background
            let screen = CraftNativeScreenController(config: CraftConfig())
            screen.loadViewIfNeeded()
            screen.evaluateScript("globalThis.edits = []; globalThis.__stxNativeCallback = function(json) { const m = JSON.parse(json); if (m.type === 'EVENT') edits.push(m.payload.nativeEvent); };")
            func document(_ value: String, _ count: Int) -> [String: Any] {
                ["type": "TextInput", "props": ["key": "search", "value": value, "mostRecentEventCount": count], "events": ["onChangeText": "typed"]]
            }
            screen.render(document("", 0))
            let input = try XCTUnwrap(find(UITextField.self, below: screen.view))
            for value in ["P", "Pl", "Pla"] { input.text = value; input.sendActions(for: .editingChanged) }
            // Pl was valid when sent, but Pla was already typed before it arrived.
            screen.render(document("Pl", 2))
            XCTAssertEqual(input.text, "Pla", "An older controlled echo erased an accepted character")
            input.text = (input.text ?? "") + "n"
            input.sendActions(for: .editingChanged)
            screen.render(document("Pla", 3))
            XCTAssertEqual(input.text, "Plan")
            input.text = (input.text ?? "") + "e"
            input.sendActions(for: .editingChanged)
            screen.render(document("Plane", 5))
            let start = try XCTUnwrap(input.position(from: input.beginningOfDocument, offset: 1))
            let end = try XCTUnwrap(input.position(from: input.beginningOfDocument, offset: 3))
            input.selectedTextRange = input.textRange(from: start, to: end)
            screen.render(document("Plan", 4))
            XCTAssertEqual(input.text, "Plane", "A late echo stays stale after the latest acknowledgement")
            XCTAssertEqual(input.selectedTextRange.map { input.offset(from: input.beginningOfDocument, to: $0.start) }, 1)
            XCTAssertEqual(input.selectedTextRange.map { input.offset(from: input.beginningOfDocument, to: $0.end) }, 3)
            XCTAssertEqual(screen.evaluateScript("edits.map(e => e.text).join('|')")?.toString(), "P|Pl|Pla|Plan|Plane")
            XCTAssertEqual(screen.evaluateScript("edits.map(e => e.eventCount).join('|')")?.toString(), "1|2|3|4|5")
            screen.render(document("", 5))
            XCTAssertEqual(input.text, "", "An intentional current reset must still apply")
            screen.render(document("Plan", 5))
            XCTAssertEqual(input.text, "Plan", "A current external value may equal earlier typed text")
        }
    }

    func testMultilineUsesTheSameAcknowledgementBoundary() throws {
        let screen = CraftNativeScreenController(config: CraftConfig())
        screen.loadViewIfNeeded()
        func document(_ value: String, _ count: Int) -> [String: Any] {
            ["type": "TextInput", "props": ["key": "notes", "multiline": true, "value": value, "mostRecentEventCount": count], "events": ["onChangeText": "typed"]]
        }
        screen.render(document("", 0))
        let input = try XCTUnwrap(find(UITextView.self, below: screen.view))
        input.text = "Pl"; screen.textViewDidChange(input)
        input.text = "Pla"; screen.textViewDidChange(input)
        screen.render(document("Pl", 1))
        XCTAssertEqual(input.text, "Pla")
        screen.render(document("", 2))
        XCTAssertEqual(input.text, "")
    }

    func testLegacyRuntimeEchoProtectionAlsoAppliesOnTheMainScriptThread() throws {
        let previousThread = CraftNativeScriptThread.isBackground
        CraftNativeScriptThread.isBackground = false
        defer { CraftNativeScriptThread.isBackground = previousThread }
        let screen = CraftNativeScreenController(config: CraftConfig())
        screen.loadViewIfNeeded()
        func document(_ value: String) -> [String: Any] {
            ["type": "TextInput", "props": ["key": "legacy", "value": value], "events": ["onChangeText": "typed"]]
        }
        screen.render(document(""))
        let input = try XCTUnwrap(find(UITextField.self, below: screen.view))
        input.text = "Pl"; input.sendActions(for: .editingChanged)
        input.text = "Pla"; input.sendActions(for: .editingChanged)
        screen.render(document("Pl"))
        XCTAssertEqual(input.text, "Pla")
        screen.render(document("Reset"))
        XCTAssertEqual(input.text, "Reset")
    }
}
