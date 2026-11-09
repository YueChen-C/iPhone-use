import Foundation

/// Turns taps, swipes and text into HID reports for one phone. Each phone has its own
/// serial queue, so gestures never interleave and phones work in parallel.
final class DeviceInput {
    let host: UUID
    let session: UUID?
    private let lifecycleLock = NSLock()
    private var retired = false
    private var lastActivityUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var calibrationRejected: Bool
    var isRetired: Bool { lifecycleLock.withLock { retired } }
    var lastInputUptime: TimeInterval { lifecycleLock.withLock { lastActivityUptime } }
    var hasRejectedCalibration: Bool { lifecycleLock.withLock { calibrationRejected } }
    var pointerOrientation: RelativePointerScreenMatcher.Orientation {
        lifecycleLock.withLock { relativePointerOrientation }
    }

    func recordInputActivity(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lifecycleLock.withLock { lastActivityUptime = uptime }
    }

    func rejectCalibration() {
        lifecycleLock.withLock { calibrationRejected = true }
    }

    var isCurrentSession: Bool {
        guard !isRetired, let session else { return false }
        return hid.connectionSession(for: host) == session
    }

    /// Transport readiness is independent of pointer calibration. A missing or
    /// mismatched calibration must not be presented as a Bluetooth disconnect.
    var isBluetoothReady: Bool {
        let reports: [ReportID] = [.keyboard] + pointerReports + [.consumer]
        return reports.allSatisfy { reportReadiness($0, host, session) }
    }

    var isPointerReady: Bool {
        coordinateMappingAvailable && pointerReports.allSatisfy { reportReadiness($0, host, session) }
    }

    var needsCalibration: Bool {
        if hasRejectedCalibration { return true }
        if calibrationRequired && calibration == nil { return true }
        if let calibration, let size = screenSize?() { return !calibration.matches(size) }
        return false
    }

    /// Press, motion and release stay on the same HID service for each mode.
    private var pointerReports: [ReportID] {
        calibration != nil || calibrationRequired ? [.relativeMouse] : [.absolutePointer]
    }

    // Gesture state is confined to this queue. Only motion supersession is
    // accessed from both the caller's thread and the queue, through its lock.
    private let queue: DispatchQueue
    private let hid = HIDPeripheral.shared
    private let reportReadiness: (ReportID, UUID, UUID?) -> Bool
    private let inputIsAllowed: () -> Bool
    private let calibrationIsVerified: () -> Bool
    private var buttons: UInt8 = 0
    private let reportSender: (ReportID, [UInt8], Bool) -> Void
    private let sleep: (TimeInterval) -> Void
    private var windowDragging = false
    let calibration: RelativePointerCalibration?
    private var absolutePointerPosition: (x: UInt16, y: UInt16)?
    private var estimatedPosition: CGPoint?
    /// Queue-confined progress lets fresh hover targets share one homing path.
    /// Cancelling the interaction or invalidating its mapping starts a new path.
    private var relativeHomingReportIndex = 0
    private var relativePointerOrientation: RelativePointerScreenMatcher.Orientation
    private var lastTrackingMovement: RelativePointerCalibration.Movement?
    private let motionSequence = PointerMotionSequence()
    // Background cancellation must not supersede a foreground hover already
    // submitted by the timer for the same AppKit mouse event.
    private let backgroundSequence = PointerMotionSequence()
    /// Matching rounds capture this once and abandon all remaining probes as
    /// soon as normal input supersedes them, including between probe attempts.
    var inputActivitySequence: UInt64 { backgroundSequence.current }
    private let calibrationRequired: Bool
    private let calibrationFilePresent: Bool
    private let screenSize: (() -> CGSize?)?

    /// A read-only snapshot for `/status`, including the curve actually loaded
    /// in memory so diagnostics do not infer it from potentially stale files.
    var pointerStatus: [String: Any] {
        let currentSize = screenSize?()
        let mode: String
        if calibration != nil {
            mode = "relative-calibrated"
        } else if calibrationRequired {
            mode = "calibration-unavailable"
        } else {
            mode = "absolute"
        }
        var calibrationInfo: [String: Any] = [
            "filePresent": calibrationFilePresent,
            "loaded": calibration != nil,
            "responseRejected": hasRejectedCalibration,
            "sessionVerified": calibration == nil || calibrationIsVerified(),
            "mode": mode,
        ]
        if let currentSize {
            calibrationInfo["screenWidth"] = Int(currentSize.width)
            calibrationInfo["screenHeight"] = Int(currentSize.height)
        }
        if let calibration {
            calibrationInfo["calibratedWidth"] = calibration.screenWidth
            calibrationInfo["calibratedHeight"] = calibration.screenHeight
            calibrationInfo["screenMatches"] = currentSize.map(calibration.matches) ?? false
            calibrationInfo["vectorModel"] = calibration.vectorModel?.rawValue ?? "single-axis"
            calibrationInfo["host"] = calibration.host.uuidString
            calibrationInfo["screenID"] = calibration.screenID
            calibrationInfo["reportInterval"] = calibration.reportInterval
            calibrationInfo["distances"] = calibration.distances
        } else {
            calibrationInfo["screenMatches"] = false
        }
        return [
            "ready": isPointerReady,
            "needsCalibration": needsCalibration,
            "sessionCurrent": isCurrentSession,
            "relativePointerOrientation": pointerOrientation.rawValue,
            "coordinateMappingAvailable": coordinateMappingAvailable,
            "calibration": calibrationInfo,
        ]
    }

