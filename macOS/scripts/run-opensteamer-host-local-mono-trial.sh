#!/bin/zsh
# Build and invoke the one-shot local mono-trial controller without touching the live host,
# launchd, HAL, CoreAudio, or either protected legacy namespace. Live modes remain gated until
# the detached UID501 guardian, root deadman, and final source/binary pins are release-audited.
set -euo pipefail

export LC_ALL=C
umask 077

readonly SELF_TEST_MODE='--self-test'
readonly PREFLIGHT_MODE='--preflight'
readonly RETRY_PREFLIGHT_MODE='--preflight-known-failed-bootstrap'
readonly START_MODE='--start-local-trial'
readonly STOP_MODE='--stop-local-trial'
readonly ROOT_MODE='--root-local-trial-broker'
readonly CAPTURE_MODE='--capture-failed-root-evidence'

readonly LIVE_RELEASE_STATUS='REVIEWED_LOCAL_TRIAL_READY'
readonly LIVE_RELEASE_READY='REVIEWED_LOCAL_TRIAL_READY'

readonly EXPECTED_REPO='/Users/ahmed/Documents/Codex/opensteamer'
readonly INVOKED_LAUNCHER_PATH="${0:A}"
readonly PINNED_USER_HOME='/Users/ahmed'
readonly PINNED_USER_NAME='ahmed'
readonly PINNED_EXEC_PATH='/usr/bin:/bin:/usr/sbin:/sbin'
readonly LAUNCHER="$EXPECTED_REPO/macOS/scripts/run-opensteamer-host-local-mono-trial.sh"
readonly SOURCE="$EXPECTED_REPO/macOS/scripts/opensteamer-host-local-mono-trial-controller.rs"
readonly V7_SOURCE="$EXPECTED_REPO/macOS/scripts/opensteamer-host-paired-v7-update-controller.rs"
readonly V1_SOURCE="$EXPECTED_REPO/macOS/scripts/opensteamer-host-post-v20-update-controller.rs"
readonly GUARDIAN_SOURCE="$EXPECTED_REPO/macOS/VirtualAudioDriver/Probes/V7DefaultRouteGuardian.swift"

readonly RUSTC='/opt/homebrew/Cellar/rust/1.97.1/bin/rustc'
readonly RUSTC_DRIVER='/opt/homebrew/Cellar/rust/1.97.1/lib/librustc_driver-1aebdb596416d2c8.dylib'
readonly RUSTC_SYSROOT='/opt/homebrew/Cellar/rust/1.97.1'
readonly EXPECTED_RUSTC_VERSION='rustc 1.97.1 (8bab26f4f 2026-07-14) (Homebrew)'
readonly EXPECTED_RUSTC_SHA256='d69d40bfd2e11825feb3538512b6ffcd63de91c35ec36bb876849f0f9f8fe6bd'
readonly EXPECTED_RUSTC_DRIVER_SHA256='aa8f5e89644f6d54fd3f1c4d4031bbda10ff750984cede4a75c7addee27e15df'

readonly EXPECTED_CONTROLLER_SOURCE_SHA256='6113d58536274d8772922f27f42368f3b3e253fb65fc976bc39e8f629e67e734'
readonly EXPECTED_V7_SOURCE_SHA256='89cb7d70605a4d6e75d622974d321ce77c456e40ce06cc57e2d450093e4dfe2a'
readonly EXPECTED_V1_SOURCE_SHA256='2dfe9ddec5ea71b206f6462deec0b8be5423e9f23ab30aebc42b8f424dfdab06'
readonly EXPECTED_UNBOUNDED_INCLUDED_SOURCE_SHA256='2020edb76b1f9537afad1ed2ec22686044f2f0cbbb3d95155546b69e0b1442e6'
readonly EXPECTED_V1_COMMAND_OUTPUT_SOURCE_SHA256='161a4322b76036fe2036086090ff15eb111bf9ad9f940d3d8f80107477ff6417'
readonly EXPECTED_INCLUDED_SOURCE_SHA256='752684945f6735a3ead6c20c38926f6f5a7495ae3f3a980e54daa834327025d6'
readonly EXPECTED_GUARDIAN_SOURCE_SHA256='f152ef8d05eed29c5918666be31821e5ef6e325351d2fcf4ad5f8b83987e299c'
readonly EXPECTED_TRANSFORMED_GUARDIAN_SOURCE_SHA256='1d220b636875546509b2f8bd69d92ff072679934b8172bcd7c89e90e4b653e12'
readonly EXPECTED_GUARDIAN_BINARY_SHA256='cc278c52c70da9aac41156a9f41079b90dae07bf6adc56ddd495c21d42d47244'
readonly EXPECTED_GUARDIAN_BINARY_SIZE='286968'
readonly PRESERVED_GUARDIAN_BINARY_SHA256='72ef50156a0154e3b6c9a84557f3c192b67ec69f7a9747476826fb9aa3d4509c'
readonly EXPECTED_GUARDIAN_SELF_TEST_SHA256='035e3cd9c881c75f101aed88f749c730cff5293c3ca04dfb88f7c14fef84275d'
readonly EXPECTED_CONTROLLER_BINARY_SHA256='4b066652df384925f4564271b00ae02c22df6bf5bd1402ea2659ab9b9508650b'
readonly EXPECTED_CONTROLLER_BINARY_SIZE='2064792'
readonly EXPECTED_ROOT_WRAPPER_PERL_SHA256='abda2bfd23a6c9a8e57adf2291f0aea4abd8faf440558ee49fe4ced55e8d9ad0'
readonly EXPECTED_ROOT_WRAPPER_PERL_STAT='1152921500312572547:0:0:1:755:101840:524320'
readonly EXPECTED_ROOT_BOOTSTRAP_SHA256='0b496d65cbc8f2e2c01c1e42b8a27e0a417b8083bdb21a1ca608c426fec7f114'
readonly EXPECTED_ROOT_CAPTURE_COMMAND_SHA256='69435f284f421eb5065a429e97f0330c13d776e21cac30204f8966e8050072af'
readonly EXPECTED_ROOT_CAPTURE_ENVELOPE_SHA256='b935200eb75912e918dd223f11d2cb4f01f5b1e03d0ec18f183e7d4f476bd53b'
readonly EXPECTED_LAUNCHER_NORMALIZED_SHA256='a688f816860704f27bb6ccf0bd0d2bc3baa1eba8f052d5322bf053b4bceb35b6'

readonly BUILD_PARENT='/Users/ahmed/Library/Application Support/opensteamer'
readonly LAUNCHER_LOCK='/Users/ahmed/Library/Application Support/opensteamer/.local-mono-trial-launcher.lock'
readonly DATA_VOLUME_MOUNT='/System/Volumes/Data'
readonly EXPECTED_DATA_VOLUME_UUID='AF638805-E0CB-4356-941F-16B84DFB6435'
readonly EXPECTED_DATA_VOLUME_GROUP_UUID='AF638805-E0CB-4356-941F-16B84DFB6435'
readonly DISKUTIL='/usr/sbin/diskutil'
readonly PLUTIL='/usr/bin/plutil'
readonly EXPECTED_DISKUTIL_STAT='1152921500312576001:0:0:1:755:1943344:524320'
readonly EXPECTED_DISKUTIL_SHA256='9299ccac6acdf493796a88979d14ff464c1ec2196b167c879f023c2dbe9f3049'
readonly EXPECTED_PLUTIL_STAT='1152921500312572590:0:0:1:755:663776:524320'
readonly EXPECTED_PLUTIL_SHA256='983854d7c73e0bcdb6d50314e900e5d0a1313888727f8a69987c0c709e991c14'
readonly ROOT_CAPTURE_CHALLENGE='OPENSTEAMER_ROOT_EVIDENCE_CAPTURE_L1CIAB_V1'
readonly ROOT_CAPTURE_TRANSPORT='/Users/ahmed/Library/Application Support/opensteamer/.failed-installed-driver-both-order-mono-loopback-root-capture-L1Ciab.transport'
readonly ROOT_CAPTURE_PARTIAL='/Users/ahmed/Library/Application Support/opensteamer/.failed-installed-driver-both-order-mono-loopback-root-capture-L1Ciab.partial'
readonly ROOT_CAPTURE_READY='/Users/ahmed/Library/Application Support/opensteamer/failed-installed-driver-both-order-mono-loopback-root-capture-L1Ciab.envelope'
readonly ROOT_CAPTURE_MAX_PAYLOAD_BYTES='1048576'
readonly ROOT_CAPTURE_MAX_TRANSPORT_BYTES='2097280'
readonly PINNED_DEVELOPER_DIR='/Applications/Xcode-26.6.0.app/Contents/Developer'
readonly PINNED_RESOLVED_DEVELOPER_DIR='/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app/Contents/Developer'
readonly PINNED_SWIFTC='/Applications/Xcode-26.6.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'
readonly PINNED_XCRUN_SWIFTC="$PINNED_RESOLVED_DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
readonly PINNED_SWIFT_FRONTEND='/Applications/Xcode-26.6.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend'
readonly PINNED_CLANG='/Applications/Xcode-26.6.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang'
readonly EXPECTED_SWIFTC_VERSION=$'swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)\nTarget: arm64-apple-macosx26.0'
readonly EXPECTED_SWIFT_FRONTEND_SHA256='2ed38571e92c0283091838c1649e27650ad9c99950288e883c7b2dc6c4ce89fb'
readonly EXPECTED_CLANG_SHA256='7def90dd8829726686213a747fc5bff1583df933dae5edc55d755479e0bfe00a'
readonly USER_TRIAL_PARENT='/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1'
readonly TRIAL_ROOT='/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab'
readonly LEGACY_USER_STAGE_READY_ROOT='/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab.ready-pre-root-L1Ciab'
readonly USER_STAGE_READY_ROOT='/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab.ready-installed-driver-both-order-mono-loopback-L1Ciab'
readonly TRIAL_RUN_ROOT='/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab/paired-v7-update-local-mono-prep-L1Ciab'
readonly TRIAL_PROBES='/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab/paired-v7-update-local-mono-prep-L1Ciab/probes'
readonly USER_STAGE_DIR='/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab/staging'
readonly USER_CONTROLLER_STAGE='/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab/staging/opensteamer-local-mono-trial-controller'
readonly USER_GUARDIAN_STAGE='/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab/staging/opensteamer-v7-default-route-guardian'
readonly ACTIVE_POINTER='/Users/ahmed/Library/Application Support/opensteamer/active-local-mono-trial-v1'
readonly ACTIVE_POINTER_TEMP='/Users/ahmed/Library/Application Support/opensteamer/.active-local-mono-trial-v1.prep-L1Ciab.tmp'
readonly ROOT_SUPPORT='/Library/Application Support/opensteamer-local-mono-trial-v1'
readonly LEGACY_FRESH_ROOT_SUPPORT='/Library/Application Support/opensteamer-local-mono-trial-v1.fresh-coreaudio-kickstart-sip-L1Ciab'
readonly FRESH_ROOT_SUPPORT='/Library/Application Support/opensteamer-local-mono-trial-v1.fresh-installed-driver-both-order-mono-loopback-L1Ciab'
readonly ROOT_BROKER_SOCKET='/Library/Application Support/opensteamer-local-mono-trial-v1/broker-prep-L1Ciab.sock'
readonly PRODUCT_DRIVER='/Library/Audio/Plug-Ins/HAL/OpensteamerVirtualMicrophone.driver'
readonly FAILED_UID_TRIAL_ROOT='/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab.failed-uid-admission'
readonly FAILED_UID_ACTIVE_POINTER='/Users/ahmed/Library/Application Support/opensteamer/failed-active-local-mono-trial-v1.uid-admission-L1Ciab'
readonly FAILED_CANDIDATE_TRIAL_ROOT='/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab.failed-candidate-gate-coderesources-mode'
readonly FAILED_CANDIDATE_ROOT_SUPPORT='/Library/Application Support/opensteamer-local-mono-trial-v1.failed-candidate-gate-coderesources-mode-L1Ciab'
readonly RESCUED_TRIAL_ROOT='/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab.failed-coreaudio-kickstart-sip'
readonly RESCUED_ACTIVE_POINTER='/Users/ahmed/Library/Application Support/opensteamer/failed-active-local-mono-trial-v1.coreaudio-kickstart-sip-L1Ciab'
readonly FAILED_COREAUDIO_ROOT_SUPPORT='/Library/Application Support/opensteamer-local-mono-trial-v1.failed-coreaudio-kickstart-sip-L1Ciab'
readonly FAILED_LOOPBACK_TRIAL_ROOT='/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab.failed-installed-driver-both-order-mono-loopback'
readonly FAILED_LOOPBACK_ROOT_SUPPORT='/Library/Application Support/opensteamer-local-mono-trial-v1.failed-installed-driver-both-order-mono-loopback-L1Ciab'
readonly FAILED_UID_ACTIVE_POINTER_SHA256='09850c37ae89ace2d97ad94d4fa2cbb2fbaeb8fd6c574f502c3dc987816b6e44'
readonly FAILED_CANDIDATE_CONTROLLER_SHA256='c0173d7a480149b8a6609c5b2db5704c937d2446edc4ed27cf39647609fa50e9'
readonly FAILED_CANDIDATE_PROXY_ARM_SHA256='762e4244042e5593667d6244f2ab336cfd233b32021edc5c1ea114d50cc9bb42'
readonly FAILED_CANDIDATE_JOURNAL_SHA256='64c743b3951cfd0f00f60b94d120d12a7e5224dec011452e440400c898e6a0bc'
readonly FAILED_CANDIDATE_RESULT_SHA256='bcabd037e855f4db07d022dbceaeccf77ea0c35a097b143b4092c2c4aaf22582'
readonly FAILED_CANDIDATE_VPIO_STATE_SHA256='cb29ef29ff60298def9f9df4ef21754e3c632b1872b71f43b32c422a7673d543'
readonly FAILED_CANDIDATE_VPIO_REPAIR_SHA256='e6312897f09d3824e521f9eb2960d5dc6cf8ecf3e1a477920e7c61c0acdf30e4'
readonly FAILED_CANDIDATE_VPIO_SNAPSHOT_SHA256='f65aa65627562f1b4d1699461d0fed101daa3c5ec9e2785348ece9469b1e38a8'
readonly FAILED_CANDIDATE_VPIO_STDOUT_SHA256='0b5df24d785c26c04e8205d1e75249f3c98dfba6201110e15c0316f5f2e4a9c8'
readonly FAILED_CANDIDATE_VPIO_FINAL_SHA256='392e239499517333fc25c99d4420a0b786e7267dc76ad23c884b4b0f9213f2b7'
readonly RESCUED_CONTROLLER_SHA256='b2da40fa1a85cf00b9dfd84ec90b5ad71cba255c1cd4414e307e4596934b7d2e'
readonly RESCUED_CONTROLLER_PIN_SHA256='070cbb6a1bde9c0230fb1e8a27aef3bc4811be0c25a356448ca2aa1836520c54'
readonly RESCUED_ROOT_LOG_SHA256='21c50e4f479513403366762e57aee476c92f22678aa1a5c8a6b4053bbb84e708'
readonly RESCUED_ROOT_JOURNAL_SHA256='fe6e6d31b12e9f3216b0d9fc059fd962628a8709374f471abb8009fe459c2d7f'
readonly RESCUED_ROOT_DRIVER_IDENTITY_SHA256='24230285158c297e64c6e6480108148cab0e36b5fb6b02fb6e1a167a61ad2f25'
readonly RESCUED_TRIAL_JOURNAL_SHA256='287c0d14aaf0f57ba1b4e133233c3425d7de70a6890938f16cc5932cb776d625'
readonly RESCUED_PROXY_ARM_SHA256='6ffeb263e9fb9ec452deeae529450e5e3e972aa71fd042b0407fc8842cb320e1'
readonly RESCUED_ACTIVE_POINTER_SHA256='a91068fd7fa302984fb2639b14c5199e91f8873d3490e0034493d99dd0de0cd1'
readonly RESCUED_VPIO_STATE_SHA256='764ad56a633d19424112ca69cb02f93e09d18884ad28eed1539f12b2cbcce668'
readonly RESCUED_VPIO_SNAPSHOT_SHA256='f65aa65627562f1b4d1699461d0fed101daa3c5ec9e2785348ece9469b1e38a8'
readonly RESCUED_VPIO_FENCE_SHA256='c707e10d126b6421cdcdf94fce276fb972871d8d30ff415f7d2bffb195cef5a8'
readonly RESCUED_VPIO_REPAIR_SHA256='e6312897f09d3824e521f9eb2960d5dc6cf8ecf3e1a477920e7c61c0acdf30e4'
readonly RESCUED_VPIO_FINAL_SHA256='392e239499517333fc25c99d4420a0b786e7267dc76ad23c884b4b0f9213f2b7'
readonly RESCUED_GUARDIAN_STDOUT_SHA256='4620ef643e00c00cf5417a035ce17312651b2093ff653b4f5fe58cb337b5be34'
readonly FAILED_LOOPBACK_CONTROLLER_SHA256='bccf3739b2f5838ba17772107224673d62f606ca46d33f7fca2a4515382965fa'
readonly FAILED_LOOPBACK_GUARDIAN_SHA256='72ef50156a0154e3b6c9a84557f3c192b67ec69f7a9747476826fb9aa3d4509c'
readonly FAILED_LOOPBACK_JOURNAL_SHA256='f8829386d95dd6faa723038224db617773417fd80a9f0835872aba7ca278723d'
readonly FAILED_LOOPBACK_RESULT_SHA256='a355c42808bc108e029b1ec828b7f664d6596d7f4eb8bc8fc604b11ce403f8c0'
readonly FAILED_LOOPBACK_PROXY_ARM_SHA256='e6b23bf0c7b4784a61f7120565111fe60d61e7ee9717dd2dab79ba964232a39a'
readonly FAILED_LOOPBACK_MIRROR_SHA256='401734d5fdde6795159ebc3647447576612fa47995eaf7ba1368f5974cf2a890'
readonly FAILED_LOOPBACK_VPIO_STATE_SHA256='c4c6c983f036f38088e10215628440a8fbc86b0629e0b25217c955b9c292824b'
readonly FAILED_LOOPBACK_VPIO_SNAPSHOT_SHA256='f65aa65627562f1b4d1699461d0fed101daa3c5ec9e2785348ece9469b1e38a8'
readonly FAILED_LOOPBACK_VPIO_FENCE_SHA256='c707e10d126b6421cdcdf94fce276fb972871d8d30ff415f7d2bffb195cef5a8'
readonly FAILED_LOOPBACK_VPIO_REPAIR_SHA256='e571d808c76a0b9993c10ec2f9d250650ce57e7d521e0e9e44fc9f36662876af'
readonly FAILED_LOOPBACK_VPIO_EMERGENCY_SHA256='82c13e9b30139451662eb05845f9e9fd5b72e8e131afc4b820576816d27095fb'
readonly FAILED_LOOPBACK_VPIO_FINAL_SHA256='cab3a6da7d8cc97e41ea27fe888bb45290a65330ea0db63946a6795b02a633fb'
readonly FAILED_LOOPBACK_GUARDIAN_STDOUT_SHA256='96e43832c6bf13fc71084d5466e6e94f63fe2c5b3fc5e52e4039129f2088f9bb'
readonly EMPTY_SHA256='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'

typeset -gi AUTHORIZATION_ATTEMPTED=0
typeset -gi LAUNCHER_LOCK_FD=-1
typeset -gi LAUNCHER_LOCK_ACQUIRED=0
typeset -g RETRY_STATE=''
typeset -g USER_RETRY_STATE=''
typeset -g ROOT_RETRY_STATE=''
typeset -g DATA_VOLUME_DEVICE=''

# This is deliberately a fixed, self-pinned command: no mode argument, repo path, shell fragment,
# or password text is accepted from the caller. The OS-owned authorization dialog is the only
# credential UI. The broker inherits /dev/null plus a root-private log and then creates its own
# session/process group before it can mutate the exact product-driver path.
readonly ROOT_BOOTSTRAP_COMMAND='exec /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/var/root USER=root LOGNAME=root /usr/bin/perl - "/Library/Application Support/opensteamer-local-mono-trial-root-bootstrap-L1Ciab.lock" "/Library/Application Support/opensteamer-local-mono-trial-v1/opensteamer-local-mono-trial-controller" "/Library/Application Support/opensteamer-local-mono-trial-v1/root-broker.log" <<\OPENSTEAMER_ROOT_WRAPPER_L1CIAB
use strict;
use warnings;
use POSIX ();
use Digest::SHA qw(sha256_hex);
no warnings "once";
umask(077);
($> + 0) == 0 or exit 77;
my ($lock_path, $controller, $log) = @ARGV;
my @data_stat = lstat("/System/Volumes/Data");
my @parent_stat = lstat("/Library/Application Support");
@data_stat && (($data_stat[2] & 0177777) == 0040775) &&
    $data_stat[4] == 0 && $data_stat[5] == 80 &&
    @parent_stat && $parent_stat[0] == $data_stat[0] && $parent_stat[4] == 0 &&
    $parent_stat[5] == 80 && (($parent_stat[2] & 0177777) == 0040755) or exit 78;
my $diskutil_path = "/usr/sbin/diskutil";
sysopen(my $diskutil_file, $diskutil_path, 0x100) or exit 78;
binmode($diskutil_file);
my @diskutil_opened = stat($diskutil_file);
my @diskutil_named = lstat($diskutil_path);
@diskutil_opened && @diskutil_named &&
    join(":", @diskutil_opened[0, 1, 2, 3, 4, 5, 7, 9, 10]) eq
        join(":", @diskutil_named[0, 1, 2, 3, 4, 5, 7, 9, 10]) &&
    $diskutil_opened[0] == $data_stat[0] &&
    $diskutil_opened[1] == 1152921500312576001 && $diskutil_opened[4] == 0 &&
    $diskutil_opened[5] == 0 && $diskutil_opened[3] == 1 &&
    (($diskutil_opened[2] & 07777) == 0755) && $diskutil_opened[7] == 1943344
    or exit 78;
my $diskutil_bytes = "";
while (1) {
    my $chunk = "";
    my $count = sysread($diskutil_file, $chunk, 65_536);
    defined($count) or exit 78;
    last if $count == 0;
    length($diskutil_bytes) + $count <= 2_097_152 or exit 78;
    $diskutil_bytes .= $chunk;
}
sha256_hex($diskutil_bytes) eq
    "9299ccac6acdf493796a88979d14ff464c1ec2196b167c879f023c2dbe9f3049" or exit 78;
my @diskutil_after = stat($diskutil_file);
my @diskutil_named_after = lstat($diskutil_path);
@diskutil_after && @diskutil_named_after &&
    join(":", @diskutil_after[0, 1, 2, 3, 4, 5, 7, 9, 10]) eq
        join(":", @diskutil_opened[0, 1, 2, 3, 4, 5, 7, 9, 10]) &&
    join(":", @diskutil_named_after[0, 1, 2, 3, 4, 5, 7, 9, 10]) eq
        join(":", @diskutil_opened[0, 1, 2, 3, 4, 5, 7, 9, 10]) or exit 78;
close($diskutil_file) or exit 78;
my $volume_plist = bounded_command_output(
    time() + 5, $diskutil_path, "info", "-plist", "/System/Volumes/Data");
defined($volume_plist) && length($volume_plist) >= 256 &&
    length($volume_plist) <= 131_072 && $volume_plist !~ /[\x00\r]/ or exit 78;
sub exact_plist_string {
    my ($plist, $key) = @_;
    my @value = $plist =~ m{<key>\Q$key\E</key>\s*<string>([^<]+)</string>}g;
    return @value == 1 ? $value[0] : undef;
}
sub exact_plist_boolean {
    my ($plist, $key) = @_;
    my @value = $plist =~ m{<key>\Q$key\E</key>\s*<(true|false)/>}g;
    return @value == 1 ? $value[0] : undef;
}
defined(exact_plist_string($volume_plist, "VolumeUUID")) &&
    exact_plist_string($volume_plist, "VolumeUUID") eq
        "AF638805-E0CB-4356-941F-16B84DFB6435" &&
    defined(exact_plist_string($volume_plist, "APFSVolumeGroupID")) &&
    exact_plist_string($volume_plist, "APFSVolumeGroupID") eq
        "AF638805-E0CB-4356-941F-16B84DFB6435" &&
    defined(exact_plist_string($volume_plist, "MountPoint")) &&
    exact_plist_string($volume_plist, "MountPoint") eq "/System/Volumes/Data" &&
    defined(exact_plist_string($volume_plist, "FilesystemType")) &&
    exact_plist_string($volume_plist, "FilesystemType") eq "apfs" &&
    defined(exact_plist_boolean($volume_plist, "Internal")) &&
    exact_plist_boolean($volume_plist, "Internal") eq "true" or exit 78;
my @data_after = lstat("/System/Volumes/Data");
my @parent_after = lstat("/Library/Application Support");
@data_after && @parent_after &&
    join(":", @data_after[0, 1, 2, 3, 4, 5, 7]) eq
        join(":", @data_stat[0, 1, 2, 3, 4, 5, 7]) &&
    join(":", @parent_after[0, 1, 2, 3, 4, 5, 7]) eq
        join(":", @parent_stat[0, 1, 2, 3, 4, 5, 7]) or exit 78;
sysopen(my $lease, $lock_path, 0x300, 0600) or exit 79;
sub lease_identity_is_exact {
    my ($handle, $path) = @_;
    my @fd_stat = stat($handle);
    my @named_stat = lstat($path);
    return @fd_stat && @named_stat &&
        $fd_stat[0] == $named_stat[0] && $fd_stat[1] == $named_stat[1] &&
        (($fd_stat[2] & 0177777) == 0100600) &&
        (($named_stat[2] & 0177777) == 0100600) &&
        $fd_stat[3] == 1 && $fd_stat[4] == 0 && $fd_stat[5] == 80 && $fd_stat[7] == 0;
}
lease_identity_is_exact($lease, $lock_path) or exit 79;
flock($lease, 6) or exit 75;
lease_identity_is_exact($lease, $lock_path) or exit 79;
$SIG{"HUP"} = "IGNORE";
$SIG{"PIPE"} = "IGNORE";
my $lease_fd = fileno($lease);
defined($lease_fd) && $lease_fd >= 3 or exit 79;
sub bounded_command_output {
    my ($deadline, @command) = @_;
    my $remaining = $deadline - time();
    return undef if $remaining <= 0;
    my ($value, $ok, $pipe, $command_pid);
    {
        local $SIG{"ALRM"} = sub { die "command timeout\n"; };
        $ok = eval {
            alarm($remaining);
            $command_pid = open($pipe, "-|", @command);
            defined($command_pid) && $command_pid > 1 or die "command open failed\n";
            local $/;
            $value = <$pipe>;
            my $command_ok = close($pipe);
            undef($command_pid);
            $command_ok or die "command failed\n";
            alarm(0);
            1;
        };
        alarm(0);
    }
    if (!$ok && defined($command_pid)) {
        my $wait_result = waitpid($command_pid, POSIX::WNOHANG());
        if ($wait_result == 0) {
            kill(9, $command_pid);
            waitpid($command_pid, 0);
        }
        undef($command_pid);
        close($pipe) if defined(fileno($pipe));
    }
    return $ok ? $value : undef;
}
my $inner_payload;
{
    local $/;
    $inner_payload = <DATA>;
}
defined($inner_payload) && length($inner_payload) == 60624 &&
    index($inner_payload, "set -eu\numask 077\n") == 0 &&
    $inner_payload =~ /require_closed_root_tree \"\$trial_root_support\"\nrequire_root_phase_lease_held\n\z/
    or exit 79;
my $prepare = fork();
defined($prepare) or exit 70;
if ($prepare == 0) {
    fcntl($lease, 2, 0) or exit 127;
    $ENV{"OPENSTEAMER_ROOT_PHASE_LEASE_FD"} = "$lease_fd";
    open(STDIN, "<", "/dev/null") or exit 127;
    exec("/bin/sh", "-c", $inner_payload, "opensteamer-root-phase");
    exit 127;
}
waitpid($prepare, 0) == $prepare or exit 70;
my $prepare_status = $?;
exit(($prepare_status >> 8) || 1) if $prepare_status != 0;
pipe(my $event_read, my $event_write) or exit 70;
pipe(my $ack_read, my $ack_write) or exit 70;
my $supervisor = fork();
defined($supervisor) or exit 70;
if ($supervisor == 0) {
    close($event_read);
    close($ack_write);
    pipe(my $go_read, my $go_write) or exit 70;
    my $broker = fork();
    defined($broker) or exit 70;
    if ($broker == 0) {
        close($event_write);
        close($ack_read);
        close($go_write);
        my $go = "";
        my $go_count = sysread($go_read, $go, 1);
        exit 126 unless defined($go_count) && $go_count == 1 && $go eq "G";
        close($go_read);
        close($lease);
        open(STDIN, "<", "/dev/null") or exit 127;
        open(STDOUT, chr(62) . chr(62), $log) or exit 127;
        open(STDERR, chr(62) . chr(62), $log) or exit 127;
        %ENV = (
            LC_ALL => "C",
            PATH => "/usr/bin:/bin:/usr/sbin:/sbin",
            HOME => "/var/root",
            USER => "root",
            LOGNAME => "root",
        );
        exec({$controller} $controller, "--root-local-trial-broker");
        exit 127;
    }
    close($go_read);
    my $identity_deadline = time() + 5;
    my $broker_start = bounded_command_output(
        $identity_deadline, "/bin/ps", "-p", "$broker", "-o", "lstart=");
    my $broker_initial_pgid = bounded_command_output(
        $identity_deadline, "/bin/ps", "-p", "$broker", "-o", "pgid=");
    if (!defined($broker_start) || !defined($broker_initial_pgid)) {
        close($go_write);
        waitpid($broker, 0);
        exit 70;
    }
    $broker_start =~ s/[[:space:]]+\z//;
    $broker_initial_pgid =~ s/[[:space:]]//g;
    if ($broker_start !~ /\A[A-Z][a-z]{2} [A-Z][a-z]{2} [ 0-3][0-9] [0-2][0-9]:[0-5][0-9]:[0-6][0-9] [0-9]{4}\z/ ||
        $broker_initial_pgid !~ /\A[1-9][0-9]*\z/) {
        close($go_write);
        waitpid($broker, 0);
        exit 70;
    }
    my $pid_message = "PID $broker|$broker_start|$broker_initial_pgid\n";
    my $pid_written = syswrite($event_write, $pid_message);
    if (!defined($pid_written) || $pid_written != length($pid_message)) {
        close($go_write);
        waitpid($broker, 0);
        exit 70;
    }
    my $ack = "";
    my $ack_count = sysread($ack_read, $ack, 1);
    if (!defined($ack_count) || $ack_count != 1 || $ack ne "A") {
        close($go_write);
        waitpid($broker, 0);
        exit 70;
    }
    close($ack_read);
    syswrite($go_write, "G") == 1 or exit 70;
    close($go_write);
    my $ready = 0;
    my $visibility_deadline = time() + 15;
    while (time() < $visibility_deadline) {
        if (kill(0, $broker)) {
            my $start = bounded_command_output(
                $visibility_deadline, "/bin/ps", "-p", "$broker", "-o", "lstart=");
            my $pgid = bounded_command_output(
                $visibility_deadline, "/bin/ps", "-p", "$broker", "-o", "pgid=");
            my $uid = bounded_command_output(
                $visibility_deadline, "/bin/ps", "-p", "$broker", "-o", "uid=");
            my $comm = bounded_command_output(
                $visibility_deadline, "/bin/ps", "-ww", "-p", "$broker", "-o", "comm=");
            if (defined($start) && defined($pgid) && defined($uid) && defined($comm)) {
                $start =~ s/[[:space:]]+\z//;
                $pgid =~ s/[[:space:]]//g;
                $uid =~ s/[[:space:]]//g;
                $comm =~ s/\n\z//;
                if ($start eq $broker_start && $pgid eq "$broker" &&
                    $uid eq "0" && $comm eq $controller) {
                    $ready = 1;
                    last;
                }
            }
        } else {
            last;
        }
        select(undef, undef, undef, 0.1);
    }
    if (!$ready) {
        if (kill(0, $broker)) {
            my $term_result = kill(15, $broker);
            if ($term_result == 1) {
                for (my $attempt = 0; $attempt < 50 && kill(0, $broker); $attempt++) {
                    select(undef, undef, undef, 0.1);
                }
                kill(9, $broker) if kill(0, $broker);
            }
        }
        waitpid($broker, 0);
        syswrite($event_write, "FAILED\n");
        exit 1;
    }
    my $ready_message = "READY $broker\n";
    syswrite($event_write, $ready_message);
    exit 0;
}
close($event_write);
close($ack_read);
my $pid_line = <$event_read>;
if (!defined($pid_line) || $pid_line !~ /\APID ([1-9][0-9]*)\|([A-Z][a-z]{2} [A-Z][a-z]{2} [ 0-3][0-9] [0-2][0-9]:[0-5][0-9]:[0-6][0-9] [0-9]{4})\|([1-9][0-9]*)\n\z/) {
    close($ack_write);
    waitpid($supervisor, 0);
    exit 70;
}
my $broker_pid = $1;
my $broker_start = $2;
my $broker_initial_pgid = $3;
syswrite($ack_write, "A") == 1 or exit 70;
close($ack_write);
my $ready_line = <$event_read>;
close($event_read);
waitpid($supervisor, 0) == $supervisor or exit 70;
my $supervisor_status = $?;
my $broker_accepted = defined($ready_line) &&
    $ready_line eq "READY $broker_pid\n" && $supervisor_status == 0;
if (!$broker_accepted) {
    my $absent_samples = 0;
    my $fallback_deadline = time() + 20;
    while (time() < $fallback_deadline) {
        if (kill(0, $broker_pid)) {
            $absent_samples = 0;
            my $start = bounded_command_output(
                $fallback_deadline, "/bin/ps", "-p", "$broker_pid", "-o", "lstart=");
            my $pgid = bounded_command_output(
                $fallback_deadline, "/bin/ps", "-p", "$broker_pid", "-o", "pgid=");
            my $uid = bounded_command_output(
                $fallback_deadline, "/bin/ps", "-p", "$broker_pid", "-o", "uid=");
            my $comm = bounded_command_output(
                $fallback_deadline, "/bin/ps", "-ww", "-p", "$broker_pid", "-o", "comm=");
            if (defined($start) && defined($pgid) && defined($uid) && defined($comm)) {
                $start =~ s/[[:space:]]+\z//;
                last if $start ne $broker_start;
                $pgid =~ s/[[:space:]]//g;
                $uid =~ s/[[:space:]]//g;
                $comm =~ s/\n\z//;
                if ($pgid eq "$broker_pid" && $uid eq "0" && $comm eq $controller) {
                    $broker_accepted = 1;
                    last;
                }
            }
        } else {
            $absent_samples++;
            last if $absent_samples == 2;
        }
        select(undef, undef, undef, 0.1);
    }
}
if (!$broker_accepted) {
    my $preexec_kill_sent = 0;
    my $terminal_absent_samples = 0;
    while (1) {
        if (!kill(0, $broker_pid)) {
            $terminal_absent_samples++;
            exit 1 if $terminal_absent_samples == 2;
            select(undef, undef, undef, 0.1);
            next;
        }
        $terminal_absent_samples = 0;
        my $resolution_deadline = time() + 5;
        my $start = bounded_command_output(
            $resolution_deadline, "/bin/ps", "-p", "$broker_pid", "-o", "lstart=");
        my $pgid = bounded_command_output(
            $resolution_deadline, "/bin/ps", "-p", "$broker_pid", "-o", "pgid=");
        my $uid = bounded_command_output(
            $resolution_deadline, "/bin/ps", "-p", "$broker_pid", "-o", "uid=");
        my $state = bounded_command_output(
            $resolution_deadline, "/bin/ps", "-p", "$broker_pid", "-o", "state=");
        my $comm = bounded_command_output(
            $resolution_deadline, "/bin/ps", "-ww", "-p", "$broker_pid", "-o", "comm=");
        if (defined($start) && defined($pgid) && defined($uid) &&
            defined($state) && defined($comm)) {
            $start =~ s/[[:space:]]+\z//;
            $pgid =~ s/[[:space:]]//g;
            $uid =~ s/[[:space:]]//g;
            $state =~ s/[[:space:]]//g;
            $comm =~ s/\n\z//;
            exit 1 if $start ne $broker_start;
            exit 1 if $uid eq "0" &&
                ($pgid eq "$broker_pid" || $pgid eq $broker_initial_pgid) &&
                ($comm eq $controller || $comm eq "/usr/bin/perl") &&
                $state =~ /\AZ[+<NXLs]*\z/;
            if (!$preexec_kill_sent && $uid eq "0" &&
                $pgid eq "$broker_pid" && $comm eq $controller) {
                $broker_accepted = 1;
                last;
            }
            if (!$preexec_kill_sent && $uid eq "0" &&
                $pgid eq $broker_initial_pgid && $comm eq "/usr/bin/perl") {
                $! = 0;
                my $kill_result = kill(9, $broker_pid);
                my $kill_errno = $! + 0;
                $preexec_kill_sent = 1
                    if $kill_result == 1 || $kill_errno == 3;
            }
        }
        select(undef, undef, undef, 0.1);
    }
}
$broker_accepted or exit 1;
print "$broker_pid\n";
exit 0;
__DATA__
set -eu
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
trial_root_support="/Library/Application Support/opensteamer-local-mono-trial-v1"
trial_root_controller="/Library/Application Support/opensteamer-local-mono-trial-v1/opensteamer-local-mono-trial-controller"
trial_root_pin="/Library/Application Support/opensteamer-local-mono-trial-v1/controller.sha256"
trial_root_log="/Library/Application Support/opensteamer-local-mono-trial-v1/root-broker.log"
trial_root_socket="/Library/Application Support/opensteamer-local-mono-trial-v1/broker-prep-L1Ciab.sock"
trial_root_transaction="/Library/Application Support/opensteamer-local-mono-trial-v1/private-transaction-prep-L1Ciab"
trial_root_sealed="/Library/Application Support/opensteamer-local-mono-trial-v1/sealed-prep-L1Ciab"
trial_root_fresh="/Library/Application Support/opensteamer-local-mono-trial-v1.fresh-installed-driver-both-order-mono-loopback-L1Ciab"
trial_root_fresh_controller="$trial_root_fresh/opensteamer-local-mono-trial-controller"
trial_root_fresh_pin="$trial_root_fresh/controller.sha256"
trial_root_fresh_log="$trial_root_fresh/root-broker.log"
trial_root_phase_lock="/Library/Application Support/opensteamer-local-mono-trial-root-bootstrap-L1Ciab.lock"
trial_root_evidence_first="/Library/Application Support/opensteamer-local-mono-trial-v1.failed-root-prepare-pin-mode-L1Ciab"
trial_root_evidence_second="/Library/Application Support/opensteamer-local-mono-trial-v1.failed-uid-admission-L1Ciab"
trial_root_evidence_third="/Library/Application Support/opensteamer-local-mono-trial-v1.failed-candidate-gate-coderesources-mode-L1Ciab"
trial_root_evidence_fourth="/Library/Application Support/opensteamer-local-mono-trial-v1.failed-coreaudio-kickstart-sip-L1Ciab"
trial_root_evidence_fifth="/Library/Application Support/opensteamer-local-mono-trial-v1.failed-installed-driver-both-order-mono-loopback-L1Ciab"
trial_user_controller="/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab/staging/opensteamer-local-mono-trial-controller"
trial_user_stage_ready="/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab.ready-installed-driver-both-order-mono-loopback-L1Ciab"
trial_legacy_user_stage_ready="/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab.ready-pre-root-L1Ciab"
trial_u3_root="/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab.failed-installed-driver-both-order-mono-loopback"
trial_active_pointer="/Users/ahmed/Library/Application Support/opensteamer/active-local-mono-trial-v1"
trial_active_pointer_tmp="/Users/ahmed/Library/Application Support/opensteamer/.active-local-mono-trial-v1.prep-L1Ciab.tmp"
trial_proxy_arm="/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab/proxy.arm"
trial_stop_request="/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab/stop.request"
trial_product_driver="/Library/Audio/Plug-Ins/HAL/OpensteamerVirtualMicrophone.driver"
trial_expected_sha="4b066652df384925f4564271b00ae02c22df6bf5bd1402ea2659ab9b9508650b"
trial_expected_size="2064792"
trial_expected_guardian_sha="cc278c52c70da9aac41156a9f41079b90dae07bf6adc56ddd495c21d42d47244"
trial_expected_guardian_size="286968"
trial_failed_root_record_count="160"
trial_failed_root_metadata_sha="0c8be16eccd7ea0d7d1c9ebedc1f979c0677b894623ab11fdd178a2ec8f2035d"
trial_failed_root_hashes_sha="45a235137d71b9c1d32d9c708e9dd2d43ec4f0b5e67623e485a79ffd314e9160"
trial_data_mount="/System/Volumes/Data"
trial_data_uuid="AF638805-E0CB-4356-941F-16B84DFB6435"
trial_data_group_uuid="AF638805-E0CB-4356-941F-16B84DFB6435"
trial_data_device=""
trial_diskutil="/usr/sbin/diskutil"
trial_plutil="/usr/bin/plutil"

data_volume_plist_value() {
    trial_volume_plist=$1
    trial_volume_property=$2
    /usr/bin/printf "%s" "$trial_volume_plist" | /usr/bin/plutil \
        -extract "$trial_volume_property" raw -o - -
}

require_data_volume_identity() {
    [ -d "$trial_data_mount" ] && [ ! -L "$trial_data_mount" ]
    [ "$trial_data_mount" = "/System/Volumes/Data" ]
    [ "$(/usr/bin/stat -f "%u:%g:%Lp:%f" "$trial_data_mount")" = "0:80:775:0" ]
    [ -f "$trial_diskutil" ] && [ ! -L "$trial_diskutil" ] && [ -x "$trial_diskutil" ]
    [ -f "$trial_plutil" ] && [ ! -L "$trial_plutil" ] && [ -x "$trial_plutil" ]
    trial_mount_before=$(/usr/bin/stat -f "%d:%i:%u:%g:%Lp:%f" "$trial_data_mount")
    trial_device_before=${trial_mount_before%%:*}
    [ "$trial_device_before" -gt 0 ]
    [ "$(/usr/bin/stat -f "%d" "$trial_diskutil")" = "$trial_device_before" ]
    [ "$(/usr/bin/stat -f "%i:%u:%g:%l:%Lp:%z:%f" "$trial_diskutil")" = \
      "1152921500312576001:0:0:1:755:1943344:524320" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_diskutil" | /usr/bin/cut -d " " -f 1)" = \
      "9299ccac6acdf493796a88979d14ff464c1ec2196b167c879f023c2dbe9f3049" ]
    [ "$(/usr/bin/stat -f "%d" "$trial_plutil")" = "$trial_device_before" ]
    [ "$(/usr/bin/stat -f "%i:%u:%g:%l:%Lp:%z:%f" "$trial_plutil")" = \
      "1152921500312572590:0:0:1:755:663776:524320" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_plutil" | /usr/bin/cut -d " " -f 1)" = \
      "983854d7c73e0bcdb6d50314e900e5d0a1313888727f8a69987c0c709e991c14" ]
    /usr/bin/codesign --verify --strict "$trial_diskutil"
    /usr/bin/codesign --verify --strict "$trial_plutil"
    trial_volume_plist=$(/usr/sbin/diskutil info -plist "$trial_data_mount")
    [ "${#trial_volume_plist}" -ge 256 ] && [ "${#trial_volume_plist}" -le 131072 ]
    [ "$(data_volume_plist_value "$trial_volume_plist" VolumeUUID)" = "$trial_data_uuid" ]
    [ "$(data_volume_plist_value "$trial_volume_plist" APFSVolumeGroupID)" = \
      "$trial_data_group_uuid" ]
    [ "$(data_volume_plist_value "$trial_volume_plist" MountPoint)" = "$trial_data_mount" ]
    [ "$(data_volume_plist_value "$trial_volume_plist" FilesystemType)" = "apfs" ]
    [ "$(data_volume_plist_value "$trial_volume_plist" Internal)" = "true" ]
    trial_mount_after=$(/usr/bin/stat -f "%d:%i:%u:%g:%Lp:%f" "$trial_data_mount")
    [ "$trial_mount_after" = "$trial_mount_before" ]
    trial_data_device=${trial_mount_after%%:*}
    for trial_data_anchor in / /Users /Library "/Library/Application Support" \
        /Users/ahmed "/Users/ahmed/Library/Application Support/opensteamer"; do
        [ -d "$trial_data_anchor" ] && [ ! -L "$trial_data_anchor" ]
        [ "$(/usr/bin/stat -f "%d" "$trial_data_anchor")" = "$trial_data_device" ]
    done
}

require_plain_root_node() {
    trial_plain_node=$1
    trial_plain_xattrs=$(/usr/bin/xattr "$trial_plain_node")
    [ -z "$trial_plain_xattrs" ]
    trial_plain_acl=$(/bin/ls -lde "$trial_plain_node")
    [ "$(/usr/bin/printf "%s\n" "$trial_plain_acl" | /usr/bin/wc -l | /usr/bin/tr -d "[:space:]")" = "1" ]
}

require_root_phase_lease_node() {
    [ -f "$trial_root_phase_lock" ] && [ ! -L "$trial_root_phase_lock" ]
    [ "$(/usr/bin/stat -f "%d:%u:%g:%l:%Lp:%z:%f" "$trial_root_phase_lock")" = \
      "$trial_data_device:0:80:1:600:0:0" ]
    require_plain_root_node "$trial_root_phase_lock"
}

require_root_phase_lease_tool() {
    [ -d "/Library/Application Support" ] && [ ! -L "/Library/Application Support" ]
    [ "$(/usr/bin/stat -f "%d:%u:%g:%Lp:%f" "/Library/Application Support")" = \
      "$trial_data_device:0:80:755:0" ]
    [ -f /usr/bin/perl ] && [ ! -L /usr/bin/perl ] && [ -x /usr/bin/perl ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" /usr/bin/perl)" = \
      "$trial_data_device:1152921500312572547:0:0:1:755:101840:524320" ]
    [ "$(/usr/bin/shasum -a 256 /usr/bin/perl | /usr/bin/cut -d " " -f 1)" = \
      "abda2bfd23a6c9a8e57adf2291f0aea4abd8faf440558ee49fe4ced55e8d9ad0" ]
    /usr/bin/codesign --verify --strict /usr/bin/perl
}

require_root_phase_lease_held() {
    require_data_volume_identity
    require_root_phase_lease_tool
    require_root_phase_lease_node
    if /usr/bin/perl -e "my \$lease_fd = \$ENV{\"OPENSTEAMER_ROOT_PHASE_LEASE_FD\"}; defined(\$lease_fd) && \$lease_fd =~ /\\A[3-9][0-9]*\\z/ or exit 70; open(my \$inherited, \"<&=\$lease_fd\") or exit 70; close(\$inherited) or exit 70; sysopen(my \$probe, \$ARGV[0], 0x100) or exit 70; if (flock(\$probe, 6)) { flock(\$probe, 8); exit 71; } exit(((\$! + 0) == 35) ? 75 : 72)" "$trial_root_phase_lock"; then
        trial_root_phase_probe_status=0
    else
        trial_root_phase_probe_status=$?
    fi
    [ "$trial_root_phase_probe_status" = "75" ]
    require_root_phase_lease_node
}

require_closed_root_tree() {
    trial_closed_tree=$1
    set +e
    trial_closed_openers=$(/usr/sbin/lsof -Fn +D "$trial_closed_tree" 2>/dev/null)
    trial_closed_status=$?
    set -e
    [ "$trial_closed_status" = "1" ] && [ -z "$trial_closed_openers" ]
}

require_root_socket() {
    trial_socket_path=$1
    [ -S "$trial_socket_path" ] && [ ! -L "$trial_socket_path" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_socket_path")" = "$trial_data_device:27093415:501:20:1:600:0:0" ]
    trial_socket_acl=$(/bin/ls -lde "$trial_socket_path")
    [ "$(/usr/bin/printf "%s\n" "$trial_socket_acl" | /usr/bin/wc -l | /usr/bin/tr -d "[:space:]")" = "1" ]
    set +e
    trial_socket_xattrs=$(/usr/bin/xattr "$trial_socket_path" 2>&1)
    trial_socket_xattr_status=$?
    set -e
    trial_socket_expected=$(/usr/bin/printf "xattr: [Errno 102] Operation not supported on socket: \047%s\047" "$trial_socket_path")
    [ "$trial_socket_xattr_status" = "1" ] && [ "$trial_socket_xattrs" = "$trial_socket_expected" ]
    set +e
    trial_socket_openers=$(/usr/sbin/lsof -Fn -- "$trial_socket_path" 2>/dev/null)
    trial_socket_lsof_status=$?
    set -e
    [ "$trial_socket_lsof_status" = "1" ] && [ -z "$trial_socket_openers" ]
}

require_failed_driver_tree() {
    trial_driver=$1
    [ -d "$trial_driver" ] && [ ! -L "$trial_driver" ]
    for trial_driver_directory in \
        "$trial_driver/Contents" "$trial_driver/Contents/MacOS" \
        "$trial_driver/Contents/Resources" "$trial_driver/Contents/Resources/en.lproj" \
        "$trial_driver/Contents/_CodeSignature"; do
        [ -d "$trial_driver_directory" ] && [ ! -L "$trial_driver_directory" ]
    done
    for trial_driver_regular in \
        "$trial_driver/Contents/Info.plist" \
        "$trial_driver/Contents/MacOS/OpensteamerVirtualMicrophone" \
        "$trial_driver/Contents/Resources/APPLE_SAMPLE_LICENSE.txt" \
        "$trial_driver/Contents/Resources/en.lproj/Localizable.strings" \
        "$trial_driver/Contents/_CodeSignature/CodeResources"; do
        [ -f "$trial_driver_regular" ] && [ ! -L "$trial_driver_regular" ]
    done
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_driver")" = "$trial_data_device:27093391:0:0:3:755:96:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_driver/Contents")" = "$trial_data_device:27093392:0:0:6:755:192:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_driver/Contents/Info.plist")" = "$trial_data_device:27093401:0:0:1:644:1165:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_driver/Contents/MacOS")" = "$trial_data_device:27093395:0:0:3:755:96:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_driver/Contents/MacOS/OpensteamerVirtualMicrophone")" = "$trial_data_device:27093396:0:0:1:755:169792:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_driver/Contents/Resources")" = "$trial_data_device:27093397:0:0:4:755:128:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_driver/Contents/Resources/APPLE_SAMPLE_LICENSE.txt")" = "$trial_data_device:27093400:0:0:1:644:1053:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_driver/Contents/Resources/en.lproj")" = "$trial_data_device:27093398:0:0:3:755:96:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_driver/Contents/Resources/en.lproj/Localizable.strings")" = "$trial_data_device:27093399:0:0:1:644:202:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_driver/Contents/_CodeSignature")" = "$trial_data_device:27093393:0:0:3:755:96:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_driver/Contents/_CodeSignature/CodeResources")" = "$trial_data_device:27093394:0:0:1:644:2841:0" ]
    trial_driver_entries=$(/usr/bin/find "$trial_driver" -xdev -print | /usr/bin/sort)
    trial_driver_expected=$(/usr/bin/printf "%s\n" \
        "$trial_driver" "$trial_driver/Contents" "$trial_driver/Contents/Info.plist" \
        "$trial_driver/Contents/MacOS" "$trial_driver/Contents/MacOS/OpensteamerVirtualMicrophone" \
        "$trial_driver/Contents/Resources" "$trial_driver/Contents/Resources/APPLE_SAMPLE_LICENSE.txt" \
        "$trial_driver/Contents/Resources/en.lproj" \
        "$trial_driver/Contents/Resources/en.lproj/Localizable.strings" \
        "$trial_driver/Contents/_CodeSignature" \
        "$trial_driver/Contents/_CodeSignature/CodeResources" | /usr/bin/sort)
    [ "$trial_driver_entries" = "$trial_driver_expected" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_driver/Contents/Info.plist" | /usr/bin/cut -d " " -f 1)" = "6e2fa0980cd27498ffe1075bcd439e61fcb0b6d38827ca2dadc3a7d6872e84e1" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_driver/Contents/MacOS/OpensteamerVirtualMicrophone" | /usr/bin/cut -d " " -f 1)" = "e78bfe1080660de99769d0f9313459fb22a08863d4ade52d25921db871383745" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_driver/Contents/Resources/APPLE_SAMPLE_LICENSE.txt" | /usr/bin/cut -d " " -f 1)" = "63202ae6ab294069b6f77114f0cce8f35531bbb75355f1d96c8db68f949acdc5" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_driver/Contents/Resources/en.lproj/Localizable.strings" | /usr/bin/cut -d " " -f 1)" = "4798181065dbb851f0de518be396d6d4f8a465158923adf16bbf91bcb826a166" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_driver/Contents/_CodeSignature/CodeResources" | /usr/bin/cut -d " " -f 1)" = "92c1b53f174dd64d1835fa9b2ecbddd84eac815ad43bbe231090d214b1cc9731" ]
    for trial_driver_node in \
        "$trial_driver" "$trial_driver/Contents" "$trial_driver/Contents/Info.plist" \
        "$trial_driver/Contents/MacOS" "$trial_driver/Contents/MacOS/OpensteamerVirtualMicrophone" \
        "$trial_driver/Contents/Resources" "$trial_driver/Contents/Resources/APPLE_SAMPLE_LICENSE.txt" \
        "$trial_driver/Contents/Resources/en.lproj" \
        "$trial_driver/Contents/Resources/en.lproj/Localizable.strings" \
        "$trial_driver/Contents/_CodeSignature" \
        "$trial_driver/Contents/_CodeSignature/CodeResources"; do
        require_plain_root_node "$trial_driver_node"
    done
    /usr/bin/codesign --verify --strict --all-architectures "$trial_driver"
    trial_driver_signature=$(/usr/bin/codesign -d --verbose=4 "$trial_driver" 2>&1)
    [ "$(/usr/bin/printf "%s\n" "$trial_driver_signature" | /usr/bin/grep -F -x -c "Identifier=com.elamin.opensteamer.VirtualMicrophoneDriver")" = "1" ]
    [ "$(/usr/bin/printf "%s\n" "$trial_driver_signature" | /usr/bin/grep -F -x -c "TeamIdentifier=MSMG8CJLB3")" = "1" ]
    [ "$(/usr/bin/printf "%s\n" "$trial_driver_signature" | /usr/bin/grep -F -x -c "CDHash=136282fbe7626c26618738e739eea2b0df2b59d5")" = "1" ]
    [ "$(/usr/bin/printf "%s\n" "$trial_driver_signature" | /usr/bin/grep -F -x -c "Authority=Apple Development: Ahmed Elamin (92LVX32M8K)")" = "1" ]
    [ "$(/usr/bin/printf "%s\n" "$trial_driver_signature" | /usr/bin/grep -F -c "flags=0x10000(runtime)")" = "1" ]
}

require_sealed_host_tree() {
    trial_sealed_host=$1
    trial_sealed_expected_metadata_sha=$2
    [ -d "$trial_sealed_host" ] && [ ! -L "$trial_sealed_host" ]
    trial_sealed_host_count=$(/usr/bin/find "$trial_sealed_host" -xdev -print | /usr/bin/wc -l | /usr/bin/tr -d "[:space:]")
    [ "$trial_sealed_host_count" = "134" ]
    trial_sealed_metadata=$(/usr/bin/find "$trial_sealed_host" -xdev -exec \
        /usr/bin/stat -f "%N|%HT|%d:%i:%u:%g:%l:%Lp:%z:%f|%Y" {} \;)
    trial_sealed_metadata_sha=$(/usr/bin/printf "%s\n" "$trial_sealed_metadata" | \
        /usr/bin/sed "s#$trial_sealed_host#.#g;s/|$trial_data_device:/|DATA_VOLUME_DEVICE:/g" | \
        /usr/bin/sort | \
        /usr/bin/shasum -a 256 | /usr/bin/cut -d " " -f 1)
    [ "$trial_sealed_metadata_sha" = "$trial_sealed_expected_metadata_sha" ]
    trial_sealed_hashes=$(/usr/bin/find "$trial_sealed_host" -xdev -type f -exec \
        /usr/bin/shasum -a 256 {} \;)
    trial_sealed_hashes_sha=$(/usr/bin/printf "%s\n" "$trial_sealed_hashes" | \
        /usr/bin/sed "s#$trial_sealed_host#.#g" | /usr/bin/sort | \
        /usr/bin/shasum -a 256 | /usr/bin/cut -d " " -f 1)
    [ "$trial_sealed_hashes_sha" = "8acd0e28c03f4808a50554f706e742e0a91b02179ce8fd7a0fe63d8ee6919725" ]
    trial_sealed_xattrs=$(/usr/bin/xattr -lr "$trial_sealed_host")
    [ -z "$trial_sealed_xattrs" ]
    trial_sealed_acl_lines=$(/usr/bin/find "$trial_sealed_host" -xdev -exec /bin/ls -lde {} \; | \
        /usr/bin/wc -l | /usr/bin/tr -d "[:space:]")
    [ "$trial_sealed_acl_lines" = "134" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_sealed_host/Contents/MacOS/CaptureServer" | /usr/bin/cut -d " " -f 1)" = "04ee090a3ad79ce08ff62c09e6872a292ea22f645423430ea1cff0f5475a46d6" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_sealed_host/Contents/Frameworks/LiveKitWebRTC.framework/Versions/A/LiveKitWebRTC" | /usr/bin/cut -d " " -f 1)" = "6963873e510a4022108dfd7106c0cac3467da0b74b6d6635a38865764f114d1b" ]
    /usr/bin/codesign --verify --strict --all-architectures "$trial_sealed_host"
    trial_sealed_signature=$(/usr/bin/codesign -d --verbose=4 "$trial_sealed_host" 2>&1)
    [ "$(/usr/bin/printf "%s\n" "$trial_sealed_signature" | /usr/bin/grep -F -x -c "Identifier=com.elamin.AudioStreamer.CaptureServer")" = "1" ]
    [ "$(/usr/bin/printf "%s\n" "$trial_sealed_signature" | /usr/bin/grep -F -x -c "TeamIdentifier=MSMG8CJLB3")" = "1" ]
    [ "$(/usr/bin/printf "%s\n" "$trial_sealed_signature" | /usr/bin/grep -F -x -c "CDHash=af8181f6c0e81fc5824d1b9ff36dbb36a25ad18b")" = "1" ]
    [ "$(/usr/bin/printf "%s\n" "$trial_sealed_signature" | /usr/bin/grep -F -x -c "Authority=Apple Development: Ahmed Elamin (92LVX32M8K)")" = "1" ]
}

require_prior_user_evidence_root() {
    trial_uid_evidence="/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab.failed-uid-admission"
    trial_uid_pointer="/Users/ahmed/Library/Application Support/opensteamer/failed-active-local-mono-trial-v1.uid-admission-L1Ciab"
    trial_candidate_evidence="/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab.failed-candidate-gate-coderesources-mode"
    [ -d "$trial_uid_evidence" ] && [ ! -L "$trial_uid_evidence" ]
    [ -f "$trial_uid_pointer" ] && [ ! -L "$trial_uid_pointer" ]
    [ -d "$trial_candidate_evidence" ] && [ ! -L "$trial_candidate_evidence" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_uid_evidence")" = "$trial_data_device:27016241:501:20:7:700:224:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_uid_pointer")" = "$trial_data_device:27017103:501:20:1:600:228:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_candidate_evidence")" = "$trial_data_device:27021633:501:20:7:700:224:0" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_uid_pointer" | /usr/bin/cut -d " " -f 1)" = "09850c37ae89ace2d97ad94d4fa2cbb2fbaeb8fd6c574f502c3dc987816b6e44" ]
    require_fixed_user_tree_digest "$trial_uid_evidence" "9" \
        "95bda3f874e5057e4e9a785a3d321698a4bbf2b2db31e6388858a7b443231aac" \
        "a82bb43d045de21a89274bf2598c8d33c7a6b371369be992d7104c81ede9a05e"
    require_fixed_user_tree_digest "$trial_candidate_evidence" "15" \
        "f303cc5e7c8c70153e7c2dd387c685d690380a1c5cb803b34b73ca81cd0a1943" \
        "f777ae709da3ef3d9c4fc365d490f466f5adf9eee0a25ea14d56cad26b52af9a"
    for trial_prior_user in "$trial_uid_evidence" "$trial_uid_pointer" "$trial_candidate_evidence"; do
        require_plain_root_node "$trial_prior_user"
    done
    require_closed_root_tree "$trial_uid_evidence"
    require_closed_root_tree "$trial_candidate_evidence"
    set +e
    trial_uid_pointer_openers=$(/usr/sbin/lsof -Fn -- "$trial_uid_pointer" 2>/dev/null)
    trial_uid_pointer_status=$?
    set -e
    [ "$trial_uid_pointer_status" = "1" ] && [ -z "$trial_uid_pointer_openers" ]
}

require_u2_user_evidence_root() {
    trial_u2_root="/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab.failed-coreaudio-kickstart-sip"
    trial_u2_run="$trial_u2_root/paired-v7-update-local-mono-prep-L1Ciab"
    trial_u2_probes="$trial_u2_run/probes"
    trial_u2_staging="$trial_u2_root/staging"
    trial_u2_controller="$trial_u2_staging/opensteamer-local-mono-trial-controller"
    trial_u2_guardian="$trial_u2_staging/opensteamer-v7-default-route-guardian"
    trial_u2_journal="$trial_u2_root/journal.log"
    trial_u2_result="$trial_u2_root/result.txt"
    trial_u2_arm="$trial_u2_root/proxy.arm"
    trial_u2_state="$trial_u2_probes/vpio-default-route-state.json"
    trial_u2_stdout="$trial_u2_probes/vpio-guardian.stdout"
    trial_u2_stderr="$trial_u2_probes/vpio-guardian.stderr"
    trial_u2_snapshot="$trial_u2_probes/vpio-guardian-snapshot.json"
    trial_u2_fence="$trial_u2_probes/vpio-guardian-prestop-fence.json"
    trial_u2_repair="$trial_u2_probes/vpio-guardian-repair.json"
    trial_u2_final="$trial_u2_probes/vpio-guardian-final.json"
    trial_u2_pointer="/Users/ahmed/Library/Application Support/opensteamer/failed-active-local-mono-trial-v1.coreaudio-kickstart-sip-L1Ciab"
    [ -d "$trial_u2_root" ] && [ ! -L "$trial_u2_root" ]
    [ -d "$trial_u2_run" ] && [ ! -L "$trial_u2_run" ]
    [ -d "$trial_u2_probes" ] && [ ! -L "$trial_u2_probes" ]
    [ -d "$trial_u2_staging" ] && [ ! -L "$trial_u2_staging" ]
    [ -f "$trial_u2_pointer" ] && [ ! -L "$trial_u2_pointer" ]
    for trial_u2_regular in "$trial_u2_controller" "$trial_u2_guardian" "$trial_u2_journal" \
        "$trial_u2_result" "$trial_u2_arm" "$trial_u2_state" "$trial_u2_stdout" \
        "$trial_u2_stderr" "$trial_u2_snapshot" "$trial_u2_fence" "$trial_u2_repair" \
        "$trial_u2_final"; do
        [ -f "$trial_u2_regular" ] && [ ! -L "$trial_u2_regular" ]
    done
    [ "$(/usr/bin/find "$trial_u2_root" -xdev -mindepth 1 -maxdepth 1 -print | /usr/bin/sort)" = "$(/usr/bin/printf "%s\n" "$trial_u2_journal" "$trial_u2_run" "$trial_u2_arm" "$trial_u2_result" "$trial_u2_staging" | /usr/bin/sort)" ]
    [ "$(/usr/bin/find "$trial_u2_run" -xdev -mindepth 1 -maxdepth 1 -print)" = "$trial_u2_probes" ]
    [ "$(/usr/bin/find "$trial_u2_probes" -xdev -mindepth 1 -maxdepth 1 -print | /usr/bin/sort)" = "$(/usr/bin/printf "%s\n" "$trial_u2_state" "$trial_u2_stdout" "$trial_u2_stderr" "$trial_u2_snapshot" "$trial_u2_fence" "$trial_u2_repair" "$trial_u2_final" | /usr/bin/sort)" ]
    [ "$(/usr/bin/find "$trial_u2_staging" -xdev -mindepth 1 -maxdepth 1 -print | /usr/bin/sort)" = "$(/usr/bin/printf "%s\n" "$trial_u2_controller" "$trial_u2_guardian" | /usr/bin/sort)" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_u2_root")" = "$trial_data_device:27092973:501:20:7:700:224:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_u2_run")" = "$trial_data_device:27092974:501:20:3:700:96:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_u2_probes")" = "$trial_data_device:27092975:501:20:9:700:288:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_u2_staging")" = "$trial_data_device:27092976:501:20:4:700:128:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_u2_controller")" = "$trial_data_device:27092977:501:20:1:500:1443880:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_u2_guardian")" = "$trial_data_device:27092978:501:20:1:500:258696:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_u2_journal")" = "$trial_data_device:27093241:501:20:1:600:95:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_u2_result")" = "$trial_data_device:27093242:501:20:1:600:0:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_u2_arm")" = "$trial_data_device:27093462:501:20:1:600:102:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_u2_state")" = "$trial_data_device:27093676:501:20:1:600:288:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_u2_stdout")" = "$trial_data_device:27093674:501:20:1:600:67:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_u2_stderr")" = "$trial_data_device:27093675:501:20:1:600:0:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_u2_snapshot")" = "$trial_data_device:27093679:501:20:1:600:1275:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_u2_fence")" = "$trial_data_device:27093690:501:20:1:600:1272:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_u2_repair")" = "$trial_data_device:27093881:501:20:1:600:1273:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_u2_final")" = "$trial_data_device:27093884:501:20:1:600:1271:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_u2_pointer")" = "$trial_data_device:27093461:501:20:1:600:228:0" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_u2_controller" | /usr/bin/cut -d " " -f 1)" = "b2da40fa1a85cf00b9dfd84ec90b5ad71cba255c1cd4414e307e4596934b7d2e" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_u2_guardian" | /usr/bin/cut -d " " -f 1)" = "72ef50156a0154e3b6c9a84557f3c192b67ec69f7a9747476826fb9aa3d4509c" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_u2_journal" | /usr/bin/cut -d " " -f 1)" = "287c0d14aaf0f57ba1b4e133233c3425d7de70a6890938f16cc5932cb776d625" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_u2_result" | /usr/bin/cut -d " " -f 1)" = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_u2_arm" | /usr/bin/cut -d " " -f 1)" = "6ffeb263e9fb9ec452deeae529450e5e3e972aa71fd042b0407fc8842cb320e1" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_u2_state" | /usr/bin/cut -d " " -f 1)" = "764ad56a633d19424112ca69cb02f93e09d18884ad28eed1539f12b2cbcce668" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_u2_stdout" | /usr/bin/cut -d " " -f 1)" = "4620ef643e00c00cf5417a035ce17312651b2093ff653b4f5fe58cb337b5be34" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_u2_stderr" | /usr/bin/cut -d " " -f 1)" = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_u2_snapshot" | /usr/bin/cut -d " " -f 1)" = "f65aa65627562f1b4d1699461d0fed101daa3c5ec9e2785348ece9469b1e38a8" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_u2_fence" | /usr/bin/cut -d " " -f 1)" = "c707e10d126b6421cdcdf94fce276fb972871d8d30ff415f7d2bffb195cef5a8" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_u2_repair" | /usr/bin/cut -d " " -f 1)" = "e6312897f09d3824e521f9eb2960d5dc6cf8ecf3e1a477920e7c61c0acdf30e4" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_u2_final" | /usr/bin/cut -d " " -f 1)" = "392e239499517333fc25c99d4420a0b786e7267dc76ad23c884b4b0f9213f2b7" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_u2_pointer" | /usr/bin/cut -d " " -f 1)" = "a91068fd7fa302984fb2639b14c5199e91f8873d3490e0034493d99dd0de0cd1" ]
    [ "$(/bin/cat "$trial_u2_journal")" = "OPENSTEAMER_LOCAL_MONO_TRIAL_V1
STATE USER_STAGE_VERIFIED
STATE ROOT_OWNED_UID_PROXY pid=21660" ]
    [ "$(/bin/cat "$trial_u2_arm")" = "schema=opensteamer.local-mono-trial-proxy-arm.v1
proxy_pid=21660
proxy_start=Sun Aug 16 14:34:47 2026" ]
    [ "$(/bin/cat "$trial_u2_stdout")" = "GUARDIAN_BROKER_READY
GUARDIAN_BROKER_CHECKED
GUARDIAN_BROKER_PONG" ]
    [ "$(/bin/cat "$trial_u2_pointer")" = "schema=opensteamer.local-mono-trial-pointer.v1
trial_root=/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab
state=arming
proxy_pid=21660
proxy_start=Sun Aug 16 14:34:47 2026
state=armed" ]
    for trial_u2_plain in "$trial_u2_root" "$trial_u2_run" "$trial_u2_probes" "$trial_u2_staging" \
        "$trial_u2_controller" "$trial_u2_guardian" "$trial_u2_journal" "$trial_u2_result" \
        "$trial_u2_arm" "$trial_u2_state" "$trial_u2_stdout" "$trial_u2_stderr" \
        "$trial_u2_snapshot" "$trial_u2_fence" "$trial_u2_repair" "$trial_u2_final" \
        "$trial_u2_pointer"; do
        require_plain_root_node "$trial_u2_plain"
    done
    require_closed_root_tree "$trial_u2_root"
    set +e
    trial_u2_pointer_openers=$(/usr/sbin/lsof -Fn -- "$trial_u2_pointer" 2>/dev/null)
    trial_u2_pointer_status=$?
    set -e
    [ "$trial_u2_pointer_status" = "1" ] && [ -z "$trial_u2_pointer_openers" ]
}

require_u3_user_evidence_root() {
    [ -d "$trial_u3_root" ] && [ ! -L "$trial_u3_root" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_u3_root")" = \
      "$trial_data_device:27209349:501:20:7:700:224:0" ]
    require_fixed_user_tree_digest "$trial_u3_root" "20" \
        "3a889d42ec394ce5b796efff8eb32f432ffd5e448f8c30d1bceb3748b3179247" \
        "1f93586f32a1669db13a13cd2dbe7b5a82f9d82400df8115ec02ba63365f0e9f"
}

require_fresh_user_stage_root() {
    trial_stage_root="/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab"
    trial_stage_run="$trial_stage_root/paired-v7-update-local-mono-prep-L1Ciab"
    trial_stage_probes="$trial_stage_run/probes"
    trial_stage_staging="$trial_stage_root/staging"
    trial_stage_controller="$trial_stage_staging/opensteamer-local-mono-trial-controller"
    trial_stage_guardian="$trial_stage_staging/opensteamer-v7-default-route-guardian"
    [ -d "$trial_stage_root" ] && [ ! -L "$trial_stage_root" ]
    [ -d "$trial_stage_run" ] && [ ! -L "$trial_stage_run" ]
    [ -d "$trial_stage_probes" ] && [ ! -L "$trial_stage_probes" ]
    [ -d "$trial_stage_staging" ] && [ ! -L "$trial_stage_staging" ]
    [ -f "$trial_stage_controller" ] && [ ! -L "$trial_stage_controller" ]
    [ -f "$trial_stage_guardian" ] && [ ! -L "$trial_stage_guardian" ]
    [ "$(/usr/bin/find "$trial_stage_root" -xdev -mindepth 1 -maxdepth 1 -print | /usr/bin/sort)" = "$(/usr/bin/printf "%s\n" "$trial_stage_run" "$trial_stage_staging" | /usr/bin/sort)" ]
    [ "$(/usr/bin/find "$trial_stage_run" -xdev -mindepth 1 -maxdepth 1 -print)" = "$trial_stage_probes" ]
    [ -z "$(/usr/bin/find "$trial_stage_probes" -xdev -mindepth 1 -maxdepth 1 -print)" ]
    [ "$(/usr/bin/find "$trial_stage_staging" -xdev -mindepth 1 -maxdepth 1 -print | /usr/bin/sort)" = "$(/usr/bin/printf "%s\n" "$trial_stage_controller" "$trial_stage_guardian" | /usr/bin/sort)" ]
    [ "$(/usr/bin/stat -f "%u:%g:%l:%Lp:%z:%f" "$trial_stage_root")" = "501:20:4:700:128:0" ]
    [ "$(/usr/bin/stat -f "%u:%g:%l:%Lp:%z:%f" "$trial_stage_run")" = "501:20:3:700:96:0" ]
    [ "$(/usr/bin/stat -f "%u:%g:%l:%Lp:%z:%f" "$trial_stage_probes")" = "501:20:2:700:64:0" ]
    [ "$(/usr/bin/stat -f "%u:%g:%l:%Lp:%z:%f" "$trial_stage_staging")" = "501:20:4:700:128:0" ]
    [ "$(/usr/bin/stat -f "%u:%g:%l:%Lp:%z:%f" "$trial_stage_controller")" = "501:20:1:500:$trial_expected_size:0" ]
    [ "$(/usr/bin/stat -f "%u:%g:%l:%Lp:%z:%f" "$trial_stage_guardian")" = "501:20:1:500:$trial_expected_guardian_size:0" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_stage_controller" | /usr/bin/cut -d " " -f 1)" = "$trial_expected_sha" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_stage_guardian" | /usr/bin/cut -d " " -f 1)" = "$trial_expected_guardian_sha" ]
    for trial_stage_plain in "$trial_stage_root" "$trial_stage_run" "$trial_stage_probes" \
        "$trial_stage_staging" "$trial_stage_controller" "$trial_stage_guardian"; do
        require_plain_root_node "$trial_stage_plain"
    done
    require_closed_root_tree "$trial_stage_root"
}

fresh_user_stage_identity() {
    /usr/bin/stat -f "%d:%i" "$trial_stage_root" "$trial_stage_run" "$trial_stage_probes" \
        "$trial_stage_staging" "$trial_stage_controller" "$trial_stage_guardian" | \
        /usr/bin/tr "\n" ":"
}

require_fixed_user_tree_digest() {
    trial_fixed_user_tree=$1
    trial_fixed_user_count=$2
    trial_fixed_user_metadata_sha=$3
    trial_fixed_user_hashes_sha=$4
    [ -d "$trial_fixed_user_tree" ] && [ ! -L "$trial_fixed_user_tree" ]
    trial_fixed_user_actual_count=$(/usr/bin/find "$trial_fixed_user_tree" -xdev -print | \
        /usr/bin/wc -l | /usr/bin/tr -d "[:space:]")
    [ "$trial_fixed_user_actual_count" = "$trial_fixed_user_count" ]
    trial_fixed_user_metadata=$(/usr/bin/find "$trial_fixed_user_tree" -xdev -exec \
        /usr/bin/stat -f "%N|%HT|%d:%i:%u:%g:%l:%Lp:%z:%f|%Y" {} \;)
    [ "$(/usr/bin/printf "%s\n" "$trial_fixed_user_metadata" | \
        /usr/bin/sed "s#$trial_fixed_user_tree#.#g;s/|$trial_data_device:/|DATA_VOLUME_DEVICE:/g" | \
        /usr/bin/sort | \
        /usr/bin/shasum -a 256 | /usr/bin/cut -d " " -f 1)" = \
      "$trial_fixed_user_metadata_sha" ]
    trial_fixed_user_hashes=$(/usr/bin/find "$trial_fixed_user_tree" -xdev -type f -exec \
        /usr/bin/shasum -a 256 {} \;)
    [ "$(/usr/bin/printf "%s\n" "$trial_fixed_user_hashes" | \
        /usr/bin/sed "s#$trial_fixed_user_tree#.#g" | /usr/bin/sort | \
        /usr/bin/shasum -a 256 | /usr/bin/cut -d " " -f 1)" = \
      "$trial_fixed_user_hashes_sha" ]
    [ -z "$(/usr/bin/xattr -lr "$trial_fixed_user_tree")" ]
    [ "$(/usr/bin/find "$trial_fixed_user_tree" -xdev -exec /bin/ls -lde {} \; | \
        /usr/bin/wc -l | /usr/bin/tr -d "[:space:]")" = "$trial_fixed_user_count" ]
    require_closed_root_tree "$trial_fixed_user_tree"
}

require_safe_partial_fresh_root_support() {
    if [ ! -e "$trial_root_fresh" ] && [ ! -L "$trial_root_fresh" ]; then
        return 0
    fi
    [ -d "$trial_root_fresh" ] && [ ! -L "$trial_root_fresh" ]
    trial_fresh_entries=$(/usr/bin/find "$trial_root_fresh" -xdev -mindepth 1 -maxdepth 1 -print)
    trial_fresh_entry_count=0
    if [ -n "$trial_fresh_entries" ]; then
        trial_fresh_entry_count=$(/usr/bin/printf "%s\n" "$trial_fresh_entries" | \
            /usr/bin/wc -l | /usr/bin/tr -d "[:space:]")
        set +e
        trial_fresh_unexpected=$(/usr/bin/printf "%s\n" "$trial_fresh_entries" | \
            /usr/bin/grep -F -v -x -e "$trial_root_fresh_controller" \
                -e "$trial_root_fresh_pin" -e "$trial_root_fresh_log")
        trial_fresh_grep_status=$?
        set -e
        [ "$trial_fresh_grep_status" = "1" ] && [ -z "$trial_fresh_unexpected" ]
    fi
    case "$trial_fresh_entry_count:$((trial_fresh_entry_count + 2)):$((64 + 32 * trial_fresh_entry_count))" in
        "0:2:64"|"1:3:96"|"2:4:128"|"3:5:160") ;;
        *) exit 79 ;;
    esac
    [ "$(/usr/bin/stat -f "%d:%u:%g:%l:%Lp:%z:%f" "$trial_root_fresh")" = \
      "$trial_data_device:0:0:$((trial_fresh_entry_count + 2)):711:$((64 + 32 * trial_fresh_entry_count)):0" ]
    require_plain_root_node "$trial_root_fresh"
    if [ -e "$trial_root_fresh_controller" ] || [ -L "$trial_root_fresh_controller" ]; then
        [ -f "$trial_root_fresh_controller" ] && [ ! -L "$trial_root_fresh_controller" ]
        case "$(/usr/bin/stat -f "%d:%u:%g:%l:%Lp:%f" "$trial_root_fresh_controller")" in
            "$trial_data_device:0:0:1:500:0") ;;
            *) exit 79 ;;
        esac
        trial_fresh_controller_size=$(/usr/bin/stat -f "%z" "$trial_root_fresh_controller")
        case "$trial_fresh_controller_size" in ""|*[!0-9]*) exit 79 ;; esac
        [ "$trial_fresh_controller_size" -le "$trial_expected_size" ]
        require_plain_root_node "$trial_root_fresh_controller"
    fi
    if [ -e "$trial_root_fresh_pin" ] || [ -L "$trial_root_fresh_pin" ]; then
        [ -f "$trial_root_fresh_pin" ] && [ ! -L "$trial_root_fresh_pin" ]
        case "$(/usr/bin/stat -f "%d:%u:%g:%l:%Lp:%f" "$trial_root_fresh_pin")" in
            "$trial_data_device:0:0:1:400:0"|"$trial_data_device:0:0:1:600:0") ;;
            *) exit 79 ;;
        esac
        trial_fresh_pin_size=$(/usr/bin/stat -f "%z" "$trial_root_fresh_pin")
        case "$trial_fresh_pin_size" in ""|*[!0-9]*) exit 79 ;; esac
        [ "$trial_fresh_pin_size" -le 65 ]
        require_plain_root_node "$trial_root_fresh_pin"
    fi
    if [ -e "$trial_root_fresh_log" ] || [ -L "$trial_root_fresh_log" ]; then
        [ -f "$trial_root_fresh_log" ] && [ ! -L "$trial_root_fresh_log" ]
        [ "$(/usr/bin/stat -f "%d:%u:%g:%l:%Lp:%z:%f" "$trial_root_fresh_log")" = \
          "$trial_data_device:0:0:1:600:0:0" ]
        require_plain_root_node "$trial_root_fresh_log"
    fi
    require_closed_root_tree "$trial_root_fresh"
}

require_fresh_root_support() {
    trial_fresh_support=$1
    trial_fresh_controller="$trial_fresh_support/opensteamer-local-mono-trial-controller"
    trial_fresh_pin="$trial_fresh_support/controller.sha256"
    trial_fresh_log="$trial_fresh_support/root-broker.log"
    [ -d "$trial_fresh_support" ] && [ ! -L "$trial_fresh_support" ]
    [ -f "$trial_fresh_controller" ] && [ ! -L "$trial_fresh_controller" ]
    [ -f "$trial_fresh_pin" ] && [ ! -L "$trial_fresh_pin" ]
    [ -f "$trial_fresh_log" ] && [ ! -L "$trial_fresh_log" ]
    [ "$(/usr/bin/find "$trial_fresh_support" -xdev -mindepth 1 -maxdepth 1 -print | \
        /usr/bin/sort)" = "$(/usr/bin/printf "%s\n" "$trial_fresh_controller" \
        "$trial_fresh_pin" "$trial_fresh_log" | /usr/bin/sort)" ]
    [ "$(/usr/bin/stat -f "%d:%u:%g:%l:%Lp:%z:%f" "$trial_fresh_support")" = \
      "$trial_data_device:0:0:5:711:160:0" ]
    [ "$(/usr/bin/stat -f "%d:%u:%g:%l:%Lp:%z:%f" "$trial_fresh_controller")" = \
      "$trial_data_device:0:0:1:500:$trial_expected_size:0" ]
    [ "$(/usr/bin/stat -f "%d:%u:%g:%l:%Lp:%z:%f" "$trial_fresh_pin")" = \
      "$trial_data_device:0:0:1:400:65:0" ]
    [ "$(/usr/bin/stat -f "%d:%u:%g:%l:%Lp:%z:%f" "$trial_fresh_log")" = \
      "$trial_data_device:0:0:1:600:0:0" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_fresh_controller" | /usr/bin/cut -d " " -f 1)" = \
      "$trial_expected_sha" ]
    [ "$(/bin/cat "$trial_fresh_pin")" = "$trial_expected_sha" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_fresh_pin" | /usr/bin/cut -d " " -f 1)" = \
      "858e28b243895c7d40e51f12510986ec2badc28422b1e76bb69a1468d728c114" ]
    [ ! -s "$trial_fresh_log" ]
    for trial_fresh_plain in "$trial_fresh_support" "$trial_fresh_controller" \
        "$trial_fresh_pin" "$trial_fresh_log"; do
        require_plain_root_node "$trial_fresh_plain"
    done
    require_closed_root_tree "$trial_fresh_support"
}

fresh_root_support_identity() {
    /usr/bin/stat -f "%d:%i" "$1" \
        "$1/opensteamer-local-mono-trial-controller" "$1/controller.sha256" \
        "$1/root-broker.log" | /usr/bin/tr "\n" ":"
}

prepare_fresh_root_support() {
    require_root_phase_lease_held
    require_safe_partial_fresh_root_support
    if [ ! -e "$trial_root_fresh" ] && [ ! -L "$trial_root_fresh" ]; then
        /usr/bin/install -d -o root -g wheel -m 0711 "$trial_root_fresh"
    fi
    require_safe_partial_fresh_root_support
    /usr/bin/install -o root -g wheel -m 0500 "$trial_stage_controller" \
        "$trial_root_fresh_controller"
    /usr/bin/printf "%s\n" "$trial_expected_sha" > "$trial_root_fresh_pin"
    /usr/sbin/chown root:wheel "$trial_root_fresh_pin"
    /bin/chmod 0400 "$trial_root_fresh_pin"
    : > "$trial_root_fresh_log"
    /usr/sbin/chown root:wheel "$trial_root_fresh_log"
    /bin/chmod 0600 "$trial_root_fresh_log"
    require_fresh_root_support "$trial_root_fresh"
    /bin/sync
    require_fresh_root_support "$trial_root_fresh"
}

require_root_retry_baseline() {
    [ ! -e "$trial_product_driver" ] && [ ! -L "$trial_product_driver" ]
    [ ! -e "$trial_active_pointer" ] && [ ! -L "$trial_active_pointer" ]
    [ ! -e "$trial_active_pointer_tmp" ] && [ ! -L "$trial_active_pointer_tmp" ]
    [ ! -e "$trial_proxy_arm" ] && [ ! -L "$trial_proxy_arm" ]
    [ ! -e "$trial_stop_request" ] && [ ! -L "$trial_stop_request" ]
    [ ! -e "$trial_user_stage_ready" ] && [ ! -L "$trial_user_stage_ready" ]
    [ ! -e "$trial_legacy_user_stage_ready" ] && [ ! -L "$trial_legacy_user_stage_ready" ]
    [ ! -e "/Library/Application Support/opensteamer-local-mono-trial-v1.fresh-coreaudio-kickstart-sip-L1Ciab" ] && \
        [ ! -L "/Library/Application Support/opensteamer-local-mono-trial-v1.fresh-coreaudio-kickstart-sip-L1Ciab" ]
    trial_process_snapshot=$(/bin/ps -wwaxo comm=)
    set +e
    trial_processes=$(/usr/bin/printf "%s\n" "$trial_process_snapshot" | \
        /usr/bin/grep -E "(^|/)(opensteamer-local-mono-trial-controller|opensteamer-v7-default-route-guardian)$")
    trial_process_status=$?
    set -e
    [ "$trial_process_status" = "1" ] && [ -z "$trial_processes" ]
}

require_d1_root_support() {
    trial_d1_support=$1
    trial_d1_controller="$trial_d1_support/opensteamer-local-mono-trial-controller"
    trial_d1_pin="$trial_d1_support/controller.sha256"
    trial_d1_log="$trial_d1_support/root-broker.log"
    trial_d1_transaction="$trial_d1_support/private-transaction-prep-L1Ciab"
    trial_d1_journal="$trial_d1_transaction/journal.log"
    trial_d1_identity="$trial_d1_transaction/driver.identity"
    trial_d1_failed="$trial_d1_transaction/OpensteamerVirtualMicrophone.driver.failed"
    trial_d1_hold="$trial_d1_transaction/OpensteamerVirtualMicrophone.driver.hold"
    trial_d1_abandoned="$trial_d1_transaction/OpensteamerVirtualMicrophone.driver.abandoned"
    trial_d1_sealed="$trial_d1_support/sealed-prep-L1Ciab"
    trial_d1_socket="$trial_d1_support/broker-prep-L1Ciab.sock"
    [ -d "$trial_d1_support" ] && [ ! -L "$trial_d1_support" ]
    [ -f "$trial_d1_controller" ] && [ ! -L "$trial_d1_controller" ]
    [ -f "$trial_d1_pin" ] && [ ! -L "$trial_d1_pin" ]
    [ -f "$trial_d1_log" ] && [ ! -L "$trial_d1_log" ]
    [ -d "$trial_d1_transaction" ] && [ ! -L "$trial_d1_transaction" ]
    [ -f "$trial_d1_journal" ] && [ ! -L "$trial_d1_journal" ]
    [ -f "$trial_d1_identity" ] && [ ! -L "$trial_d1_identity" ]
    [ -d "$trial_d1_sealed" ] && [ ! -L "$trial_d1_sealed" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_d1_support")" = "$trial_data_device:27093234:0:0:8:711:256:0" ]
    [ "$(/usr/bin/find "$trial_d1_support" -xdev -mindepth 1 -maxdepth 1 -print | /usr/bin/sort)" = "$(/usr/bin/printf "%s\n" "$trial_d1_controller" "$trial_d1_pin" "$trial_d1_log" "$trial_d1_transaction" "$trial_d1_sealed" "$trial_d1_socket" | /usr/bin/sort)" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_d1_controller")" = "$trial_data_device:27093235:0:0:1:500:1443880:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_d1_pin")" = "$trial_data_device:27093236:0:0:1:400:65:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_d1_log")" = "$trial_data_device:27093237:0:0:1:600:357:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_d1_transaction")" = "$trial_data_device:27093238:0:0:5:700:160:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_d1_sealed")" = "$trial_data_device:27093240:0:0:9:511:288:0" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_d1_controller" | /usr/bin/cut -d " " -f 1)" = "b2da40fa1a85cf00b9dfd84ec90b5ad71cba255c1cd4414e307e4596934b7d2e" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_d1_pin" | /usr/bin/cut -d " " -f 1)" = "070cbb6a1bde9c0230fb1e8a27aef3bc4811be0c25a356448ca2aa1836520c54" ]
    [ "$(/bin/cat "$trial_d1_pin")" = "b2da40fa1a85cf00b9dfd84ec90b5ad71cba255c1cd4414e307e4596934b7d2e" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_d1_log" | /usr/bin/cut -d " " -f 1)" = "21c50e4f479513403366762e57aee476c92f22678aa1a5c8a6b4053bbb84e708" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_d1_journal" | /usr/bin/cut -d " " -f 1)" = "fe6e6d31b12e9f3216b0d9fc059fd962628a8709374f471abb8009fe459c2d7f" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_d1_identity" | /usr/bin/cut -d " " -f 1)" = "24230285158c297e64c6e6480108148cab0e36b5fb6b02fb6e1a167a61ad2f25" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_d1_journal")" = "$trial_data_device:27093239:0:0:1:600:429:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_d1_identity")" = "$trial_data_device:27093414:0:0:1:600:108:0" ]
    [ "$(/bin/cat "$trial_d1_identity")" = "device=16777230
inode=27093391
tree_sha256=48089061c4333dc29201f48eaa3b4e889fde99174dd99ffeaed414d9d98b3aa5" ]
    [ "$(/usr/bin/find "$trial_d1_transaction" -xdev -mindepth 1 -maxdepth 1 -print | /usr/bin/sort)" = "$(/usr/bin/printf "%s\n" "$trial_d1_journal" "$trial_d1_identity" "$trial_d1_failed" | /usr/bin/sort)" ]
    [ ! -e "$trial_d1_hold" ] && [ ! -L "$trial_d1_hold" ]
    [ ! -e "$trial_d1_abandoned" ] && [ ! -L "$trial_d1_abandoned" ]
    require_failed_driver_tree "$trial_d1_failed"
    trial_d1_sealed_controller="$trial_d1_sealed/opensteamer-local-mono-trial-controller"
    trial_d1_sealed_pin="$trial_d1_sealed/controller.sha256"
    trial_d1_sealed_host="$trial_d1_sealed/opensteamer Host.app"
    trial_d1_sealed_mirror="$trial_d1_sealed/physical-blackhole-microphone-probe"
    trial_d1_sealed_vpio="$trial_d1_sealed/opensteamer-public-vpio-probe"
    trial_d1_sealed_guardian="$trial_d1_sealed/opensteamer-v7-default-route-guardian"
    trial_d1_sealed_proxy="$trial_d1_sealed/uid501-proxy.identity"
    [ -d "$trial_d1_sealed_host" ] && [ ! -L "$trial_d1_sealed_host" ]
    for trial_d1_sealed_regular in "$trial_d1_sealed_controller" "$trial_d1_sealed_pin" \
        "$trial_d1_sealed_mirror" "$trial_d1_sealed_vpio" "$trial_d1_sealed_guardian" \
        "$trial_d1_sealed_proxy"; do
        [ -f "$trial_d1_sealed_regular" ] && [ ! -L "$trial_d1_sealed_regular" ]
    done
    [ "$(/usr/bin/find "$trial_d1_sealed" -xdev -mindepth 1 -maxdepth 1 -print | /usr/bin/sort)" = "$(/usr/bin/printf "%s\n" "$trial_d1_sealed_controller" "$trial_d1_sealed_pin" "$trial_d1_sealed_host" "$trial_d1_sealed_mirror" "$trial_d1_sealed_vpio" "$trial_d1_sealed_guardian" "$trial_d1_sealed_proxy" | /usr/bin/sort)" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_d1_sealed_host")" = "$trial_data_device:27093251:0:0:3:755:96:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_d1_sealed_mirror")" = "$trial_data_device:27093406:0:0:1:555:989184:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_d1_sealed_vpio")" = "$trial_data_device:27093407:0:0:1:555:154912:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_d1_sealed_guardian")" = "$trial_data_device:27093408:0:0:1:555:258696:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_d1_sealed_controller")" = "$trial_data_device:27093409:0:0:1:555:1443880:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_d1_sealed_pin")" = "$trial_data_device:27093410:0:0:1:444:65:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_d1_sealed_proxy")" = "$trial_data_device:27093416:0:0:1:444:97:0" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_d1_sealed_mirror" | /usr/bin/cut -d " " -f 1)" = "403d1bf8aed711dba05c0ed575af4620ee8fa2454e6b50b6d51d07f261703d33" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_d1_sealed_vpio" | /usr/bin/cut -d " " -f 1)" = "0ec9e1a0cc5f253cc569134ce2be024a7f3ae6ad211fa7d20fe6436c0bac84c8" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_d1_sealed_guardian" | /usr/bin/cut -d " " -f 1)" = "72ef50156a0154e3b6c9a84557f3c192b67ec69f7a9747476826fb9aa3d4509c" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_d1_sealed_controller" | /usr/bin/cut -d " " -f 1)" = "b2da40fa1a85cf00b9dfd84ec90b5ad71cba255c1cd4414e307e4596934b7d2e" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_d1_sealed_pin" | /usr/bin/cut -d " " -f 1)" = "070cbb6a1bde9c0230fb1e8a27aef3bc4811be0c25a356448ca2aa1836520c54" ]
    [ "$(/usr/bin/shasum -a 256 "$trial_d1_sealed_proxy" | /usr/bin/cut -d " " -f 1)" = "b2b881e38bbf28e2024cec224dfb9052ac513acd23dcdc46840448c842985bf4" ]
    [ "$(/bin/cat "$trial_d1_sealed_proxy")" = "schema=opensteamer.local-mono-root-proxy.v1
proxy_pid=21660
proxy_start=Sun Aug 16 14:34:47 2026" ]
    require_sealed_host_tree "$trial_d1_sealed_host" \
        "ed71df7533902a1fb9105d491818bcebfdc93d932830973a56b9846ef7fd5514"
    for trial_d1_plain in "$trial_d1_support" "$trial_d1_controller" "$trial_d1_pin" \
        "$trial_d1_log" "$trial_d1_transaction" "$trial_d1_journal" "$trial_d1_identity" \
        "$trial_d1_sealed" "$trial_d1_sealed_host" "$trial_d1_sealed_mirror" \
        "$trial_d1_sealed_vpio" "$trial_d1_sealed_guardian" "$trial_d1_sealed_controller" \
        "$trial_d1_sealed_pin" "$trial_d1_sealed_proxy"; do
        require_plain_root_node "$trial_d1_plain"
    done
    require_root_socket "$trial_d1_socket"
    require_closed_root_tree "$trial_d1_support"
}

require_failed_loopback_root_support() {
    trial_failed_support=$1
    case "$trial_failed_root_record_count:$trial_failed_root_metadata_sha:$trial_failed_root_hashes_sha" in
        *PIN_AFTER*) exit 79 ;;
    esac
    trial_failed_controller="$trial_failed_support/opensteamer-local-mono-trial-controller"
    trial_failed_pin="$trial_failed_support/controller.sha256"
    trial_failed_log="$trial_failed_support/root-broker.log"
    trial_failed_transaction="$trial_failed_support/private-transaction-prep-L1Ciab"
    trial_failed_journal="$trial_failed_transaction/journal.log"
    trial_failed_identity="$trial_failed_transaction/driver.identity"
    trial_failed_driver="$trial_failed_transaction/OpensteamerVirtualMicrophone.driver.failed"
    trial_failed_hold="$trial_failed_transaction/OpensteamerVirtualMicrophone.driver.hold"
    trial_failed_abandoned="$trial_failed_transaction/OpensteamerVirtualMicrophone.driver.abandoned"
    trial_failed_sealed="$trial_failed_support/sealed-prep-L1Ciab"
    trial_failed_sealed_host="$trial_failed_sealed/opensteamer Host.app"
    trial_failed_socket="$trial_failed_support/broker-prep-L1Ciab.sock"
    [ -d "$trial_failed_support" ] && [ ! -L "$trial_failed_support" ]
    [ -f "$trial_failed_controller" ] && [ ! -L "$trial_failed_controller" ]
    [ -f "$trial_failed_pin" ] && [ ! -L "$trial_failed_pin" ]
    [ -f "$trial_failed_log" ] && [ ! -L "$trial_failed_log" ]
    [ -d "$trial_failed_transaction" ] && [ ! -L "$trial_failed_transaction" ]
    [ -f "$trial_failed_journal" ] && [ ! -L "$trial_failed_journal" ]
    [ -f "$trial_failed_identity" ] && [ ! -L "$trial_failed_identity" ]
    [ -d "$trial_failed_driver" ] && [ ! -L "$trial_failed_driver" ]
    [ ! -e "$trial_failed_hold" ] && [ ! -L "$trial_failed_hold" ]
    [ ! -e "$trial_failed_abandoned" ] && [ ! -L "$trial_failed_abandoned" ]
    [ -d "$trial_failed_sealed" ] && [ ! -L "$trial_failed_sealed" ]
    [ -d "$trial_failed_sealed_host" ] && [ ! -L "$trial_failed_sealed_host" ]
    [ -S "$trial_failed_socket" ] && [ ! -L "$trial_failed_socket" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_failed_support")" = \
      "$trial_data_device:27209685:0:0:8:711:256:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_failed_socket")" = \
      "$trial_data_device:27210031:501:20:1:600:0:0" ]
    trial_failed_actual_count=$(/usr/bin/find "$trial_failed_support" -xdev -print | \
        /usr/bin/wc -l | /usr/bin/tr -d "[:space:]")
    [ "$trial_failed_actual_count" = "$trial_failed_root_record_count" ]
    trial_failed_metadata=$(/usr/bin/find "$trial_failed_support" -xdev -exec \
        /usr/bin/stat -f "%N|%HT|%d:%i:%u:%g:%l:%Lp:%z:%f|%Y" {} \;)
    trial_failed_actual_metadata_sha=$(/usr/bin/printf "%s\n" "$trial_failed_metadata" | \
        /usr/bin/sed "s#$trial_failed_support#.#g;s/|$trial_data_device:/|DATA_VOLUME_DEVICE:/g" | \
        /usr/bin/sort | \
        /usr/bin/shasum -a 256 | /usr/bin/cut -d " " -f 1)
    [ "$trial_failed_actual_metadata_sha" = "$trial_failed_root_metadata_sha" ]
    trial_failed_hashes=$(/usr/bin/find "$trial_failed_support" -xdev -type f -exec \
        /usr/bin/shasum -a 256 {} \;)
    trial_failed_actual_hashes_sha=$(/usr/bin/printf "%s\n" "$trial_failed_hashes" | \
        /usr/bin/sed "s#$trial_failed_support#.#g" | /usr/bin/sort | \
        /usr/bin/shasum -a 256 | /usr/bin/cut -d " " -f 1)
    [ "$trial_failed_actual_hashes_sha" = "$trial_failed_root_hashes_sha" ]
    [ -z "$(/usr/bin/find "$trial_failed_support" -xdev ! -type s -exec /usr/bin/xattr {} +)" ]
    [ "$(/usr/bin/find "$trial_failed_support" -xdev -exec /bin/ls -lde {} \; | \
        /usr/bin/wc -l | /usr/bin/tr -d "[:space:]")" = "$trial_failed_root_record_count" ]
    trial_failed_socket_acl=$(/bin/ls -lde "$trial_failed_socket")
    [ "$(/usr/bin/printf "%s\n" "$trial_failed_socket_acl" | /usr/bin/wc -l | \
        /usr/bin/tr -d "[:space:]")" = "1" ]
    set +e
    trial_failed_socket_xattrs=$(/usr/bin/xattr "$trial_failed_socket" 2>&1)
    trial_failed_socket_xattr_status=$?
    set -e
    trial_failed_socket_expected=$(/usr/bin/printf \
        "xattr: [Errno 102] Operation not supported on socket: \047%s\047" \
        "$trial_failed_socket")
    [ "$trial_failed_socket_xattr_status" = "1" ] && \
        [ "$trial_failed_socket_xattrs" = "$trial_failed_socket_expected" ]
    require_failed_driver_tree "$trial_failed_driver"
    require_sealed_host_tree "$trial_failed_sealed_host" \
        "a5c70c275752033fc40777144b9aa0db8c0d54acf99d520ee14cc0ba988a84b9"
    require_closed_root_tree "$trial_failed_support"
}

require_prior_root_evidence_boundaries() {
    [ -d "$trial_root_evidence_first" ] && [ ! -L "$trial_root_evidence_first" ]
    [ -d "$trial_root_evidence_second" ] && [ ! -L "$trial_root_evidence_second" ]
    [ -d "$trial_root_evidence_third" ] && [ ! -L "$trial_root_evidence_third" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_root_evidence_first")" = \
      "$trial_data_device:27006986:0:0:7:711:224:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_root_evidence_second")" = \
      "$trial_data_device:27016896:0:0:8:711:256:0" ]
    [ "$(/usr/bin/stat -f "%d:%i:%u:%g:%l:%Lp:%z:%f" "$trial_root_evidence_third")" = \
      "$trial_data_device:27021963:0:0:8:711:256:0" ]
    trial_first_evidence_entries=$(/usr/bin/find "$trial_root_evidence_first" -xdev \
        -mindepth 1 -maxdepth 1 -print0 | /usr/bin/tr -cd "\000" | \
        /usr/bin/wc -c | /usr/bin/tr -d "[:space:]")
    trial_second_evidence_entries=$(/usr/bin/find "$trial_root_evidence_second" -xdev \
        -mindepth 1 -maxdepth 1 -print0 | /usr/bin/tr -cd "\000" | \
        /usr/bin/wc -c | /usr/bin/tr -d "[:space:]")
    trial_third_evidence_entries=$(/usr/bin/find "$trial_root_evidence_third" -xdev \
        -mindepth 1 -maxdepth 1 -print0 | /usr/bin/tr -cd "\000" | \
        /usr/bin/wc -c | /usr/bin/tr -d "[:space:]")
    [ "$trial_first_evidence_entries" = "5" ]
    [ "$trial_second_evidence_entries" = "6" ]
    [ "$trial_third_evidence_entries" = "6" ]
    for trial_root_evidence in "$trial_root_evidence_first" "$trial_root_evidence_second" \
        "$trial_root_evidence_third"; do
        require_plain_root_node "$trial_root_evidence"
        require_closed_root_tree "$trial_root_evidence"
    done
    require_d1_root_support "$trial_root_evidence_fourth"
}

require_failed_loopback_preservation_boundary() {
    require_root_phase_lease_held
    require_prior_root_evidence_boundaries
    require_prior_user_evidence_root
    require_u2_user_evidence_root
    require_u3_user_evidence_root
    require_fresh_user_stage_root
    [ "$(fresh_user_stage_identity)" = "$trial_initial_user_stage_identity" ]
    require_root_retry_baseline
}

require_root_phase_lease_held
require_prior_root_evidence_boundaries
require_prior_user_evidence_root
require_u2_user_evidence_root
require_u3_user_evidence_root
require_fresh_user_stage_root
trial_initial_user_stage_identity=$(fresh_user_stage_identity)
require_root_retry_baseline

if [ -d "$trial_root_support" ] && [ ! -L "$trial_root_support" ] && \
   [ ! -e "$trial_root_evidence_fifth" ] && [ ! -L "$trial_root_evidence_fifth" ]; then
    require_failed_loopback_root_support "$trial_root_support"
    require_safe_partial_fresh_root_support
    if [ -f "$trial_root_fresh_controller" ] && [ ! -L "$trial_root_fresh_controller" ] && \
       [ -f "$trial_root_fresh_pin" ] && [ ! -L "$trial_root_fresh_pin" ] && \
       [ -f "$trial_root_fresh_log" ] && [ ! -L "$trial_root_fresh_log" ]; then
        require_fresh_root_support "$trial_root_fresh"
        trial_quarantine_state="R1"
    else
        trial_quarantine_state="R0"
    fi
elif [ ! -e "$trial_root_support" ] && [ ! -L "$trial_root_support" ] && \
     [ -d "$trial_root_evidence_fifth" ] && [ ! -L "$trial_root_evidence_fifth" ] && \
     [ -d "$trial_root_fresh" ] && [ ! -L "$trial_root_fresh" ]; then
    require_failed_loopback_root_support "$trial_root_evidence_fifth"
    require_fresh_root_support "$trial_root_fresh"
    trial_quarantine_state="R2"
elif [ -d "$trial_root_support" ] && [ ! -L "$trial_root_support" ] && \
     [ -d "$trial_root_evidence_fifth" ] && [ ! -L "$trial_root_evidence_fifth" ] && \
     [ ! -e "$trial_root_fresh" ] && [ ! -L "$trial_root_fresh" ]; then
    require_failed_loopback_root_support "$trial_root_evidence_fifth"
    require_fresh_root_support "$trial_root_support"
    trial_quarantine_state="R3"
else
    exit 79
fi

if [ "$trial_quarantine_state" = "R0" ]; then
    require_failed_loopback_preservation_boundary
    require_failed_loopback_root_support "$trial_root_support"
    [ ! -e "$trial_root_evidence_fifth" ] && [ ! -L "$trial_root_evidence_fifth" ]
    prepare_fresh_root_support
    require_failed_loopback_preservation_boundary
    require_failed_loopback_root_support "$trial_root_support"
    require_fresh_root_support "$trial_root_fresh"
    trial_quarantine_state="R1"
fi

if [ "$trial_quarantine_state" = "R1" ]; then
    trial_failed_prepublication_identity=$(/usr/bin/stat -f "%d:%i" "$trial_root_support")
    [ "$(/usr/bin/stat -f "%d" "$trial_root_support")" = \
      "$(/usr/bin/stat -f "%d" "/Library/Application Support")" ]
    /bin/sync
    require_failed_loopback_preservation_boundary
    require_failed_loopback_root_support "$trial_root_support"
    require_fresh_root_support "$trial_root_fresh"
    [ ! -e "$trial_root_evidence_fifth" ] && [ ! -L "$trial_root_evidence_fifth" ]
    require_root_phase_lease_held
    /bin/mv -n "$trial_root_support" "$trial_root_evidence_fifth"
    [ ! -e "$trial_root_support" ] && [ ! -L "$trial_root_support" ]
    [ "$(/usr/bin/stat -f "%d:%i" "$trial_root_evidence_fifth")" = \
      "$trial_failed_prepublication_identity" ]
    require_failed_loopback_root_support "$trial_root_evidence_fifth"
    require_fresh_root_support "$trial_root_fresh"
    /bin/sync
    require_failed_loopback_preservation_boundary
    require_failed_loopback_root_support "$trial_root_evidence_fifth"
    require_fresh_root_support "$trial_root_fresh"
    trial_quarantine_state="R2"
fi

if [ "$trial_quarantine_state" = "R2" ]; then
    trial_fresh_prepublication_identity=$(fresh_root_support_identity "$trial_root_fresh")
    [ "$(/usr/bin/stat -f "%d" "$trial_root_fresh")" = \
      "$(/usr/bin/stat -f "%d" "/Library/Application Support")" ]
    /bin/sync
    require_failed_loopback_preservation_boundary
    require_failed_loopback_root_support "$trial_root_evidence_fifth"
    require_fresh_root_support "$trial_root_fresh"
    [ ! -e "$trial_root_support" ] && [ ! -L "$trial_root_support" ]
    require_root_phase_lease_held
    /bin/mv -n "$trial_root_fresh" "$trial_root_support"
    [ ! -e "$trial_root_fresh" ] && [ ! -L "$trial_root_fresh" ]
    [ "$(fresh_root_support_identity "$trial_root_support")" = \
      "$trial_fresh_prepublication_identity" ]
    require_failed_loopback_root_support "$trial_root_evidence_fifth"
    require_fresh_root_support "$trial_root_support"
    /bin/sync
    require_failed_loopback_preservation_boundary
    require_failed_loopback_root_support "$trial_root_evidence_fifth"
    require_fresh_root_support "$trial_root_support"
    trial_quarantine_state="R3"
fi

[ "$trial_quarantine_state" = "R3" ]
[ ! -e "$trial_root_fresh" ] && [ ! -L "$trial_root_fresh" ]
/bin/sync
require_failed_loopback_preservation_boundary
require_failed_loopback_root_support "$trial_root_evidence_fifth"
require_fresh_root_support "$trial_root_support"
[ "$trial_root_controller" = "$trial_root_support/opensteamer-local-mono-trial-controller" ]
[ "$trial_root_pin" = "$trial_root_support/controller.sha256" ]
[ "$trial_root_log" = "$trial_root_support/root-broker.log" ]
require_closed_root_tree "$trial_root_evidence_fifth"
require_closed_root_tree "$trial_root_support"
require_root_phase_lease_held
OPENSTEAMER_ROOT_WRAPPER_L1CIAB'

# This command is deliberately separate from ROOT_BOOTSTRAP_COMMAND. It owns only the existing
# root phase lease, performs bounded no-follow reads of the exact failed root evidence, emits one
# self-authenticating ASCII transport after two identical passes, and invokes only exact pinned,
# non-daemonizing read-only observers synchronously without sending signals or mutating state.
readonly ROOT_CAPTURE_COMMAND='exec /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/var/root USER=root LOGNAME=root /usr/bin/perl - <<\OPENSTEAMER_ROOT_CAPTURE_L1CIAB
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Fcntl qw(O_RDONLY F_SETFD FD_CLOEXEC);
use Errno qw(EINTR);
use bytes;
umask(077);
($> + 0) == 0 or die "capture requires root\n";

my $challenge = "OPENSTEAMER_ROOT_EVIDENCE_CAPTURE_L1CIAB_V1";
my $lease_path = "/Library/Application Support/opensteamer-local-mono-trial-root-bootstrap-L1Ciab.lock";
my $root = "/Library/Application Support/opensteamer-local-mono-trial-v1";
my $data_volume_mount = "/System/Volumes/Data";
my $expected_data_volume_uuid = "AF638805-E0CB-4356-941F-16B84DFB6435";
my $expected_data_volume_group_uuid = "AF638805-E0CB-4356-941F-16B84DFB6435";
my @initial_data_volume_stat = lstat($data_volume_mount);
@initial_data_volume_stat && $initial_data_volume_stat[4] == 0 &&
    $initial_data_volume_stat[5] == 80 &&
    (($initial_data_volume_stat[2] & 0177777) == 0040775)
    or die "capture Data volume mount is unsafe\n";
my $data_device = $initial_data_volume_stat[0];
my $root_device = $data_device;
my $root_inode = 27209685;
my $lease_inode = 27209629;
my $maximum_records = 512;
my $maximum_depth = 24;
my $maximum_file_bytes = 67_108_864;
my $maximum_total_regular_bytes = 536_870_912;
my $maximum_symlink_bytes = 4_096;
my $maximum_payload_bytes = 1_048_576;
my $maximum_path_argument_bytes = 131_072;
my $maximum_helper_output_bytes = 1_048_576;
my %tool_specification = (
    "/usr/bin/stat" => [1152921500312572688, 0, 0, 2, 0755, 118768,
        "934656def5cfb8e85b2e4d983bb59ba97479cec49b63b4ea2fa42d067c569242"],
    "/usr/bin/xattr" => [1152921500312573129, 0, 0, 1, 0755, 118896,
        "3cc7308e9dfd687b0b7f4778a6101633aa9dce5ccdd012cf17cd858848295162"],
    "/bin/ls" => [1152921500312571415, 0, 0, 1, 0755, 154624,
        "a97c50d34f912a5ada66959c231897ec2144e3c9cb922cd8150e4f2b0c9470e7"],
    "/usr/sbin/lsof" => [1152921500312576119, 0, 0, 1, 0755, 307600,
        "28c36d6b6dfcce1f544717b0d1961aa03441ee0a736fee3e1eaeb215c0fbff4c"],
    "/usr/bin/codesign" => [1152921500312571781, 0, 0, 1, 0755, 459824,
        "214d455584d19abc0d74d02b9cbc7d3da6bdcb0596c235e6156dd9ed2f4e1ba7"],
    "/usr/sbin/diskutil" => [1152921500312576001, 0, 0, 1, 0755, 1943344,
        "9299ccac6acdf493796a88979d14ff464c1ec2196b167c879f023c2dbe9f3049"],
);
my %captured_contents = map { $_ => 1 } (
    "controller.sha256",
    "root-broker.log",
    "private-transaction-prep-L1Ciab/journal.log",
    "private-transaction-prep-L1Ciab/driver.identity",
);
my %content_limits = (
    "controller.sha256" => 128,
    "root-broker.log" => 65_536,
    "private-transaction-prep-L1Ciab/journal.log" => 262_144,
    "private-transaction-prep-L1Ciab/driver.identity" => 4_096,
);
my %expected_symlink_targets = (
    "sealed-prep-L1Ciab/opensteamer Host.app/Contents/Frameworks/LiveKitWebRTC.framework/Headers" =>
        "Versions/Current/Headers",
    "sealed-prep-L1Ciab/opensteamer Host.app/Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC" =>
        "Versions/Current/LiveKitWebRTC",
    "sealed-prep-L1Ciab/opensteamer Host.app/Contents/Frameworks/LiveKitWebRTC.framework/Modules" =>
        "Versions/Current/Modules",
    "sealed-prep-L1Ciab/opensteamer Host.app/Contents/Frameworks/LiveKitWebRTC.framework/Resources" =>
        "Versions/Current/Resources",
    "sealed-prep-L1Ciab/opensteamer Host.app/Contents/Frameworks/LiveKitWebRTC.framework/Versions/Current" =>
        "A",
);

sub require_exact_tool {
    my ($path) = @_;
    exists($tool_specification{$path}) or die "capture helper is not allowlisted\n";
    my $expected = $tool_specification{$path};
    sysopen(my $tool, $path, O_RDONLY | 0x100)
        or die "capture helper open failed\n";
    binmode($tool);
    my @opened = stat($tool);
    my @named = lstat($path);
    @opened && @named &&
        join(":", @opened[0, 1, 2, 3, 4, 5, 7, 9, 10]) eq
            join(":", @named[0, 1, 2, 3, 4, 5, 7, 9, 10]) &&
        $opened[0] == $data_device && $opened[1] == $expected->[0] &&
        $opened[4] == $expected->[1] && $opened[5] == $expected->[2] &&
        $opened[3] == $expected->[3] && (($opened[2] & 07777) == $expected->[4]) &&
        $opened[7] == $expected->[5]
        or die "capture helper identity changed\n";
    my $bytes = "";
    while (1) {
        my $chunk = "";
        my $count = sysread($tool, $chunk, 65_536);
        defined($count) or die "capture helper read failed\n";
        last if $count == 0;
        length($bytes) + $count <= 2_097_152 or die "capture helper exceeded bound\n";
        $bytes .= $chunk;
    }
    sha256_hex($bytes) eq $expected->[6] or die "capture helper hash changed\n";
    my @after = stat($tool);
    my @named_after = lstat($path);
    @after && @named_after &&
        join(":", @after[0, 1, 2, 3, 4, 5, 7, 9, 10]) eq
            join(":", @opened[0, 1, 2, 3, 4, 5, 7, 9, 10]) &&
        join(":", @named_after[0, 1, 2, 3, 4, 5, 7, 9, 10]) eq
            join(":", @opened[0, 1, 2, 3, 4, 5, 7, 9, 10])
        or die "capture helper identity changed after read\n";
    close($tool) or die "capture helper close failed\n";
}

sub root_path_argument_is_safe {
    my ($path) = @_;
    return $path eq $root || index($path, "$root/") == 0;
}

sub capture_command_is_allowlisted {
    my (@command) = @_;
    return 0 unless @command >= 1 && exists($tool_specification{$command[0]});
    if ($command[0] eq "/usr/bin/stat") {
        return @command >= 4 && $command[1] eq "-f" &&
            $command[2] eq "%d:%i:%u:%g:%l:%Lp:%z:%f" &&
            !grep { !root_path_argument_is_safe($_) } @command[3 .. $#command];
    }
    if ($command[0] eq "/usr/bin/xattr") {
        my $socket_path = "$root/broker-prep-L1Ciab.sock";
        return (@command >= 3 && $command[1] eq "-s" &&
                !grep { !root_path_argument_is_safe($_) } @command[2 .. $#command]) ||
            (@command == 2 && $command[1] eq $socket_path);
    }
    if ($command[0] eq "/bin/ls") {
        return @command >= 3 && $command[1] eq "-lde" &&
            !grep { !root_path_argument_is_safe($_) } @command[2 .. $#command];
    }
    if ($command[0] eq "/usr/sbin/lsof") {
        return @command == 4 && $command[1] eq "-Fn" &&
            $command[2] eq "+D" && $command[3] eq $root;
    }
    if ($command[0] eq "/usr/bin/codesign") {
        my $sealed_host = "$root/sealed-prep-L1Ciab/opensteamer Host.app";
        return (@command == 5 && $command[1] eq "--verify" &&
                $command[2] eq "--strict" && $command[3] eq "--all-architectures" &&
                $command[4] eq $sealed_host) ||
            (@command == 4 && $command[1] eq "-d" &&
                $command[2] eq "--verbose=4" && $command[3] eq $sealed_host);
    }
    if ($command[0] eq "/usr/sbin/diskutil") {
        return @command == 4 && $command[1] eq "info" &&
            $command[2] eq "-plist" && $command[3] eq $data_volume_mount;
    }
    return 0;
}

sub synchronous_capture {
    my ($maximum_output, @command) = @_;
    $maximum_output >= 0 && $maximum_output <= $maximum_helper_output_bytes &&
        capture_command_is_allowlisted(@command)
        or die "capture helper invocation is not allowlisted\n";
    require_exact_tool($command[0]);
    pipe(my $reader, my $writer) or die "capture helper pipe failed\n";
    my $child = fork();
    defined($child) && $child > 0 or do {
        if (defined($child) && $child == 0) {
            close($reader);
            %ENV = (
                LC_ALL => "C",
                PATH => "/usr/bin:/bin:/usr/sbin:/sbin",
                HOME => "/var/root",
                USER => "root",
                LOGNAME => "root",
            );
            open(STDIN, "<", "/dev/null") or exit 249;
            open(STDOUT, ">&", $writer) or exit 250;
            open(STDERR, ">&", $writer) or exit 251;
            close($writer);
            exec({$command[0]} @command);
            exit 252;
        }
        die "capture helper fork failed\n";
    };
    close($writer) or die "capture helper writer close failed\n";
    my $output = "";
    my $overflowed = 0;
    while (1) {
        my $chunk = "";
        my $count = sysread($reader, $chunk, 65_536);
        if (!defined($count)) {
            next if $! == EINTR;
            die "capture helper read failed\n";
        }
        last if $count == 0;
        if (length($output) + $count <= $maximum_output) {
            $output .= $chunk;
        } else {
            $overflowed = 1;
        }
    }
    close($reader) or die "capture helper reader close failed\n";
    my $waited;
    do {
        $waited = waitpid($child, 0);
    } while ($waited == -1 && $! == EINTR);
    $waited == $child or die "capture helper reap failed\n";
    my $status = $?;
    require_exact_tool($command[0]);
    !$overflowed or die "capture helper output exceeded bound\n";
    return ($status, $output);
}

sub plist_string_value {
    my ($plist, $key) = @_;
    $plist !~ /[\x00\r]/ or die "capture volume plist contained unsafe bytes\n";
    my @value = $plist =~ m{<key>\Q$key\E</key>\s*<string>([^<]+)</string>}g;
    @value == 1 or die "capture volume plist property changed\n";
    return $value[0];
}

sub plist_boolean_value {
    my ($plist, $key) = @_;
    my @value = $plist =~ m{<key>\Q$key\E</key>\s*<(true|false)/>}g;
    @value == 1 or die "capture volume plist Boolean changed\n";
    return $value[0];
}

sub require_data_volume_identity {
    my @before = lstat($data_volume_mount);
    @before && $before[0] == $data_device && $before[4] == 0 && $before[5] == 80 &&
        (($before[2] & 0177777) == 0040775)
        or die "capture Data volume mount changed\n";
    my ($volume_status, $volume_plist) = synchronous_capture(
        131_072, "/usr/sbin/diskutil", "info", "-plist", $data_volume_mount);
    $volume_status == 0 && length($volume_plist) >= 256
        or die "capture Data volume query failed\n";
    my $volume_uuid = plist_string_value($volume_plist, "VolumeUUID");
    my $volume_group_uuid = plist_string_value($volume_plist, "APFSVolumeGroupID");
    my $mount_point = plist_string_value($volume_plist, "MountPoint");
    my $filesystem_type = plist_string_value($volume_plist, "FilesystemType");
    my $internal_value = plist_boolean_value($volume_plist, "Internal");
    $volume_uuid eq $expected_data_volume_uuid &&
        $volume_group_uuid eq $expected_data_volume_group_uuid &&
        $mount_point eq $data_volume_mount && $filesystem_type eq "apfs" &&
        $internal_value eq "true"
        or die "capture Data volume identity changed\n";
    my @after = lstat($data_volume_mount);
    @after && join(":", @after[0, 1, 2, 3, 4, 5, 7]) eq
        join(":", @before[0, 1, 2, 3, 4, 5, 7])
        or die "capture Data volume mount changed during proof\n";
    for my $anchor ("/", "/Users", "/Library", "/Library/Application Support",
        "/Users/ahmed", "/Users/ahmed/Library/Application Support/opensteamer") {
        my @anchor_stat = lstat($anchor);
        @anchor_stat && (($anchor_stat[2] & 0170000) == 0040000) &&
            $anchor_stat[0] == $data_device
            or die "capture anchor escaped the Data volume\n";
    }
    return join("\n",
        "volume_uuid=$volume_uuid",
        "volume_group_uuid=$volume_group_uuid",
        "volume_mount=$mount_point",
        "filesystem_type=$filesystem_type",
        "internal=$internal_value",
        "captured_device=$data_device",
    ) . "\n";
}

sub observation_record {
    my ($name, $status, $output) = @_;
    $name =~ /\A[a-z0-9-]+\z/ or die "capture observation name is unsafe\n";
    return join("\t", "observation", $name, $status, length($output),
        sha256_hex($output), unpack("H*", $output)) . "\n";
}

sub stat_key {
    my (@value) = @_;
    return join(":", @value[0, 1, 2, 3, 4, 5, 7, 9, 10]);
}

sub symbolic_mode {
    my ($kind, $mode) = @_;
    my $value = $kind eq "directory" ? "d" : $kind eq "regular" ? "-" :
        $kind eq "socket" ? "s" : $kind eq "symlink" ? "l" :
        die "capture ACL kind is unsupported\n";
    my @bit = (0400, 0200, 0100, 0040, 0020, 0010, 0004, 0002, 0001);
    my @character = qw(r w x r w x r w x);
    for my $index (0 .. $#bit) {
        $value .= ($mode & $bit[$index]) ? $character[$index] : "-";
    }
    substr($value, 3, 1, ($mode & 0100) ? "s" : "S") if $mode & 04000;
    substr($value, 6, 1, ($mode & 0010) ? "s" : "S") if $mode & 02000;
    substr($value, 9, 1, ($mode & 0001) ? "t" : "T") if $mode & 01000;
    return $value;
}

sub acl_line_is_canonical {
    my ($line, $kind, $mode, $nlink, $uid, $gid, $size, $path, $link_target) = @_;
    my $owner = $uid == 0 ? "root" : $uid == 501 ? "ahmed" : return 0;
    my $group = $gid == 0 ? "wheel" : $gid == 20 ? "staff" : return 0;
    my $symbolic = symbolic_mode($kind, $mode);
    my $display_path = $kind eq "symlink" ? "$path -> $link_target" : $path;
    return $line =~ /\A\Q$symbolic\E[ ]+$nlink[ ]+\Q$owner\E[ ]+
        \Q$group\E[ ]+$size[ ]+[A-Z][a-z]{2}[ ]+[ 0-3][0-9][ ]+
        (?:[0-2][0-9]:[0-5][0-9]|[0-9]{4})[ ]+\Q$display_path\E\z/x;
}

sub require_exact_lease {
    my ($handle) = @_;
    my @descriptor = stat($handle);
    my @named = lstat($lease_path);
    @descriptor && @named or die "capture lease disappeared\n";
    stat_key(@descriptor) eq stat_key(@named) or die "capture lease identity changed\n";
    $descriptor[0] == $root_device && $descriptor[1] == $lease_inode &&
        $descriptor[4] == 0 && $descriptor[5] == 80 && $descriptor[3] == 1 &&
        (($descriptor[2] & 0170000) == 0100000) &&
        (($descriptor[2] & 07777) == 0600) && $descriptor[7] == 0
        or die "capture lease metadata changed\n";
}

sysopen(my $lease, $lease_path, O_RDONLY | 0x100)
    or die "capture lease open failed\n";
fcntl($lease, F_SETFD, FD_CLOEXEC) or die "capture lease CLOEXEC failed\n";
require_exact_lease($lease);
flock($lease, 6) or die "capture lease is busy\n";
require_exact_lease($lease);

sub valid_name {
    my ($name) = @_;
    return length($name) > 0 && length($name) <= 255 &&
        index($name, "/") < 0 && $name !~ /[\x00-\x1f\x7f]/;
}

sub hex_of {
    return unpack("H*", $_[0]);
}

sub read_regular {
    my ($path, $relative, $expected_key, $size, $total_reference) = @_;
    $size <= $maximum_file_bytes or die "capture regular file exceeded bound\n";
    $$total_reference + $size <= $maximum_total_regular_bytes
        or die "capture total regular bytes exceeded bound\n";
    sysopen(my $file, $path, O_RDONLY | 0x100)
        or die "capture regular open failed\n";
    binmode($file);
    my @opened = stat($file);
    @opened && stat_key(@opened) eq $expected_key
        or die "capture regular descriptor identity changed\n";
    my $bytes = "";
    while (1) {
        my $chunk = "";
        my $count = sysread($file, $chunk, 65_536);
        defined($count) or die "capture regular read failed\n";
        last if $count == 0;
        length($bytes) + $count <= $maximum_file_bytes
            or die "capture regular read exceeded bound\n";
        $bytes .= $chunk;
    }
    length($bytes) == $size or die "capture regular size changed\n";
    my @closed_descriptor = stat($file);
    my @closed_named = lstat($path);
    @closed_descriptor && @closed_named &&
        stat_key(@closed_descriptor) eq $expected_key &&
        stat_key(@closed_named) eq $expected_key
        or die "capture regular identity changed after read\n";
    close($file) or die "capture regular close failed\n";
    $$total_reference += $size;
    my $content_record = "";
    if ($captured_contents{$relative}) {
        length($bytes) <= $content_limits{$relative}
            or die "capture selected content exceeded bound\n";
        $content_record = join("\t", "content", hex_of($relative), length($bytes),
            sha256_hex($bytes), hex_of($bytes)) . "\n";
    }
    return (sha256_hex($bytes), $content_record);
}

sub read_symlink {
    my ($path, $relative, $expected_key, $size) = @_;
    $size > 0 && $size <= $maximum_symlink_bytes
        or die "capture symlink size exceeded bound\n";
    my $target = readlink($path);
    defined($target) or die "capture symlink read failed\n";
    length($target) == $size && $target !~ /[\x00-\x1f\x7f]/ &&
        $target !~ m{\A/} && $target !~ m{(?:\A|/)\.\.?(/|\z)}
        or die "capture symlink target is unsafe\n";
    my @after = lstat($path);
    @after && stat_key(@after) eq $expected_key
        or die "capture symlink identity changed after read\n";
    my $digest = sha256_hex($target);
    my $link_record = join("\t", "link", hex_of($relative), length($target),
        $digest, hex_of($target)) . "\n";
    return ($digest, $link_record, $target);
}

sub capture_pass {
    my $data_volume_observation = require_data_volume_identity();
    my @records;
    my @contents;
    my @links;
    my @paths;
    my @non_socket_paths;
    my @socket_paths;
    my @symlink_paths;
    my %observed_symlink;
    my @expected_stat_prefixes;
    my @expected_acl_kind;
    my @expected_acl_mode;
    my @expected_acl_nlink;
    my @expected_acl_uid;
    my @expected_acl_gid;
    my @expected_acl_size;
    my @expected_acl_link_target;
    my $record_count = 0;
    my $total_regular_bytes = 0;
    my $total_path_argument_bytes = 0;
    my $walk;
    $walk = sub {
        my ($path, $relative, $depth) = @_;
        $depth <= $maximum_depth or die "capture depth exceeded bound\n";
        my @before = lstat($path);
        @before or die "capture node disappeared\n";
        $before[0] == $root_device or die "capture crossed filesystem\n";
        my $expected_key = stat_key(@before);
        my $type_bits = $before[2] & 0170000;
        my $kind;
        if ($type_bits == 0040000) {
            $kind = "directory";
        } elsif ($type_bits == 0100000) {
            $kind = "regular";
        } elsif ($type_bits == 0140000) {
            $kind = "socket";
        } elsif ($type_bits == 0120000) {
            $kind = "symlink";
        } else {
            die "capture encountered unsupported node kind at " . hex_of($relative) . "\n";
        }
        ++$record_count <= $maximum_records or die "capture record count exceeded bound\n";
        $total_path_argument_bytes += length($path) + 1;
        $total_path_argument_bytes <= $maximum_path_argument_bytes
            or die "capture helper argument bytes exceeded bound\n";
        push(@paths, $path);
        if ($kind eq "socket") {
            push(@socket_paths, $path);
        } else {
            push(@non_socket_paths, $path);
            if ($kind eq "symlink") {
                push(@symlink_paths, $path);
                !$observed_symlink{$relative}++ &&
                    exists($expected_symlink_targets{$relative})
                    or die "capture symlink path is unexpected\n";
            }
        }
        push(@expected_stat_prefixes, join(":", $before[0], $before[1], $before[4],
            $before[5], $before[3], sprintf("%o", $before[2] & 07777), $before[7]));
        push(@expected_acl_kind, $kind);
        push(@expected_acl_mode, $before[2] & 07777);
        push(@expected_acl_nlink, $before[3]);
        push(@expected_acl_uid, $before[4]);
        push(@expected_acl_gid, $before[5]);
        push(@expected_acl_size, $before[7]);
        my $link_target = "";
        my $digest = "-";
        if ($kind eq "regular") {
            my $content_record;
            ($digest, $content_record) = read_regular(
                $path, $relative, $expected_key, $before[7], \$total_regular_bytes
            );
            push(@contents, $content_record) if length($content_record) != 0;
        } elsif ($kind eq "symlink") {
            my $link_record;
            ($digest, $link_record, $link_target) =
                read_symlink($path, $relative, $expected_key, $before[7]);
            $link_target eq $expected_symlink_targets{$relative}
                or die "capture symlink target changed\n";
            push(@links, $link_record);
        }
        push(@expected_acl_link_target, $link_target);
        push(@records, join("\t", "record", hex_of($relative), $kind, $before[0],
            $before[1], $before[4], $before[5], $before[3],
            sprintf("%04o", $before[2] & 07777), $before[7], $before[9],
            $before[10], $digest) . "\n");
        if ($kind eq "directory") {
            sysopen(my $directory_descriptor, $path, O_RDONLY | 0x100)
                or die "capture directory descriptor open failed\n";
            my @opened = stat($directory_descriptor);
            @opened && stat_key(@opened) eq $expected_key
                or die "capture directory descriptor identity changed\n";
            opendir(my $directory, $path) or die "capture directory open failed\n";
            my @names = sort grep { $_ ne "." && $_ ne ".." } readdir($directory);
            closedir($directory) or die "capture directory close failed\n";
            for my $name (@names) {
                valid_name($name) or die "capture node name is unsafe\n";
                my $child_relative = length($relative) == 0 ? $name : "$relative/$name";
                length($child_relative) <= 4096 or die "capture path exceeded bound\n";
                $walk->("$path/$name", $child_relative, $depth + 1);
            }
            my @after_descriptor = stat($directory_descriptor);
            my @after_named = lstat($path);
            @after_descriptor && @after_named &&
                stat_key(@after_descriptor) eq $expected_key &&
                stat_key(@after_named) eq $expected_key
                or die "capture directory identity changed after enumeration\n";
            close($directory_descriptor) or die "capture directory descriptor close failed\n";
        } else {
            my @after_named = lstat($path);
            @after_named && stat_key(@after_named) eq $expected_key
                or die "capture node identity changed after observation\n";
        }
    };
    $walk->($root, "", 0);
    my @root_stat = lstat($root);
    @root_stat && $root_stat[0] == $root_device && $root_stat[1] == $root_inode &&
        $root_stat[4] == 0 && $root_stat[5] == 0 && $root_stat[3] == 8 &&
        (($root_stat[2] & 0170000) == 0040000) &&
        (($root_stat[2] & 07777) == 0711) && $root_stat[7] == 256
        or die "capture root evidence identity changed\n";
    for my $required (keys(%captured_contents)) {
        grep { $_ eq $required } map { my @field = split(/\t/, $_, -1); pack("H*", $field[1]) } @records
            or die "capture selected evidence is missing\n";
    }
    @socket_paths == 1 or die "capture socket topology changed\n";
    @symlink_paths == keys(%expected_symlink_targets) &&
        !grep { !$observed_symlink{$_} } keys(%expected_symlink_targets)
        or die "capture symlink topology changed\n";
    my @observations;
    push(@observations,
        observation_record("data-volume", 0, $data_volume_observation));
    my ($stat_status, $stat_output) = synchronous_capture(
        $maximum_helper_output_bytes, "/usr/bin/stat", "-f",
        "%d:%i:%u:%g:%l:%Lp:%z:%f", @paths);
    $stat_status == 0 or die "capture BSD stat observation failed\n";
    my @stat_lines = split(/\n/, $stat_output, -1);
    pop(@stat_lines) eq "" or die "capture BSD stat output lacked terminator\n";
    @stat_lines == @expected_stat_prefixes or die "capture BSD stat count changed\n";
    for my $index (0 .. $#stat_lines) {
        $stat_lines[$index] =~ /\A\Q$expected_stat_prefixes[$index]\E:[0-9]+\z/
            or die "capture BSD stat disagreed with descriptor observation\n";
    }
    push(@observations, observation_record("bsd-stat", $stat_status, $stat_output));
    my ($xattr_status, $xattr_output) = synchronous_capture(
        $maximum_helper_output_bytes, "/usr/bin/xattr", "-s", @non_socket_paths);
    $xattr_status == 0 && $xattr_output eq ""
        or die "capture found an extended attribute\n";
    push(@observations, observation_record("xattr", $xattr_status, $xattr_output));
    my ($socket_xattr_status, $socket_xattr_output) = synchronous_capture(
        4096, "/usr/bin/xattr", @socket_paths);
    my $expected_socket_xattr = "xattr: [Errno 102] Operation not supported on socket: " .
        chr(39) . $socket_paths[0] . chr(39) . "\n";
    $socket_xattr_status == 256 && $socket_xattr_output eq $expected_socket_xattr
        or die "capture socket xattr observation changed\n";
    push(@observations,
        observation_record("socket-xattr", $socket_xattr_status, $socket_xattr_output));
    my ($acl_status, $acl_output) = synchronous_capture(
        $maximum_helper_output_bytes, "/bin/ls", "-lde", @paths);
    $acl_status == 0 or die "capture ACL observation failed\n";
    my @acl_lines = split(/\n/, $acl_output, -1);
    pop(@acl_lines) eq "" or die "capture ACL output lacked terminator\n";
    @acl_lines == @paths or die "capture found an ACL or malformed listing\n";
    for my $index (0 .. $#acl_lines) {
        acl_line_is_canonical($acl_lines[$index], $expected_acl_kind[$index],
            $expected_acl_mode[$index], $expected_acl_nlink[$index],
            $expected_acl_uid[$index], $expected_acl_gid[$index],
            $expected_acl_size[$index], $paths[$index],
            $expected_acl_link_target[$index])
            or die "capture ACL observation disagreed with descriptor metadata\n";
    }
    push(@observations, observation_record("acl", $acl_status, $acl_output));
    my ($lsof_status, $lsof_output) = synchronous_capture(
        $maximum_helper_output_bytes, "/usr/sbin/lsof", "-Fn", "+D", $root);
    $lsof_status == 256 && $lsof_output eq "" or die "capture root tree is open\n";
    push(@observations, observation_record("openers", $lsof_status, $lsof_output));
    my $sealed_host = "$root/sealed-prep-L1Ciab/opensteamer Host.app";
    my ($verify_status, $verify_output) = synchronous_capture(
        $maximum_helper_output_bytes, "/usr/bin/codesign", "--verify", "--strict",
        "--all-architectures", $sealed_host);
    $verify_status == 0 && $verify_output eq ""
        or die "capture sealed host signature verification failed\n";
    push(@observations,
        observation_record("codesign-verify", $verify_status, $verify_output));
    my ($display_status, $display_output) = synchronous_capture(
        $maximum_helper_output_bytes, "/usr/bin/codesign", "-d", "--verbose=4",
        $sealed_host);
    $display_status == 0 &&
        (() = $display_output =~ /^Identifier=com[.]elamin[.]AudioStreamer[.]CaptureServer$/mg) == 1 &&
        (() = $display_output =~ /^TeamIdentifier=MSMG8CJLB3$/mg) == 1 &&
        (() = $display_output =~ /^CDHash=af8181f6c0e81fc5824d1b9ff36dbb36a25ad18b$/mg) == 1 &&
        (() = $display_output =~ /^Authority=Apple Development: Ahmed Elamin [(]92LVX32M8K[)]$/mg) == 1 &&
        (() = $display_output =~ /^CodeDirectory v=20400 size=12042 flags=0x0[(]none[)] hashes=369[+]3 location=embedded$/mg) == 1
        or die "capture sealed host signature identity changed\n";
    push(@observations,
        observation_record("codesign-display", $display_status, $display_output));
    my $payload = "schema=opensteamer.failed-root-evidence-capture.v1\n" .
        "challenge=$challenge\n" .
        "volume_uuid=$expected_data_volume_uuid\n" .
        "volume_group_uuid=$expected_data_volume_group_uuid\n" .
        "volume_mount=$data_volume_mount\n" .
        "filesystem_type=apfs\n" .
        "root_device=$root_device\n" .
        "root_inode=$root_inode\n" .
        "record_count=$record_count\n" .
        "total_regular_bytes=$total_regular_bytes\n" .
        join("", @records) . join("", @contents) . join("", @links) .
        join("", @observations) .
        "end=opensteamer.failed-root-evidence-capture.v1\n";
    length($payload) <= $maximum_payload_bytes or die "capture payload exceeded bound\n";
    return $payload;
}

my $first = capture_pass();
my $second = capture_pass();
$first eq $second or die "capture passes were not identical\n";
require_exact_lease($lease);
my $payload_hash = sha256_hex($first);
my $transport = join("\t", $challenge, length($first), $payload_hash, hex_of($first)) . "\n";
length($transport) <= 2_097_280 or die "capture transport exceeded bound\n";
require_exact_lease($lease);
print STDOUT $transport or die "capture stdout failed\n";
close(STDOUT) or die "capture stdout close failed\n";
exit 0;
OPENSTEAMER_ROOT_CAPTURE_L1CIAB'

usage() {
    print -u2 -- "usage: $LAUNCHER $SELF_TEST_MODE|$PREFLIGHT_MODE|$CAPTURE_MODE|$START_MODE|$STOP_MODE"
    exit 64
}

fail() {
    print -u2 -- "$1"
    exit "${2:-1}"
}

sha256_file() {
    /usr/bin/env -i LC_ALL=C HOME="$PINNED_USER_HOME" PATH="$PINNED_EXEC_PATH" \
        /usr/bin/shasum -a 256 -- "$1" | /usr/bin/awk '{print $1}'
}

require_hash() {
    local target_path="$1"
    local expected="$2"
    local actual
    actual="$(sha256_file "$target_path")"
    [[ "$actual" == "$expected" ]] ||
        fail "pinned local-trial input changed: $target_path expected=$expected actual=$actual"
}

data_volume_binding_is_valid() {
    local volume_uuid="$1"
    local volume_group_uuid="$2"
    local mount_point="$3"
    local filesystem_type="$4"
    local internal_value="$5"
    local device_before="$6"
    local device_after="$7"
    [[ "$volume_uuid" == "$EXPECTED_DATA_VOLUME_UUID" &&
       "$volume_group_uuid" == "$EXPECTED_DATA_VOLUME_GROUP_UUID" &&
       "$mount_point" == "$DATA_VOLUME_MOUNT" &&
       "$filesystem_type" == 'apfs' && "$internal_value" == 'true' &&
       "$device_before" == <-> && "$device_before" -gt 0 &&
       "$device_after" == "$device_before" ]]
}

data_volume_plist_value() {
    local plist_bytes="$1"
    local property_name="$2"
    print -rn -- "$plist_bytes" | /usr/bin/env -i LC_ALL=C HOME="$PINNED_USER_HOME" \
        PATH="$PINNED_EXEC_PATH" "$PLUTIL" -extract "$property_name" raw -o - -
}

require_data_volume_identity() {
    [[ -d "$DATA_VOLUME_MOUNT" && ! -L "$DATA_VOLUME_MOUNT" &&
       "$(/usr/bin/stat -f '%u:%g:%Lp:%f' "$DATA_VOLUME_MOUNT")" == '0:80:775:0' ]] ||
        fail 'canonical APFS Data volume mount is unavailable or unsafe'
    [[ -f "$DISKUTIL" && ! -L "$DISKUTIL" && -x "$DISKUTIL" &&
       "$(/usr/bin/stat -f '%i:%u:%g:%l:%Lp:%z:%f' "$DISKUTIL")" ==
           "$EXPECTED_DISKUTIL_STAT" &&
       -f "$PLUTIL" && ! -L "$PLUTIL" && -x "$PLUTIL" &&
       "$(/usr/bin/stat -f '%i:%u:%g:%l:%Lp:%z:%f' "$PLUTIL")" ==
           "$EXPECTED_PLUTIL_STAT" ]] ||
        fail 'pinned APFS volume-identity observers changed'
    require_hash "$DISKUTIL" "$EXPECTED_DISKUTIL_SHA256"
    require_hash "$PLUTIL" "$EXPECTED_PLUTIL_SHA256"
    /usr/bin/codesign --verify --strict "$DISKUTIL" "$PLUTIL" ||
        fail 'pinned APFS volume-identity observer signature changed'

    local mount_before mount_after device_before device_after volume_plist
    local volume_uuid volume_group_uuid mount_point filesystem_type internal_value
    mount_before="$(/usr/bin/stat -f '%d:%i:%u:%g:%Lp:%f' "$DATA_VOLUME_MOUNT")"
    device_before="${mount_before%%:*}"
    volume_plist=$(
        /usr/bin/env -i LC_ALL=C HOME="$PINNED_USER_HOME" PATH="$PINNED_EXEC_PATH" \
            "$DISKUTIL" info -plist "$DATA_VOLUME_MOUNT"
    ) || fail 'could not query the canonical APFS Data volume'
    (( ${#volume_plist} >= 256 && ${#volume_plist} <= 131072 )) ||
        fail 'canonical APFS Data volume description exceeded its bound'
    volume_uuid="$(data_volume_plist_value "$volume_plist" VolumeUUID)" ||
        fail 'canonical APFS Data volume UUID is unavailable'
    volume_group_uuid="$(data_volume_plist_value "$volume_plist" APFSVolumeGroupID)" ||
        fail 'canonical APFS Data volume-group UUID is unavailable'
    mount_point="$(data_volume_plist_value "$volume_plist" MountPoint)" ||
        fail 'canonical APFS Data mount point is unavailable'
    filesystem_type="$(data_volume_plist_value "$volume_plist" FilesystemType)" ||
        fail 'canonical APFS Data filesystem type is unavailable'
    internal_value="$(data_volume_plist_value "$volume_plist" Internal)" ||
        fail 'canonical APFS Data internal-media proof is unavailable'
    mount_after="$(/usr/bin/stat -f '%d:%i:%u:%g:%Lp:%f' "$DATA_VOLUME_MOUNT")"
    device_after="${mount_after%%:*}"
    [[ "$mount_after" == "$mount_before" ]] ||
        fail 'canonical APFS Data mount changed during identity proof'
    data_volume_binding_is_valid "$volume_uuid" "$volume_group_uuid" "$mount_point" \
        "$filesystem_type" "$internal_value" "$device_before" "$device_after" ||
        fail 'canonical APFS Data volume identity changed'
    local anchor
    for anchor in / /Users /Library '/Library/Application Support' \
        "$PINNED_USER_HOME" "$BUILD_PARENT" "$EXPECTED_REPO"; do
        [[ -d "$anchor" && ! -L "$anchor" &&
           "$(/usr/bin/stat -f '%d' "$anchor")" == "$device_before" ]] ||
            fail "reviewed local-trial anchor escaped the canonical APFS Data volume: $anchor"
    done
    local observer
    for observer in "$DISKUTIL" "$PLUTIL"; do
        [[ "$(/usr/bin/stat -f '%d' "$observer")" == "$device_before" ]] ||
            fail "pinned APFS volume-identity observer escaped the canonical Data volume: $observer"
    done
    DATA_VOLUME_DEVICE="$device_before"
}

require_reviewed_source() {
    local source_path="$1"
    local expected="$2"
    [[ -f "$source_path" && ! -L "$source_path" ]] ||
        fail "reviewed local-trial source is unavailable: $source_path"
    [[ "$(/usr/bin/stat -f '%u:%g:%l:%Lp' "$source_path")" == '501:20:1:644' ]] ||
        fail "reviewed local-trial source metadata is unsafe: $source_path"
    require_hash "$source_path" "$expected"
}

require_private_snapshot() {
    local snapshot_path="$1"
    [[ -f "$snapshot_path" && ! -L "$snapshot_path" ]] ||
        fail "private local-trial source snapshot is unavailable: $snapshot_path"
    [[ "$(/usr/bin/stat -f '%u:%g:%l:%Lp' "$snapshot_path")" == '501:20:1:400' ]] ||
        fail "private local-trial source snapshot metadata is unsafe: $snapshot_path"
}

require_launcher_identity() {
    [[ "$(/usr/bin/id -u)" == '501' && "$(/usr/bin/id -g)" == '20' ]] ||
        fail 'local-trial launcher must run as the fixed uid501 account without sudo'
    [[ "$(/usr/bin/id -un)" == "$PINNED_USER_NAME" &&
       "$(/usr/bin/id -gn)" == 'staff' ]] ||
        fail 'local-trial launcher account names changed'
    [[ "$INVOKED_LAUNCHER_PATH" == "$LAUNCHER" && -f "$LAUNCHER" && ! -L "$LAUNCHER" ]] ||
        fail 'local-trial launcher escaped its reviewed canonical path'
    [[ "$(/usr/bin/stat -f '%u:%g:%l:%Lp' "$LAUNCHER")" == '501:20:1:755' ]] ||
        fail 'local-trial launcher metadata is unsafe'
    [[ "$(/usr/bin/grep -c '^readonly EXPECTED_LAUNCHER_NORMALIZED_SHA256=' "$LAUNCHER")" == '1' ]] ||
        fail 'local-trial launcher self-pin field is malformed'
    local normalized
    normalized=$(
        /usr/bin/sed -E \
            "s#^(readonly EXPECTED_LAUNCHER_NORMALIZED_SHA256=)'[^']*'#\\1'NORMALIZED_LAUNCHER_PIN'#" \
            "$LAUNCHER" | /usr/bin/env -i LC_ALL=C HOME="$PINNED_USER_HOME" \
                PATH="$PINNED_EXEC_PATH" /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
    )
    [[ "$normalized" == "$EXPECTED_LAUNCHER_NORMALIZED_SHA256" ]] ||
        fail 'local-trial launcher differs from its normalized self-pin'
    print -rn -- "$ROOT_BOOTSTRAP_COMMAND" | /bin/sh -n ||
        fail 'fixed root bootstrap command is not valid POSIX shell'
    local root_bootstrap_sha256
    root_bootstrap_sha256=$(print -rn -- "$ROOT_BOOTSTRAP_COMMAND" |
        /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
    [[ "$root_bootstrap_sha256" == "$EXPECTED_ROOT_BOOTSTRAP_SHA256" ]] ||
        fail 'fixed root bootstrap command differs from its dedicated pin'
    print -rn -- "$ROOT_CAPTURE_COMMAND" | /bin/sh -n ||
        fail 'fixed root capture command is not valid POSIX shell'
    local root_capture_sha256
    root_capture_sha256=$(print -rn -- "$ROOT_CAPTURE_COMMAND" |
        /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
    [[ "$root_capture_sha256" == "$EXPECTED_ROOT_CAPTURE_COMMAND_SHA256" ]] ||
        fail 'fixed root capture command differs from its dedicated pin'
}

require_launcher_lock_node() {
    [[ -f "$LAUNCHER_LOCK" && ! -L "$LAUNCHER_LOCK" &&
       "$(/usr/bin/stat -f '%u:%g:%l:%Lp:%z:%f' "$LAUNCHER_LOCK")" ==
           '501:20:1:600:0:0' ]] ||
        fail 'fixed live-launcher lock node is unsafe'
    local lock_xattrs lock_acl
    lock_xattrs=$(/usr/bin/xattr "$LAUNCHER_LOCK") ||
        fail 'could not inspect fixed live-launcher lock xattrs'
    [[ -z "$lock_xattrs" ]] || fail 'fixed live-launcher lock has extended attributes'
    lock_acl=$(/bin/ls -lde "$LAUNCHER_LOCK") ||
        fail 'could not inspect fixed live-launcher lock ACL'
    [[ "$(print -r -- "$lock_acl" | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" ==
       '1' ]] || fail 'fixed live-launcher lock has an ACL'
}

require_launcher_lock_held() {
    (( LAUNCHER_LOCK_ACQUIRED == 1 && LAUNCHER_LOCK_FD >= 0 )) ||
        fail 'live launcher does not own its singleton lock'
    require_launcher_lock_node
    zmodload -F zsh/stat b:zstat || fail 'zsh in-process fstat support is unavailable'
    local -A descriptor_stat named_stat
    zstat -H descriptor_stat -f "$LAUNCHER_LOCK_FD" ||
        fail 'could not fstat the retained live-launcher lock descriptor'
    zstat -H named_stat "$LAUNCHER_LOCK" ||
        fail 'could not stat the named live-launcher lock in-process'
    [[ "${descriptor_stat[device]}:${descriptor_stat[inode]}:${descriptor_stat[uid]}:${descriptor_stat[gid]}:${descriptor_stat[nlink]}:${descriptor_stat[mode]}:${descriptor_stat[size]}" ==
       "${named_stat[device]}:${named_stat[inode]}:${named_stat[uid]}:${named_stat[gid]}:${named_stat[nlink]}:${named_stat[mode]}:${named_stat[size]}" ]] ||
        fail 'live-launcher lock descriptor no longer names the canonical inode'
    local exclusion_probe_result
    set +e
    /usr/bin/env -i LC_ALL=C HOME="$PINNED_USER_HOME" PATH="$PINNED_EXEC_PATH" \
        USER="$PINNED_USER_NAME" LOGNAME="$PINNED_USER_NAME" \
        /bin/zsh -fc '
            zmodload -F zsh/system b:zsystem || exit 70
            zsystem flock -t 0.02 -i 0.005 -f probe_fd "$1" 2>/dev/null
            probe_result=$?
            if (( probe_result == 2 )); then
                exit 0
            fi
            if (( probe_result == 0 )); then
                zsystem flock -u "$probe_fd"
                exit 71
            fi
            exit 72
        ' live-launcher-lock-probe "$LAUNCHER_LOCK"
    exclusion_probe_result=$?
    set -e
    [[ "$exclusion_probe_result" == '0' ]] ||
        fail 'live-launcher singleton lock is not exclusively held'
    require_launcher_lock_node
    zstat -H descriptor_stat -f "$LAUNCHER_LOCK_FD" ||
        fail 'could not re-fstat the retained live-launcher lock descriptor'
    zstat -H named_stat "$LAUNCHER_LOCK" ||
        fail 'could not re-stat the named live-launcher lock in-process'
    [[ "${descriptor_stat[device]}:${descriptor_stat[inode]}:${descriptor_stat[uid]}:${descriptor_stat[gid]}:${descriptor_stat[nlink]}:${descriptor_stat[mode]}:${descriptor_stat[size]}" ==
       "${named_stat[device]}:${named_stat[inode]}:${named_stat[uid]}:${named_stat[gid]}:${named_stat[nlink]}:${named_stat[mode]}:${named_stat[size]}" ]] ||
        fail 'live-launcher lock inode changed during exclusion proof'
}

acquire_launcher_lock() {
    [[ "$MODE" == "$START_MODE" || "$MODE" == "$STOP_MODE" ||
       "$MODE" == "$CAPTURE_MODE" ]] ||
        fail 'singleton launcher lock requested outside a serialized mode'
    [[ -d "$BUILD_PARENT" && ! -L "$BUILD_PARENT" &&
       "$(/usr/bin/stat -f '%u:%g:%Lp' "$BUILD_PARENT")" == '501:20:700' ]] ||
        fail 'private launcher-lock parent metadata is unsafe'
    if [[ ! -e "$LAUNCHER_LOCK" && ! -L "$LAUNCHER_LOCK" ]]; then
        local create_lock_result
        set +e
        ( setopt localoptions noclobber; : > "$LAUNCHER_LOCK" ) 2>/dev/null
        create_lock_result=$?
        set -e
        [[ "$create_lock_result" == '0' || -e "$LAUNCHER_LOCK" ||
           -L "$LAUNCHER_LOCK" ]] || fail 'could not initialize fixed live-launcher lock'
    fi
    require_launcher_lock_node
    zmodload -F zsh/system b:zsystem || fail 'zsh advisory-lock support is unavailable'
    local acquire_lock_result
    set +e
    zsystem flock -t 0 -f LAUNCHER_LOCK_FD "$LAUNCHER_LOCK" 2>/dev/null
    acquire_lock_result=$?
    set -e
    [[ "$acquire_lock_result" == '0' ]] ||
        fail 'another live local-trial launcher already owns the singleton lock' 75
    LAUNCHER_LOCK_ACQUIRED=1
    require_launcher_lock_held
}

require_toolchain() {
    [[ -f "$RUSTC" && ! -L "$RUSTC" && -x "$RUSTC" ]] ||
        fail 'pinned local-trial Rust compiler is unavailable'
    [[ -f "$RUSTC_DRIVER" && ! -L "$RUSTC_DRIVER" ]] ||
        fail 'pinned local-trial Rust compiler driver is unavailable'
    require_hash "$RUSTC" "$EXPECTED_RUSTC_SHA256"
    require_hash "$RUSTC_DRIVER" "$EXPECTED_RUSTC_DRIVER_SHA256"
    [[ "$(/usr/bin/env -i LC_ALL=C HOME="$PINNED_USER_HOME" PATH="$PINNED_EXEC_PATH" \
        "$RUSTC" --version)" == "$EXPECTED_RUSTC_VERSION" ]] ||
        fail 'pinned local-trial Rust compiler version changed'
    [[ "$(/usr/bin/env -i LC_ALL=C HOME="$PINNED_USER_HOME" PATH="$PINNED_EXEC_PATH" \
        "$RUSTC" --print sysroot)" == "$RUSTC_SYSROOT" ]] ||
        fail 'pinned local-trial Rust sysroot changed'
    [[ -f /usr/bin/perl && ! -L /usr/bin/perl && -x /usr/bin/perl &&
       "$(/usr/bin/stat -f '%d' /usr/bin/perl)" == "$DATA_VOLUME_DEVICE" &&
       "$(/usr/bin/stat -f '%i:%u:%g:%l:%Lp:%z:%f' /usr/bin/perl)" ==
           "$EXPECTED_ROOT_WRAPPER_PERL_STAT" ]] ||
        fail 'pinned root-phase wrapper Perl changed'
    require_hash /usr/bin/perl "$EXPECTED_ROOT_WRAPPER_PERL_SHA256"
    /usr/bin/codesign --verify --strict /usr/bin/perl ||
        fail 'pinned root-phase wrapper Perl signature changed'
}

swiftc_resolution_is_valid() {
    local resolved_developer_dir="$1"
    local observed_swiftc="$2"
    [[ "$resolved_developer_dir" == "$PINNED_RESOLVED_DEVELOPER_DIR" &&
       "$observed_swiftc" == "$PINNED_XCRUN_SWIFTC" ]]
}

require_guardian_toolchain() {
    [[ -d "$PINNED_DEVELOPER_DIR" && ! -L "$PINNED_DEVELOPER_DIR" ]] ||
        fail 'pinned local-trial Xcode developer directory is unavailable'
    [[ -L "$PINNED_SWIFTC" && "$(/usr/bin/readlink "$PINNED_SWIFTC")" == 'swift-frontend' ]] ||
        fail 'pinned local-trial swiftc link changed'
    [[ -f "$PINNED_SWIFT_FRONTEND" && ! -L "$PINNED_SWIFT_FRONTEND" &&
       -x "$PINNED_SWIFT_FRONTEND" ]] ||
        fail 'pinned local-trial Swift frontend is unavailable'
    [[ -f "$PINNED_CLANG" && ! -L "$PINNED_CLANG" && -x "$PINNED_CLANG" ]] ||
        fail 'pinned local-trial linker driver is unavailable'
    require_hash "$PINNED_SWIFT_FRONTEND" "$EXPECTED_SWIFT_FRONTEND_SHA256"
    require_hash "$PINNED_CLANG" "$EXPECTED_CLANG_SHA256"
    local resolved_developer_dir observed_swiftc
    resolved_developer_dir="${PINNED_DEVELOPER_DIR:A}"
    observed_swiftc=$(
        /usr/bin/env -i LC_ALL=C HOME="$PINNED_USER_HOME" PATH="$PINNED_EXEC_PATH" \
            DEVELOPER_DIR="$PINNED_DEVELOPER_DIR" \
            /usr/bin/xcrun --sdk macosx --find swiftc
    ) || fail 'could not resolve the pinned local-trial swiftc'
    swiftc_resolution_is_valid "$resolved_developer_dir" "$observed_swiftc" ||
        fail 'pinned local-trial swiftc resolution changed'
    [[ "$(/usr/bin/env -i LC_ALL=C HOME="$PINNED_USER_HOME" PATH="$PINNED_EXEC_PATH" \
        DEVELOPER_DIR="$PINNED_DEVELOPER_DIR" /usr/bin/xcrun --sdk macosx swiftc --version 2>&1)" ==
       "$EXPECTED_SWIFTC_VERSION" ]] || fail 'pinned local-trial Swift compiler version changed'
}

require_guardian_maximum_contract() {
    local rust_source="$1"
    local swift_source="$2"
    local rust_maximum
    local swift_maximum
    local swift_parser_reference_count
    rust_maximum=$(
        /usr/bin/sed -nE \
            's/^const GUARDIAN_MAXIMUM_SECONDS: u64 = ([1-9][0-9_]*);$/\1/p' \
            "$rust_source"
    )
    swift_maximum=$(
        /usr/bin/sed -nE \
            's/^[[:space:]]*static let brokerMaximumSeconds = ([1-9][0-9_]*)\.0$/\1/p' \
            "$swift_source"
    )
    swift_parser_reference_count=$(
        /usr/bin/grep -E -c \
            '^[[:space:]]*maximum <= Contract\.brokerMaximumSeconds else \{$' \
            "$swift_source" || true
    )
    rust_maximum="${rust_maximum//_/}"
    swift_maximum="${swift_maximum//_/}"
    [[ "$rust_maximum" == <-> && "$swift_maximum" == <-> &&
       "$swift_parser_reference_count" == '1' ]] ||
        fail 'guardian maximum contract literals are missing or non-unique'
    (( rust_maximum <= swift_maximum )) ||
        fail 'controller guardian lifetime exceeds the guardian parser maximum'
}

require_live_release_contract() {
    local rust_source="$1"
    local controller_release_status
    controller_release_status=$(
        /usr/bin/sed -nE \
            's/^const LIVE_RELEASE_STATUS: &str = "([A-Z0-9_]+)";$/\1/p' \
            "$rust_source"
    )
    [[ "$controller_release_status" == 'UNREVIEWED_LOCAL_TRIAL_DISABLED' ||
       "$controller_release_status" == "$LIVE_RELEASE_READY" ]] ||
        fail 'controller release-gate literal is missing or non-unique'
    [[ "$controller_release_status" == "$LIVE_RELEASE_STATUS" ]] ||
        fail 'launcher and controller release gates disagree'
}

text_has_ordered_tokens() {
    local remaining_text="$1"
    shift
    local required_token
    for required_token in "$@"; do
        [[ "$remaining_text" == *"$required_token"* ]] || return 1
        remaining_text="${remaining_text#*"$required_token"}"
    done
}

root_payload_mutations_are_closed() {
    local payload_text="$1"
    local inner_payload payload_sha256
    local mutation_lines expected_mutation_lines redirection_lines expected_redirection_lines
    local metadata_tool_lines expected_metadata_tool_lines
    payload_sha256=$(print -rn -- "$payload_text" | /usr/bin/shasum -a 256 |
        /usr/bin/awk '{print $1}') || return 1
    [[ "$payload_sha256" == "$EXPECTED_ROOT_BOOTSTRAP_SHA256" &&
       "$payload_text" == *$'__DATA__\n'* &&
       "$payload_text" == *$'\nOPENSTEAMER_ROOT_WRAPPER_L1CIAB' ]] || return 1
    inner_payload="${payload_text#*$'__DATA__\n'}"
    inner_payload="${inner_payload%$'\nOPENSTEAMER_ROOT_WRAPPER_L1CIAB'}"
    mutation_lines=$(print -rn -- "$inner_payload" | /usr/bin/grep -E \
        '/(bin|usr/bin|usr/sbin)/(rm|rmdir|mv|install|chmod|chown|cp|ditto|touch|mkdir|ln|dd|truncate|tee)|(^|[[:space:];|&()])(rm|rmdir|mv|install|chmod|chown|cp|ditto|touch|mkdir|ln|dd|truncate|tee)([[:space:];|&()]|$)' || true)
    expected_mutation_lines=$'        /usr/bin/install -d -o root -g wheel -m 0711 "$trial_root_fresh"\n    /usr/bin/install -o root -g wheel -m 0500 "$trial_stage_controller" \\\n    /usr/sbin/chown root:wheel "$trial_root_fresh_pin"\n    /bin/chmod 0400 "$trial_root_fresh_pin"\n    /usr/sbin/chown root:wheel "$trial_root_fresh_log"\n    /bin/chmod 0600 "$trial_root_fresh_log"\n    /bin/mv -n "$trial_root_support" "$trial_root_evidence_fifth"\n    /bin/mv -n "$trial_root_fresh" "$trial_root_support"'
    [[ "$mutation_lines" == "$expected_mutation_lines" ]] || return 1
    metadata_tool_lines=$(print -rn -- "$inner_payload" | /usr/bin/grep -E \
        '/(bin|usr/bin|usr/sbin)/(xattr|chflags)|(^|[[:space:];|&()])(xattr|chflags)([[:space:];|&()]|$)' || true)
    expected_metadata_tool_lines=$'    trial_plain_xattrs=$(/usr/bin/xattr "$trial_plain_node")\n    trial_socket_xattrs=$(/usr/bin/xattr "$trial_socket_path" 2>&1)\n    trial_sealed_xattrs=$(/usr/bin/xattr -lr "$trial_sealed_host")\n    [ -z "$(/usr/bin/xattr -lr "$trial_fixed_user_tree")" ]\n    [ -z "$(/usr/bin/find "$trial_failed_support" -xdev ! -type s -exec /usr/bin/xattr {} +)" ]\n    trial_failed_socket_xattrs=$(/usr/bin/xattr "$trial_failed_socket" 2>&1)'
    [[ "$metadata_tool_lines" == "$expected_metadata_tool_lines" ]] || return 1
    redirection_lines=$(print -rn -- "$inner_payload" | /usr/bin/grep -F '>' || true)
    expected_redirection_lines=$'    trial_closed_openers=$(/usr/sbin/lsof -Fn +D "$trial_closed_tree" 2>/dev/null)\n    trial_socket_xattrs=$(/usr/bin/xattr "$trial_socket_path" 2>&1)\n    trial_socket_openers=$(/usr/sbin/lsof -Fn -- "$trial_socket_path" 2>/dev/null)\n    trial_driver_signature=$(/usr/bin/codesign -d --verbose=4 "$trial_driver" 2>&1)\n    trial_sealed_signature=$(/usr/bin/codesign -d --verbose=4 "$trial_sealed_host" 2>&1)\n    trial_uid_pointer_openers=$(/usr/sbin/lsof -Fn -- "$trial_uid_pointer" 2>/dev/null)\n    trial_u2_pointer_openers=$(/usr/sbin/lsof -Fn -- "$trial_u2_pointer" 2>/dev/null)\n    /usr/bin/printf "%s\\n" "$trial_expected_sha" > "$trial_root_fresh_pin"\n    : > "$trial_root_fresh_log"\n    trial_failed_socket_xattrs=$(/usr/bin/xattr "$trial_failed_socket" 2>&1)'
    [[ "$redirection_lines" == "$expected_redirection_lines" ]] || return 1
    [[ "$(print -rn -- "$inner_payload" | /usr/bin/grep -F -x -c \
            '    /usr/bin/printf "%s\n" "$trial_expected_sha" > "$trial_root_fresh_pin"')" == '1' &&
       "$(print -rn -- "$inner_payload" | /usr/bin/grep -F -x -c \
            '    : > "$trial_root_fresh_log"')" == '1' &&
       "$(print -rn -- "$inner_payload" | /usr/bin/grep -E -c \
            '(>|>>)[[:space:]]*"?\$trial_root_evidence' || true)" == '0' &&
       "$(print -rn -- "$inner_payload" | /usr/bin/grep -E -c \
            '/(usr/)?bin/(rm|rmdir)([[:space:]]|$)|(^|[^[:alnum:]_])unlink([[:space:](]|$)' || true)" == '0' &&
       "$(print -rn -- "$inner_payload" | /usr/bin/grep -E -c \
            '^[[:space:]]*/(bin/(sh|zsh)|usr/bin/(perl|python3|ruby|osascript))([[:space:]]|$)' || true)" == '0' &&
       "$(print -rn -- "$inner_payload" | /usr/bin/grep -E -c \
            '(^|[[:space:]])(-delete|eval|source)([[:space:]]|$)' || true)" == '0' ]] || return 1
}

root_retry_payload_contract_is_closed() {
    local payload_text="$1"
    local r0_branch r2_branch r3_branch r0_prepare_block r1_publish_block
    local r2_publish_block final_r3_block prepare_fresh_body boundary_body prior_root_body
    local baseline_body
    prepare_fresh_body=$(print -rn -- "$payload_text" | /usr/bin/sed -n \
        '/^prepare_fresh_root_support() {$/,/^}$/p')
    boundary_body=$(print -rn -- "$payload_text" | /usr/bin/sed -n \
        '/^require_failed_loopback_preservation_boundary() {$/,/^}$/p')
    prior_root_body=$(print -rn -- "$payload_text" | /usr/bin/sed -n \
        '/^require_prior_root_evidence_boundaries() {$/,/^}$/p')
    baseline_body=$(print -rn -- "$payload_text" | /usr/bin/sed -n \
        '/^require_root_retry_baseline() {$/,/^}$/p')
    r0_branch=$'if [ -d "$trial_root_support" ] && [ ! -L "$trial_root_support" ] && \\\n   [ ! -e "$trial_root_evidence_fifth" ] && [ ! -L "$trial_root_evidence_fifth" ]; then\n    require_failed_loopback_root_support "$trial_root_support"\n    require_safe_partial_fresh_root_support\n    if [ -f "$trial_root_fresh_controller" ] && [ ! -L "$trial_root_fresh_controller" ] && \\\n       [ -f "$trial_root_fresh_pin" ] && [ ! -L "$trial_root_fresh_pin" ] && \\\n       [ -f "$trial_root_fresh_log" ] && [ ! -L "$trial_root_fresh_log" ]; then\n        require_fresh_root_support "$trial_root_fresh"\n        trial_quarantine_state="R1"\n    else\n        trial_quarantine_state="R0"\n    fi'
    r2_branch=$'elif [ ! -e "$trial_root_support" ] && [ ! -L "$trial_root_support" ] && \\\n     [ -d "$trial_root_evidence_fifth" ] && [ ! -L "$trial_root_evidence_fifth" ] && \\\n     [ -d "$trial_root_fresh" ] && [ ! -L "$trial_root_fresh" ]; then\n    require_failed_loopback_root_support "$trial_root_evidence_fifth"\n    require_fresh_root_support "$trial_root_fresh"\n    trial_quarantine_state="R2"'
    r3_branch=$'elif [ -d "$trial_root_support" ] && [ ! -L "$trial_root_support" ] && \\\n     [ -d "$trial_root_evidence_fifth" ] && [ ! -L "$trial_root_evidence_fifth" ] && \\\n     [ ! -e "$trial_root_fresh" ] && [ ! -L "$trial_root_fresh" ]; then\n    require_failed_loopback_root_support "$trial_root_evidence_fifth"\n    require_fresh_root_support "$trial_root_support"\n    trial_quarantine_state="R3"'
    r0_prepare_block=$'if [ "$trial_quarantine_state" = "R0" ]; then\n    require_failed_loopback_preservation_boundary\n    require_failed_loopback_root_support "$trial_root_support"\n    [ ! -e "$trial_root_evidence_fifth" ] && [ ! -L "$trial_root_evidence_fifth" ]\n    prepare_fresh_root_support\n    require_failed_loopback_preservation_boundary\n    require_failed_loopback_root_support "$trial_root_support"\n    require_fresh_root_support "$trial_root_fresh"\n    trial_quarantine_state="R1"\nfi'
    r1_publish_block=$'    /bin/sync\n    require_failed_loopback_preservation_boundary\n    require_failed_loopback_root_support "$trial_root_support"\n    require_fresh_root_support "$trial_root_fresh"\n    [ ! -e "$trial_root_evidence_fifth" ] && [ ! -L "$trial_root_evidence_fifth" ]\n    require_root_phase_lease_held\n    /bin/mv -n "$trial_root_support" "$trial_root_evidence_fifth"\n    [ ! -e "$trial_root_support" ] && [ ! -L "$trial_root_support" ]\n    [ "$(/usr/bin/stat -f "%d:%i" "$trial_root_evidence_fifth")" = \\\n      "$trial_failed_prepublication_identity" ]\n    require_failed_loopback_root_support "$trial_root_evidence_fifth"\n    require_fresh_root_support "$trial_root_fresh"\n    /bin/sync\n    require_failed_loopback_preservation_boundary\n    require_failed_loopback_root_support "$trial_root_evidence_fifth"\n    require_fresh_root_support "$trial_root_fresh"\n    trial_quarantine_state="R2"'
    r2_publish_block=$'    /bin/sync\n    require_failed_loopback_preservation_boundary\n    require_failed_loopback_root_support "$trial_root_evidence_fifth"\n    require_fresh_root_support "$trial_root_fresh"\n    [ ! -e "$trial_root_support" ] && [ ! -L "$trial_root_support" ]\n    require_root_phase_lease_held\n    /bin/mv -n "$trial_root_fresh" "$trial_root_support"\n    [ ! -e "$trial_root_fresh" ] && [ ! -L "$trial_root_fresh" ]\n    [ "$(fresh_root_support_identity "$trial_root_support")" = \\\n      "$trial_fresh_prepublication_identity" ]\n    require_failed_loopback_root_support "$trial_root_evidence_fifth"\n    require_fresh_root_support "$trial_root_support"\n    /bin/sync\n    require_failed_loopback_preservation_boundary\n    require_failed_loopback_root_support "$trial_root_evidence_fifth"\n    require_fresh_root_support "$trial_root_support"\n    trial_quarantine_state="R3"'
    final_r3_block=$'[ "$trial_quarantine_state" = "R3" ]\n[ ! -e "$trial_root_fresh" ] && [ ! -L "$trial_root_fresh" ]\n/bin/sync\nrequire_failed_loopback_preservation_boundary\nrequire_failed_loopback_root_support "$trial_root_evidence_fifth"\nrequire_fresh_root_support "$trial_root_support"'
    [[ "$payload_text" == *"$r0_branch"* && "$payload_text" == *"$r2_branch"* &&
       "$payload_text" == *"$r3_branch"* && "$payload_text" == *"$r0_prepare_block"* &&
       "$payload_text" == *"$r1_publish_block"* &&
       "$payload_text" == *"$r2_publish_block"* &&
       "$payload_text" == *"$final_r3_block"* ]] || return 1
    [[ "$(print -rn -- "$prepare_fresh_body" | /usr/bin/grep -F -x -c \
            '    /usr/bin/install -o root -g wheel -m 0500 "$trial_stage_controller" \')" == '1' &&
       "$(print -rn -- "$prepare_fresh_body" | /usr/bin/grep -F -x -c \
            '        "$trial_root_fresh_controller"')" == '1' &&
       "$(print -rn -- "$prepare_fresh_body" | /usr/bin/grep -F -c \
            '$trial_root_evidence' || true)" == '0' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            '    /bin/mv -n "$trial_root_support" "$trial_root_evidence_fifth"')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            '    /bin/mv -n "$trial_root_fresh" "$trial_root_support"')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -c '/bin/sync')" == '6' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            '    require_sealed_host_tree "$trial_d1_sealed_host" \')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            '        "ed71df7533902a1fb9105d491818bcebfdc93d932830973a56b9846ef7fd5514"')" == '1' &&
       "$(print -rn -- "$boundary_body" | /usr/bin/grep -F -x -c \
            '    require_u3_user_evidence_root')" == '1' &&
       "$(print -rn -- "$boundary_body" | /usr/bin/grep -F -x -c \
            '    require_fresh_user_stage_root')" == '1' &&
       "$(print -rn -- "$prior_root_body" | /usr/bin/grep -F -x -c \
            '    require_d1_root_support "$trial_root_evidence_fourth"')" == '1' &&
       "$(print -rn -- "$baseline_body" | /usr/bin/grep -F -x -c \
            '    [ ! -e "$trial_user_stage_ready" ] && [ ! -L "$trial_user_stage_ready" ]')" == '1' &&
       "$(print -rn -- "$baseline_body" | /usr/bin/grep -F -x -c \
            '    [ ! -e "$trial_legacy_user_stage_ready" ] && [ ! -L "$trial_legacy_user_stage_ready" ]')" == '1' ]] || return 1
    text_has_ordered_tokens "$payload_text" \
        $'require_root_phase_lease_held\nrequire_prior_root_evidence_boundaries\nrequire_prior_user_evidence_root\nrequire_u2_user_evidence_root\nrequire_u3_user_evidence_root\nrequire_fresh_user_stage_root\ntrial_initial_user_stage_identity=$(fresh_user_stage_identity)\nrequire_root_retry_baseline' \
        "$r0_branch" "$r2_branch" "$r3_branch" \
        "$r0_prepare_block" \
        'if [ "$trial_quarantine_state" = "R1" ]; then' \
        '    trial_failed_prepublication_identity=$(/usr/bin/stat -f "%d:%i" "$trial_root_support")' \
        "$r1_publish_block" \
        'if [ "$trial_quarantine_state" = "R2" ]; then' \
        '    trial_fresh_prepublication_identity=$(fresh_root_support_identity "$trial_root_fresh")' \
        "$r2_publish_block" \
        "$final_r3_block" \
        'require_root_phase_lease_held'
    text_has_ordered_tokens "$prepare_fresh_body" \
        '    require_root_phase_lease_held' \
        '    /usr/bin/install -o root -g wheel -m 0500 "$trial_stage_controller" \' \
        '        "$trial_root_fresh_controller"' \
        '    require_fresh_root_support "$trial_root_fresh"'
}

launcher_auth_dispatch_contract_is_closed() {
    local launcher_text="$1"
    local bootstrap_body cleanup_body start_body
    local marker_name='AUTHORIZATION_ATTEMPTED'
    local marker_line="    ${marker_name}=1"
    bootstrap_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^bootstrap_root_broker_once() {$/,/^}$/p')
    cleanup_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n '/^cleanup() {$/,/^}$/p')
    start_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^    "$START_MODE")$/,/^        ;;$/p')
    [[ "$(print -rn -- "$launcher_text" | /usr/bin/grep -F -x -c 'cleanup() {')" == '1' &&
       "$(print -rn -- "$launcher_text" | /usr/bin/grep -F -x -c 'bootstrap_root_broker_once() {')" == '1' &&
       "$(print -rn -- "$bootstrap_body" | /usr/bin/grep -F -x -c "$marker_line")" == '1' &&
       "$(print -rn -- "$bootstrap_body" | /usr/bin/grep -F -x -c \
            '    require_launcher_lock_held')" == '2' &&
       "$(print -rn -- "$bootstrap_body" | /usr/bin/grep -F -x -c \
            '    classify_retry_state')" == '1' &&
       "$(print -rn -- "$start_body" | /usr/bin/grep -F -x -c \
            '        classify_retry_state')" == '2' &&
       "$(print -rn -- "$start_body" | /usr/bin/grep -F -x -c \
            '        advance_failed_loopback_user_state')" == '1' &&
       "$(print -rn -- "$start_body" | /usr/bin/grep -F -x -c \
            '        bootstrap_root_broker_once')" == '1' &&
       "$(print -rn -- "$start_body" | /usr/bin/grep -F -x -c \
            '            "$CONTROLLER" "$RETRY_PREFLIGHT_MODE"')" == '1' &&
       "$(print -rn -- "$start_body" | /usr/bin/grep -F -x -c \
            '            "$USER_CONTROLLER_STAGE" "$START_MODE"')" == '1' &&
       "$(print -rn -- "$start_body" | /usr/bin/grep -F -c \
            'stage_live_one_shot' || true)" == '0' &&
       "$(print -rn -- "$cleanup_body" | /usr/bin/grep -E -c \
            '\$(TRIAL_ROOT|FAILED_LOOPBACK_TRIAL_ROOT|USER_STAGE_READY_ROOT|ROOT_SUPPORT|FAILED_LOOPBACK_ROOT_SUPPORT|FRESH_ROOT_SUPPORT|FAILED_COREAUDIO_ROOT_SUPPORT)' || true)" == '0' ]] || return 1
    text_has_ordered_tokens "$bootstrap_body" \
        '    require_launcher_lock_held' \
        '    classify_retry_state' \
        '    [[ "$USER_RETRY_STATE" == '\''E2'\'' &&' \
        '       ( "$ROOT_RETRY_STATE" == '\''R0'\'' || "$ROOT_RETRY_STATE" == '\''R1'\'' ||' \
        '         "$ROOT_RETRY_STATE" == '\''R2'\'' || "$ROOT_RETRY_STATE" == '\''R3'\'' ) ]] ||' \
        "$marker_line" \
        '        builtin cd / || exit 69' \
        '            /usr/bin/osascript - "$ROOT_BOOTSTRAP_COMMAND" <<'\''APPLESCRIPT'\''' \
        '    require_launcher_lock_held' \
        '    [[ "$root_pid" == <-> ]]' || return 1
    text_has_ordered_tokens "$start_body" \
        '        classify_retry_state' \
        '            "$CONTROLLER" "$RETRY_PREFLIGHT_MODE"' \
        '        advance_failed_loopback_user_state' \
        '        classify_retry_state' \
        '        [[ "$USER_RETRY_STATE" == '\''E2'\'' ]] ||' \
        '        bootstrap_root_broker_once' \
        '        require_launcher_lock_held' \
        '            "$USER_CONTROLLER_STAGE" "$START_MODE"'
}

launcher_compile_output_contract_is_closed() {
    local launcher_text="$1"
    local compile_body
    compile_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^compile_controller() {$/,/^}$/p')
    [[ "$(print -rn -- "$compile_body" | /usr/bin/grep -F -x -c \
            '        cd "$BUILD_ROOT"')" == '1' &&
       "$(print -rn -- "$compile_body" | /usr/bin/grep -F -x -c \
            '                "$SNAPSHOT_SOURCE" -o controller')" == '1' &&
       "$(print -rn -- "$compile_body" | /usr/bin/grep -F -c -- \
            '-o "$CONTROLLER"' || true)" == '0' &&
       "$(print -rn -- "$compile_body" | /usr/bin/grep -F -x -c \
            '    [[ -f "$CONTROLLER" && ! -L "$CONTROLLER" &&')" == '1' &&
       "$(print -rn -- "$compile_body" | /usr/bin/grep -F -x -c \
            '    require_hash "$CONTROLLER" "$EXPECTED_CONTROLLER_BINARY_SHA256"')" == '1' ]] ||
        return 1
    text_has_ordered_tokens "$compile_body" \
        '        cd "$BUILD_ROOT"' \
        '                "$SNAPSHOT_SOURCE" -o controller' \
        '    /bin/chmod 0500 "$CONTROLLER"' \
        '    [[ -f "$CONTROLLER" && ! -L "$CONTROLLER" &&' \
        '    require_hash "$CONTROLLER" "$EXPECTED_CONTROLLER_BINARY_SHA256"'
}

launcher_failed_loopback_user_lattice_contract_is_closed() {
    local launcher_text="$1"
    local payload_text="$2"
    local header_text stage_body advance_body user_classifier_body composite_body
    local move_lines expected_move_lines
    header_text="${launcher_text%%readonly ROOT_BOOTSTRAP_COMMAND=*}"
    stage_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^stage_live_one_shot() {$/,/^}$/p')
    advance_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^advance_failed_loopback_user_state() {$/,/^}$/p')
    user_classifier_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^classify_failed_loopback_user_state() {$/,/^}$/p')
    composite_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^classify_retry_state() {$/,/^}$/p')
    move_lines=$(print -rn -- "$stage_body$advance_body" | /usr/bin/grep -E \
        '(^|[^[:alnum:]_])((/usr)?/bin/)?mv([^[:alnum:]_]|$)' || true)
    expected_move_lines=$'        /bin/mv -n "$publish_root" "$USER_STAGE_READY_ROOT"\n        /bin/mv -n "$TRIAL_ROOT" "$FAILED_LOOPBACK_TRIAL_ROOT"\n        /bin/mv -n "$USER_STAGE_READY_ROOT" "$TRIAL_ROOT"'
    [[ "$header_text" == *"readonly LEGACY_USER_STAGE_READY_ROOT='/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab.ready-pre-root-L1Ciab'"* &&
       "$header_text" == *"readonly USER_STAGE_READY_ROOT='/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab.ready-installed-driver-both-order-mono-loopback-L1Ciab'"* &&
       "$header_text" == *"readonly FAILED_LOOPBACK_TRIAL_ROOT='/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab.failed-installed-driver-both-order-mono-loopback'"* &&
       "$header_text" != *'LOOPBACK_USER_STAGE_READY_ROOT'* &&
       "$header_text" != *'LIVE_STAGE_CREATED'* &&
       "$header_text" != *'LIVE_STAGE_IDENTITY'* &&
       "$header_text" != *'CANCELLED_STAGE_'* &&
       "$move_lines" == "$expected_move_lines" &&
       "$(print -rn -- "$stage_body" | /usr/bin/grep -F -x -c \
            '        /bin/mv -n "$publish_root" "$USER_STAGE_READY_ROOT"')" == '1' &&
       "$(print -rn -- "$stage_body" | /usr/bin/grep -F -c \
            '/bin/mkdir "$TRIAL_ROOT"' || true)" == '0' &&
       "$(print -rn -- "$stage_body" | /usr/bin/grep -F -c \
            '"$CONTROLLER" "$USER_CONTROLLER_STAGE"' || true)" == '0' &&
       "$(print -rn -- "$stage_body" | /usr/bin/grep -F -c '/bin/sync')" == '2' &&
       "$(print -rn -- "$advance_body" | /usr/bin/grep -F -c '/bin/sync')" == '4' &&
       "$(print -rn -- "$stage_body$advance_body" | /usr/bin/grep -E -c \
            '/bin/(rm|rmdir)([[:space:]]|$)' || true)" == '0' &&
       "$(print -rn -- "$user_classifier_body" | /usr/bin/grep -E -c \
            '/bin/(rm|rmdir|mv|install|chmod|chown|mkdir)([[:space:]]|$)' || true)" == '0' &&
       "$(print -rn -- "$user_classifier_body" | /usr/bin/grep -F -x -c \
            '    require_data_volume_identity')" == '1' &&
       "$(print -rn -- "$user_classifier_body" | /usr/bin/grep -F -x -c \
            '    require_preserved_failed_uid_admission_user_evidence')" == '1' &&
       "$(print -rn -- "$user_classifier_body" | /usr/bin/grep -F -x -c \
            '    require_preserved_failed_candidate_user_evidence')" == '1' &&
       "$(print -rn -- "$user_classifier_body" | /usr/bin/grep -F -x -c \
            '    require_preserved_rescued_user_evidence')" == '1' &&
       "$(print -rn -- "$user_classifier_body" | /usr/bin/grep -F -x -c \
            '        fail '\''failed-loopback user retry state is not exact E0, E1, or E2'\''')" == '1' &&
       "$(print -rn -- "$composite_body" | /usr/bin/grep -F -x -c \
            '        E0/R0|E1/R0|E2/R0|E2/R1|E2/R2|E2/R3)')" == '1' &&
       "$(print -rn -- "$composite_body" | /usr/bin/grep -F -x -c \
            '            RETRY_STATE="$USER_RETRY_STATE/$ROOT_RETRY_STATE"')" == '1' &&
       "$(print -rn -- "$composite_body" | /usr/bin/grep -E -c \
            '^[[:space:]]+[^[:space:]].*\)$')" == '2' &&
       "$(print -rn -- "$composite_body" | /usr/bin/grep -F -x -c \
            '            fail '\''failed-loopback composite retry state is outside the E0-E2/R0-R3 lattice'\''')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            '    [ ! -e "$trial_user_stage_ready" ] && [ ! -L "$trial_user_stage_ready" ]')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            '    require_u3_user_evidence_root')" -ge '1' ]] ||
        return 1
    text_has_ordered_tokens "$stage_body" \
        '    require_launcher_lock_held' \
        '    [[ "$USER_RETRY_STATE" == '\''E0'\'' ]] ||' \
        '    require_failed_loopback_user_trial_at "$TRIAL_ROOT"' \
        '    [[ ! -e "$FAILED_LOOPBACK_TRIAL_ROOT" && ! -L "$FAILED_LOOPBACK_TRIAL_ROOT" ]]' \
        '    [[ ! -e "$ACTIVE_POINTER" && ! -L "$ACTIVE_POINTER" ]] ||' \
        '        fail '\''active local-trial pointer is already present'\''' \
        '    local publish_root="$BUILD_ROOT/pre-root-user-stage.publish-L1Ciab"' \
        '    if [[ ! -e "$USER_STAGE_READY_ROOT" && ! -L "$USER_STAGE_READY_ROOT" ]]; then' \
        '        /bin/mkdir "$publish_root"' \
        '        /usr/bin/install -m 0500 "$CONTROLLER" "$publish_controller"' \
        '        require_complete_pre_root_user_stage_at "$publish_root"' \
        '            fail '\''pre-root user-stage publication crossed filesystems'\''' \
        '        local private_publish_identity' \
        '        private_publish_identity="$(/usr/bin/stat -f '\''%d:%i'\'' "$publish_root")"' \
        '        /bin/sync' \
        '        require_complete_pre_root_user_stage_at "$publish_root"' \
        '        [[ ! -e "$USER_STAGE_READY_ROOT" && ! -L "$USER_STAGE_READY_ROOT" ]] ||' \
        '            fail '\''fixed ready pre-root user-stage path raced publication'\''' \
        '        require_launcher_lock_held' \
        '        /bin/mv -n "$publish_root" "$USER_STAGE_READY_ROOT"' \
        '        [[ ! -e "$publish_root" && ! -L "$publish_root" &&' \
        '           "$(/usr/bin/stat -f '\''%d:%i'\'' "$USER_STAGE_READY_ROOT")" ==' \
        '               "$private_publish_identity" ]] ||' \
        '            fail '\''ready pre-root user-stage publication was not inode-preserving'\''' \
        '        require_complete_pre_root_user_stage_at "$USER_STAGE_READY_ROOT"' \
        '        /bin/sync' \
        '    fi' \
        '    require_complete_pre_root_user_stage_at "$USER_STAGE_READY_ROOT"' \
        '    [[ "$(/usr/bin/stat -f '\''%d'\'' "$USER_STAGE_READY_ROOT")" ==' \
        '       "$(/usr/bin/stat -f '\''%d'\'' "$USER_TRIAL_PARENT")" ]] ||' \
        '        fail '\''ready pre-root user-stage is on the wrong filesystem'\''' \
        '    require_failed_loopback_user_trial_at "$TRIAL_ROOT"' \
        '    require_launcher_lock_held' || return 1
    text_has_ordered_tokens "$advance_body" \
        '    require_launcher_lock_held' \
        '    classify_failed_loopback_user_state' \
        '    if [[ "$USER_RETRY_STATE" == '\''E0'\'' ]]; then' \
        '        stage_live_one_shot' \
        '        classify_failed_loopback_user_state' \
        '        [[ "$USER_RETRY_STATE" == '\''E0'\'' ]] ||' \
        '        require_complete_pre_root_user_stage_at "$USER_STAGE_READY_ROOT"' \
        '        require_failed_loopback_user_trial_at "$TRIAL_ROOT"' \
        '        [[ ! -e "$FAILED_LOOPBACK_TRIAL_ROOT" && ! -L "$FAILED_LOOPBACK_TRIAL_ROOT" &&' \
        '           "$(/usr/bin/stat -f '\''%d'\'' "$TRIAL_ROOT")" ==' \
        '               "$(/usr/bin/stat -f '\''%d'\'' "$USER_TRIAL_PARENT")" ]] ||' \
        '            fail '\''failed-loopback U3 publication cannot use one exclusive rename'\''' \
        '        local failed_identity' \
        '        failed_identity="$(/usr/bin/stat -f '\''%d:%i'\'' "$TRIAL_ROOT")"' \
        '    /bin/sync' \
        '        classify_failed_loopback_user_state' \
        '        [[ "$USER_RETRY_STATE" == '\''E0'\'' ]] ||' \
        '        require_launcher_lock_held' \
        '        /bin/mv -n "$TRIAL_ROOT" "$FAILED_LOOPBACK_TRIAL_ROOT"' \
        '        [[ ! -e "$TRIAL_ROOT" && ! -L "$TRIAL_ROOT" &&' \
        '           "$(/usr/bin/stat -f '\''%d:%i'\'' "$FAILED_LOOPBACK_TRIAL_ROOT")" ==' \
        '               "$failed_identity" ]] ||' \
        '            fail '\''failed-loopback U3 publication was not inode-preserving'\''' \
        '        [[ "$USER_RETRY_STATE" == '\''E1'\'' ]] ||' \
        '        /bin/sync' \
        '        [[ "$USER_RETRY_STATE" == '\''E1'\'' ]] ||' \
        '    if [[ "$USER_RETRY_STATE" == '\''E1'\'' ]]; then' \
        '        require_complete_pre_root_user_stage_at "$USER_STAGE_READY_ROOT"' \
        '        require_failed_loopback_user_trial_at "$FAILED_LOOPBACK_TRIAL_ROOT"' \
        '        [[ ! -e "$TRIAL_ROOT" && ! -L "$TRIAL_ROOT" &&' \
        '           "$(/usr/bin/stat -f '\''%d'\'' "$USER_STAGE_READY_ROOT")" ==' \
        '               "$(/usr/bin/stat -f '\''%d'\'' "$USER_TRIAL_PARENT")" ]] ||' \
        '            fail '\''failed-loopback fresh canonical publication cannot use one exclusive rename'\''' \
        '        local ready_identity' \
        '        ready_identity="$(/usr/bin/stat -f '\''%d:%i'\'' "$USER_STAGE_READY_ROOT")"' \
        '        /bin/sync' \
        '        classify_failed_loopback_user_state' \
        '        [[ "$USER_RETRY_STATE" == '\''E1'\'' ]] ||' \
        '        require_launcher_lock_held' \
        '        /bin/mv -n "$USER_STAGE_READY_ROOT" "$TRIAL_ROOT"' \
        '        [[ ! -e "$USER_STAGE_READY_ROOT" && ! -L "$USER_STAGE_READY_ROOT" &&' \
        '           "$(/usr/bin/stat -f '\''%d:%i'\'' "$TRIAL_ROOT")" == "$ready_identity" ]] ||' \
        '            fail '\''failed-loopback fresh canonical publication was not inode-preserving'\''' \
        '        [[ "$USER_RETRY_STATE" == '\''E2'\'' ]] ||' \
        '        /bin/sync' \
        '        [[ "$USER_RETRY_STATE" == '\''E2'\'' ]] ||' || return 1
    text_has_ordered_tokens "$user_classifier_body" \
        '    require_data_volume_identity' \
        '    [[ ! -e "$ACTIVE_POINTER" && ! -L "$ACTIVE_POINTER" &&' \
        '       ! -e "$ACTIVE_POINTER_TEMP" && ! -L "$ACTIVE_POINTER_TEMP" &&' \
        '       ! -e "$PRODUCT_DRIVER" && ! -L "$PRODUCT_DRIVER" &&' \
        '       ! -e "$LEGACY_USER_STAGE_READY_ROOT" && ! -L "$LEGACY_USER_STAGE_READY_ROOT" ]] ||' \
        '        fail '\''failed-loopback user retry baseline changed'\''' \
        '    require_preserved_failed_uid_admission_user_evidence' \
        '    require_preserved_failed_candidate_user_evidence' \
        '    require_preserved_rescued_user_evidence' \
        '    local canonical_present=0 evidence_present=0 ready_present=0' \
        '    [[ -e "$TRIAL_ROOT" || -L "$TRIAL_ROOT" ]] && canonical_present=1' \
        '    [[ -e "$FAILED_LOOPBACK_TRIAL_ROOT" || -L "$FAILED_LOOPBACK_TRIAL_ROOT" ]] &&' \
        '        evidence_present=1' \
        '    [[ -e "$USER_STAGE_READY_ROOT" || -L "$USER_STAGE_READY_ROOT" ]] && ready_present=1' \
        '    if (( canonical_present == 1 && evidence_present == 0 )); then' \
        '        require_failed_loopback_user_trial_at "$TRIAL_ROOT"' \
        '        if (( ready_present == 1 )); then' \
        '            require_complete_pre_root_user_stage_at "$USER_STAGE_READY_ROOT"' \
        '        USER_RETRY_STATE='\''E0'\''' \
        '    elif (( canonical_present == 0 && evidence_present == 1 && ready_present == 1 )); then' \
        '        require_failed_loopback_user_trial_at "$FAILED_LOOPBACK_TRIAL_ROOT"' \
        '        require_complete_pre_root_user_stage_at "$USER_STAGE_READY_ROOT"' \
        '        USER_RETRY_STATE='\''E1'\''' \
        '    elif (( canonical_present == 1 && evidence_present == 1 && ready_present == 0 )); then' \
        '        require_failed_loopback_user_trial_at "$FAILED_LOOPBACK_TRIAL_ROOT"' \
        '        require_complete_pre_root_user_stage_at "$TRIAL_ROOT"' \
        '        USER_RETRY_STATE='\''E2'\''' \
        '        fail '\''failed-loopback user retry state is not exact E0, E1, or E2'\''' || return 1
    text_has_ordered_tokens "$composite_body" \
        '    classify_failed_loopback_user_state' \
        '    classify_failed_loopback_root_state' \
        '        E0/R0|E1/R0|E2/R0|E2/R1|E2/R2|E2/R3)' \
        '            RETRY_STATE="$USER_RETRY_STATE/$ROOT_RETRY_STATE"' \
        '        *)' \
        '            fail '\''failed-loopback composite retry state is outside the E0-E2/R0-R3 lattice'\''' \
        '    esac'
}

launcher_failed_loopback_root_lattice_contract_is_closed() {
    local launcher_text="$1"
    local classifier_body prior_body partial_body fresh_body
    classifier_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^classify_failed_loopback_root_state() {$/,/^}$/p')
    prior_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^require_prior_root_evidence_public() {$/,/^}$/p')
    partial_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^require_public_safe_partial_fresh_root_shell() {$/,/^}$/p')
    fresh_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^require_public_fresh_root_shell_at() {$/,/^}$/p')
    [[ "$(print -rn -- "$classifier_body" | /usr/bin/grep -E -c \
            '/bin/(rm|rmdir|mv|install|chmod|chown|mkdir)([[:space:]]|$)' || true)" == '0' &&
       "$(print -rn -- "$classifier_body" | /usr/bin/grep -F -x -c \
            '    require_data_volume_identity')" == '1' &&
       "$(print -rn -- "$classifier_body" | /usr/bin/grep -F -x -c \
            '            ROOT_RETRY_STATE='\''R0'\''')" == '1' &&
       "$(print -rn -- "$classifier_body" | /usr/bin/grep -F -x -c \
            '            ROOT_RETRY_STATE='\''R1'\''')" == '1' &&
       "$(print -rn -- "$classifier_body" | /usr/bin/grep -F -x -c \
            '        ROOT_RETRY_STATE='\''R2'\''')" == '1' &&
       "$(print -rn -- "$classifier_body" | /usr/bin/grep -F -x -c \
            '        ROOT_RETRY_STATE='\''R3'\''')" == '1' &&
       "$(print -rn -- "$classifier_body" | /usr/bin/grep -F -x -c \
            '            require_public_fresh_root_shell_at "$FRESH_ROOT_SUPPORT"')" == '1' &&
       "$(print -rn -- "$classifier_body" | /usr/bin/grep -F -x -c \
            '        require_public_fresh_root_shell_at "$FRESH_ROOT_SUPPORT"')" == '1' &&
       "$(print -rn -- "$classifier_body" | /usr/bin/grep -F -x -c \
            '        fail '\''failed-loopback root retry state is not exact R0, R1, R2, or R3'\''')" == '1' &&
       "$(print -rn -- "$prior_body" | /usr/bin/grep -F -x -c \
            '    require_public_d1_root_shell_at "$FAILED_COREAUDIO_ROOT_SUPPORT"')" == '1' &&
       "$(print -rn -- "$partial_body" | /usr/bin/grep -F -x -c \
            '        [[ "$entry_status" == '\''1'\'' && -z "$unexpected" ]] ||')" == '1' &&
       "$(print -rn -- "$fresh_body" | /usr/bin/grep -F -x -c \
            '           "${DATA_VOLUME_DEVICE}:0:0:5:711:160:0" &&')" == '1' ]] || return 1
    text_has_ordered_tokens "$classifier_body" \
        '    require_data_volume_identity' \
        '    require_prior_root_evidence_public' \
        '    [[ ! -e "$LEGACY_FRESH_ROOT_SUPPORT" && ! -L "$LEGACY_FRESH_ROOT_SUPPORT" ]] ||' \
        '        fail '\''legacy root fresh-stage path unexpectedly reappeared'\''' \
        '    local canonical_present=0 evidence_present=0 fresh_present=0' \
        '    [[ -e "$ROOT_SUPPORT" || -L "$ROOT_SUPPORT" ]] && canonical_present=1' \
        '    [[ -e "$FAILED_LOOPBACK_ROOT_SUPPORT" || -L "$FAILED_LOOPBACK_ROOT_SUPPORT" ]] &&' \
        '        evidence_present=1' \
        '    [[ -e "$FRESH_ROOT_SUPPORT" || -L "$FRESH_ROOT_SUPPORT" ]] && fresh_present=1' \
        '    if (( canonical_present == 1 && evidence_present == 0 )); then' \
        '        require_public_failed_loopback_root_shell_at "$ROOT_SUPPORT"' \
        '        require_public_safe_partial_fresh_root_shell' \
        '        if (( fresh_present == 1 )) &&' \
        '              -f "$FRESH_ROOT_SUPPORT/root-broker.log" &&' \
        '            require_public_fresh_root_shell_at "$FRESH_ROOT_SUPPORT"' \
        '            ROOT_RETRY_STATE='\''R1'\''' \
        '            ROOT_RETRY_STATE='\''R0'\''' \
        '    elif (( canonical_present == 0 && evidence_present == 1 && fresh_present == 1 )); then' \
        '        require_public_failed_loopback_root_shell_at "$FAILED_LOOPBACK_ROOT_SUPPORT"' \
        '        require_public_fresh_root_shell_at "$FRESH_ROOT_SUPPORT"' \
        '        ROOT_RETRY_STATE='\''R2'\''' \
        '    elif (( canonical_present == 1 && evidence_present == 1 && fresh_present == 0 )); then' \
        '        require_public_failed_loopback_root_shell_at "$FAILED_LOOPBACK_ROOT_SUPPORT"' \
        '        require_public_fresh_root_shell_at "$ROOT_SUPPORT"' \
        '        ROOT_RETRY_STATE='\''R3'\''' \
        '        fail '\''failed-loopback root retry state is not exact R0, R1, R2, or R3'\''' || return 1
    text_has_ordered_tokens "$partial_body" \
        '    if [[ ! -e "$FRESH_ROOT_SUPPORT" && ! -L "$FRESH_ROOT_SUPPORT" ]]; then' \
        '        return' \
        '    [[ -d "$FRESH_ROOT_SUPPORT" && ! -L "$FRESH_ROOT_SUPPORT" ]]' \
        '    entries=$(/usr/bin/find "$FRESH_ROOT_SUPPORT" -xdev -mindepth 1 -maxdepth 1 -print)' \
        '        unexpected=$(print -r -- "$entries" | /usr/bin/grep -F -v -x \' \
        '            -e "$controller" -e "$pin" -e "$log")' \
        '        [[ "$entry_status" == '\''1'\'' && -z "$unexpected" ]] ||' \
        '    require_retry_tree_closed "$FRESH_ROOT_SUPPORT"' || return 1
    text_has_ordered_tokens "$fresh_body" \
        '           "${DATA_VOLUME_DEVICE}:0:0:5:711:160:0" &&' \
        '    require_hash "$controller" "$EXPECTED_CONTROLLER_BINARY_SHA256"' \
        '    [[ "$(/bin/cat "$pin")" == "$EXPECTED_CONTROLLER_BINARY_SHA256" &&' \
        '       ! -s "$log" ]]' \
        '    require_retry_tree_closed "$support_path"'
}

launcher_singleton_lock_parts_are_closed() {
    local header_text="$1"
    local acquire_body="$2"
    local held_body="$3"
    local stage_body="$4"
    local advance_body="$5"
    local bootstrap_body="$6"
    local runtime_tail="$7"
    [[ "$header_text" == *"readonly LAUNCHER_LOCK='/Users/ahmed/Library/Application Support/opensteamer/.local-mono-trial-launcher.lock'"* &&
       "$header_text" == *'typeset -gi LAUNCHER_LOCK_FD=-1'* &&
       "$header_text" == *'typeset -gi LAUNCHER_LOCK_ACQUIRED=0'* &&
       "$(print -rn -- "$acquire_body" | /usr/bin/grep -F -x -c \
            '    zsystem flock -t 0 -f LAUNCHER_LOCK_FD "$LAUNCHER_LOCK" 2>/dev/null')" == '1' &&
       "$(print -rn -- "$acquire_body" | /usr/bin/grep -F -c 'zsystem flock -e' || true)" == '0' &&
       "$(print -rn -- "$held_body" | /usr/bin/grep -F -x -c \
            '                zsystem flock -u "$probe_fd"')" == '1' &&
       "$(print -rn -- "$held_body" | /usr/bin/grep -F -c \
            'probe_result == 2')" == '1' &&
       "$(print -rn -- "$held_body" | /usr/bin/grep -F -x -c \
            '    zmodload -F zsh/stat b:zstat || fail '\''zsh in-process fstat support is unavailable'\''')" == '1' &&
       "$(print -rn -- "$held_body" | /usr/bin/grep -F -c \
            'zstat -H descriptor_stat -f "$LAUNCHER_LOCK_FD"')" == '2' &&
       "$(print -rn -- "$held_body" | /usr/bin/grep -F -c \
            'zstat -H named_stat "$LAUNCHER_LOCK"')" == '2' &&
       "$(print -rn -- "$held_body" | /usr/bin/grep -F -c '/dev/fd/' || true)" == '0' &&
       "$(print -rn -- "$acquire_body$held_body$stage_body$advance_body$bootstrap_body$runtime_tail" | \
            /usr/bin/grep -F -c 'zsystem flock -u "$LAUNCHER_LOCK_FD"' || true)" == '0' &&
       "$(print -rn -- "$stage_body" | /usr/bin/grep -F -x -c \
            '    require_launcher_lock_held')" == '2' &&
       "$(print -rn -- "$stage_body" | /usr/bin/grep -F -x -c \
            '        require_launcher_lock_held')" == '1' &&
       "$stage_body" == *$'        require_launcher_lock_held\n        /bin/mv -n "$publish_root" "$USER_STAGE_READY_ROOT"'* &&
       "$(print -rn -- "$advance_body" | /usr/bin/grep -F -x -c \
            '    require_launcher_lock_held')" == '1' &&
       "$(print -rn -- "$advance_body" | /usr/bin/grep -F -x -c \
            '        require_launcher_lock_held')" == '2' &&
       "$advance_body" == *$'        require_launcher_lock_held\n        /bin/mv -n "$TRIAL_ROOT" "$FAILED_LOOPBACK_TRIAL_ROOT"'* &&
       "$advance_body" == *$'        require_launcher_lock_held\n        /bin/mv -n "$USER_STAGE_READY_ROOT" "$TRIAL_ROOT"'* &&
       "$(print -rn -- "$bootstrap_body" | /usr/bin/grep -F -x -c \
            '    require_launcher_lock_held')" == '2' ]] || return 1
    text_has_ordered_tokens "$acquire_body" \
        $'    [[ "$MODE" == "$START_MODE" || "$MODE" == "$STOP_MODE" ||\n       "$MODE" == "$CAPTURE_MODE" ]]' \
        '        ( setopt localoptions noclobber; : > "$LAUNCHER_LOCK" ) 2>/dev/null' \
        '    require_launcher_lock_node' \
        '    zmodload -F zsh/system b:zsystem' \
        '    zsystem flock -t 0 -f LAUNCHER_LOCK_FD "$LAUNCHER_LOCK" 2>/dev/null' \
        '    [[ "$acquire_lock_result" == '\''0'\'' ]]' \
        '    LAUNCHER_LOCK_ACQUIRED=1' \
        '    require_launcher_lock_held' || return 1
    text_has_ordered_tokens "$held_body" \
        '    (( LAUNCHER_LOCK_ACQUIRED == 1 && LAUNCHER_LOCK_FD >= 0 ))' \
        '    require_launcher_lock_node' \
        '    zmodload -F zsh/stat b:zstat' \
        '    zstat -H descriptor_stat -f "$LAUNCHER_LOCK_FD"' \
        '    zstat -H named_stat "$LAUNCHER_LOCK"' \
        '        fail '\''live-launcher lock descriptor no longer names the canonical inode'\''' \
        '            zsystem flock -t 0.02 -i 0.005 -f probe_fd "$1" 2>/dev/null' \
        '            if (( probe_result == 2 )); then' \
        '    [[ "$exclusion_probe_result" == '\''0'\'' ]]' \
        '    require_launcher_lock_node' \
        '    zstat -H descriptor_stat -f "$LAUNCHER_LOCK_FD"' \
        '    zstat -H named_stat "$LAUNCHER_LOCK"' \
        '        fail '\''live-launcher lock inode changed during exclusion proof'\''' || return 1
    text_has_ordered_tokens "$bootstrap_body" \
        '    require_launcher_lock_held' \
        '    classify_retry_state' \
        '    AUTHORIZATION_ATTEMPTED=1' \
        '            /usr/bin/osascript - "$ROOT_BOOTSTRAP_COMMAND" <<'\''APPLESCRIPT'\''' \
        '    require_launcher_lock_held' || return 1
    text_has_ordered_tokens "$runtime_tail" \
        'if [[ "$MODE" == "$START_MODE" || "$MODE" == "$STOP_MODE" ]]; then' \
        '    acquire_launcher_lock' \
        $'fi\ncd "$EXPECTED_REPO"\ncase "$MODE" in' \
        '    "$START_MODE")' \
        '        classify_retry_state' \
        '        advance_failed_loopback_user_state' \
        '        classify_retry_state' \
        '        [[ "$USER_RETRY_STATE" == '\''E2'\'' ]] ||' \
        '        bootstrap_root_broker_once' \
        '        require_launcher_lock_held' \
        '            "$USER_CONTROLLER_STAGE" "$START_MODE"' \
        '    "$STOP_MODE")' \
        '        require_launcher_lock_held' \
        '            "$CONTROLLER" "$STOP_MODE"'
}

launcher_singleton_lock_contract_is_closed() {
    local launcher_text="$1"
    local header_text acquire_body held_body stage_body advance_body bootstrap_body runtime_tail
    header_text="${launcher_text%%readonly ROOT_BOOTSTRAP_COMMAND=*}"
    acquire_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^acquire_launcher_lock() {$/,/^}$/p')
    held_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^require_launcher_lock_held() {$/,/^}$/p')
    stage_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^stage_live_one_shot() {$/,/^}$/p')
    advance_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^advance_failed_loopback_user_state() {$/,/^}$/p')
    bootstrap_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^bootstrap_root_broker_once() {$/,/^}$/p')
    runtime_tail=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^readonly BUILD_ROOT=/,$p')
    launcher_singleton_lock_parts_are_closed "$header_text" "$acquire_body" "$held_body" \
        "$stage_body" "$advance_body" "$bootstrap_body" "$runtime_tail"
}

root_phase_lease_interleaving_is_safe() {
    local phase="$1"
    local wrapper_holds="$2"
    local inner_holds="$3"
    local supervisor_holds="$4"
    local broker_blocked_holds="$5"
    local broker_visible="$6"
    case "$phase" in
        prepare)
            (( wrapper_holds == 1 || inner_holds == 1 ))
            ;;
        broker_pre_ack)
            (( wrapper_holds == 1 || supervisor_holds == 1 ||
               broker_blocked_holds == 1 ))
            ;;
        broker_post_ack)
            (( wrapper_holds == 1 || supervisor_holds == 1 ||
               broker_visible == 1 ))
            ;;
        terminal)
            (( broker_visible == 1 ))
            ;;
        *)
            return 1
            ;;
    esac
}

root_phase_reaped_pipe_loses_signal_authority() {
    /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        /usr/bin/perl -MPOSIX -e '
            my $child_pid = open(my $pipe, "-|", "/usr/bin/true");
            defined($child_pid) && $child_pid > 1 or exit 70;
            local $/;
            my $output = <$pipe>;
            close($pipe) or exit 71;
            my $post_close = waitpid($child_pid, POSIX::WNOHANG());
            exit($post_close == -1 ? 0 : 72);
        '
}

launcher_guardian_toolchain_resolution_contract_is_closed() {
    local launcher_text="$1"
    local header_text helper_body guardian_toolchain_body
    header_text="${launcher_text%%readonly ROOT_BOOTSTRAP_COMMAND=*}"
    helper_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^swiftc_resolution_is_valid() {$/,/^}$/p')
    guardian_toolchain_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^require_guardian_toolchain() {$/,/^require_guardian_maximum_contract() {$/p' | \
        /usr/bin/sed '$d')
    [[ "$header_text" == *"readonly PINNED_DEVELOPER_DIR='/Applications/Xcode-26.6.0.app/Contents/Developer'"* &&
       "$header_text" == *"readonly PINNED_RESOLVED_DEVELOPER_DIR='/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app/Contents/Developer'"* &&
       "$header_text" == *'readonly PINNED_XCRUN_SWIFTC="$PINNED_RESOLVED_DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"'* &&
       "$(print -rn -- "$helper_body" | /usr/bin/grep -F -x -c \
            '       "$observed_swiftc" == "$PINNED_XCRUN_SWIFTC" ]]')" == '1' &&
       "$(print -rn -- "$helper_body" | /usr/bin/grep -F -c \
            'PINNED_SWIFTC' || true)" == '0' ]] || return 1
    text_has_ordered_tokens "$guardian_toolchain_body" \
        '    [[ -d "$PINNED_DEVELOPER_DIR" && ! -L "$PINNED_DEVELOPER_DIR" ]] ||' \
        '    [[ -L "$PINNED_SWIFTC" && "$(/usr/bin/readlink "$PINNED_SWIFTC")" == '\''swift-frontend'\'' ]] ||' \
        '    require_hash "$PINNED_SWIFT_FRONTEND" "$EXPECTED_SWIFT_FRONTEND_SHA256"' \
        '    require_hash "$PINNED_CLANG" "$EXPECTED_CLANG_SHA256"' \
        '    resolved_developer_dir="${PINNED_DEVELOPER_DIR:A}"' \
        '            /usr/bin/xcrun --sdk macosx --find swiftc' \
        '    swiftc_resolution_is_valid "$resolved_developer_dir" "$observed_swiftc" ||' \
        '        DEVELOPER_DIR="$PINNED_DEVELOPER_DIR" /usr/bin/xcrun --sdk macosx swiftc --version 2>&1)' \
        '       "$EXPECTED_SWIFTC_VERSION" ]] ||' || return 1
    swiftc_resolution_is_valid "$PINNED_RESOLVED_DEVELOPER_DIR" \
        "$PINNED_XCRUN_SWIFTC" || return 1
    ! swiftc_resolution_is_valid "$PINNED_RESOLVED_DEVELOPER_DIR" \
        "$PINNED_SWIFTC" || return 1
    ! swiftc_resolution_is_valid '/Volumes/Wrong/Xcode.app/Contents/Developer' \
        "$PINNED_XCRUN_SWIFTC" || return 1
}

launcher_data_volume_contract_is_closed() {
    local launcher_text="$1"
    local root_payload="$2"
    local capture_payload="$3"
    local header_text public_identity_body public_toolchain_body envelope_body
    local user_classifier_body root_classifier_body runtime_tail root_wrapper root_inner
    header_text="${launcher_text%%readonly ROOT_BOOTSTRAP_COMMAND=*}"
    public_identity_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^data_volume_binding_is_valid() {$/,/^require_reviewed_source() {$/p' | \
        /usr/bin/sed '$d')
    public_toolchain_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^require_toolchain() {$/,/^require_guardian_toolchain() {$/p' | /usr/bin/sed '$d')
    envelope_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^require_root_capture_envelope_file() {$/,/^resume_root_capture_publication() {$/p' | \
        /usr/bin/sed '$d')
    user_classifier_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^classify_failed_loopback_user_state() {$/,/^advance_failed_loopback_user_state() {$/p' | \
        /usr/bin/sed '$d')
    root_classifier_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^classify_failed_loopback_root_state() {$/,/^require_prior_root_evidence_public() {$/p' | \
        /usr/bin/sed '$d')
    runtime_tail=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^\[\[ "$#" == '\''1'\'' \]\] || usage$/,$p')
    [[ "$root_payload" == *$'__DATA__\n'* ]] || return 1
    root_wrapper="${root_payload%%$'__DATA__\n'*}"
    root_inner="${root_payload#*$'__DATA__\n'}"
    root_inner="${root_inner%$'\nOPENSTEAMER_ROOT_WRAPPER_L1CIAB'}"

    [[ "$header_text" == *"readonly DATA_VOLUME_MOUNT='/System/Volumes/Data'"* &&
       "$header_text" == *"readonly EXPECTED_DATA_VOLUME_UUID='AF638805-E0CB-4356-941F-16B84DFB6435'"* &&
       "$header_text" == *"readonly EXPECTED_DATA_VOLUME_GROUP_UUID='AF638805-E0CB-4356-941F-16B84DFB6435'"* &&
       "$header_text" == *"readonly DISKUTIL='/usr/sbin/diskutil'"* &&
       "$header_text" == *"readonly PLUTIL='/usr/bin/plutil'"* &&
       "$header_text" == *"readonly EXPECTED_DISKUTIL_STAT='1152921500312576001:0:0:1:755:1943344:524320'"* &&
       "$header_text" == *"readonly EXPECTED_DISKUTIL_SHA256='9299ccac6acdf493796a88979d14ff464c1ec2196b167c879f023c2dbe9f3049'"* &&
       "$header_text" == *"readonly EXPECTED_PLUTIL_STAT='1152921500312572590:0:0:1:755:663776:524320'"* &&
       "$header_text" == *"readonly EXPECTED_PLUTIL_SHA256='983854d7c73e0bcdb6d50314e900e5d0a1313888727f8a69987c0c709e991c14'"* &&
       "$header_text" == *"readonly EXPECTED_ROOT_WRAPPER_PERL_STAT='1152921500312572547:0:0:1:755:101840:524320'"* &&
       "$header_text" == *"typeset -g DATA_VOLUME_DEVICE=''"* &&
       "$header_text" != *'EXPECTED_ROOT_DEVICE'* &&
       "$(print -rn -- "$launcher_text" | /usr/bin/grep -E -c \
            '167772(29|30):' || true)" == '0' &&
       "$(print -rn -- "$root_payload" | /usr/bin/grep -F -c \
            'device=16777230')" == '1' ]] || return 1

    text_has_ordered_tokens "$public_identity_body" \
        'data_volume_binding_is_valid() {' \
        '       "$device_before" == <-> && "$device_before" -gt 0 &&' \
        'require_data_volume_identity() {' \
        '    require_hash "$DISKUTIL" "$EXPECTED_DISKUTIL_SHA256"' \
        '    require_hash "$PLUTIL" "$EXPECTED_PLUTIL_SHA256"' \
        '    /usr/bin/codesign --verify --strict "$DISKUTIL" "$PLUTIL" ||' \
        '    mount_before="$(/usr/bin/stat -f '\''%d:%i:%u:%g:%Lp:%f'\'' "$DATA_VOLUME_MOUNT")"' \
        '            "$DISKUTIL" info -plist "$DATA_VOLUME_MOUNT"' \
        '    volume_uuid="$(data_volume_plist_value "$volume_plist" VolumeUUID)" ||' \
        '    volume_group_uuid="$(data_volume_plist_value "$volume_plist" APFSVolumeGroupID)" ||' \
        '    mount_point="$(data_volume_plist_value "$volume_plist" MountPoint)" ||' \
        '    mount_after="$(/usr/bin/stat -f '\''%d:%i:%u:%g:%Lp:%f'\'' "$DATA_VOLUME_MOUNT")"' \
        '    [[ "$mount_after" == "$mount_before" ]] ||' \
        '    data_volume_binding_is_valid "$volume_uuid" "$volume_group_uuid" "$mount_point" \' \
        '    for anchor in / /Users /Library '\''/Library/Application Support'\'' \' \
        '    for observer in "$DISKUTIL" "$PLUTIL"; do' \
        '    DATA_VOLUME_DEVICE="$device_before"' || return 1
    text_has_ordered_tokens "$public_toolchain_body" \
        '       "$(/usr/bin/stat -f '\''%d'\'' /usr/bin/perl)" == "$DATA_VOLUME_DEVICE" &&' \
        '           "$EXPECTED_ROOT_WRAPPER_PERL_STAT"' \
        '    require_hash /usr/bin/perl "$EXPECTED_ROOT_WRAPPER_PERL_SHA256"' || return 1
    [[ "$(print -rn -- "$user_classifier_body" | /usr/bin/grep -F -x -c \
            '    require_data_volume_identity')" == '1' &&
       "$(print -rn -- "$root_classifier_body" | /usr/bin/grep -F -x -c \
            '    require_data_volume_identity')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -x -c \
            '    require_data_volume_identity')" == '1' ]] || return 1
    text_has_ordered_tokens "$runtime_tail" \
        'require_launcher_identity' \
        'require_data_volume_identity' \
        'require_retry_preservation_contract' || return 1

    [[ "$(print -rn -- "$root_wrapper" | /usr/bin/grep -F -x -c \
            'my $diskutil_path = "/usr/sbin/diskutil";')" == '1' &&
       "$(print -rn -- "$root_wrapper" | /usr/bin/grep -F -x -c \
            '    "9299ccac6acdf493796a88979d14ff464c1ec2196b167c879f023c2dbe9f3049" or exit 78;')" == '1' &&
       "$(print -rn -- "$root_wrapper" | /usr/bin/grep -F -x -c \
            '        "AF638805-E0CB-4356-941F-16B84DFB6435" &&')" == '2' &&
       "$(print -rn -- "$root_wrapper" | /usr/bin/grep -F -x -c \
            '    exact_plist_string($volume_plist, "MountPoint") eq "/System/Volumes/Data" &&')" == '1' ]] ||
        return 1
    text_has_ordered_tokens "$root_wrapper" \
        'my @data_stat = lstat("/System/Volumes/Data");' \
        'sysopen(my $diskutil_file, $diskutil_path, 0x100) or exit 78;' \
        'sha256_hex($diskutil_bytes) eq' \
        'my $volume_plist = bounded_command_output(' \
        '    time() + 5, $diskutil_path, "info", "-plist", "/System/Volumes/Data");' \
        '    exact_plist_string($volume_plist, "VolumeUUID") eq' \
        '    exact_plist_string($volume_plist, "APFSVolumeGroupID") eq' \
        '    exact_plist_string($volume_plist, "MountPoint") eq "/System/Volumes/Data" &&' \
        'my @data_after = lstat("/System/Volumes/Data");' \
        'sysopen(my $lease, $lock_path, 0x300, 0600) or exit 79;' || return 1

    [[ "$(print -rn -- "$root_inner" | /usr/bin/grep -F -x -c \
            'trial_data_mount="/System/Volumes/Data"')" == '1' &&
       "$(print -rn -- "$root_inner" | /usr/bin/grep -F -x -c \
            'trial_data_uuid="AF638805-E0CB-4356-941F-16B84DFB6435"')" == '1' &&
       "$(print -rn -- "$root_inner" | /usr/bin/grep -F -x -c \
            'trial_data_group_uuid="AF638805-E0CB-4356-941F-16B84DFB6435"')" == '1' &&
       "$(print -rn -- "$root_inner" | /usr/bin/grep -F -x -c \
            '    require_data_volume_identity')" -ge '1' ]] || return 1
    text_has_ordered_tokens "$root_inner" \
        '    trial_mount_before=$(/usr/bin/stat -f "%d:%i:%u:%g:%Lp:%f" "$trial_data_mount")' \
        '    [ "$(/usr/bin/stat -f "%d" "$trial_diskutil")" = "$trial_device_before" ]' \
        '    [ "$(/usr/bin/shasum -a 256 "$trial_diskutil" | /usr/bin/cut -d " " -f 1)" = \' \
        '    [ "$(/usr/bin/stat -f "%d" "$trial_plutil")" = "$trial_device_before" ]' \
        '    [ "$(/usr/bin/shasum -a 256 "$trial_plutil" | /usr/bin/cut -d " " -f 1)" = \' \
        '    /usr/bin/codesign --verify --strict "$trial_plutil"' \
        '    trial_volume_plist=$(/usr/sbin/diskutil info -plist "$trial_data_mount")' \
        '    [ "$(data_volume_plist_value "$trial_volume_plist" VolumeUUID)" = "$trial_data_uuid" ]' \
        '    trial_mount_after=$(/usr/bin/stat -f "%d:%i:%u:%g:%Lp:%f" "$trial_data_mount")' \
        '    [ "$trial_mount_after" = "$trial_mount_before" ]' \
        '    trial_data_device=${trial_mount_after%%:*}' \
        '    for trial_data_anchor in / /Users /Library "/Library/Application Support" \' \
        'require_root_phase_lease_held() {' \
        '    require_data_volume_identity' || return 1

    text_has_ordered_tokens "$capture_payload" \
        'my $data_volume_mount = "/System/Volumes/Data";' \
        'my $expected_data_volume_uuid = "AF638805-E0CB-4356-941F-16B84DFB6435";' \
        'my $expected_data_volume_group_uuid = "AF638805-E0CB-4356-941F-16B84DFB6435";' \
        'my $data_device = $initial_data_volume_stat[0];' \
        'my $root_device = $data_device;' \
        'sub require_data_volume_identity {' \
        '    $volume_uuid eq $expected_data_volume_uuid &&' \
        '    my @after = lstat($data_volume_mount);' \
        '    my $data_volume_observation = require_data_volume_identity();' \
        '        "root_device=$root_device\n" .' || return 1

    local device_before_reboot='41001'
    local device_after_reboot='41002'
    data_volume_binding_is_valid "$EXPECTED_DATA_VOLUME_UUID" \
        "$EXPECTED_DATA_VOLUME_GROUP_UUID" "$DATA_VOLUME_MOUNT" apfs true \
        "$device_before_reboot" "$device_before_reboot" || return 1
    data_volume_binding_is_valid "$EXPECTED_DATA_VOLUME_UUID" \
        "$EXPECTED_DATA_VOLUME_GROUP_UUID" "$DATA_VOLUME_MOUNT" apfs true \
        "$device_after_reboot" "$device_after_reboot" || return 1
    ! data_volume_binding_is_valid "$EXPECTED_DATA_VOLUME_UUID" \
        "$EXPECTED_DATA_VOLUME_GROUP_UUID" "$DATA_VOLUME_MOUNT" apfs true \
        "$device_before_reboot" "$device_after_reboot" || return 1
    ! data_volume_binding_is_valid '00000000-0000-0000-0000-000000000000' \
        "$EXPECTED_DATA_VOLUME_GROUP_UUID" "$DATA_VOLUME_MOUNT" apfs true \
        "$device_after_reboot" "$device_after_reboot" || return 1
    ! data_volume_binding_is_valid "$EXPECTED_DATA_VOLUME_UUID" \
        "$EXPECTED_DATA_VOLUME_GROUP_UUID" '/System/Volumes/Wrong' apfs true \
        "$device_after_reboot" "$device_after_reboot" || return 1
}

root_phase_lease_contract_is_closed() {
    local payload_text="$1"
    local wrapper_text inner_text prepare_fresh_body
    [[ "$payload_text" == *$'__DATA__\n'* &&
       "$payload_text" == *$'\nOPENSTEAMER_ROOT_WRAPPER_L1CIAB' ]] || return 1
    wrapper_text="${payload_text%%$'__DATA__\n'*}"
    inner_text="${payload_text#*$'__DATA__\n'}"
    inner_text="${inner_text%$'\nOPENSTEAMER_ROOT_WRAPPER_L1CIAB'}"
    prepare_fresh_body=$(print -rn -- "$inner_text" | /usr/bin/sed -n \
        '/^prepare_fresh_root_support() {$/,/^}$/p')
    [[ "$wrapper_text" == 'exec /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/var/root USER=root LOGNAME=root /usr/bin/perl - "/Library/Application Support/opensteamer-local-mono-trial-root-bootstrap-L1Ciab.lock" "/Library/Application Support/opensteamer-local-mono-trial-v1/opensteamer-local-mono-trial-controller" "/Library/Application Support/opensteamer-local-mono-trial-v1/root-broker.log" <<\OPENSTEAMER_ROOT_WRAPPER_L1CIAB'* &&
       "$(print -rn -- "$wrapper_text" | /usr/bin/grep -F -x -c \
            'sysopen(my $lease, $lock_path, 0x300, 0600) or exit 79;')" == '1' &&
       "$(print -rn -- "$wrapper_text" | /usr/bin/grep -F -x -c \
            'sysopen(my $diskutil_file, $diskutil_path, 0x100) or exit 78;')" == '1' &&
       "$(print -rn -- "$wrapper_text" | /usr/bin/grep -F -x -c \
            '    exact_plist_string($volume_plist, "MountPoint") eq "/System/Volumes/Data" &&')" == '1' &&
       "$(print -rn -- "$wrapper_text" | /usr/bin/grep -F -x -c \
            'flock($lease, 6) or exit 75;')" == '1' &&
       "$(print -rn -- "$wrapper_text" | /usr/bin/grep -F -x -c \
            '    fcntl($lease, 2, 0) or exit 127;')" == '1' &&
       "$(print -rn -- "$wrapper_text" | /usr/bin/grep -F -x -c \
            '        close($lease);')" == '1' &&
       "$(print -rn -- "$wrapper_text" | /usr/bin/grep -F -c \
            'close($lease);')" == '1' &&
       "$(print -rn -- "$wrapper_text" | /usr/bin/grep -F -c \
            'while (1)' || true)" == '2' &&
       "$(print -rn -- "$wrapper_text" | /usr/bin/grep -F -x -c \
            'defined($inner_payload) && length($inner_payload) == 60624 &&')" == '1' &&
       "$(print -rn -- "$wrapper_text" | /usr/bin/grep -F -x -c \
            '    my $fallback_deadline = time() + 20;')" == '1' &&
       "$(print -rn -- "$wrapper_text" | /usr/bin/grep -F -x -c \
            '        my $wait_result = waitpid($command_pid, POSIX::WNOHANG());')" == '1' &&
       "$(print -rn -- "$wrapper_text" | /usr/bin/grep -F -c \
            'kill(-' || true)" == '0' &&
       "$(print -rn -- "$inner_text" | /usr/bin/grep -F -x -c \
            'require_root_phase_lease_held')" == '2' &&
       "$(print -rn -- "$inner_text" | /usr/bin/grep -F -x -c \
            '    require_root_phase_lease_held')" == '4' &&
       "$(print -rn -- "$inner_text" | /usr/bin/grep -F -x -c \
            '        require_root_phase_lease_held')" == '0' &&
       "$(print -rn -- "$inner_text" | /usr/bin/grep -F -c \
            'trial_root_pid' || true)" == '0' ]] || return 1
    text_has_ordered_tokens "$wrapper_text" \
        'my @data_stat = lstat("/System/Volumes/Data");' \
        'sysopen(my $diskutil_file, $diskutil_path, 0x100) or exit 78;' \
        'sha256_hex($diskutil_bytes) eq' \
        'my $volume_plist = bounded_command_output(' \
        '    exact_plist_string($volume_plist, "VolumeUUID") eq' \
        '    exact_plist_string($volume_plist, "APFSVolumeGroupID") eq' \
        '    exact_plist_string($volume_plist, "MountPoint") eq "/System/Volumes/Data" &&' \
        'my @data_after = lstat("/System/Volumes/Data");' \
        'sysopen(my $lease, $lock_path, 0x300, 0600) or exit 79;' \
        'lease_identity_is_exact($lease, $lock_path) or exit 79;' \
        'flock($lease, 6) or exit 75;' \
        'lease_identity_is_exact($lease, $lock_path) or exit 79;' \
        'sub bounded_command_output {' \
        '            alarm($remaining);' \
        '            my $command_ok = close($pipe);' \
        '            undef($command_pid);' \
        '            $command_ok or die "command failed\n";' \
        '        my $wait_result = waitpid($command_pid, POSIX::WNOHANG());' \
        '        if ($wait_result == 0) {' \
        '        kill(9, $command_pid);' \
        '        waitpid($command_pid, 0);' \
        '        undef($command_pid);' \
        'defined($inner_payload) && length($inner_payload) == 60624 &&' \
        '    index($inner_payload, "set -eu\numask 077\n") == 0 &&' \
        '    $inner_payload =~ /require_closed_root_tree \"\$trial_root_support\"\nrequire_root_phase_lease_held\n\z/' \
        'my $prepare = fork();' \
        '    fcntl($lease, 2, 0) or exit 127;' \
        '    $ENV{"OPENSTEAMER_ROOT_PHASE_LEASE_FD"} = "$lease_fd";' \
        '    open(STDIN, "<", "/dev/null") or exit 127;' \
        '    exec("/bin/sh", "-c", $inner_payload, "opensteamer-root-phase");' \
        'waitpid($prepare, 0) == $prepare or exit 70;' \
        'pipe(my $event_read, my $event_write) or exit 70;' \
        'my $supervisor = fork();' \
        '    pipe(my $go_read, my $go_write) or exit 70;' \
        '    my $broker = fork();' \
        '        my $go_count = sysread($go_read, $go, 1);' \
        '        exit 126 unless defined($go_count) && $go_count == 1 && $go eq "G";' \
        '        close($lease);' \
        '        exec({$controller} $controller, "--root-local-trial-broker");' \
        '    my $identity_deadline = time() + 5;' \
        '    my $broker_start = bounded_command_output(' \
        '    my $broker_initial_pgid = bounded_command_output(' \
        '    my $pid_message = "PID $broker|$broker_start|$broker_initial_pgid\n";' \
        '    my $ack_count = sysread($ack_read, $ack, 1);' \
        '    syswrite($go_write, "G") == 1 or exit 70;' \
        '    my $visibility_deadline = time() + 15;' \
        '    while (time() < $visibility_deadline) {' \
        '            my $start = bounded_command_output(' \
        '                if ($start eq $broker_start && $pgid eq "$broker" &&' \
        '    my $ready_message = "READY $broker\n";' \
        'my $pid_line = <$event_read>;' \
        'my $broker_start = $2;' \
        'my $broker_initial_pgid = $3;' \
        'syswrite($ack_write, "A") == 1 or exit 70;' \
        'my $ready_line = <$event_read>;' \
        'waitpid($supervisor, 0) == $supervisor or exit 70;' \
        'my $broker_accepted = defined($ready_line) &&' \
        'if (!$broker_accepted) {' \
        '    my $fallback_deadline = time() + 20;' \
        '    while (time() < $fallback_deadline) {' \
        '            my $start = bounded_command_output(' \
        '                if ($pgid eq "$broker_pid" && $uid eq "0" && $comm eq $controller) {' \
        'if (!$broker_accepted) {' \
        '    my $preexec_kill_sent = 0;' \
        '    my $terminal_absent_samples = 0;' \
        '    while (1) {' \
        '            exit 1 if $terminal_absent_samples == 2;' \
        '        my $resolution_deadline = time() + 5;' \
        '            exit 1 if $start ne $broker_start;' \
        '            exit 1 if $uid eq "0" &&' \
        '                ($pgid eq "$broker_pid" || $pgid eq $broker_initial_pgid) &&' \
        '                ($comm eq $controller || $comm eq "/usr/bin/perl") &&' \
        '                $state =~ /\AZ[+<NXLs]*\z/;' \
        '                $broker_accepted = 1;' \
        '                $pgid eq $broker_initial_pgid && $comm eq "/usr/bin/perl") {' \
        '                my $kill_result = kill(9, $broker_pid);' \
        '                $preexec_kill_sent = 1' \
        '$broker_accepted or exit 1;' \
        'print "$broker_pid\n";' || return 1
    text_has_ordered_tokens "$prepare_fresh_body" \
        'prepare_fresh_root_support() {' \
        '    require_root_phase_lease_held' \
        '    require_safe_partial_fresh_root_support' \
        '    /usr/bin/install -o root -g wheel -m 0500 "$trial_stage_controller" \' \
        '        "$trial_root_fresh_controller"' \
        '    require_fresh_root_support "$trial_root_fresh"' || return 1
    text_has_ordered_tokens "$inner_text" \
        $'require_root_phase_lease_held\nrequire_prior_root_evidence_boundaries\nrequire_prior_user_evidence_root\nrequire_u2_user_evidence_root\nrequire_u3_user_evidence_root\nrequire_fresh_user_stage_root' \
        $'if [ "$trial_quarantine_state" = "R0" ]; then\n    require_failed_loopback_preservation_boundary' \
        '    prepare_fresh_root_support' \
        $'if [ "$trial_quarantine_state" = "R1" ]; then\n    trial_failed_prepublication_identity=' \
        '    require_root_phase_lease_held' \
        '    /bin/mv -n "$trial_root_support" "$trial_root_evidence_fifth"' \
        $'if [ "$trial_quarantine_state" = "R2" ]; then\n    trial_fresh_prepublication_identity=' \
        '    require_root_phase_lease_held' \
        '    /bin/mv -n "$trial_root_fresh" "$trial_root_support"' \
        '[ "$trial_quarantine_state" = "R3" ]' \
        'require_failed_loopback_preservation_boundary' \
        'require_closed_root_tree "$trial_root_support"' \
        'require_root_phase_lease_held'
}

root_capture_payload_contract_is_closed() {
    local payload_text="$1"
    local payload_sha256
    payload_sha256=$(print -rn -- "$payload_text" |
        /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}') || return 1
    [[ "$payload_sha256" == "$EXPECTED_ROOT_CAPTURE_COMMAND_SHA256" &&
       "$payload_text" == 'exec /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/var/root USER=root LOGNAME=root /usr/bin/perl - <<\OPENSTEAMER_ROOT_CAPTURE_L1CIAB'* &&
       "$payload_text" == *$'\nOPENSTEAMER_ROOT_CAPTURE_L1CIAB' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            'sysopen(my $lease, $lease_path, O_RDONLY | 0x100)')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            'fcntl($lease, F_SETFD, FD_CLOEXEC) or die "capture lease CLOEXEC failed\n";')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            'flock($lease, 6) or die "capture lease is busy\n";')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            '    my $child = fork();')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            '            open(STDIN, "<", "/dev/null") or exit 249;')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            '            exec({$command[0]} @command);')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            '        $waited = waitpid($child, 0);')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -c \
            'synchronous_capture(')" == '8' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -c \
            'observation_record(')" == '8' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            'my $first = capture_pass();')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            'my $second = capture_pass();')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            'require_exact_lease($lease);')" == '4' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            'print STDOUT $transport or die "capture stdout failed\n";')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            'close(STDOUT) or die "capture stdout close failed\n";')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c 'exit 0;')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -E -c \
            'O_WRONLY|O_RDWR|O_CREAT|0x300|syswrite|(^|[^[:alnum:]_])(unlink|rename|link|mkdir|rmdir|chmod|chown|truncate|kill|system)[[:space:]]*\(' || true)" == '0' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -E -c \
            'alarm\(|flock\([^,]+,[[:space:]]*8\)|close\(\$lease\)|`|qx[(/]|/bin/(sh|zsh)' || true)" == '0' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -c \
            '"/usr/bin/stat" =>')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -c \
            '"/usr/bin/xattr" =>')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            '        my $socket_path = "$root/broker-prep-L1Ciab.sock";')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            '            (@command == 2 && $command[1] eq $socket_path);')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -c \
            '"/bin/ls" =>')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -c \
            '"/usr/sbin/lsof" =>')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -c \
            '"/usr/bin/codesign" =>')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -c \
            '"/usr/sbin/diskutil" =>')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            '        length($bytes) + $count <= 2_097_152 or die "capture helper exceeded bound\n";')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            'my $data_volume_mount = "/System/Volumes/Data";')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            'my $expected_data_volume_uuid = "AF638805-E0CB-4356-941F-16B84DFB6435";')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            'my $root_device = $data_device;')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            '        } elsif ($type_bits == 0120000) {')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            '    my $target = readlink($path);')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            '        $maximum_helper_output_bytes, "/usr/bin/xattr", "-s", @non_socket_paths);')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            '        join("", @records) . join("", @contents) . join("", @links) .')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -x -c \
            '    my $data_volume_observation = require_data_volume_identity();')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -c \
            'acl_line_is_canonical($acl_lines[$index], $expected_acl_kind[$index],')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -c \
            '^Identifier=com[.]elamin[.]AudioStreamer[.]CaptureServer$')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -c \
            '^TeamIdentifier=MSMG8CJLB3$')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -c \
            '^Authority=Apple Development: Ahmed Elamin [(]92LVX32M8K[)]$')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -c \
            '^CDHash=af8181f6c0e81fc5824d1b9ff36dbb36a25ad18b$')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -c \
            'CodeDirectory v=20400 size=12042 flags=0x0[(]none[)] hashes=369[+]3 location=embedded$')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -c \
            '$verify_status == 0 && $verify_output eq ""')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -c \
            '$lsof_status == 256 && $lsof_output eq ""')" == '1' &&
       "$(print -rn -- "$payload_text" | /usr/bin/grep -F -c \
            '$socket_xattr_status == 256 && $socket_xattr_output eq $expected_socket_xattr')" == '1' ]] || return 1
    text_has_ordered_tokens "$payload_text" \
        '        my $socket_path = "$root/broker-prep-L1Ciab.sock";' \
        '            (@command == 2 && $command[1] eq $socket_path);' \
        'sub synchronous_capture {' \
        '    require_exact_tool($command[0]);' \
        '    my $child = fork();' \
        '            open(STDIN, "<", "/dev/null") or exit 249;' \
        '            open(STDOUT, ">&", $writer) or exit 250;' \
        '            open(STDERR, ">&", $writer) or exit 251;' \
        '            exec({$command[0]} @command);' \
        '        my $count = sysread($reader, $chunk, 65_536);' \
        '            $overflowed = 1;' \
        '    close($reader) or die "capture helper reader close failed\n";' \
        '        $waited = waitpid($child, 0);' \
        '    $waited == $child or die "capture helper reap failed\n";' \
        '    require_exact_tool($command[0]);' \
        '    !$overflowed or die "capture helper output exceeded bound\n";' \
        'sub require_data_volume_identity {' \
        '        131_072, "/usr/sbin/diskutil", "info", "-plist", $data_volume_mount);' \
        '    $volume_uuid eq $expected_data_volume_uuid &&' \
        '        $mount_point eq $data_volume_mount && $filesystem_type eq "apfs" &&' \
        '        or die "capture Data volume identity changed\n";' \
        'sub symbolic_mode {' \
        'sub acl_line_is_canonical {' \
        'sysopen(my $lease, $lease_path, O_RDONLY | 0x100)' \
        'fcntl($lease, F_SETFD, FD_CLOEXEC) or die "capture lease CLOEXEC failed\n";' \
        'require_exact_lease($lease);' \
        'flock($lease, 6) or die "capture lease is busy\n";' \
        'require_exact_lease($lease);' \
        'sub read_symlink {' \
        '    my $target = readlink($path);' \
        '        or die "capture symlink identity changed after read\n";' \
        '    my $data_volume_observation = require_data_volume_identity();' \
        '        } elsif ($type_bits == 0120000) {' \
        '            $kind = "symlink";' \
        '                read_symlink($path, $relative, $expected_key, $before[7]);' \
        '    $walk->($root, "", 0);' \
        '        observation_record("data-volume", 0, $data_volume_observation));' \
        '        $maximum_helper_output_bytes, "/usr/bin/xattr", "-s", @non_socket_paths);' \
        '        "volume_uuid=$expected_data_volume_uuid\n" .' \
        '        "root_device=$root_device\n" .' \
        'my $first = capture_pass();' \
        'my $second = capture_pass();' \
        '$first eq $second or die "capture passes were not identical\n";' \
        'require_exact_lease($lease);' \
        'length($transport) <= 2_097_280 or die "capture transport exceeded bound\n";' \
        'require_exact_lease($lease);' \
        'print STDOUT $transport or die "capture stdout failed\n";' \
        'close(STDOUT) or die "capture stdout close failed\n";' \
        'exit 0;' || return 1
}

launcher_capture_contract_is_closed() {
    local launcher_text="$1"
    local capture_body resume_body envelope_body runtime_tail cleanup_body
    capture_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^capture_root_evidence_once() {$/,/^bootstrap_root_broker_once() {$/p' | \
        /usr/bin/sed '$d')
    resume_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^resume_root_capture_publication() {$/,/^capture_root_evidence_once() {$/p' | \
        /usr/bin/sed '$d')
    envelope_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^require_root_capture_envelope_file() {$/,/^resume_root_capture_publication() {$/p' | \
        /usr/bin/sed '$d')
    runtime_tail=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^\[\[ "\$#" == '\''1'\'' \]\] || usage$/,$p')
    cleanup_body=$(print -rn -- "$launcher_text" | /usr/bin/sed -n \
        '/^cleanup() {$/,/^}$/p')
    [[ "$launcher_text" == *"readonly CAPTURE_MODE='--capture-failed-root-evidence'"* &&
       "$launcher_text" == *"readonly ROOT_CAPTURE_TRANSPORT='/Users/ahmed/Library/Application Support/opensteamer/.failed-installed-driver-both-order-mono-loopback-root-capture-L1Ciab.transport'"* &&
       "$launcher_text" == *"readonly ROOT_CAPTURE_PARTIAL='/Users/ahmed/Library/Application Support/opensteamer/.failed-installed-driver-both-order-mono-loopback-root-capture-L1Ciab.partial'"* &&
       "$launcher_text" == *"readonly ROOT_CAPTURE_READY='/Users/ahmed/Library/Application Support/opensteamer/failed-installed-driver-both-order-mono-loopback-root-capture-L1Ciab.envelope'"* &&
       "$(print -rn -- "$capture_body" | /usr/bin/grep -F -c '$ROOT_BOOTSTRAP_COMMAND' || true)" == '0' &&
       "$(print -rn -- "$capture_body" | /usr/bin/grep -E -c \
            'classify_retry_state|stage_live_one_shot|bootstrap_root_broker_once|START_MODE|STOP_MODE|CONTROLLER|GUARDIAN' || true)" == '0' &&
       "$(print -rn -- "$capture_body" | /usr/bin/grep -F -x -c \
            '    AUTHORIZATION_ATTEMPTED=1')" == '1' &&
       "$(print -rn -- "$capture_body" | /usr/bin/grep -F -x -c \
            '      builtin cd / || exit 69')" == '1' &&
       "$(print -rn -- "$capture_body" | /usr/bin/grep -F -c \
            '/usr/bin/osascript - "$ROOT_CAPTURE_COMMAND" > "$ROOT_CAPTURE_TRANSPORT"')" == '1' &&
       "$(print -rn -- "$cleanup_body" | /usr/bin/grep -E -c \
            'ROOT_CAPTURE_(TRANSPORT|PARTIAL|READY)' || true)" == '0' &&
       "$(print -rn -- "$resume_body" | /usr/bin/grep -F -x -c \
            '        /bin/ln "$ROOT_CAPTURE_TRANSPORT" "$ROOT_CAPTURE_PARTIAL"')" == '1' &&
       "$(print -rn -- "$resume_body" | /usr/bin/grep -F -x -c \
            '        /bin/ln "$ROOT_CAPTURE_PARTIAL" "$ROOT_CAPTURE_READY"')" == '2' &&
       "$(print -rn -- "$resume_body" | /usr/bin/grep -F -c \
            '/bin/rm -f -- "$ROOT_CAPTURE_TRANSPORT"')" == '2' &&
       "$(print -rn -- "$resume_body" | /usr/bin/grep -F -x -c \
            '        /bin/rm -f -- "$ROOT_CAPTURE_PARTIAL"')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -x -c \
            '    if ! /usr/bin/env -i LC_ALL=C HOME="$PINNED_USER_HOME" PATH="$PINNED_EXEC_PATH" \')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -x -c \
            "            <<'OPENSTEAMER_VALIDATE_ROOT_CAPTURE_L1CIAB'")" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            "<<'OPENSTEAMER_VALIDATE_ROOT_CAPTURE_L1CIAB' ||" || true)" == '0' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -x -c \
            "        fail 'root capture envelope failed its canonical contract'")" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -x -c \
            '$transport =~ /\A([^\t\r\n]+)\t([0-9]+)\t([0-9a-f]{64})\t([0-9a-f]+)\n\n\z/')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            'length($payload_hex) == 2 * $payload_length')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            'sha256_hex($payload) eq $payload_hash')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            '$expected_nlink =~ /\A[123]\z/')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            '$observed_total_regular_bytes += $size;')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            '$observed_total_regular_bytes ==')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            '$record_kind{$required} eq "regular"')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            '$content_length{$required} == $record_size{$required}')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            '$content_hash{$required} eq $record_digest{$required}')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            '$link_target{$relative} eq $expected_symlink_targets{$relative}')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            '$link_hash{$relative} eq $record_digest{$relative}')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            '$record_kind{$record_relative_path[$index]} eq "symlink" ?')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            '$bsd_stat_line[$index] eq "$record_stat_prefix[$index]:0"')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            '$observation_bytes{"socket-xattr"} eq $expected_socket_xattr')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            '$observation_bytes{"xattr"} eq "" && $observation_bytes{"openers"} eq ""')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            'acl_line_is_canonical($acl_line[$index], $record_acl_kind[$index],')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            'Identifier=com[.]elamin[.]AudioStreamer[.]CaptureServer')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            'TeamIdentifier=MSMG8CJLB3')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            'Authority=Apple Development: Ahmed Elamin [(]92LVX32M8K[)]')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            'CDHash=af8181f6c0e81fc5824d1b9ff36dbb36a25ad18b')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            'CodeDirectory v=20400 size=12042 flags=0x0[(]none[)] hashes=369[+]3 location=embedded$')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            '$observation{"codesign-verify.status"} == 0')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            '$observation{"codesign-verify.length"} == 0')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            '$observation{"openers.status"} == 256 && $observation{"openers.length"} == 0')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -x -c \
            '                fail '\''root capture publication names do not share one inode'\''')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            '[[ "$capture_identity" == "$expected_identity" ]]')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            '[[ "$opener_status" == '\''1'\'' && -z "$openers" ]]')" == '1' &&
       "$(print -rn -- "$envelope_body" | /usr/bin/grep -F -c \
            '[[ "$after" == "$before" && "$second_hash" == "$first_hash" &&')" == '1' ]] || return 1
    text_has_ordered_tokens "$envelope_body" \
        '    if ! /usr/bin/env -i LC_ALL=C HOME="$PINNED_USER_HOME" PATH="$PINNED_EXEC_PATH" \' \
        "            <<'OPENSTEAMER_VALIDATE_ROOT_CAPTURE_L1CIAB'" \
        'OPENSTEAMER_VALIDATE_ROOT_CAPTURE_L1CIAB' \
        '    then' \
        "        fail 'root capture envelope failed its canonical contract'" \
        '    fi' \
        '    if [[ "$EXPECTED_ROOT_CAPTURE_ENVELOPE_SHA256" != *PIN_AFTER* ]]; then' || return 1
    text_has_ordered_tokens "$capture_body" \
        '    require_launcher_lock_held' \
        '    if resume_root_capture_publication; then' \
        '    [[ ! -e "$ROOT_CAPTURE_TRANSPORT" && ! -L "$ROOT_CAPTURE_TRANSPORT" &&' \
        '    AUTHORIZATION_ATTEMPTED=1' \
        '      builtin cd / || exit 69' \
        '          /usr/bin/osascript - "$ROOT_CAPTURE_COMMAND" > "$ROOT_CAPTURE_TRANSPORT" <<'\''APPLESCRIPT'\''' \
        '    require_root_capture_envelope_file "$ROOT_CAPTURE_TRANSPORT" 1' \
        '    /bin/sync' \
        '    require_root_capture_envelope_file "$ROOT_CAPTURE_TRANSPORT" 1' \
        '    resume_root_capture_publication' || return 1
    text_has_ordered_tokens "$resume_body" \
        '    require_launcher_lock_held' \
        '    if (( transport_present == 1 && partial_present == 0 && ready_present == 0 )); then' \
        '            require_safe_incomplete_root_capture_transport' \
        '        require_launcher_lock_held' \
        '            /bin/rm -f -- "$ROOT_CAPTURE_TRANSPORT"' \
        '        /bin/ln "$ROOT_CAPTURE_TRANSPORT" "$ROOT_CAPTURE_PARTIAL"' \
        '    elif (( transport_present == 1 && partial_present == 1 && ready_present == 0 )); then' \
        '        require_same_root_capture_inode 2 "$ROOT_CAPTURE_TRANSPORT" "$ROOT_CAPTURE_PARTIAL"' \
        '        /bin/ln "$ROOT_CAPTURE_PARTIAL" "$ROOT_CAPTURE_READY"' \
        '    if (( transport_present == 1 && partial_present == 1 && ready_present == 1 )); then' \
        '        require_same_root_capture_inode 3 "$ROOT_CAPTURE_TRANSPORT" \' \
        '        /bin/sync' \
        '        require_same_root_capture_inode 3 "$ROOT_CAPTURE_TRANSPORT" \' \
        '        /bin/rm -f -- "$ROOT_CAPTURE_TRANSPORT"' \
        '    if (( transport_present == 0 && partial_present == 1 && ready_present == 1 )); then' \
        '        require_same_root_capture_inode 2 "$ROOT_CAPTURE_PARTIAL" "$ROOT_CAPTURE_READY"' \
        '        /bin/sync' \
        '        require_same_root_capture_inode 2 "$ROOT_CAPTURE_PARTIAL" "$ROOT_CAPTURE_READY"' \
        '        /bin/rm -f -- "$ROOT_CAPTURE_PARTIAL"' \
        '        /bin/sync' \
        '        require_same_root_capture_inode 1 "$ROOT_CAPTURE_READY"' || return 1
    text_has_ordered_tokens "$runtime_tail" \
        'require_launcher_identity' \
        'require_retry_preservation_contract' \
        'require_preserved_rescued_user_evidence' \
        'if [[ "$MODE" == "$CAPTURE_MODE" ]]; then' \
        '    acquire_launcher_lock' \
        '    capture_root_evidence_once' \
        '    exit 0' \
        'fi' \
        'require_toolchain' || return 1
}

require_retry_preservation_contract() {
    local launcher_source
    launcher_source=$(<"$LAUNCHER")
    launcher_guardian_toolchain_resolution_contract_is_closed "$launcher_source" ||
        fail 'pinned Xcode symlink canonicalization contract changed'
    launcher_data_volume_contract_is_closed "$launcher_source" \
        "$ROOT_BOOTSTRAP_COMMAND" "$ROOT_CAPTURE_COMMAND" ||
        fail 'stable APFS Data-volume binding or reboot-renumber contract changed'
    root_capture_payload_contract_is_closed "$ROOT_CAPTURE_COMMAND" ||
        fail 'root capture read-only, bounded, or lease-through-emission contract changed'
    launcher_capture_contract_is_closed "$launcher_source" ||
        fail 'capture-only dispatch or crash-safe publication contract changed'
    root_payload_mutations_are_closed "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'root retry payload filesystem-mutation allowlist changed'
    root_retry_payload_contract_is_closed "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'root R0-R3 preservation, durability, or proof order changed'
    root_phase_lease_contract_is_closed "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'root-phase crash exclusion or broker handoff contract changed'
    root_phase_reaped_pipe_loses_signal_authority ||
        fail 'reaped pipe Child retained numeric signal authority after close'
    root_phase_lease_interleaving_is_safe prepare 0 1 0 0 0 ||
        fail 'root-phase model lost inner-shell lease after wrapper death'
    root_phase_lease_interleaving_is_safe broker_pre_ack 0 0 1 1 0 ||
        fail 'root-phase model lost pre-ACK redundant holders after wrapper death'
    root_phase_lease_interleaving_is_safe broker_post_ack 0 0 1 0 0 ||
        fail 'root-phase model lost supervisor lease after wrapper death'
    root_phase_lease_interleaving_is_safe broker_post_ack 1 0 0 0 0 ||
        fail 'root-phase model lost wrapper lease after supervisor death'
    root_phase_lease_interleaving_is_safe terminal 0 0 0 0 1 ||
        fail 'root-phase model rejected exact visible-broker terminal state'
    ! root_phase_lease_interleaving_is_safe broker_post_ack 0 0 0 0 0 ||
        fail 'root-phase model admitted a post-GO invisible broker with no holder'

    local original_swiftc_resolution_body
    original_swiftc_resolution_body=$(print -rn -- "$launcher_source" | /usr/bin/sed -n \
        '/^swiftc_resolution_is_valid() {$/,/^}$/p')
    local canonical_swiftc_expectation='       "$observed_swiftc" == "$PINNED_XCRUN_SWIFTC" ]]'
    local symlink_spelling_expectation='       "$observed_swiftc" == "$PINNED_SWIFTC" ]]'
    local symlink_spelling_body="${original_swiftc_resolution_body/$canonical_swiftc_expectation/$symlink_spelling_expectation}"
    [[ "$symlink_spelling_body" != "$original_swiftc_resolution_body" ]] ||
        fail 'uncanonicalized-swiftc-resolution mutant setup failed'
    local symlink_spelling_mutant="${launcher_source/$original_swiftc_resolution_body/$symlink_spelling_body}"
    ! launcher_guardian_toolchain_resolution_contract_is_closed "$symlink_spelling_mutant" ||
        fail 'Xcode toolchain contract admitted the unresolved app-symlink spelling'
    local resolved_xcode_path="readonly PINNED_RESOLVED_DEVELOPER_DIR='/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app/Contents/Developer'"
    local wrong_resolved_xcode_path="readonly PINNED_RESOLVED_DEVELOPER_DIR='/Volumes/Wrong/Xcode.app/Contents/Developer'"
    local wrong_resolved_xcode_mutant="${launcher_source/$resolved_xcode_path/$wrong_resolved_xcode_path}"
    [[ "$wrong_resolved_xcode_mutant" != "$launcher_source" ]] ||
        fail 'wrong-resolved-Xcode-target mutant setup failed'
    ! launcher_guardian_toolchain_resolution_contract_is_closed "$wrong_resolved_xcode_mutant" ||
        fail 'Xcode toolchain contract admitted the wrong resolved bundle target'
    local expected_volume_uuid="readonly EXPECTED_DATA_VOLUME_UUID='AF638805-E0CB-4356-941F-16B84DFB6435'"
    local wrong_volume_uuid="readonly EXPECTED_DATA_VOLUME_UUID='00000000-0000-0000-0000-000000000000'"
    local wrong_volume_uuid_mutant="${launcher_source/$expected_volume_uuid/$wrong_volume_uuid}"
    [[ "$wrong_volume_uuid_mutant" != "$launcher_source" ]] ||
        fail 'wrong-Data-volume-UUID mutant setup failed'
    ! launcher_data_volume_contract_is_closed "$wrong_volume_uuid_mutant" \
        "$ROOT_BOOTSTRAP_COMMAND" "$ROOT_CAPTURE_COMMAND" ||
        fail 'launcher admitted the wrong APFS Data-volume UUID'
    local expected_volume_mount="readonly DATA_VOLUME_MOUNT='/System/Volumes/Data'"
    local wrong_volume_mount="readonly DATA_VOLUME_MOUNT='/System/Volumes/Wrong'"
    local wrong_volume_mount_mutant="${launcher_source/$expected_volume_mount/$wrong_volume_mount}"
    [[ "$wrong_volume_mount_mutant" != "$launcher_source" ]] ||
        fail 'wrong-Data-volume-mount mutant setup failed'
    ! launcher_data_volume_contract_is_closed "$wrong_volume_mount_mutant" \
        "$ROOT_BOOTSTRAP_COMMAND" "$ROOT_CAPTURE_COMMAND" ||
        fail 'launcher admitted the wrong APFS Data-volume mount'
    local derived_public_device='    DATA_VOLUME_DEVICE="$device_before"'
    local fixed_public_device="    DATA_VOLUME_DEVICE='41001'"
    local fixed_public_device_mutant="${launcher_source/$derived_public_device/$fixed_public_device}"
    [[ "$fixed_public_device_mutant" != "$launcher_source" ]] ||
        fail 'fixed-public-device mutant setup failed'
    ! launcher_data_volume_contract_is_closed "$fixed_public_device_mutant" \
        "$ROOT_BOOTSTRAP_COMMAND" "$ROOT_CAPTURE_COMMAND" ||
        fail 'launcher admitted a reboot-unstable fixed public device'
    local root_inner_mount='trial_data_mount="/System/Volumes/Data"'
    local root_inner_wrong_mount='trial_data_mount="/System/Volumes/Wrong"'
    local root_inner_wrong_mount_mutant="${ROOT_BOOTSTRAP_COMMAND/$root_inner_mount/$root_inner_wrong_mount}"
    [[ "$root_inner_wrong_mount_mutant" != "$ROOT_BOOTSTRAP_COMMAND" ]] ||
        fail 'wrong-root-inner-Data-mount mutant setup failed'
    ! launcher_data_volume_contract_is_closed "$launcher_source" \
        "$root_inner_wrong_mount_mutant" "$ROOT_CAPTURE_COMMAND" ||
        fail 'root bootstrap admitted the wrong stable Data-volume mount'
    local root_wrapper_volume_uuid=$'    exact_plist_string($volume_plist, "VolumeUUID") eq\n        "AF638805-E0CB-4356-941F-16B84DFB6435"'
    local root_wrapper_wrong_uuid=$'    exact_plist_string($volume_plist, "VolumeUUID") eq\n        "00000000-0000-0000-0000-000000000000"'
    local root_wrapper_wrong_uuid_mutant="${ROOT_BOOTSTRAP_COMMAND/$root_wrapper_volume_uuid/$root_wrapper_wrong_uuid}"
    [[ "$root_wrapper_wrong_uuid_mutant" != "$ROOT_BOOTSTRAP_COMMAND" ]] ||
        fail 'wrong-root-wrapper-Data-UUID mutant setup failed'
    ! launcher_data_volume_contract_is_closed "$launcher_source" \
        "$root_wrapper_wrong_uuid_mutant" "$ROOT_CAPTURE_COMMAND" ||
        fail 'root wrapper admitted the wrong stable Data-volume UUID'
    local capture_derived_device='my $data_device = $initial_data_volume_stat[0];'
    local capture_fixed_device='my $data_device = 41001;'
    local capture_fixed_device_mutant="${ROOT_CAPTURE_COMMAND/$capture_derived_device/$capture_fixed_device}"
    [[ "$capture_fixed_device_mutant" != "$ROOT_CAPTURE_COMMAND" ]] ||
        fail 'fixed-capture-device mutant setup failed'
    ! launcher_data_volume_contract_is_closed "$launcher_source" \
        "$ROOT_BOOTSTRAP_COMMAND" "$capture_fixed_device_mutant" ||
        fail 'root capture admitted a reboot-unstable fixed device'
    local capture_volume_uuid='my $expected_data_volume_uuid = "AF638805-E0CB-4356-941F-16B84DFB6435";'
    local capture_wrong_uuid='my $expected_data_volume_uuid = "00000000-0000-0000-0000-000000000000";'
    local capture_wrong_uuid_mutant="${ROOT_CAPTURE_COMMAND/$capture_volume_uuid/$capture_wrong_uuid}"
    [[ "$capture_wrong_uuid_mutant" != "$ROOT_CAPTURE_COMMAND" ]] ||
        fail 'wrong-capture-volume-UUID mutant setup failed'
    ! root_capture_payload_contract_is_closed "$capture_wrong_uuid_mutant" ||
        fail 'root capture admitted the wrong APFS Data-volume UUID'
    local capture_readonly_open='sysopen(my $lease, $lease_path, O_RDONLY | 0x100)'
    local capture_write_open='sysopen(my $lease, $lease_path, O_RDWR | 0x100)'
    local capture_write_open_mutant="${ROOT_CAPTURE_COMMAND/$capture_readonly_open/$capture_write_open}"
    [[ "$capture_write_open_mutant" != "$ROOT_CAPTURE_COMMAND" ]] ||
        fail 'writable root-capture lease mutant setup failed'
    ! root_capture_payload_contract_is_closed "$capture_write_open_mutant" ||
        fail 'root capture contract admitted a writable descriptor'
    local capture_second_pass='my $second = capture_pass();'
    local capture_reused_pass='my $second = $first;'
    local capture_single_pass_mutant="${ROOT_CAPTURE_COMMAND/$capture_second_pass/$capture_reused_pass}"
    [[ "$capture_single_pass_mutant" != "$ROOT_CAPTURE_COMMAND" ]] ||
        fail 'single-pass root-capture mutant setup failed'
    ! root_capture_payload_contract_is_closed "$capture_single_pass_mutant" ||
        fail 'root capture contract admitted a single evidence pass'
    local capture_emit_pair=$'print STDOUT $transport or die "capture stdout failed\\n";\nclose(STDOUT) or die "capture stdout close failed\\n";'
    local capture_release_before_emit=$'close($lease) or die "capture lease close failed\\n";\nprint STDOUT $transport or die "capture stdout failed\\n";\nclose(STDOUT) or die "capture stdout close failed\\n";'
    local capture_early_release_mutant="${ROOT_CAPTURE_COMMAND/$capture_emit_pair/$capture_release_before_emit}"
    [[ "$capture_early_release_mutant" != "$ROOT_CAPTURE_COMMAND" ]] ||
        fail 'release-before-capture-emission mutant setup failed'
    ! root_capture_payload_contract_is_closed "$capture_early_release_mutant" ||
        fail 'root capture contract admitted phase-lock release before final emission'
    local capture_bounded_transport='length($transport) <= 2_097_280'
    local capture_unbounded_transport='length($transport) >= 0'
    local capture_unbounded_mutant="${ROOT_CAPTURE_COMMAND/$capture_bounded_transport/$capture_unbounded_transport}"
    [[ "$capture_unbounded_mutant" != "$ROOT_CAPTURE_COMMAND" ]] ||
        fail 'unbounded root-capture transport mutant setup failed'
    ! root_capture_payload_contract_is_closed "$capture_unbounded_mutant" ||
        fail 'root capture contract admitted an unbounded transport'
    local capture_cloexec='fcntl($lease, F_SETFD, FD_CLOEXEC) or die "capture lease CLOEXEC failed\n";'
    local capture_no_cloexec_mutant="${ROOT_CAPTURE_COMMAND/$capture_cloexec/:}"
    [[ "$capture_no_cloexec_mutant" != "$ROOT_CAPTURE_COMMAND" ]] ||
        fail 'root-capture lease CLOEXEC mutant setup failed'
    ! root_capture_payload_contract_is_closed "$capture_no_cloexec_mutant" ||
        fail 'root capture contract admitted helper inheritance of the phase lease'
    local capture_list_exec='            exec({$command[0]} @command);'
    local capture_shell_exec='            exec("/bin/sh", "-c", join(" ", @command));'
    local capture_shell_mutant="${ROOT_CAPTURE_COMMAND/$capture_list_exec/$capture_shell_exec}"
    [[ "$capture_shell_mutant" != "$ROOT_CAPTURE_COMMAND" ]] ||
        fail 'root-capture shell-helper mutant setup failed'
    ! root_capture_payload_contract_is_closed "$capture_shell_mutant" ||
        fail 'root capture contract admitted shell evaluation of helper arguments'
    local capture_null_stdin='            open(STDIN, "<", "/dev/null") or exit 249;'
    local capture_inherited_stdin_mutant="${ROOT_CAPTURE_COMMAND/$capture_null_stdin/:}"
    [[ "$capture_inherited_stdin_mutant" != "$ROOT_CAPTURE_COMMAND" ]] ||
        fail 'root-capture inherited-stdin mutant setup failed'
    ! root_capture_payload_contract_is_closed "$capture_inherited_stdin_mutant" ||
        fail 'root capture contract admitted inherited helper stdin'
    local capture_drain_on_cap='            $overflowed = 1;'
    local capture_return_on_cap='            return (70, "");'
    local capture_cap_return_mutant="${ROOT_CAPTURE_COMMAND/$capture_drain_on_cap/$capture_return_on_cap}"
    [[ "$capture_cap_return_mutant" != "$ROOT_CAPTURE_COMMAND" ]] ||
        fail 'root-capture cap-return mutant setup failed'
    ! root_capture_payload_contract_is_closed "$capture_cap_return_mutant" ||
        fail 'root capture contract admitted return before helper EOF and reap'
    local capture_pipe_eof='    close($reader) or die "capture helper reader close failed\n";'
    local capture_no_eof_mutant="${ROOT_CAPTURE_COMMAND/$capture_pipe_eof/:}"
    [[ "$capture_no_eof_mutant" != "$ROOT_CAPTURE_COMMAND" ]] ||
        fail 'root-capture missing-pipe-EOF mutant setup failed'
    ! root_capture_payload_contract_is_closed "$capture_no_eof_mutant" ||
        fail 'root capture contract admitted helper wait without pipe EOF proof'
    local capture_wait_child='        $waited = waitpid($child, 0);'
    local capture_fake_wait='        $waited = $child;'
    local capture_no_wait_mutant="${ROOT_CAPTURE_COMMAND/$capture_wait_child/$capture_fake_wait}"
    [[ "$capture_no_wait_mutant" != "$ROOT_CAPTURE_COMMAND" ]] ||
        fail 'root-capture missing-reap mutant setup failed'
    ! root_capture_payload_contract_is_closed "$capture_no_wait_mutant" ||
        fail 'root capture contract admitted helper EOF without direct-Child reap'
    local capture_final_emit='print STDOUT $transport or die "capture stdout failed\n";'
    local capture_helper_leak=$'print STDOUT $stat_output;\nprint STDOUT $transport or die "capture stdout failed\\n";'
    local capture_helper_leak_mutant="${ROOT_CAPTURE_COMMAND/$capture_final_emit/$capture_helper_leak}"
    [[ "$capture_helper_leak_mutant" != "$ROOT_CAPTURE_COMMAND" ]] ||
        fail 'root-capture helper-output leak mutant setup failed'
    ! root_capture_payload_contract_is_closed "$capture_helper_leak_mutant" ||
        fail 'root capture contract admitted helper bytes before the canonical envelope'

    local capture_dispatch=$'if [[ "$MODE" == "$CAPTURE_MODE" ]]; then\n    acquire_launcher_lock\n    capture_root_evidence_once\n    exit 0\nfi'
    local capture_fallthrough=$'if [[ "$MODE" == "$CAPTURE_MODE" ]]; then\n    acquire_launcher_lock\n    capture_root_evidence_once\nfi'
    local capture_fallthrough_mutant="${launcher_source/$capture_dispatch/$capture_fallthrough}"
    [[ "$capture_fallthrough_mutant" != "$launcher_source" ]] ||
        fail 'capture-mode fallthrough mutant setup failed'
    ! launcher_capture_contract_is_closed "$capture_fallthrough_mutant" ||
        fail 'capture-only contract admitted build/start fallthrough'
    local capture_auth_pair=$'    AUTHORIZATION_ATTEMPTED=1\n    set +e'
    local capture_late_auth_mutant="${launcher_source/$capture_auth_pair/    set +e}"
    capture_late_auth_mutant="${capture_late_auth_mutant/    capture_status=\$?/    capture_status=\$?$'\n'    AUTHORIZATION_ATTEMPTED=1}"
    [[ "$capture_late_auth_mutant" != "$launcher_source" ]] ||
        fail 'late capture authorization marker mutant setup failed'
    ! launcher_capture_contract_is_closed "$capture_late_auth_mutant" ||
        fail 'capture-only contract admitted a late authorization marker'
    local original_capture_body
    original_capture_body=$(print -rn -- "$launcher_source" | /usr/bin/sed -n \
        '/^capture_root_evidence_once() {$/,/^bootstrap_root_broker_once() {$/p' | \
        /usr/bin/sed '$d')
    local capture_canonical_cwd='      builtin cd / || exit 69'
    local capture_missing_cwd_body="${original_capture_body/$capture_canonical_cwd/      :}"
    [[ "$capture_missing_cwd_body" != "$original_capture_body" ]] ||
        fail 'capture-canonical-cwd mutant setup failed'
    local capture_missing_cwd_mutant="${launcher_source/$original_capture_body/$capture_missing_cwd_body}"
    ! launcher_capture_contract_is_closed "$capture_missing_cwd_mutant" ||
        fail 'capture-only contract admitted an inherited protected working directory'
    local capture_bootstrap_mutant="${launcher_source//\"\$ROOT_CAPTURE_COMMAND\"/\"\$ROOT_BOOTSTRAP_COMMAND\"}"
    [[ "$capture_bootstrap_mutant" != "$launcher_source" ]] ||
        fail 'capture-to-bootstrap command mutant setup failed'
    ! launcher_capture_contract_is_closed "$capture_bootstrap_mutant" ||
        fail 'capture-only contract admitted the mutating root bootstrap payload'
    local capture_move_mutant="${launcher_source//\/bin\/ln/\/bin\/mv -n}"
    [[ "$capture_move_mutant" != "$launcher_source" ]] ||
        fail 'non-link root-capture publication mutant setup failed'
    ! launcher_capture_contract_is_closed "$capture_move_mutant" ||
        fail 'capture publication contract admitted a non-link partial publish'
    local original_capture_resume original_capture_envelope mutated_capture_part capture_mutant
    original_capture_resume=$(print -rn -- "$launcher_source" | /usr/bin/sed -n \
        '/^resume_root_capture_publication() {$/,/^capture_root_evidence_once() {$/p' | \
        /usr/bin/sed '$d')
    original_capture_envelope=$(print -rn -- "$launcher_source" | /usr/bin/sed -n \
        '/^require_root_capture_envelope_file() {$/,/^resume_root_capture_publication() {$/p' | \
        /usr/bin/sed '$d')
    local capture_validator_marker="            <<'OPENSTEAMER_VALIDATE_ROOT_CAPTURE_L1CIAB'"
    local capture_validator_dangling_or="            <<'OPENSTEAMER_VALIDATE_ROOT_CAPTURE_L1CIAB' ||"
    mutated_capture_part="${original_capture_envelope/$capture_validator_marker/$capture_validator_dangling_or}"
    [[ "$mutated_capture_part" != "$original_capture_envelope" ]] ||
        fail 'capture-validator-dangling-OR mutant setup failed'
    capture_mutant="${launcher_source/$original_capture_envelope/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture envelope contract admitted a fail handler inside validator input'
    local capture_double_lf_framing='$transport =~ /\A([^\t\r\n]+)\t([0-9]+)\t([0-9a-f]{64})\t([0-9a-f]+)\n\n\z/'
    local capture_single_lf_framing='$transport =~ /\A([^\t\r\n]+)\t([0-9]+)\t([0-9a-f]{64})\t([0-9a-f]+)\n\z/'
    mutated_capture_part="${original_capture_envelope/$capture_double_lf_framing/$capture_single_lf_framing}"
    [[ "$mutated_capture_part" != "$original_capture_envelope" ]] ||
        fail 'capture-double-LF-framing mutant setup failed'
    capture_mutant="${launcher_source/$original_capture_envelope/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture envelope contract admitted a single-LF osascript transport frame'
    local capture_inode_guard="                fail 'root capture publication names do not share one inode'"
    mutated_capture_part="${original_capture_envelope/$capture_inode_guard/                :}"
    [[ "$mutated_capture_part" != "$original_capture_envelope" ]] ||
        fail 'capture same-inode proof mutant setup failed'
    capture_mutant="${launcher_source/$original_capture_envelope/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture publication contract admitted distinct partial and ready inodes'
    local capture_transport_link='        /bin/ln "$ROOT_CAPTURE_TRANSPORT" "$ROOT_CAPTURE_PARTIAL"'
    mutated_capture_part="${original_capture_resume/$capture_transport_link/        :}"
    capture_mutant="${launcher_source/$original_capture_resume/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture publication contract admitted a missing transport-to-partial link'
    local capture_ready_link='        /bin/ln "$ROOT_CAPTURE_PARTIAL" "$ROOT_CAPTURE_READY"'
    mutated_capture_part="${original_capture_resume/$capture_ready_link/        :}"
    capture_mutant="${launcher_source/$original_capture_resume/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture publication contract admitted a missing partial-to-ready link'
    local capture_three_name_proof='        require_same_root_capture_inode 3 "$ROOT_CAPTURE_TRANSPORT" \'
    mutated_capture_part="${original_capture_resume/$capture_three_name_proof/        :}"
    capture_mutant="${launcher_source/$original_capture_resume/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture publication contract admitted a missing three-name reproof'
    local capture_transport_unlink='        /bin/rm -f -- "$ROOT_CAPTURE_TRANSPORT"'
    mutated_capture_part="${original_capture_resume/$capture_transport_unlink/        :}"
    capture_mutant="${launcher_source/$original_capture_resume/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture publication contract admitted a missing transport unlink'
    local capture_partial_unlink='        /bin/rm -f -- "$ROOT_CAPTURE_PARTIAL"'
    mutated_capture_part="${original_capture_resume/$capture_partial_unlink/        :}"
    capture_mutant="${launcher_source/$original_capture_resume/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture publication contract admitted a missing partial unlink'
    local capture_same_inode_guard='            [[ "$capture_identity" == "$expected_identity" ]] ||'
    mutated_capture_part="${original_capture_envelope/$capture_same_inode_guard/            true ||}"
    capture_mutant="${launcher_source/$original_capture_envelope/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture publication contract admitted a descriptor/name inode mismatch'
    local capture_stable_incomplete='    [[ "$after" == "$before" && "$second_hash" == "$first_hash" &&'
    local capture_weak_stable='    [[ -n "$first_hash" &&'
    mutated_capture_part="${original_capture_envelope/$capture_stable_incomplete/$capture_weak_stable}"
    capture_mutant="${launcher_source/$original_capture_envelope/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture publication contract admitted an unstable incomplete transport cleanup'
    local capture_content_kind='        $record_kind{$required} eq "regular" &&'
    mutated_capture_part="${original_capture_envelope/$capture_content_kind/        1 == 1 &&}"
    capture_mutant="${launcher_source/$original_capture_envelope/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture envelope contract admitted content for a non-regular record'
    local capture_content_size='        $content_length{$required} == $record_size{$required} &&'
    mutated_capture_part="${original_capture_envelope/$capture_content_size/        1 == 1 &&}"
    capture_mutant="${launcher_source/$original_capture_envelope/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture envelope contract admitted content with the wrong record size'
    local capture_content_digest='        $content_hash{$required} eq $record_digest{$required} or exit 89;'
    mutated_capture_part="${original_capture_envelope/$capture_content_digest/        1 == 1 or exit 89;}"
    capture_mutant="${launcher_source/$original_capture_envelope/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture envelope contract admitted content with the wrong record digest'
    local capture_total_sum='            $observed_total_regular_bytes += $size;'
    mutated_capture_part="${original_capture_envelope/$capture_total_sum/            :;}"
    capture_mutant="${launcher_source/$original_capture_envelope/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture envelope contract admitted an uncomputed total regular byte count'
    local capture_stat_semantic='    $bsd_stat_line[$index] eq "$record_stat_prefix[$index]:0" or exit 94;'
    mutated_capture_part="${original_capture_envelope/$capture_stat_semantic/    1 == 1 or exit 94;}"
    capture_mutant="${launcher_source/$original_capture_envelope/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture envelope contract admitted noncanonical BSD flags or stat bytes'
    local capture_socket_semantic='$observation_bytes{"socket-xattr"} eq $expected_socket_xattr or exit 95;'
    mutated_capture_part="${original_capture_envelope/$capture_socket_semantic/1 == 1 or exit 95;}"
    capture_mutant="${launcher_source/$original_capture_envelope/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture envelope contract admitted noncanonical socket xattr output'
    local capture_link_target_semantic='$link_target{$relative} eq $expected_symlink_targets{$relative} &&'
    mutated_capture_part="${original_capture_envelope/$capture_link_target_semantic/1 == 1 &&}"
    capture_mutant="${launcher_source/$original_capture_envelope/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture envelope contract admitted the wrong framework symlink target'
    local capture_link_acl_semantic='$record_kind{$record_relative_path[$index]} eq "symlink" ?'
    mutated_capture_part="${original_capture_envelope/$capture_link_acl_semantic/0 == 1 ?}"
    capture_mutant="${launcher_source/$original_capture_envelope/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture envelope contract admitted an ACL line unbound to its symlink target'

    local capture_total_equality='$observed_total_regular_bytes =='
    local capture_total_weak='$observed_total_regular_bytes >= 0 ||'
    mutated_capture_part="${original_capture_envelope/$capture_total_equality/$capture_total_weak}"
    [[ "$mutated_capture_part" != "$original_capture_envelope" ]] ||
        fail 'capture-total-equality mutant setup failed'
    capture_mutant="${launcher_source/$original_capture_envelope/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture envelope contract admitted a false declared regular-byte total'
    local capture_acl_binding='    acl_line_is_canonical($acl_line[$index], $record_acl_kind[$index],'
    mutated_capture_part="${original_capture_envelope/$capture_acl_binding/    1 == 1 ||}"
    [[ "$mutated_capture_part" != "$original_capture_envelope" ]] ||
        fail 'capture-ACL-record-binding mutant setup failed'
    capture_mutant="${launcher_source/$original_capture_envelope/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture envelope contract admitted ACL bytes unbound to record metadata'
    local capture_verify_status='$observation{"codesign-verify.status"} == 0'
    mutated_capture_part="${original_capture_envelope/$capture_verify_status/1 == 1}"
    [[ "$mutated_capture_part" != "$original_capture_envelope" ]] ||
        fail 'capture-codesign-verify-status mutant setup failed'
    capture_mutant="${launcher_source/$original_capture_envelope/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture envelope contract admitted a failed codesign verification'
    local capture_empty_outputs='$observation_bytes{"xattr"} eq "" && $observation_bytes{"openers"} eq "" &&'
    mutated_capture_part="${original_capture_envelope/$capture_empty_outputs/1 == 1 &&}"
    [[ "$mutated_capture_part" != "$original_capture_envelope" ]] ||
        fail 'capture-empty-observation mutant setup failed'
    capture_mutant="${launcher_source/$original_capture_envelope/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture envelope contract admitted nonempty xattr or opener output'
    local capture_identifier='Identifier=com[.]elamin[.]AudioStreamer[.]CaptureServer'
    mutated_capture_part="${original_capture_envelope/$capture_identifier/Identifier=com[.]example[.]Wrong}"
    [[ "$mutated_capture_part" != "$original_capture_envelope" ]] ||
        fail 'capture-codesign-identifier mutant setup failed'
    capture_mutant="${launcher_source/$original_capture_envelope/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture envelope contract admitted a wrong codesign identifier'
    local capture_team='TeamIdentifier=MSMG8CJLB3'
    mutated_capture_part="${original_capture_envelope/$capture_team/TeamIdentifier=WRONGTEAM}"
    capture_mutant="${launcher_source/$original_capture_envelope/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture envelope contract admitted a wrong codesign team'
    local capture_authority='Authority=Apple Development: Ahmed Elamin [(]92LVX32M8K[)]'
    mutated_capture_part="${original_capture_envelope/$capture_authority/Authority=Wrong}"
    capture_mutant="${launcher_source/$original_capture_envelope/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture envelope contract admitted a wrong codesign authority'
    local capture_cdhash='CDHash=af8181f6c0e81fc5824d1b9ff36dbb36a25ad18b'
    mutated_capture_part="${original_capture_envelope/$capture_cdhash/CDHash=0000000000000000000000000000000000000000}"
    capture_mutant="${launcher_source/$original_capture_envelope/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture envelope contract admitted a wrong codesign CDHash'
    local capture_historical_code_directory='CodeDirectory v=20400 size=12042 flags=0x0[(]none[)] hashes=369[+]3 location=embedded$'
    mutated_capture_part="${original_capture_envelope/$capture_historical_code_directory/CodeDirectory v=20400 size=12042 flags=0x10000[(]runtime[)] hashes=369[+]3 location=embedded$}"
    capture_mutant="${launcher_source/$original_capture_envelope/$mutated_capture_part}"
    ! launcher_capture_contract_is_closed "$capture_mutant" ||
        fail 'capture envelope contract admitted the wrong historical CodeDirectory identity'

    local producer_acl_binding='        acl_line_is_canonical($acl_lines[$index], $expected_acl_kind[$index],'
    local weak_producer_acl_mutant="${ROOT_CAPTURE_COMMAND/$producer_acl_binding/        1 == 1 ||}"
    [[ "$weak_producer_acl_mutant" != "$ROOT_CAPTURE_COMMAND" ]] ||
        fail 'root-capture producer ACL-binding mutant setup failed'
    ! root_capture_payload_contract_is_closed "$weak_producer_acl_mutant" ||
        fail 'root capture producer admitted ACL bytes unbound to descriptor metadata'
    local producer_xattr_nofollow='        $maximum_helper_output_bytes, "/usr/bin/xattr", "-s", @non_socket_paths);'
    local producer_xattr_follow='        $maximum_helper_output_bytes, "/usr/bin/xattr", @non_socket_paths);'
    local producer_xattr_follow_mutant="${ROOT_CAPTURE_COMMAND/$producer_xattr_nofollow/$producer_xattr_follow}"
    [[ "$producer_xattr_follow_mutant" != "$ROOT_CAPTURE_COMMAND" ]] ||
        fail 'root-capture symlink-xattr mutant setup failed'
    ! root_capture_payload_contract_is_closed "$producer_xattr_follow_mutant" ||
        fail 'root capture producer admitted symlink-following xattr inspection'
    local producer_socket_xattr_exact='            (@command == 2 && $command[1] eq $socket_path);'
    local producer_socket_xattr_weak='            (@command == 2 && root_path_argument_is_safe($command[1]));'
    local producer_socket_xattr_weak_mutant="${ROOT_CAPTURE_COMMAND/$producer_socket_xattr_exact/$producer_socket_xattr_weak}"
    [[ "$producer_socket_xattr_weak_mutant" != "$ROOT_CAPTURE_COMMAND" ]] ||
        fail 'root-capture socket-xattr allowlist mutant setup failed'
    ! root_capture_payload_contract_is_closed "$producer_socket_xattr_weak_mutant" ||
        fail 'root capture producer admitted a non-socket no-flag xattr invocation'
    local producer_symlink_reproof=$'    @after && stat_key(@after) eq $expected_key\n        or die "capture symlink identity changed after read\\n";'
    local producer_weak_symlink_reproof=$'    @after && 1 == 1\n        or die "capture symlink identity changed after read\\n";'
    local producer_weak_symlink_mutant="${ROOT_CAPTURE_COMMAND/$producer_symlink_reproof/$producer_weak_symlink_reproof}"
    [[ "$producer_weak_symlink_mutant" != "$ROOT_CAPTURE_COMMAND" ]] ||
        fail 'root-capture symlink-reproof mutant setup failed'
    ! root_capture_payload_contract_is_closed "$producer_weak_symlink_mutant" ||
        fail 'root capture producer admitted an unbracketed symlink target read'
    local producer_directory_descent='        if ($kind eq "directory") {'
    local producer_symlink_descent='        if ($kind eq "directory" || $kind eq "symlink") {'
    local producer_symlink_descent_mutant="${ROOT_CAPTURE_COMMAND/$producer_directory_descent/$producer_symlink_descent}"
    [[ "$producer_symlink_descent_mutant" != "$ROOT_CAPTURE_COMMAND" ]] ||
        fail 'root-capture symlink-descent mutant setup failed'
    ! root_capture_payload_contract_is_closed "$producer_symlink_descent_mutant" ||
        fail 'root capture producer admitted descent through a symlink'
    local producer_cdhash='^CDHash=af8181f6c0e81fc5824d1b9ff36dbb36a25ad18b$'
    local generic_producer_cdhash='^CDHash=[0-9a-f]{40}$'
    local generic_producer_cdhash_mutant="${ROOT_CAPTURE_COMMAND/$producer_cdhash/$generic_producer_cdhash}"
    [[ "$generic_producer_cdhash_mutant" != "$ROOT_CAPTURE_COMMAND" ]] ||
        fail 'generic root-capture CDHash mutant setup failed'
    ! root_capture_payload_contract_is_closed "$generic_producer_cdhash_mutant" ||
        fail 'root capture producer admitted a generic rather than exact CDHash'
    local producer_historical_code_directory='^CodeDirectory v=20400 size=12042 flags=0x0[(]none[)] hashes=369[+]3 location=embedded$'
    local missing_producer_runtime='^CodeDirectory .*$'
    local missing_producer_runtime_mutant="${ROOT_CAPTURE_COMMAND/$producer_historical_code_directory/$missing_producer_runtime}"
    [[ "$missing_producer_runtime_mutant" != "$ROOT_CAPTURE_COMMAND" ]] ||
        fail 'generic root-capture CodeDirectory mutant setup failed'
    ! root_capture_payload_contract_is_closed "$missing_producer_runtime_mutant" ||
        fail 'root capture producer admitted an unpinned historical CodeDirectory identity'

    local exact_install_destination=$'    /usr/bin/install -o root -g wheel -m 0500 "$trial_stage_controller" \\\n        "$trial_root_fresh_controller"'
    local wrong_install_destination=$'    /usr/bin/install -o root -g wheel -m 0500 "$trial_stage_controller" \\\n        "$trial_root_evidence_fourth/opensteamer-local-mono-trial-controller"'
    local wrong_install_mutant="${ROOT_BOOTSTRAP_COMMAND/$exact_install_destination/$wrong_install_destination}"
    [[ "$wrong_install_mutant" != "$ROOT_BOOTSTRAP_COMMAND" ]] ||
        fail 'wrong root-controller install destination mutant setup failed'
    ! root_retry_payload_contract_is_closed "$wrong_install_mutant" ||
        fail 'root retry contract admitted an install into preserved evidence'
    local inherited_prepare_line='    fcntl($lease, 2, 0) or exit 127;'
    local dropped_prepare_line='    close($lease);'
    local dropped_prepare_lease_mutant="${ROOT_BOOTSTRAP_COMMAND/$inherited_prepare_line/$dropped_prepare_line}"
    [[ "$dropped_prepare_lease_mutant" != "$ROOT_BOOTSTRAP_COMMAND" ]] ||
        fail 'prepare-child lease-drop mutant setup failed'
    ! root_phase_lease_contract_is_closed "$dropped_prepare_lease_mutant" ||
        fail 'root-phase contract admitted wrapper death with an unleased prepare child'
    local supervisor_branch='if ($supervisor == 0) {'
    local unleased_supervisor_branch=$'if ($supervisor == 0) {\n    close($lease);'
    local dropped_supervisor_lease_mutant="${ROOT_BOOTSTRAP_COMMAND/$supervisor_branch/$unleased_supervisor_branch}"
    [[ "$dropped_supervisor_lease_mutant" != "$ROOT_BOOTSTRAP_COMMAND" ]] ||
        fail 'supervisor lease-drop mutant setup failed'
    ! root_phase_lease_contract_is_closed "$dropped_supervisor_lease_mutant" ||
        fail 'root-phase contract admitted wrapper death with an unleased supervisor'
    local broker_go_then_close=$'        my $go_count = sysread($go_read, $go, 1);\n        exit 126 unless defined($go_count) && $go_count == 1 && $go eq "G";\n        close($go_read);\n        close($lease);'
    local broker_close_then_go=$'        close($lease);\n        my $go_count = sysread($go_read, $go, 1);\n        exit 126 unless defined($go_count) && $go_count == 1 && $go eq "G";\n        close($go_read);'
    local early_broker_release_mutant="${ROOT_BOOTSTRAP_COMMAND/$broker_go_then_close/$broker_close_then_go}"
    [[ "$early_broker_release_mutant" != "$ROOT_BOOTSTRAP_COMMAND" ]] ||
        fail 'pre-ACK broker lease-release mutant setup failed'
    ! root_phase_lease_contract_is_closed "$early_broker_release_mutant" ||
        fail 'root-phase contract admitted broker lease release before PID/ACK/GO'
    local scalar_handoff_line='    exec("/bin/sh", "-c", $inner_payload, "opensteamer-root-phase");'
    local stream_handoff_lines=$'    open(STDIN, "<&", \\*DATA) or exit 127;\n    exec("/bin/sh", "-s");'
    local stream_handoff_mutant="${ROOT_BOOTSTRAP_COMMAND/$scalar_handoff_line/$stream_handoff_lines}"
    [[ "$stream_handoff_mutant" != "$ROOT_BOOTSTRAP_COMMAND" ]] ||
        fail 'buffered DATA stream handoff mutant setup failed'
    ! root_phase_lease_contract_is_closed "$stream_handoff_mutant" ||
        fail 'root-phase contract admitted a buffered DATA/STDIN payload handoff'
    local exact_inner_length='defined($inner_payload) && length($inner_payload) == 60624 &&'
    local unbound_inner_length='defined($inner_payload) && length($inner_payload) > 0 &&'
    local unbound_inner_mutant="${ROOT_BOOTSTRAP_COMMAND/$exact_inner_length/$unbound_inner_length}"
    [[ "$unbound_inner_mutant" != "$ROOT_BOOTSTRAP_COMMAND" ]] ||
        fail 'unbound inner-payload length mutant setup failed'
    ! root_phase_lease_contract_is_closed "$unbound_inner_mutant" ||
        fail 'root-phase contract admitted an unbound inner payload'
    local bounded_fallback='    while (time() < $fallback_deadline) {'
    local unbounded_fallback='    while (1) {'
    local unbounded_fallback_mutant="${ROOT_BOOTSTRAP_COMMAND/$bounded_fallback/$unbounded_fallback}"
    [[ "$unbounded_fallback_mutant" != "$ROOT_BOOTSTRAP_COMMAND" ]] ||
        fail 'unbounded supervisor-failure fallback mutant setup failed'
    ! root_phase_lease_contract_is_closed "$unbounded_fallback_mutant" ||
        fail 'root-phase contract admitted an unbounded supervisor-failure fallback'
    local bounded_fallback_deadline='    my $fallback_deadline = time() + 20;'
    local stretched_fallback_deadline='    my $fallback_deadline = time() + 2000;'
    local stretched_fallback_mutant="${ROOT_BOOTSTRAP_COMMAND/$bounded_fallback_deadline/$stretched_fallback_deadline}"
    [[ "$stretched_fallback_mutant" != "$ROOT_BOOTSTRAP_COMMAND" ]] ||
        fail 'stretched supervisor-failure deadline mutant setup failed'
    ! root_phase_lease_contract_is_closed "$stretched_fallback_mutant" ||
        fail 'root-phase contract admitted an unreviewed supervisor-failure deadline'
    local safe_command_close=$'            my $command_ok = close($pipe);\n            undef($command_pid);\n            $command_ok or die "command failed\\n";'
    local stale_command_pid_close=$'            close($pipe) or die "command failed\\n";\n            undef($command_pid);'
    local stale_command_pid_mutant="${ROOT_BOOTSTRAP_COMMAND/$safe_command_close/$stale_command_pid_close}"
    [[ "$stale_command_pid_mutant" != "$ROOT_BOOTSTRAP_COMMAND" ]] ||
        fail 'post-reap stale command-PID mutant setup failed'
    ! root_phase_lease_contract_is_closed "$stale_command_pid_mutant" ||
        fail 'root-phase contract admitted signal authority after command Child reap'
    local retained_command_guard=$'        my $wait_result = waitpid($command_pid, POSIX::WNOHANG());\n        if ($wait_result == 0) {\n            kill(9, $command_pid);\n            waitpid($command_pid, 0);\n        }'
    local stale_command_signal=$'        kill(9, $command_pid);\n        waitpid($command_pid, 0);'
    local stale_command_signal_mutant="${ROOT_BOOTSTRAP_COMMAND/$retained_command_guard/$stale_command_signal}"
    [[ "$stale_command_signal_mutant" != "$ROOT_BOOTSTRAP_COMMAND" ]] ||
        fail 'post-close retained-Child guard mutant setup failed'
    ! root_phase_lease_contract_is_closed "$stale_command_signal_mutant" ||
        fail 'root-phase contract admitted a post-close signal without WNOHANG ownership proof'
    local exact_visible_accept=$'            if (!$preexec_kill_sent && $uid eq "0" &&\n                $pgid eq "$broker_pid" && $comm eq $controller) {\n                $broker_accepted = 1;\n                last;\n            }'
    local exact_visible_kill=$'            if (!$preexec_kill_sent && $uid eq "0" &&\n                $pgid eq "$broker_pid" && $comm eq $controller) {\n                kill(9, $broker_pid);\n                last;\n            }'
    local exact_visible_kill_mutant="${ROOT_BOOTSTRAP_COMMAND/$exact_visible_accept/$exact_visible_kill}"
    [[ "$exact_visible_kill_mutant" != "$ROOT_BOOTSTRAP_COMMAND" ]] ||
        fail 'exact-visible broker kill mutant setup failed'
    ! root_phase_lease_contract_is_closed "$exact_visible_kill_mutant" ||
        fail 'root-phase contract admitted killing an exact visible broker'
    local fail_closed_resolution='    while (1) {'
    local unresolved_release='    exit 1;'
    local unresolved_release_mutant="${ROOT_BOOTSTRAP_COMMAND/$fail_closed_resolution/$unresolved_release}"
    [[ "$unresolved_release_mutant" != "$ROOT_BOOTSTRAP_COMMAND" ]] ||
        fail 'unresolved broker release mutant setup failed'
    ! root_phase_lease_contract_is_closed "$unresolved_release_mutant" ||
        fail 'root-phase contract admitted releasing the lease on unresolved broker identity'
    local exact_zombie_proof=$'            exit 1 if $uid eq "0" &&\n                ($pgid eq "$broker_pid" || $pgid eq $broker_initial_pgid) &&\n                ($comm eq $controller || $comm eq "/usr/bin/perl") &&\n                $state =~ /\\AZ[+<NXLs]*\\z/;'
    local weak_zombie_proof=$'            exit 1 if $uid eq "0" &&\n                $state =~ /\\AZ/;'
    local weak_zombie_mutant="${ROOT_BOOTSTRAP_COMMAND/$exact_zombie_proof/$weak_zombie_proof}"
    [[ "$weak_zombie_mutant" != "$ROOT_BOOTSTRAP_COMMAND" ]] ||
        fail 'weak zombie-generation mutant setup failed'
    ! root_phase_lease_contract_is_closed "$weak_zombie_mutant" ||
        fail 'root-phase contract admitted an unbound zombie terminal proof'
    local two_absent_terminal='            exit 1 if $terminal_absent_samples == 2;'
    local one_absent_release='            exit 1 if $terminal_absent_samples == 1;'
    local one_absent_mutant="${ROOT_BOOTSTRAP_COMMAND/$two_absent_terminal/$one_absent_release}"
    [[ "$one_absent_mutant" != "$ROOT_BOOTSTRAP_COMMAND" ]] ||
        fail 'single-absence terminal mutant setup failed'
    ! root_phase_lease_contract_is_closed "$one_absent_mutant" ||
        fail 'root-phase contract admitted lease release after one absence sample'

    local delete_program='/bin/'
    delete_program+='r'
    delete_program+='m'
    local alias_delete_mutant="$ROOT_BOOTSTRAP_COMMAND"$'\n'"$delete_program"$' -rf -- "$trial_root_evidence"\n'
    ! root_payload_mutations_are_closed "$alias_delete_mutant" ||
        fail 'root mutation contract admitted an evidence-alias delete mutant'
    local find_delete_mutant="$ROOT_BOOTSTRAP_COMMAND"$'\n/usr/bin/find "$trial_root_evidence" -exec '"$delete_program"$' -f -- {} \\;\n'
    ! root_payload_mutations_are_closed "$find_delete_mutant" ||
        fail 'root mutation contract admitted an indirect evidence-delete mutant'
    local evidence_redirection_mutant="$ROOT_BOOTSTRAP_COMMAND"$'\n: > "$trial_root_evidence_fourth/root-broker.log"\n'
    ! root_payload_mutations_are_closed "$evidence_redirection_mutant" ||
        fail 'root mutation contract admitted an evidence-alias write-redirection mutant'
    local indirect_move_mutant="$ROOT_BOOTSTRAP_COMMAND"$'\n/usr/bin/env /bin/mv "$trial_root_evidence_fourth" /tmp/stolen-root-evidence\n'
    ! root_payload_mutations_are_closed "$indirect_move_mutant" ||
        fail 'root mutation contract admitted an env-wrapped evidence move mutant'
    local quoted_move_mutant="$ROOT_BOOTSTRAP_COMMAND"$'\n"/bin/mv" "$trial_root_evidence_fourth" /tmp/stolen-root-evidence\n'
    ! root_payload_mutations_are_closed "$quoted_move_mutant" ||
        fail 'root mutation contract admitted a quoted evidence move mutant'
    local quoted_delete_mutant="$ROOT_BOOTSTRAP_COMMAND"$'\n"/bin/rm" -rf -- "$trial_root_evidence_fourth"\n'
    ! root_payload_mutations_are_closed "$quoted_delete_mutant" ||
        fail 'root mutation contract admitted a quoted evidence delete mutant'
    local pipeline_write_mutant="$ROOT_BOOTSTRAP_COMMAND"$'\n/usr/bin/printf x | /usr/bin/tee "$trial_root_evidence_fourth/root-broker.log"\n'
    ! root_payload_mutations_are_closed "$pipeline_write_mutant" ||
        fail 'root mutation contract admitted a pipeline evidence-write mutant'
    local readwrite_redirection_mutant="$ROOT_BOOTSTRAP_COMMAND"$'\n: <> "/Applications/AudioStreamer Host.app/Contents/MacOS/CaptureServer"\n'
    ! root_payload_mutations_are_closed "$readwrite_redirection_mutant" ||
        fail 'root mutation contract admitted a protected-runtime read/write-open mutant'
    local xattr_write_mutant="$ROOT_BOOTSTRAP_COMMAND"$'\n/usr/bin/xattr -w incident modified "$trial_root_evidence_fourth"\n'
    ! root_payload_mutations_are_closed "$xattr_write_mutant" ||
        fail 'root mutation contract admitted an evidence xattr-write mutant'
    local chflags_mutant="$ROOT_BOOTSTRAP_COMMAND"$'\ncommand /usr/bin/chflags hidden "$trial_root_evidence_fourth"\n'
    ! root_payload_mutations_are_closed "$chflags_mutant" ||
        fail 'root mutation contract admitted an evidence chflags mutant'

    local q4_boundary='    require_d1_root_support "$trial_root_evidence_fourth"'
    local missing_q4_mutant="${ROOT_BOOTSTRAP_COMMAND/$q4_boundary/    :}"
    [[ "$missing_q4_mutant" != "$ROOT_BOOTSTRAP_COMMAND" ]] ||
        fail 'missing-q4-boundary mutant setup failed'
    ! root_retry_payload_contract_is_closed "$missing_q4_mutant" ||
        fail 'root retry contract admitted an unvalidated q4 evidence boundary'
    local u3_boundary='    require_u3_user_evidence_root'
    local missing_u3_mutant="${ROOT_BOOTSTRAP_COMMAND/$u3_boundary/    :}"
    [[ "$missing_u3_mutant" != "$ROOT_BOOTSTRAP_COMMAND" ]] ||
        fail 'missing-U3-boundary mutant setup failed'
    ! root_retry_payload_contract_is_closed "$missing_u3_mutant" ||
        fail 'root retry contract admitted an unvalidated U3 evidence boundary'
    local ready_absence='    [ ! -e "$trial_user_stage_ready" ] && [ ! -L "$trial_user_stage_ready" ]'
    local missing_ready_absence_mutant="${ROOT_BOOTSTRAP_COMMAND/$ready_absence/    :}"
    [[ "$missing_ready_absence_mutant" != "$ROOT_BOOTSTRAP_COMMAND" ]] ||
        fail 'missing-new-ready-boundary mutant setup failed'
    ! root_retry_payload_contract_is_closed "$missing_ready_absence_mutant" ||
        fail 'root retry contract admitted a missing new-ready absence fence'
    local q5_move='    /bin/mv -n "$trial_root_support" "$trial_root_evidence_fifth"'
    local q4_move='    /bin/mv -n "$trial_root_support" "$trial_root_evidence_fourth"'
    local wrong_q5_move_mutant="${ROOT_BOOTSTRAP_COMMAND/$q5_move/$q4_move}"
    [[ "$wrong_q5_move_mutant" != "$ROOT_BOOTSTRAP_COMMAND" ]] ||
        fail 'wrong-q5-publication mutant setup failed'
    ! root_retry_payload_contract_is_closed "$wrong_q5_move_mutant" ||
        fail 'root retry contract admitted publication over historical q4 evidence'
    local post_q5_proof=$'    require_failed_loopback_root_support "$trial_root_evidence_fifth"\n    require_fresh_root_support "$trial_root_fresh"\n    /bin/sync\n    require_failed_loopback_preservation_boundary'
    local missing_post_q5_proof=$'    :\n    require_fresh_root_support "$trial_root_fresh"\n    /bin/sync\n    require_failed_loopback_preservation_boundary'
    local missing_post_q5_mutant="${ROOT_BOOTSTRAP_COMMAND/$post_q5_proof/$missing_post_q5_proof}"
    [[ "$missing_post_q5_mutant" != "$ROOT_BOOTSTRAP_COMMAND" ]] ||
        fail 'missing-post-q5-proof mutant setup failed'
    ! root_retry_payload_contract_is_closed "$missing_post_q5_mutant" ||
        fail 'root retry contract admitted a missing post-q5 proof'
    local r1_sync_and_boundary=$'    /bin/sync\n    require_failed_loopback_preservation_boundary\n    require_failed_loopback_root_support "$trial_root_support"'
    local r1_missing_sync=$'    :\n    require_failed_loopback_preservation_boundary\n    require_failed_loopback_root_support "$trial_root_support"'
    local missing_r1_sync_mutant="${ROOT_BOOTSTRAP_COMMAND/$r1_sync_and_boundary/$r1_missing_sync}"
    [[ "$missing_r1_sync_mutant" != "$ROOT_BOOTSTRAP_COMMAND" ]] ||
        fail 'missing-R1-prepublication-sync mutant setup failed'
    ! root_retry_payload_contract_is_closed "$missing_r1_sync_mutant" ||
        fail 'root retry contract admitted a missing R1 prepublication sync'
    local r0_partial_token='        trial_quarantine_state="R0"'
    local r0_partial_reject='        require_fresh_root_support "$trial_root_fresh"'
    local partial_r0_mutant="${ROOT_BOOTSTRAP_COMMAND/$r0_partial_token/$r0_partial_reject}"
    [[ "$partial_r0_mutant" != "$ROOT_BOOTSTRAP_COMMAND" ]] ||
        fail 'partial-R0-restart mutant setup failed'
    ! root_retry_payload_contract_is_closed "$partial_r0_mutant" ||
        fail 'root retry contract admitted loss of safe partial R0 convergence'

    launcher_auth_dispatch_contract_is_closed "$launcher_source" ||
        fail 'authorization marker, retry dispatch, or cleanup order changed'
    launcher_compile_output_contract_is_closed "$launcher_source" ||
        fail 'controller build output is not the reviewed relative deterministic path'
    launcher_failed_loopback_user_lattice_contract_is_closed \
        "$launcher_source" "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'failed-loopback E0-E2 user lattice is not atomically published and restart-safe'
    launcher_failed_loopback_root_lattice_contract_is_closed "$launcher_source" ||
        fail 'failed-loopback public R0-R3 root classifier contract changed'
    launcher_singleton_lock_contract_is_closed "$launcher_source" ||
        fail 'live launcher singleton lock acquisition or hold order changed'
    local marker_name='AUTHORIZATION_ATTEMPTED'
    local marker_line="    ${marker_name}=1"
    local original_bootstrap_body missing_marker_body missing_marker_mutant
    original_bootstrap_body=$(print -rn -- "$launcher_source" | /usr/bin/sed -n \
        '/^bootstrap_root_broker_once() {$/,/^}$/p')
    missing_marker_body="${original_bootstrap_body/$marker_line/    :}"
    [[ "$missing_marker_body" != "$original_bootstrap_body" ]] ||
        fail 'missing authorization-marker mutant setup failed'
    missing_marker_mutant="${launcher_source/$original_bootstrap_body/$missing_marker_body}"
    [[ "$missing_marker_mutant" != "$launcher_source" ]] ||
        fail 'missing authorization-marker source mutant setup failed'
    ! launcher_auth_dispatch_contract_is_closed "$missing_marker_mutant" ||
        fail 'authorization contract admitted a missing marker mutant'
    local root_pid_check='    [[ "$root_pid" == <-> ]] || fail '\''authorized root broker returned a malformed PID'\'''
    local late_marker_body="${missing_marker_body/$root_pid_check/$marker_line$'\n'$root_pid_check}"
    local late_marker_mutant="${launcher_source/$original_bootstrap_body/$late_marker_body}"
    ! launcher_auth_dispatch_contract_is_closed "$late_marker_mutant" ||
        fail 'authorization contract admitted a late marker mutant'
    local cleanup_mutant="$launcher_source"$'\ncleanup() {\n    /bin/rm -rf -- "$TRIAL_ROOT"\n}\n'
    ! launcher_auth_dispatch_contract_is_closed "$cleanup_mutant" ||
        fail 'authorization contract admitted destructive canonical-stage EXIT cleanup'
    local original_stage_body original_advance_body original_user_classifier_body
    local original_composite_body direct_stage_body_mutant direct_stage_mutant
    original_stage_body=$(print -rn -- "$launcher_source" | /usr/bin/sed -n \
        '/^stage_live_one_shot() {$/,/^}$/p')
    original_advance_body=$(print -rn -- "$launcher_source" | /usr/bin/sed -n \
        '/^advance_failed_loopback_user_state() {$/,/^}$/p')
    original_user_classifier_body=$(print -rn -- "$launcher_source" | /usr/bin/sed -n \
        '/^classify_failed_loopback_user_state() {$/,/^}$/p')
    original_composite_body=$(print -rn -- "$launcher_source" | /usr/bin/sed -n \
        '/^classify_retry_state() {$/,/^}$/p')
    local -a user_gate_tokens user_gate_weakenings
    user_gate_tokens=(
        '    require_data_volume_identity'
        '    [[ ! -e "$ACTIVE_POINTER" && ! -L "$ACTIVE_POINTER" &&'
        '       ! -e "$ACTIVE_POINTER_TEMP" && ! -L "$ACTIVE_POINTER_TEMP" &&'
        '       ! -e "$PRODUCT_DRIVER" && ! -L "$PRODUCT_DRIVER" &&'
        '       ! -e "$LEGACY_USER_STAGE_READY_ROOT" && ! -L "$LEGACY_USER_STAGE_READY_ROOT" ]] ||'
        '    require_preserved_failed_uid_admission_user_evidence'
        '    require_preserved_failed_candidate_user_evidence'
        '    require_preserved_rescued_user_evidence'
        '    [[ -e "$TRIAL_ROOT" || -L "$TRIAL_ROOT" ]] && canonical_present=1'
        '    [[ -e "$FAILED_LOOPBACK_TRIAL_ROOT" || -L "$FAILED_LOOPBACK_TRIAL_ROOT" ]] &&'
        '    [[ -e "$USER_STAGE_READY_ROOT" || -L "$USER_STAGE_READY_ROOT" ]] && ready_present=1'
    )
    user_gate_weakenings=(
        '    :'
        '    [[ true &&'
        '       true &&'
        '       true &&'
        '       true ]] ||'
        '    :'
        '    :'
        '    :'
        '    :'
        '    [[ false ]] &&'
        '    :'
    )
    local gate_index weakened_user_classifier user_gate_mutant
    for (( gate_index = 1; gate_index <= ${#user_gate_tokens[@]}; gate_index++ )); do
        weakened_user_classifier="${original_user_classifier_body/${user_gate_tokens[$gate_index]}/${user_gate_weakenings[$gate_index]}}"
        [[ "$weakened_user_classifier" != "$original_user_classifier_body" ]] ||
            fail 'user-classifier baseline-gate mutant setup failed'
        user_gate_mutant="${launcher_source/$original_user_classifier_body/$weakened_user_classifier}"
        ! launcher_failed_loopback_user_lattice_contract_is_closed \
            "$user_gate_mutant" "$ROOT_BOOTSTRAP_COMMAND" ||
            fail 'failed-loopback user lattice admitted a missing baseline or topology probe'
    done
    local user_topology_fail="        fail 'failed-loopback user retry state is not exact E0, E1, or E2'"
    local user_topology_return='        return 0'
    local user_fail_open_body="${original_user_classifier_body/$user_topology_fail/$user_topology_return}"
    [[ "$user_fail_open_body" != "$original_user_classifier_body" ]] ||
        fail 'user-classifier fail-open mutant setup failed'
    local user_fail_open_mutant="${launcher_source/$original_user_classifier_body/$user_fail_open_body}"
    ! launcher_failed_loopback_user_lattice_contract_is_closed \
        "$user_fail_open_mutant" "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'failed-loopback user lattice admitted a fail-open unknown topology'
    local composite_topology_fail="            fail 'failed-loopback composite retry state is outside the E0-E2/R0-R3 lattice'"
    local composite_topology_return='            return 0'
    local composite_fail_open_body="${original_composite_body/$composite_topology_fail/$composite_topology_return}"
    [[ "$composite_fail_open_body" != "$original_composite_body" ]] ||
        fail 'composite-classifier fail-open mutant setup failed'
    local composite_fail_open_mutant="${launcher_source/$original_composite_body/$composite_fail_open_body}"
    ! launcher_failed_loopback_user_lattice_contract_is_closed \
        "$composite_fail_open_mutant" "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'failed-loopback composite lattice admitted a fail-open unknown pairing'
    local private_identity_capture='        private_publish_identity="$(/usr/bin/stat -f '\''%d:%i'\'' "$publish_root")"'
    local forged_private_identity='        private_publish_identity="0:0"'
    local forged_private_stage="${original_stage_body/$private_identity_capture/$forged_private_identity}"
    [[ "$forged_private_stage" != "$original_stage_body" ]] ||
        fail 'forged-private-stage-identity mutant setup failed'
    local forged_private_mutant="${launcher_source/$original_stage_body/$forged_private_stage}"
    ! launcher_failed_loopback_user_lattice_contract_is_closed \
        "$forged_private_mutant" "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'failed-loopback user lattice admitted a forged private-stage identity'
    local failed_identity_capture='        failed_identity="$(/usr/bin/stat -f '\''%d:%i'\'' "$TRIAL_ROOT")"'
    local forged_failed_identity='        failed_identity="0:0"'
    local forged_failed_advance="${original_advance_body/$failed_identity_capture/$forged_failed_identity}"
    [[ "$forged_failed_advance" != "$original_advance_body" ]] ||
        fail 'forged-U3-source-identity mutant setup failed'
    local forged_failed_mutant="${launcher_source/$original_advance_body/$forged_failed_advance}"
    ! launcher_failed_loopback_user_lattice_contract_is_closed \
        "$forged_failed_mutant" "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'failed-loopback user lattice admitted a forged U3 source identity'
    local ready_identity_capture='        ready_identity="$(/usr/bin/stat -f '\''%d:%i'\'' "$USER_STAGE_READY_ROOT")"'
    local forged_ready_identity='        ready_identity="0:0"'
    local forged_ready_advance="${original_advance_body/$ready_identity_capture/$forged_ready_identity}"
    [[ "$forged_ready_advance" != "$original_advance_body" ]] ||
        fail 'forged-ready-source-identity mutant setup failed'
    local forged_ready_mutant="${launcher_source/$original_advance_body/$forged_ready_advance}"
    ! launcher_failed_loopback_user_lattice_contract_is_closed \
        "$forged_ready_mutant" "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'failed-loopback user lattice admitted a forged ready-stage identity'
    local ready_race_guard=$'        [[ ! -e "$USER_STAGE_READY_ROOT" && ! -L "$USER_STAGE_READY_ROOT" ]] ||\n            fail '\''fixed ready pre-root user-stage path raced publication'\'''
    local missing_ready_race_guard='        :'
    local raced_ready_stage="${original_stage_body/$ready_race_guard/$missing_ready_race_guard}"
    [[ "$raced_ready_stage" != "$original_stage_body" ]] ||
        fail 'ready-stage race-guard mutant setup failed'
    local raced_ready_mutant="${launcher_source/$original_stage_body/$raced_ready_stage}"
    ! launcher_failed_loopback_user_lattice_contract_is_closed \
        "$raced_ready_mutant" "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'failed-loopback user lattice admitted a missing ready destination race guard'
    local advance_entry_lock='    require_launcher_lock_held'
    local extra_move_before_lock=$'    /bin/mv -f "$TRIAL_ROOT" "$USER_STAGE_READY_ROOT"\n    require_launcher_lock_held'
    local extra_move_advance="${original_advance_body/$advance_entry_lock/$extra_move_before_lock}"
    [[ "$extra_move_advance" != "$original_advance_body" ]] ||
        fail 'extra-move-before-lock mutant setup failed'
    local extra_move_mutant="${launcher_source/$original_advance_body/$extra_move_advance}"
    ! launcher_failed_loopback_user_lattice_contract_is_closed \
        "$extra_move_mutant" "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'failed-loopback user lattice admitted an extra nonexclusive move'
    direct_stage_body_mutant="${original_stage_body/\/bin\/mkdir \"\$publish_root\"/\/bin\/mkdir \"\$TRIAL_ROOT\"}"
    [[ "$direct_stage_body_mutant" != "$original_stage_body" ]] ||
        fail 'direct-canonical-stage mutant setup failed'
    direct_stage_mutant="${launcher_source/$original_stage_body/$direct_stage_body_mutant}"
    ! launcher_failed_loopback_user_lattice_contract_is_closed \
        "$direct_stage_mutant" "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'failed-loopback user lattice admitted direct canonical construction'
    local ready_resume_guard='    if [[ ! -e "$USER_STAGE_READY_ROOT" && ! -L "$USER_STAGE_READY_ROOT" ]]; then'
    local ready_resume_body_mutant="${original_stage_body/$ready_resume_guard/    if true; then}"
    [[ "$ready_resume_body_mutant" != "$original_stage_body" ]] ||
        fail 'ready-stage resume mutant setup failed'
    local ready_resume_mutant="${launcher_source/$original_stage_body/$ready_resume_body_mutant}"
    ! launcher_failed_loopback_user_lattice_contract_is_closed \
        "$ready_resume_mutant" "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'failed-loopback user lattice admitted rebuilding over a published ready tree'
    local u3_move='        /bin/mv -n "$TRIAL_ROOT" "$FAILED_LOOPBACK_TRIAL_ROOT"'
    local wrong_u3_move='        /bin/mv -n "$TRIAL_ROOT" "$RESCUED_TRIAL_ROOT"'
    local wrong_u3_advance="${original_advance_body/$u3_move/$wrong_u3_move}"
    [[ "$wrong_u3_advance" != "$original_advance_body" ]] ||
        fail 'wrong-U3-publication mutant setup failed'
    local wrong_u3_mutant="${launcher_source/$original_advance_body/$wrong_u3_advance}"
    ! launcher_failed_loopback_user_lattice_contract_is_closed \
        "$wrong_u3_mutant" "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'failed-loopback user lattice admitted publication over historical U2 evidence'
    local canonical_move='        /bin/mv -n "$USER_STAGE_READY_ROOT" "$TRIAL_ROOT"'
    local destructive_canonical='        /bin/rm -rf -- "$USER_STAGE_READY_ROOT"'
    local destructive_advance="${original_advance_body/$canonical_move/$destructive_canonical}"
    [[ "$destructive_advance" != "$original_advance_body" ]] ||
        fail 'destructive-canonical-publication mutant setup failed'
    local destructive_advance_mutant="${launcher_source/$original_advance_body/$destructive_advance}"
    ! launcher_failed_loopback_user_lattice_contract_is_closed \
        "$destructive_advance_mutant" "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'failed-loopback user lattice admitted destructive canonical publication'
    local e1_tuple='    elif (( canonical_present == 0 && evidence_present == 1 && ready_present == 1 )); then'
    local weak_e1_tuple='    elif (( canonical_present == 0 && evidence_present == 1 )); then'
    local weak_classifier="${original_user_classifier_body/$e1_tuple/$weak_e1_tuple}"
    [[ "$weak_classifier" != "$original_user_classifier_body" ]] ||
        fail 'weak-E1-tuple mutant setup failed'
    local weak_classifier_mutant="${launcher_source/$original_user_classifier_body/$weak_classifier}"
    ! launcher_failed_loopback_user_lattice_contract_is_closed \
        "$weak_classifier_mutant" "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'failed-loopback user lattice admitted a nonexact E1 topology'
    local e2_tuple='    elif (( canonical_present == 1 && evidence_present == 1 && ready_present == 0 )); then'
    local weak_e2_tuple='    elif (( canonical_present == 1 && evidence_present == 1 )); then'
    local weak_e2_classifier="${original_user_classifier_body/$e2_tuple/$weak_e2_tuple}"
    [[ "$weak_e2_classifier" != "$original_user_classifier_body" ]] ||
        fail 'weak-E2-tuple mutant setup failed'
    local weak_e2_classifier_mutant="${launcher_source/$original_user_classifier_body/$weak_e2_classifier}"
    ! launcher_failed_loopback_user_lattice_contract_is_closed \
        "$weak_e2_classifier_mutant" "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'failed-loopback user lattice admitted a nonexact E2 topology'
    local e0_failed_proof=$'    if (( canonical_present == 1 && evidence_present == 0 )); then\n        require_failed_loopback_user_trial_at "$TRIAL_ROOT"'
    local missing_e0_failed=$'    if (( canonical_present == 1 && evidence_present == 0 )); then\n        :'
    local missing_e0_failed_body="${original_user_classifier_body/$e0_failed_proof/$missing_e0_failed}"
    [[ "$missing_e0_failed_body" != "$original_user_classifier_body" ]] ||
        fail 'missing-E0-failed-validator mutant setup failed'
    local missing_e0_failed_mutant="${launcher_source/$original_user_classifier_body/$missing_e0_failed_body}"
    ! launcher_failed_loopback_user_lattice_contract_is_closed \
        "$missing_e0_failed_mutant" "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'failed-loopback user lattice admitted an unvalidated E0 canonical failure'
    local e0_ready_proof=$'        if (( ready_present == 1 )); then\n            require_complete_pre_root_user_stage_at "$USER_STAGE_READY_ROOT"'
    local missing_e0_ready=$'        if (( ready_present == 1 )); then\n            :'
    local missing_e0_ready_body="${original_user_classifier_body/$e0_ready_proof/$missing_e0_ready}"
    [[ "$missing_e0_ready_body" != "$original_user_classifier_body" ]] ||
        fail 'missing-E0-ready-validator mutant setup failed'
    local missing_e0_ready_mutant="${launcher_source/$original_user_classifier_body/$missing_e0_ready_body}"
    ! launcher_failed_loopback_user_lattice_contract_is_closed \
        "$missing_e0_ready_mutant" "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'failed-loopback user lattice admitted an unvalidated E0 ready stage'
    local e1_proofs=$'    elif (( canonical_present == 0 && evidence_present == 1 && ready_present == 1 )); then\n        require_failed_loopback_user_trial_at "$FAILED_LOOPBACK_TRIAL_ROOT"\n        require_complete_pre_root_user_stage_at "$USER_STAGE_READY_ROOT"'
    local missing_e1_u3=$'    elif (( canonical_present == 0 && evidence_present == 1 && ready_present == 1 )); then\n        :\n        require_complete_pre_root_user_stage_at "$USER_STAGE_READY_ROOT"'
    local missing_e1_u3_body="${original_user_classifier_body/$e1_proofs/$missing_e1_u3}"
    [[ "$missing_e1_u3_body" != "$original_user_classifier_body" ]] ||
        fail 'missing-E1-U3-validator mutant setup failed'
    local missing_e1_u3_mutant="${launcher_source/$original_user_classifier_body/$missing_e1_u3_body}"
    ! launcher_failed_loopback_user_lattice_contract_is_closed \
        "$missing_e1_u3_mutant" "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'failed-loopback user lattice admitted unvalidated U3 evidence in E1'
    local missing_e1_ready=$'    elif (( canonical_present == 0 && evidence_present == 1 && ready_present == 1 )); then\n        require_failed_loopback_user_trial_at "$FAILED_LOOPBACK_TRIAL_ROOT"\n        :'
    local missing_e1_ready_body="${original_user_classifier_body/$e1_proofs/$missing_e1_ready}"
    [[ "$missing_e1_ready_body" != "$original_user_classifier_body" ]] ||
        fail 'missing-E1-ready-validator mutant setup failed'
    local missing_e1_ready_mutant="${launcher_source/$original_user_classifier_body/$missing_e1_ready_body}"
    ! launcher_failed_loopback_user_lattice_contract_is_closed \
        "$missing_e1_ready_mutant" "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'failed-loopback user lattice admitted an unvalidated E1 ready stage'
    local e2_u3_proof=$'    elif (( canonical_present == 1 && evidence_present == 1 && ready_present == 0 )); then\n        require_failed_loopback_user_trial_at "$FAILED_LOOPBACK_TRIAL_ROOT"'
    local missing_e2_u3=$'    elif (( canonical_present == 1 && evidence_present == 1 && ready_present == 0 )); then\n        :'
    local missing_e2_classifier="${original_user_classifier_body/$e2_u3_proof/$missing_e2_u3}"
    [[ "$missing_e2_classifier" != "$original_user_classifier_body" ]] ||
        fail 'missing-E2-U3-validator mutant setup failed'
    local missing_e2_mutant="${launcher_source/$original_user_classifier_body/$missing_e2_classifier}"
    ! launcher_failed_loopback_user_lattice_contract_is_closed \
        "$missing_e2_mutant" "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'failed-loopback user lattice admitted unvalidated U3 evidence in E2'
    local e2_canonical_proof='        require_complete_pre_root_user_stage_at "$TRIAL_ROOT"'
    local missing_e2_canonical_body="${original_user_classifier_body/$e2_canonical_proof/        :}"
    [[ "$missing_e2_canonical_body" != "$original_user_classifier_body" ]] ||
        fail 'missing-E2-canonical-validator mutant setup failed'
    local missing_e2_canonical_mutant="${launcher_source/$original_user_classifier_body/$missing_e2_canonical_body}"
    ! launcher_failed_loopback_user_lattice_contract_is_closed \
        "$missing_e2_canonical_mutant" "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'failed-loopback user lattice admitted an unvalidated E2 canonical stage'
    local exact_composite_arm='        E0/R0|E1/R0|E2/R0|E2/R1|E2/R2|E2/R3)'
    local permissive_composite_arm='        E0/R0|E0/R1|E1/R0|E2/R0|E2/R1|E2/R2|E2/R3)'
    local permissive_composite="${original_composite_body/$exact_composite_arm/$permissive_composite_arm}"
    [[ "$permissive_composite" != "$original_composite_body" ]] ||
        fail 'permissive-composite-lattice mutant setup failed'
    local permissive_composite_mutant="${launcher_source/$original_composite_body/$permissive_composite}"
    ! launcher_failed_loopback_user_lattice_contract_is_closed \
        "$permissive_composite_mutant" "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'failed-loopback lattice admitted E0/R1'
    local permissive_e1_composite_arm='        E0/R0|E1/R0|E1/R1|E2/R0|E2/R1|E2/R2|E2/R3)'
    local permissive_e1_composite="${original_composite_body/$exact_composite_arm/$permissive_e1_composite_arm}"
    [[ "$permissive_e1_composite" != "$original_composite_body" ]] ||
        fail 'permissive-E1-composite-lattice mutant setup failed'
    local permissive_e1_composite_mutant="${launcher_source/$original_composite_body/$permissive_e1_composite}"
    ! launcher_failed_loopback_user_lattice_contract_is_closed \
        "$permissive_e1_composite_mutant" "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'failed-loopback lattice admitted E1/R1'
    local -a missing_composite_arms
    missing_composite_arms=(
        '        E1/R0|E2/R0|E2/R1|E2/R2|E2/R3)'
        '        E0/R0|E2/R0|E2/R1|E2/R2|E2/R3)'
        '        E0/R0|E1/R0|E2/R1|E2/R2|E2/R3)'
        '        E0/R0|E1/R0|E2/R0|E2/R2|E2/R3)'
        '        E0/R0|E1/R0|E2/R0|E2/R1|E2/R3)'
        '        E0/R0|E1/R0|E2/R0|E2/R1|E2/R2)'
    )
    local missing_composite_arm missing_composite_body missing_composite_mutant
    for missing_composite_arm in "${missing_composite_arms[@]}"; do
        missing_composite_body="${original_composite_body/$exact_composite_arm/$missing_composite_arm}"
        [[ "$missing_composite_body" != "$original_composite_body" ]] ||
            fail 'missing-composite-pair mutant setup failed'
        missing_composite_mutant="${launcher_source/$original_composite_body/$missing_composite_body}"
        ! launcher_failed_loopback_user_lattice_contract_is_closed \
            "$missing_composite_mutant" "$ROOT_BOOTSTRAP_COMMAND" ||
            fail 'failed-loopback lattice admitted a missing reviewed composite pair'
    done
    local first_stage_sync=$'        /bin/sync\n        require_complete_pre_root_user_stage_at "$publish_root"'
    local missing_stage_sync=$'        :\n        require_complete_pre_root_user_stage_at "$publish_root"'
    local missing_stage_sync_body="${original_stage_body/$first_stage_sync/$missing_stage_sync}"
    [[ "$missing_stage_sync_body" != "$original_stage_body" ]] ||
        fail 'missing-ready-stage-sync mutant setup failed'
    local missing_stage_sync_mutant="${launcher_source/$original_stage_body/$missing_stage_sync_body}"
    ! launcher_failed_loopback_user_lattice_contract_is_closed \
        "$missing_stage_sync_mutant" "$ROOT_BOOTSTRAP_COMMAND" ||
        fail 'failed-loopback lattice admitted a missing ready-stage sync'
    local ready_root_fence='    [ ! -e "$trial_user_stage_ready" ] && [ ! -L "$trial_user_stage_ready" ]'
    local missing_ready_root_fence="${ROOT_BOOTSTRAP_COMMAND/$ready_root_fence/    :}"
    [[ "$missing_ready_root_fence" != "$ROOT_BOOTSTRAP_COMMAND" ]] ||
        fail 'missing-ready-stage root fence mutant setup failed'
    ! launcher_failed_loopback_user_lattice_contract_is_closed \
        "$launcher_source" "$missing_ready_root_fence" ||
        fail 'failed-loopback user lattice admitted a missing authorized-root ready-stage fence'
    local original_root_classifier_body original_prior_root_body original_partial_root_body
    original_root_classifier_body=$(print -rn -- "$launcher_source" | /usr/bin/sed -n \
        '/^classify_failed_loopback_root_state() {$/,/^}$/p')
    original_prior_root_body=$(print -rn -- "$launcher_source" | /usr/bin/sed -n \
        '/^require_prior_root_evidence_public() {$/,/^}$/p')
    original_partial_root_body=$(print -rn -- "$launcher_source" | /usr/bin/sed -n \
        '/^require_public_safe_partial_fresh_root_shell() {$/,/^}$/p')
    local -a root_gate_tokens root_gate_weakenings
    root_gate_tokens=(
        '    require_data_volume_identity'
        '    [[ ! -e "$LEGACY_FRESH_ROOT_SUPPORT" && ! -L "$LEGACY_FRESH_ROOT_SUPPORT" ]] ||'
        '    [[ -e "$ROOT_SUPPORT" || -L "$ROOT_SUPPORT" ]] && canonical_present=1'
        '    [[ -e "$FAILED_LOOPBACK_ROOT_SUPPORT" || -L "$FAILED_LOOPBACK_ROOT_SUPPORT" ]] &&'
        '    [[ -e "$FRESH_ROOT_SUPPORT" || -L "$FRESH_ROOT_SUPPORT" ]] && fresh_present=1'
    )
    root_gate_weakenings=(
        '    :'
        '    [[ true ]] ||'
        '    :'
        '    [[ false ]] &&'
        '    :'
    )
    local root_gate_index weakened_root_classifier root_gate_mutant
    for (( root_gate_index = 1; root_gate_index <= ${#root_gate_tokens[@]}; root_gate_index++ )); do
        weakened_root_classifier="${original_root_classifier_body/${root_gate_tokens[$root_gate_index]}/${root_gate_weakenings[$root_gate_index]}}"
        [[ "$weakened_root_classifier" != "$original_root_classifier_body" ]] ||
            fail 'root-classifier baseline-gate mutant setup failed'
        root_gate_mutant="${launcher_source/$original_root_classifier_body/$weakened_root_classifier}"
        ! launcher_failed_loopback_root_lattice_contract_is_closed "$root_gate_mutant" ||
            fail 'failed-loopback root lattice admitted a missing baseline or topology probe'
    done
    local root_topology_fail="        fail 'failed-loopback root retry state is not exact R0, R1, R2, or R3'"
    local root_topology_return='        return 0'
    local root_fail_open_body="${original_root_classifier_body/$root_topology_fail/$root_topology_return}"
    [[ "$root_fail_open_body" != "$original_root_classifier_body" ]] ||
        fail 'root-classifier fail-open mutant setup failed'
    local root_fail_open_mutant="${launcher_source/$original_root_classifier_body/$root_fail_open_body}"
    ! launcher_failed_loopback_root_lattice_contract_is_closed "$root_fail_open_mutant" ||
        fail 'failed-loopback root lattice admitted a fail-open unknown topology'
    local public_r0='            ROOT_RETRY_STATE='\''R0'\'''
    local reject_partial_r0=$'            require_public_fresh_root_shell_at "$FRESH_ROOT_SUPPORT"\n            ROOT_RETRY_STATE='\''R0'\'''
    local reject_partial_body="${original_root_classifier_body/$public_r0/$reject_partial_r0}"
    [[ "$reject_partial_body" != "$original_root_classifier_body" ]] ||
        fail 'public-partial-R0 mutant setup failed'
    local reject_partial_mutant="${launcher_source/$original_root_classifier_body/$reject_partial_body}"
    ! launcher_failed_loopback_root_lattice_contract_is_closed "$reject_partial_mutant" ||
        fail 'public root lattice rejected safe partial fresh-root convergence in R0'
    local public_r2_proof=$'    elif (( canonical_present == 0 && evidence_present == 1 && fresh_present == 1 )); then\n        require_public_failed_loopback_root_shell_at "$FAILED_LOOPBACK_ROOT_SUPPORT"'
    local missing_public_r2_proof=$'    elif (( canonical_present == 0 && evidence_present == 1 && fresh_present == 1 )); then\n        :'
    local missing_public_r2_body="${original_root_classifier_body/$public_r2_proof/$missing_public_r2_proof}"
    [[ "$missing_public_r2_body" != "$original_root_classifier_body" ]] ||
        fail 'missing-public-R2-q5-validator mutant setup failed'
    local missing_public_r2_mutant="${launcher_source/$original_root_classifier_body/$missing_public_r2_body}"
    ! launcher_failed_loopback_root_lattice_contract_is_closed "$missing_public_r2_mutant" ||
        fail 'public root lattice admitted unvalidated q5 evidence in R2'
    local public_q4='    require_public_d1_root_shell_at "$FAILED_COREAUDIO_ROOT_SUPPORT"'
    local missing_public_q4_body="${original_prior_root_body/$public_q4/    :}"
    [[ "$missing_public_q4_body" != "$original_prior_root_body" ]] ||
        fail 'missing-public-q4-validator mutant setup failed'
    local missing_public_q4_mutant="${launcher_source/$original_prior_root_body/$missing_public_q4_body}"
    ! launcher_failed_loopback_root_lattice_contract_is_closed "$missing_public_q4_mutant" ||
        fail 'public root lattice admitted an unvalidated historical q4 boundary'
    local unexpected_partial_child='        [[ "$entry_status" == '\''1'\'' && -z "$unexpected" ]] ||'
    local permissive_partial_child='        [[ true ]] ||'
    local permissive_partial_body="${original_partial_root_body/$unexpected_partial_child/$permissive_partial_child}"
    [[ "$permissive_partial_body" != "$original_partial_root_body" ]] ||
        fail 'permissive-partial-child mutant setup failed'
    local permissive_partial_mutant="${launcher_source/$original_partial_root_body/$permissive_partial_body}"
    ! launcher_failed_loopback_root_lattice_contract_is_closed "$permissive_partial_mutant" ||
        fail 'public root lattice admitted an unexpected partial fresh-root child'
    local lock_header lock_acquire_body lock_held_body lock_runtime_tail
    lock_header="${launcher_source%%readonly ROOT_BOOTSTRAP_COMMAND=*}"
    lock_acquire_body=$(print -rn -- "$launcher_source" | /usr/bin/sed -n \
        '/^acquire_launcher_lock() {$/,/^}$/p')
    lock_held_body=$(print -rn -- "$launcher_source" | /usr/bin/sed -n \
        '/^require_launcher_lock_held() {$/,/^}$/p')
    lock_runtime_tail=$(print -rn -- "$launcher_source" | /usr/bin/sed -n \
        '/^readonly BUILD_ROOT=/,$p')
    local publish_lock_pair=$'        require_launcher_lock_held\n        /bin/mv -n "$publish_root" "$USER_STAGE_READY_ROOT"'
    local unlocked_publish_pair=$'        :\n        /bin/mv -n "$publish_root" "$USER_STAGE_READY_ROOT"'
    local unlocked_publish_stage="${original_stage_body/$publish_lock_pair/$unlocked_publish_pair}"
    [[ "$unlocked_publish_stage" != "$original_stage_body" ]] ||
        fail 'unlocked ready-stage publication mutant setup failed'
    ! launcher_singleton_lock_parts_are_closed "$lock_header" "$lock_acquire_body" \
        "$lock_held_body" "$unlocked_publish_stage" "$original_advance_body" \
        "$original_bootstrap_body" "$lock_runtime_tail" ||
        fail 'singleton contract admitted an unlocked destination-exists mv-n publication mutant'
    local early_close_pair=$'        require_launcher_lock_held\n        zsystem flock -u "$LAUNCHER_LOCK_FD"\n        /bin/mv -n "$publish_root" "$USER_STAGE_READY_ROOT"'
    local early_close_stage="${original_stage_body/$publish_lock_pair/$early_close_pair}"
    [[ "$early_close_stage" != "$original_stage_body" ]] ||
        fail 'early launcher-lock close mutant setup failed'
    ! launcher_singleton_lock_parts_are_closed "$lock_header" "$lock_acquire_body" \
        "$lock_held_body" "$early_close_stage" "$original_advance_body" \
        "$original_bootstrap_body" "$lock_runtime_tail" ||
        fail 'singleton contract admitted an early launcher-lock close mutant'
    local u3_lock_pair=$'        require_launcher_lock_held\n        /bin/mv -n "$TRIAL_ROOT" "$FAILED_LOOPBACK_TRIAL_ROOT"'
    local unlocked_u3_pair=$'        :\n        /bin/mv -n "$TRIAL_ROOT" "$FAILED_LOOPBACK_TRIAL_ROOT"'
    local unlocked_u3_advance="${original_advance_body/$u3_lock_pair/$unlocked_u3_pair}"
    [[ "$unlocked_u3_advance" != "$original_advance_body" ]] ||
        fail 'unlocked-U3-publication mutant setup failed'
    ! launcher_singleton_lock_parts_are_closed "$lock_header" "$lock_acquire_body" \
        "$lock_held_body" "$original_stage_body" "$unlocked_u3_advance" \
        "$original_bootstrap_body" "$lock_runtime_tail" ||
        fail 'singleton contract admitted U3 publication without the retained lock'
    local canonical_lock_pair=$'        require_launcher_lock_held\n        /bin/mv -n "$USER_STAGE_READY_ROOT" "$TRIAL_ROOT"'
    local unlocked_canonical_pair=$'        :\n        /bin/mv -n "$USER_STAGE_READY_ROOT" "$TRIAL_ROOT"'
    local unlocked_canonical_advance="${original_advance_body/$canonical_lock_pair/$unlocked_canonical_pair}"
    [[ "$unlocked_canonical_advance" != "$original_advance_body" ]] ||
        fail 'unlocked-canonical-publication mutant setup failed'
    ! launcher_singleton_lock_parts_are_closed "$lock_header" "$lock_acquire_body" \
        "$lock_held_body" "$original_stage_body" "$unlocked_canonical_advance" \
        "$original_bootstrap_body" "$lock_runtime_tail" ||
        fail 'singleton contract admitted canonical publication without the retained lock'
    local live_acquire_block=$'if [[ "$MODE" == "$START_MODE" || "$MODE" == "$STOP_MODE" ]]; then\n    acquire_launcher_lock\nfi'
    local start_classify_block=$'    "$START_MODE")\n        classify_retry_state'
    local late_start_classify_block=$'    "$START_MODE")\n        classify_retry_state\n        acquire_launcher_lock'
    local late_acquire_runtime="${lock_runtime_tail/$live_acquire_block/:}"
    late_acquire_runtime="${late_acquire_runtime/$start_classify_block/$late_start_classify_block}"
    [[ "$late_acquire_runtime" != "$lock_runtime_tail" ]] ||
        fail 'late singleton acquisition mutant setup failed'
    ! launcher_singleton_lock_parts_are_closed "$lock_header" "$lock_acquire_body" \
        "$lock_held_body" "$original_stage_body" "$original_advance_body" \
        "$original_bootstrap_body" "$late_acquire_runtime" ||
        fail 'singleton contract admitted acquisition after live classification'
    local inheritable_lock_line='    zsystem flock -e -t 0 -f LAUNCHER_LOCK_FD "$LAUNCHER_LOCK" 2>/dev/null'
    local normal_lock_line='    zsystem flock -t 0 -f LAUNCHER_LOCK_FD "$LAUNCHER_LOCK" 2>/dev/null'
    local inheritable_acquire="${lock_acquire_body/$normal_lock_line/$inheritable_lock_line}"
    [[ "$inheritable_acquire" != "$lock_acquire_body" ]] ||
        fail 'inheritable launcher-lock FD mutant setup failed'
    ! launcher_singleton_lock_parts_are_closed "$lock_header" "$inheritable_acquire" \
        "$lock_held_body" "$original_stage_body" "$original_advance_body" \
        "$original_bootstrap_body" "$lock_runtime_tail" ||
        fail 'singleton contract admitted an inheritable launcher-lock FD mutant'
    local second_launcher_accepting_held="${lock_held_body/probe_result == 2/probe_result == 0}"
    [[ "$second_launcher_accepting_held" != "$lock_held_body" ]] ||
        fail 'second-launch acceptance mutant setup failed'
    ! launcher_singleton_lock_parts_are_closed "$lock_header" "$lock_acquire_body" \
        "$second_launcher_accepting_held" "$original_stage_body" "$original_advance_body" \
        "$original_bootstrap_body" "$lock_runtime_tail" ||
        fail 'singleton contract admitted a second concurrent launcher'
    local descriptor_mismatch_guard="        fail 'live-launcher lock descriptor no longer names the canonical inode'"
    local descriptor_mismatch_held="${lock_held_body/$descriptor_mismatch_guard/        :}"
    [[ "$descriptor_mismatch_held" != "$lock_held_body" ]] ||
        fail 'lock descriptor/name mismatch mutant setup failed'
    ! launcher_singleton_lock_parts_are_closed "$lock_header" "$lock_acquire_body" \
        "$descriptor_mismatch_held" "$original_stage_body" "$original_advance_body" \
        "$original_bootstrap_body" "$lock_runtime_tail" ||
        fail 'singleton contract admitted an unproved lock descriptor/name match'
    local inprocess_fstat_call='zstat -H descriptor_stat -f "$LAUNCHER_LOCK_FD"'
    local external_fd_probe='descriptor_path="/dev/fd/$LAUNCHER_LOCK_FD"'
    local external_fd_held="${lock_held_body/$inprocess_fstat_call/$external_fd_probe}"
    [[ "$external_fd_held" != "$lock_held_body" ]] ||
        fail 'external CLOEXEC descriptor-probe mutant setup failed'
    ! launcher_singleton_lock_parts_are_closed "$lock_header" "$lock_acquire_body" \
        "$external_fd_held" "$original_stage_body" "$original_advance_body" \
        "$original_bootstrap_body" "$lock_runtime_tail" ||
        fail 'singleton contract admitted an external CLOEXEC descriptor probe'
    local start_advance='        advance_failed_loopback_user_state'
    local original_start_body missing_start_advance_body
    original_start_body=$(print -rn -- "$launcher_source" | /usr/bin/sed -n \
        '/^    "$START_MODE")$/,/^        ;;$/p')
    missing_start_advance_body="${original_start_body/$start_advance/        :}"
    [[ "$missing_start_advance_body" != "$original_start_body" ]] ||
        fail 'missing-START-advance mutant setup failed'
    local missing_start_advance_mutant="${launcher_source/$original_start_body/$missing_start_advance_body}"
    ! launcher_auth_dispatch_contract_is_closed "$missing_start_advance_mutant" ||
        fail 'retry dispatch admitted START without advancing the E lattice'
    local e2_start_guard='        [[ "$USER_RETRY_STATE" == '\''E2'\'' ]] ||'
    local weak_start_guard='        [[ "$USER_RETRY_STATE" == '\''E1'\'' || "$USER_RETRY_STATE" == '\''E2'\'' ]] ||'
    local weak_start_body="${original_start_body/$e2_start_guard/$weak_start_guard}"
    [[ "$weak_start_body" != "$original_start_body" ]] ||
        fail 'weak-START-E2-guard mutant setup failed'
    local weak_start_mutant="${launcher_source/$original_start_body/$weak_start_body}"
    ! launcher_auth_dispatch_contract_is_closed "$weak_start_mutant" ||
        fail 'retry dispatch admitted authorization before E2'
    local bootstrap_r3='         "$ROOT_RETRY_STATE" == '\''R2'\'' || "$ROOT_RETRY_STATE" == '\''R3'\'' ) ]] ||'
    local bootstrap_no_r3='         "$ROOT_RETRY_STATE" == '\''R2'\'' ) ]] ||'
    local missing_r3_body="${original_bootstrap_body/$bootstrap_r3/$bootstrap_no_r3}"
    [[ "$missing_r3_body" != "$original_bootstrap_body" ]] ||
        fail 'missing-bootstrap-R3 mutant setup failed'
    local missing_r3_mutant="${launcher_source/$original_bootstrap_body/$missing_r3_body}"
    ! launcher_auth_dispatch_contract_is_closed "$missing_r3_mutant" ||
        fail 'retry dispatch contract lost resumed R3 authorization'
    local bootstrap_canonical_cwd='        builtin cd / || exit 69'
    local bootstrap_missing_cwd_body="${original_bootstrap_body/$bootstrap_canonical_cwd/        :}"
    [[ "$bootstrap_missing_cwd_body" != "$original_bootstrap_body" ]] ||
        fail 'bootstrap-canonical-cwd mutant setup failed'
    local bootstrap_missing_cwd_mutant="${launcher_source/$original_bootstrap_body/$bootstrap_missing_cwd_body}"
    ! launcher_auth_dispatch_contract_is_closed "$bootstrap_missing_cwd_mutant" ||
        fail 'root bootstrap admitted an inherited protected working directory'
    local relative_output_line='                "$SNAPSHOT_SOURCE" -o controller'
    local absolute_output_line='                "$SNAPSHOT_SOURCE" -o "$CONTROLLER"'
    local absolute_output_mutant="${launcher_source//$relative_output_line/$absolute_output_line}"
    [[ "$absolute_output_mutant" != "$launcher_source" ]] ||
        fail 'absolute controller-output mutant setup failed'
    ! launcher_compile_output_contract_is_closed "$absolute_output_mutant" ||
        fail 'controller build contract admitted an absolute output-path mutant'

    [[ "$(/usr/bin/grep -E -c \
        '^[[:space:]]*/bin/(rm|rmdir|chmod|mv|install|chown)[[:space:]].*\$(FAILED_UID_TRIAL_ROOT|FAILED_UID_ACTIVE_POINTER|FAILED_CANDIDATE_TRIAL_ROOT|RESCUED_TRIAL_ROOT|RESCUED_ACTIVE_POINTER)' \
        "$LAUNCHER" || true)" == '0' ]] ||
        fail 'preserved user evidence must never be mutated'
    [[ "$(/usr/bin/grep -E -c \
        '^[[:space:]]*(local|typeset)([[:space:]]+-[^[:space:]]+)?[[:space:]]+(status|path|commands|functions|pipestatus|reply|argv|signals)(=|[[:space:]]|$)' \
        "$LAUNCHER" || true)" == '0' ]] ||
        fail 'launcher uses a reserved zsh local parameter name'
}

require_root_capture_envelope_file() {
    local envelope_path="$1"
    local expected_nlink="$2"
    require_data_volume_identity
    [[ -f "$envelope_path" && ! -L "$envelope_path" ]] ||
        fail "root capture envelope has an unsafe kind: $envelope_path"
    local envelope_stat envelope_size
    envelope_stat=$(/usr/bin/stat -f '%u:%g:%l:%Lp:%z:%f' "$envelope_path")
    envelope_size=$(/usr/bin/stat -f '%z' "$envelope_path")
    [[ "$envelope_size" == <-> && "$envelope_size" -ge 256 &&
       "$envelope_size" -le "$ROOT_CAPTURE_MAX_TRANSPORT_BYTES" &&
       "$envelope_stat" == "501:20:$expected_nlink:600:$envelope_size:0" ]] ||
        fail "root capture envelope metadata changed: $envelope_path"
    local envelope_xattrs envelope_acl
    envelope_xattrs=$(/usr/bin/xattr "$envelope_path") ||
        fail 'could not inspect root capture envelope xattrs'
    [[ -z "$envelope_xattrs" ]] || fail 'root capture envelope has extended attributes'
    envelope_acl=$(/bin/ls -lde "$envelope_path") ||
        fail 'could not inspect root capture envelope ACL'
    [[ "$(print -r -- "$envelope_acl" | /usr/bin/wc -l |
        /usr/bin/tr -d '[:space:]')" == '1' ]] ||
        fail 'root capture envelope has an ACL'
    if ! /usr/bin/env -i LC_ALL=C HOME="$PINNED_USER_HOME" PATH="$PINNED_EXEC_PATH" \
        USER="$PINNED_USER_NAME" LOGNAME="$PINNED_USER_NAME" \
        /usr/bin/perl - "$envelope_path" "$expected_nlink" "$ROOT_CAPTURE_CHALLENGE" \
            "$ROOT_CAPTURE_MAX_PAYLOAD_BYTES" "$ROOT_CAPTURE_MAX_TRANSPORT_BYTES" \
            <<'OPENSTEAMER_VALIDATE_ROOT_CAPTURE_L1CIAB'
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Fcntl qw(O_RDONLY);
use bytes;
my ($path, $expected_nlink, $challenge, $maximum_payload, $maximum_transport) = @ARGV;
my %expected_symlink_targets = (
    "sealed-prep-L1Ciab/opensteamer Host.app/Contents/Frameworks/LiveKitWebRTC.framework/Headers" =>
        "Versions/Current/Headers",
    "sealed-prep-L1Ciab/opensteamer Host.app/Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC" =>
        "Versions/Current/LiveKitWebRTC",
    "sealed-prep-L1Ciab/opensteamer Host.app/Contents/Frameworks/LiveKitWebRTC.framework/Modules" =>
        "Versions/Current/Modules",
    "sealed-prep-L1Ciab/opensteamer Host.app/Contents/Frameworks/LiveKitWebRTC.framework/Resources" =>
        "Versions/Current/Resources",
    "sealed-prep-L1Ciab/opensteamer Host.app/Contents/Frameworks/LiveKitWebRTC.framework/Versions/Current" =>
        "A",
);
$expected_nlink =~ /\A[123]\z/ or exit 70;
$maximum_payload =~ /\A[0-9]+\z/ && $maximum_transport =~ /\A[0-9]+\z/ or exit 70;
sysopen(my $file, $path, O_RDONLY | 0x100) or exit 71;
binmode($file);
my @before = stat($file);
my @named_before = lstat($path);
@before && @named_before or exit 72;
sub identity { my (@s) = @_; return join(":", @s[0, 1, 2, 3, 4, 5, 7, 9, 10]); }
sub symbolic_mode {
    my ($kind, $mode) = @_;
    my $value = $kind eq "directory" ? "d" : $kind eq "regular" ? "-" :
        $kind eq "socket" ? "s" : $kind eq "symlink" ? "l" : exit 96;
    my @bit = (0400, 0200, 0100, 0040, 0020, 0010, 0004, 0002, 0001);
    my @character = qw(r w x r w x r w x);
    for my $index (0 .. $#bit) {
        $value .= ($mode & $bit[$index]) ? $character[$index] : "-";
    }
    substr($value, 3, 1, ($mode & 0100) ? "s" : "S") if $mode & 04000;
    substr($value, 6, 1, ($mode & 0010) ? "s" : "S") if $mode & 02000;
    substr($value, 9, 1, ($mode & 0001) ? "t" : "T") if $mode & 01000;
    return $value;
}
sub acl_line_is_canonical {
    my ($line, $kind, $mode, $nlink, $uid, $gid, $size, $path, $link_target) = @_;
    my $owner = $uid == 0 ? "root" : $uid == 501 ? "ahmed" : return 0;
    my $group = $gid == 0 ? "wheel" : $gid == 20 ? "staff" : return 0;
    my $symbolic = symbolic_mode($kind, $mode);
    my $display_path = $kind eq "symlink" ? "$path -> $link_target" : $path;
    return $line =~ /\A\Q$symbolic\E[ ]+$nlink[ ]+\Q$owner\E[ ]+
        \Q$group\E[ ]+$size[ ]+[A-Z][a-z]{2}[ ]+[ 0-3][0-9][ ]+
        (?:[0-2][0-9]:[0-5][0-9]|[0-9]{4})[ ]+\Q$display_path\E\z/x;
}
identity(@before) eq identity(@named_before) or exit 72;
$before[4] == 501 && $before[5] == 20 && $before[3] == $expected_nlink &&
    (($before[2] & 0170000) == 0100000) && (($before[2] & 07777) == 0600)
    or exit 73;
my $transport = "";
while (1) {
    my $chunk = "";
    my $count = sysread($file, $chunk, 65_536);
    defined($count) or exit 74;
    last if $count == 0;
    length($transport) + $count <= $maximum_transport or exit 75;
    $transport .= $chunk;
}
my @after = stat($file);
my @named_after = lstat($path);
@after && @named_after && identity(@after) eq identity(@before) &&
    identity(@named_after) eq identity(@before) or exit 76;
close($file) or exit 77;
$transport =~ /\A([^\t\r\n]+)\t([0-9]+)\t([0-9a-f]{64})\t([0-9a-f]+)\n\n\z/
    or exit 78;
my ($observed_challenge, $payload_length, $payload_hash, $payload_hex) =
    ($1, $2, $3, $4);
$observed_challenge eq $challenge && $payload_length <= $maximum_payload &&
    length($payload_hex) == 2 * $payload_length && length($payload_hex) % 2 == 0
    or exit 79;
my $payload = pack("H*", $payload_hex);
length($payload) == $payload_length && sha256_hex($payload) eq $payload_hash or exit 80;
my @line = split(/\n/, $payload, -1);
@line >= 12 && pop(@line) eq "" or exit 81;
shift(@line) eq "schema=opensteamer.failed-root-evidence-capture.v1" or exit 82;
shift(@line) eq "challenge=$challenge" or exit 82;
shift(@line) eq "volume_uuid=AF638805-E0CB-4356-941F-16B84DFB6435" or exit 82;
shift(@line) eq "volume_group_uuid=AF638805-E0CB-4356-941F-16B84DFB6435" or exit 82;
shift(@line) eq "volume_mount=/System/Volumes/Data" or exit 82;
shift(@line) eq "filesystem_type=apfs" or exit 82;
my $root_device_line = shift(@line);
$root_device_line =~ /\Aroot_device=([0-9]+)\z/ && $1 > 0 or exit 82;
my $captured_root_device = $1;
shift(@line) eq "root_inode=27209685" or exit 82;
my $record_count_line = shift(@line);
my $total_bytes_line = shift(@line);
$record_count_line =~ /\Arecord_count=([0-9]+)\z/ or exit 83;
my $record_count = $1;
$record_count >= 1 && $record_count <= 512 or exit 83;
$total_bytes_line =~ /\Atotal_regular_bytes=([0-9]+)\z/ or exit 83;
my $declared_total_regular_bytes = $1;
$declared_total_regular_bytes <= 536_870_912 or exit 83;
pop(@line) eq "end=opensteamer.failed-root-evidence-capture.v1" or exit 84;
my %record_path;
my %record_kind;
my %record_size;
my %record_digest;
my %content_path;
my %content_length;
my %content_hash;
my %link_path;
my %link_length;
my %link_hash;
my %link_target;
my %observation;
my %observation_bytes;
my $observed_records = 0;
my $observed_total_regular_bytes = 0;
my @record_absolute_path;
my @record_relative_path;
my @record_stat_prefix;
my @record_acl_kind;
my @record_acl_mode;
my @record_acl_nlink;
my @record_acl_uid;
my @record_acl_gid;
my @record_acl_size;
my @socket_relative_path;
for my $entry (@line) {
    if ($entry =~ /\Arecord\t([0-9a-f]*)\t(directory|regular|socket|symlink)\t([0-9]+)\t([0-9]+)\t([0-9]+)\t([0-9]+)\t([0-9]+)\t([0-7]{4})\t([0-9]+)\t([0-9]+)\t([0-9]+)\t(-|[0-9a-f]{64})\z/) {
        my ($relative, $kind, $device, $inode, $uid, $gid, $nlink, $mode,
            $size, $mtime, $ctime, $digest) =
            (pack("H*", $1), $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12);
        $relative !~ /[\x00-\x1f\x7f]/ && $relative !~ m{(?:\A|/)\.\.?(/|\z)} &&
            !$record_path{$relative}++ or exit 85;
        ((($kind eq "regular" || $kind eq "symlink") &&
                $digest =~ /\A[0-9a-f]{64}\z/) ||
            (($kind eq "directory" || $kind eq "socket") && $digest eq "-"))
            or exit 85;
        $device == $captured_root_device or exit 85;
        if ($kind eq "regular") {
            $size <= 67_108_864 or exit 85;
            $observed_total_regular_bytes <= 536_870_912 - $size or exit 85;
            $observed_total_regular_bytes += $size;
        } elsif ($kind eq "symlink") {
            $size > 0 && $size <= 4_096 or exit 85;
        }
        $record_kind{$relative} = $kind;
        $record_size{$relative} = $size;
        $record_digest{$relative} = $digest;
        my $absolute = length($relative) == 0 ?
            "/Library/Application Support/opensteamer-local-mono-trial-v1" :
            "/Library/Application Support/opensteamer-local-mono-trial-v1/$relative";
        push(@record_absolute_path, $absolute);
        push(@record_relative_path, $relative);
        push(@record_stat_prefix,
            join(":", $device, $inode, $uid, $gid, $nlink, 0 + $mode, $size));
        push(@record_acl_kind, $kind);
        push(@record_acl_mode, oct($mode));
        push(@record_acl_nlink, $nlink);
        push(@record_acl_uid, $uid);
        push(@record_acl_gid, $gid);
        push(@record_acl_size, $size);
        push(@socket_relative_path, $relative) if $kind eq "socket";
        ++$observed_records;
    } elsif ($entry =~ /\Acontent\t([0-9a-f]+)\t([0-9]+)\t([0-9a-f]{64})\t([0-9a-f]*)\z/) {
        my ($relative, $length, $hash, $hex) = (pack("H*", $1), $2, $3, $4);
        my $bytes = pack("H*", $hex);
        length($hex) % 2 == 0 && length($bytes) == $length &&
            sha256_hex($bytes) eq $hash && !$content_path{$relative}++ or exit 86;
        $content_length{$relative} = $length;
        $content_hash{$relative} = $hash;
    } elsif ($entry =~ /\Alink\t([0-9a-f]+)\t([0-9]+)\t([0-9a-f]{64})\t([0-9a-f]+)\z/) {
        my ($relative, $length, $hash, $hex) = (pack("H*", $1), $2, $3, $4);
        my $target = pack("H*", $hex);
        $relative !~ /[\x00-\x1f\x7f]/ &&
            $relative !~ m{(?:\A|/)\.\.?(/|\z)} &&
            length($hex) % 2 == 0 && length($target) == $length &&
            $length > 0 && $length <= 4_096 &&
            $target !~ /[\x00-\x1f\x7f]/ && $target !~ m{\A/} &&
            $target !~ m{(?:\A|/)\.\.?(/|\z)} &&
            sha256_hex($target) eq $hash && !$link_path{$relative}++ or exit 86;
        $link_length{$relative} = $length;
        $link_hash{$relative} = $hash;
        $link_target{$relative} = $target;
    } elsif ($entry =~ /\Aobservation\t([a-z0-9-]+)\t([0-9]+)\t([0-9]+)\t([0-9a-f]{64})\t([0-9a-f]*)\z/) {
        my ($name, $status, $length, $hash, $hex) = ($1, $2, $3, $4, $5);
        my $bytes = pack("H*", $hex);
        length($hex) % 2 == 0 && length($bytes) == $length &&
            $length <= 1_048_576 && sha256_hex($bytes) eq $hash &&
            !$observation{$name}++ or exit 86;
        $observation{"$name.status"} = $status;
        $observation{"$name.length"} = $length;
        $observation_bytes{$name} = $bytes;
    } else {
        exit 87;
    }
}
$observed_records == $record_count && exists($record_path{""}) &&
    $record_kind{""} eq "directory" && $observed_total_regular_bytes ==
        $declared_total_regular_bytes or exit 88;
for my $required ("controller.sha256", "root-broker.log",
    "private-transaction-prep-L1Ciab/journal.log",
    "private-transaction-prep-L1Ciab/driver.identity") {
    exists($record_path{$required}) && exists($content_path{$required}) &&
        $record_kind{$required} eq "regular" &&
        $content_length{$required} == $record_size{$required} &&
        $content_hash{$required} eq $record_digest{$required} or exit 89;
}
scalar(keys(%content_path)) == 4 or exit 90;
scalar(keys(%link_path)) == scalar(keys(%expected_symlink_targets)) or exit 90;
for my $relative (keys(%expected_symlink_targets)) {
    exists($record_path{$relative}) && exists($link_path{$relative}) &&
        $record_kind{$relative} eq "symlink" &&
        $link_target{$relative} eq $expected_symlink_targets{$relative} &&
        $link_length{$relative} == $record_size{$relative} &&
        $link_hash{$relative} eq $record_digest{$relative} or exit 90;
}
scalar(grep { $_ eq "symlink" } values(%record_kind)) ==
    scalar(keys(%expected_symlink_targets)) or exit 90;
for my $required ("data-volume", "bsd-stat", "xattr", "socket-xattr", "acl", "openers",
    "codesign-verify", "codesign-display") {
    exists($observation{$required}) or exit 91;
}
$observation{"data-volume.status"} == 0 && $observation{"data-volume.length"} > 0 &&
    $observation{"bsd-stat.status"} == 0 && $observation{"bsd-stat.length"} > 0 &&
    $observation{"xattr.status"} == 0 && $observation{"xattr.length"} == 0 &&
    $observation{"socket-xattr.status"} == 256 &&
    $observation{"socket-xattr.length"} > 0 &&
    $observation{"acl.status"} == 0 && $observation{"acl.length"} > 0 &&
    $observation{"openers.status"} == 256 && $observation{"openers.length"} == 0 &&
    $observation{"codesign-verify.status"} == 0 &&
    $observation{"codesign-verify.length"} == 0 &&
    $observation{"codesign-display.status"} == 0 &&
    $observation{"codesign-display.length"} > 0 or exit 92;
scalar(grep { $_ !~ /[.](?:status|length)\z/ } keys(%observation)) == 8 or exit 93;
$observation_bytes{"data-volume"} eq
    "volume_uuid=AF638805-E0CB-4356-941F-16B84DFB6435\n" .
    "volume_group_uuid=AF638805-E0CB-4356-941F-16B84DFB6435\n" .
    "volume_mount=/System/Volumes/Data\n" .
    "filesystem_type=apfs\ninternal=true\n" .
    "captured_device=$captured_root_device\n" or exit 94;
$observation_bytes{"xattr"} eq "" && $observation_bytes{"openers"} eq "" &&
    $observation_bytes{"codesign-verify"} eq "" or exit 94;
$record_stat_prefix[0] eq "$captured_root_device:27209685:0:0:8:711:256" &&
    $record_absolute_path[0] eq
        "/Library/Application Support/opensteamer-local-mono-trial-v1" or exit 94;
my @bsd_stat_line = split(/\n/, $observation_bytes{"bsd-stat"}, -1);
pop(@bsd_stat_line) eq "" && @bsd_stat_line == @record_stat_prefix or exit 94;
for my $index (0 .. $#record_stat_prefix) {
    $bsd_stat_line[$index] eq "$record_stat_prefix[$index]:0" or exit 94;
}
@socket_relative_path == 1 or exit 95;
my $socket_absolute_path =
    "/Library/Application Support/opensteamer-local-mono-trial-v1/" .
    $socket_relative_path[0];
my $expected_socket_xattr =
    "xattr: [Errno 102] Operation not supported on socket: " . chr(39) .
    $socket_absolute_path . chr(39) . "\n";
$observation_bytes{"socket-xattr"} eq $expected_socket_xattr or exit 95;
my @acl_line = split(/\n/, $observation_bytes{"acl"}, -1);
pop(@acl_line) eq "" && @acl_line == @record_absolute_path or exit 96;
for my $index (0 .. $#record_absolute_path) {
    acl_line_is_canonical($acl_line[$index], $record_acl_kind[$index],
        $record_acl_mode[$index], $record_acl_nlink[$index],
        $record_acl_uid[$index], $record_acl_gid[$index],
        $record_acl_size[$index], $record_absolute_path[$index],
        $record_kind{$record_relative_path[$index]} eq "symlink" ?
            $link_target{$record_relative_path[$index]} : "") or exit 96;
}
my $codesign_display = $observation_bytes{"codesign-display"};
$codesign_display !~ /[\x00\r]/ &&
    (() = $codesign_display =~ /^Identifier=com[.]elamin[.]AudioStreamer[.]CaptureServer$/mg) == 1 &&
    (() = $codesign_display =~ /^TeamIdentifier=MSMG8CJLB3$/mg) == 1 &&
    (() = $codesign_display =~ /^CDHash=af8181f6c0e81fc5824d1b9ff36dbb36a25ad18b$/mg) == 1 &&
    (() = $codesign_display =~ /^Authority=Apple Development: Ahmed Elamin [(]92LVX32M8K[)]$/mg) == 1 &&
    (() = $codesign_display =~ /^CodeDirectory v=20400 size=12042 flags=0x0[(]none[)] hashes=369[+]3 location=embedded$/mg) == 1 or exit 97;
exit 0;
OPENSTEAMER_VALIDATE_ROOT_CAPTURE_L1CIAB
    then
        fail 'root capture envelope failed its canonical contract'
    fi
    if [[ "$EXPECTED_ROOT_CAPTURE_ENVELOPE_SHA256" != *PIN_AFTER* ]]; then
        require_hash "$envelope_path" "$EXPECTED_ROOT_CAPTURE_ENVELOPE_SHA256"
    fi
}

require_same_root_capture_inode() {
    local expected_nlink="$1"
    shift
    local expected_identity=''
    local capture_name capture_identity
    for capture_name in "$@"; do
        require_root_capture_envelope_file "$capture_name" "$expected_nlink"
        capture_identity="$(/usr/bin/stat -f '%d:%i' "$capture_name")"
        if [[ -z "$expected_identity" ]]; then
            expected_identity="$capture_identity"
        else
            [[ "$capture_identity" == "$expected_identity" ]] ||
                fail 'root capture publication names do not share one inode'
        fi
    done
}

require_safe_incomplete_root_capture_transport() {
    [[ -f "$ROOT_CAPTURE_TRANSPORT" && ! -L "$ROOT_CAPTURE_TRANSPORT" ]] ||
        fail 'incomplete root capture transport has an unsafe kind'
    local before after size first_hash second_hash xattrs acl openers opener_status
    before="$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$ROOT_CAPTURE_TRANSPORT")"
    size="$(/usr/bin/stat -f '%z' "$ROOT_CAPTURE_TRANSPORT")"
    [[ "$size" == <-> && "$size" -le "$ROOT_CAPTURE_MAX_TRANSPORT_BYTES" &&
       "$before" == *":501:20:1:600:$size:0" &&
       "${before%%:*}" == "$(/usr/bin/stat -f '%d' "$BUILD_PARENT")" ]] ||
        fail 'incomplete root capture transport metadata is unsafe'
    xattrs="$(/usr/bin/xattr "$ROOT_CAPTURE_TRANSPORT")" ||
        fail 'could not inspect incomplete root capture transport xattrs'
    [[ -z "$xattrs" ]] || fail 'incomplete root capture transport has extended attributes'
    acl="$(/bin/ls -lde "$ROOT_CAPTURE_TRANSPORT")" ||
        fail 'could not inspect incomplete root capture transport ACL'
    [[ "$(print -r -- "$acl" | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" == '1' ]] ||
        fail 'incomplete root capture transport has an ACL'
    set +e
    openers="$(/usr/sbin/lsof -Fn -- "$ROOT_CAPTURE_TRANSPORT" 2>/dev/null)"
    opener_status=$?
    set -e
    [[ "$opener_status" == '1' && -z "$openers" ]] ||
        fail 'incomplete root capture transport still has an opener'
    first_hash="$(sha256_file "$ROOT_CAPTURE_TRANSPORT")"
    after="$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$ROOT_CAPTURE_TRANSPORT")"
    second_hash="$(sha256_file "$ROOT_CAPTURE_TRANSPORT")"
    [[ "$after" == "$before" && "$second_hash" == "$first_hash" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$ROOT_CAPTURE_TRANSPORT")" ==
           "$before" ]] || fail 'incomplete root capture transport changed during proof'
}

resume_root_capture_publication() {
    require_launcher_lock_held
    local transport_present=0 partial_present=0 ready_present=0
    [[ -e "$ROOT_CAPTURE_TRANSPORT" || -L "$ROOT_CAPTURE_TRANSPORT" ]] &&
        transport_present=1
    [[ -e "$ROOT_CAPTURE_PARTIAL" || -L "$ROOT_CAPTURE_PARTIAL" ]] && partial_present=1
    [[ -e "$ROOT_CAPTURE_READY" || -L "$ROOT_CAPTURE_READY" ]] && ready_present=1
    if (( transport_present == 0 && partial_present == 0 && ready_present == 0 )); then
        return 1
    fi
    if (( transport_present == 1 && partial_present == 0 && ready_present == 0 )); then
        if ( require_root_capture_envelope_file "$ROOT_CAPTURE_TRANSPORT" 1 ) 2>/dev/null; then
            require_same_root_capture_inode 1 "$ROOT_CAPTURE_TRANSPORT"
        else
            require_safe_incomplete_root_capture_transport
            require_launcher_lock_held
            /bin/rm -f -- "$ROOT_CAPTURE_TRANSPORT"
            [[ ! -e "$ROOT_CAPTURE_TRANSPORT" && ! -L "$ROOT_CAPTURE_TRANSPORT" ]] ||
                fail 'incomplete root capture transport survived cleanup'
            /bin/sync
            [[ ! -e "$ROOT_CAPTURE_TRANSPORT" && ! -L "$ROOT_CAPTURE_TRANSPORT" ]] ||
                fail 'incomplete root capture transport cleanup was not durable'
            return 1
        fi
        [[ ! -e "$ROOT_CAPTURE_PARTIAL" && ! -L "$ROOT_CAPTURE_PARTIAL" ]] ||
            fail 'root capture partial raced transport publication'
        require_launcher_lock_held
        /bin/ln "$ROOT_CAPTURE_TRANSPORT" "$ROOT_CAPTURE_PARTIAL"
        transport_present=1
        partial_present=1
    fi
    if (( transport_present == 0 && partial_present == 1 && ready_present == 0 )); then
        require_same_root_capture_inode 1 "$ROOT_CAPTURE_PARTIAL"
        [[ ! -e "$ROOT_CAPTURE_READY" && ! -L "$ROOT_CAPTURE_READY" ]] ||
            fail 'root capture ready raced partial publication'
        require_launcher_lock_held
        /bin/ln "$ROOT_CAPTURE_PARTIAL" "$ROOT_CAPTURE_READY"
        ready_present=1
    elif (( transport_present == 1 && partial_present == 1 && ready_present == 0 )); then
        require_same_root_capture_inode 2 "$ROOT_CAPTURE_TRANSPORT" "$ROOT_CAPTURE_PARTIAL"
        [[ ! -e "$ROOT_CAPTURE_READY" && ! -L "$ROOT_CAPTURE_READY" ]] ||
            fail 'root capture ready raced transport publication'
        require_launcher_lock_held
        /bin/ln "$ROOT_CAPTURE_PARTIAL" "$ROOT_CAPTURE_READY"
        ready_present=1
    elif (( transport_present == 0 && partial_present == 0 && ready_present == 1 )); then
        require_same_root_capture_inode 1 "$ROOT_CAPTURE_READY"
        return 0
    elif (( transport_present == 1 && partial_present == 0 && ready_present == 1 )); then
        fail 'root capture transport and ready exist without the partial publication name'
    fi
    if (( transport_present == 1 && partial_present == 1 && ready_present == 1 )); then
        require_same_root_capture_inode 3 "$ROOT_CAPTURE_TRANSPORT" \
            "$ROOT_CAPTURE_PARTIAL" "$ROOT_CAPTURE_READY"
        /bin/sync
        require_same_root_capture_inode 3 "$ROOT_CAPTURE_TRANSPORT" \
            "$ROOT_CAPTURE_PARTIAL" "$ROOT_CAPTURE_READY"
        require_launcher_lock_held
        /bin/rm -f -- "$ROOT_CAPTURE_TRANSPORT"
        [[ ! -e "$ROOT_CAPTURE_TRANSPORT" && ! -L "$ROOT_CAPTURE_TRANSPORT" ]] ||
            fail 'root capture transport name survived publication'
        transport_present=0
    fi
    if (( transport_present == 0 && partial_present == 1 && ready_present == 1 )); then
        require_same_root_capture_inode 2 "$ROOT_CAPTURE_PARTIAL" "$ROOT_CAPTURE_READY"
        /bin/sync
        require_same_root_capture_inode 2 "$ROOT_CAPTURE_PARTIAL" "$ROOT_CAPTURE_READY"
        require_launcher_lock_held
        /bin/rm -f -- "$ROOT_CAPTURE_PARTIAL"
        [[ ! -e "$ROOT_CAPTURE_PARTIAL" && ! -L "$ROOT_CAPTURE_PARTIAL" ]] ||
            fail 'root capture partial name survived publication'
        /bin/sync
        require_same_root_capture_inode 1 "$ROOT_CAPTURE_READY"
        return 0
    fi
    fail 'root capture publication state is impossible'
}

capture_root_evidence_once() {
    require_launcher_lock_held
    if resume_root_capture_publication; then
        print -- "OPENSTEAMER_ROOT_CAPTURE_READY path=$ROOT_CAPTURE_READY sha256=$(sha256_file "$ROOT_CAPTURE_READY")"
        return 0
    fi
    [[ "$EXPECTED_ROOT_CAPTURE_COMMAND_SHA256" != *PIN_AFTER* ]] ||
        fail 'root capture command is not release-pinned' 78
    [[ -d "$BUILD_PARENT" && ! -L "$BUILD_PARENT" &&
       "$(/usr/bin/stat -f '%u:%g:%Lp' "$BUILD_PARENT")" == '501:20:700' ]] ||
        fail 'root capture private parent metadata is unsafe'
    [[ ! -e "$ROOT_CAPTURE_TRANSPORT" && ! -L "$ROOT_CAPTURE_TRANSPORT" &&
       ! -e "$ROOT_CAPTURE_PARTIAL" && ! -L "$ROOT_CAPTURE_PARTIAL" &&
       ! -e "$ROOT_CAPTURE_READY" && ! -L "$ROOT_CAPTURE_READY" ]] ||
        fail 'root capture fixed publication paths are not fresh'
    local capture_status
    AUTHORIZATION_ATTEMPTED=1
    set +e
    ( setopt localoptions noclobber
      builtin cd / || exit 69
      /usr/bin/env -i LC_ALL=C HOME="$PINNED_USER_HOME" PATH="$PINNED_EXEC_PATH" \
          USER="$PINNED_USER_NAME" LOGNAME="$PINNED_USER_NAME" \
          /usr/bin/osascript - "$ROOT_CAPTURE_COMMAND" > "$ROOT_CAPTURE_TRANSPORT" <<'APPLESCRIPT'
on run commandArguments
    if (count of commandArguments) is not 1 then error "fixed root capture argument missing"
    return do shell script (item 1 of commandArguments) with administrator privileges without altering line endings
end run
APPLESCRIPT
    )
    capture_status=$?
    set -e
    [[ "$capture_status" == '0' ]] ||
        fail "authorized read-only root capture failed status=$capture_status" 70
    /bin/chmod 0600 "$ROOT_CAPTURE_TRANSPORT"
    require_root_capture_envelope_file "$ROOT_CAPTURE_TRANSPORT" 1
    [[ "$(/usr/bin/stat -f '%d' "$ROOT_CAPTURE_TRANSPORT")" ==
           "$(/usr/bin/stat -f '%d' "$BUILD_PARENT")" ]] ||
        fail 'root capture transport crossed filesystems'
    /bin/sync
    require_root_capture_envelope_file "$ROOT_CAPTURE_TRANSPORT" 1
    resume_root_capture_publication || fail 'root capture publication did not converge'
    print -- "OPENSTEAMER_ROOT_CAPTURE_READY path=$ROOT_CAPTURE_READY sha256=$(sha256_file "$ROOT_CAPTURE_READY")"
}

bootstrap_root_broker_once() {
    [[ "$EXPECTED_CONTROLLER_BINARY_SHA256" != *PIN_AFTER* &&
       "$ROOT_BOOTSTRAP_COMMAND" == *"$EXPECTED_CONTROLLER_BINARY_SHA256"* ]] ||
        fail 'root bootstrap command is not bound to the exact controller postimage' 78
    require_launcher_lock_held
    classify_retry_state
    [[ "$USER_RETRY_STATE" == 'E2' &&
       ( "$ROOT_RETRY_STATE" == 'R0' || "$ROOT_RETRY_STATE" == 'R1' ||
         "$ROOT_RETRY_STATE" == 'R2' || "$ROOT_RETRY_STATE" == 'R3' ) ]] ||
        fail 'authorized root bootstrap requires exact E2/R0-R3 retry state'
    AUTHORIZATION_ATTEMPTED=1
    local root_pid
    root_pid=$(
        builtin cd / || exit 69
        /usr/bin/env -i LC_ALL=C HOME="$PINNED_USER_HOME" PATH="$PINNED_EXEC_PATH" \
            USER="$PINNED_USER_NAME" LOGNAME="$PINNED_USER_NAME" \
            /usr/bin/osascript - "$ROOT_BOOTSTRAP_COMMAND" <<'APPLESCRIPT'
on run commandArguments
    if (count of commandArguments) is not 1 then error "fixed root bootstrap argument missing"
    do shell script (item 1 of commandArguments) with administrator privileges
end run
APPLESCRIPT
    )
    require_launcher_lock_held
    [[ "$root_pid" == <-> ]] || fail 'authorized root broker returned a malformed PID'
}

require_plain_retry_node() {
    local target_path="$1"
    local expected_stat="$2"
    [[ "$(/usr/bin/stat -f '%u:%g:%l:%Lp:%z:%f' "$target_path" 2>/dev/null)" ==
       "$expected_stat" ]] || fail "known pre-runtime retry node metadata changed: $target_path"
    local xattrs
    xattrs=$(/usr/bin/xattr "$target_path") ||
        fail "could not inspect known pre-runtime retry node xattrs: $target_path"
    [[ -z "$xattrs" ]] || fail "known pre-runtime retry node has extended attributes: $target_path"
    local acl_listing acl_lines
    acl_listing=$(/bin/ls -lde "$target_path") ||
        fail "could not inspect known pre-runtime retry node ACL: $target_path"
    acl_lines=$(/usr/bin/printf '%s\n' "$acl_listing" | /usr/bin/wc -l |
        /usr/bin/tr -d '[:space:]')
    [[ "$acl_lines" == '1' ]] || fail "known pre-runtime retry node has an ACL: $target_path"
}

require_exact_retry_child_count() {
    local directory_path="$1"
    local expected="$2"
    local listing actual
    listing=$(/usr/bin/find "$directory_path" -xdev -mindepth 1 -maxdepth 1 -print) ||
        fail "could not enumerate known pre-runtime retry directory: $directory_path"
    if [[ -z "$listing" ]]; then
        actual=0
    else
        actual=$(/usr/bin/printf '%s\n' "$listing" | /usr/bin/wc -l |
            /usr/bin/tr -d '[:space:]')
    fi
    [[ "$actual" == "$expected" ]] ||
        fail "known pre-runtime retry directory contains unexpected nodes: $directory_path"
}

require_exact_retry_node() {
    local target_path="$1"
    local expected_stat="$2"
    [[ "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$target_path" 2>/dev/null)" ==
       "$expected_stat" ]] || fail "preserved retry-node identity changed: $target_path"
    require_plain_retry_node "$target_path" "${expected_stat#*:*:}"
}

require_exact_retry_children() {
    local directory_path="$1"
    shift
    local actual expected
    actual=$(/usr/bin/find "$directory_path" -xdev -mindepth 1 -maxdepth 1 -print |
        /usr/bin/sort) || fail "could not enumerate preserved retry directory: $directory_path"
    expected=$(/usr/bin/printf '%s\n' "$@" | /usr/bin/sort)
    [[ "$actual" == "$expected" ]] ||
        fail "preserved retry directory children changed: $directory_path"
}

require_preserved_failed_uid_admission_user_evidence() {
    [[ -d "$FAILED_UID_TRIAL_ROOT" && ! -L "$FAILED_UID_TRIAL_ROOT" &&
       -f "$FAILED_UID_ACTIVE_POINTER" && ! -L "$FAILED_UID_ACTIVE_POINTER" ]] ||
        fail 'preserved uid-admission user evidence is unavailable'
    [[ "$(/usr/bin/stat -f '%d:%i' "$FAILED_UID_TRIAL_ROOT")" ==
           "${DATA_VOLUME_DEVICE}:27016241" &&
       "$(/usr/bin/stat -f '%d:%i' "$FAILED_UID_ACTIVE_POINTER")" ==
           "${DATA_VOLUME_DEVICE}:27017103" ]] ||
        fail 'preserved uid-admission user evidence identity changed'
    require_plain_retry_node "$FAILED_UID_TRIAL_ROOT" '501:20:7:700:224:0'
    require_plain_retry_node "$FAILED_UID_ACTIVE_POINTER" '501:20:1:600:228:0'
    require_exact_retry_child_count "$FAILED_UID_TRIAL_ROOT" '5'
    require_hash "$FAILED_UID_ACTIVE_POINTER" "$FAILED_UID_ACTIVE_POINTER_SHA256"

    local openers lsof_status
    set +e
    openers=$(/usr/sbin/lsof -Fn +D "$FAILED_UID_TRIAL_ROOT" 2>/dev/null)
    lsof_status=$?
    set -e
    [[ "$lsof_status" == '1' && -z "$openers" ]] ||
        fail 'preserved uid-admission trial evidence is open'
    set +e
    openers=$(/usr/sbin/lsof -Fn -- "$FAILED_UID_ACTIVE_POINTER" 2>/dev/null)
    lsof_status=$?
    set -e
    [[ "$lsof_status" == '1' && -z "$openers" ]] ||
        fail 'preserved uid-admission active-pointer evidence is open'
}

require_retry_tree_closed() {
    local root="$1"
    local openers lsof_status
    set +e
    openers=$(/usr/sbin/lsof -Fn +D "$root" 2>/dev/null)
    lsof_status=$?
    set -e
    [[ "$lsof_status" == '1' && -z "$openers" ]] ||
        fail "known retry tree is open: $root"
}

require_failed_candidate_user_tree() {
    local root="$1"
    local run_root="$root/paired-v7-update-local-mono-prep-L1Ciab"
    local probes="$run_root/probes"
    local staging="$root/staging"
    local controller="$staging/opensteamer-local-mono-trial-controller"
    local guardian="$staging/opensteamer-v7-default-route-guardian"
    local proxy_arm="$root/proxy.arm"
    local journal="$root/journal.log"
    local result="$root/result.txt"
    local vpio_state="$probes/vpio-default-route-state.json"
    local vpio_repair="$probes/vpio-guardian-repair.json"
    local vpio_snapshot="$probes/vpio-guardian-snapshot.json"
    local vpio_stdout="$probes/vpio-guardian.stdout"
    local vpio_stderr="$probes/vpio-guardian.stderr"
    local vpio_final="$probes/vpio-guardian-final.json"

    [[ -d "$root" && ! -L "$root" &&
       -d "$run_root" && ! -L "$run_root" &&
       -d "$probes" && ! -L "$probes" &&
       -d "$staging" && ! -L "$staging" &&
       -f "$controller" && ! -L "$controller" &&
       -f "$guardian" && ! -L "$guardian" &&
       -f "$proxy_arm" && ! -L "$proxy_arm" &&
       -f "$journal" && ! -L "$journal" &&
       -f "$result" && ! -L "$result" &&
       -f "$vpio_state" && ! -L "$vpio_state" &&
       -f "$vpio_repair" && ! -L "$vpio_repair" &&
       -f "$vpio_snapshot" && ! -L "$vpio_snapshot" &&
       -f "$vpio_stdout" && ! -L "$vpio_stdout" &&
       -f "$vpio_stderr" && ! -L "$vpio_stderr" &&
       -f "$vpio_final" && ! -L "$vpio_final" ]] ||
        fail 'candidate-gate failure user evidence shape changed'
    [[ "$(/usr/bin/stat -f '%d:%i' "$root")" == "${DATA_VOLUME_DEVICE}:27021633" ]] ||
        fail 'candidate-gate failure user evidence identity changed'

    require_exact_retry_child_count "$root" '5'
    require_exact_retry_child_count "$run_root" '1'
    require_exact_retry_child_count "$probes" '6'
    require_exact_retry_child_count "$staging" '2'
    require_plain_retry_node "$root" '501:20:7:700:224:0'
    require_plain_retry_node "$run_root" '501:20:3:700:96:0'
    require_plain_retry_node "$probes" '501:20:8:700:256:0'
    require_plain_retry_node "$staging" '501:20:4:700:128:0'
    require_plain_retry_node "$controller" '501:20:1:500:1388904:0'
    require_plain_retry_node "$guardian" '501:20:1:500:258696:0'
    require_plain_retry_node "$proxy_arm" '501:20:1:600:101:0'
    require_plain_retry_node "$journal" '501:20:1:600:94:0'
    require_plain_retry_node "$result" '501:20:1:600:29:0'
    require_plain_retry_node "$vpio_state" '501:20:1:600:288:0'
    require_plain_retry_node "$vpio_repair" '501:20:1:600:1273:0'
    require_plain_retry_node "$vpio_snapshot" '501:20:1:600:1275:0'
    require_plain_retry_node "$vpio_stdout" '501:20:1:600:22:0'
    require_plain_retry_node "$vpio_stderr" '501:20:1:600:0:0'
    require_plain_retry_node "$vpio_final" '501:20:1:600:1271:0'

    require_hash "$controller" "$FAILED_CANDIDATE_CONTROLLER_SHA256"
    require_hash "$guardian" "$PRESERVED_GUARDIAN_BINARY_SHA256"
    require_hash "$proxy_arm" "$FAILED_CANDIDATE_PROXY_ARM_SHA256"
    require_hash "$journal" "$FAILED_CANDIDATE_JOURNAL_SHA256"
    require_hash "$result" "$FAILED_CANDIDATE_RESULT_SHA256"
    require_hash "$vpio_state" "$FAILED_CANDIDATE_VPIO_STATE_SHA256"
    require_hash "$vpio_repair" "$FAILED_CANDIDATE_VPIO_REPAIR_SHA256"
    require_hash "$vpio_snapshot" "$FAILED_CANDIDATE_VPIO_SNAPSHOT_SHA256"
    require_hash "$vpio_stdout" "$FAILED_CANDIDATE_VPIO_STDOUT_SHA256"
    require_hash "$vpio_stderr" "$EMPTY_SHA256"
    require_hash "$vpio_final" "$FAILED_CANDIDATE_VPIO_FINAL_SHA256"
    [[ "$(/bin/cat "$journal")" ==
       $'OPENSTEAMER_LOCAL_MONO_TRIAL_V1\nSTATE USER_STAGE_VERIFIED\nSTATE ROOT_OWNED_UID_PROXY pid=6805' ]] ||
        fail 'candidate-gate failure journal content changed'
    [[ "$(/bin/cat "$result")" == 'LOCAL_MONO_TRIAL_ROLLED_BACK' ]] ||
        fail 'candidate-gate failure result content changed'
    [[ "$(/bin/cat "$proxy_arm")" ==
       $'schema=opensteamer.local-mono-trial-proxy-arm.v1\nproxy_pid=6805\nproxy_start=Sun Aug 16 05:59:44 2026' ]] ||
        fail 'candidate-gate failure proxy arm changed'
    require_retry_tree_closed "$root"
}

require_preserved_failed_candidate_user_evidence() {
    require_failed_candidate_user_tree "$FAILED_CANDIDATE_TRIAL_ROOT"
}

require_preserved_rescued_active_pointer() {
    [[ -f "$RESCUED_ACTIVE_POINTER" && ! -L "$RESCUED_ACTIVE_POINTER" ]] ||
        fail 'preserved CoreAudio incident pointer is unavailable'
    require_exact_retry_node "$RESCUED_ACTIVE_POINTER" \
        "${DATA_VOLUME_DEVICE}:27093461:501:20:1:600:228:0"
    require_hash "$RESCUED_ACTIVE_POINTER" "$RESCUED_ACTIVE_POINTER_SHA256"
    [[ "$(/bin/cat "$RESCUED_ACTIVE_POINTER")" ==
       $'schema=opensteamer.local-mono-trial-pointer.v1\ntrial_root=/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab\nstate=arming\nproxy_pid=21660\nproxy_start=Sun Aug 16 14:34:47 2026\nstate=armed' ]] ||
        fail 'preserved CoreAudio incident pointer content changed'
    local openers lsof_status
    set +e
    openers=$(/usr/sbin/lsof -Fn -- "$RESCUED_ACTIVE_POINTER" 2>/dev/null)
    lsof_status=$?
    set -e
    [[ "$lsof_status" == '1' && -z "$openers" ]] ||
        fail 'preserved CoreAudio incident pointer is open'
}

require_preserved_rescued_trial() {
    local root="$RESCUED_TRIAL_ROOT"
    local run_root="$root/paired-v7-update-local-mono-prep-L1Ciab"
    local probes="$run_root/probes"
    local staging="$root/staging"
    local controller="$staging/opensteamer-local-mono-trial-controller"
    local guardian="$staging/opensteamer-v7-default-route-guardian"
    local journal="$root/journal.log"
    local result="$root/result.txt"
    local proxy_arm="$root/proxy.arm"
    local vpio_state="$probes/vpio-default-route-state.json"
    local vpio_stdout="$probes/vpio-guardian.stdout"
    local vpio_stderr="$probes/vpio-guardian.stderr"
    local vpio_snapshot="$probes/vpio-guardian-snapshot.json"
    local vpio_fence="$probes/vpio-guardian-prestop-fence.json"
    local vpio_repair="$probes/vpio-guardian-repair.json"
    local vpio_final="$probes/vpio-guardian-final.json"

    [[ -d "$root" && ! -L "$root" && -d "$run_root" && ! -L "$run_root" &&
       -d "$probes" && ! -L "$probes" && -d "$staging" && ! -L "$staging" ]] ||
        fail 'preserved CoreAudio incident directory shape changed'
    for regular_node in "$controller" "$guardian" "$journal" "$result" "$proxy_arm" \
        "$vpio_state" "$vpio_stdout" "$vpio_stderr" "$vpio_snapshot" "$vpio_fence" \
        "$vpio_repair" "$vpio_final"; do
        [[ -f "$regular_node" && ! -L "$regular_node" ]] ||
            fail "preserved CoreAudio incident file shape changed: $regular_node"
    done
    require_exact_retry_children "$root" "$journal" "$run_root" "$proxy_arm" "$result" "$staging"
    require_exact_retry_children "$run_root" "$probes"
    require_exact_retry_children "$probes" "$vpio_state" "$vpio_stdout" "$vpio_stderr" \
        "$vpio_snapshot" "$vpio_fence" "$vpio_repair" "$vpio_final"
    require_exact_retry_children "$staging" "$controller" "$guardian"

    require_exact_retry_node "$root" "${DATA_VOLUME_DEVICE}:27092973:501:20:7:700:224:0"
    require_exact_retry_node "$run_root" "${DATA_VOLUME_DEVICE}:27092974:501:20:3:700:96:0"
    require_exact_retry_node "$probes" "${DATA_VOLUME_DEVICE}:27092975:501:20:9:700:288:0"
    require_exact_retry_node "$staging" "${DATA_VOLUME_DEVICE}:27092976:501:20:4:700:128:0"
    require_exact_retry_node "$controller" "${DATA_VOLUME_DEVICE}:27092977:501:20:1:500:1443880:0"
    require_exact_retry_node "$guardian" "${DATA_VOLUME_DEVICE}:27092978:501:20:1:500:258696:0"
    require_exact_retry_node "$journal" "${DATA_VOLUME_DEVICE}:27093241:501:20:1:600:95:0"
    require_exact_retry_node "$result" "${DATA_VOLUME_DEVICE}:27093242:501:20:1:600:0:0"
    require_exact_retry_node "$proxy_arm" "${DATA_VOLUME_DEVICE}:27093462:501:20:1:600:102:0"
    require_exact_retry_node "$vpio_state" "${DATA_VOLUME_DEVICE}:27093676:501:20:1:600:288:0"
    require_exact_retry_node "$vpio_stdout" "${DATA_VOLUME_DEVICE}:27093674:501:20:1:600:67:0"
    require_exact_retry_node "$vpio_stderr" "${DATA_VOLUME_DEVICE}:27093675:501:20:1:600:0:0"
    require_exact_retry_node "$vpio_snapshot" "${DATA_VOLUME_DEVICE}:27093679:501:20:1:600:1275:0"
    require_exact_retry_node "$vpio_fence" "${DATA_VOLUME_DEVICE}:27093690:501:20:1:600:1272:0"
    require_exact_retry_node "$vpio_repair" "${DATA_VOLUME_DEVICE}:27093881:501:20:1:600:1273:0"
    require_exact_retry_node "$vpio_final" "${DATA_VOLUME_DEVICE}:27093884:501:20:1:600:1271:0"

    require_hash "$controller" "$RESCUED_CONTROLLER_SHA256"
    require_hash "$guardian" "$PRESERVED_GUARDIAN_BINARY_SHA256"
    require_hash "$journal" "$RESCUED_TRIAL_JOURNAL_SHA256"
    require_hash "$result" "$EMPTY_SHA256"
    require_hash "$proxy_arm" "$RESCUED_PROXY_ARM_SHA256"
    require_hash "$vpio_state" "$RESCUED_VPIO_STATE_SHA256"
    require_hash "$vpio_stdout" "$RESCUED_GUARDIAN_STDOUT_SHA256"
    require_hash "$vpio_stderr" "$EMPTY_SHA256"
    require_hash "$vpio_snapshot" "$RESCUED_VPIO_SNAPSHOT_SHA256"
    require_hash "$vpio_fence" "$RESCUED_VPIO_FENCE_SHA256"
    require_hash "$vpio_repair" "$RESCUED_VPIO_REPAIR_SHA256"
    require_hash "$vpio_final" "$RESCUED_VPIO_FINAL_SHA256"
    [[ "$(/bin/cat "$journal")" ==
       $'OPENSTEAMER_LOCAL_MONO_TRIAL_V1\nSTATE USER_STAGE_VERIFIED\nSTATE ROOT_OWNED_UID_PROXY pid=21660' &&
       ! -s "$result" &&
       "$(/bin/cat "$proxy_arm")" ==
           $'schema=opensteamer.local-mono-trial-proxy-arm.v1\nproxy_pid=21660\nproxy_start=Sun Aug 16 14:34:47 2026' &&
       "$(/bin/cat "$vpio_stdout")" ==
           $'GUARDIAN_BROKER_READY\nGUARDIAN_BROKER_CHECKED\nGUARDIAN_BROKER_PONG' ]] ||
        fail 'preserved CoreAudio incident transcript changed'
    require_retry_tree_closed "$root"
}

require_preserved_rescued_user_evidence() {
    require_preserved_rescued_trial
    require_preserved_rescued_active_pointer
}

require_failed_loopback_guardian_evidence() {
    local evidence_path="$1"
    local expected_mode="$2"
    local expected_passed="$3"
    local expected_failure="$4"
    local expected_sequence="$5"
    [[ "$(/usr/bin/plutil -extract schema raw -expect string "$evidence_path")" ==
           'opensteamer.v7-default-route-guardian.v1' &&
       "$(/usr/bin/plutil -extract mode raw -expect string "$evidence_path")" ==
           "$expected_mode" &&
       "$(/usr/bin/plutil -extract passed raw -expect bool "$evidence_path")" ==
           "$expected_passed" &&
       "$(/usr/bin/plutil -extract failureCode raw -expect string "$evidence_path")" ==
           "$expected_failure" &&
       "$(/usr/bin/plutil -extract listener.finalSequence raw -expect integer "$evidence_path")" ==
           "$expected_sequence" ]] ||
        fail "failed-loopback guardian evidence semantics changed: $evidence_path"
}

require_failed_loopback_user_trial_at() {
    local root="$1"
    local run_root="$root/paired-v7-update-local-mono-prep-L1Ciab"
    local probes="$run_root/probes"
    local staging="$root/staging"
    local controller="$staging/opensteamer-local-mono-trial-controller"
    local guardian="$staging/opensteamer-v7-default-route-guardian"
    local journal="$root/journal.log"
    local result="$root/result.txt"
    local proxy_arm="$root/proxy.arm"
    local mirror="$probes/mirror-loopback.json"
    local mirror_stdout="$probes/mirror-loopback.stdout"
    local mirror_stderr="$probes/mirror-loopback.stderr"
    local vpio_state="$probes/vpio-default-route-state.json"
    local vpio_stdout="$probes/vpio-guardian.stdout"
    local vpio_stderr="$probes/vpio-guardian.stderr"
    local vpio_snapshot="$probes/vpio-guardian-snapshot.json"
    local vpio_fence="$probes/vpio-guardian-prestop-fence.json"
    local vpio_repair="$probes/vpio-guardian-repair.json"
    local vpio_emergency="$probes/vpio-guardian-emergency-repair.json"
    local vpio_final="$probes/vpio-guardian-final.json"

    [[ -d "$root" && ! -L "$root" && -d "$run_root" && ! -L "$run_root" &&
       -d "$probes" && ! -L "$probes" && -d "$staging" && ! -L "$staging" ]] ||
        fail 'failed-loopback user evidence directory shape changed'
    local regular_node
    for regular_node in "$controller" "$guardian" "$journal" "$result" "$proxy_arm" \
        "$mirror" "$mirror_stdout" "$mirror_stderr" "$vpio_state" "$vpio_stdout" \
        "$vpio_stderr" "$vpio_snapshot" "$vpio_fence" "$vpio_repair" \
        "$vpio_emergency" "$vpio_final"; do
        [[ -f "$regular_node" && ! -L "$regular_node" ]] ||
            fail "failed-loopback user evidence file shape changed: $regular_node"
    done
    require_exact_retry_children "$root" "$journal" "$run_root" "$proxy_arm" "$result" "$staging"
    require_exact_retry_children "$run_root" "$probes"
    require_exact_retry_children "$probes" "$mirror" "$mirror_stdout" "$mirror_stderr" \
        "$vpio_state" "$vpio_stdout" "$vpio_stderr" "$vpio_snapshot" "$vpio_fence" \
        "$vpio_repair" "$vpio_emergency" "$vpio_final"
    require_exact_retry_children "$staging" "$controller" "$guardian"

    require_exact_retry_node "$root" "${DATA_VOLUME_DEVICE}:27209349:501:20:7:700:224:0"
    require_exact_retry_node "$run_root" "${DATA_VOLUME_DEVICE}:27209350:501:20:3:700:96:0"
    require_exact_retry_node "$probes" "${DATA_VOLUME_DEVICE}:27209351:501:20:13:700:416:0"
    require_exact_retry_node "$staging" "${DATA_VOLUME_DEVICE}:27209352:501:20:4:700:128:0"
    require_exact_retry_node "$controller" "${DATA_VOLUME_DEVICE}:27209353:501:20:1:500:1895496:0"
    require_exact_retry_node "$guardian" "${DATA_VOLUME_DEVICE}:27209354:501:20:1:500:258696:0"
    require_exact_retry_node "$journal" "${DATA_VOLUME_DEVICE}:27209861:501:20:1:600:95:0"
    require_exact_retry_node "$result" "${DATA_VOLUME_DEVICE}:27209862:501:20:1:600:228:0"
    require_exact_retry_node "$proxy_arm" "${DATA_VOLUME_DEVICE}:27210035:501:20:1:600:102:0"
    require_exact_retry_node "$vpio_state" "${DATA_VOLUME_DEVICE}:27210147:501:20:1:600:288:0"
    require_exact_retry_node "$vpio_stdout" "${DATA_VOLUME_DEVICE}:27210145:501:20:1:600:88:0"
    require_exact_retry_node "$vpio_stderr" "${DATA_VOLUME_DEVICE}:27210146:501:20:1:600:0:0"
    require_exact_retry_node "$vpio_snapshot" "${DATA_VOLUME_DEVICE}:27210150:501:20:1:600:1275:0"
    require_exact_retry_node "$vpio_fence" "${DATA_VOLUME_DEVICE}:27210158:501:20:1:600:1272:0"
    require_exact_retry_node "$vpio_repair" "${DATA_VOLUME_DEVICE}:27210238:501:20:1:600:1273:0"
    require_exact_retry_node "$vpio_emergency" "${DATA_VOLUME_DEVICE}:27210250:501:20:1:600:1265:0"
    require_exact_retry_node "$vpio_final" "${DATA_VOLUME_DEVICE}:27210242:501:20:1:600:1296:0"
    require_exact_retry_node "$mirror" "${DATA_VOLUME_DEVICE}:27210233:501:20:1:600:9160:0"
    require_exact_retry_node "$mirror_stdout" "${DATA_VOLUME_DEVICE}:27210235:501:20:1:600:0:0"
    require_exact_retry_node "$mirror_stderr" "${DATA_VOLUME_DEVICE}:27210236:501:20:1:600:0:0"

    require_hash "$controller" "$FAILED_LOOPBACK_CONTROLLER_SHA256"
    require_hash "$guardian" "$FAILED_LOOPBACK_GUARDIAN_SHA256"
    require_hash "$journal" "$FAILED_LOOPBACK_JOURNAL_SHA256"
    require_hash "$result" "$FAILED_LOOPBACK_RESULT_SHA256"
    require_hash "$proxy_arm" "$FAILED_LOOPBACK_PROXY_ARM_SHA256"
    require_hash "$mirror" "$FAILED_LOOPBACK_MIRROR_SHA256"
    require_hash "$mirror_stdout" "$EMPTY_SHA256"
    require_hash "$mirror_stderr" "$EMPTY_SHA256"
    require_hash "$vpio_state" "$FAILED_LOOPBACK_VPIO_STATE_SHA256"
    require_hash "$vpio_stdout" "$FAILED_LOOPBACK_GUARDIAN_STDOUT_SHA256"
    require_hash "$vpio_stderr" "$EMPTY_SHA256"
    require_hash "$vpio_snapshot" "$FAILED_LOOPBACK_VPIO_SNAPSHOT_SHA256"
    require_hash "$vpio_fence" "$FAILED_LOOPBACK_VPIO_FENCE_SHA256"
    require_hash "$vpio_repair" "$FAILED_LOOPBACK_VPIO_REPAIR_SHA256"
    require_hash "$vpio_emergency" "$FAILED_LOOPBACK_VPIO_EMERGENCY_SHA256"
    require_hash "$vpio_final" "$FAILED_LOOPBACK_VPIO_FINAL_SHA256"
    [[ "$(/bin/cat "$journal")" ==
           $'OPENSTEAMER_LOCAL_MONO_TRIAL_V1\nSTATE USER_STAGE_VERIFIED\nSTATE ROOT_OWNED_UID_PROXY pid=72135' &&
       "$(/bin/cat "$result")" ==
           $'LOCAL_MONO_TRIAL_FAILED installed-driver both-order mono loopback failed; retained guardian finally cleanup=Ok(OwnedSessionTermination { status: ExitStatus(unix_wait_status(256)), diagnostics: [] })\nLOCAL_MONO_TRIAL_ROLLED_BACK' &&
       "$(/bin/cat "$proxy_arm")" ==
           $'schema=opensteamer.local-mono-trial-proxy-arm.v1\nproxy_pid=72135\nproxy_start=Mon Aug 17 00:17:36 2026' &&
       "$(/bin/cat "$vpio_stdout")" ==
           $'GUARDIAN_BROKER_READY\nGUARDIAN_BROKER_CHECKED\nGUARDIAN_BROKER_PONG\nGUARDIAN_BROKER_PONG' ]] ||
        fail 'failed-loopback user evidence transcript changed'
    require_failed_loopback_guardian_evidence "$vpio_snapshot" broker-snapshot true none 0
    require_failed_loopback_guardian_evidence "$vpio_fence" broker-fence true none 0
    require_failed_loopback_guardian_evidence "$vpio_repair" broker-repair true none 3
    require_failed_loopback_guardian_evidence "$vpio_emergency" repair true none 0
    require_failed_loopback_guardian_evidence \
        "$vpio_final" broker-final false broker_final_repair_unproved 3
    require_retry_tree_closed "$root"
}

require_public_root_socket() {
    local socket_path="$1"
    [[ -S "$socket_path" && ! -L "$socket_path" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$socket_path")" ==
           "${DATA_VOLUME_DEVICE}:27093415:501:20:1:600:0:0" ]] ||
        fail 'D1 broker socket identity changed'
    local socket_acl socket_xattrs socket_xattr_status socket_expected
    socket_acl=$(/bin/ls -lde "$socket_path") || fail 'could not inspect D1 broker socket ACL'
    [[ "$(print -r -- "$socket_acl" | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" == '1' ]] ||
        fail 'D1 broker socket has an ACL'
    set +e
    socket_xattrs=$(/usr/bin/xattr "$socket_path" 2>&1)
    socket_xattr_status=$?
    set -e
    socket_expected="xattr: [Errno 102] Operation not supported on socket: '$socket_path'"
    [[ "$socket_xattr_status" == '1' && "$socket_xattrs" == "$socket_expected" ]] ||
        fail 'D1 broker socket did not return exact ENOTSUP evidence'
    local openers lsof_status
    set +e
    openers=$(/usr/sbin/lsof -Fn -- "$socket_path" 2>/dev/null)
    lsof_status=$?
    set -e
    [[ "$lsof_status" == '1' && -z "$openers" ]] || fail 'D1 broker socket is open'
}

require_public_d1_root_shell_at() {
    local support_path="$1"
    local controller="$support_path/opensteamer-local-mono-trial-controller"
    local pin="$support_path/controller.sha256"
    local log="$support_path/root-broker.log"
    local transaction="$support_path/private-transaction-prep-L1Ciab"
    local sealed="$support_path/sealed-prep-L1Ciab"
    local socket_path="$support_path/broker-prep-L1Ciab.sock"
    [[ -d "$support_path" && ! -L "$support_path" &&
       -f "$controller" && ! -L "$controller" && -f "$pin" && ! -L "$pin" &&
       -f "$log" && ! -L "$log" && -d "$transaction" && ! -L "$transaction" &&
       -d "$sealed" && ! -L "$sealed" ]] || fail 'D1 root shell shape changed'
    [[ "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$support_path")" ==
           "${DATA_VOLUME_DEVICE}:27093234:0:0:8:711:256:0" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$controller")" ==
           "${DATA_VOLUME_DEVICE}:27093235:0:0:1:500:1443880:0" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$pin")" ==
           "${DATA_VOLUME_DEVICE}:27093236:0:0:1:400:65:0" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$log")" ==
           "${DATA_VOLUME_DEVICE}:27093237:0:0:1:600:357:0" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$transaction")" ==
           "${DATA_VOLUME_DEVICE}:27093238:0:0:5:700:160:0" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$sealed")" ==
           "${DATA_VOLUME_DEVICE}:27093240:0:0:9:511:288:0" ]] || fail 'D1 root shell identity changed'
    require_public_root_socket "$socket_path"
}

require_public_safe_partial_fresh_root_shell() {
    if [[ ! -e "$FRESH_ROOT_SUPPORT" && ! -L "$FRESH_ROOT_SUPPORT" ]]; then
        return
    fi
    [[ -d "$FRESH_ROOT_SUPPORT" && ! -L "$FRESH_ROOT_SUPPORT" ]] ||
        fail 'root-only retry staging path has an unsafe kind'
    local controller="$FRESH_ROOT_SUPPORT/opensteamer-local-mono-trial-controller"
    local pin="$FRESH_ROOT_SUPPORT/controller.sha256"
    local log="$FRESH_ROOT_SUPPORT/root-broker.log"
    local entries unexpected entry_status
    entries=$(/usr/bin/find "$FRESH_ROOT_SUPPORT" -xdev -mindepth 1 -maxdepth 1 -print)
    if [[ -n "$entries" ]]; then
        set +e
        unexpected=$(print -r -- "$entries" | /usr/bin/grep -F -v -x \
            -e "$controller" -e "$pin" -e "$log")
        entry_status=$?
        set -e
        [[ "$entry_status" == '1' && -z "$unexpected" ]] ||
            fail 'partial root retry staging directory has an unexpected child'
    fi
    local present=0
    local node_stat node_size
    if [[ -e "$controller" || -L "$controller" ]]; then
        [[ -f "$controller" && ! -L "$controller" ]] ||
            fail 'partial root controller stage has an unsafe kind'
        node_stat=$(/usr/bin/stat -f '%d:%u:%g:%l:%Lp:%f' "$controller")
        node_size=$(/usr/bin/stat -f '%z' "$controller")
        [[ "$node_stat" == "${DATA_VOLUME_DEVICE}:0:0:1:500:0" && "$node_size" == <-> &&
           "$node_size" -le "$EXPECTED_CONTROLLER_BINARY_SIZE" ]] ||
            fail 'partial root controller stage metadata changed'
        (( present += 1 ))
    fi
    if [[ -e "$pin" || -L "$pin" ]]; then
        [[ -f "$pin" && ! -L "$pin" ]] || fail 'partial root pin has an unsafe kind'
        node_stat=$(/usr/bin/stat -f '%d:%u:%g:%l:%Lp:%f' "$pin")
        node_size=$(/usr/bin/stat -f '%z' "$pin")
        [[ ( "$node_stat" == "${DATA_VOLUME_DEVICE}:0:0:1:400:0" ||
             "$node_stat" == "${DATA_VOLUME_DEVICE}:0:0:1:600:0" ) &&
           "$node_size" == <-> && "$node_size" -le 65 ]] ||
            fail 'partial root pin metadata changed'
        (( present += 1 ))
    fi
    if [[ -e "$log" || -L "$log" ]]; then
        [[ -f "$log" && ! -L "$log" ]] || fail 'partial root log has an unsafe kind'
        [[ "$(/usr/bin/stat -f '%d:%u:%g:%l:%Lp:%z:%f' "$log")" ==
           "${DATA_VOLUME_DEVICE}:0:0:1:600:0:0" ]] || fail 'partial root log metadata changed'
        (( present += 1 ))
    fi
    local expected_directory_stat="${DATA_VOLUME_DEVICE}:0:0:$((present + 2)):711:$((64 + 32 * present)):0"
    [[ "$(/usr/bin/stat -f '%d:%u:%g:%l:%Lp:%z:%f' "$FRESH_ROOT_SUPPORT")" ==
       "$expected_directory_stat" ]] || fail 'partial root retry staging directory changed'
    local partial_xattrs partial_acl_lines
    partial_xattrs=$(/usr/bin/xattr -lr "$FRESH_ROOT_SUPPORT") ||
        fail 'could not inspect partial root retry staging xattrs'
    [[ -z "$partial_xattrs" ]] || fail 'partial root retry staging has extended attributes'
    partial_acl_lines=$(/usr/bin/find "$FRESH_ROOT_SUPPORT" -xdev -exec /bin/ls -lde {} \; |
        /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')
    [[ "$partial_acl_lines" == "$((present + 1))" ]] ||
        fail 'partial root retry staging has an ACL'
    require_retry_tree_closed "$FRESH_ROOT_SUPPORT"
}

require_public_fresh_root_shell_at() {
    local support_path="$1"
    local controller="$support_path/opensteamer-local-mono-trial-controller"
    local pin="$support_path/controller.sha256"
    local log="$support_path/root-broker.log"
    [[ -d "$support_path" && ! -L "$support_path" &&
       -f "$controller" && ! -L "$controller" &&
       -f "$pin" && ! -L "$pin" && -f "$log" && ! -L "$log" ]] ||
        fail 'fresh root broker shell has an unsafe kind'
    [[ "$(/usr/bin/stat -f '%d:%u:%g:%l:%Lp:%z:%f' "$support_path")" ==
           "${DATA_VOLUME_DEVICE}:0:0:5:711:160:0" &&
       "$(/usr/bin/stat -f '%d:%u:%g:%l:%Lp:%z:%f' "$controller")" ==
           "${DATA_VOLUME_DEVICE}:0:0:1:500:$EXPECTED_CONTROLLER_BINARY_SIZE:0" &&
       "$(/usr/bin/stat -f '%d:%u:%g:%l:%Lp:%z:%f' "$pin")" ==
           "${DATA_VOLUME_DEVICE}:0:0:1:400:65:0" &&
       "$(/usr/bin/stat -f '%d:%u:%g:%l:%Lp:%z:%f' "$log")" ==
           "${DATA_VOLUME_DEVICE}:0:0:1:600:0:0" ]] || fail 'fresh root broker shell metadata changed'
    require_hash "$controller" "$EXPECTED_CONTROLLER_BINARY_SHA256"
    [[ "$(/bin/cat "$pin")" == "$EXPECTED_CONTROLLER_BINARY_SHA256" &&
       ! -s "$log" ]] || fail 'fresh root broker shell contents changed'
    require_plain_retry_node "$support_path" '0:0:5:711:160:0'
    require_plain_retry_node "$controller" \
        "0:0:1:500:$EXPECTED_CONTROLLER_BINARY_SIZE:0"
    require_plain_retry_node "$pin" '0:0:1:400:65:0'
    require_plain_retry_node "$log" '0:0:1:600:0:0'
    require_retry_tree_closed "$support_path"
}

require_bound_failed_loopback_root_capture() {
    [[ "$EXPECTED_ROOT_CAPTURE_ENVELOPE_SHA256" != *PIN_AFTER* ]] ||
        fail 'failed-loopback root evidence capture is not release-pinned' 78
    require_root_capture_envelope_file "$ROOT_CAPTURE_READY" 1
    require_hash "$ROOT_CAPTURE_READY" "$EXPECTED_ROOT_CAPTURE_ENVELOPE_SHA256"
}

require_public_failed_loopback_root_shell_at() {
    local support_path="$1"
    local controller="$support_path/opensteamer-local-mono-trial-controller"
    local pin="$support_path/controller.sha256"
    local log="$support_path/root-broker.log"
    local transaction="$support_path/private-transaction-prep-L1Ciab"
    local sealed="$support_path/sealed-prep-L1Ciab"
    local sealed_host="$sealed/opensteamer Host.app"
    local sealed_mirror="$sealed/physical-blackhole-microphone-probe"
    local sealed_vpio="$sealed/opensteamer-public-vpio-probe"
    local sealed_guardian="$sealed/opensteamer-v7-default-route-guardian"
    local sealed_controller="$sealed/opensteamer-local-mono-trial-controller"
    local sealed_pin="$sealed/controller.sha256"
    local sealed_proxy="$sealed/uid501-proxy.identity"
    local socket_path="$support_path/broker-prep-L1Ciab.sock"
    [[ -d "$support_path" && ! -L "$support_path" &&
       -f "$controller" && ! -L "$controller" && -f "$pin" && ! -L "$pin" &&
       -f "$log" && ! -L "$log" && -d "$transaction" && ! -L "$transaction" &&
       -d "$sealed" && ! -L "$sealed" && -d "$sealed_host" && ! -L "$sealed_host" &&
       -f "$sealed_mirror" && ! -L "$sealed_mirror" &&
       -f "$sealed_vpio" && ! -L "$sealed_vpio" &&
       -f "$sealed_guardian" && ! -L "$sealed_guardian" &&
       -f "$sealed_controller" && ! -L "$sealed_controller" &&
       -f "$sealed_pin" && ! -L "$sealed_pin" &&
       -f "$sealed_proxy" && ! -L "$sealed_proxy" &&
       -S "$socket_path" && ! -L "$socket_path" ]] ||
        fail 'failed-loopback root evidence public shape changed'
    [[ "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$support_path")" ==
           "${DATA_VOLUME_DEVICE}:27209685:0:0:8:711:256:0" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$controller")" ==
           "${DATA_VOLUME_DEVICE}:27209686:0:0:1:500:1895496:0" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$pin")" ==
           "${DATA_VOLUME_DEVICE}:27209687:0:0:1:400:65:0" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$log")" ==
           "${DATA_VOLUME_DEVICE}:27209688:0:0:1:600:330:0" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$transaction")" ==
           "${DATA_VOLUME_DEVICE}:27209858:0:0:5:700:160:0" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$sealed")" ==
           "${DATA_VOLUME_DEVICE}:27209860:0:0:9:511:288:0" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$sealed_host")" ==
           "${DATA_VOLUME_DEVICE}:27209871:0:0:3:755:96:0" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$sealed_mirror")" ==
           "${DATA_VOLUME_DEVICE}:27210025:0:0:1:555:989184:0" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$sealed_vpio")" ==
           "${DATA_VOLUME_DEVICE}:27210026:0:0:1:555:154912:0" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$sealed_guardian")" ==
           "${DATA_VOLUME_DEVICE}:27210027:0:0:1:555:258696:0" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$sealed_controller")" ==
           "${DATA_VOLUME_DEVICE}:27210028:0:0:1:555:1895496:0" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$sealed_pin")" ==
           "${DATA_VOLUME_DEVICE}:27210029:0:0:1:444:65:0" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$sealed_proxy")" ==
           "${DATA_VOLUME_DEVICE}:27210032:0:0:1:444:97:0" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$socket_path")" ==
           "${DATA_VOLUME_DEVICE}:27210031:501:20:1:600:0:0" ]] ||
        fail 'failed-loopback root evidence public identity changed'
    local socket_acl socket_xattrs socket_xattr_status socket_expected
    socket_acl=$(/bin/ls -lde "$socket_path") ||
        fail 'could not inspect failed-loopback broker socket ACL'
    [[ "$(print -r -- "$socket_acl" | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" ==
       '1' ]] || fail 'failed-loopback broker socket has an ACL'
    set +e
    socket_xattrs=$(/usr/bin/xattr "$socket_path" 2>&1)
    socket_xattr_status=$?
    set -e
    socket_expected="xattr: [Errno 102] Operation not supported on socket: '$socket_path'"
    [[ "$socket_xattr_status" == '1' && "$socket_xattrs" == "$socket_expected" ]] ||
        fail 'failed-loopback broker socket xattr observation changed'
    require_retry_tree_closed "$support_path"
    require_bound_failed_loopback_root_capture
}

classify_failed_loopback_root_state() {
    require_data_volume_identity
    require_prior_root_evidence_public
    [[ ! -e "$LEGACY_FRESH_ROOT_SUPPORT" && ! -L "$LEGACY_FRESH_ROOT_SUPPORT" ]] ||
        fail 'legacy root fresh-stage path unexpectedly reappeared'
    local canonical_present=0 evidence_present=0 fresh_present=0
    [[ -e "$ROOT_SUPPORT" || -L "$ROOT_SUPPORT" ]] && canonical_present=1
    [[ -e "$FAILED_LOOPBACK_ROOT_SUPPORT" || -L "$FAILED_LOOPBACK_ROOT_SUPPORT" ]] &&
        evidence_present=1
    [[ -e "$FRESH_ROOT_SUPPORT" || -L "$FRESH_ROOT_SUPPORT" ]] && fresh_present=1
    if (( canonical_present == 1 && evidence_present == 0 )); then
        require_public_failed_loopback_root_shell_at "$ROOT_SUPPORT"
        require_public_safe_partial_fresh_root_shell
        if (( fresh_present == 1 )) &&
           [[ -f "$FRESH_ROOT_SUPPORT/opensteamer-local-mono-trial-controller" &&
              ! -L "$FRESH_ROOT_SUPPORT/opensteamer-local-mono-trial-controller" &&
              -f "$FRESH_ROOT_SUPPORT/controller.sha256" &&
              ! -L "$FRESH_ROOT_SUPPORT/controller.sha256" &&
              -f "$FRESH_ROOT_SUPPORT/root-broker.log" &&
              ! -L "$FRESH_ROOT_SUPPORT/root-broker.log" ]]; then
            require_public_fresh_root_shell_at "$FRESH_ROOT_SUPPORT"
            ROOT_RETRY_STATE='R1'
        else
            ROOT_RETRY_STATE='R0'
        fi
    elif (( canonical_present == 0 && evidence_present == 1 && fresh_present == 1 )); then
        require_public_failed_loopback_root_shell_at "$FAILED_LOOPBACK_ROOT_SUPPORT"
        require_public_fresh_root_shell_at "$FRESH_ROOT_SUPPORT"
        ROOT_RETRY_STATE='R2'
    elif (( canonical_present == 1 && evidence_present == 1 && fresh_present == 0 )); then
        require_public_failed_loopback_root_shell_at "$FAILED_LOOPBACK_ROOT_SUPPORT"
        require_public_fresh_root_shell_at "$ROOT_SUPPORT"
        ROOT_RETRY_STATE='R3'
    else
        fail 'failed-loopback root retry state is not exact R0, R1, R2, or R3'
    fi
    RETRY_STATE="$USER_RETRY_STATE/$ROOT_RETRY_STATE"
}

require_prior_root_evidence_public() {
    local first='/Library/Application Support/opensteamer-local-mono-trial-v1.failed-root-prepare-pin-mode-L1Ciab'
    local second='/Library/Application Support/opensteamer-local-mono-trial-v1.failed-uid-admission-L1Ciab'
    [[ -d "$first" && ! -L "$first" && -d "$second" && ! -L "$second" &&
       -d "$FAILED_CANDIDATE_ROOT_SUPPORT" && ! -L "$FAILED_CANDIDATE_ROOT_SUPPORT" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$first")" ==
           "${DATA_VOLUME_DEVICE}:27006986:0:0:7:711:224:0" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$second")" ==
           "${DATA_VOLUME_DEVICE}:27016896:0:0:8:711:256:0" &&
       "$(/usr/bin/stat -f '%d:%i:%u:%g:%l:%Lp:%z:%f' "$FAILED_CANDIDATE_ROOT_SUPPORT")" ==
           "${DATA_VOLUME_DEVICE}:27021963:0:0:8:711:256:0" ]] ||
        fail 'prior root evidence identity changed'
    require_public_d1_root_shell_at "$FAILED_COREAUDIO_ROOT_SUPPORT"
}

require_complete_pre_root_user_stage_at() {
    local stage_root="$1"
    local run_root="$stage_root/paired-v7-update-local-mono-prep-L1Ciab"
    local probes="$run_root/probes"
    local stage_dir="$stage_root/staging"
    local staged_controller="$stage_dir/opensteamer-local-mono-trial-controller"
    local staged_guardian="$stage_dir/opensteamer-v7-default-route-guardian"
    local journal="$stage_root/journal.log"
    local result="$stage_root/result.txt"
    local proxy_arm="$stage_root/proxy.arm"
    local stop_request="$stage_root/stop.request"
    [[ -d "$stage_root" && ! -L "$stage_root" &&
       -d "$run_root" && ! -L "$run_root" &&
       -d "$probes" && ! -L "$probes" &&
       -d "$stage_dir" && ! -L "$stage_dir" &&
       -f "$staged_controller" && ! -L "$staged_controller" &&
       -f "$staged_guardian" && ! -L "$staged_guardian" &&
       ! -e "$journal" && ! -L "$journal" &&
       ! -e "$result" && ! -L "$result" &&
       ! -e "$proxy_arm" && ! -L "$proxy_arm" &&
       ! -e "$stop_request" && ! -L "$stop_request" ]] ||
        fail 'fresh pre-root user stage shape changed'
    require_exact_retry_child_count "$stage_root" '2'
    require_exact_retry_child_count "$run_root" '1'
    require_exact_retry_child_count "$probes" '0'
    require_exact_retry_child_count "$stage_dir" '2'
    require_plain_retry_node "$stage_root" '501:20:4:700:128:0'
    require_plain_retry_node "$run_root" '501:20:3:700:96:0'
    require_plain_retry_node "$probes" '501:20:2:700:64:0'
    require_plain_retry_node "$stage_dir" '501:20:4:700:128:0'
    require_plain_retry_node "$staged_controller" \
        "501:20:1:500:$EXPECTED_CONTROLLER_BINARY_SIZE:0"
    require_plain_retry_node "$staged_guardian" \
        "501:20:1:500:$EXPECTED_GUARDIAN_BINARY_SIZE:0"
    require_hash "$staged_controller" "$EXPECTED_CONTROLLER_BINARY_SHA256"
    require_hash "$staged_guardian" "$EXPECTED_GUARDIAN_BINARY_SHA256"
    require_retry_tree_closed "$stage_root"
}

classify_failed_loopback_user_state() {
    require_data_volume_identity
    [[ ! -e "$ACTIVE_POINTER" && ! -L "$ACTIVE_POINTER" &&
       ! -e "$ACTIVE_POINTER_TEMP" && ! -L "$ACTIVE_POINTER_TEMP" &&
       ! -e "$PRODUCT_DRIVER" && ! -L "$PRODUCT_DRIVER" &&
       ! -e "$LEGACY_USER_STAGE_READY_ROOT" && ! -L "$LEGACY_USER_STAGE_READY_ROOT" ]] ||
        fail 'failed-loopback user retry baseline changed'
    require_preserved_failed_uid_admission_user_evidence
    require_preserved_failed_candidate_user_evidence
    require_preserved_rescued_user_evidence

    local canonical_present=0 evidence_present=0 ready_present=0
    [[ -e "$TRIAL_ROOT" || -L "$TRIAL_ROOT" ]] && canonical_present=1
    [[ -e "$FAILED_LOOPBACK_TRIAL_ROOT" || -L "$FAILED_LOOPBACK_TRIAL_ROOT" ]] &&
        evidence_present=1
    [[ -e "$USER_STAGE_READY_ROOT" || -L "$USER_STAGE_READY_ROOT" ]] && ready_present=1
    if (( canonical_present == 1 && evidence_present == 0 )); then
        require_failed_loopback_user_trial_at "$TRIAL_ROOT"
        if (( ready_present == 1 )); then
            require_complete_pre_root_user_stage_at "$USER_STAGE_READY_ROOT"
        fi
        USER_RETRY_STATE='E0'
    elif (( canonical_present == 0 && evidence_present == 1 && ready_present == 1 )); then
        require_failed_loopback_user_trial_at "$FAILED_LOOPBACK_TRIAL_ROOT"
        require_complete_pre_root_user_stage_at "$USER_STAGE_READY_ROOT"
        USER_RETRY_STATE='E1'
    elif (( canonical_present == 1 && evidence_present == 1 && ready_present == 0 )); then
        require_failed_loopback_user_trial_at "$FAILED_LOOPBACK_TRIAL_ROOT"
        require_complete_pre_root_user_stage_at "$TRIAL_ROOT"
        USER_RETRY_STATE='E2'
    else
        fail 'failed-loopback user retry state is not exact E0, E1, or E2'
    fi
    RETRY_STATE="$USER_RETRY_STATE"
}

advance_failed_loopback_user_state() {
    require_launcher_lock_held
    classify_failed_loopback_user_state
    if [[ "$USER_RETRY_STATE" == 'E0' ]]; then
        stage_live_one_shot
        classify_failed_loopback_user_state
        [[ "$USER_RETRY_STATE" == 'E0' ]] ||
            fail 'failed-loopback ready-stage preparation changed user state unexpectedly'
        require_complete_pre_root_user_stage_at "$USER_STAGE_READY_ROOT"
        require_failed_loopback_user_trial_at "$TRIAL_ROOT"
        [[ ! -e "$FAILED_LOOPBACK_TRIAL_ROOT" && ! -L "$FAILED_LOOPBACK_TRIAL_ROOT" &&
           "$(/usr/bin/stat -f '%d' "$TRIAL_ROOT")" ==
               "$(/usr/bin/stat -f '%d' "$USER_TRIAL_PARENT")" ]] ||
            fail 'failed-loopback U3 publication cannot use one exclusive rename'
        local failed_identity
        failed_identity="$(/usr/bin/stat -f '%d:%i' "$TRIAL_ROOT")"
        /bin/sync
        classify_failed_loopback_user_state
        [[ "$USER_RETRY_STATE" == 'E0' ]] ||
            fail 'failed-loopback E0 changed before U3 publication'
        require_launcher_lock_held
        /bin/mv -n "$TRIAL_ROOT" "$FAILED_LOOPBACK_TRIAL_ROOT"
        [[ ! -e "$TRIAL_ROOT" && ! -L "$TRIAL_ROOT" &&
           "$(/usr/bin/stat -f '%d:%i' "$FAILED_LOOPBACK_TRIAL_ROOT")" ==
               "$failed_identity" ]] ||
            fail 'failed-loopback U3 publication was not inode-preserving'
        classify_failed_loopback_user_state
        [[ "$USER_RETRY_STATE" == 'E1' ]] ||
            fail 'failed-loopback user retry did not reach E1'
        /bin/sync
        classify_failed_loopback_user_state
        [[ "$USER_RETRY_STATE" == 'E1' ]] ||
            fail 'failed-loopback E1 durability reproof failed'
    fi
    if [[ "$USER_RETRY_STATE" == 'E1' ]]; then
        require_complete_pre_root_user_stage_at "$USER_STAGE_READY_ROOT"
        require_failed_loopback_user_trial_at "$FAILED_LOOPBACK_TRIAL_ROOT"
        [[ ! -e "$TRIAL_ROOT" && ! -L "$TRIAL_ROOT" &&
           "$(/usr/bin/stat -f '%d' "$USER_STAGE_READY_ROOT")" ==
               "$(/usr/bin/stat -f '%d' "$USER_TRIAL_PARENT")" ]] ||
            fail 'failed-loopback fresh canonical publication cannot use one exclusive rename'
        local ready_identity
        ready_identity="$(/usr/bin/stat -f '%d:%i' "$USER_STAGE_READY_ROOT")"
        /bin/sync
        classify_failed_loopback_user_state
        [[ "$USER_RETRY_STATE" == 'E1' ]] ||
            fail 'failed-loopback E1 changed before canonical publication'
        require_launcher_lock_held
        /bin/mv -n "$USER_STAGE_READY_ROOT" "$TRIAL_ROOT"
        [[ ! -e "$USER_STAGE_READY_ROOT" && ! -L "$USER_STAGE_READY_ROOT" &&
           "$(/usr/bin/stat -f '%d:%i' "$TRIAL_ROOT")" == "$ready_identity" ]] ||
            fail 'failed-loopback fresh canonical publication was not inode-preserving'
        classify_failed_loopback_user_state
        [[ "$USER_RETRY_STATE" == 'E2' ]] ||
            fail 'failed-loopback user retry did not reach E2'
        /bin/sync
        classify_failed_loopback_user_state
        [[ "$USER_RETRY_STATE" == 'E2' ]] ||
            fail 'failed-loopback E2 durability reproof failed'
    fi
}

classify_retry_state() {
    classify_failed_loopback_user_state
    classify_failed_loopback_root_state
    case "$USER_RETRY_STATE/$ROOT_RETRY_STATE" in
        E0/R0|E1/R0|E2/R0|E2/R1|E2/R2|E2/R3)
            RETRY_STATE="$USER_RETRY_STATE/$ROOT_RETRY_STATE"
            ;;
        *)
            fail 'failed-loopback composite retry state is outside the E0-E2/R0-R3 lattice'
            ;;
    esac
}

stage_live_one_shot() {
    require_launcher_lock_held
    [[ "$USER_RETRY_STATE" == 'E0' ]] ||
        fail 'fresh failed-loopback user stage preparation is outside E0'
    [[ "$EXPECTED_CONTROLLER_BINARY_SHA256" != *PIN_AFTER* ]] ||
        fail 'local-trial controller postimage is not release-pinned' 78
    require_failed_loopback_user_trial_at "$TRIAL_ROOT"
    [[ ! -e "$FAILED_LOOPBACK_TRIAL_ROOT" && ! -L "$FAILED_LOOPBACK_TRIAL_ROOT" ]] ||
        fail 'failed-loopback U3 evidence destination is already present'
    [[ ! -e "$ACTIVE_POINTER" && ! -L "$ACTIVE_POINTER" ]] ||
        fail 'active local-trial pointer is already present'
    if [[ ! -e "$USER_TRIAL_PARENT" && ! -L "$USER_TRIAL_PARENT" ]]; then
        /bin/mkdir "$USER_TRIAL_PARENT"
        /bin/chmod 0700 "$USER_TRIAL_PARENT"
    fi
    [[ -d "$USER_TRIAL_PARENT" && ! -L "$USER_TRIAL_PARENT" &&
       "$(/usr/bin/stat -f '%u:%g:%Lp' "$USER_TRIAL_PARENT")" == '501:20:700' ]] ||
        fail 'local-trial parent metadata is unsafe'
    local publish_root="$BUILD_ROOT/pre-root-user-stage.publish-L1Ciab"
    local publish_run_root="$publish_root/paired-v7-update-local-mono-prep-L1Ciab"
    local publish_probes="$publish_run_root/probes"
    local publish_stage_dir="$publish_root/staging"
    local publish_controller="$publish_stage_dir/opensteamer-local-mono-trial-controller"
    local publish_guardian="$publish_stage_dir/opensteamer-v7-default-route-guardian"
    [[ ! -e "$publish_root" && ! -L "$publish_root" ]] ||
        fail 'private pre-root user-stage build path is not fresh'
    if [[ ! -e "$USER_STAGE_READY_ROOT" && ! -L "$USER_STAGE_READY_ROOT" ]]; then
        /bin/mkdir "$publish_root"
        /bin/chmod 0700 "$publish_root"
        /bin/mkdir "$publish_run_root"
        /bin/chmod 0700 "$publish_run_root"
        /bin/mkdir "$publish_probes"
        /bin/chmod 0700 "$publish_probes"
        /bin/mkdir "$publish_stage_dir"
        /bin/chmod 0700 "$publish_stage_dir"
        require_hash "$CONTROLLER" "$EXPECTED_CONTROLLER_BINARY_SHA256"
        require_hash "$GUARDIAN" "$EXPECTED_GUARDIAN_BINARY_SHA256"
        /usr/bin/install -m 0500 "$CONTROLLER" "$publish_controller"
        /usr/bin/install -m 0500 "$GUARDIAN" "$publish_guardian"
        require_complete_pre_root_user_stage_at "$publish_root"
        [[ "$(/usr/bin/stat -f '%d' "$publish_root")" ==
           "$(/usr/bin/stat -f '%d' "$USER_TRIAL_PARENT")" ]] ||
            fail 'pre-root user-stage publication crossed filesystems'
        local private_publish_identity
        private_publish_identity="$(/usr/bin/stat -f '%d:%i' "$publish_root")"
        /bin/sync
        require_complete_pre_root_user_stage_at "$publish_root"
        [[ ! -e "$USER_STAGE_READY_ROOT" && ! -L "$USER_STAGE_READY_ROOT" ]] ||
            fail 'fixed ready pre-root user-stage path raced publication'
        require_launcher_lock_held
        /bin/mv -n "$publish_root" "$USER_STAGE_READY_ROOT"
        [[ ! -e "$publish_root" && ! -L "$publish_root" &&
           "$(/usr/bin/stat -f '%d:%i' "$USER_STAGE_READY_ROOT")" ==
               "$private_publish_identity" ]] ||
            fail 'ready pre-root user-stage publication was not inode-preserving'
        require_complete_pre_root_user_stage_at "$USER_STAGE_READY_ROOT"
        /bin/sync
    fi
    require_complete_pre_root_user_stage_at "$USER_STAGE_READY_ROOT"
    [[ "$(/usr/bin/stat -f '%d' "$USER_STAGE_READY_ROOT")" ==
       "$(/usr/bin/stat -f '%d' "$USER_TRIAL_PARENT")" ]] ||
        fail 'ready pre-root user-stage is on the wrong filesystem'
    require_hash "$CONTROLLER" "$EXPECTED_CONTROLLER_BINARY_SHA256"
    require_hash "$GUARDIAN" "$EXPECTED_GUARDIAN_BINARY_SHA256"
    require_failed_loopback_user_trial_at "$TRIAL_ROOT"
    require_launcher_lock_held
}

[[ "$#" == '1' ]] || usage
readonly MODE="$1"
case "$MODE" in
    "$SELF_TEST_MODE"|"$PREFLIGHT_MODE"|"$CAPTURE_MODE")
        ;;
    "$START_MODE"|"$STOP_MODE")
        [[ "$LIVE_RELEASE_STATUS" == "$LIVE_RELEASE_READY" ]] ||
            fail "$MODE is disabled until the detached rollback path and final pins are release-audited" 78
        ;;
    "$ROOT_MODE")
        fail "$ROOT_MODE is a fixed root-owned broker mode and is never a public launcher mode" 78
        ;;
    *)
        usage
        ;;
esac

require_launcher_identity
require_data_volume_identity
require_retry_preservation_contract
require_preserved_failed_uid_admission_user_evidence
require_preserved_failed_candidate_user_evidence
require_preserved_rescued_user_evidence
if [[ "$MODE" == "$CAPTURE_MODE" ]]; then
    acquire_launcher_lock
    capture_root_evidence_once
    exit 0
fi
require_toolchain
require_guardian_toolchain
require_reviewed_source "$SOURCE" "$EXPECTED_CONTROLLER_SOURCE_SHA256"
require_reviewed_source "$V7_SOURCE" "$EXPECTED_V7_SOURCE_SHA256"
require_reviewed_source "$V1_SOURCE" "$EXPECTED_V1_SOURCE_SHA256"
require_reviewed_source "$GUARDIAN_SOURCE" "$EXPECTED_GUARDIAN_SOURCE_SHA256"

[[ -d "$BUILD_PARENT" && ! -L "$BUILD_PARENT" ]] ||
    fail 'private opensteamer application-support directory is unavailable'
[[ "$(/usr/bin/stat -f '%u:%g:%Lp' "$BUILD_PARENT")" == '501:20:700' ]] ||
    fail 'private opensteamer application-support directory metadata is unsafe'

readonly BUILD_ROOT="$(/usr/bin/mktemp -d "$BUILD_PARENT/.local-mono-trial-launcher-build.XXXXXX")"
cleanup() {
    if [[ -d "$BUILD_ROOT" && ! -L "$BUILD_ROOT" &&
          "$(/usr/bin/stat -f '%u:%g:%Lp' "$BUILD_ROOT" 2>/dev/null)" == '501:20:700' ]]; then
        /bin/chmod -R u+w "$BUILD_ROOT" 2>/dev/null || true
        /bin/rm -rf -- "$BUILD_ROOT"
    fi
}
abort_on_signal() {
    trap - EXIT HUP INT TERM
    cleanup
    exit 130
}
trap cleanup EXIT
trap abort_on_signal HUP INT TERM

/bin/chmod 700 "$BUILD_ROOT"
[[ "$(/usr/bin/stat -f '%u:%g:%Lp' "$BUILD_ROOT")" == '501:20:700' ]] ||
    fail 'private local-trial build directory metadata is unsafe'

readonly SNAPSHOT_SOURCE="$BUILD_ROOT/opensteamer-host-local-mono-trial-controller.rs"
readonly SNAPSHOT_V7_SOURCE="$BUILD_ROOT/opensteamer-host-paired-v7-update-controller.rs"
readonly SNAPSHOT_V1_SOURCE="$BUILD_ROOT/opensteamer-host-post-v20-update-controller.rs"
readonly SNAPSHOT_GUARDIAN_SOURCE="$BUILD_ROOT/V7DefaultRouteGuardian.swift"
readonly UNBOUNDED_INCLUDED_SOURCE="$BUILD_ROOT/opensteamer-host-post-v20-update-controller.unbounded.module.rs"
readonly V1_COMMAND_OUTPUT_SOURCE_SLICE="$BUILD_ROOT/v1-command-output.source.rs"
readonly INCLUDED_SOURCE="$BUILD_ROOT/opensteamer-host-post-v20-update-controller.module.rs"
readonly TRANSFORMED_GUARDIAN_SOURCE="$BUILD_ROOT/guardian.local.swift"
readonly CONTROLLER="$BUILD_ROOT/controller"
readonly FIRST_CONTROLLER="$BUILD_ROOT/controller.first"
readonly GUARDIAN="$BUILD_ROOT/opensteamer-v7-default-route-guardian"
readonly FIRST_GUARDIAN="$BUILD_ROOT/opensteamer-v7-default-route-guardian.first"
readonly GUARDIAN_SELF_TEST_RESULT="$BUILD_ROOT/guardian-self-test.json"
readonly COMPILER_TEMP="$BUILD_ROOT/compiler-tmp"

/usr/bin/install -m 0400 "$SOURCE" "$SNAPSHOT_SOURCE"
/usr/bin/install -m 0400 "$V7_SOURCE" "$SNAPSHOT_V7_SOURCE"
/usr/bin/install -m 0400 "$V1_SOURCE" "$SNAPSHOT_V1_SOURCE"
/usr/bin/install -m 0400 "$GUARDIAN_SOURCE" "$SNAPSHOT_GUARDIAN_SOURCE"
for snapshot in "$SNAPSHOT_SOURCE" "$SNAPSHOT_V7_SOURCE" "$SNAPSHOT_V1_SOURCE" \
                "$SNAPSHOT_GUARDIAN_SOURCE"; do
    require_private_snapshot "$snapshot"
done
require_hash "$SNAPSHOT_SOURCE" "$EXPECTED_CONTROLLER_SOURCE_SHA256"
require_hash "$SNAPSHOT_V7_SOURCE" "$EXPECTED_V7_SOURCE_SHA256"
require_hash "$SNAPSHOT_V1_SOURCE" "$EXPECTED_V1_SOURCE_SHA256"
require_hash "$SNAPSHOT_GUARDIAN_SOURCE" "$EXPECTED_GUARDIAN_SOURCE_SHA256"
require_guardian_maximum_contract "$SNAPSHOT_SOURCE" "$SNAPSHOT_GUARDIAN_SOURCE"
require_live_release_contract "$SNAPSHOT_SOURCE"

/usr/bin/sed '1,7s#^//!#//#' "$SNAPSHOT_V1_SOURCE" > "$UNBOUNDED_INCLUDED_SOURCE"
/bin/chmod 0400 "$UNBOUNDED_INCLUDED_SOURCE"
require_private_snapshot "$UNBOUNDED_INCLUDED_SOURCE"
require_hash "$UNBOUNDED_INCLUDED_SOURCE" "$EXPECTED_UNBOUNDED_INCLUDED_SOURCE_SHA256"

readonly V1_COMMAND_OUTPUT_SIGNATURE='fn command_output(program: &str, arguments: &[&str], cwd: Option<&Path>) -> Result<Output> {'
[[ "$(/usr/bin/grep -F -x -c "$V1_COMMAND_OUTPUT_SIGNATURE" "$UNBOUNDED_INCLUDED_SOURCE")" == '1' ]] ||
    fail 'immutable v1 command-output transform target is not unique'
/usr/bin/awk -v signature="$V1_COMMAND_OUTPUT_SIGNATURE" '
    BEGIN { found = 0; take = 0 }
    $0 == signature {
        if (found != 0) exit 91
        found = 1
        take = 1
    }
    take {
        print
        if ($0 == "}") {
            take = 0
            exit
        }
    }
    END { if (found != 1 || take != 0) exit 92 }
' "$UNBOUNDED_INCLUDED_SOURCE" > "$V1_COMMAND_OUTPUT_SOURCE_SLICE"
/bin/chmod 0400 "$V1_COMMAND_OUTPUT_SOURCE_SLICE"
require_private_snapshot "$V1_COMMAND_OUTPUT_SOURCE_SLICE"
require_hash "$V1_COMMAND_OUTPUT_SOURCE_SLICE" "$EXPECTED_V1_COMMAND_OUTPUT_SOURCE_SHA256"

# The immutable v1 source remains untouched. Only its private include snapshot receives this
# single, exact-range substitution so every inherited command is supervised by the local
# controller's bounded process-group runner.
/usr/bin/awk -v signature="$V1_COMMAND_OUTPUT_SIGNATURE" '
    BEGIN { replaced = 0; skipping = 0 }
    $0 == signature {
        if (replaced != 0) exit 91
        print "fn command_output(program: &str, arguments: &[&str], cwd: Option<&Path>) -> Result<Output> {"
        print "    let mut command = Command::new(program);"
        print "    command"
        print "        .args(arguments)"
        print "        .env_clear()"
        print "        .env(\"LC_ALL\", \"C\")"
        print "        .env(\"HOME\", \"/Users/ahmed\")"
        print "        .env(\"USER\", \"ahmed\")"
        print "        .env(\"LOGNAME\", \"ahmed\")"
        print "        .env(\"PATH\", \"/usr/bin:/bin:/usr/sbin:/sbin\");"
        print "    if let Some(cwd) = cwd {"
        print "        command.current_dir(cwd);"
        print "    }"
        print "    crate::bounded_imported_command_output("
        print "        &mut command,"
        print "        Duration::from_secs(10),"
        print "        4 * 1_048_576,"
        print "        program,"
        print "    )"
        print "    .map_err(ControllerError)"
        print "}"
        replaced = 1
        skipping = 1
        next
    }
    skipping {
        if ($0 == "}") skipping = 0
        next
    }
    { print }
    END { if (replaced != 1 || skipping != 0) exit 92 }
' "$UNBOUNDED_INCLUDED_SOURCE" > "$INCLUDED_SOURCE"
/bin/chmod 0400 "$INCLUDED_SOURCE"
require_private_snapshot "$INCLUDED_SOURCE"
require_hash "$INCLUDED_SOURCE" "$EXPECTED_INCLUDED_SOURCE_SHA256"

readonly GUARDIAN_UPSTREAM_ROOT='static let evidenceRoot = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v7"'
[[ "$(/usr/bin/grep -F -c "$GUARDIAN_UPSTREAM_ROOT" "$SNAPSHOT_GUARDIAN_SOURCE")" == '1' ]] ||
    fail 'default-route guardian local namespace transform is not single-literal'
/usr/bin/sed 's#static let evidenceRoot = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v7"#static let evidenceRoot = "/Users/ahmed/Library/Application Support/opensteamer/local-mono-trials-v1/trial-prep-L1Ciab"#' \
    "$SNAPSHOT_GUARDIAN_SOURCE" > "$TRANSFORMED_GUARDIAN_SOURCE"
/bin/chmod 0400 "$TRANSFORMED_GUARDIAN_SOURCE"
require_private_snapshot "$TRANSFORMED_GUARDIAN_SOURCE"
require_hash "$TRANSFORMED_GUARDIAN_SOURCE" "$EXPECTED_TRANSFORMED_GUARDIAN_SOURCE_SHA256"

# Refuse a source change that raced the private snapshots. The compiler below reads only the
# snapshots and the pinned include, never a mutable repo path.
require_reviewed_source "$SOURCE" "$EXPECTED_CONTROLLER_SOURCE_SHA256"
require_reviewed_source "$V7_SOURCE" "$EXPECTED_V7_SOURCE_SHA256"
require_reviewed_source "$V1_SOURCE" "$EXPECTED_V1_SOURCE_SHA256"
require_reviewed_source "$GUARDIAN_SOURCE" "$EXPECTED_GUARDIAN_SOURCE_SHA256"

/bin/mkdir "$COMPILER_TEMP"
/bin/chmod 0700 "$COMPILER_TEMP"
[[ "$(/usr/bin/stat -f '%u:%g:%Lp' "$COMPILER_TEMP")" == '501:20:700' ]] ||
    fail 'private local-trial compiler temporary directory metadata is unsafe'

compile_controller() {
    (
        cd "$BUILD_ROOT"
        /usr/bin/env -i \
            LC_ALL=C \
            HOME="$PINNED_USER_HOME" \
            PATH="$PINNED_EXEC_PATH" \
            TMPDIR="$COMPILER_TEMP" \
            DEVELOPER_DIR="$PINNED_DEVELOPER_DIR" \
            OPENSTEAMER_PAIRED_V7_INCLUDED_SOURCE="$INCLUDED_SOURCE" \
            "$RUSTC" --edition=2021 -D warnings -C opt-level=2 \
                -C linker="$PINNED_CLANG" \
                --sysroot "$RUSTC_SYSROOT" \
                --remap-path-prefix "$EXPECTED_REPO=/reviewed/opensteamer-local-mono-trial" \
                --remap-path-prefix "$BUILD_ROOT=/reviewed/opensteamer-local-mono-trial-build" \
                "$SNAPSHOT_SOURCE" -o controller
    )
    /bin/chmod 0500 "$CONTROLLER"
    [[ -f "$CONTROLLER" && ! -L "$CONTROLLER" &&
       "$(/usr/bin/stat -f '%u:%g:%l:%Lp:%z:%f' "$CONTROLLER")" ==
           "501:20:1:500:$EXPECTED_CONTROLLER_BINARY_SIZE:0" ]] ||
        fail 'compiled local-trial controller output metadata is unsafe'
    require_hash "$CONTROLLER" "$EXPECTED_CONTROLLER_BINARY_SHA256"
}

compile_guardian() {
    (
        cd "$BUILD_ROOT"
        /usr/bin/env -i \
            LC_ALL=C \
            HOME="$PINNED_USER_HOME" \
            PATH="$PINNED_EXEC_PATH" \
            TMPDIR=compiler-tmp \
            DEVELOPER_DIR="$PINNED_DEVELOPER_DIR" \
            /usr/bin/xcrun --sdk macosx swiftc -O -warnings-as-errors \
                guardian.local.swift -o opensteamer-v7-default-route-guardian
    )
    /bin/chmod 0500 "$GUARDIAN"
}

compile_guardian
/bin/mv "$GUARDIAN" "$FIRST_GUARDIAN"
compile_guardian
/usr/bin/cmp -s "$FIRST_GUARDIAN" "$GUARDIAN" ||
    fail 'two pinned local-trial guardian compilations were not byte-identical'
[[ "$(/usr/bin/stat -f '%u:%g:%l:%Lp:%z' "$GUARDIAN")" ==
   "501:20:1:500:$EXPECTED_GUARDIAN_BINARY_SIZE" ]] ||
    fail 'compiled local-trial guardian metadata is unsafe'
require_hash "$GUARDIAN" "$EXPECTED_GUARDIAN_BINARY_SHA256"

compile_controller
/bin/mv "$CONTROLLER" "$FIRST_CONTROLLER"
compile_controller
/usr/bin/cmp -s "$FIRST_CONTROLLER" "$CONTROLLER" ||
    fail 'two pinned local-trial controller compilations were not byte-identical'
[[ "$(/usr/bin/stat -f '%u:%g:%l:%Lp:%z' "$CONTROLLER")" ==
   "501:20:1:500:$EXPECTED_CONTROLLER_BINARY_SIZE" ]] ||
    fail 'compiled local-trial controller metadata is unsafe'
require_hash "$CONTROLLER" "$EXPECTED_CONTROLLER_BINARY_SHA256"

# Bracket both compiles with fresh proofs of every mutable input and private snapshot.
require_toolchain
require_guardian_toolchain
require_reviewed_source "$SOURCE" "$EXPECTED_CONTROLLER_SOURCE_SHA256"
require_reviewed_source "$V7_SOURCE" "$EXPECTED_V7_SOURCE_SHA256"
require_reviewed_source "$V1_SOURCE" "$EXPECTED_V1_SOURCE_SHA256"
require_reviewed_source "$GUARDIAN_SOURCE" "$EXPECTED_GUARDIAN_SOURCE_SHA256"
require_hash "$SNAPSHOT_SOURCE" "$EXPECTED_CONTROLLER_SOURCE_SHA256"
require_hash "$SNAPSHOT_V7_SOURCE" "$EXPECTED_V7_SOURCE_SHA256"
require_hash "$SNAPSHOT_V1_SOURCE" "$EXPECTED_V1_SOURCE_SHA256"
require_hash "$SNAPSHOT_GUARDIAN_SOURCE" "$EXPECTED_GUARDIAN_SOURCE_SHA256"
require_hash "$UNBOUNDED_INCLUDED_SOURCE" "$EXPECTED_UNBOUNDED_INCLUDED_SOURCE_SHA256"
require_hash "$V1_COMMAND_OUTPUT_SOURCE_SLICE" "$EXPECTED_V1_COMMAND_OUTPUT_SOURCE_SHA256"
require_hash "$INCLUDED_SOURCE" "$EXPECTED_INCLUDED_SOURCE_SHA256"
require_hash "$TRANSFORMED_GUARDIAN_SOURCE" "$EXPECTED_TRANSFORMED_GUARDIAN_SOURCE_SHA256"
require_hash "$CONTROLLER" "$EXPECTED_CONTROLLER_BINARY_SHA256"
require_hash "$GUARDIAN" "$EXPECTED_GUARDIAN_BINARY_SHA256"

if [[ "$MODE" == "$START_MODE" || "$MODE" == "$STOP_MODE" ]]; then
    acquire_launcher_lock
fi
cd "$EXPECTED_REPO"
case "$MODE" in
    "$SELF_TEST_MODE")
        classify_retry_state
        print -- "LOCAL_MONO_TRIAL_PRESERVED_UID_ADMISSION_EVIDENCE_SELF_TEST_OK trial_inode=27016241 active_inode=27017103 active_sha256=$FAILED_UID_ACTIVE_POINTER_SHA256"
        print -- "LOCAL_MONO_TRIAL_POST_RESCUE_RETRY_STATE_SELF_TEST_OK state=$RETRY_STATE rescued_trial_inode=27092973 rescued_active_inode=27093461"
        [[ ! -e "$GUARDIAN_SELF_TEST_RESULT" && ! -L "$GUARDIAN_SELF_TEST_RESULT" ]] ||
            fail 'guardian self-test result path is not fresh'
        /usr/bin/env -i LC_ALL=C HOME="$PINNED_USER_HOME" PATH="$PINNED_EXEC_PATH" \
            USER="$PINNED_USER_NAME" LOGNAME="$PINNED_USER_NAME" \
            "$GUARDIAN" self-test --result "$GUARDIAN_SELF_TEST_RESULT"
        [[ -f "$GUARDIAN_SELF_TEST_RESULT" && ! -L "$GUARDIAN_SELF_TEST_RESULT" &&
           "$(/usr/bin/stat -f '%u:%g:%l:%Lp' "$GUARDIAN_SELF_TEST_RESULT")" ==
               '501:20:1:600' &&
           "$(/usr/bin/grep -F -c '"passed" : "true"' "$GUARDIAN_SELF_TEST_RESULT")" == '1' &&
           "$(/usr/bin/grep -F -c '"mode" : "self-test"' "$GUARDIAN_SELF_TEST_RESULT")" == '1' &&
           "$(/usr/bin/grep -F -c '"cases" : "39"' "$GUARDIAN_SELF_TEST_RESULT")" == '1' ]] ||
            fail 'guardian self-test result is not the reviewed passing shape'
        require_hash "$GUARDIAN_SELF_TEST_RESULT" "$EXPECTED_GUARDIAN_SELF_TEST_SHA256"
        print -- "LOCAL_MONO_TRIAL_GUARDIAN_SELF_TEST_OK cases=39 result_sha256=$(sha256_file "$GUARDIAN_SELF_TEST_RESULT")"
        /usr/bin/env -i LC_ALL=C HOME="$PINNED_USER_HOME" PATH="$PINNED_EXEC_PATH" \
            USER="$PINNED_USER_NAME" LOGNAME="$PINNED_USER_NAME" \
            "$CONTROLLER" "$MODE"
        ;;
    "$PREFLIGHT_MODE")
        classify_retry_state
        /usr/bin/env -i LC_ALL=C HOME="$PINNED_USER_HOME" PATH="$PINNED_EXEC_PATH" \
            USER="$PINNED_USER_NAME" LOGNAME="$PINNED_USER_NAME" \
            "$CONTROLLER" "$RETRY_PREFLIGHT_MODE"
        ;;
    "$START_MODE")
        classify_retry_state
        /usr/bin/env -i LC_ALL=C HOME="$PINNED_USER_HOME" PATH="$PINNED_EXEC_PATH" \
            USER="$PINNED_USER_NAME" LOGNAME="$PINNED_USER_NAME" \
            "$CONTROLLER" "$RETRY_PREFLIGHT_MODE"
        advance_failed_loopback_user_state
        classify_retry_state
        [[ "$USER_RETRY_STATE" == 'E2' ]] ||
            fail 'failed-loopback user retry did not reach E2 before root authorization'
        bootstrap_root_broker_once
        require_launcher_lock_held
        /usr/bin/env -i LC_ALL=C HOME="$PINNED_USER_HOME" PATH="$PINNED_EXEC_PATH" \
            USER="$PINNED_USER_NAME" LOGNAME="$PINNED_USER_NAME" \
            "$USER_CONTROLLER_STAGE" "$START_MODE"
        ;;
    "$STOP_MODE")
        require_launcher_lock_held
        /usr/bin/env -i LC_ALL=C HOME="$PINNED_USER_HOME" PATH="$PINNED_EXEC_PATH" \
            USER="$PINNED_USER_NAME" LOGNAME="$PINNED_USER_NAME" \
            "$CONTROLLER" "$STOP_MODE"
        ;;
    *)
        fail 'local-trial launcher reached an impossible dispatch state'
        ;;
esac
