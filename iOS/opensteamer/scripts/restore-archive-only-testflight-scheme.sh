#!/bin/zsh

# XcodeGen 2.45 always emits run, test, profile, and analyze actions for a generated top-level
# scheme. Replace that generated file with the reviewed archive-only source after regeneration.
set -euo pipefail

readonly SCRIPT_DIR=${0:A:h}
readonly PROJECT_DIR=${SCRIPT_DIR:h}
readonly SOURCE_SCHEME="${PROJECT_DIR}/TestFlightScheme/opensteamerTestFlight.xcscheme"
readonly DESTINATION_SCHEME="${PROJECT_DIR}/opensteamer.xcodeproj/xcshareddata/xcschemes/opensteamerTestFlight.xcscheme"
readonly DESTINATION_DIRECTORY=${DESTINATION_SCHEME:h}
readonly CURRENT_UID=$(/usr/bin/id -u)
typeset TEMPORARY_SCHEME=""
typeset DESTINATION_SCHEME_ID=""

function fail() {
  print -u2 -r -- "archive-only TestFlight scheme restore failed: $1"
  exit 1
}

function clean_up() {
  if [[ -n "${TEMPORARY_SCHEME}" && -f "${TEMPORARY_SCHEME}" && ! -L "${TEMPORARY_SCHEME}" ]]; then
    /bin/rm -f "${TEMPORARY_SCHEME}"
  fi
}

trap clean_up EXIT INT TERM