    private var coordinateMappingAvailable: Bool {
        if isRetired || hasRejectedCalibration || !inputIsAllowed() { return false }
        if calibrationRequired && calibration == nil { return false }
        if let calibration, let screenSize {
            guard let size = screenSize(), calibration.matches(size) else { return false }
        }
        return true
    }

    init(
        host: UUID,
        session: UUID?,
        calibration: RelativePointerCalibration? = nil,
        calibrationRequired: Bool = false,
        calibrationFilePresent: Bool? = nil,
        calibrationRejected: Bool = false,
        calibrationIsVerified: @escaping () -> Bool = { true },
        relativePointerOrientation: RelativePointerScreenMatcher.Orientation = .identity,
        screenSize: (() -> CGSize?)? = nil,
        inputIsAllowed: @escaping () -> Bool = { true },
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
        reportSender: ((ReportID, [UInt8]) -> Void)? = nil,
        reportReadiness: ((ReportID, UUID, UUID?) -> Bool)? = nil
    ) {
        self.host = host
        self.session = session
        self.calibration = calibration
        self.calibrationRequired = calibrationRequired
        self.calibrationFilePresent = calibrationFilePresent ?? calibrationRequired
        self.calibrationRejected = calibrationRejected
        self.screenSize = screenSize
        self.inputIsAllowed = inputIsAllowed
        self.calibrationIsVerified = calibrationIsVerified
        self.relativePointerOrientation = relativePointerOrientation
        self.sleep = sleep
        self.reportReadiness =
            reportReadiness ?? {
                HIDPeripheral.shared.isReady(report: $0, host: $1, session: $2)
            }
        self.reportSender = { id, bytes, release in
            if let reportSender {
                reportSender(id, bytes)
            } else {
                // An explicit release uses the last sent absolute position, not
                // a stale window target. Still enforce the host/session in HID.
                HIDPeripheral.shared.send(
                    id, bytes, to: host, session: session, isAllowed: inputIsAllowed, absoluteRelease: release)
            }
        }
        queue = DispatchQueue(label: "iphone-use.input.\(host)")
    }

    /// Seconds between reports. BLE connection intervals are ~15-30 ms.
    var step: TimeInterval = 0.03

}

// MARK: - Pointer gestures

extension DeviceInput {
    enum ScrollDirection: String, CaseIterable {
        case up
        case down
        case left
        case right
    }

    /// Coordinates are fractions of the screen, 0...1 from the top-left corner.
    func tap(x: Double, y: Double, hold: TimeInterval = 0.08) throws {
        try performCoordinateGesture {
            pointer(x, y)
            pause(step * 2)
            button(down: true)
            pause(hold)
            button(down: false)
            pause(step)
        }
    }

    /// Double-clicks at one point with no pointer movement between clicks.
    func doubleTap(
        x: Double, y: Double,
        hold: TimeInterval = 0.22,
        gap: TimeInterval = 0.12
    ) throws {
        try multiTap(x: x, y: y, clicks: 2, hold: hold, gap: gap)
    }

    /// Triple-clicks at one point with no pointer movement between clicks.
    func tripleTap(
        x: Double, y: Double,
        hold: TimeInterval = 0.22,
        gap: TimeInterval = 0.12
    ) throws {
        try multiTap(x: x, y: y, clicks: 3, hold: hold, gap: gap)
    }

