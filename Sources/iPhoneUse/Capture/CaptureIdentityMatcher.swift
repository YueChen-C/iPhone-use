import CoreGraphics
import Foundation

/// A small color signature of the screen interior. QuickTime replaces the status
/// bar, so that area must not participate in USB screenshot comparisons.
struct CaptureIdentityImage {
    static let width = 24
    static let height = 40

    let aspectRatio: Double
    let pixels: [UInt8]

    init(aspectRatio: Double, pixels: [UInt8]) {
        self.aspectRatio = aspectRatio
        self.pixels = pixels
    }

    init?(image: CGImage) {
        guard image.width > 0, image.height > 0 else { return nil }
        aspectRatio = Double(image.width) / Double(image.height)
        let inset = Int(Double(image.height) * 0.08)
        guard
            let interior = image.cropping(
                to: CGRect(
                    x: 0, y: inset, width: image.width, height: image.height - 2 * inset))
        else { return nil }
        var rgba = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard
                let context = CGContext(
                    data: bytes.baseAddress, width: Self.width, height: Self.height,
                    bitsPerComponent: 8, bytesPerRow: Self.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(interior, in: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
            return true
        }
        guard drawn else { return nil }
        pixels = stride(from: 0, to: rgba.count, by: 4).flatMap { offset in
            Array(rgba[offset..<(offset + 3)])
        }
    }

    var isInformative: Bool {
        guard pixels.count == Self.width * Self.height * 3 else { return false }
        // Solid colors, black frames and almost empty screens cannot identify a
        // phone. Require spatial detail, not just a different average color.
        let luminances = stride(from: 0, to: pixels.count, by: 3).map { offset in
            (Double(pixels[offset]) + Double(pixels[offset + 1]) + Double(pixels[offset + 2])) / 3
        }
        let mean = luminances.reduce(0, +) / Double(luminances.count)
        return luminances.reduce(0) { $0 + abs($1 - mean) } / Double(luminances.count) >= 6
    }

    /// The final source in a proven bijection need not identify a phone on its
    /// own. Sparse Settings text is usable for elimination, while a blank,
    /// black, or nearly uniform frame must still wait for visible content.
    var hasVisibleContent: Bool {
        guard pixels.count == Self.width * Self.height * 3,
            aspectRatio.isFinite, aspectRatio > 0
        else { return false }
        let luminances = stride(from: 0, to: pixels.count, by: 3).map { offset in
            (Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])) / 3
        }.sorted()
        let inset = luminances.count / 50
        return luminances[luminances.count - 1 - inset] - luminances[inset] >= 12
    }

    func distance(to other: Self) -> Double? {
        guard pixels.count == other.pixels.count, !pixels.isEmpty,
            abs(aspectRatio - other.aspectRatio) <= 0.03
        else { return nil }
        return zip(pixels, other.pixels).reduce(0) { $0 + abs(Double($1.0) - Double($1.1)) }
            / Double(pixels.count) / 255
    }
}

enum CaptureIdentityMatcher {
    /// Keep independently proven screens usable when another phone cannot
    /// provide screenshots. Only a single explicitly unavailable phone can be
    /// identified by elimination; failed or ambiguous images are never inferred.
    static func verifiedMappings(
        physicalIDs: Set<String>, physical: [String: CaptureIdentityImage],
        sources: [String: CaptureIdentityImage], unavailable: Set<String>
    ) -> [String: String] {
        guard !sources.isEmpty, Set(sources.keys).isSubset(of: physicalIDs),
            Set(physical.keys).isSubset(of: physicalIDs), unavailable.isSubset(of: physicalIDs),
            Set(physical.keys).isDisjoint(with: unavailable)
        else { return [:] }
        var candidates: [String: String] = [:]
        for (id, image) in physical where image.isInformative {
            let scores = sources.compactMap { sourceID, candidate -> (String, Double)? in
                guard candidate.isInformative else { return nil }
                return image.distance(to: candidate).map { (sourceID, $0) }
            }.sorted { $0.1 < $1.1 }
            guard let best = scores.first, best.1 <= 0.10,
                scores.count == 1 || scores[1].1 - best.1 >= 0.04
            else { continue }
            candidates[id] = best.0
        }
        var mapping = candidates.filter { entry in
            candidates.values.filter { $0 == entry.value }.count == 1
        }
        let remainingPhysical = physicalIDs.subtracting(mapping.keys)
        let remainingSources = Set(sources.keys).subtracting(mapping.values)
        if !mapping.isEmpty, remainingPhysical.count == 1, remainingSources.count == 1,
            let id = remainingPhysical.first, unavailable.contains(id),
            let source = remainingSources.first, sources[source]?.hasVisibleContent == true
        {
            mapping[id] = source
        }
        return mapping
    }

    /// Return physical USB UID -> capture source UID only if every phone has a
    /// close, clearly distinct match and all winners form a bijection.
    static func match(
        physical: [String: CaptureIdentityImage], sources: [String: CaptureIdentityImage]
    ) -> [String: String]? {
        guard !physical.isEmpty, Set(physical.keys) == Set(sources.keys),
            physical.values.allSatisfy(\.isInformative), sources.values.allSatisfy(\.isInformative)
        else { return nil }
        var mapping: [String: String] = [:]
        for (id, image) in physical {
            let scores = sources.compactMap { sourceID, candidate -> (String, Double)? in
                image.distance(to: candidate).map { (sourceID, $0) }
            }.sorted { $0.1 < $1.1 }
            guard let best = scores.first, best.1 <= 0.10,
                scores.count == 1 || scores[1].1 - best.1 >= 0.04
            else { return nil }
            mapping[id] = best.0
        }
        guard Set(mapping.values).count == physical.count else { return nil }
        return mapping
    }
}
