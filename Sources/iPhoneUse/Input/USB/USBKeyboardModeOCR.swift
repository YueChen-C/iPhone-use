import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Request-only detail pass over the same retained frame, not a capture hot path.
/// Small iOS space-key A/拼 legends can disappear in whole-screen recognition.
/// Restrict the fallback to a visible portrait QWERTY keyboard and exact legends.
enum USBKeyboardModeOCR {
    static func observe(
        _ data: Data, device: String, receivedAt: TimeInterval, includeCandidate: Bool = true,
        recognizeDetail: (CGImage, CGPoint) throws -> [ScreenOCR.Item] = recognize
    ) -> USBKeyboardObservation {
        let result = ScreenOCR.recognize(data, device: device)
        var markers: [ScreenOCR.Item] = []
        var candidates: [ScreenOCR.Item] = []
        if hasKeyboardRows(result),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let rect = CGRect(x: Double(image.width) * 0.25, y: Double(image.height) * 0.84,
                              width: Double(image.width) * 0.5, height: Double(image.height) * 0.08).integral
            if let crop = image.cropping(to: rect) {
                markers = (try? recognizeDetail(crop, rect.origin)) ?? []
            }
            let candidateRect = CGRect(x: 0, y: Double(image.height) * 0.605,
                                       width: Double(image.width) * 0.96, height: Double(image.height) * 0.055).integral
            if includeCandidate, mode(result, markers: markers) == .chinese,
               let crop = image.cropping(to: candidateRect) {
                candidates = (try? recognizeDetail(crop, candidateRect.origin)) ?? []
            }
        }
        return USBKeyboardObservation(result: result, receivedAt: receivedAt, mode: mode(result, markers: markers),
                                      firstCandidate: firstCandidate(result, items: candidates))
    }

    /// No substring/prefix guessing: a grouped candidate row is not one candidate.
    static func firstCandidate(_ result: ScreenOCR.Result, items: [ScreenOCR.Item]) -> String? {
        guard hasKeyboardRows(result) else { return nil }
        let left = items.filter {
            (0...0.20).contains(Double($0.x) / Double(result.width))
                && (0.61...0.66).contains(Double($0.y) / Double(result.height))
        }
        guard left.count == 1 else { return nil }
        let value = left[0].text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.allSatisfy { KeyboardMap.containsHanzi(String($0)) } ? value : nil
    }

    static func hasKeyboardRows(_ result: ScreenOCR.Result) -> Bool {
        guard result.width > 0, result.height > result.width else { return false }
        let rows: [(String, ClosedRange<Double>)] = [
            ("qwertyuiop", 0.66...0.725), ("asdfghjkl", 0.725...0.79), ("zxcvbnm", 0.79...0.845),
        ]
        return rows.allSatisfy { alphabet, band in
            var keys = Set<Character>()
            for item in result.items where item.x >= 0 && item.x < result.width
                && band.contains(Double(item.y) / Double(result.height)) {
                let value = item.text.lowercased().filter { $0.isASCII && $0.isLetter }
                if !value.isEmpty, alphabet.contains(value) {
                    keys.formUnion(value)
                } else if value.count == alphabet.count,
                          zip(value, alphabet).filter({ $0 != $1 }).count == 1 {
                    // Vision can merge a whole row and substitute one glyph
                    // (e.g. ASDFGHUKL). Only accept a full-length, ordered row
                    // with one substitution, not arbitrary letter overlap.
                    // This proves keyboard presence, never input mode.
                    keys.formUnion(alphabet)
                }
            }
            return keys.count >= 4
        }
    }

    static func mode(_ result: ScreenOCR.Result, markers: [ScreenOCR.Item]) -> USBKeyboardMode {
        let general = USBKeyboardMode.infer(result)
        guard hasKeyboardRows(result) else { return general }
        var ascii = false, chinese = false
        for item in markers {
            let x = Double(item.x) / Double(result.width), y = Double(item.y) / Double(result.height)
            guard (0.65...0.75).contains(x), (0.87...0.92).contains(y) else { continue }
            switch item.text.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "A": ascii = true
            case "拼": chinese = true
            default: break
            }
        }
        if ascii && (chinese || general == .chinese) { return .unknown }
        if chinese { return .chinese }
        if ascii { return .ascii }
        return general
    }

    private static func recognize(_ image: CGImage, origin: CGPoint) throws -> [ScreenOCR.Item] {
        let width = image.width * 4, height = image.height * 4
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let enlarged = context.makeImage() else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.005
        try VNImageRequestHandler(cgImage: enlarged).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let item = ScreenOCR.Item(text: text, box: observation.boundingBox, width: image.width, height: image.height)
            return .init(text: text, x: item.x + Int(origin.x), y: item.y + Int(origin.y))
        }
    }
}
