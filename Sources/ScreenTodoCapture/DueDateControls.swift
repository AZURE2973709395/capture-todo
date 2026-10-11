import AppKit

/// 截止时间选择控件。
///
/// 默认使用紧凑的 NSDatePicker（macOS 原生日期/时间选择器），勾选后才会写入待办。
/// 图形日历放到单独弹窗里，避免在 NSAlert 内嵌大日历/时钟时把内容挤压重叠。
@MainActor
final class DueDateControls {
    let enabledButton = NSButton(checkboxWithTitle: "设置截止时间", target: nil, action: nil)
    let datePicker = NSDatePicker()
    private let calendarButton = NSButton(title: "打开日历", target: nil, action: nil)

    init(initialDate: Date? = nil) {
        enabledButton.state = initialDate == nil ? .off : .on
        enabledButton.target = self
        enabledButton.action = #selector(toggle)

        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = [.yearMonthDay, .hourMinute]
        datePicker.locale = Locale(identifier: "zh_CN")
        datePicker.dateValue = initialDate ?? Date()
        datePicker.isEnabled = initialDate != nil
        datePicker.translatesAutoresizingMaskIntoConstraints = false
        datePicker.widthAnchor.constraint(equalToConstant: 220).isActive = true

        calendarButton.target = self
        calendarButton.action = #selector(openCalendar)
        calendarButton.isEnabled = initialDate != nil
    }

    var stackView: NSStackView {
        let pickerRow = NSStackView(views: [datePicker, calendarButton])
        pickerRow.orientation = .horizontal
        pickerRow.spacing = 8
        pickerRow.alignment = .centerY

        let stack = NSStackView(views: [enabledButton, pickerRow])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        AppFontPreferences.applyFontsRecursively(to: stack)
        return stack
    }

    var isoString: String? {
        guard enabledButton.state == .on else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: datePicker.dateValue)
    }

    @objc private func toggle() {
        let enabled = enabledButton.state == .on
        datePicker.isEnabled = enabled
        calendarButton.isEnabled = enabled
    }

    @objc private func openCalendar() {
        let alert = NSAlert()
        alert.messageText = "选择截止日期"
        alert.informativeText = "时间仍使用左侧输入框中的时分。"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let calendarPicker = NSDatePicker()
        calendarPicker.datePickerStyle = .clockAndCalendar
        calendarPicker.datePickerElements = [.yearMonthDay]
        calendarPicker.locale = Locale(identifier: "zh_CN")
        calendarPicker.dateValue = datePicker.dateValue
        calendarPicker.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 230))
        container.addSubview(calendarPicker)
        AppFontPreferences.applyFontsRecursively(to: container)
        NSLayoutConstraint.activate([
            calendarPicker.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            calendarPicker.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        alert.accessoryView = container

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let calendar = Calendar.current
        let time = calendar.dateComponents([.hour, .minute, .second], from: datePicker.dateValue)
        var selectedDate = calendar.dateComponents([.year, .month, .day], from: calendarPicker.dateValue)
        selectedDate.hour = time.hour
        selectedDate.minute = time.minute
        selectedDate.second = time.second

        if let date = calendar.date(from: selectedDate) {
            datePicker.dateValue = date
            enabledButton.state = .on
            toggle()
        }
    }
}
