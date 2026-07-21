#!/bin/zsh

# Usage: `validate-testflight-paired-reconnect.sh <device-udid> <expected-build>`
# `[artifact-directory]`.
#
# Prerequisites: an unlocked, connected test iPhone on the pinned iOS version with the requested
# production build installed; Xcode command-line tools; the signed Mac capture-host app and its
# launch agent; a continuously readable host log; and working physical audio/video routes.
# `devicectl` cannot prove TestFlight receipt provenance, so App Store Connect/TestFlight remains
# the separate source of truth for distribution.
#
# Optional environment: `AUDIOSTREAMER_HOST_*` selects the launch agent, log, retry timing, and
# churn budget; `AUDIOSTREAMER_EXPECTED_TEAM_ID` pins host signing; `AUDIOSTREAMER_UI_TEST_TIMEOUT_SECONDS`,
# `AUDIOSTREAMER_AUDIO_ORACLE_DURATION_SECONDS`, and `AUDIOSTREAMER_DEVICE_*` tune bounded waits.
# Variables prefixed `AUDIOSTREAMER_SELF_TEST_` and `AUDIOSTREAMER_SCRIPT_SELF_TEST` are reserved
# for deterministic shell regression tests and must be unset for a release run.
#
# Side effects/artifacts: rebuilds/verifies and repeatedly restarts the Mac host, launches the
# production iPhone UI test, plays a deterministic audio challenge, displays a noninteractive
# video challenge, and writes authenticated host-log snapshots, watchdog markers, screenshots,
# result bundles, and oracle evidence under the artifact directory (default
# `/private/tmp/AudioStreamer-device-Paired-Reconnect`). Cleanup stops only processes owned by this run.
# Every wrong build/signature, device lock/disconnect, host/log discontinuity, timeout, or oracle
# rejection exits nonzero; `run-status.txt` becomes passed only after all exact proofs succeed.
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
REPOSITORY_ROOT=${PROJECT_DIR:h:h}
source "${SCRIPT_DIR}/physical-validation-helpers.zsh"
DEVICE_UDID=${1:?usage: $0 device-udid expected-production-build [artifact-directory]}
EXPECTED_BUILD=${2:?usage: $0 [device-udid] expected-production-build [artifact-directory]}
ARTIFACT_DIR=${3:-/private/tmp/AudioStreamer-device-Paired-Reconnect}
APP_LIST_BEFORE="${ARTIFACT_DIR}/apps-before.json"
APP_LIST_AFTER="${ARTIFACT_DIR}/apps-after.json"
CANDIDATE_BEFORE="${ARTIFACT_DIR}/production-candidate-before.json"
CANDIDATE_AFTER="${ARTIFACT_DIR}/production-candidate-after.json"
DEVICE_BEFORE="${ARTIFACT_DIR}/device-before.json"
DEVICE_AFTER="${ARTIFACT_DIR}/device-after.json"
LOCK_STATE_BEFORE="${ARTIFACT_DIR}/lock-state-before.json"
LOCK_STATE_BEFORE_XCODEBUILD="${ARTIFACT_DIR}/lock-state-before-xcodebuild.json"
LOCK_STATE_DURING_TEST="${ARTIFACT_DIR}/lock-state-during-test.json"
LOCK_STATE_AFTER_XCODEBUILD="${ARTIFACT_DIR}/lock-state-after-xcodebuild.json"
RESULT_BUNDLE="${ARTIFACT_DIR}/production-build-${EXPECTED_BUILD}-paired-reconnect.xcresult"
DERIVED_DATA="${ARTIFACT_DIR}/DerivedData"
EXPECTED_MODEL="test iPhone"
EXPECTED_OS="18.x"
EXPECTED_PLATFORM="iOS"
EXPECTED_TEST_NAME="testThreeSameProcessHostRestartsThenColdRelaunchPreservePairing"
EXPECTED_TEST_NODE="PairedReconnectPhysicalUITests/${EXPECTED_TEST_NAME}()"
# xcresult's display identifier includes `()`, while its canonical test URL does not.
EXPECTED_TEST_URL="test://com.apple.xcode/AudioStreamer/AudioStreamerUITests/PairedReconnectPhysicalUITests/${EXPECTED_TEST_NAME}"
HOST_LABEL=${AUDIOSTREAMER_HOST_LAUNCH_AGENT_LABEL:-org.example.audiostreamer.worldwide}
HOST_SERVICE="gui/${UID}/${HOST_LABEL}"
HOST_LOG=${AUDIOSTREAMER_HOST_LOG:-/tmp/audiostreamer/worldwide-host.log}
EXPECTED_MAC_HOST_TEAM_ID=${AUDIOSTREAMER_EXPECTED_TEAM_ID:-TESTTEAM01}
MAC_HOST_BUILD_SCRIPT="${REPOSITORY_ROOT}/macOS/scripts/build-mac-capture-host-app.sh"
MAC_HOST_DEPLOYMENT_VERIFIER="${REPOSITORY_ROOT}/macOS/scripts/verify-mac-host-deployment.sh"
HOST_RESTART_DELAY_SECONDS=${AUDIOSTREAMER_HOST_RESTART_DELAY_SECONDS:-8}
HOST_CONNECTION_WAIT_TIMEOUT_SECONDS=${AUDIOSTREAMER_HOST_CONNECTION_WAIT_TIMEOUT_SECONDS:-90}
HOST_CHURN_LOCK_ATTEMPTS=${AUDIOSTREAMER_HOST_CHURN_LOCK_ATTEMPTS:-600}
UI_TEST_TIMEOUT_SECONDS=${AUDIOSTREAMER_UI_TEST_TIMEOUT_SECONDS:-900}
AUDIO_ORACLE_DURATION_SECONDS=${AUDIOSTREAMER_AUDIO_ORACLE_DURATION_SECONDS:-$((UI_TEST_TIMEOUT_SECONDS + 60))}
UI_TEST_TERMINATION_GRACE_SECONDS=5
DEVICE_COMMAND_TIMEOUT_SECONDS=${AUDIOSTREAMER_DEVICE_COMMAND_TIMEOUT_SECONDS:-15}
DEVICE_LOCK_POLL_SECONDS=${AUDIOSTREAMER_DEVICE_LOCK_POLL_SECONDS:-5}
HOST_EVENTS="${ARTIFACT_DIR}/host-restart-events.log"
HOST_STATUS="${ARTIFACT_DIR}/host-restart-status.txt"
HOST_BUILD_STDOUT="${ARTIFACT_DIR}/host-build-stdout.txt"
HOST_BUILD_STDERR="${ARTIFACT_DIR}/host-build-stderr.txt"
HOST_DEPLOYMENT_MANIFEST="${ARTIFACT_DIR}/host-deployment.txt"
HOST_DEPLOYMENT_STDERR="${ARTIFACT_DIR}/host-deployment-stderr.txt"
HOST_DEPLOYMENT_RECHECK_STDOUT="${ARTIFACT_DIR}/host-deployment-recheck-stdout.txt"
HOST_DEPLOYMENT_RECHECK_STDERR="${ARTIFACT_DIR}/host-deployment-recheck-stderr.txt"
UI_TEST_TIMEOUT_MARKER="${ARTIFACT_DIR}/ui-test-timeout.txt"
DEVICE_LOCKED_MARKER="${ARTIFACT_DIR}/device-locked-during-test.txt"
DEVICE_UNAVAILABLE_MARKER="${ARTIFACT_DIR}/device-unavailable-during-test.txt"
HOST_WATCHER_FAILURE_MARKER="${ARTIFACT_DIR}/host-watcher-failed-during-test.txt"
HOST_CHURN_LOCK="${ARTIFACT_DIR}/host-churn.lock"
HOST_CHURN_STOP_MARKER="${ARTIFACT_DIR}/host-churn-stop.txt"
HOST_LOG_APPEND_CHUNK="${ARTIFACT_DIR}/host-log-appended.bin"
HOST_LOG_COMPLETED_LINES="${ARTIFACT_DIR}/host-log-completed.txt"
HOST_LOG_PARTIAL_LINE="${ARTIFACT_DIR}/host-log-partial.bin"
WATCHDOG_STATE="${ARTIFACT_DIR}/watchdog-state.txt"
WATCHDOG_FAILURE_MARKER="${ARTIFACT_DIR}/watchdog-failure.txt"
RUN_STATUS="${ARTIFACT_DIR}/run-status.txt"
AUDIO_ORACLE_TONE="${ARTIFACT_DIR}/physical-audio-oracle-tone.wav"
AUDIO_ORACLE_TONE_LOG="${ARTIFACT_DIR}/physical-audio-oracle-tone.log"
AUDIO_ORACLE_TONE_FAILURE_MARKER="${ARTIFACT_DIR}/physical-audio-oracle-tone-failed.txt"
SCREEN_ORACLE_SOURCE="${SCRIPT_DIR}/physical-screen-oracle-challenge.swift"
SCREEN_ORACLE_BINARY="${ARTIFACT_DIR}/physical-screen-oracle-challenge"
SCREEN_ORACLE_HEARTBEAT="${ARTIFACT_DIR}/physical-screen-oracle-heartbeat.txt"
SCREEN_ORACLE_LOG="${ARTIFACT_DIR}/physical-screen-oracle.log"
SCREEN_ORACLE_FAILURE_MARKER="${ARTIFACT_DIR}/physical-screen-oracle-failed.txt"
SCREEN_ORACLE_CLEANUP_PROOF="${ARTIFACT_DIR}/physical-screen-oracle-cleanup.txt"
ACTIVITIES_JSON="${ARTIFACT_DIR}/activities.json"
HOST_WATCHER_PID=""
XCODEBUILD_PID=""
XCODEBUILD_GROUP_ISOLATED=0
XCODEBUILD_WATCHDOG_PID=""
HOST_LOG_START_ID=""
HOST_LOG_START_OFFSET=""
HOST_LOG_START_DIGEST=""
EXPECTED_INITIAL_HOST_PID=""
RUN_SUCCEEDED=0
CLEANUP_RUNNING=0
AUDIO_ORACLE_TONE_PID=""
SCREEN_ORACLE_PID=""

