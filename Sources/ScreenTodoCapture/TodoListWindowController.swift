import AppKit
import os

private let todoListLogger = Logger(subsystem: "ScreenTodoCapture", category: "TodoListWindow")

/// 备忘录风格的待办工作台。
///
/// 左侧是轻量列表，右侧是正文阅读区。任务操作收进正文顶部工具条，避免常驻
/// inspector 把界面推向仪表盘风格。
@MainActor
final class TodoListWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate {
    private let store: TodoStore
    private let configStore: AppConfigStore
    private let openSettingsHandler: () -> Void
    private var records: [TodoRecord] = []
    private var isReplanning = false
    private var isUpdatingFilterControls = false

    private let tableView = NSTableView()
    private let sortPopup = NSPopUpButton()
    private let searchField = NSSearchField()
    private let viewPopup = NSPopUpButton()
    private let statusFilterPopup = NSPopUpButton()
    private let timeRangePopup = NSPopUpButton()
    private let tagFilterPopup = NSPopUpButton()
    private let priorityFilterPopup = NSPopUpButton()

    private let titleLabel = NSTextField(labelWithString: "待办详情")
    private let detailMetaStack = NSStackView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let stepsStack = NSStackView()
    private let planMetaLabel = NSTextField(labelWithString: "")
    private let sourceTextModeControl = NSSegmentedControl(
        labels: ["整理文本", "OCR 原文"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let sourceTextView = NSTextView()

    private let statusValueLabel = NSTextField(labelWithString: "-")
    private let dueValueLabel = NSTextField(labelWithString: "-")
    private let difficultyValueLabel = NSTextField(labelWithString: "-")
    private let tagsValueLabel = NSTextField(labelWithString: "-")
    private let priorityValueLabel = NSTextField(labelWithString: "-")
    private let confidenceValueLabel = NSTextField(labelWithString: "-")
    private let reminderValueLabel = NSTextField(labelWithString: "-")
    private let createdValueLabel = NSTextField(labelWithString: "-")
    private let sourceValueLabel = NSTextField(labelWithString: "-")

    private let editButton = NSButton(title: "编辑", target: nil, action: nil)
    private let reminderSyncButton = NSButton(title: "同步提醒", target: nil, action: nil)
    private var pendingReminderSyncCount = 0
    private let replanButton = NSButton(title: "重新规划", target: nil, action: nil)
    private let completeButton = NSButton(title: "标为完成", target: nil, action: nil)
    private let archiveButton = NSButton(title: "归档", target: nil, action: nil)
    private let deleteButton = NSButton(title: "删除", target: nil, action: nil)
    private let openFileButton = NSButton(title: "打开文件", target: nil, action: nil)
    private let openScreenshotButton = NSButton(title: "打开截图", target: nil, action: nil)
    private let settingsButton = NSButton(title: "设置", target: nil, action: nil)
    private let actionStatusLabel = NSTextField(labelWithString: "")

    init(store: TodoStore, configStore: AppConfigStore, openSettingsHandler: @escaping () -> Void) {
        self.store = store
        self.configStore = configStore
        self.openSettingsHandler = openSettingsHandler

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Screen Todo Capture（屏幕待办）"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.center()

        super.init(window: window)
        buildInterface(in: window)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appFontDidChange),
            name: AppFontPreferences.didChangeNotification,
            object: nil
        )
        applyFonts()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAndRefresh() {
        refresh()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refresh() {
        refresh(selecting: selectedRecord()?.fileURL)
    }

    private func refresh(selecting fileURL: URL?) {
        do {
            try store.archiveCompletedOlderThan(days: 3)
            let filterSource = try TodoRecordLoader(store: store, sortMode: .createdDesc).load()
            updateTagFilterOptions(from: filterSource)
            records = try TodoRecordLoader(
                store: store,
                sortMode: currentSortMode(),
                query: currentQuery()
            ).load()
            todoListLogger.info("Todo list refreshed.")
            tableView.reloadData()

            guard !records.isEmpty else {
                clearDetail()
                return
            }

            let selectedRow: Int
            if let fileURL,
               let index = records.firstIndex(where: { $0.fileURL == fileURL }) {
                selectedRow = index
            } else {
                selectedRow = min(max(tableView.selectedRow, 0), records.count - 1)
            }
            tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
            updateDetail()
        } catch {
            showError(error)
        }
    }

    private func buildInterface(in window: NSWindow) {
        let root = NSSplitView()
        root.isVertical = true
        root.dividerStyle = .thin
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(makeListPane())
        root.addArrangedSubview(makeDetailPane())
        window.contentView = root

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)
        ])
    }

    private func makeListPane() -> NSView {
        let container = NSVisualEffectView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.material = .sidebar
        container.blendingMode = .behindWindow
        container.state = .active

        let title = NSTextField(labelWithString: "待办")
        AppFontPreferences.apply(.largeTitle, to: title)

        sortPopup.addItems(withTitles: TodoSortMode.allCases.map(\.rawValue))
        sortPopup.selectItem(withTitle: TodoSortMode.smart.rawValue)
        sortPopup.target = self
        sortPopup.action = #selector(sortModeChanged)
        sortPopup.controlSize = .small

        let refreshButton = NSButton(title: "", target: self, action: #selector(refreshButtonClicked))
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")
        refreshButton.bezelStyle = .texturedRounded
        refreshButton.controlSize = .small
        let header = NSStackView(views: [title, NSView(), sortPopup, refreshButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "搜索"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(filterChanged)

        viewPopup.addItems(withTitles: TodoQuery.View.allCases.map(\.rawValue))
        statusFilterPopup.addItems(withTitles: TodoQuery.Status.allCases.map(\.rawValue))
        timeRangePopup.addItems(withTitles: TodoQuery.TimeRange.allCases.map(\.rawValue))
        priorityFilterPopup.addItems(withTitles: ["全部优先级", "low", "medium", "high", "urgent"])
        tagFilterPopup.addItem(withTitle: "全部标签")
        [viewPopup, statusFilterPopup, timeRangePopup, tagFilterPopup, priorityFilterPopup].forEach {
            $0.target = self
            $0.action = #selector(filterChanged)
            $0.controlSize = .small
        }

        let filterRowOne = NSStackView(views: [viewPopup, statusFilterPopup])
        filterRowOne.orientation = .horizontal
        filterRowOne.spacing = 8
        filterRowOne.distribution = .fillEqually
        let filterRowTwo = NSStackView(views: [timeRangePopup, priorityFilterPopup])
        filterRowTwo.orientation = .horizontal
        filterRowTwo.spacing = 8
        filterRowTwo.distribution = .fillEqually
        let filterStack = NSStackView(views: [searchField, filterRowOne, filterRowTwo, tagFilterPopup])
        filterStack.orientation = .vertical
        filterStack.spacing = 7
        filterStack.translatesAutoresizingMaskIntoConstraints = false

        tableView.addTableColumn(NSTableColumn(identifier: .init("title")))
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = AppFontPreferences.tableRowHeight
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.style = .sourceList

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(header)
        container.addSubview(filterStack)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 330),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            container.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            filterStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            filterStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            filterStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            searchField.widthAnchor.constraint(equalTo: filterStack.widthAnchor),
            tagFilterPopup.widthAnchor.constraint(equalTo: filterStack.widthAnchor),
            scrollView.topAnchor.constraint(equalTo: filterStack.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }

    private func makeDetailPane() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        configureNotesToolbarButtons()

        AppFontPreferences.apply(.largeTitle, to: titleLabel)
        titleLabel.lineBreakMode = .byTruncatingTail

        detailMetaStack.orientation = .horizontal
        detailMetaStack.spacing = 6
        detailMetaStack.alignment = .centerY
        detailMetaStack.distribution = .fill

        AppFontPreferences.apply(.body, to: summaryLabel)
        summaryLabel.textColor = .labelColor
        summaryLabel.maximumNumberOfLines = 0

        AppFontPreferences.apply(.caption, to: planMetaLabel)
        planMetaLabel.textColor = .secondaryLabelColor
        planMetaLabel.maximumNumberOfLines = 2

        AppFontPreferences.apply(.caption, to: actionStatusLabel)
        actionStatusLabel.textColor = .secondaryLabelColor
        actionStatusLabel.maximumNumberOfLines = 2

        stepsStack.orientation = .vertical
        stepsStack.spacing = 6
        stepsStack.alignment = .leading

        setupSourceTextControl()
        setupReadOnlyTextView(sourceTextView)

        let stack = NSStackView(views: [
            titleLabel,
            detailMetaStack,
            actionStatusLabel,
            summaryLabel,
            sectionTitle("计划"),
            stepsStack,
            planMetaLabel,
            makeSourceTextHeader(),
            scrollBox(for: sourceTextView, minHeight: 170)
        ])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        let scroll = NSScrollView()
        scroll.documentView = documentView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = makeNotesToolbar()
        container.addSubview(scroll)
        container.addSubview(toolbar)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 600),
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 52),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 44),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 58),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -58),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor, constant: -36)
        ])

        return container
    }

    private func setupSourceTextControl() {
        sourceTextModeControl.target = self
        sourceTextModeControl.action = #selector(sourceTextModeChanged)
        sourceTextModeControl.selectedSegment = 0
        sourceTextModeControl.controlSize = .small
    }

    private func makeSourceTextHeader() -> NSView {
        let title = sectionTitle("来源文本")
        let stack = NSStackView(views: [title, NSView(), sourceTextModeControl])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func makeNotesToolbar() -> NSView {
        let container = NSVisualEffectView()
        container.material = .headerView
        container.blendingMode = .withinWindow
        container.state = .active
        container.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let primaryStack = NSStackView(views: [completeButton, editButton, replanButton])
        primaryStack.orientation = .horizontal
        primaryStack.spacing = 8
        primaryStack.alignment = .centerY

        let secondaryStack = NSStackView(views: [reminderSyncButton, archiveButton, openFileButton, openScreenshotButton, settingsButton, deleteButton])
        secondaryStack.orientation = .horizontal
        secondaryStack.spacing = 6
        secondaryStack.alignment = .centerY

        let toolbarStack = NSStackView(views: [primaryStack, NSView(), secondaryStack])
        toolbarStack.orientation = .horizontal
        toolbarStack.alignment = .centerY
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(toolbarStack)
        container.addSubview(separator)
        NSLayoutConstraint.activate([
            toolbarStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            toolbarStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            toolbarStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }

    private func configureNotesToolbarButtons() {
        let buttons: [(NSButton, String, String, String?, NSColor)] = [
            (completeButton, "checkmark.circle", "标记完成", nil, NotesTheme.accent),
            (editButton, "square.and.pencil", "编辑", nil, NotesTheme.icon),
            (replanButton, "wand.and.stars", "重新规划", nil, NotesTheme.icon),
            (reminderSyncButton, "arrow.triangle.2.circlepath", "同步到苹果提醒事项 / 重试", "", NotesTheme.icon),
            (archiveButton, "archivebox", "归档", "", NotesTheme.icon),
            (openFileButton, "doc.text", "打开文件", "", NotesTheme.icon),
            (openScreenshotButton, "photo", "打开截图", "", NotesTheme.icon),
            (settingsButton, "gearshape", "设置", "", NotesTheme.icon),
            (deleteButton, "trash", "删除", "", NotesTheme.destructive)
        ]

        editButton.target = self
        editButton.action = #selector(editSelectedTodo)
        replanButton.target = self
        replanButton.action = #selector(replanSelectedTodo)
        completeButton.target = self
        completeButton.action = #selector(toggleSelectedCompletion)
        archiveButton.target = self
        archiveButton.action = #selector(archiveSelectedTodo)
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelectedTodo)
        openFileButton.target = self
        openFileButton.action = #selector(openSelectedFile)
        openScreenshotButton.target = self
        openScreenshotButton.action = #selector(openSelectedScreenshot)
        reminderSyncButton.target = self
        reminderSyncButton.action = #selector(syncSelectedReminder)
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)

        for (button, symbolName, tooltip, titleOverride, tintColor) in buttons {
            if let titleOverride {
                button.title = titleOverride
            }
            button.bezelStyle = .recessed
            button.controlSize = .regular
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.toolTip = tooltip
            button.contentTintColor = tintColor
            button.setAccessibilityLabel(tooltip)
            if titleOverride == "" {
                button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            }
        }
        deleteButton.hasDestructiveAction = true
        completeButton.keyEquivalent = "\r"
    }

    private func makeSidePane() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        editButton.target = self
        editButton.action = #selector(editSelectedTodo)
        replanButton.target = self
        replanButton.action = #selector(replanSelectedTodo)
        completeButton.target = self
        completeButton.action = #selector(toggleSelectedCompletion)
        archiveButton.target = self
        archiveButton.action = #selector(archiveSelectedTodo)
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelectedTodo)
        openFileButton.target = self
        openFileButton.action = #selector(openSelectedFile)
        openScreenshotButton.target = self
        openScreenshotButton.action = #selector(openSelectedScreenshot)
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        configureInspectorButtons()
        [statusValueLabel, dueValueLabel, difficultyValueLabel, priorityValueLabel, confidenceValueLabel, tagsValueLabel, reminderValueLabel, createdValueLabel, sourceValueLabel].forEach {
            $0.maximumNumberOfLines = 4
            $0.lineBreakMode = .byWordWrapping
        }
        actionStatusLabel.maximumNumberOfLines = 4
        actionStatusLabel.textColor = .secondaryLabelColor
        AppFontPreferences.apply(.caption, to: actionStatusLabel)

        let stateGroup = inspectorGroup(
            title: "状态信息",
            views: [
                inspectorField("状态", value: statusValueLabel),
                inspectorField("截止", value: dueValueLabel),
                inspectorField("难度", value: difficultyValueLabel),
                inspectorField("优先级", value: priorityValueLabel),
                inspectorField("置信度", value: confidenceValueLabel),
                inspectorField("标签", value: tagsValueLabel),
                inspectorField("提醒", value: reminderValueLabel),
                inspectorField("创建", value: createdValueLabel),
                inspectorField("来源", value: sourceValueLabel)
            ]
        )
        let taskActionsGroup = inspectorGroup(
            title: "任务操作",
            views: [completeButton, editButton, replanButton, archiveButton, deleteButton, actionStatusLabel]
        )
        let resourceGroup = inspectorGroup(title: "资源", views: [openFileButton, openScreenshotButton])
        let preferenceGroup = inspectorGroup(title: "偏好", views: [settingsButton])

        let stack = NSStackView(views: [stateGroup, taskActionsGroup, resourceGroup, preferenceGroup])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        let scroll = NSScrollView()
        scroll.documentView = documentView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 260),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor, constant: -18),
            stateGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            taskActionsGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resourceGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preferenceGroup.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        return container
    }

    private func configureInspectorButtons() {
        let buttonConfigurations: [(NSButton, String)] = [
            (completeButton, "checkmark.circle.fill"),
            (editButton, "pencil"),
            (replanButton, "arrow.triangle.2.circlepath"),
            (archiveButton, "archivebox"),
            (deleteButton, "trash"),
            (openFileButton, "doc.text"),
            (openScreenshotButton, "photo"),
            (settingsButton, "gearshape")
        ]

        for (button, symbolName) in buttonConfigurations {
            button.bezelStyle = .rounded
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: button.title)
            button.imagePosition = .imageLeading
            button.alignment = .left
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        }
        deleteButton.hasDestructiveAction = true
    }

    private func inspectorGroup(title: String, views: [NSView]) -> NSView {
        let titleLabel = sectionTitle(title)
        titleLabel.textColor = .labelColor

        let content = NSStackView(views: views)
        content.orientation = .vertical
        content.spacing = 8
        content.alignment = .leading

        let stack = NSStackView(views: [titleLabel, content])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        views.forEach { view in
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        }

        return stack
    }

    private func inspectorField(_ title: String, value valueLabel: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: title)
        AppFontPreferences.apply(.captionSemibold, to: label)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 42).isActive = true

        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [label, valueLabel])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .firstBaseline
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func setupReadOnlyTextView(_ textView: NSTextView) {
        textView.isEditable = false
        textView.isRichText = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        AppFontPreferences.apply(.monospace, to: textView)
        textView.textContainerInset = NSSize(width: 0, height: 6)
    }

    private func scrollBox(for textView: NSTextView, minHeight: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight).isActive = true
        return scroll
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        AppFontPreferences.apply(.captionSemibold, to: field)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        records.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("TodoCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TodoListCellView
            ?? TodoListCellView()

        let record = records[row]
        cell.identifier = identifier
        cell.configure(record: record)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetail()
    }

    private func updateDetail() {
        guard let record = selectedRecord() else {
            clearDetail()
            return
        }

        titleLabel.stringValue = record.title
        summaryLabel.stringValue = record.summary ?? "暂无摘要。启用大模型后会生成任务摘要。"
        planMetaLabel.stringValue = planMeta(for: record)
        updateDetailMeta(for: record)
        updateSourceText(for: record)

        stepsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let steps = record.plannedSteps.isEmpty ? ["暂无执行步骤。启用大模型后会生成任务规划。"] : record.plannedSteps
        for (index, step) in steps.enumerated() {
            stepsStack.addArrangedSubview(makeStepRow(index: index, text: step))
        }

        statusValueLabel.stringValue = record.status
        dueValueLabel.stringValue = record.dueDateText ?? record.dueHint ?? "未设置"
        difficultyValueLabel.stringValue = record.difficultyScore.map { "\($0)/10" } ?? "未评估"
        priorityValueLabel.stringValue = TodoPriority.display(record.priority)
        confidenceValueLabel.stringValue = record.confidence.map { String(format: "%.2f", $0) } ?? "未评估"
        tagsValueLabel.stringValue = record.tags.isEmpty ? "未标记" : record.tags.joined(separator: ", ")
        reminderValueLabel.stringValue = ReminderSyncStatus.display(record.reminderSyncStatus)
        createdValueLabel.stringValue = record.createdAtText
        sourceValueLabel.stringValue = record.sourceApplication

        completeButton.title = record.status == "已完成" ? "恢复待处理" : "标为完成"
        setActionsEnabled(true)
        openScreenshotButton.isEnabled = record.screenshotURL != nil
    }

    private func planMeta(for record: TodoRecord) -> String {
        var parts: [String] = []
        if let estimatedMinutes = record.estimatedMinutes {
            parts.append("预计 \(estimatedMinutes)")
        }
        if let difficultyScore = record.difficultyScore {
            parts.append("难度 \(difficultyScore)/10")
        }
        if let confidence = record.confidence {
            parts.append("置信度: \(String(format: "%.2f", confidence))")
        }
        if !record.planHistories.isEmpty {
            parts.append("历史版本: \(record.planHistories.count)")
        }
        return parts.isEmpty ? "暂无规划信息。" : parts.joined(separator: " · ")
    }

    private func clearDetail() {
        titleLabel.stringValue = "待办详情"
        summaryLabel.stringValue = currentQuery().isDefault
            ? "暂无待办。可以从剪贴板截图或框选截图创建一个待办。"
            : "没有符合当前搜索和过滤条件的待办。"
        planMetaLabel.stringValue = ""
        detailMetaStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        sourceTextView.string = ""
        stepsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        statusValueLabel.stringValue = "-"
        dueValueLabel.stringValue = "-"
        difficultyValueLabel.stringValue = "-"
        priorityValueLabel.stringValue = "-"
        confidenceValueLabel.stringValue = "-"
        tagsValueLabel.stringValue = "-"
        reminderValueLabel.stringValue = "-"
        createdValueLabel.stringValue = "-"
        sourceValueLabel.stringValue = "-"
        setActionMessage("")
        setActionsEnabled(false)
    }

    private func updateSourceText(for record: TodoRecord) {
        let correctedText = record.correctedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalText = record.originalText?.trimmingCharacters(in: .whitespacesAndNewlines)

        if sourceTextModeControl.selectedSegment == 0,
           correctedText?.isEmpty != false,
           originalText?.isEmpty == false {
            sourceTextModeControl.selectedSegment = 1
        }
        if sourceTextModeControl.selectedSegment == 1,
           originalText?.isEmpty != false,
           correctedText?.isEmpty == false {
            sourceTextModeControl.selectedSegment = 0
        }

        if sourceTextModeControl.selectedSegment == 0 {
            sourceTextView.string = correctedText?.isEmpty == false
                ? correctedText!
                : "暂无整理文本。"
        } else {
            sourceTextView.string = originalText?.isEmpty == false
                ? originalText!
                : "暂无 OCR 原文。"
        }
    }

    private func setActionsEnabled(_ enabled: Bool) {
        reminderSyncButton.isEnabled = enabled && pendingReminderSyncCount == 0
        editButton.isEnabled = enabled
        replanButton.isEnabled = enabled && !isReplanning
        completeButton.isEnabled = enabled
        archiveButton.isEnabled = enabled
        deleteButton.isEnabled = enabled
        openFileButton.isEnabled = enabled
        openScreenshotButton.isEnabled = enabled
    }

    private func updateDetailMeta(for record: TodoRecord) {
        detailMetaStack.arrangedSubviews.forEach { view in
            detailMetaStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let field = NSTextField(labelWithString: TodoVisuals.detailMetaLine(for: record))
        AppFontPreferences.apply(.caption, to: field)
        field.textColor = .secondaryLabelColor
        field.maximumNumberOfLines = 2
        field.lineBreakMode = .byWordWrapping
        detailMetaStack.addArrangedSubview(field)
    }

    private func makeStepRow(index: Int, text: String) -> NSView {
        let numberLabel = NSTextField(labelWithString: "\(index + 1)")
        AppFontPreferences.apply(.captionSemibold, to: numberLabel)
        numberLabel.alignment = .center
        numberLabel.textColor = .secondaryLabelColor
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        numberLabel.widthAnchor.constraint(equalToConstant: 24).isActive = true

        let label = NSTextField(labelWithString: text)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        AppFontPreferences.apply(.body, to: label)

        let row = NSStackView(views: [numberLabel, label])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .firstBaseline
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    @objc private func refreshButtonClicked() {
        refresh()
    }

    @objc private func sortModeChanged() {
        refresh()
    }

    @objc private func filterChanged() {
        guard !isUpdatingFilterControls else {
            return
        }
        refresh(selecting: nil)
    }

    @objc private func sourceTextModeChanged() {
        guard let record = selectedRecord() else {
            return
        }
        updateSourceText(for: record)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else {
            return
        }
        refresh(selecting: nil)
    }

    @objc private func editSelectedTodo() {
        guard var record = selectedRecord(),
              let edited = TodoEditDialog().edit(record: record) else {
            return
        }

        record.content = edited
        do {
            try store.update(record: record)
            refresh()
            syncReminderIfNeeded(fileURL: record.fileURL)
        } catch {
            showError(error)
        }
    }

    @objc private func syncSelectedReminder() {
        guard ReminderSyncPreferences.isEnabled else {
            setActionMessage("请先在设置中开启苹果提醒事项同步并授权。", isError: true)
            return
        }
        guard let record = selectedRecord() else { return }
        syncReminderIfNeeded(fileURL: record.fileURL)
    }

    /// 新建、编辑、完成和重规划共用同一同步服务；手动入口用于补同步及失败重试。
    private func syncReminderIfNeeded(fileURL: URL) {
        guard ReminderSyncPreferences.isEnabled else { return }
        pendingReminderSyncCount += 1
        reminderSyncButton.isEnabled = false
        setActionMessage("正在同步苹果提醒事项…", isError: false)
        Task { [weak self, fileURL] in
            guard let self else { return }
            defer {
                pendingReminderSyncCount -= 1
                reminderSyncButton.isEnabled = selectedRecord() != nil && pendingReminderSyncCount == 0
            }
            do {
                guard let metadata = try await ReminderSyncService.shared.syncTodo(fileURL: fileURL, store: store) else { return }
                setActionMessage(
                    metadata.status == .synced ? "苹果提醒事项已同步。"
                        : "同步失败：\(metadata.message ?? ReminderSyncStatus.display(metadata.status.rawValue))",
                    isError: metadata.status != .synced
                )
                refresh(selecting: selectedRecord()?.fileURL)
            } catch {
                todoListLogger.error("Reminder metadata persistence failed: \(error.localizedDescription, privacy: .public)")
                setActionMessage("提醒事项同步状态写回失败：\(error.localizedDescription)", isError: true)
            }
        }
    }

    @objc private func replanSelectedTodo() {
        guard let record = selectedRecord() else {
            return
        }

        guard let config = configStore.loadLLMConfig() else {
            setActionMessage("请先在设置 -> 大模型管理中启用大模型并填写 API Key、Base URL 和模型名称。", isError: true)
            return
        }

        isReplanning = true
        replanButton.title = "规划中..."
        setActionsEnabled(false)
        setActionMessage("正在调用 LLM（大语言模型）重新规划当前待办...", isError: false)

        let fileURL = record.fileURL
        Task { [weak self, record, config, fileURL] in
            guard let self else {
                return
            }

            do {
                let draft = try await LLMTaskPlanner(config: config).replan(record: record)
                try store.replacePlan(record: record, with: draft)
                isReplanning = false
                replanButton.title = "重新规划"
                setActionMessage("重新规划已完成，旧规划已写入历史。", isError: false)
                refresh(selecting: fileURL)
                syncReminderIfNeeded(fileURL: fileURL)
            } catch {
                isReplanning = false
                replanButton.title = "重新规划"
                setActionsEnabled(selectedRecord() != nil)
                setActionMessage("重新规划失败，原待办未被修改：\(error.localizedDescription)", isError: true)
            }
        }
    }

    @objc private func toggleSelectedCompletion() {
        guard var record = selectedRecord() else {
            return
        }

        if record.status == "已完成" {
            record.content = TodoMarkdownEditor.setMetadata("状态", value: "待处理", in: record.content)
            record.content = TodoMarkdownEditor.setMetadata("完成时间", value: nil, in: record.content)
        } else {
            record.content = TodoMarkdownEditor.setMetadata("状态", value: "已完成", in: record.content)
            record.content = TodoMarkdownEditor.setMetadata("完成时间", value: Self.isoString(Date()), in: record.content)
        }

        do {
            try store.update(record: record)
            refresh()
            syncReminderIfNeeded(fileURL: record.fileURL)
        } catch {
            showError(error)
        }
    }

    @objc private func archiveSelectedTodo() {
        guard let record = selectedRecord(),
              confirm(title: "归档待办", message: "归档后会从当前列表移除，但 Markdown 文件会保留在 Archive 目录。") else {
            return
        }

        do {
            try store.archive(record: record)
            refresh()
        } catch {
            showError(error)
        }
    }

    @objc private func deleteSelectedTodo() {
        guard let record = selectedRecord(),
              confirm(title: "删除待办", message: "这会删除待办 Markdown 和对应截图。此操作不可撤销。") else {
            return
        }

        do {
            try store.delete(record: record)
            refresh()
        } catch {
            showError(error)
        }
    }

    @objc private func openSelectedFile() {
        guard let record = selectedRecord() else { return }
        NSWorkspace.shared.open(record.fileURL)
    }

    @objc private func openSelectedScreenshot() {
        guard let screenshotURL = selectedRecord()?.screenshotURL else { return }
        NSWorkspace.shared.open(screenshotURL)
    }

    @objc private func openSettings() {
        openSettingsHandler()
    }

    @objc private func appFontDidChange() {
        applyFonts()
    }

    private func selectedRecord() -> TodoRecord? {
        guard tableView.selectedRow >= 0, tableView.selectedRow < records.count else {
            return nil
        }
        return records[tableView.selectedRow]
    }

    private func currentSortMode() -> TodoSortMode {
        let selectedTitle = sortPopup.selectedItem?.title ?? TodoSortMode.smart.rawValue
        return TodoSortMode(rawValue: selectedTitle) ?? .smart
    }

    private func currentQuery() -> TodoQuery {
        let tagTitle = tagFilterPopup.selectedItem?.title ?? "全部标签"
        let priorityTitle = priorityFilterPopup.selectedItem?.title ?? "全部优先级"
        return TodoQuery(
            searchText: searchField.stringValue,
            status: TodoQuery.Status(rawValue: statusFilterPopup.selectedItem?.title ?? "") ?? .all,
            tag: tagTitle == "全部标签" ? nil : tagTitle,
            priority: priorityTitle == "全部优先级" ? nil : priorityTitle,
            timeRange: TodoQuery.TimeRange(rawValue: timeRangePopup.selectedItem?.title ?? "") ?? .all,
            view: TodoQuery.View(rawValue: viewPopup.selectedItem?.title ?? "") ?? .all
        )
    }

    private func updateTagFilterOptions(from records: [TodoRecord]) {
        let selected = tagFilterPopup.selectedItem?.title ?? "全部标签"
        let tags = Array(Set(records.flatMap(\.tags))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }

        isUpdatingFilterControls = true
        tagFilterPopup.removeAllItems()
        tagFilterPopup.addItem(withTitle: "全部标签")
        tagFilterPopup.addItems(withTitles: tags)
        if tags.contains(selected) {
            tagFilterPopup.selectItem(withTitle: selected)
        } else {
            tagFilterPopup.selectItem(withTitle: "全部标签")
        }
        isUpdatingFilterControls = false
    }

    private func confirm(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确认")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func setActionMessage(_ message: String, isError: Bool = false) {
        actionStatusLabel.stringValue = message
        actionStatusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    private func applyFonts() {
        guard let contentView = window?.contentView else {
            return
        }

        tableView.rowHeight = AppFontPreferences.tableRowHeight
        AppFontPreferences.applyFontsRecursively(to: contentView)
        tableView.reloadData()
        updateDetail()
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}

/// Notes-like color language for the AppKit UI.
///
/// The app uses a restrained gray scale with a single warm accent, matching the
/// feel of Apple Notes more closely than the default blue-heavy control tint.
@MainActor
private enum NotesTheme {
    static var accent: NSColor {
        NSColor.systemYellow
    }

    static var icon: NSColor {
        NSColor.secondaryLabelColor
    }

    static var destructive: NSColor {
        NSColor.systemRed
    }

    static var pendingDot: NSColor {
        NSColor.systemYellow
    }

    static var quietDot: NSColor {
        NSColor.tertiaryLabelColor
    }
}

/// 列表 row 的复合视图。
///
/// 输入是一条 `TodoRecord`；输出是一个可复用的 AppKit cell，把标题、摘要和四个
/// 高价值扫描维度压缩到一行视觉层级里，避免列表只靠长文本区分任务。
@MainActor
private final class TodoListCellView: NSTableCellView {
    private let priorityStrip = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(record: TodoRecord) {
        titleLabel.stringValue = record.title
        subtitleLabel.stringValue = TodoVisuals.subtitle(for: record)
        metaLabel.stringValue = TodoVisuals.listMetaLine(for: record)
        priorityStrip.layer?.backgroundColor = TodoVisuals.listDotColor(for: record).cgColor
    }

    private func buildLayout() {
        wantsLayer = true

        priorityStrip.wantsLayer = true
        priorityStrip.layer?.cornerRadius = 3.5
        priorityStrip.translatesAutoresizingMaskIntoConstraints = false

        AppFontPreferences.apply(.bodySemibold, to: titleLabel)
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail

        AppFontPreferences.apply(.caption, to: subtitleLabel)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail

        AppFontPreferences.apply(.caption, to: metaLabel)
        metaLabel.textColor = .tertiaryLabelColor
        metaLabel.maximumNumberOfLines = 1
        metaLabel.lineBreakMode = .byTruncatingTail

        let contentStack = NSStackView(views: [titleLabel, subtitleLabel, metaLabel])
        contentStack.orientation = .vertical
        contentStack.spacing = 4
        contentStack.alignment = .leading
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(priorityStrip)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            priorityStrip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            priorityStrip.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            priorityStrip.widthAnchor.constraint(equalToConstant: 7),
            priorityStrip.heightAnchor.constraint(equalToConstant: 7),

            contentStack.leadingAnchor.constraint(equalTo: priorityStrip.trailingAnchor, constant: 11),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: contentStack.widthAnchor),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualTo: contentStack.widthAnchor),
            metaLabel.widthAnchor.constraint(lessThanOrEqualTo: contentStack.widthAnchor)
        ])
    }
}

