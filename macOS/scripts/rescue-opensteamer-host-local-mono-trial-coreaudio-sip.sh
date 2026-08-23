#!/bin/zsh
# One-shot recovery for the exact local-mono trial that stopped v6, published the candidate
# driver on disk, and then hit macOS's SIP rejection of launchctl kickstart -k.  This script
# deliberately does not signal Core Audio: the reviewed public-HAL proof established that the
# newly published endpoints were never loaded into the unchanged coreaudiod generation.
set -euo pipefail

export LC_ALL=C
umask 077

readonly SELF_TEST_MODE='--self-test'
readonly PREFLIGHT_MODE='--preflight'
readonly RESCUE_MODE='--rescue-exact-coreaudio-sip-failure'
readonly LIVE_RELEASE_STATUS='REVIEWED_COREAUDIO_SIP_RESCUE_READY'
readonly LIVE_RELEASE_READY='REVIEWED_COREAUDIO_SIP_RESCUE_READY'

readonly EXPECTED_REPO='/Users/ahmed/Documents/Codex/opensteamer'
readonly SCRIPT="$EXPECTED_REPO/macOS/scripts/rescue-opensteamer-host-local-mono-trial-coreaudio-sip.sh"
readonly INVOCATION_SCRIPT="${0:A}"
readonly EXPECTED_SCRIPT_NORMALIZED_SHA256='663dc97ec447e029cdc8cc5e6b80c77701c004f25f0d618448d60fbbb6a165e0'
readonly EXPECTED_ROOT_COMMAND_SHA256='fdd6b2736726131811516719efd770c75b2dc83657b73f1f9674e017e3199b8c'
readonly PINNED_PATH='/usr/bin:/bin:/usr/sbin:/sbin'
readonly PINNED_HOME='/Users/ahmed'

readonly ROOT_SUPPORT='/Library/Application Support/opensteamer-local-mono-trial-v1'
readonly ROOT_CONTROLLER="$ROOT_SUPPORT/opensteamer-local-mono-trial-controller"
readonly ROOT_PIN="$ROOT_SUPPORT/controller.sha256"
readonly ROOT_LOG="$ROOT_SUPPORT/root-broker.log"
readonly ROOT_TRANSACTION="$ROOT_SUPPORT/private-transaction-prep-L1Ciab"
readonly ROOT_JOURNAL="$ROOT_TRANSACTION/journal.log"
readonly ROOT_DRIVER_IDENTITY="$ROOT_TRANSACTION/driver.identity"
readonly ROOT_FAILED_DRIVER="$ROOT_TRANSACTION/OpensteamerVirtualMicrophone.driver.failed"
readonly ROOT_ABANDONED_DRIVER="$ROOT_TRANSACTION/OpensteamerVirtualMicrophone.driver.abandoned"
readonly ROOT_HOLD_DRIVER="$ROOT_TRANSACTION/OpensteamerVirtualMicrophone.driver.hold"
readonly ROOT_SEALED="$ROOT_SUPPORT/sealed-prep-L1Ciab"
readonly ROOT_SOCKET="$ROOT_SUPPORT/broker-prep-L1Ciab.sock"
readonly SEALED_CONTROLLER="$ROOT_SEALED/opensteamer-local-mono-trial-controller"
readonly SEALED_GUARDIAN="$ROOT_SEALED/opensteamer-v7-default-route-guardian"
readonly PRODUCT_DRIVER='/Library/Audio/Plug-Ins/HAL/OpensteamerVirtualMicrophone.driver'

readonly TRIAL_ROOT='/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab'
readonly TRIAL_RUN_ROOT="$TRIAL_ROOT/paired-v7-update-local-mono-prep-L1Ciab"
readonly TRIAL_PROBES="$TRIAL_RUN_ROOT/probes"
readonly TRIAL_STAGING="$TRIAL_ROOT/staging"
readonly TRIAL_CONTROLLER="$TRIAL_STAGING/opensteamer-local-mono-trial-controller"
readonly TRIAL_GUARDIAN="$TRIAL_STAGING/opensteamer-v7-default-route-guardian"
readonly ACTIVE_POINTER='/Users/ahmed/Library/Application Support/opensteamer/active-local-mono-trial-v1'
readonly ACTIVE_POINTER_TEMP='/Users/ahmed/Library/Application Support/opensteamer/.active-local-mono-trial-v1.prep-L1Ciab.tmp'
readonly RESCUED_TRIAL_ROOT='/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab.failed-coreaudio-kickstart-sip'
readonly RESCUED_ACTIVE_POINTER='/Users/ahmed/Library/Application Support/opensteamer/failed-active-local-mono-trial-v1.coreaudio-kickstart-sip-L1Ciab'

readonly NEW_APP='/Applications/opensteamer Host.app'
readonly NEW_EXECUTABLE="$NEW_APP/Contents/MacOS/CaptureServer"
readonly NEW_PLIST='/Users/ahmed/Library/LaunchAgents/org.example.opensteamer.worldwide.plist'
readonly NEW_LABEL='org.example.opensteamer.worldwide'
readonly LEGACY_APP='/Applications/AudioStreamer Host.app'
readonly LEGACY_EXECUTABLE="$LEGACY_APP/Contents/MacOS/CaptureServer"
readonly LEGACY_PLIST='/Users/ahmed/Library/LaunchAgents/com.elamin.audiostreamer.worldwide.plist'
readonly LEGACY_LABEL='com.elamin.audiostreamer.worldwide'
readonly SHARED_LOCK='/Users/ahmed/Library/Application Support/com.elamin.AudioStreamer.CaptureServer.runtime/worldwide-host.lock'
readonly LOGIN_KEYCHAIN='/Users/ahmed/Library/Keychains/login.keychain-db'
readonly PAIRING_SERVICE='com.elamin.opensteamer.CaptureServer.WorldwidePairing.v1'
readonly PAIRING_IDENTITY_ACCOUNT='worldwide-host-identity-v1'
readonly PAIRING_VIEWER_ACCOUNT='worldwide-paired-viewer-v1'

readonly V6_EVIDENCE='/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v6/paired-v6-update-1786412787-39578-728d9781-2b79-4d10-a220-8a48c1f6f716'
readonly V6_SOURCE_EXPORT="$V6_EVIDENCE/source-export"
readonly V6_REFERENCE_APP="$V6_EVIDENCE/deployment-reference/opensteamer Host.app"
readonly V6_BUNDLE_VERIFIER="$V6_SOURCE_EXPORT/macOS/scripts/verify-mac-host-bundle.sh"
readonly V6_LAUNCH_VERIFIER="$V6_SOURCE_EXPORT/macOS/scripts/verify-mac-host-launch-state.sh"

readonly CONTROLLER_SHA256='b2da40fa1a85cf00b9dfd84ec90b5ad71cba255c1cd4414e307e4596934b7d2e'
readonly CONTROLLER_SIZE='1443880'
readonly CONTROLLER_PIN_SHA256='070cbb6a1bde9c0230fb1e8a27aef3bc4811be0c25a356448ca2aa1836520c54'
readonly GUARDIAN_SHA256='72ef50156a0154e3b6c9a84557f3c192b67ec69f7a9747476826fb9aa3d4509c'
readonly MIRROR_PROBE_SHA256='403d1bf8aed711dba05c0ed575af4620ee8fa2454e6b50b6d51d07f261703d33'
readonly VPIO_PROBE_SHA256='0ec9e1a0cc5f253cc569134ce2be024a7f3ae6ad211fa7d20fe6436c0bac84c8'
readonly DRIVER_TREE_SHA256='48089061c4333dc29201f48eaa3b4e889fde99174dd99ffeaed414d9d98b3aa5'
readonly DRIVER_EXECUTABLE_SHA256='e78bfe1080660de99769d0f9313459fb22a08863d4ade52d25921db871383745'
readonly DRIVER_CDHASH='136282fbe7626c26618738e739eea2b0df2b59d5'
readonly ROOT_LOG_SHA256='21c50e4f479513403366762e57aee476c92f22678aa1a5c8a6b4053bbb84e708'
readonly ROOT_JOURNAL_SHA256='fe6e6d31b12e9f3216b0d9fc059fd962628a8709374f471abb8009fe459c2d7f'
readonly ROOT_DRIVER_IDENTITY_SHA256='24230285158c297e64c6e6480108148cab0e36b5fb6b02fb6e1a167a61ad2f25'

readonly V6_EXECUTABLE_SHA256='63d55477ca440dd3feb27f68959b479a2292e6accc635d159674c6b420b60de6'
readonly V6_PLIST_SHA256='7cdcf2d1517dc9ec1ae49b6fbbaf293c77afd958f697878d44f3b3c8e9c7e550'
readonly LEGACY_EXECUTABLE_SHA256='1bd5bbe685522f995ee01f52650198753d11344857f883898e29ee7a3f4c80bc'
readonly LEGACY_PLIST_SHA256='419eff4f410cfb0bf5e224528fd450c10292f7c1c2448d33e215e929f7c14730'
readonly V6_BUNDLE_VERIFIER_SHA256='02a348a88d25b76ab95d45620d823339212bb53ee0f39bfb3a52f04240d3d745'
readonly V6_LAUNCH_VERIFIER_SHA256='27c36f8adec05c22216955cb404d6732ceaa6065477e5bb1570f2d41e84db7a9'

readonly TRIAL_JOURNAL_SHA256='287c0d14aaf0f57ba1b4e133233c3425d7de70a6890938f16cc5932cb776d625'
readonly TRIAL_RESULT_SHA256='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
readonly TRIAL_PROXY_ARM_SHA256='6ffeb263e9fb9ec452deeae529450e5e3e972aa71fd042b0407fc8842cb320e1'
readonly ACTIVE_POINTER_SHA256='a91068fd7fa302984fb2639b14c5199e91f8873d3490e0034493d99dd0de0cd1'
readonly VPIO_STATE_SHA256='764ad56a633d19424112ca69cb02f93e09d18884ad28eed1539f12b2cbcce668'
readonly VPIO_SNAPSHOT_SHA256='f65aa65627562f1b4d1699461d0fed101daa3c5ec9e2785348ece9469b1e38a8'
readonly VPIO_PRESTOP_SHA256='c707e10d126b6421cdcdf94fce276fb972871d8d30ff415f7d2bffb195cef5a8'
readonly VPIO_REPAIR_SHA256='e6312897f09d3824e521f9eb2960d5dc6cf8ecf3e1a477920e7c61c0acdf30e4'
readonly VPIO_FINAL_SHA256='392e239499517333fc25c99d4420a0b786e7267dc76ad23c884b4b0f9213f2b7'
readonly GUARDIAN_STDOUT_SHA256='4620ef643e00c00cf5417a035ce17312651b2093ff653b4f5fe58cb337b5be34'

# This command has one possible mutation: an exclusive, same-filesystem rename of the exact
# never-loaded driver directory into the already-reserved root-private transaction namespace.
# It is idempotent for the exact post-rename state and never edits the forensic journal/log.
readonly ROOT_RESCUE_COMMAND='set -eu
umask 077
unset CDPATH ENV BASH_ENV IFS PERL5LIB PERL5OPT RUBYLIB RUBYOPT PYTHONHOME PYTHONPATH
unset DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH SDKROOT TOOLCHAINS RUSTFLAGS RUSTDOCFLAGS RUSTC_WRAPPER
LC_ALL=C
PATH=/usr/bin:/bin:/usr/sbin:/sbin
HOME=/var/root
USER=root
LOGNAME=root
export LC_ALL PATH HOME USER LOGNAME
[ "$(/usr/bin/id -u)" = "0" ]

support="/Library/Application Support/opensteamer-local-mono-trial-v1"
controller="$support/opensteamer-local-mono-trial-controller"
pin="$support/controller.sha256"
log="$support/root-broker.log"
transaction="$support/private-transaction-prep-L1Ciab"
journal="$transaction/journal.log"
identity="$transaction/driver.identity"
failed="$transaction/OpensteamerVirtualMicrophone.driver.failed"
hold="$transaction/OpensteamerVirtualMicrophone.driver.hold"
abandoned="$transaction/OpensteamerVirtualMicrophone.driver.abandoned"
sealed="$support/sealed-prep-L1Ciab"
socket="$support/broker-prep-L1Ciab.sock"
product="/Library/Audio/Plug-Ins/HAL/OpensteamerVirtualMicrophone.driver"
shared_lock="/Users/ahmed/Library/Application Support/com.elamin.AudioStreamer.CaptureServer.runtime/worldwide-host.lock"

require_empty_xattr_acl() {
    node=$1
    node_xattrs=$(/usr/bin/xattr "$node")
    [ -z "$node_xattrs" ]
    node_acl=$(/bin/ls -lde "$node")
    node_acl_lines=$(/usr/bin/printf "%s\n" "$node_acl" | /usr/bin/wc -l | /usr/bin/tr -d "[:space:]")
    [ "$node_acl_lines" = "1" ]
}

