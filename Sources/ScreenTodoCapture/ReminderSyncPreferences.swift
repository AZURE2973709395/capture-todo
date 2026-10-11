import Foundation

/// Apple Reminders（苹果提醒事项）单向同步偏好。
///
/// 该偏好属于本机 UI/系统集成设置，不能写入 `config.json`，避免和大模型 API
/// 配置混在一起，也满足“连接测试和 UI 偏好不改写配置文件”的约束。
enum ReminderSyncPreferences {
    private static let enabledKey = "syncAppleRemindersEnabled"

    static var isEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }
}

enum ReminderSyncStatus: String {
    case synced
    case failed
    case permissionDenied
    case reminderMissing

    static func display(_ value: String?) -> String {
        switch value {
        case synced.rawValue:
            return "已同步"
        case failed.rawValue:
            return "同步失败"
        case permissionDenied.rawValue:
            return "无权限"
        case reminderMissing.rawValue:
            return "提醒事项不存在"
        default:
            return "未同步"
        }
    }
}

struct ReminderSyncMetadata {
    var identifier: String?
    var syncedAt: Date?
    var status: ReminderSyncStatus
    var message: String? = nil
}
