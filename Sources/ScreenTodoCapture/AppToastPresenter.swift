import AppKit

/// 应用内轻量提示浮层。
///
/// 这里不用 UserNotifications（系统通知权限），也不用阻塞式 NSAlert。保存成功后只在
/// 屏幕右上角短暂显示一个浮层，既明确告诉用户“已经保存”，又不会打断连续截图流程。
@MainActor
final class AppToastPresenter {
    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    func showSuccess(title: String, message: String, duration: TimeInterval = 3.0) {
        show(
            title: title,
            message: message,
            symbolName: "checkmark.circle.fill",
            accentColor: .systemGreen,
            duration: duration
        )
    }

    private func show(
        title: String,
        message: String,
        symbolName: String,
        accentColor: NSColor,
        duration: TimeInterval
    ) {
        dismissWorkItem?.cancel()
        panel?.close()

        let contentView = makeContentView(
            title: title,
            message: message,
            symbolName: symbolName,
            accentColor: accentColor,
            size: preferredToastSize(title: title, message: message)
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentView.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = contentView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false

        position(panel: panel)
        panel.orderFrontRegardless()
        self.panel = panel

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.panel?.close()
                self?.panel = nil
            }
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    private func makeContentView(
        title: String,
        message: String,
        symbolName: String,
        accentColor: NSColor,
        size: NSSize
    ) -> NSView {
        let container = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        icon.contentTintColor = accentColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        AppFontPreferences.apply(.bodySemibold, to: titleLabel)
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byWordWrapping

        let messageLabel = NSTextField(labelWithString: message)
        AppFontPreferences.apply(.caption, to: messageLabel)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 4
        messageLabel.lineBreakMode = .byWordWrapping

        let textStack = NSStackView(views: [titleLabel, messageLabel])
        textStack.orientation = .vertical
        textStack.spacing = 4
        textStack.alignment = .leading
        textStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(icon)
        container.addSubview(textStack)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),

            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: 14),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -14),
            textStack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        return container
    }

    /// 根据当前全局字号和文案长度估算 Toast 大小。
    ///
    /// 输入是标题与正文；输出是给 `NSPanel` 使用的固定尺寸，避免长提示在两行内被
    /// 硬截断，同时给极长文案设置上限，保持浮层仍然像一个轻量通知。
    private func preferredToastSize(title: String, message: String) -> NSSize {
        let width: CGFloat = AppFontPreferences.size >= 18 ? 460 : 420
        let textWidth = width - 18 - 28 - 14 - 18
        let titleHeight = boundedTextHeight(
            title,
            width: textWidth,
            font: AppFontPreferences.font(.bodySemibold),
            maximumLines: 2
        )
        let messageHeight = boundedTextHeight(
            message,
            width: textWidth,
            font: AppFontPreferences.font(.caption),
            maximumLines: 4
        )

        let height = min(max(92, titleHeight + messageHeight + 34), 164)
        return NSSize(width: width, height: ceil(height))
    }

    private func boundedTextHeight(_ text: String, width: CGFloat, font: NSFont, maximumLines: Int) -> CGFloat {
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let boundingHeight = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).height
        return min(ceil(boundingHeight), lineHeight * CGFloat(maximumLines))
    }

    private func position(panel: NSPanel) {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let margin: CGFloat = 24
        let origin = NSPoint(
            x: screenFrame.maxX - panel.frame.width - margin,
            y: screenFrame.maxY - panel.frame.height - margin
        )
        panel.setFrameOrigin(origin)
    }
}
