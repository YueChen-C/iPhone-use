import Foundation
import XCTest

@testable import iPhoneUse

final class LocalizationTests: XCTestCase {
    private var previousLanguage: AppLanguage = .en

    override func setUp() {
        super.setUp()
        previousLanguage = AppLanguageStore.shared.language
    }

    override func tearDown() {
        AppLanguageStore.shared.set(previousLanguage)
        super.tearDown()
    }

    // MARK: AppLanguage resolution and persistence

    func testSystemLanguageResolution() {
        XCTAssertEqual(AppLanguage.resolvingSystemLanguage(["zh-Hans-CN"]), .zh)
        XCTAssertEqual(AppLanguage.resolvingSystemLanguage(["zh-TW", "en-US"]), .zh)
        XCTAssertEqual(AppLanguage.resolvingSystemLanguage(["en-US"]), .en)
        XCTAssertEqual(AppLanguage.resolvingSystemLanguage(["ja-JP", "zh-CN"]), .en)
        XCTAssertEqual(AppLanguage.resolvingSystemLanguage([]), .en)
    }

    func testStoreFallsBackToSystemDefaultAndPersistsChoice() throws {
        let suite = "localization-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Unset and invalid raw values both fall back to the system default.
        XCTAssertEqual(AppLanguageStore(defaults: defaults).language, AppLanguage.systemDefault)
        defaults.set("bogus", forKey: AppLanguageStore.defaultsKey)
        XCTAssertEqual(AppLanguageStore(defaults: defaults).language, AppLanguage.systemDefault)

        // A persisted choice survives a new store instance.
        let store = AppLanguageStore(defaults: defaults)
        store.set(.en)
        XCTAssertEqual(store.language, .en)
        XCTAssertEqual(defaults.string(forKey: AppLanguageStore.defaultsKey), "en")
        XCTAssertEqual(AppLanguageStore(defaults: defaults).language, .en)
    }

    func testStorePersistsExplicitSystemDefaultWithoutNotifying() throws {
        let suite = "localization-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var fires = 0
        let observer = NotificationCenter.default.addObserver(
            forName: AppLanguageStore.didChangeNotification, object: nil, queue: nil
        ) { _ in fires += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        for savedValue in [nil, "bogus"] as [String?] {
            defaults.set(savedValue, forKey: AppLanguageStore.defaultsKey)
            let store = AppLanguageStore(defaults: defaults)
            let language = AppLanguage.systemDefault
            XCTAssertEqual(store.language, language)

            store.set(language)

            XCTAssertEqual(defaults.string(forKey: AppLanguageStore.defaultsKey), language.rawValue)
            XCTAssertEqual(AppLanguageStore(defaults: defaults).language, language)
            XCTAssertEqual(fires, 0)
        }
    }

    func testStoreNotifiesOnlyOnChange() throws {
        let suite = "localization-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppLanguageStore(defaults: defaults)
        store.set(.zh)

        var fires = 0
        let observer = NotificationCenter.default.addObserver(
            forName: AppLanguageStore.didChangeNotification, object: nil, queue: nil
        ) { _ in fires += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.set(.zh)
        XCTAssertEqual(fires, 0)
        store.set(.en)
        XCTAssertEqual(fires, 1)
    }

    // MARK: /config and /viewer

    func testConfigEndpointReturnsCurrentLanguage() throws {
        AppLanguageStore.shared.set(.zh)
        let request = try XCTUnwrap(HTTPRequest.parse(Data("GET /config HTTP/1.1\r\n\r\n".utf8)))
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ControlAPI.handle(request).body) as? [String: Any])
        XCTAssertEqual(body["language"] as? String, "zh")
    }

