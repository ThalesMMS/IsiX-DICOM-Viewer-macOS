#!/bin/sh

set -e; set -o xtrace

cmake_dir="$TARGET_TEMP_DIR/CMake"
install_dir="$TARGET_TEMP_DIR/Install"
# The original source that CMake.sh resolved and configured.
source_prefix="$TARGET_TEMP_DIR/Source"
source_dir="$source_prefix/source"
copy_dir="$BUILT_PRODUCTS_DIR/DCMTK"

[ -d "${copy_dir}" ] && [ ! -f "${copy_dir}/.incomplete" ] && exit 0

mkdir -p "$install_dir"
mkdir -p "${copy_dir}"
touch "${copy_dir}/.incomplete"

args=()
export MAKEFLAGS="-j $(sysctl -n hw.ncpu)"

echo "${cmake_dir}"
cd "$cmake_dir"
make "${args[@]}" install

# CMake preserves source timestamps when installing headers. A new pin can
# contain older files; make Xcode invalidate objects and prefix headers then.
find "$install_dir/include" -type f -exec touch {} +

# Keep the stock JPEG-LS codec ABI private to its adapter so plugins cannot
# interpose a codec with a different parameter layout.
python3 "$PROJECT_DIR/tools/isolate-dcmtk-jpegls.py" "$install_dir/lib" \
    --architecture "$ARCHS" --deployment "$MACOSX_DEPLOYMENT_TARGET"

# Copy subset of applications to build directory
#
cp "${install_dir}/bin/dcmdump" "${copy_dir}"
cp "${install_dir}/bin/dcmpsprt" "${copy_dir}"
bash "$PROJECT_DIR/Horos/Scripts/DCMTK/BuildStoredPrint.sh" "$install_dir" \
    "$CONFIGURATION_TEMP_DIR/OpenSSL.build/Install" "$TARGET_TEMP_DIR/StoredPrint" \
    "$copy_dir/HorosStoredPrint" "$ARCHS" "$MACOSX_DEPLOYMENT_TARGET" "$CONFIGURATION"
# Do not keep a previously copied print client after refreshing this product.
rm -f "$copy_dir/dcmprscu"
cp "${install_dir}/bin/dsr2html" "${copy_dir}"
cp "${install_dir}/bin/echoscu" "${copy_dir}"
# A built-in dictionary is used by the library; the external dictionary is
# also bundled for the application's existing dictionary consumers.
# The source is extracted read-only; the copy stays writable so the next
# refresh can replace it.
install -m 0644 "$source_dir/dcmdata/data/dicom.dic" "${copy_dir}/dicom.dic"

# Install the identity of the compiled source with its license and the notices
# of the code it carries (CharLS, IJG), for the bundle and the release record.
licenses_dir="$install_dir/share/licenses/DCMTK"
rm -rf "$licenses_dir"
mkdir -p "$licenses_dir"
cp "$source_prefix/share/source.json" "$install_dir/share/source.json"
cp "$source_dir/COPYRIGHT" "$licenses_dir/COPYRIGHT"
cp "$source_dir/dcmjpls/docs/License.txt" "$licenses_dir/CharLS-License.txt"
cp "$source_dir/dcmjpeg/docs/ijg_readme.txt" "$licenses_dir/ijg_readme.txt"

rm -f "$copy_dir/.incomplete"

exit 0
