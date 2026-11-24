import XCTest

@testable import iPhoneUse

final class CaptureContinuityTests: XCTestCase {
    private let se = CGSize(width: 750, height: 1334)
    private let twelve = CGSize(width: 1170, height: 2532)

    private let a = CaptureScreenMapping.USBRoute(entryID: 1, sourceInstance: UUID(), run: 0)
    private let b = CaptureScreenMapping.USBRoute(entryID: 2, sourceInstance: UUID(), run: 0)

    func testRepeatedPeerReattachKeepsProvenSameSizeRoute() {
        let sizes = ["A": twelve, "B": twelve]
        let proven = ["A": a, "B": b]
        XCTAssertEqual(CaptureScreenMapping.continuing(
            proven: proven, current: ["B": b], expectedSizes: sizes, sourceSizes: ["B": twelve]), ["B": "B"])
        for entry in 10..<18 {
            let reattached = CaptureScreenMapping.USBRoute(entryID: UInt64(entry), sourceInstance: a.sourceInstance, run: 0)
            XCTAssertEqual(CaptureScreenMapping.continuing(
                proven: proven, current: ["A": reattached, "B": b], expectedSizes: sizes, sourceSizes: sizes), ["B": "B"])
        }
    }

    func testPeerUnplugAndDiscoveryGapsKeepOnlyThePositivelyAttestedRouteAcrossCycles() {
        let aPin = USBValeriaConfigurator.PinnedUSBDevice(registryEntryID: a.entryID, serial: "A")
        let bPin = USBValeriaConfigurator.PinnedUSBDevice(registryEntryID: b.entryID, serial: "B")
        let known = ["A": a.entryID, "B": b.entryID]
        let sizes = ["A": twelve, "B": twelve]
        for _ in 0..<8 {
            var reads = Set<UInt64>()
            let entries = CaptureScreenMapping.refreshUSBEntries(
                discoveredIDs: ["B"], devices: nil, confirmedEntries: known,
                readEntry: { id in reads.insert(id); return id == self.b.entryID ? bPin : nil })
            XCTAssertEqual(entries, ["B": b.entryID], "unknown topology must not clear B or cache A")
            XCTAssertEqual(reads, [a.entryID, b.entryID])

            let rediscoveredEntries = CaptureScreenMapping.refreshUSBEntries(
                discoveredIDs: ["A"], devices: [aPin, bPin], confirmedEntries: known,
                readEntry: { _ in XCTFail("no redundant direct probe for a complete scan"); return nil })
            let surviving = CaptureScreenMapping.continuing(
                proven: ["B": b], current: rediscoveredEntries.compactMapValues { $0 == b.entryID ? b : nil },
                expectedSizes: sizes, sourceSizes: ["B": twelve])
            XCTAssertEqual(surviving, ["B": "B"], "AVFoundation's omission does not delete the live B session")
        }
    }

    func testUnknownTopologyCannotReviveAnUnprovenOrChangedRoute() {
        let bPin = USBValeriaConfigurator.PinnedUSBDevice(registryEntryID: b.entryID, serial: "B")
        let wrong = USBValeriaConfigurator.PinnedUSBDevice(registryEntryID: b.entryID, serial: "C")
        for result in [nil, wrong] {
            XCTAssertTrue(CaptureScreenMapping.refreshUSBEntries(
                discoveredIDs: ["B"], devices: nil, confirmedEntries: ["B": b.entryID],
                readEntry: { _ in result }).isEmpty)
        }
        XCTAssertTrue(CaptureScreenMapping.refreshUSBEntries(
            discoveredIDs: ["B"], devices: nil, confirmedEntries: ["B": a.entryID],
            readEntry: { _ in bPin }).isEmpty, "a re-enumerated USB service requires fresh proof")
        XCTAssertTrue(CaptureScreenMapping.refreshUSBEntries(
            discoveredIDs: ["B"], devices: [], confirmedEntries: ["B": b.entryID],
            readEntry: { _ in XCTFail("known empty is not an enumeration error"); return bPin }).isEmpty)
    }

    func testGeometryAndUSBSerialCannotProveAColdStartRoute() {
        XCTAssertTrue(CaptureScreenMapping.continuing(
            proven: [:], current: ["A": a, "B": b], expectedSizes: ["A": se, "B": twelve],
            sourceSizes: ["A": se, "B": twelve]).isEmpty)
    }

