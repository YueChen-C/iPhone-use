import Darwin
import Foundation
import XPC

// Read-only alternative to direct RSD service discovery: ask Apple's own host
// broker for service sockets; only the deviceinfo control performs an RPC.
// Public libxpc calls carry the request; two private registration symbols are
// resolved at runtime from the installed CoreDevice framework.
// Check-in/usage-assertion sequencing adapted from sunghyun-k/iphone-use
// CoreDeviceClient.swift at 63472c34c0891d836ef7607cc88a15df5c7d59be (MIT).
// Copyright (c) 2026 Sunghyun Kim. See USB/UPSTREAM_LICENSE.txt for the full notice.
enum CoreDeviceTouchBroker {
    final class ReplyBox {
        private let lock = NSLock()
        private var value: xpc_object_t?
        func put(_ object: xpc_object_t) { lock.lock(); value = object; lock.unlock() }
        func get() -> xpc_object_t? { lock.lock(); defer { lock.unlock() }; return value }
    }

    final class AssertionPeers {
        private let lock = NSLock()
        private var peers: [xpc_connection_t] = []
        private var closed = false
        func retain(_ peer: xpc_connection_t) {
            lock.lock(); defer { lock.unlock() }
            if closed { xpc_connection_cancel(peer) } else { peers.append(peer) }
        }
        func cancel() {
            lock.lock(); closed = true; let owned = peers; peers.removeAll(); lock.unlock()
            for peer in owned { xpc_connection_cancel(peer) }
        }
    }

    // Verified on installed CoreDevice397.24. These are feature identifiers,
    // NOT the newer upstream actionIdentifier dialect or a mechanical rename.
    static func featureRequest(_ feature: String, input: xpc_object_t,
                              deviceIdentifier: String, version: String) -> xpc_object_t {
        let request = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(request, "CoreDevice.featureIdentifier", feature)
        xpc_dictionary_set_value(request, "CoreDevice.action", xpc_dictionary_create(nil, nil, 0))
        xpc_dictionary_set_string(request, "CoreDevice.deviceIdentifier", deviceIdentifier)
        xpc_dictionary_set_string(request, "CoreDevice.invocationIdentifier", UUID().uuidString)
        xpc_dictionary_set_int64(request, "CoreDevice.CoreDeviceDDIProtocolVersion", 2)
        let versionObject = xpc_dictionary_create(nil, nil, 0)
        let components = xpc_array_create(nil, 0)
        let numbers = version.split(separator: ".").compactMap { UInt64($0) }
        for index in 0..<5 {
            xpc_array_append_value(components, xpc_uint64_create(index < numbers.count ? numbers[index] : 0))
        }
        xpc_dictionary_set_value(versionObject, "components", components)
        xpc_dictionary_set_int64(versionObject, "originalComponentsCount", Int64(numbers.count))
        xpc_dictionary_set_string(versionObject, "stringValue", version)
        xpc_dictionary_set_value(request, "CoreDevice.coreDeviceVersion", versionObject)
        xpc_dictionary_set_value(request, "CoreDevice.input", input)
        return request
    }

    static func assertionInput(endpoint: xpc_endpoint_t) -> xpc_object_t {
        let input = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(input, "reason", "iphone-use native USB control session")
        // Native397.24 RequiredPreparedness bits: developer mode1, DDI2,
        // extended device info4, power8. No newer requirements.deviceStates.
        let options = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(options, "requiredPreparedness", 15)
        xpc_dictionary_set_value(input, "options", options)
        xpc_dictionary_set_value(input, "endpoint", endpoint)
        return input
    }

