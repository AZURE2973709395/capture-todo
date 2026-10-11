import AppKit
import ScreenTodoCaptureCore

/// 待办确认弹窗。
///
/// OCR 结果可能误识别，所以保存前必须让用户确认标题和原文。
struct TodoConfirmationWindow {
    /// 展示草稿并返回用户编辑后的版本；用户取消时返回 nil。
    @MainActor
    func confirm(draft: TodoDraft) -> TodoDraft? {
        let alert = NSAlert()
        alert.messageText = "创建截图待办"
        alert.informativeText = "请确认标题和 OCR（光学字符识别）原文。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "保存待办")
        alert.addButton(withTitle: "取消")

        let titleField = NSTextField(string: draft.title)
        titleField.placeholderString = "待办标题"

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        textView.string = draft.originalText
        textView.isEditable = true
        AppFontPreferences.apply(.body, to: textView)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView

        let sourceLabel = NSTextField(labelWithString: "来源应用: \(draft.sourceApplication)")
        let hintLabel = NSTextField(labelWithString: "时间线索: \(draft.dueHint ?? "未识别")")
        let dueDateControls = DueDateControls(initialDate: draft.dueDate.flatMap(TodoRecordLoader.parseDate))
        let planLabel = NSTextField(labelWithString: planSummary(from: draft))
        planLabel.textColor = .secondaryLabelColor
        planLabel.maximumNumberOfLines = 4

        // NSAlert 的 accessoryView 不适合复杂布局，这里用垂直栈保持结构简单。
        let stackView = NSStackView(views: [sourceLabel, hintLabel, dueDateControls.stackView, planLabel, titleField, scrollView])
        stackView.orientation = .vertical
        stackView.spacing = 8
        stackView.alignment = .leading
        stackView.setFrameSize(NSSize(width: 520, height: 292))
        AppFontPreferences.applyFontsRecursively(to: stackView)

        titleField.widthAnchor.constraint(equalToConstant: 520).isActive = true
        scrollView.widthAnchor.constraint(equalToConstant: 520).isActive = true
        scrollView.heightAnchor.constraint(equalToConstant: 220).isActive = true

        alert.accessoryView = stackView
        let response = alert.runModal()

        guard response == .alertFirstButtonReturn else {
            return nil
        }

        var editedDraft = draft
        editedDraft.title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        editedDraft.originalText = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        editedDraft.dueDate = dueDateControls.isoString

        if editedDraft.title.isEmpty {
            editedDraft.title = "从截图创建的待办"
        }

        return editedDraft
    }

    private func planSummary(from draft: TodoDraft) -> String {
        guard draft.summary != nil || !draft.plannedSteps.isEmpty || draft.estimatedMinutes != nil || draft.difficulty != nil else {
            return "大模型增强: 未启用或未返回规划"
        }

        var parts: [String] = []
        if let summary = draft.summary, !summary.isEmpty {
            parts.append("摘要: \(summary)")
        }
        if let correctedText = draft.correctedText, !correctedText.isEmpty {
            parts.append("已生成 OCR 修正文本")
        }
        if let estimatedMinutes = draft.estimatedMinutes {
            parts.append("预计耗时: \(estimatedMinutes) 分钟")
        }
        if let difficulty = draft.difficulty {
            parts.append("难度: \(difficulty)")
        }
        if let difficultyScore = draft.difficultyScore {
            parts.append("大模型难度分: \(difficultyScore)/10")
        }
        if !draft.plannedSteps.isEmpty {
            parts.append("步骤: \(draft.plannedSteps.joined(separator: " / "))")
        }

        return parts.joined(separator: "\n")
    }
}