(( $# == 0 )) || fail "this helper accepts no arguments"
[[ -f "${SOURCE_SCHEME}" && ! -L "${SOURCE_SCHEME}" ]] \
  || fail "reviewed source scheme is missing or is a symlink"
[[ -d "${DESTINATION_DIRECTORY}" && ! -L "${DESTINATION_DIRECTORY}" ]] \
  || fail "generated shared-scheme directory is missing or is a symlink"
[[ "${DESTINATION_DIRECTORY:A}" == "${DESTINATION_DIRECTORY}" ]] \
  || fail "generated shared-scheme directory resolves through a symlink"
[[ $(/usr/bin/stat -f '%u:%OLp' "${SOURCE_SCHEME}") == "${CURRENT_UID}:644" ]] \
  || fail "reviewed source scheme has an unexpected owner or mode"
[[ $(/usr/bin/stat -f '%u:%OLp' "${DESTINATION_DIRECTORY}") == "${CURRENT_UID}:755" ]] \
  || fail "generated shared-scheme directory has an unexpected owner or mode"
if [[ -e "${DESTINATION_SCHEME}" || -L "${DESTINATION_SCHEME}" ]]; then
  [[ -f "${DESTINATION_SCHEME}" && ! -L "${DESTINATION_SCHEME}" ]] \
    || fail "generated TestFlight scheme is non-regular or a symlink"
  [[ $(/usr/bin/stat -f '%u:%OLp' "${DESTINATION_SCHEME}") == "${CURRENT_UID}:644" ]] \
    || fail "generated TestFlight scheme has an unexpected owner or mode"
  DESTINATION_SCHEME_ID=$(/usr/bin/stat -f '%d:%i' "${DESTINATION_SCHEME}")
fi
readonly DESTINATION_DIRECTORY_ID=$(/usr/bin/stat -f '%d:%i' "${DESTINATION_DIRECTORY}")
/usr/bin/xmllint --noout "${SOURCE_SCHEME}" >/dev/null 2>&1 \
  || fail "reviewed source scheme is not valid XML"

readonly ARCHIVE_CONFIGURATION=$(/usr/bin/xmllint --xpath \
  'string(/Scheme/ArchiveAction/@buildConfiguration)' "${SOURCE_SCHEME}" 2>/dev/null)
[[ "${ARCHIVE_CONFIGURATION}" == "TestFlight" ]] \
  || fail "reviewed source scheme does not archive TestFlight"
readonly BUILD_FLAGS=$(/usr/bin/xmllint --xpath \
  'concat(string(/Scheme/BuildAction/BuildActionEntries/BuildActionEntry/@buildForTesting), "|", string(/Scheme/BuildAction/BuildActionEntries/BuildActionEntry/@buildForRunning), "|", string(/Scheme/BuildAction/BuildActionEntries/BuildActionEntry/@buildForProfiling), "|", string(/Scheme/BuildAction/BuildActionEntries/BuildActionEntry/@buildForArchiving), "|", string(/Scheme/BuildAction/BuildActionEntries/BuildActionEntry/@buildForAnalyzing))' \
  "${SOURCE_SCHEME}" 2>/dev/null)
[[ "${BUILD_FLAGS}" == "NO|NO|NO|YES|NO" ]] \
  || fail "reviewed source scheme is not archive-only"
readonly NONARCHIVE_ACTION_COUNT=$(/usr/bin/xmllint --xpath \
  'count(/Scheme/TestAction | /Scheme/LaunchAction | /Scheme/ProfileAction | /Scheme/AnalyzeAction)' \
  "${SOURCE_SCHEME}" 2>/dev/null)
[[ "${NONARCHIVE_ACTION_COUNT}" == "0" ]] \
  || fail "reviewed source scheme contains a non-archive action"

umask 077
TEMPORARY_SCHEME=$(/usr/bin/mktemp \
  "${DESTINATION_DIRECTORY}/.opensteamerTestFlight.xcscheme.XXXXXX") \
  || fail "could not create a private same-directory temporary scheme"
[[ -f "${TEMPORARY_SCHEME}" && ! -L "${TEMPORARY_SCHEME}" ]] \
  || fail "same-directory temporary scheme is not a regular file"
[[ $(/usr/bin/stat -f '%u:%OLp' "${TEMPORARY_SCHEME}") == "${CURRENT_UID}:600" ]] \
  || fail "same-directory temporary scheme has an unexpected owner or mode"
/bin/cp "${SOURCE_SCHEME}" "${TEMPORARY_SCHEME}" \
  || fail "could not stage the reviewed archive-only scheme"
/bin/chmod 644 "${TEMPORARY_SCHEME}" \
  || fail "could not set the staged scheme mode"
/usr/bin/cmp -s "${SOURCE_SCHEME}" "${TEMPORARY_SCHEME}" \
  || fail "staged scheme differs from its reviewed source"

[[ $(/usr/bin/stat -f '%d:%i' "${DESTINATION_DIRECTORY}") == "${DESTINATION_DIRECTORY_ID}" ]] \
  || fail "generated shared-scheme directory changed during restoration"
if [[ -n "${DESTINATION_SCHEME_ID}" ]]; then
  [[ -f "${DESTINATION_SCHEME}" && ! -L "${DESTINATION_SCHEME}" ]] \
    || fail "generated TestFlight scheme changed type during restoration"
  [[ $(/usr/bin/stat -f '%d:%i' "${DESTINATION_SCHEME}") == "${DESTINATION_SCHEME_ID}" ]] \
    || fail "generated TestFlight scheme changed during restoration"
else
  [[ ! -e "${DESTINATION_SCHEME}" && ! -L "${DESTINATION_SCHEME}" ]] \
    || fail "generated TestFlight scheme appeared during restoration"
fi
/bin/mv -f "${TEMPORARY_SCHEME}" "${DESTINATION_SCHEME}" \
  || fail "could not atomically restore the reviewed archive-only scheme"
TEMPORARY_SCHEME=""
[[ -f "${DESTINATION_SCHEME}" && ! -L "${DESTINATION_SCHEME}" ]] \
  || fail "restored scheme is not a regular file"
[[ $(/usr/bin/stat -f '%u:%OLp' "${DESTINATION_SCHEME}") == "${CURRENT_UID}:644" ]] \
  || fail "restored scheme has an unexpected owner or mode"
/usr/bin/cmp -s "${SOURCE_SCHEME}" "${DESTINATION_SCHEME}" \
  || fail "restored scheme differs from its reviewed source"
