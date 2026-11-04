import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Vision

/// Best-effort, local recognition of the exact screenshot bytes supplied by the caller.
enum ScreenOCR {
    struct Item {
        let text: String
        let x: Int
        let y: Int

        init(text: String, box: CGRect, width: Int, height: Int) {
            self.text = text
            let minX = box.minX * Double(width)
            let minY = (1 - box.maxY) * Double(height)
            x = Int((minX + box.width * Double(width) / 2).rounded())
            y = Int((minY + box.height * Double(height) / 2).rounded())
        }

        init(text: String, x: Int, y: Int) {
            self.text = text
            self.x = x
            self.y = y
        }

        var json: [String: Any] { ["text": text, "x": x, "y": y] }
    }

    struct Result {
        let width: Int
        let height: Int
        let items: [Item]
        var screenHash: String = ""

        func json(device: String) -> [String: Any] {
            ["device": device, "width": width, "height": height, "items": items.map(\.json), "screenHash": screenHash]
        }

        var summary: String {
            "\nOCR (x,y): "
                + items.map { item in
                    let encoded = try? JSONSerialization.data(withJSONObject: item.text, options: [.fragmentsAllowed])
                    let quoted = encoded.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
                    return "\(quoted) (\(item.x),\(item.y))"
                }.joined(separator: " | ")
        }
    }

