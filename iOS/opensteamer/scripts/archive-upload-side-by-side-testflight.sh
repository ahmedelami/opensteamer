#!/bin/zsh

# Guarded archive/upload path for the side-by-side TestFlight app. This script never accepts a
# caller-supplied bundle identifier, scheme, configuration, or filesystem destination. Before any
# archive it proves the effective Xcode settings use the isolated identity; before any upload it
# independently validates the finished archive's Info.plist and signing identifier.
set -euo pipefail

readonly EXPECTED_BUNDLE_IDENTIFIER="com.elamin.opensteamer"
readonly PROTECTED_BUNDLE_IDENTIFIER="com.elamin.AudioStreamer"
readonly EXPECTED_SCHEME="opensteamerTestFlight"
readonly EXPECTED_CONFIGURATION="TestFlight"
readonly EXPECTED_BUILD_NUMBER="37"
readonly EXPECTED_TEAM_ID="MSMG8CJLB3"
readonly EXPECTED_RENDEZVOUS_URL="wss://audiostreamer-rendezvous.elaminahmed03.workers.dev"

readonly SCRIPT_DIR=${0:A:h}
readonly PROJECT_DIR=${SCRIPT_DIR:h}
readonly PROJECT_PATH="${PROJECT_DIR}/opensteamer.xcodeproj"
readonly SCHEME_PATH="${PROJECT_PATH}/xcshareddata/xcschemes/${EXPECTED_SCHEME}.xcscheme"
readonly SCHEME_SOURCE_PATH="${PROJECT_DIR}/TestFlightScheme/${EXPECTED_SCHEME}.xcscheme"
readonly SCHEME_RESTORE_SCRIPT_PATH="${SCRIPT_DIR}/restore-archive-only-testflight-scheme.sh"
readonly EXPORT_OPTIONS_PATH="${PROJECT_DIR}/TestFlightExportOptions.plist"
readonly PRIVATE_TEMPORARY_ROOT="/private/tmp"
typeset SETTINGS_SCRATCH_DIRECTORY=""

function cleanup_settings_scratch() {
  if [[ -n "${SETTINGS_SCRATCH_DIRECTORY:-}" \
      && "${SETTINGS_SCRATCH_DIRECTORY}" == "${PRIVATE_TEMPORARY_ROOT}"/opensteamer-testflight-settings.* \
      && -d "${SETTINGS_SCRATCH_DIRECTORY}" ]]; then
    /bin/rm -rf -- "${SETTINGS_SCRATCH_DIRECTORY}"
  fi
  SETTINGS_SCRATCH_DIRECTORY=""
}

trap cleanup_settings_scratch EXIT INT TERM

function fail() {
  print -u2 -r -- "side-by-side TestFlight guard failed: $1"
  exit 1
}

function require_exact_plist_value() {
  local plist=$1
  local key_path=$2
  local expected=$3
  local description=$4
  local actual

  actual=$(/usr/bin/plutil -extract "${key_path}" raw -o - "${plist}" 2>/dev/null) \
    || fail "${description} is missing"
  [[ "${actual}" == "${expected}" ]] \
    || fail "${description} must be ${expected}, found ${actual}"
}

function effective_app_setting() {
  local settings_json=$1
  local key=$2
  /usr/bin/plutil -extract 0.buildSettings."${key}" raw -o - "${settings_json}" 2>/dev/null \
    || fail "effective ${key} is missing"
}

