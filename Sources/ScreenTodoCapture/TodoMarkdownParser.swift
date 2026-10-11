import Foundation

enum TodoMarkdownParser {
    static func parse(fileURL: URL, content: String, store: TodoStore) -> TodoRecord? {
        let lines = content.components(separatedBy: .newlines)
        let title = lines.first { $0.hasPrefix("# ") }?.dropFirst(2).description ?? fileURL.deletingPathExtension().lastPathComponent
        let source = metadataValue("来源应用", in: lines) ?? "未知应用"
        let createdAtText = metadataValue("创建时间", in: lines) ?? fileURL.deletingPathExtension().lastPathComponent
        let createdAt = TodoRecordLoader.parseDate(createdAtText)
        let dueDateText = metadataValue("截止时间", in: lines)
        let dueDate = dueDateText.flatMap(TodoRecordLoader.parseDate)
        let screenshotRelativePath = metadataValue("截图证据", in: lines)
        let screenshotURL = screenshotRelativePath.map { store.rootDirectory.appendingPathComponent($0) }
        let summary = section(named: "任务摘要", in: lines)
        let plannedSteps = bulletSection(named: "执行计划", in: lines)
        let completedAtText = metadataValue("完成时间", in: lines)
        let completedAt = completedAtText.flatMap(TodoRecordLoader.parseDate)
        let tags = parseTags(metadataValue("标签", in: lines))
        let priority = TodoPriority.normalize(metadataValue("优先级", in: lines))
        let confidence = parseConfidence(metadataValue("置信度", in: lines))
        let reminderSyncedAtText = metadataValue("reminderSyncedAt", in: lines)
            ?? metadataValue("Reminders 同步时间", in: lines)
        let reminderSyncedAt = reminderSyncedAtText.flatMap(TodoRecordLoader.parseDate)

        return TodoRecord(
            title: title,
            status: metadataValue("状态", in: lines) ?? "待处理",
            sourceApplication: source,
            createdAtText: createdAt.map(TodoRecordLoader.displayDate) ?? createdAtText,
            createdAt: createdAt,
            completedAtText: completedAt.map(TodoRecordLoader.displayDate) ?? completedAtText,
            completedAt: completedAt,
            dueHint: metadataValue("时间线索", in: lines),
            dueDateText: dueDate.map(TodoRecordLoader.displayDate) ?? dueDateText,
            dueDate: dueDate,
            estimatedMinutes: metadataValue("预计耗时", in: lines),
            difficulty: metadataValue("难度", in: lines),
            difficultyScore: metadataValue("难度分", in: lines).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) },
            tags: tags,
            priority: priority,
            confidence: confidence,
            summary: summary,
            plannedSteps: plannedSteps,
            planHistories: planHistories(in: lines),
            correctedText: codeBlockSection(named: "大模型修正文本", in: lines),
            originalText: codeBlockSection(named: "原始识别文本", in: lines),
            fileURL: fileURL,
            screenshotRelativePath: screenshotRelativePath,
            screenshotURL: screenshotURL,
            reminderIdentifier: metadataValue("reminderIdentifier", in: lines)
                ?? metadataValue("Reminders ID", in: lines),
            reminderSyncedAtText: reminderSyncedAt.map(TodoRecordLoader.displayDate) ?? reminderSyncedAtText,
            reminderSyncedAt: reminderSyncedAt,
            reminderSyncStatus: metadataValue("reminderSyncStatus", in: lines)
                ?? metadataValue("Reminders 同步状态", in: lines),
            content: content
        )
    }

    static func relativePath(for fileURL: URL, store: TodoStore) -> String {
        let base = store.rootDirectory.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(base) else {
            return fileURL.lastPathComponent
        }

        let startIndex = filePath.index(filePath.startIndex, offsetBy: base.count)
        let trimmed = filePath[startIndex...].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return String(trimmed)
    }

    private static func metadataValue(_ key: String, in lines: [String]) -> String? {
        let prefix = "- \(key): "
        return lines
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    private static func section(named name: String, in lines: [String]) -> String? {
        let sectionLines = rawSection(named: name, in: lines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !sectionLines.isEmpty else { return nil }
        return sectionLines.joined(separator: "\n")
    }

    private static func bulletSection(named name: String, in lines: [String]) -> [String] {
        rawSection(named: name, in: lines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)) }
    }

    private static func codeBlockSection(named name: String, in lines: [String]) -> String? {
        let sectionLines = rawSection(named: name, in: lines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !sectionLines.isEmpty else { return nil }
        return sectionLines.joined(separator: "\n")
    }

    private static func rawSection(named name: String, in lines: [String]) -> [String] {
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "## \(name)" }) else {
            return []
        }

        var result: [String] = []
        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("## ") {
                break
            }
            result.append(line)
            index += 1
        }
        return result
    }

    private static func planHistories(in lines: [String]) -> [TodoPlanHistory] {
        let historyLines = rawSection(named: "规划历史", in: lines)
        var histories: [TodoPlanHistory] = []
        var currentDateText: String?
        var currentLines: [String] = []

        func flushCurrent() {
            guard let currentDateText else {
                return
            }

            let capturedAt = TodoRecordLoader.parseDate(currentDateText) ?? Date()
            let title = metadataValue("标题", in: currentLines) ?? "旧规划"
            let steps = nestedBulletSection(named: "步骤", in: currentLines)
            histories.append(TodoPlanHistory(
                capturedAt: capturedAt,
                title: title,
                summary: metadataValue("摘要", in: currentLines),
                plannedSteps: steps,
                estimatedMinutes: metadataValue("预计耗时", in: currentLines),
                difficulty: metadataValue("难度", in: currentLines),
                difficultyScore: metadataValue("难度分", in: currentLines).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) },
                tags: parseTags(metadataValue("标签", in: currentLines)),
                priority: TodoPriority.normalize(metadataValue("优先级", in: currentLines)),
                confidence: parseConfidence(metadataValue("置信度", in: currentLines))
            ))
        }

        for line in historyLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("### ") {
                flushCurrent()
                currentDateText = String(trimmed.dropFirst(4))
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }

        flushCurrent()
        return histories
    }

    private static func nestedBulletSection(named name: String, in lines: [String]) -> [String] {
        let marker = "- \(name):"
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == marker }) else {
            return []
        }

        var steps: [String] = []
        var index = start + 1
        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.hasPrefix("  - ") || raw.hasPrefix("\t- ") {
                steps.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines))
            } else if trimmed.hasPrefix("- ") {
                break
            }
            index += 1
        }

        return steps
    }

    static func parseTags(_ value: String?) -> [String] {
        guard let value else {
            return []
        }

        let tags = value
            .components(separatedBy: CharacterSet(charactersIn: ",，、"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return TodoPriority.normalizeTags(tags)
    }

    static func parseConfidence(_ value: String?) -> Double? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("%") || trimmed.hasSuffix("％") {
            let numberText = String(trimmed.dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let number = Double(numberText) else {
                return nil
            }
            return TodoPriority.clampConfidence(number / 100)
        }

        return TodoPriority.clampConfidence(Double(trimmed))
    }
}
