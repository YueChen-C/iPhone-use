import AppKit

/// Shared native drawing tokens sampled from the approved 2.0 design, not system bezels.
enum WorkbenchTheme {
    static func color(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
    }
    static let ink = color(0x1C2936, 0xE1E8EC)
    static let muted = color(0x7D8C97, 0x95A5AF)
    static let faint = color(0x95A2AB, 0x87949E)
    static let line = color(0xE4E9ED, 0x344149)
    static let accent = color(0x127A70, 0x70B6A7)
    static let accentFill = color(0xE6F1EE, 0x253E39)
    static let sidebar = color(0xF7F9FA, 0x20282E)
    static let canvas = color(0xF2F5F7, 0x192127)
    static let paper = color(0xFFFFFF, 0x252F36)
    static let soft = color(0xFAFBFC, 0x29343C)
    static let header = color(0xF9FAFB, 0x232C33)
    static let green = color(0x589F89, 0x74B39F)
    static let amber = color(0xAD873A, 0xCFB471)

    static func text(
        _ value: String, in rect: NSRect, size: CGFloat = 12,
        weight: NSFont.Weight = .regular, color: NSColor = ink,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(
            in: rect,
            withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color, .paragraphStyle: paragraph,
            ])
    }
    static func symbol(_ name: String, in rect: NSRect, color: NSColor = muted) {
        guard
            let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: rect.height, weight: .regular))
        else { return }
        let tinted = NSImage(size: rect.size, flipped: false) { bounds in
            // SF Symbols have intrinsic aspect ratios (ellipsis is very wide).
            // Fit instead of stretching narrow glyphs into the icon square.
            let scale = min(bounds.width / symbol.size.width, bounds.height / symbol.size.height)
            let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            symbol.draw(
                in: NSRect(
                    x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                    width: size.width, height: size.height))
            color.setFill()
            bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// These remain native NSButtons: keyboard activation, focus rings and accessibility are retained.
class WorkbenchActionButton: NSButton {
    enum Appearance { case system, navigation, outline, link, solid, shortcut, plain }
    var appearanceStyle: Appearance = .system { didSet { needsDisplay = true } }
    var symbolName: String? { didSet { needsDisplay = true } }
    var drawsDisabledAsReady = false { didSet { needsDisplay = true } }
    var badge = "" { didSet { needsDisplay = true } }
    /// Only actual selection controls may retain .on; commands are always momentary.
    var retainsSelection = false
    var invoke: (() -> Void)?
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: .zero)
        title = ""
        setButtonType(.momentaryPushIn)
        bezelStyle = .rounded
        font = .systemFont(ofSize: 12)
        target = self
        action = #selector(activate)
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func activate() {
        defer {
            if !retainsSelection { state = .off }
            highlight(false)
            needsDisplay = true
        }
        invoke?()
    }
    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        // Custom drawing must repaint on release, even when the handler opens a panel.
        needsDisplay = true
    }
    var showsSelection: Bool { retainsSelection && state == .on }
    /// The same content metric used by drawing, exposed for localized layout checks.
    var requiredContentWidth: CGFloat {
        let icon: CGFloat = symbolName == nil ? 0 : (appearanceStyle == .navigation ? 17 : 14) + 8
        let text = (title as NSString).size(withAttributes: [.font: contentFont]).width
        let padding: CGFloat = alignment == .left || appearanceStyle == .navigation ? 20 : 16
        return ceil(text + icon + padding + (badge.isEmpty ? 0 : 35))
    }
    private var contentFont: NSFont {
        .systemFont(
            ofSize: font?.pointSize ?? 12,
            weight: showsSelection || appearanceStyle == .solid ? .medium : .regular)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard appearanceStyle != .system else {
            super.draw(dirtyRect)
            return
        }
        let selected = showsSelection
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        let fill: NSColor
        let stroke: NSColor
        var foreground = WorkbenchTheme.muted
        switch appearanceStyle {
        case .navigation:
            fill = selected ? WorkbenchTheme.accentFill : .clear
            stroke = .clear
            foreground = selected ? WorkbenchTheme.accent : WorkbenchTheme.muted
        case .solid:
            fill = isEnabled ? WorkbenchTheme.accent : WorkbenchTheme.accent.withAlphaComponent(0.4)
            stroke = .clear
            foreground = .white
        case .outline:
            fill = WorkbenchTheme.paper
            stroke = WorkbenchTheme.line
            foreground = WorkbenchTheme.ink
        case .shortcut:
            fill = selected ? WorkbenchTheme.accentFill.withAlphaComponent(0.5) : WorkbenchTheme.soft
            stroke = selected ? WorkbenchTheme.accent.withAlphaComponent(0.18) : WorkbenchTheme.line
            foreground = selected ? WorkbenchTheme.accent : WorkbenchTheme.muted
        case .link, .plain, .system:
            fill = .clear
            stroke = .clear
            foreground =
                appearanceStyle == .link
                ? WorkbenchTheme.accent : (font?.pointSize ?? 12 >= 12 ? WorkbenchTheme.ink : WorkbenchTheme.muted)
        }
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()
        if isHighlighted {
            WorkbenchTheme.accent.withAlphaComponent(0.09).setFill()
            path.fill()
        }
        // Keep offline sample controls readable without making them actionable.
        if !isEnabled && !drawsDisabledAsReady && appearanceStyle != .solid {
            foreground = foreground.withAlphaComponent(0.65)
        }
        if appearanceStyle == .shortcut {
            if let symbolName {
                WorkbenchTheme.symbol(
                    symbolName, in: NSRect(x: (bounds.width - 19) / 2, y: 12, width: 19, height: 19), color: foreground)
            }
            WorkbenchTheme.text(
                title, in: NSRect(x: 3, y: 40, width: bounds.width - 6, height: 17), size: 11, color: foreground,
                alignment: .center)
            return
        }
        let nav = appearanceStyle == .navigation
        let iconSize: CGFloat = nav ? 17 : 14
        let measured = (title as NSString).size(withAttributes: [.font: contentFont]).width
        let total = min(bounds.width - 16, measured + (symbolName == nil ? 0 : iconSize + 8))
        let x: CGFloat = alignment == .left || nav ? 12 : max(8, (bounds.width - total) / 2)
        if let symbolName {
            WorkbenchTheme.symbol(
                symbolName, in: NSRect(x: x, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize),
                color: foreground)
        }
        let textX = x + (symbolName == nil ? 0 : iconSize + 8)
        WorkbenchTheme.text(
            title,
            in: NSRect(
                x: textX, y: (bounds.height - 17) / 2, width: bounds.width - textX - (badge.isEmpty ? 8 : 43),
                height: 20), size: font?.pointSize ?? 12,
            weight: selected || appearanceStyle == .solid ? .medium : .regular, color: foreground)
        if !badge.isEmpty {
            let badgeRect = NSRect(x: bounds.width - 35, y: (bounds.height - 20) / 2, width: 25, height: 20)
            if selected {
                WorkbenchTheme.accent.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4).fill()
            }
            WorkbenchTheme.text(
                badge, in: badgeRect.offsetBy(dx: 0, dy: 3), size: 10, color: foreground, alignment: .center)
        }
    }
}

