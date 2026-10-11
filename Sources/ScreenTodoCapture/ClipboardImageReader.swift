import AppKit

/// 从 macOS Clipboard（剪贴板）读取图片。
///
/// 第一版刻意走剪贴板路径：用户用系统截图快捷键复制区域后，本应用只读取那张图。
/// 这样不需要 Screen Recording Permission（屏幕录制权限），权限成本最低。
struct ClipboardImageReader {
    /// 读取当前剪贴板图片；如果剪贴板没有图片，则抛出面向用户的错误。
    func readImage() throws -> NSImage {
        let pasteboard = NSPasteboard.general

        if let image = NSImage(pasteboard: pasteboard) {
            return image
        }

        throw OCRCaptureError.noImageInClipboard
    }
}
