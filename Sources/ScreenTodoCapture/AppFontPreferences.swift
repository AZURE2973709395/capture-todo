import AppKit

enum AppFontRole: String {
    case largeTitle
    case title
    case body
    case bodySemibold
    case caption
    case captionSemibold
    case monospace
    case control
}

/// 全局 UI 字号偏好。
///
/// 只写入 UserDefaults（macOS 用户偏好），不写入大模型 config.json。
@MainActor
enum AppFontPreferences {
    static let minimumSize: Double = 12
    static let maximumSize: Double = 20
    static let defaultSize: Double = 14
    static let didChangeNotification = Notification.Name("ScreenTodoCaptureAppFontDidChange")

    private static let userDefaultsKey = "uiFontSize"

    static var size: CGFloat {
        get {
            let value = UserDefaults.standard.double(forKey: userDefaultsKey)
            let resolved = value == 0 ? defaultSize : value
            return CGFloat(clamp(resolved))
        }
        set {
            let rounded = round(Double(newValue))
            let clamped = clamp(rounded)
            guard CGFloat(clamped) != size else {
                return
            }

            UserDefaults.standard.set(clamped, forKey: userDefaultsKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    static func font(_ role: AppFontRole) -> NSFont {
        let base = size
        switch role {
        case .largeTitle:
            return .boldSystemFont(ofSize: base + 8)
        case .title:
            return .boldSystemFont(ofSize: base + 4)
        case .body:
            return .systemFont(ofSize: base)
        case .bodySemibold:
            return .systemFont(ofSize: base, weight: .semibold)
        case .caption:
            return .systemFont(ofSize: max(11, base - 2))
        case .captionSemibold:
            return .systemFont(ofSize: max(11, base - 2), weight: .semibold)
        case .monospace:
            return .monospacedSystemFont(ofSize: max(11, base - 1), weight: .regular)
        case .control:
            return .systemFont(ofSize: base)
        }
    }

    static var tableRowHeight: CGFloat {
        max(68, size * 4.9)
    }

    static func apply(_ role: AppFontRole, to view: NSView) {
        view.identifier = NSUserInterfaceItemIdentifier(role.rawValue)
        applyFont(to: view, role: role)
    }

    static func applyFontsRecursively(to view: NSView) {
        if let role = view.identifier.flatMap({ AppFontRole(rawValue: $0.rawValue) }) {
            applyFont(to: view, role: role)
        } else if let textView = view as? NSTextView {
            textView.font = font(.monospace)
        } else if let textField = view as? NSTextField {
            textField.font = font(.body)
        } else if let control = view as? NSControl {
            control.font = font(.control)
        }

        for subview in view.subviews {
            applyFontsRecursively(to: subview)
        }
    }

    private static func applyFont(to view: NSView, role: AppFontRole) {
        if let textView = view as? NSTextView {
            textView.font = font(role)
        } else if let textField = view as? NSTextField {
            textField.font = font(role)
        } else if let control = view as? NSControl {
            control.font = font(role)
        }
    }

    private static func clamp(_ value: Double) -> Double {
        min(maximumSize, max(minimumSize, value))
    }
}
