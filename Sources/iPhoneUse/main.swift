import Foundation

// Native USB control runs in this executable, isolated from AppKit/BLE/capture.
if CommandLine.arguments.dropFirst().first == USBTouchWorker.argument {
    guard CommandLine.arguments.count == 3 else { exit(64) }
    exit(USBTouchWorker.run(physicalID: CommandLine.arguments[2]))
}

// An opt-in, read-only listener for validating AX without a second BLE/capture owner.
if CommandLine.arguments.dropFirst().first == "--ax-server" {
    guard CommandLine.arguments.count == 4, let port = UInt16(CommandLine.arguments[3]), port > 0 else { exit(64) }
    do { try AXTreeEndpoint.serve(device: CommandLine.arguments[2], port: port) }
    catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(70) }
    exit(0)
}

if CommandLine.arguments.dropFirst().first == NativeAXTree.workerArgument {
    guard CommandLine.arguments.count == 5, ["0", "1"].contains(CommandLine.arguments[4]) else { exit(64) }
    exit(NativeAXTree.write(device: CommandLine.arguments[2],
        output: URL(fileURLWithPath: CommandLine.arguments[3]), includeOffscreen: CommandLine.arguments[4] == "1"))
}

// Keep potentially blocking system device calls outside the GUI/capture process.
// This worker starts neither AppKit, Bluetooth nor the HTTP server.
if CommandLine.arguments.dropFirst().first == USBIdentityScreenshot.workerArgument {
    guard CommandLine.arguments.count == 4 else { exit(USBIdentityScreenshot.failedExitCode) }
    exit(
        USBIdentityScreenshot.write(
            physicalID: CommandLine.arguments[2], output: URL(fileURLWithPath: CommandLine.arguments[3])))
}

if CommandLine.arguments.dropFirst().first == "mcp" {
    MCPServer.run()
}

Application.run()
