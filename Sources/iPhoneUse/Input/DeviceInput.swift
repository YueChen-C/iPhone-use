import Foundation

/// Turns taps, swipes and text into HID reports for one phone. Each phone has its own
/// serial queue, so gestures never interleave and phones work in parallel.
final class DeviceInput {
    let host: UUID
    let session: UUID?
    private let lifecycleLock = NSLock()
    private var retired = false
    var isRetired: Bool { lifecycleLock.withLock { retired } }

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
        if calibrationRequired && calibration == nil { return true }
        if let calibration, let size = screenSize?() { return !calibration.matches(size) }
        return false
    }

    /// Absolute hosts position through the absolute collection, but iOS only
    /// synthesizes a touch from relative button reports, so every press and
    /// all drag movement run on the relative collection. Calibrated hosts
    /// use the relative collection for everything.
    private var pointerReports: [ReportID] {
        calibration != nil || calibrationRequired ? [.relativeMouse] : [.absolutePointer, .relativeMouse]
    }

    // Gesture state is confined to this queue. Only motion supersession is
    // accessed from both the caller's thread and the queue, through its lock.
    private let queue: DispatchQueue
    private let hid = HIDPeripheral.shared
    private let reportReadiness: (ReportID, UUID, UUID?) -> Bool
    private let inputIsAllowed: () -> Bool
    private var buttons: UInt8 = 0
    private let reportSender: (ReportID, [UInt8]) -> Void
    private let visualReportSender: (ReportID, [UInt8], @escaping () -> Bool) -> Void
    private let reportDrainer: (TimeInterval) -> Bool
    private let sleep: (TimeInterval) -> Void
    private var windowDragging = false
    let calibration: RelativePointerCalibration?
    private var absolutePointerPosition: (x: UInt16, y: UInt16)?
    private var estimatedPosition: CGPoint?
    /// Queue-confined progress lets fresh hover targets share one homing path.
    /// Cancelling the interaction or invalidating its mapping starts a new path.
    private var relativeHomingReportIndex = 0
    private var lastTrackingMovement: RelativePointerCalibration.Movement?
    /// Predicted pointer position in physical pixels while an uncalibrated
    /// drag runs on the relative collection. Nil outside a drag.
    private var dragPosition: CGPoint?
    private var lastEstimatedMovement: RelativePointerCalibration.Movement?
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
            "coordinateMappingAvailable": coordinateMappingAvailable,
            "calibration": calibrationInfo,
            "visualFeedback": [
                "available": visualPointerTransportAvailable,
                "actions": ["tap", "long_press", "move_pointer", "swipe"],
                "requiresFreshObservation": true,
                "observedTargetTolerancePixels": 3,
                "swipePath": "estimated-after-observed-start",
            ] as [String: Any],
        ]
    }

    private var coordinateMappingAvailable: Bool {
        if isRetired || !inputIsAllowed() { return false }
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
        screenSize: (() -> CGSize?)? = nil,
        inputIsAllowed: @escaping () -> Bool = { true },
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
        reportSender: ((ReportID, [UInt8]) -> Void)? = nil,
        reportReadiness: ((ReportID, UUID, UUID?) -> Bool)? = nil,
        reportDrainer: ((TimeInterval) -> Bool)? = nil,
        visualReportSender: ((ReportID, [UInt8], @escaping () -> Bool) -> Void)? = nil
    ) {
        self.host = host
        self.session = session
        self.calibration = calibration
        self.calibrationRequired = calibrationRequired
        self.calibrationFilePresent = calibrationFilePresent ?? calibrationRequired
        self.screenSize = screenSize
        self.inputIsAllowed = inputIsAllowed
        self.sleep = sleep
        self.reportReadiness =
            reportReadiness ?? {
                HIDPeripheral.shared.isReady(report: $0, host: $1, session: $2)
            }
        self.reportSender =
            reportSender ?? { id, bytes in
                HIDPeripheral.shared.send(id, bytes, to: host, session: session, isAllowed: inputIsAllowed)
            }
        if let visualReportSender {
            self.visualReportSender = visualReportSender
        } else if let reportSender {
            self.visualReportSender = { id, bytes, allowed in
                if allowed() { reportSender(id, bytes) }
            }
        } else {
            self.visualReportSender = { id, bytes, allowed in
                HIDPeripheral.shared.send(id, bytes, to: host, session: session, isAllowed: allowed)
            }
        }
        self.reportDrainer =
            reportDrainer ?? { timeout in
                HIDPeripheral.shared.waitUntilReportsDrained(host: host, session: session, timeout: timeout)
            }
        queue = DispatchQueue(label: "iphone-use.input.\(host)")
    }

    /// Seconds between reports. BLE connection intervals are ~15-30 ms.
    var step: TimeInterval = 0.03

}

