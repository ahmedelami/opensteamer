import CoreGraphics
import XCTest

@testable import VirtualDisplayCore

final class VirtualDisplayConfigurationTests: XCTestCase {
    func testIPhone17ProPresetHasStableIdentityAndExactNativeFirstMode() throws {
        let configuration = VirtualDisplayConfiguration.iPhone17Pro

        XCTAssertEqual(configuration.name, "opensteamer Phone Display")
        XCTAssertEqual(configuration.vendorID, 0x6F73)
        XCTAssertEqual(configuration.productID, 0x1717)
        XCTAssertEqual(configuration.serialNumber, 1)
        XCTAssertEqual(configuration.maximumWidth, 1_206)
        XCTAssertEqual(configuration.maximumHeight, 2_622)
        XCTAssertEqual(configuration.displaySettingsHiDPI, 2)
        XCTAssertEqual(
            configuration.modes.first,
            .init(logicalWidth: 603, logicalHeight: 1_311)
        )
        XCTAssertEqual(
            configuration.requiredResolvedModes.first,
            .init(
                logicalWidth: 603,
                logicalHeight: 1_311,
                pixelWidth: 1_206,
                pixelHeight: 2_622
            )
        )
        XCTAssertTrue(
            configuration.requiredResolvedModes.allSatisfy {
                $0.pixelWidth <= configuration.maximumWidth
                    && $0.pixelHeight <= configuration.maximumHeight
                    && $0.logicalHeight > $0.logicalWidth
            })
        XCTAssertNoThrow(try configuration.validate())
    }

    func testConfigurationRejectsDuplicateAdvertisedModes() {
        XCTAssertThrowsError(
            try makeConfiguration(
                modes: [
                    .init(logicalWidth: 603, logicalHeight: 1_311),
                    .init(logicalWidth: 603, logicalHeight: 1_311),
                ]
            )
        ) { error in
            XCTAssertEqual(error as? VirtualDisplayConfigurationError, .duplicateMode)
        }
    }

    func testConfigurationRejectsAdvertisedModeOutsideMaximumDimensions() {
        XCTAssertThrowsError(
            try makeConfiguration(
                modes: [.init(logicalWidth: 1_207, logicalHeight: 1_311)]
            )
        ) { error in
            XCTAssertEqual(
                error as? VirtualDisplayConfigurationError,
                .invalidModeDimensions
            )
        }
    }

