#!/bin/zsh
# Mutation tests for check-product-identity.sh. Every case starts from the same valid fixture and
# changes exactly one identity boundary, preventing one broad failure from masking a weak oracle.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
TEMPORARY_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/opensteamer-identity-tests.XXXXXX")
trap 'rm -rf "$TEMPORARY_ROOT"' EXIT INT TERM

BASELINE="$TEMPORARY_ROOT/baseline"
mkdir -p \
  "$BASELINE/scripts" \
  "$BASELINE/iOS/opensteamer/Sources/App" \
  "$BASELINE/iOS/opensteamer/Sources/Support" \
  "$BASELINE/iOS/opensteamer/Sources/Views" \
  "$BASELINE/iOS/opensteamer/opensteamer.xcodeproj/xcshareddata/xcschemes" \
  "$BASELINE/macOS/OpensteamerHost" \
  "$BASELINE/macOS/scripts" \
  "$BASELINE/macOS/Sources/CaptureServer" \
  "$BASELINE/macOS/LaunchAgents" \
  "$BASELINE/macOS/RelayBridge" \
  "$BASELINE/services/Rendezvous" \
  "$BASELINE/services/RendezvousWorker"
cp "$ROOT_DIR/scripts/check-product-identity.sh" "$BASELINE/scripts/"
chmod +x "$BASELINE/scripts/check-product-identity.sh"

print -r -- '// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "opensteamer",
    platforms: [.iOS(.v17)]
)' >"$BASELINE/Package.swift"
print -r -- '# opensteamer

Identity regression fixture.' >"$BASELINE/README.md"

print -r -- 'name: opensteamer
packages:
  opensteamer:
    path: ../..
targets:
  opensteamer:
    type: application
    settings:
      base:
        SWIFT_VERSION: 6.0
      configs:
        Debug:
          PRODUCT_BUNDLE_IDENTIFIER: org.example.AudioStreamer.dev
        Release:
          PRODUCT_BUNDLE_IDENTIFIER: com.elamin.AudioStreamer
  opensteamerTests:
    type: bundle.unit-test
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: org.example.AudioStreamerTests
  opensteamerUITests:
    type: bundle.ui-testing
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: org.example.AudioStreamerUITests' \
  >"$BASELINE/iOS/opensteamer/project.yml"

