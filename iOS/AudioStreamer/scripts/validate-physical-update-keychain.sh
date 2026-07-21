#!/bin/zsh

# Usage: `validate-physical-update-keychain.sh <device-udid> [artifact-directory]`.
#
# Prerequisites: an unlocked, connected test iPhone on the pinned iOS version; Xcode command-line
# tools with signing access; and permission to install/uninstall the side-by-side `.dev` bundle.
# The script proves that Keychain-backed activation/invitation state, viewer identity, and active
# paired-Mac record survive install-over-update. Separate negative phases prove startup cannot
# manufacture a deliberately missing identity or pairing record before read-only verification.
#
# Optional environment: `AUDIOSTREAMER_UPDATE_PHASE_TIMEOUT_SECONDS`,
# `AUDIOSTREAMER_DEVICE_COMMAND_TIMEOUT_SECONDS`, and `AUDIOSTREAMER_DEVICE_LOCK_POLL_SECONDS`
# adjust bounded waits. `AUDIOSTREAMER_SCRIPT_SELF_TEST` is reserved for deterministic shell tests;
# phase-selector variables are set internally and should not be supplied by an operator.
#
# Side effects/artifacts: builds and installs validation variants, uninstalls the validation app,
# and writes device/app/lock snapshots plus `.xcresult` bundles under the artifact directory
# (default `/private/tmp/AudioStreamer-device-Keychain-Update`). `run-status.txt` ends in `status=passed`
# only after every phase succeeds; any nonzero command, timeout, lock, metadata, or oracle failure
# exits nonzero and cleanup records `status=failed`. No failure is treated as a skip.
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
REPOSITORY_DIR=${PROJECT_DIR:h:h}
source "${SCRIPT_DIR}/physical-validation-helpers.zsh"
DEVICE_UDID=${1:?usage: $0 device-udid [artifact-directory]}
ARTIFACT_DIR=${2:-/private/tmp/AudioStreamer-device-Keychain-Update}
DERIVED_DATA="${ARTIFACT_DIR}/DerivedData"
SEED_RESULT="${ARTIFACT_DIR}/seed-build-2901.xcresult"
VERIFY_RESULT="${ARTIFACT_DIR}/verify-build-2902.xcresult"
MISSING_IDENTITY_SEED_RESULT="${ARTIFACT_DIR}/missing-identity-seed-build-2903.xcresult"
MISSING_IDENTITY_VERIFY_RESULT="${ARTIFACT_DIR}/missing-identity-verify-build-2904.xcresult"
MISSING_PAIR_SEED_RESULT="${ARTIFACT_DIR}/missing-pair-seed-build-2905.xcresult"
MISSING_PAIR_VERIFY_RESULT="${ARTIFACT_DIR}/missing-pair-verify-build-2906.xcresult"
EXPECTED_MODEL="test iPhone"
EXPECTED_OS="18.x"
EXPECTED_PLATFORM="iOS"
VALIDATION_BUNDLE_IDENTIFIER="org.example.AudioStreamer.dev"
DEVICE_BEFORE="${ARTIFACT_DIR}/device-before.json"
DEVICE_AFTER="${ARTIFACT_DIR}/device-after.json"
INSTALLED_APPS_BEFORE="${ARTIFACT_DIR}/installed-apps-before.json"
INSTALLED_APPS_AFTER_UNINSTALL="${ARTIFACT_DIR}/installed-apps-after-uninstall.json"
UNINSTALL_RESULT="${ARTIFACT_DIR}/validation-app-uninstall.json"
LOCK_STATE_BEFORE="${ARTIFACT_DIR}/lock-state-before.json"
LOCK_STATE_AFTER="${ARTIFACT_DIR}/lock-state-after.json"
PHASE_TIMEOUT_SECONDS=${AUDIOSTREAMER_UPDATE_PHASE_TIMEOUT_SECONDS:-900}
PHASE_TERMINATION_GRACE_SECONDS=5
DEVICE_COMMAND_TIMEOUT_SECONDS=${AUDIOSTREAMER_DEVICE_COMMAND_TIMEOUT_SECONDS:-15}
DEVICE_LOCK_POLL_SECONDS=${AUDIOSTREAMER_DEVICE_LOCK_POLL_SECONDS:-5}
RUN_STATUS="${ARTIFACT_DIR}/run-status.txt"
XCODEBUILD_PID=""
XCODEBUILD_GROUP_ISOLATED=0
WATCHDOG_PID=""
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
  if [[ -n "${WATCHDOG_PID}" ]] && kill -0 "${WATCHDOG_PID}" 2>/dev/null; then
    audiostreamer_terminate_process_tree \
      "${WATCHDOG_PID}" "${PHASE_TERMINATION_GRACE_SECONDS}"
    wait "${WATCHDOG_PID}" 2>/dev/null || true
  fi
  if [[ -n "${XCODEBUILD_PID}" ]]; then
    if (( XCODEBUILD_GROUP_ISOLATED != 0 )); then
      audiostreamer_terminate_isolated_process_group \
        "${XCODEBUILD_PID}" "${PHASE_TERMINATION_GRACE_SECONDS}"
    elif kill -0 "${XCODEBUILD_PID}" 2>/dev/null; then
      audiostreamer_terminate_process_tree \
        "${XCODEBUILD_PID}" "${PHASE_TERMINATION_GRACE_SECONDS}"
    fi
    audiostreamer_wait_for_final_process_status "${XCODEBUILD_PID}" || true
  fi
  if (( RUN_SUCCEEDED == 0 )); then
    if ! audiostreamer_write_state "${RUN_STATUS}" "status=failed"; then
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
trap audiostreamer_exit_on_interrupt INT
trap audiostreamer_exit_on_termination TERM