    private func multiTap(
        x: Double, y: Double,
        clicks: Int,
        hold: TimeInterval,
        gap: TimeInterval
    ) throws {
        try performCoordinateGesture {
            guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y),
                hold.isFinite, hold > 0, gap.isFinite, gap >= 0, clicks >= 2
            else {
                throw InputError.invalidSwipe(StringsAPI.current.swipeReasonPoints)
            }
            pointer(x, y)
            pause(step * 2)
            for clickIndex in 0..<clicks {
                button(down: true)
                pause(hold)
                button(down: false)
                if clickIndex + 1 < clicks {
                    pause(gap)
                } else {
                    pause(step)
                }
            }
        }
    }

    /// Long-presses at one point without sending intermediate reports while held.
    /// `duration` must be in `0.1...10.0` seconds (`100...10000` ms).
    func hold(x: Double, y: Double, duration: TimeInterval = 1.0) throws {
        try performCoordinateGesture {
            guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
                throw InputError.invalidSwipe(StringsAPI.current.swipeReasonPoints)
            }
            guard duration.isFinite, (0.1...10.0).contains(duration) else {
                throw InputError.invalidHoldDuration
            }
            pointer(x, y)
            pause(step * 2)
            button(down: true)
            pause(duration)
            button(down: false)
            pause(step)
        }
    }

    /// Moves to `from`, presses the button down, stays completely still for `holdDuration`
    /// (`0.1...10.0` s), then drags smoothly to `to` over `dragDuration` (`0.016...10.0` s)
    /// while keeping the button held, and finally releases.
    func holdDrag(
        from: (Double, Double),
        to: (Double, Double),
        holdDuration: TimeInterval = 1.0,
        dragDuration: TimeInterval = 1.0
    ) throws {
        try performCoordinateGesture {
            let table = StringsAPI.current
            guard from.0.isFinite, from.1.isFinite, (0...1).contains(from.0), (0...1).contains(from.1),
                to.0.isFinite, to.1.isFinite, (0...1).contains(to.0), (0...1).contains(to.1)
            else {
                throw InputError.invalidSwipe(table.swipeReasonPoints)
            }
            guard holdDuration.isFinite, (0.1...10.0).contains(holdDuration) else {
                throw InputError.invalidHoldDuration
            }
            guard dragDuration.isFinite, (0.016...10.0).contains(dragDuration) else {
                throw InputError.invalidSwipe(table.swipeReasonDuration)
            }
            let reportCount = dragDuration / step
            guard step.isFinite, step > 0, (step * 2).isFinite,
                reportCount.isFinite, reportCount < Double(Int.max)
            else {
                throw InputError.invalidSwipe(table.swipeReasonReportCount)
            }

            pointer(from.0, from.1)
            pause(step * 2)
            button(down: true)
            pause(holdDuration)
            let steps = max(2, Int(dragDuration / step))
            let interval = dragDuration / Double(steps)
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                let x = from.0 + (to.0 - from.0) * t
                let y = from.1 + (to.1 - from.1) * t
                dragMove(x, y, sequence: nil)
                pause(interval)
            }
            if calibration == nil { pause(step * 2) }
            button(down: false)
            pause(step)
        }
    }

    /// Moves the pointer to `at` (defaulting to screen center `(0.5, 0.5)`) and sends
    /// `ticks` (`1...1000`) wheel reports in `direction` (`up`, `down`, `left`, `right`).
    func scroll(
        direction: ScrollDirection,
        ticks: Int = 5,
        at: (Double, Double) = (0.5, 0.5)
    ) throws {
        try performCoordinateGesture {
            guard at.0.isFinite, at.1.isFinite, (0...1).contains(at.0), (0...1).contains(at.1) else {
                throw InputError.invalidSwipe(StringsAPI.current.swipeReasonPoints)
            }
            guard (1...1000).contains(ticks) else {
                throw InputError.invalidScrollTicks
            }
            pointer(at.0, at.1)
            pause(step * 2)
            let wheelStep: Int
            let usesHorizontalShift: Bool
            switch direction {
            case .up:
                wheelStep = 1
                usesHorizontalShift = false
            case .down:
                wheelStep = -1
                usesHorizontalShift = false
            case .left:
                wheelStep = 1
                usesHorizontalShift = true
            case .right:
                wheelStep = -1
                usesHorizontalShift = true
            }
            if usesHorizontalShift {
                send(.keyboard, HIDReportPayload.keyboard(modifiers: 0x02))
                pause(step)
            }
            for _ in 0..<ticks {
                send(.relativeMouse, HIDReportPayload.relativeMouse(buttons: 0, dx: 0, dy: 0, wheel: wheelStep))
                pause(step)
            }
            if usesHorizontalShift {
                send(.keyboard, HIDReportPayload.keyboard())
                pause(step)
            }
        }
    }

    /// Follow a polyline with one press and release. `duration` is the total
    /// movement wait. Positioning, button pacing and calibrated HID reports
    /// retain their own intervals. Segment waits follow physical screen distance.
    func swipe(points: [(Double, Double)], duration: TimeInterval) throws {
        try performCoordinateGesture {
            let table = StringsAPI.current
            guard points.count >= 2,
                points.allSatisfy({ x, y in
                    x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
                })
            else { throw InputError.invalidSwipe(table.swipeReasonPoints) }
            guard duration.isFinite, duration > 0 else {
                throw InputError.invalidSwipe(table.swipeReasonDuration)
            }
            // Validate before any reports: converting an infinite or out-of-range
            // report count to Int would trap, including when a caller sets step=0.
            let reportCount = duration / step
            guard step.isFinite, step > 0, (step * 2).isFinite,
                reportCount.isFinite, reportCount < Double(Int.max)
            else { throw InputError.invalidSwipe(table.swipeReasonReportCount) }

            let durations = swipeSegmentDurations(points: points, duration: duration)
            // Position and hold through the same pointer report throughout.
            pointer(points[0].0, points[0].1)
            pause(step * 2)
            button(down: true)
            pause(step)
            for (index, segmentDuration) in durations.enumerated() {
                let from = points[index]
                let to = points[index + 1]
                // Even a very short segment reaches its endpoint before the turn.
                let steps = max(2, Int(segmentDuration / step))
                for i in 1...steps {
                    let t = Double(i) / Double(steps)
                    let x = from.0 + (to.0 - from.0) * t
                    let y = from.1 + (to.1 - from.1) * t
                    let interval = segmentDuration / Double(steps)
                    dragMove(x, y, sequence: nil)
                    pause(interval)
                }
            }
            if calibration == nil { pause(step * 2) }
            button(down: false)
            pause(step)
        }
    }

    private func swipeSegmentDurations(points: [(Double, Double)], duration: TimeInterval) -> [TimeInterval] {
        let fallback =
            calibration.map { CGSize(width: $0.screenWidth, height: $0.screenHeight) }
            ?? CGSize(width: 1, height: 1)
        let size = screenSize?() ?? fallback
        // Only the aspect ratio matters. Scaling first avoids overflow for large
        // dimensions while preserving distances measured in physical pixels.
        let longestSide = max(size.width, size.height)
        let width = size.width / longestSide
        let height = size.height / longestSide
        let lengths = zip(points, points.dropFirst()).map { from, to in
            hypot((to.0 - from.0) * width, (to.1 - from.1) * height)
        }
        let total = lengths.reduce(0, +)
        // A stationary path is still a held gesture for the requested duration.
        return lengths.map { duration * (total > 0 ? $0 / total : 1 / Double(lengths.count)) }
    }

    func move(x: Double, y: Double) throws {
        try performCoordinateGesture {
            pointer(x, y)
            pause(step)
        }
    }

    /// Reload only an idle input; queued work from the old configuration must
    /// not send reports after the registry publishes its replacement.
    func retireForCalibrationReload(ifActivityUnchanged activity: UInt64? = nil) throws {
        try queue.sync {
            try requireIdlePointer()
            if let activity, !backgroundSequence.isCurrent(activity) {
                throw InputError.pairingProbeUnavailable
            }
            advanceMotionSequence()
            clearPointerEstimate()
            lifecycleLock.withLock { retired = true }
        }
    }

    /// Gain-independent fallback for hosts whose absolute coordinates do not
    /// reach the two matching targets. Capture an entire rectangle on one input
    /// queue, and never press a button or use a speculative calibration.
    func relativePairingProbe(
        preparePosition: Bool = true, isReady: () -> Bool, capture: () -> [[UInt8]?]
    ) throws -> [[[UInt8]]] {
        let sequence = backgroundSequence.current
        return try queue.sync {
            try requireIdlePointer()
            guard session != nil, !isRetired, isReady(), backgroundSequence.isCurrent(sequence) else {
                throw InputError.pairingProbeUnavailable
            }
            clearPointerEstimate()
            defer { clearPointerEstimate() }
            func move(_ dx: Int, _ dy: Int, times: Int) throws {
                for _ in 0..<times {
                    guard isReady(), backgroundSequence.isCurrent(sequence) else {
                        throw InputError.pairingProbeUnavailable
                    }
                    // Discovery observes raw HID axes before applying a transform.
                    send(.relativeMouse, HIDReportPayload.relativeMouse(buttons: 0, dx: dx, dy: dy))
                    pause(step)
                }
            }
            if preparePosition {
                // Retry away from clipped screen edges only when the local
                // trajectory could not establish a unique screen association.
                try move(-8, 0, times: 12)
                try move(0, -8, times: 12)
                try move(8, 0, times: 4)
                try move(0, 8, times: 4)
            } else {
                // Wake an idle pointer with a small reversible movement. Do
                // not sweep either screen boundary before trying the rectangle.
                try move(-8, 0, times: 1)
                try move(8, 0, times: 1)
            }
            var frames: [[[UInt8]]] = []
            for (dx, dy) in [(0, 0), (8, 0), (0, 8), (-8, 0), (0, -8)] {
                try move(dx, dy, times: dx == 0 && dy == 0 ? 0 : 4)
                pause(0.6)
                guard isReady(), backgroundSequence.isCurrent(sequence) else {
                    throw InputError.pairingProbeUnavailable
                }
                let images = capture()
                guard !images.isEmpty, images.allSatisfy({ $0 != nil }) else {
                    throw InputError.pairingProbeUnavailable
                }
                frames.append(images.map { $0! })
            }
            return frames
        }
    }

    /// Adopt only a transform proven by this session's closed discovery path.
    /// Registry cache rebuilds receive the same proof explicitly; files are unchanged.
    func adoptRelativePointerOrientation(_ orientation: RelativePointerScreenMatcher.Orientation) {
        queue.sync {
            lifecycleLock.withLock { relativePointerOrientation = orientation }
            clearPointerEstimate()
        }
    }

    /// A completed visual trajectory can establish the current origin without
    /// touching an edge. Keep it only on this exact screen/profile/input queue;
    /// cancellation or unrelated foreground activity invalidates the sample.
    @discardableResult
    func adoptObservedPointerOrigin(_ point: CGPoint, screenID: String, activity: UInt64) -> Bool {
        queue.sync {
            guard !isRetired, session != nil, inputIsAllowed(), !windowDragging, buttons == 0,
                backgroundSequence.isCurrent(activity),
                let calibration, calibration.screenID == screenID,
                let size = screenSize?(), calibration.matches(size),
                point.x.isFinite, point.y.isFinite,
                (0..<size.width).contains(point.x), (0..<size.height).contains(point.y)
            else { return false }
            estimatedPosition = point
            relativeHomingReportIndex = 0
            lastTrackingMovement = nil
            return true
        }
    }

    /// Keep native first-use measurement on this phone's normal input queue.
    /// Every report and capture rechecks ownership; disconnects and window
    /// cancellation invalidate the entire result before it can be saved.
    func measureRelativePointer(
        screenID: String, size: CGSize,
        activity: UInt64? = nil,
        reuseExisting: Bool = false,
        isReady: @escaping () -> Bool,
        capture: @escaping () -> [UInt8]?,
        onMismatch: @escaping () -> Void = {},
        progress: @escaping (Int) -> Void = { _ in }
    ) throws -> AutomaticPointerCalibration.Resolution {
        let sequence = activity ?? backgroundSequence.current
        return try queue.sync {
            try requireIdlePointer()
            guard size.width.isFinite, size.height.isFinite,
                (200...4096).contains(size.width), (300...4096).contains(size.height),
                buttons == 0, session != nil, !isRetired, isReady()
            else {
                throw InputError.pairingProbeUnavailable
            }
            clearPointerEstimate()
            defer { clearPointerEstimate() }
            func requireCurrent() throws {
                guard !self.isRetired, isReady(), self.backgroundSequence.isCurrent(sequence) else {
                    throw DeviceError(
                        "pointer measurement interrupted (retired=\(self.isRetired), ready=\(isReady()), activityCurrent=\(self.backgroundSequence.isCurrent(sequence)))"
                    )
                }
            }
            try requireCurrent()
            let reportInterval = reuseExisting ? (calibration?.reportInterval ?? 0.03) : 0.03
            let measurement = AutomaticPointerCalibration(
                host: host, screenID: screenID, width: Int(size.width), height: Int(size.height),
                reportInterval: reportInterval,
                send: { dx, dy in
                    try requireCurrent()
                    self.relative(dx, dy)
                    self.pause(reportInterval)
                },
                capture: {
                    self.pause(0.4)
                    try requireCurrent()
                    guard let pixels = capture() else { throw InputError.pairingProbeUnavailable }
                    return PointerMotionObservation.Frame(
                        width: Int(size.width), height: Int(size.height), pixels: pixels)
                }, progress: progress)
            if reuseExisting {
                var rejected = false
                do {
                    let result = try measurement.resolve(existing: calibration) {
                        rejected = true
                        onMismatch()
                    }
                    try requireCurrent()
                    // Publish rejection before releasing this queue: a waiting
                    // click must not use the old curve during registry publication.
                    self.lifecycleLock.withLock {
                        if result.reused {
                            self.calibrationRejected = false
                        } else if rejected {
                            self.calibrationRejected = true
                        }
                    }
                    return result
                } catch {
                    // Publishing a readiness change while reports are still
                    // running makes the control window cancel this very job.
                    // Block a rejected curve only once recovery has stopped.
                    if rejected { self.lifecycleLock.withLock { self.calibrationRejected = true } }
                    throw error
                }
            }
            return AutomaticPointerCalibration.Resolution(profile: try measurement.measure(), reused: false)
        }
    }

    /// Serializes a two-position matching probe with normal input on this host.
    /// A supplied calibration is used only for these reports, so recovery can
    /// test a verified old host profile without binding it to the current USB ID.
    func pairingProbe(
        calibration: RelativePointerCalibration?,
        firstPoint: CGPoint,
        secondPoint: CGPoint,
        returnToStart: Bool = false,
        thirdPoint: CGPoint? = nil,
        wait: TimeInterval = 0.6,
        isReady: () -> Bool,
        capture: () -> [UInt8]?
    ) throws -> (before: [UInt8], after: [UInt8], intermediate: [UInt8]?, returned: [UInt8]?) {
        let sequence = motionSequence.current
        let activity = backgroundSequence.current
        func probeIsReady() -> Bool { isReady() && backgroundSequence.isCurrent(activity) }
        return try queue.sync {
            guard !windowDragging, buttons == 0 else { throw InputError.pointerBusy }
            guard session != nil, probeIsReady(), motionSequence.isCurrent(sequence),
                wait.isFinite, wait >= 0,
                ([firstPoint.x, firstPoint.y, secondPoint.x, secondPoint.y]
                    + (thirdPoint.map { [$0.x, $0.y] } ?? [])).allSatisfy({
                        $0.isFinite && (0...1).contains($0)
                    })
            else { throw InputError.pairingProbeUnavailable }

            if let calibration {
                guard calibration.host == host, (try? calibration.validate()) != nil else {
                    throw InputError.pairingProbeUnavailable
                }
            }

            // The explicit profile can differ from this input's screen mapping.
            // Do not reuse either mapping's estimate across that boundary.
            clearPointerEstimate()
            defer { clearPointerEstimate() }
            // A hidden cursor may ignore an unchanged absolute report. Visit
            // another target first so the first observed landing is a move,
            // including when reconnecting at the previous absolute position.
            if let thirdPoint, calibration == nil {
                moveForPairingProbe(thirdPoint, calibration: nil, sequence: sequence, isReady: probeIsReady)
                pause(wait)
                guard probeIsReady(), motionSequence.isCurrent(sequence) else {
                    throw InputError.pairingProbeUnavailable
                }
            }
            moveForPairingProbe(firstPoint, calibration: calibration, sequence: sequence, isReady: probeIsReady)
            pause(wait)
            guard probeIsReady(), motionSequence.isCurrent(sequence), let before = capture() else {
                throw InputError.pairingProbeUnavailable
            }
            guard probeIsReady(), motionSequence.isCurrent(sequence) else { throw InputError.pairingProbeUnavailable }
            moveForPairingProbe(secondPoint, calibration: calibration, sequence: sequence, isReady: probeIsReady)
            pause(wait)
            guard probeIsReady(), motionSequence.isCurrent(sequence), let after = capture() else {
                throw InputError.pairingProbeUnavailable
            }
            var intermediate: [UInt8]?
            if let thirdPoint {
                guard probeIsReady(), motionSequence.isCurrent(sequence) else {
                    throw InputError.pairingProbeUnavailable
                }
                moveForPairingProbe(thirdPoint, calibration: calibration, sequence: sequence, isReady: probeIsReady)
                pause(wait)
                guard probeIsReady(), motionSequence.isCurrent(sequence), let pixels = capture() else {
                    throw InputError.pairingProbeUnavailable
                }
                intermediate = pixels
            }
            var returned: [UInt8]?
            if returnToStart {
                guard probeIsReady(), motionSequence.isCurrent(sequence) else {
                    throw InputError.pairingProbeUnavailable
                }
                moveForPairingProbe(firstPoint, calibration: calibration, sequence: sequence, isReady: probeIsReady)
                pause(wait)
                guard probeIsReady(), motionSequence.isCurrent(sequence), let pixels = capture() else {
                    throw InputError.pairingProbeUnavailable
                }
                returned = pixels
            }
            return (before, after, intermediate, returned)
        }
    }

    private func moveForPairingProbe(
        _ point: CGPoint, calibration: RelativePointerCalibration?, sequence: UInt64, isReady: () -> Bool
    ) {
        if let calibration {
            moveCalibratedPointer(point.x, point.y, calibration: calibration, sequence: sequence, isReady: isReady)
        } else if isReady() {
            moveAbsolutePointer(point.x, point.y, sequence: sequence)
        }
    }

    func positionPointer(x: Double, y: Double) {
        let sequence = advanceMotionSequence()
        queue.async {
            guard self.coordinateMappingAvailable else { return }
            // Calibrated movement may take several connection intervals. Drop
            // old hover targets instead of replaying a growing mouse backlog.
            guard self.motionSequence.isCurrent(sequence) else { return }
            self.pointer(x, y, sequence: sequence)
        }
    }

    /// Begin a pointer gesture. Follow with `drag` calls and finish with `release`.
    /// These small operations are intentionally separate so a real mouse drag can be
    /// forwarded while it is happening instead of being buffered as one long swipe.
    func press(x: Double, y: Double) {
        discardPendingMotion()
        queue.async {
            guard !self.windowDragging, self.coordinateMappingAvailable else { return }
            self.windowDragging = true
            // Hover and held motion use the same report and coordinate space.
            self.pointer(x, y)
            // Use the same positioning interval as the coordinate tap API.
            self.pause(self.step * 2)
            self.button(down: true)
        }
    }

    func drag(x: Double, y: Double) {
        let sequence = advanceMotionSequence()
        queue.async {
            guard self.windowDragging,
                self.motionSequence.isCurrent(sequence)
            else { return }
            self.dragMove(x, y, sequence: sequence)
        }
    }

    func release(x: Double, y: Double) {
        discardPendingMotion()
        queue.async {
            guard self.windowDragging else { return }
            self.dragMove(x, y, sequence: nil)
            if self.calibration == nil { self.pause(self.step * 2) }
            self.button(down: false)
            self.windowDragging = false
        }
    }

    /// Always clear the phone-side button state when the window loses focus or
    /// the mouse interaction is cancelled outside the view.
    func cancelPointer(preservingBackgroundMotion: Bool = false) {
        if preservingBackgroundMotion { motionSequence.advance() } else { discardPendingMotion() }
        queue.async {
            self.windowDragging = false
            if self.estimatedPosition == nil { self.relativeHomingReportIndex = 0 }
            guard self.buttons != 0 else { return }
            self.button(down: false)
        }
    }

    /// A report subscription can disappear while a calibrated movement is being
    /// sent. Drop the predicted landing so the first movement after reconnect
    /// establishes a fresh origin instead of trusting reports that were lost.
    func invalidatePointerEstimate(preservingBackgroundMotion: Bool = false) {
        if preservingBackgroundMotion { motionSequence.advance() } else { discardPendingMotion() }
        queue.async {
            self.clearPointerEstimate()
        }
    }

    @discardableResult
    private func advanceMotionSequence() -> UInt64 {
        recordInputActivity()
        backgroundSequence.advance()
        return motionSequence.advance()
    }

    private func discardPendingMotion() {
        advanceMotionSequence()
    }

    /// User activity must interrupt background measurement before waiting on
    /// its queue, including when no usable coordinate mapping exists yet.
    func cancelBackgroundMotion() {
        backgroundSequence.advance()
    }

    /// Relative mouse, for testing hosts that ignore the absolute pointer.
    func nudge(dx: Int, dy: Int, click: Bool) throws {
        if dx != 0 || dy != 0 || click { discardPendingMotion() }
        try queue.sync {
            try requireIdlePointer()
            if dx != 0 || dy != 0 {
                clearPointerEstimate()
                absolutePointerPosition = nil
            }
            var remainingX = dx
            var remainingY = dy
            while remainingX != 0 || remainingY != 0 {
                let sx = max(-127, min(127, remainingX))
                let sy = max(-127, min(127, remainingY))
                send(.relativeMouse, HIDReportPayload.relativeMouse(buttons: 0, dx: sx, dy: sy))
                remainingX -= sx
                remainingY -= sy
                pause(step)
            }
            if click {
                if calibration == nil, absolutePointerPosition != nil {
                    button(down: true)
                    pause(0.08)
                    button(down: false)
                } else {
                    send(.relativeMouse, HIDReportPayload.relativeMouse(buttons: 1))
                    pause(0.08)
                    send(.relativeMouse, HIDReportPayload.relativeMouse(buttons: 0))
                }
                pause(step)
            }
        }
    }

}

