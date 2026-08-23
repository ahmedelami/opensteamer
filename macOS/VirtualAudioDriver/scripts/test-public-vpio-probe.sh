#!/bin/zsh
set -euo pipefail

export LC_ALL=C
umask 077

usage() {
    print -u2 "usage: $0 [--self-test]"
    print -u2 "standalone live mode is forbidden; use the persisted-state v7 route guardian"
    exit 64
}

if (( $# == 0 )); then
    :
elif (( $# == 1 )) && [[ "$1" == "--self-test" ]]; then
    :
elif (( $# == 2 )) && [[ "$1" == "--live" ]] && \
     [[ "$2" == "--acknowledge-default-input-mutation" ]]; then
    print -u2 "standalone live mode is forbidden; use the persisted-state v7 route guardian"
    exit 64
else
    usage
fi

script_dir="${0:A:h}"
builder="$script_dir/build-public-vpio-probe.sh"
probe_source="$script_dir/../Probes/PublicVPIOProbe.c"
/usr/bin/python3 - "$probe_source" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
if "kAudioHardwarePropertyDevices" in source:
    raise SystemExit("public VPIO probe must not depend on normal device enumeration")
if "kAudioDevicePropertyStreamFormat" in source:
    raise SystemExit("public VPIO probe must not use deprecated device-level format lookup")
if source.count("kAudioHardwarePropertyTranslateUIDToDevice") != 1:
    raise SystemExit("public VPIO probe must resolve endpoints through one exact UID translator")
if "WriteDefaultInputDevice(context->original_input_device)" in source:
    raise SystemExit("restoration must never write a stale snapshotted AudioDeviceID")
if "WriteDefaultInputDevice(freshRestorationTarget)" not in source:
    raise SystemExit("restoration must write only a fresh UID-translated AudioDeviceID")
required = (
    "ExactEndpointMonoFloatFormat",
    "ExactClientMonoFloatFormat",
    "ExactClientStereoFloatFormat",
    "EndpointTranslationsStillMatch",
    "OutputDefaultsStillMatchAndAreSafe",
    "InputDeviceMatchesAdmissibleUID",
)
missing = [name for name in required if name not in source]
if missing:
    raise SystemExit(f"public VPIO source invariants missing: {missing!r}")
endpoint_validator = source.split("static bool ExactEndpointMonoFloatFormat", 1)[1]
endpoint_validator = endpoint_validator.split("static bool ExactClientMonoFloatFormat", 1)[0]
mono_client_validator = source.split("static bool ExactClientMonoFloatFormat", 1)[1]
mono_client_validator = mono_client_validator.split("static bool ExactClientStereoFloatFormat", 1)[0]
stereo_client_validator = source.split("static bool ExactClientStereoFloatFormat", 1)[1]
stereo_client_validator = stereo_client_validator.split("static AudioStreamBasicDescription", 1)[0]
if "kAudioFormatFlagIsNonInterleaved" in endpoint_validator:
    raise SystemExit("endpoint native ASBD must remain packed interleaved mono")
if "kAudioFormatFlagIsNonInterleaved" not in mono_client_validator:
    raise SystemExit("VPIO capture ASBD must remain noninterleaved mono")
if "kAudioFormatFlagIsNonInterleaved" not in stereo_client_validator:
    raise SystemExit("VPIO playout ASBD must remain noninterleaved stereo")
validators = (endpoint_validator, mono_client_validator, stereo_client_validator)
if any(validator.count("mReserved == 0") != 1 for validator in validators):
    raise SystemExit("all exact ASBD validators must reject nonzero reserved fields")
PY

test_root="$(/usr/bin/mktemp -d /private/tmp/opensteamer-public-vpio-tests.XXXXXX)"
test_root="${test_root:A}"
case "$test_root" in
    /private/tmp/opensteamer-public-vpio-tests.*)
        ;;
    *)
        print -u2 "unexpected probe test root: $test_root"
        exit 73
        ;;
esac
active_child_pid=""
cleanup() {
    if [[ -n "$active_child_pid" ]] && \
       /bin/kill -0 "$active_child_pid" 2>/dev/null; then
        /bin/kill -TERM "$active_child_pid" 2>/dev/null || true
        for _ in {1..40}; do
            /bin/kill -0 "$active_child_pid" 2>/dev/null || break
            /bin/sleep 0.05
        done
        if /bin/kill -0 "$active_child_pid" 2>/dev/null; then
            /bin/kill -KILL "$active_child_pid" 2>/dev/null || true
        fi
        wait "$active_child_pid" 2>/dev/null || true
    fi
    active_child_pid=""
    if [[ -d "$test_root" ]] && [[ ! -L "$test_root" ]]; then
        /bin/rm -rf -- "$test_root"
    fi
}
handle_signal() {
    trap - INT TERM HUP
    cleanup
    exit 130
}
trap cleanup EXIT
trap handle_signal INT TERM HUP

live_refusal_stdout="$test_root/live-refusal.stdout"
live_refusal_stderr="$test_root/live-refusal.stderr"
live_refusal_status=0
OSVA_PUBLIC_VPIO_LIVE=I_UNDERSTAND_THIS_TEMPORARILY_CHANGES_DEFAULT_INPUT \
    "$0" --live --acknowledge-default-input-mutation \
    >"$live_refusal_stdout" 2>"$live_refusal_stderr" || \
    live_refusal_status=$?
[[ "$live_refusal_status" == "64" ]] || {
    print -u2 "standalone wrapper did not reject live mode with status 64"
    exit 1
}
[[ ! -s "$live_refusal_stdout" ]] || {
    print -u2 "standalone live refusal wrote unexpected stdout"
    exit 1
}
[[ "$(<"$live_refusal_stderr")" == \
    "standalone live mode is forbidden; use the persisted-state v7 route guardian" ]] || {
    print -u2 "standalone live refusal diagnostic changed unexpectedly"
    exit 1
}

binary_a="$test_root/a/opensteamer-public-vpio-probe"
binary_b="$test_root/b/opensteamer-public-vpio-probe"
/bin/mkdir -p "${binary_a:h}" "${binary_b:h}"
"$builder" "$binary_a" >/dev/null
"$builder" "$binary_b" >/dev/null
/usr/bin/cmp -s "$binary_a" "$binary_b" || {
    print -u2 "public VPIO probe builds are not byte-reproducible"
    exit 1
}
[[ "$(/usr/bin/stat -f '%Lp' "$binary_a")" == "755" ]] || {
    print -u2 "public VPIO probe executable mode is not 0755"
    exit 1
}

run_with_hard_deadline() {
    local deadline_seconds="$1"
    local stdout_path="$2"
    local stderr_path="$3"
    shift 3

    "$@" >"$stdout_path" 2>"$stderr_path" &
    local child_pid=$!
    active_child_pid="$child_pid"
    local started_at=$SECONDS
    local termination_sent=0
    while /bin/kill -0 "$child_pid" 2>/dev/null; do
        local elapsed=$(( SECONDS - started_at ))
        if (( termination_sent == 0 && elapsed >= deadline_seconds - 2 )); then
            /bin/kill -TERM "$child_pid" 2>/dev/null || true
            termination_sent=1
        fi
        if (( elapsed >= deadline_seconds )); then
            /bin/kill -KILL "$child_pid" 2>/dev/null || true
            wait "$child_pid" 2>/dev/null || true
            active_child_pid=""
            print -u2 "public VPIO probe exceeded its ${deadline_seconds}-second hard deadline"
            return 124
        fi
        /bin/sleep 0.05
    done
    local child_status=0
    wait "$child_pid" || child_status=$?
    active_child_pid=""
    if (( termination_sent != 0 )); then
        print -u2 "public VPIO probe reached its bounded cancellation window"
        return 124
    fi
    return "$child_status"
}

self_test_stdout="$test_root/self-test.stdout"
self_test_stderr="$test_root/self-test.stderr"
run_with_hard_deadline 10 "$self_test_stdout" "$self_test_stderr" \
    "$binary_a" --self-test
if [[ -s "$self_test_stderr" ]]; then
    print -u2 "public VPIO pure self-test wrote unexpected stderr"
    /bin/cat "$self_test_stderr" >&2
    exit 1
fi

/usr/bin/python3 - "$self_test_stdout" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
if len(lines) != 1:
    raise SystemExit("self-test must emit exactly one JSON line")
actual = json.loads(lines[0])
expected = {
    "schema": 1,
    "mode": "self-test",
    "claim": "public-vpio-compatibility-only",
    "passed": True,
    "tests": 26,
    "mutants": 23,
    "passSetHash": "fc55e827d44da8da",
    "unexpectedFailureMask": "0000000000000000",
    "publicVPIOProcessedMicUplinkValidated": False,
    "publicVPIOStereoPlayoutRenderPathValidated": False,
    "faceTimeUplinkClaimed": False,
    "localDownlinkAcousticsClaimed": False,
    "farEndDownlinkAcousticsClaimed": False,
}
if actual != expected:
    raise SystemExit(f"unexpected exact self-test evidence: {actual!r}")
PY
print "PASS public VPIO pure evaluator and exact mutation set"
print "probe_sha256=$(/usr/bin/shasum -a 256 "$binary_a" | /usr/bin/awk '{print $1}')"
print "PASS standalone wrapper refuses live mode even with the binary opt-in token"
print "PUBLIC_VPIO_SELF_TESTS_PASSED_WITHOUT_CORE_AUDIO_IO"
