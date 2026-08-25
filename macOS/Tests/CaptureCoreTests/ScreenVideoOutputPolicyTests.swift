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

    func testOwnedDisplayResolvesEverySupportedSelectedFramebuffer() {
        let modes: [(
            logical: ScreenVideoPixelDimensions,
            scale: Double,
            framebuffer: ScreenVideoPixelDimensions
        )] = [
            (.init(width: 603, height: 1_311), 2, .init(width: 1_206, height: 2_622)),
            (.init(width: 540, height: 1_170), 2, .init(width: 1_080, height: 2_340)),
            (.init(width: 540, height: 960), 2, .init(width: 1_080, height: 1_920)),
            (.init(width: 414, height: 896), 2, .init(width: 828, height: 1_792)),
            (.init(width: 750, height: 1_334), 1, .init(width: 750, height: 1_334)),
            (.init(width: 1_024, height: 768), 1, .init(width: 1_024, height: 768)),
        ]

        for mode in modes {
            let dimensions = ScreenVideoSourceDimensionPolicy.sourceDimensions(
                vendorID: 0x6F73,
                productID: 0x1718,
                logicalDimensions: mode.logical,
                filterContentWidth: Double(mode.logical.width),
                filterContentHeight: Double(mode.logical.height),
                pointPixelScale: mode.scale
            )

            XCTAssertEqual(dimensions, mode.framebuffer)
        }
    }

    func testOrdinaryDisplayIgnoresFilterPixelScale() {
        let dimensions = ScreenVideoSourceDimensionPolicy.sourceDimensions(
            vendorID: 0x610,
            productID: 0xA0E1,
            logicalDimensions: .init(width: 1_512, height: 982),
            filterContentWidth: .nan,
            filterContentHeight: 0,
            pointPixelScale: .nan
        )

        XCTAssertEqual(dimensions, .init(width: 1_512, height: 982))
    }

    func testOwnedDisplayRejectsInvalidFilterGeometry() {
        let logical = ScreenVideoPixelDimensions(width: 540, height: 1_170)
        let invalidSnapshots: [(width: Double, height: Double, scale: Double)] = [
            (.nan, 1_170, 2),
            (540, 0, 2),
            (540, 1_170, .nan),
            (540, 1_170, 0),
            (540, 1_170, 4.1),
            (539, 1_170, 2),
        ]

        for snapshot in invalidSnapshots {
            XCTAssertNil(
                ScreenVideoSourceDimensionPolicy.sourceDimensions(
                    vendorID: 0x6F73,
                    productID: 0x1718,
                    logicalDimensions: logical,
                    filterContentWidth: snapshot.width,
                    filterContentHeight: snapshot.height,
                    pointPixelScale: snapshot.scale
                )
            )
        }
    }

    func testOwnedDisplayRejectsFramebufferOverflow() {
        XCTAssertNil(
            ScreenVideoSourceDimensionPolicy.sourceDimensions(
                vendorID: 0x6F73,
                productID: 0x1718,
                logicalDimensions: .init(width: .max, height: .max),
                filterContentWidth: Double(Int.max),
                filterContentHeight: Double(Int.max),
                pointPixelScale: 4
            )
        )
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