// MARK: - Keyboard and consumer controls

extension DeviceInput {
    /// Keyboard events originating in the control window are asynchronous so text
    /// entry never blocks AppKit's event loop while BLE reports are sent.
    func typeFromKeyboard(_ text: String, modifiers: [String] = []) -> Bool {
        guard let modifierMask = KeyboardMap.modifierMask(for: modifiers) else { return false }
        let strokes = text.compactMap { KeyboardMap.stroke(for: $0) }.map {
            KeyboardMap.Stroke(code: $0.code, modifiers: $0.modifiers | modifierMask)
        }
        guard strokes.count == text.count else { return false }
        if !strokes.isEmpty { discardPendingMotion() }
        queue.async {
            for stroke in strokes { self.press(stroke) }
        }
        return true
    }

    func keyFromKeyboard(_ name: String, modifiers: [String] = []) -> Bool {
        guard let code = KeyboardMap.code(for: name),
            let modifierMask = KeyboardMap.modifierMask(for: modifiers)
        else { return false }
        discardPendingMotion()
        queue.async {
            self.press(KeyboardMap.Stroke(code: code, modifiers: modifierMask))
        }
        return true
    }

    func type(_ text: String) throws {
        guard let keyboardText = KeyboardMap.keyboardText(for: text) else {
            let invalid = text.first { KeyboardMap.stroke(for: $0) == nil } ?? "?"
            throw InputError.untypeable(invalid)
        }
        let strokes = keyboardText.compactMap { KeyboardMap.stroke(for: $0) }
        if !strokes.isEmpty { discardPendingMotion() }
        queue.sync {
            for stroke in strokes {
                press(stroke)
            }
        }
    }