mkdir -p "${ARTIFACT_DIR}"
print -r -- "status=running" > "${RUN_STATUS}"

# Every path that can terminate xcodebuild first fences and stops the host-churn worker. If the
# ordinary lock cannot be acquired, kill that worker before removing its stale lock. Therefore the
# stopped validation group can never be killed underneath an in-flight host kickstart.
function stop_host_churn_before_xcodebuild_termination() {
  local lock_poll

  if [[ -f "${HOST_CHURN_STOP_MARKER}" ]]; then
    return 0
  fi
  if [[ -z "${HOST_WATCHER_PID}" ]] \
      || ! kill -0 "${HOST_WATCHER_PID}" 2>/dev/null; then
    rmdir "${HOST_CHURN_LOCK}" 2>/dev/null || true
    audiostreamer_write_state \
      "${HOST_CHURN_STOP_MARKER}" "state=no-live-host-watcher"
    return $?
  fi
  for ((lock_poll = 1; lock_poll <= HOST_CHURN_LOCK_ATTEMPTS; lock_poll++)); do
    if mkdir "${HOST_CHURN_LOCK}" 2>/dev/null; then
      if ! audiostreamer_write_state \
          "${HOST_CHURN_STOP_MARKER}" "state=xcodebuild-termination-requested"; then
        rmdir "${HOST_CHURN_LOCK}" 2>/dev/null || true
        return 1
      fi
      rmdir "${HOST_CHURN_LOCK}" 2>/dev/null || true
      return 0
    fi
    sleep 0.02
  done

  if [[ -n "${HOST_WATCHER_PID}" ]] && kill -0 "${HOST_WATCHER_PID}" 2>/dev/null; then
    audiostreamer_terminate_process_tree \
      "${HOST_WATCHER_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
  fi
  rmdir "${HOST_CHURN_LOCK}" 2>/dev/null || true
  audiostreamer_write_state \
    "${HOST_CHURN_STOP_MARKER}" "state=host-watcher-force-stopped"
}

function cleanup_host_watcher() {
  if [[ -n "${HOST_WATCHER_PID}" ]] && kill -0 "${HOST_WATCHER_PID}" 2>/dev/null; then
    audiostreamer_terminate_process_tree \
      "${HOST_WATCHER_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
    wait "${HOST_WATCHER_PID}" 2>/dev/null || true
  fi
}

function cleanup_xcodebuild() {
  if [[ -n "${XCODEBUILD_WATCHDOG_PID}" ]] \
      && kill -0 "${XCODEBUILD_WATCHDOG_PID}" 2>/dev/null; then
    audiostreamer_terminate_process_tree \
      "${XCODEBUILD_WATCHDOG_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
    wait "${XCODEBUILD_WATCHDOG_PID}" 2>/dev/null || true
  fi
  if [[ -n "${XCODEBUILD_PID}" ]]; then
    if (( XCODEBUILD_GROUP_ISOLATED != 0 )); then
      audiostreamer_terminate_isolated_process_group \
        "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
    elif kill -0 "${XCODEBUILD_PID}" 2>/dev/null; then
      audiostreamer_terminate_process_tree \
        "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
    fi
    audiostreamer_wait_for_final_process_status "${XCODEBUILD_PID}" || true
  fi
}

function cleanup_audio_oracle_tone() {
  if [[ -n "${AUDIO_ORACLE_TONE_PID}" ]] \
      && kill -0 "${AUDIO_ORACLE_TONE_PID}" 2>/dev/null; then
    audiostreamer_terminate_process_tree \
      "${AUDIO_ORACLE_TONE_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
    wait "${AUDIO_ORACLE_TONE_PID}" 2>/dev/null || true
  fi
  AUDIO_ORACLE_TONE_PID=""
}

function cleanup_screen_oracle_challenge() {
  if [[ -n "${SCREEN_ORACLE_PID}" ]] \
      && kill -0 "${SCREEN_ORACLE_PID}" 2>/dev/null; then
    audiostreamer_terminate_process_tree \
      "${SCREEN_ORACLE_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
    wait "${SCREEN_ORACLE_PID}" 2>/dev/null || true
  fi
  SCREEN_ORACLE_PID=""
}

