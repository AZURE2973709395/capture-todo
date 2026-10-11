import AppKit
import OSLog
import ScreenTodoCaptureCore

private let capturePipelineLogger = Logger(subsystem: "ScreenTodoCapture", category: "CapturePipeline")

/// Capture pipeline 生命周期事件。
///
/// Pipeline 不直接操作 AppKit UI；调用方可以把这些事件映射成菜单栏提示、窗口状态或日志。
enum CapturePipelineEvent {
    case llmPlanningStarted
    case llmPlanningFailed(message: String)
}

/// 一次截图创建待办的完整结果。
///
/// `draft` 是最终用于保存的草稿，已经包含本地规则和可用的 LLM 规划结果；
/// `storedTodo` 是 Markdown source-of-truth 和截图证据写盘后的路径，用于刷新 UI 或调试。
struct CapturePipelineResult {
    var storedTodo: StoredTodo
    var draft: TodoDraft
    var recognizedText: String
    var didUseLLMPlanning: Bool
    var llmPlanningErrorDescription: String?

    var title: String {
        draft.title
    }
}

/// 截图到待办的应用层编排器。
///
/// 输入是一张已经获取到的 `NSImage` 和来源应用名称；输出是已保存的待办结果。
/// 这一层集中维护 OCR、草稿生成、可选 LLM 规划、本地兜底和 Markdown/SQLite 保存顺序，
/// 让剪贴板截图和框选截图两个入口共享同一套业务语义。
@MainActor
struct CapturePipeline {
    typealias RecognizeText = (NSImage) throws -> String
    typealias MakeDraft = (_ recognizedText: String, _ sourceApplication: String, _ createdAt: Date) -> TodoDraft
    typealias LoadLLMConfig = () -> LLMConfig?
    typealias PlanDraft = (_ draft: TodoDraft, _ config: LLMConfig) async throws -> TodoDraft
    typealias SaveTodo = (_ draft: TodoDraft, _ image: NSImage) throws -> StoredTodo
    typealias EventHandler = (CapturePipelineEvent) -> Void

    private let recognizeText: RecognizeText
    private let makeDraft: MakeDraft
    private let loadLLMConfig: LoadLLMConfig
    private let planDraft: PlanDraft
    private let saveTodo: SaveTodo
    private let eventHandler: EventHandler?
    private let now: () -> Date

    init(
        ocrService: ImageOCRService = ImageOCRService(),
        draftGenerator: TodoDraftGenerator = TodoDraftGenerator(),
        store: TodoStore,
        configStore: AppConfigStore,
        eventHandler: EventHandler? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.init(
            recognizeText: { image in
                try ocrService.recognizeText(in: image)
            },
            makeDraft: { recognizedText, sourceApplication, createdAt in
                draftGenerator.makeDraft(
                    from: recognizedText,
                    sourceApplication: sourceApplication,
                    createdAt: createdAt
                )
            },
            loadLLMConfig: {
                configStore.loadLLMConfig()
            },
            planDraft: { draft, config in
                try await LLMTaskPlanner(config: config).planNewTask(draft)
            },
            saveTodo: { draft, image in
                try store.save(draft: draft, image: image)
            },
            eventHandler: eventHandler,
            now: now
        )
    }

    init(
        recognizeText: @escaping RecognizeText,
        makeDraft: @escaping MakeDraft,
        loadLLMConfig: @escaping LoadLLMConfig,
        planDraft: @escaping PlanDraft,
        saveTodo: @escaping SaveTodo,
        eventHandler: EventHandler? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.recognizeText = recognizeText
        self.makeDraft = makeDraft
        self.loadLLMConfig = loadLLMConfig
        self.planDraft = planDraft
        self.saveTodo = saveTodo
        self.eventHandler = eventHandler
        self.now = now
    }

    /// 执行 OCR -> 本地草稿 -> 可选 LLM 规划 -> 本地保存。
    ///
    /// LLM 失败只会记录并返回错误描述，最终仍保存本地规则生成的草稿；OCR 和保存失败
    /// 属于不可继续的错误，会向上抛出交给 UI 展示。
    func run(image: NSImage, sourceApplication: String) async throws -> CapturePipelineResult {
        capturePipelineLogger.info("Starting capture pipeline. source=\(sourceApplication, privacy: .public)")

        let recognizedText = try recognizeText(image)
        let trimmedText = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            capturePipelineLogger.warning("OCR returned empty text. source=\(sourceApplication, privacy: .public)")
            throw OCRCaptureError.emptyRecognitionResult
        }

        capturePipelineLogger.info("OCR completed. characters=\(recognizedText.count, privacy: .public)")
        var draft = makeDraft(recognizedText, sourceApplication, now())
        var didUseLLMPlanning = false
        var llmPlanningErrorDescription: String?

        if let llmConfig = loadLLMConfig() {
            eventHandler?(.llmPlanningStarted)
            capturePipelineLogger.info("LLM planning enabled. model=\(llmConfig.model, privacy: .public)")

            do {
                draft = try await planDraft(draft, llmConfig)
                didUseLLMPlanning = true
                capturePipelineLogger.info("LLM planning completed.")
            } catch {
                let message = Self.localizedMessage(from: error)
                llmPlanningErrorDescription = message
                eventHandler?(.llmPlanningFailed(message: message))
                capturePipelineLogger.error("LLM planning failed; falling back to local draft. error=\(message, privacy: .public)")
            }
        } else {
            capturePipelineLogger.info("LLM planning skipped because no enabled configuration is available.")
        }

        let storedTodo = try saveTodo(draft, image)
        capturePipelineLogger.info("Capture pipeline saved todo. title=\(draft.title, privacy: .public)")

        return CapturePipelineResult(
            storedTodo: storedTodo,
            draft: draft,
            recognizedText: recognizedText,
            didUseLLMPlanning: didUseLLMPlanning,
            llmPlanningErrorDescription: llmPlanningErrorDescription
        )
    }

    private static func localizedMessage(from error: Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description
        }

        return error.localizedDescription
    }
}