require_closed_tree() {
    closed_tree=$1
    set +e
    closed_openers=$(/usr/sbin/lsof -Fn +D "$closed_tree" 2>/dev/null)
    closed_status=$?
    set -e
    [ "$closed_status" = "1" ]
    [ -z "$closed_openers" ]
}

require_coreaudiod() {
    core_pids=$(/usr/bin/pgrep -x coreaudiod)
    [ "$core_pids" = "179" ]
    core_uid=$(/bin/ps -p 179 -o uid= | /usr/bin/tr -d "[:space:]")
    core_command=$(/bin/ps -p 179 -o command=)
    core_start=$(/bin/ps -p 179 -o lstart= | /usr/bin/awk "{\$1=\$1; print}")
    [ "$core_uid" = "202" ]
    [ "$core_command" = "/usr/sbin/coreaudiod" ]
    [ "$core_start" = "Fri Jul 31 11:03:20 2026" ]
}

require_driver() {
    bundle=$1
    [ -d "$bundle" ] && [ ! -L "$bundle" ]
    for driver_directory in \
        "$bundle/Contents" "$bundle/Contents/MacOS" "$bundle/Contents/Resources" \
        "$bundle/Contents/Resources/en.lproj" "$bundle/Contents/_CodeSignature"; do
        [ -d "$driver_directory" ] && [ ! -L "$driver_directory" ]
    done
    for driver_regular in \
        "$bundle/Contents/Info.plist" \
        "$bundle/Contents/MacOS/OpensteamerVirtualMicrophone" \
        "$bundle/Contents/Resources/APPLE_SAMPLE_LICENSE.txt" \
        "$bundle/Contents/Resources/en.lproj/Localizable.strings" \
        "$bundle/Contents/_CodeSignature/CodeResources"; do
        [ -f "$driver_regular" ] && [ ! -L "$driver_regular" ]
    done
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$bundle")" = "16777230:27093391:0:0:3:755:96:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$bundle/Contents")" = "16777230:27093392:0:0:6:755:192:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$bundle/Contents/Info.plist")" = "16777230:27093401:0:0:1:644:1165:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$bundle/Contents/MacOS")" = "16777230:27093395:0:0:3:755:96:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$bundle/Contents/MacOS/OpensteamerVirtualMicrophone")" = "16777230:27093396:0:0:1:755:169792:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$bundle/Contents/Resources")" = "16777230:27093397:0:0:4:755:128:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$bundle/Contents/Resources/APPLE_SAMPLE_LICENSE.txt")" = "16777230:27093400:0:0:1:644:1053:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$bundle/Contents/Resources/en.lproj")" = "16777230:27093398:0:0:3:755:96:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$bundle/Contents/Resources/en.lproj/Localizable.strings")" = "16777230:27093399:0:0:1:644:202:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$bundle/Contents/_CodeSignature")" = "16777230:27093393:0:0:3:755:96:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$bundle/Contents/_CodeSignature/CodeResources")" = "16777230:27093394:0:0:1:644:2841:0" ]
    driver_entries=$(/usr/bin/find "$bundle" -xdev -print | /usr/bin/sort)
    driver_expected=$(/usr/bin/printf "%s\n" \
        "$bundle" \
        "$bundle/Contents" \
        "$bundle/Contents/Info.plist" \
        "$bundle/Contents/MacOS" \
        "$bundle/Contents/MacOS/OpensteamerVirtualMicrophone" \
        "$bundle/Contents/Resources" \
        "$bundle/Contents/Resources/APPLE_SAMPLE_LICENSE.txt" \
        "$bundle/Contents/Resources/en.lproj" \
        "$bundle/Contents/Resources/en.lproj/Localizable.strings" \
        "$bundle/Contents/_CodeSignature" \
        "$bundle/Contents/_CodeSignature/CodeResources" | /usr/bin/sort)
    [ "$driver_entries" = "$driver_expected" ]
    [ "$(/usr/bin/shasum -a 256 "$bundle/Contents/Info.plist" | /usr/bin/cut -d " " -f 1)" = "6e2fa0980cd27498ffe1075bcd439e61fcb0b6d38827ca2dadc3a7d6872e84e1" ]
    [ "$(/usr/bin/shasum -a 256 "$bundle/Contents/MacOS/OpensteamerVirtualMicrophone" | /usr/bin/cut -d " " -f 1)" = "e78bfe1080660de99769d0f9313459fb22a08863d4ade52d25921db871383745" ]
    [ "$(/usr/bin/shasum -a 256 "$bundle/Contents/Resources/APPLE_SAMPLE_LICENSE.txt" | /usr/bin/cut -d " " -f 1)" = "63202ae6ab294069b6f77114f0cce8f35531bbb75355f1d96c8db68f949acdc5" ]
    [ "$(/usr/bin/shasum -a 256 "$bundle/Contents/Resources/en.lproj/Localizable.strings" | /usr/bin/cut -d " " -f 1)" = "4798181065dbb851f0de518be396d6d4f8a465158923adf16bbf91bcb826a166" ]
    [ "$(/usr/bin/shasum -a 256 "$bundle/Contents/_CodeSignature/CodeResources" | /usr/bin/cut -d " " -f 1)" = "92c1b53f174dd64d1835fa9b2ecbddd84eac815ad43bbe231090d214b1cc9731" ]
    for driver_node in \
        "$bundle" "$bundle/Contents" "$bundle/Contents/Info.plist" \
        "$bundle/Contents/MacOS" "$bundle/Contents/MacOS/OpensteamerVirtualMicrophone" \
        "$bundle/Contents/Resources" "$bundle/Contents/Resources/APPLE_SAMPLE_LICENSE.txt" \
        "$bundle/Contents/Resources/en.lproj" \
        "$bundle/Contents/Resources/en.lproj/Localizable.strings" \
        "$bundle/Contents/_CodeSignature" "$bundle/Contents/_CodeSignature/CodeResources"; do
        require_empty_xattr_acl "$driver_node"
    done
    /usr/bin/codesign --verify --strict --all-architectures "$bundle"
    signature=$(/usr/bin/codesign -d --verbose=4 "$bundle" 2>&1)
    [ "$(/usr/bin/printf "%s\n" "$signature" | /usr/bin/grep -F -x -c "Identifier=com.elamin.opensteamer.VirtualMicrophoneDriver")" = "1" ]
    [ "$(/usr/bin/printf "%s\n" "$signature" | /usr/bin/grep -F -x -c "TeamIdentifier=MSMG8CJLB3")" = "1" ]
    [ "$(/usr/bin/printf "%s\n" "$signature" | /usr/bin/grep -F -x -c "CDHash=136282fbe7626c26618738e739eea2b0df2b59d5")" = "1" ]
    [ "$(/usr/bin/printf "%s\n" "$signature" | /usr/bin/grep -F -x -c "Authority=Apple Development: Ahmed Elamin (92LVX32M8K)")" = "1" ]
    [ "$(/usr/bin/printf "%s\n" "$signature" | /usr/bin/grep -F -c "flags=0x10000(runtime)")" = "1" ]
    require_closed_tree "$bundle"
}

