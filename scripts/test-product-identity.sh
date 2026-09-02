#!/bin/zsh
# Mutation tests for check-product-identity.sh. Every case starts from the same valid fixture and
# changes exactly one identity boundary, preventing one broad failure from masking a weak oracle.
set -euo pipefail
zmodload zsh/system || {
  print -u2 -r -- 'identity regression setup failed: zsh/system is unavailable'
  exit 1
}

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
readonly IDENTITY_TEST_TEMP_ROOT='/Volumes/t7'
[[ "${IDENTITY_TEST_TEMP_ROOT:A}" == "${IDENTITY_TEST_TEMP_ROOT}" \
    && "${IDENTITY_TEST_TEMP_ROOT:h}" == '/Volumes' \
    && -d "${IDENTITY_TEST_TEMP_ROOT}" \
    && ! -L "${IDENTITY_TEST_TEMP_ROOT}" ]] || {
  print -u2 -r -- 'identity regression setup failed: fixed T7 scratch root is unsafe'
  exit 1
}
typeset IDENTITY_TEST_TEMP_PARENT_IDENTITY
IDENTITY_TEST_TEMP_PARENT_IDENTITY=$(/usr/bin/stat -f '%d:%i:%u:%g:%Lp:%HT' \
  "${IDENTITY_TEST_TEMP_ROOT}")
TEMPORARY_ROOT=$(mktemp -d \
  "${IDENTITY_TEST_TEMP_ROOT}/opensteamer-identity-tests.XXXXXX")
/bin/chmod 700 "${TEMPORARY_ROOT}"
typeset IDENTITY_TEST_TEMP_IDENTITY
IDENTITY_TEST_TEMP_IDENTITY=$(/usr/bin/stat -f '%d:%i:%u:%g:%Lp:%HT' \
  "${TEMPORARY_ROOT}")
typeset -i IDENTITY_TEST_TEMP_FD=-1
sysopen -r -o nofollow -u IDENTITY_TEST_TEMP_FD "${TEMPORARY_ROOT}"

cleanup_identity_test_scratch() {
  local original_status=$?
  trap '' HUP INT QUIT TERM
  trap - EXIT
  local cleanup_failed=0
  [[ "${TEMPORARY_ROOT}" \
        == "${IDENTITY_TEST_TEMP_ROOT}"/opensteamer-identity-tests.* \
      && "${TEMPORARY_ROOT:A}" == "${TEMPORARY_ROOT}" \
      && "$(/usr/bin/stat -f '%d:%i:%u:%g:%Lp:%HT' \
        "${IDENTITY_TEST_TEMP_ROOT}" 2>/dev/null)" \
        == "${IDENTITY_TEST_TEMP_PARENT_IDENTITY}" \
      && -d "${TEMPORARY_ROOT}" \
      && ! -L "${TEMPORARY_ROOT}" \
      && "$(/usr/bin/stat -f '%d:%i:%u:%g:%Lp:%HT' \
        "${TEMPORARY_ROOT}" 2>/dev/null)" \
        == "${IDENTITY_TEST_TEMP_IDENTITY}" \
      && ${IDENTITY_TEST_TEMP_FD} -ge 0 \
      && -e "/dev/fd/${IDENTITY_TEST_TEMP_FD}" \
      && "${TEMPORARY_ROOT}" -ef "/dev/fd/${IDENTITY_TEST_TEMP_FD}" ]] \
    || cleanup_failed=1
  if (( cleanup_failed == 0 )); then
    (
      cd "${TEMPORARY_ROOT}" || exit 1
      [[ "." -ef "/dev/fd/${IDENTITY_TEST_TEMP_FD}" ]] || exit 1
      /usr/bin/find -x . -depth -mindepth 1 -delete
    ) || cleanup_failed=1
  fi
  if (( cleanup_failed == 0 )); then
    [[ "${TEMPORARY_ROOT}" -ef "/dev/fd/${IDENTITY_TEST_TEMP_FD}" ]] \
      || cleanup_failed=1
  fi
  if (( IDENTITY_TEST_TEMP_FD >= 0 )); then
    exec {IDENTITY_TEST_TEMP_FD}>&-
    IDENTITY_TEST_TEMP_FD=-1
  fi
  (( cleanup_failed != 0 )) \
    || /bin/rmdir -- "${TEMPORARY_ROOT}" || cleanup_failed=1
  (( cleanup_failed == 0 )) || exit 1
  exit ${original_status}
}

trap cleanup_identity_test_scratch EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 131' QUIT
trap 'exit 143' TERM

BASELINE="$TEMPORARY_ROOT/baseline"
mkdir -p \
  "$BASELINE/scripts" \
  "$BASELINE/iOS/opensteamer/Sources/App" \
  "$BASELINE/iOS/opensteamer/Sources/Support" \
  "$BASELINE/iOS/opensteamer/Sources/Views" \
  "$BASELINE/iOS/opensteamer/TestFlightScheme" \
  "$BASELINE/iOS/opensteamer/scripts" \
  "$BASELINE/iOS/opensteamer/opensteamer.xcodeproj/xcshareddata/xcschemes" \
  "$BASELINE/macOS/OpensteamerHost" \
  "$BASELINE/macOS/scripts" \
  "$BASELINE/macOS/Sources/CaptureCore" \
  "$BASELINE/macOS/Sources/CaptureServer" \
  "$BASELINE/macOS/LaunchAgents" \
  "$BASELINE/macOS/RelayBridge" \
  "$BASELINE/macOS/VirtualAudioDriver/Driver" \
  "$BASELINE/macOS/VirtualAudioDriver/include" \
  "$BASELINE/macOS/VirtualAudioDriver/scripts" \
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
options:
  postGenCommand: /bin/zsh scripts/restore-archive-only-testflight-scheme.sh
configs:
  Debug: debug
  Release: release
  TestFlight: release
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
        TestFlight:
          PRODUCT_BUNDLE_IDENTIFIER: com.elamin.opensteamer
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
    B7 /* TestFlight */ = {
      isa = XCBuildConfiguration;
      buildSettings = {
        PRODUCT_BUNDLE_IDENTIFIER = com.elamin.opensteamer;
      };
      name = TestFlight;
    };
    B8 /* TestFlight */ = {
      isa = XCBuildConfiguration;
      buildSettings = {
        PRODUCT_BUNDLE_IDENTIFIER = org.example.AudioStreamerTests;
      };
      name = TestFlight;
    };
    B9 /* TestFlight */ = {
      isa = XCBuildConfiguration;
      buildSettings = {
        PRODUCT_BUNDLE_IDENTIFIER = org.example.AudioStreamerUITests;
      };
      name = TestFlight;
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
    F3 /* TestFlight */ = {
      isa = XCBuildConfiguration;
      buildSettings = {
        PRODUCT_NAME = "$(TARGET_NAME)";
      };
      name = TestFlight;
    };
/* End XCBuildConfiguration section */
/* Begin XCConfigurationList section */
    D1 /* Build configuration list for PBXNativeTarget "opensteamer" */ = {
      isa = XCConfigurationList;
      buildConfigurations = (
        B1 /* Debug */,
        B2 /* Release */,
        B7 /* TestFlight */,
      );
    };
    D2 /* Build configuration list for PBXNativeTarget "opensteamerTests" */ = {
      isa = XCConfigurationList;
      buildConfigurations = (
        B3 /* Debug */,
        B4 /* Release */,
        B8 /* TestFlight */,
      );
    };
    D3 /* Build configuration list for PBXNativeTarget "opensteamerUITests" */ = {
      isa = XCConfigurationList;
      buildConfigurations = (
        B5 /* Debug */,
        B6 /* Release */,
        B9 /* TestFlight */,
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
<Scheme>
  <BuildAction>
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="NO" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="YES" buildForAnalyzing="NO">
        <BuildableReference BuildableName="opensteamer.app" BlueprintName="opensteamer" BlueprintIdentifier="A1" ReferencedContainer="container:opensteamer.xcodeproj"/>
      </BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <ArchiveAction buildConfiguration="TestFlight"/>
</Scheme>' >"$BASELINE/iOS/opensteamer/opensteamer.xcodeproj/xcshareddata/xcschemes/opensteamerTestFlight.xcscheme"
cp \
  "$BASELINE/iOS/opensteamer/opensteamer.xcodeproj/xcshareddata/xcschemes/opensteamerTestFlight.xcscheme" \
  "$BASELINE/iOS/opensteamer/TestFlightScheme/opensteamerTestFlight.xcscheme"

print -r -- '#!/bin/zsh
readonly SOURCE_SCHEME="${PROJECT_DIR}/TestFlightScheme/opensteamerTestFlight.xcscheme"
readonly DESTINATION_SCHEME="${PROJECT_DIR}/opensteamer.xcodeproj/xcshareddata/xcschemes/opensteamerTestFlight.xcscheme"' \
  >"$BASELINE/iOS/opensteamer/scripts/restore-archive-only-testflight-scheme.sh"

cp "$ROOT_DIR/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  "$BASELINE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh"
print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>destination</key><string>upload</string>
<key>manageAppVersionAndBuildNumber</key><false/>
<key>method</key><string>app-store-connect</string>
<key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>MSMG8CJLB3</string>
<key>testFlightInternalTestingOnly</key><true/>
<key>uploadSymbols</key><true/>
</dict></plist>' >"$BASELINE/iOS/opensteamer/TestFlightExportOptions.plist"

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
<key>NSMicrophoneUsageDescription</key><string>opensteamer uses its virtual microphone to route your iPhone&apos;s microphone into calls on this Mac.</string>
</dict></plist>' >"$BASELINE/macOS/OpensteamerHost/Info.plist"
print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>opensteamer Capture Server</string>
<key>CFBundleIdentifier</key><string>com.elamin.AudioStreamer.CaptureServer</string>
<key>NSMicrophoneUsageDescription</key><string>opensteamer uses its virtual microphone to route your iPhone&apos;s microphone into calls on this Mac.</string>
</dict></plist>' >"$BASELINE/macOS/Sources/CaptureServer/Info.plist"
print -r -- 'enum BlackHoleRouteManagerFixture {
  static let uid = "BlackHole2ch_UID"
  static let hiddenUID = "BlackHole2ch_2_UID"
}' >"$BASELINE/macOS/Sources/CaptureCore/BlackHoleRouteManager.swift"
print -r -- 'static let opensteamerPairingService =
    "com.elamin.opensteamer.CaptureServer.WorldwidePairing.v1"' \
  >"$BASELINE/macOS/Sources/CaptureServer/WorldwidePairingStore.swift"
print -r -- 'let store = WorldwidePairingStore(
    dataStore: WorldwideKeychainDataStore()
)
fflush(stdout)' >"$BASELINE/macOS/Sources/CaptureServer/CaptureServerMain.swift"
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
<key>CFBundleExecutable</key><string>OpensteamerVirtualMicrophone</string>
<key>CFBundleIdentifier</key><string>com.elamin.opensteamer.VirtualMicrophoneDriver</string>
<key>CFBundleName</key><string>opensteamer Virtual Microphone</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFPlugInFactories</key><dict>
  <key>81CE9D28-D187-499B-84EE-F6AC6159C800</key>
  <string>OpensteamerVirtualMicrophone_Create</string>
</dict>
<key>CFPlugInTypes</key><dict>
  <key>443ABAB8-E7B3-491A-B985-BEB9187030DB</key>
  <array><string>81CE9D28-D187-499B-84EE-F6AC6159C800</string></array>
</dict>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>' >"$BASELINE/macOS/VirtualAudioDriver/Driver/Info.plist"
print -r -- '#define OSVA_BUNDLE_IDENTIFIER "com.elamin.opensteamer.VirtualMicrophoneDriver"
#define OSVA_VISIBLE_INPUT_DEVICE_UID "com.elamin.opensteamer.virtual-microphone.input"
#define OSVA_HIDDEN_WRITER_DEVICE_UID "com.elamin.opensteamer.virtual-microphone.writer"
#define OSVA_DEVICE_MODEL_UID "com.elamin.opensteamer.virtual-microphone.model"
enum {
  kOSVAClockDomain = 0x6F73564D,
};' >"$BASELINE/macOS/VirtualAudioDriver/include/OpensteamerVirtualMicrophoneDriver.h"
print -r -- '#define OSVA_SAMPLE_RATE_HZ UINT64_C(48000)
#define OSVA_CHANNEL_COUNT UINT32_C(1)
#define OSVA_BYTES_PER_FRAME UINT32_C(4)' \
  >"$BASELINE/macOS/VirtualAudioDriver/include/OpensteamerVirtualAudioCore.h"
print -r -- 'static size_t OSVADeviceRoleObjectCount(
    AudioObjectID objectID,
    AudioObjectPropertyScope scope) {
  if ((OSVAIsVisibleDevice(objectID) &&
       scope == kAudioObjectPropertyScopeInput) ||
      (OSVAIsHiddenDevice(objectID) &&
       scope == kAudioObjectPropertyScopeOutput)) {
    return 3;
  }
  return 0;
}
static size_t OSVADeviceRoleStreamCount(
    AudioObjectID objectID,
    AudioObjectPropertyScope scope) {
  return OSVADeviceRoleObjectCount(objectID, scope) == 0 ? 0 : 1;
}
static AudioStreamBasicDescription OSVAMonoFormat(void) {
  AudioStreamBasicDescription format = {
      .mSampleRate = 48000.0,
      .mFormatID = kAudioFormatLinearPCM,
      .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian |
                      kAudioFormatFlagIsPacked,
      .mBytesPerPacket = 4,
      .mFramesPerPacket = 1,
      .mBytesPerFrame = 4,
      .mChannelsPerFrame = 1,
      .mBitsPerChannel = 32,
  };
  return format;
}' >"$BASELINE/macOS/VirtualAudioDriver/Driver/OpensteamerVirtualMicrophone.c"
print -r -- '#!/bin/zsh
[[ "${requested_output:t}" != "OpensteamerVirtualMicrophone.driver" ]]
compile -mmacosx-version-min=14.0
install "$bundle/Contents/MacOS/OpensteamerVirtualMicrophone"
codesign --identifier com.elamin.opensteamer.VirtualMicrophoneDriver' \
  >"$BASELINE/macOS/VirtualAudioDriver/scripts/build-driver.sh"
print -r -- '#!/bin/zsh
[[ "${bundle:t}" != "OpensteamerVirtualMicrophone.driver" ]]
executable="$bundle/Contents/MacOS/OpensteamerVirtualMicrophone"' \
  >"$BASELINE/macOS/VirtualAudioDriver/scripts/verify-driver-bundle.sh"
chmod 755 \
  "$BASELINE/macOS/VirtualAudioDriver/scripts/build-driver.sh" \
  "$BASELINE/macOS/VirtualAudioDriver/scripts/verify-driver-bundle.sh"
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

if [[ "${OPENSTEAMER_IDENTITY_LOCATOR_ONLY:-0}" != 1 \
    && "${OPENSTEAMER_IDENTITY_BEHAVIOR_ONLY:-0}" != 1 ]]; then
  "$BASELINE/scripts/check-product-identity.sh" "$BASELINE" >/dev/null
fi

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
  [[ "${OPENSTEAMER_IDENTITY_LOCATOR_ONLY:-0}" != 1 ]] || return 0
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

if [[ "${OPENSTEAMER_IDENTITY_BEHAVIOR_ONLY:-0}" != 1 ]]; then

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

CASE=$(new_case readme-retired-rendezvous-environment-alias)
print -r -- 'AUDIOSTREAMER_RENDEZVOUS_URL' >>"$CASE/README.md"
require_rejection "$CASE" 'README retired rendezvous environment alias count'

CASE=$(new_case info-retired-rendezvous-plist-alias)
replace_once "$CASE/iOS/opensteamer/Sources/Support/Info.plist" \
  '<key>CFBundleName</key><string>opensteamer</string>' \
  $'<key>CFBundleName</key><string>opensteamer</string>\n<key>AudioStreamerRendezvousURL</key><string>https://retired.invalid</string>'
require_rejection "$CASE" 'iOS retired rendezvous plist key count'

CASE=$(new_case project-target)
replace_once "$CASE/iOS/opensteamer/project.yml" \
  $'  opensteamerTests:\n' $'  opensteamerUnitTests:\n'
require_rejection "$CASE" 'project.yml targets'

CASE=$(new_case project-testflight-postgen-hook)
replace_once "$CASE/iOS/opensteamer/project.yml" \
  'postGenCommand: /bin/zsh scripts/restore-archive-only-testflight-scheme.sh' \
  'postGenCommand: /bin/true'
require_rejection "$CASE" 'project.yml archive-only TestFlight scheme restoration hook'

CASE=$(new_case project-target-product-type)
replace_once "$CASE/iOS/opensteamer/project.yml" \
  'type: application' 'type: bundle.unit-test'
require_rejection "$CASE" 'project.yml target/product-type mapping'

CASE=$(new_case project-product-name-override)
replace_once "$CASE/iOS/opensteamer/project.yml" \
  'PRODUCT_BUNDLE_IDENTIFIER: org.example.AudioStreamer.dev' \
  $'PRODUCT_BUNDLE_IDENTIFIER: org.example.AudioStreamer.dev\n          PRODUCT_NAME: Opensteamer'
require_rejection "$CASE" 'project.yml product-name override count'

CASE=$(new_case project-code-sign-identity-override)
replace_once "$CASE/iOS/opensteamer/project.yml" \
  'PRODUCT_BUNDLE_IDENTIFIER: com.elamin.opensteamer' \
  $'PRODUCT_BUNDLE_IDENTIFIER: com.elamin.opensteamer\n          CODE_SIGN_IDENTITY: "Apple Distribution"'
require_rejection "$CASE" 'project.yml code-sign identity override count'

CASE=$(new_case project-retired-rendezvous-build-setting)
replace_once "$CASE/iOS/opensteamer/project.yml" \
  'SWIFT_VERSION: 6.0' \
  $'SWIFT_VERSION: 6.0\n        AUDIOSTREAMER_RENDEZVOUS_URL: "https://retired.invalid"'
require_rejection "$CASE" 'project.yml retired rendezvous build-setting count'

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

CASE=$(new_case project-testflight-bundle-id)
replace_once "$CASE/iOS/opensteamer/project.yml" \
  'PRODUCT_BUNDLE_IDENTIFIER: com.elamin.opensteamer' \
  'PRODUCT_BUNDLE_IDENTIFIER: com.elamin.AudioStreamer'
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

CASE=$(new_case generated-project-testflight-bundle-id)
replace_once "$CASE/iOS/opensteamer/opensteamer.xcodeproj/project.pbxproj" \
  'PRODUCT_BUNDLE_IDENTIFIER = com.elamin.opensteamer;' \
  'PRODUCT_BUNDLE_IDENTIFIER = com.elamin.AudioStreamer;'
require_rejection "$CASE" 'generated Xcode target/configuration bundle-ID mapping'

CASE=$(new_case generated-project-retired-rendezvous-build-setting)
replace_once "$CASE/iOS/opensteamer/opensteamer.xcodeproj/project.pbxproj" \
  'PRODUCT_BUNDLE_IDENTIFIER = com.elamin.opensteamer;' \
  $'PRODUCT_BUNDLE_IDENTIFIER = com.elamin.opensteamer;\n        AUDIOSTREAMER_RENDEZVOUS_URL = "https://retired.invalid";'
require_rejection "$CASE" 'generated Xcode retired rendezvous build-setting count'

CASE=$(new_case superseded-generic-export-options)
cp "$CASE/iOS/opensteamer/TestFlightExportOptions.plist" \
  "$CASE/iOS/opensteamer/ExportOptions.plist"
require_rejection "$CASE" 'superseded generic iOS export options'

CASE=$(new_case testflight-retired-rendezvous-environment-alias)
print -r -- '# AUDIOSTREAMER_RENDEZVOUS_URL' \
  >>"$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh"
require_rejection "$CASE" \
  'side-by-side TestFlight retired rendezvous environment alias count'

CASE=$(new_case testflight-retired-rendezvous-plist-alias)
print -r -- '# AudioStreamerRendezvousURL' \
  >>"$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh"
require_rejection "$CASE" \
  'side-by-side TestFlight retired rendezvous plist alias count'

CASE=$(new_case testflight-temporary-root)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'PRIVATE_TEMPORARY_ROOT="/private/tmp"' \
  'PRIVATE_TEMPORARY_ROOT="/Applications/AudioStreamer Host.app"'
require_rejection "$CASE" 'side-by-side TestFlight fixed temporary root'

CASE=$(new_case testflight-api-key-issuer)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_ASC_TEAM_ISSUER_ID="98529b8c-9fa6-4799-bcb1-7ef7c85a83d3"' \
  'EXPECTED_ASC_TEAM_ISSUER_ID="00000000-0000-0000-0000-000000000000"'
require_rejection "$CASE" 'side-by-side TestFlight exact App Store Connect team-key issuer'

CASE=$(new_case testflight-api-key-id)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_ASC_API_KEY_ID="WPN8WJYC7H"' \
  'EXPECTED_ASC_API_KEY_ID="AAAAAAAAAA"'
require_rejection "$CASE" 'side-by-side TestFlight exact App Store Connect team-key ID'

CASE=$(new_case testflight-api-key-directory)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_ASC_API_KEY_DIRECTORY="/Users/ahmed/Library/Application Support/opensteamer-release-credentials"' \
  'EXPECTED_ASC_API_KEY_DIRECTORY="/Users/ahmed/Downloads"'
require_rejection "$CASE" 'side-by-side TestFlight fixed external API-key directory'

CASE=$(new_case testflight-api-key-file-mode)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_ASC_API_KEY_FILE_MODE="600"' \
  'EXPECTED_ASC_API_KEY_FILE_MODE="644"'
require_rejection "$CASE" 'side-by-side TestFlight private API-key file mode'

CASE=$(new_case testflight-api-key-digest)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_ASC_P8_SHA256="22d0dffa775141c5bedb6eb255fb909f50f0547f1997f2ff9ad92609afce5300"' \
  'EXPECTED_ASC_P8_SHA256="0000000000000000000000000000000000000000000000000000000000000000"'
require_rejection "$CASE" 'side-by-side TestFlight exact API-key byte digest'

CASE=$(new_case testflight-api-key-stdin-digest-parser)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'NR == 1 && NF == 2 && $2 == "-" && length($1) == 64 && $1 !~ /[^0-9a-f]/ { print $1 }' \
  'NR == 1 && NF == 2 && length($1) == 64 && $1 !~ /[^0-9a-f]/ { print $1 }'
require_rejection "$CASE" 'side-by-side TestFlight private-key stdin digest parser'

CASE=$(new_case testflight-api-key-vector-digest)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_ASC_API_KEY_XCODEBUILD_ARGUMENTS_SHA256="8116cc2c29c6b7781770f13ca76f39a605d705655f7a619907ec21ac9afb7399"' \
  'EXPECTED_ASC_API_KEY_XCODEBUILD_ARGUMENTS_SHA256="0000000000000000000000000000000000000000000000000000000000000000"'
require_rejection "$CASE" 'side-by-side TestFlight exact API-key authentication-vector digest'

CASE=$(new_case testflight-api-key-inherited-fd)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'sysopen -r -o nofollow,cloexec -u TESTFLIGHT_ASC_API_KEY_FD \' \
  'sysopen -r -o nofollow -u TESTFLIGHT_ASC_API_KEY_FD \'
require_rejection "$CASE" 'side-by-side TestFlight non-inherited no-follow API-key pin'

CASE=$(new_case testflight-api-key-acl-inspection)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'LC_ALL=C /bin/ls -lde "$1" 2>/dev/null \' \
  'LC_ALL=C /bin/ls -ld "$1" 2>/dev/null \'
require_rejection "$CASE" 'side-by-side TestFlight ACL-aware metadata inspection'

CASE=$(new_case testflight-api-key-missing-archive-auth)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'-archivePath "${TESTFLIGHT_ARCHIVE_PATH}" \\\n    -allowProvisioningUpdates \\\n    "${TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS[@]}" \\' \
  $'-archivePath "${TESTFLIGHT_ARCHIVE_PATH}" \\\n    -allowProvisioningUpdates \\'
require_rejection "$CASE" 'side-by-side TestFlight exact API-key vector on archive and export'

CASE=$(new_case testflight-api-key-missing-export-auth)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'-exportPath "${TESTFLIGHT_EXPORT_DIRECTORY}" \\\n    -allowProvisioningUpdates \\\n    "${TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS[@]}" \\' \
  $'-exportPath "${TESTFLIGHT_EXPORT_DIRECTORY}" \\\n    -allowProvisioningUpdates \\'
require_rejection "$CASE" 'side-by-side TestFlight exact API-key vector on archive and export'

CASE=$(new_case testflight-api-key-upload-wrapper)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'function run_authorized_api_key_upload() {\n  pin_app_store_connect_api_key_identity \\\n    || fail "reviewed App Store Connect API key is missing, changed, or unsafe (${TESTFLIGHT_ASC_API_KEY_PIN_FAILURE})"\n  run_authorized_upload\n}' \
  $'function run_authorized_api_key_upload() {\n  run_authorized_upload\n}'
require_rejection "$CASE" 'side-by-side TestFlight API-key pin-before-upload wrapper'

