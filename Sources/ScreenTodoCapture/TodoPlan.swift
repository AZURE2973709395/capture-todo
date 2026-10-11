import Foundation
import ScreenTodoCaptureCore

/// LLM（大语言模型）返回的结构化规划结果。
///
/// 这个模型是 LLM 请求层和本地存储/UI 之间的边界：请求层只负责把模型输出
/// 清洗成 `TodoPlan`，存储层再把它应用到 `TodoDraft` 并导出 Markdown/SQLite。
struct TodoPlan: Sendable {
    var title: String?
    var correctedText: String?
    var summary: String?
    var plannedSteps: [String]
    var dueDate: String?
    var estimatedMinutes: Int?
    var difficulty: String?
    var difficultyScore: Int?
    var tags: [String]
    var priority: String?
    var confidence: Double?

    func applying(to draft: TodoDraft) -> TodoDraft {
        var updated = draft

        if let title = title, !title.isEmpty {
            updated.title = title
        }
        if let correctedText = correctedText, !correctedText.isEmpty {
            updated.correctedText = correctedText
        }

        updated.summary = summary
        updated.plannedSteps = plannedSteps
        updated.dueDate = dueDate
        updated.estimatedMinutes = estimatedMinutes
        updated.difficulty = difficulty
        updated.difficultyScore = difficultyScore
        updated.tags = tags
        updated.priority = priority
        updated.confidence = confidence
        return updated
    }
}

/// 一次旧规划快照，用于“重新规划”前保留历史版本。
///
/// 历史只保存规划相关字段，不保存 API Key、请求体或完整配置，避免把敏感信息
/// 混进 Markdown 导出和 SQLite 索引。
struct TodoPlanHistory: Sendable {
    var capturedAt: Date
    var title: String
    var summary: String?
    var plannedSteps: [String]
    var estimatedMinutes: String?
    var difficulty: String?
    var difficultyScore: Int?
    var tags: [String]
    var priority: String?
    var confidence: Double?

    init(
        capturedAt: Date = Date(),
        title: String,
        summary: String?,
        plannedSteps: [String],
        estimatedMinutes: String?,
        difficulty: String?,
        difficultyScore: Int?,
        tags: [String],
        priority: String?,
        confidence: Double?
    ) {
        self.capturedAt = capturedAt
        self.title = title
        self.summary = summary
        self.plannedSteps = plannedSteps
        self.estimatedMinutes = estimatedMinutes
        self.difficulty = difficulty
        self.difficultyScore = difficultyScore
        self.tags = tags
        self.priority = TodoPriority.normalize(priority)
        self.confidence = confidence
    }

    init(record: TodoRecord) {
        self.init(
            title: record.title,
            summary: record.summary,
            plannedSteps: record.plannedSteps,
            estimatedMinutes: record.estimatedMinutes,
            difficulty: record.difficulty,
            difficultyScore: record.difficultyScore,
            tags: record.tags,
            priority: record.priority,
            confidence: record.confidence
        )
    }
}

enum TodoPriority {
    static let allowedValues = ["low", "medium", "high", "urgent"]

    static func normalize(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return nil
        }

        switch value {
        case "low", "低", "低优先级":
            return "low"
        case "medium", "normal", "中", "普通", "中优先级":
            return "medium"
        case "high", "高", "高优先级":
            return "high"
        case "urgent", "紧急", "立即", "最高", "最高优先级":
            return "urgent"
        default:
            guard allowedValues.contains(value) else {
                return nil
            }
            return value
        }
    }

    static func normalizeTags(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for value in values {
            let tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else {
                continue
            }
            let key = tag.lowercased()
            guard !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            result.append(tag)
            if result.count >= 8 {
                break
            }
        }

        return result
    }

    static func clampDifficultyScore(_ value: Int?) -> Int? {
        guard let value else {
            return nil
        }
        return min(max(value, 1), 10)
    }

    static func clampConfidence(_ value: Double?) -> Double? {
        guard let value else {
            return nil
        }
        return min(max(value, 0), 1)
    }

    static func display(_ value: String?) -> String {
        switch normalize(value) {
        case "low":
            return "低"
        case "medium":
            return "中"
        case "high":
            return "高"
        case "urgent":
            return "紧急"
        default:
            return "未评估"
        }
    }
}
