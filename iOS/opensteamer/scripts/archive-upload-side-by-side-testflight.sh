#!/bin/zsh

# Guarded archive/upload path for the side-by-side TestFlight app. This script never accepts a
# caller-supplied bundle identifier, scheme, configuration, or filesystem destination. Before any
# archive it proves the effective Xcode settings use the isolated identity; before any upload it
# independently validates the finished archive's Info.plist and signing identifier.
# `--verify-api-key-config-only` is an offline file/argument pin check; only the explicit API-key
# upload mode can prove that the team-scoped key is active and authorized for archive/export.
set -euo pipefail
zmodload zsh/system || {
  print -u2 -r -- 'side-by-side TestFlight guard failed: zsh/system is unavailable'
  exit 1
}

readonly EXPECTED_BUNDLE_IDENTIFIER="com.elamin.opensteamer"
readonly PROTECTED_BUNDLE_IDENTIFIER="com.elamin.AudioStreamer"
readonly EXPECTED_SCHEME="opensteamerTestFlight"
readonly EXPECTED_CONFIGURATION="TestFlight"
readonly EXPECTED_BUILD_NUMBER="46"
readonly EXPECTED_SHORT_VERSION="0.1.0"
readonly EXPECTED_TEAM_ID="MSMG8CJLB3"
readonly EXPECTED_ARCHIVE_SIGNING_IDENTITY="Apple Development: Ahmed Elamin (92LVX32M8K)"
readonly EXPECTED_ASC_APPLE_ID="6797410161"
readonly EXPECTED_ASC_TEAM_ISSUER_ID="98529b8c-9fa6-4799-bcb1-7ef7c85a83d3"
readonly EXPECTED_ASC_API_KEY_ID="WPN8WJYC7H"
readonly EXPECTED_ASC_API_KEY_DIRECTORY="/Users/ahmed/Library/Application Support/opensteamer-release-credentials"
readonly EXPECTED_ASC_API_KEY_PATH="${EXPECTED_ASC_API_KEY_DIRECTORY}/AuthKey_${EXPECTED_ASC_API_KEY_ID}.p8"
readonly EXPECTED_ASC_API_KEY_OWNER_UID="501"
readonly EXPECTED_ASC_API_KEY_OWNER_GID="20"
readonly EXPECTED_ASC_API_KEY_DIRECTORY_MODE="700"
readonly EXPECTED_ASC_API_KEY_FILE_MODE="600"
readonly EXPECTED_ASC_P8_SHA256="22d0dffa775141c5bedb6eb255fb909f50f0547f1997f2ff9ad92609afce5300"
readonly -a EXPECTED_ASC_API_KEY_XCODEBUILD_ARGUMENTS=(
  -authenticationKeyPath "${EXPECTED_ASC_API_KEY_PATH}"
  -authenticationKeyID "${EXPECTED_ASC_API_KEY_ID}"
  -authenticationKeyIssuerID "${EXPECTED_ASC_TEAM_ISSUER_ID}"
)
readonly EXPECTED_ASC_API_KEY_XCODEBUILD_ARGUMENTS_SHA256="8116cc2c29c6b7781770f13ca76f39a605d705655f7a619907ec21ac9afb7399"
readonly EXPECTED_DISTRIBUTION_CERTIFICATE_SHA1="CEB61B792A7A5848E9E797BB2E44EA2642611A6F"
readonly EXPECTED_RENDEZVOUS_URL="wss://audiostreamer-rendezvous.elaminahmed03.workers.dev"
readonly PROTECTED_LEGACY_LAUNCH_AGENT_PATH="/Users/ahmed/Library/LaunchAgents/com.elamin.audiostreamer.worldwide.plist"
readonly PROTECTED_LAUNCH_AGENTS_DIRECTORY="/Users/ahmed/Library/LaunchAgents"
readonly PROTECTED_OPENSTEAMER_APPLICATION_SUPPORT_DIRECTORY="/Users/ahmed/Library/Application Support/opensteamer"
readonly PROTECTED_MIGRATION_EVIDENCE_DIRECTORY="/Users/ahmed/Library/Application Support/opensteamer/migrations"

readonly SCRIPT_DIR=${0:A:h}
readonly PROJECT_DIR=${SCRIPT_DIR:h}
readonly REPOSITORY_ROOT=${PROJECT_DIR:h:h}
readonly PROJECT_PATH="${PROJECT_DIR}/opensteamer.xcodeproj"
readonly SCHEME_PATH="${PROJECT_PATH}/xcshareddata/xcschemes/${EXPECTED_SCHEME}.xcscheme"
readonly SCHEME_SOURCE_PATH="${PROJECT_DIR}/TestFlightScheme/${EXPECTED_SCHEME}.xcscheme"
readonly SCHEME_RESTORE_SCRIPT_PATH="${SCRIPT_DIR}/restore-archive-only-testflight-scheme.sh"
readonly EXPORT_OPTIONS_PATH="${PROJECT_DIR}/TestFlightExportOptions.plist"
readonly PRIVATE_TEMPORARY_ROOT="/private/tmp"
readonly XCODE_TMP_ALIAS_ROOT="/tmp"
readonly TESTFLIGHT_BUILD_ROOT="/Volumes/t7"
readonly TESTFLIGHT_BUILD_IMAGE_SIZE="64g"
readonly TESTFLIGHT_BUILD_IMAGE_BASENAME="opensteamer-testflight-build"
readonly TESTFLIGHT_BUILD_VOLUME_NAME="opensteamer-testflight-build"
# hdiutil's public single-file sparse creation mode is called UDSP, while
# `hdiutil imageinfo -plist` identifies the resulting single-file sparse
# container with the exact on-disk FourCC `SPRS` on this pinned macOS runtime.
readonly TESTFLIGHT_BUILD_IMAGE_FORMAT="SPRS"
readonly APFS_PARTITION_TYPE_UUID="7C3457EF-0000-11AA-AA11-00306543ECAC"
readonly EXPECTED_TESTFLIGHT_BUILD_ROOT_VOLUME_UUID="25E93573-3993-42CC-8EE8-4F7A6C86A2EF"
readonly EXPECTED_TESTFLIGHT_BUILD_ROOT_PHYSICAL_STORE_UUID="CE1B73D9-E28D-40D2-8D37-D81F2C3F1051"
readonly EXPECTED_TESTFLIGHT_BUILD_ROOT_VOLUME_NAME="t7"
readonly EXPECTED_TESTFLIGHT_BUILD_ROOT_BUS_PROTOCOL="USB"
readonly EXPECTED_TESTFLIGHT_BUILD_ROOT_MEDIA_NAME="PSSD T7"
readonly EXPECTED_TESTFLIGHT_BUILD_ROOT_PHYSICAL_SIZE="1000204886016"
readonly EXPECTED_TESTFLIGHT_BUILD_ROOT_CONTAINER_SIZE="999995129856"
readonly EXPECTED_XCODE_ALIAS_PATH="/Applications/Xcode-26.6.0.app"
readonly EXPECTED_XCODE_SELECTED_DEVELOPER_PATH="${EXPECTED_XCODE_ALIAS_PATH}/Contents/Developer"
readonly EXPECTED_XCODE_REAL_BUNDLE_PATH="${TESTFLIGHT_BUILD_ROOT}/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app"
readonly EXPECTED_XCODE_REAL_DEVELOPER_PATH="${EXPECTED_XCODE_REAL_BUNDLE_PATH}/Contents/Developer"
readonly EXPECTED_XCODEBUILD_REAL_PATH="${EXPECTED_XCODE_REAL_DEVELOPER_PATH}/usr/bin/xcodebuild"
readonly EXPECTED_XCODE_BUNDLE_IDENTIFIER="com.apple.dt.Xcode"
readonly EXPECTED_XCODEBUILD_IDENTIFIER="com.apple.dt.xcodebuild"
readonly EXPECTED_XCODE_SIGNING_TEAM_ID="59GAB85EFG"
readonly EXPECTED_XCODE_VERSION="26.6"
readonly EXPECTED_XCODE_BUILD_VERSION="17F113"
readonly EXPECTED_XCODE_BUNDLE_CD_HASH="2c63b15a7f956c25ec75238dc1006a0f6227589a"
readonly EXPECTED_XCODEBUILD_CD_HASH="335573a2d481a0021e20d7c8b6e2768e407e0f26"
readonly EXPECTED_XCODE_INFO_SHA256="224c27a718df1d8b4e785d29d06259e0a9326c424e70d30efab9c587463f719a"
readonly EXPECTED_XCODE_VERSION_SHA256="951ddf34d65d84d57684bd083ca7deebf8d5722eefb074f3cdf00f8304d5f511"
readonly EXPECTED_XCODEBUILD_SHA256="d508f0e1901151843804e4af512d4587ad0e422039e43e14abf22792360ad3d4"
readonly PACKAGE_MANIFEST_PATH="${REPOSITORY_ROOT}/Package.swift"
readonly PACKAGE_RESOLVED_PATH="${REPOSITORY_ROOT}/Package.resolved"
readonly EXPECTED_PACKAGE_MANIFEST_SHA256="9c02a86ef1f8257dcd67af517ba35fca50bba0a94b865fd4dacfe476b9c7ed52"
readonly EXPECTED_PACKAGE_RESOLVED_SHA256="161213e9507513e41f0acba0d7439fcf633b9d03d78c22b1e4b15fa9f83a01d9"
readonly EXPECTED_APPLICATION_IDENTIFIER="${EXPECTED_TEAM_ID}.${EXPECTED_BUNDLE_IDENTIFIER}"
readonly PROTECTED_APPLICATION_IDENTIFIER="${EXPECTED_TEAM_ID}.${PROTECTED_BUNDLE_IDENTIFIER}"
readonly -a REJECTED_BUILD_ENVIRONMENT_VARIABLES=(
  BUILD_DIR
  BUILT_PRODUCTS_DIR
  BUILD_ROOT
  CODE_SIGN_IDENTITY
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS
  CODE_SIGN_STYLE
  CACHE_ROOT
  CCHROOT
  CLANG_MODULE_CACHE_PATH
  CONFIGURATION_BUILD_DIR
  CONFIGURATION_TEMP_DIR
  CURRENT_PROJECT_VERSION
  DERIVED_DATA_DIR
  DERIVED_FILE_DIR
  DERIVED_FILES_DIR
  DERIVED_SOURCES_DIR
  DEVELOPMENT_TEAM
  DEVELOPER_DIR
  DSTROOT
  DWARF_DSYM_FOLDER_PATH
  EXPANDED_CODE_SIGN_IDENTITY
  INDEX_DATA_STORE_DIR
  INSTALL_DIR
  INSTALL_ROOT
  LOCSYMROOT
  MODULE_CACHE_DIR
  OBJECT_FILE_DIR
  OBJECT_FILE_DIR_normal
  OBJROOT
  OPENSTEAMER_RENDEZVOUS_URL
  OTHER_CODE_SIGN_FLAGS
  PRODUCT_BUNDLE_IDENTIFIER
  PROJECT_DERIVED_DATA_DIR
  PROJECT_DERIVED_FILE_DIR
  PROVISIONING_PROFILE
  PROVISIONING_PROFILE_SPECIFIER
  PROJECT_TEMP_DIR
  PROJECT_TEMP_ROOT
  SHARED_PRECOMPS_DIR
  SOURCE_PACKAGES_DIR_PATH
  SDKROOT
  SHARED_DERIVED_FILE_DIR
  SWIFT_MODULE_CACHE_PATH
  SWIFTPM_MODULECACHE_OVERRIDE
  SYMROOT
  TARGET_BUILD_DIR
  TARGET_TEMP_DIR
  TEMP_DIR
  TEMP_FILES_DIR
  TEMP_ROOT
  TOOLCHAINS
  REZ_COLLECTOR_DIR
  XCODEBUILD_XCCONFIG_FILE
  XCODE_DEFAULT_TOOLCHAIN_OVERRIDE
  XCODE_XCCONFIG_FILE
  XDG_CACHE_HOME
)
typeset TESTFLIGHT_CONTROL_DIRECTORY=""
typeset TESTFLIGHT_CONTROL_DIRECTORY_IDENTITY=""
typeset TESTFLIGHT_CONTROL_PARENT_IDENTITY=""
typeset TESTFLIGHT_BUILD_MOUNT_POINT=""
typeset TESTFLIGHT_BUILD_MOUNT_POINT_UNDERLAY_IDENTITY=""
typeset TESTFLIGHT_BUILD_IMAGE_CONTAINER=""
typeset TESTFLIGHT_BUILD_IMAGE_CONTAINER_IDENTITY=""
typeset TESTFLIGHT_BUILD_IMAGE_PATH=""
typeset TESTFLIGHT_BUILD_IMAGE_IDENTITY=""
typeset TESTFLIGHT_BUILD_IMAGE_PARTITION_UUID=""
typeset TESTFLIGHT_BUILD_KEY_PATH=""
typeset TESTFLIGHT_BUILD_KEY_IDENTITY=""
typeset -i TESTFLIGHT_BUILD_KEY_FD=-1
typeset TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH=""
typeset TESTFLIGHT_XCODE_SANDBOX_PROFILE_IDENTITY=""
typeset TESTFLIGHT_XCODE_SANDBOX_PROFILE_SHA256=""
typeset -i TESTFLIGHT_XCODE_SANDBOX_PROFILE_FD=-1
typeset TESTFLIGHT_BUILD_ROOT_PARENT_IDENTITY=""
typeset TESTFLIGHT_BUILD_ROOT_IDENTITY=""
typeset TESTFLIGHT_BUILD_ROOT_DEVICE_IDENTIFIER=""
typeset TESTFLIGHT_BUILD_ROOT_PARENT_WHOLE_DISK=""
typeset TESTFLIGHT_BUILD_ROOT_VOLUME_UUID=""
typeset TESTFLIGHT_BUILD_ROOT_PHYSICAL_STORE_IDENTIFIER=""
typeset TESTFLIGHT_BUILD_ROOT_PHYSICAL_WHOLE_DISK=""
typeset TESTFLIGHT_XCODE_ALIAS_IDENTITY=""
typeset TESTFLIGHT_XCODE_BUNDLE_IDENTITY=""
typeset TESTFLIGHT_XCODE_DEVELOPER_IDENTITY=""
typeset TESTFLIGHT_XCODEBUILD_IDENTITY=""
typeset TESTFLIGHT_XCODE_VOLUME_ROOT_IDENTITY=""
typeset TESTFLIGHT_XCODE_VOLUME_DEVICE_IDENTIFIER=""
typeset TESTFLIGHT_XCODE_VOLUME_PARENT_WHOLE_DISK=""
typeset TESTFLIGHT_XCODE_PHYSICAL_STORE_IDENTIFIER=""
typeset TESTFLIGHT_XCODE_PHYSICAL_WHOLE_DISK=""
typeset -i TESTFLIGHT_XCODE_DEEP_SIGNATURE_VERIFIED=0
typeset TESTFLIGHT_IMAGE_DEVICE=""
typeset TESTFLIGHT_IMAGE_PARTITION_DEVICE=""
typeset TESTFLIGHT_MOUNTED_DEVICE=""
typeset TESTFLIGHT_MOUNTED_DEVICE_IDENTIFIER=""
typeset TESTFLIGHT_MOUNTED_PARENT_WHOLE_DISK=""
typeset TESTFLIGHT_MOUNTED_VOLUME_UUID=""
typeset TESTFLIGHT_MOUNTED_VOLUME_ROOT_IDENTITY=""
typeset TESTFLIGHT_DERIVED_DATA_DIRECTORY=""
typeset TESTFLIGHT_DERIVED_DATA_IDENTITY=""
typeset TESTFLIGHT_BUILD_SANDBOX_DIRECTORY=""
typeset TESTFLIGHT_BUILD_SANDBOX_IDENTITY=""
typeset TESTFLIGHT_BUILD_TMP_DIRECTORY=""
typeset TESTFLIGHT_BUILD_PRODUCTS_DIRECTORY=""
typeset TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY=""
typeset TESTFLIGHT_BUILD_DSTROOT_DIRECTORY=""
typeset TESTFLIGHT_BUILD_PRECOMPILED_DIRECTORY=""
typeset TESTFLIGHT_BUILD_CACHE_DIRECTORY=""
typeset TESTFLIGHT_BUILD_MODULE_CACHE_DIRECTORY=""
typeset TESTFLIGHT_BUILD_PACKAGE_CACHE_DIRECTORY=""
typeset TESTFLIGHT_BUILD_SOURCE_PACKAGES_DIRECTORY=""
typeset -a TESTFLIGHT_PINNED_BUILD_DIRECTORIES=()
typeset -a TESTFLIGHT_XCODEBUILD_PINNED_ARGUMENTS=()
typeset TESTFLIGHT_XCODEBUILD_PINNED_ARGUMENTS_SHA256=""
typeset -a TESTFLIGHT_XCODEBUILD_PINNED_ENVIRONMENT=()
typeset TESTFLIGHT_XCODEBUILD_PINNED_ENVIRONMENT_SHA256=""
typeset TESTFLIGHT_OUTPUT_DIRECTORY=""
typeset TESTFLIGHT_OUTPUT_DIRECTORY_IDENTITY=""
typeset TESTFLIGHT_OUTPUT_PARENT_IDENTITY=""
typeset -i TESTFLIGHT_OUTPUT_DIRECTORY_FD=-1
typeset TESTFLIGHT_VERIFICATION_SCRATCH_DIRECTORY=""
typeset TESTFLIGHT_VERIFICATION_SCRATCH_DIRECTORY_IDENTITY=""
typeset -i TESTFLIGHT_VERIFICATION_SCRATCH_DIRECTORY_FD=-1
typeset TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY=""
typeset TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY_IDENTITY=""
typeset -i TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY_FD=-1
typeset TESTFLIGHT_ARCHIVE_LOG_PATH=""
typeset TESTFLIGHT_ARCHIVE_LOG_IDENTITY=""
typeset -i TESTFLIGHT_ARCHIVE_LOG_FD=-1
typeset TESTFLIGHT_EXPORT_DIRECTORY=""
typeset TESTFLIGHT_EXPORT_DIRECTORY_IDENTITY=""
typeset -i TESTFLIGHT_EXPORT_DIRECTORY_FD=-1
typeset TESTFLIGHT_UPLOAD_LOG_PATH=""
typeset TESTFLIGHT_UPLOAD_LOG_IDENTITY=""
typeset -i TESTFLIGHT_UPLOAD_LOG_FD=-1
typeset TESTFLIGHT_ARCHIVE_PATH=""
typeset TESTFLIGHT_ARCHIVE_IDENTITY=""
typeset TESTFLIGHT_ARCHIVE_APP_IDENTITY=""
typeset TESTFLIGHT_ARCHIVE_INFO_IDENTITY=""
typeset TESTFLIGHT_ARCHIVE_INFO_SHA256=""
typeset TESTFLIGHT_ARCHIVE_INFO_WITHOUT_DISTRIBUTIONS_SHA256=""
typeset TESTFLIGHT_ARCHIVE_APP_INFO_IDENTITY=""
typeset TESTFLIGHT_ARCHIVE_PROFILE_IDENTITY=""
typeset TESTFLIGHT_ARCHIVE_PROFILE_SHA256=""
typeset TESTFLIGHT_ARCHIVE_CD_HASH=""
typeset TESTFLIGHT_ARCHIVE_TREE_SHA256=""
typeset TESTFLIGHT_ARCHIVE_TREE_WITHOUT_ROOT_INFO_SHA256=""
typeset EXPORT_OPTIONS_IDENTITY=""
typeset EXPORT_OPTIONS_SHA256=""
typeset -i EXPORT_OPTIONS_FD=-1
typeset TESTFLIGHT_XCODEBUILD_AUTHENTICATION_MODE="xcode-account"
typeset TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS_SHA256=""
typeset -a TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS=()
typeset TESTFLIGHT_ASC_API_KEY_DIRECTORY_IDENTITY=""
typeset TESTFLIGHT_ASC_API_KEY_IDENTITY=""
typeset TESTFLIGHT_ASC_API_KEY_PIN_FAILURE="not-started"
typeset -i TESTFLIGHT_ASC_API_KEY_FD=-1
typeset -i TESTFLIGHT_BUILD_CREATE_ATTEMPTED=0
typeset -i TESTFLIGHT_BUILD_IMAGE_CREATED=0
typeset -i TESTFLIGHT_BUILD_ATTACH_ATTEMPTED=0
typeset -i TESTFLIGHT_BUILD_ATTACHMENT_ACTIVE=0
typeset -i RELEASE_SCRATCH_CLEANUP_RUNNING=0
typeset -i RELEASE_SCRATCH_CLEANUP_COMPLETE=0
typeset -i RELEASE_EXIT_CLEANUP_RUNNING=0
typeset -i RELEASE_EXIT_CLEANUP_COMPLETE=0

function fail() {
  print -u2 -r -- "side-by-side TestFlight guard failed: $1"
  exit 1
}

function stat_identity() {
  /usr/bin/stat -f '%d:%i:%u:%g:%Lp:%HT' "$1" 2>/dev/null
}

function ls_mode_token() {
  LC_ALL=C /bin/ls -lde "$1" 2>/dev/null \
    | /usr/bin/awk 'NR == 1 { print $1 }'
}

function sha256_file() {
  /usr/bin/shasum -a 256 "$1" 2>/dev/null \
    | /usr/bin/awk 'NR == 1 && NF == 2 { print $1 }'
}

function sha256_private_file_contents() {
  /usr/bin/shasum -a 256 <"$1" 2>/dev/null \
    | /usr/bin/awk \
      'NR == 1 && NF == 2 && $2 == "-" && length($1) == 64 && $1 !~ /[^0-9a-f]/ { print $1 }'
}

function string_is_lowercase_sha256() {
  local candidate=$1
  [[ "${#candidate}" == 64 && "${candidate}" != *[^0-9a-f]* ]]
}

function verify_app_store_connect_api_key_static_contract() {
  print -rn -- "${EXPECTED_ASC_TEAM_ISSUER_ID}" \
    | /usr/bin/grep -Eq \
      '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' \
    || return 1
  print -rn -- "${EXPECTED_ASC_API_KEY_ID}" \
    | /usr/bin/grep -Eq '^[0-9A-Z]{10}$' || return 1
  [[ "${EXPECTED_ASC_API_KEY_DIRECTORY}" \
        == '/Users/ahmed/Library/Application Support/opensteamer-release-credentials' \
      && "${EXPECTED_ASC_API_KEY_DIRECTORY:A}" \
        == "${EXPECTED_ASC_API_KEY_DIRECTORY}" \
      && "${EXPECTED_ASC_API_KEY_PATH}" \
        == "${EXPECTED_ASC_API_KEY_DIRECTORY}/AuthKey_${EXPECTED_ASC_API_KEY_ID}.p8" \
      && "${EXPECTED_ASC_API_KEY_PATH:A}" == "${EXPECTED_ASC_API_KEY_PATH}" \
      && "${EXPECTED_ASC_API_KEY_OWNER_UID}" == <-> \
      && "${EXPECTED_ASC_API_KEY_OWNER_GID}" == <-> \
      && "${EXPECTED_ASC_API_KEY_OWNER_UID}" == "${EUID}" \
      && "${EXPECTED_ASC_API_KEY_DIRECTORY_MODE}" == '700' \
      && "${EXPECTED_ASC_API_KEY_FILE_MODE}" == '600' \
      && ${#EXPECTED_ASC_API_KEY_XCODEBUILD_ARGUMENTS[@]} == 6 \
      && "${EXPECTED_ASC_API_KEY_XCODEBUILD_ARGUMENTS[1]}" \
        == '-authenticationKeyPath' \
      && "${EXPECTED_ASC_API_KEY_XCODEBUILD_ARGUMENTS[2]}" \
        == "${EXPECTED_ASC_API_KEY_PATH}" \
      && "${EXPECTED_ASC_API_KEY_XCODEBUILD_ARGUMENTS[3]}" \
        == '-authenticationKeyID' \
      && "${EXPECTED_ASC_API_KEY_XCODEBUILD_ARGUMENTS[4]}" \
        == "${EXPECTED_ASC_API_KEY_ID}" \
      && "${EXPECTED_ASC_API_KEY_XCODEBUILD_ARGUMENTS[5]}" \
        == '-authenticationKeyIssuerID' \
      && "${EXPECTED_ASC_API_KEY_XCODEBUILD_ARGUMENTS[6]}" \
        == "${EXPECTED_ASC_TEAM_ISSUER_ID}" ]] || return 1
  string_is_lowercase_sha256 "${EXPECTED_ASC_P8_SHA256}" \
    && string_is_lowercase_sha256 \
      "${EXPECTED_ASC_API_KEY_XCODEBUILD_ARGUMENTS_SHA256}" \
    && [[ "$(string_vector_sha256 \
          "${EXPECTED_ASC_API_KEY_XCODEBUILD_ARGUMENTS[@]}")" \
        == "${EXPECTED_ASC_API_KEY_XCODEBUILD_ARGUMENTS_SHA256}" ]]
}

function xcodebuild_authentication_arguments_sha256() {
  string_vector_sha256 "${TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS[@]}"
}

function verify_app_store_connect_api_key_identity() {
  verify_app_store_connect_api_key_static_contract || return 1
  [[ "${TESTFLIGHT_XCODEBUILD_AUTHENTICATION_MODE}" \
        == 'app-store-connect-api-key' \
      && -n "${TESTFLIGHT_ASC_API_KEY_DIRECTORY_IDENTITY:-}" \
      && -n "${TESTFLIGHT_ASC_API_KEY_IDENTITY:-}" \
      && -d "${EXPECTED_ASC_API_KEY_DIRECTORY}" \
      && ! -L "${EXPECTED_ASC_API_KEY_DIRECTORY}" \
      && "$(stat_identity "${EXPECTED_ASC_API_KEY_DIRECTORY}")" \
        == "${TESTFLIGHT_ASC_API_KEY_DIRECTORY_IDENTITY}" \
      && "$(/usr/bin/stat -f '%u:%g:%Lp:%HT' \
        "${EXPECTED_ASC_API_KEY_DIRECTORY}" 2>/dev/null)" \
        == "${EXPECTED_ASC_API_KEY_OWNER_UID}:${EXPECTED_ASC_API_KEY_OWNER_GID}:${EXPECTED_ASC_API_KEY_DIRECTORY_MODE}:Directory" \
      && "$(ls_mode_token "${EXPECTED_ASC_API_KEY_DIRECTORY}")" \
        == 'drwx------' \
      && -f "${EXPECTED_ASC_API_KEY_PATH}" \
      && ! -L "${EXPECTED_ASC_API_KEY_PATH}" \
      && "$(stat_identity "${EXPECTED_ASC_API_KEY_PATH}")" \
        == "${TESTFLIGHT_ASC_API_KEY_IDENTITY}" \
      && "$(/usr/bin/stat -f '%u:%g:%Lp:%HT:%l' \
        "${EXPECTED_ASC_API_KEY_PATH}" 2>/dev/null)" \
        == "${EXPECTED_ASC_API_KEY_OWNER_UID}:${EXPECTED_ASC_API_KEY_OWNER_GID}:${EXPECTED_ASC_API_KEY_FILE_MODE}:Regular File:1" \
      && "$(ls_mode_token "${EXPECTED_ASC_API_KEY_PATH}")" \
        == '-rw-------' \
      && "$(sha256_private_file_contents "${EXPECTED_ASC_API_KEY_PATH}")" \
        == "${EXPECTED_ASC_P8_SHA256}" \
      && ${TESTFLIGHT_ASC_API_KEY_FD} -ge 0 \
      && -e "/dev/fd/${TESTFLIGHT_ASC_API_KEY_FD}" \
      && "${EXPECTED_ASC_API_KEY_PATH}" \
        -ef "/dev/fd/${TESTFLIGHT_ASC_API_KEY_FD}" \
      && ${#TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS[@]} == 6 \
      && "${TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS[1]}" \
        == '-authenticationKeyPath' \
      && "${TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS[2]}" \
        == "${EXPECTED_ASC_API_KEY_PATH}" \
      && "${TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS[3]}" \
        == '-authenticationKeyID' \
      && "${TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS[4]}" \
        == "${EXPECTED_ASC_API_KEY_ID}" \
      && "${TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS[5]}" \
        == '-authenticationKeyIssuerID' \
      && "${TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS[6]}" \
        == "${EXPECTED_ASC_TEAM_ISSUER_ID}" \
      && "${#TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS_SHA256}" == 64 \
      && "${TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS_SHA256}" \
        == "${EXPECTED_ASC_API_KEY_XCODEBUILD_ARGUMENTS_SHA256}" \
      && "$(xcodebuild_authentication_arguments_sha256)" \
        == "${TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS_SHA256}" ]]
}

function verify_xcodebuild_authentication_contract() {
  case "${TESTFLIGHT_XCODEBUILD_AUTHENTICATION_MODE}" in
    xcode-account)
      [[ ${#TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS[@]} == 0 \
          && -z "${TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS_SHA256}" \
          && -z "${TESTFLIGHT_ASC_API_KEY_DIRECTORY_IDENTITY}" \
          && -z "${TESTFLIGHT_ASC_API_KEY_IDENTITY}" \
          && ${TESTFLIGHT_ASC_API_KEY_FD} == -1 ]]
      ;;
    app-store-connect-api-key)
      verify_app_store_connect_api_key_identity
      ;;
    *)
      return 1
      ;;
  esac
}

