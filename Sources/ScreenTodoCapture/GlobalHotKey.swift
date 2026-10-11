import Carbon
import Foundation

/// Global Hotkey（全局快捷键）封装。
///
/// 这里直接使用 Carbon 的 `RegisterEventHotKey`。Carbon 是 macOS 较旧的系统接口，
/// 但注册全局快捷键这一块依然简单稳定，也能避免为 MVP 引入第三方依赖。
final class GlobalHotKey: @unchecked Sendable {
    private var eventHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let handler: @MainActor () -> Void

    init(
        keyCode: UInt32,
        modifiers: UInt32,
        identifier: UInt32 = 1,
        handler: @escaping @MainActor () -> Void
    ) throws {
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // Carbon 回调不在 Swift MainActor（主线程执行上下文）里，
        // 所以回调后立刻切回 MainActor，再触发 AppKit UI 逻辑。
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else {
                    return noErr
                }

                let hotKey = Unmanaged<GlobalHotKey>
                    .fromOpaque(userData)
                    .takeUnretainedValue()

                Task { @MainActor in
                    hotKey.handler()
                }

                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        guard installStatus == noErr else {
            throw GlobalHotKeyError.installFailed(installStatus)
        }

        // `STCT` 是 Screen Todo Capture 的四字符签名，Carbon 用它区分快捷键来源。
        let hotKeyID = EventHotKeyID(signature: Self.fourCharCode("STCT"), id: identifier)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &eventHotKeyRef
        )

        guard registerStatus == noErr else {
            throw GlobalHotKeyError.registerFailed(registerStatus)
        }
    }

    /// 释放快捷键和事件处理器，避免应用退出时留下无效注册。
    deinit {
        if let eventHotKeyRef {
            UnregisterEventHotKey(eventHotKeyRef)
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    /// Carbon API 使用四字符整数签名，这里把 "STCT" 转成对应的 OSType。
    private static func fourCharCode(_ string: String) -> OSType {
        string.utf8.reduce(0) { result, character in
            (result << 8) + OSType(character)
        }
    }
}

/// 全局快捷键注册阶段可能出现的错误。
enum GlobalHotKeyError: LocalizedError {
    case installFailed(OSStatus)
    case registerFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .installFailed(let status):
            return "安装全局快捷键事件处理器失败，错误码: \(status)"
        case .registerFailed(let status):
            return "注册全局快捷键失败，错误码: \(status)"
        }
    }
}
