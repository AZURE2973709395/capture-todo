import Foundation
import ScreenTodoCaptureCore
@testable import ScreenTodoCapture
import Testing

final class TodoDraftGeneratorTests {
    @Test
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

        #expect(draft.title.contains("第 3 章作业"))
        #expect(draft.dueHint == "周五")
        #expect(draft.sourceApplication == "微信")
    }

    @Test
    func testDefaultPlanningPromptContainsSchoolTaskGuidance() {
        let prompt = AppConfigStore().defaultSystemPrompt

        #expect(prompt.contains("学校任务"))
        #expect(prompt.contains("课程名"))
        #expect(prompt.contains("完成标准"))
        #expect(prompt.contains("不要编造"))
    }
}
