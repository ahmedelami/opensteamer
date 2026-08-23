#!/bin/zsh

# Shared runtime primitives for the physical-device release gates.
#
# Usage: source this file from a strict-mode zsh driver; it is not a standalone command. Keep
# functions free of top-level side effects so production drivers and shell regression tests can
# safely share them. Callers need the run-pinned Rust oracle selected by
# `OPENSTEAMER_PHYSICAL_VALIDATION_ORACLE`, macOS system tools used by the selected helper
# (`xcrun devicectl`, `launchctl`, `shasum`, and process utilities), and permission to inspect the
# target device or host service.
#
# Test-only environment: `OPENSTEAMER_SCRIPT_SELF_TEST` unlocks deterministic seams. The
# `OPENSTEAMER_LOG_SNAPSHOT_TEST_*` variables coordinate the log-snapshot race harness; ordinary
# release runs must leave them unset. Selected functions export `OPENSTEAMER_LOG_SNAPSHOT_*`,
# `OPENSTEAMER_FINAL_PROCESS_STATUS`, and audited connection counts for their caller.
#
# Side effects are function-specific and explicit: helpers may create caller-supplied artifact
# files, signal owned process trees, or query an attached device. A nonzero return always means the
# requested invariant was not established; helpers do not convert a failed proof into a skip.

