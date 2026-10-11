import Foundation
@testable import ScreenTodoCapture
import Testing

final class LLMTaskPlanParserTests {
    @Test
    func testParserToleratesFencedJSONLooseNumbersAndAliases() throws {
        let content = #"""
        ```json
        {
          "title": "  提交第 3 章作业  ",
          "corrected_text": "   ",
          "summary": "按要求提交作业。",
          "steps": "确认要求，完成题目\n提交 Canvas",
          "due_date": "",
          "estimated_minutes": "约 45 分钟",
          "difficulty": "medium",
          "difficulty_score": 12,
          "tags": "学校，作业，学校",
          "priority": "紧急",
          "confidence": "85 %"
        }
        ```
        """#

        let plan = try LLMTaskPlanParser.parsePlan(from: content)

        #expect(plan.title == "提交第 3 章作业")
        #expect(plan.correctedText == nil)
        #expect(plan.summary == "按要求提交作业。")
        #expect(plan.plannedSteps == ["确认要求", "完成题目", "提交 Canvas"])
        #expect(plan.dueDate == nil)
        #expect(plan.estimatedMinutes == 45)
        #expect(plan.difficultyScore == 10)
        #expect(plan.tags == ["学校", "作业"])
        #expect(plan.priority == "urgent")
        #expect(abs((try #require(plan.confidence)) - (0.85)) <= 0.001)
    }
}
