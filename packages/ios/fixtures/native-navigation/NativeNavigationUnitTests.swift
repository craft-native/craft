import UIKit
import XCTest
@testable import NativeNavigation

/// Drive the real UIKit gesture target and inspect the hosted native stacks,
/// including frames while the finger is down. UI tests cover touch routing.
@MainActor
final class NativeNavigationUnitTests: XCTestCase {
    @available(iOS 16.1, *)
    func testActivityTransitionsCatchUpWithoutThePlayerAndStopAtCompletion() {
        var state = CraftActivityAttributes.ContentState(status: "Training", distanceMeters: 0, durationSeconds: 0, progress: 0)
        state.detail = "Leg cradles"
        var timeline = CraftActivityTimeline(pending: [
            .init(at: 1000, detail: "Lunges", duration: 20),
            .init(at: 21000, detail: "Squats", duration: 30),
            .init(at: 51000, detail: "Complete", duration: 0),
        ])
        timeline.advance(&state, to: 25000)
        XCTAssertEqual(state.detail, "Squats")
        XCTAssertEqual(state.timerEndsAt, 51000)
        XCTAssertEqual(state.remainingSeconds, 26)
        XCTAssertEqual(timeline.pending.count, 1)
        timeline.advance(&state, to: 60000)
        XCTAssertEqual(state.detail, "Complete")
        XCTAssertEqual(state.paused, true)
        XCTAssertEqual(state.remainingSeconds, 0)
        XCTAssertTrue(timeline.pending.isEmpty)
    }

    @available(iOS 16.1, *)
    func testLongActivityPlanNeverGrowsTheLockScreenPayload() throws {
        var state = CraftActivityAttributes.ContentState(status: "Training", distanceMeters: 0, durationSeconds: 0, progress: 0)
        var timeline = CraftActivityTimeline(pending: (1...100).map {
            .init(at: Double($0 * 30000), detail: "Exercise \($0)", duration: 30)
        })
        timeline.advance(&state, to: 1805000)
        XCTAssertEqual(state.detail, "Exercise 60")
        XCTAssertEqual(state.timerEndsAt, 1830000)
        XCTAssertEqual(timeline.pending.count, 40)
        let payload = try JSONEncoder().encode(state)
        XCTAssertLessThan(payload.count, 1024)
        XCTAssertFalse(String(data: payload, encoding: .utf8)!.contains("Exercise 61"))
    }

    private final class Pan: UIPanGestureRecognizer {
        var phase: UIGestureRecognizer.State = .changed
        var distance: CGFloat = 0
        var speed: CGFloat = 0
        override var state: UIGestureRecognizer.State {
            get { phase }
            set { phase = newValue }
        }
        override func translation(in view: UIView?) -> CGPoint { CGPoint(x: distance, y: 0) }
        override func velocity(in view: UIView?) -> CGPoint { CGPoint(x: speed, y: 0) }
    }

    @MainActor
    private final class DisplayWait: NSObject {
        private let ready: () -> Bool
        private let finished: XCTestExpectation
        private var link: CADisplayLink?
        init(ready: @escaping () -> Bool, finished: XCTestExpectation) {
            self.ready = ready
            self.finished = finished
            super.init()
        }
        func start() {
            link = CADisplayLink(target: self, selector: #selector(frame))
            link?.add(to: .main, forMode: .common)
        }
        @objc private func frame() {
            if ready() { stop(); finished.fulfill() }
        }
        func stop() { link?.invalidate(); link = nil }
    }

    private var shell: CraftHybridController!
    private var window: UIWindow!
    private var previous: CraftHybridController?
    private var previousWindow: UIWindow?
    private var selection: String?
    private let pan = Pan()

    override func setUp() async throws {
        try await super.setUp()
        await displayWait("native host window connected") {
            CraftHybrid.shared.controller?.viewIfLoaded?.window?.windowScene != nil
        }
        previous = CraftHybrid.shared.controller
        previousWindow = previous?.view.window
        selection = CraftChrome.shared.selected
        CraftChrome.shared.selected = "/"
        // A screen going away leaves its accessory drawn for the next one to
        // decide (0.0.263), so a test starts from no accessory rather than
        // the last test's.
        CraftChrome.shared.updateTabAccessory(nil)
        shell = CraftHybridController(config: CraftHybrid.shared.config)
        let scene = previousWindow?.windowScene
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        if let scene {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        }
        window.rootViewController = shell
        window.makeKeyAndVisible()
        XCTAssertNotNil(window.windowScene, "hosted UIKit tests need a connected scene")
        shell.view.frame = window.bounds
        shell.view.layoutIfNeeded()
    }

    override func tearDown() {
        if let shell { _ = shell.tabTapped("/", reselect: false) }
        window?.isHidden = true
        window?.rootViewController = nil
        shell = nil
        window = nil
        CraftHybrid.shared.controller = previous
        CraftChrome.shared.selected = selection
        CraftChrome.shared.updateTabAccessory(nil)
        previous = nil
        previousWindow?.makeKeyAndVisible()
        previousWindow = nil
        super.tearDown()
    }

    func testAccessorySelectionTracksDestinationWithoutSelectingAnOwningTab() {
        let chrome = CraftChrome.shared
        chrome.selected = "/"
        chrome.updateTabAccessory(["path": "/messages", "title": "Messages", "symbol": "bubble.left"])
        defer { chrome.visiblePath = nil; chrome.updateTabAccessory(nil) }
        chrome.visiblePath = "/messages"
        XCTAssertTrue(chrome.accessorySelected)
        XCTAssertNil(chrome.highlightedTab)
        XCTAssertEqual(chrome.selected, "/", "the underlying stack remains available for Back")
        chrome.visiblePath = "/messages/42"
        XCTAssertTrue(chrome.accessorySelected)
        chrome.visiblePath = "/messages-other"
        XCTAssertFalse(chrome.accessorySelected)
        XCTAssertEqual(chrome.highlightedTab, "/")
        chrome.visiblePath = "/"
        XCTAssertFalse(chrome.accessorySelected)
    }