function cleanup_processes() {
  setopt localoptions noerrexit
  trap - ZERR
  if (( CLEANUP_RUNNING != 0 )); then
    return 0
  fi
  CLEANUP_RUNNING=1
  if (( RUN_SUCCEEDED == 0 )); then
    if ! audiostreamer_write_state "${RUN_STATUS}" "status=failed"; then
      print -r -- "status=failed" > "${RUN_STATUS}" 2>/dev/null || true
    fi
  fi
  stop_host_churn_before_xcodebuild_termination || true
  cleanup_host_watcher
  cleanup_xcodebuild
  cleanup_audio_oracle_tone
  cleanup_screen_oracle_challenge
  rmdir "${HOST_CHURN_LOCK}" 2>/dev/null || true
  CLEANUP_RUNNING=0
  return 0
}

function cleanup_after_error() {
  local failure_status=$?
  trap - ZERR
  cleanup_processes
  return "${failure_status}"
}
trap cleanup_processes EXIT
trap cleanup_after_error ZERR
trap audiostreamer_exit_on_interrupt INT
trap audiostreamer_exit_on_termination TERM

audiostreamer_require_positive_integer \
  AUDIOSTREAMER_HOST_RESTART_DELAY_SECONDS \
  "${HOST_RESTART_DELAY_SECONDS}"
audiostreamer_require_positive_integer \
  AUDIOSTREAMER_HOST_CONNECTION_WAIT_TIMEOUT_SECONDS \
  "${HOST_CONNECTION_WAIT_TIMEOUT_SECONDS}"
audiostreamer_require_positive_integer \
  AUDIOSTREAMER_HOST_CHURN_LOCK_ATTEMPTS \
  "${HOST_CHURN_LOCK_ATTEMPTS}"
audiostreamer_require_positive_integer \
  AUDIOSTREAMER_UI_TEST_TIMEOUT_SECONDS \
  "${UI_TEST_TIMEOUT_SECONDS}"
audiostreamer_require_positive_integer \
  AUDIOSTREAMER_AUDIO_ORACLE_DURATION_SECONDS \
  "${AUDIO_ORACLE_DURATION_SECONDS}"
audiostreamer_require_positive_integer \
  AUDIOSTREAMER_DEVICE_COMMAND_TIMEOUT_SECONDS \
  "${DEVICE_COMMAND_TIMEOUT_SECONDS}"
audiostreamer_require_positive_integer \
  AUDIOSTREAMER_DEVICE_LOCK_POLL_SECONDS \
  "${DEVICE_LOCK_POLL_SECONDS}"

rm -rf \
  "${DERIVED_DATA}" \
  "${RESULT_BUNDLE}" \
  "${HOST_EVENTS}" \
  "${HOST_STATUS}" \
  "${HOST_BUILD_STDOUT}" \
  "${HOST_BUILD_STDERR}" \
  "${HOST_DEPLOYMENT_MANIFEST}" \
  "${HOST_DEPLOYMENT_STDERR}" \
  "${HOST_DEPLOYMENT_RECHECK_STDOUT}" \
  "${HOST_DEPLOYMENT_RECHECK_STDERR}" \
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
  "${ARTIFACT_DIR}/summary.json" \
  "${ARTIFACT_DIR}/tests.json" \
  "${ACTIVITIES_JSON}" \
  "${ARTIFACT_DIR}/build-results.json" \
  "${ARTIFACT_DIR}/host-launch-agent-before.txt" \
  "${ARTIFACT_DIR}/fast-group-leader-pid.txt" \
  "${ARTIFACT_DIR}/fast-group-child-pid.txt" \
  "${ARTIFACT_DIR}/cancel-churn-ready.txt" \
  "${ARTIFACT_DIR}/cancel-churn-proceed.txt" \
  "${ARTIFACT_DIR}/cancel-churn-action.txt"

function start_physical_audio_oracle_tone() {
  /usr/bin/python3 - "${AUDIO_ORACLE_TONE}" "${AUDIO_ORACLE_DURATION_SECONDS}" <<'PY'
import math
import struct
import sys
import wave

path = sys.argv[1]
duration_seconds = int(sys.argv[2])
sample_rate = 48_000
one_second = bytearray()
for frame in range(sample_rate):
    high_band = frame >= sample_rate // 2
    amplitude = 3_000 if high_band else 9_000
    left_frequency = 8_003 if high_band else 997
    right_frequency = 11_003 if high_band else 1_499
    left = int(amplitude * math.sin(2 * math.pi * left_frequency * frame / sample_rate))
    right = int(amplitude * math.sin(2 * math.pi * right_frequency * frame / sample_rate))
    one_second.extend(struct.pack("<hh", left, right))
with wave.open(path, "wb") as output:
    output.setnchannels(2)
    output.setsampwidth(2)
    output.setframerate(sample_rate)
    for _ in range(duration_seconds):
        output.writeframesraw(one_second)
PY
  /usr/bin/afplay -v 0.25 "${AUDIO_ORACLE_TONE}" \
    > "${AUDIO_ORACLE_TONE_LOG}" 2>&1 &
  AUDIO_ORACLE_TONE_PID=$!
  sleep 0.25
  if ! kill -0 "${AUDIO_ORACLE_TONE_PID}" 2>/dev/null; then
    echo "Refusing device validation: deterministic Mac audio oracle tone did not start." >&2
    return 1
  fi
}

