#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
case "$MODE" in run|--debug|--logs|--telemetry|--verify|--diagnostics) ;; *) echo "usage: $0 [--debug|--logs|--telemetry|--verify|--diagnostics]" >&2; exit 2;; esac
DEV_CONFIGURATION="${HOROS_DEV_CONFIGURATION:-Debug}"
case "$DEV_CONFIGURATION" in Debug|Release) ;; *) echo "HOROS_DEV_CONFIGURATION must be Debug or Release" >&2; exit 2;; esac
unset HOROS_DEV_CONFIGURATION
DEV_WORKSPACE="${HOROS_DEV_WORKSPACE:-}"
unset HOROS_DEV_WORKSPACE
XCODE_CONTAINER=(-project "$ROOT_DIR/Horos.xcodeproj")
PACKAGE_OPTIONS=(-clonedSourcePackagesDirPath "$ROOT_DIR/build/SourcePackages" -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile)
if [[ -n "$DEV_WORKSPACE" ]]; then
  [[ "$DEV_WORKSPACE" = /* ]] || DEV_WORKSPACE="$ROOT_DIR/$DEV_WORKSPACE"
  if [[ ! -d "$DEV_WORKSPACE" || "$DEV_WORKSPACE" != "$ROOT_DIR/"*.xcworkspace ]] || ! git -C "$ROOT_DIR" check-ignore -q "$DEV_WORKSPACE"; then
    echo "HOROS_DEV_WORKSPACE must name an ignored .xcworkspace inside this checkout." >&2
    exit 2
  fi
  XCODE_CONTAINER=(-workspace "$DEV_WORKSPACE")
  PACKAGE_OPTIONS=(-clonedSourcePackagesDirPath "$ROOT_DIR/build/DevelopmentSourcePackages")
  echo "Local development workspace selected; its package overrides are not public release inputs."
fi
cd "$ROOT_DIR"
DEV_APP="$ROOT_DIR/build/Development/HorosDevelopment.app"
DEV_ID="org.horosproject.horos.local-development"
# A disposable internal-volume directory can avoid removable-volume consent
# during isolated tests when the checkout itself lives on an external disk.
TEST_ROOT="${HOROS_DEV_TEST_ROOT:-$ROOT_DIR/local-validation/runtime-private}"
# This launch-only option must not invalidate dependency build environment hashes.
unset HOROS_DEV_TEST_ROOT
mkdir -p "$ROOT_DIR/build/logs" "$ROOT_DIR/build/Development" "$TEST_ROOT"
# Quit only the development bundle of this checkout, preserving any installed
# Horos/OsiriX session and the development instance of another worktree.
python3 "$ROOT_DIR/script/development_process.py" quit "$DEV_APP/Contents/MacOS/Horos"
BUILD_LOG="$ROOT_DIR/build/logs/build-and-run.log"
echo "Building Horos ($DEV_CONFIGURATION). Log: $BUILD_LOG"
# Explicit products and cache locations also work with global Xcode locations
# pointing at an unavailable external volume.
if xcodebuild "${XCODE_CONTAINER[@]}" "${PACKAGE_OPTIONS[@]}" -scheme Horos -configuration "$DEV_CONFIGURATION" -destination 'generic/platform=macOS' -derivedDataPath build SYMROOT="$ROOT_DIR/build/Build/Products" COMPILATION_CACHE_CAS_PATH="$ROOT_DIR/build/CompilationCache.noindex" CODE_SIGNING_ALLOWED=NO > "$BUILD_LOG" 2>&1; then
    echo "Build succeeded. Preparing $DEV_APP"
else
    build_status=$?
    tail -n 60 "$BUILD_LOG" >&2
    echo "Build failed (exit $build_status). Full log: $BUILD_LOG" >&2
    exit "$build_status"
fi
# With SYMROOT given, this Xcode puts the intermediates in build/Intermediates.noindex,
# beside Build/, while the tests and tools look for objects, the generated
# Horos-Swift.h and the dependency installs under build/Build/Intermediates.noindex.
# Link the second to the first, so that they find what was just built.
if [ -d "$ROOT_DIR/build/Intermediates.noindex" ] && [ ! -e "$ROOT_DIR/build/Build/Intermediates.noindex" ]; then
    ln -s ../Intermediates.noindex "$ROOT_DIR/build/Build/Intermediates.noindex"
fi
rm -rf "$DEV_APP"
/usr/bin/ditto "$ROOT_DIR/build/Build/Products/$DEV_CONFIGURATION/Horos.app" "$DEV_APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DEV_ID" "$DEV_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Horos Development' "$DEV_APP/Contents/Info.plist"
# Finder loads the Quick Look extensions from this bundle. Their identifiers
# must stay prefixed with the development identifier after the rewrite above.
if [ -d "$DEV_APP/Contents/PlugIns" ]; then
    for plist in "$DEV_APP/Contents/PlugIns"/*/Contents/Info.plist; do
        [ -f "$plist" ] || continue
        old="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
        case "$old" in
            org.horosproject.horos.*)
                /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${DEV_ID}.${old#org.horosproject.horos.}" "$plist"
                ;;
        esac
    done
fi
# Exercise the app's hardened-runtime permissions after signing nested code.
# Ad-hoc development also loads the external libraries that
# Horos/Scripts/external-inputs.sh staged and signed ad hoc in the build directory.
# Keep this local exception out of the distribution entitlements.
DEV_ENTITLEMENTS="$ROOT_DIR/build/Development/entitlements.plist"
python3 - "$ROOT_DIR/Horos/Horos.entitlements" "$DEV_ENTITLEMENTS" "$MODE" <<'PYTHON'
import plistlib,sys
with open(sys.argv[1], 'rb') as source:
    entitlements = plistlib.load(source)
entitlements['com.apple.security.cs.disable-library-validation'] = True
# Hardened runtime otherwise rejects LLDB even when LLDB launches the app.
# Enable task access only for the explicitly requested local debugging mode.
if sys.argv[3] == '--debug':
    entitlements['com.apple.security.get-task-allow'] = True
# Hardened runtime otherwise strips DYLD_INSERT_LIBRARIES, so the runtime
# checkers cannot be injected. Only the explicit diagnostics mode allows it.
if sys.argv[3] == '--diagnostics':
    entitlements['com.apple.security.cs.allow-dyld-environment-variables'] = True
with open(sys.argv[2], 'wb') as destination:
    plistlib.dump(entitlements, destination)
PYTHON
# Local ad-hoc signing accommodates the development bundle identifier change.
# --deep signs nested bundles and frameworks; a bare executable copied into
# Resources is data to it, so those are signed first, inside out.
#
# The helpers in Resources are separate processes, and the hardened runtime
# implies library validation: signed without these entitlements they refuse to
# load the ad-hoc frameworks beside them and exit before running. Decompress is
# one of them, so every archive and every transcoding silently did nothing and
# the file was left in the decompression folder. Sign them with the same
# exception as the application.
[ -d "$DEV_APP/Contents/Resources" ] || { echo "Development bundle has no Resources: $DEV_APP" >&2; exit 1; }
/usr/bin/find "$DEV_APP/Contents/Resources" -type f -perm -u+x -exec /bin/sh -c '
    entitlements=$1; shift
    for file do
        case "$(/usr/bin/file -b "$file")" in
            *Mach-O*) /usr/bin/codesign --force --sign - --options runtime --entitlements "$entitlements" "$file" || exit 1 ;;
        esac
    done
' _ "$DEV_ENTITLEMENTS" {} + > "$ROOT_DIR/build/logs/development-signing.log" 2>&1
/usr/bin/codesign --force --deep --sign - "$DEV_APP" >> "$ROOT_DIR/build/logs/development-signing.log" 2>&1
/usr/bin/codesign --force --sign - --options runtime --entitlements "$DEV_ENTITLEMENTS" "$DEV_APP" >> "$ROOT_DIR/build/logs/development-signing.log" 2>&1
# The Web Portal keeps its accounts outside the DICOM database, so an isolated
# run still read and wrote the installed application's accounts until this path
# was passed too.
# Development is interactive even when the isolated preferences enable server mode.
# The host respects this argument without copying it into persistent preferences.
# The development bundle runs from build/Development and must never offer to move
# itself: in Release the LetsMove prompt is a modal that holds every XML-RPC open.
# The plugins come from a folder of the test root, not from the user's or the
# computer's plugins folders; --LoadPlugin <bundle> still loads a given one.
ARGS=(-hideListenerError NO -moveToApplicationsFolderAlertSuppress YES -DATABASELOCATION 1 -DATABASELOCATIONURL "$TEST_ROOT" -DEFAULT_DATABASELOCATION 1 -DEFAULT_DATABASELOCATIONURL "$TEST_ROOT" -WebPortalDatabasePath "$TEST_ROOT/WebUsers.sql" -AUTOCLEANINGSPACE NO -AUTOCLEANINGDATE NO -AUTOROUTINGACTIVATED NO -STORESCP NO -USESTORESCP NO -checkForUpdatesPlugins NO -SUEnableAutomaticChecks NO -IsolatedPluginsFolder "$TEST_ROOT/Isolated Plugins")
# Do not inherit a shell TMPDIR that may point at a removable volume. Keep
# development runtime files in the user's macOS temporary directory, without
# changing the build environment or the user's global configuration.
DEV_TMPDIR="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)"
if [[ ! -d "$DEV_TMPDIR" || ! -w "$DEV_TMPDIR" ]]; then
  echo "macOS temporary directory is unavailable: $DEV_TMPDIR" >&2
  exit 1
fi
if [[ "$MODE" == --debug ]]; then
  export TMPDIR="$DEV_TMPDIR"
  exec /usr/bin/lldb -- "$DEV_APP/Contents/MacOS/Horos" "${ARGS[@]}"
fi
if [[ "$MODE" == --diagnostics ]]; then
  # Run in the foreground with Xcode's Main Thread Checker inserted, so AppKit
  # calls made off the main thread are reported as they happen. The report goes
  # to stderr; redirect it to keep a transcript.
  CHECKER="$(xcode-select -p)/usr/lib/libMainThreadChecker.dylib"
  if [[ ! -f "$CHECKER" ]]; then
    echo "Main Thread Checker is not available at $CHECKER" >&2
    exit 1
  fi
  export TMPDIR="$DEV_TMPDIR"
  export DYLD_INSERT_LIBRARIES="$CHECKER"
  export MTC_RESET_INSERT_LIBRARIES=0
  exec "$DEV_APP/Contents/MacOS/Horos" "${ARGS[@]}"
fi
/usr/bin/open -n "$DEV_APP" --env "TMPDIR=$DEV_TMPDIR" --args "${ARGS[@]}"
case "$MODE" in
 --verify)
  sleep 3
  python3 "$ROOT_DIR/script/development_process.py" list "$DEV_APP/Contents/MacOS/Horos"
  ;;
 --logs|--telemetry)
  exec /usr/bin/log stream --info --style compact --predicate 'process == "Horos"'
  ;;
esac
