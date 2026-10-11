import CryptoKit
import Foundation
import OSLog
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private let todoSQLiteLogger = Logger(subsystem: "ScreenTodoCapture", category: "TodoSQLiteStore")

final class TodoSQLiteStore {
    private static let indexVersion = "1"
    private static let indexVersionKey = "index_version"
    private static let sourceSignatureKey = "markdown_source_signature"

    private let store: TodoStore
    private var db: OpaquePointer?

    init(store: TodoStore) throws {
        self.store = store
        try store.ensureDirectories()
        try openDatabase()
        try migrate()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func rebuildIndexFromMarkdown() throws {
        let markdownFiles = try markdownFiles()
        let sourceSignature = markdownSourceSignature(for: markdownFiles)
        try rebuildIndexFromMarkdown(markdownFiles: markdownFiles, sourceSignature: sourceSignature)
    }

    /// Keeps SQLite as a cache over Markdown without rewriting it on every load.
    ///
    /// The signature covers each Markdown file's relative path and bytes. This
    /// makes ordinary reads cheap, while external edits, deletes, moves, or app
    /// index-version changes still force a full rebuild before querying.
    func rebuildIndexFromMarkdownIfNeeded() throws {
        let markdownFiles = try markdownFiles()
        let sourceSignature = markdownSourceSignature(for: markdownFiles)
        let storedVersion = try metadataValue(forKey: Self.indexVersionKey)
        let storedSignature = try metadataValue(forKey: Self.sourceSignatureKey)
        let indexedRowCount = try todoIndexRowCount()

        guard storedVersion == Self.indexVersion,
              storedSignature == sourceSignature,
              indexedRowCount == markdownFiles.count else {
            todoSQLiteLogger.info("Rebuilding SQLite index. markdownCount=\(markdownFiles.count, privacy: .public), indexedCount=\(indexedRowCount, privacy: .public)")
            try rebuildIndexFromMarkdown(markdownFiles: markdownFiles, sourceSignature: sourceSignature)
            return
        }

        todoSQLiteLogger.debug("Skipped SQLite index rebuild; Markdown signature is current.")
    }

    private func rebuildIndexFromMarkdown(markdownFiles: [URL], sourceSignature: String) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute("DELETE FROM todo_index;")
            try execute("DELETE FROM todo_plan_history;")

            for fileURL in markdownFiles {
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8),
                      let record = TodoMarkdownParser.parse(fileURL: fileURL, content: content, store: store) else {
                    continue
                }
                try insert(record: record, fileURL: fileURL)
                try insertPlanHistories(record.planHistories, fileURL: fileURL)
            }
            try setMetadataValue(Self.indexVersion, forKey: Self.indexVersionKey)
            try setMetadataValue(sourceSignature, forKey: Self.sourceSignatureKey)

