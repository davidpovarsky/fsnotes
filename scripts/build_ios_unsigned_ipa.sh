#!/usr/bin/env bash
set -Eeuo pipefail

# Build FSNotes iOS and package the built app bundle as an IPA artifact.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/build/ios-unsigned}"
LOG_DIR="$OUTPUT_DIR/logs"
DERIVED_DATA="$OUTPUT_DIR/DerivedData"
SYMROOT="$OUTPUT_DIR/Products"
PAYLOAD_DIR="$OUTPUT_DIR/Payload"
IPA_PATH="$OUTPUT_DIR/FSNotes-iOS-unsigned.ipa"
XCRESULT_PATH="$OUTPUT_DIR/FSNotes-iOS.xcresult"

SCHEME="${SCHEME:-FSNotes iOS}"
CONFIGURATION="${CONFIGURATION:-Release}"
BUNDLE_ID="${BUNDLE_ID:-com.local.fsnotes.ios}"
STRIP_PLUGINS="${STRIP_PLUGINS:-1}"
COCOAPODS_REPO_UPDATE="${COCOAPODS_REPO_UPDATE:-0}"
PATCH_ICLOUD_FATAL="${PATCH_ICLOUD_FATAL:-1}"

mkdir -p "$LOG_DIR" "$OUTPUT_DIR"

