import AuthenticationServices
import SafariServices
import UIKit
import WebKit

/// Where the shell's own UI is shown from: alerts, sheets, menus, the in-app
/// browser.
///
/// Everything used to be presented from `windows.first?.rootViewController`.
/// UIKit refuses to present from a controller that is already presenting, so
/// a share sheet asked for while an alert, a picker or another sheet was up
/// did nothing at all, and the page's promise waited for an answer that could
/// not come. The controller on top is the one that can present.
enum CraftPresenter {
    /// The window people are looking at: the foreground scene's key window.
    static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
    }

    /// The controller on top of everything already presented.
    static func topViewController() -> UIViewController? {
        var top = keyWindow()?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    /// Present over whatever is on screen. A controller that shows as a
    /// popover on iPad (an action sheet, a share sheet) points at `anchor` in
    /// `view`, or sits in the middle of it with no arrow; iPadOS raises an
    /// exception for a popover with neither. False when nothing can present,
    /// so the caller answers rather than waiting.
    @discardableResult
    static func present(_ controller: UIViewController, from view: UIView?, anchor: CGRect? = nil) -> Bool {
        guard let top = topViewController() else { return false }
        if let popover = controller.popoverPresentationController {
            let source = view ?? top.view!
            popover.sourceView = source
            if let anchor {
                popover.sourceRect = anchor
            } else {
                popover.sourceRect = CGRect(x: source.bounds.midX, y: source.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
        }
        top.present(controller, animated: true)
        return true
    }

    /// `{ x, y, width, height }` in the page's CSS pixels, which are the web
    /// view's points, as a rect. Nil when it is not one.
    static func rect(_ value: Any?) -> CGRect? {
        guard let value = value as? [String: Any] else { return nil }
        func number(_ key: String) -> CGFloat? { (value[key] as? NSNumber).map { CGFloat(truncating: $0) } }
        guard let x = number("x"), let y = number("y") else { return nil }
        return CGRect(x: x, y: y, width: max(0, number("width") ?? 0), height: max(0, number("height") ?? 0))
    }

    /// UIKit's own "OK" and "Cancel", in the phone's language. The page's
    /// alerts and confirms read like the system's because they are.
    static func systemString(_ key: String) -> String {
        Bundle(for: UIApplication.self).localizedString(forKey: key, value: key, table: nil)
    }
}

// MARK: - CSS colours

extension UIColor {
    /// A colour as a page writes it in CSS: `#rgb`, `#rgba`, `#rrggbb`,
    /// `#rrggbbaa`, `rgb()` and `rgba()` (numbers or percentages, commas or
    /// spaces), `transparent`, and the handful of names a page passes to
    /// native chrome. Nil for anything else, so a caller can say it did not
    /// apply rather than paint the wrong colour.
    convenience init?(css value: String) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("#") {
            let hex = String(text.dropFirst())
            let digits: String
            switch hex.count {
            case 3, 4: digits = hex.map { "\($0)\($0)" }.joined()
            case 6, 8: digits = hex
            default: return nil
            }
            guard let packed = UInt64(digits, radix: 16) else { return nil }
            let alpha = digits.count == 8
            let shift: UInt64 = alpha ? 8 : 0
            self.init(
                red: CGFloat((packed >> (16 + shift)) & 0xFF) / 255,
                green: CGFloat((packed >> (8 + shift)) & 0xFF) / 255,
                blue: CGFloat((packed >> shift) & 0xFF) / 255,
                alpha: alpha ? CGFloat(packed & 0xFF) / 255 : 1
            )
            return
        }
        if text.hasPrefix("rgb"), let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close {
            let parts = text[text.index(after: open)..<close]
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                .map(String.init)
            guard parts.count == 3 || parts.count == 4 else { return nil }
            func channel(_ part: String, scale: CGFloat) -> CGFloat? {
                if part.hasSuffix("%") { return Double(part.dropLast()).map { CGFloat($0) / 100 } }
                return Double(part).map { CGFloat($0) / scale }
            }
            guard let r = channel(parts[0], scale: 255), let g = channel(parts[1], scale: 255), let b = channel(parts[2], scale: 255) else { return nil }
            let a = parts.count == 4 ? channel(parts[3], scale: 1) : 1
            guard let a else { return nil }
            self.init(red: min(max(r, 0), 1), green: min(max(g, 0), 1), blue: min(max(b, 0), 1), alpha: min(max(a, 0), 1))
            return
        }
        let named: [String: (CGFloat, CGFloat, CGFloat, CGFloat)] = [
            "transparent": (0, 0, 0, 0),
            "black": (0, 0, 0, 1),
            "white": (1, 1, 1, 1),
            "red": (1, 0, 0, 1),
            "green": (0, 0.5, 0, 1),
            "blue": (0, 0, 1, 1),
            "gray": (0.5, 0.5, 0.5, 1),
            "grey": (0.5, 0.5, 0.5, 1),
        ]
        guard let (r, g, b, a) = named[text] else { return nil }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}

// MARK: - Dialogs

/// `craft.dialog`: the system's alert, confirmation and action sheet, with
/// the page's own words on them.
enum CraftDialogs {
    private static func text(_ body: [String: Any], _ key: String) -> String? {
        (body[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func alert(_ body: [String: Any], from view: UIView?, completion: @escaping () -> Void) {
        let alert = UIAlertController(title: text(body, "title"), message: text(body, "message"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: text(body, "okLabel") ?? CraftPresenter.systemString("OK"), style: .default) { _ in completion() })
        if !CraftPresenter.present(alert, from: view) { completion() }
    }

    /// True when the person confirmed. `destructive` paints the confirming
    /// button red, as iOS does for a delete.
    static func confirm(_ body: [String: Any], from view: UIView?, completion: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: text(body, "title"), message: text(body, "message"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: text(body, "cancelLabel") ?? CraftPresenter.systemString("Cancel"), style: .cancel) { _ in completion(false) })
        let confirm = UIAlertAction(
            title: text(body, "confirmLabel") ?? CraftPresenter.systemString("OK"),
            style: body["destructive"] as? Bool == true ? .destructive : .default
        ) { _ in completion(true) }
        alert.addAction(confirm)
        alert.preferredAction = body["destructive"] as? Bool == true ? nil : confirm
        if !CraftPresenter.present(alert, from: view) { completion(false) }
    }

    /// The chosen action's id, or nil when the sheet was cancelled. A sheet
    /// always has a way out: with no `cancel` action of the page's own, the
    /// system's Cancel is added, which is also what a tap outside the iPad
    /// popover answers with.
    static func actionSheet(_ body: [String: Any], from view: UIView?, completion: @escaping (String?) -> Void) {
        let actions = (body["actions"] as? [[String: Any]]) ?? []
        let sheet = UIAlertController(title: text(body, "title"), message: text(body, "message"), preferredStyle: .actionSheet)
        var answered = false
        let answer: (String?) -> Void = { id in
            guard !answered else { return }
            answered = true
            completion(id)
        }
        var hasCancel = false
        for action in actions {
            guard let title = action["title"] as? String else { continue }
            let id = action["id"] as? String ?? title
            let style: UIAlertAction.Style
            switch action["style"] as? String {
            case "destructive": style = .destructive
            case "cancel" where !hasCancel:
                style = .cancel
                hasCancel = true
            default: style = .default
            }
            // A cancel action answers nil whatever its id, so a page can
            // tell "dismissed" from a choice the same way either way.
            sheet.addAction(UIAlertAction(title: title, style: style) { _ in answer(style == .cancel ? nil : id) })
        }
        if !hasCancel {
            sheet.addAction(UIAlertAction(title: CraftPresenter.systemString("Cancel"), style: .cancel) { _ in answer(nil) })
        }
        if !CraftPresenter.present(sheet, from: view, anchor: CraftPresenter.rect(body["anchor"])) { answer(nil) }
    }
}

// MARK: - Context menu

/// `craft.contextMenu.show`: a native menu pointing at a rect of the page.
///
/// A context menu normally opens only from a touch the system saw begin, and
/// the touch here began in the web page. iOS 17.4 gave UIButton
/// `performPrimaryAction()`, which opens a button's menu from code: so a
/// transparent button is laid over the rect, given the menu, and asked to
/// open it. That is the system's own menu, the list with symbols that a long
/// press shows anywhere else, anchored where the page asked. Between iOS 16
/// and 17.4 the public way to show a menu on request is UIEditMenuInteraction,
/// the horizontal edit bar; before 16 the items come up as an action sheet.
final class CraftContextMenu: NSObject {
    /// The menu on screen, kept alive until it answers.
    private static var current: CraftContextMenu?

    private let overlay = UIView()
    private let menu: UIMenu
    private var completion: ((String?) -> Void)?

    private init(menu: UIMenu, completion: @escaping (String?) -> Void) {
        self.menu = menu
        self.completion = completion
        super.init()
    }

    static func show(_ body: [String: Any], in webView: WKWebView, completion: @escaping (String?) -> Void) {
        let items = (body["items"] as? [[String: Any]]) ?? []
        guard !items.isEmpty else { completion(nil); return }
        let anchor = CraftPresenter.rect(body["anchor"])
            ?? CGRect(x: webView.bounds.midX, y: webView.bounds.midY, width: 0, height: 0)

        guard #available(iOS 16.0, *) else {
            let actions: [[String: Any]] = items.map { item in
                ["id": item["id"] ?? NSNull(), "title": item["title"] ?? "", "style": item["destructive"] as? Bool == true ? "destructive" : "default"]
            }
            CraftDialogs.actionSheet(["title": body["title"] ?? NSNull(), "actions": actions, "anchor": body["anchor"] ?? NSNull()], from: webView, completion: completion)
            return
        }

        current?.finish(nil)
        var presenter: CraftContextMenu?
        let elements: [UIMenuElement] = items.compactMap { item in
            guard let title = item["title"] as? String else { return nil }
            let id = item["id"] as? String ?? title
            var attributes: UIMenuElement.Attributes = []
            if item["destructive"] as? Bool == true { attributes.insert(.destructive) }
            if item["disabled"] as? Bool == true { attributes.insert(.disabled) }
            let image = (item["symbol"] as? String).flatMap { UIImage(systemName: $0) }
            return UIAction(title: title, image: image, attributes: attributes) { _ in presenter?.finish(id) }
        }
        let menu = UIMenu(title: body["title"] as? String ?? "", children: elements)
        let shown = CraftContextMenu(menu: menu, completion: completion)
        presenter = shown
        current = shown
        shown.present(in: webView, at: anchor)
    }

    @available(iOS 16.0, *)
    private func present(in webView: WKWebView, at anchor: CGRect) {
        overlay.frame = anchor.width > 0 && anchor.height > 0 ? anchor : CGRect(x: anchor.minX - 1, y: anchor.minY - 1, width: 2, height: 2)
        overlay.backgroundColor = .clear
        webView.addSubview(overlay)
        if #available(iOS 17.4, *) {
            let button = MenuButton(type: .custom)
            button.frame = overlay.bounds
            button.menu = menu
            button.showsMenuAsPrimaryAction = true
            button.onDismiss = { [weak self] in self?.finishSoon() }
            overlay.addSubview(button)
            button.performPrimaryAction()
            return
        }
        let interaction = UIEditMenuInteraction(delegate: self)
        overlay.addInteraction(interaction)
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: overlay.bounds.midX, y: overlay.bounds.minY))
        configuration.preferredArrowDirection = .automatic
        interaction.presentEditMenu(with: configuration)
    }

    /// The "nothing chosen" answer, a moment after the menu closes. A choice
    /// calls its action around the dismissal, not necessarily before it, so
    /// this loses to a choice that lands in the meantime.
    fileprivate func finishSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.finish(nil) }
    }

    /// The button the iOS 17.4 menu hangs from; it says when the menu closes.
    private final class MenuButton: UIButton {
        var onDismiss: (() -> Void)?

        override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
            super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
            if let animator {
                animator.addCompletion { [weak self] in self?.onDismiss?() }
            } else {
                onDismiss?()
            }
        }
    }

    fileprivate func finish(_ id: String?) {
        guard let completion else { return }
        self.completion = nil
        overlay.removeFromSuperview()
        if CraftContextMenu.current === self { CraftContextMenu.current = nil }
        completion(id)
    }
}

