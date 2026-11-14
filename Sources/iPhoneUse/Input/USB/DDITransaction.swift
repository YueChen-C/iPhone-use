import Foundation

protocol DDITransactionDevice {
    func inspect(physicalID: String) throws -> NativeDDIInspection.Report
    func unmount(physicalID: String) throws
    func mount(physicalID: String, bundle: URL) throws
}

/// Explicit, local offline transaction. A phase is persisted before every
/// potentially ambiguous operation; failures never cause an automatic retry.
enum DDITransaction {
    struct Snapshot: Codable {
        let source: DDISourceRecord
        let files: [DDIBundlePreflight.FileDigest]
        let build: String
        let coreDeviceVersion: String
        let imageSHA384: String
    }
    struct Plan: Codable {
        let schemaVersion: Int
        let id: UUID
        let physicalID: String
        let productType: String
        let productVersion: String
        let productBuild: String
        let currentImage: NativeDDIInspection.MountedImage
        let candidate: Snapshot
        let baseline: Snapshot
        let sourcePolicy: String
        let inputPolicy: String
        let created: Date
    }
    enum Phase: String, Codable {
        case preflight, authorized, unmounting, unmounted, mounting, mounted, independentlyVerified
        case restoreAuthorized, restoreUnmounting, restoreUnmounted, restoring, restoreMounted, restored
    }
    struct Event: Codable { let phase: Phase; let time: Date; let error: String? }
    struct Journal: Codable {
        let planSHA256: String
        var events: [Event]
        var phase: Phase { events.last!.phase }

        func validate() throws {
            guard !events.isEmpty, events.count <= 512,
                  events[0].phase == .preflight, events[0].error == nil else {
                throw DDIManagementError("DDI journal must begin with preflight and stay within its event limit")
            }
            for (previous, event) in zip(events, events.dropFirst()) {
                // Failed operations append an error at the last persisted phase.
                // Only explicit recovery may proceed from such an uncertain result.
                if event.phase == previous.phase, event.phase != .preflight,
                   let error = event.error, !error.isEmpty { continue }
                if event.phase == .restoreAuthorized, event.error == nil { continue }
                guard previous.error == nil, event.error == nil else {
                    throw DDIManagementError("DDI journal cannot continue an uncertain operation without explicit recovery")
                }
                switch (previous.phase, event.phase) {
                case (.preflight, .authorized), (.authorized, .unmounting),
                     (.unmounting, .unmounted), (.unmounted, .mounting),
                     (.mounting, .mounted), (.mounted, .independentlyVerified),
                     (.restoreAuthorized, .restoreUnmounting), (.restoreUnmounting, .restoreUnmounted),
                     (.restoreUnmounted, .restoring), (.restoring, .restoreMounted),
                     (.restoreMounted, .restored): break
                default: throw DDIManagementError("DDI journal contains an invalid phase transition; no replay or barrier cleanup")
                }
            }
        }
    }
    struct Summary: Encodable {
        let transactionPath: String
        let planSHA256: String
        let plan: Plan
        let journal: Journal
        let deviceMutation: Bool
        let inputSent = false
        let sourceAuthenticated = false
    }
    static let sourcePolicy = "explicit-local-research-source-risk-acknowledgement; not Apple provenance authentication or distribution clearance"
    static let inputPolicy = "offline-exclusive-app-input-lease; all legacy app processes closed; never automatic input restart"

    static func plan(physicalID: String, candidate: DDIBundlePreflight, baseline: DDIBundlePreflight,
                     directory: URL, device: DDITransactionDevice) throws -> Summary {
        try NativeDDIInspection.validateIdentity(physicalID)
        let current = try device.inspect(physicalID: physicalID)
        guard current.physicalID == physicalID, candidate.productType == current.productType,
              baseline.productType == current.productType else { throw DDIManagementError("DDI plan device/product identity mismatch") }
        let image = try developerImage(current)
        let candidateSnapshot = try snapshot(candidate), baselineSnapshot = try snapshot(baseline)
        guard matches(image, baselineSnapshot) else {
            throw DDIManagementError("Baseline payload must match the currently mounted build/version/image signature")
        }
        let store = try DDITransactionStore(root: directory, create: true)
        try store.stage(candidate, name: "candidate"); try store.stage(baseline, name: "baseline")
        let plan = Plan(schemaVersion: 1, id: UUID(), physicalID: physicalID, productType: current.productType,
                        productVersion: current.productVersion, productBuild: current.productBuild,
                        currentImage: image, candidate: candidateSnapshot, baseline: baselineSnapshot,
                        sourcePolicy: sourcePolicy, inputPolicy: inputPolicy, created: Date())
        let data = try DDITransactionStore.encoded(plan), hash = DDITransactionStore.digest(data)
        let journal = Journal(planSHA256: hash, events: [Event(phase: .preflight, time: Date(), error: nil)])
        try store.write(data, name: "plan.json"); try store.write(journal, name: "journal.json")
        return Summary(transactionPath: directory.path, planSHA256: hash, plan: plan, journal: journal, deviceMutation: false)
    }