    /// A named key with optional modifiers, e.g. key("h", modifiers: ["cmd"]).
    func key(_ name: String, modifiers: [String]) throws {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("mute") == .orderedSame {
            throw InputError.muteKeyRequiresMuteCommand
        }
        guard let code = KeyboardMap.code(for: name)
        else { throw InputError.unknownKey(name) }
        var mask: UInt8 = 0
        for modifier in modifiers {
            guard let bit = KeyboardMap.modifierBit(for: modifier) else { throw InputError.unknownKey(modifier) }
            mask |= bit
        }
        discardPendingMotion()
        queue.sync { press(KeyboardMap.Stroke(code: code, modifiers: mask)) }
    }

    func consumer(_ usage: UInt16) {
        discardPendingMotion()
        queue.sync {
            send(.consumer, HIDReportPayload.consumer(usage))
            pause(0.08)
            send(.consumer, HIDReportPayload.consumer(0))
            pause(step)
        }
    }

    /// Sends a harmless Left Control modifier tap (`0x01` down then `0x00` up)
    /// to reset iOS's idle dim/lock timer without affecting UI state.
    @discardableResult
    func sendControlKeepAlive() -> Bool {
        queue.sync {
            guard !isRetired, inputIsAllowed(), !windowDragging, buttons == 0,
                reportReadiness(.keyboard, host, session)
            else { return false }
            send(.keyboard, HIDReportPayload.keyboard(modifiers: 0x01, code: 0))
            pause(step)
            send(.keyboard, HIDReportPayload.keyboard(modifiers: 0x00, code: 0))
            return true
        }
    }

}

