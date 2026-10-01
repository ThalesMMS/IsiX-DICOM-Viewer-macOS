#!/bin/sh

set -e; set -o xtrace

cmake_dir="$TARGET_TEMP_DIR/CMake"
install_dir="$TARGET_TEMP_DIR/Install"

[ -d "$install_dir" ] && [ ! -f "$install_dir/.incomplete" ] && exit 0

mkdir -p "$install_dir"
touch "$install_dir/.incomplete"

cd "$cmake_dir"
# Install scripts can invoke another make through CMake execute_process,
# which does not preserve GNU make's jobserver descriptors. Build in parallel
# first, then install outside make without inherited jobserver state.
env -u MAKEFLAGS -u MFLAGS make -j "$(sysctl -n hw.ncpu)"
env -u MAKEFLAGS -u MFLAGS cmake --install "$cmake_dir"

# wrap the libs into one
mkdir -p "$install_dir/wlib"
ars=$(find "$install_dir/lib" -name '*.a' -type f)
libtool -static -o "$install_dir/wlib/lib$PRODUCT_NAME.a" $ars

# The identity of the source that was compiled and its original terms travel
# with the installation, without private build paths.
source_prefix="$TARGET_TEMP_DIR/Source"
mkdir -p "$install_dir/share/licenses/ITK"
cp "$source_prefix/share/source.json" "$install_dir/share/source.json"
cp "$source_prefix/source/LICENSE" "$source_prefix/source/NOTICE" "$install_dir/share/licenses/ITK/"

rm -f "$install_dir/.incomplete"

exit 0

#xcodebuild -project "$cmake_dir/$TARGET_NAME.xcodeproj" \
#-target ITKIOImageBase -target ITKStatistics -target ITKTransform \
#-target ITKVTK -target ITKNrrdIO \
#-configuration "$CONFIGURATION"