audiostreamer_require_positive_integer \
  AUDIOSTREAMER_UPDATE_PHASE_TIMEOUT_SECONDS \
  "${PHASE_TIMEOUT_SECONDS}"
audiostreamer_require_positive_integer \
  AUDIOSTREAMER_DEVICE_COMMAND_TIMEOUT_SECONDS \
  "${DEVICE_COMMAND_TIMEOUT_SECONDS}"
audiostreamer_require_positive_integer \
  AUDIOSTREAMER_DEVICE_LOCK_POLL_SECONDS \
  "${DEVICE_LOCK_POLL_SECONDS}"

rm -rf \
  "${DERIVED_DATA}" \
  "${SEED_RESULT}" \
  "${VERIFY_RESULT}" \
  "${MISSING_IDENTITY_SEED_RESULT}" \
  "${MISSING_IDENTITY_VERIFY_RESULT}" \
  "${MISSING_PAIR_SEED_RESULT}" \
  "${MISSING_PAIR_VERIFY_RESULT}" \
  "${DEVICE_BEFORE}" \
  "${DEVICE_AFTER}" \
  "${INSTALLED_APPS_BEFORE}" \
  "${INSTALLED_APPS_AFTER_UNINSTALL}" \
  "${UNINSTALL_RESULT}" \
  "${LOCK_STATE_BEFORE}" \
  "${LOCK_STATE_AFTER}" \
  "${ARTIFACT_DIR}/seed-lock-state-before.json" \
  "${ARTIFACT_DIR}/seed-lock-state-during.json" \
  "${ARTIFACT_DIR}/seed-timeout.txt" \
  "${ARTIFACT_DIR}/seed-device-locked.txt" \
  "${ARTIFACT_DIR}/seed-device-unavailable.txt" \
  "${ARTIFACT_DIR}/seed-watchdog-state.txt" \
  "${ARTIFACT_DIR}/seed-watchdog-failure.txt" \
  "${ARTIFACT_DIR}/seed-summary.json" \
  "${ARTIFACT_DIR}/seed-tests.json" \
  "${ARTIFACT_DIR}/seed-build-results.json" \
  "${ARTIFACT_DIR}/verify-lock-state-before.json" \
  "${ARTIFACT_DIR}/verify-lock-state-during.json" \
  "${ARTIFACT_DIR}/verify-timeout.txt" \
  "${ARTIFACT_DIR}/verify-device-locked.txt" \
  "${ARTIFACT_DIR}/verify-device-unavailable.txt" \
  "${ARTIFACT_DIR}/verify-watchdog-state.txt" \
  "${ARTIFACT_DIR}/verify-watchdog-failure.txt" \
  "${ARTIFACT_DIR}/verify-summary.json" \
  "${ARTIFACT_DIR}/verify-tests.json" \
  "${ARTIFACT_DIR}/verify-build-results.json" \
  "${ARTIFACT_DIR}/missing-identity-seed-lock-state-before.json" \
  "${ARTIFACT_DIR}/missing-identity-seed-lock-state-during.json" \
  "${ARTIFACT_DIR}/missing-identity-seed-timeout.txt" \
  "${ARTIFACT_DIR}/missing-identity-seed-device-locked.txt" \
  "${ARTIFACT_DIR}/missing-identity-seed-device-unavailable.txt" \
  "${ARTIFACT_DIR}/missing-identity-seed-watchdog-state.txt" \
  "${ARTIFACT_DIR}/missing-identity-seed-watchdog-failure.txt" \
  "${ARTIFACT_DIR}/missing-identity-seed-summary.json" \
  "${ARTIFACT_DIR}/missing-identity-seed-tests.json" \
  "${ARTIFACT_DIR}/missing-identity-seed-build-results.json" \
  "${ARTIFACT_DIR}/missing-identity-verify-lock-state-before.json" \
  "${ARTIFACT_DIR}/missing-identity-verify-lock-state-during.json" \
  "${ARTIFACT_DIR}/missing-identity-verify-timeout.txt" \
  "${ARTIFACT_DIR}/missing-identity-verify-device-locked.txt" \
  "${ARTIFACT_DIR}/missing-identity-verify-device-unavailable.txt" \
  "${ARTIFACT_DIR}/missing-identity-verify-watchdog-state.txt" \
  "${ARTIFACT_DIR}/missing-identity-verify-watchdog-failure.txt" \
  "${ARTIFACT_DIR}/missing-identity-verify-summary.json" \
  "${ARTIFACT_DIR}/missing-identity-verify-tests.json" \
  "${ARTIFACT_DIR}/missing-identity-verify-build-results.json" \
  "${ARTIFACT_DIR}/missing-pair-seed-lock-state-before.json" \
  "${ARTIFACT_DIR}/missing-pair-seed-lock-state-during.json" \
  "${ARTIFACT_DIR}/missing-pair-seed-timeout.txt" \
  "${ARTIFACT_DIR}/missing-pair-seed-device-locked.txt" \
  "${ARTIFACT_DIR}/missing-pair-seed-device-unavailable.txt" \
  "${ARTIFACT_DIR}/missing-pair-seed-watchdog-state.txt" \
  "${ARTIFACT_DIR}/missing-pair-seed-watchdog-failure.txt" \
  "${ARTIFACT_DIR}/missing-pair-seed-summary.json" \
  "${ARTIFACT_DIR}/missing-pair-seed-tests.json" \
  "${ARTIFACT_DIR}/missing-pair-seed-build-results.json" \
  "${ARTIFACT_DIR}/missing-pair-verify-lock-state-before.json" \
  "${ARTIFACT_DIR}/missing-pair-verify-lock-state-during.json" \
  "${ARTIFACT_DIR}/missing-pair-verify-timeout.txt" \
  "${ARTIFACT_DIR}/missing-pair-verify-device-locked.txt" \
  "${ARTIFACT_DIR}/missing-pair-verify-device-unavailable.txt" \
  "${ARTIFACT_DIR}/missing-pair-verify-watchdog-state.txt" \
  "${ARTIFACT_DIR}/missing-pair-verify-watchdog-failure.txt" \
  "${ARTIFACT_DIR}/missing-pair-verify-summary.json" \
  "${ARTIFACT_DIR}/missing-pair-verify-tests.json" \
  "${ARTIFACT_DIR}/missing-pair-verify-build-results.json" \
  "${ARTIFACT_DIR}/fast-group-leader-pid.txt" \
  "${ARTIFACT_DIR}/fast-group-child-pid.txt"

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
  local gate_name=$2
  audiostreamer_require_device_unlocked \
    "${DEVICE_UDID}" \
    "${DEVICE_COMMAND_TIMEOUT_SECONDS}" \
    "${output}" \
    "${gate_name}"
}