    private func drag(_ distance: CGFloat, phase: UIGestureRecognizer.State = .changed, speed: CGFloat = 0) {
        pan.distance = distance
        pan.speed = speed
        pan.phase = phase
        shell.perform(NSSelectorFromString("tabSwipeRecognized:"), with: pan)
    }

    private func stack(_ path: String) -> UINavigationController? {
        shell.children.compactMap { $0 as? UINavigationController }.first {
            ($0.viewControllers.first as? CraftNativeScreenController)?.routeParams["path"] as? String == path
        }
    }

    func testColdLinkWaitsForTheConstructedShellToLoadItsStacks() async throws {
        let earlyShell = CraftHybridController(config: CraftHybrid.shared.config)
        XCTAssertFalse(earlyShell.isViewLoaded)
        defer {
            window.rootViewController = shell
            CraftHybrid.shared.controller = shell
        }

        let url = try XCTUnwrap(URL(string: "https://example.com/linked-details?name=Cold"))
        XCTAssertTrue(CraftHybrid.shared.handleDeepLink(url))
        window.rootViewController = earlyShell
        earlyShell.view.frame = window.bounds
        earlyShell.view.layoutIfNeeded()

        await displayWait("the cold link reaches its screen after the shell mounts") {
            earlyShell.children.compactMap { $0 as? UINavigationController }.contains {
                guard let screen = $0.topViewController as? CraftNativeScreenController else { return false }
                return screen.routeParams["path"] as? String == "/linked-details?name=Cold"
                    && screen.routeParams["name"] as? String == "Cold"
            }
        }
    }

    private func displayWait(_ description: String, diagnostic: @escaping () -> String = { "" }, ready: @escaping () -> Bool) async {
        let finished = expectation(description: description)
        let display = DisplayWait(ready: ready, finished: finished)
        display.start()
        let result = await XCTWaiter.fulfillment(of: [finished], timeout: 15)
        display.stop()
        XCTAssertEqual(result, .completed, "\(description): \(diagnostic())")
    }

    private func renderFrames() async {
        CATransaction.flush()
        var frames = 0
        await displayWait("native frames rendered") { frames += 1; return frames >= 2 }
    }

    /// The settle a second swipe catches, slowed so a loaded simulator's
    /// frames cannot outlast it before the catch: layer time runs at a
    /// twentieth until the test puts it back (each test has its own shell).
    private func catchableSettle() {
        shell.view.layer.speed = 0.05
    }

    private func settle() async {
        await displayWait("native settle animation completed", diagnostic: { [self] in
            shell.children.compactMap { $0 as? UINavigationController }.map {
                "frame=\($0.view.frame), expected=\(shell.view.bounds), hidden=\($0.view.isHidden), animations=\($0.view.layer.animationKeys() ?? [])"
            }.joined(separator: "; ")
        }) { [self] in
            shell.children.compactMap { $0 as? UINavigationController }.allSatisfy {
                let frame = $0.view.frame
                let bounds = shell.view.bounds
                return abs(frame.minX - bounds.minX) <= 0.5 && abs(frame.minY - bounds.minY) <= 0.5
                    && abs(frame.width - bounds.width) <= 0.5 && abs(frame.height - bounds.height) <= 0.5
                    && ($0.view.layer.animationKeys()?.isEmpty ?? true)
            }
        }
        await renderFrames()
    }

