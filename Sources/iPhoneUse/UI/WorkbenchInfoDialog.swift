import AppKit

/// Shared content for the native equivalents of the HTML guide/MCP/API dialogs.
enum WorkbenchInfoKind: String, CaseIterable { case guide, mcp, api }

struct WorkbenchInfoContent {
    let title: String
    let introduction: String
    let code: String?
    let detail: String
    let notice: String

    init(kind: WorkbenchInfoKind, language: AppLanguage, executable: URL?, port: UInt16, preview: Bool) {
        let zh = language == .zh
        notice = preview
            ? (zh ? "离线界面预览，不连接真机，不执行设备操作。" : "Offline preview. No device connection or actions.")
            : (zh ? "仅显示接入说明；不会自动执行命令或向 iPhone 发送操作。" : "Instructions only. Commands and iPhone actions are never run automatically.")
        switch kind {
        case .mcp:
            title = zh ? "通过 MCP 接入 AI" : "Connect AI through MCP"
            introduction = zh
                ? "iPhone Use 提供工具服务，模型与聊天在外部客户端运行。保持主程序运行，在终端注册当前应用："
                : "iPhone Use provides tools; models and chats run in your external client. Keep this app running and register it in Terminal:"
            code = WorkbenchConfiguration.mcpCommand(executable: executable)
            detail = zh
                ? "源码版也可在仓库根目录执行 ./scripts/install-codex-mcp.sh。客户端重启或新建聊天后加载工具。多设备操作须明确选择完整设备 ID。"
                : "For a source checkout, run ./scripts/install-codex-mcp.sh at the repository root. Restart your client or open a new chat to load tools. Always select the full device ID when using multiple phones."
        case .api:
            title = zh ? "脚本与本地 HTTP API" : "Scripts and local HTTP API"
            introduction = zh
                ? "设备由本机回环服务控制。以下命令仅为文档示例，不会从弹窗自动发起请求。"
                : "Devices use the local loopback service. These are examples only; opening this dialog sends no requests."
            code = "# \(zh ? "列出设备" : "List devices")\ncurl -s http://127.0.0.1:\(port)/devices\n\n# \(zh ? "获取指定设备的截图" : "Capture a specific device")\ncurl -s 'http://127.0.0.1:\(port)/screenshot?device=DEVICE_ID' -o screen.jpg"
            detail = zh
                ? "支持截图、点击、滑动、文本输入，以及按序执行动作。设备操作必须指定准确的设备 ID；弹窗不会执行批量控制或定时任务。"
                : "Use screenshots, taps, swipes, text and ordered actions. Specify the exact device ID. This dialog does not run batch control or scheduled tasks."
        case .guide:
            title = zh ? "连接真实 iPhone" : "Connect a real iPhone"
            introduction = zh
                ? "1. 使用可传输数据的 USB 线连接，解锁 iPhone 并信任此 Mac。\n2. 允许 Mac 的相机权限，用于读取 USB 画面。\n3. iOS 17.3 及以上默认 USB 触控；旧系统默认蓝牙，需要允许蓝牙权限、开启辅助触控并完成配对。手动选择会按设备保留。\n4. USB Touch 为实验性后端：需 iOS 17+、兼容的 Apple Silicon 主机、开发者模式及兼容 DDI。最低版本不代表所有组合均支持。"
                : "1. Connect a data-capable USB cable, unlock your iPhone and trust this Mac.\n2. Allow camera access on the Mac for USB capture.\n3. iOS 17.3+ defaults to USB Touch; older versions default to Bluetooth and need permission, AssistiveTouch and pairing. Your explicit choice is saved per device.\n4. USB Touch is experimental: iOS 17+, compatible Apple Silicon hardware, Developer Mode and DDI are required. A minimum version does not guarantee every combination works."
            code = nil
            detail = zh
                ? "USB 画面已连接不等于输入已就绪。USB Touch 不可用时不自动转发至蓝牙。下载 DDI 不等于安装，安装前需核对计划。"
                : "A connected USB display does not mean input is ready. USB Touch failures never fall back to Bluetooth. Downloading a DDI does not install it; review the plan before installation."
        }
    }
}

