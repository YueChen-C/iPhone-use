import AVFoundation
import CoreImage
import CoreMediaIO
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Every iPhone plugged in over USB. A trusted iPhone shows up as a muxed capture
/// device once screen-capture devices are allowed (the same switch QuickTime flips).
final class ScreenCaptureManager {
    static let shared = ScreenCaptureManager()

    // The lock serializes discovery callbacks, timer refreshes and API reads.
    private let lock = NSLock()
    /// AVFoundation's nominal UIDs can be attached to the other iPhone's pixels
    /// when multiple muxed devices are present. Keep acquisition keyed by its
    /// source UID separately from the verified physical screen identity.
    private var sources: [String: ScreenCaptureSource] = [:]
    private var screens: [String: ScreenCaptureSession] = [:]
    private var refreshTimer: Timer?
    private var loggedNoScreens = false
    private let identityQueue = DispatchQueue(label: "iphone-use.capture-identity", qos: .utility)
    private var identityGeneration: UInt64 = 0
    private var verificationState: ScreenCaptureIdentityState = .singleDevice

    /// Called when a phone's screen appears or goes away.
    var onScreensChanged: (() -> Void)?

    func start() {
        allowScreenCaptureDevices()
        observeDeviceChanges()

        // CoreMediaIO can publish the iPhone capture device shortly after USB trust,
        // camera permission, or the screen-capture switch completes. A one-shot
        // refresh misses that transition, so keep a cheap watcher for reconnects too.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        AVCaptureDevice.requestAccess(for: .video) { granted in
            log("camera access \(granted ? "granted" : "denied")")
            self.refresh()
        }
    }

    private func allowScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    private func observeDeviceChanges() {
        NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.refresh() }
        NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.refresh() }
    }

    var all: [ScreenCaptureSession] {
        lock.withLock { screens.values.sorted { $0.name < $1.name } }
    }

    var identityState: ScreenCaptureIdentityState { lock.withLock { verificationState } }

    var permitsPointerAssociation: Bool {
        lock.withLock {
            verificationState == .singleDevice || verificationState == .verified
                || verificationState == .unavailable
        }
    }

    /// Explicit matching can retry after identical/black/dynamic screens become
    /// distinguishable. Status polling never starts new screenshot work.
    func retryIdentityVerification() {
        let job: (UInt64, [String: ScreenCaptureSource])? = lock.withLock {
            guard sources.count > 1,
                verificationState == .failed || verificationState == .unavailable
            else { return nil }
            identityGeneration &+= 1
            verificationState = .pending
            return (identityGeneration, sources)
        }
        guard let job else { return }
        onScreensChanged?()
        scheduleIdentityVerification(generation: job.0, sources: job.1)
    }

    private func refresh() {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: .muxed, position: .unspecified
        ).devices.filter { $0.modelID.contains("iOS") && $0.isConnected }
        let present = Set(devices.map(\.uniqueID))
        var changed = false
        var job: (UInt64, [String: ScreenCaptureSource])?
        lock.withLock {
            for (id, source) in sources where !present.contains(id) {
                source.stop()
                sources[id] = nil
                changed = true
                log("screen gone: \(source.name)")
            }
            for device in devices where sources[device.uniqueID] == nil {
                do {
                    sources[device.uniqueID] = try ScreenCaptureSource(device: device)
                    changed = true
                    log("capturing \(device.localizedName) (\(device.uniqueID))")
                } catch {
                    log("capture failed for \(device.localizedName): \(error)")
                }
            }
            if changed {
                identityGeneration &+= 1
                if present.count > 1 {
                    // A failed capture must not turn two discovered phones into
                    // an assumed single-device identity.
                    verificationState = sources.count == present.count ? .pending : .failed
                } else {
                    verificationState = .singleDevice
                }
                rebuildScreens(mapping: sources.mapValues(\.id), verified: false)
                if verificationState == .pending { job = (identityGeneration, sources) }
            }
            if sources.isEmpty {
                if !loggedNoScreens {
                    log("no iPhone screen yet (plug in over USB and trust this Mac)")
                    loggedNoScreens = true
                }
            } else {
                loggedNoScreens = false
            }
        }
        // Matching reads all again; notify only after releasing the discovery lock.
        if changed { onScreensChanged?() }
        if let job { scheduleIdentityVerification(generation: job.0, sources: job.1) }
    }

    /// Called under lock. New wrappers also invalidate Registry associations that
    /// were proved against an earlier capture-to-physical mapping.
    private func rebuildScreens(mapping: [String: String], verified: Bool) {
        screens = mapping.reduce(into: [:]) { result, entry in
            guard let physical = sources[entry.key], let source = sources[entry.value] else { return }
            result[entry.key] = ScreenCaptureSession(
                id: entry.key, name: physical.name, source: source, identityVerified: verified)
        }
    }

    private func scheduleIdentityVerification(generation: UInt64, sources: [String: ScreenCaptureSource]) {
        // Wait for newly started streams to deliver their first complete frames.
        identityQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let isCurrent = { self.lock.withLock { self.identityGeneration == generation } }
            guard isCurrent() else { return }
            let result = CaptureIdentityVerifier.verify(
                physicalIDs: sources.keys.sorted(),
                sourceImages: { sources.compactMapValues { $0.identityImage() } },
                isCurrent: isCurrent)
            let applied = self.lock.withLock { () -> Bool in
                guard self.identityGeneration == generation else { return false }
                switch result {
                case .verified(let mapping):
                    self.rebuildScreens(mapping: mapping, verified: true)
                    self.verificationState = .verified
                    log("capture identity verified: \(mapping)")
                case .unavailable:
                    self.rebuildScreens(mapping: sources.mapValues(\.id), verified: false)
                    self.verificationState = .unavailable
                    log("capture identity unverified: independent USB screenshot tool unavailable")
                case .failed:
                    self.verificationState = .failed
                    log("capture identity verification failed: no unique complete USB-to-video mapping")
                }
                return true
            }
            if applied { self.onScreensChanged?() }
        }
    }
}