function pin_app_store_connect_api_key_identity() {
  TESTFLIGHT_ASC_API_KEY_PIN_FAILURE='static-contract'
  verify_app_store_connect_api_key_static_contract || return 1
  TESTFLIGHT_ASC_API_KEY_PIN_FAILURE='initial-state'
  [[ "${TESTFLIGHT_XCODEBUILD_AUTHENTICATION_MODE}" == 'xcode-account' \
      && ${#TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS[@]} == 0 \
      && -z "${TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS_SHA256}" \
      && -z "${TESTFLIGHT_ASC_API_KEY_DIRECTORY_IDENTITY}" \
      && -z "${TESTFLIGHT_ASC_API_KEY_IDENTITY}" \
      && ${TESTFLIGHT_ASC_API_KEY_FD} == -1 ]] || return 1
  TESTFLIGHT_ASC_API_KEY_PIN_FAILURE='directory-type'
  [[ -d "${EXPECTED_ASC_API_KEY_DIRECTORY}" \
      && ! -L "${EXPECTED_ASC_API_KEY_DIRECTORY}" ]] || return 1
  TESTFLIGHT_ASC_API_KEY_PIN_FAILURE='directory-owner-mode'
  [[ "$(/usr/bin/stat -f '%u:%g:%Lp:%HT' \
      "${EXPECTED_ASC_API_KEY_DIRECTORY}" 2>/dev/null)" \
      == "${EXPECTED_ASC_API_KEY_OWNER_UID}:${EXPECTED_ASC_API_KEY_OWNER_GID}:${EXPECTED_ASC_API_KEY_DIRECTORY_MODE}:Directory" ]] || return 1
  TESTFLIGHT_ASC_API_KEY_PIN_FAILURE='directory-acl-or-xattr'
  [[ "$(ls_mode_token "${EXPECTED_ASC_API_KEY_DIRECTORY}")" \
      == 'drwx------' ]] || return 1
  TESTFLIGHT_ASC_API_KEY_PIN_FAILURE='file-type'
  [[ -f "${EXPECTED_ASC_API_KEY_PATH}" \
      && ! -L "${EXPECTED_ASC_API_KEY_PATH}" ]] || return 1
  TESTFLIGHT_ASC_API_KEY_PIN_FAILURE='file-owner-mode-links'
  [[ "$(/usr/bin/stat -f '%u:%g:%Lp:%HT:%l' \
      "${EXPECTED_ASC_API_KEY_PATH}" 2>/dev/null)" \
      == "${EXPECTED_ASC_API_KEY_OWNER_UID}:${EXPECTED_ASC_API_KEY_OWNER_GID}:${EXPECTED_ASC_API_KEY_FILE_MODE}:Regular File:1" ]] || return 1
  TESTFLIGHT_ASC_API_KEY_PIN_FAILURE='file-acl-or-xattr'
  [[ "$(ls_mode_token "${EXPECTED_ASC_API_KEY_PATH}")" \
      == '-rw-------' ]] || return 1
  TESTFLIGHT_ASC_API_KEY_PIN_FAILURE='file-digest'
  [[ "$(sha256_private_file_contents "${EXPECTED_ASC_API_KEY_PATH}")" \
      == "${EXPECTED_ASC_P8_SHA256}" ]] || return 1
  TESTFLIGHT_ASC_API_KEY_PIN_FAILURE='directory-identity'
  TESTFLIGHT_ASC_API_KEY_DIRECTORY_IDENTITY=$(stat_identity \
    "${EXPECTED_ASC_API_KEY_DIRECTORY}") || return 1
  TESTFLIGHT_ASC_API_KEY_PIN_FAILURE='file-identity'
  TESTFLIGHT_ASC_API_KEY_IDENTITY=$(stat_identity \
    "${EXPECTED_ASC_API_KEY_PATH}") || return 1
  TESTFLIGHT_ASC_API_KEY_PIN_FAILURE='persistent-open'
  sysopen -r -o nofollow,cloexec -u TESTFLIGHT_ASC_API_KEY_FD \
    "${EXPECTED_ASC_API_KEY_PATH}" || return 1
  TESTFLIGHT_ASC_API_KEY_PIN_FAILURE='persistent-bind'
  [[ "${EXPECTED_ASC_API_KEY_PATH}" \
      -ef "/dev/fd/${TESTFLIGHT_ASC_API_KEY_FD}" ]] || return 1
  local -i key_reader_fd=-1
  TESTFLIGHT_ASC_API_KEY_PIN_FAILURE='parse-reader-open'
  sysopen -r -o nofollow -u key_reader_fd \
    "${EXPECTED_ASC_API_KEY_PATH}" || return 1
  TESTFLIGHT_ASC_API_KEY_PIN_FAILURE='parse-reader-bind'
  [[ "/dev/fd/${key_reader_fd}" -ef "/dev/fd/${TESTFLIGHT_ASC_API_KEY_FD}" ]] \
    || {
      exec {key_reader_fd}>&-
      return 1
    }
  local key_parse_status=0
  TESTFLIGHT_ASC_API_KEY_PIN_FAILURE='pkcs8-parse'
  /usr/bin/openssl pkey -in "/dev/fd/${key_reader_fd}" -noout \
    >/dev/null 2>&1 || key_parse_status=$?
  exec {key_reader_fd}>&-
  (( key_parse_status == 0 )) || return 1
  TESTFLIGHT_XCODEBUILD_AUTHENTICATION_MODE='app-store-connect-api-key'
  TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS=(
    "${EXPECTED_ASC_API_KEY_XCODEBUILD_ARGUMENTS[@]}"
  )
  TESTFLIGHT_ASC_API_KEY_PIN_FAILURE='argument-vector-digest'
  TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS_SHA256=$( \
    xcodebuild_authentication_arguments_sha256) || return 1
  TESTFLIGHT_ASC_API_KEY_PIN_FAILURE='final-reverification'
  verify_app_store_connect_api_key_identity || return 1
  TESTFLIGHT_ASC_API_KEY_PIN_FAILURE='none'
}

function verify_package_dependency_contract() {
  [[ "${PACKAGE_MANIFEST_PATH:A}" == "${PACKAGE_MANIFEST_PATH}" \
      && "${PACKAGE_RESOLVED_PATH:A}" == "${PACKAGE_RESOLVED_PATH}" \
      && -f "${PACKAGE_MANIFEST_PATH}" && ! -L "${PACKAGE_MANIFEST_PATH}" \
      && -f "${PACKAGE_RESOLVED_PATH}" && ! -L "${PACKAGE_RESOLVED_PATH}" \
      && "$(sha256_file "${PACKAGE_MANIFEST_PATH}")" \
        == "${EXPECTED_PACKAGE_MANIFEST_SHA256}" \
      && "$(sha256_file "${PACKAGE_RESOLVED_PATH}")" \
        == "${EXPECTED_PACKAGE_RESOLVED_SHA256}" ]]
}

function archive_info_without_distributions_sha256() {
  local archive_info=$1
  [[ -f "${archive_info}" && ! -L "${archive_info}" ]] || return 1
  local xml
  xml=$(/usr/bin/plutil -convert xml1 -o - "${archive_info}" 2>/dev/null) \
    || return 1
  local root_key_count
  root_key_count=$(print -rn -- "${xml}" \
    | /usr/bin/xmllint --xpath 'count(/plist/dict/key)' - 2>/dev/null) \
    || return 1
  local expected_root_key_count=5
  if /usr/bin/plutil -extract Distributions raw -o - "${archive_info}" \
      >/dev/null 2>&1; then
    expected_root_key_count=6
  fi
  [[ "${root_key_count}" == "${expected_root_key_count}" ]] || return 1
  local application_property_keys
  application_property_keys=$(/usr/bin/plutil -extract ApplicationProperties \
    raw -expect dictionary -o - "${archive_info}" 2>/dev/null \
    | LC_ALL=C /usr/bin/sort) || return 1
  [[ "${application_property_keys}" == $'ApplicationPath\nArchitectures\nCFBundleIdentifier\nCFBundleShortVersionString\nCFBundleVersion\nSigningIdentity\nTeam' ]] \
    || return 1
  local architecture_count
  architecture_count=$(plist_array_count \
    "${archive_info}" ApplicationProperties.Architectures) || return 1
  (( architecture_count == 1 )) || return 1
  local -a semantic_fields=(
    "$(plist_typed_raw_value "${archive_info}" ArchiveVersion integer)"
    "$(plist_typed_raw_value "${archive_info}" CreationDate date)"
    "$(plist_typed_raw_value "${archive_info}" Name string)"
    "$(plist_typed_raw_value "${archive_info}" SchemeName string)"
    "$(plist_typed_raw_value \
      "${archive_info}" ApplicationProperties.ApplicationPath string)"
    "$(plist_typed_raw_value \
      "${archive_info}" ApplicationProperties.Architectures.0 string)"
    "$(plist_typed_raw_value \
      "${archive_info}" ApplicationProperties.CFBundleIdentifier string)"
    "$(plist_typed_raw_value \
      "${archive_info}" ApplicationProperties.CFBundleShortVersionString string)"
    "$(plist_typed_raw_value \
      "${archive_info}" ApplicationProperties.CFBundleVersion string)"
    "$(plist_typed_raw_value \
      "${archive_info}" ApplicationProperties.SigningIdentity string)"
    "$(plist_typed_raw_value \
      "${archive_info}" ApplicationProperties.Team string)"
  )
  (( ${#semantic_fields[@]} == 11 )) || return 1
  local semantic_field
  for semantic_field in "${semantic_fields[@]}"; do
    [[ -n "${semantic_field}" ]] || return 1
  done
  [[ "${semantic_fields[1]}" == '2' \
      && "${semantic_fields[3]}" == "${EXPECTED_SCHEME}" \
      && "${semantic_fields[4]}" == "${EXPECTED_SCHEME}" \
      && "${semantic_fields[5]}" == 'Applications/opensteamer.app' \
      && "${semantic_fields[6]}" == 'arm64' \
      && "${semantic_fields[7]}" == "${EXPECTED_BUNDLE_IDENTIFIER}" \
      && "${semantic_fields[8]}" == "${EXPECTED_SHORT_VERSION}" \
      && "${semantic_fields[9]}" == "${EXPECTED_BUILD_NUMBER}" \
      && "${semantic_fields[10]}" == "${EXPECTED_ARCHIVE_SIGNING_IDENTITY}" \
      && "${semantic_fields[11]}" == "${EXPECTED_TEAM_ID}" ]] || return 1
  local digest
  digest=$(string_vector_sha256 "${semantic_fields[@]}") || return 1
  [[ "${#digest}" == 64 ]] || return 1
  print -r -- "${digest}"
}

function filesystem_tree_manifest_stream() {
  local tree_root=$1
  local excluded_relative_path=${2:-}
  [[ -d "${tree_root}" && ! -L "${tree_root}" ]] || return 1
  (
    setopt localoptions pipefail
    export LC_ALL=C
    local -a nodes=("${tree_root}" "${tree_root}"/**/*(ND))
    local node
    local relative_path
    local node_kind
    local metadata
    local xattrs
    local link_count
    for node in "${nodes[@]}"; do
      [[ ! -L "${node}" ]] || exit 1
      if [[ "${node}" == "${tree_root}" ]]; then
        relative_path='.'
      else
        relative_path="./${node#${tree_root}/}"
      fi
      [[ -z "${excluded_relative_path}" \
          || "${relative_path}" != "${excluded_relative_path}" ]] || continue
      if [[ -d "${node}" ]]; then
        node_kind='D'
        metadata=$(/usr/bin/stat -f '%u:%g:%Lp:%l:%f' "${node}" 2>/dev/null) \
          || exit 1
      elif [[ -f "${node}" ]]; then
        node_kind='F'
        metadata=$(/usr/bin/stat -f '%u:%g:%Lp:%l:%z:%f' "${node}" 2>/dev/null) \
          || exit 1
        link_count=$(/usr/bin/stat -f '%l' "${node}" 2>/dev/null) || exit 1
        [[ "${link_count}" == 1 ]] || exit 1
      else
        exit 1
      fi
      xattrs=$(/usr/bin/xattr -lx "${node}" 2>/dev/null) || exit 1
      print -rn -- \
        "${node_kind}"$'\0'"${#relative_path}"$'\0'"${relative_path}"$'\0' \
        "${#metadata}"$'\0'"${metadata}"$'\0' \
        "${#xattrs}"$'\0'"${xattrs}"$'\0'
      if [[ "${node_kind}" == 'F' ]]; then
        /bin/cat -- "${node}" || exit 1
        print -rn -- $'\0'
      fi
    done
  )
}

function filesystem_tree_sha256() {
  local tree_root=$1
  local excluded_relative_path=${2:-}
  local digest
  digest=$(filesystem_tree_manifest_stream \
    "${tree_root}" "${excluded_relative_path}" \
    | /usr/bin/shasum -a 256 \
    | /usr/bin/awk 'NR == 1 && NF == 2 { print $1 }') || return 1
  [[ "${#digest}" == 64 ]] || return 1
  print -r -- "${digest}"
}

function run_with_pinned_build_key_stdin() {
  verify_build_key_identity || return 1
  local -i reader_fd=-1
  sysopen -r -o nofollow -u reader_fd "${TESTFLIGHT_BUILD_KEY_PATH}" \
    || return 1
  [[ -e "/dev/fd/${reader_fd}" \
      && "/dev/fd/${reader_fd}" -ef "/dev/fd/${TESTFLIGHT_BUILD_KEY_FD}" \
      && "${TESTFLIGHT_BUILD_KEY_PATH}" -ef "/dev/fd/${reader_fd}" ]] || {
    exec {reader_fd}>&-
    return 1
  }
  local operation_status=0
  "$@" <"/dev/fd/${reader_fd}" || operation_status=$?
  exec {reader_fd}>&-
  verify_build_key_identity || operation_status=1
  return ${operation_status}
}

function run_with_pinned_xcode_sandbox_profile() {
  local destination_contract=$1
  shift
  case "${destination_contract}" in
    settings|archive)
      ;;
    *)
      return 1
      ;;
  esac
  verify_xcode_sandbox_profile_identity || return 1
  local -i profile_reader_fd=-1
  sysopen -r -o nofollow -u profile_reader_fd \
    "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH}" || return 1
  [[ -e "/dev/fd/${profile_reader_fd}" \
      && "/dev/fd/${profile_reader_fd}" \
        -ef "/dev/fd/${TESTFLIGHT_XCODE_SANDBOX_PROFILE_FD}" \
      && "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH}" \
        -ef "/dev/fd/${profile_reader_fd}" ]] || {
    exec {profile_reader_fd}>&-
    return 1
  }
  local profile_text=''
  local profile_chunk=''
  local profile_text_sha256=''
  local -i profile_read_count=0
  local -i profile_read_status=0
  while true; do
    profile_chunk=''
    if sysread -i ${profile_reader_fd} -s 4096 \
        -c profile_read_count profile_chunk; then
      (( profile_read_count > 0 )) || {
        exec {profile_reader_fd}>&-
        return 1
      }
      profile_text+="${profile_chunk}"
    else
      profile_read_status=$?
      (( profile_read_status == 5 )) || {
        exec {profile_reader_fd}>&-
        return 1
      }
      break
    fi
  done
  local operation_status=0
  profile_text_sha256=$(print -rn -- "${profile_text}" \
    | /usr/bin/shasum -a 256 \
    | /usr/bin/awk 'NR == 1 && NF == 2 { print $1 }') \
    || operation_status=1
  [[ "${profile_text_sha256}" == "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_SHA256}" ]] \
    || operation_status=1
  [[ "${profile_text}" != *'job-creation'* ]] || operation_status=1
  exec {profile_reader_fd}>&-
  verify_xcode_sandbox_profile_identity || operation_status=1
  (( operation_status == 0 )) || return ${operation_status}
  /usr/bin/sandbox-exec -p "${profile_text}" "$@" \
    || operation_status=$?
  verify_xcode_sandbox_profile_identity || operation_status=1
  return ${operation_status}
}

function plist_raw_value() {
  /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

function plist_typed_raw_value() {
  local plist=$1
  local key_path=$2
  local expected_type=$3
  /usr/bin/plutil -extract "${key_path}" raw -expect "${expected_type}" \
    -o - "${plist}" 2>/dev/null
}

function plist_array_count() {
  local plist=$1
  local key_path=$2
  local count
  count=$(/usr/bin/plutil -extract "${key_path}" raw -expect array \
    -o - "${plist}" 2>/dev/null) \
    || return 2
  [[ "${count}" == <-> ]] || return 2
  print -r -- "${count}"
}

function plist_root_array_count() {
  local plist=$1
  local count
  count=$(/usr/bin/plutil -convert xml1 -o - "${plist}" 2>/dev/null \
    | /usr/bin/xmllint --xpath 'count(/plist/array/*)' - 2>/dev/null) \
    || return 2
  [[ "${count}" == <-> ]] || return 2
  print -r -- "${count}"
}

function reject_unsafe_build_environment() {
  local variable_name
  for variable_name in "${REJECTED_BUILD_ENVIRONMENT_VARIABLES[@]}"; do
    (( ${+parameters[${variable_name}]} == 0 )) \
      || fail "caller-controlled build/cache override is forbidden: ${variable_name}"
  done
}

function identifier_is_protected() {
  local identifier=$1
  [[ "${identifier}" == "${PROTECTED_BUNDLE_IDENTIFIER}" \
      || "${identifier}" == "${PROTECTED_BUNDLE_IDENTIFIER}."* \
      || "${identifier}" == "${PROTECTED_APPLICATION_IDENTIFIER}" \
      || "${identifier}" == "${PROTECTED_APPLICATION_IDENTIFIER}."* ]]
}

function require_private_regular_file() {
  local file=$1
  [[ -f "${file}" \
      && ! -L "${file}" \
      && "$(/usr/bin/stat -f '%u:%Lp:%HT' "${file}" 2>/dev/null)" \
        == "${EUID}:600:Regular File" ]]
}

function verify_build_key_identity() {
  verify_control_directory_identity || return 1
  [[ -n "${TESTFLIGHT_BUILD_KEY_PATH:-}" \
      && -n "${TESTFLIGHT_BUILD_KEY_IDENTITY:-}" \
      && "${TESTFLIGHT_BUILD_KEY_PATH}" \
        == "${TESTFLIGHT_CONTROL_DIRECTORY}/image.key" \
      && "$(stat_identity "${TESTFLIGHT_BUILD_KEY_PATH}")" \
        == "${TESTFLIGHT_BUILD_KEY_IDENTITY}" \
      && ${TESTFLIGHT_BUILD_KEY_FD} -ge 0 \
      && -e "/dev/fd/${TESTFLIGHT_BUILD_KEY_FD}" \
      && "${TESTFLIGHT_BUILD_KEY_PATH}" \
        -ef "/dev/fd/${TESTFLIGHT_BUILD_KEY_FD}" ]] \
    && require_private_regular_file "${TESTFLIGHT_BUILD_KEY_PATH}"
}

function verify_xcode_sandbox_profile_identity() {
  verify_control_directory_identity || return 1
  [[ -n "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH:-}" \
      && -n "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_IDENTITY:-}" \
      && "${#TESTFLIGHT_XCODE_SANDBOX_PROFILE_SHA256}" == 64 \
      && "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH}" \
        == "${TESTFLIGHT_CONTROL_DIRECTORY}/xcodebuild.sb" \
      && "$(stat_identity "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH}")" \
        == "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_IDENTITY}" \
      && "$(sha256_file "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH}")" \
        == "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_SHA256}" \
      && ${TESTFLIGHT_XCODE_SANDBOX_PROFILE_FD} -ge 0 \
      && -e "/dev/fd/${TESTFLIGHT_XCODE_SANDBOX_PROFILE_FD}" \
      && "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH}" \
        -ef "/dev/fd/${TESTFLIGHT_XCODE_SANDBOX_PROFILE_FD}" ]] \
    && require_private_regular_file "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH}"
}

function create_xcode_sandbox_profile() {
  verify_control_directory_identity || return 1
  TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH="${TESTFLIGHT_CONTROL_DIRECTORY}/xcodebuild.sb"
  [[ ! -e "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH}" \
      && ! -L "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH}" ]] || return 1
  local -i profile_writer_fd=-1
  sysopen -w -o creat,excl,nofollow -m 600 -u profile_writer_fd \
    "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH}" || return 1
  {
    print -r -- '(version 1)'
    print -r -- '(allow default)'
    print -r -- '(deny file-write* (subpath "/Applications"))'
    print -r -- \
      "(deny file-write* (literal \"${PROTECTED_LEGACY_LAUNCH_AGENT_PATH}\"))"
    print -r -- \
      "(deny file-write* (literal \"${PROTECTED_LAUNCH_AGENTS_DIRECTORY}\"))"
    print -r -- \
      "(deny file-write* (subpath \"${PROTECTED_LAUNCH_AGENTS_DIRECTORY}\"))"
    print -r -- \
      "(deny file-write* (literal \"${PROTECTED_OPENSTEAMER_APPLICATION_SUPPORT_DIRECTORY}\"))"
    print -r -- \
      "(deny file-write* (subpath \"${PROTECTED_OPENSTEAMER_APPLICATION_SUPPORT_DIRECTORY}\"))"
    print -r -- \
      "(deny file-write* (literal \"${PROTECTED_MIGRATION_EVIDENCE_DIRECTORY}\"))"
    print -r -- \
      "(deny file-write* (subpath \"${PROTECTED_MIGRATION_EVIDENCE_DIRECTORY}\"))"
    print -r -- \
      "(deny file-write* (literal \"${EXPECTED_ASC_API_KEY_DIRECTORY}\"))"
    print -r -- \
      "(deny file-write* (subpath \"${EXPECTED_ASC_API_KEY_DIRECTORY}\"))"
    print -r -- \
      "(deny file-write* (subpath \"${EXPECTED_XCODE_REAL_BUNDLE_PATH}\"))"
  } >"/dev/fd/${profile_writer_fd}" || {
    exec {profile_writer_fd}>&-
    return 1
  }
  /bin/chmod 600 "/dev/fd/${profile_writer_fd}" || {
    exec {profile_writer_fd}>&-
    return 1
  }
  sysopen -r -o nofollow -u TESTFLIGHT_XCODE_SANDBOX_PROFILE_FD \
    "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH}" || {
    exec {profile_writer_fd}>&-
    return 1
  }
  [[ "/dev/fd/${profile_writer_fd}" \
      -ef "/dev/fd/${TESTFLIGHT_XCODE_SANDBOX_PROFILE_FD}" ]] || {
    exec {profile_writer_fd}>&-
    return 1
  }
  TESTFLIGHT_XCODE_SANDBOX_PROFILE_IDENTITY=$(stat_identity \
    "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH}") || return 1
  TESTFLIGHT_XCODE_SANDBOX_PROFILE_SHA256=$(sha256_file \
    "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH}") || return 1
  exec {profile_writer_fd}>&-
  verify_xcode_sandbox_profile_identity
}

function require_canonical_safe_path() {
  local candidate=$1
  local required_parent=$2
  [[ -n "${candidate}" \
      && "${candidate:A}" == "${candidate}" \
      && "${candidate:h}" == "${required_parent}" \
      && "${candidate}" != *"/../"* \
      && "${candidate}" != */.. \
      && "${candidate}" != "/Applications" \
      && "${candidate}" != "/Applications/"* ]]
}

function write_private_plist() {
  local destination=$1
  shift
  [[ -n "${TESTFLIGHT_CONTROL_DIRECTORY:-}" \
      && "${destination:h}" == "${TESTFLIGHT_CONTROL_DIRECTORY}" \
      && "${destination:A}" == "${destination}" ]] \
    || return 1
  if [[ -e "${destination}" || -L "${destination}" ]]; then
    require_private_regular_file "${destination}" || return 1
  else
    (
      set -o noclobber
      umask 077
      : >"${destination}"
    ) || return 1
    require_private_regular_file "${destination}" || return 1
  fi
  local destination_identity
  destination_identity=$(stat_identity "${destination}") || return 1
  local -i destination_fd=-1
  # O_TRUNC is applied atomically by the same no-follow open that returns the
  # descriptor used for command output. The destination lives in the private,
  # mode-0700 control directory and its pre-existing inode is pinned above.
  sysopen -w -o trunc,nofollow -u destination_fd "${destination}" || return 1
  [[ "${destination}" -ef "/dev/fd/${destination_fd}" \
      && "$(stat_identity "${destination}")" == "${destination_identity}" ]] \
    || {
      exec {destination_fd}>&-
      return 1
    }
  local command_status=0
  "$@" >"/dev/fd/${destination_fd}" || command_status=$?
  [[ "${destination}" -ef "/dev/fd/${destination_fd}" \
      && "$(stat_identity "${destination}")" == "${destination_identity}" ]] \
    && require_private_regular_file "${destination}" \
    || command_status=1
  exec {destination_fd}>&-
  (( command_status == 0 ))
}

function verify_control_directory_identity() {
  [[ -n "${TESTFLIGHT_CONTROL_DIRECTORY:-}" \
      && "${PRIVATE_TEMPORARY_ROOT:A}" == "${PRIVATE_TEMPORARY_ROOT}" \
      && "$(stat_identity "${PRIVATE_TEMPORARY_ROOT}")" \
        == "${TESTFLIGHT_CONTROL_PARENT_IDENTITY}" \
      && "${TESTFLIGHT_CONTROL_DIRECTORY}" \
        == "${PRIVATE_TEMPORARY_ROOT}"/opensteamer-testflight-build-control.* \
      && "${TESTFLIGHT_CONTROL_DIRECTORY:A}" == "${TESTFLIGHT_CONTROL_DIRECTORY}" \
      && -d "${TESTFLIGHT_CONTROL_DIRECTORY}" \
      && ! -L "${TESTFLIGHT_CONTROL_DIRECTORY}" \
      && "$(stat_identity "${TESTFLIGHT_CONTROL_DIRECTORY}")" \
        == "${TESTFLIGHT_CONTROL_DIRECTORY_IDENTITY}" \
      && "$(/usr/bin/stat -f '%u:%Lp:%HT' \
        "${TESTFLIGHT_CONTROL_DIRECTORY}" 2>/dev/null)" \
        == "${EUID}:700:Directory" ]]
}

function write_backing_root_info() {
  local destination="${TESTFLIGHT_CONTROL_DIRECTORY}/backing-root-info.plist"
  write_private_plist \
    "${destination}" /usr/sbin/diskutil info -plist "${TESTFLIGHT_BUILD_ROOT}"
}

function write_backing_physical_store_info() {
  [[ "${TESTFLIGHT_BUILD_ROOT_PHYSICAL_STORE_IDENTIFIER}" == disk<->s<-> ]] \
    || return 1
  local destination="${TESTFLIGHT_CONTROL_DIRECTORY}/backing-physical-store-info.plist"
  write_private_plist \
    "${destination}" /usr/sbin/diskutil info -plist \
    "${TESTFLIGHT_BUILD_ROOT_PHYSICAL_STORE_IDENTIFIER}"
}

function write_backing_physical_disk_info() {
  [[ "${TESTFLIGHT_BUILD_ROOT_PHYSICAL_WHOLE_DISK}" == disk<-> ]] \
    || return 1
  local destination="${TESTFLIGHT_CONTROL_DIRECTORY}/backing-physical-disk-info.plist"
  write_private_plist \
    "${destination}" /usr/sbin/diskutil info -plist \
    "${TESTFLIGHT_BUILD_ROOT_PHYSICAL_WHOLE_DISK}"
}

function verify_backing_build_root_identity() {
  verify_control_directory_identity || return 1
  [[ "${TESTFLIGHT_BUILD_ROOT:A}" == "${TESTFLIGHT_BUILD_ROOT}" \
      && "${TESTFLIGHT_BUILD_ROOT:h}" == '/Volumes' \
      && -d "${TESTFLIGHT_BUILD_ROOT}" \
      && ! -L "${TESTFLIGHT_BUILD_ROOT}" \
      && "$(stat_identity "${TESTFLIGHT_BUILD_ROOT:h}")" \
        == "${TESTFLIGHT_BUILD_ROOT_PARENT_IDENTITY}" \
      && "$(stat_identity "${TESTFLIGHT_BUILD_ROOT}")" \
        == "${TESTFLIGHT_BUILD_ROOT_IDENTITY}" ]] \
    || return 1
  write_backing_root_info || return 1
  local info="${TESTFLIGHT_CONTROL_DIRECTORY}/backing-root-info.plist"
  local physical_store_count
  physical_store_count=$(plist_array_count "${info}" APFSPhysicalStores) \
    || return 1
  (( physical_store_count == 1 )) || return 1
  [[ "$(plist_raw_value "${info}" APFSPhysicalStores.0.APFSPhysicalStore)" \
      == "${TESTFLIGHT_BUILD_ROOT_PHYSICAL_STORE_IDENTIFIER}" ]] || return 1
  write_backing_physical_store_info || return 1
  write_backing_physical_disk_info || return 1
  local store_info="${TESTFLIGHT_CONTROL_DIRECTORY}/backing-physical-store-info.plist"
  local disk_info="${TESTFLIGHT_CONTROL_DIRECTORY}/backing-physical-disk-info.plist"
  [[ "$(plist_raw_value "${info}" MountPoint)" == "${TESTFLIGHT_BUILD_ROOT}" \
      && "$(plist_raw_value "${info}" FilesystemType)" == 'apfs' \
      && "$(plist_raw_value "${info}" WritableVolume)" == 'true' \
      && "$(plist_raw_value "${info}" VolumeName)" \
        == "${EXPECTED_TESTFLIGHT_BUILD_ROOT_VOLUME_NAME}" \
      && "$(plist_raw_value "${info}" BusProtocol)" \
        == "${EXPECTED_TESTFLIGHT_BUILD_ROOT_BUS_PROTOCOL}" \
      && "$(plist_raw_value "${info}" Internal)" == 'false' \
      && "$(plist_raw_value "${info}" OSInternalMedia)" == 'false' \
      && "$(plist_raw_value "${info}" RemovableMediaOrExternalDevice)" == 'true' \
      && "$(plist_raw_value "${info}" DeviceIdentifier)" \
        == "${TESTFLIGHT_BUILD_ROOT_DEVICE_IDENTIFIER}" \
      && "$(plist_raw_value "${info}" ParentWholeDisk)" \
        == "${TESTFLIGHT_BUILD_ROOT_PARENT_WHOLE_DISK}" \
      && "$(plist_raw_value "${info}" VolumeUUID)" \
        == "${EXPECTED_TESTFLIGHT_BUILD_ROOT_VOLUME_UUID}" \
      && "${TESTFLIGHT_BUILD_ROOT_VOLUME_UUID}" \
        == "${EXPECTED_TESTFLIGHT_BUILD_ROOT_VOLUME_UUID}" \
      && "$(plist_raw_value "${info}" APFSContainerSize)" \
        == "${EXPECTED_TESTFLIGHT_BUILD_ROOT_CONTAINER_SIZE}" \
      && "$(plist_raw_value "${store_info}" DeviceIdentifier)" \
        == "${TESTFLIGHT_BUILD_ROOT_PHYSICAL_STORE_IDENTIFIER}" \
      && "$(plist_raw_value "${store_info}" DiskUUID)" \
        == "${EXPECTED_TESTFLIGHT_BUILD_ROOT_PHYSICAL_STORE_UUID}" \
      && "$(plist_raw_value "${store_info}" APFSContainerReference)" \
        == "${TESTFLIGHT_BUILD_ROOT_PARENT_WHOLE_DISK}" \
      && "$(plist_raw_value "${store_info}" ParentWholeDisk)" \
        == "${TESTFLIGHT_BUILD_ROOT_PHYSICAL_WHOLE_DISK}" \
      && "$(plist_raw_value "${store_info}" Size)" \
        == "${EXPECTED_TESTFLIGHT_BUILD_ROOT_CONTAINER_SIZE}" \
      && "$(plist_raw_value "${store_info}" Internal)" == 'false' \
      && "$(plist_raw_value "${store_info}" OSInternalMedia)" == 'false' \
      && "$(plist_raw_value "${store_info}" RemovableMediaOrExternalDevice)" == 'true' \
      && "$(plist_raw_value "${disk_info}" DeviceIdentifier)" \
        == "${TESTFLIGHT_BUILD_ROOT_PHYSICAL_WHOLE_DISK}" \
      && "$(plist_raw_value "${disk_info}" WholeDisk)" == 'true' \
      && "$(plist_raw_value "${disk_info}" VirtualOrPhysical)" == 'Physical' \
      && "$(plist_raw_value "${disk_info}" MediaName)" \
        == "${EXPECTED_TESTFLIGHT_BUILD_ROOT_MEDIA_NAME}" \
      && "$(plist_raw_value "${disk_info}" BusProtocol)" \
        == "${EXPECTED_TESTFLIGHT_BUILD_ROOT_BUS_PROTOCOL}" \
      && "$(plist_raw_value "${disk_info}" Size)" \
        == "${EXPECTED_TESTFLIGHT_BUILD_ROOT_PHYSICAL_SIZE}" \
      && "$(plist_raw_value "${disk_info}" Internal)" == 'false' \
      && "$(plist_raw_value "${disk_info}" OSInternalMedia)" == 'false' \
      && "$(plist_raw_value "${disk_info}" RemovableMediaOrExternalDevice)" == 'true' ]]
}

function verify_reviewed_xcode_volume_identity() {
  [[ -n "${TESTFLIGHT_XCODE_VOLUME_ROOT_IDENTITY:-}" \
      && "$(stat_identity "${TESTFLIGHT_BUILD_ROOT}")" \
        == "${TESTFLIGHT_XCODE_VOLUME_ROOT_IDENTITY}" ]] || return 1
  local root_info
  root_info=$(/usr/sbin/diskutil info -plist "${TESTFLIGHT_BUILD_ROOT}" 2>/dev/null) \
    || return 2
  print -rn -- "${root_info}" | /usr/bin/plutil -lint - >/dev/null 2>&1 \
    || return 2
  local physical_store_count
  physical_store_count=$(plist_document_array_count \
    "${root_info}" APFSPhysicalStores) || return 2
  (( physical_store_count == 1 )) || return 1
  [[ "$(plist_document_raw_value "${root_info}" MountPoint)" \
        == "${TESTFLIGHT_BUILD_ROOT}" \
      && "$(plist_document_raw_value "${root_info}" FilesystemType)" == 'apfs' \
      && "$(plist_document_raw_value "${root_info}" VolumeUUID)" \
        == "${EXPECTED_TESTFLIGHT_BUILD_ROOT_VOLUME_UUID}" \
      && "$(plist_document_raw_value "${root_info}" DeviceIdentifier)" \
        == "${TESTFLIGHT_XCODE_VOLUME_DEVICE_IDENTIFIER}" \
      && "$(plist_document_raw_value "${root_info}" ParentWholeDisk)" \
        == "${TESTFLIGHT_XCODE_VOLUME_PARENT_WHOLE_DISK}" \
      && "$(plist_document_raw_value \
        "${root_info}" APFSPhysicalStores.0.APFSPhysicalStore)" \
        == "${TESTFLIGHT_XCODE_PHYSICAL_STORE_IDENTIFIER}" \
      && "$(plist_document_raw_value "${root_info}" VolumeName)" \
        == "${EXPECTED_TESTFLIGHT_BUILD_ROOT_VOLUME_NAME}" \
      && "$(plist_document_raw_value "${root_info}" BusProtocol)" \
        == "${EXPECTED_TESTFLIGHT_BUILD_ROOT_BUS_PROTOCOL}" \
      && "$(plist_document_raw_value "${root_info}" APFSContainerSize)" \
        == "${EXPECTED_TESTFLIGHT_BUILD_ROOT_CONTAINER_SIZE}" \
      && "$(plist_document_raw_value "${root_info}" Internal)" == 'false' \
      && "$(plist_document_raw_value "${root_info}" OSInternalMedia)" == 'false' \
      && "$(plist_document_raw_value \
        "${root_info}" RemovableMediaOrExternalDevice)" == 'true' ]] || return 1

  local store_info
  store_info=$(/usr/sbin/diskutil info -plist \
    "${TESTFLIGHT_XCODE_PHYSICAL_STORE_IDENTIFIER}" 2>/dev/null) || return 2
  print -rn -- "${store_info}" | /usr/bin/plutil -lint - >/dev/null 2>&1 \
    || return 2
  [[ "$(plist_document_raw_value "${store_info}" DeviceIdentifier)" \
        == "${TESTFLIGHT_XCODE_PHYSICAL_STORE_IDENTIFIER}" \
      && "$(plist_document_raw_value "${store_info}" DiskUUID)" \
        == "${EXPECTED_TESTFLIGHT_BUILD_ROOT_PHYSICAL_STORE_UUID}" \
      && "$(plist_document_raw_value "${store_info}" ParentWholeDisk)" \
        == "${TESTFLIGHT_XCODE_PHYSICAL_WHOLE_DISK}" \
      && "$(plist_document_raw_value "${store_info}" APFSContainerReference)" \
        == "${TESTFLIGHT_XCODE_VOLUME_PARENT_WHOLE_DISK}" \
      && "$(plist_document_raw_value "${store_info}" Size)" \
        == "${EXPECTED_TESTFLIGHT_BUILD_ROOT_CONTAINER_SIZE}" \
      && "$(plist_document_raw_value "${store_info}" Internal)" == 'false' \
      && "$(plist_document_raw_value "${store_info}" OSInternalMedia)" == 'false' \
      && "$(plist_document_raw_value \
        "${store_info}" RemovableMediaOrExternalDevice)" == 'true' ]] || return 1

  local disk_info
  disk_info=$(/usr/sbin/diskutil info -plist \
    "${TESTFLIGHT_XCODE_PHYSICAL_WHOLE_DISK}" 2>/dev/null) || return 2
  print -rn -- "${disk_info}" | /usr/bin/plutil -lint - >/dev/null 2>&1 \
    || return 2
  [[ "$(plist_document_raw_value "${disk_info}" DeviceIdentifier)" \
        == "${TESTFLIGHT_XCODE_PHYSICAL_WHOLE_DISK}" \
      && "$(plist_document_raw_value "${disk_info}" WholeDisk)" == 'true' \
      && "$(plist_document_raw_value "${disk_info}" VirtualOrPhysical)" \
        == 'Physical' \
      && "$(plist_document_raw_value "${disk_info}" MediaName)" \
        == "${EXPECTED_TESTFLIGHT_BUILD_ROOT_MEDIA_NAME}" \
      && "$(plist_document_raw_value "${disk_info}" BusProtocol)" \
        == "${EXPECTED_TESTFLIGHT_BUILD_ROOT_BUS_PROTOCOL}" \
      && "$(plist_document_raw_value "${disk_info}" Size)" \
        == "${EXPECTED_TESTFLIGHT_BUILD_ROOT_PHYSICAL_SIZE}" \
      && "$(plist_document_raw_value "${disk_info}" Internal)" == 'false' \
      && "$(plist_document_raw_value "${disk_info}" OSInternalMedia)" == 'false' \
      && "$(plist_document_raw_value \
        "${disk_info}" RemovableMediaOrExternalDevice)" == 'true' ]]
}

function verify_reviewed_xcode_deep_signature() {
  /usr/bin/codesign --verify --deep --strict --verbose=4 \
    "${EXPECTED_XCODE_REAL_BUNDLE_PATH}" >/dev/null 2>&1
}

function verify_or_reuse_reviewed_xcode_deep_signature() {
  case ${TESTFLIGHT_XCODE_DEEP_SIGNATURE_VERIFIED} in
    0)
      verify_reviewed_xcode_deep_signature || return 1
      TESTFLIGHT_XCODE_DEEP_SIGNATURE_VERIFIED=1
      ;;
    1)
      ;;
    *)
      return 1
      ;;
  esac
}

