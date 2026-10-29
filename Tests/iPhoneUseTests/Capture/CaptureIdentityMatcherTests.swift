import CoreGraphics
import XCTest

@testable import iPhoneUse

final class CaptureIdentityMatcherTests: XCTestCase {
    private func signature(inverted: Bool = false, noise: Int = 0) -> CaptureIdentityImage {
        let pixels = (0..<(CaptureIdentityImage.width * CaptureIdentityImage.height)).flatMap { index in
            let bright =
                ((index / CaptureIdentityImage.width) / 5 + index % CaptureIdentityImage.width / 4)
                .isMultiple(of: 2) != inverted
            return [UInt8](repeating: UInt8((bright ? 210 : 40) + noise), count: 3)
        }
        return CaptureIdentityImage(aspectRatio: 750.0 / 1334, pixels: pixels)
    }

    func testCorrectsCrossedSourcesForPhonesWithTheSameResolution() {
        let home = signature()
        let maps = signature(inverted: true)
        XCTAssertEqual(
            CaptureIdentityMatcher.match(
                physical: ["se": maps, "iphone7": home], sources: ["se": home, "iphone7": maps]),
            ["se": "iphone7", "iphone7": "se"])
    }

    func testPreservesAnAlreadyCorrectMappingWithSmallCaptureNoise() {
        XCTAssertEqual(
            CaptureIdentityMatcher.match(
                physical: ["se": signature(noise: 6), "iphone7": signature(inverted: true, noise: -5)],
                sources: ["se": signature(), "iphone7": signature(inverted: true)]),
            ["se": "se", "iphone7": "iphone7"])
    }

    func testIdenticalAndNearlyIdenticalScreensCannotProveIdentity() {
        for second in [signature(), signature(noise: 4)] {
            XCTAssertNil(
                CaptureIdentityMatcher.match(
                    physical: ["se": signature(), "iphone7": second],
                    sources: ["se": signature(), "iphone7": second]))
        }
    }

    func testBlackOrSolidFramesCannotIdentifyADevice() {
        for value: UInt8 in [0, 110, 255] {
            let solid = CaptureIdentityImage(
                aspectRatio: 750.0 / 1334,
                pixels: [UInt8](repeating: value, count: CaptureIdentityImage.width * CaptureIdentityImage.height * 3))
            XCTAssertNil(CaptureIdentityMatcher.match(physical: ["se": solid], sources: ["se": solid]))
        }
    }

    func testIncompleteAndNonBijectionMappingsAreRejected() {
        XCTAssertNil(
            CaptureIdentityMatcher.match(
                physical: ["se": signature(), "iphone7": signature(inverted: true)],
                sources: ["se": signature()]))
        XCTAssertNil(
            CaptureIdentityMatcher.match(
                physical: ["se": signature(), "iphone7": signature(noise: 3)],
                sources: ["se": signature(), "iphone7": signature(inverted: true)]))
    }

    func testDifferentAspectRatiosAndUnrelatedContentAreRejected() {
        let rotated = CaptureIdentityImage(aspectRatio: 1334.0 / 750, pixels: signature().pixels)
        XCTAssertNil(CaptureIdentityMatcher.match(physical: ["se": rotated], sources: ["se": signature()]))
        XCTAssertNil(
            CaptureIdentityMatcher.match(
                physical: ["se": signature()], sources: ["se": signature(inverted: true)]))
    }

    func testQuickTimeStatusBarReplacementDoesNotChangeIdentity() throws {
        let width = 120
        let height = 200
        func image(status: UInt8) throws -> CGImage {
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let value: UInt8 = y < 14 ? status : ((x / 12 + y / 16).isMultiple(of: 2) ? 220 : 30)
                    let offset = (y * width + x) * 4
                    pixels[offset] = value
                    pixels[offset + 1] = value
                    pixels[offset + 2] = value
                }
            }
            let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
            return try XCTUnwrap(
                CGImage(
                    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        }
        let physical = try XCTUnwrap(CaptureIdentityImage(image: image(status: 0)))
        let capture = try XCTUnwrap(CaptureIdentityImage(image: image(status: 255)))
        XCTAssertTrue(physical.isInformative)
        XCTAssertEqual(try XCTUnwrap(physical.distance(to: capture)), 0, accuracy: 0.0001)
    }