final class WorkbenchHelpCard: WorkbenchSurface {
    let heading = NSTextField(labelWithString: "")
    let body = NSTextField(wrappingLabelWithString: "")
    let action = WorkbenchActionButton()
    var symbolName = "book"
    override init(frame: NSRect) {
        super.init(frame: frame)
        fill = WorkbenchTheme.soft
        heading.font = .systemFont(ofSize: 12, weight: .medium)
        heading.textColor = WorkbenchTheme.ink
        body.font = .systemFont(ofSize: 10)
        body.textColor = WorkbenchTheme.muted
        action.appearanceStyle = .link
        action.alignment = .left
        action.font = .systemFont(ofSize: 11)
        [heading, body, action].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        fill.setFill()
        path.fill()
        WorkbenchTheme.line.setStroke()
        path.stroke()
        WorkbenchTheme.symbol(symbolName, in: NSRect(x: 15, y: 16, width: 16, height: 16), color: WorkbenchTheme.accent)
    }
    override func layout() {
        super.layout()
        heading.frame = NSRect(x: 39, y: 14, width: bounds.width - 51, height: 21)
        body.frame = NSRect(x: 15, y: 42, width: bounds.width - 30, height: bounds.height - 78)
        action.frame = NSRect(x: 3, y: bounds.height - 37, width: bounds.width - 10, height: 28)
    }
}

