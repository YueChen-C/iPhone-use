import AppKit
import UniformTypeIdentifiers

/// Selects presentation only; legacy UI and both windows share the same native services.
final class WorkbenchWindowCoordinator {
    private let legacy = ControlWindowCoordinator()
    private let modeStore: AppRunModeStore
    private let legacyOnly: Bool
    private var visibility = WorkbenchVisibility()
    private var controller: WorkbenchWindowController?
    private var timer: Timer?
    private var modeObserver: NSObjectProtocol?

    init(
        modeStore: AppRunModeStore = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.modeStore = modeStore
        legacyOnly = environment["IPHONE_USE_LEGACY_UI"] == "1"
        legacy.automaticPresentationEnabled = legacyOnly
        legacy.hasCompanionWindow = { [weak self] in self?.visibility.isOpen == true }
        legacy.onDeviceWindowClosed = { [weak self] in self?.refresh() }
    }

    func start() {
        guard timer == nil else { return }
        legacy.start()
        if legacyOnly { return }
        modeObserver = NotificationCenter.default.addObserver(
            forName: AppRunModeStore.didChangeNotification, object: modeStore, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.present(reason: .resumeDesktopMode)
        }
        present(reason: .discovery)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard !QuietModeActivityController.shared.isSuspended else { return }
            self?.refresh()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func showAllDevices() {
        if legacyOnly {
            legacy.showAllDevices()
            return
        }
        present(reason: .userRequest)
        if let window = controller?.window {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func present(reason: ControlWindowUpdateReason) {
        guard visibility.shouldPresent(mode: modeStore.mode, reason: reason) else { return }
        QuietModeActivityController.shared.setOpenWindows(true)
        let controller = WorkbenchWindowController()
        self.controller = controller
        controller.onClose = { [weak self] in
            guard let self else { return }
            let shouldQuit = self.visibility.close(
                mode: self.modeStore.mode, hasIndependentWindows: self.legacy.hasOpenWindows)
            self.controller = nil
            QuietModeActivityController.shared.setOpenWindows(self.legacy.hasOpenWindows)
            if shouldQuit { NSApplication.shared.terminate(nil) }
        }
        controller.root.onIndependent = { [weak self] id in
            guard let self, let device = DeviceRegistry.shared.all().first(where: { $0.id == id }) else { return }
            self.legacy.showDevice(device)
            self.refresh()
        }
        controller.root.onCloseIndependent = { [weak self] id in self?.legacy.closeDevice(id: id) }
        refresh()
        controller.showWindow(nil)
    }

    private func refresh() {
        controller?.root.refresh(devices: DeviceRegistry.shared.all(), independentIDs: legacy.openDeviceIDs)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let modeObserver { NotificationCenter.default.removeObserver(modeObserver) }
        modeObserver = nil
        controller?.stop()
        controller = nil
        legacy.stop()
    }
    deinit {
        timer?.invalidate()
        if let modeObserver { NotificationCenter.default.removeObserver(modeObserver) }
    }
}

final class WorkbenchWindowController: NSWindowController, NSWindowDelegate {
    let root: WorkbenchRootView
    var onClose: (() -> Void)?
    private var languageObserver: NSObjectProtocol?

    init() {
        root = WorkbenchRootView(frame: NSRect(x: 0, y: 0, width: 1440, height: 850))
        let window = NSWindow(
            contentRect: root.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "iPhone Use 2.0 — \(StringsWorkbench.current.title)"
        window.contentMinSize = NSSize(width: 1080, height: 700)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.acceptsMouseMovedEvents = true
        window.contentView = root
        window.setFrameAutosaveName("iPhoneUse.Workbench2")
        window.center()
        super.init(window: window)
        window.delegate = self
        root.active = true
        languageObserver = NotificationCenter.default.addObserver(
            forName: AppLanguageStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.root.refreshLocalization()
            self?.window?.title = "iPhone Use 2.0 — \(StringsWorkbench.current.title)"
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowDidResignKey(_ notification: Notification) { root.cancelInteractions() }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        root.active = window?.occlusionState.contains(.visible) == true && window?.isMiniaturized == false
    }
    func windowDidMiniaturize(_ notification: Notification) { root.active = false }
    func windowDidDeminiaturize(_ notification: Notification) { root.active = true }
    func windowWillClose(_ notification: Notification) {
        stop()
        onClose?()
    }
    func stop() {
        root.active = false
        root.stop()
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
        languageObserver = nil
    }
}

/// The view can also render explicit offline fixtures without instantiating any hardware owner.
final class WorkbenchRootView: WorkbenchSurface, NSSearchFieldDelegate, NSTextFieldDelegate {
    var onIndependent: ((String) -> Void)?
    var onCloseIndependent: ((String) -> Void)?
    var active = false { didSet { updateActivity() } }
    private(set) var state = WorkbenchState()
    private let preview: Bool
    private var controllers: [String: ControlWindowController] = [:]
    private var cards: [String: WorkbenchPhoneCard] = [:]
    private var liveDevices: [String: Device] = [:]
    private var recordings: [String: ScreenVideoRecording] = [:]
    private var isStopped = false
    private var independentIDs: Set<String> = []
    private var previewImages: [String: NSImage] = [:]
    private var previewOrder: [String] = []
    private var previewGuidance: [String: ControlConnectionOverlay] = [:]
    private var mountedGuidance: ControlConnectionOverlay?
    private(set) var infoOverlay: WorkbenchInfoOverlay?
    private weak var infoPreviousResponder: NSResponder?
    private var presentationDevices: [WorkbenchDevice] {
        guard preview else { return state.matching }
        let positions = Dictionary(uniqueKeysWithValues: previewOrder.enumerated().map { ($0.element, $0.offset) })
        return state.matching.sorted { positions[$0.id, default: Int.max] < positions[$1.id, default: Int.max] }
    }
    private var drafts: [String: String] = [:]
    /// Monotonic per-device draft revisions make an async send completion
    /// conditional on the exact draft that was submitted.  Comparing only the
    /// string is insufficient: the user may cancel/switch and type the same
    /// bytes again before the old callback returns.
    private var draftRevisions: [String: UInt64] = [:]
    private var listFingerprint = ""
    private var isUpdating = false
    private var message = ""
    private var textBusyIDs: Set<String> = []
    private let sidebar = WorkbenchSurface()
    private let inspector = WorkbenchSurface()
    private let inspectorScroll = NSScrollView()
    private let brandIcon = NSImageView()
    private let version = WorkbenchStyle.label(size: 10)
    private let breadcrumb = WorkbenchStyle.label(size: 12, secondary: true)
    private let connectionGuide = WorkbenchHelpCard(frame: .zero)
    private let sidebarNote = WorkbenchStyle.label(size: 11, secondary: true)
    private let localService = WorkbenchStyle.label(size: 11, secondary: true)
    private let serviceAddress = WorkbenchStyle.label(size: 10, secondary: true)
    private let navigationHeading = WorkbenchStyle.label(size: 10, secondary: true)
    private var hardwareIdentities: [String: WorkbenchHardwareIdentity] = [:]
    private var hardwareLookups: [String: ObjectIdentifier] = [:]
    private let canvas = WorkbenchSurface()
    private let listScroll = NSScrollView()
    private let listDocument = WorkbenchSurface()
    private let scroll = NSScrollView()
    private let document = WorkbenchSurface()
    private let search = NSSearchField()
    private let languageControl = WorkbenchSegmentedControl(
        labels: AppLanguage.allCases.map(\.displayName), trackingMode: .selectOne, target: nil, action: nil)
    private let titleLabel = WorkbenchStyle.label(size: 25, weight: .semibold)
    private let subtitleLabel = WorkbenchStyle.label(size: 12, secondary: true)
    private let brand = WorkbenchStyle.label(size: 17, weight: .semibold)
    private let deviceTitle = WorkbenchStyle.label(size: 12, weight: .medium, secondary: true)
    private let selectedTitle = WorkbenchStyle.label(size: 17, weight: .semibold)
    private let targetHint = WorkbenchStyle.label(size: 10, secondary: true)
    private let connection = WorkbenchStyle.label(size: 11, secondary: true)
    private let status = WorkbenchStyle.label(size: 11, secondary: true)
    private let empty = WorkbenchStyle.label(size: 17, secondary: true)
    private let footer = WorkbenchStyle.label(size: 10, secondary: true)
    private let targetChip = WorkbenchStyle.label(size: 9, secondary: true)
    private let deviceDetail = WorkbenchStyle.label(size: 10, secondary: true)
    private let captureTitle = WorkbenchStyle.label(size: 10, secondary: true)
    private let inputReady = WorkbenchStyle.label(size: 9, secondary: true)
    private let textHint = WorkbenchStyle.label(size: 9, secondary: true)
    private let controlHint = WorkbenchStyle.label(size: 9, secondary: true)
    private let aiCard = WorkbenchHelpCard(frame: .zero)
    private let textBackground = WorkbenchRoundedSurface()
    private let inspectorRule = WorkbenchSurface()
    private let backendTitle = WorkbenchStyle.label(size: 12, weight: .semibold)
    private let controlsTitle = WorkbenchStyle.label(size: 12, weight: .semibold)
    private let textTitle = WorkbenchStyle.label(size: 12, weight: .semibold)
    private let help = WorkbenchStyle.label(size: 10, secondary: true)
    private let backendHelp = WorkbenchStyle.label(size: 10, secondary: true)
    private let backend = WorkbenchSegmentedControl(
        labels: ["Bluetooth", "USB Touch"], trackingMode: .selectOne, target: nil, action: nil)
    private let layoutControl = WorkbenchSegmentedControl(
        labels: ["", ""], trackingMode: .selectOne, target: nil, action: nil)
    private let connectionCount = WorkbenchStyle.label(size: 10, secondary: true)
    private let canvasHint = WorkbenchStyle.label(size: 10, secondary: true)
    private let pageLabel = WorkbenchStyle.label(size: 10, secondary: true)
    private let pagePrevious = WorkbenchActionButton()
    private let pageNext = WorkbenchActionButton()
    private let interactionHint = WorkbenchStyle.label(size: 10, secondary: true)
    private let bottomNote = WorkbenchStyle.label(size: 10, secondary: true)
    private let connect = WorkbenchActionButton()
    private let workspace = WorkbenchActionButton()
    private let ai = WorkbenchActionButton()
    private let api = WorkbenchActionButton()
    private let guide = WorkbenchActionButton()
    private let send = WorkbenchActionButton()
    private let paste = WorkbenchActionButton()
    private let text = NSTextField()
    private var shortcutButtons: [ControlShortcut: WorkbenchActionButton] = [:]
    private var rowButtons: [WorkbenchActionButton] = []
    private var scrollObserver: NSObjectProtocol?

    init(frame: NSRect, preview: Bool = false) {
        self.preview = preview
        super.init(frame: frame)
        fill = WorkbenchTheme.header
        sidebar.fill = WorkbenchTheme.sidebar
        inspector.fill = WorkbenchTheme.paper
        canvas.fill = WorkbenchTheme.canvas
        [
            sidebar, canvas, inspectorScroll, brandIcon, brand, version, breadcrumb, search, languageControl, footer,
        ].forEach(addSubview)
        inspectorScroll.documentView = inspector
        inspectorScroll.hasVerticalScroller = true
        inspectorScroll.drawsBackground = false
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            ?? Bundle.module.url(forResource: "AppIcon", withExtension: "icns")
        {
            brandIcon.image = NSImage(contentsOf: url)
        }
        brandIcon.imageScaling = .scaleProportionallyUpOrDown
        [
            navigationHeading, workspace, ai, api, deviceTitle, listScroll, connectionGuide, sidebarNote, localService,
            serviceAddress,
        ].forEach(sidebar.addSubview)
        [
            titleLabel, subtitleLabel, connectionCount, canvasHint, interactionHint, bottomNote, connect, layoutControl,
            scroll, empty, pageLabel, pagePrevious, pageNext,
        ].forEach(canvas.addSubview)
        [
            selectedTitle, targetHint, targetChip, deviceDetail, captureTitle, connection, status,
            backendTitle, backend, backendHelp, controlsTitle, inputReady, controlHint,
            textTitle, textHint, textBackground, text, send, paste, help, aiCard, inspectorRule,
        ].forEach(inspector.addSubview)
        listScroll.documentView = listDocument
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        scroll.documentView = document
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in self?.updateActivity() }
        for (button, symbol) in [(workspace, "square.grid.2x2"), (ai, "shippingbox"), (api, "terminal")] {
            button.appearanceStyle = .navigation
            button.symbolName = symbol
            button.alignment = .left
            button.font = .systemFont(ofSize: 13)
        }
        workspace.retainsSelection = true
        workspace.state = .on
        ai.badge = "MCP"
        if let cell = search.cell as? NSSearchFieldCell { cell.searchButtonCell = nil }
        search.isBezeled = false
        search.drawsBackground = false
        search.font = .systemFont(ofSize: 11)
        search.focusRingType = .none
        search.delegate = self
        languageControl.segmentDistribution = .fillEqually
        languageControl.target = self
        languageControl.action = #selector(changeLanguage)
        languageControl.setAccessibilityIdentifier("workbench-language")
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        text.delegate = self
        text.isEditable = true
        text.isSelectable = true
        textBackground.fill = WorkbenchTheme.soft
        inspectorRule.fill = WorkbenchTheme.line
        text.bezelStyle = .squareBezel
        text.isBezeled = false
        text.drawsBackground = false
        text.font = .systemFont(ofSize: 11)
        text.textColor = WorkbenchTheme.ink
        text.focusRingType = .none
        text.maximumNumberOfLines = 0
        text.lineBreakMode = .byWordWrapping
        help.maximumNumberOfLines = 0
        help.lineBreakMode = .byWordWrapping
        backendHelp.maximumNumberOfLines = 0
        backendHelp.lineBreakMode = .byWordWrapping
        // Native hit regions must match the equally divided custom segment drawing.
        backend.segmentDistribution = .fillEqually
        layoutControl.segmentDistribution = .fillEqually
        backend.symbols = ["wave.3.right", "cable.connector"]
        backend.target = self
        backend.action = #selector(changeBackend)
        connect.appearanceStyle = .outline
        connect.symbolName = "plus"
        connect.font = .systemFont(ofSize: 11)
        layoutControl.symbols = ["square.grid.2x2", "rectangle.center.inset.filled"]
        layoutControl.target = self
        layoutControl.action = #selector(changeLayout)
        layoutControl.selectedSegment = 0
        for (button, symbol, id) in [
            (pagePrevious, "chevron.left", "workbench-page-previous"),
            (pageNext, "chevron.right", "workbench-page-next"),
        ] {
            button.appearanceStyle = .outline
            button.symbolName = symbol
            button.setAccessibilityIdentifier(id)
        }
        pagePrevious.invoke = { [weak self] in self?.changePage(-1) }
        pageNext.invoke = { [weak self] in self?.changePage(1) }
        pageLabel.alignment = .center
        connect.invoke = { [weak self] in self?.showInfo(.guide) }
        guide.invoke = connect.invoke
        connectionGuide.action.invoke = connect.invoke
        sidebarNote.maximumNumberOfLines = 0
        sidebarNote.lineBreakMode = .byWordWrapping
        workspace.invoke = { [weak self] in self?.setLayout(.grid) }
        ai.invoke = { [weak self] in self?.showInfo(.mcp) }
        aiCard.action.invoke = ai.invoke
        aiCard.symbolName = "shippingbox"
        send.appearanceStyle = .solid
        send.symbolName = "arrow.right"
        send.font = .systemFont(ofSize: 10)
        paste.appearanceStyle = .plain
        paste.symbolName = "doc.on.clipboard"
        paste.font = .systemFont(ofSize: 10)
        paste.alignment = .left
        api.invoke = { [weak self] in self?.showInfo(.api) }
        send.invoke = { [weak self] in self?.sendText() }
        paste.invoke = { [weak self] in self?.perform(.paste) }
        let shortcuts: [ControlShortcut] = [.home, .search, .power, .volumeDown, .volumeUp, .enter, .inputMethod]
        for shortcut in shortcuts {
            let button = WorkbenchActionButton()
            button.image = NSImage(systemSymbolName: shortcut.symbol, accessibilityDescription: nil)
            button.imagePosition = .imageAbove
            button.bezelStyle = .regularSquare
            button.appearanceStyle = shortcut == .inputMethod ? .outline : .shortcut
            button.symbolName = shortcut.symbol
            button.setAccessibilityIdentifier("workbench-shortcut:\(shortcut.rawValue)")
            button.invoke = { [weak self] in self?.perform(shortcut) }
            inspector.addSubview(button)
            shortcutButtons[shortcut] = button
        }
        refreshLocalization()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }

    func refresh(devices: [Device], independentIDs: Set<String>) {
        guard !preview else { return }
        isUpdating = true
        defer { isUpdating = false }
        liveDevices = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        self.independentIDs = independentIDs
        for device in devices where controllers[device.id] == nil {
            let controller = ControlWindowController(deviceID: device.id, name: device.screen.name, embedded: true)
            controllers[device.id] = controller
            let card = makeCard(id: device.id, name: device.screen.name, content: controller.embeddedView)
            cards[device.id] = card
            controller.controlView.onInteraction = { [weak self] in self?.select(device.id, focusPhone: false) }
            controller.onPresentationChanged = { [weak self] in
                guard let self, !self.isUpdating else { return }
                self.refreshPresentation()
            }
        }
        for (id, controller) in controllers { controller.updateDevice(liveDevices[id]) }
        for device in devices { requestHardwareIdentity(device) }
        state.reconcile(
            devices.map { device in
                WorkbenchDevice(
                    id: device.id, name: device.screen.name, connected: true,
                    backend: USBInputController.shared.selected(device.id),
                    status: controllers[device.id]?.inputStatus ?? StringsWorkbench.current.waitingInput,
                    shortcuts: independentIDs.contains(device.id)
                        ? [] : (controllers[device.id]?.availableShortcuts ?? []),
                    detail: hardwareIdentities[device.id].map { "\($0.displayName) · iOS \($0.productVersion)" } ?? "",
                    screenSize: device.screen.size, productType: hardwareIdentities[device.id]?.productType)
            })
        render()
    }

    private func requestHardwareIdentity(_ device: Device) {
        let capture = ObjectIdentifier(device.screen)
        guard hardwareLookups[device.id] != capture else { return }
        hardwareLookups[device.id] = capture
        // A capture remap/reconnect does not change the physical phone model.
        // Keep its known enclosure until the fresh full-ID lookup completes.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let identity = WorkbenchHardwareIdentity.read(physicalID: device.id, executable: executable)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.hardwareLookups[device.id] == capture,
                    self.liveDevices[device.id]?.screen === device.screen
                else { return }
                if let identity {
                    self.hardwareIdentities[device.id] = identity
                    if USBInputController.shared.applyDefault(physicalID: device.id, version: identity.productVersion) {
                        USBInputController.shared.refresh(device)
                    }
                }
                self.refreshPresentation()
            }
        }
    }

    func loadPreview(
        _ devices: [WorkbenchDevice], images: [String: NSImage] = [:], rawScreens: Bool = false,
        connectionStatuses: [String: ControlConnectionStatus] = [:], independentIDs: Set<String> = []
    ) {
        guard preview else { return }
        self.independentIDs = independentIDs
        state.reconcile(devices)
        previewImages = images
        previewOrder = devices.map(\.id)
        for (id, status) in connectionStatuses {
            let guidance = previewGuidance[id] ?? ControlConnectionOverlay(frame: .zero, presentation: .inspector)
            guidance.update(status)
            previewGuidance[id] = guidance
        }
        for device in devices where cards[device.id] == nil {
            let view = NSImageView()
            view.imageScaling = .scaleProportionallyUpOrDown
            view.image = images[device.id]
            cards[device.id] = makeCard(id: device.id, name: device.name, content: view, showsShell: rawScreens)
        }
        render()
    }

    private func makeCard(id: String, name: String, content: NSView, showsShell: Bool = true) -> WorkbenchPhoneCard {
        let card = WorkbenchPhoneCard(content: content, showsShell: showsShell)
        card.onSelect = { [weak self] in self?.select(id) }
        card.onScreenshot = { [weak self] in self?.saveScreenshot(id) }
        card.onRecording = { [weak self] in self?.toggleRecording(id) }
        card.onFocus = { [weak self] in
            self?.select(id)
            self?.setLayout(.focus)
        }
        card.onWindowAction = { [weak self] in self?.performCardAction(id) }
        document.addSubview(card)
        return card
    }

    private func performCardAction(_ id: String) {
        guard let device = state.devices.first(where: { $0.id == id }) else { return }
        if !device.connected {
            removeDisconnectedCard(id)
        } else if independentIDs.contains(id) {
            onCloseIndependent?(id)
        } else {
            controllers[id]?.stop()
            onIndependent?(id)
        }
    }

    private func removeDisconnectedCard(_ id: String) {
        // A rediscovery can land between the timer snapshot and a click.
        guard preview || !ScreenCaptureManager.shared.all.contains(where: { $0.id == id }) else { return }
        let wasSelected = state.selectedID == id
        guard state.removeDisconnected(id) else { return }
        if let controller = controllers.removeValue(forKey: id) {
            controller.onPresentationChanged = nil
            controller.stop()
        }
        cards.removeValue(forKey: id)?.removeFromSuperview()
        hardwareLookups.removeValue(forKey: id)
        hardwareIdentities.removeValue(forKey: id)
        previewGuidance.removeValue(forKey: id)
        if wasSelected {
            window?.makeFirstResponder(nil)
            text.stringValue = state.selectedID.flatMap { drafts[$0] } ?? ""
            message = ""
        }
        if independentIDs.contains(id) { onCloseIndependent?(id) }
        render()
    }

    private func refreshPresentation() {
        refresh(devices: Array(liveDevices.values), independentIDs: independentIDs)
    }

    private func render() {
        let capacity = min(3, max(1, Int((bounds.width - 576) / 356)))
        if state.pageCapacity != capacity { state.setPageCapacity(capacity) }
        let fingerprint =
            presentationDevices.map { "\($0.id):\($0.name):\($0.status):\($0.connected)" }.joined(separator: "|")
            + (state.selectedID ?? "")
        if listFingerprint != fingerprint {
            listFingerprint = fingerprint
            for button in rowButtons { button.removeFromSuperview() }
            rowButtons = []
            for device in presentationDevices {
                let button = WorkbenchDeviceRow(
                    device: device, selected: device.id == state.selectedID, thumbnail: previewImages[device.id])
                button.invoke = { [weak self] in self?.select(device.id) }
                listDocument.addSubview(button)
                rowButtons.append(button)
            }
        }
        for device in state.devices {
            cards[device.id]?.update(
                device, selected: device.id == state.selectedID, inSeparateWindow: independentIDs.contains(device.id),
                recording: recordings[device.id], canRecord: !preview && device.connected)
            cards[device.id]?.isHidden = !state.visible.contains { $0.id == device.id }
        }
        let physicalCount = preview ? nil : ScreenCaptureManager.shared.observedUSBTopology.attachedDeviceCount
        empty.isHidden = !state.visible.isEmpty
        empty.stringValue =
            state.devices.isEmpty
            ? ((physicalCount ?? 0) > 0 ? StringsWorkbench.current.waitingNativeCapture : StringsWorkbench.current.noDevice)
            : StringsWorkbench.current.noMatches
        selectedTitle.stringValue = state.selected?.name ?? "—"
        selectedTitle.toolTip = state.selectedID
        let t = StringsWorkbench.current
        let zh = AppLanguageStore.shared.language == .zh
        connection.stringValue =
            state.selected.map { $0.connected ? (zh ? "●  USB · 已连接" : "●  USB · Connected") : t.disconnected } ?? "—"
        connection.textColor = WorkbenchTheme.green
        deviceDetail.stringValue = state.selected.map { $0.detail.isEmpty ? "USB · \(t.usbPicture)" : $0.detail } ?? "—"
        inputReady.stringValue =
            state.selected?.shortcuts.isEmpty == false ? (zh ? "已就绪" : "Ready") : (zh ? "待配置" : "Not ready")
        inputReady.textColor = state.selected?.shortcuts.isEmpty == false ? WorkbenchTheme.faint : WorkbenchTheme.amber
        status.isHidden = true
        status.stringValue =
            state.selected.map { independentIDs.contains($0.id) ? t.independent : $0.status } ?? t.waitingInput
        let captureCount = state.devices.filter(\.connected).count
        let count = physicalCount ?? captureCount
        workspace.badge = "\(count)"
        deviceTitle.stringValue = "\(StringsWorkbench.current.devices)  \(count)"
        let summary = zh ? "●  \(count) 台 USB 已连接" : "●  \(count) USB connected"
        connectionCount.stringValue = count > 0 && captureCount == 0
            ? summary + (zh ? " · 等待画面" : " · Waiting for capture") : summary
        backend.selectedSegment = state.selected?.backend == .usb ? 1 : 0
        pagePrevious.isHidden = state.pageCount <= 1
        pageNext.isHidden = state.pageCount <= 1
        pageLabel.isHidden = state.pageCount <= 1
        pagePrevious.isEnabled = state.hasPreviousPage
        pageNext.isEnabled = state.hasNextPage
        pageLabel.stringValue = "\(state.pageIndex + 1) / \(state.pageCount)"
        canvasHint.isHidden = state.pageCount > 1
        updateActivity()
        let currentController = state.selectedID.flatMap { controllers[$0] }
        let guidance = state.selectedID.flatMap { preview ? previewGuidance[$0] : controllers[$0]?.connectionGuidanceView }
        if mountedGuidance !== guidance {
            mountedGuidance?.onLayoutChanged = nil
            mountedGuidance?.removeFromSuperview()
            mountedGuidance = guidance
            if let guidance {
                guidance.translatesAutoresizingMaskIntoConstraints = true
                guidance.setAccessibilityIdentifier("connection-guidance:\(state.selectedID ?? "")")
                guidance.onLayoutChanged = { [weak self] in self?.needsLayout = true }
                inspector.addSubview(guidance)
            }
        }
        let targetReady =
            !preview && currentController?.controlView.isKeyboardTarget == true
            && state.selected?.connected == true
        let available = targetReady ? (currentController?.availableShortcuts ?? []) : []
        backend.isEnabled = targetReady
        for (shortcut, button) in shortcutButtons {
            button.isEnabled = available.contains(shortcut)
            button.drawsDisabledAsReady = preview && state.selected?.shortcuts.contains(shortcut) == true
        }
        paste.isEnabled = available.contains(.paste)
        send.isEnabled =
            available.contains(.enter) && !text.stringValue.isEmpty && !textBusyIDs.contains(state.selectedID ?? "")
        footer.stringValue =
            message.isEmpty
            ? (preview
                ? t.preview : "\(t.local) · 127.0.0.1:\(Self.port)   |   \(t.current): \(state.selected?.name ?? "—")")
            : message
        needsLayout = true
        updateActivity()
    }

    func select(_ id: String, focusPhone: Bool = true) {
        guard state.devices.contains(where: { $0.id == id }) else { return }
        if state.selectedID != id {
            if let previous = state.selectedID {
                drafts[previous] = text.stringValue
                draftRevisions[previous, default: 0] &+= 1
            }
            cancelInteractions()
            _ = state.select(id)
            text.stringValue = drafts[id] ?? ""
            message = ""
        }
        _ = state.select(id)
        render()
        if focusPhone { window?.makeFirstResponder(controllers[id]?.controlView) }
    }

    func setLayout(_ layout: WorkbenchState.Layout) {
        cancelInteractions()
        state.layout = layout
        layoutControl.selectedSegment = layout == .grid ? 0 : 1
        render()
    }
    func changePage(_ offset: Int) {
        guard let target = state.pageTarget(offset: offset) else { return }
        select(target, focusPhone: false)
    }
    @objc private func changeLanguage() {
        let languages = AppLanguage.allCases
        guard languages.indices.contains(languageControl.selectedSegment) else { return }
        AppLanguageStore.shared.set(languages[languageControl.selectedSegment])
    }

    @objc private func changeLayout() { setLayout(layoutControl.selectedSegment == 1 ? .focus : .grid) }
    @objc private func changeBackend() {
        guard let id = state.selectedID, let controller = controllers[id] else { return }
        controller.selectInputBackend(backend.selectedSegment == 1 ? .usb : .ble)
        backend.selectedSegment = controller.controlView.selectedBackend == .usb ? 1 : 0
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === search {
            state.query = search.stringValue
            render()
        } else if notification.object as? NSTextField === text {
            if let id = state.selectedID {
                drafts[id] = text.stringValue
                draftRevisions[id, default: 0] &+= 1
            }
            render()
        }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let infoOverlay {
            if event.keyCode == 53 { dismissInfo(); return true }
            if event.keyCode == 48 { window?.makeFirstResponder(infoOverlay.card.close); return true }
            return super.performKeyEquivalent(with: event)
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "k" {
            cancelInteractions()
            window?.makeFirstResponder(search)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func perform(_ shortcut: ControlShortcut) {
        guard !preview, let id = state.selectedID, state.selected?.shortcuts.contains(shortcut) == true,
            let controller = controllers[id]
        else { return }
        window?.makeFirstResponder(controller.controlView)
        controller.controlView.performShortcut(shortcut)
    }

    private func sendText() {
        guard send.isEnabled, let id = state.selectedID, let controller = controllers[id] else { return }
        let value = text.stringValue
        let draftRevision = draftRevisions[id, default: 0]
        textBusyIDs.insert(id)
        window?.makeFirstResponder(controller.controlView)
        render()
        controller.controlView.sendText(value) { [weak self] result in
            guard let self else { return }
            self.textBusyIDs.remove(id)
            switch result {
            case .success:
                // Do not clear a newer draft, even if it happens to contain
                // exactly the same text as the request that just completed.
                if self.draftRevisions[id, default: 0] == draftRevision, self.drafts[id] == value {
                    self.drafts[id] = ""
                    self.draftRevisions[id, default: 0] &+= 1
                    if self.state.selectedID == id, self.text.stringValue == value { self.text.stringValue = "" }
                }
                if self.state.selectedID == id {
                    self.message = "\(StringsWorkbench.current.textSent) · \(self.cards[id]?.deviceName ?? id)"
                }
            case .failure(let error):
                if self.state.selectedID == id {
                    self.message = "\(StringsWorkbench.current.actionFailed) · \(self.cards[id]?.deviceName ?? id): \(error)"
                }
            }
            self.render()
        }
    }

    private func saveScreenshot(_ id: String) {
        guard !preview, let device = liveDevices[id] else { return }
        cancelInteractions()
        let manager = ScreenCaptureManager.shared
        let isCurrent = { manager.isCurrent(device.screen) }
        let identityConfirmed = {
            manager.identityState == .singleDevice || manager.identityVerified(for: device.screen)
        }
        do {
            try WorkbenchScreenshotCapture.validate(isCurrent: isCurrent, identityConfirmed: identityConfirmed)
        } catch {
            message = error.localizedDescription
            render()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "iPhoneUse-\(id)-\(Date().timeIntervalSince1970.rounded()).png"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result<Void, Error> {
                    let bytes = try WorkbenchScreenshotCapture.capture(
                        isCurrent: isCurrent, identityConfirmed: identityConfirmed,
                        snapshot: { device.screen.snapshot(png: true) })
                    try bytes.write(to: url, options: .atomic)
                }
                DispatchQueue.main.async {
                    self?.message =
                        result.failureDescription ?? "\(StringsWorkbench.current.screenshot): \(url.lastPathComponent)"
                    self?.render()
                }
            }
        }
    }

    private func toggleRecording(_ id: String) {
        if let recording = recordings[id] {
            recording.finish()
            render()
            return
        }
        guard !preview, !isStopped, let device = liveDevices[id], let window, window.attachedSheet == nil else { return }
        cancelInteractions()
        let manager = ScreenCaptureManager.shared
        guard manager.permitsPointerAssociation(for: device.screen) else {
            message = StringsWorkbench.current.recordingIdentityUnverified
            render()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "iPhoneUse-\(id)-\(Int(Date().timeIntervalSince1970)).mp4"
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, !self.isStopped, result == .OK, let url = panel.url else { return }
            do {
                self.recordings[id] = try manager.startRecording(screen: device.screen, destination: url) { [weak self] result in
                    guard let self else { return }
                    self.recordings.removeValue(forKey: id)
                    guard !self.isStopped else { return }
                    let text = StringsWorkbench.current
                    switch result {
                    case .success(let saved): self.message = "\(text.recordingSaved) · \(saved.lastPathComponent)"
                    case .failure(let error): self.message = "\(text.recordingFailed) · \(error.localizedDescription)"
                    }
                    self.render()
                }
                self.message = ""
            } catch {
                self.message = "\(StringsWorkbench.current.recordingFailed) · \(error.localizedDescription)"
            }
            self.render()
        }
    }

    func cancelInteractions() {
        for controller in controllers.values { controller.controlView.cancelInteraction() }
    }
    private func updateActivity() {
        for (id, controller) in controllers {
            let visible = cards[id].map { !$0.isHidden && $0.frame.intersects(scroll.contentView.bounds) } ?? false
            let shouldRun = WorkbenchRenderPolicy.shouldRun(
                active: active, visible: visible, independent: independentIDs.contains(id))
            controller.controlView.isKeyboardTarget = shouldRun && infoOverlay == nil && state.selectedID == id
            controller.controlView.isPointerTarget = shouldRun && infoOverlay == nil && state.selectedID == id
            if shouldRun && !controller.controlView.isRendering {
                controller.controlView.start()
            } else if !shouldRun && controller.controlView.isRendering {
                controller.stop()
            }
        }
    }
    func stop() {
        isStopped = true
        recordings.values.forEach { $0.finish() }
        dismissInfo()
        for controller in controllers.values { controller.stop() }
    }

    func refreshLocalization() {
        let t = StringsWorkbench.current
        brand.stringValue = "iPhone Use"
        version.stringValue = "2.0"
        breadcrumb.stringValue =
            AppLanguageStore.shared.language == .zh ? "工作空间    ›    设备工作台" : "Workspace    ›    Device Workbench"
        navigationHeading.stringValue = AppLanguageStore.shared.language == .zh ? "工 作 空 间" : "WORKSPACE"
        let language = AppLanguageStore.shared.language
        let languageLabel = language == .zh ? "界面语言" : "Interface language"
        languageControl.selectedSegment = AppLanguage.allCases.firstIndex(of: language) ?? 0
        languageControl.setAccessibilityLabel(languageLabel)
        languageControl.toolTip = languageLabel
        languageControl.needsDisplay = true
        titleLabel.stringValue = t.title
        subtitleLabel.stringValue = t.subtitle
        deviceTitle.stringValue = "\(t.devices)  \(state.devices.filter(\.connected).count)"
        let zh = language == .zh
        sidebarNote.stringValue =
            zh ? "每台设备独立选择输入方式。\n画面始终通过 USB 连接。" : "Choose input for each device.\nDisplay always connects via USB."
        connectionGuide.heading.stringValue = zh ? "第一次连接？" : "First connection?"
        connectionGuide.body.stringValue =
            zh ? "USB 连接并信任此 Mac，\n再完成输入方式设置。" : "Connect USB and trust this Mac.\nThen set up device input."
        connectionGuide.action.title = zh ? "查看连接指南  →" : "Connection guide  →"
        localService.stringValue = zh ? "●  本地服务" : "●  Local service"
        serviceAddress.stringValue = "127.0.0.1:\(Self.port)"
        targetHint.stringValue = t.current
        targetChip.stringValue = zh ? "仅作用于此设备" : "This device only"
        targetChip.textColor = WorkbenchTheme.green
        captureTitle.stringValue = zh ? "画面连接" : "Display connection"
        controlHint.stringValue = zh ? "当前设备" : "Current device"
        controlHint.alignment = .right
        inputReady.alignment = .right
        textHint.stringValue = zh ? "发送至当前设备" : "Send to current device"
        textHint.alignment = .right
        aiCard.heading.stringValue = zh ? "让 AI 接入你的 iPhone" : "Connect AI to your iPhone"
        aiCard.body.stringValue =
            zh
            ? "通过 Codex、Claude 等外部客户端，\n调用截图、点击、滑动与输入工具。"
            : "Use screenshots, taps, swipes and text\nthrough your external MCP client."
        aiCard.action.title = zh ? "查看接入配置                          →" : "Connection setup                       →"
        backendTitle.stringValue = t.inputBackend
        backendHelp.stringValue =
            zh
            ? "蓝牙 HID 负责鼠标与键盘输入。\nUSB Touch 需 iOS 17+ 与兼容的开发者服务；失败不自动回退。"
            : "Bluetooth HID handles mouse and keyboard.\nUSB Touch requires iOS 17+ and compatible services; no automatic fallback."
        controlsTitle.stringValue = AppLanguageStore.shared.language == .zh ? "快捷控制" : "Quick controls"
        textTitle.stringValue = t.textInput
        text.placeholderString = zh ? "输入要发送到 iPhone 的文字…" : "Enter text to send to iPhone…"
        connect.title = t.connect
        canvasHint.stringValue = zh ? "♧ 点击画面即可操控     ⌘ 快捷键" : "Click screen to control     ⌘ Shortcuts"
        interactionHint.stringValue = zh ? "♧  点击、拖动或滚轮滑动，直接操作手机" : "Click, drag or scroll to control your iPhone"
        bottomNote.stringValue =
            zh
            ? "♢  在你的 Mac 上连接与控制，无需越狱，也无需在 iPhone 安装应用。"
            : "Connect and control on your Mac. No jailbreak or iPhone app required."
        workspace.title = t.title
        ai.title = t.ai
        api.title = t.api
        guide.title = "↗ \(t.connect)"
        search.placeholderString = t.search
        search.setAccessibilityLabel(t.search)
        text.setAccessibilityLabel(t.textInput)
        layoutControl.setLabel(t.grid, forSegment: 0)
        layoutControl.setLabel(t.focus, forSegment: 1)
        pagePrevious.setAccessibilityLabel(zh ? "上一页设备" : "Previous devices")
        pageNext.setAccessibilityLabel(zh ? "下一页设备" : "Next devices")
        pagePrevious.toolTip = zh ? "上一页设备" : "Previous devices"
        pageNext.toolTip = zh ? "下一页设备" : "Next devices"
        backend.setLabel(zh ? "蓝牙" : "Bluetooth", forSegment: 0)
        backend.setLabel(zh ? "USB Touch · 实验性" : "USB Touch · Exp.", forSegment: 1)
        send.title = t.send
        paste.title = zh ? "手机端粘贴" : "Paste on phone"
        help.stringValue = t.pasteHint
        for (shortcut, button) in shortcutButtons {
            button.title = zh && shortcut == .home ? "主屏幕" : shortcut.title
            button.toolTip = shortcut.help
            button.setAccessibilityLabel(shortcut.title)
        }
        listFingerprint = ""
        if let kind = infoOverlay?.kind { showInfo(kind) }
        render()
    }

    override func layout() {
        super.layout()
        let capacity = max(1, Int((bounds.width - 576) / 356))
        if state.pageCapacity != min(3, capacity) { render() }
        let w = bounds.width
        let h = bounds.height
        brandIcon.frame = NSRect(x: 100, y: 17, width: 34, height: 30)
        brand.frame = NSRect(x: 143, y: 22, width: 98, height: 23)
        version.frame = NSRect(x: 247, y: 24, width: 29, height: 20)
        breadcrumb.isHidden = w < 1220
        breadcrumb.frame = NSRect(x: 319, y: 25, width: 300, height: 20)
        search.frame = NSRect(x: w - 417, y: 22, width: 218, height: 23)
        languageControl.frame = NSRect(x: w - 160, y: 18, width: 140, height: 29)
        navigationHeading.frame = NSRect(x: 27, y: 23, width: 175, height: 17)
        sidebar.frame = NSRect(x: 0, y: 64, width: 232, height: h - 94)
        inspectorScroll.frame = NSRect(x: w - 312, y: 64, width: 312, height: h - 94)
        let guidanceHeight = mountedGuidance?.preferredHeight(for: 268) ?? 0
        let guidanceOffset = guidanceHeight > 0 ? max(0, guidanceHeight - 42) + 12 : 0
        inspector.frame = NSRect(x: 0, y: 0, width: 312, height: max(888 + guidanceOffset, inspectorScroll.bounds.height))
        canvas.frame = NSRect(x: 232, y: 64, width: w - 544, height: h - 94)
        footer.frame = NSRect(x: 17, y: h - 24, width: w - 34, height: 18)
        workspace.frame = NSRect(x: 15, y: 48, width: 202, height: 39)
        ai.frame = NSRect(x: 15, y: 91, width: 202, height: 39)
        api.frame = NSRect(x: 15, y: 134, width: 202, height: 39)
        deviceTitle.frame = NSRect(x: 27, y: 205, width: 180, height: 22)
        let guideY = sidebar.bounds.height - 204
        connectionGuide.isHidden = guideY < 475
        sidebarNote.isHidden = guideY < 580
        connectionGuide.frame = NSRect(x: 21, y: guideY, width: 190, height: 122)
        localService.frame = NSRect(x: 26, y: guideY + 153, width: 180, height: 20)
        serviceAddress.frame = NSRect(x: 40, y: guideY + 176, width: 165, height: 18)
        listScroll.frame = NSRect(
            x: 15, y: 235, width: 202, height: min(max(84, guideY - 320), CGFloat(rowButtons.count) * 84))
        listDocument.frame = NSRect(
            x: 0, y: 0, width: 202, height: max(listScroll.bounds.height, CGFloat(rowButtons.count) * 84))
        for (i, button) in rowButtons.enumerated() {
            button.frame = NSRect(x: 0, y: CGFloat(i) * 84, width: 202, height: 79)
        }
        sidebarNote.frame = NSRect(
            x: 28, y: min(guideY - 70, 245 + listScroll.frame.height + 13), width: 180, height: 54)
        let cw = canvas.bounds.width
        let headingWidth: CGFloat = AppLanguageStore.shared.language == .zh ? 132 : 240
        titleLabel.frame = NSRect(x: 24, y: 27, width: headingWidth, height: 34)
        connectionCount.isHidden = cw < 700
        connectionCount.frame = NSRect(x: 36 + headingWidth, y: 33, width: 150, height: 22)
        canvasHint.frame = NSRect(x: max(170, cw - 245), y: 118, width: 220, height: 19)
        subtitleLabel.frame = NSRect(x: 24, y: 69, width: cw - 48, height: 22)
        let connectWidth = max(96, connect.requiredContentWidth)
        connect.frame = NSRect(x: cw - 24 - connectWidth, y: 39, width: connectWidth, height: 35)
        layoutControl.frame = NSRect(x: 24, y: 108, width: 134, height: 33)
        pagePrevious.frame = NSRect(x: cw - 154, y: 108, width: 34, height: 33)
        pageLabel.frame = NSRect(x: cw - 120, y: 115, width: 62, height: 20)
        pageNext.frame = NSRect(x: cw - 58, y: 108, width: 34, height: 33)
        scroll.frame = NSRect(x: 24, y: 156, width: cw - 48, height: max(260, canvas.bounds.height - 255))
        interactionHint.frame = NSRect(x: 26, y: scroll.frame.maxY + 18, width: cw - 52, height: 20)
        bottomNote.isHidden = h < 800
        bottomNote.frame = NSRect(x: 26, y: scroll.frame.maxY + 69, width: cw - 52, height: 20)
        empty.frame = NSRect(x: 35, y: 240, width: cw - 70, height: 80)
        empty.alignment = .center
        let ids = presentationDevices.filter { device in state.visible.contains { $0.id == device.id } }.map(\.id)
        let n = ids.count
        let cols = max(1, n)
        let availableWidth = (scroll.bounds.width - 16 * CGFloat(cols - 1) - 2) / CGFloat(cols)
        let cardWidth = state.layout == .focus ? min(480, availableWidth) : availableWidth
        let cardHeight = min(631, scroll.bounds.height)
        document.frame = NSRect(
            x: 0, y: 0, width: scroll.bounds.width - 2,
            height: scroll.bounds.height)
        for (i, id) in ids.enumerated() {
            let frame = NSRect(
                x: (state.layout == .focus ? max(0, (scroll.bounds.width - cardWidth) / 2) : 0)
                    + CGFloat(i) * (cardWidth + 16), y: 0, width: cardWidth,
                height: cardHeight)
            if cards[id]?.frame != frame { cards[id]?.frame = frame }
        }
        let iw = inspector.bounds.width
        let inner = iw - 44
        targetHint.frame = NSRect(x: 22, y: 29, width: 160, height: 18)
        targetChip.frame = NSRect(x: iw - 105, y: 29, width: 90, height: 18)
        selectedTitle.frame = NSRect(x: 22, y: 61, width: inner, height: 27)
        deviceDetail.frame = NSRect(x: 22, y: 93, width: inner, height: 18)
        inspectorRule.frame = NSRect(x: 22, y: 124, width: inner, height: 1)
        captureTitle.frame = NSRect(x: 22, y: 146, width: 116, height: 18)
        connection.frame = NSRect(x: 150, y: 146, width: iw - 172, height: 18)
        status.frame = .zero
        backendTitle.frame = NSRect(x: 22, y: 184, width: 140, height: 21)
        inputReady.frame = NSRect(x: 192, y: 186, width: iw - 214, height: 18)
        backend.frame = NSRect(x: 22, y: 212, width: inner, height: 39)
        backendHelp.frame = NSRect(x: 22, y: 263, width: inner, height: 42)
        backendHelp.isHidden = guidanceHeight > 0
        mountedGuidance?.frame = NSRect(x: 22, y: 263, width: inner, height: guidanceHeight)
        controlsTitle.frame = NSRect(x: 22, y: 316 + guidanceOffset, width: 140, height: 21)
        controlHint.frame = NSRect(x: 192, y: 318 + guidanceOffset, width: iw - 214, height: 18)
        let shortcuts: [ControlShortcut] = [.home, .search, .power, .volumeDown, .volumeUp, .enter]
        let buttonWidth = (inner - 14) / 3
        for (i, shortcut) in shortcuts.enumerated() {
            shortcutButtons[shortcut]?.frame = NSRect(
                x: 22 + CGFloat(i % 3) * (buttonWidth + 7), y: 342 + guidanceOffset + CGFloat(i / 3) * 70,
                width: buttonWidth, height: 63)
        }
        shortcutButtons[.inputMethod]?.frame = NSRect(x: 22, y: 482 + guidanceOffset, width: inner, height: 34)
        let textOffset = guidanceOffset + 44
        textTitle.frame = NSRect(x: 22, y: 498 + textOffset, width: 120, height: 20)
        textHint.frame = NSRect(x: 162, y: 500 + textOffset, width: iw - 184, height: 18)
        textBackground.frame = NSRect(x: 22, y: 525 + textOffset, width: inner, height: 65)
        text.frame = NSRect(x: 33, y: 537 + textOffset, width: inner - 22, height: 44)
        paste.frame = NSRect(x: 10, y: 598 + textOffset, width: 150, height: 30)
        let sendWidth = max(79, send.requiredContentWidth)
        send.frame = NSRect(x: iw - 22 - sendWidth, y: 598 + textOffset, width: sendWidth, height: 31)
        help.frame = NSRect(x: 22, y: 639 + textOffset, width: inner, height: 35)
        aiCard.frame = NSRect(x: 22, y: max(710 + textOffset, inspector.bounds.height - 135), width: inner, height: 114)
        updateActivity()
        infoOverlay?.frame = bounds
        infoOverlay?.layoutSubtreeIfNeeded()
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        WorkbenchTheme.line.setFill()
        NSRect(x: 0, y: 63, width: bounds.width, height: 1).fill()
        NSRect(x: 294, y: 21, width: 1, height: 22).fill()
        NSRect(x: 0, y: bounds.height - 30, width: bounds.width, height: 1).fill()
        let searchBox = NSRect(x: bounds.width - 449, y: 16, width: 267, height: 33)
        WorkbenchTheme.color(0xF0F3F5, 0x29343C).setFill()
        let path = NSBezierPath(roundedRect: searchBox, xRadius: 7, yRadius: 7)
        path.fill()
        WorkbenchTheme.line.setStroke()
        path.stroke()
        WorkbenchTheme.symbol("magnifyingglass", in: NSRect(x: bounds.width - 436, y: 26, width: 13, height: 13))
        NSRect(x: 231, y: 64, width: 1, height: bounds.height - 94).fill()
        NSRect(x: bounds.width - 313, y: 64, width: 1, height: bounds.height - 94).fill()
        if preview {
            for (i, color) in [NSColor.systemRed, .systemOrange, .systemGreen].enumerated() {
                color.withAlphaComponent(0.85).setFill()
                NSBezierPath(ovalIn: NSRect(x: 23 + CGFloat(i) * 20, y: 27, width: 12, height: 12)).fill()
            }
        }
    }
    static var port: UInt16 { UInt16(ProcessInfo.processInfo.environment["IPHONE_USE_PORT"] ?? "") ?? 7390 }

    func showInfo(_ kind: WorkbenchInfoKind) {
        cancelInteractions()
        if infoOverlay == nil { infoPreviousResponder = window?.firstResponder }
        infoOverlay?.removeFromSuperview()
        let content = WorkbenchInfoContent(kind: kind, language: AppLanguageStore.shared.language,
                                          executable: Bundle.main.executableURL, port: Self.port, preview: preview)
        let overlay = WorkbenchInfoOverlay(kind: kind, content: content)
        infoOverlay = overlay
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.onDismiss = { [weak self] in self?.dismissInfo() }
        addSubview(overlay, positioned: .above, relativeTo: nil)
        overlay.layoutSubtreeIfNeeded()
        render()
        // Mouse-opened dialogs should not leave a bright focus ring on X.
        // The overlay owns keyboard input; Tab explicitly focuses the close button.
        window?.makeFirstResponder(overlay)
        NSAccessibility.post(element: overlay, notification: .created)
    }

    func dismissInfo() {
        guard let overlay = infoOverlay else { return }
        overlay.removeFromSuperview()
        infoOverlay = nil
        render()
        window?.makeFirstResponder(infoPreviousResponder)
        infoPreviousResponder = nil
    }

}

enum WorkbenchConfiguration {
    static func mcpCommand(executable: URL?) -> String {
        let path = executable?.path ?? "/Applications/iPhoneUse.app/Contents/MacOS/iphone-use"
        return "codex mcp add iphone-use -- '\(path.replacingOccurrences(of: "'", with: "'\\''"))' mcp"
    }
}

class WorkbenchSurface: NSView {
    var fill: NSColor = .clear { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        dirtyRect.intersection(bounds).fill()
    }
}

private enum WorkbenchStyle {
    static func label(size: CGFloat, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = secondary ? WorkbenchTheme.muted : WorkbenchTheme.ink
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}

/// Native button drawing keeps both name and readiness visible at every row height.
private final class WorkbenchDeviceRow: WorkbenchActionButton {
    private let device: WorkbenchDevice
    private let thumbnail: NSImage?
    init(device: WorkbenchDevice, selected: Bool, thumbnail: NSImage?) {
        self.device = device
        self.thumbnail = thumbnail
        super.init()
        retainsSelection = true
        state = selected ? .on : .off
        setAccessibilityLabel("\(device.name), \(device.status)")
        toolTip = "\(device.id)\n\(device.status)"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        if state == .on {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
            WorkbenchTheme.paper.setFill()
            path.fill()
            WorkbenchTheme.color(0xD3E2DF, 0x46675E).setStroke()
            path.stroke()
        }
        let thumb = NSRect(x: 11, y: 12, width: 28, height: 55)
        if let thumbnail {
            thumbnail.draw(
                in: thumb, from: .zero, operation: .sourceOver, fraction: 0.9, respectFlipped: true, hints: nil)
        } else {
            WorkbenchTheme.symbol("iphone", in: thumb.insetBy(dx: 3, dy: 7), color: WorkbenchTheme.muted)
        }
        WorkbenchTheme.text(
            device.name, in: NSRect(x: 50, y: 13, width: bounds.width - 58, height: 20), size: 11.5, weight: .semibold)
        let detail =
            device.detail.isEmpty
            ? (device.connected
                ? "USB · \(StringsWorkbench.current.usbPicture)" : StringsWorkbench.current.disconnected)
            : device.detail
        WorkbenchTheme.text(
            detail, in: NSRect(x: 50, y: 35, width: bounds.width - 58, height: 16), size: 10,
            color: WorkbenchTheme.muted)
        let color = device.shortcuts.isEmpty ? WorkbenchTheme.amber : WorkbenchTheme.green
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 50, y: 60, width: 5, height: 5)).fill()
        WorkbenchTheme.text(
            device.status, in: NSRect(x: 60, y: 54, width: bounds.width - 68, height: 18), size: 9.5, color: color)
    }
}

private final class WorkbenchPhoneCard: WorkbenchSurface {
    var onSelect: (() -> Void)?
    var onScreenshot: (() -> Void)?
    var onRecording: (() -> Void)?
    var onFocus: (() -> Void)?
    var onWindowAction: (() -> Void)?
    private(set) var deviceName = ""
    private let title = WorkbenchActionButton()
    private let status = WorkbenchStyle.label(size: 10, secondary: true)
    private let windowAction = WorkbenchActionButton()
    private let screenshot = WorkbenchActionButton()
    private let record = WorkbenchActionButton()
    private let independent = WorkbenchActionButton()
    private let content: NSView
    private let phoneShell: WorkbenchPhoneShell?
    private var selected = false
    private var connected = true
    init(content: NSView, showsShell: Bool) {
        self.content = content
        phoneShell = showsShell ? WorkbenchPhoneShell(content: content) : nil
        super.init(frame: .zero)
        [phoneShell ?? content, title, status, screenshot, record, independent, windowAction].forEach(addSubview)
        title.appearanceStyle = .plain
        title.alignment = .left
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.invoke = { [weak self] in self?.onSelect?() }
        for action in [screenshot, record, independent] {
            action.appearanceStyle = .plain
            action.font = .systemFont(ofSize: 10)
            action.alignment = .left
            action.centersTitleVertically = true
        }
        screenshot.symbolName = "camera"
        independent.symbolName = "arrow.up.forward.square"
        screenshot.invoke = { [weak self] in self?.onScreenshot?() }
        record.invoke = { [weak self] in self?.onRecording?() }
        independent.invoke = { [weak self] in self?.onFocus?() }
        windowAction.appearanceStyle = .plain
        windowAction.invoke = { [weak self] in self?.onWindowAction?() }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // Only decoration/background hits become selection. Keep the actual
        // phone view and all command buttons on their original event paths.
        if hit === content || hit.isDescendant(of: content) { return hit }
        if hit is NSButton { return hit }
        return self
    }

    func update(
        _ device: WorkbenchDevice, selected: Bool, inSeparateWindow: Bool,
        recording: ScreenVideoRecording?, canRecord: Bool
    ) {
        deviceName = device.name
        self.selected = selected
        connected = device.connected
        if let screenSize = device.screenSize { phoneShell?.screenSize = screenSize }
        phoneShell?.model = WorkbenchPhoneModel.resolve(productType: device.productType)
        title.title = device.name
        title.drawsDisabledAsReady = true
        title.toolTip = device.id
        let zh = AppLanguageStore.shared.language == .zh
        status.stringValue =
            device.connected
            ? "♧ USB \(zh ? "画面" : "display")   \(device.backend == .usb ? "♧ USB Touch · \(zh ? "实验性" : "Experimental")" : (device.shortcuts.isEmpty ? (zh ? "• 输入待配置" : "• Input not ready") : (zh ? "ᛒ 蓝牙输入" : "ᛒ Bluetooth input")))"
            : StringsWorkbench.current.disconnected
        status.textColor = device.shortcuts.isEmpty ? WorkbenchTheme.amber : WorkbenchTheme.muted
        screenshot.title = StringsWorkbench.current.screenshot
        screenshot.toolTip = screenshot.title
        screenshot.setAccessibilityLabel(screenshot.title)
        independent.title = zh ? "聚焦设备" : "Focus device"
        independent.toolTip = independent.title
        independent.setAccessibilityLabel(independent.title)
        let texts = StringsWorkbench.current
        let isFinishing = recording?.isFinishing == true
        record.title = isFinishing ? texts.recordingSaving : (recording == nil ? texts.record : texts.recordingStop)
        record.symbolName = recording == nil ? "record.circle" : "stop.circle.fill"
        record.appearanceStyle = recording != nil && !isFinishing ? .link : .plain
        record.toolTip = record.title
        record.setAccessibilityLabel(record.title)
        record.setAccessibilityIdentifier("card-record:\(device.id)")
        record.isEnabled = !isFinishing && (recording != nil || canRecord)
        needsLayout = true
        if !device.connected {
            windowAction.symbolName = "trash"
            windowAction.toolTip = texts.removeDeviceCard
            windowAction.setAccessibilityIdentifier("card-remove:\(device.id)")
        } else if inSeparateWindow {
            windowAction.symbolName = "xmark"
            windowAction.toolTip = texts.closeIndependent
            windowAction.setAccessibilityIdentifier("card-close-window:\(device.id)")
        } else {
            windowAction.symbolName = "arrow.up.left.and.arrow.down.right"
            windowAction.toolTip = texts.expand
            windowAction.setAccessibilityIdentifier("card-expand:\(device.id)")
        }
        windowAction.setAccessibilityLabel(windowAction.toolTip)
        screenshot.isEnabled = device.connected
        independent.isEnabled = device.connected
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 11, yRadius: 11)
        WorkbenchTheme.paper.setFill()
        outline.fill()
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        (selected ? WorkbenchTheme.color(0xF2F7F5, 0x243D37) : WorkbenchTheme.color(0xF6F8F9, 0x202C33)).setFill()
        NSRect(x: 1, y: 69, width: bounds.width - 2, height: bounds.height - 117).fill()
        NSGraphicsContext.restoreGraphicsState()
        (selected ? WorkbenchTheme.color(0x388D7E, 0x70B6A7) : WorkbenchTheme.line).setStroke()
        outline.lineWidth = 1
        outline.stroke()
        WorkbenchTheme.line.setFill()
        NSRect(x: 1, y: 68, width: bounds.width - 2, height: 1).fill()
        NSRect(x: 1, y: bounds.height - 48, width: bounds.width - 2, height: 1).fill()
        (connected ? WorkbenchTheme.green : WorkbenchTheme.faint).setFill()
        NSBezierPath(ovalIn: NSRect(x: 16, y: 22, width: 5, height: 5)).fill()
    }
    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        windowAction.frame = NSRect(x: w - 35, y: 9, width: 28, height: 28)
        title.frame = NSRect(x: 16, y: 9, width: w - 59, height: 28)
        status.frame = NSRect(x: 16, y: 44, width: w - 30, height: 18)
        if let phoneShell {
            phoneShell.frame = NSRect(x: 14, y: 73, width: w - 28, height: h - 125)
        } else if content is NSImageView {
            let width = min(254, w - 32)
            content.frame = NSRect(x: (w - width) / 2, y: 73, width: width, height: h - 125)
        } else {
            content.frame = NSRect(x: 1, y: 69, width: w - 2, height: h - 117)
        }
        let actionHeight: CGFloat = 28
        let actionY = h - (48 + actionHeight) / 2
        var actionX: CGFloat = 4
        for action in [screenshot, record, independent] {
            let width = action.requiredContentWidth
            action.frame = NSRect(x: actionX, y: actionY, width: width, height: actionHeight)
            actionX += width
        }
    }
}

extension Result where Success == Void, Failure == Error {
    fileprivate var failureDescription: String? {
        if case .failure(let error) = self { return "\(StringsWorkbench.current.actionFailed): \(error)" }
        return nil
    }
}