// MARK: - Serialized report generation

extension DeviceInput {
    // Modifier reports must surround the key press/release. Combining these
    // reports changes how hosts interpret shortcuts over BLE intervals.
    fileprivate func press(_ stroke: KeyboardMap.Stroke) {
        if stroke.modifiers != 0 {
            send(.keyboard, HIDReportPayload.keyboard(modifiers: stroke.modifiers))
            pause(step)
        }
        send(.keyboard, HIDReportPayload.keyboard(modifiers: stroke.modifiers, code: stroke.code))
        pause(step)
        send(.keyboard, HIDReportPayload.keyboard(modifiers: stroke.modifiers))
        pause(step)
        if stroke.modifiers != 0 {
            send(.keyboard, HIDReportPayload.keyboard())
            pause(step)
        }
    }

    /// Window and API share either native absolute reports or the host's measured
    /// relative curve. Never mix those motion modes within one input session.
    fileprivate func pointer(_ x: Double, _ y: Double, sequence: UInt64? = nil) {
        if let calibration {
            moveCalibratedPointer(x, y, calibration: calibration, sequence: sequence)
        } else {
            moveAbsolutePointer(x, y, sequence: sequence)
        }
    }

    fileprivate func moveCalibratedPointer(
        _ x: Double, _ y: Double,
        calibration: RelativePointerCalibration, sequence: UInt64?, isReady: () -> Bool = { true }
    ) {
        guard shouldContinueMotion(sequence), isReady() else { return }
        if estimatedPosition == nil,
            !homeRelativePointer(using: calibration, sequence: sequence, isReady: isReady)
        {
            return
        }
        let target = CGPoint(x: x * Double(calibration.screenWidth), y: y * Double(calibration.screenHeight))
        // Window and API move from the same predicted landing. Only unknown
        // positions need homing. API gestures finish on this serial queue;
        // window tracking can be superseded before its next report.
        while shouldContinueMotion(sequence), isReady() {
            guard
                let movement = calibration.trackingStep(
                    from: estimatedPosition ?? .zero, to: target, after: lastTrackingMovement)
            else { break }
            relative(movement.report.dx, movement.report.dy)
            estimatedPosition = movement.position
            lastTrackingMovement = movement.report
            pause(calibration.reportInterval)
        }
    }