function verify_reviewed_xcode_toolchain_identity() {
  local selected_developer_path
  selected_developer_path=$(/usr/bin/xcode-select -p 2>/dev/null) || return 2
  [[ "${selected_developer_path}" == "${EXPECTED_XCODE_SELECTED_DEVELOPER_PATH}" \
      && "${selected_developer_path:A}" \
        == "${EXPECTED_XCODE_REAL_DEVELOPER_PATH}" \
      && -L "${EXPECTED_XCODE_ALIAS_PATH}" \
      && "${EXPECTED_XCODE_ALIAS_PATH:A}" \
        == "${EXPECTED_XCODE_REAL_BUNDLE_PATH}" \
      && -d "${EXPECTED_XCODE_REAL_BUNDLE_PATH}" \
      && ! -L "${EXPECTED_XCODE_REAL_BUNDLE_PATH}" \
      && -d "${EXPECTED_XCODE_REAL_DEVELOPER_PATH}" \
      && ! -L "${EXPECTED_XCODE_REAL_DEVELOPER_PATH}" \
      && -f "${EXPECTED_XCODE_REAL_BUNDLE_PATH}/Contents/Info.plist" \
      && ! -L "${EXPECTED_XCODE_REAL_BUNDLE_PATH}/Contents/Info.plist" \
      && -f "${EXPECTED_XCODE_REAL_BUNDLE_PATH}/Contents/version.plist" \
      && ! -L "${EXPECTED_XCODE_REAL_BUNDLE_PATH}/Contents/version.plist" \
      && -x "${EXPECTED_XCODEBUILD_REAL_PATH}" \
      && -f "${EXPECTED_XCODEBUILD_REAL_PATH}" \
      && ! -L "${EXPECTED_XCODEBUILD_REAL_PATH}" \
      && "$(stat_identity "${EXPECTED_XCODE_ALIAS_PATH}")" \
        == "${TESTFLIGHT_XCODE_ALIAS_IDENTITY}" \
      && "$(stat_identity "${EXPECTED_XCODE_REAL_BUNDLE_PATH}")" \
        == "${TESTFLIGHT_XCODE_BUNDLE_IDENTITY}" \
      && "${TESTFLIGHT_XCODE_BUNDLE_IDENTITY%%:*}" \
        == "${TESTFLIGHT_XCODE_VOLUME_ROOT_IDENTITY%%:*}" \
      && "$(stat_identity "${EXPECTED_XCODE_REAL_DEVELOPER_PATH}")" \
        == "${TESTFLIGHT_XCODE_DEVELOPER_IDENTITY}" \
      && "$(stat_identity "${EXPECTED_XCODEBUILD_REAL_PATH}")" \
        == "${TESTFLIGHT_XCODEBUILD_IDENTITY}" \
      && "$(sha256_file \
        "${EXPECTED_XCODE_REAL_BUNDLE_PATH}/Contents/Info.plist")" \
        == "${EXPECTED_XCODE_INFO_SHA256}" \
      && "$(sha256_file \
        "${EXPECTED_XCODE_REAL_BUNDLE_PATH}/Contents/version.plist")" \
        == "${EXPECTED_XCODE_VERSION_SHA256}" \
      && "$(sha256_file "${EXPECTED_XCODEBUILD_REAL_PATH}")" \
        == "${EXPECTED_XCODEBUILD_SHA256}" \
      && "$(plist_raw_value \
        "${EXPECTED_XCODE_REAL_BUNDLE_PATH}/Contents/Info.plist" \
        CFBundleIdentifier)" == "${EXPECTED_XCODE_BUNDLE_IDENTIFIER}" \
      && "$(plist_raw_value \
        "${EXPECTED_XCODE_REAL_BUNDLE_PATH}/Contents/Info.plist" \
        CFBundleShortVersionString)" == "${EXPECTED_XCODE_VERSION}" \
      && "$(plist_raw_value \
        "${EXPECTED_XCODE_REAL_BUNDLE_PATH}/Contents/version.plist" \
        ProductBuildVersion)" == "${EXPECTED_XCODE_BUILD_VERSION}" ]] || return 1
  verify_reviewed_xcode_volume_identity || return $?
  verify_or_reuse_reviewed_xcode_deep_signature || return 1
  /usr/bin/codesign --verify --strict --verbose=4 \
    "${EXPECTED_XCODEBUILD_REAL_PATH}" >/dev/null 2>&1 || return 1
  local bundle_metadata
  local executable_metadata
  bundle_metadata=$(/usr/bin/codesign -dv --verbose=4 \
    "${EXPECTED_XCODE_REAL_BUNDLE_PATH}" 2>&1) || return 1
  executable_metadata=$(/usr/bin/codesign -dv --verbose=4 \
    "${EXPECTED_XCODEBUILD_REAL_PATH}" 2>&1) || return 1
  [[ "$(codesign_metadata_value "${bundle_metadata}" Identifier)" \
        == "${EXPECTED_XCODE_BUNDLE_IDENTIFIER}" \
      && "$(codesign_metadata_value "${bundle_metadata}" TeamIdentifier)" \
        == "${EXPECTED_XCODE_SIGNING_TEAM_ID}" \
      && "$(codesign_metadata_value "${bundle_metadata}" CDHash)" \
        == "${EXPECTED_XCODE_BUNDLE_CD_HASH}" \
      && "$(codesign_metadata_value "${executable_metadata}" Identifier)" \
        == "${EXPECTED_XCODEBUILD_IDENTIFIER}" \
      && "$(codesign_metadata_value "${executable_metadata}" TeamIdentifier)" \
        == "${EXPECTED_XCODE_SIGNING_TEAM_ID}" \
      && "$(codesign_metadata_value "${executable_metadata}" CDHash)" \
        == "${EXPECTED_XCODEBUILD_CD_HASH}" ]]
}

function pin_reviewed_xcode_toolchain_identity() {
  [[ -L "${EXPECTED_XCODE_ALIAS_PATH}" \
      && "${EXPECTED_XCODE_ALIAS_PATH:A}" \
        == "${EXPECTED_XCODE_REAL_BUNDLE_PATH}" \
      && -d "${EXPECTED_XCODE_REAL_BUNDLE_PATH}" \
      && ! -L "${EXPECTED_XCODE_REAL_BUNDLE_PATH}" \
      && -d "${EXPECTED_XCODE_REAL_DEVELOPER_PATH}" \
      && ! -L "${EXPECTED_XCODE_REAL_DEVELOPER_PATH}" \
      && -f "${EXPECTED_XCODEBUILD_REAL_PATH}" \
      && ! -L "${EXPECTED_XCODEBUILD_REAL_PATH}" ]] || return 1
  TESTFLIGHT_XCODE_ALIAS_IDENTITY=$(stat_identity "${EXPECTED_XCODE_ALIAS_PATH}") \
    || return 1
  TESTFLIGHT_XCODE_BUNDLE_IDENTITY=$(stat_identity \
    "${EXPECTED_XCODE_REAL_BUNDLE_PATH}") || return 1
  TESTFLIGHT_XCODE_DEVELOPER_IDENTITY=$(stat_identity \
    "${EXPECTED_XCODE_REAL_DEVELOPER_PATH}") || return 1
  TESTFLIGHT_XCODEBUILD_IDENTITY=$(stat_identity \
    "${EXPECTED_XCODEBUILD_REAL_PATH}") || return 1
  TESTFLIGHT_XCODE_VOLUME_ROOT_IDENTITY=$(stat_identity "${TESTFLIGHT_BUILD_ROOT}") \
    || return 1
  [[ "${TESTFLIGHT_XCODE_BUNDLE_IDENTITY%%:*}" \
      == "${TESTFLIGHT_XCODE_VOLUME_ROOT_IDENTITY%%:*}" ]] || return 1
  local root_info
  root_info=$(/usr/sbin/diskutil info -plist "${TESTFLIGHT_BUILD_ROOT}" 2>/dev/null) \
    || return 2
  print -rn -- "${root_info}" | /usr/bin/plutil -lint - >/dev/null 2>&1 \
    || return 2
  local physical_store_count
  physical_store_count=$(plist_document_array_count \
    "${root_info}" APFSPhysicalStores) || return 2
  (( physical_store_count == 1 )) || return 1
  TESTFLIGHT_XCODE_VOLUME_DEVICE_IDENTIFIER=$(plist_document_raw_value \
    "${root_info}" DeviceIdentifier) || return 1
  TESTFLIGHT_XCODE_VOLUME_PARENT_WHOLE_DISK=$(plist_document_raw_value \
    "${root_info}" ParentWholeDisk) || return 1
  TESTFLIGHT_XCODE_PHYSICAL_STORE_IDENTIFIER=$(plist_document_raw_value \
    "${root_info}" APFSPhysicalStores.0.APFSPhysicalStore) || return 1
  [[ "${TESTFLIGHT_XCODE_VOLUME_DEVICE_IDENTIFIER}" == disk<->s<->* \
      && "${TESTFLIGHT_XCODE_VOLUME_PARENT_WHOLE_DISK}" == disk<-> \
      && "${TESTFLIGHT_XCODE_PHYSICAL_STORE_IDENTIFIER}" == disk<->s<-> ]] \
    || return 1
  local store_info
  store_info=$(/usr/sbin/diskutil info -plist \
    "${TESTFLIGHT_XCODE_PHYSICAL_STORE_IDENTIFIER}" 2>/dev/null) || return 2
  print -rn -- "${store_info}" | /usr/bin/plutil -lint - >/dev/null 2>&1 \
    || return 2
  TESTFLIGHT_XCODE_PHYSICAL_WHOLE_DISK=$(plist_document_raw_value \
    "${store_info}" ParentWholeDisk) || return 1
  [[ "${TESTFLIGHT_XCODE_PHYSICAL_WHOLE_DISK}" == disk<-> ]] || return 1
  verify_reviewed_xcode_toolchain_identity
}

function verify_image_container_identity() {
  verify_backing_build_root_identity || return 1
  [[ -n "${TESTFLIGHT_BUILD_IMAGE_CONTAINER:-}" \
      && "${TESTFLIGHT_BUILD_IMAGE_CONTAINER}" \
        == "${TESTFLIGHT_BUILD_ROOT}"/.opensteamer-testflight-build-image.* \
      && "${TESTFLIGHT_BUILD_IMAGE_CONTAINER:A}" \
        == "${TESTFLIGHT_BUILD_IMAGE_CONTAINER}" \
      && -d "${TESTFLIGHT_BUILD_IMAGE_CONTAINER}" \
      && ! -L "${TESTFLIGHT_BUILD_IMAGE_CONTAINER}" \
      && "$(stat_identity "${TESTFLIGHT_BUILD_IMAGE_CONTAINER}")" \
        == "${TESTFLIGHT_BUILD_IMAGE_CONTAINER_IDENTITY}" ]]
}

function verify_image_storage_identity() {
  verify_image_container_identity || return 1
  [[ -n "${TESTFLIGHT_BUILD_IMAGE_PATH:-}" \
      && "${TESTFLIGHT_BUILD_IMAGE_PATH}" \
        == "${TESTFLIGHT_BUILD_IMAGE_CONTAINER}/${TESTFLIGHT_BUILD_IMAGE_BASENAME}.sparseimage" \
      && "${TESTFLIGHT_BUILD_IMAGE_PATH:A}" == "${TESTFLIGHT_BUILD_IMAGE_PATH}" \
      && -f "${TESTFLIGHT_BUILD_IMAGE_PATH}" \
      && ! -L "${TESTFLIGHT_BUILD_IMAGE_PATH}" \
      && "$(stat_identity "${TESTFLIGHT_BUILD_IMAGE_PATH}")" \
        == "${TESTFLIGHT_BUILD_IMAGE_IDENTITY}" ]]
}

