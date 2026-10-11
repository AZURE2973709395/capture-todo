import EventKit
import Foundation
import OSLog

private let reminderSyncLogger = Logger(subsystem: "ScreenTodoCapture", category: "ReminderSync")

/// 本地记录到系统提醒的值类型边界。EventKit 对象留在系统适配器内，便于用假后端验证同步。
struct ReminderPayload {
    var title: String
    var notes: String
    var priority: Int
    var dueDate: Date?
    var isCompleted: Bool
    var sourceURL: URL

    init(record: TodoRecord) {
        title = record.title
        var parts = [record.summary].compactMap { $0 }.filter { !$0.isEmpty }
        if !record.plannedSteps.isEmpty {
            parts.append("执行步骤:\n" + record.plannedSteps.map { "- \($0)" }.joined(separator: "\n"))
        }
        parts.append("本地 Markdown: \(record.fileURL.path)")
        notes = parts.joined(separator: "\n\n")
        switch TodoPriority.normalize(record.priority) {
        case "urgent": priority = 1
        case "high": priority = 3
        case "medium": priority = 5
        case "low": priority = 9
        default: priority = 0
        }
        dueDate = record.dueDate
        isCompleted = record.status == "已完成"
        sourceURL = record.fileURL.standardizedFileURL
    }
}

/// 系统访问边界：所有 EventKit 对象在主 actor 上使用；授权和查找可以异步等待。
@MainActor
protocol ReminderSyncBackend {
    func requestAccess() async throws -> Bool
    func upsert(_ payload: ReminderPayload, identifier: String?) async throws -> String
    func verifyConnection() throws
}

enum ReminderSyncError: LocalizedError {
    case noWritableCalendar
    case lookupFailed

    var errorDescription: String? {
        switch self {
        case .noWritableCalendar: return "未找到可写的提醒事项列表，请先在苹果提醒事项中创建一个列表。"
        case .lookupFailed: return "无法读取提醒事项，请检查系统权限后重试。"
        }
    }
}

/// EventKit 适配器。优先通过已保存 ID 更新；ID 丢失时通过本地文件 URL 恢复关联，避免重复创建。
@MainActor
final class EventKitReminderBackend: ReminderSyncBackend {
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    func requestAccess() async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .denied || status == .restricted { return false }
        if #available(macOS 14.0, *) {
            if status == .fullAccess { return true }
        } else if status == .authorized { return true }

        return try await withCheckedThrowingContinuation { continuation in
            let completion: @Sendable (Bool, Error?) -> Void = { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
            if #available(macOS 14.0, *) {
                eventStore.requestFullAccessToReminders(completion: completion)
            } else {
                eventStore.requestAccess(to: .reminder, completion: completion)
            }
        }
    }

    func upsert(_ payload: ReminderPayload, identifier: String?) async throws -> String {
        var existing = identifier.flatMap { eventStore.calendarItem(withIdentifier: $0) as? EKReminder }
        if existing == nil {
            // URL 恢复覆盖系统 ID 变化或保存系统提醒后本地元数据写回失败的情况。
            let predicate = eventStore.predicateForReminders(in: nil)
            let sourceURL = payload.sourceURL
            let recoveredID: String? = try await withCheckedThrowingContinuation { continuation in
                eventStore.fetchReminders(matching: predicate) { reminders in
                    guard let reminders else {
                        continuation.resume(throwing: ReminderSyncError.lookupFailed)
                        return
                    }
                    // 只跨并发边界传值类型 ID，避免传递非 Sendable 的 EventKit 对象。
                    let identifier = reminders.first { $0.url?.standardizedFileURL == sourceURL }?.calendarItemIdentifier
                    continuation.resume(returning: identifier)
                }
            }
            existing = recoveredID.flatMap { eventStore.calendarItem(withIdentifier: $0) as? EKReminder }
        }

        let reminder = existing ?? EKReminder(eventStore: eventStore)
        if existing == nil {
            reminder.calendar = try writableCalendar()
        }
        guard reminder.calendar.allowsContentModifications else { throw ReminderSyncError.noWritableCalendar }
        reminder.title = payload.title
        reminder.notes = payload.notes
        reminder.priority = payload.priority
        reminder.url = payload.sourceURL
        reminder.dueDateComponents = payload.dueDate.map {
            Calendar.current.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute], from: $0)
        }
        reminder.alarms = payload.dueDate.map { [EKAlarm(absoluteDate: $0)] } ?? []
        reminder.isCompleted = payload.isCompleted
        if !payload.isCompleted { reminder.completionDate = nil }
        try eventStore.save(reminder, commit: true)
        reminderSyncLogger.info("Saved reminder. created=\(existing == nil, privacy: .public)")
        return reminder.calendarItemIdentifier
    }

    private func writableCalendar() throws -> EKCalendar {
        let preferred = eventStore.defaultCalendarForNewReminders()
        guard let calendar = preferred.flatMap({ $0.allowsContentModifications ? $0 : nil })
            ?? eventStore.calendars(for: .reminder).first(where: { $0.allowsContentModifications }) else {
            throw ReminderSyncError.noWritableCalendar
        }
        return calendar
    }

    /// 真实连接检查只操作本次创建的临时提醒：验证写入、更新完成状态，再清理。
    /// 保存前失败不会删除任何项目；清理失败会返回明确错误，方便用户手动移除测试提醒。
    func verifyConnection() throws {
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = "Screen Todo Capture 连接测试（临时）"
        reminder.calendar = try writableCalendar()
        try eventStore.save(reminder, commit: true)
        var verificationError: Error?
        do {
            guard let saved = eventStore.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder,
                  saved.title == reminder.title else { throw ReminderSyncError.lookupFailed }
            saved.isCompleted = true
            try eventStore.save(saved, commit: true)
            guard (eventStore.calendarItem(withIdentifier: saved.calendarItemIdentifier) as? EKReminder)?.isCompleted == true else {
                throw ReminderSyncError.lookupFailed
            }
        } catch { verificationError = error }
        do { try eventStore.remove(reminder, commit: true) }
        catch {
            throw NSError(domain: "ReminderSync", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "临时提醒清理失败，请在苹果提醒事项中移除‘Screen Todo Capture 连接测试（临时）’：\(error.localizedDescription)"])
        }
        if let verificationError { throw verificationError }
        reminderSyncLogger.info("Live reminder connection check passed; temporary reminder removed.")
    }

}

