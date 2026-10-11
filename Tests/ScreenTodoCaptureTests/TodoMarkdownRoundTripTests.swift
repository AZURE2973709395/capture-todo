import Foundation
import ScreenTodoCaptureCore
@testable import ScreenTodoCapture
import XCTest

final class TodoMarkdownRoundTripTests: XCTestCase {
    func testParseConfidenceAcceptsLoosePercentAndDecimalFormats() throws {
        let cases: [(String, Double)] = [
            ("85 %", 0.85),
            ("85％", 0.85),
            ("85 ％", 0.85),
            ("0.85", 0.85)
        ]

        for (input, expected) in cases {
            let confidence = try XCTUnwrap(TodoMarkdownParser.parseConfidence(input), input)
            XCTAssertEqual(confidence, expected, accuracy: 0.0001, input)
        }
    }

    func testMarkdownRoundTripKeepsLLMPlanningFieldsAndHistory() throws {
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let draft = TodoDraft(
            title: "整理合同反馈",
            originalText: "明天下午前把合同修改意见发给客户",
            correctedText: "明天下午前把合同修改意见发给客户。",
            sourceApplication: "微信",
            dueHint: "明天",
            dueDate: "2027-01-15T08:00:00+08:00",
            summary: "需要整理并发送合同修改意见。",
            plannedSteps: ["确认修改点", "整理成清单", "发送给客户"],
            estimatedMinutes: 45,
            difficulty: "medium",
            difficultyScore: 5,
            tags: ["工作", "合同"],
            priority: "high",
            confidence: 0.82,
            createdAt: createdAt,
            screenshotRelativePath: "Captures/sample.png",
            reminderIdentifier: "reminder-1",
            reminderSyncedAt: "2027-01-15T08:10:00+08:00",
            reminderSyncStatus: "synced"
        )
        let history = TodoPlanHistory(
            capturedAt: createdAt.addingTimeInterval(60),
            title: "旧标题",
            summary: "旧摘要",
            plannedSteps: ["旧步骤"],
            estimatedMinutes: "30 分钟",
            difficulty: "easy",
            difficultyScore: 3,
            tags: ["旧标签"],
            priority: "low",
            confidence: 0.4
        )

        let markdown = TodoMarkdownExporter.markdown(
            draft: draft,
            status: "待处理",
            histories: [history]
        )
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = TodoStore(rootDirectoryOverride: temporaryRoot)
        let fileURL = store.todosDirectory.appendingPathComponent("sample.md")

        let record = try XCTUnwrap(TodoMarkdownParser.parse(fileURL: fileURL, content: markdown, store: store))
        XCTAssertEqual(record.title, "整理合同反馈")
        XCTAssertEqual(record.tags, ["工作", "合同"])
        XCTAssertEqual(record.priority, "high")
        XCTAssertEqual(try XCTUnwrap(record.confidence), 0.82, accuracy: 0.001)
        XCTAssertEqual(record.planHistories.count, 1)
        XCTAssertEqual(record.planHistories.first?.title, "旧标题")
        XCTAssertEqual(record.planHistories.first?.plannedSteps, ["旧步骤"])
        XCTAssertEqual(record.reminderIdentifier, "reminder-1")
        XCTAssertEqual(record.reminderSyncStatus, "synced")
    }

    func testTodoStoreReplanPreservesOldPlanAsHistory() throws {
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let store = TodoStore(rootDirectoryOverride: temporaryRoot)
        let originalDraft = TodoDraft(
            title: "旧规划任务",
            originalText: "今晚整理截图待办",
            sourceApplication: "测试",
            summary: "旧摘要",
            plannedSteps: ["旧步骤"],
            estimatedMinutes: 20,
            difficulty: "easy",
            difficultyScore: 2,
            tags: ["测试"],
            priority: "low",
            confidence: 0.5,
            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
        )

        _ = try store.save(draft: originalDraft, image: nil)
        let originalRecord = try XCTUnwrap(try TodoRecordLoader(store: store).load().first)
        var replannedDraft = originalRecord.makeDraftForPlanning()
        replannedDraft.title = "新规划任务"
        replannedDraft.summary = "新摘要"
        replannedDraft.plannedSteps = ["新步骤一", "新步骤二"]
        replannedDraft.tags = ["自动化", "测试"]
        replannedDraft.priority = "urgent"
        replannedDraft.confidence = 0.91

        try store.replacePlan(record: originalRecord, with: replannedDraft)

        let updatedRecord = try XCTUnwrap(try TodoRecordLoader(store: store).load().first)
        XCTAssertEqual(updatedRecord.title, "新规划任务")
        XCTAssertEqual(updatedRecord.priority, "urgent")
        XCTAssertEqual(updatedRecord.tags, ["自动化", "测试"])
        XCTAssertEqual(try XCTUnwrap(updatedRecord.confidence), 0.91, accuracy: 0.001)
        XCTAssertEqual(updatedRecord.planHistories.count, 1)
        XCTAssertEqual(updatedRecord.planHistories.first?.title, "旧规划任务")
        XCTAssertEqual(updatedRecord.planHistories.first?.priority, "low")
    }

