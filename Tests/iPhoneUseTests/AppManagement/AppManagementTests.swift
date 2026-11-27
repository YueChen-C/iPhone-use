import Foundation
import XCTest

@testable import iPhoneUse

final class AppManagementTests: XCTestCase {
    private let first = "00000000-0000000000000001"
    private let second = "00000000-0000000000000002"

    func testInventoryUsesReadOnlyMultiPartBrowse() throws {
        let stream = try PlistStream([
            [
                "Status": "BrowsingApplications",
                "CurrentList": [["CFBundleIdentifier": "com.example.second", "CFBundleName": "Second"]],
            ],
            [
                "Status": "BrowsingApplications",
                "CurrentList": [
                    [
                        "CFBundleIdentifier": "com.example.first", "CFBundleDisplayName": "First",
                        "ApplicationType": "User",
                    ]
                ],
            ],
            ["Status": "Complete"],
        ])
        XCTAssertEqual(
            try NativeAppInventory.browse(stream),
            [
                ["bundle_id": "com.example.first", "name": "First", "application_type": "User"],
                ["bundle_id": "com.example.second", "name": "Second"],
            ])
        let request =
            try PropertyListSerialization.propertyList(from: stream.sent.dropFirst(4), options: [], format: nil)
            as? [String: Any]
        XCTAssertEqual(request?["Command"] as? String, "Browse")
    }

    func testDesktopInventoryRequestsVisibilityAndMainPathWithoutChangingPublicBrowse() throws {
        let entries = [
            ["CFBundleIdentifier": "com.example.app", "CFBundleDisplayName": "Example", "ApplicationType": "User",
             "Path": "/var/containers/A/Example App.app", "CFBundleExecutable": "Example"],
            ["CFBundleIdentifier": "com.example.invalid", "ApplicationType": "User", "Path": "/Applications/Bad.app",
             "CFBundleExecutable": "PlugIns/Other"],
        ]
        let stream = try PlistStream([["Status": "Complete", "CurrentList": entries]])
        let apps = try NativeAppInventory.manageableApps(stream)
        XCTAssertEqual(apps.map(\.executablePath), [executable, nil])
        func attributesRequested(by stream: PlistStream) throws -> Set<String> {
            let request = try XCTUnwrap(PropertyListSerialization.propertyList(from: stream.sent.dropFirst(4),
                options: [], format: nil) as? [String: Any])
            let options = try XCTUnwrap(request["ClientOptions"] as? [String: [String]])
            return Set(try XCTUnwrap(options["ReturnAttributes"]))
        }
        let publicStream = try PlistStream([["Status": "Complete", "CurrentList": entries]])
        XCTAssertEqual(try NativeAppInventory.browse(publicStream), apps.map(\.attributes))
        XCTAssertEqual(try attributesRequested(by: publicStream), [
            "CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "CFBundleShortVersionString", "ApplicationType",
        ])
        XCTAssertEqual(try attributesRequested(by: stream).subtracting(attributesRequested(by: publicStream)), [
            "Path", "CFBundleExecutable", "SBAppTags", "SBAppTags~iphone", "SBIconVisibilityDefaultVisible", "IsAppClip",
        ])
    }

    func testDesktopInventoryKeepsThirdPartyAndVisibleSystemAppsButNotHiddenComponents() throws {
        func entry(_ id: String, _ type: String = "System", _ metadata: [String: Any] = [:]) -> [String: Any] {
            ["CFBundleIdentifier": id, "ApplicationType": type].merging(metadata) { _, new in new }
        }
        let entries = [
            entry("com.apple.Passbook", "System", ["CFBundleDisplayName": "Wallet"]),
            entry("com.apple.PassbookUISceneService", "System", ["CFBundleDisplayName": "Wallet", "SBAppTags": ["hidden"]]),
            entry("com.apple.CredentialSharingService", "System", ["SBAppTags": ["hidden"]]),
            entry("com.apple.siri", "System", ["SBAppTags": ["SBInternalAppTag"]]),
            entry("com.apple.ScreenTimeWidgetApplication", "System", ["SBAppTags~iphone": ["hidden"]]),
            entry("com.apple.PreviewShell", "System", ["SBIconVisibilityDefaultVisible": false]),
            entry("com.apple.springboard", "Hidden"),
            entry("com.apple.Passwords", "System", ["CFBundlePackageType": "XPC!"]),
            entry("com.apple.mobilephone", "System", ["SBAppTags": ["any-telephony"]]),
            entry("com.apple.FTMInternal"),
            entry("com.apple.webapp"),
            entry("org.example.app", "User"),
            entry("org.example.app.Clip", "User", ["IsAppClip": true]),
            ["CFBundleIdentifier": "org.example.unclassified"],
        ]
        let replies: [[String: Any]] = [["Status": "Complete", "CurrentList": entries]]
        let desktop = try NativeAppInventory.manageableApps(PlistStream(replies)).compactMap { $0.attributes["bundle_id"] }
        XCTAssertEqual(desktop, ["com.apple.Passbook", "com.apple.Passwords", "com.apple.mobilephone", "org.example.app"])
        let publicList = try NativeAppInventory.browse(PlistStream(replies)).compactMap { $0["bundle_id"] }
        XCTAssertEqual(publicList, entries.compactMap { $0["CFBundleIdentifier"] as? String }.sorted())
    }

