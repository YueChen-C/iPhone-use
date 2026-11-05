import Foundation

/// Pointer adaptation using USB frames only. It sends button-free reports,
/// checks forward/reverse motion, then verifies actual target landings before
/// returning a profile. Persistence and session ownership belong to the caller.
final class AutomaticPointerCalibration {
    typealias Frame = PointerMotionObservation.Frame
    private let host: UUID
    private let screenID: String
    private let width: Int
    private let height: Int
    private let reportInterval: TimeInterval
    private let send: (Int, Int) throws -> Void
    private let capture: () throws -> Frame
    private let progress: (Int) -> Void
    private var position: CGPoint?

    init(
        host: UUID, screenID: String, width: Int, height: Int, reportInterval: TimeInterval = 0.03,
        send: @escaping (Int, Int) throws -> Void, capture: @escaping () throws -> Frame,
        progress: @escaping (Int) -> Void = { _ in }
    ) {
        self.host = host
        self.screenID = screenID
        self.width = width
        self.height = height
        self.reportInterval = reportInterval
        self.send = send
        self.capture = capture
        self.progress = progress
    }

    func measure() throws -> RelativePointerCalibration {
        let initial = try prepareSamplingArea()
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
        for count in [4, 16, 32] {
            guard
                let vertical = try sample(
                    count: count, axis: 1, reports: max(1, Int(ceil(64 / distances[count])))),
                abs(vertical - distances[count]) <= max(0.5, distances[count] * 0.02)
            else { throw unavailable("vertical count \(count)") }
        }
        let profile = RelativePointerCalibration(
            host: host, screenWidth: width, screenHeight: height, reportInterval: reportInterval,
            distances: distances, screenID: screenID)
        try profile.validate()
        guard try verifyTargets(profile) else {
            throw DeviceError("automatic pointer calibration failed target verification; no profile saved")
        }
        return try verifyingVectorModel(profile)
    }

    struct Resolution {
        let profile: RelativePointerCalibration
        let reused: Bool
    }

    /// Observation failure is different from a measured mismatch: only a
    /// repeatable displacement can invalidate an existing curve.
    func resolve(
        existing: RelativePointerCalibration?, onMismatch: () -> Void = {}
    ) throws -> Resolution {
        if let existing {
            try existing.validate()
            guard existing.host == host, existing.screenID == screenID,
                existing.matches(CGSize(width: width, height: height)), existing.reportInterval == reportInterval
            else { throw unavailable("profile identity, dimensions or report interval") }
            _ = try prepareSamplingArea()
            if try matchesResponse(existing), try verifyTargets(existing) {
                let profile = try verifyingVectorModel(existing)
                return Resolution(profile: profile, reused: profile == existing)
            }
            onMismatch()
        }
        return Resolution(profile: try measure(), reused: false)
    }

    /// Model selection belongs to measurement, not to the previous file's
    /// metadata. An axis-only recovery must not permanently disable smooth
    /// combined reports on a phone whose diagonal response can be verified.
    private func verifyingVectorModel(_ profile: RelativePointerCalibration) throws -> RelativePointerCalibration {
        guard profile.vectorModel == nil else { return profile }
        do {
            guard try matchesDiagonals(profile) else { return profile }
            let radial = RelativePointerCalibration(
                host: host, screenWidth: width, screenHeight: height,
                reportInterval: profile.reportInterval, distances: profile.distances,
                screenID: screenID, vectorModel: .radialQuantized)
            if try verifyTargets(radial) { return radial }
        } catch is ObservationError {
            // Only local observation failures are recoverable here. Transport,
            // cancellation and session errors from send/capture must propagate.
        }
        // Optional probing may have lost the origin or moved under a different
        // model. Re-establish it and prove axis landings again before fallback.
        _ = try prepareSamplingArea()
        guard try verifyTargets(profile) else { throw unavailable("axis fallback target verification") }
        return profile
    }

    private func prepareSamplingArea() throws -> Double {
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

        return initial
    }

    private func matchesResponse(_ profile: RelativePointerCalibration) throws -> Bool {
        for (count, axis) in [(8, 0), (32, 0), (16, 0), (16, 1), (1, 0)] {
            guard count < profile.distances.count else { throw unavailable("profile sampling range") }
            let expected = profile.distances[count]
            guard
                let measured = try sample(
                    count: count, axis: axis, reports: max(1, min(256, Int(ceil(64 / expected)))))
            else { throw unavailable("saved curve count \(count)") }
            if abs(measured - expected) > max(0.75, expected * 0.05) { return false }
        }
        if profile.vectorModel == nil { return true }
        return try matchesDiagonals(profile)
    }