            try execute("COMMIT;")
        } catch {
            _ = try? execute("ROLLBACK;")
            throw error
        }
    }

    func loadActiveRecords() throws -> [TodoRecord] {
        try loadRecords(matching: TodoQuery())
    }

    func loadRecords(matching query: TodoQuery, referenceDate: Date = Date()) throws -> [TodoRecord] {
        let whereClause = whereClause(for: query, referenceDate: referenceDate)
        let sql = """
        SELECT file_path, content
        FROM todo_index
        \(whereClause.sql)
        ORDER BY updated_at DESC;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindWhereValues(statement, values: whereClause.values)

        var records: [TodoRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let filePath = columnText(statement, index: 0),
                  let content = columnText(statement, index: 1) else {
                continue
            }

            let fileURL = store.rootDirectory.appendingPathComponent(filePath)
            if let record = TodoMarkdownParser.parse(fileURL: fileURL, content: content, store: store) {
                records.append(record)
            }
        }

        return records
    }

    private func insert(record: TodoRecord, fileURL: URL) throws {
        let statement = try prepare("""
        INSERT INTO todo_index (
            file_path, archived, title, status, source_application,
            created_at_text, due_date_text, difficulty_score,
            tags_text, priority, confidence, summary_text, original_text,
            corrected_text, reminder_identifier, reminder_synced_at,
            reminder_sync_status, content, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """)
        defer { sqlite3_finalize(statement) }

        let archived = TodoMarkdownParser.relativePath(for: fileURL, store: store).hasPrefix("Archive/") ? 1 : 0
        try bindText(statement, index: 1, value: TodoMarkdownParser.relativePath(for: fileURL, store: store))
        sqlite3_bind_int(statement, 2, Int32(archived))
        try bindText(statement, index: 3, value: record.title)
        try bindText(statement, index: 4, value: record.status)
        try bindText(statement, index: 5, value: record.sourceApplication)
        try bindText(statement, index: 6, value: record.createdAtText)
        try bindNullableText(statement, index: 7, value: record.dueDateText)
        if let difficultyScore = record.difficultyScore {
            sqlite3_bind_int(statement, 8, Int32(difficultyScore))
        } else {
            sqlite3_bind_null(statement, 8)
        }
        try bindNullableText(statement, index: 9, value: record.tags.isEmpty ? nil : record.tags.joined(separator: ", "))
        try bindNullableText(statement, index: 10, value: record.priority)
        bindNullableDouble(statement, index: 11, value: record.confidence)
        try bindNullableText(statement, index: 12, value: record.summary)
        try bindNullableText(statement, index: 13, value: record.originalText)
        try bindNullableText(statement, index: 14, value: record.correctedText)
        try bindNullableText(statement, index: 15, value: record.reminderIdentifier)
        try bindNullableText(statement, index: 16, value: record.reminderSyncedAtText)
        try bindNullableText(statement, index: 17, value: record.reminderSyncStatus)
        try bindText(statement, index: 18, value: record.content)
        try bindText(statement, index: 19, value: Self.isoString(Date()))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError()
        }
    }

    private func insertPlanHistories(_ histories: [TodoPlanHistory], fileURL: URL) throws {
        let filePath = TodoMarkdownParser.relativePath(for: fileURL, store: store)

        for (index, history) in histories.enumerated() {
            let statement = try prepare("""
            INSERT INTO todo_plan_history (
                file_path, sort_order, captured_at, title, summary,
                steps_json, estimated_minutes, difficulty, difficulty_score,
                tags_json, priority, confidence
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(statement) }

            try bindText(statement, index: 1, value: filePath)
            sqlite3_bind_int(statement, 2, Int32(index))
            try bindText(statement, index: 3, value: Self.isoString(history.capturedAt))
            try bindText(statement, index: 4, value: history.title)
            try bindNullableText(statement, index: 5, value: history.summary)
            try bindText(statement, index: 6, value: Self.jsonString(history.plannedSteps))
            try bindNullableText(statement, index: 7, value: history.estimatedMinutes)
            try bindNullableText(statement, index: 8, value: history.difficulty)
            if let difficultyScore = history.difficultyScore {
                sqlite3_bind_int(statement, 9, Int32(difficultyScore))
            } else {
                sqlite3_bind_null(statement, 9)
            }
            try bindText(statement, index: 10, value: Self.jsonString(history.tags))
            try bindNullableText(statement, index: 11, value: history.priority)
            bindNullableDouble(statement, index: 12, value: history.confidence)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError()
            }
        }
    }

    private func migrate() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS todo_index (
            file_path TEXT PRIMARY KEY,
            archived INTEGER NOT NULL,
            title TEXT NOT NULL,
            status TEXT NOT NULL,
            source_application TEXT NOT NULL,
            created_at_text TEXT NOT NULL,
            due_date_text TEXT,
            difficulty_score INTEGER,
            tags_text TEXT,
            priority TEXT,
            confidence REAL,
            summary_text TEXT,
            original_text TEXT,
            corrected_text TEXT,
            reminder_identifier TEXT,
            reminder_synced_at TEXT,
            reminder_sync_status TEXT,
            content TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        """)

        try ensureColumn("todo_index", column: "tags_text", definition: "TEXT")
        try ensureColumn("todo_index", column: "priority", definition: "TEXT")
        try ensureColumn("todo_index", column: "confidence", definition: "REAL")
        try ensureColumn("todo_index", column: "summary_text", definition: "TEXT")
        try ensureColumn("todo_index", column: "original_text", definition: "TEXT")
        try ensureColumn("todo_index", column: "corrected_text", definition: "TEXT")
        try ensureColumn("todo_index", column: "reminder_identifier", definition: "TEXT")
        try ensureColumn("todo_index", column: "reminder_synced_at", definition: "TEXT")
        try ensureColumn("todo_index", column: "reminder_sync_status", definition: "TEXT")

        try execute("""
        CREATE TABLE IF NOT EXISTS todo_plan_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_path TEXT NOT NULL,
            sort_order INTEGER NOT NULL,
            captured_at TEXT NOT NULL,
            title TEXT NOT NULL,
            summary TEXT,
            steps_json TEXT NOT NULL,
            estimated_minutes TEXT,
            difficulty TEXT,
            difficulty_score INTEGER,
            tags_json TEXT NOT NULL,
            priority TEXT,
            confidence REAL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS todo_index_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)

        try execute("CREATE INDEX IF NOT EXISTS idx_todo_index_archived ON todo_index(archived);")
        try execute("CREATE INDEX IF NOT EXISTS idx_todo_index_status ON todo_index(status);")
        try execute("CREATE INDEX IF NOT EXISTS idx_todo_index_due_date ON todo_index(due_date_text);")
        try execute("CREATE INDEX IF NOT EXISTS idx_todo_index_difficulty ON todo_index(difficulty_score);")
        try execute("CREATE INDEX IF NOT EXISTS idx_todo_index_created ON todo_index(created_at_text);")
        try execute("CREATE INDEX IF NOT EXISTS idx_todo_index_priority ON todo_index(priority);")
        try execute("CREATE INDEX IF NOT EXISTS idx_todo_index_tags ON todo_index(tags_text);")
        try execute("CREATE INDEX IF NOT EXISTS idx_todo_index_reminder_status ON todo_index(reminder_sync_status);")
        try execute("CREATE INDEX IF NOT EXISTS idx_todo_plan_history_file ON todo_plan_history(file_path);")
    }

    private func openDatabase() throws {
        let databaseURL = store.rootDirectory.appendingPathComponent("todos.sqlite3")
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE,
            nil
        )
        guard result == SQLITE_OK, let handle else {
            throw sqliteError()
        }

        db = handle
        sqlite3_busy_timeout(handle, 2000)
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;")
    }

    private func markdownFiles() throws -> [URL] {
        let directories = [store.todosDirectory, store.archiveDirectory]
        var files: [URL] = []

        for directory in directories {
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator where fileURL.pathExtension == "md" {
                files.append(fileURL)
            }
        }

        return files.sorted { $0.path < $1.path }
    }

    private func markdownSourceSignature(for files: [URL]) -> String {
        var hasher = SHA256()

        for fileURL in files {
            let relativePath = TodoMarkdownParser.relativePath(for: fileURL, store: store)
            hasher.update(data: Data(relativePath.utf8))
            hasher.update(data: Data([0]))
            if let content = try? Data(contentsOf: fileURL) {
                hasher.update(data: content)
            } else {
                hasher.update(data: Data("<unreadable>".utf8))
            }
            hasher.update(data: Data([0]))
        }

        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func metadataValue(forKey key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM todo_index_metadata WHERE key = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }

        try bindText(statement, index: 1, value: key)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return columnText(statement, index: 0)
    }

    private func setMetadataValue(_ value: String, forKey key: String) throws {
        let statement = try prepare("""
        INSERT OR REPLACE INTO todo_index_metadata (key, value)
        VALUES (?, ?);
        """)
        defer { sqlite3_finalize(statement) }

        try bindText(statement, index: 1, value: key)
        try bindText(statement, index: 2, value: value)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError()
        }
    }

    private func todoIndexRowCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM todo_index;")
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw sqliteError()
        }

        return Int(sqlite3_column_int(statement, 0))
    }

    private func whereClause(for query: TodoQuery, referenceDate: Date) -> (sql: String, values: [String]) {
        var conditions: [String] = []
        var values: [String] = []

        if query.status == .archived {
            conditions.append("archived = 1")
        } else {
            conditions.append("archived = 0")
        }

        if let status = query.status.storedValue {
            conditions.append("status = ?")
            values.append(status)
        }

        if let priority = query.priority {
            conditions.append("priority = ?")
            values.append(priority)
        }

        if let tag = query.normalizedTag {
            // `tags_text` is a comma-separated index column. Add delimiters on
            // both sides so a query for "工" does not match the tag "工作".
            conditions.append("LOWER(', ' || tags_text || ',') LIKE ?")
            values.append("%, \(tag.lowercased()),%")
        } else if query.showsTaggedRecordsOnly {
            conditions.append("tags_text IS NOT NULL AND tags_text != ''")
        }

        if let search = query.normalizedSearchText?.lowercased() {
            conditions.append("""
            (
                LOWER(title) LIKE ? OR
                LOWER(summary_text) LIKE ? OR
                LOWER(original_text) LIKE ? OR
                LOWER(corrected_text) LIKE ? OR
                LOWER(content) LIKE ?
            )
            """)
            let pattern = "%\(search)%"
            values.append(contentsOf: Array(repeating: pattern, count: 5))
        }

        appendTimeRangeConditions(query.effectiveTimeRange, referenceDate: referenceDate, to: &conditions, values: &values)

        return ("WHERE \(conditions.joined(separator: " AND "))", values)
    }

    private func appendTimeRangeConditions(
        _ timeRange: TodoQuery.TimeRange,
        referenceDate: Date,
        to conditions: inout [String],
        values: inout [String]
    ) {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: referenceDate)

        switch timeRange {
        case .all:
            return
        case .today:
            let end = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? referenceDate
            conditions.append("status != '已完成'")
            conditions.append("due_date_text IS NOT NULL")
            conditions.append("due_date_text < ?")
            values.append(TodoRecordLoader.displayDate(end))
        case .nextThreeDays:
            let end = calendar.date(byAdding: .day, value: 3, to: startOfToday) ?? referenceDate
            conditions.append("due_date_text IS NOT NULL")
            conditions.append("due_date_text >= ?")
            conditions.append("due_date_text < ?")
            values.append(TodoRecordLoader.displayDate(startOfToday))
            values.append(TodoRecordLoader.displayDate(end))
        case .thisWeek:
            guard let week = calendar.dateInterval(of: .weekOfYear, for: referenceDate) else {
                return
            }
            conditions.append("due_date_text IS NOT NULL")
            conditions.append("due_date_text >= ?")
            conditions.append("due_date_text < ?")
            values.append(TodoRecordLoader.displayDate(week.start))
            values.append(TodoRecordLoader.displayDate(week.end))
        case .overdue:
            conditions.append("status != '已完成'")
            conditions.append("due_date_text IS NOT NULL")
            conditions.append("due_date_text < ?")
            values.append(TodoRecordLoader.displayDate(startOfToday))
        case .noDueDate:
            conditions.append("due_date_text IS NULL")
        }
    }

    private func bindWhereValues(_ statement: OpaquePointer, values: [String]) throws {
        for (offset, value) in values.enumerated() {
            try bindText(statement, index: Int32(offset + 1), value: value)
        }
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            defer { sqlite3_free(errorMessage) }
            throw sqliteError(message: errorMessage.map { String(cString: $0) })
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError()
        }

        return statement
    }

    private func bindText(_ statement: OpaquePointer, index: Int32, value: String) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, SQLITE_TRANSIENT)
        }
        guard result == SQLITE_OK else {
            throw sqliteError()
        }
    }

    private func bindNullableText(_ statement: OpaquePointer, index: Int32, value: String?) throws {
        if let value {
            try bindText(statement, index: index, value: value)
        } else {
            let result = sqlite3_bind_null(statement, index)
            guard result == SQLITE_OK else {
                throw sqliteError()
            }
        }
    }

    private func bindNullableDouble(_ statement: OpaquePointer, index: Int32, value: Double?) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func columnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }

        return String(cString: pointer)
    }

    private func ensureColumn(_ table: String, column: String, definition: String) throws {
        let columns = try columnNames(in: table)
        guard !columns.contains(column) else {
            return
        }
        try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
    }

    private func columnNames(in table: String) throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = columnText(statement, index: 1) {
                columns.insert(name)
            }
        }
        return columns
    }

    private func sqliteError(message: String? = nil) -> Error {
        let description = message ?? (db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "未知 SQLite 错误")
        return NSError(domain: "TodoSQLiteStore", code: Int(sqlite3_errcode(db)), userInfo: [
            NSLocalizedDescriptionKey: description
        ])
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func jsonString(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }
}