function remove_existing_validation_app() {
  xcrun devicectl device info apps \
    --device "${DEVICE_UDID}" \
    --timeout "${DEVICE_COMMAND_TIMEOUT_SECONDS}" \
    --json-output "${INSTALLED_APPS_BEFORE}" >/dev/null
  jq -e '.info.outcome == "success" and (.result.apps | type == "array")' \
    "${INSTALLED_APPS_BEFORE}" >/dev/null

  if jq -e --arg bundle "${VALIDATION_BUNDLE_IDENTIFIER}" \
      '.result.apps | any(.bundleIdentifier == $bundle)' \
      "${INSTALLED_APPS_BEFORE}" >/dev/null; then
    # Xcode can restore a previously installed debug app after an application-hosted test.
    # Remove it before seeding so only the inert validation build can run between phases.
    xcrun devicectl device uninstall app \
      --device "${DEVICE_UDID}" \
      --timeout "${DEVICE_COMMAND_TIMEOUT_SECONDS}" \
      --json-output "${UNINSTALL_RESULT}" \
      "${VALIDATION_BUNDLE_IDENTIFIER}" >/dev/null
    jq -e '.info.outcome == "success"' "${UNINSTALL_RESULT}" >/dev/null
  fi

  xcrun devicectl device info apps \
    --device "${DEVICE_UDID}" \
    --timeout "${DEVICE_COMMAND_TIMEOUT_SECONDS}" \
    --json-output "${INSTALLED_APPS_AFTER_UNINSTALL}" >/dev/null
  jq -e --arg bundle "${VALIDATION_BUNDLE_IDENTIFIER}" '
    (.info.outcome == "success") and
    (.result.apps | type == "array") and
    (.result.apps | all(.bundleIdentifier != $bundle))
  ' "${INSTALLED_APPS_AFTER_UNINSTALL}" >/dev/null
}

