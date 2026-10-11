import AppKit
import ScreenTodoCaptureCore
import Vision

/// 使用 Apple Vision（苹果图像识别框架）做本地 OCR（光学字符识别）。
///
/// 识别在本机完成，截图内容不会因为 OCR 这一步上传到云端。
struct ImageOCRService {
    private let postProcessor = OCRTextPostProcessor()

    /// 识别 `NSImage` 中的文字，并返回经过排序、清洗后的纯文本。
    func recognizeText(in image: NSImage) throws -> String {
        guard let cgImage = image.cgImageForOCR() else {
            throw OCRCaptureError.cannotCreateCGImage
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // 聊天场景常见中文和英文混排，先覆盖简体中文、繁体中文和英文。
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let observations = (request.results ?? []).compactMap { observation -> OCRObservation? in
            guard let candidate = observation.topCandidates(1).first else {
                return nil
            }

            return OCRObservation(
                text: candidate.string,
                boundingBox: observation.boundingBox,
                confidence: candidate.confidence
            )
        }

        return postProcessor.normalizedText(from: observations)
    }
}

/// 捕获和识别阶段会展示给用户的错误。
enum OCRCaptureError: LocalizedError {
    case noImageInClipboard
    case cannotCreateCGImage
    case emptyRecognitionResult

    var errorDescription: String? {
        switch self {
        case .noImageInClipboard:
            return "剪贴板里没有图片。请先用 Command + Control + Shift + 4 截图到剪贴板。"
        case .cannotCreateCGImage:
            return "无法读取这张截图。"
        case .emptyRecognitionResult:
            return "没有识别到可用文字。"
        }
    }
}

private extension NSImage {
    /// Vision 需要 `CGImage` 输入；剪贴板图片在 AppKit 中通常先表现为 `NSImage`。
    func cgImageForOCR() -> CGImage? {
        var rect = NSRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
