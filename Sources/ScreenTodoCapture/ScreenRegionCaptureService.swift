import AppKit
import CoreGraphics
import Foundation
import OSLog

private let screenRegionCaptureLogger = Logger(subsystem: "ScreenTodoCapture", category: "ScreenRegionCapture")

/// 使用 macOS 原生框选截图能力捕获屏幕区域。
///
/// 第一版选择调用系统 `screencapture` 命令，而不是自绘选区窗口。这样能复用 macOS
/// 用户熟悉的区域选择体验，并且不会把截图写入 Clipboard（剪贴板）。临时 PNG 只用于
/// 在当前流程中读回 `NSImage`，正式证据文件仍由 `TodoStore` 写入 Captures 目录。
struct ScreenRegionCaptureService {
    var temporaryDirectory: URL = FileManager.default.temporaryDirectory

    func captureRegion() throws -> NSImage {
        requestScreenCaptureAccessIfNeeded()

        let temporaryURL = temporaryDirectory
            .appendingPathComponent("screen-todo-region-\(UUID().uuidString)")
            .appendingPathExtension("png")

        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-r", "-x", temporaryURL.path]
        let standardError = Pipe()
        process.standardError = standardError

        screenRegionCaptureLogger.info("Starting interactive region capture.")
        try process.run()
        process.waitUntilExit()
        let errorText = standardError.fileHandleForReading.readDataToEndOfFile()
        let errorMessage = String(data: errorText, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            screenRegionCaptureLogger.info("Interactive region capture cancelled or failed. status=\(process.terminationStatus, privacy: .public), stderr=\(errorMessage, privacy: .public)")
            if ScreenCaptureFailureClassifier.isPermissionDenied(errorMessage) {
                throw ScreenRegionCaptureError.screenRecordingPermissionRequired(errorMessage)
            }
            if !FileManager.default.fileExists(atPath: temporaryURL.path) {
                throw ScreenRegionCaptureError.cancelled
            }
            throw ScreenRegionCaptureError.commandFailed(process.terminationStatus, errorMessage)
        }

        guard FileManager.default.fileExists(atPath: temporaryURL.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: temporaryURL.path),
              (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 else {
            throw ScreenRegionCaptureError.cancelled
        }

        guard let image = NSImage(contentsOf: temporaryURL) else {
            throw ScreenRegionCaptureError.cannotLoadImage
        }

        screenRegionCaptureLogger.info("Interactive region capture completed.")
        return image
    }

    /// 尽量用当前 App 身份触发 Screen Recording（屏幕录制）权限提示，但不把预检结果当成硬拦截。
    ///
    /// 本地 ad-hoc 签名、自行重新安装、或刚刚在系统设置里切换权限后，TCC（隐私权限数据库）
    /// 可能短时间返回 false。真正是否能截图仍以 `/usr/sbin/screencapture` 的执行结果为准，
    /// 这样能避免“已经授权但仍被提前拦住”的假阴性。
    private func requestScreenCaptureAccessIfNeeded() {
        guard !CGPreflightScreenCaptureAccess() else {
            return
        }

        screenRegionCaptureLogger.info("Screen capture access preflight returned false; requesting and continuing to command fallback.")
        _ = CGRequestScreenCaptureAccess()
    }
}

enum ScreenCaptureFailureClassifier {
    /// 将系统截图命令的 stderr 归类。这里只做权限错误识别，取消框选仍由调用方按文件是否生成处理。
    static func isPermissionDenied(_ standardError: String) -> Bool {
        let normalized = standardError.lowercased()
        let markers = [
            "not authorized",
            "not authorised",
            "not permitted",
            "denied",
            "permission",
            "privacy",
            "screen recording",
            "tcc"
        ]
        return markers.contains { normalized.contains($0) }
    }
}

enum ScreenRegionCaptureError: LocalizedError {
    case cancelled
    case commandFailed(Int32, String)
    case cannotLoadImage
    case screenRecordingPermissionRequired(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "已取消框选截图。"
        case .commandFailed(let status, let details):
            if details.isEmpty {
                return "框选截图失败，系统截图命令退出码: \(status)"
            }
            return "框选截图失败，系统截图命令退出码: \(status)。系统返回: \(details)"
        case .cannotLoadImage:
            return "框选截图已生成，但无法读取图片。"
        case .screenRecordingPermissionRequired(let details):
            let suffix = details.isEmpty ? "" : " 系统返回: \(details)"
            return "需要授予 Screen Todo Capture 屏幕录制权限。请在系统设置 -> 隐私与安全性 -> 屏幕录制中允许 Screen Todo Capture，然后完全退出并重新打开应用。\(suffix)"
        }
    }
}
