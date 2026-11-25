import AVFoundation
import XCTest

@testable import iPhoneUse

final class ScreenVideoRecordingTests: XCTestCase {
    func testStoppingAfterOneLiveSampleSavesPlayableVideo() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("capture.mp4")
        let previous = Data("previous file".utf8)
        try previous.write(to: destination)
        let saved = expectation(description: "finished writing")
        var result: Result<URL, Error>?
        let recorder = try ScreenVideoRecording(destination: destination, size: CGSize(width: 65, height: 97)) {
            result = $0
            saved.fulfill()
        }
        let (sample, buffer) = try makeSample(width: 65, height: 97)
        recorder.offer(sample, buffer: buffer)
        XCTAssertEqual(try Data(contentsOf: destination), previous)
        recorder.finish()
        recorder.finish()
        await fulfillment(of: [saved], timeout: 5)

        XCTAssertEqual(try result?.get().resolvingSymlinksInPath(), destination.resolvingSymlinksInPath())
        let movie = AVURLAsset(url: destination)
        let videoTracks = try await movie.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(videoTracks.first)
        let size = try await track.load(.naturalSize)
        let duration = try await movie.load(.duration)
        XCTAssertEqual(size, CGSize(width: 66, height: 98))
        XCTAssertGreaterThan(duration.seconds, 0)
        let reader = try AVAssetReader(asset: movie)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        XCTAssertNotNil(output.copyNextSampleBuffer())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["capture.mp4"])
    }

    func testMismatchedStreamEndsRecordingAndPreservesDestinationWithoutFrames() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("capture.mp4")
        let previous = Data("previous file".utf8)
        try previous.write(to: destination)
        let saved = expectation(description: "recording failed with no frames")
        let recorder = try ScreenVideoRecording(destination: destination, size: CGSize(width: 64, height: 96)) {
            defer { saved.fulfill() }
            guard case .failure(let error) = $0 else {
                XCTFail("A recording with no accepted frames must fail")
                return
            }
            XCTAssertEqual(error as? ScreenVideoRecording.Failure, .noFrames)
        }
        XCTAssertThrowsError(try ScreenVideoRecording(destination: destination, size: .zero) { _ in }) {
            XCTAssertEqual($0 as? ScreenVideoRecording.Failure, .destinationBusy)
        }
        let (sample, buffer) = try makeSample(width: 96, height: 64)
        recorder.offer(sample, buffer: buffer)
        await fulfillment(of: [saved], timeout: 5)
        XCTAssertTrue(recorder.isFinishing)
        XCTAssertEqual(try Data(contentsOf: destination), previous)
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private func makeSample(width: Int, height: Int) throws -> (CMSampleBuffer, CVPixelBuffer) {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let address = CVPixelBufferGetBaseAddress(buffer) { memset(address, 120, CVPixelBufferGetDataSize(buffer)) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: 9000, timescale: 30),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: nil, imageBuffer: buffer, formatDescription: try XCTUnwrap(format),
                sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return (try XCTUnwrap(sample), buffer)
    }
}
