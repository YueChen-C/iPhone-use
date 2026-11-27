import Foundation

/// Presentation-only snapshots. IDs are full USB identities, never names or prefixes.
struct WorkbenchDevice: Equatable {
    let id: String
    var name: String
    var connected: Bool
    var backend: InputBackendKind
    var status: String
    var shortcuts: Set<ControlShortcut> = []
    var detail: String = ""
    var screenSize: CGSize? = nil
    var productType: String? = nil
    /// Pointer mode is decided from measured landings, never the iOS version.
    var offersPointerRecalibration: Bool { connected && backend == .ble }
}

struct WorkbenchState {
    enum Layout { case grid, focus }
    private(set) var devices: [WorkbenchDevice] = []
    private(set) var selectedID: String?
    var query = "" { didSet { if query != oldValue { gridPage = 0 } } }
    var layout: Layout = .grid { didSet { revealSelection() } }
    private(set) var pageCapacity = 3
    private var gridPage = 0

    var selected: WorkbenchDevice? { devices.first { $0.id == selectedID } }
    var matching: [WorkbenchDevice] {
        devices.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
    }
    var pageSize: Int { layout == .focus ? 1 : pageCapacity }
    var pageCount: Int { max(1, (matching.count + pageSize - 1) / pageSize) }
    var pageIndex: Int {
        layout == .focus ? (matching.firstIndex { $0.id == selectedID } ?? 0) : min(gridPage, pageCount - 1)
    }
    var visible: [WorkbenchDevice] {
        if layout == .focus { return matching.filter { $0.id == selectedID } }
        return Array(matching.dropFirst(pageIndex * pageSize).prefix(pageSize))
    }
    var hasPreviousPage: Bool { pageIndex > 0 }
    var hasNextPage: Bool { pageIndex + 1 < pageCount }

    mutating func setPageCapacity(_ capacity: Int) {
        let bounded = min(3, max(1, capacity))
        guard bounded != pageCapacity else { return }
        pageCapacity = bounded
        revealSelection()
    }

    /// Resolve a full identity before the root saves drafts, cancels old input,
    /// and selects the first device on the destination page.
    func pageTarget(offset: Int) -> String? {
        let destination = pageIndex + offset
        guard destination >= 0, destination < pageCount else { return nil }
        let index = destination * pageSize
        return matching.indices.contains(index) ? matching[index].id : nil
    }

    private mutating func revealSelection() {
        if let index = matching.firstIndex(where: { $0.id == selectedID }) { gridPage = index / pageCapacity }
        else { gridPage = min(gridPage, pageCount - 1) }
    }

    mutating func reconcile(_ connected: [WorkbenchDevice]) {
        let byID = Dictionary(connected.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        devices = devices.map { old in
            if let current = byID[old.id] { return current }
            var disconnected = old
            disconnected.connected = false
            disconnected.shortcuts = []
            disconnected.status = StringsWorkbench.current.disconnected
            return disconnected
        }
        let known = Set(devices.map(\.id))
        devices += byID.values.filter { !known.contains($0.id) }.sorted {
            $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name
        }
        if selectedID == nil { selectedID = devices.first?.id }
        gridPage = min(gridPage, pageCount - 1)
    }

    /// Remove presentation state only. A future exact-ID discovery can add it again.
    @discardableResult
    mutating func removeDisconnected(_ exactID: String) -> Bool {
        guard let index = devices.firstIndex(where: { $0.id == exactID && !$0.connected }) else { return false }
        devices.remove(at: index)
        if selectedID == exactID {
            let visible = matching
            selectedID = visible.first(where: \.connected)?.id ?? visible.first?.id
                ?? devices.first(where: \.connected)?.id ?? devices.first?.id
        }
        revealSelection()
        return true
    }

    @discardableResult
    mutating func select(_ exactID: String) -> Bool {
        guard devices.contains(where: { $0.id == exactID }) else { return false }
        selectedID = exactID
        revealSelection()
        return true
    }
}

/// A quiet background service never presents a workbench on startup/hotplug.
struct WorkbenchVisibility {
    private(set) var isOpen = false
    mutating func shouldPresent(mode: AppRunMode, reason: ControlWindowUpdateReason) -> Bool {
        guard !isOpen, mode == .desktop || reason == .userRequest else { return false }
        isOpen = true
        return true
    }
    mutating func close(mode: AppRunMode, hasIndependentWindows: Bool) -> Bool {
        isOpen = false
        return mode == .desktop && !hasIndependentWindows
    }
}

/// Presentation gating only; capture ownership remains with the existing shared service.
enum WorkbenchRenderPolicy {
    static func shouldRun(active: Bool, visible: Bool, independent: Bool) -> Bool {
        active && visible && !independent
    }
}

/// Hardware identifiers, never device names or screen-size guesses, select the enclosure.
enum WorkbenchPhoneModel: String, CaseIterable {
    case classicHome, roundedNotch, flatNotch, dynamicIsland, neutral