// MARK: - Pointer gestures

extension DeviceInput {
    /// Availability of an independent observed-position path. This deliberately
    /// does not change the meaning of calibrated readiness or save a curve.
    var visualPointerTransportAvailable: Bool {
        !isRetired && session != nil && inputIsAllowed()
            && reportReadiness(.relativeMouse, host, session)
    }

    func visualMove(
        x: Double, y: Double, size: CGSize,
        capture: @escaping (UInt64?, TimeInterval) throws -> VisualPointerFrame,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) throws {
        try performVisualPointer(x: x, y: y, hold: nil, size: size, capture: capture, now: now)
    }

    func visualTap(
        x: Double, y: Double, hold: TimeInterval = 0.08, size: CGSize,
        capture: @escaping (UInt64?, TimeInterval) throws -> VisualPointerFrame,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) throws {
        try performVisualPointer(x: x, y: y, hold: hold, size: size, capture: capture, now: now)
    }

    /// Observe the press position, then estimate a drag from the measured local
    /// gain. Scrolling changes the background, so the path is not a 5px claim.
    func visualSwipe(
        points: [(Double, Double)], duration: TimeInterval, size: CGSize,
        capture: @escaping (UInt64?, TimeInterval) throws -> VisualPointerFrame,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) throws {
        guard (2...128).contains(points.count), duration.isFinite, duration > 0, duration <= 5,
            points.allSatisfy({ $0.0.isFinite && $0.1.isFinite && (0...1).contains($0.0) && (0...1).contains($0.1) })
        else { throw DeviceError("visual swipe needs a finite path and a duration of at most 5 seconds") }
        try performVisualPointer(
            x: points[0].0, y: points[0].1, hold: nil, size: size,
            drag: (points, duration), capture: capture, now: now)
    }