    static func fulfilledIdentifier(_ message: xpc_object_t, deviceIdentifier: String) -> String? {
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY,
              let type = xpc_dictionary_get_string(message, "mangledTypeName"),
              String(cString: type) == "CoreDeviceService.AssertionFulfilledMessage",
              let value = xpc_dictionary_get_value(message, "value"),
              let identifier = xpc_dictionary_get_value(value, "identifier"),
              xpc_get_type(identifier) == XPC_TYPE_UUID, let assertionBytes = xpc_uuid_get_bytes(identifier),
              let snapshot = xpc_dictionary_get_value(value, "updatedSnapshot"),
              let info = xpc_dictionary_get_value(snapshot, "deviceInfo"),
              let device = xpc_dictionary_get_value(info, "identifier"),
              xpc_get_type(device) == XPC_TYPE_UUID, let deviceBytes = xpc_uuid_get_bytes(device),
              NSUUID(uuidBytes: deviceBytes).uuidString.caseInsensitiveCompare(deviceIdentifier) == .orderedSame else {
            return nil
        }
        return NSUUID(uuidBytes: assertionBytes).uuidString
    }

    static func withSession(physicalID: String, body: (xpc_connection_t, DispatchQueue, String, String) throws -> Void) throws {
        let path = "/Library/Developer/PrivateFrameworks/CoreDevice.framework"
        guard let bundle = Bundle(path: path),
              let version = bundle.infoDictionary?["CFBundleVersion"] as? String,
              let library = dlopen(path + "/CoreDevice", RTLD_NOW | RTLD_LOCAL),
              let add = dlsym(library, "_coredevice_xpc_add_bundle"),
              let initialize = dlsym(library, "_coredevice_xpc_init_services") else {
            throw AXDTX.Failure("Installed CoreDevice broker registration symbols are unavailable")
        }
        // Registration stores process-global callbacks: keep the framework loaded
        // until this short-lived diagnostic exits rather than dlclose underneath it.
        typealias AddBundle = @convention(c) (AnyObject) -> Void
        typealias Initialize = @convention(c) () -> Void
        unsafeBitCast(add, to: AddBundle.self)(bundle)
        unsafeBitCast(initialize, to: Initialize.self)()
        guard version == "397.24" else {
            throw AXDTX.Failure("Broker dialect verified only for installed CoreDevice397.24; refusing to guess for \(version)")
        }

        let queue = DispatchQueue(label: "iphone-use.native-usb-touch.broker")
        let service = xpc_connection_create("com.apple.CoreDevice.CoreDeviceService", queue)
        let checkedIn = DispatchSemaphore(value: 0)
        let snapshotBox = ReplyBox()
        xpc_connection_set_event_handler(service) { event in
            guard xpc_get_type(event) == XPC_TYPE_DICTIONARY else {
                snapshotBox.put(event); checkedIn.signal(); return
            }
            var message = event
            if let value = xpc_dictionary_get_value(event, "value"),
               let request = xpc_dictionary_get_value(value, "request") { message = request }
            if let type = xpc_dictionary_get_string(message, "mangledTypeName"),
               String(cString: type) == "CoreDevice.DeviceManagerCheckInCompleteEvent" {
                snapshotBox.put(message); checkedIn.signal()
            }
        }
        xpc_connection_resume(service)
        defer { xpc_connection_cancel(service) }
        let checkIn = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(checkIn, "mangledTypeName", "CoreDevice.DeviceManagerCheckInRequest")
        let checkInValue = xpc_dictionary_create(nil, nil, 0)
        var identifier = UUID().uuid
        withUnsafeBytes(of: &identifier) { bytes in
            xpc_dictionary_set_uuid(checkInValue, "identifier", bytes.bindMemory(to: UInt8.self).baseAddress!)
        }
        xpc_dictionary_set_value(checkIn, "value", checkInValue)
        xpc_connection_send_message_with_reply(service, checkIn, queue) { reply in
            if xpc_get_type(reply) == XPC_TYPE_ERROR { snapshotBox.put(reply); checkedIn.signal() }
        }
        guard checkedIn.wait(timeout: .now() + 7) == .success, let snapshot = snapshotBox.get() else {
            throw AXDTX.Failure("Broker check-in timed out; capability result inconclusive; no touch sent")
        }
        guard xpc_get_type(snapshot) == XPC_TYPE_DICTIONARY,
              let value = xpc_dictionary_get_value(snapshot, "value"),
              let devices = xpc_dictionary_get_value(value, "initialDeviceSnapshots"),
              xpc_get_type(devices) == XPC_TYPE_ARRAY else {
            let description = xpc_copy_description(snapshot)
            defer { free(description) }
            throw AXDTX.Failure("Broker check-in unavailable: \(String(cString: description)); no touch sent")
        }
        var matches: [String] = []
        xpc_array_apply(devices) { _, device in
            if let info = xpc_dictionary_get_value(device, "deviceInfo"),
               let udid = xpc_dictionary_get_string(info, "udid"), String(cString: udid) == physicalID,
               let key = xpc_dictionary_get_value(info, "identifier"),
               xpc_get_type(key) == XPC_TYPE_UUID, let bytes = xpc_uuid_get_bytes(key) {
                matches.append(NSUUID(uuidBytes: bytes).uuidString)
            }
            return true
        }
        guard matches.count == 1, let deviceIdentifier = matches.first else {
            throw AXDTX.Failure("USB physical identity unavailable or ambiguous; no device fallback")
        }
        // Fulfilment arrives on an endpoint, not as the action reply (which is
        // delayed until release). Keep our listener/peers alive for the sockets.
        let fulfilled = DispatchSemaphore(value: 0)
        let assertionReply = ReplyBox()
        let peers = AssertionPeers()
        let listener = xpc_connection_create(nil, queue)
        xpc_connection_set_event_handler(listener) { peer in
            guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
            xpc_connection_set_event_handler(peer) { message in
                guard fulfilledIdentifier(message, deviceIdentifier: deviceIdentifier) != nil else { return }
                assertionReply.put(message); fulfilled.signal()
            }
            peers.retain(peer)
            xpc_connection_activate(peer)
        }
        xpc_connection_activate(listener)
        defer {
            xpc_connection_cancel(listener); peers.cancel()
        }
        let assertion = featureRequest("com.apple.coredevice.feature.acquireusageassertion",
                                      input: assertionInput(endpoint: xpc_endpoint_create(listener)),
                                      deviceIdentifier: deviceIdentifier, version: version)
        xpc_connection_send_message_with_reply(service, assertion, queue) { reply in
            assertionReply.put(reply); fulfilled.signal()
        }
        guard fulfilled.wait(timeout: .now() + 12) == .success, let reply = assertionReply.get() else {
            throw AXDTX.Failure("Broker usage assertion timed out; capability result inconclusive; no touch sent")
        }
        guard let assertionID = fulfilledIdentifier(reply, deviceIdentifier: deviceIdentifier) else {
            let description = xpc_copy_description(reply); defer { free(description) }
            throw AXDTX.Failure("Broker usage assertion was not fulfilled: \(String(cString: description)); no touch sent")
        }
        _ = assertionID
        guard let value = xpc_dictionary_get_value(reply, "value"),
              let updated = xpc_dictionary_get_value(value, "updatedSnapshot"),
              let info = xpc_dictionary_get_value(updated, "deviceInfo"),
              let udid = xpc_dictionary_get_string(info, "udid"), String(cString: udid) == physicalID else {
            throw AXDTX.Failure("USB assertion physical identity mismatch")
        }
        try body(service, queue, deviceIdentifier, version)
    }

    static func connect(_ name: String, service: xpc_connection_t, queue: DispatchQueue,
                        deviceIdentifier: String, version: String) throws -> USBRemoteXPC {
        let input = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(input, "serviceName", name)
        let request = featureRequest("com.apple.dt.servicesocket.create", input: input,
                                     deviceIdentifier: deviceIdentifier, version: version)
        let completed = DispatchSemaphore(value: 0), box = ReplyBox()
        xpc_connection_send_message_with_reply(service, request, queue) { box.put($0); completed.signal() }
        guard completed.wait(timeout: .now() + 7) == .success, let response = box.get(),
              xpc_get_type(response) == XPC_TYPE_DICTIONARY,
              xpc_dictionary_get_value(response, "CoreDevice.error") == nil,
              let output = xpc_dictionary_get_value(response, "CoreDevice.output"),
              xpc_get_type(output) == XPC_TYPE_DICTIONARY else {
            throw AXDTX.Failure("USB service unavailable; check DDI capability: \(name)")
        }
        return try USBRemoteXPC(socket: USBBrokerSocket(taking: xpc_dictionary_dup_fd(output, "fileDescriptor")))
    }
}