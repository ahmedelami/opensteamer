import XCTest

@testable import CaptureCore

final class ScreenVideoOutputPolicyTests: XCTestCase {
    func testCaptureStartupRejectsFramebufferResolutionDrift() {
        XCTAssertTrue(
            ScreenVideoSourceDimensionPolicy.isStableAcrossStart(
                before: .init(width: 1_206, height: 2_622),
                after: .init(width: 1_206, height: 2_622)
            )
        )
        XCTAssertFalse(
            ScreenVideoSourceDimensionPolicy.isStableAcrossStart(
                before: .init(width: 1_206, height: 2_622),
                after: .init(width: 1_080, height: 2_340)
            )
        )
    }

    func testOwnedDisplayRequirementAcceptsExactSoleMainIdentity() {
        XCTAssertTrue(
            ScreenVideoDisplayRequirementPolicy.isSatisfied(
                ownedDisplayRequirement,
                by: ownedDisplaySnapshot
            )
        )
    }

    func testOwnedDisplayRequirementRejectsRecycledIDIdentity() {
        var snapshot = ownedDisplaySnapshot
        snapshot = ScreenVideoDisplaySnapshot(
            displayID: snapshot.displayID,
            vendorID: 0xFFFF,
            productID: snapshot.productID,
            serialNumber: snapshot.serialNumber,
            isOnline: snapshot.isOnline,
            isActive: snapshot.isActive,
            mainDisplayID: snapshot.mainDisplayID,
            onlineDisplayIDs: snapshot.onlineDisplayIDs
        )

        XCTAssertFalse(
            ScreenVideoDisplayRequirementPolicy.isSatisfied(
                ownedDisplayRequirement,
                by: snapshot
            )
        )
    }

    func testOwnedDisplayRequirementRejectsTopologyDrift() {
        let snapshot = ScreenVideoDisplaySnapshot(
            displayID: ownedDisplaySnapshot.displayID,
            vendorID: ownedDisplaySnapshot.vendorID,
            productID: ownedDisplaySnapshot.productID,
            serialNumber: ownedDisplaySnapshot.serialNumber,
            isOnline: true,
            isActive: true,
            mainDisplayID: ownedDisplaySnapshot.displayID,
            onlineDisplayIDs: [ownedDisplaySnapshot.displayID, 99]
        )

        XCTAssertFalse(
            ScreenVideoDisplayRequirementPolicy.isSatisfied(
                ownedDisplayRequirement,
                by: snapshot
            )
        )
    }

    func testOrdinaryDisplayKeepsScreenCaptureKitLogicalDimensions() {
        let dimensionKind = ScreenVideoSourceDimensionPolicy.dimensionKind(
            vendorID: 0x610,
            productID: 0xA0E1
        )

        XCTAssertEqual(dimensionKind, .logical)
    }

    func testOpenSteamerPhoneDisplayUsesFramebufferPixels() {
        let dimensionKind = ScreenVideoSourceDimensionPolicy.dimensionKind(
            vendorID: 0x6F73,
            productID: 0x1717
        )

        XCTAssertEqual(dimensionKind, .framebufferPixels)
    }

    func testOpenSteamerCombinedDisplayUsesFramebufferPixels() {
        let dimensionKind = ScreenVideoSourceDimensionPolicy.dimensionKind(
            vendorID: 0x6F73,
            productID: 0x1718
        )

        XCTAssertEqual(dimensionKind, .framebufferPixels)
    }

    func testMatchingProductFromAnotherVendorKeepsLogicalDimensions() {
        let dimensionKind = ScreenVideoSourceDimensionPolicy.dimensionKind(
            vendorID: 0xFFFF,
            productID: 0x1717
        )

        XCTAssertEqual(dimensionKind, .logical)
    }

    func testUnknownOpenSteamerProductKeepsLogicalDimensions() {
        let dimensionKind = ScreenVideoSourceDimensionPolicy.dimensionKind(
            vendorID: 0x6F73,
            productID: 0x1719
        )

        XCTAssertEqual(dimensionKind, .logical)
    }

    func testPhoneRetinaModeUsesFullFramebufferPixels() throws {
        let output = try ScreenVideoOutputPolicy.outputDimensions(
            source: .init(width: 1_206, height: 2_622),
            maximumWidth: 1_920
        )

        XCTAssertEqual(output, .init(width: 1_206, height: 2_622))
    }

    func testLandscapeFramebufferScalesWithinWidthCap() throws {
        let output = try ScreenVideoOutputPolicy.outputDimensions(
            source: .init(width: 3_840, height: 2_160),
            maximumWidth: 1_920
        )

        XCTAssertEqual(output, .init(width: 1_920, height: 1_080))
    }

    func testOddDimensionsRoundDownForVideoChromaPlanes() throws {
        let output = try ScreenVideoOutputPolicy.outputDimensions(
            source: .init(width: 1_205, height: 2_621),
            maximumWidth: 1_920
        )

        XCTAssertEqual(output.width, 1_204)
        XCTAssertEqual(output.height % 2, 0)
        XCTAssertLessThanOrEqual(output.height, 2_621)
    }

    func testInvalidDimensionsFailClosed() {
        XCTAssertThrowsError(
            try ScreenVideoOutputPolicy.outputDimensions(
                source: .init(width: 1, height: 2_622),
                maximumWidth: 1_920
            )
        ) { error in
            XCTAssertEqual(error as? ScreenVideoOutputPolicyError, .invalidDimensions)
        }
    }

    private let ownedDisplayRequirement = ScreenVideoDisplayRequirement(
        vendorID: 0x6F73,
        productID: 0x1718,
        serialNumber: 1,
        requiresSoleMainDisplay: true
    )

    private let ownedDisplaySnapshot = ScreenVideoDisplaySnapshot(
        displayID: 42,
        vendorID: 0x6F73,
        productID: 0x1718,
        serialNumber: 1,
        isOnline: true,
        isActive: true,
        mainDisplayID: 42,
        onlineDisplayIDs: [42]
    )
}