    private func performVisualPointer(
        x: Double, y: Double, hold: TimeInterval?, size: CGSize,
        drag: (points: [(Double, Double)], duration: TimeInterval)? = nil,
        capture: @escaping (UInt64?, TimeInterval) throws -> VisualPointerFrame,
        now: @escaping () -> TimeInterval
    ) throws {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y),
            size.width.isFinite, size.height.isFinite,
            step.isFinite, step > 0, step <= 1,
            (200...4096).contains(size.width), (300...4096).contains(size.height),
            hold.map({ $0.isFinite && (0...10).contains($0) }) ?? true
        else { throw DeviceError("invalid visual pointer coordinates or hold duration") }
        // This deadline starts BEFORE queueing. A timed-out caller must never
        // receive a delayed click when an earlier operation finally completes.
        let deadline = now() + 40
        let sequence = advanceMotionSequence()
        let operation = PointerMotionSequence()
        let operationSequence = operation.current
        defer { operation.advance() }
        try queue.sync {
            try requireIdlePointer()
            guard buttons == 0 else { throw InputError.pointerBusy }
            clearPointerEstimate()
            absolutePointerPosition = nil
            defer {
                clearPointerEstimate()
                absolutePointerPosition = nil
            }
            func requireCurrent() throws {
                guard now() < deadline, motionSequence.isCurrent(sequence),
                    visualPointerTransportAvailable,
                    screenSize.map({ $0() == size }) ?? true
                else { throw DeviceError("visual pointer operation expired or its device changed") }
            }
            try requireCurrent()
            let mayDeliver = { [self] in
                now() < deadline && !isRetired && inputIsAllowed() && motionSequence.isCurrent(sequence)
                    && operation.isCurrent(operationSequence)
                    && (screenSize.map({ $0() == size }) ?? true)
            }
            let controller = VisualPointerController(
                width: Int(size.width), height: Int(size.height),
                send: { dx, dy in
                    try requireCurrent()
                    guard (-127...127).contains(dx), (-127...127).contains(dy) else {
                        throw DeviceError("visual pointer report exceeds HID range")
                    }
                    self.visualReportSender(
                        .relativeMouse, HIDReportPayload.relativeMouse(buttons: 0, dx: dx, dy: dy), mayDeliver)
                    self.pause(self.step)
                },
                capture: { after, notBefore in
                    try requireCurrent()
                    guard self.reportDrainer(min(2, deadline - now())) else {
                        throw DeviceError("pointer reports did not drain; no click sent")
                    }
                    try requireCurrent()
                    // CoreBluetooth acceptance is not remote delivery. Wait for
                    // a later USB frame as well; the controller checks stability.
                    let frame = try capture(after, max(notBefore, now() + 0.15))
                    try requireCurrent()
                    return frame
                }, now: now)
            let target = CGPoint(
                x: min(size.width - 1, x * size.width),
                y: min(size.height - 1, y * size.height))
            let landing = try controller.land(to: target)
            try requireCurrent()
            var dragReports: [(dx: Int, dy: Int, wait: TimeInterval)] = []
            if let drag {
                guard landing.gainX.isFinite, landing.gainY.isFinite,
                    (0.005...256).contains(landing.gainX), (0.005...256).contains(landing.gainY)
                else { throw DeviceError("observed pointer gain cannot safely describe a drag") }
                let durations = swipeSegmentDurations(points: drag.points, duration: drag.duration)
                var residualX = 0.0
                var residualY = 0.0
                for (index, segmentDuration) in durations.enumerated() {
                    let count = segmentDuration / step
                    guard count.isFinite, count <= 256 else { throw DeviceError("visual swipe exceeds report budget") }
                    let steps = max(2, Int(count))
                    let from = drag.points[index]
                    let to = drag.points[index + 1]
                    for _ in 0..<steps {
                        residualX += (to.0 - from.0) * size.width / Double(steps) / landing.gainX
                        residualY += (to.1 - from.1) * size.height / Double(steps) / landing.gainY
                        guard residualX.isFinite, residualY.isFinite,
                            abs(residualX) <= 32512, abs(residualY) <= 32512
                        else { throw DeviceError("visual swipe exceeds report budget") }
                        let dx = Int(residualX.rounded())
                        let dy = Int(residualY.rounded())
                        residualX -= Double(dx)
                        residualY -= Double(dy)
                        let pieces = max(1, (max(abs(dx), abs(dy)) + 126) / 127)
                        guard dragReports.count + pieces <= 256 else {
                            throw DeviceError("visual swipe exceeds report budget")
                        }
                        var sentX = 0
                        var sentY = 0
                        for piece in 1...pieces {
                            let nextX = Int((Double(dx) * Double(piece) / Double(pieces)).rounded())
                            let nextY = Int((Double(dy) * Double(piece) / Double(pieces)).rounded())
                            let sx = nextX - sentX
                            let sy = nextY - sentY
                            dragReports.append((sx, sy, step + segmentDuration / Double(steps * pieces)))
                            sentX = nextX
                            sentY = nextY
                        }
                    }
                }
            }
            if hold != nil || drag != nil {
                let actionWait = (hold ?? step) + dragReports.reduce(0.0) { $0 + $1.wait }
                guard now() + actionWait + 0.5 < deadline else {
                    throw DeviceError("visual pointer click deadline exceeded; no click sent")
                }
                try requireCurrent()
                buttons = 1
                visualReportSender(.relativeMouse, HIDReportPayload.relativeMouse(buttons: 1), mayDeliver)
                defer {
                    if buttons != 0 {
                        buttons = 0
                        visualReportSender(.relativeMouse, HIDReportPayload.relativeMouse(buttons: 0), { true })
                        // Best effort only: a disconnected host cannot confirm
                        // release. Preserve the original operation error.
                        _ = reportDrainer(min(1, max(0, deadline - now())))
                    }
                }
                // Start hold timing only after BLE accepted the press. Otherwise
                // backpressure can queue press and release together as a tap.
                guard reportDrainer(min(2, max(0, deadline - now()))) else {
                    throw DeviceError("button press delivery could not be confirmed; release was requested")
                }
                try requireCurrent()
                guard now() + actionWait + 0.5 < deadline else {
                    throw DeviceError("visual pointer hold deadline exceeded; release was requested")
                }
                pause(hold ?? step)
                for report in dragReports {
                    try requireCurrent()
                    visualReportSender(
                        .relativeMouse,
                        HIDReportPayload.relativeMouse(buttons: 1, dx: report.dx, dy: report.dy), mayDeliver)
                    pause(report.wait)
                }
                buttons = 0
                // A release remains valid even if the capture disappeared or
                // a user interrupted us after the press; session checks remain.
                visualReportSender(.relativeMouse, HIDReportPayload.relativeMouse(buttons: 0), { true })
                guard reportDrainer(min(2, max(0, deadline - now()))) else {
                    throw DeviceError("click delivery could not be confirmed; button release was requested")
                }
                try requireCurrent()
            }
        }
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