CASE=$(new_case testflight-app-store-processing-wait)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function wait_for_app_store_processing() {' \
  'function skip_app_store_processing() {'
require_rejection "$CASE" 'side-by-side TestFlight automated Apple processing wait'

CASE=$(new_case testflight-app-store-processing-wait-reachability)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'    stage_started_at=${SECONDS}\n    wait_for_app_store_processing \\\n      || fail "Apple did not confirm the uploaded internal build as VALID"\n    print_release_stage_timing app_store_processing "${stage_started_at}"' \
  $'    stage_started_at=${SECONDS}\n    true # Apple processing wait omitted\n    print_release_stage_timing app_store_processing "${stage_started_at}"'
require_rejection "$CASE" \
  'side-by-side TestFlight API-key processing wait reachability and order'

CASE=$(new_case testflight-app-store-processing-deadline)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'APP_STORE_PROCESSING_WAIT_TIMEOUT_SECONDS=1800' \
  'APP_STORE_PROCESSING_WAIT_TIMEOUT_SECONDS=86400'
require_rejection "$CASE" \
  'side-by-side TestFlight bounded Apple processing deadline'

CASE=$(new_case testflight-app-store-processing-poll-interval)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'APP_STORE_PROCESSING_WAIT_POLL_SECONDS=5' \
  'APP_STORE_PROCESSING_WAIT_POLL_SECONDS=300'
require_rejection "$CASE" \
  'side-by-side TestFlight bounded Apple processing poll interval'

CASE=$(new_case testflight-app-store-processing-termination-grace)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'APP_STORE_PROCESSING_TERMINATION_GRACE_SECONDS=5' \
  'APP_STORE_PROCESSING_TERMINATION_GRACE_SECONDS=300'
require_rejection "$CASE" \
  'side-by-side TestFlight bounded Apple processing termination grace'

CASE=$(new_case testflight-app-store-processing-signal-masked-launch)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  mask_release_cleanup_signals\n  /usr/bin/env -i \\\n    LC_ALL=C' \
  $'  /usr/bin/env -i \\\n    LC_ALL=C'
require_rejection "$CASE" \
  'side-by-side TestFlight signal-masked processing-query launch'

CASE=$(new_case testflight-app-store-processing-state-publication)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'    >"/dev/fd/${TESTFLIGHT_PROCESSING_STATUS_FD}" &\n  TESTFLIGHT_PROCESSING_QUERY_PID=$!\n  TESTFLIGHT_PROCESSING_QUERY_RUNNING=1\n  install_release_signal_traps' \
  $'    >"/dev/fd/${TESTFLIGHT_PROCESSING_STATUS_FD}" &\n  TESTFLIGHT_PROCESSING_QUERY_PID=$!\n  install_release_signal_traps\n  TESTFLIGHT_PROCESSING_QUERY_RUNNING=1'
require_rejection "$CASE" \
  'side-by-side TestFlight processing-query atomic state publication'

CASE=$(new_case testflight-app-store-processing-terminated-state-order)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  wait "${TESTFLIGHT_PROCESSING_QUERY_PID}" 2>/dev/null || true\n  TESTFLIGHT_PROCESSING_QUERY_RUNNING=0\n  TESTFLIGHT_PROCESSING_QUERY_PID=-1' \
  $'  wait "${TESTFLIGHT_PROCESSING_QUERY_PID}" 2>/dev/null || true\n  TESTFLIGHT_PROCESSING_QUERY_PID=-1\n  TESTFLIGHT_PROCESSING_QUERY_RUNNING=0'
require_rejection "$CASE" \
  'side-by-side TestFlight terminated-query reaped state ordering'

CASE=$(new_case testflight-app-store-processing-completed-state-order)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'    wait "${TESTFLIGHT_PROCESSING_QUERY_PID}" || query_status=$?\n    TESTFLIGHT_PROCESSING_QUERY_RUNNING=0\n    TESTFLIGHT_PROCESSING_QUERY_PID=-1' \
  $'    wait "${TESTFLIGHT_PROCESSING_QUERY_PID}" || query_status=$?\n    TESTFLIGHT_PROCESSING_QUERY_PID=-1\n    TESTFLIGHT_PROCESSING_QUERY_RUNNING=0'
require_rejection "$CASE" \
  'side-by-side TestFlight completed-query reaped state ordering'

CASE=$(new_case testflight-app-store-processing-post-kill-bound)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'    /bin/kill -KILL "${TESTFLIGHT_PROCESSING_QUERY_PID}" 2>/dev/null || return 1\n    termination_deadline=$((\n      SECONDS + APP_STORE_PROCESSING_TERMINATION_GRACE_SECONDS\n    ))\n    while processing_query_is_running \\\n        && (( SECONDS < termination_deadline )); do\n      /bin/sleep 1\n    done\n    processing_query_is_running && return 1' \
  $'    /bin/kill -KILL "${TESTFLIGHT_PROCESSING_QUERY_PID}" 2>/dev/null || return 1\n    true # post-SIGKILL child liveness was not bounded'
require_rejection "$CASE" \
  'side-by-side TestFlight bounded post-SIGKILL processing-query termination'

CASE=$(new_case testflight-app-store-processing-timeout-enforcement)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  while processing_query_is_running \\\n      && (( SECONDS < query_deadline )); do\n    /bin/sleep "${APP_STORE_PROCESSING_WAIT_POLL_SECONDS}"\n  done\n  if processing_query_is_running; then\n    terminate_processing_query || query_status=1\n    (( query_status != 0 )) || query_status=124' \
  $'  while processing_query_is_running; do\n    /bin/sleep "${APP_STORE_PROCESSING_WAIT_POLL_SECONDS}"\n  done\n  if processing_query_is_running; then\n    terminate_processing_query || query_status=1\n    (( query_status != 0 )) || query_status=124'
require_rejection "$CASE" \
  'side-by-side TestFlight processing-query timeout enforcement'

CASE=$(new_case testflight-app-store-processing-independent-tmp)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '    TMPDIR="${TESTFLIGHT_PROCESSING_TMP_DIRECTORY}" \' \
  '    TMPDIR="${TESTFLIGHT_BUILD_TMP_DIRECTORY}" \'
require_rejection "$CASE" \
  'side-by-side TestFlight independent processing TMPDIR use'

CASE=$(new_case testflight-app-store-processing-tmp-cleanup)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  exec {TESTFLIGHT_PROCESSING_STATUS_FD}>&-\n  TESTFLIGHT_PROCESSING_STATUS_FD=-1\n  remove_processing_tmp_directory || query_status=1\n  (( query_status == 0 )) || return ${query_status}' \
  $'  exec {TESTFLIGHT_PROCESSING_STATUS_FD}>&-\n  TESTFLIGHT_PROCESSING_STATUS_FD=-1\n  true # processing TMPDIR cleanup omitted\n  (( query_status == 0 )) || return ${query_status}'
require_rejection "$CASE" \
  'side-by-side TestFlight bounded processing-query cleanup order'

CASE=$(new_case testflight-app-store-processing-exit-cleanup)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '  terminate_processing_query || cleanup_failed=1' \
  '  true # processing-query exit cleanup omitted'
require_rejection "$CASE" \
  'side-by-side TestFlight exit cleanup terminates processing before release cleanup'

CASE=$(new_case testflight-build-cache-cleanup-before-processing)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  cleanup_private_build_volume_signal_masked \\\n    || fail "could not clean the exact private build volume before Apple processing"' \
  '  true # private build cache cleanup omitted'
require_rejection "$CASE" \
  'side-by-side TestFlight cache cleanup before processing and no post-cleanup archive rescan'

CASE=$(new_case testflight-app-store-build-status-operation)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '    --build-status \' \
  '    --list-providers \'
require_rejection "$CASE" 'side-by-side TestFlight exact App Store build-status operation'

CASE=$(new_case testflight-app-store-delivery-binding)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '    --delivery-id "${TESTFLIGHT_DELIVERY_ID}" \' \
  '    --delivery-id "00000000-0000-0000-0000-000000000000" \'
require_rejection "$CASE" 'side-by-side TestFlight upload-bound processing wait'

CASE=$(new_case testflight-app-store-terminal-wait)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '    --wait \' \
  '    --show-progress \'
require_rejection "$CASE" 'side-by-side TestFlight terminal Apple processing wait'

CASE=$(new_case testflight-app-store-valid-status-verifier)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function verify_app_store_processing_status() {' \
  'function accept_app_store_processing_status() {'
require_rejection "$CASE" 'side-by-side TestFlight terminal VALID status verifier'

CASE=$(new_case testflight-app-store-json-status-parser)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '/usr/bin/plutil -convert xml1 -o /dev/null -- \' \
  '/usr/bin/plutil -lint \'
require_rejection "$CASE" 'side-by-side TestFlight JSON processing-status parser'

CASE=$(new_case testflight-build-root)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'TESTFLIGHT_BUILD_ROOT="/Volumes/t7"' \
  'TESTFLIGHT_BUILD_ROOT="/Applications/AudioStreamer Host.app"'
require_rejection "$CASE" 'side-by-side TestFlight fixed T7 build root'

CASE=$(new_case testflight-build-root-volume-uuid)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_TESTFLIGHT_BUILD_ROOT_VOLUME_UUID="25E93573-3993-42CC-8EE8-4F7A6C86A2EF"' \
  'EXPECTED_TESTFLIGHT_BUILD_ROOT_VOLUME_UUID="00000000-0000-0000-0000-000000000000"'
require_rejection "$CASE" 'side-by-side TestFlight reviewed T7 volume UUID'

CASE=$(new_case testflight-build-root-physical-store-uuid)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_TESTFLIGHT_BUILD_ROOT_PHYSICAL_STORE_UUID="CE1B73D9-E28D-40D2-8D37-D81F2C3F1051"' \
  'EXPECTED_TESTFLIGHT_BUILD_ROOT_PHYSICAL_STORE_UUID="00000000-0000-0000-0000-000000000000"'
require_rejection "$CASE" 'side-by-side TestFlight reviewed T7 physical-store UUID'

CASE=$(new_case testflight-build-root-media-name)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_TESTFLIGHT_BUILD_ROOT_MEDIA_NAME="PSSD T7"' \
  'EXPECTED_TESTFLIGHT_BUILD_ROOT_MEDIA_NAME="Unreviewed Disk"'
require_rejection "$CASE" 'side-by-side TestFlight reviewed T7 physical-media name'

CASE=$(new_case testflight-build-root-physical-size)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_TESTFLIGHT_BUILD_ROOT_PHYSICAL_SIZE="1000204886016"' \
  'EXPECTED_TESTFLIGHT_BUILD_ROOT_PHYSICAL_SIZE="0"'
require_rejection "$CASE" 'side-by-side TestFlight reviewed T7 physical size'

CASE=$(new_case testflight-build-image-total-bytes)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'TESTFLIGHT_BUILD_IMAGE_TOTAL_BYTES="68719476736"' \
  'TESTFLIGHT_BUILD_IMAGE_TOTAL_BYTES="68719476735"'
require_rejection "$CASE" 'side-by-side TestFlight exact sparse-image byte capacity'

CASE=$(new_case testflight-build-image-sector-count)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'TESTFLIGHT_BUILD_IMAGE_SECTOR_COUNT="134217728"' \
  'TESTFLIGHT_BUILD_IMAGE_SECTOR_COUNT="134217727"'
require_rejection "$CASE" 'side-by-side TestFlight exact sparse-image sector capacity'

CASE=$(new_case testflight-build-image-encryption-algorithm)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'TESTFLIGHT_BUILD_IMAGE_ENCRYPTION="AES-256"' \
  'TESTFLIGHT_BUILD_IMAGE_ENCRYPTION="AES-128"'
require_rejection "$CASE" 'side-by-side TestFlight exact sparse-image encryption algorithm'

CASE=$(new_case testflight-persistent-cache-schema)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'TESTFLIGHT_BUILD_CACHE_SCHEMA="opensteamer-testflight-build-cache-v1"' \
  'TESTFLIGHT_BUILD_CACHE_SCHEMA="opensteamer-testflight-build-cache-unreviewed"'
require_rejection "$CASE" 'side-by-side TestFlight persistent cache schema'

CASE=$(new_case testflight-persistent-cache-root)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'TESTFLIGHT_BUILD_CACHE_ROOT="${TESTFLIGHT_BUILD_ROOT}/.${TESTFLIGHT_BUILD_CACHE_SCHEMA}"' \
  'TESTFLIGHT_BUILD_CACHE_ROOT="/Applications/AudioStreamer Host.app"'
require_rejection "$CASE" 'side-by-side TestFlight fixed persistent cache root'

CASE=$(new_case testflight-persistent-cache-key)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_TESTFLIGHT_BUILD_KEY_PATH="${EXPECTED_ASC_API_KEY_DIRECTORY}/${TESTFLIGHT_BUILD_CACHE_SCHEMA}.key"' \
  'EXPECTED_TESTFLIGHT_BUILD_KEY_PATH="/private/tmp/unreviewed.key"'
require_rejection "$CASE" 'side-by-side TestFlight fixed persistent cache key'

CASE=$(new_case testflight-persistent-cache-lock)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_TESTFLIGHT_BUILD_LOCK_PATH="${EXPECTED_ASC_API_KEY_DIRECTORY}/${TESTFLIGHT_BUILD_CACHE_SCHEMA}.lock"' \
  'EXPECTED_TESTFLIGHT_BUILD_LOCK_PATH="/private/tmp/unreviewed.lock"'
require_rejection "$CASE" 'side-by-side TestFlight fixed persistent cache lock'

CASE=$(new_case testflight-persistent-cache-mount-root)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'TESTFLIGHT_BUILD_MOUNT_ROOT="${PRIVATE_TEMPORARY_ROOT}/${TESTFLIGHT_BUILD_CACHE_SCHEMA}"' \
  'TESTFLIGHT_BUILD_MOUNT_ROOT="/Applications/AudioStreamer Host.app"'
require_rejection "$CASE" 'side-by-side TestFlight stable persistent cache mount root'

CASE=$(new_case testflight-persistent-cache-lock-acquisition)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'zsystem flock -t 0 -f TESTFLIGHT_BUILD_CACHE_LOCK_FD' \
  'true # persistent cache lock bypassed'
require_rejection "$CASE" 'side-by-side TestFlight nonblocking persistent cache lock'

CASE=$(new_case testflight-persistent-cache-lock-acquisition-reachability)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'function initialize_or_pin_persistent_build_cache_storage() {\n  acquire_persistent_build_cache_lock\n' \
  $'function initialize_or_pin_persistent_build_cache_storage() {\n  true # persistent cache lock acquisition omitted\n'
require_rejection "$CASE" \
  'side-by-side TestFlight persistent cache acquisition reachability and order'

CASE=$(new_case testflight-persistent-cache-lock-release)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'zsystem flock -u "${TESTFLIGHT_BUILD_CACHE_LOCK_FD}"' \
  'true # persistent cache lock leaked'
require_rejection "$CASE" 'side-by-side TestFlight persistent cache lock release'

CASE=$(new_case testflight-persistent-cache-partial-enrollment)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'persistent build-cache enrollment requires clean absent state' \
  'partial cache state accepted'
require_rejection "$CASE" 'side-by-side TestFlight retry-safe enrollment precondition'

CASE=$(new_case testflight-persistent-cache-enrollment-marker-path)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_TESTFLIGHT_BUILD_ENROLLMENT_MARKER_PATH="${EXPECTED_ASC_API_KEY_DIRECTORY}/${TESTFLIGHT_BUILD_CACHE_SCHEMA}.enrollment.pending"' \
  'EXPECTED_TESTFLIGHT_BUILD_ENROLLMENT_MARKER_PATH="/private/tmp/unreviewed.enrollment.pending"'
require_rejection "$CASE" \
  'side-by-side TestFlight fixed durable enrollment marker path'

CASE=$(new_case testflight-persistent-cache-enrollment-marker-content)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'TESTFLIGHT_BUILD_ENROLLMENT_MARKER_CONTENT="opensteamer-testflight-build-cache-enrollment-v1"' \
  'TESTFLIGHT_BUILD_ENROLLMENT_MARKER_CONTENT="opensteamer-testflight-build-cache-enrollment-v0"'
require_rejection "$CASE" \
  'side-by-side TestFlight exact durable enrollment marker content'

CASE=$(new_case testflight-persistent-cache-enrollment-marker-verification)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'      && "$(sha256_file "${TESTFLIGHT_BUILD_ENROLLMENT_MARKER_PATH}")" \\\n        == "${TESTFLIGHT_BUILD_ENROLLMENT_MARKER_SHA256}" \\\n      && ${TESTFLIGHT_BUILD_ENROLLMENT_MARKER_FD} -ge 0' \
  $'      && true # durable marker content accepted without verification \\\n      && ${TESTFLIGHT_BUILD_ENROLLMENT_MARKER_FD} -ge 0'
require_rejection "$CASE" \
  'side-by-side TestFlight durable enrollment marker content verification'

CASE=$(new_case testflight-persistent-cache-enrollment-marker-exclusive-create)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'sysopen -w -o creat,excl,nofollow -m 600 -u marker_writer_fd' \
  'sysopen -w -o creat,trunc,nofollow -m 600 -u marker_writer_fd'
require_rejection "$CASE" \
  'side-by-side TestFlight exclusive durable enrollment marker creation'

CASE=$(new_case testflight-persistent-cache-enrollment-marker-publication)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  /bin/sync\n  /bin/mv -- "${EXPECTED_TESTFLIGHT_BUILD_ENROLLMENT_MARKER_STAGING_PATH}" \\\n    "${EXPECTED_TESTFLIGHT_BUILD_ENROLLMENT_MARKER_PATH}" || return 1\n  /bin/sync' \
  $'  true # pre-publication sync omitted\n  /bin/mv -- "${EXPECTED_TESTFLIGHT_BUILD_ENROLLMENT_MARKER_STAGING_PATH}" \\\n    "${EXPECTED_TESTFLIGHT_BUILD_ENROLLMENT_MARKER_PATH}" || return 1\n  /bin/sync'
require_rejection "$CASE" \
  'side-by-side TestFlight fsynced atomic durable enrollment marker publication'

CASE=$(new_case testflight-persistent-cache-enrollment-staging-recovery)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'function recover_interrupted_build_cache_enrollment() {\n  remove_pending_enrollment_marker_staging_if_safe || return 1\n  if [[ ! -e "${EXPECTED_TESTFLIGHT_BUILD_ENROLLMENT_MARKER_PATH}"' \
  $'function recover_interrupted_build_cache_enrollment() {\n  true # staging-only enrollment recovery omitted\n  if [[ ! -e "${EXPECTED_TESTFLIGHT_BUILD_ENROLLMENT_MARKER_PATH}"'
require_rejection "$CASE" \
  'side-by-side TestFlight staging-only interrupted enrollment recovery reachability'

CASE=$(new_case testflight-persistent-cache-interrupted-enrollment-reachability)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'    recover_interrupted_build_cache_enrollment \\\n      || fail "interrupted persistent build-cache enrollment was not safe to recover"\n    [[ ! -e "${EXPECTED_TESTFLIGHT_BUILD_KEY_PATH}"' \
  $'    true # interrupted enrollment recovery omitted\n    [[ ! -e "${EXPECTED_TESTFLIGHT_BUILD_KEY_PATH}"'
require_rejection "$CASE" \
  'side-by-side TestFlight interrupted enrollment recovery before absent-state enrollment'

CASE=$(new_case testflight-persistent-cache-enrollment-marker-reservation)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'      || fail "persistent build-cache enrollment requires clean absent state"\n    reserve_pending_enrollment_marker \\\n      || fail "could not publish the durable build-cache enrollment marker"' \
  $'      || fail "persistent build-cache enrollment requires clean absent state"\n    true # durable enrollment marker reservation omitted'
require_rejection "$CASE" \
  'side-by-side TestFlight durable marker reservation before enrollment mutation'

CASE=$(new_case testflight-persistent-cache-routine-pending-marker-rejection)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'        && ! -L "${EXPECTED_TESTFLIGHT_BUILD_LOCK_PATH}" \\\n        && ! -e "${EXPECTED_TESTFLIGHT_BUILD_ENROLLMENT_MARKER_PATH}" \\\n        && ! -L "${EXPECTED_TESTFLIGHT_BUILD_ENROLLMENT_MARKER_PATH}" \\\n        && ! -e "${EXPECTED_TESTFLIGHT_BUILD_ENROLLMENT_MARKER_STAGING_PATH}" \\\n        && ! -L "${EXPECTED_TESTFLIGHT_BUILD_ENROLLMENT_MARKER_STAGING_PATH}" \\\n        && -f "${EXPECTED_TESTFLIGHT_BUILD_KEY_PATH}"' \
  $'        && ! -L "${EXPECTED_TESTFLIGHT_BUILD_LOCK_PATH}" \\\n        && -f "${EXPECTED_TESTFLIGHT_BUILD_KEY_PATH}"'
require_rejection "$CASE" \
  'side-by-side TestFlight routine mode rejects pending enrollment markers'

CASE=$(new_case testflight-persistent-cache-interrupted-image-idle-guard)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'    image_lsof_output=$(/usr/sbin/lsof -n -P -- \\\n      "${TESTFLIGHT_BUILD_IMAGE_PATH}" 2>/dev/null) || image_lsof_status=$?\n    (( image_lsof_status == 1 )) && [[ -z "${image_lsof_output}" ]] || return 1' \
  $'    image_lsof_output=\x27\x27\n    image_lsof_status=1\n    true # busy interrupted-enrollment image accepted'
require_rejection "$CASE" \
  'side-by-side TestFlight interrupted enrollment image idle-user guard'

CASE=$(new_case testflight-persistent-cache-interrupted-key-idle-guard)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'    key_lsof_output=$(/usr/sbin/lsof -n -P -- \\\n      "${TESTFLIGHT_BUILD_KEY_PATH}" 2>/dev/null) || key_lsof_status=$?\n    (( key_lsof_status == 1 )) && [[ -z "${key_lsof_output}" ]] || return 1' \
  $'    key_lsof_output=\x27\x27\n    key_lsof_status=1\n    true # busy interrupted-enrollment key accepted'
require_rejection "$CASE" \
  'side-by-side TestFlight interrupted enrollment key idle-user guard'

CASE=$(new_case testflight-persistent-cache-interrupted-root-rollback-order)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'    /bin/rmdir -- "${TESTFLIGHT_BUILD_CACHE_ROOT}" || return 1\n  fi\n\n  if [[ -e "${EXPECTED_TESTFLIGHT_BUILD_KEY_PATH}"' \
  $'    true # interrupted enrollment root preserved\n  fi\n\n  if [[ -e "${EXPECTED_TESTFLIGHT_BUILD_KEY_PATH}"'
require_rejection "$CASE" \
  'side-by-side TestFlight interrupted enrollment root rollback before key'

CASE=$(new_case testflight-persistent-cache-interrupted-key-marker-order)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'    /bin/rm -- "${TESTFLIGHT_BUILD_KEY_PATH}" || return 1\n  fi\n\n  remove_pending_enrollment_marker || return 1\n  /bin/sync' \
  $'    true # interrupted enrollment key preserved\n  fi\n\n  remove_pending_enrollment_marker || return 1\n  /bin/sync'
require_rejection "$CASE" \
  'side-by-side TestFlight interrupted enrollment key and marker rollback order'

CASE=$(new_case testflight-persistent-cache-enrollment-marker-pre-remove-sync)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  mask_release_cleanup_signals\n  /bin/sync\n  remove_pending_enrollment_marker \\\n    || fail "could not commit the persistent build-cache enrollment marker"\n  /bin/sync\n  TESTFLIGHT_BUILD_CACHE_ENROLLMENT_COMMITTED=1\n  install_release_signal_traps' \
  $'  mask_release_cleanup_signals\n  remove_pending_enrollment_marker \\\n    || fail "could not commit the persistent build-cache enrollment marker"\n  /bin/sync\n  TESTFLIGHT_BUILD_CACHE_ENROLLMENT_COMMITTED=1\n  install_release_signal_traps'
require_rejection "$CASE" \
  'side-by-side TestFlight durable enrollment commit ordering and sync barriers'

CASE=$(new_case testflight-persistent-cache-enrollment-marker-post-remove-sync)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  mask_release_cleanup_signals\n  /bin/sync\n  remove_pending_enrollment_marker \\\n    || fail "could not commit the persistent build-cache enrollment marker"\n  /bin/sync\n  TESTFLIGHT_BUILD_CACHE_ENROLLMENT_COMMITTED=1\n  install_release_signal_traps' \
  $'  mask_release_cleanup_signals\n  /bin/sync\n  remove_pending_enrollment_marker \\\n    || fail "could not commit the persistent build-cache enrollment marker"\n  TESTFLIGHT_BUILD_CACHE_ENROLLMENT_COMMITTED=1\n  install_release_signal_traps'
require_rejection "$CASE" \
  'side-by-side TestFlight durable enrollment commit ordering and sync barriers'

CASE=$(new_case testflight-persistent-cache-enrollment-marker-lock-owned-cleanup)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  if (( cleanup_failed == 0 \\\n      && TESTFLIGHT_BUILD_CACHE_INITIALIZE_MODE == 1 \\\n      && TESTFLIGHT_BUILD_CACHE_ENROLLMENT_COMMITTED == 0 \\\n      && TESTFLIGHT_BUILD_CACHE_LOCK_FD >= 0 )); then\n    verify_build_cache_lock_identity || cleanup_failed=1\n  fi\n  if (( cleanup_failed == 0 \\\n      && TESTFLIGHT_BUILD_CACHE_INITIALIZE_MODE == 1 \\\n      && TESTFLIGHT_BUILD_CACHE_ENROLLMENT_COMMITTED == 0 \\\n      && TESTFLIGHT_BUILD_CACHE_LOCK_FD >= 0 )); then\n    if [[ -e "${EXPECTED_TESTFLIGHT_BUILD_ENROLLMENT_MARKER_PATH}"' \
  $'  if (( cleanup_failed == 0 \\\n      && TESTFLIGHT_BUILD_CACHE_INITIALIZE_MODE == 1 \\\n      && TESTFLIGHT_BUILD_CACHE_ENROLLMENT_COMMITTED == 0 )); then\n    if [[ -e "${EXPECTED_TESTFLIGHT_BUILD_ENROLLMENT_MARKER_PATH}"'
require_rejection "$CASE" \
  'side-by-side TestFlight lock-owned enrollment journal cleanup'

CASE=$(new_case testflight-persistent-cache-contract-verifier)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function verify_persistent_build_cache_contract() {' \
  'function ignore_persistent_build_cache_contract() {'
require_rejection "$CASE" 'side-by-side TestFlight persistent cache contract verifier'

CASE=$(new_case testflight-persistent-cache-recovery)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function recover_stale_persistent_build_cache_state() {' \
  'function ignore_stale_persistent_build_cache_state() {'
require_rejection "$CASE" 'side-by-side TestFlight killed-run cache recovery'

CASE=$(new_case testflight-persistent-cache-recovery-reachability)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  initialize_or_pin_persistent_build_cache_storage\n  recover_stale_persistent_build_cache_state \\\n    || fail "stale persistent build-cache state was not identity-safe to recover"\n  create_stable_build_mount_underlay' \
  $'  initialize_or_pin_persistent_build_cache_storage\n  true # stale persistent cache recovery omitted\n  create_stable_build_mount_underlay'
require_rejection "$CASE" \
  'side-by-side TestFlight stale recovery reachability and order'

CASE=$(new_case testflight-persistent-cache-recovery-idle-user-guard)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'    lsof_output=$(/usr/sbin/lsof -n -P +D \\\n      "${TESTFLIGHT_BUILD_MOUNT_POINT}" 2>/dev/null) || lsof_status=$?\n    (( lsof_status == 1 )) && [[ -z "${lsof_output}" ]] || return 1\n\n    # The nonblocking lock proves no conforming release is active.' \
  $'    lsof_output=\x27\x27\n    lsof_status=1\n    true # busy stale attachment accepted\n\n    # The nonblocking lock proves no conforming release is active.'
require_rejection "$CASE" \
  'side-by-side TestFlight stale recovery idle-user guard'

CASE=$(new_case testflight-persistent-cache-underlay-recovery)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function remove_exact_stale_build_mount_underlay() {' \
  'function ignore_exact_stale_build_mount_underlay() {'
require_rejection "$CASE" 'side-by-side TestFlight exact stale-underlay recovery'

CASE=$(new_case testflight-persistent-cache-enrollment-commit)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '  TESTFLIGHT_BUILD_CACHE_ENROLLMENT_COMMITTED=1' \
  '  true # enrollment completion not published'
require_rejection "$CASE" 'side-by-side TestFlight enrollment completion publication'

CASE=$(new_case testflight-persistent-cache-contract-fields)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '/usr/bin/plutil -insert sdk -string iphoneos' \
  '/usr/bin/plutil -replace sdk -string iphoneos'
require_rejection "$CASE" 'side-by-side TestFlight exact persistent cache contract fields'

CASE=$(new_case testflight-persistent-cache-contract-staging)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'local pending_contract="${TESTFLIGHT_BUILD_CACHE_CONTRACT_PATH}.pending"' \
  'local pending_contract="${TESTFLIGHT_BUILD_CACHE_CONTRACT_PATH}"'
require_rejection "$CASE" 'side-by-side TestFlight atomic cache-contract staging'

CASE=$(new_case testflight-persistent-cache-contract-publication)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '/bin/mv -- "${pending_contract}" "${TESTFLIGHT_BUILD_CACHE_CONTRACT_PATH}"' \
  '/bin/cp -- "${pending_contract}" "${TESTFLIGHT_BUILD_CACHE_CONTRACT_PATH}"'
require_rejection "$CASE" 'side-by-side TestFlight atomic cache-contract publication'

CASE=$(new_case testflight-persistent-cache-workspace-identity)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'TESTFLIGHT_BUILD_WORKSPACE_KEY=$(string_vector_sha256 "${REPOSITORY_ROOT}")' \
  'TESTFLIGHT_BUILD_WORKSPACE_KEY=$(string_vector_sha256 "${EXPECTED_BUILD_NUMBER}")'
require_rejection "$CASE" 'side-by-side TestFlight checkout-specific DerivedData identity'

CASE=$(new_case testflight-persistent-cache-workspace-pending-key)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'local pending_workspace_root="${workspaces_root}/.workspace-${TESTFLIGHT_BUILD_WORKSPACE_KEY}.pending"' \
  'local pending_workspace_root="${workspaces_root}/.workspace-unreviewed.pending"'
require_rejection "$CASE" \
  'side-by-side TestFlight deterministic checkout-workspace staging path'

CASE=$(new_case testflight-persistent-cache-workspace-staging-cardinality)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '(( ${#children[@]} == 4 )) || return 1' \
  '(( ${#children[@]} >= 3 )) || return 1'
require_rejection "$CASE" \
  'side-by-side TestFlight exact staged workspace cardinality'

CASE=$(new_case testflight-persistent-cache-workspace-staging-whitelist)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'function workspace_staging_directory_is_exact_and_empty() {\n  local workspace_root=$1\n  require_owned_private_directory "${workspace_root}" || return 1\n  local workspace_identity\n  workspace_identity=$(stat_identity "${workspace_root}") || return 1\n  local -a children=("${workspace_root}"/*(ND))\n  (( ${#children[@]} == 4 )) || return 1\n  local child\n  local child_name\n  local child_identity\n  local -a nested_children=()\n  for child in "${children[@]}"; do\n    child_name=${child:t}\n    case "${child_name}" in\n      run-tmp|DerivedData|Products|Intermediates)' \
  $'function workspace_staging_directory_is_exact_and_empty() {\n  local workspace_root=$1\n  require_owned_private_directory "${workspace_root}" || return 1\n  local workspace_identity\n  workspace_identity=$(stat_identity "${workspace_root}") || return 1\n  local -a children=("${workspace_root}"/*(ND))\n  (( ${#children[@]} == 4 )) || return 1\n  local child\n  local child_name\n  local child_identity\n  local -a nested_children=()\n  for child in "${children[@]}"; do\n    child_name=${child:t}\n    case "${child_name}" in\n      run-tmp|DerivedData|Products|Intermediates|Unreviewed)'
require_rejection "$CASE" \
  'side-by-side TestFlight exact staged workspace child whitelist'

CASE=$(new_case testflight-persistent-cache-workspace-staging-same-device)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'    [[ "${child_identity%%:*}" == "${workspace_identity%%:*}" ]] \\\n      || return 1' \
  $'    [[ "${child_identity%%:*}" != "${workspace_identity%%:*}" ]] \\\n      || return 1'
require_rejection "$CASE" \
  'side-by-side TestFlight staged workspace child same-device proof'

CASE=$(new_case testflight-persistent-cache-workspace-pending-same-device)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'      *)\n        return 1\n        ;;\n    esac\n    require_owned_private_directory "${child}" || return 1\n    child_identity=$(stat_identity "${child}") || return 1\n    [[ "${child_identity%%:*}" \\\n        == "${pending_workspace_identity%%:*}" ]] || return 1' \
  $'      *)\n        return 1\n        ;;\n    esac\n    require_owned_private_directory "${child}" || return 1\n    child_identity=$(stat_identity "${child}") || return 1\n    [[ "${child_identity%%:*}" \\\n        != "${pending_workspace_identity%%:*}" ]] || return 1'
require_rejection "$CASE" \
  'side-by-side TestFlight pending workspace child same-device proof'

CASE=$(new_case testflight-persistent-cache-workspace-partial-resume-helper)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function populate_or_verify_pending_workspace_directory() {' \
  'function accept_partial_workspace_directory_without_verification() {'
require_rejection "$CASE" \
  'side-by-side TestFlight safe partial workspace-staging recovery'

CASE=$(new_case testflight-persistent-cache-existing-workspace-verifier)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function verify_existing_workspace_directory() {' \
  'function accept_existing_workspace_directory() {'
require_rejection "$CASE" \
  'side-by-side TestFlight existing workspace fail-closed verifier'

CASE=$(new_case testflight-persistent-cache-workspace-prepublish-lock)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  populate_or_verify_pending_workspace_directory \\\n    "${pending_workspace_root}" "${pending_workspace_identity}" || return 1\n\n  /bin/sync\n  verify_build_cache_lock_identity || return 1' \
  $'  populate_or_verify_pending_workspace_directory \\\n    "${pending_workspace_root}" "${pending_workspace_identity}" || return 1\n\n  /bin/sync\n  true # pre-publish cache-lock proof omitted'
require_rejection "$CASE" \
  'side-by-side TestFlight atomic checkout-workspace lock fencing'

CASE=$(new_case testflight-persistent-cache-workspace-postpublish-lock)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  publish_workspace_directory_exclusively \\\n    "${pending_workspace_root}" "${workspace_root}" "${workspaces_root}" \\\n    "${workspaces_root_identity}" \\\n    || return 1\n  /bin/sync\n  verify_build_cache_lock_identity || return 1' \
  $'  publish_workspace_directory_exclusively \\\n    "${pending_workspace_root}" "${workspace_root}" "${workspaces_root}" \\\n    "${workspaces_root_identity}" \\\n    || return 1\n  /bin/sync\n  true # post-publish cache-lock proof omitted'
require_rejection "$CASE" \
  'side-by-side TestFlight atomic checkout-workspace lock fencing'

CASE=$(new_case testflight-persistent-cache-workspace-prepublish-sync)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  populate_or_verify_pending_workspace_directory \\\n    "${pending_workspace_root}" "${pending_workspace_identity}" || return 1\n\n  /bin/sync\n  verify_build_cache_lock_identity || return 1' \
  $'  populate_or_verify_pending_workspace_directory \\\n    "${pending_workspace_root}" "${pending_workspace_identity}" || return 1\n\n  true # pre-publish sync omitted\n  verify_build_cache_lock_identity || return 1'
require_rejection "$CASE" \
  'side-by-side TestFlight durable checkout-workspace publication'

CASE=$(new_case testflight-persistent-cache-workspace-postpublish-sync)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  publish_workspace_directory_exclusively \\\n    "${pending_workspace_root}" "${workspace_root}" "${workspaces_root}" \\\n    "${workspaces_root_identity}" \\\n    || return 1\n  /bin/sync\n  verify_build_cache_lock_identity || return 1' \
  $'  publish_workspace_directory_exclusively \\\n    "${pending_workspace_root}" "${workspace_root}" "${workspaces_root}" \\\n    "${workspaces_root_identity}" \\\n    || return 1\n  true # post-publish sync omitted\n  verify_build_cache_lock_identity || return 1'
require_rejection "$CASE" \
  'side-by-side TestFlight durable checkout-workspace publication'

CASE=$(new_case testflight-persistent-cache-workspace-exclusive-publisher)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function publish_workspace_directory_exclusively() {' \
  'function publish_workspace_directory_with_clobbering() {'
require_rejection "$CASE" \
  'side-by-side TestFlight exclusive workspace publisher'

CASE=$(new_case testflight-persistent-cache-workspace-exclusive-rename-primitive)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'Fiddle.dlopen(nil)["renameatx_np"]' \
  'Fiddle.dlopen(nil)["renameat_np"]'
require_rejection "$CASE" \
  'side-by-side TestFlight Darwin exclusive same-volume rename primitive'

CASE=$(new_case testflight-persistent-cache-workspace-exclusive-rename-flags)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'rename_excl = 0x4; rename_nofollow_any = 0x10;' \
  'rename_excl = 0x0; rename_nofollow_any = 0x0;'
require_rejection "$CASE" \
  'side-by-side TestFlight exclusive no-follow workspace rename flags'

CASE=$(new_case testflight-persistent-cache-workspace-exclusive-beneath-flag)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'rename_resolve_beneath = 0x20;' \
  'rename_resolve_beneath = 0x0;'
require_rejection "$CASE" \
  'side-by-side TestFlight descriptor-beneath workspace rename flag'

CASE=$(new_case testflight-persistent-cache-workspace-exclusive-rename-environment)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '/usr/bin/ruby --disable=gems,rubyopt -e "${rename_program}" --' \
  '/usr/bin/ruby -e "${rename_program}" --'
require_rejection "$CASE" \
  'side-by-side TestFlight environment-scrubbed system exclusive rename caller'

CASE=$(new_case testflight-persistent-cache-workspace-parent-descriptor)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'parent_file = File.open(ARGV.fetch(0), File::RDONLY | File::NOFOLLOW);' \
  'parent_file = File.open(ARGV.fetch(0), File::RDONLY);'
require_rejection "$CASE" \
  'side-by-side TestFlight no-follow workspace-parent descriptor'

CASE=$(new_case testflight-persistent-cache-workspace-parent-descriptor-identity)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'parent_stat.dev == Integer(ARGV.fetch(1), 10) && parent_stat.ino == Integer(ARGV.fetch(2), 10)' \
  'parent_stat.dev == Integer(ARGV.fetch(1), 10)'
require_rejection "$CASE" \
  'side-by-side TestFlight workspace-parent descriptor identity proof'

CASE=$(new_case testflight-persistent-cache-workspace-exclusive-publish-call)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  publish_workspace_directory_exclusively \\\n    "${pending_workspace_root}" "${workspace_root}" "${workspaces_root}" \\\n    "${workspaces_root_identity}" \\\n    || return 1' \
  $'  publish_workspace_directory_exclusively \\\n    "${pending_workspace_root}" "${workspace_root}" "${workspaces_root}" \\\n    "unreviewed-parent-identity" \\\n    || return 1'
require_rejection "$CASE" \
  'side-by-side TestFlight exclusive checkout-workspace publication'

CASE=$(new_case testflight-persistent-cache-workspace-published-inode-proof)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'      && "$(stat_identity "${workspace_root}")" \\\n        == "${pending_workspace_identity}" ]] || return 1' \
  $'      && "$(stat_identity "${workspace_root}")" \\\n        != "${pending_workspace_identity}" ]] || return 1'
require_rejection "$CASE" \
  'side-by-side TestFlight published workspace inode proof'

CASE=$(new_case testflight-persistent-cache-workspace-published-identity-handoff)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'TESTFLIGHT_BUILD_SANDBOX_IDENTITY="${pending_workspace_identity}"' \
  'TESTFLIGHT_BUILD_SANDBOX_IDENTITY="" # published inode handoff omitted'
require_rejection "$CASE" \
  'side-by-side TestFlight published workspace identity handoff'

CASE=$(new_case testflight-persistent-cache-workspace-existing-identity-handoff)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'TESTFLIGHT_BUILD_SANDBOX_IDENTITY="${existing_workspace_identity}"' \
  'TESTFLIGHT_BUILD_SANDBOX_IDENTITY="" # existing inode handoff omitted'
require_rejection "$CASE" \
  'side-by-side TestFlight existing workspace identity handoff'

CASE=$(new_case testflight-persistent-cache-workspace-child-identity-handoff)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function capture_verified_workspace_child_identities() {' \
  'function capture_unverified_workspace_child_identities() {'
require_rejection "$CASE" \
  'side-by-side TestFlight workspace-child identity handoff'

CASE=$(new_case testflight-persistent-cache-workspace-child-identity-constraint)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'local required_identity=${3:-}' \
  'local required_identity="" # captured child identity ignored'
require_rejection "$CASE" \
  'side-by-side TestFlight verified cache-child identity constraint'

CASE=$(new_case testflight-persistent-cache-workspace-child-identity-consumption)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  initialize_or_pin_cache_directory \\\n    "${TESTFLIGHT_DERIVED_DATA_DIRECTORY}" "${workspace_root}" \\\n    "${TESTFLIGHT_BUILD_EXPECTED_DERIVED_DATA_IDENTITY}" || return 1\n  initialize_or_pin_cache_directory \\\n    "${TESTFLIGHT_BUILD_PRODUCTS_DIRECTORY}" "${workspace_root}" \\\n    "${TESTFLIGHT_BUILD_EXPECTED_PRODUCTS_IDENTITY}" || return 1\n  initialize_or_pin_cache_directory \\\n    "${TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY}" "${workspace_root}" \\\n    "${TESTFLIGHT_BUILD_EXPECTED_INTERMEDIATES_IDENTITY}" || return 1' \
  $'  initialize_or_pin_cache_directory \\\n    "${TESTFLIGHT_DERIVED_DATA_DIRECTORY}" "${workspace_root}" \\\n    "" || return 1\n  initialize_or_pin_cache_directory \\\n    "${TESTFLIGHT_BUILD_PRODUCTS_DIRECTORY}" "${workspace_root}" \\\n    "" || return 1\n  initialize_or_pin_cache_directory \\\n    "${TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY}" "${workspace_root}" \\\n    "" || return 1'
require_rejection "$CASE" \
  'side-by-side TestFlight verified workspace-child identity consumption'

CASE=$(new_case testflight-persistent-cache-workspace-run-tmp-identity-consumption)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  initialize_or_migrate_run_tmp_parent_directory \\\n    "${TESTFLIGHT_BUILD_RUN_TMP_PARENT_DIRECTORY}" "${workspace_root}" \\\n    "${TESTFLIGHT_BUILD_SANDBOX_IDENTITY}" \\\n    "${TESTFLIGHT_BUILD_EXPECTED_RUN_TMP_PARENT_IDENTITY}" || return 1' \
  $'  initialize_or_migrate_run_tmp_parent_directory \\\n    "${TESTFLIGHT_BUILD_RUN_TMP_PARENT_DIRECTORY}" "${workspace_root}" \\\n    "${TESTFLIGHT_BUILD_SANDBOX_IDENTITY}" \\\n    "" || return 1'
require_rejection "$CASE" \
  'side-by-side TestFlight verified run-TMP identity consumption'

CASE=$(new_case testflight-persistent-cache-workspace-identity-consumption)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  [[ -n "${TESTFLIGHT_BUILD_SANDBOX_IDENTITY}" \\\n      && "$(stat_identity "${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}")" \\\n        == "${TESTFLIGHT_BUILD_SANDBOX_IDENTITY}" ]] || return 1' \
  $'  [[ -n "${TESTFLIGHT_BUILD_SANDBOX_IDENTITY}" \\\n      && "$(stat_identity "${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}")" \\\n        != "${TESTFLIGHT_BUILD_SANDBOX_IDENTITY}" ]] || return 1'
require_rejection "$CASE" \
  'side-by-side TestFlight verified workspace identity consumption'

CASE=$(new_case testflight-persistent-cache-workspace-parent-identity)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'workspaces_root_identity=$(stat_identity "${workspaces_root}") || return 1' \
  'workspaces_root_identity=$(stat_identity "${workspace_root}") || return 1'
require_rejection "$CASE" \
  'side-by-side TestFlight checkout-workspace parent identity fencing'

CASE=$(new_case testflight-persistent-cache-workspace-layout-call)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  initialize_or_provision_workspace_directory \\\n    "${workspace_root}" "${workspaces_root}" || return 1' \
  $'  initialize_or_require_cache_parent_directory \\\n    "${workspace_root}" "${workspaces_root}" || return 1'
require_rejection "$CASE" \
  'side-by-side TestFlight scoped atomic checkout-workspace provisioning call'

CASE=$(new_case testflight-persistent-cache-shared-root)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'local shared_root="${cache_v1}/shared"' \
  'local shared_root="${workspace_root}/shared"'
require_rejection "$CASE" 'side-by-side TestFlight cross-iteration shared dependency cache'

CASE=$(new_case testflight-persistent-cache-run-tmp)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '"${TESTFLIGHT_BUILD_RUN_TMP_PARENT_DIRECTORY}/run.XXXXXX"' \
  '"${TESTFLIGHT_BUILD_RUN_TMP_PARENT_DIRECTORY}/shared"'
require_rejection "$CASE" 'side-by-side TestFlight fresh encrypted per-run TMPDIR'

CASE=$(new_case testflight-persistent-cache-run-tmp-migration)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function initialize_or_migrate_run_tmp_parent_directory() {' \
  'function refuse_legacy_run_tmp_parent_migration() {'
require_rejection "$CASE" 'side-by-side TestFlight legacy-cache run-TMP migration'

CASE=$(new_case testflight-persistent-cache-run-tmp-cleanup)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function remove_current_run_tmp_directory() {' \
  'function preserve_current_run_tmp_directory() {'
require_rejection "$CASE" 'side-by-side TestFlight fresh per-run TMPDIR cleanup'

CASE=$(new_case testflight-persistent-cache-run-tmp-cleanup-reachability)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'      && [[ -n "${TESTFLIGHT_BUILD_TMP_DIRECTORY:-}" ]]; then\n    remove_current_run_tmp_directory || cleanup_failed=1\n  fi' \
  $'      && [[ -n "${TESTFLIGHT_BUILD_TMP_DIRECTORY:-}" ]]; then\n    true # current run-TMP cleanup omitted\n  fi'
require_rejection "$CASE" \
  'side-by-side TestFlight current run-TMP cleanup reachability and order'

CASE=$(new_case testflight-derived-data-xattr-name)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'TESTFLIGHT_DERIVED_DATA_BACKUP_EXCLUSION_XATTR="com.apple.metadata:com_apple_backup_excludeItem"' \
  'TESTFLIGHT_DERIVED_DATA_BACKUP_EXCLUSION_XATTR="com.example.unreviewed"'
require_rejection "$CASE" 'side-by-side TestFlight exact Xcode backup-exclusion xattr'

CASE=$(new_case testflight-derived-data-xattr-digest)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'TESTFLIGHT_DERIVED_DATA_BACKUP_EXCLUSION_XATTR_SHA256="1cb8eb62affde4c49d785fafeddd9b210838894d525505fe9cf448c7ecf9970c"' \
  'TESTFLIGHT_DERIVED_DATA_BACKUP_EXCLUSION_XATTR_SHA256="0000000000000000000000000000000000000000000000000000000000000000"'
require_rejection "$CASE" 'side-by-side TestFlight exact Xcode backup-exclusion xattr bytes'

CASE=$(new_case testflight-persistent-cache-key-rollback)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '            remove_exact_private_file "${TESTFLIGHT_BUILD_KEY_PATH}"' \
  '            remove_exact_private_file "/Applications/AudioStreamer Host.app"'
require_rejection "$CASE" 'side-by-side TestFlight failed-enrollment key rollback'

CASE=$(new_case testflight-release-stage-timing-evidence)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function print_release_stage_timing() {' \
  'function ignore_release_stage_timing() {'
require_rejection "$CASE" 'side-by-side TestFlight release-stage timing evidence'

CASE=$(new_case testflight-complete-release-stage-timing)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '  print_release_stage_timing build_settings "${stage_started_at}"' \
  '  true # build-settings timing omitted'
require_rejection "$CASE" 'side-by-side TestFlight complete routine stage timing'

CASE=$(new_case testflight-build-image-type)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '-type SPARSE' \
  '-type UDIF'
require_rejection "$CASE" 'side-by-side TestFlight sparse-image creation'

CASE=$(new_case testflight-archive-action-settings-proof)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'archive -showBuildSettings -json' \
  'build -showBuildSettings -json'
require_rejection "$CASE" 'side-by-side TestFlight archive-action settings proof'

CASE=$(new_case testflight-build-image-size)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '-size "${TESTFLIGHT_BUILD_IMAGE_SIZE}"' \
  '-size "1t"'
require_rejection "$CASE" 'side-by-side TestFlight bounded sparse-image creation'

CASE=$(new_case testflight-build-image-filesystem)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '-fs APFS' \
  '-fs "Journaled HFS+"'
require_rejection "$CASE" 'side-by-side TestFlight private APFS creation'

CASE=$(new_case testflight-build-image-encryption)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '-encryption AES-256' \
  '-encryption AES-128'
require_rejection "$CASE" 'side-by-side TestFlight encrypted backing image'

CASE=$(new_case testflight-build-image-format)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'TESTFLIGHT_BUILD_IMAGE_FORMAT="SPRS"' \
  'TESTFLIGHT_BUILD_IMAGE_FORMAT="UDRW"'
require_rejection "$CASE" 'side-by-side TestFlight exact sparse-image format'

CASE=$(new_case testflight-apfs-partition-binding)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'APFS_PARTITION_TYPE_UUID="7C3457EF-0000-11AA-AA11-00306543ECAC"' \
  'APFS_PARTITION_TYPE_UUID="00000000-0000-0000-0000-000000000000"'
require_rejection "$CASE" 'side-by-side TestFlight APFS partition binding'

CASE=$(new_case testflight-created-image-encryption-proof)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'Properties.Encrypted' \
  'Properties.EncryptionIgnored'
require_rejection "$CASE" 'side-by-side TestFlight created-image encryption proof'

CASE=$(new_case testflight-attached-image-encryption-proof)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'images.${image_index}.image-encrypted' \
  'images.${image_index}.image-encryption-ignored'
require_rejection "$CASE" 'side-by-side TestFlight attached-image encryption proof'

CASE=$(new_case testflight-typed-array-enumeration)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'count=$(/usr/bin/plutil -extract "${key_path}" raw -expect array \\\n    -o - "${plist}" 2>/dev/null)' \
  $'count=$(/usr/bin/plutil -extract "${key_path}" raw -expect dictionary \\\n    -o - "${plist}" 2>/dev/null)'
require_rejection "$CASE" 'side-by-side TestFlight array type enforcement'

CASE=$(new_case testflight-unbounded-image-enumeration)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  local image_writeable=\x27\x27\n  local enumerated_root=\x27\x27\n  for (( image_index = 0; image_index < image_count; image_index += 1 )); do' \
  $'  local image_writeable=\x27\x27\n  local enumerated_root=\x27\x27\n  for image_index in {0..63}; do'
require_rejection "$CASE" 'side-by-side TestFlight unbounded image enumeration'

CASE=$(new_case testflight-indeterminate-is-not-absence)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'Malformed or unreadable enumeration is indeterminate, never evidence of absence.' \
  'Malformed enumeration is treated as absence.'
require_rejection "$CASE" 'side-by-side TestFlight indeterminate-not-absence policy'

CASE=$(new_case testflight-encrypted-writable-attachment)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '|true|true" ]]' \
  '|false|true" ]]'
require_rejection "$CASE" 'side-by-side TestFlight encrypted writable attachment acceptance'

CASE=$(new_case testflight-pre-create-cleanup-state)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'    verify_build_key_identity \\\n      || fail "build-image key changed before encrypted image creation"\n    TESTFLIGHT_BUILD_CREATE_ATTEMPTED=1\n    run_with_pinned_build_key_stdin /usr/bin/hdiutil create' \
  $'    verify_build_key_identity \\\n      || fail "build-image key changed before encrypted image creation"\n    TESTFLIGHT_BUILD_CREATE_ATTEMPTED=0\n    run_with_pinned_build_key_stdin /usr/bin/hdiutil create'
require_rejection "$CASE" 'side-by-side TestFlight pre-create cleanup state'

CASE=$(new_case testflight-create-cleanup-reachability)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'TESTFLIGHT_BUILD_CREATE_ATTEMPTED == 1' \
  'TESTFLIGHT_BUILD_CREATE_ATTEMPTED == 0'
require_rejection "$CASE" 'side-by-side TestFlight attempted-create cleanup reachability'

CASE=$(new_case testflight-pre-attach-cleanup-state)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  verify_build_key_identity \\\n    || fail "build-image key changed before attachment"\n  TESTFLIGHT_BUILD_ATTACH_ATTEMPTED=1\n  write_private_plist "${attachment_plist}" run_with_pinned_build_key_stdin' \
  $'  verify_build_key_identity \\\n    || fail "build-image key changed before attachment"\n  TESTFLIGHT_BUILD_ATTACH_ATTEMPTED=0\n  write_private_plist "${attachment_plist}" run_with_pinned_build_key_stdin'
require_rejection "$CASE" 'side-by-side TestFlight pre-attach cleanup state'

CASE=$(new_case testflight-attach-cleanup-reachability)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'TESTFLIGHT_BUILD_ATTACH_ATTEMPTED == 1' \
  'TESTFLIGHT_BUILD_ATTACH_ATTEMPTED == 0'
require_rejection "$CASE" 'side-by-side TestFlight attempted-attachment cleanup reachability'

CASE=$(new_case testflight-partial-attach-discovery)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function find_current_attachment_root_device() {' \
  'function find_ignored_attachment_root_device() {'
require_rejection "$CASE" 'side-by-side TestFlight partial-attach discovery'

CASE=$(new_case testflight-key-identity-guard)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function verify_build_key_identity() {' \
  'function ignore_build_key_identity() {'
require_rejection "$CASE" 'side-by-side TestFlight private key identity guard'

CASE=$(new_case testflight-key-bound-create-ordering)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'    verify_build_key_identity \\\n      || fail "build-image key changed before encrypted image creation"\n    TESTFLIGHT_BUILD_CREATE_ATTEMPTED=1\n    run_with_pinned_build_key_stdin /usr/bin/hdiutil create' \
  $'    verify_build_key_identity || true\n    TESTFLIGHT_BUILD_CREATE_ATTEMPTED=1\n    /usr/bin/hdiutil create'
require_rejection "$CASE" 'side-by-side TestFlight key-bound create ordering'

CASE=$(new_case testflight-key-bound-attach-ordering)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'verify_build_key_identity \\\n    || fail "build-image key changed before attachment"\n  TESTFLIGHT_BUILD_ATTACH_ATTEMPTED=1\n  write_private_plist "${attachment_plist}" run_with_pinned_build_key_stdin \\\n    /usr/bin/hdiutil attach' \
  $'verify_build_key_identity || true\n  TESTFLIGHT_BUILD_ATTACH_ATTEMPTED=1\n  write_private_plist "${attachment_plist}" /usr/bin/hdiutil attach'
require_rejection "$CASE" 'side-by-side TestFlight key-bound attach ordering'

CASE=$(new_case testflight-build-image-volume-name)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '-volname "${TESTFLIGHT_BUILD_VOLUME_NAME}"' \
  '-volname "AudioStreamer Host.app"'
require_rejection "$CASE" 'side-by-side TestFlight exact private volume creation'

CASE=$(new_case testflight-build-volume-owners)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '-owners on' \
  '-owners off'
require_rejection "$CASE" 'side-by-side TestFlight ownership-enforcing mount'

CASE=$(new_case testflight-build-image-canonical-path)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '"${TESTFLIGHT_BUILD_IMAGE_PATH:A}" == "${TESTFLIGHT_BUILD_IMAGE_PATH}"' \
  '"${TESTFLIGHT_BUILD_IMAGE_PATH:A}" != ""'
require_rejection "$CASE" 'side-by-side TestFlight canonical sparse-image path'

CASE=$(new_case testflight-build-image-parent-path)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '&& "${candidate:h}" == "${required_parent}"' \
  '&& -n "${required_parent}"'
require_rejection "$CASE" 'side-by-side TestFlight exact safe-path parent guard'

CASE=$(new_case testflight-build-image-traversal)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '&& "${candidate}" != *"/../"*' \
  '&& -n "${candidate}"'
require_rejection "$CASE" 'side-by-side TestFlight traversal rejection guard'

CASE=$(new_case testflight-protected-app-path-rejection)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '&& "${candidate}" != "/Applications/"*' \
  '&& "${candidate}" != "/System/"*'
require_rejection "$CASE" 'side-by-side TestFlight protected-application path rejection'

CASE=$(new_case testflight-global-permissions-check)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '$(plist_raw_value "${info}" GlobalPermissionsEnabled)' \
  '$(plist_raw_value "${info}" GlobalPermissionsIgnored)'
require_rejection "$CASE" 'side-by-side TestFlight ownership-state validation'

CASE=$(new_case testflight-prearchive-destination-identity)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'verify_archive_exec_destinations || return 1' \
  'verify_output_directory_identity || return 1'
require_rejection "$CASE" 'side-by-side TestFlight archive destination reservation and exec revalidation'

CASE=$(new_case testflight-postarchive-volume-identity)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '|| fail "private build volume changed during archive"' \
  '|| true'
require_rejection "$CASE" 'side-by-side TestFlight post-archive volume revalidation'

CASE=$(new_case testflight-strict-archive-signature)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '/usr/bin/codesign --verify --deep --strict --verbose=4 "${app_path}"' \
  '/usr/bin/codesign -dv --verbose=4 "${app_path}"'
require_rejection "$CASE" 'side-by-side TestFlight strict archive signature verification'

CASE=$(new_case testflight-output-identity)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function verify_output_directory_identity() {' \
  'function ignore_output_directory_identity() {'
require_rejection "$CASE" 'side-by-side TestFlight pinned output identity'

CASE=$(new_case testflight-object-bound-plist-truncation)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'sysopen -w -o trunc,nofollow -u destination_fd "${destination}"' \
  'sysopen -w -o trunc -u destination_fd "${destination}"'
require_rejection "$CASE" 'side-by-side TestFlight atomic private snapshot replacement'

CASE=$(new_case testflight-output-directory-nofollow)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'sysopen -r -o nofollow -u TESTFLIGHT_OUTPUT_DIRECTORY_FD' \
  'sysopen -r -u TESTFLIGHT_OUTPUT_DIRECTORY_FD'
require_rejection "$CASE" \
  'side-by-side TestFlight no-follow directory and profile descriptor pinning'

CASE=$(new_case testflight-log-nofollow)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'sysopen -a -o nofollow -u TESTFLIGHT_ARCHIVE_LOG_FD' \
  'sysopen -a -u TESTFLIGHT_ARCHIVE_LOG_FD'
require_rejection "$CASE" 'side-by-side TestFlight no-follow log descriptor pinning'

CASE=$(new_case testflight-export-find-status)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'first_entry=$(/usr/bin/find "${TESTFLIGHT_EXPORT_DIRECTORY}"' \
  'first_entry=$(command /usr/bin/find "${TESTFLIGHT_EXPORT_DIRECTORY}"'
require_rejection "$CASE" 'side-by-side TestFlight export-directory scan status capture'

CASE=$(new_case testflight-archive-identity)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function pin_archive_filesystem_identity() {' \
  'function ignore_archive_filesystem_identity() {'
require_rejection "$CASE" 'side-by-side TestFlight pinned archive identity'

CASE=$(new_case testflight-full-archive-tree-manifest)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function filesystem_tree_manifest_stream() {' \
  'function ignored_filesystem_tree_manifest_stream() {'
require_rejection "$CASE" 'side-by-side TestFlight deterministic full archive tree manifest'

CASE=$(new_case testflight-full-archive-tree-digest)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'TESTFLIGHT_ARCHIVE_TREE_SHA256=$(filesystem_tree_sha256 "${archive_path}")' \
  'TESTFLIGHT_ARCHIVE_TREE_SHA256=$(print ignored)'
require_rejection "$CASE" 'side-by-side TestFlight pinned full archive tree digest'

CASE=$(new_case testflight-normalized-postupload-tree-digest)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'TESTFLIGHT_ARCHIVE_TREE_WITHOUT_ROOT_INFO_SHA256=$(filesystem_tree_sha256 \' \
  'TESTFLIGHT_ARCHIVE_TREE_WITHOUT_ROOT_INFO_SHA256=$(print ignored \'
require_rejection "$CASE" 'side-by-side TestFlight normalized post-upload tree digest'

CASE=$(new_case testflight-archive-info-semantic-digest)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function archive_info_without_distributions_sha256() {' \
  'function ignored_archive_info_without_distributions_sha256() {'
require_rejection "$CASE" 'side-by-side TestFlight normalized archive metadata digest'

CASE=$(new_case testflight-archive-short-version)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_SHORT_VERSION="0.1.0"' \
  'EXPECTED_SHORT_VERSION="0.0.0"'
require_rejection "$CASE" 'side-by-side TestFlight exact archive short version'

CASE=$(new_case testflight-archive-signing-identity)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_ARCHIVE_SIGNING_IDENTITY="Apple Development: Ahmed Elamin (92LVX32M8K)"' \
  'EXPECTED_ARCHIVE_SIGNING_IDENTITY="Apple Development: Unreviewed"'
require_rejection "$CASE" 'side-by-side TestFlight exact archive signing identity'

CASE=$(new_case testflight-archive-application-path)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '&& "${semantic_fields[5]}" == '\''Applications/opensteamer.app'\'' \' \
  '&& "${semantic_fields[5]}" == '\''Applications/AudioStreamer.app'\'' \'
require_rejection "$CASE" 'side-by-side TestFlight exact archive application path'

CASE=$(new_case testflight-postupload-info-equality)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '== "${TESTFLIGHT_ARCHIVE_INFO_WITHOUT_DISTRIBUTIONS_SHA256}"' \
  '!= "${TESTFLIGHT_ARCHIVE_INFO_WITHOUT_DISTRIBUTIONS_SHA256}"'
require_rejection "$CASE" 'side-by-side TestFlight post-upload metadata equality excluding Distributions'

CASE=$(new_case testflight-distribution-record-verifier)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function verify_successful_upload_distribution_record() {' \
  'function ignore_successful_upload_distribution_record() {'
require_rejection "$CASE" 'side-by-side TestFlight successful distribution-record verification'

CASE=$(new_case testflight-asc-apple-id)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_ASC_APPLE_ID="6797410161"' \
  'EXPECTED_ASC_APPLE_ID="0"'
require_rejection "$CASE" 'side-by-side TestFlight exact App Store Connect app identity'

CASE=$(new_case testflight-distribution-certificate)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_DISTRIBUTION_CERTIFICATE_SHA1="CEB61B792A7A5848E9E797BB2E44EA2642611A6F"' \
  'EXPECTED_DISTRIBUTION_CERTIFICATE_SHA1="0000000000000000000000000000000000000000"'
require_rejection "$CASE" 'side-by-side TestFlight exact distribution certificate identity'

CASE=$(new_case testflight-postupload-payload-verifier)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function verify_archive_payload_after_upload() {' \
  'function ignore_archive_payload_after_upload() {'
require_rejection "$CASE" 'side-by-side TestFlight post-upload payload and distribution verification'

CASE=$(new_case testflight-redundant-post-cleanup-archive-rescan)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  fi\n  print -- "side-by-side TestFlight upload completed; evidence: ${output_directory}"' \
  $'  fi\n  verify_archive_payload_after_upload || fail "redundant rescan"\n  print -- "side-by-side TestFlight upload completed; evidence: ${output_directory}"'
require_rejection "$CASE" \
  'side-by-side TestFlight post-upload payload and distribution verification'

CASE=$(new_case testflight-redundant-initial-archive-tree-rescan)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  pin_archive_filesystem_identity \\\n    || fail "could not pin the completed archive filesystem identity"\n  verify_archive_contents_at_path "${TESTFLIGHT_ARCHIVE_PATH}"\n  print_release_stage_timing archive_verification "${stage_started_at}"' \
  $'  pin_archive_filesystem_identity \\\n    || fail "could not pin the completed archive filesystem identity"\n  verify_archive\n  print_release_stage_timing archive_verification "${stage_started_at}"'
require_rejection "$CASE" \
  'side-by-side TestFlight single full-tree pre-upload revalidation'

CASE=$(new_case testflight-export-options-identity)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function verify_export_options_identity() {' \
  'function ignore_export_options_identity() {'
require_rejection "$CASE" 'side-by-side TestFlight pinned export-options identity'

CASE=$(new_case testflight-immediate-preupload-revalidation)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'verify_export_options_identity \\\n    || fail "export options changed after reviewed configuration validation"\n  verify_archive\n  verify_xcodebuild_authentication_contract \\\n    || fail "release authentication identity changed before upload"' \
  $'verify_export_options_identity || true\n  verify_archive\n  verify_output_directory_identity'
require_rejection "$CASE" 'side-by-side TestFlight immediate pre-upload revalidation'

CASE=$(new_case testflight-build-environment-rejection)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function reject_unsafe_build_environment() {' \
  'function ignore_unsafe_build_environment() {'
require_rejection "$CASE" 'side-by-side TestFlight caller build-environment rejection'

CASE=$(new_case testflight-empty-xcode-environment)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  local -a pinned_command=(\n    /usr/bin/env -i\n    "${TESTFLIGHT_XCODEBUILD_PINNED_ENVIRONMENT[@]}"' \
  $'  local -a pinned_command=(\n    /usr/bin/env\n    "${TESTFLIGHT_XCODEBUILD_PINNED_ENVIRONMENT[@]}"'
require_rejection "$CASE" \
  'side-by-side TestFlight empty inherited Xcode and exclusive-rename environments'

CASE=$(new_case testflight-xcode-sandbox)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '/usr/bin/sandbox-exec -p "${profile_text}"' \
  '/usr/bin/env'
require_rejection "$CASE" 'side-by-side TestFlight protected-path Xcode sandbox'

CASE=$(new_case testflight-unsupported-private-export-override)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '  run_pinned_xcodebuild export -exportArchive \' \
  $'  run_pinned_xcodebuild export \\\n    -DVTITunesConnectOutOfProcess NO \\\n    -exportArchive \\'
require_rejection "$CASE" \
  'side-by-side TestFlight unsupported private Xcode override rejection'

CASE=$(new_case testflight-export-action-vector-equality-bypass)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '== "$(string_vector_sha256 "${expected_export_arguments[@]}")" ]]' \
  '== "$(string_vector_sha256 "${supplied_arguments[@]}")" ]]'
require_rejection "$CASE" \
  'side-by-side TestFlight full export-vector equality proof'

CASE=$(new_case testflight-export-action-verifier-bypass)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function verify_xcodebuild_action_arguments() {' \
  'function ignore_xcodebuild_action_arguments() {'
require_rejection "$CASE" \
  'side-by-side TestFlight runtime Xcode action argument proof'

CASE=$(new_case testflight-export-pre-action-verifier-call-bypass)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  verify_xcodebuild_action_arguments \\\n    "${destination_contract}" "$@" || return 1' \
  '  true # action verification bypassed'
require_rejection "$CASE" \
  'side-by-side TestFlight immediate exact action verification'

CASE=$(new_case testflight-export-post-action-verifier-call-bypass)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  verify_xcodebuild_action_arguments \\\n    "${destination_contract}" "$@" || command_status=1' \
  '  true # post-command action verification bypassed'
require_rejection "$CASE" \
  'side-by-side TestFlight complete pre/post action argument proof'

CASE=$(new_case testflight-export-routed-through-outer-sandbox)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'      # this exact, fully pinned export vector without the outer profile.\n      "$@"' \
  $'      # this exact, fully pinned export vector without the outer profile.\n      run_with_pinned_xcode_sandbox_profile "${destination_contract}" "$@"'
require_rejection "$CASE" \
  'side-by-side TestFlight export-only outer-sandbox bypass'

CASE=$(new_case testflight-export-router-broadened)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'    export)\n      # The supported upload action launches Xcode' \
  $'    export|*)\n      # The supported upload action launches Xcode'
require_rejection "$CASE" \
  'side-by-side TestFlight export-only outer-sandbox bypass'

CASE=$(new_case testflight-archive-routed-direct)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'    settings|archive)\n      run_with_pinned_xcode_sandbox_profile "${destination_contract}" "$@"\n      ;;\n    export)' \
  $'    settings)\n      run_with_pinned_xcode_sandbox_profile "${destination_contract}" "$@"\n      ;;\n    archive)\n      "$@"\n      ;;\n    export)'
require_rejection "$CASE" \
  'side-by-side TestFlight build-action protected-path sandbox'

CASE=$(new_case testflight-export-arguments-reordered)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'    -archivePath "${TESTFLIGHT_ARCHIVE_PATH}" \\\n    -exportOptionsPlist "${EXPORT_OPTIONS_PATH}" \\' \
  $'    -exportOptionsPlist "${EXPORT_OPTIONS_PATH}" \\\n    -archivePath "${TESTFLIGHT_ARCHIVE_PATH}" \\'
require_rejection "$CASE" \
  'side-by-side TestFlight exact supported export invocation vector'

CASE=$(new_case testflight-export-trailing-argument)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'    "${TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS[@]}" \\\n    2>&1 | /usr/bin/tee "/dev/fd/${TESTFLIGHT_UPLOAD_LOG_FD}" \\' \
  $'    "${TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS[@]}" \\\n    -unreviewedTrailingArgument \\\n    2>&1 | /usr/bin/tee "/dev/fd/${TESTFLIGHT_UPLOAD_LOG_FD}" \\'
require_rejection "$CASE" \
  'side-by-side TestFlight exact supported export invocation vector'

CASE=$(new_case testflight-export-post-filesystem-proof)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '  verify_pinned_xcodebuild_filesystem_contract || command_status=1' \
  '  true # post-command filesystem proof bypassed'
require_rejection "$CASE" \
  'side-by-side TestFlight post-command action and filesystem proof'

CASE=$(new_case testflight-redundant-outer-filesystem-check)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '  local archive_status=0' \
  $'  verify_pinned_xcodebuild_filesystem_contract || return 1\n  local archive_status=0'
require_rejection "$CASE" \
  'side-by-side TestFlight single pre-and-post Xcode filesystem checks'

CASE=$(new_case testflight-redundant-outer-export-destination-check)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '  local upload_status=0' \
  $'  verify_export_exec_destinations || return 1\n  local upload_status=0'
require_rejection "$CASE" \
  'side-by-side TestFlight single pre-and-post export destination checks'

CASE=$(new_case testflight-persistent-export-default)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function verify_xcodebuild_action_arguments() {' \
  $'/usr/bin/defaults write com.apple.dt.Xcode UnreviewedExportBehavior -bool true\nfunction verify_xcodebuild_action_arguments() {'
require_rejection "$CASE" \
  'side-by-side TestFlight persistent defaults mutation rejection'

CASE=$(new_case testflight-global-private-export-environment)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  "    'PATH=/usr/bin:/bin:/usr/sbin:/sbin'" \
  $'    '\''PATH=/usr/bin:/bin:/usr/sbin:/sbin'\''\n    '\''DVTITunesConnectOutOfProcess=NO'\'''
require_rejection "$CASE" \
  'side-by-side TestFlight unsupported private Xcode override rejection'

CASE=$(new_case testflight-base-sandbox-job-creation)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  "  print -r -- '(allow default)'" \
  $'  print -r -- \'(allow default)\'\n  print -r -- \'(allow job-creation (subpath "/"))\''
require_rejection "$CASE" \
  'side-by-side TestFlight complete job-creation allowance rejection'

CASE=$(new_case testflight-base-sandbox-job-creation-check)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '  [[ "${profile_text}" != *'\''job-creation'\''* ]] || operation_status=1' \
  '  [[ -n "${profile_text}" ]] || operation_status=1'
require_rejection "$CASE" \
  'side-by-side TestFlight job-creation-free base sandbox profile'


CASE=$(new_case testflight-native-package-sandbox-resolution)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'    resolve)\n      # Xcode\'s package resolver applies its own child sandbox.' \
  $'    resolve)\n      run_with_pinned_xcode_sandbox_profile "$@"\n      # Xcode\'s package resolver applies its own child sandbox.'
require_rejection "$CASE" \
  'side-by-side TestFlight native package-sandbox resolution'

CASE=$(new_case testflight-encrypted-package-cache)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '-packageCachePath "${TESTFLIGHT_BUILD_PACKAGE_CACHE_DIRECTORY}"' \
  '-packageCachePath /Users/ahmed/Library/Caches/org.swift.swiftpm'
require_rejection "$CASE" 'side-by-side TestFlight encrypted SwiftPM package cache'

CASE=$(new_case testflight-resolved-package-only)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '-onlyUsePackageVersionsFromResolvedFile' \
  '-disablePackageVersionPinning'
require_rejection "$CASE" 'side-by-side TestFlight resolved package graph pin'

CASE=$(new_case testflight-package-update-suppression)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '-skipPackageUpdates' \
  '-allowPackageUpdates'
require_rejection "$CASE" 'side-by-side TestFlight package update suppression'

CASE=$(new_case testflight-package-manifest-pin)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_PACKAGE_MANIFEST_SHA256="914e2ce96c49ccb1376f66d5a986cfd2461f3aa8758b044cf655a1d55bca4178"' \
  'EXPECTED_PACKAGE_MANIFEST_SHA256="0000000000000000000000000000000000000000000000000000000000000000"'
require_rejection "$CASE" 'side-by-side TestFlight exact package manifest pin'

CASE=$(new_case testflight-package-resolved-pin)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_PACKAGE_RESOLVED_SHA256="161213e9507513e41f0acba0d7439fcf633b9d03d78c22b1e4b15fa9f83a01d9"' \
  'EXPECTED_PACKAGE_RESOLVED_SHA256="0000000000000000000000000000000000000000000000000000000000000000"'
require_rejection "$CASE" 'side-by-side TestFlight exact resolved package pin'

CASE=$(new_case testflight-cache-enrollment-package-manifest-pin)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_TESTFLIGHT_BUILD_CACHE_ENROLLMENT_PACKAGE_MANIFEST_SHA256="b1bbbff9772b71d850ffec63a8fb1afef9d5e470c1abcedaeb7373b2c98d6d44"' \
  'EXPECTED_TESTFLIGHT_BUILD_CACHE_ENROLLMENT_PACKAGE_MANIFEST_SHA256="0000000000000000000000000000000000000000000000000000000000000000"'
require_rejection "$CASE" \
  'side-by-side TestFlight exact enrolled package-manifest pin'

CASE=$(new_case testflight-cache-enrollment-package-resolved-pin)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_TESTFLIGHT_BUILD_CACHE_ENROLLMENT_PACKAGE_RESOLVED_SHA256="161213e9507513e41f0acba0d7439fcf633b9d03d78c22b1e4b15fa9f83a01d9"' \
  'EXPECTED_TESTFLIGHT_BUILD_CACHE_ENROLLMENT_PACKAGE_RESOLVED_SHA256="0000000000000000000000000000000000000000000000000000000000000000"'
require_rejection "$CASE" \
  'side-by-side TestFlight exact enrolled resolved-package pin'

CASE=$(new_case testflight-cache-enrollment-current-package-verification)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'function run_initialize_build_cache() {\n  verify_package_dependency_contract \\\n    || fail "current package inputs changed before build-cache enrollment"' \
  $'function run_initialize_build_cache() {\n  true # current package inputs not verified before enrollment'
require_rejection "$CASE" \
  'side-by-side TestFlight fresh enrollment current-package verification'

CASE=$(new_case testflight-entrypoint-current-package-verification)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'verify_static_contract\nverify_package_dependency_contract \\\n  || fail "current package inputs do not match the reviewed release pins"\npin_export_options_identity' \
  $'verify_static_contract\ntrue # current package inputs not verified at entrypoint\npin_export_options_identity'
require_rejection "$CASE" \
  'side-by-side TestFlight entrypoint current-package verification'

CASE=$(new_case testflight-xcode-sandbox-profile-consumption)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'if sysread -i ${profile_reader_fd} -s 4096 \' \
  'if /usr/bin/false; then #'
require_rejection "$CASE" \
  'side-by-side TestFlight descriptor-bound sandbox-profile consumption'

CASE=$(new_case testflight-xcode-sandbox-profile-consumed-hash)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '[[ "${profile_text_sha256}" == "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_SHA256}" ]]' \
  '[[ "${profile_text_sha256}" == "${profile_text_sha256}" ]]'
require_rejection "$CASE" \
  'side-by-side TestFlight consumed sandbox-profile hash pin'

CASE=$(new_case testflight-fresh-xcode-sandbox-reader)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function run_with_pinned_xcode_sandbox_profile() {' \
  'function run_with_reused_xcode_sandbox_profile() {'
require_rejection "$CASE" 'side-by-side TestFlight fresh sandbox-profile reader per command'

CASE=$(new_case testflight-fresh-build-key-reader)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function run_with_pinned_build_key_stdin() {' \
  'function run_with_reused_build_key_stdin() {'
require_rejection "$CASE" 'side-by-side TestFlight fresh private-key reader per command'

CASE=$(new_case testflight-exclusive-sandbox-profile)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'sysopen -w -o creat,excl,nofollow -m 600 -u profile_writer_fd \' \
  'sysopen -w -o creat,nofollow -m 600 -u profile_writer_fd \'
require_rejection "$CASE" 'side-by-side TestFlight exclusive sandbox-profile creation descriptor'

CASE=$(new_case testflight-applications-write-denial)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '(deny file-write* (subpath "/Applications"))' \
  '(allow file-write* (subpath "/Applications"))'
require_rejection "$CASE" 'side-by-side TestFlight kernel-enforced Applications write denial'

CASE=$(new_case testflight-protected-launch-agent-path)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'PROTECTED_LEGACY_LAUNCH_AGENT_PATH="/Users/ahmed/Library/LaunchAgents/com.elamin.audiostreamer.worldwide.plist"' \
  'PROTECTED_LEGACY_LAUNCH_AGENT_PATH="/private/tmp/ignored.plist"'
require_rejection "$CASE" 'side-by-side TestFlight exact protected legacy LaunchAgent path'

CASE=$(new_case testflight-launch-agents-subtree-denial)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '(deny file-write* (subpath \"${PROTECTED_LAUNCH_AGENTS_DIRECTORY}\"))' \
  '(allow file-write* (subpath \"${PROTECTED_LAUNCH_AGENTS_DIRECTORY}\"))'
require_rejection "$CASE" 'side-by-side TestFlight kernel-enforced LaunchAgents subtree write denial'

CASE=$(new_case testflight-migration-evidence-denial)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '(deny file-write* (subpath \"${PROTECTED_MIGRATION_EVIDENCE_DIRECTORY}\"))' \
  '(allow file-write* (subpath \"${PROTECTED_MIGRATION_EVIDENCE_DIRECTORY}\"))'
require_rejection "$CASE" 'side-by-side TestFlight kernel-enforced migration evidence write denial'

CASE=$(new_case testflight-application-support-denial)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '(deny file-write* (subpath \"${PROTECTED_OPENSTEAMER_APPLICATION_SUPPORT_DIRECTORY}\"))' \
  '(allow file-write* (subpath \"${PROTECTED_OPENSTEAMER_APPLICATION_SUPPORT_DIRECTORY}\"))'
require_rejection "$CASE" 'side-by-side TestFlight kernel-enforced application-support subtree write denial'

CASE=$(new_case testflight-build-key-read-denial)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '(deny file-read* (literal \"${EXPECTED_TESTFLIGHT_BUILD_KEY_PATH}\"))' \
  '(allow file-read* (literal \"${EXPECTED_TESTFLIGHT_BUILD_KEY_PATH}\"))'
require_rejection "$CASE" \
  'side-by-side TestFlight build-image key read denial for build actions'

CASE=$(new_case testflight-build-lock-read-denial)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '(deny file-read* (literal \"${EXPECTED_TESTFLIGHT_BUILD_LOCK_PATH}\"))' \
  '(allow file-read* (literal \"${EXPECTED_TESTFLIGHT_BUILD_LOCK_PATH}\"))'
require_rejection "$CASE" \
  'side-by-side TestFlight build-cache lock read denial for build actions'

CASE=$(new_case testflight-executable-scheme-actions)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'count(/Scheme//PreActions | /Scheme//PostActions | /Scheme//ExecutionAction)' \
  'count(/Scheme//IgnoredActions)'
require_rejection "$CASE" 'side-by-side TestFlight executable scheme-action rejection'

CASE=$(new_case testflight-executable-pbx-actions)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'isa = PBX(ShellScript|AppleScript)BuildPhase;|isa = PBXBuildRule;|shellScript = ' \
  'isa = PBXIgnoredBuildPhase;'
require_rejection "$CASE" 'side-by-side TestFlight executable PBX action rejection'

CASE=$(new_case testflight-effective-writable-roots)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'        DERIVED_SOURCES_DIR \\\n        INDEX_DATA_STORE_DIR \\' \
  $'        DERIVED_SOURCES_DIR \\'
require_rejection "$CASE" 'side-by-side TestFlight exhaustive effective writable-root verification'

CASE=$(new_case testflight-manual-symroot-override)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '    -clonedSourcePackagesDirPath "${TESTFLIGHT_BUILD_SOURCE_PACKAGES_DIRECTORY}"' \
  $'    -clonedSourcePackagesDirPath "${TESTFLIGHT_BUILD_SOURCE_PACKAGES_DIRECTORY}"\n    "SYMROOT=${TESTFLIGHT_BUILD_PRODUCTS_DIRECTORY}"'
require_rejection "$CASE" 'side-by-side TestFlight Xcode-owned product root'

CASE=$(new_case testflight-manual-objroot-override)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '    -clonedSourcePackagesDirPath "${TESTFLIGHT_BUILD_SOURCE_PACKAGES_DIRECTORY}"' \
  $'    -clonedSourcePackagesDirPath "${TESTFLIGHT_BUILD_SOURCE_PACKAGES_DIRECTORY}"\n    "OBJROOT=${TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY}"'
require_rejection "$CASE" 'side-by-side TestFlight Xcode-owned intermediate root'

CASE=$(new_case testflight-xcode-owned-archive-staging)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'TESTFLIGHT_BUILD_DSTROOT_DIRECTORY="${TESTFLIGHT_DERIVED_DATA_DIRECTORY}/Build/Intermediates.noindex/ArchiveIntermediates/${EXPECTED_SCHEME}/InstallationBuildProductsLocation"' \
  'TESTFLIGHT_BUILD_DSTROOT_DIRECTORY="${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}/DSTRoot"'
require_rejection "$CASE" 'side-by-side TestFlight Xcode-owned archive staging root'

CASE=$(new_case testflight-xcode-tmp-alias-root)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'readonly XCODE_TMP_ALIAS_ROOT="/tmp"' \
  'readonly XCODE_TMP_ALIAS_ROOT="/private/tmp"'
require_rejection "$CASE" 'side-by-side TestFlight pinned Xcode tmp alias root'

CASE=$(new_case testflight-real-xcode-alias)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_XCODE_ALIAS_PATH="/Applications/Xcode-26.6.0.app"' \
  'EXPECTED_XCODE_ALIAS_PATH="/Applications/Xcode.app"'
require_rejection "$CASE" 'side-by-side TestFlight selected Xcode symlink contract'

CASE=$(new_case testflight-real-xcode-digest)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_XCODEBUILD_SHA256="d508f0e1901151843804e4af512d4587ad0e422039e43e14abf22792360ad3d4"' \
  'EXPECTED_XCODEBUILD_SHA256="0000000000000000000000000000000000000000000000000000000000000000"'
require_rejection "$CASE" 'side-by-side TestFlight reviewed real xcodebuild digest'

CASE=$(new_case testflight-real-altool-path)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_ALTOOL_REAL_PATH="${EXPECTED_XCODE_REAL_BUNDLE_PATH}/Contents/SharedFrameworks/ContentDelivery.framework/Versions/A/Resources/altool"' \
  'EXPECTED_ALTOOL_REAL_PATH="/usr/bin/unreviewed-altool"'
require_rejection "$CASE" 'side-by-side TestFlight exact pinned altool path'

CASE=$(new_case testflight-real-altool-digest)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_ALTOOL_SHA256="600c9117df7fa1be881fbf8d4df746b31fd6d6e35c71d8eeff8a26f600c7a2d5"' \
  'EXPECTED_ALTOOL_SHA256="0000000000000000000000000000000000000000000000000000000000000000"'
require_rejection "$CASE" 'side-by-side TestFlight exact pinned altool bytes'

CASE=$(new_case testflight-real-altool-cdhash)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'EXPECTED_ALTOOL_CD_HASH="cab578a19665f314251768644dfd34092d09e926"' \
  'EXPECTED_ALTOOL_CD_HASH="0000000000000000000000000000000000000000"'
require_rejection "$CASE" 'side-by-side TestFlight exact pinned altool signature'

typeset -a FAST_XCODE_PIN_NAMES=(
  selected-developer-path
  canonical-developer-path
  alias-filesystem-identity
  bundle-filesystem-identity
  bundle-volume-binding
  developer-filesystem-identity
  xcodebuild-filesystem-identity
  altool-filesystem-identity
  info-plist-digest-use
  version-plist-digest-use
  xcodebuild-digest-use
  altool-digest-use
  bundle-identifier-plist
  bundle-version-plist
  bundle-build-version-plist
  volume-verifier-call
  xcodebuild-signature
  altool-signature
  bundle-signing-identifier
  bundle-signing-team
  bundle-cdhash
  xcodebuild-signing-identifier
  xcodebuild-signing-team
  xcodebuild-cdhash
  altool-signing-identifier
  altool-signing-team
  altool-cdhash
)
typeset -a FAST_XCODE_PIN_LITERALS=(
  '"${selected_developer_path}" == "${EXPECTED_XCODE_SELECTED_DEVELOPER_PATH}"'
  $'"${selected_developer_path:A}" \\\n        == "${EXPECTED_XCODE_REAL_DEVELOPER_PATH}"'
  $'"$(stat_identity "${EXPECTED_XCODE_ALIAS_PATH}")" \\\n        == "${TESTFLIGHT_XCODE_ALIAS_IDENTITY}"'
  $'"$(stat_identity "${EXPECTED_XCODE_REAL_BUNDLE_PATH}")" \\\n        == "${TESTFLIGHT_XCODE_BUNDLE_IDENTITY}"'
  $'      && "${TESTFLIGHT_XCODE_BUNDLE_IDENTITY%%:*}" \\\n        == "${TESTFLIGHT_XCODE_VOLUME_ROOT_IDENTITY%%:*}"'
  $'"$(stat_identity "${EXPECTED_XCODE_REAL_DEVELOPER_PATH}")" \\\n        == "${TESTFLIGHT_XCODE_DEVELOPER_IDENTITY}"'
  $'"$(stat_identity "${EXPECTED_XCODEBUILD_REAL_PATH}")" \\\n        == "${TESTFLIGHT_XCODEBUILD_IDENTITY}"'
  $'"$(stat_identity "${EXPECTED_ALTOOL_REAL_PATH}")" \\\n        == "${TESTFLIGHT_ALTOOL_IDENTITY}"'
  $'"$(sha256_file \\\n        "${EXPECTED_XCODE_REAL_BUNDLE_PATH}/Contents/Info.plist")" \\\n        == "${EXPECTED_XCODE_INFO_SHA256}"'
  $'"$(sha256_file \\\n        "${EXPECTED_XCODE_REAL_BUNDLE_PATH}/Contents/version.plist")" \\\n        == "${EXPECTED_XCODE_VERSION_SHA256}"'
  $'"$(sha256_file "${EXPECTED_XCODEBUILD_REAL_PATH}")" \\\n        == "${EXPECTED_XCODEBUILD_SHA256}"'
  $'"$(sha256_file "${EXPECTED_ALTOOL_REAL_PATH}")" \\\n        == "${EXPECTED_ALTOOL_SHA256}"'
  $'CFBundleIdentifier)" == "${EXPECTED_XCODE_BUNDLE_IDENTIFIER}"'
  $'CFBundleShortVersionString)" == "${EXPECTED_XCODE_VERSION}"'
  $'ProductBuildVersion)" == "${EXPECTED_XCODE_BUILD_VERSION}"'
  'verify_reviewed_xcode_volume_identity || return $?'
  $'/usr/bin/codesign --verify --strict --verbose=4 \\\n    "${EXPECTED_XCODEBUILD_REAL_PATH}"'
  $'/usr/bin/codesign --verify --strict --verbose=4 \\\n    "${EXPECTED_ALTOOL_REAL_PATH}"'
  $'codesign_metadata_value "${bundle_metadata}" Identifier)" \\\n        == "${EXPECTED_XCODE_BUNDLE_IDENTIFIER}"'
  $'codesign_metadata_value "${bundle_metadata}" TeamIdentifier)" \\\n        == "${EXPECTED_XCODE_SIGNING_TEAM_ID}"'
  $'codesign_metadata_value "${bundle_metadata}" CDHash)" \\\n        == "${EXPECTED_XCODE_BUNDLE_CD_HASH}"'
  $'codesign_metadata_value "${executable_metadata}" Identifier)" \\\n        == "${EXPECTED_XCODEBUILD_IDENTIFIER}"'
  $'codesign_metadata_value "${executable_metadata}" TeamIdentifier)" \\\n        == "${EXPECTED_XCODE_SIGNING_TEAM_ID}"'
  $'codesign_metadata_value "${executable_metadata}" CDHash)" \\\n        == "${EXPECTED_XCODEBUILD_CD_HASH}"'
  $'codesign_metadata_value "${altool_metadata}" Identifier)" \\\n        == "${EXPECTED_ALTOOL_IDENTIFIER}"'
  $'codesign_metadata_value "${altool_metadata}" TeamIdentifier)" \\\n        == "${EXPECTED_XCODE_SIGNING_TEAM_ID}"'
  $'codesign_metadata_value "${altool_metadata}" CDHash)" \\\n        == "${EXPECTED_ALTOOL_CD_HASH}"'
)
(( ${#FAST_XCODE_PIN_NAMES[@]} == ${#FAST_XCODE_PIN_LITERALS[@]} ))
for (( FAST_XCODE_PIN_INDEX = 1;
    FAST_XCODE_PIN_INDEX <= ${#FAST_XCODE_PIN_NAMES[@]};
    FAST_XCODE_PIN_INDEX += 1 )); do
  CASE=$(new_case \
    "testflight-fast-xcode-${FAST_XCODE_PIN_NAMES[FAST_XCODE_PIN_INDEX]}")
  replace_once \
    "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
    "${FAST_XCODE_PIN_LITERALS[FAST_XCODE_PIN_INDEX]}" \
    "removed_fast_xcode_pin_${FAST_XCODE_PIN_INDEX}"
  require_rejection "$CASE" \
    'side-by-side TestFlight complete fast Xcode identity contract'
done

CASE=$(new_case testflight-real-xcode-filesystem-device)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'  [[ "${TESTFLIGHT_XCODE_BUNDLE_IDENTITY%%:*}" \\\n      == "${TESTFLIGHT_XCODE_VOLUME_ROOT_IDENTITY%%:*}" ]] || return 1' \
  $'  [[ -n "${TESTFLIGHT_XCODE_BUNDLE_IDENTITY}" ]] || return 1'
require_rejection "$CASE" 'side-by-side TestFlight real-Xcode filesystem-device binding'

CASE=$(new_case testflight-real-xcode-volume-verifier)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function verify_reviewed_xcode_volume_identity() {' \
  'function ignore_reviewed_xcode_volume_identity() {'
require_rejection "$CASE" 'side-by-side TestFlight real-Xcode T7 volume and store verification'

CASE=$(new_case testflight-pinned-xcode-entrypoint)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'    "${EXPECTED_XCODEBUILD_REAL_PATH}"\n    "$@"' \
  $'    /usr/bin/xcodebuild\n    archive\n    "$@"'
require_rejection "$CASE" 'side-by-side TestFlight direct pinned real-Xcode invocation'

CASE=$(new_case testflight-signal-mask)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  "trap '' HUP INT QUIT TERM" \
  "trap '' TERM"
require_rejection "$CASE" 'side-by-side TestFlight cleanup signal mask'

CASE=$(new_case testflight-idempotent-masked-cleanup)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'cleanup_release_scratch || cleanup_status=1' \
  'cleanup_private_build_volume || cleanup_status=1'
require_rejection "$CASE" 'side-by-side TestFlight idempotent masked normal cleanup'

CASE=$(new_case testflight-signed-entitlements-verifier)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'function verify_main_signed_entitlements() {' \
  'function ignore_main_signed_entitlements() {'
require_rejection "$CASE" 'side-by-side TestFlight signed entitlement verification'

CASE=$(new_case testflight-profile-team-entitlement)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'Entitlements.com\.apple\.developer\.team-identifier' \
  'Entitlements.com.apple.developer.team-identifier'
require_rejection "$CASE" \
  'side-by-side TestFlight profile team entitlement literal dotted-key escaping'

CASE=$(new_case testflight-app-team-entitlement)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  "'com\.apple\.developer\.team-identifier'" \
  "'com.apple.developer.team-identifier'"
require_rejection "$CASE" \
  'side-by-side TestFlight app team entitlement literal dotted-key escaping'

CASE=$(new_case testflight-profile-leaf-certificate)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'matching_certificate_count == 1' \
  'matching_certificate_count >= 0'
require_rejection "$CASE" 'side-by-side TestFlight unique leaf-certificate match'

CASE=$(new_case testflight-certificate-directory-object-binding)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'    [[ "." -ef "/dev/fd/${extraction_fd}" ]] || exit 1\n    /usr/bin/codesign -d --extract-certificates=certificate' \
  $'    true\n    /usr/bin/codesign -d --extract-certificates=certificate'
require_rejection "$CASE" \
  'side-by-side TestFlight traversable held certificate-directory binding'

CASE=$(new_case testflight-profile-utc-validity)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'creation_epoch=$(TZ=UTC /bin/date -j -f' \
  $'creation_epoch=$(/bin/date -j -f'
require_rejection "$CASE" 'side-by-side TestFlight UTC provisioning validity parsing'

CASE=$(new_case testflight-signed-entitlements-call)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'verify_main_signed_entitlements "${app_path}"' \
  'true'
require_rejection "$CASE" 'side-by-side TestFlight signed entitlement verifier call'

CASE=$(new_case testflight-provisioning-profile-call)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'verify_embedded_provisioning_profile "${app_path}"' \
  'true'
require_rejection "$CASE" 'side-by-side TestFlight provisioning-profile verifier call'

CASE=$(new_case testflight-nested-framework-identity)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'CFBundleIdentifier)" \\\n        == \x27io.livekit.LiveKitWebRTC\x27' \
  $'CFBundleIdentifier)" \\\n        == \x27io.livekit.UnreviewedWebRTC\x27'
require_rejection "$CASE" 'side-by-side TestFlight exact LiveKit framework identity'

CASE=$(new_case testflight-nested-verifier-call)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'verify_reviewed_nested_code "${archive_path}"' \
  'true'
require_rejection "$CASE" 'side-by-side TestFlight archive product nested-code verifier call'

CASE=$(new_case testflight-framework-manifest-membership)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '[(Ie)${expected_framework}]} > 0' \
  '[(Ie)${expected_framework}]} == 1'
require_rejection "$CASE" 'side-by-side TestFlight non-first expected framework membership'

CASE=$(new_case testflight-framework-info-membership)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '[(Ie)${framework_info}]} > 0' \
  '[(Ie)${framework_info}]} == 1'
require_rejection "$CASE" 'side-by-side TestFlight non-first framework Info membership'

CASE=$(new_case testflight-framework-executable-membership)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '[(Ie)${framework_executable}]} > 0' \
  '[(Ie)${framework_executable}]} == 1'
require_rejection "$CASE" 'side-by-side TestFlight non-first framework executable membership'

CASE=$(new_case testflight-nested-bundle-manifest)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '*.bundle' \
  '*.unreviewed-bundle'
require_rejection "$CASE" 'side-by-side TestFlight unreviewed resource-bundle rejection'

CASE=$(new_case testflight-nested-mach-o-manifest)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  'feedface|cefaedfe|feedfacf|cffaedfe|cafebabe|bebafeca|cafebabf|bfbafeca' \
  'feedface'
require_rejection "$CASE" 'side-by-side TestFlight complete Mach-O magic set'

CASE=$(new_case testflight-exact-image-detach)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'    TESTFLIGHT_IMAGE_DEVICE=${attachment_fields[1]}\n    TESTFLIGHT_MOUNTED_DEVICE=${attachment_fields[2]}\n    TESTFLIGHT_IMAGE_PARTITION_DEVICE=${attachment_fields[3]}\n    TESTFLIGHT_BUILD_ATTACH_ATTEMPTED=1\n    TESTFLIGHT_BUILD_ATTACHMENT_ACTIVE=1\n    /usr/bin/hdiutil detach "${TESTFLIGHT_IMAGE_DEVICE}" || return 1' \
  $'    TESTFLIGHT_IMAGE_DEVICE=${attachment_fields[1]}\n    TESTFLIGHT_MOUNTED_DEVICE=${attachment_fields[2]}\n    TESTFLIGHT_IMAGE_PARTITION_DEVICE=${attachment_fields[3]}\n    TESTFLIGHT_BUILD_ATTACH_ATTEMPTED=1\n    TESTFLIGHT_BUILD_ATTACHMENT_ACTIVE=1\n    /usr/bin/hdiutil detach "/Applications/AudioStreamer Host.app" || return 1'
require_rejection "$CASE" 'side-by-side TestFlight exact image-device detach'

CASE=$(new_case testflight-exact-image-removal)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  $'            && TESTFLIGHT_BUILD_CACHE_ENROLLMENT_COMMITTED == 0 )); then\n          /bin/rm -- "${TESTFLIGHT_BUILD_IMAGE_PATH}" || cleanup_failed=1' \
  $'            && TESTFLIGHT_BUILD_CACHE_ENROLLMENT_COMMITTED == 0 )); then\n          /bin/rm -- "/Applications/AudioStreamer Host.app" || cleanup_failed=1'
require_rejection "$CASE" 'side-by-side TestFlight failed-enrollment image rollback'

CASE=$(new_case testflight-failed-enrollment-container-rollback)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '/bin/rmdir -- "${TESTFLIGHT_BUILD_IMAGE_CONTAINER}"' \
  '/bin/rmdir -- "/Applications/AudioStreamer Host.app"'
require_rejection "$CASE" \
  'side-by-side TestFlight failed-enrollment container rollback'

CASE=$(new_case testflight-derived-data-path)
replace_once "$CASE/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh" \
  '-derivedDataPath "${TESTFLIGHT_DERIVED_DATA_DIRECTORY}"' \
  '-derivedDataPath "/Applications/AudioStreamer Host.app"'
require_rejection "$CASE" 'side-by-side TestFlight fixed private DerivedData'

CASE=$(new_case testflight-export-build-number-management)
replace_once "$CASE/iOS/opensteamer/TestFlightExportOptions.plist" \
  '<key>manageAppVersionAndBuildNumber</key><false/>' \
  '<key>manageAppVersionAndBuildNumber</key><true/>'
require_rejection "$CASE" 'side-by-side TestFlight fixed build-number policy'

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

CASE=$(new_case testflight-reviewed-scheme-drift)
replace_once "$CASE/iOS/opensteamer/TestFlightScheme/opensteamerTestFlight.xcscheme" \
  'buildForRunning="NO"' 'buildForRunning="YES"'
require_rejection "$CASE" 'generated TestFlight scheme differs from reviewed archive-only source'

CASE=$(new_case testflight-restorer-destination)
replace_once "$CASE/iOS/opensteamer/scripts/restore-archive-only-testflight-scheme.sh" \
  'DESTINATION_SCHEME="${PROJECT_DIR}/opensteamer.xcodeproj/xcshareddata/xcschemes/opensteamerTestFlight.xcscheme"' \
  'DESTINATION_SCHEME="${PROJECT_DIR}/opensteamer.xcodeproj/xcshareddata/xcschemes/opensteamer.xcscheme"'
require_rejection "$CASE" 'archive-only TestFlight restorer destination'

# The real post-generation helper must reject an existing destination symlink without following
# it. This exercises the filesystem boundary directly instead of relying only on source inspection.
RESTORER_CASE="$TEMPORARY_ROOT/testflight-restorer-symlink"
RESTORER_PROJECT="$RESTORER_CASE/iOS/opensteamer"
mkdir -p \
  "$RESTORER_PROJECT/TestFlightScheme" \
  "$RESTORER_PROJECT/scripts" \
  "$RESTORER_PROJECT/opensteamer.xcodeproj/xcshareddata/xcschemes"
cp "$ROOT_DIR/iOS/opensteamer/TestFlightScheme/opensteamerTestFlight.xcscheme" \
  "$RESTORER_PROJECT/TestFlightScheme/opensteamerTestFlight.xcscheme"
cp "$ROOT_DIR/iOS/opensteamer/scripts/restore-archive-only-testflight-scheme.sh" \
  "$RESTORER_PROJECT/scripts/restore-archive-only-testflight-scheme.sh"
chmod 755 "$RESTORER_PROJECT/scripts/restore-archive-only-testflight-scheme.sh"
RESTORER_SENTINEL="$RESTORER_CASE/protected-sentinel"
print -r -- 'must remain unchanged' >"$RESTORER_SENTINEL"
ln -s "$RESTORER_SENTINEL" \
  "$RESTORER_PROJECT/opensteamer.xcodeproj/xcshareddata/xcschemes/opensteamerTestFlight.xcscheme"
if "$RESTORER_PROJECT/scripts/restore-archive-only-testflight-scheme.sh" \
    >"$RESTORER_CASE/restorer.log" 2>&1; then
  print -u2 -r -- 'archive-only TestFlight restorer unexpectedly followed a destination symlink'
  exit 1
fi
if [[ "$(<"$RESTORER_SENTINEL")" != 'must remain unchanged' ]]; then
  print -u2 -r -- 'archive-only TestFlight restorer modified the destination symlink target'
  exit 1
fi

CASE=$(new_case visible-navigation-title)
replace_once "$CASE/iOS/opensteamer/Sources/Views/BrowserView.swift" \
  '.navigationTitle("opensteamer")' '.navigationTitle("Opensteamer")'
require_rejection "$CASE" 'iOS navigation-title lowercase identity'

CASE=$(new_case virtual-driver-directory)
mv "$CASE/macOS/VirtualAudioDriver" "$CASE/macOS/VirtualAudioDriverRenamed"
require_rejection "$CASE" 'required directory is missing: macOS/VirtualAudioDriver'

CASE=$(new_case virtual-driver-build-script-missing)
mv "$CASE/macOS/VirtualAudioDriver/scripts/build-driver.sh" \
  "$CASE/macOS/VirtualAudioDriver/scripts/build-driver.sh.missing"
require_rejection "$CASE" \
  'required file is missing: macOS/VirtualAudioDriver/scripts/build-driver.sh'

CASE=$(new_case virtual-driver-build-script-not-executable)
chmod 644 "$CASE/macOS/VirtualAudioDriver/scripts/build-driver.sh"
require_rejection "$CASE" 'virtual microphone driver build script: required file is not executable'

CASE=$(new_case virtual-driver-verifier-missing)
mv "$CASE/macOS/VirtualAudioDriver/scripts/verify-driver-bundle.sh" \
  "$CASE/macOS/VirtualAudioDriver/scripts/verify-driver-bundle.sh.missing"
require_rejection "$CASE" \
  'required file is missing: macOS/VirtualAudioDriver/scripts/verify-driver-bundle.sh'

CASE=$(new_case virtual-driver-verifier-not-executable)
chmod 644 "$CASE/macOS/VirtualAudioDriver/scripts/verify-driver-bundle.sh"
require_rejection "$CASE" 'virtual microphone bundle verifier: required file is not executable'

CASE=$(new_case virtual-driver-build-bundle-filename)
replace_once "$CASE/macOS/VirtualAudioDriver/scripts/build-driver.sh" \
  '"${requested_output:t}" != "OpensteamerVirtualMicrophone.driver"' \
  '"${requested_output:t}" != "OpensteamerMicrophone.driver"'
require_rejection "$CASE" 'virtual microphone build output bundle filename'

CASE=$(new_case virtual-driver-verifier-bundle-filename)
replace_once "$CASE/macOS/VirtualAudioDriver/scripts/verify-driver-bundle.sh" \
  '"${bundle:t}" != "OpensteamerVirtualMicrophone.driver"' \
  '"${bundle:t}" != "OpensteamerMicrophone.driver"'
require_rejection "$CASE" 'virtual microphone verifier bundle filename'

CASE=$(new_case virtual-driver-build-executable-filename)
replace_once "$CASE/macOS/VirtualAudioDriver/scripts/build-driver.sh" \
  '"$bundle/Contents/MacOS/OpensteamerVirtualMicrophone"' \
  '"$bundle/Contents/MacOS/OpensteamerMicrophone"'
require_rejection "$CASE" 'virtual microphone build executable filename'

CASE=$(new_case virtual-driver-verifier-executable-filename)
replace_once "$CASE/macOS/VirtualAudioDriver/scripts/verify-driver-bundle.sh" \
  'executable="$bundle/Contents/MacOS/OpensteamerVirtualMicrophone"' \
  'executable="$bundle/Contents/MacOS/OpensteamerMicrophone"'
require_rejection "$CASE" 'virtual microphone verifier executable filename'

CASE=$(new_case virtual-driver-build-minimum-macos)
replace_once "$CASE/macOS/VirtualAudioDriver/scripts/build-driver.sh" \
  '-mmacosx-version-min=14.0' '-mmacosx-version-min=13.0'
require_rejection "$CASE" 'virtual microphone build minimum macOS version'

CASE=$(new_case virtual-driver-build-signature-identifier)
replace_once "$CASE/macOS/VirtualAudioDriver/scripts/build-driver.sh" \
  '--identifier com.elamin.opensteamer.VirtualMicrophoneDriver' \
  '--identifier com.elamin.opensteamer.MicrophoneDriver'
require_rejection "$CASE" 'virtual microphone build signature identifier'

CASE=$(new_case virtual-driver-bundle-identifier)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/Info.plist" \
  '<key>CFBundleIdentifier</key><string>com.elamin.opensteamer.VirtualMicrophoneDriver</string>' \
  '<key>CFBundleIdentifier</key><string>com.elamin.opensteamer.MicrophoneDriver</string>'
require_rejection "$CASE" 'virtual microphone driver bundle identifier'

CASE=$(new_case virtual-driver-bundle-name)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/Info.plist" \
  '<key>CFBundleName</key><string>opensteamer Virtual Microphone</string>' \
  '<key>CFBundleName</key><string>opensteamer Microphone</string>'
require_rejection "$CASE" 'virtual microphone driver bundle name'

CASE=$(new_case virtual-driver-executable-name)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/Info.plist" \
  '<key>CFBundleExecutable</key><string>OpensteamerVirtualMicrophone</string>' \
  '<key>CFBundleExecutable</key><string>OpensteamerMicrophone</string>'
require_rejection "$CASE" 'virtual microphone driver executable name'

CASE=$(new_case virtual-driver-short-version)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/Info.plist" \
  '<key>CFBundleShortVersionString</key><string>0.1.0</string>' \
  '<key>CFBundleShortVersionString</key><string>0.2.0</string>'
require_rejection "$CASE" 'virtual microphone driver short version'

CASE=$(new_case virtual-driver-build-version)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/Info.plist" \
  '<key>CFBundleVersion</key><string>1</string>' \
  '<key>CFBundleVersion</key><string>2</string>'
require_rejection "$CASE" 'virtual microphone driver build version'

CASE=$(new_case virtual-driver-package-type)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/Info.plist" \
  '<key>CFBundlePackageType</key><string>BNDL</string>' \
  '<key>CFBundlePackageType</key><string>APPL</string>'
require_rejection "$CASE" 'virtual microphone driver package type'

CASE=$(new_case virtual-driver-plist-minimum-macos)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/Info.plist" \
  '<key>LSMinimumSystemVersion</key><string>14.0</string>' \
  '<key>LSMinimumSystemVersion</key><string>13.0</string>'
require_rejection "$CASE" 'virtual microphone driver minimum macOS version'

CASE=$(new_case virtual-driver-factory-cardinality)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/Info.plist" \
  $'  <key>81CE9D28-D187-499B-84EE-F6AC6159C800</key>\n  <string>OpensteamerVirtualMicrophone_Create</string>' \
  $'  <key>81CE9D28-D187-499B-84EE-F6AC6159C800</key>\n  <string>OpensteamerVirtualMicrophone_Create</string>\n  <key>00000000-0000-0000-0000-000000000000</key>\n  <string>UnexpectedFactory</string>'
require_rejection "$CASE" 'virtual microphone factory dictionary cardinality'

CASE=$(new_case virtual-driver-factory-uuid)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/Info.plist" \
  $'<key>81CE9D28-D187-499B-84EE-F6AC6159C800</key>\n  <string>OpensteamerVirtualMicrophone_Create</string>' \
  $'<key>00000000-0000-0000-0000-000000000000</key>\n  <string>OpensteamerVirtualMicrophone_Create</string>'
require_rejection "$CASE" 'virtual microphone factory UUID and symbol'

CASE=$(new_case virtual-driver-factory-symbol)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/Info.plist" \
  '<string>OpensteamerVirtualMicrophone_Create</string>' \
  '<string>OpensteamerVirtualMicrophone_CreateUnexpected</string>'
require_rejection "$CASE" 'virtual microphone factory UUID and symbol'

CASE=$(new_case virtual-driver-type-cardinality)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/Info.plist" \
  $'  <key>443ABAB8-E7B3-491A-B985-BEB9187030DB</key>\n  <array><string>81CE9D28-D187-499B-84EE-F6AC6159C800</string></array>' \
  $'  <key>443ABAB8-E7B3-491A-B985-BEB9187030DB</key>\n  <array><string>81CE9D28-D187-499B-84EE-F6AC6159C800</string></array>\n  <key>00000000-0000-0000-0000-000000000000</key>\n  <array><string>81CE9D28-D187-499B-84EE-F6AC6159C800</string></array>'
require_rejection "$CASE" 'virtual microphone plug-in type dictionary cardinality'

CASE=$(new_case virtual-driver-type-uuid)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/Info.plist" \
  '<key>443ABAB8-E7B3-491A-B985-BEB9187030DB</key>' \
  '<key>00000000-0000-0000-0000-000000000000</key>'
require_rejection "$CASE" 'virtual microphone factory list cardinality'

CASE=$(new_case virtual-driver-factory-list-cardinality)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/Info.plist" \
  '<array><string>81CE9D28-D187-499B-84EE-F6AC6159C800</string></array>' \
  '<array><string>81CE9D28-D187-499B-84EE-F6AC6159C800</string><string>00000000-0000-0000-0000-000000000000</string></array>'
require_rejection "$CASE" 'virtual microphone factory list cardinality'

CASE=$(new_case virtual-driver-type-mapping)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/Info.plist" \
  '<array><string>81CE9D28-D187-499B-84EE-F6AC6159C800</string></array>' \
  '<array><string>00000000-0000-0000-0000-000000000000</string></array>'
require_rejection "$CASE" 'virtual microphone plug-in type UUID mapping'

CASE=$(new_case virtual-driver-source-bundle-identifier)
replace_once "$CASE/macOS/VirtualAudioDriver/include/OpensteamerVirtualMicrophoneDriver.h" \
  '"com.elamin.opensteamer.VirtualMicrophoneDriver"' \
  '"com.elamin.opensteamer.MicrophoneDriver"'
require_rejection "$CASE" 'virtual microphone source bundle identifier'

CASE=$(new_case virtual-driver-visible-uid)
replace_once "$CASE/macOS/VirtualAudioDriver/include/OpensteamerVirtualMicrophoneDriver.h" \
  '"com.elamin.opensteamer.virtual-microphone.input"' \
  '"com.elamin.opensteamer.virtual-microphone.capture"'
require_rejection "$CASE" 'virtual microphone visible-input UID'

CASE=$(new_case virtual-driver-hidden-uid)
replace_once "$CASE/macOS/VirtualAudioDriver/include/OpensteamerVirtualMicrophoneDriver.h" \
  '"com.elamin.opensteamer.virtual-microphone.writer"' \
  '"com.elamin.opensteamer.virtual-microphone.output"'
require_rejection "$CASE" 'virtual microphone hidden-writer UID'

CASE=$(new_case virtual-driver-model-uid)
replace_once "$CASE/macOS/VirtualAudioDriver/include/OpensteamerVirtualMicrophoneDriver.h" \
  '"com.elamin.opensteamer.virtual-microphone.model"' \
  '"com.elamin.opensteamer.virtual-microphone.model-v2"'
require_rejection "$CASE" 'virtual microphone model UID'

CASE=$(new_case virtual-driver-clock-domain)
replace_once "$CASE/macOS/VirtualAudioDriver/include/OpensteamerVirtualMicrophoneDriver.h" \
  'kOSVAClockDomain = 0x6F73564D,' \
  'kOSVAClockDomain = 0x00000000,'
require_rejection "$CASE" 'virtual microphone shared clock domain'

CASE=$(new_case virtual-driver-core-sample-rate)
replace_once "$CASE/macOS/VirtualAudioDriver/include/OpensteamerVirtualAudioCore.h" \
  '#define OSVA_SAMPLE_RATE_HZ UINT64_C(48000)' \
  '#define OSVA_SAMPLE_RATE_HZ UINT64_C(44100)'
require_rejection "$CASE" 'virtual microphone core sample rate'

CASE=$(new_case virtual-driver-core-channels)
replace_once "$CASE/macOS/VirtualAudioDriver/include/OpensteamerVirtualAudioCore.h" \
  '#define OSVA_CHANNEL_COUNT UINT32_C(1)' \
  '#define OSVA_CHANNEL_COUNT UINT32_C(2)'
require_rejection "$CASE" 'virtual microphone core mono channel count'

CASE=$(new_case virtual-driver-core-bytes-per-frame)
replace_once "$CASE/macOS/VirtualAudioDriver/include/OpensteamerVirtualAudioCore.h" \
  '#define OSVA_BYTES_PER_FRAME UINT32_C(4)' \
  '#define OSVA_BYTES_PER_FRAME UINT32_C(8)'
require_rejection "$CASE" 'virtual microphone core Float32 bytes per frame'

CASE=$(new_case virtual-driver-visible-role)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/OpensteamerVirtualMicrophone.c" \
  $'(OSVAIsVisibleDevice(objectID) &&\n       scope == kAudioObjectPropertyScopeInput)' \
  $'(OSVAIsVisibleDevice(objectID) &&\n       scope == kAudioObjectPropertyScopeOutput)'
require_rejection "$CASE" 'virtual microphone visible device 1-in/0-out role'

CASE=$(new_case virtual-driver-hidden-role)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/OpensteamerVirtualMicrophone.c" \
  $'(OSVAIsHiddenDevice(objectID) &&\n       scope == kAudioObjectPropertyScopeOutput)' \
  $'(OSVAIsHiddenDevice(objectID) &&\n       scope == kAudioObjectPropertyScopeInput)'
require_rejection "$CASE" 'virtual microphone hidden device 0-in/1-out role'

CASE=$(new_case virtual-driver-added-visible-output-role)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/OpensteamerVirtualMicrophone.c" \
  $'(OSVAIsVisibleDevice(objectID) &&\n       scope == kAudioObjectPropertyScopeInput) ||' \
  $'(OSVAIsVisibleDevice(objectID) &&\n       scope == kAudioObjectPropertyScopeInput) ||\n      (OSVAIsVisibleDevice(objectID) &&\n       scope == kAudioObjectPropertyScopeOutput) ||'
require_rejection "$CASE" 'virtual microphone visible output-role absence'

CASE=$(new_case virtual-driver-added-hidden-input-role)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/OpensteamerVirtualMicrophone.c" \
  $'(OSVAIsHiddenDevice(objectID) &&\n       scope == kAudioObjectPropertyScopeOutput)) {' \
  $'(OSVAIsHiddenDevice(objectID) &&\n       scope == kAudioObjectPropertyScopeOutput) ||\n      (OSVAIsHiddenDevice(objectID) &&\n       scope == kAudioObjectPropertyScopeInput)) {'
require_rejection "$CASE" 'virtual microphone hidden input-role absence'

CASE=$(new_case virtual-driver-role-stream-count)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/OpensteamerVirtualMicrophone.c" \
  'return OSVADeviceRoleObjectCount(objectID, scope) == 0 ? 0 : 1;' \
  'return OSVADeviceRoleObjectCount(objectID, scope) == 0 ? 0 : 2;'
require_rejection "$CASE" 'virtual microphone one stream per valid endpoint role'

CASE=$(new_case virtual-driver-native-sample-rate)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/OpensteamerVirtualMicrophone.c" \
  '.mSampleRate = 48000.0,' '.mSampleRate = 44100.0,'
require_rejection "$CASE" 'virtual microphone native sample rate'

CASE=$(new_case virtual-driver-native-format-id)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/OpensteamerVirtualMicrophone.c" \
  '.mFormatID = kAudioFormatLinearPCM,' \
  '.mFormatID = kAudioFormatMPEG4AAC,'
require_rejection "$CASE" 'virtual microphone native linear PCM format'

CASE=$(new_case virtual-driver-native-format-flags)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/OpensteamerVirtualMicrophone.c" \
  $'.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian |\n                      kAudioFormatFlagIsPacked,' \
  $'.mFormatFlags = kAudioFormatFlagsNativeEndian |\n                      kAudioFormatFlagIsPacked,'
require_rejection "$CASE" 'virtual microphone native Float32 packed-endian flags'

CASE=$(new_case virtual-driver-native-bytes-per-packet)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/OpensteamerVirtualMicrophone.c" \
  '.mBytesPerPacket = 4,' '.mBytesPerPacket = 8,'
require_rejection "$CASE" 'virtual microphone native bytes per packet'

CASE=$(new_case virtual-driver-native-frames-per-packet)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/OpensteamerVirtualMicrophone.c" \
  '.mFramesPerPacket = 1,' '.mFramesPerPacket = 2,'
require_rejection "$CASE" 'virtual microphone native frames per packet'

CASE=$(new_case virtual-driver-native-bytes-per-frame)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/OpensteamerVirtualMicrophone.c" \
  '.mBytesPerFrame = 4,' '.mBytesPerFrame = 8,'
require_rejection "$CASE" 'virtual microphone native bytes per frame'

CASE=$(new_case virtual-driver-native-channels)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/OpensteamerVirtualMicrophone.c" \
  '.mChannelsPerFrame = 1,' '.mChannelsPerFrame = 2,'
require_rejection "$CASE" 'virtual microphone native mono channel count'

CASE=$(new_case virtual-driver-native-bit-depth)
replace_once "$CASE/macOS/VirtualAudioDriver/Driver/OpensteamerVirtualMicrophone.c" \
  '.mBitsPerChannel = 32,' '.mBitsPerChannel = 16,'
require_rejection "$CASE" 'virtual microphone native Float32 bit depth'

CASE=$(new_case virtual-driver-legacy-visible-uid)
print -r -- '#define FORBIDDEN_LEGACY_UID "BlackHole2ch_UID"' \
  >>"$CASE/macOS/VirtualAudioDriver/include/OpensteamerVirtualMicrophoneDriver.h"
require_rejection "$CASE" 'legacy BlackHole device UID appears in the new virtual microphone driver'

CASE=$(new_case mac-host-microphone-usage-description)
replace_once "$CASE/macOS/OpensteamerHost/Info.plist" \
  '<key>NSMicrophoneUsageDescription</key><string>opensteamer uses its virtual microphone to route your iPhone&apos;s microphone into calls on this Mac.</string>' \
  '<key>NSMicrophoneUsageDescription</key><string>opensteamer records the BlackHole virtual input.</string>'
require_rejection "$CASE" 'macOS host microphone description lowercase identity'

CASE=$(new_case swiftpm-host-microphone-usage-description)
replace_once "$CASE/macOS/Sources/CaptureServer/Info.plist" \
  '<key>NSMicrophoneUsageDescription</key><string>opensteamer uses its virtual microphone to route your iPhone&apos;s microphone into calls on this Mac.</string>' \
  '<key>NSMicrophoneUsageDescription</key><string>opensteamer records the BlackHole virtual input.</string>'
require_rejection "$CASE" 'SwiftPM capture-server microphone description lowercase identity'

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
  '"com.elamin.opensteamer.CaptureServer.WorldwidePairing.v1"' \
  '"com.elamin.AudioStreamer.CaptureServer.WorldwidePairing.v1"'
require_rejection "$CASE" 'isolated opensteamer pairing Keychain service'

CASE=$(new_case mac-protected-pairing-keychain-service-added)
print -r -- 'let forbidden = "com.elamin.AudioStreamer.CaptureServer.WorldwidePairing.v1"' \
  >>"$CASE/macOS/Sources/CaptureServer/WorldwidePairingStore.swift"
require_rejection "$CASE" 'protected legacy pairing Keychain service absence'

CASE=$(new_case mac-protected-pairing-keychain-service-other-source)
print -r -- 'let forbidden = "com.elamin.AudioStreamer.CaptureServer.WorldwidePairing.v1"' \
  >>"$CASE/macOS/Sources/CaptureServer/CaptureServerMain.swift"
require_rejection "$CASE" 'protected legacy pairing Keychain service appears in macOS runtime source'

CASE=$(new_case mac-pairing-arbitrary-service-initializer)
print -r -- 'init(service: String) {}' \
  >>"$CASE/macOS/Sources/CaptureServer/WorldwidePairingStore.swift"
require_rejection "$CASE" 'arbitrary pairing Keychain service initializer absence'

CASE=$(new_case mac-pairing-explicit-composition)
replace_once "$CASE/macOS/Sources/CaptureServer/CaptureServerMain.swift" \
  'dataStore: WorldwideKeychainDataStore()' \
  'dataStore: LegacyWorldwideKeychainDataStore()'
require_rejection "$CASE" 'explicit opensteamer pairing-store composition'

CASE=$(new_case mac-pairing-code-flush)
replace_once "$CASE/macOS/Sources/CaptureServer/CaptureServerMain.swift" \
  'fflush(stdout)' '/* missing pairing-code flush */'
require_rejection "$CASE" 'immediate one-time pairing-code flush'

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

fi

if [[ "${OPENSTEAMER_IDENTITY_LOCATOR_ONLY:-0}" == 1 ]]; then
  print -- 'opensteamer product identity mutation locators passed'
  exit 0
fi

# Exercise the real release-guard parsers and state machines without reaching hdiutil, Xcode,
# signing, a device, or either installed runtime. The sourced library is cut immediately before
# its main entry point, and every external-state writer is replaced with a deterministic fixture.
BEHAVIOR_ROOT="$TEMPORARY_ROOT/release-guard-behavior"
BEHAVIOR_CONTROL="$BEHAVIOR_ROOT/control"
BEHAVIOR_TARGET_IMAGE='/Volumes/t7/opensteamer-behavior-target.sparseimage'
BEHAVIOR_MOUNT_POINT='/private/tmp/opensteamer-behavior-mount'
BEHAVIOR_WRAPPER="$ROOT_DIR/iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh"
mkdir -p "$BEHAVIOR_CONTROL"

DOTTED_KEY_FIXTURE="$BEHAVIOR_ROOT/dotted-entitlement-keys.plist"
print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>com.apple.developer.team-identifier</key><string>MSMG8CJLB3</string>
<key>Entitlements</key><dict>
<key>com.apple.developer.team-identifier</key><string>MSMG8CJLB3</string>
</dict>
</dict></plist>' >"$DOTTED_KEY_FIXTURE"
WRAPPER_PATH="$BEHAVIOR_WRAPPER" DOTTED_KEY_FIXTURE="$DOTTED_KEY_FIXTURE" \
/bin/zsh <<'DOTTEDKEYTEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM

typeset document
document=$(<"$DOTTED_KEY_FIXTURE")
[[ "$(plist_document_raw_value \
      "$document" 'com\.apple\.developer\.team-identifier')" \
      == "$EXPECTED_TEAM_ID" \
    && "$(plist_document_raw_value \
      "$document" 'Entitlements.com\.apple\.developer\.team-identifier')" \
      == "$EXPECTED_TEAM_ID" ]]
for unescaped_key_path in \
    com.apple.developer.team-identifier \
    Entitlements.com.apple.developer.team-identifier; do
  if plist_document_raw_value \
      "$document" "$unescaped_key_path" >/dev/null 2>&1; then
    print -u2 -r -- \
      "unescaped dotted entitlement key unexpectedly resolved: ${unescaped_key_path}"
    exit 1
  fi
done
DOTTEDKEYTEST

HELD_DIRECTORY="$BEHAVIOR_ROOT/held-certificate-directory"
/bin/mkdir -m 700 "$HELD_DIRECTORY"
WRAPPER_PATH="$BEHAVIOR_WRAPPER" HELD_DIRECTORY="$HELD_DIRECTORY" \
/bin/zsh <<'HELDDIRECTORYTEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM

typeset -i held_fd=-1
sysopen -r -o nofollow -u held_fd "$HELD_DIRECTORY"
(
  cd "$HELD_DIRECTORY" || exit 1
  [[ "." -ef "/dev/fd/${held_fd}" ]] || exit 1
)
typeset moved_directory="${HELD_DIRECTORY}.moved"
/bin/mv -- "$HELD_DIRECTORY" "$moved_directory"
/bin/mkdir -m 700 "$HELD_DIRECTORY"
if (
  cd "$HELD_DIRECTORY" || exit 1
  [[ "." -ef "/dev/fd/${held_fd}" ]]
); then
  print -u2 -r -- 'replacement certificate directory matched the held object'
  exit 1
fi
/bin/rmdir -- "$HELD_DIRECTORY"
/bin/mv -- "$moved_directory" "$HELD_DIRECTORY"
exec {held_fd}>&-
HELDDIRECTORYTEST

write_hdiutil_snapshot() {
  local destination=$1
  local image_count=$2
  local target_indices=$3
  local image_index
  local image_path
  local disk_number
  {
    print -r -- '<?xml version="1.0" encoding="UTF-8"?>'
    print -r -- '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    print -r -- '<plist version="1.0"><dict><key>images</key><array>'
    for (( image_index = 0; image_index < image_count; image_index += 1 )); do
      disk_number=$((image_index + 100))
      if [[ ",${target_indices}," == *",${image_index},"* ]]; then
        image_path=$BEHAVIOR_TARGET_IMAGE
      else
        image_path="/Volumes/t7/unrelated-${image_index}.sparseimage"
      fi
      print -r -- '<dict>'
      print -r -- "<key>image-path</key><string>${image_path}</string>"
      if [[ "$image_path" == "$BEHAVIOR_TARGET_IMAGE" ]]; then
        print -r -- '<key>image-encrypted</key><true/><key>writeable</key><true/>'
      fi
      print -r -- '<key>system-entities</key><array>'
      print -r -- "<dict><key>dev-entry</key><string>/dev/disk${disk_number}</string><key>content-hint</key><string>GUID_partition_scheme</string></dict>"
      if [[ "$image_path" == "$BEHAVIOR_TARGET_IMAGE" ]]; then
        print -r -- "<dict><key>dev-entry</key><string>/dev/disk${disk_number}s1</string><key>content-hint</key><string>Apple_APFS</string><key>mount-point</key><string>${BEHAVIOR_MOUNT_POINT}</string></dict>"
      fi
      print -r -- '</array></dict>'
    done
    print -r -- '</array></dict></plist>'
  } >"$destination"
}

write_hdiutil_entity_heavy_snapshot() {
  local destination=$1
  local entity_index
  {
    print -r -- '<?xml version="1.0" encoding="UTF-8"?>'
    print -r -- '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    print -r -- '<plist version="1.0"><dict><key>images</key><array><dict>'
    print -r -- "<key>image-path</key><string>${BEHAVIOR_TARGET_IMAGE}</string>"
    print -r -- '<key>image-encrypted</key><true/><key>writeable</key><true/>'
    print -r -- '<key>system-entities</key><array>'
    print -r -- '<dict><key>dev-entry</key><string>/dev/disk900</string><key>content-hint</key><string>GUID_partition_scheme</string></dict>'
    for (( entity_index = 1; entity_index < 129; entity_index += 1 )); do
      print -r -- "<dict><key>dev-entry</key><string>/dev/disk900s${entity_index}</string><key>content-hint</key><string>Apple_Free</string></dict>"
    done
    print -r -- "<dict><key>dev-entry</key><string>/dev/disk900s129</string><key>content-hint</key><string>Apple_APFS</string><key>mount-point</key><string>${BEHAVIOR_MOUNT_POINT}</string></dict>"
    print -r -- '</array></dict></array></dict></plist>'
  } >"$destination"
}

write_hdiutil_efi_first_snapshot() {
  local destination=$1
  print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>images</key><array><dict>
<key>image-path</key><string>'"${BEHAVIOR_TARGET_IMAGE}"'</string>
<key>image-encrypted</key><true/><key>writeable</key><true/>
<key>system-entities</key><array>
<dict><key>dev-entry</key><string>/dev/disk777s1</string><key>content-hint</key><string>EFI</string></dict>
<dict><key>dev-entry</key><string>/dev/disk777s2</string><key>content-hint</key><string>Apple_APFS</string></dict>
<dict><key>dev-entry</key><string>/dev/disk777</string><key>content-hint</key><string>GUID_partition_scheme</string></dict>
<dict><key>dev-entry</key><string>/dev/disk778s1</string><key>content-hint</key><string>41504653-0000-11AA-AA11-00306543ECAC</string><key>mount-point</key><string>'"${BEHAVIOR_MOUNT_POINT}"'</string></dict>
<dict><key>dev-entry</key><string>/dev/disk778</string><key>content-hint</key><string>EF57347C-0000-11AA-AA11-00306543ECAC</string></dict>
</array></dict></array></dict></plist>' >"$destination"
}

HDITARGET="$BEHAVIOR_ROOT/hdiutil-target-at-129.plist"
HDIABSENT="$BEHAVIOR_ROOT/hdiutil-absent-130.plist"
HDIDUPLICATE="$BEHAVIOR_ROOT/hdiutil-duplicate.plist"
HDIZERO="$BEHAVIOR_ROOT/hdiutil-zero.plist"
HDISCALAR="$BEHAVIOR_ROOT/hdiutil-scalar.plist"
HDIMISSINGPATH="$BEHAVIOR_ROOT/hdiutil-missing-path.plist"
HDIBADENTITIES="$BEHAVIOR_ROOT/hdiutil-bad-entities.plist"
HDIENTITYHEAVY="$BEHAVIOR_ROOT/hdiutil-entity-at-129.plist"
HDIEFIFIRST="$BEHAVIOR_ROOT/hdiutil-efi-first.plist"
HDIMALFORMEDTAIL="$BEHAVIOR_ROOT/hdiutil-malformed-entity-at-129.plist"
write_hdiutil_snapshot "$HDITARGET" 130 129
write_hdiutil_snapshot "$HDIABSENT" 130 ''
write_hdiutil_snapshot "$HDIDUPLICATE" 130 '64,129'
write_hdiutil_snapshot "$HDIZERO" 0 ''
write_hdiutil_entity_heavy_snapshot "$HDIENTITYHEAVY"
write_hdiutil_efi_first_snapshot "$HDIEFIFIRST"
/bin/cp -- "$HDIENTITYHEAVY" "$HDIMALFORMEDTAIL"
/usr/bin/plutil -replace images.0.system-entities.1.content-hint \
  -string Apple_APFS "$HDIMALFORMEDTAIL"
/usr/bin/plutil -insert images.0.system-entities.1.mount-point \
  -string "$BEHAVIOR_MOUNT_POINT" "$HDIMALFORMEDTAIL"
/usr/bin/plutil -remove images.0.system-entities.129.content-hint \
  "$HDIMALFORMEDTAIL"
print -r -- '<?xml version="1.0"?><plist version="1.0"><dict><key>images</key><string>not-an-array</string></dict></plist>' >"$HDISCALAR"
print -r -- '<?xml version="1.0"?><plist version="1.0"><dict><key>images</key><array><dict><key>system-entities</key><array><dict><key>dev-entry</key><string>/dev/disk100</string><key>content-hint</key><string>GUID_partition_scheme</string></dict></array></dict></array></dict></plist>' >"$HDIMISSINGPATH"
print -r -- '<?xml version="1.0"?><plist version="1.0"><dict><key>images</key><array><dict><key>image-path</key><string>/Volumes/t7/unrelated.sparseimage</string><key>system-entities</key><string>not-an-array</string></dict></array></dict></plist>' >"$HDIBADENTITIES"

WRAPPER_PATH="$BEHAVIOR_WRAPPER" \
CONTROL_PATH="$BEHAVIOR_CONTROL" \
TARGET_IMAGE="$BEHAVIOR_TARGET_IMAGE" \
MOUNT_POINT="$BEHAVIOR_MOUNT_POINT" \
SNAP_TARGET="$HDITARGET" \
SNAP_ABSENT="$HDIABSENT" \
SNAP_DUPLICATE="$HDIDUPLICATE" \
SNAP_ZERO="$HDIZERO" \
SNAP_SCALAR="$HDISCALAR" \
SNAP_MISSING_PATH="$HDIMISSINGPATH" \
SNAP_BAD_ENTITIES="$HDIBADENTITIES" \
SNAP_ENTITY_HEAVY="$HDIENTITYHEAVY" \
SNAP_EFI_FIRST="$HDIEFIFIRST" \
SNAP_MALFORMED_TAIL="$HDIMALFORMEDTAIL" \
/bin/zsh <<'HDITEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM

TESTFLIGHT_CONTROL_DIRECTORY=$CONTROL_PATH
TESTFLIGHT_BUILD_IMAGE_PATH=$TARGET_IMAGE
TESTFLIGHT_BUILD_MOUNT_POINT=$MOUNT_POINT
typeset SNAPSHOT=''
typeset LAST_OUTPUT=''

function write_private_plist() {
  /bin/cp -- "$SNAPSHOT" "$1"
}

function expect_status() {
  local expected=$1
  shift
  local actual
  if LAST_OUTPUT=$("$@" 2>/dev/null); then
    actual=0
  else
    actual=$?
  fi
  [[ $actual == $expected ]] || {
    print -u2 -r -- "release-guard behavior status mismatch: expected ${expected}, got ${actual}: $*"
    exit 1
  }
}

SNAPSHOT=$SNAP_TARGET
expect_status 0 find_current_attachment_root_device
[[ "$LAST_OUTPUT" == '/dev/disk229' ]]
expect_status 0 find_current_attachment_record
[[ "$LAST_OUTPUT" == '/dev/disk229|/dev/disk229s1|/dev/disk229s1|true|true' ]]
expect_status 1 current_attachment_is_absent

SNAPSHOT=$SNAP_ABSENT
expect_status 1 find_current_attachment_root_device
expect_status 0 current_attachment_is_absent

SNAPSHOT=$SNAP_DUPLICATE
expect_status 2 find_current_attachment_root_device
expect_status 2 find_current_attachment_record
expect_status 2 current_attachment_is_absent

SNAPSHOT=$SNAP_ENTITY_HEAVY
expect_status 0 find_current_attachment_root_device
[[ "$LAST_OUTPUT" == '/dev/disk900' ]]
expect_status 0 find_current_attachment_record
[[ "$LAST_OUTPUT" == '/dev/disk900|/dev/disk900s129|/dev/disk900s129|true|true' ]]

SNAPSHOT=$SNAP_EFI_FIRST
expect_status 0 find_current_attachment_root_device
[[ "$LAST_OUTPUT" == '/dev/disk777' ]]
expect_status 0 find_current_attachment_record
[[ "$LAST_OUTPUT" == '/dev/disk777|/dev/disk778s1|/dev/disk777s2|true|true' ]]

SNAPSHOT=$SNAP_MALFORMED_TAIL
expect_status 2 find_current_attachment_root_device
expect_status 2 find_current_attachment_record
expect_status 2 current_attachment_is_absent

SNAPSHOT=$SNAP_ZERO
expect_status 1 find_current_attachment_root_device
expect_status 0 current_attachment_is_absent

for SNAPSHOT in "$SNAP_SCALAR" "$SNAP_MISSING_PATH"; do
  expect_status 2 find_current_attachment_root_device
  expect_status 2 current_attachment_is_absent
done

# A malformed unrelated image must not make the exact cache image indeterminate.
SNAPSHOT=$SNAP_BAD_ENTITIES
expect_status 1 find_current_attachment_root_device
expect_status 1 find_current_attachment_record
expect_status 0 current_attachment_is_absent

function write_private_plist() { return 1 }
expect_status 2 find_current_attachment_root_device
expect_status 2 current_attachment_is_absent
HDITEST

T7_ROOT_FIXTURE="$BEHAVIOR_ROOT/t7-root.plist"
T7_STORE_FIXTURE="$BEHAVIOR_ROOT/t7-store.plist"
T7_DISK_FIXTURE="$BEHAVIOR_ROOT/t7-disk.plist"
print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>MountPoint</key><string>/Volumes/t7</string>
<key>FilesystemType</key><string>apfs</string>
<key>WritableVolume</key><true/>
<key>VolumeName</key><string>t7</string>
<key>BusProtocol</key><string>USB</string>
<key>Internal</key><false/>
<key>OSInternalMedia</key><false/>
<key>RemovableMediaOrExternalDevice</key><true/>
<key>DeviceIdentifier</key><string>disk99s1</string>
<key>ParentWholeDisk</key><string>disk99</string>
<key>VolumeUUID</key><string>25E93573-3993-42CC-8EE8-4F7A6C86A2EF</string>
<key>APFSContainerSize</key><integer>999995129856</integer>
<key>APFSPhysicalStores</key><array><dict><key>APFSPhysicalStore</key><string>disk98s2</string></dict></array>
</dict></plist>' >"$T7_ROOT_FIXTURE"
print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>DeviceIdentifier</key><string>disk98s2</string>
<key>DiskUUID</key><string>CE1B73D9-E28D-40D2-8D37-D81F2C3F1051</string>
<key>APFSContainerReference</key><string>disk99</string>
<key>ParentWholeDisk</key><string>disk98</string>
<key>Size</key><integer>999995129856</integer>
<key>Internal</key><false/>
<key>OSInternalMedia</key><false/>
<key>RemovableMediaOrExternalDevice</key><true/>
</dict></plist>' >"$T7_STORE_FIXTURE"
print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>DeviceIdentifier</key><string>disk98</string>
<key>WholeDisk</key><true/>
<key>VirtualOrPhysical</key><string>Physical</string>
<key>MediaName</key><string>PSSD T7</string>
<key>BusProtocol</key><string>USB</string>
<key>Size</key><integer>1000204886016</integer>
<key>Internal</key><false/>
<key>OSInternalMedia</key><false/>
<key>RemovableMediaOrExternalDevice</key><true/>
</dict></plist>' >"$T7_DISK_FIXTURE"

WRAPPER_PATH="$BEHAVIOR_WRAPPER" \
CONTROL_PATH="$BEHAVIOR_CONTROL" \
ROOT_FIXTURE="$T7_ROOT_FIXTURE" \
STORE_FIXTURE="$T7_STORE_FIXTURE" \
DISK_FIXTURE="$T7_DISK_FIXTURE" \
/bin/zsh <<'T7TEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM

TESTFLIGHT_CONTROL_DIRECTORY=$CONTROL_PATH
TESTFLIGHT_BUILD_ROOT_PARENT_IDENTITY=$(stat_identity "${TESTFLIGHT_BUILD_ROOT:h}")
TESTFLIGHT_BUILD_ROOT_IDENTITY=$(stat_identity "${TESTFLIGHT_BUILD_ROOT}")
TESTFLIGHT_BUILD_ROOT_DEVICE_IDENTIFIER=disk99s1
TESTFLIGHT_BUILD_ROOT_PARENT_WHOLE_DISK=disk99
TESTFLIGHT_BUILD_ROOT_VOLUME_UUID=$EXPECTED_TESTFLIGHT_BUILD_ROOT_VOLUME_UUID
TESTFLIGHT_BUILD_ROOT_PHYSICAL_STORE_IDENTIFIER=disk98s2
TESTFLIGHT_BUILD_ROOT_PHYSICAL_WHOLE_DISK=disk98
/bin/cp -- "$ROOT_FIXTURE" "${ROOT_FIXTURE}.valid"
/bin/cp -- "$STORE_FIXTURE" "${STORE_FIXTURE}.valid"
/bin/cp -- "$DISK_FIXTURE" "${DISK_FIXTURE}.valid"

function verify_control_directory_identity() { return 0 }
function write_backing_root_info() {
  /bin/cp -- "$ROOT_FIXTURE" \
    "$TESTFLIGHT_CONTROL_DIRECTORY/backing-root-info.plist"
}
function write_backing_physical_store_info() {
  /bin/cp -- "$STORE_FIXTURE" \
    "$TESTFLIGHT_CONTROL_DIRECTORY/backing-physical-store-info.plist"
}
function write_backing_physical_disk_info() {
  /bin/cp -- "$DISK_FIXTURE" \
    "$TESTFLIGHT_CONTROL_DIRECTORY/backing-physical-disk-info.plist"
}

function reset_t7_fixtures() {
  /bin/cp -- "${ROOT_FIXTURE}.valid" "$ROOT_FIXTURE"
  /bin/cp -- "${STORE_FIXTURE}.valid" "$STORE_FIXTURE"
  /bin/cp -- "${DISK_FIXTURE}.valid" "$DISK_FIXTURE"
}
function expect_t7_identity_rejection() {
  if verify_backing_build_root_identity >/dev/null 2>&1; then
    print -u2 -r -- "mutated T7 identity passed: $1"
    exit 1
  fi
}

verify_backing_build_root_identity
reset_t7_fixtures
/usr/bin/plutil -replace VolumeUUID -string \
  00000000-0000-0000-0000-000000000000 "$ROOT_FIXTURE"
expect_t7_identity_rejection volume-uuid
reset_t7_fixtures
/usr/bin/plutil -insert APFSPhysicalStores.1 -xml \
  '<dict><key>APFSPhysicalStore</key><string>disk97s2</string></dict>' \
  "$ROOT_FIXTURE"
expect_t7_identity_rejection store-cardinality
reset_t7_fixtures
/usr/bin/plutil -replace DiskUUID -string \
  00000000-0000-0000-0000-000000000000 "$STORE_FIXTURE"
expect_t7_identity_rejection store-uuid
reset_t7_fixtures
/usr/bin/plutil -replace APFSContainerReference -string disk97 "$STORE_FIXTURE"
expect_t7_identity_rejection store-container-link
reset_t7_fixtures
/usr/bin/plutil -replace MediaName -string 'Unreviewed Disk' "$DISK_FIXTURE"
expect_t7_identity_rejection physical-media-name
reset_t7_fixtures
/usr/bin/plutil -replace Size -integer 0 "$DISK_FIXTURE"
expect_t7_identity_rejection physical-size
reset_t7_fixtures
/usr/bin/plutil -replace BusProtocol -string SATA "$ROOT_FIXTURE"
expect_t7_identity_rejection bus-protocol
reset_t7_fixtures
/usr/bin/plutil -replace Internal -bool YES "$DISK_FIXTURE"
expect_t7_identity_rejection external-media-flag
T7TEST

MANIFEST_ARCHIVE="$BEHAVIOR_ROOT/manifest.xcarchive"
MANIFEST_APP="$MANIFEST_ARCHIVE/Products/Applications/opensteamer.app"
MANIFEST_FRAMEWORK="$MANIFEST_APP/Frameworks/LiveKitWebRTC.framework"
mkdir -p "$MANIFEST_FRAMEWORK"
/bin/cp -- /usr/bin/true "$MANIFEST_APP/opensteamer"
/bin/cp -- /usr/bin/true "$MANIFEST_FRAMEWORK/LiveKitWebRTC"
print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.elamin.opensteamer</string>
<key>CFBundleExecutable</key><string>opensteamer</string>
</dict></plist>' >"$MANIFEST_APP/Info.plist"
print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.livekit.LiveKitWebRTC</string>
<key>CFBundleExecutable</key><string>LiveKitWebRTC</string>
</dict></plist>' >"$MANIFEST_FRAMEWORK/Info.plist"

WRAPPER_PATH="$BEHAVIOR_WRAPPER" MANIFEST_ARCHIVE="$MANIFEST_ARCHIVE" \
/bin/zsh <<'MANIFESTTEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM

function expect_manifest_rejection() {
  if verify_reviewed_archive_product_manifest "$MANIFEST_ARCHIVE" \
      >/dev/null 2>&1; then
    print -u2 -r -- "archive product manifest mutation unexpectedly passed: $1"
    exit 1
  fi
}

verify_reviewed_archive_product_manifest "$MANIFEST_ARCHIVE"
typeset products="$MANIFEST_ARCHIVE/Products"
typeset app="$products/Applications/opensteamer.app"

/bin/mkdir "$products/Applications/sibling.app"
expect_manifest_rejection sibling-app
/bin/rmdir "$products/Applications/sibling.app"

/bin/mkdir "$app/Unreviewed.appex"
expect_manifest_rejection app-extension
/bin/rmdir "$app/Unreviewed.appex"

/bin/mkdir "$app/Unreviewed.bundle"
expect_manifest_rejection resource-bundle
/bin/rmdir "$app/Unreviewed.bundle"

/bin/cp -- /usr/bin/true "$app/unreviewed.dylib"
expect_manifest_rejection dylib
/bin/rm -- "$app/unreviewed.dylib"

/bin/cp -- /usr/bin/true "$app/helper"
expect_manifest_rejection arbitrary-mach-o
/bin/rm -- "$app/helper"

/bin/ln -s Info.plist "$app/unreviewed-link"
expect_manifest_rejection symlink
/bin/rm -- "$app/unreviewed-link"

/bin/mkdir "$app/ExtraMetadata"
print -r -- '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' \
  >"$app/ExtraMetadata/Info.plist"
expect_manifest_rejection extra-info-plist
/bin/rm -- "$app/ExtraMetadata/Info.plist"
/bin/rmdir "$app/ExtraMetadata"

/bin/mkdir "$products/UnreviewedProduct"
/bin/cp -- /usr/bin/true "$products/UnreviewedProduct/helper"
expect_manifest_rejection product-tree-mach-o
/bin/rm -- "$products/UnreviewedProduct/helper"
/bin/rmdir "$products/UnreviewedProduct"

verify_reviewed_archive_product_manifest "$MANIFEST_ARCHIVE"
MANIFESTTEST

TREE_DIGEST_ROOT="$BEHAVIOR_ROOT/tree-digest"
mkdir -p "$TREE_DIGEST_ROOT/dSYMs"
print -r -- baseline-info >"$TREE_DIGEST_ROOT/Info.plist"
print -r -- baseline-symbols >"$TREE_DIGEST_ROOT/dSYMs/opensteamer.symbols"
WRAPPER_PATH="$BEHAVIOR_WRAPPER" TREE_DIGEST_ROOT="$TREE_DIGEST_ROOT" \
/bin/zsh <<'TREEDIGESTTEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM

typeset full_baseline
typeset excluded_baseline
full_baseline=$(filesystem_tree_sha256 "$TREE_DIGEST_ROOT")
excluded_baseline=$(filesystem_tree_sha256 "$TREE_DIGEST_ROOT" './Info.plist')
[[ "${#full_baseline}" == 64 && "${#excluded_baseline}" == 64 ]]

print -r -- changed-symbols >"$TREE_DIGEST_ROOT/dSYMs/opensteamer.symbols"
[[ "$(filesystem_tree_sha256 "$TREE_DIGEST_ROOT")" != "$full_baseline" \
    && "$(filesystem_tree_sha256 "$TREE_DIGEST_ROOT" './Info.plist')" \
      != "$excluded_baseline" ]]
print -r -- baseline-symbols >"$TREE_DIGEST_ROOT/dSYMs/opensteamer.symbols"
[[ "$(filesystem_tree_sha256 "$TREE_DIGEST_ROOT")" == "$full_baseline" ]]

print -r -- changed-info >"$TREE_DIGEST_ROOT/Info.plist"
[[ "$(filesystem_tree_sha256 "$TREE_DIGEST_ROOT")" != "$full_baseline" \
    && "$(filesystem_tree_sha256 "$TREE_DIGEST_ROOT" './Info.plist')" \
      == "$excluded_baseline" ]]
print -r -- baseline-info >"$TREE_DIGEST_ROOT/Info.plist"

/bin/ln -s Info.plist "$TREE_DIGEST_ROOT/unsafe-link"
if filesystem_tree_sha256 "$TREE_DIGEST_ROOT" >/dev/null 2>&1; then
  print -u2 -r -- 'symlink unexpectedly passed the full-tree digest'
  exit 1
fi
/bin/rm -- "$TREE_DIGEST_ROOT/unsafe-link"
/bin/ln "$TREE_DIGEST_ROOT/Info.plist" "$TREE_DIGEST_ROOT/hardlink"
if filesystem_tree_sha256 "$TREE_DIGEST_ROOT" >/dev/null 2>&1; then
  print -u2 -r -- 'hard link unexpectedly passed the full-tree digest'
  exit 1
fi
/bin/rm -- "$TREE_DIGEST_ROOT/hardlink"
[[ "$(filesystem_tree_sha256 "$TREE_DIGEST_ROOT")" == "$full_baseline" ]]
TREEDIGESTTEST

BASELINE_ARCHIVE_INFO="$BEHAVIOR_ROOT/archive-info-baseline.plist"
POSTUPLOAD_ARCHIVE_INFO="$BEHAVIOR_ROOT/archive-info-postupload.plist"
print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>ApplicationProperties</key><dict>
<key>ApplicationPath</key><string>Applications/opensteamer.app</string>
<key>Architectures</key><array><string>arm64</string></array>
<key>CFBundleIdentifier</key><string>com.elamin.opensteamer</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>61</string>
<key>SigningIdentity</key><string>Apple Development: Ahmed Elamin (92LVX32M8K)</string>
<key>Team</key><string>MSMG8CJLB3</string>
</dict>
<key>ArchiveVersion</key><integer>2</integer>
<key>CreationDate</key><date>2026-08-04T12:00:00Z</date>
<key>Name</key><string>opensteamerTestFlight</string>
<key>SchemeName</key><string>opensteamerTestFlight</string>
</dict></plist>' >"$BASELINE_ARCHIVE_INFO"
print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>ApplicationProperties</key><dict>
<key>ApplicationPath</key><string>Applications/opensteamer.app</string>
<key>Architectures</key><array><string>arm64</string></array>
<key>CFBundleIdentifier</key><string>com.elamin.opensteamer</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>61</string>
<key>SigningIdentity</key><string>Apple Development: Ahmed Elamin (92LVX32M8K)</string>
<key>Team</key><string>MSMG8CJLB3</string>
</dict>
<key>ArchiveVersion</key><integer>2</integer>
<key>CreationDate</key><date>2026-08-04T12:00:00Z</date>
<key>Distributions</key><array><dict>
<key>adamId</key><string>6797410161</string>
<key>identifier</key><string>082360c7-b3ee-45dc-9264-68604218c97e</string>
<key>certificateSHA1</key><string>CEB61B792A7A5848E9E797BB2E44EA2642611A6F</string>
<key>destination</key><string>upload</string>
<key>preparationEvent</key><dict><key>errors</key><array/><key>state</key><string>success</string></dict>
<key>task</key><string>distribute</string>
<key>teamID</key><string>MSMG8CJLB3</string>
<key>uploadDestination</key><string>App Store</string>
<key>uploadedBuildNumber</key><string>61</string>
<key>uploadEvent</key><dict><key>errors</key><array/><key>state</key><string>success</string></dict>
</dict></array>
<key>Name</key><string>opensteamerTestFlight</string>
<key>SchemeName</key><string>opensteamerTestFlight</string>
</dict></plist>' >"$POSTUPLOAD_ARCHIVE_INFO"
WRAPPER_PATH="$BEHAVIOR_WRAPPER" \
BASELINE_ARCHIVE_INFO="$BASELINE_ARCHIVE_INFO" \
POSTUPLOAD_ARCHIVE_INFO="$POSTUPLOAD_ARCHIVE_INFO" \
/bin/zsh <<'DISTRIBUTIONTEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM

function expect_distribution_rejection() {
  if verify_successful_upload_distribution_record "$POSTUPLOAD_ARCHIVE_INFO" \
      >/dev/null 2>&1; then
    print -u2 -r -- "distribution mutation unexpectedly passed: $1"
    exit 1
  fi
}

typeset baseline_semantics
baseline_semantics=$(archive_info_without_distributions_sha256 \
  "$BASELINE_ARCHIVE_INFO")
[[ "$baseline_semantics" == \
  "$(archive_info_without_distributions_sha256 "$POSTUPLOAD_ARCHIVE_INFO")" ]]
verify_successful_upload_distribution_record "$POSTUPLOAD_ARCHIVE_INFO"

/usr/bin/plutil -replace ApplicationProperties.ApplicationPath \
  -string Applications/AudioStreamer.app "$BASELINE_ARCHIVE_INFO"
if archive_info_without_distributions_sha256 "$BASELINE_ARCHIVE_INFO" \
    >/dev/null 2>&1; then
  print -u2 -r -- 'wrong archive application path passed reviewed semantics'
  exit 1
fi
/usr/bin/plutil -replace ApplicationProperties.ApplicationPath \
  -string Applications/opensteamer.app "$BASELINE_ARCHIVE_INFO"
/usr/bin/plutil -replace ApplicationProperties.Team \
  -string UNREVIEWED "$BASELINE_ARCHIVE_INFO"
if archive_info_without_distributions_sha256 "$BASELINE_ARCHIVE_INFO" \
    >/dev/null 2>&1; then
  print -u2 -r -- 'wrong archive team passed reviewed semantics'
  exit 1
fi
/usr/bin/plutil -replace ApplicationProperties.Team \
  -string MSMG8CJLB3 "$BASELINE_ARCHIVE_INFO"
[[ "$baseline_semantics" == \
  "$(archive_info_without_distributions_sha256 "$BASELINE_ARCHIVE_INFO")" ]]

/usr/bin/plutil -replace Distributions.0.adamId -string 0 \
  "$POSTUPLOAD_ARCHIVE_INFO"
expect_distribution_rejection apple-id
/usr/bin/plutil -replace Distributions.0.adamId -string 6797410161 \
  "$POSTUPLOAD_ARCHIVE_INFO"
/usr/bin/plutil -replace Distributions.0.identifier -string malformed \
  "$POSTUPLOAD_ARCHIVE_INFO"
expect_distribution_rejection identifier
/usr/bin/plutil -replace Distributions.0.identifier \
  -string 082360c7-b3ee-45dc-9264-68604218c97e \
  "$POSTUPLOAD_ARCHIVE_INFO"
/usr/bin/plutil -replace Distributions.0.uploadedBuildNumber -string 40 \
  "$POSTUPLOAD_ARCHIVE_INFO"
expect_distribution_rejection build
/usr/bin/plutil -replace Distributions.0.uploadedBuildNumber -string 61 \
  "$POSTUPLOAD_ARCHIVE_INFO"
/usr/bin/plutil -replace Distributions.0.certificateSHA1 \
  -string 0000000000000000000000000000000000000000 "$POSTUPLOAD_ARCHIVE_INFO"
expect_distribution_rejection certificate
/usr/bin/plutil -replace Distributions.0.certificateSHA1 \
  -string CEB61B792A7A5848E9E797BB2E44EA2642611A6F "$POSTUPLOAD_ARCHIVE_INFO"
/usr/bin/plutil -replace Distributions.0.uploadEvent.state -string failure \
  "$POSTUPLOAD_ARCHIVE_INFO"
expect_distribution_rejection state
/usr/bin/plutil -replace Distributions.0.uploadEvent.state -string success \
  "$POSTUPLOAD_ARCHIVE_INFO"
/usr/bin/plutil -insert Distributions.0.uploadEvent.errors.0 \
  -string rejected "$POSTUPLOAD_ARCHIVE_INFO"
expect_distribution_rejection errors
/usr/bin/plutil -remove Distributions.0.uploadEvent.errors.0 \
  "$POSTUPLOAD_ARCHIVE_INFO"

/usr/bin/plutil -replace SchemeName -string changed "$POSTUPLOAD_ARCHIVE_INFO"
[[ "$baseline_semantics" != \
  "$(archive_info_without_distributions_sha256 "$POSTUPLOAD_ARCHIVE_INFO")" ]]
/usr/bin/plutil -replace SchemeName -string opensteamerTestFlight \
  "$POSTUPLOAD_ARCHIVE_INFO"
/usr/bin/plutil -insert UnexpectedMetadata -string rejected \
  "$POSTUPLOAD_ARCHIVE_INFO"
if archive_info_without_distributions_sha256 "$POSTUPLOAD_ARCHIVE_INFO" \
    >/dev/null 2>&1; then
  print -u2 -r -- 'unexpected archive metadata passed semantic normalization'
  exit 1
fi
/usr/bin/plutil -remove UnexpectedMetadata "$POSTUPLOAD_ARCHIVE_INFO"
verify_successful_upload_distribution_record "$POSTUPLOAD_ARCHIVE_INFO"
DISTRIBUTIONTEST

for BUILD_OVERRIDE in \
    'DEVELOPER_DIR=/Applications/UnreviewedXcode.app/Contents/Developer' \
    'TOOLCHAINS=unreviewed' \
    'XCODE_XCCONFIG_FILE=/private/tmp/unreviewed.xcconfig' \
    'SDKROOT=/private/tmp/unreviewed-sdk' \
    'SYMROOT=/Applications/AudioStreamer Host.app' \
    'CACHE_ROOT=/Applications/AudioStreamer Host.app'; do
  if /usr/bin/env "$BUILD_OVERRIDE" WRAPPER_PATH="$BEHAVIOR_WRAPPER" \
      /bin/zsh -c 'source <(/usr/bin/sed "/^verify_static_contract$/,$d" "$WRAPPER_PATH"); trap - EXIT HUP INT QUIT TERM; reject_unsafe_build_environment' \
      >/dev/null 2>&1; then
    print -u2 -r -- "unsafe inherited build override passed: $BUILD_OVERRIDE"
    exit 1
  fi
done

DIGEST_BUILD_MOUNT="$BEHAVIOR_ROOT/digest-build-volume"
DIGEST_BUILD_SANDBOX="$DIGEST_BUILD_MOUNT/BuildSandbox"
DIGEST_RUN_TMP_PARENT="$DIGEST_BUILD_SANDBOX/run-tmp"
DIGEST_RUN_TMP="$DIGEST_RUN_TMP_PARENT/run.fixture"
/bin/mkdir -m 700 "$DIGEST_BUILD_MOUNT"
/bin/mkdir -m 700 "$DIGEST_BUILD_SANDBOX"
/bin/mkdir -m 700 "$DIGEST_RUN_TMP_PARENT"
/bin/mkdir -m 700 "$DIGEST_RUN_TMP"
WRAPPER_PATH="$BEHAVIOR_WRAPPER" \
DIGEST_BUILD_MOUNT="$DIGEST_BUILD_MOUNT" \
DIGEST_BUILD_SANDBOX="$DIGEST_BUILD_SANDBOX" \
DIGEST_RUN_TMP_PARENT="$DIGEST_RUN_TMP_PARENT" \
DIGEST_RUN_TMP="$DIGEST_RUN_TMP" \
/bin/zsh <<'DIGESTTEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM
function reject_unsafe_build_environment() { return 0 }
function verify_reviewed_xcode_toolchain_identity() { return 0 }
function verify_private_build_volume_identity() { return 0 }
function verify_xcode_sandbox_profile_identity() { return 0 }
function verify_package_dependency_contract() { return 0 }

TESTFLIGHT_BUILD_MOUNT_POINT=$DIGEST_BUILD_MOUNT
TESTFLIGHT_BUILD_SANDBOX_DIRECTORY=$DIGEST_BUILD_SANDBOX
TESTFLIGHT_BUILD_RUN_TMP_PARENT_DIRECTORY=$DIGEST_RUN_TMP_PARENT
TESTFLIGHT_BUILD_RUN_TMP_PARENT_IDENTITY=$(stat_identity \
  "$TESTFLIGHT_BUILD_RUN_TMP_PARENT_DIRECTORY")
TESTFLIGHT_BUILD_TMP_DIRECTORY=$DIGEST_RUN_TMP
TESTFLIGHT_BUILD_TMP_IDENTITY=$(stat_identity \
  "$TESTFLIGHT_BUILD_TMP_DIRECTORY")
TESTFLIGHT_DERIVED_DATA_DIRECTORY=$TESTFLIGHT_BUILD_SANDBOX_DIRECTORY/DerivedData
TESTFLIGHT_BUILD_PRODUCTS_DIRECTORY=$TESTFLIGHT_BUILD_SANDBOX_DIRECTORY/Products
TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY=$TESTFLIGHT_BUILD_SANDBOX_DIRECTORY/Intermediates
TESTFLIGHT_BUILD_DSTROOT_DIRECTORY=$TESTFLIGHT_DERIVED_DATA_DIRECTORY/Build/Intermediates.noindex/ArchiveIntermediates/$EXPECTED_SCHEME/InstallationBuildProductsLocation
typeset shared_cache_root=$TESTFLIGHT_BUILD_MOUNT_POINT/BuildCache/v1/shared
TESTFLIGHT_BUILD_PRECOMPILED_DIRECTORY=$shared_cache_root/SharedPrecompiledHeaders
TESTFLIGHT_BUILD_CACHE_DIRECTORY=$shared_cache_root/Caches
TESTFLIGHT_BUILD_MODULE_CACHE_DIRECTORY=$shared_cache_root/ModuleCache.noindex
TESTFLIGHT_BUILD_PACKAGE_CACHE_DIRECTORY=$shared_cache_root/PackageCache
TESTFLIGHT_BUILD_SOURCE_PACKAGES_DIRECTORY=$shared_cache_root/SourcePackages
TESTFLIGHT_XCODEBUILD_PINNED_ARGUMENTS=(one two)
TESTFLIGHT_XCODEBUILD_PINNED_ENVIRONMENT=('LC_ALL=C' 'PATH=/usr/bin:/bin')
TESTFLIGHT_XCODEBUILD_PINNED_ARGUMENTS_SHA256=$(xcodebuild_pinned_arguments_sha256)
TESTFLIGHT_XCODEBUILD_PINNED_ENVIRONMENT_SHA256=$(xcodebuild_pinned_environment_sha256)
verify_pinned_xcodebuild_filesystem_contract

TESTFLIGHT_XCODEBUILD_PINNED_ARGUMENTS+=(injected)
if verify_pinned_xcodebuild_filesystem_contract >/dev/null 2>&1; then
  print -u2 -r -- 'mutated pinned xcodebuild argument vector passed its digest'
  exit 1
fi
TESTFLIGHT_XCODEBUILD_PINNED_ARGUMENTS=(one two)
TESTFLIGHT_XCODEBUILD_PINNED_ENVIRONMENT+=(INJECTED=value)
if verify_pinned_xcodebuild_filesystem_contract >/dev/null 2>&1; then
  print -u2 -r -- 'mutated pinned xcodebuild environment passed its digest'
  exit 1
fi
DIGESTTEST

WRAPPER_PATH="$BEHAVIOR_WRAPPER" /bin/zsh <<'XCODECONTRACTTEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM

typeset -gi PINNED_CONTRACT_CALLS=0
function verify_pinned_xcodebuild_filesystem_contract() {
  (( PINNED_CONTRACT_CALLS += 1 ))
}
function verify_control_directory_identity() { return 0 }
function verify_archive_exec_destinations() { return 0 }
function verify_archive_destination_identity() { return 0 }
function verify_export_exec_destinations() { return 0 }
function verify_export_destination_identity() { return 0 }
function verify_xcodebuild_action_arguments() { return 0 }
typeset -gi DESTINATION_COMMAND_CALLS=0
function run_xcodebuild_command_for_destination_contract() {
  (( DESTINATION_COMMAND_CALLS += 1 ))
}

run_pinned_xcodebuild resolve ignored
run_pinned_xcodebuild settings ignored
run_pinned_xcodebuild archive ignored
run_pinned_xcodebuild export ignored
[[ "$PINNED_CONTRACT_CALLS" == 8 \
    && "$DESTINATION_COMMAND_CALLS" == 4 ]]
XCODECONTRACTTEST

WRAPPER_PATH="$BEHAVIOR_WRAPPER" /bin/zsh <<'DESTINATIONROUTINGTEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM

typeset -gi OUTER_SANDBOX_CALLS=0
typeset -ga OUTER_SANDBOX_CONTRACTS=()
function run_with_pinned_xcode_sandbox_profile() {
  (( OUTER_SANDBOX_CALLS += 1 ))
  OUTER_SANDBOX_CONTRACTS+=("$1")
  shift
  "$@"
}

run_xcodebuild_command_for_destination_contract resolve \
  /usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true
[[ "$OUTER_SANDBOX_CALLS" == 0 ]]

run_xcodebuild_command_for_destination_contract settings /usr/bin/true
run_xcodebuild_command_for_destination_contract archive /usr/bin/true
run_xcodebuild_command_for_destination_contract export /usr/bin/true
[[ "$OUTER_SANDBOX_CALLS" == 2 \
    && "${(j:|:)OUTER_SANDBOX_CONTRACTS}" == 'settings|archive' ]]
DESTINATIONROUTINGTEST

WRAPPER_PATH="$BEHAVIOR_WRAPPER" /bin/zsh <<'EXPORTACTIONARGUMENTSTEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM

TESTFLIGHT_ARCHIVE_PATH=/private/tmp/opensteamer-action-contract.xcarchive
TESTFLIGHT_EXPORT_DIRECTORY=/private/tmp/opensteamer-action-contract-export
function verify_xcodebuild_authentication_contract() { return 0 }
TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS=(
  -authenticationKeyPath /private/tmp/reviewed-test-key.p8
  -authenticationKeyID REVIEWEDKEY
  -authenticationKeyIssuerID 00000000-0000-0000-0000-000000000000
)
typeset -a EXPECTED_EXPORT_ARGUMENTS=(
  -exportArchive
  -archivePath "${TESTFLIGHT_ARCHIVE_PATH}"
  -exportOptionsPlist "${EXPORT_OPTIONS_PATH}"
  -exportPath "${TESTFLIGHT_EXPORT_DIRECTORY}"
  -allowProvisioningUpdates
  "${TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS[@]}"
)

verify_xcodebuild_action_arguments \
  export "${EXPECTED_EXPORT_ARGUMENTS[@]}"

function expect_action_argument_rejection() {
  local destination_contract=$1
  shift
  if verify_xcodebuild_action_arguments \
      "${destination_contract}" "$@" >/dev/null 2>&1; then
    print -u2 -r -- "action-argument mutation unexpectedly passed: $1"
    exit 1
  fi
}

expect_action_argument_rejection export \
  -exportArchive \
  -archivePath "${TESTFLIGHT_ARCHIVE_PATH}" \
  -exportOptionsPlist "${EXPORT_OPTIONS_PATH}" \
  -exportPath "${TESTFLIGHT_EXPORT_DIRECTORY}" \
  "${TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS[@]}"
expect_action_argument_rejection export \
  -exportArchive \
  -archivePath "${TESTFLIGHT_ARCHIVE_PATH}" \
  -exportOptionsPlist "${EXPORT_OPTIONS_PATH}" \
  -exportPath "${TESTFLIGHT_EXPORT_DIRECTORY}" \
  -allowProvisioningUpdates
expect_action_argument_rejection export \
  -archivePath "${TESTFLIGHT_ARCHIVE_PATH}" \
  -exportArchive \
  "${EXPECTED_EXPORT_ARGUMENTS[@]:3}"
expect_action_argument_rejection export \
  "${EXPECTED_EXPORT_ARGUMENTS[@]}" -unreviewedTrailingArgument
typeset -a WRONG_ARCHIVE_ARGUMENTS=("${EXPECTED_EXPORT_ARGUMENTS[@]}")
WRONG_ARCHIVE_ARGUMENTS[3]=/private/tmp/unreviewed.xcarchive
expect_action_argument_rejection export "${WRONG_ARCHIVE_ARGUMENTS[@]}"
expect_action_argument_rejection export \
  -DVTITunesConnectOutOfProcess NO "${EXPECTED_EXPORT_ARGUMENTS[@]}"
expect_action_argument_rejection resolve -DVTUnreviewedOverride
expect_action_argument_rejection settings -DVTUnreviewedOverride
expect_action_argument_rejection archive \
  -DVTITunesConnectOutOfProcessUnreviewed
EXPORTACTIONARGUMENTSTEST

WRAPPER_PATH="$BEHAVIOR_WRAPPER" /bin/zsh <<'ARCHIVEROOTSTEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM

TESTFLIGHT_CONTROL_DIRECTORY=/private/tmp/opensteamer-archive-roots-behavior/control
TESTFLIGHT_BUILD_SANDBOX_DIRECTORY=/private/tmp/opensteamer-archive-roots-behavior/BuildSandbox
TESTFLIGHT_DERIVED_DATA_DIRECTORY=$TESTFLIGHT_BUILD_SANDBOX_DIRECTORY/DerivedData
TESTFLIGHT_BUILD_PRODUCTS_DIRECTORY=$TESTFLIGHT_BUILD_SANDBOX_DIRECTORY/Products
TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY=$TESTFLIGHT_BUILD_SANDBOX_DIRECTORY/Intermediates
TESTFLIGHT_BUILD_DSTROOT_DIRECTORY=$TESTFLIGHT_DERIVED_DATA_DIRECTORY/Build/Intermediates.noindex/ArchiveIntermediates/$EXPECTED_SCHEME/InstallationBuildProductsLocation
TESTFLIGHT_BUILD_PRECOMPILED_DIRECTORY=$TESTFLIGHT_BUILD_SANDBOX_DIRECTORY/SharedPrecompiledHeaders
TESTFLIGHT_BUILD_CACHE_DIRECTORY=$TESTFLIGHT_BUILD_SANDBOX_DIRECTORY/Caches
TESTFLIGHT_BUILD_MODULE_CACHE_DIRECTORY=$TESTFLIGHT_BUILD_SANDBOX_DIRECTORY/ModuleCache.noindex
TESTFLIGHT_BUILD_PACKAGE_CACHE_DIRECTORY=$TESTFLIGHT_BUILD_SANDBOX_DIRECTORY/PackageCache
TESTFLIGHT_XCODEBUILD_PINNED_ARGUMENTS=(pinned)
typeset ROOTS_DSTROOT="${XCODE_TMP_ALIAS_ROOT}/${TESTFLIGHT_BUILD_DSTROOT_DIRECTORY#${PRIVATE_TEMPORARY_ROOT}/}"
typeset ROOTS_INSTALL_ROOT=$ROOTS_DSTROOT
typeset ROOTS_INSTALL_DIR=$ROOTS_DSTROOT/Applications
typeset ROOTS_TARGET_BUILD_DIR=$ROOTS_DSTROOT/Applications
typeset ROOTS_ARCHIVE_INTERMEDIATES="${XCODE_TMP_ALIAS_ROOT}/${TESTFLIGHT_DERIVED_DATA_DIRECTORY#${PRIVATE_TEMPORARY_ROOT}/}/Build/Intermediates.noindex/ArchiveIntermediates/$EXPECTED_SCHEME"
typeset ROOTS_BUILD_PRODUCTS_PATH=$ROOTS_ARCHIVE_INTERMEDIATES/BuildProductsPath
typeset ROOTS_BUILD_DIR=$ROOTS_BUILD_PRODUCTS_PATH
typeset ROOTS_SIGNATURE_METADATA_FOLDER_PATH=$ROOTS_BUILD_PRODUCTS_PATH/Signatures
typeset ROOTS_OBJROOT=$ROOTS_ARCHIVE_INTERMEDIATES/IntermediateBuildFilesPath
typeset WRONG_ROOTS_DSTROOT="${XCODE_TMP_ALIAS_ROOT}/${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY#${PRIVATE_TEMPORARY_ROOT}/}/DSTRoot"

function write_private_plist() { return 0 }
function plist_root_array_count() { print -r -- 1 }
function plist_typed_raw_value() {
  [[ "$2" == 0.target && "$3" == string ]] || return 1
  print -r -- opensteamer
}
function build_settings_entry_value() {
  local key=$3
  case "$key" in
    BUILD_DIR) print -r -- "$ROOTS_BUILD_DIR" ;;
    BUILD_ROOT|SYMROOT) print -r -- "$ROOTS_BUILD_PRODUCTS_PATH" ;;
    BUILT_PRODUCTS_DIR|CONFIGURATION_BUILD_DIR|DWARF_DSYM_FOLDER_PATH)
      print -r -- "$ROOTS_BUILD_PRODUCTS_PATH/$EXPECTED_CONFIGURATION-iphoneos"
      ;;
    SIGNATURE_METADATA_FOLDER_PATH)
      print -r -- "$ROOTS_SIGNATURE_METADATA_FOLDER_PATH"
      ;;
    SWIFT_STDLIB_TOOL_UNSIGNED_DESTINATION_DIR)
      print -r -- "$ROOTS_BUILD_PRODUCTS_PATH/SwiftSupport"
      ;;
    OBJROOT|PROJECT_TEMP_ROOT) print -r -- "$ROOTS_OBJROOT" ;;
    DSTROOT) print -r -- "$ROOTS_DSTROOT" ;;
    INSTALL_ROOT) print -r -- "$ROOTS_INSTALL_ROOT" ;;
    INSTALL_DIR) print -r -- "$ROOTS_INSTALL_DIR" ;;
    TARGET_BUILD_DIR) print -r -- "$ROOTS_TARGET_BUILD_DIR" ;;
    SHARED_PRECOMPS_DIR) print -r -- "$TESTFLIGHT_BUILD_PRECOMPILED_DIRECTORY" ;;
    CACHE_ROOT) print -r -- "$TESTFLIGHT_BUILD_CACHE_DIRECTORY" ;;
    MODULE_CACHE_DIR|CLANG_MODULE_CACHE_PATH|SWIFT_MODULE_CACHE_PATH)
      print -r -- "$TESTFLIGHT_BUILD_MODULE_CACHE_DIRECTORY"
      ;;
    PRODUCT_BUNDLE_IDENTIFIER) print -r -- "$EXPECTED_BUNDLE_IDENTIFIER" ;;
    CURRENT_PROJECT_VERSION) print -r -- "$EXPECTED_BUILD_NUMBER" ;;
    DEVELOPMENT_TEAM) print -r -- "$EXPECTED_TEAM_ID" ;;
    CODE_SIGN_STYLE) print -r -- Automatic ;;
    CODE_SIGN_IDENTITY) print -r -- 'Apple Development' ;;
    OPENSTEAMER_RENDEZVOUS_URL)
      print -r -- "$EXPECTED_RENDEZVOUS_URL"
      ;;
    *) print -r -- "$TESTFLIGHT_BUILD_SANDBOX_DIRECTORY/Derived/$key" ;;
  esac
}

verify_effective_archive_build_roots
ROOTS_BUILD_DIR=$WRONG_ROOTS_DSTROOT
if verify_effective_archive_build_roots >/dev/null 2>&1; then
  print -u2 -r -- 'split archive BUILD_DIR passed effective-root verification'
  exit 1
fi
ROOTS_BUILD_DIR=$ROOTS_BUILD_PRODUCTS_PATH
ROOTS_SIGNATURE_METADATA_FOLDER_PATH=$WRONG_ROOTS_DSTROOT/Signatures
if verify_effective_archive_build_roots >/dev/null 2>&1; then
  print -u2 -r -- 'split archive signature root passed effective-root verification'
  exit 1
fi
ROOTS_SIGNATURE_METADATA_FOLDER_PATH=$ROOTS_BUILD_PRODUCTS_PATH/Signatures
ROOTS_OBJROOT=$WRONG_ROOTS_DSTROOT
if verify_effective_archive_build_roots >/dev/null 2>&1; then
  print -u2 -r -- 'split archive OBJROOT passed effective-root verification'
  exit 1
fi
ROOTS_OBJROOT=$ROOTS_ARCHIVE_INTERMEDIATES/IntermediateBuildFilesPath
ROOTS_DSTROOT=$WRONG_ROOTS_DSTROOT
if verify_effective_archive_build_roots >/dev/null 2>&1; then
  print -u2 -r -- 'manually overridden archive DSTROOT passed effective-root verification'
  exit 1
fi
ROOTS_DSTROOT="${XCODE_TMP_ALIAS_ROOT}/${TESTFLIGHT_BUILD_DSTROOT_DIRECTORY#${PRIVATE_TEMPORARY_ROOT}/}"
ROOTS_INSTALL_ROOT=$WRONG_ROOTS_DSTROOT
if verify_effective_archive_build_roots >/dev/null 2>&1; then
  print -u2 -r -- 'manually overridden archive INSTALL_ROOT passed effective-root verification'
  exit 1
fi
ROOTS_INSTALL_ROOT=$ROOTS_DSTROOT
ROOTS_INSTALL_DIR=$WRONG_ROOTS_DSTROOT/Applications
if verify_effective_archive_build_roots >/dev/null 2>&1; then
  print -u2 -r -- 'manually overridden archive INSTALL_DIR passed effective-root verification'
  exit 1
fi
ROOTS_INSTALL_DIR=$ROOTS_DSTROOT/Applications
ROOTS_TARGET_BUILD_DIR=$WRONG_ROOTS_DSTROOT/Applications
if verify_effective_archive_build_roots >/dev/null 2>&1; then
  print -u2 -r -- 'manually overridden archive TARGET_BUILD_DIR passed effective-root verification'
  exit 1
fi
ARCHIVEROOTSTEST

PROFILE_CONTROL="$BEHAVIOR_ROOT/profile-control"
PROFILE_PATH="$PROFILE_CONTROL/xcodebuild.sb"
mkdir -m 700 "$PROFILE_CONTROL"
print -r -- '(version 1)
(allow default)' >"$PROFILE_PATH"
/bin/chmod 600 "$PROFILE_PATH"
WRAPPER_PATH="$BEHAVIOR_WRAPPER" PROFILE_CONTROL="$PROFILE_CONTROL" \
PROFILE_PATH="$PROFILE_PATH" /bin/zsh <<'PROFILETEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM
function verify_control_directory_identity() { return 0 }
TESTFLIGHT_CONTROL_DIRECTORY=$PROFILE_CONTROL
TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH=$PROFILE_PATH
TESTFLIGHT_XCODE_SANDBOX_PROFILE_IDENTITY=$(stat_identity "$PROFILE_PATH")
TESTFLIGHT_XCODE_SANDBOX_PROFILE_SHA256=$(sha256_file "$PROFILE_PATH")
sysopen -r -o nofollow -u TESTFLIGHT_XCODE_SANDBOX_PROFILE_FD "$PROFILE_PATH"
verify_xcode_sandbox_profile_identity
run_with_pinned_xcode_sandbox_profile settings /usr/bin/true
run_with_pinned_xcode_sandbox_profile archive /usr/bin/true
if run_with_pinned_xcode_sandbox_profile export /usr/bin/true; then
  print -u2 -r -- 'outer sandbox unexpectedly accepted the export action'
  exit 1
fi

print -r -- '(allow default)' >"$PROFILE_PATH"
if verify_xcode_sandbox_profile_identity >/dev/null 2>&1; then
  print -u2 -r -- 'mutated sandbox profile content passed its hash pin'
  exit 1
fi
print -r -- '(version 1)
(allow default)' >"$PROFILE_PATH"
TESTFLIGHT_XCODE_SANDBOX_PROFILE_SHA256=$(sha256_file "$PROFILE_PATH")
verify_xcode_sandbox_profile_identity

/bin/mv -- "$PROFILE_PATH" "${PROFILE_PATH}.moved"
/bin/ln -s "${PROFILE_PATH}.moved" "$PROFILE_PATH"
if verify_xcode_sandbox_profile_identity >/dev/null 2>&1; then
  print -u2 -r -- 'replaced sandbox profile inode passed its descriptor pin'
  exit 1
fi
/bin/rm -- "$PROFILE_PATH"
/bin/mv -- "${PROFILE_PATH}.moved" "$PROFILE_PATH"
exec {TESTFLIGHT_XCODE_SANDBOX_PROFILE_FD}>&-
PROFILETEST

FD_CONTROL="$BEHAVIOR_ROOT/fd-control"
mkdir -m 700 "$FD_CONTROL"
print -r -- 'repeatable-secret' >"$FD_CONTROL/image.key"
/bin/chmod 600 "$FD_CONTROL/image.key"
WRAPPER_PATH="$BEHAVIOR_WRAPPER" FD_CONTROL="$FD_CONTROL" \
/bin/zsh <<'FDCONSUMERTEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM
function verify_control_directory_identity() { return 0 }
function verify_build_key_identity() { return 0 }

TESTFLIGHT_CONTROL_DIRECTORY=$FD_CONTROL
TESTFLIGHT_BUILD_KEY_PATH="$FD_CONTROL/image.key"
TESTFLIGHT_BUILD_KEY_IDENTITY=$(stat_identity "$TESTFLIGHT_BUILD_KEY_PATH")
sysopen -r -o nofollow -u TESTFLIGHT_BUILD_KEY_FD "$TESTFLIGHT_BUILD_KEY_PATH"
typeset first
typeset second
first=$(run_with_pinned_build_key_stdin /bin/cat)
second=$(run_with_pinned_build_key_stdin /bin/cat)
[[ "$first" == repeatable-secret && "$second" == "$first" ]]

typeset snapshot="$FD_CONTROL/reused.plist"
write_private_plist "$snapshot" /usr/bin/printf '%s' \
  'a deliberately longer first snapshot'
write_private_plist "$snapshot" /usr/bin/printf '%s' short
[[ "$(<"$snapshot")" == short \
    && "$(/usr/bin/stat -f '%z' "$snapshot")" == 5 ]]
exec {TESTFLIGHT_BUILD_KEY_FD}>&-
FDCONSUMERTEST

WRAPPER_PATH="$BEHAVIOR_WRAPPER" \
CLEANUP_MARKER="$BEHAVIOR_ROOT/cleanup-tristate.log" \
/bin/zsh <<'CLEANUPTEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM

TESTFLIGHT_CONTROL_DIRECTORY=''
TESTFLIGHT_BUILD_IMAGE_CONTAINER=''
TESTFLIGHT_BUILD_IMAGE_PATH=''
TESTFLIGHT_BUILD_MOUNT_POINT=''
TESTFLIGHT_BUILD_ATTACH_ATTEMPTED=1
TESTFLIGHT_BUILD_ATTACHMENT_ACTIVE=0
typeset DISCOVERY_STATUS=2

function find_current_attachment_root_device() {
  print -r -- root >>"$CLEANUP_MARKER"
  return $DISCOVERY_STATUS
}
function current_attachment_is_absent() {
  print -r -- absence >>"$CLEANUP_MARKER"
  return 0
}

if cleanup_private_build_volume >/dev/null 2>&1; then
  print -u2 -r -- 'indeterminate attachment enumeration was accepted as absence'
  exit 1
fi
[[ "$(grep -c '^root$' "$CLEANUP_MARKER")" == 1 ]]
[[ "$(grep -c '^absence$' "$CLEANUP_MARKER" 2>/dev/null || true)" == 0 ]]

DISCOVERY_STATUS=1
TESTFLIGHT_BUILD_ATTACH_ATTEMPTED=1
TESTFLIGHT_BUILD_ATTACHMENT_ACTIVE=0
cleanup_private_build_volume
cleanup_private_build_volume
[[ "$(grep -c '^root$' "$CLEANUP_MARKER")" == 2 ]]
[[ "$(grep -c '^absence$' "$CLEANUP_MARKER" 2>/dev/null || true)" == 0 ]]
[[ $TESTFLIGHT_BUILD_ATTACH_ATTEMPTED == 0 && $TESTFLIGHT_BUILD_ATTACHMENT_ACTIVE == 0 ]]
CLEANUPTEST

LATE_CLEANUP_CONTROL="$BEHAVIOR_ROOT/late-cleanup-control"
LATE_CLEANUP_CONTAINER="$BEHAVIOR_ROOT/late-cleanup-container"
LATE_CLEANUP_IMAGE="$LATE_CLEANUP_CONTAINER/opensteamer-testflight-build.sparseimage"
LATE_CLEANUP_MARKER="$BEHAVIOR_ROOT/late-cleanup.log"
mkdir -p "$LATE_CLEANUP_CONTROL" "$LATE_CLEANUP_CONTAINER"
print -r -- image >"$LATE_CLEANUP_IMAGE"
WRAPPER_PATH="$BEHAVIOR_WRAPPER" \
LATE_CONTROL="$LATE_CLEANUP_CONTROL" \
LATE_CONTAINER="$LATE_CLEANUP_CONTAINER" \
LATE_IMAGE="$LATE_CLEANUP_IMAGE" \
LATE_MARKER="$LATE_CLEANUP_MARKER" \
/bin/zsh <<'LATECLEANUPTEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM

TESTFLIGHT_CONTROL_DIRECTORY=$LATE_CONTROL
TESTFLIGHT_CONTROL_DIRECTORY_IDENTITY=control
TESTFLIGHT_BUILD_IMAGE_CONTAINER=$LATE_CONTAINER
TESTFLIGHT_BUILD_IMAGE_CONTAINER_IDENTITY=container
TESTFLIGHT_BUILD_IMAGE_PATH=$LATE_IMAGE
TESTFLIGHT_BUILD_IMAGE_IDENTITY=image
TESTFLIGHT_BUILD_CREATE_ATTEMPTED=1
TESTFLIGHT_BUILD_IMAGE_CREATED=1
TESTFLIGHT_BUILD_ATTACH_ATTEMPTED=0
TESTFLIGHT_BUILD_ATTACHMENT_ACTIVE=0
TESTFLIGHT_BUILD_MOUNT_POINT=''
TESTFLIGHT_BUILD_MOUNT_POINT_UNDERLAY_IDENTITY=''
TESTFLIGHT_BUILD_KEY_PATH=''
TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH=''

function verify_control_directory_identity() {
  [[ -d "$TESTFLIGHT_CONTROL_DIRECTORY" ]]
}
function verify_image_container_identity() {
  print -r -- container >>"$LATE_MARKER"
  [[ -d "$TESTFLIGHT_BUILD_IMAGE_CONTAINER" ]]
}
function verify_image_storage_identity() {
  [[ -f "$TESTFLIGHT_BUILD_IMAGE_PATH" ]]
}
function current_attachment_is_absent() { return 0 }
functions[production_remove_exact_private_file]=$functions[remove_exact_private_file]
typeset -i REMOVE_CALLS=0
function remove_exact_private_file() {
  (( REMOVE_CALLS += 1 ))
  (( REMOVE_CALLS != 1 )) || return 1
  production_remove_exact_private_file "$@"
}

if cleanup_private_build_volume_signal_masked >/dev/null 2>&1; then
  print -u2 -r -- 'injected late cleanup failure unexpectedly passed'
  exit 1
fi
[[ -f "$LATE_IMAGE" \
    && -d "$LATE_CONTAINER" \
    && -z "$TESTFLIGHT_BUILD_IMAGE_PATH" \
    && -z "$TESTFLIGHT_BUILD_IMAGE_CONTAINER" \
    && "$TESTFLIGHT_BUILD_IMAGE_CREATED" == 0 \
    && "$TESTFLIGHT_BUILD_CREATE_ATTEMPTED" == 0 \
    && "$RELEASE_SCRATCH_CLEANUP_RUNNING" == 0 \
    && "$RELEASE_SCRATCH_CLEANUP_COMPLETE" == 0 ]]
cleanup_private_build_volume_signal_masked
[[ ! -e "$LATE_CONTROL" \
    && -f "$LATE_IMAGE" \
    && -d "$LATE_CONTAINER" \
    && -z "$TESTFLIGHT_CONTROL_DIRECTORY" \
    && "$RELEASE_SCRATCH_CLEANUP_RUNNING" == 0 \
    && "$RELEASE_SCRATCH_CLEANUP_COMPLETE" == 1 ]]
typeset calls_after_success=$REMOVE_CALLS
cleanup_private_build_volume_signal_masked
[[ "$REMOVE_CALLS" == "$calls_after_success" ]]
[[ "$(grep -c '^container$' "$LATE_MARKER")" == 2 ]]
LATECLEANUPTEST

IMAGE_INFO_CONTROL="$BEHAVIOR_ROOT/image-info-control"
IMAGE_INFO_FIXTURE="$BEHAVIOR_ROOT/image-info.plist"
/bin/mkdir -m 700 "$IMAGE_INFO_CONTROL"
print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>Format</key><string>SPRS</string>
<key>Properties</key><dict><key>Encrypted</key><true/></dict>
<key>Backing Store Information</key><dict>
<key>Class Name</key><string>CEncryptedEncoding</string>
<key>Encryption</key><string>AES-256</string>
<key>Backing Store Information</key><dict>
<key>Class Name</key><string>CBSDBackingStore</string>
</dict></dict>
<key>Size Information</key><dict>
<key>Total Bytes</key><integer>68719476736</integer>
<key>Sector Count</key><integer>134217728</integer>
</dict>
<key>partitions</key><dict><key>partitions</key><array><dict>
<key>partition-hint</key><string>Apple_APFS</string>
<key>partition-UUID</key><string>11111111-2222-3333-4444-555555555555</string>
</dict></array></dict>
</dict></plist>' >"$IMAGE_INFO_FIXTURE"
WRAPPER_PATH="$BEHAVIOR_WRAPPER" \
IMAGE_INFO_CONTROL="$IMAGE_INFO_CONTROL" \
IMAGE_INFO_FIXTURE="$IMAGE_INFO_FIXTURE" \
/bin/zsh <<'IMAGEINFOTEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM

function verify_image_storage_identity() { return 0 }
function verify_build_key_identity() { return 0 }
function write_private_plist() {
  local destination=$1
  /bin/cp -- "$IMAGE_INFO_FIXTURE" "$destination"
  /bin/chmod 600 "$destination"
}
function expect_image_info_rejection() {
  if write_and_verify_created_image_info >/dev/null 2>&1; then
    print -u2 -r -- "image-info mutation unexpectedly passed: $1"
    exit 1
  fi
}

TESTFLIGHT_CONTROL_DIRECTORY=$IMAGE_INFO_CONTROL
TESTFLIGHT_BUILD_IMAGE_PATH=$IMAGE_INFO_CONTROL/fake.sparseimage
write_and_verify_created_image_info
[[ "$TESTFLIGHT_BUILD_IMAGE_PARTITION_UUID" \
    == '11111111-2222-3333-4444-555555555555' ]]

/usr/bin/plutil -replace 'Backing Store Information.Class Name' \
  -string CUnencryptedEncoding "$IMAGE_INFO_FIXTURE"
expect_image_info_rejection outer-backing-class
/usr/bin/plutil -replace 'Backing Store Information.Class Name' \
  -string CEncryptedEncoding "$IMAGE_INFO_FIXTURE"
/usr/bin/plutil -replace \
  'Backing Store Information.Backing Store Information.Class Name' \
  -string CUnknownBackingStore "$IMAGE_INFO_FIXTURE"
expect_image_info_rejection nested-backing-class
/usr/bin/plutil -replace \
  'Backing Store Information.Backing Store Information.Class Name' \
  -string CBSDBackingStore "$IMAGE_INFO_FIXTURE"
/usr/bin/plutil -replace 'Backing Store Information.Encryption' \
  -string AES-128 "$IMAGE_INFO_FIXTURE"
expect_image_info_rejection encryption
/usr/bin/plutil -replace 'Backing Store Information.Encryption' \
  -string AES-256 "$IMAGE_INFO_FIXTURE"
/usr/bin/plutil -replace 'Size Information.Total Bytes' \
  -integer 34359738368 "$IMAGE_INFO_FIXTURE"
expect_image_info_rejection total-bytes
/usr/bin/plutil -replace 'Size Information.Total Bytes' \
  -integer 68719476736 "$IMAGE_INFO_FIXTURE"
/usr/bin/plutil -replace 'Size Information.Sector Count' \
  -integer 67108864 "$IMAGE_INFO_FIXTURE"
expect_image_info_rejection sector-count
/usr/bin/plutil -replace 'Size Information.Sector Count' \
  -integer 134217728 "$IMAGE_INFO_FIXTURE"
/usr/bin/plutil -insert partitions.partitions.1 -xml \
  '<dict><key>partition-hint</key><string>Apple_APFS</string><key>partition-UUID</key><string>AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE</string></dict>' \
  "$IMAGE_INFO_FIXTURE"
expect_image_info_rejection duplicate-apfs-partition
/usr/bin/plutil -remove partitions.partitions.1 "$IMAGE_INFO_FIXTURE"
write_and_verify_created_image_info
IMAGEINFOTEST

STALE_RECOVERY_ROOT="$BEHAVIOR_ROOT/stale-recovery-root"
STALE_RECOVERY_MOUNT="$STALE_RECOVERY_ROOT/mount"
STALE_RECOVERY_MARKER="$BEHAVIOR_ROOT/stale-recovery-marker"
/bin/mkdir -m 700 "$STALE_RECOVERY_ROOT"
/bin/mkdir -m 700 "$STALE_RECOVERY_MOUNT"
print -r -- busy >"$STALE_RECOVERY_MOUNT/busy"
WRAPPER_PATH="$BEHAVIOR_WRAPPER" \
STALE_RECOVERY_ROOT="$STALE_RECOVERY_ROOT" \
STALE_RECOVERY_MOUNT="$STALE_RECOVERY_MOUNT" \
STALE_RECOVERY_MARKER="$STALE_RECOVERY_MARKER" \
/bin/zsh <<'STALERECOVERYTEST'
source <(/usr/bin/sed \
  -e 's|^readonly TESTFLIGHT_BUILD_MOUNT_ROOT=.*$|readonly TESTFLIGHT_BUILD_MOUNT_ROOT="${STALE_RECOVERY_ROOT}"|' \
  -e 's|/usr/bin/hdiutil detach "${TESTFLIGHT_IMAGE_DEVICE}"|mock_hdiutil_detach "${TESTFLIGHT_IMAGE_DEVICE}"|g' \
  -e '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM

function verify_build_cache_lock_identity() { return 0 }
function verify_image_storage_identity() { return 0 }
function find_current_attachment_record() {
  print -r -- '/dev/disk41|/dev/disk41s2|/dev/disk41s1|true|true'
}
function verify_hdiutil_attachment_identity() { return 0 }
function current_attachment_is_absent() { return 0 }
function remove_exact_stale_build_mount_underlay() {
  print -r -- underlay >>"$STALE_RECOVERY_MARKER"
}
function mock_hdiutil_detach() {
  [[ "$1" == /dev/disk41 ]] || return 1
  print -r -- "detach:$1" >>"$STALE_RECOVERY_MARKER"
}

TESTFLIGHT_BUILD_CACHE_INITIALIZE_MODE=0
typeset -i stale_busy_fd=-1
sysopen -r -o nofollow -u stale_busy_fd "$STALE_RECOVERY_MOUNT/busy"
if recover_stale_persistent_build_cache_state >/dev/null 2>&1; then
  print -u2 -r -- 'busy stale attachment unexpectedly detached'
  exit 1
fi
[[ ! -e "$STALE_RECOVERY_MARKER" ]]
exec {stale_busy_fd}>&-

recover_stale_persistent_build_cache_state >/dev/null
[[ "$(/usr/bin/sed -n '1p' "$STALE_RECOVERY_MARKER")" \
      == 'detach:/dev/disk41' \
    && "$(/usr/bin/sed -n '2p' "$STALE_RECOVERY_MARKER")" == underlay \
    && "$(/usr/bin/wc -l <"$STALE_RECOVERY_MARKER" | /usr/bin/tr -d ' ')" == 2 ]]
STALERECOVERYTEST

WORKSPACE_ATOMIC_PARENT="$BEHAVIOR_ROOT/workspace-atomic-parent"
/bin/mkdir -m 700 "$WORKSPACE_ATOMIC_PARENT"
WRAPPER_PATH="$BEHAVIOR_WRAPPER" \
WORKSPACE_ATOMIC_PARENT="$WORKSPACE_ATOMIC_PARENT" \
/bin/zsh <<'WORKSPACEATOMICTEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM

TESTFLIGHT_BUILD_CACHE_INITIALIZE_MODE=0
typeset -i WORKSPACE_LOCK_CHECKS=0
function verify_build_cache_lock_identity() {
  (( WORKSPACE_LOCK_CHECKS += 1 ))
  return 0
}
function verify_persistent_build_cache_contract() { return 0 }
function select_workspace_key() {
  local key=$1
  local workspace="$WORKSPACE_ATOMIC_PARENT/$key"
  TESTFLIGHT_BUILD_WORKSPACE_KEY=$key
  TESTFLIGHT_BUILD_SANDBOX_DIRECTORY=$workspace
  TESTFLIGHT_BUILD_RUN_TMP_PARENT_DIRECTORY="$workspace/run-tmp"
  TESTFLIGHT_DERIVED_DATA_DIRECTORY="$workspace/DerivedData"
  TESTFLIGHT_BUILD_PRODUCTS_DIRECTORY="$workspace/Products"
  TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY="$workspace/Intermediates"
}
function expect_workspace_rejection() {
  local label=$1
  local key=$2
  select_workspace_key "$key"
  if initialize_or_provision_workspace_directory \
      "$WORKSPACE_ATOMIC_PARENT/$key" "$WORKSPACE_ATOMIC_PARENT" \
      >/dev/null 2>&1; then
    print -u2 -r -- \
      "malformed checkout workspace unexpectedly passed: ${label}"
    exit 1
  fi
}

typeset first_key=1111111111111111111111111111111111111111111111111111111111111111
typeset second_key=2222222222222222222222222222222222222222222222222222222222222222
typeset first_workspace="$WORKSPACE_ATOMIC_PARENT/$first_key"
typeset second_workspace="$WORKSPACE_ATOMIC_PARENT/$second_key"
typeset second_pending="$WORKSPACE_ATOMIC_PARENT/.workspace-${second_key}.pending"
typeset parent_identity
parent_identity=$(stat_identity "$WORKSPACE_ATOMIC_PARENT")

# A previously unseen second checkout is published with only the exact four
# empty private children; the first checkout remains untouched.
select_workspace_key "$first_key"
initialize_or_provision_workspace_directory \
  "$first_workspace" "$WORKSPACE_ATOMIC_PARENT"
typeset first_identity
first_identity=$(stat_identity "$first_workspace")
typeset -i lock_checks_before=$WORKSPACE_LOCK_CHECKS
select_workspace_key "$second_key"
initialize_or_provision_workspace_directory \
  "$second_workspace" "$WORKSPACE_ATOMIC_PARENT"
(( WORKSPACE_LOCK_CHECKS - lock_checks_before == 4 ))
typeset second_identity
second_identity=$(stat_identity "$second_workspace")
[[ "$TESTFLIGHT_BUILD_SANDBOX_IDENTITY" == "$second_identity" \
    && "$TESTFLIGHT_BUILD_EXPECTED_RUN_TMP_PARENT_IDENTITY" \
      == "$(stat_identity "$second_workspace/run-tmp")" \
    && "$TESTFLIGHT_BUILD_EXPECTED_DERIVED_DATA_IDENTITY" \
      == "$(stat_identity "$second_workspace/DerivedData")" \
    && "$TESTFLIGHT_BUILD_EXPECTED_PRODUCTS_IDENTITY" \
      == "$(stat_identity "$second_workspace/Products")" \
    && "$TESTFLIGHT_BUILD_EXPECTED_INTERMEDIATES_IDENTITY" \
      == "$(stat_identity "$second_workspace/Intermediates")" \
    && "$(stat_identity "$first_workspace")" == "$first_identity" \
    && ! -e "$second_pending" \
    && ! -L "$second_pending" ]]
workspace_staging_directory_is_exact_and_empty "$second_workspace"
typeset -a published_workspaces=("$WORKSPACE_ATOMIC_PARENT"/*(ND))
(( ${#published_workspaces[@]} == 2 ))

# Revalidating the same checkout preserves the workspace and every child inode.
typeset -a rerun_nodes=(
  "$second_workspace"
  "$second_workspace/run-tmp"
  "$second_workspace/DerivedData"
  "$second_workspace/Products"
  "$second_workspace/Intermediates"
)
typeset -a rerun_identities=()
typeset node
for node in "${rerun_nodes[@]}"; do
  rerun_identities+=("$(stat_identity "$node")")
done
lock_checks_before=$WORKSPACE_LOCK_CHECKS
initialize_or_provision_workspace_directory \
  "$second_workspace" "$WORKSPACE_ATOMIC_PARENT"
(( WORKSPACE_LOCK_CHECKS - lock_checks_before == 2 ))
[[ "$TESTFLIGHT_BUILD_SANDBOX_IDENTITY" == "$second_identity" \
    && "$TESTFLIGHT_BUILD_EXPECTED_RUN_TMP_PARENT_IDENTITY" \
      == "$rerun_identities[2]" \
    && "$TESTFLIGHT_BUILD_EXPECTED_DERIVED_DATA_IDENTITY" \
      == "$rerun_identities[3]" \
    && "$TESTFLIGHT_BUILD_EXPECTED_PRODUCTS_IDENTITY" \
      == "$rerun_identities[4]" \
    && "$TESTFLIGHT_BUILD_EXPECTED_INTERMEDIATES_IDENTITY" \
      == "$rerun_identities[5]" ]]
typeset -i node_index=1
for node in "${rerun_nodes[@]}"; do
  [[ "$(stat_identity "$node")" == "$rerun_identities[$node_index]" ]]
  (( node_index += 1 ))
done

# Replacing any captured child before its downstream consumer runs is rejected.
typeset child_record
typeset child_path
typeset child_identity
typeset child_label
typeset child_remainder
typeset held_child
for child_record in \
    "$second_workspace/DerivedData|$TESTFLIGHT_BUILD_EXPECTED_DERIVED_DATA_IDENTITY|derived-data" \
    "$second_workspace/Products|$TESTFLIGHT_BUILD_EXPECTED_PRODUCTS_IDENTITY|products" \
    "$second_workspace/Intermediates|$TESTFLIGHT_BUILD_EXPECTED_INTERMEDIATES_IDENTITY|intermediates"; do
  child_path=${child_record%%|*}
  child_remainder=${child_record#*|}
  child_identity=${child_remainder%%|*}
  child_label=${child_remainder#*|}
  held_child="${WORKSPACE_ATOMIC_PARENT:h}/held-${child_label}"
  /bin/mv -- "$child_path" "$held_child"
  /bin/mkdir -m 700 "$child_path"
  TESTFLIGHT_PINNED_BUILD_DIRECTORIES=()
  if initialize_or_pin_cache_directory \
      "$child_path" "$second_workspace" "$child_identity" \
      >/dev/null 2>&1; then
    print -u2 -r -- \
      "replacement workspace child unexpectedly pinned: ${child_label}"
    exit 1
  fi
  /bin/rmdir -- "$child_path"
  /bin/mv -- "$held_child" "$child_path"
  [[ "$(stat_identity "$child_path")" == "$child_identity" ]]
done

typeset held_run_tmp="${WORKSPACE_ATOMIC_PARENT:h}/held-run-tmp"
/bin/mv -- "$second_workspace/run-tmp" "$held_run_tmp"
/bin/mkdir -m 700 "$second_workspace/run-tmp"
if initialize_or_migrate_run_tmp_parent_directory \
    "$second_workspace/run-tmp" "$second_workspace" "$second_identity" \
    "$TESTFLIGHT_BUILD_EXPECTED_RUN_TMP_PARENT_IDENTITY" \
    >/dev/null 2>&1; then
  print -u2 -r -- 'replacement workspace run-TMP parent unexpectedly passed'
  exit 1
fi
/bin/rmdir -- "$second_workspace/run-tmp"
/bin/mv -- "$held_run_tmp" "$second_workspace/run-tmp"
[[ "$(stat_identity "$second_workspace/run-tmp")" \
    == "$TESTFLIGHT_BUILD_EXPECTED_RUN_TMP_PARENT_IDENTITY" ]]

# An interrupted pending directory may contain a safe subset of the exact
# children. Completion preserves those inodes and publishes the pending inode.
typeset partial_key=3333333333333333333333333333333333333333333333333333333333333333
typeset partial_workspace="$WORKSPACE_ATOMIC_PARENT/$partial_key"
typeset partial_pending="$WORKSPACE_ATOMIC_PARENT/.workspace-${partial_key}.pending"
/bin/mkdir -m 700 "$partial_pending"
/bin/mkdir -m 700 "$partial_pending/DerivedData"
/bin/mkdir -m 700 "$partial_pending/run-tmp"
typeset partial_pending_identity
typeset partial_derived_data_identity
typeset partial_run_tmp_identity
partial_pending_identity=$(stat_identity "$partial_pending")
partial_derived_data_identity=$(stat_identity "$partial_pending/DerivedData")
partial_run_tmp_identity=$(stat_identity "$partial_pending/run-tmp")
lock_checks_before=$WORKSPACE_LOCK_CHECKS
select_workspace_key "$partial_key"
initialize_or_provision_workspace_directory \
  "$partial_workspace" "$WORKSPACE_ATOMIC_PARENT"
(( WORKSPACE_LOCK_CHECKS - lock_checks_before == 3 ))
[[ ! -e "$partial_pending" \
    && ! -L "$partial_pending" \
    && "$TESTFLIGHT_BUILD_SANDBOX_IDENTITY" \
      == "$partial_pending_identity" \
    && "$TESTFLIGHT_BUILD_EXPECTED_RUN_TMP_PARENT_IDENTITY" \
      == "$partial_run_tmp_identity" \
    && "$TESTFLIGHT_BUILD_EXPECTED_DERIVED_DATA_IDENTITY" \
      == "$partial_derived_data_identity" \
    && "$TESTFLIGHT_BUILD_EXPECTED_PRODUCTS_IDENTITY" \
      == "$(stat_identity "$partial_workspace/Products")" \
    && "$TESTFLIGHT_BUILD_EXPECTED_INTERMEDIATES_IDENTITY" \
      == "$(stat_identity "$partial_workspace/Intermediates")" \
    && "$(stat_identity "$partial_workspace")" \
      == "$partial_pending_identity" \
    && "$(stat_identity "$partial_workspace/DerivedData")" \
      == "$partial_derived_data_identity" \
    && "$(stat_identity "$partial_workspace/run-tmp")" \
      == "$partial_run_tmp_identity" ]]
workspace_staging_directory_is_exact_and_empty "$partial_workspace"

# Linked, public, nonempty, unexpected, and incomplete states all fail closed.
typeset symlink_key=4444444444444444444444444444444444444444444444444444444444444444
typeset symlink_pending="$WORKSPACE_ATOMIC_PARENT/.workspace-${symlink_key}.pending"
/bin/mkdir -m 700 "$symlink_pending"
/bin/ln -s "$first_workspace/DerivedData" "$symlink_pending/DerivedData"
expect_workspace_rejection symlink-child "$symlink_key"

typeset wrong_mode_key=5555555555555555555555555555555555555555555555555555555555555555
typeset wrong_mode_pending="$WORKSPACE_ATOMIC_PARENT/.workspace-${wrong_mode_key}.pending"
/bin/mkdir -m 700 "$wrong_mode_pending"
/bin/mkdir -m 755 "$wrong_mode_pending/DerivedData"
expect_workspace_rejection wrong-mode-child "$wrong_mode_key"

typeset nonempty_key=6666666666666666666666666666666666666666666666666666666666666666
typeset nonempty_pending="$WORKSPACE_ATOMIC_PARENT/.workspace-${nonempty_key}.pending"
/bin/mkdir -m 700 "$nonempty_pending"
/bin/mkdir -m 700 "$nonempty_pending/DerivedData"
print -r -- occupied >"$nonempty_pending/DerivedData/unreviewed"
expect_workspace_rejection nonempty-child "$nonempty_key"

typeset unexpected_key=7777777777777777777777777777777777777777777777777777777777777777
typeset unexpected_pending="$WORKSPACE_ATOMIC_PARENT/.workspace-${unexpected_key}.pending"
/bin/mkdir -m 700 "$unexpected_pending"
/bin/mkdir -m 700 "$unexpected_pending/Unreviewed"
expect_workspace_rejection unexpected-child "$unexpected_key"

typeset missing_key=8888888888888888888888888888888888888888888888888888888888888888
typeset missing_workspace="$WORKSPACE_ATOMIC_PARENT/$missing_key"
/bin/mkdir -m 700 "$missing_workspace"
/bin/mkdir -m 700 "$missing_workspace/DerivedData"
/bin/mkdir -m 700 "$missing_workspace/Products"
/bin/mkdir -m 700 "$missing_workspace/run-tmp"
expect_workspace_rejection missing-existing-child "$missing_key"

# Inject a target after the provisioner's final absence check but at the
# exclusive-publisher boundary. The appeared target and pending source remain
# distinct, with neither object replaced or nested beneath the other.
typeset appearance_key=9999999999999999999999999999999999999999999999999999999999999999
typeset appearance_workspace="$WORKSPACE_ATOMIC_PARENT/$appearance_key"
typeset appearance_pending="$WORKSPACE_ATOMIC_PARENT/.workspace-${appearance_key}.pending"
typeset appearance_target_identity=''
typeset appearance_pending_identity=''
function publish_workspace_directory_exclusively() {
  [[ "$2" == "$appearance_workspace" ]] || return 1
  appearance_pending_identity=$(stat_identity "$1") || return 1
  print -r -- appeared >"$2" || return 1
  /bin/chmod 600 "$2" || return 1
  appearance_target_identity=$(stat_identity "$2") || return 1
  return 1
}
lock_checks_before=$WORKSPACE_LOCK_CHECKS
expect_workspace_rejection target-appearance "$appearance_key"
(( WORKSPACE_LOCK_CHECKS - lock_checks_before == 3 ))
[[ -z "$TESTFLIGHT_BUILD_SANDBOX_IDENTITY" \
    && -f "$appearance_workspace" \
    && ! -L "$appearance_workspace" \
    && "$(stat_identity "$appearance_workspace")" \
      == "$appearance_target_identity" \
    && -d "$appearance_pending" \
    && ! -L "$appearance_pending" \
    && "$(stat_identity "$appearance_pending")" \
      == "$appearance_pending_identity" \
    && ! "$appearance_workspace" -ef "$appearance_pending" ]]
workspace_staging_directory_is_exact_and_empty "$appearance_pending"
[[ "$(stat_identity "$WORKSPACE_ATOMIC_PARENT")" == "$parent_identity" ]]
WORKSPACEATOMICTEST

RUN_TMP_MIGRATION_PARENT="$BEHAVIOR_ROOT/run-tmp-migration-workspace"
RUN_TMP_MIGRATION_TARGET="$RUN_TMP_MIGRATION_PARENT/run-tmp"
/bin/mkdir -m 700 "$RUN_TMP_MIGRATION_PARENT"
WRAPPER_PATH="$BEHAVIOR_WRAPPER" \
RUN_TMP_MIGRATION_PARENT="$RUN_TMP_MIGRATION_PARENT" \
RUN_TMP_MIGRATION_TARGET="$RUN_TMP_MIGRATION_TARGET" \
/bin/zsh <<'RUNTMPMIGRATIONTEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM

TESTFLIGHT_BUILD_CACHE_INITIALIZE_MODE=0
function verify_build_cache_lock_identity() { return 0 }
function verify_persistent_build_cache_contract() { return 0 }
typeset RUN_TMP_MIGRATION_PARENT_IDENTITY
RUN_TMP_MIGRATION_PARENT_IDENTITY=$(stat_identity "$RUN_TMP_MIGRATION_PARENT")
initialize_or_migrate_run_tmp_parent_directory \
  "$RUN_TMP_MIGRATION_TARGET" "$RUN_TMP_MIGRATION_PARENT" \
  "$RUN_TMP_MIGRATION_PARENT_IDENTITY" ''
require_owned_private_directory "$RUN_TMP_MIGRATION_TARGET"
/bin/rmdir -- "$RUN_TMP_MIGRATION_TARGET"

/bin/ln -s "$RUN_TMP_MIGRATION_PARENT" "$RUN_TMP_MIGRATION_TARGET"
if initialize_or_migrate_run_tmp_parent_directory \
    "$RUN_TMP_MIGRATION_TARGET" "$RUN_TMP_MIGRATION_PARENT" \
    "$RUN_TMP_MIGRATION_PARENT_IDENTITY" '' \
    >/dev/null 2>&1; then
  print -u2 -r -- 'symlink run-TMP migration target unexpectedly passed'
  exit 1
fi
/bin/rm -- "$RUN_TMP_MIGRATION_TARGET"

/bin/mkdir -m 755 "$RUN_TMP_MIGRATION_TARGET"
if initialize_or_migrate_run_tmp_parent_directory \
    "$RUN_TMP_MIGRATION_TARGET" "$RUN_TMP_MIGRATION_PARENT" \
    "$RUN_TMP_MIGRATION_PARENT_IDENTITY" '' \
    >/dev/null 2>&1; then
  print -u2 -r -- 'public run-TMP migration target unexpectedly passed'
  exit 1
fi
/bin/rmdir -- "$RUN_TMP_MIGRATION_TARGET"
/bin/rmdir -- "$RUN_TMP_MIGRATION_PARENT"
RUNTMPMIGRATIONTEST

RUN_TMP_SANDBOX="$BEHAVIOR_ROOT/run-tmp-sandbox"
RUN_TMP_PARENT="$RUN_TMP_SANDBOX/run-tmp"
RUN_TMP_CURRENT="$RUN_TMP_PARENT/run.current"
RUN_TMP_SIBLING="$RUN_TMP_PARENT/run.sibling"
/bin/mkdir -m 700 "$RUN_TMP_SANDBOX"
/bin/mkdir -m 700 "$RUN_TMP_PARENT"
/bin/mkdir -m 700 "$RUN_TMP_CURRENT"
/bin/mkdir -m 700 "$RUN_TMP_SIBLING"
/bin/mkdir -m 700 "$RUN_TMP_CURRENT/nested"
print -r -- transient >"$RUN_TMP_CURRENT/nested/file"
WRAPPER_PATH="$BEHAVIOR_WRAPPER" \
RUN_TMP_SANDBOX="$RUN_TMP_SANDBOX" \
RUN_TMP_PARENT="$RUN_TMP_PARENT" \
RUN_TMP_CURRENT="$RUN_TMP_CURRENT" \
RUN_TMP_SIBLING="$RUN_TMP_SIBLING" \
/bin/zsh <<'RUNTMPCLEANUPTEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM

TESTFLIGHT_BUILD_SANDBOX_DIRECTORY=$RUN_TMP_SANDBOX
TESTFLIGHT_BUILD_RUN_TMP_PARENT_DIRECTORY=$RUN_TMP_PARENT
TESTFLIGHT_BUILD_RUN_TMP_PARENT_IDENTITY=$(stat_identity "$RUN_TMP_PARENT")
TESTFLIGHT_BUILD_TMP_DIRECTORY=$RUN_TMP_CURRENT
TESTFLIGHT_BUILD_TMP_IDENTITY=$(stat_identity "$RUN_TMP_CURRENT")
remove_current_run_tmp_directory
[[ ! -e "$RUN_TMP_CURRENT" \
    && -d "$RUN_TMP_SIBLING" \
    && -z "$TESTFLIGHT_BUILD_TMP_DIRECTORY" \
    && -z "$TESTFLIGHT_BUILD_TMP_IDENTITY" ]]
/bin/rmdir -- "$RUN_TMP_SIBLING"
/bin/rmdir -- "$RUN_TMP_PARENT"
/bin/rmdir -- "$RUN_TMP_SANDBOX"
RUNTMPCLEANUPTEST

PROCESSING_QUERY_OUTPUT="$BEHAVIOR_ROOT/processing-query-output"
PROCESSING_QUERY_BUILD_TMP="$BEHAVIOR_ROOT/processing-query-build-tmp"
PROCESSING_QUERY_MOCK="$BEHAVIOR_ROOT/mock-processing-query.zsh"
/bin/mkdir -m 700 "$PROCESSING_QUERY_OUTPUT"
/bin/mkdir -m 700 "$PROCESSING_QUERY_BUILD_TMP"
print -r -- preserve >"$PROCESSING_QUERY_BUILD_TMP/sentinel"
print -r -- '#!/bin/zsh
print -r -- "${TMPDIR}"
trap "" TERM
while true; do
  /bin/sleep 1
done' >"$PROCESSING_QUERY_MOCK"
/bin/chmod 700 "$PROCESSING_QUERY_MOCK"
WRAPPER_PATH="$BEHAVIOR_WRAPPER" \
PROCESSING_QUERY_OUTPUT="$PROCESSING_QUERY_OUTPUT" \
PROCESSING_QUERY_BUILD_TMP="$PROCESSING_QUERY_BUILD_TMP" \
PROCESSING_QUERY_MOCK="$PROCESSING_QUERY_MOCK" \
/bin/zsh <<'PROCESSINGQUERYTEST'
source <(/usr/bin/sed \
  -e 's|^readonly EXPECTED_ALTOOL_REAL_PATH=.*$|readonly EXPECTED_ALTOOL_REAL_PATH="${PROCESSING_QUERY_MOCK}"|' \
  -e 's|^readonly -i APP_STORE_PROCESSING_WAIT_TIMEOUT_SECONDS=1800$|readonly -i APP_STORE_PROCESSING_WAIT_TIMEOUT_SECONDS=1|' \
  -e 's|^readonly -i APP_STORE_PROCESSING_WAIT_POLL_SECONDS=5$|readonly -i APP_STORE_PROCESSING_WAIT_POLL_SECONDS=1|' \
  -e 's|^readonly -i APP_STORE_PROCESSING_TERMINATION_GRACE_SECONDS=5$|readonly -i APP_STORE_PROCESSING_TERMINATION_GRACE_SECONDS=1|' \
  -e '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM

function verify_app_store_connect_api_key_identity() { return 0 }
function verify_reviewed_xcode_toolchain_identity() { return 0 }
function verify_archive_destination_identity() { return 0 }
function verify_successful_upload_distribution_record() { return 0 }
function verify_output_directory_identity() { return 0 }
function verify_processing_status_destination() { return 0 }
function plist_typed_raw_value() {
  [[ "$2" == Distributions.0.identifier && "$3" == string ]] || return 1
  print -r -- 082360c7-b3ee-45dc-9264-68604218c97e
}
typeset PROCESSING_SIGNAL_STATE=unmasked
function mask_release_cleanup_signals() {
  [[ "$PROCESSING_SIGNAL_STATE" == unmasked ]] || return 1
  PROCESSING_SIGNAL_STATE=masked
}
function install_release_signal_traps() {
  if ! [[ "$PROCESSING_SIGNAL_STATE" == masked \
      && $TESTFLIGHT_PROCESSING_QUERY_PID -gt 1 \
      && $TESTFLIGHT_PROCESSING_QUERY_RUNNING == 1 ]]; then
    print -u2 -r -- \
      'processing query published incomplete state before restoring signal traps'
    return 1
  fi
  PROCESSING_SIGNAL_STATE=installed
}

TESTFLIGHT_OUTPUT_DIRECTORY=$PROCESSING_QUERY_OUTPUT
TESTFLIGHT_ARCHIVE_PATH=$PROCESSING_QUERY_OUTPUT/fake.xcarchive
TESTFLIGHT_BUILD_TMP_DIRECTORY=$PROCESSING_QUERY_BUILD_TMP
typeset -i processing_wait_started=$SECONDS
typeset -i processing_wait_status=0
wait_for_app_store_processing >/dev/null 2>&1 || processing_wait_status=$?
typeset -i processing_wait_elapsed=$((SECONDS - processing_wait_started))
if [[ $processing_wait_status != 124 \
    || $processing_wait_elapsed -lt 1 \
    || $processing_wait_elapsed -gt 10 ]]; then
  print -u2 -r -- \
    "bounded processing query returned ${processing_wait_status} after ${processing_wait_elapsed}s"
  exit 1
fi
typeset observed_processing_tmp=''
observed_processing_tmp=$(/usr/bin/sed -n '1p' \
  "$TESTFLIGHT_PROCESSING_STATUS_PATH")
if ! [[ "$observed_processing_tmp" \
      == "$PROCESSING_QUERY_OUTPUT"/app-store-processing-tmp.* \
    && "$observed_processing_tmp" != "$PROCESSING_QUERY_BUILD_TMP" \
    && ! -e "$observed_processing_tmp" \
    && ! -L "$observed_processing_tmp" \
    && -d "$PROCESSING_QUERY_BUILD_TMP" \
    && "$(<"$PROCESSING_QUERY_BUILD_TMP/sentinel")" == preserve \
    && -z "$TESTFLIGHT_PROCESSING_TMP_DIRECTORY" \
    && -z "$TESTFLIGHT_PROCESSING_TMP_DIRECTORY_IDENTITY" \
    && $TESTFLIGHT_PROCESSING_QUERY_PID == -1 \
    && $TESTFLIGHT_PROCESSING_QUERY_RUNNING == 0 \
    && "$PROCESSING_SIGNAL_STATE" == installed \
    && $TESTFLIGHT_PROCESSING_STATUS_FD == -1 ]]; then
  print -u2 -r -- \
    "bounded processing query did not isolate and clean TMPDIR: ${observed_processing_tmp}"
  exit 1
fi
PROCESSINGQUERYTEST

ENROLLMENT_DIVERGENCE_MARKER="$BEHAVIOR_ROOT/enrollment-divergence-initialized"
WRAPPER_PATH="$BEHAVIOR_WRAPPER" \
ENROLLMENT_DIVERGENCE_MARKER="$ENROLLMENT_DIVERGENCE_MARKER" \
/bin/zsh <<'ENROLLMENTDIVERGENCETEST'
source <(/usr/bin/sed \
  -e 's|^readonly EXPECTED_TESTFLIGHT_BUILD_CACHE_ENROLLMENT_PACKAGE_MANIFEST_SHA256=.*$|readonly EXPECTED_TESTFLIGHT_BUILD_CACHE_ENROLLMENT_PACKAGE_MANIFEST_SHA256="0000000000000000000000000000000000000000000000000000000000000000"|' \
  -e '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM

function verify_package_dependency_contract() { return 0 }
function initialize_private_testflight_build_volume() {
  print -r -- initialized >"$ENROLLMENT_DIVERGENCE_MARKER"
}

if ( run_initialize_build_cache ) >/dev/null 2>&1; then
  print -u2 -r -- 'fresh enrollment accepted divergent package provenance'
  exit 1
fi
if [[ -e "$ENROLLMENT_DIVERGENCE_MARKER" \
    || -L "$ENROLLMENT_DIVERGENCE_MARKER" ]]; then
  print -u2 -r -- 'divergent enrollment reached cache initialization'
  exit 1
fi
ENROLLMENTDIVERGENCETEST

ENROLLMENT_RECOVERY_CREDENTIALS="$BEHAVIOR_ROOT/enrollment-recovery-credentials"
ENROLLMENT_RECOVERY_BUILD_ROOT="$BEHAVIOR_ROOT/enrollment-recovery-build-root"
ENROLLMENT_RECOVERY_MOUNT_ROOT="$BEHAVIOR_ROOT/enrollment-recovery-mount-root"
ENROLLMENT_RECOVERY_COMMIT_MARKER="$BEHAVIOR_ROOT/enrollment-recovery-commit.log"
/bin/mkdir -m 700 "$ENROLLMENT_RECOVERY_CREDENTIALS"
/bin/mkdir -m 700 "$ENROLLMENT_RECOVERY_BUILD_ROOT"
WRAPPER_PATH="$BEHAVIOR_WRAPPER" \
ENROLLMENT_RECOVERY_CREDENTIALS="$ENROLLMENT_RECOVERY_CREDENTIALS" \
ENROLLMENT_RECOVERY_BUILD_ROOT="$ENROLLMENT_RECOVERY_BUILD_ROOT" \
ENROLLMENT_RECOVERY_MOUNT_ROOT="$ENROLLMENT_RECOVERY_MOUNT_ROOT" \
ENROLLMENT_RECOVERY_COMMIT_MARKER="$ENROLLMENT_RECOVERY_COMMIT_MARKER" \
/bin/zsh <<'ENROLLMENTRECOVERYTEST'
source <(/usr/bin/sed \
  -e 's|^readonly EXPECTED_ASC_API_KEY_DIRECTORY=.*$|readonly EXPECTED_ASC_API_KEY_DIRECTORY="${ENROLLMENT_RECOVERY_CREDENTIALS}"|' \
  -e 's|^readonly TESTFLIGHT_BUILD_ROOT=.*$|readonly TESTFLIGHT_BUILD_ROOT="${ENROLLMENT_RECOVERY_BUILD_ROOT}"|' \
  -e 's|^readonly TESTFLIGHT_BUILD_MOUNT_ROOT=.*$|readonly TESTFLIGHT_BUILD_MOUNT_ROOT="${ENROLLMENT_RECOVERY_MOUNT_ROOT}"|' \
  -e 's|^readonly EXPECTED_TESTFLIGHT_BUILD_CACHE_ENROLLMENT_PACKAGE_MANIFEST_SHA256=.*$|readonly EXPECTED_TESTFLIGHT_BUILD_CACHE_ENROLLMENT_PACKAGE_MANIFEST_SHA256="${EXPECTED_PACKAGE_MANIFEST_SHA256}"|' \
  -e 's|^readonly EXPECTED_TESTFLIGHT_BUILD_CACHE_ENROLLMENT_PACKAGE_RESOLVED_SHA256=.*$|readonly EXPECTED_TESTFLIGHT_BUILD_CACHE_ENROLLMENT_PACKAGE_RESOLVED_SHA256="${EXPECTED_PACKAGE_RESOLVED_SHA256}"|' \
  -e '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM

function verify_package_dependency_contract() { return 0 }
function find_current_attachment_record() { return 1 }
function reset_enrollment_recovery_state() {
  if (( TESTFLIGHT_BUILD_ENROLLMENT_MARKER_FD >= 0 )); then
    exec {TESTFLIGHT_BUILD_ENROLLMENT_MARKER_FD}>&-
  fi
  if (( TESTFLIGHT_BUILD_KEY_FD >= 0 )); then
    exec {TESTFLIGHT_BUILD_KEY_FD}>&-
  fi
  TESTFLIGHT_BUILD_ENROLLMENT_MARKER_PATH=''
  TESTFLIGHT_BUILD_ENROLLMENT_MARKER_IDENTITY=''
  TESTFLIGHT_BUILD_ENROLLMENT_MARKER_FD=-1
  TESTFLIGHT_BUILD_IMAGE_CONTAINER=''
  TESTFLIGHT_BUILD_IMAGE_CONTAINER_IDENTITY=''
  TESTFLIGHT_BUILD_IMAGE_PATH=''
  TESTFLIGHT_BUILD_IMAGE_IDENTITY=''
  TESTFLIGHT_BUILD_KEY_PATH=''
  TESTFLIGHT_BUILD_KEY_IDENTITY=''
  TESTFLIGHT_BUILD_KEY_FD=-1
  TESTFLIGHT_BUILD_CACHE_ROOT_IDENTITY=''
  TESTFLIGHT_BUILD_CACHE_ROOT_CREATED=0
  TESTFLIGHT_BUILD_CREATE_ATTEMPTED=0
  TESTFLIGHT_BUILD_ATTACH_ATTEMPTED=0
  TESTFLIGHT_BUILD_ATTACHMENT_ACTIVE=0
  TESTFLIGHT_IMAGE_DEVICE=''
  TESTFLIGHT_IMAGE_PARTITION_DEVICE=''
  TESTFLIGHT_MOUNTED_DEVICE=''
}

typeset enrollment_marker=$EXPECTED_TESTFLIGHT_BUILD_ENROLLMENT_MARKER_PATH
typeset enrollment_marker_staging=$EXPECTED_TESTFLIGHT_BUILD_ENROLLMENT_MARKER_STAGING_PATH
typeset enrollment_cache_root=$TESTFLIGHT_BUILD_CACHE_ROOT
typeset enrollment_image="$enrollment_cache_root/${TESTFLIGHT_BUILD_IMAGE_BASENAME}.sparseimage"
typeset enrollment_key=$EXPECTED_TESTFLIGHT_BUILD_KEY_PATH
typeset enrollment_lock=$EXPECTED_TESTFLIGHT_BUILD_LOCK_PATH

# A killed writer can leave only the bounded .new file; the next initializer removes it.
print -rn -- partial >"$enrollment_marker_staging"
/bin/chmod 600 "$enrollment_marker_staging"
recover_interrupted_build_cache_enrollment >/dev/null
[[ ! -e "$enrollment_marker_staging" && ! -L "$enrollment_marker_staging" ]]

/bin/mkdir -m 700 "$enrollment_cache_root"
print -r -- image >"$enrollment_image"
/bin/chmod 600 "$enrollment_image"
print -r -- 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
  >"$enrollment_key"
/bin/chmod 600 "$enrollment_key"
print -rn -- '' >"$enrollment_lock"
/bin/chmod 600 "$enrollment_lock"
reserve_pending_enrollment_marker
reset_enrollment_recovery_state

# Routine releases must reject an otherwise complete cache while its journal is pending.
TESTFLIGHT_BUILD_CACHE_INITIALIZE_MODE=0
if ( acquire_persistent_build_cache_lock ) >/dev/null 2>&1; then
  print -u2 -r -- 'routine cache acquisition accepted a pending enrollment marker'
  exit 1
fi
/bin/mv -- "$enrollment_marker" "$enrollment_marker_staging"
if ( acquire_persistent_build_cache_lock ) >/dev/null 2>&1; then
  print -u2 -r -- 'routine cache acquisition accepted a staged enrollment marker'
  exit 1
fi
/bin/mv -- "$enrollment_marker_staging" "$enrollment_marker"

# A malformed final marker authorizes no rollback at all.
print -r -- opensteamer-testflight-build-cache-enrollment-v0 \
  >"$enrollment_marker"
if recover_interrupted_build_cache_enrollment >/dev/null 2>&1; then
  print -u2 -r -- 'malformed enrollment marker unexpectedly authorized recovery'
  exit 1
fi
[[ -d "$enrollment_cache_root" \
    && -f "$enrollment_image" \
    && -f "$enrollment_key" \
    && -f "$enrollment_marker" ]]
reset_enrollment_recovery_state
/bin/rm -- "$enrollment_marker"
reserve_pending_enrollment_marker
reset_enrollment_recovery_state
TESTFLIGHT_BUILD_CACHE_INITIALIZE_MODE=1

# A surviving image user blocks rollback before any persistent object is removed.
typeset -i enrollment_image_busy_fd=-1
sysopen -r -o nofollow -u enrollment_image_busy_fd "$enrollment_image"
if recover_interrupted_build_cache_enrollment >/dev/null 2>&1; then
  print -u2 -r -- 'busy interrupted-enrollment image unexpectedly rolled back'
  exit 1
fi
[[ -d "$enrollment_cache_root" \
    && -f "$enrollment_image" \
    && -f "$enrollment_key" \
    && -f "$enrollment_marker" ]]
reset_enrollment_recovery_state
exec {enrollment_image_busy_fd}>&-

# A surviving key user blocks key deletion; the durable marker makes the partial rollback retryable.
typeset -i enrollment_key_busy_fd=-1
sysopen -r -o nofollow -u enrollment_key_busy_fd "$enrollment_key"
if recover_interrupted_build_cache_enrollment >/dev/null 2>&1; then
  print -u2 -r -- 'busy interrupted-enrollment key unexpectedly rolled back'
  exit 1
fi
[[ ! -e "$enrollment_cache_root" \
    && ! -L "$enrollment_cache_root" \
    && ! -e "$enrollment_image" \
    && ! -L "$enrollment_image" \
    && -f "$enrollment_key" \
    && -f "$enrollment_marker" ]]
reset_enrollment_recovery_state
exec {enrollment_key_busy_fd}>&-

recover_interrupted_build_cache_enrollment >/dev/null
[[ ! -e "$enrollment_cache_root" \
    && ! -L "$enrollment_cache_root" \
    && ! -e "$enrollment_key" \
    && ! -L "$enrollment_key" \
    && ! -e "$enrollment_marker" \
    && ! -L "$enrollment_marker" ]]

# A cleanup process that does not own the cache lock cannot erase another initializer's journal.
reserve_pending_enrollment_marker
reset_enrollment_recovery_state
TESTFLIGHT_BUILD_CACHE_INITIALIZE_MODE=1
TESTFLIGHT_BUILD_CACHE_ENROLLMENT_COMMITTED=0
TESTFLIGHT_BUILD_CACHE_LOCK_FD=-1
cleanup_private_build_volume
[[ -f "$enrollment_marker" \
    && "$(sha256_file "$enrollment_marker")" \
      == "$TESTFLIGHT_BUILD_ENROLLMENT_MARKER_SHA256" ]]
/bin/rm -- "$enrollment_marker"
print -rn -- partial >"$enrollment_marker_staging"
/bin/chmod 600 "$enrollment_marker_staging"
TESTFLIGHT_BUILD_CACHE_INITIALIZE_MODE=1
TESTFLIGHT_BUILD_CACHE_ENROLLMENT_COMMITTED=0
TESTFLIGHT_BUILD_CACHE_LOCK_FD=-1
cleanup_private_build_volume
[[ -f "$enrollment_marker_staging" ]]
/bin/rm -- "$enrollment_marker_staging"

# The public initializer removes the durable marker before publishing committed state.
functions -c remove_pending_enrollment_marker \
  production_remove_pending_enrollment_marker
function remove_pending_enrollment_marker() {
  [[ $TESTFLIGHT_BUILD_CACHE_ENROLLMENT_COMMITTED == 0 ]] || return 1
  print -r -- remove >>"$ENROLLMENT_RECOVERY_COMMIT_MARKER"
  production_remove_pending_enrollment_marker
}
function initialize_private_testflight_build_volume() {
  reserve_pending_enrollment_marker
  print -r -- initialize >>"$ENROLLMENT_RECOVERY_COMMIT_MARKER"
}
function verify_private_build_volume_identity() {
  verify_pending_enrollment_marker
  print -r -- verify >>"$ENROLLMENT_RECOVERY_COMMIT_MARKER"
}
function cleanup_private_build_volume() {
  [[ $TESTFLIGHT_BUILD_CACHE_ENROLLMENT_COMMITTED == 1 \
      && ! -e "$enrollment_marker" \
      && ! -L "$enrollment_marker" \
      && ! -e "$enrollment_marker_staging" \
      && ! -L "$enrollment_marker_staging" ]] || return 1
  print -r -- cleanup >>"$ENROLLMENT_RECOVERY_COMMIT_MARKER"
}
RELEASE_SCRATCH_CLEANUP_COMPLETE=0
RELEASE_SCRATCH_CLEANUP_RUNNING=0
run_initialize_build_cache >/dev/null
[[ "$(<"$ENROLLMENT_RECOVERY_COMMIT_MARKER")" \
    == $'initialize\nverify\nremove\ncleanup' ]]
ENROLLMENTRECOVERYTEST

ROLLBACK_CONTROL="$BEHAVIOR_ROOT/rollback-control"
ROLLBACK_CONTAINER="$BEHAVIOR_ROOT/rollback-cache-root"
ROLLBACK_IMAGE="$ROLLBACK_CONTAINER/cache.sparseimage"
ROLLBACK_KEY="$BEHAVIOR_ROOT/rollback.key"
ROLLBACK_LOCK="$BEHAVIOR_ROOT/rollback.lock"
ROLLBACK_SENTINEL="$BEHAVIOR_ROOT/rollback-sentinel"
/bin/mkdir -m 700 "$ROLLBACK_CONTROL"
/bin/mkdir -m 700 "$ROLLBACK_CONTAINER"
print -r -- image >"$ROLLBACK_IMAGE"
/bin/chmod 600 "$ROLLBACK_IMAGE"
print -r -- key >"$ROLLBACK_KEY"
/bin/chmod 600 "$ROLLBACK_KEY"
print -rn -- '' >"$ROLLBACK_LOCK"
/bin/chmod 600 "$ROLLBACK_LOCK"
print -r -- preserve >"$ROLLBACK_SENTINEL"
WRAPPER_PATH="$BEHAVIOR_WRAPPER" \
ROLLBACK_CONTROL="$ROLLBACK_CONTROL" \
ROLLBACK_CONTAINER="$ROLLBACK_CONTAINER" \
ROLLBACK_IMAGE="$ROLLBACK_IMAGE" \
ROLLBACK_KEY="$ROLLBACK_KEY" \
ROLLBACK_LOCK="$ROLLBACK_LOCK" \
ROLLBACK_SENTINEL="$ROLLBACK_SENTINEL" \
/bin/zsh <<'ENROLLMENTROLLBACKTEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM

function verify_control_directory_identity() {
  [[ -d "$TESTFLIGHT_CONTROL_DIRECTORY" \
      && "$(stat_identity "$TESTFLIGHT_CONTROL_DIRECTORY")" \
        == "$TESTFLIGHT_CONTROL_DIRECTORY_IDENTITY" ]]
}
function verify_image_container_identity() {
  [[ -d "$TESTFLIGHT_BUILD_IMAGE_CONTAINER" \
      && "$(stat_identity "$TESTFLIGHT_BUILD_IMAGE_CONTAINER")" \
        == "$TESTFLIGHT_BUILD_IMAGE_CONTAINER_IDENTITY" ]]
}
function verify_image_storage_identity() {
  [[ -f "$TESTFLIGHT_BUILD_IMAGE_PATH" \
      && "$(stat_identity "$TESTFLIGHT_BUILD_IMAGE_PATH")" \
        == "$TESTFLIGHT_BUILD_IMAGE_IDENTITY" ]]
}
function current_attachment_is_absent() { return 0 }
function verify_build_cache_lock_identity() {
  [[ -f "$ROLLBACK_LOCK" \
      && ! -L "$ROLLBACK_LOCK" \
      && -n "$TESTFLIGHT_BUILD_CACHE_LOCK_IDENTITY" \
      && "$(stat_identity "$ROLLBACK_LOCK")" \
        == "$TESTFLIGHT_BUILD_CACHE_LOCK_IDENTITY" \
      && "$TESTFLIGHT_BUILD_CACHE_LOCK_FD" -ge 0 \
      && -e "/dev/fd/${TESTFLIGHT_BUILD_CACHE_LOCK_FD}" \
      && "$ROLLBACK_LOCK" -ef "/dev/fd/${TESTFLIGHT_BUILD_CACHE_LOCK_FD}" ]]
}

TESTFLIGHT_CONTROL_DIRECTORY=$ROLLBACK_CONTROL
TESTFLIGHT_CONTROL_DIRECTORY_IDENTITY=$(stat_identity "$ROLLBACK_CONTROL")
TESTFLIGHT_BUILD_IMAGE_CONTAINER=$ROLLBACK_CONTAINER
TESTFLIGHT_BUILD_IMAGE_CONTAINER_IDENTITY=$(stat_identity "$ROLLBACK_CONTAINER")
TESTFLIGHT_BUILD_IMAGE_PATH=$ROLLBACK_IMAGE
TESTFLIGHT_BUILD_IMAGE_IDENTITY=$(stat_identity "$ROLLBACK_IMAGE")
TESTFLIGHT_BUILD_KEY_PATH=$ROLLBACK_KEY
TESTFLIGHT_BUILD_KEY_IDENTITY=$(stat_identity "$ROLLBACK_KEY")
sysopen -r -o nofollow -u TESTFLIGHT_BUILD_KEY_FD "$ROLLBACK_KEY"
TESTFLIGHT_BUILD_CACHE_LOCK_IDENTITY=$(stat_identity "$ROLLBACK_LOCK")
zsystem flock -t 0 -f TESTFLIGHT_BUILD_CACHE_LOCK_FD "$ROLLBACK_LOCK"
TESTFLIGHT_BUILD_CACHE_INITIALIZE_MODE=1
TESTFLIGHT_BUILD_CACHE_ENROLLMENT_COMMITTED=0
TESTFLIGHT_BUILD_CACHE_ROOT_CREATED=1
TESTFLIGHT_BUILD_KEY_CREATED=1
TESTFLIGHT_BUILD_CREATE_ATTEMPTED=1
TESTFLIGHT_BUILD_IMAGE_CREATED=1
TESTFLIGHT_BUILD_ATTACH_ATTEMPTED=0
TESTFLIGHT_BUILD_ATTACHMENT_ACTIVE=0
TESTFLIGHT_BUILD_MOUNT_POINT=''
TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH=''

cleanup_private_build_volume
[[ ! -e "$ROLLBACK_IMAGE" \
    && ! -e "$ROLLBACK_CONTAINER" \
    && ! -e "$ROLLBACK_KEY" \
    && ! -e "$ROLLBACK_CONTROL" \
    && -f "$ROLLBACK_LOCK" \
    && "$(<"$ROLLBACK_SENTINEL")" == preserve \
    && "$TESTFLIGHT_BUILD_KEY_FD" == -1 \
    && "$TESTFLIGHT_BUILD_CACHE_LOCK_FD" == -1 \
    && -z "$TESTFLIGHT_BUILD_CACHE_LOCK_IDENTITY" \
    && "$TESTFLIGHT_BUILD_CACHE_INITIALIZE_MODE" == 0 \
    && "$TESTFLIGHT_BUILD_CACHE_ENROLLMENT_COMMITTED" == 0 \
    && "$TESTFLIGHT_BUILD_CACHE_ROOT_CREATED" == 0 \
    && "$TESTFLIGHT_BUILD_KEY_CREATED" == 0 ]]
typeset -i rollback_lock_probe=-1
zsystem flock -t 0 -f rollback_lock_probe "$ROLLBACK_LOCK"
zsystem flock -u "$rollback_lock_probe"
ENROLLMENTROLLBACKTEST

ENROLLED_SIGNAL_CONTROL="$BEHAVIOR_ROOT/enrolled-signal-control"
ENROLLED_SIGNAL_CONTAINER="$BEHAVIOR_ROOT/enrolled-signal-cache-root"
ENROLLED_SIGNAL_IMAGE="$ENROLLED_SIGNAL_CONTAINER/cache.sparseimage"
ENROLLED_SIGNAL_KEY="$BEHAVIOR_ROOT/enrolled-signal.key"
ENROLLED_SIGNAL_LOCK="$BEHAVIOR_ROOT/enrolled-signal.lock"
ENROLLED_SIGNAL_SENTINEL="$BEHAVIOR_ROOT/enrolled-signal-sentinel"
/bin/mkdir -m 700 "$ENROLLED_SIGNAL_CONTROL"
/bin/mkdir -m 700 "$ENROLLED_SIGNAL_CONTAINER"
print -r -- image >"$ENROLLED_SIGNAL_IMAGE"
/bin/chmod 600 "$ENROLLED_SIGNAL_IMAGE"
print -r -- key >"$ENROLLED_SIGNAL_KEY"
/bin/chmod 600 "$ENROLLED_SIGNAL_KEY"
print -rn -- '' >"$ENROLLED_SIGNAL_LOCK"
/bin/chmod 600 "$ENROLLED_SIGNAL_LOCK"
print -r -- preserve >"$ENROLLED_SIGNAL_SENTINEL"
if WRAPPER_PATH="$BEHAVIOR_WRAPPER" \
    ENROLLED_SIGNAL_CONTROL="$ENROLLED_SIGNAL_CONTROL" \
    ENROLLED_SIGNAL_CONTAINER="$ENROLLED_SIGNAL_CONTAINER" \
    ENROLLED_SIGNAL_IMAGE="$ENROLLED_SIGNAL_IMAGE" \
    ENROLLED_SIGNAL_KEY="$ENROLLED_SIGNAL_KEY" \
    ENROLLED_SIGNAL_LOCK="$ENROLLED_SIGNAL_LOCK" \
    /bin/zsh <<'ENROLLEDSIGNALTEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")

function verify_control_directory_identity() {
  [[ -d "$TESTFLIGHT_CONTROL_DIRECTORY" \
      && "$(stat_identity "$TESTFLIGHT_CONTROL_DIRECTORY")" \
        == "$TESTFLIGHT_CONTROL_DIRECTORY_IDENTITY" ]]
}
function verify_image_container_identity() {
  [[ -d "$TESTFLIGHT_BUILD_IMAGE_CONTAINER" \
      && "$(stat_identity "$TESTFLIGHT_BUILD_IMAGE_CONTAINER")" \
        == "$TESTFLIGHT_BUILD_IMAGE_CONTAINER_IDENTITY" ]]
}
function verify_image_storage_identity() {
  [[ -f "$TESTFLIGHT_BUILD_IMAGE_PATH" \
      && "$(stat_identity "$TESTFLIGHT_BUILD_IMAGE_PATH")" \
        == "$TESTFLIGHT_BUILD_IMAGE_IDENTITY" ]]
}
function verify_build_key_identity() {
  [[ -f "$TESTFLIGHT_BUILD_KEY_PATH" \
      && "$(stat_identity "$TESTFLIGHT_BUILD_KEY_PATH")" \
        == "$TESTFLIGHT_BUILD_KEY_IDENTITY" \
      && "$TESTFLIGHT_BUILD_KEY_PATH" \
        -ef "/dev/fd/${TESTFLIGHT_BUILD_KEY_FD}" ]]
}
function current_attachment_is_absent() { return 0 }
function verify_build_cache_lock_identity() {
  [[ -f "$ENROLLED_SIGNAL_LOCK" \
      && ! -L "$ENROLLED_SIGNAL_LOCK" \
      && "$(stat_identity "$ENROLLED_SIGNAL_LOCK")" \
        == "$TESTFLIGHT_BUILD_CACHE_LOCK_IDENTITY" \
      && "$TESTFLIGHT_BUILD_CACHE_LOCK_FD" -ge 0 \
      && -e "/dev/fd/${TESTFLIGHT_BUILD_CACHE_LOCK_FD}" \
      && "$ENROLLED_SIGNAL_LOCK" \
        -ef "/dev/fd/${TESTFLIGHT_BUILD_CACHE_LOCK_FD}" ]]
}

TESTFLIGHT_CONTROL_DIRECTORY=$ENROLLED_SIGNAL_CONTROL
TESTFLIGHT_CONTROL_DIRECTORY_IDENTITY=$(stat_identity "$ENROLLED_SIGNAL_CONTROL")
TESTFLIGHT_BUILD_IMAGE_CONTAINER=$ENROLLED_SIGNAL_CONTAINER
TESTFLIGHT_BUILD_IMAGE_CONTAINER_IDENTITY=$(stat_identity \
  "$ENROLLED_SIGNAL_CONTAINER")
TESTFLIGHT_BUILD_IMAGE_PATH=$ENROLLED_SIGNAL_IMAGE
TESTFLIGHT_BUILD_IMAGE_IDENTITY=$(stat_identity "$ENROLLED_SIGNAL_IMAGE")
TESTFLIGHT_BUILD_KEY_PATH=$ENROLLED_SIGNAL_KEY
TESTFLIGHT_BUILD_KEY_IDENTITY=$(stat_identity "$ENROLLED_SIGNAL_KEY")
sysopen -r -o nofollow -u TESTFLIGHT_BUILD_KEY_FD "$ENROLLED_SIGNAL_KEY"
TESTFLIGHT_BUILD_CACHE_LOCK_IDENTITY=$(stat_identity "$ENROLLED_SIGNAL_LOCK")
zsystem flock -t 0 -f TESTFLIGHT_BUILD_CACHE_LOCK_FD \
  "$ENROLLED_SIGNAL_LOCK"
TESTFLIGHT_BUILD_CACHE_INITIALIZE_MODE=1
TESTFLIGHT_BUILD_CACHE_ENROLLMENT_COMMITTED=1
TESTFLIGHT_BUILD_CACHE_ROOT_CREATED=1
TESTFLIGHT_BUILD_KEY_CREATED=1
TESTFLIGHT_BUILD_CREATE_ATTEMPTED=1
TESTFLIGHT_BUILD_IMAGE_CREATED=1
TESTFLIGHT_BUILD_ATTACH_ATTEMPTED=0
TESTFLIGHT_BUILD_ATTACHMENT_ACTIVE=0
TESTFLIGHT_BUILD_MOUNT_POINT=''
TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH=''

/bin/kill -TERM $$
exit 99
ENROLLEDSIGNALTEST
then
  print -u2 -r -- 'TERM did not terminate the committed-enrollment behavior child'
  exit 1
else
  ENROLLED_SIGNAL_STATUS=$?
fi
[[ $ENROLLED_SIGNAL_STATUS == 143 \
    && ! -e "$ENROLLED_SIGNAL_CONTROL" \
    && -d "$ENROLLED_SIGNAL_CONTAINER" \
    && -f "$ENROLLED_SIGNAL_IMAGE" \
    && "$(<"$ENROLLED_SIGNAL_IMAGE")" == image \
    && -f "$ENROLLED_SIGNAL_KEY" \
    && "$(<"$ENROLLED_SIGNAL_KEY")" == key \
    && -f "$ENROLLED_SIGNAL_LOCK" \
    && "$(<"$ENROLLED_SIGNAL_SENTINEL")" == preserve ]]
typeset -i enrolled_signal_lock_probe=-1
zsystem flock -t 0 -f enrolled_signal_lock_probe "$ENROLLED_SIGNAL_LOCK"
zsystem flock -u "$enrolled_signal_lock_probe"

PROCESSING_STATUS="$BEHAVIOR_ROOT/app-store-processing-status.json"
print -r -- '{
  "delivery-uuid": "082360c7-b3ee-45dc-9264-68604218c97e",
  "build-status": "VALID",
  "import-status": "VALID",
  "is-on-app-store-connect": true,
  "build-audience-type": "INTERNAL_ONLY",
  "app-store-attributes": {
    "buildAudienceType": "INTERNAL_ONLY",
    "processingState": "VALID",
    "version": "61",
    "expired": false
  }
}' >"$PROCESSING_STATUS"
/bin/chmod 600 "$PROCESSING_STATUS"
WRAPPER_PATH="$BEHAVIOR_WRAPPER" PROCESSING_STATUS="$PROCESSING_STATUS" \
/bin/zsh <<'PROCESSINGSTATUSTEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM

function repin_processing_status() {
  /bin/chmod 600 "$PROCESSING_STATUS"
  TESTFLIGHT_PROCESSING_STATUS_IDENTITY=$(stat_identity "$PROCESSING_STATUS")
}
function expect_processing_status_rejection() {
  repin_processing_status
  if verify_app_store_processing_status >/dev/null 2>&1; then
    print -u2 -r -- "processing-status mutation unexpectedly passed: $1"
    exit 1
  fi
}

function verify_output_directory_identity() { return 0 }
TESTFLIGHT_OUTPUT_DIRECTORY=${PROCESSING_STATUS:h}
TESTFLIGHT_PROCESSING_STATUS_PATH=$PROCESSING_STATUS
TESTFLIGHT_PROCESSING_STATUS_FD=-1
TESTFLIGHT_DELIVERY_ID=082360c7-b3ee-45dc-9264-68604218c97e
repin_processing_status
verify_app_store_processing_status

/usr/bin/plutil -replace app-store-attributes.processingState \
  -string PROCESSING "$PROCESSING_STATUS"
expect_processing_status_rejection processing-state
/usr/bin/plutil -replace app-store-attributes.processingState \
  -string VALID "$PROCESSING_STATUS"
/usr/bin/plutil -replace build-audience-type \
  -string EXTERNAL_ONLY "$PROCESSING_STATUS"
expect_processing_status_rejection audience
/usr/bin/plutil -replace build-audience-type \
  -string INTERNAL_ONLY "$PROCESSING_STATUS"
/usr/bin/plutil -replace app-store-attributes.version \
  -string 52 "$PROCESSING_STATUS"
expect_processing_status_rejection build
/usr/bin/plutil -replace app-store-attributes.version \
  -string 61 "$PROCESSING_STATUS"
/usr/bin/plutil -replace delivery-uuid \
  -string 11111111-2222-3333-4444-555555555555 "$PROCESSING_STATUS"
expect_processing_status_rejection delivery
/usr/bin/plutil -replace delivery-uuid \
  -string 082360c7-b3ee-45dc-9264-68604218c97e "$PROCESSING_STATUS"
typeset valid_status_backup="${PROCESSING_STATUS}.valid"
/bin/cp -- "$PROCESSING_STATUS" "$valid_status_backup"
print -r -- '{"incomplete":' >"$PROCESSING_STATUS"
expect_processing_status_rejection malformed-json
/bin/mv -- "$valid_status_backup" "$PROCESSING_STATUS"
repin_processing_status
verify_app_store_processing_status
PROCESSINGSTATUSTEST

SIGNAL_MARKER="$BEHAVIOR_ROOT/signal-masked.log"
if WRAPPER_PATH="$BEHAVIOR_WRAPPER" SIGNAL_MARKER="$SIGNAL_MARKER" \
    /bin/zsh <<'SIGNALTEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
function cleanup_private_build_volume() {
  print -r -- before >>"$SIGNAL_MARKER"
  /bin/kill -TERM $$
  print -r -- after >>"$SIGNAL_MARKER"
  return 0
}
cleanup_private_build_volume_signal_masked
cleanup_private_build_volume_signal_masked
/bin/kill -TERM $$
exit 99
SIGNALTEST
then
  print -u2 -r -- 'restored TERM trap did not terminate the cleanup behavior child'
  exit 1
else
  SIGNAL_STATUS=$?
fi
[[ $SIGNAL_STATUS == 143 ]]
[[ "$(grep -c '^before$' "$SIGNAL_MARKER")" == 1 ]]
[[ "$(grep -c '^after$' "$SIGNAL_MARKER")" == 1 ]]

EXIT_SIGNAL_MARKER="$BEHAVIOR_ROOT/exit-signal-masked.log"
if WRAPPER_PATH="$BEHAVIOR_WRAPPER" EXIT_SIGNAL_MARKER="$EXIT_SIGNAL_MARKER" \
    /bin/zsh <<'EXITSIGNALTEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
function cleanup_release_scratch() {
  print -r -- before >>"$EXIT_SIGNAL_MARKER"
  /bin/kill -INT $$
  print -r -- after >>"$EXIT_SIGNAL_MARKER"
  return 0
}
/bin/kill -TERM $$
exit 99
EXITSIGNALTEST
then
  print -u2 -r -- 'TERM did not enter the production EXIT cleanup path'
  exit 1
else
  EXIT_SIGNAL_STATUS=$?
fi
[[ $EXIT_SIGNAL_STATUS == 143 ]]
[[ "$(grep -c '^before$' "$EXIT_SIGNAL_MARKER")" == 1 ]]
[[ "$(grep -c '^after$' "$EXIT_SIGNAL_MARKER")" == 1 ]]

WRAPPER_PATH="$BEHAVIOR_WRAPPER" /bin/zsh <<'DESTINATIONTEST'
source <(/usr/bin/sed '/^verify_static_contract$/,$d' "$WRAPPER_PATH")
trap - EXIT HUP INT QUIT TERM

function expect_rejection() {
  if "$@" >/dev/null 2>&1; then
    print -u2 -r -- "release destination mutation unexpectedly passed: $*"
    exit 1
  fi
}

create_safe_output_directory
[[ "$TESTFLIGHT_OUTPUT_DIRECTORY" == /private/tmp/opensteamer-testflight-output.* ]]
trap '/bin/rm -rf -- "$TESTFLIGHT_OUTPUT_DIRECTORY"' EXIT
reserve_archive_exec_destinations
reserve_export_exec_destinations
verify_archive_exec_destinations
verify_export_exec_destinations
[[ "$TESTFLIGHT_ARCHIVE_LOG_PATH" -ef "/dev/fd/${TESTFLIGHT_ARCHIVE_LOG_FD}" ]]
[[ "$TESTFLIGHT_UPLOAD_LOG_PATH" -ef "/dev/fd/${TESTFLIGHT_UPLOAD_LOG_FD}" ]]

print -r -- occupied >"$TESTFLIGHT_ARCHIVE_PATH"
expect_rejection verify_archive_exec_destinations
/bin/rm -- "$TESTFLIGHT_ARCHIVE_PATH"

typeset sentinel="$TESTFLIGHT_OUTPUT_DIRECTORY/sentinel"
print -r -- unchanged >"$sentinel"
/bin/ln -s "$sentinel" "$TESTFLIGHT_ARCHIVE_PATH"
expect_rejection verify_archive_exec_destinations
[[ "$(<"$sentinel")" == unchanged ]]
/bin/rm -- "$TESTFLIGHT_ARCHIVE_PATH"

typeset moved_archive_directory="${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY}.moved"
/bin/mv -- "$TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY" "$moved_archive_directory"
/bin/mkdir -m 700 "$TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY"
expect_rejection verify_archive_destination_identity
/bin/rmdir -- "$TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY"
/bin/mv -- "$moved_archive_directory" "$TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY"

typeset moved_archive_log="${TESTFLIGHT_ARCHIVE_LOG_PATH}.moved"
/bin/mv -- "$TESTFLIGHT_ARCHIVE_LOG_PATH" "$moved_archive_log"
/bin/ln -s "$sentinel" "$TESTFLIGHT_ARCHIVE_LOG_PATH"
expect_rejection verify_archive_destination_identity
print -u${TESTFLIGHT_ARCHIVE_LOG_FD} -r -- descriptor-evidence
[[ "$(<"$sentinel")" == unchanged ]]
/bin/rm -- "$TESTFLIGHT_ARCHIVE_LOG_PATH"
/bin/mv -- "$moved_archive_log" "$TESTFLIGHT_ARCHIVE_LOG_PATH"

typeset export_entry="$TESTFLIGHT_EXPORT_DIRECTORY/occupied"
print -r -- occupied >"$export_entry"
expect_rejection verify_export_exec_destinations
/bin/rm -- "$export_entry"
/bin/ln -s "$sentinel" "$export_entry"
expect_rejection verify_export_exec_destinations
/bin/rm -- "$export_entry"

typeset moved_export_directory="${TESTFLIGHT_EXPORT_DIRECTORY}.moved"
/bin/mv -- "$TESTFLIGHT_EXPORT_DIRECTORY" "$moved_export_directory"
/bin/mkdir -m 700 "$TESTFLIGHT_EXPORT_DIRECTORY"
expect_rejection verify_export_destination_identity
/bin/rmdir -- "$TESTFLIGHT_EXPORT_DIRECTORY"
/bin/mv -- "$moved_export_directory" "$TESTFLIGHT_EXPORT_DIRECTORY"

typeset moved_upload_log="${TESTFLIGHT_UPLOAD_LOG_PATH}.moved"
/bin/mv -- "$TESTFLIGHT_UPLOAD_LOG_PATH" "$moved_upload_log"
/bin/ln -s "$sentinel" "$TESTFLIGHT_UPLOAD_LOG_PATH"
expect_rejection verify_export_destination_identity
print -u${TESTFLIGHT_UPLOAD_LOG_FD} -r -- descriptor-evidence
[[ "$(<"$sentinel")" == unchanged ]]
/bin/rm -- "$TESTFLIGHT_UPLOAD_LOG_PATH"
/bin/mv -- "$moved_upload_log" "$TESTFLIGHT_UPLOAD_LOG_PATH"

exec {TESTFLIGHT_ARCHIVE_LOG_FD}>&-
exec {TESTFLIGHT_UPLOAD_LOG_FD}>&-
exec {TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY_FD}>&-
exec {TESTFLIGHT_EXPORT_DIRECTORY_FD}>&-
exec {TESTFLIGHT_OUTPUT_DIRECTORY_FD}>&-
/bin/rm -rf -- "$TESTFLIGHT_OUTPUT_DIRECTORY"
trap - EXIT
DESTINATIONTEST

print -- 'opensteamer product identity regression tests passed'
