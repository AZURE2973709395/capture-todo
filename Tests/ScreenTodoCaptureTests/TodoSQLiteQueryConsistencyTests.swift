import Foundation
import SQLite3
import ScreenTodoCaptureCore
@testable import ScreenTodoCapture
import Testing

private let testSQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class TodoSQLiteQueryConsistencyTests {
    @Test
    func testSQLiteTagFilterMatchesWholeTagInsteadOfSubstring() throws {
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let store = TodoStore(rootDirectoryOverride: temporaryRoot)
        _ = try store.save(
            draft: TodoDraft(
                title: "整理工作材料",
                originalText: "今天整理工作材料",
                sourceApplication: "测试",
                tags: ["工作"],
                createdAt: Date(timeIntervalSince1970: 1_800_000_600)
            ),
            image: nil
        )

        let index = try TodoSQLiteStore(store: store)
        try index.rebuildIndexFromMarkdown()

        let partialTagResults = try index.loadRecords(matching: TodoQuery(tag: "工"))
        #expect(partialTagResults.isEmpty)

        let exactTagResults = try index.loadRecords(matching: TodoQuery(tag: "工作"))
        #expect(exactTagResults.map(\.title) == ["整理工作材料"])
    }

    @Test
    func testSearchFullMarkdownContentMatchesSQLiteAndFallback() throws {
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let store = TodoStore(rootDirectoryOverride: temporaryRoot)
        try store.ensureDirectories()

        let markdown = """
        # 标题不含关键字

        - 状态: 待处理
        - 来源应用: 测试
        - 创建时间: 2027-01-15T08:00:00+08:00

        ## 任务摘要

        常规摘要

        ## 原始识别文本

        ```text
        普通 OCR 文本
        ```

        ## 手工备注

        manual-only-token
        """
        let fileURL = store.todosDirectory.appendingPathComponent("manual.md")
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)

        let record = try #require(TodoMarkdownParser.parse(fileURL: fileURL, content: markdown, store: store))
        let query = TodoQuery(searchText: "manual-only-token")
        #expect(query.matches(record))

        let index = try TodoSQLiteStore(store: store)
        try index.rebuildIndexFromMarkdown()
        let sqliteResults = try index.loadRecords(matching: query)
        #expect(sqliteResults.map(\.title) == ["标题不含关键字"])
    }

    @Test
    func testLoaderSkipsSQLiteRebuildWhenMarkdownSignatureIsUnchanged() throws {
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let store = TodoStore(rootDirectoryOverride: temporaryRoot)
        _ = try store.save(
            draft: TodoDraft(
                title: "索引缓存任务",
                originalText: "验证未变化时不重建 SQLite",
                sourceApplication: "测试",
                createdAt: Date(timeIntervalSince1970: 1_800_000_700)
            ),
            image: nil
        )

        let databaseURL = store.rootDirectory.appendingPathComponent("todos.sqlite3")
        try setUpdatedAt("sentinel-updated-at", databaseURL: databaseURL)

        let records = try TodoRecordLoader(store: store).load()

        #expect(records.map(\.title) == ["索引缓存任务"])
        #expect(try updatedAt(databaseURL: databaseURL) == "sentinel-updated-at")
    }

    @Test
    func testLoaderRebuildsSQLiteIndexAfterExternalMarkdownEdit() throws {
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let store = TodoStore(rootDirectoryOverride: temporaryRoot)
        let stored = try store.save(
            draft: TodoDraft(
                title: "外部修改任务",
                originalText: "初始文本",
                sourceApplication: "测试",
                createdAt: Date(timeIntervalSince1970: 1_800_000_701)
            ),
            image: nil
        )

        var markdown = try String(contentsOf: stored.todoURL, encoding: .utf8)
        markdown.append("\n## 手工备注\n\nexternal-edit-token\n")
        try markdown.write(to: stored.todoURL, atomically: true, encoding: .utf8)

        let results = try TodoRecordLoader(
            store: store,
            query: TodoQuery(searchText: "external-edit-token")
        ).load()

        #expect(results.map(\.title) == ["外部修改任务"])
    }

    private func setUpdatedAt(_ value: String, databaseURL: URL) throws {
        try withDatabase(databaseURL) { db in
            let statement = try prepare("UPDATE todo_index SET updated_at = ?;", db: db)
            defer { sqlite3_finalize(statement) }

            let bindResult = value.withCString { pointer in
                sqlite3_bind_text(statement, 1, pointer, -1, testSQLITE_TRANSIENT)
            }
            guard bindResult == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError(db)
            }
        }
    }

    private func updatedAt(databaseURL: URL) throws -> String? {
        try withDatabase(databaseURL) { db in
            let statement = try prepare("SELECT updated_at FROM todo_index LIMIT 1;", db: db)
            defer { sqlite3_finalize(statement) }

            guard sqlite3_step(statement) == SQLITE_ROW,
                  let pointer = sqlite3_column_text(statement, 0) else {
                return nil
            }
            return String(cString: pointer)
        }
    }

    private func withDatabase<T>(_ databaseURL: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE, nil)
        guard openResult == SQLITE_OK, let handle else {
            throw sqliteError(handle)
        }
        defer { sqlite3_close(handle) }

        return try body(handle)
    }

    private func prepare(_ sql: String, db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError(db)
        }

        return statement
    }

    private func sqliteError(_ db: OpaquePointer?) -> Error {
        let description = db.map { String(cString: sqlite3_errmsg($0)) } ?? "未知 SQLite 错误"
        return NSError(domain: "TodoSQLiteQueryConsistencyTests", code: Int(sqlite3_errcode(db)), userInfo: [
            NSLocalizedDescriptionKey: description
        ])
    }
}
