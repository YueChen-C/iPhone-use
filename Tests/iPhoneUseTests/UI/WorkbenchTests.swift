import AppKit
import XCTest

@testable import iPhoneUse

final class WorkbenchStateTests: XCTestCase {
    func testScreenshotExportRequiresIdentityBeforeAndAfterEncoding() throws {
        let bytes = Data([1, 2, 3])
        XCTAssertEqual(
            String(describing: WorkbenchScreenshotCapture.Failure.identityUnverified),
            StringsWorkbench.current.screenshotIdentityUnverified)
        var encoded = 0
        XCTAssertThrowsError(try WorkbenchScreenshotCapture.capture(
            isCurrent: { true }, identityConfirmed: { false }, snapshot: { encoded += 1; return bytes }
        )) { XCTAssertEqual($0 as? WorkbenchScreenshotCapture.Failure, .identityUnverified) }
        XCTAssertThrowsError(try WorkbenchScreenshotCapture.capture(
            isCurrent: { false }, identityConfirmed: { true }, snapshot: { encoded += 1; return bytes }
        )) { XCTAssertEqual($0 as? WorkbenchScreenshotCapture.Failure, .disconnected) }
        XCTAssertEqual(encoded, 0)

        XCTAssertEqual(try WorkbenchScreenshotCapture.capture(
            isCurrent: { true }, identityConfirmed: { true }, snapshot: { bytes }), bytes)
        XCTAssertThrowsError(try WorkbenchScreenshotCapture.capture(
            isCurrent: { true }, identityConfirmed: { true }, snapshot: { nil }
        )) { XCTAssertEqual($0 as? WorkbenchScreenshotCapture.Failure, .notReady) }

        var current = true
        XCTAssertThrowsError(try WorkbenchScreenshotCapture.capture(
            isCurrent: { current }, identityConfirmed: { true }, snapshot: { current = false; return bytes }
        )) { XCTAssertEqual($0 as? WorkbenchScreenshotCapture.Failure, .disconnected) }
        var confirmed = true
        XCTAssertThrowsError(try WorkbenchScreenshotCapture.capture(
            isCurrent: { true }, identityConfirmed: { confirmed }, snapshot: { confirmed = false; return bytes }
        )) { XCTAssertEqual($0 as? WorkbenchScreenshotCapture.Failure, .identityUnverified) }
    }

    func testPaginationCapsThreeAndKeepsExactSelectionOnDestinationPage() {
        var state = WorkbenchState()
        state.reconcile((1...8).map { device("id-\($0)", "Phone \($0)") })
        state.setPageCapacity(10)
        XCTAssertEqual(state.pageCapacity, 3)
        XCTAssertEqual(state.visible.map(\.id), ["id-1", "id-2", "id-3"])
        XCTAssertEqual(state.pageCount, 3)
        XCTAssertFalse(state.hasPreviousPage)
        XCTAssertEqual(state.pageTarget(offset: 1), "id-4")
        XCTAssertTrue(state.select(state.pageTarget(offset: 1)!))
        XCTAssertEqual(state.pageIndex, 1)
        XCTAssertEqual(state.visible.map(\.id), ["id-4", "id-5", "id-6"])
        state.select("id-8")
        XCTAssertEqual(state.pageIndex, 2)
        XCTAssertEqual(state.visible.map(\.id), ["id-7", "id-8"])
        XCTAssertNil(state.pageTarget(offset: 1))
        state.setPageCapacity(1)
        XCTAssertEqual(state.visible.map(\.id), ["id-8"])
        XCTAssertEqual(state.pageIndex, 7)
        state.layout = .focus
        XCTAssertEqual(state.pageTarget(offset: -1), "id-7")
        XCTAssertFalse(state.select("id"))
        XCTAssertEqual(state.selectedID, "id-8")
        state.query = "Phone 1"
        XCTAssertTrue(state.visible.isEmpty)
        state.layout = .grid
        XCTAssertEqual(state.visible.map(\.id), ["id-1"])
        state.query = "no match"
        XCTAssertEqual(state.pageCount, 1)
        XCTAssertTrue(state.visible.isEmpty)
        XCTAssertNil(state.pageTarget(offset: 1))
    }
    private func device(_ id: String, _ name: String = "same name") -> WorkbenchDevice {
        WorkbenchDevice(
            id: id, name: name, connected: true, backend: .ble, status: "ready", shortcuts: [.home, .enter])
    }

    func testExactIdentityNotNameOrPrefixAndSelectionSurvivesDisconnect() {
        var state = WorkbenchState()
        state.reconcile([device("phone-12"), device("phone-1")])
        XCTAssertEqual(state.devices.count, 2)
        XCTAssertTrue(state.select("phone-12"))
        XCTAssertFalse(state.select("phone"))
        XCTAssertEqual(state.selectedID, "phone-12")
        state.reconcile([device("phone-1")])
        XCTAssertEqual(state.selectedID, "phone-12")
        XCTAssertFalse(state.selected!.connected)
        XCTAssertTrue(state.selected!.shortcuts.isEmpty)
        state.reconcile([device("phone-12"), device("new-phone")])
        XCTAssertEqual(state.selectedID, "phone-12")
        XCTAssertTrue(state.selected!.connected)
        XCTAssertEqual(state.devices.count, 3)
    }

    func testRemoveDisconnectedRequiresExactIDAndKeepsFilteredSelectionValid() {
        var state = WorkbenchState()
        let a = device("phone-a", "iPhone")
        let b = device("phone-ab", "iPhone")
        let c = device("other", "Other")
        state.reconcile([a, b, c])
        state.layout = .focus
        state.query = "iPhone"
        XCTAssertTrue(state.select(a.id))
        XCTAssertFalse(state.removeDisconnected(a.id), "a connected device cannot be removed")
        state.reconcile([b, c])
        XCTAssertFalse(state.removeDisconnected("phone"), "partial IDs do not target any card")
        XCTAssertTrue(state.removeDisconnected(a.id))
        XCTAssertEqual(state.selectedID, b.id)
        XCTAssertEqual(state.visible.map(\.id), [b.id])
        state.reconcile([b, c])
        XCTAssertEqual(Set(state.devices.map(\.id)), [b.id, c.id])
        state.reconcile([a, b, c])
        XCTAssertEqual(Set(state.devices.map(\.id)), [a.id, b.id, c.id])
        XCTAssertEqual(state.selectedID, b.id)
    }

    func testRemoveLastDisconnectedCardResetsSelectionAndPage() {
        var state = WorkbenchState()
        state.reconcile([device("a"), device("b")])
        state.setPageCapacity(1)
        XCTAssertTrue(state.select("b"))
        XCTAssertEqual(state.pageIndex, 1)
        state.reconcile([])
        XCTAssertTrue(state.removeDisconnected("b"))
        XCTAssertEqual(state.pageIndex, 0)
        XCTAssertEqual(state.selectedID, "a")
        XCTAssertTrue(state.removeDisconnected("a"))
        XCTAssertTrue(state.visible.isEmpty)
        XCTAssertNil(state.selectedID)
    }

