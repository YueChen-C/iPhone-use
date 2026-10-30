import AppKit

/// A visual hint must not intercept Home, keyboard or pointer wake-up actions.
final class ControlLockNotice: NSView {
    private let title = NSTextField(wrappingLabelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private var state: DeviceLockState = .unknown

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        layer?.cornerRadius = 10
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .systemYellow
        message.font = .systemFont(ofSize: 12)
        message.textColor = .white
        let stack = NSStackView(views: [title, message])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        refreshLocalization()
    }

    func refreshLocalization() {
        title.stringValue = state.title
        message.stringValue = state.message
        setAccessibilityLabel(title.stringValue + ". " + message.stringValue)
    }

    func update(_ state: DeviceLockState) {
        self.state = state
        isHidden = !state.showsNotice
        refreshLocalization()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
