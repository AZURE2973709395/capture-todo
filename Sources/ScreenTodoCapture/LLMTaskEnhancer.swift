import Foundation
import ScreenTodoCaptureCore

/// 大模型增强结果。
///
/// 字段名用 snake_case（下划线命名），方便直接解析模型输出的 JSON。
private struct LLMTaskPlan: Decodable {
    var title: String?
    var corrected_text: String?
    var summary: String?
    var steps: [String]?
    var due_date: String?
    var estimated_minutes: Int?
    var difficulty: String?
    var difficulty_score: Int?
}

private struct ChatCompletionRequest: Encodable {
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

private struct ChatCompletionResponse: Decodable {
    var choices: [Choice]

    struct Choice: Decodable {
        var message: Message
    }

    struct Message: Decodable {
        var content: String
    }
}

/// 用 LLM（大语言模型）把 OCR 原文整理成更可靠的待办。
///
/// 该能力只有在配置了 API Key（接口密钥）且启用后才会运行。
struct LLMTaskEnhancer {
    var config: LLMConfig

    func enhance(_ draft: TodoDraft) async throws -> TodoDraft {
        var request = URLRequest(url: LLMEndpointResolver.chatCompletionsURL(from: config.baseURL))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(makeRequestBody(for: draft))

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMTaskEnhancerError.badStatus(httpResponse.statusCode, body)
        }

        let apiResponse = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = apiResponse.choices.first?.message.content,
              let jsonData = extractJSONObject(from: content).data(using: .utf8) else {
            throw LLMTaskEnhancerError.emptyResponse
        }

        let plan = try JSONDecoder().decode(LLMTaskPlan.self, from: jsonData)

        var enhanced = draft
        if let title = plan.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            enhanced.title = title
        }
        if let correctedText = plan.corrected_text?.trimmingCharacters(in: .whitespacesAndNewlines), !correctedText.isEmpty {
            enhanced.correctedText = correctedText
        }
        enhanced.summary = plan.summary
        enhanced.plannedSteps = plan.steps ?? []
        enhanced.dueDate = plan.due_date
        enhanced.estimatedMinutes = plan.estimated_minutes
        enhanced.difficulty = plan.difficulty
        enhanced.difficultyScore = plan.difficulty_score
        return enhanced
    }

    private func makeRequestBody(for draft: TodoDraft) -> ChatCompletionRequest {
        let userPrompt = """
        来源应用：\(draft.sourceApplication)
        时间线索：\(draft.dueHint ?? "未识别")

        OCR 原文：
        \(draft.originalText)
        """

        return ChatCompletionRequest(
            model: config.model,
            messages: [
                .init(role: "system", content: config.systemPrompt),
                .init(role: "user", content: userPrompt)
            ],
            temperature: 0.2,
            response_format: .init(type: "json_object")
        )
    }

    /// 有些模型会把 JSON 包在 ```json 代码块里，这里取出最外层对象。
    private func extractJSONObject(from content: String) -> String {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"),
              start <= end else {
            return content
        }

        return String(content[start...end])
    }
}

enum LLMTaskEnhancerError: LocalizedError {
    case badStatus(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .badStatus(let code, let body):
            return "大模型请求失败，HTTP 状态码: \(code)。\(body)"
        case .emptyResponse:
            return "大模型没有返回可解析的任务规划。"
        }
    }
}