    func testDesktopProcessSnapshotMatchesOnlyExactMainExecutableAndPreservesUnknown() throws {
        var queries = 0
        let paths = try NativeAppServices.processPaths { request in
            queries += 1
            XCTAssertEqual(try decode(request)["CoreDevice.featureIdentifier"] as? String, NativeAppServices.processListFeature)
            return processes(process(21, "file:///var/containers/A/Example%20App.app/Example"),
                             process(22, "file:///private/var/containers/App/App.app/Extensions/Other"), process(23, nil))
        }
        XCTAssertEqual(queries, 1)
        let partial = NativeAppServices.ProcessSnapshot(paths: paths.paths, complete: paths.complete)
        XCTAssertEqual(partial.state(for: executable), .running)
        XCTAssertEqual(partial.state(for: nil), .unknown)
        let appPath = "/private/var/containers/App/App.app/App"
        XCTAssertEqual(partial.state(for: appPath), .unknown)
        let complete = try NativeAppServices.processPaths { _ in
            processes(process(23, "file:///private/var/containers/App/App.app/Extensions/Other"))
        }
        XCTAssertTrue(complete.complete)
        let snapshot = NativeAppServices.ProcessSnapshot(paths: complete.paths, complete: complete.complete)
        XCTAssertEqual(snapshot.state(for: appPath), .stopped)
        XCTAssertEqual(snapshot.state(for: nil), .unknown)
        XCTAssertThrowsError(try NativeAppServices.processPaths { _ in ["CoreDevice.error": "Unavailable"] })
    }

    func testInventoryNeverReturnsPartialDataOnServiceFailure() throws {
        let stream = try PlistStream([
            ["Status": "BrowsingApplications", "CurrentList": [["CFBundleIdentifier": "com.example.app"]]],
            ["Error": "PermissionDenied"],
        ])
        XCTAssertThrowsError(try NativeAppInventory.browse(stream))
    }

    func testBundleValidationAndLaunchWireUsesNonRestartingOptions() throws {
        for invalid in ["", "com..example", "com.example/other", "com.example\n", "-option value", "中文", "a\0b"] {
            XCTAssertFalse(NativeAppServices.validBundleID(invalid))
            XCTAssertThrowsError(try NativeAppServices.launchRequest(bundleID: invalid))
        }
        let request = try NativeAppServices.launchRequest(bundleID: "com.example.my-app")
        var decoder = AXRSDDecoder(data: USBXPCValue.dictionary(request).encode())
        let root = try XCTUnwrap(try decoder.object() as? [String: Any])
        XCTAssertEqual(root["CoreDevice.featureIdentifier"] as? String, NativeAppServices.launchFeature)
        let input = try XCTUnwrap(root["CoreDevice.input"] as? [String: Any])
        let args = try XCTUnwrap(input["options"] as? [String: Any])
        XCTAssertEqual(args["terminateExisting"] as? Bool, false)
        XCTAssertEqual(args["startStopped"] as? Bool, false)
        XCTAssertNil(args["payloadURL"])
    }

    func testLaunchURLPreservesPathEscapesQueryAndFragmentInCoreDeviceOptions() throws {
        let url = "HTTPS://Example.com:8443/with%2fescape?x=a%2Bb&x=b#top"
        let request = try NativeAppServices.launchRequest(bundleID: "com.example.app", payloadURL: url)
        var decoder = AXRSDDecoder(data: USBXPCValue.dictionary(request).encode())
        let root = try XCTUnwrap(try decoder.object() as? [String: Any])
        let input = try XCTUnwrap(root["CoreDevice.input"] as? [String: Any])
        let options = try XCTUnwrap(input["options"] as? [String: Any])
        XCTAssertEqual(root["CoreDevice.featureIdentifier"] as? String, NativeAppServices.launchFeature)
        XCTAssertEqual(options["payloadURL"] as? [String: String], ["relative": url])
        XCTAssertEqual(options["terminateExisting"] as? Bool, false)
        XCTAssertEqual(options["arguments"] as? [String], [])
        XCTAssertNil(input["payloadURL"])
    }

