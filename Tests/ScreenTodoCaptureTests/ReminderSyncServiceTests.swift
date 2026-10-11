import Foundation
import ScreenTodoCaptureCore
import Testing
@testable import ScreenTodoCapture

/// 使用内存后端验证同步编排，不请求系统权限，也不触碰用户真实的提醒事项。
@MainActor
struct ReminderSyncServiceTests {
    @Test func deniedAccessPreservesAssociationAndLastSuccessTime() async throws {
        let (store, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        var record = original
        record.reminderIdentifier = "existing"
        record.reminderSyncedAt = Date(timeIntervalSince1970: 100)
        let backend = FakeReminderBackend()
        backend.granted = false
        let result = await ReminderSyncService(backend: backend).sync(record: record)
        #expect(result.status == .permissionDenied)
        #expect(result.identifier == "existing")
        #expect(result.syncedAt == record.reminderSyncedAt)
        #expect(backend.payloads.isEmpty)
        #expect(result.message?.contains("系统设置") == true)
    }

    @Test func mapsAllFieldsAndCompletedState() async throws {
        let (store, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        var record = original
        record.status = "已完成"
        record.priority = "urgent"
        record.summary = "作业摘要"
        record.plannedSteps = ["检查格式", "提交"]
        record.dueDate = Date(timeIntervalSince1970: 1_900_000_000)
        let backend = FakeReminderBackend()
        let result = await ReminderSyncService(backend: backend).sync(record: record)
        let payload = try #require(backend.payloads.first)
        #expect(result.status == .synced)
        #expect(payload.title == record.title)
        #expect(payload.priority == 1)
        #expect(payload.dueDate == record.dueDate)
        #expect(payload.isCompleted)
        #expect(payload.notes.contains("作业摘要"))
        #expect(payload.notes.contains("- 检查格式"))
        #expect(payload.sourceURL == record.fileURL.standardizedFileURL)
    }

    @Test func updatesExistingReminderAndClearsRemovedDueDate() async throws {
        let (store, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let backend = FakeReminderBackend()
        let service = ReminderSyncService(backend: backend)
        let first = try #require(try await service.syncTodo(fileURL: original.fileURL, store: store))
        var record = try #require(try store.loadRecord(fileURL: original.fileURL))
        // 标题是 Markdown 一级标题，由编辑器的 title 替换逻辑直接改写。
        record.content = TodoMarkdownEditor.setTitle("修改后的标题", in: record.content)
        record.content = TodoMarkdownEditor.setMetadata("状态", value: "已完成", in: record.content)
        record.content = TodoMarkdownEditor.setMetadata("截止时间", value: nil, in: record.content)
        try store.update(record: record)
        let second = try #require(try await service.syncTodo(fileURL: original.fileURL, store: store))
        #expect(first.identifier == second.identifier)
        #expect(backend.createdCount == 1)
        #expect(backend.payloads.last?.title == "修改后的标题")
        #expect(backend.payloads.first?.dueDate != nil)
        #expect(backend.payloads.last?.dueDate == nil)
        #expect(backend.payloads.last?.isCompleted == true)
        let indexed = try #require(try TodoRecordLoader(store: store).load().first)
        #expect(indexed.reminderIdentifier == first.identifier)
        #expect(indexed.reminderSyncStatus == "synced")
    }

    @Test func failedSaveKeepsIdentifierAndCanRetry() async throws {
        let (store, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let backend = FakeReminderBackend()
        let service = ReminderSyncService(backend: backend)
        let first = try #require(try await service.syncTodo(fileURL: record.fileURL, store: store))
        let lastSuccess = try #require(try store.loadRecord(fileURL: record.fileURL)).reminderSyncedAt
        backend.failSave = true
        let failed = try #require(try await service.syncTodo(fileURL: record.fileURL, store: store))
        #expect(failed.status == .failed)
        #expect(failed.identifier == first.identifier)
        #expect(failed.syncedAt == lastSuccess)
        backend.failSave = false
        let retried = try #require(try await service.syncTodo(fileURL: record.fileURL, store: store))
        #expect(retried.status == .synced)
        #expect(retried.identifier == first.identifier)
        #expect(backend.createdCount == 1)
    }

    @Test func simultaneousRequestsWaitAndReloadAssociation() async throws {
        let (store, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let backend = FakeReminderBackend()
        backend.yieldDuringSave = true
        let service = ReminderSyncService(backend: backend)
        let first = Task { try await service.syncTodo(fileURL: record.fileURL, store: store) }
        let second = Task { try await service.syncTodo(fileURL: record.fileURL, store: store) }
        let a = try #require(try await first.value)
        let b = try #require(try await second.value)
        #expect(a.identifier == b.identifier)
        #expect(backend.identifiersPassed == [nil, a.identifier])
        #expect(backend.maxConcurrentSaves == 1)
    }

    @Test func missingLocalFileIsSkipped() async throws {
        let (store, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        try FileManager.default.removeItem(at: record.fileURL)
        let backend = FakeReminderBackend()
        let result = try await ReminderSyncService(backend: backend).syncTodo(fileURL: record.fileURL, store: store)
        #expect(result == nil)
        #expect(backend.payloads.isEmpty)
    }

    @Test func connectionCheckHonorsPermissionAndReportsBackendFailure() async throws {
        let backend = FakeReminderBackend()
        let service = ReminderSyncService(backend: backend)
        backend.granted = false
        await #expect(throws: (any Error).self) { try await service.verifyConnection() }
        #expect(backend.connectionChecks == 0)
        backend.granted = true
        try await service.verifyConnection()
        #expect(backend.connectionChecks == 1)
        backend.failSave = true
        await #expect(throws: ReminderSyncError.self) { try await service.verifyConnection() }
    }

    private func fixture() throws -> (TodoStore, TodoRecord) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = TodoStore(rootDirectoryOverride: root)
        let saved = try store.save(draft: TodoDraft(title: "同步测试", originalText: "测试内容", sourceApplication: "测试", dueDate: "2030-03-01T12:00:00Z"), image: nil)
        return (store, try #require(try store.loadRecord(fileURL: saved.todoURL)))
    }
}

@MainActor
private final class FakeReminderBackend: ReminderSyncBackend {
    var connectionChecks = 0
    var granted = true
    var failSave = false
    var yieldDuringSave = false
    var payloads: [ReminderPayload] = []
    var identifiersPassed: [String?] = []
    var createdCount = 0
    var activeSaves = 0
    var maxConcurrentSaves = 0

    func requestAccess() async throws -> Bool { granted }
    func verifyConnection() throws {
        connectionChecks += 1
        if failSave { throw ReminderSyncError.noWritableCalendar }
    }

    func upsert(_ payload: ReminderPayload, identifier: String?) async throws -> String {
        activeSaves += 1
        maxConcurrentSaves = max(maxConcurrentSaves, activeSaves)
        defer { activeSaves -= 1 }
        if yieldDuringSave { await Task.yield() }
        if failSave { throw ReminderSyncError.noWritableCalendar }
        payloads.append(payload)
        identifiersPassed.append(identifier)
        if let identifier { return identifier }
        createdCount += 1
        return "fake-reminder-\(createdCount)"
    }
}