    func testViewerFollowsAppLanguageAndQueryOverride() throws {
        let zh = WebPreview.html(for: .zh)
        XCTAssertTrue(zh.contains("lang=\"zh-CN\""))
        XCTAssertTrue(zh.contains("实时画面"))
        let en = WebPreview.html(for: .en)
        XCTAssertTrue(en.contains("lang=\"en\""))
        XCTAssertTrue(en.contains("Live Screen"))

        // ?lang=zh|en pins the page; anything else falls back to the app language.
        AppLanguageStore.shared.set(.zh)
        let pinned = try XCTUnwrap(HTTPRequest.parse(Data("GET /viewer?lang=en HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertTrue(
            String(decoding: ControlAPI.handle(pinned).body, as: UTF8.self).contains("Live Screen"))
        let junk = try XCTUnwrap(
            HTTPRequest.parse(Data("GET /viewer?lang=junk HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertTrue(
            String(decoding: ControlAPI.handle(junk).body, as: UTF8.self).contains("实时画面"))
    }

    // MARK: App-side error localization

    func testAPIErrorsFollowTheAppLanguage() throws {
        AppLanguageStore.shared.set(.zh)
        XCTAssertEqual(StringsAPI.current.textRequired, StringsAPI.zh.textRequired)
        XCTAssertThrowsError(
            try RequestCoordinates.point(["x": 1], "x", "y", screenSize: nil, screenName: "phone")
        ) { error in
            XCTAssertEqual(String(describing: error), StringsAPI.zh.coordinatesRequired("x", "y"))
        }
        let zhCaptureError = StringsAPI.zh.captureFailedFromDevice("iPhone", "cannot open (-11800)")
        let enCaptureError = StringsAPI.en.captureFailedFromDevice("iPhone", "cannot open (-11800)")
        XCTAssertTrue(zhCaptureError.contains("iPhone") && zhCaptureError.contains("-11800"))
        XCTAssertTrue(enCaptureError.contains("iPhone") && enCaptureError.contains("-11800"))
    }

    // MARK: MCP catalog

    func testMCPCatalogLocalizesDescriptionsButKeepsNamesAndSchemas() throws {
        let enTools = MCPToolCatalog.tools(for: .en)
        let zhTools = MCPToolCatalog.tools(for: .zh)
        let required: Set<String> = [
            "list_devices", "screenshot", "move_pointer", "adjust_pointer", "click_pointer",
            "tap", "long_press", "swipe", "type_text", "press_key", "keyboard_sequence", "home",
        ]
        func names(_ tools: [[String: Any]]) -> Set<String> {
            Set(tools.compactMap { $0["name"] as? String })
        }
        XCTAssertEqual(names(enTools), required)
        XCTAssertEqual(names(zhTools), required)

        for (enTool, zhTool) in zip(enTools, zhTools) {
            XCTAssertEqual(enTool["name"] as? String, zhTool["name"] as? String)
            XCTAssertNotEqual(enTool["description"] as? String, zhTool["description"] as? String)
            let enSchema = try XCTUnwrap(enTool["inputSchema"] as? [String: Any])
            let zhSchema = try XCTUnwrap(zhTool["inputSchema"] as? [String: Any])
            let enProperties = try XCTUnwrap(enSchema["properties"] as? [String: Any])
            let zhProperties = try XCTUnwrap(zhSchema["properties"] as? [String: Any])
            XCTAssertEqual(Set(enProperties.keys), Set(zhProperties.keys))
            XCTAssertEqual(enSchema["required"] as? [String], zhSchema["required"] as? [String])
        }

        // Numeric constraints are part of the contract and never localize.
        let adjust = try XCTUnwrap(zhTools.first { $0["name"] as? String == "adjust_pointer" })
        let dx = try XCTUnwrap(
            ((adjust["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["dx"]
                as? [String: Any])
        XCTAssertEqual(dx["minimum"] as? Int, -32)
        XCTAssertEqual(dx["maximum"] as? Int, 32)
    }

    func testMCPServerServesToolsInTheConfiguredLanguage() throws {
        let previous = MCPServer.language
        defer { MCPServer.language = previous }

        func homeDescription(for language: AppLanguage) throws -> String {
            MCPServer.language = language
            let reply = try XCTUnwrap(
                MCPServer.response(to: ["id": 1, "method": "tools/list"]) { _, _ in [:] })
            let tools = try XCTUnwrap((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
            let home = try XCTUnwrap(tools.first { $0["name"] as? String == "home" })
            return try XCTUnwrap(home["description"] as? String)
        }

        XCTAssertEqual(try homeDescription(for: .zh), "回到主屏幕。")
        XCTAssertEqual(try homeDescription(for: .en), "Go to the Home Screen.")
    }

    func testMCPValidationErrorsLocalize() {
        XCTAssertThrowsError(
            try MCPToolRequest.action(
                named: "move_pointer", arguments: ["x": -1, "y": 2], longEdge: 1200, language: .zh)
        ) { error in
            XCTAssertEqual(String(describing: error), StringsMCP(language: .zh).coordinateFinite("x"))
        }
        XCTAssertThrowsError(
            try MCPKeyboardSequence.actions(arguments: ["steps": []], language: .zh)
        ) { error in
            XCTAssertEqual(
                String(describing: error), StringsMCP(language: .zh).keyboardSequenceRange)
        }
        // Default-parameter callers keep the stable English contract.
        XCTAssertThrowsError(
            try MCPToolRequest.action(named: "move_pointer", arguments: ["x": -1, "y": 2], longEdge: 1200)
        ) { error in
            XCTAssertEqual(String(describing: error), "x must be a finite, nonnegative screenshot coordinate")
        }
    }
}