/// One physical iPhone's public screen identity. Acquisition may come from a
/// different nominal AVFoundation UID after independent USB verification.
final class ScreenCaptureSession {
    let id: String
    let name: String
    let identityVerified: Bool
    private let source: ScreenCaptureSource

    var sourceID: String { source.id }
    var size: CGSize? { source.size }

    fileprivate init(id: String, name: String, source: ScreenCaptureSource, identityVerified: Bool) {
        self.id = id
        self.name = name
        self.source = source
        self.identityVerified = identityVerified
    }

    func frame() -> CVPixelBuffer? { source.frame() }

    func snapshot(png: Bool, maxWidth: Int? = nil, maxEdge: Int? = nil) -> Data? {
        source.snapshot(png: png, maxWidth: maxWidth, maxEdge: maxEdge)
    }

    func thumbnail(width: Int, height: Int) -> [UInt8]? { source.thumbnail(width: width, height: height) }
}

/// A nominal AVFoundation acquisition source. Its UID is never rewritten by
/// screen identity verification, so ordinary device refreshes preserve remaps.
private final class ScreenCaptureSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private static let context = CIContext()

    /// The nominal capture device UID, independent of the pixels' physical phone.
    let id: String
    let name: String
    let device: AVCaptureDevice

    private let session = AVCaptureSession()
    private let queue: DispatchQueue
    /// Read and written only on queue; callers retain a snapshot before rendering.
    private var latest: CVPixelBuffer?

    init(device: AVCaptureDevice) throws {
        self.device = device
        id = device.uniqueID
        name = device.localizedName
        queue = DispatchQueue(label: "iphone-use.capture.\(device.uniqueID)")
        super.init()

        try configureSession()
        session.startRunning()
    }

    private func configureSession() throws {
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError("cannot capture \(name)") }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CaptureError("cannot read frames from \(name)") }
        session.addOutput(output)
    }

    func stop() {
        session.stopRunning()
    }

    var size: CGSize? {
        frame().map { CGSize(width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0)) }
    }

    func frame() -> CVPixelBuffer? {
        queue.sync { latest }
    }

    func identityImage() -> CaptureIdentityImage? {
        guard let buffer = frame() else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = Self.context.createCGImage(image, from: image.extent) else { return nil }
        return CaptureIdentityImage(image: cgImage)
    }

    /// JPEG or PNG of the latest frame, scaled so neither edge exceeds the limits.
    func snapshot(png: Bool, maxWidth: Int? = nil, maxEdge: Int? = nil) -> Data? {
        guard let buffer = frame() else { return nil }
        var image = CIImage(cvPixelBuffer: buffer)
        var scale = 1.0
        if let maxWidth { scale = min(scale, Double(maxWidth) / image.extent.width) }
        if let maxEdge { scale = min(scale, Double(maxEdge) / max(image.extent.width, image.extent.height)) }
        if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        guard let cgImage = Self.context.createCGImage(image, from: image.extent) else { return nil }
        let data = NSMutableData()
        let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(
            destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Grayscale pixels of the latest frame at a small size, first row at the top.
    func thumbnail(width: Int, height: Int) -> [UInt8]? {
        guard let buffer = frame() else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        let small = image.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(width) / image.extent.width, y: CGFloat(height) / image.extent.height))
        guard let cgImage = Self.context.createCGImage(small, from: small.extent) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        latest = CMSampleBufferGetImageBuffer(sampleBuffer)
    }

    struct CaptureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