    static func resolve(productType: String?) -> Self {
        guard let productType else { return .neutral }
        if [
            "iPhone8,4", "iPhone12,8", "iPhone14,6", "iPhone8,1", "iPhone8,2",
            "iPhone9,1", "iPhone9,2", "iPhone9,3", "iPhone9,4", "iPhone10,1",
            "iPhone10,2", "iPhone10,4", "iPhone10,5",
        ].contains(productType) {
            return .classicHome
        }
        if [
            "iPhone10,3", "iPhone10,6", "iPhone11,2", "iPhone11,4", "iPhone11,6",
            "iPhone11,8", "iPhone12,1", "iPhone12,3", "iPhone12,5",
        ].contains(productType) {
            return .roundedNotch
        }
        if [
            "iPhone13,1", "iPhone13,2", "iPhone13,3", "iPhone13,4", "iPhone14,2",
            "iPhone14,3", "iPhone14,4", "iPhone14,5", "iPhone14,7", "iPhone14,8",
        ].contains(productType) {
            return .flatNotch
        }
        if [
            "iPhone15,2", "iPhone15,3", "iPhone15,4", "iPhone15,5", "iPhone16,1", "iPhone16,2",
            "iPhone17,1", "iPhone17,2", "iPhone17,3", "iPhone17,4",
        ].contains(productType) {
            return .dynamicIsland
        }
        return .neutral
    }
}

/// Export only independently identified pixels. A live preview alone is not proof
/// of physical identity, and a save panel must not preserve a stale capture lease.
enum WorkbenchScreenshotCapture {
    enum Failure: Error, Equatable, LocalizedError, CustomStringConvertible {
        case disconnected, identityUnverified, notReady

        var description: String { errorDescription ?? "" }

        var errorDescription: String? {
            switch self {
            case .disconnected: return StringsWorkbench.current.disconnected
            case .identityUnverified: return StringsWorkbench.current.screenshotIdentityUnverified
            case .notReady: return StringsWorkbench.current.screenshotNotReady
            }
        }
    }

    static func validate(isCurrent: () -> Bool, identityConfirmed: () -> Bool) throws {
        guard isCurrent() else { throw Failure.disconnected }
        guard identityConfirmed() else { throw Failure.identityUnverified }
    }

    static func capture(
        isCurrent: () -> Bool, identityConfirmed: () -> Bool, snapshot: () -> Data?
    ) throws -> Data {
        try validate(isCurrent: isCurrent, identityConfirmed: identityConfirmed)
        guard let bytes = snapshot() else { throw Failure.notReady }
        // Encoding can overlap a disconnect/remap; never write those bytes.
        try validate(isCurrent: isCurrent, identityConfirmed: identityConfirmed)
        return bytes
    }
}

/// One read-only metadata query per capture identity, outside AppKit and the render timer.
struct WorkbenchHardwareIdentity: Decodable, Equatable {
    let physicalID: String
    let productType: String
    let productVersion: String

    var displayName: String {
        let known = [
            "iPhone8,4": "iPhone SE", "iPhone12,8": "iPhone SE (2nd gen)",
            "iPhone14,6": "iPhone SE (3rd gen)", "iPhone13,1": "iPhone 12 mini",
            "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro",
            "iPhone13,4": "iPhone 12 Pro Max",
        ]
        return known[productType] ?? productType
    }
    static func read(physicalID: String, executable: URL) -> Self? {
        // Reuse the established exact-USB identity inspector; no input, pairing or DDI mutation.
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("iphone-use-model-\(UUID()).json")
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
            let file = try? FileHandle(forWritingTo: output)
        else { return nil }
        defer {
            try? file.close()
            try? FileManager.default.removeItem(at: output)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["ddi", "inspect", physicalID]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = file
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        guard finished.wait(timeout: .now() + 8) == .success else {
            if process.isRunning { process.terminate() }
            _ = finished.wait(timeout: .now() + 1)
            return nil
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0,
            let size = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 65536,
            let data = try? Data(contentsOf: output),
            let identity = try? JSONDecoder().decode(Self.self, from: data),
            identity.physicalID == physicalID, !identity.productType.isEmpty
        else { return nil }
        return identity
    }
}
