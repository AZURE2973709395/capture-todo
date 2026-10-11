# Screen Todo Capture

`Screen Todo Capture（屏幕内容转待办捕获器）` 是一个 macOS 菜单栏 MVP（最小可用版本）：把框选截图或剪贴板截图做 OCR（光学字符识别），自动生成待办规划，并把待办 Markdown（文本待办文件）和截图证据保存到本地。

当前版本对应“项目-1：截图 OCR”：

- `Region Capture（框选截图）`：直接调起 macOS 原生框选截图，不需要先写入剪贴板。
- `Clipboard OCR（剪贴板图片文字识别）`：保留读取 macOS 剪贴板截图的兼容入口。
- `Vision OCR（苹果本地图像文字识别）`：支持简体中文、繁体中文和英文。
- `Todo Draft（待办草稿）`：从 OCR 原文里提取标题和时间线索；启用大模型后自动生成结构化规划。
- `Menu Bar App（菜单栏应用）`：常驻菜单栏。
- `Todo Window（待办窗口）`：用原生窗口查看已保存待办。
- `Todo Management（待办管理）`：支持编辑、完成、恢复待处理、删除、归档。
- `Global Hotkey（全局快捷键）`：`Command + Option + Shift + T` 框选截图，`Command + Option + T` 读取剪贴板截图。
- `Local Storage（本地存储）`：保存 Markdown 待办、PNG 截图，并维护 SQLite（轻量本地数据库）索引。
- `LLM Automation（大模型自动化）`：可选接入兼容 OpenAI 格式的大模型接口，生成标题、步骤、标签、优先级、置信度和难度分。
- `Settings（设置）`：在页面里管理大模型 API Key、模型、接口地址和任务规划提示词。
- `Apple Reminders Sync（苹果提醒事项同步）`：可选单向同步本地待办到系统提醒事项。
- `App Icon（应用图标）`：生成并打包原生 `.icns` 图标。

## 开发环境与项目结构

- macOS 13 或更高版本，Swift 6 工具链；无第三方包依赖。
- `Sources/ScreenTodoCaptureCore`：待办草稿、时间线索提取和 OCR 文本后处理。
- `Sources/ScreenTodoCapture`：AppKit 界面、截图与 OCR 流程、可选大模型规划、Markdown/SQLite 存储和提醒事项同步。
- `Tests/ScreenTodoCaptureTests`：解析、存储、查询一致性和截图错误分类等测试。
- `scripts` 与 `Resources`：应用打包、安装、开机启动和图标资源。

在项目根目录执行 `swift build` 编译，执行 `swift test` 运行测试。测试需要提供 XCTest 的 Xcode 开发环境；仅安装 Command Line Tools 时可能出现 `no such module XCTest`。

## 使用方式

推荐入口是直接框选截图；剪贴板截图入口仍保留，适合你已经用系统快捷键复制过图片的情况。

### 方式一：直接运行源码

首次使用先克隆仓库：

```bash
git clone https://github.com/AZURE2973709395/capture-todo.git
```

```bash
cd capture-todo
swift run ScreenTodoCapture
```

运行后会直接弹出待办窗口，并且 Dock（程序坞）里会出现应用图标。macOS 顶部菜单栏也会保留一个 `TODO` 快捷菜单。

### 方式二：运行 .app 包

如果已经打包，可以直接打开：

```bash
open .build/release/ScreenTodoCapture.app
```

如果 `.app` 不存在，先打包：

```bash
cd capture-todo
./scripts/package-app.sh
open .build/release/ScreenTodoCapture.app
```

### 安装到应用程序

如果你希望它出现在 Finder（访达）的“应用程序”和 Launchpad（启动台）里，运行：

```bash
cd capture-todo
./scripts/install-app.sh
open "/Applications/Screen Todo Capture.app"
```

## 创建一个待办

1. 先打开 QQ、微信或任何你想捕获的页面。

