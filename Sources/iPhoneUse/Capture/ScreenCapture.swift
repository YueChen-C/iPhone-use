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
    private var verifiedScreenIDs: Set<String> = []
    private var refreshTimer: Timer?
    private var loggedNoScreens = false
    private let identityQueue = DispatchQueue(label: "iphone-use.capture-identity", qos: .utility)
    private var identityGeneration: UInt64 = 0
    private var verificationState: ScreenCaptureIdentityState = .singleDevice
    private var associationIdentities = CaptureAssociationIdentity()
    private var sourceRecovery = CaptureSourceRecovery()

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
        lock.withLock { verificationState.permitsAssociation(identityVerified: true) }
    }

    func permitsPointerAssociation(for screen: ScreenCaptureSession) -> Bool {
        lock.withLock {
            screens[screen.id] === screen
                && verificationState.permitsAssociation(identityVerified: verifiedScreenIDs.contains(screen.id))
        }
    }

    func isCurrent(_ screen: ScreenCaptureSession) -> Bool {
        lock.withLock { screens[screen.id] === screen }
    }

    func identityVerified(for screen: ScreenCaptureSession) -> Bool {
        lock.withLock { screens[screen.id] === screen && verifiedScreenIDs.contains(screen.id) }
    }

    var associationScreens: [ScreenCaptureSession] {
        lock.withLock {
            screens.values.filter {
                verificationState.permitsAssociation(identityVerified: verifiedScreenIDs.contains($0.id))
            }
            .sorted { $0.name < $1.name }
        }
    }

    /// Explicit matching can retry after identical/black/dynamic screens become
    /// distinguishable. Status polling never starts new screenshot work.
    func retryIdentityVerification() {
        let job: (UInt64, [String: ScreenCaptureSource])? = lock.withLock {
            guard sources.count > 1,
                verificationState == .failed || verificationState == .unavailable
                    || verificationState == .partiallyVerified
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
                associationIdentities.retain(physicalIDs: Set(sources.keys))
                sourceRecovery.retain(sources: Set(sources.values.map(\.instanceID)))
                identityGeneration &+= 1
                if present.count > 1 {
                    // A failed capture must not turn two discovered phones into
                    // an assumed single-device identity.
                    verificationState = sources.count == present.count ? .pending : .failed
                } else {
                    verificationState = .singleDevice
                }
                rebuildScreens(mapping: [:], verified: false)
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

    /// Called under lock. Retain surviving preview objects and Bluetooth proofs
    /// while input remains blocked by the separate capture verification state.
    private func rebuildScreens(mapping: [String: String], verified: Bool) {
        let displayMapping = CaptureScreenMapping.previews(
            confirmed: mapping,
            previous: screens.mapValues { .init(id: $0.sourceID, instance: $0.sourceInstanceID) },
            sources: sources.mapValues(\.instanceID))
        verifiedScreenIDs = verified ? Set(mapping.keys) : []
        screens = displayMapping.reduce(into: [:]) { result, entry in
            guard let physical = sources[entry.key], let source = sources[entry.value] else { return }
            let identity = associationIdentities.identity(
                physicalID: entry.key,
                isConfirmed: (verified && mapping[entry.key] != nil) || verificationState == .singleDevice)
            if let previous = screens[entry.key], previous.sourceInstanceID == source.instanceID,
                previous.associationIdentity == identity
            {
                result[entry.key] = previous
                return
            }
            result[entry.key] = ScreenCaptureSession(
                id: entry.key, name: physical.name, source: source,
                associationIdentity: identity)
        }
    }

    private func scheduleIdentityVerification(
        generation: UInt64, sources: [String: ScreenCaptureSource], retryOnFailure: Bool = true,
        delay: TimeInterval = 0.5
    ) {
        // Wait for newly started streams to deliver their first complete frames.
        identityQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let isCurrent = { self.lock.withLock { self.identityGeneration == generation } }
            guard isCurrent() else { return }
            let result = CaptureIdentityVerifier.verify(
                physicalIDs: sources.keys.sorted(),
                sourceImages: { sources.compactMapValues { $0.identityImage() } },
                isCurrent: isCurrent)
            var shouldRetry = false
            var shouldRecover = false
            let applied = self.lock.withLock { () -> Bool in
                guard self.identityGeneration == generation else { return false }
                switch result {
                case .verified(let mapping):
                    self.rebuildScreens(mapping: mapping, verified: true)
                    self.verificationState = .verified
                    log("capture identity verified: \(mapping)")
                case .partiallyVerified(let mapping):
                    self.rebuildScreens(mapping: mapping, verified: true)
                    self.verificationState = .partiallyVerified
                    log("capture identity partially verified: \(mapping)")
                    shouldRecover = true
                case .unavailable:
                    // Without an independent check, pointer discovery must
                    // prove this mapping again before reusing Bluetooth input.
                    self.associationIdentities = CaptureAssociationIdentity()
                    self.rebuildScreens(mapping: [:], verified: false)
                    self.verificationState = .unavailable
                    log("capture identity unverified: native USB screenshot service unavailable")
                case .failed:
                    self.verificationState = .failed
                    shouldRetry = retryOnFailure
                    shouldRecover = !retryOnFailure
                    log("capture identity verification failed: no unique complete USB-to-video mapping")
                }
                if shouldRecover {
                    let empty = sources.values.filter { $0.frame() == nil }
                    let selected = self.sourceRecovery.take(empty: Set(empty.map(\.instanceID)))
                    shouldRecover = !selected.isEmpty
                    if shouldRecover {
                        // Starting/stopping one muxed stream can reroute another
                        // stream's pixels. Keep Bluetooth proofs, but recheck
                        // the complete video mapping before accepting input.
                        self.verificationState = .pending
                        for source in empty where selected.contains(source.instanceID) {
                            log("restarting empty capture source: \(source.name) (\(source.id))")
                            source.restart()
                        }
                    }
                }
                return true
            }
            if applied { self.onScreensChanged?() }
            if applied, shouldRecover {
                self.scheduleIdentityVerification(
                    generation: generation, sources: sources, retryOnFailure: false, delay: 1.5)
            } else if applied, shouldRetry {
                // Capture and screenshotr can race during USB/service startup.
                // One delayed retry gives them time to settle without polling
                // indefinitely or ever moving a pointer for identity checks.
                self.scheduleIdentityVerification(
                    generation: generation, sources: sources, retryOnFailure: false, delay: 3)
            }
        }
    }
}