    private func matchesDiagonals(_ profile: RelativePointerCalibration) throws -> Bool {
        for (dx, dy) in [(7, 7), (12, 16)] {
            let count = Int(hypot(Double(dx), Double(dy)))
            guard count < profile.distances.count else { throw unavailable("diagonal sampling range") }
            let gain = profile.distances[count] / Double(count)
            let expected = CGPoint(x: gain * Double(dx), y: gain * Double(dy))
            let reports = max(1, min(256, Int(ceil(48 / max(expected.x, expected.y)))))
            guard let measured = try sample(dx: dx, dy: dy, reports: reports, requiringParallelMotion: false) else {
                throw unavailable("diagonal response")
            }
            if abs(measured.x - expected.x) > max(0.75, expected.x * 0.05)
                || abs(measured.y - expected.y) > max(0.75, expected.y * 0.05)
            {
                return false
            }
        }
        return true
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
        guard let delta = try sample(dx: axis == 0 ? count : 0, dy: axis == 1 ? count : 0, reports: reports) else {
            return nil
        }
        return axis == 0 ? delta.x : delta.y
    }

    private func sample(
        dx: Int, dy: Int, reports: Int, requiringParallelMotion: Bool = true
    ) throws -> CGPoint? {
        let before = try frame()
        let direction = CGPoint(x: dx, y: dy)
        try burst(dx, dy, reports: reports)
        let after = try frame()
        try burst(-dx, -dy, reports: reports)
        let returned = try frame()
        guard
            let forward = PointerMotionObservation.motion(
                from: before, to: after, direction: direction, allowingBackgroundAnimation: true),
            let reverse = PointerMotionObservation.motion(
                from: after, to: returned, direction: CGPoint(x: -direction.x, y: -direction.y),
                allowingBackgroundAnimation: true)
        else {
            // Overlap may need a longer burst. An animated/invalid return frame
            // cannot establish that the pointer returned and must stop sampling.
            guard let changes = PointerMotionObservation.changedPixels(before, returned), changes <= 256 else {
                throw unavailable("unobservable return at (\(dx), \(dy)), reports \(reports)")
            }
            return nil
        }
        guard distance(forward.from, reverse.to) <= 2, distance(forward.to, reverse.from) <= 1,
            !requiringParallelMotion
                || abs(forward.delta.x * Double(dy) - forward.delta.y * Double(dx)) <= hypot(Double(dx), Double(dy))
        else { throw unavailable("nonrepeatable motion at (\(dx), \(dy))") }
        position = reverse.to
        return CGPoint(
            x: (forward.delta.x - reverse.delta.x) / (2 * Double(reports)),
            y: (forward.delta.y - reverse.delta.y) / (2 * Double(reports)))
    }

    private func verifyTargets(_ profile: RelativePointerCalibration) throws -> Bool {
        for fraction in [CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.65, y: 0.6), CGPoint(x: 0.4, y: 0.5)] {
            guard let start = position else { throw unavailable() }
            let target = CGPoint(x: fraction.x * Double(width), y: fraction.y * Double(height))
            let before = try frame()
            var predicted = start
            var previous: RelativePointerCalibration.Movement?
            for _ in 0..<4096 {
                guard let move = profile.trackingStep(from: predicted, to: target, after: previous) else { break }
                try send(move.report.dx, move.report.dy)
                predicted = move.position
                previous = move.report
            }
            let after = try frame()
            guard
                let motion = PointerMotionObservation.motion(
                    from: before, to: after, direction: CGPoint(x: target.x - start.x, y: target.y - start.y),
                    allowingBackgroundAnimation: true),
                distance(motion.from, start) <= 2
            else { throw unavailable("target observation") }
            position = motion.to
            if distance(motion.to, target) > 3 { return false }
        }
        return true
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

    private struct ObservationError: Error, CustomStringConvertible {
        let reason: String
        var description: String {
            "cannot observe repeatable pointer motion in USB frames (\(reason)); no profile saved"
        }
    }

    private func unavailable(_ reason: String = "pointer observation") -> ObservationError {
        ObservationError(reason: reason)
    }
}
