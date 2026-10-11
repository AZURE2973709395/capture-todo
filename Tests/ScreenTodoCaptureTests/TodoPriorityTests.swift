import Foundation
@testable import ScreenTodoCapture
import XCTest

final class TodoPriorityTests: XCTestCase {
    func testNormalizeAcceptsKnownAliasesAndRejectsUnknownValues() {
        XCTAssertEqual(TodoPriority.normalize(" 高优先级 "), "high")
        XCTAssertEqual(TodoPriority.normalize("normal"), "medium")
        XCTAssertEqual(TodoPriority.normalize("立即"), "urgent")
        XCTAssertEqual(TodoPriority.normalize("LOW"), "low")
        XCTAssertNil(TodoPriority.normalize("later"))
        XCTAssertNil(TodoPriority.normalize("   "))
    }

    func testClampHelpersKeepPlannerScoresInSupportedRanges() {
        XCTAssertEqual(TodoPriority.clampDifficultyScore(0), 1)
        XCTAssertEqual(TodoPriority.clampDifficultyScore(11), 10)
        XCTAssertEqual(TodoPriority.clampDifficultyScore(6), 6)
        XCTAssertEqual(TodoPriority.clampConfidence(-0.2), 0)
        XCTAssertEqual(TodoPriority.clampConfidence(1.3), 1)
        XCTAssertEqual(TodoPriority.clampConfidence(0.72), 0.72)
    }
}
