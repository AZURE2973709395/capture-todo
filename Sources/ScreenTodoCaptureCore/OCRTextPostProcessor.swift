import CoreGraphics
import Foundation

/// OCR（光学字符识别）返回的一段文字及其在图片中的位置。
///
/// Vision（苹果图像识别框架）给出的坐标是归一化坐标，范围通常是 0...1。
/// 这里保留 `boundingBox`，是为了在后处理时按视觉顺序重排聊天文本。
public struct OCRObservation: Equatable, Sendable {
    public var text: String
    public var boundingBox: CGRect
    public var confidence: Float

    public init(text: String, boundingBox: CGRect, confidence: Float) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

/// 把 Vision OCR 的分散识别结果整理成更接近人类阅读顺序的纯文本。
///
/// 聊天截图里的文字常被识别成多个小块，所以这里会做三件事：
/// 1. 清理空白字符。
/// 2. 过滤低置信度结果。
/// 3. 按 y 坐标从上到下、按 x 坐标从左到右恢复行顺序。
public struct OCRTextPostProcessor {
    private let minimumConfidence: Float
    private let sameLineThreshold: CGFloat

    public init(minimumConfidence: Float = 0.3, sameLineThreshold: CGFloat = 0.022) {
        self.minimumConfidence = minimumConfidence
        self.sameLineThreshold = sameLineThreshold
    }

    /// 返回清洗后的 OCR 文本，供待办标题生成和原文留档使用。
    public func normalizedText(from observations: [OCRObservation]) -> String {
        let candidates = observations
            .map { observation in
                OCRObservation(
                    text: normalizeWhitespace(observation.text),
                    boundingBox: observation.boundingBox,
                    confidence: observation.confidence
                )
            }
            .filter { !$0.text.isEmpty && $0.confidence >= minimumConfidence }
            .sorted { lhs, rhs in
                let yDistance = abs(lhs.boundingBox.midY - rhs.boundingBox.midY)
                if yDistance > sameLineThreshold {
                    return lhs.boundingBox.midY > rhs.boundingBox.midY
                }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }

        // Vision 的坐标原点在左下角，所以 y 值越大越靠近截图顶部。
        var groupedLines: [[OCRObservation]] = []
        for candidate in candidates {
            guard let lastLine = groupedLines.last,
                  let anchor = lastLine.first,
                  abs(anchor.boundingBox.midY - candidate.boundingBox.midY) <= sameLineThreshold else {
                groupedLines.append([candidate])
                continue
            }

            groupedLines[groupedLines.count - 1].append(candidate)
        }

        return groupedLines
            .map { line in
                line
                    .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                    .map(\.text)
                    .joined(separator: " ")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 将一段文本内部连续空格、换行压成单个空格，减少 OCR 噪声。
    private func normalizeWhitespace(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
