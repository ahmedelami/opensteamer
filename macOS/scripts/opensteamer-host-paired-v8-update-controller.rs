//! Pairing-preserving updater for the committed isolated `opensteamer Host.app`.
//!
//! The historical post-v20 controller remains an immutable included implementation source for
//! its reviewed low-level filesystem, launchd, signature, process, lock, and deployment proofs.
//! This controller owns a disjoint v8 journal/pointer namespace, never starts an interactive
//! host, never resets pairing, never operates the installed virtual microphone driver, and rolls
//! back to the exact committed pairing-preserving v7 retry-4 host.

#[allow(dead_code)]
mod paired_v8 {
    include!(env!("OPENSTEAMER_PAIRED_V8_INCLUDED_SOURCE"));
    use std::os::darwin::fs::MetadataExt as _;

    const V8_PREFLIGHT_MODE: &str = "--verify-paired-v8-host-update-preflight";
    const V8_EXECUTE_MODE: &str = "--execute-authorized-paired-v8-host-update";
    const V8_ROLLBACK_MODE: &str = "--rollback-authorized-paired-v8-host-update";
    const V8_SELF_TEST_MODE: &str = "--self-test-paired-v8-host-update";
    const V8_EXPECTED_REPO: &str = "/Users/ahmed/Documents/Codex/opensteamer";

    const V8_UPDATE_ROOT: &str =
        "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v8";
    const V8_ACTIVE_UPDATE: &str =
        "/Users/ahmed/Library/Application Support/opensteamer/active-paired-host-update-v8";
    const V8_UPDATE_LOCK: &str = UPDATE_LOCK;
    const V8_JOURNAL_HEADER: &str = "OPENSTEAMER_PAIRED_HOST_UPDATE_V8";
    const HIDDEN_INSTALL_PREFIX: &str = ".opensteamer-paired-v8-install-";
    const NEW_LAUNCH_AGENT_LABEL: &str = NEW_LABEL;
    const PROTECTED_LEGACY_LAUNCH_AGENT_LABEL: &str = LEGACY_LABEL;
    const REVIEWED_LAUNCH_AGENT_PATH: &str = NEW_PLIST;
    const REVIEWED_LAUNCH_AGENT_SHA256: &str = NEW_PLIST_SHA256;

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
    const COMMITTED_V5_RESERVE_DEVICE: u64 = 16_777_230;
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
    const COMMITTED_V6_BASELINE_APP: &str = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v6/paired-v6-update-1786412787-39578-728d9781-2b79-4d10-a220-8a48c1f6f716/deployment-reference/opensteamer Host.app";
    const COMMITTED_V6_BASELINE_SOURCE_EXPORT: &str = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v6/paired-v6-update-1786412787-39578-728d9781-2b79-4d10-a220-8a48c1f6f716/source-export";
    const COMMITTED_V6_BASELINE_EXECUTABLE_SHA256: &str =
        "63d55477ca440dd3feb27f68959b479a2292e6accc635d159674c6b420b60de6";
    const COMMITTED_V6_BASELINE_CDHASH: &str = "1d7b50e8bf2cc907244f950049b167a8f252473e";
    const COMMITTED_V6_VERIFY_BUNDLE_SHA256: &str = COMMITTED_V5_VERIFY_BUNDLE_SHA256;
    const COMMITTED_V6_VERIFY_LIVE_PROCESS_SHA256: &str =
        COMMITTED_V5_VERIFY_LIVE_PROCESS_SHA256;
    const COMMITTED_V6_VERIFY_DEPLOYMENT_SHA256: &str =
        COMMITTED_V5_VERIFY_DEPLOYMENT_SHA256;
    const COMMITTED_V6_VERIFY_LAUNCH_STATE_SHA256: &str =
        COMMITTED_V5_VERIFY_LAUNCH_STATE_SHA256;
    const COMMITTED_V6_LAUNCH_AGENT_SOURCE_SHA256: &str =
        COMMITTED_V5_LAUNCH_AGENT_SOURCE_SHA256;

    const COMMITTED_V7_POINTER: &str =
        "/Users/ahmed/Library/Application Support/opensteamer/active-paired-host-update-v7-retry-4";
    const COMMITTED_V7_UPDATE_ROOT: &str =
        "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v7";
    const COMMITTED_V7_EVIDENCE_NAME: &str =
        "paired-v7-update-retry-4-1787410812-36567-22c759df-9572-48b8-99f9-49cd96467e1f";
    const COMMITTED_V7_EVIDENCE: &str = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v7/paired-v7-update-retry-4-1787410812-36567-22c759df-9572-48b8-99f9-49cd96467e1f";
    const COMMITTED_V7_POINTER_SHA256: &str =
        "61882730f61eba21c66333cc694e362931982402de74b2135436d17abd701d90";
    const COMMITTED_V7_POINTER_INODE: u64 = 27_877_657;
    const COMMITTED_V7_EVIDENCE_INODE: u64 = 27_870_917;
    const COMMITTED_V7_JOURNAL_SHA256: &str =
        "590e105252083b2029c1cb3aee3940622d607cabacfedc4f1c6e7f95798e2971";
    const COMMITTED_V7_RESULT_SHA256: &str =
        "22127aa5523e3efa468822044100fb2fd1cc5ceb97552377c986b1f5c1a15d77";
    const COMMITTED_V7_PROVENANCE_SHA256: &str =
        "54e9c10a8cded2fce3b1195072ab891f3379a210f3fb0e3781ec7eba02e9d207";
    const COMMITTED_V7_SOURCE_ARCHIVE_SHA256: &str =
        "274a1252bc389713305d2568cc4ba913827ca970b335a20fb992b1d9d7c3da66";
    const COMMITTED_V7_INSTALL_HOLD_NAME_SHA256: &str =
        "36665f7edc76008a97234696c240b728f1b864acc48d8c9f7b2636bd99c847c8";
    const COMMITTED_V7_BUILD_STDOUT_SHA256: &str =
        "90fee8d2ab0bad6bffe412e4b6afabeb599eca67c0ad233a51535fe98bc9c4df";
    const COMMITTED_V7_BUILD_STDERR_SHA256: &str =
        "9cd07078791c68563f6cb63ab5978862a42a1762e3dded3b344d81f171650f5b";
    const COMMITTED_V7_FUNCTIONAL_INPUTS_SHA256: &str =
        "960b81ed1e23b6976d415fa87ef7a2654c1aa9099aea0d0c6e6312e024bb38e0";
    const COMMITTED_V7_DRIVER_RECORD_SHA256: &str =
        "8439ab4e43b813eac75c91f23c22f65b41e4ace5bac524ec8a2efdb59f6451a0";
    const COMMITTED_V7_CONTROLLER_SOURCE_SHA256: &str =
        "081212e20d74ae2c823eb8eab317259bc4899eae0e09c8f19e600d71d4f625e3";
    const COMMITTED_V7_LAUNCHER_SOURCE_SHA256: &str =
        "fc53a001c13aded937826cb3b5cf3e1084f077cfb32f5f0aeb94df4e0cd97176";
    const COMMITTED_V7_CONTROLLER_BINARY_SHA256: &str =
        "70d1f444c0cb4db90cec6ec18edbd81e1a9285ae068f5f53aeb28027303b7de5";
    const COMMITTED_V7_INCLUDED_V1_SOURCE_SHA256: &str =
        "2dfe9ddec5ea71b206f6462deec0b8be5423e9f23ab30aebc42b8f424dfdab06";
    const COMMITTED_V7_SOURCE_COMMIT: &str = "9eb6e6196b57b4ade03047ce53032cdbea4c028f";
    const COMMITTED_V7_SOURCE_TREE: &str = "4f99e4297625421dbee91493bc41800061440525";
    const COMMITTED_V7_INSTALL_HOLD_ROOT: &str =
        "/Applications/.opensteamer-paired-v7-install-22c759df-9572-48b8-99f9-49cd96467e1f";
    const COMMITTED_V7_RESERVE_INODE: u64 = 27_877_652;
    const COMMITTED_V7_BASELINE_APP: &str = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v7/paired-v7-update-retry-4-1787410812-36567-22c759df-9572-48b8-99f9-49cd96467e1f/deployment-reference/opensteamer Host.app";
    const COMMITTED_V7_BASELINE_SOURCE_EXPORT: &str = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v7/paired-v7-update-retry-4-1787410812-36567-22c759df-9572-48b8-99f9-49cd96467e1f/source-export";
    const COMMITTED_V7_BASELINE_EXECUTABLE_SHA256: &str =
        "d2b74f0faf48f7f25d51c44f958aaa7aa7361c6cb7306a742c73e7f4fb85ef41";
    const COMMITTED_V7_BASELINE_CDHASH: &str = "af2ad07715d8efe45ac8f8a355930e654441897e";
    const COMMITTED_V7_BASELINE_INFO_PLIST_SHA256: &str =
        "3c017d9cf034cbc864fc19103a0919f296930f0752f8ecfedcb1c93fbbc9694d";
    const COMMITTED_V7_RETRY4_PINSET_SHA256: &str =
        "9fd0d8ab7eb3d08ba52f89e4641e551c0a873ef9dcfc0644916f0533bdbd097b";

    const CURRENT_BASELINE_APP: &str = COMMITTED_V7_BASELINE_APP;
    const CURRENT_BASELINE_SOURCE_EXPORT: &str = COMMITTED_V7_BASELINE_SOURCE_EXPORT;
    const CURRENT_BASELINE_EXECUTABLE_SHA256: &str = COMMITTED_V7_BASELINE_EXECUTABLE_SHA256;
    const CURRENT_BASELINE_CDHASH: &str = COMMITTED_V7_BASELINE_CDHASH;
    const CURRENT_BASELINE_VERIFY_BUNDLE_SHA256: &str = COMMITTED_V5_VERIFY_BUNDLE_SHA256;
    const CURRENT_BASELINE_VERIFY_LIVE_PROCESS_SHA256: &str =
        COMMITTED_V5_VERIFY_LIVE_PROCESS_SHA256;
    const CURRENT_BASELINE_VERIFY_DEPLOYMENT_SHA256: &str =
        COMMITTED_V5_VERIFY_DEPLOYMENT_SHA256;
    const CURRENT_BASELINE_VERIFY_LAUNCH_STATE_SHA256: &str =
        COMMITTED_V5_VERIFY_LAUNCH_STATE_SHA256;
    const CURRENT_BASELINE_LAUNCH_AGENT_SOURCE_SHA256: &str =
        COMMITTED_V5_LAUNCH_AGENT_SOURCE_SHA256;

    const V7_ROOT_SUPPORT_PARENT: &str = "/Library/Application Support/opensteamer";
    const V7_ROOT_TRANSACTION_PARENT: &str =
        "/Library/Application Support/opensteamer/driver-transactions-v7";
    const V7_ROOT_SUPPORT_PARENT_INODE: u64 = 27_777_167;
    const V7_ROOT_TRANSACTION_PARENT_INODE: u64 = 27_777_175;
    const V7_ROOT_OUTER_NAMES: [&str; 6] = [
        "driver-transactions-v7",
        "privileged-v7",
        "privileged-v7-recovery-retry-2",
        "privileged-v7-recovery-retry-2-v2",
        "privileged-v7-v2",
        "privileged-v7-v3",
    ];
    const V7_PRODUCT_DRIVER: &str =
        "/Library/Audio/Plug-Ins/HAL/OpensteamerVirtualMicrophone.driver";
    const V7_PRODUCT_DRIVER_IDENTIFIER: &str =
        "com.elamin.opensteamer.VirtualMicrophoneDriver";
    const V7_PRODUCT_DRIVER_TEAM_ID: &str = "MSMG8CJLB3";
    const V7_PRODUCT_DRIVER_TREE_SHA256: &str =
        "f32e870ed639fedd90ea63d3434727d72e5c030fccc4d3c6cf9bda1ae003ce49";
    const V7_PRODUCT_DRIVER_EXECUTABLE_SHA256: &str =
        "ca6efc2627be0e83e591b66187820cbc7a34d8dfd7cbf2818788e1589d496866";
    const V7_PRODUCT_DRIVER_DEVICE: u64 = 16_777_229;
    const V7_PRODUCT_DRIVER_INODE: u64 = 27_877_539;

    const ISOLATED_PAIRING_IDENTITY_ACCOUNT: &str = "worldwide-host-identity-v1";
    const ISOLATED_PAIRING_VIEWER_ACCOUNT: &str = "worldwide-paired-viewer-v1";
    const PAIRED_AVAILABILITY_MARKER_PREFIX: &str =
        "[info] Worldwide paired-device availability is online";
    const REQUIRED_V7_PREDECESSOR_COMMIT: &str = COMMITTED_V7_SOURCE_COMMIT;
    const RELEASE_PIN_STATUS: &str = "PINNED_FINAL_REVIEW";
    const RELEASE_PIN_READY: &str = "PINNED_FINAL_REVIEW";
    const RELEASE_PIN_PLACEHOLDER: &str = "PIN_AFTER_FINAL_REVIEW";
    const EXPECTED_FUNCTIONAL_SOURCE_COMMIT: &str =
        "a4ec2f03a7d2cd7562b60e8ecc4ecaf54962008c";
    const EXPECTED_FUNCTIONAL_SOURCE_TREE: &str =
        "56f3b98437a51a1c40d481b610b2315829c4c917";
    const V8_RELEASE_ONLY_PATHS: [&str; 3] = [
        "macOS/Tests/CaptureServerTests/V8HostUpdateContractTests.swift",
        "macOS/scripts/opensteamer-host-paired-v8-update-controller.rs",
        "macOS/scripts/update-opensteamer-host-paired-v8.sh",
    ];
    const EXPECTED_SOURCE_BRANCH: &str = "agent/auto-select-iphone-microphone";
    const EXPECTED_REMOTE: &str = "https://github.com/ahmedelami/opensteamer.git";