final class WorkbenchSegmentedControl: NSSegmentedControl {
    var symbols: [String] = []
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        WorkbenchTheme.color(0xE8EDF0, 0x1C282F).setFill()
        path.fill()
        WorkbenchTheme.line.setStroke()
        path.stroke()
        guard segmentCount > 0 else { return }
        let width = (bounds.width - 6) / CGFloat(segmentCount)
        for i in 0..<segmentCount {
            let segment = NSRect(x: 3 + CGFloat(i) * width, y: 3, width: width, height: bounds.height - 6)
            let selected = selectedSegment == i
            if selected {
                WorkbenchTheme.paper.setFill()
                NSBezierPath(roundedRect: segment, xRadius: 4, yRadius: 4).fill()
            }
            let color = selected ? WorkbenchTheme.accent : WorkbenchTheme.muted
            let hasIcon = symbols.indices.contains(i)
            if hasIcon {
                WorkbenchTheme.symbol(
                    symbols[i], in: NSRect(x: segment.minX + 11, y: segment.midY - 6, width: 12, height: 12),
                    color: color)
            }
            WorkbenchTheme.text(
                label(forSegment: i) ?? "",
                in: NSRect(
                    x: segment.minX + (hasIcon ? 28 : 5), y: segment.midY - 7,
                    width: segment.width - (hasIcon ? 31 : 10), height: 19), size: 10.5, color: color,
                alignment: hasIcon ? .left : .center)
        }
    }
}

final class WorkbenchRoundedSurface: WorkbenchSurface {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        fill.setFill()
        path.fill()
        WorkbenchTheme.line.setStroke()
        path.stroke()
    }
}

/// Fits the actual capture inside a narrow device bezel; the card itself never becomes a black canvas.
/// Pointer coordinates remain relative to the unchanged embedded PhoneControlView.
struct WorkbenchPhoneGeometry {
    let body: NSRect
    let screen: NSRect
    let cornerRadius: CGFloat
    let screenCornerRadius: CGFloat
    let landscape: Bool

    init(screenSize: CGSize, bounds: NSRect, model: WorkbenchPhoneModel = .neutral) {
        let valid =
            screenSize.width > 0 && screenSize.height > 0
            && screenSize.width.isFinite && screenSize.height.isFinite
        let size = valid ? screenSize : CGSize(width: 390, height: 844)
        landscape = size.width > size.height
        let short = min(size.width, size.height)
        let side = model == .classicHome ? short * 0.052 : short * 0.024
        let end = model == .classicHome ? short * 0.24 : side
        let insetX = landscape ? end : side
        let insetY = landscape ? side : end
        let available = bounds.insetBy(dx: 7, dy: 6)
        let scale = max(
            0,
            min(
                available.width / (size.width + 2 * insetX),
                available.height / (size.height + 2 * insetY)))
        let total = NSSize(
            width: (size.width + 2 * insetX) * scale,
            height: (size.height + 2 * insetY) * scale)
        body = NSRect(
            x: bounds.midX - total.width / 2, y: bounds.midY - total.height / 2,
            width: total.width, height: total.height)
        screen = body.insetBy(dx: insetX * scale, dy: insetY * scale)
        cornerRadius = short * scale * (model == .classicHome ? 0.16 : 0.13)
        screenCornerRadius = model == .classicHome ? short * scale * 0.008 : max(0, cornerRadius - side * scale)
    }
}