function verify_static_contract() {
  [[ "${EXPECTED_BUNDLE_IDENTIFIER}" != "${PROTECTED_BUNDLE_IDENTIFIER}" ]] \
    || fail "isolated and protected bundle identifiers are equal"
  [[ -d "${PROJECT_PATH}" ]] || fail "Xcode project is missing"
  [[ -f "${SCHEME_PATH}" ]] || fail "archive-only shared scheme is missing"
  [[ -f "${SCHEME_SOURCE_PATH}" && ! -L "${SCHEME_SOURCE_PATH}" ]] \
    || fail "reviewed archive-only scheme source is missing or is a symlink"
  [[ -x "${SCHEME_RESTORE_SCRIPT_PATH}" && ! -L "${SCHEME_RESTORE_SCRIPT_PATH}" ]] \
    || fail "XcodeGen archive-only scheme restorer is missing, non-executable, or a symlink"
  /usr/bin/cmp -s "${SCHEME_SOURCE_PATH}" "${SCHEME_PATH}" \
    || fail "generated scheme differs from the reviewed archive-only source"
  [[ -f "${EXPORT_OPTIONS_PATH}" ]] || fail "dedicated export options are missing"
  /usr/bin/xmllint --noout "${SCHEME_PATH}" >/dev/null 2>&1 \
    || fail "shared scheme is not valid XML"
  local archive_configuration
  archive_configuration=$(/usr/bin/xmllint --xpath \
    'string(/Scheme/ArchiveAction/@buildConfiguration)' "${SCHEME_PATH}" 2>/dev/null) \
    || fail "could not read archive configuration"
  [[ "${archive_configuration}" == "${EXPECTED_CONFIGURATION}" ]] \
    || fail "scheme archives ${archive_configuration}, not ${EXPECTED_CONFIGURATION}"
  local build_flags
  build_flags=$(/usr/bin/xmllint --xpath \
    'concat(string(/Scheme/BuildAction/BuildActionEntries/BuildActionEntry/@buildForTesting), "|", string(/Scheme/BuildAction/BuildActionEntries/BuildActionEntry/@buildForRunning), "|", string(/Scheme/BuildAction/BuildActionEntries/BuildActionEntry/@buildForProfiling), "|", string(/Scheme/BuildAction/BuildActionEntries/BuildActionEntry/@buildForArchiving), "|", string(/Scheme/BuildAction/BuildActionEntries/BuildActionEntry/@buildForAnalyzing))' \
    "${SCHEME_PATH}" 2>/dev/null) || fail "could not read scheme build flags"
  [[ "${build_flags}" == "NO|NO|NO|YES|NO" ]] \
    || fail "scheme is not archive-only"
  local nonarchive_actions
  nonarchive_actions=$(/usr/bin/xmllint --xpath \
    'count(/Scheme/TestAction | /Scheme/LaunchAction | /Scheme/ProfileAction | /Scheme/AnalyzeAction)' \
    "${SCHEME_PATH}" 2>/dev/null) || fail "could not inspect scheme actions"
  [[ "${nonarchive_actions}" == "0" ]] || fail "scheme exposes a non-archive action"

  /usr/bin/plutil -lint "${EXPORT_OPTIONS_PATH}" >/dev/null \
    || fail "export options are not a valid plist"
  require_exact_plist_value "${EXPORT_OPTIONS_PATH}" destination upload "export destination"
  require_exact_plist_value \
    "${EXPORT_OPTIONS_PATH}" method app-store-connect "export method"
  require_exact_plist_value \
    "${EXPORT_OPTIONS_PATH}" signingStyle automatic "export signing style"
  require_exact_plist_value "${EXPORT_OPTIONS_PATH}" teamID "${EXPECTED_TEAM_ID}" "export team"
  require_exact_plist_value \
    "${EXPORT_OPTIONS_PATH}" manageAppVersionAndBuildNumber false \
    "export build-number management"
  require_exact_plist_value \
    "${EXPORT_OPTIONS_PATH}" testFlightInternalTestingOnly true \
    "internal-only TestFlight policy"
  require_exact_plist_value \
    "${EXPORT_OPTIONS_PATH}" uploadSymbols true "symbol upload policy"
}

function verify_effective_build_settings() {
  SETTINGS_SCRATCH_DIRECTORY=$(/usr/bin/mktemp -d \
    "${PRIVATE_TEMPORARY_ROOT}/opensteamer-testflight-settings.XXXXXX") \
    || fail "could not create settings scratch directory"
  local settings_json="${SETTINGS_SCRATCH_DIRECTORY}/settings.json"

  /usr/bin/xcodebuild \
    -project "${PROJECT_PATH}" \
    -target opensteamer \
    -configuration "${EXPECTED_CONFIGURATION}" \
    -sdk iphoneos \
    -showBuildSettings \
    -json >"${settings_json}" \
    || fail "Xcode could not resolve archive build settings"

  local target_name
  target_name=$(/usr/bin/plutil -extract 0.target raw -o - "${settings_json}" 2>/dev/null) \
    || fail "resolved target is missing"
  [[ "${target_name}" == "opensteamer" ]] || fail "resolved unexpected target ${target_name}"

  local bundle_identifier
  bundle_identifier=$(effective_app_setting "${settings_json}" PRODUCT_BUNDLE_IDENTIFIER)
  [[ "${bundle_identifier}" != "${PROTECTED_BUNDLE_IDENTIFIER}" ]] \
    || fail "effective settings address the protected app"
  [[ "${bundle_identifier}" == "${EXPECTED_BUNDLE_IDENTIFIER}" ]] \
    || fail "effective bundle identifier is ${bundle_identifier}"
  [[ "$(effective_app_setting "${settings_json}" CONFIGURATION)" == "${EXPECTED_CONFIGURATION}" ]] \
    || fail "effective configuration is not ${EXPECTED_CONFIGURATION}"
  [[ "$(effective_app_setting "${settings_json}" CURRENT_PROJECT_VERSION)" == "${EXPECTED_BUILD_NUMBER}" ]] \
    || fail "effective build number is not ${EXPECTED_BUILD_NUMBER}"
  [[ "$(effective_app_setting "${settings_json}" DEVELOPMENT_TEAM)" == "${EXPECTED_TEAM_ID}" ]] \
    || fail "effective development team is not ${EXPECTED_TEAM_ID}"
  [[ "$(effective_app_setting "${settings_json}" OPENSTEAMER_RENDEZVOUS_URL)" == "${EXPECTED_RENDEZVOUS_URL}" ]] \
    || fail "effective rendezvous endpoint is not production"
  [[ "$(effective_app_setting "${settings_json}" AUDIOSTREAMER_RENDEZVOUS_URL)" == "${EXPECTED_RENDEZVOUS_URL}" ]] \
    || fail "compatibility rendezvous endpoint is not production"

  cleanup_settings_scratch
}

