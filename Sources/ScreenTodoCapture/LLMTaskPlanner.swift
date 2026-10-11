import Foundation
import OSLog
import ScreenTodoCaptureCore

private let llmPlannerLogger = Logger(subsystem: "ScreenTodoCapture", category: "LLMTaskPlanner")

private struct LLMTaskPlanningRequest: Encodable {
    var model: String
    var messages: [Message]
    var temperature: Double
    var response_format: ResponseFormat

    struct Message: Encodable {
        var role: String
        var content: String
    }

    struct ResponseFormat: Encodable {
        var type: String
    }
}

private struct LLMTaskPlanningResponse: Decodable {
    var choices: [Choice]

    struct Choice: Decodable {
        var message: Message
    }

    struct Message: Decodable {
        var content: String
    }
}

/// 直接对应模型 JSON 输出的 DTO（数据传输对象）。
///
/// 这里故意支持数字字段用字符串返回的情况，因为不同 OpenAI-compatible
///（兼容 OpenAI 格式）接口对 JSON 输出的稳定性不同。清洗后的强类型对象由
/// `todoPlan()` 生成，调用方不需要再理解模型输出细节。
private struct LLMTaskPlanPayload: Decodable {
    var title: String?
    var correctedText: String?
    var summary: String?
    var steps: [String]
    var dueDate: String?
    var estimatedMinutes: Int?
    var difficulty: String?
    var difficultyScore: Int?
    var tags: [String]
    var priority: String?
    var confidence: Double?

    enum CodingKeys: String, CodingKey {
        case title
        case correctedText = "corrected_text"
        case summary
        case steps
        case dueDate = "due_date"
        case estimatedMinutes = "estimated_minutes"
        case difficulty
        case difficultyScore = "difficulty_score"
        case tags
        case priority
        case confidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeTrimmedStringIfPresent(forKey: .title)
        correctedText = try container.decodeTrimmedStringIfPresent(forKey: .correctedText)
        summary = try container.decodeTrimmedStringIfPresent(forKey: .summary)
        steps = try container.decodeStringArrayIfPresent(forKey: .steps)
        dueDate = try container.decodeTrimmedStringIfPresent(forKey: .dueDate)
        estimatedMinutes = try container.decodeIntIfPresent(forKey: .estimatedMinutes)
        difficulty = try container.decodeTrimmedStringIfPresent(forKey: .difficulty)
        difficultyScore = try container.decodeIntIfPresent(forKey: .difficultyScore)
        tags = try container.decodeStringArrayIfPresent(forKey: .tags)
        priority = try container.decodeTrimmedStringIfPresent(forKey: .priority)
        confidence = try container.decodeDoubleIfPresent(forKey: .confidence)
    }

    func todoPlan() -> TodoPlan {
        TodoPlan(
            title: title.nilIfEmpty,
            correctedText: correctedText.nilIfEmpty,
            summary: summary.nilIfEmpty,
            plannedSteps: TodoPriority.normalizeTags(steps),
            dueDate: dueDate.nilIfEmpty,
            estimatedMinutes: estimatedMinutes,
            difficulty: difficulty.nilIfEmpty,
            difficultyScore: TodoPriority.clampDifficultyScore(difficultyScore),
            tags: TodoPriority.normalizeTags(tags),
            priority: TodoPriority.normalize(priority),
            confidence: TodoPriority.clampConfidence(confidence)
        )
    }
}

/// Parses raw model message content into the app's cleaned planning model.
///
/// `LLMTaskPlanner` owns transport and logging; this parser owns model-output
/// tolerance, including fenced JSON and loose number formats returned by
/// OpenAI-compatible services. Keeping it internal gives tests a stable logic
/// boundary without exposing request internals.
enum LLMTaskPlanParser {
    static func parsePlan(from content: String) throws -> TodoPlan {
        let payload = try JSONDecoder().decode(
            LLMTaskPlanPayload.self,
            from: Data(extractJSONObject(from: content).utf8)
        )
        return payload.todoPlan()
    }

    /// Some models wrap JSON in Markdown code fences; use the outermost object.
    private static func extractJSONObject(from content: String) -> String {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"),
              start <= end else {
            return content
        }

        return String(content[start...end])
    }
}

