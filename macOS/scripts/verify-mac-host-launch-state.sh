#!/bin/zsh
# Independently verifies the reviewed LaunchAgent plist and captured launchctl state.
set -euo pipefail

readonly REVIEWED_LABEL="org.example.opensteamer.worldwide"
readonly REVIEWED_EXECUTABLE="/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer"
readonly REVIEWED_RENDEZVOUS_URL="wss://audiostreamer-rendezvous.elaminahmed03.workers.dev"
readonly REVIEWED_STDOUT="/var/tmp/opensteamer-worldwide-host.log"
readonly REVIEWED_STDERR="/var/tmp/opensteamer-worldwide-host.err.log"
readonly REVIEWED_THROTTLE="10"
readonly REVIEWED_RATE_LIMIT="64"

fail() {
    print -u2 -- "verify-mac-host-launch-state: $*"
    exit 1
}

usage() {
    print -u2 -- \
        "usage: $0 --verify-plist <expected-executable> <launch-agent-plist>\n       $0 <launchctl-print-file> <expected-executable> <launch-agent-template> <installed-launch-agent>"
    exit 64
}

plist_extract() {
    local plist="$1" key="$2" format="$3" expected_type="$4"
    /usr/bin/plutil -extract "$key" "$format" -expect "$expected_type" -o - "$plist" 2>/dev/null
}

canonical_plist() {
    /usr/bin/plutil -convert xml1 -o - "$1"
}

