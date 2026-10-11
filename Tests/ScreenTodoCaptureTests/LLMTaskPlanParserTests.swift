import Foundation
@testable import ScreenTodoCapture
import XCTest

final class LLMTaskPlanParserTests: XCTestCase {
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

        XCTAssertEqual(plan.title, "提交第 3 章作业")
        XCTAssertNil(plan.correctedText)
        XCTAssertEqual(plan.summary, "按要求提交作业。")
        XCTAssertEqual(plan.plannedSteps, ["确认要求", "完成题目", "提交 Canvas"])
        XCTAssertNil(plan.dueDate)
        XCTAssertEqual(plan.estimatedMinutes, 45)
        XCTAssertEqual(plan.difficultyScore, 10)
        XCTAssertEqual(plan.tags, ["学校", "作业"])
        XCTAssertEqual(plan.priority, "urgent")
        XCTAssertEqual(try XCTUnwrap(plan.confidence), 0.85, accuracy: 0.001)
    }
}