/// One physical iPhone's public screen identity. Acquisition may come from a
/// different nominal AVFoundation UID after independent USB verification.
final class ScreenCaptureSession {
    let id: String
    let name: String
    let associationIdentity: UUID
    private let source: ScreenCaptureSource

    var sourceID: String { source.id }
    var sourceInstanceID: UUID { source.instanceID }
    var size: CGSize? { source.size }

    fileprivate init(
        id: String, name: String, source: ScreenCaptureSource, associationIdentity: UUID
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.associationIdentity = associationIdentity
    }

    func frame() -> CVPixelBuffer? { source.frame() }

    func observationFrame() -> ScreenCaptureFrameStore.Snapshot? { source.observationFrame() }

    func snapshot(png: Bool, maxWidth: Int? = nil, maxEdge: Int? = nil) -> Data? {
        source.snapshot(png: png, maxWidth: maxWidth, maxEdge: maxEdge)
    }

    func thumbnail(width: Int, height: Int) -> [UInt8]? { source.thumbnail(width: width, height: height) }

    /// Wait for an atomically identified USB frame received after the input
    /// deadline. Call from the phone's input queue, never the capture callback.
    func pointerFrame(
        after sequence: UInt64?, notBefore: TimeInterval, timeout: TimeInterval = 2
    ) throws -> VisualPointerFrame {
        try source.pointerFrame(after: sequence, notBefore: notBefore, timeout: timeout)
    }
}

/// Keeps frame pixels and their freshness metadata under the same lock. Waiting
/// releases this lock so the capture callback can publish and wake consumers.
final class ScreenCaptureFrameStore {
    struct Snapshot {
        let buffer: CVPixelBuffer
        let sequence: UInt64
        let receivedAt: TimeInterval
    }

    private let condition = NSCondition()
    private var latest: Snapshot?
    private var sequence: UInt64 = 0
    private var stopped = false