    private func attachFrame(_ name: String) {
        let image = UIGraphicsImageRenderer(bounds: shell.view.bounds).image { shell.view.layer.render(in: $0.cgContext) }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func mountDetails() {
        _ = shell.tabTapped("/details", reselect: false)
        _ = shell.tabTapped("/", reselect: false)
        CraftChrome.shared.selected = "/"
    }

    func testVerticalNativeScrollDoesNotPreventTheHorizontalTabGesture() throws {
        _ = shell.tabTapped("/details", reselect: false)
        let details = try XCTUnwrap(stack("/details"))
        details.view.layoutIfNeeded()
        func scroll(in view: UIView) -> UIScrollView? {
            if view.accessibilityIdentifier == "people-list" { return view as? UIScrollView }
            return view.subviews.lazy.compactMap { scroll(in: $0) }.first
        }
        let people = try XCTUnwrap(scroll(in: details.view))
        let tabPan = try XCTUnwrap(shell.view.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
        XCTAssertFalse(people.alwaysBounceHorizontal)
        XCTAssertLessThanOrEqual(people.contentSize.width, people.bounds.width + 1)
        XCTAssertTrue(shell.gestureRecognizer(tabPan, shouldRecognizeSimultaneouslyWith: people.panGestureRecognizer),
                      "the vertical list's pan must not win the horizontal tab gesture")
        people.alwaysBounceHorizontal = true
        XCTAssertFalse(shell.gestureRecognizer(tabPan, shouldRecognizeSimultaneouslyWith: people.panGestureRecognizer),
                       "a horizontal scroller must keep its own gesture")
    }

    func testNativeLinkRetainsItsTapRecognizerAcrossUnrelatedUpdates() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        func document(_ count: Int, enabled: Bool = true) -> [String: Any] {
            ["type": "View", "children": [
                ["type": "TouchableOpacity", "props": ["testID": "link-probe", "href": "/linked-details", "accessibilityLabel": "Open details", "disabled": !enabled],
                 "children": [["type": "Text", "children": ["Open details"]]]],
                ["type": "Text", "props": ["testID": "unrelated-count"], "children": ["Count: \(count)"]],
            ]]
        }
        func find(_ view: UIView) -> UIView? {
            if view.accessibilityIdentifier == "link-probe" { return view }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        controller.render(document(0))
        let link = try XCTUnwrap(find(controller.view))
        XCTAssertTrue(link.accessibilityTraits.contains(.link), "an href-bearing pressable should be exposed as a link")
        for count in 1...4 {
            controller.render(document(count))
            XCTAssertTrue(find(controller.view) === link, "a count update replaced the native link")
            XCTAssertEqual(link.gestureRecognizers?.filter { $0 is UITapGestureRecognizer }.count, 1,
                           "an unrelated screen update removed or duplicated the native link's tap recognizer")
            XCTAssertTrue(link.isUserInteractionEnabled)
        }
        controller.render(document(5, enabled: false))
        XCTAssertEqual(link.gestureRecognizers?.filter { $0 is UITapGestureRecognizer }.count ?? 0, 0)
        controller.render(document(6))
        XCTAssertEqual(link.gestureRecognizers?.filter { $0 is UITapGestureRecognizer }.count, 1)
    }

    func testSelectableTextUsesNativeSelectionControl() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render([
            "type": "View",
            "children": [[
                "type": "Text",
                "props": ["testID": "selectable-text", "selectable": true],
                "children": ["Copy me"],
            ]],
        ])
        controller.view.layoutIfNeeded()

        func find(_ view: UIView) -> UIView? {
            if view.accessibilityIdentifier == "selectable-text" { return view }
            return view.subviews.lazy.compactMap { find($0) }.first
        }

        let text = try XCTUnwrap(find(controller.view) as? UITextView)
        XCTAssertTrue(text.isSelectable)
        XCTAssertFalse(text.isEditable)
        XCTAssertFalse(text.isScrollEnabled)
    }

    func testKeyedRowButtonKeepsItsNativeHitTargetAndDispatchAfterInputReordersRows() async throws {
        let home = try XCTUnwrap(stack("/"))
        let screen = try XCTUnwrap(home.topViewController as? CraftNativeScreenController)
        func find(_ id: String, in view: UIView) -> UIView? {
            if view.accessibilityIdentifier == id { return view }
            return view.subviews.lazy.compactMap { find(id, in: $0) }.first
        }
        await displayWait("keyed input mounted") { find("navigation-input-b", in: screen.view) != nil }
        let input = try XCTUnwrap(find("navigation-input-b", in: screen.view) as? UITextField)
        XCTAssertTrue(input.becomeFirstResponder())
        input.text = "draft"
        input.sendActions(for: .editingChanged)
        await displayWait("input-driven keyed reorder") {
            find("navigation-input-c", in: screen.view) != nil
        }
        XCTAssertTrue(input === find("navigation-input-b", in: screen.view))
        let button = try XCTUnwrap(find("navigation-select-b", in: screen.view) as? UIButton)
        let scroll = try XCTUnwrap(find("native-root-scroll", in: screen.view) as? UIScrollView)
        // Becoming first responder animates the scroll view's bounds. During
        // that transition UIKit legitimately keeps the scroll view as the hit
        // target. Sample the retained button after the native geometry settles.
        await displayWait("keyed row keyboard geometry settled", diagnostic: {
            "bounds=\(scroll.bounds), animations=\(scroll.layer.animationKeys() ?? [])"
        }) {
            screen.view.layoutIfNeeded()
            return scroll.layer.animationKeys()?.isEmpty ?? true
        }
        scroll.scrollRectToVisible(button.convert(button.bounds, to: scroll), animated: false)
        window.layoutIfNeeded()
        await renderFrames()
        let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: window)
        let hit = window.hitTest(point, with: nil)
        XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true,
                      "The retained button's visible center hit \(String(describing: hit)) at \(point), button frame \(button.frame)")
        button.sendActions(for: .touchUpInside)
        await displayWait("retained row button callback") {
            (find("keyed-list-status", in: screen.view) as? UILabel)?.text == "Selected: b"
        }
    }

