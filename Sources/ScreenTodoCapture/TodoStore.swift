import AppKit
import Foundation
import OSLog
import ScreenTodoCaptureCore

private let todoStoreLogger = Logger(subsystem: "ScreenTodoCapture", category: "TodoStore")

/// 保存后的本地资源位置。
struct StoredTodo {
    var todoURL: URL
    var screenshotURL: URL?
}

/// 本地文件存储层。
///
/// 待办用 Markdown（文本待办文件）保存，截图用 PNG 保存。
/// 目录放在 Application Support（应用支持目录）下，符合 macOS 应用数据习惯。
struct TodoStore {
    private let fileManager = FileManager.default
    private let rootDirectoryOverride: URL?

    init(rootDirectoryOverride: URL? = nil) {
        self.rootDirectoryOverride = rootDirectoryOverride
    }

    /// 应用私有数据根目录。
    var rootDirectory: URL {
        if let rootDirectoryOverride {
            return rootDirectoryOverride
        }

        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ScreenTodoCapture", isDirectory: true)
    }

    var todosDirectory: URL {
        rootDirectory.appendingPathComponent("Todos", isDirectory: true)
    }

    var capturesDirectory: URL {
        rootDirectory.appendingPathComponent("Captures", isDirectory: true)
    }

    var archiveDirectory: URL {
        rootDirectory.appendingPathComponent("Archive", isDirectory: true)
    }

    /// 保存待办草稿和可选截图，并把截图相对路径写回 Markdown。
    func save(draft: TodoDraft, image: NSImage?) throws -> StoredTodo {
        try ensureDirectories()

        let identifier = uniqueIdentifier(startingWith: Self.fileIdentifier(from: draft.createdAt))
        var screenshotURL: URL?
        var draft = draft

        if let image {
            let filename = "\(identifier).png"
            let url = capturesDirectory.appendingPathComponent(filename)
            try image.pngData().write(to: url, options: .atomic)
            screenshotURL = url
            draft.screenshotRelativePath = "Captures/\(filename)"
        }

        let todoURL = todosDirectory.appendingPathComponent("\(identifier).md")
        try TodoMarkdownExporter.markdown(draft: draft).write(to: todoURL, atomically: true, encoding: .utf8)
        todoStoreLogger.info("Saved todo markdown. file=\(todoURL.lastPathComponent, privacy: .public)")
        try syncSQLiteIndex()

        return StoredTodo(todoURL: todoURL, screenshotURL: screenshotURL)
    }

