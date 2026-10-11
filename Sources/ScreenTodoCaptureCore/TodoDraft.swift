import Foundation

/// 待办草稿的数据模型。
///
/// 当前 MVP（最小可用版本）先保存为 Markdown（文本待办文件）。
/// 后续接 Apple Reminders（苹果提醒事项）或 Notion（第三方知识库）时，
/// 可以继续复用这个结构作为中间层。
public struct TodoDraft: Equatable, Sendable {
    /// 用户最终看到和确认的待办标题。
    public var title: String

    /// OCR（光学字符识别）得到的原始文本，保留它便于回溯和人工修正。
    public var originalText: String

    /// 大模型修正后的文本。它用于提升可读性，但不会覆盖原始 OCR 文本。
    public var correctedText: String?

    /// 创建待办时的前台应用名称，例如微信、QQ、Safari。
    public var sourceApplication: String

    /// 从原文里粗略提取的时间线索，例如“明天”“下周一”“15:30”。
    public var dueHint: String?

    /// 可排序的截止时间，ISO8601 格式字符串。没有明确日期时为空。
    public var dueDate: String?

    /// 大模型或本地规则生成的任务摘要。
    public var summary: String?

    /// 大模型规划出的执行步骤。没有接入大模型时可以为空。
    public var plannedSteps: [String]

    /// 预计完成时间，单位为分钟。
    public var estimatedMinutes: Int?

    /// 难度评估，例如 easy（简单）、medium（中等）、hard（困难）。
    public var difficulty: String?

    /// 难度分数，1 到 10。用于排序和工作量判断。
    public var difficultyScore: Int?

    /// 大模型生成的任务标签，例如工作、学校、论文。
    public var tags: [String]

    /// 大模型生成的优先级，取值 low、medium、high、urgent。
    public var priority: String?

    /// 大模型对本次规划的置信度，0 到 1。
    public var confidence: Double?

    /// 草稿创建时间，用于排序和生成文件名。
    public var createdAt: Date

    /// 截图相对路径。保存 Markdown 时使用相对路径，方便整体迁移目录。
    public var screenshotRelativePath: String?

    /// Apple Reminders（苹果提醒事项）里的系统标识。为空表示尚未成功创建提醒事项。
    public var reminderIdentifier: String?

    /// 最近一次成功同步到 Reminders 的时间，ISO8601 字符串。
    public var reminderSyncedAt: String?

    /// 最近一次 Reminders 同步状态，例如 synced 或 failed。
    public var reminderSyncStatus: String?

    public init(
        title: String,
        originalText: String,
        correctedText: String? = nil,
        sourceApplication: String,
        dueHint: String? = nil,
        dueDate: String? = nil,
        summary: String? = nil,
        plannedSteps: [String] = [],
        estimatedMinutes: Int? = nil,
        difficulty: String? = nil,
        difficultyScore: Int? = nil,
        tags: [String] = [],
        priority: String? = nil,
        confidence: Double? = nil,
        createdAt: Date = Date(),
        screenshotRelativePath: String? = nil,
        reminderIdentifier: String? = nil,
        reminderSyncedAt: String? = nil,
        reminderSyncStatus: String? = nil
    ) {
        self.title = title
        self.originalText = originalText
        self.correctedText = correctedText
        self.sourceApplication = sourceApplication
        self.dueHint = dueHint
        self.dueDate = dueDate
        self.summary = summary
        self.plannedSteps = plannedSteps
        self.estimatedMinutes = estimatedMinutes
        self.difficulty = difficulty
        self.difficultyScore = difficultyScore
        self.tags = tags
        self.priority = priority
        self.confidence = confidence
        self.createdAt = createdAt
        self.screenshotRelativePath = screenshotRelativePath
        self.reminderIdentifier = reminderIdentifier
        self.reminderSyncedAt = reminderSyncedAt
        self.reminderSyncStatus = reminderSyncStatus
    }

    /// 生成本地待办文件内容。
    ///
    /// 这里不直接写 Apple Reminders（苹果提醒事项），是为了让第一版有可检查、
    /// 可迁移、可版本化的本地结果。
    public func markdown() -> String {
        var lines: [String] = [
            "# \(title)",
            "",
            "- 状态: 待处理",
            "- 来源应用: \(sourceApplication)",
            "- 创建时间: \(Self.formattedDate(createdAt))"
        ]

        if let dueHint, !dueHint.isEmpty {
            lines.append("- 时间线索: \(dueHint)")
        }

        if let dueDate, !dueDate.isEmpty {
            lines.append("- 截止时间: \(dueDate)")
        }

        if let estimatedMinutes {
            lines.append("- 预计耗时: \(estimatedMinutes) 分钟")
        }

        if let difficulty, !difficulty.isEmpty {
            lines.append("- 难度: \(difficulty)")
        }

        if let difficultyScore {
            lines.append("- 难度分: \(difficultyScore)")
        }

        if !tags.isEmpty {
            lines.append("- 标签: \(tags.joined(separator: ", "))")
        }

        if let priority, !priority.isEmpty {
            lines.append("- 优先级: \(priority)")
        }

        if let confidence {
            lines.append("- 置信度: \(String(format: "%.2f", confidence))")
        }

        if let screenshotRelativePath, !screenshotRelativePath.isEmpty {
            lines.append("- 截图证据: \(screenshotRelativePath)")
        }

        if let reminderIdentifier, !reminderIdentifier.isEmpty {
            lines.append("- reminderIdentifier: \(reminderIdentifier)")
        }
        if let reminderSyncedAt, !reminderSyncedAt.isEmpty {
            lines.append("- reminderSyncedAt: \(reminderSyncedAt)")
        }
        if let reminderSyncStatus, !reminderSyncStatus.isEmpty {
            lines.append("- reminderSyncStatus: \(reminderSyncStatus)")
        }

        if let summary, !summary.isEmpty {
            lines.append(contentsOf: [
                "",
                "## 任务摘要",
                "",
                summary
            ])
        }

        if !plannedSteps.isEmpty {
            lines.append(contentsOf: [
                "",
                "## 执行计划",
                ""
            ])
            lines.append(contentsOf: plannedSteps.map { "- \($0)" })
        }

        if let correctedText, !correctedText.isEmpty {
            lines.append(contentsOf: [
                "",
                "## 大模型修正文本",
                "",
                "```text",
                correctedText,
                "```"
            ])
        }

        lines.append(contentsOf: [
            "",
            "## 原始识别文本",
            "",
            "```text",
            originalText,
            "```",
            ""
        ])

        return lines.joined(separator: "\n")
    }

    /// 每次调用都创建 formatter，避免 Swift 6 对共享可变 formatter 的并发安全报错。
    private static func formattedDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
