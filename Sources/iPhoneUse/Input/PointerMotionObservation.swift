import Foundation

/// Observes two separated circular pointers against a stationary background.
/// Bounding-box centers avoid the overlapping-crescent centroid bias of small
/// frame differences. Ambiguous, clipped, morphed or animated images fail closed.
enum PointerMotionObservation {
    struct Frame {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        var isValid: Bool {
            width > 0 && height > 0 && width <= 4096 && height <= 4096
                && pixels.count == width * height
        }
    }

    struct Motion {
        let from: CGPoint
        let to: CGPoint
        var delta: CGPoint { CGPoint(x: to.x - from.x, y: to.y - from.y) }
    }

    private struct Blob {
        let area: Int
        let bounds: CGRect
        var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

        var isPointer: Bool {
            let w = bounds.width
            let h = bounds.height
            return (8...100).contains(w) && (8...100).contains(h)
                && abs(w - h) <= 2 && Double(area) / (w * h) >= 0.6
        }
    }

    static func changedPixels(_ a: Frame, _ b: Frame) -> Int? {
        guard a.isValid, b.isValid, a.width == b.width, a.height == b.height else { return nil }
        return zip(a.pixels, b.pixels).reduce(0) { $0 + (abs(Int($1.0) - Int($1.1)) > 12 ? 1 : 0) }
    }

    static func motion(from a: Frame, to b: Frame, direction: CGPoint) -> Motion? {
        guard a.isValid, b.isValid, a.width == b.width, a.height == b.height,
            direction.x.isFinite, direction.y.isFinite, hypot(direction.x, direction.y) > 0
        else { return nil }
        let width = a.width
        let height = a.height
        var mask = zip(a.pixels, b.pixels).map { abs(Int($0.0) - Int($0.1)) > 12 }
        var blobs: [Blob] = []
        var noise = 0
        for index in mask.indices where mask[index] {
            mask[index] = false
            var stack = [index]
            var area = 0
            var minX = width
            var minY = height
            var maxX = 0
            var maxY = 0
            while let pixel = stack.popLast() {
                let x = pixel % width
                let y = pixel / width
                area += 1
                // Large changes cannot be a mouse pointer; bound work for video.
                guard area <= 10000 else { return nil }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
                for next in [
                    x > 0 ? pixel - 1 : -1, x + 1 < width ? pixel + 1 : -1,
                    y > 0 ? pixel - width : -1, y + 1 < height ? pixel + width : -1,
                ] where next >= 0 && mask[next] {
                    mask[next] = false
                    stack.append(next)
                }
            }
            // USB video can fluctuate along text edges. A narrow fragment
            // cannot be a supported disk, even when its length makes its area
            // exceed the small-fragment cutoff. Share one bounded noise budget.
            let blobWidth = maxX - minX + 1
            let blobHeight = maxY - minY + 1
            if area < 20 || min(blobWidth, blobHeight) < 8 {
                noise += area
                guard noise <= 256 else { return nil }
                continue
            }
            let bounds = CGRect(x: minX, y: minY, width: blobWidth, height: blobHeight)
            guard minX > 1, minY > 1, maxX < width - 2, maxY < height - 2 else { return nil }
            blobs.append(Blob(area: area, bounds: bounds))
            guard blobs.count <= 2 else { return nil }
        }
        guard blobs.count == 2, blobs.allSatisfy(\.isPointer),
            abs(blobs[0].bounds.width - blobs[1].bounds.width) <= 1,
            abs(blobs[0].bounds.height - blobs[1].bounds.height) <= 1,
            Double(min(blobs[0].area, blobs[1].area)) / Double(max(blobs[0].area, blobs[1].area)) >= 0.85,
            !blobs[0].bounds.insetBy(dx: -3, dy: -3).intersects(blobs[1].bounds.insetBy(dx: -3, dy: -3))
        else { return nil }
        let ordered = blobs.sorted {
            $0.center.x * direction.x + $0.center.y * direction.y
                < $1.center.x * direction.x + $1.center.y * direction.y
        }
        return Motion(from: ordered[0].center, to: ordered[1].center)
    }
}