    /// 确保待办和截图目录存在。菜单打开目录前也会调用它。
    func ensureDirectories() throws {
        try fileManager.createDirectory(at: todosDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: capturesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
    }

    func update(record: TodoRecord) throws {
        try record.content.write(to: record.fileURL, atomically: true, encoding: .utf8)
        todoStoreLogger.info("Updated todo markdown. file=\(record.fileURL.lastPathComponent, privacy: .public)")
        try syncSQLiteIndex()
    }

    func loadRecord(fileURL: URL) throws -> TodoRecord? {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        return TodoMarkdownParser.parse(fileURL: fileURL, content: content, store: self)
    }

    /// 写回 Apple Reminders 单向同步结果。
    ///
    /// 同步是外部系统副作用，不能影响本地待办保存；因此这里只更新同步元数据，不改动
    /// 标题、状态、规划等业务字段，并在写回后重建 SQLite 索引。
    func updateReminderMetadata(fileURL: URL, metadata: ReminderSyncMetadata) throws {
        var content = try String(contentsOf: fileURL, encoding: .utf8)
        content = TodoMarkdownEditor.setMetadata("reminderIdentifier", value: metadata.identifier, in: content)
        content = TodoMarkdownEditor.setMetadata("reminderSyncedAt", value: metadata.syncedAt.map(Self.isoString), in: content)
        content = TodoMarkdownEditor.setMetadata("reminderSyncStatus", value: metadata.status.rawValue, in: content)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        todoStoreLogger.info("Updated reminder sync metadata. file=\(fileURL.lastPathComponent, privacy: .public)")
        try syncSQLiteIndex()
    }

    /// 用新的 LLM 规划覆盖当前规划字段，并把旧规划追加到 Markdown 历史区。
    ///
    /// 输入 `record` 是旧版本，`draft` 是 `LLMTaskPlanner` 生成的新版本。存储层负责
    /// 保留状态、完成时间、截图路径和历史版本，并同步 SQLite 索引。
    func replacePlan(record: TodoRecord, with draft: TodoDraft) throws {
        var draft = draft
        draft.screenshotRelativePath = record.screenshotRelativePath

        let completedAt = record.completedAt.map(Self.isoString) ?? record.completedAtText
        let histories = record.planHistories + [TodoPlanHistory(record: record)]
        let markdown = TodoMarkdownExporter.markdown(
            draft: draft,
            status: record.status,
            completedAt: completedAt,
            histories: histories
        )

        try markdown.write(to: record.fileURL, atomically: true, encoding: .utf8)
        todoStoreLogger.info("Replaced todo plan and appended history. file=\(record.fileURL.lastPathComponent, privacy: .public)")
        try syncSQLiteIndex()
    }

    func delete(record: TodoRecord) throws {
        if let screenshotURL = record.screenshotURL,
           fileManager.fileExists(atPath: screenshotURL.path) {
            try fileManager.removeItem(at: screenshotURL)
        }

        if fileManager.fileExists(atPath: record.fileURL.path) {
            try fileManager.removeItem(at: record.fileURL)
        }
        todoStoreLogger.info("Deleted todo and linked screenshot when present. file=\(record.fileURL.lastPathComponent, privacy: .public)")
        try syncSQLiteIndex()
    }

    func archive(record: TodoRecord) throws {
        try ensureDirectories()

        let destination = archiveDirectory.appendingPathComponent(record.fileURL.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        try fileManager.moveItem(at: record.fileURL, to: destination)
        todoStoreLogger.info("Archived todo. file=\(record.fileURL.lastPathComponent, privacy: .public)")
        try syncSQLiteIndex()
    }

    func archiveCompletedOlderThan(days: Int) throws {
        let records = try TodoRecordLoader(store: self).load()
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()

        for record in records {
            guard record.status == "已完成",
                  let completedAt = record.completedAt,
                  completedAt < cutoff else {
                continue
            }

            try archive(record: record)
        }
    }

    /// Markdown 是 source of truth（事实来源），SQLite 是读取索引。
    /// 每次文件级变更后重建索引，保证删除、归档、编辑和重规划后的两份存储一致。
    private func syncSQLiteIndex() throws {
        try TodoSQLiteStore(store: self).rebuildIndexFromMarkdown()
    }

    /// 用创建时间生成稳定文件名，便于按时间排序。
    ///
    /// 保存流程可能在同一秒内连续触发多次，例如用户快速框选多个作业通知。
    /// 这里保留时间前缀用于排序，同时由 `uniqueIdentifier` 负责追加序号避免覆盖。
    private static func fileIdentifier(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }

    /// 生成不会覆盖现有 Markdown 或截图证据的文件标识。
    ///
    /// Markdown 是事实来源，截图是证据附件；二者共享同一个标识可以让人工排查时更容易
    /// 对齐文件。只要任一侧已经存在，就追加递增后缀生成一组新的路径。
    private func uniqueIdentifier(startingWith baseIdentifier: String) -> String {
        var candidate = baseIdentifier
        var suffix = 2

        while fileManager.fileExists(atPath: todosDirectory.appendingPathComponent("\(candidate).md").path)
            || fileManager.fileExists(atPath: capturesDirectory.appendingPathComponent("\(candidate).png").path) {
            candidate = "\(baseIdentifier)-\(suffix)"
            suffix += 1
        }

        return candidate
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private extension NSImage {
    /// 将截图统一保存为 PNG，避免 TIFF 等剪贴板内部格式不方便预览和迁移。
    func pngData() throws -> Data {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            throw OCRCaptureError.cannotCreateCGImage
        }

        return data
    }
}
