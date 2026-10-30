import AppKit

/// A fixed-width sibling of the phone view, so toolbar clicks and its width never
/// participate in phone coordinate conversion.
final class ControlSidebar: NSView {
    static let width: CGFloat = 116
    /// Group titles resolve through the table so a language switch can retitle
    /// existing labels without rebuilding the stack's constraint wiring.
    private static let shortcutGroups: [(title: KeyPath<StringsUI, String>, shortcuts: [ControlShortcut])] =
        [
            (\.groupNavigation, [.home, .search, .power]),
            (\.groupInput, [.paste, .enter]),
            (\.groupVolume, [.volumeUp, .volumeDown]),
        ]

    var onAction: ((ControlShortcut) -> Void)?
    private var buttons: [ControlShortcut: NSButton] = [:]
    private var groupLabels: [NSTextField] = []
    private let status = NSTextField(wrappingLabelWithString: StringsUI.current.statusInitial)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let stack = makeShortcutStack()
        configureStatusLabel()
        let divider = makeDivider()
        installConstraints(stack: stack, divider: divider)
    }

    func update(available: Set<ControlShortcut>, status text: String) {
        for (shortcut, button) in buttons { button.isEnabled = available.contains(shortcut) }
        status.stringValue = text
        status.toolTip = text
    }

    /// Re-applies every localized title after a language change. The status line
    /// itself is owned by PhoneControlView, which recomputes it on its next tick.
    func refreshLocalization() {
        let table = StringsUI.current
        for (index, label) in groupLabels.enumerated() {
            label.stringValue = table[keyPath: Self.shortcutGroups[index].title]
        }
        for (shortcut, button) in buttons {
            button.title = shortcut.title
            button.toolTip = shortcut.help
            button.setAccessibilityLabel(shortcut.title)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        // AppKit can invalidate beyond a view's bounds. Do not paint over the
        // adjacent phone image when redrawing the sidebar.
        dirtyRect.intersection(bounds).fill()
    }

    private func makeShortcutStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for group in Self.shortcutGroups {
            addShortcutGroup(titleKey: group.title, shortcuts: group.shortcuts, to: stack)
        }
        return stack
    }

    private func addShortcutGroup(
        titleKey: KeyPath<StringsUI, String>, shortcuts: [ControlShortcut], to stack: NSStackView
    ) {
        let label = NSTextField(labelWithString: StringsUI.current[keyPath: titleKey])
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        stack.addArrangedSubview(label)
        groupLabels.append(label)
        for shortcut in shortcuts {
            let button = makeButton(for: shortcut)
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            buttons[shortcut] = button
        }
        if let lastView = stack.arrangedSubviews.last {
            stack.setCustomSpacing(16, after: lastView)
        }
    }

    private func makeButton(for shortcut: ControlShortcut) -> NSButton {
        let button = NSButton(title: shortcut.title, target: self, action: #selector(activate(_:)))
        button.tag = shortcut.rawValue
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: shortcut.symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.font = .systemFont(ofSize: 12)
        button.toolTip = shortcut.help
        button.setAccessibilityLabel(shortcut.title)
        button.isEnabled = false
        return button
    }

    private func configureStatusLabel() {
        status.font = .systemFont(ofSize: 10)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3
        status.translatesAutoresizingMaskIntoConstraints = false
        addSubview(status)
    }

    private func makeDivider() -> NSBox {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)
        return divider
    }

    private func installConstraints(stack: NSStackView, divider: NSBox) {
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            status.topAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 16),
            status.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    @objc private func activate(_ sender: NSButton) {
        guard let shortcut = ControlShortcut(rawValue: sender.tag) else { return }
        onAction?(shortcut)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

enum ControlShortcut: Int, CaseIterable {
    case home, search, paste, enter, volumeUp, volumeDown, power

    var title: String {
        let table = StringsUI.current
        return switch self {
        case .home: table.shortcutHome
        case .search: table.shortcutSearch
        case .paste: table.shortcutPaste
        case .enter: table.shortcutEnter
        case .volumeUp: table.shortcutVolumeUp
        case .volumeDown: table.shortcutVolumeDown
        case .power: table.shortcutPower
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .search: "magnifyingglass"
        case .paste: "doc.on.clipboard"
        case .enter: "return"
        case .volumeUp: "speaker.plus"
        case .volumeDown: "speaker.minus"
        case .power: "power"
        }
    }

    var help: String {
        let table = StringsUI.current
        return switch self {
        case .home: table.helpHome
        case .search: table.helpSearch
        case .paste: table.helpPaste
        case .enter: table.helpEnter
        case .volumeUp: table.helpVolumeUp
        case .volumeDown: table.helpVolumeDown
        case .power: table.helpPower
        }
    }

    var report: ReportID {
        switch self {
        case .home, .volumeUp, .volumeDown, .power: .consumer
        case .search, .paste, .enter: .keyboard
        }
    }

    func isAvailable(on input: DeviceInput) -> Bool {
        guard input.isCurrentSession else { return false }
        return HIDPeripheral.shared.isReady(report: report, host: input.host, session: input.session)
    }

    func perform(on input: DeviceInput) throws {
        switch self {
        case .home: input.consumer(0x0223)
        case .search: try input.key("space", modifiers: ["cmd"])
        case .paste: try input.key("v", modifiers: ["cmd"])
        case .enter: try input.key("enter", modifiers: [])
        case .volumeUp: input.consumer(0x00E9)
        case .volumeDown: input.consumer(0x00EA)
        case .power: input.consumer(0x0030)
        }
    }
}
