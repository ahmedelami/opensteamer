#!/bin/zsh

# Usage: `validate-release-pair-baseline.sh <coredevice-identifier> <hardware-udid>
# <expected-production-build> [artifact-directory]`.
#
# Prerequisites: an unlocked, connected test iPhone on the pinned iOS version with the requested
# production opensteamer build already installed, plus Xcode command-line tools authorized for
# that device. The selected UI test uses only stable accessibility identifiers, so a candidate
# build cannot manufacture the pre-update saved-pair evidence.
#
# Optional environment: `OPENSTEAMER_BASELINE_UI_TEST_TIMEOUT_SECONDS`,
# `OPENSTEAMER_DEVICE_COMMAND_TIMEOUT_SECONDS`, and `OPENSTEAMER_DEVICE_LOCK_POLL_SECONDS`
# adjust bounded waits; `OPENSTEAMER_SCRIPT_SELF_TEST` is reserved for shell regression tests.
#
# Side effects/artifacts: launches the installed production app through a UI-test runner and writes
# app/device/lock snapshots, watchdog markers, logs, and the baseline `.xcresult` under the artifact
# directory (default `/private/tmp/opensteamer-device-InstalledRelease-Baseline`). Any wrong build, lock,
# disconnect, timeout, missing oracle, or test failure exits nonzero and leaves `run-status.txt` as
# failed; success is recorded only after the result bundle proves the exact test passed.
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
source "${SCRIPT_DIR}/physical-validation-helpers.zsh"
if (( $# < 3 || $# > 4 )) \
    || [[ -z "${1:-}" || -z "${2:-}" || -z "${3:-}" ]]; then
  echo \
    "usage: $0 coredevice-identifier hardware-udid expected-production-build [artifact-directory]" \
    >&2
  exit 2
fi
COREDEVICE_IDENTIFIER=$1
HARDWARE_UDID=$2
EXPECTED_BUILD=$3
shift 3
ARTIFACT_DIR=${1:-/private/tmp/opensteamer-device-InstalledRelease-Baseline}
EXPECTED_MODEL="iPhone XR"
EXPECTED_OS="18.7.9"
EXPECTED_PLATFORM="iOS"
EXPECTED_TEST_NAME="testLegacyInstalledReleaseProductionBaselineHasSavedPair"
EXPECTED_TEST_NODE="PairedReconnectPhysicalUITests/${EXPECTED_TEST_NAME}()"
EXPECTED_TEST_URL="test://com.apple.xcode/opensteamer/opensteamerUITests/PairedReconnectPhysicalUITests/${EXPECTED_TEST_NAME}"
UI_TEST_TIMEOUT_SECONDS=${OPENSTEAMER_BASELINE_UI_TEST_TIMEOUT_SECONDS:-600}
UI_TEST_TERMINATION_GRACE_SECONDS=5
DEVICE_COMMAND_TIMEOUT_SECONDS=${OPENSTEAMER_DEVICE_COMMAND_TIMEOUT_SECONDS:-15}
DEVICE_LOCK_POLL_SECONDS=${OPENSTEAMER_DEVICE_LOCK_POLL_SECONDS:-5}
DEVICE_BEFORE="${ARTIFACT_DIR}/device-before.json"
DEVICE_AFTER="${ARTIFACT_DIR}/device-after.json"
LOCK_STATE_BEFORE="${ARTIFACT_DIR}/lock-state-before.json"
LOCK_STATE_BEFORE_XCODEBUILD="${ARTIFACT_DIR}/lock-state-before-xcodebuild.json"
LOCK_STATE_DURING_TEST="${ARTIFACT_DIR}/lock-state-during-test.json"
LOCK_STATE_AFTER_XCODEBUILD="${ARTIFACT_DIR}/lock-state-after-xcodebuild.json"
APP_LIST_BEFORE="${ARTIFACT_DIR}/apps-before.json"
APP_LIST_AFTER="${ARTIFACT_DIR}/apps-after.json"
CANDIDATE_BEFORE="${ARTIFACT_DIR}/installed-release-before.json"
CANDIDATE_AFTER="${ARTIFACT_DIR}/installed-release-after.json"
RESULT_BUNDLE="${ARTIFACT_DIR}/installed-release-${EXPECTED_BUILD}-saved-pair-baseline.xcresult"
DERIVED_DATA="${ARTIFACT_DIR}/DerivedData"
TIMEOUT_MARKER="${ARTIFACT_DIR}/ui-test-timeout.txt"
DEVICE_LOCKED_MARKER="${ARTIFACT_DIR}/device-locked-during-test.txt"
DEVICE_UNAVAILABLE_MARKER="${ARTIFACT_DIR}/device-unavailable-during-test.txt"
WATCHDOG_STATE="${ARTIFACT_DIR}/watchdog-state.txt"
WATCHDOG_FAILURE_MARKER="${ARTIFACT_DIR}/watchdog-failure.txt"
RUN_STATUS="${ARTIFACT_DIR}/run-status.txt"
XCODEBUILD_PID=""
XCODEBUILD_GROUP_ISOLATED=0
XCODEBUILD_WATCHDOG_PID=""
RUN_SUCCEEDED=0
CLEANUP_RUNNING=0

mkdir -p "${ARTIFACT_DIR}"
print -r -- "status=running" > "${RUN_STATUS}"

function cleanup() {
  setopt localoptions noerrexit
  trap - ZERR
  if (( CLEANUP_RUNNING != 0 )); then
    return 0
  fi
  CLEANUP_RUNNING=1
  if [[ -n "${XCODEBUILD_WATCHDOG_PID}" ]] \
      && kill -0 "${XCODEBUILD_WATCHDOG_PID}" 2>/dev/null; then
    opensteamer_terminate_process_tree \
      "${XCODEBUILD_WATCHDOG_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
    wait "${XCODEBUILD_WATCHDOG_PID}" 2>/dev/null || true
  fi
  if [[ -n "${XCODEBUILD_PID}" ]]; then
    if (( XCODEBUILD_GROUP_ISOLATED != 0 )); then
      opensteamer_terminate_isolated_process_group \
        "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
    elif kill -0 "${XCODEBUILD_PID}" 2>/dev/null; then
      opensteamer_terminate_process_tree \
        "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
    fi
    opensteamer_wait_for_final_process_status "${XCODEBUILD_PID}" || true
  fi
  if (( RUN_SUCCEEDED == 0 )); then
    if ! opensteamer_write_state "${RUN_STATUS}" "status=failed"; then
      print -r -- "status=failed" > "${RUN_STATUS}" 2>/dev/null || true
    fi
  fi
  CLEANUP_RUNNING=0
  return 0
}

function cleanup_after_error() {
  local failure_status=$?
  trap - ZERR
  cleanup
  return "${failure_status}"
}
trap cleanup EXIT
trap cleanup_after_error ZERR
trap opensteamer_exit_on_interrupt INT
trap opensteamer_exit_on_termination TERM

opensteamer_require_positive_integer \
  OPENSTEAMER_BASELINE_UI_TEST_TIMEOUT_SECONDS \
  "${UI_TEST_TIMEOUT_SECONDS}"
opensteamer_require_positive_integer \
  OPENSTEAMER_DEVICE_COMMAND_TIMEOUT_SECONDS \
  "${DEVICE_COMMAND_TIMEOUT_SECONDS}"
opensteamer_require_positive_integer \
  OPENSTEAMER_DEVICE_LOCK_POLL_SECONDS \
  "${DEVICE_LOCK_POLL_SECONDS}"

rm -rf \
  "${DERIVED_DATA}" \
  "${RESULT_BUNDLE}" \
  "${TIMEOUT_MARKER}" \
  "${DEVICE_LOCKED_MARKER}" \
  "${DEVICE_UNAVAILABLE_MARKER}" \
  "${WATCHDOG_STATE}" \
  "${WATCHDOG_FAILURE_MARKER}" \
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
  "${ARTIFACT_DIR}/build-results.json" \
  "${ARTIFACT_DIR}/fast-group-leader-pid.txt" \
  "${ARTIFACT_DIR}/fast-group-child-pid.txt" \
  "${RUN_STATUS}.tmp"

function capture_and_validate_device() {
  local output=$1
  xcrun devicectl device info details \
    --device "${COREDEVICE_IDENTIFIER}" \
    --timeout "${DEVICE_COMMAND_TIMEOUT_SECONDS}" \
    --json-output "${output}" >/dev/null
  opensteamer_require_physical_iphone_xr_details \
    "${output}" \
    "${COREDEVICE_IDENTIFIER}" \
    "${HARDWARE_UDID}"
}

function capture_and_require_unlocked() {
  local output=$1
  opensteamer_require_device_unlocked \
    "${COREDEVICE_IDENTIFIER}" \
    "${DEVICE_COMMAND_TIMEOUT_SECONDS}" \
    "${output}" \
    "device baseline validation"
}

function capture_production_installedRelease() {
  local app_list=$1
  local candidate=$2
  xcrun devicectl device info apps \
    --device "${COREDEVICE_IDENTIFIER}" \
    --timeout "${DEVICE_COMMAND_TIMEOUT_SECONDS}" \
    --json-output "${app_list}" >/dev/null

  # Select the App Store/TestFlight production bundle while validating the visible product.
  jq -e \
    --arg bundle "com.elamin.AudioStreamer" \
    --arg build "${EXPECTED_BUILD}" '
    [.result.apps[] | select(.bundleIdentifier == $bundle)] as $matches
    | (($matches | length) == 1) and
      ($matches[0].bundleVersion == $build) and
      ($matches[0].name == "opensteamer") and
      ($matches[0].appClip == false) and
      ($matches[0].internalApp == false) and
      ($matches[0].removable == true)
  ' "${app_list}" >/dev/null

  jq -S \
    --arg bundle "com.elamin.AudioStreamer" '
    [.result.apps[] | select(.bundleIdentifier == $bundle)][0]
  ' "${app_list}" > "${candidate}"
}

function validate_xcresult() {
  local summary
  local tests
  local build_results

  summary=$(xcrun xcresulttool get test-results summary \
    --path "${RESULT_BUNDLE}" \
    --compact)
  tests=$(xcrun xcresulttool get test-results tests \
    --path "${RESULT_BUNDLE}" \
    --compact)
  build_results=$(xcrun xcresulttool get build-results \
    --path "${RESULT_BUNDLE}" \
    --compact)
  print -r -- "${summary}" > "${ARTIFACT_DIR}/summary.json"
  print -r -- "${tests}" > "${ARTIFACT_DIR}/tests.json"
  print -r -- "${build_results}" > "${ARTIFACT_DIR}/build-results.json"

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
  ' <<<"${summary}" >/dev/null

  jq -e \
    --arg hardware_udid "${HARDWARE_UDID}" \
    --arg model "${EXPECTED_MODEL}" \
    --arg os "${EXPECTED_OS}" \
    --arg platform "${EXPECTED_PLATFORM}" \
    --arg node "${EXPECTED_TEST_NODE}" \
    --arg url "${EXPECTED_TEST_URL}" '
    ((.devices | length) == 1) and
    (.devices[0].deviceId == $hardware_udid) and
    (.devices[0].modelName == $model) and
    (.devices[0].osVersion == $os) and
    (.devices[0].platform == $platform) and
    ([.. | objects | select(.nodeType? == "Test Case")] | length == 1) and
    ([.. | objects | select(.nodeType? == "Test Case")][0].nodeIdentifier == $node) and
    ([.. | objects | select(.nodeType? == "Test Case")][0].nodeIdentifierURL == $url) and
    ([.. | objects | select(.nodeType? == "Test Case")][0].result == "Passed")
  ' <<<"${tests}" >/dev/null

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
  ' <<<"${build_results}" >/dev/null
}

if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "fast-group-failure" ]]; then
  opensteamer_start_isolated_validation_process /bin/zsh -c '
    /usr/bin/python3 -c "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); signal.signal(signal.SIGHUP, signal.SIG_IGN); time.sleep(30)" &
    print -r -- $! > "$1"
    exit 0
  ' fast-group "${ARTIFACT_DIR}/fast-group-child-pid.txt"
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