/// A native vector enclosure selected from exact ProductType. Capture remains the input target.
final class WorkbenchPhoneShell: WorkbenchSurface {
    let content: NSView
    private let trim = WorkbenchPhoneTrim()
    var model: WorkbenchPhoneModel = .neutral {
        didSet {
            if model != oldValue {
                needsLayout = true
                needsDisplay = true
            }
        }
    }
    var screenSize = CGSize(width: 390, height: 844) {
        didSet {
            if screenSize != oldValue {
                needsLayout = true
                needsDisplay = true
            }
        }
    }
    var geometry: WorkbenchPhoneGeometry {
        WorkbenchPhoneGeometry(screenSize: screenSize, bounds: bounds, model: model)
    }
    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        addSubview(content)
        addSubview(trim)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let layout = geometry
        let body = NSBezierPath(roundedRect: layout.body, xRadius: layout.cornerRadius, yRadius: layout.cornerRadius)
        NSColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 1).setFill()
        body.fill()
        NSColor(srgbRed: 0.43, green: 0.48, blue: 0.51, alpha: 1).setStroke()
        body.lineWidth = model == .flatNotch ? 2 : 1.3
        body.stroke()
        guard !layout.landscape else { return }
        NSColor(srgbRed: 0.30, green: 0.34, blue: 0.37, alpha: 1).setFill()
        for (x, fraction, height) in [
            (layout.body.minX - 2, 0.23, 0.06),
            (layout.body.minX - 2, 0.32, 0.06),
            (layout.body.maxX, 0.27, 0.10),
        ] {
            NSBezierPath(
                roundedRect: NSRect(
                    x: x, y: layout.body.minY + layout.body.height * fraction,
                    width: 2, height: layout.body.height * height),
                xRadius: 1, yRadius: 1
            ).fill()
        }
    }
    override func layout() {
        super.layout()
        let layout = geometry
        if content.frame != layout.screen { content.frame = layout.screen }
        content.layer?.cornerRadius = layout.screenCornerRadius
        trim.frame = bounds
        trim.model = model
        trim.geometry = layout
        trim.needsDisplay = true
    }
}

/// Non-interactive hardware details; SE parts stay outside the display; notches occupy its empty center.
private final class WorkbenchPhoneTrim: WorkbenchSurface {
    var model = WorkbenchPhoneModel.neutral
    var geometry = WorkbenchPhoneGeometry(screenSize: .zero, bounds: .zero)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let g = geometry
        // Rotate decoration coordinates with the display, without changing the input view.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = AffineTransform(translationByX: g.body.midX, byY: g.body.midY)
        (transform as NSAffineTransform).concat()
        if g.landscape {
            let rotation = NSAffineTransform()
            rotation.rotate(byDegrees: -90)
            rotation.concat()
        }
        let w = g.landscape ? g.body.height : g.body.width
        let h = g.landscape ? g.body.width : g.body.height
        let sw = g.landscape ? g.screen.height : g.screen.width
        let sh = g.landscape ? g.screen.width : g.screen.height
        let screen = NSRect(x: -sw / 2, y: -sh / 2, width: sw, height: sh)
        let top = -h / 2
        if model == .classicHome {
            let end = (h - sh) / 2
            let speaker = NSRect(x: -w * 0.09, y: top + end * 0.52, width: w * 0.18, height: w * 0.018)
            NSColor(srgbRed: 0.24, green: 0.26, blue: 0.28, alpha: 1).setFill()
            NSBezierPath(roundedRect: speaker, xRadius: 2, yRadius: 2).fill()
            NSBezierPath(
                ovalIn: NSRect(
                    x: -w * 0.21, y: speaker.midY - w * 0.015,
                    width: w * 0.03, height: w * 0.03)
            ).fill()
            let diameter = end * 0.67
            let home = NSRect(
                x: -diameter / 2, y: sh / 2 + (end - diameter) / 2,
                width: diameter, height: diameter)
            NSColor(srgbRed: 0.30, green: 0.32, blue: 0.34, alpha: 1).setStroke()
            let ring = NSBezierPath(ovalIn: home)
            ring.lineWidth = 1.3
            ring.stroke()
        } else if model == .flatNotch || model == .roundedNotch {
            let notch = NSRect(x: -sw * 0.23, y: screen.minY - 1, width: sw * 0.46, height: sw * 0.085)
            NSColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 1).setFill()
            NSBezierPath(roundedRect: notch, xRadius: sw * 0.035, yRadius: sw * 0.035).fill()
            NSColor(srgbRed: 0.24, green: 0.26, blue: 0.28, alpha: 1).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: -sw * 0.09, y: notch.midY - 1, width: sw * 0.18, height: 2),
                xRadius: 1, yRadius: 1
            ).fill()
        } else if model == .dynamicIsland {
            NSColor.black.setFill()
            let island = NSRect(x: -sw * 0.16, y: screen.minY + sw * 0.035, width: sw * 0.32, height: sw * 0.075)
            NSBezierPath(roundedRect: island, xRadius: island.height / 2, yRadius: island.height / 2).fill()
        }
    }
}