function validate_xcresult() {
  local phase=$1
  local result_bundle=$2
  local expected_test_name=$3
  local expected_node_identifier="KeychainStoreTests/${expected_test_name}()"
  # xcresult's display identifier includes `()`, while its canonical test URL does not.
  local expected_identifier_url="test://com.apple.xcode/AudioStreamer/AudioStreamerTests/KeychainStoreTests/${expected_test_name}"
  local summary
  local tests
  local build_results

  summary=$(xcrun xcresulttool get test-results summary \
    --path "${result_bundle}" \
    --compact)
  tests=$(xcrun xcresulttool get test-results tests \
    --path "${result_bundle}" \
    --compact)
  build_results=$(xcrun xcresulttool get build-results \
    --path "${result_bundle}" \
    --compact)
  print -r -- "${summary}" > "${ARTIFACT_DIR}/${phase}-summary.json"
  print -r -- "${tests}" > "${ARTIFACT_DIR}/${phase}-tests.json"
  print -r -- "${build_results}" > "${ARTIFACT_DIR}/${phase}-build-results.json"

  # Test totals alone can produce false evidence when Xcode ran the right count on the wrong
  # destination or selected a similarly named method. Require the exact case identity and device.
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
    --arg node "${expected_node_identifier}" \
    --arg url "${expected_identifier_url}" '
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

  # Treat warnings and analyzer diagnostics as aggregate evidence issues, not harmless noise.
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
    (.actionTitle == "Testing project AudioStreamer with scheme AudioStreamer") and
    (.destination.deviceId == $udid) and
    (.destination.modelName == $model) and
    (.destination.osVersion == $os) and
    (.destination.platform == $platform)
  ' <<<"${build_results}" >/dev/null
}