    static func status(directory: URL) throws -> Summary {
        let store = try DDITransactionStore(root: directory, create: false)
        let (plan, hash, journal) = try load(store)
        return Summary(transactionPath: directory.path, planSHA256: hash, plan: plan, journal: journal,
                       deviceMutation: journal.events.contains { [.unmounting, .restoreUnmounting].contains($0.phase) })
    }

    static func execute(directory: URL, confirmation: String, acknowledgeSourceRisk: Bool, restore: Bool,
                        device: DDITransactionDevice, markPending: (DDIProcessLease.Pending) throws -> Void,
                        clearPending: (DDIProcessLease.Pending) throws -> Void) throws -> Summary {
        let store = try DDITransactionStore(root: directory, create: false)
        let (plan, hash, loadedJournal) = try load(store)
        guard acknowledgeSourceRisk, confirmation == hash else {
            throw DDIManagementError("Explicit local source-risk acknowledgement and exact plan SHA256 required")
        }
        var journal = loadedJournal
        guard restore || journal.phase == .preflight else {
            throw DDIManagementError("DDI operation already attempted; do not replay. Inspect journal and explicitly restore if needed")
        }
        // Apply requires both snapshots. Recovery must remain usable when only
        // the candidate is corrupt: it needs the pristine baseline, not a
        // second valid copy of the payload being discarded.
        if !restore { _ = try validateSnapshot(plan.candidate, name: "candidate", plan: plan, store: store) }
        _ = try validateSnapshot(plan.baseline, name: "baseline", plan: plan, store: store)
        let target = restore ? plan.baseline : plan.candidate
        let current = try device.inspect(physicalID: plan.physicalID)
        try validateDevice(current, plan)
        if !restore {
            guard try developerImage(current) == plan.currentImage else {
                throw DDIManagementError("Mounted image changed after planning; create a new plan")
            }
        } else {
            // Interrupted calls can leave no mount, baseline or candidate.
            // An unrelated/new image is not silently overwritten by recovery.
            let images = current.mountedImages.filter { $0.mountPath == "/System/Developer" && $0.isMounted }
            guard images.count <= 1, images.allSatisfy({ matches($0, plan.baseline) || matches($0, plan.candidate) }) else {
                throw DDIManagementError("Recovery found an unrelated mounted image; inspect manually")
            }
        }
        let pending = DDIProcessLease.Pending(transactionPath: directory.path, planSHA256: hash)
        func record(_ phase: Phase, error: String? = nil) throws {
            journal.events.append(Event(phase: phase, time: Date(), error: error))
            try store.write(journal, name: "journal.json")
        }
        // The persistent barrier precedes every device operation, including a
        // kill/timeout between journal updates. Only verified success clears it.
        try markPending(pending)
        if restore, journal.phase == .restored, matches(try developerImage(current), plan.baseline) {
            // A crash between persisted verification and clearing pending is
            // recoverable without repeating any device operation.
            try clearPending(pending)
            return Summary(transactionPath: directory.path, planSHA256: hash, plan: plan, journal: journal, deviceMutation: false)
        }
        try record(restore ? .restoreAuthorized : .authorized)
        do {
            try record(restore ? .restoreUnmounting : .unmounting)
            if current.mountedImages.contains(where: { $0.mountPath == "/System/Developer" && $0.isMounted }) {
                try device.unmount(physicalID: plan.physicalID)
            }
            let unmounted = try device.inspect(physicalID: plan.physicalID)
            try validateDevice(unmounted, plan)
            guard !unmounted.mountedImages.contains(where: { $0.mountPath == "/System/Developer" && $0.isMounted }) else {
                throw DDIManagementError("DDI unmount return was not independently confirmed")
            }
            try record(restore ? .restoreUnmounted : .unmounted)
            let name = restore ? "baseline" : "candidate"
            let bundle = try validateSnapshot(target, name: name, plan: plan, store: store)
            try record(restore ? .restoring : .mounting)
            try device.mount(physicalID: plan.physicalID, bundle: bundle)
            try record(restore ? .restoreMounted : .mounted)
            let mounted = try device.inspect(physicalID: plan.physicalID)
            try validateDevice(mounted, plan)
            guard matches(try developerImage(mounted), target) else {
                throw DDIManagementError("DDI mount return was not independently confirmed against build/version/signature")
            }
            try record(restore ? .restored : .independentlyVerified)
            try clearPending(pending)
        } catch {
            // Keep the ambiguous phase and exact error. Never automatically
            // remount/retry, clear the barrier or restart a touch session.
            let phase = journal.phase
            try? record(phase, error: "\(error)")
            throw DDIManagementError("DDI \(journal.phase.rawValue): \(error). Recovery: iphone-use ddi restore \(directory.path) --confirm \(hash) --acknowledge-source-risk")
        }
        return Summary(transactionPath: directory.path, planSHA256: hash, plan: plan, journal: journal, deviceMutation: true)
    }

