import Foundation
import ScreenTodoCaptureCore

enum TodoSortMode: String, CaseIterable {
    case smart = "智能排序"
    case createdDesc = "创建时间"
    case dueDateAsc = "截止时间"
    case difficultyDesc = "难度分"
}

/// 前端列表展示用的待办记录。
///
/// 它从 Markdown 文件解析而来，不要求和 TodoDraft 一一对应所有字段。
struct TodoRecord: Sendable {
    var title: String
    var status: String
    var sourceApplication: String
    var createdAtText: String
    var createdAt: Date?
    var completedAtText: String?
    var completedAt: Date?
    var dueHint: String?
    var dueDateText: String?
    var dueDate: Date?
    var estimatedMinutes: String?
    var difficulty: String?
    var difficultyScore: Int?
    var tags: [String]
    var priority: String?
    var confidence: Double?
    var summary: String?
    var plannedSteps: [String]
    var planHistories: [TodoPlanHistory]
    var correctedText: String?
    var originalText: String?
    var fileURL: URL
    var screenshotRelativePath: String?
    var screenshotURL: URL?
    var reminderIdentifier: String?
    var reminderSyncedAtText: String?
    var reminderSyncedAt: Date?
    var reminderSyncStatus: String?
    var content: String

    var displaySubtitle: String {
        var parts = [sourceApplication]
        if let dueDateText, !dueDateText.isEmpty {
            parts.append("截止: \(dueDateText)")
        } else if let dueHint, !dueHint.isEmpty {
            parts.append("时间: \(dueHint)")
        }
        if let difficultyScore {
            parts.append("难度: \(difficultyScore)")
        } else if let difficulty, !difficulty.isEmpty {
            parts.append("难度: \(difficulty)")
        }
        if let priority = TodoPriority.normalize(priority) {
            parts.append("优先级: \(TodoPriority.display(priority))")
        }
        if !tags.isEmpty {
            parts.append("标签: \(tags.prefix(2).joined(separator: ","))")
        }
        return parts.joined(separator: " · ")
    }

    /// 把已保存记录还原成可重新规划的草稿。
    ///
    /// 输入来自 Markdown 解析结果；输出只提供给 `LLMTaskPlanner` 和 `TodoStore`，
    /// 不在这里发请求或写文件，避免记录读取层耦合外部服务。
    func makeDraftForPlanning() -> TodoDraft {
        TodoDraft(
            title: title,
            originalText: originalText ?? correctedText ?? summary ?? content,
            correctedText: correctedText,
            sourceApplication: sourceApplication,
            dueHint: dueHint,
            dueDate: dueDateText,
            summary: summary,
            plannedSteps: plannedSteps,
            estimatedMinutes: estimatedMinutes.flatMap { Int($0.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) },
            difficulty: difficulty,
            difficultyScore: difficultyScore,
            tags: tags,
            priority: priority,
            confidence: confidence,
            createdAt: createdAt ?? Date(),
            screenshotRelativePath: screenshotRelativePath,
            reminderIdentifier: reminderIdentifier,
            reminderSyncedAt: reminderSyncedAtText,
            reminderSyncStatus: reminderSyncStatus
        )
    }
}

/// 从本地 Markdown 待办目录读取记录。
struct TodoRecordLoader {
    var store: TodoStore
    var sortMode: TodoSortMode = .smart
    var query: TodoQuery = TodoQuery()
    var referenceDate: Date = Date()

    func load() throws -> [TodoRecord] {
        try store.ensureDirectories()
        if let records = try? loadFromSQLite() {
            return records.sorted(by: sort)
        }

        return try loadFromMarkdown()
            .filter { query.matches($0, referenceDate: referenceDate) }
            .sorted(by: sort)
    }

    private func sort(_ lhs: TodoRecord, _ rhs: TodoRecord) -> Bool {
        let lhsDone = lhs.status == "已完成"
        let rhsDone = rhs.status == "已完成"
        if lhsDone != rhsDone {
            return !lhsDone
        }

        switch sortMode {
        case .smart:
            let leftDue = lhs.dueDate ?? .distantFuture
            let rightDue = rhs.dueDate ?? .distantFuture
            if leftDue != rightDue { return leftDue < rightDue }
            let leftDifficulty = lhs.difficultyScore ?? 0
            let rightDifficulty = rhs.difficultyScore ?? 0
            if leftDifficulty != rightDifficulty { return leftDifficulty > rightDifficulty }
            return (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
        case .createdDesc:
            return (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
        case .dueDateAsc:
            let left = lhs.dueDate ?? .distantFuture
            let right = rhs.dueDate ?? .distantFuture
            if left != right { return left < right }
            return (lhs.difficultyScore ?? 0) > (rhs.difficultyScore ?? 0)
        case .difficultyDesc:
            let left = lhs.difficultyScore ?? 0
            let right = rhs.difficultyScore ?? 0
            if left != right { return left > right }
            return (lhs.dueDate ?? .distantFuture) < (rhs.dueDate ?? .distantFuture)
        }
    }

    private func loadFromMarkdown() throws -> [TodoRecord] {
        let directories = [store.todosDirectory, store.archiveDirectory]
        let files = try directories.flatMap { directory in
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "md" }
        }

        return files.compactMap(loadRecord)
    }

    private func loadFromSQLite() throws -> [TodoRecord] {
        let index = try TodoSQLiteStore(store: store)
        // The loader treats SQLite as a cache over Markdown. It verifies the
        // Markdown source signature before querying so normal refreshes avoid
        // rewriting the index, while manual file edits still flow into search.
        try index.rebuildIndexFromMarkdownIfNeeded()
        return try index.loadRecords(matching: query, referenceDate: referenceDate)
    }

    private func loadRecord(from fileURL: URL) -> TodoRecord? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        return TodoMarkdownParser.parse(fileURL: fileURL, content: content, store: store)
    }

    static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let internetFormatter = ISO8601DateFormatter()
        internetFormatter.formatOptions = [.withInternetDateTime]
        if let date = internetFormatter.date(from: trimmed) {
            return date
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: trimmed) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
            "yyyy/MM/dd HH:mm",
            "yyyy/MM/dd"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        return nil
    }

    static func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

enum TodoMarkdownEditor {
    static func setTitle(_ title: String, in content: String) -> String {
        var lines = content.components(separatedBy: .newlines)
        if let index = lines.firstIndex(where: { $0.hasPrefix("# ") }) {
            lines[index] = "# \(title)"
        } else {
            lines.insert("# \(title)", at: 0)
        }
        return lines.joined(separator: "\n")
    }

    static func setMetadata(_ key: String, value: String?, in content: String) -> String {
        var lines = content.components(separatedBy: .newlines)
        let prefix = "- \(key): "
        let cleanValue = value?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let index = lines.firstIndex(where: { $0.hasPrefix(prefix) }) {
            if let cleanValue, !cleanValue.isEmpty {
                lines[index] = "\(prefix)\(cleanValue)"
            } else {
                lines.remove(at: index)
            }
        } else if let cleanValue, !cleanValue.isEmpty {
            let insertIndex = metadataInsertIndex(in: lines)
            lines.insert("\(prefix)\(cleanValue)", at: insertIndex)
        }

        return lines.joined(separator: "\n")
    }

    private static func metadataInsertIndex(in lines: [String]) -> Int {
        guard let titleIndex = lines.firstIndex(where: { $0.hasPrefix("# ") }) else {
            return 0
        }

        var index = titleIndex + 1
        if index < lines.count, lines[index].isEmpty {
            index += 1
        }
        while index < lines.count, lines[index].hasPrefix("- ") {
            index += 1
        }
        return index
    }
}
