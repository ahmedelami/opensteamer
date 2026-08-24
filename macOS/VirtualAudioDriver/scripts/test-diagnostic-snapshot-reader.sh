#!/bin/zsh
set -euo pipefail

export LC_ALL=C
umask 077

if (( $# != 0 )); then
    print -u2 "usage: $0"
    exit 64
fi

script_dir="${0:A:h}"
driver_root="${script_dir:h}"
builder="$script_dir/build-diagnostic-snapshot-reader.sh"
source="$driver_root/Probes/DiagnosticSnapshotReader.c"
header="$driver_root/include/OpensteamerVirtualMicrophoneDriver.h"

/usr/bin/python3 - "$source" "$header" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
header = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")

forbidden = (
    "AudioObjectSetPropertyData",
    "AudioDeviceCreateIOProcID",
    "AudioDeviceStart",
    "AudioDeviceStop",
    "AudioQueue",
    "AudioUnit",
    "kAudioHardwarePropertyDevices",
    "kAudioHardwarePropertyDefaultInputDevice",
    "kAudioHardwarePropertyDefaultOutputDevice",
    "kAudioHardwarePropertyDefaultSystemOutputDevice",
)
present = [token for token in forbidden if token in source]
if present:
    raise SystemExit(f"diagnostic reader contains forbidden live/mutating API tokens: {present!r}")

required_source = (
    "OSVA_VISIBLE_INPUT_DEVICE_UID",
    "OSVA_HIDDEN_WRITER_DEVICE_UID",
    "kAudioHardwarePropertyTranslateUIDToDevice",
    "kAudioObjectPropertyCustomPropertyInfoList",
    "kOSVADiagnosticSnapshotProperty",
    "kOSVADiagnosticSnapshotUnavailableError",
    "kAudioObjectPropertyScopeGlobal",
    "kAudioObjectPropertyElementMain",
    "AudioObjectGetPropertyDataSize",
    "AudioObjectGetPropertyData",
    "kAudioServerPlugInCustomPropertyDataTypeCFPropertyList",
    "kAudioServerPlugInCustomPropertyDataTypeNone",
    "CFDataGetTypeID",
    "CFDataGetLength",
    "CFDataGetBytes",
    "CFRelease",
    "SnapshotSchemaIsExact",
    "SharedStateEqual",
    "ExactTranslationsRemainStable",
    "kMaximumCoherenceAttempts",
    "driverClientGeneration",
    "coreSessionID",
    "lastCallCoreLifecycleSequence",
    "epochMappingUnavailableCount",
    "lastSeedGeneration",
    "lastPublishedSeedGeneration",
    "lastConsumedSeedGeneration",
    "ioWorkLoop",
    "metadataSequence",
    "metadataDroppedUpdateCount",
    "currentCount",
    "underflowCount",
    "--read-once",
)
missing = [token for token in required_source if token not in source]
if missing:
    raise SystemExit(f"diagnostic reader source contract is incomplete: {missing!r}")

required_header = (
    "kOSVADiagnosticSnapshotSchemaVersion = 1",
    "kOSVADiagnosticSnapshotByteCount = 8608",
    "kOSVADiagnosticSnapshotProperty = 0x6F734453",
    "CFPropertyListRef whose concrete value is",
    "CFData containing exactly one OSVADiagnosticSnapshot",
    "typedef struct OSVADiagnosticSnapshot",
)
missing = [token for token in required_header if token not in header]
if missing:
    raise SystemExit(f"diagnostic reader schema contract is incomplete: {missing!r}")
PY

test_root="$(/usr/bin/mktemp -d /private/tmp/opensteamer-diagnostic-reader-tests.XXXXXX)"
test_root="${test_root:A}"
case "$test_root" in
    /private/tmp/opensteamer-diagnostic-reader-tests.*)
        ;;
    *)
        print -u2 "unexpected diagnostic-reader test root: $test_root"
        exit 73
        ;;
esac
cleanup() {
    if [[ -d "$test_root" ]] && [[ ! -L "$test_root" ]]; then
        /bin/rm -rf -- "$test_root"
    fi
}
trap cleanup EXIT INT TERM HUP

binary_a="$test_root/a/opensteamer-diagnostic-snapshot-reader"
binary_b="$test_root/b/opensteamer-diagnostic-snapshot-reader"
/bin/mkdir -p "${binary_a:h}" "${binary_b:h}"
"$builder" "$binary_a" >/dev/null
"$builder" "$binary_b" >/dev/null
/usr/bin/cmp -s "$binary_a" "$binary_b" || {
    print -u2 "diagnostic-reader builds are not byte-reproducible"
    exit 1
}
[[ "$(/usr/bin/stat -f '%Lp' "$binary_a")" == "755" ]] || {
    print -u2 "diagnostic-reader executable mode is not 0755"
    exit 1
}

undefined_symbols="$(/usr/bin/nm -u "$binary_a")"
for forbidden_symbol in \
    _AudioObjectSetPropertyData \
    _AudioDeviceCreateIOProcID \
    _AudioDeviceStart \
    _AudioDeviceStop \
    _AudioQueueNewInput \
    _AudioQueueNewOutput \
    _AudioQueueStart \
    _AudioUnitInitialize; do
    if /usr/bin/grep -Fq -- "$forbidden_symbol" <<< "$undefined_symbols"; then
        print -u2 "diagnostic reader imports forbidden symbol: $forbidden_symbol"
        exit 1
    fi
