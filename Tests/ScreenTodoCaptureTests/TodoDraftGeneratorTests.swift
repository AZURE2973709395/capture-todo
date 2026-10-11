import Foundation
import ScreenTodoCaptureCore
@testable import ScreenTodoCapture
import XCTest

final class TodoDraftGeneratorTests: XCTestCase {
    func testSchoolAssignmentTextBecomesUsefulFallbackDraft() {
        let text = """
        发送
        高等数学群
        第 3 章作业周五 23:59 前提交到 Canvas
        图片
        """

        let draft = TodoDraftGenerator().makeDraft(
            from: text,
            sourceApplication: "微信",
            createdAt: Date(timeIntervalSince1970: 1_800_000_500)
        )

        XCTAssertTrue(draft.title.contains("第 3 章作业"))
        XCTAssertEqual(draft.dueHint, "周五")
        XCTAssertEqual(draft.sourceApplication, "微信")
    }

    func testDefaultPlanningPromptContainsSchoolTaskGuidance() {
        let prompt = AppConfigStore().defaultSystemPrompt

        XCTAssertTrue(prompt.contains("学校任务"))
        XCTAssertTrue(prompt.contains("课程名"))
        XCTAssertTrue(prompt.contains("完成标准"))
        XCTAssertTrue(prompt.contains("不要编造"))
    }
}