@available(iOS 16.0, *)
extension CraftContextMenu: UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        menu
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        overlay.bounds
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration, animator: UIEditMenuInteractionAnimating) {
        animator.addCompletion { [weak self] in self?.finishSoon() }
    }
}

// MARK: - In-app browser and web sign-in

/// `craft.browser.open`: a page somewhere else, without leaving the app.
///
/// `safari` is SFSafariViewController, which shares Safari's cookies and
/// autofill and comes back to the app with Done. `auth` is
/// ASWebAuthenticationSession, the system's sign-in sheet, which answers with
/// the URL the provider redirected to on `callbackScheme`. Its session is not
/// ephemeral, so someone already signed in to the provider in Safari is not
/// asked again.
final class CraftBrowser: NSObject {
    static let shared = CraftBrowser()

    private var safariCompletion: (([String: Any]) -> Void)?
    private var authSession: ASWebAuthenticationSession?

    func open(_ url: URL, mode: String, callbackScheme: String?, from view: UIView?, completion: @escaping ([String: Any]) -> Void) {
        if mode == "auth" {
            authenticate(url, callbackScheme: callbackScheme, completion: completion)
            return
        }
        guard url.scheme == "https" || url.scheme == "http" else {
            completion(["cancelled": true, "error": "Only http and https pages open in the in-app browser"])
            return
        }
        // One at a time: a second open answers the first.
        safariCompletion?(["cancelled": false])
        let safari = SFSafariViewController(url: url)
        safari.dismissButtonStyle = .close
        safari.delegate = self
        safariCompletion = completion
        if !CraftPresenter.present(safari, from: view) {
            safariCompletion = nil
            completion(["cancelled": true, "error": "Nothing could present the browser"])
        }
    }

