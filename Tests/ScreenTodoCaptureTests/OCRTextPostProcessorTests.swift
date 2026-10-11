import CoreGraphics
import ScreenTodoCaptureCore
import Testing

final class OCRTextPostProcessorTests {
    @Test
    func testNormalizedTextOrdersObservationsByVisualReadingOrder() {
        let observations = [
            OCRObservation(text: "Canvas", boundingBox: CGRect(x: 0.50, y: 0.80, width: 0.20, height: 0.04), confidence: 0.95),
            OCRObservation(text: "提交到", boundingBox: CGRect(x: 0.20, y: 0.80, width: 0.20, height: 0.04), confidence: 0.94),
            OCRObservation(text: "周五前", boundingBox: CGRect(x: 0.20, y: 0.60, width: 0.20, height: 0.04), confidence: 0.96)
        ]

        let text = OCRTextPostProcessor().normalizedText(from: observations)

        #expect(text == "提交到 Canvas\n周五前")
    }

    @Test
    func testNormalizedTextDropsLowConfidenceAndEmptyObservations() {
        let observations = [
            OCRObservation(text: "  论文初稿  ", boundingBox: CGRect(x: 0.10, y: 0.70, width: 0.40, height: 0.04), confidence: 0.91),
            OCRObservation(text: "噪声", boundingBox: CGRect(x: 0.10, y: 0.60, width: 0.20, height: 0.04), confidence: 0.10),
            OCRObservation(text: "   ", boundingBox: CGRect(x: 0.10, y: 0.50, width: 0.20, height: 0.04), confidence: 0.99)
        ]

        let text = OCRTextPostProcessor().normalizedText(from: observations)

        #expect(text == "论文初稿")
    }
}