function pin_partial_image_identity_for_cleanup() {
  verify_image_container_identity || return 1
  [[ -n "${TESTFLIGHT_BUILD_IMAGE_PATH:-}" \
      && "${TESTFLIGHT_BUILD_IMAGE_PATH}" \
        == "${TESTFLIGHT_BUILD_IMAGE_CONTAINER}/${TESTFLIGHT_BUILD_IMAGE_BASENAME}.sparseimage" ]] \
    || return 1
  require_canonical_safe_path \
    "${TESTFLIGHT_BUILD_IMAGE_PATH}" "${TESTFLIGHT_BUILD_IMAGE_CONTAINER}" \
    || return 1
  if [[ ! -e "${TESTFLIGHT_BUILD_IMAGE_PATH}" \
      && ! -L "${TESTFLIGHT_BUILD_IMAGE_PATH}" ]]; then
    return 0
  fi
  [[ -f "${TESTFLIGHT_BUILD_IMAGE_PATH}" \
      && ! -L "${TESTFLIGHT_BUILD_IMAGE_PATH}" ]] || return 1
  TESTFLIGHT_BUILD_IMAGE_IDENTITY=$(stat_identity \
    "${TESTFLIGHT_BUILD_IMAGE_PATH}")
  [[ -n "${TESTFLIGHT_BUILD_IMAGE_IDENTITY}" ]]
}

function plist_buddy_value() {
  /usr/libexec/PlistBuddy -c "Print $2" "$1" 2>/dev/null
}

