#!/bin/sh

# The frameworks a plugin made for Horos or OsiriX names in its load commands.
#
# The application's executable defines and exports the classes, functions and
# constants of the former plugin API; a plugin built with -undefined
# dynamic_lookup finds them there. Its load commands also name the framework of
# the SDK it was built with, and dyld refuses a plugin whose framework is
# missing. Horos.framework was that SDK, and plugins were linked over the years
# against the names it had: HorosAPI, OsiriXAPI, OsiriX Headers and HorosDCM.
# Each of the five carries only version numbers (API/HorosAPI.c) and keeps the
# install name of Horos.framework, as the copies the former SDK target made did.
#
# The App Store version loads no plugins and carries none of them.

set -eu

frameworks="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
names="Horos HorosAPI OsiriXAPI OsiriX_Headers HorosDCM"
# "OsiriX Headers" has a space: it is written OsiriX_Headers in the list above.
framework_name() { [ "$1" = OsiriX_Headers ] && echo "OsiriX Headers" || echo "$1"; }

if [ "${ISIS_BUILD_CHANNEL:-github}" = "appstore" ]; then
    for name in $names; do
        rm -Rf "$frameworks/$(framework_name "$name").framework"
    done
    exit 0
fi

# codesign is given the identity Xcode resolved for this build, or ad hoc when
# there is none. EXPANDED_CODE_SIGN_IDENTITY is the identity itself; the _NAME
# beside it is the display name, which codesign cannot look up.
identity="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
[ -n "$identity" ] || identity="-"
signing_allowed="${CODE_SIGNING_ALLOWED:-YES}"

work="$DERIVED_FILE_DIR/FormerPluginFrameworks"
rm -Rf "$work"
mkdir -p "$work" "$frameworks"
arch_flags=""
for arch in $ARCHS; do arch_flags="$arch_flags -arch $arch"; done
# shellcheck disable=SC2086
xcrun clang -dynamiclib $arch_flags -isysroot "$SDKROOT" -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
    -fvisibility=default -install_name "@executable_path/../Frameworks/Horos.framework/Versions/A/Horos" \
    -compatibility_version 1.0.0 -current_version 1.0.0 \
    "$SRCROOT/API/HorosAPI.c" -o "$work/binary"

for name in $names; do
    framework="$(framework_name "$name")"
    path="$frameworks/$framework.framework"
    rm -Rf "$path"
    mkdir -p "$path/Versions/A/Resources"
    cp "$work/binary" "$path/Versions/A/$framework"
    # The identifiers the former SDK target gave them; the space is left out.
    if [ "$name" = Horos ]; then suffix=api; else suffix="$(echo "$name" | tr -d _)"; fi
    cat > "$path/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>English</string>
	<key>CFBundleExecutable</key>
	<string>$framework</string>
	<key>CFBundleIdentifier</key>
	<string>${PRODUCT_BUNDLE_IDENTIFIER}.$suffix</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
</dict>
</plist>
PLIST
    ln -s A "$path/Versions/Current"
    ln -s "Versions/Current/$framework" "$path/$framework"
    ln -s Versions/Current/Resources "$path/Resources"
    if [ "$signing_allowed" != "NO" ]; then
        /usr/bin/codesign --force --sign "$identity" --options runtime "$path"
    fi
done

exit 0
