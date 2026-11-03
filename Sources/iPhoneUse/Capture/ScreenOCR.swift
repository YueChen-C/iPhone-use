import CoreGraphics
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

        var json: [String: Any] { ["text": text, "x": x, "y": y] }
    }

    struct Result {
        let width: Int
        let height: Int
        let items: [Item]

        func json(device: String) -> [String: Any] {
            ["device": device, "width": width, "height": height, "items": items.map(\.json)]
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

    static func sorted(_ items: [Item]) -> [Item] {
        items.sorted {
            if $0.y / 12 != $1.y / 12 { return $0.y / 12 < $1.y / 12 }
            if $0.x != $1.x { return $0.x < $1.x }
            if $0.y != $1.y { return $0.y < $1.y }
            return $0.text < $1.text
        }
    }

    static func recognize(_ data: Data) -> Result {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return Result(width: 0, height: 0, items: []) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
            let items = (request.results ?? []).compactMap { observation -> Item? in
                guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
                return Item(text: text, box: observation.boundingBox, width: image.width, height: image.height)
            }
            return Result(width: image.width, height: image.height, items: sorted(items))
        } catch {
            // Recognition must never turn a successful screenshot into a failed tool call.
            return Result(width: image.width, height: image.height, items: [])
        }
    }
}
