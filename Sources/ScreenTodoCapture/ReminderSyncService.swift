import EventKit
import Foundation
import OSLog

private let reminderSyncLogger = Logger(subsystem: "ScreenTodoCapture", category: "ReminderSync")

/// 单向同步到 Apple Reminders（苹果提醒事项）的系统集成层。
///
/// 该服务只负责 EventKit（事件工具包）交互，不读写 Markdown 或 SQLite。调用方在本地
/// 待办保存成功后传入 `TodoRecord`，再把返回的同步元数据写回本地 source of truth。
final class ReminderSyncService {
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    func createReminder(for record: TodoRecord) async -> ReminderSyncMetadata {
        do {
            guard try await requestReminderAccess() else {
                reminderSyncLogger.error("Reminder access denied when creating reminder.")
                return ReminderSyncMetadata(identifier: nil, syncedAt: Date(), status: .permissionDenied)
            }

            let reminder = EKReminder(eventStore: eventStore)
            reminder.title = record.title
            reminder.notes = notes(for: record)
            reminder.priority = priority(for: record.priority)
            if let dueDate = record.dueDate {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: dueDate
                )
            }

            guard let calendar = eventStore.defaultCalendarForNewReminders()
                    ?? eventStore.calendars(for: .reminder).first else {
                reminderSyncLogger.error("No writable reminders calendar found.")
                return ReminderSyncMetadata(identifier: nil, syncedAt: Date(), status: .failed)
            }

            reminder.calendar = calendar
            try eventStore.save(reminder, commit: true)
            reminderSyncLogger.info("Created Apple Reminder for todo. title=\(record.title, privacy: .public)")
            return ReminderSyncMetadata(
                identifier: reminder.calendarItemIdentifier,
                syncedAt: Date(),
                status: .synced
            )
        } catch {
            reminderSyncLogger.error("Failed to create Apple Reminder. error=\(error.localizedDescription, privacy: .public)")
            return ReminderSyncMetadata(identifier: nil, syncedAt: Date(), status: .failed)
        }
    }

    func updateCompletion(for record: TodoRecord, isCompleted: Bool) async -> ReminderSyncMetadata {
        guard let identifier = record.reminderIdentifier, !identifier.isEmpty else {
            return ReminderSyncMetadata(identifier: nil, syncedAt: Date(), status: .reminderMissing)
        }

        do {
            guard try await requestReminderAccess() else {
                reminderSyncLogger.error("Reminder access denied when updating reminder.")
                return ReminderSyncMetadata(identifier: identifier, syncedAt: Date(), status: .permissionDenied)
            }

            guard let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
                reminderSyncLogger.error("Apple Reminder not found for identifier.")
                return ReminderSyncMetadata(identifier: identifier, syncedAt: Date(), status: .reminderMissing)
            }

            reminder.isCompleted = isCompleted
            if !isCompleted {
                reminder.completionDate = nil
            }
            try eventStore.save(reminder, commit: true)
            reminderSyncLogger.info("Updated Apple Reminder completion. completed=\(isCompleted, privacy: .public)")
            return ReminderSyncMetadata(identifier: identifier, syncedAt: Date(), status: .synced)
        } catch {
            reminderSyncLogger.error("Failed to update Apple Reminder. error=\(error.localizedDescription, privacy: .public)")
            return ReminderSyncMetadata(identifier: identifier, syncedAt: Date(), status: .failed)
        }
    }

    private func requestReminderAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            if #available(macOS 14.0, *) {
                eventStore.requestFullAccessToReminders { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            } else {
                eventStore.requestAccess(to: .reminder) { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
    }

    private func notes(for record: TodoRecord) -> String {
        var parts: [String] = []
        if let summary = record.summary, !summary.isEmpty {
            parts.append(summary)
        }
        if !record.plannedSteps.isEmpty {
            parts.append("执行步骤:\n\(record.plannedSteps.map { "- \($0)" }.joined(separator: "\n"))")
        }
        parts.append("本地 Markdown: \(record.fileURL.path)")
        return parts.joined(separator: "\n\n")
    }

    private func priority(for value: String?) -> Int {
        switch TodoPriority.normalize(value) {
        case "urgent":
            return 1
        case "high":
            return 3
        case "medium":
            return 5
        case "low":
            return 9
        default:
            return 0
        }
    }
}
