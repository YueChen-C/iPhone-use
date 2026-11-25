import AVFoundation
import Darwin
import Foundation

/// A video-only export of one live capture stream. The capture callback never waits for the encoder.
final class ScreenVideoRecording {
    enum Failure: LocalizedError {
        case identityUnverified, noFrames, destinationBusy, encodingFailed

        var errorDescription: String? {
            let text = StringsWorkbench.current
            switch self {
            case .identityUnverified: return text.recordingIdentityUnverified
            case .noFrames: return text.recordingNoFrames
            case .destinationBusy: return text.recordingDestinationBusy
            case .encodingFailed: return text.recordingEncodingFailed
            }
        }
    }

    // The capture callback retains this immutable sample for the serial writer queue.
    private struct Frame: @unchecked Sendable {
        let sample: CMSampleBuffer
    }

    private static let activeLock = NSLock()
    private static var active: [URL: ScreenVideoRecording] = [:]
    private static let pendingWrites = DispatchGroup()

    private let destination: URL
    private let temporaryURL: URL
    private let size: CGSize
    private let completion: (Result<URL, Error>) -> Void
    private let queue = DispatchQueue(label: "iphone-use.video-recording", qos: .userInitiated)
    private let lock = NSLock()
    private var finishing = false
    private var framePending = false

    // Encoder state is confined to queue.
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var lastTime: CMTime?
    private var lastDuration = CMTime(value: 1, timescale: 30)

    var isFinishing: Bool { lock.withLock { finishing } }

    init(destination: URL, size: CGSize, completion: @escaping (Result<URL, Error>) -> Void) throws {
        let folder = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        self.destination = folder.appendingPathComponent(destination.lastPathComponent)
        temporaryURL = folder.appendingPathComponent(".iphone-use-\(UUID().uuidString).mp4")
        self.size = size
        self.completion = completion
        try Self.activeLock.withLock {
            guard Self.active[self.destination] == nil else { throw Failure.destinationBusy }
            Self.pendingWrites.enter()
            Self.active[self.destination] = self
        }
    }

    func offer(_ sample: CMSampleBuffer, buffer: CVPixelBuffer) {
        let frameSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        guard frameSize == size else {
            finish()
            return
        }
        lock.withLock {
            guard !finishing, !framePending else { return }
            framePending = true
            let frame = Frame(sample: sample)
            queue.async { [self] in
                defer { lock.withLock { framePending = false } }
                append(frame.sample)
            }
        }
    }

    func finish() {
        lock.withLock {
            guard !finishing else { return }
            finishing = true
            queue.async { [self] in finalize() }
        }
    }

    static func finishAll(waitTimeout: TimeInterval) -> Bool {
        let recordings = activeLock.withLock { Array(active.values) }
        recordings.forEach { $0.finish() }
        return pendingWrites.wait(timeout: .now() + waitTimeout) == .success
    }

    private func append(_ sample: CMSampleBuffer) {
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isNumeric, lastTime.map({ time > $0 }) ?? true else { return }
        do {
            if writer == nil { try startWriter(at: time) }
            guard let writer, let input else { throw Failure.encodingFailed }
            guard writer.status == .writing else { throw writer.error ?? Failure.encodingFailed }
            // Keep at most one queued frame. A slow disk or encoder can drop frames without stalling preview.
            guard input.isReadyForMoreMediaData else { return }
            guard input.append(sample) else { throw writer.error ?? Failure.encodingFailed }
            lastTime = time
            let duration = CMSampleBufferGetDuration(sample)
            if duration.isNumeric, duration > .zero { lastDuration = duration }
        } catch {
            fail(error)
        }
    }

    private func startWriter(at time: CMTime) throws {
        let writer = try AVAssetWriter(outputURL: temporaryURL, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                // H.264 uses 4:2:0 chroma. Fit any odd-sized source into even output dimensions.
                AVVideoWidthKey: Int(size.width) + Int(size.width) % 2,
                AVVideoHeightKey: Int(size.height) + Int(size.height) % 2,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw Failure.encodingFailed }
        writer.add(input)
        self.writer = writer
        self.input = input
        guard writer.startWriting() else { throw writer.error ?? Failure.encodingFailed }
        writer.startSession(atSourceTime: time)
    }

    private func finalize() {
        guard let writer, let input, let lastTime else {
            fail(Failure.noFrames)
            return
        }
        guard writer.status == .writing else {
            fail(writer.error ?? Failure.encodingFailed)
            return
        }
        writer.endSession(atSourceTime: lastTime + lastDuration)
        input.markAsFinished()
        writer.finishWriting { [self] in
            guard writer.status == .completed else {
                complete(.failure(writer.error ?? Failure.encodingFailed))
                return
            }
            // Same-directory rename publishes the completed file and preserves an existing file if encoding fails.
            let status = rename(temporaryURL.path, destination.path)
            if status == 0 {
                complete(.success(destination))
            } else {
                complete(.failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)))
            }
        }
    }

    private func fail(_ error: Error) {
        lock.withLock { finishing = true }
        if writer?.status == .writing { writer?.cancelWriting() }
        complete(.failure(error))
    }

    private func complete(_ result: Result<URL, Error>) {
        // An append failure can race a queued finish. Only one path releases the destination.
        let completed = Self.activeLock.withLock {
            guard Self.active[destination] === self else { return false }
            try? FileManager.default.removeItem(at: temporaryURL)
            Self.active.removeValue(forKey: destination)
            Self.pendingWrites.leave()
            return true
        }
        guard completed else { return }
        DispatchQueue.main.async { [completion] in completion(result) }
    }
}
