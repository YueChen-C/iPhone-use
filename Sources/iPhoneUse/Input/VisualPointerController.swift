import Foundation

/// A full-size USB frame. Both timestamps and `now` use the caller's clock.
struct VisualPointerFrame {
    let frame: PointerMotionObservation.Frame
    let sequence: UInt64
    let receivedAt: TimeInterval
}

/// The landing is observed; the gains are local estimates for later input.
/// They do not establish the accuracy of an unobserved drag trajectory.
struct VisualPointerLanding {
    let point: CGPoint
    let gainX: Double
    let gainY: Double
}

/// A single move owns its observations; no predicted position survives a call.
/// `capture` must drain preceding input and wait for a newer, settled USB frame.
final class VisualPointerController {
    enum Failure: Error, LocalizedError, CustomStringConvertible, Equatable {
        case invalidTarget, invalidFrame, staleFrame, timeout
        case probeFailed, causalityFailed, observationFailed, ambiguousObservation, noProgress, budgetExceeded

        var errorDescription: String? { description }

        var description: String {
            switch self {
            case .invalidTarget: return "Visual pointer target is outside the screen."
            case .invalidFrame: return "Visual pointer capture is not a full-size valid frame."
            case .staleFrame: return "Visual pointer capture is stale."
            case .timeout: return "Visual pointer movement exceeded its 30-second deadline."
            case .probeFailed: return "Visual pointer probes could not establish an absolute position."
            case .causalityFailed: return "Visual pointer candidate did not follow the reverse-axis input challenge."
            case .observationFailed: return "Visual pointer position is not observable against its reference frames."
            case .ambiguousObservation: return "Visual pointer reference observations disagree."
            case .noProgress: return "Visual pointer movement made no reliable progress."
            case .budgetExceeded: return "Visual pointer movement exhausted its bounded correction budget."
            }
        }
    }

    private let width: Int
    private let height: Int
    private let send: (Int, Int) throws -> Void
    private let capture: (UInt64?, TimeInterval) throws -> VisualPointerFrame
    private let now: () -> TimeInterval

    init(
        width: Int, height: Int,
        send: @escaping (Int, Int) throws -> Void,
        capture: @escaping (UInt64?, TimeInterval) throws -> VisualPointerFrame,
        now: @escaping () -> TimeInterval
    ) {
        self.width = width
        self.height = height
        self.send = send
        self.capture = capture
        self.now = now
    }

    func move(to target: CGPoint) throws -> CGPoint {
        try land(to: target).point
    }

    func land(to target: CGPoint) throws -> VisualPointerLanding {
        guard width > 0, height > 0, width <= 4096, height <= 4096,
            target.x.isFinite, target.y.isFinite,
            target.x >= 0, target.x < Double(width),
            target.y >= 0, target.y < Double(height)
        else { throw Failure.invalidTarget }
        let run = Run(controller: self)
        let point = try run.move(to: target)
        return VisualPointerLanding(point: point, gainX: run.gainX, gainY: run.gainY)
    }

    private struct Reference {
        let image: VisualPointerFrame
        let point: CGPoint
    }

    private struct Pair {
        let before: VisualPointerFrame
        let after: VisualPointerFrame
        let centers: [CGPoint]
    }

    private final class Run {
        let controller: VisualPointerController
        let startedAt: TimeInterval
        var lastSequence: UInt64?
        var references: [Reference] = []
        var reports = 0
        var gainX = 1.0
        var gainY = 1.0

        init(controller: VisualPointerController) {
            self.controller = controller
            startedAt = controller.now()
        }

        func checkDeadline() throws {
            let time = controller.now()
            guard startedAt.isFinite, time.isFinite,
                time >= startedAt, time - startedAt < 30
            else { throw Failure.timeout }
        }

