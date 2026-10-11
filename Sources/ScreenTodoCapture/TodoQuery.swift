import Foundation

/// TodoQuery is the shared contract between the workbench UI, loader, and
/// SQLite index. Markdown remains the source of truth; this type only describes
/// which indexed rows should be loaded and then parsed back into TodoRecord.
struct TodoQuery: Equatable, Sendable {
    enum Status: String, CaseIterable, Sendable {
        case all = "全部状态"
        case pending = "待处理"
        case completed = "已完成"
        case archived = "已归档"

        var storedValue: String? {
            switch self {
            case .all:
                return nil
            case .pending:
                return "待处理"
            case .completed:
                return "已完成"
            case .archived:
                return nil
            }
        }
    }

    enum TimeRange: String, CaseIterable, Sendable {
        case all = "全部时间"
        case today = "今日"
        case nextThreeDays = "近三天"
        case thisWeek = "本周"
        case overdue = "已过期"
        case noDueDate = "无截止时间"
    }

    enum View: String, CaseIterable, Sendable {
        case all = "全部"
        case today = "今日"
        case tags = "标签"
    }

    var searchText: String
    var status: Status
    var tag: String?
    var priority: String?
    var timeRange: TimeRange
    var view: View

    init(
        searchText: String = "",
        status: Status = .all,
        tag: String? = nil,
        priority: String? = nil,
        timeRange: TimeRange = .all,
        view: View = .all
    ) {
        self.searchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.status = status
        self.tag = tag?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.priority = TodoPriority.normalize(priority)
        self.timeRange = timeRange
        self.view = view
    }

    var normalizedSearchText: String? {
        searchText.isEmpty ? nil : searchText
    }

    var normalizedTag: String? {
        TodoPriority.normalizeTags([tag ?? ""]).first
    }

    var effectiveTimeRange: TimeRange {
        view == .today ? .today : timeRange
    }

    var showsTaggedRecordsOnly: Bool {
        view == .tags && normalizedTag == nil
    }

    var isDefault: Bool {
        normalizedSearchText == nil &&
            status == .all &&
            normalizedTag == nil &&
            priority == nil &&
            timeRange == .all &&
            view == .all
    }

    var loggingDescription: String {
        let search = normalizedSearchText ?? "-"
        let tag = normalizedTag ?? "-"
        let priority = priority ?? "-"
        return "view=\(view.rawValue), status=\(status.rawValue), time=\(effectiveTimeRange.rawValue), search=\(search), tag=\(tag), priority=\(priority)"
    }

    /// In-memory mirror of the SQLite WHERE semantics, used only when the index
    /// cannot be read. It keeps fallback behavior correct without letting the
    /// fallback path define a separate product behavior.
    func matches(_ record: TodoRecord, referenceDate: Date = Date(), calendar: Calendar = .current) -> Bool {
        let isArchived = record.fileURL.path.contains("/Archive/")
        if status == .archived {
            guard isArchived else { return false }
        } else if isArchived {
            return false
        }

        if let status = status.storedValue, record.status != status {
            return false
        }

        if let priority, TodoPriority.normalize(record.priority) != priority {
            return false
        }

        if let tag = normalizedTag {
            let wanted = tag.lowercased()
            guard record.tags.contains(where: { $0.lowercased() == wanted }) else {
                return false
            }
        } else if showsTaggedRecordsOnly, record.tags.isEmpty {
            return false
        }

        if let search = normalizedSearchText?.lowercased() {
            // SQLite searches the full Markdown `content` column. The fallback
            // path must mirror that contract so manual sections remain searchable
            // even if the SQLite index cannot be used.
            guard record.content.lowercased().contains(search) else {
                return false
            }
        }

        switch effectiveTimeRange {
        case .all:
            return true
        case .today:
            let interval = calendar.dateInterval(of: .day, for: referenceDate)
            guard let interval else { return true }
            return record.status != "已完成" && (record.dueDate.map { $0 < interval.end } ?? false)
        case .nextThreeDays:
            let start = calendar.startOfDay(for: referenceDate)
            let end = calendar.date(byAdding: .day, value: 3, to: start) ?? referenceDate
            return record.dueDate.map { $0 >= start && $0 < end } ?? false
        case .thisWeek:
            guard let week = calendar.dateInterval(of: .weekOfYear, for: referenceDate) else {
                return true
            }
            return record.dueDate.map { week.contains($0) } ?? false
        case .overdue:
            let startOfToday = calendar.startOfDay(for: referenceDate)
            return record.status != "已完成" && (record.dueDate.map { $0 < startOfToday } ?? false)
        case .noDueDate:
            return record.dueDate == nil
        }
    }
}