on_error() {
  local exit_code=$?
  echo ""
  echo "::error::iOS IPA build failed with exit code $exit_code"
  echo ""
  echo "Last 120 lines from logs:"
  for log in "$LOG_DIR"/*.log; do
    [ -f "$log" ] || continue
    echo ""
    echo "===== $log ====="
    tail -n 120 "$log" || true
  done
  echo ""
  echo "Diagnostic files to copy back:"
  echo "- $LOG_DIR/environment.log"
  echo "- $LOG_DIR/pod-install.log"
  echo "- $LOG_DIR/build-settings.log"
  echo "- $LOG_DIR/xcodebuild.log"
  echo "- $XCRESULT_PATH, if present"
  exit "$exit_code"
}
trap on_error ERR

run_and_log() {
  local name="$1"
  shift
  local log="$LOG_DIR/$name.log"
  echo ""
  echo "===== $* ====="
  set +e
  "$@" 2>&1 | tee "$log"
  local status=${PIPESTATUS[0]}
  set -e
  if [ "$status" -ne 0 ]; then
    echo "::error::$name failed with exit code $status. Full log: $log"
    return "$status"
  fi
}

cd "$ROOT_DIR"
rm -rf "$OUTPUT_DIR"
mkdir -p "$LOG_DIR" "$DERIVED_DATA" "$SYMROOT"

{
  echo "ROOT_DIR=$ROOT_DIR"
  echo "OUTPUT_DIR=$OUTPUT_DIR"
  echo "SCHEME=$SCHEME"
  echo "CONFIGURATION=$CONFIGURATION"
  echo "BUNDLE_ID=$BUNDLE_ID"
  echo "STRIP_PLUGINS=$STRIP_PLUGINS"
  echo "COCOAPODS_REPO_UPDATE=$COCOAPODS_REPO_UPDATE"
  echo "PATCH_ICLOUD_FATAL=$PATCH_ICLOUD_FATAL"
  echo "macOS=$(sw_vers -productVersion 2>/dev/null || true)"
  echo ""
  xcodebuild -version || true
  echo ""
  ruby --version || true
  pod --version || true
} | tee "$LOG_DIR/environment.log"

if [ "$PATCH_ICLOUD_FATAL" = "1" ]; then
  VIEW_CONTROLLER="$ROOT_DIR/FSNotes iOS/ViewController.swift"
  if grep -q 'fatalError("This app was not built with the proper entitlement requests.")' "$VIEW_CONTROLLER"; then
    echo "Patching iCloud entitlement fatalError for local IPA build" | tee "$LOG_DIR/source-patch.log"
    python3 - <<'PY'
from pathlib import Path
path = Path('FSNotes iOS/ViewController.swift')
text = path.read_text()
old = '            fatalError("This app was not built with the proper entitlement requests.")'
new = '            print("iCloud key-value store is unavailable in this local IPA build; continuing without that entitlement.")'
if old not in text:
    raise SystemExit('Expected iCloud entitlement fatalError was not found')
path.write_text(text.replace(old, new, 1))
PY
  else
    echo "iCloud entitlement fatalError patch was not needed" | tee "$LOG_DIR/source-patch.log"
  fi
fi

if ! command -v pod >/dev/null 2>&1; then
  run_and_log install-cocoapods sudo gem install cocoapods
fi

if [ "$COCOAPODS_REPO_UPDATE" = "1" ]; then
  run_and_log pod-install pod install --repo-update
else
  run_and_log pod-install pod install
fi

WORKSPACE="$ROOT_DIR/FSNotes.xcworkspace"
if [ ! -d "$WORKSPACE" ]; then
  echo "::error::FSNotes.xcworkspace was not created. CocoaPods likely failed."
  exit 1
fi

# Do not override PRODUCT_BUNDLE_IDENTIFIER here. xcodebuild applies that override
# to every target, including embedded frameworks, which makes iOS reject the IPA
# because multiple bundles get the same CFBundleIdentifier.
COMMON_BUILD_ARGS=(
  -workspace "$WORKSPACE"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -sdk iphoneos
  -destination generic/platform=iOS
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=
  DEVELOPMENT_TEAM=
  PROVISIONING_PROFILE_SPECIFIER=
  CODE_SIGN_ENTITLEMENTS=
  ASSETCATALOG_COMPILER_APPICON_NAME=
  ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS=NO
)

run_and_log build-settings xcodebuild "${COMMON_BUILD_ARGS[@]}" -showBuildSettings

run_and_log xcodebuild xcodebuild \
  "${COMMON_BUILD_ARGS[@]}" \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$XCRESULT_PATH" \
  SYMROOT="$SYMROOT" \
  build

APP_PATH=""
while IFS= read -r candidate; do
  APP_PATH="$candidate"
  break
done < <(find "$SYMROOT" "$DERIVED_DATA/Build/Products" -type d -name 'FSNotes iOS.app' 2>/dev/null | sort)

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
  echo "::error::Built FSNotes iOS.app was not found. Product tree follows:"
  find "$OUTPUT_DIR" -maxdepth 5 -print | sed 's#^#  #' | tee "$LOG_DIR/product-tree.log"
  exit 1
fi

echo "Found app bundle: $APP_PATH" | tee "$LOG_DIR/package.log"

# Change only the application bundle identifier after the build. Embedded frameworks
# keep their own identifiers, so iOS will not see duplicate bundle IDs.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_PATH/Info.plist"
echo "Set app CFBundleIdentifier to $BUNDLE_ID" | tee -a "$LOG_DIR/package.log"

if [ "$STRIP_PLUGINS" = "1" ] && [ -d "$APP_PATH/PlugIns" ]; then
  echo "Removing PlugIns from app bundle" | tee -a "$LOG_DIR/package.log"
  rm -rf "$APP_PATH/PlugIns"
fi

rm -rf "$APP_PATH/_CodeSignature"
find "$APP_PATH" -name '_CodeSignature' -type d -prune -exec rm -rf {} +

rm -rf "$PAYLOAD_DIR"
mkdir -p "$PAYLOAD_DIR"
cp -R "$APP_PATH" "$PAYLOAD_DIR/"

rm -f "$IPA_PATH"
(
  cd "$OUTPUT_DIR"
  /usr/bin/zip -qry "$IPA_PATH" Payload
)

ls -lh "$IPA_PATH" | tee -a "$LOG_DIR/package.log"
echo "Built IPA: $IPA_PATH"