    @MainActor
    func testCapturePipelineFallsBackToLocalDraftWhenLLMFails() async throws {
        enum TestError: Error { case llmFailure }

        let image = NSImage(size: NSSize(width: 10, height: 10))
        let todoURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pipeline.md")
        var savedDraft: TodoDraft?
        var events: [CapturePipelineEvent] = []
        let config = LLMConfig(
            enabled: true,
            baseURL: URL(string: "https://example.com/v1")!,
            apiKey: "test",
            model: "test-model",
            systemPrompt: "test"
        )

        let pipeline = CapturePipeline(
            recognizeText: { _ in "明天提交预算表" },
            makeDraft: { text, source, createdAt in
                TodoDraft(
                    title: "本地标题",
                    originalText: text,
                    sourceApplication: source,
                    createdAt: createdAt
                )
            },
            loadLLMConfig: { config },
            planDraft: { _, _ in throw TestError.llmFailure },
            saveTodo: { draft, _ in
                savedDraft = draft
                return StoredTodo(todoURL: todoURL, screenshotURL: nil)
            },
            eventHandler: { events.append($0) },
            now: { Date(timeIntervalSince1970: 1_800_000_200) }
        )

        let result = try await pipeline.run(image: image, sourceApplication: "测试应用")
        XCTAssertEqual(savedDraft?.title, "本地标题")
        XCTAssertEqual(result.recognizedText, "明天提交预算表")
        XCTAssertFalse(result.didUseLLMPlanning)
        XCTAssertNotNil(result.llmPlanningErrorDescription)
        XCTAssertEqual(events.count, 2)
    }

    func testTodoQueryFiltersSearchTagsPriorityAndToday() throws {
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let store = TodoStore(rootDirectoryOverride: temporaryRoot)
        let referenceDate = TodoRecordLoader.parseDate("2027-01-15 10:00")!
        let yesterday = TodoRecordLoader.displayDate(Calendar.current.date(byAdding: .day, value: -1, to: referenceDate)!)
        let today = TodoRecordLoader.displayDate(referenceDate)
        let future = TodoRecordLoader.displayDate(Calendar.current.date(byAdding: .day, value: 5, to: referenceDate)!)

        _ = try store.save(draft: TodoDraft(
            title: "准备预算表",
            originalText: "请今天提交预算表",
            sourceApplication: "微信",
            dueDate: today,
            summary: "提交预算材料",
            plannedSteps: ["整理预算"],
            tags: ["工作"],
            priority: "high",
            createdAt: Date(timeIntervalSince1970: 1_800_000_300)
        ), image: nil)
        _ = try store.save(draft: TodoDraft(
            title: "过期合同",
            originalText: "昨天要确认合同",
            sourceApplication: "QQ",
            dueDate: yesterday,
            summary: "确认合同细节",
            tags: ["合同"],
            priority: "urgent",
            createdAt: Date(timeIntervalSince1970: 1_800_000_301)
        ), image: nil)
        _ = try store.save(draft: TodoDraft(
            title: "未来个人任务",
            originalText: "下周整理照片",
            sourceApplication: "备忘录",
            dueDate: future,
            summary: "个人事项",
            tags: ["个人"],
            priority: "low",
            createdAt: Date(timeIntervalSince1970: 1_800_000_302)
        ), image: nil)

        let searchResults = try TodoRecordLoader(
            store: store,
            query: TodoQuery(searchText: "预算", priority: "high"),
            referenceDate: referenceDate
        ).load()
        XCTAssertEqual(searchResults.map(\.title), ["准备预算表"])

        let tagResults = try TodoRecordLoader(
            store: store,
            query: TodoQuery(tag: "合同", priority: "urgent"),
            referenceDate: referenceDate
        ).load()
        XCTAssertEqual(tagResults.map(\.title), ["过期合同"])

        let todayResults = try TodoRecordLoader(
            store: store,
            query: TodoQuery(timeRange: .today, view: .today),
            referenceDate: referenceDate
        ).load()
        XCTAssertEqual(Set(todayResults.map(\.title)), Set(["准备预算表", "过期合同"]))
    }
}