    func testConfigurationRejectsResolvedFramebufferOutsideMaximumDimensions() {
        XCTAssertThrowsError(
            try makeConfiguration(
                requiredResolvedModes: [
                    .init(
                        logicalWidth: 603,
                        logicalHeight: 1_311,
                        pixelWidth: 1_207,
                        pixelHeight: 2_622
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? VirtualDisplayConfigurationError,
                .invalidResolvedModeDimensions
            )
        }
    }

    func testConfigurationRejectsNonFinitePhysicalDimensions() {
        XCTAssertThrowsError(
            try makeConfiguration(physicalWidthMillimeters: .infinity)
        ) { error in
            XCTAssertEqual(
                error as? VirtualDisplayConfigurationError,
                .invalidPhysicalDimensions
            )
        }
    }

    func testConfigurationRejectsUnsupportedHiDPISetting() {
        XCTAssertThrowsError(try makeConfiguration(displaySettingsHiDPI: 0)) { error in
            XCTAssertEqual(
                error as? VirtualDisplayConfigurationError,
                .invalidDisplaySettingsHiDPI
            )
        }
    }

    func testCurrentMacOSRuntimeExportsVirtualDisplayClassesWhenCompatibilityCheckIsAvailable()
        throws
    {
        guard VirtualDisplayOwner.runtimeIsAvailable else {
            throw XCTSkip("This macOS runtime does not expose the optional compatibility classes")
        }
        XCTAssertTrue(VirtualDisplayOwner.runtimeIsAvailable)
    }

    func testHeadlessPlaceholderPreservesDesktopAndRequiresExactSelectableChoices() throws {
        let configuration = try XCTUnwrap(
            HeadlessDesktopReplacement.makeConfiguration(
                vendorID: HeadlessDesktopReplacement.appleHeadlessVendorID,
                productID: HeadlessDesktopReplacement.appleHeadlessProductID,
                logicalWidth: 1_080,
                logicalHeight: 1_920,
                pixelWidth: 1_080,
                pixelHeight: 1_920
            )
        )

        XCTAssertEqual(configuration.name, "opensteamer Display")
        XCTAssertEqual(configuration.displaySettingsHiDPI, 1)
        XCTAssertEqual(configuration.maximumWidth, 1_206)
        XCTAssertEqual(configuration.maximumHeight, 2_622)
        XCTAssertEqual(configuration.modes.count, 9)
        XCTAssertEqual(
            configuration.modes.first,
            .init(logicalWidth: 1_080, logicalHeight: 1_920)
        )
        XCTAssertEqual(
            configuration.requiredResolvedModes.first,
            .init(
                logicalWidth: 1_080,
                logicalHeight: 1_920,
                pixelWidth: 1_080,
                pixelHeight: 1_920
            )
        )
        XCTAssertEqual(
            configuration.restoredDesktopMode,
            .init(
                logicalWidth: 1_080,
                logicalHeight: 1_920,
                pixelWidth: 1_080,
                pixelHeight: 1_920
            )
        )
        XCTAssertEqual(
            configuration.requiredResolvedModes,
            [
                .init(
                    logicalWidth: 1_080,
                    logicalHeight: 1_920,
                    pixelWidth: 1_080,
                    pixelHeight: 1_920
                ),
                .init(
                    logicalWidth: 603,
                    logicalHeight: 1_311,
                    pixelWidth: 1_206,
                    pixelHeight: 2_622
                ),
                .init(
                    logicalWidth: 540,
                    logicalHeight: 1_170,
                    pixelWidth: 1_080,
                    pixelHeight: 2_340
                ),
                .init(
                    logicalWidth: 540,
                    logicalHeight: 960,
                    pixelWidth: 1_080,
                    pixelHeight: 1_920
                ),
                .init(
                    logicalWidth: 414,
                    logicalHeight: 896,
                    pixelWidth: 828,
                    pixelHeight: 1_792
                ),
                .init(
                    logicalWidth: 750,
                    logicalHeight: 1_334,
                    pixelWidth: 750,
                    pixelHeight: 1_334
                ),
            ]
        )
    }

    func testEverySelectableFramebufferAspectFitsTheNativePhoneViewportAtFullWidth() throws {
        let configuration = try XCTUnwrap(
            HeadlessDesktopReplacement.makeConfiguration(
                vendorID: HeadlessDesktopReplacement.appleHeadlessVendorID,
                productID: HeadlessDesktopReplacement.appleHeadlessProductID,
                logicalWidth: 1_080,
                logicalHeight: 1_920,
                pixelWidth: 1_080,
                pixelHeight: 1_920
            )
        )
        let nativePhoneViewport = CGSize(width: 603, height: 1_311)

        for mode in configuration.requiredResolvedModes {
            let scale = min(
                nativePhoneViewport.width / CGFloat(mode.pixelWidth),
                nativePhoneViewport.height / CGFloat(mode.pixelHeight)
            )
            let renderedWidth = CGFloat(mode.pixelWidth) * scale
            XCTAssertEqual(
                renderedWidth,
                nativePhoneViewport.width,
                accuracy: 0.001,
                "Selectable framebuffer did not fit viewport width: \(mode)"
            )
        }
    }

    func testTwoXHeadlessPlaceholderPreservesItsResolvedCurrentMode() throws {
        let configuration = try XCTUnwrap(
            HeadlessDesktopReplacement.makeConfiguration(
                vendorID: HeadlessDesktopReplacement.appleHeadlessVendorID,
                productID: HeadlessDesktopReplacement.appleHeadlessProductID,
                logicalWidth: 540,
                logicalHeight: 960,
                pixelWidth: 1_080,
                pixelHeight: 1_920
            )
        )

        XCTAssertEqual(
            configuration.modes.first,
            .init(logicalWidth: 1_080, logicalHeight: 1_920)
        )
        XCTAssertEqual(
            configuration.requiredResolvedModes.first,
            .init(
                logicalWidth: 540,
                logicalHeight: 960,
                pixelWidth: 1_080,
                pixelHeight: 1_920
            )
        )
    }

    func testLandscapeHeadlessPlaceholderKeepsPortraitNativeModeAndRestorationMapping()
        throws
    {
        let configuration = try XCTUnwrap(
            HeadlessDesktopReplacement.makeConfiguration(
                vendorID: HeadlessDesktopReplacement.appleHeadlessVendorID,
                productID: HeadlessDesktopReplacement.appleHeadlessProductID,
                logicalWidth: 1_920,
                logicalHeight: 1_080,
                pixelWidth: 1_920,
                pixelHeight: 1_080
            )
        )

        XCTAssertEqual(
            configuration.modes.first,
            .init(logicalWidth: 1_080, logicalHeight: 1_920)
        )
        XCTAssertFalse(
            configuration.modes.contains(
                .init(logicalWidth: 1_920, logicalHeight: 1_080)
            )
        )
        XCTAssertEqual(
            configuration.requiredResolvedModes.first,
            .init(
                logicalWidth: 1_080,
                logicalHeight: 1_920,
                pixelWidth: 1_080,
                pixelHeight: 1_920
            )
        )
        XCTAssertEqual(
            configuration.requiredResolvedModes,
            [
                .init(
                    logicalWidth: 1_080,
                    logicalHeight: 1_920,
                    pixelWidth: 1_080,
                    pixelHeight: 1_920
                ),
                .init(
                    logicalWidth: 603,
                    logicalHeight: 1_311,
                    pixelWidth: 1_206,
                    pixelHeight: 2_622
                ),
                .init(
                    logicalWidth: 540,
                    logicalHeight: 1_170,
                    pixelWidth: 1_080,
                    pixelHeight: 2_340
                ),
                .init(
                    logicalWidth: 540,
                    logicalHeight: 960,
                    pixelWidth: 1_080,
                    pixelHeight: 1_920
                ),
                .init(
                    logicalWidth: 414,
                    logicalHeight: 896,
                    pixelWidth: 828,
                    pixelHeight: 1_792
                ),
                .init(
                    logicalWidth: 750,
                    logicalHeight: 1_334,
                    pixelWidth: 750,
                    pixelHeight: 1_334
                ),
            ]
        )
        XCTAssertEqual(
            configuration.restoredDesktopMode,
            .init(
                logicalWidth: 1_920,
                logicalHeight: 1_080,
                pixelWidth: 1_920,
                pixelHeight: 1_080
            )
        )

        let restoration = RestoredDesktopExpectation(afterRetiring: configuration)
        XCTAssertEqual(restoration.logicalWidth, 1_920)
        XCTAssertEqual(restoration.logicalHeight, 1_080)
        XCTAssertEqual(restoration.pixelWidth, 1_920)
        XCTAssertEqual(restoration.pixelHeight, 1_080)
    }

    func testNonHeadlessDisplayDoesNotGetReplaced() throws {
        let configuration = try HeadlessDesktopReplacement.makeConfiguration(
            vendorID: 0x1234,
            productID: 0x5678,
            logicalWidth: 1_080,
            logicalHeight: 1_920,
            pixelWidth: 1_080,
            pixelHeight: 1_920
        )

        XCTAssertNil(configuration)
    }

    func testHeadlessRestorationWaitsUntilTopologySettles() {
        var probes = 0
        var sleeps = 0

        let restored = HeadlessDesktopReplacement.waitUntilRestored(
            maximumAttempts: 4,
            isRestored: {
                probes += 1
                return probes == 3
            },
            sleeper: { sleeps += 1 }
        )

        XCTAssertTrue(restored)
        XCTAssertEqual(probes, 3)
        XCTAssertEqual(sleeps, 2)
    }

    func testHeadlessRestorationFailsClosedAfterBoundedPolling() {
        var probes = 0
        var sleeps = 0

        let restored = HeadlessDesktopReplacement.waitUntilRestored(
            maximumAttempts: 3,
            isRestored: {
                probes += 1
                return false
            },
            sleeper: { sleeps += 1 }
        )

        XCTAssertFalse(restored)
        XCTAssertEqual(probes, 3)
        XCTAssertEqual(sleeps, 2)
    }

    func testRestoredDesktopRequiresExactHeadlessMappingOrSafePhysicalMain() throws {
        let retired = try XCTUnwrap(
            HeadlessDesktopReplacement.makeConfiguration(
                vendorID: HeadlessDesktopReplacement.appleHeadlessVendorID,
                productID: HeadlessDesktopReplacement.appleHeadlessProductID,
                logicalWidth: 540,
                logicalHeight: 960,
                pixelWidth: 1_080,
                pixelHeight: 1_920
            )
        )
        let exactHeadless = RestoredDesktopSnapshot(
            vendorID: HeadlessDesktopReplacement.appleHeadlessVendorID,
            productID: HeadlessDesktopReplacement.appleHeadlessProductID,
            serialNumber: 0,
            logicalWidth: 540,
            logicalHeight: 960,
            pixelWidth: 1_080,
            pixelHeight: 1_920,
            isMain: true,
            isActive: true
        )

        XCTAssertTrue(
            RestoredDesktopPolicy.accepts(
                [exactHeadless],
                retiredConfiguration: retired,
                appleHeadlessVendorID: HeadlessDesktopReplacement.appleHeadlessVendorID,
                appleHeadlessProductID: HeadlessDesktopReplacement.appleHeadlessProductID
            )
        )
        XCTAssertFalse(
            RestoredDesktopPolicy.accepts(
                [
                    .init(
                        vendorID: exactHeadless.vendorID,
                        productID: exactHeadless.productID,
                        serialNumber: 0,
                        logicalWidth: 1_080,
                        logicalHeight: 1_920,
                        pixelWidth: 1_080,
                        pixelHeight: 1_920,
                        isMain: true,
                        isActive: true
                    )
                ],
                retiredConfiguration: retired,
                appleHeadlessVendorID: HeadlessDesktopReplacement.appleHeadlessVendorID,
                appleHeadlessProductID: HeadlessDesktopReplacement.appleHeadlessProductID
            )
        )
        XCTAssertTrue(
            RestoredDesktopPolicy.accepts(
                [
                    .init(
                        vendorID: 0x1234,
                        productID: 0x5678,
                        serialNumber: 9,
                        logicalWidth: 2_560,
                        logicalHeight: 1_440,
                        pixelWidth: 2_560,
                        pixelHeight: 1_440,
                        isMain: true,
                        isActive: true
                    )
                ],
                retiredConfiguration: retired,
                appleHeadlessVendorID: HeadlessDesktopReplacement.appleHeadlessVendorID,
                appleHeadlessProductID: HeadlessDesktopReplacement.appleHeadlessProductID
            )
        )
    }

    func testRestoredDesktopRejectsRetiredOpenSteamerIdentity() throws {
        let retired = try makeConfiguration()
        let stillOwned = RestoredDesktopSnapshot(
            vendorID: retired.vendorID,
            productID: retired.productID,
            serialNumber: retired.serialNumber,
            logicalWidth: 603,
            logicalHeight: 1_311,
            pixelWidth: 1_206,
            pixelHeight: 2_622,
            isMain: true,
            isActive: true
        )

        XCTAssertFalse(
            RestoredDesktopPolicy.accepts(
                [stillOwned],
                retiredConfiguration: retired,
                appleHeadlessVendorID: HeadlessDesktopReplacement.appleHeadlessVendorID,
                appleHeadlessProductID: HeadlessDesktopReplacement.appleHeadlessProductID
            )
        )
        XCTAssertFalse(
            RestoredDesktopPolicy.accepts(
                [
                    .init(
                        vendorID: 0x6F73,
                        productID: 0x1717,
                        serialNumber: retired.serialNumber &+ 1,
                        logicalWidth: 603,
                        logicalHeight: 1_311,
                        pixelWidth: 1_206,
                        pixelHeight: 2_622,
                        isMain: true,
                        isActive: true
                    )
                ],
                retiredConfiguration: retired,
                appleHeadlessVendorID: HeadlessDesktopReplacement.appleHeadlessVendorID,
                appleHeadlessProductID: HeadlessDesktopReplacement.appleHeadlessProductID
            )
        )
    }

    private func makeConfiguration(
        physicalWidthMillimeters: Double = 139.2,
        displaySettingsHiDPI: UInt32 = 2,
        modes: [VirtualDisplayMode] = [
            .init(logicalWidth: 603, logicalHeight: 1_311)
        ],
        requiredResolvedModes: [VirtualDisplayResolvedMode] = [
            .init(
                logicalWidth: 603,
                logicalHeight: 1_311,
                pixelWidth: 1_206,
                pixelHeight: 2_622
            )
        ]
    ) throws -> VirtualDisplayConfiguration {
        try VirtualDisplayConfiguration(
            name: "Test Phone Display",
            vendorID: 1,
            productID: 2,
            serialNumber: 3,
            maximumWidth: 1_206,
            maximumHeight: 2_622,
            physicalWidthMillimeters: physicalWidthMillimeters,
            physicalHeightMillimeters: 302.7,
            displaySettingsHiDPI: displaySettingsHiDPI,
            modes: modes,
            requiredResolvedModes: requiredResolvedModes
        )
    }
}