    static func decode(_ data: Data) -> Result? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let width = json["width"] as? Int, let height = json["height"] as? Int,
            width > 0, height > 0, let hash = json["screenHash"] as? String, !hash.isEmpty,
            let raw = json["items"] as? [[String: Any]]
        else { return nil }
        var items: [Item] = []
        for item in raw {
            guard let text = item["text"] as? String, let x = item["x"] as? Int, let y = item["y"] as? Int else {
                return nil
            }
            items.append(Item(text: text, x: x, y: y))
        }
        return Result(width: width, height: height, items: items, screenHash: hash)
    }

    static func sorted(_ items: [Item]) -> [Item] {
        items.sorted {
            if $0.y / 12 != $1.y / 12 { return $0.y / 12 < $1.y / 12 }
            if $0.x != $1.x { return $0.x < $1.x }
            if $0.y != $1.y { return $0.y < $1.y }
            return $0.text < $1.text
        }
    }

    private struct CacheKey: Equatable {
        let device: String
        let width: Int
        let height: Int
        let hash: String
    }

    private struct FrameSignature {
        let width: Int
        let height: Int
        let cells: [UInt8]
        let hash: String
    }

    private static let lock = NSLock()
    private static var cache: [(CacheKey, Result, [UInt8])] = []
    private static let maximumLumaDelta = 16
    private static let significantLumaDelta = 6
    private static let significantPixelRatio = 2000
    private static var recentSignatures: [FrameSignature] = []
    private static var previous: [String: Set<String>] = [:]

    struct Diff {
        let added: [String]
        let removed: [String]
        let unchanged: Bool
        let screenHash: String

        var summary: String {
            let changes = (added.map { "+" + $0 } + removed.map { "-" + $0 }).joined(separator: "\n")
            return "screenHash: \(screenHash) unchanged: \(unchanged)" + (changes.isEmpty ? "" : "\n" + changes)
        }
    }

    static func diff(device: String, current: Result) -> Diff {
        lock.lock()
        defer { lock.unlock() }
        let texts = Set(current.items.map(\.text))
        let old = previous[device]
        previous[device] = texts
        return Diff(
            added: texts.subtracting(old ?? []).sorted(), removed: (old ?? []).subtracting(texts).sorted(),
            unchanged: old == texts, screenHash: current.screenHash)
    }

    static func summaryDiff(for result: Result, device: String) -> String {
        diff(device: device, current: result).summary
    }

    /// Hash decoded pixels with a 2-level L-infinity tolerance on an 8x8 luminance grid
    /// so USB H.264/YUV LSB quantization noise does not invalidate a static screen.
    static func stabilitySignature(_ data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return "" }
        lock.lock()
        defer { lock.unlock() }
        return frameHashLocked(image)
    }

    /// SHA-256 of dimensions and every decoded 8-bit luminance pixel, without tolerance.
    static func screenHash(_ data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return "" }
        return content(image)?.hash ?? ""
    }

    private static func content(_ image: CGImage) -> (hash: String, luma: [UInt8])? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { return nil }
        let hash = SHA256.hash(data: Data("\(image.width)x\(image.height):".utf8) + Data(pixels)).map {
            String(format: "%02x", $0)
        }.joined()
        return (hash, pixels)
    }

    private static func canReuse(_ current: [UInt8], reference: [UInt8]) -> Bool {
        guard current.count == reference.count, !current.isEmpty else { return false }
        var significant = 0
        for (pixel, old) in zip(current, reference) {
            let delta = abs(Int(pixel) - Int(old))
            guard delta <= maximumLumaDelta else { return false }
            if delta > significantLumaDelta {
                significant += 1
                guard significant * significantPixelRatio <= current.count else { return false }
            }
        }
        return true
    }

    private static func frameHashLocked(_ image: CGImage) -> String {
        let sampleW = min(max(image.width, 1), 8)
        let sampleH = min(max(image.height, 1), 8)
        var cells = [UInt8](repeating: 0, count: sampleW * sampleH)
        let rendered = cells.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: sampleW, height: sampleH,
                    bitsPerComponent: 8, bytesPerRow: sampleW, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleW, height: sampleH))
            return true
        }
        guard rendered else { return "" }
        if let match = recentSignatures.last(where: { sig in
            sig.width == image.width && sig.height == image.height && sig.cells.count == cells.count
                && zip(sig.cells, cells).allSatisfy { abs(Int($0) - Int($1)) <= 2 }
        }) {
            return match.hash
        }
        let hash = SHA256.hash(data: Data("\(image.width)x\(image.height):".utf8) + Data(cells)).map {
            String(format: "%02x", $0)
        }.joined()
        recentSignatures.append(FrameSignature(width: image.width, height: image.height, cells: cells, hash: hash))
        if recentSignatures.count > 16 { recentSignatures.removeFirst() }
        return hash
    }

    static func recognize(
        _ data: Data, device: String = "", recognition: (CGImage) throws -> [Item] = detect
    ) -> Result {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return Result(width: 0, height: 0, items: []) }
        // Serialize recognition too: concurrent callers of the same frame share one Vision pass.
        lock.lock()
        defer { lock.unlock() }
        let pixels = content(image)
        let hash = pixels?.hash ?? ""
        let key = CacheKey(device: device, width: image.width, height: image.height, hash: hash)
        if !hash.isEmpty, let index = cache.firstIndex(where: { $0.0 == key }) {
            let hit = cache.remove(at: index)
            cache.append(hit)
            return hit.1
        }
        if let pixels,
            let hit = cache.last(where: {
                $0.0.device == device && $0.0.width == image.width && $0.0.height == image.height
                    && canReuse(pixels.luma, reference: $0.2)
            })
        {
            let result = Result(width: image.width, height: image.height, items: hit.1.items, screenHash: hash)
            // Keep the original recognized pixels as the reference: noise must not drift cumulatively.
            cache.append((key, result, hit.2))
            if cache.count > 8 { cache.removeFirst() }
            return result
        }
        do {
            let items = try recognition(image)
            let result = Result(width: image.width, height: image.height, items: sorted(items), screenHash: hash)
            if let pixels {
                cache.append((key, result, pixels.luma))
                if cache.count > 8 { cache.removeFirst() }
            }
            return result
        } catch {
            // A failed recognition is not a cacheable empty screen.
            return Result(width: image.width, height: image.height, items: [])
        }
    }
    private static func detect(_ image: CGImage) throws -> [Item] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation -> Item? in
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            return Item(text: text, box: observation.boundingBox, width: image.width, height: image.height)
        }
    }

}
