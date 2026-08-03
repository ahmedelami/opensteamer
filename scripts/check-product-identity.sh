#!/bin/zsh
# Verifies that every build and deployment surface agrees on the exact opensteamer product
# identity. The iOS Release app uses its App Store identity; Debug, test, Keychain, protocol, and
# macOS compatibility identifiers remain separately asserted so no configuration can drift.
set -uo pipefail

REPOSITORY=${1:-.}
if [[ ! -d "$REPOSITORY" ]]; then
  print -u2 -- "product identity check failed: repository directory does not exist: $REPOSITORY"
  exit 1
fi

ROOT="$(cd "$REPOSITORY" && pwd -P)"
FAILURES=0
EXPECTED_IOS_TARGETS=$'opensteamer\nopensteamerTests\nopensteamerUITests'
EXPECTED_SCHEME_FILES=$'opensteamer.xcscheme\nopensteamerTestFlight.xcscheme\nopensteamerUITests.xcscheme'

fail() {
  print -u2 -r -- "product identity check failed: $1"
  FAILURES=$((FAILURES + 1))
}

assert_equal() {
  local description=$1
  local expected=$2
  local actual=$3
  if [[ "$actual" != "$expected" ]]; then
    [[ -n "$actual" ]] || actual='<missing>'
    fail "$description: expected [$expected], found [$actual]"
  fi
}

require_file() {
  local relative_path=$1
  if [[ ! -f "$ROOT/$relative_path" ]]; then
    fail "required file is missing: $relative_path"
    return 1
  fi
  return 0
}

require_directory() {
  local relative_path=$1
  if [[ ! -d "$ROOT/$relative_path" ]]; then
    fail "required directory is missing: $relative_path"
    return 1
  fi
  return 0
}

assert_plist_value() {
  local relative_path=$1
  local key_path=$2
  local expected=$3
  local description=$4
  local actual

  require_file "$relative_path" || return
  if ! plutil -lint "$ROOT/$relative_path" >/dev/null 2>&1; then
    fail "$description: $relative_path is not a valid property list"
    return
  fi
  if ! actual=$(plutil -extract "$key_path" raw -o - "$ROOT/$relative_path" 2>/dev/null); then
    fail "$description: key $key_path is missing from $relative_path"
    return
  fi
  assert_equal "$description" "$expected" "$actual"
}

