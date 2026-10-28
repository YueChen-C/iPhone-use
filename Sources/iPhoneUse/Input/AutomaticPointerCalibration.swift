import Foundation

/// First-use adaptation using USB frames only. It sends button-free reports,
/// checks forward/reverse motion, then verifies actual target landings before
/// returning a profile. Persistence and session ownership belong to the caller.
final class AutomaticPointerCalibration {
    typealias Frame = PointerMotionObservation.Frame
    private let host: UUID
    private let screenID: String
    private let width: Int
    private let height: Int
    private let send: (Int, Int) throws -> Void
    private let capture: () throws -> Frame
    private let progress: (Int) -> Void
    private var position: CGPoint?

    init(
        host: UUID, screenID: String, width: Int, height: Int,
        send: @escaping (Int, Int) throws -> Void, capture: @escaping () throws -> Frame,
        progress: @escaping (Int) -> Void = { _ in }
    ) {
        self.host = host
        self.screenID = screenID
        self.width = width
        self.height = height
        self.send = send
        self.capture = capture
        self.progress = progress
    }

    func measure() throws -> RelativePointerCalibration {
        guard (200...4096).contains(width), (300...4096).contains(height), !screenID.isEmpty else {
            throw DeviceError("automatic pointer calibration requires a full-size USB frame")
        }
        // Leave either horizontal boundary and wake a hidden pointer. Subsequent
        // observations, rather than a default curve, establish its position.
        try burst(-127, 0, reports: 16)
        try burst(8, 0, reports: 8)
        var initial: Double?
        for reports in [8, 4, 2, 1, 16, 32] {
            if let sample = try sample(count: 8, axis: 0, reports: reports) {
                initial = sample
                break
            }
        }
        guard let initial, initial > 0, let start = position else { throw unavailable("initial pointer observation") }
        // Keep the measuring area away from screen edges and browser chrome.
        let anchor = CGPoint(x: Double(width) * 0.25, y: Double(height) * 0.5)
        for axis in 0...1 {
            let difference = axis == 0 ? anchor.x - start.x : anchor.y - start.y
            let reports = Int((abs(difference) / initial).rounded())
            guard reports <= 256 else { throw unavailable() }
            try burst(
                axis == 0 ? (difference < 0 ? -8 : 8) : 0,
                axis == 1 ? (difference < 0 ? -8 : 8) : 0, reports: reports)
        }
        guard try sample(count: 8, axis: 0, reports: max(1, Int(ceil(64 / initial)))) != nil,
            let located = position, located.x > 55, located.x < Double(width) * 0.55,
            located.y > 55, located.y < Double(height) - 180
        else { throw unavailable("sampling area observation") }

        var distances = [0.0]
        for count in 1...32 {
            let estimate = count == 1 ? initial / 8 : distances[count - 1]
            var reports = max(1, min(256, Int(ceil(64 / max(estimate, 0.25)))))
            var measured: Double?
            while reports <= 256 {
                measured = try sample(count: count, axis: 0, reports: reports)
                if measured != nil { break }
                if reports == 256 { break }
                reports = min(256, reports * 2)
            }
            guard let measured, measured > distances.last!, measured.isFinite else {
                throw unavailable("horizontal count \(count)")
            }
            distances.append(measured)
            progress(count)
        }
        // A horizontal curve alone does not establish vertical equivalence.
        for count in [4, 16, 32] {
            guard
                let vertical = try sample(
                    count: count, axis: 1, reports: max(1, Int(ceil(64 / distances[count])))),
                abs(vertical - distances[count]) <= max(0.5, distances[count] * 0.02)
            else { throw unavailable("vertical count \(count)") }
        }
        // Deliberately keep single-axis planning: native observations have not
        // established the host's diagonal acceleration model.
        let profile = RelativePointerCalibration(
            host: host, screenWidth: width, screenHeight: height, reportInterval: 0.03,
            distances: distances, screenID: screenID)
        try profile.validate()
        try verify(profile)
        return profile
    }

    private func burst(_ dx: Int, _ dy: Int, reports: Int) throws {
        for _ in 0..<reports { try send(dx, dy) }
    }

    private func frame() throws -> Frame {
        let result = try capture()
        guard result.isValid, result.width == width, result.height == height else { throw unavailable() }
        return result
    }

    private func sample(count: Int, axis: Int, reports: Int) throws -> Double? {
        let before = try frame()
        let direction = CGPoint(x: axis == 0 ? 1 : 0, y: axis == 1 ? 1 : 0)
        try burst(axis == 0 ? count : 0, axis == 1 ? count : 0, reports: reports)
        let after = try frame()
        try burst(axis == 0 ? -count : 0, axis == 1 ? -count : 0, reports: reports)
        let returned = try frame()
        // A clipped burst cannot be retried from a now-incorrect origin.
        guard let changes = PointerMotionObservation.changedPixels(before, returned) else {
            throw unavailable("invalid return frame at count \(count), axis \(axis), reports \(reports)")
        }
        guard changes <= 256 else {
            throw unavailable(
                "screen changed in \(changes) pixels after count \(count), axis \(axis), reports \(reports)")
        }
        guard let forward = PointerMotionObservation.motion(from: before, to: after, direction: direction),
            let reverse = PointerMotionObservation.motion(
                from: after, to: returned, direction: CGPoint(x: -direction.x, y: -direction.y))
        else { return nil }  // Small overlapping pointers need a longer burst.
        guard distance(forward.from, reverse.to) <= 2, distance(forward.to, reverse.from) <= 1,
            axis == 0 ? abs(forward.delta.y) <= 1 : abs(forward.delta.x) <= 1
        else { throw unavailable("nonrepeatable motion at count \(count)") }
        position = reverse.to
        let delta = axis == 0 ? forward.delta.x - reverse.delta.x : forward.delta.y - reverse.delta.y
        return delta / (2 * Double(reports))
    }

    private func verify(_ profile: RelativePointerCalibration) throws {
        for fraction in [CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.65, y: 0.6), CGPoint(x: 0.4, y: 0.5)] {
            guard let start = position else { throw unavailable() }
            let target = CGPoint(x: fraction.x * Double(width), y: fraction.y * Double(height))
            let before = try frame()
            let plan = profile.plan(from: start, to: target)
            for report in plan.reports { try send(report.dx, report.dy) }
            let after = try frame()
            guard
                let motion = PointerMotionObservation.motion(
                    from: before, to: after, direction: CGPoint(x: target.x - start.x, y: target.y - start.y)),
                distance(motion.from, start) <= 2, distance(motion.to, target) <= 3
            else { throw DeviceError("automatic pointer calibration failed target verification; no profile saved") }
            position = motion.to
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

    private func unavailable(_ reason: String = "pointer observation") -> DeviceError {
        DeviceError("cannot observe repeatable pointer motion in USB frames (\(reason)); no profile saved")
    }
}