    private func authenticate(_ url: URL, callbackScheme: String?, completion: @escaping ([String: Any]) -> Void) {
        authSession?.cancel()
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callback, error in
            DispatchQueue.main.async {
                self?.authSession = nil
                if let callback {
                    completion(["url": callback.absoluteString, "cancelled": false])
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    completion(["cancelled": true])
                } else {
                    completion(["cancelled": true, "error": error?.localizedDescription ?? "Sign-in did not finish"])
                }
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        if !session.start() {
            authSession = nil
            completion(["cancelled": true, "error": "The sign-in sheet could not start"])
        }
    }
}

extension CraftBrowser: SFSafariViewControllerDelegate {
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        let completion = safariCompletion
        safariCompletion = nil
        completion?(["cancelled": false])
    }
}

extension CraftBrowser: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        CraftPresenter.keyWindow() ?? ASPresentationAnchor()
    }
}

// MARK: - SF Symbols

/// `craft.symbols.image`: an SF Symbol drawn to a PNG data URL, so a page can
/// show the same glyph the system's own controls use.
enum CraftSymbols {
    static func image(named name: String, options: [String: Any]) -> String? {
        let pointSize = (options["pointSize"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 17
        let weight: UIImage.SymbolWeight
        switch options["weight"] as? String {
        case "ultraLight": weight = .ultraLight
        case "thin": weight = .thin
        case "light": weight = .light
        case "medium": weight = .medium
        case "semibold": weight = .semibold
        case "bold": weight = .bold
        case "heavy": weight = .heavy
        case "black": weight = .black
        default: weight = .regular
        }
        let scale: UIImage.SymbolScale
        switch options["scale"] as? String {
        case "small": scale = .small
        case "large": scale = .large
        default: scale = .medium
        }
        let configuration = UIImage.SymbolConfiguration(pointSize: max(1, pointSize), weight: weight, scale: scale)
        guard !name.isEmpty, let symbol = UIImage(systemName: name, withConfiguration: configuration) else { return nil }
        // Resolved against the screen's own appearance: drawing a dynamic
        // colour off screen would otherwise pick the light variant.
        let traits = CraftPresenter.keyWindow()?.traitCollection ?? UITraitCollection.current
        let color = ((options["color"] as? String).flatMap { UIColor(css: $0) } ?? .label).resolvedColor(with: traits)
        let tinted = symbol.withTintColor(color, renderingMode: .alwaysOriginal)
        let format = UIGraphicsImageRendererFormat()
        format.scale = CraftPresenter.keyWindow()?.screen.scale ?? UIScreen.main.scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: tinted.size, format: format).image { _ in tinted.draw(at: .zero) }
        guard let data = image.pngData() else { return nil }
        return "data:image/png;base64," + data.base64EncodedString()
    }
}

// MARK: - Status bar

/// `craft.statusBar.setStyle`: light or dark status bar text, or the
/// system's choice for the app's appearance.
///
/// The bar is view-controller based (UIViewControllerBasedStatusBarAppearance)
/// so the system's own sheets keep theirs. The root is SwiftUI's hosting
/// controller, which offers no way to say which style it wants, so the first
/// call teaches that controller's class to answer from here. Only that exact
/// class is touched, and only once.
enum CraftStatusBar {
    static var style: UIStatusBarStyle = .default
    private static var taught = Set<ObjectIdentifier>()

