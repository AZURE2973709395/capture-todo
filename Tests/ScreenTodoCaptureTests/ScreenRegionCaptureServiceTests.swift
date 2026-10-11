@testable import ScreenTodoCapture
import XCTest

final class ScreenRegionCaptureServiceTests: XCTestCase {
    func testFailureClassifierDetectsScreenRecordingPermissionErrors() {
        XCTAssertTrue(ScreenCaptureFailureClassifier.isPermissionDenied(
            "screencapture: not authorized to capture the screen"
        ))
        XCTAssertTrue(ScreenCaptureFailureClassifier.isPermissionDenied(
            "Screen Recording permission is required by privacy policy"
        ))
    }

    func testFailureClassifierDoesNotTreatCancellationAsPermissionError() {
        XCTAssertFalse(ScreenCaptureFailureClassifier.isPermissionDenied(""))
        XCTAssertFalse(ScreenCaptureFailureClassifier.isPermissionDenied(
            "user cancelled interactive capture"
        ))
    }
}
