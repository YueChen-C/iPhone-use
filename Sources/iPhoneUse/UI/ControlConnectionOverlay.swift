import AppKit
import IOBluetooth

enum ControlConnectionStatus {
    case waitingForDevice, disconnected, unmatched, connecting, verifyingScreen, connected

    var showsOverlay: Bool { self != .connected && self != .verifyingScreen }

    /// An ignored event must not cancel the discovery needed to enable input.
    var permitsBackgroundMotionPreemption: Bool { self == .connected }

    static func resolve(
        hasScreen: Bool, hasMatchedHost: Bool, bluetoothState: DeviceBluetoothState,
        inputIsCurrent: Bool, inputIsReady: Bool, screenPermitsInput: Bool
    ) -> Self {
        guard hasScreen else { return .waitingForDevice }
        if !hasMatchedHost { return bluetoothState == .unmatched ? .unmatched : .disconnected }
        if !screenPermitsInput { return .verifyingScreen }
        if inputIsCurrent { return inputIsReady ? .connected : .connecting }
        return hasMatchedHost ? .connecting : .disconnected
    }
}

/// Covers the complete content area, including shortcuts, while keeping the
/// captured screen visible underneath. Window input is also gated at its source.
final class ControlConnectionOverlay: NSView {
    enum Presentation { case screenOverlay, inspector }
    let presentation: Presentation
    var onLayoutChanged: (() -> Void)?
    private var messageStack: NSStackView?
    private static let controllerNameLock = NSLock()
    private static var cachedControllerName: String?
    private static var controllerNameLoaded = false

    private let title = NSTextField(labelWithString: StringsUI.current.overlayNotConnectedTitle)
    private let icon = NSImageView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var hasConnected = false
    private var lastStatus: ControlConnectionStatus = .disconnected
    private var usbPresentation: ControlUSBPresentation?
    private var backendSelectionFailure: String?
    var onNoticeDismissed: (() -> Void)?
    private var instructionsField: NSTextField?
    private var helpField: NSTextField?
    var onEnableUSB: (() -> Void)?
    var onRetryUSB: ((@escaping () -> Void) -> Void)?
    private let retryUSBButton = NSButton(title: "", target: nil, action: nil)
    private var retryingUSB = false
    var onCancelUSBSetup: (() -> Void)?
    private var setup: USBSetupPresentation?
    private let setupButton = NSButton(title: "", target: nil, action: nil)
    private let setupProgress = NSProgressIndicator()

    private var cardView: NSView?
    private let reconnectButton = NSButton(title: "", target: nil, action: nil)
    private let viewOnlyButton = NSButton(title: "", target: nil, action: nil)
    private let pillView = PillContainerView()
    private let pillLabel = NSTextField(labelWithString: "")
    private let pillButton = NSButton(title: "", target: nil, action: nil)
    private(set) var isDismissed = false

    override convenience init(frame: NSRect) {
        self.init(frame: frame, presentation: .screenOverlay)
    }

    init(frame: NSRect, presentation: Presentation) {
        self.presentation = presentation
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(StringsUI.current.overlayAccessibility)

        let card = makeMessageCard()
        cardView = card
        let icon = makeIconAndConfigureLabels()
        let instructions = makePairingInstructions()
        let help = makeTroubleshootingLabel()
        let buttons = makeButtonsStack()
        let stack = makeMessageStack(
            card: card, icon: icon, instructions: instructions, help: help, buttons: buttons)
        messageStack = stack
        installConstraints(
            card: card, stack: stack, icon: icon, instructions: instructions, help: help, buttons: buttons)
        setupPillView()
        update(.disconnected)
    }

    private func makeMessageCard() -> NSView {
        let card = ConnectionMessageCard()
        card.compact = presentation == .inspector
        card.wantsLayer = true
        card.layer?.cornerRadius = 16
        card.layer?.masksToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        return card
    }