    func testSearchAndFocusDoNotMutateInputIdentity() {
        var state = WorkbenchState()
        state.reconcile([device("a", "Office"), device("b", "Lab")])
        XCTAssertTrue(state.select("b"))
        state.query = "OFFICE"
        XCTAssertEqual(state.matching.map(\.id), ["a"])
        state.layout = .focus
        XCTAssertTrue(state.visible.isEmpty)
        XCTAssertEqual(state.selectedID, "b")
        state.query = ""
        XCTAssertEqual(state.visible.map(\.id), ["b"])
        state.layout = .grid
        XCTAssertEqual(state.visible.count, 2)
    }

    func testRepeatedDiscoveryDoesNotDuplicateTilesAndCarriesBackendCapability() {
        var state = WorkbenchState()
        var usb = device("b")
        usb.backend = .usb
        usb.shortcuts = [.enter]
        for _ in 0..<5 { state.reconcile([device("a"), usb]) }
        XCTAssertEqual(state.devices.count, 2)
        XCTAssertTrue(state.select("b"))
        XCTAssertEqual(state.selected?.backend, .usb)
        XCTAssertFalse(state.selected!.shortcuts.contains(.home))
        XCTAssertTrue(state.selected!.shortcuts.contains(.enter))
    }

    func testDuplicateIDsInSingleSnapshotUseOnlyFirstIdentity() {
        var state = WorkbenchState()
        state.reconcile([device("a", "original"), device("a", "duplicate"), device("b")])
        XCTAssertEqual(state.devices.count, 2)
        XCTAssertEqual(state.devices.first { $0.id == "a" }?.name, "original")
        state.reconcile([device("a", "renamed"), device("a", "other")])
        XCTAssertEqual(state.devices.count, 2)
        XCTAssertEqual(state.selected?.name, "renamed")
    }

    func testCancelledTextDispatchCannotBecomeCurrentAgain() {
        let pending = ControlTextDispatch()
        XCTAssertFalse(pending.isCancelled)
        pending.cancel()
        pending.cancel()
        XCTAssertTrue(pending.isCancelled)
        XCTAssertFalse(ControlTextDispatch().isCancelled)
    }

    func testCancelledTextCompletionKeepsUncertainOutcomeInsteadOfLateSuccess() throws {
        let pending = ControlTextDispatch()
        XCTAssertNoThrow(try pending.finalResult(.success(())).get())
        let failure = DeviceError("offline fixture")
        XCTAssertThrowsError(try pending.finalResult(.failure(failure)).get()) {
            XCTAssertEqual(String(describing: $0), "offline fixture")
        }
        pending.cancel()
        XCTAssertThrowsError(try pending.finalResult(.success(())).get()) {
            XCTAssertEqual(String(describing: $0), StringsWorkbench.current.textCancelled)
        }
        XCTAssertTrue(pending.isCancelled)
        XCTAssertTrue(StringsWorkbench.zh.textCancelled.contains("可能"))
        XCTAssertTrue(StringsWorkbench.en.textCancelled.contains("may already"))
    }

    func testOnlyActiveVisibleEmbeddedPhonesRender() {
        for active in [false, true] {
            for visible in [false, true] {
                for independent in [false, true] {
                    XCTAssertEqual(
                        WorkbenchRenderPolicy.shouldRun(active: active, visible: visible, independent: independent),
                        active && visible && !independent)
                }
            }
        }
    }

    func testQuietModeDoesNotPresentUntilUserRequestAndDoesNotQuitOnClose() {
        var visibility = WorkbenchVisibility()
        XCTAssertFalse(visibility.shouldPresent(mode: .residentQuiet, reason: .discovery))
        XCTAssertFalse(visibility.shouldPresent(mode: .residentQuiet, reason: .resumeDesktopMode))
        XCTAssertTrue(visibility.shouldPresent(mode: .residentQuiet, reason: .userRequest))
        XCTAssertFalse(visibility.shouldPresent(mode: .residentQuiet, reason: .userRequest))
        XCTAssertFalse(visibility.close(mode: .residentQuiet, hasIndependentWindows: false))
        XCTAssertFalse(visibility.isOpen)
    }

    func testDesktopCloseWaitsForIndependentWindowsAndCanReopen() {
        var visibility = WorkbenchVisibility()
        XCTAssertTrue(visibility.shouldPresent(mode: .desktop, reason: .discovery))
        XCTAssertFalse(visibility.close(mode: .desktop, hasIndependentWindows: true))
        XCTAssertTrue(visibility.shouldPresent(mode: .desktop, reason: .userRequest))
        XCTAssertTrue(visibility.close(mode: .desktop, hasIndependentWindows: false))
    }

    func testInfoContentKeepsRealCommandsRulesAndNeverClaimsPrototypeRuntime() {
        for language in AppLanguage.allCases {
            for kind in WorkbenchInfoKind.allCases {
                let content = WorkbenchInfoContent(kind: kind, language: language,
                    executable: URL(fileURLWithPath: "/a b/it's/tool"), port: 8123, preview: false)
                XCTAssertFalse(content.title.isEmpty)
                XCTAssertFalse(content.introduction.isEmpty)
                XCTAssertFalse(content.detail.isEmpty)
                XCTAssertFalse(content.notice.isEmpty)
                XCTAssertFalse(content.notice.contains("原型"))
                if kind == .mcp {
                    XCTAssertEqual(content.code, "codex mcp add iphone-use -- '/a b/it'\\''s/tool' mcp")
                    XCTAssertTrue(content.detail.contains("./scripts/install-codex-mcp.sh"))
                } else if kind == .api {
                    XCTAssertTrue(content.code?.contains("127.0.0.1:8123/devices") == true)
                    XCTAssertTrue(content.code?.contains("device=DEVICE_ID") == true)
                } else {
                    XCTAssertNil(content.code)
                    XCTAssertTrue(content.introduction.contains("17.3"))
                    XCTAssertTrue(content.introduction.contains("17+"))
                }
            }
        }
    }

    func testMCPCommandQuotesActualExecutableIncludingSpacesAndQuotes() {
        XCTAssertEqual(
            WorkbenchConfiguration.mcpCommand(executable: URL(fileURLWithPath: "/a b/it's/tool")),
            "codex mcp add iphone-use -- '/a b/it'\\''s/tool' mcp")
    }

    func testNewLocalizationKeysAreCompleteAndDifferentWhereExpected() {
        for language in AppLanguage.allCases {
            let table = StringsWorkbench(language: language)
            for field in Mirror(reflecting: table).children {
                XCTAssertFalse((field.value as! String).isEmpty, "\(field.label ?? "") \(language)")
            }
        }
        XCTAssertNotEqual(StringsWorkbench.zh.title, StringsWorkbench.en.title)
        XCTAssertTrue(StringsWorkbench.en.backendHelp.contains("never"))
    }

    func testUnboundPhoneTextIsRefusedSynchronouslyWithoutServiceWork() {
        let view = PhoneControlView(deviceID: "not-a-device", frame: .zero)
        var outcome: Result<Void, Error>?
        view.sendText("hello") { outcome = $0 }
        guard case .failure = outcome else { return XCTFail("unbound view must refuse input") }
        XCTAssertFalse(view.isRendering)
        view.isKeyboardTarget = false
        XCTAssertFalse(view.acceptsLocalKeyEquivalents)
    }
}

