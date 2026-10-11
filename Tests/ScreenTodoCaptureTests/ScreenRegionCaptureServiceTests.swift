@testable import ScreenTodoCapture
import Testing

final class ScreenRegionCaptureServiceTests {
    @Test
    func testFailureClassifierDetectsScreenRecordingPermissionErrors() {
        #expect(ScreenCaptureFailureClassifier.isPermissionDenied(
            "screencapture: not authorized to capture the screen"
        ))
        #expect(ScreenCaptureFailureClassifier.isPermissionDenied(
            "Screen Recording permission is required by privacy policy"
        ))
    }

    @Test
    func testFailureClassifierDoesNotTreatCancellationAsPermissionError() {
        #expect(!(ScreenCaptureFailureClassifier.isPermissionDenied("")))
        #expect(!(ScreenCaptureFailureClassifier.isPermissionDenied(
            "user cancelled interactive capture"
        )))
    }
}