    private func makeIconAndConfigureLabels() -> NSImageView {
        icon.image = NSImage(
                systemSymbolName: "antenna.radiowaves.left.and.right.slash",
                accessibilityDescription: nil)
        icon.contentTintColor = .systemOrange
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: presentation == .inspector ? 20 : 28, weight: .medium)
        title.font = .systemFont(ofSize: presentation == .inspector ? 13 : 19, weight: .semibold)
        title.alignment = presentation == .inspector ? .left : .center
        title.maximumNumberOfLines = 0
        title.lineBreakMode = .byWordWrapping
        message.font = .systemFont(ofSize: presentation == .inspector ? 12 : 13)
        message.alignment = presentation == .inspector ? .left : .center
        message.textColor = .secondaryLabelColor
        return icon
    }

    private func makePairingInstructions() -> NSTextField {
        let instructions = NSTextField(wrappingLabelWithString: pairingText())
        instructions.font = .systemFont(ofSize: 12)
        instructionsField = instructions
        resolveControllerNameIfNeeded()
        return instructions
    }

    private func pairingText() -> String {
        let advertisedName = HIDPeripheral.shared.localName
        // The advertising name does not give this app a separate Bluetooth
        // identity. iOS may show the Mac's controller name instead. Resolve it
        // off the main thread so IOBluetooth initialization cannot freeze launch.
        let controllerName = Self.controllerNameLock.withLock { Self.cachedControllerName }
        return StringsUI.current.pairingInstructions(advertisedName, controllerName)
    }

    private func resolveControllerNameIfNeeded() {
        let alreadyLoaded = Self.controllerNameLock.withLock { Self.controllerNameLoaded }
        guard !alreadyLoaded else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let resolved = IOBluetoothHostController.default()?.nameAsString()?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Self.controllerNameLock.withLock {
                Self.cachedControllerName = resolved
                Self.controllerNameLoaded = true
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.instructionsField?.stringValue = self.pairingText()
                self.onLayoutChanged?()
            }
        }
    }

    private func makeTroubleshootingLabel() -> NSTextField {
        let help = NSTextField(wrappingLabelWithString: StringsUI.current.overlayHelp)
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        helpField = help
        return help
    }

    private func makeButtonsStack() -> NSStackView {
        reconnectButton.title = StringsUI.current.overlayButtonReconnect
        reconnectButton.bezelStyle = .rounded
        reconnectButton.target = self
        reconnectButton.action = #selector(onReconnectClicked)

        viewOnlyButton.title = StringsUI.current.overlayButtonViewOnly
        viewOnlyButton.bezelStyle = .rounded
        viewOnlyButton.target = self
        viewOnlyButton.action = #selector(onViewOnlyClicked)

        setupButton.title = StringsUSBSetup.current.enable
        setupButton.bezelStyle = .rounded
        setupButton.target = self
        setupButton.action = #selector(onEnableUSBClicked)
        setupButton.isHidden = true
        setupProgress.style = .bar
        setupProgress.minValue = 0; setupProgress.maxValue = 1
        setupProgress.isHidden = true

        retryUSBButton.title = StringsUSBControl.current.retryPreparation
        retryUSBButton.bezelStyle = .rounded
        retryUSBButton.setButtonType(.momentaryPushIn)
        retryUSBButton.target = self
        retryUSBButton.action = #selector(onRetryUSBClicked)
        retryUSBButton.isHidden = true

        let stack = NSStackView()
        stack.orientation = presentation == .inspector ? .vertical : .horizontal
        // Keep a lone acknowledgement centered when the reconnect action hides.
        stack.setViews([viewOnlyButton, retryUSBButton, reconnectButton], in: .center)
        stack.spacing = presentation == .inspector ? 6 : 12
        stack.alignment = presentation == .inspector ? .leading : .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func makeMessageStack(
        card: NSView, icon: NSImageView, instructions: NSTextField, help: NSTextField, buttons: NSStackView
    ) -> NSStackView {
        // Keep the longer setup action on its own row in narrow phone windows.
        let stack = NSStackView(views: [icon, title, message, instructions, help, setupProgress, setupButton, buttons])
        stack.orientation = .vertical
        stack.alignment = presentation == .inspector ? .leading : .centerX
        stack.spacing = presentation == .inspector ? 10 : 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        return stack
    }

    private func setupPillView() {
        pillView.wantsLayer = true
        pillView.translatesAutoresizingMaskIntoConstraints = false
        pillView.isHidden = true
        addSubview(pillView)

        pillLabel.stringValue = StringsUI.current.overlayPillTitle
        pillLabel.font = .systemFont(ofSize: 11, weight: .medium)
        pillLabel.textColor = .secondaryLabelColor
        pillLabel.translatesAutoresizingMaskIntoConstraints = false

        pillButton.title = StringsUI.current.overlayPillShowGuidance
        pillButton.bezelStyle = .inline
        pillButton.font = .systemFont(ofSize: 11, weight: .semibold)
        pillButton.target = self
        pillButton.action = #selector(onShowGuidanceClicked)
        pillButton.translatesAutoresizingMaskIntoConstraints = false

        let pillStack = NSStackView(views: [pillLabel, pillButton])
        pillStack.orientation = .horizontal
        pillStack.spacing = 8
        pillStack.alignment = .centerY
        pillStack.translatesAutoresizingMaskIntoConstraints = false
        pillView.addSubview(pillStack)

        NSLayoutConstraint.activate([
            pillView.topAnchor.constraint(equalTo: topAnchor, constant: presentation == .inspector ? 0 : 14),
            pillView.centerXAnchor.constraint(equalTo: centerXAnchor),
            pillView.heightAnchor.constraint(equalToConstant: 28),
            pillStack.leadingAnchor.constraint(equalTo: pillView.leadingAnchor, constant: 12),
            pillStack.trailingAnchor.constraint(equalTo: pillView.trailingAnchor, constant: -12),
            pillStack.centerYAnchor.constraint(equalTo: pillView.centerYAnchor),
        ])
    }

    private func installConstraints(
        card: NSView, stack: NSStackView, icon: NSImageView,
        instructions: NSTextField, help: NSTextField, buttons: NSStackView
    ) {
        if presentation == .inspector {
            NSLayoutConstraint.activate([
                card.leadingAnchor.constraint(equalTo: leadingAnchor),
                card.trailingAnchor.constraint(equalTo: trailingAnchor),
                card.topAnchor.constraint(equalTo: topAnchor),
                stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
                stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
                stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
                stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
                icon.heightAnchor.constraint(equalToConstant: 24),
                title.widthAnchor.constraint(equalTo: stack.widthAnchor),
                message.widthAnchor.constraint(equalTo: stack.widthAnchor),
                instructions.widthAnchor.constraint(equalTo: stack.widthAnchor),
                help.widthAnchor.constraint(equalTo: stack.widthAnchor),
                setupProgress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ])
            return
        }
        let preferredWidth = card.widthAnchor.constraint(equalToConstant: 420)
        preferredWidth.priority = NSLayoutConstraint.Priority(500)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            preferredWidth,
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
            icon.heightAnchor.constraint(equalToConstant: 32),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            instructions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor),
            setupProgress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
    }

    /// Measure wrapping at the Inspector's actual width; its scroll document
    /// grows with guidance rather than clipping controls or stretching a phone.
    func preferredHeight(for width: CGFloat) -> CGFloat {
        guard !isHidden else { return 0 }
        guard !isDismissed else { return 28 }
        let textWidth = max(1, width - 28)
        for field in [title, message, instructionsField, helpField].compactMap({ $0 }) {
            field.preferredMaxLayoutWidth = textWidth
        }
        return ceil(messageStack?.fittingSize.height ?? 0) + 28
    }

    @objc private func onReconnectClicked() {
        reconnectButton.isEnabled = false
        DeviceRegistry.shared.reconnectBluetooth(resetExhausted: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.reconnectButton.isEnabled = true
        }
    }

    @objc private func onViewOnlyClicked() {
        if backendSelectionFailure != nil {
            showBackendSelectionFailure(nil)
            onNoticeDismissed?()
            return
        }
        setDismissed(true)
    }

    @objc private func onRetryUSBClicked() {
        guard usbPresentation?.offersPreparationRetry == true, !retryingUSB,
              setup?.isWorking != true, let onRetryUSB else { return }
        retryingUSB = true
        retryUSBButton.isEnabled = false
        onRetryUSB { [weak self] in
            guard let self else { return }
            self.retryingUSB = false
            self.update(self.lastStatus)
        }
    }

    @objc private func onEnableUSBClicked() {
        if setup?.canCancel == true { onCancelUSBSetup?(); return }
        guard usbPresentation?.offersUSBSetup == true, setup?.isWorking != true else { return }
        onEnableUSB?()
    }

    func updateSetup(_ state: USBSetupPresentation?) {
        setup = state
        update(lastStatus)
    }

    @objc private func onShowGuidanceClicked() {
        setDismissed(false)
    }

    func setDismissed(_ dismissed: Bool) {
        guard isDismissed != dismissed else { return }
        isDismissed = dismissed
        cardView?.isHidden = dismissed
        pillView.isHidden = !dismissed
        needsDisplay = true
        onLayoutChanged?()
    }

    func update(_ status: ControlConnectionStatus) {
        defer { onLayoutChanged?() }
        lastStatus = status
        if status == .waitingForDevice { backendSelectionFailure = nil }
        if let backendSelectionFailure {
            updateSelectionFailureCard(backendSelectionFailure)
            return
        }
        if let usbPresentation {
            updateUSBCard(usbPresentation)
            return
        }
        if status == .connected {
            hasConnected = true
            setDismissed(false)
        }
        isHidden = !status.showsOverlay
        let table = StringsUI.current
        retryUSBButton.isHidden = true
        setupButton.isHidden = true
        setupProgress.isHidden = true
        setupProgress.stopAnimation(nil)
        viewOnlyButton.isEnabled = true
        setAccessibilityLabel(table.overlayAccessibility)
        icon.image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right.slash", accessibilityDescription: nil)
        message.toolTip = nil
        helpField?.stringValue = table.overlayHelp
        viewOnlyButton.title = table.overlayButtonViewOnly
        pillLabel.stringValue = table.overlayPillTitle
        pillButton.title = table.overlayPillShowGuidance
        instructionsField?.isHidden = status == .unmatched
        helpField?.isHidden = status == .unmatched

        let hasPhoneScreen = status != .waitingForDevice
        viewOnlyButton.isHidden = !hasPhoneScreen
        reconnectButton.isHidden = !hasPhoneScreen

        if status == .waitingForDevice {
            setDismissed(false)
        } else if isDismissed {
            cardView?.isHidden = true
            pillView.isHidden = false
        } else {
            cardView?.isHidden = false
            pillView.isHidden = true
        }

        switch status {
        case .waitingForDevice:
            title.stringValue = table.overlayWaitingTitle
            message.stringValue = table.overlayWaitingMessage
        case .disconnected:
            title.stringValue =
                hasConnected ? table.overlayDisconnectedTitle : table.overlayNotConnectedTitle
            message.stringValue = table.overlayBluetoothMessage
        case .connecting:
            title.stringValue = table.overlayConnectingTitle
            message.stringValue = table.overlayConnectingMessage
        case .unmatched:
            title.stringValue = table.overlayUnmatchedTitle
            message.stringValue = table.overlayUnmatchedMessage
        case .verifyingScreen, .connected:
            break
        }
    }

    func updateUSB(_ presentation: ControlUSBPresentation?) {
        let changedBackend = (usbPresentation == nil) != (presentation == nil)
        if changedBackend { setup = nil }
        usbPresentation = presentation
        if changedBackend { setDismissed(false) }
        update(lastStatus)
    }

    /// Reuse the app's connection card, without selecting USB or offering DDI
    /// setup for an incompatible device. Polling must not erase the notice.
    func showBackendSelectionFailure(_ message: String?) {
        backendSelectionFailure = message
        setDismissed(false)
        update(lastStatus)
    }

    private func updateSelectionFailureCard(_ detail: String) {
        let table = StringsUSBControl.current
        isHidden = false
        setAccessibilityLabel(table.title)
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        title.stringValue = table.title
        message.stringValue = detail
        message.toolTip = detail
        instructionsField?.isHidden = true
        helpField?.isHidden = true
        reconnectButton.isHidden = true
        retryUSBButton.isHidden = true
        setupButton.isHidden = true
        setupProgress.isHidden = true
        setupProgress.stopAnimation(nil)
        viewOnlyButton.title = table.acknowledge
        viewOnlyButton.isHidden = false
        viewOnlyButton.isEnabled = true
        cardView?.isHidden = false
        pillView.isHidden = true
    }

    private func updateUSBCard(_ presentation: ControlUSBPresentation) {
        let table = StringsUSBControl.current
        setAccessibilityLabel(table.title)
        icon.image = NSImage(systemSymbolName: "cable.connector", accessibilityDescription: nil)
        let showingSetup = presentation.hasScreen && (presentation.showsOverlay || setup == .complete || setup?.isWorking == true)
        isHidden = !showingSetup
        if !presentation.showsOverlay || !presentation.hasScreen { setDismissed(false) }
        instructionsField?.isHidden = true
        helpField?.isHidden = false
        reconnectButton.isHidden = true // Never route USB recovery into Bluetooth reconnect.
        retryUSBButton.title = table.retryPreparation
        retryUSBButton.isHidden = !presentation.offersPreparationRetry
        retryUSBButton.isEnabled = !retryingUSB && setup?.isWorking != true
        viewOnlyButton.isHidden = !presentation.hasScreen
        title.stringValue = table.title
        message.stringValue = table.status(presentation)
        message.toolTip = presentation.detail.isEmpty ? nil : presentation.detail
        helpField?.stringValue = table.guidance(presentation.recovery)
        if presentation.offersUSBSetup {
            helpField?.stringValue += "\n\n" + StringsUSBSetup.current.consent
        }
        let working = setup?.isWorking == true
        let cancellable = setup?.canCancel == true
        setupButton.title = cancellable ? StringsUSBSetup.current.cancel : StringsUSBSetup.current.enable
        setupButton.isHidden = !cancellable && (!presentation.offersUSBSetup || working
            || setup == .connectionFailed)
        setupButton.isEnabled = cancellable || !working
        setupProgress.isHidden = !showingSetup || (!working && setup != .complete)
        viewOnlyButton.isEnabled = !working
        if let setup, showingSetup {
            let progress = StringsUSBSetup.current.progress(setup)
            if working || setup == .complete {
                message.stringValue = progress
                helpField?.isHidden = true
            } else {
                helpField?.stringValue = progress
            }
            if setup == .failed || setup == .cancelled {
                helpField?.stringValue += "\n\n" + StringsUSBSetup.current.consent
            }
            setupProgress.isIndeterminate = setup.fraction == nil
            setupProgress.doubleValue = setup.fraction ?? 0
            if working && setup.fraction == nil { setupProgress.startAnimation(nil) } else { setupProgress.stopAnimation(nil) }
        } else {
            setupProgress.stopAnimation(nil)
        }
        viewOnlyButton.title = table.viewOnly
        pillLabel.stringValue = table.pill
        pillButton.title = table.showGuidance
        cardView?.isHidden = isDismissed
        pillView.isHidden = !isDismissed
    }

    /// Rebuilds the static card text and replays the last status after a
    /// language change; replaying .connected only hides the overlay.
    func refreshLocalization() {
        let table = StringsUI.current
        setAccessibilityLabel(table.overlayAccessibility)
        instructionsField?.stringValue = pairingText()
        helpField?.stringValue = table.overlayHelp
        reconnectButton.title = table.overlayButtonReconnect
        viewOnlyButton.title = table.overlayButtonViewOnly
        pillLabel.stringValue = table.overlayPillTitle
        pillButton.title = table.overlayPillShowGuidance
        update(lastStatus)
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }
        if isDismissed {
            if !pillView.isHidden, pillView.frame.contains(localPoint) {
                return pillView.hitTest(localPoint)
            }
            return nil
        }
        if let cardView, !cardView.isHidden, cardView.frame.contains(localPoint) {
            return cardView.hitTest(localPoint)
        }
        return self
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {}

    override func draw(_ dirtyRect: NSRect) {
        guard presentation == .screenOverlay, !isDismissed else { return }
        NSColor.black.withAlphaComponent(0.45).setFill()
        dirtyRect.fill(using: .sourceOver)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class ConnectionMessageCard: NSView {
    var compact = false
    override func draw(_ dirtyRect: NSRect) {
        (compact ? NSColor.controlBackgroundColor : NSColor.windowBackgroundColor).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).fill()
    }
}

private final class PillContainerView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 13.5, yRadius: 13.5)
        path.lineWidth = 1
        path.stroke()
    }
}
