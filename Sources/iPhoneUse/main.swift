import Foundation

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