print -r -- '// !$*UTF8*$!
{
  archiveVersion = 1;
  classes = {};
  objectVersion = 56;
  objects = {
/* Begin PBXFileReference section */
    E1 /* opensteamer.app */ = {isa = PBXFileReference; lastKnownFileType = wrapper.application; path = opensteamer.app; sourceTree = BUILT_PRODUCTS_DIR; };
    E2 /* opensteamerTests.xctest */ = {isa = PBXFileReference; lastKnownFileType = wrapper.cfbundle; path = opensteamerTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
    E3 /* opensteamerUITests.xctest */ = {isa = PBXFileReference; lastKnownFileType = wrapper.cfbundle; path = opensteamerUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */
/* Begin PBXNativeTarget section */
    A1 /* opensteamer */ = {
      isa = PBXNativeTarget;
      buildConfigurationList = D1 /* Build configuration list for PBXNativeTarget "opensteamer" */;
      name = opensteamer;
      productName = opensteamer;
      productReference = E1 /* opensteamer.app */;
      productType = "com.apple.product-type.application";
    };
    A2 /* opensteamerTests */ = {
      isa = PBXNativeTarget;
      buildConfigurationList = D2 /* Build configuration list for PBXNativeTarget "opensteamerTests" */;
      name = opensteamerTests;
      productName = opensteamerTests;
      productReference = E2 /* opensteamerTests.xctest */;
      productType = "com.apple.product-type.bundle.unit-test";
    };
    A3 /* opensteamerUITests */ = {
      isa = PBXNativeTarget;
      buildConfigurationList = D3 /* Build configuration list for PBXNativeTarget "opensteamerUITests" */;
      name = opensteamerUITests;
      productName = opensteamerUITests;
      productReference = E3 /* opensteamerUITests.xctest */;
      productType = "com.apple.product-type.bundle.ui-testing";
    };
/* End PBXNativeTarget section */
/* Begin XCBuildConfiguration section */
    B1 /* Debug */ = {
      isa = XCBuildConfiguration;
      buildSettings = {
        PRODUCT_BUNDLE_IDENTIFIER = org.example.AudioStreamer.dev;
      };
      name = Debug;
    };
    B2 /* Release */ = {
      isa = XCBuildConfiguration;
      buildSettings = {
        PRODUCT_BUNDLE_IDENTIFIER = com.elamin.AudioStreamer;
      };
      name = Release;
    };
    B3 /* Debug */ = {
      isa = XCBuildConfiguration;
      buildSettings = {
        PRODUCT_BUNDLE_IDENTIFIER = org.example.AudioStreamerTests;
      };
      name = Debug;
    };
    B4 /* Release */ = {
      isa = XCBuildConfiguration;
      buildSettings = {
        PRODUCT_BUNDLE_IDENTIFIER = org.example.AudioStreamerTests;
      };
      name = Release;
    };
    B5 /* Debug */ = {
      isa = XCBuildConfiguration;
      buildSettings = {
        PRODUCT_BUNDLE_IDENTIFIER = org.example.AudioStreamerUITests;
      };
      name = Debug;
    };
    B6 /* Release */ = {
      isa = XCBuildConfiguration;
      buildSettings = {
        PRODUCT_BUNDLE_IDENTIFIER = org.example.AudioStreamerUITests;
      };
      name = Release;
    };
    F1 /* Debug */ = {
      isa = XCBuildConfiguration;
      buildSettings = {
        PRODUCT_NAME = "$(TARGET_NAME)";
      };
      name = Debug;
    };
    F2 /* Release */ = {
      isa = XCBuildConfiguration;
      buildSettings = {
        PRODUCT_NAME = "$(TARGET_NAME)";
      };
      name = Release;
    };
/* End XCBuildConfiguration section */
/* Begin XCConfigurationList section */
    D1 /* Build configuration list for PBXNativeTarget "opensteamer" */ = {
      isa = XCConfigurationList;
      buildConfigurations = (
        B1 /* Debug */,
        B2 /* Release */,
      );
    };
    D2 /* Build configuration list for PBXNativeTarget "opensteamerTests" */ = {
      isa = XCConfigurationList;
      buildConfigurations = (
        B3 /* Debug */,
        B4 /* Release */,
      );
    };
    D3 /* Build configuration list for PBXNativeTarget "opensteamerUITests" */ = {
      isa = XCConfigurationList;
      buildConfigurations = (
        B5 /* Debug */,
        B6 /* Release */,
      );
    };
/* End XCConfigurationList section */
  };
  rootObject = PROJECT;
}' \
  >"$BASELINE/iOS/opensteamer/opensteamer.xcodeproj/project.pbxproj"

print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<Scheme>
  <BuildableReference BuildableName="opensteamer.app" BlueprintName="opensteamer" BlueprintIdentifier="A1" ReferencedContainer="container:opensteamer.xcodeproj"/>
  <BuildableReference BuildableName="opensteamerTests.xctest" BlueprintName="opensteamerTests" BlueprintIdentifier="A2" ReferencedContainer="container:opensteamer.xcodeproj"/>
</Scheme>' >"$BASELINE/iOS/opensteamer/opensteamer.xcodeproj/xcshareddata/xcschemes/opensteamer.xcscheme"
print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<Scheme>
  <BuildableReference BuildableName="opensteamerUITests.xctest" BlueprintName="opensteamerUITests" BlueprintIdentifier="A3" ReferencedContainer="container:opensteamer.xcodeproj"/>
</Scheme>' >"$BASELINE/iOS/opensteamer/opensteamer.xcodeproj/xcshareddata/xcschemes/opensteamerUITests.xcscheme"

print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>opensteamer</string>
<key>CFBundleName</key><string>opensteamer</string>
<key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
<key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
<key>NSCameraUsageDescription</key><string>opensteamer may request camera access through its real-time communication framework only when you explicitly start a camera-capable sharing feature. Ordinary audio and screen streaming do not access the camera.</string>
<key>NSLocalNetworkUsageDescription</key><string>opensteamer finds the Mac capture server on your local Wi-Fi network.</string>
</dict></plist>' >"$BASELINE/iOS/opensteamer/Sources/Support/Info.plist"
print -r -- 'struct BrowserViewFixture {
  var body: some View { Text("Fixture").navigationTitle("opensteamer") }
}' >"$BASELINE/iOS/opensteamer/Sources/Views/BrowserView.swift"
print -r -- 'let nowPlaying = [MPMediaItemPropertyTitle: "opensteamer"]' \
  >"$BASELINE/iOS/opensteamer/Sources/App/BackgroundPlaybackCoordinator.swift"

print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>opensteamer Host</string>
<key>CFBundleName</key><string>opensteamer Host</string>
<key>CFBundleIdentifier</key><string>com.elamin.AudioStreamer.CaptureServer</string>
<key>CFBundleExecutable</key><string>CaptureServer</string>
<key>NSAudioCaptureUsageDescription</key><string>opensteamer captures this Mac&apos;s audio so it can stream playback to your iPhone.</string>
<key>NSMicrophoneUsageDescription</key><string>opensteamer records the BlackHole virtual input so it can stream this Mac&apos;s routed audio to your iPhone.</string>
</dict></plist>' >"$BASELINE/macOS/OpensteamerHost/Info.plist"
print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>opensteamer Capture Server</string>
<key>CFBundleIdentifier</key><string>com.elamin.AudioStreamer.CaptureServer</string>
</dict></plist>' >"$BASELINE/macOS/Sources/CaptureServer/Info.plist"
print -r -- 'static let legacyPairingService =
    "com.elamin.AudioStreamer.CaptureServer.WorldwidePairing.v1"' \
  >"$BASELINE/macOS/Sources/CaptureServer/WorldwidePairingStore.swift"
print -r -- 'static let legacyRuntimeDirectoryName =
    "com.elamin.AudioStreamer.CaptureServer.runtime"' \
  >"$BASELINE/macOS/Sources/CaptureServer/WorldwideHostProcessLock.swift"
print -r -- 'codesign --identifier com.elamin.AudioStreamer.CaptureServer executable' \
  >"$BASELINE/macOS/scripts/build-opensteamer-host-app.sh"
print -r -- 'EXPECTED_BUNDLE_IDENTIFIER="com.elamin.AudioStreamer.CaptureServer"' \
  >"$BASELINE/macOS/scripts/verify-mac-host-bundle.sh"
print -r -- 'verify-live "com.elamin.AudioStreamer.CaptureServer"' \
  >"$BASELINE/macOS/scripts/verify-mac-host-deployment.sh"
print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>org.example.opensteamer.worldwide</string>
<key>ProgramArguments</key><array><string>/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer</string></array>
<key>StandardOutPath</key><string>/var/tmp/opensteamer-worldwide-host.log</string>
<key>StandardErrorPath</key><string>/var/tmp/opensteamer-worldwide-host.err.log</string>
</dict></plist>' >"$BASELINE/macOS/LaunchAgents/org.example.opensteamer.worldwide.plist"

print -r -- '{"name":"@opensteamer/rendezvous"}' >"$BASELINE/services/Rendezvous/package.json"
print -r -- '{"name":"@opensteamer/rendezvous","packages":{"":{"name":"@opensteamer/rendezvous"}}}' \
  >"$BASELINE/services/Rendezvous/package-lock.json"
print -r -- '{"name":"@opensteamer/rendezvous-worker"}' \
  >"$BASELINE/services/RendezvousWorker/package.json"
print -r -- '{"name":"@opensteamer/rendezvous-worker","packages":{"":{"name":"@opensteamer/rendezvous-worker"}}}' \
  >"$BASELINE/services/RendezvousWorker/package-lock.json"
print -r -- '{"name":"opensteamer-relay-bridge"}' >"$BASELINE/macOS/RelayBridge/package.json"
print -r -- '{"name":"opensteamer-relay-bridge","packages":{"":{"name":"opensteamer-relay-bridge"}}}' \
  >"$BASELINE/macOS/RelayBridge/package-lock.json"
print -r -- 'name = "opensteamer-rendezvous"
main = "src/index.js"' >"$BASELINE/services/RendezvousWorker/wrangler.toml"
print -r -- 'name = "opensteamer-rendezvous-test"
main = "src/index.js"' >"$BASELINE/services/RendezvousWorker/wrangler.test.toml"

"$BASELINE/scripts/check-product-identity.sh" "$BASELINE" >/dev/null

replace_once() {
  local file=$1
  local original=$2
  local replacement=$3
  node -e '
    const fs = require("node:fs");
    const file = process.argv[1];
    const original = process.argv[2];
    const replacement = process.argv[3];
    const contents = fs.readFileSync(file, "utf8");
    const first = contents.indexOf(original);
    if (first < 0 || contents.indexOf(original, first + original.length) >= 0) process.exit(2);
    fs.writeFileSync(file, contents.slice(0, first) + replacement + contents.slice(first + original.length));
  ' "$file" "$original" "$replacement"
}

new_case() {
  local name=$1
  local fixture="$TEMPORARY_ROOT/$name"
  cp -R "$BASELINE" "$fixture"
  print -r -- "$fixture"
}

require_rejection() {
  local fixture=$1
  local expected_diagnostic=$2
  local output="$fixture/rejection.log"
  if "$fixture/scripts/check-product-identity.sh" "$fixture" >"$output" 2>&1; then
    print -u2 -r -- "identity mutation unexpectedly passed: ${fixture:t}"
    exit 1
  fi
  if ! grep -Fq -- "$expected_diagnostic" "$output"; then
    print -u2 -r -- "identity mutation emitted the wrong diagnostic: ${fixture:t}"
    sed -n '1,120p' "$output" >&2
    exit 1
  fi
}

CASE=$(new_case lowercase-casing)
replace_once "$CASE/iOS/opensteamer/Sources/Support/Info.plist" \
  '<key>CFBundleDisplayName</key><string>opensteamer</string>' \
  '<key>CFBundleDisplayName</key><string>Opensteamer</string>'
require_rejection "$CASE" 'iOS CFBundleDisplayName lowercase identity'

CASE=$(new_case camera-usage-description)
replace_once "$CASE/iOS/opensteamer/Sources/Support/Info.plist" \
  '<key>NSCameraUsageDescription</key><string>opensteamer may request camera access through its real-time communication framework only when you explicitly start a camera-capable sharing feature. Ordinary audio and screen streaming do not access the camera.</string>' \
  '<key>NSCameraUsageDescription</key><string>opensteamer uses the camera during ordinary audio streaming.</string>'
require_rejection "$CASE" 'iOS camera usage description'

CASE=$(new_case project-target)
replace_once "$CASE/iOS/opensteamer/project.yml" \
  $'  opensteamerTests:\n' $'  opensteamerUnitTests:\n'
require_rejection "$CASE" 'project.yml targets'

CASE=$(new_case project-target-product-type)
replace_once "$CASE/iOS/opensteamer/project.yml" \
  'type: application' 'type: bundle.unit-test'
require_rejection "$CASE" 'project.yml target/product-type mapping'

CASE=$(new_case project-product-name-override)
replace_once "$CASE/iOS/opensteamer/project.yml" \
  'PRODUCT_BUNDLE_IDENTIFIER: org.example.AudioStreamer.dev' \
  $'PRODUCT_BUNDLE_IDENTIFIER: org.example.AudioStreamer.dev\n          PRODUCT_NAME: Opensteamer'
require_rejection "$CASE" 'project.yml product-name override count'

CASE=$(new_case project-debug-bundle-id)
replace_once "$CASE/iOS/opensteamer/project.yml" \
  'PRODUCT_BUNDLE_IDENTIFIER: org.example.AudioStreamer.dev' \
  'PRODUCT_BUNDLE_IDENTIFIER: org.example.opensteamer.dev'
require_rejection "$CASE" 'project.yml target/configuration bundle-ID mapping'

CASE=$(new_case project-release-bundle-id)
replace_once "$CASE/iOS/opensteamer/project.yml" \
  'PRODUCT_BUNDLE_IDENTIFIER: com.elamin.AudioStreamer' \
  'PRODUCT_BUNDLE_IDENTIFIER: com.elamin.opensteamer'
require_rejection "$CASE" 'project.yml target/configuration bundle-ID mapping'

CASE=$(new_case project-unit-test-bundle-id)
replace_once "$CASE/iOS/opensteamer/project.yml" \
  'PRODUCT_BUNDLE_IDENTIFIER: org.example.AudioStreamerTests' \
  'PRODUCT_BUNDLE_IDENTIFIER: org.example.opensteamerTests'
require_rejection "$CASE" 'project.yml target/configuration bundle-ID mapping'

CASE=$(new_case project-ui-test-bundle-id)
replace_once "$CASE/iOS/opensteamer/project.yml" \
  'PRODUCT_BUNDLE_IDENTIFIER: org.example.AudioStreamerUITests' \
  'PRODUCT_BUNDLE_IDENTIFIER: org.example.opensteamerUITests'
require_rejection "$CASE" 'project.yml target/configuration bundle-ID mapping'

CASE=$(new_case generated-project-debug-bundle-id)
replace_once "$CASE/iOS/opensteamer/opensteamer.xcodeproj/project.pbxproj" \
  'PRODUCT_BUNDLE_IDENTIFIER = org.example.AudioStreamer.dev;' \
  'PRODUCT_BUNDLE_IDENTIFIER = org.example.opensteamer.dev;'
require_rejection "$CASE" 'generated Xcode target/configuration bundle-ID mapping'

CASE=$(new_case generated-project-release-bundle-id)
replace_once "$CASE/iOS/opensteamer/opensteamer.xcodeproj/project.pbxproj" \
  'PRODUCT_BUNDLE_IDENTIFIER = com.elamin.AudioStreamer;' \
  'PRODUCT_BUNDLE_IDENTIFIER = com.elamin.opensteamer;'
require_rejection "$CASE" 'generated Xcode target/configuration bundle-ID mapping'

CASE=$(new_case generated-project-unit-test-bundle-id)
replace_once "$CASE/iOS/opensteamer/opensteamer.xcodeproj/project.pbxproj" \
  $'PRODUCT_BUNDLE_IDENTIFIER = org.example.AudioStreamerTests;\n      };\n      name = Debug;' \
  $'PRODUCT_BUNDLE_IDENTIFIER = org.example.opensteamerTests;\n      };\n      name = Debug;'
require_rejection "$CASE" 'generated Xcode target/configuration bundle-ID mapping'

CASE=$(new_case generated-project-ui-test-bundle-id)
replace_once "$CASE/iOS/opensteamer/opensteamer.xcodeproj/project.pbxproj" \
  $'PRODUCT_BUNDLE_IDENTIFIER = org.example.AudioStreamerUITests;\n      };\n      name = Release;' \
  $'PRODUCT_BUNDLE_IDENTIFIER = org.example.opensteamerUITests;\n      };\n      name = Release;'
require_rejection "$CASE" 'generated Xcode target/configuration bundle-ID mapping'

CASE=$(new_case generated-project-target-product)
replace_once "$CASE/iOS/opensteamer/opensteamer.xcodeproj/project.pbxproj" \
  'productName = opensteamerTests;' 'productName = opensteamer;'
require_rejection "$CASE" 'generated Xcode target/product mapping'

CASE=$(new_case generated-project-product-type)
replace_once "$CASE/iOS/opensteamer/opensteamer.xcodeproj/project.pbxproj" \
  'productType = "com.apple.product-type.application";' \
  'productType = "com.apple.product-type.bundle.unit-test";'
require_rejection "$CASE" 'generated Xcode target/product mapping'

CASE=$(new_case generated-product-name-override)
replace_once "$CASE/iOS/opensteamer/opensteamer.xcodeproj/project.pbxproj" \
  'PRODUCT_BUNDLE_IDENTIFIER = com.elamin.AudioStreamer;' \
  $'PRODUCT_NAME = Opensteamer;\n        PRODUCT_BUNDLE_IDENTIFIER = com.elamin.AudioStreamer;'
require_rejection "$CASE" 'generated Xcode product-name setting count'

CASE=$(new_case generated-project-product-reference)
replace_once "$CASE/iOS/opensteamer/opensteamer.xcodeproj/project.pbxproj" \
  'productReference = E1 /* opensteamer.app */;' \
  'productReference = E2 /* opensteamer.app */;'
require_rejection "$CASE" 'generated Xcode target/product mapping'

CASE=$(new_case generated-product-path)
replace_once "$CASE/iOS/opensteamer/opensteamer.xcodeproj/project.pbxproj" \
  'path = opensteamer.app;' 'path = Opensteamer.app;'
require_rejection "$CASE" 'generated Xcode target/product mapping'

CASE=$(new_case generated-configuration-name)
replace_once "$CASE/iOS/opensteamer/opensteamer.xcodeproj/project.pbxproj" \
  $'PRODUCT_BUNDLE_IDENTIFIER = org.example.AudioStreamer.dev;\n      };\n      name = Debug;' \
  $'PRODUCT_BUNDLE_IDENTIFIER = org.example.AudioStreamer.dev;\n      };\n      name = Release;'
require_rejection "$CASE" 'could not parse generated Xcode target/product/configuration mappings'

CASE=$(new_case scheme-buildable-pairing)
replace_once "$CASE/iOS/opensteamer/opensteamer.xcodeproj/xcshareddata/xcschemes/opensteamer.xcscheme" \
  'BuildableName="opensteamer.app" BlueprintName="opensteamer"' \
  'BuildableName="opensteamer.app" BlueprintName="opensteamerTests"'
require_rejection "$CASE" 'opensteamer scheme buildable/blueprint/project mapping'

CASE=$(new_case scheme-blueprint-identifier)
replace_once "$CASE/iOS/opensteamer/opensteamer.xcodeproj/xcshareddata/xcschemes/opensteamer.xcscheme" \
  'BlueprintIdentifier="A1"' 'BlueprintIdentifier="A2"'
require_rejection "$CASE" 'opensteamer scheme buildable/blueprint/project mapping'

CASE=$(new_case visible-navigation-title)
replace_once "$CASE/iOS/opensteamer/Sources/Views/BrowserView.swift" \
  '.navigationTitle("opensteamer")' '.navigationTitle("Opensteamer")'
require_rejection "$CASE" 'iOS navigation-title lowercase identity'

CASE=$(new_case mac-host-bundle-identifier)
replace_once "$CASE/macOS/OpensteamerHost/Info.plist" \
  '<key>CFBundleIdentifier</key><string>com.elamin.AudioStreamer.CaptureServer</string>' \
  '<key>CFBundleIdentifier</key><string>org.example.AudioStreamer.CaptureServer</string>'
require_rejection "$CASE" 'preserved macOS host bundle identifier'

CASE=$(new_case swiftpm-host-bundle-identifier)
replace_once "$CASE/macOS/Sources/CaptureServer/Info.plist" \
  '<key>CFBundleIdentifier</key><string>com.elamin.AudioStreamer.CaptureServer</string>' \
  '<key>CFBundleIdentifier</key><string>org.example.AudioStreamer.CaptureServer</string>'
require_rejection "$CASE" 'preserved SwiftPM capture-server bundle identifier'

CASE=$(new_case mac-pairing-keychain-service)
replace_once "$CASE/macOS/Sources/CaptureServer/WorldwidePairingStore.swift" \
  '"com.elamin.AudioStreamer.CaptureServer.WorldwidePairing.v1"' \
  '"org.example.AudioStreamer.CaptureServer.WorldwidePairing.v1"'
require_rejection "$CASE" 'preserved macOS pairing Keychain service'

CASE=$(new_case mac-runtime-lock-namespace)
replace_once "$CASE/macOS/Sources/CaptureServer/WorldwideHostProcessLock.swift" \
  '"com.elamin.AudioStreamer.CaptureServer.runtime"' \
  '"org.example.AudioStreamer.CaptureServer.runtime"'
require_rejection "$CASE" 'preserved cross-version runtime lock namespace'

CASE=$(new_case mac-executable-signature-identifier)
replace_once "$CASE/macOS/scripts/build-opensteamer-host-app.sh" \
  '--identifier com.elamin.AudioStreamer.CaptureServer' \
  '--identifier org.example.AudioStreamer.CaptureServer'
require_rejection "$CASE" 'preserved macOS executable signature identifier'

CASE=$(new_case mac-bundle-verifier-identity)
replace_once "$CASE/macOS/scripts/verify-mac-host-bundle.sh" \
  'EXPECTED_BUNDLE_IDENTIFIER="com.elamin.AudioStreamer.CaptureServer"' \
  'EXPECTED_BUNDLE_IDENTIFIER="org.example.AudioStreamer.CaptureServer"'
require_rejection "$CASE" 'macOS bundle verifier identity'

CASE=$(new_case mac-deployment-verifier-identity)
replace_once "$CASE/macOS/scripts/verify-mac-host-deployment.sh" \
  '"com.elamin.AudioStreamer.CaptureServer"' \
  '"org.example.AudioStreamer.CaptureServer"'
require_rejection "$CASE" 'macOS deployment verifier identity'

CASE=$(new_case launch-agent-host-path)
replace_once "$CASE/macOS/LaunchAgents/org.example.opensteamer.worldwide.plist" \
  '/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer' \
  '/Applications/Opensteamer Host.app/Contents/MacOS/CaptureServer'
require_rejection "$CASE" 'LaunchAgent host program path'

CASE=$(new_case launch-agent-standard-output-path)
replace_once "$CASE/macOS/LaunchAgents/org.example.opensteamer.worldwide.plist" \
  '/var/tmp/opensteamer-worldwide-host.log' \
  '/tmp/opensteamer/worldwide-host.log'
require_rejection "$CASE" 'LaunchAgent standard-output path'

CASE=$(new_case launch-agent-standard-error-path)
replace_once "$CASE/macOS/LaunchAgents/org.example.opensteamer.worldwide.plist" \
  '/var/tmp/opensteamer-worldwide-host.err.log' \
  '/tmp/opensteamer/worldwide-host.err.log'
require_rejection "$CASE" 'LaunchAgent standard-error path'

CASE=$(new_case npm-package-name)
replace_once "$CASE/services/Rendezvous/package.json" \
  '@opensteamer/rendezvous' '@opensteamer/signaling'
require_rejection "$CASE" 'Rendezvous npm package name'

CASE=$(new_case worker-name)
replace_once "$CASE/services/RendezvousWorker/wrangler.toml" \
  'name = "opensteamer-rendezvous"' 'name = "opensteamer-signaling"'
require_rejection "$CASE" 'production Worker name'

print -- 'opensteamer product identity regression tests passed'
