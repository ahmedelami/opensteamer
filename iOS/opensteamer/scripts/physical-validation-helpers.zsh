#!/bin/zsh

# Shared runtime primitives for the physical-device release gates.
#
# Usage: source this file from a strict-mode zsh driver; it is not a standalone command. Keep
# functions free of top-level side effects so production drivers and shell regression tests can
# safely share them. Callers need macOS system tools used by the selected helper (`python3`,
# `xcrun devicectl`, `launchctl`, `shasum`, and process utilities) plus permission to inspect the
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

function opensteamer_require_continuous_log() {
  local initial_identity=$1
  local current_identity=$2
  local prior_line_count=$3
  local current_line_count=$4

  [[ -n "${initial_identity}" && "${current_identity}" == "${initial_identity}" ]] \
    || return 1
  [[ -n "${prior_line_count}" && "${prior_line_count}" != *[^0-9]* ]] \
    || return 1
  [[ -n "${current_line_count}" && "${current_line_count}" != *[^0-9]* ]] \
    || return 1
  (( current_line_count >= prior_line_count ))
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
  if ! metadata=$(/usr/bin/python3 - \
      "${log_path}" \
      "${expected_identity}" \
      "${prior_offset}" \
      "${prior_digest}" \
      "${appended_output}" <<'PY'
import hashlib
import os
import sys
import time

path, expected_identity, prior_offset_text, prior_digest, output = sys.argv[1:]
try:
    prior_offset = int(prior_offset_text)
except ValueError:
    sys.exit(2)
if prior_offset < 0 or len(prior_digest) != 64:
    sys.exit(2)

ready_path = os.environ.get("OPENSTEAMER_LOG_SNAPSHOT_TEST_READY")
proceed_path = os.environ.get("OPENSTEAMER_LOG_SNAPSHOT_TEST_PROCEED")
hook_used = False
last_reason = "log snapshot did not stabilize"

for _ in range(20):
    try:
        descriptor = os.open(path, os.O_RDONLY)
    except OSError as error:
        last_reason = f"could not open log: {error}"
        time.sleep(0.01)
        continue
    try:
        before = os.fstat(descriptor)
        identity = f"{before.st_dev}:{before.st_ino}"
        if expected_identity and identity != expected_identity:
            print("log path identity changed", file=sys.stderr)
            sys.exit(3)
        if before.st_size < prior_offset:
            print("log became shorter than the consumed byte offset", file=sys.stderr)
            sys.exit(3)

        if ready_path and proceed_path and not hook_used:
            hook_used = True
            with open(ready_path, "w", encoding="utf-8") as ready:
                ready.write("ready\n")
            deadline = time.monotonic() + 2
            while not os.path.exists(proceed_path) and time.monotonic() < deadline:
                time.sleep(0.005)
            if not os.path.exists(proceed_path):
                print("snapshot test hook timed out", file=sys.stderr)
                sys.exit(4)

        data = os.pread(descriptor, before.st_size, 0)
        after = os.fstat(descriptor)
        try:
            path_after = os.stat(path)
        except OSError as error:
            last_reason = f"could not restat log path: {error}"
            time.sleep(0.01)
            continue
        before_version = (
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        )
        after_version = (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        )
        if before_version != after_version:
            last_reason = "opened log changed during snapshot"
            time.sleep(0.01)
            continue
        if (path_after.st_dev, path_after.st_ino) != (after.st_dev, after.st_ino):
            last_reason = "log path changed during snapshot"
            time.sleep(0.01)
            continue
        if len(data) != before.st_size:
            last_reason = "short read from opened log"
            time.sleep(0.01)
            continue

        consumed_digest = hashlib.sha256(data[:prior_offset]).hexdigest()
        if consumed_digest != prior_digest:
            print("consumed log prefix digest changed", file=sys.stderr)
            sys.exit(3)
        snapshot_digest = hashlib.sha256(data).hexdigest()
        temporary_output = f"{output}.tmp.{os.getpid()}"
        with open(temporary_output, "wb") as appended:
            appended.write(data[prior_offset:])
        os.replace(temporary_output, output)
        print(identity)
        print(len(data))
        print(snapshot_digest)
        print("1" if not data or data.endswith(b"\n") else "0")
        sys.exit(0)
    finally:
        os.close(descriptor)

print(last_reason, file=sys.stderr)
sys.exit(3)
PY
  ); then
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

  /usr/bin/python3 - \
      "${appended_input}" "${partial_state}" "${completed_output}" <<'PY'
import os
import sys

appended_path, partial_path, completed_path = sys.argv[1:]
with open(appended_path, "rb") as appended:
    payload = appended.read()
try:
    with open(partial_path, "rb") as partial:
        payload = partial.read() + payload
except FileNotFoundError:
    pass

boundary = payload.rfind(b"\n")
if boundary < 0:
    completed = b""
    partial = payload
else:
    completed = payload[: boundary + 1]
    partial = payload[boundary + 1 :]

for path, contents in ((completed_path, completed), (partial_path, partial)):
    temporary = f"{path}.tmp.{os.getpid()}"
    with open(temporary, "wb") as destination:
        destination.write(contents)
    os.replace(temporary, path)
PY
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

# Run a small critical-section command with a hard wall-clock bound and kill its whole subprocess
# group on timeout. This prevents a wedged system command from indefinitely holding a driver lock.
function opensteamer_run_with_timeout() {
  local timeout_seconds=$1
  shift
  /usr/bin/python3 -c '
import os
import signal
import subprocess
import sys

timeout = float(sys.argv[1])
command = sys.argv[2:]
process = subprocess.Popen(command, start_new_session=True)
try:
    return_code = process.wait(timeout=timeout)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        pass
    # The leader may exit on TERM while a descendant in the same group ignores it. Always sweep
    # the still-addressable group with KILL before returning the timeout status.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    if process.poll() is None:
        process.wait()
    sys.exit(124)
if return_code < 0:
    sys.exit(128 - return_code)
sys.exit(return_code)
' "${timeout_seconds}" "$@"
}

# The background function is replaced by Python and then the requested executable, preserving
# `$!` as a dedicated session/process-group leader that the parent can safely signal as a unit.
function opensteamer_exec_in_isolated_process_group() {
  if [[ ! -x /usr/bin/python3 ]]; then
    echo "/usr/bin/python3 is required to create an isolated validation process group." >&2
    return 127
  fi
  exec /usr/bin/python3 -c '
import os
import sys
if os.getpgrp() != os.getpid():
    os.setsid()
os.execvp(sys.argv[1], sys.argv[1:])
' "$@"
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

function opensteamer_process_group_exists() {
  local leader_pid=$1
  kill -0 -- "-${leader_pid}" 2>/dev/null
}

function opensteamer_wait_for_process_group_exit() {
  local leader_pid=$1
  local timeout_seconds=$2
  local wait_started=${SECONDS}

  while opensteamer_process_group_exists "${leader_pid}"; do
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
  while kill -0 -- "-${leader_pid}" 2>/dev/null \
      && (( SECONDS - grace_started < grace_seconds )); do
    sleep 0.2
  done
  if kill -0 -- "-${leader_pid}" 2>/dev/null; then
    kill -KILL -- "-${leader_pid}" 2>/dev/null || true
  fi
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
