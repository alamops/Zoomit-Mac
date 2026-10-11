#!/bin/zsh
# Native UI tests require full Xcode and an unlocked, English-language macOS login.
# This wrapper never resets TCC, terminates the installed official app, or substitutes a picker.
set -euo pipefail

UI_ROOT="${0:A:h:h}"
UI_MODE="recording"
UI_DISTRIBUTION="homebrew"
UI_AUTHORIZATION="normal"
while (( $# )); do
    case "$1" in
        --preflight) UI_MODE="preflight"; shift ;;
        --compatibility) UI_MODE="compatibility"; shift ;;
        --distribution)
            (( $# >= 2 )) || { print -u2 "error: --distribution needs homebrew or appstore"; exit 2; }
            UI_DISTRIBUTION="$2"; shift 2 ;;
        --picker-only) UI_AUTHORIZATION="picker-only"; shift ;;
        --help|-h)
            print 'Usage: zsh Scripts/test-recording-ui.sh [--preflight | --compatibility] [--distribution homebrew|appstore] [--picker-only]'
            print 'Default: all required native tests, including recording flows when installed by Wave 3.'
            print '--picker-only verifies native capture without a blanket Screen Recording grant for the dedicated probe.'
            print 'Two-display checks require a second display and fail explicitly when the environment is missing.'
            exit 0 ;;
        *) print -u2 "error: unknown argument $1"; exit 2 ;;
    esac
done
case "$UI_DISTRIBUTION" in
    homebrew) UI_SCHEME="RecordingUI" ;;
    appstore) UI_SCHEME="RecordingUIAppStore" ;;
    *) print -u2 "error: distribution must be homebrew or appstore"; exit 2 ;;
esac
if [[ "$(uname -s)" != "Darwin" ]] || ! xcodebuild -version >/dev/null 2>&1; then
    print -u2 'error: Native recording tests require macOS 14+ and full Xcode. Select it with sudo xcode-select -s /Applications/Xcode.app/Contents/Developer.'
    exit 1
fi
UI_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
(( UI_MAJOR >= 14 )) || { print -u2 'error: macOS 14 or newer is required.'; exit 1; }
UI_CONSOLE_USER="$(stat -f '%Su' /dev/console)"
if [[ "$UI_CONSOLE_USER" != "$(id -un)" || "$UI_CONSOLE_USER" == "root" || "$UI_CONSOLE_USER" == "loginwindow" ]]; then
    print -u2 'error: Run the native UI tests as the logged-in desktop user, with the session unlocked. SSH/headless/root sessions are not supported.'
    exit 1
fi
mkdir -p "$UI_ROOT/.build/recording-ui"
UI_LOCK="$UI_ROOT/.build/recording-ui/run.lock"
if ! mkdir "$UI_LOCK" 2>/dev/null; then
    print -u2 "error: another recording UI run owns $UI_LOCK. Do not run UI tests concurrently. If no run is active, remove this stale lock directory."
    exit 1
fi
UI_RUN_DIR="$(mktemp -d "$UI_ROOT/.build/recording-ui/run-$(date +%Y%m%d-%H%M%S)-XXXXXX")"
UI_DERIVED="$UI_RUN_DIR/DerivedData"
UI_APP_NAME="ZoomIt Recording Tests ${UI_DISTRIBUTION}.app"
UI_APP_PATH="$UI_ROOT/.build/$UI_APP_NAME"
UI_PRODUCTS="$UI_DERIVED/Build/Products/Debug"
UI_TEST_OWNED_EXECUTABLES=(
    "$UI_PRODUCTS/Recording Picker Probe.app/Contents/MacOS/Recording Picker Probe"
    "$UI_PRODUCTS/Recording Fixture A.app/Contents/MacOS/Recording Fixture A"
    "$UI_PRODUCTS/Recording Fixture B.app/Contents/MacOS/Recording Fixture B"
    "$UI_APP_PATH/Contents/MacOS/ZoomIt"
)
function ui_cleanup() {
    # XCTest tears down its launched apps normally. On a runner failure, terminate only
    # processes whose full executable path matches this run's explicitly built test apps.
    local ui_executable ui_pid ui_command
    for ui_executable in "${UI_TEST_OWNED_EXECUTABLES[@]}"; do
        while IFS= read -r ui_pid; do
            [[ -n "$ui_pid" ]] || continue
            ui_command="$(ps -p "$ui_pid" -o comm= 2>/dev/null || true)"
            [[ "$ui_command" == "$ui_executable" ]] && kill "$ui_pid" 2>/dev/null || true
        done < <(pgrep -f "$ui_executable" 2>/dev/null || true)
    done
    rmdir "$UI_LOCK" 2>/dev/null || true
}
trap ui_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
print "Native UI artifacts: $UI_RUN_DIR"
print 'Allow the dedicated test apps/test runner in System Settings > Privacy & Security as requested.'
print 'Missing Screen Recording, Accessibility, or Automation authorization is an error. Grants must be made through system UI; no test bypasses TCC.'
print "distribution=$UI_DISTRIBUTION mode=$UI_MODE authorization=$UI_AUTHORIZATION" > "$UI_RUN_DIR/run-environment.txt"
xcodebuild -version >> "$UI_RUN_DIR/run-environment.txt"
sw_vers >> "$UI_RUN_DIR/run-environment.txt"