        func freshFrame() throws -> VisualPointerFrame {
            try checkDeadline()
            let notBefore = controller.now()
            let image = try controller.capture(lastSequence, notBefore)
            try checkDeadline()
            guard image.receivedAt.isFinite, image.receivedAt >= notBefore,
                lastSequence.map({ image.sequence > $0 }) ?? true
            else { throw Failure.staleFrame }
            guard image.frame.isValid,
                image.frame.width == controller.width,
                image.frame.height == controller.height
            else { throw Failure.invalidFrame }
            lastSequence = image.sequence
            return image
        }

        func report(_ dx: Int, _ dy: Int) throws {
            try checkDeadline()
            // Covers bootstrap and all coarse reports, not just successful rounds.
            guard reports < 304 else { throw Failure.budgetExceeded }
            reports += 1
            try controller.send(dx, dy)
            try checkDeadline()
        }

        func pair(_ before: VisualPointerFrame, _ after: VisualPointerFrame) -> Pair? {
            guard
                let motion = PointerMotionObservation.motion(
                    from: before.frame, to: after.frame, direction: CGPoint(x: 1, y: 0)
                )
            else { return nil }
            // Direction only sorts these two centers. It does NOT identify time.
            return Pair(before: before, after: after, centers: [motion.from, motion.to])
        }

        func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
            hypot(a.x - b.x, a.y - b.y)
        }

        func retain(_ reference: Reference) {
            let candidates = references + [reference]
            guard candidates.count > 2 else {
                references = candidates
                return
            }
            var best = (0, 1)
            var separation = -Double.infinity
            // Prefer widely separated anchors (150 px or more when available).
            // Separation is not a promise that a large/morphed pointer is visible.
            for i in candidates.indices {
                for j in candidates.indices where j > i {
                    let d = distance(candidates[i].point, candidates[j].point)
                    if d > separation {
                        separation = d
                        best = (i, j)
                    }
                }
            }
            references = [candidates[best.0], candidates[best.1]]
        }

        func bootstrap() throws -> Reference {
            var before = try freshFrame()
            // Three same-direction moves allow an initially clipped pointer to
            // enter the interior before the two usable frame differences.
            for count in [16, 32, 64, 127] {
                // The highest tier also searches beyond a wide unobservable
                // edge/UI region. Short symmetric excursions can otherwise
                // return before any three usable frames have been captured.
                // This still shares the move's report and time budgets.
                let attempts = count == 127 ? 8 : 3
                for direction in [(1, 1), (-1, -1), (1, -1), (-1, 1)] {
                    var previous: Pair?
                    for _ in 0..<attempts {
                        try report(direction.0 * count, direction.1 * count)
                        let after = try freshFrame()
                        let current = pair(before, after)
                        if let a = previous, let b = current {
                            var matches: [(Int, Int)] = []
                            for i in 0..<2 {
                                for j in 0..<2 where distance(a.centers[i], b.centers[j]) <= 2 {
                                    matches.append((i, j))
                                }
                            }
                            // A→B and B→C must have exactly one common center B.
                            // A return to A, animation, clipping or overlap cannot
                            // establish an absolute pointer location.
                            if matches.count == 1 {
                                let match = matches[0]
                                let pointB = b.centers[match.1]
                                let pointC = b.centers[1 - match.1]
                                let dx = pointC.x - pointB.x
                                let dy = pointC.y - pointB.y
                                let gx = abs(dx) / Double(count)
                                let gy = abs(dy) / Double(count)
                                if dx * Double(direction.0) > 2, dy * Double(direction.1) > 2 {
                                    gainX = gx
                                    gainY = gy
                                    retain(Reference(image: a.before, point: a.centers[1 - match.0]))
                                    retain(Reference(image: b.before, point: pointB))
                                    let result = Reference(image: after, point: pointC)
                                    retain(result)
                                    try checkDeadline()
                                    return try challenge(result, count: count, direction: direction)
                                }
                            }
                        }
                        before = after
                        previous = current
                    }
                }
            }
            try checkDeadline()
            throw Failure.probeFailed
        }

