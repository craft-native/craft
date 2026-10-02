import UIKit

/// The result of a Craft action, independent of whether the caller is a
/// WebKit page or the JavaScriptCore native-screen runtime.
struct CraftNativeActionError: Error {
    let code: String
    let message: String
}

enum CraftNativeActions {
    /// Nil means this small shared router does not own the action. Both hosts
    /// can then continue through their existing unsupported-action path.
    static func perform(action: String, body: [String: Any], config: CraftConfig) -> Result<Any, CraftNativeActionError>? {
        switch action {
        case "getDeviceInfo":
            return .success(deviceInfo())
        case "haptic":
            guard config.enableHaptics else {
                return .failure(CraftNativeActionError(code: "CAPABILITY_DISABLED", message: "Haptics is disabled"))
            }
            triggerHaptic(style: body["style"] as? String ?? "medium")
            return .success(true)
        case "clipboardWrite":
            guard config.enableClipboard else {
                return .failure(CraftNativeActionError(code: "CAPABILITY_DISABLED", message: "Clipboard is disabled"))
            }
            guard let text = body["text"] as? String else {
                return .failure(CraftNativeActionError(code: "INVALID_ARGUMENT", message: "clipboardWrite was called without the values it needs"))
            }
            UIPasteboard.general.string = text
            return .success(true)
        case "clipboardRead":
            guard config.enableClipboard else {
                return .failure(CraftNativeActionError(code: "CAPABILITY_DISABLED", message: "Clipboard is disabled"))
            }
            return .success(UIPasteboard.general.string ?? "")
        default:
            return nil
        }
    }

    static func triggerHaptic(style: String) {
        switch style {
        case "light":
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case "heavy":
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case "success":
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "warning":
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case "error":
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case "selection":
            UISelectionFeedbackGenerator().selectionChanged()
        default:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private static func deviceInfo() -> [String: Any] {
        let device = UIDevice.current
        let screen = UIScreen.main
        #if targetEnvironment(simulator)
        let isSimulator = true
        #else
        let isSimulator = false
        #endif
        let batteryState: String
        switch device.batteryState {
        case .charging: batteryState = "charging"
        case .full: batteryState = "full"
        case .unplugged: batteryState = "unplugged"
        default: batteryState = "unknown"
        }
        return [
            "platform": "ios",
            "model": device.model,
            "name": device.name,
            "systemName": device.systemName,
            "systemVersion": device.systemVersion,
            "identifierForVendor": device.identifierForVendor?.uuidString ?? "",
            "isSimulator": isSimulator,
            "screenWidth": screen.bounds.width,
            "screenHeight": screen.bounds.height,
            "screenScale": screen.scale,
            "batteryLevel": device.batteryLevel,
            "batteryState": batteryState,
            "locale": Locale.current.identifier,
            "timezone": TimeZone.current.identifier
        ]
    }
}
