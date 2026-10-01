#!/bin/sh

cd "$SRCROOT/Binaries"
unzip -uo DB_Previous_Models.zip
unzip -uo PAGES.zip
unzip -uo OsiriXReport.template.zip
/usr/bin/python3 "$SRCROOT/Horos/Scripts/Horos/stage-dciodvfy.py" || exit $?

unzip -uo weasis-portable*.zip -d weasis
chmod -R 755 weasis
find "$SRCROOT/Binaries/weasis" -name __MACOSX | xargs rm -Rf
# remove empty macOS app that prevents notarization
rm -Rf "$SRCROOT/Binaries/weasis/viewer-mac.app"

cd "$SRCROOT/Binaries/PAGES"
rm ._*

exit 0
