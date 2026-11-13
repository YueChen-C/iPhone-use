import AppKit
import UniformTypeIdentifiers

/// Local plan/review UI only. A running GUI owns an input lease; it must never
/// offer an in-process mount button that could bypass the offline CLI gate.
final class DDIReviewWindowController: NSWindowController, NSTextFieldDelegate {
    private let fields = (0..<6).map { _ in NSTextField(string: "") }
    private let result = NSTextView()
    private let createButton: NSButton
    private let inspectButton: NSButton
    private let openButton: NSButton
    private let copyButton: NSButton
    private let recoveryButton: NSButton
    private var texts: StringsDDIReview
    private var labels: [NSTextField] = []
    private var chooseButtons: [NSButton] = []
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let offline = NSTextField(wrappingLabelWithString: "")
    private var languageObserver: NSObjectProtocol?
    private var commands: String?
    private var busy = false

    init(language: AppLanguage) {
        let texts = StringsDDIReview(language: language)
        self.texts = texts
        createButton = NSButton(title: texts.create, target: nil, action: nil)
        inspectButton = NSButton(title: texts.inspect, target: nil, action: nil)
        openButton = NSButton(title: texts.open, target: nil, action: nil)
        copyButton = NSButton(title: texts.copy, target: nil, action: nil)
        recoveryButton = NSButton(title: texts.recovery, target: nil, action: nil)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 860, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = texts.title; window.isReleasedWhenClosed = false; window.minSize = .init(width: 720, height: 640)
        super.init(window: window)
        build(window)
        window.center()
        languageObserver = NotificationCenter.default.addObserver(forName: AppLanguageStore.didChangeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.refreshLocalization() }
    }
    deinit { if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) } }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build(_ window: NSWindow) {
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        notice.stringValue = texts.notice
        notice.font = .systemFont(ofSize: 12); stack.addArrangedSubview(notice)
        let names = [texts.device, texts.candidate, texts.candidateReceipt, texts.baseline, texts.baselineReceipt, texts.transaction]
        for index in fields.indices {
            let label = NSTextField(labelWithString: names[index]); label.widthAnchor.constraint(equalToConstant: 190).isActive = true
            labels.append(label)
            let field = fields[index]; field.placeholderString = names[index]; field.setAccessibilityLabel(names[index]); field.delegate = self
            let row = NSStackView(views: [label, field]); row.spacing = 8
            if index > 0 {
                let button = NSButton(title: texts.choose, target: self, action: #selector(choose(_:))); button.tag = index
                chooseButtons.append(button)
                row.addArrangedSubview(button)
            }
            stack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let actions = NSStackView(views: [inspectButton, createButton, openButton, copyButton]); actions.spacing = 8
        for (button, selector) in [(inspectButton, #selector(inspectDevice)), (createButton, #selector(createPlan)),
                                   (openButton, #selector(openTransaction)), (copyButton, #selector(copyCommands))] {
            button.target = self; button.action = selector
        }
        copyButton.isEnabled = false; stack.addArrangedSubview(actions)
        actions.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        recoveryButton.target = self; recoveryButton.action = #selector(findRecovery)
        stack.addArrangedSubview(recoveryButton)
        offline.stringValue = texts.offline; offline.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(offline)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        result.isEditable = false; result.isRichText = false; result.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        result.frame = .init(x: 0, y: 0, width: 800, height: 240)
        result.minSize = .zero; result.maxSize = .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        result.isVerticallyResizable = true; result.isHorizontallyResizable = false; result.autoresizingMask = [.width]
        result.textContainer?.widthTracksTextView = true
        result.textContainer?.containerSize = .init(width: 800, height: CGFloat.greatestFiniteMagnitude)
        result.setAccessibilityLabel(texts.title); scroll.documentView = result
        stack.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        notice.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        offline.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if let content = window.contentView {
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
                scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)])
        }
    }
    private func refreshLocalization() {
        texts = .current; window?.title = texts.title; notice.stringValue = texts.notice; offline.stringValue = texts.offline
        let names = [texts.device, texts.candidate, texts.candidateReceipt, texts.baseline, texts.baselineReceipt, texts.transaction]
        for index in fields.indices {
            labels[index].stringValue = names[index]; fields[index].placeholderString = names[index]
            fields[index].setAccessibilityLabel(names[index])
        }
        for button in chooseButtons { button.title = texts.choose }
        inspectButton.title = texts.inspect; createButton.title = texts.create; openButton.title = texts.open; copyButton.title = texts.copy
        recoveryButton.title = texts.recovery
        result.setAccessibilityLabel(texts.title)
        if busy { result.string = texts.working }
    }
    @objc private func choose(_ sender: NSButton) {
        guard !busy else { return }
        commands = nil; copyButton.isEnabled = false
        let index = sender.tag
        if index == 5 {
            let panel = NSSavePanel(); panel.canCreateDirectories = true; panel.nameFieldStringValue = "DDI-transaction-" + UUID().uuidString
            if panel.runModal() == .OK, let url = panel.url { fields[index].stringValue = url.path }
        } else {
            let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
            panel.canChooseDirectories = index == 1 || index == 3; panel.canChooseFiles = !panel.canChooseDirectories
            panel.treatsFilePackagesAsDirectories = true
            if panel.canChooseFiles { panel.allowedContentTypes = [.json] }
            if panel.runModal() == .OK, let url = panel.url { fields[index].stringValue = url.path }
        }
    }
    @objc private func inspectDevice() { run(.inspect(fields[0].stringValue)) }
    @objc private func findRecovery() { run(.recovery) }
    @objc private func createPlan() {
        run(.plan(device: fields[0].stringValue, candidate: fields[1].stringValue, candidateReceipt: fields[2].stringValue,
                  baseline: fields[3].stringValue, baselineReceipt: fields[4].stringValue, directory: fields[5].stringValue))
    }
    @objc private func openTransaction() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { fields[5].stringValue = url.path; run(.status(url.path)) }
    }
    @objc private func copyCommands() {
        guard !busy, let commands else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(commands, forType: .string)
    }
    func controlTextDidChange(_ notification: Notification) {
        commands = nil; copyButton.isEnabled = false
    }
    private func run(_ request: DDIReviewRequest) {
        guard !busy else { return }
        commands = nil; copyButton.isEnabled = false
        do { _ = try request.arguments() } catch { result.string = "\(error)"; return }
        guard let executable = Bundle.main.executableURL else { return }
        busy = true; commands = nil; copyButton.isEnabled = false
        for field in fields { field.isEnabled = false }
        for button in chooseButtons { button.isEnabled = false }
        for button in [createButton, inspectButton, openButton, recoveryButton] { button.isEnabled = false }
        result.string = texts.working
        DispatchQueue.global(qos: .utility).async { [self] in
            let outcome = Result { try DDIReviewClient(executable: executable).run(request) }
            DispatchQueue.main.async { [self] in
                busy = false
                for field in fields { field.isEnabled = true }
                for button in chooseButtons { button.isEnabled = true }
                for button in [createButton, inspectButton, openButton, recoveryButton] { button.isEnabled = true }
                switch outcome {
                case .success(let report):
                    commands = report.offlineCommands; copyButton.isEnabled = commands != nil
                    result.string = report.json + (commands.map { "\n\n" + texts.offline + "\n\n" + $0 } ?? "")
                case .failure(let error): result.string = "\(error)"
                }
            }
        }
    }
}