    func testLaunchURLValidationRejectsNonWebMalformedAndOverLimitInputs() throws {
        let prefix = "https://example.com/"
        let boundary = prefix + String(repeating: "a", count: NativeAppServices.launchURLByteLimit - prefix.utf8.count)
        for value in [boundary, "http://localhost:8080/", "http://[::1]:8080/", "https://xn--fsqu00a.com/%E4%B8%AD", "https://example.com/a%20b"] {
            XCTAssertTrue(NativeAppServices.validLaunchURL(value), value)
        }
        let invalid = [
            "", "example.com", "//example.com/", "https:", "https:/example.com/", "https:///path", "https://:80/",
            "file:///tmp/demo", "javascript:alert(1)", "mailto:test@example.com", "myapp://demo", "ftp://example.com/",
            "https://user:secret@example.com/", "https://@example.com/", " https://example.com/", "https://example.com/a b",
            "https://example.com/a\n", "https://example.com/a\0b", "https://example.com/a%zz", "https://a%2Fb.test/",
            "https://a%00b.test/", "https://a\\b.test/", "https://[hello]/", "https://[1::2::3]/",
            "https://example.com:65536/", "https://example.com:99999999999999999999/",
        ]
        for value in invalid {
            XCTAssertFalse(NativeAppServices.validLaunchURL(value), value)
            XCTAssertThrowsError(try NativeAppServices.launchRequest(bundleID: "com.example.app", payloadURL: value))
        }
        XCTAssertFalse(NativeAppServices.validLaunchURL(boundary + "a"))
    }

    func testLaunchUsesOnlyExactPeerAndAdvertisedService() throws {
        let service = NativeAppServices.serviceName
        var peer: [String: Any] = ["Properties": ["UniqueDeviceID": first], "Services": [service: ["Port": "1234"]]]
        XCTAssertEqual(try NativeAppServices.port(peer: peer, device: first, requiring: [NativeAppServices.launchFeature]), 1234)
        XCTAssertThrowsError(try NativeAppServices.port(peer: peer, device: second, requiring: [NativeAppServices.launchFeature]))
        peer["Services"] = [service: ["Port": "1234", "Features": ["unrelated"]]]
        XCTAssertThrowsError(try NativeAppServices.port(peer: peer, device: first, requiring: [NativeAppServices.launchFeature]))
        peer["Services"] = [:]
        XCTAssertThrowsError(try NativeAppServices.port(peer: peer, device: first, requiring: [NativeAppServices.launchFeature]))
    }

