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
            framebuffer: ScreenVideoPixelDimensions,
            encoded: ScreenVideoPixelDimensions
        )] = [
            (.init(width: 540, height: 960), 1, .init(width: 540, height: 960), .init(width: 540, height: 960)),
            (.init(width: 603, height: 1_312), 1, .init(width: 603, height: 1_312), .init(width: 602, height: 1_310)),
            (.init(width: 640, height: 480), 1, .init(width: 640, height: 480), .init(width: 640, height: 480)),
            (.init(width: 640, height: 1_392), 1, .init(width: 640, height: 1_392), .init(width: 640, height: 1_392)),
            (.init(width: 720, height: 1_280), 1, .init(width: 720, height: 1_280), .init(width: 720, height: 1_280)),
            (.init(width: 750, height: 1_334), 1, .init(width: 750, height: 1_334), .init(width: 750, height: 1_334)),
            (.init(width: 400, height: 300), 2, .init(width: 800, height: 600), .init(width: 800, height: 600)),
            (.init(width: 800, height: 600), 1, .init(width: 800, height: 600), .init(width: 800, height: 600)),
            (.init(width: 400, height: 870), 2, .init(width: 800, height: 1_740), .init(width: 800, height: 1_740)),
            (.init(width: 800, height: 1_740), 1, .init(width: 800, height: 1_740), .init(width: 800, height: 1_740)),
            (.init(width: 405, height: 720), 2, .init(width: 810, height: 1_440), .init(width: 810, height: 1_440)),
            (.init(width: 810, height: 1_440), 1, .init(width: 810, height: 1_440), .init(width: 810, height: 1_440)),
            (.init(width: 414, height: 896), 2, .init(width: 828, height: 1_792), .init(width: 828, height: 1_792)),
            (.init(width: 828, height: 1_792), 1, .init(width: 828, height: 1_792), .init(width: 828, height: 1_792)),
            (.init(width: 450, height: 800), 2, .init(width: 900, height: 1_600), .init(width: 900, height: 1_600)),
            (.init(width: 900, height: 1_600), 1, .init(width: 900, height: 1_600), .init(width: 900, height: 1_600)),
            (.init(width: 512, height: 384), 2, .init(width: 1_024, height: 768), .init(width: 1_024, height: 768)),
            (.init(width: 1_024, height: 768), 1, .init(width: 1_024, height: 768), .init(width: 1_024, height: 768)),
            (.init(width: 512, height: 1_113), 2, .init(width: 1_024, height: 2_226), .init(width: 1_024, height: 2_226)),
            (.init(width: 1_024, height: 2_226), 1, .init(width: 1_024, height: 2_226), .init(width: 1_024, height: 2_226)),
            (.init(width: 540, height: 960), 2, .init(width: 1_080, height: 1_920), .init(width: 1_080, height: 1_920)),
            (.init(width: 1_080, height: 1_920), 1, .init(width: 1_080, height: 1_920), .init(width: 1_080, height: 1_920)),
            (.init(width: 540, height: 1_170), 2, .init(width: 1_080, height: 2_340), .init(width: 1_080, height: 2_340)),
            (.init(width: 1_080, height: 2_340), 1, .init(width: 1_080, height: 2_340), .init(width: 1_080, height: 2_340)),
            (.init(width: 603, height: 1_311), 2, .init(width: 1_206, height: 2_622), .init(width: 1_206, height: 2_622)),
            (.init(width: 1_206, height: 2_622), 1, .init(width: 1_206, height: 2_622), .init(width: 1_206, height: 2_622)),
            (.init(width: 640, height: 480), 2, .init(width: 1_280, height: 960), .init(width: 1_280, height: 960)),
            (.init(width: 672, height: 504), 2, .init(width: 1_344, height: 1_008), .init(width: 1_344, height: 1_008)),
            (.init(width: 800, height: 600), 2, .init(width: 1_600, height: 1_200), .init(width: 1_600, height: 1_200)),
        ]

        for mode in modes {
            let dimensions = ScreenVideoSourceDimensionPolicy.sourceDimensions(
                vendorID: 0x6F73,
                productID: 0x1718,
                logicalDimensions: mode.logical,
                filterContentWidth: Double(mode.logical.width),
                filterContentHeight: Double(mode.logical.height),
                pointPixelScale: mode.scale,
                coreGraphicsLogicalDimensions: mode.logical,
                coreGraphicsPixelDimensions: mode.framebuffer
            )

            XCTAssertEqual(dimensions, mode.framebuffer)
            XCTAssertEqual(
                try ScreenVideoOutputPolicy.outputDimensions(
                    source: mode.framebuffer,
                    maximumWidth: 1_920
                ),
                mode.encoded
            )
        }
    }

    func testOrdinaryDisplayIgnoresFilterPixelScale() {
        let dimensions = ScreenVideoSourceDimensionPolicy.sourceDimensions(
            vendorID: 0x610,
            productID: 0xA0E1,
            logicalDimensions: .init(width: 1_512, height: 982),
            filterContentWidth: .nan,
            filterContentHeight: 0,
            pointPixelScale: .nan,
            coreGraphicsLogicalDimensions: .init(width: 0, height: 0),
            coreGraphicsPixelDimensions: .init(width: 0, height: 0)
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
                    pointPixelScale: snapshot.scale,
                    coreGraphicsLogicalDimensions: logical,
                    coreGraphicsPixelDimensions: .init(width: 1_080, height: 2_340)
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
                pointPixelScale: 4,
                coreGraphicsLogicalDimensions: .init(width: .max, height: .max),
                coreGraphicsPixelDimensions: .init(width: .max, height: .max)
            )
        )
    }

    func testOwnedDisplayUsesCurrentCoreGraphicsFramebufferDespiteStaleFilterScale() {
        let logical = ScreenVideoPixelDimensions(width: 540, height: 1_170)

        XCTAssertEqual(
            ScreenVideoSourceDimensionPolicy.sourceDimensions(
                vendorID: 0x6F73,
                productID: 0x1718,
                logicalDimensions: logical,
                filterContentWidth: 540,
                filterContentHeight: 1_170,
                pointPixelScale: 1,
                coreGraphicsLogicalDimensions: logical,
                coreGraphicsPixelDimensions: .init(width: 1_080, height: 2_340)
            ),
            .init(width: 1_080, height: 2_340)
        )
    }

    func testOwnedDisplayAcceptsOnlyReconciledFilterAndCoreGraphicsFramebuffer() {
        let logical = ScreenVideoPixelDimensions(width: 540, height: 1_170)

        XCTAssertEqual(
            ScreenVideoSourceDimensionPolicy.sourceDimensions(
                vendorID: 0x6F73,
                productID: 0x1718,
                logicalDimensions: logical,
                filterContentWidth: 540,
                filterContentHeight: 1_170,
                pointPixelScale: 2,
                coreGraphicsLogicalDimensions: logical,
                coreGraphicsPixelDimensions: .init(width: 1_080, height: 2_340)
            ),
            .init(width: 1_080, height: 2_340)
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