/// 统一负责“新建任务规划”和“已有任务重新规划”的大模型入口。
///
/// 该层只做三件事：构造请求、调用 Chat Completions（聊天补全）接口、把模型 JSON
/// 解析成 `TodoPlan`。它不会写 `config.json`，也不会直接操作 Markdown、SQLite 或 UI。
struct LLMTaskPlanner {
    var config: LLMConfig

    func planNewTask(_ draft: TodoDraft) async throws -> TodoDraft {
        llmPlannerLogger.info("Planning new todo with LLM. source=\(draft.sourceApplication, privacy: .public)")
        let plan = try await requestPlan(for: draft, mode: .newTask)
        llmPlannerLogger.info("LLM planning succeeded for new todo.")
        return plan.applying(to: draft)
    }

    func replan(record: TodoRecord) async throws -> TodoDraft {
        llmPlannerLogger.info("Replanning todo with LLM. file=\(record.fileURL.lastPathComponent, privacy: .public)")
        let draft = record.makeDraftForPlanning()
        let plan = try await requestPlan(for: draft, mode: .replan(record: record))
        llmPlannerLogger.info("LLM replanning succeeded. file=\(record.fileURL.lastPathComponent, privacy: .public)")
        return plan.applying(to: draft)
    }

    private func requestPlan(for draft: TodoDraft, mode: PlanningMode) async throws -> TodoPlan {
        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !apiKey.isEmpty else {
            throw LLMTaskPlannerError.missingAPIKey
        }
        guard !model.isEmpty else {
            throw LLMTaskPlannerError.missingModel
        }

        var request = URLRequest(url: LLMEndpointResolver.chatCompletionsURL(from: config.baseURL))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(makeRequestBody(for: draft, mode: mode, model: model))

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                throw LLMTaskPlannerError.badStatus(httpResponse.statusCode, Self.safeBodyPreview(from: data))
            }

            let apiResponse = try JSONDecoder().decode(LLMTaskPlanningResponse.self, from: data)
            guard let content = apiResponse.choices.first?.message.content else {
                throw LLMTaskPlannerError.emptyResponse
            }