    fileprivate func moveAbsolutePointer(_ x: Double, _ y: Double, sequence: UInt64?) {
        guard shouldContinueMotion(sequence) else { return }
        let max = Double(HIDReportMap.absoluteMax)
        let px = UInt16(Swift.max(0, Swift.min(max, (x * max).rounded())))
        let py = UInt16(Swift.max(0, Swift.min(max, (y * max).rounded())))
        absolutePointerPosition = (px, py)
        send(.absolutePointer, HIDReportPayload.absolutePointer(buttons: buttons, x: px, y: py))
    }

    /// Held movement uses the same coordinates and report as hover/press.
    fileprivate func dragMove(_ x: Double, _ y: Double, sequence: UInt64?) {
        pointer(x, y, sequence: sequence)
    }

    fileprivate func shouldContinueMotion(_ sequence: UInt64?) -> Bool {
        guard !isRetired, inputIsAllowed() else {
            clearPointerEstimate()
            return false
        }
        // Synchronous API gestures have no supersession token and must finish.
        guard let sequence else { return true }
        return motionSequence.isCurrent(sequence)
    }

    @discardableResult
    fileprivate func homeRelativePointer(
        using calibration: RelativePointerCalibration? = nil, sequence: UInt64? = nil,
        isReady: () -> Bool = { true }
    ) -> Bool {
        guard let calibration = calibration ?? self.calibration else { return false }
        // Recover an unknown origin on first use or after invalidation.
        // Never home while a button is held.
        guard buttons == 0 else { return false }
        let reports = calibration.homingReports
        while relativeHomingReportIndex < reports.count {
            // An interrupted homing path has no known origin. Leave the
            // estimate unset until a later operation completes the whole path.
            guard shouldContinueMotion(sequence), isReady() else { return false }
            let report = reports[relativeHomingReportIndex]
            relative(report.dx, report.dy)
            relativeHomingReportIndex += 1
            pause(calibration.reportInterval)
        }
        guard shouldContinueMotion(sequence), isReady() else { return false }
        estimatedPosition = .zero
        relativeHomingReportIndex = 0
        lastTrackingMovement = nil
        return true
    }