[ -d "$support" ] && [ ! -L "$support" ]
[ -f "$controller" ] && [ ! -L "$controller" ]
[ -f "$pin" ] && [ ! -L "$pin" ]
[ -f "$log" ] && [ ! -L "$log" ]
[ -d "$transaction" ] && [ ! -L "$transaction" ]
[ -f "$journal" ] && [ ! -L "$journal" ]
[ -f "$identity" ] && [ ! -L "$identity" ]
[ -d "$sealed" ] && [ ! -L "$sealed" ]
[ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$support")" = "16777230:27093234:0:0:8:711:256:0" ]
[ "$(/usr/bin/find "$support" -xdev -mindepth 1 -maxdepth 1 -print | /usr/bin/sort)" = "$(/usr/bin/printf "%s\n" "$controller" "$pin" "$log" "$transaction" "$sealed" "$socket" | /usr/bin/sort)" ]
[ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$controller")" = "16777230:27093235:0:0:1:500:1443880:0" ]
[ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$pin")" = "16777230:27093236:0:0:1:400:65:0" ]
[ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$log")" = "16777230:27093237:0:0:1:600:357:0" ]
[ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$sealed")" = "16777230:27093240:0:0:9:511:288:0" ]
[ -S "$socket" ] && [ ! -L "$socket" ]
[ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$socket")" = "16777230:27093415:501:20:1:600:0:0" ]
[ "$(/usr/bin/shasum -a 256 "$controller" | /usr/bin/cut -d " " -f 1)" = "b2da40fa1a85cf00b9dfd84ec90b5ad71cba255c1cd4414e307e4596934b7d2e" ]
[ "$(/usr/bin/shasum -a 256 "$pin" | /usr/bin/cut -d " " -f 1)" = "070cbb6a1bde9c0230fb1e8a27aef3bc4811be0c25a356448ca2aa1836520c54" ]
[ "$(/bin/cat "$pin")" = "b2da40fa1a85cf00b9dfd84ec90b5ad71cba255c1cd4414e307e4596934b7d2e" ]
[ "$(/usr/bin/shasum -a 256 "$log" | /usr/bin/cut -d " " -f 1)" = "21c50e4f479513403366762e57aee476c92f22678aa1a5c8a6b4053bbb84e708" ]
[ "$(/usr/bin/shasum -a 256 "$journal" | /usr/bin/cut -d " " -f 1)" = "fe6e6d31b12e9f3216b0d9fc059fd962628a8709374f471abb8009fe459c2d7f" ]
[ "$(/usr/bin/shasum -a 256 "$identity" | /usr/bin/cut -d " " -f 1)" = "24230285158c297e64c6e6480108148cab0e36b5fb6b02fb6e1a167a61ad2f25" ]
[ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$journal")" = "16777230:27093239:0:0:1:600:429:0" ]
[ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$identity")" = "16777230:27093414:0:0:1:600:108:0" ]
[ "$(/bin/cat "$identity")" = "device=16777230
inode=27093391
tree_sha256=48089061c4333dc29201f48eaa3b4e889fde99174dd99ffeaed414d9d98b3aa5" ]

sealed_controller="$sealed/opensteamer-local-mono-trial-controller"
sealed_pin="$sealed/controller.sha256"
sealed_host="$sealed/opensteamer Host.app"
sealed_mirror="$sealed/physical-blackhole-microphone-probe"
sealed_vpio="$sealed/opensteamer-public-vpio-probe"
sealed_guardian="$sealed/opensteamer-v7-default-route-guardian"
sealed_proxy="$sealed/uid501-proxy.identity"
[ -d "$sealed_host" ] && [ ! -L "$sealed_host" ]
for sealed_regular in "$sealed_controller" "$sealed_pin" "$sealed_mirror" "$sealed_vpio" "$sealed_guardian" "$sealed_proxy"; do
    [ -f "$sealed_regular" ] && [ ! -L "$sealed_regular" ]
done
[ "$(/usr/bin/find "$sealed" -xdev -mindepth 1 -maxdepth 1 -print | /usr/bin/sort)" = "$(/usr/bin/printf "%s\n" "$sealed_controller" "$sealed_pin" "$sealed_host" "$sealed_mirror" "$sealed_vpio" "$sealed_guardian" "$sealed_proxy" | /usr/bin/sort)" ]
[ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$sealed_host")" = "16777230:27093251:0:0:3:755:96:0" ]
[ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$sealed_mirror")" = "16777230:27093406:0:0:1:555:989184:0" ]
[ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$sealed_vpio")" = "16777230:27093407:0:0:1:555:154912:0" ]
[ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$sealed_guardian")" = "16777230:27093408:0:0:1:555:258696:0" ]
[ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$sealed_controller")" = "16777230:27093409:0:0:1:555:1443880:0" ]
[ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$sealed_pin")" = "16777230:27093410:0:0:1:444:65:0" ]
[ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$sealed_proxy")" = "16777230:27093416:0:0:1:444:97:0" ]
[ "$(/usr/bin/shasum -a 256 "$sealed_mirror" | /usr/bin/cut -d " " -f 1)" = "403d1bf8aed711dba05c0ed575af4620ee8fa2454e6b50b6d51d07f261703d33" ]
[ "$(/usr/bin/shasum -a 256 "$sealed_vpio" | /usr/bin/cut -d " " -f 1)" = "0ec9e1a0cc5f253cc569134ce2be024a7f3ae6ad211fa7d20fe6436c0bac84c8" ]
[ "$(/usr/bin/shasum -a 256 "$sealed_guardian" | /usr/bin/cut -d " " -f 1)" = "72ef50156a0154e3b6c9a84557f3c192b67ec69f7a9747476826fb9aa3d4509c" ]
[ "$(/usr/bin/shasum -a 256 "$sealed_controller" | /usr/bin/cut -d " " -f 1)" = "b2da40fa1a85cf00b9dfd84ec90b5ad71cba255c1cd4414e307e4596934b7d2e" ]
[ "$(/usr/bin/shasum -a 256 "$sealed_pin" | /usr/bin/cut -d " " -f 1)" = "070cbb6a1bde9c0230fb1e8a27aef3bc4811be0c25a356448ca2aa1836520c54" ]
[ "$(/usr/bin/shasum -a 256 "$sealed_proxy" | /usr/bin/cut -d " " -f 1)" = "b2b881e38bbf28e2024cec224dfb9052ac513acd23dcdc46840448c842985bf4" ]
[ "$(/bin/cat "$sealed_proxy")" = "schema=opensteamer.local-mono-root-proxy.v1
proxy_pid=21660
proxy_start=Sun Aug 16 14:34:47 2026" ]

for root_plain in "$support" "$controller" "$pin" "$log" "$transaction" "$journal" "$identity" "$sealed" "$sealed_host" "$sealed_mirror" "$sealed_vpio" "$sealed_guardian" "$sealed_controller" "$sealed_pin" "$sealed_proxy"; do
    require_empty_xattr_acl "$root_plain"
done
socket_acl=$(/bin/ls -lde "$socket")
[ "$(/usr/bin/printf "%s\n" "$socket_acl" | /usr/bin/wc -l | /usr/bin/tr -d "[:space:]")" = "1" ]
set +e
socket_xattrs=$(/usr/bin/xattr "$socket" 2>&1)
socket_xattr_status=$?
set -e
socket_xattr_expected=$(/usr/bin/printf "xattr: [Errno 102] Operation not supported on socket: \047%s\047" "$socket")
[ "$socket_xattr_status" = "1" ]
[ "$socket_xattrs" = "$socket_xattr_expected" ]
[ "$(/usr/bin/printf "%s" "$socket_xattrs" | /usr/bin/wc -c | /usr/bin/tr -d "[:space:]")" = "140" ]
[ "$(/usr/bin/printf "%s" "$socket_xattrs" | /usr/bin/shasum -a 256 | /usr/bin/cut -d " " -f 1)" = "0a6694842c8455a02e3721380bbdb2945e63e78ae2c221846bebbb854198cdaa" ]
require_closed_tree "$support"

for old_evidence in \
    "/Library/Application Support/opensteamer-local-mono-trial-v1.failed-root-prepare-pin-mode-L1Ciab" \
    "/Library/Application Support/opensteamer-local-mono-trial-v1.failed-uid-admission-L1Ciab" \
    "/Library/Application Support/opensteamer-local-mono-trial-v1.failed-candidate-gate-coderesources-mode-L1Ciab"; do
    [ -d "$old_evidence" ] && [ ! -L "$old_evidence" ]
    require_empty_xattr_acl "$old_evidence"
    require_closed_tree "$old_evidence"
done
[ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "/Library/Application Support/opensteamer-local-mono-trial-v1.failed-root-prepare-pin-mode-L1Ciab")" = "16777230:27006986:0:0:7:711:224:0" ]
[ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "/Library/Application Support/opensteamer-local-mono-trial-v1.failed-uid-admission-L1Ciab")" = "16777230:27016896:0:0:8:711:256:0" ]
[ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "/Library/Application Support/opensteamer-local-mono-trial-v1.failed-candidate-gate-coderesources-mode-L1Ciab")" = "16777230:27021963:0:0:8:711:256:0" ]

process_snapshot=$(/bin/ps -wwaxo comm=)
set +e
trial_processes=$(/usr/bin/printf "%s\n" "$process_snapshot" | /usr/bin/grep -E "(^|/)(opensteamer-local-mono-trial-controller|opensteamer-v7-default-route-guardian)$")
trial_process_status=$?
set -e
[ "$trial_process_status" = "1" ] && [ -z "$trial_processes" ]
require_coreaudiod
require_coreaudiod

if [ -d "$product" ] && [ ! -L "$product" ] && [ ! -e "$failed" ] && [ ! -L "$failed" ]; then
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$transaction")" = "16777230:27093238:0:0:4:700:128:0" ]
    [ "$(/usr/bin/find "$transaction" -xdev -mindepth 1 -maxdepth 1 -print | /usr/bin/sort)" = "$(/usr/bin/printf "%s\n" "$identity" "$journal" | /usr/bin/sort)" ]
    [ ! -e "$hold" ] && [ ! -L "$hold" ]
    [ ! -e "$abandoned" ] && [ ! -L "$abandoned" ]
    require_driver "$product"
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$shared_lock")" = "16777230:10835208:501:20:1:600:122:0" ]
    [ "$(/usr/bin/shasum -a 256 "$shared_lock" | /usr/bin/cut -d " " -f 1)" = "ad1d80772b48f16874718f5ae18aa7aca2a82b9dfbb962f14ae57d1195463fbb" ]
    [ "$(/bin/cat "$shared_lock")" = "OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1
pid=58067
nonce=d487c3d7020269c12dedaa2274eac704955b71922c7f8e0e7fff13f5b7670fc0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" /usr/bin/perl)" = "16777230:1152921500312572547:0:0:1:755:101840:524320" ]
    [ "$(/usr/bin/shasum -a 256 /usr/bin/perl | /usr/bin/cut -d " " -f 1)" = "abda2bfd23a6c9a8e57adf2291f0aea4abd8faf440558ee49fe4ced55e8d9ad0" ]
    /usr/bin/codesign --verify --strict --all-architectures /usr/bin/perl
    /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/var/root USER=root LOGNAME=root \
        /usr/bin/perl -e "
            sub capture {
                pipe(my \$reader, my \$writer) or die \"pipe\";
                my \$child = fork();
                die \"fork\" unless defined \$child;
                if (\$child == 0) {
                    close(\$reader);
                    open(STDOUT, \">&\", \$writer) or exit 250;
                    open(STDERR, \">&\", \$writer) or exit 251;
                    exec(@_);
                    exit 252;
                }
                close(\$writer);
                local \$/;
                my \$output = <\$reader> // \"\";
                close(\$reader) or die \"read-close\";
                waitpid(\$child, 0) == \$child or die \"wait\";
                return (\$?, \$output);
            }
            sub bounded_capture {
                my @result = capture(@_);
                die \"capture-output\" if length(\$result[1]) > 1048576;
                return @result;
            }
            sub require_coreaudiod {
                my (\$pid_status, \$pid_output) =
                    bounded_capture(\"/usr/bin/pgrep\", \"-x\", \"coreaudiod\");
                die \"coreaudiod-pid\" unless
                    \$pid_status == 0 && \$pid_output eq \"179\\n\";
                my (\$uid_status, \$uid_output) =
                    bounded_capture(\"/bin/ps\", \"-p\", \"179\", \"-o\", \"uid=\");
                \$uid_output =~ s/\\s+//g;
                die \"coreaudiod-uid\" unless \$uid_status == 0 && \$uid_output eq \"202\";
                my (\$command_status, \$command_output) =
                    bounded_capture(\"/bin/ps\", \"-p\", \"179\", \"-o\", \"command=\");
                \$command_output =~ s/\\n\\z//;
                die \"coreaudiod-command\" unless
                    \$command_status == 0 && \$command_output eq \"/usr/sbin/coreaudiod\";
                my (\$start_status, \$start_output) =
                    bounded_capture(\"/bin/ps\", \"-p\", \"179\", \"-o\", \"lstart=\");
                \$start_output =~ s/^\\s+//;
                \$start_output =~ s/\\s+\\z//;
                \$start_output =~ s/\\s+/ /g;
                die \"coreaudiod-start\" unless
                    \$start_status == 0 &&
                    \$start_output eq \"Fri Jul 31 11:03:20 2026\";
            }
            sub require_exact_driver {
                my (\$bundle) = @_;
                my @specifications = (
                    [\$bundle, 27093391, 0040000, 3, 0, 0, 0755, 96],
                    [\"\$bundle/Contents\", 27093392, 0040000, 6, 0, 0, 0755, 192],
                    [\"\$bundle/Contents/Info.plist\", 27093401, 0100000, 1, 0, 0, 0644, 1165],
                    [\"\$bundle/Contents/MacOS\", 27093395, 0040000, 3, 0, 0, 0755, 96],
                    [\"\$bundle/Contents/MacOS/OpensteamerVirtualMicrophone\", 27093396, 0100000, 1, 0, 0, 0755, 169792],
                    [\"\$bundle/Contents/Resources\", 27093397, 0040000, 4, 0, 0, 0755, 128],
                    [\"\$bundle/Contents/Resources/APPLE_SAMPLE_LICENSE.txt\", 27093400, 0100000, 1, 0, 0, 0644, 1053],
                    [\"\$bundle/Contents/Resources/en.lproj\", 27093398, 0040000, 3, 0, 0, 0755, 96],
                    [\"\$bundle/Contents/Resources/en.lproj/Localizable.strings\", 27093399, 0100000, 1, 0, 0, 0644, 202],
                    [\"\$bundle/Contents/_CodeSignature\", 27093393, 0040000, 3, 0, 0, 0755, 96],
                    [\"\$bundle/Contents/_CodeSignature/CodeResources\", 27093394, 0100000, 1, 0, 0, 0644, 2841]
                );
                for my \$specification (@specifications) {
                    my (\$path, \$kind, \$links, \$uid, \$gid, \$permissions, \$size) =
                        (\$specification->[0], \$specification->[2], \$specification->[3],
                         \$specification->[4], \$specification->[5], \$specification->[6],
                         \$specification->[7]);
                    my @node = lstat(\$path);
                    die \"driver-node\" unless @node &&
                        \$node[0] == 16777230 && \$node[1] == \$specification->[1] &&
                        (\$node[2] & 0170000) == \$kind && \$node[3] == \$links &&
                        \$node[4] == \$uid && \$node[5] == \$gid &&
                        (\$node[2] & 07777) == \$permissions && \$node[7] == \$size;
                }
                my (\$find_status, \$find_output) =
                    bounded_capture(\"/usr/bin/find\", \$bundle, \"-xdev\", \"-print\");
                die \"driver-find\" unless \$find_status == 0;
                my @actual = sort grep { length(\$_) } split(/\\n/, \$find_output, -1);
                my @expected = sort map { \$_->[0] } @specifications;
                die \"driver-tree\" unless @actual == @expected &&
                    join(\"\\n\", @actual) eq join(\"\\n\", @expected);
                my @hashes = (
                    [\"\$bundle/Contents/Info.plist\", \"6e2fa0980cd27498ffe1075bcd439e61fcb0b6d38827ca2dadc3a7d6872e84e1\"],
                    [\"\$bundle/Contents/MacOS/OpensteamerVirtualMicrophone\", \"e78bfe1080660de99769d0f9313459fb22a08863d4ade52d25921db871383745\"],
                    [\"\$bundle/Contents/Resources/APPLE_SAMPLE_LICENSE.txt\", \"63202ae6ab294069b6f77114f0cce8f35531bbb75355f1d96c8db68f949acdc5\"],
                    [\"\$bundle/Contents/Resources/en.lproj/Localizable.strings\", \"4798181065dbb851f0de518be396d6d4f8a465158923adf16bbf91bcb826a166\"],
                    [\"\$bundle/Contents/_CodeSignature/CodeResources\", \"92c1b53f174dd64d1835fa9b2ecbddd84eac815ad43bbe231090d214b1cc9731\"]
                );
                for my \$hash (@hashes) {
                    my (\$hash_status, \$hash_output) =
                        bounded_capture(\"/usr/bin/shasum\", \"-a\", \"256\", \$hash->[0]);
                    die \"driver-hash\" unless \$hash_status == 0 &&
                        substr(\$hash_output, 0, 64) eq \$hash->[1] &&
                        substr(\$hash_output, 64) eq \"  \$hash->[0]\\n\";
                }
                my (\$verify_status, \$verify_output) = bounded_capture(
                    \"/usr/bin/codesign\", \"--verify\", \"--strict\",
                    \"--all-architectures\", \$bundle);
                die \"driver-signature\" unless
                    \$verify_status == 0 && \$verify_output eq \"\";
                my (\$display_status, \$display_output) = bounded_capture(
                    \"/usr/bin/codesign\", \"-d\", \"--verbose=4\", \$bundle);
                die \"driver-designated-identity\" unless \$display_status == 0 &&
                    (() = \$display_output =~ /^Identifier=com[.]elamin[.]opensteamer[.]VirtualMicrophoneDriver\$/mg) == 1 &&
                    (() = \$display_output =~ /^TeamIdentifier=MSMG8CJLB3\$/mg) == 1 &&
                    (() = \$display_output =~ /^CDHash=136282fbe7626c26618738e739eea2b0df2b59d5\$/mg) == 1 &&
                    (() = \$display_output =~ /^Authority=Apple Development: Ahmed Elamin [(]92LVX32M8K[)]\$/mg) == 1 &&
                    (() = \$display_output =~ /flags=0x10000[(]runtime[)]/g) == 1;
            }
            my (\$lock, \$source, \$destination) = @ARGV;
            sysopen(my \$handle, \$lock, 0x100) or die \"lock-open\";
            my @descriptor = stat(\$handle);
            my @named = lstat(\$lock);
            die \"lock-identity\" unless @descriptor && @named &&
                \$descriptor[0] == 16777230 && \$descriptor[1] == 10835208 &&
                \$named[0] == \$descriptor[0] && \$named[1] == \$descriptor[1] &&
                \$descriptor[3] == 1 && \$descriptor[4] == 501 && \$descriptor[5] == 20 &&
                (\$descriptor[2] & 0170000) == 0100000 &&
                (\$descriptor[2] & 07777) == 0600 && \$descriptor[7] == 122;
            my \$text = \"\";
            my \$count = sysread(\$handle, \$text, 512);
            die \"lock-read\" unless defined(\$count) && \$count == 122 &&
                \$text eq \"OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1\\npid=58067\\nnonce=d487c3d7020269c12dedaa2274eac704955b71922c7f8e0e7fff13f5b7670fc0\\n\";
            flock(\$handle, 6) or die \"lock-owned\";
            require_exact_driver(\$source);
            my (\$v6_status, \$v6_output) = bounded_capture(\"/bin/launchctl\", \"print\", \"gui/501/org.example.opensteamer.worldwide\");
            die \"v6-service\" unless \$v6_status == (113 << 8) &&
                \$v6_output eq \"Bad request.\\nCould not find service \\\"org.example.opensteamer.worldwide\\\" in domain for user gui: 501\\n\";
            my (\$legacy_status, \$legacy_output) = bounded_capture(\"/bin/launchctl\", \"print\", \"gui/501/com.elamin.audiostreamer.worldwide\");
            die \"legacy-service\" unless \$legacy_status == (113 << 8) &&
                \$legacy_output eq \"Bad request.\\nCould not find service \\\"com.elamin.audiostreamer.worldwide\\\" in domain for user gui: 501\\n\";
            my (\$capture_status, \$capture_output) = bounded_capture(\"/usr/bin/pgrep\", \"-x\", \"CaptureServer\");
            die \"capture-process\" unless \$capture_status == (1 << 8) && \$capture_output eq \"\";
            my (\$lsof_status, \$lsof_output) =
                bounded_capture(\"/usr/sbin/lsof\", \"-Fn\", \"+D\", \$source);
            die \"driver-openers\" unless
                \$lsof_status == (1 << 8) && \$lsof_output eq \"\";
            require_coreaudiod();
            my (\$lsof_recheck_status, \$lsof_recheck_output) =
                bounded_capture(\"/usr/sbin/lsof\", \"-Fn\", \"+D\", \$source);
            die \"driver-openers-recheck\" unless
                \$lsof_recheck_status == (1 << 8) && \$lsof_recheck_output eq \"\";
            require_coreaudiod();
            system(\"/bin/mv\", \"-n\", \$source, \$destination) == 0 or die \"move\";
            require_coreaudiod();
            die \"source-remained\" if lstat(\$source);
            my @moved = lstat(\$destination);
            die \"destination-identity\" unless @moved && \$moved[0] == 16777230 &&
                \$moved[1] == 27093391 && (\$moved[2] & 0170000) == 0040000 &&
                \$moved[4] == 0 && \$moved[5] == 0 && (\$moved[2] & 07777) == 0755;
            require_exact_driver(\$destination);
            my (\$moved_lsof_status, \$moved_lsof_output) =
                bounded_capture(\"/usr/sbin/lsof\", \"-Fn\", \"+D\", \$destination);
            die \"moved-driver-openers\" unless
                \$moved_lsof_status == (1 << 8) && \$moved_lsof_output eq \"\";
            system(\"/bin/sync\") == 0 or die \"sync\";
            require_coreaudiod();
            flock(\$handle, 8) or die \"unlock\";
            close(\$handle) or die \"lock-close\";
        " "$shared_lock" "$product" "$failed"
    [ ! -e "$product" ] && [ ! -L "$product" ]
    require_driver "$failed"
    rescue_state=moved
elif [ ! -e "$product" ] && [ ! -L "$product" ] && [ -d "$failed" ] && [ ! -L "$failed" ]; then
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$transaction")" = "16777230:27093238:0:0:5:700:160:0" ]
    [ "$(/usr/bin/find "$transaction" -xdev -mindepth 1 -maxdepth 1 -print | /usr/bin/sort)" = "$(/usr/bin/printf "%s\n" "$identity" "$journal" "$failed" | /usr/bin/sort)" ]
    [ ! -e "$hold" ] && [ ! -L "$hold" ]
    [ ! -e "$abandoned" ] && [ ! -L "$abandoned" ]
    require_driver "$failed"
    rescue_state=already-moved
else
    exit 79
fi

/bin/sync
[ ! -e "$product" ] && [ ! -L "$product" ]
require_driver "$failed"
[ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$transaction")" = "16777230:27093238:0:0:5:700:160:0" ]
[ "$(/usr/bin/find "$transaction" -xdev -mindepth 1 -maxdepth 1 -print | /usr/bin/sort)" = "$(/usr/bin/printf "%s\n" "$identity" "$journal" "$failed" | /usr/bin/sort)" ]
require_coreaudiod
require_coreaudiod
require_closed_tree "$support"
/usr/bin/printf "LOCAL_MONO_RESCUE_ROOT_OK state=%s coreaudiod_pid=179 coreaudiod_start=Fri_Jul_31_11:03:20_2026\n" "$rescue_state"'

typeset -g USER_EVIDENCE_STATE=''
typeset -g V6_STATE=''
typeset -gi ADMISSION_PROVED=0
typeset -g LOCK_GENERATION_NONCE=''
typeset -g OBSERVED_V6_FINGERPRINT=''
typeset -g ADMITTED_V6_FINGERPRINT=''
typeset -gi ROOT_RESCUE_PROVED=0

fail() {
    print -u2 -- "local-mono exact rescue: $*"
    exit 1
}

require_absent() {
    local target_path="$1"
    [[ ! -e "$target_path" && ! -L "$target_path" ]] ||
        fail "expected path is present: $target_path"
}

require_hash() {
    local target_path="$1"
    local expected="$2"
    [[ -f "$target_path" && ! -L "$target_path" ]] ||
        fail "pinned regular file is unavailable: $target_path"
    [[ "$(/usr/bin/shasum -a 256 "$target_path" | /usr/bin/awk '{print $1}')" == "$expected" ]] ||
        fail "pinned file changed: $target_path"
}

require_plain_node() {
    local target_path="$1"
    local expected="$2"
    [[ "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$target_path" 2>/dev/null)" ==
       "$expected" ]] || fail "node identity changed: $target_path"
    local xattrs acl
    xattrs=$(/usr/bin/xattr "$target_path") || fail "could not inspect xattrs: $target_path"
    [[ -z "$xattrs" ]] || fail "unexpected xattrs: $target_path"
    acl=$(/bin/ls -lde "$target_path") || fail "could not inspect ACL: $target_path"
    [[ "$(print -r -- "$acl" | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" == '1' ]] ||
        fail "unexpected ACL: $target_path"
}

require_exact_children() {
    local root="$1"
    shift
    local actual expected
    actual=$(/usr/bin/find "$root" -xdev -mindepth 1 -maxdepth 1 -print | /usr/bin/sort) ||
        fail "could not enumerate exact directory: $root"
    expected=$(/usr/bin/printf '%s\n' "$@" | /usr/bin/sort)
    [[ "$actual" == "$expected" ]] || fail "exact directory children changed: $root"
}

socket_xattr_result_is_expected() {
    [[ "$#" == '2' && "$1" == '1' &&
       "$2" == "xattr: [Errno 102] Operation not supported on socket: '$ROOT_SOCKET'" &&
       "${#2}" == '140' &&
       "$(print -rn -- "$2" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')" ==
           '0a6694842c8455a02e3721380bbdb2945e63e78ae2c221846bebbb854198cdaa' ]]
}

self_test_socket_xattr_classifier() {
    local expected="xattr: [Errno 102] Operation not supported on socket: '$ROOT_SOCKET'"
    socket_xattr_result_is_expected 1 "$expected" ||
        fail 'socket xattr classifier rejected exact ENOTSUP evidence'
    if socket_xattr_result_is_expected 0 "$expected" ||
       socket_xattr_result_is_expected 1 "${expected}x" ||
       socket_xattr_result_is_expected 1 'xattr: [Errno 1] Operation not permitted'; then
        fail 'socket xattr classifier accepted an invalid mutant'
    fi
}

require_closed_tree() {
    local root="$1"
    local openers lsof_status
    set +e
    openers=$(/usr/sbin/lsof -Fn +D "$root" 2>/dev/null)
    lsof_status=$?
    set -e
    [[ "$lsof_status" == '1' && -z "$openers" ]] || fail "tree has an opener: $root"
}

require_closed_file() {
    local target_path="$1"
    local openers lsof_status
    set +e
    openers=$(/usr/sbin/lsof -Fn -- "$target_path" 2>/dev/null)
    lsof_status=$?
    set -e
    [[ "$lsof_status" == '1' && -z "$openers" ]] ||
        fail "file has an opener: $target_path"
}

require_process_absent() {
    local name="$1"
    local pids pgrep_status
    set +e
    pids=$(/usr/bin/pgrep -x "$name" 2>/dev/null)
    pgrep_status=$?
    set -e
    [[ "$pgrep_status" == '1' && -z "$pids" ]] || fail "unexpected process exists: $name"
}

require_local_trial_processes_absent() {
    local snapshot matches process_status
    snapshot=$(/bin/ps -wwaxo comm=) || fail 'could not enumerate mapped executables'
    set +e
    matches=$(print -r -- "$snapshot" | /usr/bin/grep -E \
        '(^|/)(opensteamer-local-mono-trial-controller|opensteamer-v7-default-route-guardian)$')
    process_status=$?
    set -e
    [[ "$process_status" == '1' && -z "$matches" ]] ||
        fail "local-trial executable is still mapped: $matches"
}

require_coreaudiod_unchanged() {
    local pids uid command start
    pids=$(/usr/bin/pgrep -x coreaudiod) || fail 'coreaudiod enumeration failed'
    [[ "$pids" == '179' ]] || fail 'coreaudiod PID set changed'
    uid=$(/bin/ps -p 179 -o uid= | /usr/bin/tr -d '[:space:]')
    command=$(/bin/ps -p 179 -o command=)
    start=$(/bin/ps -p 179 -o lstart= | /usr/bin/awk '{$1=$1; print}')
    [[ "$uid" == '202' && "$command" == '/usr/sbin/coreaudiod' &&
       "$start" == 'Fri Jul 31 11:03:20 2026' ]] || fail 'coreaudiod identity changed'
}

require_service_absent() {
    local label="$1"
    local output launch_status expected
    set +e
    output=$(/bin/launchctl print "gui/501/$label" 2>&1)
    launch_status=$?
    set -e
    expected=$'Bad request.\nCould not find service "'"$label"$'" in domain for user gui: 501'
    [[ "$launch_status" == '113' && "$output" == "$expected" ]] ||
        fail "launchd did not exactly prove service absence: $label"
}

require_legacy_offline() {
    require_service_absent "$LEGACY_LABEL"
    local disabled
    disabled=$(/bin/launchctl print-disabled gui/501) ||
        fail 'could not inspect protected legacy disabled override'
    [[ "$(print -r -- "$disabled" | /usr/bin/grep -F -x -c \
        $'\t\t"com.elamin.audiostreamer.worldwide" => disabled')" == '1' ]] ||
        fail 'protected legacy launchd label is not exactly disabled'
}

require_shared_lock_unowned() {
    require_plain_node "$SHARED_LOCK" '16777230:10835208:501:20:1:600:122:0'
    require_hash "$SHARED_LOCK" 'ad1d80772b48f16874718f5ae18aa7aca2a82b9dfbb962f14ae57d1195463fbb'
    [[ "$(/bin/cat "$SHARED_LOCK")" ==
       $'OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1\npid=58067\nnonce=d487c3d7020269c12dedaa2274eac704955b71922c7f8e0e7fff13f5b7670fc0' ]] ||
        fail 'stale unowned v6 lock content changed'
    require_plain_node /usr/bin/perl \
        '16777230:1152921500312572547:0:0:1:755:101840:524320'
    require_hash /usr/bin/perl 'abda2bfd23a6c9a8e57adf2291f0aea4abd8faf440558ee49fe4ced55e8d9ad0'
    /usr/bin/codesign --verify --strict --all-architectures /usr/bin/perl ||
        fail 'SIP Perl signature proof failed'
    /usr/bin/env -i LC_ALL=C HOME="$PINNED_HOME" PATH="$PINNED_PATH" \
        /usr/bin/perl -e '
            my $path = shift @ARGV;
            sysopen(my $handle, $path, 0x100) or die "open";
            my @descriptor = stat($handle);
            my @named = lstat($path);
            die "identity" unless @descriptor && @named;
            die "metadata" unless
                $descriptor[0] == 16777230 && $descriptor[1] == 10835208 &&
                $named[0] == $descriptor[0] && $named[1] == $descriptor[1] &&
                $descriptor[3] == 1 && $descriptor[4] == 501 && $descriptor[5] == 20 &&
                ($descriptor[2] & 0170000) == 0100000 &&
                ($descriptor[2] & 07777) == 0600 && $descriptor[7] == 122;
            my $text = "";
            my $count = sysread($handle, $text, 512);
            die "read" unless defined($count) && $count == 122;
            die "content" unless $text eq
                "OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1\npid=58067\nnonce=d487c3d7020269c12dedaa2274eac704955b71922c7f8e0e7fff13f5b7670fc0\n";
            flock($handle, 6) or die "locked";
            flock($handle, 8) or die "unlock";
            close($handle) or die "close";
        ' "$SHARED_LOCK" || fail 'canonical shared lock is owned or changed'
    require_plain_node "$SHARED_LOCK" '16777230:10835208:501:20:1:600:122:0'
    require_hash "$SHARED_LOCK" 'ad1d80772b48f16874718f5ae18aa7aca2a82b9dfbb962f14ae57d1195463fbb'
    [[ "$(/bin/cat "$SHARED_LOCK")" ==
       $'OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1\npid=58067\nnonce=d487c3d7020269c12dedaa2274eac704955b71922c7f8e0e7fff13f5b7670fc0' ]] ||
        fail 'stale unowned v6 lock changed during proof'
}

require_postmove_shared_lock_unowned() {
    require_absent "$PRODUCT_DRIVER"
    [[ "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$ROOT_TRANSACTION" 2>/dev/null)" ==
       '16777230:27093238:0:0:5:700:160:0' ]] ||
        fail 'post-move root transaction topology is unavailable'
    require_service_absent "$NEW_LABEL"
    require_process_absent CaptureServer

    [[ -f "$SHARED_LOCK" && ! -L "$SHARED_LOCK" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%f' "$SHARED_LOCK")" ==
           '16777230:10835208:501:20:1:600:0' ]] ||
        fail 'post-move generation lock metadata changed'
    local xattrs acl text pid nonce expected_size pid_row pid_status
    xattrs=$(/usr/bin/xattr "$SHARED_LOCK") || fail 'could not inspect post-move lock xattrs'
    [[ -z "$xattrs" ]] || fail 'post-move lock has unexpected xattrs'
    acl=$(/bin/ls -lde "$SHARED_LOCK") || fail 'could not inspect post-move lock ACL'
    [[ "$(print -r -- "$acl" | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" == '1' ]] ||
        fail 'post-move lock has an unexpected ACL'

    text=$(/bin/cat "$SHARED_LOCK") || fail 'could not read post-move generation lock'
    local -a lines
    lines=("${(@f)text}")
    [[ "${#lines}" == '3' &&
       "$lines[1]" == 'OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1' &&
       "$lines[2]" == pid=* && "$lines[3]" =~ ^nonce=[0-9a-f]{64}$ ]] ||
        fail 'post-move generation lock content is malformed'
    pid="${lines[2]#pid=}"
    nonce="${lines[3]#nonce=}"
    [[ "$pid" =~ ^[1-9][0-9]{0,4}$ ]] ||
        fail 'post-move generation lock PID is malformed'
    expected_size=$(( 117 + ${#pid} ))
    [[ "$(/usr/bin/stat -f '%z' "$SHARED_LOCK")" == "$expected_size" ]] ||
        fail 'post-move generation lock size is inconsistent'

    set +e
    pid_row=$(/bin/ps -p "$pid" -o pid= 2>&1)
    pid_status=$?
    set -e
    [[ "$pid_status" == '1' && -z "$pid_row" ]] ||
        fail 'post-move generation lock PID is still present'

    require_plain_node /usr/bin/perl \
        '16777230:1152921500312572547:0:0:1:755:101840:524320'
    require_hash /usr/bin/perl 'abda2bfd23a6c9a8e57adf2291f0aea4abd8faf440558ee49fe4ced55e8d9ad0'
    /usr/bin/codesign --verify --strict --all-architectures /usr/bin/perl ||
        fail 'SIP Perl signature proof failed'
    /usr/bin/env -i LC_ALL=C HOME="$PINNED_HOME" PATH="$PINNED_PATH" \
        /usr/bin/perl -e '
            my ($path, $pid, $nonce, $expected_size) = @ARGV;
            sysopen(my $handle, $path, 0x100) or die "open";
            my @descriptor = stat($handle);
            my @named = lstat($path);
            die "identity" unless @descriptor && @named;
            die "metadata" unless
                $descriptor[0] == 16777230 && $descriptor[1] == 10835208 &&
                $named[0] == $descriptor[0] && $named[1] == $descriptor[1] &&
                $descriptor[3] == 1 && $descriptor[4] == 501 && $descriptor[5] == 20 &&
                ($descriptor[2] & 0170000) == 0100000 &&
                ($descriptor[2] & 07777) == 0600 && $descriptor[7] == $expected_size;
            my $expected =
                "OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1\npid=$pid\nnonce=$nonce\n";
            my $text = "";
            my $count = sysread($handle, $text, 512);
            die "read" unless defined($count) && $count == $expected_size;
            die "content" unless $text eq $expected;
            flock($handle, 6) or die "locked";
            flock($handle, 8) or die "unlock";
            close($handle) or die "close";
        ' "$SHARED_LOCK" "$pid" "$nonce" "$expected_size" ||
        fail 'post-move generation lock is owned or changed'

    require_service_absent "$NEW_LABEL"
    require_process_absent CaptureServer
    set +e
    pid_row=$(/bin/ps -p "$pid" -o pid= 2>&1)
    pid_status=$?
    set -e
    [[ "$pid_status" == '1' && -z "$pid_row" ]] ||
        fail 'post-move generation lock PID appeared during proof'
    [[ -f "$SHARED_LOCK" && ! -L "$SHARED_LOCK" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$SHARED_LOCK")" ==
           "16777230:10835208:501:20:1:600:${expected_size}:0" &&
       "$(/bin/cat "$SHARED_LOCK")" == "$text" ]] ||
        fail 'post-move generation lock changed during proof'
}

require_offline_shared_lock_unowned() {
    if [[ -d "$PRODUCT_DRIVER" && ! -L "$PRODUCT_DRIVER" ]]; then
        require_shared_lock_unowned
    elif [[ ! -e "$PRODUCT_DRIVER" && ! -L "$PRODUCT_DRIVER" ]]; then
        require_postmove_shared_lock_unowned
    else
        fail 'driver state cannot select an offline lock proof'
    fi
}

require_public_hal_absent() {
    require_plain_node "$SEALED_GUARDIAN" '16777230:27093408:0:0:1:555:258696:0'
    require_hash "$SEALED_GUARDIAN" "$GUARDIAN_SHA256"
    local output guardian_status
    set +e
    output=$(/usr/bin/env -i LC_ALL=C HOME="$PINNED_HOME" PATH="$PINNED_PATH" \
        USER=ahmed LOGNAME=ahmed "$SEALED_GUARDIAN" verify-product-absent </dev/null 2>&1)
    guardian_status=$?
    set -e
    (( ${#output} <= 1048576 )) || fail 'public HAL proof output exceeded its bound'
    [[ "$guardian_status" == '0' &&
       "$output" == 'PRODUCT_ENDPOINTS_ABSENT_AND_LEGACY_PAIR_AVAILABLE' ]] ||
        fail "public HAL/BlackHole/default-route proof failed: ${output:-no diagnostic}"
}

try_sealed_admission() {
    local output admission_status
    set +e
    output=$(/usr/bin/env -i LC_ALL=C HOME="$PINNED_HOME" PATH="$PINNED_PATH" \
        USER=ahmed LOGNAME=ahmed "$SEALED_CONTROLLER" \
        --uid501-verify-exact-v6-admission </dev/null 2>&1)
    admission_status=$?
    set -e
    (( ${#output} <= 1048576 )) || return 1
    [[ "$admission_status" == '0' && -z "$output" ]]
}

require_sealed_admission() {
    require_plain_node "$SEALED_CONTROLLER" \
        '16777230:27093409:0:0:1:555:1443880:0'
    require_hash "$SEALED_CONTROLLER" "$CONTROLLER_SHA256"
    require_plain_node "$ROOT_SEALED/controller.sha256" \
        '16777230:27093410:0:0:1:444:65:0'
    require_hash "$ROOT_SEALED/controller.sha256" "$CONTROLLER_PIN_SHA256"
    [[ "$(/bin/cat "$ROOT_SEALED/controller.sha256")" == "$CONTROLLER_SHA256" ]] ||
        fail 'sealed controller pin content changed'
    try_sealed_admission || fail 'exact v6 sealed admission failed'
}

require_guardian_json_contract() {
    local evidence_path="$1"
    local mode="$2"
    local removed="$3"
    if [[ "$mode:$removed" == 'broker-repair:false' ]]; then
        require_hash "$evidence_path" "$VPIO_REPAIR_SHA256"
    elif [[ "$mode:$removed" == 'broker-final:true' ]]; then
        require_hash "$evidence_path" "$VPIO_FINAL_SHA256"
    else
        fail 'unreviewed guardian evidence contract requested'
    fi
    require_plain_node /usr/bin/plutil \
        '16777230:1152921500312572590:0:0:1:755:663776:524320'
    require_hash /usr/bin/plutil '983854d7c73e0bcdb6d50314e900e5d0a1313888727f8a69987c0c709e991c14'
    /usr/bin/codesign --verify --strict --all-architectures /usr/bin/plutil ||
        fail 'SIP plutil signature proof failed'
    [[ "$(/usr/bin/plutil -extract schema raw -o - "$evidence_path")" ==
           'opensteamer.v7-default-route-guardian.v1' &&
       "$(/usr/bin/plutil -extract mode raw -o - "$evidence_path")" == "$mode" &&
       "$(/usr/bin/plutil -extract passed raw -o - "$evidence_path")" == 'true' &&
       "$(/usr/bin/plutil -extract baselineStable raw -o - "$evidence_path")" == 'true' &&
       "$(/usr/bin/plutil -extract outputsUnchanged raw -o - "$evidence_path")" == 'true' &&
       "$(/usr/bin/plutil -extract hiddenEndpointNeverDefault raw -o - "$evidence_path")" == 'true' &&
       "$(/usr/bin/plutil -extract virtualEndpointsNeverOutputDefault raw -o - "$evidence_path")" == 'true' &&
       "$(/usr/bin/plutil -extract failureCode raw -o - "$evidence_path")" == 'none' &&
       "$(/usr/bin/plutil -extract inputRestored raw -o - "$evidence_path")" == 'true' &&
       "$(/usr/bin/plutil -extract newerInputChoicePreserved raw -o - "$evidence_path")" == 'false' &&
       "$(/usr/bin/plutil -extract listener.removedAndDrained raw -o - "$evidence_path")" == "$removed" &&
       "$(/usr/bin/plutil -extract listener.outputNotifications raw -o - "$evidence_path")" == '0' &&
       "$(/usr/bin/plutil -extract listener.systemOutputNotifications raw -o - "$evidence_path")" == '0' ]] ||
        fail 'guardian evidence field contract changed'
}

require_prior_user_evidence() {
    local uid_trial='/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab.failed-uid-admission'
    local uid_active='/Users/ahmed/Library/Application Support/opensteamer/failed-active-local-mono-trial-v1.uid-admission-L1Ciab'
    local candidate='/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab.failed-candidate-gate-coderesources-mode'
    [[ -d "$uid_trial" && ! -L "$uid_trial" && -f "$uid_active" && ! -L "$uid_active" &&
       -d "$candidate" && ! -L "$candidate" ]] || fail 'prior preserved user evidence is absent'
    [[ "$(/usr/bin/stat -f '%d:%i' "$uid_trial")" == '16777230:27016241' &&
       "$(/usr/bin/stat -f '%d:%i' "$uid_active")" == '16777230:27017103' &&
       "$(/usr/bin/stat -f '%d:%i' "$candidate")" == '16777230:27021633' ]] ||
        fail 'prior preserved user evidence identity changed'
    require_closed_tree "$uid_trial"
    require_closed_file "$uid_active"
    require_closed_tree "$candidate"
}

require_active_pointer_at() {
    local pointer_path="$1"
    [[ -f "$pointer_path" && ! -L "$pointer_path" ]] ||
        fail "active-pointer evidence is unavailable: $pointer_path"
    require_plain_node "$pointer_path" '16777230:27093461:501:20:1:600:228:0'
    require_hash "$pointer_path" "$ACTIVE_POINTER_SHA256"
    [[ "$(/bin/cat "$pointer_path")" ==
       $'schema=opensteamer.local-mono-trial-pointer.v1\ntrial_root=/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab\nstate=arming\nproxy_pid=21660\nproxy_start=Sun Aug 16 14:34:47 2026\nstate=armed' ]] ||
        fail 'active-pointer evidence content changed'
    require_closed_file "$pointer_path"
}

require_incident_trial_at() {
    local root="$1"
    local run="$root/paired-v7-update-local-mono-prep-L1Ciab"
    local probes="$run/probes"
    local staging="$root/staging"
    local controller="$staging/opensteamer-local-mono-trial-controller"
    local guardian="$staging/opensteamer-v7-default-route-guardian"
    local journal="$root/journal.log"
    local result="$root/result.txt"
    local arm="$root/proxy.arm"
    local state="$probes/vpio-default-route-state.json"
    local stdout="$probes/vpio-guardian.stdout"
    local stderr="$probes/vpio-guardian.stderr"
    local snapshot="$probes/vpio-guardian-snapshot.json"
    local fence="$probes/vpio-guardian-prestop-fence.json"
    local repair="$probes/vpio-guardian-repair.json"
    local final="$probes/vpio-guardian-final.json"

    [[ -d "$root" && ! -L "$root" && -d "$run" && ! -L "$run" &&
       -d "$probes" && ! -L "$probes" && -d "$staging" && ! -L "$staging" ]] ||
        fail "incident evidence directory shape changed: $root"
    for regular in "$controller" "$guardian" "$journal" "$result" "$arm" "$state" \
        "$stdout" "$stderr" "$snapshot" "$fence" "$repair" "$final"; do
        [[ -f "$regular" && ! -L "$regular" ]] || fail "incident evidence file changed: $regular"
    done

    require_exact_children "$root" "$journal" "$run" "$arm" "$result" "$staging"
    require_exact_children "$run" "$probes"
    require_exact_children "$probes" "$state" "$stdout" "$stderr" "$snapshot" "$fence" \
        "$repair" "$final"
    require_exact_children "$staging" "$controller" "$guardian"

    require_plain_node "$root" '16777230:27092973:501:20:7:700:224:0'
    require_plain_node "$run" '16777230:27092974:501:20:3:700:96:0'
    require_plain_node "$probes" '16777230:27092975:501:20:9:700:288:0'
    require_plain_node "$staging" '16777230:27092976:501:20:4:700:128:0'
    require_plain_node "$controller" '16777230:27092977:501:20:1:500:1443880:0'
    require_plain_node "$guardian" '16777230:27092978:501:20:1:500:258696:0'
    require_plain_node "$journal" '16777230:27093241:501:20:1:600:95:0'
    require_plain_node "$result" '16777230:27093242:501:20:1:600:0:0'
    require_plain_node "$arm" '16777230:27093462:501:20:1:600:102:0'
    require_plain_node "$state" '16777230:27093676:501:20:1:600:288:0'
    require_plain_node "$stdout" '16777230:27093674:501:20:1:600:67:0'
    require_plain_node "$stderr" '16777230:27093675:501:20:1:600:0:0'
    require_plain_node "$snapshot" '16777230:27093679:501:20:1:600:1275:0'
    require_plain_node "$fence" '16777230:27093690:501:20:1:600:1272:0'
    require_plain_node "$repair" '16777230:27093881:501:20:1:600:1273:0'
    require_plain_node "$final" '16777230:27093884:501:20:1:600:1271:0'

    require_hash "$controller" "$CONTROLLER_SHA256"
    require_hash "$guardian" "$GUARDIAN_SHA256"
    require_hash "$journal" "$TRIAL_JOURNAL_SHA256"
    require_hash "$result" "$TRIAL_RESULT_SHA256"
    require_hash "$arm" "$TRIAL_PROXY_ARM_SHA256"
    require_hash "$state" "$VPIO_STATE_SHA256"
    require_hash "$stdout" "$GUARDIAN_STDOUT_SHA256"
    require_hash "$stderr" "$TRIAL_RESULT_SHA256"
    require_hash "$snapshot" "$VPIO_SNAPSHOT_SHA256"
    require_hash "$fence" "$VPIO_PRESTOP_SHA256"
    require_hash "$repair" "$VPIO_REPAIR_SHA256"
    require_hash "$final" "$VPIO_FINAL_SHA256"

    [[ "$(/bin/cat "$journal")" ==
       $'OPENSTEAMER_LOCAL_MONO_TRIAL_V1\nSTATE USER_STAGE_VERIFIED\nSTATE ROOT_OWNED_UID_PROXY pid=21660' ]] ||
        fail 'incident journal content changed'
    [[ ! -s "$result" ]] || fail 'incident result is no longer empty'
    [[ "$(/bin/cat "$arm")" ==
       $'schema=opensteamer.local-mono-trial-proxy-arm.v1\nproxy_pid=21660\nproxy_start=Sun Aug 16 14:34:47 2026' ]] ||
        fail 'incident proxy arm changed'
    [[ "$(/bin/cat "$stdout")" ==
       $'GUARDIAN_BROKER_READY\nGUARDIAN_BROKER_CHECKED\nGUARDIAN_BROKER_PONG' ]] ||
        fail 'incident guardian transcript changed'
    require_guardian_json_contract "$repair" 'broker-repair' 'false'
    require_guardian_json_contract "$final" 'broker-final' 'true'
    require_closed_tree "$root"
}

classify_user_evidence() {
    require_absent "$ACTIVE_POINTER_TEMP"
    local trial=0 active=0 rescued_trial=0 rescued_active=0
    [[ -e "$TRIAL_ROOT" || -L "$TRIAL_ROOT" ]] && trial=1
    [[ -e "$ACTIVE_POINTER" || -L "$ACTIVE_POINTER" ]] && active=1
    [[ -e "$RESCUED_TRIAL_ROOT" || -L "$RESCUED_TRIAL_ROOT" ]] && rescued_trial=1
    [[ -e "$RESCUED_ACTIVE_POINTER" || -L "$RESCUED_ACTIVE_POINTER" ]] && rescued_active=1
    if (( trial == 1 && active == 1 && rescued_trial == 0 && rescued_active == 0 )); then
        require_incident_trial_at "$TRIAL_ROOT"
        require_active_pointer_at "$ACTIVE_POINTER"
        USER_EVIDENCE_STATE='U0'
    elif (( trial == 1 && active == 0 && rescued_trial == 0 && rescued_active == 1 )); then
        require_incident_trial_at "$TRIAL_ROOT"
        require_active_pointer_at "$RESCUED_ACTIVE_POINTER"
        USER_EVIDENCE_STATE='U1'
    elif (( trial == 0 && active == 0 && rescued_trial == 1 && rescued_active == 1 )); then
        require_incident_trial_at "$RESCUED_TRIAL_ROOT"
        require_active_pointer_at "$RESCUED_ACTIVE_POINTER"
        USER_EVIDENCE_STATE='U2'
    else
        fail 'user rescue evidence is not exact restart-safe state U0, U1, or U2'
    fi
}

require_root_shell_public_shape() {
    [[ -d "$ROOT_SUPPORT" && ! -L "$ROOT_SUPPORT" &&
       -f "$ROOT_CONTROLLER" && ! -L "$ROOT_CONTROLLER" &&
       -d "$ROOT_TRANSACTION" && ! -L "$ROOT_TRANSACTION" &&
       -d "$ROOT_SEALED" && ! -L "$ROOT_SEALED" &&
       -S "$ROOT_SOCKET" && ! -L "$ROOT_SOCKET" ]] ||
        fail 'root incident shell is unavailable'
    [[ "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$ROOT_SUPPORT")" ==
           '16777230:27093234:0:0:8:711:256:0' &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$ROOT_CONTROLLER")" ==
           '16777230:27093235:0:0:1:500:1443880:0' ]] ||
        fail 'root support/controller identity changed'
    local transaction_stat
    transaction_stat=$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$ROOT_TRANSACTION")
    [[ "$transaction_stat" == '16777230:27093238:0:0:4:700:128:0' ||
       "$transaction_stat" == '16777230:27093238:0:0:5:700:160:0' ]] ||
        fail 'root transaction identity changed'
    [[ "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$ROOT_SEALED")" ==
       '16777230:27093240:0:0:9:511:288:0' ]] ||
        fail 'root sealed-tree identity changed'
    [[ "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$ROOT_SOCKET")" ==
       '16777230:27093415:501:20:1:600:0:0' ]] ||
        fail 'root broker socket identity changed'
    local socket_acl socket_xattrs socket_xattr_status
    socket_acl=$(/bin/ls -lde "$ROOT_SOCKET") || fail 'could not inspect root broker socket ACL'
    [[ "$(print -r -- "$socket_acl" | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" == '1' ]] ||
        fail 'root broker socket has an unexpected ACL'
    set +e
    socket_xattrs=$(/usr/bin/xattr "$ROOT_SOCKET" 2>&1)
    socket_xattr_status=$?
    set -e
    socket_xattr_result_is_expected "$socket_xattr_status" "$socket_xattrs" ||
        fail 'root broker socket did not return exact xattr-not-supported proof'
    require_closed_file "$ROOT_SOCKET"
}

require_user_driver_tree_if_present() {
    if [[ -e "$PRODUCT_DRIVER" || -L "$PRODUCT_DRIVER" ]]; then
        [[ -d "$PRODUCT_DRIVER" && ! -L "$PRODUCT_DRIVER" ]] ||
            fail 'canonical product driver is not the exact directory kind'
        require_plain_node "$PRODUCT_DRIVER" '16777230:27093391:0:0:3:755:96:0'
        require_hash "$PRODUCT_DRIVER/Contents/MacOS/OpensteamerVirtualMicrophone" \
            "$DRIVER_EXECUTABLE_SHA256"
        local signature
        /usr/bin/codesign --verify --strict --all-architectures "$PRODUCT_DRIVER" ||
            fail 'canonical product driver signature verification failed'
        signature=$(/usr/bin/codesign -d --verbose=4 "$PRODUCT_DRIVER" 2>&1) ||
            fail 'canonical product driver signature details failed'
        [[ "$(print -r -- "$signature" | /usr/bin/grep -F -x -c \
               "CDHash=$DRIVER_CDHASH")" == '1' ]] || fail 'canonical driver CDHash changed'
        require_closed_tree "$PRODUCT_DRIVER"
    fi
}

require_exact_offline_v6_artifacts() {
    [[ -d "$NEW_APP" && ! -L "$NEW_APP" && -d "$LEGACY_APP" && ! -L "$LEGACY_APP" ]] ||
        fail 'v6 or protected legacy application bundle is unavailable'
    [[ "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$NEW_APP")" ==
           '16777230:25795490:501:20:3:755:96:0' &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$NEW_EXECUTABLE")" ==
           '16777230:25795495:501:20:1:755:6025264:0' &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$NEW_PLIST")" ==
           '16777230:21673018:501:20:1:600:1137:0' ]] ||
        fail 'exact committed v6 app/plist identity changed'
    [[ "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$LEGACY_APP")" ==
           '16777230:12547983:501:80:7:755:224:0' &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$LEGACY_EXECUTABLE")" ==
           '16777230:12547988:501:80:1:755:4531808:0' &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$LEGACY_PLIST")" ==
           '16777230:12407477:501:20:1:600:933:0' ]] ||
        fail 'protected legacy app/plist identity changed'
    require_hash "$NEW_EXECUTABLE" "$V6_EXECUTABLE_SHA256"
    require_hash "$NEW_PLIST" "$V6_PLIST_SHA256"
    require_hash "$LEGACY_EXECUTABLE" "$LEGACY_EXECUTABLE_SHA256"
    require_hash "$LEGACY_PLIST" "$LEGACY_PLIST_SHA256"
    require_hash "$V6_REFERENCE_APP/Contents/MacOS/CaptureServer" "$V6_EXECUTABLE_SHA256"
    require_hash "$V6_BUNDLE_VERIFIER" "$V6_BUNDLE_VERIFIER_SHA256"
    require_hash "$V6_LAUNCH_VERIFIER" "$V6_LAUNCH_VERIFIER_SHA256"
    [[ -x "$V6_BUNDLE_VERIFIER" && -x "$V6_LAUNCH_VERIFIER" ]] ||
        fail 'committed v6 verifier is not executable'

    /usr/bin/env -i LC_ALL=C HOME="$PINNED_HOME" PATH="$PINNED_PATH" \
        USER=ahmed LOGNAME=ahmed OPENSTEAMER_EXPECTED_ARCHITECTURES=arm64 \
        "$V6_BUNDLE_VERIFIER" --installed-runtime "$NEW_APP" MSMG8CJLB3 \
        "$V6_REFERENCE_APP/Contents/MacOS/CaptureServer" </dev/null >/dev/null ||
        fail 'exact committed v6 installed bundle proof failed'
    /usr/bin/env -i LC_ALL=C HOME="$PINNED_HOME" PATH="$PINNED_PATH" \
        USER=ahmed LOGNAME=ahmed "$V6_LAUNCH_VERIFIER" --verify-plist \
        "$NEW_EXECUTABLE" "$NEW_PLIST" </dev/null >/dev/null ||
        fail 'exact committed v6 LaunchAgent proof failed'

    [[ -f "$LOGIN_KEYCHAIN" && ! -L "$LOGIN_KEYCHAIN" &&
       "$(/usr/bin/stat -f '%u:%g:%l:%Lp' "$LOGIN_KEYCHAIN")" == '501:20:1:644' ]] ||
        fail 'isolated pairing login Keychain metadata is unsafe'
    for account in "$PAIRING_IDENTITY_ACCOUNT" "$PAIRING_VIEWER_ACCOUNT"; do
        /usr/bin/env -i LC_ALL=C HOME="$PINNED_HOME" PATH="$PINNED_PATH" \
            USER=ahmed LOGNAME=ahmed /usr/bin/security find-generic-password \
            -s "$PAIRING_SERVICE" -a "$account" "$LOGIN_KEYCHAIN" \
            </dev/null >/dev/null 2>&1 || fail "isolated pairing item is unavailable: $account"
    done
    [[ -f "$LOGIN_KEYCHAIN" && ! -L "$LOGIN_KEYCHAIN" &&
       "$(/usr/bin/stat -f '%u:%g:%l:%Lp' "$LOGIN_KEYCHAIN")" == '501:20:1:644' ]] ||
        fail 'isolated pairing login Keychain metadata changed during proof'
}

v6_transition_for_sample() {
    [[ "$#" == '2' ]] || return 1
    case "$1:$2" in
        '113:0') print -r -- offline ;;
        '0:0') print -r -- starting ;;
        '0:1') print -r -- healthy ;;
        *) return 1 ;;
    esac
}

classify_v6_state() {
    local output launch_status expected ready=0 transition
    set +e
    output=$(/bin/launchctl print "gui/501/$NEW_LABEL" 2>&1)
    launch_status=$?
    set -e
    (( ${#output} <= 1048576 )) || fail 'launchd state output exceeded its bound'
    expected=$'Bad request.\nCould not find service "org.example.opensteamer.worldwide" in domain for user gui: 501'
    if [[ "$launch_status" == '113' && "$output" == "$expected" ]]; then
        transition=$(v6_transition_for_sample "$launch_status" '0') ||
            fail 'v6 offline transition classifier failed'
    elif [[ "$launch_status" == '0' ]]; then
        require_absent "$PRODUCT_DRIVER"
        if try_lightweight_v6_identity; then
            ready=1
        fi
        transition=$(v6_transition_for_sample "$launch_status" "$ready") ||
            fail 'v6 present transition classifier failed'
    else
        fail 'v6 launchd state is neither exact absent nor present'
    fi
    case "$transition" in
        offline)
            require_process_absent CaptureServer
            require_offline_shared_lock_unowned
            V6_STATE='offline'
            ADMISSION_PROVED=0
            ;;
        starting)
            require_present_v6_service_shape "$output"
            V6_STATE='starting'
            ADMISSION_PROVED=0
            ;;
        healthy)
            admit_current_v6_generation
            V6_STATE='healthy'
            ADMISSION_PROVED=1
            ;;
        *) fail 'v6 transition classifier returned an impossible state' ;;
    esac
}

self_test_v6_transition_classifier() {
    [[ "$(v6_transition_for_sample 113 0)" == 'offline' &&
       "$(v6_transition_for_sample 0 0)" == 'starting' &&
       "$(v6_transition_for_sample 0 1)" == 'healthy' ]] ||
        fail 'v6 transition classifier rejected a reviewed state'
    if v6_transition_for_sample 113 1 >/dev/null 2>&1 ||
       v6_transition_for_sample 0 2 >/dev/null 2>&1 ||
       v6_transition_for_sample 1 0 >/dev/null 2>&1 ||
       v6_transition_for_sample 0 >/dev/null 2>&1; then
        fail 'v6 transition classifier accepted an invalid mutant'
    fi
    cheap_process_tuple_is_ready 0 0 123 "$NEW_EXECUTABLE" 1 ||
        fail 'cheap readiness tuple rejected the reviewed state'
    if cheap_process_tuple_is_ready 1 0 123 "$NEW_EXECUTABLE" 1 ||
       cheap_process_tuple_is_ready 0 1 123 "$NEW_EXECUTABLE" 1 ||
       cheap_process_tuple_is_ready 0 0 $'123\n124' "$NEW_EXECUTABLE" 1 ||
       cheap_process_tuple_is_ready 0 0 123 "$LEGACY_EXECUTABLE" 1 ||
       cheap_process_tuple_is_ready 0 0 123 "$NEW_EXECUTABLE" 0; then
        fail 'cheap readiness tuple accepted an invalid mutant'
    fi
}

try_lock_generation_for_pid() {
    local pid="$1"
    local text
    local -a lines
    local expected_size=$(( 117 + ${#pid} ))
    [[ -f "$SHARED_LOCK" && ! -L "$SHARED_LOCK" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%f' "$SHARED_LOCK")" ==
           '16777230:10835208:501:20:1:600:0' &&
       "$(/usr/bin/stat -f '%z' "$SHARED_LOCK")" == "$expected_size" ]] || return 1
    text=$(/bin/cat "$SHARED_LOCK")
    lines=("${(@f)text}")
    [[ "${#lines}" == '3' && "$lines[1]" == 'OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1' &&
       "$lines[2]" == "pid=$pid" && "$lines[3]" =~ '^nonce=[0-9a-f]{64}$' ]] || return 1
    LOCK_GENERATION_NONCE="${lines[3]#nonce=}"
}

require_lock_generation_for_pid() {
    try_lock_generation_for_pid "$1" || fail 'v6 generation lock identity/content changed'
}

cheap_process_tuple_is_ready() {
    [[ "$#" == '5' && "$1" == '0' && "$2" == '0' && "$3" == <-> &&
       "$4" == "$NEW_EXECUTABLE" && "$5" == '1' ]]
}

try_lightweight_v6_identity() {
    local state launch_status pids command start runs
    set +e
    state=$(/bin/launchctl print "gui/501/$NEW_LABEL" 2>&1)
    launch_status=$?
    pids=$(/usr/bin/pgrep -x CaptureServer 2>/dev/null)
    local pgrep_status=$?
    set -e
    (( ${#state} <= 1048576 )) || return 1
    [[ "$launch_status" == '0' && "$pgrep_status" == '0' && "$pids" == <-> ]] || return 1
    command=$(/bin/ps -p "$pids" -o comm= 2>/dev/null) || return 1
    [[ "$command" == "$NEW_EXECUTABLE" ]] || return 1
    try_lock_generation_for_pid "$pids" || return 1
    cheap_process_tuple_is_ready "$launch_status" "$pgrep_status" "$pids" "$command" '1' || return 1
    start=$(/bin/ps -p "$pids" -o lstart= 2>/dev/null | /usr/bin/awk '{$1=$1; print}') ||
        return 1
    [[ -n "$start" ]] || return 1
    runs=$(print -r -- "$state" | /usr/bin/sed -n $'s/^\truns = //p') || return 1
    [[ "$runs" == <-> && "$runs" != '0' ]] || return 1
    [[ "$(print -r -- "$state" | /usr/bin/grep -F -x -c \
           "gui/501/$NEW_LABEL = {")" == '1' &&
       "$(print -r -- "$state" | /usr/bin/grep -F -x -c $'\tpath = '"$NEW_PLIST")" == '1' &&
       "$(print -r -- "$state" | /usr/bin/grep -F -x -c $'\tstate = running')" == '1' &&
       "$(print -r -- "$state" | /usr/bin/grep -F -x -c $'\tprogram = '"$NEW_EXECUTABLE")" == '1' &&
       "$(print -r -- "$state" | /usr/bin/grep -F -x -c $'\tpid = '"$pids")" == '1' ]] ||
        return 1
    OBSERVED_V6_FINGERPRINT="$pids|$start|$runs|$LOCK_GENERATION_NONCE"
}

require_lightweight_v6_identity() {
    try_lightweight_v6_identity || fail 'v6 lightweight service/process identity is unavailable'
}

require_present_v6_service_shape() {
    local state="$1" pids pgrep_status command
    [[ "$(print -r -- "$state" | /usr/bin/grep -F -x -c \
           "gui/501/$NEW_LABEL = {")" == '1' &&
       "$(print -r -- "$state" | /usr/bin/grep -F -x -c $'\tpath = '"$NEW_PLIST")" == '1' &&
       "$(print -r -- "$state" | /usr/bin/grep -F -x -c $'\tprogram = '"$NEW_EXECUTABLE")" == '1' &&
       "$(print -r -- "$state" | /usr/bin/grep -E -c $'^\tstate = [[:alnum:] -]+$')" == '1' ]] ||
        fail 'present v6 launchd job has an unexpected static identity'
    set +e
    pids=$(/usr/bin/pgrep -x CaptureServer 2>/dev/null)
    pgrep_status=$?
    set -e
    if [[ "$pgrep_status" == '0' ]]; then
        [[ "$pids" == <-> ]] || fail 'present v6 job has an ambiguous CaptureServer set'
        command=$(/bin/ps -p "$pids" -o comm= 2>/dev/null) ||
            fail 'present v6 job process identity is unavailable'
        [[ "$command" == "$NEW_EXECUTABLE" ]] ||
            fail 'present v6 job mapped an unexpected executable'
    elif [[ "$pgrep_status" == '1' && -z "$pids" ]]; then
        :
    else
        fail 'present v6 job process enumeration failed'
    fi
}

admit_current_v6_generation() {
    local before after
    require_lightweight_v6_identity
    before="$OBSERVED_V6_FINGERPRINT"
    require_sealed_admission
    require_lightweight_v6_identity
    after="$OBSERVED_V6_FINGERPRINT"
    [[ "$after" == "$before" ]] || fail 'v6 generation changed across full admission'
    if [[ -n "$ADMITTED_V6_FINGERPRINT" ]]; then
        [[ "$after" == "$ADMITTED_V6_FINGERPRINT" ]] ||
            fail 'full admission silently rebound to a different v6 generation'
    else
        ADMITTED_V6_FINGERPRINT="$after"
    fi
    ADMISSION_PROVED=1
}

require_admitted_v6_lightweight() {
    [[ "$ADMISSION_PROVED" == '1' && -n "$ADMITTED_V6_FINGERPRINT" ]] ||
        fail 'no fully admitted v6 generation is pinned'
    require_lightweight_v6_identity
    [[ "$OBSERVED_V6_FINGERPRINT" == "$ADMITTED_V6_FINGERPRINT" ]] ||
        fail 'admitted v6 generation changed'
}

bootstrap_v6_if_needed() {
    if [[ "$V6_STATE" == 'healthy' && "$ADMISSION_PROVED" == '1' &&
          -n "$ADMITTED_V6_FINGERPRINT" ]] &&
       try_lightweight_v6_identity &&
       [[ "$OBSERVED_V6_FINGERPRINT" == "$ADMITTED_V6_FINGERPRINT" ]]; then
        return 0
    fi
    classify_v6_state
    if [[ "$V6_STATE" == 'healthy' ]]; then
        return 0
    fi
    [[ "$V6_STATE" == 'offline' || "$V6_STATE" == 'starting' ]] ||
        fail 'unreviewed v6 bootstrap state'
    require_absent "$PRODUCT_DRIVER"
    [[ "$ROOT_RESCUE_PROVED" == '1' ]] ||
        fail 'authorized root post-move proof is not pinned for v6 bootstrap'
    require_exact_offline_v6_artifacts
    require_legacy_offline
    require_public_hal_absent
    if [[ "$V6_STATE" == 'offline' ]]; then
        require_process_absent CaptureServer
        require_offline_shared_lock_unowned
        require_legacy_offline
        require_service_absent "$NEW_LABEL"
        require_process_absent CaptureServer
        require_offline_shared_lock_unowned

        local output bootstrap_status
        set +e
        output=$(/usr/bin/env -i LC_ALL=C HOME="$PINNED_HOME" PATH="$PINNED_PATH" \
            USER=ahmed LOGNAME=ahmed /bin/launchctl bootstrap gui/501 "$NEW_PLIST" \
            </dev/null 2>&1)
        bootstrap_status=$?
        set -e
        (( ${#output} <= 1048576 )) || fail 'v6 bootstrap diagnostic exceeded its bound'
        [[ "$bootstrap_status" == '0' && -z "$output" ]] ||
            fail "exact v6 launchctl bootstrap failed: ${output:-no diagnostic}"
    fi

    local attempts=0 ready=0
    while (( attempts < 45 )); do
        if try_lightweight_v6_identity; then
            ready=1
            break
        fi
        /bin/sleep 1
        (( attempts += 1 ))
    done
    [[ "$ready" == '1' ]] || fail 'exact v6 did not reach cheap readiness within 45 seconds'
    admit_current_v6_generation
    V6_STATE='healthy'
    require_legacy_offline
    require_public_hal_absent
    require_coreaudiod_unchanged
    require_coreaudiod_unchanged
}

require_script_identity() {
    [[ "$INVOCATION_SCRIPT" == "$SCRIPT" && -f "$SCRIPT" && ! -L "$SCRIPT" ]] ||
        fail 'rescue escaped its canonical script path'
    [[ "$(/usr/bin/stat -f '%u:%g:%l:%Lp' "$SCRIPT")" == '501:20:1:700' ]] ||
        fail 'rescue script metadata changed'
    [[ "$(/usr/bin/grep -F -x -c \
        "readonly EXPECTED_SCRIPT_NORMALIZED_SHA256='$EXPECTED_SCRIPT_NORMALIZED_SHA256'" \
        "$SCRIPT")" == '1' ]] || fail 'rescue normalized self-pin field is malformed'
    local normalized
    normalized=$(/usr/bin/sed -E \
        "s#^(readonly EXPECTED_SCRIPT_NORMALIZED_SHA256=)'[^']*'#\\1'NORMALIZED_RESCUE_PIN'#" \
        "$SCRIPT" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
    [[ "$normalized" == "$EXPECTED_SCRIPT_NORMALIZED_SHA256" ]] ||
        fail 'rescue script differs from its normalized self-pin'
    [[ "$(print -rn -- "$ROOT_RESCUE_COMMAND" | /usr/bin/shasum -a 256 | \
        /usr/bin/awk '{print $1}')" == "$EXPECTED_ROOT_COMMAND_SHA256" ]] ||
        fail 'root rescue command differs from its pin'
    print -rn -- "$ROOT_RESCUE_COMMAND" | /bin/sh -n ||
        fail 'root rescue command is not valid POSIX shell'
}

require_static_contracts() {
    local static_source authorization_source
    static_source=$(/usr/bin/sed '/^require_static_contracts() {$/,/^}$/d' "$SCRIPT") ||
        fail 'could not isolate rescue source for static checks'
    authorization_source=$(/usr/bin/sed -n '/^run_root_rescue_once() {$/,/^}$/p' "$SCRIPT") ||
        fail 'could not isolate authorization function for static checks'
    [[ "$ROOT_RESCUE_COMMAND" != *'/bin/kill'* &&
       "$ROOT_RESCUE_COMMAND" != *'/usr/bin/killall'* &&
       "$ROOT_RESCUE_COMMAND" != *'kickstart'* &&
       "$ROOT_RESCUE_COMMAND" != *'bootstrap'* &&
       "$ROOT_RESCUE_COMMAND" != *'bootout'* &&
       "$ROOT_RESCUE_COMMAND" != *'enable'* &&
       "$ROOT_RESCUE_COMMAND" != *'disable'* ]] ||
        fail 'root rescue command contains a forbidden CoreAudio/service signal primitive'
    [[ "$(print -r -- "$ROOT_RESCUE_COMMAND" | /usr/bin/grep -F -c \
           'system(\"/bin/mv\", \"-n\", \$source, \$destination) == 0 or die \"move\";')" == '1' &&
       "$(print -r -- "$ROOT_RESCUE_COMMAND" | /usr/bin/grep -F -c \
           'capture(\"/bin/launchctl\", \"print\",')" == '2' &&
       "$(print -r -- "$ROOT_RESCUE_COMMAND" | /usr/bin/grep -F -c \
           '\"/bin/launchctl\"')" == '2' &&
       "$(print -r -- "$ROOT_RESCUE_COMMAND" | /usr/bin/grep -F -c \
           'bounded_capture(\"/usr/sbin/lsof\", \"-Fn\", \"+D\", \$source)')" == '2' &&
       "$(print -r -- "$ROOT_RESCUE_COMMAND" | /usr/bin/grep -F -c \
           'bounded_capture(\"/usr/sbin/lsof\", \"-Fn\", \"+D\", \$destination)')" == '1' &&
       "$(print -r -- "$ROOT_RESCUE_COMMAND" | /usr/bin/grep -F -c \
           'require_coreaudiod();')" == '4' &&
       "$(/usr/bin/grep -E -c '^[[:space:]]+/bin/mv -n "\$ACTIVE_POINTER" "\$RESCUED_ACTIVE_POINTER"$' "$SCRIPT")" == '1' &&
       "$(/usr/bin/grep -E -c '^[[:space:]]+/bin/mv -n "\$TRIAL_ROOT" "\$RESCUED_TRIAL_ROOT"$' "$SCRIPT")" == '1' ]] ||
        fail 'exclusive rescue rename contract changed'
    [[ "$(print -r -- "$static_source" | /usr/bin/grep -E -c \
           '(^|[[:space:]])(/bin/)?(rm|rmdir)([[:space:]]|$)' || true)" == '0' ]] ||
        fail 'rescue must not delete any artifact'
    [[ "$(print -r -- "$static_source" | /usr/bin/grep -F -c '/usr/bin/python3' || true)" == '0' ]] ||
        fail 'rescue must not resolve an external developer Python'
    [[ "$(print -r -- "$static_source" | /usr/bin/grep -E -c \
           '^[[:space:]]+(local|typeset)([[:space:]]+-[^[:space:]]+)?[[:space:]]+([^#]*[[:space:]])?(status|path|commands|functions|pipestatus|reply|argv|signals)(=|[[:space:]]|$)' || true)" == '0' ]] ||
        fail 'rescue declares a reserved zsh special as a local variable'
    [[ "$(print -r -- "$authorization_source" | /usr/bin/grep -F -c \
           '/usr/bin/osascript - "$ROOT_RESCUE_COMMAND"')" == '1' ]] ||
        fail 'rescue must contain exactly one fixed authorization call'
    [[ "$(print -r -- "$static_source" | /usr/bin/grep -E -c \
           '/bin/mv.*(AudioStreamer Host|com\.elamin\.audiostreamer)' || true)" == '0' ]] ||
        fail 'rescue attempted to move a protected legacy artifact'
}

read_only_preflight() {
    [[ "$(/usr/bin/id -u)" == '501' ]] || fail 'rescue must run as uid501 without sudo'
    require_static_contracts
    require_prior_user_evidence
    classify_user_evidence
    require_root_shell_public_shape
    require_local_trial_processes_absent
    require_coreaudiod_unchanged
    require_coreaudiod_unchanged
    require_user_driver_tree_if_present
    require_public_hal_absent
    require_public_hal_absent
    require_legacy_offline
    classify_v6_state
    if [[ "$V6_STATE" == 'offline' || "$V6_STATE" == 'starting' ]]; then
        require_exact_offline_v6_artifacts
    fi
    print -- "LOCAL_MONO_RESCUE_PREFLIGHT_OK user_state=$USER_EVIDENCE_STATE v6_state=$V6_STATE"
}

run_root_rescue_once() {
    local output root_status
    set +e
    output=$(/usr/bin/env -i LC_ALL=C HOME="$PINNED_HOME" PATH="$PINNED_PATH" \
        USER=ahmed LOGNAME=ahmed /usr/bin/osascript - "$ROOT_RESCUE_COMMAND" <<'APPLESCRIPT'
on run commandArguments
    if (count of commandArguments) is not 1 then error "fixed root rescue argument missing"
    do shell script (item 1 of commandArguments) with administrator privileges
end run
APPLESCRIPT
    )
    root_status=$?
    set -e
    (( ${#output} <= 4096 )) || fail 'authorized root rescue output exceeded its bound'
    [[ "$root_status" == '0' &&
       ( "$output" == 'LOCAL_MONO_RESCUE_ROOT_OK state=moved coreaudiod_pid=179 coreaudiod_start=Fri_Jul_31_11:03:20_2026' ||
         "$output" == 'LOCAL_MONO_RESCUE_ROOT_OK state=already-moved coreaudiod_pid=179 coreaudiod_start=Fri_Jul_31_11:03:20_2026' ) ]] ||
        fail "authorized root rescue failed: ${output:-no diagnostic}"
    ROOT_RESCUE_PROVED=1
}

require_final_safety_fence() {
    require_absent "$PRODUCT_DRIVER"
    require_root_shell_public_shape
    require_local_trial_processes_absent
    require_coreaudiod_unchanged
    require_coreaudiod_unchanged
    require_legacy_offline
    require_public_hal_absent
    require_public_hal_absent
    require_admitted_v6_lightweight
}

preserve_user_incident_evidence() {
    classify_user_evidence
    if [[ "$USER_EVIDENCE_STATE" == 'U0' ]]; then
        require_final_safety_fence
        require_active_pointer_at "$ACTIVE_POINTER"
        require_absent "$RESCUED_ACTIVE_POINTER"
        /bin/mv -n "$ACTIVE_POINTER" "$RESCUED_ACTIVE_POINTER"
        /bin/sync
        require_absent "$ACTIVE_POINTER"
        require_active_pointer_at "$RESCUED_ACTIVE_POINTER"
        USER_EVIDENCE_STATE='U1'
    fi
    if [[ "$USER_EVIDENCE_STATE" == 'U1' ]]; then
        require_final_safety_fence
        require_incident_trial_at "$TRIAL_ROOT"
        require_absent "$RESCUED_TRIAL_ROOT"
        /bin/mv -n "$TRIAL_ROOT" "$RESCUED_TRIAL_ROOT"
        /bin/sync
        require_absent "$TRIAL_ROOT"
        require_incident_trial_at "$RESCUED_TRIAL_ROOT"
        USER_EVIDENCE_STATE='U2'
    fi
    [[ "$USER_EVIDENCE_STATE" == 'U2' ]] || fail 'user evidence preservation did not converge'
    require_final_safety_fence
    classify_user_evidence
    [[ "$USER_EVIDENCE_STATE" == 'U2' ]] || fail 'final user evidence state changed'
    admit_current_v6_generation
}

run_rescue() {
    [[ "$LIVE_RELEASE_STATUS" == "$LIVE_RELEASE_READY" ]] ||
        fail 'rescue is not release-audited'
    read_only_preflight
    run_root_rescue_once
    require_absent "$PRODUCT_DRIVER"
    require_coreaudiod_unchanged
    require_coreaudiod_unchanged
    require_public_hal_absent
    require_public_hal_absent
    require_local_trial_processes_absent
    bootstrap_v6_if_needed
    require_final_safety_fence
    preserve_user_incident_evidence
    print -- 'LOCAL_MONO_RESCUE_COMPLETE exact_v6_restored=true product_driver_absent=true evidence=preserved'
}

self_test() {
    self_test_v6_transition_classifier
    self_test_socket_xattr_classifier
    require_static_contracts
    local output controller_status
    set +e
    output=$(/usr/bin/env -i LC_ALL=C HOME="$PINNED_HOME" PATH="$PINNED_PATH" \
        USER=ahmed LOGNAME=ahmed "$SEALED_CONTROLLER" --self-test </dev/null 2>&1)
    controller_status=$?
    set -e
    (( ${#output} <= 1048576 )) || fail 'controller self-test output exceeded its bound'
    [[ "$controller_status" == '0' && "$output" ==
       'LOCAL_MONO_TRIAL_SELF_TEST_OK cases=70 live_enabled=true artifact_root=/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-prep/prep.L1Ciab' ]] ||
        fail 'sealed controller self-test failed'
    read_only_preflight
    print -- 'LOCAL_MONO_RESCUE_SELF_TEST_OK controller_cases=70 no_mutation=true'
}

usage() {
    print -u2 -- "usage: $SCRIPT $SELF_TEST_MODE|$PREFLIGHT_MODE|$RESCUE_MODE"
    exit 64
}

[[ "$#" == '1' ]] || usage
readonly MODE="$1"
case "$MODE" in
    "$SELF_TEST_MODE"|"$PREFLIGHT_MODE"|"$RESCUE_MODE") ;;
    *) usage ;;
esac

require_script_identity
case "$MODE" in
    "$SELF_TEST_MODE") self_test ;;
    "$PREFLIGHT_MODE") read_only_preflight ;;
    "$RESCUE_MODE") run_rescue ;;
esac
