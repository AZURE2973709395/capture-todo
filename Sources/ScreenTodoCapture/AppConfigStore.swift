import Foundation

/// 应用配置文件。
///
/// 目前主要配置 LLM（大语言模型）增强能力。配置文件放在 Application Support
/// 目录下，避免把 API Key（接口密钥）写进源码或 README。
struct AppConfiguration: Codable {
    var llm: LLMConfig?
}

/// OpenAI-compatible（兼容 OpenAI 格式）的 Chat Completions（聊天补全）配置。
///
/// 很多模型服务都支持类似 `/v1/chat/completions` 的请求格式，所以这里不把实现
/// 绑定死在某一家服务商上。
struct LLMConfig: Codable, Sendable {
    var enabled: Bool
    var baseURL: URL
    var apiKey: String
    var model: String
    var systemPrompt: String

    init(enabled: Bool, baseURL: URL, apiKey: String, model: String, systemPrompt: String) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.systemPrompt = systemPrompt
    }

    /// 兼容旧版 config.json。旧配置可能没有 systemPrompt 等字段，不能因此让设置页打不开。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        baseURL = try container.decodeIfPresent(URL.self, forKey: .baseURL)
            ?? URL(string: "https://api.openai.com/v1/chat/completions")!
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? "gpt-4o-mini"
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
    }
}

/// 读取和保存本地配置文件。
struct AppConfigStore {
    private let fileManager = FileManager.default
    private let store = TodoStore()

    var configURL: URL {
        store.rootDirectory.appendingPathComponent("config.json")
    }

    var defaultSystemPrompt: String {
        """
        你是一个中文任务管理助手。请把用户从聊天截图 OCR 得到的文本整理成一个可执行待办。
        用户主要用它处理学校任务，包括作业、论文、实验报告、阅读、课堂展示、考试复习和小组项目。
        只输出 JSON，不要输出 Markdown，不要解释。
        JSON 字段必须是：
        title: 简短明确的待办标题
        corrected_text: 修正 OCR 断行、明显错字和多余 UI 噪声后的聊天文本
        summary: 一句话说明课程/任务背景、交付物和目标；如果课程名未知，不要编造
        steps: 3 到 6 个可执行步骤；学校任务要包含确认要求、准备材料、完成正文/解题/复习、检查格式、提交/同步给组员等完成标准
        due_date: 如果能从原文推断明确截止时间，输出 ISO8601 字符串；不能则输出空字符串
        estimated_minutes: 预计完成分钟数，整数
        difficulty: easy、medium、hard 三选一
        difficulty_score: 1 到 10 的难度分，1 最简单，10 最难
        tags: 1 到 6 个短标签数组，优先包含学校、课程名、任务类型和来源平台，例如 ["学校", "论文"]
        priority: low、medium、high、urgent 四选一
        confidence: 0 到 1 的置信度数字
        如果 OCR 文本不完整，请保守推断，不要编造不存在的课程名、老师、联系人、金额、截止时间或提交平台；缺少关键信息时在 steps 中加入“确认要求”类步骤并降低 confidence。
        """
    }

    /// 首次启动时写入一个禁用状态的示例配置，用户可以之后在设置页面修改。
    func ensureSampleConfig() throws {
        try store.ensureDirectories()

        guard !fileManager.fileExists(atPath: configURL.path) else {
            return
        }

        let config = AppConfiguration(
            llm: LLMConfig(
                enabled: false,
                baseURL: URL(string: "https://api.openai.com/v1/chat/completions")!,
                apiKey: "",
                model: "gpt-4o-mini",
                systemPrompt: defaultSystemPrompt
            )
        )
        try saveConfiguration(config)
    }

    /// 返回可用的大模型配置；未开启或缺少密钥时返回 nil。
    func loadLLMConfig() -> LLMConfig? {
        if let envConfig = loadEnvironmentConfig() {
            return envConfig
        }

        guard let config = try? loadConfiguration(),
              let llm = config.llm,
              llm.enabled,
              !llm.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return llm
    }

    func loadConfiguration() throws -> AppConfiguration {
        try ensureSampleConfig()

        let data = try Data(contentsOf: configURL)
        var config = try JSONDecoder().decode(AppConfiguration.self, from: data)

        if config.llm == nil {
            config.llm = LLMConfig(
                enabled: false,
                baseURL: URL(string: "https://api.openai.com/v1/chat/completions")!,
                apiKey: "",
                model: "gpt-4o-mini",
                systemPrompt: defaultSystemPrompt
            )
        }

        if config.llm?.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            config.llm?.systemPrompt = defaultSystemPrompt
        }

        return config
    }

    func saveConfiguration(_ configuration: AppConfiguration) throws {
        try store.ensureDirectories()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(configuration)
        try data.write(to: configURL, options: .atomic)
    }

    /// 仍支持环境变量，方便临时调试；开机启动场景更推荐 config.json。
    private func loadEnvironmentConfig() -> LLMConfig? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SCREEN_TODO_LLM_ENABLED"] == "true",
              let apiKey = environment["SCREEN_TODO_LLM_API_KEY"],
              !apiKey.isEmpty,
              let model = environment["SCREEN_TODO_LLM_MODEL"],
              !model.isEmpty else {
            return nil
        }

        let baseURL = URL(
            string: environment["SCREEN_TODO_LLM_BASE_URL"] ?? "https://api.openai.com/v1/chat/completions"
        )!

        return LLMConfig(
            enabled: true,
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            systemPrompt: environment["SCREEN_TODO_LLM_SYSTEM_PROMPT"] ?? defaultSystemPrompt
        )
    }
}