            return try LLMTaskPlanParser.parsePlan(from: content)
        } catch let error as LLMTaskPlannerError {
            llmPlannerLogger.error("LLM planning failed: \(error.localizedDescription, privacy: .public)")
            throw error
        } catch {
            llmPlannerLogger.error("LLM planning failed with transport or parse error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func makeRequestBody(for draft: TodoDraft, mode: PlanningMode, model: String) -> LLMTaskPlanningRequest {
        LLMTaskPlanningRequest(
            model: model,
            messages: [
                .init(role: "system", content: augmentedSystemPrompt),
                .init(role: "user", content: userPrompt(for: draft, mode: mode))
            ],
            temperature: 0.2,
            response_format: .init(type: "json_object")
        )
    }

    private var augmentedSystemPrompt: String {
        """
        \(config.systemPrompt)

        固定 JSON 输出契约（必须遵守）：
        - 只输出一个 JSON object（JSON 对象），不要输出 Markdown（标记文本）或解释。
        - 所有字段都必须出现，字段名必须使用 snake_case（下划线命名）。
        - title: 简短、适合作为待办列表展示的中文标题。
        - corrected_text: 修正 OCR 断行、明显错字和 UI 噪声后的文本。
        - summary: 一句话说明任务背景、交付物和目标；学校任务要尽量点出课程或任务类型，但不要编造。
        - steps: 3 到 6 个可执行步骤的字符串数组。学校任务必须覆盖确认要求、准备材料、完成主体工作、检查质量/格式、提交或同步结果等完成标准。
        - due_date: 能明确推断时输出 ISO8601 时间字符串；不能明确推断时输出空字符串。
        - estimated_minutes: 预计完成分钟数，整数；信息不足时给保守估计。
        - difficulty: easy、medium、hard 三选一。
        - difficulty_score: 1 到 10 的整数，1 最简单，10 最难。
        - tags: 1 到 6 个短标签字符串数组；学校场景优先包含“学校”、课程名、任务类型或来源平台，例如 ["学校", "论文"]。
        - priority: 只能是 low、medium、high、urgent 四个英文值之一。
        - confidence: 0 到 1 的数字，表示你对规划准确性的置信度。
        - 不要编造课程名、老师、联系人、金额、日期、提交平台、承诺或背景；没有依据时降低 confidence，并在 steps 中加入确认关键信息的步骤。
        """
    }

    private func userPrompt(for draft: TodoDraft, mode: PlanningMode) -> String {
        var blocks: [String] = [
            mode.description,
            "来源应用：\(draft.sourceApplication)",
            "创建时间：\(Self.isoString(draft.createdAt))",
            "当前标题：\(draft.title)",
            "时间线索：\(draft.dueHint ?? "未识别")"
        ]

        if let summary = draft.summary, !summary.isEmpty {
            blocks.append("当前摘要：\(summary)")
        }
        if !draft.plannedSteps.isEmpty {
            blocks.append("当前步骤：\n\(draft.plannedSteps.map { "- \($0)" }.joined(separator: "\n"))")
        }
        if let correctedText = draft.correctedText, !correctedText.isEmpty {
            blocks.append("当前修正文案：\n\(correctedText)")
        }

        blocks.append("OCR 原文：\n\(draft.originalText)")
        return blocks.joined(separator: "\n\n")
    }

    private static func safeBodyPreview(from data: Data) -> String {
        let body = String(data: data, encoding: .utf8) ?? ""
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "响应体为空。"
        }

        return String(trimmed.prefix(500))
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private enum PlanningMode {
    case newTask
    case replan(record: TodoRecord)

    var description: String {
        switch self {
        case .newTask:
            return "任务模式：新建任务规划。请根据 OCR 原文自动生成可保存的待办。"
        case .replan(let record):
            return """
            任务模式：已有待办重新规划。请覆盖当前标题、摘要、步骤、耗时、难度、标签、优先级和置信度，但保留原始 OCR 事实边界。
            当前状态：\(record.status)
            已有标签：\(record.tags.joined(separator: ", "))
            已有优先级：\(record.priority ?? "未评估")
            """
        }
    }
}

enum LLMTaskPlannerError: LocalizedError {
    case missingAPIKey
    case missingModel
    case badStatus(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "缺少 API Key（接口密钥）。"
        case .missingModel:
            return "缺少 Model（模型名称）。"
        case .badStatus(let code, let body):
            return "大模型规划失败，HTTP 状态码: \(code)。\(body)"
        case .emptyResponse:
            return "大模型没有返回可解析的任务规划 JSON。"
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeTrimmedStringIfPresent(forKey key: Key) throws -> String? {
        guard let value = try? decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func decodeStringArrayIfPresent(forKey key: Key) throws -> [String] {
        if let values = try? decodeIfPresent([String].self, forKey: key) {
            return values
        }

        guard let value = try? decodeIfPresent(String.self, forKey: key) else {
            return []
        }

        return value
            .components(separatedBy: CharacterSet(charactersIn: ",，、\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-•"))) }
            .filter { !$0.isEmpty }
    }

    func decodeIntIfPresent(forKey key: Key) throws -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(value.rounded())
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let exactValue = Int(trimmed) {
                return exactValue
            }
            return trimmed.firstDecimalNumber.map { Int($0.rounded()) }
        }
        return nil
    }

    func decodeDoubleIfPresent(forKey key: Key) throws -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let trimmed = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "%", with: "")
                .replacingOccurrences(of: "％", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isPercent = value.contains("%") || value.contains("％")
            guard let number = Double(trimmed) ?? trimmed.firstDecimalNumber else {
                return nil
            }
            return isPercent ? number / 100 : number
        }
        return nil
    }
}

private extension String {
    /// Extracts the first signed decimal number from loose model text such as
    /// "约 45 分钟" while avoiding ad hoc parsing at individual decode sites.
    var firstDecimalNumber: Double? {
        guard let range = range(of: #"[-+]?\d+(\.\d+)?"#, options: .regularExpression) else {
            return nil
        }
        return Double(self[range])
    }
}

private extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