    /// Follow a polyline with one press and release. `duration` is the total
    /// movement wait; positioning, button pacing and calibrated HID reports
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
            // iOS synthesizes the touch on the relative collection only, and
            // absolute movement cannot move a held touch. Uncalibrated hosts
            // position through one absolute report, then drag with estimated
            // relative counts; calibrated hosts drag on their measured curve.
            pointer(points[0].0, points[0].1)
            pause(step * 2)
            beginEstimatedDrag(x: points[0].0, y: points[0].1)
            button(down: true)
            pause(step)
            for (index, segmentDuration) in durations.enumerated() {
                let from = points[index]
                let to = points[index + 1]
                // Even a very short segment reaches its endpoint before the turn.
                let steps = max(2, Int(segmentDuration / step))
                for i in 1...steps {
                    let t = Double(i) / Double(steps)
                    dragMove(from.0 + (to.0 - from.0) * t, from.1 + (to.1 - from.1) * t, sequence: nil)
                    pause(segmentDuration / Double(steps))
                }
            }
            button(down: false)
            pause(step)
            endEstimatedDrag()
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
    func retireForCalibrationReload() throws {
        try queue.sync {
            try requireIdlePointer()
            advanceMotionSequence()
            clearPointerEstimate()
            lifecycleLock.withLock { retired = true }
        }
    }