2. 推荐直接触发框选截图：

   ```text
   Command + Option + Shift + T
   ```

   也可以点击顶部菜单栏 `TODO`，然后点“框选截图创建待办”。这会调起 macOS 原生区域选择，截图不会写入系统剪贴板。

3. 如果你想继续使用 Clipboard（剪贴板）方式，也可以先用 macOS 系统截图快捷键复制区域：

   ```text
   Command + Control + Shift + 4
   ```

   鼠标会变成选区十字光标。框选聊天内容后，截图会进入剪贴板，但不会保存到桌面。

   然后触发 Screen Todo Capture：

   ```text
   Command + Option + T
   ```

   也可以点击顶部菜单栏的 checklist（清单）图标，然后点“从剪贴板截图创建待办”。

4. 如果 OCR（光学字符识别）成功，应用会自动保存待办。启用大模型时会先生成标题、摘要、步骤、标签、优先级、置信度、耗时和难度；大模型失败或未启用时，会退回本地规则自动保存，避免漏掉任务。

5. 保存后文件会写入：

   ```text
   ~/Library/Application Support/ScreenTodoCapture/Todos
   ~/Library/Application Support/ScreenTodoCapture/Captures
   ```

   应用还会维护一个 SQLite 索引：

   ```text
   ~/Library/Application Support/ScreenTodoCapture/todos.sqlite3
   ```

   当前策略是 `SQLite 索引/查询层 + Markdown 可读导出`。`.md` 仍然保留，方便你手工查看、备份和迁移；App 刷新时会把 Markdown 同步进 SQLite，后续搜索、过滤和统计可以直接基于 SQLite 扩展。

## 截图保存机制

`Command + Option + Shift + T` 会使用系统 `screencapture（截图命令）` 做交互式框选，并把临时 PNG 读入应用。临时文件读取后会清理，正式截图证据仍保存到 `Captures` 目录。

`Command + Control + Shift + 4` 是 macOS 的“截图到 Clipboard（剪贴板）”快捷键。它不会把截图保存到桌面文件，只会把图片放进剪贴板。

本应用不会自动删除剪贴板内容。每次成功创建待办时，应用会额外保存一份 PNG 截图到：

```text
~/Library/Application Support/ScreenTodoCapture/Captures
```

如果你之后复制了别的文字或图片，macOS 剪贴板里的截图会被覆盖；但已经保存的 PNG 截图不会受影响。

## 查看待办 UI

启动应用后会自动打开待办窗口。也可以点击菜单栏 `TODO`，然后选择：

```text
打开待办面板
```

这个窗口是接近 macOS 备忘录风格的两栏工作台：

- 左栏：待办列表，默认使用智能排序，显示标题、摘要、状态、截止时间和来源。
- 右栏：正文式任务详情，显示任务摘要、执行步骤和简要规划信息；整理文本与原始 OCR 文本通过“来源文本”切换查看。
- 顶部工具条：提供编辑、重新规划、完成/恢复、归档、打开文件/截图、设置和删除等操作。

待办面板支持：

- `搜索/过滤`：按标题、摘要、OCR 原文、状态、时间范围、标签和优先级过滤；支持 `全部`、`今日`、`标签` 视图。
- `编辑`：修改标题、状态、截止时间和 Markdown 详情。难度分由大模型评估，不手工填写。
- `重新规划`：对已有待办再次调用 LLM（大语言模型）生成新标题和计划。新规划会覆盖当前规划字段，旧规划会写入 Markdown 的“规划历史”区块，并同步到 SQLite 历史表。
- `标为完成 / 恢复待处理`：切换任务状态。
- `归档`：把当前待办移动到 Archive（归档目录），保留 Markdown 文件。
- `删除`：删除待办 Markdown 和对应截图。
- `排序`：可按智能排序、创建时间、截止时间、难度分排序。智能排序会优先显示未完成任务，再按截止时间和难度分排序。
- `设置`：打开 Settings（设置）窗口，在“大模型管理”里配置模型和任务规划提示词。