    fileprivate func relative(_ dx: Int, _ dy: Int) {
        let report = relativePointerOrientation.reportDelta(dx: dx, dy: dy)
        send(.relativeMouse, HIDReportPayload.relativeMouse(buttons: buttons, dx: report.dx, dy: report.dy))
    }

    fileprivate func button(down: Bool) {
        buttons = down ? 1 : 0
        if calibration == nil, !calibrationRequired, let position = absolutePointerPosition {
            send(
                .absolutePointer,
                HIDReportPayload.absolutePointer(buttons: buttons, x: position.x, y: position.y),
                release: !down)
        } else {
            send(.relativeMouse, HIDReportPayload.relativeMouse(buttons: buttons))
        }
    }

    /// Coordinate APIs share the same validation order and queue boundary.
    /// Keep pacing inside the operation so a complete gesture stays serialized.
    fileprivate func performCoordinateGesture(_ gesture: () throws -> Void) throws {
        // Supersede background probes before waiting on their input queue.
        discardPendingMotion()
        try queue.sync {
            try requireIdlePointer()
            try requireCoordinateMapping()
            try gesture()
        }
    }

    fileprivate func clearPointerEstimate() {
        estimatedPosition = nil
        relativeHomingReportIndex = 0
        lastTrackingMovement = nil
    }

    fileprivate func requireIdlePointer() throws {
        guard !windowDragging else { throw InputError.pointerBusy }
    }

    fileprivate func requireCoordinateMapping() throws {
        guard coordinateMappingAvailable else {
            clearPointerEstimate()
            throw InputError.calibrationMismatch
        }
    }

    fileprivate func pause(_ seconds: TimeInterval) {
        sleep(seconds)
    }

    fileprivate func send(_ id: ReportID, _ bytes: [UInt8], release: Bool = false) {
        guard !isRetired else { return }
        // A capture can be invalidated while an input is queued. Stop stale
        // movement and presses, while still releasing any held button or key.
        guard release || inputIsAllowed() || (id != .absolutePointer && bytes.allSatisfy { $0 == 0 }) else { return }
        reportSender(id, bytes, release)
    }

}

extension DeviceInput {
    enum InputError: Error, CustomStringConvertible, Equatable {
        case untypeable(Character)
        case unknownKey(String)
        case muteKeyRequiresMuteCommand
        case pointerBusy
        case calibrationMismatch
        case invalidSwipe(String)
        case invalidHoldDuration
        case invalidScrollTicks
        case pairingProbeUnavailable

        var description: String {
            let table = StringsAPI.current
            return switch self {
            case .untypeable(let c): table.untypeable(String(reflecting: c))
            case .unknownKey(let k): table.unknownKey(k)
            case .muteKeyRequiresMuteCommand:
                "mute is excluded from key; use mute or unmute so ringer state is verified over USB"
            case .pointerBusy: table.pointerBusy
            case .calibrationMismatch: table.calibrationMismatch
            case .invalidSwipe(let reason): table.invalidSwipePrefix(reason)
            case .invalidHoldDuration: "hold duration must be within 100...10000 ms (0.1...10.0 seconds)"
            case .invalidScrollTicks: "scroll ticks must be within 1...1000"
            case .pairingProbeUnavailable: table.pairingProbeUnavailable
            }
        }
    }
}

/// Supersedes stale window hover/drag targets without touching queue-owned
/// gesture state. Wrapping arithmetic preserves behavior across sequence rollover.
private final class PointerMotionSequence {
    private let lock = NSLock()
    private var value: UInt64 = 0

    var current: UInt64 { lock.withLock { value } }

    @discardableResult
    func advance() -> UInt64 {
        lock.withLock {
            value &+= 1
            return value
        }
    }

    func isCurrent(_ sequence: UInt64) -> Bool {
        lock.withLock { value == sequence }
    }
}
