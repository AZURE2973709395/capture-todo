import Darwin
import Foundation

/// 管理 LaunchAgent（macOS 用户级开机启动项）。
///
/// LaunchAgent 写入 `~/Library/LaunchAgents`，只影响当前用户，不需要管理员权限。
struct LaunchAgentManager {
    private let label = "local.codex.ScreenTodoCapture"
    private let fileManager = FileManager.default
    private let store = TodoStore()

    private var domain: String {
        "gui/\(getuid())"
    }

    private var launchAgentsDirectory: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(label).plist")
    }

    func isInstalled() -> Bool {
        fileManager.fileExists(atPath: plistURL.path)
    }

    func install() throws {
        try store.ensureDirectories()
        try fileManager.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)

        let executablePath = currentExecutablePath()
        let logDirectory = store.rootDirectory.appendingPathComponent("Logs", isDirectory: true)
        try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": logDirectory.appendingPathComponent("launch-agent.out.log").path,
            "StandardErrorPath": logDirectory.appendingPathComponent("launch-agent.err.log").path
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)

        _ = try? runLaunchctl(["bootout", domain, plistURL.path])
        try runLaunchctl(["bootstrap", domain, plistURL.path])
        _ = try? runLaunchctl(["enable", "\(domain)/\(label)"])
        _ = try? runLaunchctl(["kickstart", "-k", "\(domain)/\(label)"])
    }

    func uninstall() throws {
        _ = try? runLaunchctl(["bootout", domain, plistURL.path])
        if fileManager.fileExists(atPath: plistURL.path) {
            try fileManager.removeItem(at: plistURL)
        }
    }

    /// 优先使用 .app 包内的可执行文件；如果通过 `swift run` 启动，则使用当前二进制路径。
    private func currentExecutablePath() -> String {
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasSuffix(".app") {
            return URL(fileURLWithPath: bundlePath)
                .appendingPathComponent("Contents/MacOS/ScreenTodoCapture")
                .path
        }

        return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    }

    @discardableResult
    private func runLaunchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw LaunchAgentError.launchctlFailed(arguments, process.terminationStatus)
        }

        return process.terminationStatus
    }
}

enum LaunchAgentError: LocalizedError {
    case launchctlFailed([String], Int32)

    var errorDescription: String? {
        switch self {
        case .launchctlFailed(let arguments, let status):
            return "launchctl 执行失败：\(arguments.joined(separator: " "))，退出码：\(status)"
        }
    }
}
