import AppKit
import Carbon
import ScreenTodoCaptureCore

/// 普通 macOS 应用入口，同时保留菜单栏快捷入口。
///
/// 主流程：读取剪贴板截图 -> OCR 识别 -> 可选 LLM 自动规划 -> 本地保存。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var clipboardHotKey: GlobalHotKey?
    private var regionHotKey: GlobalHotKey?
    private let clipboardReader = ClipboardImageReader()
    private let regionCaptureService = ScreenRegionCaptureService()
    private let store = TodoStore()
    private let configStore = AppConfigStore()
    private let launchAgentManager = LaunchAgentManager()
    private let toastPresenter = AppToastPresenter()
    private lazy var todoListWindowController = TodoListWindowController(store: store, configStore: configStore) { [weak self] in
        self?.openSettings()
    }
    private lazy var settingsWindowController = SettingsWindowController(configStore: configStore)
    private var lastOCRText = ""
    private var lastStoredTodo: StoredTodo?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `.regular` 表示普通应用：Dock（程序坞）显示图标，Command+Tab 可切换。
        NSApp.setActivationPolicy(.regular)
        setupApplicationMenu()
        setupStatusItem()
        setupHotKey()
        try? store.ensureDirectories()
        try? configStore.ensureSampleConfig()
        todoListWindowController.showAndRefresh()
    }

    /// 创建 Dock 应用菜单。这样用户从屏幕顶部的应用菜单也能直接找到“设置”。
    private func setupApplicationMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(menuItem(
            title: "设置...",
            action: #selector(openSettings),
            keyEquivalent: ","
        ))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(menuItem(
            title: "退出 Screen Todo Capture",
            action: #selector(quit),
            keyEquivalent: "q"
        ))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let todoMenuItem = NSMenuItem()
        let todoMenu = NSMenu(title: "待办")
        todoMenu.addItem(menuItem(
            title: "框选截图创建待办",
            action: #selector(captureScreenRegion),
            keyEquivalent: "T",
            modifiers: [.command, .option, .shift]
        ))
        todoMenu.addItem(menuItem(
            title: "从剪贴板截图创建待办",
            action: #selector(captureClipboardImage),
            keyEquivalent: "t",
            modifiers: [.command, .option]
        ))
        todoMenu.addItem(menuItem(
            title: "打开待办面板",
            action: #selector(openTodoListWindow),
            keyEquivalent: "1"
        ))
        todoMenuItem.submenu = todoMenu
        mainMenu.addItem(todoMenuItem)

        NSApp.mainMenu = mainMenu
    }

    /// 创建菜单栏快捷入口。即使 Dock 可见，也保留顶部快捷菜单。
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = "TODO"
            button.imagePosition = .imageLeading
            button.toolTip = "Screen Todo Capture（截图 OCR 转待办）"

            if let image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Screen Todo Capture") {
                image.isTemplate = true
                button.image = image
            }
        }

        let menu = NSMenu()
        menu.addItem(menuItem(
            title: "框选截图创建待办",
            action: #selector(captureScreenRegion),
            keyEquivalent: ""
        ))
        menu.addItem(menuItem(
            title: "从剪贴板截图创建待办",
            action: #selector(captureClipboardImage),
            keyEquivalent: ""
        ))
        menu.addItem(menuItem(
            title: "复制上次 OCR 文本",
            action: #selector(copyLastOCRText),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(
            title: "打开待办面板",
            action: #selector(openTodoListWindow),
            keyEquivalent: ""
        ))
        menu.addItem(menuItem(
            title: "打开待办目录",
            action: #selector(openTodosDirectory),
            keyEquivalent: ""
        ))
        menu.addItem(menuItem(
            title: "打开截图目录",
            action: #selector(openCapturesDirectory),
            keyEquivalent: ""
        ))
        menu.addItem(menuItem(
            title: "设置...",
            action: #selector(openSettings),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(
            title: "安装开机启动",
            action: #selector(installLaunchAgent),
            keyEquivalent: ""
        ))
        menu.addItem(menuItem(
            title: "卸载开机启动",
            action: #selector(uninstallLaunchAgent),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(
            title: "退出",
            action: #selector(quit),
            keyEquivalent: "q"
        ))
        item.menu = menu
        statusItem = item
    }

    private func menuItem(
        title: String,
        action: Selector,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    /// 注册全局快捷键。框选截图是主入口，剪贴板截图保留为兼容入口。
    private func setupHotKey() {
        do {
            clipboardHotKey = try GlobalHotKey(
                keyCode: UInt32(kVK_ANSI_T),
                modifiers: UInt32(cmdKey | optionKey)
            ) { [weak self] in
                self?.captureClipboardImage()
            }
            regionHotKey = try GlobalHotKey(
                keyCode: UInt32(kVK_ANSI_T),
                modifiers: UInt32(cmdKey | optionKey | shiftKey),
                identifier: 2
            ) { [weak self] in
                self?.captureScreenRegion()
            }
        } catch {
            showError(error)
        }
    }

    /// 核心业务流程。
    ///
    /// 当前前台应用只用于上下文记录，不读取 QQ/微信等应用的内部数据。
    @objc private func captureClipboardImage() {
        Task {
            await captureClipboardImageFlow()
        }
    }

    @objc private func captureScreenRegion() {
        Task {
            await captureScreenRegionFlow()
        }
    }

    private func captureClipboardImageFlow() async {
        let sourceApplication = NSWorkspace.shared.frontmostApplication?.localizedName ?? "未知应用"

        do {
            let image = try clipboardReader.readImage()
            try await runCapturePipeline(image: image, sourceApplication: sourceApplication)
        } catch {
            showError(error)
        }
    }

    private func captureScreenRegionFlow() async {
        let sourceApplication = NSWorkspace.shared.frontmostApplication?.localizedName ?? "未知应用"

        do {
            showNotification(title: "框选截图", body: "请拖拽选择要识别的屏幕区域。")
            let image = try regionCaptureService.captureRegion()
            try await runCapturePipeline(image: image, sourceApplication: sourceApplication)
        } catch ScreenRegionCaptureError.cancelled {
            showNotification(title: "已取消截图", body: "没有创建待办。")
        } catch {
            showError(error)
        }
    }

    private func runCapturePipeline(image: NSImage, sourceApplication: String) async throws {
        let pipeline = CapturePipeline(
            store: store,
            configStore: configStore
        ) { [weak self] event in
            switch event {
            case .llmPlanningStarted:
                self?.showNotification(title: "大模型规划中", body: "正在生成标题、步骤、标签、优先级和难度。")
            case .llmPlanningFailed:
                self?.showNotification(title: "大模型规划失败", body: "已使用本地规则自动保存待办。")
            }
        }

        let result = try await pipeline.run(image: image, sourceApplication: sourceApplication)
        lastOCRText = result.recognizedText
        lastStoredTodo = result.storedTodo
        todoListWindowController.refresh()
        showNotification(title: "待办已保存", body: result.title)
        toastPresenter.showSuccess(
            title: "保存成功",
            message: "已保存待办：\(result.title)"
        )
        await syncReminderForNewTodoIfNeeded(todoURL: result.storedTodo.todoURL)
    }

    private func syncReminderForNewTodoIfNeeded(todoURL: URL) async {
        guard ReminderSyncPreferences.isEnabled else {
            return
        }

        do {
            guard let record = try store.loadRecord(fileURL: todoURL) else {
                return
            }
            guard let metadata = try await ReminderSyncService.shared.syncTodo(fileURL: todoURL, store: store) else { return }
            todoListWindowController.refresh()
            if metadata.status == .synced {
                showNotification(title: "提醒事项已同步", body: record.title)
            } else {
                showNotification(title: "提醒事项同步失败", body: metadata.message ?? ReminderSyncStatus.display(metadata.status.rawValue))
            }
        } catch {
            showNotification(title: "提醒事项同步失败", body: error.localizedDescription)
        }
    }

    /// 方便用户把上一次 OCR 文本复制到其他工具里继续处理。
    @objc private func copyLastOCRText() {
        guard !lastOCRText.isEmpty else {
            showNotification(title: "没有可复制的 OCR 文本", body: "请先从剪贴板截图创建一次待办。")
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastOCRText, forType: .string)
        showNotification(title: "OCR 文本已复制", body: "已复制到剪贴板。")
    }

    /// 打开原生待办列表窗口。
    @objc private func openTodoListWindow() {
        todoListWindowController.showAndRefresh()
    }

    /// 打开本地 Markdown 待办目录。
    @objc private func openTodosDirectory() {
        try? store.ensureDirectories()
        NSWorkspace.shared.open(store.todosDirectory)
    }

    /// 打开截图证据目录。
    @objc private func openCapturesDirectory() {
        try? store.ensureDirectories()
        NSWorkspace.shared.open(store.capturesDirectory)
    }

    /// 打开通用设置窗口；大模型管理、API Key 和任务规划提示词都放在这里。
    @objc func openSettings() {
        settingsWindowController.show()
    }

    /// 将当前应用注册为用户级开机启动项。
    @objc private func installLaunchAgent() {
        do {
            try launchAgentManager.install()
            showNotification(title: "开机启动已安装", body: "Screen Todo Capture 会在你登录后自动启动。")
        } catch {
            showError(error)
        }
    }

    /// 移除用户级开机启动项。
    @objc private func uninstallLaunchAgent() {
        do {
            try launchAgentManager.uninstall()
            showNotification(title: "开机启动已卸载", body: "Screen Todo Capture 不会再自动启动。")
        } catch {
            showError(error)
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// 用阻塞弹窗展示需要用户立即处理的错误。
    private func showError(_ error: Error) {
        if let regionCaptureError = error as? ScreenRegionCaptureError,
           case .screenRecordingPermissionRequired = regionCaptureError {
            showScreenRecordingPermissionError(regionCaptureError)
            return
        }

        let alert = NSAlert(error: error)
        alert.messageText = "截图 OCR 失败"
        alert.runModal()
    }

    /// Screen Recording（屏幕录制）属于 TCC（macOS 隐私权限数据库）管理的系统权限。
    ///
    /// 用户勾选权限后，当前进程通常需要完整退出并重新打开才能让新授权生效。本弹窗只负责
    /// 引导用户进入系统设置或退出应用，不在这里修改任何业务数据或配置文件。
    private func showScreenRecordingPermissionError(_ error: ScreenRegionCaptureError) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "\(error.localizedDescription)\n\n如果你已经勾选过，请完全退出 Screen Todo Capture 后重新打开；本地开发包每次重新安装后也可能需要重新授权。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "退出应用")
        alert.addButton(withTitle: "取消")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            NSApplication.shared.terminate(nil)
        default:
            break
        }
    }

    /// 用菜单栏短文本展示保存成功、复制成功这类非阻塞结果。
    ///
    /// 不使用 UserNotifications（新版通知框架），也不使用 NSUserNotification（旧版通知 API），
    /// 这样未签名本地应用启动时不会因为通知权限或 bundle 元数据问题崩溃。
    private func showNotification(title: String, body: String) {
        guard let button = statusItem?.button else {
            return
        }

        let originalImage = button.image
        let originalTitle = button.title
        button.image = nil
        button.title = title
        button.toolTip = body

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            button.title = originalTitle.isEmpty ? "TODO" : originalTitle
            button.image = originalImage
            button.toolTip = "Screen Todo Capture（截图 OCR 转待办）"
        }
    }
}

// Swift Package 可执行程序入口：手动创建 NSApplication 并挂载代理。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
