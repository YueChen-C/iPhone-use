import Foundation

/// Measured physical pixels per relative HID report. This compensates the host's
/// acceleration curve; it is an estimate, not feedback about the current pointer.
struct RelativePointerCalibration: Codable {
    let host: UUID
    /// Stable USB capture identity. Older profiles omit this field and may only
    /// be loaded for their original host until DeviceRegistry explicitly binds them.
    let screenID: String?
    let screenWidth: Int
    let screenHeight: Int
    let reportInterval: Double
    /// Index is the magnitude of a relative HID count; value is its measured
    /// pixel distance. Index zero is the stationary report.
    let distances: [Double]
    /// Enable combined-axis reports only after diagonal movements have been
    /// checked against this host's measured curve. Legacy profiles stay axial.
    enum VectorModel: String, Codable {
        /// iOS selects acceleration gain using the integer part of hypot(dx, dy).
        case radialQuantized
    }
    let vectorModel: VectorModel?

    init(
        host: UUID, screenWidth: Int, screenHeight: Int, reportInterval: Double,
        distances: [Double], screenID: String? = nil, vectorModel: VectorModel? = nil
    ) {
        self.host = host
        self.screenID = screenID
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.reportInterval = reportInterval
        self.distances = distances
        self.vectorModel = vectorModel
    }

    struct Movement {
        let dx: Int
        let dy: Int
    }

    func validate() throws {
        // Keep these checks ordered: the count/range checks make the indexed
        // values below safe, and the final bound limits homing report volume.
        guard screenWidth > 0, screenWidth <= 16384, screenHeight > 0, screenHeight <= 16384,
            reportInterval.isFinite, (0.01...0.1).contains(reportInterval),
            (2...128).contains(distances.count), distances.first == 0,
            distances.allSatisfy({ $0.isFinite && $0 >= 0 }),
            zip(distances, distances.dropFirst()).allSatisfy({ $0 < $1 }),
            distances[1] >= 0.05,
            ceil(Double(screenWidth) / distances.last!) + ceil(Double(screenHeight) / distances.last!) <= 512
        else { throw DeviceError("invalid relative pointer calibration") }
    }

    func matches(_ size: CGSize) -> Bool {
        size.width == Double(screenWidth) && size.height == Double(screenHeight)
    }

}

/// Pure motion planning. These methods predict landing positions from the
/// measured curve; sending reports and pacing them belongs to `DeviceInput`.
extension RelativePointerCalibration {
    /// Keep reports on one axis: the measured curve must not be applied to a
    /// diagonal vector with a different magnitude and hence different acceleration.
    func plan(from start: CGPoint, to target: CGPoint) -> (reports: [Movement], position: CGPoint) {
        var reports: [Movement] = []
        var position = start
        let targets = [
            max(0, min(Double(screenWidth - 1), target.x)),
            max(0, min(Double(screenHeight - 1), target.y)),
        ]
        for axis in 0...1 {
            var current = axis == 0 ? position.x : position.y
            // Use only moves that reduce the error. Retain the predicted landing
            // so sub-count errors do not accumulate on each window mouse event.
            for _ in 0..<4096 {
                let remaining = targets[axis] - current
                guard abs(remaining) >= distances[1] / 2 else { break }
                let count = (1..<distances.count).min {
                    abs(distances[$0] - abs(remaining)) < abs(distances[$1] - abs(remaining))
                }!
                let delta = (remaining < 0 ? -1.0 : 1.0) * distances[count]
                guard abs(remaining - delta) < abs(remaining) else { break }
                let value = remaining < 0 ? -count : count
                reports.append(Movement(dx: axis == 0 ? value : 0, dy: axis == 1 ? value : 0))
                current += delta
            }
            if axis == 0 {
                position.x = max(0, min(Double(screenWidth - 1), current))
            } else {
                position.y = max(0, min(Double(screenHeight - 1), current))
            }
        }
        return (reports, position)
    }

    /// One interruptible window movement. Unverified profiles alternate measured
    /// axes; verified vector profiles use the measured magnitude-based gain.
    func trackingStep(from start: CGPoint, to target: CGPoint, after previous: Movement?)
        -> (report: Movement, position: CGPoint)?
    {
        let target = CGPoint(
            x: max(0, min(Double(screenWidth - 1), target.x)),
            y: max(0, min(Double(screenHeight - 1), target.y)))
        if vectorModel == .radialQuantized { return radialTrackingStep(from: start, to: target) }
        let remaining = [target.x - start.x, target.y - start.y]
        let largestError = max(abs(remaining[0]), abs(remaining[1]))
        let tolerance = distances[1] / 2
        guard largestError > tolerance else { return nil }

        // Do not overshoot and then send a reverse correction. The final report
        // may round past the target by at most half the smallest measured step.
        let counts: [Int?] = remaining.map { error in
            guard abs(error) > tolerance else { return nil }
            let distance = min(abs(error), distances.last! * abs(error) / largestError)
            return (1..<distances.count).last { distances[$0] <= distance + tolerance }
        }
        let preferredAxis: Int
        if let previous {
            preferredAxis = previous.dx != 0 ? 1 : 0
        } else {
            preferredAxis = abs(remaining[0]) >= abs(remaining[1]) ? 0 : 1
        }
        for axis in [preferredAxis, 1 - preferredAxis] {
            guard let count = counts[axis] else { continue }
            let sign = remaining[axis] < 0 ? -1 : 1
            let report = Movement(
                dx: axis == 0 ? sign * count : 0,
                dy: axis == 1 ? sign * count : 0)
            var position = start
            let delta = Double(sign) * distances[count]
            if axis == 0 {
                position.x = max(0, min(Double(screenWidth - 1), start.x + delta))
            } else {
                position.y = max(0, min(Double(screenHeight - 1), start.y + delta))
            }
            return (report, position)
        }
        return nil
    }