function run_phase() {
  local phase=$1
  local condition=$2
  local test_name=$3
  local build_number=$4
  local result_bundle=$5
  local timeout_marker="${ARTIFACT_DIR}/${phase}-timeout.txt"
  local locked_marker="${ARTIFACT_DIR}/${phase}-device-locked.txt"
  local unavailable_marker="${ARTIFACT_DIR}/${phase}-device-unavailable.txt"
  local lock_state_before="${ARTIFACT_DIR}/${phase}-lock-state-before.json"
  local lock_state_during="${ARTIFACT_DIR}/${phase}-lock-state-during.json"
  local watchdog_state="${ARTIFACT_DIR}/${phase}-watchdog-state.txt"
  local watchdog_failure_marker="${ARTIFACT_DIR}/${phase}-watchdog-failure.txt"
  local xcodebuild_status
  local watchdog_status
  local expected_watchdog_state

  echo "Running ${phase} on physical device ${DEVICE_UDID}..."
  rm -f \
    "${timeout_marker}" \
    "${locked_marker}" \
    "${unavailable_marker}" \
    "${lock_state_before}" \
    "${lock_state_during}" \
    "${watchdog_state}" \
    "${watchdog_failure_marker}"
  capture_and_require_unlocked \
    "${lock_state_before}" \
    "physical ${phase} update validation"
  audiostreamer_start_isolated_validation_process xcodebuild test \
    -project "${PROJECT_DIR}/AudioStreamer.xcodeproj" \
    -scheme AudioStreamer \
    -configuration Debug \
    -destination "platform=iOS,id=${DEVICE_UDID}" \
    -derivedDataPath "${DERIVED_DATA}" \
    -parallel-testing-enabled NO \
    -maximum-parallel-testing-workers 1 \
    -only-testing:"AudioStreamerTests/KeychainStoreTests/${test_name}" \
    -resultBundlePath "${result_bundle}" \
    CURRENT_PROJECT_VERSION="${build_number}" \
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG AUDIOSTREAMER_UPDATE_VALIDATION_HOST ${condition}"
  (
    set -e
    audiostreamer_write_state "${watchdog_state}" "state=monitoring"
    watchdog_started=${SECONDS}
    lock_poll_started=${SECONDS}
    lock_query_failures=0
    while kill -0 "${XCODEBUILD_PID}" 2>/dev/null; do
      if (( SECONDS - watchdog_started >= PHASE_TIMEOUT_SECONDS )); then
        print -r -- \
          "Timed out after ${PHASE_TIMEOUT_SECONDS}s during physical ${phase} validation." \
          > "${timeout_marker}"
        audiostreamer_terminate_isolated_process_group \
          "${XCODEBUILD_PID}" "${PHASE_TERMINATION_GRACE_SECONDS}"
        audiostreamer_write_state "${watchdog_state}" "state=timeout-handled"
        exit 0
      fi
      if (( SECONDS - lock_poll_started >= DEVICE_LOCK_POLL_SECONDS )); then
        lock_poll_started=${SECONDS}
        if audiostreamer_device_is_unlocked \
            "${DEVICE_UDID}" \
            "${DEVICE_COMMAND_TIMEOUT_SECONDS}" \
            "${lock_state_during}"; then
          lock_query_failures=0
        else
          lock_result=$?
          if (( lock_result == 5 )); then
            print -r -- \
              "The iPhone locked during physical ${phase} update validation." \
              > "${locked_marker}"
            audiostreamer_terminate_isolated_process_group \
              "${XCODEBUILD_PID}" "${PHASE_TERMINATION_GRACE_SECONDS}"
            audiostreamer_write_state "${watchdog_state}" "state=device-locked-handled"
            exit 0
          fi
          lock_query_failures=$((lock_query_failures + 1))
          if (( lock_query_failures >= 2 )); then
            print -r -- \
              "The iPhone lock state could not be verified twice during physical ${phase} update validation." \
              > "${unavailable_marker}"
            audiostreamer_terminate_isolated_process_group \
              "${XCODEBUILD_PID}" "${PHASE_TERMINATION_GRACE_SECONDS}"
            audiostreamer_write_state "${watchdog_state}" "state=device-unavailable-handled"
            exit 0
          fi
        fi
      fi
      sleep 1
    done
    audiostreamer_write_state "${watchdog_state}" "state=xcodebuild-ended"
  ) &
  WATCHDOG_PID=$!
  audiostreamer_wait_for_final_process_status "${XCODEBUILD_PID}"
  xcodebuild_status=${AUDIOSTREAMER_FINAL_PROCESS_STATUS}
  if ! audiostreamer_wait_for_process_group_exit "${XCODEBUILD_PID}" 2; then
    print -r -- \
      "The physical ${phase} xcodebuild process group remained alive after its leader exited." \
      > "${watchdog_failure_marker}"
    audiostreamer_terminate_isolated_process_group \
      "${XCODEBUILD_PID}" "${PHASE_TERMINATION_GRACE_SECONDS}"
  fi
  XCODEBUILD_PID=""
  XCODEBUILD_GROUP_ISOLATED=0
  if ! audiostreamer_wait_for_process_exit \
      "${WATCHDOG_PID}" "$((DEVICE_COMMAND_TIMEOUT_SECONDS + 5))"; then
    print -r -- \
      "The device lock watchdog did not finish after physical ${phase} xcodebuild ended." \
      > "${watchdog_failure_marker}"
    audiostreamer_terminate_process_tree \
      "${WATCHDOG_PID}" "${PHASE_TERMINATION_GRACE_SECONDS}"
  fi
  if wait "${WATCHDOG_PID}" 2>/dev/null; then
    watchdog_status=0
  else
    watchdog_status=$?
  fi
  WATCHDOG_PID=""

  if [[ -f "${watchdog_failure_marker}" ]]; then
    cat "${watchdog_failure_marker}" >&2
    return 7
  fi
  if (( watchdog_status != 0 )); then
    echo "Physical ${phase} lock watchdog failed with status ${watchdog_status}." >&2
    return 7
  fi
  expected_watchdog_state="state=xcodebuild-ended"
  if [[ -f "${timeout_marker}" ]]; then
    expected_watchdog_state="state=timeout-handled"
  elif [[ -f "${locked_marker}" ]]; then
    expected_watchdog_state="state=device-locked-handled"
  elif [[ -f "${unavailable_marker}" ]]; then
    expected_watchdog_state="state=device-unavailable-handled"
  fi
  if ! grep -qx "${expected_watchdog_state}" "${watchdog_state}" 2>/dev/null; then
    echo "Physical ${phase} lock watchdog lifecycle evidence is incomplete; expected ${expected_watchdog_state}." >&2
    return 7
  fi
  if [[ -f "${timeout_marker}" ]]; then
    cat "${timeout_marker}" >&2
    return 124
  elif [[ -f "${locked_marker}" ]]; then
    cat "${locked_marker}" >&2
    return 5
  elif [[ -f "${unavailable_marker}" ]]; then
    cat "${unavailable_marker}" >&2
    return 6
  fi
  if (( xcodebuild_status != 0 )); then
    echo "Physical ${phase} validation failed with xcodebuild status ${xcodebuild_status}." >&2
    return "${xcodebuild_status}"
  fi

  validate_xcresult "${phase}" "${result_bundle}" "${test_name}"
}

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