/// 小型元信息胶囊。
///
/// 依赖调用方传入文案和强调色；内部负责字体、边距和浅色背景，供列表 row 与详情页
/// 共用，确保同一状态在不同区域有一致的视觉编码。
@MainActor
private final class TodoBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, color: NSColor) {
        label.stringValue = text
        label.textColor = color
        layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
        layer?.borderColor = color.withAlphaComponent(0.28).cgColor
    }

    private func buildLayout() {
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1

        AppFontPreferences.apply(.captionSemibold, to: label)
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])
    }
}

/// 待办展示层的文案压缩和颜色规则。
///
/// 这里不改变数据模型，只把记录中的状态、优先级、截止时间和难度映射成稳定、
/// 可扫描的 UI 表示，供列表和详情区共同调用。
@MainActor
private enum TodoVisuals {
    static func subtitle(for record: TodoRecord) -> String {
        if let summary = record.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return summary
        }
        if let originalText = record.originalText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !originalText.isEmpty {
            return originalText
                .components(separatedBy: .newlines)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? record.displaySubtitle
        }
        return record.displaySubtitle
    }

    static func listMetaLine(for record: TodoRecord) -> String {
        [
            record.status,
            compactDueText(for: record),
            record.sourceApplication
        ]
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: "  ·  ")
    }

    static func detailMetaLine(for record: TodoRecord) -> String {
        var parts = [
            record.status,
            record.sourceApplication,
            compactDueText(for: record)
        ]
        if let priority = record.priority {
            parts.append("优先级 \(TodoPriority.display(priority))")
        }
        if let difficultyScore = record.difficultyScore {
            parts.append("难度 \(difficultyScore)/10")
        }
        if !record.tags.isEmpty {
            parts.append(record.tags.prefix(3).joined(separator: "、"))
        }
        if let syncStatus = record.reminderSyncStatus {
            parts.append("提醒事项 \(ReminderSyncStatus.display(syncStatus))")
        }
        return parts.joined(separator: "  ·  ")
    }

    static func statusColor(for status: String) -> NSColor {
        switch status {
        case "已完成":
            return .systemGreen
        case "已归档":
            return NotesTheme.quietDot
        default:
            return NotesTheme.pendingDot
        }
    }

    static func priorityColor(for priority: String?) -> NSColor {
        switch TodoPriority.normalize(priority) {
        case "urgent":
            return NSColor.systemRed
        case "high":
            return NSColor.systemOrange
        case "medium":
            return NotesTheme.accent
        case "low":
            return NSColor.systemGreen
        default:
            return NotesTheme.quietDot
        }
    }

    static func listDotColor(for record: TodoRecord) -> NSColor {
        if record.status == "已完成" {
            return NSColor.systemGreen.withAlphaComponent(0.72)
        }
        switch TodoPriority.normalize(record.priority) {
        case "urgent":
            return NSColor.systemRed.withAlphaComponent(0.78)
        case "high":
            return NSColor.systemOrange.withAlphaComponent(0.78)
        case "medium", "low":
            return NotesTheme.accent.withAlphaComponent(0.82)
        default:
            return NotesTheme.quietDot
        }
    }

    static func dueBadgeText(for record: TodoRecord) -> String {
        "截止 \(compactDueText(for: record))"
    }

    static func dueColor(for record: TodoRecord) -> NSColor {
        guard record.status != "已完成",
              let dueDate = record.dueDate else {
            return .secondaryLabelColor
        }

        let calendar = Calendar.current
        if dueDate < Date() {
            return .systemRed
        }
        if calendar.isDateInToday(dueDate) {
            return .systemOrange
        }
        if calendar.isDateInTomorrow(dueDate) {
            return .systemBlue
        }
        return .systemTeal
    }

    static func difficultyBadgeText(for record: TodoRecord) -> String {
        if let difficultyScore = record.difficultyScore {
            return "难度 \(difficultyScore)"
        }
        if let difficulty = record.difficulty?.trimmingCharacters(in: .whitespacesAndNewlines),
           !difficulty.isEmpty {
            return "难度 \(difficulty)"
        }
        return "难度 未评估"
    }

    static func difficultyColor(for record: TodoRecord) -> NSColor {
        guard let score = record.difficultyScore else {
            return .secondaryLabelColor
        }
        if score >= 8 {
            return .systemRed
        }
        if score >= 5 {
            return .systemOrange
        }
        return .systemGreen
    }

    private static func compactDueText(for record: TodoRecord) -> String {
        guard let dueDate = record.dueDate else {
            if let dueDateText = record.dueDateText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !dueDateText.isEmpty {
                return dueDateText
            }
            if let dueHint = record.dueHint?.trimmingCharacters(in: .whitespacesAndNewlines),
               !dueHint.isEmpty {
                return dueHint
            }
            return "未设置"
        }

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "zh_CN")
        timeFormatter.dateFormat = "HH:mm"

        let calendar = Calendar.current
        if calendar.isDateInToday(dueDate) {
            return "今天 \(timeFormatter.string(from: dueDate))"
        }
        if calendar.isDateInTomorrow(dueDate) {
            return "明天 \(timeFormatter.string(from: dueDate))"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: dueDate)
    }
}