    /// Gain-independent fallback for hosts whose absolute coordinates do not
    /// reach the two matching targets. Capture an entire rectangle on one input
    /// queue, and never press a button or use a speculative calibration.
    func relativePairingProbe(isReady: () -> Bool, capture: () -> [[UInt8]?]) throws -> [[[UInt8]]] {
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
                    relative(dx, dy)
                    pause(step)
                }
            }
            // First make room, then leave the top/left edges before capturing.
            // A clipped pointer cannot provide a complete return trajectory.
            try move(-8, 0, times: 12)
            try move(0, -8, times: 12)
            try move(8, 0, times: 4)
            try move(0, 8, times: 4)
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

    /// Keep native first-use measurement on this phone's normal input queue.
    /// Every report and capture rechecks ownership; disconnects and window
    /// cancellation invalidate the entire result before it can be saved.
    func measureRelativePointer(
        screenID: String, size: CGSize,
        isReady: @escaping () -> Bool,
        capture: @escaping () -> [UInt8]?,
        progress: @escaping (Int) -> Void = { _ in }
    ) throws -> RelativePointerCalibration {
        let sequence = backgroundSequence.current
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
                    throw InputError.pairingProbeUnavailable
                }
            }
            let measurement = AutomaticPointerCalibration(
                host: host, screenID: screenID, width: Int(size.width), height: Int(size.height),
                send: { dx, dy in
                    try requireCurrent()
                    self.relative(dx, dy)
                    self.pause(0.03)
                },
                capture: {
                    self.pause(0.4)
                    try requireCurrent()
                    guard let pixels = capture() else { throw InputError.pairingProbeUnavailable }
                    return PointerMotionObservation.Frame(
                        width: Int(size.width), height: Int(size.height), pixels: pixels)
                }, progress: progress)
            return try measurement.measure()
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
        wait: TimeInterval = 0.6,
        isReady: () -> Bool,
        capture: () -> [UInt8]?
    ) throws -> (before: [UInt8], after: [UInt8], returned: [UInt8]?) {
        let sequence = motionSequence.current
        let activity = backgroundSequence.current
        func probeIsReady() -> Bool { isReady() && backgroundSequence.isCurrent(activity) }
        return try queue.sync {
            guard !windowDragging, buttons == 0 else { throw InputError.pointerBusy }
            guard session != nil, probeIsReady(), motionSequence.isCurrent(sequence),
                wait.isFinite, wait >= 0,
                [firstPoint.x, firstPoint.y, secondPoint.x, secondPoint.y].allSatisfy({
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
            return (before, after, returned)
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
            // Position through the absolute collection, then press on the
            // relative collection: iOS synthesizes the touch there.
            self.pointer(x, y)
            // Use the same positioning interval as the coordinate tap API.
            self.pause(self.step * 2)
            self.beginEstimatedDrag(x: x, y: y)
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
            self.button(down: false)
            self.windowDragging = false
            self.endEstimatedDrag()
        }
    }

    /// Always clear the phone-side button state when the window loses focus or
    /// the mouse interaction is cancelled outside the view.
    func cancelPointer() {
        discardPendingMotion()
        queue.async {
            self.windowDragging = false
            self.endEstimatedDrag()
            if self.estimatedPosition == nil { self.relativeHomingReportIndex = 0 }
            guard self.buttons != 0 else { return }
            self.button(down: false)
            // The drag positioned the pointer through the absolute collection.
            // Clear that collection at its last position so no cancellation
            // path can leave a held button behind on either collection.
            if let position = self.absolutePointerPosition {
                self.send(
                    .absolutePointer,
                    HIDReportPayload.absolutePointer(buttons: 0, x: position.x, y: position.y))
            }
        }
    }

    /// A report subscription can disappear while a calibrated movement is being
    /// sent. Drop the predicted landing so the first movement after reconnect
    /// establishes a fresh origin instead of trusting reports that were lost.
    func invalidatePointerEstimate() {
        discardPendingMotion()
        queue.async {
            self.clearPointerEstimate()
        }
    }

    @discardableResult
    private func advanceMotionSequence() -> UInt64 {
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
            if dx != 0 || dy != 0 { clearPointerEstimate() }
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
                send(.relativeMouse, HIDReportPayload.relativeMouse(buttons: 1))
                pause(0.08)
                send(.relativeMouse, HIDReportPayload.relativeMouse(buttons: 0))
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
        let strokes = try text.map { character -> KeyboardMap.Stroke in
            guard let stroke = KeyboardMap.stroke(for: character) else { throw InputError.untypeable(character) }
            return stroke
        }
        if !strokes.isEmpty { discardPendingMotion() }
        queue.sync {
            for stroke in strokes {
                press(stroke)
            }
        }
    }

    /// A named key with optional modifiers, e.g. key("h", modifiers: ["cmd"]).
    func key(_ name: String, modifiers: [String]) throws {
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

    /// Movement while the pointer button is held: calibrated hosts follow
    /// their measured curve, uncalibrated hosts the estimated relative drag.
    /// Absolute reports can never carry this movement: iOS pins the touch to
    /// the relative collection, and absolute pointer moves — with or without
    /// button bits — do not move it (verified on iOS 26).
    fileprivate func dragMove(_ x: Double, _ y: Double, sequence: UInt64?) {
        if let calibration {
            moveCalibratedPointer(x, y, calibration: calibration, sequence: sequence)
        } else {
            moveEstimatedDragPointer(x, y, sequence: sequence)
        }
    }

    /// Anchors the uncalibrated drag estimate at the press position.
    fileprivate func beginEstimatedDrag(x: Double, y: Double) {
        guard calibration == nil, let size = screenSize?() else { return }
        dragPosition = CGPoint(x: x * size.width, y: y * size.height)
        lastEstimatedMovement = nil
    }

    fileprivate func endEstimatedDrag() {
        dragPosition = nil
        lastEstimatedMovement = nil
    }

    /// Built-in acceleration prior for drags without a measured curve:
    /// physical pixels per sustained report of each relative count, measured
    /// on a 750-pixel 2x iPhone. iOS pointer acceleration is superlinear, so
    /// a flat pixels-per-count guess makes fast drags overshoot badly. The
    /// prior is scaled by the live screen's width against the reference;
    /// a saved calibration always replaces it.
    static let estimatedDragCurve: [Double] = [
        0, 0.53125, 1.28125, 2.1875, 3.28125, 4.5625, 6.03125, 7.65625,
        9.5, 11.508771929824562, 13.708333333333334, 16.1, 18.647058823529413,
        21.4, 24.37037037037037, 27.47826086956522, 30.761904761904763,
        34.31578947368421, 38, 41.86666666666667, 46, 50.15384615384615,
        54.72727272727273, 59.2, 64.2, 69.11111111111111, 74.25, 79.75,
        85.42857142857143, 91.14285714285714, 97.33333333333333, 103.33333333333333,
        109.6,
    ]
    /// Screen width the built-in drag curve was measured on.
    private static let estimatedDragReferenceWidth = 750.0
    /// Largest relative count per estimated drag report; the largest measured
    /// value in the built-in curve.
    static let estimatedDragMaxCount = 32

    /// Follows the drag target with relative reports, one axis per report like
    /// unverified calibrated profiles. Each report picks the count whose
    /// curve-predicted distance best covers the remaining error, so slow and
    /// fast drags track the mouse at the same fidelity; each new target
    /// corrects whatever the real curve did differently.
    fileprivate func moveEstimatedDragPointer(_ x: Double, _ y: Double, sequence: UInt64?) {
        guard shouldContinueMotion(sequence),
            let size = screenSize?(),
            var position = dragPosition
        else { return }
        let target = CGPoint(
            x: max(0, min(size.width - 1, x * size.width)),
            y: max(0, min(size.height - 1, y * size.height)))
        let scale = size.width / Self.estimatedDragReferenceWidth
        let tolerance = Self.estimatedDragCurve[1] * scale / 2
        while shouldContinueMotion(sequence) {
            let remainingX = target.x - position.x
            let remainingY = target.y - position.y
            guard abs(remainingX) > tolerance || abs(remainingY) > tolerance else { break }
            let preferredAxis: Int
            if let last = lastEstimatedMovement {
                preferredAxis = last.dx != 0 ? 1 : 0
            } else {
                preferredAxis = abs(remainingX) >= abs(remainingY) ? 0 : 1
            }
            var report = (dx: 0, dy: 0)
            for axis in [preferredAxis, 1 - preferredAxis] {
                let error = axis == 0 ? remainingX : remainingY
                guard abs(error) > tolerance else { continue }
                // Largest count whose predicted distance still fits the error,
                // so the estimate never overshoots its own prediction.
                var count = 1
                for candidate in 1...Self.estimatedDragMaxCount
                where Self.estimatedDragCurve[candidate] * scale <= abs(error) + tolerance {
                    count = candidate
                }
                let distance = Self.estimatedDragCurve[count] * scale
                if axis == 0 {
                    report.dx = error < 0 ? -count : count
                    position.x = max(0, min(size.width - 1, position.x + (error < 0 ? -distance : distance)))
                } else {
                    report.dy = error < 0 ? -count : count
                    position.y = max(0, min(size.height - 1, position.y + (error < 0 ? -distance : distance)))
                }
                break
            }
            guard report.dx != 0 || report.dy != 0 else { break }
            relative(report.dx, report.dy)
            lastEstimatedMovement = RelativePointerCalibration.Movement(dx: report.dx, dy: report.dy)
            pause(step)
        }
        dragPosition = position
        // Keep the absolute bookkeeping where the phone most likely shows the
        // pointer, so a later hover or cancellation does not jump it.
        let unit = Double(HIDReportMap.absoluteMax)
        absolutePointerPosition = (
            UInt16(max(0, min(unit, (position.x / size.width * unit).rounded()))),
            UInt16(max(0, min(unit, (position.y / size.height * unit).rounded())))
        )
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
        send(.relativeMouse, HIDReportPayload.relativeMouse(buttons: buttons, dx: dx, dy: dy))
    }

    fileprivate func button(down: Bool) {
        buttons = down ? 1 : 0
        // Buttons live on the relative collection: iOS synthesizes touches
        // from relative button reports, never from absolute pointer buttons.
        send(.relativeMouse, HIDReportPayload.relativeMouse(buttons: buttons))
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
        dragPosition = nil
        lastEstimatedMovement = nil
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

    fileprivate func send(_ id: ReportID, _ bytes: [UInt8]) {
        guard !isRetired else { return }
        // A capture can be invalidated while an input is queued. Stop stale
        // movement and presses, while still releasing any held button or key.
        guard inputIsAllowed() || (id != .absolutePointer && bytes.allSatisfy { $0 == 0 }) else { return }
        reportSender(id, bytes)
    }

}

extension DeviceInput {
    enum InputError: Error, CustomStringConvertible {
        case untypeable(Character)
        case unknownKey(String)
        case pointerBusy
        case calibrationMismatch
        case invalidSwipe(String)
        case pairingProbeUnavailable

        var description: String {
            let table = StringsAPI.current
            return switch self {
            case .untypeable(let c): table.untypeable(String(reflecting: c))
            case .unknownKey(let k): table.unknownKey(k)
            case .pointerBusy: table.pointerBusy
            case .calibrationMismatch: table.calibrationMismatch
            case .invalidSwipe(let reason): table.invalidSwipePrefix(reason)
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
