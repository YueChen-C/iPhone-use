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
    private static let controllerNameLock = NSLock()
    private static var cachedControllerName: String?
    private static var controllerNameLoaded = false

    private let title = NSTextField(labelWithString: StringsUI.current.overlayNotConnectedTitle)
    private let message = NSTextField(wrappingLabelWithString: "")
    private var hasConnected = false
    private var lastStatus: ControlConnectionStatus = .disconnected
    private var instructionsField: NSTextField?
    private var helpField: NSTextField?

    private var cardView: NSView?
    private let reconnectButton = NSButton(title: "", target: nil, action: nil)
    private let viewOnlyButton = NSButton(title: "", target: nil, action: nil)
    private let pillView = PillContainerView()
    private let pillLabel = NSTextField(labelWithString: "")
    private let pillButton = NSButton(title: "", target: nil, action: nil)
    private(set) var isDismissed = false

    override init(frame: NSRect) {
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
        installConstraints(
            card: card, stack: stack, icon: icon, instructions: instructions, help: help, buttons: buttons)
        setupPillView()
        update(.disconnected)
    }

    private func makeMessageCard() -> NSView {
        let card = ConnectionMessageCard()
        card.wantsLayer = true
        card.layer?.cornerRadius = 16
        card.layer?.masksToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        return card
    }

    private func makeIconAndConfigureLabels() -> NSImageView {
        let icon = NSImageView(
            image: NSImage(
                systemSymbolName: "antenna.radiowaves.left.and.right.slash",
                accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .systemOrange
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        title.alignment = .center
        message.font = .systemFont(ofSize: 13)
        message.alignment = .center
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

        let stack = NSStackView(views: [viewOnlyButton, reconnectButton])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func makeMessageStack(
        card: NSView, icon: NSImageView, instructions: NSTextField, help: NSTextField, buttons: NSStackView
    ) -> NSStackView {
        let stack = NSStackView(views: [icon, title, message, instructions, help, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
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
            pillView.topAnchor.constraint(equalTo: topAnchor, constant: 14),
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
            buttons.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
    }

    @objc private func onReconnectClicked() {
        reconnectButton.isEnabled = false
        DeviceRegistry.shared.reconnectBluetooth(resetExhausted: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.reconnectButton.isEnabled = true
        }
    }

    @objc private func onViewOnlyClicked() {
        setDismissed(true)
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
    }

    func update(_ status: ControlConnectionStatus) {
        lastStatus = status
        if status == .connected {
            hasConnected = true
            setDismissed(false)
        }
        isHidden = !status.showsOverlay
        let table = StringsUI.current
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
                return pillView.hitTest(point)
            }
            return nil
        }
        if let cardView, !cardView.isHidden, cardView.frame.contains(localPoint) {
            return cardView.hitTest(point)
        }
        return self
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {}

    override func draw(_ dirtyRect: NSRect) {
        guard !isDismissed else { return }
        NSColor.black.withAlphaComponent(0.45).setFill()
        dirtyRect.fill(using: .sourceOver)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class ConnectionMessageCard: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
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
