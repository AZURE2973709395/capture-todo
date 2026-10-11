import Foundation

private struct LLMConnectionTestRequest: Encodable {
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

private struct LLMConnectionTestResponse: Decodable {
    var choices: [Choice]

    struct Choice: Decodable {
        var message: Message
    }

    struct Message: Decodable {
        var content: String
    }
}

/// 用真实 Chat Completions（聊天补全）请求验证大模型连接。
struct LLMConnectionTester {
    var config: LLMConfig

    func test() async throws {
        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !apiKey.isEmpty else {
            throw LLMConnectionTestError.missingAPIKey
        }
        guard !model.isEmpty else {
            throw LLMConnectionTestError.missingModel
        }

        var request = URLRequest(url: LLMEndpointResolver.chatCompletionsURL(from: config.baseURL))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(makeRequestBody(model: model))

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw LLMConnectionTestError.badStatus(
                httpResponse.statusCode,
                Self.safeBodyPreview(from: data)
            )
        }

        let apiResponse = try JSONDecoder().decode(LLMConnectionTestResponse.self, from: data)
        guard let content = apiResponse.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              canParseJSONObject(from: content) else {
            throw LLMConnectionTestError.unparseableResponse
        }
    }

    private func makeRequestBody(model: String) -> LLMConnectionTestRequest {
        LLMConnectionTestRequest(
            model: model,
            messages: [
                .init(role: "system", content: "只输出 JSON，不要输出 Markdown。"),
                .init(role: "user", content: "请只返回 {\"ok\": true}，用于连接测试。")
            ],
            temperature: 0,
            response_format: .init(type: "json_object")
        )
    }

    private func canParseJSONObject(from content: String) -> Bool {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"),
              start <= end,
              let data = String(content[start...end]).data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            return false
        }

        return true
    }

    private static func safeBodyPreview(from data: Data) -> String {
        let body = String(data: data, encoding: .utf8) ?? ""
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "响应体为空。"
        }

        return String(trimmed.prefix(500))
    }
}

enum LLMConnectionTestError: LocalizedError {
    case invalidURL
    case missingAPIKey
    case missingModel
    case badStatus(Int, String)
    case unparseableResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Base URL（接口地址）不是有效的 HTTP URL。"
        case .missingAPIKey:
            return "缺少 API Key（接口密钥）。"
        case .missingModel:
            return "缺少 Model（模型名称）。"
        case .badStatus(let code, let body):
            return "连接失败，HTTP 状态码: \(code)。\(body)"
        case .unparseableResponse:
            return "连接成功但模型返回内容不可解析。请确认接口兼容 OpenAI Chat Completions。"
        }
    }
}