final class WorkbenchNativeViewTests: XCTestCase {
    func testHeaderLanguageSwitchUpdatesImmediatelyAndPersists() throws {
        _ = NSApplication.shared
        let store = AppLanguageStore.shared
        let defaults = UserDefaults.standard
        let savedValue = defaults.object(forKey: AppLanguageStore.defaultsKey)
        let previousLanguage = store.language
        defer {
            store.set(previousLanguage)
            defaults.set(savedValue, forKey: AppLanguageStore.defaultsKey)
        }
        store.set(.zh)
        let controller = WorkbenchWindowController()
        defer { controller.stop() }
        let root = controller.root
        let window = try XCTUnwrap(controller.window)
        let picker = try XCTUnwrap(root.subviews.compactMap { $0 as? NSSegmentedControl }.first {
            $0.accessibilityIdentifier() == "workbench-language"
        }, "The workbench header must expose its own language control")
        let search = try XCTUnwrap(root.subviews.compactMap { $0 as? NSSearchField }.first)
        let draft = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextField }.first {
            $0.accessibilityLabel() == StringsWorkbench.zh.textInput
        })

        for width: CGFloat in [1080, 1220, 1680] {
            root.frame.size.width = width
            renderLayout(root)
            XCTAssertTrue(root.bounds.contains(picker.frame))
            XCTAssertFalse(picker.frame.intersects(search.frame))
        }
        XCTAssertEqual(picker.label(forSegment: 0), "中文")
        XCTAssertEqual(picker.label(forSegment: 1), "English")
        XCTAssertEqual(picker.selectedSegment, 0)
        XCTAssertEqual(search.placeholderString, StringsWorkbench.zh.search)
        search.stringValue = "Demo iPhone"
        root.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        draft.stringValue = "Draft, not sent"
        root.setLayout(.focus)

        for (index, language) in [(1, AppLanguage.en), (0, AppLanguage.zh)] {
            picker.selectedSegment = index
            XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
            let strings = StringsWorkbench(language: language)
            XCTAssertEqual(AppLanguageStore(defaults: defaults).language, language)
            XCTAssertEqual(search.placeholderString, strings.search)
            XCTAssertEqual(search.accessibilityLabel(), strings.search)
            XCTAssertEqual(draft.accessibilityLabel(), strings.textInput)
            XCTAssertEqual(window.title, "iPhone Use 2.0 — \(strings.title)")
            XCTAssertEqual(search.stringValue, "Demo iPhone")
            XCTAssertEqual(root.state.query, "Demo iPhone")
            XCTAssertEqual(draft.stringValue, "Draft, not sent")
            XCTAssertEqual(root.state.layout, .focus)
        }

        // The existing macOS menu uses this store; toggles there must update the header too.
        store.set(.en)
        XCTAssertEqual(picker.selectedSegment, 1)
    }

    func testInfoDialogsShareHTMLGeometryAndCoverWorkspaceWithoutPhoneOverlay() throws {
        _ = NSApplication.shared
        for size in [NSSize(width: 1440, height: 807), NSSize(width: 1080, height: 700)] {
            let root = WorkbenchRootView(frame: NSRect(origin: .zero, size: size), preview: true)
            let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.loadPreview([WorkbenchDevice(id: "exact-a", name: "a", connected: true, backend: .ble, status: "ready")])
            root.select("exact-a")
            for kind in WorkbenchInfoKind.allCases {
                root.showInfo(kind)
                renderLayout(root)
                let overlay = try XCTUnwrap(root.infoOverlay)
                overlay.layoutSubtreeIfNeeded()
                overlay.card.layoutSubtreeIfNeeded()
                let card = overlay.card
                XCTAssertTrue(overlay.superview === root)
                XCTAssertTrue(root.subviews.last === overlay)
                XCTAssertEqual(overlay.frame, root.bounds)
                XCTAssertEqual(card.frame.width, 570, accuracy: 1)
                XCTAssertEqual(card.frame.midX, root.bounds.midX, accuracy: 1)
                XCTAssertEqual(card.frame.midY, root.bounds.midY, accuracy: 1)
                XCTAssertTrue(root.bounds.contains(card.frame))
                XCTAssertEqual(card.heading.font?.pointSize, 20)
                XCTAssertEqual(card.heading.frame.minX, 28)
                XCTAssertTrue(card.bodyScroll.hasVerticalScroller)
                XCTAssertFalse(card.code.isEditable)
                XCTAssertTrue(card.code.isSelectable)
                XCTAssertEqual(card.codeBox.isHidden, kind == .guide)
                XCTAssertTrue(card.bounds.contains(card.notice.frame))
                XCTAssertLessThanOrEqual(card.bodyScroll.frame.maxY, card.rule.frame.minY)
                XCTAssertEqual(root.state.selectedID, "exact-a")
                let outside = root.hitTest(NSPoint(x: 10, y: 100))
                XCTAssertTrue(outside === overlay)
                root.showInfo(kind)
                XCTAssertEqual(root.subviews.compactMap { $0 as? WorkbenchInfoOverlay }.count, 1)
                root.infoOverlay?.card.close.performClick(nil)
                XCTAssertNil(root.infoOverlay)
                XCTAssertEqual(root.state.selectedID, "exact-a")
            }
        }
    }

    func testInfoDialogEscapeDismissesAndKeepsDraftAndSelection() throws {
        _ = NSApplication.shared
        let root = WorkbenchRootView(frame: NSRect(x: 0, y: 0, width: 1080, height: 700), preview: true)
        let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        root.loadPreview([WorkbenchDevice(id: "exact-a", name: "a", connected: true, backend: .ble, status: "ready")])
        let text = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextField }.first {
            $0.isEditable && !($0 is NSSearchField)
        })
        text.stringValue = "draft-only"
        root.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: text))
        let previous = NSTextView(frame: .zero)
        root.addSubview(previous)
        window.makeFirstResponder(previous)
        root.showInfo(.mcp)
        let overlay = try XCTUnwrap(root.infoOverlay)
        XCTAssertTrue(window.firstResponder === overlay)
        let tab = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\t",
            charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        XCTAssertTrue(root.performKeyEquivalent(with: tab))
        XCTAssertTrue(window.firstResponder === overlay.card.close)
        overlay.card.code.cancelOperation(nil)
        XCTAssertNil(root.infoOverlay)
        XCTAssertTrue(window.firstResponder === previous)
        XCTAssertEqual(text.stringValue, "draft-only")
        XCTAssertEqual(root.state.selectedID, "exact-a")

        // Long paths on a short window scroll inside the card; close/footer remain visible.
        let content = WorkbenchInfoContent(kind: .mcp, language: .en,
            executable: URL(fileURLWithPath: "/" + String(repeating: "long-path/", count: 60) + "tool"),
            port: 7390, preview: true)
        let compact = WorkbenchInfoOverlay(kind: .mcp, content: content)
        compact.frame = NSRect(x: 0, y: 0, width: 600, height: 320)
        compact.layoutSubtreeIfNeeded()
        compact.card.layoutSubtreeIfNeeded()
        XCTAssertTrue(compact.bounds.contains(compact.card.frame))
        XCTAssertTrue(compact.card.bounds.contains(compact.card.close.frame))
        XCTAssertTrue(compact.card.bounds.contains(compact.card.notice.frame))
        XCTAssertGreaterThan(compact.card.body.bounds.height, compact.card.bodyScroll.bounds.height)
    }

    func testBlankCardAndBezelClicksSelectWithoutInterceptingPhoneContent() {
        _ = NSApplication.shared
        for rawScreens in [true, false] {
            let root = WorkbenchRootView(frame: NSRect(x: 0, y: 0, width: 1440, height: 700), preview: true)
            let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = root
            root.loadPreview((1...2).map {
                WorkbenchDevice(id: "id-\($0)", name: "Phone \($0)", connected: true, backend: .ble, status: "sample")
            }, rawScreens: rawScreens)
            renderLayout(root)
            let titles = descendants(root).compactMap { $0 as? NSButton }.filter {
                $0.toolTip == "id-1" || $0.toolTip == "id-2"
            }
            XCTAssertEqual(titles.count, 2)
            for title in titles {
                let id = title.toolTip!
                let card = title.superview!
                let other = id == "id-1" ? "id-2" : "id-1"
                var points: [(String, NSPoint)] = [
                    ("header", NSPoint(x: 5, y: 5)),
                    ("status", NSPoint(x: 25, y: 52)),
                    ("card-margin", NSPoint(x: 5, y: card.bounds.midY)),
                    ("footer", NSPoint(x: card.bounds.width - 35, y: card.bounds.height - 24)),
                ]
                if let shell = card.subviews.compactMap({ $0 as? WorkbenchPhoneShell }).first {
                    points.append(("shell-background", shell.convert(NSPoint(x: 2, y: shell.bounds.midY), to: card)))
                    points.append(("bezel", shell.convert(NSPoint(x: shell.geometry.body.midX,
                        y: shell.geometry.body.minY + 1), to: card)))
                    let screen = shell.content
                    let point = screen.convert(NSPoint(x: screen.bounds.midX, y: screen.bounds.midY), to: root.superview)
                    let hit = root.hitTest(point)
                    XCTAssertTrue(hit === screen || hit?.isDescendant(of: screen) == true)
                }
                for (area, point) in points {
                    root.select(other)
                    renderLayout(root)
                    // AppKit hitTest takes coordinates in the receiver's superview.
                    let hit = root.hitTest(card.convert(point, to: root.superview))
                    XCTAssertTrue(hit === card, "\(area) must select only the enclosing card")
                    let event = NSEvent.mouseEvent(with: .leftMouseDown,
                        location: card.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                    hit?.mouseDown(with: event)
                    XCTAssertEqual(root.state.selectedID, id, "\(area)")
                    print("BLANK_SELECTION shell=\(rawScreens) area=\(area) target=\(id) selected=\(root.state.selectedID ?? "nil")")
                }
                for button in card.subviews.compactMap({ $0 as? NSButton }) {
                    let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: root.superview)
                    XCTAssertTrue(root.hitTest(point) === button, "Command buttons must keep their hit target")
                }
                XCTAssertTrue(card.acceptsFirstMouse(for: nil))
            }
            let gap = titles[0].superview!
            let outside = gap.convert(NSPoint(x: gap.bounds.width + 5, y: gap.bounds.midY), to: gap.superview)
            XCTAssertNil(gap.hitTest(outside), "Do not select a device from the gap between cards")
        }
    }

    func testPaginationFitsOneRowAtEveryWindowWidthAndLeftSelectionRevealsPage() {
        _ = NSApplication.shared
        for (width, capacity) in [(1080, 1), (1440, 2), (1680, 3), (2400, 3)] {
            let root = WorkbenchRootView(frame: NSRect(x: 0, y: 0, width: width, height: 700), preview: true)
            root.loadPreview((1...8).map {
                WorkbenchDevice(id: "id-\($0)", name: "Phone \($0)", connected: true, backend: .ble, status: "sample")
            }, rawScreens: true)
            renderLayout(root)
            XCTAssertEqual(root.state.visible.count, capacity)
            let next = descendants(root).compactMap { $0 as? NSButton }.first {
                $0.accessibilityIdentifier() == "workbench-page-next"
            }!
            let previous = descendants(root).compactMap { $0 as? NSButton }.first {
                $0.accessibilityIdentifier() == "workbench-page-previous"
            }!
            XCTAssertTrue(next.isEnabled)
            XCTAssertFalse(previous.isEnabled)
            next.performClick(nil)
            renderLayout(root)
            XCTAssertEqual(root.state.pageIndex, 1)
            XCTAssertEqual(root.state.selectedID, "id-\(capacity + 1)")
            XCTAssertTrue(previous.isEnabled)
            root.select("id-8")
            renderLayout(root)
            XCTAssertTrue(root.state.visible.contains { $0.id == "id-8" })
            XCTAssertFalse(next.isEnabled)
            let cards = descendants(root).compactMap { $0 as? WorkbenchPhoneShell }
                .filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap(\.superview)
            XCTAssertLessThanOrEqual(cards.count, 3)
            for card in cards {
                XCTAssertEqual(card.frame.minY, 0)
                XCTAssertLessThanOrEqual(card.frame.maxX, card.superview!.bounds.width + 1)
                XCTAssertLessThanOrEqual(card.frame.maxY, card.superview!.bounds.height + 1)
            }
            root.frame.size.width = 1080
            renderLayout(root)
            XCTAssertEqual(root.state.visible.map(\.id), ["id-8"])
            previous.performClick(nil)
            renderLayout(root)
            XCTAssertEqual(root.state.selectedID, "id-7")
            root.setLayout(.focus)
            renderLayout(root)
            next.performClick(nil)
            renderLayout(root)
            XCTAssertEqual(root.state.visible.map(\.id), ["id-8"])
        }
    }
    func testEmbeddedGuidanceLivesOutsidePhoneAndKeepsErrorInputGate() {
        _ = NSApplication.shared
        let controller = ControlWindowController(deviceID: "offline-only", embedded: true)
        let guidance = controller.connectionGuidanceView
        XCTAssertEqual(guidance.presentation, .inspector)
        XCTAssertFalse(descendants(controller.embeddedView).contains { $0 is ControlConnectionOverlay })
        XCTAssertNil(guidance.superview)
        controller.controlView.onBackendSelectionFailed?("Cannot select this input backend")
        XCTAssertTrue(controller.controlView.isBackendNoticeVisible)
        XCTAssertFalse(guidance.isHidden)
        // Moving a notice does not acknowledge it or make unbound input ready.
        XCTAssertTrue(controller.availableShortcuts.isEmpty)
        guidance.showBackendSelectionFailure(nil)
        guidance.update(.connected)
        XCTAssertTrue(guidance.isHidden)
        // Standalone windows retain the original overlay presentation by default.
        XCTAssertEqual(ControlConnectionOverlay(frame: .zero).presentation, .screenOverlay)
    }

    func testSelectedInspectorGuidanceWrapsScrollsAndNeverEntersPhoneShell() {
        _ = NSApplication.shared
        let root = WorkbenchRootView(frame: NSRect(x: 0, y: 0, width: 1080, height: 700), preview: true)
        root.loadPreview([
            WorkbenchDevice(id: "a", name: "same", connected: true, backend: .ble, status: "unmatched"),
            WorkbenchDevice(id: "b", name: "same", connected: true, backend: .ble, status: "ready"),
        ], rawScreens: true, connectionStatuses: ["a": .unmatched, "b": .connected])
        renderLayout(root)
        let inspectorScroll = root.subviews.compactMap { $0 as? NSScrollView }.first!
        let inspector = inspectorScroll.documentView!
        let guidance = inspector.subviews.compactMap { $0 as? ControlConnectionOverlay }.first!
        XCTAssertEqual(guidance.accessibilityIdentifier(), "connection-guidance:a")
        XCTAssertFalse(guidance.isHidden)
        XCTAssertEqual(guidance.frame.width, 268)
        XCTAssertGreaterThan(guidance.frame.height, 150)
        guidance.layoutSubtreeIfNeeded()
        let viewOnly = descendants(guidance).compactMap { $0 as? NSButton }.first {
            $0.title == StringsUI.current.overlayButtonViewOnly
        }!
        let point = viewOnly.convert(NSPoint(x: viewOnly.bounds.midX, y: viewOnly.bounds.midY), to: inspector)
        let hit = guidance.hitTest(point)
        XCTAssertTrue(hit === viewOnly || hit?.isDescendant(of: viewOnly) == true)
        for shell in descendants(root).filter({ $0 is WorkbenchPhoneShell }) {
            XCTAssertFalse(descendants(shell).contains { $0 is ControlConnectionOverlay })
        }
        let home = descendants(inspector).compactMap { $0 as? WorkbenchActionButton }.first {
            $0.appearanceStyle == .shortcut && $0.symbolName == ControlShortcut.home.symbol
        }!
        XCTAssertGreaterThan(home.frame.minY, guidance.frame.maxY)
        XCTAssertGreaterThan(inspector.bounds.height, inspectorScroll.contentSize.height)
        guidance.setDismissed(true)
        renderLayout(root)
        XCTAssertEqual(guidance.frame.height, 28)
        root.select("b")
        renderLayout(root)
        XCTAssertNil(guidance.superview)
        let ready = inspector.subviews.compactMap { $0 as? ControlConnectionOverlay }.first!
        XCTAssertEqual(ready.accessibilityIdentifier(), "connection-guidance:b")
        XCTAssertTrue(ready.isHidden)
        root.select("a")
        renderLayout(root)
        XCTAssertTrue(guidance.superview === inspector)
        XCTAssertTrue(guidance.isDismissed)
        XCTAssertTrue(inspector.subviews.filter { !$0.isHidden }.allSatisfy { $0.frame.maxY <= inspector.bounds.height })
    }

    func testInspectorUSBSetupActionsAndLongGuidanceStayOutsideCapturedScreen() {
        _ = NSApplication.shared
        let controller = ControlWindowController(deviceID: "offline-only", embedded: true)
        let guidance = controller.connectionGuidanceView
        guidance.update(.disconnected)
        let parent = WorkbenchSurface(frame: NSRect(x: 0, y: 0, width: 312, height: 1400))
        parent.addSubview(guidance)
        guidance.translatesAutoresizingMaskIntoConstraints = true
        guidance.frame = NSRect(x: 22, y: 263, width: 268, height: guidance.preferredHeight(for: 268))
        guidance.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(guidance.subviews.filter { !$0.isHidden }.map { $0.frame.maxY }.max()!, guidance.bounds.height + 1)
        XCTAssertFalse(descendants(controller.embeddedView).contains { $0 === guidance })
        var setup = 0
        var cancel = 0
        guidance.onEnableUSB = { setup += 1 }
        guidance.onCancelUSBSetup = { cancel += 1 }
        guidance.updateUSB(ControlUSBPresentation(
            snapshot: ["state": InputBackendReadiness.requiresDDI.rawValue],
            inputReady: false, hasScreen: true))
        let enable = descendants(guidance).compactMap { $0 as? NSButton }.first {
            $0.title == StringsUSBSetup.current.enable
        }!
        enable.performClick(nil)
        XCTAssertEqual(setup, 1)
        guidance.updateSetup(.inspecting)
        XCTAssertEqual(enable.title, StringsUSBSetup.current.cancel)
        enable.performClick(nil)
        XCTAssertEqual(cancel, 1)
        guidance.updateSetup(.failed)
        XCTAssertFalse(guidance.isHidden)
        XCTAssertTrue(controller.availableShortcuts.isEmpty)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func renderLayout(_ root: WorkbenchRootView) {
        root.layoutSubtreeIfNeeded()
        for child in root.subviews { child.layoutSubtreeIfNeeded() }
    }

    func testOfflinePreviewSelectionFocusAndSearchUseOneStateWithoutHardware() {
        _ = NSApplication.shared
        let root = WorkbenchRootView(frame: NSRect(x: 0, y: 0, width: 1440, height: 850), preview: true)
        root.loadPreview([
            WorkbenchDevice(id: "first", name: "same", connected: true, backend: .ble, status: "example"),
            WorkbenchDevice(id: "second", name: "same", connected: true, backend: .usb, status: "example"),
        ])
        renderLayout(root)
        root.select("second")
        XCTAssertEqual(root.state.selectedID, "second")
        root.setLayout(.focus)
        XCTAssertEqual(root.state.visible.map(\.id), ["second"])
        XCTAssertFalse(descendants(root).contains { $0 is PhoneControlView })
        let search = descendants(root).compactMap { $0 as? NSSearchField }.first!
        search.stringValue = "first"
        root.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        XCTAssertEqual(root.state.matching.map(\.id), ["first"])
        XCTAssertEqual(root.state.selectedID, "second")
        XCTAssertTrue(root.state.visible.isEmpty)
    }

    func testPreviewControlButtonsAreDisabledAndMinimumWidthHasThreeRegions() {
        _ = NSApplication.shared
        let root = WorkbenchRootView(frame: NSRect(x: 0, y: 0, width: 1080, height: 850), preview: true)
        root.loadPreview([
            WorkbenchDevice(
                id: "a", name: "a", connected: true, backend: .ble, status: "sample",
                shortcuts: Set(ControlShortcut.allCases))
        ])
        renderLayout(root)
        let controls = descendants(root).compactMap { $0 as? NSButton }
        XCTAssertTrue(controls.filter { $0.title == ControlShortcut.home.title }.allSatisfy { !$0.isEnabled })
        XCTAssertTrue(controls.filter { $0.title == StringsWorkbench.current.send }.allSatisfy { !$0.isEnabled })
        XCTAssertEqual(root.subviews.filter { $0 is WorkbenchSurface }.count, 2)
        XCTAssertEqual(root.subviews.filter { $0 is NSScrollView }.count, 1)
        XCTAssertTrue(root.subviews.allSatisfy { $0.frame.maxX <= root.bounds.maxX + 1 })
    }
    func testMinimumHeightInspectorScrollsToAllControlsAndShortcutsHaveRoom() {
        _ = NSApplication.shared
        let root = WorkbenchRootView(frame: NSRect(x: 0, y: 0, width: 1080, height: 700), preview: true)
        root.loadPreview([])
        renderLayout(root)
        let inspectorScroll = root.subviews.compactMap { $0 as? NSScrollView }.first!
        let inspector = inspectorScroll.documentView!
        XCTAssertGreaterThan(inspector.bounds.height, inspectorScroll.contentSize.height)
        XCTAssertTrue(inspector.subviews.allSatisfy { $0.frame.minY >= 0 && $0.frame.maxY <= inspector.bounds.height })
        let home = descendants(inspector).compactMap { $0 as? WorkbenchActionButton }.first {
            $0.appearanceStyle == .shortcut && $0.symbolName == ControlShortcut.home.symbol
        }!
        XCTAssertEqual(home.bezelStyle, .regularSquare)
        XCTAssertGreaterThanOrEqual(home.frame.height, 60)
        XCTAssertTrue(inspectorScroll.hasVerticalScroller)
    }

    func testRepeatedSnapshotsKeepNativeCardsAndPerDeviceTextDrafts() {
        _ = NSApplication.shared
        let root = WorkbenchRootView(frame: NSRect(x: 0, y: 0, width: 1440, height: 850), preview: true)
        let devices = [
            WorkbenchDevice(id: "a", name: "same", connected: true, backend: .ble, status: "sample"),
            WorkbenchDevice(id: "b", name: "same", connected: true, backend: .usb, status: "sample"),
        ]
        root.loadPreview(devices)
        let images = descendants(root).compactMap { $0 as? NSImageView }.map(ObjectIdentifier.init)
        let text = descendants(root).compactMap { $0 as? NSTextField }.first {
            $0.isEditable && !($0 is NSSearchField)
        }!
        text.stringValue = "draft for a"
        root.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: text))
        root.select("b")
        XCTAssertEqual(text.stringValue, "")
        text.stringValue = "draft for b"
        root.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: text))
        root.select("a")
        XCTAssertEqual(text.stringValue, "draft for a")
        root.loadPreview(devices)
        XCTAssertEqual(descendants(root).compactMap { $0 as? NSImageView }.map(ObjectIdentifier.init), images)
        XCTAssertEqual(text.stringValue, "draft for a")
        root.select("b")
        XCTAssertEqual(text.stringValue, "draft for b")
    }

    func testCardClosesOnlyItsIndependentWindowAndReturnsToExpand() throws {
        _ = NSApplication.shared
        let root = WorkbenchRootView(frame: NSRect(x: 0, y: 0, width: 1440, height: 850), preview: true)
        let a = WorkbenchDevice(id: "phone-a", name: "iPhone", connected: true, backend: .usb, status: "ready")
        let b = WorkbenchDevice(id: "phone-ab", name: "iPhone", connected: true, backend: .usb, status: "ready")
        let devices = [a, b]
        var openIDs: Set<String> = [a.id, b.id]
        var closed: [String] = []
        root.loadPreview(devices, independentIDs: openIDs)
        root.select(b.id)
        root.onCloseIndependent = { [weak root] id in
            closed.append(id)
            openIDs.remove(id)
            root?.loadPreview(devices, independentIDs: openIDs)
        }
        func action(_ id: String) -> WorkbenchActionButton? {
            descendants(root).compactMap { $0 as? WorkbenchActionButton }.first { $0.accessibilityIdentifier() == id }
        }
        let closeA = try XCTUnwrap(action("card-close-window:\(a.id)"))
        XCTAssertEqual(closeA.symbolName, "xmark")
        XCTAssertEqual(closeA.accessibilityLabel(), StringsWorkbench.current.closeIndependent)
        closeA.performClick(nil)
        XCTAssertEqual(closed, [a.id])
        XCTAssertEqual(openIDs, [b.id])
        XCTAssertNotNil(action("card-close-window:\(b.id)"))
        XCTAssertEqual(root.state.selectedID, b.id)
        let expandA = try XCTUnwrap(action("card-expand:\(a.id)"))
        var reopened: [String] = []
        root.onIndependent = { reopened.append($0) }
        expandA.performClick(nil)
        XCTAssertEqual(reopened, [a.id])
    }

    func testRemoveOfflineCardClosesOnlyItsWindowPreservesOtherDraftAndAllowsRediscovery() throws {
        _ = NSApplication.shared
        let root = WorkbenchRootView(frame: NSRect(x: 0, y: 0, width: 1440, height: 850), preview: true)
        let a = WorkbenchDevice(id: "phone-a", name: "iPhone", connected: true, backend: .usb, status: "ready")
        let b = WorkbenchDevice(id: "phone-ab", name: "iPhone", connected: true, backend: .usb, status: "ready")
        root.loadPreview([a, b], independentIDs: [a.id, b.id])
        root.select(b.id)
        let draft = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextField }.first {
            $0.isEditable && !($0 is NSSearchField)
        })
        draft.stringValue = "draft for remaining phone"
        root.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: draft))
        root.select(a.id)
        root.loadPreview([b], independentIDs: [a.id, b.id])
        var closed: [String] = []
        root.onCloseIndependent = { closed.append($0) }
        let remove = try XCTUnwrap(descendants(root).compactMap { $0 as? WorkbenchActionButton }.first {
            $0.accessibilityIdentifier() == "card-remove:\(a.id)"
        })
        XCTAssertEqual(remove.symbolName, "trash")
        XCTAssertEqual(remove.accessibilityLabel(), StringsWorkbench.current.removeDeviceCard)
        remove.performClick(nil)
        XCTAssertNil(remove.superview?.superview, "the removed card is no longer mounted")
        XCTAssertEqual(closed, [a.id])
        XCTAssertEqual(root.state.devices.map(\.id), [b.id])
        XCTAssertEqual(root.state.selectedID, b.id)
        XCTAssertEqual(draft.stringValue, "draft for remaining phone")
        root.loadPreview([b], independentIDs: [b.id])
        XCTAssertEqual(root.state.devices.map(\.id), [b.id])
        root.loadPreview([a, b], independentIDs: [b.id])
        XCTAssertEqual(Set(root.state.devices.map(\.id)), [a.id, b.id])
        XCTAssertEqual(root.state.selectedID, b.id)
        XCTAssertFalse(descendants(root).contains { $0.accessibilityIdentifier() == "card-remove:\(a.id)" })
    }

    func testNativeEditMenuStandardSelectAllActionEditsOnlyLocalField() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let phone = PhoneControlView(deviceID: "offline-edit-menu", frame: .zero)
        let field = NSTextField(frame: NSRect(x: 5, y: 5, width: 200, height: 24))
        field.stringValue = "314159"
        window.contentView!.addSubview(phone)
        window.contentView!.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        XCTAssertFalse(phone.acceptsLocalKeyEquivalents)
        let menu = AppEditMenu.make(language: .en)
        let selectAll = try XCTUnwrap(menu.items.last)
        XCTAssertNil(selectAll.target)
        XCTAssertEqual(selectAll.action, #selector(NSText.selectAll(_:)))
        // XCTest may have no key window. Supply the resolved local editor only
        // in this fixture; the installed application menu keeps its nil target.
        XCTAssertTrue(editor.tryToPerform(try XCTUnwrap(selectAll.action), with: selectAll))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 6))
        XCTAssertEqual(field.stringValue, "314159")
        XCTAssertFalse(phone.isRendering)
        XCTAssertTrue(menu.items.allSatisfy { $0.target == nil })
    }

    func testNativeEditMenuRelocalizesInPlaceWithStandardShortcuts() {
        let menu = AppEditMenu.make(language: .en)
        let identities = menu.items.map(ObjectIdentifier.init)
        let commands = menu.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(commands.map(\.keyEquivalent), ["z", "z", "x", "c", "v", "a"])
        XCTAssertEqual(commands.map { NSStringFromSelector($0.action!) },
                       ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"])
        XCTAssertEqual(commands[1].keyEquivalentModifierMask, [.command, .shift])
        XCTAssertTrue(commands.enumerated().filter { $0.offset != 1 }.allSatisfy {
            $0.element.keyEquivalentModifierMask == [.command]
        })
        AppEditMenu.localize(menu, language: .zh)
        XCTAssertEqual(menu.title, "编辑")
        XCTAssertEqual(menu.items.last?.title, "全选")
        XCTAssertEqual(menu.items.map(ObjectIdentifier.init), identities)
        AppEditMenu.localize(menu, language: .en)
        XCTAssertEqual(menu.title, "Edit")
        XCTAssertEqual(menu.items.last?.title, "Select All")
        XCTAssertEqual(menu.items.map(ObjectIdentifier.init), identities)
    }

    func testNativeEditMenuLeavesFocusedPhoneEditingLocalityIntact() throws {
        final class KeyFixtureWindow: NSWindow {
            override var isKeyWindow: Bool { true }
        }
        _ = NSApplication.shared
        let window = KeyFixtureWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let phone = PhoneControlView(deviceID: "offline-edit-shortcuts", frame: .zero)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView!.addSubview(phone)
        window.contentView!.addSubview(field)
        for key in ["a", "c", "x", "v", "z"] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: 0))
            window.makeFirstResponder(phone)
            // Unbound input is consumed without sending; no hardware session starts.
            XCTAssertTrue(phone.performKeyEquivalent(with: event))
            window.makeFirstResponder(field)
            XCTAssertFalse(phone.acceptsLocalKeyEquivalents)
            XCTAssertFalse(phone.performKeyEquivalent(with: event))
        }
        XCTAssertFalse(phone.isRendering)
    }

    func testPhoneDoesNotStealPasteFromAnotherNativeTextField() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 500), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let phone = PhoneControlView(deviceID: "unbound", frame: .zero)
        let field = NSTextField(frame: .zero)
        window.contentView!.addSubview(phone)
        window.contentView!.addSubview(field)
        window.makeFirstResponder(phone)
        XCTAssertTrue(phone.acceptsLocalKeyEquivalents)
        phone.isKeyboardTarget = false
        XCTAssertFalse(phone.acceptsLocalKeyEquivalents)
        phone.isKeyboardTarget = true
        window.makeFirstResponder(field)
        XCTAssertFalse(phone.acceptsLocalKeyEquivalents)
        XCTAssertFalse(phone.isRendering)
    }

    func testEmbeddedControllerCreatesNoWindowOrRenderingLoop() {
        _ = NSApplication.shared
        let controller = ControlWindowController(deviceID: "offline-only", name: "offline", embedded: true)
        XCTAssertNil(controller.window)
        XCTAssertFalse(controller.controlView.isRendering)
        // Legacy default is preserved; the workbench root gates embedded targets.
        XCTAssertTrue(controller.controlView.isPointerTarget)
        XCTAssertTrue(controller.availableShortcuts.isEmpty)
        XCTAssertTrue(descendants(controller.embeddedView).contains { $0 === controller.controlView })
        XCTAssertFalse(descendants(controller.embeddedView).contains { $0 is ControlSidebar })
        controller.embeddedView.frame = NSRect(x: 0, y: 0, width: 326, height: 600)
        controller.embeddedView.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.controlView.frame.width, 326, accuracy: 1)
    }

    func testApprovedDesignGeometryAndCustomNativeButtonStyles() {
        _ = NSApplication.shared
        let root = WorkbenchRootView(frame: NSRect(x: 0, y: 0, width: 1680, height: 980), preview: true)
        root.loadPreview([])
        renderLayout(root)
        let sidebar = root.subviews.compactMap { $0 as? WorkbenchSurface }.first { $0.frame.minX == 0 }!
        XCTAssertEqual(sidebar.frame.width, 232)
        let inspectorScroll = root.subviews.compactMap { $0 as? NSScrollView }.first!
        XCTAssertEqual(inspectorScroll.frame.width, 312)
        XCTAssertEqual(inspectorScroll.frame.minY, 64)
        let buttons = descendants(root).compactMap { $0 as? WorkbenchActionButton }
        XCTAssertEqual(buttons.filter { $0.appearanceStyle == .navigation }.count, 3)
        XCTAssertEqual(buttons.filter { $0.appearanceStyle == .shortcut }.count, 6)
        XCTAssertEqual(buttons.filter { $0.appearanceStyle == .solid }.count, 1)
        XCTAssertFalse(buttons.contains { $0.appearanceStyle == .system })
        let segments = descendants(root).compactMap { $0 as? WorkbenchSegmentedControl }
        XCTAssertEqual(segments.count, 3)
        XCTAssertTrue(segments.contains { $0.accessibilityIdentifier() == "workbench-language" })
        XCTAssertTrue(segments.allSatisfy { $0.segmentDistribution == .fillEqually })
    }

    func testLocalizedPrimaryAndCardActionsHaveTheirFullTextWidth() {
        _ = NSApplication.shared
        for language in AppLanguage.allCases {
            let table = StringsWorkbench(language: language)
            let root = WorkbenchRootView(frame: NSRect(x: 0, y: 0, width: 1080, height: 700), preview: true)
            root.loadPreview([WorkbenchDevice(id: "a", name: "Phone", connected: true, backend: .ble, status: "sample")]
            )
            let actions = descendants(root).compactMap { $0 as? WorkbenchActionButton }.filter {
                ["plus", "arrow.right", "camera", "arrow.up.forward.square"].contains($0.symbolName ?? "")
            }
            // Inject both label tables without changing the app's persisted language.
            for button in actions {
                switch button.symbolName {
                case "plus": button.title = table.connect
                case "arrow.right": button.title = table.send
                case "camera": button.title = table.screenshot
                default: button.title = language == .zh ? "聚焦设备" : "Focus device"
                }
            }
            renderLayout(root)
            XCTAssertEqual(actions.count, 4)
            for button in actions {
                XCTAssertGreaterThanOrEqual(
                    button.bounds.width, button.requiredContentWidth,
                    "\(language): \(button.title)")
                XCTAssertLessThanOrEqual(button.frame.maxX, button.superview!.bounds.width)
            }
        }
    }

    func testInputMethodShortcutFitsInspectorAndStaysMomentaryAndPreviewOnly() {
        _ = NSApplication.shared
        for size in [NSSize(width: 1680, height: 980), NSSize(width: 1080, height: 700)] {
            let root = WorkbenchRootView(frame: NSRect(origin: .zero, size: size), preview: true)
            root.loadPreview([WorkbenchDevice(id: "selected", name: "Phone", connected: true, backend: .usb,
                status: "sample", shortcuts: Set(ControlShortcut.allCases))])
            renderLayout(root)
            let buttons = descendants(root).compactMap { $0 as? WorkbenchActionButton }
            let button = buttons.first {
                $0.accessibilityIdentifier() == "workbench-shortcut:\(ControlShortcut.inputMethod.rawValue)"
            }!
            XCTAssertEqual(button.title, ControlShortcut.inputMethod.title)
            XCTAssertEqual(button.toolTip, ControlShortcut.inputMethod.help)
            XCTAssertNotNil(button.invoke)
            XCTAssertFalse(button.isEnabled, "offline preview must never send input")
            XCTAssertFalse(button.retainsSelection)
            XCTAssertGreaterThanOrEqual(button.bounds.width, button.requiredContentWidth)
            XCTAssertEqual(button.frame.width, 268)
            let grid = buttons.filter { $0.appearanceStyle == .shortcut }
            XCTAssertEqual(grid.count, 6)
            XCTAssertTrue(grid.allSatisfy { $0.frame.maxY < button.frame.minY })
            let text = descendants(root).compactMap { $0 as? NSTextField }.first {
                $0.accessibilityLabel() == StringsWorkbench.current.textInput
            }!
            XCTAssertGreaterThan(text.frame.minY, button.frame.maxY)
            XCTAssertLessThanOrEqual(button.frame.maxY, button.superview!.bounds.height)
        }
    }

    func testCommandButtonsOnlyHighlightDuringPressAndKeepNoLatchedState() {
        _ = NSApplication.shared
        for style in [WorkbenchActionButton.Appearance.navigation, .shortcut, .outline, .link, .solid, .plain] {
            let button = WorkbenchActionButton()
            button.appearanceStyle = style
            var calls = 0
            button.invoke = { calls += 1 }
            button.highlight(true)
            XCTAssertTrue(button.isHighlighted)
            button.highlight(false)
            XCTAssertFalse(button.isHighlighted)
            button.state = .on
            button.performClick(nil)
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(button.state, .off)
            XCTAssertFalse(button.showsSelection)
            XCTAssertFalse(button.isHighlighted)
        }
        let root = WorkbenchRootView(frame: NSRect(x: 0, y: 0, width: 1440, height: 850), preview: true)
        root.loadPreview([WorkbenchDevice(id: "a", name: "Phone", connected: true, backend: .ble, status: "ready")])
        let buttons = descendants(root).compactMap { $0 as? WorkbenchActionButton }
        XCTAssertTrue(buttons.filter { $0.appearanceStyle == .shortcut }.allSatisfy { !$0.showsSelection })
        let workspace = buttons.first { $0.title == StringsWorkbench.current.title }!
        XCTAssertTrue(workspace.retainsSelection)
        XCTAssertTrue(workspace.showsSelection)
        XCTAssertTrue(buttons.contains { $0.retainsSelection && $0.toolTip?.hasPrefix("a\n") == true })
    }

    func testExactProductTypeSelectsSEAnd12FramesWithoutNicknameOrResolutionGuessing() {
        XCTAssertEqual(WorkbenchPhoneModel.resolve(productType: "iPhone12,8"), .classicHome)
        XCTAssertEqual(WorkbenchPhoneModel.resolve(productType: "iPhone14,6"), .classicHome)
        XCTAssertEqual(WorkbenchPhoneModel.resolve(productType: "iPhone13,2"), .flatNotch)
        XCTAssertEqual(WorkbenchPhoneModel.resolve(productType: "iPhone15,2"), .dynamicIsland)
        XCTAssertEqual(WorkbenchPhoneModel.resolve(productType: "iPhone SE"), .neutral)
        XCTAssertEqual(WorkbenchPhoneModel.resolve(productType: "unknown"), .neutral)
        XCTAssertEqual(WorkbenchPhoneModel.resolve(productType: nil), .neutral)
        for model in WorkbenchPhoneModel.allCases {
            for size in [CGSize(width: 750, height: 1334), CGSize(width: 2532, height: 1170)] {
                let layout = WorkbenchPhoneGeometry(
                    screenSize: size,
                    bounds: NSRect(x: 0, y: 0, width: 400, height: 500), model: model)
                XCTAssertEqual(layout.screen.width / layout.screen.height, size.width / size.height, accuracy: 0.0001)
                XCTAssertTrue(layout.body.contains(layout.screen))
                if model == .classicHome {
                    XCTAssertLessThan(layout.screenCornerRadius, 3)
                    let end =
                        layout.landscape ? layout.screen.minX - layout.body.minX : layout.screen.minY - layout.body.minY
                    XCTAssertGreaterThan(end, 20)
                }
            }
        }
    }

    func testPhoneShellFitsRealCaptureWithoutBlackLetterboxAndRetainsNativeContent() {
        _ = NSApplication.shared
        for size in [
            CGSize(width: 750, height: 1334), CGSize(width: 1170, height: 2532),
            CGSize(width: 2532, height: 1170),
        ] {
            let phone = PhoneControlView(deviceID: "offline-only", frame: .zero)
            let shell = WorkbenchPhoneShell(content: phone)
            shell.frame = NSRect(x: 0, y: 0, width: 420, height: 350)
            shell.screenSize = size
            shell.layoutSubtreeIfNeeded()
            let geometry = shell.geometry
            XCTAssertEqual(phone.frame, geometry.screen)
            XCTAssertEqual(phone.frame.width / phone.frame.height, size.width / size.height, accuracy: 0.0001)
            XCTAssertTrue(shell.bounds.contains(geometry.body))
            XCTAssertGreaterThan(geometry.body.width, phone.frame.width)
            XCTAssertLessThan(geometry.body.width - phone.frame.width, phone.frame.width * 0.1)
            XCTAssertTrue(shell.content === phone)
            XCTAssertTrue(phone.layer?.masksToBounds == true)
            XCTAssertFalse(phone.isRendering)
        }
    }

    func testCustomSegmentedControlPreservesNativeSelectionAndAction() {
        let control = WorkbenchSegmentedControl(
            labels: ["Grid", "Focus"], trackingMode: .selectOne, target: nil, action: nil)
        control.selectedSegment = 0
        XCTAssertEqual(control.label(forSegment: 0), "Grid")
        control.selectedSegment = 1
        XCTAssertEqual(control.selectedSegment, 1)
        control.isEnabled = false
        XCTAssertFalse(control.isEnabled)
    }

}