    func testMissingScreenshotServiceCanBeResolvedByOneRemainingSource() {
        XCTAssertEqual(
            CaptureIdentityMatcher.verifiedMappings(
                physicalIDs: ["se", "new"], physical: ["se": signature()],
                sources: ["se": signature(inverted: true), "new": signature()], unavailable: ["new"]),
            ["se": "new", "new": "se"])
    }

    func testSparseSettingsScreenCanOnlyBeInferredAfterTheOtherPhoneIsProven() {
        var pixels = [UInt8](repeating: 245, count: CaptureIdentityImage.width * CaptureIdentityImage.height * 3)
        for i in 0..<(40 * 3) { pixels[i] = 180 }
        let settings = CaptureIdentityImage(aspectRatio: 1170.0 / 2532, pixels: pixels)
        XCTAssertFalse(settings.isInformative, "sparse text cannot independently identify the phone")
        XCTAssertTrue(settings.hasVisibleContent)
        XCTAssertNil(CaptureIdentityMatcher.match(physical: ["new": settings], sources: ["new": settings]))
        XCTAssertEqual(
            CaptureIdentityMatcher.verifiedMappings(
                physicalIDs: ["se", "new"], physical: ["se": signature()],
                sources: ["se": settings, "new": signature()], unavailable: ["new"]),
            ["se": "new", "new": "se"])
        XCTAssertEqual(
            CaptureIdentityMatcher.verifiedMappings(
                physicalIDs: ["se", "new"], physical: [:],
                sources: ["se": settings, "new": signature()], unavailable: ["se", "new"]), [:])
    }

    func testEliminationStillRejectsBlankFramesAndIsolatedCaptureNoise() {
        for value: UInt8 in [0, 110, 245, 255] {
            var pixels = [UInt8](repeating: value, count: CaptureIdentityImage.width * CaptureIdentityImage.height * 3)
            for i in 0..<18 { pixels[i] = value > 128 ? 0 : 255 }
            let blank = CaptureIdentityImage(aspectRatio: 1170.0 / 2532, pixels: pixels)
            XCTAssertFalse(blank.hasVisibleContent)
            XCTAssertEqual(
                CaptureIdentityMatcher.verifiedMappings(
                    physicalIDs: ["se", "new"], physical: ["se": signature()],
                    sources: ["se": signature(), "new": blank], unavailable: ["new"]), ["se": "se"])
        }
    }

    func testFailedOrContradictoryScreenshotCannotBeInferredByElimination() {
        for physical in [["se": signature()], ["se": signature(), "new": signature()]] {
            let mapping = CaptureIdentityMatcher.verifiedMappings(
                physicalIDs: ["se", "new"], physical: physical,
                sources: ["se": signature(), "new": signature(inverted: true)], unavailable: [])
            XCTAssertNil(mapping["new"])
        }
    }

    func testAmbiguousSourcesCannotBeResolvedUsingMissingScreenshotService() {
        XCTAssertEqual(
            CaptureIdentityMatcher.verifiedMappings(
                physicalIDs: ["se", "new"], physical: ["se": signature()],
                sources: ["se": signature(), "new": signature()], unavailable: ["new"]), [:])
    }

    func testSeveralUnavailablePhonesDoNotBlockTheIndependentlyVerifiedPhone() {
        let other = CaptureIdentityImage(aspectRatio: 1.1, pixels: signature().pixels)
        XCTAssertEqual(
            CaptureIdentityMatcher.verifiedMappings(
                physicalIDs: ["se", "new1", "new2"], physical: ["se": signature()],
                sources: ["se": signature(), "new1": signature(inverted: true), "new2": other],
                unavailable: ["new1", "new2"]), ["se": "se"])
    }

    func testPartialIdentityStateOnlyPermitsVerifiedScreens() {
        XCTAssertTrue(ScreenCaptureIdentityState.partiallyVerified.permitsAssociation(identityVerified: true))
        XCTAssertFalse(ScreenCaptureIdentityState.partiallyVerified.permitsAssociation(identityVerified: false))
        for state in [ScreenCaptureIdentityState.pending, .failed] {
            XCTAssertFalse(state.permitsAssociation(identityVerified: true))
            XCTAssertFalse(state.permitsAssociation(identityVerified: false))
        }
    }
}