plist_arguments() {
    local plist="$1" index=0 value key
    plist_extract "$plist" ProgramArguments xml1 array >/dev/null || return 1
    while (( index < 64 )); do
        key="ProgramArguments.$index"
        if value="$(plist_extract "$plist" "$key" raw string)"; then
            [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
            print -r -- "$value"
            index=$((index + 1))
            continue
        fi
        # `raw -expect string` is both the value and type probe. If the node still extracts as
        # XML, it exists with a non-string type and must be rejected; otherwise the array ended.
        if /usr/bin/plutil -extract "$key" xml1 -o /dev/null "$plist" 2>/dev/null; then
            return 1
        fi
        (( index > 0 )) || return 1
        return 0
    done
    return 1
}

# `plutil -extract ... -expect` validates the property-list node type before its raw value is read.
assert_reviewed_plist() {
    local plist="$1" expected_executable="$2"
    [[ "$expected_executable" == "$REVIEWED_EXECUTABLE" ]] || fail \
        "expected executable must be exactly '$REVIEWED_EXECUTABLE'"
    [[ -f "$plist" && ! -L "$plist" ]] || fail "LaunchAgent plist is not a real regular file: $plist"
    [[ "$(/usr/bin/stat -f '%l' "$plist")" == 1 ]] || fail \
        "LaunchAgent plist must have exactly one hard link"
    /usr/bin/plutil -lint "$plist" >/dev/null || fail "LaunchAgent is not a valid property list: $plist"

    local label run_at_load keep_alive throttle stdout_path stderr_path rate_limit
    label="$(plist_extract "$plist" Label raw string)" || fail "Label must be a string"
    run_at_load="$(plist_extract "$plist" RunAtLoad raw bool)" || fail "RunAtLoad must be a Boolean"
    keep_alive="$(plist_extract "$plist" KeepAlive raw bool)" || fail "KeepAlive must be a Boolean"
    throttle="$(plist_extract "$plist" ThrottleInterval raw integer)" || fail \
        "ThrottleInterval must be an integer"
    stdout_path="$(plist_extract "$plist" StandardOutPath raw string)" || fail \
        "StandardOutPath must be a string"
    stderr_path="$(plist_extract "$plist" StandardErrorPath raw string)" || fail \
        "StandardErrorPath must be a string"
    rate_limit="$(plist_extract "$plist" EnvironmentVariables.OSLogRateLimit raw string)" || fail \
        "EnvironmentVariables.OSLogRateLimit must be a string"
    plist_extract "$plist" ProgramArguments xml1 array >/dev/null || fail \
        "ProgramArguments must be an array"
    plist_extract "$plist" EnvironmentVariables xml1 dictionary >/dev/null || fail \
        "EnvironmentVariables must be a dictionary"

    [[ "$label" == "$REVIEWED_LABEL" ]] || fail "LaunchAgent Label is '$label', expected '$REVIEWED_LABEL'"
    [[ "$run_at_load" == true ]] || fail "LaunchAgent requires Boolean RunAtLoad=true"
    [[ "$keep_alive" == true ]] || fail "LaunchAgent requires Boolean KeepAlive=true"
    [[ "$throttle" == "$REVIEWED_THROTTLE" ]] || fail \
        "LaunchAgent ThrottleInterval is '$throttle', expected integer '$REVIEWED_THROTTLE'"
    [[ "$stdout_path" == "$REVIEWED_STDOUT" ]] || fail \
        "LaunchAgent StandardOutPath is '$stdout_path', expected '$REVIEWED_STDOUT'"
    [[ "$stderr_path" == "$REVIEWED_STDERR" ]] || fail \
        "LaunchAgent StandardErrorPath is '$stderr_path', expected '$REVIEWED_STDERR'"
    [[ "$rate_limit" == "$REVIEWED_RATE_LIMIT" ]] || fail \
        "LaunchAgent OSLogRateLimit is '$rate_limit', expected '$REVIEWED_RATE_LIMIT'"

    local canonical top_keys environment_keys
    canonical="$(canonical_plist "$plist")" || fail "could not canonicalize LaunchAgent"
    top_keys="$(print -r -- "$canonical" | /usr/bin/awk '
        /^[[:space:]]*<dict>/ { depth += 1; next }
        /^[[:space:]]*<array>/ { depth += 1; next }
        /^[[:space:]]*<\/dict>/ { depth -= 1; next }
        /^[[:space:]]*<\/array>/ { depth -= 1; next }
        depth == 1 && /^[[:space:]]*<key>[^<]+<\/key>/ {
            value=$0; sub(/^[[:space:]]*<key>/, "", value); sub(/<\/key>[[:space:]]*$/, "", value); print value
        }
    ' | LC_ALL=C /usr/bin/sort)"
    [[ "$top_keys" == $'EnvironmentVariables\nKeepAlive\nLabel\nProgramArguments\nRunAtLoad\nStandardErrorPath\nStandardOutPath\nThrottleInterval' ]] || fail \
        "LaunchAgent top-level keys differ from the reviewed contract"
    environment_keys="$(print -r -- "$canonical" | /usr/bin/awk '
        /<key>EnvironmentVariables<\/key>/ { want = 1; next }
        want && /<dict>/ { inside = 1; depth = 1; want = 0; next }
        inside && /<dict>/ { depth += 1 }
        inside && /<\/dict>/ { depth -= 1; if (depth == 0) exit }
        inside && depth == 1 && /^[[:space:]]*<key>[^<]+<\/key>/ {
            value=$0; sub(/^[[:space:]]*<key>/, "", value); sub(/<\/key>[[:space:]]*$/, "", value); print value
        }
    ' | LC_ALL=C /usr/bin/sort)"
    [[ "$environment_keys" == OSLogRateLimit ]] || fail \
        "EnvironmentVariables must contain only OSLogRateLimit"

    local actual_arguments expected_arguments wss_count
    actual_arguments="$(plist_arguments "$plist")" || fail \
        "ProgramArguments must contain only strings"
    expected_arguments="$(cat <<'ARGS'
/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer
--worldwide
--allow-remote-control
--duration
0
--verbose
--rendezvous-url
wss://audiostreamer-rendezvous.elaminahmed03.workers.dev
ARGS
)"
    [[ "$actual_arguments" == "$expected_arguments" ]] || fail \
        "LaunchAgent ProgramArguments do not equal the reviewed eight-item contract"
    wss_count="$(print -r -- "$actual_arguments" | /usr/bin/awk '/^wss:\/\// { count += 1 } END { print count + 0 }')"
    [[ "$wss_count" == 1 ]] || fail "LaunchAgent must contain exactly one wss:// URL"
    if print -r -- "$actual_arguments" | /usr/bin/grep -Fxq -- '--reset-worldwide-pairing'; then
        fail "LaunchAgent must not reset worldwide pairing"
    fi
    if print -r -- "$actual_arguments" | /usr/bin/grep -Eq -- \
        '^(--with-lan|--no-lan|--host|--port|--screen-port|--bonjour-name|--no-bonjour|--token|--force-relay|--capture-mode|--display-id)$'; then
        fail "LaunchAgent contains a forbidden LAN/test-mode argument"
    fi
    return 0
}