    func testTerminationLookupRequiresExactInstalledBundleAndMainExecutable() throws {
        let id = "com.example.app"
        let bundlePath = "/var/containers/Bundle/Application/A/Example App.app"
        func reply(_ entry: [String: Any]) -> [String: Any] {
            ["Status": "Complete", "LookupResult": [id: entry]]
        }
        let stream = try PlistStream([reply([
            "CFBundleIdentifier": id, "Path": bundlePath, "CFBundleExecutable": "Example",
        ])])
        XCTAssertEqual(
            try NativeAppInventory.executablePath(stream, bundleID: id), "/private" + bundlePath + "/Example")
        let request = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: stream.sent.dropFirst(4), options: [], format: nil) as? [String: Any])
        XCTAssertEqual(request["Command"] as? String, "Lookup")
        XCTAssertEqual((request["ClientOptions"] as? [String: Any])?["BundleIDs"] as? [String], [id])
        for entry in [
            ["CFBundleIdentifier": "com.example.other", "Path": bundlePath, "CFBundleExecutable": "Example"],
            ["CFBundleIdentifier": id, "Path": bundlePath, "CFBundleExecutable": "PlugIns/Extension"],
            ["CFBundleIdentifier": id, "Path": bundlePath],
            ["CFBundleIdentifier": id, "Path": "/var/../Example.app", "CFBundleExecutable": "Example"],
        ] {
            XCTAssertThrowsError(try NativeAppInventory.executablePath(PlistStream([reply(entry)]), bundleID: id))
        }
    }

    func testTerminateSignalsOnlyExactMainExecutableThenReadsBackExit() throws {
        let target = process(42, "file:///var/containers/A/Example%20App.app/Example")
        let extensionProcess = process(43, "file:///private/var/containers/A/Example%20App.app/PlugIns/Other.appex/Example")
        let otherApp = process(44, "file:///private/var/containers/B/Example%20App.app/Example")
        var features: [String] = []
        var signals = 0
        var replies = [processes(target, extensionProcess, otherApp), receipt(42),
                       processes(target, otherApp), processes(extensionProcess, otherApp)]
        let result = try NativeAppServices.terminate(executablePath: executable, exchange: { request in
            let wire = try self.decode(request)
            let feature = try XCTUnwrap(wire["CoreDevice.featureIdentifier"] as? String)
            features.append(feature)
            if feature == NativeAppServices.signalFeature {
                XCTAssertEqual(signals, 1)
                let input = wire["CoreDevice.input"] as? [String: Any]
                XCTAssertEqual((input?["process"] as? [String: Any])?["processIdentifier"] as? Int64, 42)
                XCTAssertEqual(input?["signal"] as? Int64, 9)
            }
            return replies.removeFirst()
        }, willSignal: { signals += 1 }, wait: {})
        guard case .terminated(42) = result else { return XCTFail("Expected verified exit of PID 42") }
        let list = NativeAppServices.processListFeature
        XCTAssertEqual(features, [list, NativeAppServices.signalFeature, list, list])
        XCTAssertEqual(signals, 1)
    }

    func testTerminateDoesNotSignalWhenStoppedOrIdentityIsUncertain() throws {
        let url = "file:///var/containers/A/Example%20App.app/Example"
        let other = process(43, "file:///var/containers/B/Example%20App.app/Example")
        func terminate(_ listing: [String: Any]) throws -> NativeAppServices.TerminationResult {
            try NativeAppServices.terminate(executablePath: executable, exchange: { request in
                XCTAssertEqual(try self.decode(request)["CoreDevice.featureIdentifier"] as? String,
                               NativeAppServices.processListFeature)
                return listing
            }, willSignal: { XCTFail("Must not send a signal") })
        }
        guard case .alreadyStopped = try terminate(processes(other)) else { return XCTFail("Expected no-op") }
        for uncertain in [processes(process(42, url), process(43, url)), processes(process(42, url), process(42, url)),
                          processes(process(1, url)), processes(process(42, nil)), ["CoreDevice.error": "denied"]] {
            XCTAssertThrowsError(try terminate(uncertain))
        }
    }

    func testTerminateNeverResignalsAfterBadReceiptOrRelaunch() throws {
        let url = "file:///var/containers/A/Example%20App.app/Example"
        let target = process(42, url)
        for responses in [[receipt(43)], [receipt(42), ["CoreDevice.error": "disconnected"]],
                          [receipt(42)] + Array(repeating: processes(process(43, url)), count: 5)] {
            var replies = [processes(target)] + responses
            var signals = 0
            XCTAssertThrowsError(try NativeAppServices.terminate(executablePath: executable, exchange: { _ in
                guard !replies.isEmpty else { throw AXDTX.Failure("Unexpected additional request") }
                return replies.removeFirst()
            }, willSignal: { signals += 1 }, wait: {}))
            XCTAssertTrue(replies.isEmpty)
            XCTAssertEqual(signals, 1)
        }
    }

    private let executable = "/private/var/containers/A/Example App.app/Example"

    private func decode(_ request: [String: USBXPCValue]) throws -> [String: Any] {
        var decoder = AXRSDDecoder(data: USBXPCValue.dictionary(request).encode())
        return try XCTUnwrap(try decoder.object() as? [String: Any])
    }

    private func process(_ pid: Int, _ url: String?) -> [String: Any] {
        var token: [String: Any] = ["processIdentifier": pid]
        if let url { token["executableURL"] = ["relative": url] }
        return token
    }

    private func processes(_ entries: [String: Any]...) -> [String: Any] {
        ["CoreDevice.output": ["processTokens": entries]]
    }

    private func receipt(_ pid: Int) -> [String: Any] {
        ["CoreDevice.output": ["process": process(pid, nil), "signal": 9]]
    }

    func testLaunchReceiptAndForegroundAreIndependent() throws {
        func reply(_ pid: Any) -> [String: Any] { ["CoreDevice.output": ["processToken": ["processIdentifier": pid]]] }
        XCTAssertEqual(try NativeAppServices.launchPID(reply(42)), 42)
        for invalid: Any in [true, 0, -1, 1.5, "22", UInt64.max] {
            XCTAssertThrowsError(try NativeAppServices.launchPID(reply(invalid)))
        }
        func verifies(_ tree: [String: Any]) -> Bool {
            NativeAppManagement.verifiesForeground(tree, device: first, bundleID: "com.example.app", launchPID: 42)
        }
        XCTAssertTrue(verifies(["device": first, "foreground_app": ["pid": 42]]))
        XCTAssertTrue(verifies(["device": first, "foreground_app": ["bundle_id": "com.example.app"]]))
        XCTAssertFalse(verifies(["device": second, "foreground_app": ["pid": 42]]))
        XCTAssertFalse(verifies(["device": first, "foreground_app": ["pid": 42, "bundle_id": "com.other.app"]]))
        XCTAssertFalse(verifies(["device": first, "foreground_app": ["pid": 43, "bundle_id": "com.example.app"]]))
        XCTAssertFalse(verifies(["device": first, "foreground_app": NSNull()]))
    }

    func testForegroundProjectionIgnoresUnrelatedNonFiniteAXValues() throws {
        func dump(_ entries: [[String: Any]]) -> [String: Any] {
            ["associatedRequestType": 11, "resultData": ["treeDump": entries]]
        }
        func root(_ id: Int, _ pid: Int) -> [String: Any] {
            ["associatedRequestType": 4, "resultData": ["objectID": id, "pid": pid]]
        }
        let attributes: [String: Any] = [
            "associatedRequestType": 5, "associatedTranslationObject": ["objectID": 1],
            "resultData": ["6": "com.example.app", "53": Double.infinity],
        ]
        let input = dump([root(1, 42), attributes])
        var fullTree = AXTree(includeOffscreen: false)
        XCTAssertThrowsError(try fullTree.update(input))
        var projection = AXTree(includeOffscreen: false, foregroundOnly: true)
        try projection.update(input)
        let observation = projection.foregroundJSON(device: first)
        XCTAssertTrue(
            NativeAppManagement.verifiesForeground(
                observation, device: first, bundleID: "com.example.app", launchPID: 42))
        XCTAssertNil(observation["elements"])
        try projection.update(dump([root(2, 43)]))
        XCTAssertTrue(projection.foregroundJSON(device: first)["foreground_app"] is NSNull)
    }

    func testTunnelDoesNotReadRetransmitsTwiceOrAcceptSequenceGaps() {
        XCTAssertEqual(AXTunnelSocket.retransmittedPrefix(sequence: 100, expected: 100, count: 10), 0)
        XCTAssertEqual(AXTunnelSocket.retransmittedPrefix(sequence: 90, expected: 100, count: 10), 10)
        XCTAssertEqual(AXTunnelSocket.retransmittedPrefix(sequence: 95, expected: 100, count: 10), 5)
        XCTAssertEqual(AXTunnelSocket.retransmittedPrefix(sequence: UInt32.max, expected: 2, count: 5), 3)
        XCTAssertNil(AXTunnelSocket.retransmittedPrefix(sequence: 101, expected: 100, count: 10))
    }

    func testTerminateRoutingRequiresBundleIDAndPOST() throws {
        let bundle = "com.example.app"
        XCTAssertThrowsError(try MCPToolRequest.action(named: "terminate_app", arguments: ["pid": 42], longEdge: 1000))
        let action = try XCTUnwrap(try MCPToolRequest.action(named: "terminate_app", arguments: [
            "device_id": second, "bundle_id": bundle, "pid": 42,
        ], longEdge: 1000))
        XCTAssertEqual(action.path, "/terminate_app")
        XCTAssertEqual(action.body as? [String: String], ["device": second, "bundle_id": bundle])
        for (method, body, status) in [
            ("GET", ["bundle_id": bundle], 404), ("POST", ["pid": "42"], 400),
            ("POST", ["bundle_id": "../../bad"], 400),
        ] {
            let request = HTTPRequest(method: method, path: "/terminate_app", query: [:], body: body)
            let response = AppManagementEndpoint.response(request, operation: .terminate, resolve: { _ in
                XCTFail("Should not select a device for an invalid request"); return self.second
            }, perform: { _, _, _, _ in XCTFail("Should not execute"); return [:] })
            XCTAssertEqual(response.status, status)
        }
    }

    func testLaunchURLRoutesUnchangedThroughMCPAndHTTPAndIsNotReflected() throws {
        let bundle = "com.example.app"
        let url = "https://example.com/path?token=a%2Fb#section"
        for optionalURL in [nil, url] {
            var args: [String: Any] = ["bundle_id": bundle, "device_id": second]
            if let optionalURL { args["url"] = optionalURL }
            let action = try XCTUnwrap(try MCPToolRequest.action(named: "launch_app", arguments: args, longEdge: 1000))
            XCTAssertEqual(action.path, "/launch_app")
            let request = HTTPRequest(method: "POST", path: action.path, query: [:], body: action.body)
            var called = false
            let response = AppManagementEndpoint.response(request, operation: .launch, resolve: { selector in
                XCTAssertEqual(selector, self.second); return self.second
            }, perform: { operation, device, bundleID, payloadURL in
                called = true
                XCTAssertEqual(operation, .launch)
                XCTAssertEqual(device, self.second)
                XCTAssertEqual(bundleID, bundle)
                XCTAssertEqual(payloadURL, optionalURL)
                return ["outcome": "acknowledged"]
            })
            XCTAssertTrue(called)
            XCTAssertEqual(response.status, 200)
            XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("token="))
        }
    }

    func testInvalidAndMisplacedLaunchURLsDoNotResolveADeviceOrRunAnOperation() throws {
        let bundle = "com.example.app"
        let valid = "https://example.com/"
        let credentialed = "https://user:secret@example.com/"
        for (operation, body, query) in [
            (NativeAppManagement.Operation.launch, ["bundle_id": bundle, "url": NSNull()] as [String: Any], [:]),
            (.launch, ["bundle_id": bundle, "url": true], [:]),
            (.launch, ["bundle_id": bundle, "url": credentialed], [:]),
            (.launch, ["url": valid], [:]),
            (.launch, ["bundle_id": bundle], ["url": valid]),
            (.terminate, ["bundle_id": bundle, "url": valid], [:]),
            (.list, ["url": valid], [:]),
        ] {
            if query.isEmpty {
                XCTAssertThrowsError(try MCPToolRequest.action(named: operation.rawValue, arguments: body, longEdge: 1000)) {
                    XCTAssertFalse(String(describing: $0).contains("secret"))
                }
            }
            let request = HTTPRequest(method: "POST", path: operation.path, query: query, body: body)
            let response = AppManagementEndpoint.response(request, operation: operation, resolve: { _ in
                XCTFail("Should reject the URL before looking up any device"); return self.second
            }, perform: { _, _, _, _ in XCTFail("Should not execute"); return [:] })
            XCTAssertEqual(response.status, 400)
            XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("secret"))
        }
    }

    func testAmbiguityAndFailureEvidenceAcrossHTTPAndMCP() throws {
        let devices = [(id: first, name: "iPhone"), (id: second, name: "iPhone")]
        XCTAssertThrowsError(try AppManagementEndpoint.resolve("iPhone", devices: devices))
        XCTAssertThrowsError(try AppManagementEndpoint.resolve(nil, devices: devices))
        XCTAssertEqual(try AppManagementEndpoint.resolve(second, devices: devices), second)
        let request = HTTPRequest(
            method: "POST", path: "/terminate_app", query: [:], body: ["device": second, "bundle_id": "com.example.app"])
        let response = AppManagementEndpoint.response(
            request, operation: .terminate,
            resolve: {
                try AppManagementEndpoint.resolve($0, devices: devices)
            },
            perform: { _, device, bundle, url in
                XCTAssertNil(url)
                XCTAssertEqual(device, self.second)
                XCTAssertEqual(bundle, "com.example.app")
                throw NativeAppManagement.Failure(description: "Missing receipt", outcome: "unknown")
            })
        XCTAssertEqual(response.status, 503)
        let error = MCPAPIError.error(response.body, status: response.status, language: .en)
        XCTAssertEqual(error.details?["outcome"] as? String, "unknown")
        XCTAssertEqual(error.details?["replayAllowed"] as? Bool, false)
    }
}

private final class PlistStream: AXByteStream {
    private var pending = Data()
    var sent = Data()
    init(_ frames: [[String: Any]]) throws {
        for frame in frames {
            let body = try PropertyListSerialization.data(fromPropertyList: frame, format: .binary, options: 0)
            pending += AXUSBProxy.big(UInt64(body.count), 4) + body
        }
    }
    func send(_ data: Data) throws { sent += data }
    func read(_ count: Int) throws -> Data {
        guard pending.count >= count else { throw AXDTX.Failure("Fixture EOF") }
        let output = Data(pending.prefix(count))
        pending.removeFirst(count)
        return output
    }
}