    #[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
    enum V8State {
        Begun,
        SourceExported,
        BuildVerified,
        StopInitiated,
        InstallHoldVerified,
        CurrentStopped,
        CurrentHeld,
        NewPublished,
        PersistentBootstrapped,
        ReadyVerified,
        Committed,
        RollbackStarted,
        FailedNewArchived,
        CurrentRestored,
        CurrentBootstrapped,
        RolledBack,
        CriticalFailure,
    }

    impl V8State {
        fn token(self) -> &'static str {
            match self {
                Self::Begun => "BEGUN",
                Self::SourceExported => "SOURCE_EXPORTED",
                Self::BuildVerified => "BUILD_VERIFIED",
                Self::StopInitiated => "STOP_INITIATED",
                Self::InstallHoldVerified => "INSTALL_HOLD_VERIFIED",
                Self::CurrentStopped => "CURRENT_STOPPED",
                Self::CurrentHeld => "CURRENT_HELD",
                Self::NewPublished => "NEW_PUBLISHED",
                Self::PersistentBootstrapped => "PERSISTENT_BOOTSTRAPPED",
                Self::ReadyVerified => "READY_VERIFIED",
                Self::Committed => "COMMITTED",
                Self::RollbackStarted => "ROLLBACK_STARTED",
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
                "STOP_INITIATED" => Self::StopInitiated,
                "INSTALL_HOLD_VERIFIED" => Self::InstallHoldVerified,
                "CURRENT_STOPPED" => Self::CurrentStopped,
                "CURRENT_HELD" => Self::CurrentHeld,
                "NEW_PUBLISHED" => Self::NewPublished,
                "PERSISTENT_BOOTSTRAPPED" => Self::PersistentBootstrapped,
                "READY_VERIFIED" => Self::ReadyVerified,
                "COMMITTED" => Self::Committed,
                "ROLLBACK_STARTED" => Self::RollbackStarted,
                "FAILED_NEW_ARCHIVED" => Self::FailedNewArchived,
                "CURRENT_RESTORED" => Self::CurrentRestored,
                "CURRENT_BOOTSTRAPPED" => Self::CurrentBootstrapped,
                "ROLLED_BACK" => Self::RolledBack,
                "CRITICAL_FAILURE" => Self::CriticalFailure,
                _ => return None,
            })
        }
    }

    struct V8Journal {
        path: PathBuf,
        file: File,
        state: V8State,
        healthy: bool,
    }

    impl V8Journal {
        fn create(path: &Path) -> Result<Self> {
            let mut file = OpenOptions::new()
                .create_new(true)
                .read(true)
                .write(true)
                .mode(0o600)
                .custom_flags(O_NOFOLLOW | 0x0100_0000)
                .open(path)
                .map_err(|error| ControllerError(format!("cannot create v8 journal: {error}")))?;
            validate_open_journal_file(path, &file)?;
            writeln!(file, "{V8_JOURNAL_HEADER}")?;
            file.sync_all()?;
            fsync_parent(path)?;
            let mut journal = Self {
                path: path.to_path_buf(),
                file,
                state: V8State::Begun,
                healthy: true,
            };
            journal.record(V8State::Begun, &[])?;
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
                .map_err(|_| ControllerError("v8 journal is not UTF-8".to_owned()))?;
            let state = parse_v8_journal(complete_text)?;
            if complete_length != bytes.len() {
                if !is_plausible_v8_torn_tail(&bytes[complete_length..], state) {
                    return Err(ControllerError(
                        "v8 journal has an implausible incomplete final record".to_owned(),
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

        fn record(&mut self, state: V8State, fields: &[(&str, String)]) -> Result<()> {
            self.require_healthy()?;
            validate_v8_transition(self.state, state)?;
            validate_v8_fields(state, fields)?;
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
                        "cannot durably append v8 journal record: {error}"
                    ))),
                    Err(recovery_error) => Err(ControllerError(format!(
                        "cannot durably append v8 journal record ({error}) or restore prior length ({recovery_error})"
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
                    "v8 journal is poisoned after an unrecovered append failure".to_owned(),
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
                    "v8 journal append recovery did not restore prior durable length".to_owned(),
                ));
            }
            let text = std::str::from_utf8(&bytes)
                .map_err(|_| ControllerError("recovered v8 journal is not UTF-8".to_owned()))?;
            if parse_v8_journal(text)? != self.state {
                return Err(ControllerError(
                    "v8 journal append recovery did not restore prior state".to_owned(),
                ));
            }
            self.file.seek(SeekFrom::End(0))?;
            self.healthy = true;
            Ok(())
        }
    }

    struct V8Layout {
        repo: PathBuf,
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
        journal: PathBuf,
        result: PathBuf,
    }

    enum V8Command {
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
    }

    impl V8Layout {
        fn new(repo: PathBuf, evidence: PathBuf, nonce: &str) -> Self {
            let stage_output = evidence.join("staged-output");
            let deployment_reference_dir = evidence.join("deployment-reference");
            let rollback_dir = evidence.join("rollback-current");
            let failed_dir = evidence.join("failed-new");
            let install_hold_root = PathBuf::from(format!(
                "/Applications/.opensteamer-paired-v8-install-{nonce}"
            ));
            Self {
                repo,
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
                journal: evidence.join("journal.log"),
                result: evidence.join("result.txt"),
                evidence,
            }
        }
    }

    pub fn entry() {
        if let Err(error) = paired_v8_real_main() {
            eprintln!("opensteamer paired-v8 update controller: {error}");
            std::process::exit(1);
        }
    }

    fn paired_v8_real_main() -> Result<()> {
        let arguments: Vec<String> = env::args().collect();
        verify_optimized_binary_scrub()?;
        let command = parse_v8_command(&arguments)?;
        if !matches!(command, V8Command::SelfTest) {
            require_v8_release_pins()?;
        }
        match command {
            V8Command::Preflight(repo) => {
                let repo = canonical_repo(&repo)?;
                verify_machine_contract()?;
                let _transaction_lock = acquire_update_transaction_lock()?;
                verify_committed_v7_baseline()?;
                let generation = verify_paired_v8_runtime()?;
                let provenance = verify_paired_v8_git_provenance(&repo, true)?;
                verify_isolated_pairing_items_present()?;
                require_path_absent(Path::new(V8_ACTIVE_UPDATE), "active paired-v8 pointer")?;
                require_v8_update_root_unused()?;
                println!(
                    "PAIRED_V8_UPDATE_PREFLIGHT_OK pid={} runs={} baseline=sole-ready pairing=preserved v1=immutable v2=immutable v3=immutable v4=immutable v5=immutable v6=immutable v7-retry4=immutable driver=read-only-immutable root-outer=read-only-immutable v8=absent source_commit={} source_tree={} release_commit={} release_tree={}",
                    generation.pid,
                    generation.runs,
                    EXPECTED_FUNCTIONAL_SOURCE_COMMIT,
                    EXPECTED_FUNCTIONAL_SOURCE_TREE,
                    provenance.commit,
                    provenance.tree
                );
                Ok(())
            }
            V8Command::Execute {
                repo,
                authorized_commit,
                authorized_tree,
            } => execute_paired_v8_update(
                canonical_repo(&repo)?,
                &authorized_commit,
                &authorized_tree,
            ),
            V8Command::Rollback(repo) => rollback_existing_paired_v8_update(canonical_repo(&repo)?),
            V8Command::SelfTest => paired_v8_self_test(),
            V8Command::ProbeLock { runtime, lock, pid } => {
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
        }
    }

    fn parse_v8_command(arguments: &[String]) -> Result<V8Command> {
        match arguments {
            [_, mode, repo] if mode == V8_PREFLIGHT_MODE => {
                Ok(V8Command::Preflight(repo.clone()))
            }
            [_, mode, repo, authorized_commit, authorized_tree] if mode == V8_EXECUTE_MODE => {
                require_canonical_git_oid(authorized_commit, "authorized commit")?;
                require_canonical_git_oid(authorized_tree, "authorized tree")?;
                Ok(V8Command::Execute {
                    repo: repo.clone(),
                    authorized_commit: authorized_commit.clone(),
                    authorized_tree: authorized_tree.clone(),
                })
            }
            [_, mode, repo] if mode == V8_ROLLBACK_MODE => Ok(V8Command::Rollback(repo.clone())),
            [_, mode] if mode == V8_SELF_TEST_MODE => Ok(V8Command::SelfTest),
            [_, mode, runtime, lock, pid] if mode == PROBE_LOCK_MODE => {
                Ok(V8Command::ProbeLock {
                    runtime: runtime.clone(),
                    lock: lock.clone(),
                    pid: pid.clone(),
                })
            }
            _ => Err(ControllerError(format!(
                "usage: {} {V8_PREFLIGHT_MODE} <canonical-repo>\n       {} {V8_EXECUTE_MODE} <canonical-repo> <authorized-commit> <authorized-tree>\n       {} {V8_ROLLBACK_MODE} <canonical-repo>\n       {} {V8_SELF_TEST_MODE}\n       {} {PROBE_LOCK_MODE} <runtime-dir> <lock-file> <pid>",
                arguments.first().map_or("controller", String::as_str),
                arguments.first().map_or("controller", String::as_str),
                arguments.first().map_or("controller", String::as_str),
                arguments.first().map_or("controller", String::as_str),
                arguments.first().map_or("controller", String::as_str),
            ))),
        }
    }

    fn require_canonical_git_oid(value: &str, label: &str) -> Result<()> {
        if value.len() != 40
            || !value
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err(ControllerError(format!(
                "{label} must be exactly 40 lowercase hexadecimal characters"
            )));
        }
        Ok(())
    }

    fn require_v8_release_pins() -> Result<()> {
        let frozen_source_pins = [
            EXPECTED_FUNCTIONAL_SOURCE_COMMIT,
            EXPECTED_FUNCTIONAL_SOURCE_TREE,
        ];
        if RELEASE_PIN_STATUS != RELEASE_PIN_READY
            || frozen_source_pins.iter().any(|pin| {
                pin.is_empty()
                    || pin.contains(RELEASE_PIN_PLACEHOLDER)
                    || pin.contains("UNPINNED")
            })
        {
            return Err(ControllerError(
                "paired-v8 is intentionally unrunnable until the final controller source and deterministic binary pins are reviewed"
                    .to_owned(),
            ));
        }
        require_canonical_git_oid(
            EXPECTED_FUNCTIONAL_SOURCE_COMMIT,
            "frozen functional-source commit",
        )?;
        require_canonical_git_oid(
            EXPECTED_FUNCTIONAL_SOURCE_TREE,
            "frozen functional-source tree",
        )
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
            ControllerError(format!("cannot resolve the paired-v8 controller: {error}"))
        })?;
        let mut file = File::open(&executable).map_err(|error| {
            ControllerError(format!("cannot inspect the paired-v8 controller: {error}"))
        })?;
        let before = file.metadata()?;
        if !before.file_type().is_file()
            || before.nlink() != 1
            || before.len() == 0
            || before.len() > MAX_CONTROLLER_BYTES
        {
            return Err(ControllerError(
                "paired-v8 controller binary has unsafe metadata".to_owned(),
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
                "paired-v8 controller changed while being scrub-verified".to_owned(),
            ));
        }
        for (index, encoded) in FORBIDDEN_MARKER_HEX.iter().enumerate() {
            let marker = decode_marker_hex(encoded)?;
            if bytes
                .windows(marker.len())
                .any(|window| window == marker.as_slice())
            {
                return Err(ControllerError(format!(
                    "optimized paired-v8 controller retained forbidden legacy marker {index}"
                )));
            }
        }
        Ok(())
    }

    fn decode_marker_hex(encoded: &str) -> Result<Vec<u8>> {
        if encoded.len() % 2 != 0 {
            return Err(ControllerError(
                "paired-v8 binary scrub marker has odd length".to_owned(),
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
                "paired-v8 binary scrub marker is not lowercase hexadecimal".to_owned(),
            )),
        }
    }

    fn require_v8_update_root_unused() -> Result<()> {
        require_v8_update_root_unused_at(Path::new(V8_UPDATE_ROOT))
    }

    fn require_v8_update_root_unused_at(root: &Path) -> Result<()> {
        match fs::symlink_metadata(root) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(error) => {
                return Err(ControllerError(format!(
                    "cannot inspect paired-v8 update root {}: {error}",
                    root.display()
                )))
            }
            Ok(_) => require_directory(root, 0o700)?,
        }
        let mut entries = fs::read_dir(root).map_err(|error| {
            ControllerError(format!(
                "cannot enumerate paired-v8 update root {}: {error}",
                root.display()
            ))
        })?;
        if entries.next().transpose()?.is_some() {
            return Err(ControllerError(
                "paired-v8 update root already contains retained attempt evidence; a second attempt is not authorized"
                    .to_owned(),
            ));
        }
        Ok(())
    }

    fn prepare_v8_update_root_for_first_attempt() -> Result<()> {
        let root = Path::new(V8_UPDATE_ROOT);
        match fs::symlink_metadata(root) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                create_private_directory(root)?;
            }
            Err(error) => {
                return Err(ControllerError(format!(
                    "cannot inspect paired-v8 update root {}: {error}",
                    root.display()
                )))
            }
            Ok(_) => {}
        }
        require_v8_update_root_unused_at(root)
    }

    fn execute_paired_v8_update(
        repo: PathBuf,
        authorized_commit: &str,
        authorized_tree: &str,
    ) -> Result<()> {
        require_canonical_git_oid(authorized_commit, "authorized commit")?;
        require_canonical_git_oid(authorized_tree, "authorized tree")?;
        verify_machine_contract()?;
        let transaction_lock = acquire_update_transaction_lock_at(Path::new(V8_UPDATE_LOCK))?;
        verify_committed_v7_baseline()?;
        let initial_generation = verify_paired_v8_runtime()?;
        verify_isolated_pairing_items_present()?;
        let provenance = verify_paired_v8_git_provenance(&repo, true)?;
        require_authorized_provenance(&provenance, authorized_commit, authorized_tree)?;
        require_path_absent(Path::new(V8_ACTIVE_UPDATE), "active paired-v8 pointer")?;
        require_v8_update_root_unused()?;
        require_available_bytes(
            Path::new(PRIVATE_ROOT),
            2 * 1_024 * 1_024 * 1_024,
            "before creating paired-v8 update evidence",
        )?;

        let nonce = new_nonce()?;
        let evidence = PathBuf::from(V8_UPDATE_ROOT).join(format!(
            "paired-v8-update-{}-{}-{}",
            unix_seconds()?,
            std::process::id(),
            nonce
        ));
        prepare_v8_update_root_for_first_attempt()?;
        create_private_directory(&evidence)?;
        let layout = V8Layout::new(repo, evidence, &nonce);
        create_private_directory(&layout.rollback_dir)?;
        create_private_directory(&layout.failed_dir)?;
        let mut journal = V8Journal::create(&layout.journal)?;
        record_v8_install_hold_name(&layout)?;

        let result = perform_paired_v8_update(
            &layout,
            &mut journal,
            &provenance,
            &initial_generation,
            authorized_commit,
            authorized_tree,
        );
        match result {
            Ok(()) => Ok(()),
            Err(primary) => {
                if journal.state == V8State::Committed {
                    let _ = write_result(
                        &layout.result,
                        "success-with-warning",
                        Some(&primary.to_string()),
                    );
                    eprintln!(
                        "warning: paired-v8 update committed but final reporting failed: {primary}"
                    );
                    return Ok(());
                }
                let pointer_absent_before_stop = journal.state == V8State::StopInitiated
                    && matches!(
                        fs::symlink_metadata(V8_ACTIVE_UPDATE),
                        Err(error) if error.kind() == std::io::ErrorKind::NotFound
                    );
                let crossed_stop = journal.state >= V8State::StopInitiated
                    && journal.state < V8State::Committed
                    && !pointer_absent_before_stop;
                if !crossed_stop {
                    if layout.rollback_reserve.exists() {
                        let _ = release_rollback_reserve(&layout.rollback_reserve);
                    }
                    let _ = archive_v8_install_hold_root(&layout);
                    let _ = write_result(
                        &layout.result,
                        "failed-before-stop",
                        Some(&primary.to_string()),
                    );
                    return Err(primary);
                }
                verify_v8_active_pointer(&layout.evidence)?;
                match rollback_to_current_baseline(&layout, &mut journal, &transaction_lock) {
                    Ok(()) => {
                        write_result(&layout.result, "rolled-back", Some(&primary.to_string()))?;
                        retire_v8_active_pointer(&layout)?;
                        Err(ControllerError(format!(
                            "update failed and exact current isolated baseline was restored; evidence={}: {primary}",
                            layout.evidence.display()
                        )))
                    }
                    Err(rollback) => {
                        let _ = journal.record(
                            V8State::CriticalFailure,
                            &[("phase", "rollback".to_owned())],
                        );
                        let _ = write_result(
                            &layout.result,
                            "critical-failure",
                            Some(&format!("primary={primary}; rollback={rollback}")),
                        );
                        Err(ControllerError(format!(
                            "CRITICAL: paired-v8 update and rollback both failed; keep host offline; evidence={}: primary={primary}; rollback={rollback}",
                            layout.evidence.display()
                        )))
                    }
                }
            }
        }
    }

    fn perform_paired_v8_update(
        layout: &V8Layout,
        journal: &mut V8Journal,
        provenance: &Provenance,
        initial_generation: &LaunchGeneration,
        authorized_commit: &str,
        authorized_tree: &str,
    ) -> Result<()> {
        export_v8_source(layout, provenance)?;
        journal.record(
            V8State::SourceExported,
            &[
                ("commit", provenance.commit.clone()),
                ("tree", provenance.tree.clone()),
                ("initial_pid", initial_generation.pid.to_string()),
            ],
        )?;

        build_and_verify_v8_staged_app(layout)?;
        prepare_v8_deployment_reference(layout)?;
        journal.record(
            V8State::BuildVerified,
            &[(
                "executable_sha256",
                sha256(&layout.staged_app.join("Contents/MacOS/CaptureServer"))?,
            )],
        )?;

        require_available_bytes(
            Path::new(PRIVATE_ROOT),
            1_024 * 1_024 * 1_024,
            "after staging and immediately before stopping the current isolated host",
        )?;
        verify_v8_deployment_reference(layout)?;
        verify_isolated_pairing_items_present()?;
        verify_v7_pointer_unchanged()?;
        let revalidated = verify_paired_v8_runtime()?;
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

        let boundary_provenance = verify_paired_v8_git_provenance(&layout.repo, true)?;
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

        let reserve = allocate_rollback_reserve(&layout.rollback_reserve, 8 * 1_024 * 1_024)?;
        journal.record(
            V8State::StopInitiated,
            &[
                ("reserve_device", reserve.0.to_string()),
                ("reserve_inode", reserve.1.to_string()),
                ("reserve_bytes", reserve.2.to_string()),
            ],
        )?;
        publish_v8_active_pointer(&layout.evidence)?;
        prepare_v8_install_hold(layout)?;
        journal.record(V8State::InstallHoldVerified, &[])?;

        verify_v8_active_pointer(&layout.evidence)?;
        verify_v8_deployment_reference(layout)?;
        verify_isolated_pairing_items_present()?;
        verify_v7_pointer_unchanged()?;
        let final_generation = verify_paired_v8_runtime()?;
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

        bootout_exact_new_job()?;
        wait_for_no_capture_servers(Duration::from_secs(30))?;
        require_service_absent(NEW_LAUNCH_AGENT_LABEL)?;
        verify_protected_legacy_absent()?;
        let lock = acquire_unowned_shared_lock()?;
        verify_v8_active_pointer(&layout.evidence)?;
        verify_v7_pointer_unchanged()?;
        verify_isolated_pairing_items_present()?;
        verify_v8_deployment_reference(layout)?;
        verify_current_baseline_app_at(Path::new(NEW_APP), true)?;
        journal.record(V8State::CurrentStopped, &[])?;

        rename_exclusive(Path::new(NEW_APP), &layout.rollback_app)?;
        fsync_parent(Path::new(NEW_APP))?;
        fsync_parent(&layout.rollback_app)?;
        verify_current_baseline_app_at(&layout.rollback_app, false)?;
        journal.record(V8State::CurrentHeld, &[])?;

        rename_exclusive(&layout.install_hold, Path::new(NEW_APP))?;
        fsync_parent(&layout.install_hold)?;
        fsync_parent(Path::new(NEW_APP))?;
        fs::remove_dir(&layout.install_hold_root).map_err(|error| {
            ControllerError(format!(
                "cannot remove empty paired-v8 install-hold root {}: {error}",
                layout.install_hold_root.display()
            ))
        })?;
        fsync_parent(&layout.install_hold_root)?;
        verify_v8_installed_matches_reference(layout)?;
        verify_isolated_pairing_items_present()?;
        verify_v7_pointer_unchanged()?;
        journal.record(V8State::NewPublished, &[])?;
        drop(lock);

        let checkpoint = capture_log_checkpoint()?;
        bootstrap_exact_new_job()?;
        journal.record(V8State::PersistentBootstrapped, &[])?;
        let generation = wait_for_paired_v8_launch_generation(Duration::from_secs(45))?;
        verify_paired_v8_deployment(layout, &checkpoint, &generation)?;
        verify_isolated_pairing_items_present()?;
        verify_v7_pointer_unchanged()?;
        journal.record(
            V8State::ReadyVerified,
            &[
                ("pid", generation.pid.to_string()),
                ("runs", generation.runs.to_string()),
                ("nonce", generation.nonce.clone()),
            ],
        )?;
        verify_protected_legacy_absent()?;
        release_rollback_reserve(&layout.rollback_reserve)?;
        journal.record(V8State::Committed, &[])?;
        if let Err(error) = write_result(&layout.result, "success", None) {
            eprintln!("warning: paired-v8 update committed but result recording failed: {error}");
        }
        println!(
            "PAIRED_V8_HOST_UPDATE_COMMITTED evidence={} pid={} rollback=current-isolated-retained pairing=preserved",
            layout.evidence.display(),
            generation.pid
        );
        Ok(())
    }

    fn rollback_existing_paired_v8_update(repo: PathBuf) -> Result<()> {
        verify_machine_contract()?;
        let transaction_lock = acquire_update_transaction_lock_at(Path::new(V8_UPDATE_LOCK))?;
        verify_committed_v7_baseline()?;
        let evidence =
            read_update_pointer_at(Path::new(V8_ACTIVE_UPDATE), Path::new(V8_UPDATE_ROOT))?;
        let layout = v8_layout_from_existing(repo, evidence)?;
        let mut journal = V8Journal::open(&layout.journal)?;
        if journal.state == V8State::RolledBack {
            verify_paired_v8_runtime()?;
            verify_isolated_pairing_items_present()?;
            ensure_rolled_back_result(&layout.result)?;
            retire_v8_active_pointer(&layout)?;
            println!("PAIRED_V8_HOST_UPDATE_ALREADY_ROLLED_BACK");
            return Ok(());
        }
        rollback_to_current_baseline(&layout, &mut journal, &transaction_lock)?;
        write_result(&layout.result, "rolled-back-by-explicit-request", None)?;
        retire_v8_active_pointer(&layout)?;
        println!(
            "PAIRED_V8_HOST_UPDATE_ROLLED_BACK evidence={} pairing=preserved",
            layout.evidence.display()
        );
        Ok(())
    }

    fn rollback_to_current_baseline(
        layout: &V8Layout,
        journal: &mut V8Journal,
        _transaction_lock: &UpdateTransactionLock,
    ) -> Result<()> {
        journal.require_healthy()?;
        verify_v8_active_pointer(&layout.evidence)?;
        verify_v7_pointer_unchanged()?;
        verify_isolated_pairing_items_present()?;
        if journal.state == V8State::RolledBack {
            verify_paired_v8_runtime()?;
            return Ok(());
        }
        let already_rolling_back = matches!(
            journal.state,
            V8State::RollbackStarted
                | V8State::FailedNewArchived
                | V8State::CurrentRestored
                | V8State::CurrentBootstrapped
        );
        if !already_rolling_back {
            journal.record(V8State::RollbackStarted, &[])?;
        }
        if layout.rollback_reserve.exists() {
            release_rollback_reserve(&layout.rollback_reserve)?;
        }

        archive_v8_install_hold_root(layout)?;
        verify_v8_active_pointer(&layout.evidence)?;
        verify_v7_pointer_unchanged()?;
        verify_isolated_pairing_items_present()?;
        verify_reviewed_launch_agent_unchanged()?;
        bootout_paired_v8_job_if_loaded(layout)?;
        wait_for_no_capture_servers(Duration::from_secs(30))?;
        require_service_absent(NEW_LAUNCH_AGENT_LABEL)?;
        verify_protected_legacy_absent()?;
        let lock = acquire_unowned_shared_lock()?;
        verify_isolated_pairing_items_present()?;
        verify_v7_pointer_unchanged()?;

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
                verify_v8_installed_matches_reference(layout)?;
                rename_exclusive(Path::new(NEW_APP), &layout.failed_app)?;
                fsync_parent(Path::new(NEW_APP))?;
                fsync_parent(&layout.failed_app)?;
                if journal.state == V8State::RollbackStarted {
                    journal.record(V8State::FailedNewArchived, &[])?;
                }
            } else if failed_exists && journal.state == V8State::RollbackStarted {
                journal.record(V8State::FailedNewArchived, &[])?;
            }

            require_path_absent(Path::new(NEW_APP), "canonical app before baseline restore")?;
            rename_exclusive(&layout.rollback_app, Path::new(NEW_APP))?;
            fsync_parent(Path::new(NEW_APP))?;
            fsync_parent(&layout.rollback_app)?;
            verify_current_baseline_app_at(Path::new(NEW_APP), true)?;
            if matches!(
                journal.state,
                V8State::RollbackStarted | V8State::FailedNewArchived
            ) {
                journal.record(V8State::CurrentRestored, &[])?;
            }
        } else if canonical_exists {
            verify_current_baseline_app_at(Path::new(NEW_APP), true)?;
            if matches!(
                journal.state,
                V8State::RollbackStarted | V8State::FailedNewArchived
            ) {
                journal.record(V8State::CurrentRestored, &[])?;
            }
        } else {
            return Err(ControllerError(
                "rollback cannot locate the exact current isolated baseline".to_owned(),
            ));
        }

        if !matches!(
            journal.state,
            V8State::CurrentRestored | V8State::CurrentBootstrapped
        ) {
            return Err(ControllerError(format!(
                "paired-v8 rollback topology is not resumable from {}",
                journal.state.token()
            )));
        }
        verify_isolated_pairing_items_present()?;
        verify_v7_pointer_unchanged()?;
        drop(lock);

        verify_current_baseline_app_at(Path::new(NEW_APP), true)?;
        let checkpoint = capture_log_checkpoint()?;
        bootstrap_exact_new_job()?;
        if journal.state == V8State::CurrentRestored {
            journal.record(V8State::CurrentBootstrapped, &[])?;
        }
        let generation = wait_for_paired_v8_launch_generation(Duration::from_secs(45))?;
        verify_current_baseline_oracle_pins()?;
        verify_deployment(
            Path::new(CURRENT_BASELINE_SOURCE_EXPORT),
            Path::new(CURRENT_BASELINE_APP),
            &checkpoint,
            &generation,
        )?;
        verify_isolated_pairing_items_present()?;
        verify_v7_pointer_unchanged()?;
        verify_protected_legacy_absent()?;
        journal.record(V8State::RolledBack, &[])?;
        verify_paired_v8_runtime()?;
        Ok(())
    }

    fn v8_layout_from_existing(repo: PathBuf, evidence: PathBuf) -> Result<V8Layout> {
        require_descendant(Path::new(V8_UPDATE_ROOT), &evidence)?;
        require_directory(&evidence, 0o700)?;
        let install_hold_name = read_bounded_utf8(&evidence.join("install-hold-name.txt"), 512)?;
        let install_hold_root = PathBuf::from(install_hold_name.trim_end());
        let nonce = install_hold_root
            .file_name()
            .and_then(|value| value.to_str())
            .and_then(|value| value.strip_prefix(HIDDEN_INSTALL_PREFIX))
            .ok_or_else(|| {
                ControllerError("paired-v8 install-hold name is malformed".to_owned())
            })?;
        let expected = V8Layout::new(repo, evidence, nonce);
        if expected.install_hold_root != install_hold_root {
            return Err(ControllerError(
                "paired-v8 install-hold path escaped its recorded layout".to_owned(),
            ));
        }
        require_v8_install_hold_layout(&expected.install_hold_root, &expected.install_hold)?;
        Ok(expected)
    }

    fn export_v8_source(layout: &V8Layout, provenance: &Provenance) -> Result<()> {
        require_path_absent(&layout.source_tar, "v8 source archive")?;
        require_path_absent(&layout.source_export, "v8 source export")?;
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
        require_success(status, "git archive for paired-v8 update")?;
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
        require_output_success(&output, "extract paired-v8 source archive")?;
        require_regular(
            &layout
                .source_export
                .join("macOS/scripts/build-opensteamer-host-app.sh"),
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        require_regular(
            &layout
                .source_export
                .join("macOS/scripts/opensteamer-host-paired-v8-update-controller.rs"),
            0o600,
        )?;
        let mut record = create_new_private(&layout.evidence.join("provenance.txt"))?;
        writeln!(
            record,
            "functional_source_commit={EXPECTED_FUNCTIONAL_SOURCE_COMMIT}"
        )?;
        writeln!(
            record,
            "functional_source_tree={EXPECTED_FUNCTIONAL_SOURCE_TREE}"
        )?;
        writeln!(record, "release_commit={}", provenance.commit)?;
        writeln!(record, "release_tree={}", provenance.tree)?;
        writeln!(record, "commit={}", provenance.commit)?;
        writeln!(record, "tree={}", provenance.tree)?;
        writeln!(record, "upstream={}", provenance.upstream)?;
        writeln!(record, "remote={}", provenance.remote)?;
        writeln!(
            record,
            "source_archive_sha256={}",
            sha256(&layout.source_tar)?
        )?;
        record.sync_all()?;
        fsync_parent(&layout.evidence.join("provenance.txt"))
    }

    fn build_and_verify_v8_staged_app(layout: &V8Layout) -> Result<()> {
        require_path_absent(&layout.stage_output, "paired-v8 staged output")?;
        require_path_absent(&layout.scratch, "paired-v8 SwiftPM scratch")?;
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
        require_success(status, "fresh signed paired-v8 host build")?;
        verify_staged_app_contract(
            &layout.source_export,
            &layout.staged_app,
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        let executable = layout.staged_app.join("Contents/MacOS/CaptureServer");
        if sha256(&executable)? == CURRENT_BASELINE_EXECUTABLE_SHA256 {
            return Err(ControllerError(
                "paired-v8 staged executable is byte-identical to the current isolated baseline"
                    .to_owned(),
            ));
        }
        verify_staged_pairing_namespace(&executable)
    }

    fn verify_staged_pairing_namespace(executable: &Path) -> Result<()> {
        let strings = command_output("/usr/bin/strings", &[path_text(executable)?], None)?;
        require_output_success(&strings, "inspect paired-v8 staged pairing namespace")?;
        let text = decode_utf8(&strings.stdout, "paired-v8 strings output")?;
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
                "paired-v8 staged pairing namespace is not isolated: isolated_count={isolated_count} protected_count={protected_count}"
            )));
        }
        Ok(())
    }

    fn prepare_v8_deployment_reference(layout: &V8Layout) -> Result<()> {
        require_path_absent(
            &layout.deployment_reference_dir,
            "paired-v8 deployment-reference directory",
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
        require_output_success(&output, "copy paired-v8 deployment reference")?;
        verify_v8_deployment_reference(layout)
    }

    fn verify_v8_deployment_reference(layout: &V8Layout) -> Result<()> {
        require_directory(&layout.deployment_reference_dir, 0o700)?;
        for app in [&layout.staged_app, &layout.deployment_reference_app] {
            verify_staged_app_contract(&layout.source_export, app, SOURCE_EXPORT_EXECUTABLE_MODE)?;
            let executable = app.join("Contents/MacOS/CaptureServer");
            if sha256(&executable)? == CURRENT_BASELINE_EXECUTABLE_SHA256 {
                return Err(ControllerError(
                    "paired-v8 deployment reference equals current isolated baseline".to_owned(),
                ));
            }
            verify_staged_pairing_namespace(&executable)?;
        }
        require_tree_equal(&layout.staged_app, &layout.deployment_reference_app)
    }

    fn prepare_v8_install_hold(layout: &V8Layout) -> Result<()> {
        require_v8_install_hold_layout(&layout.install_hold_root, &layout.install_hold)?;
        require_path_absent(&layout.install_hold_root, "paired-v8 hidden install hold")?;
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
        require_output_success(&output, "copy paired-v8 install hold")?;
        verify_bundle(
            &layout.source_export,
            &layout.install_hold,
            false,
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        require_tree_equal(&layout.deployment_reference_app, &layout.install_hold)
    }

    fn record_v8_install_hold_name(layout: &V8Layout) -> Result<()> {
        require_v8_install_hold_layout(&layout.install_hold_root, &layout.install_hold)?;
        let path = layout.evidence.join("install-hold-name.txt");
        let mut record = create_new_private(&path)?;
        writeln!(record, "{}", layout.install_hold_root.display())?;
        record.sync_all()?;
        fsync_parent(&path)
    }

    fn archive_v8_install_hold_root(layout: &V8Layout) -> Result<()> {
        require_v8_install_hold_layout(&layout.install_hold_root, &layout.install_hold)?;
        let archive = layout.failed_dir.join("partial-install-hold-root");
        if archive.parent() != Some(layout.failed_dir.as_path()) {
            return Err(ControllerError(
                "partial install-hold quarantine escaped the retained failed-new directory"
                    .to_owned(),
            ));
        }
        require_directory(&layout.failed_dir, 0o700)?;
        archive_v8_install_hold_root_at(&layout.install_hold_root, &archive)
    }

    fn archive_v8_install_hold_root_at(install_hold_root: &Path, archive: &Path) -> Result<()> {
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

    fn verify_v8_installed_matches_reference(layout: &V8Layout) -> Result<()> {
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

    fn verify_paired_v8_deployment(
        layout: &V8Layout,
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

    fn verify_committed_v5_baseline() -> Result<()> {
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
        if reserve_metadata.dev() != COMMITTED_V5_RESERVE_DEVICE
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
        verify_committed_v5_baseline()?;
        require_regular(Path::new(COMMITTED_V6_POINTER), 0o600)?;
        if sha256(Path::new(COMMITTED_V6_POINTER))? != COMMITTED_V6_POINTER_SHA256
            || read_bounded_utf8(Path::new(COMMITTED_V6_POINTER), 512)?
                != format!("{COMMITTED_V6_EVIDENCE}\n")
        {
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
        require_exact_child_names(
            Path::new(COMMITTED_V6_UPDATE_ROOT),
            &[evidence.file_name().and_then(|name| name.to_str()).ok_or_else(|| {
                ControllerError("committed v6 evidence name is invalid".to_owned())
            })?],
            "committed v6 update root",
        )?;
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
        if read_bounded_utf8(&evidence.join("provenance.txt"), 1_024)?
            != expected_provenance
        {
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
        let evidence_metadata = fs::symlink_metadata(evidence)?;
        if reserve_metadata.dev() != evidence_metadata.dev()
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
        require_exact_child_names(&failed_new, &[], "committed v6 failed-new directory")?;
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
            let path = Path::new(COMMITTED_V6_BASELINE_SOURCE_EXPORT).join(relative);
            require_regular(&path, mode)?;
            if sha256(&path)? != expected_sha256 {
                return Err(ControllerError(format!(
                    "committed v6 updater source changed: {}",
                    path.display()
                )));
            }
        }
        let launcher = Path::new(COMMITTED_V6_BASELINE_SOURCE_EXPORT)
            .join("macOS/scripts/update-opensteamer-host-paired-v6.sh");
        let expected_binary_pin =
            format!("EXPECTED_BINARY_SHA256='{COMMITTED_V6_CONTROLLER_BINARY_SHA256}'");
        if read_bounded_utf8(&launcher, 32 * 1_024)?
            .lines()
            .filter(|line| *line == expected_binary_pin)
            .count()
            != 1
        {
            return Err(ControllerError(
                "committed v6 launcher binary postimage pin changed".to_owned(),
            ));
        }
        verify_committed_v6_oracle_pins()?;
        let reference = Path::new(COMMITTED_V6_BASELINE_APP);
        verify_bundle(
            Path::new(COMMITTED_V6_BASELINE_SOURCE_EXPORT),
            reference,
            false,
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        let executable = reference.join("Contents/MacOS/CaptureServer");
        if sha256(&executable)? != COMMITTED_V6_BASELINE_EXECUTABLE_SHA256
            || code_hash(reference)? != COMMITTED_V6_BASELINE_CDHASH
        {
            return Err(ControllerError(
                "committed v6 isolated deployment reference changed".to_owned(),
            ));
        }
        require_code_identity(reference)?;
        verify_staged_pairing_namespace(&executable)?;
        let staged = evidence.join("staged-output/opensteamer Host.app");
        verify_staged_app_contract(
            Path::new(COMMITTED_V6_BASELINE_SOURCE_EXPORT),
            &staged,
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        require_tree_equal(reference, &staged)?;
        verify_committed_v5_app_at(&evidence.join("rollback-current/opensteamer Host.app"))
    }

    fn verify_committed_v7_baseline() -> Result<String> {
        verify_committed_v6_baseline()?;
        require_regular(Path::new(COMMITTED_V7_POINTER), 0o600)?;
        let pointer_metadata = fs::symlink_metadata(COMMITTED_V7_POINTER)?;
        if pointer_metadata.ino() != COMMITTED_V7_POINTER_INODE
            || sha256(Path::new(COMMITTED_V7_POINTER))? != COMMITTED_V7_POINTER_SHA256
            || read_bounded_utf8(Path::new(COMMITTED_V7_POINTER), 512)?
                != format!("{COMMITTED_V7_EVIDENCE}\n")
        {
            return Err(ControllerError(
                "committed v7 retry-4 pointer identity or bytes changed".to_owned(),
            ));
        }
        verify_update_pointer_at(
            Path::new(COMMITTED_V7_POINTER),
            Path::new(COMMITTED_V7_EVIDENCE),
            Path::new(COMMITTED_V7_UPDATE_ROOT),
        )?;
        let update_root = Path::new(COMMITTED_V7_UPDATE_ROOT);
        require_directory(update_root, 0o700)?;
        require_exact_child_names(
            update_root,
            &[
                "paired-v7-update-1787367704-92913-bba21548-458c-4d31-bd0a-eccdb282c02a",
                "paired-v7-update-retry-1-1787373601-48365-716c0ed7-8cd5-4b9f-9d64-a3169a077a25",
                "paired-v7-update-retry-2-1787375620-74854-34192453-910c-4331-a0d0-d9cb250b1f9c",
                "paired-v7-update-retry-3-1787392225-87409-09602523-891e-4822-bf48-650a3b7f9637",
                COMMITTED_V7_EVIDENCE_NAME,
            ],
            "committed v7 update root",
        )?;
        let evidence = Path::new(COMMITTED_V7_EVIDENCE);
        require_directory(evidence, 0o700)?;
        if fs::symlink_metadata(evidence)?.ino() != COMMITTED_V7_EVIDENCE_INODE {
            return Err(ControllerError(
                "committed v7 retry-4 evidence inode changed".to_owned(),
            ));
        }
        require_exact_child_names(
            evidence,
            &[
                "build.stderr",
                "build.stdout",
                "deployment-reference",
                "driver-transaction-record.txt",
                "failed-new",
                "functional-inputs.txt",
                "install-hold-name.txt",
                "journal.log",
                "probes",
                "production-driver-v7",
                "provenance.txt",
                "result.txt",
                "rollback-current",
                "rollback-reserve.bin",
                "source-export",
                "source.tar",
                "staged-output",
                "swiftpm-scratch",
            ],
            "committed v7 retry-4 evidence",
        )?;
        for (relative, mode, expected) in [
            ("journal.log", 0o600, COMMITTED_V7_JOURNAL_SHA256),
            ("result.txt", 0o600, COMMITTED_V7_RESULT_SHA256),
            ("provenance.txt", 0o600, COMMITTED_V7_PROVENANCE_SHA256),
            ("source.tar", 0o600, COMMITTED_V7_SOURCE_ARCHIVE_SHA256),
            (
                "install-hold-name.txt",
                0o600,
                COMMITTED_V7_INSTALL_HOLD_NAME_SHA256,
            ),
            ("build.stdout", 0o600, COMMITTED_V7_BUILD_STDOUT_SHA256),
            ("build.stderr", 0o600, COMMITTED_V7_BUILD_STDERR_SHA256),
            (
                "functional-inputs.txt",
                0o600,
                COMMITTED_V7_FUNCTIONAL_INPUTS_SHA256,
            ),
            (
                "driver-transaction-record.txt",
                0o600,
                COMMITTED_V7_DRIVER_RECORD_SHA256,
            ),
        ] {
            let path = evidence.join(relative);
            require_regular(&path, mode)?;
            if sha256(&path)? != expected {
                return Err(ControllerError(format!(
                    "committed v7 retry-4 evidence changed: {}",
                    path.display()
                )));
            }
        }
        if read_bounded_utf8(&evidence.join("result.txt"), 128)? != "result=success\n" {
            return Err(ControllerError(
                "committed v7 retry-4 result is not exact success".to_owned(),
            ));
        }
        let expected_provenance = format!(
            "commit={COMMITTED_V7_SOURCE_COMMIT}\ntree={COMMITTED_V7_SOURCE_TREE}\nfunctional_source_commit=7beb049226ada83e97afba3e60089469d0eeeef6\nfunctional_source_tree=60e2df01afe1b4c09362b8e1b55efa709f23a748\nauthorized_release_commit={COMMITTED_V7_SOURCE_COMMIT}\nauthorized_release_tree={COMMITTED_V7_SOURCE_TREE}\nupstream=origin/{EXPECTED_SOURCE_BRANCH}\nremote={EXPECTED_REMOTE}\nfunctional_inputs_sha256=6201d2ba57d50217246b151a623303658a587bab57ee484f3c85e5a34a4a9e28\nfunctional_input_evidence_sha256={COMMITTED_V7_FUNCTIONAL_INPUTS_SHA256}\nsource_archive_sha256={COMMITTED_V7_SOURCE_ARCHIVE_SHA256}\n"
        );
        if read_bounded_utf8(&evidence.join("provenance.txt"), 2_048)?
            != expected_provenance
        {
            return Err(ControllerError(
                "committed v7 retry-4 provenance bytes changed".to_owned(),
            ));
        }
        if read_bounded_utf8(&evidence.join("install-hold-name.txt"), 512)?
            != format!("{COMMITTED_V7_INSTALL_HOLD_ROOT}\n")
        {
            return Err(ControllerError(
                "committed v7 retry-4 install-hold record changed".to_owned(),
            ));
        }
        require_path_absent(
            Path::new(COMMITTED_V7_INSTALL_HOLD_ROOT),
            "committed v7 retry-4 install-hold root",
        )?;
        let reserve = evidence.join("rollback-reserve.bin");
        require_regular(&reserve, 0o600)?;
        let reserve_metadata = fs::symlink_metadata(&reserve)?;
        if reserve_metadata.dev() != fs::symlink_metadata(evidence)?.dev()
            || reserve_metadata.ino() != COMMITTED_V7_RESERVE_INODE
            || reserve_metadata.len() != 0
            || reserve_metadata.blocks() != 0
        {
            return Err(ControllerError(
                "committed v7 retry-4 released rollback reserve changed".to_owned(),
            ));
        }
        let failed_new = evidence.join("failed-new");
        require_directory(&failed_new, 0o700)?;
        require_exact_child_names(&failed_new, &[], "committed v7 failed-new directory")?;
        verify_v7_retained_probe_and_driver_evidence(evidence)?;
        for (relative, mode, expected_sha256) in [
            (
                "macOS/scripts/opensteamer-host-paired-v7-update-controller.rs",
                0o600,
                COMMITTED_V7_CONTROLLER_SOURCE_SHA256,
            ),
            (
                "macOS/scripts/update-opensteamer-host-paired-v7.sh",
                0o700,
                COMMITTED_V7_LAUNCHER_SOURCE_SHA256,
            ),
            (
                "macOS/scripts/opensteamer-host-post-v20-update-controller.rs",
                0o600,
                COMMITTED_V7_INCLUDED_V1_SOURCE_SHA256,
            ),
        ] {
            let path = Path::new(COMMITTED_V7_BASELINE_SOURCE_EXPORT).join(relative);
            require_regular(&path, mode)?;
            if sha256(&path)? != expected_sha256 {
                return Err(ControllerError(format!(
                    "committed v7 updater source changed: {}",
                    path.display()
                )));
            }
        }
        let launcher = Path::new(COMMITTED_V7_BASELINE_SOURCE_EXPORT)
            .join("macOS/scripts/update-opensteamer-host-paired-v7.sh");
        let expected_binary_pin =
            format!("EXPECTED_BINARY_SHA256='{COMMITTED_V7_CONTROLLER_BINARY_SHA256}'");
        if read_bounded_utf8(&launcher, 32 * 1_024)?
            .lines()
            .filter(|line| *line == expected_binary_pin)
            .count()
            != 1
        {
            return Err(ControllerError(
                "committed v7 launcher binary postimage pin changed".to_owned(),
            ));
        }
        verify_current_baseline_oracle_pins()?;
        let reference = Path::new(COMMITTED_V7_BASELINE_APP);
        verify_bundle(
            Path::new(COMMITTED_V7_BASELINE_SOURCE_EXPORT),
            reference,
            false,
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        let executable = reference.join("Contents/MacOS/CaptureServer");
        if sha256(&executable)? != COMMITTED_V7_BASELINE_EXECUTABLE_SHA256
            || sha256(&reference.join("Contents/Info.plist"))?
                != COMMITTED_V7_BASELINE_INFO_PLIST_SHA256
            || code_hash(reference)? != COMMITTED_V7_BASELINE_CDHASH
        {
            return Err(ControllerError(
                "committed v7 isolated deployment reference changed".to_owned(),
            ));
        }
        require_code_identity(reference)?;
        verify_staged_pairing_namespace(&executable)?;
        let staged = evidence.join("staged-output/opensteamer Host.app");
        verify_staged_app_contract(
            Path::new(COMMITTED_V7_BASELINE_SOURCE_EXPORT),
            &staged,
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        require_tree_equal(reference, &staged)?;
        verify_committed_v6_app_at(&evidence.join("rollback-current/opensteamer Host.app"))?;
        verify_v7_outer_root_and_driver_immutable()
    }

    fn require_exact_child_names(root: &Path, expected: &[&str], label: &str) -> Result<()> {
        let mut actual = fs::read_dir(root)?
            .map(|entry| {
                entry.and_then(|entry| {
                    entry.file_name().into_string().map_err(|_| {
                        std::io::Error::new(
                            std::io::ErrorKind::InvalidData,
                            "non-UTF-8 child name",
                        )
                    })
                })
            })
            .collect::<std::io::Result<Vec<_>>>()?;
        actual.sort();
        let mut expected_values = expected.iter().map(|name| (*name).to_owned()).collect::<Vec<_>>();
        expected_values.sort();
        if actual != expected_values {
            return Err(ControllerError(format!(
                "{label} child set is not exact"
            )));
        }
        Ok(())
    }

    fn verify_v7_retained_probe_and_driver_evidence(evidence: &Path) -> Result<()> {
        let probes = evidence.join("probes");
        let production = evidence.join("production-driver-v7");
        require_directory(&probes, 0o700)?;
        require_directory(&production, 0o700)?;
        for (relative, mode, expected) in [
            ("probes/guardian-self-test.json", 0o600, "035e3cd9c881c75f101aed88f749c730cff5293c3ca04dfb88f7c14fef84275d"),
            ("probes/mirror-loopback-self-test.json", 0o600, "a1b4787f016786908a6174f7889040df14703bc3c5f5dfc3d97b5b37164e8540"),
            ("probes/mirror-loopback.json", 0o600, "be350c958ce0c383ced7a38d850deb32784aeeac1fda4e833ee0353b341c4aaf"),
            ("probes/mirror-loopback.stderr", 0o600, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("probes/mirror-loopback.stdout", 0o600, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("probes/opensteamer-public-vpio-probe", 0o755, "0ec9e1a0cc5f253cc569134ce2be024a7f3ae6ad211fa7d20fe6436c0bac84c8"),
            ("probes/opensteamer-v7-default-route-guardian", 0o755, "53ee0ce919f1b61c9d66a95d3ec8b417fba85df9f925fd24146d70b663fa995c"),
            ("probes/physical-virtual-microphone-probe", 0o755, "b344eb24cde4ab1881b065e2ef0aa208aef12dbdd31fea7259eabc5ad5b6abaf"),
            ("probes/vpio-default-route-state.json", 0o600, "4a95c6e17a46e122892439a2a54abb5f968d7f8d83a7b10345bb5918dd6f46cd"),
            ("probes/vpio-default-route-state.sha256", 0o600, "ad9e5d80a93d1923f767fcea6a9c6c06018c7eaea2095b13c4eed08f7ed5296d"),
            ("probes/vpio-guardian-result.json", 0o600, "9a273511365adc6393c3e2a39b6560edea248de267a3843ba36d68de725b43ff"),
            ("probes/vpio-guardian-result.process.stderr", 0o600, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("probes/vpio-guardian-result.process.stdout", 0o600, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("probes/vpio.stderr", 0o600, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("probes/vpio.stdout", 0o600, "50d52ba92d3e77f0d2688c4c0f07b515a5908742b6b45fb034913bd7ea855114"),
            ("production-driver-v7/OpensteamerVirtualMicrophone-v7.pkg", 0o600, "e2b13dde169a7994a50b819e414212e884136b0ab0c40c482531b8f8dc2a3f45"),
            ("production-driver-v7/candidate-manifest.txt", 0o400, "88c842ec87374b6cbf1f5de32ae7788e15cf42f81fcb9213952ea8338a11f1a1"),
            ("production-driver-v7/verification.txt", 0o400, "02202147f3281049c28696c0668c9547ad3913a2daaf218c9c3f6b2bc0bcbe98"),
        ] {
            let path = evidence.join(relative);
            require_regular(&path, mode)?;
            if sha256(&path)? != expected {
                return Err(ControllerError(format!(
                    "committed v7 probe/driver evidence changed: {}",
                    path.display()
                )));
            }
        }
        verify_exact_v7_driver_bundle(&production.join("OpensteamerVirtualMicrophone.driver"), 501)
    }

    fn verify_v7_outer_root_and_driver_immutable() -> Result<String> {
        let before = read_v7_outer_root_snapshot()?;
        verify_exact_v7_driver_bundle(Path::new(V7_PRODUCT_DRIVER), 0)?;
        let canonical = fs::symlink_metadata(V7_PRODUCT_DRIVER)?;
        if canonical.dev() != V7_PRODUCT_DRIVER_DEVICE
            || canonical.ino() != V7_PRODUCT_DRIVER_INODE
        {
            return Err(ControllerError(
                "canonical v7 driver outer identity changed".to_owned(),
            ));
        }
        let after = read_v7_outer_root_snapshot()?;
        if after != before {
            return Err(ControllerError(
                "root-owned v7 outer transaction topology changed during read-only proof"
                    .to_owned(),
            ));
        }
        Ok(before)
    }

    fn read_v7_outer_root_snapshot() -> Result<String> {
        let parent = Path::new(V7_ROOT_SUPPORT_PARENT);
        let parent_metadata = fs::symlink_metadata(parent)?;
        if !parent_metadata.file_type().is_dir()
            || parent_metadata.file_type().is_symlink()
            || parent_metadata.uid() != 0
            || parent_metadata.gid() != 0
            || parent_metadata.permissions().mode() & 0o777 != 0o755
            || parent_metadata.st_flags() != 0
            || parent_metadata.dev() != V7_PRODUCT_DRIVER_DEVICE
            || parent_metadata.ino() != V7_ROOT_SUPPORT_PARENT_INODE
            || parent_metadata.nlink() != 8
            || parent_metadata.len() != 256
        {
            return Err(ControllerError(
                "root-owned opensteamer support parent identity changed".to_owned(),
            ));
        }
        require_exact_child_names(parent, &V7_ROOT_OUTER_NAMES, "root v7 outer support parent")?;
        let expected_children = [
            ("driver-transactions-v7", 27_777_175_u64, 5_u64, 160_u64),
            ("privileged-v7", 27_777_169, 5, 160),
            ("privileged-v7-recovery-retry-2", 27_803_148, 5, 160),
            ("privileged-v7-recovery-retry-2-v2", 27_807_654, 5, 160),
            ("privileged-v7-v2", 27_832_673, 5, 160),
            ("privileged-v7-v3", 27_870_738, 5, 160),
        ];
        let mut snapshot = format!(
            "parent={}:{}:{}:{}:{}\n",
            parent_metadata.dev(),
            parent_metadata.ino(),
            parent_metadata.nlink(),
            parent_metadata.len(),
            parent_metadata.st_flags()
        );
        for (name, inode, nlink, length) in expected_children {
            let path = parent.join(name);
            let metadata = fs::symlink_metadata(&path)?;
            if !metadata.file_type().is_dir()
                || metadata.file_type().is_symlink()
                || metadata.uid() != 0
                || metadata.gid() != 0
                || metadata.permissions().mode() & 0o777 != 0o700
                || metadata.st_flags() != 0
                || metadata.dev() != V7_PRODUCT_DRIVER_DEVICE
                || metadata.ino() != inode
                || metadata.nlink() != nlink
                || metadata.len() != length
            {
                return Err(ControllerError(format!(
                    "root-owned v7 outer child identity changed: {}",
                    path.display()
                )));
            }
            snapshot.push_str(&format!(
                "child={name}:{}:{}:{}:{}:{}\n",
                metadata.dev(),
                metadata.ino(),
                metadata.nlink(),
                metadata.len(),
                metadata.st_flags()
            ));
        }
        let transaction_parent = fs::symlink_metadata(V7_ROOT_TRANSACTION_PARENT)?;
        if transaction_parent.ino() != V7_ROOT_TRANSACTION_PARENT_INODE {
            return Err(ControllerError(
                "v7 root transaction-parent outer inode changed".to_owned(),
            ));
        }
        Ok(snapshot)
    }

    fn verify_exact_v7_driver_bundle(bundle: &Path, expected_uid: u32) -> Result<()> {
        let expected = [
            (".", "directory", 0o755),
            ("Contents", "directory", 0o755),
            ("Contents/Info.plist", "file", 0o644),
            ("Contents/MacOS", "directory", 0o755),
            ("Contents/MacOS/OpensteamerVirtualMicrophone", "file", 0o755),
            ("Contents/Resources", "directory", 0o755),
            ("Contents/Resources/APPLE_SAMPLE_LICENSE.txt", "file", 0o644),
            ("Contents/Resources/en.lproj", "directory", 0o755),
            ("Contents/Resources/en.lproj/Localizable.strings", "file", 0o644),
            ("Contents/_CodeSignature", "directory", 0o755),
            ("Contents/_CodeSignature/CodeResources", "file", 0o644),
        ];
        let mut actual = Vec::new();
        fn walk_v7_driver(
            root: &Path,
            relative: &Path,
            expected_uid: u32,
            output: &mut Vec<(String, String, u32)>,
        ) -> Result<()> {
            let absolute = if relative.as_os_str().is_empty() {
                root.to_path_buf()
            } else {
                root.join(relative)
            };
            let metadata = fs::symlink_metadata(&absolute)?;
            if metadata.file_type().is_symlink()
                || metadata.uid() != expected_uid
                || metadata.gid() != if expected_uid == 0 { 0 } else { 20 }
                || metadata.st_flags() != 0
                || (metadata.file_type().is_file() && metadata.nlink() != 1)
            {
                return Err(ControllerError(format!(
                    "v7 driver node ownership/link contract changed: {}",
                    absolute.display()
                )));
            }
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
                    .ok_or_else(|| ControllerError("v7 driver path is not UTF-8".to_owned()))?
                    .to_owned()
            };
            output.push((display, kind.to_owned(), metadata.permissions().mode() & 0o777));
            if metadata.file_type().is_dir() {
                let mut children = fs::read_dir(&absolute)?
                    .map(|entry| entry.map(|entry| entry.file_name()))
                    .collect::<std::io::Result<Vec<_>>>()?;
                children.sort();
                for child in children {
                    walk_v7_driver(root, &relative.join(child), expected_uid, output)?;
                }
            }
            Ok(())
        }
        walk_v7_driver(bundle, Path::new(""), expected_uid, &mut actual)?;
        let expected_values = expected
            .iter()
            .map(|(path, kind, mode)| (path.to_string(), kind.to_string(), *mode))
            .collect::<Vec<_>>();
        if actual != expected_values {
            return Err(ControllerError(
                "v7 production driver lstat manifest is not exact".to_owned(),
            ));
        }
        let regular_files = [
            "Contents/Info.plist",
            "Contents/MacOS/OpensteamerVirtualMicrophone",
            "Contents/Resources/APPLE_SAMPLE_LICENSE.txt",
            "Contents/Resources/en.lproj/Localizable.strings",
            "Contents/_CodeSignature/CodeResources",
        ];
        let mut manifest = Vec::new();
        for (path, kind, mode) in &actual {
            let type_name = if kind == "directory" {
                "Directory"
            } else {
                "Regular File"
            };
            write!(manifest, "{type_name}|{:o}|{path}\0", mode)?;
        }
        for relative in regular_files {
            write!(manifest, "{relative}\0{}\0", sha256(&bundle.join(relative))?)?;
        }
        if sha256_bytes(&manifest)? != V7_PRODUCT_DRIVER_TREE_SHA256 {
            return Err(ControllerError(
                "v7 production driver tree hash differs from its committed pin".to_owned(),
            ));
        }
        let executable = bundle.join("Contents/MacOS/OpensteamerVirtualMicrophone");
        if sha256(&executable)? != V7_PRODUCT_DRIVER_EXECUTABLE_SHA256 {
            return Err(ControllerError(
                "v7 production driver executable differs from its committed pin".to_owned(),
            ));
        }
        let xattrs = command_output("/usr/bin/xattr", &["-lr", path_text(bundle)?], None)?;
        require_output_success(&xattrs, "inspect immutable v7 driver xattrs")?;
        if !xattrs.stdout.is_empty() || !xattrs.stderr.is_empty() {
            return Err(ControllerError(
                "v7 production driver contains extended attributes".to_owned(),
            ));
        }
        let architectures = command_line("/usr/bin/lipo", &["-archs", path_text(&executable)?], None)?;
        let mut archs = architectures.split_ascii_whitespace().collect::<Vec<_>>();
        archs.sort_unstable();
        if archs != ["arm64", "x86_64"] {
            return Err(ControllerError(
                "v7 production driver architecture set changed".to_owned(),
            ));
        }
        let signature = command_output(
            "/usr/bin/codesign",
            &["--verify", "--strict", "--all-architectures", path_text(bundle)?],
            None,
        )?;
        require_output_success(&signature, "verify immutable v7 driver signature")?;
        for arch in ["arm64", "x86_64"] {
            let details = command_output(
                "/usr/bin/codesign",
                &["-d", "-a", arch, "--verbose=4", path_text(bundle)?],
                None,
            )?;
            require_output_success(&details, "inspect immutable v7 driver signature")?;
            let text = decode_utf8(&details.stderr, "v7 driver codesign metadata")?;
            if !text.contains(&format!("Identifier={V7_PRODUCT_DRIVER_IDENTIFIER}\n"))
                || !text.contains(&format!("TeamIdentifier={V7_PRODUCT_DRIVER_TEAM_ID}\n"))
                || !text.contains("Authority=Developer ID Application:")
                || !text.contains("flags=0x10000(runtime)")
                || !text.contains("Timestamp=")
                || text.contains("Timestamp=none")
            {
                return Err(ControllerError(format!(
                    "{arch} v7 driver signing contract changed"
                )));
            }
            let entitlements = command_output(
                "/usr/bin/codesign",
                &["-d", "-a", arch, "--entitlements", ":-", path_text(bundle)?],
                None,
            )?;
            require_output_success(&entitlements, "inspect immutable v7 driver entitlements")?;
            if !entitlements.stdout.is_empty() {
                return Err(ControllerError(format!(
                    "{arch} v7 driver unexpectedly contains entitlements"
                )));
            }
        }
        Ok(())
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
        require_output_success(&output, "hash immutable v7 driver manifest")?;
        let text = decode_utf8(&output.stdout, "v7 driver manifest shasum output")?;
        let digest = text
            .split_ascii_whitespace()
            .next()
            .ok_or_else(|| ControllerError("v7 driver manifest hash is absent".to_owned()))?;
        if digest.len() != 64
            || !digest
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err(ControllerError(
                "v7 driver manifest hash is malformed".to_owned(),
            ));
        }
        Ok(digest.to_owned())
    }

    fn verify_committed_v6_oracle_pins() -> Result<()> {
        let source_export = Path::new(COMMITTED_V6_BASELINE_SOURCE_EXPORT);
        require_directory(source_export, 0o700)?;
        for (relative, mode, expected_sha256) in [
            ("macOS/scripts/verify-mac-host-bundle.sh", 0o700, COMMITTED_V6_VERIFY_BUNDLE_SHA256),
            ("macOS/scripts/verify-live-mac-host-process.sh", 0o700, COMMITTED_V6_VERIFY_LIVE_PROCESS_SHA256),
            ("macOS/scripts/verify-mac-host-deployment.sh", 0o700, COMMITTED_V6_VERIFY_DEPLOYMENT_SHA256),
            ("macOS/scripts/verify-mac-host-launch-state.sh", 0o700, COMMITTED_V6_VERIFY_LAUNCH_STATE_SHA256),
            ("macOS/LaunchAgents/org.example.opensteamer.worldwide.plist", 0o600, COMMITTED_V6_LAUNCH_AGENT_SOURCE_SHA256),
        ] {
            let oracle = source_export.join(relative);
            require_regular(&oracle, mode)?;
            if sha256(&oracle)? != expected_sha256 {
                return Err(ControllerError(format!(
                    "committed v6 rollback oracle changed: {}",
                    oracle.display()
                )));
            }
        }
        Ok(())
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
        require_tree_equal(Path::new(COMMITTED_V4_BASELINE_APP), app)
    }

    fn verify_committed_v5_app_at(app: &Path) -> Result<()> {
        verify_committed_v5_oracle_pins()?;
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
        require_tree_equal(Path::new(COMMITTED_V5_BASELINE_APP), app)
    }

    fn verify_committed_v6_app_at(app: &Path) -> Result<()> {
        verify_committed_v6_oracle_pins()?;
        require_directory(app, 0o755)?;
        let executable = app.join("Contents/MacOS/CaptureServer");
        require_regular(&executable, 0o755)?;
        if sha256(&executable)? != COMMITTED_V6_BASELINE_EXECUTABLE_SHA256
            || code_hash(app)? != COMMITTED_V6_BASELINE_CDHASH
        {
            return Err(ControllerError(format!(
                "committed v6 rollback app changed at {}",
                app.display()
            )));
        }
        require_code_identity(app)?;
        require_tree_equal(Path::new(COMMITTED_V6_BASELINE_APP), app)
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
                    "committed v7 rollback oracle changed: {}",
                    oracle.display()
                )));
            }
        }
        Ok(())
    }

    fn verify_v7_pointer_unchanged() -> Result<()> {
        verify_committed_v7_baseline().map(|_| ())
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
                "committed v7 LaunchAgent source changed".to_owned(),
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

    fn verify_isolated_pairing_items_present() -> Result<()> {
        require_root_owned_system_executable(Path::new("/usr/bin/security"))?;
        for account in [
            ISOLATED_PAIRING_IDENTITY_ACCOUNT,
            ISOLATED_PAIRING_VIEWER_ACCOUNT,
        ] {
            let status = Command::new("/usr/bin/security")
                .args([
                    "find-generic-password",
                    "-s",
                    ISOLATED_PAIRING_SERVICE,
                    "-a",
                    account,
                ])
                .env_clear()
                .env("HOME", USER_HOME)
                .env("USER", "ahmed")
                .env("LOGNAME", "ahmed")
                .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .map_err(|error| {
                    ControllerError(format!(
                        "cannot inspect isolated pairing item metadata for {account}: {error}"
                    ))
                })?;
            if !status.success() {
                return Err(ControllerError(format!(
                    "isolated pairing item is absent or inaccessible: account={account} status={status}"
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

    fn verify_paired_v8_runtime() -> Result<LaunchGeneration> {
        verify_committed_v7_baseline()?;
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

    fn verify_paired_v8_git_provenance(repo: &Path, require_remote: bool) -> Result<Provenance> {
        let status = command_output(
            "/usr/bin/git",
            &["status", "--porcelain=v1", "--untracked-files=all"],
            Some(repo),
        )?;
        require_output_success(&status, "inspect paired-v8 git worktree")?;
        if !status.stdout.is_empty() {
            return Err(ControllerError(
                "repository must be completely clean before a paired-v8 host update".to_owned(),
            ));
        }
        let commit = command_line("/usr/bin/git", &["rev-parse", "HEAD"], Some(repo))?;
        let tree = command_line("/usr/bin/git", &["rev-parse", "HEAD^{tree}"], Some(repo))?;
        require_canonical_git_oid(&commit, "current commit")?;
        require_canonical_git_oid(&tree, "current tree")?;
        let functional_tree_ref = format!("{EXPECTED_FUNCTIONAL_SOURCE_COMMIT}^{{tree}}");
        let functional_tree = command_line(
            "/usr/bin/git",
            &["rev-parse", functional_tree_ref.as_str()],
            Some(repo),
        )?;
        if functional_tree != EXPECTED_FUNCTIONAL_SOURCE_TREE {
            return Err(ControllerError(
                "frozen paired-v8 functional-source commit no longer resolves to its reviewed tree"
                    .to_owned(),
            ));
        }
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
                REQUIRED_V7_PREDECESSOR_COMMIT,
                EXPECTED_FUNCTIONAL_SOURCE_COMMIT,
            ],
            Some(repo),
        )?;
        require_output_success(
            &ancestry,
            "verify retry4-v7 predecessor ancestry of frozen functional source",
        )?;
        let release_ancestry = command_output(
            "/usr/bin/git",
            &[
                "merge-base",
                "--is-ancestor",
                EXPECTED_FUNCTIONAL_SOURCE_COMMIT,
                &commit,
            ],
            Some(repo),
        )?;
        require_output_success(
            &release_ancestry,
            "verify frozen functional-source ancestry of paired-v8 release",
        )?;
        let release_diff = command_output(
            "/usr/bin/git",
            &[
                "diff",
                "--no-ext-diff",
                "--no-renames",
                "--name-status",
                EXPECTED_FUNCTIONAL_SOURCE_COMMIT,
                &commit,
                "--",
            ],
            Some(repo),
        )?;
        require_output_success(
            &release_diff,
            "inspect paired-v8 release-only source delta",
        )?;
        let release_diff_text = decode_utf8(
            &release_diff.stdout,
            "paired-v8 release-only source delta",
        )?;
        let mut actual_release_records = release_diff_text
            .lines()
            .map(str::to_owned)
            .collect::<Vec<_>>();
        actual_release_records.sort();
        let mut expected_release_records = V8_RELEASE_ONLY_PATHS
            .iter()
            .map(|path| format!("A\t{path}"))
            .collect::<Vec<_>>();
        expected_release_records.sort();
        if actual_release_records != expected_release_records {
            return Err(ControllerError(
                "paired-v8 release differs from the frozen functional source by anything other than the three reviewed new v8 files"
                    .to_owned(),
            ));
        }
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
            require_output_success(&output, "verify pushed paired-v8 source commit")?;
            let text = decode_utf8(&output.stdout, "paired-v8 git ls-remote output")?;
            let records: Vec<&str> = text.lines().collect();
            let expected_ref = format!("refs/heads/{EXPECTED_SOURCE_BRANCH}");
            if records.len() != 1 {
                return Err(ControllerError(
                    "paired-v8 source branch is absent or ambiguous on origin".to_owned(),
                ));
            }
            let mut fields = records[0].split('\t');
            if fields.next() != Some(commit.as_str())
                || fields.next() != Some(expected_ref.as_str())
                || fields.next().is_some()
            {
                return Err(ControllerError(
                    "origin paired-v8 source branch does not resolve to local HEAD".to_owned(),
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

    fn wait_for_paired_v8_launch_generation(timeout: Duration) -> Result<LaunchGeneration> {
        wait_for_launch_generation(timeout)
    }

    fn bootout_paired_v8_job_if_loaded(layout: &V8Layout) -> Result<()> {
        let state = command_output(
            "/bin/launchctl",
            &["print", &format!("gui/{USER_ID}/{NEW_LAUNCH_AGENT_LABEL}")],
            None,
        )?;
        if state.status.success() {
            let loaded = parse_loaded_launch_job(decode_utf8(
                &state.stdout,
                "paired-v8 rollback launchctl state",
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
                    verify_v8_installed_matches_reference(layout)?;
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
            require_output_success(&output, "boot out paired-v8 LaunchAgent during rollback")?;
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
        require_output_success(&output, "verify canonical paired-v8 host mapped code")
    }

    fn require_v8_install_hold_layout(root: &Path, app: &Path) -> Result<()> {
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
                "paired-v8 install hold escaped its reviewed layout: {}",
                app.display()
            )));
        }
        Ok(())
    }

    fn publish_v8_active_pointer(evidence: &Path) -> Result<()> {
        require_descendant(Path::new(V8_UPDATE_ROOT), evidence)?;
        let pending = PathBuf::from(format!("{V8_ACTIVE_UPDATE}.pending-{}", std::process::id()));
        require_path_absent(&pending, "pending paired-v8 pointer")?;
        require_path_absent(Path::new(V8_ACTIVE_UPDATE), "active paired-v8 pointer")?;
        let mut file = create_new_private(&pending)?;
        writeln!(file, "{}", evidence.display())?;
        file.sync_all()?;
        rename_exclusive(&pending, Path::new(V8_ACTIVE_UPDATE))?;
        fsync_parent(Path::new(V8_ACTIVE_UPDATE))
    }

    fn verify_v8_active_pointer(expected_evidence: &Path) -> Result<()> {
        verify_update_pointer_at(
            Path::new(V8_ACTIVE_UPDATE),
            expected_evidence,
            Path::new(V8_UPDATE_ROOT),
        )
    }

    fn retire_v8_active_pointer(layout: &V8Layout) -> Result<()> {
        retire_update_pointer_at(
            Path::new(V8_ACTIVE_UPDATE),
            &layout.evidence,
            Path::new(V8_UPDATE_ROOT),
        )
    }

    fn path_exists_without_follow(path: &Path) -> Result<bool> {
        match fs::symlink_metadata(path) {
            Ok(_) => Ok(true),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(error) => Err(error.into()),
        }
    }

    fn parse_v8_journal(text: &str) -> Result<V8State> {
        let mut lines = text.lines();
        if lines.next() != Some(V8_JOURNAL_HEADER) {
            return Err(ControllerError(
                "paired-v8 journal header is malformed".to_owned(),
            ));
        }
        let mut state = None;
        for line in lines {
            let mut fields = line.split(' ');
            if fields.next() != Some("STATE") {
                return Err(ControllerError(
                    "paired-v8 journal record is malformed".to_owned(),
                ));
            }
            let next = fields
                .next()
                .and_then(V8State::parse)
                .ok_or_else(|| ControllerError("paired-v8 journal state is unknown".to_owned()))?;
            if let Some(previous) = state {
                validate_v8_transition(previous, next)?;
            } else if next != V8State::Begun {
                return Err(ControllerError(
                    "paired-v8 journal does not begin at BEGUN".to_owned(),
                ));
            }
            let fields: Vec<&str> = fields.collect();
            let expected = v8_field_schema(next);
            if fields.len() != expected.len() {
                return Err(ControllerError(
                    "paired-v8 journal field count is invalid".to_owned(),
                ));
            }
            for (field, expected_key) in fields.into_iter().zip(expected) {
                let (key, value) = field.split_once('=').ok_or_else(|| {
                    ControllerError("paired-v8 journal field is malformed".to_owned())
                })?;
                if key != *expected_key || !is_safe_journal_value(value) {
                    return Err(ControllerError(
                        "paired-v8 journal field is unsafe".to_owned(),
                    ));
                }
            }
            state = Some(next);
        }
        state.ok_or_else(|| ControllerError("paired-v8 journal has no state".to_owned()))
    }

    fn v8_field_schema(state: V8State) -> &'static [&'static str] {
        match state {
            V8State::Begun
            | V8State::InstallHoldVerified
            | V8State::CurrentStopped
            | V8State::CurrentHeld
            | V8State::NewPublished
            | V8State::PersistentBootstrapped
            | V8State::Committed
            | V8State::RollbackStarted
            | V8State::FailedNewArchived
            | V8State::CurrentRestored
            | V8State::CurrentBootstrapped
            | V8State::RolledBack => &[],
            V8State::SourceExported => &["commit", "tree", "initial_pid"],
            V8State::BuildVerified => &["executable_sha256"],
            V8State::StopInitiated => &["reserve_device", "reserve_inode", "reserve_bytes"],
            V8State::ReadyVerified => &["pid", "runs", "nonce"],
            V8State::CriticalFailure => &["phase"],
        }
    }

    fn validate_v8_fields(state: V8State, fields: &[(&str, String)]) -> Result<()> {
        let expected = v8_field_schema(state);
        if fields.len() != expected.len() {
            return Err(ControllerError(
                "paired-v8 journal record has wrong field count".to_owned(),
            ));
        }
        for ((key, value), expected_key) in fields.iter().zip(expected) {
            if *key != *expected_key || !is_safe_journal_value(value) {
                return Err(ControllerError("unsafe paired-v8 journal field".to_owned()));
            }
        }
        Ok(())
    }

    fn validate_v8_transition(previous: V8State, next: V8State) -> Result<()> {
        if previous == V8State::Begun && next == V8State::Begun {
            return Ok(());
        }
        let forward = matches!(
            (previous, next),
            (V8State::Begun, V8State::SourceExported)
                | (V8State::SourceExported, V8State::BuildVerified)
                | (V8State::BuildVerified, V8State::StopInitiated)
                | (V8State::StopInitiated, V8State::InstallHoldVerified)
                | (V8State::InstallHoldVerified, V8State::CurrentStopped)
                | (V8State::CurrentStopped, V8State::CurrentHeld)
                | (V8State::CurrentHeld, V8State::NewPublished)
                | (V8State::NewPublished, V8State::PersistentBootstrapped)
                | (V8State::PersistentBootstrapped, V8State::ReadyVerified)
                | (V8State::ReadyVerified, V8State::Committed)
        );
        let rollback_entry = next == V8State::RollbackStarted
            && ((previous >= V8State::StopInitiated && previous <= V8State::Committed)
                || previous == V8State::CriticalFailure)
            && previous != V8State::RollbackStarted;
        let rollback = matches!(
            (previous, next),
            (V8State::RollbackStarted, V8State::FailedNewArchived)
                | (V8State::RollbackStarted, V8State::CurrentRestored)
                | (V8State::FailedNewArchived, V8State::CurrentRestored)
                | (V8State::CurrentRestored, V8State::CurrentBootstrapped)
                | (V8State::CurrentBootstrapped, V8State::RolledBack)
        );
        let critical = next == V8State::CriticalFailure
            && previous >= V8State::RollbackStarted
            && previous < V8State::RolledBack;
        if forward || rollback_entry || rollback || critical {
            Ok(())
        } else {
            Err(ControllerError(format!(
                "invalid paired-v8 journal transition: {} -> {}",
                previous.token(),
                next.token()
            )))
        }
    }

    const ALL_V8_STATES: [V8State; 17] = [
        V8State::Begun,
        V8State::SourceExported,
        V8State::BuildVerified,
        V8State::StopInitiated,
        V8State::InstallHoldVerified,
        V8State::CurrentStopped,
        V8State::CurrentHeld,
        V8State::NewPublished,
        V8State::PersistentBootstrapped,
        V8State::ReadyVerified,
        V8State::Committed,
        V8State::RollbackStarted,
        V8State::FailedNewArchived,
        V8State::CurrentRestored,
        V8State::CurrentBootstrapped,
        V8State::RolledBack,
        V8State::CriticalFailure,
    ];

    fn is_plausible_v8_torn_tail(tail: &[u8], previous: V8State) -> bool {
        if tail.is_empty() || tail.len() > 4_096 || tail.contains(&b'\n') || tail.contains(&b'\r') {
            return false;
        }
        let Ok(tail) = std::str::from_utf8(tail) else {
            return false;
        };
        ALL_V8_STATES
            .iter()
            .copied()
            .filter(|next| validate_v8_transition(previous, *next).is_ok())
            .any(|next| is_plausible_v8_record_prefix(tail, next))
    }

    fn is_plausible_v8_record_prefix(tail: &str, state: V8State) -> bool {
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
        let expected = v8_field_schema(state);
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

    fn paired_v8_self_test() -> Result<()> {
        verify_v8_cli_surface()?;
        let valid = format!(
            "{V8_JOURNAL_HEADER}\nSTATE BEGUN\nSTATE SOURCE_EXPORTED commit={} tree={} initial_pid=41\nSTATE BUILD_VERIFIED executable_sha256={}\nSTATE STOP_INITIATED reserve_device=1 reserve_inode=2 reserve_bytes=8388608\nSTATE INSTALL_HOLD_VERIFIED\nSTATE CURRENT_STOPPED\nSTATE CURRENT_HELD\nSTATE NEW_PUBLISHED\nSTATE PERSISTENT_BOOTSTRAPPED\nSTATE READY_VERIFIED pid=42 runs=1 nonce={}\nSTATE COMMITTED\n",
            "a".repeat(40),
            "b".repeat(40),
            "c".repeat(64),
            "d".repeat(64),
        );
        if parse_v8_journal(&valid)? != V8State::Committed {
            return Err(ControllerError(
                "paired-v8 committed journal parser self-test failed".to_owned(),
            ));
        }
        let rolled_back = format!(
            "{V8_JOURNAL_HEADER}\nSTATE BEGUN\nSTATE SOURCE_EXPORTED commit={} tree={} initial_pid=41\nSTATE BUILD_VERIFIED executable_sha256={}\nSTATE STOP_INITIATED reserve_device=1 reserve_inode=2 reserve_bytes=8388608\nSTATE INSTALL_HOLD_VERIFIED\nSTATE CURRENT_STOPPED\nSTATE CURRENT_HELD\nSTATE NEW_PUBLISHED\nSTATE ROLLBACK_STARTED\nSTATE FAILED_NEW_ARCHIVED\nSTATE CURRENT_RESTORED\nSTATE CURRENT_BOOTSTRAPPED\nSTATE ROLLED_BACK\n",
            "a".repeat(40),
            "b".repeat(40),
            "c".repeat(64),
        );
        if parse_v8_journal(&rolled_back)? != V8State::RolledBack {
            return Err(ControllerError(
                "paired-v8 rollback journal parser self-test failed".to_owned(),
            ));
        }
        if parse_v8_journal(&format!(
            "{V8_JOURNAL_HEADER}\nSTATE BEGUN\nSTATE NEW_PUBLISHED\n"
        ))
        .is_ok()
        {
            return Err(ControllerError(
                "paired-v8 journal parser accepted a skipped transition".to_owned(),
            ));
        }
        let hold_root = Path::new("/Applications/.opensteamer-paired-v8-install-selftest");
        let hold_app = hold_root.join("opensteamer Host.app");
        require_v8_install_hold_layout(hold_root, &hold_app)?;
        if require_v8_install_hold_layout(
            Path::new("/Applications/opensteamer Host.app"),
            &hold_app,
        )
        .is_ok()
            || require_v8_install_hold_layout(hold_root, &hold_root.join("unreviewed Host.app"))
                .is_ok()
        {
            return Err(ControllerError(
                "paired-v8 install-hold layout self-test failed".to_owned(),
            ));
        }
        paired_v8_dynamic_self_test()?;
        println!("SELF_TEST_OK paired-v8-host-update-controller");
        Ok(())
    }

    fn verify_v8_cli_surface() -> Result<()> {
        let executable = "controller".to_owned();
        let repo = V8_EXPECTED_REPO.to_owned();
        let authorized_commit = "a".repeat(40);
        let authorized_tree = "b".repeat(40);
        let allowed = [
            vec![
                executable.clone(),
                V8_PREFLIGHT_MODE.to_owned(),
                repo.clone(),
            ],
            vec![
                executable.clone(),
                V8_EXECUTE_MODE.to_owned(),
                repo.clone(),
                authorized_commit.clone(),
                authorized_tree.clone(),
            ],
            vec![
                executable.clone(),
                V8_ROLLBACK_MODE.to_owned(),
                repo.clone(),
            ],
            vec![executable.clone(), V8_SELF_TEST_MODE.to_owned()],
            vec![
                executable.clone(),
                PROBE_LOCK_MODE.to_owned(),
                LOCK_DIRECTORY.to_owned(),
                LOCK_FILE.to_owned(),
                "1".to_owned(),
            ],
        ];
        if !matches!(parse_v8_command(&allowed[0]), Ok(V8Command::Preflight(_)))
            || !matches!(parse_v8_command(&allowed[1]), Ok(V8Command::Execute { .. }))
            || !matches!(parse_v8_command(&allowed[2]), Ok(V8Command::Rollback(_)))
            || !matches!(parse_v8_command(&allowed[3]), Ok(V8Command::SelfTest))
            || !matches!(
                parse_v8_command(&allowed[4]),
                Ok(V8Command::ProbeLock { .. })
            )
        {
            return Err(ControllerError(
                "paired-v8 CLI rejected a reviewed command shape".to_owned(),
            ));
        }

        let malformed = [
            vec![executable.clone(), V8_PREFLIGHT_MODE.to_owned()],
            vec![executable.clone(), V8_EXECUTE_MODE.to_owned(), repo.clone()],
            vec![
                executable.clone(),
                V8_EXECUTE_MODE.to_owned(),
                repo.clone(),
                "A".repeat(40),
                authorized_tree.clone(),
            ],
            vec![
                executable.clone(),
                V8_EXECUTE_MODE.to_owned(),
                repo.clone(),
                "a".repeat(39),
                authorized_tree.clone(),
            ],
            vec![
                executable.clone(),
                V8_EXECUTE_MODE.to_owned(),
                repo.clone(),
                authorized_commit.clone(),
                format!("{}g", "b".repeat(39)),
            ],
            vec![
                executable.clone(),
                V8_SELF_TEST_MODE.to_owned(),
                repo.clone(),
            ],
            vec![
                executable.clone(),
                PROBE_LOCK_MODE.to_owned(),
                LOCK_DIRECTORY.to_owned(),
                LOCK_FILE.to_owned(),
            ],
        ];
        if malformed
            .iter()
            .any(|arguments| parse_v8_command(arguments).is_ok())
        {
            return Err(ControllerError(
                "paired-v8 CLI accepted an unreviewed command shape".to_owned(),
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
                "paired-v8 authorization binding accepted a mismatched commit or tree".to_owned(),
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
                ControllerError("paired-v8 CLI test mode is not UTF-8".to_owned())
            })?;
            let arguments = vec![executable.clone(), mode, repo.clone()];
            if parse_v8_command(&arguments).is_ok() {
                return Err(ControllerError(
                    "paired-v8 CLI exposed an inherited update mode".to_owned(),
                ));
            }
        }
        Ok(())
    }

    fn paired_v8_dynamic_self_test() -> Result<()> {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| ControllerError("system clock predates Unix epoch".to_owned()))?
            .as_nanos();
        let directory = PathBuf::from(format!(
            "/private/tmp/opensteamer-paired-v8-selftest-{}-{unique}",
            std::process::id()
        ));
        require_path_absent(&directory, "paired-v8 self-test directory")?;
        fs::create_dir(&directory)?;
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
        let result = paired_v8_dynamic_self_test_in(&directory);
        let cleanup = fs::remove_dir_all(&directory);
        match (result, cleanup) {
            (Err(error), _) => Err(error),
            (Ok(()), Err(error)) => Err(ControllerError(format!(
                "cannot remove paired-v8 self-test directory: {error}"
            ))),
            (Ok(()), Ok(())) => Ok(()),
        }
    }

    fn paired_v8_dynamic_self_test_in(directory: &Path) -> Result<()> {
        let recoverable = directory.join("recoverable.log");
        let mut journal = V8Journal::create(&recoverable)?;
        journal.record(
            V8State::SourceExported,
            &[
                ("commit", "a".repeat(40)),
                ("tree", "b".repeat(40)),
                ("initial_pid", "41".to_owned()),
            ],
        )?;
        let before_rejected = fs::metadata(&recoverable)?.len();
        if journal
            .record(
                V8State::BuildVerified,
                &[("executable_sha256", "unsafe value".to_owned())],
            )
            .is_ok()
            || fs::metadata(&recoverable)?.len() != before_rejected
        {
            return Err(ControllerError(
                "paired-v8 journal validation failure changed durable bytes".to_owned(),
            ));
        }
        drop(journal);
        let mut partial = OpenOptions::new().append(true).open(&recoverable)?;
        partial.write_all(
            format!("STATE BUILD_VERIFIED executable_sha256={}", "c".repeat(64)).as_bytes(),
        )?;
        partial.sync_all()?;
        drop(partial);
        let mut reopened = V8Journal::open(&recoverable)?;
        if reopened.state != V8State::SourceExported {
            return Err(ControllerError(
                "paired-v8 journal recovery accepted an incomplete final record".to_owned(),
            ));
        }
        reopened.record(
            V8State::BuildVerified,
            &[("executable_sha256", "c".repeat(64))],
        )?;
        drop(reopened);

        let corrupt = directory.join("corrupt.log");
        let mut corrupt_journal = V8Journal::create(&corrupt)?;
        corrupt_journal.record(
            V8State::SourceExported,
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
        if V8Journal::open(&corrupt).is_ok() {
            return Err(ControllerError(
                "paired-v8 journal recovery accepted a malformed complete record".to_owned(),
            ));
        }

        let transaction_lock = directory.join("transaction.lock");
        let first = acquire_update_transaction_lock_at(&transaction_lock)?;
        if acquire_update_transaction_lock_at(&transaction_lock).is_ok() {
            return Err(ControllerError(
                "paired-v8 transaction lock allowed concurrent ownership".to_owned(),
            ));
        }
        drop(first);
        drop(acquire_update_transaction_lock_at(&transaction_lock)?);

        let failed_attempt_root = directory.join("failed-attempt-root");
        require_v8_update_root_unused_at(&failed_attempt_root)?;
        fs::create_dir(&failed_attempt_root)?;
        fs::set_permissions(&failed_attempt_root, fs::Permissions::from_mode(0o700))?;
        require_v8_update_root_unused_at(&failed_attempt_root)?;
        let failed_attempt = failed_attempt_root.join("failed-before-stop-evidence");
        fs::create_dir(&failed_attempt)?;
        fs::set_permissions(&failed_attempt, fs::Permissions::from_mode(0o700))?;
        if require_v8_update_root_unused_at(&failed_attempt_root).is_ok() {
            return Err(ControllerError(
                "paired-v8 single-attempt gate accepted failed-before-stop evidence".to_owned(),
            ));
        }

        let rolled_back_root = directory.join("rolled-back-attempt-root");
        fs::create_dir(&rolled_back_root)?;
        fs::set_permissions(&rolled_back_root, fs::Permissions::from_mode(0o700))?;
        require_v8_update_root_unused_at(&rolled_back_root)?;
        let rolled_back_attempt = rolled_back_root.join("rolled-back-evidence");
        fs::create_dir(&rolled_back_attempt)?;
        fs::set_permissions(&rolled_back_attempt, fs::Permissions::from_mode(0o700))?;
        if require_v8_update_root_unused_at(&rolled_back_root).is_ok() {
            return Err(ControllerError(
                "paired-v8 single-attempt gate accepted rolled-back evidence".to_owned(),
            ));
        }

        let pointer_fixture = directory.join("v7-retry4-pointer-fixture");
        let mut pointer = create_new_private(&pointer_fixture)?;
        pointer.write_all(COMMITTED_V7_EVIDENCE.as_bytes())?;
        pointer.write_all(b"\n")?;
        pointer.sync_all()?;
        drop(pointer);
        if sha256(&pointer_fixture)? != COMMITTED_V7_POINTER_SHA256 {
            return Err(ControllerError(
                "retry4-v7 pointer fixture does not match its committed hash".to_owned(),
            ));
        }
        verify_self_test_pinned_file(&pointer_fixture, COMMITTED_V7_POINTER_SHA256)?;
        let mut mutate_pointer = OpenOptions::new().append(true).open(&pointer_fixture)?;
        mutate_pointer.write_all(b"x")?;
        mutate_pointer.sync_all()?;
        drop(mutate_pointer);
        if verify_self_test_pinned_file(&pointer_fixture, COMMITTED_V7_POINTER_SHA256).is_ok() {
            return Err(ControllerError(
                "retry4-v7 pointer corruption was accepted".to_owned(),
            ));
        }

        let evidence_fixture = directory.join("v7-retry4-pinset-fixture");
        let pinset = v7_retry4_pinset_bytes();
        let pinset_sha256 = sha256_bytes(pinset.as_bytes())?;
        if pinset_sha256 != COMMITTED_V7_RETRY4_PINSET_SHA256 {
            return Err(ControllerError(format!(
                "retry4-v7 evidence/oracle pinset changed: current={pinset_sha256}"
            )));
        }
        let mut evidence = create_new_private(&evidence_fixture)?;
        evidence.write_all(pinset.as_bytes())?;
        evidence.sync_all()?;
        drop(evidence);
        verify_self_test_pinned_file(
            &evidence_fixture,
            COMMITTED_V7_RETRY4_PINSET_SHA256,
        )?;
        let evidence_file = OpenOptions::new().write(true).open(&evidence_fixture)?;
        evidence_file.set_len(1)?;
        evidence_file.sync_all()?;
        drop(evidence_file);
        if verify_self_test_pinned_file(
            &evidence_fixture,
            COMMITTED_V7_RETRY4_PINSET_SHA256,
        )
        .is_ok()
        {
            return Err(ControllerError(
                "retry4-v7 evidence/oracle pinset corruption was accepted".to_owned(),
            ));
        }

        self_test_v7_current_oracle_pin_mutation(directory)?;
        self_test_partial_install_hold_recovery(directory)?;
        self_test_publication_boundary_recovery(directory)
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

        archive_v8_install_hold_root_at(&install_hold_root, &archive)?;
        require_path_absent(&install_hold_root, "quarantined partial install-hold root")?;
        require_directory(&archive, 0o700)?;
        if read_bounded_utf8(&archive.join("opensteamer Host.app"), 128)? != "partial-copy-marker" {
            return Err(ControllerError(
                "opaque partial install-hold quarantine changed child bytes".to_owned(),
            ));
        }

        // A resumed rollback sees the retained quarantine and succeeds idempotently.
        archive_v8_install_hold_root_at(&install_hold_root, &archive)?;

        // Both paths existing is ambiguous and must fail before any host bootout.
        fs::create_dir(&install_hold_root)?;
        fs::set_permissions(&install_hold_root, fs::Permissions::from_mode(0o700))?;
        if archive_v8_install_hold_root_at(&install_hold_root, &archive).is_ok() {
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

    fn v7_retry4_pinset_bytes() -> String {
        format!(
            concat!(
                "pointer={}\n",
                "pointer_sha256={}\n",
                "pointer_inode={}\n",
                "evidence={}\n",
                "evidence_inode={}\n",
                "journal_sha256={}\n",
                "result_sha256={}\n",
                "provenance_sha256={}\n",
                "source_archive_sha256={}\n",
                "functional_inputs_sha256={}\n",
                "driver_record_sha256={}\n",
                "source_commit={}\n",
                "source_tree={}\n",
                "baseline_executable_sha256={}\n",
                "baseline_cdhash={}\n",
                "baseline_info_plist_sha256={}\n",
                "verify_bundle_sha256={}\n",
                "verify_live_process_sha256={}\n",
                "verify_deployment_sha256={}\n",
                "verify_launch_state_sha256={}\n",
                "launch_agent_source_sha256={}\n"
            ),
            COMMITTED_V7_POINTER,
            COMMITTED_V7_POINTER_SHA256,
            COMMITTED_V7_POINTER_INODE,
            COMMITTED_V7_EVIDENCE,
            COMMITTED_V7_EVIDENCE_INODE,
            COMMITTED_V7_JOURNAL_SHA256,
            COMMITTED_V7_RESULT_SHA256,
            COMMITTED_V7_PROVENANCE_SHA256,
            COMMITTED_V7_SOURCE_ARCHIVE_SHA256,
            COMMITTED_V7_FUNCTIONAL_INPUTS_SHA256,
            COMMITTED_V7_DRIVER_RECORD_SHA256,
            COMMITTED_V7_SOURCE_COMMIT,
            COMMITTED_V7_SOURCE_TREE,
            CURRENT_BASELINE_EXECUTABLE_SHA256,
            CURRENT_BASELINE_CDHASH,
            COMMITTED_V7_BASELINE_INFO_PLIST_SHA256,
            CURRENT_BASELINE_VERIFY_BUNDLE_SHA256,
            CURRENT_BASELINE_VERIFY_LIVE_PROCESS_SHA256,
            CURRENT_BASELINE_VERIFY_DEPLOYMENT_SHA256,
            CURRENT_BASELINE_VERIFY_LAUNCH_STATE_SHA256,
            CURRENT_BASELINE_LAUNCH_AGENT_SOURCE_SHA256,
        )
    }

    fn self_test_v7_current_oracle_pin_mutation(directory: &Path) -> Result<()> {
        for (name, mode) in [
            ("verify-bundle-oracle-fixture", 0o700),
            ("verify-live-process-oracle-fixture", 0o700),
            ("verify-deployment-oracle-fixture", 0o700),
            ("verify-launch-state-oracle-fixture", 0o700),
            ("launch-agent-oracle-fixture", 0o600),
        ] {
            let path = directory.join(name);
            let mut oracle = create_new_private(&path)?;
            writeln!(oracle, "immutable-v7-current-oracle={name}")?;
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
                    "v7 current rollback oracle corruption was accepted: {name}"
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
        const REPLACEMENT_BYTES: &str = "paired-v8-replacement";

        let case_root = directory.join(case.name);
        fs::create_dir(&case_root)?;
        fs::set_permissions(&case_root, fs::Permissions::from_mode(0o700))?;
        let canonical = case_root.join("canonical-app-fixture");
        let rollback = case_root.join("rollback-current-fixture");
        let pending = case_root.join("pending-new-fixture");
        let failed = case_root.join("failed-new-fixture");
        let pointer = case_root.join("pinned-v7-retry4-pointer-fixture");

        let mut pointer_file = create_new_private(&pointer)?;
        writeln!(pointer_file, "{COMMITTED_V7_EVIDENCE}")?;
        pointer_file.sync_all()?;
        drop(pointer_file);
        if sha256(&pointer)? != COMMITTED_V7_POINTER_SHA256 {
            return Err(ControllerError(
                "publication matrix retry4-v7 pointer does not match the committed bytes"
                    .to_owned(),
            ));
        }
        verify_self_test_pinned_file(&pointer, COMMITTED_V7_POINTER_SHA256)?;

        let mut baseline = create_new_private(&canonical)?;
        baseline.write_all(BASELINE_BYTES.as_bytes())?;
        baseline.sync_all()?;
        drop(baseline);
        let mut replacement = create_new_private(&pending)?;
        replacement.write_all(REPLACEMENT_BYTES.as_bytes())?;
        replacement.sync_all()?;
        drop(replacement);

        if case.current_held {
            self_test_checked_rename(
                &canonical,
                &rollback,
                &pointer,
                COMMITTED_V7_POINTER_SHA256,
            )?;
        }
        if case.new_published {
            self_test_checked_rename(
                &pending,
                &canonical,
                &pointer,
                COMMITTED_V7_POINTER_SHA256,
            )?;
        }
        verify_self_test_boundary_topology(case, &canonical, &rollback, &pending, &failed, false)?;
        verify_self_test_pinned_file(&pointer, COMMITTED_V7_POINTER_SHA256)?;

        if path_exists_without_follow(&rollback)? {
            if path_exists_without_follow(&canonical)? {
                verify_self_test_fixture(&canonical, Some(REPLACEMENT_BYTES))?;
                self_test_checked_rename(
                    &canonical,
                    &failed,
                    &pointer,
                    COMMITTED_V7_POINTER_SHA256,
                )?;
            }
            self_test_checked_rename(
                &rollback,
                &canonical,
                &pointer,
                COMMITTED_V7_POINTER_SHA256,
            )?;
        }
        verify_self_test_boundary_topology(case, &canonical, &rollback, &pending, &failed, true)?;
        verify_self_test_pinned_file(&pointer, COMMITTED_V7_POINTER_SHA256)?;
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
        const REPLACEMENT_BYTES: &str = "paired-v8-replacement";

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
    paired_v8::entry();
}
