import Foundation
@testable import ScreenTodoCapture
import Testing

final class TodoPriorityTests {
    @Test
    func testNormalizeAcceptsKnownAliasesAndRejectsUnknownValues() {
        #expect(TodoPriority.normalize(" 高优先级 ") == "high")
        #expect(TodoPriority.normalize("normal") == "medium")
        #expect(TodoPriority.normalize("立即") == "urgent")
        #expect(TodoPriority.normalize("LOW") == "low")
        #expect(TodoPriority.normalize("later") == nil)
        #expect(TodoPriority.normalize("   ") == nil)
    }

    @Test
    func testClampHelpersKeepPlannerScoresInSupportedRanges() {
        #expect(TodoPriority.clampDifficultyScore(0) == 1)
        #expect(TodoPriority.clampDifficultyScore(11) == 10)
        #expect(TodoPriority.clampDifficultyScore(6) == 6)
        #expect(TodoPriority.clampConfidence(-0.2) == 0)
        #expect(TodoPriority.clampConfidence(1.3) == 1)
        #expect(TodoPriority.clampConfidence(0.72) == 0.72)
    }
}