function apfs_partition_uuid_from_image_info() {
  local plist=$1
  local partition_count
  partition_count=$(plist_array_count "${plist}" 'partitions.partitions') \
    || return 2
  local match_count=0
  local partition_index
  local partition_hint
  local partition_uuid=''
  for (( partition_index = 0; partition_index < partition_count; partition_index += 1 )); do
    partition_hint=$(plist_buddy_value \
      "${plist}" ":partitions:partitions:${partition_index}:partition-hint") \
      || return 2
    if [[ "${partition_hint:u}" == 'APPLE_APFS' \
        || "${partition_hint:u}" == "${APFS_PARTITION_TYPE_UUID}" ]]; then
      partition_uuid=$(plist_buddy_value \
        "${plist}" ":partitions:partitions:${partition_index}:partition-UUID") \
        || return 2
      (( match_count += 1 ))
    fi
  done
  (( match_count == 1 && ${#partition_uuid} == 36 )) || return 1
  print -r -- "${partition_uuid:u}"
}

function write_and_verify_created_image_info() {
  verify_image_storage_identity || return 1
  verify_build_key_identity || return 1
  local destination="${TESTFLIGHT_CONTROL_DIRECTORY}/created-image-info.plist"
  write_private_plist \
    "${destination}" run_with_pinned_build_key_stdin \
    /usr/bin/hdiutil imageinfo -plist -stdinpass \
    "${TESTFLIGHT_BUILD_IMAGE_PATH}" \
    || return 1
  verify_image_storage_identity || return 1
  verify_build_key_identity || return 1
  [[ "$(plist_raw_value "${destination}" Properties.Encrypted)" == 'true' \
      && "$(plist_raw_value "${destination}" Format)" \
        == "${TESTFLIGHT_BUILD_IMAGE_FORMAT}" ]] || return 1
  TESTFLIGHT_BUILD_IMAGE_PARTITION_UUID=$(apfs_partition_uuid_from_image_info \
    "${destination}") || return 1
  [[ ${#TESTFLIGHT_BUILD_IMAGE_PARTITION_UUID} == 36 ]]
}

function unique_guid_root_device_from_entity_array() {
  local plist=$1
  local entity_key_path=$2
  local entity_count
  entity_count=$(plist_array_count "${plist}" "${entity_key_path}") \
    || return 2
  (( entity_count > 0 )) || return 2

  local entity_index
  local entity_device
  local entity_hint
  local entity_mount
  local root_device=''
  local root_count=0
  for (( entity_index = 0; entity_index < entity_count; entity_index += 1 )); do
    entity_device=$(plist_typed_raw_value \
      "${plist}" "${entity_key_path}.${entity_index}.dev-entry" string) \
      || return 2
    entity_hint=$(plist_typed_raw_value \
      "${plist}" "${entity_key_path}.${entity_index}.content-hint" string) \
      || return 2
    [[ "${entity_device}" == /dev/disk<->* \
        && -n "${entity_hint}" ]] || return 2
    if [[ "${entity_hint}" == 'GUID_partition_scheme' ]]; then
      [[ "${entity_device}" == /dev/disk<-> ]] || return 2
      root_device=${entity_device}
      (( root_count += 1 ))
    fi
    if ! entity_mount=$(plist_typed_raw_value \
        "${plist}" "${entity_key_path}.${entity_index}.mount-point" string); then
      /usr/bin/plutil -type \
        "${entity_key_path}.${entity_index}.mount-point" "${plist}" \
        >/dev/null 2>&1 && return 2
    fi
  done
  (( root_count == 1 )) || return 2
  print -r -- "${root_device}"
}

function attachment_devices_from_plist() {
  local plist=$1
  local image_prefix=$2
  local image_key_prefix=${3:-}
  local expected_mount_point=${4:-${TESTFLIGHT_BUILD_MOUNT_POINT}}
  local entity_key_path='system-entities'
  [[ -z "${image_key_prefix}" ]] \
    || entity_key_path="${image_key_prefix}.system-entities"
  local root_device
  root_device=$(unique_guid_root_device_from_entity_array \
    "${plist}" "${entity_key_path}") || return 2

  local mounted_device=''
  local mount_count=0
  local image_partition_device=''
  local image_partition_count=0
  local entity_index
  local entity_mount
  local entity_device
  local entity_hint
  local entity_count
  entity_count=$(plist_array_count "${plist}" "${entity_key_path}") \
    || return 2
  (( entity_count > 0 )) || return 2
  for (( entity_index = 0; entity_index < entity_count; entity_index += 1 )); do
    entity_hint=$(plist_typed_raw_value \
      "${plist}" "${entity_key_path}.${entity_index}.content-hint" string) \
      || return 2
    entity_device=$(plist_typed_raw_value \
      "${plist}" "${entity_key_path}.${entity_index}.dev-entry" string) \
      || return 2
    if [[ "${entity_hint:u}" == 'APPLE_APFS' \
        || "${entity_hint:u}" == "${APFS_PARTITION_TYPE_UUID}" ]]; then
      [[ "${entity_device}" == "${root_device}"s<-> ]] || return 1
      image_partition_device=${entity_device}
      (( image_partition_count += 1 ))
    fi
    if ! entity_mount=$(plist_typed_raw_value \
        "${plist}" "${entity_key_path}.${entity_index}.mount-point" string); then
      /usr/bin/plutil -type \
        "${entity_key_path}.${entity_index}.mount-point" "${plist}" \
        >/dev/null 2>&1 && return 2
      continue
    fi
    if [[ "${entity_mount}" == "${expected_mount_point}" ]]; then
      [[ -n "${entity_device}" ]] || return 1
      [[ "${entity_device}" == /dev/disk<->* ]] || return 1
      mounted_device=${entity_device}
      (( mount_count += 1 ))
    fi
  done
  (( mount_count == 1 && image_partition_count == 1 )) || return 1
  print -r -- "${root_device}|${mounted_device}|${image_partition_device}"
}

function attachment_root_device_from_plist() {
  local plist=$1
  local image_key_prefix=$2
  local entity_key_path="${image_key_prefix}.system-entities"
  unique_guid_root_device_from_entity_array "${plist}" "${entity_key_path}"
}

function find_current_attachment_record() {
  local info="${TESTFLIGHT_CONTROL_DIRECTORY}/hdiutil-info.plist"
  write_private_plist "${info}" /usr/bin/hdiutil info -plist || return 2
  local image_count
  image_count=$(plist_array_count "${info}" images) || return 2
  local image_index
  local image_path
  local match_count=0
  local record=''
  local devices=''
  local image_encrypted=''
  local image_writeable=''
  local enumerated_root=''
  for (( image_index = 0; image_index < image_count; image_index += 1 )); do
    image_path=$(plist_typed_raw_value \
      "${info}" "images.${image_index}.image-path" string) \
      || return 2
    enumerated_root=$(attachment_root_device_from_plist \
      "${info}" "images.${image_index}") || return 2
    if [[ "${image_path}" == "${TESTFLIGHT_BUILD_IMAGE_PATH}" ]]; then
      devices=$(attachment_devices_from_plist \
        "${info}" ":images:${image_index}" "images.${image_index}") || return 2
      image_encrypted=$(plist_typed_raw_value \
        "${info}" "images.${image_index}.image-encrypted" bool) || return 2
      image_writeable=$(plist_typed_raw_value \
        "${info}" "images.${image_index}.writeable" bool) || return 2
      record="${devices}|${image_encrypted:l}|${image_writeable:l}"
      (( match_count += 1 ))
    fi
  done
  (( match_count == 1 )) || {
    (( match_count == 0 )) && return 1
    return 2
  }
  print -r -- "${record}"
}

function find_current_attachment_root_device() {
  local info="${TESTFLIGHT_CONTROL_DIRECTORY}/hdiutil-info.plist"
  write_private_plist "${info}" /usr/bin/hdiutil info -plist || return 2
  local image_count
  image_count=$(plist_array_count "${info}" images) || return 2
  local image_index
  local image_path
  local root_device=''
  local root_hint=''
  local match_count=0
  local enumerated_root=''
  for (( image_index = 0; image_index < image_count; image_index += 1 )); do
    image_path=$(plist_typed_raw_value \
      "${info}" "images.${image_index}.image-path" string) \
      || return 2
    enumerated_root=$(attachment_root_device_from_plist \
      "${info}" "images.${image_index}") || return 2
    if [[ "${image_path}" == "${TESTFLIGHT_BUILD_IMAGE_PATH}" ]]; then
      root_device=${enumerated_root}
      (( match_count += 1 ))
    fi
  done
  (( match_count == 1 )) || {
    (( match_count == 0 )) && return 1
    return 2
  }
  print -r -- "${root_device}"
}

function current_attachment_is_absent() {
  local info="${TESTFLIGHT_CONTROL_DIRECTORY}/hdiutil-info.plist"
  write_private_plist "${info}" /usr/bin/hdiutil info -plist || return 2
  local image_count
  image_count=$(plist_array_count "${info}" images) || return 2
  local image_index
  local image_path
  local enumerated_root
  local match_count=0
  for (( image_index = 0; image_index < image_count; image_index += 1 )); do
    image_path=$(plist_typed_raw_value \
      "${info}" "images.${image_index}.image-path" string) \
      || return 2
    enumerated_root=$(attachment_root_device_from_plist \
      "${info}" "images.${image_index}") || return 2
    [[ "${image_path}" != "${TESTFLIGHT_BUILD_IMAGE_PATH}" ]] \
      || (( match_count += 1 ))
  done
  (( match_count == 0 )) && return 0
  (( match_count == 1 )) && return 1
  return 2
}

function verify_hdiutil_attachment_identity() {
  verify_control_directory_identity || return 1
  verify_image_storage_identity || return 1
  local record
  record=$(find_current_attachment_record) || return 1
  [[ "${record}" \
      == "${TESTFLIGHT_IMAGE_DEVICE}|${TESTFLIGHT_MOUNTED_DEVICE}|${TESTFLIGHT_IMAGE_PARTITION_DEVICE}|true|true" ]]
}

function write_image_partition_info() {
  local destination="${TESTFLIGHT_CONTROL_DIRECTORY}/image-partition-info.plist"
  write_private_plist \
    "${destination}" /usr/sbin/diskutil info -plist \
    "${TESTFLIGHT_IMAGE_PARTITION_DEVICE}"
}

function write_mounted_volume_info() {
  local destination="${TESTFLIGHT_CONTROL_DIRECTORY}/mounted-volume-info.plist"
  write_private_plist \
    "${destination}" /usr/sbin/diskutil info -plist "${TESTFLIGHT_MOUNTED_DEVICE}"
}

function pin_private_build_directory() {
  local directory=$1
  local required_parent=$2
  require_canonical_safe_path "${directory}" "${required_parent}" || return 1
  [[ ! -e "${directory}" && ! -L "${directory}" ]] || return 1
  /bin/mkdir -m 700 "${directory}" || return 1
  /bin/chmod 700 "${directory}" || return 1
  local identity
  identity=$(stat_identity "${directory}") || return 1
  [[ -n "${identity}" \
      && "$(/usr/bin/stat -f '%u:%Lp:%HT' "${directory}" 2>/dev/null)" \
        == "${EUID}:700:Directory" ]] || return 1
  TESTFLIGHT_PINNED_BUILD_DIRECTORIES+=("${directory}|${identity}")
}

function verify_pinned_build_directories() {
  (( ${#TESTFLIGHT_PINNED_BUILD_DIRECTORIES[@]} == 9 )) || return 1
  local -a expected_directories=(
    "${TESTFLIGHT_BUILD_TMP_DIRECTORY}"
    "${TESTFLIGHT_DERIVED_DATA_DIRECTORY}"
    "${TESTFLIGHT_BUILD_PRODUCTS_DIRECTORY}"
    "${TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY}"
    "${TESTFLIGHT_BUILD_PRECOMPILED_DIRECTORY}"
    "${TESTFLIGHT_BUILD_CACHE_DIRECTORY}"
    "${TESTFLIGHT_BUILD_MODULE_CACHE_DIRECTORY}"
    "${TESTFLIGHT_BUILD_PACKAGE_CACHE_DIRECTORY}"
    "${TESTFLIGHT_BUILD_SOURCE_PACKAGES_DIRECTORY}"
  )
  local record
  local directory
  local identity
  for record in "${TESTFLIGHT_PINNED_BUILD_DIRECTORIES[@]}"; do
    directory=${record%%|*}
    identity=${record#*|}
    [[ -n "${directory}" \
        && -n "${identity}" \
        && "${directory:A}" == "${directory}" \
        && "${directory}" == "${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}/"* \
        && -d "${directory}" \
        && ! -L "${directory}" \
        && "$(stat_identity "${directory}")" == "${identity}" \
        && "$(/usr/bin/stat -f '%u:%Lp:%HT' "${directory}" 2>/dev/null)" \
          == "${EUID}:700:Directory" ]] || return 1
  done
  local expected_directory
  local occurrence_count
  for expected_directory in "${expected_directories[@]}"; do
    occurrence_count=0
    for record in "${TESTFLIGHT_PINNED_BUILD_DIRECTORIES[@]}"; do
      [[ "${record%%|*}" != "${expected_directory}" ]] \
        || (( occurrence_count += 1 ))
    done
    (( occurrence_count == 1 )) || return 1
  done
}

function verify_private_build_volume_identity() {
  verify_hdiutil_attachment_identity || return 1
  verify_pinned_build_directories || return 1
  write_image_partition_info || return 1
  write_mounted_volume_info || return 1
  local partition_info="${TESTFLIGHT_CONTROL_DIRECTORY}/image-partition-info.plist"
  local info="${TESTFLIGHT_CONTROL_DIRECTORY}/mounted-volume-info.plist"
  local current_partition_uuid
  current_partition_uuid=$(plist_raw_value "${partition_info}" DiskUUID) \
    || return 1
  [[ "$(plist_raw_value "${partition_info}" DeviceNode)" \
        == "${TESTFLIGHT_IMAGE_PARTITION_DEVICE}" \
      && "$(plist_raw_value "${partition_info}" ParentWholeDisk)" \
        == "${TESTFLIGHT_IMAGE_DEVICE#/dev/}" \
      && "$(plist_raw_value "${partition_info}" Content)" == 'Apple_APFS' \
      && "${current_partition_uuid:u}" \
        == "${TESTFLIGHT_BUILD_IMAGE_PARTITION_UUID}" \
      && "$(plist_raw_value "${info}" MountPoint)" == "${TESTFLIGHT_BUILD_MOUNT_POINT}" \
      && "$(plist_raw_value "${info}" FilesystemType)" == 'apfs' \
      && "$(plist_raw_value "${info}" FilesystemName)" == 'APFS' \
      && "$(plist_raw_value "${info}" WritableVolume)" == 'true' \
      && "$(plist_raw_value "${info}" GlobalPermissionsEnabled)" == 'true' \
      && "$(plist_raw_value "${info}" DeviceIdentifier)" \
        == "${TESTFLIGHT_MOUNTED_DEVICE_IDENTIFIER}" \
      && "$(plist_raw_value "${info}" ParentWholeDisk)" \
        == "${TESTFLIGHT_MOUNTED_PARENT_WHOLE_DISK}" \
      && "$(plist_raw_value "${info}" VolumeUUID)" \
        == "${TESTFLIGHT_MOUNTED_VOLUME_UUID}" \
      && "$(plist_raw_value "${info}" VolumeName)" \
        == "${TESTFLIGHT_BUILD_VOLUME_NAME}" \
      && -d "${TESTFLIGHT_BUILD_MOUNT_POINT}" \
      && ! -L "${TESTFLIGHT_BUILD_MOUNT_POINT}" \
      && "$(stat_identity "${TESTFLIGHT_BUILD_MOUNT_POINT}")" \
        == "${TESTFLIGHT_MOUNTED_VOLUME_ROOT_IDENTITY}" \
      && "${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}" \
        == "${TESTFLIGHT_BUILD_MOUNT_POINT}/BuildSandbox" \
      && -d "${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}" \
      && ! -L "${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}" \
      && "$(stat_identity "${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}")" \
        == "${TESTFLIGHT_BUILD_SANDBOX_IDENTITY}" \
      && "${TESTFLIGHT_DERIVED_DATA_DIRECTORY}" \
        == "${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}/DerivedData" \
      && "${TESTFLIGHT_DERIVED_DATA_DIRECTORY:A}" \
        == "${TESTFLIGHT_DERIVED_DATA_DIRECTORY}" \
      && -d "${TESTFLIGHT_DERIVED_DATA_DIRECTORY}" \
      && ! -L "${TESTFLIGHT_DERIVED_DATA_DIRECTORY}" \
      && "$(stat_identity "${TESTFLIGHT_DERIVED_DATA_DIRECTORY}")" \
        == "${TESTFLIGHT_DERIVED_DATA_IDENTITY}" \
      && "$(/usr/bin/stat -f '%u:%Lp:%HT' \
        "${TESTFLIGHT_DERIVED_DATA_DIRECTORY}" 2>/dev/null)" \
        == "${EUID}:700:Directory" ]]
}

function remove_exact_private_file() {
  local file=$1
  [[ ! -e "${file}" && ! -L "${file}" ]] && return 0
  require_private_regular_file "${file}" || return 1
  /bin/rm -- "${file}" || return 1
  [[ ! -e "${file}" && ! -L "${file}" ]]
}

function cleanup_private_build_volume() {
  local cleanup_failed=0

  if [[ -n "${TESTFLIGHT_CONTROL_DIRECTORY:-}" ]]; then
    if [[ -z "${TESTFLIGHT_CONTROL_DIRECTORY_IDENTITY:-}" \
        && "${TESTFLIGHT_CONTROL_DIRECTORY}" \
          == "${PRIVATE_TEMPORARY_ROOT}"/opensteamer-testflight-build-control.* \
        && "${TESTFLIGHT_CONTROL_DIRECTORY:A}" \
          == "${TESTFLIGHT_CONTROL_DIRECTORY}" \
        && "$(stat_identity "${PRIVATE_TEMPORARY_ROOT}")" \
          == "${TESTFLIGHT_CONTROL_PARENT_IDENTITY}" \
        && -d "${TESTFLIGHT_CONTROL_DIRECTORY}" \
        && ! -L "${TESTFLIGHT_CONTROL_DIRECTORY}" \
        && "$(/usr/bin/stat -f '%u:%Lp:%HT' \
          "${TESTFLIGHT_CONTROL_DIRECTORY}" 2>/dev/null)" \
          == "${EUID}:700:Directory" ]]; then
      TESTFLIGHT_CONTROL_DIRECTORY_IDENTITY=$(stat_identity \
        "${TESTFLIGHT_CONTROL_DIRECTORY}")
    fi
    verify_control_directory_identity || cleanup_failed=1
  fi
  if (( cleanup_failed == 0 )) \
      && [[ -n "${TESTFLIGHT_BUILD_IMAGE_CONTAINER:-}" ]]; then
    verify_image_container_identity || cleanup_failed=1
  fi

  # ATTACH_ATTEMPTED is set before hdiutil starts. A signal may be delivered after the kernel
  # attached the image but before hdiutil returned or the success assignment ran, so cleanup must
  # discover the exact image-path association rather than trusting only the success flag.
  if (( cleanup_failed == 0 \
      && (TESTFLIGHT_BUILD_ATTACH_ATTEMPTED == 1 \
        || TESTFLIGHT_BUILD_ATTACHMENT_ACTIVE == 1) )); then
    local discovered_image_device=''
    local discovery_status=0
    if discovered_image_device=$(find_current_attachment_root_device); then
      [[ -z "${TESTFLIGHT_IMAGE_DEVICE:-}" \
          || "${TESTFLIGHT_IMAGE_DEVICE}" == "${discovered_image_device}" ]] \
        || cleanup_failed=1
      if (( cleanup_failed == 0 )); then
        TESTFLIGHT_IMAGE_DEVICE=${discovered_image_device}
        TESTFLIGHT_BUILD_ATTACHMENT_ACTIVE=1
        /usr/bin/hdiutil detach "${TESTFLIGHT_IMAGE_DEVICE}" \
          || cleanup_failed=1
      fi
      if (( cleanup_failed == 0 )); then
        TESTFLIGHT_BUILD_ATTACHMENT_ACTIVE=0
        TESTFLIGHT_BUILD_ATTACH_ATTEMPTED=0
        current_attachment_is_absent || cleanup_failed=1
        if (( cleanup_failed == 0 )); then
          TESTFLIGHT_IMAGE_DEVICE=""
          TESTFLIGHT_IMAGE_PARTITION_DEVICE=""
          TESTFLIGHT_MOUNTED_DEVICE=""
          TESTFLIGHT_MOUNTED_DEVICE_IDENTIFIER=""
          TESTFLIGHT_MOUNTED_PARENT_WHOLE_DISK=""
          TESTFLIGHT_MOUNTED_VOLUME_UUID=""
          TESTFLIGHT_MOUNTED_VOLUME_ROOT_IDENTITY=""
        fi
      fi
    else
      discovery_status=$?
      if (( discovery_status == 1 )); then
        # A single complete, typed hdiutil snapshot proved the exact image path absent.
        TESTFLIGHT_BUILD_ATTACHMENT_ACTIVE=0
        TESTFLIGHT_BUILD_ATTACH_ATTEMPTED=0
      else
        # Malformed or unreadable enumeration is indeterminate, never evidence of absence.
        cleanup_failed=1
      fi
    fi
    if (( cleanup_failed == 0 )) \
        && [[ -n "${TESTFLIGHT_BUILD_MOUNT_POINT_UNDERLAY_IDENTITY:-}" ]]; then
      [[ -d "${TESTFLIGHT_BUILD_MOUNT_POINT}" \
          && ! -L "${TESTFLIGHT_BUILD_MOUNT_POINT}" \
          && "$(stat_identity "${TESTFLIGHT_BUILD_MOUNT_POINT}")" \
            == "${TESTFLIGHT_BUILD_MOUNT_POINT_UNDERLAY_IDENTITY}" ]] \
        || cleanup_failed=1
    fi
  fi

  if (( cleanup_failed == 0 )) \
      && [[ -n "${TESTFLIGHT_BUILD_IMAGE_PATH:-}" ]]; then
    if [[ -e "${TESTFLIGHT_BUILD_IMAGE_PATH}" \
        || -L "${TESTFLIGHT_BUILD_IMAGE_PATH}" ]]; then
      (( TESTFLIGHT_BUILD_CREATE_ATTEMPTED == 1 \
          || TESTFLIGHT_BUILD_IMAGE_CREATED == 1 )) \
        || cleanup_failed=1
      if [[ -z "${TESTFLIGHT_BUILD_IMAGE_IDENTITY:-}" ]]; then
        (( cleanup_failed != 0 )) \
          || pin_partial_image_identity_for_cleanup || cleanup_failed=1
      else
        (( cleanup_failed != 0 )) \
          || verify_image_storage_identity || cleanup_failed=1
      fi
      (( cleanup_failed != 0 )) \
        || current_attachment_is_absent || cleanup_failed=1
      (( cleanup_failed != 0 )) \
        || /bin/rm -- "${TESTFLIGHT_BUILD_IMAGE_PATH}" || cleanup_failed=1
      if (( cleanup_failed == 0 )); then
        [[ ! -e "${TESTFLIGHT_BUILD_IMAGE_PATH}" \
            && ! -L "${TESTFLIGHT_BUILD_IMAGE_PATH}" ]] || cleanup_failed=1
      fi
    elif (( TESTFLIGHT_BUILD_IMAGE_CREATED == 1 )); then
      # A completed image may be absent only after this masked cleanup removed and cleared it.
      cleanup_failed=1
    fi
    if (( cleanup_failed == 0 )); then
      TESTFLIGHT_BUILD_IMAGE_PATH=""
      TESTFLIGHT_BUILD_IMAGE_IDENTITY=""
      TESTFLIGHT_BUILD_IMAGE_CREATED=0
    fi
  fi

  if (( cleanup_failed == 0 )) \
      && [[ -n "${TESTFLIGHT_BUILD_IMAGE_CONTAINER:-}" ]]; then
    verify_image_container_identity || cleanup_failed=1
    if (( cleanup_failed == 0 )); then
      /bin/rmdir -- "${TESTFLIGHT_BUILD_IMAGE_CONTAINER}" \
        || cleanup_failed=1
    fi
    if (( cleanup_failed == 0 )); then
      TESTFLIGHT_BUILD_IMAGE_CONTAINER=""
      TESTFLIGHT_BUILD_IMAGE_CONTAINER_IDENTITY=""
      TESTFLIGHT_BUILD_CREATE_ATTEMPTED=0
    fi
  fi

  if (( cleanup_failed == 0 )) \
      && [[ -n "${TESTFLIGHT_CONTROL_DIRECTORY:-}" ]]; then
    verify_control_directory_identity || cleanup_failed=1
    if (( TESTFLIGHT_BUILD_ATTACHMENT_ACTIVE == 0 )) \
        && [[ -n "${TESTFLIGHT_BUILD_MOUNT_POINT:-}" ]]; then
      if [[ -d "${TESTFLIGHT_BUILD_MOUNT_POINT}" \
          && ! -L "${TESTFLIGHT_BUILD_MOUNT_POINT}" ]]; then
        if [[ -z "${TESTFLIGHT_BUILD_MOUNT_POINT_UNDERLAY_IDENTITY:-}" \
            && "${TESTFLIGHT_BUILD_MOUNT_POINT:h}" \
              == "${TESTFLIGHT_CONTROL_DIRECTORY}" \
            && "$(/usr/bin/stat -f '%u:%Lp:%HT' \
              "${TESTFLIGHT_BUILD_MOUNT_POINT}" 2>/dev/null)" \
              == "${EUID}:700:Directory" ]]; then
          TESTFLIGHT_BUILD_MOUNT_POINT_UNDERLAY_IDENTITY=$(stat_identity \
            "${TESTFLIGHT_BUILD_MOUNT_POINT}")
        fi
        [[ -n "${TESTFLIGHT_BUILD_MOUNT_POINT_UNDERLAY_IDENTITY:-}" \
            && "$(stat_identity "${TESTFLIGHT_BUILD_MOUNT_POINT}")" \
              == "${TESTFLIGHT_BUILD_MOUNT_POINT_UNDERLAY_IDENTITY}" ]] \
          || cleanup_failed=1
      elif [[ -e "${TESTFLIGHT_BUILD_MOUNT_POINT}" \
          || -L "${TESTFLIGHT_BUILD_MOUNT_POINT}" ]]; then
        cleanup_failed=1
      elif [[ -n "${TESTFLIGHT_BUILD_MOUNT_POINT_UNDERLAY_IDENTITY:-}" ]]; then
        cleanup_failed=1
      fi
    fi
    if (( cleanup_failed == 0 )); then
      remove_exact_private_file \
        "${TESTFLIGHT_CONTROL_DIRECTORY}/attachment.plist" || cleanup_failed=1
      remove_exact_private_file \
        "${TESTFLIGHT_CONTROL_DIRECTORY}/backing-root-info.plist" || cleanup_failed=1
      remove_exact_private_file \
        "${TESTFLIGHT_CONTROL_DIRECTORY}/backing-physical-store-info.plist" \
        || cleanup_failed=1
      remove_exact_private_file \
        "${TESTFLIGHT_CONTROL_DIRECTORY}/backing-physical-disk-info.plist" \
        || cleanup_failed=1
      remove_exact_private_file \
        "${TESTFLIGHT_CONTROL_DIRECTORY}/mounted-volume-info.plist" || cleanup_failed=1
      remove_exact_private_file \
        "${TESTFLIGHT_CONTROL_DIRECTORY}/image-partition-info.plist" || cleanup_failed=1
      remove_exact_private_file \
        "${TESTFLIGHT_CONTROL_DIRECTORY}/created-image-info.plist" || cleanup_failed=1
      remove_exact_private_file \
        "${TESTFLIGHT_CONTROL_DIRECTORY}/hdiutil-info.plist" || cleanup_failed=1
      remove_exact_private_file \
        "${TESTFLIGHT_CONTROL_DIRECTORY}/archive-build-settings.json" \
        || cleanup_failed=1
      if (( cleanup_failed == 0 )) \
          && [[ -n "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH:-}" ]]; then
        if [[ -e "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH}" \
            || -L "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH}" ]]; then
          if [[ -z "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_IDENTITY:-}" \
              && "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH}" \
                == "${TESTFLIGHT_CONTROL_DIRECTORY}/xcodebuild.sb" ]] \
              && require_private_regular_file \
                "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH}"; then
            TESTFLIGHT_XCODE_SANDBOX_PROFILE_IDENTITY=$(stat_identity \
              "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH}")
            TESTFLIGHT_XCODE_SANDBOX_PROFILE_SHA256=$(sha256_file \
              "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH}")
            if (( TESTFLIGHT_XCODE_SANDBOX_PROFILE_FD < 0 )); then
              sysopen -r -o nofollow -u TESTFLIGHT_XCODE_SANDBOX_PROFILE_FD \
                "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH}" \
                || cleanup_failed=1
            fi
          fi
          verify_xcode_sandbox_profile_identity || cleanup_failed=1
          (( cleanup_failed != 0 )) \
            || remove_exact_private_file \
              "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH}" \
            || cleanup_failed=1
        elif [[ -n "${TESTFLIGHT_XCODE_SANDBOX_PROFILE_IDENTITY:-}" ]]; then
          cleanup_failed=1
        fi
        if (( cleanup_failed == 0 )); then
          if (( TESTFLIGHT_XCODE_SANDBOX_PROFILE_FD >= 0 )); then
            exec {TESTFLIGHT_XCODE_SANDBOX_PROFILE_FD}>&-
            TESTFLIGHT_XCODE_SANDBOX_PROFILE_FD=-1
          fi
          TESTFLIGHT_XCODE_SANDBOX_PROFILE_PATH=""
          TESTFLIGHT_XCODE_SANDBOX_PROFILE_IDENTITY=""
          TESTFLIGHT_XCODE_SANDBOX_PROFILE_SHA256=""
        fi
      fi
      if (( cleanup_failed == 0 )) \
          && [[ -n "${TESTFLIGHT_BUILD_KEY_PATH:-}" ]]; then
        if [[ -z "${TESTFLIGHT_BUILD_KEY_IDENTITY:-}" \
            && "${TESTFLIGHT_BUILD_KEY_PATH}" \
              == "${TESTFLIGHT_CONTROL_DIRECTORY}/image.key" ]] \
            && require_private_regular_file "${TESTFLIGHT_BUILD_KEY_PATH}"; then
          TESTFLIGHT_BUILD_KEY_IDENTITY=$(stat_identity \
            "${TESTFLIGHT_BUILD_KEY_PATH}")
        fi
        if (( TESTFLIGHT_BUILD_KEY_FD < 0 )); then
          sysopen -r -o nofollow -u TESTFLIGHT_BUILD_KEY_FD \
            "${TESTFLIGHT_BUILD_KEY_PATH}" || cleanup_failed=1
        fi
        verify_build_key_identity || cleanup_failed=1
        (( cleanup_failed != 0 )) \
          || remove_exact_private_file "${TESTFLIGHT_BUILD_KEY_PATH}" \
          || cleanup_failed=1
        if (( cleanup_failed == 0 )); then
          if (( TESTFLIGHT_BUILD_KEY_FD >= 0 )); then
            exec {TESTFLIGHT_BUILD_KEY_FD}>&-
            TESTFLIGHT_BUILD_KEY_FD=-1
          fi
          TESTFLIGHT_BUILD_KEY_PATH=""
          TESTFLIGHT_BUILD_KEY_IDENTITY=""
        fi
      fi
    fi
    if (( cleanup_failed == 0 )); then
      if [[ -n "${TESTFLIGHT_BUILD_MOUNT_POINT:-}" \
          && -d "${TESTFLIGHT_BUILD_MOUNT_POINT}" ]]; then
        /bin/rmdir -- "${TESTFLIGHT_BUILD_MOUNT_POINT}" || cleanup_failed=1
      fi
      if (( cleanup_failed == 0 )); then
        TESTFLIGHT_BUILD_MOUNT_POINT=""
        TESTFLIGHT_BUILD_MOUNT_POINT_UNDERLAY_IDENTITY=""
      fi
    fi
    if (( cleanup_failed == 0 )); then
      /bin/rmdir -- "${TESTFLIGHT_CONTROL_DIRECTORY}" || cleanup_failed=1
      if (( cleanup_failed == 0 )); then
        TESTFLIGHT_CONTROL_DIRECTORY=""
        TESTFLIGHT_CONTROL_DIRECTORY_IDENTITY=""
      fi
    fi
  fi

  if (( cleanup_failed != 0 )); then
    print -u2 -r -- \
      'side-by-side TestFlight guard failed: private build volume cleanup was not identity-safe'
    return 1
  fi

  TESTFLIGHT_CONTROL_DIRECTORY=""
  TESTFLIGHT_BUILD_IMAGE_CONTAINER=""
  TESTFLIGHT_BUILD_IMAGE_PATH=""
  TESTFLIGHT_BUILD_KEY_PATH=""
  TESTFLIGHT_BUILD_KEY_FD=-1
  TESTFLIGHT_BUILD_MOUNT_POINT=""
  TESTFLIGHT_DERIVED_DATA_DIRECTORY=""
  TESTFLIGHT_BUILD_SANDBOX_DIRECTORY=""
  TESTFLIGHT_BUILD_TMP_DIRECTORY=""
  TESTFLIGHT_BUILD_PRODUCTS_DIRECTORY=""
  TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY=""
  TESTFLIGHT_BUILD_DSTROOT_DIRECTORY=""
  TESTFLIGHT_BUILD_PRECOMPILED_DIRECTORY=""
  TESTFLIGHT_BUILD_CACHE_DIRECTORY=""
  TESTFLIGHT_BUILD_MODULE_CACHE_DIRECTORY=""
  TESTFLIGHT_BUILD_PACKAGE_CACHE_DIRECTORY=""
  TESTFLIGHT_BUILD_SOURCE_PACKAGES_DIRECTORY=""
  TESTFLIGHT_PINNED_BUILD_DIRECTORIES=()
  TESTFLIGHT_XCODEBUILD_PINNED_ARGUMENTS=()
  TESTFLIGHT_XCODEBUILD_PINNED_ARGUMENTS_SHA256=""
  TESTFLIGHT_XCODEBUILD_PINNED_ENVIRONMENT=()
  TESTFLIGHT_XCODEBUILD_PINNED_ENVIRONMENT_SHA256=""
  TESTFLIGHT_IMAGE_DEVICE=""
  TESTFLIGHT_IMAGE_PARTITION_DEVICE=""
  TESTFLIGHT_MOUNTED_DEVICE=""
  TESTFLIGHT_BUILD_CREATE_ATTEMPTED=0
  TESTFLIGHT_BUILD_IMAGE_CREATED=0
  TESTFLIGHT_BUILD_ATTACH_ATTEMPTED=0
  TESTFLIGHT_BUILD_ATTACHMENT_ACTIVE=0
  return 0
}

function cleanup_release_scratch() {
  (( RELEASE_SCRATCH_CLEANUP_COMPLETE == 0 )) || return 0
  (( RELEASE_SCRATCH_CLEANUP_RUNNING == 0 )) || return 1
  RELEASE_SCRATCH_CLEANUP_RUNNING=1
  local cleanup_failed=0
  cleanup_private_build_volume || cleanup_failed=1
  RELEASE_SCRATCH_CLEANUP_RUNNING=0
  if (( cleanup_failed == 0 )); then
    RELEASE_SCRATCH_CLEANUP_COMPLETE=1
  fi
  return ${cleanup_failed}
}

function mask_release_cleanup_signals() {
  trap '' HUP INT QUIT TERM
}

function install_release_signal_traps() {
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 131' QUIT
  trap 'exit 143' TERM
}

function cleanup_private_build_volume_signal_masked() {
  mask_release_cleanup_signals
  local cleanup_status=0
  cleanup_release_scratch || cleanup_status=1
  install_release_signal_traps
  return ${cleanup_status}
}

function cleanup_on_exit() {
  local original_status=$?
  mask_release_cleanup_signals
  trap - EXIT
  (( RELEASE_EXIT_CLEANUP_COMPLETE == 0 )) || exit ${original_status}
  if (( RELEASE_EXIT_CLEANUP_RUNNING != 0 )); then
    print -u2 -r -- \
      'side-by-side TestFlight guard failed: recursive release cleanup was rejected'
    exit 1
  fi
  RELEASE_EXIT_CLEANUP_RUNNING=1
  local cleanup_failed=0
  cleanup_release_scratch || cleanup_failed=1
  if (( TESTFLIGHT_ASC_API_KEY_FD >= 0 )); then
    exec {TESTFLIGHT_ASC_API_KEY_FD}>&- || cleanup_failed=1
    TESTFLIGHT_ASC_API_KEY_FD=-1
  fi
  RELEASE_EXIT_CLEANUP_RUNNING=0
  RELEASE_EXIT_CLEANUP_COMPLETE=1
  (( cleanup_failed == 0 )) || exit 1
  exit ${original_status}
}

trap cleanup_on_exit EXIT
install_release_signal_traps

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

function build_settings_entry_value() {
  local settings_json=$1
  local index=$2
  local key=$3
  /usr/bin/plutil -extract "${index}.buildSettings.${key}" raw -o - \
    "${settings_json}" 2>/dev/null
}

function effective_path_is_inside_build_sandbox() {
  local settings_json=$1
  local index=$2
  local key=$3
  local value
  value=$(build_settings_entry_value \
    "${settings_json}" "${index}" "${key}") || return 1
  local canonical_value="${value:A}"
  [[ -n "${value}" \
      && "${canonical_value}" == "${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}/"* ]] \
    || return 1
  [[ "${value}" == "${canonical_value}" ]] && return 0
  verify_xcode_tmp_alias_identity || return 1
  [[ "${value}" == "${XCODE_TMP_ALIAS_ROOT}/"* \
      && "${PRIVATE_TEMPORARY_ROOT}/${value#${XCODE_TMP_ALIAS_ROOT}/}" \
        == "${canonical_value}" ]]
}

function verify_xcode_tmp_alias_identity() {
  [[ -L "${XCODE_TMP_ALIAS_ROOT}" \
      && "$(/usr/bin/readlink "${XCODE_TMP_ALIAS_ROOT}" 2>/dev/null)" \
        == 'private/tmp' \
      && "${XCODE_TMP_ALIAS_ROOT:A}" == "${PRIVATE_TEMPORARY_ROOT}" \
      && "$(/usr/bin/stat -f '%u:%g:%Lp:%HT:%Y' \
        "${XCODE_TMP_ALIAS_ROOT}" 2>/dev/null)" \
        == '0:0:755:Symbolic Link:private/tmp' ]]
}

function xcode_archive_staging_value_matches() {
  local settings_json=$1
  local index=$2
  local key=$3
  local suffix=$4
  verify_xcode_tmp_alias_identity || return 1
  local canonical_expected="${TESTFLIGHT_BUILD_DSTROOT_DIRECTORY}${suffix}"
  [[ "${canonical_expected}" == "${PRIVATE_TEMPORARY_ROOT}/"* \
      && "${canonical_expected:A}" == "${canonical_expected}" \
      && "${canonical_expected}" == "${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}/"* ]] \
    || return 1
  local alias_expected="${XCODE_TMP_ALIAS_ROOT}/${canonical_expected#${PRIVATE_TEMPORARY_ROOT}/}"
  local value
  value=$(build_settings_entry_value \
    "${settings_json}" "${index}" "${key}") || return 1
  [[ "${value}" == "${alias_expected}" \
      && "${value:A}" == "${canonical_expected}" ]]
}

function xcode_archive_intermediate_value_matches() {
  local settings_json=$1
  local index=$2
  local key=$3
  local suffix=$4
  verify_xcode_tmp_alias_identity || return 1
  local canonical_expected="${TESTFLIGHT_DERIVED_DATA_DIRECTORY}/Build/Intermediates.noindex/ArchiveIntermediates/${EXPECTED_SCHEME}/${suffix}"
  [[ "${canonical_expected}" == "${PRIVATE_TEMPORARY_ROOT}/"* \
      && "${canonical_expected:A}" == "${canonical_expected}" \
      && "${canonical_expected}" == "${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}/"* ]] \
    || return 1
  local alias_expected="${XCODE_TMP_ALIAS_ROOT}/${canonical_expected#${PRIVATE_TEMPORARY_ROOT}/}"
  local value
  value=$(build_settings_entry_value \
    "${settings_json}" "${index}" "${key}") || return 1
  [[ ("${value}" == "${canonical_expected}" \
        || "${value}" == "${alias_expected}") \
      && "${value:A}" == "${canonical_expected}" ]]
}

function string_vector_sha256() {
  local argument
  {
    for argument in "$@"; do
      print -rn -- "${#argument}:"
      print -rn -- "${argument}"
    done
  } | /usr/bin/shasum -a 256 \
    | /usr/bin/awk 'NR == 1 && NF == 2 { print $1 }'
}

function xcodebuild_pinned_arguments_sha256() {
  string_vector_sha256 "${TESTFLIGHT_XCODEBUILD_PINNED_ARGUMENTS[@]}"
}

function xcodebuild_pinned_environment_sha256() {
  string_vector_sha256 "${TESTFLIGHT_XCODEBUILD_PINNED_ENVIRONMENT[@]}"
}

function verify_xcodebuild_action_arguments() {
  local destination_contract=$1
  shift
  local -a supplied_arguments=("$@")
  local supplied_argument
  for supplied_argument in "${supplied_arguments[@]}"; do
    [[ "${supplied_argument}" != -DVT* ]] || return 1
  done
  case "${destination_contract}" in
    export)
      verify_xcodebuild_authentication_contract || return 1
      local -a expected_export_arguments=(
        -exportArchive
        -archivePath "${TESTFLIGHT_ARCHIVE_PATH}"
        -exportOptionsPlist "${EXPORT_OPTIONS_PATH}"
        -exportPath "${TESTFLIGHT_EXPORT_DIRECTORY}"
        -allowProvisioningUpdates
        "${TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS[@]}"
      )
      (( ${#supplied_arguments[@]} == ${#expected_export_arguments[@]} )) \
        && [[ "$(string_vector_sha256 "${supplied_arguments[@]}")" \
          == "$(string_vector_sha256 "${expected_export_arguments[@]}")" ]]
      ;;
    resolve|settings|archive)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

function verify_pinned_xcodebuild_filesystem_contract() {
  reject_unsafe_build_environment
  verify_reviewed_xcode_toolchain_identity || return 1
  verify_private_build_volume_identity || return 1
  verify_xcode_sandbox_profile_identity || return 1
  verify_package_dependency_contract || return 1
  verify_xcodebuild_authentication_contract || return 1
  (( ${#TESTFLIGHT_XCODEBUILD_PINNED_ARGUMENTS[@]} > 0 )) || return 1
  (( ${#TESTFLIGHT_XCODEBUILD_PINNED_ENVIRONMENT[@]} > 0 )) || return 1
  [[ "${#TESTFLIGHT_XCODEBUILD_PINNED_ARGUMENTS_SHA256}" == 64 \
      && "$(xcodebuild_pinned_arguments_sha256)" \
        == "${TESTFLIGHT_XCODEBUILD_PINNED_ARGUMENTS_SHA256}" \
      && "${#TESTFLIGHT_XCODEBUILD_PINNED_ENVIRONMENT_SHA256}" == 64 \
      && "$(xcodebuild_pinned_environment_sha256)" \
        == "${TESTFLIGHT_XCODEBUILD_PINNED_ENVIRONMENT_SHA256}" ]] || return 1
  [[ "${TESTFLIGHT_BUILD_TMP_DIRECTORY}" \
        == "${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}/tmp" \
      && "${TESTFLIGHT_DERIVED_DATA_DIRECTORY}" \
        == "${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}/DerivedData" \
      && "${TESTFLIGHT_BUILD_PRODUCTS_DIRECTORY}" \
        == "${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}/Products" \
      && "${TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY}" \
        == "${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}/Intermediates" \
      && "${TESTFLIGHT_BUILD_DSTROOT_DIRECTORY}" \
        == "${TESTFLIGHT_DERIVED_DATA_DIRECTORY}/Build/Intermediates.noindex/ArchiveIntermediates/${EXPECTED_SCHEME}/InstallationBuildProductsLocation" \
      && "${TESTFLIGHT_BUILD_PRECOMPILED_DIRECTORY}" \
        == "${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}/SharedPrecompiledHeaders" \
      && "${TESTFLIGHT_BUILD_CACHE_DIRECTORY}" \
        == "${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}/Caches" \
      && "${TESTFLIGHT_BUILD_MODULE_CACHE_DIRECTORY}" \
        == "${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}/ModuleCache.noindex" \
      && "${TESTFLIGHT_BUILD_PACKAGE_CACHE_DIRECTORY}" \
        == "${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}/PackageCache" \
      && "${TESTFLIGHT_BUILD_SOURCE_PACKAGES_DIRECTORY}" \
        == "${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}/SourcePackages" ]]
}

function run_xcodebuild_command_for_destination_contract() {
  local destination_contract=$1
  shift
  case "${destination_contract}" in
    resolve)
      # Xcode's package resolver applies its own child sandbox. An outer Seatbelt
      # profile makes that supported child sandbox fail with EPERM. Resolve the
      # exact Package.resolved graph into the pinned encrypted cache first, while
      # retaining the scrubbed environment and reviewed Xcode command.
      "$@"
      ;;
    settings|archive)
      run_with_pinned_xcode_sandbox_profile "${destination_contract}" "$@"
      ;;
    export)
      # The supported upload action launches Xcode's distribution service. Its
      # launchd job cannot be authorized by a filtered Seatbelt rule, so run only
      # this exact, fully pinned export vector without the outer profile.
      "$@"
      ;;
    *)
      return 1
      ;;
  esac
}

function run_pinned_xcodebuild() {
  local destination_contract=$1
  shift
  verify_xcodebuild_action_arguments \
    "${destination_contract}" "$@" || return 1
  verify_pinned_xcodebuild_filesystem_contract || return 1
  case "${destination_contract}" in
    archive|export)
      # Settings resolution may reuse the process-local deep seal, but any command
      # that creates or distributes the release gets a fresh whole-Xcode seal.
      verify_reviewed_xcode_deep_signature || return 1
      verify_pinned_xcodebuild_filesystem_contract || return 1
      ;;
  esac
  case "${destination_contract}" in
    resolve|settings)
      verify_control_directory_identity || return 1
      ;;
    archive)
      verify_archive_exec_destinations || return 1
      ;;
    export)
      verify_export_exec_destinations || return 1
      ;;
    *)
      return 1
      ;;
  esac
  local -a pinned_command=(
    /usr/bin/env -i
    "${TESTFLIGHT_XCODEBUILD_PINNED_ENVIRONMENT[@]}"
    "${EXPECTED_XCODEBUILD_REAL_PATH}"
    "$@"
  )
  local command_status=0
  run_xcodebuild_command_for_destination_contract \
    "${destination_contract}" "${pinned_command[@]}" || command_status=$?
  verify_xcodebuild_action_arguments \
    "${destination_contract}" "$@" || command_status=1
  case "${destination_contract}" in
    archive|export)
      verify_reviewed_xcode_deep_signature || command_status=1
      ;;
  esac
  verify_pinned_xcodebuild_filesystem_contract || command_status=1
  case "${destination_contract}" in
    resolve|settings)
      verify_control_directory_identity || command_status=1
      ;;
    archive)
      verify_archive_destination_identity || command_status=1
      ;;
    export)
      verify_export_destination_identity || command_status=1
      ;;
  esac
  return ${command_status}
}

function resolve_pinned_package_dependencies() {
  verify_package_dependency_contract || return 1
  run_pinned_xcodebuild resolve \
    -resolvePackageDependencies \
    "${TESTFLIGHT_XCODEBUILD_PINNED_ARGUMENTS[@]}" \
    || return 1
  verify_pinned_xcodebuild_filesystem_contract
}

function verify_effective_archive_build_roots() {
  local destination="${TESTFLIGHT_CONTROL_DIRECTORY}/archive-build-settings.json"
  write_private_plist \
    "${destination}" run_pinned_xcodebuild settings \
    "${TESTFLIGHT_XCODEBUILD_PINNED_ARGUMENTS[@]}" \
    archive -showBuildSettings -json || return 2
  local entry_count
  entry_count=$(plist_root_array_count "${destination}") || return 1
  (( entry_count > 0 )) || return 1
  local entry_index
  local target_name
  local app_target_count=0
  local derived_key
  for (( entry_index = 0; entry_index < entry_count; entry_index += 1 )); do
    target_name=$(plist_typed_raw_value \
      "${destination}" "${entry_index}.target" string) || return 1
    [[ "$(build_settings_entry_value "${destination}" "${entry_index}" SHARED_PRECOMPS_DIR)" \
          == "${TESTFLIGHT_BUILD_PRECOMPILED_DIRECTORY}" \
        && "$(build_settings_entry_value "${destination}" "${entry_index}" CACHE_ROOT)" \
          == "${TESTFLIGHT_BUILD_CACHE_DIRECTORY}" \
        && "$(build_settings_entry_value "${destination}" "${entry_index}" MODULE_CACHE_DIR)" \
          == "${TESTFLIGHT_BUILD_MODULE_CACHE_DIRECTORY}" \
        && "$(build_settings_entry_value "${destination}" "${entry_index}" CLANG_MODULE_CACHE_PATH)" \
          == "${TESTFLIGHT_BUILD_MODULE_CACHE_DIRECTORY}" \
        && "$(build_settings_entry_value "${destination}" "${entry_index}" SWIFT_MODULE_CACHE_PATH)" \
          == "${TESTFLIGHT_BUILD_MODULE_CACHE_DIRECTORY}" ]] || return 1
    xcode_archive_staging_value_matches \
      "${destination}" "${entry_index}" DSTROOT '' || return 1
    xcode_archive_staging_value_matches \
      "${destination}" "${entry_index}" INSTALL_ROOT '' || return 1
    xcode_archive_staging_value_matches \
      "${destination}" "${entry_index}" INSTALL_DIR /Applications || return 1
    xcode_archive_staging_value_matches \
      "${destination}" "${entry_index}" TARGET_BUILD_DIR /Applications || return 1
    for derived_key in BUILD_DIR BUILD_ROOT SYMROOT; do
      xcode_archive_intermediate_value_matches \
        "${destination}" "${entry_index}" "${derived_key}" \
        BuildProductsPath || return 1
    done
    for derived_key in \
        BUILT_PRODUCTS_DIR \
        CONFIGURATION_BUILD_DIR \
        DWARF_DSYM_FOLDER_PATH; do
      xcode_archive_intermediate_value_matches \
        "${destination}" "${entry_index}" "${derived_key}" \
        "BuildProductsPath/${EXPECTED_CONFIGURATION}-iphoneos" || return 1
    done
    xcode_archive_intermediate_value_matches \
      "${destination}" "${entry_index}" SIGNATURE_METADATA_FOLDER_PATH \
      BuildProductsPath/Signatures || return 1
    xcode_archive_intermediate_value_matches \
      "${destination}" "${entry_index}" \
      SWIFT_STDLIB_TOOL_UNSIGNED_DESTINATION_DIR \
      BuildProductsPath/SwiftSupport || return 1
    for derived_key in OBJROOT PROJECT_TEMP_ROOT; do
      xcode_archive_intermediate_value_matches \
        "${destination}" "${entry_index}" "${derived_key}" \
        IntermediateBuildFilesPath || return 1
    done
    for derived_key in \
        CONFIGURATION_TEMP_DIR \
        DERIVED_FILE_DIR \
        DERIVED_FILES_DIR \
        DERIVED_SOURCES_DIR \
        INDEX_DATA_STORE_DIR \
        LOCSYMROOT \
        OBJECT_FILE_DIR \
        OBJECT_FILE_DIR_normal \
        PROJECT_DERIVED_DATA_DIR \
        PROJECT_DERIVED_FILE_DIR \
        PROJECT_TEMP_DIR \
        REZ_COLLECTOR_DIR \
        SHARED_DERIVED_FILE_DIR \
        TARGET_TEMP_DIR \
        TEMP_DIR \
        TEMP_FILES_DIR \
        TEMP_ROOT; do
      effective_path_is_inside_build_sandbox \
        "${destination}" "${entry_index}" "${derived_key}" || return 1
    done
    if [[ "${target_name}" == opensteamer ]]; then
      (( app_target_count += 1 ))
      [[ "$(build_settings_entry_value \
            "${destination}" "${entry_index}" PRODUCT_BUNDLE_IDENTIFIER)" \
            == "${EXPECTED_BUNDLE_IDENTIFIER}" \
          && "$(build_settings_entry_value \
            "${destination}" "${entry_index}" CURRENT_PROJECT_VERSION)" \
            == "${EXPECTED_BUILD_NUMBER}" \
          && "$(build_settings_entry_value \
            "${destination}" "${entry_index}" DEVELOPMENT_TEAM)" \
            == "${EXPECTED_TEAM_ID}" \
          && "$(build_settings_entry_value \
            "${destination}" "${entry_index}" CODE_SIGN_STYLE)" \
            == 'Automatic' \
          && ( "$(build_settings_entry_value \
            "${destination}" "${entry_index}" CODE_SIGN_IDENTITY)" \
              == 'iPhone Developer' \
            || "$(build_settings_entry_value \
              "${destination}" "${entry_index}" CODE_SIGN_IDENTITY)" \
              == 'Apple Development' ) \
          && "$(build_settings_entry_value \
            "${destination}" "${entry_index}" OPENSTEAMER_RENDEZVOUS_URL)" \
            == "${EXPECTED_RENDEZVOUS_URL}" ]] || return 1
    fi
  done
  (( app_target_count == 1 ))
}

function verify_static_contract() {
  [[ "${EXPECTED_BUNDLE_IDENTIFIER}" != "${PROTECTED_BUNDLE_IDENTIFIER}" ]] \
    || fail "isolated and protected bundle identifiers are equal"
  verify_app_store_connect_api_key_static_contract \
    || fail "App Store Connect API-key constants are not the reviewed exact contract"
  [[ -d "${PROJECT_PATH}" ]] || fail "Xcode project is missing"
  [[ -f "${SCHEME_PATH}" ]] || fail "archive-only shared scheme is missing"
  [[ -f "${SCHEME_SOURCE_PATH}" && ! -L "${SCHEME_SOURCE_PATH}" ]] \
    || fail "reviewed archive-only scheme source is missing or is a symlink"
  [[ -x "${SCHEME_RESTORE_SCRIPT_PATH}" && ! -L "${SCHEME_RESTORE_SCRIPT_PATH}" ]] \
    || fail "XcodeGen archive-only scheme restorer is missing, non-executable, or a symlink"
  /usr/bin/cmp -s "${SCHEME_SOURCE_PATH}" "${SCHEME_PATH}" \
    || fail "generated scheme differs from the reviewed archive-only source"
  [[ -f "${EXPORT_OPTIONS_PATH}" && ! -L "${EXPORT_OPTIONS_PATH}" \
      && "${EXPORT_OPTIONS_PATH:A}" == "${EXPORT_OPTIONS_PATH}" ]] \
    || fail "dedicated export options are missing, non-canonical, or a symlink"
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
  local executable_scheme_actions
  executable_scheme_actions=$(/usr/bin/xmllint --xpath \
    'count(/Scheme//PreActions | /Scheme//PostActions | /Scheme//ExecutionAction)' \
    "${SCHEME_PATH}" 2>/dev/null) \
    || fail "could not inspect scheme executable actions"
  [[ "${executable_scheme_actions}" == '0' ]] \
    || fail "scheme contains a pre-action, post-action, or execution action"
  local project_file="${PROJECT_PATH}/project.pbxproj"
  [[ -f "${project_file}" && ! -L "${project_file}" ]] \
    || fail "Xcode project file is missing or is a symlink"
  if /usr/bin/grep -Eq \
      'isa = PBX(ShellScript|AppleScript)BuildPhase;|isa = PBXBuildRule;|shellScript = ' \
      "${project_file}"; then
    fail "Xcode project contains an executable shell, AppleScript, or build-rule action"
  fi

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

function pin_export_options_identity() {
  [[ -f "${EXPORT_OPTIONS_PATH}" \
      && ! -L "${EXPORT_OPTIONS_PATH}" \
      && "${EXPORT_OPTIONS_PATH:A}" == "${EXPORT_OPTIONS_PATH}" ]] \
    || return 1
  EXPORT_OPTIONS_IDENTITY=$(stat_identity "${EXPORT_OPTIONS_PATH}")
  EXPORT_OPTIONS_SHA256=$(sha256_file "${EXPORT_OPTIONS_PATH}")
  sysopen -r -o nofollow -u EXPORT_OPTIONS_FD "${EXPORT_OPTIONS_PATH}" \
    || return 1
  [[ -n "${EXPORT_OPTIONS_IDENTITY}" \
      && "${#EXPORT_OPTIONS_SHA256}" == 64 \
      && "${EXPORT_OPTIONS_PATH}" -ef "/dev/fd/${EXPORT_OPTIONS_FD}" ]]
}

function verify_export_options_identity() {
  [[ -n "${EXPORT_OPTIONS_IDENTITY:-}" \
      && "${#EXPORT_OPTIONS_SHA256}" == 64 \
      && -f "${EXPORT_OPTIONS_PATH}" \
      && ! -L "${EXPORT_OPTIONS_PATH}" \
      && "${EXPORT_OPTIONS_PATH:A}" == "${EXPORT_OPTIONS_PATH}" \
      && "$(stat_identity "${EXPORT_OPTIONS_PATH}")" \
        == "${EXPORT_OPTIONS_IDENTITY}" \
      && "$(sha256_file "${EXPORT_OPTIONS_PATH}")" \
        == "${EXPORT_OPTIONS_SHA256}" \
      && ${EXPORT_OPTIONS_FD} -ge 0 \
      && -e "/dev/fd/${EXPORT_OPTIONS_FD}" \
      && "${EXPORT_OPTIONS_PATH}" -ef "/dev/fd/${EXPORT_OPTIONS_FD}" ]]
}

function initialize_private_testflight_build_volume() {
  [[ "${PRIVATE_TEMPORARY_ROOT:A}" == "${PRIVATE_TEMPORARY_ROOT}" \
      && -d "${PRIVATE_TEMPORARY_ROOT}" \
      && ! -L "${PRIVATE_TEMPORARY_ROOT}" ]] \
    || fail "fixed private temporary root is unavailable or unsafe"
  TESTFLIGHT_CONTROL_PARENT_IDENTITY=$(stat_identity "${PRIVATE_TEMPORARY_ROOT}")
  [[ -n "${TESTFLIGHT_CONTROL_PARENT_IDENTITY}" ]] \
    || fail "could not pin the private temporary root"

  TESTFLIGHT_CONTROL_DIRECTORY=$(/usr/bin/mktemp -d \
    "${PRIVATE_TEMPORARY_ROOT}/opensteamer-testflight-build-control.XXXXXX") \
    || fail "could not create private build-volume control directory"
  /bin/chmod 700 "${TESTFLIGHT_CONTROL_DIRECTORY}" \
    || fail "could not protect build-volume control directory"
  require_canonical_safe_path \
    "${TESTFLIGHT_CONTROL_DIRECTORY}" "${PRIVATE_TEMPORARY_ROOT}" \
    || fail "build-volume control path is not canonical and private"
  TESTFLIGHT_CONTROL_DIRECTORY_IDENTITY=$(stat_identity \
    "${TESTFLIGHT_CONTROL_DIRECTORY}")
  verify_control_directory_identity \
    || fail "build-volume control directory failed identity validation"
  create_xcode_sandbox_profile \
    || fail "could not create the protected-path Xcode sandbox profile"

  TESTFLIGHT_BUILD_MOUNT_POINT="${TESTFLIGHT_CONTROL_DIRECTORY}/mount"
  require_canonical_safe_path \
    "${TESTFLIGHT_BUILD_MOUNT_POINT}" "${TESTFLIGHT_CONTROL_DIRECTORY}" \
    || fail "private build mount path is not canonical"
  /bin/mkdir -m 700 "${TESTFLIGHT_BUILD_MOUNT_POINT}" \
    || fail "could not create private build mount point"
  /bin/chmod 700 "${TESTFLIGHT_BUILD_MOUNT_POINT}" \
    || fail "could not protect private build mount point"
  TESTFLIGHT_BUILD_MOUNT_POINT_UNDERLAY_IDENTITY=$(stat_identity \
    "${TESTFLIGHT_BUILD_MOUNT_POINT}")
  [[ -n "${TESTFLIGHT_BUILD_MOUNT_POINT_UNDERLAY_IDENTITY}" \
      && "$(/usr/bin/stat -f '%u:%Lp:%HT' \
        "${TESTFLIGHT_BUILD_MOUNT_POINT}" 2>/dev/null)" \
        == "${EUID}:700:Directory" ]] \
    || fail "private build mount point failed identity validation"

  TESTFLIGHT_BUILD_KEY_PATH="${TESTFLIGHT_CONTROL_DIRECTORY}/image.key"
  local -i build_key_write_fd=-1
  sysopen -w -o creat,excl,nofollow -m 600 -u build_key_write_fd \
    "${TESTFLIGHT_BUILD_KEY_PATH}" \
    || fail "could not exclusively create a private build-image key"
  /usr/bin/openssl rand -hex 32 >"/dev/fd/${build_key_write_fd}" \
    || fail "could not populate the private build-image key"
  /bin/chmod 600 "/dev/fd/${build_key_write_fd}" \
    || fail "could not protect the build-image key"
  exec {build_key_write_fd}>&-
  sysopen -r -o nofollow -u TESTFLIGHT_BUILD_KEY_FD \
    "${TESTFLIGHT_BUILD_KEY_PATH}" \
    || fail "could not pin the private build-image key"
  require_private_regular_file "${TESTFLIGHT_BUILD_KEY_PATH}" \
    || fail "build-image key failed private-file validation"
  TESTFLIGHT_BUILD_KEY_IDENTITY=$(stat_identity "${TESTFLIGHT_BUILD_KEY_PATH}")

  [[ "${TESTFLIGHT_BUILD_ROOT:A}" == "${TESTFLIGHT_BUILD_ROOT}" \
      && "${TESTFLIGHT_BUILD_ROOT:h}" == '/Volumes' \
      && -d "${TESTFLIGHT_BUILD_ROOT}" \
      && ! -L "${TESTFLIGHT_BUILD_ROOT}" ]] \
    || fail "fixed T7 build root is unavailable or unsafe"
  TESTFLIGHT_BUILD_ROOT_PARENT_IDENTITY=$(stat_identity "${TESTFLIGHT_BUILD_ROOT:h}")
  TESTFLIGHT_BUILD_ROOT_IDENTITY=$(stat_identity "${TESTFLIGHT_BUILD_ROOT}")
  write_backing_root_info || fail "could not inspect fixed T7 build root"
  local backing_info="${TESTFLIGHT_CONTROL_DIRECTORY}/backing-root-info.plist"
  TESTFLIGHT_BUILD_ROOT_DEVICE_IDENTIFIER=$(plist_raw_value \
    "${backing_info}" DeviceIdentifier) \
    || fail "T7 build-root device identifier is missing"
  TESTFLIGHT_BUILD_ROOT_PARENT_WHOLE_DISK=$(plist_raw_value \
    "${backing_info}" ParentWholeDisk) \
    || fail "T7 build-root parent device is missing"
  TESTFLIGHT_BUILD_ROOT_VOLUME_UUID=$(plist_raw_value \
    "${backing_info}" VolumeUUID) \
    || fail "T7 build-root volume UUID is missing"
  local physical_store_count
  physical_store_count=$(plist_array_count \
    "${backing_info}" APFSPhysicalStores) \
    || fail "T7 build-root physical-store array is missing or malformed"
  (( physical_store_count == 1 )) \
    || fail "T7 build root must have exactly one reviewed physical store"
  TESTFLIGHT_BUILD_ROOT_PHYSICAL_STORE_IDENTIFIER=$(plist_raw_value \
    "${backing_info}" APFSPhysicalStores.0.APFSPhysicalStore) \
    || fail "T7 build-root physical-store identifier is missing"
  write_backing_physical_store_info \
    || fail "could not inspect T7 physical-store identity"
  local physical_store_info="${TESTFLIGHT_CONTROL_DIRECTORY}/backing-physical-store-info.plist"
  TESTFLIGHT_BUILD_ROOT_PHYSICAL_WHOLE_DISK=$(plist_raw_value \
    "${physical_store_info}" ParentWholeDisk) \
    || fail "T7 physical whole-disk identifier is missing"
  [[ -n "${TESTFLIGHT_BUILD_ROOT_IDENTITY}" \
      && -n "${TESTFLIGHT_BUILD_ROOT_PARENT_IDENTITY}" \
      && "${TESTFLIGHT_BUILD_ROOT_DEVICE_IDENTIFIER}" == disk<->s<->* \
      && "${TESTFLIGHT_BUILD_ROOT_PARENT_WHOLE_DISK}" == disk<-> \
      && "${TESTFLIGHT_BUILD_ROOT_PHYSICAL_STORE_IDENTIFIER}" == disk<->s<-> \
      && "${TESTFLIGHT_BUILD_ROOT_PHYSICAL_WHOLE_DISK}" == disk<-> \
      && "${TESTFLIGHT_BUILD_ROOT_VOLUME_UUID}" \
        == "${EXPECTED_TESTFLIGHT_BUILD_ROOT_VOLUME_UUID}" \
      && "$(plist_raw_value "${backing_info}" VolumeName)" \
        == "${EXPECTED_TESTFLIGHT_BUILD_ROOT_VOLUME_NAME}" \
      && "$(plist_raw_value "${backing_info}" BusProtocol)" \
        == "${EXPECTED_TESTFLIGHT_BUILD_ROOT_BUS_PROTOCOL}" \
      && "$(plist_raw_value "${backing_info}" Internal)" == 'false' \
      && "$(plist_raw_value "${backing_info}" OSInternalMedia)" == 'false' \
      && "$(plist_raw_value "${backing_info}" RemovableMediaOrExternalDevice)" == 'true' ]] \
    || fail "T7 build root does not match the reviewed external-volume identity"
  verify_backing_build_root_identity \
    || fail "T7 build root changed during initialization"

  TESTFLIGHT_BUILD_IMAGE_CONTAINER=$(/usr/bin/mktemp -d \
    "${TESTFLIGHT_BUILD_ROOT}/.opensteamer-testflight-build-image.XXXXXX") \
    || fail "could not create unique T7 build-image container"
  /bin/chmod 700 "${TESTFLIGHT_BUILD_IMAGE_CONTAINER}" \
    || fail "could not protect T7 build-image container metadata"
  require_canonical_safe_path \
    "${TESTFLIGHT_BUILD_IMAGE_CONTAINER}" "${TESTFLIGHT_BUILD_ROOT}" \
    || fail "T7 build-image container path is not canonical"
  TESTFLIGHT_BUILD_IMAGE_CONTAINER_IDENTITY=$(stat_identity \
    "${TESTFLIGHT_BUILD_IMAGE_CONTAINER}")
  [[ -n "${TESTFLIGHT_BUILD_IMAGE_CONTAINER_IDENTITY}" ]] \
    || fail "could not pin T7 build-image container"

  TESTFLIGHT_BUILD_IMAGE_PATH="${TESTFLIGHT_BUILD_IMAGE_CONTAINER}/${TESTFLIGHT_BUILD_IMAGE_BASENAME}.sparseimage"
  require_canonical_safe_path \
    "${TESTFLIGHT_BUILD_IMAGE_PATH}" "${TESTFLIGHT_BUILD_IMAGE_CONTAINER}" \
    || fail "T7 build-image path is not canonical"
  [[ ! -e "${TESTFLIGHT_BUILD_IMAGE_PATH}" \
      && ! -L "${TESTFLIGHT_BUILD_IMAGE_PATH}" ]] \
    || fail "unique T7 build-image path already exists"
  verify_build_key_identity \
    || fail "build-image key changed before encrypted image creation"
  TESTFLIGHT_BUILD_CREATE_ATTEMPTED=1
  run_with_pinned_build_key_stdin /usr/bin/hdiutil create \
    -size "${TESTFLIGHT_BUILD_IMAGE_SIZE}" \
    -type SPARSE \
    -fs APFS \
    -volname "${TESTFLIGHT_BUILD_VOLUME_NAME}" \
    -encryption AES-256 \
    -stdinpass \
    "${TESTFLIGHT_BUILD_IMAGE_PATH}" >/dev/null \
    || fail "could not create encrypted sparse APFS build image"
  TESTFLIGHT_BUILD_IMAGE_CREATED=1
  /bin/chmod 600 "${TESTFLIGHT_BUILD_IMAGE_PATH}" \
    || fail "could not protect T7 build-image metadata"
  [[ -f "${TESTFLIGHT_BUILD_IMAGE_PATH}" \
      && ! -L "${TESTFLIGHT_BUILD_IMAGE_PATH}" ]] \
    || fail "encrypted sparse APFS build image is missing or unsafe"
  TESTFLIGHT_BUILD_IMAGE_IDENTITY=$(stat_identity "${TESTFLIGHT_BUILD_IMAGE_PATH}")
  verify_image_storage_identity \
    || fail "T7 build-image identity changed after creation"
  write_and_verify_created_image_info \
    || fail "created sparse image is not the exact encrypted APFS content"

  local attachment_plist="${TESTFLIGHT_CONTROL_DIRECTORY}/attachment.plist"
  (
    set -o noclobber
    umask 077
    : >"${attachment_plist}"
  ) || fail "could not create a private attachment record"
  require_private_regular_file "${attachment_plist}" \
    || fail "initial attachment record failed private-file validation"
  verify_image_storage_identity \
    || fail "T7 build-image identity changed before attachment"
  verify_build_key_identity \
    || fail "build-image key changed before attachment"
  TESTFLIGHT_BUILD_ATTACH_ATTEMPTED=1
  write_private_plist "${attachment_plist}" run_with_pinned_build_key_stdin \
    /usr/bin/hdiutil attach \
    -plist \
    -nobrowse \
    -noautoopen \
    -owners on \
    -mountpoint "${TESTFLIGHT_BUILD_MOUNT_POINT}" \
    -stdinpass \
    "${TESTFLIGHT_BUILD_IMAGE_PATH}" \
    || fail "could not attach private APFS build image"
  TESTFLIGHT_BUILD_ATTACHMENT_ACTIVE=1
  require_private_regular_file "${attachment_plist}" \
    || fail "build-image attachment record failed validation"
  local devices
  devices=$(attachment_devices_from_plist "${attachment_plist}" '') \
    || fail "could not bind attached image and mounted-volume devices"
  TESTFLIGHT_IMAGE_DEVICE=${devices%%|*}
  local devices_after_root=${devices#*|}
  TESTFLIGHT_MOUNTED_DEVICE=${devices_after_root%%|*}
  TESTFLIGHT_IMAGE_PARTITION_DEVICE=${devices_after_root#*|}
  verify_hdiutil_attachment_identity \
    || fail "attached image association or encrypted state failed identity validation"

  write_image_partition_info \
    || fail "could not inspect the attached image partition"
  write_mounted_volume_info || fail "could not inspect mounted APFS build volume"
  local partition_info="${TESTFLIGHT_CONTROL_DIRECTORY}/image-partition-info.plist"
  local attached_partition_uuid
  attached_partition_uuid=$(plist_raw_value "${partition_info}" DiskUUID) \
    || fail "attached image partition UUID is missing"
  local mounted_info="${TESTFLIGHT_CONTROL_DIRECTORY}/mounted-volume-info.plist"
  TESTFLIGHT_MOUNTED_DEVICE_IDENTIFIER=$(plist_raw_value \
    "${mounted_info}" DeviceIdentifier) \
    || fail "mounted build device identifier is missing"
  TESTFLIGHT_MOUNTED_PARENT_WHOLE_DISK=$(plist_raw_value \
    "${mounted_info}" ParentWholeDisk) \
    || fail "mounted build parent device is missing"
  TESTFLIGHT_MOUNTED_VOLUME_UUID=$(plist_raw_value \
    "${mounted_info}" VolumeUUID) \
    || fail "mounted build volume UUID is missing"
  [[ "${TESTFLIGHT_MOUNTED_DEVICE}" \
        == "/dev/${TESTFLIGHT_MOUNTED_DEVICE_IDENTIFIER}" \
      && "$(plist_raw_value "${partition_info}" DeviceNode)" \
        == "${TESTFLIGHT_IMAGE_PARTITION_DEVICE}" \
      && "$(plist_raw_value "${partition_info}" ParentWholeDisk)" \
        == "${TESTFLIGHT_IMAGE_DEVICE#/dev/}" \
      && "$(plist_raw_value "${partition_info}" Content)" == 'Apple_APFS' \
      && "${attached_partition_uuid:u}" \
        == "${TESTFLIGHT_BUILD_IMAGE_PARTITION_UUID}" \
      && "${TESTFLIGHT_MOUNTED_DEVICE_IDENTIFIER}" == disk<->* \
      && "${TESTFLIGHT_MOUNTED_PARENT_WHOLE_DISK}" == disk<-> \
      && "${#TESTFLIGHT_MOUNTED_VOLUME_UUID}" == 36 \
      && "$(plist_raw_value "${mounted_info}" GlobalPermissionsEnabled)" == 'true' \
      && "$(plist_raw_value "${mounted_info}" FilesystemType)" == 'apfs' \
      && "$(plist_raw_value "${mounted_info}" VolumeName)" \
        == "${TESTFLIGHT_BUILD_VOLUME_NAME}" ]] \
    || fail "mounted build volume is not the expected ownership-enforcing APFS volume"
  TESTFLIGHT_MOUNTED_VOLUME_ROOT_IDENTITY=$(stat_identity \
    "${TESTFLIGHT_BUILD_MOUNT_POINT}")

  TESTFLIGHT_BUILD_SANDBOX_DIRECTORY="${TESTFLIGHT_BUILD_MOUNT_POINT}/BuildSandbox"
  require_canonical_safe_path \
    "${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}" "${TESTFLIGHT_BUILD_MOUNT_POINT}" \
    || fail "build sandbox path is not canonical inside the private build volume"
  /bin/mkdir -m 700 "${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}" \
    || fail "could not create the private build sandbox"
  /bin/chmod 700 "${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}" \
    || fail "could not protect the private build sandbox"
  TESTFLIGHT_BUILD_SANDBOX_IDENTITY=$(stat_identity \
    "${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}")
  [[ -n "${TESTFLIGHT_BUILD_SANDBOX_IDENTITY}" ]] \
    || fail "could not pin the private build sandbox"

  TESTFLIGHT_BUILD_TMP_DIRECTORY="${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}/tmp"
  TESTFLIGHT_DERIVED_DATA_DIRECTORY="${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}/DerivedData"
  TESTFLIGHT_BUILD_PRODUCTS_DIRECTORY="${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}/Products"
  TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY="${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}/Intermediates"
  # Xcode's archive action must own its product, intermediate, and installation
  # topology. Overriding SYMROOT, OBJROOT, DSTROOT, INSTALL_ROOT, or INSTALL_DIR
  # splits compilation from archive finalization and leaves an incomplete archive
  # even after compilation and signing pass.
  TESTFLIGHT_BUILD_DSTROOT_DIRECTORY="${TESTFLIGHT_DERIVED_DATA_DIRECTORY}/Build/Intermediates.noindex/ArchiveIntermediates/${EXPECTED_SCHEME}/InstallationBuildProductsLocation"
  TESTFLIGHT_BUILD_PRECOMPILED_DIRECTORY="${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}/SharedPrecompiledHeaders"
  TESTFLIGHT_BUILD_CACHE_DIRECTORY="${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}/Caches"
  TESTFLIGHT_BUILD_MODULE_CACHE_DIRECTORY="${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}/ModuleCache.noindex"
  TESTFLIGHT_BUILD_PACKAGE_CACHE_DIRECTORY="${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}/PackageCache"
  TESTFLIGHT_BUILD_SOURCE_PACKAGES_DIRECTORY="${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}/SourcePackages"
  TESTFLIGHT_PINNED_BUILD_DIRECTORIES=()
  local build_directory
  for build_directory in \
      "${TESTFLIGHT_BUILD_TMP_DIRECTORY}" \
      "${TESTFLIGHT_DERIVED_DATA_DIRECTORY}" \
      "${TESTFLIGHT_BUILD_PRODUCTS_DIRECTORY}" \
      "${TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY}" \
      "${TESTFLIGHT_BUILD_PRECOMPILED_DIRECTORY}" \
      "${TESTFLIGHT_BUILD_CACHE_DIRECTORY}" \
      "${TESTFLIGHT_BUILD_MODULE_CACHE_DIRECTORY}" \
      "${TESTFLIGHT_BUILD_PACKAGE_CACHE_DIRECTORY}" \
      "${TESTFLIGHT_BUILD_SOURCE_PACKAGES_DIRECTORY}"; do
    pin_private_build_directory \
      "${build_directory}" "${TESTFLIGHT_BUILD_SANDBOX_DIRECTORY}" \
      || fail "could not atomically create and pin private build directory ${build_directory:t}"
  done
  TESTFLIGHT_DERIVED_DATA_IDENTITY=$(stat_identity \
    "${TESTFLIGHT_DERIVED_DATA_DIRECTORY}")
  TESTFLIGHT_XCODEBUILD_PINNED_ARGUMENTS=(
    -project "${PROJECT_PATH}"
    -scheme "${EXPECTED_SCHEME}"
    -configuration "${EXPECTED_CONFIGURATION}"
    -sdk iphoneos
    -derivedDataPath "${TESTFLIGHT_DERIVED_DATA_DIRECTORY}"
    -clonedSourcePackagesDirPath "${TESTFLIGHT_BUILD_SOURCE_PACKAGES_DIRECTORY}"
    -packageCachePath "${TESTFLIGHT_BUILD_PACKAGE_CACHE_DIRECTORY}"
    -onlyUsePackageVersionsFromResolvedFile
    -skipPackageUpdates
    "SHARED_PRECOMPS_DIR=${TESTFLIGHT_BUILD_PRECOMPILED_DIRECTORY}"
    "CACHE_ROOT=${TESTFLIGHT_BUILD_CACHE_DIRECTORY}"
    "MODULE_CACHE_DIR=${TESTFLIGHT_BUILD_MODULE_CACHE_DIRECTORY}"
    "CLANG_MODULE_CACHE_PATH=${TESTFLIGHT_BUILD_MODULE_CACHE_DIRECTORY}"
    "SWIFT_MODULE_CACHE_PATH=${TESTFLIGHT_BUILD_MODULE_CACHE_DIRECTORY}"
    "DERIVED_FILE_DIR=${TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY}/DerivedFiles"
    "DERIVED_FILES_DIR=${TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY}/DerivedFiles"
    "DERIVED_SOURCES_DIR=${TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY}/DerivedSources"
    "PROJECT_DERIVED_DATA_DIR=${TESTFLIGHT_DERIVED_DATA_DIRECTORY}/ProjectDerivedData"
    "PROJECT_DERIVED_FILE_DIR=${TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY}/ProjectDerivedFiles"
    "TEMP_FILES_DIR=${TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY}/TempFiles"
    "INDEX_DATA_STORE_DIR=${TESTFLIGHT_DERIVED_DATA_DIRECTORY}/Index.noindex/DataStore"
    "LOCSYMROOT=${TESTFLIGHT_BUILD_PRODUCTS_DIRECTORY}/LocalizedSymbols"
  )
  TESTFLIGHT_XCODEBUILD_PINNED_ARGUMENTS_SHA256=$(xcodebuild_pinned_arguments_sha256)
  [[ "${#TESTFLIGHT_XCODEBUILD_PINNED_ARGUMENTS_SHA256}" == 64 ]] \
    || fail "could not pin the reviewed xcodebuild argument vector"
  TESTFLIGHT_XCODEBUILD_PINNED_ENVIRONMENT=(
    'LC_ALL=C'
    'PATH=/usr/bin:/bin:/usr/sbin:/sbin'
    "DEVELOPER_DIR=${EXPECTED_XCODE_REAL_DEVELOPER_PATH}"
    "TMPDIR=${TESTFLIGHT_BUILD_TMP_DIRECTORY}"
    "DERIVED_DATA_DIR=${TESTFLIGHT_DERIVED_DATA_DIRECTORY}"
    "SHARED_PRECOMPS_DIR=${TESTFLIGHT_BUILD_PRECOMPILED_DIRECTORY}"
    "CACHE_ROOT=${TESTFLIGHT_BUILD_CACHE_DIRECTORY}"
    "CCHROOT=${TESTFLIGHT_BUILD_CACHE_DIRECTORY}"
    "MODULE_CACHE_DIR=${TESTFLIGHT_BUILD_MODULE_CACHE_DIRECTORY}"
    "CLANG_MODULE_CACHE_PATH=${TESTFLIGHT_BUILD_MODULE_CACHE_DIRECTORY}"
    "SWIFT_MODULE_CACHE_PATH=${TESTFLIGHT_BUILD_MODULE_CACHE_DIRECTORY}"
    "SWIFTPM_MODULECACHE_OVERRIDE=${TESTFLIGHT_BUILD_MODULE_CACHE_DIRECTORY}"
    "XDG_CACHE_HOME=${TESTFLIGHT_BUILD_CACHE_DIRECTORY}"
    "SOURCE_PACKAGES_DIR_PATH=${TESTFLIGHT_BUILD_SOURCE_PACKAGES_DIRECTORY}"
    "DERIVED_FILE_DIR=${TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY}/DerivedFiles"
    "DERIVED_FILES_DIR=${TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY}/DerivedFiles"
    "DERIVED_SOURCES_DIR=${TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY}/DerivedSources"
    "PROJECT_DERIVED_DATA_DIR=${TESTFLIGHT_DERIVED_DATA_DIRECTORY}/ProjectDerivedData"
    "PROJECT_DERIVED_FILE_DIR=${TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY}/ProjectDerivedFiles"
    "TEMP_FILES_DIR=${TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY}/TempFiles"
    "INDEX_DATA_STORE_DIR=${TESTFLIGHT_DERIVED_DATA_DIRECTORY}/Index.noindex/DataStore"
    "LOCSYMROOT=${TESTFLIGHT_BUILD_PRODUCTS_DIRECTORY}/LocalizedSymbols"
    "DWARF_DSYM_FOLDER_PATH=${TESTFLIGHT_BUILD_PRODUCTS_DIRECTORY}"
    "OBJECT_FILE_DIR=${TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY}/Objects"
    "OBJECT_FILE_DIR_normal=${TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY}/Objects-normal"
    "SHARED_DERIVED_FILE_DIR=${TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY}/SharedDerivedSources"
    "REZ_COLLECTOR_DIR=${TESTFLIGHT_BUILD_INTERMEDIATES_DIRECTORY}/Rez"
  )
  TESTFLIGHT_XCODEBUILD_PINNED_ENVIRONMENT_SHA256=$(xcodebuild_pinned_environment_sha256)
  [[ "${#TESTFLIGHT_XCODEBUILD_PINNED_ENVIRONMENT_SHA256}" == 64 ]] \
    || fail "could not pin the scrubbed xcodebuild environment"
  verify_private_build_volume_identity \
    || fail "private ownership-enforcing build volume failed final initialization"
}

function verify_output_directory_identity() {
  [[ -n "${TESTFLIGHT_OUTPUT_DIRECTORY:-}" \
      && -n "${TESTFLIGHT_OUTPUT_DIRECTORY_IDENTITY:-}" \
      && "${TESTFLIGHT_OUTPUT_DIRECTORY}" \
        == "${PRIVATE_TEMPORARY_ROOT}"/opensteamer-testflight-output.* \
      && "${TESTFLIGHT_OUTPUT_DIRECTORY:A}" \
        == "${TESTFLIGHT_OUTPUT_DIRECTORY}" \
      && "$(stat_identity "${PRIVATE_TEMPORARY_ROOT}")" \
        == "${TESTFLIGHT_OUTPUT_PARENT_IDENTITY}" \
      && -d "${TESTFLIGHT_OUTPUT_DIRECTORY}" \
      && ! -L "${TESTFLIGHT_OUTPUT_DIRECTORY}" \
      && "$(stat_identity "${TESTFLIGHT_OUTPUT_DIRECTORY}")" \
        == "${TESTFLIGHT_OUTPUT_DIRECTORY_IDENTITY}" \
      && "$(/usr/bin/stat -f '%u:%Lp:%HT' \
        "${TESTFLIGHT_OUTPUT_DIRECTORY}" 2>/dev/null)" \
        == "${EUID}:700:Directory" \
      && ${TESTFLIGHT_OUTPUT_DIRECTORY_FD} -ge 0 \
      && -e "/dev/fd/${TESTFLIGHT_OUTPUT_DIRECTORY_FD}" \
      && "${TESTFLIGHT_OUTPUT_DIRECTORY}" \
        -ef "/dev/fd/${TESTFLIGHT_OUTPUT_DIRECTORY_FD}" ]]
}

function verify_verification_scratch_directory_identity() {
  verify_output_directory_identity || return 1
  [[ -n "${TESTFLIGHT_VERIFICATION_SCRATCH_DIRECTORY:-}" \
      && -n "${TESTFLIGHT_VERIFICATION_SCRATCH_DIRECTORY_IDENTITY:-}" \
      && "${TESTFLIGHT_VERIFICATION_SCRATCH_DIRECTORY:h}" \
        == "${TESTFLIGHT_OUTPUT_DIRECTORY}" \
      && "${TESTFLIGHT_VERIFICATION_SCRATCH_DIRECTORY}" \
        == "${TESTFLIGHT_OUTPUT_DIRECTORY}"/verification-scratch.* \
      && "${TESTFLIGHT_VERIFICATION_SCRATCH_DIRECTORY:A}" \
        == "${TESTFLIGHT_VERIFICATION_SCRATCH_DIRECTORY}" \
      && -d "${TESTFLIGHT_VERIFICATION_SCRATCH_DIRECTORY}" \
      && ! -L "${TESTFLIGHT_VERIFICATION_SCRATCH_DIRECTORY}" \
      && "$(stat_identity "${TESTFLIGHT_VERIFICATION_SCRATCH_DIRECTORY}")" \
        == "${TESTFLIGHT_VERIFICATION_SCRATCH_DIRECTORY_IDENTITY}" \
      && "$(/usr/bin/stat -f '%u:%Lp:%HT' \
        "${TESTFLIGHT_VERIFICATION_SCRATCH_DIRECTORY}" 2>/dev/null)" \
        == "${EUID}:700:Directory" \
      && ${TESTFLIGHT_VERIFICATION_SCRATCH_DIRECTORY_FD} -ge 0 \
      && -e "/dev/fd/${TESTFLIGHT_VERIFICATION_SCRATCH_DIRECTORY_FD}" \
      && "${TESTFLIGHT_VERIFICATION_SCRATCH_DIRECTORY}" \
        -ef "/dev/fd/${TESTFLIGHT_VERIFICATION_SCRATCH_DIRECTORY_FD}" ]]
}

function verify_pinned_log_destination() {
  local path=$1
  local identity=$2
  local descriptor=$3
  verify_output_directory_identity || return 1
  [[ -n "${path}" \
      && -n "${identity}" \
      && "${path:h}" == "${TESTFLIGHT_OUTPUT_DIRECTORY}" \
      && "${path:A}" == "${path}" \
      && -f "${path}" \
      && ! -L "${path}" \
      && "$(stat_identity "${path}")" == "${identity}" \
      && "$(/usr/bin/stat -f '%u:%Lp:%HT' "${path}" 2>/dev/null)" \
        == "${EUID}:600:Regular File" ]] || return 1
  if (( descriptor >= 0 )); then
    [[ -e "/dev/fd/${descriptor}" \
        && "${path}" -ef "/dev/fd/${descriptor}" ]] || return 1
  fi
}

function verify_archive_destination_identity() {
  verify_output_directory_identity || return 1
  [[ -n "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY:-}" \
      && -n "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY_IDENTITY:-}" \
      && "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY:h}" \
        == "${TESTFLIGHT_OUTPUT_DIRECTORY}" \
      && "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY}" \
        == "${TESTFLIGHT_OUTPUT_DIRECTORY}"/archive-destination.* \
      && "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY:A}" \
        == "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY}" \
      && -d "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY}" \
      && ! -L "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY}" \
      && "$(stat_identity "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY}")" \
        == "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY_IDENTITY}" \
      && "$(/usr/bin/stat -f '%u:%Lp:%HT' \
        "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY}" 2>/dev/null)" \
        == "${EUID}:700:Directory" \
      && ${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY_FD} -ge 0 \
      && -e "/dev/fd/${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY_FD}" \
      && "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY}" \
        -ef "/dev/fd/${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY_FD}" \
      && "${TESTFLIGHT_ARCHIVE_PATH}" \
        == "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY}/opensteamerTestFlight.xcarchive" ]] \
    || return 1
  verify_pinned_log_destination \
    "${TESTFLIGHT_ARCHIVE_LOG_PATH}" \
    "${TESTFLIGHT_ARCHIVE_LOG_IDENTITY}" \
    "${TESTFLIGHT_ARCHIVE_LOG_FD}"
}

function verify_archive_exec_destinations() {
  verify_archive_destination_identity || return 1
  [[ ! -e "${TESTFLIGHT_ARCHIVE_PATH}" \
      && ! -L "${TESTFLIGHT_ARCHIVE_PATH}" ]]
}

function reserve_archive_exec_destinations() {
  verify_output_directory_identity || return 1
  TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY=$(/usr/bin/mktemp -d \
    "${TESTFLIGHT_OUTPUT_DIRECTORY}/archive-destination.XXXXXX") || return 1
  sysopen -r -o nofollow -u TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY_FD \
    "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY}" || return 1
  TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY_IDENTITY=$(stat_identity \
    "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY}") || return 1
  TESTFLIGHT_ARCHIVE_PATH="${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY}/opensteamerTestFlight.xcarchive"

  TESTFLIGHT_ARCHIVE_LOG_PATH=$(/usr/bin/mktemp \
    "${TESTFLIGHT_OUTPUT_DIRECTORY}/archive-log.XXXXXX") || return 1
  sysopen -a -o nofollow -u TESTFLIGHT_ARCHIVE_LOG_FD \
    "${TESTFLIGHT_ARCHIVE_LOG_PATH}" || return 1
  TESTFLIGHT_ARCHIVE_LOG_IDENTITY=$(stat_identity \
    "${TESTFLIGHT_ARCHIVE_LOG_PATH}") || return 1
  verify_archive_exec_destinations
}

function verify_export_destination_identity() {
  verify_output_directory_identity || return 1
  [[ -n "${TESTFLIGHT_EXPORT_DIRECTORY:-}" \
      && -n "${TESTFLIGHT_EXPORT_DIRECTORY_IDENTITY:-}" \
      && "${TESTFLIGHT_EXPORT_DIRECTORY:h}" == "${TESTFLIGHT_OUTPUT_DIRECTORY}" \
      && "${TESTFLIGHT_EXPORT_DIRECTORY}" \
        == "${TESTFLIGHT_OUTPUT_DIRECTORY}"/export-destination.* \
      && "${TESTFLIGHT_EXPORT_DIRECTORY:A}" == "${TESTFLIGHT_EXPORT_DIRECTORY}" \
      && -d "${TESTFLIGHT_EXPORT_DIRECTORY}" \
      && ! -L "${TESTFLIGHT_EXPORT_DIRECTORY}" \
      && "$(stat_identity "${TESTFLIGHT_EXPORT_DIRECTORY}")" \
        == "${TESTFLIGHT_EXPORT_DIRECTORY_IDENTITY}" \
      && "$(/usr/bin/stat -f '%u:%Lp:%HT' \
        "${TESTFLIGHT_EXPORT_DIRECTORY}" 2>/dev/null)" \
        == "${EUID}:700:Directory" \
      && ${TESTFLIGHT_EXPORT_DIRECTORY_FD} -ge 0 \
      && -e "/dev/fd/${TESTFLIGHT_EXPORT_DIRECTORY_FD}" \
      && "${TESTFLIGHT_EXPORT_DIRECTORY}" \
        -ef "/dev/fd/${TESTFLIGHT_EXPORT_DIRECTORY_FD}" ]] || return 1
  verify_pinned_log_destination \
    "${TESTFLIGHT_UPLOAD_LOG_PATH}" \
    "${TESTFLIGHT_UPLOAD_LOG_IDENTITY}" \
    "${TESTFLIGHT_UPLOAD_LOG_FD}"
}

function verify_export_exec_destinations() {
  verify_export_destination_identity || return 1
  local first_entry
  first_entry=$(/usr/bin/find "${TESTFLIGHT_EXPORT_DIRECTORY}" \
    -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) || return 2
  [[ -z "${first_entry}" ]]
}

function reserve_export_exec_destinations() {
  verify_output_directory_identity || return 1
  TESTFLIGHT_EXPORT_DIRECTORY=$(/usr/bin/mktemp -d \
    "${TESTFLIGHT_OUTPUT_DIRECTORY}/export-destination.XXXXXX") || return 1
  sysopen -r -o nofollow -u TESTFLIGHT_EXPORT_DIRECTORY_FD \
    "${TESTFLIGHT_EXPORT_DIRECTORY}" || return 1
  TESTFLIGHT_EXPORT_DIRECTORY_IDENTITY=$(stat_identity \
    "${TESTFLIGHT_EXPORT_DIRECTORY}") || return 1

  TESTFLIGHT_UPLOAD_LOG_PATH=$(/usr/bin/mktemp \
    "${TESTFLIGHT_OUTPUT_DIRECTORY}/upload-log.XXXXXX") || return 1
  sysopen -a -o nofollow -u TESTFLIGHT_UPLOAD_LOG_FD \
    "${TESTFLIGHT_UPLOAD_LOG_PATH}" || return 1
  TESTFLIGHT_UPLOAD_LOG_IDENTITY=$(stat_identity \
    "${TESTFLIGHT_UPLOAD_LOG_PATH}") || return 1
  verify_export_exec_destinations
}

function verify_archive_filesystem_identity() {
  verify_output_directory_identity || return 1
  [[ -n "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY_IDENTITY:-}" \
      && -d "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY}" \
      && ! -L "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY}" \
      && "$(stat_identity "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY}")" \
        == "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY_IDENTITY}" ]] || return 1
  local archive_path="${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY}/opensteamerTestFlight.xcarchive"
  local products_path="${archive_path}/Products"
  local applications_path="${products_path}/Applications"
  local archive_info="${archive_path}/Info.plist"
  local app_path="${applications_path}/opensteamer.app"
  local app_info="${app_path}/Info.plist"
  local app_profile="${app_path}/embedded.mobileprovision"
  local -a application_products=("${applications_path}"/*(ND))
  (( ${#application_products[@]} == 1 )) \
    && [[ "${application_products[1]}" == "${app_path}" ]] || return 1
  [[ "${TESTFLIGHT_ARCHIVE_PATH}" == "${archive_path}" \
      && "${archive_path:A}" == "${archive_path}" \
      && -d "${archive_path}" && ! -L "${archive_path}" \
      && -d "${products_path}" && ! -L "${products_path}" \
      && -d "${applications_path}" && ! -L "${applications_path}" \
      && -d "${app_path}" && ! -L "${app_path}" \
      && -f "${archive_info}" && ! -L "${archive_info}" \
      && -f "${app_info}" && ! -L "${app_info}" \
      && -f "${app_profile}" && ! -L "${app_profile}" \
      && -n "${TESTFLIGHT_ARCHIVE_IDENTITY:-}" \
      && "$(stat_identity "${archive_path}")" \
        == "${TESTFLIGHT_ARCHIVE_IDENTITY}" \
      && "$(stat_identity "${app_path}")" \
        == "${TESTFLIGHT_ARCHIVE_APP_IDENTITY}" \
      && "$(stat_identity "${archive_info}")" \
        == "${TESTFLIGHT_ARCHIVE_INFO_IDENTITY}" \
      && "$(sha256_file "${archive_info}")" \
        == "${TESTFLIGHT_ARCHIVE_INFO_SHA256}" \
      && "$(stat_identity "${app_info}")" \
        == "${TESTFLIGHT_ARCHIVE_APP_INFO_IDENTITY}" \
      && "$(stat_identity "${app_profile}")" \
        == "${TESTFLIGHT_ARCHIVE_PROFILE_IDENTITY}" \
      && "$(sha256_file "${app_profile}")" \
        == "${TESTFLIGHT_ARCHIVE_PROFILE_SHA256}" \
      && "${#TESTFLIGHT_ARCHIVE_TREE_SHA256}" == 64 \
      && "$(filesystem_tree_sha256 "${archive_path}")" \
        == "${TESTFLIGHT_ARCHIVE_TREE_SHA256}" ]]
}

function pin_archive_filesystem_identity() {
  verify_output_directory_identity || return 1
  [[ -n "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY_IDENTITY:-}" \
      && -d "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY}" \
      && ! -L "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY}" \
      && "$(stat_identity "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY}")" \
        == "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY_IDENTITY}" ]] || return 1
  local archive_path="${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY}/opensteamerTestFlight.xcarchive"
  local products_path="${archive_path}/Products"
  local applications_path="${products_path}/Applications"
  local archive_info="${archive_path}/Info.plist"
  local app_path="${applications_path}/opensteamer.app"
  local app_info="${app_path}/Info.plist"
  local app_profile="${app_path}/embedded.mobileprovision"
  local -a application_products=("${applications_path}"/*(ND))
  (( ${#application_products[@]} == 1 )) \
    && [[ "${application_products[1]}" == "${app_path}" ]] || return 1
  [[ "${archive_path:A}" == "${archive_path}" \
      && -d "${archive_path}" && ! -L "${archive_path}" \
      && -d "${products_path}" && ! -L "${products_path}" \
      && -d "${applications_path}" && ! -L "${applications_path}" \
      && -d "${app_path}" && ! -L "${app_path}" \
      && -f "${archive_info}" && ! -L "${archive_info}" \
      && -f "${app_info}" && ! -L "${app_info}" \
      && -f "${app_profile}" && ! -L "${app_profile}" ]] || return 1
  TESTFLIGHT_ARCHIVE_PATH=${archive_path}
  TESTFLIGHT_ARCHIVE_IDENTITY=$(stat_identity "${archive_path}")
  TESTFLIGHT_ARCHIVE_APP_IDENTITY=$(stat_identity "${app_path}")
  TESTFLIGHT_ARCHIVE_INFO_IDENTITY=$(stat_identity "${archive_info}")
  TESTFLIGHT_ARCHIVE_INFO_SHA256=$(sha256_file "${archive_info}")
  if /usr/bin/plutil -extract Distributions raw -o - "${archive_info}" \
      >/dev/null 2>&1; then
    return 1
  fi
  TESTFLIGHT_ARCHIVE_INFO_WITHOUT_DISTRIBUTIONS_SHA256=\
$(archive_info_without_distributions_sha256 "${archive_info}")
  TESTFLIGHT_ARCHIVE_APP_INFO_IDENTITY=$(stat_identity "${app_info}")
  TESTFLIGHT_ARCHIVE_PROFILE_IDENTITY=$(stat_identity "${app_profile}")
  TESTFLIGHT_ARCHIVE_PROFILE_SHA256=$(sha256_file "${app_profile}")
  TESTFLIGHT_ARCHIVE_TREE_SHA256=$(filesystem_tree_sha256 "${archive_path}")
  TESTFLIGHT_ARCHIVE_TREE_WITHOUT_ROOT_INFO_SHA256=$(filesystem_tree_sha256 \
    "${archive_path}" './Info.plist')
  [[ "${#TESTFLIGHT_ARCHIVE_INFO_SHA256}" == 64 \
      && "${#TESTFLIGHT_ARCHIVE_INFO_WITHOUT_DISTRIBUTIONS_SHA256}" == 64 \
      && "${#TESTFLIGHT_ARCHIVE_PROFILE_SHA256}" == 64 \
      && "${#TESTFLIGHT_ARCHIVE_TREE_SHA256}" == 64 \
      && "${#TESTFLIGHT_ARCHIVE_TREE_WITHOUT_ROOT_INFO_SHA256}" == 64 ]] \
    || return 1
  verify_archive_filesystem_identity
}

function plist_document_raw_value() {
  local document=$1
  local key_path=$2
  print -rn -- "${document}" \
    | /usr/bin/plutil -extract "${key_path}" raw -o - - 2>/dev/null
}

function plist_document_array_count() {
  local document=$1
  local key_path=$2
  local count
  count=$(print -rn -- "${document}" \
    | /usr/bin/plutil -extract "${key_path}" raw -expect array \
      -o - - 2>/dev/null) || return 1
  [[ "${count}" == <-> ]] || return 1
  print -r -- "${count}"
}

function codesign_metadata_value() {
  local metadata=$1
  local key=$2
  local value
  value=$(print -r -- "${metadata}" \
    | /usr/bin/awk -F= -v expected="${key}" '$1 == expected { print $2 }')
  [[ -n "${value}" && "${value}" != *$'\n'* ]] || return 1
  print -r -- "${value}"
}

function profile_certificate_sha256() {
  local profile=$1
  local certificate_index=$2
  local encoded_certificate
  encoded_certificate=$(plist_document_raw_value \
    "${profile}" "DeveloperCertificates.${certificate_index}") || return 1
  [[ -n "${encoded_certificate}" ]] || return 1
  print -rn -- "${encoded_certificate}" \
    | /usr/bin/base64 -D 2>/dev/null \
    | /usr/bin/shasum -a 256 2>/dev/null \
    | /usr/bin/awk 'NR == 1 && NF == 2 { print $1 }'
}

function app_leaf_signing_certificate_sha256() {
  local app_path=$1
  verify_verification_scratch_directory_identity || return 1
  local extraction_directory
  extraction_directory=$(/usr/bin/mktemp -d \
    "${TESTFLIGHT_VERIFICATION_SCRATCH_DIRECTORY}/certificates.XXXXXX") \
    || return 1
  local extraction_identity
  extraction_identity=$(stat_identity "${extraction_directory}") || return 1
  local -i extraction_fd=-1
  sysopen -r -o nofollow -u extraction_fd "${extraction_directory}" \
    || return 1
  [[ "${extraction_directory:A}" == "${extraction_directory}" \
      && "${extraction_directory:h}" \
        == "${TESTFLIGHT_VERIFICATION_SCRATCH_DIRECTORY}" \
      && -d "${extraction_directory}" \
      && ! -L "${extraction_directory}" \
      && "$(stat_identity "${extraction_directory}")" \
        == "${extraction_identity}" \
      && "${extraction_directory}" -ef "/dev/fd/${extraction_fd}" ]] \
    || return 1
  (
    cd "${extraction_directory}" || exit 1
    [[ "." -ef "/dev/fd/${extraction_fd}" ]] || exit 1
    /usr/bin/codesign -d --extract-certificates=certificate \
      "${app_path}" >/dev/null 2>&1
  ) || return 1
  verify_verification_scratch_directory_identity || return 1
  [[ -d "${extraction_directory}" \
      && ! -L "${extraction_directory}" \
      && "$(stat_identity "${extraction_directory}")" \
        == "${extraction_identity}" \
      && "${extraction_directory}" -ef "/dev/fd/${extraction_fd}" ]] \
    || return 1
  local certificate_path
  local certificate_count=0
  while IFS= read -r -d '' certificate_path; do
    [[ "${certificate_path:h}" == '.' \
        && "${certificate_path:t}" == certificate<-> ]] || return 1
    (( certificate_count += 1 ))
  done < <(
    cd "${extraction_directory}" || exit 1
    [[ "." -ef "/dev/fd/${extraction_fd}" ]] || exit 1
    /usr/bin/find . -mindepth 1 -maxdepth 1 -type f ! -type l -print0
  )
  (( certificate_count > 0 )) || return 1
  (
    cd "${extraction_directory}" || exit 1
    [[ "." -ef "/dev/fd/${extraction_fd}" ]] || exit 1
    [[ -f ./certificate0 && ! -L ./certificate0 ]] || exit 1
    sha256_file ./certificate0
  )
}

function verify_main_signed_entitlements() {
  local app_path=$1
  local entitlements
  entitlements=$(/usr/bin/codesign -d --entitlements :- "${app_path}" 2>/dev/null) \
    || return 1
  print -rn -- "${entitlements}" | /usr/bin/plutil -lint - >/dev/null 2>&1 \
    || return 1
  [[ "${entitlements}" != *"${PROTECTED_BUNDLE_IDENTIFIER}"* \
      && "$(plist_document_raw_value \
        "${entitlements}" application-identifier)" \
        == "${EXPECTED_APPLICATION_IDENTIFIER}" \
      && "$(plist_document_raw_value \
        "${entitlements}" 'com\.apple\.developer\.team-identifier')" \
        == "${EXPECTED_TEAM_ID}" \
      && "$(plist_document_raw_value "${entitlements}" get-task-allow)" \
        == 'true' ]]
}

function verify_embedded_provisioning_profile() {
  local app_path=$1
  local profile_path="${app_path}/embedded.mobileprovision"
  local -a profile_paths=()
  local discovered_profile
  while IFS= read -r -d '' discovered_profile; do
    profile_paths+=("${discovered_profile}")
  done < <(/usr/bin/find "${app_path}" \
    -name embedded.mobileprovision -print0)
  (( ${#profile_paths[@]} == 1 )) \
    && [[ "${profile_paths[1]}" == "${profile_path}" ]] || return 1
  [[ -f "${profile_path}" && ! -L "${profile_path}" ]] || return 1
  local profile
  profile=$(/usr/bin/security cms -D -i "${profile_path}" 2>/dev/null) \
    || return 1
  print -rn -- "${profile}" | /usr/bin/plutil -lint - >/dev/null 2>&1 \
    || return 1
  [[ "${profile}" != *"${PROTECTED_BUNDLE_IDENTIFIER}"* ]] || return 1

  local prefix_count
  local team_count
  local keychain_group_count
  local certificate_count
  prefix_count=$(plist_document_array_count \
    "${profile}" ApplicationIdentifierPrefix) || return 1
  team_count=$(plist_document_array_count "${profile}" TeamIdentifier) || return 1
  keychain_group_count=$(plist_document_array_count \
    "${profile}" Entitlements.keychain-access-groups) || return 1
  certificate_count=$(plist_document_array_count \
    "${profile}" DeveloperCertificates) || return 1
  (( prefix_count == 1 \
      && team_count == 1 \
      && keychain_group_count == 2 \
      && certificate_count > 0 )) || return 1
  [[ "$(plist_document_raw_value "${profile}" ApplicationIdentifierPrefix.0)" \
        == "${EXPECTED_TEAM_ID}" \
      && "$(plist_document_raw_value "${profile}" TeamIdentifier.0)" \
        == "${EXPECTED_TEAM_ID}" \
      && "$(plist_document_raw_value \
        "${profile}" Entitlements.application-identifier)" \
        == "${EXPECTED_TEAM_ID}.*" \
      && "$(plist_document_raw_value \
        "${profile}" 'Entitlements.com\.apple\.developer\.team-identifier')" \
        == "${EXPECTED_TEAM_ID}" \
      && "$(plist_document_raw_value \
        "${profile}" Entitlements.get-task-allow)" == 'true' \
      && "$(plist_document_raw_value \
        "${profile}" Entitlements.keychain-access-groups.0)" \
        == "${EXPECTED_TEAM_ID}.*" \
      && "$(plist_document_raw_value \
        "${profile}" Entitlements.keychain-access-groups.1)" \
        == 'com.apple.token' ]] || return 1

  local leaf_certificate_sha256
  leaf_certificate_sha256=$(app_leaf_signing_certificate_sha256 "${app_path}") \
    || return 1
  [[ "${#leaf_certificate_sha256}" == 64 ]] || return 1
  local certificate_index
  local profile_certificate_hash
  local matching_certificate_count=0
  for (( certificate_index = 0; certificate_index < certificate_count; certificate_index += 1 )); do
    profile_certificate_hash=$(profile_certificate_sha256 \
      "${profile}" "${certificate_index}") || return 1
    [[ "${#profile_certificate_hash}" == 64 ]] || return 1
    [[ "${profile_certificate_hash}" != "${leaf_certificate_sha256}" ]] \
      || (( matching_certificate_count += 1 ))
  done
  (( matching_certificate_count == 1 )) || return 1

  local creation_date
  local expiration_date
  local creation_epoch
  local expiration_epoch
  local current_epoch
  creation_date=$(plist_document_raw_value "${profile}" CreationDate) || return 1
  expiration_date=$(plist_document_raw_value "${profile}" ExpirationDate) || return 1
  creation_epoch=$(TZ=UTC /bin/date -j -f '%Y-%m-%dT%H:%M:%SZ' \
    "${creation_date}" '+%s' 2>/dev/null) || return 1
  expiration_epoch=$(TZ=UTC /bin/date -j -f '%Y-%m-%dT%H:%M:%SZ' \
    "${expiration_date}" '+%s' 2>/dev/null) || return 1
  current_epoch=$(/bin/date '+%s') || return 1
  (( creation_epoch <= current_epoch && current_epoch < expiration_epoch ))
}

function file_is_mach_o() {
  local file=$1
  [[ -f "${file}" && ! -L "${file}" ]] || return 2
  local magic
  magic=$(LC_ALL=C /usr/bin/od -An -N4 -tx1 "${file}" 2>/dev/null \
    | LC_ALL=C /usr/bin/tr -d '[:space:]') || return 2
  case "${magic:l}" in
    feedface|cefaedfe|feedfacf|cffaedfe|cafebabe|bebafeca|cafebabf|bfbafeca)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

function verify_reviewed_archive_product_manifest() {
  local archive_path=$1
  local products_path="${archive_path}/Products"
  local applications_path="${products_path}/Applications"
  local app_path="${applications_path}/opensteamer.app"
  local main_executable="${app_path}/opensteamer"
  local expected_framework="${app_path}/Frameworks/LiveKitWebRTC.framework"
  local framework_executable="${expected_framework}/LiveKitWebRTC"
  local app_info="${app_path}/Info.plist"
  local framework_info="${expected_framework}/Info.plist"
  [[ -d "${products_path}" \
      && ! -L "${products_path}" \
      && -d "${applications_path}" \
      && ! -L "${applications_path}" \
      && -d "${app_path}" \
      && ! -L "${app_path}" \
      && -f "${main_executable}" \
      && ! -L "${main_executable}" \
      && -d "${expected_framework}" \
      && ! -L "${expected_framework}" \
      && -f "${framework_executable}" \
      && ! -L "${framework_executable}" \
      && -f "${app_info}" \
      && ! -L "${app_info}" \
      && -f "${framework_info}" \
      && ! -L "${framework_info}" \
      && "$(plist_raw_value "${app_info}" CFBundleIdentifier)" \
        == "${EXPECTED_BUNDLE_IDENTIFIER}" \
      && "$(plist_raw_value "${app_info}" CFBundleExecutable)" \
        == 'opensteamer' \
      && "$(plist_raw_value "${framework_info}" CFBundleIdentifier)" \
        == 'io.livekit.LiveKitWebRTC' \
      && "$(plist_raw_value "${framework_info}" CFBundleExecutable)" \
        == 'LiveKitWebRTC' ]] || return 1

  # Scan the complete executable Products payload. Archive metadata and dSYM Mach-O debug symbols
  # live outside Products and are not executable payload; no unreviewed code may appear here.
  local -a all_nodes=("${products_path}"/**/*(ND))
  local -a code_container_paths=()
  local -a info_plist_paths=()
  local -a mach_o_paths=()
  local node
  local mach_o_status
  for node in "${all_nodes[@]}"; do
    [[ ! -L "${node}" ]] || return 1
    case "${node:t}" in
      (*.app|*.appex|*.framework|*.xpc|*.bundle|*.dylib)
        code_container_paths+=("${node}")
        ;;
    esac
    [[ "${node:t}" != 'Info.plist' ]] || info_plist_paths+=("${node}")
    if [[ -f "${node}" ]]; then
      if file_is_mach_o "${node}"; then
        mach_o_paths+=("${node}")
      else
        mach_o_status=$?
        (( mach_o_status == 1 )) || return 2
      fi
    fi
  done

  (( ${#code_container_paths[@]} == 2 \
      && ${code_container_paths[(Ie)${app_path}]} > 0 \
      && ${code_container_paths[(Ie)${expected_framework}]} > 0 \
      && ${#info_plist_paths[@]} == 2 \
      && ${info_plist_paths[(Ie)${app_info}]} > 0 \
      && ${info_plist_paths[(Ie)${framework_info}]} > 0 \
      && ${#mach_o_paths[@]} == 2 \
      && ${mach_o_paths[(Ie)${main_executable}]} > 0 \
      && ${mach_o_paths[(Ie)${framework_executable}]} > 0 )) || return 1
}

function verify_reviewed_nested_code() {
  local archive_path=$1
  verify_reviewed_archive_product_manifest "${archive_path}" || return $?
  local app_path="${archive_path}/Products/Applications/opensteamer.app"
  local expected_framework="${app_path}/Frameworks/LiveKitWebRTC.framework"
  local framework_executable="${expected_framework}/LiveKitWebRTC"

  /usr/bin/codesign --verify --strict --verbose=4 "${expected_framework}" \
    >/dev/null 2>&1 || return 1
  /usr/bin/codesign --verify --strict --verbose=4 "${framework_executable}" \
    >/dev/null 2>&1 || return 1

  local signed_path
  local metadata
  local identifier
  local team_identifier
  local entitlements
  for signed_path in "${expected_framework}" "${framework_executable}"; do
    metadata=$(/usr/bin/codesign -dv --verbose=4 "${signed_path}" 2>&1) \
      || return 1
    identifier=$(codesign_metadata_value "${metadata}" Identifier) || return 1
    team_identifier=$(codesign_metadata_value "${metadata}" TeamIdentifier) \
      || return 1
    ! identifier_is_protected "${identifier}" \
      && [[ "${identifier}" == 'io.livekit.LiveKitWebRTC' \
        && "${team_identifier}" == "${EXPECTED_TEAM_ID}" ]] || return 1
    entitlements=$(/usr/bin/codesign -d --entitlements :- \
      "${signed_path}" 2>/dev/null) || return 1
    [[ -z "${entitlements}" ]] || return 1
  done
}

function verify_archive_contents_at_path() {
  local archive_path=$1
  local archive_info="${archive_path}/Info.plist"
  local app_info="${archive_path}/Products/Applications/opensteamer.app/Info.plist"
  local app_path="${app_info:h}"

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

  /usr/bin/codesign --verify --deep --strict --verbose=4 "${app_path}" \
    >/dev/null 2>&1 || fail "archived app signature integrity verification failed"
  verify_main_signed_entitlements "${app_path}" \
    || fail "archived app signed entitlements are not the reviewed side-by-side identity"
  verify_embedded_provisioning_profile "${app_path}" \
    || fail "archived app provisioning profile is not the reviewed team envelope"
  verify_reviewed_nested_code "${archive_path}" \
    || fail "archived app nested signed-code identity set is not reviewed"

  local signed_identifier
  local signature_metadata
  signature_metadata=$(/usr/bin/codesign -dv --verbose=4 "${app_path}" 2>&1) \
    || fail "could not inspect archived app signature"
  signed_identifier=$(codesign_metadata_value \
    "${signature_metadata}" Identifier) \
    || fail "archived signature identifier is missing or ambiguous"
  ! identifier_is_protected "${signed_identifier}" \
    || fail "archived signature addresses the protected app identity"
  [[ "${signed_identifier}" == "${EXPECTED_BUNDLE_IDENTIFIER}" ]] \
    || fail "archived signature identifier is ${signed_identifier}"
  local signed_team_id
  signed_team_id=$(codesign_metadata_value \
    "${signature_metadata}" TeamIdentifier) \
    || fail "archived signature team is missing or ambiguous"
  [[ "${signed_team_id}" == "${EXPECTED_TEAM_ID}" ]] \
    || fail "archived signature team is ${signed_team_id}"
  local cd_hash
  cd_hash=$(codesign_metadata_value "${signature_metadata}" CDHash) \
    || fail "archived signature CDHash is missing or ambiguous"
  cd_hash=${cd_hash:l}
  [[ "${#cd_hash}" == 40 || "${#cd_hash}" == 64 ]] \
    || fail "archived signature CDHash is missing or malformed"
  if [[ -z "${TESTFLIGHT_ARCHIVE_CD_HASH:-}" ]]; then
    TESTFLIGHT_ARCHIVE_CD_HASH=${cd_hash}
  else
    [[ "${cd_hash}" == "${TESTFLIGHT_ARCHIVE_CD_HASH}" ]] \
      || fail "archived app CDHash changed after initial verification"
  fi
}

function verify_archive() {
  verify_archive_filesystem_identity \
    || fail "archive path or pinned filesystem identity changed"
  verify_archive_contents_at_path "${TESTFLIGHT_ARCHIVE_PATH}"
}

function verify_successful_upload_distribution_record() {
  local archive_info=$1
  [[ -f "${archive_info}" && ! -L "${archive_info}" ]] || return 1
  local distribution_count
  distribution_count=$(plist_array_count "${archive_info}" Distributions) \
    || return 1
  (( distribution_count == 1 )) || return 1
  [[ "$(plist_raw_value "${archive_info}" Distributions.0.adamId)" \
        == "${EXPECTED_ASC_APPLE_ID}" \
      && "$(plist_raw_value "${archive_info}" Distributions.0.destination)" \
        == 'upload' \
      && "$(plist_raw_value "${archive_info}" Distributions.0.task)" \
        == 'distribute' \
      && "$(plist_raw_value "${archive_info}" Distributions.0.teamID)" \
        == "${EXPECTED_TEAM_ID}" \
      && "$(plist_raw_value "${archive_info}" Distributions.0.uploadDestination)" \
        == 'App Store' \
      && "$(plist_raw_value "${archive_info}" Distributions.0.uploadedBuildNumber)" \
        == "${EXPECTED_BUILD_NUMBER}" \
      && "$(plist_raw_value "${archive_info}" Distributions.0.preparationEvent.state)" \
        == 'success' \
      && "$(plist_raw_value "${archive_info}" Distributions.0.uploadEvent.state)" \
        == 'success' ]] || return 1
  local certificate_sha1
  certificate_sha1=$(plist_raw_value \
    "${archive_info}" Distributions.0.certificateSHA1) || return 1
  certificate_sha1=${certificate_sha1:u}
  [[ "${#certificate_sha1}" == 40 \
      && "${certificate_sha1}" != *[^0-9A-F]* \
      && "${certificate_sha1}" \
        == "${EXPECTED_DISTRIBUTION_CERTIFICATE_SHA1}" ]] || return 1
  local preparation_error_count
  local upload_error_count
  preparation_error_count=$(plist_array_count \
    "${archive_info}" Distributions.0.preparationEvent.errors) || return 1
  upload_error_count=$(plist_array_count \
    "${archive_info}" Distributions.0.uploadEvent.errors) || return 1
  (( preparation_error_count == 0 && upload_error_count == 0 ))
}

function verify_archive_payload_after_upload() {
  # Xcode records distribution results by replacing the archive-root Info.plist
  # after a successful upload.  Exclude only that file from the pre-upload tree
  # digest, then validate its exact app/team/build success record separately.
  verify_output_directory_identity || return 1
  [[ -n "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY_IDENTITY:-}" \
      && -d "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY}" \
      && ! -L "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY}" \
      && "$(stat_identity "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY}")" \
        == "${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY_IDENTITY}" ]] || return 1
  local archive_path="${TESTFLIGHT_ARCHIVE_DESTINATION_DIRECTORY}/opensteamerTestFlight.xcarchive"
  local products_path="${archive_path}/Products"
  local applications_path="${products_path}/Applications"
  local archive_info="${archive_path}/Info.plist"
  local app_path="${applications_path}/opensteamer.app"
  local app_info="${app_path}/Info.plist"
  local app_profile="${app_path}/embedded.mobileprovision"
  local -a application_products=("${applications_path}"/*(ND))
  (( ${#application_products[@]} == 1 )) \
    && [[ "${application_products[1]}" == "${app_path}" ]] || return 1
  [[ "${TESTFLIGHT_ARCHIVE_PATH}" == "${archive_path}" \
      && "${archive_path:A}" == "${archive_path}" \
      && -d "${archive_path}" && ! -L "${archive_path}" \
      && "$(stat_identity "${archive_path}")" \
        == "${TESTFLIGHT_ARCHIVE_IDENTITY}" \
      && -d "${products_path}" && ! -L "${products_path}" \
      && -d "${applications_path}" && ! -L "${applications_path}" \
      && -d "${app_path}" && ! -L "${app_path}" \
      && "$(stat_identity "${app_path}")" \
        == "${TESTFLIGHT_ARCHIVE_APP_IDENTITY}" \
      && -f "${archive_info}" && ! -L "${archive_info}" \
      && -f "${app_info}" && ! -L "${app_info}" \
      && "$(stat_identity "${app_info}")" \
        == "${TESTFLIGHT_ARCHIVE_APP_INFO_IDENTITY}" \
      && -f "${app_profile}" && ! -L "${app_profile}" \
      && "$(stat_identity "${app_profile}")" \
        == "${TESTFLIGHT_ARCHIVE_PROFILE_IDENTITY}" \
      && "$(sha256_file "${app_profile}")" \
        == "${TESTFLIGHT_ARCHIVE_PROFILE_SHA256}" \
      && "${#TESTFLIGHT_ARCHIVE_TREE_WITHOUT_ROOT_INFO_SHA256}" == 64 \
      && "$(filesystem_tree_sha256 "${archive_path}" './Info.plist')" \
        == "${TESTFLIGHT_ARCHIVE_TREE_WITHOUT_ROOT_INFO_SHA256}" \
      && "${#TESTFLIGHT_ARCHIVE_INFO_WITHOUT_DISTRIBUTIONS_SHA256}" == 64 \
      && "$(archive_info_without_distributions_sha256 "${archive_info}")" \
        == "${TESTFLIGHT_ARCHIVE_INFO_WITHOUT_DISTRIBUTIONS_SHA256}" ]] \
    || return 1
  verify_successful_upload_distribution_record "${archive_info}"
}

function create_safe_output_directory() {
  TESTFLIGHT_OUTPUT_PARENT_IDENTITY=$(stat_identity "${PRIVATE_TEMPORARY_ROOT}")
  [[ -n "${TESTFLIGHT_OUTPUT_PARENT_IDENTITY}" ]] || return 1
  TESTFLIGHT_OUTPUT_DIRECTORY=$(/usr/bin/mktemp -d \
    "${PRIVATE_TEMPORARY_ROOT}/opensteamer-testflight-output.XXXXXX") \
    || return 1
  sysopen -r -o nofollow -u TESTFLIGHT_OUTPUT_DIRECTORY_FD \
    "${TESTFLIGHT_OUTPUT_DIRECTORY}" || return 1
  TESTFLIGHT_OUTPUT_DIRECTORY_IDENTITY=$(stat_identity \
    "${TESTFLIGHT_OUTPUT_DIRECTORY}")
  verify_output_directory_identity || return 1
  TESTFLIGHT_VERIFICATION_SCRATCH_DIRECTORY=$(/usr/bin/mktemp -d \
    "${TESTFLIGHT_OUTPUT_DIRECTORY}/verification-scratch.XXXXXX") \
    || return 1
  sysopen -r -o nofollow -u TESTFLIGHT_VERIFICATION_SCRATCH_DIRECTORY_FD \
    "${TESTFLIGHT_VERIFICATION_SCRATCH_DIRECTORY}" || return 1
  TESTFLIGHT_VERIFICATION_SCRATCH_DIRECTORY_IDENTITY=$(stat_identity \
    "${TESTFLIGHT_VERIFICATION_SCRATCH_DIRECTORY}") || return 1
  verify_verification_scratch_directory_identity
}

function archive_side_by_side_app() {
  local output_directory=$1
  verify_output_directory_identity \
    || fail "private TestFlight output directory changed before archive"
  [[ "${output_directory}" == "${TESTFLIGHT_OUTPUT_DIRECTORY}" ]] \
    || fail "archive destination parent is not the pinned private output directory"
  reserve_archive_exec_destinations \
    || fail "could not atomically reserve archive and log destinations"
  initialize_private_testflight_build_volume
  resolve_pinned_package_dependencies \
    || fail "could not resolve the pinned package graph into the encrypted cache"
  local effective_roots_status=0
  verify_effective_archive_build_roots || effective_roots_status=$?
  if (( effective_roots_status == 2 )); then
    fail "could not obtain effective archive build settings"
  elif (( effective_roots_status != 0 )); then
    fail "effective archive build/cache roots escaped the encrypted build volume"
  fi
  verify_archive_exec_destinations \
    || fail "reserved archive or log destination changed immediately before archive"
  verify_pinned_xcodebuild_filesystem_contract \
    || fail "private build filesystem contract changed immediately before archive"
  local archive_status=0
  run_pinned_xcodebuild archive archive \
    "${TESTFLIGHT_XCODEBUILD_PINNED_ARGUMENTS[@]}" \
    -archivePath "${TESTFLIGHT_ARCHIVE_PATH}" \
    -allowProvisioningUpdates \
    "${TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS[@]}" \
    2>&1 | /usr/bin/tee "/dev/fd/${TESTFLIGHT_ARCHIVE_LOG_FD}" \
    || archive_status=$?
  verify_xcodebuild_authentication_contract \
    || fail "release authentication identity changed during archive"
  (( archive_status == 0 )) || return ${archive_status}
  verify_archive_destination_identity \
    || fail "archive or pinned log destination changed during archive"
  exec {TESTFLIGHT_ARCHIVE_LOG_FD}>&-
  TESTFLIGHT_ARCHIVE_LOG_FD=-1
  verify_pinned_log_destination \
    "${TESTFLIGHT_ARCHIVE_LOG_PATH}" \
    "${TESTFLIGHT_ARCHIVE_LOG_IDENTITY}" -1 \
    || fail "archive log path changed after descriptor close"
  verify_output_directory_identity \
    || fail "private TestFlight output directory changed during archive"
  verify_private_build_volume_identity \
    || fail "private build volume changed during archive"
  pin_archive_filesystem_identity \
    || fail "could not pin the completed archive filesystem identity"
  verify_archive
}

function run_archive_only() {
  create_safe_output_directory \
    || fail "could not create a private TestFlight output directory"
  local output_directory=${TESTFLIGHT_OUTPUT_DIRECTORY}
  archive_side_by_side_app "${output_directory}"
  cleanup_private_build_volume_signal_masked \
    || fail "could not clean the exact private build volume"
  verify_archive
  print -- "side-by-side TestFlight archive verified: ${TESTFLIGHT_ARCHIVE_PATH}"
}

function run_authorized_upload() {
  verify_xcodebuild_authentication_contract \
    || fail "release authentication contract is invalid before archive"
  create_safe_output_directory \
    || fail "could not create a private TestFlight output directory"
  local output_directory=${TESTFLIGHT_OUTPUT_DIRECTORY}
  archive_side_by_side_app "${output_directory}"
  reserve_export_exec_destinations \
    || fail "could not atomically reserve export and upload-log destinations"
  # No App Store Connect operation occurs before the completed archive passes verify_archive.
  verify_output_directory_identity \
    || fail "private TestFlight output directory changed before upload"
  verify_export_options_identity \
    || fail "export options changed after reviewed configuration validation"
  verify_archive
  verify_xcodebuild_authentication_contract \
    || fail "release authentication identity changed before upload"
  verify_export_exec_destinations \
    || fail "reserved export or upload-log destination changed immediately before upload"
  verify_pinned_xcodebuild_filesystem_contract \
    || fail "private build filesystem contract changed immediately before upload"
  local upload_status=0
  run_pinned_xcodebuild export -exportArchive \
    -archivePath "${TESTFLIGHT_ARCHIVE_PATH}" \
    -exportOptionsPlist "${EXPORT_OPTIONS_PATH}" \
    -exportPath "${TESTFLIGHT_EXPORT_DIRECTORY}" \
    -allowProvisioningUpdates \
    "${TESTFLIGHT_XCODEBUILD_AUTHENTICATION_ARGUMENTS[@]}" \
    2>&1 | /usr/bin/tee "/dev/fd/${TESTFLIGHT_UPLOAD_LOG_FD}" \
    || upload_status=$?
  verify_xcodebuild_authentication_contract \
    || fail "release authentication identity changed during upload"
  (( upload_status == 0 )) || return ${upload_status}
  verify_export_destination_identity \
    || fail "export or pinned upload-log destination changed during upload"
  exec {TESTFLIGHT_UPLOAD_LOG_FD}>&-
  TESTFLIGHT_UPLOAD_LOG_FD=-1
  verify_pinned_log_destination \
    "${TESTFLIGHT_UPLOAD_LOG_PATH}" \
    "${TESTFLIGHT_UPLOAD_LOG_IDENTITY}" -1 \
    || fail "upload log path changed after descriptor close"
  verify_export_options_identity \
    || fail "export options changed during upload"
  verify_archive_payload_after_upload \
    || fail "archived application payload changed during upload"
  verify_archive_contents_at_path "${TESTFLIGHT_ARCHIVE_PATH}"
  cleanup_private_build_volume_signal_masked \
    || fail "could not clean the exact private build volume"
  verify_archive_payload_after_upload \
    || fail "archived application payload changed after private-build cleanup"
  verify_archive_contents_at_path "${TESTFLIGHT_ARCHIVE_PATH}"
  print -- "side-by-side TestFlight upload completed; evidence: ${output_directory}"
}

function run_authorized_api_key_upload() {
  pin_app_store_connect_api_key_identity \
    || fail "reviewed App Store Connect API key is missing, changed, or unsafe (${TESTFLIGHT_ASC_API_KEY_PIN_FAILURE})"
  run_authorized_upload
}

verify_static_contract
pin_export_options_identity \
  || fail "could not pin the reviewed export-options identity"
reject_unsafe_build_environment
if [[ "${1:-}" == '--verify-api-key-config-only' ]]; then
  (( $# == 1 )) || fail \
    "--verify-api-key-config-only accepts no additional arguments"
  pin_app_store_connect_api_key_identity \
    || fail "reviewed App Store Connect API key is missing, changed, or unsafe (${TESTFLIGHT_ASC_API_KEY_PIN_FAILURE})"
fi
pin_reviewed_xcode_toolchain_identity \
  || fail "active Xcode does not match the reviewed signed T7 toolchain identity"

case "${1:-}" in
  --verify-config-only)
    (( $# == 1 )) || fail "--verify-config-only accepts no additional arguments"
    print -- "side-by-side TestFlight configuration verified"
    ;;
  --verify-api-key-config-only)
    verify_app_store_connect_api_key_identity \
      || fail "reviewed App Store Connect API key changed during Xcode verification"
    print -- "side-by-side TestFlight API-key configuration verified"
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
  --upload-authorized-side-by-side-testflight-with-api-key)
    (( $# == 1 )) || fail \
      "--upload-authorized-side-by-side-testflight-with-api-key accepts no additional arguments"
    run_authorized_api_key_upload
    ;;
  *)
    fail \
      "usage: $0 --verify-config-only | --verify-api-key-config-only | --archive-only | --upload-authorized-side-by-side-testflight | --upload-authorized-side-by-side-testflight-with-api-key"
    ;;
esac