截止时间使用紧凑的 macOS 原生 Date Picker（日期/时间选择器）。编辑时可以直接输入日期时间，也可以点击“打开日历”用 Calendar（日历）选择日期，避免大日历和时钟挤在待办弹窗里导致显示重叠。

完成超过 3 天的待办会在刷新列表时自动归档。

## 配置大模型

默认不会调用大模型，也不会把聊天内容上传到任何服务。

要启用大模型，点击菜单栏 `TODO` 里的：

```text
设置...
```

也可以在待办面板右侧点击：

```text
设置
```

打开 Settings（设置）窗口后，进入 `大模型管理`。这里可以配置：

- 是否启用大模型增强。
- API Key（接口密钥）。
- Base URL（接口地址）。
- Model（模型名称）。
- Task Planning Prompt（任务规划提示词）。
- `测试连接`：用当前页面里的 Base URL（接口地址）、API Key（接口密钥）和 Model（模型名称）发起一次轻量 Chat Completions（聊天补全）请求，验证接口是否可用。测试不会保存设置，也不会改写 `config.json`。
- `界面字号`：调整全局 UI 字体大小，覆盖待办面板、设置页、创建/编辑弹窗和文本区。字号保存到 macOS UserDefaults（用户偏好），不会写入 `config.json`。
- `同步到 Apple Reminders（苹果提醒事项）`：打开后，新建待办会单向创建系统提醒事项；本地完成/恢复会同步提醒事项状态。删除或归档本地待办不会删除系统提醒事项。

底层仍会保存到 `config.json`：

```json
{
  "llm": {
    "enabled": true,
    "baseURL": "https://api.openai.com/v1/chat/completions",
    "apiKey": "你的 API Key",
    "model": "你的模型名称",
    "systemPrompt": "你的任务规划提示词"
  }
}
```

说明：

- `LLM（大语言模型）` 只接收 OCR 文本和来源应用名称，不上传截图文件本身。
- 当前的“识别增强”是文本级增强：修正 OCR 断行、明显错字、界面噪声，并生成更准确的任务标题。
- 大模型会生成任务规划建议：标题、修正文案、摘要、执行步骤、截止时间、预计耗时、难度等级、1-10 难度分、tags（标签）、priority（优先级）和 confidence（置信度）。
- 任务规划提示词可在设置窗口里修改，用来注入你自己的标题风格、步骤粒度、难度评分规则和保守推断边界。
- `baseURL` 使用 OpenAI-compatible（兼容 OpenAI 格式）的 Chat Completions（聊天补全）接口。
- `baseURL` 可以填写完整 `/chat/completions` 端点，也可以填写兼容 OpenAI 的 `/v1` 根路径；应用发请求时会自动补齐 `/chat/completions`，不会改写配置文件。
- 如果没有配置或配置失败，应用会自动退回本地规则生成待办。
- 字体大小不是大模型配置的一部分，不会进入 `config.json`。

## 规划历史与存储

重规划时，应用会先把旧标题、摘要、步骤、预计耗时、难度、标签、优先级和置信度保存为历史版本，再写入新规划。

存储仍采用：

- Markdown（文本待办文件）：作为 source of truth（事实来源），可直接打开阅读和备份。
- SQLite（轻量本地数据库）：作为索引/查询层，包含 tags（标签）、priority（优先级）、confidence（置信度）和 `todo_plan_history` 历史表。

编辑、完成、删除、归档、重新规划后都会重建 SQLite 索引，保持 Markdown 与 SQLite 一致。

Apple Reminders 单向同步会额外写入这些 Markdown 元数据：

```text
- reminderIdentifier: ...
- reminderSyncedAt: ...
- reminderSyncStatus: synced
```

这些字段也会进入 SQLite 索引，用来在 UI 中显示同步状态。

也可以临时用环境变量：

```bash
export SCREEN_TODO_LLM_ENABLED=true
export SCREEN_TODO_LLM_API_KEY="你的 API Key"
export SCREEN_TODO_LLM_MODEL="你的模型名称"
export SCREEN_TODO_LLM_BASE_URL="https://api.openai.com/v1/chat/completions"
swift run ScreenTodoCapture
```

