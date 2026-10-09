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