    private func radialTrackingStep(from start: CGPoint, to target: CGPoint)
        -> (report: Movement, position: CGPoint)?
    {
        let remainingX = target.x - start.x
        let remainingY = target.y - start.y
        let tolerance = distances[1] / 2
        let epsilon = 1e-9
        guard max(abs(remainingX), abs(remainingY)) > tolerance + epsilon else { return nil }
        let remainingLength = hypot(remainingX, remainingY)
        let maxCount = distances.count - 1

        let candidates = radialCandidates(
            remainingX: remainingX, remainingY: remainingY,
            remainingLength: remainingLength, tolerance: tolerance, maxCount: maxCount)

        let signX = remainingX < 0 ? -1 : 1
        let signY = remainingY < 0 ? -1 : 1
        var bestError = remainingX * remainingX + remainingY * remainingY
        var best: (report: Movement, position: CGPoint)?
        for (x, y) in candidates {
            guard x == 0 || abs(remainingX) > tolerance + epsilon,
                y == 0 || abs(remainingY) > tolerance + epsilon
            else { continue }
            let magnitude = hypot(Double(x), Double(y))
            // Do not extrapolate beyond the measured acceleration curve even
            // when both components would individually fit a relative report.
            guard magnitude > 0, magnitude <= Double(maxCount) else { continue }
            // Repeated diagonal probes show that iOS truncates the vector's
            // magnitude before looking up gain, then scales each component.
            let count = Int(magnitude)
            let gain = distances[count] / Double(count)
            let deltaX = gain * Double(x)
            let deltaY = gain * Double(y)
            guard deltaX <= abs(remainingX) + tolerance + epsilon,
                deltaY <= abs(remainingY) + tolerance + epsilon
            else { continue }
            let position = CGPoint(
                x: max(0, min(Double(screenWidth - 1), start.x + Double(signX) * deltaX)),
                y: max(0, min(Double(screenHeight - 1), start.y + Double(signY) * deltaY)))
            let errorX = target.x - position.x
            let errorY = target.y - position.y
            let error = errorX * errorX + errorY * errorY
            guard error < bestError else { continue }
            bestError = error
            best = (Movement(dx: signX * x, dy: signY * y), position)
        }
        return best
    }

    /// Candidate order is significant: strict error improvement when scoring keeps
    /// the first candidate when two reports have identical predicted error.
    private func radialCandidates(
        remainingX: Double, remainingY: Double, remainingLength: Double,
        tolerance: Double, maxCount: Int
    ) -> [(Int, Int)] {
        // Invert the measured distance curve to seed nearby integral HID
        // candidates. Scoring uses the measured quantized gain, so this
        // interpolation never substitutes for the host's actual vector model.
        let requestedDistance = min(remainingLength, distances[maxCount])
        let upper = (1...maxCount).first { distances[$0] >= requestedDistance } ?? maxCount
        let lower = upper - 1
        let idealCount =
            Double(lower)
            + (requestedDistance - distances[lower]) / (distances[upper] - distances[lower])
        let idealX = idealCount * abs(remainingX) / remainingLength
        let idealY = idealCount * abs(remainingY) / remainingLength
        let centerX = Int(idealX.rounded())
        let centerY = Int(idealY.rounded())
        var candidates: [(Int, Int)] = []
        for x in max(0, centerX - 2)...min(maxCount, centerX + 2) {
            for y in max(0, centerY - 2)...min(maxCount, centerY + 2) {
                candidates.append((x, y))
            }
        }
        // A narrow direction may have no admissible diagonal lattice point.
        // Measured axis reports guarantee progress down to the final half step.
        if let count = (1...maxCount).last(where: { distances[$0] <= abs(remainingX) + tolerance }) {
            candidates.append((count, 0))
        }
        if let count = (1...maxCount).last(where: { distances[$0] <= abs(remainingY) + tolerance }) {
            candidates.append((0, count))
        }

        return candidates
    }

    var homingReports: [Movement] {
        let count = distances.count - 1
        let distance = distances[count]
        // Two extra reports cross the boundary despite small calibration error.
        return Array(repeating: Movement(dx: -count, dy: 0), count: Int(ceil(Double(screenWidth) / distance)) + 2)
            + Array(repeating: Movement(dx: 0, dy: -count), count: Int(ceil(Double(screenHeight) / distance)) + 2)
    }
}