function start_physical_screen_oracle_challenge() {
  xcrun --sdk macosx swiftc \
    -parse-as-library \
    -framework AppKit \
    "${SCREEN_ORACLE_SOURCE}" \
    -o "${SCREEN_ORACLE_BINARY}"
  "${SCREEN_ORACLE_BINARY}" "${SCREEN_ORACLE_HEARTBEAT}" \
    > "${SCREEN_ORACLE_LOG}" 2>&1 &
  SCREEN_ORACLE_PID=$!
  for challenge_poll in {1..100}; do
    if [[ -s "${SCREEN_ORACLE_HEARTBEAT}" ]]; then
      break
    fi
    if ! kill -0 "${SCREEN_ORACLE_PID}" 2>/dev/null; then
      echo "Refusing device validation: decoded-screen pixel challenge exited during startup." >&2
      return 1
    fi
    sleep 0.05
  done
  if [[ ! -s "${SCREEN_ORACLE_HEARTBEAT}" ]] \
      || ! kill -0 "${SCREEN_ORACLE_PID}" 2>/dev/null; then
    echo "Refusing device validation: decoded-screen pixel challenge did not start." >&2
    return 1
  fi
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

function capture_and_validate_device() {
  local output=$1
  xcrun devicectl device info details \
    --device "${DEVICE_UDID}" \
    --timeout "${DEVICE_COMMAND_TIMEOUT_SECONDS}" \
    --json-output "${output}" >/dev/null
  jq -e \
    --arg udid "${DEVICE_UDID}" \
    --arg model "${EXPECTED_MODEL}" \
    --arg os "${EXPECTED_OS}" '
    (.info.outcome == "success") and
    (.result.hardwareProperties.udid == $udid) and
    (.result.hardwareProperties.marketingName == $model) and
    (.result.hardwareProperties.platform == "iOS") and
    (.result.hardwareProperties.reality == "physical") and
    (.result.deviceProperties.osVersionNumber == $os) and
    (.result.deviceProperties.bootState == "booted")
  ' "${output}" >/dev/null
}

function capture_and_require_unlocked() {
  local output=$1
  audiostreamer_require_device_unlocked \
    "${DEVICE_UDID}" \
    "${DEVICE_COMMAND_TIMEOUT_SECONDS}" \
    "${output}" \
    "device reconnect validation"
}

function capture_production_candidate() {
  local app_list=$1
  local candidate=$2
  xcrun devicectl device info apps \
    --device "${DEVICE_UDID}" \
    --timeout "${DEVICE_COMMAND_TIMEOUT_SECONDS}" \
    --json-output "${app_list}" >/dev/null

  jq -e \
    --arg bundle "org.example.AudioStreamer" \
    --arg build "${EXPECTED_BUILD}" '
    [.result.apps[] | select(.bundleIdentifier == $bundle)] as $matches
    | (($matches | length) == 1) and
      ($matches[0].bundleVersion == $build) and
      ($matches[0].name == "AudioStreamer") and
      ($matches[0].appClip == false) and
      ($matches[0].internalApp == false) and
      ($matches[0].removable == true)
  ' "${app_list}" >/dev/null

  jq -S \
    --arg bundle "org.example.AudioStreamer" '
    [.result.apps[] | select(.bundleIdentifier == $bundle)][0]
  ' "${app_list}" > "${candidate}"
}

function validate_ui_xcresult() {
  local summary
  local tests
  local build_results
  local activities

  summary=$(xcrun xcresulttool get test-results summary \
    --path "${RESULT_BUNDLE}" \
    --compact)
  tests=$(xcrun xcresulttool get test-results tests \
    --path "${RESULT_BUNDLE}" \
    --compact)
  build_results=$(xcrun xcresulttool get build-results \
    --path "${RESULT_BUNDLE}" \
    --compact)
  activities=$(xcrun xcresulttool get test-results activities \
    --path "${RESULT_BUNDLE}" \
    --test-id "${EXPECTED_TEST_URL}" \
    --compact)
  print -r -- "${summary}" > "${ARTIFACT_DIR}/summary.json"
  print -r -- "${tests}" > "${ARTIFACT_DIR}/tests.json"
  print -r -- "${build_results}" > "${ARTIFACT_DIR}/build-results.json"
  print -r -- "${activities}" > "${ACTIVITIES_JSON}"

  jq -e \
    --arg udid "${DEVICE_UDID}" \
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
    (.devicesAndConfigurations[0].device.deviceId == $udid) and
    (.devicesAndConfigurations[0].device.modelName == $model) and
    (.devicesAndConfigurations[0].device.osVersion == $os) and
    (.devicesAndConfigurations[0].device.platform == $platform)
  ' <<<"${summary}" >/dev/null

  jq -e \
    --arg udid "${DEVICE_UDID}" \
    --arg model "${EXPECTED_MODEL}" \
    --arg os "${EXPECTED_OS}" \
    --arg platform "${EXPECTED_PLATFORM}" \
    --arg node "${EXPECTED_TEST_NODE}" \
    --arg url "${EXPECTED_TEST_URL}" '
    ((.devices | length) == 1) and
    (.devices[0].deviceId == $udid) and
    (.devices[0].modelName == $model) and
    (.devices[0].osVersion == $os) and
    (.devices[0].platform == $platform) and
    ([.. | objects | select(.nodeType? == "Test Case")] | length == 1) and
    ([.. | objects | select(.nodeType? == "Test Case")][0].nodeIdentifier == $node) and
    ([.. | objects | select(.nodeType? == "Test Case")][0].nodeIdentifierURL == $url) and
    ([.. | objects | select(.nodeType? == "Test Case")][0].result == "Passed")
  ' <<<"${tests}" >/dev/null

  jq -e \
    --arg udid "${DEVICE_UDID}" \
    --arg model "${EXPECTED_MODEL}" \
    --arg os "${EXPECTED_OS}" \
    --arg platform "${EXPECTED_PLATFORM}" '
    (.status == "succeeded") and
    (([.errorCount, .warningCount, .analyzerWarningCount] | add) == 0) and
    ((.errors | length) == 0) and
    ((.warnings | length) == 0) and
    ((.analyzerWarnings | length) == 0) and
    (.actionTitle == "Testing project AudioStreamer with scheme AudioStreamerUITests") and
    (.destination.deviceId == $udid) and
    (.destination.modelName == $model) and
    (.destination.osVersion == $os) and
    (.destination.platform == $platform)
  ' <<<"${build_results}" >/dev/null

  validate_required_physical_activities_json "${ACTIVITIES_JSON}"
}

function current_host_pid() {
  if [[ "${AUDIOSTREAMER_SCRIPT_SELF_TEST:-}" == host-provenance-* \
      && -n "${AUDIOSTREAMER_SELF_TEST_HOST_PID_FILE:-}" ]]; then
    tr -d '[:space:]' < "${AUDIOSTREAMER_SELF_TEST_HOST_PID_FILE}" 2>/dev/null \
      || true
    return
  fi
  launchctl print "${HOST_SERVICE}" 2>/dev/null \
    | awk '$1 == "pid" && $2 == "=" { print $3; exit }' \
    || true
}

# Bind every replacement launchd PID to the same freshly built code identity.
# A stable path alone is not proof: an already-running process can keep an old
# vnode mapped after the installed app at that path is atomically replaced.
function verify_host_deployment_snapshot() {
  local expected_host_pid=$1
  local phase=$2
  local verifier_result

  rm -f "${HOST_DEPLOYMENT_RECHECK_STDOUT}" "${HOST_DEPLOYMENT_RECHECK_STDERR}"
  if AUDIOSTREAMER_EXPECTED_TEAM_ID="${EXPECTED_MAC_HOST_TEAM_ID}" \
      AUDIOSTREAMER_EXPECTED_HOST_PID="${expected_host_pid}" \
      "${MAC_HOST_DEPLOYMENT_VERIFIER}" \
      > "${HOST_DEPLOYMENT_RECHECK_STDOUT}" \
      2> "${HOST_DEPLOYMENT_RECHECK_STDERR}"; then
    verifier_result=0
  else
    verifier_result=$?
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
  rm -f "${HOST_DEPLOYMENT_RECHECK_STDOUT}" "${HOST_DEPLOYMENT_RECHECK_STDERR}"
  return "${verifier_result}"
}

function kickstart_host_service() {
  if [[ "${AUDIOSTREAMER_SCRIPT_SELF_TEST:-}" == host-provenance-* \
      && -n "${AUDIOSTREAMER_SELF_TEST_HOST_PID_FILE:-}" \
      && -n "${AUDIOSTREAMER_SELF_TEST_HOST_PID_QUEUE:-}" ]]; then
    /usr/bin/python3 - \
        "${AUDIOSTREAMER_SELF_TEST_HOST_PID_FILE}" \
        "${AUDIOSTREAMER_SELF_TEST_HOST_PID_QUEUE}" \
        "${AUDIOSTREAMER_SELF_TEST_KICKSTART_EVENTS}" <<'PY'
import os
import sys

pid_path, queue_path, events_path = sys.argv[1:]
with open(queue_path, "r", encoding="utf-8") as queue:
    values = [line.strip() for line in queue if line.strip()]
if not values:
    sys.exit(1)
next_pid = values.pop(0)
with open(f"{pid_path}.tmp", "w", encoding="utf-8") as destination:
    destination.write(f"{next_pid}\n")
os.replace(f"{pid_path}.tmp", pid_path)
with open(f"{queue_path}.tmp", "w", encoding="utf-8") as queue:
    if values:
        queue.write("\n".join(values) + "\n")
os.replace(f"{queue_path}.tmp", queue_path)
with open(events_path, "a", encoding="utf-8") as events:
    events.write(f"kickstart={next_pid}\n")
PY
    return
  fi
  audiostreamer_run_with_timeout 5 launchctl kickstart -k "${HOST_SERVICE}"
}

function wait_before_host_restart() {
  if [[ "${AUDIOSTREAMER_SCRIPT_SELF_TEST:-}" == host-provenance-* ]]; then
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
      || ! audiostreamer_write_state \
        "${HOST_CHURN_STOP_MARKER}" "state=xcodebuild-ended"; then
    release_host_churn_lock
    return 1
  fi
  release_host_churn_lock
}

# Read, authenticate, split, and audit one new log snapshot before committing its byte cursor. The
# current launchd PID is checked even when the snapshot contains no connected records.
function audit_new_host_log_records() {
  local expected_host_pid=$1
  local current_process_id
  local line
  local new_connections

  if ! audiostreamer_capture_log_snapshot \
      "${HOST_LOG}" \
      "${HOST_LOG_START_ID}" \
      "${HOST_LOG_START_OFFSET}" \
      "${HOST_LOG_START_DIGEST}" \
      "${HOST_LOG_APPEND_CHUNK}"; then
    return 1
  fi
  if ! audiostreamer_split_completed_log_lines \
      "${HOST_LOG_APPEND_CHUNK}" \
      "${HOST_LOG_PARTIAL_LINE}" \
      "${HOST_LOG_COMPLETED_LINES}"; then
    return 1
  fi
  current_process_id=$(current_host_pid)
  if ! audiostreamer_audit_connected_log_lines \
      "${HOST_LOG_COMPLETED_LINES}" \
      "${expected_host_pid}" \
      "${current_process_id}"; then
    return 1
  fi

  new_connections=${AUDIOSTREAMER_AUDITED_CONNECTION_COUNT}
  HOST_LOG_START_OFFSET=${AUDIOSTREAMER_LOG_SNAPSHOT_OFFSET}
  HOST_LOG_START_DIGEST=${AUDIOSTREAMER_LOG_SNAPSHOT_DIGEST}
  AUDIOSTREAMER_NEW_HOST_CONNECTIONS=${new_connections}
  AUDIOSTREAMER_CURRENT_HOST_PID=${current_process_id}
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

function run_host_provenance_self_test() {
  local scenario=${AUDIOSTREAMER_SCRIPT_SELF_TEST#host-provenance-}
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
  AUDIOSTREAMER_SELF_TEST_HOST_PID_FILE=${host_pid_file}
  AUDIOSTREAMER_SELF_TEST_HOST_PID_QUEUE=${host_pid_queue}
  AUDIOSTREAMER_SELF_TEST_KICKSTART_EVENTS=${kickstart_events}
  AUDIOSTREAMER_SELF_TEST_PRE_KICK_READY=${pre_kick_ready}
  if [[ "${scenario}" == "final-audit-mismatch" \
      || "${scenario}" == "final-partial-mismatch" ]]; then
    AUDIOSTREAMER_SELF_TEST_AUDIT_ONLY_READY=${audit_only_ready}
    AUDIOSTREAMER_SELF_TEST_AUDIT_ONLY_PROCEED=${audit_only_proceed}
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
  empty_digest=$(audiostreamer_empty_sha256)
  if ! audiostreamer_capture_log_snapshot \
      "${HOST_LOG}" "" 0 "${empty_digest}" "${HOST_LOG_APPEND_CHUNK}"; then
    return 20
  fi
  HOST_LOG_START_ID=${AUDIOSTREAMER_LOG_SNAPSHOT_ID}
  HOST_LOG_START_OFFSET=${AUDIOSTREAMER_LOG_SNAPSHOT_OFFSET}
  HOST_LOG_START_DIGEST=${AUDIOSTREAMER_LOG_SNAPSHOT_DIGEST}
  rm -f "${HOST_LOG_APPEND_CHUNK}"

  audiostreamer_start_isolated_validation_process /usr/bin/python3 -c '
import os
import sys
import time

scenario, log_path, pid_path, ready_path = sys.argv[1:]

def append(pid):
    with open(log_path, "a", encoding="utf-8") as log:
        log.write(f"Worldwide WebRTC peer state: connected pid={pid}\n")
        log.flush()
        os.fsync(log.fileno())

def wait_file(path):
    deadline = time.monotonic() + 2
    while not os.path.exists(path) and time.monotonic() < deadline:
        time.sleep(0.005)
    if not os.path.exists(path):
        sys.exit(31)

def wait_pid(expected):
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        try:
            with open(pid_path, "r", encoding="utf-8") as source:
                if source.read().strip() == expected:
                    return
        except FileNotFoundError:
            pass
        time.sleep(0.005)
    sys.exit(32)

if scenario == "batched-malformed":
    with open(log_path, "a", encoding="utf-8") as log:
        log.write("Worldwide WebRTC peer state: connected pid=100\n")
        log.write("Worldwide WebRTC peer state: connected pid=0\n")
        log.flush()
        os.fsync(log.fileno())
elif scenario == "pre-kick-mismatch":
    append("100")
    wait_file(ready_path)
    append("999")
elif scenario == "same-inode-rewrite":
    append("100")
    wait_file(ready_path)
    with open(log_path, "rb") as source:
        contents = source.read()
    if not contents.startswith(b"baseline\n"):
        sys.exit(33)
    with open(log_path, "wb") as destination:
        destination.write(b"Baseline\n" + contents[len(b"baseline\n"):])
        destination.flush()
        os.fsync(destination.fileno())
else:
    append("100")
    wait_pid("200")
    append("200")
    wait_pid("100" if scenario == "reused-pid" else "300")
    if scenario != "reused-pid":
        append("300")
        wait_pid("400")
        if scenario == "late-mismatch":
            append("999")
        elif scenario == "unique-pids":
            append("400")
time.sleep(0.5)
' "${scenario}" "${HOST_LOG}" "${host_pid_file}" "${pre_kick_ready}"

  (
    trap - EXIT ZERR INT TERM
    churn_host_after_live_connections
  ) &
  HOST_WATCHER_PID=$!
  audiostreamer_wait_for_final_process_status "${XCODEBUILD_PID}"
  if ! audiostreamer_wait_for_process_group_exit "${XCODEBUILD_PID}" 1; then
    audiostreamer_terminate_isolated_process_group \
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
    audiostreamer_write_state "${audit_only_proceed}" "state=proceed"
  fi
  if ! audiostreamer_wait_for_process_exit "${HOST_WATCHER_PID}" 3; then
    return 21
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
  audiostreamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
}

# SwiftPM invokes this probe in a separate real zsh process. It protects against shell-runtime
# failures (such as assigning a read-only special parameter) that `zsh -n` cannot detect.
if [[ "${AUDIOSTREAMER_SCRIPT_SELF_TEST:-}" == "validate-physical-activities" ]]; then
  validate_required_physical_activities_json \
    "${AUDIOSTREAMER_SELF_TEST_ACTIVITIES_JSON:?missing activity fixture}"
  audiostreamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${AUDIOSTREAMER_SCRIPT_SELF_TEST:-}" == "audio-oracle-tone" ]]; then
  start_physical_audio_oracle_tone
  /usr/bin/afinfo "${AUDIO_ORACLE_TONE}" >/dev/null
  kill -0 "${AUDIO_ORACLE_TONE_PID}"
  cleanup_audio_oracle_tone
  audiostreamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${AUDIOSTREAMER_SCRIPT_SELF_TEST:-}" == "screen-oracle-challenge" ]]; then
  start_physical_screen_oracle_challenge
  first_counter=$(physical_screen_oracle_counter)
  sleep 0.4
  second_counter=$(physical_screen_oracle_counter)
  (( second_counter > first_counter ))
  kill -0 "${SCREEN_ORACLE_PID}"
  challenge_pid=${SCREEN_ORACLE_PID}
  cleanup_screen_oracle_challenge
  ! kill -0 "${challenge_pid}" 2>/dev/null
  audiostreamer_write_state \
    "${SCREEN_ORACLE_CLEANUP_PROOF}" \
    "state=terminated pid=${challenge_pid} first=${first_counter} last=${second_counter}"
  audiostreamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${AUDIOSTREAMER_SCRIPT_SELF_TEST:-}" == "write-host-status" ]]; then
  write_host_status pending 2 1 "runtime self-test"
  audiostreamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${AUDIOSTREAMER_SCRIPT_SELF_TEST:-}" == "cancel-stopped-churn" ]]; then
  churn_ready="${ARTIFACT_DIR}/cancel-churn-ready.txt"
  churn_proceed="${ARTIFACT_DIR}/cancel-churn-proceed.txt"
  churn_action="${ARTIFACT_DIR}/cancel-churn-action.txt"
  audiostreamer_start_isolated_validation_process /bin/zsh -c \
    'trap "exit 0" TERM; while true; do sleep 30; done'
  (
    mkdir "${HOST_CHURN_LOCK}"
    audiostreamer_suspend_isolated_process_group "${XCODEBUILD_PID}" 3
    audiostreamer_write_state "${churn_ready}" "state=stopped"
    while [[ ! -f "${churn_proceed}" ]]; do
      sleep 0.02
    done
    audiostreamer_write_state "${churn_action}" "action=ran"
    audiostreamer_resume_process_group "${XCODEBUILD_PID}" || true
    rmdir "${HOST_CHURN_LOCK}" 2>/dev/null || true
  ) &
  HOST_WATCHER_PID=$!
  for ready_poll in {1..250}; do
    [[ -f "${churn_ready}" ]] && break
    sleep 0.02
  done
  [[ -f "${churn_ready}" ]] || exit 9

  stop_host_churn_before_xcodebuild_termination
  audiostreamer_terminate_isolated_process_group \
    "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
  audiostreamer_wait_for_final_process_status "${XCODEBUILD_PID}"
  XCODEBUILD_PID=""
  XCODEBUILD_GROUP_ISOLATED=0
  audiostreamer_write_state "${churn_proceed}" "state=proceed"
  sleep 0.1
  [[ ! -f "${churn_action}" ]] || exit 10
  HOST_WATCHER_PID=""
  audiostreamer_write_state "${RUN_STATUS}" "status=self-test-passed"
  RUN_SUCCEEDED=1
  exit 0
fi
if [[ "${AUDIOSTREAMER_SCRIPT_SELF_TEST:-}" == "fast-group-failure" ]]; then
  audiostreamer_start_isolated_validation_process /bin/zsh -c '
    /usr/bin/python3 -c "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); signal.signal(signal.SIGHUP, signal.SIG_IGN); time.sleep(30)" &
    print -r -- $! > "$1"
    exit 0
  ' fast-group "${ARTIFACT_DIR}/fast-group-child-pid.txt"
  audiostreamer_wait_for_final_process_status "${XCODEBUILD_PID}" || true
  function fail_fast_group_self_test() { return 8 }
  fail_fast_group_self_test
fi
if [[ "${AUDIOSTREAMER_SCRIPT_SELF_TEST:-}" == "fail-command" ]]; then
  function fail_for_runtime_self_test() { return 9 }
  fail_for_runtime_self_test
fi
if [[ "${AUDIOSTREAMER_SCRIPT_SELF_TEST:-}" == "self-signal" ]]; then
  (sleep 0.1; kill -TERM $$) &
  SELF_SIGNAL_PID=$!
  sleep 0.3
  wait "${SELF_SIGNAL_PID}" 2>/dev/null || true
  audiostreamer_write_state "${RUN_STATUS}" "status=passed"
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
      new_connections=${AUDIOSTREAMER_NEW_HOST_CONNECTIONS}
      if (( new_connections > 0 )); then
        first_connection_number=$((connections + 1))
        record_audited_host_connections \
          "${first_connection_number}" "${AUDIOSTREAMER_CURRENT_HOST_PID}"
        connections=$((connections + new_connections))
      fi
      if (( restarts != 3 )); then
        release_host_churn_lock
        write_host_status failed "${connections}" "${restarts}" \
          "xcodebuild ended before three host replacements were verified"
        return 1
      fi
      if [[ "${AUDIOSTREAMER_SCRIPT_SELF_TEST:-}" != host-provenance-* ]] \
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
    new_connections=${AUDIOSTREAMER_NEW_HOST_CONNECTIONS}
    if (( new_connections > 0 )); then
      first_connection_number=$((connections + 1))
      record_audited_host_connections \
        "${first_connection_number}" "${AUDIOSTREAMER_CURRENT_HOST_PID}"
      connections=$((connections + new_connections))
    fi
    if (( restarts >= 3 || new_connections == 0 )); then
      sleep 0.2
      continue
    fi

    previous_pid=${AUDIOSTREAMER_CURRENT_HOST_PID}
    if [[ -n "${AUDIOSTREAMER_SELF_TEST_PRE_KICK_READY:-}" ]]; then
      audiostreamer_write_state \
        "${AUDIOSTREAMER_SELF_TEST_PRE_KICK_READY}" "state=ready"
    fi
    wait_before_host_restart
    if ! audit_new_host_log_records "${expected_host_pid}"; then
      write_host_status failed "${connections}" "${restarts}" \
        "host log or PID provenance changed during the pre-kick delay"
      return 1
    fi
    new_connections=${AUDIOSTREAMER_NEW_HOST_CONNECTIONS}
    if (( new_connections > 0 )); then
      first_connection_number=$((connections + 1))
      record_audited_host_connections \
        "${first_connection_number}" "${AUDIOSTREAMER_CURRENT_HOST_PID}"
      connections=$((connections + new_connections))
    fi
    replacement_pid=$(current_host_pid)
    if ! audiostreamer_require_same_host_process \
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
        || ! audiostreamer_require_same_host_process \
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
    if ! audiostreamer_suspend_isolated_process_group "${XCODEBUILD_PID}" 3; then
      release_host_churn_lock
      write_host_status failed "${connections}" "${restarts}" \
        "could not suspend the live xcodebuild process group before host churn"
      return 1
    fi
    replacement_pid=$(current_host_pid)
    if [[ -f "${HOST_CHURN_STOP_MARKER}" ]] \
        || ! audiostreamer_require_same_host_process \
          "${expected_host_pid}" "${previous_pid}" "${replacement_pid}" \
        || ! audit_new_host_log_records "${expected_host_pid}"; then
      audiostreamer_resume_process_group "${XCODEBUILD_PID}" || true
      release_host_churn_lock
      write_host_status failed "${connections}" "${restarts}" \
        "host or log provenance changed before connected PID ${previous_pid} could be kickstarted"
      return 1
    fi
    new_connections=${AUDIOSTREAMER_NEW_HOST_CONNECTIONS}
    if (( new_connections > 0 )); then
      first_connection_number=$((connections + 1))
      record_audited_host_connections \
        "${first_connection_number}" "${AUDIOSTREAMER_CURRENT_HOST_PID}"
      connections=$((connections + new_connections))
    fi

    # The parent publishes its stop marker under this same lock only after the isolated validation
    # group ends. The final snapshot, PID proof, and kickstart are one stopped critical section.
    if ! kickstart_host_service; then
      audiostreamer_resume_process_group "${XCODEBUILD_PID}" || true
      release_host_churn_lock
      write_host_status failed "${connections}" "${restarts}" \
        "launchctl kickstart failed after connection ${connections}"
      return 1
    fi
    if ! audiostreamer_resume_process_group "${XCODEBUILD_PID}"; then
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

    if [[ "${AUDIOSTREAMER_SCRIPT_SELF_TEST:-}" != host-provenance-* ]] \
        && ! verify_host_deployment_snapshot \
          "${replacement_pid}" "restart-$((restarts + 1))"; then
      write_host_status failed "${connections}" "${restarts}" \
        "replacement host PID ${replacement_pid} did not match the freshly built signed app"
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
      if [[ -n "${AUDIOSTREAMER_SELF_TEST_AUDIT_ONLY_READY:-}" \
          && -n "${AUDIOSTREAMER_SELF_TEST_AUDIT_ONLY_PROCEED:-}" ]]; then
        audiostreamer_write_state \
          "${AUDIOSTREAMER_SELF_TEST_AUDIT_ONLY_READY}" "state=ready"
        while [[ ! -f "${AUDIOSTREAMER_SELF_TEST_AUDIT_ONLY_PROCEED}" ]]; do
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

if [[ "${AUDIOSTREAMER_SCRIPT_SELF_TEST:-}" == host-provenance-* ]]; then
  run_host_provenance_self_test
  exit 0
fi

if [[ -z "${AUDIOSTREAMER_EXPECTED_TEAM_ID:-}" ]]; then
  echo "AUDIOSTREAMER_EXPECTED_TEAM_ID is required for a physical release run." >&2
  exit 2
fi
EXPECTED_MAC_HOST_TEAM_ID=${AUDIOSTREAMER_EXPECTED_TEAM_ID}

capture_and_validate_device "${DEVICE_BEFORE}"
capture_and_require_unlocked "${LOCK_STATE_BEFORE}"
capture_production_candidate "${APP_LIST_BEFORE}" "${CANDIDATE_BEFORE}"

# Rebuild from this checkout, then bind the physical evidence to that exact signed artifact and
# live launchd process. A loaded label and PID are insufficient: a legacy app or naked executable
# can connect while macOS privacy permissions belong to a different code identity.
if ! "${MAC_HOST_BUILD_SCRIPT}" \
    > "${HOST_BUILD_STDOUT}" 2> "${HOST_BUILD_STDERR}"; then
  echo "Refusing device reconnect validation: the signed Mac host build failed." >&2
  cat "${HOST_BUILD_STDERR}" >&2
  exit 3
fi
if [[ "$(tail -n 1 "${HOST_BUILD_STDOUT}")" \
    != "${REPOSITORY_ROOT}/build/AudioStreamer Host.app" ]]; then
  echo "Refusing device reconnect validation: the Mac host build returned an unexpected artifact." >&2
  exit 3
fi
EXPECTED_INITIAL_HOST_PID=$(current_host_pid)
if [[ -z "${EXPECTED_INITIAL_HOST_PID}" \
    || "${EXPECTED_INITIAL_HOST_PID}" == *[^0-9]* ]]; then
  echo "Refusing device reconnect validation: launch agent ${HOST_SERVICE} has no valid running host PID." >&2
  exit 3
fi
if ! AUDIOSTREAMER_EXPECTED_TEAM_ID="${EXPECTED_MAC_HOST_TEAM_ID}" \
    AUDIOSTREAMER_EXPECTED_HOST_PID="${EXPECTED_INITIAL_HOST_PID}" \
    "${MAC_HOST_DEPLOYMENT_VERIFIER}" \
    > "${HOST_DEPLOYMENT_MANIFEST}" 2> "${HOST_DEPLOYMENT_STDERR}"; then
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

# The build and app-list checks can take long enough for the device to relock after preflight.
capture_and_require_unlocked "${LOCK_STATE_BEFORE_XCODEBUILD}"
HOST_LOG_START_OFFSET=0
HOST_LOG_START_DIGEST=$(audiostreamer_empty_sha256)
if ! audiostreamer_capture_log_snapshot \
    "${HOST_LOG}" \
    "" \
    "${HOST_LOG_START_OFFSET}" \
    "${HOST_LOG_START_DIGEST}" \
    "${HOST_LOG_APPEND_CHUNK}"; then
  echo "Refusing device reconnect validation: host log identity could not be captured." >&2
  exit 3
fi
HOST_LOG_START_ID=${AUDIOSTREAMER_LOG_SNAPSHOT_ID}
HOST_LOG_START_OFFSET=${AUDIOSTREAMER_LOG_SNAPSHOT_OFFSET}
HOST_LOG_START_DIGEST=${AUDIOSTREAMER_LOG_SNAPSHOT_DIGEST}
if [[ "${AUDIOSTREAMER_LOG_SNAPSHOT_ENDS_WITH_NEWLINE}" != "1" ]]; then
  echo "Refusing device reconnect validation: host log does not end at a complete record boundary." >&2
  exit 3
fi
rm -f "${HOST_LOG_APPEND_CHUNK}"
print -rn -- "" > "${HOST_LOG_PARTIAL_LINE}"

start_physical_audio_oracle_tone
start_physical_screen_oracle_challenge
SCREEN_ORACLE_LAST_COUNTER=$(physical_screen_oracle_counter)

audiostreamer_start_isolated_validation_process xcodebuild test \
  -project "${PROJECT_DIR}/AudioStreamer.xcodeproj" \
  -scheme AudioStreamerUITests \
  -configuration Debug \
  -destination "platform=iOS,id=${DEVICE_UDID}" \
  -derivedDataPath "${DERIVED_DATA}" \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 600 \
  -maximum-test-execution-time-allowance 720 \
  -only-testing:AudioStreamerUITests/PairedReconnectPhysicalUITests/testThreeSameProcessHostRestartsThenColdRelaunchPreservePairing \
  -resultBundlePath "${RESULT_BUNDLE}"
(
  trap - EXIT ZERR INT TERM
  churn_host_after_live_connections
) &
HOST_WATCHER_PID=$!
(
  set -e
  audiostreamer_write_state "${WATCHDOG_STATE}" "state=monitoring"
  watchdog_started=${SECONDS}
  lock_poll_started=${SECONDS}
  lock_query_failures=0
  screen_oracle_stale_polls=0
  while kill -0 "${XCODEBUILD_PID}" 2>/dev/null; do
    if [[ -z "${AUDIO_ORACLE_TONE_PID}" ]] \
        || ! kill -0 "${AUDIO_ORACLE_TONE_PID}" 2>/dev/null; then
      print -r -- \
        "The deterministic Mac audio oracle tone stopped during physical validation." \
        > "${AUDIO_ORACLE_TONE_FAILURE_MARKER}"
      stop_host_churn_before_xcodebuild_termination || true
      audiostreamer_terminate_isolated_process_group \
        "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
      audiostreamer_write_state "${WATCHDOG_STATE}" "state=audio-oracle-failure-handled"
      exit 0
    fi
    current_screen_oracle_counter=$(physical_screen_oracle_counter || true)
    if [[ -z "${SCREEN_ORACLE_PID}" ]] \
        || ! kill -0 "${SCREEN_ORACLE_PID}" 2>/dev/null \
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
      audiostreamer_terminate_isolated_process_group \
        "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
      audiostreamer_write_state "${WATCHDOG_STATE}" "state=screen-oracle-failure-handled"
      exit 0
    fi
    if (( SECONDS - watchdog_started >= UI_TEST_TIMEOUT_SECONDS )); then
      print -r -- \
        "Timed out after ${UI_TEST_TIMEOUT_SECONDS}s while running the physical device UI gate." \
        > "${UI_TEST_TIMEOUT_MARKER}"
      stop_host_churn_before_xcodebuild_termination || true
      audiostreamer_terminate_isolated_process_group \
        "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
      audiostreamer_write_state "${WATCHDOG_STATE}" "state=timeout-handled"
      exit 0
    fi
    if ! kill -0 "${HOST_WATCHER_PID}" 2>/dev/null \
        && ! grep -qx 'status=passed' "${HOST_STATUS}" 2>/dev/null; then
      print -r -- \
        "The host restart watcher failed before completing its three verified restarts." \
        > "${HOST_WATCHER_FAILURE_MARKER}"
      stop_host_churn_before_xcodebuild_termination || true
      audiostreamer_terminate_isolated_process_group \
        "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
      audiostreamer_write_state "${WATCHDOG_STATE}" "state=host-watcher-failure-handled"
      exit 0
    fi
    if (( SECONDS - lock_poll_started >= DEVICE_LOCK_POLL_SECONDS )); then
      lock_poll_started=${SECONDS}
      if audiostreamer_device_is_unlocked \
          "${DEVICE_UDID}" \
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
          audiostreamer_terminate_isolated_process_group \
            "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
          audiostreamer_write_state "${WATCHDOG_STATE}" "state=device-locked-handled"
          exit 0
        fi
        lock_query_failures=$((lock_query_failures + 1))
        if (( lock_query_failures >= 2 )); then
          print -r -- \
            "The iPhone lock state could not be verified twice during the physical device UI gate." \
            > "${DEVICE_UNAVAILABLE_MARKER}"
          stop_host_churn_before_xcodebuild_termination || true
          audiostreamer_terminate_isolated_process_group \
            "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
          audiostreamer_write_state "${WATCHDOG_STATE}" "state=device-unavailable-handled"
          exit 0
        fi
      fi
    fi
    sleep 1
  done
  audiostreamer_write_state "${WATCHDOG_STATE}" "state=xcodebuild-ended"
) &
XCODEBUILD_WATCHDOG_PID=$!
audiostreamer_wait_for_final_process_status "${XCODEBUILD_PID}"
XCODEBUILD_STATUS=${AUDIOSTREAMER_FINAL_PROCESS_STATUS}
if ! audiostreamer_wait_for_process_group_exit "${XCODEBUILD_PID}" 2; then
  print -r -- \
    "The device xcodebuild process group remained alive after its leader exited." \
    > "${WATCHDOG_FAILURE_MARKER}"
  audiostreamer_terminate_isolated_process_group \
    "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
  if ! audiostreamer_wait_for_process_group_exit "${XCODEBUILD_PID}" 2; then
    echo "The device xcodebuild process group survived forced termination." >&2
    exit 7
  fi
fi
if ! request_final_host_log_audit; then
  print -r -- \
    "The parent could not publish the host-churn stop marker after xcodebuild ended." \
    > "${WATCHDOG_FAILURE_MARKER}"
fi
XCODEBUILD_PID=""
XCODEBUILD_GROUP_ISOLATED=0
if ! audiostreamer_wait_for_process_exit \
    "${XCODEBUILD_WATCHDOG_PID}" "$((DEVICE_COMMAND_TIMEOUT_SECONDS + 5))"; then
  print -r -- \
    "The device lock watchdog did not finish after xcodebuild ended." \
    > "${WATCHDOG_FAILURE_MARKER}"
  audiostreamer_terminate_process_tree \
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
  capture_and_require_unlocked "${LOCK_STATE_AFTER_XCODEBUILD}"
fi

# Capture the exact production candidate again even when XCTest fails. An install, replacement,
# or update during the gate invalidates both positive and negative test evidence.
capture_and_validate_device "${DEVICE_AFTER}"
capture_production_candidate "${APP_LIST_AFTER}" "${CANDIDATE_AFTER}"
if ! cmp -s "${CANDIDATE_BEFORE}" "${CANDIDATE_AFTER}"; then
  echo "Production candidate changed during device validation." >&2
  diff -u "${CANDIDATE_BEFORE}" "${CANDIDATE_AFTER}" >&2 || true
  exit 2
fi
if (( XCODEBUILD_STATUS != 0 )); then
  echo "Physical UI test failed with xcodebuild status ${XCODEBUILD_STATUS}." >&2
  exit "${XCODEBUILD_STATUS}"
fi
if [[ -z "${AUDIO_ORACLE_TONE_PID}" ]] \
    || ! kill -0 "${AUDIO_ORACLE_TONE_PID}" 2>/dev/null; then
  echo "The deterministic Mac audio oracle tone was not alive at final audit." >&2
  exit 7
fi
if [[ -z "${SCREEN_ORACLE_PID}" ]] \
    || ! kill -0 "${SCREEN_ORACLE_PID}" 2>/dev/null \
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

validate_ui_xcresult

echo "Production-bundle device reconnect gate passed with three verified same-process host restarts: ${RESULT_BUNDLE}"
echo "Host restart evidence: ${HOST_EVENTS}"
audiostreamer_write_state "${RUN_STATUS}" "status=passed"
RUN_SUCCEEDED=1
