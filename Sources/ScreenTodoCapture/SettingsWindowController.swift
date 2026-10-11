import AppKit

/// 通用应用设置窗口。
///
/// 目前先把 LLM（大语言模型）管理放在这里；后续可以继续扩展快捷键、存储、
/// 隐私确认等设置项。
@MainActor
final class SettingsWindowController: NSWindowController {
    private let configStore: AppConfigStore

    private let enabledButton = NSButton(checkboxWithTitle: "启用大模型增强", target: nil, action: nil)
    private let baseURLField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let modelField = NSTextField()
    private let promptTextView = NSTextView()
    private let testConnectionButton = NSButton(title: "测试连接", target: nil, action: nil)
    private let connectionStatusLabel = NSTextField(labelWithString: "尚未测试连接。")
    private let fontSizeSlider = NSSlider()
    private let fontSizeValueLabel = NSTextField(labelWithString: "")
    private let reminderSyncButton = NSButton(
        checkboxWithTitle: "同步到 Apple Reminders（苹果提醒事项）",
        target: nil,
        action: nil
    )

    init(configStore: AppConfigStore) {
        self.configStore = configStore

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.center()

        super.init(window: window)
        buildInterface(in: window)
        load()
        applyFonts()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        load()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildInterface(in window: NSWindow) {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = container

        let sidebar = makeSidebar()
        let content = makeLLMManagementPane()
        container.addSubview(sidebar)
        container.addSubview(content)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: container.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 190),

            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    private func makeSidebar() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.72).cgColor

        let title = NSTextField(labelWithString: "设置")

        let llmItem = NSTextField(labelWithString: "大模型管理")
        llmItem.textColor = .controlAccentColor

        let hint = NSTextField(labelWithString: "LLM\n大语言模型")
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 2