done
for required_symbol in \
    _AudioObjectGetPropertyData \
    _AudioObjectGetPropertyDataSize; do
    if ! /usr/bin/grep -Fq -- "$required_symbol" <<< "$undefined_symbols"; then
        print -u2 "diagnostic reader is missing required read-only symbol: $required_symbol"
        exit 1
    fi
done

usage_stdout="$test_root/usage.stdout"
usage_stderr="$test_root/usage.stderr"
usage_status=0
"$binary_a" >"$usage_stdout" 2>"$usage_stderr" || usage_status=$?
[[ "$usage_status" == "64" ]] || {
    print -u2 "diagnostic reader did not reject missing mode with status 64"
    exit 1
}
[[ ! -s "$usage_stdout" ]] || {
    print -u2 "diagnostic-reader usage path wrote unexpected stdout"
    exit 1
}
[[ "$(<"$usage_stderr")" == *"--self-test | --read-once" ]] || {
    print -u2 "diagnostic-reader usage text changed unexpectedly"
    exit 1
}

self_test_stdout="$test_root/self-test.stdout"
self_test_stderr="$test_root/self-test.stderr"
"$binary_a" --self-test >"$self_test_stdout" 2>"$self_test_stderr"
[[ ! -s "$self_test_stderr" ]] || {
    print -u2 "diagnostic-reader self-test wrote unexpected stderr"
    /bin/cat "$self_test_stderr" >&2
    exit 1
}
/usr/bin/python3 - "$self_test_stdout" <<'PY'
import json
import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
if len(lines) != 2:
    raise SystemExit("diagnostic-reader self-test must emit fixture and summary JSON lines")
fixture = json.loads(lines[0])
if fixture["readerSchema"] != 1 or fixture["mode"] != "self-test-fixture":
    raise SystemExit(f"unexpected diagnostic-reader fixture identity: {fixture!r}")
if fixture["claim"] != "read-only-virtual-driver-diagnostic-snapshot":
    raise SystemExit("diagnostic-reader fixture claim changed unexpectedly")
if not fixture["endpointReadsCoherent"]:
    raise SystemExit("diagnostic-reader fixture must report coherent endpoint reads")
if fixture["customPropertyDataType"] != "CFPropertyList":
    raise SystemExit("diagnostic-reader fixture lost the public IPC transport declaration")
if fixture["payloadConcreteType"] != "CFData":
    raise SystemExit("diagnostic-reader fixture lost the concrete CFData payload declaration")
if (
    fixture["snapshotSchemaVersion"] != 1
    or fixture["snapshotStructSize"] != 8608
    or not fixture["allDeclaredInvariantsHold"]
):
    raise SystemExit("diagnostic-reader fixture schema/invariants are invalid")
transition = fixture["lastDriverTransition"]
if (
    transition["driverClientGeneration"] != 70
    or transition["coreSessionID"] != 80
    or transition["processID"] != 4321
):
    raise SystemExit("diagnostic-reader transition provenance is incomplete")
if fixture["zeroTimestamp"][0]["endpointRole"] != 1:
    raise SystemExit("visible zero-timestamp endpoint indexing changed")
if (
    fixture["zeroTimestamp"][0]["sequence"] != 4
    or fixture["zeroTimestamp"][0]["metadataSequence"] != 2
    or fixture["zeroTimestamp"][0]["metadataDroppedUpdateCount"] != 3
    or fixture["zeroTimestamp"][0]["epochMappingUnavailableCount"] != 0
    or fixture["zeroTimestamp"][0]["lastSeedGeneration"] != 3
    or fixture["zeroTimestamp"][0]["lastCoreLifecycleSequence"] != 48
    or fixture["zeroTimestamp"][0]["lastCallCoreLifecycleSequence"] != 50
):
    raise SystemExit("visible zero-timestamp diagnostics lost schema fields")
if fixture["zeroTimestamp"][1]["endpointRole"] != 2:
    raise SystemExit("writer zero-timestamp endpoint indexing changed")
if (
    fixture["io"][1]["sequence"] != 6
    or fixture["io"][1]["metadataSequence"] != 2
    or fixture["io"][1]["metadataDroppedUpdateCount"] != 5
    or fixture["io"][1]["epochMappingUnavailableCount"] != 0
    or fixture["io"][1]["lastPublishedSeedGeneration"] != 3
    or fixture["io"][1]["lastConsumedSeedGeneration"] != 0
):
    raise SystemExit("writer I/O diagnostics lost generation fields")
if (
    fixture["ioWorkLoop"][0]["endpointRole"] != 1
    or fixture["ioWorkLoop"][0]["sequence"] != 9
    or fixture["ioWorkLoop"][0]["metadataSequence"] != 2
    or fixture["ioWorkLoop"][0]["metadataDroppedUpdateCount"] != 8
    or fixture["ioWorkLoop"][0]["currentCount"] != 2
    or fixture["ioWorkLoop"][0]["beginCount"] != 5
    or fixture["ioWorkLoop"][0]["endCount"] != 4
    or fixture["ioWorkLoop"][0]["underflowCount"] != 1
):
    raise SystemExit("visible I/O work-loop diagnostics lost schema fields")
actual = json.loads(lines[1])
expected = {
    "schema": 1,
    "mode": "self-test",
    "passed": True,
    "tests": 27,
    "coreAudioIOStarted": False,
    "routesMutated": False,
}
if actual != expected:
    raise SystemExit(f"unexpected diagnostic-reader self-test: {actual!r}")
PY

print "PASS diagnostic snapshot reader schema and coherence self-tests"
print "PASS exact-UID reader imports only read-only Core Audio property APIs"
print "DIAGNOSTIC_SNAPSHOT_READER_TESTS_PASSED_WITHOUT_CORE_AUDIO_IO"