/// 应用同步入口。共享实例串行处理所有窗口的请求，等待前一个请求完成后再读最新 Markdown，
/// 防止授权弹窗期间多次编辑导致旧状态覆盖新状态或重复创建。失败不撤销本地保存。
@MainActor
final class ReminderSyncService {
    static let shared = ReminderSyncService()
    private let backend: any ReminderSyncBackend
    private var pending: Task<Void, Never>?

    init(backend: any ReminderSyncBackend = EventKitReminderBackend()) {
        self.backend = backend
    }

    func requestAccess() async throws -> Bool { try await backend.requestAccess() }

    func verifyConnection() async throws {
        await pending?.value
        guard try await backend.requestAccess() else {
            throw NSError(domain: "ReminderSync", code: 2, userInfo: [NSLocalizedDescriptionKey: "未获得提醒事项权限，请在系统设置中允许访问。"])
        }
        try backend.verifyConnection()
    }

    func syncTodo(fileURL: URL, store: TodoStore) async throws -> ReminderSyncMetadata? {
        let previous = pending
        let operation = Task { @MainActor () throws -> ReminderSyncMetadata? in
            await previous?.value
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let record = try store.loadRecord(fileURL: fileURL) else { return nil }
            let metadata = await sync(record: record)
            // 文件可能在系统授权/查询期间被删除或归档，不重建已移除的本地记录。
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            try store.updateReminderMetadata(fileURL: fileURL, metadata: metadata)
            return metadata
        }
        pending = Task { _ = try? await operation.value }
        return try await operation.value
    }

    /// 纯同步编排，可注入后端测试授权拒绝、字段映射、关联保留和系统保存失败。
    func sync(record: TodoRecord) async -> ReminderSyncMetadata {
        do {
            guard try await backend.requestAccess() else {
                reminderSyncLogger.warning("Reminder permission denied.")
                return ReminderSyncMetadata(identifier: record.reminderIdentifier, syncedAt: record.reminderSyncedAt,
                    status: .permissionDenied, message: "请在系统设置 → 隐私与安全性 → 提醒事项中允许访问，再点击同步重试。")
            }
            let identifier = try await backend.upsert(ReminderPayload(record: record), identifier: record.reminderIdentifier)
            return ReminderSyncMetadata(identifier: identifier, syncedAt: Date(), status: .synced)
        } catch {
            reminderSyncLogger.error("Reminder sync failed: \(error.localizedDescription, privacy: .public)")
            return ReminderSyncMetadata(identifier: record.reminderIdentifier, syncedAt: record.reminderSyncedAt,
                status: .failed, message: error.localizedDescription)
        }
    }
}