parse_launch_snapshot() {
    local input_path="$1"
    /usr/bin/awk -v expected_label="$REVIEWED_LABEL" '
    function trim(value) {
        sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value); return value
    }
    function emit_once(name, value) {
        counts[name] += 1
        print name "\t" value
    }
    NR == 1 {
        expected = "gui/" ENVIRON["UID"] "/" expected_label " = {"
        # UID may be absent from awk environment under test runners; validate the stable suffix here.
        if ($0 !~ "^gui/[0-9]+/" expected_label " = \\{$") exit 80
        depth = 1
        next
    }
    {
        raw=$0; line=trim(raw)
        if (line == "") next
        if (closed) exit 81

        if (depth == 1) {
            if (line == "}") { depth=0; closed=1; next }
            if (line == "arguments = {") {
                argument_blocks += 1; block="arguments"; depth=2; next
            }
            if (line == "environment = {") {
                job_environment_blocks += 1; block="job-environment"; depth=2; next
            }
            if (line == "inherited environment = {" || line == "default environment = {") {
                environment_blocks += 1; block="other-environment"; depth=2; next
            }
            if (line ~ / = \{$/) { block="other"; depth=2; next }
            if (line ~ /^path = /) { value=line; sub(/^path = /, "", value); emit_once("path", value); next }
            if (line ~ /^type = /) { value=line; sub(/^type = /, "", value); emit_once("type", value); next }
            if (line ~ /^state = /) { value=line; sub(/^state = /, "", value); emit_once("state", value); next }
            if (line ~ /^program = /) { value=line; sub(/^program = /, "", value); emit_once("program", value); next }
            if (line ~ /^pid = [0-9]+$/) { value=line; sub(/^pid = /, "", value); emit_once("pid", value); next }
            if (line ~ /^runs = [0-9]+$/) { value=line; sub(/^runs = /, "", value); emit_once("runs", value); next }
            if (line ~ /^stdout path = /) { value=line; sub(/^stdout path = /, "", value); emit_once("stdout", value); next }
            if (line ~ /^stderr path = /) { value=line; sub(/^stderr path = /, "", value); emit_once("stderr", value); next }
            if (line ~ /^minimum runtime = [0-9]+$/) { value=line; sub(/^minimum runtime = /, "", value); emit_once("minimum-runtime", value); next }
            if (line ~ /^properties = /) { value=line; sub(/^properties = /, "", value); emit_once("properties", value); next }
            if (line ~ /[{}]/) exit 82
            next
        }

        if (line == "}") {
            depth -= 1
            if (depth == 1) block=""
            next
        }
        if (line ~ / = \{$/) {
            if (block == "arguments" && depth == 2) exit 83
            depth += 1
            next
        }
        if (line ~ /[{}]/) exit 84
        if (depth == 2 && block == "arguments") {
            if (line == "") exit 85
            print "argument\t" line
            arguments += 1
            next
        }
        if (depth == 2 && (block == "job-environment" || block == "other-environment")) {
            split_at=index(line, " => ")
            if (split_at == 0) exit 86
            key=substr(line, 1, split_at-1)
            value=substr(line, split_at+4)
            if (key == "" || value == "") exit 87
            print "environment-any\t" key "\t" value
            if (block == "job-environment") print "job-environment\t" key "\t" value
            next
        }
    }
    END {
        if (depth != 0 || !closed || argument_blocks != 1 || arguments < 1 ||
            job_environment_blocks != 1 || counts["path"] != 1 || counts["type"] != 1 ||
            counts["state"] != 1 || counts["program"] != 1 || counts["pid"] != 1 ||
            counts["runs"] != 1 || counts["stdout"] != 1 || counts["stderr"] != 1 ||
            counts["minimum-runtime"] != 1 || counts["properties"] != 1) exit 88
    }
' "$input_path"
}

if (( $# == 1 )) && [[ "$1" == --self-test-launch-parser ]]; then
    local_fixture="$(cat <<'LAUNCHCTL'
gui/501/org.example.opensteamer.worldwide = {
    active count = 1
    path = /Users/ahmed/Library/LaunchAgents/org.example.opensteamer.worldwide.plist
    type = LaunchAgent
    state = running
    program = /Applications/opensteamer Host.app/Contents/MacOS/CaptureServer
    arguments = {
        /Applications/opensteamer Host.app/Contents/MacOS/CaptureServer
        --worldwide
        --allow-remote-control
        --duration
        0
        --verbose
        --rendezvous-url
        wss://audiostreamer-rendezvous.elaminahmed03.workers.dev
    }
    environment = {
        OSLogRateLimit => 64
        XPC_SERVICE_NAME => org.example.opensteamer.worldwide
    }
    stdout path = /var/tmp/opensteamer-worldwide-host.log
    stderr path = /var/tmp/opensteamer-worldwide-host.err.log
    minimum runtime = 10
    runs = 2
    pid = 820
    resource coalition = {
        ID = 919
        type = resource
        state = active
        pid = 99999
        program = /tmp/adversarial
        arguments = {
            /tmp/adversarial
            --nested
        }
    }
    jetsam coalition = {
        ID = 920
        type = jetsam
        state = active
    }
    properties = keepalive | runatload | inferred program | managed LWCR | has LWCR
}
LAUNCHCTL
)"
    parsed_fixture="$(print -r -- "$local_fixture" | parse_launch_snapshot /dev/stdin)" || fail         "real coalition launchctl fixture was rejected"
    [[ "$(print -r -- "$parsed_fixture" | /usr/bin/awk -F '\t' '$1 == "pid" { print $2 }')" == 820 ]] || fail         "nested coalition PID contaminated the top-level parse"
    [[ "$(print -r -- "$parsed_fixture" | /usr/bin/awk -F '\t' '$1 == "program" { print $2 }')" == "$REVIEWED_EXECUTABLE" ]] || fail         "nested coalition program contaminated the top-level parse"
    [[ "$(print -r -- "$parsed_fixture" | /usr/bin/awk -F '\t' '$1 == "argument" { count += 1 } END { print count + 0 }')" == 8 ]] || fail         "nested coalition arguments contaminated the top-level parse"
    duplicate_fixture="$(print -r -- "$local_fixture" | /usr/bin/awk '/^[[:space:]]*resource coalition = \{$/ { print "    pid = 999" } { print }')"
    if print -r -- "$duplicate_fixture" | parse_launch_snapshot /dev/stdin >/dev/null 2>&1; then
        fail "duplicate top-level PID fixture was accepted"
    fi
    unclosed_fixture="$(print -r -- "$local_fixture" | /usr/bin/sed '$d')"
    if print -r -- "$unclosed_fixture" | parse_launch_snapshot /dev/stdin >/dev/null 2>&1; then
        fail "unclosed top-level job fixture was accepted"
    fi
    print -r -- "SELF_TEST_OK launch-parser"
    exit 0
fi

if (( $# == 3 )) && [[ "$1" == --verify-plist ]]; then
    assert_reviewed_plist "$3" "$2"
    print -r -- "plist=$3"
    exit 0
fi

(( $# == 4 )) || usage
LAUNCH_STATE_FILE="$1"
EXPECTED_EXECUTABLE="$2"
LAUNCH_AGENT_TEMPLATE="$3"
INSTALLED_LAUNCH_AGENT="$4"

[[ -f "$LAUNCH_STATE_FILE" && ! -L "$LAUNCH_STATE_FILE" ]] || fail \
    "launchctl state file is not a safe regular file"
assert_reviewed_plist "$LAUNCH_AGENT_TEMPLATE" "$EXPECTED_EXECUTABLE"
assert_reviewed_plist "$INSTALLED_LAUNCH_AGENT" "$EXPECTED_EXECUTABLE"
SOURCE_CANONICAL="$(canonical_plist "$LAUNCH_AGENT_TEMPLATE")" || fail "could not canonicalize source plist"
INSTALLED_CANONICAL="$(canonical_plist "$INSTALLED_LAUNCH_AGENT")" || fail \
    "could not canonicalize installed plist"
[[ "$SOURCE_CANONICAL" == "$INSTALLED_CANONICAL" ]] || fail \
    "installed LaunchAgent plist differs from the source-controlled template"
[[ "$(/usr/bin/stat -f '%u' "$INSTALLED_LAUNCH_AGENT")" == "$UID" ]] || fail \
    "installed LaunchAgent is not owned by the current uid"
[[ "$(/usr/bin/stat -f '%Lp' "$INSTALLED_LAUNCH_AGENT")" == 600 ]] || fail \
    "installed LaunchAgent mode must be 0600"

LAUNCH_STATE="$(<"$LAUNCH_STATE_FILE")"
HEADER_LABEL="$(print -r -- "$LAUNCH_STATE" | /usr/bin/awk 'NR == 1 {
    value=$1; sub(/^gui\/[0-9]+\//, "", value); print value; exit
}')"
[[ "$HEADER_LABEL" == "$REVIEWED_LABEL" ]] || fail \
    "launchd snapshot label is '$HEADER_LABEL', expected '$REVIEWED_LABEL'"

# Emit only fields and blocks whose parent is the top-level launchd job. Nested resource/jetsam
# coalitions may repeat names such as type/state/active count and are deliberately ignored.
PARSED_LAUNCH_STATE="$(parse_launch_snapshot "$LAUNCH_STATE_FILE")" || fail \
    "launchd snapshot top-level job structure is malformed or ambiguous"

manifest_once() {
    local key="$1" values count
    values="$(print -r -- "$PARSED_LAUNCH_STATE" | /usr/bin/awk -F '\t' -v key="$key" '$1 == key { print substr($0, length($1) + 2) }')"
    count="$(print -r -- "$values" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
    [[ "$count" == 1 ]] || fail "launchd top-level manifest has $count '$key' fields, expected one"
    print -r -- "$values"
}

LOADED_PATH="$(manifest_once path)"
LOADED_TYPE="$(manifest_once type)"
LOADED_STATE="$(manifest_once state)"
PROGRAM="$(manifest_once program)"
PID="$(manifest_once pid)"
RUNS="$(manifest_once runs)"
LOADED_STDOUT="$(manifest_once stdout)"
LOADED_STDERR="$(manifest_once stderr)"
LOADED_MINIMUM_RUNTIME="$(manifest_once minimum-runtime)"
LOADED_PROPERTIES="$(manifest_once properties)"

[[ "$LOADED_PATH" == "$INSTALLED_LAUNCH_AGENT" ]] || fail \
    "launchd loaded plist is '$LOADED_PATH', expected '$INSTALLED_LAUNCH_AGENT'"
[[ "$LOADED_TYPE" == LaunchAgent ]] || fail "launchd job type is '$LOADED_TYPE', expected 'LaunchAgent'"
[[ "$LOADED_STATE" == running ]] || fail "launchd job state is '$LOADED_STATE', expected 'running'"
[[ "$PROGRAM" == "$REVIEWED_EXECUTABLE" ]] || fail \
    "launchd program is '$PROGRAM', expected '$REVIEWED_EXECUTABLE'"
[[ "$LOADED_STDOUT" == "$REVIEWED_STDOUT" ]] || fail "loaded stdout path is wrong"
[[ "$LOADED_STDERR" == "$REVIEWED_STDERR" ]] || fail "loaded stderr path is wrong"
[[ "$LOADED_MINIMUM_RUNTIME" == "$REVIEWED_THROTTLE" ]] || fail \
    "loaded minimum runtime is '$LOADED_MINIMUM_RUNTIME', expected '$REVIEWED_THROTTLE'"
[[ " $LOADED_PROPERTIES " == *" keepalive "* ]] || fail \
    "loaded launchd job is missing KeepAlive persistence"
[[ " $LOADED_PROPERTIES " == *" runatload "* ]] || fail \
    "loaded launchd job is missing RunAtLoad persistence"

ACTUAL_ARGUMENTS="$(print -r -- "$PARSED_LAUNCH_STATE" | /usr/bin/awk -F '\t' '$1 == "argument" { print substr($0, length($1) + 2) }')"
EXPECTED_ARGUMENTS="$(plist_arguments "$LAUNCH_AGENT_TEMPLATE")" || fail "could not read expected arguments"
[[ "$ACTUAL_ARGUMENTS" == "$EXPECTED_ARGUMENTS" ]] || fail \
    "live launchd arguments do not exactly match the reviewed LaunchAgent"

OVERRIDES="$(print -r -- "$PARSED_LAUNCH_STATE" | /usr/bin/awk -F '\t' '
    $1 == "environment-any" && ($2 == "OPENSTEAMER_RENDEZVOUS_URL" ||
        $2 == "AUDIOSTREAMER_RENDEZVOUS_URL" || $2 == "MCAP_TOKEN" || $2 ~ /^DYLD_/) { print $2 }
')"
[[ -z "$OVERRIDES" ]] || fail "loaded job contains behavior-overriding environment: ${(j:, :)${(f)OVERRIDES}}"

ENV_ERROR="$(print -r -- "$PARSED_LAUNCH_STATE" | /usr/bin/awk -F '\t' \
    -v expected_rate="$REVIEWED_RATE_LIMIT" -v expected_label="$REVIEWED_LABEL" '
    $1 == "job-environment" {
        if ($2 == "OSLogRateLimit") {
            rates += 1; if ($3 != expected_rate) bad="rate:" $3
        } else if ($2 == "XPC_SERVICE_NAME") {
            xpcs += 1; if ($3 != expected_label) bad="xpc:" $3
        } else if (bad == "") bad="unknown:" $2
    }
    END { if (rates < 1) print "missing-rate"; else print bad }
')"
case "$ENV_ERROR" in
    '') ;;
    missing-rate) fail "loaded launchd job is missing OSLogRateLimit" ;;
    rate:*) fail "loaded launchd OSLogRateLimit is '${ENV_ERROR#rate:}', expected '$REVIEWED_RATE_LIMIT'" ;;
    xpc:*) fail "loaded launchd XPC_SERVICE_NAME is '${ENV_ERROR#xpc:}', expected '$REVIEWED_LABEL'" ;;
    unknown:*) fail "loaded launchd job contains unreviewed environment key '${ENV_ERROR#unknown:}'" ;;
    *) fail "could not validate loaded launchd environment" ;;
esac

print -r -- "pid=$PID"
print -r -- "runs=$RUNS"
print -r -- "program=$PROGRAM"