    func publish(_ buffer: CVPixelBuffer, receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        condition.lock()
        defer { condition.unlock() }
        guard !stopped, receivedAt.isFinite, receivedAt >= 0, sequence < .max else { return }
        sequence += 1
        latest = Snapshot(buffer: buffer, sequence: sequence, receivedAt: receivedAt)
        condition.broadcast()
    }

    func snapshot() -> Snapshot? {
        condition.lock()
        defer { condition.unlock() }
        return latest
    }

    func wait(after sequence: UInt64?, notBefore: TimeInterval, timeout: TimeInterval) throws -> Snapshot {
        guard notBefore.isFinite, notBefore >= 0, timeout.isFinite, timeout >= 0 else {
            throw DeviceError("invalid fresh pointer frame deadline")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        guard deadline.isFinite else { throw DeviceError("invalid fresh pointer frame timeout") }
        condition.lock()
        defer { condition.unlock() }
        while true {
            guard !stopped else { throw DeviceError("USB capture stopped while waiting for a pointer frame") }
            if let latest, sequence.map({ latest.sequence > $0 }) ?? true, latest.receivedAt >= notBefore {
                return latest
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw DeviceError("timed out waiting for a fresh USB pointer frame") }
            // A notification may be spurious or contain an older frame. Recheck
            // both predicates against the original monotonic deadline.
            guard condition.wait(until: Date(timeIntervalSinceNow: remaining)) else {
                throw DeviceError("timed out waiting for a fresh USB pointer frame")
            }
        }
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }

    func resume() {
        condition.lock()
        stopped = false
        condition.unlock()
    }
}

/// A nominal AVFoundation acquisition source. Its UID is never rewritten by
/// screen identity verification, so ordinary device refreshes preserve remaps.
private final class ScreenCaptureSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private static let context = CIContext()

    /// The nominal capture device UID, independent of the pixels' physical phone.
    let id: String
    let name: String
    let instanceID = UUID()
    let device: AVCaptureDevice

    private let session = AVCaptureSession()
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()
    private let frames = ScreenCaptureFrameStore()

    init(device: AVCaptureDevice) throws {
        self.device = device
        id = device.uniqueID
        name = device.localizedName
        queue = DispatchQueue(label: "iphone-use.capture.\(device.uniqueID)")
        super.init()
        queue.setSpecific(key: queueKey, value: true)

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
        frames.stop()
        session.stopRunning()
    }

    func restart() {
        frames.stop()
        session.stopRunning()
        frames.resume()
        session.startRunning()
    }

    var size: CGSize? {
        frame().map { CGSize(width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0)) }
    }

    func frame() -> CVPixelBuffer? {
        frames.snapshot()?.buffer
    }

    func observationFrame() -> ScreenCaptureFrameStore.Snapshot? { frames.snapshot() }

    func pointerFrame(
        after sequence: UInt64?, notBefore: TimeInterval, timeout: TimeInterval
    ) throws -> VisualPointerFrame {
        guard DispatchQueue.getSpecific(key: queueKey) != true else {
            throw DeviceError("cannot wait for a pointer frame on the USB capture queue")
        }
        let snapshot = try frames.wait(after: sequence, notBefore: notBefore, timeout: timeout)
        let width = CVPixelBufferGetWidth(snapshot.buffer)
        let height = CVPixelBufferGetHeight(snapshot.buffer)
        guard (1...4096).contains(width), (1...4096).contains(height),
            let pixels = Self.grayscale(snapshot.buffer, width: width, height: height)
        else { throw DeviceError("cannot convert a full-size USB pointer frame") }
        return VisualPointerFrame(
            frame: PointerMotionObservation.Frame(width: width, height: height, pixels: pixels),
            sequence: snapshot.sequence, receivedAt: snapshot.receivedAt)
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
        return Self.grayscale(buffer, width: width, height: height)
    }

    /// Render outside the frame-state lock. Retaining the snapshot keeps this
    /// buffer alive even when capture publishes the next one during conversion.
    private static func grayscale(_ buffer: CVPixelBuffer, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0, !width.multipliedReportingOverflow(by: height).overflow else { return nil }
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
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frames.publish(buffer)
    }

    struct CaptureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
