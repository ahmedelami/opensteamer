import Foundation
import XCTest

final class MacHostBundleIdentityTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testPrivacySensitiveHostUsesStableUniqueApplicationIdentity() throws {
        let infoPlistURL = repositoryRoot.appendingPathComponent(
            "macOS/MacCaptureHost/Info.plist"
        )
        let propertyList = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: infoPlistURL),
            format: nil
        )
        let info = try XCTUnwrap(propertyList as? [String: Any])

        XCTAssertEqual(
            info["CFBundleIdentifier"] as? String,
            "org.example.AudioStreamer.CaptureServer"
        )
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "CaptureServer")
        XCTAssertEqual(info["CFBundleName"] as? String, "AudioStreamer Host")
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "AudioStreamer Host")
    }

    func testBuildScriptPreservesPrivacyVisibleHostNameAndIdentifier() throws {
        let script = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/scripts/build-mac-capture-host-app.sh"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            script.contains("APP_DIR=\"$ROOT_DIR/build/AudioStreamer Host.app\"")
        )
        XCTAssertTrue(
            script.contains("--identifier org.example.AudioStreamer.CaptureServer")
        )
        XCTAssertTrue(
            script.contains(
                "cp \"macOS/MacCaptureHost/Info.plist\" \"$CONTENTS_DIR/Info.plist\""
            )
        )
        XCTAssertFalse(
            script.contains("APP_DIR=\"$ROOT_DIR/build/MacCaptureHost.app\""),
            "A generic legacy bundle name can bind Screen Recording permission to the wrong app."
        )
    }
}
