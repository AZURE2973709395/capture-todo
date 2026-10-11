import Foundation
import ScreenTodoCaptureCore

enum TodoMarkdownExporter {
    /// 把结构化草稿导出为可读 Markdown。
    ///
    /// Markdown 仍是用户可直接打开、迁移和备份的主文件；SQLite 只负责索引和加速读取。
    /// 这里集中维护导出格式，避免 UI 或存储层继续手工拼接 Markdown。
    static func markdown(
        draft: TodoDraft,
        status: String = "待处理",
        completedAt: String? = nil,
        histories: [TodoPlanHistory] = []
    ) -> String {
        var lines: [String] = [
            "# \(draft.title)",
            "",
            "- 状态: \(status)",
            "- 来源应用: \(draft.sourceApplication)",
            "- 创建时间: \(isoString(draft.createdAt))"
        ]

        if let completedAt, !completedAt.isEmpty {
            lines.append("- 完成时间: \(completedAt)")
        }
        if let dueHint = draft.dueHint, !dueHint.isEmpty {
            lines.append("- 时间线索: \(dueHint)")
        }
        if let dueDate = draft.dueDate, !dueDate.isEmpty {
            lines.append("- 截止时间: \(dueDate)")
        }
        if let estimatedMinutes = draft.estimatedMinutes {
            lines.append("- 预计耗时: \(estimatedMinutes) 分钟")
        }
        if let difficulty = draft.difficulty, !difficulty.isEmpty {
            lines.append("- 难度: \(difficulty)")
        }
        if let difficultyScore = draft.difficultyScore {
            lines.append("- 难度分: \(difficultyScore)")
        }
        let tags = TodoPriority.normalizeTags(draft.tags)
        if !tags.isEmpty {
            lines.append("- 标签: \(tags.joined(separator: ", "))")
        }
        if let priority = TodoPriority.normalize(draft.priority) {
            lines.append("- 优先级: \(priority)")
        }
        if let confidence = TodoPriority.clampConfidence(draft.confidence) {
            lines.append("- 置信度: \(String(format: "%.2f", confidence))")
        }
        if let screenshotRelativePath = draft.screenshotRelativePath, !screenshotRelativePath.isEmpty {
            lines.append("- 截图证据: \(screenshotRelativePath)")
        }
        if let reminderIdentifier = draft.reminderIdentifier, !reminderIdentifier.isEmpty {
            lines.append("- reminderIdentifier: \(reminderIdentifier)")
        }
        if let reminderSyncedAt = draft.reminderSyncedAt, !reminderSyncedAt.isEmpty {
            lines.append("- reminderSyncedAt: \(reminderSyncedAt)")
        }
        if let reminderSyncStatus = draft.reminderSyncStatus, !reminderSyncStatus.isEmpty {
            lines.append("- reminderSyncStatus: \(reminderSyncStatus)")
        }

        if let summary = draft.summary, !summary.isEmpty {
            lines.append(contentsOf: ["", "## 任务摘要", "", summary])
        }

        if !draft.plannedSteps.isEmpty {
            lines.append(contentsOf: ["", "## 执行计划", ""])
            lines.append(contentsOf: draft.plannedSteps.map { "- \($0)" })
        }

        if let correctedText = draft.correctedText, !correctedText.isEmpty {
            lines.append(contentsOf: ["", "## 大模型修正文本", "", "```text", correctedText, "```"])
        }

        lines.append(contentsOf: ["", "## 原始识别文本", "", "```text", draft.originalText, "```"])

        if !histories.isEmpty {
            lines.append(contentsOf: ["", "## 规划历史"])
            for history in histories {
                lines.append(contentsOf: [
                    "",
                    "### \(isoString(history.capturedAt))",
                    "- 标题: \(history.title)"
                ])
                if let summary = history.summary, !summary.isEmpty {
                    lines.append("- 摘要: \(summary)")
                }
                if let estimatedMinutes = history.estimatedMinutes, !estimatedMinutes.isEmpty {
                    lines.append("- 预计耗时: \(estimatedMinutes)")
                }
                if let difficulty = history.difficulty, !difficulty.isEmpty {
                    lines.append("- 难度: \(difficulty)")
                }
                if let difficultyScore = history.difficultyScore {
                    lines.append("- 难度分: \(difficultyScore)")
                }
                let historyTags = TodoPriority.normalizeTags(history.tags)
                if !historyTags.isEmpty {
                    lines.append("- 标签: \(historyTags.joined(separator: ", "))")
                }
                if let priority = TodoPriority.normalize(history.priority) {
                    lines.append("- 优先级: \(priority)")
                }
                if let confidence = TodoPriority.clampConfidence(history.confidence) {
                    lines.append("- 置信度: \(String(format: "%.2f", confidence))")
                }
                if !history.plannedSteps.isEmpty {
                    lines.append("- 步骤:")
                    lines.append(contentsOf: history.plannedSteps.map { "  - \($0)" })
                }
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
