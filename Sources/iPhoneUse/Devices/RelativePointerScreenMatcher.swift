import Foundation

/// Identifies a relative mouse without assuming any pixel/count gain. Four
/// button-free movements trace a rectangle. The same local changed region must
/// arrive and depart at every corner, reversing its pixel changes. Unrelated
/// animation elsewhere on the screen is not part of that evidence.
enum RelativePointerScreenMatcher {
    static let width = 180
    static let height = 320

    static func matches(_ frames: [[UInt8]]) -> Bool {
        guard frames.count == 5, frames.allSatisfy({ $0.count == width * height }) else { return false }
        let edges = (0..<4).map { regions(frames[$0], frames[$0 + 1]) }
        // A busy screen is insufficient evidence; keep the path search bounded.
        guard edges.allSatisfy({ !$0.isEmpty && $0.count <= 64 }) else { return false }
        let corners = (0..<4).map { corner in
            edges[corner].flatMap { outgoing in
                edges[(corner + 3) % 4].compactMap { incoming -> Corner? in
                    guard outgoing.polarity == -incoming.polarity,
                        distance(outgoing.center, incoming.center) <= 2
                    else { return nil }
                    let common = outgoing.pixels.intersection(incoming.pixels)
                    guard common.count * 2 >= max(outgoing.pixels.count, incoming.pixels.count) else { return nil }
                    // Arrival and departure restore the local background. At
                    // the first corner the cursor itself must also return.
                    let before = corner == 0 ? 3 : corner - 1
                    let after = corner + 1
                    guard stable(common, frames[before], frames[after]),
                        corner != 0 || stable(common, frames[0], frames[4])
                    else { return nil }
                    return Corner(outgoing: outgoing, incoming: incoming)
                }
            }
        }
        guard corners.allSatisfy({ !$0.isEmpty && $0.count <= 64 }) else { return false }
        for a in corners[0] {
            for b in corners[1] where edge(a, b, dx: 1, dy: 0) {
                for c in corners[2] where edge(b, c, dx: 0, dy: 1) {
                    for d in corners[3]
                    where edge(c, d, dx: -1, dy: 0) && edge(d, a, dx: 0, dy: -1)
                        && abs((b.center.x - a.center.x) + (d.center.x - c.center.x)) <= 2
                        && abs((c.center.y - b.center.y) + (a.center.y - d.center.y)) <= 2
                    {
                        return true
                    }
                }
            }
        }
        return false
    }

    private struct Region {
        let pixels: Set<Int>
        let center: CGPoint
        let polarity: Int
    }

    private struct Corner {
        let outgoing: Region
        let incoming: Region
        var center: CGPoint {
            CGPoint(
                x: (outgoing.center.x + incoming.center.x) / 2,
                y: (outgoing.center.y + incoming.center.y) / 2)
        }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func stable(_ pixels: Set<Int>, _ a: [UInt8], _ b: [UInt8]) -> Bool {
        pixels.filter { abs(Int(a[$0]) - Int(b[$0])) <= 12 }.count * 4 >= pixels.count * 3
    }

    private static func edge(_ a: Corner, _ b: Corner, dx: Double, dy: Double) -> Bool {
        let x = b.center.x - a.center.x
        let y = b.center.y - a.center.y
        let sizes = (a.outgoing.pixels.count, b.incoming.pixels.count)
        return x * dx + y * dy >= 2 && abs(x * dy - y * dx) <= 2
            && min(sizes.0, sizes.1) * 2 >= max(sizes.0, sizes.1)
    }

    private static func regions(_ before: [UInt8], _ after: [UInt8]) -> [Region] {
        var changes = [Int8](repeating: 0, count: before.count)
        for i in before.indices {
            let delta = Int(after[i]) - Int(before[i])
            guard abs(delta) > 12 else { continue }
            changes[i] = delta > 0 ? 1 : -1
        }
        var result: [Region] = []
        for i in changes.indices where changes[i] != 0 {
            let polarity = changes[i]
            changes[i] = 0
            var pixels = [i]
            var cursor = 0
            while cursor < pixels.count {
                let pixel = pixels[cursor]
                cursor += 1
                for y in max(0, pixel / width - 1)...min(height - 1, pixel / width + 1) {
                    for x in max(0, pixel % width - 1)...min(width - 1, pixel % width + 1) {
                        let neighbor = y * width + x
                        if changes[neighbor] == polarity {
                            changes[neighbor] = 0
                            pixels.append(neighbor)
                        }
                    }
                }
            }
            guard (3...250).contains(pixels.count) else { continue }
            let center = CGPoint(
                x: Double(pixels.reduce(0) { $0 + $1 % width }) / Double(pixels.count),
                y: Double(pixels.reduce(0) { $0 + $1 / width }) / Double(pixels.count))
            guard pixels.allSatisfy({ hypot(Double($0 % width) - center.x, Double($0 / width) - center.y) <= 12 })
            else { continue }
            result.append(Region(pixels: Set(pixels), center: center, polarity: Int(polarity)))
        }
        return result
    }
}
