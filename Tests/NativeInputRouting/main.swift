import Darwin
import Foundation

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == USBTouchWorker.argument {
    exit(USBTouchWorker.run(physicalID: CommandLine.arguments[2]))
}
func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw AXDTX.Failure(message) }
}
func wait(_ message: String, _ predicate: () -> Bool) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 7
    while !predicate(), ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.002) }
    try require(predicate(), message)
}
func state(_ controller: USBInputController, _ device: Device) -> String {
    controller.status(device)["state"] as? String ?? "ble"
}
let mode = CommandLine.arguments.dropFirst().first ?? "normal"
try require(["normal", "backpressure", "held-pointer", "queued-key", "usb-release-failure", "buttons", "without-buttons", "button-release-failure"].contains(mode), "unknown mode")
let controller = USBInputController(), hid = HIDPeripheral.shared
let pause = InputPause()
let a = Device(id: ["usb-release-failure", "without-buttons", "button-release-failure"].contains(mode) ? mode : "target", screen: ScreenCaptureSession())
let b = Device(id: "peer", screen: ScreenCaptureSession())
let hostA = UUID(), hostB = UUID()
func input(_ device: Device, _ host: UUID) -> DeviceInput {
    let session = hid.subscribe(host), generation = controller.generation(device.id)
    let input = DeviceInput(host: host, session: session,
                            inputIsAllowed: { controller.permitsBLE(device.id, generation: generation) },
                            sleep: { _ in if device.id == a.id { pause.pause() } })
    DeviceRegistry.shared.retain(input, for: device)
    return input
}
let old = input(a, hostA), peer = input(b, hostB)
try old.key("a", modifiers: ["cmd"])
try peer.key("b", modifiers: [])
try require(hid.reports(hostA).count == 4 && hid.reports(hostB).count == 2, "initial BLE input")
if mode == "backpressure" { hid.block(hostA, true) }
var heldPoint: Data?
if mode == "held-pointer" {
    old.press(x: 0.2, y: 0.3)
    try wait("accepted BLE down") { hid.reports(hostA).last?.1.first == 1 }
    heldPoint = hid.reports(hostA).last!.1
    hid.block(hostA, true)
    old.drag(x: 0.8, y: 0.9)
    try wait("queued BLE motion") { hid.pending(hostA) > 0 }
}
let beforeQueuedKey = hid.reports(hostA).count
if mode == "queued-key" {
    pause.arm()
    try require(old.keyFromKeyboard("a"), "initial window key")
    try require(pause.entered.wait(timeout: .now() + 7) == .success, "key pacing boundary")
    try require(old.keyFromKeyboard("v", modifiers: ["cmd"]), "queued window shortcut")
}
controller.select(.usb, device: a)
try require(!controller.permitsBLE(a.id, generation: nil), "BLE admission must close synchronously")
if mode == "queued-key" { pause.open() }
if mode == "backpressure" || mode == "held-pointer" {
    try wait("failed release gate") { state(controller, a) == "failed" }
    try require(controller.input(a) == nil && hid.pending(hostA) > 0, "USB activated before BLE drain")
    try peer.key("c", modifiers: [])
    try require(hid.reports(hostB).count == 4, "peer blocked by target backpressure")
    hid.block(hostA, false)
    controller.select(.usb, device: a)
}
try wait("USB readiness") { controller.input(a)?.isReady == true }
try require(old.isRetired && controller.selected(b.id) == .ble, "old BLE retired/peer selection")
if let heldPoint {
    let pointers = hid.reports(hostA).filter { $0.0 == .absolutePointer }
    var releasedPoint = heldPoint; releasedPoint[0] = 0
    try require(pointers.count == 3 && pointers.last!.1 == releasedPoint,
                "stale motion accepted or BLE released at wrong position")
    print("heldPointer lastAcceptedRelease=true staleMotionDropped=true")
}
if mode == "queued-key" {
    let reports = Array(hid.reports(hostA).dropFirst(beforeQueuedKey))
    try require(!pause.timedOut && reports.count == 5 && reports[0].0 == .keyboard
                && reports[0].1 == Data(HIDReportPayload.keyboard(code: KeyboardMap.code(for: "a")!))
                && reports.dropFirst().allSatisfy { $0.1.allSatisfy { $0 == 0 } },
                "queued shortcut escaped invalidation")
    print("queuedKeyboard oldPressDropped=true neutralReleaseDrained=true")
}
let cutoff = hid.reports(hostA).count
try old.key("v", modifiers: ["cmd"])
old.consumer(0x0223)
try require(hid.reports(hostA).count == cutoff, "retired BLE sent new input")
let usb = controller.input(a)!
try require(usb.isKeyboardReady, "native USB keyboard discovery")
if mode == "usb-release-failure" {
    do { try usb.gesture("tap", points: [.init(x: 0.2, y: 0.3)], duration: 0.02); throw AXDTX.Failure("fault accepted") }
    catch let error as USBInputFailure { try require(error.mayHaveExecuted, "uncertain delivery lost") }
    controller.select(.ble, device: a)
    try wait("USB missing release gate") { state(controller, a) == "failed" }
    try require(!controller.permitsBLE(a.id, generation: nil), "unconfirmed USB release enabled BLE")
    try require(controller.selected(b.id) == .ble && peer.isBluetoothReady
                && hid.reports(hostB).count == 2, "USB fault changed peer route or reports")
    try require(!controller.stop(waitTimeout: 6), "failed release was marked clean")
    print("mode=usb-release-failure uncertain=true bleAllowed=false stop=false peerUnchanged=true hardware=simulated")
    exit(0)
}
if mode == "without-buttons" {
    try require(!usb.isButtonsReady && usb.isKeyboardReady, "optional Indigo degraded keyboard")
    do { try usb.button(.home); throw AXDTX.Failure("unsupported button accepted") }
    catch let error as USBInputFailure { try require(!error.mayHaveExecuted, "missing service dispatched input") }
    try require(usb.isReady && !usb.buttonFromWindow(.home), "missing Indigo retired healthy worker")
    print("buttons absent=true touchKeyboardReady=true noFallback=true")
}
if mode == "buttons" || mode == "button-release-failure" {
    try require(usb.isButtonsReady, "Indigo capability missing")
    if mode == "button-release-failure" {
        do { try usb.button(.home); throw AXDTX.Failure("button release fault accepted") }
        catch let error as USBInputFailure { try require(error.mayHaveExecuted, "button uncertainty lost") }
        controller.select(.ble, device: a)
        try wait("button release gate") { state(controller, a) == "failed" }
        try require(!controller.permitsBLE(a.id, generation: nil) && !controller.stop(waitTimeout: 6), "button release failed open")
        print("buttons uncertain=true releaseUnconfirmed=true bleAllowed=false hardware=simulated")
        exit(0)
    }
    try require(usb.down(.init(x: 0.4, y: 0.5)), "held pointer")
    try require(!usb.buttonFromWindow(.home), "button queued behind held pointer")
    do { try usb.button(.home); throw AXDTX.Failure("button accepted while held") }
    catch let error as USBInputFailure { try require(!error.mayHaveExecuted, "busy button sent") }
    usb.up(.init(x: 0.4, y: 0.5))
    // Queue serialization drains up/PING before the synchronous button.
    var admitted = false
    try wait("window release") {
        if !admitted { admitted = usb.buttonFromWindow(.home) }
        return admitted
    }
    // Next sync operation drains that one admitted window button.
    try usb.button(.volumeUp); try usb.button(.volumeDown); try usb.button(.power)
    let expired = DispatchSemaphore(value: 0)
    var expiredSafely = false
    try require(usb.buttonFromWindow(.home), "first window button refused")
    try require(usb.buttonFromWindow(.volumeUp) { result in
        if case .failure(let failure as USBInputFailure) = result {
            expiredSafely = !failure.mayHaveExecuted
        }
        expired.signal()
    }, "queued window button refused")
    try require(expired.wait(timeout: .now() + 7) == .success && expiredSafely, "expired window button replayed")
    print("buttons home=true power=true volume=true heldPointerRejected=true queuedExpired=true hardware=simulated")
}
try usb.gesture("tap", points: [.init(x: 0.2, y: 0.3)], duration: 0.02)
try usb.key("v", modifiers: ["cmd"])
let root = ProcessInfo.processInfo.environment["INPUT_ROUTING_FIXTURE_ROOT"]!
let transport = URL(fileURLWithPath: root).appendingPathComponent(a.id + ".transport")
let nativeReports = try String(contentsOf: transport, encoding: .utf8)
try require(nativeReports.contains("surface:7 report:") && nativeReports.contains("surface:8 report:"),
            "touch/keyboard did not share native worker")