/// Workspace-level modal, never mounted inside a phone image or device card.
final class WorkbenchInfoOverlay: WorkbenchSurface {
    let kind: WorkbenchInfoKind
    let card: WorkbenchInfoCard
    var onDismiss: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    init(kind: WorkbenchInfoKind, content: WorkbenchInfoContent) {
        self.kind = kind
        card = WorkbenchInfoCard(content: content)
        super.init(frame: .zero)
        setAccessibilityIdentifier("workbench-info-dialog:\(kind.rawValue)")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(content.title)
        addSubview(card)
        card.close.invoke = { [weak self] in self?.onDismiss?() }
        card.onEscape = { [weak self] in self?.onDismiss?() }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let width = min(570, max(0, bounds.width - 48))
        let height = min(card.preferredHeight(for: width), max(0, bounds.height - 64))
        card.frame = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2,
                            width: width, height: height)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.10, green: 0.18, blue: 0.23, alpha: 0.33).setFill()
        dirtyRect.intersection(bounds).fill()
    }
    // Blank backdrop clicks are swallowed rather than reaching an iPhone.
    override func mouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDismiss?() }
    }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { onDismiss?(); return true }
        // Keep the keyboard loop inside this modal. Close is the only action.
        if event.keyCode == 48 { window?.makeFirstResponder(card.close); return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class WorkbenchInfoCard: WorkbenchSurface {
    let close = WorkbenchActionButton()
    let heading = NSTextField(labelWithString: "")
    let bodyScroll = NSScrollView()
    let body = WorkbenchSurface()
    let introduction = NSTextField(wrappingLabelWithString: "")
    let detail = NSTextField(wrappingLabelWithString: "")
    let notice = NSTextField(wrappingLabelWithString: "")
    let codeBox = WorkbenchDialogCodeSurface()
    let code = WorkbenchDialogCodeView()
    let rule = WorkbenchSurface()
    let content: WorkbenchInfoContent
    var onEscape: (() -> Void)?

    init(content: WorkbenchInfoContent) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        shadow = NSShadow()
        shadow?.shadowColor = NSColor(srgbRed: 0.10, green: 0.24, blue: 0.22, alpha: 0.20)
        shadow?.shadowBlurRadius = 32
        shadow?.shadowOffset = NSSize(width: 0, height: -12)
        heading.stringValue = content.title
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        heading.textColor = WorkbenchTheme.ink
        introduction.stringValue = content.introduction
        detail.stringValue = content.detail
        notice.stringValue = content.notice
        for label in [introduction, detail, notice] {
            label.font = .systemFont(ofSize: label === notice ? 10 : 12)
            label.textColor = label === notice ? WorkbenchTheme.amber : WorkbenchTheme.muted
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.isSelectable = true
            let style = NSMutableParagraphStyle()
            style.lineSpacing = label === notice ? 3 : 6
            label.attributedStringValue = NSAttributedString(string: label.stringValue, attributes: [
                .font: label.font!, .foregroundColor: label.textColor!, .paragraphStyle: style,
            ])
        }
        close.appearanceStyle = .plain
        close.symbolName = "xmark"
        close.setAccessibilityLabel(AppLanguageStore.shared.language == .zh ? "关闭对话框" : "Close dialog")
        close.setAccessibilityIdentifier("workbench-dialog-close")
        close.keyEquivalent = "\u{1b}"
        close.keyEquivalentModifierMask = []
        bodyScroll.documentView = body
        bodyScroll.hasVerticalScroller = true
        bodyScroll.drawsBackground = false
        bodyScroll.borderType = .noBorder
        bodyScroll.autohidesScrollers = true
        codeBox.fill = WorkbenchTheme.color(0xF1F5F5, 0x203B35)
        code.string = content.code ?? ""
        code.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        code.textColor = WorkbenchTheme.color(0x437466, 0xA2D1BF)
        code.isEditable = false
        code.isSelectable = true
        code.drawsBackground = false
        code.isRichText = false
        code.isHorizontallyResizable = false
        code.isVerticallyResizable = false
        code.textContainerInset = .zero
        code.textContainer?.lineFragmentPadding = 0
        code.textContainer?.lineBreakMode = .byCharWrapping
        code.onEscape = { [weak self] in self?.onEscape?() }
        code.setAccessibilityIdentifier("workbench-dialog-code")
        rule.fill = WorkbenchTheme.line
        [heading, close, bodyScroll, notice, rule].forEach(addSubview)
        [introduction, codeBox, detail].forEach(body.addSubview)
        codeBox.addSubview(code)
        codeBox.isHidden = content.code == nil
    }
    required init?(coder: NSCoder) { fatalError() }
    private func height(_ label: NSTextField, width: CGFloat) -> CGFloat {
        ceil(label.attributedStringValue.boundingRect(
            with: NSSize(width: max(1, width), height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height) + 4
    }
    private func codeHeight(width: CGFloat) -> CGFloat {
        guard content.code != nil else { return 0 }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byCharWrapping
        return ceil((code.string as NSString).boundingRect(
            with: NSSize(width: max(1, width), height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: code.font!, .paragraphStyle: style]
        ).height) + 10
    }
    private func bodyHeight(width: CGFloat) -> CGFloat {
        height(introduction, width: width) + 16
            + (content.code == nil ? 0 : codeHeight(width: width - 30) + 30 + 16)
            + height(detail, width: width)
    }
    func preferredHeight(for width: CGFloat) -> CGFloat {
        let inner = max(1, width - 56)
        return 28 + 28 + 14 + bodyHeight(width: inner) + 20 + 13 + height(notice, width: inner) + 28
    }
    override func layout() {
        super.layout()
        let inner = max(1, bounds.width - 56)
        let footerHeight = height(notice, width: inner)
        heading.frame = NSRect(x: 28, y: 28, width: inner - 36, height: 28)
        close.frame = NSRect(x: bounds.width - 54, y: 25, width: 28, height: 28)
        rule.frame = NSRect(x: 28, y: bounds.height - 28 - footerHeight - 13, width: inner, height: 1)
        notice.frame = NSRect(x: 28, y: bounds.height - 28 - footerHeight, width: inner, height: footerHeight)
        bodyScroll.frame = NSRect(x: 28, y: 70, width: inner, height: max(1, rule.frame.minY - 90))
        // Reserve scroller room at compact heights so text never clips under it.
        let width = max(1, bodyScroll.contentSize.width - 2)
        body.frame = NSRect(x: 0, y: 0, width: width, height: max(bodyScroll.bounds.height, bodyHeight(width: width)))
        introduction.frame = NSRect(x: 0, y: 0, width: width, height: height(introduction, width: width))
        var y = introduction.frame.maxY + 16
        if content.code != nil {
            let h = codeHeight(width: width - 30)
            codeBox.frame = NSRect(x: 0, y: y, width: width, height: h + 30)
            code.frame = NSRect(x: 15, y: 15, width: width - 30, height: h)
            code.textContainer?.containerSize = NSSize(width: width - 30, height: h)
            y = codeBox.frame.maxY + 16
        }
        detail.frame = NSRect(x: 0, y: y, width: width, height: height(detail, width: width))
    }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 15, yRadius: 15)
        WorkbenchTheme.paper.setFill(); path.fill()
        WorkbenchTheme.color(0xDBE6E2, 0x43594F).setStroke(); path.stroke()
    }
    // A card-background click cannot dismiss or fall through into the backdrop.
    override func mouseDown(with event: NSEvent) {}
}

final class WorkbenchDialogCodeView: NSTextView {
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

final class WorkbenchDialogCodeSurface: WorkbenchSurface {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        fill.setFill(); path.fill()
        WorkbenchTheme.color(0xE1E9E7, 0x43594F).setStroke(); path.stroke()
    }
}
