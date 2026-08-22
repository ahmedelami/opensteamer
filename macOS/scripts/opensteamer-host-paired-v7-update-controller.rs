//! One-shot pairing-preserving updater for the repo-owned virtual microphone driver and the
//! committed isolated `opensteamer Host.app`.
//!
//! The historical post-v20 controller remains an immutable included implementation source for
//! its reviewed low-level filesystem, launchd, signature, process, lock, and deployment proofs.
//! This controller owns a disjoint v7 journal/pointer namespace, never starts an interactive
//! host, never resets pairing, and rolls back to the exact committed pairing-preserving v6 host
//! plus the independently retained prior on-disk product-driver state. BlackHole is never an
//! install, quarantine, publication, or rollback target.

#[allow(dead_code)]
pub(crate) mod paired_v7 {
    include!(env!("OPENSTEAMER_PAIRED_V7_INCLUDED_SOURCE"));
    use std::os::darwin::fs::MetadataExt as _;
    use std::os::unix::process::CommandExt as _;

    unsafe extern "C" {
        fn geteuid() -> u32;
        fn fcntl(file_descriptor: i32, command: i32, ...) -> i32;
    }

    const F_GETFD: i32 = 1;
    const FD_CLOEXEC: i32 = 1;

    const V7_PREFLIGHT_MODE: &str = "--verify-paired-v7-host-update-preflight";
    const V7_EXECUTE_MODE: &str = "--execute-authorized-paired-v7-host-update";
    const V7_ROLLBACK_MODE: &str = "--rollback-authorized-paired-v7-host-update";
    const V7_SELF_TEST_MODE: &str = "--self-test-paired-v7-host-update";
    const V7_EXPECTED_REPO: &str = "/Users/ahmed/Documents/Codex/opensteamer";

    const V7_UPDATE_ROOT: &str =
        "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v7";
    const V7_ACTIVE_UPDATE: &str =
        "/Users/ahmed/Library/Application Support/opensteamer/active-paired-host-update-v7-retry-2";
    const FIRST_ATTEMPT_V7_ACTIVE_UPDATE: &str =
        "/Users/ahmed/Library/Application Support/opensteamer/active-paired-host-update-v7";
    const RETRY_1_V7_ACTIVE_UPDATE: &str =
        "/Users/ahmed/Library/Application Support/opensteamer/active-paired-host-update-v7-retry-1";
    const FIRST_ATTEMPT_V7_PENDING_PREFIX: &str = "active-paired-host-update-v7.pending-";
    const RETRY_1_V7_PENDING_PREFIX: &str = "active-paired-host-update-v7-retry-1.pending-";
    const RETRY_V7_PENDING_PREFIX: &str = "active-paired-host-update-v7-retry-2.pending-";
    const RETAINED_FAILED_V7_ATTEMPT_NAME: &str =
        "paired-v7-update-1787367704-92913-bba21548-458c-4d31-bd0a-eccdb282c02a";
    const RETAINED_FAILED_V7_ATTEMPT: &str =
        "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v7/paired-v7-update-1787367704-92913-bba21548-458c-4d31-bd0a-eccdb282c02a";
    const RETAINED_FAILED_V7_ATTEMPT_GID: u32 = 20;
    const RETAINED_FAILED_V7_ROOT_INODE: u64 = 27_737_655;
    const RETAINED_FAILED_V7_ATTEMPT_INODE: u64 = 27_737_656;
    const RETAINED_FAILED_V7_RESULT_INODE: u64 = 27_744_003;
    const RETAINED_FAILED_V7_RESULT_SHA256: &str =
        "a2c6cc1df53d424a97cf6aca55672b7eeb39a6d528aa63315c1e878ab429adc4";
    const RETAINED_FAILED_V7_RESULT: &str =
        "result=failed-before-stop\ndiagnostic=required file has unsafe type/owner/link-count/mode: /Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v7/paired-v7-update-1787367704-92913-bba21548-458c-4d31-bd0a-eccdb282c02a/probes/physical-virtual-microphone-probe\n";
    const RETAINED_FAILED_V7_JOURNAL_INODE: u64 = 27_737_659;
    const RETAINED_FAILED_V7_JOURNAL_SHA256: &str =
        "cdc94d9d88b6e12e41f485c217f9f88bbfc5621f226079501ee94b8512b80c3a";
    const RETAINED_FAILED_V7_JOURNAL: &str =
        "OPENSTEAMER_PAIRED_HOST_UPDATE_V7\nSTATE BEGUN\nSTATE SOURCE_EXPORTED commit=1ec63de7b4f6721cf7b04b7445f54f0e33f8b3a0 tree=c343c0bac2d77036e7f3a78dacc3cbf48e83b7ee initial_pid=873\n";
    const RETAINED_FAILED_V7_PROVENANCE_INODE: u64 = 27_738_087;
    const RETAINED_FAILED_V7_PROVENANCE_SHA256: &str =
        "b2205b990a7dc7773a8f65730179566a91999315e6769112b682070d3fbb7dc6";
    const RETAINED_FAILED_V7_PROVENANCE: &str =
        "commit=1ec63de7b4f6721cf7b04b7445f54f0e33f8b3a0\ntree=c343c0bac2d77036e7f3a78dacc3cbf48e83b7ee\nfunctional_source_commit=7beb049226ada83e97afba3e60089469d0eeeef6\nfunctional_source_tree=60e2df01afe1b4c09362b8e1b55efa709f23a748\nauthorized_release_commit=1ec63de7b4f6721cf7b04b7445f54f0e33f8b3a0\nauthorized_release_tree=c343c0bac2d77036e7f3a78dacc3cbf48e83b7ee\nupstream=origin/agent/auto-select-iphone-microphone\nremote=https://github.com/ahmedelami/opensteamer.git\nfunctional_inputs_sha256=fdef1da4413f66d5f066c86b0eba709b55c74b1f72b29dac8d62e991a2343ca6\nfunctional_input_evidence_sha256=73a01a709f6a78b768696ac4105128a6b22de5ae3a46512980b8d77ea6370967\nsource_archive_sha256=11d5a102b43e46856bd3b8a055e026bbc7a8c04365ad28cadb711eb4ac7de74d\n";
    const RETAINED_FAILED_V7_SOURCE_TAR_INODE: u64 = 27_737_662;
    const RETAINED_FAILED_V7_SOURCE_TAR_SIZE: u64 = 12_584_960;
    const RETAINED_FAILED_V7_SOURCE_TAR_SHA256: &str =
        "11d5a102b43e46856bd3b8a055e026bbc7a8c04365ad28cadb711eb4ac7de74d";
    const RETAINED_FAILED_V7_FUNCTIONAL_INPUTS_INODE: u64 = 27_738_086;
    const RETAINED_FAILED_V7_FUNCTIONAL_INPUTS_SIZE: u64 = 22_759;
    const RETAINED_FAILED_V7_FUNCTIONAL_INPUTS_SHA256: &str =
        "73a01a709f6a78b768696ac4105128a6b22de5ae3a46512980b8d77ea6370967";
    const RETAINED_FAILED_V7_INSTALL_HOLD_NAME_INODE: u64 = 27_737_660;
    const RETAINED_FAILED_V7_INSTALL_HOLD_NAME_SIZE: u64 = 82;
    const RETAINED_FAILED_V7_INSTALL_HOLD_NAME_SHA256: &str =
        "faab67bc8d4008d4d01734876654c7935e7aaf3af98610402c7927f80d699e28";
    const RETAINED_FAILED_V7_PROBES_INODE: u64 = 27_743_975;
    const RETAINED_FAILED_V7_PUBLIC_PROBE_INODE: u64 = 27_743_999;
    const RETAINED_FAILED_V7_PUBLIC_PROBE_SIZE: u64 = 154_912;
    const RETAINED_FAILED_V7_PUBLIC_PROBE_SHA256: &str =
        "0ec9e1a0cc5f253cc569134ce2be024a7f3ae6ad211fa7d20fe6436c0bac84c8";
    const RETAINED_FAILED_V7_GUARDIAN_INODE: u64 = 27_743_985;
    const RETAINED_FAILED_V7_GUARDIAN_SIZE: u64 = 286_968;
    const RETAINED_FAILED_V7_GUARDIAN_SHA256: &str =
        "a59c39bfc198546729a430e7cdbfd19d982e30697c7e67e3a4bd72ca49304e1e";
    const RETAINED_FAILED_V7_MIRROR_PROBE_INODE: u64 = 27_743_981;
    const RETAINED_FAILED_V7_MIRROR_PROBE_SIZE: u64 = 1_096_944;
    const RETAINED_FAILED_V7_MIRROR_PROBE_SHA256: &str =
        "13f6209ebb6a388f296c62ae4cfa5ce153b24e8a78d0ef45091b0aa30bc27b4b";
    const RETAINED_FAILED_V7_FAILED_NEW_INODE: u64 = 27_737_658;
    const RETAINED_FAILED_V7_ROLLBACK_CURRENT_INODE: u64 = 27_737_657;
    const RETAINED_FAILED_V7_INSTALL_HOLD: &str =
        "/Applications/.opensteamer-paired-v7-install-bba21548-458c-4d31-bd0a-eccdb282c02a";
    const RETAINED_FAILED_V7_RETRY_1_NAME: &str =
        "paired-v7-update-retry-1-1787373601-48365-716c0ed7-8cd5-4b9f-9d64-a3169a077a25";
    const RETAINED_FAILED_V7_RETRY_1: &str =
        "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v7/paired-v7-update-retry-1-1787373601-48365-716c0ed7-8cd5-4b9f-9d64-a3169a077a25";
    const RETAINED_FAILED_V7_RETRY_1_INODE: u64 = 27_758_526;
    const RETAINED_FAILED_V7_RETRY_1_RESULT_INODE: u64 = 27_765_144;
    const RETAINED_FAILED_V7_RETRY_1_RESULT_SHA256: &str =
        "606dd930e931ef96c1f028d4693473b39ad5c24fede939ed961d0e5c8b12aa70";
    const RETAINED_FAILED_V7_RETRY_1_RESULT: &str =
        "result=failed-before-stop\ndiagnostic=paired-v7 probe binary differs from its release pin: /Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v7/paired-v7-update-retry-1-1787373601-48365-716c0ed7-8cd5-4b9f-9d64-a3169a077a25/probes/opensteamer-v7-default-route-guardian\n";
    const RETAINED_FAILED_V7_RETRY_1_JOURNAL_INODE: u64 = 27_758_529;
    const RETAINED_FAILED_V7_RETRY_1_JOURNAL_SHA256: &str =
        "41a2e81d30d176f32dec89c1a770e0181695a3cb00428d09dcb449411d802827";
    const RETAINED_FAILED_V7_RETRY_1_JOURNAL: &str =
        "OPENSTEAMER_PAIRED_HOST_UPDATE_V7\nSTATE BEGUN\nSTATE SOURCE_EXPORTED commit=17c61bafcbef3e873bbd25789e3c516379bbac91 tree=7bf8155bc0b83c8de9feb718ceabb0e6735e7b2d initial_pid=873\n";
    const RETAINED_FAILED_V7_RETRY_1_PROVENANCE_INODE: u64 = 27_758_957;
    const RETAINED_FAILED_V7_RETRY_1_PROVENANCE_SHA256: &str =
        "dba0fc40a54e28fee8a7ec55220d94be596097c4167466510a2808d1fb3ba114";
    const RETAINED_FAILED_V7_RETRY_1_PROVENANCE: &str =
        "commit=17c61bafcbef3e873bbd25789e3c516379bbac91\ntree=7bf8155bc0b83c8de9feb718ceabb0e6735e7b2d\nfunctional_source_commit=7beb049226ada83e97afba3e60089469d0eeeef6\nfunctional_source_tree=60e2df01afe1b4c09362b8e1b55efa709f23a748\nauthorized_release_commit=17c61bafcbef3e873bbd25789e3c516379bbac91\nauthorized_release_tree=7bf8155bc0b83c8de9feb718ceabb0e6735e7b2d\nupstream=origin/agent/auto-select-iphone-microphone\nremote=https://github.com/ahmedelami/opensteamer.git\nfunctional_inputs_sha256=fdef1da4413f66d5f066c86b0eba709b55c74b1f72b29dac8d62e991a2343ca6\nfunctional_input_evidence_sha256=42819772d0ecfd838e23a0b8e9ea17d270604d03ab311566b1f4c337bf676e75\nsource_archive_sha256=bfee8bcd03c2815525a0e6a4217f6c3de7411fdced7753e3b7dcfccf9f2bcec1\n";
    const RETAINED_FAILED_V7_RETRY_1_SOURCE_TAR_INODE: u64 = 27_758_532;
    const RETAINED_FAILED_V7_RETRY_1_SOURCE_TAR_SIZE: u64 = 12_707_840;
    const RETAINED_FAILED_V7_RETRY_1_SOURCE_TAR_SHA256: &str =
        "bfee8bcd03c2815525a0e6a4217f6c3de7411fdced7753e3b7dcfccf9f2bcec1";
    const RETAINED_FAILED_V7_RETRY_1_FUNCTIONAL_INPUTS_INODE: u64 = 27_758_956;
    const RETAINED_FAILED_V7_RETRY_1_FUNCTIONAL_INPUTS_SIZE: u64 = 22_759;
    const RETAINED_FAILED_V7_RETRY_1_FUNCTIONAL_INPUTS_SHA256: &str =
        "42819772d0ecfd838e23a0b8e9ea17d270604d03ab311566b1f4c337bf676e75";
    const RETAINED_FAILED_V7_RETRY_1_INSTALL_HOLD_NAME_INODE: u64 = 27_758_530;
    const RETAINED_FAILED_V7_RETRY_1_INSTALL_HOLD_NAME_SIZE: u64 = 82;
    const RETAINED_FAILED_V7_RETRY_1_INSTALL_HOLD_NAME_SHA256: &str =
        "19c00bad374b30b1ea7d9e6ed23c3c2cd8c26e7e48a8aa059bb1eb7ffd15a3fb";
    const RETAINED_FAILED_V7_RETRY_1_PROBES_INODE: u64 = 27_764_883;
    const RETAINED_FAILED_V7_RETRY_1_PUBLIC_PROBE_INODE: u64 = 27_765_140;
    const RETAINED_FAILED_V7_RETRY_1_PUBLIC_PROBE_SIZE: u64 = 154_912;
    const RETAINED_FAILED_V7_RETRY_1_PUBLIC_PROBE_SHA256: &str =
        "0ec9e1a0cc5f253cc569134ce2be024a7f3ae6ad211fa7d20fe6436c0bac84c8";
    const RETAINED_FAILED_V7_RETRY_1_GUARDIAN_INODE: u64 = 27_765_125;
    const RETAINED_FAILED_V7_RETRY_1_GUARDIAN_SIZE: u64 = 286_968;
    const RETAINED_FAILED_V7_RETRY_1_GUARDIAN_SHA256: &str =
        "53ee0ce919f1b61c9d66a95d3ec8b417fba85df9f925fd24146d70b663fa995c";
    const RETAINED_FAILED_V7_RETRY_1_MIRROR_PROBE_INODE: u64 = 27_765_117;
    const RETAINED_FAILED_V7_RETRY_1_MIRROR_PROBE_SIZE: u64 = 1_096_944;
    const RETAINED_FAILED_V7_RETRY_1_MIRROR_PROBE_SHA256: &str =
        "13f6209ebb6a388f296c62ae4cfa5ce153b24e8a78d0ef45091b0aa30bc27b4b";
    const RETAINED_FAILED_V7_RETRY_1_FAILED_NEW_INODE: u64 = 27_758_528;
    const RETAINED_FAILED_V7_RETRY_1_ROLLBACK_CURRENT_INODE: u64 = 27_758_527;
    const RETAINED_FAILED_V7_RETRY_1_INSTALL_HOLD: &str =
        "/Applications/.opensteamer-paired-v7-install-716c0ed7-8cd5-4b9f-9d64-a3169a077a25";
    const V7_UPDATE_LOCK: &str = UPDATE_LOCK;
    const V7_JOURNAL_HEADER: &str = "OPENSTEAMER_PAIRED_HOST_UPDATE_V7";
    const HIDDEN_INSTALL_PREFIX: &str = ".opensteamer-paired-v7-install-";
    const ISOLATED_PAIRING_LOGIN_KEYCHAIN: &str =
        "/Users/ahmed/Library/Keychains/login.keychain-db";
    const ISOLATED_PAIRING_LOGIN_KEYCHAIN_GID: u32 = 20;
    const ISOLATED_PAIRING_LOGIN_KEYCHAIN_MODE: u32 = 0o644;
    const NEW_LAUNCH_AGENT_LABEL: &str = NEW_LABEL;
    const PROTECTED_LEGACY_LAUNCH_AGENT_LABEL: &str = LEGACY_LABEL;
    const REVIEWED_LAUNCH_AGENT_PATH: &str = NEW_PLIST;
    const REVIEWED_LAUNCH_AGENT_SHA256: &str = NEW_PLIST_SHA256;

    const RELEASE_PIN_STATUS: &str = "PINNED_FINAL_REVIEW";
    const RELEASE_PIN_READY: &str = "PINNED_FINAL_REVIEW";
    const RELEASE_PIN_PLACEHOLDER: &str = "PIN_AFTER_FINAL_REVIEW";
    const EXPECTED_DRIVER_TEAM_ID: &str = "MSMG8CJLB3";
    const EXPECTED_DRIVER_IDENTIFIER: &str = "com.elamin.opensteamer.VirtualMicrophoneDriver";
    const PRODUCT_DRIVER_NAME: &str = "OpensteamerVirtualMicrophone.driver";
    const PRODUCT_DRIVER_CANONICAL_PATH: &str =
        "/Library/Audio/Plug-Ins/HAL/OpensteamerVirtualMicrophone.driver";
    const RETIRED_BLACKHOLE_VISIBLE_UID: &str = "BlackHole2ch_UID";
    const RETIRED_BLACKHOLE_HIDDEN_UID: &str = "BlackHole2ch_2_UID";
    const PRODUCT_VISIBLE_UID: &str = "com.elamin.opensteamer.virtual-microphone.input";
    const PRODUCT_WRITER_UID: &str = "com.elamin.opensteamer.virtual-microphone.writer";
    const PRODUCT_MODEL_UID: &str = "com.elamin.opensteamer.virtual-microphone.model";
    const PRODUCT_CLOCK_DOMAIN: u32 = 0x6F73_564D;
    const NOTARY_KEYCHAIN_PROFILE: &str = "opensteamer-production-v7";
    const EXPECTED_DEVELOPER_ID_APPLICATION_SHA1: &str =
        "2BD65FABE76E3155726886963F8836E0048440E2";
    const EXPECTED_DEVELOPER_ID_INSTALLER_IDENTITY_SHA1: &str =
        "39FE8277467264AAAFDAAE6A74E68F99FE8B3461";
    const EXPECTED_DEVELOPER_ID_INSTALLER_LEAF_SHA256: &str =
        "4021696842E07336784376884D24969D9A94654A54F5B0C5C8FBC3C8C5D599AE";
    const REVIEWED_PRODUCTION_DRIVER_CANDIDATE_ROOT: &str =
        "/Users/ahmed/Library/Application Support/opensteamer/reviewed-driver-candidates-v7/production-driver-v7";
    const EXPECTED_PRODUCTION_DRIVER_CANDIDATE_MANIFEST_SHA256: &str =
        "88c842ec87374b6cbf1f5de32ae7788e15cf42f81fcb9213952ea8338a11f1a1";
    const EXPECTED_FUNCTIONAL_INPUTS_SHA256: &str =
        "fdef1da4413f66d5f066c86b0eba709b55c74b1f72b29dac8d62e991a2343ca6";
    const EXPECTED_PRODUCTION_DRIVER_TREE_SHA256: &str =
        "f32e870ed639fedd90ea63d3434727d72e5c030fccc4d3c6cf9bda1ae003ce49";
    const EXPECTED_PRODUCTION_DRIVER_EXECUTABLE_SHA256: &str =
        "ca6efc2627be0e83e591b66187820cbc7a34d8dfd7cbf2818788e1589d496866";
    const EXPECTED_PRODUCTION_DRIVER_PACKAGE_SHA256: &str =
        "e2b13dde169a7994a50b819e414212e884136b0ab0c40c482531b8f8dc2a3f45";
    const EXPECTED_MIRROR_PROBE_SOURCE_SHA256: &str =
        "3c6baf8474bd5f2ed807f74bd910a9e057bfcf384e54f6b66aadeb1634554383";
    const EXPECTED_MIRROR_PROBE_BINARY_SHA256: &str =
        "13f6209ebb6a388f296c62ae4cfa5ce153b24e8a78d0ef45091b0aa30bc27b4b";
    const EXPECTED_PUBLIC_VPIO_PROBE_BUILDER_SHA256: &str =
        "88a8a3d7cced350337e6624d010efc0c061d9f23ed1ce8e72f626494c14f1b2d";
    const EXPECTED_PUBLIC_VPIO_PROBE_SOURCE_SHA256: &str =
        "cbb5cf76c51119e9d232f2cee3c8d4d66c3fc85fa8611a09436587becec6ad2b";
    const EXPECTED_PUBLIC_VPIO_PROBE_CORE_SOURCE_SHA256: &str =
        "31bd71470968758c1809d5475dfc1a7b823b7b5db2cbe889b6660f84f1907aab";
    const EXPECTED_PUBLIC_VPIO_PROBE_HEADER_SHA256: &str =
        "4ec4cf52b5bb79eae45b6965e97912f23041a3d879b3814b67763caded0548dd";
    const EXPECTED_PUBLIC_VPIO_PROBE_BINARY_SHA256: &str =
        "0ec9e1a0cc5f253cc569134ce2be024a7f3ae6ad211fa7d20fe6436c0bac84c8";
    const EXPECTED_DEFAULT_ROUTE_GUARDIAN_SOURCE_SHA256: &str =
        "f152ef8d05eed29c5918666be31821e5ef6e325351d2fcf4ad5f8b83987e299c";
    const EXPECTED_DEFAULT_ROUTE_GUARDIAN_BINARY_SHA256: &str =
        "53ee0ce919f1b61c9d66a95d3ec8b417fba85df9f925fd24146d70b663fa995c";
    const EXPECTED_PRODUCTION_DRIVER_BUILDER_SHA256: &str =
        "91e1da8c84d47f05dd4dc19a84418a946238b1e411cf09d0dd3fb275babc88d5";
    const EXPECTED_PRODUCTION_DRIVER_VERIFIER_SHA256: &str =
        "290731edd02baf42ca40f43f11f74d75271617a46393184cb4d0d566a147257e";
    const EXPECTED_INSTALLER_SIGNATURE_PARSER_SHA256: &str =
        "25293a4c83b5c6a6e1c95a95388d596f56057e5c5a54add0756017cfc6b0deac";
    const ROOT_V7_SUPPORT_DIRECTORY: &str =
        "/Library/Application Support/opensteamer/privileged-v7";
    const ROOT_V7_CONTROLLER: &str =
        "/Library/Application Support/opensteamer/privileged-v7/opensteamer-v7-controller";
    const ROOT_V7_CONTROLLER_PIN: &str =
        "/Library/Application Support/opensteamer/privileged-v7/controller-binary.sha256";
    const ROOT_V7_CONTROLLER_IDENTITY_JOURNAL: &str =
        "/Library/Application Support/opensteamer/privileged-v7/controller-identity.log";
    const ROOT_V7_TRANSACTION_PARENT: &str =
        "/Library/Application Support/opensteamer/driver-transactions-v7";
    const ROOT_V7_CONTROLLER_BOOTSTRAP_MODE: &str = "--root-bootstrap-controller-identity-v7";
    const MAX_V7_CONTROLLER_BYTES: u64 = 64 * 1_024 * 1_024;
    const ROOT_BROKER_DEADMAN_SECONDS: u64 = 75;
    const PINNED_XCODE_APPLICATION_LINK: &str = "/Applications/Xcode-26.6.0.app";
    const PINNED_XCODE_APPLICATION_TARGET: &str =
        "/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app";
    const PINNED_XCODE_DEVELOPER_DIR: &str = "/Applications/Xcode-26.6.0.app/Contents/Developer";
    const PINNED_XCODE_RESOLVED_DEVELOPER_DIR: &str =
        "/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app/Contents/Developer";
    const PINNED_XCODE_DEVELOPER_UID: u32 = 501;
    const PINNED_XCODE_DEVELOPER_GID: u32 = 20;
    const PINNED_XCODE_DEVELOPER_MODE: u32 = 0o755;
    const PINNED_XCODE_SWIFTC_ALIAS: &str = "/Applications/Xcode-26.6.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc";
    const PINNED_XCODE_RESOLVED_SWIFTC_ALIAS: &str = "/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc";
    const PINNED_XCODE_SWIFTC_ALIAS_TARGET: &str = "swift-frontend";
    const PINNED_XCODE_SWIFT_FRONTEND: &str = "/Applications/Xcode-26.6.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend";
    const PINNED_XCODE_CLANG: &str = "/Applications/Xcode-26.6.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang";
    const EXPECTED_XCODE_SWIFT_FRONTEND_SHA256: &str =
        "2ed38571e92c0283091838c1649e27650ad9c99950288e883c7b2dc6c4ce89fb";
    const EXPECTED_XCODE_CLANG_SHA256: &str =
        "7def90dd8829726686213a747fc5bff1583df933dae5edc55d755479e0bfe00a";
    const EXPECTED_XCODE_SWIFTC_VERSION: &str = "swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)\nTarget: arm64-apple-macosx26.0";
    const PINNED_DATA_VOLUME_MOUNT: &str = "/System/Volumes/Data";
    const EXPECTED_DATA_VOLUME_UUID: &str = "AF638805-E0CB-4356-941F-16B84DFB6435";
    const EXPECTED_DATA_VOLUME_GROUP_UUID: &str = "AF638805-E0CB-4356-941F-16B84DFB6435";
    const PINNED_DATA_VOLUME_DISKUTIL: &str = "/usr/sbin/diskutil";
    const EXPECTED_DATA_VOLUME_DISKUTIL_SHA256: &str =
        "9299ccac6acdf493796a88979d14ff464c1ec2196b167c879f023c2dbe9f3049";

    const COMMITTED_V1_POINTER: &str =
        "/Users/ahmed/Library/Application Support/opensteamer/active-post-v20-host-update-v1";
    const COMMITTED_V1_EVIDENCE: &str = "/Users/ahmed/Library/Application Support/opensteamer/host-updates/post-v20-update-1785755610-30384-e2654f34-367f-4767-93f8-76d27a7e2c10";
    const COMMITTED_V1_POINTER_SHA256: &str =
        "f6e76a7d67e424fe319f12ef505d94b6826cc5c36f0415644832c853e9788cdf";
    const COMMITTED_V1_JOURNAL_SHA256: &str =
        "1c6051a9538901c0002b126b373c9476b93aa48c220127358e7e08e2b58d5ff5";
    const COMMITTED_V1_RESULT_SHA256: &str =
        "22127aa5523e3efa468822044100fb2fd1cc5ceb97552377c986b1f5c1a15d77";
    const COMMITTED_V1_PROVENANCE_SHA256: &str =
        "ff747bc792b4781b709f3650941a28eaba4235b1fdb87a76ed079ad930eb95d1";
    const COMMITTED_V1_SOURCE_ARCHIVE_SHA256: &str =
        "7f0fc3bc8efb16958c8c424e159188e2b9fc2b1ee8747f25a0a2261ee7091b9f";
    const COMMITTED_V1_INSTALL_HOLD_NAME_SHA256: &str =
        "ee67e4a38815acebb71b3a35fd3f83e0faa9c8eec0237b96be3ae91bc77afa43";

    const COMMITTED_V1_BASELINE_APP: &str = "/Users/ahmed/Library/Application Support/opensteamer/host-updates/post-v20-update-1785755610-30384-e2654f34-367f-4767-93f8-76d27a7e2c10/deployment-reference/opensteamer Host.app";
    const COMMITTED_V1_BASELINE_SOURCE_EXPORT: &str = "/Users/ahmed/Library/Application Support/opensteamer/host-updates/post-v20-update-1785755610-30384-e2654f34-367f-4767-93f8-76d27a7e2c10/source-export";
    const COMMITTED_V1_BASELINE_EXECUTABLE_SHA256: &str =
        "ae7638a512440bb567d5e07f1067d8e5035bb59951e38c0559a74e4afa1d2e52";
    const COMMITTED_V1_BASELINE_CDHASH: &str = "468cbff663853fc36f184946194cda0f4e146be9";
    const COMMITTED_V1_VERIFY_BUNDLE_SHA256: &str =
        "02a348a88d25b76ab95d45620d823339212bb53ee0f39bfb3a52f04240d3d745";
    const COMMITTED_V1_VERIFY_LIVE_PROCESS_SHA256: &str =
        "0e56403570362c6d59ea86dc10d3cc53d7a5461d4a2f6c78d6e6c86dd13a4b41";
    const COMMITTED_V1_VERIFY_DEPLOYMENT_SHA256: &str =
        "6c4a1598d2b78550202b5d23903f0dd64e117384cd962a2c18c73e74795fe4de";
    const COMMITTED_V1_VERIFY_LAUNCH_STATE_SHA256: &str =
        "27c36f8adec05c22216955cb404d6732ceaa6065477e5bb1570f2d41e84db7a9";
    const COMMITTED_V1_LAUNCH_AGENT_SOURCE_SHA256: &str =
        "7cdcf2d1517dc9ec1ae49b6fbbaf293c77afd958f697878d44f3b3c8e9c7e550";

    const COMMITTED_V2_POINTER: &str =
        "/Users/ahmed/Library/Application Support/opensteamer/active-paired-host-update-v2";
    const COMMITTED_V2_UPDATE_ROOT: &str =
        "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v2";
    const COMMITTED_V2_EVIDENCE: &str = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v2/paired-v2-update-1785977369-24182-475e6219-114a-4bd9-b9df-c934579faf75";
    const COMMITTED_V2_POINTER_SHA256: &str =
        "e83a072333d5976e64bc4905b0d03cb685de4837fe0cb523d9524e88318099dc";
    const COMMITTED_V2_JOURNAL_SHA256: &str =
        "9859ef5c7ca5f65a386d5dca580c2d5b2cd40f44cf759cf15b8a8ffd8d3a57b4";
    const COMMITTED_V2_RESULT_SHA256: &str =
        "22127aa5523e3efa468822044100fb2fd1cc5ceb97552377c986b1f5c1a15d77";
    const COMMITTED_V2_PROVENANCE_SHA256: &str =
        "539c8de1abdf41285b567ab5d3da53df4bf999a026cced58c69567a4406a4fad";
    const COMMITTED_V2_SOURCE_ARCHIVE_SHA256: &str =
        "b5a60d25f146a78217a7d354cdf195a5a51c385fe375b5254fd143da81448cfe";
    const COMMITTED_V2_INSTALL_HOLD_NAME_SHA256: &str =
        "f42627f1938a7b0dfeb0f9861dda66818c43774f4bdf580e262e18002f86e4bb";
    const COMMITTED_V2_BUILD_STDOUT_SHA256: &str =
        "f03c04ea0e9e66555e109fa52ee37a9da7b5a92ecf32dc15130169f51b372dab";
    const COMMITTED_V2_BUILD_STDERR_SHA256: &str =
        "9b45d25034827dd2694eac47362fc4ec0a1148880e0cc263c86ba11d5e03e5e5";
    const COMMITTED_V2_CONTROLLER_SOURCE_SHA256: &str =
        "5e26447094f85269850f218d0084337116c91e3eddf2cda1e22ec934f55f9104";
    const COMMITTED_V2_LAUNCHER_SOURCE_SHA256: &str =
        "a733fcf94c5d07fb1465656123c8a185646b199524fe44a26d4aa49f3a7a61a1";
    const COMMITTED_V2_INCLUDED_V1_SOURCE_SHA256: &str =
        "2dfe9ddec5ea71b206f6462deec0b8be5423e9f23ab30aebc42b8f424dfdab06";

    const COMMITTED_V2_BASELINE_APP: &str = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v2/paired-v2-update-1785977369-24182-475e6219-114a-4bd9-b9df-c934579faf75/deployment-reference/opensteamer Host.app";
    const COMMITTED_V2_BASELINE_SOURCE_EXPORT: &str = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v2/paired-v2-update-1785977369-24182-475e6219-114a-4bd9-b9df-c934579faf75/source-export";
    const COMMITTED_V2_BASELINE_EXECUTABLE_SHA256: &str =
        "7cc60fc9a1677ff10e17f4a6e09647e502a92b5492db46170567bed98c09f3bc";
    const COMMITTED_V2_BASELINE_CDHASH: &str = "e503fb26b65b3550404cf5eaff3307fe68ba1e38";
    const COMMITTED_V2_VERIFY_BUNDLE_SHA256: &str =
        "02a348a88d25b76ab95d45620d823339212bb53ee0f39bfb3a52f04240d3d745";
    const COMMITTED_V2_VERIFY_LIVE_PROCESS_SHA256: &str =
        "0e56403570362c6d59ea86dc10d3cc53d7a5461d4a2f6c78d6e6c86dd13a4b41";
    const COMMITTED_V2_VERIFY_DEPLOYMENT_SHA256: &str =
        "6c4a1598d2b78550202b5d23903f0dd64e117384cd962a2c18c73e74795fe4de";
    const COMMITTED_V2_VERIFY_LAUNCH_STATE_SHA256: &str =
        "27c36f8adec05c22216955cb404d6732ceaa6065477e5bb1570f2d41e84db7a9";
    const COMMITTED_V2_LAUNCH_AGENT_SOURCE_SHA256: &str =
        "7cdcf2d1517dc9ec1ae49b6fbbaf293c77afd958f697878d44f3b3c8e9c7e550";

    const COMMITTED_V3_POINTER: &str =
        "/Users/ahmed/Library/Application Support/opensteamer/active-paired-host-update-v3";
    const COMMITTED_V3_UPDATE_ROOT: &str =
        "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v3";
    const COMMITTED_V3_EVIDENCE: &str = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v3/paired-v3-update-1786018665-19633-6cf5e703-22ae-4268-b3d8-75f35c37589b";
    const COMMITTED_V3_POINTER_SHA256: &str =
        "598039b1200c04e828650b780b4745a94a1d3b77cba9dca8525a846f026c9d38";
    const COMMITTED_V3_JOURNAL_SHA256: &str =
        "c836304aba4515a5e81c542a40586cde91d4474a35073206ab2315650c8e7629";
    const COMMITTED_V3_RESULT_SHA256: &str =
        "22127aa5523e3efa468822044100fb2fd1cc5ceb97552377c986b1f5c1a15d77";
    const COMMITTED_V3_PROVENANCE_SHA256: &str =
        "9ad6a3bd4cc9c286fe628e8c189191652c2d5136111411cbc30055c231e49cbd";
    const COMMITTED_V3_SOURCE_ARCHIVE_SHA256: &str =
        "f25157d09eb91e1124b403d03f48546c0347cb70bea18f1dd17d6ae84fb17c5f";
    const COMMITTED_V3_INSTALL_HOLD_NAME_SHA256: &str =
        "ad2b9f1156a23982b8e9526631bd730e3d2064b30770b9f969ca0049f4511f43";
    const COMMITTED_V3_BUILD_STDOUT_SHA256: &str =
        "46ab32af32490416df5d9aba72e4bb060a208994f23f894b8e9d37778fed3605";
    const COMMITTED_V3_BUILD_STDERR_SHA256: &str =
        "ff5ab234191bb5b4b2d56e976af25086059f5b351134b9edc10d6e4a7c51db9e";
    const COMMITTED_V3_CONTROLLER_SOURCE_SHA256: &str =
        "3eeed3c8c1fd495df22bc516b0b38c0fe6178c9dd1ff3dee596633336683e769";
    const COMMITTED_V3_LAUNCHER_SOURCE_SHA256: &str =
        "07f9d126aef51d38effc13da81e54803cc30ffa8a7db9b60c6852568cba4d07d";
    const COMMITTED_V3_INCLUDED_V1_SOURCE_SHA256: &str =
        "2dfe9ddec5ea71b206f6462deec0b8be5423e9f23ab30aebc42b8f424dfdab06";

    const COMMITTED_V3_BASELINE_APP: &str = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v3/paired-v3-update-1786018665-19633-6cf5e703-22ae-4268-b3d8-75f35c37589b/deployment-reference/opensteamer Host.app";
    const COMMITTED_V3_BASELINE_SOURCE_EXPORT: &str = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v3/paired-v3-update-1786018665-19633-6cf5e703-22ae-4268-b3d8-75f35c37589b/source-export";
    const COMMITTED_V3_BASELINE_EXECUTABLE_SHA256: &str =
        "3ae931ddc06cb9bf303201143c8e1868fad45c0d0db2cb76e6eb9eca55d16181";
    const COMMITTED_V3_BASELINE_CDHASH: &str = "60311a91a4be4fb80c4c0414f134c2289c05240b";
    const COMMITTED_V3_VERIFY_BUNDLE_SHA256: &str =
        "02a348a88d25b76ab95d45620d823339212bb53ee0f39bfb3a52f04240d3d745";
    const COMMITTED_V3_VERIFY_LIVE_PROCESS_SHA256: &str =
        "0e56403570362c6d59ea86dc10d3cc53d7a5461d4a2f6c78d6e6c86dd13a4b41";
    const COMMITTED_V3_VERIFY_DEPLOYMENT_SHA256: &str =
        "6c4a1598d2b78550202b5d23903f0dd64e117384cd962a2c18c73e74795fe4de";
    const COMMITTED_V3_VERIFY_LAUNCH_STATE_SHA256: &str =
        "27c36f8adec05c22216955cb404d6732ceaa6065477e5bb1570f2d41e84db7a9";
    const COMMITTED_V3_LAUNCH_AGENT_SOURCE_SHA256: &str =
        "7cdcf2d1517dc9ec1ae49b6fbbaf293c77afd958f697878d44f3b3c8e9c7e550";

    const COMMITTED_V4_POINTER: &str =
        "/Users/ahmed/Library/Application Support/opensteamer/active-paired-host-update-v4";
    const COMMITTED_V4_UPDATE_ROOT: &str =
        "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v4";
    const COMMITTED_V4_EVIDENCE: &str = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v4/paired-v4-update-1786291257-27621-6a237b6f-a9cc-4adb-a48a-129d364f8073";
    const COMMITTED_V4_POINTER_SHA256: &str =
        "6c54a9561602a3b7c1a3308792dbc3146644311cab318c89c136e77b0ee27e1b";
    const COMMITTED_V4_JOURNAL_SHA256: &str =
        "4be780a2ee74d0de1ed8ab82eb520fd0216ec6056ff19120f462b26a15950da1";
    const COMMITTED_V4_RESULT_SHA256: &str =
        "22127aa5523e3efa468822044100fb2fd1cc5ceb97552377c986b1f5c1a15d77";
    const COMMITTED_V4_PROVENANCE_SHA256: &str =
        "ff6af9dafbbfc7a579fe8f451d1d095e06d1b7942fbe5ddc2d2efd68517f79bf";
    const COMMITTED_V4_SOURCE_ARCHIVE_SHA256: &str =
        "55cc9f4672a3bc7588f1e05ba2899e905853c5e82cde3e4dcd9cc0bd4fd30a27";
    const COMMITTED_V4_INSTALL_HOLD_NAME_SHA256: &str =
        "cb630b1f36e17343747b9eb7b18e4f0235c45a76e9873d4fc4618bf7851cc407";
    const COMMITTED_V4_BUILD_STDOUT_SHA256: &str =
        "272a0ad16858c224aa26d6a265258c6dd66cb5292a2b742fd645c07f007ed3f1";
    const COMMITTED_V4_BUILD_STDERR_SHA256: &str =
        "771296873efbcb817e1adf937f4b3f2eccd3f871f3fca5e5a0ebac4dee797cc0";
    const COMMITTED_V4_CONTROLLER_SOURCE_SHA256: &str =
        "e688f39358399f80629fde49198b5610f7ea5628ec0abf081fb76ec088f67034";
    const COMMITTED_V4_LAUNCHER_SOURCE_SHA256: &str =
        "abd9fc4dcb81b7b18eec4a0d20a2b10a9d48d088dd97ad1649ccb407a872245d";
    const COMMITTED_V4_INCLUDED_V1_SOURCE_SHA256: &str =
        "2dfe9ddec5ea71b206f6462deec0b8be5423e9f23ab30aebc42b8f424dfdab06";
    const COMMITTED_V4_SOURCE_COMMIT: &str = "e0fd02808ed8863819902dce854d974db8895d3c";
    const COMMITTED_V4_SOURCE_TREE: &str = "0c0934443a73d7808d3ede612638804148411ea6";
    const COMMITTED_V4_BASELINE_APP: &str = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v4/paired-v4-update-1786291257-27621-6a237b6f-a9cc-4adb-a48a-129d364f8073/deployment-reference/opensteamer Host.app";
    const COMMITTED_V4_BASELINE_SOURCE_EXPORT: &str = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v4/paired-v4-update-1786291257-27621-6a237b6f-a9cc-4adb-a48a-129d364f8073/source-export";
    const COMMITTED_V4_BASELINE_EXECUTABLE_SHA256: &str =
        "ce0c1347aa6ddf7ecd290729d8351c65dc1bc43d99416f6a4c17141db7371a4b";
    const COMMITTED_V4_BASELINE_CDHASH: &str = "47ff9ae616f6b0b14880e7e419b00ec6a88193d7";
    const COMMITTED_V4_VERIFY_BUNDLE_SHA256: &str =
        "02a348a88d25b76ab95d45620d823339212bb53ee0f39bfb3a52f04240d3d745";
    const COMMITTED_V4_VERIFY_LIVE_PROCESS_SHA256: &str =
        "0e56403570362c6d59ea86dc10d3cc53d7a5461d4a2f6c78d6e6c86dd13a4b41";
    const COMMITTED_V4_VERIFY_DEPLOYMENT_SHA256: &str =
        "6c4a1598d2b78550202b5d23903f0dd64e117384cd962a2c18c73e74795fe4de";
    const COMMITTED_V4_VERIFY_LAUNCH_STATE_SHA256: &str =
        "27c36f8adec05c22216955cb404d6732ceaa6065477e5bb1570f2d41e84db7a9";
    const COMMITTED_V4_LAUNCH_AGENT_SOURCE_SHA256: &str =
        "7cdcf2d1517dc9ec1ae49b6fbbaf293c77afd958f697878d44f3b3c8e9c7e550";

    const COMMITTED_V5_POINTER: &str =
        "/Users/ahmed/Library/Application Support/opensteamer/active-paired-host-update-v5";
    const COMMITTED_V5_UPDATE_ROOT: &str =
        "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v5";
    const COMMITTED_V5_EVIDENCE: &str = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v5/paired-v5-update-1786316959-19979-3f7de8a9-473f-4abf-b15d-9790c827765e";
    const COMMITTED_V5_POINTER_SHA256: &str =
        "291c5a5f6a1fcf71cd32e5c15f95da212a73d59d8d030c46ece930cde5e4c7a8";
    const COMMITTED_V5_JOURNAL_SHA256: &str =
        "aa356a3696c632e1690fce95ace8ed6d55f1ae80567d47b2737e03468b186ff7";
    const COMMITTED_V5_RESULT_SHA256: &str =
        "22127aa5523e3efa468822044100fb2fd1cc5ceb97552377c986b1f5c1a15d77";
    const COMMITTED_V5_PROVENANCE_SHA256: &str =
        "60dfee1584d102ae668f417878352a8658ab55bc26a090b7aff03d49d4df0600";
    const COMMITTED_V5_SOURCE_ARCHIVE_SHA256: &str =
        "9a5fe00fdb786225b6dd505586c0fbc5643d1acaca802b8ee93c3d3052660fbe";
    const COMMITTED_V5_INSTALL_HOLD_NAME_SHA256: &str =
        "4232410939ddd5182ee305f34eb547bdf6ddb0f4353e8c6857b0e3eda2e3e9f4";
    const COMMITTED_V5_BUILD_STDOUT_SHA256: &str =
        "910cf1081d9a5ca9adfa9169a9f22746e3c2ccf09e9c315490487316c2ac11c0";
    const COMMITTED_V5_BUILD_STDERR_SHA256: &str =
        "3c182eb1dac054dbf2a8ed05252c5cbd7d890777022929d46a995389ee072468";
    const COMMITTED_V5_CONTROLLER_SOURCE_SHA256: &str =
        "bf377d7881b0707a1fd93a2a28c02a16a17c0380c879d91b93d1a05e2dc21e49";
    const COMMITTED_V5_LAUNCHER_SOURCE_SHA256: &str =
        "97863cbcacd650118ef92df9dd60b0ff3510a4b21e425d7e25abc0aa716f4822";
    const COMMITTED_V5_CONTROLLER_BINARY_SHA256: &str =
        "09cbef7a14dd3e2454878193dabc732b7c0b0be2295ab26a0166ada9ce769aa9";
    const COMMITTED_V5_INCLUDED_V1_SOURCE_SHA256: &str =
        "2dfe9ddec5ea71b206f6462deec0b8be5423e9f23ab30aebc42b8f424dfdab06";
    const COMMITTED_V5_SOURCE_COMMIT: &str = "aad4633320734727e05afd1624b06c93bf96ae6f";
    const COMMITTED_V5_SOURCE_TREE: &str = "ebf42a023e9790b9eb58becd8a473a7b124b1e07";
    const COMMITTED_V5_INSTALL_HOLD_ROOT: &str =
        "/Applications/.opensteamer-paired-v5-install-3f7de8a9-473f-4abf-b15d-9790c827765e";
    const COMMITTED_V5_RESERVE_INODE: u64 = 25_430_692;
    const COMMITTED_V5_BASELINE_APP: &str = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v5/paired-v5-update-1786316959-19979-3f7de8a9-473f-4abf-b15d-9790c827765e/deployment-reference/opensteamer Host.app";
    const COMMITTED_V5_BASELINE_SOURCE_EXPORT: &str = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v5/paired-v5-update-1786316959-19979-3f7de8a9-473f-4abf-b15d-9790c827765e/source-export";
    const COMMITTED_V5_BASELINE_EXECUTABLE_SHA256: &str =
        "2cb98599725f1a8c658b9a8afc38b50fabe252168292e27505af88cbecf2d205";
    const COMMITTED_V5_BASELINE_CDHASH: &str = "92ad981f78d75d63d7a857c677bc73fdfc004da6";
    const COMMITTED_V5_VERIFY_BUNDLE_SHA256: &str =
        "02a348a88d25b76ab95d45620d823339212bb53ee0f39bfb3a52f04240d3d745";
    const COMMITTED_V5_VERIFY_LIVE_PROCESS_SHA256: &str =
        "0e56403570362c6d59ea86dc10d3cc53d7a5461d4a2f6c78d6e6c86dd13a4b41";
    const COMMITTED_V5_VERIFY_DEPLOYMENT_SHA256: &str =
        "6c4a1598d2b78550202b5d23903f0dd64e117384cd962a2c18c73e74795fe4de";
    const COMMITTED_V5_VERIFY_LAUNCH_STATE_SHA256: &str =
        "27c36f8adec05c22216955cb404d6732ceaa6065477e5bb1570f2d41e84db7a9";
    const COMMITTED_V5_LAUNCH_AGENT_SOURCE_SHA256: &str =
        "7cdcf2d1517dc9ec1ae49b6fbbaf293c77afd958f697878d44f3b3c8e9c7e550";

    const COMMITTED_V6_POINTER: &str =
        "/Users/ahmed/Library/Application Support/opensteamer/active-paired-host-update-v6";
    const COMMITTED_V6_UPDATE_ROOT: &str =
        "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v6";
    const COMMITTED_V6_EVIDENCE: &str = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v6/paired-v6-update-1786412787-39578-728d9781-2b79-4d10-a220-8a48c1f6f716";
    const COMMITTED_V6_POINTER_SHA256: &str =
        "0efc073d72f216f5e9e32d149a65b56058b3443e512d55103b5301c69a1fb9e0";
    const COMMITTED_V6_JOURNAL_SHA256: &str =
        "0786549ef4d6e83928784e52cd44689c757a9ff92a7a659a437b112f9cc84802";
    const COMMITTED_V6_RESULT_SHA256: &str =
        "22127aa5523e3efa468822044100fb2fd1cc5ceb97552377c986b1f5c1a15d77";
    const COMMITTED_V6_PROVENANCE_SHA256: &str =
        "7430adc7efc43649de191af0b43ea2e246481bee70b89b5a40ac760940b18518";
    const COMMITTED_V6_SOURCE_ARCHIVE_SHA256: &str =
        "f54819c36e28a1bd1f5833ee819920065f006697f27ead76e15809653d38bcf2";
    const COMMITTED_V6_INSTALL_HOLD_NAME_SHA256: &str =
        "d39ee0bf39d6d409135e548e9b2b6eadd05e21539998e177649df947918b7d99";
    const COMMITTED_V6_BUILD_STDOUT_SHA256: &str =
        "6be403da0c16fc9cc8e401620fbfbd25ec8aa0cfba3db0115b40534df18cd34f";
    const COMMITTED_V6_BUILD_STDERR_SHA256: &str =
        "24f478dcec7ff8679238177c5d219cf90b1684c8edf8e9c155bd7c114edf3802";
    const COMMITTED_V6_CONTROLLER_SOURCE_SHA256: &str =
        "3ee23b156017ce72e800882fb75c91f32a813586c4d20c4ee71ef047e38026f5";
    const COMMITTED_V6_LAUNCHER_SOURCE_SHA256: &str =
        "b84ea32d87c419ed1c4a9dafda7e84133bb35416ede63e4244187067542d6b04";
    const COMMITTED_V6_CONTROLLER_BINARY_SHA256: &str =
        "b01f9285d6f241fa8759ba13d7db73c5a470b8f9d6a42e25fa3863f6a60cd282";
    const COMMITTED_V6_INCLUDED_V1_SOURCE_SHA256: &str =
        "2dfe9ddec5ea71b206f6462deec0b8be5423e9f23ab30aebc42b8f424dfdab06";
    const COMMITTED_V6_SOURCE_COMMIT: &str = "e8771daf2fb666c4515f8fa613fbe9f7997f0f88";
    const COMMITTED_V6_SOURCE_TREE: &str = "205c379540e9e033ede4fdea86ed4954a82747ee";
    const COMMITTED_V6_INSTALL_HOLD_ROOT: &str =
        "/Applications/.opensteamer-paired-v6-install-728d9781-2b79-4d10-a220-8a48c1f6f716";
    const COMMITTED_V6_RESERVE_INODE: u64 = 25_795_487;

    const CURRENT_BASELINE_APP: &str = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v6/paired-v6-update-1786412787-39578-728d9781-2b79-4d10-a220-8a48c1f6f716/deployment-reference/opensteamer Host.app";
    const CURRENT_BASELINE_SOURCE_EXPORT: &str = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v6/paired-v6-update-1786412787-39578-728d9781-2b79-4d10-a220-8a48c1f6f716/source-export";
    const CURRENT_BASELINE_EXECUTABLE_SHA256: &str =
        "63d55477ca440dd3feb27f68959b479a2292e6accc635d159674c6b420b60de6";
    const CURRENT_BASELINE_CDHASH: &str = "1d7b50e8bf2cc907244f950049b167a8f252473e";
    const CURRENT_BASELINE_VERIFY_BUNDLE_SHA256: &str =
        "02a348a88d25b76ab95d45620d823339212bb53ee0f39bfb3a52f04240d3d745";
    const CURRENT_BASELINE_VERIFY_LIVE_PROCESS_SHA256: &str =
        "0e56403570362c6d59ea86dc10d3cc53d7a5461d4a2f6c78d6e6c86dd13a4b41";
    const CURRENT_BASELINE_VERIFY_DEPLOYMENT_SHA256: &str =
        "6c4a1598d2b78550202b5d23903f0dd64e117384cd962a2c18c73e74795fe4de";
    const CURRENT_BASELINE_VERIFY_LAUNCH_STATE_SHA256: &str =
        "27c36f8adec05c22216955cb404d6732ceaa6065477e5bb1570f2d41e84db7a9";
    const CURRENT_BASELINE_LAUNCH_AGENT_SOURCE_SHA256: &str =
        "7cdcf2d1517dc9ec1ae49b6fbbaf293c77afd958f697878d44f3b3c8e9c7e550";

    const ISOLATED_PAIRING_IDENTITY_ACCOUNT: &str = "worldwide-host-identity-v1";
    const ISOLATED_PAIRING_VIEWER_ACCOUNT: &str = "worldwide-paired-viewer-v1";
    const PAIRED_AVAILABILITY_MARKER_PREFIX: &str =
        "[info] Worldwide paired-device availability is online";
    const REQUIRED_REPO_OWNED_DRIVER_PATCH_COMMIT: &str =
        "7beb049226ada83e97afba3e60089469d0eeeef6";
    const EXPECTED_SOURCE_BRANCH: &str = "agent/auto-select-iphone-microphone";
    const EXPECTED_REMOTE: &str = "https://github.com/ahmedelami/opensteamer.git";
    const REQUIRED_RELEASE_DIFF_PATHS: [&str; 2] = [
        "macOS/scripts/opensteamer-host-paired-v7-update-controller.rs",
        "macOS/scripts/update-opensteamer-host-paired-v7.sh",
    ];
    const RELEASE_ONLY_PATH_ALLOWLIST: [&str; 9] = [
        "AGENTS.md",
        "README.md",
        "TESTING_ORACLES.md",
        "USER_PROTECTED_LEGACY_RUNTIME.md",
        "WORLDWIDE_REMOTE_ACCESS.md",
        "macOS/Tests/CaptureServerTests/V7DriverHostUpdateContractTests.swift",
        "macOS/VirtualAudioDriver/README.md",
        "macOS/scripts/opensteamer-host-paired-v7-update-controller.rs",
        "macOS/scripts/update-opensteamer-host-paired-v7.sh",
    ];

    #[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
    enum V7State {
        Begun,
        SourceExported,
        BuildVerified,
        InstallHoldVerified,
        DriverPrepared,
        StopInitiated,
        CurrentStopped,
        CurrentHeld,
        DriverPublished,
        ProbesVerified,
        NewPublished,
        PersistentBootstrapped,
        ReadyVerified,
        Committed,
        RollbackStarted,
        DriverRestored,
        FailedNewArchived,
        CurrentRestored,
        CurrentBootstrapped,
        RolledBack,
        CriticalFailure,
    }

    impl V7State {
        fn token(self) -> &'static str {
            match self {
                Self::Begun => "BEGUN",
                Self::SourceExported => "SOURCE_EXPORTED",
                Self::BuildVerified => "BUILD_VERIFIED",
                Self::InstallHoldVerified => "INSTALL_HOLD_VERIFIED",
                Self::DriverPrepared => "DRIVER_PREPARED",
                Self::StopInitiated => "STOP_INITIATED",
                Self::CurrentStopped => "CURRENT_STOPPED",
                Self::CurrentHeld => "CURRENT_HELD",
                Self::DriverPublished => "DRIVER_PUBLISHED",
                Self::ProbesVerified => "PROBES_VERIFIED",
                Self::NewPublished => "NEW_PUBLISHED",
                Self::PersistentBootstrapped => "PERSISTENT_BOOTSTRAPPED",
                Self::ReadyVerified => "READY_VERIFIED",
                Self::Committed => "COMMITTED",
                Self::RollbackStarted => "ROLLBACK_STARTED",
                Self::DriverRestored => "DRIVER_RESTORED",
                Self::FailedNewArchived => "FAILED_NEW_ARCHIVED",
                Self::CurrentRestored => "CURRENT_RESTORED",
                Self::CurrentBootstrapped => "CURRENT_BOOTSTRAPPED",
                Self::RolledBack => "ROLLED_BACK",
                Self::CriticalFailure => "CRITICAL_FAILURE",
            }
        }

        fn parse(value: &str) -> Option<Self> {
            Some(match value {
                "BEGUN" => Self::Begun,
                "SOURCE_EXPORTED" => Self::SourceExported,
                "BUILD_VERIFIED" => Self::BuildVerified,
                "INSTALL_HOLD_VERIFIED" => Self::InstallHoldVerified,
                "DRIVER_PREPARED" => Self::DriverPrepared,
                "STOP_INITIATED" => Self::StopInitiated,
                "CURRENT_STOPPED" => Self::CurrentStopped,
                "CURRENT_HELD" => Self::CurrentHeld,
                "DRIVER_PUBLISHED" => Self::DriverPublished,
                "PROBES_VERIFIED" => Self::ProbesVerified,
                "NEW_PUBLISHED" => Self::NewPublished,
                "PERSISTENT_BOOTSTRAPPED" => Self::PersistentBootstrapped,
                "READY_VERIFIED" => Self::ReadyVerified,
                "COMMITTED" => Self::Committed,
                "ROLLBACK_STARTED" => Self::RollbackStarted,
                "DRIVER_RESTORED" => Self::DriverRestored,
                "FAILED_NEW_ARCHIVED" => Self::FailedNewArchived,
                "CURRENT_RESTORED" => Self::CurrentRestored,
                "CURRENT_BOOTSTRAPPED" => Self::CurrentBootstrapped,
                "ROLLED_BACK" => Self::RolledBack,
                "CRITICAL_FAILURE" => Self::CriticalFailure,
                _ => return None,
            })
        }
    }

    fn v7_crossed_stop_without_durable_commit(state: V7State) -> bool {
        matches!(
            state,
            V7State::StopInitiated
                | V7State::CurrentStopped
                | V7State::CurrentHeld
                | V7State::DriverPublished
                | V7State::ProbesVerified
                | V7State::NewPublished
                | V7State::PersistentBootstrapped
                | V7State::ReadyVerified
                | V7State::RollbackStarted
                | V7State::DriverRestored
                | V7State::FailedNewArchived
                | V7State::CurrentRestored
                | V7State::CurrentBootstrapped
                | V7State::CriticalFailure
        )
    }

    struct V7Journal {
        path: PathBuf,
        file: File,
        state: V7State,
        healthy: bool,
    }

    impl V7Journal {
        fn create(path: &Path) -> Result<Self> {
            let mut file = OpenOptions::new()
                .create_new(true)
                .read(true)
                .write(true)
                .mode(0o600)
                .custom_flags(O_NOFOLLOW | 0x0100_0000)
                .open(path)
                .map_err(|error| ControllerError(format!("cannot create v7 journal: {error}")))?;
            validate_open_journal_file(path, &file)?;
            writeln!(file, "{V7_JOURNAL_HEADER}")?;
            file.sync_all()?;
            fsync_parent(path)?;
            let mut journal = Self {
                path: path.to_path_buf(),
                file,
                state: V7State::Begun,
                healthy: true,
            };
            journal.record(V7State::Begun, &[])?;
            Ok(journal)
        }

        fn open(path: &Path) -> Result<Self> {
            require_regular(path, 0o600)?;
            let mut file = OpenOptions::new()
                .read(true)
                .write(true)
                .custom_flags(O_NOFOLLOW | 0x0100_0000)
                .open(path)?;
            validate_open_journal_file(path, &file)?;
            let bytes = read_open_journal_bytes(&mut file)?;
            let complete_length = bytes
                .iter()
                .rposition(|byte| *byte == b'\n')
                .map_or(0, |index| index + 1);
            let complete_text = std::str::from_utf8(&bytes[..complete_length])
                .map_err(|_| ControllerError("v7 journal is not UTF-8".to_owned()))?;
            let state = parse_v7_journal(complete_text)?;
            if complete_length != bytes.len() {
                if !is_plausible_v7_torn_tail(&bytes[complete_length..], state) {
                    return Err(ControllerError(
                        "v7 journal has an implausible incomplete final record".to_owned(),
                    ));
                }
                validate_open_journal_file(path, &file)?;
                file.set_len(complete_length as u64)?;
                file.sync_all()?;
            }
            file.seek(SeekFrom::End(0))?;
            Ok(Self {
                path: path.to_path_buf(),
                file,
                state,
                healthy: true,
            })
        }

        fn record(&mut self, state: V7State, fields: &[(&str, String)]) -> Result<()> {
            self.require_healthy()?;
            validate_v7_transition(self.state, state)?;
            validate_v7_fields(state, fields)?;
            let mut record = Vec::new();
            write!(record, "STATE {}", state.token())?;
            for (key, value) in fields {
                write!(record, " {key}={value}")?;
            }
            record.push(b'\n');
            let prior_length = self.file.seek(SeekFrom::End(0))?;
            self.healthy = false;
            if let Err(error) = self
                .file
                .write_all(&record)
                .and_then(|_| self.file.sync_all())
            {
                let recovery = self.restore_after_failed_append(prior_length);
                return match recovery {
                    Ok(()) => Err(ControllerError(format!(
                        "cannot durably append v7 journal record: {error}"
                    ))),
                    Err(recovery_error) => Err(ControllerError(format!(
                        "cannot durably append v7 journal record ({error}) or restore prior length ({recovery_error})"
                    ))),
                };
            }
            validate_open_journal_file(&self.path, &self.file)?;
            self.state = state;
            self.healthy = true;
            Ok(())
        }

        fn require_healthy(&mut self) -> Result<()> {
            if !self.healthy {
                return Err(ControllerError(
                    "v7 journal is poisoned after an unrecovered append failure".to_owned(),
                ));
            }
            if let Err(error) = validate_open_journal_file(&self.path, &self.file) {
                self.healthy = false;
                return Err(error);
            }
            Ok(())
        }

        fn restore_after_failed_append(&mut self, prior_length: u64) -> Result<()> {
            self.file.set_len(prior_length)?;
            self.file.sync_all()?;
            validate_open_journal_file(&self.path, &self.file)?;
            let bytes = read_open_journal_bytes(&mut self.file)?;
            if bytes.len() as u64 != prior_length || !bytes.ends_with(b"\n") {
                return Err(ControllerError(
                    "v7 journal append recovery did not restore prior durable length".to_owned(),
                ));
            }
            let text = std::str::from_utf8(&bytes)
                .map_err(|_| ControllerError("recovered v7 journal is not UTF-8".to_owned()))?;
            if parse_v7_journal(text)? != self.state {
                return Err(ControllerError(
                    "v7 journal append recovery did not restore prior state".to_owned(),
                ));
            }
            self.file.seek(SeekFrom::End(0))?;
            self.healthy = true;
            Ok(())
        }
    }

    struct V7Layout {
        repo: PathBuf,
        nonce: String,
        evidence: PathBuf,
        source_tar: PathBuf,
        source_export: PathBuf,
        stage_output: PathBuf,
        staged_app: PathBuf,
        deployment_reference_dir: PathBuf,
        deployment_reference_app: PathBuf,
        scratch: PathBuf,
        rollback_dir: PathBuf,
        rollback_app: PathBuf,
        failed_dir: PathBuf,
        failed_app: PathBuf,
        rollback_reserve: PathBuf,
        install_hold_root: PathBuf,
        install_hold: PathBuf,
        production_driver_dir: PathBuf,
        production_driver: PathBuf,
        production_driver_package: PathBuf,
        mirror_probe: PathBuf,
        public_vpio_probe: PathBuf,
        default_route_guardian: PathBuf,
        driver_transaction_record: PathBuf,
        mirror_probe_result: PathBuf,
        vpio_guardian_state: PathBuf,
        vpio_guardian_result: PathBuf,
        vpio_guardian_repair_result: PathBuf,
        vpio_stdout: PathBuf,
        vpio_stderr: PathBuf,
        journal: PathBuf,
        result: PathBuf,
    }

    enum V7Command {
        Preflight(String),
        Execute {
            repo: String,
            authorized_commit: String,
            authorized_tree: String,
        },
        Rollback(String),
        SelfTest,
        ProbeLock {
            runtime: String,
            lock: String,
            pid: String,
        },
        RootControllerBootstrap,
        RootDriverBroker {
            nonce: String,
            staged_driver: String,
            staged_package: String,
        },
        UIDDriverBrokerProxy {
            nonce: String,
            staged_driver: String,
            staged_package: String,
            parent_pid: u32,
            parent_start_sha256: String,
        },
        RootDriverRestoreBroker {
            nonce: String,
        },
        UIDDriverRestoreProxy {
            nonce: String,
            evidence: String,
            pointer_expectation: RetryV7PointerExpectation,
            parent_pid: u32,
            parent_start_sha256: String,
        },
    }

    impl V7Layout {
        fn new(repo: PathBuf, evidence: PathBuf, nonce: &str) -> Self {
            let stage_output = evidence.join("staged-output");
            let deployment_reference_dir = evidence.join("deployment-reference");
            let rollback_dir = evidence.join("rollback-current");
            let failed_dir = evidence.join("failed-new");
            let install_hold_root = PathBuf::from(format!(
                "/Applications/.opensteamer-paired-v7-install-{nonce}"
            ));
            let production_driver_dir = evidence.join("production-driver-v7");
            // The guardian independently restricts its repair state to this exact evidence
            // namespace. Keep this spelling synchronized with its compile-time contract.
            let probes_dir = evidence.join("probes");
            Self {
                repo,
                nonce: nonce.to_owned(),
                source_tar: evidence.join("source.tar"),
                source_export: evidence.join("source-export"),
                staged_app: stage_output.join("opensteamer Host.app"),
                stage_output,
                deployment_reference_app: deployment_reference_dir.join("opensteamer Host.app"),
                deployment_reference_dir,
                scratch: evidence.join("swiftpm-scratch"),
                rollback_app: rollback_dir.join("opensteamer Host.app"),
                rollback_dir,
                failed_app: failed_dir.join("opensteamer Host.app"),
                failed_dir,
                rollback_reserve: evidence.join("rollback-reserve.bin"),
                install_hold: install_hold_root.join("opensteamer Host.app"),
                install_hold_root,
                production_driver: production_driver_dir
                    .join("OpensteamerVirtualMicrophone.driver"),
                production_driver_package: production_driver_dir
                    .join("OpensteamerVirtualMicrophone-v7.pkg"),
                production_driver_dir,
                mirror_probe: probes_dir.join("physical-virtual-microphone-probe"),
                public_vpio_probe: probes_dir.join("opensteamer-public-vpio-probe"),
                default_route_guardian: probes_dir.join("opensteamer-v7-default-route-guardian"),
                driver_transaction_record: evidence.join("driver-transaction-record.txt"),
                mirror_probe_result: probes_dir.join("mirror-loopback.json"),
                vpio_guardian_state: probes_dir.join("vpio-default-route-state.json"),
                vpio_guardian_result: probes_dir.join("vpio-guardian-result.json"),
                vpio_guardian_repair_result: probes_dir.join("vpio-guardian-repair-result.json"),
                vpio_stdout: probes_dir.join("vpio.stdout"),
                vpio_stderr: probes_dir.join("vpio.stderr"),
                journal: evidence.join("journal.log"),
                result: evidence.join("result.txt"),
                evidence,
            }
        }
    }

    pub fn entry() {
        if let Err(error) = paired_v7_real_main() {
            eprintln!("opensteamer paired-v7 update controller: {error}");
            std::process::exit(1);
        }
    }

    /// Read-only admission proof reused by the separately pinned, one-shot local mono trial.
    /// Exposing this narrow wrapper avoids duplicating or weakening the committed v1-v6 chain.
    pub(crate) fn local_trial_verify_exact_v6_admission() -> std::result::Result<(), String> {
        verify_paired_v7_runtime()
            .map(|_| ())
            .and_then(|_| verify_isolated_pairing_items_present())
            .map_err(|error| error.to_string())
    }

    /// Stops only the exact isolated v6 job after re-running the full admission proof.
    pub(crate) fn local_trial_stop_exact_v6() -> std::result::Result<(), String> {
        (|| -> Result<()> {
            let runtime =
                verify_paired_v7_runtime().and_then(|_| verify_isolated_pairing_items_present());
            if runtime.is_err() {
                verify_committed_v6_baseline()?;
                verify_current_baseline_app_at(Path::new(NEW_APP), true)?;
                verify_protected_legacy_absent()?;
                let processes = capture_server_processes()?;
                if !processes.is_empty()
                    && (processes.len() != 1 || processes[0].1 != Path::new(NEW_EXECUTABLE))
                {
                    return Err(ControllerError(format!(
                        "v6 stop recovery found an unexpected CaptureServer topology: {processes:?}"
                    )));
                }
                let state = command_output(
                    "/bin/launchctl",
                    &["print", &format!("gui/{USER_ID}/{NEW_LABEL}")],
                    None,
                )?;
                if service_absence_observation(NEW_LABEL, &state)? {
                    if !processes.is_empty() {
                        wait_for_no_capture_servers(Duration::from_secs(30))?;
                    }
                    require_service_absent(NEW_LAUNCH_AGENT_LABEL)?;
                    acquire_unowned_shared_lock().map(drop)?;
                    return Ok(());
                }
                require_output_success(&state, "inspect partially running exact v6 job")?;
                wait_for_launch_generation(Duration::from_secs(45))?;
                verify_paired_v7_runtime()?;
                verify_isolated_pairing_items_present()?;
            }
            bootout_exact_new_job()?;
            wait_for_no_capture_servers(Duration::from_secs(30))?;
            require_service_absent(NEW_LAUNCH_AGENT_LABEL)?;
            verify_protected_legacy_absent()?;
            acquire_unowned_shared_lock().map(drop)
        })()
        .map_err(|error| error.to_string())
    }

    /// Restarts and proves the exact committed v6 host; no local-trial app or plist is accepted.
    pub(crate) fn local_trial_bootstrap_and_verify_exact_v6() -> std::result::Result<(), String> {
        if verify_paired_v7_runtime()
            .and_then(|_| verify_isolated_pairing_items_present())
            .is_ok()
        {
            return Ok(());
        }
        (|| -> Result<()> {
            verify_committed_v6_baseline()?;
            verify_current_baseline_app_at(Path::new(NEW_APP), true)?;
            verify_protected_legacy_absent()?;
            let processes = capture_server_processes()?;
            if !processes.is_empty()
                && (processes.len() != 1 || processes[0].1 != Path::new(NEW_EXECUTABLE))
            {
                return Err(ControllerError(format!(
                    "v6 recovery found an unexpected CaptureServer topology: {processes:?}"
                )));
            }
            let state = command_output(
                "/bin/launchctl",
                &["print", &format!("gui/{USER_ID}/{NEW_LABEL}")],
                None,
            )?;
            if service_absence_observation(NEW_LABEL, &state)? {
                if !processes.is_empty() {
                    // An interrupted bootout can remove the launchd service before the exact v6
                    // process releases its lock. Converge that old generation fully to absence
                    // before creating the only replacement generation.
                    wait_for_no_capture_servers(Duration::from_secs(30))?;
                    require_service_absent(NEW_LAUNCH_AGENT_LABEL)?;
                    acquire_unowned_shared_lock().map(drop)?;
                }
                bootstrap_exact_new_job()?;
            } else {
                require_output_success(&state, "inspect already-bootstrapped exact v6 job")?;
                if let Some((pid, _)) = processes.first() {
                    require_solo_capture_server(Path::new(NEW_EXECUTABLE), *pid)?;
                }
            }
            wait_for_launch_generation(Duration::from_secs(45))?;
            verify_paired_v7_runtime()?;
            verify_isolated_pairing_items_present()?;
            Ok(())
        })()
        .map_err(|error| error.to_string())
    }

    /// Proves that the one-shot local-trial child is the sole CaptureServer and sole writer of
    /// the canonical shared generation lock. This deliberately does not accept a launchd label
    /// or app publication; the caller supplies the fixed root-owned sealed executable path.
    pub(crate) fn local_trial_verify_candidate_generation(
        pid: u32,
        executable: &std::path::Path,
    ) -> std::result::Result<(u64, u64, String), String> {
        require_solo_capture_server(executable, pid)
            .and_then(|_| read_generation_lock(pid))
            .and_then(|generation| {
                prove_lock_holder(pid, Duration::from_secs(4))?;
                require_service_absent(NEW_LAUNCH_AGENT_LABEL)?;
                verify_protected_legacy_absent()?;
                Ok(generation)
            })
            .map_err(|error| error.to_string())
    }

    /// Proves that a stopped local-trial child cannot still reassert a default route: no
    /// CaptureServer remains, the exact v6 service is absent, and the canonical shared lock is
    /// independently acquirable. The returned guard is intentionally dropped inside this proof.
    pub(crate) fn local_trial_verify_candidate_absent_and_lock_released(
    ) -> std::result::Result<(), String> {
        wait_for_no_capture_servers(Duration::from_secs(30))
            .and_then(|_| require_service_absent(NEW_LAUNCH_AGENT_LABEL))
            .and_then(|_| verify_protected_legacy_absent())
            .and_then(|_| acquire_unowned_shared_lock().map(drop))
            .map_err(|error| error.to_string())
    }

    fn paired_v7_real_main() -> Result<()> {
        let arguments: Vec<String> = env::args().collect();
        verify_optimized_binary_scrub()?;
        let command = parse_v7_command(&arguments)?;
        if !matches!(command, V7Command::SelfTest) {
            require_v7_release_pins()?;
        }
        match command {
            V7Command::Preflight(repo) => {
                let repo = canonical_repo(&repo)?;
                verify_machine_contract()?;
                let provenance = verify_paired_v7_git_provenance(&repo, true)?;
                verify_v7_production_signing_availability()?;
                let release_cycle =
                    verify_reviewed_production_candidate_preflight(&repo, &provenance)?;
                let _transaction_lock = acquire_update_transaction_lock()?;
                verify_committed_v6_baseline()?;
                let generation = verify_paired_v7_runtime()?;
                verify_isolated_pairing_items_present()?;
                require_v7_retry_admission_ready()?;
                println!(
                    "PAIRED_V7_UPDATE_PREFLIGHT_OK pid={} runs={} baseline=sole-ready pairing=preserved v1=immutable v2=immutable v3=immutable v4=immutable v5=immutable v6=immutable v7=absent source_commit={} source_tree={} release_commit={} release_tree={} functional_inputs_sha256={}",
                    generation.pid,
                    generation.runs,
                    release_cycle.candidate.commit,
                    release_cycle.candidate.tree,
                    provenance.commit,
                    provenance.tree,
                    release_cycle.functional_inputs_sha256,
                );
                Ok(())
            }
            V7Command::Execute {
                repo,
                authorized_commit,
                authorized_tree,
            } => execute_paired_v7_update(
                canonical_repo(&repo)?,
                &authorized_commit,
                &authorized_tree,
            ),
            V7Command::Rollback(repo) => rollback_existing_paired_v7_update(canonical_repo(&repo)?),
            V7Command::SelfTest => paired_v7_self_test(),
            V7Command::ProbeLock { runtime, lock, pid } => {
                if runtime != LOCK_DIRECTORY || lock != LOCK_FILE {
                    return Err(ControllerError(
                        "lock probe paths differ from canonical shared lock".to_owned(),
                    ));
                }
                let pid = parse_positive_u32(&pid, "lock-holder PID")?;
                prove_lock_holder(pid, Duration::from_secs(4))?;
                println!("lock_holder={pid}");
                Ok(())
            }
            V7Command::RootControllerBootstrap => bootstrap_root_controller_identity(),
            V7Command::RootDriverBroker {
                nonce,
                staged_driver,
                staged_package,
            } => root_driver_broker(
                &nonce,
                Path::new(&staged_driver),
                Path::new(&staged_package),
            ),
            V7Command::UIDDriverBrokerProxy {
                nonce,
                staged_driver,
                staged_package,
                parent_pid,
                parent_start_sha256,
            } => uid501_driver_broker_proxy(
                &nonce,
                Path::new(&staged_driver),
                Path::new(&staged_package),
                parent_pid,
                &parent_start_sha256,
            ),
            V7Command::RootDriverRestoreBroker { nonce } => root_driver_restore_broker(&nonce),
            V7Command::UIDDriverRestoreProxy {
                nonce,
                evidence,
                pointer_expectation,
                parent_pid,
                parent_start_sha256,
            } => uid501_driver_restore_proxy(
                &nonce,
                Path::new(&evidence),
                pointer_expectation,
                parent_pid,
                &parent_start_sha256,
            ),
        }
    }

    fn parse_v7_command(arguments: &[String]) -> Result<V7Command> {
        match arguments {
            [_, mode, repo] if mode == V7_PREFLIGHT_MODE => {
                Ok(V7Command::Preflight(repo.clone()))
            }
            [_, mode, repo, authorized_commit, authorized_tree] if mode == V7_EXECUTE_MODE => {
                require_canonical_git_oid(authorized_commit, "authorized commit")?;
                require_canonical_git_oid(authorized_tree, "authorized tree")?;
                Ok(V7Command::Execute {
                    repo: repo.clone(),
                    authorized_commit: authorized_commit.clone(),
                    authorized_tree: authorized_tree.clone(),
                })
            }
            [_, mode, repo] if mode == V7_ROLLBACK_MODE => Ok(V7Command::Rollback(repo.clone())),
            [_, mode] if mode == V7_SELF_TEST_MODE => Ok(V7Command::SelfTest),
            [_, mode, runtime, lock, pid] if mode == PROBE_LOCK_MODE => {
                Ok(V7Command::ProbeLock {
                    runtime: runtime.clone(),
                    lock: lock.clone(),
                    pid: pid.clone(),
                })
            }
            [_, mode] if mode == ROOT_V7_CONTROLLER_BOOTSTRAP_MODE => {
                Ok(V7Command::RootControllerBootstrap)
            }
            [_, mode, nonce, staged_driver, staged_package]
                if mode == "--root-driver-broker-v7" =>
            {
                validate_v7_nonce(nonce)?;
                Ok(V7Command::RootDriverBroker {
                    nonce: nonce.clone(),
                    staged_driver: staged_driver.clone(),
                    staged_package: staged_package.clone(),
                })
            }
            [_, mode, nonce] if mode == "--root-driver-restore-broker-v7" => {
                validate_v7_nonce(nonce)?;
                Ok(V7Command::RootDriverRestoreBroker {
                    nonce: nonce.clone(),
                })
            }
            [
                _,
                mode,
                nonce,
                staged_driver,
                staged_package,
                parent_pid,
                parent_start_sha256,
            ]
                if mode == "--uid501-driver-broker-proxy-v7" =>
            {
                validate_v7_nonce(nonce)?;
                let parent_pid = parse_positive_u32(parent_pid, "v7 broker parent PID")?;
                require_canonical_lower_hex(
                    parent_start_sha256,
                    64,
                    "v7 broker parent start SHA-256",
                )?;
                Ok(V7Command::UIDDriverBrokerProxy {
                    nonce: nonce.clone(),
                    staged_driver: staged_driver.clone(),
                    staged_package: staged_package.clone(),
                    parent_pid,
                    parent_start_sha256: parent_start_sha256.clone(),
                })
            }
            [
                _,
                mode,
                nonce,
                evidence,
                pointer_expectation,
                parent_pid,
                parent_start_sha256,
            ]
                if mode == "--uid501-driver-restore-proxy-v7" =>
            {
                validate_v7_nonce(nonce)?;
                let pointer_expectation =
                    RetryV7PointerExpectation::from_token(pointer_expectation)?;
                let parent_pid = parse_positive_u32(parent_pid, "v7 restore parent PID")?;
                require_canonical_lower_hex(
                    parent_start_sha256,
                    64,
                    "v7 restore parent start SHA-256",
                )?;
                Ok(V7Command::UIDDriverRestoreProxy {
                    nonce: nonce.clone(),
                    evidence: evidence.clone(),
                    pointer_expectation,
                    parent_pid,
                    parent_start_sha256: parent_start_sha256.clone(),
                })
            }
            _ => Err(ControllerError(format!(
                "usage: {} {V7_PREFLIGHT_MODE} <canonical-repo>\n       {} {V7_EXECUTE_MODE} <canonical-repo> <authorized-commit> <authorized-tree>\n       {} {V7_ROLLBACK_MODE} <canonical-repo>\n       {} {V7_SELF_TEST_MODE}\n       {} {PROBE_LOCK_MODE} <runtime-dir> <lock-file> <pid>",
                arguments.first().map_or("controller", String::as_str),
                arguments.first().map_or("controller", String::as_str),
                arguments.first().map_or("controller", String::as_str),
                arguments.first().map_or("controller", String::as_str),
                arguments.first().map_or("controller", String::as_str),
            ))),
        }
    }

    fn require_canonical_git_oid(value: &str, label: &str) -> Result<()> {
        require_canonical_lower_hex(value, 40, label)
    }

    fn require_canonical_lower_hex(value: &str, length: usize, label: &str) -> Result<()> {
        if value.len() != length
            || !value
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err(ControllerError(format!(
                "{label} must be exactly {length} lowercase hexadecimal characters"
            )));
        }
        Ok(())
    }

    fn release_pins_complete(status: &str, text_pins: &[&str], numeric_pins: &[u64]) -> bool {
        status == RELEASE_PIN_READY
            && !text_pins.is_empty()
            && text_pins.iter().all(|pin| {
                !pin.is_empty()
                    && !pin.contains(RELEASE_PIN_PLACEHOLDER)
                    && !pin.contains("UNPINNED")
            })
            && numeric_pins.iter().all(|pin| *pin != 0 && *pin != u64::MAX)
    }

    fn require_v7_release_pins() -> Result<()> {
        let text_pins = [
            NOTARY_KEYCHAIN_PROFILE,
            EXPECTED_DEVELOPER_ID_APPLICATION_SHA1,
            EXPECTED_DEVELOPER_ID_INSTALLER_IDENTITY_SHA1,
            EXPECTED_DEVELOPER_ID_INSTALLER_LEAF_SHA256,
            REVIEWED_PRODUCTION_DRIVER_CANDIDATE_ROOT,
            EXPECTED_PRODUCTION_DRIVER_CANDIDATE_MANIFEST_SHA256,
            EXPECTED_FUNCTIONAL_INPUTS_SHA256,
            EXPECTED_PRODUCTION_DRIVER_TREE_SHA256,
            EXPECTED_PRODUCTION_DRIVER_EXECUTABLE_SHA256,
            EXPECTED_PRODUCTION_DRIVER_PACKAGE_SHA256,
            EXPECTED_MIRROR_PROBE_SOURCE_SHA256,
            EXPECTED_MIRROR_PROBE_BINARY_SHA256,
            EXPECTED_PUBLIC_VPIO_PROBE_BUILDER_SHA256,
            EXPECTED_PUBLIC_VPIO_PROBE_SOURCE_SHA256,
            EXPECTED_PUBLIC_VPIO_PROBE_CORE_SOURCE_SHA256,
            EXPECTED_PUBLIC_VPIO_PROBE_HEADER_SHA256,
            EXPECTED_PUBLIC_VPIO_PROBE_BINARY_SHA256,
            EXPECTED_DEFAULT_ROUTE_GUARDIAN_SOURCE_SHA256,
            EXPECTED_DEFAULT_ROUTE_GUARDIAN_BINARY_SHA256,
            EXPECTED_PRODUCTION_DRIVER_BUILDER_SHA256,
            EXPECTED_PRODUCTION_DRIVER_VERIFIER_SHA256,
            EXPECTED_INSTALLER_SIGNATURE_PARSER_SHA256,
            REQUIRED_REPO_OWNED_DRIVER_PATCH_COMMIT,
        ];
        let numeric_pins = [COMMITTED_V5_RESERVE_INODE, COMMITTED_V6_RESERVE_INODE];
        if !release_pins_complete(RELEASE_PIN_STATUS, &text_pins, &numeric_pins) {
            return Err(ControllerError(
                "paired-v7 is intentionally unrunnable until final source, v6 evidence, signing, notarization, driver, package, and probe pins are reviewed"
                    .to_owned(),
            ));
        }
        for (label, value, expected_length) in [
            (
                "production driver candidate manifest SHA-256",
                EXPECTED_PRODUCTION_DRIVER_CANDIDATE_MANIFEST_SHA256,
                64,
            ),
            (
                "functional input manifest SHA-256",
                EXPECTED_FUNCTIONAL_INPUTS_SHA256,
                64,
            ),
            (
                "production driver tree SHA-256",
                EXPECTED_PRODUCTION_DRIVER_TREE_SHA256,
                64,
            ),
            (
                "production driver executable SHA-256",
                EXPECTED_PRODUCTION_DRIVER_EXECUTABLE_SHA256,
                64,
            ),
            (
                "production driver package SHA-256",
                EXPECTED_PRODUCTION_DRIVER_PACKAGE_SHA256,
                64,
            ),
            (
                "mirror probe source SHA-256",
                EXPECTED_MIRROR_PROBE_SOURCE_SHA256,
                64,
            ),
            (
                "mirror probe binary SHA-256",
                EXPECTED_MIRROR_PROBE_BINARY_SHA256,
                64,
            ),
            (
                "public VPIO probe builder SHA-256",
                EXPECTED_PUBLIC_VPIO_PROBE_BUILDER_SHA256,
                64,
            ),
            (
                "public VPIO probe source SHA-256",
                EXPECTED_PUBLIC_VPIO_PROBE_SOURCE_SHA256,
                64,
            ),
            (
                "public VPIO probe core source SHA-256",
                EXPECTED_PUBLIC_VPIO_PROBE_CORE_SOURCE_SHA256,
                64,
            ),
            (
                "public VPIO probe header SHA-256",
                EXPECTED_PUBLIC_VPIO_PROBE_HEADER_SHA256,
                64,
            ),
            (
                "public VPIO probe binary SHA-256",
                EXPECTED_PUBLIC_VPIO_PROBE_BINARY_SHA256,
                64,
            ),
            (
                "default-route guardian source SHA-256",
                EXPECTED_DEFAULT_ROUTE_GUARDIAN_SOURCE_SHA256,
                64,
            ),
            (
                "default-route guardian binary SHA-256",
                EXPECTED_DEFAULT_ROUTE_GUARDIAN_BINARY_SHA256,
                64,
            ),
            (
                "production driver builder SHA-256",
                EXPECTED_PRODUCTION_DRIVER_BUILDER_SHA256,
                64,
            ),
            (
                "production driver verifier SHA-256",
                EXPECTED_PRODUCTION_DRIVER_VERIFIER_SHA256,
                64,
            ),
            (
                "installer signature parser SHA-256",
                EXPECTED_INSTALLER_SIGNATURE_PARSER_SHA256,
                64,
            ),
        ] {
            if value.len() != expected_length
                || !value
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
            {
                return Err(ControllerError(format!(
                    "{label} is not an exact lowercase hexadecimal release pin"
                )));
            }
        }
        for (label, value) in [
            (
                "Developer ID Application SHA-1",
                EXPECTED_DEVELOPER_ID_APPLICATION_SHA1,
            ),
            (
                "Developer ID Installer SHA-1",
                EXPECTED_DEVELOPER_ID_INSTALLER_IDENTITY_SHA1,
            ),
        ] {
            if value.len() != 40
                || !value
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'A'..=b'F').contains(&byte))
            {
                return Err(ControllerError(format!(
                    "{label} is not an exact uppercase hexadecimal release pin"
                )));
            }
        }
        if EXPECTED_DEVELOPER_ID_INSTALLER_LEAF_SHA256.len() != 64
            || !EXPECTED_DEVELOPER_ID_INSTALLER_LEAF_SHA256
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'A'..=b'F').contains(&byte))
        {
            return Err(ControllerError(
                "Developer ID Installer leaf SHA-256 is not an exact uppercase hexadecimal release pin"
                    .to_owned(),
            ));
        }
        require_canonical_git_oid(
            REQUIRED_REPO_OWNED_DRIVER_PATCH_COMMIT,
            "required repo-owned driver patch commit",
        )
    }

    fn count_exact_production_identity(
        identity_text: &str,
        certificate_sha1: &str,
        identity_kind: &str,
    ) -> usize {
        let label = format!("{identity_kind}:");
        let team = format!("({EXPECTED_DRIVER_TEAM_ID})");
        identity_text
            .lines()
            .filter(|line| {
                line.contains(certificate_sha1) && line.contains(&label) && line.contains(&team)
            })
            .count()
    }

    fn verify_pinned_xcode_developer_directory() -> Result<()> {
        let application_link = Path::new(PINNED_XCODE_APPLICATION_LINK);
        let application_link_metadata = fs::symlink_metadata(application_link)?;
        if !application_link_metadata.file_type().is_symlink() {
            return Err(ControllerError(
                "pinned production Xcode application path is not the reviewed symlink"
                    .to_owned(),
            ));
        }
        let application_target = fs::read_link(application_link)?;
        if !application_target.is_absolute()
            || application_target.to_str() != Some(PINNED_XCODE_APPLICATION_TARGET)
        {
            return Err(ControllerError(
                "pinned production Xcode application symlink target changed".to_owned(),
            ));
        }

        let canonical_developer_directory = fs::canonicalize(PINNED_XCODE_DEVELOPER_DIR)?;
        if canonical_developer_directory != Path::new(PINNED_XCODE_RESOLVED_DEVELOPER_DIR) {
            return Err(ControllerError(
                "pinned production Xcode developer directory resolved elsewhere".to_owned(),
            ));
        }
        let resolved_developer_directory =
            fs::symlink_metadata(PINNED_XCODE_RESOLVED_DEVELOPER_DIR)?;
        if !resolved_developer_directory.file_type().is_dir()
            || resolved_developer_directory.file_type().is_symlink()
            || resolved_developer_directory.uid() != PINNED_XCODE_DEVELOPER_UID
            || resolved_developer_directory.gid() != PINNED_XCODE_DEVELOPER_GID
            || resolved_developer_directory.permissions().mode() & 0o7777
                != PINNED_XCODE_DEVELOPER_MODE
        {
            return Err(ControllerError(
                "resolved production Xcode developer directory is unavailable or unsafe"
                    .to_owned(),
            ));
        }

        let swiftc_alias = Path::new(PINNED_XCODE_SWIFTC_ALIAS);
        let swiftc_alias_metadata = fs::symlink_metadata(swiftc_alias)?;
        if !swiftc_alias_metadata.file_type().is_symlink() {
            return Err(ControllerError(
                "pinned production swiftc alias is not the reviewed symlink".to_owned(),
            ));
        }
        let swiftc_alias_target = fs::read_link(swiftc_alias)?;
        if swiftc_alias_target.to_str() != Some(PINNED_XCODE_SWIFTC_ALIAS_TARGET) {
            return Err(ControllerError(
                "pinned production swiftc alias target changed".to_owned(),
            ));
        }

        for (tool, expected_sha256, description) in [
            (
                PINNED_XCODE_SWIFT_FRONTEND,
                EXPECTED_XCODE_SWIFT_FRONTEND_SHA256,
                "Swift frontend",
            ),
            (
                PINNED_XCODE_CLANG,
                EXPECTED_XCODE_CLANG_SHA256,
                "Clang linker driver",
            ),
        ] {
            let tool_path = Path::new(tool);
            let tool_metadata = fs::symlink_metadata(tool_path)?;
            if !tool_metadata.file_type().is_file()
                || tool_metadata.file_type().is_symlink()
                || tool_metadata.permissions().mode() & 0o111 == 0
            {
                return Err(ControllerError(format!(
                    "pinned production {description} is not a regular executable"
                )));
            }
            if sha256(tool_path)? != expected_sha256 {
                return Err(ControllerError(format!(
                    "pinned production {description} bytes changed"
                )));
            }
        }

        let xcrun_swiftc = Command::new("/usr/bin/xcrun")
            .args(["--sdk", "macosx", "--find", "swiftc"])
            .env_clear()
            .env("LC_ALL", "C")
            .env("HOME", USER_HOME)
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .env("DEVELOPER_DIR", PINNED_XCODE_DEVELOPER_DIR)
            .output()?;
        require_output_success(&xcrun_swiftc, "resolve the pinned production swiftc")?;
        let expected_xcrun_swiftc = format!("{PINNED_XCODE_RESOLVED_SWIFTC_ALIAS}\n");
        if !xcrun_swiftc.stderr.is_empty()
            || xcrun_swiftc.stdout.as_slice() != expected_xcrun_swiftc.as_bytes()
        {
            return Err(ControllerError(
                "pinned production xcrun swiftc resolution changed".to_owned(),
            ));
        }

        let swiftc_version = Command::new("/usr/bin/xcrun")
            .args(["--sdk", "macosx", "swiftc", "--version"])
            .env_clear()
            .env("LC_ALL", "C")
            .env("HOME", USER_HOME)
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .env("DEVELOPER_DIR", PINNED_XCODE_DEVELOPER_DIR)
            .output()?;
        require_output_success(&swiftc_version, "inspect the pinned production swiftc version")?;
        let version_stderr = decode_utf8(
            &swiftc_version.stderr,
            "pinned production swiftc version stderr",
        )?;
        let version_stdout = decode_utf8(
            &swiftc_version.stdout,
            "pinned production swiftc version stdout",
        )?;
        let observed_swiftc_version = format!("{version_stderr}{version_stdout}");
        if observed_swiftc_version.strip_suffix('\n') != Some(EXPECTED_XCODE_SWIFTC_VERSION) {
            return Err(ControllerError(
                "pinned production swiftc version changed".to_owned(),
            ));
        }
        Ok(())
    }

    fn verify_v7_production_signing_availability() -> Result<()> {
        for (path, mode) in [("/usr/bin/security", 0o755), ("/usr/bin/xcrun", 0o755)] {
            require_fixed_system_binary(Path::new(path), mode)?;
        }
        verify_pinned_xcode_developer_directory()?;
        if NOTARY_KEYCHAIN_PROFILE.len() > 128
            || !NOTARY_KEYCHAIN_PROFILE
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        {
            return Err(ControllerError(
                "notary keychain profile release pin is unsafe".to_owned(),
            ));
        }
        let identities = command_output("/usr/bin/security", &["find-identity", "-v"], None)?;
        require_output_success(&identities, "enumerate production signing identities")?;
        if identities.stdout.len() > 262_144 || !identities.stderr.is_empty() {
            return Err(ControllerError(
                "production signing identity enumeration output is not exact".to_owned(),
            ));
        }
        let identity_text = decode_utf8(
            &identities.stdout,
            "production signing identity enumeration",
        )?;
        if count_exact_production_identity(
            identity_text,
            EXPECTED_DEVELOPER_ID_APPLICATION_SHA1,
            "Developer ID Application",
        ) != 1
            || count_exact_production_identity(
                identity_text,
                EXPECTED_DEVELOPER_ID_INSTALLER_IDENTITY_SHA1,
                "Developer ID Installer",
            ) != 1
        {
            return Err(ControllerError(
                "exact Developer ID Application and Installer identities for Team MSMG8CJLB3 must each be available once"
                    .to_owned(),
            ));
        }

        let notary = Command::new("/usr/bin/xcrun")
            .args([
                "notarytool",
                "history",
                "--keychain-profile",
                NOTARY_KEYCHAIN_PROFILE,
                "--output-format",
                "json",
            ])
            .env_clear()
            .env("LC_ALL", "C")
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .env("DEVELOPER_DIR", PINNED_XCODE_DEVELOPER_DIR)
            .output()?;
        require_output_success(&notary, "authenticate the pinned notarytool profile")?;
        if notary.stdout.is_empty() || notary.stdout.len() > 1_048_576 || !notary.stderr.is_empty()
        {
            return Err(ControllerError(
                "pinned notarytool profile did not return bounded JSON history".to_owned(),
            ));
        }
        let notary_text = decode_utf8(&notary.stdout, "notarytool JSON history")?;
        if !matches!(
            notary_text.trim_start().as_bytes().first(),
            Some(b'{') | Some(b'[')
        ) {
            return Err(ControllerError(
                "pinned notarytool profile returned non-JSON history".to_owned(),
            ));
        }
        Ok(())
    }

    fn verify_reviewed_production_candidate_preflight(
        repo: &Path,
        provenance: &Provenance,
    ) -> Result<ReleaseCycleEvidence> {
        let verifier =
            repo.join("macOS/VirtualAudioDriver/scripts/verify-production-driver-package-v7.sh");
        require_regular(&verifier, 0o755)?;
        if sha256(&verifier)? != EXPECTED_PRODUCTION_DRIVER_VERIFIER_SHA256 {
            return Err(ControllerError(
                "production driver verifier differs from its release pin".to_owned(),
            ));
        }
        let parser = repo.join("macOS/VirtualAudioDriver/scripts/parse-installer-signature-v7.sh");
        require_regular(&parser, 0o755)?;
        if sha256(&parser)? != EXPECTED_INSTALLER_SIGNATURE_PARSER_SHA256 {
            return Err(ControllerError(
                "installer signature parser differs from its release pin".to_owned(),
            ));
        }
        let candidate = Path::new(REVIEWED_PRODUCTION_DRIVER_CANDIDATE_ROOT);
        require_directory(candidate, 0o500)?;
        let manifest = candidate.join("candidate-manifest.txt");
        require_regular(&manifest, 0o400)?;
        if sha256(&manifest)? != EXPECTED_PRODUCTION_DRIVER_CANDIDATE_MANIFEST_SHA256 {
            return Err(ControllerError(
                "reviewed production-driver candidate manifest changed".to_owned(),
            ));
        }
        let release_cycle = verify_candidate_manifest_provenance(
            &manifest,
            repo,
            provenance,
            EXPECTED_FUNCTIONAL_INPUTS_SHA256,
        )?;
        let driver = candidate.join(PRODUCT_DRIVER_NAME);
        let package = candidate.join("OpensteamerVirtualMicrophone-v7.pkg");
        let verification = Command::new(&verifier)
            .args([
                path_text(&driver)?,
                path_text(&package)?,
                EXPECTED_DEVELOPER_ID_APPLICATION_SHA1,
                EXPECTED_DEVELOPER_ID_INSTALLER_LEAF_SHA256,
                EXPECTED_PRODUCTION_DRIVER_TREE_SHA256,
                EXPECTED_PRODUCTION_DRIVER_EXECUTABLE_SHA256,
                EXPECTED_PRODUCTION_DRIVER_PACKAGE_SHA256,
            ])
            .env_clear()
            .env("LC_ALL", "C")
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .env("DEVELOPER_DIR", PINNED_XCODE_DEVELOPER_DIR)
            .output()?;
        require_output_success(
            &verification,
            "preflight the exact reviewed production driver candidate",
        )?;
        let stdout = decode_utf8(
            &verification.stdout,
            "production driver candidate preflight stdout",
        )?;
        if !stdout.ends_with("VERIFIED_DEVELOPER_ID_NOTARIZED_STAPLED_DRIVER_PACKAGE_V7\n") {
            return Err(ControllerError(
                "production driver candidate preflight omitted its exact success marker".to_owned(),
            ));
        }
        Ok(release_cycle)
    }

    fn validate_v7_nonce(nonce: &str) -> Result<()> {
        if nonce.len() != 36
            || nonce.bytes().enumerate().any(|(index, byte)| match index {
                8 | 13 | 18 | 23 => byte != b'-',
                _ => !(byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)),
            })
        {
            return Err(ControllerError(
                "v7 transaction nonce is malformed".to_owned(),
            ));
        }
        Ok(())
    }

    #[derive(Clone, Debug, Eq, PartialEq)]
    struct RootNodeIdentity {
        present: bool,
        device: u64,
        inode: u64,
        mode: u32,
        kind: String,
    }

    #[derive(Clone, Debug, Eq, PartialEq)]
    struct ControllerBinaryIdentity {
        device: u64,
        inode: u64,
        length: u64,
        sha256: String,
    }

    #[derive(Clone, Debug, Eq, PartialEq)]
    struct CandidateSourceBinding {
        commit: String,
        tree: String,
        branch: String,
        remote: String,
    }

    #[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
    struct FunctionalInputDigest {
        path: String,
        mode: String,
        sha256: String,
    }

    #[derive(Clone, Debug, Eq, PartialEq)]
    struct ReleaseCycleEvidence {
        candidate: CandidateSourceBinding,
        release_commit: String,
        release_tree: String,
        changed_paths: Vec<String>,
        functional_inputs: Vec<FunctionalInputDigest>,
        functional_inputs_sha256: String,
    }

    struct RootDriverLayout {
        root: PathBuf,
        hold: PathBuf,
        package: PathBuf,
        prior: PathBuf,
        failed: PathBuf,
        abandoned: PathBuf,
        state: PathBuf,
    }

    fn root_driver_layout(nonce: &str) -> Result<RootDriverLayout> {
        validate_v7_nonce(nonce)?;
        let root = Path::new(ROOT_V7_TRANSACTION_PARENT).join(format!("transaction-{nonce}"));
        Ok(RootDriverLayout {
            hold: root.join(PRODUCT_DRIVER_NAME),
            package: root.join("OpensteamerVirtualMicrophone-v7.pkg"),
            prior: root.join("prior-product-driver.node"),
            failed: root.join("failed-v7-product-driver.node"),
            abandoned: root.join("abandoned-v7-install-hold.node"),
            state: root.join("state.txt"),
            root,
        })
    }

    fn stable_controller_binary_identity(
        path: &Path,
        expected_uid: u32,
        expected_gid: Option<u32>,
        expected_mode: u32,
    ) -> Result<ControllerBinaryIdentity> {
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(O_NOFOLLOW)
            .open(path)?;
        let before = file.metadata()?;
        let named_before = fs::symlink_metadata(path)?;
        let metadata_is_exact = |metadata: &fs::Metadata| {
            metadata.file_type().is_file()
                && !metadata.file_type().is_symlink()
                && metadata.uid() == expected_uid
                && expected_gid.is_none_or(|gid| metadata.gid() == gid)
                && metadata.nlink() == 1
                && metadata.permissions().mode() & 0o777 == expected_mode
                && metadata.len() > 0
                && metadata.len() <= MAX_V7_CONTROLLER_BYTES
        };
        if !metadata_is_exact(&before)
            || !metadata_is_exact(&named_before)
            || before.dev() != named_before.dev()
            || before.ino() != named_before.ino()
            || before.len() != named_before.len()
        {
            return Err(ControllerError(format!(
                "v7 controller inode metadata is unsafe: {}",
                path.display()
            )));
        }
        let mut bytes = Vec::with_capacity(before.len() as usize);
        Read::by_ref(&mut file)
            .take(MAX_V7_CONTROLLER_BYTES + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() as u64 != before.len() {
            return Err(ControllerError(
                "v7 controller length changed during its bounded read".to_owned(),
            ));
        }
        let after = file.metadata()?;
        let named_after = fs::symlink_metadata(path)?;
        if !metadata_is_exact(&after)
            || !metadata_is_exact(&named_after)
            || before.dev() != after.dev()
            || before.ino() != after.ino()
            || before.len() != after.len()
            || before.dev() != named_after.dev()
            || before.ino() != named_after.ino()
            || before.len() != named_after.len()
        {
            return Err(ControllerError(
                "v7 controller inode changed while deriving its digest".to_owned(),
            ));
        }
        Ok(ControllerBinaryIdentity {
            device: before.dev(),
            inode: before.ino(),
            length: before.len(),
            sha256: sha256_bytes(&bytes)?,
        })
    }

    fn verified_uid501_controller_identity() -> Result<ControllerBinaryIdentity> {
        if unsafe { geteuid() } != USER_ID {
            return Err(ControllerError(
                "unprivileged v7 controller mode requires exact uid 501".to_owned(),
            ));
        }
        let executable = env::current_exe()?;
        if executable.file_name().and_then(|value| value.to_str()) != Some("controller") {
            return Err(ControllerError(
                "v7 controller executable name is not the reviewed launcher output".to_owned(),
            ));
        }
        let parent = executable
            .parent()
            .ok_or_else(|| ControllerError("v7 controller has no build parent".to_owned()))?;
        let leaf = parent
            .file_name()
            .and_then(|value| value.to_str())
            .ok_or_else(|| ControllerError("v7 controller build leaf is not UTF-8".to_owned()))?;
        if !leaf.starts_with(".paired-v7-controller-build.")
            || parent.parent() != Some(Path::new(PRIVATE_ROOT))
        {
            return Err(ControllerError(
                "v7 controller escaped the external launcher's private build directory".to_owned(),
            ));
        }
        let parent_metadata = fs::symlink_metadata(parent)?;
        if !parent_metadata.file_type().is_dir()
            || parent_metadata.file_type().is_symlink()
            || parent_metadata.uid() != USER_ID
            || parent_metadata.permissions().mode() & 0o777 != 0o700
        {
            return Err(ControllerError(
                "v7 controller private build directory metadata is unsafe".to_owned(),
            ));
        }
        stable_controller_binary_identity(&executable, USER_ID, None, 0o500)
    }

    fn controller_identity_journal(identity: &ControllerBinaryIdentity) -> String {
        format!(
            "OPENSTEAMER_V7_CONTROLLER_IDENTITY_V1\ncontroller_path={ROOT_V7_CONTROLLER}\ncontroller_device={}\ncontroller_inode={}\ncontroller_length={}\ncontroller_sha256={}\n",
            identity.device, identity.inode, identity.length, identity.sha256
        )
    }

    fn parse_controller_identity_journal(text: &str) -> Result<ControllerBinaryIdentity> {
        let mut lines = text.lines();
        let expected_path_line = format!("controller_path={ROOT_V7_CONTROLLER}");
        if lines.next() != Some("OPENSTEAMER_V7_CONTROLLER_IDENTITY_V1")
            || lines.next() != Some(expected_path_line.as_str())
        {
            return Err(ControllerError(
                "root controller identity journal header is invalid".to_owned(),
            ));
        }
        let parse_number = |line: Option<&str>, prefix: &str| -> Result<u64> {
            line.and_then(|value| value.strip_prefix(prefix))
                .ok_or_else(|| {
                    ControllerError("root controller identity journal is malformed".to_owned())
                })?
                .parse::<u64>()
                .map_err(|_| {
                    ControllerError(
                        "root controller identity journal number is malformed".to_owned(),
                    )
                })
        };
        let device = parse_number(lines.next(), "controller_device=")?;
        let inode = parse_number(lines.next(), "controller_inode=")?;
        let length = parse_number(lines.next(), "controller_length=")?;
        let sha256 = lines
            .next()
            .and_then(|value| value.strip_prefix("controller_sha256="))
            .ok_or_else(|| {
                ControllerError("root controller identity journal digest is absent".to_owned())
            })?
            .to_owned();
        if lines.next().is_some() || !text.ends_with('\n') {
            return Err(ControllerError(
                "root controller identity journal has extra or unterminated data".to_owned(),
            ));
        }
        require_canonical_lower_hex(&sha256, 64, "root controller identity journal SHA-256")?;
        if device == 0 || inode == 0 || length == 0 || length > MAX_V7_CONTROLLER_BYTES {
            return Err(ControllerError(
                "root controller identity journal contains impossible inode data".to_owned(),
            ));
        }
        Ok(ControllerBinaryIdentity {
            device,
            inode,
            length,
            sha256,
        })
    }

    fn read_root_sealed_utf8(path: &Path, maximum: u64) -> Result<String> {
        require_root_regular(path, 0o400)?;
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(O_NOFOLLOW)
            .open(path)?;
        let before = file.metadata()?;
        let named_before = fs::symlink_metadata(path)?;
        if before.dev() != named_before.dev()
            || before.ino() != named_before.ino()
            || before.len() != named_before.len()
            || before.len() > maximum
        {
            return Err(ControllerError(
                "root-sealed controller record changed before read".to_owned(),
            ));
        }
        let mut bytes = Vec::with_capacity(before.len() as usize);
        Read::by_ref(&mut file)
            .take(maximum + 1)
            .read_to_end(&mut bytes)?;
        let after = file.metadata()?;
        let named_after = fs::symlink_metadata(path)?;
        require_root_regular(path, 0o400)?;
        if bytes.len() as u64 != before.len()
            || before.dev() != after.dev()
            || before.ino() != after.ino()
            || before.len() != after.len()
            || before.dev() != named_after.dev()
            || before.ino() != named_after.ino()
            || before.len() != named_after.len()
        {
            return Err(ControllerError(
                "root-sealed controller record changed during read".to_owned(),
            ));
        }
        String::from_utf8(bytes)
            .map_err(|_| ControllerError("root-sealed controller record is not UTF-8".to_owned()))
    }

    fn read_root_controller_identity_records() -> Result<ControllerBinaryIdentity> {
        let pin = read_root_sealed_utf8(Path::new(ROOT_V7_CONTROLLER_PIN), 65)?;
        let digest = pin.strip_suffix('\n').ok_or_else(|| {
            ControllerError("root controller digest pin is not newline-terminated".to_owned())
        })?;
        require_canonical_lower_hex(digest, 64, "root controller digest pin")?;
        let journal = read_root_sealed_utf8(
            Path::new(ROOT_V7_CONTROLLER_IDENTITY_JOURNAL),
            1_024,
        )?;
        let identity = parse_controller_identity_journal(&journal)?;
        if identity.sha256 != digest {
            return Err(ControllerError(
                "root controller pin and identity journal disagree".to_owned(),
            ));
        }
        Ok(identity)
    }

    fn require_root_controller_identity_binding(
        actual: &ControllerBinaryIdentity,
        sealed: &ControllerBinaryIdentity,
    ) -> Result<()> {
        if actual != sealed {
            return Err(ControllerError(
                "root-owned v7 controller inode or digest differs from its sealed identity journal"
                    .to_owned(),
            ));
        }
        Ok(())
    }

    fn require_proxy_controller_identity_binding(
        actual: &ControllerBinaryIdentity,
        sealed: &ControllerBinaryIdentity,
    ) -> Result<()> {
        if actual.sha256 != sealed.sha256 || actual.length != sealed.length {
            return Err(ControllerError(
                "UID501 proxy controller digest differs from the sealed root controller identity"
                    .to_owned(),
            ));
        }
        Ok(())
    }

    fn create_or_verify_root_sealed(path: &Path, expected: &str) -> Result<()> {
        match fs::symlink_metadata(path) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let mut file = root_create_new_private(path)?;
                file.write_all(expected.as_bytes())?;
                file.sync_all()?;
                file.set_permissions(fs::Permissions::from_mode(0o400))?;
                file.sync_all()?;
                fsync_parent(path)?;
            }
            Err(error) => return Err(error.into()),
            Ok(_) => {}
        }
        if read_root_sealed_utf8(path, 1_024)? != expected {
            return Err(ControllerError(format!(
                "root-sealed controller record differs from the authenticated inode: {}",
                path.display()
            )));
        }
        Ok(())
    }

    fn bootstrap_root_controller_identity() -> Result<()> {
        if unsafe { geteuid() } != 0 || env::current_exe()? != Path::new(ROOT_V7_CONTROLLER) {
            return Err(ControllerError(
                "root controller identity bootstrap escaped its authenticated fixed path"
                    .to_owned(),
            ));
        }
        require_root_private_directory(Path::new(ROOT_V7_SUPPORT_DIRECTORY))?;
        let identity = stable_controller_binary_identity(
            Path::new(ROOT_V7_CONTROLLER),
            0,
            Some(0),
            0o500,
        )?;
        create_or_verify_root_sealed(
            Path::new(ROOT_V7_CONTROLLER_PIN),
            &format!("{}\n", identity.sha256),
        )?;
        create_or_verify_root_sealed(
            Path::new(ROOT_V7_CONTROLLER_IDENTITY_JOURNAL),
            &controller_identity_journal(&identity),
        )?;
        if read_root_controller_identity_records()? != identity {
            return Err(ControllerError(
                "root controller identity records did not revalidate the authenticated inode"
                    .to_owned(),
            ));
        }
        println!("ROOT_V7_CONTROLLER_IDENTITY_SEALED");
        Ok(())
    }

    fn verify_root_controller_identity() -> Result<ControllerBinaryIdentity> {
        if unsafe { geteuid() } != 0 {
            return Err(ControllerError(
                "privileged v7 driver mode requires effective UID 0".to_owned(),
            ));
        }
        let executable = env::current_exe()?;
        if executable != Path::new(ROOT_V7_CONTROLLER) {
            return Err(ControllerError(
                "privileged v7 driver mode escaped the fixed root-owned controller path".to_owned(),
            ));
        }
        let actual = stable_controller_binary_identity(&executable, 0, Some(0), 0o500)?;
        let sealed = read_root_controller_identity_records()?;
        require_root_controller_identity_binding(&actual, &sealed)?;
        Ok(actual)
    }

    fn require_root_private_directory(path: &Path) -> Result<()> {
        let metadata = fs::symlink_metadata(path)?;
        if !metadata.file_type().is_dir()
            || metadata.file_type().is_symlink()
            || metadata.uid() != 0
            || metadata.gid() != 0
            || metadata.permissions().mode() & 0o777 != 0o700
        {
            return Err(ControllerError(format!(
                "root-private v7 directory metadata is unsafe: {}",
                path.display()
            )));
        }
        Ok(())
    }

    fn require_root_regular(path: &Path, expected_mode: u32) -> Result<()> {
        let metadata = fs::symlink_metadata(path)?;
        if !metadata.file_type().is_file()
            || metadata.file_type().is_symlink()
            || metadata.uid() != 0
            || metadata.gid() != 0
            || metadata.nlink() != 1
            || metadata.permissions().mode() & 0o777 != expected_mode
        {
            return Err(ControllerError(format!(
                "root-private file metadata is unsafe: {}",
                path.display()
            )));
        }
        Ok(())
    }

    fn root_create_new_private(path: &Path) -> Result<File> {
        let file = OpenOptions::new()
            .create_new(true)
            .read(true)
            .write(true)
            .mode(0o600)
            .custom_flags(O_NOFOLLOW)
            .open(path)?;
        require_root_regular(path, 0o600)?;
        let descriptor = file.metadata()?;
        let named = fs::symlink_metadata(path)?;
        if descriptor.dev() != named.dev() || descriptor.ino() != named.ino() {
            return Err(ControllerError(
                "root-private file was replaced during creation".to_owned(),
            ));
        }
        Ok(file)
    }

    fn read_root_bounded_utf8(path: &Path, maximum: u64) -> Result<String> {
        require_root_regular(path, 0o600)?;
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(O_NOFOLLOW)
            .open(path)?;
        let descriptor = file.metadata()?;
        let named = fs::symlink_metadata(path)?;
        if descriptor.dev() != named.dev()
            || descriptor.ino() != named.ino()
            || descriptor.len() > maximum
        {
            return Err(ControllerError(
                "root-private state changed before bounded read".to_owned(),
            ));
        }
        let mut bytes = Vec::with_capacity(descriptor.len() as usize);
        file.take(maximum + 1).read_to_end(&mut bytes)?;
        if bytes.len() as u64 > maximum {
            return Err(ControllerError(
                "root-private state exceeds bounded read limit".to_owned(),
            ));
        }
        require_root_regular(path, 0o600)?;
        let after = fs::symlink_metadata(path)?;
        if descriptor.dev() != after.dev()
            || descriptor.ino() != after.ino()
            || descriptor.len() != after.len()
        {
            return Err(ControllerError(
                "root-private state was replaced during bounded read".to_owned(),
            ));
        }
        String::from_utf8(bytes)
            .map_err(|_| ControllerError("root-private state is not UTF-8".to_owned()))
    }

    fn root_node_identity(path: &Path) -> Result<RootNodeIdentity> {
        match fs::symlink_metadata(path) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(RootNodeIdentity {
                present: false,
                device: 0,
                inode: 0,
                mode: 0,
                kind: "absent".to_owned(),
            }),
            Err(error) => Err(error.into()),
            Ok(metadata) => {
                let file_type = metadata.file_type();
                let kind = if file_type.is_dir() {
                    "directory"
                } else if file_type.is_file() {
                    "file"
                } else if file_type.is_symlink() {
                    "symlink"
                } else {
                    "special"
                };
                Ok(RootNodeIdentity {
                    present: true,
                    device: metadata.dev(),
                    inode: metadata.ino(),
                    mode: metadata.mode(),
                    kind: kind.to_owned(),
                })
            }
        }
    }

    fn write_root_driver_state(
        layout: &RootDriverLayout,
        prior: &RootNodeIdentity,
        hold: &RootNodeIdentity,
    ) -> Result<()> {
        let mut state = root_create_new_private(&layout.state)?;
        writeln!(state, "schema=opensteamer.root-driver-transaction.v7")?;
        writeln!(state, "prior_present={}", u8::from(prior.present))?;
        writeln!(state, "prior_device={}", prior.device)?;
        writeln!(state, "prior_inode={}", prior.inode)?;
        writeln!(state, "prior_mode={}", prior.mode)?;
        writeln!(state, "prior_kind={}", prior.kind)?;
        writeln!(state, "hold_device={}", hold.device)?;
        writeln!(state, "hold_inode={}", hold.inode)?;
        writeln!(
            state,
            "hold_tree_sha256={EXPECTED_PRODUCTION_DRIVER_TREE_SHA256}"
        )?;
        writeln!(
            state,
            "package_sha256={EXPECTED_PRODUCTION_DRIVER_PACKAGE_SHA256}"
        )?;
        state.sync_all()?;
        fsync_parent(&layout.state)
    }

    fn read_root_driver_state(
        layout: &RootDriverLayout,
    ) -> Result<(RootNodeIdentity, RootNodeIdentity)> {
        let text = read_root_bounded_utf8(&layout.state, 4_096)?;
        let mut values = std::collections::BTreeMap::new();
        for line in text.lines() {
            let (key, value) = line
                .split_once('=')
                .ok_or_else(|| ControllerError("root driver state line is malformed".to_owned()))?;
            if values.insert(key, value).is_some() {
                return Err(ControllerError(
                    "root driver state contains duplicate keys".to_owned(),
                ));
            }
        }
        let exact_keys: std::collections::BTreeSet<&str> = [
            "schema",
            "prior_present",
            "prior_device",
            "prior_inode",
            "prior_mode",
            "prior_kind",
            "hold_device",
            "hold_inode",
            "hold_tree_sha256",
            "package_sha256",
        ]
        .into_iter()
        .collect();
        if values
            .keys()
            .copied()
            .collect::<std::collections::BTreeSet<_>>()
            != exact_keys
            || values.get("schema").copied() != Some("opensteamer.root-driver-transaction.v7")
            || values.get("hold_tree_sha256").copied()
                != Some(EXPECTED_PRODUCTION_DRIVER_TREE_SHA256)
            || values.get("package_sha256").copied()
                != Some(EXPECTED_PRODUCTION_DRIVER_PACKAGE_SHA256)
        {
            return Err(ControllerError(
                "root driver state schema or tree pin changed".to_owned(),
            ));
        }
        let parse_number = |key: &str| -> Result<u64> {
            values
                .get(key)
                .ok_or_else(|| ControllerError("root driver state key is absent".to_owned()))?
                .parse::<u64>()
                .map_err(|_| ControllerError("root driver state number is malformed".to_owned()))
        };
        let prior_present = match values.get("prior_present").copied() {
            Some("0") => false,
            Some("1") => true,
            _ => {
                return Err(ControllerError(
                    "root driver prior-presence field is malformed".to_owned(),
                ))
            }
        };
        let prior = RootNodeIdentity {
            present: prior_present,
            device: parse_number("prior_device")?,
            inode: parse_number("prior_inode")?,
            mode: u32::try_from(parse_number("prior_mode")?)
                .map_err(|_| ControllerError("root driver mode overflowed".to_owned()))?,
            kind: values
                .get("prior_kind")
                .ok_or_else(|| ControllerError("root driver prior kind is absent".to_owned()))?
                .to_string(),
        };
        let hold = RootNodeIdentity {
            present: true,
            device: parse_number("hold_device")?,
            inode: parse_number("hold_inode")?,
            mode: 0,
            kind: "directory".to_owned(),
        };
        Ok((prior, hold))
    }

    fn expected_driver_nodes() -> &'static [(&'static str, &'static str, u32)] {
        &[
            (".", "directory", 0o755),
            ("Contents", "directory", 0o755),
            ("Contents/Info.plist", "file", 0o644),
            ("Contents/MacOS", "directory", 0o755),
            ("Contents/MacOS/OpensteamerVirtualMicrophone", "file", 0o755),
            ("Contents/Resources", "directory", 0o755),
            ("Contents/Resources/APPLE_SAMPLE_LICENSE.txt", "file", 0o644),
            ("Contents/Resources/en.lproj", "directory", 0o755),
            (
                "Contents/Resources/en.lproj/Localizable.strings",
                "file",
                0o644,
            ),
            ("Contents/_CodeSignature", "directory", 0o755),
            ("Contents/_CodeSignature/CodeResources", "file", 0o644),
        ]
    }

    fn driver_regular_files() -> &'static [&'static str] {
        &[
            "Contents/Info.plist",
            "Contents/MacOS/OpensteamerVirtualMicrophone",
            "Contents/Resources/APPLE_SAMPLE_LICENSE.txt",
            "Contents/Resources/en.lproj/Localizable.strings",
            "Contents/_CodeSignature/CodeResources",
        ]
    }

    fn parse_installer_leaf_sha256(text: &str) -> Result<String> {
        const EXPECTED_STATUS: &str =
            "Status: signed by a developer certificate issued by Apple for distribution";
        if text.len() > 65_536 {
            return Err(ControllerError(
                "installer signature output exceeds the bounded limit".to_owned(),
            ));
        }
        let lines: Vec<&str> = text.lines().collect();
        let statuses: Vec<&str> = lines
            .iter()
            .copied()
            .map(str::trim)
            .filter(|line| line.starts_with("Status:"))
            .collect();
        if statuses.as_slice() != [EXPECTED_STATUS] {
            return Err(ControllerError(
                "installer signature status is not the exact Developer ID distribution status"
                    .to_owned(),
            ));
        }
        let leaf_indices: Vec<usize> = lines
            .iter()
            .enumerate()
            .filter_map(|(index, line)| {
                line.trim_start()
                    .starts_with("1. Developer ID Installer:")
                    .then_some(index)
            })
            .collect();
        if leaf_indices.len() != 1 {
            return Err(ControllerError(
                "installer signature does not contain exactly one Developer ID Installer leaf"
                    .to_owned(),
            ));
        }
        let leaf = leaf_indices[0];
        if !lines[leaf].contains(&format!("({EXPECTED_DRIVER_TEAM_ID})")) {
            return Err(ControllerError(
                "installer signature Team ID differs from the release pin".to_owned(),
            ));
        }
        let mut labels = Vec::new();
        for index in leaf + 1..std::cmp::min(lines.len(), leaf + 12) {
            let trimmed = lines[index].trim_start();
            if trimmed
                .split_once('.')
                .is_some_and(|(number, _)| number.bytes().all(|byte| byte.is_ascii_digit()))
            {
                break;
            }
            if lines[index].trim() == "SHA256 Fingerprint:" {
                labels.push(index);
            }
        }
        if labels.len() != 1 {
            return Err(ControllerError(
                "installer leaf SHA-256 fingerprint label is not unique".to_owned(),
            ));
        }
        let mut fingerprint = String::new();
        for line in lines
            .iter()
            .take(std::cmp::min(lines.len(), labels[0] + 6))
            .skip(labels[0] + 1)
        {
            let trimmed = line.trim_start();
            if trimmed.contains("Fingerprint:")
                || trimmed
                    .split_once('.')
                    .is_some_and(|(number, _)| number.bytes().all(|byte| byte.is_ascii_digit()))
            {
                break;
            }
            fingerprint.extend(
                line.bytes()
                    .filter(|byte| byte.is_ascii_hexdigit())
                    .map(char::from),
            );
            if fingerprint.len() >= 64 {
                break;
            }
        }
        let fingerprint = fingerprint.to_ascii_uppercase();
        if fingerprint.len() != 64 || !fingerprint.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(ControllerError(
                "installer leaf SHA-256 fingerprint is malformed".to_owned(),
            ));
        }
        Ok(fingerprint)
    }

    fn verify_root_production_package(package: &Path) -> Result<()> {
        require_root_regular(package, 0o400)?;
        if sha256(package)? != EXPECTED_PRODUCTION_DRIVER_PACKAGE_SHA256 {
            return Err(ControllerError(
                "root-owned production package hash differs from the release pin".to_owned(),
            ));
        }
        let signature = command_output(
            "/usr/sbin/pkgutil",
            &["--check-signature", path_text(package)?],
            None,
        )?;
        require_output_success(&signature, "verify root-owned production package signature")?;
        let mut signature_text =
            decode_utf8(&signature.stdout, "pkgutil signature stdout")?.to_owned();
        signature_text.push_str(decode_utf8(&signature.stderr, "pkgutil signature stderr")?);
        if parse_installer_leaf_sha256(&signature_text)?
            != EXPECTED_DEVELOPER_ID_INSTALLER_LEAF_SHA256
        {
            return Err(ControllerError(
                "root-owned package installer certificate fingerprint is not pinned".to_owned(),
            ));
        }
        let stapler = Command::new("/usr/bin/xcrun")
            .env_clear()
            .env("LC_ALL", "C")
            .env("DEVELOPER_DIR", PINNED_XCODE_DEVELOPER_DIR)
            .args(["stapler", "validate", "-v", path_text(package)?])
            .output()?;
        require_output_success(&stapler, "validate root-owned package staple")?;
        let gatekeeper = command_output(
            "/usr/sbin/spctl",
            &[
                "--assess",
                "--type",
                "install",
                "--verbose=4",
                path_text(package)?,
            ],
            None,
        )?;
        require_output_success(&gatekeeper, "assess root-owned notarized package")
    }

    fn sha256_bytes(bytes: &[u8]) -> Result<String> {
        let mut child = Command::new("/usr/bin/shasum")
            .args(["-a", "256"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;
        child
            .stdin
            .take()
            .ok_or_else(|| ControllerError("shasum stdin is unavailable".to_owned()))?
            .write_all(bytes)?;
        let output = child.wait_with_output()?;
        require_output_success(&output, "hash production driver tree manifest")?;
        let text = decode_utf8(&output.stdout, "driver tree shasum output")?;
        let hash = text
            .split_ascii_whitespace()
            .next()
            .ok_or_else(|| ControllerError("driver tree shasum output is empty".to_owned()))?;
        if hash.len() != 64
            || !hash
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err(ControllerError(
                "driver tree shasum output is malformed".to_owned(),
            ));
        }
        Ok(hash.to_owned())
    }

    fn verify_root_production_driver(bundle: &Path) -> Result<()> {
        let expected = expected_driver_nodes();
        let mut actual = Vec::new();
        fn walk(
            root: &Path,
            relative: &Path,
            output: &mut Vec<(String, String, u32)>,
        ) -> Result<()> {
            let absolute = if relative.as_os_str().is_empty() {
                root.to_path_buf()
            } else {
                root.join(relative)
            };
            let metadata = fs::symlink_metadata(&absolute)?;
            let kind = if metadata.file_type().is_dir() {
                "directory"
            } else if metadata.file_type().is_file() {
                "file"
            } else {
                "unexpected"
            };
            let display = if relative.as_os_str().is_empty() {
                ".".to_owned()
            } else {
                relative
                    .to_str()
                    .ok_or_else(|| ControllerError("driver path is not UTF-8".to_owned()))?
                    .to_owned()
            };
            output.push((
                display,
                kind.to_owned(),
                metadata.permissions().mode() & 0o777,
            ));
            if metadata.file_type().is_dir() {
                let mut children = fs::read_dir(&absolute)?
                    .map(|entry| entry.map(|entry| entry.file_name()))
                    .collect::<std::io::Result<Vec<_>>>()?;
                children.sort();
                for child in children {
                    walk(root, &relative.join(child), output)?;
                }
            }
            Ok(())
        }
        walk(bundle, Path::new(""), &mut actual)?;
        let expected_values: Vec<(String, String, u32)> = expected
            .iter()
            .map(|(path, kind, mode)| (path.to_string(), kind.to_string(), *mode))
            .collect();
        if actual != expected_values {
            return Err(ControllerError(
                "root production driver lstat manifest is not exact".to_owned(),
            ));
        }
        let mut manifest = Vec::new();
        for (path, kind, mode) in &actual {
            let type_name = if kind == "directory" {
                "Directory"
            } else {
                "Regular File"
            };
            write!(manifest, "{type_name}|{:o}|{path}\0", mode)?;
        }
        for relative in driver_regular_files() {
            let digest = sha256(&bundle.join(relative))?;
            write!(manifest, "{relative}\0{digest}\0")?;
        }
        if sha256_bytes(&manifest)? != EXPECTED_PRODUCTION_DRIVER_TREE_SHA256 {
            return Err(ControllerError(
                "root production driver tree hash differs from the release pin".to_owned(),
            ));
        }
        let executable = bundle.join("Contents/MacOS/OpensteamerVirtualMicrophone");
        if sha256(&executable)? != EXPECTED_PRODUCTION_DRIVER_EXECUTABLE_SHA256 {
            return Err(ControllerError(
                "root production driver executable hash differs from the release pin".to_owned(),
            ));
        }
        let xattrs = command_output("/usr/bin/xattr", &["-lr", path_text(bundle)?], None)?;
        require_output_success(&xattrs, "inspect root production driver xattrs")?;
        if !xattrs.stdout.is_empty() || !xattrs.stderr.is_empty() {
            return Err(ControllerError(
                "root production driver contains extended attributes".to_owned(),
            ));
        }
        let architectures =
            command_line("/usr/bin/lipo", &["-archs", path_text(&executable)?], None)?;
        let mut archs: Vec<&str> = architectures.split_ascii_whitespace().collect();
        archs.sort_unstable();
        if archs != ["arm64", "x86_64"] {
            return Err(ControllerError(
                "root production driver architecture set is not exact".to_owned(),
            ));
        }
        let signature = command_output(
            "/usr/bin/codesign",
            &[
                "--verify",
                "--strict",
                "--all-architectures",
                path_text(bundle)?,
            ],
            None,
        )?;
        require_output_success(&signature, "verify root production driver signature")?;
        for arch in ["arm64", "x86_64"] {
            let details = command_output(
                "/usr/bin/codesign",
                &["-d", "-a", arch, "--verbose=4", path_text(bundle)?],
                None,
            )?;
            require_output_success(&details, "inspect root production driver signature")?;
            let text = decode_utf8(&details.stderr, "root codesign metadata")?;
            if !text.contains(&format!("Identifier={EXPECTED_DRIVER_IDENTIFIER}\n"))
                || !text.contains(&format!("TeamIdentifier={EXPECTED_DRIVER_TEAM_ID}\n"))
                || !text.contains("Authority=Developer ID Application:")
                || !text.contains("flags=0x10000(runtime)")
                || !text.contains("Timestamp=")
                || text.contains("Timestamp=none")
            {
                return Err(ControllerError(format!(
                    "{arch} root production driver signing contract is not exact"
                )));
            }
            let entitlements = command_output(
                "/usr/bin/codesign",
                &["-d", "-a", arch, "--entitlements", ":-", path_text(bundle)?],
                None,
            )?;
            require_output_success(&entitlements, "inspect root driver entitlements")?;
            if !entitlements.stdout.is_empty() {
                return Err(ControllerError(format!(
                    "{arch} root production driver contains entitlements"
                )));
            }
        }
        Ok(())
    }

    fn prepare_root_transaction_parent() -> Result<()> {
        require_root_private_directory(Path::new(ROOT_V7_SUPPORT_DIRECTORY))?;
        match fs::symlink_metadata(ROOT_V7_TRANSACTION_PARENT) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                fs::create_dir(ROOT_V7_TRANSACTION_PARENT)?;
                fs::set_permissions(
                    ROOT_V7_TRANSACTION_PARENT,
                    fs::Permissions::from_mode(0o700),
                )?;
                fsync_parent(Path::new(ROOT_V7_TRANSACTION_PARENT))?;
            }
            Err(error) => return Err(error.into()),
            Ok(_) => {}
        }
        require_root_private_directory(Path::new(ROOT_V7_TRANSACTION_PARENT))
    }

    fn require_no_host_process_for_root_driver_mutation() -> Result<()> {
        let output = command_output("/usr/bin/pgrep", &["-x", "CaptureServer"], None)?;
        if output.status.success() || !output.stdout.is_empty() {
            return Err(ControllerError(
                "root product-driver mutation refused while CaptureServer exists".to_owned(),
            ));
        }
        if output.status.code() != Some(1) {
            return Err(command_failure("prove CaptureServer absence", &output));
        }
        Ok(())
    }

    fn require_exact_staged_driver_artifacts(
        nonce: &str,
        staged_driver: &Path,
        staged_package: &Path,
    ) -> Result<()> {
        let artifact_root = staged_driver.parent().ok_or_else(|| {
            ControllerError("staged driver has no production artifact root".to_owned())
        })?;
        let evidence = artifact_root.parent().ok_or_else(|| {
            ControllerError("staged driver has no paired-v7 evidence parent".to_owned())
        })?;
        require_descendant(Path::new(V7_UPDATE_ROOT), evidence)?;
        if artifact_root.file_name().and_then(|value| value.to_str())
            != Some("production-driver-v7")
            || staged_driver != artifact_root.join(PRODUCT_DRIVER_NAME)
            || staged_package != artifact_root.join("OpensteamerVirtualMicrophone-v7.pkg")
        {
            return Err(ControllerError(
                "root driver artifacts escaped the exact staged layout".to_owned(),
            ));
        }
        let evidence_name = evidence
            .file_name()
            .and_then(|value| value.to_str())
            .ok_or_else(|| ControllerError("paired-v7 evidence name is not UTF-8".to_owned()))?;
        if !evidence_name.starts_with("paired-v7-update-") || !evidence_name.ends_with(nonce) {
            return Err(ControllerError(
                "root driver artifact path is not bound to the transaction nonce".to_owned(),
            ));
        }
        require_directory(Path::new(V7_UPDATE_ROOT), 0o700)?;
        require_directory(evidence, 0o700)?;
        require_directory(artifact_root, 0o700)?;
        require_directory(staged_driver, 0o755)?;
        require_regular(staged_package, 0o600)
    }

    fn root_driver_prepare(nonce: &str, staged_driver: &Path, staged_package: &Path) -> Result<()> {
        verify_root_controller_identity()?;
        prepare_root_transaction_parent()?;
        require_exact_staged_driver_artifacts(nonce, staged_driver, staged_package)?;
        let layout = root_driver_layout(nonce)?;
        require_path_absent(&layout.root, "root v7 driver transaction")?;
        fs::create_dir(&layout.root)?;
        fs::set_permissions(&layout.root, fs::Permissions::from_mode(0o700))?;
        require_root_private_directory(&layout.root)?;
        let prior = root_node_identity(Path::new(PRODUCT_DRIVER_CANONICAL_PATH))?;
        let copy = command_output(
            "/usr/bin/ditto",
            &[
                "--noqtn",
                path_text(staged_driver)?,
                path_text(&layout.hold)?,
            ],
            None,
        )?;
        require_output_success(&copy, "copy exact production driver into root hold")?;
        let ownership = command_output(
            "/usr/sbin/chown",
            &["-R", "0:0", path_text(&layout.hold)?],
            None,
        )?;
        require_output_success(&ownership, "root-own production driver hold")?;
        let package_copy = command_output(
            "/usr/bin/install",
            &[
                "-o",
                "root",
                "-g",
                "wheel",
                "-m",
                "0400",
                path_text(staged_package)?,
                path_text(&layout.package)?,
            ],
            None,
        )?;
        require_output_success(&package_copy, "copy exact package into root transaction")?;
        verify_root_production_driver(&layout.hold)?;
        verify_root_production_package(&layout.package)?;
        let hold = root_node_identity(&layout.hold)?;
        if !hold.present || hold.kind != "directory" {
            return Err(ControllerError(
                "root production driver hold identity is invalid".to_owned(),
            ));
        }
        write_root_driver_state(&layout, &prior, &hold)?;
        if root_node_identity(Path::new(PRODUCT_DRIVER_CANONICAL_PATH))? != prior {
            return Err(ControllerError(
                "canonical product driver changed during read-only root preparation".to_owned(),
            ));
        }
        println!(
            "ROOT_V7_DRIVER_PREPARED root={} prior={} prior_device={} prior_inode={} hold_device={} hold_inode={}",
            layout.root.display(),
            u8::from(prior.present),
            prior.device,
            prior.inode,
            hold.device,
            hold.inode
        );
        Ok(())
    }

    fn root_driver_publish_reload(nonce: &str) -> Result<()> {
        verify_root_controller_identity()?;
        require_no_host_process_for_root_driver_mutation()?;
        let layout = root_driver_layout(nonce)?;
        require_root_private_directory(&layout.root)?;
        let (prior, hold) = read_root_driver_state(&layout)?;
        verify_root_production_driver(&layout.hold)?;
        if root_node_identity(&layout.hold)?.device != hold.device
            || root_node_identity(&layout.hold)?.inode != hold.inode
        {
            return Err(ControllerError(
                "root production driver hold was replaced after verification".to_owned(),
            ));
        }
        let canonical = Path::new(PRODUCT_DRIVER_CANONICAL_PATH);
        if root_node_identity(canonical)? != prior {
            return Err(ControllerError(
                "canonical product driver changed after the read-only pre-stop snapshot".to_owned(),
            ));
        }
        if prior.present {
            rename_exclusive(canonical, &layout.prior)?;
            fsync_parent(canonical)?;
        }
        let publication = rename_exclusive(&layout.hold, canonical);
        if let Err(error) = publication {
            if prior.present && !path_exists_without_follow(canonical)? {
                let _ = rename_exclusive(&layout.prior, canonical);
                let _ = fsync_parent(canonical);
            }
            return Err(error);
        }
        fsync_parent(canonical)?;
        if let Err(error) =
            verify_root_production_driver(canonical).and_then(|_| reload_core_audio_root())
        {
            let _ = rename_exclusive(canonical, &layout.failed);
            if prior.present {
                let _ = rename_exclusive(&layout.prior, canonical);
            }
            let _ = fsync_parent(canonical);
            let _ = reload_core_audio_root();
            return Err(ControllerError(format!(
                "root driver publication failed and immediate prior-state restoration was attempted: {error}"
            )));
        }
        println!("ROOT_V7_DRIVER_PUBLISHED root={}", layout.root.display());
        Ok(())
    }

    fn root_driver_rollback_reload(nonce: &str) -> Result<()> {
        verify_root_controller_identity()?;
        require_no_host_process_for_root_driver_mutation()?;
        let layout = root_driver_layout(nonce)?;
        require_root_private_directory(&layout.root)?;
        let (prior, hold) = read_root_driver_state(&layout)?;
        let canonical = Path::new(PRODUCT_DRIVER_CANONICAL_PATH);
        let canonical_identity = root_node_identity(canonical)?;
        let failed_identity = root_node_identity(&layout.failed)?;
        let canonical_is_new = canonical_identity.present
            && canonical_identity.device == hold.device
            && canonical_identity.inode == hold.inode;
        let failed_is_new = failed_identity.present
            && failed_identity.device == hold.device
            && failed_identity.inode == hold.inode;
        let canonical_is_prior = canonical_identity == prior;
        if canonical_is_new {
            if failed_identity.present {
                return Err(ControllerError(
                    "rollback found duplicate new-driver identities".to_owned(),
                ));
            }
            verify_root_production_driver(canonical)?;
            rename_exclusive(canonical, &layout.failed)?;
        } else if !(canonical_is_prior && failed_is_new) {
            return Err(ControllerError(
                "rollback refused an unowned or ambiguous canonical product-driver state"
                    .to_owned(),
            ));
        }
        if prior.present && !canonical_is_prior {
            let retained = root_node_identity(&layout.prior)?;
            if retained.device != prior.device || retained.inode != prior.inode {
                return Err(ControllerError(
                    "root-owned prior product-driver state was replaced".to_owned(),
                ));
            }
            rename_exclusive(&layout.prior, canonical)?;
        } else if !prior.present && path_exists_without_follow(canonical)? {
            return Err(ControllerError(
                "rollback could not prove newly added product driver absent".to_owned(),
            ));
        }
        fsync_parent(canonical)?;
        reload_core_audio_root()?;
        println!("ROOT_V7_DRIVER_ROLLED_BACK root={}", layout.root.display());
        Ok(())
    }

    fn root_driver_restore_or_abandon_existing(nonce: &str) -> Result<()> {
        verify_root_controller_identity()?;
        require_no_host_process_for_root_driver_mutation()?;
        let layout = root_driver_layout(nonce)?;
        require_root_private_directory(&layout.root)?;
        let (prior, hold) = read_root_driver_state(&layout)?;
        let canonical = root_node_identity(Path::new(PRODUCT_DRIVER_CANONICAL_PATH))?;
        let held = root_node_identity(&layout.hold)?;
        let failed = root_node_identity(&layout.failed)?;
        let abandoned = root_node_identity(&layout.abandoned)?;
        let canonical_is_hold = canonical == hold;
        let held_is_hold = held == hold;
        let failed_is_hold = failed == hold;
        let abandoned_is_hold = abandoned == hold;
        let owned_locations = [
            canonical_is_hold,
            held_is_hold,
            failed_is_hold,
            abandoned_is_hold,
        ]
        .into_iter()
        .filter(|present| *present)
        .count();
        if owned_locations != 1 {
            return Err(ControllerError(
                "existing root driver transaction has duplicate or missing new-driver identity"
                    .to_owned(),
            ));
        }

        if canonical == prior && held_is_hold {
            // Preparation never touched the canonical path. Retain the verified hold under the
            // root-owned transaction root before reloading; this is idempotently distinguishable
            // from a published-and-restored driver in `failed`.
            verify_root_production_driver(&layout.hold)?;
            rename_exclusive(&layout.hold, &layout.abandoned)?;
            fsync_parent(&layout.abandoned)?;
            reload_core_audio_root()?;
            println!(
                "ROOT_V7_DRIVER_PREPARE_ABANDONED_AND_RELOADED root={}",
                layout.root.display()
            );
            return Ok(());
        }
        if canonical == prior && abandoned_is_hold {
            verify_root_production_driver(&layout.abandoned)?;
            reload_core_audio_root()?;
            println!(
                "ROOT_V7_DRIVER_PREPARE_ALREADY_ABANDONED_AND_RELOADED root={}",
                layout.root.display()
            );
            return Ok(());
        }

        // Published, publication-failure-restored, and already-rolled-back layouts are handled
        // by the exact inode-bound idempotent rollback implementation.
        root_driver_rollback_reload(nonce)
    }

    fn root_driver_verify_existing_restore_ready(nonce: &str) -> Result<()> {
        verify_root_controller_identity()?;
        let layout = root_driver_layout(nonce)?;
        require_root_private_directory(&layout.root)?;
        let (prior, hold) = read_root_driver_state(&layout)?;
        let locations = [
            Path::new(PRODUCT_DRIVER_CANONICAL_PATH),
            layout.hold.as_path(),
            layout.failed.as_path(),
            layout.abandoned.as_path(),
        ];
        let mut hold_location = None;
        for location in locations {
            if root_node_identity(location)? == hold {
                if hold_location.is_some() {
                    return Err(ControllerError(
                        "root restore preflight found a duplicated new-driver inode".to_owned(),
                    ));
                }
                hold_location = Some(location);
            }
        }
        let hold_location = hold_location.ok_or_else(|| {
            ControllerError(
                "root restore preflight cannot locate the exact new-driver inode".to_owned(),
            )
        })?;
        verify_root_production_driver(hold_location)?;
        verify_root_production_package(&layout.package)?;

        let canonical = root_node_identity(Path::new(PRODUCT_DRIVER_CANONICAL_PATH))?;
        if canonical != prior && canonical != hold {
            return Err(ControllerError(
                "root restore preflight found an unowned canonical product driver".to_owned(),
            ));
        }
        if canonical == hold && prior.present {
            let retained = root_node_identity(&layout.prior)?;
            if retained != prior {
                return Err(ControllerError(
                    "root restore preflight found replaced retained prior driver state".to_owned(),
                ));
            }
        }
        println!(
            "ROOT_V7_DRIVER_RESTORE_READY root={}",
            layout.root.display()
        );
        Ok(())
    }

    fn root_driver_restore_broker(nonce: &str) -> Result<()> {
        root_driver_verify_existing_restore_ready(nonce)?;
        println!("ROOT_V7_RESTORE_BROKER_READY nonce={nonce}");
        std::io::stdout().flush()?;
        let commands =
            spawn_bounded_line_reader(std::io::stdin(), 128, "root restore broker command");
        loop {
            let command = match commands
                .recv_timeout(Duration::from_secs(ROOT_BROKER_DEADMAN_SECONDS))
            {
                Ok(Ok(command)) => command,
                Ok(Err(error)) => return Err(ControllerError(error)),
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    return Err(ControllerError(
                        "root restore broker deadman expired before a terminal command".to_owned(),
                    ))
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    return Err(ControllerError(
                        "root restore broker command pipe closed before a terminal command"
                            .to_owned(),
                    ))
                }
            };
            match command.as_str() {
                "PING" => println!("ROOT_V7_RESTORE_BROKER_PONG nonce={nonce}"),
                "RESTORE" => {
                    root_driver_restore_or_abandon_existing(nonce)?;
                    println!("ROOT_V7_RESTORE_BROKER_RESTORED nonce={nonce}");
                    std::io::stdout().flush()?;
                    return Ok(());
                }
                "ABORT" => {
                    root_driver_verify_existing_restore_ready(nonce)?;
                    println!("ROOT_V7_RESTORE_BROKER_ABORTED nonce={nonce}");
                    std::io::stdout().flush()?;
                    return Ok(());
                }
                _ => {
                    return Err(ControllerError(
                        "root restore broker rejected an unreviewed command".to_owned(),
                    ))
                }
            }
            std::io::stdout().flush()?;
        }
    }

    fn root_driver_abandon_prepare(nonce: &str) -> Result<()> {
        verify_root_controller_identity()?;
        let layout = root_driver_layout(nonce)?;
        require_root_private_directory(&layout.root)?;
        let (prior, hold) = read_root_driver_state(&layout)?;
        if root_node_identity(Path::new(PRODUCT_DRIVER_CANONICAL_PATH))? != prior {
            return Err(ControllerError(
                "pre-stop cleanup refused because canonical product driver changed".to_owned(),
            ));
        }
        let current_hold = root_node_identity(&layout.hold)?;
        if current_hold.device != hold.device || current_hold.inode != hold.inode {
            return Err(ControllerError(
                "pre-stop cleanup found a replaced root-owned driver hold".to_owned(),
            ));
        }
        rename_exclusive(&layout.hold, &layout.abandoned)?;
        fsync_parent(&layout.abandoned)?;
        println!(
            "ROOT_V7_DRIVER_PREPARE_ABANDONED root={}",
            layout.root.display()
        );
        Ok(())
    }

    fn root_driver_verify_commit_ready(nonce: &str) -> Result<()> {
        verify_root_controller_identity()?;
        let layout = root_driver_layout(nonce)?;
        require_root_private_directory(&layout.root)?;
        let (prior, hold) = read_root_driver_state(&layout)?;
        let canonical = root_node_identity(Path::new(PRODUCT_DRIVER_CANONICAL_PATH))?;
        if !canonical.present || canonical.device != hold.device || canonical.inode != hold.inode {
            return Err(ControllerError(
                "root broker commit found a replaced canonical product driver".to_owned(),
            ));
        }
        verify_root_production_driver(Path::new(PRODUCT_DRIVER_CANONICAL_PATH))?;
        verify_root_production_package(&layout.package)?;
        if prior.present {
            let retained = root_node_identity(&layout.prior)?;
            if retained.device != prior.device || retained.inode != prior.inode {
                return Err(ControllerError(
                    "root broker commit found replaced prior driver state".to_owned(),
                ));
            }
        }
        println!("ROOT_V7_DRIVER_COMMIT_READY root={}", layout.root.display());
        Ok(())
    }

    fn root_broker_cleanup_after_failure(nonce: &str, published: bool) -> Result<()> {
        if published {
            return root_driver_rollback_reload(nonce);
        }
        match root_driver_abandon_prepare(nonce) {
            Ok(()) => Ok(()),
            Err(abandon) => match root_driver_rollback_reload(nonce) {
                Ok(()) => Ok(()),
                Err(rollback) => Err(ControllerError(format!(
                    "root broker could neither abandon preparation ({abandon}) nor restore the product driver ({rollback})"
                ))),
            },
        }
    }

    fn root_driver_broker(nonce: &str, staged_driver: &Path, staged_package: &Path) -> Result<()> {
        verify_root_controller_identity()?;
        root_driver_prepare(nonce, staged_driver, staged_package)?;
        println!("ROOT_V7_BROKER_READY nonce={nonce}");
        std::io::stdout().flush()?;

        let (sender, receiver) = mpsc::channel::<std::result::Result<String, String>>();
        thread::spawn(move || {
            let stdin = std::io::stdin();
            let mut reader = BufReader::new(stdin.lock());
            loop {
                let mut bytes = Vec::new();
                let read = match Read::by_ref(&mut reader)
                    .take(130)
                    .read_until(b'\n', &mut bytes)
                {
                    Ok(read) => read,
                    Err(error) => {
                        let _ = sender.send(Err(format!("broker stdin read failed: {error}")));
                        return;
                    }
                };
                if read == 0 {
                    return;
                }
                if bytes.len() > 128 || !bytes.ends_with(b"\n") {
                    let _ = sender.send(Err("broker command exceeded its bound".to_owned()));
                    return;
                }
                bytes.pop();
                if bytes.ends_with(b"\r") {
                    bytes.pop();
                }
                match String::from_utf8(bytes) {
                    Ok(command) => {
                        if sender.send(Ok(command)).is_err() {
                            return;
                        }
                    }
                    Err(_) => {
                        let _ = sender.send(Err("broker command is not UTF-8".to_owned()));
                        return;
                    }
                }
            }
        });

        let mut published = false;
        let mut commit_ready = false;
        loop {
            let command = match receiver
                .recv_timeout(Duration::from_secs(ROOT_BROKER_DEADMAN_SECONDS))
            {
                Ok(Ok(command)) => command,
                Ok(Err(error)) => {
                    root_broker_cleanup_after_failure(nonce, published)?;
                    return Err(ControllerError(error));
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    root_broker_cleanup_after_failure(nonce, published)?;
                    return Err(ControllerError(
                        "root broker deadman expired; automatic product-driver restoration completed"
                            .to_owned(),
                    ));
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    root_broker_cleanup_after_failure(nonce, published)?;
                    return Err(ControllerError(
                        "root broker parent pipe closed; automatic product-driver restoration completed"
                            .to_owned(),
                    ));
                }
            };
            match (published, commit_ready, command.as_str()) {
                (_, _, "PING") => println!("ROOT_V7_BROKER_PONG nonce={nonce}"),
                (false, false, "PUBLISH") => {
                    if let Err(error) = root_driver_publish_reload(nonce) {
                        root_broker_cleanup_after_failure(nonce, false)?;
                        return Err(error);
                    }
                    published = true;
                    println!("ROOT_V7_BROKER_PUBLISHED nonce={nonce}");
                }
                (false, false, "ABANDON") => {
                    root_driver_abandon_prepare(nonce)?;
                    println!("ROOT_V7_BROKER_ABANDONED nonce={nonce}");
                    std::io::stdout().flush()?;
                    return Ok(());
                }
                (true, _, "ROLLBACK") => {
                    root_driver_rollback_reload(nonce)?;
                    println!("ROOT_V7_BROKER_ROLLED_BACK nonce={nonce}");
                    std::io::stdout().flush()?;
                    return Ok(());
                }
                (true, false, "PREPARE_COMMIT") => {
                    root_driver_verify_commit_ready(nonce)?;
                    commit_ready = true;
                    println!("ROOT_V7_BROKER_COMMIT_READY nonce={nonce}");
                }
                (true, true, "COMMIT") => {
                    root_driver_verify_commit_ready(nonce)?;
                    println!("ROOT_V7_BROKER_COMMITTED nonce={nonce}");
                    std::io::stdout().flush()?;
                    return Ok(());
                }
                _ => {
                    root_broker_cleanup_after_failure(nonce, published)?;
                    return Err(ControllerError(
                        "root broker rejected an out-of-sequence command and restored its safe state"
                            .to_owned(),
                    ));
                }
            }
            std::io::stdout().flush()?;
        }
    }

    fn reload_core_audio_root() -> Result<()> {
        let output = command_output(
            "/bin/launchctl",
            &["kickstart", "-k", "system/com.apple.audio.coreaudiod"],
            None,
        )?;
        require_output_success(
            &output,
            "reload Core Audio after exact product-driver mutation",
        )?;
        let deadline = Instant::now() + Duration::from_secs(15);
        while Instant::now() < deadline {
            let probe = command_output("/usr/bin/pgrep", &["-x", "coreaudiod"], None)?;
            if probe.status.success() && !probe.stdout.is_empty() {
                return Ok(());
            }
            thread::sleep(Duration::from_millis(50));
        }
        Err(ControllerError(
            "coreaudiod did not return before the bounded reload deadline".to_owned(),
        ))
    }

    fn require_fixed_system_binary(path: &Path, expected_mode: u32) -> Result<()> {
        let metadata = fs::symlink_metadata(path)?;
        if !metadata.file_type().is_file()
            || metadata.file_type().is_symlink()
            || metadata.uid() != 0
            || metadata.gid() != 0
            || metadata.nlink() == 0
            || metadata.permissions().mode() & 0o777 != expected_mode
        {
            return Err(ControllerError(format!(
                "fixed system binary metadata is unsafe: {}",
                path.display()
            )));
        }
        Ok(())
    }

    #[derive(Clone, Copy, PartialEq, Eq)]
    struct DataVolumeMountIdentity {
        device: u64,
        inode: u64,
        mode: u32,
        links: u64,
        uid: u32,
        gid: u32,
        length: u64,
        flags: u32,
    }

    fn data_volume_mount_identity() -> Result<DataVolumeMountIdentity> {
        let mount = Path::new(PINNED_DATA_VOLUME_MOUNT);
        let metadata = fs::symlink_metadata(mount)?;
        if !metadata.file_type().is_dir()
            || metadata.file_type().is_symlink()
            || metadata.uid() != 0
            || metadata.gid() != 80
            || metadata.permissions().mode() & 0o7777 != 0o775
            || metadata.st_flags() != 0
            || metadata.dev() == 0
            || fs::canonicalize(mount)? != mount
        {
            return Err(ControllerError(
                "canonical APFS Data volume mount is unavailable or unsafe".to_owned(),
            ));
        }
        Ok(DataVolumeMountIdentity {
            device: metadata.dev(),
            inode: metadata.ino(),
            mode: metadata.mode(),
            links: metadata.nlink(),
            uid: metadata.uid(),
            gid: metadata.gid(),
            length: metadata.len(),
            flags: metadata.st_flags(),
        })
    }

    fn plist_value_after_unique_key<'a>(plist: &'a str, key: &str) -> Result<&'a str> {
        let marker = format!("<key>{key}</key>");
        let mut occurrences = plist.match_indices(&marker);
        let (offset, _) = occurrences.next().ok_or_else(|| {
            ControllerError(format!("Data volume plist is missing {key}"))
        })?;
        if occurrences.next().is_some() {
            return Err(ControllerError(format!(
                "Data volume plist repeats {key}"
            )));
        }
        Ok(plist[offset + marker.len()..]
            .trim_start_matches(|character: char| matches!(character, ' ' | '\t' | '\n')))
    }

    fn exact_plist_string<'a>(plist: &'a str, key: &str) -> Result<&'a str> {
        let value_and_tail = plist_value_after_unique_key(plist, key)?
            .strip_prefix("<string>")
            .ok_or_else(|| ControllerError(format!("Data volume plist {key} is not a string")))?;
        let end = value_and_tail.find("</string>").ok_or_else(|| {
            ControllerError(format!("Data volume plist {key} string is unterminated"))
        })?;
        let value = &value_and_tail[..end];
        if value.is_empty() || value.bytes().any(|byte| matches!(byte, b'<' | b'>' | b'&')) {
            return Err(ControllerError(format!(
                "Data volume plist {key} string is unsafe"
            )));
        }
        Ok(value)
    }

    fn exact_plist_boolean(plist: &str, key: &str) -> Result<bool> {
        let value = plist_value_after_unique_key(plist, key)?;
        if value.starts_with("<true/>") {
            Ok(true)
        } else if value.starts_with("<false/>") {
            Ok(false)
        } else {
            Err(ControllerError(format!(
                "Data volume plist {key} is not a Boolean"
            )))
        }
    }

    fn validate_data_volume_plist(plist: &str) -> Result<()> {
        for (key, expected) in [
            ("VolumeUUID", EXPECTED_DATA_VOLUME_UUID),
            ("APFSVolumeGroupID", EXPECTED_DATA_VOLUME_GROUP_UUID),
            ("MountPoint", PINNED_DATA_VOLUME_MOUNT),
            ("FilesystemType", "apfs"),
        ] {
            if exact_plist_string(plist, key)? != expected {
                return Err(ControllerError(format!(
                    "canonical APFS Data volume {key} changed"
                )));
            }
        }
        if !exact_plist_boolean(plist, "Internal")? {
            return Err(ControllerError(
                "canonical APFS Data volume Internal is not true".to_owned(),
            ));
        }
        if !exact_plist_boolean(plist, "Writable")? {
            return Err(ControllerError(
                "canonical APFS Data volume Writable is not true".to_owned(),
            ));
        }
        Ok(())
    }

    fn verified_data_volume_device() -> Result<u64> {
        let diskutil = Path::new(PINNED_DATA_VOLUME_DISKUTIL);
        require_fixed_system_binary(diskutil, 0o755)?;
        if sha256(diskutil)? != EXPECTED_DATA_VOLUME_DISKUTIL_SHA256 {
            return Err(ControllerError(
                "pinned APFS Data volume observer bytes changed".to_owned(),
            ));
        }

        let mount_before = data_volume_mount_identity()?;
        let volume = Command::new(PINNED_DATA_VOLUME_DISKUTIL)
            .args(["info", "-plist", PINNED_DATA_VOLUME_MOUNT])
            .env_clear()
            .env("LC_ALL", "C")
            .env("HOME", USER_HOME)
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .output()?;
        require_output_success(&volume, "inspect the canonical APFS Data volume")?;
        if volume.stdout.len() < 256
            || volume.stdout.len() > 131_072
            || !volume.stderr.is_empty()
            || volume.stdout.contains(&0)
            || volume.stdout.contains(&b'\r')
        {
            return Err(ControllerError(
                "canonical APFS Data volume plist is not exact and bounded".to_owned(),
            ));
        }
        let mount_after = data_volume_mount_identity()?;
        if mount_after != mount_before {
            return Err(ControllerError(
                "canonical APFS Data mount changed during identity proof".to_owned(),
            ));
        }
        validate_data_volume_plist(decode_utf8(
            &volume.stdout,
            "canonical APFS Data volume plist",
        )?)?;
        Ok(mount_before.device)
    }

    fn sudo_output(arguments: &[&str]) -> Result<Output> {
        command_output("/usr/bin/sudo", arguments, None)
    }

    fn authenticate_v7_privileged_boundary() -> Result<()> {
        require_fixed_system_binary(Path::new("/usr/bin/sudo"), 0o511)?;
        let status = Command::new("/usr/bin/sudo")
            .arg("-v")
            .env("LC_ALL", "C")
            .stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            .status()?;
        require_success(
            status,
            "authenticate the narrowly scoped v7 privileged driver boundary",
        )
    }

    fn require_descriptor_close_on_exec(file: &File, label: &str) -> Result<()> {
        // SAFETY: F_GETFD only inspects the live descriptor and has no pointer argument.
        let flags = unsafe { fcntl(file.as_raw_fd(), F_GETFD) };
        if flags < 0 {
            return Err(ControllerError(format!(
                "cannot inspect {label} close-on-exec flag: {}",
                std::io::Error::last_os_error()
            )));
        }
        if flags & FD_CLOEXEC == 0 {
            return Err(ControllerError(format!(
                "{label} is inheritable; detached crash recovery would retain its lock"
            )));
        }
        Ok(())
    }

    fn sudo_stat(path: &Path) -> Result<Option<String>> {
        let output = sudo_output(&[
            "-n",
            "/usr/bin/stat",
            "-f",
            "%u:%g:%l:%Lp:%HT",
            path_text(path)?,
        ])?;
        if output.status.success() {
            let value = decode_utf8(&output.stdout, "privileged stat output")?
                .strip_suffix('\n')
                .ok_or_else(|| {
                    ControllerError("privileged stat output is not newline-terminated".to_owned())
                })?;
            if value.is_empty() || value.contains('\n') {
                return Err(ControllerError(
                    "privileged stat output is malformed".to_owned(),
                ));
            }
            return Ok(Some(value.to_owned()));
        }
        if output.status.code() == Some(1) {
            return Ok(None);
        }
        Err(command_failure("inspect privileged v7 path", &output))
    }

    fn sudo_root_sealed_file(path: &Path, maximum: u64) -> Result<String> {
        let stat_arguments = [
            "-n",
            "/usr/bin/stat",
            "-f",
            "%u:%g:%l:%Lp:%HT:%d:%i:%z",
            path_text(path)?,
        ];
        let read_identity = || -> Result<String> {
            let output = sudo_output(&stat_arguments)?;
            require_output_success(&output, "inspect root-sealed controller record")?;
            let line = decode_utf8(&output.stdout, "root-sealed controller stat output")?
                .strip_suffix('\n')
                .ok_or_else(|| {
                    ControllerError(
                        "root-sealed controller stat output is not newline-terminated".to_owned(),
                    )
                })?
                .to_owned();
            let fields: Vec<&str> = line.split(':').collect();
            if fields.len() != 8
                || fields[0] != "0"
                || fields[1] != "0"
                || fields[2] != "1"
                || fields[3] != "400"
                || fields[4] != "Regular File"
            {
                return Err(ControllerError(format!(
                    "root-sealed controller record metadata is unsafe: {}",
                    path.display()
                )));
            }
            let device = fields[5].parse::<u64>().map_err(|_| {
                ControllerError("root-sealed controller record device is malformed".to_owned())
            })?;
            let inode = fields[6].parse::<u64>().map_err(|_| {
                ControllerError("root-sealed controller record inode is malformed".to_owned())
            })?;
            let length = fields[7].parse::<u64>().map_err(|_| {
                ControllerError("root-sealed controller record length is malformed".to_owned())
            })?;
            if device == 0 || inode == 0 || length == 0 || length > maximum {
                return Err(ControllerError(
                    "root-sealed controller record has impossible bounded identity".to_owned(),
                ));
            }
            Ok(line)
        };
        let before = read_identity()?;
        let output = sudo_output(&["-n", "/bin/cat", path_text(path)?])?;
        require_output_success(&output, "read root-sealed controller record")?;
        if !output.stderr.is_empty() || output.stdout.len() as u64 > maximum {
            return Err(ControllerError(
                "root-sealed controller record read was not bounded and quiet".to_owned(),
            ));
        }
        let after = read_identity()?;
        if before != after {
            return Err(ControllerError(
                "root-sealed controller record changed during privileged read".to_owned(),
            ));
        }
        String::from_utf8(output.stdout).map_err(|_| {
            ControllerError("root-sealed controller record is not UTF-8".to_owned())
        })
    }

    fn read_root_controller_identity_records_via_sudo() -> Result<ControllerBinaryIdentity> {
        let pin = sudo_root_sealed_file(Path::new(ROOT_V7_CONTROLLER_PIN), 65)?;
        let digest = pin.strip_suffix('\n').ok_or_else(|| {
            ControllerError("root controller digest pin is not newline-terminated".to_owned())
        })?;
        require_canonical_lower_hex(digest, 64, "root controller digest pin")?;
        let journal = sudo_root_sealed_file(
            Path::new(ROOT_V7_CONTROLLER_IDENTITY_JOURNAL),
            1_024,
        )?;
        let identity = parse_controller_identity_journal(&journal)?;
        if identity.sha256 != digest {
            return Err(ControllerError(
                "root controller pin and identity journal disagree".to_owned(),
            ));
        }
        Ok(identity)
    }

    fn verify_uid501_controller_against_root_pin() -> Result<ControllerBinaryIdentity> {
        let actual = verified_uid501_controller_identity()?;
        let sealed = read_root_controller_identity_records_via_sudo()?;
        require_proxy_controller_identity_binding(&actual, &sealed)?;
        Ok(actual)
    }

    fn sudo_install_directory(path: &Path, mode: &str) -> Result<()> {
        let output = sudo_output(&[
            "-n",
            "/usr/bin/install",
            "-d",
            "-o",
            "root",
            "-g",
            "wheel",
            "-m",
            mode,
            path_text(path)?,
        ])?;
        require_output_success(&output, "create fixed root-owned v7 directory")
    }

    fn require_or_create_root_directory(path: &Path, mode: &str) -> Result<()> {
        match sudo_stat(path)? {
            None => sudo_install_directory(path, mode)?,
            Some(value) => {
                let fields: Vec<&str> = value.split(':').collect();
                if fields.len() != 5
                    || fields[0] != "0"
                    || fields[1] != "0"
                    || fields[3] != mode
                    || fields[4] != "Directory"
                {
                    return Err(ControllerError(format!(
                        "pre-existing privileged v7 directory is opaque or unsafe: {}",
                        path.display()
                    )));
                }
            }
        }
        let expected = format!("0:0:");
        let value = sudo_stat(path)?.ok_or_else(|| {
            ControllerError("privileged v7 directory disappeared after creation".to_owned())
        })?;
        if !value.starts_with(&expected) || !value.ends_with(&format!(":{mode}:Directory")) {
            return Err(ControllerError(
                "privileged v7 directory metadata changed after creation".to_owned(),
            ));
        }
        Ok(())
    }

    fn bootstrap_root_owned_v7_controller() -> Result<ControllerBinaryIdentity> {
        for (path, mode) in [
            ("/bin/cat", 0o755),
            ("/usr/bin/install", 0o755),
            ("/usr/bin/stat", 0o755),
            ("/usr/bin/shasum", 0o755),
        ] {
            require_fixed_system_binary(Path::new(path), mode)?;
        }
        let current = env::current_exe()?;
        let before = verified_uid501_controller_identity()?;
        let root_parent = Path::new("/Library/Application Support/opensteamer");
        require_or_create_root_directory(root_parent, "755")?;
        require_or_create_root_directory(Path::new(ROOT_V7_SUPPORT_DIRECTORY), "700")?;
        match sudo_stat(Path::new(ROOT_V7_CONTROLLER))? {
            None => {
                let output = sudo_output(&[
                    "-n",
                    "/usr/bin/install",
                    "-o",
                    "root",
                    "-g",
                    "wheel",
                    "-m",
                    "0500",
                    path_text(&current)?,
                    ROOT_V7_CONTROLLER,
                ])?;
                require_output_success(&output, "install exact root-owned v7 controller")?;
            }
            Some(value) if value == "0:0:1:500:Regular File" => {}
            Some(_) => {
                return Err(ControllerError(
                    "pre-existing root-owned v7 controller path is opaque or unsafe".to_owned(),
                ))
            }
        }
        let hash = sudo_output(&["-n", "/usr/bin/shasum", "-a", "256", ROOT_V7_CONTROLLER])?;
        require_output_success(&hash, "hash root-owned v7 controller")?;
        if parse_shasum_output(
            decode_utf8(&hash.stdout, "root controller shasum output")?,
            ROOT_V7_CONTROLLER,
        )? != before.sha256
            || sudo_stat(Path::new(ROOT_V7_CONTROLLER))?.as_deref()
                != Some("0:0:1:500:Regular File")
        {
            return Err(ControllerError(
                "root-owned v7 controller copy differs from its exact reviewed bytes or metadata"
                    .to_owned(),
            ));
        }
        let bootstrap = sudo_output(&["-n", ROOT_V7_CONTROLLER, ROOT_V7_CONTROLLER_BOOTSTRAP_MODE])?;
        require_output_success(&bootstrap, "seal root-owned v7 controller identity")?;
        if decode_utf8(&bootstrap.stdout, "root controller identity bootstrap stdout")?
            != "ROOT_V7_CONTROLLER_IDENTITY_SEALED\n"
            || !bootstrap.stderr.is_empty()
        {
            return Err(ControllerError(
                "root controller identity bootstrap omitted its exact marker".to_owned(),
            ));
        }
        let after = verified_uid501_controller_identity()?;
        if before != after {
            return Err(ControllerError(
                "running v7 controller inode or digest changed across privileged bootstrap"
                    .to_owned(),
            ));
        }
        let sealed = read_root_controller_identity_records_via_sudo()?;
        if sealed.sha256 != after.sha256 || sealed.length != after.length {
            return Err(ControllerError(
                "sealed root controller identity differs from the authenticated UID501 binary"
                    .to_owned(),
            ));
        }
        Ok(after)
    }

    fn spawn_bounded_line_reader<R: Read + Send + 'static>(
        reader: R,
        maximum: u64,
        label: &'static str,
    ) -> mpsc::Receiver<std::result::Result<String, String>> {
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || {
            let mut reader = BufReader::new(reader);
            loop {
                let mut bytes = Vec::new();
                let read = match Read::by_ref(&mut reader)
                    .take(maximum + 2)
                    .read_until(b'\n', &mut bytes)
                {
                    Ok(read) => read,
                    Err(error) => {
                        let _ = sender.send(Err(format!("{label} read failed: {error}")));
                        return;
                    }
                };
                if read == 0 {
                    return;
                }
                if bytes.len() as u64 > maximum || !bytes.ends_with(b"\n") {
                    let _ = sender.send(Err(format!("{label} line exceeded its bound")));
                    return;
                }
                bytes.pop();
                if bytes.ends_with(b"\r") {
                    bytes.pop();
                }
                match String::from_utf8(bytes) {
                    Ok(line) => {
                        if sender.send(Ok(line)).is_err() {
                            return;
                        }
                    }
                    Err(_) => {
                        let _ = sender.send(Err(format!("{label} line is not UTF-8")));
                        return;
                    }
                }
            }
        });
        receiver
    }

    fn proxy_root_request(
        root: &mut Child,
        root_stdin: &mut std::process::ChildStdin,
        root_responses: &mpsc::Receiver<std::result::Result<String, String>>,
        command: &str,
        marker: &str,
    ) -> Result<()> {
        writeln!(root_stdin, "{command}")?;
        root_stdin.flush()?;
        let deadline = Instant::now() + Duration::from_secs(70);
        while Instant::now() < deadline {
            match root_responses.recv_timeout(Duration::from_millis(100)) {
                Ok(Ok(line)) => {
                    println!("{line}");
                    std::io::stdout().flush()?;
                    if line == marker {
                        return Ok(());
                    }
                }
                Ok(Err(error)) => return Err(ControllerError(error)),
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    if let Some(status) = root.try_wait()? {
                        return Err(ControllerError(format!(
                            "root broker exited before {marker}: {status}"
                        )));
                    }
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    return Err(ControllerError(format!(
                        "root broker response pipe closed before {marker}"
                    )))
                }
            }
        }
        Err(ControllerError(format!(
            "root broker did not report {marker} before the proxy deadline"
        )))
    }

    fn proxy_wait_for_root_marker(
        root: &mut Child,
        responses: &mpsc::Receiver<std::result::Result<String, String>>,
        marker: &str,
        timeout: Duration,
    ) -> Result<()> {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            match responses.recv_timeout(Duration::from_millis(100)) {
                Ok(Ok(line)) => {
                    println!("{line}");
                    std::io::stdout().flush()?;
                    if line == marker {
                        return Ok(());
                    }
                }
                Ok(Err(error)) => return Err(ControllerError(error)),
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    if let Some(status) = root.try_wait()? {
                        return Err(ControllerError(format!(
                            "root broker exited before {marker}: {status}"
                        )));
                    }
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    return Err(ControllerError(format!(
                        "root broker response pipe closed before {marker}"
                    )))
                }
            }
        }
        Err(ControllerError(format!(
            "root broker did not report {marker} before the proxy deadline"
        )))
    }

    fn proxy_wait_for_root_exit(root: &mut Child) -> Result<()> {
        let deadline = Instant::now() + Duration::from_secs(15);
        while Instant::now() < deadline {
            if let Some(status) = root.try_wait()? {
                return require_success(status, "finish proxied root v7 broker");
            }
            thread::sleep(Duration::from_millis(25));
        }
        Err(ControllerError(
            "proxied root v7 broker did not exit after its terminal response; it was not killed"
                .to_owned(),
        ))
    }

    fn uid_proxy_journal_committed(layout: &V7Layout) -> bool {
        require_regular(&layout.journal, 0o600)
            .and_then(|_| read_bounded_utf8(&layout.journal, 1_048_576))
            .and_then(|text| parse_v7_journal(&text))
            .is_ok_and(|state| state == V7State::Committed)
    }

    fn uid_proxy_begin_driver_rollback(layout: &V7Layout) -> Result<bool> {
        let mut journal = V7Journal::open(&layout.journal)?;
        if journal.state < V7State::StopInitiated || journal.state == V7State::Committed {
            return Ok(false);
        }
        if journal.state < V7State::RollbackStarted {
            journal.record(V7State::RollbackStarted, &[])?;
        }
        Ok(journal.state == V7State::RollbackStarted)
    }

    fn uid_proxy_finish_driver_rollback(layout: &V7Layout, begun: bool) -> Result<()> {
        if !begun {
            return Ok(());
        }
        let mut journal = V7Journal::open(&layout.journal)?;
        if journal.state == V7State::RollbackStarted {
            journal.record(V7State::DriverRestored, &[])?;
        }
        if journal.state != V7State::DriverRestored {
            return Err(ControllerError(
                "UID501 crash proxy could not durably prove driver restoration order".to_owned(),
            ));
        }
        Ok(())
    }

    fn uid_proxy_cleanup(
        layout: &V7Layout,
        root: &mut Child,
        root_stdin: &mut std::process::ChildStdin,
        root_responses: &mpsc::Receiver<std::result::Result<String, String>>,
        published: bool,
        commit_ready: bool,
    ) -> Result<()> {
        let journal_committed = uid_proxy_journal_committed(layout);
        if journal_committed {
            if !published || !commit_ready {
                return Err(ControllerError(
                    "journal committed before the driver broker was commit-ready".to_owned(),
                ));
            }
            let marker = format!("ROOT_V7_BROKER_COMMITTED nonce={}", layout.nonce);
            proxy_root_request(root, root_stdin, root_responses, "COMMIT", &marker)?;
            return proxy_wait_for_root_exit(root);
        }
        let pong = format!("ROOT_V7_BROKER_PONG nonce={}", layout.nonce);
        proxy_root_request(root, root_stdin, root_responses, "PING", &pong)?;
        let terminal = if published {
            bootout_paired_v7_job_if_loaded(layout)?;
            wait_for_no_capture_servers(Duration::from_secs(30))?;
            let marker = format!("ROOT_V7_BROKER_ROLLED_BACK nonce={}", layout.nonce);
            proxy_root_request(root, root_stdin, root_responses, "ROLLBACK", &marker)?;
            marker
        } else {
            let marker = format!("ROOT_V7_BROKER_ABANDONED nonce={}", layout.nonce);
            proxy_root_request(root, root_stdin, root_responses, "ABANDON", &marker)?;
            marker
        };
        let _ = terminal;
        proxy_wait_for_root_exit(root)
    }

    fn parent_process_identity_sha256(pid: u32) -> Result<String> {
        sha256_bytes(process_start(pid)?.as_bytes())
    }

    fn require_exact_broker_parent(parent_pid: u32, expected_start_sha256: &str) -> Result<()> {
        require_canonical_lower_hex(expected_start_sha256, 64, "v7 broker parent start SHA-256")?;
        let actual = parent_process_identity_sha256(parent_pid)?;
        if actual != expected_start_sha256 {
            return Err(ControllerError(
                "UID501 broker proxy parent generation differs from its launch binding".to_owned(),
            ));
        }
        Ok(())
    }

    fn exact_broker_parent_is_alive(parent_pid: u32, expected_start_sha256: &str) -> bool {
        parent_process_identity_sha256(parent_pid)
            .is_ok_and(|actual| actual == expected_start_sha256)
    }

    fn acquire_crash_recovery_transaction_lock() -> Result<UpdateTransactionLock> {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut last_error = None;
        while Instant::now() < deadline {
            match acquire_update_transaction_lock_at(Path::new(V7_UPDATE_LOCK)) {
                Ok(lock) => return Ok(lock),
                Err(error) => last_error = Some(error),
            }
            thread::sleep(Duration::from_millis(25));
        }
        Err(ControllerError(format!(
            "detached UID501 crash recovery could not acquire the released transaction lock: {}",
            last_error
                .map(|error| error.to_string())
                .unwrap_or_else(|| "no lock observation".to_owned())
        )))
    }

    fn require_retry_v7_leaf_main_pid(evidence: &Path, expected_main_pid: u32) -> Result<()> {
        if expected_main_pid == 0 {
            return Err(ControllerError(
                "paired-v7 pending-pointer recovery main PID is zero".to_owned(),
            ));
        }
        let name = evidence
            .file_name()
            .and_then(|value| value.to_str())
            .ok_or_else(|| ControllerError("paired-v7 retry leaf name is not UTF-8".to_owned()))?;
        let suffix = name
            .strip_prefix("paired-v7-update-retry-2-")
            .ok_or_else(|| {
                ControllerError("paired-v7 pending recovery leaf is not retry-2".to_owned())
            })?;
        if suffix.len() <= 37 || suffix.as_bytes()[suffix.len() - 37] != b'-' {
            return Err(ControllerError(
                "paired-v7 pending recovery leaf omitted its nonce".to_owned(),
            ));
        }
        let (numeric, nonce_with_separator) = suffix.split_at(suffix.len() - 37);
        validate_v7_nonce(&nonce_with_separator[1..])?;
        let (timestamp_text, pid_text) = numeric.split_once('-').ok_or_else(|| {
            ControllerError("paired-v7 pending recovery leaf omitted timestamp or PID".to_owned())
        })?;
        let timestamp = timestamp_text.parse::<u64>().ok();
        let pid = pid_text.parse::<u32>().ok();
        let expected_path = format!("{V7_UPDATE_ROOT}/{name}");
        if timestamp.filter(|value| *value > 0).is_none()
            || timestamp.is_some_and(|value| value.to_string() != timestamp_text)
            || pid != Some(expected_main_pid)
            || pid_text != expected_main_pid.to_string()
            || evidence.to_str() != Some(expected_path.as_str())
            || evidence.parent().and_then(Path::to_str) != Some(V7_UPDATE_ROOT)
        {
            return Err(ControllerError(
                "paired-v7 pending pointer PID is not bound to its exact direct retry leaf"
                    .to_owned(),
            ));
        }
        Ok(())
    }

    fn open_exact_retry_v7_pending_pointer(
        path: &Path,
        evidence: &Path,
        expected_device: u64,
    ) -> Result<(File, fs::Metadata)> {
        let expected_bytes = format!("{}\n", evidence.display());
        let metadata_is_exact = |metadata: &fs::Metadata| {
            metadata.file_type().is_file()
                && !metadata.file_type().is_symlink()
                && metadata.uid() == USER_ID
                && metadata.gid() == RETAINED_FAILED_V7_ATTEMPT_GID
                && metadata.nlink() == 1
                && metadata.permissions().mode() & 0o7777 == 0o600
                && metadata.dev() == expected_device
                && metadata.len() == expected_bytes.len() as u64
                && metadata.st_flags() == 0
        };
        let named_before = fs::symlink_metadata(path)?;
        if !metadata_is_exact(&named_before) {
            return Err(ControllerError(format!(
                "paired-v7 recoverable pending pointer metadata is unsafe: {}",
                path.display()
            )));
        }
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(O_NOFOLLOW)
            .open(path)?;
        let descriptor_before = file.metadata()?;
        if !metadata_is_exact(&descriptor_before)
            || descriptor_before.dev() != named_before.dev()
            || descriptor_before.ino() != named_before.ino()
            || descriptor_before.len() != named_before.len()
        {
            return Err(ControllerError(
                "paired-v7 pending pointer changed before descriptor binding".to_owned(),
            ));
        }
        let mut bytes = Vec::with_capacity(expected_bytes.len());
        Read::by_ref(&mut file)
            .take(expected_bytes.len() as u64 + 1)
            .read_to_end(&mut bytes)?;
        let descriptor_after = file.metadata()?;
        let named_after = fs::symlink_metadata(path)?;
        if bytes.as_slice() != expected_bytes.as_bytes()
            || !metadata_is_exact(&descriptor_after)
            || !metadata_is_exact(&named_after)
            || descriptor_before.dev() != descriptor_after.dev()
            || descriptor_before.ino() != descriptor_after.ino()
            || descriptor_before.len() != descriptor_after.len()
            || descriptor_before.dev() != named_after.dev()
            || descriptor_before.ino() != named_after.ino()
            || descriptor_before.len() != named_after.len()
        {
            return Err(ControllerError(
                "paired-v7 recoverable pending pointer bytes or identity changed".to_owned(),
            ));
        }
        Ok((file, descriptor_before))
    }

    fn retire_exact_retry_v7_pending_pointer_after_parent_crash(
        evidence: &Path,
        expected_main_pid: u32,
    ) -> Result<()> {
        require_path_absent(
            Path::new(FIRST_ATTEMPT_V7_ACTIVE_UPDATE),
            "retained first-attempt paired-v7 pointer",
        )?;
        require_path_absent(
            Path::new(RETRY_1_V7_ACTIVE_UPDATE),
            "retained retry-1 paired-v7 pointer",
        )?;
        require_path_absent(Path::new(V7_ACTIVE_UPDATE), "retry paired-v7 pointer")?;
        let pending = PathBuf::from(format!(
            "{V7_ACTIVE_UPDATE}.pending-{expected_main_pid}"
        ));
        let pending_name = pending
            .file_name()
            .and_then(|value| value.to_str())
            .ok_or_else(|| ControllerError("paired-v7 pending pointer name is not UTF-8".to_owned()))?;
        let private_root = Path::new(PRIVATE_ROOT);
        require_directory(private_root, 0o700)?;
        let root_before = fs::symlink_metadata(private_root)?;
        let mut found_expected_pending = false;
        for entry in fs::read_dir(private_root)? {
            let entry = entry?;
            let name = entry.file_name();
            let name = name.to_str().ok_or_else(|| {
                ControllerError("private opensteamer entry name is not UTF-8".to_owned())
            })?;
            if name.starts_with(FIRST_ATTEMPT_V7_PENDING_PREFIX)
                || name.starts_with(RETRY_1_V7_PENDING_PREFIX)
                || name.starts_with(RETRY_V7_PENDING_PREFIX)
            {
                if name != pending_name || entry.path().to_str() != pending.to_str() {
                    return Err(ControllerError(format!(
                        "unexpected paired-v7 pending pointer blocks crash recovery: {name}"
                    )));
                }
                if found_expected_pending {
                    return Err(ControllerError(
                        "duplicate paired-v7 pending pointer blocks crash recovery".to_owned(),
                    ));
                }
                found_expected_pending = true;
            }
        }
        let root_after_scan = fs::symlink_metadata(private_root)?;
        if root_before.dev() != root_after_scan.dev()
            || root_before.ino() != root_after_scan.ino()
            || root_before.permissions().mode() & 0o7777 != 0o700
            || root_after_scan.permissions().mode() & 0o7777 != 0o700
        {
            return Err(ControllerError(
                "private opensteamer root changed during pending recovery scan".to_owned(),
            ));
        }
        let retired = evidence.join("retired-pending-active-pointer.txt");
        let retired_exists = path_exists_without_follow(&retired)?;
        if found_expected_pending && retired_exists {
            return Err(ControllerError(
                "paired-v7 pending and retired-pending pointers both exist".to_owned(),
            ));
        }
        if !found_expected_pending && !retired_exists {
            require_no_v7_pending_pointers()?;
            return Ok(());
        }

        require_retry_v7_leaf_main_pid(evidence, expected_main_pid)?;
        let data_volume_device = verified_data_volume_device()?;
        let source = if found_expected_pending { &pending } else { &retired };
        let (file, descriptor_before) =
            open_exact_retry_v7_pending_pointer(source, evidence, data_volume_device)?;
        if found_expected_pending {
            require_path_absent(&retired, "retired paired-v7 pending pointer")?;
            rename_exclusive(&pending, &retired)?;
            fsync_parent(&pending)?;
            fsync_parent(&retired)?;
        }
        let descriptor_after = file.metadata()?;
        let retired_after = fs::symlink_metadata(&retired)?;
        if !retired_after.file_type().is_file()
            || retired_after.file_type().is_symlink()
            || retired_after.uid() != USER_ID
            || retired_after.gid() != RETAINED_FAILED_V7_ATTEMPT_GID
            || retired_after.nlink() != 1
            || retired_after.permissions().mode() & 0o7777 != 0o600
            || retired_after.st_flags() != 0
            || descriptor_before.dev() != descriptor_after.dev()
            || descriptor_before.ino() != descriptor_after.ino()
            || descriptor_before.len() != descriptor_after.len()
            || descriptor_before.dev() != retired_after.dev()
            || descriptor_before.ino() != retired_after.ino()
            || descriptor_before.len() != retired_after.len()
        {
            return Err(ControllerError(
                "retired paired-v7 pending pointer lost its descriptor-bound identity".to_owned(),
            ));
        }
        require_path_absent(&pending, "retired paired-v7 pending pointer source")?;
        require_no_v7_pending_pointers()
    }

    fn uid_proxy_complete_host_crash_rollback(
        layout: &V7Layout,
        expected_main_pid: u32,
    ) -> Result<()> {
        verify_committed_v6_baseline()?;
        verify_isolated_pairing_items_present()?;
        verify_v5_pointer_unchanged()?;
        let active_pointer_exists = path_exists_without_follow(Path::new(V7_ACTIVE_UPDATE))?;
        let pointer_expectation = if active_pointer_exists {
            RetryV7PointerExpectation::Present
        } else {
            retire_exact_retry_v7_pending_pointer_after_parent_crash(
                &layout.evidence,
                expected_main_pid,
            )?;
            RetryV7PointerExpectation::Absent
        };

        require_current_retry_v7_layout(
            &layout.evidence,
            Some(&layout.nonce),
            pointer_expectation,
        )?;
        if pointer_expectation == RetryV7PointerExpectation::Present {
            verify_v7_active_pointer(&layout.evidence)?;
        }
        let transaction_lock = acquire_crash_recovery_transaction_lock()?;
        let mut journal = V7Journal::open(&layout.journal)?;
        if journal.state != V7State::DriverRestored {
            return Err(ControllerError(
                "detached UID501 crash recovery did not begin after driver restoration".to_owned(),
            ));
        }
        rollback_to_current_baseline(
            layout,
            &mut journal,
            &transaction_lock,
            pointer_expectation,
        )?;
        write_result(
            &layout.result,
            "rolled-back-recovered",
            Some("detached UID501 proxy recovered a main-process-group loss"),
        )?;
        if pointer_expectation == RetryV7PointerExpectation::Present {
            retire_v7_active_pointer(layout)
        } else {
            require_current_retry_v7_layout(
                &layout.evidence,
                Some(&layout.nonce),
                RetryV7PointerExpectation::Absent,
            )
        }
    }

    fn uid501_driver_broker_proxy(
        nonce: &str,
        staged_driver: &Path,
        staged_package: &Path,
        parent_pid: u32,
        parent_start_sha256: &str,
    ) -> Result<()> {
        if unsafe { geteuid() } != USER_ID {
            return Err(ControllerError(
                "v7 driver broker proxy must run as uid 501 without sudo".to_owned(),
            ));
        }
        let _controller_identity = verify_uid501_controller_against_root_pin()?;
        require_exact_broker_parent(parent_pid, parent_start_sha256)?;
        require_exact_staged_driver_artifacts(nonce, staged_driver, staged_package)?;
        let evidence = staged_driver
            .parent()
            .and_then(Path::parent)
            .ok_or_else(|| ControllerError("v7 broker proxy evidence path is absent".to_owned()))?
            .to_path_buf();
        let layout = V7Layout::new(PathBuf::from(V7_EXPECTED_REPO), evidence, nonce);
        if layout.production_driver != staged_driver
            || layout.production_driver_package != staged_package
        {
            return Err(ControllerError(
                "v7 broker proxy artifact paths escaped the exact layout".to_owned(),
            ));
        }
        let mut root = Command::new("/usr/bin/sudo")
            .args([
                "-n",
                ROOT_V7_CONTROLLER,
                "--root-driver-broker-v7",
                nonce,
                path_text(staged_driver)?,
                path_text(staged_package)?,
            ])
            .env_clear()
            .env("LC_ALL", "C")
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .process_group(0)
            .spawn()?;
        let mut root_stdin = root.stdin.take().ok_or_else(|| {
            ControllerError("proxied root broker stdin is unavailable".to_owned())
        })?;
        let root_stdout = root.stdout.take().ok_or_else(|| {
            ControllerError("proxied root broker stdout is unavailable".to_owned())
        })?;
        let root_responses = spawn_bounded_line_reader(root_stdout, 4_096, "root broker response");
        proxy_wait_for_root_marker(
            &mut root,
            &root_responses,
            &format!("ROOT_V7_BROKER_READY nonce={nonce}"),
            Duration::from_secs(90),
        )?;

        let parent_commands =
            spawn_bounded_line_reader(std::io::stdin(), 128, "broker parent command");
        let mut published = false;
        let mut commit_ready = false;
        let mut last_parent_command = Instant::now();
        loop {
            let command = match parent_commands.recv_timeout(Duration::from_millis(100)) {
                Ok(Ok(command)) => {
                    last_parent_command = Instant::now();
                    command
                }
                Ok(Err(error)) => {
                    let committed = uid_proxy_journal_committed(&layout);
                    uid_proxy_cleanup(
                        &layout,
                        &mut root,
                        &mut root_stdin,
                        &root_responses,
                        published,
                        commit_ready,
                    )?;
                    if committed {
                        return Ok(());
                    }
                    return Err(ControllerError(error));
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    let exact_parent_survives =
                        exact_broker_parent_is_alive(parent_pid, parent_start_sha256);
                    let committed = uid_proxy_journal_committed(&layout);
                    let rollback_begun = if committed {
                        Ok(false)
                    } else {
                        uid_proxy_begin_driver_rollback(&layout)
                    };
                    let cleanup = uid_proxy_cleanup(
                        &layout,
                        &mut root,
                        &mut root_stdin,
                        &root_responses,
                        published,
                        commit_ready,
                    );
                    let begun = rollback_begun?;
                    cleanup?;
                    if committed {
                        return Ok(());
                    }
                    uid_proxy_finish_driver_rollback(&layout, begun)?;
                    if begun && !exact_parent_survives {
                        uid_proxy_complete_host_crash_rollback(&layout, parent_pid)?;
                        return Ok(());
                    }
                    return Err(ControllerError(
                        "v7 broker command pipe closed while its exact parent remained live; UID501 proxy stopped the host and restored the driver"
                            .to_owned(),
                    ));
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    if last_parent_command.elapsed() < Duration::from_secs(60) {
                        continue;
                    }
                    let exact_parent_survives =
                        exact_broker_parent_is_alive(parent_pid, parent_start_sha256);
                    let committed = uid_proxy_journal_committed(&layout);
                    let rollback_begun = if committed {
                        Ok(false)
                    } else {
                        uid_proxy_begin_driver_rollback(&layout)
                    };
                    let cleanup = uid_proxy_cleanup(
                        &layout,
                        &mut root,
                        &mut root_stdin,
                        &root_responses,
                        published,
                        commit_ready,
                    );
                    let begun = rollback_begun?;
                    cleanup?;
                    if committed {
                        return Ok(());
                    }
                    uid_proxy_finish_driver_rollback(&layout, begun)?;
                    if begun && !exact_parent_survives {
                        uid_proxy_complete_host_crash_rollback(&layout, parent_pid)?;
                        return Ok(());
                    }
                    return Err(ControllerError(
                        "v7 broker parent heartbeat expired; UID501 proxy stopped the host and restored the driver"
                            .to_owned(),
                    ));
                }
            };
            let marker = match (published, commit_ready, command.as_str()) {
                (_, _, "PING") => format!("ROOT_V7_BROKER_PONG nonce={nonce}"),
                (false, false, "PUBLISH") => {
                    format!("ROOT_V7_BROKER_PUBLISHED nonce={nonce}")
                }
                (false, false, "ABANDON") => {
                    format!("ROOT_V7_BROKER_ABANDONED nonce={nonce}")
                }
                (true, _, "ROLLBACK") => {
                    format!("ROOT_V7_BROKER_ROLLED_BACK nonce={nonce}")
                }
                (true, false, "PREPARE_COMMIT") => {
                    format!("ROOT_V7_BROKER_COMMIT_READY nonce={nonce}")
                }
                (true, true, "COMMIT") => {
                    format!("ROOT_V7_BROKER_COMMITTED nonce={nonce}")
                }
                _ => {
                    uid_proxy_cleanup(
                        &layout,
                        &mut root,
                        &mut root_stdin,
                        &root_responses,
                        published,
                        commit_ready,
                    )?;
                    return Err(ControllerError(
                        "UID501 broker proxy rejected an out-of-sequence command".to_owned(),
                    ));
                }
            };
            proxy_root_request(
                &mut root,
                &mut root_stdin,
                &root_responses,
                &command,
                &marker,
            )?;
            if command == "PUBLISH" {
                published = true;
            }
            if command == "PREPARE_COMMIT" {
                commit_ready = true;
            }
            if matches!(command.as_str(), "ABANDON" | "ROLLBACK" | "COMMIT") {
                return proxy_wait_for_root_exit(&mut root);
            }
        }
    }

    fn existing_v7_layout_for_restore_proxy(
        nonce: &str,
        evidence: &Path,
        pointer_expectation: RetryV7PointerExpectation,
    ) -> Result<V7Layout> {
        if pointer_expectation == RetryV7PointerExpectation::Present {
            let active_evidence =
                read_update_pointer_at(Path::new(V7_ACTIVE_UPDATE), Path::new(V7_UPDATE_ROOT))?;
            if active_evidence.to_str() != evidence.to_str() {
                return Err(ControllerError(
                    "restore proxy evidence differs from the exact active v7 transaction"
                        .to_owned(),
                ));
            }
        }
        require_current_retry_v7_layout(
            evidence,
            Some(nonce),
            pointer_expectation,
        )?;
        let layout =
            v7_layout_from_existing(PathBuf::from(V7_EXPECTED_REPO), evidence.to_path_buf())?;
        if layout.nonce != nonce {
            return Err(ControllerError(
                "restore proxy nonce differs from the exact current v7 transaction".to_owned(),
            ));
        }
        Ok(layout)
    }

    fn uid_restore_proxy_abort(
        root: &mut Child,
        root_stdin: &mut std::process::ChildStdin,
        root_responses: &mpsc::Receiver<std::result::Result<String, String>>,
        nonce: &str,
    ) -> Result<()> {
        proxy_root_request(
            root,
            root_stdin,
            root_responses,
            "ABORT",
            &format!("ROOT_V7_RESTORE_BROKER_ABORTED nonce={nonce}"),
        )?;
        proxy_wait_for_root_exit(root)
    }

    fn uid_restore_proxy_restore(
        layout: &V7Layout,
        root: &mut Child,
        root_stdin: &mut std::process::ChildStdin,
        root_responses: &mpsc::Receiver<std::result::Result<String, String>>,
    ) -> Result<()> {
        let begun = uid_proxy_begin_driver_rollback(layout)?;
        if !begun {
            return Err(ControllerError(
                "restore proxy refused product-driver mutation without durable ROLLBACK_STARTED intent"
                    .to_owned(),
            ));
        }
        bootout_paired_v7_job_if_loaded(layout)?;
        wait_for_no_capture_servers(Duration::from_secs(30))?;
        proxy_root_request(
            root,
            root_stdin,
            root_responses,
            "RESTORE",
            &format!("ROOT_V7_RESTORE_BROKER_RESTORED nonce={}", layout.nonce),
        )?;
        proxy_wait_for_root_exit(root)?;
        uid_proxy_finish_driver_rollback(layout, begun)
    }

    fn uid501_driver_restore_proxy(
        nonce: &str,
        evidence: &Path,
        pointer_expectation: RetryV7PointerExpectation,
        parent_pid: u32,
        parent_start_sha256: &str,
    ) -> Result<()> {
        if unsafe { geteuid() } != USER_ID {
            return Err(ControllerError(
                "v7 driver restore proxy must run as uid 501 without sudo".to_owned(),
            ));
        }
        let _controller_identity = verify_uid501_controller_against_root_pin()?;
        require_exact_broker_parent(parent_pid, parent_start_sha256)?;
        let layout =
            existing_v7_layout_for_restore_proxy(nonce, evidence, pointer_expectation)?;
        let mut root = Command::new("/usr/bin/sudo")
            .args([
                "-n",
                ROOT_V7_CONTROLLER,
                "--root-driver-restore-broker-v7",
                nonce,
            ])
            .env_clear()
            .env("LC_ALL", "C")
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .process_group(0)
            .spawn()?;
        let mut root_stdin = root.stdin.take().ok_or_else(|| {
            ControllerError("restore root broker stdin is unavailable".to_owned())
        })?;
        let root_stdout = root.stdout.take().ok_or_else(|| {
            ControllerError("restore root broker stdout is unavailable".to_owned())
        })?;
        let root_responses =
            spawn_bounded_line_reader(root_stdout, 4_096, "restore root broker response");
        proxy_wait_for_root_marker(
            &mut root,
            &root_responses,
            &format!("ROOT_V7_RESTORE_BROKER_READY nonce={nonce}"),
            Duration::from_secs(90),
        )?;
        println!("UID_V7_RESTORE_PROXY_READY nonce={nonce}");
        std::io::stdout().flush()?;

        let parent_commands =
            spawn_bounded_line_reader(std::io::stdin(), 128, "restore proxy parent command");
        let mut last_parent_command = Instant::now();
        loop {
            let command = match parent_commands.recv_timeout(Duration::from_millis(100)) {
                Ok(Ok(command)) => {
                    last_parent_command = Instant::now();
                    command
                }
                Ok(Err(error)) => {
                    if uid_proxy_journal_committed(&layout) {
                        uid_restore_proxy_abort(
                            &mut root,
                            &mut root_stdin,
                            &root_responses,
                            nonce,
                        )?;
                    } else {
                        uid_restore_proxy_restore(
                            &layout,
                            &mut root,
                            &mut root_stdin,
                            &root_responses,
                        )?;
                    }
                    return Err(ControllerError(error));
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    let exact_parent_survives =
                        exact_broker_parent_is_alive(parent_pid, parent_start_sha256);
                    if uid_proxy_journal_committed(&layout) {
                        uid_restore_proxy_abort(
                            &mut root,
                            &mut root_stdin,
                            &root_responses,
                            nonce,
                        )?;
                        return Ok(());
                    }
                    uid_restore_proxy_restore(
                        &layout,
                        &mut root,
                        &mut root_stdin,
                        &root_responses,
                    )?;
                    if !exact_parent_survives {
                        uid_proxy_complete_host_crash_rollback(&layout, parent_pid)?;
                        return Ok(());
                    }
                    return Err(ControllerError(
                        "restore proxy command pipe closed while its exact parent remained live"
                            .to_owned(),
                    ));
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    if last_parent_command.elapsed() < Duration::from_secs(60) {
                        continue;
                    }
                    if uid_proxy_journal_committed(&layout) {
                        uid_restore_proxy_abort(
                            &mut root,
                            &mut root_stdin,
                            &root_responses,
                            nonce,
                        )?;
                        return Err(ControllerError(
                            "restore proxy heartbeat expired before rollback intent".to_owned(),
                        ));
                    }
                    uid_restore_proxy_restore(
                        &layout,
                        &mut root,
                        &mut root_stdin,
                        &root_responses,
                    )?;
                    return Err(ControllerError(
                        "restore proxy heartbeat expired after restoring the driver".to_owned(),
                    ));
                }
            };
            match command.as_str() {
                "PING" => {
                    proxy_root_request(
                        &mut root,
                        &mut root_stdin,
                        &root_responses,
                        "PING",
                        &format!("ROOT_V7_RESTORE_BROKER_PONG nonce={nonce}"),
                    )?;
                    println!("UID_V7_RESTORE_PROXY_PONG nonce={nonce}");
                    std::io::stdout().flush()?;
                }
                "RESTORE" => {
                    uid_restore_proxy_restore(
                        &layout,
                        &mut root,
                        &mut root_stdin,
                        &root_responses,
                    )?;
                    println!("UID_V7_RESTORE_PROXY_RESTORED nonce={nonce}");
                    std::io::stdout().flush()?;
                    return Ok(());
                }
                "ABORT" if uid_proxy_journal_committed(&layout) => {
                    uid_restore_proxy_abort(&mut root, &mut root_stdin, &root_responses, nonce)?;
                    println!("UID_V7_RESTORE_PROXY_ABORTED nonce={nonce}");
                    std::io::stdout().flush()?;
                    return Ok(());
                }
                _ => {
                    return Err(ControllerError(
                        "restore proxy rejected an out-of-sequence command".to_owned(),
                    ))
                }
            }
        }
    }

    struct RootExistingDriverRestoreClient {
        child: Child,
        stdin: Option<std::process::ChildStdin>,
        responses: mpsc::Receiver<std::result::Result<String, String>>,
        nonce: String,
        terminal: bool,
    }

    impl RootExistingDriverRestoreClient {
        fn start(
            layout: &V7Layout,
            pointer_expectation: RetryV7PointerExpectation,
        ) -> Result<Self> {
            authenticate_v7_privileged_boundary()?;
            let _controller_identity = bootstrap_root_owned_v7_controller()?;
            let current = env::current_exe()?;
            let parent_pid = std::process::id();
            let parent_start_sha256 = parent_process_identity_sha256(parent_pid)?;
            let parent_pid_text = parent_pid.to_string();
            let evidence = path_text(&layout.evidence)?;
            let pointer_expectation_token = pointer_expectation.token();
            let mut child = Command::new(&current)
                .args([
                    "--uid501-driver-restore-proxy-v7",
                    &layout.nonce,
                    evidence,
                    pointer_expectation_token,
                    &parent_pid_text,
                    &parent_start_sha256,
                ])
                .env_clear()
                .env("LC_ALL", "C")
                .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::inherit())
                .process_group(0)
                .spawn()?;
            let stdin = child
                .stdin
                .take()
                .ok_or_else(|| ControllerError("restore proxy stdin is unavailable".to_owned()))?;
            let stdout = child
                .stdout
                .take()
                .ok_or_else(|| ControllerError("restore proxy stdout is unavailable".to_owned()))?;
            let responses = spawn_bounded_line_reader(stdout, 4_096, "restore proxy response");
            let mut client = Self {
                child,
                stdin: Some(stdin),
                responses,
                nonce: layout.nonce.clone(),
                terminal: false,
            };
            client.await_marker(
                &format!("UID_V7_RESTORE_PROXY_READY nonce={}", layout.nonce),
                Duration::from_secs(90),
            )?;
            client.request(
                "PING",
                &format!("UID_V7_RESTORE_PROXY_PONG nonce={}", layout.nonce),
            )?;
            Ok(client)
        }

        fn await_marker(&mut self, marker: &str, timeout: Duration) -> Result<()> {
            let deadline = Instant::now() + timeout;
            while Instant::now() < deadline {
                match self.responses.recv_timeout(Duration::from_millis(100)) {
                    Ok(Ok(line)) if line == marker => return Ok(()),
                    Ok(Ok(_)) => {}
                    Ok(Err(error)) => return Err(ControllerError(error)),
                    Err(mpsc::RecvTimeoutError::Timeout) => {
                        if let Some(status) = self.child.try_wait()? {
                            return Err(ControllerError(format!(
                                "restore proxy exited before {marker}: {status}"
                            )));
                        }
                    }
                    Err(mpsc::RecvTimeoutError::Disconnected) => {
                        return Err(ControllerError(format!(
                            "restore proxy response pipe closed before {marker}"
                        )))
                    }
                }
            }
            Err(ControllerError(format!(
                "restore proxy did not report {marker} before its parent deadline"
            )))
        }

        fn request(&mut self, command: &str, marker: &str) -> Result<()> {
            let stdin = self.stdin.as_mut().ok_or_else(|| {
                ControllerError("restore proxy command pipe is closed".to_owned())
            })?;
            writeln!(stdin, "{command}")?;
            stdin.flush()?;
            self.await_marker(marker, Duration::from_secs(70))
        }

        fn restore(&mut self) -> Result<()> {
            let marker = format!("UID_V7_RESTORE_PROXY_RESTORED nonce={}", self.nonce);
            self.request("RESTORE", &marker)?;
            self.terminal = true;
            self.stdin.take();
            let status = self.child.wait()?;
            require_success(status, "finish detached v7 restore proxy")
        }
    }

    impl Drop for RootExistingDriverRestoreClient {
        fn drop(&mut self) {
            if !self.terminal {
                self.stdin.take();
            }
        }
    }

    struct RootDriverBrokerClient {
        child: Child,
        stdin: Option<std::process::ChildStdin>,
        responses: mpsc::Receiver<std::result::Result<String, String>>,
        record: File,
        nonce: String,
        published: bool,
        terminal: bool,
    }

    impl RootDriverBrokerClient {
        fn start(layout: &V7Layout) -> Result<Self> {
            authenticate_v7_privileged_boundary()?;
            let controller_identity = bootstrap_root_owned_v7_controller()?;
            let mut record = create_new_private(&layout.driver_transaction_record)?;
            writeln!(record, "schema=opensteamer.driver-transaction-evidence.v7")?;
            writeln!(record, "nonce={}", layout.nonce)?;
            writeln!(
                record,
                "canonical_product_driver={PRODUCT_DRIVER_CANONICAL_PATH}"
            )?;
            writeln!(
                record,
                "root_controller_sha256={}",
                controller_identity.sha256
            )?;
            record.sync_all()?;
            let current = env::current_exe()?;
            let parent_pid = std::process::id();
            let parent_start_sha256 = parent_process_identity_sha256(parent_pid)?;
            let mut child = Command::new(&current)
                .args([
                    "--uid501-driver-broker-proxy-v7",
                    &layout.nonce,
                    path_text(&layout.production_driver)?,
                    path_text(&layout.production_driver_package)?,
                    &parent_pid.to_string(),
                    &parent_start_sha256,
                ])
                .env_clear()
                .env("LC_ALL", "C")
                .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::inherit())
                .process_group(0)
                .spawn()?;
            let stdout = child.stdout.take().ok_or_else(|| {
                ControllerError("root broker stdout pipe is unavailable".to_owned())
            })?;
            let stdin = child.stdin.take().ok_or_else(|| {
                ControllerError("root broker stdin pipe is unavailable".to_owned())
            })?;
            let (sender, responses) = mpsc::channel::<std::result::Result<String, String>>();
            thread::spawn(move || {
                let mut reader = BufReader::new(stdout);
                loop {
                    let mut bytes = Vec::new();
                    let read = match Read::by_ref(&mut reader)
                        .take(4_098)
                        .read_until(b'\n', &mut bytes)
                    {
                        Ok(read) => read,
                        Err(error) => {
                            let _ = sender
                                .send(Err(format!("root broker stdout read failed: {error}")));
                            return;
                        }
                    };
                    if read == 0 {
                        return;
                    }
                    if bytes.len() > 4_096 || !bytes.ends_with(b"\n") {
                        let _ =
                            sender.send(Err("root broker response exceeded its bound".to_owned()));
                        return;
                    }
                    bytes.pop();
                    match String::from_utf8(bytes) {
                        Ok(line) => {
                            if sender.send(Ok(line)).is_err() {
                                return;
                            }
                        }
                        Err(_) => {
                            let _ =
                                sender.send(Err("root broker response is not UTF-8".to_owned()));
                            return;
                        }
                    }
                }
            });
            let mut client = Self {
                child,
                stdin: Some(stdin),
                responses,
                record,
                nonce: layout.nonce.clone(),
                published: false,
                terminal: false,
            };
            client.await_marker(
                &format!("ROOT_V7_BROKER_READY nonce={}", layout.nonce),
                Duration::from_secs(90),
            )?;
            Ok(client)
        }

        fn record_line(&mut self, direction: &str, line: &str) -> Result<()> {
            if line.is_empty()
                || line.len() > 4_096
                || !line.bytes().all(|byte| {
                    byte == b' '
                        || byte == b'='
                        || byte == b'/'
                        || byte == b'-'
                        || byte == b'.'
                        || byte == b'_'
                        || byte == b':'
                        || byte.is_ascii_alphanumeric()
                })
            {
                return Err(ControllerError(
                    "root broker evidence line is unsafe".to_owned(),
                ));
            }
            writeln!(self.record, "{direction}={line}")?;
            self.record.sync_all()?;
            Ok(())
        }

        fn await_marker(&mut self, marker: &str, timeout: Duration) -> Result<()> {
            let deadline = Instant::now() + timeout;
            while Instant::now() < deadline {
                match self.responses.recv_timeout(Duration::from_millis(100)) {
                    Ok(Ok(line)) => {
                        self.record_line("root", &line)?;
                        if line == marker {
                            return Ok(());
                        }
                    }
                    Ok(Err(error)) => return Err(ControllerError(error)),
                    Err(mpsc::RecvTimeoutError::Timeout) => {
                        if let Some(status) = self.child.try_wait()? {
                            return Err(ControllerError(format!(
                                "root broker exited before {marker}: {status}"
                            )));
                        }
                    }
                    Err(mpsc::RecvTimeoutError::Disconnected) => {
                        return Err(ControllerError(format!(
                            "root broker response pipe closed before {marker}"
                        )))
                    }
                }
            }
            Err(ControllerError(format!(
                "root broker did not report {marker} before its parent deadline"
            )))
        }

        fn request(&mut self, command: &str, marker: &str) -> Result<()> {
            if self.terminal {
                return Err(ControllerError(
                    "root broker command attempted after terminal response".to_owned(),
                ));
            }
            self.record_line("user", command)?;
            let stdin = self.stdin.as_mut().ok_or_else(|| {
                ControllerError("root broker stdin was already closed".to_owned())
            })?;
            writeln!(stdin, "{command}")?;
            stdin.flush()?;
            self.await_marker(marker, Duration::from_secs(70))
        }

        fn ping(&mut self) -> Result<()> {
            let marker = format!("ROOT_V7_BROKER_PONG nonce={}", self.nonce);
            self.request("PING", &marker)
        }

        fn publish(&mut self) -> Result<()> {
            let marker = format!("ROOT_V7_BROKER_PUBLISHED nonce={}", self.nonce);
            self.request("PUBLISH", &marker)?;
            self.published = true;
            Ok(())
        }

        fn rollback(&mut self) -> Result<()> {
            let marker = format!("ROOT_V7_BROKER_ROLLED_BACK nonce={}", self.nonce);
            self.request("ROLLBACK", &marker)?;
            self.terminal = true;
            self.stdin.take();
            self.wait_for_exit(Duration::from_secs(15))
        }

        fn abandon(&mut self) -> Result<()> {
            let marker = format!("ROOT_V7_BROKER_ABANDONED nonce={}", self.nonce);
            self.request("ABANDON", &marker)?;
            self.terminal = true;
            self.stdin.take();
            self.wait_for_exit(Duration::from_secs(15))
        }

        fn commit(&mut self) -> Result<()> {
            let marker = format!("ROOT_V7_BROKER_COMMITTED nonce={}", self.nonce);
            self.request("COMMIT", &marker)?;
            self.terminal = true;
            self.stdin.take();
            self.wait_for_exit(Duration::from_secs(15))
        }

        fn prepare_commit(&mut self) -> Result<()> {
            let marker = format!("ROOT_V7_BROKER_COMMIT_READY nonce={}", self.nonce);
            self.request("PREPARE_COMMIT", &marker)
        }

        fn restore_or_abandon(&mut self) -> Result<()> {
            if self.published {
                self.rollback()
            } else {
                self.abandon()
            }
        }

        fn require_proxy_crash_cleanup(&mut self) -> Result<()> {
            if self.terminal {
                return Ok(());
            }
            self.record_line("user", "PARENT_PIPE_CLOSE")?;
            self.stdin.take();
            let marker = if self.published {
                format!("ROOT_V7_BROKER_ROLLED_BACK nonce={}", self.nonce)
            } else {
                format!("ROOT_V7_BROKER_ABANDONED nonce={}", self.nonce)
            };
            self.await_marker(&marker, Duration::from_secs(70))?;
            self.terminal = true;
            self.wait_for_exit(Duration::from_secs(15))
        }

        fn require_proxy_commit_from_durable_journal(&mut self) -> Result<()> {
            if self.terminal {
                return Ok(());
            }
            self.record_line("user", "PARENT_PIPE_CLOSE_AFTER_COMMIT")?;
            self.stdin.take();
            let marker = format!("ROOT_V7_BROKER_COMMITTED nonce={}", self.nonce);
            self.await_marker(&marker, Duration::from_secs(70))?;
            self.terminal = true;
            self.wait_for_exit(Duration::from_secs(15))
        }

        fn wait_for_exit(&mut self, timeout: Duration) -> Result<()> {
            let deadline = Instant::now() + timeout;
            while Instant::now() < deadline {
                if let Some(status) = self.child.try_wait()? {
                    return require_success(status, "finish root v7 broker");
                }
                thread::sleep(Duration::from_millis(25));
            }
            Err(ControllerError(
                "root v7 broker did not exit after its terminal response; it was not killed"
                    .to_owned(),
            ))
        }
    }

    impl Drop for RootDriverBrokerClient {
        fn drop(&mut self) {
            if !self.terminal {
                self.stdin.take();
            }
        }
    }

    fn verify_optimized_binary_scrub() -> Result<()> {
        const MAX_CONTROLLER_BYTES: u64 = 64 * 1_024 * 1_024;
        const FORBIDDEN_MARKER_HEX: [&str; 15] = [
            "2d2d72657365742d776f726c64776964652d70616972696e67",
            "2d2d656d69742d66726573682d776f726c64776964652d70616972696e67",
            "776169745f666f725f696e7465726163746976655f70616972696e67",
            "2d2d657865637574652d617574686f72697a65642d706f73742d7632302d686f73742d7570646174652d776974682d72657669657765642d7072656275696c74",
            "72657669657765642d7072656275696c74",
            "696e7669746174696f6e",
            "2d2d7665726966792d706f73742d7632302d686f73742d7570646174652d707265666c69676874",
            "2d2d657865637574652d617574686f72697a65642d706f73742d7632302d686f73742d757064617465",
            "2d2d726f6c6c6261636b2d617574686f72697a65642d706f73742d7632302d686f73742d757064617465",
            "2d2d73656c662d746573742d706f73742d7632302d686f73742d757064617465",
            "2d2d696e7374616c6c2d7072656275696c742d686f7374",
            "2d2d7665726966792d7061697265642d76352d686f73742d7570646174652d707265666c69676874",
            "2d2d657865637574652d617574686f72697a65642d7061697265642d76352d686f73742d757064617465",
            "2d2d726f6c6c6261636b2d617574686f72697a65642d7061697265642d76352d686f73742d757064617465",
            "2d2d73656c662d746573742d7061697265642d76352d686f73742d757064617465",
        ];

        let executable = env::current_exe().map_err(|error| {
            ControllerError(format!("cannot resolve the paired-v7 controller: {error}"))
        })?;
        let mut file = File::open(&executable).map_err(|error| {
            ControllerError(format!("cannot inspect the paired-v7 controller: {error}"))
        })?;
        let before = file.metadata()?;
        if !before.file_type().is_file()
            || before.nlink() != 1
            || before.len() == 0
            || before.len() > MAX_CONTROLLER_BYTES
        {
            return Err(ControllerError(
                "paired-v7 controller binary has unsafe metadata".to_owned(),
            ));
        }
        let mut bytes = Vec::with_capacity(before.len() as usize);
        Read::by_ref(&mut file)
            .take(MAX_CONTROLLER_BYTES + 1)
            .read_to_end(&mut bytes)?;
        let after = file.metadata()?;
        if bytes.len() as u64 != before.len()
            || after.dev() != before.dev()
            || after.ino() != before.ino()
            || after.len() != before.len()
        {
            return Err(ControllerError(
                "paired-v7 controller changed while being scrub-verified".to_owned(),
            ));
        }
        for (index, encoded) in FORBIDDEN_MARKER_HEX.iter().enumerate() {
            let marker = decode_marker_hex(encoded)?;
            if bytes
                .windows(marker.len())
                .any(|window| window == marker.as_slice())
            {
                return Err(ControllerError(format!(
                    "optimized paired-v7 controller retained forbidden legacy marker {index}"
                )));
            }
        }
        Ok(())
    }

    fn decode_marker_hex(encoded: &str) -> Result<Vec<u8>> {
        if encoded.len() % 2 != 0 {
            return Err(ControllerError(
                "paired-v7 binary scrub marker has odd length".to_owned(),
            ));
        }
        encoded
            .as_bytes()
            .chunks_exact(2)
            .map(|pair| {
                let high = decode_hex_nibble(pair[0])?;
                let low = decode_hex_nibble(pair[1])?;
                Ok((high << 4) | low)
            })
            .collect()
    }

    fn decode_hex_nibble(value: u8) -> Result<u8> {
        match value {
            b'0'..=b'9' => Ok(value - b'0'),
            b'a'..=b'f' => Ok(value - b'a' + 10),
            _ => Err(ControllerError(
                "paired-v7 binary scrub marker is not lowercase hexadecimal".to_owned(),
            )),
        }
    }

    fn require_exact_single_private_directory_child_at(
        root: &Path,
        expected_name: &str,
    ) -> Result<PathBuf> {
        if expected_name.is_empty() || expected_name.contains('/') {
            return Err(ControllerError(
                "retained paired-v7 attempt name is not one exact path component".to_owned(),
            ));
        }
        require_directory(root, 0o700)?;
        let root_before = fs::symlink_metadata(root)?;
        let mut entries = fs::read_dir(root).map_err(|error| {
            ControllerError(format!(
                "cannot enumerate paired-v7 update root {}: {error}",
                root.display()
            ))
        })?;
        let entry = entries.next().transpose()?.ok_or_else(|| {
            ControllerError("retained paired-v7 failed attempt is absent".to_owned())
        })?;
        if entries.next().transpose()?.is_some() {
            return Err(ControllerError(
                "paired-v7 update root contains an unexpected additional attempt".to_owned(),
            ));
        }
        if entry.file_name().to_str() != Some(expected_name) {
            return Err(ControllerError(
                "paired-v7 update root does not contain the exact retained failed attempt"
                    .to_owned(),
            ));
        }
        let expected = root.join(expected_name);
        if entry.path().as_os_str() != expected.as_os_str() {
            return Err(ControllerError(
                "retained paired-v7 failed attempt escaped its exact root".to_owned(),
            ));
        }
        require_directory(&expected, 0o700)?;
        let root_after = fs::symlink_metadata(root)?;
        if root_before.dev() != root_after.dev()
            || root_before.ino() != root_after.ino()
            || root_before.permissions().mode() & 0o7777 != 0o700
            || root_after.permissions().mode() & 0o7777 != 0o700
        {
            return Err(ControllerError(
                "paired-v7 update root changed during exact enumeration".to_owned(),
            ));
        }
        Ok(expected)
    }

    fn require_exact_retained_file(
        path: &Path,
        expected_device: u64,
        expected_inode: u64,
        expected_mode: u32,
        expected_length: u64,
        expected_sha256: &str,
    ) -> Result<Vec<u8>> {
        if expected_length > 16 * 1_024 * 1_024 {
            return Err(ControllerError(format!(
                "retained paired-v7 file pin exceeds its fixed read bound: {}",
                path.display()
            )));
        }
        let metadata_is_exact = |metadata: &fs::Metadata| {
            metadata.file_type().is_file()
                && !metadata.file_type().is_symlink()
                && metadata.uid() == USER_ID
                && metadata.gid() == RETAINED_FAILED_V7_ATTEMPT_GID
                && metadata.nlink() == 1
                && metadata.permissions().mode() & 0o7777 == expected_mode
                && metadata.dev() == expected_device
                && metadata.ino() == expected_inode
                && metadata.len() == expected_length
                && metadata.st_flags() == 0
        };
        let named_before = fs::symlink_metadata(path)?;
        if !metadata_is_exact(&named_before) {
            return Err(ControllerError(format!(
                "retained paired-v7 failure file metadata changed: {}",
                path.display()
            )));
        }
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(O_NOFOLLOW)
            .open(path)?;
        let descriptor_before = file.metadata()?;
        if !metadata_is_exact(&descriptor_before)
            || descriptor_before.dev() != named_before.dev()
            || descriptor_before.ino() != named_before.ino()
            || descriptor_before.len() != named_before.len()
        {
            return Err(ControllerError(format!(
                "retained paired-v7 failure file changed before its exact read: {}",
                path.display()
            )));
        }
        let mut bytes = Vec::with_capacity(expected_length as usize);
        Read::by_ref(&mut file)
            .take(expected_length + 1)
            .read_to_end(&mut bytes)?;
        let descriptor_after = file.metadata()?;
        let named_after = fs::symlink_metadata(path)?;
        if bytes.len() as u64 != expected_length
            || sha256_bytes(&bytes)? != expected_sha256
            || !metadata_is_exact(&descriptor_after)
            || !metadata_is_exact(&named_after)
            || descriptor_before.dev() != descriptor_after.dev()
            || descriptor_before.ino() != descriptor_after.ino()
            || descriptor_before.len() != descriptor_after.len()
            || descriptor_before.dev() != named_after.dev()
            || descriptor_before.ino() != named_after.ino()
            || descriptor_before.len() != named_after.len()
        {
            return Err(ControllerError(format!(
                "retained paired-v7 failure file bytes or identity changed: {}",
                path.display()
            )));
        }
        Ok(bytes)
    }

    fn require_exact_retained_failure_file(
        path: &Path,
        expected_device: u64,
        expected_inode: u64,
        expected_bytes: &str,
        expected_sha256: &str,
    ) -> Result<()> {
        let bytes = require_exact_retained_file(
            path,
            expected_device,
            expected_inode,
            0o600,
            expected_bytes.len() as u64,
            expected_sha256,
        )?;
        if bytes.as_slice() != expected_bytes.as_bytes() {
            return Err(ControllerError(format!(
                "retained paired-v7 failure file exact bytes changed: {}",
                path.display()
            )));
        }
        Ok(())
    }

    fn require_exact_retained_empty_directory(
        path: &Path,
        expected_device: u64,
        expected_inode: u64,
    ) -> Result<()> {
        let metadata_is_exact = |metadata: &fs::Metadata| {
            metadata.file_type().is_dir()
                && !metadata.file_type().is_symlink()
                && metadata.uid() == USER_ID
                && metadata.gid() == RETAINED_FAILED_V7_ATTEMPT_GID
                && metadata.nlink() == 2
                && metadata.permissions().mode() & 0o7777 == 0o700
                && metadata.dev() == expected_device
                && metadata.ino() == expected_inode
                && metadata.st_flags() == 0
        };
        let before = fs::symlink_metadata(path)?;
        if !metadata_is_exact(&before) || fs::read_dir(path)?.next().transpose()?.is_some() {
            return Err(ControllerError(format!(
                "retained paired-v7 directory is not the exact empty directory: {}",
                path.display()
            )));
        }
        let after = fs::symlink_metadata(path)?;
        if !metadata_is_exact(&after)
            || before.dev() != after.dev()
            || before.ino() != after.ino()
            || before.nlink() != after.nlink()
        {
            return Err(ControllerError(format!(
                "retained paired-v7 empty directory changed during enumeration: {}",
                path.display()
            )));
        }
        Ok(())
    }

    fn require_exact_retained_probe_directory(
        retained: &Path,
        expected_device: u64,
    ) -> Result<()> {
        const EXPECTED_NAMES: [&str; 3] = [
            "opensteamer-public-vpio-probe",
            "opensteamer-v7-default-route-guardian",
            "physical-virtual-microphone-probe",
        ];
        let probes = retained.join("probes");
        let metadata_is_exact = |metadata: &fs::Metadata| {
            metadata.file_type().is_dir()
                && !metadata.file_type().is_symlink()
                && metadata.uid() == USER_ID
                && metadata.gid() == RETAINED_FAILED_V7_ATTEMPT_GID
                && metadata.nlink() == 5
                && metadata.permissions().mode() & 0o7777 == 0o700
                && metadata.dev() == expected_device
                && metadata.ino() == RETAINED_FAILED_V7_PROBES_INODE
                && metadata.st_flags() == 0
        };
        let before = fs::symlink_metadata(&probes)?;
        if !metadata_is_exact(&before) {
            return Err(ControllerError(
                "retained paired-v7 probe directory metadata changed".to_owned(),
            ));
        }
        let mut actual = Vec::new();
        for entry in fs::read_dir(&probes)? {
            let entry = entry?;
            let name = entry.file_name();
            let name = name.to_str().ok_or_else(|| {
                ControllerError("retained paired-v7 probe name is not UTF-8".to_owned())
            })?;
            if !entry.file_type()?.is_file()
                || entry.path().to_str()
                    != probes.join(name).to_str()
            {
                return Err(ControllerError(format!(
                    "retained paired-v7 probe has unsafe type or path: {name}"
                )));
            }
            actual.push(name.to_owned());
        }
        actual.sort_unstable();
        if actual.iter().map(String::as_str).ne(EXPECTED_NAMES) {
            return Err(ControllerError(
                "retained paired-v7 probe name/type set changed".to_owned(),
            ));
        }
        require_exact_retained_file(
            &probes.join("opensteamer-public-vpio-probe"),
            expected_device,
            RETAINED_FAILED_V7_PUBLIC_PROBE_INODE,
            0o755,
            RETAINED_FAILED_V7_PUBLIC_PROBE_SIZE,
            RETAINED_FAILED_V7_PUBLIC_PROBE_SHA256,
        )?;
        require_exact_retained_file(
            &probes.join("opensteamer-v7-default-route-guardian"),
            expected_device,
            RETAINED_FAILED_V7_GUARDIAN_INODE,
            0o700,
            RETAINED_FAILED_V7_GUARDIAN_SIZE,
            RETAINED_FAILED_V7_GUARDIAN_SHA256,
        )?;
        require_exact_retained_file(
            &probes.join("physical-virtual-microphone-probe"),
            expected_device,
            RETAINED_FAILED_V7_MIRROR_PROBE_INODE,
            0o700,
            RETAINED_FAILED_V7_MIRROR_PROBE_SIZE,
            RETAINED_FAILED_V7_MIRROR_PROBE_SHA256,
        )?;
        let after = fs::symlink_metadata(&probes)?;
        if !metadata_is_exact(&after)
            || before.dev() != after.dev()
            || before.ino() != after.ino()
            || before.nlink() != after.nlink()
        {
            return Err(ControllerError(
                "retained paired-v7 probe directory changed during verification".to_owned(),
            ));
        }
        Ok(())
    }

    fn require_exact_retained_retry_1_probe_directory(
        retained: &Path,
        expected_device: u64,
    ) -> Result<()> {
        const EXPECTED_NAMES: [&str; 3] = [
            "opensteamer-public-vpio-probe",
            "opensteamer-v7-default-route-guardian",
            "physical-virtual-microphone-probe",
        ];
        let probes = retained.join("probes");
        let metadata_is_exact = |metadata: &fs::Metadata| {
            metadata.file_type().is_dir()
                && !metadata.file_type().is_symlink()
                && metadata.uid() == USER_ID
                && metadata.gid() == RETAINED_FAILED_V7_ATTEMPT_GID
                && metadata.nlink() == 5
                && metadata.permissions().mode() & 0o7777 == 0o700
                && metadata.dev() == expected_device
                && metadata.ino() == RETAINED_FAILED_V7_RETRY_1_PROBES_INODE
                && metadata.st_flags() == 0
        };
        let before = fs::symlink_metadata(&probes)?;
        if !metadata_is_exact(&before) {
            return Err(ControllerError(
                "retained paired-v7 retry-1 probe directory metadata changed".to_owned(),
            ));
        }
        let mut actual = Vec::new();
        for entry in fs::read_dir(&probes)? {
            let entry = entry?;
            let name = entry.file_name();
            let name = name.to_str().ok_or_else(|| {
                ControllerError("retained paired-v7 retry-1 probe name is not UTF-8".to_owned())
            })?;
            if !entry.file_type()?.is_file()
                || entry.path().to_str() != probes.join(name).to_str()
            {
                return Err(ControllerError(format!(
                    "retained paired-v7 retry-1 probe has unsafe type or path: {name}"
                )));
            }
            actual.push(name.to_owned());
        }
        actual.sort_unstable();
        if actual.iter().map(String::as_str).ne(EXPECTED_NAMES) {
            return Err(ControllerError(
                "retained paired-v7 retry-1 probe name/type set changed".to_owned(),
            ));
        }
        require_exact_retained_file(
            &probes.join("opensteamer-public-vpio-probe"),
            expected_device,
            RETAINED_FAILED_V7_RETRY_1_PUBLIC_PROBE_INODE,
            0o755,
            RETAINED_FAILED_V7_RETRY_1_PUBLIC_PROBE_SIZE,
            RETAINED_FAILED_V7_RETRY_1_PUBLIC_PROBE_SHA256,
        )?;
        require_exact_retained_file(
            &probes.join("opensteamer-v7-default-route-guardian"),
            expected_device,
            RETAINED_FAILED_V7_RETRY_1_GUARDIAN_INODE,
            0o755,
            RETAINED_FAILED_V7_RETRY_1_GUARDIAN_SIZE,
            RETAINED_FAILED_V7_RETRY_1_GUARDIAN_SHA256,
        )?;
        require_exact_retained_file(
            &probes.join("physical-virtual-microphone-probe"),
            expected_device,
            RETAINED_FAILED_V7_RETRY_1_MIRROR_PROBE_INODE,
            0o755,
            RETAINED_FAILED_V7_RETRY_1_MIRROR_PROBE_SIZE,
            RETAINED_FAILED_V7_RETRY_1_MIRROR_PROBE_SHA256,
        )?;
        let after = fs::symlink_metadata(&probes)?;
        if !metadata_is_exact(&after)
            || before.dev() != after.dev()
            || before.ino() != after.ino()
            || before.nlink() != after.nlink()
        {
            return Err(ControllerError(
                "retained paired-v7 retry-1 probe directory changed during verification"
                    .to_owned(),
            ));
        }
        Ok(())
    }

    fn require_no_v7_pending_pointers() -> Result<()> {
        let private_root = Path::new(PRIVATE_ROOT);
        require_directory(private_root, 0o700)?;
        let before = fs::symlink_metadata(private_root)?;
        for entry in fs::read_dir(private_root)? {
            let entry = entry?;
            let name = entry.file_name();
            let name = name.to_str().ok_or_else(|| {
                ControllerError("private opensteamer entry name is not UTF-8".to_owned())
            })?;
            if name.starts_with(FIRST_ATTEMPT_V7_PENDING_PREFIX)
                || name.starts_with(RETRY_1_V7_PENDING_PREFIX)
                || name.starts_with(RETRY_V7_PENDING_PREFIX)
            {
                return Err(ControllerError(format!(
                    "stale paired-v7 pending pointer is present: {name}"
                )));
            }
        }
        let after = fs::symlink_metadata(private_root)?;
        if before.dev() != after.dev()
            || before.ino() != after.ino()
            || before.permissions().mode() & 0o7777 != 0o700
            || after.permissions().mode() & 0o7777 != 0o700
        {
            return Err(ControllerError(
                "private opensteamer root changed during pending-pointer scan".to_owned(),
            ));
        }
        Ok(())
    }

    fn require_exact_retained_v7_top_level(retained: &Path) -> Result<()> {
        const EXPECTED: [&str; 16] = [
            "D:deployment-reference",
            "D:failed-new",
            "D:probes",
            "D:production-driver-v7",
            "D:rollback-current",
            "D:source-export",
            "D:staged-output",
            "D:swiftpm-scratch",
            "F:build.stderr",
            "F:build.stdout",
            "F:functional-inputs.txt",
            "F:install-hold-name.txt",
            "F:journal.log",
            "F:provenance.txt",
            "F:result.txt",
            "F:source.tar",
        ];
        let before = fs::symlink_metadata(retained)?;
        let mut actual = Vec::new();
        for entry in fs::read_dir(retained)? {
            let entry = entry?;
            let name = entry.file_name();
            let name = name.to_str().ok_or_else(|| {
                ControllerError("retained paired-v7 entry name is not UTF-8".to_owned())
            })?;
            let file_type = entry.file_type()?;
            let kind = if file_type.is_dir() {
                "D"
            } else if file_type.is_file() {
                "F"
            } else {
                return Err(ControllerError(format!(
                    "retained paired-v7 top-level entry has unsafe type: {name}"
                )));
            };
            actual.push(format!("{kind}:{name}"));
        }
        actual.sort_unstable();
        if actual.len() != EXPECTED.len()
            || actual
                .iter()
                .map(String::as_str)
                .ne(EXPECTED.iter().copied())
        {
            return Err(ControllerError(
                "retained paired-v7 top-level name/type set changed".to_owned(),
            ));
        }
        let after = fs::symlink_metadata(retained)?;
        if before.dev() != after.dev()
            || before.ino() != after.ino()
            || before.permissions().mode() & 0o7777 != 0o700
            || after.permissions().mode() & 0o7777 != 0o700
        {
            return Err(ControllerError(
                "retained paired-v7 attempt changed during top-level enumeration".to_owned(),
            ));
        }
        Ok(())
    }

    fn require_exact_retained_v7_evidence(expected_device: u64) -> Result<()> {
        let root = Path::new(V7_UPDATE_ROOT);
        let retained = Path::new(RETAINED_FAILED_V7_ATTEMPT);
        let root_metadata_is_exact = |metadata: &fs::Metadata| {
            metadata.file_type().is_dir()
                && !metadata.file_type().is_symlink()
                && metadata.uid() == USER_ID
                && metadata.gid() == RETAINED_FAILED_V7_ATTEMPT_GID
                && metadata.permissions().mode() & 0o7777 == 0o700
                && metadata.dev() == expected_device
                && metadata.ino() == RETAINED_FAILED_V7_ROOT_INODE
                && metadata.st_flags() == 0
        };
        let retained_metadata_is_exact = |metadata: &fs::Metadata| {
            metadata.file_type().is_dir()
                && !metadata.file_type().is_symlink()
                && metadata.uid() == USER_ID
                && metadata.gid() == RETAINED_FAILED_V7_ATTEMPT_GID
                && metadata.nlink() >= 2
                && metadata.permissions().mode() & 0o7777 == 0o700
                && metadata.dev() == expected_device
                && metadata.ino() == RETAINED_FAILED_V7_ATTEMPT_INODE
                && metadata.st_flags() == 0
        };
        if retained.to_str() != Some(RETAINED_FAILED_V7_ATTEMPT)
            || retained.parent().and_then(Path::to_str) != Some(V7_UPDATE_ROOT)
            || retained.file_name().and_then(|name| name.to_str())
                != Some(RETAINED_FAILED_V7_ATTEMPT_NAME)
        {
            return Err(ControllerError(
                "retained paired-v7 failed attempt path is not byte-exact".to_owned(),
            ));
        }
        let root_before = fs::symlink_metadata(root)?;
        let retained_before = fs::symlink_metadata(retained)?;
        if !root_metadata_is_exact(&root_before)
            || !retained_metadata_is_exact(&retained_before)
        {
            return Err(ControllerError(
                "retained paired-v7 failure evidence metadata changed".to_owned(),
            ));
        }
        require_path_absent(
            Path::new(RETAINED_FAILED_V7_INSTALL_HOLD),
            "retained first-attempt paired-v7 install hold",
        )?;
        require_path_absent(
            &retained.join("rollback-reserve.bin"),
            "retained first-attempt rollback reserve",
        )?;
        require_path_absent(
            &retained.join("driver-transaction-record.txt"),
            "retained first-attempt driver transaction record",
        )?;
        require_exact_retained_v7_top_level(retained)?;
        require_exact_retained_failure_file(
            &retained.join("result.txt"),
            expected_device,
            RETAINED_FAILED_V7_RESULT_INODE,
            RETAINED_FAILED_V7_RESULT,
            RETAINED_FAILED_V7_RESULT_SHA256,
        )?;
        require_exact_retained_failure_file(
            &retained.join("journal.log"),
            expected_device,
            RETAINED_FAILED_V7_JOURNAL_INODE,
            RETAINED_FAILED_V7_JOURNAL,
            RETAINED_FAILED_V7_JOURNAL_SHA256,
        )?;
        require_exact_retained_failure_file(
            &retained.join("provenance.txt"),
            expected_device,
            RETAINED_FAILED_V7_PROVENANCE_INODE,
            RETAINED_FAILED_V7_PROVENANCE,
            RETAINED_FAILED_V7_PROVENANCE_SHA256,
        )?;
        require_exact_retained_file(
            &retained.join("source.tar"),
            expected_device,
            RETAINED_FAILED_V7_SOURCE_TAR_INODE,
            0o600,
            RETAINED_FAILED_V7_SOURCE_TAR_SIZE,
            RETAINED_FAILED_V7_SOURCE_TAR_SHA256,
        )?;
        require_exact_retained_file(
            &retained.join("functional-inputs.txt"),
            expected_device,
            RETAINED_FAILED_V7_FUNCTIONAL_INPUTS_INODE,
            0o600,
            RETAINED_FAILED_V7_FUNCTIONAL_INPUTS_SIZE,
            RETAINED_FAILED_V7_FUNCTIONAL_INPUTS_SHA256,
        )?;
        require_exact_retained_file(
            &retained.join("install-hold-name.txt"),
            expected_device,
            RETAINED_FAILED_V7_INSTALL_HOLD_NAME_INODE,
            0o600,
            RETAINED_FAILED_V7_INSTALL_HOLD_NAME_SIZE,
            RETAINED_FAILED_V7_INSTALL_HOLD_NAME_SHA256,
        )?;
        require_exact_retained_probe_directory(retained, expected_device)?;
        require_exact_retained_empty_directory(
            &retained.join("failed-new"),
            expected_device,
            RETAINED_FAILED_V7_FAILED_NEW_INODE,
        )?;
        require_exact_retained_empty_directory(
            &retained.join("rollback-current"),
            expected_device,
            RETAINED_FAILED_V7_ROLLBACK_CURRENT_INODE,
        )?;
        require_exact_retained_v7_top_level(retained)?;
        let retained_after = fs::symlink_metadata(retained)?;
        let root_after = fs::symlink_metadata(root)?;
        if !root_metadata_is_exact(&root_after)
            || !retained_metadata_is_exact(&retained_after)
            || root_before.dev() != root_after.dev()
            || root_before.ino() != root_after.ino()
            || root_before.nlink() != root_after.nlink()
            || root_before.permissions().mode() & 0o7777
                != root_after.permissions().mode() & 0o7777
            || retained_before.dev() != retained_after.dev()
            || retained_before.ino() != retained_after.ino()
            || retained_before.nlink() != retained_after.nlink()
            || retained_before.permissions().mode() & 0o7777
                != retained_after.permissions().mode() & 0o7777
        {
            return Err(ControllerError(
                "retained paired-v7 failure evidence changed during persistent verification"
                    .to_owned(),
            ));
        }
        Ok(())
    }

    fn require_exact_retained_retry_1_v7_evidence(expected_device: u64) -> Result<()> {
        let root = Path::new(V7_UPDATE_ROOT);
        let retained = Path::new(RETAINED_FAILED_V7_RETRY_1);
        let root_metadata_is_exact = |metadata: &fs::Metadata| {
            metadata.file_type().is_dir()
                && !metadata.file_type().is_symlink()
                && metadata.uid() == USER_ID
                && metadata.gid() == RETAINED_FAILED_V7_ATTEMPT_GID
                && metadata.permissions().mode() & 0o7777 == 0o700
                && metadata.dev() == expected_device
                && metadata.ino() == RETAINED_FAILED_V7_ROOT_INODE
                && metadata.st_flags() == 0
        };
        let retained_metadata_is_exact = |metadata: &fs::Metadata| {
            metadata.file_type().is_dir()
                && !metadata.file_type().is_symlink()
                && metadata.uid() == USER_ID
                && metadata.gid() == RETAINED_FAILED_V7_ATTEMPT_GID
                && metadata.nlink() >= 2
                && metadata.permissions().mode() & 0o7777 == 0o700
                && metadata.dev() == expected_device
                && metadata.ino() == RETAINED_FAILED_V7_RETRY_1_INODE
                && metadata.st_flags() == 0
        };
        if retained.to_str() != Some(RETAINED_FAILED_V7_RETRY_1)
            || retained.parent().and_then(Path::to_str) != Some(V7_UPDATE_ROOT)
            || retained.file_name().and_then(|name| name.to_str())
                != Some(RETAINED_FAILED_V7_RETRY_1_NAME)
        {
            return Err(ControllerError(
                "retained paired-v7 retry-1 failed attempt path is not byte-exact".to_owned(),
            ));
        }
        let root_before = fs::symlink_metadata(root)?;
        let retained_before = fs::symlink_metadata(retained)?;
        if !root_metadata_is_exact(&root_before)
            || !retained_metadata_is_exact(&retained_before)
        {
            return Err(ControllerError(
                "retained paired-v7 retry-1 failure evidence metadata changed".to_owned(),
            ));
        }
        require_path_absent(
            Path::new(RETAINED_FAILED_V7_RETRY_1_INSTALL_HOLD),
            "retained retry-1 paired-v7 install hold",
        )?;
        require_path_absent(
            &retained.join("rollback-reserve.bin"),
            "retained retry-1 rollback reserve",
        )?;
        require_path_absent(
            &retained.join("driver-transaction-record.txt"),
            "retained retry-1 driver transaction record",
        )?;
        require_path_absent(
            &retained.join("retired-pending-active-pointer.txt"),
            "retained retry-1 retired pending pointer",
        )?;
        require_exact_retained_v7_top_level(retained)?;
        require_exact_retained_failure_file(
            &retained.join("result.txt"),
            expected_device,
            RETAINED_FAILED_V7_RETRY_1_RESULT_INODE,
            RETAINED_FAILED_V7_RETRY_1_RESULT,
            RETAINED_FAILED_V7_RETRY_1_RESULT_SHA256,
        )?;
        require_exact_retained_failure_file(
            &retained.join("journal.log"),
            expected_device,
            RETAINED_FAILED_V7_RETRY_1_JOURNAL_INODE,
            RETAINED_FAILED_V7_RETRY_1_JOURNAL,
            RETAINED_FAILED_V7_RETRY_1_JOURNAL_SHA256,
        )?;
        require_exact_retained_failure_file(
            &retained.join("provenance.txt"),
            expected_device,
            RETAINED_FAILED_V7_RETRY_1_PROVENANCE_INODE,
            RETAINED_FAILED_V7_RETRY_1_PROVENANCE,
            RETAINED_FAILED_V7_RETRY_1_PROVENANCE_SHA256,
        )?;
        require_exact_retained_file(
            &retained.join("source.tar"),
            expected_device,
            RETAINED_FAILED_V7_RETRY_1_SOURCE_TAR_INODE,
            0o600,
            RETAINED_FAILED_V7_RETRY_1_SOURCE_TAR_SIZE,
            RETAINED_FAILED_V7_RETRY_1_SOURCE_TAR_SHA256,
        )?;
        require_exact_retained_file(
            &retained.join("functional-inputs.txt"),
            expected_device,
            RETAINED_FAILED_V7_RETRY_1_FUNCTIONAL_INPUTS_INODE,
            0o600,
            RETAINED_FAILED_V7_RETRY_1_FUNCTIONAL_INPUTS_SIZE,
            RETAINED_FAILED_V7_RETRY_1_FUNCTIONAL_INPUTS_SHA256,
        )?;
        require_exact_retained_file(
            &retained.join("install-hold-name.txt"),
            expected_device,
            RETAINED_FAILED_V7_RETRY_1_INSTALL_HOLD_NAME_INODE,
            0o600,
            RETAINED_FAILED_V7_RETRY_1_INSTALL_HOLD_NAME_SIZE,
            RETAINED_FAILED_V7_RETRY_1_INSTALL_HOLD_NAME_SHA256,
        )?;
        require_exact_retained_retry_1_probe_directory(retained, expected_device)?;
        require_exact_retained_empty_directory(
            &retained.join("failed-new"),
            expected_device,
            RETAINED_FAILED_V7_RETRY_1_FAILED_NEW_INODE,
        )?;
        require_exact_retained_empty_directory(
            &retained.join("rollback-current"),
            expected_device,
            RETAINED_FAILED_V7_RETRY_1_ROLLBACK_CURRENT_INODE,
        )?;
        require_exact_retained_v7_top_level(retained)?;
        let retained_after = fs::symlink_metadata(retained)?;
        let root_after = fs::symlink_metadata(root)?;
        if !root_metadata_is_exact(&root_after)
            || !retained_metadata_is_exact(&retained_after)
            || root_before.dev() != root_after.dev()
            || root_before.ino() != root_after.ino()
            || root_before.nlink() != root_after.nlink()
            || root_before.permissions().mode() & 0o7777
                != root_after.permissions().mode() & 0o7777
            || retained_before.dev() != retained_after.dev()
            || retained_before.ino() != retained_after.ino()
            || retained_before.nlink() != retained_after.nlink()
            || retained_before.permissions().mode() & 0o7777
                != retained_after.permissions().mode() & 0o7777
        {
            return Err(ControllerError(
                "retained paired-v7 retry-1 failure evidence changed during persistent verification"
                    .to_owned(),
            ));
        }
        Ok(())
    }

    fn require_v7_retry_admission_ready() -> Result<()> {
        require_path_absent(
            Path::new(FIRST_ATTEMPT_V7_ACTIVE_UPDATE),
            "retained first-attempt paired-v7 pointer",
        )?;
        require_path_absent(
            Path::new(RETRY_1_V7_ACTIVE_UPDATE),
            "retained retry-1 paired-v7 pointer",
        )?;
        require_path_absent(Path::new(V7_ACTIVE_UPDATE), "retry paired-v7 pointer")?;
        require_no_v7_pending_pointers()?;
        require_path_absent(
            Path::new(RETAINED_FAILED_V7_INSTALL_HOLD),
            "retained first-attempt paired-v7 install hold",
        )?;
        require_path_absent(
            Path::new(RETAINED_FAILED_V7_RETRY_1_INSTALL_HOLD),
            "retained retry-1 paired-v7 install hold",
        )?;
        require_path_absent(
            Path::new(ROOT_V7_SUPPORT_DIRECTORY),
            "retained first-attempt root support directory",
        )?;
        require_path_absent(
            Path::new(ROOT_V7_TRANSACTION_PARENT),
            "retained first-attempt root transaction directory",
        )?;
        let data_volume_device = verified_data_volume_device()?;
        let root = Path::new(V7_UPDATE_ROOT);
        require_exact_v7_retained_pair(root)?;
        require_exact_retained_v7_evidence(data_volume_device)?;
        require_exact_retained_retry_1_v7_evidence(data_volume_device)?;
        require_exact_v7_retained_pair(root)
    }

    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    enum RetryV7PointerExpectation {
        Absent,
        Present,
    }

    impl RetryV7PointerExpectation {
        fn token(self) -> &'static str {
            match self {
                Self::Absent => "absent",
                Self::Present => "present",
            }
        }

        fn from_token(token: &str) -> Result<Self> {
            match token {
                "absent" => Ok(Self::Absent),
                "present" => Ok(Self::Present),
                _ => Err(ControllerError(
                    "v7 restore pointer expectation is not canonical".to_owned(),
                )),
            }
        }
    }

    fn require_exact_v7_root_names(root: &Path, expected_names: &[&str]) -> Result<()> {
        if root.to_str() != Some(V7_UPDATE_ROOT)
            || expected_names.is_empty()
            || expected_names
                .iter()
                .any(|name| name.is_empty() || name.contains('/'))
        {
            return Err(ControllerError(
                "paired-v7 namespace proof received a non-canonical root or child".to_owned(),
            ));
        }
        let root_before = fs::symlink_metadata(root)?;
        if !root_before.file_type().is_dir()
            || root_before.file_type().is_symlink()
            || root_before.uid() != USER_ID
            || root_before.gid() != RETAINED_FAILED_V7_ATTEMPT_GID
            || root_before.permissions().mode() & 0o7777 != 0o700
            || root_before.ino() != RETAINED_FAILED_V7_ROOT_INODE
            || root_before.st_flags() != 0
        {
            return Err(ControllerError(
                "paired-v7 namespace root metadata is unsafe".to_owned(),
            ));
        }
        let mut actual = Vec::new();
        for entry in fs::read_dir(root)? {
            let entry = entry?;
            let entry_name = entry.file_name();
            let entry_name = entry_name.to_str().ok_or_else(|| {
                ControllerError("paired-v7 retry namespace entry is not UTF-8".to_owned())
            })?;
            let expected_path = root.join(entry_name);
            if !entry.file_type()?.is_dir()
                || entry.path().to_str() != expected_path.to_str()
            {
                return Err(ControllerError(
                    "paired-v7 retry namespace contains a non-directory or non-exact child"
                        .to_owned(),
                ));
            }
            actual.push(entry_name.to_owned());
        }
        actual.sort_unstable();
        let mut expected: Vec<String> = expected_names
            .iter()
            .map(|name| (*name).to_owned())
            .collect();
        expected.sort_unstable();
        if expected.windows(2).any(|pair| pair[0] == pair[1]) || actual != expected {
            return Err(ControllerError(
                "paired-v7 retry namespace child set is not exact"
                    .to_owned(),
            ));
        }
        let root_after = fs::symlink_metadata(root)?;
        if !root_after.file_type().is_dir()
            || root_after.file_type().is_symlink()
            || root_after.uid() != USER_ID
            || root_after.gid() != RETAINED_FAILED_V7_ATTEMPT_GID
            || root_after.permissions().mode() & 0o7777 != 0o700
            || root_after.st_flags() != 0
            || root_before.dev() != root_after.dev()
            || root_before.ino() != root_after.ino()
            || root_before.nlink() != root_after.nlink()
        {
            return Err(ControllerError(
                "paired-v7 retry namespace root changed during exact enumeration".to_owned(),
            ));
        }
        Ok(())
    }

    fn require_exact_v7_retained_pair(root: &Path) -> Result<()> {
        require_exact_v7_root_names(
            root,
            &[
                RETAINED_FAILED_V7_ATTEMPT_NAME,
                RETAINED_FAILED_V7_RETRY_1_NAME,
            ],
        )
    }

    fn require_exact_v7_root_triplet(root: &Path, current_name: &str) -> Result<()> {
        require_exact_v7_root_names(
            root,
            &[
                RETAINED_FAILED_V7_ATTEMPT_NAME,
                RETAINED_FAILED_V7_RETRY_1_NAME,
                current_name,
            ],
        )
    }

    fn require_retry_v7_pointer_expectation(
        evidence: &Path,
        expectation: RetryV7PointerExpectation,
    ) -> Result<()> {
        require_path_absent(
            Path::new(FIRST_ATTEMPT_V7_ACTIVE_UPDATE),
            "retained first-attempt paired-v7 pointer",
        )?;
        require_path_absent(
            Path::new(RETRY_1_V7_ACTIVE_UPDATE),
            "retained retry-1 paired-v7 pointer",
        )?;
        require_no_v7_pending_pointers()?;
        match expectation {
            RetryV7PointerExpectation::Absent => {
                require_path_absent(Path::new(V7_ACTIVE_UPDATE), "retry paired-v7 pointer")
            }
            RetryV7PointerExpectation::Present => verify_update_pointer_at(
                Path::new(V7_ACTIVE_UPDATE),
                evidence,
                Path::new(V7_UPDATE_ROOT),
            ),
        }
    }

    fn require_current_retry_v7_layout(
        evidence: &Path,
        expected_nonce: Option<&str>,
        pointer_expectation: RetryV7PointerExpectation,
    ) -> Result<()> {
        let name = evidence
            .file_name()
            .and_then(|value| value.to_str())
            .ok_or_else(|| ControllerError("paired-v7 retry leaf name is not UTF-8".to_owned()))?;
        let suffix = name
            .strip_prefix("paired-v7-update-retry-2-")
            .ok_or_else(|| {
                ControllerError("paired-v7 retry leaf escaped its fixed retry-2 shape".to_owned())
            })?;
        if suffix.len() <= 37 || suffix.as_bytes()[suffix.len() - 37] != b'-' {
            return Err(ControllerError(
                "paired-v7 retry leaf omitted its canonical nonce".to_owned(),
            ));
        }
        let (numeric, nonce_with_separator) = suffix.split_at(suffix.len() - 37);
        let nonce = &nonce_with_separator[1..];
        validate_v7_nonce(nonce)?;
        if expected_nonce.is_some_and(|expected| expected != nonce) {
            return Err(ControllerError(
                "paired-v7 retry leaf nonce differs from its transaction binding".to_owned(),
            ));
        }
        let (timestamp_text, pid_text) = numeric.split_once('-').ok_or_else(|| {
            ControllerError("paired-v7 retry leaf omitted its timestamp or PID".to_owned())
        })?;
        let timestamp = timestamp_text.parse::<u64>().ok();
        let pid = pid_text.parse::<u32>().ok();
        if timestamp.filter(|value| *value > 0).is_none()
            || pid.filter(|value| *value > 0).is_none()
            || timestamp.is_some_and(|value| value.to_string() != timestamp_text)
            || pid.is_some_and(|value| value.to_string() != pid_text)
            || pid_text.contains('-')
        {
            return Err(ControllerError(
                "paired-v7 retry leaf timestamp or PID is not canonical".to_owned(),
            ));
        }
        let root = Path::new(V7_UPDATE_ROOT);
        let expected_evidence = root.join(name);
        if evidence.to_str() != expected_evidence.to_str()
            || evidence.parent().and_then(Path::to_str) != Some(V7_UPDATE_ROOT)
            || evidence.to_str() == Some(RETAINED_FAILED_V7_ATTEMPT)
            || evidence.to_str() == Some(RETAINED_FAILED_V7_RETRY_1)
            || name == RETAINED_FAILED_V7_ATTEMPT_NAME
            || name == RETAINED_FAILED_V7_RETRY_1_NAME
        {
            return Err(ControllerError(
                "paired-v7 retry leaf is not one exact direct non-retained child".to_owned(),
            ));
        }
        let data_volume_device = verified_data_volume_device()?;
        let root_before = fs::symlink_metadata(root)?;
        let retry_metadata = fs::symlink_metadata(evidence)?;
        if !root_before.file_type().is_dir()
            || root_before.file_type().is_symlink()
            || root_before.uid() != USER_ID
            || root_before.gid() != RETAINED_FAILED_V7_ATTEMPT_GID
            || root_before.permissions().mode() & 0o7777 != 0o700
            || root_before.dev() != data_volume_device
            || root_before.ino() != RETAINED_FAILED_V7_ROOT_INODE
            || root_before.st_flags() != 0
            || retry_metadata.file_type().is_symlink()
            || !retry_metadata.file_type().is_dir()
            || retry_metadata.uid() != USER_ID
            || retry_metadata.gid() != RETAINED_FAILED_V7_ATTEMPT_GID
            || retry_metadata.permissions().mode() & 0o7777 != 0o700
            || retry_metadata.dev() != data_volume_device
            || retry_metadata.ino() == 0
            || retry_metadata.ino() == RETAINED_FAILED_V7_ROOT_INODE
            || retry_metadata.ino() == RETAINED_FAILED_V7_ATTEMPT_INODE
            || retry_metadata.ino() == RETAINED_FAILED_V7_RETRY_1_INODE
            || retry_metadata.nlink() < 2
            || retry_metadata.st_flags() != 0
        {
            return Err(ControllerError(
                "paired-v7 current retry namespace metadata is unsafe".to_owned(),
            ));
        }
        require_exact_v7_root_triplet(root, name)?;
        require_exact_retained_v7_evidence(data_volume_device)?;
        require_exact_retained_retry_1_v7_evidence(data_volume_device)?;
        require_retry_v7_pointer_expectation(evidence, pointer_expectation)?;
        require_exact_v7_root_triplet(root, name)?;
        let root_after = fs::symlink_metadata(root)?;
        let retry_after = fs::symlink_metadata(evidence)?;
        if !root_after.file_type().is_dir()
            || root_after.file_type().is_symlink()
            || root_after.uid() != USER_ID
            || root_after.gid() != RETAINED_FAILED_V7_ATTEMPT_GID
            || root_after.permissions().mode() & 0o7777 != 0o700
            || retry_after.file_type().is_symlink()
            || !retry_after.file_type().is_dir()
            || retry_after.uid() != USER_ID
            || retry_after.gid() != RETAINED_FAILED_V7_ATTEMPT_GID
            || retry_after.permissions().mode() & 0o7777 != 0o700
            || root_before.dev() != root_after.dev()
            || root_before.ino() != root_after.ino()
            || root_before.nlink() != root_after.nlink()
            || root_before.permissions().mode() & 0o7777
                != root_after.permissions().mode() & 0o7777
            || root_before.st_flags() != root_after.st_flags()
            || retry_metadata.dev() != retry_after.dev()
            || retry_metadata.ino() != retry_after.ino()
            || retry_metadata.nlink() != retry_after.nlink()
            || retry_metadata.len() != retry_after.len()
            || retry_metadata.permissions().mode() & 0o7777
                != retry_after.permissions().mode() & 0o7777
            || retry_metadata.st_flags() != retry_after.st_flags()
        {
            return Err(ControllerError(
                "paired-v7 retry namespace was renamed or replaced during persistent proof"
                    .to_owned(),
            ));
        }
        require_retry_v7_pointer_expectation(evidence, pointer_expectation)?;
        require_exact_v7_root_triplet(root, name)?;
        Ok(())
    }

    fn execute_paired_v7_update(
        repo: PathBuf,
        authorized_commit: &str,
        authorized_tree: &str,
    ) -> Result<()> {
        require_canonical_git_oid(authorized_commit, "authorized commit")?;
        require_canonical_git_oid(authorized_tree, "authorized tree")?;
        verify_machine_contract()?;
        let provenance = verify_paired_v7_git_provenance(&repo, true)?;
        require_authorized_provenance(&provenance, authorized_commit, authorized_tree)?;
        verify_v7_production_signing_availability()?;
        let release_cycle = verify_reviewed_production_candidate_preflight(&repo, &provenance)?;
        let transaction_lock = acquire_update_transaction_lock_at(Path::new(V7_UPDATE_LOCK))?;
        require_descriptor_close_on_exec(
            &transaction_lock.file,
            "paired-v7 update transaction lock",
        )?;
        verify_committed_v6_baseline()?;
        let initial_generation = verify_paired_v7_runtime()?;
        verify_isolated_pairing_items_present()?;
        require_v7_retry_admission_ready()?;
        require_available_bytes(
            Path::new(PRIVATE_ROOT),
            2 * 1_024 * 1_024 * 1_024,
            "before creating paired-v7 update evidence",
        )?;

        let nonce = new_nonce()?;
        let evidence = PathBuf::from(V7_UPDATE_ROOT).join(format!(
            "paired-v7-update-retry-2-{}-{}-{}",
            unix_seconds()?,
            std::process::id(),
            nonce
        ));
        require_v7_retry_admission_ready()?;
        create_private_directory(&evidence)?;
        require_current_retry_v7_layout(
            &evidence,
            Some(&nonce),
            RetryV7PointerExpectation::Absent,
        )?;
        let layout = V7Layout::new(repo, evidence, &nonce);
        create_private_directory(&layout.rollback_dir)?;
        create_private_directory(&layout.failed_dir)?;
        let mut journal = V7Journal::create(&layout.journal)?;
        record_v7_install_hold_name(&layout)?;

        let result = perform_paired_v7_update(
            &layout,
            &mut journal,
            &provenance,
            &release_cycle,
            &initial_generation,
            authorized_commit,
            authorized_tree,
        );
        match result {
            Ok(()) => Ok(()),
            Err(primary) => {
                if journal.state == V7State::Committed {
                    let _ = write_result(
                        &layout.result,
                        "success-with-warning",
                        Some(&primary.to_string()),
                    );
                    eprintln!(
                        "warning: paired-v7 update committed but final reporting failed: {primary}"
                    );
                    return Ok(());
                }
                let active_pointer_exists =
                    path_exists_without_follow(Path::new(V7_ACTIVE_UPDATE))?;
                let pointer_absent_before_stop = !active_pointer_exists
                    && matches!(journal.state, V7State::StopInitiated | V7State::RolledBack);
                let crossed_stop = v7_crossed_stop_without_durable_commit(journal.state)
                    && !pointer_absent_before_stop;
                if !crossed_stop {
                    if layout.rollback_reserve.exists() {
                        let _ = release_rollback_reserve(&layout.rollback_reserve);
                    }
                    let _ = archive_v7_install_hold_root(&layout);
                    let _ = write_result(
                        &layout.result,
                        "failed-before-stop",
                        Some(&primary.to_string()),
                    );
                    return Err(primary);
                }
                let rollback_pointer_expectation = if active_pointer_exists {
                    RetryV7PointerExpectation::Present
                } else {
                    retire_exact_retry_v7_pending_pointer_after_parent_crash(
                        &layout.evidence,
                        std::process::id(),
                    )?;
                    RetryV7PointerExpectation::Absent
                };
                match rollback_to_current_baseline(
                    &layout,
                    &mut journal,
                    &transaction_lock,
                    rollback_pointer_expectation,
                ) {
                    Ok(()) => {
                        write_result(&layout.result, "rolled-back", Some(&primary.to_string()))?;
                        if rollback_pointer_expectation == RetryV7PointerExpectation::Present {
                            retire_v7_active_pointer(&layout)?;
                        } else {
                            require_current_retry_v7_layout(
                                &layout.evidence,
                                Some(&layout.nonce),
                                RetryV7PointerExpectation::Absent,
                            )?;
                        }
                        Err(ControllerError(format!(
                            "update failed and exact current isolated baseline was restored; evidence={}: {primary}",
                            layout.evidence.display()
                        )))
                    }
                    Err(rollback) => {
                        let _ = journal.record(
                            V7State::CriticalFailure,
                            &[("phase", "rollback".to_owned())],
                        );
                        let _ = write_result(
                            &layout.result,
                            "critical-failure",
                            Some(&format!("primary={primary}; rollback={rollback}")),
                        );
                        Err(ControllerError(format!(
                            "CRITICAL: paired-v7 update and rollback both failed; keep host offline; evidence={}: primary={primary}; rollback={rollback}",
                            layout.evidence.display()
                        )))
                    }
                }
            }
        }
    }

    fn perform_paired_v7_update(
        layout: &V7Layout,
        journal: &mut V7Journal,
        provenance: &Provenance,
        release_cycle: &ReleaseCycleEvidence,
        initial_generation: &LaunchGeneration,
        authorized_commit: &str,
        authorized_tree: &str,
    ) -> Result<()> {
        export_v7_source(layout, provenance, release_cycle)?;
        journal.record(
            V7State::SourceExported,
            &[
                ("commit", provenance.commit.clone()),
                ("tree", provenance.tree.clone()),
                ("initial_pid", initial_generation.pid.to_string()),
            ],
        )?;

        build_and_verify_v7_staged_app(layout)?;
        prepare_v7_deployment_reference(layout)?;
        materialize_reviewed_production_driver(layout, provenance)?;
        build_and_verify_v7_probe_binaries(layout)?;
        journal.record(
            V7State::BuildVerified,
            &[(
                "executable_sha256",
                sha256(&layout.staged_app.join("Contents/MacOS/CaptureServer"))?,
            )],
        )?;

        prepare_v7_install_hold(layout)?;
        journal.record(V7State::InstallHoldVerified, &[])?;

        require_available_bytes(
            Path::new(PRIVATE_ROOT),
            1_024 * 1_024 * 1_024,
            "after staging and immediately before stopping the current isolated host",
        )?;
        verify_v7_deployment_reference(layout)?;
        verify_isolated_pairing_items_present()?;
        verify_v5_pointer_unchanged()?;
        let revalidated = verify_paired_v7_runtime()?;
        if revalidated.pid != initial_generation.pid
            || revalidated.runs != initial_generation.runs
            || revalidated.process_start != initial_generation.process_start
            || revalidated.nonce != initial_generation.nonce
            || revalidated.lock_device != initial_generation.lock_device
            || revalidated.lock_inode != initial_generation.lock_inode
        {
            return Err(ControllerError(
                "current isolated launch generation changed during the build".to_owned(),
            ));
        }

        require_current_retry_v7_layout(
            &layout.evidence,
            Some(&layout.nonce),
            RetryV7PointerExpectation::Absent,
        )?;
        let boundary_provenance = verify_paired_v7_git_provenance(&layout.repo, true)?;
        require_authorized_provenance(&boundary_provenance, authorized_commit, authorized_tree)?;
        if boundary_provenance.commit != provenance.commit
            || boundary_provenance.tree != provenance.tree
            || boundary_provenance.upstream != provenance.upstream
            || boundary_provenance.remote != provenance.remote
        {
            return Err(ControllerError(
                "clean pushed provenance changed between evidence creation and the pre-stop gate"
                    .to_owned(),
            ));
        }
        let boundary_release_cycle =
            verify_reviewed_production_candidate_preflight(&layout.repo, &boundary_provenance)?;
        if &boundary_release_cycle != release_cycle {
            return Err(ControllerError(
                "candidate S, authorized release R, or functional-input proof changed before stop"
                    .to_owned(),
            ));
        }

        require_current_retry_v7_layout(
            &layout.evidence,
            Some(&layout.nonce),
            RetryV7PointerExpectation::Absent,
        )?;
        let mut broker = RootDriverBrokerClient::start(layout)?;
        journal.record(V7State::DriverPrepared, &[])?;

        require_current_retry_v7_layout(
            &layout.evidence,
            Some(&layout.nonce),
            RetryV7PointerExpectation::Absent,
        )?;

        verify_v7_deployment_reference(layout)?;
        verify_isolated_pairing_items_present()?;
        verify_v5_pointer_unchanged()?;
        let final_generation = verify_paired_v7_runtime()?;
        if final_generation.pid != initial_generation.pid
            || final_generation.runs != initial_generation.runs
            || final_generation.process_start != initial_generation.process_start
            || final_generation.nonce != initial_generation.nonce
            || final_generation.lock_device != initial_generation.lock_device
            || final_generation.lock_inode != initial_generation.lock_inode
        {
            return Err(ControllerError(
                "current isolated launch generation changed at the pre-stop gate".to_owned(),
            ));
        }

        require_current_retry_v7_layout(
            &layout.evidence,
            Some(&layout.nonce),
            RetryV7PointerExpectation::Absent,
        )?;
        let transaction = (|| -> Result<LaunchGeneration> {
            broker.ping()?;
            let reserve = allocate_rollback_reserve(&layout.rollback_reserve, 8 * 1_024 * 1_024)?;
            journal.record(
                V7State::StopInitiated,
                &[
                    ("reserve_device", reserve.0.to_string()),
                    ("reserve_inode", reserve.1.to_string()),
                    ("reserve_bytes", reserve.2.to_string()),
                ],
            )?;
            publish_v7_active_pointer(&layout.evidence)?;

            verify_v7_active_pointer(&layout.evidence)?;
            verify_v7_deployment_reference(layout)?;
            verify_isolated_pairing_items_present()?;
            verify_v5_pointer_unchanged()?;
            bootout_exact_new_job()?;
            wait_for_no_capture_servers(Duration::from_secs(30))?;
            require_service_absent(NEW_LAUNCH_AGENT_LABEL)?;
            verify_protected_legacy_absent()?;
            let lock = acquire_unowned_shared_lock()?;
            verify_v7_active_pointer(&layout.evidence)?;
            verify_v5_pointer_unchanged()?;
            verify_isolated_pairing_items_present()?;
            verify_v7_deployment_reference(layout)?;
            verify_current_baseline_app_at(Path::new(NEW_APP), true)?;
            journal.record(V7State::CurrentStopped, &[])?;

            rename_exclusive(Path::new(NEW_APP), &layout.rollback_app)?;
            fsync_parent(Path::new(NEW_APP))?;
            fsync_parent(&layout.rollback_app)?;
            verify_current_baseline_app_at(&layout.rollback_app, false)?;
            journal.record(V7State::CurrentHeld, &[])?;

            broker.publish()?;
            journal.record(V7State::DriverPublished, &[])?;
            run_installed_driver_probes(layout, &mut broker)?;
            journal.record(V7State::ProbesVerified, &[])?;

            rename_exclusive(&layout.install_hold, Path::new(NEW_APP))?;
            fsync_parent(&layout.install_hold)?;
            fsync_parent(Path::new(NEW_APP))?;
            fs::remove_dir(&layout.install_hold_root).map_err(|error| {
                ControllerError(format!(
                    "cannot remove empty paired-v7 install-hold root {}: {error}",
                    layout.install_hold_root.display()
                ))
            })?;
            fsync_parent(&layout.install_hold_root)?;
            verify_v7_installed_matches_reference(layout)?;
            verify_isolated_pairing_items_present()?;
            verify_v5_pointer_unchanged()?;
            journal.record(V7State::NewPublished, &[])?;
            drop(lock);

            broker.ping()?;
            let checkpoint = capture_log_checkpoint()?;
            bootstrap_exact_new_job()?;
            journal.record(V7State::PersistentBootstrapped, &[])?;
            let generation = wait_for_paired_v7_launch_generation(Duration::from_secs(45))?;
            broker.ping()?;
            verify_paired_v7_deployment(layout, &checkpoint, &generation)?;
            verify_isolated_pairing_items_present()?;
            verify_v5_pointer_unchanged()?;
            journal.record(
                V7State::ReadyVerified,
                &[
                    ("pid", generation.pid.to_string()),
                    ("runs", generation.runs.to_string()),
                    ("nonce", generation.nonce.clone()),
                ],
            )?;
            verify_protected_legacy_absent()?;
            release_rollback_reserve(&layout.rollback_reserve)?;
            Ok(generation)
        })();

        let generation = match transaction {
            Ok(generation) => generation,
            Err(primary) => {
                *journal = V7Journal::open(&layout.journal)?;
                let crossed_stop = v7_crossed_stop_without_durable_commit(journal.state);
                if crossed_stop && journal.state < V7State::RollbackStarted {
                    journal.record(V7State::RollbackStarted, &[])?;
                }
                let host_stop = if crossed_stop {
                    bootout_paired_v7_job_if_loaded(layout)
                        .and_then(|_| wait_for_no_capture_servers(Duration::from_secs(30)))
                } else {
                    Ok(())
                };
                let driver_cleanup_already_durable = matches!(
                    journal.state,
                    V7State::DriverRestored
                        | V7State::FailedNewArchived
                        | V7State::CurrentRestored
                        | V7State::CurrentBootstrapped
                        | V7State::RolledBack
                );
                let privileged_cleanup = if driver_cleanup_already_durable {
                    Ok(())
                } else if host_stop.is_ok() {
                    broker.restore_or_abandon()
                } else {
                    broker.require_proxy_crash_cleanup()
                };
                if let Err(cleanup) = privileged_cleanup {
                    return Err(ControllerError(format!(
                        "CRITICAL: paired-v7 failure could not prove product-driver restoration before host rollback: primary={primary}; host_stop={host_stop:?}; privileged_cleanup={cleanup}"
                    )));
                }
                if crossed_stop {
                    *journal = V7Journal::open(&layout.journal)?;
                    if journal.state == V7State::RollbackStarted {
                        journal.record(V7State::DriverRestored, &[])?;
                    }
                    if journal.state != V7State::DriverRestored {
                        return Err(ControllerError(
                            "product driver cleanup did not durably precede host rollback"
                                .to_owned(),
                        ));
                    }
                }
                return Err(primary);
            }
        };

        let rollback_ready_commit_failure = |primary: ControllerError,
                                             broker: &mut RootDriverBrokerClient,
                                             journal: &mut V7Journal|
         -> Result<()> {
            if journal.state < V7State::RollbackStarted {
                journal.record(V7State::RollbackStarted, &[])?;
            }
            bootout_paired_v7_job_if_loaded(layout)?;
            wait_for_no_capture_servers(Duration::from_secs(30))?;
            broker.restore_or_abandon()?;
            journal.record(V7State::DriverRestored, &[])?;
            Err(primary)
        };
        if let Err(error) = broker.prepare_commit() {
            return rollback_ready_commit_failure(error, &mut broker, journal);
        }
        if let Err(error) = require_current_retry_v7_layout(
            &layout.evidence,
            Some(&layout.nonce),
            RetryV7PointerExpectation::Present,
        ) {
            return rollback_ready_commit_failure(error, &mut broker, journal);
        }
        if let Err(error) = journal.record(V7State::Committed, &[]) {
            return rollback_ready_commit_failure(error, &mut broker, journal);
        }
        if let Err(error) = broker.commit() {
            broker.require_proxy_commit_from_durable_journal().map_err(|cleanup| {
                ControllerError(format!(
                    "CRITICAL: durable COMMITTED journal exists but broker commit could not be proved: primary={error}; proxy={cleanup}"
                ))
            })?;
            eprintln!(
                "warning: root broker commit completed through its durable-journal crash path: {error}"
            );
        }
        if let Err(error) = write_result(&layout.result, "success", None) {
            eprintln!("warning: paired-v7 update committed but result recording failed: {error}");
        }
        println!(
            "PAIRED_V7_HOST_UPDATE_COMMITTED evidence={} pid={} rollback=current-isolated-retained pairing=preserved",
            layout.evidence.display(),
            generation.pid
        );
        Ok(())
    }

    fn rollback_existing_paired_v7_update(repo: PathBuf) -> Result<()> {
        verify_machine_contract()?;
        let transaction_lock = acquire_update_transaction_lock_at(Path::new(V7_UPDATE_LOCK))?;
        verify_committed_v6_baseline()?;
        let evidence =
            read_update_pointer_at(Path::new(V7_ACTIVE_UPDATE), Path::new(V7_UPDATE_ROOT))?;
        require_current_retry_v7_layout(
            &evidence,
            None,
            RetryV7PointerExpectation::Present,
        )?;
        let layout = v7_layout_from_existing(repo, evidence)?;
        require_current_retry_v7_layout(
            &layout.evidence,
            Some(&layout.nonce),
            RetryV7PointerExpectation::Present,
        )?;
        let mut journal = V7Journal::open(&layout.journal)?;
        if journal.state == V7State::RolledBack {
            verify_paired_v7_runtime()?;
            verify_isolated_pairing_items_present()?;
            ensure_rolled_back_result(&layout.result)?;
            retire_v7_active_pointer(&layout)?;
            println!("PAIRED_V7_HOST_UPDATE_ALREADY_ROLLED_BACK");
            return Ok(());
        }
        rollback_to_current_baseline(
            &layout,
            &mut journal,
            &transaction_lock,
            RetryV7PointerExpectation::Present,
        )?;
        write_result(&layout.result, "rolled-back-by-explicit-request", None)?;
        retire_v7_active_pointer(&layout)?;
        println!(
            "PAIRED_V7_HOST_UPDATE_ROLLED_BACK evidence={} pairing=preserved",
            layout.evidence.display()
        );
        Ok(())
    }

    fn rollback_to_current_baseline(
        layout: &V7Layout,
        journal: &mut V7Journal,
        _transaction_lock: &UpdateTransactionLock,
        pointer_expectation: RetryV7PointerExpectation,
    ) -> Result<()> {
        journal.require_healthy()?;
        require_current_retry_v7_layout(
            &layout.evidence,
            Some(&layout.nonce),
            pointer_expectation,
        )?;
        verify_v5_pointer_unchanged()?;
        verify_isolated_pairing_items_present()?;
        if journal.state == V7State::RolledBack {
            verify_paired_v7_runtime()?;
            return Ok(());
        }
        let driver_already_restored = matches!(
            journal.state,
            V7State::DriverRestored
                | V7State::FailedNewArchived
                | V7State::CurrentRestored
                | V7State::CurrentBootstrapped
                | V7State::RolledBack
        );
        // Establish both detached UID501 and root recovery processes while the current host is
        // still recoverable. This is the only password prompt; no later restore depends on the
        // sudo timestamp surviving host shutdown or probe/rollback deadlines.
        let mut driver_restore = if driver_already_restored {
            None
        } else {
            Some(RootExistingDriverRestoreClient::start(
                layout,
                pointer_expectation,
            )?)
        };
        let already_rolling_back = matches!(
            journal.state,
            V7State::RollbackStarted
                | V7State::DriverRestored
                | V7State::FailedNewArchived
                | V7State::CurrentRestored
                | V7State::CurrentBootstrapped
        );
        if !already_rolling_back {
            journal.record(V7State::RollbackStarted, &[])?;
        }
        if layout.rollback_reserve.exists() {
            release_rollback_reserve(&layout.rollback_reserve)?;
        }

        require_current_retry_v7_layout(
            &layout.evidence,
            Some(&layout.nonce),
            pointer_expectation,
        )?;
        verify_v5_pointer_unchanged()?;
        verify_isolated_pairing_items_present()?;
        bootout_paired_v7_job_if_loaded(layout)?;
        wait_for_no_capture_servers(Duration::from_secs(30))?;
        require_service_absent(NEW_LAUNCH_AGENT_LABEL)?;
        verify_protected_legacy_absent()?;
        let lock = acquire_unowned_shared_lock()?;
        verify_isolated_pairing_items_present()?;
        verify_v5_pointer_unchanged()?;

        if journal.state == V7State::RollbackStarted {
            let restore = driver_restore.as_mut().ok_or_else(|| {
                ControllerError(
                    "product-driver restoration was not prepared before host shutdown".to_owned(),
                )
            })?;
            restore.restore()?;
            *journal = V7Journal::open(&layout.journal)?;
        }
        if journal.state != V7State::DriverRestored
            && journal.state != V7State::FailedNewArchived
            && journal.state != V7State::CurrentRestored
            && journal.state != V7State::CurrentBootstrapped
        {
            return Err(ControllerError(
                "product-driver restoration did not durably precede host rollback".to_owned(),
            ));
        }
        drop(driver_restore);
        archive_v7_install_hold_root(layout)?;

        let canonical_exists = path_exists_without_follow(Path::new(NEW_APP))?;
        let rollback_exists = path_exists_without_follow(&layout.rollback_app)?;
        let failed_exists = path_exists_without_follow(&layout.failed_app)?;

        if rollback_exists {
            verify_current_baseline_app_at(&layout.rollback_app, false)?;
            if canonical_exists {
                if verify_current_baseline_app_at(Path::new(NEW_APP), true).is_ok() {
                    return Err(ControllerError(
                        "rollback found duplicate current isolated baseline apps".to_owned(),
                    ));
                }
                if failed_exists {
                    return Err(ControllerError(
                        "rollback found both canonical failed app and retained failed archive"
                            .to_owned(),
                    ));
                }
                verify_v7_installed_matches_reference(layout)?;
                rename_exclusive(Path::new(NEW_APP), &layout.failed_app)?;
                fsync_parent(Path::new(NEW_APP))?;
                fsync_parent(&layout.failed_app)?;
                if journal.state == V7State::DriverRestored {
                    journal.record(V7State::FailedNewArchived, &[])?;
                }
            } else if failed_exists && journal.state == V7State::DriverRestored {
                journal.record(V7State::FailedNewArchived, &[])?;
            }

            require_path_absent(Path::new(NEW_APP), "canonical app before baseline restore")?;
            rename_exclusive(&layout.rollback_app, Path::new(NEW_APP))?;
            fsync_parent(Path::new(NEW_APP))?;
            fsync_parent(&layout.rollback_app)?;
            verify_current_baseline_app_at(Path::new(NEW_APP), true)?;
            if matches!(
                journal.state,
                V7State::DriverRestored | V7State::FailedNewArchived
            ) {
                journal.record(V7State::CurrentRestored, &[])?;
            }
        } else if canonical_exists {
            verify_current_baseline_app_at(Path::new(NEW_APP), true)?;
            if matches!(
                journal.state,
                V7State::DriverRestored | V7State::FailedNewArchived
            ) {
                journal.record(V7State::CurrentRestored, &[])?;
            }
        } else {
            return Err(ControllerError(
                "rollback cannot locate the exact current isolated baseline".to_owned(),
            ));
        }

        if !matches!(
            journal.state,
            V7State::CurrentRestored | V7State::CurrentBootstrapped
        ) {
            return Err(ControllerError(format!(
                "paired-v7 rollback topology is not resumable from {}",
                journal.state.token()
            )));
        }
        verify_isolated_pairing_items_present()?;
        verify_v5_pointer_unchanged()?;
        drop(lock);

        verify_current_baseline_app_at(Path::new(NEW_APP), true)?;
        let checkpoint = capture_log_checkpoint()?;
        bootstrap_exact_new_job()?;
        if journal.state == V7State::CurrentRestored {
            journal.record(V7State::CurrentBootstrapped, &[])?;
        }
        let generation = wait_for_paired_v7_launch_generation(Duration::from_secs(45))?;
        verify_current_baseline_oracle_pins()?;
        verify_deployment(
            Path::new(CURRENT_BASELINE_SOURCE_EXPORT),
            Path::new(CURRENT_BASELINE_APP),
            &checkpoint,
            &generation,
        )?;
        verify_isolated_pairing_items_present()?;
        verify_v5_pointer_unchanged()?;
        verify_protected_legacy_absent()?;
        journal.record(V7State::RolledBack, &[])?;
        verify_paired_v7_runtime()?;
        Ok(())
    }

    fn v7_layout_from_existing(repo: PathBuf, evidence: PathBuf) -> Result<V7Layout> {
        require_descendant(Path::new(V7_UPDATE_ROOT), &evidence)?;
        require_directory(&evidence, 0o700)?;
        let install_hold_name = read_bounded_utf8(&evidence.join("install-hold-name.txt"), 512)?;
        let install_hold_root = PathBuf::from(install_hold_name.trim_end());
        let nonce = install_hold_root
            .file_name()
            .and_then(|value| value.to_str())
            .and_then(|value| value.strip_prefix(HIDDEN_INSTALL_PREFIX))
            .ok_or_else(|| {
                ControllerError("paired-v7 install-hold name is malformed".to_owned())
            })?;
        let expected = V7Layout::new(repo, evidence, nonce);
        if expected.install_hold_root != install_hold_root {
            return Err(ControllerError(
                "paired-v7 install-hold path escaped its recorded layout".to_owned(),
            ));
        }
        require_v7_install_hold_layout(&expected.install_hold_root, &expected.install_hold)?;
        Ok(expected)
    }

    fn export_v7_source(
        layout: &V7Layout,
        provenance: &Provenance,
        release_cycle: &ReleaseCycleEvidence,
    ) -> Result<()> {
        if release_cycle.release_commit != provenance.commit
            || release_cycle.release_tree != provenance.tree
            || release_cycle.functional_inputs_sha256 != EXPECTED_FUNCTIONAL_INPUTS_SHA256
        {
            return Err(ControllerError(
                "release-cycle evidence is not bound to the source export".to_owned(),
            ));
        }
        require_path_absent(&layout.source_tar, "v7 source archive")?;
        require_path_absent(&layout.source_export, "v7 source export")?;
        create_private_directory(&layout.source_export)?;
        let archive = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&layout.source_tar)?;
        let status = Command::new("/usr/bin/git")
            .args(["archive", "--format=tar", &provenance.commit])
            .current_dir(&layout.repo)
            .stdout(Stdio::from(archive))
            .stderr(Stdio::piped())
            .status()?;
        require_success(status, "git archive for paired-v7 update")?;
        require_regular(&layout.source_tar, 0o600)?;
        let output = command_output(
            "/usr/bin/tar",
            &[
                "-xf",
                path_text(&layout.source_tar)?,
                "-C",
                path_text(&layout.source_export)?,
            ],
            None,
        )?;
        require_output_success(&output, "extract paired-v7 source archive")?;
        require_regular(
            &layout
                .source_export
                .join("macOS/scripts/build-opensteamer-host-app.sh"),
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        require_regular(
            &layout
                .source_export
                .join("macOS/scripts/opensteamer-host-paired-v7-update-controller.rs"),
            0o600,
        )?;
        let functional_inputs_path = layout.evidence.join("functional-inputs.txt");
        let mut functional_inputs = create_new_private(&functional_inputs_path)?;
        writeln!(
            functional_inputs,
            "schema=opensteamer.functional-input-evidence.v1"
        )?;
        writeln!(
            functional_inputs,
            "source_commit={}",
            release_cycle.candidate.commit
        )?;
        writeln!(
            functional_inputs,
            "source_tree={}",
            release_cycle.candidate.tree
        )?;
        writeln!(functional_inputs, "release_commit={}", provenance.commit)?;
        writeln!(functional_inputs, "release_tree={}", provenance.tree)?;
        writeln!(
            functional_inputs,
            "canonical_sha256={}",
            release_cycle.functional_inputs_sha256
        )?;
        writeln!(
            functional_inputs,
            "input_count={}",
            release_cycle.functional_inputs.len()
        )?;
        for input in &release_cycle.functional_inputs {
            writeln!(
                functional_inputs,
                "input path_length={} path={} mode={} sha256={}",
                input.path.len(), input.path, input.mode, input.sha256
            )?;
        }
        writeln!(
            functional_inputs,
            "release_diff_count={}",
            release_cycle.changed_paths.len()
        )?;
        for path in &release_cycle.changed_paths {
            writeln!(functional_inputs, "release_diff_path={path}")?;
        }
        functional_inputs.sync_all()?;
        fsync_parent(&functional_inputs_path)?;

        let provenance_path = layout.evidence.join("provenance.txt");
        let mut record = create_new_private(&provenance_path)?;
        writeln!(record, "commit={}", provenance.commit)?;
        writeln!(record, "tree={}", provenance.tree)?;
        writeln!(
            record,
            "functional_source_commit={}",
            release_cycle.candidate.commit
        )?;
        writeln!(
            record,
            "functional_source_tree={}",
            release_cycle.candidate.tree
        )?;
        writeln!(record, "authorized_release_commit={}", provenance.commit)?;
        writeln!(record, "authorized_release_tree={}", provenance.tree)?;
        writeln!(record, "upstream={}", provenance.upstream)?;
        writeln!(record, "remote={}", provenance.remote)?;
        writeln!(
            record,
            "functional_inputs_sha256={}",
            release_cycle.functional_inputs_sha256
        )?;
        writeln!(
            record,
            "functional_input_evidence_sha256={}",
            sha256(&functional_inputs_path)?
        )?;
        writeln!(
            record,
            "source_archive_sha256={}",
            sha256(&layout.source_tar)?
        )?;
        record.sync_all()?;
        fsync_parent(&provenance_path)
    }

    fn build_and_verify_v7_staged_app(layout: &V7Layout) -> Result<()> {
        require_path_absent(&layout.stage_output, "paired-v7 staged output")?;
        require_path_absent(&layout.scratch, "paired-v7 SwiftPM scratch")?;
        let stdout = create_new_private(&layout.evidence.join("build.stdout"))?;
        let stderr = create_new_private(&layout.evidence.join("build.stderr"))?;
        let build_script = layout
            .source_export
            .join("macOS/scripts/build-opensteamer-host-app.sh");
        let status = Command::new(&build_script)
            .current_dir(&layout.source_export)
            .env_clear()
            .env("HOME", USER_HOME)
            .env("USER", "ahmed")
            .env("LOGNAME", "ahmed")
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin")
            .env("DEVELOPER_DIR", PINNED_XCODE_DEVELOPER_DIR)
            .env("OPENSTEAMER_HOST_APP_OUTPUT_DIR", &layout.stage_output)
            .env("OPENSTEAMER_HOST_SCRATCH_PATH", &layout.scratch)
            .env("OPENSTEAMER_REQUIRE_FRESH_RELEASE", "1")
            .env("OPENSTEAMER_EXPECTED_TEAM_ID", EXPECTED_TEAM_ID)
            .env(
                "OPENSTEAMER_EXPECTED_SIGNING_IDENTITY_SHA1",
                EXPECTED_SIGNING_IDENTITY_SHA1,
            )
            .env(
                "OPENSTEAMER_HOST_DESIGNATED_REQUIREMENT_REFERENCE",
                OFFLINE_LEGACY_REFERENCE,
            )
            .env("OPENSTEAMER_EXPECTED_ARCHITECTURES", "arm64")
            .stdout(Stdio::from(stdout))
            .stderr(Stdio::from(stderr))
            .status()?;
        require_success(status, "fresh signed paired-v7 host build")?;
        verify_staged_app_contract(
            &layout.source_export,
            &layout.staged_app,
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        let executable = layout.staged_app.join("Contents/MacOS/CaptureServer");
        if sha256(&executable)? == CURRENT_BASELINE_EXECUTABLE_SHA256 {
            return Err(ControllerError(
                "paired-v7 staged executable is byte-identical to the current isolated baseline"
                    .to_owned(),
            ));
        }
        verify_staged_pairing_namespace(&executable)
    }

    fn require_exported_pinned_file(
        layout: &V7Layout,
        relative: &str,
        expected_mode: u32,
        expected_sha256: &str,
    ) -> Result<PathBuf> {
        let path = layout.source_export.join(relative);
        require_descendant(&layout.source_export, &path)?;
        require_regular(&path, expected_mode)?;
        if sha256(&path)? != expected_sha256 {
            return Err(ControllerError(format!(
                "exported v7 source differs from its release pin: {relative}"
            )));
        }
        Ok(path)
    }

    fn functional_input_path(path: &str) -> bool {
        if RELEASE_ONLY_PATH_ALLOWLIST.contains(&path) {
            return false;
        }
        matches!(
            path,
            "Package.swift"
                | "Package.resolved"
                | "THIRD_PARTY_NOTICES.md"
                | "macOS/LaunchAgents/org.example.opensteamer.worldwide.plist"
                | "macOS/OpensteamerHost/Info.plist"
                | "macOS/scripts/build-opensteamer-host-app.sh"
                | "macOS/scripts/verify-launch-agent-state.sh"
                | "macOS/scripts/verify-live-mac-host-process.sh"
                | "macOS/scripts/verify-mac-host-bundle.sh"
                | "macOS/scripts/verify-opensteamer-host-deployment.sh"
                | "iOS/opensteamer/scripts/physical-blackhole-microphone-probe.swift"
        ) || path.starts_with("macOS/Sources/")
            || path.starts_with("shared/Sources/")
            || path.starts_with("macOS/VirtualAudioDriver/")
                && !path.starts_with("macOS/VirtualAudioDriver/tests/")
    }

    fn require_canonical_release_path(path: &str, label: &str) -> Result<()> {
        if path.is_empty()
            || path.starts_with('/')
            || path.ends_with('/')
            || path.contains('\0')
            || path.contains('\n')
            || path.contains('\r')
            || path.split('/').any(|part| part.is_empty() || part == "." || part == "..")
            || !path
                .bytes()
                .all(|byte| byte.is_ascii_graphic() && byte != b'\\')
        {
            return Err(ControllerError(format!(
                "{label} contains a non-canonical repository path"
            )));
        }
        Ok(())
    }

    fn canonical_functional_inputs_from_git(
        repo: &Path,
        commit: &str,
    ) -> Result<Vec<FunctionalInputDigest>> {
        require_canonical_git_oid(commit, "functional-input commit")?;
        let listing = command_output(
            "/usr/bin/git",
            &["ls-tree", "-r", "-z", "--full-tree", commit, "--"],
            Some(repo),
        )?;
        require_output_success(&listing, "enumerate canonical functional inputs")?;
        if !listing.stderr.is_empty() || !listing.stdout.ends_with(&[0]) {
            return Err(ControllerError(
                "functional-input git tree listing framing is invalid".to_owned(),
            ));
        }
        let text = String::from_utf8(listing.stdout).map_err(|_| {
            ControllerError("functional-input git tree listing is not UTF-8".to_owned())
        })?;
        let mut inputs = Vec::new();
        for record in text[..text.len() - 1].split('\0') {
            let (header, path) = record.split_once('\t').ok_or_else(|| {
                ControllerError("functional-input git tree record is malformed".to_owned())
            })?;
            require_canonical_release_path(path, "functional-input git tree")?;
            if !functional_input_path(path) {
                continue;
            }
            let fields: Vec<&str> = header.split(' ').collect();
            if fields.len() != 3
                || !matches!(fields[0], "100644" | "100755")
                || fields[1] != "blob"
            {
                return Err(ControllerError(format!(
                    "functional input is not an exact regular Git blob: {path}"
                )));
            }
            require_canonical_git_oid(fields[2], "functional-input blob")?;
            let blob = command_output(
                "/usr/bin/git",
                &["cat-file", "blob", fields[2]],
                Some(repo),
            )?;
            require_output_success(&blob, "read canonical functional-input blob")?;
            if !blob.stderr.is_empty() {
                return Err(ControllerError(format!(
                    "functional-input blob read emitted diagnostics: {path}"
                )));
            }
            inputs.push(FunctionalInputDigest {
                path: path.to_owned(),
                mode: fields[0].to_owned(),
                sha256: sha256_bytes(&blob.stdout)?,
            });
        }
        if inputs.is_empty() {
            return Err(ControllerError(
                "canonical functional-input manifest is empty".to_owned(),
            ));
        }
        inputs.sort();
        if inputs
            .windows(2)
            .any(|window| window[0].path >= window[1].path)
        {
            return Err(ControllerError(
                "canonical functional-input manifest contains duplicate paths".to_owned(),
            ));
        }
        Ok(inputs)
    }

    fn canonical_functional_inputs_sha256(inputs: &[FunctionalInputDigest]) -> Result<String> {
        if inputs.is_empty() {
            return Err(ControllerError(
                "cannot digest an empty functional-input manifest".to_owned(),
            ));
        }
        let mut canonical = format!(
            "OPENSTEAMER_FUNCTIONAL_INPUTS_V1\ncount={}\n",
            inputs.len()
        )
        .into_bytes();
        let mut previous: Option<&str> = None;
        for input in inputs {
            require_canonical_release_path(&input.path, "functional-input manifest")?;
            if !matches!(input.mode.as_str(), "100644" | "100755") {
                return Err(ControllerError(
                    "functional-input manifest contains an invalid Git mode".to_owned(),
                ));
            }
            require_canonical_lower_hex(
                &input.sha256,
                64,
                "functional-input content SHA-256",
            )?;
            if previous.is_some_and(|path| path >= input.path.as_str()) {
                return Err(ControllerError(
                    "functional-input manifest is not strictly path-sorted".to_owned(),
                ));
            }
            canonical.extend_from_slice(
                format!(
                    "path_length={} path={} mode={} sha256={}\n",
                    input.path.len(), input.path, input.mode, input.sha256
                )
                .as_bytes(),
            );
            previous = Some(&input.path);
        }
        sha256_bytes(&canonical)
    }

    fn release_changed_paths(repo: &Path, source: &str, release: &str) -> Result<Vec<String>> {
        let diff = command_output(
            "/usr/bin/git",
            &[
                "diff",
                "--name-only",
                "--no-renames",
                "-z",
                source,
                release,
                "--",
            ],
            Some(repo),
        )?;
        require_output_success(&diff, "enumerate candidate-to-release paths")?;
        if !diff.stderr.is_empty() || !diff.stdout.ends_with(&[0]) {
            return Err(ControllerError(
                "candidate-to-release diff framing is invalid".to_owned(),
            ));
        }
        let text = String::from_utf8(diff.stdout).map_err(|_| {
            ControllerError("candidate-to-release diff is not UTF-8".to_owned())
        })?;
        let mut paths = Vec::new();
        for path in text[..text.len() - 1].split('\0') {
            require_canonical_release_path(path, "candidate-to-release diff")?;
            paths.push(path.to_owned());
        }
        paths.sort();
        if paths.windows(2).any(|window| window[0] >= window[1]) {
            return Err(ControllerError(
                "candidate-to-release diff contains duplicate paths".to_owned(),
            ));
        }
        Ok(paths)
    }

    fn validate_release_cycle_evidence(
        candidate: &CandidateSourceBinding,
        release_commit: &str,
        release_tree: &str,
        resolved_candidate_tree: &str,
        candidate_is_ancestor: bool,
        changed_paths: &[String],
        source_inputs: &[FunctionalInputDigest],
        release_inputs: &[FunctionalInputDigest],
        expected_functional_inputs_sha256: &str,
    ) -> Result<String> {
        require_canonical_git_oid(&candidate.commit, "candidate source commit")?;
        require_canonical_git_oid(&candidate.tree, "candidate source tree")?;
        require_canonical_git_oid(release_commit, "authorized release commit")?;
        require_canonical_git_oid(release_tree, "authorized release tree")?;
        require_canonical_git_oid(resolved_candidate_tree, "resolved candidate source tree")?;
        require_canonical_lower_hex(
            expected_functional_inputs_sha256,
            64,
            "reviewed functional-input manifest SHA-256",
        )?;
        if candidate.branch != EXPECTED_SOURCE_BRANCH || candidate.remote != EXPECTED_REMOTE {
            return Err(ControllerError(
                "candidate source branch or remote differs from the release contract".to_owned(),
            ));
        }
        if candidate.tree != resolved_candidate_tree {
            return Err(ControllerError(
                "candidate manifest source commit/tree binding does not resolve exactly"
                    .to_owned(),
            ));
        }
        if candidate.commit == release_commit || !candidate_is_ancestor {
            return Err(ControllerError(
                "authorized release R is not a strict descendant of candidate source S"
                    .to_owned(),
            ));
        }
        if changed_paths.is_empty()
            || changed_paths
                .windows(2)
                .any(|window| window[0] >= window[1])
            || changed_paths.iter().any(|path| {
                require_canonical_release_path(path, "candidate-to-release allowlist").is_err()
                    || !RELEASE_ONLY_PATH_ALLOWLIST.contains(&path.as_str())
            })
            || REQUIRED_RELEASE_DIFF_PATHS
                .iter()
                .any(|required| !changed_paths.iter().any(|path| path == required))
        {
            return Err(ControllerError(
                "candidate-to-release path set is not the exact reviewed release-only allowlist"
                    .to_owned(),
            ));
        }
        if source_inputs.is_empty() || source_inputs != release_inputs {
            return Err(ControllerError(
                "one or more canonical host, driver, probe, or package inputs changed from S to R"
                    .to_owned(),
            ));
        }
        let actual = canonical_functional_inputs_sha256(source_inputs)?;
        if actual != expected_functional_inputs_sha256 {
            return Err(ControllerError(
                "canonical functional-input manifest differs from its reviewed release pin"
                    .to_owned(),
            ));
        }
        Ok(actual)
    }

    fn read_candidate_source_binding(manifest: &Path) -> Result<CandidateSourceBinding> {
        let text = read_bounded_utf8(manifest, 4_096)?;
        if !text.ends_with('\n') || text.contains('\r') || text.as_bytes().contains(&0) {
            return Err(ControllerError(
                "reviewed production-driver candidate manifest framing is invalid".to_owned(),
            ));
        }
        let expected_keys = [
            "schema",
            "source_commit",
            "source_tree",
            "source_branch",
            "remote",
            "developer_id_application_sha1",
            "developer_id_installer_identity_sha1",
            "developer_id_installer_leaf_sha256",
            "bundle_tree_sha256",
            "executable_sha256",
            "package_sha256",
            "notary_submission_id",
        ];
        let lines: Vec<&str> = text.lines().collect();
        if lines.len() != expected_keys.len() {
            return Err(ControllerError(
                "reviewed production-driver candidate manifest field count is invalid".to_owned(),
            ));
        }
        let mut values = Vec::with_capacity(expected_keys.len());
        for (line, expected_key) in lines.into_iter().zip(expected_keys) {
            let (key, value) = line.split_once('=').ok_or_else(|| {
                ControllerError(
                    "reviewed production-driver candidate manifest field is malformed".to_owned(),
                )
            })?;
            if key != expected_key
                || value.is_empty()
                || !value.bytes().all(|byte| {
                    byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-' | b':' | b'/')
                })
            {
                return Err(ControllerError(
                    "reviewed production-driver candidate manifest field is unsafe".to_owned(),
                ));
            }
            values.push(value);
        }
        let expected_values = [
            "opensteamer.production-driver-candidate.v7",
            values[1],
            values[2],
            EXPECTED_SOURCE_BRANCH,
            EXPECTED_REMOTE,
            EXPECTED_DEVELOPER_ID_APPLICATION_SHA1,
            EXPECTED_DEVELOPER_ID_INSTALLER_IDENTITY_SHA1,
            EXPECTED_DEVELOPER_ID_INSTALLER_LEAF_SHA256,
            EXPECTED_PRODUCTION_DRIVER_TREE_SHA256,
            EXPECTED_PRODUCTION_DRIVER_EXECUTABLE_SHA256,
            EXPECTED_PRODUCTION_DRIVER_PACKAGE_SHA256,
        ];
        if values[..expected_values.len()] != expected_values {
            return Err(ControllerError(
                "reviewed production-driver candidate is not bound to the exact authorized source and release pins"
                    .to_owned(),
            ));
        }
        require_canonical_git_oid(values[1], "candidate manifest source commit")?;
        require_canonical_git_oid(values[2], "candidate manifest source tree")?;
        validate_v7_nonce(values[11]).map_err(|_| {
            ControllerError(
                "reviewed production-driver candidate notary submission ID is malformed".to_owned(),
            )
        })?;
        Ok(CandidateSourceBinding {
            commit: values[1].to_owned(),
            tree: values[2].to_owned(),
            branch: values[3].to_owned(),
            remote: values[4].to_owned(),
        })
    }

    fn verify_candidate_manifest_provenance(
        manifest: &Path,
        repo: &Path,
        provenance: &Provenance,
        expected_functional_inputs_sha256: &str,
    ) -> Result<ReleaseCycleEvidence> {
        let candidate = read_candidate_source_binding(manifest)?;
        let resolved_commit = command_line(
            "/usr/bin/git",
            &["rev-parse", "--verify", &format!("{}^{{commit}}", candidate.commit)],
            Some(repo),
        )?;
        if resolved_commit != candidate.commit {
            return Err(ControllerError(
                "candidate source commit does not resolve to its exact full object ID".to_owned(),
            ));
        }
        let resolved_candidate_tree = command_line(
            "/usr/bin/git",
            &["rev-parse", &format!("{}^{{tree}}", candidate.commit)],
            Some(repo),
        )?;
        let ancestry = command_output(
            "/usr/bin/git",
            &[
                "merge-base",
                "--is-ancestor",
                &candidate.commit,
                &provenance.commit,
            ],
            Some(repo),
        )?;
        let candidate_is_ancestor = if ancestry.status.success() {
            true
        } else if ancestry.status.code() == Some(1)
            && ancestry.stdout.is_empty()
            && ancestry.stderr.is_empty()
        {
            false
        } else {
            return Err(command_failure(
                "verify candidate-source ancestry for authorized release",
                &ancestry,
            ));
        };
        let changed_paths = release_changed_paths(repo, &candidate.commit, &provenance.commit)?;
        let source_inputs = canonical_functional_inputs_from_git(repo, &candidate.commit)?;
        let release_inputs = canonical_functional_inputs_from_git(repo, &provenance.commit)?;
        let functional_inputs_sha256 = validate_release_cycle_evidence(
            &candidate,
            &provenance.commit,
            &provenance.tree,
            &resolved_candidate_tree,
            candidate_is_ancestor,
            &changed_paths,
            &source_inputs,
            &release_inputs,
            expected_functional_inputs_sha256,
        )?;
        Ok(ReleaseCycleEvidence {
            candidate,
            release_commit: provenance.commit.clone(),
            release_tree: provenance.tree.clone(),
            changed_paths,
            functional_inputs: release_inputs,
            functional_inputs_sha256,
        })
    }

    fn materialize_reviewed_production_driver(
        layout: &V7Layout,
        provenance: &Provenance,
    ) -> Result<()> {
        let builder = require_exported_pinned_file(
            layout,
            "macOS/VirtualAudioDriver/scripts/build-production-driver-package-v7.sh",
            SOURCE_EXPORT_EXECUTABLE_MODE,
            EXPECTED_PRODUCTION_DRIVER_BUILDER_SHA256,
        )?;
        let verifier = require_exported_pinned_file(
            layout,
            "macOS/VirtualAudioDriver/scripts/verify-production-driver-package-v7.sh",
            SOURCE_EXPORT_EXECUTABLE_MODE,
            EXPECTED_PRODUCTION_DRIVER_VERIFIER_SHA256,
        )?;
        let _parser = require_exported_pinned_file(
            layout,
            "macOS/VirtualAudioDriver/scripts/parse-installer-signature-v7.sh",
            SOURCE_EXPORT_EXECUTABLE_MODE,
            EXPECTED_INSTALLER_SIGNATURE_PARSER_SHA256,
        )?;
        let candidate = Path::new(REVIEWED_PRODUCTION_DRIVER_CANDIDATE_ROOT);
        require_directory(candidate, 0o500)?;
        let candidate_manifest = candidate.join("candidate-manifest.txt");
        require_regular(&candidate_manifest, 0o400)?;
        if sha256(&candidate_manifest)? != EXPECTED_PRODUCTION_DRIVER_CANDIDATE_MANIFEST_SHA256 {
            return Err(ControllerError(
                "reviewed production-driver candidate manifest changed".to_owned(),
            ));
        }
        let _release_cycle = verify_candidate_manifest_provenance(
            &candidate_manifest,
            &layout.repo,
            provenance,
            EXPECTED_FUNCTIONAL_INPUTS_SHA256,
        )?;
        require_path_absent(
            &layout.production_driver_dir,
            "paired-v7 production driver materialization root",
        )?;
        let output = Command::new(&builder)
            .args([
                path_text(candidate)?,
                path_text(&layout.production_driver_dir)?,
                EXPECTED_DEVELOPER_ID_APPLICATION_SHA1,
                EXPECTED_DEVELOPER_ID_INSTALLER_LEAF_SHA256,
                EXPECTED_PRODUCTION_DRIVER_TREE_SHA256,
                EXPECTED_PRODUCTION_DRIVER_EXECUTABLE_SHA256,
                EXPECTED_PRODUCTION_DRIVER_PACKAGE_SHA256,
                EXPECTED_PRODUCTION_DRIVER_CANDIDATE_MANIFEST_SHA256,
            ])
            .env_clear()
            .env("LC_ALL", "C")
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .env("DEVELOPER_DIR", PINNED_XCODE_DEVELOPER_DIR)
            .output()?;
        require_output_success(&output, "materialize reviewed production driver package")?;
        if decode_utf8(&output.stdout, "production driver builder stdout")?
            != format!("{}\n", layout.production_driver_dir.display())
        {
            return Err(ControllerError(
                "production driver materializer returned an unexpected path".to_owned(),
            ));
        }
        require_directory(&layout.production_driver_dir, 0o700)?;
        require_directory(&layout.production_driver, 0o755)?;
        require_regular(&layout.production_driver_package, 0o600)?;
        if sha256(&layout.production_driver_package)? != EXPECTED_PRODUCTION_DRIVER_PACKAGE_SHA256
            || sha256(
                &layout
                    .production_driver
                    .join("Contents/MacOS/OpensteamerVirtualMicrophone"),
            )? != EXPECTED_PRODUCTION_DRIVER_EXECUTABLE_SHA256
        {
            return Err(ControllerError(
                "materialized production driver artifact hashes changed".to_owned(),
            ));
        }
        let verification = Command::new(&verifier)
            .args([
                path_text(&layout.production_driver)?,
                path_text(&layout.production_driver_package)?,
                EXPECTED_DEVELOPER_ID_APPLICATION_SHA1,
                EXPECTED_DEVELOPER_ID_INSTALLER_LEAF_SHA256,
                EXPECTED_PRODUCTION_DRIVER_TREE_SHA256,
                EXPECTED_PRODUCTION_DRIVER_EXECUTABLE_SHA256,
                EXPECTED_PRODUCTION_DRIVER_PACKAGE_SHA256,
            ])
            .env_clear()
            .env("LC_ALL", "C")
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .env("DEVELOPER_DIR", PINNED_XCODE_DEVELOPER_DIR)
            .output()?;
        require_output_success(&verification, "strictly reverify production driver package")?;
        let verification_text =
            decode_utf8(&verification.stdout, "production driver verifier stdout")?;
        if !verification_text
            .ends_with("VERIFIED_DEVELOPER_ID_NOTARIZED_STAPLED_DRIVER_PACKAGE_V7\n")
        {
            return Err(ControllerError(
                "production driver verifier did not emit its exact success marker".to_owned(),
            ));
        }
        Ok(())
    }

    fn build_and_verify_v7_probe_binaries(layout: &V7Layout) -> Result<()> {
        let probe_directory = layout
            .mirror_probe
            .parent()
            .ok_or_else(|| ControllerError("paired-v7 probe output has no parent".to_owned()))?;
        create_private_directory(probe_directory)?;
        let mirror_source = require_exported_pinned_file(
            layout,
            "iOS/opensteamer/scripts/physical-blackhole-microphone-probe.swift",
            0o600,
            EXPECTED_MIRROR_PROBE_SOURCE_SHA256,
        )?;
        const MIRROR_SOURCE_BASENAME: &str = "physical-blackhole-microphone-probe.swift";
        let mirror_source_parent = mirror_source.parent().ok_or_else(|| {
            ControllerError("paired-v7 mirror source has no validated parent".to_owned())
        })?;
        require_directory(mirror_source_parent, 0o700)?;
        if mirror_source.file_name().and_then(|name| name.to_str())
            != Some(MIRROR_SOURCE_BASENAME)
        {
            return Err(ControllerError(
                "paired-v7 mirror source basename changed after absolute-path validation"
                    .to_owned(),
            ));
        }
        let guardian_source = require_exported_pinned_file(
            layout,
            "macOS/VirtualAudioDriver/Probes/V7DefaultRouteGuardian.swift",
            0o600,
            EXPECTED_DEFAULT_ROUTE_GUARDIAN_SOURCE_SHA256,
        )?;
        const GUARDIAN_SOURCE_BASENAME: &str = "V7DefaultRouteGuardian.swift";
        let guardian_source_parent = guardian_source.parent().ok_or_else(|| {
            ControllerError("paired-v7 guardian source has no validated parent".to_owned())
        })?;
        require_directory(guardian_source_parent, 0o700)?;
        if guardian_source.file_name().and_then(|name| name.to_str())
            != Some(GUARDIAN_SOURCE_BASENAME)
        {
            return Err(ControllerError(
                "paired-v7 guardian source basename changed after absolute-path validation"
                    .to_owned(),
            ));
        }
        let public_builder = require_exported_pinned_file(
            layout,
            "macOS/VirtualAudioDriver/scripts/build-public-vpio-probe.sh",
            SOURCE_EXPORT_EXECUTABLE_MODE,
            EXPECTED_PUBLIC_VPIO_PROBE_BUILDER_SHA256,
        )?;
        for (relative, expected) in [
            (
                "macOS/VirtualAudioDriver/Probes/PublicVPIOProbe.c",
                EXPECTED_PUBLIC_VPIO_PROBE_SOURCE_SHA256,
            ),
            (
                "macOS/VirtualAudioDriver/Probes/PublicVPIOProbeCore.c",
                EXPECTED_PUBLIC_VPIO_PROBE_CORE_SOURCE_SHA256,
            ),
            (
                "macOS/VirtualAudioDriver/Probes/PublicVPIOProbeCore.h",
                EXPECTED_PUBLIC_VPIO_PROBE_HEADER_SHA256,
            ),
        ] {
            let _ = require_exported_pinned_file(layout, relative, 0o600, expected)?;
        }

        let compile_swift = |source_argument: &str,
                             source_directory: Option<&Path>,
                             output: &Path,
                             extra: &[&str]|
         -> Result<()> {
            let mut arguments = vec![
                "--sdk",
                "macosx",
                "swiftc",
                "-swift-version",
                "5",
                "-O",
                "-warnings-as-errors",
                source_argument,
            ];
            arguments.extend_from_slice(extra);
            arguments.push("-o");
            arguments.push(path_text(output)?);
            let mut command = Command::new("/usr/bin/xcrun");
            command.args(arguments);
            if let Some(directory) = source_directory {
                command.current_dir(directory);
            }
            let result = command
                .env_clear()
                .env("LC_ALL", "C")
                .env("HOME", USER_HOME)
                .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
                .env("DEVELOPER_DIR", PINNED_XCODE_DEVELOPER_DIR)
                .output()?;
            require_output_success(&result, "compile exact paired-v7 Swift probe")?;

            let compiled_output_is_exact = |metadata: &fs::Metadata, expected_mode: u32| {
                metadata.file_type().is_file()
                    && !metadata.file_type().is_symlink()
                    && metadata.uid() == USER_ID
                    && metadata.nlink() == 1
                    && metadata.permissions().mode() & 0o7777 == expected_mode
            };
            let named_before = fs::symlink_metadata(output)?;
            if !compiled_output_is_exact(&named_before, 0o700) {
                return Err(ControllerError(format!(
                    "compiled paired-v7 Swift probe has unsafe initial metadata: {}",
                    output.display()
                )));
            }
            let compiled_output = OpenOptions::new()
                .read(true)
                .write(true)
                .custom_flags(O_NOFOLLOW)
                .open(output)?;
            let descriptor_before = compiled_output.metadata()?;
            if !compiled_output_is_exact(&descriptor_before, 0o700)
                || descriptor_before.dev() != named_before.dev()
                || descriptor_before.ino() != named_before.ino()
                || descriptor_before.len() != named_before.len()
            {
                return Err(ControllerError(format!(
                    "compiled paired-v7 Swift probe changed before mode normalization: {}",
                    output.display()
                )));
            }
            compiled_output.set_permissions(fs::Permissions::from_mode(0o755))?;
            let descriptor_after = compiled_output.metadata()?;
            let named_after = fs::symlink_metadata(output)?;
            if !compiled_output_is_exact(&descriptor_after, 0o755)
                || !compiled_output_is_exact(&named_after, 0o755)
                || descriptor_before.dev() != descriptor_after.dev()
                || descriptor_before.ino() != descriptor_after.ino()
                || descriptor_before.len() != descriptor_after.len()
                || descriptor_before.dev() != named_after.dev()
                || descriptor_before.ino() != named_after.ino()
                || descriptor_before.len() != named_after.len()
            {
                return Err(ControllerError(format!(
                    "compiled paired-v7 Swift probe changed during mode normalization: {}",
                    output.display()
                )));
            }
            Ok(())
        };
        compile_swift(
            MIRROR_SOURCE_BASENAME,
            Some(mirror_source_parent),
            &layout.mirror_probe,
            &[
                "-Xfrontend",
                "-disable-sil-perf-optzns",
                "-Xfrontend",
                "-disable-incremental-llvm-codegen",
                "-Xlinker",
                "-reproducible",
                "-framework",
                "AudioToolbox",
                "-framework",
                "CoreAudio",
            ],
        )?;
        compile_swift(
            GUARDIAN_SOURCE_BASENAME,
            Some(guardian_source_parent),
            &layout.default_route_guardian,
            &[],
        )?;
        let public = Command::new(&public_builder)
            .arg(&layout.public_vpio_probe)
            .env_clear()
            .env("LC_ALL", "C")
            .env("HOME", USER_HOME)
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .env("DEVELOPER_DIR", PINNED_XCODE_DEVELOPER_DIR)
            .output()?;
        require_output_success(&public, "build exact public VPIO probe")?;

        for (path, expected) in [
            (&layout.mirror_probe, EXPECTED_MIRROR_PROBE_BINARY_SHA256),
            (
                &layout.public_vpio_probe,
                EXPECTED_PUBLIC_VPIO_PROBE_BINARY_SHA256,
            ),
            (
                &layout.default_route_guardian,
                EXPECTED_DEFAULT_ROUTE_GUARDIAN_BINARY_SHA256,
            ),
        ] {
            require_regular(path, 0o755)?;
            if sha256(path)? != expected {
                return Err(ControllerError(format!(
                    "paired-v7 probe binary differs from its release pin: {}",
                    path.display()
                )));
            }
        }

        let mirror_self_test = probe_directory.join("mirror-loopback-self-test.json");
        let status = Command::new(&layout.mirror_probe)
            .args([
                "mirror-loopback-self-test",
                "--case",
                "healthy",
                "--nonce",
                &layout.nonce,
                "--required-headroom-seconds",
                "0",
                "--result",
                path_text(&mirror_self_test)?,
            ])
            .env_clear()
            .env("LC_ALL", "C")
            .status()?;
        require_success(status, "run mirror-loopback pure self-test")?;
        require_regular(&mirror_self_test, 0o600)?;
        let mirror_text = read_bounded_utf8(&mirror_self_test, 1_048_576)?;
        if !mirror_text
            .contains("\"schema\" : \"opensteamer.virtual-microphone-mirror-loopback.v2\"")
            || !mirror_text.contains("\"status\" : \"passed\"")
        {
            return Err(ControllerError(
                "mirror-loopback pure self-test evidence is not exact".to_owned(),
            ));
        }

        let public_self_test = Command::new(&layout.public_vpio_probe)
            .arg("--self-test")
            .env_clear()
            .env("LC_ALL", "C")
            .output()?;
        require_output_success(&public_self_test, "run public VPIO pure self-test")?;
        let public_text = decode_utf8(&public_self_test.stdout, "public VPIO self-test")?;
        if !public_text.contains("\"mode\":\"self-test\"")
            || !public_text.contains("\"passed\":true")
            || !public_self_test.stderr.is_empty()
        {
            return Err(ControllerError(
                "public VPIO pure self-test evidence changed".to_owned(),
            ));
        }

        let guardian_self_test = probe_directory.join("guardian-self-test.json");
        let status = Command::new(&layout.default_route_guardian)
            .args(["self-test", "--result", path_text(&guardian_self_test)?])
            .env_clear()
            .env("LC_ALL", "C")
            .status()?;
        require_success(status, "run default-route guardian pure self-test")?;
        require_regular(&guardian_self_test, 0o600)?;
        let guardian_text = read_bounded_utf8(&guardian_self_test, 65_536)?;
        if !guardian_text.contains("\"mode\" : \"self-test\"")
            || !guardian_text.contains("\"passed\" : \"true\"")
        {
            return Err(ControllerError(
                "default-route guardian pure self-test evidence changed".to_owned(),
            ));
        }
        Ok(())
    }

    struct BoundedChildOutcome {
        status: ExitStatus,
        timed_out: bool,
    }

    fn run_bounded_process_group(
        mut command: Command,
        stdout_path: &Path,
        stderr_path: &Path,
        timeout: Duration,
    ) -> Result<BoundedChildOutcome> {
        let stdout = create_new_private(stdout_path)?;
        let stderr = create_new_private(stderr_path)?;
        command
            .env_clear()
            .env("LC_ALL", "C")
            .stdin(Stdio::null())
            .stdout(Stdio::from(stdout))
            .stderr(Stdio::from(stderr))
            .process_group(0);
        let mut child = command.spawn()?;
        let pid = i32::try_from(child.id())
            .map_err(|_| ControllerError("bounded probe PID overflowed".to_owned()))?;
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if let Some(status) = child.try_wait()? {
                return Ok(BoundedChildOutcome {
                    status,
                    timed_out: false,
                });
            }
            thread::sleep(Duration::from_millis(20));
        }
        // SAFETY: process_group(0) made the exact child PID the isolated group leader.
        let _ = unsafe { kill(-pid, SIGTERM) };
        let term_deadline = Instant::now() + Duration::from_millis(500);
        while Instant::now() < term_deadline {
            if child.try_wait()?.is_some() {
                break;
            }
            thread::sleep(Duration::from_millis(20));
        }
        // SAFETY: the negative exact group leader PID targets only this isolated probe tree.
        let _ = unsafe { kill(-pid, SIGKILL) };
        let status = child.wait()?;
        let group_deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < group_deadline {
            // SAFETY: signal 0 performs a non-mutating existence probe on the isolated group.
            if unsafe { kill(-pid, 0) } != 0 {
                return Ok(BoundedChildOutcome {
                    status,
                    timed_out: true,
                });
            }
            thread::sleep(Duration::from_millis(20));
        }
        Err(ControllerError(
            "timed-out probe process group survived TERM and KILL".to_owned(),
        ))
    }

    fn verify_json_with_python(path: &Path, program: &str, label: &str) -> Result<()> {
        require_regular(path, 0o600)?;
        let output = command_output("/usr/bin/python3", &["-c", program, path_text(path)?], None)?;
        require_output_success(&output, label)
    }

    fn verify_mirror_loopback_result(path: &Path) -> Result<()> {
        verify_json_with_python(
            path,
            r#"import json,sys
v=json.load(open(sys.argv[1],encoding='utf-8'))
assert v['schema']=='opensteamer.virtual-microphone-mirror-loopback.v2'
assert v['status']=='passed' and v['mode']=='real' and v['realQueuePathImplemented'] is True
assert v['lifecycle']['requiredStartOrders']==['visible-first','hidden-first']
assert [x['startOrder'] for x in v['lifecycle']['cycles']]==['visible-first','hidden-first']
assert all(x['quiescentBefore'] and x['quiescentAfter'] and x['nearZeroSharedClock'] and x['timelinesAdvanced'] and x['queuesStoppedAndDisposed'] for x in v['lifecycle']['cycles'])
assert v['defaults']['inputBeforeAfterEqual'] and v['defaults']['outputBeforeAfterEqual'] and v['defaults']['systemOutputBeforeAfterEqual']
assert v['defaults']['notificationCount']==0 and not v['defaults']['mutated']
assert v['defaults']['hiddenEndpointNeverDefault'] and v['defaults']['virtualEndpointsNeverOutputDefault']
assert v['teardown']['cleanupEvidenceComplete'] and v['teardown']['callbackGatesDrained'] and v['teardown']['listenersRemoved'] and v['teardown']['contextsReleased']
assert v['failureCode']=='none' and v['failureReasons']==[]"#,
            "verify exact installed-driver both-order mono loopback evidence",
        )
    }

    fn verify_guardian_result(path: &Path, expected_mode: &str) -> Result<()> {
        verify_json_with_python(
            path,
            &format!(
                r#"import json,sys
v=json.load(open(sys.argv[1],encoding='utf-8'))
assert v['schema']=='opensteamer.v7-default-route-guardian.v1' and v['mode']=={expected_mode:?}
assert v['passed'] is True and v['baselineStable'] is True
assert v['inputRestored'] is True and v['outputsUnchanged'] is True
assert v['hiddenEndpointNeverDefault'] is True and v['virtualEndpointsNeverOutputDefault'] is True
assert v['listener']['removedAndDrained'] is True
assert v['listener']['outputNotifications']==0 and v['listener']['systemOutputNotifications']==0
assert v['failureCode']=='none'"#
            ),
            "verify exact default-route guardian evidence",
        )
    }

    fn verify_public_vpio_result(path: &Path) -> Result<()> {
        require_regular(path, 0o600)?;
        let text = read_bounded_utf8(path, 1_048_576)?;
        if text.lines().count() != 1 {
            return Err(ControllerError(
                "public VPIO live evidence is not exactly one JSON line".to_owned(),
            ));
        }
        let output = command_output(
            "/usr/bin/python3",
            &[
                "-c",
                r#"import json,sys
v=json.load(open(sys.argv[1],encoding='utf-8'))
assert v['schema']==1 and v['mode']=='live-opt-in' and v['claim']=='public-vpio-compatibility-only' and v['passed'] is True
assert v['failureMask']=='0000000000000000'
assert v['visibleInputChannels']==1 and v['visibleOutputChannels']==0
assert v['hiddenInputChannels']==0 and v['hiddenOutputChannels']==1
assert v['visibleNativeFormatExact'] and v['hiddenNativeFormatExact']
assert v['processedMicClientFormatExact'] and v['playoutClientFormatExact']
assert v['endpointTranslationStableBeforeCommit'] and v['endpointTranslationStableAfterStart']
assert v['outputDefaultsStableAndSafeBeforeGate'] and v['defaultsStableAndSafeAfterVPIOStart'] and v['outputDefaultsStableAndSafeAfterRun']
assert v['outputNotifications']==0 and v['systemOutputNotifications']==0 and v['unexpectedInputNotifications']==0
assert v['restorationOwnershipPreserved'] and v['restorationTargetRetranslatedFromUID'] and v['restorationSucceeded'] and v['finalDefaultInputMatchesSnapshot']
assert v['gatesClosedBeforeStop'] and v['callbacksStableAfterDrain'] and v['listenersRemoved'] and v['listenerCallbacksStableAfterRemoval']
assert v['publicVPIOProcessedMicUplinkValidated'] and v['publicVPIOStereoPlayoutRenderPathValidated']
assert not v['faceTimeUplinkClaimed'] and not v['localDownlinkAcousticsClaimed'] and not v['farEndDownlinkAcousticsClaimed']"#,
                path_text(path)?,
            ],
            None,
        )?;
        require_output_success(&output, "verify exact public VPIO live evidence")
    }

    fn stable_user_file_sha256(path: &Path) -> Result<String> {
        require_regular(path, 0o600)?;
        let before = fs::symlink_metadata(path)?;
        let digest = sha256(path)?;
        require_regular(path, 0o600)?;
        let after = fs::symlink_metadata(path)?;
        if before.dev() != after.dev() || before.ino() != after.ino() || before.len() != after.len()
        {
            return Err(ControllerError(
                "guardian state changed while its repair hash was captured".to_owned(),
            ));
        }
        Ok(digest)
    }

    fn repair_guardian_state(layout: &V7Layout, state_sha256: &str) -> Result<()> {
        require_path_absent(
            &layout.vpio_guardian_repair_result,
            "guardian repair result",
        )?;
        let process_stdout = layout
            .vpio_guardian_repair_result
            .with_extension("process.stdout");
        let process_stderr = layout
            .vpio_guardian_repair_result
            .with_extension("process.stderr");
        let mut command = Command::new(&layout.default_route_guardian);
        command.args([
            "repair",
            "--state",
            path_text(&layout.vpio_guardian_state)?,
            "--expected-state-sha256",
            state_sha256,
            "--result",
            path_text(&layout.vpio_guardian_repair_result)?,
        ]);
        let outcome = run_bounded_process_group(
            command,
            &process_stdout,
            &process_stderr,
            Duration::from_secs(12),
        )?;
        if outcome.timed_out || !outcome.status.success() {
            return Err(ControllerError(
                "default-route repair failed or exceeded its independent parent deadline"
                    .to_owned(),
            ));
        }
        verify_guardian_result(&layout.vpio_guardian_repair_result, "repair")
    }

    fn run_installed_driver_probes(
        layout: &V7Layout,
        broker: &mut RootDriverBrokerClient,
    ) -> Result<()> {
        wait_for_no_capture_servers(Duration::from_secs(2))?;
        require_service_absent(NEW_LAUNCH_AGENT_LABEL)?;
        verify_protected_legacy_absent()?;
        broker.ping()?;

        let verifier = require_exported_pinned_file(
            layout,
            "macOS/VirtualAudioDriver/scripts/verify-production-driver-package-v7.sh",
            SOURCE_EXPORT_EXECUTABLE_MODE,
            EXPECTED_PRODUCTION_DRIVER_VERIFIER_SHA256,
        )?;
        let installed = Command::new(&verifier)
            .args([
                PRODUCT_DRIVER_CANONICAL_PATH,
                path_text(&layout.production_driver_package)?,
                EXPECTED_DEVELOPER_ID_APPLICATION_SHA1,
                EXPECTED_DEVELOPER_ID_INSTALLER_LEAF_SHA256,
                EXPECTED_PRODUCTION_DRIVER_TREE_SHA256,
                EXPECTED_PRODUCTION_DRIVER_EXECUTABLE_SHA256,
                EXPECTED_PRODUCTION_DRIVER_PACKAGE_SHA256,
            ])
            .env_clear()
            .env("LC_ALL", "C")
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .env("DEVELOPER_DIR", PINNED_XCODE_DEVELOPER_DIR)
            .output()?;
        require_output_success(
            &installed,
            "verify installed exact production driver topology",
        )?;

        let mirror_stdout = layout.mirror_probe_result.with_extension("stdout");
        let mirror_stderr = layout.mirror_probe_result.with_extension("stderr");
        let mut mirror = Command::new(&layout.mirror_probe);
        mirror.args([
            "mirror-loopback",
            "--nonce",
            &layout.nonce,
            "--required-headroom-seconds",
            "60",
            "--result",
            path_text(&layout.mirror_probe_result)?,
        ]);
        let mirror_outcome = run_bounded_process_group(
            mirror,
            &mirror_stdout,
            &mirror_stderr,
            Duration::from_secs(25),
        )?;
        if mirror_outcome.timed_out || !mirror_outcome.status.success() {
            return Err(ControllerError(
                "installed-driver both-order mono loopback failed or timed out".to_owned(),
            ));
        }
        verify_mirror_loopback_result(&layout.mirror_probe_result)?;
        broker.ping()?;

        let guardian_stdout = layout.vpio_guardian_result.with_extension("process.stdout");
        let guardian_stderr = layout.vpio_guardian_result.with_extension("process.stderr");
        let mut guardian = Command::new(&layout.default_route_guardian);
        guardian.args([
            "run",
            "--child",
            path_text(&layout.public_vpio_probe)?,
            "--state",
            path_text(&layout.vpio_guardian_state)?,
            "--result",
            path_text(&layout.vpio_guardian_result)?,
            "--child-stdout",
            path_text(&layout.vpio_stdout)?,
            "--child-stderr",
            path_text(&layout.vpio_stderr)?,
            "--timeout-seconds",
            "30",
        ]);
        let guardian_outcome = run_bounded_process_group(
            guardian,
            &guardian_stdout,
            &guardian_stderr,
            Duration::from_secs(42),
        )?;
        let state_sha256 = stable_user_file_sha256(&layout.vpio_guardian_state)?;
        let state_hash_path = layout.vpio_guardian_state.with_extension("sha256");
        let mut state_hash_record = create_new_private(&state_hash_path)?;
        writeln!(state_hash_record, "{state_sha256}")?;
        state_hash_record.sync_all()?;
        if guardian_outcome.timed_out || !guardian_outcome.status.success() {
            repair_guardian_state(layout, &state_sha256)?;
            return Err(ControllerError(
                "public VPIO guardian failed or timed out; conditional external route repair passed"
                    .to_owned(),
            ));
        }
        let verification = verify_guardian_result(&layout.vpio_guardian_result, "run")
            .and_then(|_| verify_public_vpio_result(&layout.vpio_stdout))
            .and_then(|_| {
                require_regular(&layout.vpio_stderr, 0o600)?;
                if fs::metadata(&layout.vpio_stderr)?.len() != 0 {
                    return Err(ControllerError(
                        "public VPIO live child wrote unexpected stderr".to_owned(),
                    ));
                }
                Ok(())
            });
        if let Err(error) = verification {
            repair_guardian_state(layout, &state_sha256)?;
            return Err(ControllerError(format!(
                "public VPIO evidence verification failed after conditional route repair: {error}"
            )));
        }
        broker.ping()?;
        wait_for_no_capture_servers(Duration::from_secs(2))?;
        require_service_absent(NEW_LAUNCH_AGENT_LABEL)?;
        Ok(())
    }

    fn verify_staged_pairing_namespace(executable: &Path) -> Result<()> {
        let strings = command_output("/usr/bin/strings", &[path_text(executable)?], None)?;
        require_output_success(&strings, "inspect paired-v7 staged pairing namespace")?;
        let text = decode_utf8(&strings.stdout, "paired-v7 strings output")?;
        let isolated_count = text
            .lines()
            .filter(|line| *line == ISOLATED_PAIRING_SERVICE)
            .count();
        let protected_count = text
            .lines()
            .filter(|line| *line == PROTECTED_PAIRING_SERVICE)
            .count();
        if isolated_count != 1 || protected_count != 0 {
            return Err(ControllerError(format!(
                "paired-v7 staged pairing namespace is not isolated: isolated_count={isolated_count} protected_count={protected_count}"
            )));
        }
        Ok(())
    }

    fn prepare_v7_deployment_reference(layout: &V7Layout) -> Result<()> {
        require_path_absent(
            &layout.deployment_reference_dir,
            "paired-v7 deployment-reference directory",
        )?;
        create_private_directory(&layout.deployment_reference_dir)?;
        let output = command_output(
            "/usr/bin/ditto",
            &[
                "--noqtn",
                path_text(&layout.staged_app)?,
                path_text(&layout.deployment_reference_app)?,
            ],
            None,
        )?;
        require_output_success(&output, "copy paired-v7 deployment reference")?;
        verify_v7_deployment_reference(layout)
    }

    fn verify_v7_deployment_reference(layout: &V7Layout) -> Result<()> {
        require_directory(&layout.deployment_reference_dir, 0o700)?;
        for app in [&layout.staged_app, &layout.deployment_reference_app] {
            verify_staged_app_contract(&layout.source_export, app, SOURCE_EXPORT_EXECUTABLE_MODE)?;
            let executable = app.join("Contents/MacOS/CaptureServer");
            if sha256(&executable)? == CURRENT_BASELINE_EXECUTABLE_SHA256 {
                return Err(ControllerError(
                    "paired-v7 deployment reference equals current isolated baseline".to_owned(),
                ));
            }
            verify_staged_pairing_namespace(&executable)?;
        }
        require_tree_equal(&layout.staged_app, &layout.deployment_reference_app)
    }

    fn prepare_v7_install_hold(layout: &V7Layout) -> Result<()> {
        require_v7_install_hold_layout(&layout.install_hold_root, &layout.install_hold)?;
        require_path_absent(&layout.install_hold_root, "paired-v7 hidden install hold")?;
        create_private_directory(&layout.install_hold_root)?;
        let output = command_output(
            "/usr/bin/ditto",
            &[
                "--noqtn",
                path_text(&layout.deployment_reference_app)?,
                path_text(&layout.install_hold)?,
            ],
            None,
        )?;
        require_output_success(&output, "copy paired-v7 install hold")?;
        verify_bundle(
            &layout.source_export,
            &layout.install_hold,
            false,
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        require_tree_equal(&layout.deployment_reference_app, &layout.install_hold)
    }

    fn record_v7_install_hold_name(layout: &V7Layout) -> Result<()> {
        require_v7_install_hold_layout(&layout.install_hold_root, &layout.install_hold)?;
        let path = layout.evidence.join("install-hold-name.txt");
        let mut record = create_new_private(&path)?;
        writeln!(record, "{}", layout.install_hold_root.display())?;
        record.sync_all()?;
        fsync_parent(&path)
    }

    fn archive_v7_install_hold_root(layout: &V7Layout) -> Result<()> {
        require_v7_install_hold_layout(&layout.install_hold_root, &layout.install_hold)?;
        let archive = layout.failed_dir.join("partial-install-hold-root");
        if archive.parent() != Some(layout.failed_dir.as_path()) {
            return Err(ControllerError(
                "partial install-hold quarantine escaped the retained failed-new directory"
                    .to_owned(),
            ));
        }
        require_directory(&layout.failed_dir, 0o700)?;
        archive_v7_install_hold_root_at(&layout.install_hold_root, &archive)
    }

    fn archive_v7_install_hold_root_at(install_hold_root: &Path, archive: &Path) -> Result<()> {
        let root_exists = path_exists_without_follow(install_hold_root)?;
        let archive_exists = path_exists_without_follow(archive)?;
        match (root_exists, archive_exists) {
            (false, false) => Ok(()),
            (false, true) => require_directory(archive, 0o700),
            (true, true) => Err(ControllerError(
                "partial install-hold root and its quarantine both exist".to_owned(),
            )),
            (true, false) => {
                // The child may be an incomplete `ditto` result. Quarantine the reviewed root as
                // an opaque directory; do not inspect or validate the partial bundle first.
                require_directory(install_hold_root, 0o700)?;
                rename_exclusive(install_hold_root, archive)?;
                fsync_parent(install_hold_root)?;
                fsync_parent(archive)?;
                require_path_absent(install_hold_root, "quarantined partial install-hold root")?;
                require_directory(archive, 0o700)
            }
        }
    }

    fn verify_v7_installed_matches_reference(layout: &V7Layout) -> Result<()> {
        verify_bundle(
            &layout.source_export,
            Path::new(NEW_APP),
            true,
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        require_tree_equal(&layout.deployment_reference_app, Path::new(NEW_APP))?;
        verify_staged_pairing_namespace(Path::new(NEW_EXECUTABLE))?;
        verify_reviewed_launch_agent_unchanged()?;
        verify_protected_legacy_absent()
    }

    fn verify_paired_v7_deployment(
        layout: &V7Layout,
        checkpoint: &LogCheckpoint,
        generation: &LaunchGeneration,
    ) -> Result<()> {
        verify_deployment(
            &layout.source_export,
            &layout.deployment_reference_app,
            checkpoint,
            generation,
        )?;
        verify_generation_bound_paired_marker(checkpoint, generation)
    }

    fn verify_generation_bound_paired_marker(
        checkpoint: &LogCheckpoint,
        generation: &LaunchGeneration,
    ) -> Result<()> {
        require_regular(Path::new(ONLINE_LOG), 0o600)?;
        let before = fs::metadata(ONLINE_LOG)?;
        if before.dev() != checkpoint.device
            || before.ino() != checkpoint.inode
            || before.len() < checkpoint.offset
            || before.nlink() != 1
            || before.uid() != USER_ID
        {
            return Err(ControllerError(
                "paired availability log changed outside the generation checkpoint".to_owned(),
            ));
        }
        let suffix_length = before.len() - checkpoint.offset;
        if suffix_length > 8 * 1_024 * 1_024 {
            return Err(ControllerError(
                "paired availability log suffix exceeds the bounded proof limit".to_owned(),
            ));
        }
        let mut file = File::open(ONLINE_LOG)?;
        file.seek(SeekFrom::Start(checkpoint.offset))?;
        let mut bytes = Vec::with_capacity(suffix_length as usize);
        file.take(8 * 1_024 * 1_024 + 1).read_to_end(&mut bytes)?;
        if bytes.len() as u64 > 8 * 1_024 * 1_024 {
            return Err(ControllerError(
                "paired availability log grew beyond the bounded proof limit".to_owned(),
            ));
        }
        let after = fs::metadata(ONLINE_LOG)?;
        if after.dev() != before.dev()
            || after.ino() != before.ino()
            || after.len() < checkpoint.offset + bytes.len() as u64
        {
            return Err(ControllerError(
                "paired availability log changed while being read".to_owned(),
            ));
        }
        let text = std::str::from_utf8(&bytes)
            .map_err(|_| ControllerError("paired availability log is not UTF-8".to_owned()))?;
        let expected = format!(
            "{PAIRED_AVAILABILITY_MARKER_PREFIX} pid={} nonce={}",
            generation.pid, generation.nonce
        );
        if text.lines().filter(|line| *line == expected).count() == 0 {
            return Err(ControllerError(
                "generation-bound paired-device availability marker is absent".to_owned(),
            ));
        }
        Ok(())
    }

    fn verify_committed_v1_baseline() -> Result<()> {
        require_regular(Path::new(COMMITTED_V1_POINTER), 0o600)?;
        if sha256(Path::new(COMMITTED_V1_POINTER))? != COMMITTED_V1_POINTER_SHA256 {
            return Err(ControllerError(
                "committed v1 pointer hash changed".to_owned(),
            ));
        }
        let pointer = read_bounded_utf8(Path::new(COMMITTED_V1_POINTER), 512)?;
        if pointer != format!("{COMMITTED_V1_EVIDENCE}\n") {
            return Err(ControllerError(
                "committed v1 pointer bytes changed".to_owned(),
            ));
        }
        verify_update_pointer_at(
            Path::new(COMMITTED_V1_POINTER),
            Path::new(COMMITTED_V1_EVIDENCE),
            Path::new(UPDATE_ROOT),
        )?;
        let evidence = Path::new(COMMITTED_V1_EVIDENCE);
        require_directory(evidence, 0o700)?;
        for (relative, expected) in [
            ("journal.log", COMMITTED_V1_JOURNAL_SHA256),
            ("result.txt", COMMITTED_V1_RESULT_SHA256),
            ("provenance.txt", COMMITTED_V1_PROVENANCE_SHA256),
            ("source.tar", COMMITTED_V1_SOURCE_ARCHIVE_SHA256),
            (
                "install-hold-name.txt",
                COMMITTED_V1_INSTALL_HOLD_NAME_SHA256,
            ),
        ] {
            let path = evidence.join(relative);
            require_regular(&path, 0o600)?;
            if sha256(&path)? != expected {
                return Err(ControllerError(format!(
                    "committed v1 evidence changed: {}",
                    path.display()
                )));
            }
        }
        if read_bounded_utf8(&evidence.join("result.txt"), 128)? != "result=success\n" {
            return Err(ControllerError(
                "committed v1 result is not exact success".to_owned(),
            ));
        }
        verify_committed_v1_oracle_pins()?;
        let reference = Path::new(COMMITTED_V1_BASELINE_APP);
        verify_bundle(
            Path::new(COMMITTED_V1_BASELINE_SOURCE_EXPORT),
            reference,
            false,
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        let executable = reference.join("Contents/MacOS/CaptureServer");
        if sha256(&executable)? != COMMITTED_V1_BASELINE_EXECUTABLE_SHA256
            || code_hash(reference)? != COMMITTED_V1_BASELINE_CDHASH
        {
            return Err(ControllerError(
                "committed v1 isolated deployment reference changed".to_owned(),
            ));
        }
        require_code_identity(reference)?;
        verify_staged_pairing_namespace(&executable)
    }

    fn verify_committed_v1_oracle_pins() -> Result<()> {
        let source_export = Path::new(COMMITTED_V1_BASELINE_SOURCE_EXPORT);
        require_directory(source_export, 0o700)?;
        for (relative, mode, expected_sha256) in [
            (
                "macOS/scripts/verify-mac-host-bundle.sh",
                0o700,
                COMMITTED_V1_VERIFY_BUNDLE_SHA256,
            ),
            (
                "macOS/scripts/verify-live-mac-host-process.sh",
                0o700,
                COMMITTED_V1_VERIFY_LIVE_PROCESS_SHA256,
            ),
            (
                "macOS/scripts/verify-mac-host-deployment.sh",
                0o700,
                COMMITTED_V1_VERIFY_DEPLOYMENT_SHA256,
            ),
            (
                "macOS/scripts/verify-mac-host-launch-state.sh",
                0o700,
                COMMITTED_V1_VERIFY_LAUNCH_STATE_SHA256,
            ),
            (
                "macOS/LaunchAgents/org.example.opensteamer.worldwide.plist",
                0o600,
                COMMITTED_V1_LAUNCH_AGENT_SOURCE_SHA256,
            ),
        ] {
            let oracle = source_export.join(relative);
            require_regular(&oracle, mode)?;
            if sha256(&oracle)? != expected_sha256 {
                return Err(ControllerError(format!(
                    "committed v1 rollback oracle changed: {}",
                    oracle.display()
                )));
            }
        }
        Ok(())
    }

    fn verify_committed_v2_baseline() -> Result<()> {
        verify_committed_v1_baseline()?;
        require_regular(Path::new(COMMITTED_V2_POINTER), 0o600)?;
        if sha256(Path::new(COMMITTED_V2_POINTER))? != COMMITTED_V2_POINTER_SHA256 {
            return Err(ControllerError(
                "committed v2 pointer hash changed".to_owned(),
            ));
        }
        let pointer = read_bounded_utf8(Path::new(COMMITTED_V2_POINTER), 512)?;
        if pointer != format!("{COMMITTED_V2_EVIDENCE}\n") {
            return Err(ControllerError(
                "committed v2 pointer bytes changed".to_owned(),
            ));
        }
        verify_update_pointer_at(
            Path::new(COMMITTED_V2_POINTER),
            Path::new(COMMITTED_V2_EVIDENCE),
            Path::new(COMMITTED_V2_UPDATE_ROOT),
        )?;
        let evidence = Path::new(COMMITTED_V2_EVIDENCE);
        require_directory(evidence, 0o700)?;
        for (relative, expected) in [
            ("journal.log", COMMITTED_V2_JOURNAL_SHA256),
            ("result.txt", COMMITTED_V2_RESULT_SHA256),
            ("provenance.txt", COMMITTED_V2_PROVENANCE_SHA256),
            ("source.tar", COMMITTED_V2_SOURCE_ARCHIVE_SHA256),
            (
                "install-hold-name.txt",
                COMMITTED_V2_INSTALL_HOLD_NAME_SHA256,
            ),
            ("build.stdout", COMMITTED_V2_BUILD_STDOUT_SHA256),
            ("build.stderr", COMMITTED_V2_BUILD_STDERR_SHA256),
        ] {
            let path = evidence.join(relative);
            require_regular(&path, 0o600)?;
            if sha256(&path)? != expected {
                return Err(ControllerError(format!(
                    "committed v2 evidence changed: {}",
                    path.display()
                )));
            }
        }
        if read_bounded_utf8(&evidence.join("result.txt"), 128)? != "result=success\n" {
            return Err(ControllerError(
                "committed v2 result is not exact success".to_owned(),
            ));
        }
        for (relative, mode, expected_sha256) in [
            (
                "macOS/scripts/opensteamer-host-paired-v2-update-controller.rs",
                0o600,
                COMMITTED_V2_CONTROLLER_SOURCE_SHA256,
            ),
            (
                "macOS/scripts/update-opensteamer-host-paired-v2.sh",
                0o700,
                COMMITTED_V2_LAUNCHER_SOURCE_SHA256,
            ),
            (
                "macOS/scripts/opensteamer-host-post-v20-update-controller.rs",
                0o600,
                COMMITTED_V2_INCLUDED_V1_SOURCE_SHA256,
            ),
        ] {
            let path = Path::new(COMMITTED_V2_BASELINE_SOURCE_EXPORT).join(relative);
            require_regular(&path, mode)?;
            if sha256(&path)? != expected_sha256 {
                return Err(ControllerError(format!(
                    "committed v2 updater source changed: {}",
                    path.display()
                )));
            }
        }
        verify_committed_v2_oracle_pins()?;
        let reference = Path::new(COMMITTED_V2_BASELINE_APP);
        verify_bundle(
            Path::new(COMMITTED_V2_BASELINE_SOURCE_EXPORT),
            reference,
            false,
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        let executable = reference.join("Contents/MacOS/CaptureServer");
        if sha256(&executable)? != COMMITTED_V2_BASELINE_EXECUTABLE_SHA256
            || code_hash(reference)? != COMMITTED_V2_BASELINE_CDHASH
        {
            return Err(ControllerError(
                "committed v2 isolated deployment reference changed".to_owned(),
            ));
        }
        require_code_identity(reference)?;
        verify_staged_pairing_namespace(&executable)?;

        let staged = evidence.join("staged-output/opensteamer Host.app");
        verify_staged_app_contract(
            Path::new(COMMITTED_V2_BASELINE_SOURCE_EXPORT),
            &staged,
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        require_tree_equal(reference, &staged)?;

        let v1_rollback = evidence.join("rollback-current/opensteamer Host.app");
        verify_committed_v1_app_at(&v1_rollback)
    }

    fn verify_committed_v2_oracle_pins() -> Result<()> {
        let source_export = Path::new(COMMITTED_V2_BASELINE_SOURCE_EXPORT);
        require_directory(source_export, 0o700)?;
        for (relative, mode, expected_sha256) in [
            (
                "macOS/scripts/verify-mac-host-bundle.sh",
                0o700,
                COMMITTED_V2_VERIFY_BUNDLE_SHA256,
            ),
            (
                "macOS/scripts/verify-live-mac-host-process.sh",
                0o700,
                COMMITTED_V2_VERIFY_LIVE_PROCESS_SHA256,
            ),
            (
                "macOS/scripts/verify-mac-host-deployment.sh",
                0o700,
                COMMITTED_V2_VERIFY_DEPLOYMENT_SHA256,
            ),
            (
                "macOS/scripts/verify-mac-host-launch-state.sh",
                0o700,
                COMMITTED_V2_VERIFY_LAUNCH_STATE_SHA256,
            ),
            (
                "macOS/LaunchAgents/org.example.opensteamer.worldwide.plist",
                0o600,
                COMMITTED_V2_LAUNCH_AGENT_SOURCE_SHA256,
            ),
        ] {
            let oracle = source_export.join(relative);
            require_regular(&oracle, mode)?;
            if sha256(&oracle)? != expected_sha256 {
                return Err(ControllerError(format!(
                    "committed v2 rollback oracle changed: {}",
                    oracle.display()
                )));
            }
        }
        Ok(())
    }

    fn verify_committed_v3_baseline() -> Result<()> {
        verify_committed_v2_baseline()?;
        require_regular(Path::new(COMMITTED_V3_POINTER), 0o600)?;
        if sha256(Path::new(COMMITTED_V3_POINTER))? != COMMITTED_V3_POINTER_SHA256 {
            return Err(ControllerError(
                "committed v3 pointer hash changed".to_owned(),
            ));
        }
        let pointer = read_bounded_utf8(Path::new(COMMITTED_V3_POINTER), 512)?;
        if pointer != format!("{COMMITTED_V3_EVIDENCE}\n") {
            return Err(ControllerError(
                "committed v3 pointer bytes changed".to_owned(),
            ));
        }
        verify_update_pointer_at(
            Path::new(COMMITTED_V3_POINTER),
            Path::new(COMMITTED_V3_EVIDENCE),
            Path::new(COMMITTED_V3_UPDATE_ROOT),
        )?;
        let evidence = Path::new(COMMITTED_V3_EVIDENCE);
        require_directory(evidence, 0o700)?;
        for (relative, expected) in [
            ("journal.log", COMMITTED_V3_JOURNAL_SHA256),
            ("result.txt", COMMITTED_V3_RESULT_SHA256),
            ("provenance.txt", COMMITTED_V3_PROVENANCE_SHA256),
            ("source.tar", COMMITTED_V3_SOURCE_ARCHIVE_SHA256),
            (
                "install-hold-name.txt",
                COMMITTED_V3_INSTALL_HOLD_NAME_SHA256,
            ),
            ("build.stdout", COMMITTED_V3_BUILD_STDOUT_SHA256),
            ("build.stderr", COMMITTED_V3_BUILD_STDERR_SHA256),
        ] {
            let path = evidence.join(relative);
            require_regular(&path, 0o600)?;
            if sha256(&path)? != expected {
                return Err(ControllerError(format!(
                    "committed v3 evidence changed: {}",
                    path.display()
                )));
            }
        }
        if read_bounded_utf8(&evidence.join("result.txt"), 128)? != "result=success\n" {
            return Err(ControllerError(
                "committed v3 result is not exact success".to_owned(),
            ));
        }
        for (relative, mode, expected_sha256) in [
            (
                "macOS/scripts/opensteamer-host-paired-v3-update-controller.rs",
                0o600,
                COMMITTED_V3_CONTROLLER_SOURCE_SHA256,
            ),
            (
                "macOS/scripts/update-opensteamer-host-paired-v3.sh",
                0o700,
                COMMITTED_V3_LAUNCHER_SOURCE_SHA256,
            ),
            (
                "macOS/scripts/opensteamer-host-post-v20-update-controller.rs",
                0o600,
                COMMITTED_V3_INCLUDED_V1_SOURCE_SHA256,
            ),
        ] {
            let path = Path::new(COMMITTED_V3_BASELINE_SOURCE_EXPORT).join(relative);
            require_regular(&path, mode)?;
            if sha256(&path)? != expected_sha256 {
                return Err(ControllerError(format!(
                    "committed v3 updater source changed: {}",
                    path.display()
                )));
            }
        }
        verify_committed_v3_oracle_pins()?;
        let reference = Path::new(COMMITTED_V3_BASELINE_APP);
        verify_bundle(
            Path::new(COMMITTED_V3_BASELINE_SOURCE_EXPORT),
            reference,
            false,
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        let executable = reference.join("Contents/MacOS/CaptureServer");
        if sha256(&executable)? != COMMITTED_V3_BASELINE_EXECUTABLE_SHA256
            || code_hash(reference)? != COMMITTED_V3_BASELINE_CDHASH
        {
            return Err(ControllerError(
                "committed v3 isolated deployment reference changed".to_owned(),
            ));
        }
        require_code_identity(reference)?;
        verify_staged_pairing_namespace(&executable)?;

        let staged = evidence.join("staged-output/opensteamer Host.app");
        verify_staged_app_contract(
            Path::new(COMMITTED_V3_BASELINE_SOURCE_EXPORT),
            &staged,
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        require_tree_equal(reference, &staged)?;

        let v2_rollback = evidence.join("rollback-current/opensteamer Host.app");
        verify_committed_v2_app_at(&v2_rollback)
    }

    fn verify_committed_v4_baseline() -> Result<()> {
        verify_committed_v3_baseline()?;
        require_regular(Path::new(COMMITTED_V4_POINTER), 0o600)?;
        if sha256(Path::new(COMMITTED_V4_POINTER))? != COMMITTED_V4_POINTER_SHA256 {
            return Err(ControllerError(
                "committed v4 pointer hash changed".to_owned(),
            ));
        }
        let pointer = read_bounded_utf8(Path::new(COMMITTED_V4_POINTER), 512)?;
        if pointer != format!("{COMMITTED_V4_EVIDENCE}\n") {
            return Err(ControllerError(
                "committed v4 pointer bytes changed".to_owned(),
            ));
        }
        verify_update_pointer_at(
            Path::new(COMMITTED_V4_POINTER),
            Path::new(COMMITTED_V4_EVIDENCE),
            Path::new(COMMITTED_V4_UPDATE_ROOT),
        )?;
        let evidence = Path::new(COMMITTED_V4_EVIDENCE);
        require_directory(evidence, 0o700)?;
        for (relative, expected) in [
            ("journal.log", COMMITTED_V4_JOURNAL_SHA256),
            ("result.txt", COMMITTED_V4_RESULT_SHA256),
            ("provenance.txt", COMMITTED_V4_PROVENANCE_SHA256),
            ("source.tar", COMMITTED_V4_SOURCE_ARCHIVE_SHA256),
            (
                "install-hold-name.txt",
                COMMITTED_V4_INSTALL_HOLD_NAME_SHA256,
            ),
            ("build.stdout", COMMITTED_V4_BUILD_STDOUT_SHA256),
            ("build.stderr", COMMITTED_V4_BUILD_STDERR_SHA256),
        ] {
            let path = evidence.join(relative);
            require_regular(&path, 0o600)?;
            if sha256(&path)? != expected {
                return Err(ControllerError(format!(
                    "committed v4 evidence changed: {}",
                    path.display()
                )));
            }
        }
        if read_bounded_utf8(&evidence.join("result.txt"), 128)? != "result=success\n" {
            return Err(ControllerError(
                "committed v4 result is not exact success".to_owned(),
            ));
        }
        let expected_provenance = format!(
            "commit={COMMITTED_V4_SOURCE_COMMIT}\ntree={COMMITTED_V4_SOURCE_TREE}\nupstream=origin/{EXPECTED_SOURCE_BRANCH}\nremote={EXPECTED_REMOTE}\nsource_archive_sha256={COMMITTED_V4_SOURCE_ARCHIVE_SHA256}\n"
        );
        if read_bounded_utf8(&evidence.join("provenance.txt"), 1024)? != expected_provenance {
            return Err(ControllerError(
                "committed v4 provenance bytes changed".to_owned(),
            ));
        }
        for (relative, mode, expected_sha256) in [
            (
                "macOS/scripts/opensteamer-host-paired-v4-update-controller.rs",
                0o600,
                COMMITTED_V4_CONTROLLER_SOURCE_SHA256,
            ),
            (
                "macOS/scripts/update-opensteamer-host-paired-v4.sh",
                0o700,
                COMMITTED_V4_LAUNCHER_SOURCE_SHA256,
            ),
            (
                "macOS/scripts/opensteamer-host-post-v20-update-controller.rs",
                0o600,
                COMMITTED_V4_INCLUDED_V1_SOURCE_SHA256,
            ),
        ] {
            let path = Path::new(COMMITTED_V4_BASELINE_SOURCE_EXPORT).join(relative);
            require_regular(&path, mode)?;
            if sha256(&path)? != expected_sha256 {
                return Err(ControllerError(format!(
                    "committed v4 updater source changed: {}",
                    path.display()
                )));
            }
        }
        verify_committed_v4_oracle_pins()?;
        let reference = Path::new(COMMITTED_V4_BASELINE_APP);
        verify_bundle(
            Path::new(COMMITTED_V4_BASELINE_SOURCE_EXPORT),
            reference,
            false,
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        let executable = reference.join("Contents/MacOS/CaptureServer");
        if sha256(&executable)? != COMMITTED_V4_BASELINE_EXECUTABLE_SHA256
            || code_hash(reference)? != COMMITTED_V4_BASELINE_CDHASH
        {
            return Err(ControllerError(
                "committed v4 isolated deployment reference changed".to_owned(),
            ));
        }
        require_code_identity(reference)?;
        verify_staged_pairing_namespace(&executable)?;

        let staged = evidence.join("staged-output/opensteamer Host.app");
        verify_staged_app_contract(
            Path::new(COMMITTED_V4_BASELINE_SOURCE_EXPORT),
            &staged,
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        require_tree_equal(reference, &staged)?;

        let v3_rollback = evidence.join("rollback-current/opensteamer Host.app");
        verify_committed_v3_app_at(&v3_rollback)
    }

    fn verify_committed_v5_baseline(data_volume_device: u64) -> Result<()> {
        verify_committed_v4_baseline()?;
        require_regular(Path::new(COMMITTED_V5_POINTER), 0o600)?;
        if sha256(Path::new(COMMITTED_V5_POINTER))? != COMMITTED_V5_POINTER_SHA256 {
            return Err(ControllerError(
                "committed v5 pointer hash changed".to_owned(),
            ));
        }
        let pointer = read_bounded_utf8(Path::new(COMMITTED_V5_POINTER), 512)?;
        if pointer != format!("{COMMITTED_V5_EVIDENCE}\n") {
            return Err(ControllerError(
                "committed v5 pointer bytes changed".to_owned(),
            ));
        }
        verify_update_pointer_at(
            Path::new(COMMITTED_V5_POINTER),
            Path::new(COMMITTED_V5_EVIDENCE),
            Path::new(COMMITTED_V5_UPDATE_ROOT),
        )?;
        let evidence = Path::new(COMMITTED_V5_EVIDENCE);
        require_directory(evidence, 0o700)?;
        require_directory(Path::new(COMMITTED_V5_UPDATE_ROOT), 0o700)?;
        let mut root_entries = fs::read_dir(COMMITTED_V5_UPDATE_ROOT)?;
        let only_entry = root_entries.next().transpose()?.ok_or_else(|| {
            ControllerError("committed v5 update root is unexpectedly empty".to_owned())
        })?;
        if only_entry.path() != evidence || root_entries.next().transpose()?.is_some() {
            return Err(ControllerError(
                "committed v5 update root does not contain exactly its authorized evidence"
                    .to_owned(),
            ));
        }
        for (relative, expected) in [
            ("journal.log", COMMITTED_V5_JOURNAL_SHA256),
            ("result.txt", COMMITTED_V5_RESULT_SHA256),
            ("provenance.txt", COMMITTED_V5_PROVENANCE_SHA256),
            ("source.tar", COMMITTED_V5_SOURCE_ARCHIVE_SHA256),
            (
                "install-hold-name.txt",
                COMMITTED_V5_INSTALL_HOLD_NAME_SHA256,
            ),
            ("build.stdout", COMMITTED_V5_BUILD_STDOUT_SHA256),
            ("build.stderr", COMMITTED_V5_BUILD_STDERR_SHA256),
        ] {
            let path = evidence.join(relative);
            require_regular(&path, 0o600)?;
            if sha256(&path)? != expected {
                return Err(ControllerError(format!(
                    "committed v5 evidence changed: {}",
                    path.display()
                )));
            }
        }
        if read_bounded_utf8(&evidence.join("result.txt"), 128)? != "result=success\n" {
            return Err(ControllerError(
                "committed v5 result is not exact success".to_owned(),
            ));
        }
        let expected_provenance = format!(
            "commit={COMMITTED_V5_SOURCE_COMMIT}\ntree={COMMITTED_V5_SOURCE_TREE}\nupstream=origin/{EXPECTED_SOURCE_BRANCH}\nremote={EXPECTED_REMOTE}\nsource_archive_sha256={COMMITTED_V5_SOURCE_ARCHIVE_SHA256}\n"
        );
        if read_bounded_utf8(&evidence.join("provenance.txt"), 1024)? != expected_provenance {
            return Err(ControllerError(
                "committed v5 provenance bytes changed".to_owned(),
            ));
        }
        if read_bounded_utf8(&evidence.join("install-hold-name.txt"), 512)?
            != format!("{COMMITTED_V5_INSTALL_HOLD_ROOT}\n")
        {
            return Err(ControllerError(
                "committed v5 install-hold record bytes changed".to_owned(),
            ));
        }
        require_path_absent(
            Path::new(COMMITTED_V5_INSTALL_HOLD_ROOT),
            "committed v5 install-hold root",
        )?;
        let reserve = evidence.join("rollback-reserve.bin");
        require_regular(&reserve, 0o600)?;
        let reserve_metadata = fs::symlink_metadata(&reserve)?;
        if reserve_metadata.dev() != data_volume_device
            || reserve_metadata.ino() != COMMITTED_V5_RESERVE_INODE
            || reserve_metadata.len() != 0
            || reserve_metadata.blocks() != 0
        {
            return Err(ControllerError(
                "committed v5 released rollback reserve changed".to_owned(),
            ));
        }
        let failed_new = evidence.join("failed-new");
        require_directory(&failed_new, 0o700)?;
        if fs::read_dir(&failed_new)?.next().transpose()?.is_some() {
            return Err(ControllerError(
                "committed v5 failed-new directory is not empty".to_owned(),
            ));
        }
        for (relative, mode, expected_sha256) in [
            (
                "macOS/scripts/opensteamer-host-paired-v5-update-controller.rs",
                0o600,
                COMMITTED_V5_CONTROLLER_SOURCE_SHA256,
            ),
            (
                "macOS/scripts/update-opensteamer-host-paired-v5.sh",
                0o700,
                COMMITTED_V5_LAUNCHER_SOURCE_SHA256,
            ),
            (
                "macOS/scripts/opensteamer-host-post-v20-update-controller.rs",
                0o600,
                COMMITTED_V5_INCLUDED_V1_SOURCE_SHA256,
            ),
        ] {
            let path = Path::new(COMMITTED_V5_BASELINE_SOURCE_EXPORT).join(relative);
            require_regular(&path, mode)?;
            if sha256(&path)? != expected_sha256 {
                return Err(ControllerError(format!(
                    "committed v5 updater source changed: {}",
                    path.display()
                )));
            }
        }
        let launcher = Path::new(COMMITTED_V5_BASELINE_SOURCE_EXPORT)
            .join("macOS/scripts/update-opensteamer-host-paired-v5.sh");
        let launcher_text = read_bounded_utf8(&launcher, 32 * 1_024)?;
        let expected_binary_pin =
            format!("EXPECTED_BINARY_SHA256='{COMMITTED_V5_CONTROLLER_BINARY_SHA256}'");
        if launcher_text
            .lines()
            .filter(|line| *line == expected_binary_pin)
            .count()
            != 1
        {
            return Err(ControllerError(
                "committed v5 launcher binary postimage pin changed".to_owned(),
            ));
        }
        verify_committed_v5_oracle_pins()?;
        let reference = Path::new(COMMITTED_V5_BASELINE_APP);
        verify_bundle(
            Path::new(COMMITTED_V5_BASELINE_SOURCE_EXPORT),
            reference,
            false,
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        let executable = reference.join("Contents/MacOS/CaptureServer");
        if sha256(&executable)? != COMMITTED_V5_BASELINE_EXECUTABLE_SHA256
            || code_hash(reference)? != COMMITTED_V5_BASELINE_CDHASH
        {
            return Err(ControllerError(
                "committed v5 isolated deployment reference changed".to_owned(),
            ));
        }
        require_code_identity(reference)?;
        verify_staged_pairing_namespace(&executable)?;

        let staged = evidence.join("staged-output/opensteamer Host.app");
        verify_staged_app_contract(
            Path::new(COMMITTED_V5_BASELINE_SOURCE_EXPORT),
            &staged,
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        require_tree_equal(reference, &staged)?;

        let v4_rollback = evidence.join("rollback-current/opensteamer Host.app");
        verify_committed_v4_app_at(&v4_rollback)
    }

    fn verify_committed_v6_baseline() -> Result<()> {
        let data_volume_device = verified_data_volume_device()?;
        verify_committed_v5_baseline(data_volume_device)?;
        require_regular(Path::new(COMMITTED_V6_POINTER), 0o600)?;
        if sha256(Path::new(COMMITTED_V6_POINTER))? != COMMITTED_V6_POINTER_SHA256 {
            return Err(ControllerError(
                "committed v6 pointer hash changed".to_owned(),
            ));
        }
        let pointer = read_bounded_utf8(Path::new(COMMITTED_V6_POINTER), 512)?;
        if pointer != format!("{COMMITTED_V6_EVIDENCE}\n") {
            return Err(ControllerError(
                "committed v6 pointer bytes changed".to_owned(),
            ));
        }
        verify_update_pointer_at(
            Path::new(COMMITTED_V6_POINTER),
            Path::new(COMMITTED_V6_EVIDENCE),
            Path::new(COMMITTED_V6_UPDATE_ROOT),
        )?;
        let evidence = Path::new(COMMITTED_V6_EVIDENCE);
        require_directory(evidence, 0o700)?;
        require_directory(Path::new(COMMITTED_V6_UPDATE_ROOT), 0o700)?;
        let mut root_entries = fs::read_dir(COMMITTED_V6_UPDATE_ROOT)?;
        let only_entry = root_entries.next().transpose()?.ok_or_else(|| {
            ControllerError("committed v6 update root is unexpectedly empty".to_owned())
        })?;
        if only_entry.path() != evidence || root_entries.next().transpose()?.is_some() {
            return Err(ControllerError(
                "committed v6 update root does not contain exactly its authorized evidence"
                    .to_owned(),
            ));
        }
        for (relative, expected) in [
            ("journal.log", COMMITTED_V6_JOURNAL_SHA256),
            ("result.txt", COMMITTED_V6_RESULT_SHA256),
            ("provenance.txt", COMMITTED_V6_PROVENANCE_SHA256),
            ("source.tar", COMMITTED_V6_SOURCE_ARCHIVE_SHA256),
            (
                "install-hold-name.txt",
                COMMITTED_V6_INSTALL_HOLD_NAME_SHA256,
            ),
            ("build.stdout", COMMITTED_V6_BUILD_STDOUT_SHA256),
            ("build.stderr", COMMITTED_V6_BUILD_STDERR_SHA256),
        ] {
            let path = evidence.join(relative);
            require_regular(&path, 0o600)?;
            if sha256(&path)? != expected {
                return Err(ControllerError(format!(
                    "committed v6 evidence changed: {}",
                    path.display()
                )));
            }
        }
        if read_bounded_utf8(&evidence.join("result.txt"), 128)? != "result=success\n" {
            return Err(ControllerError(
                "committed v6 result is not exact success".to_owned(),
            ));
        }
        let expected_provenance = format!(
            "commit={COMMITTED_V6_SOURCE_COMMIT}\ntree={COMMITTED_V6_SOURCE_TREE}\nupstream=origin/{EXPECTED_SOURCE_BRANCH}\nremote={EXPECTED_REMOTE}\nsource_archive_sha256={COMMITTED_V6_SOURCE_ARCHIVE_SHA256}\n"
        );
        if read_bounded_utf8(&evidence.join("provenance.txt"), 1024)? != expected_provenance {
            return Err(ControllerError(
                "committed v6 provenance bytes changed".to_owned(),
            ));
        }
        if read_bounded_utf8(&evidence.join("install-hold-name.txt"), 512)?
            != format!("{COMMITTED_V6_INSTALL_HOLD_ROOT}\n")
        {
            return Err(ControllerError(
                "committed v6 install-hold record bytes changed".to_owned(),
            ));
        }
        require_path_absent(
            Path::new(COMMITTED_V6_INSTALL_HOLD_ROOT),
            "committed v6 install-hold root",
        )?;
        let reserve = evidence.join("rollback-reserve.bin");
        require_regular(&reserve, 0o600)?;
        let reserve_metadata = fs::symlink_metadata(&reserve)?;
        if reserve_metadata.dev() != data_volume_device
            || reserve_metadata.ino() != COMMITTED_V6_RESERVE_INODE
            || reserve_metadata.len() != 0
            || reserve_metadata.blocks() != 0
        {
            return Err(ControllerError(
                "committed v6 released rollback reserve changed".to_owned(),
            ));
        }
        let failed_new = evidence.join("failed-new");
        require_directory(&failed_new, 0o700)?;
        if fs::read_dir(&failed_new)?.next().transpose()?.is_some() {
            return Err(ControllerError(
                "committed v6 failed-new directory is not empty".to_owned(),
            ));
        }
        for (relative, mode, expected_sha256) in [
            (
                "macOS/scripts/opensteamer-host-paired-v6-update-controller.rs",
                0o600,
                COMMITTED_V6_CONTROLLER_SOURCE_SHA256,
            ),
            (
                "macOS/scripts/update-opensteamer-host-paired-v6.sh",
                0o700,
                COMMITTED_V6_LAUNCHER_SOURCE_SHA256,
            ),
            (
                "macOS/scripts/opensteamer-host-post-v20-update-controller.rs",
                0o600,
                COMMITTED_V6_INCLUDED_V1_SOURCE_SHA256,
            ),
        ] {
            let path = Path::new(CURRENT_BASELINE_SOURCE_EXPORT).join(relative);
            require_regular(&path, mode)?;
            if sha256(&path)? != expected_sha256 {
                return Err(ControllerError(format!(
                    "committed v6 updater source changed: {}",
                    path.display()
                )));
            }
        }
        let launcher = Path::new(CURRENT_BASELINE_SOURCE_EXPORT)
            .join("macOS/scripts/update-opensteamer-host-paired-v6.sh");
        let launcher_text = read_bounded_utf8(&launcher, 32 * 1_024)?;
        let expected_binary_pin =
            format!("EXPECTED_BINARY_SHA256='{COMMITTED_V6_CONTROLLER_BINARY_SHA256}'");
        if launcher_text
            .lines()
            .filter(|line| *line == expected_binary_pin)
            .count()
            != 1
        {
            return Err(ControllerError(
                "committed v6 launcher binary postimage pin changed".to_owned(),
            ));
        }
        verify_current_baseline_oracle_pins()?;
        let reference = Path::new(CURRENT_BASELINE_APP);
        verify_bundle(
            Path::new(CURRENT_BASELINE_SOURCE_EXPORT),
            reference,
            false,
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        let executable = reference.join("Contents/MacOS/CaptureServer");
        if sha256(&executable)? != CURRENT_BASELINE_EXECUTABLE_SHA256
            || code_hash(reference)? != CURRENT_BASELINE_CDHASH
        {
            return Err(ControllerError(
                "committed v6 isolated deployment reference changed".to_owned(),
            ));
        }
        require_code_identity(reference)?;
        verify_staged_pairing_namespace(&executable)?;

        let staged = evidence.join("staged-output/opensteamer Host.app");
        verify_staged_app_contract(
            Path::new(CURRENT_BASELINE_SOURCE_EXPORT),
            &staged,
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        require_tree_equal(reference, &staged)?;

        let v5_rollback = evidence.join("rollback-current/opensteamer Host.app");
        verify_committed_v5_app_at(&v5_rollback)
    }

    fn verify_committed_v3_oracle_pins() -> Result<()> {
        let source_export = Path::new(COMMITTED_V3_BASELINE_SOURCE_EXPORT);
        require_directory(source_export, 0o700)?;
        for (relative, mode, expected_sha256) in [
            (
                "macOS/scripts/verify-mac-host-bundle.sh",
                0o700,
                COMMITTED_V3_VERIFY_BUNDLE_SHA256,
            ),
            (
                "macOS/scripts/verify-live-mac-host-process.sh",
                0o700,
                COMMITTED_V3_VERIFY_LIVE_PROCESS_SHA256,
            ),
            (
                "macOS/scripts/verify-mac-host-deployment.sh",
                0o700,
                COMMITTED_V3_VERIFY_DEPLOYMENT_SHA256,
            ),
            (
                "macOS/scripts/verify-mac-host-launch-state.sh",
                0o700,
                COMMITTED_V3_VERIFY_LAUNCH_STATE_SHA256,
            ),
            (
                "macOS/LaunchAgents/org.example.opensteamer.worldwide.plist",
                0o600,
                COMMITTED_V3_LAUNCH_AGENT_SOURCE_SHA256,
            ),
        ] {
            let oracle = source_export.join(relative);
            require_regular(&oracle, mode)?;
            if sha256(&oracle)? != expected_sha256 {
                return Err(ControllerError(format!(
                    "committed v3 rollback oracle changed: {}",
                    oracle.display()
                )));
            }
        }
        Ok(())
    }

    fn verify_committed_v4_oracle_pins() -> Result<()> {
        let source_export = Path::new(COMMITTED_V4_BASELINE_SOURCE_EXPORT);
        require_directory(source_export, 0o700)?;
        for (relative, mode, expected_sha256) in [
            (
                "macOS/scripts/verify-mac-host-bundle.sh",
                0o700,
                COMMITTED_V4_VERIFY_BUNDLE_SHA256,
            ),
            (
                "macOS/scripts/verify-live-mac-host-process.sh",
                0o700,
                COMMITTED_V4_VERIFY_LIVE_PROCESS_SHA256,
            ),
            (
                "macOS/scripts/verify-mac-host-deployment.sh",
                0o700,
                COMMITTED_V4_VERIFY_DEPLOYMENT_SHA256,
            ),
            (
                "macOS/scripts/verify-mac-host-launch-state.sh",
                0o700,
                COMMITTED_V4_VERIFY_LAUNCH_STATE_SHA256,
            ),
            (
                "macOS/LaunchAgents/org.example.opensteamer.worldwide.plist",
                0o600,
                COMMITTED_V4_LAUNCH_AGENT_SOURCE_SHA256,
            ),
        ] {
            let oracle = source_export.join(relative);
            require_regular(&oracle, mode)?;
            if sha256(&oracle)? != expected_sha256 {
                return Err(ControllerError(format!(
                    "committed v4 rollback oracle changed: {}",
                    oracle.display()
                )));
            }
        }
        Ok(())
    }

    fn verify_current_baseline_oracle_pins() -> Result<()> {
        let source_export = Path::new(CURRENT_BASELINE_SOURCE_EXPORT);
        require_directory(source_export, 0o700)?;
        for (relative, mode, expected_sha256) in [
            (
                "macOS/scripts/verify-mac-host-bundle.sh",
                0o700,
                CURRENT_BASELINE_VERIFY_BUNDLE_SHA256,
            ),
            (
                "macOS/scripts/verify-live-mac-host-process.sh",
                0o700,
                CURRENT_BASELINE_VERIFY_LIVE_PROCESS_SHA256,
            ),
            (
                "macOS/scripts/verify-mac-host-deployment.sh",
                0o700,
                CURRENT_BASELINE_VERIFY_DEPLOYMENT_SHA256,
            ),
            (
                "macOS/scripts/verify-mac-host-launch-state.sh",
                0o700,
                CURRENT_BASELINE_VERIFY_LAUNCH_STATE_SHA256,
            ),
            (
                "macOS/LaunchAgents/org.example.opensteamer.worldwide.plist",
                0o600,
                CURRENT_BASELINE_LAUNCH_AGENT_SOURCE_SHA256,
            ),
        ] {
            let oracle = source_export.join(relative);
            require_regular(&oracle, mode)?;
            if sha256(&oracle)? != expected_sha256 {
                return Err(ControllerError(format!(
                    "committed v5 rollback oracle changed: {}",
                    oracle.display()
                )));
            }
        }
        Ok(())
    }

    fn verify_committed_v5_oracle_pins() -> Result<()> {
        let source_export = Path::new(COMMITTED_V5_BASELINE_SOURCE_EXPORT);
        require_directory(source_export, 0o700)?;
        for (relative, mode, expected_sha256) in [
            (
                "macOS/scripts/verify-mac-host-bundle.sh",
                0o700,
                COMMITTED_V5_VERIFY_BUNDLE_SHA256,
            ),
            (
                "macOS/scripts/verify-live-mac-host-process.sh",
                0o700,
                COMMITTED_V5_VERIFY_LIVE_PROCESS_SHA256,
            ),
            (
                "macOS/scripts/verify-mac-host-deployment.sh",
                0o700,
                COMMITTED_V5_VERIFY_DEPLOYMENT_SHA256,
            ),
            (
                "macOS/scripts/verify-mac-host-launch-state.sh",
                0o700,
                COMMITTED_V5_VERIFY_LAUNCH_STATE_SHA256,
            ),
            (
                "macOS/LaunchAgents/org.example.opensteamer.worldwide.plist",
                0o600,
                COMMITTED_V5_LAUNCH_AGENT_SOURCE_SHA256,
            ),
        ] {
            let oracle = source_export.join(relative);
            require_regular(&oracle, mode)?;
            if sha256(&oracle)? != expected_sha256 {
                return Err(ControllerError(format!(
                    "committed v5 rollback oracle changed: {}",
                    oracle.display()
                )));
            }
        }
        Ok(())
    }

    fn verify_committed_v1_app_at(app: &Path) -> Result<()> {
        verify_committed_v1_oracle_pins()?;
        require_directory(app, 0o755)?;
        let executable = app.join("Contents/MacOS/CaptureServer");
        require_regular(&executable, 0o755)?;
        if sha256(&executable)? != COMMITTED_V1_BASELINE_EXECUTABLE_SHA256
            || code_hash(app)? != COMMITTED_V1_BASELINE_CDHASH
        {
            return Err(ControllerError(format!(
                "committed v1 rollback app changed at {}",
                app.display()
            )));
        }
        require_code_identity(app)?;
        verify_historical_rollback_app_xattrs(app)?;
        require_tree_equal(Path::new(COMMITTED_V1_BASELINE_APP), app)
    }

    fn verify_committed_v2_app_at(app: &Path) -> Result<()> {
        verify_committed_v2_oracle_pins()?;
        require_directory(app, 0o755)?;
        let executable = app.join("Contents/MacOS/CaptureServer");
        require_regular(&executable, 0o755)?;
        if sha256(&executable)? != COMMITTED_V2_BASELINE_EXECUTABLE_SHA256
            || code_hash(app)? != COMMITTED_V2_BASELINE_CDHASH
        {
            return Err(ControllerError(format!(
                "committed v2 rollback app changed at {}",
                app.display()
            )));
        }
        require_code_identity(app)?;
        verify_historical_rollback_app_xattrs(app)?;
        require_tree_equal(Path::new(COMMITTED_V2_BASELINE_APP), app)
    }

    fn verify_committed_v3_app_at(app: &Path) -> Result<()> {
        verify_committed_v3_oracle_pins()?;
        require_directory(app, 0o755)?;
        let executable = app.join("Contents/MacOS/CaptureServer");
        require_regular(&executable, 0o755)?;
        if sha256(&executable)? != COMMITTED_V3_BASELINE_EXECUTABLE_SHA256
            || code_hash(app)? != COMMITTED_V3_BASELINE_CDHASH
        {
            return Err(ControllerError(format!(
                "committed v3 rollback app changed at {}",
                app.display()
            )));
        }
        require_code_identity(app)?;
        verify_historical_rollback_app_xattrs(app)?;
        require_tree_equal(Path::new(COMMITTED_V3_BASELINE_APP), app)
    }

    fn verify_committed_v4_app_at(app: &Path) -> Result<()> {
        verify_committed_v4_oracle_pins()?;
        require_directory(app, 0o755)?;
        let executable = app.join("Contents/MacOS/CaptureServer");
        require_regular(&executable, 0o755)?;
        if sha256(&executable)? != COMMITTED_V4_BASELINE_EXECUTABLE_SHA256
            || code_hash(app)? != COMMITTED_V4_BASELINE_CDHASH
        {
            return Err(ControllerError(format!(
                "committed v4 rollback app changed at {}",
                app.display()
            )));
        }
        require_code_identity(app)?;
        verify_historical_rollback_app_xattrs(app)?;
        require_tree_equal(Path::new(COMMITTED_V4_BASELINE_APP), app)
    }

    fn verify_committed_v5_app_at(app: &Path) -> Result<()> {
        require_directory(app, 0o755)?;
        let executable = app.join("Contents/MacOS/CaptureServer");
        require_regular(&executable, 0o755)?;
        if sha256(&executable)? != COMMITTED_V5_BASELINE_EXECUTABLE_SHA256
            || code_hash(app)? != COMMITTED_V5_BASELINE_CDHASH
        {
            return Err(ControllerError(format!(
                "committed v5 rollback app changed at {}",
                app.display()
            )));
        }
        require_code_identity(app)?;
        verify_historical_rollback_app_xattrs(app)?;
        // The committed v5 deployment reference was already verified above with its exact
        // exported bundle oracle. This rollback copy is admitted by executable/CDHash/signature
        // plus byte-for-byte tree equality. Do not re-run the oracle here: macOS may attach the
        // opaque `com.apple.macl` metadata to a retained app directory after commit, and that
        // non-content system xattr must not make the immutable byte tree unverifiable.
        require_tree_equal(Path::new(COMMITTED_V5_BASELINE_APP), app)
    }

    fn verify_historical_rollback_app_xattrs(app: &Path) -> Result<()> {
        let listing = command_output("/usr/bin/xattr", &["-r", path_text(app)?], None)?;
        require_output_success(&listing, "inspect historical rollback app xattrs")?;
        let text = decode_utf8(&listing.stdout, "historical rollback xattr listing")?;
        if text.is_empty() {
            return Ok(());
        }
        let expected = format!("{}: com.apple.macl\n", app.display());
        if text != expected || !listing.stderr.is_empty() {
            return Err(ControllerError(format!(
                "historical rollback app contains an unreviewed xattr: {}",
                app.display()
            )));
        }
        let payload = command_output(
            "/usr/bin/xattr",
            &["-px", "com.apple.macl", path_text(app)?],
            None,
        )?;
        require_output_success(&payload, "read historical rollback macl payload")?;
        let hexadecimal = decode_utf8(&payload.stdout, "historical rollback macl payload")?
            .bytes()
            .filter(|byte| !byte.is_ascii_whitespace())
            .collect::<Vec<_>>();
        if hexadecimal.len() != 144
            || hexadecimal.iter().any(|byte| *byte != b'0')
            || !payload.stderr.is_empty()
        {
            return Err(ControllerError(
                "historical rollback app macl payload is not the exact 72-NUL system value"
                    .to_owned(),
            ));
        }
        Ok(())
    }

    fn verify_v5_pointer_unchanged() -> Result<()> {
        verify_committed_v6_baseline()
    }

    fn verify_current_baseline_app_at(app: &Path, canonical_installed: bool) -> Result<()> {
        verify_current_baseline_oracle_pins()?;
        require_directory(app, 0o755)?;
        let executable = app.join("Contents/MacOS/CaptureServer");
        require_regular(&executable, 0o755)?;
        if sha256(&executable)? != CURRENT_BASELINE_EXECUTABLE_SHA256
            || code_hash(app)? != CURRENT_BASELINE_CDHASH
        {
            return Err(ControllerError(format!(
                "current isolated baseline changed at {}",
                app.display()
            )));
        }
        require_code_identity(app)?;
        require_tree_equal(Path::new(CURRENT_BASELINE_APP), app)?;
        if canonical_installed {
            if app != Path::new(NEW_APP) {
                return Err(ControllerError(
                    "installed baseline verification escaped canonical app".to_owned(),
                ));
            }
            verify_bundle(
                Path::new(CURRENT_BASELINE_SOURCE_EXPORT),
                app,
                true,
                SOURCE_EXPORT_EXECUTABLE_MODE,
            )?;
        }
        Ok(())
    }

    fn verify_reviewed_launch_agent_unchanged() -> Result<()> {
        verify_current_baseline_oracle_pins()?;
        require_regular(Path::new(REVIEWED_LAUNCH_AGENT_PATH), 0o600)?;
        if sha256(Path::new(REVIEWED_LAUNCH_AGENT_PATH))? != REVIEWED_LAUNCH_AGENT_SHA256 {
            return Err(ControllerError(
                "reviewed isolated LaunchAgent bytes changed".to_owned(),
            ));
        }
        let source = Path::new(CURRENT_BASELINE_SOURCE_EXPORT)
            .join("macOS/LaunchAgents/org.example.opensteamer.worldwide.plist");
        require_regular(&source, 0o600)?;
        if sha256(&source)? != REVIEWED_LAUNCH_AGENT_SHA256 {
            return Err(ControllerError(
                "committed v5 LaunchAgent source changed".to_owned(),
            ));
        }
        Ok(())
    }

    fn verify_protected_legacy_absent() -> Result<()> {
        if PROTECTED_LEGACY_LAUNCH_AGENT_LABEL != LEGACY_LABEL {
            return Err(ControllerError(
                "protected legacy LaunchAgent alias changed".to_owned(),
            ));
        }
        verify_legacy_sources()?;
        require_legacy_disabled_and_absent()
    }

    #[derive(Clone, Copy)]
    struct IsolatedPairingKeychainMetadataProof {
        is_regular_file: bool,
        is_symlink: bool,
        uid: u32,
        gid: u32,
        nlink: u64,
        mode: u32,
    }

    fn isolated_pairing_keychain_metadata_is_exact(
        proof: IsolatedPairingKeychainMetadataProof,
    ) -> bool {
        proof.is_regular_file
            && !proof.is_symlink
            && proof.uid == USER_ID
            && proof.gid == ISOLATED_PAIRING_LOGIN_KEYCHAIN_GID
            && proof.nlink == 1
            && proof.mode == ISOLATED_PAIRING_LOGIN_KEYCHAIN_MODE
    }

    fn require_isolated_pairing_login_keychain() -> Result<()> {
        if unsafe { geteuid() } != USER_ID {
            return Err(ControllerError(
                "isolated pairing Keychain proof must run as uid 501".to_owned(),
            ));
        }
        let path = Path::new(ISOLATED_PAIRING_LOGIN_KEYCHAIN);
        let metadata = fs::symlink_metadata(path)?;
        let proof = IsolatedPairingKeychainMetadataProof {
            is_regular_file: metadata.file_type().is_file(),
            is_symlink: metadata.file_type().is_symlink(),
            uid: metadata.uid(),
            gid: metadata.gid(),
            nlink: metadata.nlink(),
            mode: metadata.permissions().mode() & 0o7777,
        };
        if !isolated_pairing_keychain_metadata_is_exact(proof) {
            return Err(ControllerError(format!(
                "isolated pairing login Keychain has unsafe metadata: {}",
                path.display()
            )));
        }
        Ok(())
    }

    fn verify_isolated_pairing_items_present() -> Result<()> {
        require_root_owned_system_executable(Path::new("/usr/bin/security"))?;
        require_isolated_pairing_login_keychain()?;
        for account in [
            ISOLATED_PAIRING_IDENTITY_ACCOUNT,
            ISOLATED_PAIRING_VIEWER_ACCOUNT,
        ] {
            let output = command_output(
                "/usr/bin/security",
                &[
                    "find-generic-password",
                    "-s",
                    ISOLATED_PAIRING_SERVICE,
                    "-a",
                    account,
                    ISOLATED_PAIRING_LOGIN_KEYCHAIN,
                ],
                None,
            )?;
            if !output.status.success() {
                return Err(ControllerError(format!(
                    "isolated pairing item is absent or inaccessible: account={account} status={}",
                    output.status
                )));
            }
        }
        Ok(())
    }

    fn require_root_owned_system_executable(path: &Path) -> Result<()> {
        let metadata = fs::symlink_metadata(path)?;
        if !metadata.file_type().is_file()
            || metadata.file_type().is_symlink()
            || metadata.uid() != 0
            || metadata.nlink() != 1
            || metadata.permissions().mode() & 0o777 != 0o755
        {
            return Err(ControllerError(format!(
                "system executable has unsafe metadata: {}",
                path.display()
            )));
        }
        Ok(())
    }

    fn verify_paired_v7_runtime() -> Result<LaunchGeneration> {
        verify_committed_v6_baseline()?;
        verify_protected_legacy_absent()?;
        verify_reviewed_launch_agent_unchanged()?;
        verify_current_baseline_app_at(Path::new(NEW_APP), true)?;
        let launch = read_loaded_launch_state()?;
        require_solo_capture_server(Path::new(NEW_EXECUTABLE), launch.pid)?;
        let (lock_device, lock_inode, nonce) = read_generation_lock(launch.pid)?;
        prove_lock_holder(launch.pid, Duration::from_secs(4))?;
        let generation = LaunchGeneration {
            pid: launch.pid,
            runs: launch.runs,
            process_start: process_start(launch.pid)?,
            nonce,
            lock_device,
            lock_inode,
        };
        thread::sleep(Duration::from_millis(500));
        let second = read_loaded_launch_state()?;
        let (second_device, second_inode, second_nonce) = read_generation_lock(generation.pid)?;
        if second.pid != generation.pid
            || second.runs != generation.runs
            || process_start(generation.pid)? != generation.process_start
            || second_device != generation.lock_device
            || second_inode != generation.lock_inode
            || second_nonce != generation.nonce
        {
            return Err(ControllerError(
                "current isolated launch generation changed during preflight".to_owned(),
            ));
        }
        prove_lock_holder(generation.pid, Duration::from_secs(4))?;
        Ok(generation)
    }

    fn verify_paired_v7_git_provenance(repo: &Path, require_remote: bool) -> Result<Provenance> {
        let status = command_output(
            "/usr/bin/git",
            &["status", "--porcelain=v1", "--untracked-files=all"],
            Some(repo),
        )?;
        require_output_success(&status, "inspect paired-v7 git worktree")?;
        if !status.stdout.is_empty() {
            return Err(ControllerError(
                "repository must be completely clean before a paired-v7 host update".to_owned(),
            ));
        }
        let commit = command_line("/usr/bin/git", &["rev-parse", "HEAD"], Some(repo))?;
        let tree = command_line("/usr/bin/git", &["rev-parse", "HEAD^{tree}"], Some(repo))?;
        require_canonical_git_oid(&commit, "current commit")?;
        require_canonical_git_oid(&tree, "current tree")?;
        let remote = command_line(
            "/usr/bin/git",
            &["config", "--get", "remote.origin.url"],
            Some(repo),
        )?;
        if remote != EXPECTED_REMOTE {
            return Err(ControllerError(
                "origin remote differs from the reviewed repository".to_owned(),
            ));
        }
        let ancestry = command_output(
            "/usr/bin/git",
            &[
                "merge-base",
                "--is-ancestor",
                REQUIRED_REPO_OWNED_DRIVER_PATCH_COMMIT,
                &commit,
            ],
            Some(repo),
        )?;
        require_output_success(
            &ancestry,
            "verify required repo-owned driver patch ancestry",
        )?;
        if require_remote {
            let output = command_output(
                "/usr/bin/git",
                &[
                    "ls-remote",
                    "--heads",
                    "origin",
                    &format!("refs/heads/{EXPECTED_SOURCE_BRANCH}"),
                ],
                Some(repo),
            )?;
            require_output_success(&output, "verify pushed paired-v7 source commit")?;
            let text = decode_utf8(&output.stdout, "paired-v7 git ls-remote output")?;
            let records: Vec<&str> = text.lines().collect();
            let expected_ref = format!("refs/heads/{EXPECTED_SOURCE_BRANCH}");
            if records.len() != 1 {
                return Err(ControllerError(
                    "paired-v7 source branch is absent or ambiguous on origin".to_owned(),
                ));
            }
            let mut fields = records[0].split('\t');
            if fields.next() != Some(commit.as_str())
                || fields.next() != Some(expected_ref.as_str())
                || fields.next().is_some()
            {
                return Err(ControllerError(
                    "origin paired-v7 source branch does not resolve to local HEAD".to_owned(),
                ));
            }
        }
        Ok(Provenance {
            commit,
            tree,
            upstream: format!("origin/{EXPECTED_SOURCE_BRANCH}"),
            remote,
        })
    }

    fn require_authorized_provenance(
        provenance: &Provenance,
        authorized_commit: &str,
        authorized_tree: &str,
    ) -> Result<()> {
        require_canonical_git_oid(authorized_commit, "authorized commit")?;
        require_canonical_git_oid(authorized_tree, "authorized tree")?;
        if provenance.commit != authorized_commit || provenance.tree != authorized_tree {
            return Err(ControllerError(format!(
                "current clean pushed provenance differs from the explicitly authorized commit/tree: current_commit={} current_tree={} authorized_commit={} authorized_tree={}",
                provenance.commit, provenance.tree, authorized_commit, authorized_tree
            )));
        }
        Ok(())
    }

    fn wait_for_paired_v7_launch_generation(timeout: Duration) -> Result<LaunchGeneration> {
        wait_for_launch_generation(timeout)
    }

    fn bootout_paired_v7_job_if_loaded(layout: &V7Layout) -> Result<()> {
        let state = command_output(
            "/bin/launchctl",
            &["print", &format!("gui/{USER_ID}/{NEW_LAUNCH_AGENT_LABEL}")],
            None,
        )?;
        if state.status.success() {
            let loaded = parse_loaded_launch_job(decode_utf8(
                &state.stdout,
                "paired-v7 rollback launchctl state",
            )?)?;
            let expected_start = if let Some(pid) = loaded.pid {
                require_solo_capture_server(Path::new(NEW_EXECUTABLE), pid)?;
                if verify_current_baseline_app_at(Path::new(NEW_APP), true).is_ok() {
                    verify_live_canonical_process(
                        Path::new(CURRENT_BASELINE_SOURCE_EXPORT),
                        pid,
                        Path::new(CURRENT_BASELINE_APP),
                    )?;
                } else {
                    verify_v7_installed_matches_reference(layout)?;
                    verify_live_canonical_process(
                        &layout.source_export,
                        pid,
                        &layout.deployment_reference_app,
                    )?;
                }
                Some(process_start(pid)?)
            } else {
                require_no_capture_servers()?;
                None
            };
            let output = command_output(
                "/bin/launchctl",
                &[
                    "bootout",
                    &format!("gui/{USER_ID}/{NEW_LAUNCH_AGENT_LABEL}"),
                ],
                None,
            )?;
            require_output_success(&output, "boot out paired-v7 LaunchAgent during rollback")?;
            wait_for_new_job_bootout(&loaded, expected_start.as_deref(), Duration::from_secs(30))?;
        } else {
            require_service_absent(NEW_LAUNCH_AGENT_LABEL)?;
        }
        Ok(())
    }

    fn verify_live_canonical_process(
        verifier_root: &Path,
        pid: u32,
        signed_reference_app: &Path,
    ) -> Result<()> {
        if verifier_root == Path::new(CURRENT_BASELINE_SOURCE_EXPORT) {
            verify_current_baseline_oracle_pins()?;
        }
        let verifier = verifier_root.join("macOS/scripts/verify-live-mac-host-process.sh");
        require_regular(&verifier, SOURCE_EXPORT_EXECUTABLE_MODE)?;
        let reference_executable = signed_reference_app.join("Contents/MacOS/CaptureServer");
        let expected_cdhash = code_hash(&reference_executable)?;
        let output = command_output(
            path_text(&verifier)?,
            &[
                &pid.to_string(),
                NEW_EXECUTABLE,
                &expected_cdhash,
                EXPECTED_IDENTIFIER,
                EXPECTED_TEAM_ID,
                "/Applications/opensteamer Host.app/Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC",
            ],
            Some(verifier_root),
        )?;
        require_output_success(&output, "verify canonical paired-v7 host mapped code")
    }

    fn require_v7_install_hold_layout(root: &Path, app: &Path) -> Result<()> {
        if root.parent() != Some(Path::new("/Applications"))
            || !root
                .file_name()
                .and_then(|value| value.to_str())
                .is_some_and(|value| {
                    value.starts_with(HIDDEN_INSTALL_PREFIX)
                        && value.len() > HIDDEN_INSTALL_PREFIX.len()
                        && value.len() < 160
                })
            || app.parent() != Some(root)
            || app.file_name().and_then(|value| value.to_str()) != Some("opensteamer Host.app")
        {
            return Err(ControllerError(format!(
                "paired-v7 install hold escaped its reviewed layout: {}",
                app.display()
            )));
        }
        Ok(())
    }

    fn publish_v7_active_pointer(evidence: &Path) -> Result<()> {
        require_current_retry_v7_layout(
            evidence,
            None,
            RetryV7PointerExpectation::Absent,
        )?;
        let pending = PathBuf::from(format!("{V7_ACTIVE_UPDATE}.pending-{}", std::process::id()));
        require_path_absent(&pending, "pending paired-v7 pointer")?;
        require_path_absent(Path::new(V7_ACTIVE_UPDATE), "active paired-v7 pointer")?;
        let mut file = create_new_private(&pending)?;
        writeln!(file, "{}", evidence.display())?;
        file.sync_all()?;
        rename_exclusive(&pending, Path::new(V7_ACTIVE_UPDATE))?;
        fsync_parent(Path::new(V7_ACTIVE_UPDATE))?;
        require_current_retry_v7_layout(
            evidence,
            None,
            RetryV7PointerExpectation::Present,
        )
    }

    fn verify_v7_active_pointer(expected_evidence: &Path) -> Result<()> {
        require_current_retry_v7_layout(
            expected_evidence,
            None,
            RetryV7PointerExpectation::Present,
        )
    }

    fn retire_v7_active_pointer(layout: &V7Layout) -> Result<()> {
        let pointer_expectation = if path_exists_without_follow(Path::new(V7_ACTIVE_UPDATE))? {
            RetryV7PointerExpectation::Present
        } else {
            RetryV7PointerExpectation::Absent
        };
        require_current_retry_v7_layout(
            &layout.evidence,
            Some(&layout.nonce),
            pointer_expectation,
        )?;
        retire_update_pointer_at(
            Path::new(V7_ACTIVE_UPDATE),
            &layout.evidence,
            Path::new(V7_UPDATE_ROOT),
        )?;
        require_current_retry_v7_layout(
            &layout.evidence,
            Some(&layout.nonce),
            RetryV7PointerExpectation::Absent,
        )
    }

    fn path_exists_without_follow(path: &Path) -> Result<bool> {
        match fs::symlink_metadata(path) {
            Ok(_) => Ok(true),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(error) => Err(error.into()),
        }
    }

    fn parse_v7_journal(text: &str) -> Result<V7State> {
        let mut lines = text.lines();
        if lines.next() != Some(V7_JOURNAL_HEADER) {
            return Err(ControllerError(
                "paired-v7 journal header is malformed".to_owned(),
            ));
        }
        let mut state = None;
        for line in lines {
            let mut fields = line.split(' ');
            if fields.next() != Some("STATE") {
                return Err(ControllerError(
                    "paired-v7 journal record is malformed".to_owned(),
                ));
            }
            let next = fields
                .next()
                .and_then(V7State::parse)
                .ok_or_else(|| ControllerError("paired-v7 journal state is unknown".to_owned()))?;
            if let Some(previous) = state {
                validate_v7_transition(previous, next)?;
            } else if next != V7State::Begun {
                return Err(ControllerError(
                    "paired-v7 journal does not begin at BEGUN".to_owned(),
                ));
            }
            let fields: Vec<&str> = fields.collect();
            let expected = v7_field_schema(next);
            if fields.len() != expected.len() {
                return Err(ControllerError(
                    "paired-v7 journal field count is invalid".to_owned(),
                ));
            }
            for (field, expected_key) in fields.into_iter().zip(expected) {
                let (key, value) = field.split_once('=').ok_or_else(|| {
                    ControllerError("paired-v7 journal field is malformed".to_owned())
                })?;
                if key != *expected_key || !is_safe_journal_value(value) {
                    return Err(ControllerError(
                        "paired-v7 journal field is unsafe".to_owned(),
                    ));
                }
            }
            state = Some(next);
        }
        state.ok_or_else(|| ControllerError("paired-v7 journal has no state".to_owned()))
    }

    fn v7_field_schema(state: V7State) -> &'static [&'static str] {
        match state {
            V7State::Begun
            | V7State::InstallHoldVerified
            | V7State::DriverPrepared
            | V7State::CurrentStopped
            | V7State::CurrentHeld
            | V7State::DriverPublished
            | V7State::ProbesVerified
            | V7State::NewPublished
            | V7State::PersistentBootstrapped
            | V7State::Committed
            | V7State::RollbackStarted
            | V7State::DriverRestored
            | V7State::FailedNewArchived
            | V7State::CurrentRestored
            | V7State::CurrentBootstrapped
            | V7State::RolledBack => &[],
            V7State::SourceExported => &["commit", "tree", "initial_pid"],
            V7State::BuildVerified => &["executable_sha256"],
            V7State::StopInitiated => &["reserve_device", "reserve_inode", "reserve_bytes"],
            V7State::ReadyVerified => &["pid", "runs", "nonce"],
            V7State::CriticalFailure => &["phase"],
        }
    }

    fn validate_v7_fields(state: V7State, fields: &[(&str, String)]) -> Result<()> {
        let expected = v7_field_schema(state);
        if fields.len() != expected.len() {
            return Err(ControllerError(
                "paired-v7 journal record has wrong field count".to_owned(),
            ));
        }
        for ((key, value), expected_key) in fields.iter().zip(expected) {
            if *key != *expected_key || !is_safe_journal_value(value) {
                return Err(ControllerError("unsafe paired-v7 journal field".to_owned()));
            }
        }
        Ok(())
    }

    fn validate_v7_transition(previous: V7State, next: V7State) -> Result<()> {
        if previous == V7State::Begun && next == V7State::Begun {
            return Ok(());
        }
        let forward = matches!(
            (previous, next),
            (V7State::Begun, V7State::SourceExported)
                | (V7State::SourceExported, V7State::BuildVerified)
                | (V7State::BuildVerified, V7State::InstallHoldVerified)
                | (V7State::InstallHoldVerified, V7State::DriverPrepared)
                | (V7State::DriverPrepared, V7State::StopInitiated)
                | (V7State::StopInitiated, V7State::CurrentStopped)
                | (V7State::CurrentStopped, V7State::CurrentHeld)
                | (V7State::CurrentHeld, V7State::DriverPublished)
                | (V7State::DriverPublished, V7State::ProbesVerified)
                | (V7State::ProbesVerified, V7State::NewPublished)
                | (V7State::NewPublished, V7State::PersistentBootstrapped)
                | (V7State::PersistentBootstrapped, V7State::ReadyVerified)
                | (V7State::ReadyVerified, V7State::Committed)
        );
        let rollback_entry = next == V7State::RollbackStarted
            && ((previous >= V7State::StopInitiated && previous <= V7State::Committed)
                || previous == V7State::CriticalFailure)
            && previous != V7State::RollbackStarted;
        let rollback = matches!(
            (previous, next),
            (V7State::RollbackStarted, V7State::DriverRestored)
                | (V7State::DriverRestored, V7State::FailedNewArchived)
                | (V7State::DriverRestored, V7State::CurrentRestored)
                | (V7State::DriverRestored, V7State::RolledBack)
                | (V7State::FailedNewArchived, V7State::CurrentRestored)
                | (V7State::CurrentRestored, V7State::CurrentBootstrapped)
                | (V7State::CurrentBootstrapped, V7State::RolledBack)
        );
        let critical = next == V7State::CriticalFailure
            && previous >= V7State::RollbackStarted
            && previous < V7State::RolledBack;
        if forward || rollback_entry || rollback || critical {
            Ok(())
        } else {
            Err(ControllerError(format!(
                "invalid paired-v7 journal transition: {} -> {}",
                previous.token(),
                next.token()
            )))
        }
    }

    const ALL_V7_STATES: [V7State; 21] = [
        V7State::Begun,
        V7State::SourceExported,
        V7State::BuildVerified,
        V7State::InstallHoldVerified,
        V7State::DriverPrepared,
        V7State::StopInitiated,
        V7State::CurrentStopped,
        V7State::CurrentHeld,
        V7State::DriverPublished,
        V7State::ProbesVerified,
        V7State::NewPublished,
        V7State::PersistentBootstrapped,
        V7State::ReadyVerified,
        V7State::Committed,
        V7State::RollbackStarted,
        V7State::DriverRestored,
        V7State::FailedNewArchived,
        V7State::CurrentRestored,
        V7State::CurrentBootstrapped,
        V7State::RolledBack,
        V7State::CriticalFailure,
    ];

    fn is_plausible_v7_torn_tail(tail: &[u8], previous: V7State) -> bool {
        if tail.is_empty() || tail.len() > 4_096 || tail.contains(&b'\n') || tail.contains(&b'\r') {
            return false;
        }
        let Ok(tail) = std::str::from_utf8(tail) else {
            return false;
        };
        ALL_V7_STATES
            .iter()
            .copied()
            .filter(|next| validate_v7_transition(previous, *next).is_ok())
            .any(|next| is_plausible_v7_record_prefix(tail, next))
    }

    fn is_plausible_v7_record_prefix(tail: &str, state: V7State) -> bool {
        let state_prefix = format!("STATE {}", state.token());
        if tail.len() <= state_prefix.len() {
            return state_prefix.starts_with(tail);
        }
        if !tail.starts_with(&state_prefix) {
            return false;
        }
        let Some(fields_text) = tail[state_prefix.len()..].strip_prefix(' ') else {
            return false;
        };
        let expected = v7_field_schema(state);
        if expected.is_empty() {
            return false;
        }
        let fields: Vec<&str> = fields_text.split(' ').collect();
        if fields.len() > expected.len() {
            return false;
        }
        for (index, (field, expected_key)) in fields.iter().zip(expected).enumerate() {
            let expected_prefix = format!("{expected_key}=");
            let last = index + 1 == fields.len();
            if field.len() <= expected_prefix.len() {
                return last && expected_prefix.starts_with(field);
            }
            let Some(value) = field.strip_prefix(&expected_prefix) else {
                return false;
            };
            if !value.bytes().all(|byte| {
                byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-' | b':' | b'/')
            }) || (value.is_empty() && !last)
            {
                return false;
            }
        }
        true
    }

    fn paired_v7_self_test() -> Result<()> {
        verify_v7_cli_surface()?;
        self_test_controller_binary_identity_binding()?;
        self_test_production_identity_parser()?;
        self_test_installer_signature_parser()?;
        self_test_isolated_pairing_keychain_metadata_contract()?;
        self_test_detached_crash_matrix()?;
        for state in [
            V7State::StopInitiated,
            V7State::DriverPublished,
            V7State::ReadyVerified,
            V7State::RollbackStarted,
            V7State::DriverRestored,
            V7State::CurrentBootstrapped,
            V7State::CriticalFailure,
        ] {
            if !v7_crossed_stop_without_durable_commit(state) {
                return Err(ControllerError(format!(
                    "paired-v7 stop-boundary model rejected {}",
                    state.token()
                )));
            }
        }
        for state in [
            V7State::Begun,
            V7State::DriverPrepared,
            V7State::Committed,
            V7State::RolledBack,
        ] {
            if v7_crossed_stop_without_durable_commit(state) {
                return Err(ControllerError(format!(
                    "paired-v7 stop-boundary model accepted {}",
                    state.token()
                )));
            }
        }
        let valid = format!(
            "{V7_JOURNAL_HEADER}\nSTATE BEGUN\nSTATE SOURCE_EXPORTED commit={} tree={} initial_pid=41\nSTATE BUILD_VERIFIED executable_sha256={}\nSTATE INSTALL_HOLD_VERIFIED\nSTATE DRIVER_PREPARED\nSTATE STOP_INITIATED reserve_device=1 reserve_inode=2 reserve_bytes=8388608\nSTATE CURRENT_STOPPED\nSTATE CURRENT_HELD\nSTATE DRIVER_PUBLISHED\nSTATE PROBES_VERIFIED\nSTATE NEW_PUBLISHED\nSTATE PERSISTENT_BOOTSTRAPPED\nSTATE READY_VERIFIED pid=42 runs=1 nonce={}\nSTATE COMMITTED\n",
            "a".repeat(40),
            "b".repeat(40),
            "c".repeat(64),
            "d".repeat(64),
        );
        if parse_v7_journal(&valid)? != V7State::Committed {
            return Err(ControllerError(
                "paired-v7 committed journal parser self-test failed".to_owned(),
            ));
        }
        let rolled_back = format!(
            "{V7_JOURNAL_HEADER}\nSTATE BEGUN\nSTATE SOURCE_EXPORTED commit={} tree={} initial_pid=41\nSTATE BUILD_VERIFIED executable_sha256={}\nSTATE INSTALL_HOLD_VERIFIED\nSTATE DRIVER_PREPARED\nSTATE STOP_INITIATED reserve_device=1 reserve_inode=2 reserve_bytes=8388608\nSTATE CURRENT_STOPPED\nSTATE CURRENT_HELD\nSTATE DRIVER_PUBLISHED\nSTATE ROLLBACK_STARTED\nSTATE DRIVER_RESTORED\nSTATE FAILED_NEW_ARCHIVED\nSTATE CURRENT_RESTORED\nSTATE CURRENT_BOOTSTRAPPED\nSTATE ROLLED_BACK\n",
            "a".repeat(40),
            "b".repeat(40),
            "c".repeat(64),
        );
        if parse_v7_journal(&rolled_back)? != V7State::RolledBack {
            return Err(ControllerError(
                "paired-v7 rollback journal parser self-test failed".to_owned(),
            ));
        }
        if parse_v7_journal(&format!(
            "{V7_JOURNAL_HEADER}\nSTATE BEGUN\nSTATE NEW_PUBLISHED\n"
        ))
        .is_ok()
        {
            return Err(ControllerError(
                "paired-v7 journal parser accepted a skipped transition".to_owned(),
            ));
        }
        let hold_root = Path::new("/Applications/.opensteamer-paired-v7-install-selftest");
        let hold_app = hold_root.join("opensteamer Host.app");
        require_v7_install_hold_layout(hold_root, &hold_app)?;
        if require_v7_install_hold_layout(
            Path::new("/Applications/opensteamer Host.app"),
            &hold_app,
        )
        .is_ok()
            || require_v7_install_hold_layout(hold_root, &hold_root.join("unreviewed Host.app"))
                .is_ok()
        {
            return Err(ControllerError(
                "paired-v7 install-hold layout self-test failed".to_owned(),
            ));
        }
        paired_v7_dynamic_self_test()?;
        println!("SELF_TEST_OK paired-v7-host-update-controller");
        Ok(())
    }

    fn self_test_controller_binary_identity_binding() -> Result<()> {
        let sealed = ControllerBinaryIdentity {
            device: 1,
            inode: 2,
            length: 3,
            sha256: "a".repeat(64),
        };
        require_root_controller_identity_binding(&sealed, &sealed)?;
        require_proxy_controller_identity_binding(&sealed, &sealed)?;

        let caller_supplied_digest = ControllerBinaryIdentity {
            sha256: "b".repeat(64),
            ..sealed.clone()
        };
        if require_root_controller_identity_binding(&caller_supplied_digest, &sealed).is_ok()
            || require_proxy_controller_identity_binding(&caller_supplied_digest, &sealed).is_ok()
        {
            return Err(ControllerError(
                "controller identity accepted an unanchored caller digest".to_owned(),
            ));
        }
        let replaced_root_inode = ControllerBinaryIdentity {
            inode: sealed.inode + 1,
            ..sealed.clone()
        };
        if require_root_controller_identity_binding(&replaced_root_inode, &sealed).is_ok() {
            return Err(ControllerError(
                "root controller identity accepted a replaced inode".to_owned(),
            ));
        }
        let journal = controller_identity_journal(&sealed);
        if parse_controller_identity_journal(&journal)? != sealed
            || parse_controller_identity_journal(
                &journal.replace("controller_sha256=", "caller_sha256="),
            )
            .is_ok()
        {
            return Err(ControllerError(
                "root controller identity journal parser accepted a caller-hash mutant"
                    .to_owned(),
            ));
        }
        Ok(())
    }

    fn verify_v7_cli_surface() -> Result<()> {
        let executable = "controller".to_owned();
        let repo = V7_EXPECTED_REPO.to_owned();
        let authorized_commit = "a".repeat(40);
        let authorized_tree = "b".repeat(40);
        let allowed = [
            vec![
                executable.clone(),
                V7_PREFLIGHT_MODE.to_owned(),
                repo.clone(),
            ],
            vec![
                executable.clone(),
                V7_EXECUTE_MODE.to_owned(),
                repo.clone(),
                authorized_commit.clone(),
                authorized_tree.clone(),
            ],
            vec![
                executable.clone(),
                V7_ROLLBACK_MODE.to_owned(),
                repo.clone(),
            ],
            vec![executable.clone(), V7_SELF_TEST_MODE.to_owned()],
            vec![
                executable.clone(),
                PROBE_LOCK_MODE.to_owned(),
                LOCK_DIRECTORY.to_owned(),
                LOCK_FILE.to_owned(),
                "1".to_owned(),
            ],
        ];
        if !matches!(parse_v7_command(&allowed[0]), Ok(V7Command::Preflight(_)))
            || !matches!(parse_v7_command(&allowed[1]), Ok(V7Command::Execute { .. }))
            || !matches!(parse_v7_command(&allowed[2]), Ok(V7Command::Rollback(_)))
            || !matches!(parse_v7_command(&allowed[3]), Ok(V7Command::SelfTest))
            || !matches!(
                parse_v7_command(&allowed[4]),
                Ok(V7Command::ProbeLock { .. })
            )
        {
            return Err(ControllerError(
                "paired-v7 CLI rejected a reviewed command shape".to_owned(),
            ));
        }

        let nonce = "11111111-1111-1111-1111-111111111111";
        let staged_root =
            format!("{V7_UPDATE_ROOT}/paired-v7-update-1-1-{nonce}/production-driver-v7");
        let staged_driver = format!("{staged_root}/{PRODUCT_DRIVER_NAME}");
        let staged_package = format!("{staged_root}/OpensteamerVirtualMicrophone-v7.pkg");
        let retry_evidence =
            format!("{V7_UPDATE_ROOT}/paired-v7-update-retry-2-1-41-{nonce}");
        let parent_start_sha256 = "e".repeat(64);
        let internal = [
            vec![
                executable.clone(),
                ROOT_V7_CONTROLLER_BOOTSTRAP_MODE.to_owned(),
            ],
            vec![
                executable.clone(),
                "--root-driver-broker-v7".to_owned(),
                nonce.to_owned(),
                staged_driver.clone(),
                staged_package.clone(),
            ],
            vec![
                executable.clone(),
                "--uid501-driver-broker-proxy-v7".to_owned(),
                nonce.to_owned(),
                staged_driver.clone(),
                staged_package.clone(),
                "41".to_owned(),
                parent_start_sha256.clone(),
            ],
            vec![
                executable.clone(),
                "--root-driver-restore-broker-v7".to_owned(),
                nonce.to_owned(),
            ],
            vec![
                executable.clone(),
                "--uid501-driver-restore-proxy-v7".to_owned(),
                nonce.to_owned(),
                retry_evidence.clone(),
                RetryV7PointerExpectation::Absent.token().to_owned(),
                "41".to_owned(),
                parent_start_sha256.clone(),
            ],
        ];
        if !matches!(
            parse_v7_command(&internal[0]),
            Ok(V7Command::RootControllerBootstrap)
        ) || !matches!(
            parse_v7_command(&internal[1]),
            Ok(V7Command::RootDriverBroker { .. })
        ) || !matches!(
            parse_v7_command(&internal[2]),
            Ok(V7Command::UIDDriverBrokerProxy { .. })
        ) || !matches!(
            parse_v7_command(&internal[3]),
            Ok(V7Command::RootDriverRestoreBroker { .. })
        ) || !matches!(
            parse_v7_command(&internal[4]),
            Ok(V7Command::UIDDriverRestoreProxy { .. })
        ) {
            return Err(ControllerError(
                "paired-v7 CLI rejected an exact internal broker shape".to_owned(),
            ));
        }

        let malformed = [
            vec![executable.clone(), V7_PREFLIGHT_MODE.to_owned()],
            vec![executable.clone(), V7_EXECUTE_MODE.to_owned(), repo.clone()],
            vec![
                executable.clone(),
                V7_EXECUTE_MODE.to_owned(),
                repo.clone(),
                "A".repeat(40),
                authorized_tree.clone(),
            ],
            vec![
                executable.clone(),
                V7_EXECUTE_MODE.to_owned(),
                repo.clone(),
                "a".repeat(39),
                authorized_tree.clone(),
            ],
            vec![
                executable.clone(),
                V7_EXECUTE_MODE.to_owned(),
                repo.clone(),
                authorized_commit.clone(),
                format!("{}g", "b".repeat(39)),
            ],
            vec![
                executable.clone(),
                V7_SELF_TEST_MODE.to_owned(),
                repo.clone(),
            ],
            vec![
                executable.clone(),
                PROBE_LOCK_MODE.to_owned(),
                LOCK_DIRECTORY.to_owned(),
                LOCK_FILE.to_owned(),
            ],
            vec![
                executable.clone(),
                "--root-driver-restore-existing-v7".to_owned(),
                nonce.to_owned(),
            ],
            vec![
                executable.clone(),
                ROOT_V7_CONTROLLER_BOOTSTRAP_MODE.to_owned(),
                "a".repeat(64),
            ],
            vec![
                executable.clone(),
                "--root-driver-broker-v7".to_owned(),
                nonce.to_owned(),
                staged_driver.clone(),
                staged_package.clone(),
                "/tmp/user-controlled-verifier".to_owned(),
            ],
            vec![
                executable.clone(),
                "--uid501-driver-broker-proxy-v7".to_owned(),
                nonce.to_owned(),
                staged_driver.clone(),
                staged_package.clone(),
                "41".to_owned(),
                "E".repeat(64),
            ],
            vec![
                executable.clone(),
                "--uid501-driver-restore-proxy-v7".to_owned(),
                nonce.to_owned(),
                retry_evidence.clone(),
                "unknown".to_owned(),
                "41".to_owned(),
                parent_start_sha256.clone(),
            ],
            vec![
                executable.clone(),
                "--uid501-driver-restore-proxy-v7".to_owned(),
                nonce.to_owned(),
                retry_evidence,
                RetryV7PointerExpectation::Present.token().to_owned(),
                "0".to_owned(),
                parent_start_sha256.clone(),
            ],
        ];
        if malformed
            .iter()
            .any(|arguments| parse_v7_command(arguments).is_ok())
        {
            return Err(ControllerError(
                "paired-v7 CLI accepted an unreviewed command shape".to_owned(),
            ));
        }

        let provenance = Provenance {
            commit: authorized_commit.clone(),
            tree: authorized_tree.clone(),
            upstream: format!("origin/{EXPECTED_SOURCE_BRANCH}"),
            remote: EXPECTED_REMOTE.to_owned(),
        };
        require_authorized_provenance(&provenance, &authorized_commit, &authorized_tree)?;
        if require_authorized_provenance(&provenance, &"c".repeat(40), &authorized_tree).is_ok()
            || require_authorized_provenance(&provenance, &authorized_commit, &"d".repeat(40))
                .is_ok()
        {
            return Err(ControllerError(
                "paired-v7 authorization binding accepted a mismatched commit or tree".to_owned(),
            ));
        }

        for encoded_mode in [
            "2d2d7665726966792d706f73742d7632302d686f73742d7570646174652d707265666c69676874",
            "2d2d657865637574652d617574686f72697a65642d706f73742d7632302d686f73742d757064617465",
            "2d2d726f6c6c6261636b2d617574686f72697a65642d706f73742d7632302d686f73742d757064617465",
            "2d2d73656c662d746573742d706f73742d7632302d686f73742d757064617465",
            "2d2d657865637574652d617574686f72697a65642d706f73742d7632302d686f73742d7570646174652d776974682d72657669657765642d7072656275696c74",
            "2d2d7665726966792d7061697265642d76352d686f73742d7570646174652d707265666c69676874",
            "2d2d657865637574652d617574686f72697a65642d7061697265642d76352d686f73742d757064617465",
            "2d2d726f6c6c6261636b2d617574686f72697a65642d7061697265642d76352d686f73742d757064617465",
            "2d2d73656c662d746573742d7061697265642d76352d686f73742d757064617465",
        ] {
            let mode = String::from_utf8(decode_marker_hex(encoded_mode)?).map_err(|_| {
                ControllerError("paired-v7 CLI test mode is not UTF-8".to_owned())
            })?;
            let arguments = vec![executable.clone(), mode, repo.clone()];
            if parse_v7_command(&arguments).is_ok() {
                return Err(ControllerError(
                    "paired-v7 CLI exposed an inherited update mode".to_owned(),
                ));
            }
        }
        Ok(())
    }

    fn self_test_production_identity_parser() -> Result<()> {
        let app = format!(
            "  1) {} \"Developer ID Application: Reviewed ({})\"\n",
            EXPECTED_DEVELOPER_ID_APPLICATION_SHA1, EXPECTED_DRIVER_TEAM_ID,
        );
        let installer = format!(
            "  2) {} \"Developer ID Installer: Reviewed ({})\"\n",
            EXPECTED_DEVELOPER_ID_INSTALLER_IDENTITY_SHA1, EXPECTED_DRIVER_TEAM_ID,
        );
        let healthy = format!("{app}{installer}     2 valid identities found\n");
        if count_exact_production_identity(
            &healthy,
            EXPECTED_DEVELOPER_ID_APPLICATION_SHA1,
            "Developer ID Application",
        ) != 1
            || count_exact_production_identity(
                &healthy,
                EXPECTED_DEVELOPER_ID_INSTALLER_IDENTITY_SHA1,
                "Developer ID Installer",
            ) != 1
        {
            return Err(ControllerError(
                "production signing identity fixture was rejected".to_owned(),
            ));
        }
        for mutant in [
            app.replace(EXPECTED_DRIVER_TEAM_ID, "AAAAAAAAAA"),
            app.replace("Developer ID Application:", "Apple Development:"),
            app.replace(
                EXPECTED_DEVELOPER_ID_APPLICATION_SHA1,
                "0000000000000000000000000000000000000000",
            ),
            format!("{app}{app}"),
        ] {
            if count_exact_production_identity(
                &mutant,
                EXPECTED_DEVELOPER_ID_APPLICATION_SHA1,
                "Developer ID Application",
            ) == 1
            {
                return Err(ControllerError(
                    "production signing identity parser accepted a mutant".to_owned(),
                ));
            }
        }
        Ok(())
    }

    fn self_test_installer_signature_parser() -> Result<()> {
        const STATUS: &str =
            "Status: signed by a developer certificate issued by Apple for distribution";
        const FINGERPRINT: &str =
            "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF";
        let fingerprint_lines = format!("{} {}", &FINGERPRINT[..32], &FINGERPRINT[32..]);
        let healthy = format!(
            "Package fixture:\n   {STATUS}\n   Certificate Chain:\n    1. Developer ID Installer: Reviewed ({EXPECTED_DRIVER_TEAM_ID})\n       SHA256 Fingerprint:\n           {fingerprint_lines}\n    2. Developer ID Certification Authority\n",
        );
        if parse_installer_leaf_sha256(&healthy)? != FINGERPRINT {
            return Err(ControllerError(
                "installer signature parser rejected the current pkgutil status".to_owned(),
            ));
        }

        let mutants = [
            healthy.replace(
                STATUS,
                "Status: signed by a certificate trusted by Mac OS X",
            ),
            healthy.replace(STATUS, &format!("{STATUS} (trusted)")),
            healthy.replace(STATUS, &format!("{STATUS}\n   {STATUS}")),
            healthy.replace(EXPECTED_DRIVER_TEAM_ID, "AAAAAAAAAA"),
            healthy.replace("Developer ID Installer:", "Developer ID Application:"),
            healthy.replace(&fingerprint_lines, "01234567"),
            format!(
                "{healthy}    1. Developer ID Installer: Duplicate ({EXPECTED_DRIVER_TEAM_ID})\n"
            ),
        ];
        for mutant in mutants {
            if parse_installer_leaf_sha256(&mutant).is_ok() {
                return Err(ControllerError(
                    "installer signature parser accepted a status or identity mutant".to_owned(),
                ));
            }
        }
        Ok(())
    }

    fn self_test_isolated_pairing_keychain_metadata_contract() -> Result<()> {
        let exact = IsolatedPairingKeychainMetadataProof {
            is_regular_file: true,
            is_symlink: false,
            uid: USER_ID,
            gid: ISOLATED_PAIRING_LOGIN_KEYCHAIN_GID,
            nlink: 1,
            mode: ISOLATED_PAIRING_LOGIN_KEYCHAIN_MODE,
        };
        if !isolated_pairing_keychain_metadata_is_exact(exact) {
            return Err(ControllerError(
                "exact uid501 login Keychain metadata fixture was rejected".to_owned(),
            ));
        }
        for mutant in [
            IsolatedPairingKeychainMetadataProof {
                is_regular_file: false,
                ..exact
            },
            IsolatedPairingKeychainMetadataProof {
                is_symlink: true,
                ..exact
            },
            IsolatedPairingKeychainMetadataProof { uid: 0, ..exact },
            IsolatedPairingKeychainMetadataProof { gid: 0, ..exact },
            IsolatedPairingKeychainMetadataProof { nlink: 2, ..exact },
            IsolatedPairingKeychainMetadataProof {
                mode: 0o600,
                ..exact
            },
            IsolatedPairingKeychainMetadataProof {
                mode: 0o4644,
                ..exact
            },
        ] {
            if isolated_pairing_keychain_metadata_is_exact(mutant) {
                return Err(ControllerError(
                    "uid501 login Keychain metadata contract accepted a mutant".to_owned(),
                ));
            }
        }
        Ok(())
    }

    #[derive(Clone, Copy)]
    enum ModeledGroupSignal {
        Term,
        Kill,
    }

    #[derive(Clone, Copy)]
    enum ModeledCrashBoundary {
        AfterDriverPublish,
        DuringGuardedProbeKill,
        AfterNewHostBootstrap,
        AfterCommittedJournal,
    }

    #[derive(Clone, Copy)]
    struct ModeledCrashIsolation {
        proxy_outside_main_group: bool,
        root_outside_main_and_proxy_groups: bool,
        transaction_lock_close_on_exec: bool,
        persistent_root_broker_alive: bool,
    }

    fn modeled_process_group_crash_recovery(
        signal: ModeledGroupSignal,
        boundary: ModeledCrashBoundary,
        isolation: &ModeledCrashIsolation,
    ) -> Result<Vec<&'static str>> {
        match signal {
            ModeledGroupSignal::Term | ModeledGroupSignal::Kill => {}
        }
        if !isolation.proxy_outside_main_group {
            return Err(ControllerError(
                "process-group mutant killed the UID501 recovery proxy with main".to_owned(),
            ));
        }
        if !isolation.root_outside_main_and_proxy_groups {
            return Err(ControllerError(
                "process-group mutant killed the privileged broker with main or proxy".to_owned(),
            ));
        }
        if matches!(boundary, ModeledCrashBoundary::AfterCommittedJournal) {
            return Ok(vec!["root_commit", "keep_exact_new_host"]);
        }
        if !isolation.transaction_lock_close_on_exec {
            return Err(ControllerError(
                "descriptor mutant retained the main transaction lock in a detached child"
                    .to_owned(),
            ));
        }
        if !isolation.persistent_root_broker_alive {
            return Err(ControllerError(
                "privilege-loss mutant removed the already-authorized root restore boundary"
                    .to_owned(),
            ));
        }
        let mut actions = vec!["uid_stop_exact_v7_host", "uid_wait_no_capture_server"];
        if matches!(boundary, ModeledCrashBoundary::DuringGuardedProbeKill) {
            actions.push("guardian_conditionally_restore_owned_input");
        }
        actions.extend([
            "root_restore_exact_prior_driver",
            "root_reload_core_audio",
            "journal_driver_restored",
            "uid_restore_exact_v6_app",
            "uid_bootstrap_exact_v6_host",
            "uid_prove_exact_v6_ready",
        ]);
        Ok(actions)
    }

    fn require_action_order(
        actions: &[&str],
        earlier: &str,
        later: &str,
        label: &str,
    ) -> Result<()> {
        let earlier_index = actions.iter().position(|action| *action == earlier);
        let later_index = actions.iter().position(|action| *action == later);
        if !matches!((earlier_index, later_index), (Some(left), Some(right)) if left < right) {
            return Err(ControllerError(format!(
                "detached crash model violates {label}: actions={actions:?}"
            )));
        }
        Ok(())
    }

    fn self_test_detached_crash_matrix() -> Result<()> {
        let safe = ModeledCrashIsolation {
            proxy_outside_main_group: true,
            root_outside_main_and_proxy_groups: true,
            transaction_lock_close_on_exec: true,
            persistent_root_broker_alive: true,
        };
        for signal in [ModeledGroupSignal::Term, ModeledGroupSignal::Kill] {
            for boundary in [
                ModeledCrashBoundary::AfterDriverPublish,
                ModeledCrashBoundary::DuringGuardedProbeKill,
                ModeledCrashBoundary::AfterNewHostBootstrap,
            ] {
                let actions = modeled_process_group_crash_recovery(signal, boundary, &safe)?;
                require_action_order(
                    &actions,
                    "root_restore_exact_prior_driver",
                    "uid_restore_exact_v6_app",
                    "driver restoration before v6 app restoration",
                )?;
                require_action_order(
                    &actions,
                    "root_reload_core_audio",
                    "uid_bootstrap_exact_v6_host",
                    "Core Audio reload before v6 bootstrap",
                )?;
                require_action_order(
                    &actions,
                    "uid_restore_exact_v6_app",
                    "uid_prove_exact_v6_ready",
                    "v6 restoration and readiness",
                )?;
            }
        }
        let committed = modeled_process_group_crash_recovery(
            ModeledGroupSignal::Kill,
            ModeledCrashBoundary::AfterCommittedJournal,
            &safe,
        )?;
        if committed != ["root_commit", "keep_exact_new_host"] {
            return Err(ControllerError(
                "durable-commit crash model incorrectly rolled back".to_owned(),
            ));
        }
        for mutant in [
            ModeledCrashIsolation {
                proxy_outside_main_group: false,
                ..safe
            },
            ModeledCrashIsolation {
                root_outside_main_and_proxy_groups: false,
                ..safe
            },
            ModeledCrashIsolation {
                transaction_lock_close_on_exec: false,
                ..safe
            },
            ModeledCrashIsolation {
                persistent_root_broker_alive: false,
                ..safe
            },
        ] {
            if modeled_process_group_crash_recovery(
                ModeledGroupSignal::Kill,
                ModeledCrashBoundary::AfterNewHostBootstrap,
                &mutant,
            )
            .is_ok()
            {
                return Err(ControllerError(
                    "detached crash matrix accepted a rollback-breaking mutant".to_owned(),
                ));
            }
        }
        let probe_kill = modeled_process_group_crash_recovery(
            ModeledGroupSignal::Kill,
            ModeledCrashBoundary::DuringGuardedProbeKill,
            &safe,
        )?;
        require_action_order(
            &probe_kill,
            "guardian_conditionally_restore_owned_input",
            "root_restore_exact_prior_driver",
            "guardian KILL repair before driver rollback",
        )
    }

    fn paired_v7_dynamic_self_test() -> Result<()> {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| ControllerError("system clock predates Unix epoch".to_owned()))?
            .as_nanos();
        let directory = PathBuf::from(format!(
            "/private/tmp/opensteamer-paired-v7-selftest-{}-{unique}",
            std::process::id()
        ));
        require_path_absent(&directory, "paired-v7 self-test directory")?;
        fs::create_dir(&directory)?;
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
        let result = paired_v7_dynamic_self_test_in(&directory);
        let cleanup = fs::remove_dir_all(&directory);
        match (result, cleanup) {
            (Err(error), _) => Err(error),
            (Ok(()), Err(error)) => Err(ControllerError(format!(
                "cannot remove paired-v7 self-test directory: {error}"
            ))),
            (Ok(()), Ok(())) => Ok(()),
        }
    }

    fn paired_v7_dynamic_self_test_in(directory: &Path) -> Result<()> {
        let recoverable = directory.join("recoverable.log");
        let mut journal = V7Journal::create(&recoverable)?;
        journal.record(
            V7State::SourceExported,
            &[
                ("commit", "a".repeat(40)),
                ("tree", "b".repeat(40)),
                ("initial_pid", "41".to_owned()),
            ],
        )?;
        let before_rejected = fs::metadata(&recoverable)?.len();
        if journal
            .record(
                V7State::BuildVerified,
                &[("executable_sha256", "unsafe value".to_owned())],
            )
            .is_ok()
            || fs::metadata(&recoverable)?.len() != before_rejected
        {
            return Err(ControllerError(
                "paired-v7 journal validation failure changed durable bytes".to_owned(),
            ));
        }
        drop(journal);
        let mut partial = OpenOptions::new().append(true).open(&recoverable)?;
        partial.write_all(
            format!("STATE BUILD_VERIFIED executable_sha256={}", "c".repeat(64)).as_bytes(),
        )?;
        partial.sync_all()?;
        drop(partial);
        let mut reopened = V7Journal::open(&recoverable)?;
        if reopened.state != V7State::SourceExported {
            return Err(ControllerError(
                "paired-v7 journal recovery accepted an incomplete final record".to_owned(),
            ));
        }
        reopened.record(
            V7State::BuildVerified,
            &[("executable_sha256", "c".repeat(64))],
        )?;
        drop(reopened);

        let corrupt = directory.join("corrupt.log");
        let mut corrupt_journal = V7Journal::create(&corrupt)?;
        corrupt_journal.record(
            V7State::SourceExported,
            &[
                ("commit", "a".repeat(40)),
                ("tree", "b".repeat(40)),
                ("initial_pid", "41".to_owned()),
            ],
        )?;
        drop(corrupt_journal);
        let mut corrupt_append = OpenOptions::new().append(true).open(&corrupt)?;
        corrupt_append.write_all(b"STATE NEW_PUBLISHED\n")?;
        corrupt_append.sync_all()?;
        drop(corrupt_append);
        if V7Journal::open(&corrupt).is_ok() {
            return Err(ControllerError(
                "paired-v7 journal recovery accepted a malformed complete record".to_owned(),
            ));
        }

        let transaction_lock = directory.join("transaction.lock");
        let first = acquire_update_transaction_lock_at(&transaction_lock)?;
        if acquire_update_transaction_lock_at(&transaction_lock).is_ok() {
            return Err(ControllerError(
                "paired-v7 transaction lock allowed concurrent ownership".to_owned(),
            ));
        }
        drop(first);
        drop(acquire_update_transaction_lock_at(&transaction_lock)?);

        let empty_attempt_root = directory.join("empty-attempt-root");
        fs::create_dir(&empty_attempt_root)?;
        fs::set_permissions(&empty_attempt_root, fs::Permissions::from_mode(0o700))?;
        if require_exact_single_private_directory_child_at(
            &empty_attempt_root,
            "retained-failed-attempt",
        )
        .is_ok()
        {
            return Err(ControllerError(
                "paired-v7 retry gate accepted an absent retained attempt".to_owned(),
            ));
        }

        let exact_attempt_root = directory.join("exact-attempt-root");
        fs::create_dir(&exact_attempt_root)?;
        fs::set_permissions(&exact_attempt_root, fs::Permissions::from_mode(0o700))?;
        let exact_attempt = exact_attempt_root.join("retained-failed-attempt");
        fs::create_dir(&exact_attempt)?;
        fs::set_permissions(&exact_attempt, fs::Permissions::from_mode(0o700))?;
        if require_exact_single_private_directory_child_at(
            &exact_attempt_root,
            "retained-failed-attempt",
        )? != exact_attempt
        {
            return Err(ControllerError(
                "paired-v7 retry gate changed the exact retained attempt path".to_owned(),
            ));
        }
        let extra_attempt = exact_attempt_root.join("unexpected-second-attempt");
        fs::create_dir(&extra_attempt)?;
        fs::set_permissions(&extra_attempt, fs::Permissions::from_mode(0o700))?;
        if require_exact_single_private_directory_child_at(
            &exact_attempt_root,
            "retained-failed-attempt",
        )
        .is_ok()
        {
            return Err(ControllerError(
                "paired-v7 retry gate accepted an unexpected additional attempt".to_owned(),
            ));
        }

        let wrong_attempt_root = directory.join("wrong-attempt-root");
        fs::create_dir(&wrong_attempt_root)?;
        fs::set_permissions(&wrong_attempt_root, fs::Permissions::from_mode(0o700))?;
        let wrong_attempt = wrong_attempt_root.join("different-failed-attempt");
        fs::create_dir(&wrong_attempt)?;
        fs::set_permissions(&wrong_attempt, fs::Permissions::from_mode(0o700))?;
        if require_exact_single_private_directory_child_at(
            &wrong_attempt_root,
            "retained-failed-attempt",
        )
        .is_ok()
        {
            return Err(ControllerError(
                "paired-v7 retry gate accepted the wrong retained attempt".to_owned(),
            ));
        }

        let pointer_fixture = directory.join("v5-pointer-fixture");
        let mut pointer = create_new_private(&pointer_fixture)?;
        pointer.write_all(COMMITTED_V5_EVIDENCE.as_bytes())?;
        pointer.write_all(b"\n")?;
        pointer.sync_all()?;
        drop(pointer);
        let pointer_hash = sha256(&pointer_fixture)?;
        verify_self_test_pinned_file(&pointer_fixture, &pointer_hash)?;
        let mut mutate_pointer = OpenOptions::new().append(true).open(&pointer_fixture)?;
        mutate_pointer.write_all(b"x")?;
        mutate_pointer.sync_all()?;
        drop(mutate_pointer);
        if verify_self_test_pinned_file(&pointer_fixture, &pointer_hash).is_ok() {
            return Err(ControllerError(
                "v5 pointer corruption was accepted".to_owned(),
            ));
        }

        let evidence_fixture = directory.join("v5-evidence-fixture");
        let mut evidence = create_new_private(&evidence_fixture)?;
        evidence.write_all(b"committed-evidence\n")?;
        evidence.sync_all()?;
        drop(evidence);
        let evidence_hash = sha256(&evidence_fixture)?;
        verify_self_test_pinned_file(&evidence_fixture, &evidence_hash)?;
        let evidence_file = OpenOptions::new().write(true).open(&evidence_fixture)?;
        evidence_file.set_len(1)?;
        evidence_file.sync_all()?;
        drop(evidence_file);
        if verify_self_test_pinned_file(&evidence_fixture, &evidence_hash).is_ok() {
            return Err(ControllerError(
                "v5 evidence corruption was accepted".to_owned(),
            ));
        }

        self_test_v5_oracle_pin_mutation(directory)?;
        self_test_candidate_manifest_binding(directory)?;
        self_test_release_cycle_contract()?;
        self_test_partial_install_hold_recovery(directory)?;
        self_test_publication_boundary_recovery(directory)
    }

    fn self_test_candidate_manifest_binding(directory: &Path) -> Result<()> {
        let manifest = directory.join("candidate-manifest-fixture.txt");
        let candidate = CandidateSourceBinding {
            commit: "a".repeat(40),
            tree: "b".repeat(40),
            branch: EXPECTED_SOURCE_BRANCH.to_owned(),
            remote: EXPECTED_REMOTE.to_owned(),
        };
        let mut file = create_new_private(&manifest)?;
        for (key, value) in [
            ("schema", "opensteamer.production-driver-candidate.v7"),
            ("source_commit", candidate.commit.as_str()),
            ("source_tree", candidate.tree.as_str()),
            ("source_branch", EXPECTED_SOURCE_BRANCH),
            ("remote", candidate.remote.as_str()),
            (
                "developer_id_application_sha1",
                EXPECTED_DEVELOPER_ID_APPLICATION_SHA1,
            ),
            (
                "developer_id_installer_identity_sha1",
                EXPECTED_DEVELOPER_ID_INSTALLER_IDENTITY_SHA1,
            ),
            (
                "developer_id_installer_leaf_sha256",
                EXPECTED_DEVELOPER_ID_INSTALLER_LEAF_SHA256,
            ),
            ("bundle_tree_sha256", EXPECTED_PRODUCTION_DRIVER_TREE_SHA256),
            (
                "executable_sha256",
                EXPECTED_PRODUCTION_DRIVER_EXECUTABLE_SHA256,
            ),
            ("package_sha256", EXPECTED_PRODUCTION_DRIVER_PACKAGE_SHA256),
            (
                "notary_submission_id",
                "11111111-1111-1111-1111-111111111111",
            ),
        ] {
            writeln!(file, "{key}={value}")?;
        }
        file.sync_all()?;
        drop(file);
        if read_candidate_source_binding(&manifest)? != candidate {
            return Err(ControllerError(
                "candidate manifest did not preserve its exact functional source S".to_owned(),
            ));
        }
        let mut mutation = OpenOptions::new().append(true).open(&manifest)?;
        writeln!(mutation, "unreviewed=value")?;
        mutation.sync_all()?;
        drop(mutation);
        if read_candidate_source_binding(&manifest).is_ok() {
            return Err(ControllerError(
                "candidate manifest accepted an appended field".to_owned(),
            ));
        }
        Ok(())
    }

    fn self_test_release_cycle_contract() -> Result<()> {
        let candidate = CandidateSourceBinding {
            commit: "a".repeat(40),
            tree: "b".repeat(40),
            branch: EXPECTED_SOURCE_BRANCH.to_owned(),
            remote: EXPECTED_REMOTE.to_owned(),
        };
        let release_commit = "c".repeat(40);
        let release_tree = "d".repeat(40);
        let source_inputs = vec![FunctionalInputDigest {
            path: "Package.swift".to_owned(),
            mode: "100644".to_owned(),
            sha256: "e".repeat(64),
        }];
        let expected = canonical_functional_inputs_sha256(&source_inputs)?;
        let release_inputs = source_inputs.clone();
        let changed_paths: Vec<String> = REQUIRED_RELEASE_DIFF_PATHS
            .iter()
            .map(|path| (*path).to_owned())
            .collect();
        validate_release_cycle_evidence(
            &candidate,
            &release_commit,
            &release_tree,
            &candidate.tree,
            true,
            &changed_paths,
            &source_inputs,
            &release_inputs,
            &expected,
        )?;

        if validate_release_cycle_evidence(
            &candidate,
            &release_commit,
            &release_tree,
            &candidate.tree,
            false,
            &changed_paths,
            &source_inputs,
            &release_inputs,
            &expected,
        )
        .is_ok()
        {
            return Err(ControllerError(
                "release-cycle ancestry mutant was accepted".to_owned(),
            ));
        }

        let mut changed_input = release_inputs.clone();
        changed_input[0].sha256 = "f".repeat(64);
        if validate_release_cycle_evidence(
            &candidate,
            &release_commit,
            &release_tree,
            &candidate.tree,
            true,
            &changed_paths,
            &source_inputs,
            &changed_input,
            &expected,
        )
        .is_ok()
        {
            return Err(ControllerError(
                "release-cycle functional-input mutant was accepted".to_owned(),
            ));
        }

        let mut extra_path = changed_paths.clone();
        extra_path.push("macOS/Sources/CaptureServer/main.swift".to_owned());
        extra_path.sort();
        if validate_release_cycle_evidence(
            &candidate,
            &release_commit,
            &release_tree,
            &candidate.tree,
            true,
            &extra_path,
            &source_inputs,
            &release_inputs,
            &expected,
        )
        .is_ok()
        {
            return Err(ControllerError(
                "release-cycle extra-diff-path mutant was accepted".to_owned(),
            ));
        }

        let mismatched_candidate = CandidateSourceBinding {
            tree: "f".repeat(40),
            ..candidate.clone()
        };
        if validate_release_cycle_evidence(
            &mismatched_candidate,
            &release_commit,
            &release_tree,
            &candidate.tree,
            true,
            &changed_paths,
            &source_inputs,
            &release_inputs,
            &expected,
        )
        .is_ok()
        {
            return Err(ControllerError(
                "candidate manifest source mismatch mutant was accepted".to_owned(),
            ));
        }

        let unanchored_caller_digest = "9".repeat(64);
        if validate_release_cycle_evidence(
            &candidate,
            &release_commit,
            &release_tree,
            &candidate.tree,
            true,
            &changed_paths,
            &source_inputs,
            &release_inputs,
            &unanchored_caller_digest,
        )
        .is_ok()
        {
            return Err(ControllerError(
                "release-cycle proof accepted an unanchored caller digest".to_owned(),
            ));
        }
        Ok(())
    }

    fn self_test_partial_install_hold_recovery(directory: &Path) -> Result<()> {
        let install_hold_root = directory.join("partial-install-hold-root");
        let archive = directory.join("partial-install-hold-quarantine");
        fs::create_dir(&install_hold_root)?;
        fs::set_permissions(&install_hold_root, fs::Permissions::from_mode(0o700))?;

        // Deliberately model a failed `ditto`: the expected app child is a malformed regular file.
        let malformed_child = install_hold_root.join("opensteamer Host.app");
        let mut marker = create_new_private(&malformed_child)?;
        marker.write_all(b"partial-copy-marker")?;
        marker.sync_all()?;
        drop(marker);

        archive_v7_install_hold_root_at(&install_hold_root, &archive)?;
        require_path_absent(&install_hold_root, "quarantined partial install-hold root")?;
        require_directory(&archive, 0o700)?;
        if read_bounded_utf8(&archive.join("opensteamer Host.app"), 128)? != "partial-copy-marker" {
            return Err(ControllerError(
                "opaque partial install-hold quarantine changed child bytes".to_owned(),
            ));
        }

        // A resumed rollback sees the retained quarantine and succeeds idempotently.
        archive_v7_install_hold_root_at(&install_hold_root, &archive)?;

        // Both paths existing is ambiguous and must fail before any host bootout.
        fs::create_dir(&install_hold_root)?;
        fs::set_permissions(&install_hold_root, fs::Permissions::from_mode(0o700))?;
        if archive_v7_install_hold_root_at(&install_hold_root, &archive).is_ok() {
            return Err(ControllerError(
                "partial install-hold quarantine accepted ambiguous duplicate roots".to_owned(),
            ));
        }
        Ok(())
    }

    fn verify_self_test_pinned_file(path: &Path, expected_sha256: &str) -> Result<()> {
        verify_self_test_pinned_file_with_mode(path, 0o600, expected_sha256)
    }

    fn verify_self_test_pinned_file_with_mode(
        path: &Path,
        mode: u32,
        expected_sha256: &str,
    ) -> Result<()> {
        require_regular(path, mode)?;
        if sha256(path)? != expected_sha256 {
            return Err(ControllerError("pinned self-test file changed".to_owned()));
        }
        Ok(())
    }

    fn self_test_v5_oracle_pin_mutation(directory: &Path) -> Result<()> {
        for (name, mode) in [
            ("verify-bundle-oracle-fixture", 0o700),
            ("verify-live-process-oracle-fixture", 0o700),
            ("verify-deployment-oracle-fixture", 0o700),
            ("verify-launch-state-oracle-fixture", 0o700),
            ("launch-agent-oracle-fixture", 0o600),
        ] {
            let path = directory.join(name);
            let mut oracle = create_new_private(&path)?;
            writeln!(oracle, "immutable-v5-oracle={name}")?;
            oracle.sync_all()?;
            drop(oracle);
            fs::set_permissions(&path, fs::Permissions::from_mode(mode))?;
            let expected_sha256 = sha256(&path)?;
            verify_self_test_pinned_file_with_mode(&path, mode, &expected_sha256)?;
            let mut mutation = OpenOptions::new().append(true).open(&path)?;
            mutation.write_all(b"mutation")?;
            mutation.sync_all()?;
            drop(mutation);
            if verify_self_test_pinned_file_with_mode(&path, mode, &expected_sha256).is_ok() {
                return Err(ControllerError(format!(
                    "v5 rollback oracle corruption was accepted: {name}"
                )));
            }
        }
        Ok(())
    }

    #[derive(Clone, Copy)]
    struct PublicationBoundaryCase {
        name: &'static str,
        current_held: bool,
        new_published: bool,
    }

    const PUBLICATION_BOUNDARY_CASES: [PublicationBoundaryCase; 5] = [
        PublicationBoundaryCase {
            name: "pre-current-hold",
            current_held: false,
            new_published: false,
        },
        PublicationBoundaryCase {
            name: "current-held-pre-new-publish",
            current_held: true,
            new_published: false,
        },
        PublicationBoundaryCase {
            name: "new-published-pre-bootstrap",
            current_held: true,
            new_published: true,
        },
        PublicationBoundaryCase {
            name: "bootstrapped-pre-ready",
            current_held: true,
            new_published: true,
        },
        PublicationBoundaryCase {
            name: "ready-pre-commit",
            current_held: true,
            new_published: true,
        },
    ];

    fn self_test_publication_boundary_recovery(directory: &Path) -> Result<()> {
        for case in PUBLICATION_BOUNDARY_CASES {
            self_test_publication_boundary_case(directory, case)?;
        }
        Ok(())
    }

    fn self_test_publication_boundary_case(
        directory: &Path,
        case: PublicationBoundaryCase,
    ) -> Result<()> {
        const BASELINE_BYTES: &str = "current-isolated-baseline";
        const REPLACEMENT_BYTES: &str = "paired-v7-replacement";

        let case_root = directory.join(case.name);
        fs::create_dir(&case_root)?;
        fs::set_permissions(&case_root, fs::Permissions::from_mode(0o700))?;
        let canonical = case_root.join("canonical-app-fixture");
        let rollback = case_root.join("rollback-current-fixture");
        let pending = case_root.join("pending-new-fixture");
        let failed = case_root.join("failed-new-fixture");
        let pointer = case_root.join("pinned-v5-pointer-fixture");

        let mut pointer_file = create_new_private(&pointer)?;
        writeln!(pointer_file, "{COMMITTED_V5_EVIDENCE}")?;
        pointer_file.sync_all()?;
        drop(pointer_file);
        if sha256(&pointer)? != COMMITTED_V5_POINTER_SHA256 {
            return Err(ControllerError(
                "publication matrix v5 pointer does not match the committed bytes".to_owned(),
            ));
        }
        verify_self_test_pinned_file(&pointer, COMMITTED_V5_POINTER_SHA256)?;

        let mut baseline = create_new_private(&canonical)?;
        baseline.write_all(BASELINE_BYTES.as_bytes())?;
        baseline.sync_all()?;
        drop(baseline);
        let mut replacement = create_new_private(&pending)?;
        replacement.write_all(REPLACEMENT_BYTES.as_bytes())?;
        replacement.sync_all()?;
        drop(replacement);

        if case.current_held {
            self_test_checked_rename(&canonical, &rollback, &pointer, COMMITTED_V5_POINTER_SHA256)?;
        }
        if case.new_published {
            self_test_checked_rename(&pending, &canonical, &pointer, COMMITTED_V5_POINTER_SHA256)?;
        }
        verify_self_test_boundary_topology(case, &canonical, &rollback, &pending, &failed, false)?;
        verify_self_test_pinned_file(&pointer, COMMITTED_V5_POINTER_SHA256)?;

        if path_exists_without_follow(&rollback)? {
            if path_exists_without_follow(&canonical)? {
                verify_self_test_fixture(&canonical, Some(REPLACEMENT_BYTES))?;
                self_test_checked_rename(
                    &canonical,
                    &failed,
                    &pointer,
                    COMMITTED_V5_POINTER_SHA256,
                )?;
            }
            self_test_checked_rename(&rollback, &canonical, &pointer, COMMITTED_V5_POINTER_SHA256)?;
        }
        verify_self_test_boundary_topology(case, &canonical, &rollback, &pending, &failed, true)?;
        verify_self_test_pinned_file(&pointer, COMMITTED_V5_POINTER_SHA256)?;
        Ok(())
    }

    fn self_test_checked_rename(
        source: &Path,
        destination: &Path,
        pointer: &Path,
        pointer_sha256: &str,
    ) -> Result<()> {
        verify_self_test_pinned_file(pointer, pointer_sha256)?;
        rename_exclusive(source, destination)?;
        fsync_parent(source)?;
        fsync_parent(destination)?;
        verify_self_test_pinned_file(pointer, pointer_sha256)
    }

    fn verify_self_test_boundary_topology(
        case: PublicationBoundaryCase,
        canonical: &Path,
        rollback: &Path,
        pending: &Path,
        failed: &Path,
        recovered: bool,
    ) -> Result<()> {
        const BASELINE_BYTES: &str = "current-isolated-baseline";
        const REPLACEMENT_BYTES: &str = "paired-v7-replacement";

        if recovered {
            verify_self_test_fixture(canonical, Some(BASELINE_BYTES))?;
            verify_self_test_fixture(rollback, None)?;
            if case.new_published {
                verify_self_test_fixture(pending, None)?;
                verify_self_test_fixture(failed, Some(REPLACEMENT_BYTES))?;
            } else {
                verify_self_test_fixture(pending, Some(REPLACEMENT_BYTES))?;
                verify_self_test_fixture(failed, None)?;
            }
        } else if case.new_published {
            verify_self_test_fixture(canonical, Some(REPLACEMENT_BYTES))?;
            verify_self_test_fixture(rollback, Some(BASELINE_BYTES))?;
            verify_self_test_fixture(pending, None)?;
            verify_self_test_fixture(failed, None)?;
        } else if case.current_held {
            verify_self_test_fixture(canonical, None)?;
            verify_self_test_fixture(rollback, Some(BASELINE_BYTES))?;
            verify_self_test_fixture(pending, Some(REPLACEMENT_BYTES))?;
            verify_self_test_fixture(failed, None)?;
        } else {
            verify_self_test_fixture(canonical, Some(BASELINE_BYTES))?;
            verify_self_test_fixture(rollback, None)?;
            verify_self_test_fixture(pending, Some(REPLACEMENT_BYTES))?;
            verify_self_test_fixture(failed, None)?;
        }
        Ok(())
    }

    fn verify_self_test_fixture(path: &Path, expected: Option<&str>) -> Result<()> {
        if let Some(expected) = expected {
            if read_bounded_utf8(path, 128)? != expected {
                return Err(ControllerError(
                    "publication-boundary crash recovery failed".to_owned(),
                ));
            }
        } else if path_exists_without_follow(path)? {
            return Err(ControllerError(
                "current isolated baseline rollback restoration failed".to_owned(),
            ));
        }
        Ok(())
    }
}

fn main() {
    paired_v7::entry();
}
