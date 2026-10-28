import AppKit
import IOBluetooth

enum ControlConnectionStatus {
    case waitingForDevice, disconnected, unmatched, connecting, connected

    static func resolve(
        hasScreen: Bool, hasMatchedHost: Bool, hasConnectedHosts: Bool,
        inputIsCurrent: Bool, inputIsReady: Bool
    ) -> Self {
        guard hasScreen else { return .waitingForDevice }
        if !hasMatchedHost && hasConnectedHosts { return .unmatched }
        if inputIsCurrent { return inputIsReady ? .connected : .connecting }
        return hasMatchedHost ? .connecting : .disconnected
    }
}

/// Covers the complete content area, including shortcuts, while keeping the
/// captured screen visible underneath. Window input is also gated at its source.
final class ControlConnectionOverlay: NSView {
    private let title = NSTextField(labelWithString: StringsUI.current.overlayNotConnectedTitle)
    private let message = NSTextField(wrappingLabelWithString: "")
    private var hasConnected = false
    private var lastStatus: ControlConnectionStatus = .disconnected
    private var instructionsField: NSTextField?
    private var helpField: NSTextField?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(StringsUI.current.overlayAccessibility)

        let card = makeMessageCard()
        let icon = makeIconAndConfigureLabels()
        let instructions = makePairingInstructions()
        let help = makeTroubleshootingLabel()
        let stack = makeMessageStack(
            card: card, icon: icon, instructions: instructions, help: help)
        installConstraints(card: card, stack: stack, icon: icon, instructions: instructions, help: help)
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
        return instructions
    }

    private func pairingText() -> String {
        let advertisedName = HIDPeripheral.shared.localName
        // The advertising name does not give this app a separate Bluetooth
        // identity. iOS may show the Mac's controller name instead.
        let controllerName = IOBluetoothHostController.default()?.nameAsString()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return StringsUI.current.pairingInstructions(advertisedName, controllerName)
    }

    private func makeTroubleshootingLabel() -> NSTextField {
        let help = NSTextField(wrappingLabelWithString: StringsUI.current.overlayHelp)
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        helpField = help
        return help
    }

    private func makeMessageStack(
        card: NSView, icon: NSImageView, instructions: NSTextField, help: NSTextField
    ) -> NSStackView {
        let stack = NSStackView(views: [icon, title, message, instructions, help])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        return stack
    }

    private func installConstraints(
        card: NSView, stack: NSStackView, icon: NSImageView,
        instructions: NSTextField, help: NSTextField
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
        ])
    }

    func update(_ status: ControlConnectionStatus) {
        lastStatus = status
        if status == .connected { hasConnected = true }
        isHidden = status == .connected
        let table = StringsUI.current
        instructionsField?.isHidden = status == .unmatched
        helpField?.isHidden = status == .unmatched
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
        case .connected:
            break
        }
    }

    /// Rebuilds the static card text and replays the last status after a
    /// language change; replaying .connected only hides the overlay.
    func refreshLocalization() {
        setAccessibilityLabel(StringsUI.current.overlayAccessibility)
        instructionsField?.stringValue = pairingText()
        helpField?.stringValue = StringsUI.current.overlayHelp
        update(lastStatus)
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {}

    override func draw(_ dirtyRect: NSRect) {
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
