import AppKit

struct WorkbenchManagedApp {
    let bundleID: String
    let name: String
    let executablePath: String?
    var state: NativeAppServices.RunningState = .unknown

    init?(_ entry: NativeAppInventory.Entry) {
        guard let id = entry.attributes["bundle_id"], NativeAppServices.validBundleID(id) else { return nil }
        bundleID = id
        let name = entry.attributes["name"] ?? ""
        self.name = name.isEmpty ? id : name
        executablePath = entry.executablePath
    }

    static func visible(_ apps: [Self], query: String) -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return apps.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || $0.bundleID.localizedCaseInsensitiveContains(query)
        }.sorted {
            if ($0.state == .running) != ($1.state == .running) { return $0.state == .running }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.bundleID < $1.bundleID : order == .orderedAscending
        }
    }
}

/// A sheet bound to one physical USB device. Refresh never sends a device mutation.
final class WorkbenchAppManager: WorkbenchSurface, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    struct Client {
        let inventory: (String) throws -> [NativeAppInventory.Entry]
        let processes: (String) throws -> NativeAppServices.ProcessSnapshot
        let perform: (NativeAppManagement.Operation, String, String) throws -> Void

        static let native = Client(
            inventory: NativeAppManagement.managerInventory, processes: NativeAppManagement.managerProcesses,
            perform: { operation, device, bundleID in
                // This sheet refreshes the actual process snapshot, not an AX foreground receipt.
                _ = try NativeAppManagement.perform(
                    operation, device: device, bundleID: bundleID, capture: { _ in [:] })
            })
    }

    static let size = NSSize(width: 730, height: 532)
    static func title(_ language: AppLanguage) -> String { language == .zh ? "App 管理" : "App Management" }

    let deviceID: String
    var onClose: (() -> Void)?
    private let client: Client
    private let language: AppLanguage
    private var zh: Bool { language == .zh }
    private var apps: [WorkbenchManagedApp] = []
    private(set) var visibleApps: [WorkbenchManagedApp] = []
    private var connected = true
    private var connectionRevision = 0
    private var busy = false
    private var mutating = false
    private var loadMessage = ""
    private var actionMessage = ""
    private let search = NSSearchField()
    private let reloadButton = NSButton(title: "", target: nil, action: nil)
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private let table = NSTableView()
    private let summary = NSTextField(labelWithString: "")
    private let notice = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "")

    init(deviceID: String, deviceName: String, language: AppLanguage, client: Client = .native) {
        self.deviceID = deviceID
        self.language = language
        self.client = client
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        fill = WorkbenchTheme.paper
        let icon = NSImageView(frame: NSRect(x: 22, y: 21, width: 35, height: 35))
        icon.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        icon.contentTintColor = WorkbenchTheme.accent
        icon.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: Self.title(language))
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = WorkbenchTheme.ink
        title.frame = NSRect(x: 68, y: 17, width: 620, height: 27)
        let target = NSTextField(labelWithString: zh ? "当前设备：\(deviceName)" : "Current device: \(deviceName)")
        target.font = .systemFont(ofSize: 12)
        target.textColor = .secondaryLabelColor
        target.toolTip = deviceID
        target.frame = NSRect(x: 68, y: 46, width: 620, height: 18)

        search.frame = NSRect(x: 22, y: 80, width: 576, height: 28)
        search.placeholderString = zh ? "搜索应用名称或包名" : "Search by app name or bundle ID"
        search.setAccessibilityLabel(search.placeholderString)
        search.setAccessibilityIdentifier("app-manager-search")
        search.delegate = self
        reloadButton.title = zh ? "刷新" : "Refresh"
        reloadButton.target = self
        reloadButton.action = #selector(reloadFromButton)
        reloadButton.frame = NSRect(x: 607, y: 77, width: 101, height: 34)
        reloadButton.setAccessibilityIdentifier("app-manager-refresh")
        closeButton.title = zh ? "关闭" : "Close"
        closeButton.target = self
        closeButton.action = #selector(closeFromButton)
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.frame = NSRect(x: 607, y: 483, width: 101, height: 33)

        let scroll = NSScrollView(frame: NSRect(x: 22, y: 117, width: 686, height: 337))
        scroll.borderType = .lineBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        table.setAccessibilityIdentifier("app-manager-table")
        table.headerView = NSTableHeaderView()
        table.usesAlternatingRowBackgroundColors = true
        table.selectionHighlightStyle = .none
        table.rowHeight = 47
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        for (id, title, width) in [
            ("app", zh ? "应用 / 包名" : "App / Bundle ID", 370.0),
            ("state", zh ? "主进程" : "Main process", 118.0),
            ("actions", zh ? "操作" : "Actions", 178.0),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.resizingMask = id == "app" ? .autoresizingMask : []
            table.addTableColumn(column)
        }
        table.delegate = self
        table.dataSource = self
        scroll.documentView = table
        empty.alignment = .center
        empty.textColor = .secondaryLabelColor
        empty.frame = NSRect(x: 39, y: 252, width: 652, height: 24)
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        summary.frame = NSRect(x: 23, y: 464, width: 681, height: 17)
        notice.font = .systemFont(ofSize: 11)
        notice.lineBreakMode = .byTruncatingTail
        notice.frame = NSRect(x: 23, y: 490, width: 576, height: 18)
        [icon, title, target, search, reloadButton, scroll, empty, summary, notice, closeButton].forEach(addSubview)
        reloadRows()
    }

    required init?(coder: NSCoder) { fatalError() }

    func focusSearch() { window?.makeFirstResponder(search) }

    func setConnected(_ connected: Bool) {
        guard self.connected != connected else { return }
        self.connected = connected
        connectionRevision += 1
        apps = []
        actionMessage = ""
        loadMessage =
            connected
            ? (zh ? "设备已重新连接，请刷新列表。" : "Device reconnected. Refresh the list.")
            : (zh ? "USB 已断开，等待原设备重新连接。" : "USB disconnected. Reconnect the original device.")
        reloadRows()
    }

    @objc private func reloadFromButton() { refresh() }
    @objc private func closeFromButton() { if !mutating { onClose?() } }

    func refresh(keepingActionMessage: Bool = false) {
        guard connected, !busy else { return }
        if !keepingActionMessage { actionMessage = "" }
        busy = true
        for i in apps.indices { apps[i].state = .unknown }
        loadMessage = zh ? "正在读取已安装应用…" : "Loading installed apps…"
        reloadRows()
        let revision = connectionRevision
        let inventory = client.inventory
        let deviceID = deviceID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try inventory(deviceID) }
            DispatchQueue.main.async { [weak self] in self?.receiveInventory(result, revision: revision) }
        }
    }

    private func receiveInventory(_ result: Result<[NativeAppInventory.Entry], Error>, revision: Int) {
        guard revision == connectionRevision else {
            finishStaleRequest()
            return
        }
        switch result {
        case .failure(let error):
            apps = []
            loadMessage = zh ? "无法读取应用列表：\(error)" : "Could not load apps: \(error)"
            busy = false
            reloadRows()
        case .success(let entries):
            apps = entries.compactMap(WorkbenchManagedApp.init)
            guard !apps.isEmpty else {
                busy = false
                loadMessage = ""
                reloadRows()
                return
            }
            loadMessage = zh ? "正在读取运行状态…" : "Checking running apps…"
            reloadRows()
            let processes = client.processes
            let deviceID = deviceID
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try processes(deviceID) }
                DispatchQueue.main.async { [weak self] in self?.receiveProcesses(result, revision: revision) }
            }
        }
    }

    private func receiveProcesses(_ result: Result<NativeAppServices.ProcessSnapshot, Error>, revision: Int) {
        guard revision == connectionRevision else {
            finishStaleRequest()
            return
        }
        busy = false
        switch result {
        case .success(let snapshot):
            for i in apps.indices { apps[i].state = snapshot.state(for: apps[i].executablePath) }
            loadMessage = ""
        case .failure(let error):
            loadMessage = zh ? "运行状态不可用：\(error)" : "Running status unavailable: \(error)"
        }
        reloadRows()
    }

    private func finishStaleRequest() {
        busy = false
        mutating = false
        reloadRows()
    }

    func operate(_ operation: NativeAppManagement.Operation, bundleID: String) {
        guard operation == .launch || operation == .terminate, connected, !busy,
            let app = apps.first(where: { $0.bundleID == bundleID }),
            operation != .terminate || app.state != .stopped
        else { return }
        busy = true
        mutating = true
        actionMessage = ""
        let launch = operation == .launch
        loadMessage =
            launch
            ? (zh ? "正在启动 \(app.name)…" : "Launching \(app.name)…")
            : (zh ? "正在结束 \(app.name)…" : "Force quitting \(app.name)…")
        reloadRows()
        let perform = client.perform
        let deviceID = deviceID
        let revision = connectionRevision
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try perform(operation, deviceID, bundleID) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard revision == self.connectionRevision else {
                    self.finishStaleRequest()
                    return
                }
                self.busy = false
                self.mutating = false
                switch result {
                case .success:
                    self.actionMessage =
                        launch
                        ? (self.zh ? "已接受启动请求：\(app.name)" : "Launch acknowledged: \(app.name)")
                        : (self.zh ? "主进程已停止：\(app.name)" : "Main process stopped: \(app.name)")
                case .failure(let error):
                    self.actionMessage =
                        self.zh ? "操作未确认，不会自动重试：\(error)" : "Action not confirmed; not retried: \(error)"
                }
                self.refresh(keepingActionMessage: true)
            }
        }
    }

    func controlTextDidChange(_ notification: Notification) { reloadRows() }

    private func reloadRows() {
        visibleApps = WorkbenchManagedApp.visible(apps, query: search.stringValue)
        table.reloadData()
        let running = apps.filter { $0.state == .running }.count
        let unknown = apps.filter { $0.state == .unknown }.count
        summary.stringValue =
            zh
            ? "显示 \(visibleApps.count)/\(apps.count) 个应用  ·  \(running) 个运行中  ·  \(unknown) 个未知"
            : "\(visibleApps.count) of \(apps.count) apps  ·  \(running) running  ·  \(unknown) unknown"
        let messages = [actionMessage, loadMessage].filter { !$0.isEmpty }
        notice.stringValue = messages.joined(separator: "  ·  ")
        notice.toolTip = notice.stringValue.isEmpty ? nil : notice.stringValue
        empty.isHidden = !visibleApps.isEmpty
        empty.stringValue =
            apps.isEmpty
            ? (!loadMessage.isEmpty ? loadMessage : (zh ? "没有应用" : "No apps"))
            : (zh ? "没有匹配的应用" : "No matching apps")
        reloadButton.isEnabled = connected && !busy
        closeButton.isEnabled = !mutating
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleApps.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard visibleApps.indices.contains(row), let column else { return nil }
        let app = visibleApps[row]
        let cell = WorkbenchSurface(frame: NSRect(x: 0, y: 0, width: column.width, height: tableView.rowHeight))
        func label(
            _ value: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular,
            color: NSColor = .labelColor
        ) {
            let text = NSTextField(labelWithString: value)
            text.font = .systemFont(ofSize: size, weight: weight)
            text.textColor = color
            text.lineBreakMode = .byTruncatingTail
            text.frame = NSRect(x: 8, y: y, width: column.width - 15, height: 18)
            text.autoresizingMask = [.width]
            text.toolTip = value
            cell.addSubview(text)
        }
        switch column.identifier.rawValue {
        case "app":
            label(app.name, y: 6, size: 13, weight: .semibold)
            label(app.bundleID, y: 25, size: 11, color: .secondaryLabelColor)
        case "state":
            switch app.state {
            case .running: label(zh ? "● 运行中" : "● Running", y: 14, size: 12, color: WorkbenchTheme.accent)
            case .stopped: label(zh ? "○ 未运行" : "○ Stopped", y: 14, size: 12, color: .secondaryLabelColor)
            case .unknown: label(zh ? "— 未知" : "— Unknown", y: 14, size: 12, color: .secondaryLabelColor)
            }
        default:
            for (operation, title, x) in [
                (NativeAppManagement.Operation.launch, zh ? "启动" : "Launch", 2.0),
                (.terminate, zh ? "强制结束" : "Force Quit", 90.0),
            ] {
                let button = WorkbenchActionButton()
                button.appearanceStyle = .outline
                button.title = title
                button.frame = NSRect(x: x, y: 10, width: 81, height: 27)
                button.setAccessibilityLabel("\(title) · \(app.name)")
                button.setAccessibilityIdentifier("app-manager-\(operation.rawValue):\(app.bundleID)")
                button.isEnabled = connected && !busy && (operation != .terminate || app.state != .stopped)
                button.invoke = { [weak self] in self?.operate(operation, bundleID: app.bundleID) }
                cell.addSubview(button)
            }
        }
        return cell
    }
}