assert_json_name() {
  local relative_path=$1
  local selector=$2
  local expected=$3
  local description=$4
  local actual

  require_file "$relative_path" || return
  if ! actual=$(node -e '
    const fs = require("node:fs");
    const file = process.argv[1];
    const selector = process.argv[2];
    try {
      const document = JSON.parse(fs.readFileSync(file, "utf8"));
      const value = selector === "lock-root" ? document.packages?.[""]?.name : document.name;
      if (typeof value !== "string") process.exit(2);
      process.stdout.write(value);
    } catch (_) {
      process.exit(3);
    }
  ' "$ROOT/$relative_path" "$selector"); then
    fail "$description: could not read a string name from $relative_path ($selector)"
    return
  fi
  assert_equal "$description" "$expected" "$actual"
}

assert_literal_count() {
  local relative_path=$1
  local literal=$2
  local expected_count=$3
  local description=$4
  local actual_count

  require_file "$relative_path" || return
  if ! actual_count=$(node -e '
    const fs = require("node:fs");
    const contents = fs.readFileSync(process.argv[1], "utf8");
    const literal = process.argv[2];
    if (literal.length === 0) process.exit(2);
    let count = 0;
    let offset = 0;
    while ((offset = contents.indexOf(literal, offset)) >= 0) {
      count += 1;
      offset += literal.length;
    }
    process.stdout.write(String(count));
  ' "$ROOT/$relative_path" "$literal"); then
    fail "$description: could not count the required literal in $relative_path"
    return
  fi
  assert_equal "$description" "$expected_count" "$actual_count"
}

toml_root_name() {
  awk '
    BEGIN { in_section = 0; count = 0 }
    /^[[:space:]]*\[/ { in_section = 1 }
    !in_section && /^[[:space:]]*name[[:space:]]*=/ {
      value = $0
      sub(/^[^=]*=[[:space:]]*/, "", value)
      if (value !~ /^"[^"]+"[[:space:]]*$/) exit 2
      sub(/^"/, "", value)
      sub(/"[[:space:]]*$/, "", value)
      print value
      count++
    }
    END { if (count != 1) exit 3 }
  ' "$1"
}

assert_toml_name() {
  local relative_path=$1
  local expected=$2
  local description=$3
  local actual

  require_file "$relative_path" || return
  if ! actual=$(toml_root_name "$ROOT/$relative_path"); then
    fail "$description: could not read exactly one quoted root name from $relative_path"
    return
  fi
  assert_equal "$description" "$expected" "$actual"
}

for required_tool in awk find grep node plutil sed sort xmllint; do
  if ! command -v "$required_tool" >/dev/null 2>&1; then
    fail "required validation tool is unavailable: $required_tool"
  fi
done
if (( FAILURES > 0 )); then
  exit 1
fi

# Root package and public project name.
if require_file Package.swift; then
  SWIFT_PACKAGE_NAME=$(awk '
    /^let package = Package\([[:space:]]*$/ { in_package = 1; next }
    in_package && /^[[:space:]]*(platforms|products|dependencies|targets):/ { exit }
    in_package && /^[[:space:]]*name:[[:space:]]*"/ {
      value = $0
      sub(/^[[:space:]]*name:[[:space:]]*"/, "", value)
      sub(/",[[:space:]]*$/, "", value)
      print value
      exit
    }
  ' "$ROOT/Package.swift")
  assert_equal "root Swift package name" opensteamer "$SWIFT_PACKAGE_NAME"
fi

if require_file README.md; then
  README_HEADING=$(sed -n '1p' "$ROOT/README.md")
  assert_equal "README heading" '# opensteamer' "$README_HEADING"
fi

# XcodeGen is authoritative, while the generated project and shared schemes must carry the same
# names so local builds, archives, and CI cannot silently diverge.
require_directory iOS/opensteamer
require_directory iOS/opensteamer/opensteamer.xcodeproj
require_file iOS/opensteamer/opensteamer.xcodeproj/project.pbxproj

if [[ -d "$ROOT/iOS/opensteamer" ]]; then
  IOS_PROJECTS=$(find "$ROOT/iOS/opensteamer" -mindepth 1 -maxdepth 1 -type d -name '*.xcodeproj' \
    -exec basename {} \; | LC_ALL=C sort)
  assert_equal "iOS Xcode project directory set" opensteamer.xcodeproj "$IOS_PROJECTS"
fi

PROJECT_YML='iOS/opensteamer/project.yml'
if require_file "$PROJECT_YML"; then
  assert_literal_count \
    "$PROJECT_YML" \
    'postGenCommand: /bin/zsh scripts/restore-archive-only-testflight-scheme.sh' 1 \
    'project.yml archive-only TestFlight scheme restoration hook'
  # Target names are the product names. An override can silently rename only one configuration,
  # so the authoritative XcodeGen source must continue to inherit its exact target identities.
  assert_literal_count \
    "$PROJECT_YML" 'PRODUCT_NAME:' 0 'project.yml product-name override count'
  assert_literal_count \
    "$PROJECT_YML" 'CODE_SIGN_IDENTITY:' 0 'project.yml code-sign identity override count'

  XCODEGEN_PROJECT_NAME=$(awk '
    /^name:[[:space:]]*/ {
      value = $0
      sub(/^name:[[:space:]]*/, "", value)
      print value
    }
  ' "$ROOT/$PROJECT_YML")
  assert_equal "project.yml project name" opensteamer "$XCODEGEN_PROJECT_NAME"

  XCODEGEN_PACKAGES=$(awk '
    /^packages:[[:space:]]*$/ { in_packages = 1; next }
    in_packages && /^[^[:space:]]/ { in_packages = 0 }
    in_packages && substr($0, 1, 2) == "  " && substr($0, 3, 1) != " " && /:[[:space:]]*$/ {
      value = substr($0, 3)
      sub(/:[[:space:]]*$/, "", value)
      print value
    }
  ' "$ROOT/$PROJECT_YML" | LC_ALL=C sort)
  assert_equal "project.yml local package reference set" opensteamer "$XCODEGEN_PACKAGES"

  XCODEGEN_TARGETS=$(awk '
    /^targets:[[:space:]]*$/ { in_targets = 1; next }
    in_targets && /^[^[:space:]]/ { in_targets = 0 }
    in_targets && substr($0, 1, 2) == "  " && substr($0, 3, 1) != " " && /:[[:space:]]*$/ {
      value = substr($0, 3)
      sub(/:[[:space:]]*$/, "", value)
      print value
    }
  ' "$ROOT/$PROJECT_YML" | LC_ALL=C sort)
  assert_equal "project.yml targets" "$EXPECTED_IOS_TARGETS" "$XCODEGEN_TARGETS"

  XCODEGEN_TARGET_TYPES=$(awk '
    /^targets:[[:space:]]*$/ { in_targets = 1; next }
    in_targets && /^[^[:space:]]/ { in_targets = 0 }
    in_targets && /^  [^[:space:]][^:]*:[[:space:]]*$/ {
      target = $0
      sub(/^  /, "", target)
      sub(/:[[:space:]]*$/, "", target)
      next
    }
    in_targets && /^    type:[[:space:]]*/ {
      value = $0
      sub(/^    type:[[:space:]]*/, "", value)
      print target "|" value
    }
  ' "$ROOT/$PROJECT_YML" | LC_ALL=C sort)
  EXPECTED_XCODEGEN_TARGET_TYPES=$(printf '%s\n' \
    'opensteamer|application' \
    'opensteamerTests|bundle.unit-test' \
    'opensteamerUITests|bundle.ui-testing' \
    | LC_ALL=C sort)
  assert_equal \
    "project.yml target/product-type mapping" \
    "$EXPECTED_XCODEGEN_TARGET_TYPES" \
    "$XCODEGEN_TARGET_TYPES"

  XCODEGEN_BUNDLE_ID_MAPPINGS=$(awk '
    /^targets:[[:space:]]*$/ { in_targets = 1; next }
    in_targets && /^[^[:space:]]/ { in_targets = 0 }
    in_targets && /^  [^[:space:]][^:]*:[[:space:]]*$/ {
      target = $0
      sub(/^  /, "", target)
      sub(/:[[:space:]]*$/, "", target)
      scope = ""
      next
    }
    in_targets && /^      base:[[:space:]]*$/ { scope = "base"; next }
    in_targets && /^      configs:[[:space:]]*$/ { scope = ""; next }
    in_targets && /^        Debug:[[:space:]]*$/ { scope = "Debug"; next }
    in_targets && /^        Release:[[:space:]]*$/ { scope = "Release"; next }
    in_targets && /^        TestFlight:[[:space:]]*$/ { scope = "TestFlight"; next }
    in_targets && /PRODUCT_BUNDLE_IDENTIFIER:[[:space:]]*/ {
      value = $0
      sub(/^.*PRODUCT_BUNDLE_IDENTIFIER:[[:space:]]*/, "", value)
      print target "|" scope "|" value
    }
  ' "$ROOT/$PROJECT_YML" | LC_ALL=C sort)
  EXPECTED_XCODEGEN_BUNDLE_ID_MAPPINGS=$(printf '%s\n' \
    'opensteamer|Debug|org.example.AudioStreamer.dev' \
    'opensteamer|Release|com.elamin.AudioStreamer' \
    'opensteamer|TestFlight|com.elamin.opensteamer' \
    'opensteamerTests|base|org.example.AudioStreamerTests' \
    'opensteamerUITests|base|org.example.AudioStreamerUITests' \
    | LC_ALL=C sort)
  assert_equal \
    "project.yml target/configuration bundle-ID mapping" \
    "$EXPECTED_XCODEGEN_BUNDLE_ID_MAPPINGS" \
    "$XCODEGEN_BUNDLE_ID_MAPPINGS"
fi

PBX_PROJECT='iOS/opensteamer/opensteamer.xcodeproj/project.pbxproj'
APP_TARGET_ID=''
UNIT_TEST_TARGET_ID=''
UI_TEST_TARGET_ID=''
if [[ -f "$ROOT/$PBX_PROJECT" ]]; then
  if ! plutil -lint "$ROOT/$PBX_PROJECT" >/dev/null 2>&1; then
    fail "generated Xcode project is not a valid ASCII property list: $PBX_PROJECT"
  fi
  if ! PBX_CONTRACTS=$(node -e '
    const fs = require("node:fs");
    const text = fs.readFileSync(process.argv[1], "utf8");
    function section(name) {
      const start = `/* Begin ${name} section */`;
      const end = `/* End ${name} section */`;
      const first = text.indexOf(start);
      const last = text.indexOf(end);
      if (first < 0 || last <= first) throw new Error(`missing ${name}`);
      return text.slice(first + start.length, last);
    }
    function objects(name) {
      const source = section(name);
      const values = new Map();
      const expression = /^[ \t]*([A-F0-9]+) \/\* ([^*]+) \*\/ = \{/gm;
      let match;
      while ((match = expression.exec(source)) !== null) {
        const objectStart = expression.lastIndex - 1;
        let depth = 0;
        let quoted = false;
        let escaped = false;
        let objectEnd = -1;
        for (let index = objectStart; index < source.length; index += 1) {
          const character = source[index];
          if (quoted) {
            if (escaped) escaped = false;
            else if (character === "\\") escaped = true;
            else if (character === "\"") quoted = false;
            continue;
          }
          if (character === "\"") {
            quoted = true;
          } else if (character === "{") {
            depth += 1;
          } else if (character === "}") {
            depth -= 1;
            if (depth === 0) {
              objectEnd = index + 1;
              break;
            }
          }
        }
        if (objectEnd < 0) throw new Error(`unterminated object ${match[1]} in ${name}`);
        values.set(match[1], { body: source.slice(objectStart, objectEnd) });
        expression.lastIndex = objectEnd;
      }
      if (values.size === 0) throw new Error(`empty ${name}`);
      return values;
    }
    function setting(body, key) {
      const escapedKey = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      const match = body.match(
        new RegExp(`(?:^|[\\n;{])\\s*${escapedKey}\\s*=\\s*([^;]+);`, "m")
      );
      if (!match) throw new Error(`missing ${key}`);
      return match[1].trim().replace(/^"|"$/g, "");
    }
    function referenceID(body, key) {
      const escapedKey = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      const match = body.match(
        new RegExp(`(?:^|[\\n;{])\\s*${escapedKey}\\s*=\\s*([A-F0-9]+)\\b`, "m")
      );
      if (!match) throw new Error(`missing ${key} reference`);
      return match[1];
    }
    const targets = objects("PBXNativeTarget");
    const fileReferences = objects("PBXFileReference");
    const buildConfigurations = objects("XCBuildConfiguration");
    const configurationLists = objects("XCConfigurationList");
    const lines = [];
    for (const [targetID, target] of targets.entries()) {
      const name = setting(target.body, "name");
      const productName = setting(target.body, "productName");
      const productType = setting(target.body, "productType");
      const productReferenceID = referenceID(target.body, "productReference");
      const productReference = fileReferences.get(productReferenceID);
      if (!productReference) throw new Error(`missing product reference for ${name}`);
      const productPath = setting(productReference.body, "path");
      const productFileType = setting(productReference.body, "lastKnownFileType");
      const configurationListID = referenceID(target.body, "buildConfigurationList");
      lines.push(`target|${name}|${productName}|${productPath}|${productFileType}|${productType}`);
      lines.push(`target-id|${name}|${targetID}`);
      const configurationList = configurationLists.get(configurationListID);
      if (!configurationList) throw new Error(`missing configuration list for ${name}`);
      const entries = configurationList.body.match(
        /buildConfigurations = \(([\s\S]*?)\);/
      )?.[1];
      if (!entries) throw new Error(`missing configurations for ${name}`);
      const entryIDs = entries.split("\n").flatMap((line) => {
        const entry = line.match(/^\s*([A-F0-9]+)\b/);
        return entry ? [entry[1]] : [];
      });
      const configurationNames = new Set();
      for (const entryID of entryIDs) {
        const configuration = buildConfigurations.get(entryID);
        if (!configuration) throw new Error(`missing configuration ${entryID} for ${name}`);
        const configurationName = setting(configuration.body, "name");
        if (!["Debug", "Release", "TestFlight"].includes(configurationName)) {
          throw new Error(`unexpected configuration ${configurationName} for ${name}`);
        }
        if (configurationNames.has(configurationName)) {
          throw new Error(`duplicate configuration ${configurationName} for ${name}`);
        }
        configurationNames.add(configurationName);
        const bundleID = setting(configuration.body, "PRODUCT_BUNDLE_IDENTIFIER");
        lines.push(`build|${name}|${configurationName}|${bundleID}`);
      }
      if (entryIDs.length !== 3 || configurationNames.size !== 3) {
        throw new Error(`wrong configuration set for ${name}`);
      }
    }
    process.stdout.write(lines.sort().join("\n"));
  ' "$ROOT/$PBX_PROJECT"); then
    fail "could not parse generated Xcode target/product/configuration mappings"
  else
    PBX_TARGET_CONTRACTS=$(print -r -- "$PBX_CONTRACTS" \
      | sed -n '/^target|/p' | LC_ALL=C sort)
    EXPECTED_PBX_TARGET_CONTRACTS=$(printf '%s\n' \
      'target|opensteamer|opensteamer|opensteamer.app|wrapper.application|com.apple.product-type.application' \
      'target|opensteamerTests|opensteamerTests|opensteamerTests.xctest|wrapper.cfbundle|com.apple.product-type.bundle.unit-test' \
      'target|opensteamerUITests|opensteamerUITests|opensteamerUITests.xctest|wrapper.cfbundle|com.apple.product-type.bundle.ui-testing' \
      | LC_ALL=C sort)
    assert_equal \
      "generated Xcode target/product mapping" \
      "$EXPECTED_PBX_TARGET_CONTRACTS" \
      "$PBX_TARGET_CONTRACTS"

    PBX_BUILD_CONTRACTS=$(print -r -- "$PBX_CONTRACTS" \
      | sed -n '/^build|/p' | LC_ALL=C sort)
    EXPECTED_PBX_BUILD_CONTRACTS=$(printf '%s\n' \
      'build|opensteamer|Debug|org.example.AudioStreamer.dev' \
      'build|opensteamer|Release|com.elamin.AudioStreamer' \
      'build|opensteamer|TestFlight|com.elamin.opensteamer' \
      'build|opensteamerTests|Debug|org.example.AudioStreamerTests' \
      'build|opensteamerTests|Release|org.example.AudioStreamerTests' \
      'build|opensteamerTests|TestFlight|org.example.AudioStreamerTests' \
      'build|opensteamerUITests|Debug|org.example.AudioStreamerUITests' \
      'build|opensteamerUITests|Release|org.example.AudioStreamerUITests' \
      'build|opensteamerUITests|TestFlight|org.example.AudioStreamerUITests' \
      | LC_ALL=C sort)
    assert_equal \
      "generated Xcode target/configuration bundle-ID mapping" \
      "$EXPECTED_PBX_BUILD_CONTRACTS" \
      "$PBX_BUILD_CONTRACTS"

    APP_TARGET_ID=$(print -r -- "$PBX_CONTRACTS" | awk -F'|' \
      '$1 == "target-id" && $2 == "opensteamer" { print $3 }')
    UNIT_TEST_TARGET_ID=$(print -r -- "$PBX_CONTRACTS" | awk -F'|' \
      '$1 == "target-id" && $2 == "opensteamerTests" { print $3 }')
    UI_TEST_TARGET_ID=$(print -r -- "$PBX_CONTRACTS" | awk -F'|' \
      '$1 == "target-id" && $2 == "opensteamerUITests" { print $3 }')
    [[ -n "$APP_TARGET_ID" && "$APP_TARGET_ID" != *$'\n'* ]] \
      || fail "could not resolve exactly one generated app target ID"
    [[ -n "$UNIT_TEST_TARGET_ID" && "$UNIT_TEST_TARGET_ID" != *$'\n'* ]] \
      || fail "could not resolve exactly one generated unit-test target ID"
    [[ -n "$UI_TEST_TARGET_ID" && "$UI_TEST_TARGET_ID" != *$'\n'* ]] \
      || fail "could not resolve exactly one generated UI-test target ID"
  fi

  # XcodeGen emits one project-level fallback for each configuration. Target configurations must not
  # override it; together with the target-name mapping above this proves the effective product,
  # wrapper, and executable names in both configurations.
  assert_literal_count \
    "$PBX_PROJECT" 'PRODUCT_NAME = ' 3 'generated Xcode product-name setting count'
  assert_literal_count \
    "$PBX_PROJECT" 'PRODUCT_NAME = "$(TARGET_NAME)";' 3 \
    'generated Xcode inherited product-name defaults'
fi

scheme_contracts() {
  node -e '
    const fs = require("node:fs");
    const text = fs.readFileSync(process.argv[1], "utf8");
    const references = [...text.matchAll(/<BuildableReference\b([^>]*)\/?\s*>/g)];
    if (references.length === 0) process.exit(2);
    const lines = references.map((reference) => {
      const attributes = reference[1];
      function value(name) {
        const match = attributes.match(new RegExp(`${name}\\s*=\\s*"([^"]+)"`));
        if (!match) throw new Error(`missing ${name}`);
        return match[1];
      }
      return `${value("BlueprintIdentifier")}|${value("BuildableName")}|${value("BlueprintName")}|${value("ReferencedContainer")}`;
    });
    process.stdout.write([...new Set(lines)].sort().join("\n"));
  ' "$1"
}

SCHEME_DIRECTORY='iOS/opensteamer/opensteamer.xcodeproj/xcshareddata/xcschemes'
if require_directory "$SCHEME_DIRECTORY"; then
  SCHEME_FILES=$(find "$ROOT/$SCHEME_DIRECTORY" -mindepth 1 -maxdepth 1 -type f -name '*.xcscheme' \
    -exec basename {} \; | LC_ALL=C sort)
  assert_equal "shared Xcode scheme filename set" "$EXPECTED_SCHEME_FILES" "$SCHEME_FILES"

  for scheme in opensteamer.xcscheme opensteamerTestFlight.xcscheme opensteamerUITests.xcscheme; do
    if [[ -f "$ROOT/$SCHEME_DIRECTORY/$scheme" ]] \
      && ! xmllint --noout "$ROOT/$SCHEME_DIRECTORY/$scheme" >/dev/null 2>&1; then
      fail "shared Xcode scheme is not valid XML: $scheme"
    fi
  done

  APP_SCHEME="$ROOT/$SCHEME_DIRECTORY/opensteamer.xcscheme"
  if [[ -f "$APP_SCHEME" ]]; then
    if ! APP_SCHEME_CONTRACTS=$(scheme_contracts "$APP_SCHEME"); then
      fail "could not parse opensteamer scheme buildable mappings"
    else
      EXPECTED_APP_SCHEME_CONTRACTS=$(printf '%s\n' \
        "$APP_TARGET_ID|opensteamer.app|opensteamer|container:opensteamer.xcodeproj" \
        "$UNIT_TEST_TARGET_ID|opensteamerTests.xctest|opensteamerTests|container:opensteamer.xcodeproj" \
        | LC_ALL=C sort)
      assert_equal \
        "opensteamer scheme buildable/blueprint/project mapping" \
        "$EXPECTED_APP_SCHEME_CONTRACTS" \
        "$APP_SCHEME_CONTRACTS"
    fi
  fi

  TESTFLIGHT_SCHEME="$ROOT/$SCHEME_DIRECTORY/opensteamerTestFlight.xcscheme"
  if [[ -f "$TESTFLIGHT_SCHEME" ]]; then
    if ! TESTFLIGHT_SCHEME_CONTRACTS=$(scheme_contracts "$TESTFLIGHT_SCHEME"); then
      fail "could not parse opensteamerTestFlight scheme buildable mappings"
    else
      assert_equal \
        "opensteamerTestFlight scheme buildable/blueprint/project mapping" \
        "$APP_TARGET_ID|opensteamer.app|opensteamer|container:opensteamer.xcodeproj" \
        "$TESTFLIGHT_SCHEME_CONTRACTS"
    fi
    TESTFLIGHT_ARCHIVE_CONFIG=$(xmllint --xpath \
      'string(/Scheme/ArchiveAction/@buildConfiguration)' "$TESTFLIGHT_SCHEME" 2>/dev/null)
    assert_equal \
      "opensteamerTestFlight archive configuration" \
      TestFlight \
      "$TESTFLIGHT_ARCHIVE_CONFIG"
    TESTFLIGHT_BUILD_FLAGS=$(xmllint --xpath \
      'concat(string(/Scheme/BuildAction/BuildActionEntries/BuildActionEntry/@buildForTesting), "|", string(/Scheme/BuildAction/BuildActionEntries/BuildActionEntry/@buildForRunning), "|", string(/Scheme/BuildAction/BuildActionEntries/BuildActionEntry/@buildForProfiling), "|", string(/Scheme/BuildAction/BuildActionEntries/BuildActionEntry/@buildForArchiving), "|", string(/Scheme/BuildAction/BuildActionEntries/BuildActionEntry/@buildForAnalyzing))' \
      "$TESTFLIGHT_SCHEME" 2>/dev/null)
    assert_equal \
      "opensteamerTestFlight archive-only build flags" \
      'NO|NO|NO|YES|NO' \
      "$TESTFLIGHT_BUILD_FLAGS"
    TESTFLIGHT_NONARCHIVE_ACTION_COUNT=$(xmllint --xpath \
      'count(/Scheme/TestAction | /Scheme/LaunchAction | /Scheme/ProfileAction | /Scheme/AnalyzeAction)' \
      "$TESTFLIGHT_SCHEME" 2>/dev/null)
    assert_equal \
      "opensteamerTestFlight non-archive action count" \
      0 \
      "$TESTFLIGHT_NONARCHIVE_ACTION_COUNT"
  fi

  TESTFLIGHT_SCHEME_SOURCE='iOS/opensteamer/TestFlightScheme/opensteamerTestFlight.xcscheme'
  TESTFLIGHT_SCHEME_RESTORER='iOS/opensteamer/scripts/restore-archive-only-testflight-scheme.sh'
  require_file "$TESTFLIGHT_SCHEME_SOURCE"
  require_file "$TESTFLIGHT_SCHEME_RESTORER"
  if [[ -f "$ROOT/$TESTFLIGHT_SCHEME_SOURCE" \
      && -f "$TESTFLIGHT_SCHEME" ]] \
      && ! cmp -s "$ROOT/$TESTFLIGHT_SCHEME_SOURCE" "$TESTFLIGHT_SCHEME"; then
    fail 'generated TestFlight scheme differs from reviewed archive-only source'
  fi
  assert_literal_count "$TESTFLIGHT_SCHEME_RESTORER" \
    'SOURCE_SCHEME="${PROJECT_DIR}/TestFlightScheme/opensteamerTestFlight.xcscheme"' 1 \
    'archive-only TestFlight restorer source'
  assert_literal_count "$TESTFLIGHT_SCHEME_RESTORER" \
    'DESTINATION_SCHEME="${PROJECT_DIR}/opensteamer.xcodeproj/xcshareddata/xcschemes/opensteamerTestFlight.xcscheme"' 1 \
    'archive-only TestFlight restorer destination'

  UI_SCHEME="$ROOT/$SCHEME_DIRECTORY/opensteamerUITests.xcscheme"
  if [[ -f "$UI_SCHEME" ]]; then
    if ! UI_SCHEME_CONTRACTS=$(scheme_contracts "$UI_SCHEME"); then
      fail "could not parse opensteamerUITests scheme buildable mappings"
    else
      assert_equal \
        "opensteamerUITests scheme buildable/blueprint/project mapping" \
        "$UI_TEST_TARGET_ID|opensteamerUITests.xctest|opensteamerUITests|container:opensteamer.xcodeproj" \
        "$UI_SCHEME_CONTRACTS"
    fi
  fi
fi

SIDE_BY_SIDE_TESTFLIGHT_SCRIPT='iOS/opensteamer/scripts/archive-upload-side-by-side-testflight.sh'
require_file "$SIDE_BY_SIDE_TESTFLIGHT_SCRIPT"
assert_literal_count "$SIDE_BY_SIDE_TESTFLIGHT_SCRIPT" \
  'EXPECTED_BUNDLE_IDENTIFIER="com.elamin.opensteamer"' 1 \
  'side-by-side TestFlight expected bundle guard'
assert_literal_count "$SIDE_BY_SIDE_TESTFLIGHT_SCRIPT" \
  'PROTECTED_BUNDLE_IDENTIFIER="com.elamin.AudioStreamer"' 1 \
  'side-by-side TestFlight protected bundle rejection guard'
assert_literal_count "$SIDE_BY_SIDE_TESTFLIGHT_SCRIPT" \
  'EXPECTED_SCHEME="opensteamerTestFlight"' 1 \
  'side-by-side TestFlight scheme guard'
assert_literal_count "$SIDE_BY_SIDE_TESTFLIGHT_SCRIPT" \
  'EXPECTED_CONFIGURATION="TestFlight"' 1 \
  'side-by-side TestFlight configuration guard'
assert_literal_count "$SIDE_BY_SIDE_TESTFLIGHT_SCRIPT" \
  'EXPECTED_BUILD_NUMBER="40"' 1 \
  'side-by-side TestFlight build-number guard'
assert_literal_count "$SIDE_BY_SIDE_TESTFLIGHT_SCRIPT" \
  'PRIVATE_TEMPORARY_ROOT="/private/tmp"' 1 \
  'side-by-side TestFlight fixed temporary root'
assert_literal_count "$SIDE_BY_SIDE_TESTFLIGHT_SCRIPT" \
  'TMPDIR' 0 \
  'side-by-side TestFlight caller-controlled temporary root rejection'
assert_literal_count "$SIDE_BY_SIDE_TESTFLIGHT_SCRIPT" \
  'require_new_output_directory' 0 \
  'side-by-side TestFlight caller-controlled output path rejection'

SIDE_BY_SIDE_EXPORT_OPTIONS='iOS/opensteamer/TestFlightExportOptions.plist'
assert_plist_value "$SIDE_BY_SIDE_EXPORT_OPTIONS" destination upload \
  'side-by-side TestFlight export destination'
assert_plist_value "$SIDE_BY_SIDE_EXPORT_OPTIONS" method app-store-connect \
  'side-by-side TestFlight export method'
assert_plist_value "$SIDE_BY_SIDE_EXPORT_OPTIONS" signingStyle automatic \
  'side-by-side TestFlight export signing style'
assert_plist_value "$SIDE_BY_SIDE_EXPORT_OPTIONS" teamID MSMG8CJLB3 \
  'side-by-side TestFlight export team'
assert_plist_value "$SIDE_BY_SIDE_EXPORT_OPTIONS" manageAppVersionAndBuildNumber false \
  'side-by-side TestFlight fixed build-number policy'
assert_plist_value "$SIDE_BY_SIDE_EXPORT_OPTIONS" testFlightInternalTestingOnly true \
  'side-by-side TestFlight internal-only policy'
assert_plist_value "$SIDE_BY_SIDE_EXPORT_OPTIONS" uploadSymbols true \
  'side-by-side TestFlight symbol upload policy'

assert_plist_value iOS/opensteamer/Sources/Support/Info.plist \
  CFBundleDisplayName opensteamer 'iOS CFBundleDisplayName lowercase identity'
assert_plist_value iOS/opensteamer/Sources/Support/Info.plist \
  CFBundleName opensteamer 'iOS CFBundleName lowercase identity'
assert_plist_value iOS/opensteamer/Sources/Support/Info.plist \
  CFBundleExecutable '$(EXECUTABLE_NAME)' 'iOS Info.plist executable indirection'
assert_plist_value iOS/opensteamer/Sources/Support/Info.plist \
  CFBundleIdentifier '$(PRODUCT_BUNDLE_IDENTIFIER)' 'iOS Info.plist bundle identifier indirection'
assert_plist_value iOS/opensteamer/Sources/Support/Info.plist \
  NSLocalNetworkUsageDescription \
  'opensteamer finds the Mac capture server on your local Wi-Fi network.' \
  'iOS local-network description lowercase identity'
assert_plist_value iOS/opensteamer/Sources/Support/Info.plist \
  NSCameraUsageDescription \
  'opensteamer may request camera access through its real-time communication framework only when you explicitly start a camera-capable sharing feature. Ordinary audio and screen streaming do not access the camera.' \
  'iOS camera usage description'
assert_literal_count iOS/opensteamer/Sources/Views/BrowserView.swift \
  '.navigationTitle("opensteamer")' 1 'iOS navigation-title lowercase identity'
assert_literal_count iOS/opensteamer/Sources/App/BackgroundPlaybackCoordinator.swift \
  'MPMediaItemPropertyTitle: "opensteamer"' 1 'iOS Now Playing lowercase identity'

# The distributed host uses user-facing opensteamer naming but retains the established bundle ID.
assert_plist_value macOS/OpensteamerHost/Info.plist \
  CFBundleDisplayName 'opensteamer Host' 'macOS host CFBundleDisplayName'
assert_plist_value macOS/OpensteamerHost/Info.plist \
  CFBundleName 'opensteamer Host' 'macOS host CFBundleName'
assert_plist_value macOS/OpensteamerHost/Info.plist \
  CFBundleIdentifier com.elamin.AudioStreamer.CaptureServer 'preserved macOS host bundle identifier'
assert_plist_value macOS/OpensteamerHost/Info.plist \
  CFBundleExecutable CaptureServer 'macOS host executable name'
assert_plist_value macOS/OpensteamerHost/Info.plist \
  NSAudioCaptureUsageDescription \
  "opensteamer captures this Mac's audio so it can stream playback to your iPhone." \
  'macOS host audio-capture description lowercase identity'
assert_plist_value macOS/OpensteamerHost/Info.plist \
  NSMicrophoneUsageDescription \
  "opensteamer records the BlackHole virtual input so it can stream this Mac's routed audio to your iPhone." \
  'macOS host microphone description lowercase identity'
assert_plist_value macOS/Sources/CaptureServer/Info.plist \
  CFBundleIdentifier com.elamin.AudioStreamer.CaptureServer \
  'preserved SwiftPM capture-server bundle identifier'
assert_plist_value macOS/Sources/CaptureServer/Info.plist \
  CFBundleName 'opensteamer Capture Server' 'SwiftPM capture-server bundle name'
assert_literal_count macOS/Sources/CaptureServer/WorldwidePairingStore.swift \
  '"com.elamin.opensteamer.CaptureServer.WorldwidePairing.v1"' 1 \
  'isolated opensteamer pairing Keychain service'
assert_literal_count macOS/Sources/CaptureServer/WorldwidePairingStore.swift \
  '"com.elamin.AudioStreamer.CaptureServer.WorldwidePairing.v1"' 0 \
  'protected legacy pairing Keychain service absence'
assert_literal_count macOS/Sources/CaptureServer/WorldwidePairingStore.swift \
  'init(service:' 0 'arbitrary pairing Keychain service initializer absence'
assert_literal_count macOS/Sources/CaptureServer/CaptureServerMain.swift \
  'dataStore: WorldwideKeychainDataStore()' 1 \
  'explicit opensteamer pairing-store composition'
assert_literal_count macOS/Sources/CaptureServer/CaptureServerMain.swift \
  'fflush(stdout)' 1 'immediate one-time pairing-code flush'
if require_directory macOS/Sources; then
  PROTECTED_PAIRING_SOURCE_MATCHES=$(find "$ROOT/macOS/Sources" -type f -name '*.swift' \
    -exec grep -lF -- \
      'com.elamin.AudioStreamer.CaptureServer.WorldwidePairing.v1' {} + 2>/dev/null || true)
  [[ -z "$PROTECTED_PAIRING_SOURCE_MATCHES" ]] \
    || fail 'protected legacy pairing Keychain service appears in macOS runtime source'
fi
assert_literal_count macOS/Sources/CaptureServer/WorldwideHostProcessLock.swift \
  '"com.elamin.AudioStreamer.CaptureServer.runtime"' 1 \
  'preserved cross-version runtime lock namespace'
assert_literal_count macOS/scripts/build-opensteamer-host-app.sh \
  '--identifier com.elamin.AudioStreamer.CaptureServer' 1 \
  'preserved macOS executable signature identifier'
assert_literal_count macOS/scripts/verify-mac-host-bundle.sh \
  'EXPECTED_BUNDLE_IDENTIFIER="com.elamin.AudioStreamer.CaptureServer"' 1 \
  'macOS bundle verifier identity'
assert_literal_count macOS/scripts/verify-mac-host-deployment.sh \
  '"com.elamin.AudioStreamer.CaptureServer"' 1 \
  'macOS deployment verifier identity'

LAUNCH_AGENT_DIRECTORY='macOS/LaunchAgents'
if require_directory "$LAUNCH_AGENT_DIRECTORY"; then
  LAUNCH_AGENT_FILES=$(find "$ROOT/$LAUNCH_AGENT_DIRECTORY" -mindepth 1 -maxdepth 1 \
    -type f -name '*.plist' -exec basename {} \; | LC_ALL=C sort)
  assert_equal "LaunchAgent filename set" org.example.opensteamer.worldwide.plist "$LAUNCH_AGENT_FILES"
fi

LAUNCH_AGENT='macOS/LaunchAgents/org.example.opensteamer.worldwide.plist'
assert_plist_value "$LAUNCH_AGENT" Label org.example.opensteamer.worldwide 'LaunchAgent label'
assert_plist_value "$LAUNCH_AGENT" ProgramArguments.0 \
  '/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer' \
  'LaunchAgent host program path'
assert_plist_value "$LAUNCH_AGENT" StandardOutPath \
  /var/tmp/opensteamer-worldwide-host.log 'LaunchAgent standard-output path'
assert_plist_value "$LAUNCH_AGENT" StandardErrorPath \
  /var/tmp/opensteamer-worldwide-host.err.log 'LaunchAgent standard-error path'

# npm records the identity twice in lockfiles: once at the document root and once for packages[""].
assert_json_name services/Rendezvous/package.json top @opensteamer/rendezvous \
  'Rendezvous npm package name'
assert_json_name services/Rendezvous/package-lock.json top @opensteamer/rendezvous \
  'Rendezvous lockfile package name'
assert_json_name services/Rendezvous/package-lock.json lock-root @opensteamer/rendezvous \
  'Rendezvous lockfile root-package name'
assert_json_name services/RendezvousWorker/package.json top @opensteamer/rendezvous-worker \
  'Worker npm package name'
assert_json_name services/RendezvousWorker/package-lock.json top @opensteamer/rendezvous-worker \
  'Worker lockfile package name'
assert_json_name services/RendezvousWorker/package-lock.json lock-root @opensteamer/rendezvous-worker \
  'Worker lockfile root-package name'
assert_json_name macOS/RelayBridge/package.json top opensteamer-relay-bridge \
  'RelayBridge npm package name'
assert_json_name macOS/RelayBridge/package-lock.json top opensteamer-relay-bridge \
  'RelayBridge lockfile package name'
assert_json_name macOS/RelayBridge/package-lock.json lock-root opensteamer-relay-bridge \
  'RelayBridge lockfile root-package name'

assert_toml_name services/RendezvousWorker/wrangler.toml opensteamer-rendezvous \
  'production Worker name'
assert_toml_name services/RendezvousWorker/wrangler.test.toml opensteamer-rendezvous-test \
  'test Worker name'

if (( FAILURES > 0 )); then
  print -u2 -- "opensteamer product identity check rejected $FAILURES mismatch(es)"
  exit 1
fi

print -- 'opensteamer product identity check passed'