    func testRepeatedSelectorsRetainDistinctProtocolViewsAcrossReorders() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        window.rootViewController = controller
        controller.loadViewIfNeeded()
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        func document(_ ids: [String]) -> [String: Any] {
            ["id": "identity-root", "type": "View", "children": ids.map { id in
                ["id": "row-\(id)", "type": "View", "props": ["testID": "repeated-row"],
                 "children": [["id": "input-\(id)", "type": "TextInput", "props": ["testID": "repeated-input", "accessibilityLabel": "\(id) draft"]]]]
            }]
        }
        func matching(_ view: UIView, _ id: String) -> [UIView] {
            (view.accessibilityIdentifier == id ? [view] : []) + view.subviews.flatMap { matching($0, id) }
        }
        controller.render(document(["alpha", "beta"]))
        controller.view.layoutIfNeeded()
        let original = matching(controller.view, "repeated-row")
        XCTAssertEqual(original.count, 2)
        guard original.count == 2 else { return }
        let alpha = original[0]
        let beta = original[1]
        let betaInput = try XCTUnwrap(matching(beta, "repeated-input").first as? UITextField)
        XCTAssertTrue(betaInput.becomeFirstResponder())
        betaInput.text = "Beta private draft"
        betaInput.sendActions(for: .editingChanged)
        controller.render(document(["beta", "alpha"]))
        controller.view.layoutIfNeeded()
        let reordered = matching(controller.view, "repeated-row")
        XCTAssertEqual(reordered.count, 2)
        guard reordered.count == 2 else { return }
        XCTAssertTrue(reordered[0] === beta, "the repeated selector overrode Beta's protocol identity")
        XCTAssertTrue(reordered[1] === alpha, "the repeated selector overrode Alpha's protocol identity")
        XCTAssertTrue(matching(reordered[0], "repeated-input").first === betaInput)
        XCTAssertEqual(betaInput.text, "Beta private draft")
        XCTAssertTrue(betaInput.isFirstResponder, "reordering replaced the focused native input")
    }

    func testIdlePreparationKeepsSelectionAndCurrentStackIntact() async throws {
        let home = try XCTUnwrap(stack("/"))
        let root = home.topViewController
        await displayWait("adjacent native root prepared while idle") { self.stack("/details") != nil }
        let prepared = try XCTUnwrap(stack("/details"))
        XCTAssertTrue(prepared.view.isHidden)
        XCTAssertFalse(home.view.isHidden)
        XCTAssertTrue(home.topViewController === root)
        XCTAssertEqual(CraftChrome.shared.selected, "/")
        XCTAssertEqual(prepared.view.bounds.size, home.view.bounds.size)
        drag(-150)
        XCTAssertTrue(stack("/details") === prepared)
        drag(-150, phase: .cancelled)
        await settle()
        XCTAssertFalse(home.view.isHidden)
        XCTAssertEqual(CraftChrome.shared.selected, "/")
    }

    private func checkPreparedGuard(background: Bool, coldSwipe: Bool) async throws {
        let originalBackground = CraftNativeScriptThread.isBackground
        CraftNativeScriptThread.isBackground = background
        defer {
            CraftChrome.shared.configure(tabs: CraftHybrid.shared.config.tabs ?? [], selected: "/", splash: false)
            CraftNativeScriptThread.queue.sync {}
            CraftNativeScriptThread.isBackground = originalBackground
        }
        CraftChrome.shared.configure(tabs: [
            CraftConfig.Tab(id: "/", title: "Home"),
            CraftConfig.Tab(id: "/guarded", title: "Guarded"),
        ], selected: "/", splash: false)
        shell = CraftHybridController(config: CraftHybrid.shared.config)
        window.rootViewController = shell
        shell.view.frame = window.bounds
        shell.view.layoutIfNeeded()
        let home = try XCTUnwrap(stack("/"))
        if coldSwipe {
            XCTAssertNil(stack("/guarded"))
            drag(-150)
        } else {
            await displayWait("guarded tab prepared while idle") { self.stack("/guarded") != nil }
        }
        let guarded = try XCTUnwrap(stack("/guarded"))
        let screen = try XCTUnwrap(guarded.viewControllers.first as? CraftNativeScreenController)
        await displayWait("compiled hidden guard mounted") {
            screen.evaluateScript("typeof globalThis.__detailsFocusAtMount")?.toString() == "boolean"
        }
        XCTAssertEqual(screen.evaluateScript("__detailsFocusAtMount")?.toBool(), false)
        XCTAssertEqual(screen.evaluateScript("craft.navigation.isFocused()")?.toBool(), false)
        XCTAssertEqual(home.viewControllers.count, 1, "preparation must not push Login's equivalent over Home")
        XCTAssertEqual(guarded.viewControllers.count, 1)
        // The tab indicator previews the destination while the native Home
        // stack still owns focus and navigation until the swipe commits.
        XCTAssertEqual(CraftChrome.shared.selected, coldSwipe ? "/guarded" : "/")
        if coldSwipe {
            drag(-150, phase: .cancelled)
            await settle()
            XCTAssertEqual(CraftChrome.shared.selected, "/")
            XCTAssertEqual(screen.evaluateScript("craft.navigation.isFocused()")?.toBool(), false)
        }
        XCTAssertTrue(shell.tabTapped("/guarded", reselect: false))
        await displayWait("the guard navigates only when its tab is shown") {
            (guarded.topViewController as? CraftNativeScreenController)?.evaluateScript("craft.route.name")?.toString() == "summary"
        }
        XCTAssertEqual(home.viewControllers.count, 1)
        XCTAssertEqual(guarded.viewControllers.count, 2)
    }

    func testIdlePreparedGuardWaitsForFocusOnMainThread() async throws {
        try await checkPreparedGuard(background: false, coldSwipe: false)
    }

    func testIdlePreparedGuardWaitsForFocusOnScriptThread() async throws {
        try await checkPreparedGuard(background: true, coldSwipe: false)
    }

    func testColdSwipeGuardWaitsForFocusOnMainThread() async throws {
        try await checkPreparedGuard(background: false, coldSwipe: true)
    }

    func testColdSwipeGuardWaitsForFocusOnScriptThread() async throws {
        try await checkPreparedGuard(background: true, coldSwipe: true)
    }

    func testPreparedHiddenScreenCannotReceiveTheVisibleScreensNativeLink() async throws {
        await displayWait("adjacent native root prepared while idle") { self.stack("/details") != nil }
        let home = try XCTUnwrap(stack("/")?.topViewController as? CraftNativeScreenController)
        let hidden = try XCTUnwrap(stack("/details")?.topViewController as? CraftNativeScreenController)
        let listen = "globalThis.__links = []; craft.deepLinks.onLink(function(link) { __links.push(link.url); });"
        home.evaluateScript(listen)
        hidden.evaluateScript(listen)
        let url = try XCTUnwrap(URL(string: "https://example.com/?nativeFocus=visible"))
        DeepLinkManager.shared.handleURL(url)
        await displayWait("visible native screen receives its link") {
            home.evaluateScript("__links.length")?.toInt32() == 1
        }
        XCTAssertEqual(home.evaluateScript("__links[0]")?.toString(), url.absoluteString)
        XCTAssertEqual(hidden.evaluateScript("__links.length")?.toInt32(), 0)
    }

    func testFirstSwipeMountsAnUnvisitedNativeTabBesideTheCurrentScreen() async throws {
        // Do not yield an idle run-loop turn between constructing this shell
        // and dragging: this explicitly covers the cold fallback as well as
        // the separately tested idle preparation path.
        shell = CraftHybridController(config: CraftHybrid.shared.config)
        window.rootViewController = shell
        shell.view.frame = window.bounds
        shell.view.layoutIfNeeded()
        XCTAssertNil(stack("/details"))
        let width = shell.view.bounds.width
        drag(-150)
        let incoming = try XCTUnwrap(stack("/details"), "a first visit must participate in the interactive transition")
        let outgoing = try XCTUnwrap(stack("/"))
        XCTAssertEqual(incoming.view.frame.minX, width - 150, accuracy: 0.5)
        XCTAssertEqual(outgoing.view.frame.maxX, incoming.view.frame.minX, accuracy: 0.5)
        drag(-150, phase: .cancelled)
        await settle()
    }

    func testFirstPanMovementCancelsAShortDragWithoutAChangedEvent() async throws {
        mountDetails()
        let width = shell.view.bounds.width
        let home = try XCTUnwrap(stack("/"))
        let details = try XCTUnwrap(stack("/details"))
        let distance = width * 0.1
        drag(-distance, phase: .began)
        XCTAssertEqual(details.view.frame.minX, width - distance, accuracy: 0.5,
                       "the first recognized movement must move the incoming native screen")
        drag(-distance, phase: .ended)
        await settle()
        XCTAssertEqual(CraftChrome.shared.selected, "/", "a short pan without changed events must cancel")
        XCTAssertEqual(home.view.frame.minX, 0, accuracy: 0.5)
        XCTAssertTrue(details.view.isHidden)

        drag(-width * 0.6, phase: .began)
        drag(-width * 0.6, phase: .ended)
        await settle()
        XCTAssertEqual(CraftChrome.shared.selected, "/details", "the next full pan must still commit")
        XCTAssertEqual(details.view.frame.minX, 0, accuracy: 0.5)
        XCTAssertFalse(details.view.isHidden)
    }

    func testEndedOnlyPanKeepsTheInteractiveCompletionThresholds() async throws {
        mountDetails()
        let width = shell.view.bounds.width
        drag(-width * 0.1, phase: .ended)
        await settle()
        XCTAssertEqual(CraftChrome.shared.selected, "/", "the fallback must cancel a short slow drag too")

        drag(-width * 0.1, phase: .ended, speed: -900)
        await settle()
        XCTAssertEqual(CraftChrome.shared.selected, "/details", "a deliberate fast flick must remain supported")
        let details = try XCTUnwrap(stack("/details"))
        XCTAssertEqual(details.view.frame.minX, 0, accuracy: 0.5)
        XCTAssertFalse(details.view.isHidden)
    }

    func testIncomingTabKeepsItsEdgePastHalfwayInBothDirections() async throws {
        mountDetails()
        let width = shell.view.bounds.width
        let home = try XCTUnwrap(stack("/"))
        let details = try XCTUnwrap(stack("/details"))
        for amount in [CGFloat(150), width * 0.75, width] {
            drag(-amount)
            XCTAssertEqual(details.view.frame.minX, width - amount, accuracy: 0.5)
            XCTAssertEqual(home.view.frame.maxX, details.view.frame.minX, accuracy: 0.5)
            XCTAssertEqual(CraftChrome.shared.tabSwipePosition ?? -1, amount / width, accuracy: 0.001)
        }
        attachFrame("Left swipe beyond halfway")
        drag(-width, phase: .ended)
        await settle()
        XCTAssertTrue(home.view.isHidden)
        XCTAssertFalse(details.view.isHidden)
        XCTAssertEqual(details.view.frame, shell.view.bounds)
        for amount in [CGFloat(150), width * 0.75, width] {
            drag(amount)
            XCTAssertEqual(home.view.frame.maxX, amount, accuracy: 0.5)
            XCTAssertEqual(home.view.frame.maxX, details.view.frame.minX, accuracy: 0.5)
            XCTAssertEqual(CraftChrome.shared.tabSwipePosition ?? -1, 1 - amount / width, accuracy: 0.001)
        }
        attachFrame("Right swipe beyond halfway")
        drag(width, phase: .ended)
        await settle()
        XCTAssertEqual(CraftChrome.shared.selected, "/")
        XCTAssertNil(CraftChrome.shared.tabSwipePosition)
        XCTAssertFalse(home.view.isHidden)
        XCTAssertEqual(home.view.frame, shell.view.bounds)
    }

    func testReleaseAnimatesToTheDestinationInsteadOfJumping() async throws {
        mountDetails()
        let details = try XCTUnwrap(stack("/details"))
        let width = shell.view.bounds.width
        drag(-width * 0.4)
        let start = details.view.frame.minX
        attachFrame("Incoming native tab follows the finger")
        // A real drag renders before release; beginning and ending in one
        // run-loop turn can otherwise animate from an uncommitted layer.
        await renderFrames()
        let releasedAt = CACurrentMediaTime()
        drag(-width * 0.4, phase: .ended)
        if !UIAccessibility.isReduceMotionEnabled {
            let animation = try XCTUnwrap(details.view.layer.animation(forKey: "position") as? CABasicAnimation,
                                          "UIKit must hand the settle to the native compositor")
            let from = try XCTUnwrap(animation.fromValue as? NSValue).cgPointValue
            let to = try XCTUnwrap(animation.toValue as? NSValue).cgPointValue
            XCTAssertEqual(animation.duration, 0.22, accuracy: 0.001)
            XCTAssertEqual(from.x - to.x, start, accuracy: 0.5)
            XCTAssertEqual(to.x, animation.isAdditive ? 0 : width * 0.5, accuracy: 0.5)
        }
        let sample = expectation(description: "sample a settling animation frame")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            let elapsed = CACurrentMediaTime() - releasedAt
            // A loaded simulator may schedule this after the animation has
            // finished. Its native interpolation was still required above.
            if !UIAccessibility.isReduceMotionEnabled && elapsed < 0.19 {
                let frame = details.view.layer.presentation()?.frame ?? details.view.frame
                XCTAssertGreaterThan(frame.minX, 0.5, "the native transition jumped to its final frame")
                XCTAssertLessThan(frame.minX, start, "the native transition never advanced")
            }
            sample.fulfill()
        }
        await fulfillment(of: [sample], timeout: 15)
        await settle()
        XCTAssertEqual(details.view.frame, shell.view.bounds)
        XCTAssertFalse(details.view.isHidden)
        XCTAssertEqual(CraftChrome.shared.selected, "/details")
    }

    /// Swipe twice in quick succession: the second finger lands while the
    /// first swipe settles. It catches the screens where they are, as a
    /// paging scroll view does, instead of being ignored until the settle
    /// ends, and carries on to the next tab without a jump.
    func testASwipeCatchesTheLastOneWhileItSettlesAndCarriesOn() async throws {
        mountDetails()
        _ = shell.tabTapped("/third", reselect: false)
        _ = shell.tabTapped("/", reselect: false)
        CraftChrome.shared.selected = "/"
        let width = shell.view.bounds.width
        let home = try XCTUnwrap(stack("/"))
        let details = try XCTUnwrap(stack("/details"))
        let third = try XCTUnwrap(stack("/third"))
        drag(-width * 0.6)
        catchableSettle()
        drag(-width * 0.6, phase: .ended, speed: -900)
        await renderFrames()
        drag(0, phase: .began, speed: -600)
        shell.view.layer.speed = 1
        // The first swipe is done (Details is the tab) and nothing moved.
        XCTAssertEqual(CraftChrome.shared.selected, "/details")
        let caughtAt = details.view.frame.minX
        XCTAssertGreaterThan(caughtAt, 0.5, "the settle should still have been under way")
        XCTAssertLessThan(caughtAt, width * 0.4 + 1)
        XCTAssertFalse(home.view.isHidden)
        XCTAssertEqual(home.view.frame.maxX, caughtAt, accuracy: 0.5)
        drag(-150)
        XCTAssertEqual(details.view.frame.minX, caughtAt - 150, accuracy: 0.5)
        XCTAssertEqual(third.view.frame.minX, details.view.frame.maxX, accuracy: 0.5)
        XCTAssertEqual(home.view.frame.maxX, details.view.frame.minX, accuracy: 0.5, "the outgoing screen keeps its place beside Details")
        attachFrame("A caught swipe carrying on to Third")
        drag(-width * 0.6, phase: .ended, speed: -900)
        await settle()
        XCTAssertEqual(CraftChrome.shared.selected, "/third")
        XCTAssertFalse(third.view.isHidden)
        XCTAssertTrue(details.view.isHidden)
        XCTAssertTrue(home.view.isHidden)
        XCTAssertEqual(third.view.frame, shell.view.bounds)
    }

    /// The second finger goes back instead: the screen the first swipe was
    /// leaving follows it from exactly where it was.
    func testACaughtSwipeGoesBackFromWhereTheScreensWere() async throws {
        mountDetails()
        let width = shell.view.bounds.width
        let home = try XCTUnwrap(stack("/"))
        let details = try XCTUnwrap(stack("/details"))
        drag(-width * 0.6)
        catchableSettle()
        drag(-width * 0.6, phase: .ended, speed: -900)
        await renderFrames()
        drag(0, phase: .began, speed: 600)
        shell.view.layer.speed = 1
        let caughtAt = details.view.frame.minX
        XCTAssertGreaterThan(caughtAt, 0.5, "the settle should still have been under way")
        drag(120)
        XCTAssertEqual(details.view.frame.minX, caughtAt + 120, accuracy: 0.5)
        XCTAssertEqual(home.view.frame.maxX, details.view.frame.minX, accuracy: 0.5)
        drag(width * 0.6, phase: .ended, speed: 900)
        await settle()
        XCTAssertEqual(CraftChrome.shared.selected, "/")
        XCTAssertFalse(home.view.isHidden)
        XCTAssertTrue(details.view.isHidden)
        XCTAssertEqual(home.view.frame, shell.view.bounds)
    }

    /// Caught and let go without moving: the screens finish where they were going.
    func testACaughtSwipeLetGoWithoutMovingFinishesWhereItWasGoing() async throws {
        mountDetails()
        let width = shell.view.bounds.width
        let home = try XCTUnwrap(stack("/"))
        let details = try XCTUnwrap(stack("/details"))
        drag(-width * 0.6)
        catchableSettle()
        drag(-width * 0.6, phase: .ended, speed: -900)
        await renderFrames()
        drag(0, phase: .began)
        shell.view.layer.speed = 1
        drag(0, phase: .ended)
        await settle()
        XCTAssertEqual(CraftChrome.shared.selected, "/details")
        XCTAssertFalse(details.view.isHidden)
        XCTAssertTrue(home.view.isHidden)
        XCTAssertEqual(details.view.frame, shell.view.bounds)
    }

    func testShortAndSystemCancelledSwipesRestoreBothStacksAndSelection() async throws {
        mountDetails()
        let home = try XCTUnwrap(stack("/"))
        let details = try XCTUnwrap(stack("/details"))
        for phase in [UIGestureRecognizer.State.ended, .cancelled, .failed] {
            drag(-50)
            drag(-50, phase: phase)
            await settle()
            XCTAssertEqual(CraftChrome.shared.selected, "/")
            XCTAssertFalse(home.view.isHidden)
            XCTAssertTrue(details.view.isHidden)
            XCTAssertEqual(home.view.frame, shell.view.bounds)
            XCTAssertEqual(details.view.frame, shell.view.bounds)
        }
    }

    func testReversingTheDragNeverExposesTheBackgroundOrSelectsTheWrongTab() async throws {
        mountDetails()
        let home = try XCTUnwrap(stack("/"))
        let details = try XCTUnwrap(stack("/details"))
        drag(-150)
        drag(70)
        XCTAssertEqual(home.view.frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(details.view.frame.minX, shell.view.bounds.width, accuracy: 0.5)
        drag(70, phase: .ended, speed: 800)
        await settle()
        XCTAssertEqual(CraftChrome.shared.selected, "/")
        XCTAssertEqual(home.view.frame, shell.view.bounds)
    }

    func testTabTapDuringSettlingWinsOverTheSwipeCompletion() async throws {
        mountDetails()
        let home = try XCTUnwrap(stack("/"))
        let details = try XCTUnwrap(stack("/details"))
        for path in ["/", "/third", "/details"] {
            _ = shell.tabTapped("/", reselect: false)
            CraftChrome.shared.selected = "/"
            drag(-shell.view.bounds.width * 0.4)
            drag(-shell.view.bounds.width * 0.4, phase: .ended)
            let tab = try XCTUnwrap(CraftChrome.shared.tabs.first { $0.id == path })
            CraftChrome.shared.tap(tab)
            let selected = try XCTUnwrap(stack(path))
            XCTAssertFalse(selected.view.isHidden, "the newer tab tap must take effect immediately")
            XCTAssertEqual(selected.view.frame, shell.view.bounds)
            XCTAssertTrue(selected.view.layer.animationKeys()?.isEmpty ?? true)
            await settle()
            XCTAssertEqual(CraftChrome.shared.selected, path, "a completed swipe overrode the newer tab tap")
            XCTAssertEqual(home.view.isHidden, path != "/")
            XCTAssertEqual(details.view.isHidden, path != "/details")
            XCTAssertEqual(selected.view.frame, shell.view.bounds)
        }
    }

    func testTabAccessoryRoutePushesAndRestoresTheSelectedNativeStack() async throws {
        shell.open("/linked-details")
        let home = try XCTUnwrap(stack("/"))
        await displayWait("details push completed") {
            home.transitionCoordinator == nil
                && (home.topViewController as? CraftNativeScreenController)?.routeParams["path"] as? String == "/linked-details"
        }
        XCTAssertTrue(CraftHybrid.shared.controller === shell)
        XCTAssertEqual(CraftChrome.shared.tabAccessory?.id, "/capabilities")
        CraftHybrid.shared.open("/capabilities")
        await displayWait("the accessory path reaches its native screen") {
            home.transitionCoordinator == nil
                && (home.topViewController as? CraftNativeScreenController)?.routeParams["path"] as? String == "/capabilities"
        }
        XCTAssertEqual(home.viewControllers.count, 3)
        XCTAssertEqual(CraftChrome.shared.selected, "/")
        XCTAssertNil(CraftChrome.shared.tabAccessory)
        home.popViewController(animated: false)
        await renderFrames()
        XCTAssertEqual(CraftChrome.shared.tabAccessory?.id, "/capabilities")
        home.popViewController(animated: false)
        await renderFrames()
        XCTAssertNil(CraftChrome.shared.tabAccessory)
    }

    func testPreparedTabOptionsCannotReplaceVisibleScreenChrome() async throws {
        await displayWait("the Third tab is prepared") { [self] in stack("/third") != nil }
        let home = try XCTUnwrap(stack("/"))
        let visible = try XCTUnwrap(home.topViewController as? CraftNativeScreenController)
        visible.evaluateScript("craft.navigation.setOptions({tabBarHidden:true,tabAccessory:{path:'/capabilities',title:'Visible controls',symbol:'bolt'}})")
        await displayWait("the visible screen owns the hidden bar and accessory") {
            CraftChrome.shared.hiddenByScreen && CraftChrome.shared.tabAccessory?.id == "/capabilities"
        }
        let background = try XCTUnwrap(stack("/third"))
        XCTAssertTrue(background.view.isHidden)
        let prepared = try XCTUnwrap(background.topViewController as? CraftNativeScreenController)
        prepared.evaluateScript("craft.navigation.setOptions({title:'Prepared update delivered',tabBarHidden:false,tabAccessory:null})")
        await displayWait("the background screen received its late options") {
            prepared.navigationItem.title == "Prepared update delivered"
        }
        XCTAssertTrue(CraftChrome.shared.hiddenByScreen, "a late background update cannot reveal the foreground screen's tab bar")
        XCTAssertEqual(CraftChrome.shared.tabAccessory?.id, "/capabilities", "the visible screen keeps its accessory")
        _ = shell.tabTapped("/third", reselect: false)
        await settle()
        XCTAssertFalse(CraftChrome.shared.hiddenByScreen, "the prepared options apply when that screen becomes visible")
        XCTAssertNil(CraftChrome.shared.tabAccessory)
    }

    func testNativePushKeepsItsAccessoryAfterTabPreparation() async throws {
        await displayWait("the Third tab is prepared") { [self] in stack("/third") != nil }
        let home = try XCTUnwrap(stack("/"))
        let root = try XCTUnwrap(home.topViewController as? CraftNativeScreenController)
        func button(in view: UIView) -> UIButton? {
            if view.accessibilityIdentifier == "navigation-open-details" { return view as? UIButton }
            return view.subviews.lazy.compactMap { button(in: $0) }.first
        }
        let open = try XCTUnwrap(button(in: root.view))
        open.sendActions(for: .touchUpInside)
        await displayWait("the compiled button pushes Details") {
            home.topViewController !== root && home.transitionCoordinator == nil
        }
        await renderFrames()
        XCTAssertEqual(CraftChrome.shared.selected, "/")
        XCTAssertEqual(CraftChrome.shared.tabAccessory?.id, "/capabilities")

        let background = try XCTUnwrap(stack("/third"))
        XCTAssertTrue(background.view.isHidden)
        let prepared = try XCTUnwrap(background.topViewController as? CraftNativeScreenController)
        // UIKit can deliver the prepared tab's first appearance after the
        // foreground push has finished. That callback must not claim chrome.
        prepared.viewDidAppear(false)
        XCTAssertEqual(CraftChrome.shared.tabAccessory?.id, "/capabilities")
        XCTAssertEqual(CraftChrome.shared.selected, "/")
    }

    func testDisappearingHiddenNativeTabCannotClearTheVisibleAccessory() async throws {
        shell.open("/linked-details")
        let home = try XCTUnwrap(stack("/"))
        await displayWait("details accessory is visible") {
            home.transitionCoordinator == nil && CraftChrome.shared.tabAccessory?.id == "/capabilities"
        }
        let background = CraftNativeScreenController(config: CraftHybrid.shared.config)
        background.loadViewIfNeeded()
        // A prepared or retained controller may finish disappearing after the
        // current screen has published its chrome. It cannot clear that owner.
        background.viewWillDisappear(false)
        XCTAssertEqual(CraftChrome.shared.tabAccessory?.id, "/capabilities")
        let visible = try XCTUnwrap(home.topViewController as? CraftNativeScreenController)
        // Its owner going away gives it up but leaves it drawn until the next
        // screen says what it wants (the pill no longer stretches and back).
        visible.viewWillDisappear(false)
        XCTAssertEqual(CraftChrome.shared.tabAccessory?.id, "/capabilities", "released, still drawn")
        CraftChrome.shared.clearUnclaimedTabAccessory()
        XCTAssertNil(CraftChrome.shared.tabAccessory, "an accessory nobody claims comes off")
        visible.screenVisibilityChanged(true)
        XCTAssertEqual(CraftChrome.shared.tabAccessory?.id, "/capabilities")
    }

    func testCancelledColdSwipeRestoresTheVisibleScreensAccessory() async throws {
        let previous = CraftChrome.shared.tabAccessory
        drag(-150)
        await renderFrames()
        drag(-150, phase: .cancelled)
        await settle()
        XCTAssertEqual(CraftChrome.shared.selected, "/")
        XCTAssertEqual(CraftChrome.shared.tabAccessory, previous, "an unvisited tab's preview must not leave its accessory on the restored screen")
    }

    /// A tab tapped before the shell prepared it is made first, hidden, and
    /// the tap then shows that one: mounted after the selection began, it
    /// held the main thread while the bar's pill should have been moving.
    func testATabNotPreparedYetIsMadeBeforeItsSelectionMoves() async throws {
        guard stack("/third") == nil else { throw XCTSkip("the shell prepared /third already") }
        shell.mountTabBeforeSelecting("/third")
        let made = try XCTUnwrap(stack("/third"))
        XCTAssertTrue(made.view.isHidden, "made out of sight")
        XCTAssertEqual(CraftChrome.shared.selected, "/")
        XCTAssertFalse(try XCTUnwrap(stack("/")).view.isHidden)
        // Made already: asking again changes nothing.
        shell.mountTabBeforeSelecting("/third")
        XCTAssertTrue(stack("/third") === made)
        _ = shell.tabTapped("/third", reselect: false)
        await renderFrames()
        XCTAssertTrue(stack("/third") === made, "the tap shows the one made")
        XCTAssertFalse(made.view.isHidden)
    }

    func testDeferredPageSelectionCannotOverrideANewerNativeTabTap() async throws {
        mountDetails()
        // A page reports its tab while a native stack owns the screen. The
        // shell defers correcting that report; another real tab tap arrives
        // before the correction runs (for example while a cold root mounts).
        CraftChrome.shared.handle(["type": "selectTab", "id": "/details"])
        let third = try XCTUnwrap(CraftChrome.shared.tabs.first { $0.id == "/third" })
        CraftChrome.shared.tap(third)
        XCTAssertEqual(CraftChrome.shared.selected, "/third")
        await renderFrames()
        XCTAssertEqual(CraftChrome.shared.selected, "/third", "a stale page correction changed the selected tab")
        XCTAssertFalse(try XCTUnwrap(stack("/third")).view.isHidden)
        XCTAssertTrue(try XCTUnwrap(stack("/")).view.isHidden)
    }

    func testDeferredPageSelectionPreservesANewerInteractiveSwipePreview() async throws {
        mountDetails()
        for reported in ["/third", "/details"] {
            CraftChrome.shared.handle(["type": "selectTab", "id": reported])
            drag(-150)
            XCTAssertEqual(CraftChrome.shared.selected, "/details")
            await renderFrames()
            XCTAssertEqual(CraftChrome.shared.selected, "/details", "a stale page correction cleared the finger's tab preview")
            drag(-150, phase: .cancelled)
            await settle()
            XCTAssertEqual(CraftChrome.shared.selected, "/", "cancellation must restore the native owning tab, not the page's stale report")
            XCTAssertFalse(try XCTUnwrap(stack("/")).view.isHidden)
        }
    }

    func testPageReportingTheOutgoingRootCannotClearAnActiveSwipePreview() async throws {
        mountDetails()
        drag(-150)
        CraftChrome.shared.handle(["type": "selectTab", "id": "/"])
        await renderFrames()
        XCTAssertEqual(CraftChrome.shared.selected, "/details", "the finger's preview owns selection until the gesture settles")
        drag(-150, phase: .cancelled)
        await settle()
        XCTAssertEqual(CraftChrome.shared.selected, "/")
    }

    func testSwipeAfterATabTapCannotBeChangedByTheOlderAnimation() async throws {
        mountDetails()
        let details = try XCTUnwrap(stack("/details"))
        let width = shell.view.bounds.width
        drag(-width * 0.4)
        drag(-width * 0.4, phase: .ended)
        let homeTab = try XCTUnwrap(CraftChrome.shared.tabs.first { $0.id == "/" })
        CraftChrome.shared.tap(homeTab)
        drag(-width * 0.4)
        XCTAssertEqual(details.view.frame.minX, width * 0.6, accuracy: 0.5)
        drag(-width * 0.4, phase: .ended)
        await settle()
        XCTAssertEqual(CraftChrome.shared.selected, "/details")
        XCTAssertFalse(details.view.isHidden)
        XCTAssertEqual(details.view.frame, shell.view.bounds)
    }
}