function verify_archive() {
  local archive_path=$1
  local archive_info="${archive_path}/Info.plist"
  local app_info="${archive_path}/Products/Applications/opensteamer.app/Info.plist"
  local app_path="${app_info:h}"
  [[ -f "${archive_info}" ]] || fail "archive Info.plist is missing"
  [[ -f "${app_info}" ]] || fail "archived app Info.plist is missing"

  require_exact_plist_value \
    "${archive_info}" ApplicationProperties.CFBundleIdentifier \
    "${EXPECTED_BUNDLE_IDENTIFIER}" "archive application identifier"
  require_exact_plist_value \
    "${app_info}" CFBundleIdentifier "${EXPECTED_BUNDLE_IDENTIFIER}" \
    "archived app bundle identifier"
  require_exact_plist_value \
    "${app_info}" CFBundleVersion "${EXPECTED_BUILD_NUMBER}" "archived app build number"
  require_exact_plist_value \
    "${app_info}" OpensteamerRendezvousURL "${EXPECTED_RENDEZVOUS_URL}" \
    "archived app rendezvous endpoint"
  require_exact_plist_value \
    "${app_info}" AudioStreamerRendezvousURL "${EXPECTED_RENDEZVOUS_URL}" \
    "archived app compatibility rendezvous endpoint"

  local signed_identifier
  local signature_metadata
  signature_metadata=$(/usr/bin/codesign -dv --verbose=4 "${app_path}" 2>&1) \
    || fail "could not inspect archived app signature"
  signed_identifier=$(print -r -- "${signature_metadata}" \
    | /usr/bin/awk -F= '$1 == "Identifier" { print $2 }')
  [[ "${signed_identifier}" == "${EXPECTED_BUNDLE_IDENTIFIER}" ]] \
    || fail "archived signature identifier is ${signed_identifier}"
  local signed_team_id
  signed_team_id=$(print -r -- "${signature_metadata}" \
    | /usr/bin/awk -F= '$1 == "TeamIdentifier" { print $2 }')
  [[ "${signed_team_id}" == "${EXPECTED_TEAM_ID}" ]] \
    || fail "archived signature team is ${signed_team_id}"
}

function create_safe_output_directory() {
  local output_directory
  output_directory=$(/usr/bin/mktemp -d \
    "${PRIVATE_TEMPORARY_ROOT}/opensteamer-testflight-output.XXXXXX") \
    || return 1
  [[ "${output_directory}" == "${PRIVATE_TEMPORARY_ROOT}"/opensteamer-testflight-output.* \
      && -d "${output_directory}" \
      && ! -L "${output_directory}" \
      && "$(/usr/bin/stat -f '%u:%Lp:%HT' "${output_directory}")" \
        == "${EUID}:700:Directory" ]] \
    || return 1
  print -r -- "${output_directory}"
}

function archive_side_by_side_app() {
  local output_directory=$1
  local archive_path="${output_directory}/opensteamerTestFlight.xcarchive"
  /usr/bin/xcodebuild archive \
    -project "${PROJECT_PATH}" \
    -scheme "${EXPECTED_SCHEME}" \
    -configuration "${EXPECTED_CONFIGURATION}" \
    -archivePath "${archive_path}" \
    -allowProvisioningUpdates \
    | /usr/bin/tee "${output_directory}/archive.log"
  verify_archive "${archive_path}"
}

function run_archive_only() {
  local output_directory
  output_directory=$(create_safe_output_directory) \
    || fail "could not create a private TestFlight output directory"
  archive_side_by_side_app "${output_directory}"
  print -- "side-by-side TestFlight archive verified: ${output_directory}/opensteamerTestFlight.xcarchive"
}

function run_authorized_upload() {
  local output_directory
  output_directory=$(create_safe_output_directory) \
    || fail "could not create a private TestFlight output directory"
  archive_side_by_side_app "${output_directory}"
  # No App Store Connect operation occurs before the completed archive passes verify_archive.
  /usr/bin/xcodebuild -exportArchive \
    -archivePath "${output_directory}/opensteamerTestFlight.xcarchive" \
    -exportOptionsPlist "${EXPORT_OPTIONS_PATH}" \
    -exportPath "${output_directory}/export" \
    -allowProvisioningUpdates \
    | /usr/bin/tee "${output_directory}/upload.log"
  print -- "side-by-side TestFlight upload completed; evidence: ${output_directory}"
}

verify_static_contract
verify_effective_build_settings

case "${1:-}" in
  --verify-config-only)
    (( $# == 1 )) || fail "--verify-config-only accepts no additional arguments"
    print -- "side-by-side TestFlight configuration verified"
    ;;
  --archive-only)
    (( $# == 1 )) || fail "--archive-only accepts no additional arguments"
    run_archive_only
    ;;
  --upload-authorized-side-by-side-testflight)
    (( $# == 1 )) || fail \
      "--upload-authorized-side-by-side-testflight accepts no additional arguments"
    run_authorized_upload
    ;;
  *)
    fail \
      "usage: $0 --verify-config-only | --archive-only | --upload-authorized-side-by-side-testflight"
    ;;
esac