    private static func load(_ store: DDITransactionStore) throws -> (Plan, String, Journal) {
        let data = try store.read("plan.json"), hash = DDITransactionStore.digest(data)
        let plan = try JSONDecoder().decode(Plan.self, from: data)
        let journal = try store.read(Journal.self, name: "journal.json")
        try NativeDDIInspection.validateIdentity(plan.physicalID)
        guard plan.schemaVersion == 1, journal.planSHA256 == hash,
              plan.sourcePolicy == sourcePolicy, plan.inputPolicy == inputPolicy else {
            throw DDIManagementError("DDI transaction plan/journal does not match")
        }
        try journal.validate()
        return (plan, hash, journal)
    }
    private static func snapshot(_ report: DDIBundlePreflight) throws -> Snapshot {
        let manifestData = try DDILocalFile.metadata(root: URL(fileURLWithPath: report.bundlePath), path: "Restore/BuildManifest.plist")
        guard DDITransactionStore.digest(manifestData) == report.source.sha256["Restore/BuildManifest.plist"] else {
            throw DDIManagementError("DDI manifest changed after preflight")
        }
        let manifest = try PropertyListSerialization.propertyList(from: manifestData, format: nil) as? [String: Any]
        let identities = manifest?["BuildIdentities"] as? [[String: Any]]
        let identity = identities?.first { $0["Ap,ProductType"] as? String == report.productType }
        let components = identity?["Manifest"] as? [String: Any]
        let image = components?["PersonalizedDMG"] as? [String: Any]
        let info = image?["Info"] as? [String: Any]
        guard let path = info?["Path"] as? String,
              let digest = report.files.first(where: { $0.path == "Restore/" + path })?.sha384 else {
            throw DDIManagementError("DDI snapshot image digest missing")
        }
        return Snapshot(source: report.source, files: report.files, build: report.build,
                        coreDeviceVersion: report.coreDeviceVersion, imageSHA384: digest)
    }
    private static func validateSnapshot(_ snapshot: Snapshot, name: String, plan: Plan, store: DDITransactionStore) throws -> URL {
        let url = store.root.appendingPathComponent(name)
        let report = try DDIBundlePreflight.inspect(bundle: url, source: snapshot.source, productType: plan.productType)
        guard report.files == snapshot.files, report.build == snapshot.build,
              report.coreDeviceVersion == snapshot.coreDeviceVersion else {
            throw DDIManagementError("DDI transaction snapshot changed")
        }
        return url
    }
    private static func validateDevice(_ report: NativeDDIInspection.Report, _ plan: Plan) throws {
        guard report.physicalID == plan.physicalID, report.productType == plan.productType,
              report.productVersion == plan.productVersion, report.productBuild == plan.productBuild,
              report.frameworkVersion == NativeDDIInspection.frameworkVersion else {
            throw DDIManagementError("DDI physical device/OS/host changed; no fallback")
        }
    }
    private static func developerImage(_ report: NativeDDIInspection.Report) throws -> NativeDDIInspection.MountedImage {
        let images = report.mountedImages.filter { $0.mountPath == "/System/Developer" && $0.isMounted }
        guard images.count == 1, let image = images.first else { throw DDIManagementError("Exactly one mounted developer image required") }
        return image
    }
    private static func matches(_ image: NativeDDIInspection.MountedImage, _ snapshot: Snapshot) -> Bool {
        guard image.imageType == "Personalized", image.build == snapshot.build, image.version == snapshot.coreDeviceVersion,
              let signature = image.imageSignature.flatMap({ Data(base64Encoded: $0) }), signature.count == 48 else { return false }
        return signature.map { String(format: "%02x", $0) }.joined() == snapshot.imageSHA384
    }
}
