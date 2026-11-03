import Foundation

/// Session-local hover measurements for absolute-pointer hosts whose drags
/// still require relative reports. Nothing is pressed or persisted while fitting.
enum DragPointerCalibration {
    static func fit(six: Double, fourteen: Double) throws -> [Double] {
        let b = (fourteen / 14 - six / 6) / 8
        let a = six / 6 - 6 * b
        let curve = (0...8).map { n in Double(n) * (a + b * Double(n)) }
        guard six.isFinite, fourteen.isFinite, b >= 0, a >= -0.01,
            curve[1] >= 0.05, curve[8] < 200,
            zip(curve, curve.dropFirst()).allSatisfy({ $0 < $1 })
        else { throw DeviceError("drag calibration: unsupported acceleration curve; no drag sent") }
        return curve
    }

    static func measure(
        size: CGSize, position: (Double, Double) throws -> Void,
        send: (Int, Int) throws -> Void, capture: () throws -> PointerMotionObservation.Frame
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
                let offAxis = vertical ? abs(motion.delta.x) : abs(motion.delta.y)
                let measured = vertical ? motion.delta.y : motion.delta.x
                guard offAxis <= 2, measured > 0,
                    abs(motion.from.x - size.width * 0.18) <= 5,
                    abs(motion.from.y - size.height * row) <= 5
                else { continue }
                return measured / Double(reports)
            }
            throw DeviceError(
                "drag calibration: cannot observe count \(count) on \(vertical ? "y" : "x") axis; no drag sent")
        }
        let six = try sample(6, 40)
        let fourteen = try sample(14, 8)
        let curve = try fit(six: six, fourteen: fourteen)
        for vertical in [false, true] {
            let actual = try sample(8, 24, vertical: vertical)
            guard abs(actual - curve[8]) <= max(0.15, curve[8] * 0.08) else {
                throw DeviceError("drag calibration: validation disagrees with fitted curve; no drag sent")
            }
        }
        return curve
    }
}
