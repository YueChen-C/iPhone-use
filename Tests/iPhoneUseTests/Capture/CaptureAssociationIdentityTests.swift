import XCTest

@testable import iPhoneUse

final class CaptureContinuityTests: XCTestCase {
    private let se = CGSize(width: 750, height: 1334)
    private let twelve = CGSize(width: 1170, height: 2532)

    func testRemovingAResolvesBWithoutScreenshotAndRepeatedReattachPreservesIt() {
        let expected = ["A": twelve, "B": se]
        XCTAssertEqual(CaptureScreenMapping.continuing(
            physicalIDs: ["B"], expectedSizes: expected, sourceSizes: ["B": se]), ["B": "B"])
        for _ in 0..<8 {
            XCTAssertEqual(CaptureScreenMapping.continuing(
                physicalIDs: ["A", "B"], expectedSizes: expected,
                sourceSizes: ["A": twelve, "B": se]), ["A": "A", "B": "B"])
        }
    }

    func testSwappedNominalStreamsUseLearnedPhysicalDimensionsNotNominalUIDs() {
        XCTAssertEqual(CaptureScreenMapping.continuing(
            physicalIDs: ["A", "B"], expectedSizes: ["A": twelve, "B": se],
            sourceSizes: ["A": se, "B": twelve]), ["A": "B", "B": "A"])
    }

    func testUnknownOrEqualSizedPeersCannotBeApprovedByDimensions() {
        XCTAssertTrue(CaptureScreenMapping.continuing(
            physicalIDs: ["A", "B"], expectedSizes: ["B": se],
            sourceSizes: ["A": twelve, "B": se]).isEmpty)
        XCTAssertTrue(CaptureScreenMapping.continuing(
            physicalIDs: ["A", "B"], expectedSizes: ["A": se, "B": se],
            sourceSizes: ["A": se, "B": se]).isEmpty)
        XCTAssertTrue(CaptureScreenMapping.continuing(
            physicalIDs: ["B"], expectedSizes: ["A": se, "B": se],
            sourceSizes: ["B": se]).isEmpty, "a removed equal-sized peer may leave ambiguous pixels")
    }

    func testMissingOrAmbiguousStreamDoesNotDisableAnotherProvenRoute() {
        XCTAssertEqual(CaptureScreenMapping.continuing(
            physicalIDs: ["A", "B"], expectedSizes: ["A": twelve, "B": se],
            sourceSizes: ["A": se]), ["B": "A"])
        XCTAssertEqual(CaptureScreenMapping.continuing(
            physicalIDs: ["A", "B", "C"], expectedSizes: ["A": twelve, "B": se, "C": se],
            sourceSizes: ["A": twelve, "B": se, "C": se]), ["A": "A"])
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
