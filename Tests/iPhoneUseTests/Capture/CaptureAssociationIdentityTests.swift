import XCTest

@testable import iPhoneUse

final class CaptureAssociationIdentityTests: XCTestCase {
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
