import Foundation

/// Serializes idle transitions on the main queue, alongside capture discovery timers and windows.
final class QuietModeActivityController {
    static let shared = QuietModeActivityController()
    private let runningLock = NSLock()
    private var running = false
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var lastActivity: TimeInterval = 0
    private var openWindows = false
    private var suspended = false
    private var activeRequests = 0
    private let timeout: TimeInterval
    private let mode: () -> AppRunMode
    private let now: () -> TimeInterval
    private let suspendCapture: () -> ScreenCaptureStopResult
    private let resumeCapture: () -> Void
    private let checkIdleUnplug: () -> Void
    private var shutdownClean = true
    private var resumedAt: TimeInterval?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        mode: @escaping () -> AppRunMode = { AppRunModeStore.shared.mode },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        suspendCapture: @escaping () -> ScreenCaptureStopResult = {
            let result = ScreenCaptureManager.shared.suspendForIdle(waitTimeout: Application.shutdownWaitTimeout)
            ScreenCaptureManager.shared.onScreensChanged?()
            return result
        },
        checkIdleUnplug: @escaping () -> Void = {
            if ScreenCaptureManager.shared.clearIdleUSBDemandIfUnplugged() {
                ScreenCaptureManager.shared.onScreensChanged?()
            }
        },
        resumeCapture: @escaping () -> Void = {
            DeviceRegistry.shared.prewakeBluetoothForIdleResume()
            ScreenCaptureManager.shared.start()
        }
    ) {
        self.mode = mode
        self.now = now
        self.suspendCapture = suspendCapture
        self.resumeCapture = resumeCapture
        self.checkIdleUnplug = checkIdleUnplug
        let value = environment["IPHONE_USE_IDLE_TIMEOUT"].flatMap(Double.init)
        timeout = value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 60
    }

    func start() {
        precondition(Thread.isMainThread)
        guard timer == nil else { return }
        lastActivity = now()
        runningLock.withLock { running = true }
        observer = NotificationCenter.default.addObserver(
            forName: AppRunModeStore.didChangeNotification, object: AppRunModeStore.shared, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.modeChanged()
        }
        let timer = Timer(timeInterval: min(timeout, 1), repeats: true) { [weak self] _ in self?.checkIdle() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        precondition(Thread.isMainThread)
        runningLock.withLock { running = false }
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func modeChanged() {
        if mode() == .desktop { wake() }
        lastActivity = now()
    }

    func setOpenWindows(_ open: Bool) {
        precondition(Thread.isMainThread)
        guard openWindows != open else { return }
        openWindows = open
        if open { wake() }
    }

    func requestStarted() -> Bool {
        guard runningLock.withLock({ running }) else { return false }
        return onMain {
            guard self.timer != nil else { return false }
            self.activeRequests += 1
            return self.wake()
        }
    }

    func requestFinished() {
        guard runningLock.withLock({ running }) else { return }
        onMain {
            guard self.timer != nil else { return }
            self.activeRequests = max(0, self.activeRequests - 1)
            self.lastActivity = self.now()
        }
    }

    var isSuspended: Bool {
        guard runningLock.withLock({ running }) else { return false }
        return onMain { self.suspended }
    }

    /// Follow-up requests share the wake window even after the first request resumes capture.
    var isWithinWakeGraceWindow: Bool {
        guard runningLock.withLock({ running }) else { return false }
        return onMain {
            guard let resumedAt = self.resumedAt else { return false }
            return self.now() - resumedAt < 6.0
        }
    }

    @discardableResult
    private func wake() -> Bool {
        lastActivity = now()
        guard suspended else { return false }
        if !shutdownClean {
            log("idle capture resuming after incomplete shutdown; startup reconciliation will gate discovery")
        }
        shutdownClean = true
        suspended = false
        resumedAt = now()
        resumeCapture()
        return true
    }

    func checkIdle() {
        if suspended {
            checkIdleUnplug()
            return
        }
        guard mode() == .residentQuiet, !openWindows, activeRequests == 0,
            now() - lastActivity >= timeout
        else { return }
        suspended = true
        resumedAt = nil
        let result = suspendCapture()
        shutdownClean = result.isClean
        if !result.isClean {
            log(
                "idle capture shutdown incomplete: captureDrained=\(result.captureDrained), usbRestored=\(result.usbRestored)"
            )
        }
    }

    private func onMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync(execute: body)
    }
}
