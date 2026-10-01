#!/bin/sh

set -e; set -o xtrace

cmake_dir="$TARGET_TEMP_DIR/CMake"
install_dir="$TARGET_TEMP_DIR/Install"
source_prefix="$TARGET_TEMP_DIR/Source"
source_dir="$source_prefix/source"
freetype_adapter="$(cd "$(dirname "$0")" && pwd)/adapt-freetype.py"

if [ -d "$install_dir" ] && [ -f "$install_dir/wlib/lib$PRODUCT_NAME.a" ] && [ ! -f "$install_dir/.incomplete" ] && \
    python3 "$freetype_adapter" --verify-install "$install_dir"; then
    exit 0
fi

mkdir -p "$install_dir"
touch "$install_dir/.incomplete"

cd "$cmake_dir"
# A nested make inside a CMake install script cannot inherit closed jobserver
# descriptors from the parent build. Run installation as its own CMake step.
env -u MAKEFLAGS -u MFLAGS make -j "$(sysctl -n hw.ncpu)"
env -u MAKEFLAGS -u MFLAGS cmake --install "$cmake_dir"

# Adapt the installed module before aggregation, so CMake SDK consumers and the
# host resolve the same public symbol. Keep arithmetic in the original source;
# the original raw name becomes local rather than colliding with other vendors.
# The host link retains the prefixed entry point for plugins even when no
# built-in call reaches it, without exporting the raw implementation name.
python3 "$freetype_adapter" "$install_dir" \
    "$source_dir/ThirdParty/freetype/vtkfreetype"

# Copy only the selected acquisition identity and original terms, not private
# build paths. Host transforms are recorded independently of pristine source.
mkdir -p "$install_dir/share/licenses/VTK"
cp "$source_prefix/share/source.json" "$install_dir/share/source.json"
cp "$source_dir/Copyright.txt" "$install_dir/share/licenses/VTK/Copyright.txt"

# Preserve upstream's versioned headers: its installed CMake targets and file
# sets reference that directory. Root aliases retain the host/plugin include
# paths and are relative, so a copied installation remains usable.
versioned_headers=""
for versioned in "$install_dir"/include/vtk-*; do
    [ -d "$versioned" ] || continue
    [ -z "$versioned_headers" ] || { echo >&2 "error: multiple VTK header versions installed"; exit 1; }
    versioned_headers="$versioned"
done
[ -n "$versioned_headers" ] || { echo >&2 "error: no versioned VTK headers installed"; exit 1; }

# The unmodified external TIFF wrapper includes <tiffio.h>. Stage the exact
# pinned headers beside it for both versioned and compatibility include paths.
# Retain the old vtktiff/libtiff path as relative aliases for existing callers.
mkdir -p "$versioned_headers/vtktiff/libtiff"
for header in tiff.h tiffconf.h tiffio.h tiffvers.h; do
    cp -Lf "$CONFIGURATION_TEMP_DIR/ExternalInputs.build/Install/include/$header" "$versioned_headers/$header"
    ln -sfn "../../$header" "$versioned_headers/vtktiff/libtiff/$header"
done
for entry in "$versioned_headers"/*; do
    alias="$install_dir/include/$(basename "$entry")"
    if [ -e "$alias" ] && [ ! -L "$alias" ]; then
        echo >&2 "error: refusing to replace unmanaged VTK include: $alias"
        exit 1
    fi
    ln -sfn "$(basename "$versioned_headers")/$(basename "$entry")" "$alias"
done

# wrap the libs into one
mkdir -p "$install_dir/wlib"
ars=$(find "$install_dir/lib" -name '*.a' -type f | tr '\n' ' ')
libtool -static -o "$install_dir/wlib/lib$PRODUCT_NAME.a" $ars
python3 "$freetype_adapter" --complete "$install_dir"

rm -f "$install_dir/.incomplete"

exit 0