        let stack = NSStackView(views: [title, llmItem, hint])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        AppFontPreferences.apply(.title, to: title)
        AppFontPreferences.apply(.bodySemibold, to: llmItem)
        AppFontPreferences.apply(.caption, to: hint)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18)
        ])

        return container
    }

    private func makeLLMManagementPane() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "大模型管理")
        AppFontPreferences.apply(.largeTitle, to: title)

        let description = helperText("启用后，应用会把 OCR（光学字符识别）文本发送给你配置的 OpenAI-compatible（兼容 OpenAI 格式）接口，用于总结标题、修正文本、生成步骤、估算耗时和难度分。", role: .body)

        baseURLField.placeholderString = "https://api.openai.com/v1/chat/completions"
        apiKeyField.placeholderString = "API Key（接口密钥）"
        modelField.placeholderString = "Model（模型名称），例如 gpt-4o-mini"

        AppFontPreferences.apply(.monospace, to: promptTextView)
        promptTextView.isRichText = false
        promptTextView.textContainerInset = NSSize(width: 10, height: 10)

        let promptScroll = NSScrollView()
        promptScroll.documentView = promptTextView
        promptScroll.hasVerticalScroller = true
        promptScroll.translatesAutoresizingMaskIntoConstraints = false

        let promptHelp = helperText("Task Planning System Prompt（任务规划系统提示词）会作为 system message（系统消息）发送给模型。你可以在这里规定标题风格、步骤粒度、难度评分规则和保守推断边界。", role: .caption)

        let saveButton = NSButton(title: "保存设置", target: self, action: #selector(save))
        let resetButton = NSButton(title: "恢复默认规划提示词", target: self, action: #selector(resetPrompt))
        let openConfigButton = NSButton(title: "打开配置文件", target: self, action: #selector(openConfigFile))
        testConnectionButton.target = self
        testConnectionButton.action = #selector(testConnection)

        connectionStatusLabel.textColor = .secondaryLabelColor
        connectionStatusLabel.maximumNumberOfLines = 2
        AppFontPreferences.apply(.caption, to: connectionStatusLabel)

        let buttonStack = NSStackView(views: [saveButton, resetButton, openConfigButton, testConnectionButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        fontSizeSlider.minValue = AppFontPreferences.minimumSize
        fontSizeSlider.maxValue = AppFontPreferences.maximumSize
        fontSizeSlider.numberOfTickMarks = Int(AppFontPreferences.maximumSize - AppFontPreferences.minimumSize + 1)
        fontSizeSlider.allowsTickMarkValuesOnly = true
        fontSizeSlider.target = self
        fontSizeSlider.action = #selector(fontSizeChanged)
        fontSizeSlider.translatesAutoresizingMaskIntoConstraints = false
        fontSizeSlider.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let fontSizeTitle = NSTextField(labelWithString: "界面字号")
        AppFontPreferences.apply(.bodySemibold, to: fontSizeTitle)
        AppFontPreferences.apply(.body, to: fontSizeValueLabel)

        let fontSizeRow = NSStackView(views: [fontSizeTitle, fontSizeSlider, fontSizeValueLabel])
        fontSizeRow.orientation = .horizontal
        fontSizeRow.spacing = 10
        fontSizeRow.alignment = .centerY

        let reminderHelp = helperText("开启后，新建待办会单向创建 Apple Reminders（苹果提醒事项）；本地完成/恢复会同步状态。删除或归档本地待办不会删除系统提醒事项。", role: .caption)
        reminderSyncButton.target = self
        reminderSyncButton.action = #selector(reminderSyncChanged)

        let llmSection = settingsSection(
            title: "LLM 连接",
            views: [
                enabledButton,
                formField(title: "Base URL（接口地址）", control: baseURLField),
                formField(title: "API Key（接口密钥）", control: apiKeyField),
                formField(title: "Model（模型名称）", control: modelField),
                formField(title: "Task Planning Prompt（任务规划提示词）", control: promptScroll, helper: promptHelp),
                buttonStack,
                connectionStatusLabel
            ]
        )
        let displaySection = settingsSection(title: "显示", views: [fontSizeRow])
        let integrationSection = settingsSection(
            title: "系统集成",
            views: [reminderSyncButton, reminderHelp]
        )

        let stack = NSStackView(views: [title, description, llmSection, displaySection, integrationSection])
        stack.orientation = .vertical
        stack.spacing = 18
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = SettingsFlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        let scrollView = NSScrollView()
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),

            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor, constant: -22),
            description.widthAnchor.constraint(equalTo: stack.widthAnchor),
            llmSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            displaySection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            integrationSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            promptScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])

        return container
    }

    private func load() {
        do {
            let configuration = try configStore.loadConfiguration()
            let llm = configuration.llm ?? LLMConfig(
                enabled: false,
                baseURL: URL(string: "https://api.openai.com/v1/chat/completions")!,
                apiKey: "",
                model: "gpt-4o-mini",
                systemPrompt: configStore.defaultSystemPrompt
            )

            enabledButton.state = llm.enabled ? .on : .off
            baseURLField.stringValue = llm.baseURL.absoluteString
            apiKeyField.stringValue = llm.apiKey
            modelField.stringValue = llm.model
            promptTextView.string = llm.systemPrompt
            fontSizeSlider.doubleValue = Double(AppFontPreferences.size)
            reminderSyncButton.state = ReminderSyncPreferences.isEnabled ? .on : .off
            resetConnectionStatus()
            updateFontSizeValueLabel()
        } catch {
            showError(error)
        }
    }

    @objc private func save() {
        guard let baseURL = URL(string: baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            showError(SettingsError.invalidURL)
            return
        }

        let config = AppConfiguration(
            llm: LLMConfig(
                enabled: enabledButton.state == .on,
                baseURL: baseURL,
                apiKey: apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                model: modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                systemPrompt: promptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? configStore.defaultSystemPrompt
                    : promptTextView.string
            )
        )

        do {
            try configStore.saveConfiguration(config)
            showMessage("设置已保存")
        } catch {
            showError(error)
        }
    }

    @objc private func resetPrompt() {
        promptTextView.string = configStore.defaultSystemPrompt
    }

    @objc private func openConfigFile() {
        NSWorkspace.shared.open(configStore.configURL)
    }

    @objc private func testConnection() {
        guard let config = makeTestConfiguration() else {
            return
        }

        testConnectionButton.isEnabled = false
        testConnectionButton.title = "测试中..."
        setConnectionStatus("正在测试大模型连接...", isError: false)

        Task { [weak self, config] in
            do {
                try await LLMConnectionTester(config: config).test()
                await MainActor.run {
                    self?.testConnectionButton.isEnabled = true
                    self?.testConnectionButton.title = "测试连接"
                    self?.setConnectionStatus("连接成功。当前 Base URL、API Key 和 Model 可用。", isError: false)
                }
            } catch {
                await MainActor.run {
                    self?.testConnectionButton.isEnabled = true
                    self?.testConnectionButton.title = "测试连接"
                    self?.setConnectionStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    @objc private func fontSizeChanged() {
        let rounded = round(fontSizeSlider.doubleValue)
        fontSizeSlider.doubleValue = rounded
        AppFontPreferences.size = CGFloat(rounded)
        updateFontSizeValueLabel()
        applyFonts()
    }

    @objc private func reminderSyncChanged() {
        ReminderSyncPreferences.isEnabled = reminderSyncButton.state == .on
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        AppFontPreferences.apply(.captionSemibold, to: field)
        return field
    }

    /// 设置页的分区容器。
    ///
    /// 输入是一组已配置的 AppKit 控件；输出是带标题、内部分隔和统一宽度约束的
    /// 纵向区域，用来把 LLM、显示和系统集成从一条长表单拆成可维护的模块。
    private func settingsSection(title: String, views: [NSView]) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        AppFontPreferences.apply(.title, to: titleLabel)

        let separator = NSBox()
        separator.boxType = .separator

        let content = NSStackView(views: views)
        content.orientation = .vertical
        content.spacing = 10
        content.alignment = .leading

        let stack = NSStackView(views: [titleLabel, separator, content])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        content.translatesAutoresizingMaskIntoConstraints = false
        separator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            content.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        views.forEach { view in
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }

        return stack
    }

    private func formField(title: String, control: NSView, helper: NSTextField? = nil) -> NSView {
        let titleLabel = label(title)
        var views: [NSView] = [titleLabel]
        if let helper {
            views.append(helper)
        }
        views.append(control)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = 5
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        helper?.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return stack
    }

    private func helperText(_ text: String, role: AppFontRole) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        AppFontPreferences.apply(role, to: field)
        return field
    }

    private func makeTestConfiguration() -> LLMConfig? {
        let baseURLText = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: baseURLText),
              let scheme = baseURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              baseURL.host != nil else {
            setConnectionStatus(LLMConnectionTestError.invalidURL.localizedDescription, isError: true)
            return nil
        }

        return LLMConfig(
            enabled: true,
            baseURL: baseURL,
            apiKey: apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            model: modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            systemPrompt: promptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? configStore.defaultSystemPrompt
                : promptTextView.string
        )
    }

    private func setConnectionStatus(_ message: String, isError: Bool) {
        connectionStatusLabel.stringValue = message
        connectionStatusLabel.textColor = isError ? .systemRed : .systemGreen
    }

    private func resetConnectionStatus() {
        connectionStatusLabel.stringValue = "尚未测试连接。"
        connectionStatusLabel.textColor = .secondaryLabelColor
    }

    private func updateFontSizeValueLabel() {
        fontSizeValueLabel.stringValue = "\(Int(AppFontPreferences.size)) pt"
    }

    private func applyFonts() {
        guard let contentView = window?.contentView else {
            return
        }

        AppFontPreferences.applyFontsRecursively(to: contentView)
        updateFontSizeValueLabel()
    }

    private func showMessage(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}

enum SettingsError: LocalizedError {
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "接口地址不是有效 URL。"
        }
    }
}

private final class SettingsFlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}
