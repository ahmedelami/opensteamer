#!/bin/zsh

# Usage: `validate-testflight-paired-reconnect.sh <coredevice-identifier> <hardware-udid>
# <expected-production-build> <physical-output-uid> [artifact-directory]`.
#
# Prerequisites: an unlocked, connected test iPhone on the pinned iOS version with the requested
# production build installed; Xcode command-line tools; the signed Mac capture-host app and its
# launch agent; a continuously readable host log; and working physical audio/video/call routes.
# `devicectl` cannot prove TestFlight receipt provenance, so App Store Connect/TestFlight remains
# the separate source of truth for distribution.
#
# Optional environment: `OPENSTEAMER_HOST_*` selects the launch agent, log, retry timing, and
# churn budget; `OPENSTEAMER_EXPECTED_APP_BUNDLE_IDENTIFIER` selects the side-by-side TestFlight
# identity and defaults to `com.elamin.opensteamer`; `OPENSTEAMER_EXPECTED_TEAM_ID` pins host signing;
# `OPENSTEAMER_UI_TEST_TIMEOUT_SECONDS`,
# `OPENSTEAMER_AUDIO_ORACLE_DURATION_SECONDS`, and `OPENSTEAMER_DEVICE_*` tune bounded waits.
# Variables prefixed `OPENSTEAMER_SELF_TEST_` and `OPENSTEAMER_SCRIPT_SELF_TEST` are reserved
# for deterministic shell regression tests and must be unset for a release run.
#
# Side effects/artifacts: rebuilds/verifies the Mac host; proves raw iPhone microphone forwarding
# into BlackHole through a UID-pinned acoustic probe; repeatedly restarts the host while proving
# reconnect/background/screen behavior; then uses distinct nonce-bound operator acknowledgements
# to enter and leave a real connected Phone or FaceTime call under one stable host PID. It writes
# phase-specific result bundles, watchdog markers, authenticated host-log snapshots, screenshots,
# and oracle evidence under the artifact directory (default
# `/Volumes/t7/opensteamer-device-Paired-Reconnect`). The physical-output UID is passed only to the
# probe process and is never retained. Cleanup stops only processes owned by this run. Every wrong
# build/signature, device lock/disconnect, host/log discontinuity, timeout, call acknowledgement
# failure, or oracle rejection exits nonzero; `run-status.txt` becomes passed only after all three
# exact proofs succeed.
set -euo pipefail
umask 077

SAFE_APP_BUNDLE_IDENTIFIER="com.elamin.opensteamer"
PROTECTED_APP_BUNDLE_IDENTIFIER="com.elamin.AudioStreamer"
SAFE_HOST_LAUNCH_AGENT_LABEL="org.example.opensteamer.worldwide"
PROTECTED_HOST_LAUNCH_AGENT_LABEL="com.elamin.audiostreamer.worldwide"
SAFE_HOST_SERVICE="gui/${UID}/${SAFE_HOST_LAUNCH_AGENT_LABEL}"
SAFE_HOST_LOG="/var/tmp/opensteamer-worldwide-host.log"
SAFE_HOST_REVIEWED_LAUNCH_AGENT="${0:A:h:h:h:h}/macOS/LaunchAgents/org.example.opensteamer.worldwide.plist"
SAFE_HOST_INSTALLED_LAUNCH_AGENT="/Users/ahmed/Library/LaunchAgents/org.example.opensteamer.worldwide.plist"
SAFE_HOST_EXECUTABLE="/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer"
REVIEWED_T7_VOLUME_UUID="25E93573-3993-42CC-8EE8-4F7A6C86A2EF"
REVIEWED_T7_STORE_UUID="CE1B73D9-E28D-40D2-8D37-D81F2C3F1051"
REVIEWED_PHYSICAL_OUTPUT_UID="BuiltInSpeakerDevice"
CONTROLLED_HOST_NO_AUDIO_TAPS_CONFIRMATION="controlled-host-no-audio-taps-reviewed"
EXPECTED_APP_BUNDLE_IDENTIFIER=${OPENSTEAMER_EXPECTED_APP_BUNDLE_IDENTIFIER:-${SAFE_APP_BUNDLE_IDENTIFIER}}
if [[ "${EXPECTED_APP_BUNDLE_IDENTIFIER}" == "${PROTECTED_APP_BUNDLE_IDENTIFIER}" ]]; then
  echo \
    "Refusing to validate the protected ${PROTECTED_APP_BUNDLE_IDENTIFIER} app; use the side-by-side TestFlight identity." \
    >&2
  exit 2
fi
if [[ "${EXPECTED_APP_BUNDLE_IDENTIFIER}" != "${SAFE_APP_BUNDLE_IDENTIFIER}" ]]; then
  echo \
    "The TestFlight validator requires the exact side-by-side ${SAFE_APP_BUNDLE_IDENTIFIER} identity." \
    >&2
  exit 2
fi
export OPENSTEAMER_EXPECTED_APP_BUNDLE_IDENTIFIER="${EXPECTED_APP_BUNDLE_IDENTIFIER}"

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
REPOSITORY_ROOT=${PROJECT_DIR:h:h}
source "${SCRIPT_DIR}/physical-validation-helpers.zsh"

# Test seams are process-wide authority. A typo or inherited environment variable must never make
# a physical release run execute synthetic branches, even when that variable's value is empty.
function reject_self_test_variables_outside_explicit_self_test() {
  local variable_name
  local -a leaked_variables=()

  [[ -n "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" ]] && return 0
  for variable_name in ${(k)parameters}; do
    if [[ "${variable_name}" == OPENSTEAMER_SELF_TEST_* ]]; then
      leaked_variables+=("${variable_name}")
    fi
  done
  if (( ${#leaked_variables[@]} > 0 )); then
    echo \
      "Refusing a physical release run with reserved self-test variables present: ${(j:, :)leaked_variables}." \
      >&2
    return 2
  fi
}
reject_self_test_variables_outside_explicit_self_test || exit $?

if (( $# < 4 || $# > 5 )) \
    || [[ -z "${1:-}" || -z "${2:-}" || -z "${3:-}" || -z "${4:-}" ]]; then
  echo \
    "usage: $0 coredevice-identifier hardware-udid expected-production-build physical-output-uid [artifact-directory]" \
    >&2
  exit 2
fi
COREDEVICE_IDENTIFIER=$1
HARDWARE_UDID=$2
EXPECTED_BUILD=$3
PHYSICAL_OUTPUT_UID=$4
shift 4
ARTIFACT_DIR=${1:-/Volumes/t7/opensteamer-device-Paired-Reconnect}
if [[ "${PHYSICAL_OUTPUT_UID}" != "${REVIEWED_PHYSICAL_OUTPUT_UID}" ]]; then
  echo \
    "The physical-output UID must be the reviewed built-in speaker identity ${REVIEWED_PHYSICAL_OUTPUT_UID}." \
    >&2
  exit 2
fi

# This declaration is an operational prerequisite, not cryptographic provenance. HAL metadata and
# a nonce challenge cannot prove the absence of a hostile same-user audio tap. A production run is
# valid only on the controlled Mac after the operator has disabled loopback/tap/routing software.
if [[ -z "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" \
    && "${OPENSTEAMER_CONTROLLED_HOST_NO_AUDIO_TAPS_ACK:-}" \
      != "${CONTROLLED_HOST_NO_AUDIO_TAPS_CONFIRMATION}" ]]; then
  echo \
    "Set OPENSTEAMER_CONTROLLED_HOST_NO_AUDIO_TAPS_ACK=${CONTROLLED_HOST_NO_AUDIO_TAPS_CONFIRMATION} only after verifying that the controlled Mac has no audio taps or loopback routes." \
    >&2
  exit 2
fi

function require_reviewed_t7_volume_identity() {
  local volume_uuid
  local store_identifier
  local store_uuid

  [[ -d /Volumes/t7 && ! -L /Volumes/t7 ]] || return 1
  volume_uuid=$(
    /usr/sbin/diskutil info -plist /Volumes/t7 \
      | /usr/bin/plutil -extract VolumeUUID raw -o - -
  ) || return $?
  store_identifier=$(
    /usr/sbin/diskutil info -plist /Volumes/t7 \
      | /usr/bin/plutil -extract APFSPhysicalStores.0.APFSPhysicalStore raw -o - -
  ) || return $?
  [[ -n "${store_identifier}" \
      && "${store_identifier}" != *[^A-Za-z0-9]* ]] || return 1
  store_uuid=$(
    /usr/sbin/diskutil info -plist "${store_identifier}" \
      | /usr/bin/plutil -extract DiskUUID raw -o - -
  ) || return $?
  [[ "${volume_uuid}" == "${REVIEWED_T7_VOLUME_UUID}" \
      && "${store_uuid}" == "${REVIEWED_T7_STORE_UUID}" ]]
}

# Validate every existing component before creating the private root. Lexical traversal and every
# symlink are rejected rather than normalized; the final canonical path must therefore be identical
# to the supplied path. Existing run roots and descendants are owner-only so a later rm -rf cannot
# be redirected by another local process.
function prepare_guarded_physical_artifact_directory() {
  local artifact_path=$1
  local current="/Volumes/t7"
  local relative
  local component
  local canonical
  local root_device
  local metadata
  local -a components

  [[ -n "${artifact_path}" \
      && "${artifact_path}" == /Volumes/t7/* \
      && "${artifact_path}" != *'//'* \
      && "${artifact_path}" != *$'\n'* \
      && "${artifact_path}" != *$'\r'* ]] || return 2
  relative=${artifact_path#/Volumes/t7/}
  components=("${(@s:/:)relative}")
  (( ${#components[@]} > 0 )) || return 2
  for component in "${components[@]}"; do
    [[ -n "${component}" && "${component}" != "." && "${component}" != ".." ]] \
      || return 2
  done

  require_reviewed_t7_volume_identity || return 2
  metadata=$(/usr/bin/stat -f '%u:%Lp:%HT:%d' /Volumes/t7) || return $?
  [[ "${metadata}" == "$((UID)):775:Directory:"* ]] || return 2
  root_device=${metadata##*:}
  [[ -n "${root_device}" && "${root_device}" != *[^0-9]* ]] || return 2

  for component in "${components[@]}"; do
    current="${current}/${component}"
    if [[ -L "${current}" ]]; then
      return 2
    fi
    if [[ -e "${current}" ]]; then
      [[ -d "${current}" ]] || return 2
      metadata=$(/usr/bin/stat -f '%u:%Lp:%HT:%d' "${current}") || return $?
      [[ "${metadata}" == "$((UID)):700:Directory:${root_device}" ]] || return 2
    fi
  done

  /bin/mkdir -p "${artifact_path}" || return $?
  canonical=${artifact_path:A}
  [[ "${canonical}" == "${artifact_path}" \
      && ! -L "${artifact_path}" \
      && "$((UID)):700:Directory:${root_device}" \
        == "$(/usr/bin/stat -f '%u:%Lp:%HT:%d' "${artifact_path}" 2>/dev/null)" ]] \
    || return 2
  require_reviewed_t7_volume_identity || return 2
  ARTIFACT_DIR_CANONICAL=${canonical}
}

if [[ -z "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" \
    || "${OPENSTEAMER_SCRIPT_SELF_TEST}" == artifact-path-* ]]; then
  if ! prepare_guarded_physical_artifact_directory "${ARTIFACT_DIR}"; then
    echo \
      "Physical validation artifacts require a canonical owner-only path on the reviewed T7 volume and store." \
      >&2
    exit 2
  fi
  ARTIFACT_DIR=${ARTIFACT_DIR_CANONICAL}
fi
RAW_PHASE_DIR="${ARTIFACT_DIR}/phase-1-raw-blackhole"
RECONNECT_PHASE_DIR="${ARTIFACT_DIR}/phase-2-reconnect"
CALL_PHASE_DIR="${ARTIFACT_DIR}/phase-3-real-call"
PHASE_EVENTS="${ARTIFACT_DIR}/phase-order.log"
RAW_PHASE_STATUS="${RAW_PHASE_DIR}/phase-status.txt"
RECONNECT_PHASE_STATUS="${RECONNECT_PHASE_DIR}/phase-status.txt"
CALL_PHASE_STATUS="${CALL_PHASE_DIR}/phase-status.txt"
APP_LIST_BEFORE="${ARTIFACT_DIR}/apps-before.json"
APP_LIST_AFTER="${ARTIFACT_DIR}/apps-after.json"
CANDIDATE_BEFORE="${ARTIFACT_DIR}/production-candidate-before.json"
CANDIDATE_AFTER="${ARTIFACT_DIR}/production-candidate-after.json"
DEVICE_BEFORE="${ARTIFACT_DIR}/device-before.json"
DEVICE_AFTER="${ARTIFACT_DIR}/device-after.json"
LOCK_STATE_BEFORE="${ARTIFACT_DIR}/lock-state-before.json"
RAW_APP_LIST_AFTER="${RAW_PHASE_DIR}/apps-after.json"
RAW_CANDIDATE_AFTER="${RAW_PHASE_DIR}/production-candidate-after.json"
RAW_DEVICE_AFTER="${RAW_PHASE_DIR}/device-after.json"
RECONNECT_APP_LIST_AFTER="${RECONNECT_PHASE_DIR}/apps-after.json"
RECONNECT_CANDIDATE_AFTER="${RECONNECT_PHASE_DIR}/production-candidate-after.json"
RECONNECT_DEVICE_AFTER="${RECONNECT_PHASE_DIR}/device-after.json"
CALL_APP_LIST_AFTER="${CALL_PHASE_DIR}/apps-after.json"
CALL_CANDIDATE_AFTER="${CALL_PHASE_DIR}/production-candidate-after.json"
CALL_DEVICE_AFTER="${CALL_PHASE_DIR}/device-after.json"
RAW_LOCK_STATE_BEFORE_XCODEBUILD="${RAW_PHASE_DIR}/lock-state-before-xcodebuild.json"
RAW_LOCK_STATE_DURING_TEST="${RAW_PHASE_DIR}/lock-state-during-test.json"
RAW_LOCK_STATE_AFTER_XCODEBUILD="${RAW_PHASE_DIR}/lock-state-after-xcodebuild.json"
LOCK_STATE_BEFORE_XCODEBUILD="${RECONNECT_PHASE_DIR}/lock-state-before-xcodebuild.json"
LOCK_STATE_DURING_TEST="${RECONNECT_PHASE_DIR}/lock-state-during-test.json"
LOCK_STATE_AFTER_XCODEBUILD="${RECONNECT_PHASE_DIR}/lock-state-after-xcodebuild.json"
CALL_LOCK_STATE_BEFORE_XCODEBUILD="${CALL_PHASE_DIR}/lock-state-before-xcodebuild.json"
CALL_LOCK_STATE_DURING_TEST="${CALL_PHASE_DIR}/lock-state-during-test.json"
CALL_LOCK_STATE_AFTER_XCODEBUILD="${CALL_PHASE_DIR}/lock-state-after-xcodebuild.json"
RAW_RESULT_BUNDLE="${RAW_PHASE_DIR}/production-build-${EXPECTED_BUILD}-raw-iphone-microphone.xcresult"
RAW_DERIVED_DATA="${RAW_PHASE_DIR}/DerivedData"
RAW_SUMMARY_JSON="${RAW_PHASE_DIR}/summary.json"
RAW_TESTS_JSON="${RAW_PHASE_DIR}/tests.json"
RAW_BUILD_RESULTS_JSON="${RAW_PHASE_DIR}/build-results.json"
RAW_ACTIVITIES_JSON="${RAW_PHASE_DIR}/activities.json"
RECONNECT_RESULT_BUNDLE="${RECONNECT_PHASE_DIR}/production-build-${EXPECTED_BUILD}-paired-reconnect.xcresult"
RECONNECT_DERIVED_DATA="${RECONNECT_PHASE_DIR}/DerivedData"
RECONNECT_SUMMARY_JSON="${RECONNECT_PHASE_DIR}/summary.json"
RECONNECT_TESTS_JSON="${RECONNECT_PHASE_DIR}/tests.json"
RECONNECT_BUILD_RESULTS_JSON="${RECONNECT_PHASE_DIR}/build-results.json"
RECONNECT_ACTIVITIES_JSON="${RECONNECT_PHASE_DIR}/activities.json"
CALL_RESULT_BUNDLE="${CALL_PHASE_DIR}/production-build-${EXPECTED_BUILD}-real-connected-call.xcresult"
CALL_DERIVED_DATA="${CALL_PHASE_DIR}/DerivedData"
CALL_SUMMARY_JSON="${CALL_PHASE_DIR}/summary.json"
CALL_TESTS_JSON="${CALL_PHASE_DIR}/tests.json"
CALL_BUILD_RESULTS_JSON="${CALL_PHASE_DIR}/build-results.json"
CALL_ACTIVITIES_JSON="${CALL_PHASE_DIR}/activities.json"
RESULT_BUNDLE=${RECONNECT_RESULT_BUNDLE}
DERIVED_DATA=${RECONNECT_DERIVED_DATA}
LEGACY_DERIVED_DATA="${ARTIFACT_DIR}/DerivedData"
LEGACY_RECONNECT_RESULT_BUNDLE="${ARTIFACT_DIR}/production-build-${EXPECTED_BUILD}-paired-reconnect.xcresult"
LEGACY_HOST_EVENTS="${ARTIFACT_DIR}/host-restart-events.log"
LEGACY_HOST_STATUS="${ARTIFACT_DIR}/host-restart-status.txt"
LEGACY_SUMMARY_JSON="${ARTIFACT_DIR}/summary.json"
LEGACY_TESTS_JSON="${ARTIFACT_DIR}/tests.json"
LEGACY_BUILD_RESULTS_JSON="${ARTIFACT_DIR}/build-results.json"
LEGACY_ACTIVITIES_JSON="${ARTIFACT_DIR}/activities.json"
LEGACY_DEVICE_LOCKED_MARKER="${ARTIFACT_DIR}/device-locked-during-test.txt"
XCODE_TEMP_DIR="${ARTIFACT_DIR}/xcode-tmp"
XCODE_SOURCE_PACKAGES="/Volumes/t7/opensteamer-source-packages"
EXPECTED_MODEL="iPhone XR"
EXPECTED_OS="18.7.9"
EXPECTED_PLATFORM="iOS"
EXPECTED_RAW_TEST_NAME="testProductionRawIPhoneMicrophoneOracleSustainsRollingContinuity"
EXPECTED_RAW_TEST_NODE="PairedReconnectPhysicalUITests/${EXPECTED_RAW_TEST_NAME}()"
EXPECTED_RAW_TEST_URL="test://com.apple.xcode/opensteamer/opensteamerUITests/PairedReconnectPhysicalUITests/${EXPECTED_RAW_TEST_NAME}"
EXPECTED_RAW_RUNTIME_ATTACHMENT_NAME="Production raw iPhone microphone runtime overlap evidence"
EXPECTED_TEST_NAME="testThreeSameProcessHostRestartsThenColdRelaunchPreservePairing"
EXPECTED_TEST_NODE="PairedReconnectPhysicalUITests/${EXPECTED_TEST_NAME}()"
# xcresult's display identifier includes `()`, while its canonical test URL does not.
EXPECTED_TEST_URL="test://com.apple.xcode/opensteamer/opensteamerUITests/PairedReconnectPhysicalUITests/${EXPECTED_TEST_NAME}"
EXPECTED_CALL_TEST_NAME="testRealConnectedCallRecoveryRotatesOrdinaryAudioPolicyAndRequiresFreshProof"
EXPECTED_CALL_TEST_NODE="PairedReconnectPhysicalUITests/${EXPECTED_CALL_TEST_NAME}()"
EXPECTED_CALL_TEST_URL="test://com.apple.xcode/opensteamer/opensteamerUITests/PairedReconnectPhysicalUITests/${EXPECTED_CALL_TEST_NAME}"
HOST_LABEL=${OPENSTEAMER_HOST_LAUNCH_AGENT_LABEL:-${SAFE_HOST_LAUNCH_AGENT_LABEL}}
HOST_SERVICE="gui/${UID}/${HOST_LABEL}"
HOST_LOG=${OPENSTEAMER_HOST_LOG:-${SAFE_HOST_LOG}}
EXPECTED_MAC_HOST_TEAM_ID=${OPENSTEAMER_EXPECTED_TEAM_ID:-TESTTEAM01}
MAC_HOST_BUILD_SCRIPT="${REPOSITORY_ROOT}/macOS/scripts/build-opensteamer-host-app.sh"
MAC_HOST_DEPLOYMENT_VERIFIER="${REPOSITORY_ROOT}/macOS/scripts/verify-mac-host-deployment.sh"
MAC_HOST_LAUNCH_STATE_VERIFIER="${REPOSITORY_ROOT}/macOS/scripts/verify-mac-host-launch-state.sh"
HOST_FRESH_STAGED_APP="${REPOSITORY_ROOT}/build/opensteamer Host.app"
HOST_OFFLINE_LEGACY_REFERENCE="/Applications/AudioStreamer Host.app/Contents/MacOS/CaptureServer"
HOST_REVIEWED_LAUNCH_AGENT="${REPOSITORY_ROOT}/macOS/LaunchAgents/${HOST_LABEL}.plist"
HOST_INSTALLED_LAUNCH_AGENT="/Users/ahmed/Library/LaunchAgents/${HOST_LABEL}.plist"
HOST_EXECUTABLE="${SAFE_HOST_EXECUTABLE}"
HOST_LOCK_DIRECTORY="/Users/ahmed/Library/Application Support/com.elamin.AudioStreamer.CaptureServer.runtime"
HOST_LOCK_FILE="${HOST_LOCK_DIRECTORY}/worldwide-host.lock"
HOST_RESTART_DELAY_SECONDS=${OPENSTEAMER_HOST_RESTART_DELAY_SECONDS:-8}
HOST_CONNECTION_WAIT_TIMEOUT_SECONDS=${OPENSTEAMER_HOST_CONNECTION_WAIT_TIMEOUT_SECONDS:-90}
HOST_CHURN_LOCK_ATTEMPTS=${OPENSTEAMER_HOST_CHURN_LOCK_ATTEMPTS:-600}

function require_exact_safe_host_mutation_identity() {
  [[ "${HOST_LABEL}" == "${SAFE_HOST_LAUNCH_AGENT_LABEL}" \
      && "${HOST_LABEL}" != "${PROTECTED_HOST_LAUNCH_AGENT_LABEL}" \
      && "${HOST_SERVICE}" == "${SAFE_HOST_SERVICE}" \
      && "${HOST_LOG}" == "${SAFE_HOST_LOG}" \
      && "${HOST_REVIEWED_LAUNCH_AGENT}" \
        == "${SAFE_HOST_REVIEWED_LAUNCH_AGENT}" \
      && "${HOST_INSTALLED_LAUNCH_AGENT}" \
        == "${SAFE_HOST_INSTALLED_LAUNCH_AGENT}" \
      && "${HOST_EXECUTABLE}" == "${SAFE_HOST_EXECUTABLE}" ]]
}

if ! require_exact_safe_host_mutation_identity; then
  echo \
    "Refusing physical validation because the host launch label, service, executable, plist, or log is not the exact reviewed opensteamer identity." \
    >&2
  exit 2
fi
UI_TEST_TIMEOUT_SECONDS=${OPENSTEAMER_UI_TEST_TIMEOUT_SECONDS:-900}
AUDIO_ORACLE_DURATION_SECONDS=${OPENSTEAMER_AUDIO_ORACLE_DURATION_SECONDS:-$((UI_TEST_TIMEOUT_SECONDS + 60))}
CALL_AUDIO_ORACLE_DURATION_SECONDS=${OPENSTEAMER_CALL_AUDIO_ORACLE_DURATION_SECONDS:-$((UI_TEST_TIMEOUT_SECONDS + 60))}
BLACKHOLE_PROBE_TIMEOUT_SECONDS=${OPENSTEAMER_BLACKHOLE_PROBE_TIMEOUT_SECONDS:-60}
RAW_CONTINUITY_REVALIDATION_TIMEOUT_SECONDS=${OPENSTEAMER_RAW_CONTINUITY_REVALIDATION_TIMEOUT_SECONDS:-8}
RAW_CONTINUITY_MAX_LOG_DELTA_BYTES=1048576
RAW_CONTINUITY_MAX_PARTIAL_BYTES=65536
RAW_CONTINUITY_MAX_EVIDENCE_BYTES=8192
CALL_READY_TIMEOUT_SECONDS=${OPENSTEAMER_CALL_READY_TIMEOUT_SECONDS:-180}
CALL_ACOUSTIC_TIMEOUT_SECONDS=${OPENSTEAMER_CALL_ACOUSTIC_TIMEOUT_SECONDS:-180}
CALL_END_TIMEOUT_SECONDS=${OPENSTEAMER_CALL_END_TIMEOUT_SECONDS:-90}
RAW_READY_TIMEOUT_SECONDS=${OPENSTEAMER_RAW_READY_TIMEOUT_SECONDS:-90}
POST_CALL_RAW_CONTINUITY_SECONDS=${OPENSTEAMER_POST_CALL_RAW_CONTINUITY_SECONDS:-330}
# This is a hard wall-clock budget from the accepted end-call acknowledgement through raw-route
# readiness, the deployment verifier's eleven-second stability window, identity capture, and probe
# launch. Keeping one declared budget makes the conservative same-clock overlap arithmetic auditable.
POST_CALL_RAW_PRE_PROBE_BUDGET_SECONDS=${OPENSTEAMER_POST_CALL_RAW_PRE_PROBE_BUDGET_SECONDS:-40}
# The CoreAudio default-route snapshot between the acoustic and end-call acknowledgements is a
# separate bounded command and therefore has its own contribution to the continuity budget.
POST_CALL_RAW_INTER_ACK_SNAPSHOT_BUDGET_SECONDS=${OPENSTEAMER_POST_CALL_RAW_INTER_ACK_SNAPSHOT_BUDGET_SECONDS:-4}
POST_CALL_RAW_REQUIRED_OVERLAP_SECONDS=6
POST_CALL_RAW_SAFETY_MARGIN_SECONDS=${OPENSTEAMER_POST_CALL_RAW_SAFETY_MARGIN_SECONDS:-10}
POST_CALL_RAW_UI_TIMEOUT_SLACK_SECONDS=${OPENSTEAMER_POST_CALL_RAW_UI_TIMEOUT_SLACK_SECONDS:-15}
POST_CALL_RAW_UI_TIMEOUT_SECONDS=0
POST_CALL_RAW_REQUIRED_CONTINUITY_SECONDS=0
UI_TEST_TERMINATION_GRACE_SECONDS=5
DEVICE_COMMAND_TIMEOUT_SECONDS=${OPENSTEAMER_DEVICE_COMMAND_TIMEOUT_SECONDS:-15}
DEVICE_LOCK_POLL_SECONDS=${OPENSTEAMER_DEVICE_LOCK_POLL_SECONDS:-5}
HOST_EVENTS="${RECONNECT_PHASE_DIR}/host-restart-events.log"
HOST_STATUS="${RECONNECT_PHASE_DIR}/host-restart-status.txt"
HOST_BUILD_STDOUT="${ARTIFACT_DIR}/host-build-stdout.txt"
HOST_BUILD_STDERR="${ARTIFACT_DIR}/host-build-stderr.txt"
HOST_DEPLOYMENT_MANIFEST="${ARTIFACT_DIR}/host-deployment.txt"
HOST_DEPLOYMENT_STDERR="${ARTIFACT_DIR}/host-deployment-stderr.txt"
HOST_DEPLOYMENT_RECHECK_STDOUT="${ARTIFACT_DIR}/host-deployment-recheck-stdout.txt"
HOST_DEPLOYMENT_RECHECK_STDERR="${ARTIFACT_DIR}/host-deployment-recheck-stderr.txt"
RAW_UI_TEST_TIMEOUT_MARKER="${RAW_PHASE_DIR}/ui-test-timeout.txt"
RAW_DEVICE_LOCKED_MARKER="${RAW_PHASE_DIR}/device-locked-during-test.txt"
RAW_DEVICE_UNAVAILABLE_MARKER="${RAW_PHASE_DIR}/device-unavailable-during-test.txt"
RAW_WATCHDOG_STATE="${RAW_PHASE_DIR}/watchdog-state.txt"
RAW_WATCHDOG_FAILURE_MARKER="${RAW_PHASE_DIR}/watchdog-failure.txt"
RAW_HOST_LOG_APPEND_CHUNK="${RAW_PHASE_DIR}/host-log-appended.bin"
RAW_HOST_LOG_COMPLETED_LINES="${RAW_PHASE_DIR}/host-log-completed.txt"
RAW_HOST_LOG_PARTIAL_LINE="${RAW_PHASE_DIR}/host-log-partial.bin"
RAW_READY_REQUEST="${RAW_PHASE_DIR}/raw-session-ready-request.txt"
RAW_READY_RESUMED_MARKER="${RAW_PHASE_DIR}/raw-session-ready-resumed.txt"
RAW_READY_EVIDENCE="${RAW_PHASE_DIR}/raw-session-ready-evidence.txt"
RAW_READY_STATUS="${RAW_PHASE_DIR}/raw-session-ready-status.txt"
RAW_READY_TIMEOUT_MARKER="${RAW_PHASE_DIR}/raw-session-ready-timeout.txt"
RAW_READY_STALE_MARKER="${RAW_PHASE_DIR}/raw-session-ready-stale-evidence.txt"
RAW_READY_CONTINUITY_EVIDENCE="${RAW_PHASE_DIR}/raw-session-continuity-evidence.txt"
RAW_READY_CONTINUITY_ARMED_MARKER="${RAW_PHASE_DIR}/raw-session-continuity-armed.txt"
RAW_READY_CONTINUITY_LOG_APPEND_CHUNK="${RAW_PHASE_DIR}/raw-session-continuity-log-appended.bin"
RAW_READY_CONTINUITY_LOG_COMPLETED_LINES="${RAW_PHASE_DIR}/raw-session-continuity-log-completed.txt"
RAW_READY_CONTINUITY_LOG_PARTIAL_LINE="${RAW_PHASE_DIR}/raw-session-continuity-log-partial.bin"
RAW_PROBE_OVERLAP_MARKER="${RAW_PHASE_DIR}/physical-blackhole-microphone-overlap.txt"
RAW_PROBE_NON_OVERLAP_MARKER="${RAW_PHASE_DIR}/physical-blackhole-microphone-non-overlap.txt"
RAW_UI_RUNTIME_ATTACHMENT_PAYLOAD_ID="${RAW_PHASE_DIR}/raw-ui-runtime-attachment-payload-id.txt"
RAW_UI_RUNTIME_EVIDENCE="${RAW_PHASE_DIR}/raw-ui-runtime-evidence.txt"
RAW_UI_COMPLETION_OBSERVATION="${RAW_PHASE_DIR}/raw-ui-completion-observation.txt"
RAW_UI_CAUSAL_STATE_OBSERVATION=""
RAW_UI_BOUNDS_EVIDENCE="${RAW_PHASE_DIR}/raw-ui-host-bounds.txt"
RAW_PROBE_PROCESS_START_EVIDENCE="${RAW_PHASE_DIR}/production-app-probe-start.txt"
RAW_PROBE_PROCESS_COMPLETION_EVIDENCE="${RAW_PHASE_DIR}/production-app-probe-completion.txt"
RAW_PROBE_COMPLETION_OBSERVATION="${RAW_PHASE_DIR}/physical-blackhole-completion-observation.txt"
RAW_PROBE_WAIT_EVIDENCE="${RAW_PHASE_DIR}/physical-blackhole-wait-evidence.txt"
RAW_PROBE_INTERVAL_EVIDENCE="${RAW_PHASE_DIR}/physical-blackhole-proof-interval.txt"
UI_TEST_TIMEOUT_MARKER="${RECONNECT_PHASE_DIR}/ui-test-timeout.txt"
DEVICE_LOCKED_MARKER="${RECONNECT_PHASE_DIR}/device-locked-during-test.txt"
DEVICE_UNAVAILABLE_MARKER="${RECONNECT_PHASE_DIR}/device-unavailable-during-test.txt"
HOST_WATCHER_FAILURE_MARKER="${RECONNECT_PHASE_DIR}/host-watcher-failed-during-test.txt"
HOST_CHURN_LOCK="${RECONNECT_PHASE_DIR}/host-churn.lock"
HOST_CHURN_STOP_MARKER="${RECONNECT_PHASE_DIR}/host-churn-stop.txt"
HOST_LOG_APPEND_CHUNK="${RECONNECT_PHASE_DIR}/host-log-appended.bin"
HOST_LOG_COMPLETED_LINES="${RECONNECT_PHASE_DIR}/host-log-completed.txt"
HOST_LOG_PARTIAL_LINE="${RECONNECT_PHASE_DIR}/host-log-partial.bin"
WATCHDOG_STATE="${RECONNECT_PHASE_DIR}/watchdog-state.txt"
WATCHDOG_FAILURE_MARKER="${RECONNECT_PHASE_DIR}/watchdog-failure.txt"
CALL_UI_TEST_TIMEOUT_MARKER="${CALL_PHASE_DIR}/ui-test-timeout.txt"
CALL_DEVICE_LOCKED_MARKER="${CALL_PHASE_DIR}/device-locked-during-test.txt"
CALL_DEVICE_UNAVAILABLE_MARKER="${CALL_PHASE_DIR}/device-unavailable-during-test.txt"
CALL_WATCHDOG_STATE="${CALL_PHASE_DIR}/watchdog-state.txt"
CALL_WATCHDOG_FAILURE_MARKER="${CALL_PHASE_DIR}/watchdog-failure.txt"
CALL_AUDIO_ORACLE_FAILURE_MARKER="${CALL_PHASE_DIR}/physical-audio-oracle-tone-failed.txt"
CALL_STABLE_HOST_FAILURE_MARKER="${CALL_PHASE_DIR}/stable-host-changed.txt"
RAW_APP_TERMINATION_EVIDENCE="${RAW_PHASE_DIR}/production-app-termination.txt"
CALL_APP_TERMINATION_EVIDENCE="${CALL_PHASE_DIR}/production-app-termination.txt"
CALL_READY_REQUEST="${CALL_PHASE_DIR}/call-ready-request.txt"
CALL_READY_ACKNOWLEDGEMENT="${CALL_PHASE_DIR}/call-ready-acknowledgement.txt"
CALL_READY_STATUS="${CALL_PHASE_DIR}/call-ready-status.txt"
CALL_READY_TIMEOUT_MARKER="${CALL_PHASE_DIR}/call-ready-timeout.txt"
CALL_READY_STALE_MARKER="${CALL_PHASE_DIR}/call-ready-stale-acknowledgement.txt"
CALL_ACOUSTIC_REQUEST="${CALL_PHASE_DIR}/call-acoustic-request.txt"
CALL_ACOUSTIC_ACKNOWLEDGEMENT="${CALL_PHASE_DIR}/call-acoustic-acknowledgement.txt"
CALL_ACOUSTIC_STATUS="${CALL_PHASE_DIR}/call-acoustic-status.txt"
CALL_ACOUSTIC_TIMEOUT_MARKER="${CALL_PHASE_DIR}/call-acoustic-timeout.txt"
CALL_ACOUSTIC_STALE_MARKER="${CALL_PHASE_DIR}/call-acoustic-stale-acknowledgement.txt"
CALL_UI_HOSTED_PRE_ACK_OBSERVATION="${CALL_PHASE_DIR}/call-ui-hosted-pre-acoustic.txt"
CALL_END_REQUEST="${CALL_PHASE_DIR}/call-end-request.txt"
CALL_END_ACKNOWLEDGEMENT="${CALL_PHASE_DIR}/call-end-acknowledgement.txt"
CALL_END_STATUS="${CALL_PHASE_DIR}/call-end-status.txt"
CALL_END_TIMEOUT_MARKER="${CALL_PHASE_DIR}/call-end-timeout.txt"
CALL_END_STALE_MARKER="${CALL_PHASE_DIR}/call-end-stale-acknowledgement.txt"
RECONNECT_MEDIA_CLEANUP_PROOF="${RECONNECT_PHASE_DIR}/phase-cleanup.txt"
RUN_STATUS="${ARTIFACT_DIR}/run-status.txt"
RAW_BLACKHOLE_PROBE_SOURCE="${SCRIPT_DIR}/physical-blackhole-microphone-probe.swift"
RAW_BLACKHOLE_PROBE_BINARY="${RAW_PHASE_DIR}/physical-blackhole-microphone-probe"
RAW_BLACKHOLE_PROBE_RESULT="${RAW_PHASE_DIR}/physical-blackhole-microphone-result.json"
RAW_BLACKHOLE_PROBE_COMPILE_STDOUT="${RAW_PHASE_DIR}/physical-blackhole-microphone-compile-stdout.txt"
RAW_BLACKHOLE_PROBE_COMPILE_STDERR="${RAW_PHASE_DIR}/physical-blackhole-microphone-compile-stderr.txt"
RAW_BLACKHOLE_PROBE_CLEANUP_PROOF="${RAW_PHASE_DIR}/physical-blackhole-microphone-cleanup.txt"
RAW_BLACKHOLE_PROBE_DIAGNOSTICS="${RAW_PHASE_DIR}/physical-blackhole-microphone-diagnostics.txt"
RAW_BLACKHOLE_PROBE_COMPLETION="${RAW_PHASE_DIR}/physical-blackhole-microphone-completion.txt"
RAW_DEFAULT_INPUT_BEFORE="${RAW_PHASE_DIR}/default-input-before.json"
RAW_DEFAULT_INPUT_HEALTHY="${RAW_PHASE_DIR}/default-input-healthy.json"
RAW_DEFAULT_INPUT_DURING=""
RAW_DEFAULT_INPUT_AFTER="${RAW_PHASE_DIR}/default-input-after.json"
RAW_DEFAULT_INPUT_LIFECYCLE_EVIDENCE="${RAW_PHASE_DIR}/default-input-lifecycle.txt"
RAW_APP_DISCONNECT_EVIDENCE="${RAW_PHASE_DIR}/production-app-disconnect.txt"
CALL_POST_RAW_DIR="${CALL_PHASE_DIR}/post-call-raw-microphone"
CALL_POST_RAW_HOST_LOG_APPEND_CHUNK="${CALL_POST_RAW_DIR}/host-log-appended.bin"
CALL_POST_RAW_HOST_LOG_COMPLETED_LINES="${CALL_POST_RAW_DIR}/host-log-completed.txt"
CALL_POST_RAW_HOST_LOG_PARTIAL_LINE="${CALL_POST_RAW_DIR}/host-log-partial.bin"
CALL_POST_RAW_READY_REQUEST="${CALL_POST_RAW_DIR}/raw-session-ready-request.txt"
CALL_POST_RAW_READY_RESUMED_MARKER="${CALL_POST_RAW_DIR}/raw-session-ready-resumed.txt"
CALL_POST_RAW_READY_EVIDENCE="${CALL_POST_RAW_DIR}/raw-session-ready-evidence.txt"
CALL_POST_RAW_READY_STATUS="${CALL_POST_RAW_DIR}/raw-session-ready-status.txt"
CALL_POST_RAW_READY_TIMEOUT_MARKER="${CALL_POST_RAW_DIR}/raw-session-ready-timeout.txt"
CALL_POST_RAW_READY_STALE_MARKER="${CALL_POST_RAW_DIR}/raw-session-ready-stale-evidence.txt"
CALL_POST_RAW_READY_CONTINUITY_EVIDENCE="${CALL_POST_RAW_DIR}/raw-session-continuity-evidence.txt"
CALL_POST_RAW_READY_CONTINUITY_ARMED_MARKER="${CALL_POST_RAW_DIR}/raw-session-continuity-armed.txt"
CALL_POST_RAW_READY_CONTINUITY_LOG_APPEND_CHUNK="${CALL_POST_RAW_DIR}/raw-session-continuity-log-appended.bin"
CALL_POST_RAW_READY_CONTINUITY_LOG_COMPLETED_LINES="${CALL_POST_RAW_DIR}/raw-session-continuity-log-completed.txt"
CALL_POST_RAW_READY_CONTINUITY_LOG_PARTIAL_LINE="${CALL_POST_RAW_DIR}/raw-session-continuity-log-partial.bin"
CALL_POST_RAW_PROBE_OVERLAP_MARKER="${CALL_POST_RAW_DIR}/physical-blackhole-microphone-overlap.txt"
CALL_POST_RAW_PROBE_NON_OVERLAP_MARKER="${CALL_POST_RAW_DIR}/physical-blackhole-microphone-non-overlap.txt"
CALL_POST_RAW_UI_RUNTIME_ATTACHMENT_PAYLOAD_ID="${CALL_POST_RAW_DIR}/raw-ui-runtime-attachment-payload-id.txt"
CALL_POST_RAW_UI_RUNTIME_EVIDENCE="${CALL_POST_RAW_DIR}/raw-ui-runtime-evidence.txt"
CALL_POST_RAW_UI_COMPLETION_OBSERVATION="${CALL_POST_RAW_DIR}/raw-ui-completion-observation.txt"
CALL_POST_RAW_UI_CAUSAL_STATE_OBSERVATION="${CALL_POST_RAW_DIR}/raw-ui-causal-state-observation.txt"
CALL_POST_RAW_GENERATION_ATTACHMENT_PAYLOAD_ID="${CALL_POST_RAW_DIR}/raw-ui-generation-attachment-payload-id.txt"
CALL_POST_RAW_GENERATION_EVIDENCE="${CALL_POST_RAW_DIR}/raw-ui-generation-evidence.txt"
CALL_POST_RAW_UI_BOUNDS_EVIDENCE="${CALL_POST_RAW_DIR}/raw-ui-host-bounds.txt"
CALL_POST_RAW_PROBE_PROCESS_START_EVIDENCE="${CALL_POST_RAW_DIR}/production-app-probe-start.txt"
CALL_POST_RAW_PROBE_PROCESS_COMPLETION_EVIDENCE="${CALL_POST_RAW_DIR}/production-app-probe-completion.txt"
CALL_POST_RAW_PROBE_COMPLETION_OBSERVATION="${CALL_POST_RAW_DIR}/physical-blackhole-completion-observation.txt"
CALL_POST_RAW_PROBE_WAIT_EVIDENCE="${CALL_POST_RAW_DIR}/physical-blackhole-wait-evidence.txt"
CALL_POST_RAW_PROBE_INTERVAL_EVIDENCE="${CALL_POST_RAW_DIR}/physical-blackhole-proof-interval.txt"
CALL_POST_RAW_PROBE_RESULT="${CALL_POST_RAW_DIR}/physical-blackhole-microphone-result.json"
CALL_POST_RAW_PROBE_CLEANUP_PROOF="${CALL_POST_RAW_DIR}/physical-blackhole-microphone-cleanup.txt"
CALL_POST_RAW_PROBE_DIAGNOSTICS="${CALL_POST_RAW_DIR}/physical-blackhole-microphone-diagnostics.txt"
CALL_POST_RAW_PROBE_COMPLETION="${CALL_POST_RAW_DIR}/physical-blackhole-microphone-completion.txt"
CALL_POST_RAW_DEFAULT_INPUT_BEFORE="${CALL_POST_RAW_DIR}/default-input-before.json"
CALL_POST_RAW_DEFAULT_INPUT_HEALTHY="${CALL_POST_RAW_DIR}/default-input-healthy.json"
CALL_POST_RAW_DEFAULT_INPUT_DURING="${CALL_POST_RAW_DIR}/default-input-during.json"
CALL_POST_RAW_DEFAULT_INPUT_AFTER="${CALL_POST_RAW_DIR}/default-input-after.json"
CALL_POST_RAW_DEFAULT_INPUT_LIFECYCLE_EVIDENCE="${CALL_POST_RAW_DIR}/default-input-lifecycle.txt"
AUDIO_ORACLE_TONE="${RECONNECT_PHASE_DIR}/physical-audio-oracle-tone.wav"
AUDIO_ORACLE_TONE_LOG="${RECONNECT_PHASE_DIR}/physical-audio-oracle-tone.log"
AUDIO_ORACLE_TONE_FAILURE_MARKER="${RECONNECT_PHASE_DIR}/physical-audio-oracle-tone-failed.txt"
CALL_AUDIO_ORACLE_TONE="${CALL_PHASE_DIR}/physical-audio-oracle-tone.wav"
CALL_AUDIO_ORACLE_TONE_LOG="${CALL_PHASE_DIR}/physical-audio-oracle-tone.log"
SCREEN_ORACLE_SOURCE="${SCRIPT_DIR}/physical-screen-oracle-challenge.swift"
SCREEN_ORACLE_BINARY="${RECONNECT_PHASE_DIR}/physical-screen-oracle-challenge"
SCREEN_ORACLE_HEARTBEAT="${RECONNECT_PHASE_DIR}/physical-screen-oracle-heartbeat.txt"
SCREEN_ORACLE_LOG="${RECONNECT_PHASE_DIR}/physical-screen-oracle.log"
SCREEN_ORACLE_FAILURE_MARKER="${RECONNECT_PHASE_DIR}/physical-screen-oracle-failed.txt"
SCREEN_ORACLE_CLEANUP_PROOF="${RECONNECT_PHASE_DIR}/physical-screen-oracle-cleanup.txt"
ACTIVITIES_JSON=${RECONNECT_ACTIVITIES_JSON}
HOST_WATCHER_PID=""
XCODEBUILD_PID=""
XCODEBUILD_GROUP_ISOLATED=0
XCODEBUILD_GROUP_HANDLE=""
XCODEBUILD_WATCHDOG_PID=""
XCODEBUILD_LIVE_STDOUT=""
BLACKHOLE_PROBE_PID=""
BLACKHOLE_PROBE_STATUS=""
BLACKHOLE_PROBE_STARTED_SECONDS=0
BLACKHOLE_PROBE_STARTED_MONOTONIC_NS=0
CALL_ACOUSTIC_ACCEPTED_NS=0
CALL_ACOUSTIC_ACCEPTED_TOKEN=""
BLACKHOLE_PROBE_NONCE=""
RAW_PROBE_STARTED_NS=0
RAW_PROBE_BOUND_PID=""
HOST_LOG_START_ID=""
HOST_LOG_START_OFFSET=""
HOST_LOG_START_DIGEST=""
RAW_HOST_LOG_START_ID=""
RAW_HOST_LOG_START_OFFSET=""
RAW_HOST_LOG_START_DIGEST=""
RAW_READY_NONCE=""
RAW_READY_REQUESTED_NS=0
RAW_READY_RESUMED_NS=0
RAW_PROOF_CONTEXT="phase-1"
RAW_PROOF_EVENT_PHASE=1
RAW_PROOF_EVENT_PREFIX=""
RAW_PROOF_EXPECTED_HOST_PID=""
RAW_PROOF_REQUIRE_NEW_CONNECTION=1
RAW_PROOF_WORK_DIR="${RAW_PHASE_DIR}"
PRODUCTION_PROCESS_QUERY_COUNT=0
EXPECTED_INITIAL_HOST_PID=""
CALL_STABLE_HOST_PID=""
HOST_GENERATION_STATE="${ARTIFACT_DIR}/host-generation.txt"
HOST_GENERATION_LOG_OFFSET=""
HOST_GENERATION_LOG_DEVICE=""
HOST_GENERATION_LOG_INODE=""
HOST_GENERATION_PID=""
HOST_GENERATION_RUNS=""
HOST_GENERATION_PROCESS_START=""
HOST_GENERATION_NONCE=""
HOST_GENERATION_LOCK_DEVICE=""
HOST_GENERATION_LOCK_INODE=""
RUN_SUCCEEDED=0
CLEANUP_RUNNING=0
AUDIO_ORACLE_TONE_PID=""
SCREEN_ORACLE_PID=""
ACTIVE_PHASE_STATUS=""
OPENSTEAMER_CAPTURED_COMMAND_STATUS=0
OPENSTEAMER_CAPTURED_PHASE_STATUS=0
PHYSICAL_VALIDATION_ORACLE_SOURCE="${SCRIPT_DIR}/physical-validation-oracle.rs"
PHYSICAL_VALIDATION_RUSTC="/opt/homebrew/Cellar/rust/1.97.1/bin/rustc"
PHYSICAL_VALIDATION_RUSTC_DRIVER="/opt/homebrew/Cellar/rust/1.97.1/lib/librustc_driver-1aebdb596416d2c8.dylib"
PHYSICAL_VALIDATION_RUSTC_SYSROOT="/opt/homebrew/Cellar/rust/1.97.1"
PHYSICAL_VALIDATION_RUSTC_VERSION="rustc 1.97.1 (8bab26f4f 2026-07-14) (Homebrew)"
PHYSICAL_VALIDATION_RUSTC_SHA256="d69d40bfd2e11825feb3538512b6ffcd63de91c35ec36bb876849f0f9f8fe6bd"
PHYSICAL_VALIDATION_RUSTC_DRIVER_SHA256="aa8f5e89644f6d54fd3f1c4d4031bbda10ff750984cede4a75c7addee27e15df"
PHYSICAL_VALIDATION_ORACLE_BUILD_DIR=""
PHYSICAL_VALIDATION_ORACLE_SELF_TEST="${ARTIFACT_DIR}/physical-validation-oracle-self-test.txt"
MIGRATION_CONTROLLER_SOURCE="${REPOSITORY_ROOT}/macOS/scripts/opensteamer-host-post-v20-update-controller.rs"
MIGRATION_CONTROLLER_SOURCE_SHA256="2dfe9ddec5ea71b206f6462deec0b8be5423e9f23ab30aebc42b8f424dfdab06"
MIGRATION_CONTROLLER_BINARY_SHA256="0beb8e96aabd059ee5f108dfd05d7d5d99fa52b58f56ab942a31ee8efd33f528"
OPENSTEAMER_MIGRATION_CONTROLLER_BINARY=""

# XCTest already compiles one current-source oracle for the class. Reuse it only after entering an
# explicit inert script self-test, then copy it into this process's ordinary private run directory
# so cleanup and controller-fixture tests never mutate the shared binary. A physical run and the
# dedicated migration-controller build self-test still take the fresh compiler/self-test path.
function initialize_exported_physical_validation_oracle_for_self_test() {
  local exported_oracle=${OPENSTEAMER_PHYSICAL_VALIDATION_ORACLE:-}
  local exported_parent=${exported_oracle:h}
  local build_parent="/Volumes/t7"
  local build_dir
  local oracle_binary
  local exported_sha256
  local copied_sha256
  local monotonic_ns

  [[ -n "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" \
      && "${OPENSTEAMER_SCRIPT_SELF_TEST}" \
        != "migration-controller-lock-probe-build" \
      && -n "${exported_oracle}" ]] || return 2
  if [[ ! -d "${build_parent}" || -L "${build_parent}" \
      || "$(/usr/bin/stat -f '%u:%Lp:%HT' "${build_parent}" 2>/dev/null)" \
        != "$(/usr/bin/id -u):775:Directory" \
      || "${exported_parent}" \
        != /Volumes/t7/opensteamer-physical-validation-tests-* \
      || ! -d "${exported_parent}" || -L "${exported_parent}" \
      || "$(/usr/bin/stat -f '%u:%Lp:%HT' "${exported_parent}" 2>/dev/null)" \
        != "$(/usr/bin/id -u):700:Directory" \
      || ! -f "${exported_oracle}" || -L "${exported_oracle}" \
      || ! -x "${exported_oracle}" \
      || "$(/usr/bin/stat -f '%u:%l:%Lp' "${exported_oracle}" 2>/dev/null)" \
        != "$(/usr/bin/id -u):1:500" ]]; then
    echo "The XCTest-exported Rust physical-validation oracle is unsafe." >&2
    return 1
  fi

  exported_sha256=$(
    /usr/bin/shasum -a 256 "${exported_oracle}" \
      | /usr/bin/awk '{print $1}'
  ) || return $?
  [[ "${#exported_sha256}" == 64 \
      && "${exported_sha256}" != *[^0-9a-f]* ]] || return 1

  build_dir=$(
    /usr/bin/mktemp -d \
      "${build_parent}/.opensteamer-physical-validation-oracle.XXXXXX"
  ) || return $?
  PHYSICAL_VALIDATION_ORACLE_BUILD_DIR=${build_dir}
  /bin/chmod 700 "${build_dir}" || return $?
  if [[ "${build_dir}" != /Volumes/t7/.opensteamer-physical-validation-oracle.* \
      || -L "${build_dir}" \
      || "$(/usr/bin/stat -f '%u:%Lp:%HT' "${build_dir}" 2>/dev/null)" \
        != "$(/usr/bin/id -u):700:Directory" ]]; then
    echo "The private XCTest Rust-oracle directory is unsafe." >&2
    return 1
  fi
  /bin/mkdir "${build_dir}/tmp" || return $?
  /bin/chmod 700 "${build_dir}/tmp" || return $?
  oracle_binary="${build_dir}/physical-validation-oracle"
  /bin/cp "${exported_oracle}" "${oracle_binary}" || return $?
  /bin/chmod 500 "${oracle_binary}" || return $?
  copied_sha256=$(
    /usr/bin/shasum -a 256 "${oracle_binary}" \
      | /usr/bin/awk '{print $1}'
  ) || return $?
  if [[ "${copied_sha256}" != "${exported_sha256}" \
      || "$(/usr/bin/stat -f '%u:%l:%Lp' "${oracle_binary}" 2>/dev/null)" \
        != "$(/usr/bin/id -u):1:500" ]]; then
    echo "The private XCTest Rust-oracle copy changed." >&2
    return 1
  fi

  typeset -gx OPENSTEAMER_PHYSICAL_VALIDATION_ORACLE="${oracle_binary}"
  monotonic_ns=$(opensteamer_run_physical_validation_oracle monotonic-ns) \
    || return $?
  [[ -n "${monotonic_ns}" && "${monotonic_ns}" != *[^0-9]* ]] || return 1
  opensteamer_write_state \
    "${PHYSICAL_VALIDATION_ORACLE_SELF_TEST}" \
    "SELF_TEST_OK physical-validation-oracle"
}

function initialize_physical_validation_oracle() {
  local build_parent="/Volumes/t7"
  local build_dir
  local source_copy
  local source_sha256
  local compiler_sha256
  local compiler_driver_sha256
  local oracle_binary
  local self_test_temporary="${PHYSICAL_VALIDATION_ORACLE_SELF_TEST}.tmp.$$"

  if [[ -n "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" \
      && "${OPENSTEAMER_SCRIPT_SELF_TEST}" \
        != "migration-controller-lock-probe-build" \
      && -n "${OPENSTEAMER_PHYSICAL_VALIDATION_ORACLE:-}" ]]; then
    initialize_exported_physical_validation_oracle_for_self_test
    return $?
  fi

  if [[ ! -d "${build_parent}" || -L "${build_parent}" \
      || "$(/usr/bin/stat -f '%u:%Lp:%HT' "${build_parent}" 2>/dev/null)" \
        != "$(/usr/bin/id -u):775:Directory" ]]; then
    echo "The guarded /Volumes/t7 physical-validation build parent is unavailable or unsafe." >&2
    return 1
  fi
  if [[ ! -f "${PHYSICAL_VALIDATION_RUSTC}" \
      || -L "${PHYSICAL_VALIDATION_RUSTC}" \
      || ! -x "${PHYSICAL_VALIDATION_RUSTC}" \
      || "$(/usr/bin/stat -f '%u:%g:%l:%Lp' "${PHYSICAL_VALIDATION_RUSTC}" 2>/dev/null)" \
        != "$(/usr/bin/id -u):80:1:555" ]]; then
    echo "The reviewed Rust compiler metadata changed." >&2
    return 1
  fi
  compiler_sha256=$(
    /usr/bin/shasum -a 256 "${PHYSICAL_VALIDATION_RUSTC}" \
      | /usr/bin/awk '{print $1}'
  ) || return $?
  if [[ "${compiler_sha256}" != "${PHYSICAL_VALIDATION_RUSTC_SHA256}" \
      || "$("${PHYSICAL_VALIDATION_RUSTC}" --version)" \
        != "${PHYSICAL_VALIDATION_RUSTC_VERSION}" \
      || "$("${PHYSICAL_VALIDATION_RUSTC}" --print sysroot)" \
        != "${PHYSICAL_VALIDATION_RUSTC_SYSROOT}" ]]; then
    echo "The reviewed Rust compiler identity changed." >&2
    return 1
  fi
  if [[ ! -f "${PHYSICAL_VALIDATION_RUSTC_DRIVER}" \
      || -L "${PHYSICAL_VALIDATION_RUSTC_DRIVER}" \
      || "$(/usr/bin/stat -f '%u:%g:%l:%Lp' "${PHYSICAL_VALIDATION_RUSTC_DRIVER}" 2>/dev/null)" \
        != "$(/usr/bin/id -u):80:1:444" ]]; then
    echo "The reviewed Rust compiler driver metadata changed." >&2
    return 1
  fi
  compiler_driver_sha256=$(
    /usr/bin/shasum -a 256 "${PHYSICAL_VALIDATION_RUSTC_DRIVER}" \
      | /usr/bin/awk '{print $1}'
  ) || return $?
  if [[ "${compiler_driver_sha256}" \
      != "${PHYSICAL_VALIDATION_RUSTC_DRIVER_SHA256}" ]]; then
    echo "The reviewed Rust compiler driver identity changed." >&2
    return 1
  fi
  if [[ ! -f "${PHYSICAL_VALIDATION_ORACLE_SOURCE}" \
      || -L "${PHYSICAL_VALIDATION_ORACLE_SOURCE}" \
      || "$(/usr/bin/stat -f '%u:%l:%Lp' "${PHYSICAL_VALIDATION_ORACLE_SOURCE}" 2>/dev/null)" \
        != "$(/usr/bin/id -u):1:644" ]]; then
    echo "The Rust physical-validation oracle source metadata is unsafe." >&2
    return 1
  fi
  source_sha256=$(
    /usr/bin/shasum -a 256 "${PHYSICAL_VALIDATION_ORACLE_SOURCE}" \
      | /usr/bin/awk '{print $1}'
  ) || return $?
  if [[ ${#source_sha256} != 64 || "${source_sha256}" == *[^0-9a-f]* ]]; then
    echo "The Rust physical-validation oracle source hash is malformed." >&2
    return 1
  fi

  build_dir=$(
    /usr/bin/mktemp -d \
      "${build_parent}/.opensteamer-physical-validation-oracle.XXXXXX"
  ) || return $?
  PHYSICAL_VALIDATION_ORACLE_BUILD_DIR=${build_dir}
  /bin/chmod 700 "${build_dir}" || return $?
  if [[ "${build_dir}" != /Volumes/t7/.opensteamer-physical-validation-oracle.* \
      || -L "${build_dir}" \
      || "$(/usr/bin/stat -f '%u:%Lp:%HT' "${build_dir}" 2>/dev/null)" \
        != "$(/usr/bin/id -u):700:Directory" ]]; then
    echo "The private Rust physical-validation build directory is unsafe." >&2
    return 1
  fi
  /bin/mkdir "${build_dir}/tmp" || return $?
  /bin/chmod 700 "${build_dir}/tmp" || return $?
  source_copy="${build_dir}/physical-validation-oracle.rs"
  oracle_binary="${build_dir}/physical-validation-oracle"
  /bin/cp "${PHYSICAL_VALIDATION_ORACLE_SOURCE}" "${source_copy}" || return $?
  /bin/chmod 400 "${source_copy}" || return $?
  if [[ "$(/usr/bin/stat -f '%u:%l:%Lp' "${source_copy}" 2>/dev/null)" \
      != "$(/usr/bin/id -u):1:400" \
      || "$(/usr/bin/shasum -a 256 "${source_copy}" | /usr/bin/awk '{print $1}')" \
        != "${source_sha256}" ]]; then
    echo "The private Rust physical-validation source copy changed." >&2
    return 1
  fi
  TMPDIR="${build_dir}/tmp" \
    "${PHYSICAL_VALIDATION_RUSTC}" \
      --edition=2021 \
      -D warnings \
      -C opt-level=2 \
      --sysroot "${PHYSICAL_VALIDATION_RUSTC_SYSROOT}" \
      --remap-path-prefix "${REPOSITORY_ROOT}=/reviewed/opensteamer" \
      --remap-path-prefix "${build_dir}=/reviewed/opensteamer-physical-validation-build" \
      "${source_copy}" \
      -o "${oracle_binary}" || return $?
  /bin/chmod 500 "${oracle_binary}" || return $?
  if [[ ! -f "${oracle_binary}" || -L "${oracle_binary}" \
      || "$(/usr/bin/stat -f '%u:%l:%Lp' "${oracle_binary}" 2>/dev/null)" \
        != "$(/usr/bin/id -u):1:500" ]]; then
    echo "The compiled Rust physical-validation oracle metadata is unsafe." >&2
    return 1
  fi
  if [[ "$(/usr/bin/shasum -a 256 "${PHYSICAL_VALIDATION_RUSTC}" | /usr/bin/awk '{print $1}')" \
        != "${PHYSICAL_VALIDATION_RUSTC_SHA256}" \
      || "$(/usr/bin/shasum -a 256 "${PHYSICAL_VALIDATION_RUSTC_DRIVER}" | /usr/bin/awk '{print $1}')" \
        != "${PHYSICAL_VALIDATION_RUSTC_DRIVER_SHA256}" \
      || "$(/usr/bin/shasum -a 256 "${PHYSICAL_VALIDATION_ORACLE_SOURCE}" | /usr/bin/awk '{print $1}')" \
        != "${source_sha256}" ]]; then
    echo "A trusted Rust physical-validation compilation input changed during compilation." >&2
    return 1
  fi
  typeset -gx OPENSTEAMER_PHYSICAL_VALIDATION_ORACLE="${oracle_binary}"
  rm -f "${self_test_temporary}" || return $?
  if opensteamer_run_physical_validation_oracle self-test \
      > "${self_test_temporary}" 2>&1; then
    :
  else
    local self_test_status=$?
    rm -f "${self_test_temporary}"
    return "${self_test_status}"
  fi
  /bin/mv "${self_test_temporary}" \
    "${PHYSICAL_VALIDATION_ORACLE_SELF_TEST}" || return $?
  /usr/bin/grep -Fxq \
    'SELF_TEST_OK physical-validation-oracle' \
    "${PHYSICAL_VALIDATION_ORACLE_SELF_TEST}"
}

function validate_migration_controller_binary() {
  local controller=${OPENSTEAMER_MIGRATION_CONTROLLER_BINARY:-}

  [[ -n "${controller}" \
      && "${controller}" == /Volumes/t7/.opensteamer-physical-validation-oracle.*/migration-lock-probe \
      && -f "${controller}" \
      && ! -L "${controller}" \
      && -x "${controller}" \
      && "$(/usr/bin/stat -f '%u:%l:%Lp' "${controller}" 2>/dev/null)" \
        == "$(/usr/bin/id -u):1:500" \
      && "$(/usr/bin/shasum -a 256 "${controller}" 2>/dev/null \
        | /usr/bin/awk '{print $1}')" == "${MIGRATION_CONTROLLER_BINARY_SHA256}" ]]
}

# The deployment verifier delegates the canonical advisory-lock proof to fresh reviewed Rust.
# Build that probe once, on T7, only for a real physical run; inert shell self-tests supply their
# own non-executed fixture path and therefore do not multiply this compile across every test case.
function initialize_migration_controller_lock_probe() {
  local build_dir=${PHYSICAL_VALIDATION_ORACLE_BUILD_DIR:-}
  local controller_build="${build_dir}/controller"
  local controller_binary="${build_dir}/migration-lock-probe"
  local source_sha256

  if [[ -z "${build_dir}" \
      || "${build_dir}" != /Volumes/t7/.opensteamer-physical-validation-oracle.* \
      || ! -d "${build_dir}" \
      || -L "${build_dir}" \
      || "$(/usr/bin/stat -f '%u:%Lp:%HT' "${build_dir}" 2>/dev/null)" \
        != "$(/usr/bin/id -u):700:Directory" ]]; then
    echo "The guarded Rust physical-validation build directory is unavailable." >&2
    return 1
  fi
  if [[ ! -f "${MIGRATION_CONTROLLER_SOURCE}" \
      || -L "${MIGRATION_CONTROLLER_SOURCE}" \
      || "$(/usr/bin/stat -f '%u:%l:%Lp' "${MIGRATION_CONTROLLER_SOURCE}" 2>/dev/null)" \
        != "$(/usr/bin/id -u):1:644" ]]; then
    echo "The reviewed migration lock-probe source metadata is unsafe." >&2
    return 1
  fi
  source_sha256=$(
    /usr/bin/shasum -a 256 "${MIGRATION_CONTROLLER_SOURCE}" \
      | /usr/bin/awk '{print $1}'
  ) || return $?
  if [[ "${source_sha256}" != "${MIGRATION_CONTROLLER_SOURCE_SHA256}" ]]; then
    echo "The reviewed migration lock-probe source bytes changed." >&2
    return 1
  fi

  TMPDIR="${build_dir}/tmp" \
    "${PHYSICAL_VALIDATION_RUSTC}" \
      --edition=2021 \
      -D warnings \
      -C opt-level=2 \
      --sysroot "${PHYSICAL_VALIDATION_RUSTC_SYSROOT}" \
      --remap-path-prefix "${REPOSITORY_ROOT}=/reviewed/opensteamer-post-v20" \
      --remap-path-prefix "${build_dir}=/reviewed/opensteamer-post-v20-build" \
      "${MIGRATION_CONTROLLER_SOURCE}" \
      -o "${controller_build}" || return $?
  /bin/chmod 500 "${controller_build}" || return $?
  /bin/mv "${controller_build}" "${controller_binary}" || return $?
  OPENSTEAMER_MIGRATION_CONTROLLER_BINARY=${controller_binary}
  typeset -gx OPENSTEAMER_MIGRATION_CONTROLLER_BINARY
  if [[ "$(/usr/bin/shasum -a 256 "${PHYSICAL_VALIDATION_RUSTC}" \
          | /usr/bin/awk '{print $1}')" != "${PHYSICAL_VALIDATION_RUSTC_SHA256}" \
      || "$(/usr/bin/shasum -a 256 "${PHYSICAL_VALIDATION_RUSTC_DRIVER}" \
          | /usr/bin/awk '{print $1}')" != "${PHYSICAL_VALIDATION_RUSTC_DRIVER_SHA256}" \
      || "$(/usr/bin/shasum -a 256 "${MIGRATION_CONTROLLER_SOURCE}" \
          | /usr/bin/awk '{print $1}')" != "${MIGRATION_CONTROLLER_SOURCE_SHA256}" ]]; then
    echo "The compiled migration lock probe or a trusted compilation input changed." >&2
    return 1
  fi
  if ! validate_migration_controller_binary; then
    echo "The compiled migration lock probe did not match the pinned binary identity." >&2
    return 1
  fi
}

function cleanup_physical_validation_oracle() {
  local build_dir=${PHYSICAL_VALIDATION_ORACLE_BUILD_DIR:-}

  if [[ -z "${build_dir}" ]]; then
    return 0
  fi
  if [[ "${build_dir}" != /Volumes/t7/.opensteamer-physical-validation-oracle.* \
      || ! -d "${build_dir}" || -L "${build_dir}" \
      || "$(/usr/bin/stat -f '%u:%Lp:%HT' "${build_dir}" 2>/dev/null)" \
        != "$(/usr/bin/id -u):700:Directory" ]]; then
    echo "Refusing to clean an untrusted Rust physical-validation build path." >&2
    return 1
  fi
  /bin/chmod -R u+w "${build_dir}" 2>/dev/null || return $?
  /bin/rm -rf "${build_dir}" || return $?
  PHYSICAL_VALIDATION_ORACLE_BUILD_DIR=""
  unset OPENSTEAMER_PHYSICAL_VALIDATION_ORACLE
  OPENSTEAMER_MIGRATION_CONTROLLER_BINARY=""
  unset OPENSTEAMER_MIGRATION_CONTROLLER_BINARY
}

mkdir -p "${ARTIFACT_DIR}"
print -r -- "status=running" > "${RUN_STATUS}"

# Every path that can terminate xcodebuild first fences and stops the host-churn worker. If the
# ordinary lock cannot be acquired, kill that worker before removing its stale lock. Therefore the
# stopped validation group can never be killed underneath an in-flight host kickstart.
function opensteamer_terminate_and_reap_host_watcher() {
  local watcher_pid="${HOST_WATCHER_PID:-}"
  local reap_attempts="${HOST_CHURN_LOCK_ATTEMPTS:-250}"
  local reap_poll
  local watcher_state=""
  local tree_termination_failed=0

  if [[ -z "${watcher_pid}" ]]; then
    return 0
  fi
  if opensteamer_process_group_exists "${watcher_pid}"; then
    if ! opensteamer_terminate_isolated_process_group \
        "${watcher_pid}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"; then
      return 1
    fi
  elif /bin/kill -0 "${watcher_pid}" 2>/dev/null; then
    if ! opensteamer_terminate_process_tree \
        "${watcher_pid}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"; then
      tree_termination_failed=1
    fi
  fi

  for ((reap_poll = 1; reap_poll <= reap_attempts; reap_poll++)); do
    watcher_state=$(
      /bin/ps -o stat= -p "${watcher_pid}" 2>/dev/null \
        | /usr/bin/tr -d '[:space:]' || true
    )
    if [[ -z "${watcher_state}" || "${watcher_state}" == Z* ]]; then
      break
    fi
    sleep 0.02
  done
  if [[ -n "${watcher_state}" && "${watcher_state}" != Z* ]]; then
    return 1
  fi
  if [[ -z "${watcher_state}" ]] \
      && /bin/kill -0 "${watcher_pid}" 2>/dev/null; then
    return 1
  fi
  wait "${watcher_pid}" 2>/dev/null || true
  if /bin/kill -0 "${watcher_pid}" 2>/dev/null; then
    return 1
  fi
  HOST_WATCHER_PID=""
  if ((tree_termination_failed != 0)); then
    return 1
  fi
  return 0
}

function stop_host_churn_before_xcodebuild_termination() {
  local lock_poll

  if [[ -f "${HOST_CHURN_STOP_MARKER}" ]]; then
    if ! opensteamer_terminate_and_reap_host_watcher; then
      return 1
    fi
    return 0
  fi
  if [[ -z "${HOST_WATCHER_PID}" ]] \
      || ! opensteamer_process_group_exists "${HOST_WATCHER_PID}"; then
    if ! opensteamer_terminate_and_reap_host_watcher; then
      return 1
    fi
    rmdir "${HOST_CHURN_LOCK}" 2>/dev/null || true
    if ! opensteamer_write_state \
        "${HOST_CHURN_STOP_MARKER}" "state=no-live-host-watcher"; then
      return 1
    fi
    return 0
  fi
  for ((lock_poll = 1; lock_poll <= HOST_CHURN_LOCK_ATTEMPTS; lock_poll++)); do
    if mkdir "${HOST_CHURN_LOCK}" 2>/dev/null; then
      if ! opensteamer_write_state \
          "${HOST_CHURN_STOP_MARKER}" "state=xcodebuild-termination-requested"; then
        rmdir "${HOST_CHURN_LOCK}" 2>/dev/null || true
        return 1
      fi
      if ! opensteamer_terminate_and_reap_host_watcher; then
        rmdir "${HOST_CHURN_LOCK}" 2>/dev/null || true
        return 1
      fi
      rmdir "${HOST_CHURN_LOCK}" 2>/dev/null || true
      return 0
    fi
    sleep 0.02
  done

  if ! opensteamer_terminate_and_reap_host_watcher; then
    rmdir "${HOST_CHURN_LOCK}" 2>/dev/null || true
    return 1
  fi
  rmdir "${HOST_CHURN_LOCK}" 2>/dev/null || true
  opensteamer_write_state \
    "${HOST_CHURN_STOP_MARKER}" "state=host-watcher-force-stopped"
}

function cleanup_host_watcher() {
  local watcher_pid=${HOST_WATCHER_PID}

  if [[ -z "${watcher_pid}" ]]; then
    return 0
  fi
  if opensteamer_process_group_exists "${watcher_pid}"; then
    opensteamer_terminate_isolated_process_group \
      "${watcher_pid}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
  elif kill -0 "${watcher_pid}" 2>/dev/null; then
    opensteamer_terminate_process_tree \
      "${watcher_pid}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
  fi
  wait "${watcher_pid}" 2>/dev/null || true
  if opensteamer_process_group_exists "${watcher_pid}"; then
    return 1
  fi
  HOST_WATCHER_PID=""
  return 0
}

function cleanup_xcodebuild() {
  local group_handle=${XCODEBUILD_GROUP_HANDLE:-${XCODEBUILD_PID}}

  if [[ -n "${XCODEBUILD_WATCHDOG_PID}" ]] \
      && kill -0 "${XCODEBUILD_WATCHDOG_PID}" 2>/dev/null; then
    opensteamer_terminate_process_tree \
      "${XCODEBUILD_WATCHDOG_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
    wait "${XCODEBUILD_WATCHDOG_PID}" 2>/dev/null || true
  fi
  if [[ -n "${group_handle}" ]]; then
    if (( XCODEBUILD_GROUP_ISOLATED != 0 )) \
        || opensteamer_process_group_exists "${group_handle}"; then
      opensteamer_terminate_isolated_process_group \
        "${group_handle}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
    elif kill -0 "${group_handle}" 2>/dev/null; then
      opensteamer_terminate_process_tree \
        "${group_handle}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
    fi
    opensteamer_wait_for_final_process_status "${group_handle}" || true
    if opensteamer_process_group_exists "${group_handle}"; then
      XCODEBUILD_GROUP_HANDLE=${group_handle}
      return 1
    fi
  fi
  XCODEBUILD_PID=""
  XCODEBUILD_GROUP_HANDLE=""
  XCODEBUILD_GROUP_ISOLATED=0
  return 0
}

function cleanup_blackhole_probe() {
  local probe_pid=${BLACKHOLE_PROBE_PID}

  if [[ -z "${probe_pid}" ]]; then
    return 0
  fi
  if opensteamer_process_group_exists "${probe_pid}"; then
    opensteamer_terminate_isolated_process_group \
      "${probe_pid}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
  elif kill -0 "${probe_pid}" 2>/dev/null; then
    opensteamer_terminate_process_tree \
      "${probe_pid}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
  fi
  opensteamer_wait_for_final_process_status "${probe_pid}" || true
  if opensteamer_process_group_exists "${probe_pid}"; then
    BLACKHOLE_PROBE_STATUS=137
    return 1
  fi
  BLACKHOLE_PROBE_STATUS=${OPENSTEAMER_FINAL_PROCESS_STATUS:-143}
  BLACKHOLE_PROBE_PID=""
  opensteamer_write_state \
    "${RAW_BLACKHOLE_PROBE_CLEANUP_PROOF}" \
    "state=terminated status=${BLACKHOLE_PROBE_STATUS}" 2>/dev/null || true
  return 0
}

function wait_for_blackhole_probe_completion() {
  local timeout_seconds=$1
  local started=${BLACKHOLE_PROBE_STARTED_SECONDS}
  local probe_pid=${BLACKHOLE_PROBE_PID}
  local completion_fields
  local completion_end_ns
  local completion_status
  local wait_deadline_ns
  local bounded_wait_status
  local wait_temporary="${RAW_PROBE_WAIT_EVIDENCE}.tmp.$$"

  [[ -n "${probe_pid}" ]] || return 1
  [[ -n "${RAW_BLACKHOLE_PROBE_COMPLETION}" ]] || return 1
  if (( started <= 0 )); then
    started=${SECONDS}
  fi
  [[ -n "${BLACKHOLE_PROBE_STARTED_MONOTONIC_NS}" \
      && "${BLACKHOLE_PROBE_STARTED_MONOTONIC_NS}" != *[^0-9]* \
      && "${timeout_seconds}" != *[^0-9]* ]] || return 3
  wait_deadline_ns=$((
    BLACKHOLE_PROBE_STARTED_MONOTONIC_NS + timeout_seconds * 1000000000
  ))
  (( wait_deadline_ns > BLACKHOLE_PROBE_STARTED_MONOTONIC_NS )) || return 3
  while [[ ! -s "${RAW_BLACKHOLE_PROBE_COMPLETION}" ]]; do
    if ! opensteamer_process_group_exists "${probe_pid}"; then
      sleep 0.05
      if [[ -s "${RAW_BLACKHOLE_PROBE_COMPLETION}" ]]; then
        continue
      fi
      opensteamer_wait_for_final_process_status "${probe_pid}" || true
      BLACKHOLE_PROBE_STATUS=${OPENSTEAMER_FINAL_PROCESS_STATUS:-1}
      BLACKHOLE_PROBE_PID=""
      record_raw_overlap_failure missing-probe-completion 3
      return 1
    fi
    if (( SECONDS - started >= timeout_seconds )); then
      opensteamer_terminate_isolated_process_group \
        "${probe_pid}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
      opensteamer_wait_for_final_process_status "${probe_pid}" || true
      if ! opensteamer_wait_for_process_group_exit "${probe_pid}" 2; then
        BLACKHOLE_PROBE_STATUS=137
        record_raw_overlap_failure probe-group-survived-timeout 137
        return 137
      fi
      BLACKHOLE_PROBE_STATUS=124
      BLACKHOLE_PROBE_PID=""
      if [[ ! -f "${RAW_BLACKHOLE_PROBE_DIAGNOSTICS}" ]]; then
        opensteamer_write_state \
          "${RAW_BLACKHOLE_PROBE_DIAGNOSTICS}" \
          "diagnostic=probe-timeout"
      fi
      opensteamer_write_state \
        "${RAW_BLACKHOLE_PROBE_CLEANUP_PROOF}" \
        "state=timed-out status=124"
      record_raw_overlap_failure probe-timeout 124
      return 124
    fi
    sleep 0.1
  done
  if opensteamer_wait_for_final_group_status_until \
      "${probe_pid}" \
      "${wait_deadline_ns}" \
      "${UI_TEST_TERMINATION_GRACE_SECONDS}"; then
    bounded_wait_status=0
  else
    bounded_wait_status=$?
  fi
  if (( bounded_wait_status == 124 )); then
    BLACKHOLE_PROBE_STATUS=124
    BLACKHOLE_PROBE_PID=""
    opensteamer_write_state \
      "${RAW_BLACKHOLE_PROBE_CLEANUP_PROOF}" \
      "state=wrapper-timed-out-after-completion status=124" || true
    record_raw_overlap_failure probe-wrapper-timeout-after-completion 124
    return 124
  fi
  if (( bounded_wait_status != 0 )); then
    BLACKHOLE_PROBE_STATUS=137
    record_raw_overlap_failure probe-wrapper-wait-indeterminate \
      "${bounded_wait_status}"
    return "${bounded_wait_status}"
  fi
  if ! opensteamer_wait_for_process_group_exit "${probe_pid}" 2; then
    BLACKHOLE_PROBE_STATUS=137
    record_raw_overlap_failure probe-group-survived-exit 137
    return 137
  fi
  BLACKHOLE_PROBE_STATUS=${OPENSTEAMER_FINAL_PROCESS_STATUS}
  BLACKHOLE_PROBE_PID=""
  completion_fields=$(
    parse_raw_probe_completion_file \
      "${RAW_READY_NONCE:-unbound}" \
      "${RAW_PROBE_STARTED_NS:-0}" \
      "${RAW_PROBE_BOUND_PID:-0}"
  ) || {
    record_raw_overlap_failure malformed-probe-completion 3
    return 3
  }
  completion_end_ns=${completion_fields%% *}
  completion_status=${completion_fields##* }
  if [[ -z "${completion_status}" \
      || "${completion_status}" == *[^0-9]* \
      || -z "${BLACKHOLE_PROBE_STATUS}" \
      || "${BLACKHOLE_PROBE_STATUS}" == *[^0-9]* ]] \
      || (( completion_status != BLACKHOLE_PROBE_STATUS )); then
    record_raw_overlap_failure probe-wait-status-mismatch 3
    return 3
  fi
  if [[ -n "${RAW_READY_NONCE}" ]]; then
    if (( completion_status != 0 )); then
      record_raw_overlap_failure \
        nonzero-probe-completion "${completion_status}"
      return "${completion_status}"
    fi
    [[ -s "${RAW_READY_CONTINUITY_EVIDENCE}" ]] || {
      record_raw_overlap_failure missing-post-probe-route-continuity 3
      return 3
    }
    {
      print -r -- "schema=opensteamer.blackhole-probe-wait.v1"
      print -r -- "nonce=${RAW_READY_NONCE}"
      print -r -- "wrapperPID=${probe_pid}"
      print -r -- "probeEndMonotonicNs=${completion_end_ns}"
      print -r -- "completionStatus=${completion_status}"
      print -r -- "waitStatus=${BLACKHOLE_PROBE_STATUS}"
    } > "${wait_temporary}" || {
      record_raw_overlap_failure probe-wait-evidence-write-failed 3
      return 3
    }
    mv "${wait_temporary}" "${RAW_PROBE_WAIT_EVIDENCE}" || {
      record_raw_overlap_failure probe-wait-evidence-move-failed 3
      return 3
    }
  fi
  opensteamer_write_state \
    "${RAW_BLACKHOLE_PROBE_CLEANUP_PROOF}" \
    "state=exited status=${BLACKHOLE_PROBE_STATUS}" || return $?
  return "${BLACKHOLE_PROBE_STATUS}"
}

function begin_phase() {
  local phase_number=$1
  local phase_name=$2
  local phase_status=$3
  local command_status

  if opensteamer_write_state "${phase_status}" "status=running"; then
    :
  else
    command_status=$?
    return "${command_status}"
  fi
  if print -r -- \
      "phase=${phase_number} name=${phase_name} state=started" \
      >> "${PHASE_EVENTS}"; then
    :
  else
    command_status=$?
    opensteamer_write_state "${phase_status}" "status=failed" 2>/dev/null || true
    return "${command_status}"
  fi
  ACTIVE_PHASE_STATUS=${phase_status}
  return 0
}

function complete_phase() {
  local phase_number=$1
  local phase_name=$2
  local phase_status=$3
  local command_status

  if opensteamer_write_state "${phase_status}" "status=passed"; then
    :
  else
    command_status=$?
    return "${command_status}"
  fi
  if print -r -- \
      "phase=${phase_number} name=${phase_name} state=passed" \
      >> "${PHASE_EVENTS}"; then
    :
  else
    command_status=$?
    opensteamer_write_state "${phase_status}" "status=failed" 2>/dev/null || true
    return "${command_status}"
  fi
  ACTIVE_PHASE_STATUS=""
  return 0
}

function fail_phase() {
  local phase_status=$1
  local command_status=0

  opensteamer_write_state "${phase_status}" "status=failed" \
    || command_status=$?
  ACTIVE_PHASE_STATUS=""
  return "${command_status}"
}

function run_command_capturing_status() {
  setopt localoptions noerrexit
  "$@"
  OPENSTEAMER_CAPTURED_COMMAND_STATUS=$?
  return 0
}

function run_phase_capturing_status() {
  run_command_capturing_status "$@"
  OPENSTEAMER_CAPTURED_PHASE_STATUS=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  return 0
}

function cleanup_audio_oracle_tone() {
  local tone_pid=${AUDIO_ORACLE_TONE_PID}

  if [[ -z "${tone_pid}" ]]; then
    return 0
  fi
  if opensteamer_process_group_exists "${tone_pid}"; then
    opensteamer_terminate_isolated_process_group \
      "${tone_pid}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
  elif kill -0 "${tone_pid}" 2>/dev/null; then
    opensteamer_terminate_process_tree \
      "${tone_pid}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
  fi
  wait "${tone_pid}" 2>/dev/null || true
  if opensteamer_process_group_exists "${tone_pid}"; then
    return 1
  fi
  AUDIO_ORACLE_TONE_PID=""
  return 0
}

function cleanup_screen_oracle_challenge() {
  local screen_pid=${SCREEN_ORACLE_PID}

  if [[ -z "${screen_pid}" ]]; then
    return 0
  fi
  if opensteamer_process_group_exists "${screen_pid}"; then
    opensteamer_terminate_isolated_process_group \
      "${screen_pid}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
  elif kill -0 "${screen_pid}" 2>/dev/null; then
    opensteamer_terminate_process_tree \
      "${screen_pid}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
  fi
  wait "${screen_pid}" 2>/dev/null || true
  if opensteamer_process_group_exists "${screen_pid}"; then
    return 1
  fi
  SCREEN_ORACLE_PID=""
  return 0
}

function cleanup_processes() {
  setopt localoptions noerrexit
  trap - ZERR
  local phase_status
  if (( CLEANUP_RUNNING != 0 )); then
    return 0
  fi
  CLEANUP_RUNNING=1
  if (( RUN_SUCCEEDED == 0 )); then
    if ! opensteamer_write_state "${RUN_STATUS}" "status=failed"; then
      print -r -- "status=failed" > "${RUN_STATUS}" 2>/dev/null || true
    fi
  fi
  for phase_status in \
      "${RAW_PHASE_STATUS}" "${RECONNECT_PHASE_STATUS}" "${CALL_PHASE_STATUS}"; do
    if grep -qx 'status=running' "${phase_status}" 2>/dev/null; then
      if ! opensteamer_write_state "${phase_status}" "status=failed"; then
        print -r -- "status=failed" > "${phase_status}" 2>/dev/null || true
      fi
    fi
  done
  stop_host_churn_before_xcodebuild_termination || true
  cleanup_host_watcher
  cleanup_blackhole_probe
  cleanup_xcodebuild
  cleanup_audio_oracle_tone
  cleanup_screen_oracle_challenge
  cleanup_physical_validation_oracle || true
  rmdir "${HOST_CHURN_LOCK}" 2>/dev/null || true
  CLEANUP_RUNNING=0
  return 0
}

function cleanup_after_exit() {
  local failure_status=$?

  if (( RUN_SUCCEEDED == 0 )); then
    clear_raw_overlap_success_evidence 2>/dev/null || true
  fi
  cleanup_processes
  return "${failure_status}"
}

function cleanup_after_error() {
  local failure_status=$?
  trap - ZERR
  if (( RUN_SUCCEEDED == 0 )); then
    clear_raw_overlap_success_evidence 2>/dev/null || true
  fi
  cleanup_processes
  return "${failure_status}"
}
trap cleanup_after_exit EXIT
trap cleanup_after_error ZERR
trap opensteamer_exit_on_interrupt INT
trap opensteamer_exit_on_termination TERM

opensteamer_require_positive_integer \
  OPENSTEAMER_HOST_RESTART_DELAY_SECONDS \
  "${HOST_RESTART_DELAY_SECONDS}"
opensteamer_require_positive_integer \
  OPENSTEAMER_HOST_CONNECTION_WAIT_TIMEOUT_SECONDS \
  "${HOST_CONNECTION_WAIT_TIMEOUT_SECONDS}"
opensteamer_require_positive_integer \
  OPENSTEAMER_HOST_CHURN_LOCK_ATTEMPTS \
  "${HOST_CHURN_LOCK_ATTEMPTS}"
opensteamer_require_positive_integer \
  OPENSTEAMER_UI_TEST_TIMEOUT_SECONDS \
  "${UI_TEST_TIMEOUT_SECONDS}"
opensteamer_require_positive_integer \
  OPENSTEAMER_AUDIO_ORACLE_DURATION_SECONDS \
  "${AUDIO_ORACLE_DURATION_SECONDS}"
opensteamer_require_positive_integer \
  OPENSTEAMER_CALL_AUDIO_ORACLE_DURATION_SECONDS \
  "${CALL_AUDIO_ORACLE_DURATION_SECONDS}"
opensteamer_require_positive_integer \
  OPENSTEAMER_BLACKHOLE_PROBE_TIMEOUT_SECONDS \
  "${BLACKHOLE_PROBE_TIMEOUT_SECONDS}"
opensteamer_require_positive_integer \
  OPENSTEAMER_RAW_CONTINUITY_REVALIDATION_TIMEOUT_SECONDS \
  "${RAW_CONTINUITY_REVALIDATION_TIMEOUT_SECONDS}"
opensteamer_require_positive_integer \
  OPENSTEAMER_CALL_READY_TIMEOUT_SECONDS \
  "${CALL_READY_TIMEOUT_SECONDS}"
opensteamer_require_positive_integer \
  OPENSTEAMER_CALL_ACOUSTIC_TIMEOUT_SECONDS \
  "${CALL_ACOUSTIC_TIMEOUT_SECONDS}"
opensteamer_require_positive_integer \
  OPENSTEAMER_CALL_END_TIMEOUT_SECONDS \
  "${CALL_END_TIMEOUT_SECONDS}"
opensteamer_require_positive_integer \
  OPENSTEAMER_RAW_READY_TIMEOUT_SECONDS \
  "${RAW_READY_TIMEOUT_SECONDS}"
opensteamer_require_positive_integer \
  OPENSTEAMER_POST_CALL_RAW_CONTINUITY_SECONDS \
  "${POST_CALL_RAW_CONTINUITY_SECONDS}"
opensteamer_require_positive_integer \
  OPENSTEAMER_POST_CALL_RAW_PRE_PROBE_BUDGET_SECONDS \
  "${POST_CALL_RAW_PRE_PROBE_BUDGET_SECONDS}"
opensteamer_require_positive_integer \
  OPENSTEAMER_POST_CALL_RAW_INTER_ACK_SNAPSHOT_BUDGET_SECONDS \
  "${POST_CALL_RAW_INTER_ACK_SNAPSHOT_BUDGET_SECONDS}"
opensteamer_require_positive_integer \
  OPENSTEAMER_POST_CALL_RAW_SAFETY_MARGIN_SECONDS \
  "${POST_CALL_RAW_SAFETY_MARGIN_SECONDS}"
opensteamer_require_positive_integer \
  OPENSTEAMER_POST_CALL_RAW_UI_TIMEOUT_SLACK_SECONDS \
  "${POST_CALL_RAW_UI_TIMEOUT_SLACK_SECONDS}"
opensteamer_require_positive_integer \
  OPENSTEAMER_DEVICE_COMMAND_TIMEOUT_SECONDS \
  "${DEVICE_COMMAND_TIMEOUT_SECONDS}"
opensteamer_require_positive_integer \
  OPENSTEAMER_DEVICE_LOCK_POLL_SECONDS \
  "${DEVICE_LOCK_POLL_SECONDS}"
if (( BLACKHOLE_PROBE_TIMEOUT_SECONDS < 8 \
    || BLACKHOLE_PROBE_TIMEOUT_SECONDS > 120 )); then
  echo "OPENSTEAMER_BLACKHOLE_PROBE_TIMEOUT_SECONDS must be between 8 and 120." >&2
  exit 2
fi
if (( RAW_CONTINUITY_REVALIDATION_TIMEOUT_SECONDS < 2 \
    || RAW_CONTINUITY_REVALIDATION_TIMEOUT_SECONDS > 8 )); then
  echo "OPENSTEAMER_RAW_CONTINUITY_REVALIDATION_TIMEOUT_SECONDS must be between 2 and 8." >&2
  exit 2
fi
if (( ${#CALL_READY_TIMEOUT_SECONDS} > 3 \
    || CALL_READY_TIMEOUT_SECONDS > 300 )); then
  echo "OPENSTEAMER_CALL_READY_TIMEOUT_SECONDS must be at most 300." >&2
  exit 2
fi
if (( ${#CALL_ACOUSTIC_TIMEOUT_SECONDS} > 3 \
    || ${#CALL_END_TIMEOUT_SECONDS} > 3 \
    || ${#POST_CALL_RAW_CONTINUITY_SECONDS} > 3 \
    || ${#POST_CALL_RAW_PRE_PROBE_BUDGET_SECONDS} > 2 \
    || ${#POST_CALL_RAW_INTER_ACK_SNAPSHOT_BUDGET_SECONDS} > 2 \
    || ${#POST_CALL_RAW_SAFETY_MARGIN_SECONDS} > 3 \
    || ${#POST_CALL_RAW_UI_TIMEOUT_SLACK_SECONDS} > 3 \
    || CALL_ACOUSTIC_TIMEOUT_SECONDS > 300 \
    || CALL_END_TIMEOUT_SECONDS > 300 \
    || POST_CALL_RAW_CONTINUITY_SECONDS > 600 \
    || POST_CALL_RAW_PRE_PROBE_BUDGET_SECONDS < 12 \
    || POST_CALL_RAW_PRE_PROBE_BUDGET_SECONDS > 60 \
    || POST_CALL_RAW_INTER_ACK_SNAPSHOT_BUDGET_SECONDS < 1 \
    || POST_CALL_RAW_INTER_ACK_SNAPSHOT_BUDGET_SECONDS > 15 \
    || POST_CALL_RAW_SAFETY_MARGIN_SECONDS > 120 \
    || POST_CALL_RAW_UI_TIMEOUT_SLACK_SECONDS > 120 )); then
  echo "The post-call timing contract is outside its reviewed bounded range." >&2
  exit 2
fi
POST_CALL_RAW_REQUIRED_CONTINUITY_SECONDS=$((
  CALL_ACOUSTIC_TIMEOUT_SECONDS
  + CALL_END_TIMEOUT_SECONDS
  + POST_CALL_RAW_INTER_ACK_SNAPSHOT_BUDGET_SECONDS
  + POST_CALL_RAW_PRE_PROBE_BUDGET_SECONDS
  + POST_CALL_RAW_REQUIRED_OVERLAP_SECONDS
  + POST_CALL_RAW_SAFETY_MARGIN_SECONDS
))
POST_CALL_RAW_UI_TIMEOUT_SECONDS=$((
  POST_CALL_RAW_CONTINUITY_SECONDS
  + POST_CALL_RAW_UI_TIMEOUT_SLACK_SECONDS
))
if (( POST_CALL_RAW_CONTINUITY_SECONDS \
      < POST_CALL_RAW_REQUIRED_CONTINUITY_SECONDS )); then
  echo "OPENSTEAMER_POST_CALL_RAW_CONTINUITY_SECONDS must cover the acoustic and end-call timeouts, bounded inter-ack CoreAudio snapshot, bounded pre-probe verifier, six-second probe, and safety margin (minimum ${POST_CALL_RAW_REQUIRED_CONTINUITY_SECONDS})." >&2
  exit 2
fi
if (( POST_CALL_RAW_UI_TIMEOUT_SECONDS >= UI_TEST_TIMEOUT_SECONDS )); then
  echo "The post-call raw UI timeout must remain below OPENSTEAMER_UI_TEST_TIMEOUT_SECONDS." >&2
  exit 2
fi

rm -rf \
  "${RAW_PHASE_DIR}" \
  "${RECONNECT_PHASE_DIR}" \
  "${CALL_PHASE_DIR}" \
  "${PHASE_EVENTS}" \
  "${DERIVED_DATA}" \
  "${RESULT_BUNDLE}" \
  "${LEGACY_DERIVED_DATA}" \
  "${LEGACY_RECONNECT_RESULT_BUNDLE}" \
  "${LEGACY_HOST_EVENTS}" \
  "${LEGACY_HOST_STATUS}" \
  "${LEGACY_SUMMARY_JSON}" \
  "${LEGACY_TESTS_JSON}" \
  "${LEGACY_BUILD_RESULTS_JSON}" \
  "${LEGACY_ACTIVITIES_JSON}" \
  "${LEGACY_DEVICE_LOCKED_MARKER}" \
  "${HOST_EVENTS}" \
  "${HOST_STATUS}" \
  "${HOST_BUILD_STDOUT}" \
  "${HOST_BUILD_STDERR}" \
  "${HOST_DEPLOYMENT_MANIFEST}" \
  "${HOST_DEPLOYMENT_STDERR}" \
  "${HOST_DEPLOYMENT_RECHECK_STDOUT}" \
  "${HOST_DEPLOYMENT_RECHECK_STDERR}" \
  "${HOST_GENERATION_STATE}" \
  "${PHYSICAL_VALIDATION_ORACLE_SELF_TEST}" \
  "${XCODE_TEMP_DIR}" \
  "${UI_TEST_TIMEOUT_MARKER}" \
  "${DEVICE_LOCKED_MARKER}" \
  "${DEVICE_UNAVAILABLE_MARKER}" \
  "${HOST_WATCHER_FAILURE_MARKER}" \
  "${HOST_CHURN_LOCK}" \
  "${HOST_CHURN_STOP_MARKER}" \
  "${HOST_LOG_APPEND_CHUNK}" \
  "${HOST_LOG_COMPLETED_LINES}" \
  "${HOST_LOG_PARTIAL_LINE}" \
  "${WATCHDOG_STATE}" \
  "${WATCHDOG_FAILURE_MARKER}" \
  "${AUDIO_ORACLE_TONE}" \
  "${AUDIO_ORACLE_TONE_LOG}" \
  "${AUDIO_ORACLE_TONE_FAILURE_MARKER}" \
  "${SCREEN_ORACLE_BINARY}" \
  "${SCREEN_ORACLE_HEARTBEAT}" \
  "${SCREEN_ORACLE_LOG}" \
  "${SCREEN_ORACLE_FAILURE_MARKER}" \
  "${SCREEN_ORACLE_CLEANUP_PROOF}" \
  "${DEVICE_BEFORE}" \
  "${DEVICE_AFTER}" \
  "${LOCK_STATE_BEFORE}" \
  "${LOCK_STATE_BEFORE_XCODEBUILD}" \
  "${LOCK_STATE_DURING_TEST}" \
  "${LOCK_STATE_AFTER_XCODEBUILD}" \
  "${APP_LIST_BEFORE}" \
  "${APP_LIST_AFTER}" \
  "${CANDIDATE_BEFORE}" \
  "${CANDIDATE_AFTER}" \
  "${ACTIVITIES_JSON}" \
  "${ARTIFACT_DIR}/host-launch-agent-before.txt" \
  "${ARTIFACT_DIR}/fast-group-leader-pid.txt" \
  "${ARTIFACT_DIR}/fast-group-child-pid.txt" \
  "${ARTIFACT_DIR}/blackhole-probe-leader-pid.txt" \
  "${ARTIFACT_DIR}/blackhole-validation-sentinel-pid.txt" \
  "${ARTIFACT_DIR}/call-stable-host-pid.txt" \
  "${ARTIFACT_DIR}/call-phase-leak-pid.txt" \
  "${ARTIFACT_DIR}/call-phase-leak-child-pid.txt" \
  "${ARTIFACT_DIR}/cancel-churn-ready.txt" \
  "${ARTIFACT_DIR}/cancel-churn-proceed.txt" \
  "${ARTIFACT_DIR}/cancel-churn-action.txt"

mkdir -p \
  "${RAW_PHASE_DIR}" \
  "${RECONNECT_PHASE_DIR}" \
  "${CALL_PHASE_DIR}" \
  "${XCODE_TEMP_DIR}" \
  "${XCODE_SOURCE_PACKAGES}"
initialize_physical_validation_oracle

function start_physical_audio_oracle_tone() {
  local tone_path=${1:-${AUDIO_ORACLE_TONE}}
  local tone_log=${2:-${AUDIO_ORACLE_TONE_LOG}}
  local duration_seconds=${3:-${AUDIO_ORACLE_DURATION_SECONDS}}
  local generation_status
  local group_status

  opensteamer_run_physical_validation_oracle \
    wav-tone "${tone_path}" "${duration_seconds}"
  generation_status=$?
  (( generation_status == 0 )) || return "${generation_status}"

  opensteamer_exec_in_isolated_process_group \
    /usr/bin/afplay -v 0.25 "${tone_path}" \
    > "${tone_log}" 2>&1 &
  AUDIO_ORACLE_TONE_PID=$!
  if opensteamer_require_isolated_process_group "${AUDIO_ORACLE_TONE_PID}" 5; then
    :
  else
    group_status=$?
    cleanup_audio_oracle_tone || true
    return "${group_status}"
  fi
  sleep 0.25
  if ! opensteamer_process_group_exists "${AUDIO_ORACLE_TONE_PID}"; then
    echo "Refusing device validation: deterministic Mac audio oracle tone did not start." >&2
    return 1
  fi
  return 0
}

function start_physical_screen_oracle_challenge() {
  TMPDIR="${XCODE_TEMP_DIR}" xcrun --sdk macosx swiftc \
    -parse-as-library \
    -framework AppKit \
    "${SCREEN_ORACLE_SOURCE}" \
    -o "${SCREEN_ORACLE_BINARY}"
  local compile_status=$?
  local group_status

  (( compile_status == 0 )) || return "${compile_status}"
  opensteamer_exec_in_isolated_process_group \
    "${SCREEN_ORACLE_BINARY}" "${SCREEN_ORACLE_HEARTBEAT}" \
    > "${SCREEN_ORACLE_LOG}" 2>&1 &
  SCREEN_ORACLE_PID=$!
  run_command_capturing_status \
    opensteamer_require_isolated_process_group "${SCREEN_ORACLE_PID}" 5
  group_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( group_status != 0 )); then
    cleanup_screen_oracle_challenge || true
    return "${group_status}"
  fi
  for challenge_poll in {1..100}; do
    if [[ -s "${SCREEN_ORACLE_HEARTBEAT}" ]]; then
      break
    fi
    if ! opensteamer_process_group_exists "${SCREEN_ORACLE_PID}"; then
      echo "Refusing device validation: decoded-screen pixel challenge exited during startup." >&2
      return 1
    fi
    sleep 0.05
  done
  if [[ ! -s "${SCREEN_ORACLE_HEARTBEAT}" ]] \
      || ! opensteamer_process_group_exists "${SCREEN_ORACLE_PID}"; then
    echo "Refusing device validation: decoded-screen pixel challenge did not start." >&2
    return 1
  fi
  return 0
}

function physical_screen_oracle_counter() {
  local value
  value=$(cat "${SCREEN_ORACLE_HEARTBEAT}" 2>/dev/null || true)
  [[ "${value}" =~ '^counter=[0-9]+$' ]] || return 1
  print -r -- "${value#counter=}"
}

function validate_required_physical_activities_json() {
  local activities_file=$1
  jq -e \
    --arg test_url "${EXPECTED_TEST_URL}" '
    # `xcresulttool ... activities` exposes attachment identity and payload metadata, but not
    # the raw string/screenshot bytes. Validate exactly what is observable: the named payload
    # must be retained, addressable, timestamped, and UUID-identified on its expected activity.
    def valid_attachment_metadata:
      .payloadId? as $payload |
      .uuid? as $uuid |
      .timestamp? as $timestamp |
      .lifetime? as $lifetime |
      (($payload | type) == "string") and
      (($payload | length) >= 16) and
      ($payload | test("^0~[A-Za-z0-9_-]+={0,2}$")) and
      (($uuid | type) == "string") and
      ($uuid | test("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")) and
      (($timestamp | type) == "number") and
      ($timestamp > 0) and
      ($lifetime == "keepAlways");
    def valid_activity_metadata:
      (.isAssociatedWithFailure? == false) and
      ((.startTime? | type) == "number") and
      (.startTime > 0);
    def one_named_attachment($activity; $name):
      ([($activity.attachments // [])[] | select(.name? == $name)] as $matches |
        (($matches | length) == 1) and
        ($matches[0] | valid_attachment_metadata));
    def one_matching_attachment($activity; $pattern):
      ([($activity.attachments // [])[]
        | select(((.name? // "") | test($pattern)))] as $matches |
        (($matches | length) == 1) and
        ($matches[0] | valid_attachment_metadata));
    def one_activity($activities; $title):
      [($activities // [])[] | select(.title? == $title)];
    def one_activity_with_attachments($activities; $title; $names):
      (one_activity($activities; $title) as $matches |
        (($matches | length) == 1) and
        ($matches[0] | valid_activity_metadata) and
        all($names[]; . as $name | one_named_attachment($matches[0]; $name)));
    def one_restart_activity($activities; $attempt):
      (one_activity(
        $activities;
        "Same-process host restart and reconnect " + $attempt
      ) as $matches |
        (($matches | length) == 1) and
        ($matches[0] | valid_activity_metadata) and
        one_named_attachment(
          $matches[0];
          "WebRTC route - host restart reconnect " + $attempt
        ) and
        one_matching_attachment(
          $matches[0];
          "^test iPhone (Direct|TURN relay) route before host restart " + $attempt + "$"
        ) and
        one_named_attachment(
          $matches[0];
          "test iPhone recovered in same process " + $attempt
        ));
    def one_cold_launch_activity($activities):
      (one_activity($activities; "Cold-launch saved-pair reconnect") as $matches |
        (($matches | length) == 1) and
        ($matches[0] | valid_activity_metadata) and
        one_named_attachment(
          $matches[0];
          "WebRTC route - cold-launch saved-pair reconnect"
        ) and
        one_named_attachment(
          $matches[0];
          "WebRTC route - after background audio proof"
        ) and
        one_named_attachment(
          $matches[0];
          "WebRTC route - after hiding the cold-launch Mac screen"
        ) and
        one_activity_with_attachments(
          ($matches[0].childActivities // []);
          "Physical background audio continuity oracle";
          ["Background native audio continuity evidence"]
        ) and
        one_activity_with_attachments(
          ($matches[0].childActivities // []);
          "Physical screen Show-Hide and same-session audio oracle";
          [
            "test iPhone live Mac screen with authenticated input capability",
            "Decoded screen pixel freshness evidence",
            "Authenticated screen Show-Hide evidence",
            "Same-session audio continuity across screen Show-Hide"
          ]
        ));
    (.testIdentifierURL == $test_url) and
    ((.testRuns | type) == "array") and
    ((.testRuns | length) == 1) and
    ((.testRuns[0].activities | type) == "array") and
    (.testRuns[0].activities as $root_activities |
      one_restart_activity($root_activities; "1") and
      one_restart_activity($root_activities; "2") and
      one_restart_activity($root_activities; "3") and
      one_activity_with_attachments(
        $root_activities;
        "Explicit disconnect and same-process reconnect";
        [
          "WebRTC route - before explicit disconnect",
          "WebRTC route - same-process reconnect after explicit disconnect"
        ]
      ) and
      one_cold_launch_activity($root_activities))
  ' "${activities_file}" >/dev/null
}

function validate_direct_attachment_activities_json() {
  local activities_file=$1
  local expected_test_url=$2
  shift 2
  local required_names_json

  required_names_json=$(opensteamer_run_physical_validation_oracle \
    argv-json "$@")
  jq -e \
    --arg test_url "${expected_test_url}" \
    --argjson required_names "${required_names_json}" '
    def valid_attachment_metadata:
      .payloadId? as $payload |
      .uuid? as $uuid |
      .timestamp? as $timestamp |
      .lifetime? as $lifetime |
      (($payload | type) == "string") and
      (($payload | length) >= 16) and
      ($payload | test("^0~[A-Za-z0-9_-]+={0,2}$")) and
      (($uuid | type) == "string") and
      ($uuid | test("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")) and
      (($timestamp | type) == "number") and
      ($timestamp > 0) and
      ($lifetime == "keepAlways");
    def valid_activity_metadata:
      (.isAssociatedWithFailure? == false) and
      ((.startTime? | type) == "number") and
      (.startTime > 0);
    (.testIdentifierURL == $test_url) and
    ((.testRuns | type) == "array") and
    ((.testRuns | length) == 1) and
    ((.testRuns[0].activities | type) == "array") and
    (.testRuns[0].activities as $activities |
      [
        $activities[]?
        | ..
        | objects
        | select((.attachments? | type) == "array")
        | . as $activity
        | ($activity.attachments // [])[]
        | {
            activity: $activity,
            attachment: .
          }
      ] as $records |
      all(
        $required_names[];
        . as $required_name |
        ([
          $records[]
          | select(.attachment.name? == $required_name)
        ] as $matches |
          (($matches | length) == 1) and
          ($matches[0].activity | valid_activity_metadata) and
          ($matches[0].attachment | valid_attachment_metadata))
      ))
  ' "${activities_file}" >/dev/null
}

function capture_unique_direct_attachment_payload_id() {
  local activities_file=$1
  local expected_test_url=$2
  local attachment_name=$3
  local output=$4
  local temporary="${output}.tmp.$$"

  rm -f "${output}" "${temporary}" || return $?
  jq -er \
    --arg test_url "${expected_test_url}" \
    --arg attachment_name "${attachment_name}" '
    if (.testIdentifierURL == $test_url) and
       ((.testRuns | type) == "array") and
       ((.testRuns | length) == 1) and
       ((.testRuns[0].activities | type) == "array") then
      [
        .testRuns[0].activities[]?
        | ..
        | objects
        | select((.attachments? | type) == "array")
        | (.attachments // [])[]
        | select(.name? == $attachment_name)
        | .payloadId?
      ] as $matches |
      if (($matches | length) == 1) and
         (($matches[0] | type) == "string") and
         ($matches[0] | test("^0~[A-Za-z0-9_-]+={0,2}$"))
      then
        $matches[0]
      else
        error("missing or ambiguous runtime attachment payload")
      end
    else
      error("runtime attachment is not bound to the exact test run")
    end
  ' "${activities_file}" > "${temporary}" || {
    rm -f "${temporary}"
    return 3
  }
  mv "${temporary}" "${output}"
}

function validate_raw_physical_activities_json() {
  rm -f "${RAW_UI_RUNTIME_ATTACHMENT_PAYLOAD_ID}" || return $?
  validate_direct_attachment_activities_json \
    "$1" \
    "${EXPECTED_RAW_TEST_URL}" \
    "Production raw iPhone microphone rolling continuity evidence" \
    "${EXPECTED_RAW_RUNTIME_ATTACHMENT_NAME}" || return $?
  capture_unique_direct_attachment_payload_id \
    "$1" \
    "${EXPECTED_RAW_TEST_URL}" \
    "${EXPECTED_RAW_RUNTIME_ATTACHMENT_NAME}" \
    "${RAW_UI_RUNTIME_ATTACHMENT_PAYLOAD_ID}"
}

function validate_call_physical_activities_json() {
  mkdir -p "${CALL_POST_RAW_DIR}" || return $?
  validate_direct_attachment_activities_json \
    "$1" \
    "${EXPECTED_CALL_TEST_URL}" \
    "Startup connected-call incoming Mac playout continuity evidence" \
    "Interruption-origin incoming Mac playout continuity evidence" \
    "Fresh ordinary audio proof after final call recovery" \
    "Post-call raw iPhone microphone rolling continuity evidence" \
    "Post-call raw iPhone microphone runtime overlap evidence" \
    "Post-call raw microphone generation evidence" || return $?
  capture_unique_direct_attachment_payload_id \
    "$1" \
    "${EXPECTED_CALL_TEST_URL}" \
    "Post-call raw iPhone microphone runtime overlap evidence" \
    "${CALL_POST_RAW_UI_RUNTIME_ATTACHMENT_PAYLOAD_ID}" || return $?
  capture_unique_direct_attachment_payload_id \
    "$1" \
    "${EXPECTED_CALL_TEST_URL}" \
    "Post-call raw microphone generation evidence" \
    "${CALL_POST_RAW_GENERATION_ATTACHMENT_PAYLOAD_ID}"
}

function capture_and_validate_device() {
  local output=$1
  xcrun devicectl device info details \
    --device "${COREDEVICE_IDENTIFIER}" \
    --timeout "${DEVICE_COMMAND_TIMEOUT_SECONDS}" \
    --json-output "${output}" >/dev/null
  local command_status=$?
  (( command_status == 0 )) || return "${command_status}"
  opensteamer_require_physical_iphone_xr_details \
    "${output}" \
    "${COREDEVICE_IDENTIFIER}" \
    "${HARDWARE_UDID}"
}

function capture_and_require_unlocked() {
  local output=$1
  if [[ "${OPENSTEAMER_SELF_TEST_CRITICAL_FAILURE:-}" == "lock-proof" ]]; then
    return 44
  fi
  opensteamer_require_device_unlocked \
    "${COREDEVICE_IDENTIFIER}" \
    "${DEVICE_COMMAND_TIMEOUT_SECONDS}" \
    "${output}" \
    "device reconnect validation"
}

function capture_production_candidate() {
  local app_list=$1
  local candidate=$2
  xcrun devicectl device info apps \
    --device "${COREDEVICE_IDENTIFIER}" \
    --timeout "${DEVICE_COMMAND_TIMEOUT_SECONDS}" \
    --json-output "${app_list}" >/dev/null
  local command_status=$?
  (( command_status == 0 )) || return "${command_status}"

  # Address only the explicitly selected side-by-side App Store/TestFlight application.
  jq -e \
    --arg bundle "${EXPECTED_APP_BUNDLE_IDENTIFIER}" \
    --arg build "${EXPECTED_BUILD}" '
    [.result.apps[] | select(.bundleIdentifier == $bundle)] as $matches
    | (($matches | length) == 1) and
      ($matches[0].bundleVersion == $build) and
      ($matches[0].name == "opensteamer") and
      ($matches[0].appClip == false) and
      ($matches[0].internalApp == false) and
      ($matches[0].removable == true)
  ' "${app_list}" >/dev/null || return $?

  jq -S \
    --arg bundle "${EXPECTED_APP_BUNDLE_IDENTIFIER}" '
    [.result.apps[] | select(.bundleIdentifier == $bundle)][0]
  ' "${app_list}" > "${candidate}" || return $?
}

function capture_ui_xcresult_payload() {
  local payload_kind=$1
  local result_bundle=$2
  local expected_test_url=$3
  local injected_failure=${OPENSTEAMER_SELF_TEST_XCRESULT_FAILURE:-}

  if [[ -n "${injected_failure}" ]]; then
    if [[ "${payload_kind}" == "${injected_failure}" ]]; then
      case "${payload_kind}" in
        summary) return 31 ;;
        tests) return 32 ;;
        build-results) return 33 ;;
        activities) return 34 ;;
        *) return 35 ;;
      esac
    fi
    print -r -- '{}'
    return 0
  fi

  case "${payload_kind}" in
    summary)
      xcrun xcresulttool get test-results summary \
        --path "${result_bundle}" \
        --compact
      ;;
    tests)
      xcrun xcresulttool get test-results tests \
        --path "${result_bundle}" \
        --compact
      ;;
    build-results)
      xcrun xcresulttool get build-results \
        --path "${result_bundle}" \
        --compact
      ;;
    activities)
      xcrun xcresulttool get test-results activities \
        --path "${result_bundle}" \
        --test-id "${expected_test_url}" \
        --compact
      ;;
    *)
      return 2
      ;;
  esac
}

function capture_ui_xcresult_attachment_payload() {
  local result_bundle=$1
  local payload_id_file=$2
  local output=$3
  local payload_id
  local temporary="${output}.tmp.$$"
  local command_status

  rm -f "${output}" "${temporary}" || return $?
  [[ -s "${payload_id_file}" ]] || return 3
  payload_id=$(<"${payload_id_file}") || return 3
  if opensteamer_run_physical_validation_oracle \
      validate-payload-id "${payload_id}"; then
    :
  else
    rm -f "${output}" "${temporary}"
    return 3
  fi
  if [[ -n "${OPENSTEAMER_SELF_TEST_RAW_ATTACHMENT_EXPORT_FAILURE:-}" ]]; then
    return 41
  fi
  if [[ -n "${OPENSTEAMER_SELF_TEST_RAW_UI_RUNTIME_PAYLOAD:-}" ]]; then
    [[ -s "${OPENSTEAMER_SELF_TEST_RAW_UI_RUNTIME_PAYLOAD}" ]] || return 3
    if /bin/cp \
        "${OPENSTEAMER_SELF_TEST_RAW_UI_RUNTIME_PAYLOAD}" \
        "${temporary}"; then
      :
    else
      command_status=$?
      rm -f "${temporary}"
      return "${command_status}"
    fi
  else
    if xcrun xcresulttool export object \
        --legacy \
        --path "${result_bundle}" \
        --id "${payload_id}" \
        --type file \
        --output-path "${temporary}" \
        >/dev/null; then
      :
    else
      command_status=$?
      rm -f "${temporary}"
      return "${command_status}"
    fi
  fi
  [[ -s "${temporary}" ]] || {
    rm -f "${temporary}"
    return 3
  }
  mv "${temporary}" "${output}"
}

function validate_ui_xcresult() {
  local result_bundle=$1
  local summary_file=$2
  local tests_file=$3
  local build_results_file=$4
  local activities_file=$5
  local expected_test_node=$6
  local expected_test_url=$7
  local activity_validator=$8
  local summary
  local tests
  local build_results
  local activities

  summary=$(capture_ui_xcresult_payload summary "${result_bundle}" "${expected_test_url}") \
    || return $?
  tests=$(capture_ui_xcresult_payload tests "${result_bundle}" "${expected_test_url}") \
    || return $?
  build_results=$(capture_ui_xcresult_payload build-results "${result_bundle}" "${expected_test_url}") \
    || return $?
  activities=$(capture_ui_xcresult_payload activities "${result_bundle}" "${expected_test_url}") \
    || return $?
  print -r -- "${summary}" > "${summary_file}" || return $?
  print -r -- "${tests}" > "${tests_file}" || return $?
  print -r -- "${build_results}" > "${build_results_file}" || return $?
  print -r -- "${activities}" > "${activities_file}" || return $?

  jq -e \
    --arg hardware_udid "${HARDWARE_UDID}" \
    --arg model "${EXPECTED_MODEL}" \
    --arg os "${EXPECTED_OS}" \
    --arg platform "${EXPECTED_PLATFORM}" '
    (.result == "Passed") and
    (.totalTestCount == 1) and
    (.passedTests == 1) and
    (.failedTests == 0) and
    (.skippedTests == 0) and
    (.expectedFailures == 0) and
    ((.testFailures | length) == 0) and
    ((.devicesAndConfigurations | length) == 1) and
    (.devicesAndConfigurations[0].passedTests == 1) and
    (.devicesAndConfigurations[0].failedTests == 0) and
    (.devicesAndConfigurations[0].skippedTests == 0) and
    (.devicesAndConfigurations[0].expectedFailures == 0) and
    (.devicesAndConfigurations[0].device.deviceId == $hardware_udid) and
    (.devicesAndConfigurations[0].device.modelName == $model) and
    (.devicesAndConfigurations[0].device.osVersion == $os) and
    (.devicesAndConfigurations[0].device.platform == $platform)
  ' <<<"${summary}" >/dev/null || return $?

  jq -e \
    --arg hardware_udid "${HARDWARE_UDID}" \
    --arg model "${EXPECTED_MODEL}" \
    --arg os "${EXPECTED_OS}" \
    --arg platform "${EXPECTED_PLATFORM}" \
    --arg node "${expected_test_node}" \
    --arg url "${expected_test_url}" '
    ((.devices | length) == 1) and
    (.devices[0].deviceId == $hardware_udid) and
    (.devices[0].modelName == $model) and
    (.devices[0].osVersion == $os) and
    (.devices[0].platform == $platform) and
    ([.. | objects | select(.nodeType? == "Test Case")] | length == 1) and
    ([.. | objects | select(.nodeType? == "Test Case")][0].nodeIdentifier == $node) and
    ([.. | objects | select(.nodeType? == "Test Case")][0].nodeIdentifierURL == $url) and
    ([.. | objects | select(.nodeType? == "Test Case")][0].result == "Passed")
  ' <<<"${tests}" >/dev/null || return $?

  jq -e \
    --arg hardware_udid "${HARDWARE_UDID}" \
    --arg model "${EXPECTED_MODEL}" \
    --arg os "${EXPECTED_OS}" \
    --arg platform "${EXPECTED_PLATFORM}" '
    (.status == "succeeded") and
    (([.errorCount, .warningCount, .analyzerWarningCount] | add) == 0) and
    ((.errors | length) == 0) and
    ((.warnings | length) == 0) and
    ((.analyzerWarnings | length) == 0) and
    (.actionTitle == "Testing project opensteamer with scheme opensteamerUITests") and
    (.destination.deviceId == $hardware_udid) and
    (.destination.modelName == $model) and
    (.destination.osVersion == $os) and
    (.destination.platform == $platform)
  ' <<<"${build_results}" >/dev/null || return $?

  "${activity_validator}" "${activities_file}" || return $?
}

function validate_blackhole_probe_json() {
  local result_file=$1
  local expected_nonce=$2
  local runtime_physical_output_uid=$3

  jq -e \
    --arg expected_nonce "${expected_nonce}" \
    --arg physical_output_uid "${runtime_physical_output_uid}" '
    def exact_keys($expected):
      (keys == ($expected | sort));
    def nonnegative_integer:
      (type == "number") and
      (. >= 0) and
      (floor == .);
    def positive_integer:
      (type == "number") and
      (. > 0) and
      (floor == .);
    def finite_number:
      type == "number";
    def close($first; $second; $tolerance):
      ((($first - $second) | abs) <= $tolerance);
    . as $root |
    exact_keys([
      "advancingProgressObservationCount",
      "aggregateClippedRatio",
      "callbackCount",
      "canonicalCaptureUID",
      "captureQueueReadbackMatches",
      "captureSeconds",
      "captureUIDMatches",
      "capturedFrameCount",
      "challengeAlgorithm",
      "challengeNonceMatches",
      "challengeVersion",
      "channels",
      "defaultChangeNotificationCount",
      "defaultInputBeforeAfterEqual",
      "defaultOutputBeforeAfterEqual",
      "defaultSystemOutputBeforeAfterEqual",
      "detectedLagMs",
      "discriminationMargin",
      "envelopeCorrelation",
      "failureCode",
      "failureReasons",
      "format",
      "frameDensity",
      "longestNonSilentGapMs",
      "matchRatio",
      "matchedSymbolCount",
      "maxCallbackGapMs",
      "nonSilentFrameRatio",
      "normalizedCorrelation",
      "physicalOutputQueueReadbackMatches",
      "physicalOutputValidated",
      "progressObservationCount",
      "progressSnapshots",
      "proofWindowSeconds",
      "queueReadbackMatches",
      "recognizedChannel",
      "runNonce",
      "schema",
      "status",
      "symbolCount",
      "totalCallbackCount",
      "totalCapturedFrameCount"
    ]) and
    ([.. | strings | select(contains($physical_output_uid))] | length == 0) and
    (.schema == "opensteamer.physical-blackhole-microphone.v1") and
    (.status == "passed") and
    (.runNonce == $expected_nonce) and
    (.challengeAlgorithm == "nonce-splitmix64-frequency-hop-raised-envelope") and
    (.challengeVersion == 1) and
    (.canonicalCaptureUID == "BlackHole2ch_UID") and
    (.captureUIDMatches == true) and
    (.physicalOutputValidated == true) and
    (.challengeNonceMatches == true) and
    (.queueReadbackMatches == true) and
    (.captureQueueReadbackMatches == true) and
    (.physicalOutputQueueReadbackMatches == true) and
    (.queueReadbackMatches ==
      (.captureQueueReadbackMatches and .physicalOutputQueueReadbackMatches)) and
    (.format |
      exact_keys([
        "channels",
        "interleaved",
        "sampleRate",
        "signedInt16"
      ]) and
      (.sampleRate == 48000) and
      (.channels == 2) and
      (.signedInt16 == true) and
      (.interleaved == true)) and
    (.proofWindowSeconds | finite_number) and
    (.proofWindowSeconds >= 6) and
    (.captureSeconds | finite_number) and
    (.captureSeconds > 0) and
    (.callbackCount | positive_integer) and
    (.capturedFrameCount | positive_integer) and
    (.totalCallbackCount | positive_integer) and
    (.totalCapturedFrameCount | positive_integer) and
    (.callbackCount <= .totalCallbackCount) and
    (.capturedFrameCount <= .totalCapturedFrameCount) and
    close(
      .captureSeconds;
      (.capturedFrameCount / 48000);
      0.0001
    ) and
    (.frameDensity | finite_number) and
    close(
      .frameDensity;
      (.capturedFrameCount / (.proofWindowSeconds * 48000));
      0.000001
    ) and
    (.frameDensity >= 0.85) and
    (.frameDensity <= 1.15) and
    (.captureSeconds >= (.proofWindowSeconds * 0.85)) and
    (.captureSeconds <= (.proofWindowSeconds * 1.15)) and
    (.maxCallbackGapMs | finite_number) and
    (.maxCallbackGapMs >= 0) and
    (.maxCallbackGapMs <= 100) and
    (.longestNonSilentGapMs | finite_number) and
    (.longestNonSilentGapMs >= 0) and
    (.longestNonSilentGapMs <= 500) and
    (.nonSilentFrameRatio | finite_number) and
    (.nonSilentFrameRatio >= 0.20) and
    (.nonSilentFrameRatio <= 1) and
    (.aggregateClippedRatio | finite_number) and
    (.aggregateClippedRatio >= 0) and
    (.aggregateClippedRatio < 0.005) and
    (.progressObservationCount | positive_integer) and
    (.advancingProgressObservationCount | nonnegative_integer) and
    (.advancingProgressObservationCount >= 2) and
    (.progressSnapshots as $progress |
      (($progress | type) == "array") and
      (($progress | length) == $root.progressObservationCount) and
      (($progress | length) >= 3) and
      all(
        $progress[];
        exact_keys([
          "advancing",
          "callbackCount",
          "callbackDelta",
          "capturedFrameCount",
          "elapsedSeconds",
          "frameDelta"
        ]) and
        (.elapsedSeconds | finite_number) and
        (.elapsedSeconds >= 0) and
        (.elapsedSeconds <= $root.proofWindowSeconds) and
        (.callbackCount | nonnegative_integer) and
        (.capturedFrameCount | nonnegative_integer) and
        (.callbackDelta | nonnegative_integer) and
        (.frameDelta | nonnegative_integer) and
        ((.advancing | type) == "boolean") and
        (.advancing == ((.callbackDelta > 0) and (.frameDelta > 0)))
      ) and
      ($progress[0].callbackDelta == 0) and
      ($progress[0].frameDelta == 0) and
      all(
        range(1; ($progress | length));
        . as $index |
        ($progress[$index].elapsedSeconds >=
          $progress[$index - 1].elapsedSeconds) and
        ($progress[$index].callbackCount >=
          $progress[$index - 1].callbackCount) and
        ($progress[$index].capturedFrameCount >=
          $progress[$index - 1].capturedFrameCount) and
        ($progress[$index].callbackDelta ==
          ($progress[$index].callbackCount -
            $progress[$index - 1].callbackCount)) and
        ($progress[$index].frameDelta ==
          ($progress[$index].capturedFrameCount -
            $progress[$index - 1].capturedFrameCount))
      ) and
      (([
        $progress[]
        | select(.advancing == true)
      ] | length) == $root.advancingProgressObservationCount) and
      ($progress[-1].callbackCount <= $root.totalCallbackCount) and
      ($progress[-1].capturedFrameCount <= $root.totalCapturedFrameCount)) and
    (.channels as $channels |
      (($channels | type) == "array") and
      (($channels | length) == 2) and
      (([$channels[].channel] | sort) == [0, 1]) and
      all(
        $channels[];
        exact_keys([
          "challengeSymbolCount",
          "channel",
          "clippedRatio",
          "discriminationMargin",
          "envelopeCorrelation",
          "matchRatio",
          "matchedSymbolCount",
          "nonSilentRatio",
          "normalizedCorrelation",
          "peak",
          "rms"
        ]) and
        (.channel | nonnegative_integer) and
        (.rms | finite_number) and
        (.rms >= 0) and
        (.peak | nonnegative_integer) and
        (.peak < 32760) and
        (.rms <= .peak) and
        (.clippedRatio | finite_number) and
        (.clippedRatio >= 0) and
        (.clippedRatio < 0.005) and
        (.nonSilentRatio | finite_number) and
        (.nonSilentRatio >= 0) and
        (.nonSilentRatio <= 1) and
        (.challengeSymbolCount | positive_integer) and
        (.matchedSymbolCount | nonnegative_integer) and
        (.matchedSymbolCount <= .challengeSymbolCount) and
        (.matchRatio | finite_number) and
        close(
          .matchRatio;
          (.matchedSymbolCount / .challengeSymbolCount);
          0.000000001
        ) and
        (.normalizedCorrelation | finite_number) and
        (.normalizedCorrelation >= 0) and
        (.normalizedCorrelation <= 1) and
        (.discriminationMargin | finite_number) and
        (.discriminationMargin >= -1) and
        (.discriminationMargin <= 1) and
        (.envelopeCorrelation | finite_number) and
        (.envelopeCorrelation >= -1) and
        (.envelopeCorrelation <= 1)
      ) and
      ($root.recognizedChannel | nonnegative_integer) and
      (($root.recognizedChannel == 0) or
        ($root.recognizedChannel == 1)) and
      ([
        $channels[]
        | select(.channel == $root.recognizedChannel)
      ][0]) as $recognized |
      ($recognized.peak >= 512) and
      ($recognized.nonSilentRatio >= 0.20) and
      ($root.symbolCount | positive_integer) and
      ($root.symbolCount >= 16) and
      ($root.matchedSymbolCount | nonnegative_integer) and
      ($root.matchedSymbolCount <= $root.symbolCount) and
      close(
        $root.matchRatio;
        ($root.matchedSymbolCount / $root.symbolCount);
        0.000000001
      ) and
      ($root.matchRatio >= 0.80) and
      ($root.normalizedCorrelation >= 0.60) and
      ($root.discriminationMargin >= 0.10) and
      ($root.symbolCount == $recognized.challengeSymbolCount) and
      ($root.matchedSymbolCount == $recognized.matchedSymbolCount) and
      close($root.matchRatio; $recognized.matchRatio; 0.000000001) and
      close(
        $root.normalizedCorrelation;
        $recognized.normalizedCorrelation;
        0.000000001
      ) and
      close(
        $root.discriminationMargin;
        $recognized.discriminationMargin;
        0.000000001
      ) and
      close(
        $root.envelopeCorrelation;
        $recognized.envelopeCorrelation;
        0.000000001
      ) and
      close(
        $root.aggregateClippedRatio;
        (([$channels[].clippedRatio] | add) / 2);
        0.000000001
      )) and
    (.detectedLagMs | finite_number) and
    (.detectedLagMs >= 40) and
    (.detectedLagMs <= 5000) and
    (.defaultInputBeforeAfterEqual == true) and
    (.defaultOutputBeforeAfterEqual == true) and
    (.defaultSystemOutputBeforeAfterEqual == true) and
    (.defaultChangeNotificationCount == 0) and
    (.failureCode == "none") and
    (.failureReasons == [])
  ' "${result_file}" >/dev/null
}

function current_host_pid() {
  if [[ ( "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == host-provenance-* \
        || "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == call-stable-host-* \
        || "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == raw-readiness-* ) \
      && -n "${OPENSTEAMER_SELF_TEST_HOST_PID_FILE:-}" ]]; then
    tr -d '[:space:]' < "${OPENSTEAMER_SELF_TEST_HOST_PID_FILE}" 2>/dev/null \
      || true
    return
  fi
  launchctl print "${HOST_SERVICE}" 2>/dev/null \
    | awk '$1 == "pid" && $2 == "=" { print $3; exit }' \
    || true
}

function parse_host_process_start_identity() {
  /usr/bin/awk '
    function valid(value, weekday, month, day, hour, minute, second, year) {
      if (length(value) != 24) return 0
      weekday=substr(value, 1, 3); month=substr(value, 5, 3)
      day=substr(value, 9, 2); hour=substr(value, 12, 2)
      minute=substr(value, 15, 2); second=substr(value, 18, 2)
      year=substr(value, 21, 4)
      if (substr(value, 4, 1) != " " || substr(value, 8, 1) != " " ||
          substr(value, 11, 1) != " " || substr(value, 14, 1) != ":" ||
          substr(value, 17, 1) != ":" || substr(value, 20, 1) != " ") return 0
      if (weekday !~ /^(Sun|Mon|Tue|Wed|Thu|Fri|Sat)$/ ||
          month !~ /^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)$/) return 0
      if (day !~ /^( [1-9]|[12][0-9]|3[01])$/) return 0
      if (hour !~ /^[0-9][0-9]$/ || hour + 0 > 23 ||
          minute !~ /^[0-9][0-9]$/ || minute + 0 > 59 ||
          second !~ /^[0-9][0-9]$/ || second + 0 > 60 ||
          year !~ /^[0-9][0-9][0-9][0-9]$/) return 0
      return 1
    }
    {
      value=$0
      sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value)
      if (value == "") next
      records += 1
      if (!valid(value)) malformed=1
      parsed=value
    }
    END {
      if (records != 1 || malformed) exit 65
      print parsed
    }
  '
}

function capture_host_generation_log_checkpoint() {
  local metadata
  local revalidated
  local -a fields

  [[ -f "${HOST_LOG}" && ! -L "${HOST_LOG}" ]] || return 1
  metadata=$(/usr/bin/stat -f '%u|%l|%Lp|%HT|%d|%i|%z' "${HOST_LOG}") \
    || return $?
  fields=("${(@s:|:)metadata}")
  (( ${#fields[@]} == 7 )) || return 1
  [[ "${fields[1]}" == "$(/usr/bin/id -u)" \
      && "${fields[2]}" == 1 \
      && "${fields[3]}" == 600 \
      && "${fields[4]}" == "Regular File" \
      && "${fields[5]}" != *[^0-9]* \
      && "${fields[6]}" != *[^0-9]* \
      && "${fields[7]}" != *[^0-9]* ]] || return 1
  HOST_GENERATION_LOG_DEVICE=${fields[5]}
  HOST_GENERATION_LOG_INODE=${fields[6]}
  HOST_GENERATION_LOG_OFFSET=${fields[7]}
  revalidated=$(/usr/bin/stat -f '%d|%i|%z' "${HOST_LOG}") || return $?
  fields=("${(@s:|:)revalidated}")
  (( ${#fields[@]} == 3 )) || return 1
  [[ "${fields[1]}" == "${HOST_GENERATION_LOG_DEVICE}" \
      && "${fields[2]}" == "${HOST_GENERATION_LOG_INODE}" \
      && "${fields[3]}" != *[^0-9]* ]] || return 1
  (( fields[3] >= HOST_GENERATION_LOG_OFFSET ))
}

function capture_host_launch_identity() {
  local launch_state="${ARTIFACT_DIR}/.host-launch-state.$$"
  local manifest
  local captured_pid
  local captured_runs

  /bin/rm -f "${launch_state}" || return $?
  if /bin/launchctl print "${HOST_SERVICE}" > "${launch_state}" 2>/dev/null; then
    :
  else
    local launch_status=$?
    /bin/rm -f "${launch_state}"
    return "${launch_status}"
  fi
  manifest=$(
    "${MAC_HOST_LAUNCH_STATE_VERIFIER}" \
      "${launch_state}" \
      "${HOST_EXECUTABLE}" \
      "${HOST_REVIEWED_LAUNCH_AGENT}" \
      "${HOST_INSTALLED_LAUNCH_AGENT}"
  ) || {
    local manifest_status=$?
    /bin/rm -f "${launch_state}"
    return "${manifest_status}"
  }
  /bin/rm -f "${launch_state}" || return $?
  captured_pid=$(print -r -- "${manifest}" | /usr/bin/awk -F= '
    $1 == "pid" { count += 1; value=$2 }
    END { if (count != 1 || value !~ /^[1-9][0-9]*$/) exit 65; print value }
  ') || return $?
  captured_runs=$(print -r -- "${manifest}" | /usr/bin/awk -F= '
    $1 == "runs" { count += 1; value=$2 }
    END { if (count != 1 || value !~ /^[1-9][0-9]*$/) exit 65; print value }
  ') || return $?
  OPENSTEAMER_CAPTURED_HOST_PID=${captured_pid}
  OPENSTEAMER_CAPTURED_HOST_RUNS=${captured_runs}
}

function capture_host_generation_record() {
  local expected_host_pid=$1
  local directory_metadata
  local lock_metadata
  local lock_metadata_after
  local record
  local prefix
  local nonce
  local probe_output
  local -a fields

  [[ -d "${HOST_LOCK_DIRECTORY}" && ! -L "${HOST_LOCK_DIRECTORY}" ]] || return 1
  directory_metadata=$(
    /usr/bin/stat -f '%u|%Lp|%HT' "${HOST_LOCK_DIRECTORY}"
  ) || return $?
  [[ "${directory_metadata}" == "$(/usr/bin/id -u)|700|Directory" ]] || return 1
  [[ -f "${HOST_LOCK_FILE}" && ! -L "${HOST_LOCK_FILE}" ]] || return 1
  lock_metadata=$(
    /usr/bin/stat -f '%u|%l|%Lp|%HT|%d|%i|%z' "${HOST_LOCK_FILE}"
  ) || return $?
  fields=("${(@s:|:)lock_metadata}")
  (( ${#fields[@]} == 7 )) || return 1
  [[ "${fields[1]}" == "$(/usr/bin/id -u)" \
      && "${fields[2]}" == 1 \
      && "${fields[3]}" == 600 \
      && "${fields[4]}" == "Regular File" \
      && "${fields[5]}" != *[^0-9]* \
      && "${fields[6]}" != *[^0-9]* \
      && "${fields[7]}" != *[^0-9]* ]] || return 1
  (( fields[7] <= 512 )) || return 1
  record=$(/bin/dd if="${HOST_LOCK_FILE}" bs=513 count=1 2>/dev/null) || return $?
  lock_metadata_after=$(
    /usr/bin/stat -f '%u|%l|%Lp|%HT|%d|%i|%z' "${HOST_LOCK_FILE}"
  ) || return $?
  [[ "${lock_metadata_after}" == "${lock_metadata}" ]] || return 1
  prefix=$'OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1\npid='"${expected_host_pid}"$'\nnonce='
  [[ "${record}" == "${prefix}"* ]] || return 1
  nonce=${record#"${prefix}"}
  [[ ${#nonce} == 64 \
      && "${nonce}" != *[^0-9a-f]* \
      && "${nonce}" != *$'\n'* \
      && "${nonce}" != *$'\r'* ]] || return 1
  validate_migration_controller_binary || return 1
  probe_output=$(
    "${OPENSTEAMER_MIGRATION_CONTROLLER_BINARY}" \
      --probe-lock \
      "${HOST_LOCK_DIRECTORY}" \
      "${HOST_LOCK_FILE}" \
      "${expected_host_pid}"
  ) || return $?
  [[ "${probe_output}" == "lock_holder=${expected_host_pid}" ]] || return 1
  [[ "$(/usr/bin/stat -f '%d|%i' "${HOST_LOCK_FILE}")" \
      == "${fields[5]}|${fields[6]}" ]] || return 1
  OPENSTEAMER_CAPTURED_HOST_NONCE=${nonce}
  OPENSTEAMER_CAPTURED_HOST_LOCK_DEVICE=${fields[5]}
  OPENSTEAMER_CAPTURED_HOST_LOCK_INODE=${fields[6]}
}

function persist_host_generation_snapshot() {
  local temporary="${HOST_GENERATION_STATE}.tmp.$$"

  {
    print -r -- "schema=opensteamer.host-generation.v1"
    print -r -- "log_offset=${HOST_GENERATION_LOG_OFFSET}"
    print -r -- "log_device=${HOST_GENERATION_LOG_DEVICE}"
    print -r -- "log_inode=${HOST_GENERATION_LOG_INODE}"
    print -r -- "pid=${HOST_GENERATION_PID}"
    print -r -- "runs=${HOST_GENERATION_RUNS}"
    print -r -- "process_start=${HOST_GENERATION_PROCESS_START}"
    print -r -- "nonce=${HOST_GENERATION_NONCE}"
    print -r -- "lock_device=${HOST_GENERATION_LOCK_DEVICE}"
    print -r -- "lock_inode=${HOST_GENERATION_LOCK_INODE}"
  } > "${temporary}" || return $?
  /bin/mv "${temporary}" "${HOST_GENERATION_STATE}"
}

function bind_host_generation_snapshot() {
  local expected_host_pid=$1
  local process_start
  local process_start_after

  [[ -n "${HOST_GENERATION_LOG_OFFSET}" \
      && -n "${HOST_GENERATION_LOG_DEVICE}" \
      && -n "${HOST_GENERATION_LOG_INODE}" ]] || return 1
  capture_host_launch_identity || return $?
  [[ "${OPENSTEAMER_CAPTURED_HOST_PID}" == "${expected_host_pid}" ]] || return 1
  process_start=$(
    LC_ALL=C /bin/ps -p "${expected_host_pid}" -o lstart= 2>/dev/null \
      | parse_host_process_start_identity
  ) || return $?
  capture_host_generation_record "${expected_host_pid}" || return $?
  process_start_after=$(
    LC_ALL=C /bin/ps -p "${expected_host_pid}" -o lstart= 2>/dev/null \
      | parse_host_process_start_identity
  ) || return $?
  [[ "${process_start_after}" == "${process_start}" \
      && "$(current_host_pid)" == "${expected_host_pid}" ]] || return 1

  HOST_GENERATION_PID=${expected_host_pid}
  HOST_GENERATION_RUNS=${OPENSTEAMER_CAPTURED_HOST_RUNS}
  HOST_GENERATION_PROCESS_START=${process_start}
  HOST_GENERATION_NONCE=${OPENSTEAMER_CAPTURED_HOST_NONCE}
  HOST_GENERATION_LOCK_DEVICE=${OPENSTEAMER_CAPTURED_HOST_LOCK_DEVICE}
  HOST_GENERATION_LOCK_INODE=${OPENSTEAMER_CAPTURED_HOST_LOCK_INODE}
  persist_host_generation_snapshot
}

function parse_host_generation_snapshot() {
  /usr/bin/awk -F= '
    NR == 1 { if ($0 != "schema=opensteamer.host-generation.v1") bad=1; next }
    NR == 2 { if ($0 !~ /^log_offset=[0-9]+$/) bad=1; else print substr($0, 12); next }
    NR == 3 { if ($0 !~ /^log_device=[0-9]+$/) bad=1; else print substr($0, 12); next }
    NR == 4 { if ($0 !~ /^log_inode=[0-9]+$/) bad=1; else print substr($0, 11); next }
    NR == 5 { if ($0 !~ /^pid=[1-9][0-9]*$/) bad=1; else print substr($0, 5); next }
    NR == 6 { if ($0 !~ /^runs=[1-9][0-9]*$/) bad=1; else print substr($0, 6); next }
    NR == 7 { if ($0 !~ /^process_start=/) bad=1; else print substr($0, 15); next }
    NR == 8 {
      value=substr($0, 7)
      if ($0 !~ /^nonce=/ || length(value) != 64 || value !~ /^[0-9a-f]+$/) bad=1
      else print value
      next
    }
    NR == 9 { if ($0 !~ /^lock_device=[0-9]+$/) bad=1; else print substr($0, 13); next }
    NR == 10 { if ($0 !~ /^lock_inode=[0-9]+$/) bad=1; else print substr($0, 12); next }
    NR > 10 { bad=1 }
    END { if (bad || NR != 10) exit 65 }
  '
}

function load_host_generation_snapshot() {
  local expected_host_pid=$1
  local parsed
  local normalized_start
  local -a values

  [[ -f "${HOST_GENERATION_STATE}" \
      && ! -L "${HOST_GENERATION_STATE}" \
      && "$(/usr/bin/stat -f '%u:%l:%Lp' "${HOST_GENERATION_STATE}" 2>/dev/null)" \
        == "$(/usr/bin/id -u):1:600" ]] || return 1
  parsed=$(parse_host_generation_snapshot < "${HOST_GENERATION_STATE}") || return $?
  values=("${(@f)parsed}")
  (( ${#values[@]} == 9 )) || return 1
  [[ "${values[4]}" == "${expected_host_pid}" ]] || return 1
  normalized_start=$(print -r -- "${values[6]}" \
    | parse_host_process_start_identity) || return $?
  [[ "${normalized_start}" == "${values[6]}" ]] || return 1
  HOST_GENERATION_LOG_OFFSET=${values[1]}
  HOST_GENERATION_LOG_DEVICE=${values[2]}
  HOST_GENERATION_LOG_INODE=${values[3]}
  HOST_GENERATION_PID=${values[4]}
  HOST_GENERATION_RUNS=${values[5]}
  HOST_GENERATION_PROCESS_START=${values[6]}
  HOST_GENERATION_NONCE=${values[7]}
  HOST_GENERATION_LOCK_DEVICE=${values[8]}
  HOST_GENERATION_LOCK_INODE=${values[9]}
}

# Bind every initial/replacement launchd PID to the same freshly staged code identity and one
# pre-start log checkpoint. A stable path alone is not proof: a live process can keep an old vnode
# mapped after the installed app at that path is atomically replaced.
function verify_host_deployment_snapshot() {
  local expected_host_pid=$1
  local phase=$2
  local verifier_timeout_seconds=${3:-}
  local verifier_result
  local -a verifier_command

  if [[ -n "${verifier_timeout_seconds}" ]] \
      && { [[ "${verifier_timeout_seconds}" == *[^0-9]* ]] \
        || (( verifier_timeout_seconds <= 0 )); }; then
    return 2
  fi

  /bin/rm -f "${HOST_DEPLOYMENT_RECHECK_STDOUT}" "${HOST_DEPLOYMENT_RECHECK_STDERR}"
  if ! load_host_generation_snapshot "${expected_host_pid}" \
      || [[ ! -d "${HOST_FRESH_STAGED_APP}" \
        || -L "${HOST_FRESH_STAGED_APP}" \
        || ! -f "${HOST_OFFLINE_LEGACY_REFERENCE}" \
        || -L "${HOST_OFFLINE_LEGACY_REFERENCE}" \
        || ! -f "${HOST_REVIEWED_LAUNCH_AGENT}" \
        || -L "${HOST_REVIEWED_LAUNCH_AGENT}" ]] \
      || ! validate_migration_controller_binary; then
    print -r -- "host generation inputs are incomplete or unsafe" \
      > "${HOST_DEPLOYMENT_RECHECK_STDERR}"
    verifier_result=1
  else
    verifier_command=(
      /usr/bin/env
      "OPENSTEAMER_EXPECTED_TEAM_ID=${EXPECTED_MAC_HOST_TEAM_ID}"
      "OPENSTEAMER_MIGRATION_CONTROLLER_BINARY=${OPENSTEAMER_MIGRATION_CONTROLLER_BINARY}"
      "${MAC_HOST_DEPLOYMENT_VERIFIER}"
      "${HOST_FRESH_STAGED_APP}" \
      "${HOST_OFFLINE_LEGACY_REFERENCE}" \
      "${HOST_REVIEWED_LAUNCH_AGENT}" \
      "${HOST_GENERATION_LOG_OFFSET}" \
      "${HOST_GENERATION_LOG_DEVICE}" \
      "${HOST_GENERATION_LOG_INODE}" \
      "${HOST_GENERATION_PID}" \
      "${HOST_GENERATION_RUNS}" \
      "${HOST_GENERATION_PROCESS_START}" \
      "${HOST_GENERATION_NONCE}" \
      "${HOST_GENERATION_LOCK_DEVICE}" \
      "${HOST_GENERATION_LOCK_INODE}"
    )
    if [[ -n "${verifier_timeout_seconds}" ]]; then
      if opensteamer_run_with_timeout \
          "${verifier_timeout_seconds}" \
          "${verifier_command[@]}" \
          > "${HOST_DEPLOYMENT_RECHECK_STDOUT}" \
          2> "${HOST_DEPLOYMENT_RECHECK_STDERR}"; then
        verifier_result=0
      else
        verifier_result=$?
      fi
    elif "${verifier_command[@]}" \
        > "${HOST_DEPLOYMENT_RECHECK_STDOUT}" \
        2> "${HOST_DEPLOYMENT_RECHECK_STDERR}"; then
      verifier_result=0
    else
      verifier_result=$?
    fi
  fi

  {
    print -r -- ""
    print -r -- "phase=${phase} expected_pid=${expected_host_pid}"
    cat "${HOST_DEPLOYMENT_RECHECK_STDOUT}" 2>/dev/null || true
  } >> "${HOST_DEPLOYMENT_MANIFEST}"
  {
    print -r -- ""
    print -r -- "phase=${phase} expected_pid=${expected_host_pid}"
    cat "${HOST_DEPLOYMENT_RECHECK_STDERR}" 2>/dev/null || true
  } >> "${HOST_DEPLOYMENT_STDERR}"
  /bin/rm -f "${HOST_DEPLOYMENT_RECHECK_STDOUT}" "${HOST_DEPLOYMENT_RECHECK_STDERR}"
  return "${verifier_result}"
}

function kickstart_host_service() {
  local queued_pid
  local next_pid
  local -a queued_pids

  if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == host-provenance-* \
      && -n "${OPENSTEAMER_SELF_TEST_HOST_PID_FILE:-}" \
      && -n "${OPENSTEAMER_SELF_TEST_HOST_PID_QUEUE:-}" ]]; then
    while IFS= read -r queued_pid; do
      [[ -n "${queued_pid}" ]] || continue
      queued_pids+=("${queued_pid}")
    done < "${OPENSTEAMER_SELF_TEST_HOST_PID_QUEUE}"
    (( ${#queued_pids[@]} > 0 )) || return 1
    next_pid=${queued_pids[1]}
    print -r -- "${next_pid}" \
      > "${OPENSTEAMER_SELF_TEST_HOST_PID_FILE}.tmp" || return $?
    /bin/mv \
      "${OPENSTEAMER_SELF_TEST_HOST_PID_FILE}.tmp" \
      "${OPENSTEAMER_SELF_TEST_HOST_PID_FILE}" || return $?
    print -rl -- "${queued_pids[@]:1}" \
      > "${OPENSTEAMER_SELF_TEST_HOST_PID_QUEUE}.tmp" || return $?
    /bin/mv \
      "${OPENSTEAMER_SELF_TEST_HOST_PID_QUEUE}.tmp" \
      "${OPENSTEAMER_SELF_TEST_HOST_PID_QUEUE}" || return $?
    print -r -- "kickstart=${next_pid}" \
      >> "${OPENSTEAMER_SELF_TEST_KICKSTART_EVENTS}" || return $?
    return
  fi
  require_exact_safe_host_mutation_identity || return 2
  opensteamer_run_with_timeout 5 launchctl kickstart -k "${HOST_SERVICE}"
}

function wait_for_replacement_host_pid() {
  local previous_pid=$1
  local wait_started=${SECONDS}
  local replacement_pid

  while (( SECONDS - wait_started < 30 )); do
    replacement_pid=$(current_host_pid)
    if [[ -n "${replacement_pid}" \
        && "${replacement_pid}" != "${previous_pid}" \
        && "${replacement_pid}" != *[^0-9]* ]] \
        && (( replacement_pid > 0 )); then
      print -r -- "${replacement_pid}"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

function wait_before_host_restart() {
  if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == host-provenance-* ]]; then
    sleep 0.15
  else
    sleep "${HOST_RESTART_DELAY_SECONDS}"
  fi
}

function write_host_status() {
  # `status` is a read-only special parameter in zsh. Keep this name ordinary so the
  # physical gate can actually publish its independent host-churn evidence.
  local gate_state=$1
  local connections=$2
  local restarts=$3
  local detail=$4
  local temporary_status="${HOST_STATUS}.tmp"

  {
    print -r -- "status=${gate_state}"
    print -r -- "connections=${connections}"
    print -r -- "restarts=${restarts}"
    print -r -- "detail=${detail}"
  } > "${temporary_status}"
  mv "${temporary_status}" "${HOST_STATUS}"
}

function acquire_host_churn_lock() {
  local lock_poll
  for lock_poll in {1..250}; do
    if mkdir "${HOST_CHURN_LOCK}" 2>/dev/null; then
      return 0
    fi
    sleep 0.02
  done
  return 1
}

function release_host_churn_lock() {
  rmdir "${HOST_CHURN_LOCK}" 2>/dev/null || true
}

function request_final_host_log_audit() {
  if [[ -f "${HOST_CHURN_STOP_MARKER}" ]]; then
    return 1
  fi
  if ! acquire_host_churn_lock; then
    return 1
  fi
  if [[ -f "${HOST_CHURN_STOP_MARKER}" ]] \
      || ! opensteamer_write_state \
        "${HOST_CHURN_STOP_MARKER}" "state=xcodebuild-ended"; then
    release_host_churn_lock
    return 1
  fi
  release_host_churn_lock
}

function start_host_churn_worker() {
  local variable_name
  local variable_value
  local function_name
  local worker_source
  local worker_status
  local -a worker_variables=(
    ARTIFACT_DIR
    SAFE_HOST_LAUNCH_AGENT_LABEL
    PROTECTED_HOST_LAUNCH_AGENT_LABEL
    SAFE_HOST_SERVICE
    SAFE_HOST_LOG
    SAFE_HOST_REVIEWED_LAUNCH_AGENT
    SAFE_HOST_INSTALLED_LAUNCH_AGENT
    SAFE_HOST_EXECUTABLE
    HOST_LABEL
    HOST_LOG
    HOST_SERVICE
    HOST_STATUS
    HOST_EVENTS
    HOST_CHURN_STOP_MARKER
    HOST_CHURN_LOCK
    HOST_LOG_APPEND_CHUNK
    HOST_LOG_COMPLETED_LINES
    HOST_LOG_PARTIAL_LINE
    HOST_LOG_START_ID
    HOST_LOG_START_OFFSET
    HOST_LOG_START_DIGEST
    EXPECTED_INITIAL_HOST_PID
    XCODEBUILD_PID
    UI_TEST_TIMEOUT_SECONDS
    HOST_CONNECTION_WAIT_TIMEOUT_SECONDS
    HOST_RESTART_DELAY_SECONDS
    EXPECTED_MAC_HOST_TEAM_ID
    MAC_HOST_DEPLOYMENT_VERIFIER
    MAC_HOST_LAUNCH_STATE_VERIFIER
    HOST_FRESH_STAGED_APP
    HOST_OFFLINE_LEGACY_REFERENCE
    HOST_REVIEWED_LAUNCH_AGENT
    HOST_INSTALLED_LAUNCH_AGENT
    HOST_EXECUTABLE
    HOST_LOCK_DIRECTORY
    HOST_LOCK_FILE
    HOST_GENERATION_STATE
    HOST_GENERATION_LOG_OFFSET
    HOST_GENERATION_LOG_DEVICE
    HOST_GENERATION_LOG_INODE
    HOST_GENERATION_PID
    HOST_GENERATION_RUNS
    HOST_GENERATION_PROCESS_START
    HOST_GENERATION_NONCE
    HOST_GENERATION_LOCK_DEVICE
    HOST_GENERATION_LOCK_INODE
    MIGRATION_CONTROLLER_BINARY_SHA256
    OPENSTEAMER_MIGRATION_CONTROLLER_BINARY
    HOST_DEPLOYMENT_RECHECK_STDOUT
    HOST_DEPLOYMENT_RECHECK_STDERR
    HOST_DEPLOYMENT_MANIFEST
    HOST_DEPLOYMENT_STDERR
    OPENSTEAMER_SCRIPT_SELF_TEST
    OPENSTEAMER_SELF_TEST_HOST_PID_FILE
    OPENSTEAMER_SELF_TEST_HOST_PID_QUEUE
    OPENSTEAMER_SELF_TEST_KICKSTART_EVENTS
    OPENSTEAMER_SELF_TEST_PRE_KICK_READY
    OPENSTEAMER_SELF_TEST_AUDIT_ONLY_READY
    OPENSTEAMER_SELF_TEST_AUDIT_ONLY_PROCEED
  )
  local -a worker_functions=(
    current_host_pid
    parse_host_process_start_identity
    capture_host_generation_log_checkpoint
    capture_host_launch_identity
    capture_host_generation_record
    persist_host_generation_snapshot
    bind_host_generation_snapshot
    parse_host_generation_snapshot
    load_host_generation_snapshot
    validate_migration_controller_binary
    verify_host_deployment_snapshot
    require_exact_safe_host_mutation_identity
    kickstart_host_service
    wait_before_host_restart
    write_host_status
    acquire_host_churn_lock
    release_host_churn_lock
    audit_new_host_log_records
    record_audited_host_connections
    churn_host_after_live_connections
  )

  worker_source=$(
    {
      print -r -- '#!/bin/zsh'
      print -r -- 'set -u'
      printf 'source %q\n' "${SCRIPT_DIR}/physical-validation-helpers.zsh"
      for variable_name in "${worker_variables[@]}"; do
        if (( ${+parameters[$variable_name]} )); then
          variable_value=${(P)variable_name}
        else
          variable_value=""
        fi
        printf '%s=%q\n' "${variable_name}" "${variable_value}"
      done
      for function_name in "${worker_functions[@]}"; do
        functions "${function_name}"
      done
      print -r -- 'churn_host_after_live_connections'
    }
  ) || return $?

  opensteamer_exec_in_isolated_process_group \
    /bin/zsh -c "${worker_source}" host-churn-worker &
  HOST_WATCHER_PID=$!
  if opensteamer_require_isolated_process_group "${HOST_WATCHER_PID}" 5; then
    return 0
  else
    worker_status=$?
  fi
  cleanup_host_watcher || true
  return "${worker_status}"
}

function capture_and_require_unchanged_candidate() {
  local device_output=$1
  local app_list_output=$2
  local candidate_output=$3
  local phase_name=$4

  if [[ "${OPENSTEAMER_SELF_TEST_CRITICAL_FAILURE:-}" == "unchanged-candidate" ]]; then
    return 45
  fi
  capture_and_validate_device "${device_output}" || return $?
  capture_production_candidate "${app_list_output}" "${candidate_output}" || return $?
  if ! cmp -s "${CANDIDATE_BEFORE}" "${candidate_output}"; then
    echo "Production candidate changed during ${phase_name}." >&2
    diff -u "${CANDIDATE_BEFORE}" "${candidate_output}" >&2 || true
    return 2
  fi
}

function compile_blackhole_probe() {
  rm -f \
    "${RAW_BLACKHOLE_PROBE_BINARY}" \
    "${RAW_BLACKHOLE_PROBE_RESULT}" \
    "${RAW_BLACKHOLE_PROBE_COMPILE_STDOUT}" \
    "${RAW_BLACKHOLE_PROBE_COMPILE_STDERR}" \
    "${RAW_BLACKHOLE_PROBE_CLEANUP_PROOF}" || return $?
  if ! TMPDIR="${XCODE_TEMP_DIR}" xcrun --sdk macosx swiftc \
      "${RAW_BLACKHOLE_PROBE_SOURCE}" \
      -o "${RAW_BLACKHOLE_PROBE_BINARY}" \
      -framework AudioToolbox \
      -framework CoreAudio \
      > "${RAW_BLACKHOLE_PROBE_COMPILE_STDOUT}" \
      2> "${RAW_BLACKHOLE_PROBE_COMPILE_STDERR}"; then
    echo "The physical BlackHole microphone probe did not compile." >&2
    return 3
  fi
}

function capture_default_input_snapshot() {
  local output=$1
  local role=$2
  local timeout_seconds=${3:-}

  rm -f "${output}" || return $?
  if [[ -n "${OPENSTEAMER_SELF_TEST_RAW_READINESS:-}" ]]; then
    local observed
    local input_hash
    local is_blackhole=false
    local input_transport_class=built-in
    local selection_mode=${OPENSTEAMER_SELF_TEST_DEFAULT_INPUT_MODE:-switched}
    observed=$(current_monotonic_time_ns) || return $?
    if [[ "${selection_mode}" == "preselected" ]]; then
      case "${role}" in
        before|healthy|after)
          input_hash=$(printf 'b%.0s' {1..64})
          is_blackhole=true
          input_transport_class=virtual
          ;;
        *)
          return 3
          ;;
      esac
    else
      case "${role}" in
        before|after)
        input_hash=$(printf 'a%.0s' {1..64})
          ;;
        healthy)
          input_hash=$(printf 'b%.0s' {1..64})
          is_blackhole=true
          input_transport_class=virtual
          ;;
        *)
          return 3
          ;;
      esac
    fi
    cat > "${output}" <<EOF
{
  "defaultOutputIsForbiddenBlackHole": false,
  "defaultSystemOutputIsForbiddenBlackHole": false,
  "inputIsCanonicalBlackHole": ${is_blackhole},
  "inputIsHiddenMirrorBlackHole": false,
  "inputTransportClass": "${input_transport_class}",
  "inputUIDFingerprint": "${input_hash}",
  "observedAtMonotonicNs": ${observed},
  "outputUIDFingerprint": "$(printf 'c%.0s' {1..64})",
  "role": "${role}",
  "schema": "opensteamer.default-input-snapshot.v3",
  "systemOutputUIDFingerprint": "$(printf 'd%.0s' {1..64})"
}
EOF
    return $?
  fi

  if [[ -n "${timeout_seconds}" ]]; then
    opensteamer_require_positive_integer \
      snapshot-timeout-seconds "${timeout_seconds}" || return $?
    opensteamer_run_with_timeout \
      "${timeout_seconds}" \
      "${RAW_BLACKHOLE_PROBE_BINARY}" \
      snapshot-default-uids \
      --role "${role}" \
      --result "${output}"
  else
    "${RAW_BLACKHOLE_PROBE_BINARY}" \
      snapshot-default-uids \
      --role "${role}" \
      --result "${output}"
  fi
}

function validate_default_input_lifecycle_json() {
  local before=$1
  local healthy=$2
  local after=$3
  local probe_start=$4
  local during=${5:-}
  local probe_end=${6:-0}
  local evidence_output=${7:-}
  local -a snapshots=("${before}" "${healthy}")
  local selection_mode
  local transition_exercised
  local temporary

  if [[ -n "${during}" ]]; then
    snapshots+=("${during}")
  fi
  snapshots+=("${after}")

  jq -e -s \
    --argjson probe_start "${probe_start}" \
    --argjson probe_end "${probe_end}" '
    def exact_keys:
      keys == ([
        "defaultOutputIsForbiddenBlackHole",
        "defaultSystemOutputIsForbiddenBlackHole",
        "inputIsCanonicalBlackHole",
        "inputIsHiddenMirrorBlackHole",
        "inputTransportClass",
        "inputUIDFingerprint",
        "observedAtMonotonicNs",
        "outputUIDFingerprint",
        "role",
        "schema",
        "systemOutputUIDFingerprint"
      ] | sort);
    def fingerprint:
      type == "string"
      and test("^[0-9a-f]{64}$");
    . as $snapshots
    | (length == 3 or length == 4)
    and (all(.[]; exact_keys))
    and (all(.[]; .schema == "opensteamer.default-input-snapshot.v3"))
    and (all(.[];
      (.inputUIDFingerprint | fingerprint)
      and (.outputUIDFingerprint | fingerprint)
      and (.systemOutputUIDFingerprint | fingerprint)
      and .inputIsHiddenMirrorBlackHole == false
      and .defaultOutputIsForbiddenBlackHole == false
      and .defaultSystemOutputIsForbiddenBlackHole == false
      and (.inputTransportClass
        | IN("built-in", "virtual", "aggregate", "usb", "bluetooth", "other"))
      and (.observedAtMonotonicNs | type == "number" and . > 0 and floor == .)
    ))
    and .[0].role == "before"
    and .[1].role == "healthy"
    and .[-1].role == "after"
    and .[1].inputIsCanonicalBlackHole == true
    and .[1].inputTransportClass == "virtual"
    and .[0].observedAtMonotonicNs < .[1].observedAtMonotonicNs
    and .[1].observedAtMonotonicNs < $probe_start
    and $probe_start < .[-1].observedAtMonotonicNs
    and (if .[0].inputIsCanonicalBlackHole then
      (all(.[]; .inputIsCanonicalBlackHole == true))
      and (all(.[]; .inputTransportClass == "virtual"))
      and (all(.[]; .inputUIDFingerprint == $snapshots[0].inputUIDFingerprint))
    else
      .[-1].inputIsCanonicalBlackHole == false
      and .[0].inputUIDFingerprint == .[-1].inputUIDFingerprint
      and .[0].inputTransportClass == .[-1].inputTransportClass
      and .[0].inputUIDFingerprint != .[1].inputUIDFingerprint
    end)
    and (all(.[]; .outputUIDFingerprint == $snapshots[0].outputUIDFingerprint))
    and (all(.[]; .systemOutputUIDFingerprint == $snapshots[0].systemOutputUIDFingerprint))
    and (if length == 4 then
      .[2].role == "healthy"
      and .[2].inputIsCanonicalBlackHole == true
      and .[2].inputUIDFingerprint == .[1].inputUIDFingerprint
      and $probe_start < .[2].observedAtMonotonicNs
      and .[2].observedAtMonotonicNs < $probe_end
      and $probe_start < $probe_end
      and .[2].observedAtMonotonicNs < .[3].observedAtMonotonicNs
    else true end)
  ' "${snapshots[@]}" >/dev/null || return $?

  if jq -e '.inputIsCanonicalBlackHole == true' \
      "${before}" >/dev/null; then
    selection_mode=preselected
    transition_exercised=0
  else
    selection_mode=switched
    transition_exercised=1
  fi
  if [[ -n "${evidence_output}" ]]; then
    temporary="${evidence_output}.tmp.$$"
    {
      print -r -- "schema=opensteamer.default-input-lifecycle.v1"
      print -r -- "selectionMode=${selection_mode}"
      print -r -- "transitionExercised=${transition_exercised}"
      print -r -- "restorationExercised=${transition_exercised}"
    } > "${temporary}" || return $?
    mv "${temporary}" "${evidence_output}"
  fi
}

function validate_default_input_baseline_json() {
  local snapshot=$1

  jq -e '
    .schema == "opensteamer.default-input-snapshot.v3"
    and (.inputIsCanonicalBlackHole | type == "boolean")
    and .inputIsHiddenMirrorBlackHole == false
    and .defaultOutputIsForbiddenBlackHole == false
    and .defaultSystemOutputIsForbiddenBlackHole == false
    and (.inputTransportClass
      | IN("built-in", "virtual", "aggregate", "usb", "bluetooth", "other"))
    and (if .inputIsCanonicalBlackHole then
      .inputTransportClass == "virtual"
    else true end)
  ' "${snapshot}" >/dev/null
}

function wait_for_default_input_restoration() {
  local started=${SECONDS}

  while (( SECONDS - started < 5 )); do
    capture_default_input_snapshot \
      "${RAW_DEFAULT_INPUT_AFTER}" after || return $?
    if jq -e \
        --slurpfile before "${RAW_DEFAULT_INPUT_BEFORE}" '
        .schema == "opensteamer.default-input-snapshot.v3"
        and .inputIsCanonicalBlackHole
          == $before[0].inputIsCanonicalBlackHole
        and .inputUIDFingerprint
          == $before[0].inputUIDFingerprint
        and .inputTransportClass
          == $before[0].inputTransportClass
      ' "${RAW_DEFAULT_INPUT_AFTER}" >/dev/null; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

function start_bounded_blackhole_probe_process() {
  local group_status
  local write_status

  rm -f \
    "${RAW_BLACKHOLE_PROBE_DIAGNOSTICS}" \
    "${RAW_BLACKHOLE_PROBE_COMPLETION}" || return $?
  opensteamer_exec_in_isolated_process_group \
    /bin/zsh -c 'kill -STOP $$; exec "$@"' \
    blackhole-probe-supervisor \
    "${OPENSTEAMER_PHYSICAL_VALIDATION_ORACLE}" \
    probe-supervise \
    "${RAW_BLACKHOLE_PROBE_DIAGNOSTICS}" \
    "${RAW_BLACKHOLE_PROBE_COMPLETION}" \
    "${PHYSICAL_OUTPUT_UID}" \
    "65536" \
    "${RAW_READY_NONCE:-unbound}" \
    "${RAW_PROBE_STARTED_NS:-0}" \
    "${RAW_PROBE_BOUND_PID:-0}" \
    "${OPENSTEAMER_SELF_TEST_RAW_REPORTED_STATUS:--}" \
    "${OPENSTEAMER_SELF_TEST_RAW_COMPLETION_MODE:-normal}" \
    "${OPENSTEAMER_SELF_TEST_RAW_PROBE_END_OFFSET_NS:--}" \
    -- \
    "$@" &
  BLACKHOLE_PROBE_PID=$!
  BLACKHOLE_PROBE_STARTED_SECONDS=${SECONDS}
  BLACKHOLE_PROBE_STARTED_MONOTONIC_NS=$(current_monotonic_time_ns) || {
    write_status=$?
    cleanup_blackhole_probe || true
    return "${write_status}"
  }
  [[ "${BLACKHOLE_PROBE_STARTED_MONOTONIC_NS}" != *[^0-9]* \
      && BLACKHOLE_PROBE_STARTED_MONOTONIC_NS -gt 0 ]] || {
    cleanup_blackhole_probe || true
    return 3
  }
  print -r -- "${BLACKHOLE_PROBE_PID}" \
    > "${ARTIFACT_DIR}/blackhole-probe-leader-pid.txt" || {
      write_status=$?
      cleanup_blackhole_probe || true
      return "${write_status}"
    }
  run_command_capturing_status \
    opensteamer_require_isolated_process_group "${BLACKHOLE_PROBE_PID}" 5
  group_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( group_status != 0 )); then
    cleanup_blackhole_probe || true
    return "${group_status}"
  fi
  run_command_capturing_status \
    opensteamer_wait_for_stopped_process_group "${BLACKHOLE_PROBE_PID}" 5
  group_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( group_status != 0 )); then
    cleanup_blackhole_probe || true
    return "${group_status}"
  fi
  if ! opensteamer_resume_process_group "${BLACKHOLE_PROBE_PID}"; then
    group_status=$?
    cleanup_blackhole_probe || true
    return "${group_status}"
  fi
}

function fresh_blackhole_probe_nonce() {
  print -r -- \
    "raw-$(
      /usr/bin/uuidgen \
        | tr '[:upper:]' '[:lower:]'
    )"
}

function start_blackhole_probe() {
  local probe_status

  [[ -n "${RAW_READY_NONCE}" \
      && "${RAW_READY_NONCE}" != *[^A-Za-z0-9-]* ]] || return 3
  BLACKHOLE_PROBE_NONCE="${RAW_READY_NONCE}"
  if [[ -n "${OPENSTEAMER_SELF_TEST_RAW_READINESS:-}" ]]; then
    run_command_capturing_status \
      start_bounded_blackhole_probe_process \
      /bin/zsh -c 'sleep "$1"; exit "$2"' \
      raw-readiness-probe \
      "${OPENSTEAMER_SELF_TEST_RAW_PROBE_DURATION:-0.4}" \
      "${OPENSTEAMER_SELF_TEST_RAW_PROBE_STATUS:-0}"
  else
    run_command_capturing_status \
      start_bounded_blackhole_probe_process \
      "${RAW_BLACKHOLE_PROBE_BINARY}" \
      run \
      --nonce "${BLACKHOLE_PROBE_NONCE}" \
      --physical-output-uid "${PHYSICAL_OUTPUT_UID}" \
      --result "${RAW_BLACKHOLE_PROBE_RESULT}" \
      --timeout-seconds "${BLACKHOLE_PROBE_TIMEOUT_SECONDS}"
  fi
  probe_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( probe_status != 0 )); then
    echo "The physical BlackHole microphone probe did not enter an isolated process group." >&2
    return "${probe_status}"
  fi
  return 0
}

function start_isolated_validation_process_capturing_output() {
  local standard_output=$1
  local standard_error=$2
  shift 2

  : > "${standard_output}" || return $?
  : > "${standard_error}" || return $?
  opensteamer_start_isolated_validation_process "$@" \
    > "${standard_output}" 2> "${standard_error}"
}

function capture_raw_ui_completion_observation_from_log() {
  local live_output=$1
  local completion_line="OPENSTEAMER_RAW_UI_CONTINUITY_COMPLETE_V1 nonce=${RAW_READY_NONCE}"
  local teardown_line="OPENSTEAMER_RAW_UI_TEARDOWN_BEGIN_V1 nonce=${RAW_READY_NONCE}"
  local observed_at_ns
  local temporary="${RAW_UI_COMPLETION_OBSERVATION}.tmp.$$"

  [[ -s "${live_output}" ]] || return 1
  # The ten-second XCTest handshake grace is useful only if the Mac sees completion before the
  # test announces teardown. Seeing both in one poll is ambiguous and therefore fails closed.
  /usr/bin/grep -Fxq "${teardown_line}" "${live_output}" && return 9
  [[ "$(/usr/bin/grep -Fxc "${completion_line}" "${live_output}")" == "1" ]] \
    || return 1
  observed_at_ns=$(current_monotonic_time_ns) || return $?
  [[ -n "${observed_at_ns}" && "${observed_at_ns}" != *[^0-9]* ]] || return 3
  {
    print -r -- "schema=opensteamer.raw-ui-completion-observation.v1"
    print -r -- "nonce=${RAW_READY_NONCE}"
    print -r -- "observedAtMonotonicNs=${observed_at_ns}"
  } > "${temporary}" || return $?
  mv "${temporary}" "${RAW_UI_COMPLETION_OBSERVATION}"
}

function capture_call_ui_hosted_state_observation_from_log() {
  local live_output=$1
  local sequence=$2
  local acoustic_token=$3
  local lower_bound_ns=$4
  local output=$5
  local marker="OPENSTEAMER_CALL_UI_HOSTED_ACTIVE_V2 nonce=${RAW_READY_NONCE} sequence=${sequence} acousticToken=${acoustic_token}"
  local marker_count
  local observed_at_ns
  local acknowledgement_accepted_ns=0
  local temporary="${output}.tmp.$$"

  [[ -n "${output}" && -s "${live_output}" \
      && ( "${sequence}" == "1" || "${sequence}" == "2" ) \
      && -n "${lower_bound_ns}" \
      && "${lower_bound_ns}" != *[^0-9]* \
      && -n "${RAW_READY_RESUMED_NS}" \
      && "${RAW_READY_RESUMED_NS}" != *[^0-9]* ]] || return 1
  if [[ "${sequence}" == "1" ]]; then
    [[ "${acoustic_token}" == "-" \
        && "${lower_bound_ns}" == "${RAW_READY_RESUMED_NS}" ]] || return 3
  else
    [[ -n "${acoustic_token}" \
        && "${acoustic_token}" != *[^A-Za-z0-9-]* \
        && "${acoustic_token}" == "${CALL_ACOUSTIC_ACCEPTED_TOKEN}" \
        && -n "${CALL_ACOUSTIC_ACCEPTED_NS}" \
        && "${CALL_ACOUSTIC_ACCEPTED_NS}" != *[^0-9]* \
        && "${lower_bound_ns}" == "${CALL_ACOUSTIC_ACCEPTED_NS}" ]] || return 3
    acknowledgement_accepted_ns=${CALL_ACOUSTIC_ACCEPTED_NS}
  fi
  marker_count=$(/usr/bin/grep -Fxc "${marker}" "${live_output}" 2>/dev/null) \
    || marker_count=0
  (( marker_count == 0 )) && return 1
  (( marker_count == 1 )) || return 9
  observed_at_ns=$(current_monotonic_time_ns) || return $?
  [[ -n "${observed_at_ns}" && "${observed_at_ns}" != *[^0-9]* \
      ]] || return 3
  (( observed_at_ns > lower_bound_ns )) || return 9
  {
    print -r -- "schema=opensteamer.call-ui-hosted-state-observation.v2"
    print -r -- "nonce=${RAW_READY_NONCE}"
    print -r -- "state=hosted-call-active"
    print -r -- "sequence=${sequence}"
    print -r -- "acousticToken=${acoustic_token}"
    print -r -- "resumedAtMonotonicNs=${RAW_READY_RESUMED_NS}"
    print -r -- "acknowledgementAcceptedAtMonotonicNs=${acknowledgement_accepted_ns}"
    print -r -- "observedAtMonotonicNs=${observed_at_ns}"
  } > "${temporary}" || return $?
  mv "${temporary}" "${output}"
}

function wait_for_nonce_bound_call_ui_hosted_state() {
  local deadline_ns=$1
  local live_output=$2
  local sequence=$3
  local acoustic_token=$4
  local lower_bound_ns=$5
  local output=$6
  local capture_status

  [[ -n "${output}" ]] || return 3
  rm -f "${output}" || return $?
  while acknowledgement_remaining_seconds "${deadline_ns}" >/dev/null; do
    if [[ -z "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" ]] \
        && { [[ -z "${XCODEBUILD_PID}" ]] \
          || ! opensteamer_process_group_exists "${XCODEBUILD_PID}"; }; then
      return 9
    fi
    if capture_call_ui_hosted_state_observation_from_log \
        "${live_output}" \
        "${sequence}" \
        "${acoustic_token}" \
        "${lower_bound_ns}" \
        "${output}"; then
      if acknowledgement_remaining_seconds "${deadline_ns}" >/dev/null; then
        return 0
      fi
      rm -f "${output}" || true
      break
    else
      capture_status=$?
      (( capture_status == 1 )) || return "${capture_status}"
    fi
    sleep 0.05
  done
  rm -f "${output}" || true
  return 1
}

function run_simple_physical_ui_test() {
  local test_name=$1
  local result_bundle=$2
  local derived_data=$3
  local timeout_marker=$4
  local locked_marker=$5
  local unavailable_marker=$6
  local watchdog_state=$7
  local watchdog_failure_marker=$8
  local lock_state_during_test=$9
  local tone_failure_marker=${10}
  local stable_host_failure_marker=${11}
  local expected_host_pid=${12}
  local xcodebuild_action=${13:-test}
  local after_start_hook=${14:-}
  local preserve_derived_data=${15:-0}
  local overlap_completion_marker=${16:-}
  local before_start_hook=${17:-}
  local xcodebuild_status
  local watchdog_status
  local expected_watchdog_state
  local isolation_status=0
  local hook_status=0
  local hook_cleanup_status=0
  local xcodebuild_group_pid
  local xcodebuild_live_stdout="${result_bundle}.live-stdout.txt"
  local xcodebuild_live_stderr="${result_bundle}.live-stderr.txt"

  if [[ -n "${overlap_completion_marker}" ]]; then
    prepare_raw_overlap_contract || return $?
  fi

  if [[ "${preserve_derived_data}" == "1" ]]; then
    rm -rf "${result_bundle}" || return $?
  else
    rm -rf "${derived_data}" "${result_bundle}" || return $?
  fi
  rm -f \
    "${timeout_marker}" \
    "${locked_marker}" \
    "${unavailable_marker}" \
    "${watchdog_state}" \
    "${watchdog_failure_marker}" \
    "${overlap_completion_marker}" \
    "${RAW_PROBE_NON_OVERLAP_MARKER}" || return $?
  if [[ -n "${tone_failure_marker}" ]]; then
    rm -f "${tone_failure_marker}" || return $?
  fi
  if [[ -n "${stable_host_failure_marker}" ]]; then
    rm -f "${stable_host_failure_marker}" || return $?
  fi

  if [[ -n "${before_start_hook}" ]]; then
    run_command_capturing_status "${before_start_hook}"
    hook_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
    (( hook_status == 0 )) || return "${hook_status}"
  fi

  XCODEBUILD_LIVE_STDOUT=${xcodebuild_live_stdout}
  if [[ -n "${OPENSTEAMER_SELF_TEST_ISOLATION_FAILURE_STATUS:-}" ]]; then
    isolation_status=${OPENSTEAMER_SELF_TEST_ISOLATION_FAILURE_STATUS}
  elif [[ -n "${OPENSTEAMER_SELF_TEST_SIMPLE_UI_DURATION:-}" ]]; then
    run_command_capturing_status \
      opensteamer_start_isolated_validation_process \
      /bin/zsh -c 'sleep "$1"; exit "$2"' \
      simple-ui-self-test \
      "${OPENSTEAMER_SELF_TEST_SIMPLE_UI_DURATION}" \
      "${OPENSTEAMER_SELF_TEST_SIMPLE_UI_STATUS:-0}"
    isolation_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  else
    run_command_capturing_status \
      start_isolated_validation_process_capturing_output \
      "${xcodebuild_live_stdout}" \
      "${xcodebuild_live_stderr}" \
      /usr/bin/env TMPDIR="${XCODE_TEMP_DIR}" \
      xcodebuild "${xcodebuild_action}" \
      -project "${PROJECT_DIR}/opensteamer.xcodeproj" \
      -scheme opensteamerUITests \
      -configuration Debug \
      -destination "platform=iOS,id=${HARDWARE_UDID}" \
      -derivedDataPath "${derived_data}" \
      -clonedSourcePackagesDirPath "${XCODE_SOURCE_PACKAGES}" \
      -parallel-testing-enabled NO \
      -maximum-parallel-testing-workers 1 \
      -test-timeouts-enabled YES \
      -default-test-execution-time-allowance 600 \
      -maximum-test-execution-time-allowance 720 \
      "-only-testing:opensteamerUITests/PairedReconnectPhysicalUITests/${test_name}" \
      -resultBundlePath "${result_bundle}"
    isolation_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  fi
  if (( isolation_status != 0 )); then
    XCODEBUILD_LIVE_STDOUT=""
    return "${isolation_status}"
  fi
  XCODEBUILD_GROUP_HANDLE=${XCODEBUILD_PID}
  (
    set -e
    opensteamer_write_state "${watchdog_state}" "state=monitoring"
    watchdog_started=${SECONDS}
    lock_poll_started=${SECONDS}
    lock_query_failures=0
    while kill -0 "${XCODEBUILD_PID}" 2>/dev/null; do
      if [[ -z "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" \
          && -n "${overlap_completion_marker}" \
          && ! -s "${RAW_UI_COMPLETION_OBSERVATION}" ]]; then
        if capture_raw_ui_completion_observation_from_log \
            "${xcodebuild_live_stdout}"; then
          :
        else
          completion_handshake_status=$?
          if (( completion_handshake_status != 1 )); then
            record_raw_overlap_failure \
              raw-ui-completion-handshake-rejected \
              "${completion_handshake_status}"
            print -r -- \
              "The nonce-bound raw UI completion handshake was rejected before teardown." \
              > "${watchdog_failure_marker}"
            opensteamer_terminate_isolated_process_group \
              "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
            opensteamer_write_state \
              "${watchdog_state}" "state=raw-ui-completion-failure-handled"
            exit 0
          fi
        fi
      fi
      if [[ -n "${overlap_completion_marker}" \
          && ! -f "${overlap_completion_marker}" \
          && -s "${RAW_BLACKHOLE_PROBE_COMPLETION}" ]]; then
        if capture_raw_probe_completion_observation; then
          :
        else
          completion_status=$?
          record_raw_overlap_failure \
            probe-completion-observation-rejected "${completion_status}"
          print -r -- "The nonce-bound probe completion observation was rejected." \
            > "${watchdog_failure_marker}"
          opensteamer_terminate_isolated_process_group \
            "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
          opensteamer_write_state \
            "${watchdog_state}" "state=probe-completion-failure-handled"
          exit 0
        fi
      fi
      if [[ -n "${tone_failure_marker}" ]] \
          && { [[ -z "${AUDIO_ORACLE_TONE_PID}" ]] \
            || ! opensteamer_process_group_exists "${AUDIO_ORACLE_TONE_PID}"; }; then
        print -r -- \
          "The deterministic Mac audio oracle tone stopped during physical validation." \
          > "${tone_failure_marker}"
        opensteamer_terminate_isolated_process_group \
          "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
        opensteamer_write_state \
          "${watchdog_state}" "state=audio-oracle-failure-handled"
        exit 0
      fi
      if [[ -n "${expected_host_pid}" ]] \
          && [[ "$(current_host_pid)" != "${expected_host_pid}" ]]; then
        print -r -- \
          "The signed Mac host PID changed during the stable-host call phase." \
          > "${stable_host_failure_marker}"
        opensteamer_terminate_isolated_process_group \
          "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
        opensteamer_write_state \
          "${watchdog_state}" "state=stable-host-failure-handled"
        exit 0
      fi
      if (( SECONDS - watchdog_started >= UI_TEST_TIMEOUT_SECONDS )); then
        print -r -- \
          "Timed out after ${UI_TEST_TIMEOUT_SECONDS}s while running the physical device UI gate." \
          > "${timeout_marker}"
        opensteamer_terminate_isolated_process_group \
          "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
        opensteamer_write_state "${watchdog_state}" "state=timeout-handled"
        exit 0
      fi
      if (( SECONDS - lock_poll_started >= DEVICE_LOCK_POLL_SECONDS )); then
        lock_poll_started=${SECONDS}
        if opensteamer_device_is_unlocked \
            "${COREDEVICE_IDENTIFIER}" \
            "${DEVICE_COMMAND_TIMEOUT_SECONDS}" \
            "${lock_state_during_test}"; then
          lock_query_failures=0
        else
          lock_result=$?
          if (( lock_result == 5 )); then
            print -r -- \
              "The iPhone locked while the physical device UI gate was running." \
              > "${locked_marker}"
            opensteamer_terminate_isolated_process_group \
              "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
            opensteamer_write_state \
              "${watchdog_state}" "state=device-locked-handled"
            exit 0
          fi
          lock_query_failures=$((lock_query_failures + 1))
          if (( lock_query_failures >= 2 )); then
            print -r -- \
              "The iPhone lock state could not be verified twice during the physical device UI gate." \
              > "${unavailable_marker}"
            opensteamer_terminate_isolated_process_group \
              "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
            opensteamer_write_state \
              "${watchdog_state}" "state=device-unavailable-handled"
            exit 0
          fi
        fi
      fi
      if [[ -n "${overlap_completion_marker}" ]]; then
        sleep 0.1
      else
        sleep 1
      fi
    done
    opensteamer_write_state "${watchdog_state}" "state=xcodebuild-ended"
  ) &
  XCODEBUILD_WATCHDOG_PID=$!

  if [[ -n "${after_start_hook}" ]]; then
    run_command_capturing_status "${after_start_hook}"
    hook_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
    if (( hook_status != 0 )); then
      cleanup_blackhole_probe || hook_cleanup_status=$?
      cleanup_xcodebuild || hook_cleanup_status=$?
      if (( hook_cleanup_status != 0 )); then
        XCODEBUILD_LIVE_STDOUT=""
        return 125
      fi
      XCODEBUILD_LIVE_STDOUT=""
      return "${hook_status}"
    fi
  fi

  xcodebuild_group_pid=${XCODEBUILD_PID}
  opensteamer_wait_for_final_process_status "${XCODEBUILD_PID}"
  xcodebuild_status=${OPENSTEAMER_FINAL_PROCESS_STATUS}
  if ! opensteamer_wait_for_process_group_exit "${XCODEBUILD_PID}" 2; then
    print -r -- \
      "The device xcodebuild process group remained alive after its leader exited." \
      > "${watchdog_failure_marker}"
    opensteamer_terminate_isolated_process_group \
      "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
    if ! opensteamer_wait_for_process_group_exit "${XCODEBUILD_PID}" 2; then
      print -r -- \
        "The device xcodebuild process group survived forced termination." \
        > "${watchdog_failure_marker}"
    fi
  fi
  if opensteamer_process_group_exists "${xcodebuild_group_pid}"; then
    XCODEBUILD_GROUP_HANDLE=${xcodebuild_group_pid}
  else
    XCODEBUILD_GROUP_HANDLE=""
  fi
  if ! opensteamer_wait_for_process_exit \
      "${XCODEBUILD_WATCHDOG_PID}" "$((DEVICE_COMMAND_TIMEOUT_SECONDS + 5))"; then
    print -r -- \
      "The device lock watchdog did not finish after xcodebuild ended." \
      > "${watchdog_failure_marker}"
    opensteamer_terminate_process_tree \
      "${XCODEBUILD_WATCHDOG_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
  fi
  if wait "${XCODEBUILD_WATCHDOG_PID}" 2>/dev/null; then
    watchdog_status=0
  else
    watchdog_status=$?
  fi
  XCODEBUILD_WATCHDOG_PID=""
  XCODEBUILD_PID=""
  XCODEBUILD_GROUP_ISOLATED=0
  XCODEBUILD_LIVE_STDOUT=""

  if [[ -z "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" \
      && -n "${overlap_completion_marker}" \
      && ! -s "${RAW_UI_COMPLETION_OBSERVATION}" ]]; then
    print -r -- \
      "The nonce-bound raw UI completion handshake was not observed before xcodebuild ended." \
      > "${watchdog_failure_marker}"
  fi

  if [[ -f "${watchdog_failure_marker}" ]]; then
    cat "${watchdog_failure_marker}" >&2
    return 7
  fi
  if (( watchdog_status != 0 )); then
    echo "Device lock watchdog failed with status ${watchdog_status}." >&2
    return 7
  fi
  expected_watchdog_state="state=xcodebuild-ended"
  if [[ -f "${timeout_marker}" ]]; then
    expected_watchdog_state="state=timeout-handled"
  elif [[ -f "${locked_marker}" ]]; then
    expected_watchdog_state="state=device-locked-handled"
  elif [[ -f "${unavailable_marker}" ]]; then
    expected_watchdog_state="state=device-unavailable-handled"
  elif [[ -n "${tone_failure_marker}" && -f "${tone_failure_marker}" ]]; then
    expected_watchdog_state="state=audio-oracle-failure-handled"
  elif [[ -n "${stable_host_failure_marker}" \
      && -f "${stable_host_failure_marker}" ]]; then
    expected_watchdog_state="state=stable-host-failure-handled"
  fi
  if ! grep -qx "${expected_watchdog_state}" "${watchdog_state}" 2>/dev/null; then
    echo "Device lock watchdog lifecycle evidence is incomplete; expected ${expected_watchdog_state}." >&2
    return 7
  fi
  if [[ -f "${timeout_marker}" ]]; then
    cat "${timeout_marker}" >&2
    return 124
  fi
  if [[ -f "${locked_marker}" ]]; then
    cat "${locked_marker}" >&2
    return 5
  fi
  if [[ -f "${unavailable_marker}" ]]; then
    cat "${unavailable_marker}" >&2
    return 6
  fi
  if [[ -n "${tone_failure_marker}" && -f "${tone_failure_marker}" ]]; then
    cat "${tone_failure_marker}" >&2
    return 7
  fi
  if [[ -n "${stable_host_failure_marker}" \
      && -f "${stable_host_failure_marker}" ]]; then
    cat "${stable_host_failure_marker}" >&2
    return 4
  fi
  if (( xcodebuild_status == 0 )) \
      && [[ -n "${overlap_completion_marker}" \
          && ! -f "${overlap_completion_marker}" ]]; then
    record_raw_overlap_failure \
      ui-ended-before-valid-probe-completion 9
    cleanup_blackhole_probe || true
    echo "The raw UI session ended before valid nonce-bound probe completion evidence was captured." >&2
    return 9
  fi
  if (( xcodebuild_status != 0 )) \
      && [[ -n "${overlap_completion_marker}" ]]; then
    record_raw_overlap_failure \
      raw-ui-test-failed "${xcodebuild_status}"
  fi
  return "${xcodebuild_status}"
}

function require_phase_three_quiescence() {
  local process_id

  for process_id in \
      "${BLACKHOLE_PROBE_PID}" \
      "${SCREEN_ORACLE_PID}" \
      "${HOST_WATCHER_PID}" \
      "${AUDIO_ORACLE_TONE_PID}" \
      "${XCODEBUILD_PID}" \
      "${XCODEBUILD_GROUP_HANDLE}"; do
    if [[ -n "${process_id}" ]] \
        && opensteamer_process_group_exists "${process_id}"; then
      echo "A prior-phase process group remained alive at the stable-host call boundary." >&2
      return 1
    fi
  done
  if [[ -n "${XCODEBUILD_WATCHDOG_PID}" ]] \
      && kill -0 "${XCODEBUILD_WATCHDOG_PID}" 2>/dev/null; then
    echo "A prior-phase watchdog remained alive at the stable-host call boundary." >&2
    return 1
  fi
  if [[ -d "${HOST_CHURN_LOCK}" ]]; then
    echo "The host-churn lock remained held at the stable-host call boundary." >&2
    return 1
  fi
}

function require_stable_call_host() {
  local expected_host_pid=$1
  local observed_host_pid

  observed_host_pid=$(current_host_pid)
  opensteamer_require_same_host_process \
    "${expected_host_pid}" "${expected_host_pid}" "${observed_host_pid}"
}

function capture_production_processes_json() {
  local output=$1
  local fixture

  rm -f "${output}" || return $?
  PRODUCTION_PROCESS_QUERY_COUNT=$((PRODUCTION_PROCESS_QUERY_COUNT + 1))
  if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == production-app-termination-* ]]; then
    if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST}" == "production-app-termination-stale-json" \
        && "${PRODUCTION_PROCESS_QUERY_COUNT}" == "1" ]]; then
      return 0
    fi
    if (( PRODUCTION_PROCESS_QUERY_COUNT == 1 )); then
      fixture=${OPENSTEAMER_SELF_TEST_APP_PROCESS_INITIAL_JSON:-}
    else
      fixture=${OPENSTEAMER_SELF_TEST_APP_PROCESS_AFTER_JSON:-}
    fi
    [[ -s "${fixture}" ]] || return 1
    /bin/cp "${fixture}" "${output}"
    return $?
  fi

  opensteamer_run_with_timeout \
    "${DEVICE_COMMAND_TIMEOUT_SECONDS}" \
    xcrun devicectl device info processes \
    --device "${COREDEVICE_IDENTIFIER}" \
    --timeout "${DEVICE_COMMAND_TIMEOUT_SECONDS}" \
    --json-output "${output}" \
    >/dev/null 2>&1
}

function production_app_pid_from_process_json() {
  local process_json=$1
  local candidate_json=$2

  jq -er \
    --arg bundle "${EXPECTED_APP_BUNDLE_IDENTIFIER}" \
    --slurpfile candidate "${candidate_json}" '
    def normalized_path:
      if type == "string" then
        sub("^file://"; "") | sub("/+$"; "")
      else
        ""
      end;
    . as $inventory |
    ($candidate[0]) as $app |
    if (($app | type) != "object") or
       ($app.bundleIdentifier? != $bundle) or
       ($inventory.info.outcome? != "success") or
       (($inventory.result? | type) != "object") then
      error("invalid structured process inventory")
    else
      [
        $app
        | ..
        | strings
        | normalized_path
        | select(test("opensteamer\\.app$"; "i"))
      ] | unique as $app_roots |
      [
        $inventory.result
        | ..
        | objects
        | to_entries[]
        | select(
            (.key | test("^(processes|runningProcesses|processList)$"; "i")) and
            ((.value | type) == "array")
          )
        | .value
      ] as $process_collections |
      (
        if (($process_collections | length) == 0) or
           any($process_collections[]; any(.[]; type != "object")) then
          error("missing or malformed structured process collection")
        else
          $process_collections
        end
      ) as $validated_process_collections |
      [
        $validated_process_collections[]
        | .[]
        | ..
        | objects
        | select(has("processIdentifier") or has("pid"))
        | . as $record
        | (
            $record.executable? //
            $record.executableURL? //
            $record.path? //
            ""
          ) as $raw_executable
        | ($raw_executable | normalized_path) as $executable
        | {
            pid: ($record.processIdentifier? // $record.pid? // null),
            bundle: (
              $record.bundleIdentifier? //
              $record.applicationBundleIdentifier? //
              $record.bundleID? //
              null
            ),
            name: ($record.name? // $record.processName? // ""),
            pathMatches: any(
              $app_roots[];
              . as $root |
              ($executable | startswith($root + "/"))
            )
          }
      ] as $records |
      [
        $records[]
        | select(
            (.bundle == $bundle) or
            .pathMatches or
            (.name == "opensteamer")
          )
      ] as $identities |
      if all(
          $identities[];
          ((.pid | type) == "number") and
          (.pid > 0) and
          ((.pid | floor) == .pid) and
          ((.bundle == null) or (.bundle == $bundle)) and
          ((.bundle == $bundle) or .pathMatches)
        ) then
        ([ $identities[].pid ] | unique) as $pids |
        if ($pids | length) == 0 then
          "absent"
        elif ($pids | length) == 1 then
          ($pids[0] | tostring)
        else
          error("ambiguous production process identity")
        end
      else
        error("wrong or malformed production process identity")
      end
    end
  ' "${process_json}"
}

function capture_raw_probe_production_identity() {
  local boundary=$1
  local process_json="${RAW_PROOF_WORK_DIR}/.raw-probe-${boundary}-processes.json"
  local candidate_json="${CANDIDATE_BEFORE}"
  local evidence_output
  local fixture_pid
  local identity
  local observed_at_ns
  local temporary
  local command_status

  case "${boundary}" in
    start)
      evidence_output="${RAW_PROBE_PROCESS_START_EVIDENCE}"
      ;;
    completion)
      evidence_output="${RAW_PROBE_PROCESS_COMPLETION_EVIDENCE}"
      ;;
    *)
      return 3
      ;;
  esac
  temporary="${evidence_output}.tmp.$$"
  rm -f "${process_json}" "${evidence_output}" "${temporary}" || return $?
  if [[ -n "${OPENSTEAMER_SELF_TEST_RAW_READINESS:-}" ]]; then
    candidate_json="${RAW_PROOF_WORK_DIR}/.raw-probe-self-test-candidate.json"
    jq -n \
      --arg bundle "${EXPECTED_APP_BUNDLE_IDENTIFIER}" \
      '{bundleIdentifier:$bundle,path:"/Applications/opensteamer.app"}' \
      > "${candidate_json}" || return $?
    fixture_pid=7101
    if [[ "${boundary}" == "completion" ]]; then
      fixture_pid=${OPENSTEAMER_SELF_TEST_RAW_APP_COMPLETION_PID:-7101}
    fi
    if [[ "${fixture_pid}" == "absent" ]]; then
      print -r -- \
        '{"info":{"outcome":"success"},"result":{"processes":[]}}' \
        > "${process_json}" || return $?
    elif [[ -n "${fixture_pid}" \
        && "${fixture_pid}" != *[^0-9]* ]] \
        && (( fixture_pid > 0 )); then
      jq -n \
        --arg bundle "${EXPECTED_APP_BUNDLE_IDENTIFIER}" \
        --argjson pid "${fixture_pid}" \
        '{info:{outcome:"success"},result:{processes:[{processIdentifier:$pid,bundleIdentifier:$bundle,executable:"/Applications/opensteamer.app/opensteamer"}]}}' \
        > "${process_json}" || return $?
    else
      return 3
    fi
  else
    [[ -s "${candidate_json}" ]] || return 3
    capture_production_processes_json "${process_json}" || return $?
  fi
  [[ -s "${process_json}" ]] || return 3
  identity=$(
    production_app_pid_from_process_json \
      "${process_json}" "${candidate_json}"
  ) || {
    command_status=$?
    rm -f "${process_json}"
    return "${command_status}"
  }
  if [[ -z "${identity}" || "${identity}" == "absent" \
      || "${identity}" == *[^0-9]* ]] \
      || (( identity <= 0 )); then
    rm -f "${process_json}"
    return 3
  fi
  if jq -e \
      --arg bundle "${EXPECTED_APP_BUNDLE_IDENTIFIER}" \
      --argjson process_id "${identity}" '
    (.info.outcome? == "success") and
    ((.result? | type) == "object") and
    ([
      .result
      | ..
      | objects
      | select((.processIdentifier? // .pid? // null) == $process_id)
      | select(
          (.bundleIdentifier? //
            .applicationBundleIdentifier? //
            .bundleID? //
            null) == $bundle
        )
    ] | length == 1)
  ' "${process_json}" >/dev/null; then
    :
  else
    command_status=$?
    rm -f "${process_json}"
    return "${command_status}"
  fi
  rm -f "${process_json}"
  observed_at_ns=$(current_monotonic_time_ns) || return $?
  if [[ -z "${observed_at_ns}" \
      || "${observed_at_ns}" == *[^0-9]* ]] \
      || (( observed_at_ns <= 0 )); then
    return 3
  fi
  {
    print -r -- "schema=opensteamer.production-app-probe-boundary.v1"
    print -r -- "boundary=${boundary}"
    print -r -- "nonce=${RAW_READY_NONCE}"
    print -r -- "bundleIdentifier=${EXPECTED_APP_BUNDLE_IDENTIFIER}"
    print -r -- "pid=${identity}"
    print -r -- "observedAtMonotonicNs=${observed_at_ns}"
  } > "${temporary}" || return $?
  mv "${temporary}" "${evidence_output}" || return $?
  print -r -- "${identity}"
}

function terminate_production_app_pid_json() {
  local process_id=$1
  local output=$2

  rm -f "${output}" || return $?
  if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == production-app-termination-* ]]; then
    if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST}" == "production-app-termination-termination-failure" ]]; then
      return 17
    fi
    if [[ -n "${OPENSTEAMER_SELF_TEST_EXPECTED_APP_PID:-}" \
        && "${process_id}" != "${OPENSTEAMER_SELF_TEST_EXPECTED_APP_PID}" ]]; then
      return 18
    fi
    [[ -s "${OPENSTEAMER_SELF_TEST_APP_TERMINATION_JSON:-}" ]] || return 1
    /bin/cp "${OPENSTEAMER_SELF_TEST_APP_TERMINATION_JSON}" "${output}"
    return $?
  fi

  opensteamer_run_with_timeout \
    "${DEVICE_COMMAND_TIMEOUT_SECONDS}" \
    xcrun devicectl device process terminate \
    --device "${COREDEVICE_IDENTIFIER}" \
    --pid "${process_id}" \
    --timeout "${DEVICE_COMMAND_TIMEOUT_SECONDS}" \
    --json-output "${output}" \
    >/dev/null 2>&1
}

function validate_production_app_termination_json() {
  local output=$1
  local process_id=$2

  jq -e \
    --arg bundle "${EXPECTED_APP_BUNDLE_IDENTIFIER}" \
    --argjson process_id "${process_id}" '
    def pid_aliases:
      [
        to_entries[]
        | select(
            (.key == "processIdentifier") or
            (.key == "pid")
          )
        | .value
      ];
    def bundle_aliases:
      [
        to_entries[]
        | select(
            (.key == "bundleIdentifier") or
            (.key == "applicationBundleIdentifier") or
            (.key == "bundleID")
          )
        | .value
      ];
    (.info.outcome? == "success") and
    ((.result? | type) == "object") and
    (
      [
        .result
        | ..
        | objects
        | . as $record
        | ($record | pid_aliases) as $pids
        | ($record | bundle_aliases) as $bundles
        | select(
            any($pids[]; . == $process_id) or
            any($bundles[]; . == $bundle)
          )
        | {pids: $pids, bundles: $bundles}
      ] as $candidates |
      (($candidates | length) > 0) and
      all(
        $candidates[];
        (. as $candidate |
          (($candidate.pids | length) > 0) and
          (($candidate.bundles | length) > 0) and
          all(
            $candidate.pids[];
            (type == "number") and
            (. > 0) and
            ((floor) == .) and
            (. == $process_id)
          ) and
          (($candidate.pids | unique | length) == 1) and
          all(
            $candidate.bundles[];
            (type == "string") and
            (. == $bundle)
          ) and
          (($candidate.bundles | unique | length) == 1)
        )
      )
    )
  ' "${output}" >/dev/null
}

function write_production_app_termination_evidence() {
  local output=$1
  local gate_state=$2
  local process_id=${3:-}
  local temporary="${output}.tmp.$$"

  {
    print -r -- "schema=opensteamer.production-app-termination.v1"
    print -r -- "state=${gate_state}"
    print -r -- "bundleIdentifier=${EXPECTED_APP_BUNDLE_IDENTIFIER}"
    print -r -- "processQuery=structured-devicectl-json"
    if [[ -n "${process_id}" ]]; then
      print -r -- "pid=${process_id}"
      print -r -- "termination=structured-devicectl-json-by-pid"
    else
      print -r -- "termination=not-required"
    fi
  } > "${temporary}" || return $?
  mv "${temporary}" "${output}"
}

function terminate_production_app_for_phase() {
  local phase_directory=$1
  local evidence_output=$2
  local failure_context=$3
  local process_json="${phase_directory}/.production-processes.json"
  local termination_json="${phase_directory}/.production-termination.json"
  local post_process_json="${phase_directory}/.production-processes-after.json"
  local candidate_json=${OPENSTEAMER_SELF_TEST_APP_CANDIDATE_JSON:-${CANDIDATE_BEFORE}}
  local process_identity
  local post_identity
  local command_status

  PRODUCTION_PROCESS_QUERY_COUNT=0
  rm -f \
    "${evidence_output}" \
    "${process_json}" \
    "${termination_json}" \
    "${post_process_json}" || return $?
  [[ -s "${candidate_json}" ]] || return 1

  capture_production_processes_json "${process_json}" || return $?
  [[ -s "${process_json}" ]] || return 1
  process_identity=$(
    production_app_pid_from_process_json "${process_json}" "${candidate_json}"
  ) || {
    command_status=$?
    rm -f "${process_json}" "${termination_json}" "${post_process_json}"
    return "${command_status}"
  }
  rm -f "${process_json}"

  if [[ "${process_identity}" == "absent" ]]; then
    write_production_app_termination_evidence \
      "${evidence_output}" already-terminated
    return $?
  fi
  if [[ -z "${process_identity}" || "${process_identity}" == *[^0-9]* ]] \
      || (( process_identity <= 0 )); then
    return 1
  fi

  terminate_production_app_pid_json "${process_identity}" "${termination_json}" \
    || {
      command_status=$?
      rm -f "${termination_json}" "${post_process_json}"
      echo "The production app could not be terminated ${failure_context}." >&2
      return "${command_status}"
    }
  [[ -s "${termination_json}" ]] || {
    rm -f "${termination_json}" "${post_process_json}"
    return 1
  }
  validate_production_app_termination_json \
    "${termination_json}" "${process_identity}" || {
      command_status=$?
      rm -f "${termination_json}" "${post_process_json}"
      return "${command_status}"
    }
  rm -f "${termination_json}"

  capture_production_processes_json "${post_process_json}" || {
    command_status=$?
    rm -f "${post_process_json}"
    return "${command_status}"
  }
  [[ -s "${post_process_json}" ]] || {
    rm -f "${post_process_json}"
    return 1
  }
  post_identity=$(
    production_app_pid_from_process_json "${post_process_json}" "${candidate_json}"
  ) || {
    command_status=$?
    rm -f "${post_process_json}"
    return "${command_status}"
  }
  rm -f "${post_process_json}"
  if [[ "${post_identity}" != "absent" ]]; then
    echo "The production app could not be terminated ${failure_context}." >&2
    return 1
  fi
  write_production_app_termination_evidence \
    "${evidence_output}" terminated "${process_identity}"
}

function terminate_production_app_for_raw_phase() {
  terminate_production_app_for_phase \
    "${RAW_PHASE_DIR}" \
    "${RAW_APP_TERMINATION_EVIDENCE}" \
    "before raw microphone validation"
}

function terminate_production_app_for_call_phase() {
  if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == call-ready-* ]]; then
    write_production_app_termination_evidence \
      "${CALL_APP_TERMINATION_EVIDENCE}" terminated 1
    return $?
  fi
  terminate_production_app_for_phase \
    "${CALL_PHASE_DIR}" \
    "${CALL_APP_TERMINATION_EVIDENCE}" \
    "before the real-call acknowledgement"
}

function fresh_call_ready_token() {
  if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == call-ready-* \
      && -n "${OPENSTEAMER_SELF_TEST_CALL_READY_TOKEN:-}" ]]; then
    print -r -- "${OPENSTEAMER_SELF_TEST_CALL_READY_TOKEN}"
    return
  fi
  print -r -- \
    "call-$(
      /usr/bin/uuidgen \
        | tr '[:upper:]' '[:lower:]'
    )"
}

function wait_for_fresh_call_ready_acknowledgement() {
  local token
  local acknowledgement
  local deadline_ns
  local self_test_query_delay_consumed=0
  local self_test_post_read_delay_consumed=0

  deadline_ns=$(acknowledgement_deadline_ns \
    "${CALL_READY_TIMEOUT_SECONDS}") || return $?

  rm -f \
    "${CALL_READY_REQUEST}" \
    "${CALL_READY_STATUS}" \
    "${CALL_READY_TIMEOUT_MARKER}" \
    "${CALL_READY_STALE_MARKER}" || return $?
  if [[ -e "${CALL_READY_ACKNOWLEDGEMENT}" ]]; then
    rm -f "${CALL_READY_ACKNOWLEDGEMENT}" || return $?
    opensteamer_write_state \
      "${CALL_READY_STALE_MARKER}" "state=discarded-before-request" || return $?
  fi
  token=$(fresh_call_ready_token) || return $?
  opensteamer_write_state \
    "${CALL_READY_REQUEST}" "ready-token=${token}" || return $?
  print -r -- \
    "phase=3 event=call-ready-requested" \
    >> "${PHASE_EVENTS}" || return $?
  if [[ -z "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" ]]; then
    print -r -- \
      "Connect a real Phone or FaceTime call, then write exactly 'ready=${token}' to ${CALL_READY_ACKNOWLEDGEMENT}." \
      >&2 || return $?
  fi

  while acknowledgement_remaining_seconds "${deadline_ns}" >/dev/null; do
    if (( self_test_query_delay_consumed == 0 )) \
        && [[ -n "${OPENSTEAMER_SELF_TEST_ACK_QUERY_DELAY_SECONDS:-}" ]]; then
      sleep "${OPENSTEAMER_SELF_TEST_ACK_QUERY_DELAY_SECONDS}"
      self_test_query_delay_consumed=1
      acknowledgement_remaining_seconds "${deadline_ns}" >/dev/null || break
    fi
    if [[ -f "${CALL_READY_ACKNOWLEDGEMENT}" ]]; then
      acknowledgement=$(<"${CALL_READY_ACKNOWLEDGEMENT}") || return $?
      if (( self_test_post_read_delay_consumed == 0 )) \
          && [[ -n "${OPENSTEAMER_SELF_TEST_ACK_POST_READ_DELAY_SECONDS:-}" ]]; then
        sleep "${OPENSTEAMER_SELF_TEST_ACK_POST_READ_DELAY_SECONDS}"
        self_test_post_read_delay_consumed=1
      fi
      acknowledgement_remaining_seconds "${deadline_ns}" >/dev/null || break
      if [[ "${acknowledgement}" == "ready=${token}" ]]; then
        opensteamer_write_state "${CALL_READY_STATUS}" "state=accepted" || return $?
        print -r -- \
          "phase=3 event=call-ready-accepted" \
          >> "${PHASE_EVENTS}" || return $?
        return 0
      fi
      rm -f "${CALL_READY_ACKNOWLEDGEMENT}" || return $?
      opensteamer_write_state \
        "${CALL_READY_STALE_MARKER}" "state=rejected" || return $?
    fi
    sleep 0.1
  done

  opensteamer_write_state "${CALL_READY_STATUS}" "state=timed-out" || return $?
  opensteamer_write_state \
    "${CALL_READY_TIMEOUT_MARKER}" "state=timed-out" || return $?
  echo "Timed out waiting for a fresh real-call operator acknowledgement." >&2
  return 1
}

function fresh_call_end_token() {
  if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == call-end-* \
      && -n "${OPENSTEAMER_SELF_TEST_CALL_END_TOKEN:-}" ]]; then
    print -r -- "${OPENSTEAMER_SELF_TEST_CALL_END_TOKEN}"
    return
  fi
  print -r -- \
    "end-call-$(
      /usr/bin/uuidgen \
        | tr '[:upper:]' '[:lower:]'
    )"
}

function fresh_call_acoustic_token() {
  if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == call-acoustic-* \
      && -n "${OPENSTEAMER_SELF_TEST_CALL_ACOUSTIC_TOKEN:-}" ]]; then
    print -r -- "${OPENSTEAMER_SELF_TEST_CALL_ACOUSTIC_TOKEN}"
    return
  fi
  print -r -- \
    "heard-call-$(
      /usr/bin/uuidgen \
        | tr '[:upper:]' '[:lower:]'
  )"
}

function acknowledgement_deadline_ns() {
  local timeout_seconds=$1
  local started_ns
  local deadline_ns

  [[ -n "${timeout_seconds}" && "${timeout_seconds}" != *[^0-9]* ]] \
    || return 2
  started_ns=$(current_monotonic_time_ns) || return $?
  [[ -n "${started_ns}" && "${started_ns}" != *[^0-9]* ]] || return 3
  deadline_ns=$((started_ns + timeout_seconds * 1000000000))
  (( deadline_ns > started_ns )) || return 3
  print -r -- "${deadline_ns}"
}

# Print the positive whole-second budget remaining at an acknowledgement boundary, rounded up so
# the nested device query cannot exceed the absolute deadline merely because its API accepts only
# seconds. Absence of output with status 1 means the deadline has already closed.
function acknowledgement_remaining_seconds() {
  local deadline_ns=$1
  local now_ns
  local remaining_ns

  [[ -n "${deadline_ns}" && "${deadline_ns}" != *[^0-9]* ]] || return 3
  now_ns=$(current_monotonic_time_ns) || return $?
  [[ -n "${now_ns}" && "${now_ns}" != *[^0-9]* ]] || return 3
  (( now_ns < deadline_ns )) || return 1
  remaining_ns=$((deadline_ns - now_ns))
  print -r -- $(((remaining_ns + 999999999) / 1000000000))
}

# The WebRTC/native counters used by XCTest stop before the final iOS mixer, route, DAC, and
# speaker. This fresh human acknowledgement is therefore a separate physical acceptance boundary,
# and it must complete while the real call, XCTest, tone, device, and one signed host are live.
function wait_for_fresh_call_acoustic_acknowledgement() {
  local token
  local acknowledgement
  local deadline_ns=${1:-}
  local remaining_seconds
  local query_timeout_seconds
  local lock_poll_started=${SECONDS}
  local lock_query_failures=0
  local lock_result
  local accepted_record
  local self_test_query_delay_consumed=0
  local self_test_post_read_delay_consumed=0

  CALL_ACOUSTIC_ACCEPTED_NS=0
  CALL_ACOUSTIC_ACCEPTED_TOKEN=""

  if [[ -z "${deadline_ns}" ]]; then
    deadline_ns=$(acknowledgement_deadline_ns \
      "${CALL_ACOUSTIC_TIMEOUT_SECONDS}") || return $?
  else
    acknowledgement_remaining_seconds "${deadline_ns}" >/dev/null || return 1
  fi

  /bin/rm -f \
    "${CALL_ACOUSTIC_REQUEST}" \
    "${CALL_ACOUSTIC_STATUS}" \
    "${CALL_ACOUSTIC_TIMEOUT_MARKER}" \
    "${CALL_ACOUSTIC_STALE_MARKER}" || return $?
  if [[ -e "${CALL_ACOUSTIC_ACKNOWLEDGEMENT}" ]]; then
    /bin/rm -f "${CALL_ACOUSTIC_ACKNOWLEDGEMENT}" || return $?
    opensteamer_write_state \
      "${CALL_ACOUSTIC_STALE_MARKER}" "state=discarded-before-request" || return $?
  fi
  token=$(fresh_call_acoustic_token) || return $?
  opensteamer_write_state \
    "${CALL_ACOUSTIC_REQUEST}" "heard-token=${token}" || return $?
  print -r -- "phase=3 event=call-acoustic-requested" \
    >> "${PHASE_EVENTS}" || return $?
  if [[ -z "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" ]]; then
    print -r -- \
      "While the real call is still connected, listen at the physical iPhone until the streamed Mac tone is clearly audible, then write exactly 'heard=${token}' to ${CALL_ACOUSTIC_ACKNOWLEDGEMENT}." \
      >&2 || return $?
  fi
  while remaining_seconds=$(acknowledgement_remaining_seconds \
      "${deadline_ns}"); do
    if (( self_test_query_delay_consumed == 0 )) \
        && [[ -n "${OPENSTEAMER_SELF_TEST_ACK_QUERY_DELAY_SECONDS:-}" ]]; then
      sleep "${OPENSTEAMER_SELF_TEST_ACK_QUERY_DELAY_SECONDS}"
      self_test_query_delay_consumed=1
      acknowledgement_remaining_seconds "${deadline_ns}" >/dev/null || break
    fi
    if [[ -z "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" ]]; then
      if [[ -z "${XCODEBUILD_PID}" ]] \
          || ! opensteamer_process_group_exists "${XCODEBUILD_PID}"; then
        opensteamer_write_state \
          "${CALL_ACOUSTIC_STATUS}" "state=ui-ended-before-acknowledgement" || true
        return 9
      fi
      if [[ -z "${AUDIO_ORACLE_TONE_PID}" ]] \
          || ! opensteamer_process_group_exists "${AUDIO_ORACLE_TONE_PID}"; then
        opensteamer_write_state \
          "${CALL_ACOUSTIC_STATUS}" "state=audio-oracle-ended-before-acknowledgement" || true
        return 7
      fi
      if [[ -z "${CALL_STABLE_HOST_PID}" \
          || "$(current_host_pid)" != "${CALL_STABLE_HOST_PID}" ]]; then
        opensteamer_write_state \
          "${CALL_ACOUSTIC_STATUS}" "state=host-changed-before-acknowledgement" || true
        return 4
      fi
      if (( SECONDS - lock_poll_started >= DEVICE_LOCK_POLL_SECONDS )); then
        lock_poll_started=${SECONDS}
        remaining_seconds=$(acknowledgement_remaining_seconds \
          "${deadline_ns}") || break
        if (( remaining_seconds > 1 )); then
          query_timeout_seconds=${DEVICE_COMMAND_TIMEOUT_SECONDS}
          if (( query_timeout_seconds >= remaining_seconds )); then
            query_timeout_seconds=$((remaining_seconds - 1))
          fi
          if opensteamer_device_is_unlocked \
              "${COREDEVICE_IDENTIFIER}" \
              "${query_timeout_seconds}" \
              "${CALL_LOCK_STATE_DURING_TEST}"; then
            lock_query_failures=0
          else
            lock_result=$?
            if (( lock_result == 5 )); then
              opensteamer_write_state \
                "${CALL_ACOUSTIC_STATUS}" "state=device-locked-before-acknowledgement" || true
              return 5
            fi
            lock_query_failures=$((lock_query_failures + 1))
            if (( lock_query_failures >= 2 )); then
              opensteamer_write_state \
                "${CALL_ACOUSTIC_STATUS}" "state=device-unavailable-before-acknowledgement" || true
              return 6
            fi
          fi
          acknowledgement_remaining_seconds "${deadline_ns}" >/dev/null || break
        fi
      fi
    fi
    acknowledgement_remaining_seconds "${deadline_ns}" >/dev/null || break
    if [[ -f "${CALL_ACOUSTIC_ACKNOWLEDGEMENT}" ]]; then
      acknowledgement=$(<"${CALL_ACOUSTIC_ACKNOWLEDGEMENT}") || return $?
      if (( self_test_post_read_delay_consumed == 0 )) \
          && [[ -n "${OPENSTEAMER_SELF_TEST_ACK_POST_READ_DELAY_SECONDS:-}" ]]; then
        sleep "${OPENSTEAMER_SELF_TEST_ACK_POST_READ_DELAY_SECONDS}"
        self_test_post_read_delay_consumed=1
      fi
      acknowledgement_remaining_seconds "${deadline_ns}" >/dev/null || break
      if [[ "${acknowledgement}" == "heard=${token}" ]]; then
        CALL_ACOUSTIC_ACCEPTED_NS=$(current_monotonic_time_ns) || return $?
        [[ "${CALL_ACOUSTIC_ACCEPTED_NS}" != *[^0-9]* \
            && CALL_ACOUSTIC_ACCEPTED_NS -lt deadline_ns ]] || break
        CALL_ACOUSTIC_ACCEPTED_TOKEN=${token}
        accepted_record="schema=opensteamer.call-acoustic-acknowledgement.v2
nonce=${RAW_READY_NONCE}
sequence=1
token=${token}
state=accepted
acceptedAtMonotonicNs=${CALL_ACOUSTIC_ACCEPTED_NS}"
        opensteamer_write_state \
          "${CALL_ACOUSTIC_STATUS}" \
          "${accepted_record}" || return $?
        print -r -- "phase=3 event=call-acoustic-accepted" \
          >> "${PHASE_EVENTS}" || return $?
        return 0
      fi
      /bin/rm -f "${CALL_ACOUSTIC_ACKNOWLEDGEMENT}" || return $?
      opensteamer_write_state \
        "${CALL_ACOUSTIC_STALE_MARKER}" "state=rejected" || return $?
    fi
    sleep 0.1
  done

  opensteamer_write_state "${CALL_ACOUSTIC_STATUS}" "state=timed-out" || return $?
  opensteamer_write_state \
    "${CALL_ACOUSTIC_TIMEOUT_MARKER}" "state=timed-out" || return $?
  echo "Timed out waiting for the nonce-bound in-call acoustic acknowledgement." >&2
  return 1
}

# xcodebuild is already running when this hook executes. The operator must first observe the
# connected-call hosted-playout proof on the iPhone, then end that call and acknowledge this fresh
# token. The XCTest process continues concurrently and can accept post-call recovery only after the
# real call transition; stale files, early test exit, host/tone loss, and device-lock uncertainty
# all fail closed.
function wait_for_fresh_call_end_acknowledgement() {
  local token
  local acknowledgement
  local deadline_ns
  local remaining_seconds
  local query_timeout_seconds
  local lock_poll_started=${SECONDS}
  local lock_query_failures=0
  local lock_result
  local self_test_query_delay_consumed=0
  local self_test_post_read_delay_consumed=0

  deadline_ns=$(acknowledgement_deadline_ns \
    "${CALL_END_TIMEOUT_SECONDS}") || return $?

  /bin/rm -f \
    "${CALL_END_REQUEST}" \
    "${CALL_END_STATUS}" \
    "${CALL_END_TIMEOUT_MARKER}" \
    "${CALL_END_STALE_MARKER}" || return $?
  if [[ -e "${CALL_END_ACKNOWLEDGEMENT}" ]]; then
    /bin/rm -f "${CALL_END_ACKNOWLEDGEMENT}" || return $?
    opensteamer_write_state \
      "${CALL_END_STALE_MARKER}" "state=discarded-before-request" || return $?
  fi
  token=$(fresh_call_end_token) || return $?
  opensteamer_write_state \
    "${CALL_END_REQUEST}" "end-call-token=${token}" || return $?
  print -r -- "phase=3 event=call-end-requested" \
    >> "${PHASE_EVENTS}" || return $?
  if [[ -z "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" ]]; then
    print -r -- \
      "After the iPhone shows sustained connected-call playout, end the real call, then write exactly 'ended=${token}' to ${CALL_END_ACKNOWLEDGEMENT}." \
      >&2 || return $?
  fi
  while remaining_seconds=$(acknowledgement_remaining_seconds \
      "${deadline_ns}"); do
    if (( self_test_query_delay_consumed == 0 )) \
        && [[ -n "${OPENSTEAMER_SELF_TEST_ACK_QUERY_DELAY_SECONDS:-}" ]]; then
      sleep "${OPENSTEAMER_SELF_TEST_ACK_QUERY_DELAY_SECONDS}"
      self_test_query_delay_consumed=1
      acknowledgement_remaining_seconds "${deadline_ns}" >/dev/null || break
    fi
    if [[ -z "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" ]]; then
      if [[ -z "${XCODEBUILD_PID}" ]] \
          || ! opensteamer_process_group_exists "${XCODEBUILD_PID}"; then
        opensteamer_write_state \
          "${CALL_END_STATUS}" "state=ui-ended-before-acknowledgement" || true
        return 9
      fi
      if [[ -z "${AUDIO_ORACLE_TONE_PID}" ]] \
          || ! opensteamer_process_group_exists "${AUDIO_ORACLE_TONE_PID}"; then
        opensteamer_write_state \
          "${CALL_END_STATUS}" "state=audio-oracle-ended-before-acknowledgement" || true
        return 7
      fi
      if [[ -z "${CALL_STABLE_HOST_PID}" \
          || "$(current_host_pid)" != "${CALL_STABLE_HOST_PID}" ]]; then
        opensteamer_write_state \
          "${CALL_END_STATUS}" "state=host-changed-before-acknowledgement" || true
        return 4
      fi
      if (( SECONDS - lock_poll_started >= DEVICE_LOCK_POLL_SECONDS )); then
        lock_poll_started=${SECONDS}
        remaining_seconds=$(acknowledgement_remaining_seconds \
          "${deadline_ns}") || break
        if (( remaining_seconds > 1 )); then
          query_timeout_seconds=${DEVICE_COMMAND_TIMEOUT_SECONDS}
          if (( query_timeout_seconds >= remaining_seconds )); then
            query_timeout_seconds=$((remaining_seconds - 1))
          fi
          if opensteamer_device_is_unlocked \
              "${COREDEVICE_IDENTIFIER}" \
              "${query_timeout_seconds}" \
              "${CALL_LOCK_STATE_DURING_TEST}"; then
            lock_query_failures=0
          else
            lock_result=$?
            if (( lock_result == 5 )); then
              opensteamer_write_state \
                "${CALL_END_STATUS}" "state=device-locked-before-acknowledgement" || true
              return 5
            fi
            lock_query_failures=$((lock_query_failures + 1))
            if (( lock_query_failures >= 2 )); then
              opensteamer_write_state \
                "${CALL_END_STATUS}" "state=device-unavailable-before-acknowledgement" || true
              return 6
            fi
          fi
          acknowledgement_remaining_seconds "${deadline_ns}" >/dev/null || break
        fi
      fi
    fi
    acknowledgement_remaining_seconds "${deadline_ns}" >/dev/null || break
    if [[ -f "${CALL_END_ACKNOWLEDGEMENT}" ]]; then
      acknowledgement=$(<"${CALL_END_ACKNOWLEDGEMENT}") || return $?
      if (( self_test_post_read_delay_consumed == 0 )) \
          && [[ -n "${OPENSTEAMER_SELF_TEST_ACK_POST_READ_DELAY_SECONDS:-}" ]]; then
        sleep "${OPENSTEAMER_SELF_TEST_ACK_POST_READ_DELAY_SECONDS}"
        self_test_post_read_delay_consumed=1
      fi
      acknowledgement_remaining_seconds "${deadline_ns}" >/dev/null || break
      if [[ "${acknowledgement}" == "ended=${token}" ]]; then
        opensteamer_write_state "${CALL_END_STATUS}" "state=accepted" || return $?
        print -r -- "phase=3 event=call-end-accepted" \
          >> "${PHASE_EVENTS}" || return $?
        return 0
      fi
      /bin/rm -f "${CALL_END_ACKNOWLEDGEMENT}" || return $?
      opensteamer_write_state \
        "${CALL_END_STALE_MARKER}" "state=rejected" || return $?
    fi
    sleep 0.1
  done

  opensteamer_write_state "${CALL_END_STATUS}" "state=timed-out" || return $?
  opensteamer_write_state \
    "${CALL_END_TIMEOUT_MARKER}" "state=timed-out" || return $?
  echo "Timed out waiting for the nonce-bound end-call operator acknowledgement." >&2
  return 1
}

function configure_post_call_raw_contract() {
  [[ -x "${RAW_BLACKHOLE_PROBE_BINARY}" ]] || return 3
  mkdir -p "${CALL_POST_RAW_DIR}" || return $?

  RAW_READY_TIMEOUT_SECONDS=${POST_CALL_RAW_PRE_PROBE_BUDGET_SECONDS}
  RAW_PROOF_CONTEXT="post-call"
  RAW_PROOF_EVENT_PHASE=3
  RAW_PROOF_EVENT_PREFIX="post-call-"
  RAW_PROOF_EXPECTED_HOST_PID=${CALL_STABLE_HOST_PID}
  RAW_PROOF_REQUIRE_NEW_CONNECTION=0
  RAW_PROOF_WORK_DIR=${CALL_POST_RAW_DIR}
  RAW_HOST_LOG_APPEND_CHUNK=${CALL_POST_RAW_HOST_LOG_APPEND_CHUNK}
  RAW_HOST_LOG_COMPLETED_LINES=${CALL_POST_RAW_HOST_LOG_COMPLETED_LINES}
  RAW_HOST_LOG_PARTIAL_LINE=${CALL_POST_RAW_HOST_LOG_PARTIAL_LINE}
  RAW_READY_REQUEST=${CALL_POST_RAW_READY_REQUEST}
  RAW_READY_RESUMED_MARKER=${CALL_POST_RAW_READY_RESUMED_MARKER}
  RAW_READY_EVIDENCE=${CALL_POST_RAW_READY_EVIDENCE}
  RAW_READY_STATUS=${CALL_POST_RAW_READY_STATUS}
  RAW_READY_TIMEOUT_MARKER=${CALL_POST_RAW_READY_TIMEOUT_MARKER}
  RAW_READY_STALE_MARKER=${CALL_POST_RAW_READY_STALE_MARKER}
  RAW_READY_CONTINUITY_EVIDENCE=${CALL_POST_RAW_READY_CONTINUITY_EVIDENCE}
  RAW_READY_CONTINUITY_ARMED_MARKER=${CALL_POST_RAW_READY_CONTINUITY_ARMED_MARKER}
  RAW_READY_CONTINUITY_LOG_APPEND_CHUNK=${CALL_POST_RAW_READY_CONTINUITY_LOG_APPEND_CHUNK}
  RAW_READY_CONTINUITY_LOG_COMPLETED_LINES=${CALL_POST_RAW_READY_CONTINUITY_LOG_COMPLETED_LINES}
  RAW_READY_CONTINUITY_LOG_PARTIAL_LINE=${CALL_POST_RAW_READY_CONTINUITY_LOG_PARTIAL_LINE}
  RAW_PROBE_OVERLAP_MARKER=${CALL_POST_RAW_PROBE_OVERLAP_MARKER}
  RAW_PROBE_NON_OVERLAP_MARKER=${CALL_POST_RAW_PROBE_NON_OVERLAP_MARKER}
  RAW_UI_RUNTIME_ATTACHMENT_PAYLOAD_ID=${CALL_POST_RAW_UI_RUNTIME_ATTACHMENT_PAYLOAD_ID}
  RAW_UI_RUNTIME_EVIDENCE=${CALL_POST_RAW_UI_RUNTIME_EVIDENCE}
  RAW_UI_COMPLETION_OBSERVATION=${CALL_POST_RAW_UI_COMPLETION_OBSERVATION}
  RAW_UI_CAUSAL_STATE_OBSERVATION=${CALL_POST_RAW_UI_CAUSAL_STATE_OBSERVATION}
  RAW_UI_BOUNDS_EVIDENCE=${CALL_POST_RAW_UI_BOUNDS_EVIDENCE}
  RAW_PROBE_PROCESS_START_EVIDENCE=${CALL_POST_RAW_PROBE_PROCESS_START_EVIDENCE}
  RAW_PROBE_PROCESS_COMPLETION_EVIDENCE=${CALL_POST_RAW_PROBE_PROCESS_COMPLETION_EVIDENCE}
  RAW_PROBE_COMPLETION_OBSERVATION=${CALL_POST_RAW_PROBE_COMPLETION_OBSERVATION}
  RAW_PROBE_WAIT_EVIDENCE=${CALL_POST_RAW_PROBE_WAIT_EVIDENCE}
  RAW_PROBE_INTERVAL_EVIDENCE=${CALL_POST_RAW_PROBE_INTERVAL_EVIDENCE}
  RAW_BLACKHOLE_PROBE_RESULT=${CALL_POST_RAW_PROBE_RESULT}
  RAW_BLACKHOLE_PROBE_CLEANUP_PROOF=${CALL_POST_RAW_PROBE_CLEANUP_PROOF}
  RAW_BLACKHOLE_PROBE_DIAGNOSTICS=${CALL_POST_RAW_PROBE_DIAGNOSTICS}
  RAW_BLACKHOLE_PROBE_COMPLETION=${CALL_POST_RAW_PROBE_COMPLETION}
  RAW_DEFAULT_INPUT_BEFORE=${CALL_POST_RAW_DEFAULT_INPUT_BEFORE}
  RAW_DEFAULT_INPUT_HEALTHY=${CALL_POST_RAW_DEFAULT_INPUT_HEALTHY}
  RAW_DEFAULT_INPUT_DURING=${CALL_POST_RAW_DEFAULT_INPUT_DURING}
  RAW_DEFAULT_INPUT_AFTER=${CALL_POST_RAW_DEFAULT_INPUT_AFTER}
  RAW_DEFAULT_INPUT_LIFECYCLE_EVIDENCE=${CALL_POST_RAW_DEFAULT_INPUT_LIFECYCLE_EVIDENCE}
  BLACKHOLE_PROBE_PID=""
  BLACKHOLE_PROBE_STATUS=""
}

function arm_post_call_raw_readiness() {
  local resumed_at_ns

  initialize_raw_session_readiness || return $?
  resumed_at_ns=$(current_monotonic_time_ns) || return $?
  if [[ -z "${resumed_at_ns}" || "${resumed_at_ns}" == *[^0-9]* ]] \
      || (( resumed_at_ns <= RAW_READY_REQUESTED_NS )); then
    return 3
  fi
  RAW_READY_RESUMED_NS=${resumed_at_ns}
  opensteamer_write_state \
    "${RAW_READY_RESUMED_MARKER}" \
    "state=resumed nonce=${RAW_READY_NONCE} resumedAtMonotonicNs=${RAW_READY_RESUMED_NS}" \
    || return $?
  print -r -- "phase=3 event=post-call-raw-proof-armed" \
    >> "${PHASE_EVENTS}"
}

function run_real_call_operator_and_post_call_probe() {
  local acoustic_deadline_ns

  # The pre-start hook established the Mac lower bound before this XCTest process existed. Require
  # a fresh nonce-bound hosted-call marker before either operator acknowledgement can be accepted.
  # The marker wait and acoustic acknowledgement share one absolute timeout; neither resets it.
  acoustic_deadline_ns=$(acknowledgement_deadline_ns \
    "${CALL_ACOUSTIC_TIMEOUT_SECONDS}") || return $?
  wait_for_nonce_bound_call_ui_hosted_state \
    "${acoustic_deadline_ns}" \
    "${XCODEBUILD_LIVE_STDOUT}" \
    1 \
    - \
    "${RAW_READY_RESUMED_NS}" \
    "${CALL_UI_HOSTED_PRE_ACK_OBSERVATION}" || return $?
  wait_for_fresh_call_acoustic_acknowledgement \
    "${acoustic_deadline_ns}" || return $?
  # XCTest consumes the exact token-bound accepted record while it is still continuously validating
  # interruption-origin hosted playout, then emits sequence 2. A historical pre-ack marker can never
  # authorize an acknowledgement heard after the call has already become ordinary.
  wait_for_nonce_bound_call_ui_hosted_state \
    "${acoustic_deadline_ns}" \
    "${XCODEBUILD_LIVE_STDOUT}" \
    2 \
    "${CALL_ACOUSTIC_ACCEPTED_TOKEN}" \
    "${CALL_ACOUSTIC_ACCEPTED_NS}" \
    "${RAW_UI_CAUSAL_STATE_OBSERVATION}" || return $?
  capture_default_input_snapshot \
    "${RAW_DEFAULT_INPUT_BEFORE}" \
    before \
    "${POST_CALL_RAW_INTER_ACK_SNAPSHOT_BUDGET_SECONDS}" || return $?
  validate_default_input_baseline_json \
    "${RAW_DEFAULT_INPUT_BEFORE}" || return 3
  wait_for_fresh_call_end_acknowledgement || return $?
  wait_for_fresh_raw_session_readiness_and_start_probe
}

function validate_post_call_raw_generation_evidence() {
  local evidence=${CALL_POST_RAW_GENERATION_EVIDENCE}
  local nonce
  local ordinary_policy
  local raw_policy
  local microphone_policy
  local recording
  local approved
  local app_start
  local app_end
  local runtime_start
  local runtime_end
  local runtime_continuity
  local continuity
  local required_continuity_ns
  local uuid_value

  [[ -s "${evidence}" ]] || return 3
  awk -F= '
    BEGIN {
      expected["schema"]=1; expected["nonce"]=1; expected["sessionGeneration"]=1
      expected["ordinaryAudioPolicyGeneration"]=1; expected["rawAudioPolicyGeneration"]=1
      expected["transportAuthorizationGeneration"]=1; expected["windowGeneration"]=1
      expected["microphonePolicyGeneration"]=1; expected["recordingGeneration"]=1
      expected["approvedRecordingGeneration"]=1; expected["appPIDAtStart"]=1
      expected["appPIDAtEnd"]=1; expected["continuityDurationNs"]=1
    }
    {
      key=$1; value=substr($0, length(key) + 2)
      if (!(key in expected) || seen[key]++ || value == "") exit 3
    }
    END { if (NR != 13) exit 3; for (key in expected) if (seen[key] != 1) exit 3 }
  ' "${evidence}" || return 3
  [[ "$(raw_evidence_value "${evidence}" schema)" \
      == "opensteamer.post-call-raw-generation.v1" ]] || return 3
  nonce=$(raw_evidence_value "${evidence}" nonce) || return 3
  [[ "${nonce}" == "${RAW_READY_NONCE}" ]] || return 3
  for uuid_value in \
      "$(raw_evidence_value "${evidence}" sessionGeneration)" \
      "$(raw_evidence_value "${evidence}" ordinaryAudioPolicyGeneration)" \
      "$(raw_evidence_value "${evidence}" rawAudioPolicyGeneration)" \
      "$(raw_evidence_value "${evidence}" transportAuthorizationGeneration)" \
      "$(raw_evidence_value "${evidence}" windowGeneration)"; do
    print -r -- "${uuid_value}" \
      | /usr/bin/grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' \
      || return 3
  done
  ordinary_policy=$(raw_evidence_value "${evidence}" ordinaryAudioPolicyGeneration) || return 3
  raw_policy=$(raw_evidence_value "${evidence}" rawAudioPolicyGeneration) || return 3
  [[ "${ordinary_policy}" == "${raw_policy}" ]] || return 3
  microphone_policy=$(raw_evidence_value "${evidence}" microphonePolicyGeneration) || return 3
  recording=$(raw_evidence_value "${evidence}" recordingGeneration) || return 3
  approved=$(raw_evidence_value "${evidence}" approvedRecordingGeneration) || return 3
  app_start=$(raw_evidence_value "${evidence}" appPIDAtStart) || return 3
  app_end=$(raw_evidence_value "${evidence}" appPIDAtEnd) || return 3
  continuity=$(raw_evidence_value "${evidence}" continuityDurationNs) || return 3
  runtime_start=$(raw_evidence_value "${RAW_UI_RUNTIME_EVIDENCE}" appPIDAtStart) || return 3
  runtime_end=$(raw_evidence_value "${RAW_UI_RUNTIME_EVIDENCE}" appPIDAtEnd) || return 3
  runtime_continuity=$(raw_evidence_value \
    "${RAW_UI_RUNTIME_EVIDENCE}" continuityDurationNs) || return 3
  required_continuity_ns=$((
    POST_CALL_RAW_CONTINUITY_SECONDS * 1000000000
  ))
  [[ "${microphone_policy}" != *[^0-9]* \
      && "${recording}" != *[^0-9]* && "${recording}" == "${approved}" \
      && "${app_start}" != *[^0-9]* && "${app_start}" == "${app_end}" \
      && "${app_start}" == "${runtime_start}" && "${app_end}" == "${runtime_end}" \
      && "${continuity}" != *[^0-9]* \
      && "${runtime_continuity}" != *[^0-9]* \
      && "${continuity}" == "${runtime_continuity}" ]] || return 3
  (( microphone_policy > 0 && recording > 0 \
      && app_start > 0 && continuity >= required_continuity_ns ))
}

function reject_runtime_uid_in_retained_artifacts() {
  opensteamer_run_physical_validation_oracle \
    scan-no-bytes "${ARTIFACT_DIR}" "${PHYSICAL_OUTPUT_UID}"
}

function current_unix_time_ns() {
  opensteamer_run_physical_validation_oracle unix-ns
}

function current_monotonic_time_ns() {
  opensteamer_run_physical_validation_oracle monotonic-ns
}

function raw_evidence_value() {
  local evidence_file=$1
  local key=$2

  [[ -s "${evidence_file}" ]] || return 3
  awk -v key="${key}" '
    index($0, key "=") == 1 {
      count += 1
      value = substr($0, length(key) + 2)
    }
    END {
      if (count != 1) exit 3
      print value
    }
  ' "${evidence_file}"
}

# These local wrappers are exclusive to post-probe continuity. They retain only a bounded suffix
# and share one absolute monotonic deadline across prefix authentication and line reconstruction.
function capture_bounded_raw_continuity_log_snapshot() {
  local log_path=$1
  local expected_identity=$2
  local prior_offset=$3
  local prior_digest=$4
  local appended_output=$5
  local deadline_ns=$6
  local metadata
  local -a metadata_lines

  rm -f "${appended_output}" || return $?
  if ! metadata=$(opensteamer_run_physical_validation_oracle \
      log-snapshot-bounded \
      "${log_path}" \
      "${expected_identity:--}" \
      "${prior_offset}" \
      "${prior_digest}" \
      "${appended_output}" \
      "${deadline_ns}" \
      "${RAW_CONTINUITY_MAX_LOG_DELTA_BYTES}"); then
    rm -f "${appended_output}" || true
    return 1
  fi
  metadata_lines=("${(@f)metadata}")
  if (( ${#metadata_lines[@]} != 4 )) \
      || [[ -z "${metadata_lines[1]}" \
          || "${metadata_lines[2]}" == *[^0-9]* \
          || "${metadata_lines[3]}" == *[^0-9a-f]* \
          || ${#metadata_lines[3]} != 64 \
          || ( "${metadata_lines[4]}" != "0" \
            && "${metadata_lines[4]}" != "1" ) ]]; then
    rm -f "${appended_output}" || true
    return 1
  fi
  OPENSTEAMER_LOG_SNAPSHOT_ID=${metadata_lines[1]}
  OPENSTEAMER_LOG_SNAPSHOT_OFFSET=${metadata_lines[2]}
  OPENSTEAMER_LOG_SNAPSHOT_DIGEST=${metadata_lines[3]}
  OPENSTEAMER_LOG_SNAPSHOT_ENDS_WITH_NEWLINE=${metadata_lines[4]}
}

function split_bounded_raw_continuity_log_lines() {
  local appended_input=$1
  local partial_state=$2
  local completed_output=$3
  local deadline_ns=$4

  opensteamer_run_physical_validation_oracle \
    split-lines-bounded \
    "${appended_input}" \
    "${partial_state}" \
    "${completed_output}" \
    "${deadline_ns}" \
    "${RAW_CONTINUITY_MAX_LOG_DELTA_BYTES}" \
    "${RAW_CONTINUITY_MAX_PARTIAL_BYTES}"
}

function raw_continuity_require_before_deadline() {
  local deadline_ns=$1
  local current_ns

  current_ns=$(current_monotonic_time_ns) || return $?
  [[ -n "${current_ns}" && "${current_ns}" != *[^0-9]* ]] \
      && (( current_ns < deadline_ns ))
}

# Reject every transport, route, writer, or forwarding transition that contradicts the tuple
# frozen at probe launch. Positive observations are counted only after the wrapper completion has
# been parsed and a fresh authenticated log checkpoint has been armed.
function audit_raw_session_continuity_lines() {
  local completed_lines=$1
  local expected_host_pid=$2
  local expected_routing_epoch=$3
  local expected_peer_generation=$4
  local expected_device_generation=$5
  local accept_positive_observations=$6
  local line
  local expected_peer_state="Worldwide WebRTC peer state: connected pid=${expected_host_pid}"
  local expected_route="Worldwide authenticated media route selected BlackHole default input routingEpoch=${expected_routing_epoch} peerGeneration=${expected_peer_generation} deviceGeneration=${expected_device_generation} pid=${expected_host_pid}"
  local expected_writer="Worldwide iPhone microphone hidden writer selected routingEpoch=${expected_routing_epoch} peerGeneration=${expected_peer_generation} deviceGeneration=${expected_device_generation} pid=${expected_host_pid}"
  local healthy_forwarding="Worldwide iPhone microphone forwarding phase=forwardingHealthy inputEndpointAvailable=true hiddenSinkAvailable=true hiddenWriterSelectionProven=true transport=true trackAdmitted=true queueRunning=true "
  local progress_fields
  local callback_count
  local pull_count
  local frame_count
  local remaining_fields

  while IFS= read -r line; do
    if [[ "${line}" == *"Worldwide WebRTC peer state: "* ]]; then
      [[ "${line}" == *"${expected_peer_state}" ]] || return 4
    fi
    if [[ "${line}" == *"Worldwide authenticated media route selected BlackHole default input routingEpoch="* ]]; then
      [[ "${line}" == *"${expected_route}" ]] || return 4
    fi
    if [[ "${line}" == *"Worldwide iPhone microphone hidden writer selected routingEpoch="* ]]; then
      [[ "${line}" == *"${expected_writer}" ]] || return 4
      if (( accept_positive_observations != 0 )); then
        RAW_CONTINUITY_CURRENT_WRITER_OBSERVATIONS=$((
          RAW_CONTINUITY_CURRENT_WRITER_OBSERVATIONS + 1
        ))
      fi
    fi
    if [[ "${line}" == *"Worldwide iPhone microphone forwarding phase="* ]]; then
      [[ "${line}" == *"${healthy_forwarding}"* ]] || return 4
      if (( accept_positive_observations != 0 )); then
        progress_fields=$(
          print -r -- "${line}" \
            | /usr/bin/sed -E \
                's/.* callbacks=([0-9]+) pulls=([0-9]+) frames=([0-9]+).*/\1 \2 \3/'
        ) || return $?
        callback_count=${progress_fields%% *}
        remaining_fields=${progress_fields#* }
        pull_count=${remaining_fields%% *}
        frame_count=${remaining_fields##* }
        [[ -n "${callback_count}" \
            && "${callback_count}" != *[^0-9]* \
            && -n "${pull_count}" \
            && "${pull_count}" != *[^0-9]* \
            && -n "${frame_count}" \
            && "${frame_count}" != *[^0-9]* ]] || return 4
        if [[ -z "${RAW_CONTINUITY_LAST_CALLBACK_COUNT}" ]]; then
          RAW_CONTINUITY_FIRST_CALLBACK_COUNT=${callback_count}
          RAW_CONTINUITY_FIRST_PULL_COUNT=${pull_count}
          RAW_CONTINUITY_FIRST_FRAME_COUNT=${frame_count}
          RAW_CONTINUITY_LAST_CALLBACK_COUNT=${callback_count}
          RAW_CONTINUITY_LAST_PULL_COUNT=${pull_count}
          RAW_CONTINUITY_LAST_FRAME_COUNT=${frame_count}
          RAW_CONTINUITY_CURRENT_AUTHORIZATION_OBSERVATIONS=1
        elif (( callback_count < RAW_CONTINUITY_LAST_CALLBACK_COUNT \
            || pull_count < RAW_CONTINUITY_LAST_PULL_COUNT \
            || frame_count < RAW_CONTINUITY_LAST_FRAME_COUNT )); then
          return 4
        elif (( callback_count > RAW_CONTINUITY_LAST_CALLBACK_COUNT \
            && pull_count > RAW_CONTINUITY_LAST_PULL_COUNT \
            && frame_count > RAW_CONTINUITY_LAST_FRAME_COUNT )); then
          RAW_CONTINUITY_LAST_CALLBACK_COUNT=${callback_count}
          RAW_CONTINUITY_LAST_PULL_COUNT=${pull_count}
          RAW_CONTINUITY_LAST_FRAME_COUNT=${frame_count}
          RAW_CONTINUITY_CURRENT_AUTHORIZATION_OBSERVATIONS=$((
            RAW_CONTINUITY_CURRENT_AUTHORIZATION_OBSERVATIONS + 1
          ))
        fi
      fi
    fi
    if [[ "${line}" == *"Worldwide microphone routing was revoked because "* \
        || "${line}" == *"iPhone microphone forwarding encountered an output runtime failure"* ]]; then
      return 4
    fi
  done < "${completed_lines}"
}

function cleanup_raw_session_continuity_scratch() {
  rm -f \
    "${RAW_READY_CONTINUITY_LOG_APPEND_CHUNK}" \
    "${RAW_READY_CONTINUITY_LOG_COMPLETED_LINES}" \
    "${RAW_READY_CONTINUITY_LOG_PARTIAL_LINE}"
}

# The physical probe can succeed from buffers admitted before a route change. Re-read the exact
# append-only host-log suffix after completion, reject any intervening contradiction, then require
# two new current healthy-forwarding snapshots and matching hidden-writer selections under the same
# host PID/routing epoch/peer generation/device generation. The single absolute monotonic deadline
# bounds the complete post-completion observation window.
function revalidate_raw_session_continuity_after_probe() {
  local probe_end_ns=$1
  local readiness_schema
  local expected_nonce
  local expected_host_pid
  local expected_routing_epoch
  local expected_peer_generation
  local expected_device_generation
  local cursor_identity
  local start_cursor_offset
  local start_cursor_digest
  local start_cursor_partial_bytes
  local start_cursor_partial_digest
  local cursor_offset
  local cursor_digest
  local observed_cursor_partial_bytes
  local observed_cursor_partial_digest
  local current_process_id
  local revalidation_started_ns
  local revalidation_deadline_ns
  local observed_at_ns
  local final_drain_completed_at_ns
  local maximum_wait_ns
  local readiness_bytes
  local evidence_temporary="${RAW_READY_CONTINUITY_EVIDENCE}.tmp.$$"
  local command_status

  [[ -n "${probe_end_ns}" && "${probe_end_ns}" != *[^0-9]* ]] \
      && (( probe_end_ns > 0 )) || return 3
  maximum_wait_ns=$((
    RAW_CONTINUITY_REVALIDATION_TIMEOUT_SECONDS * 1000000000
  ))
  revalidation_started_ns=$(current_monotonic_time_ns) || return $?
  [[ -n "${revalidation_started_ns}" \
      && "${revalidation_started_ns}" != *[^0-9]* ]] \
      && (( revalidation_started_ns > probe_end_ns )) || return 3
  revalidation_deadline_ns=$((revalidation_started_ns + maximum_wait_ns))
  (( revalidation_deadline_ns > revalidation_started_ns )) || return 3

  # Establish the only post-completion deadline before parsing, hashing, copying, or authenticating
  # any evidence. The readiness record itself is also size-bounded before awk sees it.
  [[ -f "${RAW_READY_EVIDENCE}" && ! -L "${RAW_READY_EVIDENCE}" ]] \
    || return 3
  readiness_bytes=$(/usr/bin/stat -f '%z' "${RAW_READY_EVIDENCE}") \
    || return $?
  [[ -n "${readiness_bytes}" && "${readiness_bytes}" != *[^0-9]* ]] \
      && (( readiness_bytes > 0 \
        && readiness_bytes <= RAW_CONTINUITY_MAX_EVIDENCE_BYTES )) \
    || return 3
  raw_continuity_require_before_deadline "${revalidation_deadline_ns}" \
    || return 124
  readiness_schema=$(raw_evidence_value "${RAW_READY_EVIDENCE}" schema) \
    || return 3
  expected_nonce=$(raw_evidence_value "${RAW_READY_EVIDENCE}" nonce) \
    || return 3
  expected_host_pid=$(raw_evidence_value "${RAW_READY_EVIDENCE}" hostPID) \
    || return 3
  expected_routing_epoch=$(raw_evidence_value \
    "${RAW_READY_EVIDENCE}" blackHoleRoutingEpoch) || return 3
  expected_peer_generation=$(raw_evidence_value \
    "${RAW_READY_EVIDENCE}" blackHolePeerGeneration) || return 3
  expected_device_generation=$(raw_evidence_value \
    "${RAW_READY_EVIDENCE}" blackHoleDeviceGeneration) || return 3
  cursor_identity=$(raw_evidence_value \
    "${RAW_READY_EVIDENCE}" cursorIdentity) || return 3
  start_cursor_offset=$(raw_evidence_value \
    "${RAW_READY_EVIDENCE}" cursorOffset) || return 3
  start_cursor_digest=$(raw_evidence_value \
    "${RAW_READY_EVIDENCE}" cursorDigest) || return 3
  start_cursor_partial_bytes=$(raw_evidence_value \
    "${RAW_READY_EVIDENCE}" cursorPartialBytes) || return 3
  start_cursor_partial_digest=$(raw_evidence_value \
    "${RAW_READY_EVIDENCE}" cursorPartialDigest) || return 3
  [[ "${readiness_schema}" == "opensteamer.raw-session-readiness.v5" \
      && "${expected_nonce}" == "${RAW_READY_NONCE}" \
      && -n "${cursor_identity}" \
      && -n "${expected_host_pid}" \
      && "${expected_host_pid}" != *[^0-9]* \
      && -n "${expected_routing_epoch}" \
      && ${#expected_routing_epoch} -eq 32 \
      && "${expected_routing_epoch}" != *[^0-9a-f]* \
      && -n "${expected_peer_generation}" \
      && "${expected_peer_generation}" != *[^0-9]* \
      && -n "${expected_device_generation}" \
      && "${expected_device_generation}" != *[^0-9]* \
      && -n "${start_cursor_offset}" \
      && "${start_cursor_offset}" != *[^0-9]* \
      && ${#start_cursor_digest} -eq 64 \
      && "${start_cursor_digest}" != *[^0-9a-f]* \
      && -n "${start_cursor_partial_bytes}" \
      && "${start_cursor_partial_bytes}" != *[^0-9]* \
      && ${#start_cursor_partial_digest} -eq 64 \
      && "${start_cursor_partial_digest}" != *[^0-9a-f]* \
      && start_cursor_partial_bytes -le RAW_CONTINUITY_MAX_PARTIAL_BYTES ]] \
      && (( expected_host_pid > 0 \
        && expected_peer_generation > 0 \
        && expected_device_generation > 0 )) || return 3

  raw_continuity_require_before_deadline "${revalidation_deadline_ns}" \
    || return 124
  rm -f \
    "${RAW_READY_CONTINUITY_EVIDENCE}" \
    "${RAW_READY_CONTINUITY_ARMED_MARKER}" \
    "${evidence_temporary}" || return $?
  cleanup_raw_session_continuity_scratch || return $?
  [[ -f "${RAW_HOST_LOG_PARTIAL_LINE}" \
      && ! -L "${RAW_HOST_LOG_PARTIAL_LINE}" ]] || return 3
  observed_cursor_partial_bytes=$(
    /usr/bin/stat -f '%z' "${RAW_HOST_LOG_PARTIAL_LINE}"
  ) || return $?
  [[ -n "${observed_cursor_partial_bytes}" \
      && "${observed_cursor_partial_bytes}" != *[^0-9]* ]] \
      && (( observed_cursor_partial_bytes <= RAW_CONTINUITY_MAX_PARTIAL_BYTES )) \
    || return 3
  raw_continuity_require_before_deadline "${revalidation_deadline_ns}" \
    || return 124
  observed_cursor_partial_digest=$(
    /usr/bin/shasum -a 256 "${RAW_HOST_LOG_PARTIAL_LINE}" \
      | /usr/bin/awk '{print $1}'
  ) || return $?
  [[ "${observed_cursor_partial_bytes}" == "${start_cursor_partial_bytes}" \
      && "${observed_cursor_partial_digest}" \
        == "${start_cursor_partial_digest}" ]] || return 4
  /bin/cp \
    "${RAW_HOST_LOG_PARTIAL_LINE}" \
    "${RAW_READY_CONTINUITY_LOG_PARTIAL_LINE}" || return $?
  raw_continuity_require_before_deadline "${revalidation_deadline_ns}" \
    || return 124
  cursor_offset=${start_cursor_offset}
  cursor_digest=${start_cursor_digest}
  current_process_id=$(current_host_pid)
  [[ "${current_process_id}" == "${expected_host_pid}" ]] || return 4

  # First consume the complete launch-to-completion suffix. A positive record in this suffix is
  # not sufficient: acceptance requires a separate observation after this checkpoint.
  if ! capture_bounded_raw_continuity_log_snapshot \
      "${HOST_LOG}" \
      "${cursor_identity}" \
      "${cursor_offset}" \
      "${cursor_digest}" \
      "${RAW_READY_CONTINUITY_LOG_APPEND_CHUNK}" \
      "${revalidation_deadline_ns}" \
      || ! split_bounded_raw_continuity_log_lines \
        "${RAW_READY_CONTINUITY_LOG_APPEND_CHUNK}" \
        "${RAW_READY_CONTINUITY_LOG_PARTIAL_LINE}" \
        "${RAW_READY_CONTINUITY_LOG_COMPLETED_LINES}" \
        "${revalidation_deadline_ns}" \
      || ! opensteamer_audit_connected_log_lines \
        "${RAW_READY_CONTINUITY_LOG_COMPLETED_LINES}" \
        "${expected_host_pid}" \
        "${current_process_id}" \
      || ! audit_raw_session_continuity_lines \
        "${RAW_READY_CONTINUITY_LOG_COMPLETED_LINES}" \
        "${expected_host_pid}" \
        "${expected_routing_epoch}" \
        "${expected_peer_generation}" \
        "${expected_device_generation}" \
        0; then
    command_status=4
    cleanup_raw_session_continuity_scratch || true
    return "${command_status}"
  fi
  cursor_offset=${OPENSTEAMER_LOG_SNAPSHOT_OFFSET}
  cursor_digest=${OPENSTEAMER_LOG_SNAPSHOT_DIGEST}
  rm -f \
    "${RAW_READY_CONTINUITY_LOG_APPEND_CHUNK}" \
    "${RAW_READY_CONTINUITY_LOG_COMPLETED_LINES}" || return $?
  raw_continuity_require_before_deadline "${revalidation_deadline_ns}" \
    || return 124
  opensteamer_write_state \
    "${RAW_READY_CONTINUITY_ARMED_MARKER}" \
    "state=armed nonce=${expected_nonce} revalidationStartedAtMonotonicNs=${revalidation_started_ns}" \
    || return $?

  RAW_CONTINUITY_CURRENT_WRITER_OBSERVATIONS=0
  RAW_CONTINUITY_CURRENT_AUTHORIZATION_OBSERVATIONS=0
  RAW_CONTINUITY_FIRST_CALLBACK_COUNT=""
  RAW_CONTINUITY_FIRST_PULL_COUNT=""
  RAW_CONTINUITY_FIRST_FRAME_COUNT=""
  RAW_CONTINUITY_LAST_CALLBACK_COUNT=""
  RAW_CONTINUITY_LAST_PULL_COUNT=""
  RAW_CONTINUITY_LAST_FRAME_COUNT=""
  while true; do
    observed_at_ns=$(current_monotonic_time_ns) || return $?
    [[ -n "${observed_at_ns}" \
        && "${observed_at_ns}" != *[^0-9]* ]] || return 3
    if (( observed_at_ns >= revalidation_deadline_ns )); then
      cleanup_raw_session_continuity_scratch || true
      return 124
    fi
    current_process_id=$(current_host_pid)
    if [[ "${current_process_id}" != "${expected_host_pid}" ]]; then
      cleanup_raw_session_continuity_scratch || true
      return 4
    fi
    if ! capture_bounded_raw_continuity_log_snapshot \
        "${HOST_LOG}" \
        "${cursor_identity}" \
        "${cursor_offset}" \
        "${cursor_digest}" \
        "${RAW_READY_CONTINUITY_LOG_APPEND_CHUNK}" \
        "${revalidation_deadline_ns}" \
        || ! split_bounded_raw_continuity_log_lines \
          "${RAW_READY_CONTINUITY_LOG_APPEND_CHUNK}" \
          "${RAW_READY_CONTINUITY_LOG_PARTIAL_LINE}" \
          "${RAW_READY_CONTINUITY_LOG_COMPLETED_LINES}" \
          "${revalidation_deadline_ns}" \
        || ! opensteamer_audit_connected_log_lines \
          "${RAW_READY_CONTINUITY_LOG_COMPLETED_LINES}" \
          "${expected_host_pid}" \
          "${current_process_id}" \
        || ! audit_raw_session_continuity_lines \
          "${RAW_READY_CONTINUITY_LOG_COMPLETED_LINES}" \
          "${expected_host_pid}" \
          "${expected_routing_epoch}" \
          "${expected_peer_generation}" \
          "${expected_device_generation}" \
          1; then
      command_status=4
      cleanup_raw_session_continuity_scratch || true
      return "${command_status}"
    fi
    cursor_offset=${OPENSTEAMER_LOG_SNAPSHOT_OFFSET}
    cursor_digest=${OPENSTEAMER_LOG_SNAPSHOT_DIGEST}
    observed_cursor_partial_bytes=$(
      /usr/bin/stat -f '%z' "${RAW_READY_CONTINUITY_LOG_PARTIAL_LINE}"
    ) || return $?
    [[ -n "${observed_cursor_partial_bytes}" \
        && "${observed_cursor_partial_bytes}" != *[^0-9]* ]] \
        && (( observed_cursor_partial_bytes <= RAW_CONTINUITY_MAX_PARTIAL_BYTES )) \
      || return 3
    raw_continuity_require_before_deadline "${revalidation_deadline_ns}" \
      || return 124
    observed_cursor_partial_digest=$(
      /usr/bin/shasum -a 256 "${RAW_READY_CONTINUITY_LOG_PARTIAL_LINE}" \
        | /usr/bin/awk '{print $1}'
    ) || return $?
    [[ -n "${observed_cursor_partial_bytes}" \
        && "${observed_cursor_partial_bytes}" != *[^0-9]* \
        && ${#observed_cursor_partial_digest} -eq 64 \
        && "${observed_cursor_partial_digest}" != *[^0-9a-f]* ]] \
      || return 3
    rm -f \
      "${RAW_READY_CONTINUITY_LOG_APPEND_CHUNK}" \
      "${RAW_READY_CONTINUITY_LOG_COMPLETED_LINES}" || return $?
    if (( RAW_CONTINUITY_CURRENT_WRITER_OBSERVATIONS >= 2 \
        && RAW_CONTINUITY_CURRENT_AUTHORIZATION_OBSERVATIONS >= 2 \
        && observed_cursor_partial_bytes == 0 )); then
      current_process_id=$(current_host_pid)
      [[ "${current_process_id}" == "${expected_host_pid}" ]] || return 4
      # The claimed observation time is sampled before one final authenticated drain. Any
      # transition appended at or before this instant must therefore be present in the retained
      # end cursor and is audited before publication.
      observed_at_ns=$(current_monotonic_time_ns) || return $?
      [[ -n "${observed_at_ns}" \
          && "${observed_at_ns}" != *[^0-9]* ]] \
          && (( observed_at_ns > revalidation_started_ns \
            && observed_at_ns < revalidation_deadline_ns )) || return 124
      if ! capture_bounded_raw_continuity_log_snapshot \
          "${HOST_LOG}" \
          "${cursor_identity}" \
          "${cursor_offset}" \
          "${cursor_digest}" \
          "${RAW_READY_CONTINUITY_LOG_APPEND_CHUNK}" \
          "${revalidation_deadline_ns}" \
          || ! split_bounded_raw_continuity_log_lines \
            "${RAW_READY_CONTINUITY_LOG_APPEND_CHUNK}" \
            "${RAW_READY_CONTINUITY_LOG_PARTIAL_LINE}" \
            "${RAW_READY_CONTINUITY_LOG_COMPLETED_LINES}" \
            "${revalidation_deadline_ns}" \
          || ! opensteamer_audit_connected_log_lines \
            "${RAW_READY_CONTINUITY_LOG_COMPLETED_LINES}" \
            "${expected_host_pid}" \
            "${current_process_id}" \
          || ! audit_raw_session_continuity_lines \
            "${RAW_READY_CONTINUITY_LOG_COMPLETED_LINES}" \
            "${expected_host_pid}" \
            "${expected_routing_epoch}" \
            "${expected_peer_generation}" \
            "${expected_device_generation}" \
            1; then
        cleanup_raw_session_continuity_scratch || true
        return 4
      fi
      cursor_offset=${OPENSTEAMER_LOG_SNAPSHOT_OFFSET}
      cursor_digest=${OPENSTEAMER_LOG_SNAPSHOT_DIGEST}
      observed_cursor_partial_bytes=$(
        /usr/bin/stat -f '%z' "${RAW_READY_CONTINUITY_LOG_PARTIAL_LINE}"
      ) || return $?
      [[ "${observed_cursor_partial_bytes}" == "0" ]] || return 4
      observed_cursor_partial_digest=$(
        /usr/bin/shasum -a 256 "${RAW_READY_CONTINUITY_LOG_PARTIAL_LINE}" \
          | /usr/bin/awk '{print $1}'
      ) || return $?
      [[ "${observed_cursor_partial_digest}" \
          == "$(opensteamer_empty_sha256)" ]] || return 4
      rm -f \
        "${RAW_READY_CONTINUITY_LOG_APPEND_CHUNK}" \
        "${RAW_READY_CONTINUITY_LOG_COMPLETED_LINES}" || return $?
      current_process_id=$(current_host_pid)
      [[ "${current_process_id}" == "${expected_host_pid}" ]] || return 4
      final_drain_completed_at_ns=$(current_monotonic_time_ns) || return $?
      [[ -n "${final_drain_completed_at_ns}" \
          && "${final_drain_completed_at_ns}" != *[^0-9]* ]] \
          && (( final_drain_completed_at_ns > observed_at_ns \
            && final_drain_completed_at_ns < revalidation_deadline_ns )) \
        || return 124
      {
        print -r -- "schema=opensteamer.raw-session-continuity.v2"
        print -r -- "nonce=${expected_nonce}"
        print -r -- "probeEndMonotonicNs=${probe_end_ns}"
        print -r -- \
          "revalidationStartedAtMonotonicNs=${revalidation_started_ns}"
        print -r -- "observedAtMonotonicNs=${observed_at_ns}"
        print -r -- \
          "finalDrainCompletedAtMonotonicNs=${final_drain_completed_at_ns}"
        print -r -- "maximumWaitNs=${maximum_wait_ns}"
        print -r -- "hostPID=${expected_host_pid}"
        print -r -- "blackHoleRoutingEpoch=${expected_routing_epoch}"
        print -r -- \
          "blackHolePeerGeneration=${expected_peer_generation}"
        print -r -- \
          "blackHoleDeviceGeneration=${expected_device_generation}"
        print -r -- "hiddenWriterSelectionProven=true"
        print -r -- "transportAuthorized=true"
        print -r -- "trackAdmitted=true"
        print -r -- "queueRunning=true"
        print -r -- \
          "writerSelectionObservationCount=${RAW_CONTINUITY_CURRENT_WRITER_OBSERVATIONS}"
        print -r -- \
          "authorizationObservationCount=${RAW_CONTINUITY_CURRENT_AUTHORIZATION_OBSERVATIONS}"
        print -r -- \
          "firstCallbackCount=${RAW_CONTINUITY_FIRST_CALLBACK_COUNT}"
        print -r -- "lastCallbackCount=${RAW_CONTINUITY_LAST_CALLBACK_COUNT}"
        print -r -- "firstPullCount=${RAW_CONTINUITY_FIRST_PULL_COUNT}"
        print -r -- "lastPullCount=${RAW_CONTINUITY_LAST_PULL_COUNT}"
        print -r -- "firstFrameCount=${RAW_CONTINUITY_FIRST_FRAME_COUNT}"
        print -r -- "lastFrameCount=${RAW_CONTINUITY_LAST_FRAME_COUNT}"
        print -r -- "startCursorIdentity=${cursor_identity}"
        print -r -- "startCursorOffset=${start_cursor_offset}"
        print -r -- "startCursorDigest=${start_cursor_digest}"
        print -r -- \
          "startCursorPartialBytes=${start_cursor_partial_bytes}"
        print -r -- \
          "startCursorPartialDigest=${start_cursor_partial_digest}"
        print -r -- "endCursorOffset=${cursor_offset}"
        print -r -- "endCursorDigest=${cursor_digest}"
        print -r -- \
          "endCursorPartialBytes=${observed_cursor_partial_bytes}"
        print -r -- \
          "endCursorPartialDigest=${observed_cursor_partial_digest}"
      } > "${evidence_temporary}" || return $?
      mv "${evidence_temporary}" "${RAW_READY_CONTINUITY_EVIDENCE}" \
        || return $?
      cleanup_raw_session_continuity_scratch || return $?
      return 0
    fi
    sleep 0.05
  done
}

function clear_raw_overlap_success_evidence() {
  if [[ "${RAW_PROOF_CONTEXT:-}" == "post-call" ]]; then
    rm -f "${CALL_UI_HOSTED_PRE_ACK_OBSERVATION}" || return $?
  fi
  if [[ -n "${RAW_UI_CAUSAL_STATE_OBSERVATION:-}" ]]; then
    rm -f "${RAW_UI_CAUSAL_STATE_OBSERVATION}" || return $?
  fi
  rm -f \
    "${RAW_UI_RUNTIME_ATTACHMENT_PAYLOAD_ID}" \
    "${RAW_UI_RUNTIME_EVIDENCE}" \
    "${RAW_UI_COMPLETION_OBSERVATION}" \
    "${RAW_UI_BOUNDS_EVIDENCE}" \
    "${RAW_PROBE_PROCESS_START_EVIDENCE}" \
    "${RAW_PROBE_PROCESS_COMPLETION_EVIDENCE}" \
    "${RAW_PROBE_COMPLETION_OBSERVATION}" \
    "${RAW_PROBE_WAIT_EVIDENCE}" \
    "${RAW_READY_CONTINUITY_EVIDENCE}" \
    "${RAW_READY_CONTINUITY_ARMED_MARKER}" \
    "${RAW_READY_CONTINUITY_LOG_APPEND_CHUNK}" \
    "${RAW_READY_CONTINUITY_LOG_COMPLETED_LINES}" \
    "${RAW_READY_CONTINUITY_LOG_PARTIAL_LINE}" \
    "${RAW_PROBE_INTERVAL_EVIDENCE}" \
    "${RAW_PROBE_OVERLAP_MARKER}" \
    "${RAW_BLACKHOLE_PROBE_COMPLETION}"
}

function reset_raw_overlap_evidence() {
  clear_raw_overlap_success_evidence || return $?
  rm -f "${RAW_PROBE_NON_OVERLAP_MARKER}"
}

function record_raw_overlap_failure() {
  local state=$1
  local failure_status=${2:-1}

  clear_raw_overlap_success_evidence 2>/dev/null || true
  opensteamer_write_state \
    "${RAW_PROBE_NON_OVERLAP_MARKER}" \
    "schema=opensteamer.raw-blackhole-overlap-failure.v1 state=${state} status=${failure_status} nonce=${RAW_READY_NONCE:-missing}" \
    2>/dev/null || true
}

function prepare_raw_overlap_contract() {
  reset_raw_overlap_evidence || return $?
  RAW_READY_NONCE=$(fresh_raw_ready_nonce) || return $?
  if [[ -z "${RAW_READY_NONCE}" \
      || ${#RAW_READY_NONCE} -lt 16 \
      || ${#RAW_READY_NONCE} -gt 128 \
      || "${RAW_READY_NONCE}" == *[^A-Za-z0-9-]* ]]; then
    return 3
  fi
  typeset -gx \
    OPENSTEAMER_RAW_CONTINUITY_PROOF_NONCE="${RAW_READY_NONCE}"
  if [[ "${RAW_PROOF_CONTEXT}" == "post-call" ]]; then
    typeset -gx \
      OPENSTEAMER_POST_CALL_RAW_CONTINUITY_PROOF_NONCE="${RAW_READY_NONCE}" \
      OPENSTEAMER_POST_CALL_RAW_CONTINUITY_SECONDS="${POST_CALL_RAW_CONTINUITY_SECONDS}" \
      OPENSTEAMER_POST_CALL_RAW_UI_TIMEOUT_SECONDS="${POST_CALL_RAW_UI_TIMEOUT_SECONDS}" \
      OPENSTEAMER_CALL_ACOUSTIC_REQUEST_PATH="${CALL_ACOUSTIC_REQUEST}" \
      OPENSTEAMER_CALL_ACOUSTIC_STATUS_PATH="${CALL_ACOUSTIC_STATUS}" \
      OPENSTEAMER_CALL_ACOUSTIC_TIMEOUT_SECONDS="${CALL_ACOUSTIC_TIMEOUT_SECONDS}"
  fi
  BLACKHOLE_PROBE_NONCE="${RAW_READY_NONCE}"
  RAW_READY_REQUESTED_NS=0
  RAW_READY_RESUMED_NS=0
  RAW_PROBE_STARTED_NS=0
  RAW_PROBE_BOUND_PID=""
  CALL_ACOUSTIC_ACCEPTED_NS=0
  CALL_ACOUSTIC_ACCEPTED_TOKEN=""
}

function fresh_raw_ready_nonce() {
  if [[ -n "${OPENSTEAMER_SELF_TEST_RAW_READINESS:-}" ]]; then
    print -r -- "raw-readiness-self-test-token"
    return 0
  fi
  print -r -- \
    "raw-ready-$(
      /usr/bin/uuidgen \
        | tr '[:upper:]' '[:lower:]'
    )"
}

function parse_raw_probe_completion_file() {
  local expected_nonce=${1:-unbound}
  local expected_start=${2:-0}
  local expected_pid=${3:-0}

  opensteamer_run_physical_validation_oracle \
    parse-completion \
    "${RAW_BLACKHOLE_PROBE_COMPLETION}" \
    "${expected_nonce}" \
    "${expected_start}" \
    "${expected_pid}"
}

function capture_raw_probe_completion_observation() {
  local completion_fields
  local probe_end_ns
  local completion_status
  local completion_pid
  local completion_observed_ns
  local readiness_schema
  local readiness_nonce
  local expected_probe_start
  local expected_production_pid
  local continuity_status
  local temporary="${RAW_PROBE_COMPLETION_OBSERVATION}.tmp.$$"

  # This function runs in the watchdog subprocess, which was forked before the parent starts the
  # probe. Bind completion to the atomically published readiness record instead of stale fork-time
  # shell globals (which are intentionally still zero in the watchdog).
  readiness_schema=$(raw_evidence_value \
    "${RAW_READY_EVIDENCE}" schema) || return 3
  readiness_nonce=$(raw_evidence_value \
    "${RAW_READY_EVIDENCE}" nonce) || return 3
  expected_probe_start=$(raw_evidence_value \
    "${RAW_READY_EVIDENCE}" probeStartedAtMonotonicNs) || return 3
  expected_production_pid=$(raw_evidence_value \
    "${RAW_READY_EVIDENCE}" productionPID) || return 3
  [[ "${readiness_schema}" == "opensteamer.raw-session-readiness.v5" \
      && "${readiness_nonce}" == "${RAW_READY_NONCE}" \
      && "${expected_probe_start}" != *[^0-9]* \
      && "${expected_production_pid}" != *[^0-9]* ]] \
      && (( expected_probe_start > 0 && expected_production_pid > 0 )) \
    || return 3
  completion_fields=$(
    parse_raw_probe_completion_file \
      "${RAW_READY_NONCE}" \
      "${expected_probe_start}" \
      "${expected_production_pid}"
  ) || return 3
  probe_end_ns=${completion_fields%% *}
  completion_status=${completion_fields##* }
  if (( completion_status != 0 )); then
    return "${completion_status}"
  fi
  completion_pid=$(capture_raw_probe_production_identity completion) || return $?
  [[ "${completion_pid}" == "${expected_production_pid}" ]] || return 3
  completion_observed_ns=$(raw_evidence_value \
    "${RAW_PROBE_PROCESS_COMPLETION_EVIDENCE}" observedAtMonotonicNs) \
    || return 3
  if [[ -z "${completion_observed_ns}" \
      || "${completion_observed_ns}" == *[^0-9]* ]] \
      || (( completion_observed_ns < probe_end_ns )); then
    return 3
  fi
  # This watchdog still overlaps the live XCTest/app session. Prove the exact host/writer tuple
  # now; the parent intentionally does not defer this check until XCTest has disconnected.
  if revalidate_raw_session_continuity_after_probe "${probe_end_ns}"; then
    :
  else
    continuity_status=$?
    return "${continuity_status}"
  fi
  {
    print -r -- \
      "schema=opensteamer.blackhole-probe-completion-observation.v1"
    print -r -- "nonce=${RAW_READY_NONCE}"
    print -r -- "probeEndMonotonicNs=${probe_end_ns}"
    print -r -- \
      "completionObservedAtMonotonicNs=${completion_observed_ns}"
    print -r -- "status=0"
    print -r -- "productionPIDAtCompletion=${completion_pid}"
  } > "${temporary}" || return $?
  mv "${temporary}" "${RAW_PROBE_COMPLETION_OBSERVATION}"
}

function initialize_raw_session_readiness() {
  local empty_digest
  local request_temporary="${RAW_READY_REQUEST}.tmp.$$"
  local command_status

  clear_raw_overlap_success_evidence || return $?

  rm -f \
    "${RAW_READY_REQUEST}" \
    "${RAW_READY_RESUMED_MARKER}" \
    "${RAW_READY_STATUS}" \
    "${RAW_READY_TIMEOUT_MARKER}" \
    "${RAW_READY_STALE_MARKER}" \
    "${RAW_READY_CONTINUITY_EVIDENCE}" \
    "${RAW_READY_CONTINUITY_ARMED_MARKER}" \
    "${RAW_READY_CONTINUITY_LOG_APPEND_CHUNK}" \
    "${RAW_READY_CONTINUITY_LOG_COMPLETED_LINES}" \
    "${RAW_READY_CONTINUITY_LOG_PARTIAL_LINE}" \
    "${RAW_HOST_LOG_APPEND_CHUNK}" \
    "${RAW_HOST_LOG_COMPLETED_LINES}" \
    "${RAW_HOST_LOG_PARTIAL_LINE}" || return $?
  if [[ -e "${RAW_READY_EVIDENCE}" ]]; then
    rm -f "${RAW_READY_EVIDENCE}" || return $?
    opensteamer_write_state \
      "${RAW_READY_STALE_MARKER}" "state=discarded-before-arm" || return $?
  fi

  empty_digest=$(opensteamer_empty_sha256) || return $?
  if opensteamer_capture_log_snapshot \
      "${HOST_LOG}" \
      "" \
      0 \
      "${empty_digest}" \
      "${RAW_HOST_LOG_APPEND_CHUNK}"; then
    :
  else
    command_status=$?
    return "${command_status}"
  fi
  if [[ "${OPENSTEAMER_LOG_SNAPSHOT_ENDS_WITH_NEWLINE}" != "1" ]]; then
    return 3
  fi
  RAW_HOST_LOG_START_ID=${OPENSTEAMER_LOG_SNAPSHOT_ID}
  RAW_HOST_LOG_START_OFFSET=${OPENSTEAMER_LOG_SNAPSHOT_OFFSET}
  RAW_HOST_LOG_START_DIGEST=${OPENSTEAMER_LOG_SNAPSHOT_DIGEST}
  rm -f "${RAW_HOST_LOG_APPEND_CHUNK}"
  print -rn -- "" > "${RAW_HOST_LOG_PARTIAL_LINE}" || return $?

  if [[ -z "${RAW_READY_NONCE}" \
      || ${#RAW_READY_NONCE} -lt 16 \
      || ${#RAW_READY_NONCE} -gt 128 \
      || "${RAW_READY_NONCE}" == *[^A-Za-z0-9-]* ]]; then
    return 3
  fi
  RAW_READY_REQUESTED_NS=$(current_monotonic_time_ns) || return $?
  if [[ -z "${RAW_READY_REQUESTED_NS}" \
      || "${RAW_READY_REQUESTED_NS}" == *[^0-9]* ]]; then
    return 3
  fi
  {
    print -r -- "schema=opensteamer.raw-session-readiness.v3"
    print -r -- "nonce=${RAW_READY_NONCE}"
    print -r -- "requestedAtMonotonicNs=${RAW_READY_REQUESTED_NS}"
    print -r -- "cursorIdentity=${RAW_HOST_LOG_START_ID}"
    print -r -- "cursorOffset=${RAW_HOST_LOG_START_OFFSET}"
    print -r -- "cursorDigest=${RAW_HOST_LOG_START_DIGEST}"
  } > "${request_temporary}" || return $?
  mv "${request_temporary}" "${RAW_READY_REQUEST}" || return $?
  print -r -- \
    "phase=${RAW_PROOF_EVENT_PHASE} event=${RAW_PROOF_EVENT_PREFIX}raw-session-readiness-requested" \
    >> "${PHASE_EVENTS}" || return $?
}

function wait_for_fresh_raw_session_readiness_and_start_probe() {
  local wait_started=${SECONDS}
  local current_process_id
  local production_process_id
  local new_connections
  local authenticated_connections=0
  local healthy_boundary_observed=0
  local hidden_writer_selection_observed=0
  local blackhole_routing_epoch=""
  local blackhole_peer_generation=0
  local blackhole_device_generation=0
  local next_blackhole_routing_epoch=""
  local next_blackhole_peer_generation=0
  local next_blackhole_device_generation=0
  local healthy_route_line
  local healthy_route_pattern
  local ready_at_ns
  local probe_started_at_ns
  local elapsed_seconds
  local remaining_verifier_budget
  local cursor_partial_bytes
  local cursor_partial_digest
  local evidence_temporary="${RAW_READY_EVIDENCE}.tmp.$$"
  local command_status

  while (( SECONDS - wait_started < RAW_READY_TIMEOUT_SECONDS )); do
    if [[ -z "${XCODEBUILD_PID}" ]] \
        || ! opensteamer_process_group_exists "${XCODEBUILD_PID}"; then
      opensteamer_write_state \
        "${RAW_READY_STATUS}" "state=ui-ended-before-readiness" || true
      return 9
    fi
    if opensteamer_capture_log_snapshot \
        "${HOST_LOG}" \
        "${RAW_HOST_LOG_START_ID}" \
        "${RAW_HOST_LOG_START_OFFSET}" \
        "${RAW_HOST_LOG_START_DIGEST}" \
        "${RAW_HOST_LOG_APPEND_CHUNK}"; then
      :
    else
      command_status=$?
      opensteamer_write_state \
        "${RAW_READY_STATUS}" "state=host-log-invalid" || true
      return "${command_status}"
    fi
    opensteamer_split_completed_log_lines \
      "${RAW_HOST_LOG_APPEND_CHUNK}" \
      "${RAW_HOST_LOG_PARTIAL_LINE}" \
      "${RAW_HOST_LOG_COMPLETED_LINES}" || return $?
    current_process_id=$(current_host_pid)
    opensteamer_audit_connected_log_lines \
      "${RAW_HOST_LOG_COMPLETED_LINES}" \
      "${RAW_PROOF_EXPECTED_HOST_PID:-${EXPECTED_INITIAL_HOST_PID}}" \
      "${current_process_id}" || {
        command_status=$?
        opensteamer_write_state \
          "${RAW_READY_STATUS}" "state=host-identity-invalid" || true
        return "${command_status}"
      }

    new_connections=${OPENSTEAMER_AUDITED_CONNECTION_COUNT}
    authenticated_connections=$(( authenticated_connections
        + new_connections
    ))
    healthy_route_pattern="Worldwide authenticated media route selected BlackHole default input routingEpoch=[0-9a-f]{32} peerGeneration=[1-9][0-9]* deviceGeneration=[1-9][0-9]* pid=${current_process_id}$"
    if grep -Eq "${healthy_route_pattern}" \
        "${RAW_HOST_LOG_COMPLETED_LINES}"; then
      healthy_boundary_observed=1
      healthy_route_line=$(
        /usr/bin/grep -Eo "${healthy_route_pattern}" \
          "${RAW_HOST_LOG_COMPLETED_LINES}" \
          | /usr/bin/tail -n 1
      ) || return $?
      next_blackhole_routing_epoch=$(
        print -r -- "${healthy_route_line}" \
          | /usr/bin/sed -E \
              's/.*routingEpoch=([0-9a-f]{32}) peerGeneration=.*/\1/'
      ) || return $?
      next_blackhole_peer_generation=$(
        print -r -- "${healthy_route_line}" \
          | /usr/bin/sed -E \
              's/.*peerGeneration=([1-9][0-9]*) deviceGeneration=.*/\1/'
      ) || return $?
      next_blackhole_device_generation=$(
        print -r -- "${healthy_route_line}" \
          | /usr/bin/sed -E \
              's/.*deviceGeneration=([1-9][0-9]*) pid=.*/\1/'
      ) || return $?
      [[ ${#next_blackhole_routing_epoch} -eq 32 \
          && "${next_blackhole_routing_epoch}" != *[^0-9a-f]* \
          && -n "${next_blackhole_peer_generation}" \
          && "${next_blackhole_peer_generation}" != *[^0-9]* \
          && next_blackhole_peer_generation -gt 0 \
          && -n "${next_blackhole_device_generation}" \
          && "${next_blackhole_device_generation}" != *[^0-9]* \
          && next_blackhole_device_generation -gt 0 ]] || return 3
      if [[ -n "${blackhole_routing_epoch}" ]] \
          && (( blackhole_peer_generation > 0 \
          && blackhole_device_generation > 0 )); then
        if [[ "${blackhole_routing_epoch}" \
              != "${next_blackhole_routing_epoch}" ]] \
            || (( blackhole_peer_generation \
                    != next_blackhole_peer_generation \
                || blackhole_device_generation \
                    != next_blackhole_device_generation )); then
          hidden_writer_selection_observed=0
        fi
      fi
      blackhole_routing_epoch=${next_blackhole_routing_epoch}
      blackhole_peer_generation=${next_blackhole_peer_generation}
      blackhole_device_generation=${next_blackhole_device_generation}
      if (( RAW_PROOF_REQUIRE_NEW_CONNECTION == 0 )); then
        authenticated_connections=1
      fi
      if [[ ! -s "${RAW_DEFAULT_INPUT_HEALTHY}" ]]; then
        capture_default_input_snapshot \
          "${RAW_DEFAULT_INPUT_HEALTHY}" healthy || return $?
        jq -e \
          '.inputIsCanonicalBlackHole == true
          and .inputIsHiddenMirrorBlackHole == false
          and .defaultOutputIsForbiddenBlackHole == false
          and .defaultSystemOutputIsForbiddenBlackHole == false' \
          "${RAW_DEFAULT_INPUT_HEALTHY}" >/dev/null || return 3
      fi
    fi
    if [[ -n "${blackhole_routing_epoch}" ]] \
        && (( blackhole_peer_generation > 0 \
        && blackhole_device_generation > 0 )) && grep -Eq \
        "Worldwide iPhone microphone hidden writer selected routingEpoch=${blackhole_routing_epoch} peerGeneration=${blackhole_peer_generation} deviceGeneration=${blackhole_device_generation} pid=${current_process_id}$" \
        "${RAW_HOST_LOG_COMPLETED_LINES}"; then
      hidden_writer_selection_observed=1
    fi
    RAW_HOST_LOG_START_OFFSET=${OPENSTEAMER_LOG_SNAPSHOT_OFFSET}
    RAW_HOST_LOG_START_DIGEST=${OPENSTEAMER_LOG_SNAPSHOT_DIGEST}
    if (( authenticated_connections > 0
        && healthy_boundary_observed != 0
        && hidden_writer_selection_observed != 0 )); then
      if [[ -z "${OPENSTEAMER_SELF_TEST_RAW_READINESS:-}" ]]; then
        if [[ "${RAW_PROOF_CONTEXT}" == "post-call" ]]; then
          elapsed_seconds=$((SECONDS - wait_started))
          remaining_verifier_budget=$((
            RAW_READY_TIMEOUT_SECONDS - elapsed_seconds
          ))
          if (( remaining_verifier_budget <= 0 )); then
            opensteamer_write_state \
              "${RAW_READY_STATUS}" "state=pre-probe-budget-exhausted" || true
            return 124
          fi
          verify_host_deployment_snapshot \
            "${RAW_PROOF_EXPECTED_HOST_PID:-${EXPECTED_INITIAL_HOST_PID}}" \
            "${RAW_PROOF_CONTEXT}-raw-session-readiness" \
            "${remaining_verifier_budget}" || return $?
          if (( SECONDS - wait_started >= RAW_READY_TIMEOUT_SECONDS )); then
            opensteamer_write_state \
              "${RAW_READY_STATUS}" "state=pre-probe-budget-exhausted" || true
            return 124
          fi
        else
          verify_host_deployment_snapshot \
            "${RAW_PROOF_EXPECTED_HOST_PID:-${EXPECTED_INITIAL_HOST_PID}}" \
            "${RAW_PROOF_CONTEXT}-raw-session-readiness" || return $?
        fi
      fi
      ready_at_ns=$(current_monotonic_time_ns) || return $?
      if [[ -z "${ready_at_ns}" || "${ready_at_ns}" == *[^0-9]* ]] \
          || (( ready_at_ns <= RAW_READY_RESUMED_NS )); then
        return 3
      fi
      if [[ -z "${XCODEBUILD_PID}" ]] \
          || ! opensteamer_process_group_exists "${XCODEBUILD_PID}"; then
        record_raw_overlap_failure raw-ui-ended-before-probe-launch 9
        return 9
      fi
      production_process_id=$(capture_raw_probe_production_identity start) || {
        command_status=$?
        record_raw_overlap_failure \
          production-app-start-identity-invalid "${command_status}"
        return "${command_status}"
      }
      if [[ "${RAW_PROOF_CONTEXT}" == "post-call" ]] \
          && (( SECONDS - wait_started >= RAW_READY_TIMEOUT_SECONDS )); then
        opensteamer_write_state \
          "${RAW_READY_STATUS}" "state=pre-probe-budget-exhausted" || true
        record_raw_overlap_failure pre-probe-budget-exhausted 124
        return 124
      fi
      RAW_PROBE_BOUND_PID=${production_process_id}
      probe_started_at_ns=$(current_monotonic_time_ns) || {
        command_status=$?
        record_raw_overlap_failure probe-start-clock-failed "${command_status}"
        return "${command_status}"
      }
      if [[ -z "${probe_started_at_ns}" \
          || "${probe_started_at_ns}" == *[^0-9]* ]] \
          || (( probe_started_at_ns <= ready_at_ns )); then
        record_raw_overlap_failure probe-start-order-invalid 3
        return 3
      fi
      RAW_PROBE_STARTED_NS=${probe_started_at_ns}
      if start_blackhole_probe; then
        :
      else
        command_status=$?
        record_raw_overlap_failure probe-launch-failed "${command_status}"
        return "${command_status}"
      fi
      if [[ "${RAW_PROOF_CONTEXT}" == "post-call" ]] \
          && (( SECONDS - wait_started >= RAW_READY_TIMEOUT_SECONDS )); then
        cleanup_blackhole_probe || true
        opensteamer_write_state \
          "${RAW_READY_STATUS}" "state=pre-probe-budget-exhausted" || true
        record_raw_overlap_failure pre-probe-budget-exhausted 124
        return 124
      fi
      if [[ -n "${RAW_DEFAULT_INPUT_DURING}" ]]; then
        capture_default_input_snapshot \
          "${RAW_DEFAULT_INPUT_DURING}" healthy || return $?
        jq -e \
          '.inputIsCanonicalBlackHole == true
          and .inputIsHiddenMirrorBlackHole == false
          and .defaultOutputIsForbiddenBlackHole == false
          and .defaultSystemOutputIsForbiddenBlackHole == false' \
          "${RAW_DEFAULT_INPUT_DURING}" >/dev/null || return 3
      fi
      [[ -f "${RAW_HOST_LOG_PARTIAL_LINE}" \
          && ! -L "${RAW_HOST_LOG_PARTIAL_LINE}" ]] || return 3
      cursor_partial_bytes=$(
        /usr/bin/stat -f '%z' "${RAW_HOST_LOG_PARTIAL_LINE}"
      ) || return $?
      cursor_partial_digest=$(
        /usr/bin/shasum -a 256 "${RAW_HOST_LOG_PARTIAL_LINE}" \
          | /usr/bin/awk '{print $1}'
      ) || return $?
      [[ -n "${cursor_partial_bytes}" \
          && "${cursor_partial_bytes}" != *[^0-9]* \
          && ${#cursor_partial_digest} -eq 64 \
          && "${cursor_partial_digest}" != *[^0-9a-f]* ]] || return 3
      {
        print -r -- "schema=opensteamer.raw-session-readiness.v5"
        print -r -- "nonce=${RAW_READY_NONCE}"
        print -r -- "requestedAtMonotonicNs=${RAW_READY_REQUESTED_NS}"
        print -r -- "resumedAtMonotonicNs=${RAW_READY_RESUMED_NS}"
        print -r -- "readyAtMonotonicNs=${ready_at_ns}"
        print -r -- "probeStartedAtMonotonicNs=${probe_started_at_ns}"
        print -r -- "productionPID=${RAW_PROBE_BOUND_PID}"
        print -r -- "hostPID=${current_process_id}"
        print -r -- "blackHoleRoutingEpoch=${blackhole_routing_epoch}"
        print -r -- "blackHolePeerGeneration=${blackhole_peer_generation}"
        print -r -- "blackHoleDeviceGeneration=${blackhole_device_generation}"
        print -r -- "authenticatedConnectionCount=${authenticated_connections}"
        print -r -- "cursorIdentity=${RAW_HOST_LOG_START_ID}"
        print -r -- "cursorOffset=${RAW_HOST_LOG_START_OFFSET}"
        print -r -- "cursorDigest=${RAW_HOST_LOG_START_DIGEST}"
        print -r -- "cursorPartialBytes=${cursor_partial_bytes}"
        print -r -- "cursorPartialDigest=${cursor_partial_digest}"
      } > "${evidence_temporary}" || {
        command_status=$?
        cleanup_blackhole_probe || true
        return "${command_status}"
      }
      mv "${evidence_temporary}" "${RAW_READY_EVIDENCE}" || {
        command_status=$?
        cleanup_blackhole_probe || true
        return "${command_status}"
      }
      opensteamer_write_state "${RAW_READY_STATUS}" "state=accepted" || {
        command_status=$?
        cleanup_blackhole_probe || true
        return "${command_status}"
      }
      print -r -- \
        "phase=${RAW_PROOF_EVENT_PHASE} event=${RAW_PROOF_EVENT_PREFIX}raw-session-ready" \
        >> "${PHASE_EVENTS}" || return $?
      print -r -- \
        "phase=${RAW_PROOF_EVENT_PHASE} event=${RAW_PROOF_EVENT_PREFIX}blackhole-probe-started" \
        >> "${PHASE_EVENTS}" || return $?
      return 0
    fi
    sleep 0.05
  done

  opensteamer_write_state "${RAW_READY_STATUS}" "state=timed-out" || true
  opensteamer_write_state "${RAW_READY_TIMEOUT_MARKER}" "state=timed-out" || true
  echo "Timed out waiting for fresh authenticated raw-session readiness." >&2
  return 124
}

function arm_raw_session_readiness_and_start_probe() {
  local command_status

  if opensteamer_suspend_isolated_process_group "${XCODEBUILD_PID}" 3; then
    :
  else
    command_status=$?
    return "${command_status}"
  fi
  if initialize_raw_session_readiness; then
    :
  else
    command_status=$?
    opensteamer_resume_process_group "${XCODEBUILD_PID}" 2>/dev/null || true
    return "${command_status}"
  fi
  RAW_READY_RESUMED_NS=$(current_monotonic_time_ns) || return $?
  if [[ -z "${RAW_READY_RESUMED_NS}" \
      || "${RAW_READY_RESUMED_NS}" == *[^0-9]* ]] \
      || (( RAW_READY_RESUMED_NS <= RAW_READY_REQUESTED_NS )); then
    return 3
  fi
  if opensteamer_resume_process_group "${XCODEBUILD_PID}"; then
    :
  else
    command_status=$?
    record_raw_overlap_failure raw-ui-resume-failed "${command_status}"
    return "${command_status}"
  fi
  opensteamer_write_state \
    "${RAW_READY_RESUMED_MARKER}" \
    "state=resumed nonce=${RAW_READY_NONCE} resumedAtMonotonicNs=${RAW_READY_RESUMED_NS}" \
    || return $?
  print -r -- "phase=1 event=raw-ui-process-resumed" \
    >> "${PHASE_EVENTS}" || return $?
  wait_for_fresh_raw_session_readiness_and_start_probe
}

function validate_and_retain_raw_overlap_evidence() {
  local now_ns
  local validation_status
  local ui_causal_state="-"

  if [[ -z "${RAW_READY_NONCE}" \
      || "${BLACKHOLE_PROBE_NONCE}" != "${RAW_READY_NONCE}" ]]; then
    record_raw_overlap_failure nonce-binding-invalid 3
    return 3
  fi
  if [[ -n "${OPENSTEAMER_SELF_TEST_RAW_NOW_NS:-}" ]]; then
    now_ns=${OPENSTEAMER_SELF_TEST_RAW_NOW_NS}
  else
    now_ns=$(current_monotonic_time_ns) || return $?
  fi
  if [[ "${RAW_PROOF_CONTEXT}" == "post-call" ]]; then
    if [[ -z "${RAW_UI_CAUSAL_STATE_OBSERVATION}" \
        || ! -s "${RAW_UI_CAUSAL_STATE_OBSERVATION}" ]]; then
      record_raw_overlap_failure missing-ui-causal-state 3
      return 3
    fi
    ui_causal_state=${RAW_UI_CAUSAL_STATE_OBSERVATION}
  fi
  rm -f \
    "${RAW_UI_BOUNDS_EVIDENCE}" \
    "${RAW_PROBE_INTERVAL_EVIDENCE}" \
    "${RAW_PROBE_OVERLAP_MARKER}" || return $?
  if opensteamer_run_physical_validation_oracle \
      validate-overlap \
      "${RAW_READY_REQUEST}" \
      "${RAW_READY_EVIDENCE}" \
      "${RAW_UI_RUNTIME_EVIDENCE}" \
      "${RAW_PROBE_PROCESS_START_EVIDENCE}" \
      "${RAW_PROBE_PROCESS_COMPLETION_EVIDENCE}" \
      "${RAW_PROBE_COMPLETION_OBSERVATION}" \
      "${RAW_PROBE_WAIT_EVIDENCE}" \
      "${RAW_BLACKHOLE_PROBE_COMPLETION}" \
      "${RAW_BLACKHOLE_PROBE_RESULT}" \
      "${RAW_READY_NONCE}" \
      "${RAW_READY_REQUESTED_NS}" \
      "${RAW_READY_RESUMED_NS}" \
      "${RAW_UI_COMPLETION_OBSERVATION}" \
      "${ui_causal_state}" \
      "${RAW_UI_BOUNDS_EVIDENCE}" \
      "${RAW_PROBE_INTERVAL_EVIDENCE}" \
      "${RAW_PROBE_OVERLAP_MARKER}" \
      "${now_ns}" \
      "${RAW_READY_CONTINUITY_EVIDENCE}"
  then
    return 0
  else
    validation_status=$?
    record_raw_overlap_failure \
      causal-overlap-rejected "${validation_status}"
    return "${validation_status}"
  fi
}

function prepare_raw_physical_ui_test() {
  local build_status

  rm -rf "${RAW_DERIVED_DATA}" "${RAW_RESULT_BUNDLE}" || return $?
  run_command_capturing_status \
    opensteamer_run_with_timeout \
    "${UI_TEST_TIMEOUT_SECONDS}" \
    xcodebuild build-for-testing \
    -project "${PROJECT_DIR}/opensteamer.xcodeproj" \
    -scheme opensteamerUITests \
    -configuration Debug \
    -destination "platform=iOS,id=${HARDWARE_UDID}" \
    -derivedDataPath "${RAW_DERIVED_DATA}" \
    -parallel-testing-enabled NO \
    -maximum-parallel-testing-workers 1 \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 600 \
    -maximum-test-execution-time-allowance 720 \
    "-only-testing:opensteamerUITests/PairedReconnectPhysicalUITests/${EXPECTED_RAW_TEST_NAME}"
  build_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  return "${build_status}"
}

function run_raw_microphone_blackhole_phase() {
  local ui_status=0
  local probe_status=0
  local critical_status=0

  begin_phase 1 raw-iphone-microphone-blackhole "${RAW_PHASE_STATUS}" || return $?
  if [[ "${OPENSTEAMER_SELF_TEST_CRITICAL_FAILURE:-}" == "raw-phase" ]]; then
    fail_phase "${RAW_PHASE_STATUS}" || true
    return 91
  fi

  run_command_capturing_status require_phase_three_quiescence
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    fail_phase "${RAW_PHASE_STATUS}" || true
    return "${critical_status}"
  fi

  run_command_capturing_status compile_blackhole_probe
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    fail_phase "${RAW_PHASE_STATUS}" || true
    return "${critical_status}"
  fi

  run_command_capturing_status \
    capture_and_require_unlocked "${RAW_LOCK_STATE_BEFORE_XCODEBUILD}"
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    fail_phase "${RAW_PHASE_STATUS}" || true
    return "${critical_status}"
  fi

  run_command_capturing_status prepare_raw_physical_ui_test
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    fail_phase "${RAW_PHASE_STATUS}" || true
    return "${critical_status}"
  fi

  run_command_capturing_status terminate_production_app_for_raw_phase
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    fail_phase "${RAW_PHASE_STATUS}" || true
    return "${critical_status}"
  fi

  run_command_capturing_status \
    capture_default_input_snapshot \
    "${RAW_DEFAULT_INPUT_BEFORE}" before
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )) \
      || ! validate_default_input_baseline_json \
          "${RAW_DEFAULT_INPUT_BEFORE}"; then
    fail_phase "${RAW_PHASE_STATUS}" || true
    return 3
  fi

  print -r -- "phase=1 event=production-app-terminated" \
    >> "${PHASE_EVENTS}" || {
      critical_status=$?
      fail_phase "${RAW_PHASE_STATUS}" || true
      return "${critical_status}"
    }

  print -r -- \
    "phase=1 event=xcodebuild-started-without-building test=${EXPECTED_RAW_TEST_NAME}" \
    >> "${PHASE_EVENTS}" || {
      critical_status=$?
      fail_phase "${RAW_PHASE_STATUS}" || true
      return "${critical_status}"
    }
  run_command_capturing_status \
    run_simple_physical_ui_test \
    "${EXPECTED_RAW_TEST_NAME}" \
    "${RAW_RESULT_BUNDLE}" \
    "${RAW_DERIVED_DATA}" \
    "${RAW_UI_TEST_TIMEOUT_MARKER}" \
    "${RAW_DEVICE_LOCKED_MARKER}" \
    "${RAW_DEVICE_UNAVAILABLE_MARKER}" \
    "${RAW_WATCHDOG_STATE}" \
    "${RAW_WATCHDOG_FAILURE_MARKER}" \
    "${RAW_LOCK_STATE_DURING_TEST}" \
    "" \
    "" \
    "" \
    "test-without-building" \
    arm_raw_session_readiness_and_start_probe \
    1 \
    "${RAW_PROBE_COMPLETION_OBSERVATION}"
  ui_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}

  if (( ui_status != 0 )); then
    cleanup_blackhole_probe || true
  else
    run_command_capturing_status \
      wait_for_blackhole_probe_completion "${BLACKHOLE_PROBE_TIMEOUT_SECONDS}"
    probe_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  fi

  run_command_capturing_status \
    capture_and_require_unchanged_candidate \
    "${RAW_DEVICE_AFTER}" \
    "${RAW_APP_LIST_AFTER}" \
    "${RAW_CANDIDATE_AFTER}" \
    "raw iPhone microphone and BlackHole validation"
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    cleanup_blackhole_probe || true
    fail_phase "${RAW_PHASE_STATUS}" || true
    return "${critical_status}"
  fi
  if (( ui_status != 0 )); then
    fail_phase "${RAW_PHASE_STATUS}" || true
    return "${ui_status}"
  fi
  if (( probe_status != 0 )); then
    echo "The physical BlackHole microphone probe failed." >&2
    fail_phase "${RAW_PHASE_STATUS}" || true
    return "${probe_status}"
  fi
  if [[ -z "${BLACKHOLE_PROBE_STATUS}" \
      || "${BLACKHOLE_PROBE_STATUS}" == *[^0-9]* ]]; then
    fail_phase "${RAW_PHASE_STATUS}" || true
    return 1
  fi
  if (( BLACKHOLE_PROBE_STATUS != 0 )); then
    echo "The physical BlackHole microphone probe failed." >&2
    fail_phase "${RAW_PHASE_STATUS}" || true
    return "${BLACKHOLE_PROBE_STATUS}"
  fi

  run_command_capturing_status \
    capture_and_require_unlocked "${RAW_LOCK_STATE_AFTER_XCODEBUILD}"
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    fail_phase "${RAW_PHASE_STATUS}" || true
    return "${critical_status}"
  fi

  run_command_capturing_status \
    validate_blackhole_probe_json \
    "${RAW_BLACKHOLE_PROBE_RESULT}" \
    "${BLACKHOLE_PROBE_NONCE}" \
    "${PHYSICAL_OUTPUT_UID}"
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    echo "The physical BlackHole microphone result failed its exact JSON contract." >&2
    record_raw_overlap_failure \
      blackhole-json-invalid "${critical_status}"
    fail_phase "${RAW_PHASE_STATUS}" || true
    return "${critical_status}"
  fi

  run_command_capturing_status \
    validate_ui_xcresult \
    "${RAW_RESULT_BUNDLE}" \
    "${RAW_SUMMARY_JSON}" \
    "${RAW_TESTS_JSON}" \
    "${RAW_BUILD_RESULTS_JSON}" \
    "${RAW_ACTIVITIES_JSON}" \
    "${EXPECTED_RAW_TEST_NODE}" \
    "${EXPECTED_RAW_TEST_URL}" \
    validate_raw_physical_activities_json
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    record_raw_overlap_failure \
      raw-xcresult-invalid "${critical_status}"
    fail_phase "${RAW_PHASE_STATUS}" || true
    return "${critical_status}"
  fi

  run_command_capturing_status \
    capture_ui_xcresult_attachment_payload \
    "${RAW_RESULT_BUNDLE}" \
    "${RAW_UI_RUNTIME_ATTACHMENT_PAYLOAD_ID}" \
    "${RAW_UI_RUNTIME_EVIDENCE}"
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    record_raw_overlap_failure \
      raw-runtime-attachment-export-failed "${critical_status}"
    fail_phase "${RAW_PHASE_STATUS}" || true
    return "${critical_status}"
  fi

  run_command_capturing_status \
    require_stable_call_host "${EXPECTED_INITIAL_HOST_PID}"
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status == 0 )); then
    run_command_capturing_status \
      verify_host_deployment_snapshot \
      "${EXPECTED_INITIAL_HOST_PID}" "raw-phase-final"
    critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  fi
  if (( critical_status != 0 )); then
    echo "The signed host changed during raw microphone validation." >&2
    record_raw_overlap_failure \
      raw-stable-host-invalid "${critical_status}"
    fail_phase "${RAW_PHASE_STATUS}" || true
    return 4
  fi

  run_command_capturing_status reject_runtime_uid_in_retained_artifacts
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    echo "A retained phase-one artifact contained the runtime physical-output UID." >&2
    record_raw_overlap_failure \
      raw-retained-artifact-invalid "${critical_status}"
    fail_phase "${RAW_PHASE_STATUS}" || true
    return "${critical_status}"
  fi

  run_command_capturing_status validate_and_retain_raw_overlap_evidence
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    echo "The nonce-bound causal raw UI and BlackHole overlap proof failed." >&2
    fail_phase "${RAW_PHASE_STATUS}" || true
    return "${critical_status}"
  fi

  run_command_capturing_status \
    terminate_production_app_for_phase \
    "${RAW_PHASE_DIR}" \
    "${RAW_APP_DISCONNECT_EVIDENCE}" \
    "after raw microphone validation"
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    fail_phase "${RAW_PHASE_STATUS}" || true
    return "${critical_status}"
  fi

  run_command_capturing_status \
    wait_for_default_input_restoration
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    echo "The original default input baseline was not preserved/restored after disconnect." >&2
    fail_phase "${RAW_PHASE_STATUS}" || true
    return "${critical_status}"
  fi

  run_command_capturing_status \
    validate_default_input_lifecycle_json \
    "${RAW_DEFAULT_INPUT_BEFORE}" \
    "${RAW_DEFAULT_INPUT_HEALTHY}" \
    "${RAW_DEFAULT_INPUT_AFTER}" \
    "${RAW_PROBE_STARTED_NS}" \
    "" \
    0 \
    "${RAW_DEFAULT_INPUT_LIFECYCLE_EVIDENCE}"
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    echo "The default-input lifecycle evidence (preselected or switched) was rejected." >&2
    fail_phase "${RAW_PHASE_STATUS}" || true
    return "${critical_status}"
  fi

  if complete_phase \
      1 raw-iphone-microphone-blackhole "${RAW_PHASE_STATUS}"; then
    return 0
  else
    critical_status=$?
    clear_raw_overlap_success_evidence 2>/dev/null || true
    return "${critical_status}"
  fi
}

function run_real_connected_call_phase() {
  local ui_status=0
  local probe_status=0
  local post_call_probe_end_ns=0
  local critical_status=0

  begin_phase 3 real-connected-call "${CALL_PHASE_STATUS}" || return $?
  if [[ "${OPENSTEAMER_SELF_TEST_CRITICAL_FAILURE:-}" == "call-phase" ]]; then
    fail_phase "${CALL_PHASE_STATUS}" || true
    return 92
  fi

  run_command_capturing_status require_phase_three_quiescence
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    fail_phase "${CALL_PHASE_STATUS}" || true
    return "${critical_status}"
  fi

  CALL_STABLE_HOST_PID=$(current_host_pid)
  if [[ -z "${CALL_STABLE_HOST_PID}" \
      || "${CALL_STABLE_HOST_PID}" == *[^0-9]* ]]; then
    echo "The final signed host PID was not stable before the real-call phase." >&2
    fail_phase "${CALL_PHASE_STATUS}" || true
    return 4
  fi
  run_command_capturing_status \
    require_stable_call_host "${CALL_STABLE_HOST_PID}"
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status == 0 )); then
    run_command_capturing_status \
      verify_host_deployment_snapshot \
      "${CALL_STABLE_HOST_PID}" "call-phase-preflight"
    critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  fi
  if (( critical_status != 0 )); then
    echo "The final signed host PID was not stable before the real-call phase." >&2
    fail_phase "${CALL_PHASE_STATUS}" || true
    return 4
  fi

  run_command_capturing_status terminate_production_app_for_call_phase
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    fail_phase "${CALL_PHASE_STATUS}" || true
    return "${critical_status}"
  fi
  print -r -- "phase=3 event=production-app-terminated" \
    >> "${PHASE_EVENTS}" || {
      critical_status=$?
      fail_phase "${CALL_PHASE_STATUS}" || true
      return "${critical_status}"
    }

  run_command_capturing_status wait_for_fresh_call_ready_acknowledgement
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    fail_phase "${CALL_PHASE_STATUS}" || true
    return "${critical_status}"
  fi

  run_command_capturing_status \
    require_stable_call_host "${CALL_STABLE_HOST_PID}"
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    echo "The host PID changed while waiting for the real-call acknowledgement." >&2
    fail_phase "${CALL_PHASE_STATUS}" || true
    return 4
  fi

  run_command_capturing_status \
    start_physical_audio_oracle_tone \
    "${CALL_AUDIO_ORACLE_TONE}" \
    "${CALL_AUDIO_ORACLE_TONE_LOG}" \
    "${CALL_AUDIO_ORACLE_DURATION_SECONDS}"
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    fail_phase "${CALL_PHASE_STATUS}" || true
    return "${critical_status}"
  fi

  run_command_capturing_status \
    capture_and_require_unlocked "${CALL_LOCK_STATE_BEFORE_XCODEBUILD}"
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    cleanup_audio_oracle_tone || true
    fail_phase "${CALL_PHASE_STATUS}" || true
    return "${critical_status}"
  fi

  run_command_capturing_status configure_post_call_raw_contract
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    cleanup_audio_oracle_tone || true
    fail_phase "${CALL_PHASE_STATUS}" || true
    return "${critical_status}"
  fi

  print -r -- \
    "phase=3 event=xcodebuild-started test=${EXPECTED_CALL_TEST_NAME}" \
    >> "${PHASE_EVENTS}" || {
      critical_status=$?
      cleanup_audio_oracle_tone || true
      fail_phase "${CALL_PHASE_STATUS}" || true
      return "${critical_status}"
    }
  run_command_capturing_status \
    run_simple_physical_ui_test \
    "${EXPECTED_CALL_TEST_NAME}" \
    "${CALL_RESULT_BUNDLE}" \
    "${CALL_DERIVED_DATA}" \
    "${CALL_UI_TEST_TIMEOUT_MARKER}" \
    "${CALL_DEVICE_LOCKED_MARKER}" \
    "${CALL_DEVICE_UNAVAILABLE_MARKER}" \
    "${CALL_WATCHDOG_STATE}" \
    "${CALL_WATCHDOG_FAILURE_MARKER}" \
    "${CALL_LOCK_STATE_DURING_TEST}" \
    "${CALL_AUDIO_ORACLE_FAILURE_MARKER}" \
    "${CALL_STABLE_HOST_FAILURE_MARKER}" \
    "${CALL_STABLE_HOST_PID}" \
    "test" \
    run_real_call_operator_and_post_call_probe \
    0 \
    "${RAW_PROBE_COMPLETION_OBSERVATION}" \
    arm_post_call_raw_readiness
  ui_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}

  if (( ui_status == 0 )) \
      && { ! /usr/bin/grep -Fxq 'state=accepted' "${CALL_ACOUSTIC_STATUS}" \
        || ! /usr/bin/grep -Fxq 'state=accepted' "${CALL_END_STATUS}"; }; then
    cleanup_audio_oracle_tone || true
    fail_phase "${CALL_PHASE_STATUS}" || true
    return 1
  fi

  if (( ui_status != 0 )); then
    cleanup_blackhole_probe || true
  else
    run_command_capturing_status \
      wait_for_blackhole_probe_completion "${BLACKHOLE_PROBE_TIMEOUT_SECONDS}"
    probe_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  fi

  run_command_capturing_status \
    capture_and_require_unchanged_candidate \
    "${CALL_DEVICE_AFTER}" \
    "${CALL_APP_LIST_AFTER}" \
    "${CALL_CANDIDATE_AFTER}" \
    "real connected-call validation"
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    cleanup_audio_oracle_tone || true
    fail_phase "${CALL_PHASE_STATUS}" || true
    return "${critical_status}"
  fi
  if (( ui_status != 0 )); then
    cleanup_audio_oracle_tone || true
    fail_phase "${CALL_PHASE_STATUS}" || true
    return "${ui_status}"
  fi
  if (( probe_status != 0 )) \
      || [[ -z "${BLACKHOLE_PROBE_STATUS}" \
          || "${BLACKHOLE_PROBE_STATUS}" == *[^0-9]* ]] \
      || (( BLACKHOLE_PROBE_STATUS != 0 )); then
    echo "The post-call physical BlackHole microphone probe failed." >&2
    cleanup_audio_oracle_tone || true
    fail_phase "${CALL_PHASE_STATUS}" || true
    return 7
  fi
  post_call_probe_end_ns=$(raw_evidence_value \
    "${RAW_PROBE_WAIT_EVIDENCE}" probeEndMonotonicNs) || return $?
  if [[ -z "${post_call_probe_end_ns}" \
      || "${post_call_probe_end_ns}" == *[^0-9]* ]] \
      || (( post_call_probe_end_ns <= RAW_PROBE_STARTED_NS )); then
    cleanup_audio_oracle_tone || true
    fail_phase "${CALL_PHASE_STATUS}" || true
    return 3
  fi

  run_command_capturing_status \
    validate_blackhole_probe_json \
    "${RAW_BLACKHOLE_PROBE_RESULT}" \
    "${BLACKHOLE_PROBE_NONCE}" \
    "${PHYSICAL_OUTPUT_UID}"
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    cleanup_audio_oracle_tone || true
    fail_phase "${CALL_PHASE_STATUS}" || true
    return "${critical_status}"
  fi

  run_command_capturing_status wait_for_default_input_restoration
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status == 0 )); then
    run_command_capturing_status \
      validate_default_input_lifecycle_json \
      "${RAW_DEFAULT_INPUT_BEFORE}" \
      "${RAW_DEFAULT_INPUT_HEALTHY}" \
      "${RAW_DEFAULT_INPUT_AFTER}" \
      "${RAW_PROBE_STARTED_NS}" \
      "${RAW_DEFAULT_INPUT_DURING}" \
      "${post_call_probe_end_ns}" \
      "${RAW_DEFAULT_INPUT_LIFECYCLE_EVIDENCE}"
    critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  fi
  if (( critical_status != 0 )); then
    echo "The post-call BlackHole preselected/switch lifecycle proof failed." >&2
    cleanup_audio_oracle_tone || true
    fail_phase "${CALL_PHASE_STATUS}" || true
    return "${critical_status}"
  fi

  run_command_capturing_status \
    capture_and_require_unlocked "${CALL_LOCK_STATE_AFTER_XCODEBUILD}"
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    cleanup_audio_oracle_tone || true
    fail_phase "${CALL_PHASE_STATUS}" || true
    return "${critical_status}"
  fi

  if [[ -z "${AUDIO_ORACLE_TONE_PID}" ]] \
      || ! opensteamer_process_group_exists "${AUDIO_ORACLE_TONE_PID}"; then
    echo "The real-call audio oracle tone was not alive at final audit." >&2
    cleanup_audio_oracle_tone || true
    fail_phase "${CALL_PHASE_STATUS}" || true
    return 7
  fi

  run_command_capturing_status \
    require_stable_call_host "${CALL_STABLE_HOST_PID}"
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status == 0 )); then
    run_command_capturing_status \
      verify_host_deployment_snapshot \
      "${CALL_STABLE_HOST_PID}" "call-phase-final"
    critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  fi
  if (( critical_status != 0 )); then
    echo "The signed host PID changed during real-call validation." >&2
    cleanup_audio_oracle_tone || true
    fail_phase "${CALL_PHASE_STATUS}" || true
    return 4
  fi

  run_command_capturing_status \
    validate_ui_xcresult \
    "${CALL_RESULT_BUNDLE}" \
    "${CALL_SUMMARY_JSON}" \
    "${CALL_TESTS_JSON}" \
    "${CALL_BUILD_RESULTS_JSON}" \
    "${CALL_ACTIVITIES_JSON}" \
    "${EXPECTED_CALL_TEST_NODE}" \
    "${EXPECTED_CALL_TEST_URL}" \
    validate_call_physical_activities_json
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    cleanup_audio_oracle_tone || true
    fail_phase "${CALL_PHASE_STATUS}" || true
    return "${critical_status}"
  fi

  run_command_capturing_status \
    capture_ui_xcresult_attachment_payload \
    "${CALL_RESULT_BUNDLE}" \
    "${CALL_POST_RAW_UI_RUNTIME_ATTACHMENT_PAYLOAD_ID}" \
    "${CALL_POST_RAW_UI_RUNTIME_EVIDENCE}"
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status == 0 )); then
    run_command_capturing_status \
      capture_ui_xcresult_attachment_payload \
      "${CALL_RESULT_BUNDLE}" \
      "${CALL_POST_RAW_GENERATION_ATTACHMENT_PAYLOAD_ID}" \
      "${CALL_POST_RAW_GENERATION_EVIDENCE}"
    critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  fi
  if (( critical_status == 0 )); then
    run_command_capturing_status validate_post_call_raw_generation_evidence
    critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  fi
  if (( critical_status == 0 )); then
    run_command_capturing_status validate_and_retain_raw_overlap_evidence
    critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  fi
  if (( critical_status == 0 )); then
    run_command_capturing_status reject_runtime_uid_in_retained_artifacts
    critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  fi
  if (( critical_status != 0 )); then
    echo "The nonce-bound post-call raw sender/BlackHole overlap proof failed." >&2
    cleanup_audio_oracle_tone || true
    fail_phase "${CALL_PHASE_STATUS}" || true
    return "${critical_status}"
  fi

  run_command_capturing_status cleanup_audio_oracle_tone
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    fail_phase "${CALL_PHASE_STATUS}" || true
    return 7
  fi

  run_command_capturing_status require_phase_three_quiescence
  critical_status=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( critical_status != 0 )); then
    fail_phase "${CALL_PHASE_STATUS}" || true
    return "${critical_status}"
  fi

  complete_phase 3 real-connected-call "${CALL_PHASE_STATUS}" || return $?
}

# Read, authenticate, split, and audit one new log snapshot before committing its byte cursor. The
# current launchd PID is checked even when the snapshot contains no connected records.
function audit_new_host_log_records() {
  local expected_host_pid=$1
  local current_process_id
  local line
  local new_connections

  if ! opensteamer_capture_log_snapshot \
      "${HOST_LOG}" \
      "${HOST_LOG_START_ID}" \
      "${HOST_LOG_START_OFFSET}" \
      "${HOST_LOG_START_DIGEST}" \
      "${HOST_LOG_APPEND_CHUNK}"; then
    return 1
  fi
  if ! opensteamer_split_completed_log_lines \
      "${HOST_LOG_APPEND_CHUNK}" \
      "${HOST_LOG_PARTIAL_LINE}" \
      "${HOST_LOG_COMPLETED_LINES}"; then
    return 1
  fi
  current_process_id=$(current_host_pid)
  if ! opensteamer_audit_connected_log_lines \
      "${HOST_LOG_COMPLETED_LINES}" \
      "${expected_host_pid}" \
      "${current_process_id}"; then
    return 1
  fi

  new_connections=${OPENSTEAMER_AUDITED_CONNECTION_COUNT}
  HOST_LOG_START_OFFSET=${OPENSTEAMER_LOG_SNAPSHOT_OFFSET}
  HOST_LOG_START_DIGEST=${OPENSTEAMER_LOG_SNAPSHOT_DIGEST}
  OPENSTEAMER_NEW_HOST_CONNECTIONS=${new_connections}
  OPENSTEAMER_CURRENT_HOST_PID=${current_process_id}
}

function record_audited_host_connections() {
  local first_connection_number=$1
  local host_pid=$2
  local connection_number=${first_connection_number}
  local line

  while IFS= read -r line; do
    [[ "${line}" == *"Worldwide WebRTC peer state: connected pid="* ]] || continue
    print -r -- \
      "connection=${connection_number} observed_at=$(date -u +%FT%TZ) host_pid=${host_pid} log=${line}" \
      >> "${HOST_EVENTS}"
    connection_number=$((connection_number + 1))
  done < "${HOST_LOG_COMPLETED_LINES}"
}

function prepare_host_deployment_contract_self_test() {
  local mode=$1
  local controller="${PHYSICAL_VALIDATION_ORACLE_BUILD_DIR}/migration-lock-probe"
  local verifier="${ARTIFACT_DIR}/host-deployment-verifier-fixture.zsh"
  local staged="${ARTIFACT_DIR}/fresh-staged.app"
  local offline="${ARTIFACT_DIR}/offline-legacy-reference"
  local reviewed="${ARTIFACT_DIR}/reviewed-launch-agent.plist"
  local nonce="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  /bin/mkdir -p "${staged}" || return $?
  print -r -- "offline-reference" > "${offline}" || return $?
  print -r -- "reviewed-plist" > "${reviewed}" || return $?
  /bin/cp "${OPENSTEAMER_PHYSICAL_VALIDATION_ORACLE}" "${controller}" || return $?
  /bin/chmod 500 "${controller}" || return $?
  MIGRATION_CONTROLLER_BINARY_SHA256=$(
    /usr/bin/shasum -a 256 "${controller}" | /usr/bin/awk '{print $1}'
  ) || return $?
  OPENSTEAMER_MIGRATION_CONTROLLER_BINARY=${controller}
  HOST_FRESH_STAGED_APP=${staged}
  HOST_OFFLINE_LEGACY_REFERENCE=${offline}
  HOST_REVIEWED_LAUNCH_AGENT=${reviewed}
  MAC_HOST_DEPLOYMENT_VERIFIER=${verifier}
  if [[ "${mode}" == missing ]]; then
    nonce="malformed"
  fi
  {
    print -r -- '#!/bin/zsh'
    print -r -- 'set -eu'
    print -r -- '[[ -n "${OPENSTEAMER_MIGRATION_CONTROLLER_BINARY:-}" ]] || exit 90'
    print -r -- 'print -r -- "verifier-invoked=true"'
    print -r -- 'print -r -- "controller=${OPENSTEAMER_MIGRATION_CONTROLLER_BINARY}"'
    print -r -- 'print -r -- "argc=$#"'
    print -r -- 'integer argument_index=1'
    print -r -- 'for argument in "$@"; do'
    print -r -- '  print -r -- "arg${argument_index}=${argument}"'
    print -r -- '  argument_index=$((argument_index + 1))'
    print -r -- 'done'
  } > "${verifier}" || return $?
  /bin/chmod 500 "${verifier}" || return $?
  {
    print -r -- "schema=opensteamer.host-generation.v1"
    print -r -- "log_offset=123"
    print -r -- "log_device=456"
    print -r -- "log_inode=789"
    print -r -- "pid=4242"
    print -r -- "runs=7"
    print -r -- "process_start=Mon Aug  3 12:34:56 2026"
    print -r -- "nonce=${nonce}"
    print -r -- "lock_device=111"
    print -r -- "lock_inode=222"
  } > "${HOST_GENERATION_STATE}" || return $?
}

function run_host_provenance_self_test() {
  local scenario=${OPENSTEAMER_SCRIPT_SELF_TEST#host-provenance-}
  local host_pid_file="${ARTIFACT_DIR}/self-test-host-pid.txt"
  local host_pid_queue="${ARTIFACT_DIR}/self-test-host-pid-queue.txt"
  local kickstart_events="${ARTIFACT_DIR}/self-test-kickstarts.txt"
  local pre_kick_ready="${ARTIFACT_DIR}/self-test-pre-kick-ready.txt"
  local audit_only_ready="${ARTIFACT_DIR}/self-test-audit-only-ready.txt"
  local audit_only_proceed="${ARTIFACT_DIR}/self-test-audit-only-proceed.txt"
  local watcher_result
  local kickstart_count
  local empty_digest

  HOST_LOG="${ARTIFACT_DIR}/self-test-worldwide-host.log"
  OPENSTEAMER_SELF_TEST_HOST_PID_FILE=${host_pid_file}
  OPENSTEAMER_SELF_TEST_HOST_PID_QUEUE=${host_pid_queue}
  OPENSTEAMER_SELF_TEST_KICKSTART_EVENTS=${kickstart_events}
  OPENSTEAMER_SELF_TEST_PRE_KICK_READY=${pre_kick_ready}
  if [[ "${scenario}" == "final-audit-mismatch" \
      || "${scenario}" == "final-partial-mismatch" ]]; then
    OPENSTEAMER_SELF_TEST_AUDIT_ONLY_READY=${audit_only_ready}
    OPENSTEAMER_SELF_TEST_AUDIT_ONLY_PROCEED=${audit_only_proceed}
  fi
  EXPECTED_INITIAL_HOST_PID=100
  rm -rf \
    "${HOST_LOG}" \
    "${host_pid_file}" \
    "${host_pid_queue}" \
    "${kickstart_events}" \
    "${pre_kick_ready}" \
    "${audit_only_ready}" \
    "${audit_only_proceed}" \
    "${HOST_EVENTS}" \
    "${HOST_STATUS}" \
    "${HOST_CHURN_LOCK}" \
    "${HOST_CHURN_STOP_MARKER}" \
    "${HOST_LOG_APPEND_CHUNK}" \
    "${HOST_LOG_COMPLETED_LINES}" \
    "${HOST_LOG_PARTIAL_LINE}"
  print -r -- "baseline" > "${HOST_LOG}"
  print -r -- "100" > "${host_pid_file}"
  case "${scenario}" in
    reused-pid)
      print -r -- $'200\n100' > "${host_pid_queue}"
      ;;
    *)
      print -r -- $'200\n300\n400' > "${host_pid_queue}"
      ;;
  esac
  print -rn -- "" > "${kickstart_events}"
  print -rn -- "" > "${HOST_LOG_PARTIAL_LINE}"
  empty_digest=$(opensteamer_empty_sha256)
  if ! opensteamer_capture_log_snapshot \
      "${HOST_LOG}" "" 0 "${empty_digest}" "${HOST_LOG_APPEND_CHUNK}"; then
    return 20
  fi
  HOST_LOG_START_ID=${OPENSTEAMER_LOG_SNAPSHOT_ID}
  HOST_LOG_START_OFFSET=${OPENSTEAMER_LOG_SNAPSHOT_OFFSET}
  HOST_LOG_START_DIGEST=${OPENSTEAMER_LOG_SNAPSHOT_DIGEST}
  rm -f "${HOST_LOG_APPEND_CHUNK}"

  opensteamer_start_isolated_validation_process /bin/zsh -c '
scenario=$1
log_path=$2
pid_path=$3
ready_path=$4

function append_record() {
  print -r -- "Worldwide WebRTC peer state: connected pid=$1" >> "${log_path}"
}
function wait_for_file() {
  for poll in {1..400}; do
    [[ -e "$1" ]] && return 0
    sleep 0.005
  done
  return 31
}
function wait_for_pid() {
  local expected=$1
  local observed
  for poll in {1..400}; do
    observed=$(<"${pid_path}") 2>/dev/null || observed=""
    [[ "${observed}" == "${expected}" ]] && return 0
    sleep 0.005
  done
  return 32
}

case "${scenario}" in
  batched-malformed)
    append_record 100
    append_record 0
    ;;
  pre-kick-mismatch)
    append_record 100
    wait_for_file "${ready_path}" || exit $?
    append_record 999
    ;;
  same-inode-rewrite)
    append_record 100
    wait_for_file "${ready_path}" || exit $?
    print -rn -- B \
      | /bin/dd of="${log_path}" bs=1 seek=0 conv=notrunc 2>/dev/null
    ;;
  *)
    append_record 100
    wait_for_pid 200 || exit $?
    append_record 200
    if [[ "${scenario}" == reused-pid ]]; then
      wait_for_pid 100 || exit $?
    else
      wait_for_pid 300 || exit $?
      append_record 300
      wait_for_pid 400 || exit $?
      if [[ "${scenario}" == late-mismatch ]]; then
        append_record 999
      elif [[ "${scenario}" == unique-pids ]]; then
        append_record 400
      fi
    fi
    ;;
esac
sleep 0.5
' host-provenance-writer \
    "${scenario}" "${HOST_LOG}" "${host_pid_file}" "${pre_kick_ready}"

  if ! start_host_churn_worker; then
    return 60
  fi
  opensteamer_wait_for_final_process_status "${XCODEBUILD_PID}"
  if ! opensteamer_wait_for_process_group_exit "${XCODEBUILD_PID}" 1; then
    opensteamer_terminate_isolated_process_group \
      "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
  fi
  if [[ "${scenario}" == "final-audit-mismatch" \
      || "${scenario}" == "final-partial-mismatch" ]]; then
    for audit_poll in {1..200}; do
      [[ -f "${audit_only_ready}" ]] && break
      sleep 0.01
    done
    [[ -f "${audit_only_ready}" ]] || return 48
    if [[ "${scenario}" == "final-partial-mismatch" ]]; then
      print -rn -- "Worldwide WebRTC peer state: connected pid=999" >> "${HOST_LOG}"
    else
      print -r -- "Worldwide WebRTC peer state: connected pid=999" >> "${HOST_LOG}"
    fi
  fi
  request_final_host_log_audit
  if [[ "${scenario}" == "final-audit-mismatch" \
      || "${scenario}" == "final-partial-mismatch" ]]; then
    opensteamer_write_state "${audit_only_proceed}" "state=proceed"
  fi
  if ! opensteamer_wait_for_process_exit "${HOST_WATCHER_PID}" 3; then
    return 21
  fi
  if opensteamer_process_group_exists "${HOST_WATCHER_PID}"; then
    return 61
  fi
  if wait "${HOST_WATCHER_PID}" 2>/dev/null; then
    watcher_result=0
  else
    watcher_result=$?
  fi
  HOST_WATCHER_PID=""
  XCODEBUILD_PID=""
  XCODEBUILD_GROUP_ISOLATED=0
  kickstart_count=$(grep -c '^kickstart=' "${kickstart_events}" 2>/dev/null || true)

  case "${scenario}" in
    batched-malformed)
      (( watcher_result != 0 )) || return 28
      (( kickstart_count == 0 )) || return 29
      grep -qx 'connections=0' "${HOST_STATUS}" || return 30
      grep -qx 'restarts=0' "${HOST_STATUS}" || return 31
      grep -qx 'detail=host log snapshot or PID provenance became invalid' \
        "${HOST_STATUS}" || return 49
      ;;
    pre-kick-mismatch|same-inode-rewrite)
      (( watcher_result != 0 )) || return 32
      (( kickstart_count == 0 )) || return 33
      grep -qx 'connections=1' "${HOST_STATUS}" || return 34
      grep -qx 'restarts=0' "${HOST_STATUS}" || return 35
      grep -qx 'detail=host log or PID provenance changed during the pre-kick delay' \
        "${HOST_STATUS}" || return 50
      ;;
    reused-pid)
      (( watcher_result != 0 )) || return 36
      (( kickstart_count == 2 )) || return 37
      grep -qx 'connections=2' "${HOST_STATUS}" || return 38
      grep -qx 'restarts=1' "${HOST_STATUS}" || return 39
      grep -qx 'detail=launchd reused previously observed host PID 100' \
        "${HOST_STATUS}" || return 51
      ;;
    late-mismatch)
      (( watcher_result != 0 )) || return 40
      (( kickstart_count == 3 )) || return 41
      grep -qx 'connections=3' "${HOST_STATUS}" || return 42
      grep -qx 'restarts=3' "${HOST_STATUS}" || return 43
      grep -qx 'detail=host log snapshot or PID provenance became invalid' \
        "${HOST_STATUS}" || return 52
      ;;
    unique-pids)
      (( watcher_result == 0 )) || return 22
      grep -qx 'status=passed' "${HOST_STATUS}" || return 23
      grep -qx 'restarts=3' "${HOST_STATUS}" || return 24
      (( kickstart_count == 3 )) || return 25
      grep -qx 'connections=4' "${HOST_STATUS}" || return 44
      grep -qx \
        'detail=audited 4 live connections and verified three globally unique host replacements' \
        "${HOST_STATUS}" || return 53
      ;;
    final-audit-mismatch)
      (( watcher_result != 0 )) || return 26
      (( kickstart_count == 3 )) || return 27
      grep -qx 'connections=3' "${HOST_STATUS}" || return 45
      grep -qx 'restarts=3' "${HOST_STATUS}" || return 46
      grep -qx 'detail=final host log snapshot or PID provenance was invalid' \
        "${HOST_STATUS}" || return 54
      ;;
    final-partial-mismatch)
      (( watcher_result != 0 )) || return 55
      (( kickstart_count == 3 )) || return 56
      grep -qx 'connections=3' "${HOST_STATUS}" || return 57
      grep -qx 'restarts=3' "${HOST_STATUS}" || return 58
      grep -qx 'detail=final host log snapshot ended with an incomplete record' \
        "${HOST_STATUS}" || return 59
      ;;
    *)
      return 47
      ;;
  esac
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
}

function run_critical_failure_self_test() {
  local target=${OPENSTEAMER_SCRIPT_SELF_TEST#critical-failure-}
  local injected_status=0
  local phase_status=${RAW_PHASE_STATUS}

  case "${target}" in
    xcresult-summary|xcresult-tests|xcresult-build-results|xcresult-activities)
      begin_phase 1 raw-iphone-microphone-blackhole "${RAW_PHASE_STATUS}" || return $?
      OPENSTEAMER_SELF_TEST_XCRESULT_FAILURE=${target#xcresult-}
      if validate_ui_xcresult \
          "${RAW_PHASE_DIR}/missing.xcresult" \
          "${RAW_SUMMARY_JSON}" \
          "${RAW_TESTS_JSON}" \
          "${RAW_BUILD_RESULTS_JSON}" \
          "${RAW_ACTIVITIES_JSON}" \
          "${EXPECTED_RAW_TEST_NODE}" \
          "${EXPECTED_RAW_TEST_URL}" \
          validate_raw_physical_activities_json; then
        injected_status=0
      else
        injected_status=$?
      fi
      ;;
    unchanged-candidate)
      begin_phase 1 raw-iphone-microphone-blackhole "${RAW_PHASE_STATUS}" || return $?
      OPENSTEAMER_SELF_TEST_CRITICAL_FAILURE=unchanged-candidate
      if capture_and_require_unchanged_candidate \
          "${RAW_DEVICE_AFTER}" \
          "${RAW_APP_LIST_AFTER}" \
          "${RAW_CANDIDATE_AFTER}" \
          "self-test"; then
        injected_status=0
      else
        injected_status=$?
      fi
      ;;
    lock-proof)
      begin_phase 1 raw-iphone-microphone-blackhole "${RAW_PHASE_STATUS}" || return $?
      OPENSTEAMER_SELF_TEST_CRITICAL_FAILURE=lock-proof
      if capture_and_require_unlocked "${RAW_LOCK_STATE_BEFORE_XCODEBUILD}"; then
        injected_status=0
      else
        injected_status=$?
      fi
      ;;
    simple-ui-isolation)
      begin_phase 1 raw-iphone-microphone-blackhole "${RAW_PHASE_STATUS}" || return $?
      OPENSTEAMER_SELF_TEST_ISOLATION_FAILURE_STATUS=19
      if run_simple_physical_ui_test \
          "${EXPECTED_RAW_TEST_NAME}" \
          "${RAW_RESULT_BUNDLE}" \
          "${RAW_DERIVED_DATA}" \
          "${RAW_UI_TEST_TIMEOUT_MARKER}" \
          "${RAW_DEVICE_LOCKED_MARKER}" \
          "${RAW_DEVICE_UNAVAILABLE_MARKER}" \
          "${RAW_WATCHDOG_STATE}" \
          "${RAW_WATCHDOG_FAILURE_MARKER}" \
          "${RAW_LOCK_STATE_DURING_TEST}" \
          "" \
          "" \
          ""; then
        injected_status=0
      else
        injected_status=$?
      fi
      ;;
    raw-phase)
      OPENSTEAMER_SELF_TEST_CRITICAL_FAILURE=raw-phase
      run_phase_capturing_status run_raw_microphone_blackhole_phase
      return "${OPENSTEAMER_CAPTURED_PHASE_STATUS}"
      ;;
    call-phase)
      phase_status=${CALL_PHASE_STATUS}
      OPENSTEAMER_SELF_TEST_CRITICAL_FAILURE=call-phase
      run_phase_capturing_status run_real_connected_call_phase
      return "${OPENSTEAMER_CAPTURED_PHASE_STATUS}"
      ;;
    *)
      return 98
      ;;
  esac

  if (( injected_status == 0 )); then
    injected_status=99
  fi
  fail_phase "${phase_status}" || return $?
  return "${injected_status}"
}

function write_raw_overlap_self_test_fixture() {
  local scenario=$1
  local requested=500000000
  local fixture_requested=${requested}
  local resumed=1000000000
  local ready=2000000000
  local continuity=30000000000
  local xcode_end=37000000000
  local now=40000000000
  local probe_start=10000000000
  local probe_end=16000000000
  local start_observed=9000000000
  local completion_observed=17000000000
  local ui_nonce="${RAW_READY_NONCE}"
  local ui_pid_start=7101
  local ui_pid_end=7101
  local wrapper_status=0
  local wait_status=0
  local continuity_routing_epoch="0123456789abcdef0123456789abcdef"
  local continuity_peer_generation=1
  local continuity_device_generation=1
  local continuity_host_pid=5100
  local continuity_writer_proven=true
  local continuity_revalidation_started
  local continuity_observed

  case "${scenario}" in
    success|exact-six)
      ;;
    exact-start)
      probe_start=7000000000
      probe_end=13000000000
      start_observed=6500000000
      completion_observed=13500000000
      ;;
    exact-end)
      probe_start=25000000000
      probe_end=31000000000
      start_observed=24500000000
      completion_observed=31500000000
      ;;
    delayed-call-end|delayed-call-end-short-continuity)
      # The resumed lower bound predates both reviewed operator waits: 180 seconds for the
      # in-call acoustic proof and 90 seconds to end the call. The inter-ack CoreAudio snapshot,
      # readiness, and bounded verifier then consume reviewed time before the six-second probe. A
      # 330s UI duration admits this production shape; the short variant must fail closed.
      ready=282000000000
      probe_start=292000000000
      probe_end=298000000000
      start_observed=291000000000
      completion_observed=299000000000
      xcode_end=620000000000
      now=621000000000
      continuity=330000000000
      if [[ "${scenario}" == "delayed-call-end-short-continuity" ]]; then
        continuity=310000000000
      fi
      ;;
    one-ns-short)
      probe_end=15999999999
      completion_observed=16999999999
      ;;
    non-overlap)
      probe_start=25000000001
      probe_end=31000000001
      start_observed=24500000000
      completion_observed=31500000000
      ;;
    outside-start)
      probe_start=6999999999
      probe_end=12999999999
      start_observed=6500000000
      completion_observed=13500000000
      ;;
    equal-window)
      xcode_end=61000000000
      now=62000000000
      ;;
    inverted)
      probe_end=9999999999
      completion_observed=11000000000
      ;;
    stale-evidence)
      fixture_requested=$((requested - 1))
      ;;
    future-evidence)
      now=$((xcode_end - 1))
      ;;
    underflow)
      continuity=$((xcode_end + 1))
      ;;
    overflow)
      requested=9223372036854775700
      fixture_requested=${requested}
      resumed=9223372036854775750
      ready=9223372036854775760
      start_observed=9223372036854775770
      probe_start=9223372036854775780
      probe_end=9223372036854775790
      completion_observed=9223372036854775800
      xcode_end=9223372036854775807
      now=9223372036854775807
      continuity=100
      ;;
    mismatch)
      ui_nonce="${RAW_READY_NONCE}-stale"
      ;;
    pid-mismatch)
      ui_pid_end=7102
      ;;
    status-mismatch)
      wrapper_status=17
      ;;
    wait-status-mismatch)
      wait_status=17
      ;;
    continuity-routing-epoch-change)
      continuity_routing_epoch="fedcba9876543210fedcba9876543210"
      ;;
    continuity-peer-generation-change)
      continuity_peer_generation=2
      ;;
    continuity-device-generation-change)
      continuity_device_generation=2
      ;;
    continuity-host-pid-change)
      continuity_host_pid=5101
      ;;
    continuity-writer-revoked)
      continuity_writer_proven=false
      ;;
    *)
      return 100
      ;;
  esac
  reset_raw_overlap_evidence || return $?
  RAW_READY_REQUESTED_NS=${requested}
  RAW_READY_RESUMED_NS=${resumed}
  RAW_PROBE_STARTED_NS=${probe_start}
  RAW_PROBE_BOUND_PID=7101
  BLACKHOLE_PROBE_NONCE="${RAW_READY_NONCE}"
  OPENSTEAMER_SELF_TEST_RAW_NOW_NS=${now}
  if [[ "${scenario}" == "overflow" ]]; then
    continuity_revalidation_started=${completion_observed}
    continuity_observed=${completion_observed}
  else
    continuity_revalidation_started=$((completion_observed + 1))
    continuity_observed=$((completion_observed + 2))
  fi
  opensteamer_write_state "${RAW_READY_REQUEST}" "schema=opensteamer.raw-session-readiness.v3
nonce=${RAW_READY_NONCE}
requestedAtMonotonicNs=${fixture_requested}
cursorIdentity=self-test-log-identity
cursorOffset=0
cursorDigest=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" || return $?
  opensteamer_write_state "${RAW_READY_EVIDENCE}" "schema=opensteamer.raw-session-readiness.v5
nonce=${RAW_READY_NONCE}
requestedAtMonotonicNs=${fixture_requested}
resumedAtMonotonicNs=${resumed}
readyAtMonotonicNs=${ready}
probeStartedAtMonotonicNs=${probe_start}
productionPID=7101
hostPID=5100
blackHoleRoutingEpoch=0123456789abcdef0123456789abcdef
blackHolePeerGeneration=1
blackHoleDeviceGeneration=1
authenticatedConnectionCount=1
cursorIdentity=self-test-log-identity
cursorOffset=1
cursorDigest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
cursorPartialBytes=0
cursorPartialDigest=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" || return $?
  opensteamer_write_state "${RAW_UI_RUNTIME_EVIDENCE}" "schema=opensteamer.raw-ui-runtime.v1
nonce=${ui_nonce}
continuityDurationNs=${continuity}
appPIDAtStart=${ui_pid_start}
appPIDAtEnd=${ui_pid_end}" || return $?
  opensteamer_write_state "${RAW_UI_COMPLETION_OBSERVATION}" "schema=opensteamer.raw-ui-completion-observation.v1
nonce=${ui_nonce}
observedAtMonotonicNs=${xcode_end}" || return $?
  opensteamer_write_state "${RAW_PROBE_PROCESS_START_EVIDENCE}" "schema=opensteamer.production-app-probe-boundary.v1
boundary=start
nonce=${RAW_READY_NONCE}
bundleIdentifier=${EXPECTED_APP_BUNDLE_IDENTIFIER}
pid=7101
observedAtMonotonicNs=${start_observed}" || return $?
  opensteamer_write_state "${RAW_PROBE_PROCESS_COMPLETION_EVIDENCE}" "schema=opensteamer.production-app-probe-boundary.v1
boundary=completion
nonce=${RAW_READY_NONCE}
bundleIdentifier=${EXPECTED_APP_BUNDLE_IDENTIFIER}
pid=7101
observedAtMonotonicNs=${completion_observed}" || return $?
  opensteamer_write_state "${RAW_PROBE_COMPLETION_OBSERVATION}" "schema=opensteamer.blackhole-probe-completion-observation.v1
nonce=${RAW_READY_NONCE}
probeEndMonotonicNs=${probe_end}
completionObservedAtMonotonicNs=${completion_observed}
status=0
productionPIDAtCompletion=7101" || return $?
  opensteamer_write_state "${RAW_PROBE_WAIT_EVIDENCE}" "schema=opensteamer.blackhole-probe-wait.v1
nonce=${RAW_READY_NONCE}
wrapperPID=999
probeEndMonotonicNs=${probe_end}
completionStatus=0
waitStatus=${wait_status}" || return $?
  opensteamer_write_state "${RAW_BLACKHOLE_PROBE_COMPLETION}" "schema=opensteamer.blackhole-probe-completion.v1
nonce=${RAW_READY_NONCE}
probeStartMonotonicNs=${probe_start}
probeEndMonotonicNs=${probe_end}
status=${wrapper_status}
productionPIDAtStart=7101" || return $?
  opensteamer_write_state "${RAW_READY_CONTINUITY_EVIDENCE}" "schema=opensteamer.raw-session-continuity.v2
nonce=${RAW_READY_NONCE}
probeEndMonotonicNs=${probe_end}
revalidationStartedAtMonotonicNs=${continuity_revalidation_started}
observedAtMonotonicNs=${continuity_observed}
finalDrainCompletedAtMonotonicNs=$((continuity_observed + 1))
maximumWaitNs=8000000000
hostPID=${continuity_host_pid}
blackHoleRoutingEpoch=${continuity_routing_epoch}
blackHolePeerGeneration=${continuity_peer_generation}
blackHoleDeviceGeneration=${continuity_device_generation}
hiddenWriterSelectionProven=${continuity_writer_proven}
transportAuthorized=true
trackAdmitted=true
queueRunning=true
writerSelectionObservationCount=2
authorizationObservationCount=2
firstCallbackCount=1
lastCallbackCount=2
firstPullCount=1
lastPullCount=2
firstFrameCount=480
lastFrameCount=960
startCursorIdentity=self-test-log-identity
startCursorOffset=1
startCursorDigest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
startCursorPartialBytes=0
startCursorPartialDigest=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
endCursorOffset=2
endCursorDigest=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
endCursorPartialBytes=0
endCursorPartialDigest=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" || return $?
  opensteamer_write_state "${RAW_BLACKHOLE_PROBE_RESULT}" "{\"schema\":\"opensteamer.physical-blackhole-microphone.v1\",\"status\":\"passed\",\"runNonce\":\"${RAW_READY_NONCE}\"}"
}

function run_legacy_raw_readiness_self_test() {
  local scenario=${OPENSTEAMER_SCRIPT_SELF_TEST#raw-readiness-}
  local host_pid_file="${ARTIFACT_DIR}/raw-readiness-host-pid.txt"
  local writer_pid=""
  local ui_status=0
  local probe_status=0

  HOST_LOG="${ARTIFACT_DIR}/raw-readiness-host.log"
  OPENSTEAMER_SELF_TEST_HOST_PID_FILE=${host_pid_file}
  OPENSTEAMER_SELF_TEST_RAW_READINESS=1
  EXPECTED_INITIAL_HOST_PID=5100
  RAW_READY_TIMEOUT_SECONDS=1
  UI_TEST_TIMEOUT_SECONDS=5
  DEVICE_LOCK_POLL_SECONDS=10
  OPENSTEAMER_SELF_TEST_SIMPLE_UI_STATUS=0
  case "${scenario}" in
    success)
      OPENSTEAMER_SELF_TEST_SIMPLE_UI_DURATION=2
      OPENSTEAMER_SELF_TEST_RAW_PROBE_DURATION=0.4
      ;;
    stale|timeout)
      OPENSTEAMER_SELF_TEST_SIMPLE_UI_DURATION=2
      OPENSTEAMER_SELF_TEST_RAW_PROBE_DURATION=0.4
      ;;
    non-overlap)
      OPENSTEAMER_SELF_TEST_SIMPLE_UI_DURATION=1
      OPENSTEAMER_SELF_TEST_RAW_PROBE_DURATION=3
      ;;
    *)
      return 100
      ;;
  esac

  print -r -- "5100" > "${host_pid_file}" || return $?
  print -r -- "baseline" > "${HOST_LOG}" || return $?
  if [[ "${scenario}" == "stale" ]]; then
    opensteamer_write_state \
      "${RAW_READY_EVIDENCE}" \
      "schema=opensteamer.raw-session-readiness.v1 stale=true" || return $?
  fi
  if [[ "${scenario}" == "success" || "${scenario}" == "non-overlap" ]]; then
    (
      for ready_poll in {1..300}; do
        [[ -s "${RAW_READY_RESUMED_MARKER}" ]] && break
        sleep 0.01
      done
      [[ -s "${RAW_READY_RESUMED_MARKER}" ]] || exit 101
      print -r -- "Worldwide WebRTC peer state: connected pid=5100" \
        >> "${HOST_LOG}"
    ) &
    writer_pid=$!
  fi

  if run_simple_physical_ui_test \
      "${EXPECTED_RAW_TEST_NAME}" \
      "${RAW_RESULT_BUNDLE}" \
      "${RAW_DERIVED_DATA}" \
      "${RAW_UI_TEST_TIMEOUT_MARKER}" \
      "${RAW_DEVICE_LOCKED_MARKER}" \
      "${RAW_DEVICE_UNAVAILABLE_MARKER}" \
      "${RAW_WATCHDOG_STATE}" \
      "${RAW_WATCHDOG_FAILURE_MARKER}" \
      "${RAW_LOCK_STATE_DURING_TEST}" \
      "" \
      "" \
      "" \
      "test-without-building" \
      arm_raw_session_readiness_and_start_probe \
      1 \
      "${RAW_PROBE_OVERLAP_MARKER}"; then
    ui_status=0
  else
    ui_status=$?
  fi
  if [[ -n "${writer_pid}" ]]; then
    wait "${writer_pid}" || return $?
  fi

  case "${scenario}" in
    success)
      (( ui_status == 0 )) || return 102
      if wait_for_blackhole_probe_completion 2; then
        probe_status=0
      else
        probe_status=$?
      fi
      (( probe_status == 0 )) || return 103
      grep -qx 'state=accepted' "${RAW_READY_STATUS}" || return 104
      grep -qx 'state=probe-exited-while-ui-running' \
        "${RAW_PROBE_OVERLAP_MARKER}" || return 105
      [[ -s "${RAW_READY_EVIDENCE}" ]] || return 106
      ;;
    stale)
      (( ui_status == 124 )) || return 107
      grep -qx 'state=discarded-before-arm' \
        "${RAW_READY_STALE_MARKER}" || return 108
      [[ -z "${BLACKHOLE_PROBE_PID}" ]] || return 109
      ;;
    timeout)
      (( ui_status == 124 )) || return 110
      grep -qx 'state=timed-out' "${RAW_READY_TIMEOUT_MARKER}" || return 111
      [[ -z "${BLACKHOLE_PROBE_PID}" ]] || return 112
      ;;
    non-overlap)
      (( ui_status == 9 )) || return 113
      grep -qx 'state=ui-ended-before-probe-completed' \
        "${RAW_PROBE_NON_OVERLAP_MARKER}" || return 114
      [[ -z "${BLACKHOLE_PROBE_PID}" ]] || return 115
      ;;
  esac

  cleanup_blackhole_probe || true
  cleanup_xcodebuild || true
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
}

function run_raw_completion_self_test() {
  local scenario=$1
  local host_pid_file="${ARTIFACT_DIR}/raw-readiness-host-pid.txt"
  local routing_epoch="0123456789abcdef0123456789abcdef"
  local replacement_routing_epoch="fedcba9876543210fedcba9876543210"
  local writer_pid=""
  local writer_status=0
  local ui_status=0
  local probe_status=0

  HOST_LOG="${ARTIFACT_DIR}/raw-readiness-host.log"
  OPENSTEAMER_SELF_TEST_HOST_PID_FILE=${host_pid_file}
  OPENSTEAMER_SELF_TEST_RAW_READINESS=1
  EXPECTED_INITIAL_HOST_PID=5100
  RAW_READY_TIMEOUT_SECONDS=3
  RAW_CONTINUITY_REVALIDATION_TIMEOUT_SECONDS=2
  UI_TEST_TIMEOUT_SECONDS=7
  DEVICE_LOCK_POLL_SECONDS=10
  OPENSTEAMER_SELF_TEST_SIMPLE_UI_STATUS=0
  # The completion record is fsync'd on the reviewed external volume. Keep the inert UI alive
  # long enough for that durable rename while retaining a strict end-to-end self-test deadline.
  OPENSTEAMER_SELF_TEST_SIMPLE_UI_DURATION=5
  OPENSTEAMER_SELF_TEST_RAW_PROBE_DURATION=0.1
  case "${scenario}" in
    completion-success)
      ;;
    completion-missing-hidden-writer|completion-mismatched-hidden-writer-generation|completion-mismatched-hidden-writer-peer-generation|completion-mismatched-hidden-writer-routing-epoch|completion-mismatched-hidden-writer-pid|completion-stale-hidden-writer-after-pair-change|completion-stale-hidden-writer-after-routing-epoch-change|completion-post-launch-device-generation-change|completion-post-launch-peer-generation-change|completion-post-launch-routing-epoch-change|completion-post-launch-writer-revoked|completion-post-launch-disconnect)
      ;;
    completion-nonce-mismatch)
      OPENSTEAMER_SELF_TEST_RAW_COMPLETION_MODE=nonce-mismatch
      ;;
    completion-inverted)
      OPENSTEAMER_SELF_TEST_RAW_PROBE_END_OFFSET_NS=0
      ;;
    completion-nonzero)
      OPENSTEAMER_SELF_TEST_RAW_PROBE_STATUS=17
      ;;
    completion-malformed)
      OPENSTEAMER_SELF_TEST_RAW_COMPLETION_MODE=malformed
      ;;
    completion-wait-status-mismatch)
      OPENSTEAMER_SELF_TEST_RAW_PROBE_STATUS=17
      OPENSTEAMER_SELF_TEST_RAW_REPORTED_STATUS=0
      ;;
    completion-absent-pid)
      OPENSTEAMER_SELF_TEST_RAW_APP_COMPLETION_PID=absent
      ;;
    completion-changed-pid)
      OPENSTEAMER_SELF_TEST_RAW_APP_COMPLETION_PID=7102
      ;;
    runner-alive-without-completion)
      OPENSTEAMER_SELF_TEST_RAW_COMPLETION_MODE=missing
      ;;
    *)
      return 100
      ;;
  esac

  print -r -- "5100" > "${host_pid_file}" || return $?
  print -r -- "baseline" > "${HOST_LOG}" || return $?
  (
    for ready_poll in {1..300}; do
      [[ -s "${RAW_READY_RESUMED_MARKER}" ]] && break
      sleep 0.01
    done
    [[ -s "${RAW_READY_RESUMED_MARKER}" ]] || exit 101
    if [[ "${scenario}" == "completion-stale-hidden-writer-after-pair-change" ]]; then
      print -r -- "Worldwide authenticated media route selected BlackHole default input routingEpoch=${routing_epoch} peerGeneration=1 deviceGeneration=1 pid=5100" \
        >> "${HOST_LOG}"
      print -r -- "Worldwide iPhone microphone hidden writer selected routingEpoch=${routing_epoch} peerGeneration=1 deviceGeneration=1 pid=5100" \
        >> "${HOST_LOG}"
      sleep 0.2
      print -r -- "Worldwide WebRTC peer state: connected pid=5100" \
        >> "${HOST_LOG}"
      print -r -- "Worldwide authenticated media route selected BlackHole default input routingEpoch=${routing_epoch} peerGeneration=1 deviceGeneration=2 pid=5100" \
        >> "${HOST_LOG}"
    elif [[ "${scenario}" == "completion-stale-hidden-writer-after-routing-epoch-change" ]]; then
      print -r -- "Worldwide authenticated media route selected BlackHole default input routingEpoch=${routing_epoch} peerGeneration=1 deviceGeneration=1 pid=5100" \
        >> "${HOST_LOG}"
      print -r -- "Worldwide iPhone microphone hidden writer selected routingEpoch=${routing_epoch} peerGeneration=1 deviceGeneration=1 pid=5100" \
        >> "${HOST_LOG}"
      sleep 0.2
      print -r -- "Worldwide WebRTC peer state: connected pid=5100" \
        >> "${HOST_LOG}"
      print -r -- "Worldwide authenticated media route selected BlackHole default input routingEpoch=${replacement_routing_epoch} peerGeneration=1 deviceGeneration=1 pid=5100" \
        >> "${HOST_LOG}"
    else
      print -r -- "Worldwide WebRTC peer state: connected pid=5100" \
        >> "${HOST_LOG}"
      print -r -- "Worldwide authenticated media route selected BlackHole default input routingEpoch=${routing_epoch} peerGeneration=1 deviceGeneration=1 pid=5100" \
        >> "${HOST_LOG}"
      if [[ "${scenario}" != "completion-missing-hidden-writer" ]]; then
        if [[ "${scenario}" == "completion-mismatched-hidden-writer-generation" ]]; then
          print -r -- "Worldwide iPhone microphone hidden writer selected routingEpoch=${routing_epoch} peerGeneration=1 deviceGeneration=2 pid=5100" \
            >> "${HOST_LOG}"
        elif [[ "${scenario}" == "completion-mismatched-hidden-writer-peer-generation" ]]; then
          print -r -- "Worldwide iPhone microphone hidden writer selected routingEpoch=${routing_epoch} peerGeneration=2 deviceGeneration=1 pid=5100" \
            >> "${HOST_LOG}"
        elif [[ "${scenario}" == "completion-mismatched-hidden-writer-routing-epoch" ]]; then
          print -r -- "Worldwide iPhone microphone hidden writer selected routingEpoch=${replacement_routing_epoch} peerGeneration=1 deviceGeneration=1 pid=5100" \
            >> "${HOST_LOG}"
        elif [[ "${scenario}" == "completion-mismatched-hidden-writer-pid" ]]; then
          print -r -- "Worldwide iPhone microphone hidden writer selected routingEpoch=${routing_epoch} peerGeneration=1 deviceGeneration=1 pid=51000" \
            >> "${HOST_LOG}"
        else
          print -r -- "Worldwide iPhone microphone hidden writer selected routingEpoch=${routing_epoch} peerGeneration=1 deviceGeneration=1 pid=5100" \
            >> "${HOST_LOG}"
        fi
      fi
    fi
    case "${scenario}" in
      completion-success|completion-wait-status-mismatch|completion-post-launch-device-generation-change|completion-post-launch-peer-generation-change|completion-post-launch-routing-epoch-change|completion-post-launch-writer-revoked|completion-post-launch-disconnect)
        for continuity_poll in {1..1000}; do
          [[ -s "${RAW_READY_CONTINUITY_ARMED_MARKER}" ]] && break
          sleep 0.01
        done
        [[ -s "${RAW_READY_CONTINUITY_ARMED_MARKER}" ]] || exit 102
        case "${scenario}" in
          completion-success|completion-wait-status-mismatch)
            for continuity_sample in 1 2; do
              print -r -- "Worldwide iPhone microphone forwarding phase=forwardingHealthy inputEndpointAvailable=true hiddenSinkAvailable=true hiddenWriterSelectionProven=true transport=true trackAdmitted=true queueRunning=true callbacks=${continuity_sample} pulls=${continuity_sample} frames=$((continuity_sample * 480)) silenceFallbacks=0" \
                >> "${HOST_LOG}"
              print -r -- "Worldwide iPhone microphone hidden writer selected routingEpoch=${routing_epoch} peerGeneration=1 deviceGeneration=1 pid=5100" \
                >> "${HOST_LOG}"
              sleep 0.05
            done
            ;;
          completion-post-launch-device-generation-change)
            print -r -- "Worldwide authenticated media route selected BlackHole default input routingEpoch=${routing_epoch} peerGeneration=1 deviceGeneration=2 pid=5100" \
              >> "${HOST_LOG}"
            ;;
          completion-post-launch-peer-generation-change)
            print -r -- "Worldwide authenticated media route selected BlackHole default input routingEpoch=${routing_epoch} peerGeneration=2 deviceGeneration=1 pid=5100" \
              >> "${HOST_LOG}"
            ;;
          completion-post-launch-routing-epoch-change)
            print -r -- "Worldwide authenticated media route selected BlackHole default input routingEpoch=${replacement_routing_epoch} peerGeneration=1 deviceGeneration=1 pid=5100" \
              >> "${HOST_LOG}"
            ;;
          completion-post-launch-writer-revoked)
            print -r -- \
              "Worldwide iPhone microphone forwarding phase=forwardingHealthy inputEndpointAvailable=true hiddenSinkAvailable=true hiddenWriterSelectionProven=true transport=true trackAdmitted=true queueRunning=true callbacks=1 pulls=1 frames=480 silenceFallbacks=0"$'\n'\
"Worldwide iPhone microphone hidden writer selected routingEpoch=${routing_epoch} peerGeneration=1 deviceGeneration=1 pid=5100"$'\n'\
"Worldwide iPhone microphone forwarding phase=forwardingHealthy inputEndpointAvailable=true hiddenSinkAvailable=true hiddenWriterSelectionProven=true transport=true trackAdmitted=true queueRunning=true callbacks=2 pulls=2 frames=960 silenceFallbacks=0"$'\n'\
"Worldwide iPhone microphone hidden writer selected routingEpoch=${routing_epoch} peerGeneration=1 deviceGeneration=1 pid=5100"$'\n'\
"Worldwide iPhone microphone forwarding phase=waitingForTransport inputEndpointAvailable=true hiddenSinkAvailable=true hiddenWriterSelectionProven=false transport=false trackAdmitted=false queueRunning=false callbacks=2 pulls=2 frames=960 silenceFallbacks=0" \
              >> "${HOST_LOG}"
            ;;
          completion-post-launch-disconnect)
            print -r -- "Worldwide WebRTC peer state: disconnected pid=5100" \
              >> "${HOST_LOG}"
            ;;
        esac
        ;;
    esac
  ) &
  writer_pid=$!

  if run_simple_physical_ui_test \
      "${EXPECTED_RAW_TEST_NAME}" \
      "${RAW_RESULT_BUNDLE}" \
      "${RAW_DERIVED_DATA}" \
      "${RAW_UI_TEST_TIMEOUT_MARKER}" \
      "${RAW_DEVICE_LOCKED_MARKER}" \
      "${RAW_DEVICE_UNAVAILABLE_MARKER}" \
      "${RAW_WATCHDOG_STATE}" \
      "${RAW_WATCHDOG_FAILURE_MARKER}" \
      "${RAW_LOCK_STATE_DURING_TEST}" \
      "" \
      "" \
      "" \
      "test-without-building" \
      arm_raw_session_readiness_and_start_probe \
      1 \
      "${RAW_PROBE_COMPLETION_OBSERVATION}"; then
    ui_status=0
  else
    ui_status=$?
  fi
  if /bin/kill -0 "${writer_pid}" 2>/dev/null; then
    /bin/kill -TERM "${writer_pid}" 2>/dev/null || true
  fi
  if wait "${writer_pid}"; then
    writer_status=0
  else
    writer_status=$?
  fi
  writer_pid=""
  case "${scenario}" in
    completion-success)
      (( ui_status == 0 )) || return 102
      if wait_for_blackhole_probe_completion 8; then
        probe_status=0
      else
        probe_status=$?
      fi
      (( probe_status == 0 )) || return 103
      [[ -s "${RAW_PROBE_COMPLETION_OBSERVATION}" ]] || return 104
      [[ -s "${RAW_PROBE_WAIT_EVIDENCE}" ]] || return 105
      [[ -s "${RAW_READY_CONTINUITY_EVIDENCE}" ]] || return 106
      ;;
    completion-wait-status-mismatch)
      (( ui_status == 0 )) || return 106
      if wait_for_blackhole_probe_completion 8; then
        return 107
      else
        probe_status=$?
      fi
      (( probe_status == 3 )) || return 108
      ;;
    runner-alive-without-completion)
      (( ui_status == 9 )) || return 109
      ;;
    completion-missing-hidden-writer|completion-mismatched-hidden-writer-generation|completion-mismatched-hidden-writer-peer-generation|completion-mismatched-hidden-writer-routing-epoch|completion-mismatched-hidden-writer-pid|completion-stale-hidden-writer-after-pair-change|completion-stale-hidden-writer-after-routing-epoch-change)
      (( ui_status == 124 )) || return 112
      grep -qx 'state=timed-out' "${RAW_READY_TIMEOUT_MARKER}" || return 113
      ;;
    completion-post-launch-device-generation-change|completion-post-launch-peer-generation-change|completion-post-launch-routing-epoch-change|completion-post-launch-writer-revoked|completion-post-launch-disconnect)
      (( ui_status == 7 )) || return 114
      [[ ! -e "${RAW_READY_CONTINUITY_EVIDENCE}" ]] || return 117
      [[ -s "${RAW_PROBE_NON_OVERLAP_MARKER}" ]] || return 118
      ;;
    completion-nonce-mismatch|completion-inverted|completion-nonzero|completion-malformed|completion-absent-pid|completion-changed-pid)
      (( ui_status == 7 )) || return 110
      ;;
  esac
  (( writer_status == 0 || writer_status == 143 )) || return "${writer_status}"

  cleanup_blackhole_probe || true
  cleanup_xcodebuild || true
  if [[ "${scenario}" != "completion-success" ]]; then
    clear_raw_overlap_success_evidence 2>/dev/null || true
    [[ ! -e "${RAW_PROBE_OVERLAP_MARKER}" ]] || return 111
  fi
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
}

function run_raw_readiness_self_test() {
  local scenario=${OPENSTEAMER_SCRIPT_SELF_TEST#raw-readiness-}
  local overlap_status=0
  local export_status=0

  case "${scenario}" in
    stale|timeout)
      run_legacy_raw_readiness_self_test
      return $?
      ;;
    completion-*|runner-alive-without-completion)
      run_raw_completion_self_test "${scenario}"
      return $?
      ;;
    stale-export|invalid-export-payload)
      prepare_raw_overlap_contract || return $?
      if [[ "${scenario}" == "invalid-export-payload" ]]; then
        print -r -- "invalid-payload" \
          > "${RAW_UI_RUNTIME_ATTACHMENT_PAYLOAD_ID}" || return $?
      else
        print -r -- "0~RawRuntimeAttachmentPayload_abcdefghijklmnop" \
          > "${RAW_UI_RUNTIME_ATTACHMENT_PAYLOAD_ID}" || return $?
      fi
      print -r -- "stale-output" > "${RAW_UI_RUNTIME_EVIDENCE}" || return $?
      if [[ "${scenario}" == "stale-export" ]]; then
        OPENSTEAMER_SELF_TEST_RAW_ATTACHMENT_EXPORT_FAILURE=1
      fi
      if capture_ui_xcresult_attachment_payload \
          "${RAW_RESULT_BUNDLE}" \
          "${RAW_UI_RUNTIME_ATTACHMENT_PAYLOAD_ID}" \
          "${RAW_UI_RUNTIME_EVIDENCE}"; then
        return 126
      else
        export_status=$?
      fi
      unset OPENSTEAMER_SELF_TEST_RAW_ATTACHMENT_EXPORT_FAILURE
      if [[ "${scenario}" == "invalid-export-payload" ]]; then
        (( export_status == 3 )) || return 127
      else
        (( export_status == 41 )) || return 128
      fi
      [[ ! -e "${RAW_UI_RUNTIME_EVIDENCE}" ]] || return 129
      [[ ! -e "${RAW_PROBE_OVERLAP_MARKER}" ]] || return 130
      opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
      RUN_SUCCEEDED=1
      return 0
      ;;
  esac

  prepare_raw_overlap_contract || return $?
  write_raw_overlap_self_test_fixture "${scenario}" || return $?
  if validate_and_retain_raw_overlap_evidence; then
    overlap_status=0
  else
    overlap_status=$?
  fi
  case "${scenario}" in
    success|exact-start|exact-end|exact-six|delayed-call-end)
      (( overlap_status == 0 )) || return 131
      [[ -s "${RAW_UI_BOUNDS_EVIDENCE}" ]] || return 132
      [[ -s "${RAW_PROBE_INTERVAL_EVIDENCE}" ]] || return 133
      [[ -s "${RAW_PROBE_OVERLAP_MARKER}" ]] || return 134
      [[ ! -e "${RAW_PROBE_NON_OVERLAP_MARKER}" ]] || return 135
      ;;
    *)
      (( overlap_status != 0 )) || return 136
      [[ ! -e "${RAW_UI_BOUNDS_EVIDENCE}" ]] || return 137
      [[ ! -e "${RAW_PROBE_INTERVAL_EVIDENCE}" ]] || return 138
      [[ ! -e "${RAW_PROBE_OVERLAP_MARKER}" ]] || return 139
      [[ -s "${RAW_PROBE_NON_OVERLAP_MARKER}" ]] || return 140
      ;;
  esac
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
}

function run_raw_ui_completion_handshake_self_test() {
  local scenario=${OPENSTEAMER_SCRIPT_SELF_TEST#raw-ui-completion-handshake-}
  local live_output="${ARTIFACT_DIR}/synthetic-live-xcodebuild.txt"
  local completion_status=0
  local observed_nonce
  local observed_at_ns

  OPENSTEAMER_SELF_TEST_RAW_READINESS=1
  prepare_raw_overlap_contract || return $?
  case "${scenario}" in
    success)
      print -r -- \
        "OPENSTEAMER_RAW_UI_CONTINUITY_COMPLETE_V1 nonce=${RAW_READY_NONCE}" \
        > "${live_output}" || return $?
      if capture_raw_ui_completion_observation_from_log "${live_output}"; then
        completion_status=0
      else
        completion_status=$?
      fi
      (( completion_status == 0 )) || return 141
      [[ -s "${RAW_UI_COMPLETION_OBSERVATION}" ]] || return 142
      observed_nonce=$(raw_evidence_value \
        "${RAW_UI_COMPLETION_OBSERVATION}" nonce) || return $?
      observed_at_ns=$(raw_evidence_value \
        "${RAW_UI_COMPLETION_OBSERVATION}" observedAtMonotonicNs) || return $?
      [[ "${observed_nonce}" == "${RAW_READY_NONCE}" ]] || return 143
      [[ "${observed_at_ns}" != *[^0-9]* ]] || return 144
      (( observed_at_ns > 0 )) || return 145
      ;;
    late)
      {
        print -r -- \
          "OPENSTEAMER_RAW_UI_CONTINUITY_COMPLETE_V1 nonce=${RAW_READY_NONCE}"
        print -r -- \
          "OPENSTEAMER_RAW_UI_TEARDOWN_BEGIN_V1 nonce=${RAW_READY_NONCE}"
      } > "${live_output}" || return $?
      if capture_raw_ui_completion_observation_from_log "${live_output}"; then
        completion_status=0
      else
        completion_status=$?
      fi
      (( completion_status == 9 )) || return 146
      [[ ! -e "${RAW_UI_COMPLETION_OBSERVATION}" ]] || return 147
      ;;
    nonce-mismatch)
      print -r -- \
        "OPENSTEAMER_RAW_UI_CONTINUITY_COMPLETE_V1 nonce=${RAW_READY_NONCE}-stale" \
        > "${live_output}" || return $?
      if capture_raw_ui_completion_observation_from_log "${live_output}"; then
        completion_status=0
      else
        completion_status=$?
      fi
      (( completion_status == 1 )) || return 148
      [[ ! -e "${RAW_UI_COMPLETION_OBSERVATION}" ]] || return 149
      ;;
    *)
      return 150
      ;;
  esac
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
}

function run_raw_ui_causal_state_handshake_self_test() {
  local scenario=${OPENSTEAMER_SCRIPT_SELF_TEST#raw-ui-causal-state-handshake-}
  local live_output="${ARTIFACT_DIR}/synthetic-causal-live-xcodebuild.txt"
  local capture_status=0

  OPENSTEAMER_SELF_TEST_RAW_READINESS=1
  RAW_UI_CAUSAL_STATE_OBSERVATION="${ARTIFACT_DIR}/raw-ui-causal-state-observation.txt"
  prepare_raw_overlap_contract || return $?
  RAW_READY_RESUMED_NS=1
  CALL_ACOUSTIC_ACCEPTED_TOKEN=self-test-acoustic-token
  CALL_ACOUSTIC_ACCEPTED_NS=2
  case "${scenario}" in
    success)
      print -r -- \
        "OPENSTEAMER_CALL_UI_HOSTED_ACTIVE_V2 nonce=${RAW_READY_NONCE} sequence=1 acousticToken=-" \
        > "${live_output}" || return $?
      capture_call_ui_hosted_state_observation_from_log \
        "${live_output}" 1 - "${RAW_READY_RESUMED_NS}" \
        "${CALL_UI_HOSTED_PRE_ACK_OBSERVATION}" \
        || return 163
      print -r -- \
        "OPENSTEAMER_CALL_UI_HOSTED_ACTIVE_V2 nonce=${RAW_READY_NONCE} sequence=2 acousticToken=${CALL_ACOUSTIC_ACCEPTED_TOKEN}" \
        >> "${live_output}" || return $?
      capture_call_ui_hosted_state_observation_from_log \
        "${live_output}" 2 "${CALL_ACOUSTIC_ACCEPTED_TOKEN}" \
        "${CALL_ACOUSTIC_ACCEPTED_NS}" \
        "${RAW_UI_CAUSAL_STATE_OBSERVATION}" || return 164
      [[ "$(raw_evidence_value \
          "${RAW_UI_CAUSAL_STATE_OBSERVATION}" state)" \
          == "hosted-call-active" ]] || return 165
      [[ "$(raw_evidence_value \
          "${RAW_UI_CAUSAL_STATE_OBSERVATION}" sequence)" \
          == "2" ]] || return 166
      [[ "$(raw_evidence_value \
          "${RAW_UI_CAUSAL_STATE_OBSERVATION}" resumedAtMonotonicNs)" \
          == "${RAW_READY_RESUMED_NS}" ]] || return 167
      ;;
    nonce-mismatch)
      print -r -- \
        "OPENSTEAMER_CALL_UI_HOSTED_ACTIVE_V2 nonce=${RAW_READY_NONCE}-stale sequence=1 acousticToken=-" \
        > "${live_output}" || return $?
      if capture_call_ui_hosted_state_observation_from_log \
          "${live_output}" 1 - "${RAW_READY_RESUMED_NS}" \
          "${CALL_UI_HOSTED_PRE_ACK_OBSERVATION}"; then
        capture_status=0
      else
        capture_status=$?
      fi
      (( capture_status == 1 )) || return 168
      [[ ! -e "${CALL_UI_HOSTED_PRE_ACK_OBSERVATION}" ]] || return 169
      ;;
    duplicate)
      {
        print -r -- \
          "OPENSTEAMER_CALL_UI_HOSTED_ACTIVE_V2 nonce=${RAW_READY_NONCE} sequence=1 acousticToken=-"
        print -r -- \
          "OPENSTEAMER_CALL_UI_HOSTED_ACTIVE_V2 nonce=${RAW_READY_NONCE} sequence=1 acousticToken=-"
      } > "${live_output}" || return $?
      if capture_call_ui_hosted_state_observation_from_log \
          "${live_output}" 1 - "${RAW_READY_RESUMED_NS}" \
          "${CALL_UI_HOSTED_PRE_ACK_OBSERVATION}"; then
        capture_status=0
      else
        capture_status=$?
      fi
      (( capture_status == 9 )) || return 170
      [[ ! -e "${CALL_UI_HOSTED_PRE_ACK_OBSERVATION}" ]] || return 171
      ;;
    ordinary-before-heard)
      {
        print -r -- \
          "OPENSTEAMER_CALL_UI_HOSTED_ACTIVE_V2 nonce=${RAW_READY_NONCE} sequence=1 acousticToken=-"
        print -r -- \
          "OPENSTEAMER_CALL_UI_ORDINARY_BEFORE_ACOUSTIC_V1 nonce=${RAW_READY_NONCE}"
      } > "${live_output}" || return $?
      capture_call_ui_hosted_state_observation_from_log \
        "${live_output}" 1 - "${RAW_READY_RESUMED_NS}" \
        "${CALL_UI_HOSTED_PRE_ACK_OBSERVATION}" || return 173
      if capture_call_ui_hosted_state_observation_from_log \
          "${live_output}" 2 "${CALL_ACOUSTIC_ACCEPTED_TOKEN}" \
          "${CALL_ACOUSTIC_ACCEPTED_NS}" \
          "${RAW_UI_CAUSAL_STATE_OBSERVATION}"; then
        return 174
      else
        capture_status=$?
      fi
      (( capture_status == 1 )) || return 175
      [[ ! -e "${RAW_UI_CAUSAL_STATE_OBSERVATION}" ]] || return 176
      ;;
    *)
      return 172
      ;;
  esac
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
}

function run_blackhole_probe_diagnostic_self_test() {
  local scenario=${OPENSTEAMER_SCRIPT_SELF_TEST#blackhole-probe-diagnostic-}
  local observed_status=0

  case "${scenario}" in
    success)
      start_bounded_blackhole_probe_process \
        /bin/zsh -c 'print -r -- harmless; exit 0' diagnostic-success || return $?
      if wait_for_blackhole_probe_completion 3; then
        observed_status=0
      else
        observed_status=$?
      fi
      (( observed_status == 0 )) || return 116
      [[ ! -e "${RAW_BLACKHOLE_PROBE_DIAGNOSTICS}" ]] || return 117
      ;;
    failure)
      start_bounded_blackhole_probe_process \
        /bin/zsh -c 'print -r -- synthetic-probe-failure >&2; /usr/bin/yes x | /usr/bin/head -c 100000 >&2; exit 17' \
        diagnostic-failure || return $?
      if wait_for_blackhole_probe_completion 3; then
        return 118
      else
        observed_status=$?
      fi
      (( observed_status == 17 )) || return 119
      grep -q 'synthetic-probe-failure' \
        "${RAW_BLACKHOLE_PROBE_DIAGNOSTICS}" || return 120
      ;;
    uid-leak)
      start_bounded_blackhole_probe_process \
        /bin/zsh -c 'print -r -- "$1" >&2; exit 0' \
        diagnostic-uid-leak \
        "${PHYSICAL_OUTPUT_UID}" || return $?
      if wait_for_blackhole_probe_completion 3; then
        return 121
      else
        observed_status=$?
      fi
      (( observed_status == 86 )) || return 122
      grep -qx 'diagnostic=runtime-uid-output-rejected' \
        "${RAW_BLACKHOLE_PROBE_DIAGNOSTICS}" || return 123
      ;;
    wedged-after-completion)
      OPENSTEAMER_SELF_TEST_RAW_COMPLETION_MODE=wedged-after-completion
      start_bounded_blackhole_probe_process \
        /bin/zsh -c 'exit 0' diagnostic-wedged-after-completion || return $?
      if wait_for_blackhole_probe_completion 1; then
        return 171
      else
        observed_status=$?
      fi
      (( observed_status == 124 )) || return 172
      [[ -z "${BLACKHOLE_PROBE_PID}" ]] || return 173
      /usr/bin/grep -Fxq \
        'state=wrapper-timed-out-after-completion status=124' \
        "${RAW_BLACKHOLE_PROBE_CLEANUP_PROOF}" || return 174
      ;;
    *)
      return 124
      ;;
  esac
  reject_runtime_uid_in_retained_artifacts || return 125
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
}

if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == critical-failure-* ]]; then
  run_critical_failure_self_test
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == raw-readiness-* ]]; then
  run_raw_readiness_self_test
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == raw-ui-completion-handshake-* ]]; then
  run_raw_ui_completion_handshake_self_test
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == raw-ui-causal-state-handshake-* ]]; then
  run_raw_ui_causal_state_handshake_self_test
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == blackhole-probe-diagnostic-* ]]; then
  run_blackhole_probe_diagnostic_self_test
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == production-app-termination-* ]]; then
  terminate_production_app_for_call_phase
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "reject-runtime-uid" ]]; then
  reject_runtime_uid_in_retained_artifacts
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi

if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "validate-blackhole-probe-json" ]]; then
  validate_blackhole_probe_json \
    "${OPENSTEAMER_SELF_TEST_PROBE_JSON:?missing probe JSON fixture}" \
    "${OPENSTEAMER_SELF_TEST_PROBE_NONCE:?missing probe nonce}" \
    "${PHYSICAL_OUTPUT_UID}"
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "validate-default-input-lifecycle" ]]; then
  if [[ -n "${OPENSTEAMER_SELF_TEST_DEFAULT_INPUT_DURING:-}" ]]; then
    validate_default_input_lifecycle_json \
      "${OPENSTEAMER_SELF_TEST_DEFAULT_INPUT_BEFORE:?missing before fixture}" \
      "${OPENSTEAMER_SELF_TEST_DEFAULT_INPUT_HEALTHY:?missing healthy fixture}" \
      "${OPENSTEAMER_SELF_TEST_DEFAULT_INPUT_AFTER:?missing after fixture}" \
      "${OPENSTEAMER_SELF_TEST_DEFAULT_INPUT_PROBE_START:?missing probe start}" \
      "${OPENSTEAMER_SELF_TEST_DEFAULT_INPUT_DURING}" \
      "${OPENSTEAMER_SELF_TEST_DEFAULT_INPUT_PROBE_END:?missing probe end}"
  else
    validate_default_input_lifecycle_json \
      "${OPENSTEAMER_SELF_TEST_DEFAULT_INPUT_BEFORE:?missing before fixture}" \
      "${OPENSTEAMER_SELF_TEST_DEFAULT_INPUT_HEALTHY:?missing healthy fixture}" \
      "${OPENSTEAMER_SELF_TEST_DEFAULT_INPUT_AFTER:?missing after fixture}" \
      "${OPENSTEAMER_SELF_TEST_DEFAULT_INPUT_PROBE_START:?missing probe start}"
  fi
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "validate-raw-activities" ]]; then
  validate_raw_physical_activities_json \
    "${OPENSTEAMER_SELF_TEST_ACTIVITIES_JSON:?missing activity fixture}"
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "validate-call-activities" ]]; then
  validate_call_physical_activities_json \
    "${OPENSTEAMER_SELF_TEST_ACTIVITIES_JSON:?missing activity fixture}"
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "phase-order" ]]; then
  begin_phase 1 raw-iphone-microphone-blackhole "${RAW_PHASE_STATUS}"
  complete_phase 1 raw-iphone-microphone-blackhole "${RAW_PHASE_STATUS}"
  begin_phase 2 reconnect-background-screen "${RECONNECT_PHASE_STATUS}"
  complete_phase 2 reconnect-background-screen "${RECONNECT_PHASE_STATUS}"
  begin_phase 3 real-connected-call "${CALL_PHASE_STATUS}"
  complete_phase 3 real-connected-call "${CALL_PHASE_STATUS}"
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "phase-failure-raw" ]]; then
  begin_phase 1 raw-iphone-microphone-blackhole "${RAW_PHASE_STATUS}"
  function fail_raw_phase_self_test() { return 11 }
  fail_raw_phase_self_test
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "phase-failure-reconnect" ]]; then
  begin_phase 1 raw-iphone-microphone-blackhole "${RAW_PHASE_STATUS}"
  complete_phase 1 raw-iphone-microphone-blackhole "${RAW_PHASE_STATUS}"
  begin_phase 2 reconnect-background-screen "${RECONNECT_PHASE_STATUS}"
  function fail_reconnect_phase_self_test() { return 12 }
  fail_reconnect_phase_self_test
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "phase-failure-call" ]]; then
  begin_phase 1 raw-iphone-microphone-blackhole "${RAW_PHASE_STATUS}"
  complete_phase 1 raw-iphone-microphone-blackhole "${RAW_PHASE_STATUS}"
  begin_phase 2 reconnect-background-screen "${RECONNECT_PHASE_STATUS}"
  complete_phase 2 reconnect-background-screen "${RECONNECT_PHASE_STATUS}"
  begin_phase 3 real-connected-call "${CALL_PHASE_STATUS}"
  function fail_call_phase_self_test() { return 13 }
  fail_call_phase_self_test
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "blackhole-probe-exit-failure" ]]; then
  start_bounded_blackhole_probe_process \
    /bin/zsh -c 'sleep 0.2; exit 1' blackhole-exit-failure
  if wait_for_blackhole_probe_completion 3; then
    exit 60
  fi
  [[ "${BLACKHOLE_PROBE_STATUS}" == "1" ]] || exit 61
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "blackhole-probe-timeout" ]]; then
  start_bounded_blackhole_probe_process \
    /bin/zsh -c 'trap "" TERM HUP; sleep 30' blackhole-timeout
  if wait_for_blackhole_probe_completion 1; then
    exit 62
  fi
  [[ "${BLACKHOLE_PROBE_STATUS}" == "124" ]] || exit 63
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "blackhole-probe-group-cleanup" ]]; then
  opensteamer_start_isolated_validation_process \
    /bin/zsh -c 'trap "exit 0" TERM; while true; do sleep 30; done'
  validation_pid=${XCODEBUILD_PID}
  print -r -- "${validation_pid}" \
    > "${ARTIFACT_DIR}/blackhole-validation-sentinel-pid.txt"
  opensteamer_exec_in_isolated_process_group \
    /bin/zsh -c 'trap "" TERM HUP; sleep 30' &
  BLACKHOLE_PROBE_PID=$!
  BLACKHOLE_PROBE_STARTED_SECONDS=${SECONDS}
  print -r -- "${BLACKHOLE_PROBE_PID}" \
    > "${ARTIFACT_DIR}/blackhole-probe-leader-pid.txt"
  opensteamer_require_isolated_process_group "${BLACKHOLE_PROBE_PID}" 3
  cleanup_blackhole_probe
  [[ "${XCODEBUILD_PID}" == "${validation_pid}" ]] || exit 64
  kill -0 "${validation_pid}" 2>/dev/null || exit 65
  opensteamer_terminate_isolated_process_group \
    "${validation_pid}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
  opensteamer_wait_for_final_process_status "${validation_pid}" || true
  XCODEBUILD_PID=""
  XCODEBUILD_GROUP_ISOLATED=0
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "call-ready-success" ]]; then
  OPENSTEAMER_SELF_TEST_CALL_READY_TOKEN="self-test-call-ready-token"
  CALL_READY_TIMEOUT_SECONDS=3
  terminate_production_app_for_call_phase
  print -r -- \
    "phase=3 event=production-app-terminated" \
    >> "${PHASE_EVENTS}"
  (
    for ready_poll in {1..200}; do
      [[ -s "${CALL_READY_REQUEST}" ]] && break
      sleep 0.01
    done
    [[ -s "${CALL_READY_REQUEST}" ]] || exit 70
    ready_token=$(cat "${CALL_READY_REQUEST}")
    ready_token=${ready_token#ready-token=}
    opensteamer_write_state \
      "${CALL_READY_ACKNOWLEDGEMENT}" "ready=${ready_token}"
  ) &
  call_ready_writer_pid=$!
  wait_for_fresh_call_ready_acknowledgement
  wait "${call_ready_writer_pid}"
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "call-ready-late-after-query" \
    || "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "call-ready-late-after-read" ]]; then
  OPENSTEAMER_SELF_TEST_CALL_READY_TOKEN="self-test-call-ready-token"
  if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST}" == "call-ready-late-after-query" ]]; then
    OPENSTEAMER_SELF_TEST_ACK_QUERY_DELAY_SECONDS=1.2
  else
    OPENSTEAMER_SELF_TEST_ACK_POST_READ_DELAY_SECONDS=1.2
  fi
  CALL_READY_TIMEOUT_SECONDS=1
  terminate_production_app_for_call_phase
  print -r -- \
    "phase=3 event=production-app-terminated" \
    >> "${PHASE_EVENTS}"
  (
    for ready_poll in {1..200}; do
      [[ -s "${CALL_READY_REQUEST}" ]] && break
      sleep 0.01
    done
    [[ -s "${CALL_READY_REQUEST}" ]] || exit 151
    ready_token=$(<"${CALL_READY_REQUEST}")
    ready_token=${ready_token#ready-token=}
    opensteamer_write_state \
      "${CALL_READY_ACKNOWLEDGEMENT}" "ready=${ready_token}"
  ) &
  call_ready_writer_pid=$!
  if wait_for_fresh_call_ready_acknowledgement; then
    exit 152
  fi
  wait "${call_ready_writer_pid}"
  /usr/bin/grep -Fxq 'state=timed-out' "${CALL_READY_STATUS}" || exit 153
  ! /usr/bin/grep -Fq 'event=call-ready-accepted' "${PHASE_EVENTS}" || exit 154
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "call-ready-timeout" ]]; then
  OPENSTEAMER_SELF_TEST_CALL_READY_TOKEN="self-test-call-ready-token"
  CALL_READY_TIMEOUT_SECONDS=1
  terminate_production_app_for_call_phase
  print -r -- \
    "phase=3 event=production-app-terminated" \
    >> "${PHASE_EVENTS}"
  if wait_for_fresh_call_ready_acknowledgement; then
    exit 71
  fi
  grep -qx 'state=timed-out' "${CALL_READY_STATUS}" || exit 72
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "call-ready-stale" ]]; then
  OPENSTEAMER_SELF_TEST_CALL_READY_TOKEN="self-test-call-ready-token"
  CALL_READY_TIMEOUT_SECONDS=1
  opensteamer_write_state \
    "${CALL_READY_ACKNOWLEDGEMENT}" \
    "ready=${OPENSTEAMER_SELF_TEST_CALL_READY_TOKEN}"
  terminate_production_app_for_call_phase
  print -r -- \
    "phase=3 event=production-app-terminated" \
    >> "${PHASE_EVENTS}"
  if wait_for_fresh_call_ready_acknowledgement; then
    exit 73
  fi
  grep -qx 'state=discarded-before-request' \
    "${CALL_READY_STALE_MARKER}" || exit 74
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "call-end-success" ]]; then
  OPENSTEAMER_SELF_TEST_CALL_END_TOKEN="self-test-call-end-token"
  CALL_END_TIMEOUT_SECONDS=3
  print -r -- "phase=3 event=connected-call-proof-observed" \
    >> "${PHASE_EVENTS}"
  (
    for end_poll in {1..200}; do
      [[ -s "${CALL_END_REQUEST}" ]] && break
      sleep 0.01
    done
    [[ -s "${CALL_END_REQUEST}" ]] || exit 75
    end_token=$(<"${CALL_END_REQUEST}")
    end_token=${end_token#end-call-token=}
    opensteamer_write_state \
      "${CALL_END_ACKNOWLEDGEMENT}" "ended=${end_token}"
  ) &
  call_end_writer_pid=$!
  wait_for_fresh_call_end_acknowledgement
  wait "${call_end_writer_pid}"
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "call-end-late-after-query" ]]; then
  OPENSTEAMER_SELF_TEST_CALL_END_TOKEN="self-test-call-end-token"
  OPENSTEAMER_SELF_TEST_ACK_QUERY_DELAY_SECONDS=1.2
  CALL_END_TIMEOUT_SECONDS=1
  print -r -- "phase=3 event=connected-call-proof-observed" \
    >> "${PHASE_EVENTS}"
  (
    for end_poll in {1..200}; do
      [[ -s "${CALL_END_REQUEST}" ]] && break
      sleep 0.01
    done
    [[ -s "${CALL_END_REQUEST}" ]] || exit 90
    end_token=$(<"${CALL_END_REQUEST}")
    end_token=${end_token#end-call-token=}
    opensteamer_write_state \
      "${CALL_END_ACKNOWLEDGEMENT}" "ended=${end_token}"
  ) &
  call_end_writer_pid=$!
  if wait_for_fresh_call_end_acknowledgement; then
    exit 91
  fi
  wait "${call_end_writer_pid}"
  /usr/bin/grep -Fxq 'state=timed-out' "${CALL_END_STATUS}" || exit 92
  ! /usr/bin/grep -Fq 'event=call-end-accepted' "${PHASE_EVENTS}" || exit 93
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "call-end-late-after-read" ]]; then
  OPENSTEAMER_SELF_TEST_CALL_END_TOKEN="self-test-call-end-token"
  OPENSTEAMER_SELF_TEST_ACK_POST_READ_DELAY_SECONDS=1.2
  CALL_END_TIMEOUT_SECONDS=1
  print -r -- "phase=3 event=connected-call-proof-observed" \
    >> "${PHASE_EVENTS}"
  (
    for end_poll in {1..200}; do
      [[ -s "${CALL_END_REQUEST}" ]] && break
      sleep 0.01
    done
    [[ -s "${CALL_END_REQUEST}" ]] || exit 155
    end_token=$(<"${CALL_END_REQUEST}")
    end_token=${end_token#end-call-token=}
    opensteamer_write_state \
      "${CALL_END_ACKNOWLEDGEMENT}" "ended=${end_token}"
  ) &
  call_end_writer_pid=$!
  if wait_for_fresh_call_end_acknowledgement; then
    exit 156
  fi
  wait "${call_end_writer_pid}"
  /usr/bin/grep -Fxq 'state=timed-out' "${CALL_END_STATUS}" || exit 157
  ! /usr/bin/grep -Fq 'event=call-end-accepted' "${PHASE_EVENTS}" || exit 158
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == call-acoustic-* ]]; then
  RAW_READY_NONCE="self-test-call-acoustic-nonce"
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "call-acoustic-success" ]]; then
  OPENSTEAMER_SELF_TEST_CALL_ACOUSTIC_TOKEN="self-test-call-acoustic-token"
  CALL_ACOUSTIC_TIMEOUT_SECONDS=3
  (
    for acoustic_poll in {1..200}; do
      [[ -s "${CALL_ACOUSTIC_REQUEST}" ]] && break
      sleep 0.01
    done
    [[ -s "${CALL_ACOUSTIC_REQUEST}" ]] || exit 85
    acoustic_token=$(<"${CALL_ACOUSTIC_REQUEST}")
    acoustic_token=${acoustic_token#heard-token=}
    opensteamer_write_state \
      "${CALL_ACOUSTIC_ACKNOWLEDGEMENT}" "heard=${acoustic_token}"
  ) &
  call_acoustic_writer_pid=$!
  wait_for_fresh_call_acoustic_acknowledgement
  wait "${call_acoustic_writer_pid}"
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "call-acoustic-late-after-query" ]]; then
  OPENSTEAMER_SELF_TEST_CALL_ACOUSTIC_TOKEN="self-test-call-acoustic-token"
  OPENSTEAMER_SELF_TEST_ACK_QUERY_DELAY_SECONDS=1.2
  CALL_ACOUSTIC_TIMEOUT_SECONDS=1
  (
    for acoustic_poll in {1..200}; do
      [[ -s "${CALL_ACOUSTIC_REQUEST}" ]] && break
      sleep 0.01
    done
    [[ -s "${CALL_ACOUSTIC_REQUEST}" ]] || exit 94
    acoustic_token=$(<"${CALL_ACOUSTIC_REQUEST}")
    acoustic_token=${acoustic_token#heard-token=}
    opensteamer_write_state \
      "${CALL_ACOUSTIC_ACKNOWLEDGEMENT}" "heard=${acoustic_token}"
  ) &
  call_acoustic_writer_pid=$!
  if wait_for_fresh_call_acoustic_acknowledgement; then
    exit 95
  fi
  wait "${call_acoustic_writer_pid}"
  /usr/bin/grep -Fxq 'state=timed-out' "${CALL_ACOUSTIC_STATUS}" || exit 96
  ! /usr/bin/grep -Fq 'event=call-acoustic-accepted' "${PHASE_EVENTS}" || exit 97
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "call-acoustic-late-after-read" ]]; then
  OPENSTEAMER_SELF_TEST_CALL_ACOUSTIC_TOKEN="self-test-call-acoustic-token"
  OPENSTEAMER_SELF_TEST_ACK_POST_READ_DELAY_SECONDS=1.2
  CALL_ACOUSTIC_TIMEOUT_SECONDS=1
  (
    for acoustic_poll in {1..200}; do
      [[ -s "${CALL_ACOUSTIC_REQUEST}" ]] && break
      sleep 0.01
    done
    [[ -s "${CALL_ACOUSTIC_REQUEST}" ]] || exit 159
    acoustic_token=$(<"${CALL_ACOUSTIC_REQUEST}")
    acoustic_token=${acoustic_token#heard-token=}
    opensteamer_write_state \
      "${CALL_ACOUSTIC_ACKNOWLEDGEMENT}" "heard=${acoustic_token}"
  ) &
  call_acoustic_writer_pid=$!
  if wait_for_fresh_call_acoustic_acknowledgement; then
    exit 160
  fi
  wait "${call_acoustic_writer_pid}"
  /usr/bin/grep -Fxq 'state=timed-out' "${CALL_ACOUSTIC_STATUS}" || exit 161
  ! /usr/bin/grep -Fq 'event=call-acoustic-accepted' "${PHASE_EVENTS}" || exit 162
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "call-acoustic-timeout" ]]; then
  OPENSTEAMER_SELF_TEST_CALL_ACOUSTIC_TOKEN="self-test-call-acoustic-token"
  CALL_ACOUSTIC_TIMEOUT_SECONDS=1
  if wait_for_fresh_call_acoustic_acknowledgement; then
    exit 86
  fi
  /usr/bin/grep -Fxq 'state=timed-out' "${CALL_ACOUSTIC_STATUS}" || exit 87
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "call-acoustic-stale" ]]; then
  OPENSTEAMER_SELF_TEST_CALL_ACOUSTIC_TOKEN="self-test-call-acoustic-token"
  CALL_ACOUSTIC_TIMEOUT_SECONDS=1
  opensteamer_write_state \
    "${CALL_ACOUSTIC_ACKNOWLEDGEMENT}" \
    "heard=${OPENSTEAMER_SELF_TEST_CALL_ACOUSTIC_TOKEN}"
  if wait_for_fresh_call_acoustic_acknowledgement; then
    exit 88
  fi
  /usr/bin/grep -Fxq 'state=discarded-before-request' \
    "${CALL_ACOUSTIC_STALE_MARKER}" || exit 89
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "call-end-timeout" ]]; then
  OPENSTEAMER_SELF_TEST_CALL_END_TOKEN="self-test-call-end-token"
  CALL_END_TIMEOUT_SECONDS=1
  print -r -- "phase=3 event=connected-call-proof-observed" \
    >> "${PHASE_EVENTS}"
  if wait_for_fresh_call_end_acknowledgement; then
    exit 76
  fi
  /usr/bin/grep -Fxq 'state=timed-out' "${CALL_END_STATUS}" || exit 77
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "call-end-stale" ]]; then
  OPENSTEAMER_SELF_TEST_CALL_END_TOKEN="self-test-call-end-token"
  CALL_END_TIMEOUT_SECONDS=1
  opensteamer_write_state \
    "${CALL_END_ACKNOWLEDGEMENT}" \
    "ended=${OPENSTEAMER_SELF_TEST_CALL_END_TOKEN}"
  print -r -- "phase=3 event=connected-call-proof-observed" \
    >> "${PHASE_EVENTS}"
  if wait_for_fresh_call_end_acknowledgement; then
    exit 78
  fi
  /usr/bin/grep -Fxq 'state=discarded-before-request' \
    "${CALL_END_STALE_MARKER}" || exit 79
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "call-stable-host-pass" ]]; then
  host_pid_file="${ARTIFACT_DIR}/call-stable-host-pid.txt"
  OPENSTEAMER_SELF_TEST_HOST_PID_FILE=${host_pid_file}
  print -r -- "4100" > "${host_pid_file}"
  require_stable_call_host 4100
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "call-stable-host-mismatch" ]]; then
  host_pid_file="${ARTIFACT_DIR}/call-stable-host-pid.txt"
  OPENSTEAMER_SELF_TEST_HOST_PID_FILE=${host_pid_file}
  print -r -- "4200" > "${host_pid_file}"
  if require_stable_call_host 4100; then
    exit 75
  fi
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "call-phase-quiescence-clean" ]]; then
  require_phase_three_quiescence
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == call-phase-quiescence-leak-* ]]; then
  leak_kind=${OPENSTEAMER_SCRIPT_SELF_TEST#call-phase-quiescence-leak-}
  if [[ "${leak_kind}" == "churn-lock" ]]; then
    mkdir "${HOST_CHURN_LOCK}"
  elif [[ "${leak_kind}" == "surviving-child" ]]; then
    opensteamer_exec_in_isolated_process_group \
      /bin/zsh -c '
"$1" self-test-ignore-signals "$2" &
sleep 0.2
exit 0
' surviving-child \
        "${OPENSTEAMER_PHYSICAL_VALIDATION_ORACLE}" \
        "${ARTIFACT_DIR}/call-phase-leak-child-pid.txt" &
    leak_pid=$!
    print -r -- "${leak_pid}" \
      > "${ARTIFACT_DIR}/call-phase-leak-pid.txt"
    opensteamer_require_isolated_process_group "${leak_pid}" 3
    opensteamer_wait_for_final_process_status "${leak_pid}" || true
    HOST_WATCHER_PID=${leak_pid}
    if require_phase_three_quiescence; then
      exit 77
    fi
    opensteamer_terminate_isolated_process_group \
      "${leak_pid}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
    if ! opensteamer_wait_for_process_group_exit "${leak_pid}" 2; then
      exit 78
    fi
    HOST_WATCHER_PID=""
    opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
    RUN_SUCCEEDED=1
    exit 0
  else
    opensteamer_exec_in_isolated_process_group \
      /bin/zsh -c 'trap "exit 0" TERM; while true; do sleep 30; done' &
    leak_pid=$!
    print -r -- "${leak_pid}" \
      > "${ARTIFACT_DIR}/call-phase-leak-pid.txt"
    opensteamer_require_isolated_process_group "${leak_pid}" 3
    case "${leak_kind}" in
      probe)
        BLACKHOLE_PROBE_PID=${leak_pid}
        ;;
      screen)
        SCREEN_ORACLE_PID=${leak_pid}
        ;;
      host-watcher)
        HOST_WATCHER_PID=${leak_pid}
        ;;
      reconnect-tone)
        AUDIO_ORACLE_TONE_PID=${leak_pid}
        ;;
      xcodebuild)
        XCODEBUILD_PID=${leak_pid}
        XCODEBUILD_GROUP_ISOLATED=1
        ;;
      *)
        exit 76
        ;;
    esac
  fi
  if require_phase_three_quiescence; then
    exit 77
  fi
  if [[ "${leak_kind}" == "churn-lock" ]]; then
    rmdir "${HOST_CHURN_LOCK}"
  else
    opensteamer_terminate_isolated_process_group \
      "${leak_pid}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
    opensteamer_wait_for_final_process_status "${leak_pid}" || true
    BLACKHOLE_PROBE_PID=""
    SCREEN_ORACLE_PID=""
    HOST_WATCHER_PID=""
    AUDIO_ORACLE_TONE_PID=""
    XCODEBUILD_PID=""
    XCODEBUILD_GROUP_ISOLATED=0
  fi
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi

# SwiftPM invokes this probe in a separate real zsh process. It protects against shell-runtime
# failures (such as assigning a read-only special parameter) that `zsh -n` cannot detect.
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "validate-physical-activities" ]]; then
  validate_required_physical_activities_json \
    "${OPENSTEAMER_SELF_TEST_ACTIVITIES_JSON:?missing activity fixture}"
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "audio-oracle-tone" ]]; then
  start_physical_audio_oracle_tone \
    "${AUDIO_ORACLE_TONE}" \
    "${AUDIO_ORACLE_TONE_LOG}" \
    "${AUDIO_ORACLE_DURATION_SECONDS}"
  /usr/bin/afinfo "${AUDIO_ORACLE_TONE}" >/dev/null
  kill -0 "${AUDIO_ORACLE_TONE_PID}"
  cleanup_audio_oracle_tone
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "screen-oracle-challenge" ]]; then
  start_physical_screen_oracle_challenge
  first_counter=$(physical_screen_oracle_counter)
  sleep 0.4
  second_counter=$(physical_screen_oracle_counter)
  (( second_counter > first_counter ))
  kill -0 "${SCREEN_ORACLE_PID}"
  challenge_pid=${SCREEN_ORACLE_PID}
  cleanup_screen_oracle_challenge
  ! kill -0 "${challenge_pid}" 2>/dev/null
  opensteamer_write_state \
    "${SCREEN_ORACLE_CLEANUP_PROOF}" \
    "state=terminated pid=${challenge_pid} first=${first_counter} last=${second_counter}"
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "write-host-status" ]]; then
  write_host_status pending 2 1 "runtime self-test"
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "cancel-stopped-churn" ]]; then
  churn_ready="${ARTIFACT_DIR}/cancel-churn-ready.txt"
  churn_proceed="${ARTIFACT_DIR}/cancel-churn-proceed.txt"
  churn_action="${ARTIFACT_DIR}/cancel-churn-action.txt"
  cancel_churn_original_stop_marker="${HOST_CHURN_STOP_MARKER}"
  cancel_churn_original_lock="${HOST_CHURN_LOCK}"
  non_group_watcher_script="${ARTIFACT_DIR}/cancel-non-group-watcher.zsh"
  cat > "${non_group_watcher_script}" <<'OPENSTEAMER_CANCEL_NON_GROUP_WATCHER'
#!/bin/zsh

term_marker=$1
ready_marker=$2
trap 'print -r -- "state=terminated" > "${term_marker}"; exit 0' TERM
print -r -- "state=ready" > "${ready_marker}"
while true; do /bin/sleep 30; done
OPENSTEAMER_CANCEL_NON_GROUP_WATCHER

  for watcher_scenario in live stale; do
    watcher_term_marker="${ARTIFACT_DIR}/cancel-${watcher_scenario}-watcher-term.txt"
    watcher_ready_marker="${ARTIFACT_DIR}/cancel-${watcher_scenario}-watcher-ready.txt"
    HOST_CHURN_STOP_MARKER="${ARTIFACT_DIR}/cancel-${watcher_scenario}-stop.txt"
    HOST_CHURN_LOCK="${ARTIFACT_DIR}/cancel-${watcher_scenario}-lock"
    rm -f \
      "${watcher_term_marker}" \
      "${watcher_ready_marker}" \
      "${HOST_CHURN_STOP_MARKER}"
    rmdir "${HOST_CHURN_LOCK}" 2>/dev/null || true
    if [[ "${watcher_scenario}" == "stale" ]]; then
      opensteamer_write_state "${HOST_CHURN_STOP_MARKER}" "state=stale"
    fi

    /bin/zsh "${non_group_watcher_script}" \
      "${watcher_term_marker}" "${watcher_ready_marker}" &
    HOST_WATCHER_PID=$!
    cancel_non_group_watcher_pid="${HOST_WATCHER_PID}"
    cancel_non_group_watcher_pgid=""
    for ((watcher_poll = 1; watcher_poll <= 100; watcher_poll++)); do
      cancel_non_group_watcher_pgid=$(
        /bin/ps -o pgid= -p "${cancel_non_group_watcher_pid}" 2>/dev/null \
          | /usr/bin/tr -d '[:space:]' || true
      )
      if [[ -f "${watcher_ready_marker}" ]] \
          && [[ -n "${cancel_non_group_watcher_pgid}" ]]; then
        break
      fi
      sleep 0.01
    done
    if [[ ! -f "${watcher_ready_marker}" ]] \
        || [[ -z "${cancel_non_group_watcher_pgid}" ]] \
        || [[ "${cancel_non_group_watcher_pgid}" == "${cancel_non_group_watcher_pid}" ]]; then
      /bin/kill -TERM "${cancel_non_group_watcher_pid}" 2>/dev/null || true
      wait "${cancel_non_group_watcher_pid}" 2>/dev/null || true
      HOST_WATCHER_PID=""
      exit 16
    fi

    stop_host_churn_before_xcodebuild_termination
    [[ -z "${HOST_WATCHER_PID}" ]] || exit 17
    if /bin/kill -0 "${cancel_non_group_watcher_pid}" 2>/dev/null; then
      exit 18
    fi
    [[ -f "${watcher_term_marker}" ]] || exit 19
    if [[ "${watcher_scenario}" == "stale" ]]; then
      [[ "$(/bin/cat "${HOST_CHURN_STOP_MARKER}")" == "state=stale" ]] || exit 20
    else
      [[ -f "${HOST_CHURN_STOP_MARKER}" ]] || exit 21
    fi
  done
  HOST_CHURN_STOP_MARKER="${cancel_churn_original_stop_marker}"
  HOST_CHURN_LOCK="${cancel_churn_original_lock}"

  churn_watcher_script="${ARTIFACT_DIR}/cancel-churn-watcher.zsh"
  cat > "${churn_watcher_script}" <<'OPENSTEAMER_CANCEL_CHURN_WATCHER'
#!/bin/zsh
set -eu

host_churn_lock=$1
validation_pid=$2
churn_ready=$3
churn_proceed=$4
churn_action=$5

trap 'rmdir "${host_churn_lock}" 2>/dev/null || true; exit 0' TERM INT HUP
trap 'rmdir "${host_churn_lock}" 2>/dev/null || true' EXIT
mkdir "${host_churn_lock}"
kill -STOP -- "-${validation_pid}"
print -r -- "state=stopped" > "${churn_ready}"
while [[ ! -f "${churn_proceed}" ]]; do
  sleep 0.02
done
print -r -- "action=ran" > "${churn_action}"
kill -CONT -- "-${validation_pid}" || true
OPENSTEAMER_CANCEL_CHURN_WATCHER

  opensteamer_start_isolated_validation_process /bin/zsh -c \
    'trap "exit 0" TERM; while true; do sleep 30; done'
  cancel_churn_validation_pid="${XCODEBUILD_PID}"

  opensteamer_exec_in_isolated_process_group \
    /bin/zsh \
    "${churn_watcher_script}" \
    "${HOST_CHURN_LOCK}" \
    "${cancel_churn_validation_pid}" \
    "${churn_ready}" \
    "${churn_proceed}" \
    "${churn_action}" &
  HOST_WATCHER_PID=$!

  churn_watcher_pgid=""
  for ((watcher_group_poll = 1; watcher_group_poll <= 250; watcher_group_poll++)); do
    churn_watcher_pgid=$(
      /bin/ps -o pgid= -p "${HOST_WATCHER_PID}" 2>/dev/null \
        | /usr/bin/tr -d '[:space:]' || true
    )
    if [[ "${churn_watcher_pgid}" == "${HOST_WATCHER_PID}" ]]; then
      break
    fi
    sleep 0.02
  done
  if [[ "${churn_watcher_pgid}" != "${HOST_WATCHER_PID}" ]]; then
    /bin/kill -TERM "${HOST_WATCHER_PID}" 2>/dev/null || true
    wait "${HOST_WATCHER_PID}" 2>/dev/null || true
    HOST_WATCHER_PID=""
    exit 8
  fi
  cancel_churn_watcher_pid="${HOST_WATCHER_PID}"

  for ready_poll in {1..250}; do
    [[ -f "${churn_ready}" ]] && break
    sleep 0.02
  done
  [[ -f "${churn_ready}" ]] || exit 9

  stop_host_churn_before_xcodebuild_termination
  [[ -z "${HOST_WATCHER_PID}" ]] || exit 10
  if opensteamer_process_group_exists "${cancel_churn_watcher_pid}"; then
    exit 11
  fi
  opensteamer_write_state "${churn_proceed}" "state=proceed"
  sleep 0.1
  [[ ! -f "${churn_action}" ]] || exit 12
  if ! opensteamer_process_group_exists "${cancel_churn_validation_pid}"; then
    exit 13
  fi
  opensteamer_terminate_isolated_process_group \
    "${cancel_churn_validation_pid}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
  opensteamer_wait_for_final_process_status "${cancel_churn_validation_pid}"
  XCODEBUILD_PID=""
  XCODEBUILD_GROUP_ISOLATED=0
  if opensteamer_process_group_exists "${cancel_churn_validation_pid}"; then
    exit 14
  fi
  [[ ! -f "${churn_action}" ]] || exit 15
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "fast-group-failure" ]]; then
  opensteamer_start_isolated_validation_process /bin/zsh -c '
    "$1" self-test-ignore-signals "$2" &
    exit 0
  ' fast-group \
    "${OPENSTEAMER_PHYSICAL_VALIDATION_ORACLE}" \
    "${ARTIFACT_DIR}/fast-group-child-pid.txt"
  opensteamer_wait_for_final_process_status "${XCODEBUILD_PID}" || true
  function fail_fast_group_self_test() { return 8 }
  fail_fast_group_self_test
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "fail-command" ]]; then
  function fail_for_runtime_self_test() { return 9 }
  fail_for_runtime_self_test
fi
if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "self-signal" ]]; then
  (sleep 0.1; kill -TERM $$) &
  SELF_SIGNAL_PID=$!
  sleep 0.3
  wait "${SELF_SIGNAL_PID}" 2>/dev/null || true
  opensteamer_write_state "${RUN_STATUS}" "status=passed"
  RUN_SUCCEEDED=1
  exit 0
fi

# Audit every completed connected record appended during the physical UI gate. The first three
# snapshots containing live connections trigger host replacement; later snapshots are audit-only
# until the parent proves the isolated xcodebuild group ended and requests the final locked audit.
function churn_host_after_live_connections() {
  local connections=0
  local restarts=0
  local previous_pid
  local replacement_pid
  local pid_poll
  local connection_wait_started
  local connection_wait_timeout=${UI_TEST_TIMEOUT_SECONDS}
  local expected_host_pid
  local new_connections
  local first_connection_number
  local -A observed_host_pids

  expected_host_pid=${EXPECTED_INITIAL_HOST_PID}
  if [[ -z "${expected_host_pid}" \
      || "$(current_host_pid)" != "${expected_host_pid}" ]]; then
    write_host_status failed 0 0 \
      "host PID changed between preflight and host-watcher startup"
    return 1
  fi
  observed_host_pids[${expected_host_pid}]=1
  connection_wait_started=${SECONDS}
  write_host_status pending 0 0 "waiting for the first live WebRTC connection"

  while true; do
    if [[ -f "${HOST_CHURN_STOP_MARKER}" ]]; then
      if ! acquire_host_churn_lock; then
        write_host_status failed "${connections}" "${restarts}" \
          "could not acquire the host churn lock for the final log audit"
        return 1
      fi
      if [[ ! -f "${HOST_CHURN_STOP_MARKER}" ]]; then
        release_host_churn_lock
        continue
      fi
      if ! grep -qx 'state=xcodebuild-ended' "${HOST_CHURN_STOP_MARKER}"; then
        release_host_churn_lock
        write_host_status failed "${connections}" "${restarts}" \
          "host log auditing was cancelled before xcodebuild ended"
        return 1
      fi
      if ! audit_new_host_log_records "${expected_host_pid}"; then
        release_host_churn_lock
        write_host_status failed "${connections}" "${restarts}" \
          "final host log snapshot or PID provenance was invalid"
        return 1
      fi
      if [[ -s "${HOST_LOG_PARTIAL_LINE}" ]]; then
        release_host_churn_lock
        write_host_status failed "${connections}" "${restarts}" \
          "final host log snapshot ended with an incomplete record"
        return 1
      fi
      new_connections=${OPENSTEAMER_NEW_HOST_CONNECTIONS}
      if (( new_connections > 0 )); then
        first_connection_number=$((connections + 1))
        record_audited_host_connections \
          "${first_connection_number}" "${OPENSTEAMER_CURRENT_HOST_PID}"
        connections=$((connections + new_connections))
      fi
      if (( restarts != 3 )); then
        release_host_churn_lock
        write_host_status failed "${connections}" "${restarts}" \
          "xcodebuild ended before three host replacements were verified"
        return 1
      fi
      if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" != host-provenance-* ]] \
          && ! verify_host_deployment_snapshot "${expected_host_pid}" "final"; then
        release_host_churn_lock
        write_host_status failed "${connections}" "${restarts}" \
          "final host PID ${expected_host_pid} did not match the freshly built signed app"
        return 1
      fi
      write_host_status passed "${connections}" "${restarts}" \
        "audited ${connections} live connections and verified three globally unique host replacements"
      release_host_churn_lock
      return 0
    fi

    if (( restarts < 3 \
        && SECONDS - connection_wait_started >= connection_wait_timeout )); then
      write_host_status failed "${connections}" "${restarts}" \
        "timed out waiting ${connection_wait_timeout}s for live connection $((connections + 1))"
      return 1
    fi
    if ! audit_new_host_log_records "${expected_host_pid}"; then
      write_host_status failed "${connections}" "${restarts}" \
        "host log snapshot or PID provenance became invalid"
      return 1
    fi
    new_connections=${OPENSTEAMER_NEW_HOST_CONNECTIONS}
    if (( new_connections > 0 )); then
      first_connection_number=$((connections + 1))
      record_audited_host_connections \
        "${first_connection_number}" "${OPENSTEAMER_CURRENT_HOST_PID}"
      connections=$((connections + new_connections))
    fi
    if (( restarts >= 3 || new_connections == 0 )); then
      sleep 0.2
      continue
    fi

    previous_pid=${OPENSTEAMER_CURRENT_HOST_PID}
    if [[ -n "${OPENSTEAMER_SELF_TEST_PRE_KICK_READY:-}" ]]; then
      opensteamer_write_state \
        "${OPENSTEAMER_SELF_TEST_PRE_KICK_READY}" "state=ready"
    fi
    wait_before_host_restart
    if ! audit_new_host_log_records "${expected_host_pid}"; then
      write_host_status failed "${connections}" "${restarts}" \
        "host log or PID provenance changed during the pre-kick delay"
      return 1
    fi
    new_connections=${OPENSTEAMER_NEW_HOST_CONNECTIONS}
    if (( new_connections > 0 )); then
      first_connection_number=$((connections + 1))
      record_audited_host_connections \
        "${first_connection_number}" "${OPENSTEAMER_CURRENT_HOST_PID}"
      connections=$((connections + new_connections))
    fi
    replacement_pid=$(current_host_pid)
    if ! opensteamer_require_same_host_process \
        "${expected_host_pid}" "${previous_pid}" "${replacement_pid}"; then
      write_host_status failed "${connections}" "${restarts}" \
        "connected host PID ${previous_pid} changed before the requested kickstart"
      return 1
    fi
    if ! kill -0 "${XCODEBUILD_PID}" 2>/dev/null; then
      write_host_status failed "${connections}" "${restarts}" \
        "xcodebuild ended before connected host PID ${previous_pid} could be kickstarted"
      return 1
    fi
    if ! acquire_host_churn_lock; then
      write_host_status failed "${connections}" "${restarts}" \
        "could not acquire the host churn coordination lock"
      return 1
    fi
    replacement_pid=$(current_host_pid)
    if [[ -f "${HOST_CHURN_STOP_MARKER}" ]] \
        || ! opensteamer_require_same_host_process \
          "${expected_host_pid}" "${previous_pid}" "${replacement_pid}" \
        || ! kill -0 "${XCODEBUILD_PID}" 2>/dev/null; then
      release_host_churn_lock
      write_host_status failed "${connections}" "${restarts}" \
        "host churn stopped before connected PID ${previous_pid} could be kickstarted"
      return 1
    fi

    # Freeze the isolated validation group before the final liveness check. A stopped leader cannot
    # exit between this check and kickstart, which makes the host restart provably precede the end
    # of xcodebuild instead of relying on a narrow kill(0)/launchctl timing window.
    if ! opensteamer_suspend_isolated_process_group "${XCODEBUILD_PID}" 3; then
      release_host_churn_lock
      write_host_status failed "${connections}" "${restarts}" \
        "could not suspend the live xcodebuild process group before host churn"
      return 1
    fi
    replacement_pid=$(current_host_pid)
    if [[ -f "${HOST_CHURN_STOP_MARKER}" ]] \
        || ! opensteamer_require_same_host_process \
          "${expected_host_pid}" "${previous_pid}" "${replacement_pid}" \
        || ! audit_new_host_log_records "${expected_host_pid}" \
        || ! capture_host_generation_log_checkpoint; then
      opensteamer_resume_process_group "${XCODEBUILD_PID}" || true
      release_host_churn_lock
      write_host_status failed "${connections}" "${restarts}" \
        "host, log provenance, or the generation checkpoint changed before connected PID ${previous_pid} could be kickstarted"
      return 1
    fi
    new_connections=${OPENSTEAMER_NEW_HOST_CONNECTIONS}
    if (( new_connections > 0 )); then
      first_connection_number=$((connections + 1))
      record_audited_host_connections \
        "${first_connection_number}" "${OPENSTEAMER_CURRENT_HOST_PID}"
      connections=$((connections + new_connections))
    fi

    # The parent publishes its stop marker under this same lock only after the isolated validation
    # group ends. The final snapshot, PID proof, and kickstart are one stopped critical section.
    if ! kickstart_host_service; then
      opensteamer_resume_process_group "${XCODEBUILD_PID}" || true
      release_host_churn_lock
      write_host_status failed "${connections}" "${restarts}" \
        "launchctl kickstart failed after connection ${connections}"
      return 1
    fi
    if ! opensteamer_resume_process_group "${XCODEBUILD_PID}"; then
      release_host_churn_lock
      write_host_status failed "${connections}" "${restarts}" \
        "xcodebuild process group could not resume after host restart ${connections}"
      return 1
    fi
    release_host_churn_lock

    replacement_pid=""
    for pid_poll in {1..100}; do
      replacement_pid=$(current_host_pid)
      if [[ -n "${replacement_pid}" && "${replacement_pid}" != "${previous_pid}" ]]; then
        if [[ "${replacement_pid}" == *[^0-9]* ]] \
            || (( replacement_pid <= 0 )); then
          write_host_status failed "${connections}" "${restarts}" \
            "launchd reported a malformed replacement host PID"
          return 1
        fi
        if [[ -n "${observed_host_pids[${replacement_pid}]-}" ]]; then
          write_host_status failed "${connections}" "${restarts}" \
            "launchd reused previously observed host PID ${replacement_pid}"
          return 1
        fi
        break
      fi
      sleep 0.1
    done
    if [[ -z "${replacement_pid}" \
        || "${replacement_pid}" == *[^0-9]* \
        || "${replacement_pid}" == "${previous_pid}" ]]; then
      write_host_status failed "${connections}" "${restarts}" \
        "launchd did not report a replacement host PID after connection ${connections}"
      return 1
    fi

    if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" != host-provenance-* ]] \
        && { ! bind_host_generation_snapshot "${replacement_pid}" \
          || ! verify_host_deployment_snapshot \
            "${replacement_pid}" "restart-$((restarts + 1))"; }; then
      write_host_status failed "${connections}" "${restarts}" \
        "replacement host PID ${replacement_pid} did not publish one generation-bound freshly built deployment"
      return 1
    fi

    restarts=$((restarts + 1))
    expected_host_pid=${replacement_pid}
    observed_host_pids[${replacement_pid}]=1
    print -r -- \
      "restart=${restarts} completed_at=$(date -u +%FT%TZ) old_pid=${previous_pid} new_pid=${replacement_pid}" \
      >> "${HOST_EVENTS}"
    if (( restarts == 3 )); then
      write_host_status pending "${connections}" "${restarts}" \
        "three restarts complete; auditing all remaining connections until xcodebuild ends"
      if [[ -n "${OPENSTEAMER_SELF_TEST_AUDIT_ONLY_READY:-}" \
          && -n "${OPENSTEAMER_SELF_TEST_AUDIT_ONLY_PROCEED:-}" ]]; then
        opensteamer_write_state \
          "${OPENSTEAMER_SELF_TEST_AUDIT_ONLY_READY}" "state=ready"
        while [[ ! -f "${OPENSTEAMER_SELF_TEST_AUDIT_ONLY_PROCEED}" ]]; do
          sleep 0.01
        done
      fi
    else
      write_host_status pending "${connections}" "${restarts}" \
        "waiting for another live connection"
    fi
    connection_wait_started=${SECONDS}
    connection_wait_timeout=${HOST_CONNECTION_WAIT_TIMEOUT_SECONDS}
  done
}

if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "migration-controller-lock-probe-build" ]]; then
  initialize_migration_controller_lock_probe
  validate_migration_controller_binary
  opensteamer_write_state \
    "${ARTIFACT_DIR}/migration-controller-lock-probe-status.txt" \
    "status=validated sha256=${MIGRATION_CONTROLLER_BINARY_SHA256}"
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi

if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == host-deployment-contract-* ]]; then
  deployment_contract_mode=${OPENSTEAMER_SCRIPT_SELF_TEST#host-deployment-contract-}
  prepare_host_deployment_contract_self_test "${deployment_contract_mode}"
  if [[ "${deployment_contract_mode}" == success ]]; then
    verify_host_deployment_snapshot 4242 self-test-contract || exit 80
    /usr/bin/grep -Fxq 'verifier-invoked=true' \
      "${HOST_DEPLOYMENT_MANIFEST}" || exit 81
  elif [[ "${deployment_contract_mode}" == missing ]]; then
    if verify_host_deployment_snapshot 4242 self-test-contract-missing; then
      exit 82
    fi
    if /usr/bin/grep -Fq 'verifier-invoked=true' \
        "${HOST_DEPLOYMENT_MANIFEST}" 2>/dev/null; then
      exit 83
    fi
  else
    exit 84
  fi
  opensteamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi

if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == host-provenance-* ]]; then
  run_host_provenance_self_test
  exit 0
fi

if [[ -n "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" ]]; then
  echo \
    "Unknown OPENSTEAMER_SCRIPT_SELF_TEST mode '${OPENSTEAMER_SCRIPT_SELF_TEST}'." \
    >&2
  exit 2
fi

if [[ -z "${OPENSTEAMER_EXPECTED_TEAM_ID:-}" ]]; then
  echo "OPENSTEAMER_EXPECTED_TEAM_ID is required for a physical release run." >&2
  exit 2
fi
EXPECTED_MAC_HOST_TEAM_ID=${OPENSTEAMER_EXPECTED_TEAM_ID}

capture_and_validate_device "${DEVICE_BEFORE}"
capture_and_require_unlocked "${LOCK_STATE_BEFORE}"
capture_production_candidate "${APP_LIST_BEFORE}" "${CANDIDATE_BEFORE}"

# Rebuild from this checkout, then bind the physical evidence to that exact signed artifact and
# live launchd process. A loaded label and PID are insufficient: a legacy app or naked executable
# can connect while macOS privacy permissions belong to a different code identity.
if ! TMPDIR="${XCODE_TEMP_DIR}" "${MAC_HOST_BUILD_SCRIPT}" \
    > "${HOST_BUILD_STDOUT}" 2> "${HOST_BUILD_STDERR}"; then
  echo "Refusing device reconnect validation: the signed Mac host build failed." >&2
  cat "${HOST_BUILD_STDERR}" >&2
  exit 3
fi
if [[ "$(tail -n 1 "${HOST_BUILD_STDOUT}")" \
    != "${HOST_FRESH_STAGED_APP}" ]]; then
  echo "Refusing device reconnect validation: the Mac host build returned an unexpected artifact." >&2
  exit 3
fi
initialize_migration_controller_lock_probe || {
  echo "Refusing device reconnect validation: the reviewed Rust lock probe could not be built." >&2
  exit 3
}
HOST_PREINITIAL_PID=$(current_host_pid)
if [[ -z "${HOST_PREINITIAL_PID}" \
    || "${HOST_PREINITIAL_PID}" == *[^0-9]* ]]; then
  echo "Refusing device reconnect validation: launch agent ${HOST_SERVICE} has no valid running host PID." >&2
  exit 3
fi
# Prove the exact currently loaded opensteamer executable/plists/log/generation against the freshly
# built reviewed postimage before the first mutating launchctl command. If the installed host is
# stale or any protected/arbitrary label was selected, validation stops without a kickstart.
if ! capture_host_generation_log_checkpoint \
    || ! bind_host_generation_snapshot "${HOST_PREINITIAL_PID}" \
    || ! verify_host_deployment_snapshot \
      "${HOST_PREINITIAL_PID}" "pre-initial-kickstart" \
    || ! capture_host_generation_log_checkpoint \
    || ! kickstart_host_service; then
  echo "Refusing device reconnect validation: a fresh generation-bound host checkpoint could not be armed." >&2
  exit 3
fi
EXPECTED_INITIAL_HOST_PID=$(wait_for_replacement_host_pid "${HOST_PREINITIAL_PID}") || {
  echo "Refusing device reconnect validation: launchd did not publish a fresh initial host generation." >&2
  exit 3
}
if ! bind_host_generation_snapshot "${EXPECTED_INITIAL_HOST_PID}" \
    || ! verify_host_deployment_snapshot \
      "${EXPECTED_INITIAL_HOST_PID}" "initial"; then
  echo "Refusing device reconnect validation: the installed/live Mac host does not match the freshly built signed app." >&2
  cat "${HOST_DEPLOYMENT_STDERR}" >&2
  exit 3
fi

if [[ ! -f "${HOST_LOG}" ]]; then
  echo "Refusing device reconnect validation: host log does not exist at ${HOST_LOG}." >&2
  exit 3
fi
if ! launchctl print "${HOST_SERVICE}" \
  > "${ARTIFACT_DIR}/host-launch-agent-before.txt" 2>&1; then
  echo "Refusing device reconnect validation: launch agent ${HOST_SERVICE} is not loaded." >&2
  exit 3
fi
if [[ "$(current_host_pid)" != "${EXPECTED_INITIAL_HOST_PID}" ]]; then
  echo "Refusing device reconnect validation: the host PID changed after deployment verification." >&2
  exit 3
fi

run_phase_capturing_status run_raw_microphone_blackhole_phase
RAW_PHASE_RESULT=${OPENSTEAMER_CAPTURED_PHASE_STATUS}
if (( RAW_PHASE_RESULT != 0 )); then
  exit "${RAW_PHASE_RESULT}"
fi

run_command_capturing_status \
  begin_phase 2 reconnect-background-screen "${RECONNECT_PHASE_STATUS}"
RECONNECT_PHASE_RESULT=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
if (( RECONNECT_PHASE_RESULT != 0 )); then
  exit "${RECONNECT_PHASE_RESULT}"
fi

# The build and app-list checks can take long enough for the device to relock after preflight.
run_command_capturing_status \
  capture_and_require_unlocked "${LOCK_STATE_BEFORE_XCODEBUILD}"
RECONNECT_PHASE_RESULT=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
if (( RECONNECT_PHASE_RESULT != 0 )); then
  fail_phase "${RECONNECT_PHASE_STATUS}" || true
  exit "${RECONNECT_PHASE_RESULT}"
fi
HOST_LOG_START_OFFSET=0
HOST_LOG_START_DIGEST=$(opensteamer_empty_sha256)
run_command_capturing_status \
  opensteamer_capture_log_snapshot \
  "${HOST_LOG}" \
  "" \
  "${HOST_LOG_START_OFFSET}" \
  "${HOST_LOG_START_DIGEST}" \
  "${HOST_LOG_APPEND_CHUNK}"
RECONNECT_PHASE_RESULT=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
if (( RECONNECT_PHASE_RESULT != 0 )); then
  echo "Refusing device reconnect validation: host log identity could not be captured." >&2
  fail_phase "${RECONNECT_PHASE_STATUS}" || true
  exit "${RECONNECT_PHASE_RESULT}"
fi
HOST_LOG_START_ID=${OPENSTEAMER_LOG_SNAPSHOT_ID}
HOST_LOG_START_OFFSET=${OPENSTEAMER_LOG_SNAPSHOT_OFFSET}
HOST_LOG_START_DIGEST=${OPENSTEAMER_LOG_SNAPSHOT_DIGEST}
if [[ "${OPENSTEAMER_LOG_SNAPSHOT_ENDS_WITH_NEWLINE}" != "1" ]]; then
  echo "Refusing device reconnect validation: host log does not end at a complete record boundary." >&2
  exit 3
fi
rm -f "${HOST_LOG_APPEND_CHUNK}"
print -rn -- "" > "${HOST_LOG_PARTIAL_LINE}"

run_command_capturing_status \
  start_physical_audio_oracle_tone \
  "${AUDIO_ORACLE_TONE}" \
  "${AUDIO_ORACLE_TONE_LOG}" \
  "${AUDIO_ORACLE_DURATION_SECONDS}"
RECONNECT_PHASE_RESULT=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
if (( RECONNECT_PHASE_RESULT != 0 )); then
  fail_phase "${RECONNECT_PHASE_STATUS}" || true
  exit "${RECONNECT_PHASE_RESULT}"
fi
run_command_capturing_status start_physical_screen_oracle_challenge
RECONNECT_PHASE_RESULT=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
if (( RECONNECT_PHASE_RESULT != 0 )); then
  cleanup_audio_oracle_tone || true
  fail_phase "${RECONNECT_PHASE_STATUS}" || true
  exit "${RECONNECT_PHASE_RESULT}"
fi
SCREEN_ORACLE_LAST_COUNTER=$(physical_screen_oracle_counter)

run_command_capturing_status \
  opensteamer_start_isolated_validation_process \
  /usr/bin/env TMPDIR="${XCODE_TEMP_DIR}" \
  xcodebuild test \
  -project "${PROJECT_DIR}/opensteamer.xcodeproj" \
  -scheme opensteamerUITests \
  -configuration Debug \
  -destination "platform=iOS,id=${HARDWARE_UDID}" \
  -derivedDataPath "${DERIVED_DATA}" \
  -clonedSourcePackagesDirPath "${XCODE_SOURCE_PACKAGES}" \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 600 \
  -maximum-test-execution-time-allowance 720 \
  -only-testing:opensteamerUITests/PairedReconnectPhysicalUITests/testThreeSameProcessHostRestartsThenColdRelaunchPreservePairing \
  -resultBundlePath "${RESULT_BUNDLE}"
RECONNECT_PHASE_RESULT=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
if (( RECONNECT_PHASE_RESULT != 0 )); then
  cleanup_audio_oracle_tone || true
  cleanup_screen_oracle_challenge || true
  fail_phase "${RECONNECT_PHASE_STATUS}" || true
  exit "${RECONNECT_PHASE_RESULT}"
fi
XCODEBUILD_GROUP_HANDLE=${XCODEBUILD_PID}
run_command_capturing_status start_host_churn_worker
RECONNECT_PHASE_RESULT=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
if (( RECONNECT_PHASE_RESULT != 0 )); then
  fail_phase "${RECONNECT_PHASE_STATUS}" || true
  exit "${RECONNECT_PHASE_RESULT}"
fi
(
  set -e
  opensteamer_write_state "${WATCHDOG_STATE}" "state=monitoring"
  watchdog_started=${SECONDS}
  lock_poll_started=${SECONDS}
  lock_query_failures=0
  screen_oracle_stale_polls=0
  while kill -0 "${XCODEBUILD_PID}" 2>/dev/null; do
    if [[ -z "${AUDIO_ORACLE_TONE_PID}" ]] \
        || ! opensteamer_process_group_exists "${AUDIO_ORACLE_TONE_PID}"; then
      print -r -- \
        "The deterministic Mac audio oracle tone stopped during physical validation." \
        > "${AUDIO_ORACLE_TONE_FAILURE_MARKER}"
      stop_host_churn_before_xcodebuild_termination || true
      opensteamer_terminate_isolated_process_group \
        "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
      opensteamer_write_state "${WATCHDOG_STATE}" "state=audio-oracle-failure-handled"
      exit 0
    fi
    current_screen_oracle_counter=$(physical_screen_oracle_counter || true)
    if [[ -z "${SCREEN_ORACLE_PID}" ]] \
        || ! opensteamer_process_group_exists "${SCREEN_ORACLE_PID}" \
        || [[ -z "${current_screen_oracle_counter}" ]] \
        || (( current_screen_oracle_counter <= SCREEN_ORACLE_LAST_COUNTER )); then
      screen_oracle_stale_polls=$((screen_oracle_stale_polls + 1))
    else
      SCREEN_ORACLE_LAST_COUNTER=${current_screen_oracle_counter}
      screen_oracle_stale_polls=0
    fi
    if (( screen_oracle_stale_polls >= 2 )); then
      print -r -- \
        "The deterministic decoded-screen pixel challenge stopped advancing during physical validation." \
        > "${SCREEN_ORACLE_FAILURE_MARKER}"
      stop_host_churn_before_xcodebuild_termination || true
      opensteamer_terminate_isolated_process_group \
        "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
      opensteamer_write_state "${WATCHDOG_STATE}" "state=screen-oracle-failure-handled"
      exit 0
    fi
    if (( SECONDS - watchdog_started >= UI_TEST_TIMEOUT_SECONDS )); then
      print -r -- \
        "Timed out after ${UI_TEST_TIMEOUT_SECONDS}s while running the physical device UI gate." \
        > "${UI_TEST_TIMEOUT_MARKER}"
      stop_host_churn_before_xcodebuild_termination || true
      opensteamer_terminate_isolated_process_group \
        "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
      opensteamer_write_state "${WATCHDOG_STATE}" "state=timeout-handled"
      exit 0
    fi
    if ! kill -0 "${HOST_WATCHER_PID}" 2>/dev/null \
        && ! grep -qx 'status=passed' "${HOST_STATUS}" 2>/dev/null; then
      print -r -- \
        "The host restart watcher failed before completing its three verified restarts." \
        > "${HOST_WATCHER_FAILURE_MARKER}"
      stop_host_churn_before_xcodebuild_termination || true
      opensteamer_terminate_isolated_process_group \
        "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
      opensteamer_write_state "${WATCHDOG_STATE}" "state=host-watcher-failure-handled"
      exit 0
    fi
    if (( SECONDS - lock_poll_started >= DEVICE_LOCK_POLL_SECONDS )); then
      lock_poll_started=${SECONDS}
      if opensteamer_device_is_unlocked \
          "${COREDEVICE_IDENTIFIER}" \
          "${DEVICE_COMMAND_TIMEOUT_SECONDS}" \
          "${LOCK_STATE_DURING_TEST}"; then
        lock_query_failures=0
      else
        lock_result=$?
        if (( lock_result == 5 )); then
          print -r -- \
            "The iPhone locked while the physical device UI gate was running." \
            > "${DEVICE_LOCKED_MARKER}"
          stop_host_churn_before_xcodebuild_termination || true
          opensteamer_terminate_isolated_process_group \
            "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
          opensteamer_write_state "${WATCHDOG_STATE}" "state=device-locked-handled"
          exit 0
        fi
        lock_query_failures=$((lock_query_failures + 1))
        if (( lock_query_failures >= 2 )); then
          print -r -- \
            "The iPhone lock state could not be verified twice during the physical device UI gate." \
            > "${DEVICE_UNAVAILABLE_MARKER}"
          stop_host_churn_before_xcodebuild_termination || true
          opensteamer_terminate_isolated_process_group \
            "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
          opensteamer_write_state "${WATCHDOG_STATE}" "state=device-unavailable-handled"
          exit 0
        fi
      fi
    fi
    sleep 1
  done
  opensteamer_write_state "${WATCHDOG_STATE}" "state=xcodebuild-ended"
) &
XCODEBUILD_WATCHDOG_PID=$!
opensteamer_wait_for_final_process_status "${XCODEBUILD_PID}"
XCODEBUILD_STATUS=${OPENSTEAMER_FINAL_PROCESS_STATUS}
if ! opensteamer_wait_for_process_group_exit "${XCODEBUILD_PID}" 2; then
  print -r -- \
    "The device xcodebuild process group remained alive after its leader exited." \
    > "${WATCHDOG_FAILURE_MARKER}"
  opensteamer_terminate_isolated_process_group \
    "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
  if ! opensteamer_wait_for_process_group_exit "${XCODEBUILD_PID}" 2; then
    echo "The device xcodebuild process group survived forced termination." >&2
    exit 7
  fi
fi
if opensteamer_process_group_exists "${XCODEBUILD_PID}"; then
  XCODEBUILD_GROUP_HANDLE=${XCODEBUILD_PID}
else
  XCODEBUILD_GROUP_HANDLE=""
fi
if ! request_final_host_log_audit; then
  print -r -- \
    "The parent could not publish the host-churn stop marker after xcodebuild ended." \
    > "${WATCHDOG_FAILURE_MARKER}"
fi
XCODEBUILD_PID=""
XCODEBUILD_GROUP_ISOLATED=0
if ! opensteamer_wait_for_process_exit \
    "${XCODEBUILD_WATCHDOG_PID}" "$((DEVICE_COMMAND_TIMEOUT_SECONDS + 5))"; then
  print -r -- \
    "The device lock watchdog did not finish after xcodebuild ended." \
    > "${WATCHDOG_FAILURE_MARKER}"
  opensteamer_terminate_process_tree \
    "${XCODEBUILD_WATCHDOG_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
fi
if wait "${XCODEBUILD_WATCHDOG_PID}" 2>/dev/null; then
  XCODEBUILD_WATCHDOG_STATUS=0
else
  XCODEBUILD_WATCHDOG_STATUS=$?
fi
XCODEBUILD_WATCHDOG_PID=""

for watcher_poll in {1..100}; do
  if ! kill -0 "${HOST_WATCHER_PID}" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if kill -0 "${HOST_WATCHER_PID}" 2>/dev/null; then
  echo "Host log auditor did not finish its final locked snapshot." >&2
  exit 4
fi
if opensteamer_process_group_exists "${HOST_WATCHER_PID}"; then
  echo "Host log auditor left a surviving owned process group." >&2
  exit 4
fi
if wait "${HOST_WATCHER_PID}"; then
  HOST_WATCHER_RESULT=0
else
  HOST_WATCHER_RESULT=$?
fi
HOST_WATCHER_PID=""

if [[ -f "${WATCHDOG_FAILURE_MARKER}" ]]; then
  cat "${WATCHDOG_FAILURE_MARKER}" >&2
  exit 7
fi
if (( XCODEBUILD_WATCHDOG_STATUS != 0 )); then
  echo "device lock watchdog failed with status ${XCODEBUILD_WATCHDOG_STATUS}." >&2
  exit 7
fi
EXPECTED_WATCHDOG_STATE="state=xcodebuild-ended"
if [[ -f "${UI_TEST_TIMEOUT_MARKER}" ]]; then
  EXPECTED_WATCHDOG_STATE="state=timeout-handled"
elif [[ -f "${DEVICE_LOCKED_MARKER}" ]]; then
  EXPECTED_WATCHDOG_STATE="state=device-locked-handled"
elif [[ -f "${DEVICE_UNAVAILABLE_MARKER}" ]]; then
  EXPECTED_WATCHDOG_STATE="state=device-unavailable-handled"
elif [[ -f "${HOST_WATCHER_FAILURE_MARKER}" ]]; then
  EXPECTED_WATCHDOG_STATE="state=host-watcher-failure-handled"
elif [[ -f "${AUDIO_ORACLE_TONE_FAILURE_MARKER}" ]]; then
  EXPECTED_WATCHDOG_STATE="state=audio-oracle-failure-handled"
elif [[ -f "${SCREEN_ORACLE_FAILURE_MARKER}" ]]; then
  EXPECTED_WATCHDOG_STATE="state=screen-oracle-failure-handled"
fi
if ! grep -qx "${EXPECTED_WATCHDOG_STATE}" "${WATCHDOG_STATE}" 2>/dev/null; then
  echo "device lock watchdog lifecycle evidence is incomplete; expected ${EXPECTED_WATCHDOG_STATE}." >&2
  exit 7
fi
if [[ -f "${UI_TEST_TIMEOUT_MARKER}" ]]; then
  cat "${UI_TEST_TIMEOUT_MARKER}" >&2
  XCODEBUILD_STATUS=124
elif [[ -f "${DEVICE_LOCKED_MARKER}" ]]; then
  cat "${DEVICE_LOCKED_MARKER}" >&2
  exit 5
elif [[ -f "${DEVICE_UNAVAILABLE_MARKER}" ]]; then
  cat "${DEVICE_UNAVAILABLE_MARKER}" >&2
  exit 6
elif [[ -f "${HOST_WATCHER_FAILURE_MARKER}" ]]; then
  cat "${HOST_WATCHER_FAILURE_MARKER}" >&2
  exit 4
elif [[ -f "${AUDIO_ORACLE_TONE_FAILURE_MARKER}" ]]; then
  cat "${AUDIO_ORACLE_TONE_FAILURE_MARKER}" >&2
  exit 7
elif [[ -f "${SCREEN_ORACLE_FAILURE_MARKER}" ]]; then
  cat "${SCREEN_ORACLE_FAILURE_MARKER}" >&2
  exit 7
fi
if (( XCODEBUILD_STATUS == 0 )); then
  run_command_capturing_status \
    capture_and_require_unlocked "${LOCK_STATE_AFTER_XCODEBUILD}"
  RECONNECT_PHASE_RESULT=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
  if (( RECONNECT_PHASE_RESULT != 0 )); then
    fail_phase "${RECONNECT_PHASE_STATUS}" || true
    exit "${RECONNECT_PHASE_RESULT}"
  fi
fi

# Capture the exact production candidate again even when XCTest fails. An install, replacement,
# or update during the gate invalidates both positive and negative test evidence.
run_command_capturing_status \
  capture_and_require_unchanged_candidate \
  "${RECONNECT_DEVICE_AFTER}" \
  "${RECONNECT_APP_LIST_AFTER}" \
  "${RECONNECT_CANDIDATE_AFTER}" \
  "reconnect/background/screen validation"
RECONNECT_PHASE_RESULT=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
if (( RECONNECT_PHASE_RESULT != 0 )); then
  fail_phase "${RECONNECT_PHASE_STATUS}" || true
  exit "${RECONNECT_PHASE_RESULT}"
fi
if (( XCODEBUILD_STATUS != 0 )); then
  echo "Physical UI test failed with xcodebuild status ${XCODEBUILD_STATUS}." >&2
  exit "${XCODEBUILD_STATUS}"
fi
if [[ -z "${AUDIO_ORACLE_TONE_PID}" ]] \
    || ! opensteamer_process_group_exists "${AUDIO_ORACLE_TONE_PID}"; then
  echo "The deterministic Mac audio oracle tone was not alive at final audit." >&2
  exit 7
fi
if [[ -z "${SCREEN_ORACLE_PID}" ]] \
    || ! opensteamer_process_group_exists "${SCREEN_ORACLE_PID}" \
    || [[ ! -s "${SCREEN_ORACLE_HEARTBEAT}" ]]; then
  echo "The deterministic decoded-screen pixel challenge was not alive at final audit." >&2
  exit 7
fi

# The UI test cannot pass its three same-process recovery waits unless churn occurred, but this
# independent artifact check prevents an unrelated network transition from becoming false proof.
if (( HOST_WATCHER_RESULT != 0 )); then
  echo "Host churn/log auditor failed; see ${HOST_STATUS} and ${HOST_EVENTS}." >&2
  exit 4
fi
HOST_AUDITED_CONNECTIONS=$(awk -F= '$1 == "connections" { print $2; exit }' \
  "${HOST_STATUS}" 2>/dev/null || true)
if ! grep -qx 'status=passed' "${HOST_STATUS}" \
  || ! grep -qx 'restarts=3' "${HOST_STATUS}" \
  || [[ -z "${HOST_AUDITED_CONNECTIONS}" \
      || "${HOST_AUDITED_CONNECTIONS}" == *[^0-9]* ]] \
  || (( HOST_AUDITED_CONNECTIONS < 3 )); then
  echo "Host churn evidence is incomplete; see ${HOST_STATUS} and ${HOST_EVENTS}." >&2
  exit 4
fi

run_command_capturing_status \
  validate_ui_xcresult \
  "${RECONNECT_RESULT_BUNDLE}" \
  "${RECONNECT_SUMMARY_JSON}" \
  "${RECONNECT_TESTS_JSON}" \
  "${RECONNECT_BUILD_RESULTS_JSON}" \
  "${RECONNECT_ACTIVITIES_JSON}" \
  "${EXPECTED_TEST_NODE}" \
  "${EXPECTED_TEST_URL}" \
  validate_required_physical_activities_json
RECONNECT_PHASE_RESULT=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
if (( RECONNECT_PHASE_RESULT != 0 )); then
  fail_phase "${RECONNECT_PHASE_STATUS}" || true
  exit "${RECONNECT_PHASE_RESULT}"
fi

run_command_capturing_status cleanup_audio_oracle_tone
RECONNECT_PHASE_RESULT=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
if (( RECONNECT_PHASE_RESULT == 0 )); then
  run_command_capturing_status cleanup_screen_oracle_challenge
  RECONNECT_PHASE_RESULT=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
fi
if (( RECONNECT_PHASE_RESULT != 0 )); then
  fail_phase "${RECONNECT_PHASE_STATUS}" || true
  exit 7
fi
opensteamer_write_state \
  "${RECONNECT_MEDIA_CLEANUP_PROOF}" \
  "state=terminated"
run_command_capturing_status require_phase_three_quiescence
RECONNECT_PHASE_RESULT=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
if (( RECONNECT_PHASE_RESULT != 0 )); then
  fail_phase "${RECONNECT_PHASE_STATUS}" || true
  exit "${RECONNECT_PHASE_RESULT}"
fi
run_command_capturing_status \
  complete_phase 2 reconnect-background-screen "${RECONNECT_PHASE_STATUS}"
RECONNECT_PHASE_RESULT=${OPENSTEAMER_CAPTURED_COMMAND_STATUS}
if (( RECONNECT_PHASE_RESULT != 0 )); then
  fail_phase "${RECONNECT_PHASE_STATUS}" || true
  exit "${RECONNECT_PHASE_RESULT}"
fi

run_phase_capturing_status run_real_connected_call_phase
CALL_PHASE_RESULT=${OPENSTEAMER_CAPTURED_PHASE_STATUS}
if (( CALL_PHASE_RESULT != 0 )); then
  exit "${CALL_PHASE_RESULT}"
fi

capture_and_validate_device "${DEVICE_AFTER}"
capture_production_candidate "${APP_LIST_AFTER}" "${CANDIDATE_AFTER}"
if ! cmp -s "${CANDIDATE_BEFORE}" "${CANDIDATE_AFTER}"; then
  echo "Production candidate changed during the complete three-phase device validation." >&2
  diff -u "${CANDIDATE_BEFORE}" "${CANDIDATE_AFTER}" >&2 || true
  exit 2
fi
if ! require_stable_call_host "${CALL_STABLE_HOST_PID}"; then
  echo "The final signed host PID changed after real-call validation." >&2
  exit 4
fi
if ! reject_runtime_uid_in_retained_artifacts; then
  echo "A retained validation artifact contained the runtime physical-output UID." >&2
  exit 1
fi
if ! grep -qx 'status=passed' "${RAW_PHASE_STATUS}" \
    || ! grep -qx 'status=passed' "${RECONNECT_PHASE_STATUS}" \
    || ! grep -qx 'status=passed' "${CALL_PHASE_STATUS}"; then
  echo "One or more physical validation phases did not publish passing evidence." >&2
  exit 1
fi

echo "Production-bundle raw iPhone microphone and BlackHole gate passed: ${RAW_RESULT_BUNDLE}"
echo "Production-bundle reconnect gate passed with three verified same-process host restarts: ${RECONNECT_RESULT_BUNDLE}"
echo "Host restart evidence: ${HOST_EVENTS}"
echo "Production-bundle real connected-call gate passed under one stable host PID: ${CALL_RESULT_BUNDLE}"
opensteamer_write_state "${RUN_STATUS}" "status=passed"
RUN_SUCCEEDED=1
