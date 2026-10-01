#!/bin/sh

set -e; set -o xtrace
configuration="$(cd "$(dirname "$0")" && pwd)"
provider="$PROJECT_DIR/FeedbackReporter"

# A nested build does not inherit command-line build-setting overrides. Keep
# its compilation cache in this checkout too, including when built from Xcode.
compilation_cache="${COMPILATION_CACHE_CAS_PATH:-$PROJECT_DIR/build/CompilationCache.noindex}"
mkdir -p "$compilation_cache"
# -derivedDataPath alone does not constrain the effective OBJROOT. A shared
# nested build database with different parent product roots produces stale-file
# warnings when configurations alternate; override every nested root explicitly.
# Keep all nested intermediate/product roots beneath this configuration's target.
nested_root="$TARGET_TEMP_DIR/FeedbackReporterNested"
mkdir -p "$nested_root"
source_staging="$(mktemp -d "$nested_root/SourceSelection.staging.XXXXXX")"
rmdir "$source_staging"
trap 'rm -rf "$source_staging"' EXIT
python3 "$configuration/prepare.py" "$provider" "$source_staging"
workspace="$nested_root/SourceSelection"
rm -rf "$workspace"
mv "$source_staging" "$workspace"
cd "$workspace"
xcodebuild -derivedDataPath "$nested_root" -scheme "FeedbackReporter" -configuration Release -destination 'generic/platform=macOS' ARCHS="$ARCHS" MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" COMPILATION_CACHE_CAS_PATH="$compilation_cache" CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-YES}" OBJROOT="$nested_root/Build/Intermediates.noindex" SYMROOT="$nested_root/Build/Products" CACHE_ROOT="$nested_root/Cache.noindex" SHARED_PRECOMPS_DIR="$nested_root/Build/PrecompiledHeaders" build

# Replace this managed product rather than merging old compiled resources:
# an older .nib may be a directory while the new compiler emits a file.
case "$BUILT_PRODUCTS_DIR" in
    /|'') echo 'error: FeedbackReporter requires a non-root build products directory' >&2; exit 1 ;;
    /*) ;;
    *) echo 'error: FeedbackReporter build products directory must be absolute' >&2; exit 1 ;;
esac
framework_source="$nested_root/Build/Products/Release/FeedbackReporter.framework"
framework_destination="$BUILT_PRODUCTS_DIR/FeedbackReporter.framework"
framework_staging="$BUILT_PRODUCTS_DIR/.FeedbackReporter.framework.staging"
[ -d "$framework_source" ] || { echo 'error: FeedbackReporter framework was not built' >&2; exit 1; }
[ "$framework_source" != "$framework_destination" ] || { echo 'error: FeedbackReporter source and destination coincide' >&2; exit 1; }
rm -rf "$framework_staging"
cp -R "$framework_source" "$framework_staging"
rm -rf "$framework_destination"
mv "$framework_staging" "$framework_destination"

exit 0
