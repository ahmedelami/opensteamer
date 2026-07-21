#!/bin/zsh
# Read-only validator for a captured `launchctl print` record and its LaunchAgent manifests.
#
# Usage: provide the launch-state snapshot, expected executable, source-controlled plist, and
# installed plist. The snapshot must use macOS `launchctl print` text format; plist inputs may be
# XML or binary. Standard macOS `plutil` and PlistBuddy are required.
#
# The script checks semantic manifest equality, persistence flags, exact program arguments, and the
# complete job-scoped environment before returning `pid` and `program` as key=value lines. It does
# not load or alter a job. Argument-count errors exit 64; invalid inputs or state exit 1 on stderr.
set -eu

fail() {
    print -u2 -- "verify-mac-host-launch-state: $*"
    exit 1
}

if (( $# != 4 )); then
    print -u2 -- \
        "usage: $0 <launchctl-print-file> <expected-executable> <launch-agent-template> <installed-launch-agent>"
    exit 64
fi

LAUNCH_STATE_FILE="$1"
EXPECTED_EXECUTABLE="$2"
LAUNCH_AGENT_TEMPLATE="$3"
INSTALLED_LAUNCH_AGENT="$4"

[[ -f "$LAUNCH_STATE_FILE" ]] || fail \
    "launchctl state file does not exist: $LAUNCH_STATE_FILE"
[[ -f "$LAUNCH_AGENT_TEMPLATE" ]] || fail \
    "source-controlled LaunchAgent template does not exist: $LAUNCH_AGENT_TEMPLATE"
[[ -f "$INSTALLED_LAUNCH_AGENT" ]] || fail \
    "installed LaunchAgent plist does not exist: $INSTALLED_LAUNCH_AGENT"
[[ ! -L "$LAUNCH_AGENT_TEMPLATE" ]] || fail \
    "source-controlled LaunchAgent template must not be a symbolic link"
[[ ! -L "$INSTALLED_LAUNCH_AGENT" ]] || fail \
    "installed LaunchAgent plist must not be a symbolic link"
/usr/bin/plutil -lint "$LAUNCH_AGENT_TEMPLATE" >/dev/null || fail \
    "source-controlled LaunchAgent template is not a valid property list"
/usr/bin/plutil -lint "$INSTALLED_LAUNCH_AGENT" >/dev/null || fail \
    "installed LaunchAgent is not a valid property list"

# The installed manifest is an executable part of the release artifact. Compare
# canonical XML so dictionary ordering, indentation, and binary-vs-XML encoding
# do not create a false failure, while every property-list value still must match.
SOURCE_CANONICAL_PLIST="$(/usr/bin/plutil \
    -convert xml1 -o - "$LAUNCH_AGENT_TEMPLATE")" || fail \
    "could not canonicalize the source-controlled LaunchAgent template"
INSTALLED_CANONICAL_PLIST="$(/usr/bin/plutil \
    -convert xml1 -o - "$INSTALLED_LAUNCH_AGENT")" || fail \
    "could not canonicalize the installed LaunchAgent plist"
[[ "$SOURCE_CANONICAL_PLIST" == "$INSTALLED_CANONICAL_PLIST" ]] || fail \
    "installed LaunchAgent plist differs from the source-controlled template"

SOURCE_RUN_AT_LOAD="$(/usr/libexec/PlistBuddy \
    -c "Print :RunAtLoad" "$LAUNCH_AGENT_TEMPLATE" 2>/dev/null || true)"
[[ "$SOURCE_RUN_AT_LOAD" == "true" ]] || fail \
    "source-controlled LaunchAgent requires RunAtLoad=true"
SOURCE_KEEP_ALIVE="$(/usr/libexec/PlistBuddy \
    -c "Print :KeepAlive" "$LAUNCH_AGENT_TEMPLATE" 2>/dev/null || true)"
[[ "$SOURCE_KEEP_ALIVE" == "true" ]] || fail \
    "source-controlled LaunchAgent requires KeepAlive=true"
SOURCE_OS_LOG_RATE_LIMIT="$(/usr/libexec/PlistBuddy \
    -c "Print :EnvironmentVariables:OSLogRateLimit" \
    "$LAUNCH_AGENT_TEMPLATE" 2>/dev/null || true)"
[[ "$SOURCE_OS_LOG_RATE_LIMIT" == "64" ]] || fail \
    "source-controlled LaunchAgent requires EnvironmentVariables.OSLogRateLimit=64"
SOURCE_LABEL="$(/usr/libexec/PlistBuddy \
    -c "Print :Label" "$LAUNCH_AGENT_TEMPLATE" 2>/dev/null || true)"
[[ -n "$SOURCE_LABEL" ]] || fail \
    "source-controlled LaunchAgent requires a Label"

LAUNCH_STATE="$(<"$LAUNCH_STATE_FILE")"
# Parsing deliberately anchors complete `launchctl print` fields instead of accepting substrings;
# loose matching could mistake inherited/default environment or diagnostic text for job state.
LOADED_PATH="$(print -r -- "$LAUNCH_STATE" \
    | /usr/bin/awk '$1 == "path" && $2 == "=" { sub(/^[^=]*= /, ""); print; exit }')"
[[ "$LOADED_PATH" == "$INSTALLED_LAUNCH_AGENT" ]] || fail \
    "launchd loaded plist is '$LOADED_PATH', expected '$INSTALLED_LAUNCH_AGENT'"

LOADED_TYPE="$(print -r -- "$LAUNCH_STATE" \
    | /usr/bin/awk '$1 == "type" && $2 == "=" { print $3; exit }')"
[[ "$LOADED_TYPE" == "LaunchAgent" ]] || fail \
    "launchd job type is '$LOADED_TYPE', expected 'LaunchAgent'"

has_loaded_property() {
    local expected_property="$1"
    print -r -- "$LAUNCH_STATE" | /usr/bin/awk -v expected="$expected_property" '
        $1 == "properties" && $2 == "=" {
            for (field_index = 3; field_index <= NF; field_index += 1) {
                if ($field_index == expected) {
                    found = 1
                }
            }
        }
        END { exit(found ? 0 : 1) }
    '
}
has_loaded_property "runatload" || fail \
    "loaded launchd job is missing RunAtLoad persistence"
has_loaded_property "keepalive" || fail \
    "loaded launchd job is missing KeepAlive persistence"

PROGRAM="$(print -r -- "$LAUNCH_STATE" \
    | /usr/bin/awk '$1 == "program" && $2 == "=" { sub(/^[^=]*= /, ""); print; exit }')"
[[ "$PROGRAM" == "$EXPECTED_EXECUTABLE" ]] || fail \
    "launchd program is '$PROGRAM', expected '$EXPECTED_EXECUTABLE'"

ACTUAL_ARGUMENTS="$(print -r -- "$LAUNCH_STATE" | /usr/bin/awk '
    $1 == "arguments" && $2 == "=" && $3 == "{" { inside = 1; next }
    inside && $1 == "}" { exit }
    inside { sub(/^[[:space:]]+/, ""); print }
')"

EXPECTED_ARGUMENTS=()
# PlistBuddy reports a missing array index by failing, which provides the array termination signal.
argument_index=0
while argument="$(/usr/libexec/PlistBuddy \
    -c "Print :ProgramArguments:$argument_index" \
    "$LAUNCH_AGENT_TEMPLATE" 2>/dev/null)"; do
    EXPECTED_ARGUMENTS+=("$argument")
    argument_index=$((argument_index + 1))
done
(( ${#EXPECTED_ARGUMENTS[@]} > 0 )) || fail \
    "LaunchAgent template has no ProgramArguments"
[[ "${EXPECTED_ARGUMENTS[1]}" == "$EXPECTED_EXECUTABLE" ]] || fail \
    "LaunchAgent template does not target '$EXPECTED_EXECUTABLE'"
EXPECTED_ARGUMENT_LINES="$(printf '%s\n' "${EXPECTED_ARGUMENTS[@]}")"
[[ "$ACTUAL_ARGUMENTS" == "$EXPECTED_ARGUMENT_LINES" ]] || fail \
    "live launchd arguments do not exactly match the source-controlled LaunchAgent"

# These variables change the endpoint/authentication selected by CaptureServer,
# or permit dynamic-loader injection. They may appear in any launchctl
# environment section, so inspect the loaded job rather than only the plist.
OVERRIDING_ENVIRONMENT_KEYS="$(print -r -- "$LAUNCH_STATE" | /usr/bin/awk '
    $2 == "=>" && ($1 == "OPENSTEAMER_RENDEZVOUS_URL" ||
                    $1 == "AUDIOSTREAMER_RENDEZVOUS_URL" ||
                    $1 == "MCAP_TOKEN" ||
                    $1 ~ /^DYLD_/) { print $1 }
')"
[[ -z "$OVERRIDING_ENVIRONMENT_KEYS" ]] || fail \
    "loaded job contains behavior-overriding environment: ${(j:, :)${(f)OVERRIDING_ENVIRONMENT_KEYS}}"

# Comparing the installed plist to the source template is insufficient: launchd
# can still be running an older in-memory job. Validate the complete job-scoped
# environment rather than a denylist. macOS 26 can print an identical value
# twice; repetition is harmless only when every full value is exact.
JOB_ENVIRONMENT_ERROR="$(print -r -- "$LAUNCH_STATE" | /usr/bin/awk \
    -v expected_rate="$SOURCE_OS_LOG_RATE_LIMIT" \
    -v expected_label="$SOURCE_LABEL" '
    function full_value(    value, field_index) {
        value = $3
        for (field_index = 4; field_index <= NF; field_index += 1) {
            value = value " " $field_index
        }
        return value
    }
    $1 == "environment" && $2 == "=" && $3 == "{" {
        inside = 1
        found_block = 1
        next
    }
    inside && $1 == "}" { inside = 0; next }
    inside && NF > 0 {
        value = full_value()
        if ($1 == "OSLogRateLimit") {
            found_rate += 1
            if ($2 != "=>" || NF != 3 || value != expected_rate) {
                if (error == "") error = "rate:" value
            }
        } else if ($1 == "XPC_SERVICE_NAME") {
            found_xpc += 1
            if ($2 != "=>" || NF != 3 || value != expected_label) {
                if (error == "") error = "xpc:" value
            }
        } else if (error == "") {
            error = "unknown:" $1
        }
    }
    END {
        if (!found_block) print "missing-block"
        else if (!found_rate) print "missing-rate"
        else print error
    }
')"
case "$JOB_ENVIRONMENT_ERROR" in
    "") ;;
    missing-block) fail "loaded launchd job is missing its environment block" ;;
    missing-rate) fail "loaded launchd job is missing OSLogRateLimit" ;;
    rate:*) fail \
        "loaded launchd OSLogRateLimit is '${JOB_ENVIRONMENT_ERROR#rate:}', expected '$SOURCE_OS_LOG_RATE_LIMIT'" ;;
    xpc:*) fail \
        "loaded launchd XPC_SERVICE_NAME is '${JOB_ENVIRONMENT_ERROR#xpc:}', expected '$SOURCE_LABEL'" ;;
    unknown:*) fail \
        "loaded launchd job contains unreviewed environment key '${JOB_ENVIRONMENT_ERROR#unknown:}'" ;;
    *) fail "could not validate loaded launchd environment" ;;
esac

PID="$(print -r -- "$LAUNCH_STATE" \
    | /usr/bin/awk '$1 == "pid" && $2 == "=" && $3 ~ /^[0-9]+$/ { print $3; exit }')"
[[ -n "$PID" ]] || fail "launch agent has no running PID"

# Keep stdout machine-readable for `verify-mac-host-deployment.sh`.
print -r -- "pid=$PID"
print -r -- "program=$PROGRAM"
