import Foundation

/// Session-local hover measurements for absolute-pointer hosts whose drags
/// still require relative reports. Nothing is pressed or persisted while fitting.
enum DragPointerCalibration {
    static func fit(six: Double, fourteen: Double) throws -> [Double] {
        let b = (fourteen / 14 - six / 6) / 8
        let a = six / 6 - 6 * b
        let curve = (0...8).map { n in Double(n) * (max(0, a) + b * Double(n)) }
        guard six.isFinite, fourteen.isFinite, b >= 0, a >= -max(0.1, six * 0.02),
            curve[1] >= 0.05, curve[8] < 200,
            zip(curve, curve.dropFirst()).allSatisfy({ $0 < $1 })
        else { throw DeviceError("drag calibration: unsupported acceleration curve; no drag sent") }
        return curve
    }

    static func measure(
        size: CGSize, position: (Double, Double) throws -> Void,
        send: (Int, Int) throws -> Void, capture: () throws -> PointerMotionObservation.Frame,
        verticalScale: (Double) -> Void = { _ in }
    ) throws -> [Double] {
        func sample(_ count: Int, _ reports: Int, vertical: Bool = false) throws -> Double {
            // Re-send a different absolute coordinate first: iOS can ignore an
            // unchanged absolute report even after relative movement.
            for row in [0.35, 0.55, 0.70] {
                try position(0.1, 0.2)
                try position(0.18, row)
                let before = try capture()
                for _ in 0..<reports { try send(vertical ? 0 : count, vertical ? count : 0) }
                let after = try capture()
                guard
                    let motion = PointerMotionObservation.motion(
                        from: before, to: after, direction: CGPoint(x: vertical ? 0 : 1, y: vertical ? 1 : 0))
                else { continue }
                let sx = size.width / Double(before.width)
                let sy = size.height / Double(before.height)
                let offAxis = vertical ? abs(motion.delta.x) : abs(motion.delta.y)
                let measured = vertical ? motion.delta.y * sy : motion.delta.x * sx
                guard offAxis <= 2, measured > 0,
                    abs(motion.from.x - Double(before.width) * 0.18) <= 5,
                    abs(motion.from.y - Double(before.height) * row) <= 5
                else { continue }
                return measured / Double(reports)
            }
            throw DeviceError(
                "drag calibration: cannot observe count \(count) on \(vertical ? "y" : "x") axis; no drag sent")
        }
        // Start small enough for normal tracking sensitivity. Low-gain hosts
        // retry with a longer path; later counts use the measured gain.
        var first: Double?
        for reports in [8, 16, 32, 40] {
            do {
                first = try sample(6, reports)
                break
            } catch let error as DeviceInput.InputError { throw error } catch { continue }
        }
        guard let six = first else { throw DeviceError("drag calibration: no measurable initial motion; no drag sent") }
        // Normal tracking sensitivity is not quadratic near counts 1...5.
        // Measure the actual drag lookup table instead of extrapolating there.
        let target = min(size.width * 0.25, 100)
        func reports(_ gain: Double) -> Int { max(8, min(512, Int((target / gain).rounded()))) }
        var curve = [Double](repeating: 0, count: 9)
        curve[6] = six
        for count in 1...8 where count != 6 {
            curve[count] = try sample(count, reports(six * pow(Double(count) / 6, 1.5)))
        }
        guard curve[1] >= 0.05, curve[8] < 200,
            zip(curve, curve.dropFirst()).allSatisfy({ $0 < $1 })
        else {
            throw DeviceError("drag calibration: non-monotonic measured curve; no drag sent")
        }
        var verticalRatios: [Double] = []
        for count in [4, 8] {
            let actual = try sample(count, reports(curve[count]), vertical: true)
            verticalRatios.append(actual / curve[count])
            guard abs(actual - curve[count]) <= max(0.15, curve[count] * 0.05) else {
                throw DeviceError(
                    "drag calibration: y count \(count) actual=\(actual) expected=\(curve[count]); no drag sent")
            }
        }
        verticalScale(verticalRatios.reduce(0, +) / Double(verticalRatios.count))
        return curve
    }
}