# build-app.sh applies ZOOMIT_APP_STORE to the complete SwiftPM package for this variant,
# and seals the appropriate existing entitlements into the dedicated test bundle.
ZOOMIT_DISTRIBUTION="$UI_DISTRIBUTION" \
ZOOMIT_BUNDLE_ID="com.sysinternals.zoomitmac.recordingtests.$UI_DISTRIBUTION" \
ZOOMIT_DISPLAY_NAME="ZoomIt Recording Tests $UI_DISTRIBUTION" \
ZOOMIT_APP_NAME="$UI_APP_NAME" \
ZOOMIT_SIGN_IDENTITY="-" \
zsh "$UI_ROOT/Scripts/build-app.sh" debug > "$UI_RUN_DIR/build-recorder.log" 2>&1 || {
    cat "$UI_RUN_DIR/build-recorder.log" >&2; exit 1
}
UI_INFO="$UI_APP_PATH/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$UI_INFO")" == "com.sysinternals.zoomitmac.recordingtests.$UI_DISTRIBUTION" ]] || {
    print -u2 'error: recorder test identity mismatch; refusing to launch.'; exit 1
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ZoomItDistribution' "$UI_INFO")" == "$UI_DISTRIBUTION" ]] || {
    print -u2 'error: recorder distribution mismatch; refusing to launch.'; exit 1
}
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$UI_APP_PATH"
UI_SELECTION=()
case "$UI_MODE" in
    preflight)
        UI_SELECTION=(-only-testing:RecordingUITests/HarnessSmokeTests/testPreflight -only-testing:RecordingUITests/PickerCompatibilityTests/testRealPickerCancellationAndRetry) ;;
    compatibility)
        UI_SELECTION=(-only-testing:RecordingUITests/HarnessSmokeTests -only-testing:RecordingUITests/PickerCompatibilityTests) ;;
esac
# Scheme variables expand these build settings into the XCTest runner's environment.
# Running serially avoids global picker/hotkey interference between test processes.
if ! xcodebuild test \
    -project "$UI_ROOT/Tests/RecordingUI/RecordingUI.xcodeproj" \
    -scheme "$UI_SCHEME" -destination 'platform=macOS' \
    -parallel-testing-enabled NO -maximum-concurrent-test-macos-destinations 1 \
    -derivedDataPath "$UI_DERIVED" \
    -resultBundlePath "$UI_RUN_DIR/RecordingUI.xcresult" \
    "ZOOMIT_UI_APP_PATH=$UI_APP_PATH" \
    "ZOOMIT_UI_ARTIFACTS=$UI_RUN_DIR" \
    "ZOOMIT_PICKER_AUTHORIZATION=$UI_AUTHORIZATION" \
    "${UI_SELECTION[@]}" 2>&1 | tee "$UI_RUN_DIR/xcodebuild.log"; then
    print -u2 "error: native UI checks failed; inspect $UI_RUN_DIR/RecordingUI.xcresult, xcodebuild.log and probe-evidence.json."
    print -u2 'If authorization failed, grant the dedicated bundle and Xcode runner Screen Recording/Accessibility/Automation permission through System Settings, unlock the desktop, and rerun. A missing second display is an unverified required environment, not a passing check.'
    exit 1
fi
print "Native UI checks passed for $UI_DISTRIBUTION; retained evidence: $UI_RUN_DIR"