    @discardableResult
    static func setStyle(_ name: String) -> Bool {
        switch name {
        case "light": style = .lightContent
        case "dark": style = .darkContent
        default: style = .default
        }
        guard let root = CraftPresenter.keyWindow()?.rootViewController else { return false }
        teach(root)
        UIView.animate(withDuration: 0.2) { root.setNeedsStatusBarAppearanceUpdate() }
        return true
    }

    private static func teach(_ controller: UIViewController) {
        guard let cls = object_getClass(controller) else { return }
        let key = ObjectIdentifier(cls)
        guard !taught.contains(key) else { return }
        taught.insert(key)
        let preferred: @convention(block) (AnyObject) -> Int = { _ in CraftStatusBar.style.rawValue }
        class_replaceMethod(cls, #selector(getter: UIViewController.preferredStatusBarStyle), imp_implementationWithBlock(preferred), "q@:")
        // Asked first, and a child's answer would win over the one above.
        let child: @convention(block) (AnyObject) -> UIViewController? = { _ in nil }
        class_replaceMethod(cls, #selector(getter: UIViewController.childForStatusBarStyle), imp_implementationWithBlock(child), "@@:")
    }
}

// MARK: - Keyboard accessory bar

/// The bar WebKit puts above the keyboard for a form field (the up and down
/// arrows and Done), which no native app's keyboard has.
///
/// There is no public switch for it. The bar is the `inputAccessoryView` of
/// WKContentView, WebKit's private first responder inside the web view, so
/// this is the trick Cordova and Capacitor use: that one view's class is
/// swapped for a subclass, made at runtime, whose `inputAccessoryView` is nil.
/// Nothing is swizzled globally, and showing the bar again restores the view's
/// own class. If WebKit renames the view, this finds nothing and does nothing.
enum CraftKeyboardAccessory {
    private static let subclassName = "CraftAccessoryFreeContentView"
    private static var originalClass: AnyClass?

    @discardableResult
    static func setVisible(_ visible: Bool, in webView: WKWebView) -> Bool {
        guard let content = webView.scrollView.subviews.first(where: { String(describing: type(of: $0)).hasPrefix("WKContentView") }),
              let current = object_getClass(content) else { return false }
        let isHidden = NSStringFromClass(current) == subclassName
        if visible {
            if isHidden, let originalClass { object_setClass(content, originalClass) }
        } else if !isHidden {
            guard let subclass = accessoryFreeSubclass(of: current) else { return false }
            object_setClass(content, subclass)
        }
        if content.isFirstResponder { content.reloadInputViews() }
        return true
    }

    private static func accessoryFreeSubclass(of base: AnyClass) -> AnyClass? {
        if let existing = NSClassFromString(subclassName) { return existing }
        guard let subclass = objc_allocateClassPair(base, subclassName, 0) else { return nil }
        let none: @convention(block) (AnyObject) -> UIView? = { _ in nil }
        class_addMethod(subclass, #selector(getter: UIResponder.inputAccessoryView), imp_implementationWithBlock(none), "@@:")
        objc_registerClassPair(subclass)
        originalClass = base
        return subclass
    }
}

// MARK: - Pull to refresh

/// `craft.refresh`: the system's pull-to-refresh on the web view's own scroll
/// view, so the spinner, the rubber band and the haptic are UIKit's. A pull
/// fires `craftRefresh` at the page, which calls `craft.refresh.end()` when it
/// has its new content. A page that never does is not left spinning forever.
final class CraftRefreshControl: NSObject {
    private weak var scrollView: UIScrollView?
    private var control: UIRefreshControl?
    private var safety: DispatchWorkItem?
    private let onRefresh: () -> Void

    init(onRefresh: @escaping () -> Void) {
        self.onRefresh = onRefresh
    }

    func enable(on scrollView: UIScrollView, tint: UIColor?) {
        if control == nil || self.scrollView !== scrollView {
            disable()
            let control = UIRefreshControl()
            control.addTarget(self, action: #selector(pulled), for: .valueChanged)
            scrollView.refreshControl = control
            self.control = control
            self.scrollView = scrollView
        }
        control?.tintColor = tint
    }

    func disable() {
        end()
        if let scrollView, scrollView.refreshControl === control { scrollView.refreshControl = nil }
        control = nil
    }

    func end() {
        safety?.cancel()
        safety = nil
        control?.endRefreshing()
    }

    @objc private func pulled() {
        onRefresh()
        safety?.cancel()
        let safety = DispatchWorkItem { [weak self] in self?.control?.endRefreshing() }
        self.safety = safety
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: safety)
    }
}