        func observe(_ image: VisualPointerFrame) throws -> Reference {
            try checkDeadline()
            var points: [CGPoint] = []
            for reference in references {
                guard let changes = pair(reference.image, image) else { continue }
                let matches = changes.centers.indices.filter {
                    distance(changes.centers[$0], reference.point) <= 2
                }
                guard matches.count == 1 else { continue }
                points.append(changes.centers[1 - matches[0]])
            }
            guard let point = points.first else { throw Failure.observationFailed }
            guard points.allSatisfy({ distance($0, point) <= 2 }) else { throw Failure.ambiguousObservation }
            let result = Reference(image: image, point: point)
            retain(result)
            try checkDeadline()
            return result
        }

        func challenge(_ candidate: Reference, count: Int, direction: (Int, Int)) throws -> Reference {
            // A moving circular UI element can produce exactly the same two
            // blobs as a pointer. Require a causal response to two independently
            // reversed axes before trusting the candidate, even if it is already
            // at the target. Do not label the observed centers using direction.
            try report(-direction.0 * count, 0)
            let horizontal = try observe(freshFrame())
            let dx = horizontal.point.x - candidate.point.x
            guard dx * Double(-direction.0) > 2,
                abs(horizontal.point.y - candidate.point.y) <= 2
            else {
                throw Failure.causalityFailed
            }
            gainX = abs(dx) / Double(count)

            try report(0, -direction.1 * count)
            let vertical = try observe(freshFrame())
            let dy = vertical.point.y - horizontal.point.y
            guard dy * Double(-direction.1) > 2,
                abs(vertical.point.x - horizontal.point.x) <= 2
            else {
                throw Failure.causalityFailed
            }
            gainY = abs(dy) / Double(count)
            return vertical
        }

        func confirmed(_ current: Reference, target: CGPoint) throws -> CGPoint? {
            // Bounding-box centers include pixel quantization. Leave margin
            // inside the real 5 px acceptance boundary rather than consuming it.
            guard distance(current.point, target) <= 3 else { return nil }
            let later = try observe(freshFrame())
            guard distance(later.point, target) <= 3,
                distance(later.point, current.point) <= 2
            else { throw Failure.noProgress }
            return later.point
        }

        func move(to target: CGPoint) throws -> CGPoint {
            var current = try bootstrap()
            if let point = try confirmed(current, target: target) { return point }
            var stalled = 0
            for _ in 0..<16 {
                try checkDeadline()
                let errorX = target.x - current.point.x
                let errorY = target.y - current.point.y
                let horizontal = abs(errorX) >= abs(errorY)
                let error = horizontal ? errorX : errorY
                let gain = horizontal ? gainX : gainY
                // Only the measured delta updates gain. The estimate determines
                // input size, never the asserted position or completion result.
                let wanted = max(1, min(2032, Int((abs(error) * 0.65 / gain).rounded())))
                let sign = error < 0 ? -1 : 1
                var remaining = wanted
                while remaining > 0 {
                    let count = min(127, remaining)
                    try report(horizontal ? sign * count : 0, horizontal ? 0 : sign * count)
                    remaining -= count
                }
                let next = try observe(freshFrame())
                let dx = next.point.x - current.point.x
                let dy = next.point.y - current.point.y
                let actual = horizontal ? dx : dy
                let crossAxis = horizontal ? dy : dx
                guard actual * Double(sign) >= -2, abs(crossAxis) <= 2 else { throw Failure.noProgress }
                if abs(actual) < 0.5 {
                    stalled += 1
                    guard stalled < 3 else { throw Failure.noProgress }
                } else {
                    stalled = 0
                    let measuredGain = abs(actual) / Double(wanted)
                    if horizontal { gainX = measuredGain } else { gainY = measuredGain }
                }
                current = next
                if let point = try confirmed(current, target: target) { return point }
            }
            throw Failure.budgetExceeded
        }
    }
}