@MainActor
struct TodoEditDialog {
    func edit(record: TodoRecord) -> String? {
        let alert = NSAlert()
        alert.messageText = "编辑待办"
        alert.informativeText = "可以修改标题、状态、截止时间和 Markdown 详情。难度分由大模型评估。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let titleField = NSTextField(string: record.title)
        let statusPopup = NSPopUpButton()
        statusPopup.addItems(withTitles: ["待处理", "已完成"])
        statusPopup.selectItem(withTitle: record.status)

        let dueDateControls = DueDateControls(initialDate: record.dueDate)
        let difficultyLabel = NSTextField(labelWithString: record.difficultyScore.map { "大模型难度分: \($0)/10" } ?? "大模型难度分: 未评估")
        difficultyLabel.textColor = .secondaryLabelColor

        let contentView = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        contentView.string = record.content
        AppFontPreferences.apply(.monospace, to: contentView)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        scrollView.hasVerticalScroller = true
        scrollView.documentView = contentView

        let stack = NSStackView(views: [
            label("标题"),
            titleField,
            label("状态"),
            statusPopup,
            label("截止时间"),
            dueDateControls.stackView,
            label("难度分"),
            difficultyLabel,
            label("详情 Markdown"),
            scrollView
        ])
        stack.orientation = .vertical
        stack.spacing = 7
        stack.alignment = .leading
        stack.setFrameSize(NSSize(width: 640, height: 470))
        AppFontPreferences.applyFontsRecursively(to: stack)

        titleField.widthAnchor.constraint(equalToConstant: 640).isActive = true
        scrollView.widthAnchor.constraint(equalToConstant: 640).isActive = true
        scrollView.heightAnchor.constraint(equalToConstant: 300).isActive = true

        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        var content = contentView.string
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            content = TodoMarkdownEditor.setTitle(title, in: content)
        }

        let oldStatus = record.status
        let newStatus = statusPopup.selectedItem?.title ?? "待处理"
        content = TodoMarkdownEditor.setMetadata("状态", value: newStatus, in: content)
        if newStatus == "已完成", oldStatus != "已完成" {
            content = TodoMarkdownEditor.setMetadata("完成时间", value: isoString(Date()), in: content)
        } else if newStatus != "已完成" {
            content = TodoMarkdownEditor.setMetadata("完成时间", value: nil, in: content)
        }

        content = TodoMarkdownEditor.setMetadata("截止时间", value: dueDateControls.isoString, in: content)
        return content
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        AppFontPreferences.apply(.captionSemibold, to: field)
        return field
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