    func testRunInstanceAndGeometryChangesInvalidateOnlyTheChangedRoute() {
        let sizes = ["A": twelve, "B": twelve]
        let proven = ["A": a, "B": b]
        for invalidated in [
            CaptureScreenMapping.USBRoute(entryID: a.entryID, sourceInstance: UUID(), run: 0),
            CaptureScreenMapping.USBRoute(entryID: a.entryID, sourceInstance: a.sourceInstance, run: 1),
        ] {
            XCTAssertEqual(CaptureScreenMapping.continuing(
                proven: proven, current: ["A": invalidated, "B": b], expectedSizes: sizes, sourceSizes: sizes), ["B": "B"])
        }
        for sourceSizes in [["B": twelve], ["A": se, "B": twelve]] {
            XCTAssertEqual(CaptureScreenMapping.continuing(
                proven: proven, current: proven, expectedSizes: sizes, sourceSizes: sourceSizes), ["B": "B"])
        }
    }

    func testUSBEntriesRejectDuplicateSerialAliasesRegistryIDsAndMissingSerials() {
        let aID = "00008030-00001234ABCDEF00"
        let alias = "0000803000001234abcdef00"
        let bID = "00008030-0000111122223333"
        let aPin = USBValeriaConfigurator.PinnedUSBDevice(registryEntryID: 1, serial: alias)
        let bPin = USBValeriaConfigurator.PinnedUSBDevice(registryEntryID: 2, serial: bID)
        let missing = USBValeriaConfigurator.PinnedUSBDevice(registryEntryID: 3, serial: nil)
        let duplicate = USBValeriaConfigurator.PinnedUSBDevice(registryEntryID: 1, serial: nil)
        XCTAssertEqual(CaptureScreenMapping.usbEntries(sourceIDs: [aID, bID], devices: [aPin, missing, bPin]), [aID: 1, bID: 2])
        XCTAssertEqual(CaptureScreenMapping.usbEntries(sourceIDs: [aID, alias, bID], devices: [aPin, bPin]), [bID: 2])
        XCTAssertEqual(CaptureScreenMapping.usbEntries(sourceIDs: [aID, bID], devices: [aPin, bPin, duplicate]), [bID: 2])
    }
}

final class CaptureAssociationIdentityTests: XCTestCase {
    func testProvisionalPixelsAreHiddenUntilIndependentVerificationAndOnRemap() {
        let gate = CaptureDisplayIdentity(confirmed: false)
        var reads = 0
        func pixels() -> String? { reads += 1; return "peer-phone-pixels" }
        XCTAssertNil(gate.read(pixels))
        XCTAssertEqual(reads, 0, "unverified render/screenshot must not read the source")
        gate.setConfirmed(true)
        XCTAssertEqual(gate.read { "exact-phone-pixels" }, "exact-phone-pixels")
        gate.setConfirmed(false)
        XCTAssertNil(gate.read(pixels), "topology changes revoke the old session as well")
        XCTAssertFalse(gate.isConfirmed)
        gate.setConfirmed(true)
        XCTAssertEqual(gate.read { "reverified-phone-pixels" }, "reverified-phone-pixels")
        XCTAssertNil(gate.read {
            gate.setConfirmed(false)
            gate.setConfirmed(true)
            return "encoded-before-topology-changed"
        }, "an old in-flight snapshot cannot survive revoke/reverify")
    }

    func testPendingCrossMappedReconnectNeverDisplaysANominalPeerFrame() {
        let a = UUID(), b = UUID()
        let previous: [String: CaptureScreenMapping.Source] = [
            "SE": .init(id: "12", instance: b), "12": .init(id: "SE", instance: a),
        ]
        let sources = ["SE": a, "12": UUID()]
        let provisional = CaptureScreenMapping.previews(confirmed: [:], previous: previous, sources: sources)
        let gates = provisional.mapValues { _ in CaptureDisplayIdentity(confirmed: false) }
        for (phone, source) in provisional {
            XCTAssertNil(gates[phone]?.read { source })
        }
        let confirmed = CaptureScreenMapping.previews(
            confirmed: ["SE": "SE", "12": "12"], previous: previous, sources: sources)
        XCTAssertEqual(confirmed, ["SE": "SE", "12": "12"])
        for (phone, source) in confirmed {
            gates[phone]?.setConfirmed(true)
            XCTAssertEqual(gates[phone]?.read { source }, phone)
        }
    }

    func testSurvivingPhoneRetainsBluetoothProofWhileCaptureInputIsPaused() {
        var identities = CaptureAssociationIdentity()
        let original = identities.identity(physicalID: "SE", isConfirmed: true)
        identities.retain(physicalIDs: ["SE", "new"])
        let pending = identities.identity(physicalID: "SE", isConfirmed: false)
        XCTAssertEqual(pending, original)
        XCTAssertFalse(ScreenCaptureIdentityState.pending.permitsAssociation(identityVerified: true))
        XCTAssertFalse(ScreenCaptureIdentityState.failed.permitsAssociation(identityVerified: true))
        XCTAssertEqual(identities.identity(physicalID: "SE", isConfirmed: true), original)
    }