cd "${REPOSITORY_DIR}"
capture_and_validate_device "${DEVICE_BEFORE}"
capture_and_require_unlocked \
  "${LOCK_STATE_BEFORE}" \
  "physical update validation"
remove_existing_validation_app
run_phase \
  seed \
  AUDIOSTREAMER_UPDATE_SEED \
  testSeedStableItemsForPhysicalUpdateValidation \
  2901 \
  "${SEED_RESULT}"
run_phase \
  verify \
  AUDIOSTREAMER_UPDATE_VERIFY \
  testStableItemsSurvivePhysicalUpdate \
  2902 \
  "${VERIFY_RESULT}"
run_phase \
  missing-identity-seed \
  AUDIOSTREAMER_UPDATE_MISSING_IDENTITY_SEED \
  testSeedMissingIdentityForPhysicalUpdateValidation \
  2903 \
  "${MISSING_IDENTITY_SEED_RESULT}"
run_phase \
  missing-identity-verify \
  AUDIOSTREAMER_UPDATE_MISSING_IDENTITY_VERIFY \
  testVerifyHostDoesNotCreateMissingIdentity \
  2904 \
  "${MISSING_IDENTITY_VERIFY_RESULT}"
run_phase \
  missing-pair-seed \
  AUDIOSTREAMER_UPDATE_MISSING_PAIR_SEED \
  testSeedMissingPairedMacForPhysicalUpdateValidation \
  2905 \
  "${MISSING_PAIR_SEED_RESULT}"
run_phase \
  missing-pair-verify \
  AUDIOSTREAMER_UPDATE_MISSING_PAIR_VERIFY \
  testVerifyHostDoesNotCreateMissingPairedMac \
  2906 \
  "${MISSING_PAIR_VERIFY_RESULT}"
capture_and_validate_device "${DEVICE_AFTER}"
capture_and_require_unlocked \
  "${LOCK_STATE_AFTER}" \
  "completed physical update validation"

echo "Physical cross-process update and missing-credential validation passed."
echo "Seed result: ${SEED_RESULT}"
echo "Verify result: ${VERIFY_RESULT}"
echo "Missing identity seed result: ${MISSING_IDENTITY_SEED_RESULT}"
echo "Missing identity verify result: ${MISSING_IDENTITY_VERIFY_RESULT}"
echo "Missing paired Mac seed result: ${MISSING_PAIR_SEED_RESULT}"
echo "Missing paired Mac verify result: ${MISSING_PAIR_VERIFY_RESULT}"
audiostreamer_write_state "${RUN_STATUS}" "status=passed"
RUN_SUCCEEDED=1