capture_and_validate_device "${DEVICE_BEFORE}"
capture_and_require_unlocked "${LOCK_STATE_BEFORE}"
capture_production_installedRelease "${APP_LIST_BEFORE}" "${CANDIDATE_BEFORE}"

# Device and app inspection can take long enough for the device to relock after preflight.
capture_and_require_unlocked "${LOCK_STATE_BEFORE_XCODEBUILD}"

opensteamer_start_isolated_validation_process xcodebuild test \
  -project "${PROJECT_DIR}/opensteamer.xcodeproj" \
  -scheme opensteamerUITests \
  -configuration Debug \
  -destination "platform=iOS,id=${HARDWARE_UDID}" \
  -derivedDataPath "${DERIVED_DATA}" \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 120 \
  -only-testing:opensteamerUITests/PairedReconnectPhysicalUITests/testLegacyInstalledReleaseProductionBaselineHasSavedPair \
  -resultBundlePath "${RESULT_BUNDLE}"
(
  set -e
  opensteamer_write_state "${WATCHDOG_STATE}" "state=monitoring"
  watchdog_started=${SECONDS}
  lock_poll_started=${SECONDS}
  lock_query_failures=0
  while kill -0 "${XCODEBUILD_PID}" 2>/dev/null; do
    if (( SECONDS - watchdog_started >= UI_TEST_TIMEOUT_SECONDS )); then
      print -r -- \
        "Timed out after ${UI_TEST_TIMEOUT_SECONDS}s while capturing the installed release baseline." \
        > "${TIMEOUT_MARKER}"
      opensteamer_terminate_isolated_process_group \
        "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
      opensteamer_write_state "${WATCHDOG_STATE}" "state=timeout-handled"
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
            "The iPhone locked while the installed release baseline UI gate was running." \
            > "${DEVICE_LOCKED_MARKER}"
          opensteamer_terminate_isolated_process_group \
            "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
          opensteamer_write_state "${WATCHDOG_STATE}" "state=device-locked-handled"
          exit 0
        fi
        lock_query_failures=$((lock_query_failures + 1))
        if (( lock_query_failures >= 2 )); then
          print -r -- \
            "The iPhone lock state could not be verified twice during the installed release baseline UI gate." \
            > "${DEVICE_UNAVAILABLE_MARKER}"
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
    "The installed release xcodebuild process group remained alive after its leader exited." \
    > "${WATCHDOG_FAILURE_MARKER}"
  opensteamer_terminate_isolated_process_group \
    "${XCODEBUILD_PID}" "${UI_TEST_TERMINATION_GRACE_SECONDS}"
fi
XCODEBUILD_PID=""
XCODEBUILD_GROUP_ISOLATED=0
if ! opensteamer_wait_for_process_exit \
    "${XCODEBUILD_WATCHDOG_PID}" "$((DEVICE_COMMAND_TIMEOUT_SECONDS + 5))"; then
  print -r -- \
    "The installed release lock watchdog did not finish after xcodebuild ended." \
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

if [[ -f "${WATCHDOG_FAILURE_MARKER}" ]]; then
  cat "${WATCHDOG_FAILURE_MARKER}" >&2
  exit 7
fi
if (( XCODEBUILD_WATCHDOG_STATUS != 0 )); then
  echo "Installed release lock watchdog failed with status ${XCODEBUILD_WATCHDOG_STATUS}." >&2
  exit 7
fi
EXPECTED_WATCHDOG_STATE="state=xcodebuild-ended"
if [[ -f "${TIMEOUT_MARKER}" ]]; then
  EXPECTED_WATCHDOG_STATE="state=timeout-handled"
elif [[ -f "${DEVICE_LOCKED_MARKER}" ]]; then
  EXPECTED_WATCHDOG_STATE="state=device-locked-handled"
elif [[ -f "${DEVICE_UNAVAILABLE_MARKER}" ]]; then
  EXPECTED_WATCHDOG_STATE="state=device-unavailable-handled"
fi
if ! grep -qx "${EXPECTED_WATCHDOG_STATE}" "${WATCHDOG_STATE}" 2>/dev/null; then
  echo "Installed release lock watchdog lifecycle evidence is incomplete; expected ${EXPECTED_WATCHDOG_STATE}." >&2
  exit 7
fi
if [[ -f "${TIMEOUT_MARKER}" ]]; then
  cat "${TIMEOUT_MARKER}" >&2
  XCODEBUILD_STATUS=124
elif [[ -f "${DEVICE_LOCKED_MARKER}" ]]; then
  cat "${DEVICE_LOCKED_MARKER}" >&2
  exit 5
elif [[ -f "${DEVICE_UNAVAILABLE_MARKER}" ]]; then
  cat "${DEVICE_UNAVAILABLE_MARKER}" >&2
  exit 6
fi
if (( XCODEBUILD_STATUS == 0 )); then
  capture_and_require_unlocked "${LOCK_STATE_AFTER_XCODEBUILD}"
fi

capture_and_validate_device "${DEVICE_AFTER}"
capture_production_installedRelease "${APP_LIST_AFTER}" "${CANDIDATE_AFTER}"
if ! cmp -s "${CANDIDATE_BEFORE}" "${CANDIDATE_AFTER}"; then
  echo "Installed release changed during baseline validation." >&2
  diff -u "${CANDIDATE_BEFORE}" "${CANDIDATE_AFTER}" >&2 || true
  exit 2
fi
if (( XCODEBUILD_STATUS != 0 )); then
  echo "Installed release baseline UI test failed with xcodebuild status ${XCODEBUILD_STATUS}." >&2
  exit "${XCODEBUILD_STATUS}"
fi

validate_xcresult

echo "Installed release device saved-pair baseline passed: ${RESULT_BUNDLE}"
opensteamer_write_state "${RUN_STATUS}" "status=passed"
RUN_SUCCEEDED=1