    func testReverifiedVideoSourceSwapPreservesDistinctPhysicalBluetoothIdentities() {
        var identities = CaptureAssociationIdentity()
        let a = UUID()
        let b = UUID()
        let first = identities.identity(physicalID: "SE", isConfirmed: true)
        let other = identities.identity(physicalID: "new", isConfirmed: true)
        let mapping = CaptureScreenMapping.previews(
            confirmed: ["SE": "new", "new": "SE"],
            previous: ["SE": .init(id: "SE", instance: a), "new": .init(id: "new", instance: b)],
            sources: ["SE": a, "new": b])
        XCTAssertEqual(mapping, ["SE": "new", "new": "SE"])
        XCTAssertNotEqual(first, other)
        XCTAssertEqual(identities.identity(physicalID: "SE", isConfirmed: true), first)
        XCTAssertEqual(identities.identity(physicalID: "new", isConfirmed: true), other)
    }

    func testDisconnectForgetsPhysicalIdentityEvenIfTheOtherSourceSurvives() {
        var identities = CaptureAssociationIdentity()
        let original = identities.identity(physicalID: "SE", isConfirmed: true)
        identities.retain(physicalIDs: ["new"])
        XCTAssertNotEqual(identities.identity(physicalID: "SE", isConfirmed: true), original)
    }

    func testUnconfirmedUSBReconnectCannotReviveItsPreviousProof() {
        var identities = CaptureAssociationIdentity()
        let original = identities.identity(physicalID: "SE", isConfirmed: true)
        identities.retain(physicalIDs: [])
        identities.retain(physicalIDs: ["SE"])
        XCTAssertNotEqual(identities.identity(physicalID: "SE", isConfirmed: false), original)
        XCTAssertNotEqual(identities.identity(physicalID: "SE", isConfirmed: true), original)
    }

    func testRemovingOtherPhoneAndItsVideoSourceKeepsSurvivorsBluetoothIdentity() {
        var identities = CaptureAssociationIdentity()
        let original = identities.identity(physicalID: "B", isConfirmed: true)
        let a = UUID()
        let b = UUID()
        let previous: [String: CaptureScreenMapping.Source] = [
            "A": .init(id: "B", instance: b), "B": .init(id: "A", instance: a),
        ]
        identities.retain(physicalIDs: ["B"])
        XCTAssertEqual(
            CaptureScreenMapping.previews(confirmed: [:], previous: previous, sources: ["B": b]),
            ["B": "B"])
        XCTAssertEqual(identities.identity(physicalID: "B", isConfirmed: true), original)
    }

    func testNewUnconfirmedPhoneCannotInheritAnExistingMotionProof() {
        var identities = CaptureAssociationIdentity()
        let known = identities.identity(physicalID: "SE", isConfirmed: true)
        XCTAssertNotEqual(identities.identity(physicalID: "new", isConfirmed: false), known)
    }
}

final class CaptureScreenMappingTests: XCTestCase {
    func testAddingAndRemovingAnotherPhoneKeepsSurvivingRemappedSources() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let previous: [String: CaptureScreenMapping.Source] = [
            "A": .init(id: "B", instance: b), "B": .init(id: "A", instance: a),
        ]
        let adding = CaptureScreenMapping.previews(
            confirmed: [:], previous: previous, sources: ["A": a, "B": b, "C": c])
        XCTAssertEqual(adding, ["A": "B", "B": "A", "C": "C"])
        XCTAssertEqual(
            CaptureScreenMapping.previews(
                confirmed: [:], previous: previous, sources: ["A": a, "B": b]),
            ["A": "B", "B": "A"])
    }

    func testRemovedPhoneCannotKeepOrStealTheSurvivorsSource() {
        let b = UUID()
        XCTAssertEqual(
            CaptureScreenMapping.previews(
                confirmed: [:], previous: ["A": .init(id: "B", instance: b)], sources: ["B": b]),
            ["B": "B"])
    }

    func testRecreatedSourceCannotKeepItsPreviousPhysicalMapping() {
        let a = UUID()
        let oldB = UUID()
        let newB = UUID()
        XCTAssertEqual(
            CaptureScreenMapping.previews(
                confirmed: [:],
                previous: ["A": .init(id: "B", instance: oldB)],
                sources: ["A": a, "B": newB]),
            ["A": "A", "B": "B"])
    }

    func testVerifiedMappingTakesPriorityAndPreviewsNeverShareASource() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let mapping = CaptureScreenMapping.previews(
            confirmed: ["A": "B"],
            previous: ["B": .init(id: "B", instance: b), "C": .init(id: "C", instance: c)],
            sources: ["A": a, "B": b, "C": c])
        XCTAssertEqual(mapping, ["A": "B", "B": "A", "C": "C"])
        XCTAssertEqual(Set(mapping.values).count, mapping.count)
    }
}