## 开机自动启动

方式一：在应用菜单里安装。

点击菜单栏 `TODO`，然后选择：

```text
安装开机启动
```

方式二：用脚本安装。

```bash
cd capture-todo
./scripts/install-launch-agent.sh
```

卸载：

```bash
cd capture-todo
./scripts/uninstall-launch-agent.sh
```

它使用的是 LaunchAgent（macOS 用户级开机启动项），配置文件写入：

```text
~/Library/LaunchAgents/local.codex.ScreenTodoCapture.plist
```

这只影响当前用户，不需要管理员权限。

## 如果“不起作用”

先按下面顺序排查：

1. 确认应用已经启动：顶部菜单栏应该有 `TODO` 文本菜单项。没有 `TODO` 就先运行：

   ```bash
   open .build/release/ScreenTodoCapture.app
   ```

2. 推荐先试直接框选截图：

   ```text
   Command + Option + Shift + T
   ```

   如果你取消框选，应用不会创建待办。

3. 如果你用剪贴板方式，确认你用的是“复制到剪贴板”的截图快捷键：

   ```text
   Command + Control + Shift + 4
   ```

   如果你用的是 `Command + Shift + 4`，截图会保存到桌面，不会进入剪贴板，本应用就读不到图片。

4. 不确定剪贴板里有没有图片时，可以先随便打开一个聊天窗口，按 `Command + Control + Shift + 4` 框选一块区域，再点击菜单栏图标里的“从剪贴板截图创建待办”。

5. 如果快捷键没反应，可能被其他应用占用了快捷键。先用菜单栏菜单触发；后续可以在代码里换一个快捷键。

6. 当前版本不再使用 Notification Permission（通知权限）。保存、复制、开机启动等非阻塞结果会短暂显示在菜单栏图标位置，避免未签名本地应用因为通知权限崩溃。

7. 保存结果在这里：

   ```text
   ~/Library/Application Support/ScreenTodoCapture/Todos
   ```

8. 如果 Apple Reminders 同步失败，先确认设置页开关已打开，并在系统权限弹窗中允许访问提醒事项。本地待办保存不依赖同步成功。

9. 如果应用打不开，可以重新构建：

   ```bash
   cd capture-todo
   swift build
   ./scripts/package-app.sh
   open .build/release/ScreenTodoCapture.app
   ```

## 打包成 .app

没有 Xcode（苹果集成开发环境）也可以用脚本生成一个简单的 `.app` 包：

```bash
./scripts/package-app.sh
```

打包脚本会自动生成 `AppIcon.icns（macOS 应用图标文件）`，并写入 `.app`。

生成路径：

```text
.build/release/ScreenTodoCapture.app
```

## 重新生成应用图标

```bash
cd capture-todo
./scripts/generate-icon.sh
```

生成文件：

```text
Resources/AppIcon-1024.png
Resources/AppIcon.iconset
Resources/AppIcon.icns
```

## 轻量实现选择

当前版本没有第三方依赖。Global Hotkey（全局快捷键）使用 macOS 原生 `Carbon（旧版系统事件接口）` 实现；OCR（光学字符识别）、框选截图、剪贴板读取、菜单栏、Apple Reminders 和本地存储都使用 macOS 原生能力实现。

## 当前边界

- 当前直接框选截图使用系统 `screencapture` 命令，不自绘截图选择器。
- 当前不读取 QQ/微信数据库，也不读取聊天软件内部消息结构。
- Apple Reminders（苹果提醒事项）只做本地到系统提醒事项的单向同步，不做反向导入或删除系统提醒事项。

## 下一步建议

1. 加 `ScreenCaptureKit（苹果屏幕捕获框架）` 选区截图，替代命令行 `screencapture`。
2. 加 `Accessibility（辅助功能）` 可选能力，记录当前窗口标题作为来源上下文。
3. 加任务复盘：记录实际耗时，反向校准 LLM（大语言模型）的估时和难度分。