if mode == "buttons" {
    let buttonReports = nativeReports.split(separator: "\n").filter { $0.hasPrefix("button:") }.map(String.init)
    let expected = [USBHardwareButton.home, .volumeUp, .volumeDown, .power, .home].flatMap { button in
        ["button:12:\(button.usage):1", "button:12:\(button.usage):2"]
    }
    try require(buttonReports == expected, "Indigo button sequence or mapping mismatch")
    try require(hid.reports(hostA).count == cutoff, "USB buttons escaped to BLE")
}
let keyboardReports = nativeReports.split(separator: "\n").filter { $0.hasPrefix("surface:8 report:") }
let stroke = try USBKeyboardRequest.key("v", modifiers: ["cmd"])
let expectedKeys = try [USBKeyboardReport.encode(modifiers: stroke.modifiers),
                        USBKeyboardReport.encode(code: stroke.code, modifiers: stroke.modifiers),
                        USBKeyboardReport.encode(modifiers: stroke.modifiers), USBKeyboardReport.encode()]
try require(keyboardReports.map(String.init) == expectedKeys.map { "surface:8 report:" + $0.base64EncodedString() },
            "native USB shortcut press/release bytes")
controller.select(.ble, device: a)
try wait("explicit BLE return") { controller.permitsBLE(a.id, generation: nil) }
try require(!usb.isReady, "old USB revived")
let afterRetirement = try String(contentsOf: transport, encoding: .utf8)
do {
    try usb.key("enter", modifiers: [])
    throw AXDTX.Failure("retired USB key accepted")
} catch let error as USBInputFailure {
    try require(!error.mayHaveExecuted, "retired key dispatch evidence")
}
do {
    try usb.button(.home)
    throw AXDTX.Failure("retired USB button accepted")
} catch let error as USBInputFailure {
    try require(!error.mayHaveExecuted, "retired button dispatch evidence")
}
try require(try String(contentsOf: transport, encoding: .utf8) == afterRetirement, "retired USB sent input")
let fresh = input(a, hostA)
try fresh.key("enter", modifiers: [])
try require(hid.reports(hostA).count >= cutoff + 2, "BLE did not resume")
try peer.key("d", modifiers: [])
try require(hid.reports(hostB).count == (["backpressure", "held-pointer"].contains(mode) ? 6 : 4), "peer route changed")
try require(controller.stop(waitTimeout: 6), "clean stop")
try require(!controller.permitsBLE(a.id, generation: nil) && !controller.permitsBLE(b.id, generation: nil), "shutdown admission")
print("mode=\(mode) bleToUSB=true oldBLEBlocked=true usbKeyboard=true usbToBLE=true oldUSBBlocked=true peerIsolated=true stop=true hardware=simulated")
if mode == "normal" {
    // Exercise the production worker with a real pipe EOF, not a fake release.
    let child = Process(), stdin = Pipe(), stdout = Pipe()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = [USBTouchWorker.argument, "eof"]
    child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
    try child.run()
    try stdin.fileHandleForWriting.close()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    child.waitUntilExit()
    let events = try output.split(separator: 10).map {
        (try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])?["event"] as? String
    }
    try require(child.terminationReason == .exit && child.terminationStatus == 0
                && events == ["ready", "released"], "worker must confirm EOF release exactly once")
    print("workerEOF releaseEvents=1 exit=0 hardware=simulated")
}