function opensteamer_run_physical_validation_oracle() {
  local oracle=${OPENSTEAMER_PHYSICAL_VALIDATION_ORACLE:-}
  local expected_metadata

  if [[ -z "${oracle}" || "${oracle}" != /Volumes/t7/* \
      || ! -f "${oracle}" || -L "${oracle}" || ! -x "${oracle}" ]]; then
    echo "The run-pinned Rust physical-validation oracle is unavailable or unsafe." >&2
    return 127
  fi
  expected_metadata="$(/usr/bin/id -u):1:500"
  if [[ "$(/usr/bin/stat -f '%u:%l:%Lp' "${oracle}" 2>/dev/null)" \
      != "${expected_metadata}" ]]; then
    echo "The run-pinned Rust physical-validation oracle metadata changed." >&2
    return 127
  fi
  "${oracle}" "$@"
}

function opensteamer_require_positive_integer() {
  local setting_name=$1
  local setting_value=$2
  if [[ -z "${setting_value}" || "${setting_value}" == *[^0-9]* ]] \
      || (( setting_value <= 0 )); then
    echo "${setting_name} must be a positive integer, got '${setting_value}'." >&2
    return 2
  fi
}

function opensteamer_connected_host_pid_from_log_line() {
  local log_line=$1
  local prefix="Worldwide WebRTC peer state: connected pid="
  local process_id

  [[ "${log_line}" == *"${prefix}"* ]] || return 1
  process_id=${log_line#*${prefix}}
  [[ "${process_id}" != *"${prefix}"* ]] || return 1
  if [[ -z "${process_id}" || "${process_id}" == *[^0-9]* ]] \
      || (( process_id <= 0 )); then
    return 1
  fi
  print -r -- "${process_id}"
}

function opensteamer_require_same_host_process() {
  local logged_process_id=$1
  local expected_process_id=$2
  local current_process_id=$3
  local process_id

  for process_id in \
      "${logged_process_id}" "${expected_process_id}" "${current_process_id}"; do
    if [[ -z "${process_id}" || "${process_id}" == *[^0-9]* ]]; then
      return 1
    fi
    (( process_id > 0 )) || return 1
  done
  [[ "${logged_process_id}" == "${expected_process_id}" \
      && "${logged_process_id}" == "${current_process_id}" ]]
}

function opensteamer_empty_sha256() {
  print -r -- "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
}

# Capture one coherent prefix of an append-only log through a single opened descriptor. The
# caller retains the returned byte offset and digest; every later capture rereads and authenticates
# that consumed prefix before returning new bytes. This detects in-place rewrite/truncate-refill as
# well as path replacement, and avoids mixing independent stat/wc/sed observations.
function opensteamer_capture_log_snapshot() {
  local log_path=$1
  local expected_identity=$2
  local prior_offset=$3
  local prior_digest=$4
  local appended_output=$5
  local metadata
  local -a metadata_lines

  rm -f "${appended_output}"
  if ! metadata=$(opensteamer_run_physical_validation_oracle \
      log-snapshot \
      "${log_path}" \
      "${expected_identity:--}" \
      "${prior_offset}" \
      "${prior_digest}" \
      "${appended_output}"); then
    rm -f "${appended_output}"
    return 1
  fi

  metadata_lines=("${(@f)metadata}")
  if (( ${#metadata_lines[@]} != 4 )) \
      || [[ -z "${metadata_lines[1]}" \
          || "${metadata_lines[2]}" == *[^0-9]* \
          || "${metadata_lines[3]}" == *[^0-9a-f]* \
          || ${#metadata_lines[3]} != 64 \
          || ( "${metadata_lines[4]}" != "0" && "${metadata_lines[4]}" != "1" ) ]]; then
    rm -f "${appended_output}"
    return 1
  fi

  OPENSTEAMER_LOG_SNAPSHOT_ID=${metadata_lines[1]}
  OPENSTEAMER_LOG_SNAPSHOT_OFFSET=${metadata_lines[2]}
  OPENSTEAMER_LOG_SNAPSHOT_DIGEST=${metadata_lines[3]}
  OPENSTEAMER_LOG_SNAPSHOT_ENDS_WITH_NEWLINE=${metadata_lines[4]}
}

# Preserve an incomplete trailing record between snapshots and expose only newline-terminated
# records to the PID auditor. Both outputs are replaced atomically after the split is complete.
function opensteamer_split_completed_log_lines() {
  local appended_input=$1
  local partial_state=$2
  local completed_output=$3

  opensteamer_run_physical_validation_oracle \
    split-lines "${appended_input}" "${partial_state}" "${completed_output}"
}

# Validate every completed connected record in one snapshot. A single malformed or stale PID makes
# the whole batch fail; callers may advance their byte cursor only after this function succeeds.
function opensteamer_audit_connected_log_lines() {
  local completed_input=$1
  local expected_process_id=$2
  local current_process_id=$3
  local line
  local logged_process_id
  local audited_connections=0

  if ! opensteamer_require_same_host_process \
      "${expected_process_id}" "${expected_process_id}" "${current_process_id}"; then
    return 1
  fi
  while IFS= read -r line; do
    if [[ "${line}" != *"Worldwide WebRTC peer state: connected pid="* ]]; then
      continue
    fi
    if ! logged_process_id=$(opensteamer_connected_host_pid_from_log_line \
        "${line}"); then
      return 1
    fi
    if ! opensteamer_require_same_host_process \
        "${logged_process_id}" "${expected_process_id}" "${current_process_id}"; then
      return 1
    fi
    audited_connections=$((audited_connections + 1))
  done < "${completed_input}"
  OPENSTEAMER_AUDITED_CONNECTION_COUNT=${audited_connections}
}

function opensteamer_exit_on_interrupt() {
  trap - INT TERM
  exit 130
}

function opensteamer_exit_on_termination() {
  trap - INT TERM
  exit 143
}

function opensteamer_write_state() {
  local output=$1
  local value=$2
  local temporary_output="${output}.tmp.$$"

  print -r -- "${value}" > "${temporary_output}"
  mv "${temporary_output}" "${output}"
}

function opensteamer_wait_for_process_exit() {
  local process_pid=$1
  local timeout_seconds=$2
  local wait_started=${SECONDS}

  while kill -0 "${process_pid}" 2>/dev/null; do
    if (( SECONDS - wait_started >= timeout_seconds )); then
      return 1
    fi
    sleep 0.1
  done
}

# zsh queues STOP and CONT notifications for `wait <pid>` ahead of the child's eventual status.
# Drain the queue until zsh reports no remaining child (127), retaining the last observed status.
# A direct exit 127 remains failure even though zsh cannot distinguish it from no-child afterward.
function opensteamer_wait_for_final_process_status() {
  local process_pid=$1
  local final_status=127
  local observed_status

  while true; do
    if wait "${process_pid}" 2>/dev/null; then
      observed_status=0
    else
      observed_status=$?
    fi
    if (( observed_status == 127 )); then
      OPENSTEAMER_FINAL_PROCESS_STATUS=${final_status}
      return 0
    fi
    final_status=${observed_status}
  done
}

# Never enter zsh's blocking `wait` while an isolated wrapper can still be stopped or wedged. Poll
# the whole group against one absolute monotonic deadline; only drain zsh's queued child statuses
# after ESRCH proves the group absent. At the deadline, terminate and re-prove absence before drain.
function opensteamer_wait_for_final_group_status_until() {
  local process_pid=$1
  local deadline_ns=$2
  local termination_grace_seconds=$3
  local now_ns

  [[ -n "${process_pid}" && "${process_pid}" != *[^0-9]* \
      && -n "${deadline_ns}" && "${deadline_ns}" != *[^0-9]* \
      && -n "${termination_grace_seconds}" \
      && "${termination_grace_seconds}" != *[^0-9]* ]] || return 2
  (( process_pid > 0 && deadline_ns > 0 && termination_grace_seconds > 0 )) \
    || return 2

  while true; do
    now_ns=$(opensteamer_run_physical_validation_oracle monotonic-ns) || return $?
    [[ -n "${now_ns}" && "${now_ns}" != *[^0-9]* ]] || return 125
    if (( now_ns >= deadline_ns )); then
      if ! opensteamer_terminate_isolated_process_group \
          "${process_pid}" "${termination_grace_seconds}"; then
        return 125
      fi
      if opensteamer_process_group_exists "${process_pid}"; then
        return 125
      fi
      opensteamer_wait_for_final_process_status "${process_pid}" || return $?
      return 124
    fi
    if opensteamer_process_group_exists "${process_pid}"; then
      [[ "${OPENSTEAMER_PROCESS_GROUP_STATE}" != "indeterminate" ]] || return 125
      sleep 0.05
      continue
    fi
    opensteamer_wait_for_final_process_status "${process_pid}"
    return $?
  done
}

# Run a small critical-section command with a hard wall-clock bound and kill its whole subprocess
# group on timeout. This prevents a wedged system command from indefinitely holding a driver lock.
function opensteamer_run_with_timeout() {
  local timeout_seconds=$1
  shift
  opensteamer_run_physical_validation_oracle \
    run-timeout "${timeout_seconds}" "$@"
}

# The background function is replaced by the Rust oracle and then the requested executable, preserving
# `$!` as a dedicated session/process-group leader that the parent can safely signal as a unit.
function opensteamer_exec_in_isolated_process_group() {
  local oracle=${OPENSTEAMER_PHYSICAL_VALIDATION_ORACLE:-}

  if [[ -z "${oracle}" || "${oracle}" != /Volumes/t7/* \
      || ! -f "${oracle}" || -L "${oracle}" || ! -x "${oracle}" \
      || "$(/usr/bin/stat -f '%u:%l:%Lp' "${oracle}" 2>/dev/null)" \
        != "$(/usr/bin/id -u):1:500" ]]; then
    echo "The run-pinned Rust physical-validation oracle is unavailable or unsafe." >&2
    return 127
  fi
  exec "${oracle}" isolated-exec "$@"
}

# Driver globals are intentional here: setting the cleanup flag immediately after `$!` closes the
# fast-leader race in which the leader exits before process-group verification can observe it.
function opensteamer_start_isolated_validation_process() {
  opensteamer_exec_in_isolated_process_group "$@" &
  XCODEBUILD_PID=$!
  XCODEBUILD_GROUP_ISOLATED=1
  if [[ "${OPENSTEAMER_SCRIPT_SELF_TEST:-}" == "fast-group-failure" ]]; then
    print -r -- "${XCODEBUILD_PID}" > "${ARTIFACT_DIR}/fast-group-leader-pid.txt"
    sleep 0.2
  fi
  opensteamer_require_isolated_process_group "${XCODEBUILD_PID}" 5
}

function opensteamer_require_isolated_process_group() {
  local leader_pid=$1
  local wait_started=${SECONDS}
  local timeout_seconds=$2
  local process_group

  while (( SECONDS - wait_started < timeout_seconds )); do
    process_group=$(ps -o pgid= -p "${leader_pid}" 2>/dev/null \
      | tr -d '[:space:]' || true)
    if [[ "${process_group}" == "${leader_pid}" ]]; then
      return 0
    fi
    if ! kill -0 "${leader_pid}" 2>/dev/null; then
      return 8
    fi
    sleep 0.02
  done
  echo "Process ${leader_pid} did not become an isolated process-group leader." >&2
  return 8
}

# Some launch wrappers deliberately stop themselves before `exec` so the caller can finish
# publishing their PID and evidence paths before any child code runs. Merely observing the new
# process group is not enough: a SIGCONT sent before the wrapper reaches SIGSTOP is lost and leaves
# the wrapper stopped forever. Wait for the already-requested stop without sending another STOP,
# then let the caller issue exactly one matching resume.
function opensteamer_wait_for_stopped_process_group() {
  local leader_pid=$1
  local timeout_seconds=$2
  local process_group
  local process_state
  local wait_started=${SECONDS}

  while (( SECONDS - wait_started < timeout_seconds )); do
    process_group=$(ps -o pgid= -p "${leader_pid}" 2>/dev/null \
      | tr -d '[:space:]' || true)
    process_state=$(ps -o state= -p "${leader_pid}" 2>/dev/null \
      | tr -d '[:space:]' || true)
    if [[ "${process_group}" == "${leader_pid}" \
        && "${process_state}" == T* ]]; then
      return 0
    fi
    if [[ -z "${process_group}" || -z "${process_state}" ]] \
        || ! kill -0 "${leader_pid}" 2>/dev/null; then
      return 8
    fi
    sleep 0.02
  done
  return 8
}

function opensteamer_process_group_exists() {
  local leader_pid=$1
  local group_state
  local probe_status

  OPENSTEAMER_PROCESS_GROUP_STATE=indeterminate
  if group_state=$(opensteamer_run_physical_validation_oracle \
      process-group-state "${leader_pid}" 2>/dev/null); then
    [[ "${group_state}" == "exists" ]] || return 125
    OPENSTEAMER_PROCESS_GROUP_STATE=exists
    return 0
  else
    probe_status=$?
  fi
  if (( probe_status == 1 )) && [[ "${group_state}" == "absent" ]]; then
    OPENSTEAMER_PROCESS_GROUP_STATE=absent
    return 1
  fi
  # Permission denial or any unclassified probe failure is not absence. Return true so ordinary
  # boolean callers fail closed, while the exported state lets cleanup/wait callers report 125.
  echo "Process-group absence for ${leader_pid} could not be proven by ESRCH." >&2
  return 0
}

function opensteamer_wait_for_process_group_exit() {
  local leader_pid=$1
  local timeout_seconds=$2
  local wait_started=${SECONDS}

  while opensteamer_process_group_exists "${leader_pid}"; do
    if [[ "${OPENSTEAMER_PROCESS_GROUP_STATE}" == "indeterminate" ]]; then
      return 125
    fi
    if (( SECONDS - wait_started >= timeout_seconds )); then
      return 1
    fi
    sleep 0.1
  done
}

# SIGSTOP closes the liveness check/use race around destructive validation actions. Once the
# isolated group leader is observably stopped, it cannot exit between the driver's final check and
# the host restart. Every successful call must be paired with `opensteamer_resume_process_group`.
function opensteamer_suspend_isolated_process_group() {
  local leader_pid=$1
  local timeout_seconds=$2
  local process_group
  local process_state
  local wait_started=${SECONDS}

  process_group=$(ps -o pgid= -p "${leader_pid}" 2>/dev/null \
    | tr -d '[:space:]' || true)
  if [[ -z "${process_group}" || "${process_group}" != "${leader_pid}" ]]; then
    return 8
  fi
  if ! kill -STOP -- "-${leader_pid}" 2>/dev/null; then
    return 8
  fi

  while (( SECONDS - wait_started < timeout_seconds )); do
    process_state=$(ps -o state= -p "${leader_pid}" 2>/dev/null \
      | tr -d '[:space:]' || true)
    if [[ "${process_state}" == T* ]]; then
      return 0
    fi
    if [[ -z "${process_state}" ]] || ! kill -0 "${leader_pid}" 2>/dev/null; then
      kill -CONT -- "-${leader_pid}" 2>/dev/null || true
      return 8
    fi
    sleep 0.02
  done

  kill -CONT -- "-${leader_pid}" 2>/dev/null || true
  return 8
}

function opensteamer_resume_process_group() {
  local leader_pid=$1
  kill -CONT -- "-${leader_pid}" 2>/dev/null
}

# Unlike ancestry rescans, a process group retains children that a terminating parent reparents.
# SIGKILL is delivered to the whole group at one kernel boundary, so TERM handlers cannot create a
# last-moment orphan outside the fallback snapshot.
function opensteamer_terminate_isolated_process_group() {
  local leader_pid=$1
  local grace_seconds=$2
  local process_group
  local grace_started

  if kill -0 "${leader_pid}" 2>/dev/null; then
    process_group=$(ps -o pgid= -p "${leader_pid}" 2>/dev/null \
      | tr -d '[:space:]' || true)
    if [[ -n "${process_group}" && "${process_group}" != "${leader_pid}" ]]; then
      echo "Refusing group signal: ${leader_pid} is not its process-group leader." >&2
      opensteamer_terminate_process_tree "${leader_pid}" "${grace_seconds}"
      return
    fi
  fi

  # Queue TERM before CONT so a deliberately stopped validation group can run its termination
  # handlers without receiving any unsignalled execution window.
  kill -TERM -- "-${leader_pid}" 2>/dev/null || true
  kill -CONT -- "-${leader_pid}" 2>/dev/null || true
  grace_started=${SECONDS}
  while opensteamer_process_group_exists "${leader_pid}" \
      && [[ "${OPENSTEAMER_PROCESS_GROUP_STATE}" != "indeterminate" ]] \
      && (( SECONDS - grace_started < grace_seconds )); do
    sleep 0.2
  done
  # KILL is unconditional and the stable group handle is retained for one bounded re-sweep.
  kill -KILL -- "-${leader_pid}" 2>/dev/null || true
  if opensteamer_wait_for_process_group_exit "${leader_pid}" 1; then
    return 0
  fi
  kill -KILL -- "-${leader_pid}" 2>/dev/null || true
  if opensteamer_wait_for_process_group_exit "${leader_pid}" 1; then
    return 0
  fi
  echo "Process group ${leader_pid} survived or could not prove absence after repeated KILL." >&2
  return 125
}

# Require the exact public iPhone XR release tuple while keeping the CoreDevice selector and the
# hardware UDID in their distinct namespaces. This helper only validates a caller-owned snapshot.
function opensteamer_require_physical_iphone_xr_details() {
  local output=$1
  local coredevice_identifier=$2
  local hardware_udid=$3

  jq -e \
    --arg coredevice_identifier "${coredevice_identifier}" \
    --arg hardware_udid "${hardware_udid}" '
    (.info.outcome == "success") and
    (.result.identifier == $coredevice_identifier) and
    (.result.hardwareProperties.udid == $hardware_udid) and
    (.result.hardwareProperties.marketingName == "iPhone XR") and
    (.result.hardwareProperties.productType == "iPhone11,8") and
    (.result.hardwareProperties.hardwareModel == "N841AP") and
    (.result.hardwareProperties.platform == "iOS") and
    (.result.hardwareProperties.reality == "physical") and
    (.result.deviceProperties.osVersionNumber == "18.7.9") and
    (.result.deviceProperties.osBuildUpdate == "22H355") and
    (.result.deviceProperties.bootState == "booted") and
    (.result.connectionProperties.pairingState == "paired")
  ' "${output}" >/dev/null
}

# Returns 0 only for a successful, explicitly unlocked response; 5 means the device is locked,
# and 6 means its state could not be established within the bounded devicectl call.
function opensteamer_device_is_unlocked() {
  local coredevice_identifier=$1
  local command_timeout_seconds=$2
  local output=$3

  rm -f "${output}"
  if ! xcrun devicectl device info lockState \
      --device "${coredevice_identifier}" \
      --timeout "${command_timeout_seconds}" \
      --json-output "${output}" >/dev/null 2>&1; then
    return 6
  fi
  if jq -e '
    (.info.outcome == "success") and
    (.result.passcodeRequired == false)
  ' "${output}" >/dev/null 2>&1; then
    return 0
  fi
  if jq -e '
    (.info.outcome == "success") and
    (.result.passcodeRequired == true)
  ' "${output}" >/dev/null 2>&1; then
    return 5
  fi
  return 6
}

function opensteamer_require_device_unlocked() {
  local coredevice_identifier=$1
  local command_timeout_seconds=$2
  local output=$3
  local gate_name=$4
  local lock_result

  if opensteamer_device_is_unlocked \
      "${coredevice_identifier}" "${command_timeout_seconds}" "${output}"; then
    return 0
  else
    lock_result=$?
  fi

  if (( lock_result == 5 )); then
    echo "Refusing ${gate_name}: unlock the iPhone and leave it awake." >&2
    return 5
  fi
  echo "Refusing ${gate_name}: the iPhone lock state could not be verified." >&2
  return 6
}

function opensteamer_descendant_pids() {
  local parent_pid=$1
  local child_pid
  local children

  children=$(pgrep -P "${parent_pid}" 2>/dev/null || true)
  for child_pid in ${(f)children}; do
    opensteamer_descendant_pids "${child_pid}"
    print -r -- "${child_pid}"
  done
}

# Freeze every surviving PID we have observed, then recursively rescan from each one. Retaining
# those anchors matters when the original root exits during grace and its children are reparented.
function opensteamer_freeze_process_forest() {
  local descendant_pid
  local descendant_text
  local known_pid
  local stable_scans=0
  local scan
  local added
  local -a known_pids
  local -A seen_pids

  for known_pid in "$@"; do
    [[ -n "${known_pid}" ]] || continue
    if [[ -z "${seen_pids[${known_pid}]-}" ]]; then
      seen_pids[${known_pid}]=1
      known_pids+=("${known_pid}")
    fi
  done

  for scan in {1..20}; do
    for known_pid in "${known_pids[@]}"; do
      kill -STOP "${known_pid}" 2>/dev/null || true
    done
    added=0
    for known_pid in "${known_pids[@]}"; do
      kill -0 "${known_pid}" 2>/dev/null || continue
      descendant_text=$(opensteamer_descendant_pids "${known_pid}")
      for descendant_pid in ${(f)descendant_text}; do
        [[ -n "${descendant_pid}" ]] || continue
        kill -STOP "${descendant_pid}" 2>/dev/null || true
        if [[ -z "${seen_pids[${descendant_pid}]-}" ]]; then
          seen_pids[${descendant_pid}]=1
          known_pids+=("${descendant_pid}")
          added=1
        fi
      done
    done
    if (( added == 0 )); then
      stable_scans=$((stable_scans + 1))
      if (( stable_scans >= 2 )); then
        print -rl -- "${known_pids[@]}"
        return 0
      fi
    else
      stable_scans=0
    fi
    sleep 0.02
  done
  print -rl -- "${known_pids[@]}"
}

# TERM the entire captured process tree, wait only for a bounded grace period, then KILL anything
# still alive. Callers may safely `wait` for their direct child after this function returns.
function opensteamer_terminate_process_tree() {
  local root_pid=$1
  local grace_seconds=$2
  local grace_started
  local descendant_pid
  local descendant_text
  local frozen_process_text
  local -a descendant_pids frozen_process_pids

  if [[ -z "${root_pid}" ]] || ! kill -0 "${root_pid}" 2>/dev/null; then
    return 0
  fi

  descendant_text=$(opensteamer_descendant_pids "${root_pid}")
  descendant_pids=("${(@f)descendant_text}")
  for descendant_pid in "${descendant_pids[@]}"; do
    [[ -n "${descendant_pid}" ]] || continue
    kill -TERM "${descendant_pid}" 2>/dev/null || true
  done
  kill -TERM "${root_pid}" 2>/dev/null || true

  grace_started=${SECONDS}
  while kill -0 "${root_pid}" 2>/dev/null \
      && (( SECONDS - grace_started < grace_seconds )); do
    sleep 0.2
  done

  # TERM handlers can create replacement children during the grace period. Freeze and rescan the
  # live tree so the fallback cannot kill a parent while leaving its new child orphaned.
  frozen_process_text=$(opensteamer_freeze_process_forest \
    "${root_pid}" "${descendant_pids[@]}")
  frozen_process_pids=("${(@f)frozen_process_text}")
  for descendant_pid in "${frozen_process_pids[@]}"; do
    [[ -n "${descendant_pid}" ]] || continue
    [[ "${descendant_pid}" != "${root_pid}" ]] || continue
    if kill -0 "${descendant_pid}" 2>/dev/null; then
      kill -KILL "${descendant_pid}" 2>/dev/null || true
    fi
  done
  if kill -0 "${root_pid}" 2>/dev/null; then
    kill -KILL "${root_pid}" 2>/dev/null || true
  fi
}
