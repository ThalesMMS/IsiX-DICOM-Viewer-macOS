#!/bin/sh

export PATH="$PATH:/opt/local/bin:/opt/local/sbin:/opt/homebrew/bin/"

path="$( cd "$(dirname "${BASH_SOURCE[0]}")" && pwd )/$(basename "${BASH_SOURCE[0]}")"
set -e
external_inputs="$(dirname "$path")/../external-inputs.sh"
source_prefix="$TARGET_TEMP_DIR/Source"
source_dir="$(sh "$external_inputs" --source OpenJPEG "$source_prefix" \
    "${EXTERNAL_SOURCES_DOWNLOADS:-$PROJECT_TEMP_DIR/ExternalSources.downloads}")"

# One narrow hash for every dependency; see Horos/Scripts/dependency-hash.sh.
# The selected record carries the archive identity, even at the same version.
# Resolve and validate the pristine tree before considering a configure hit.
. "$(dirname "$path")/../dependency-hash.sh"
dependency_cross_cache "$path"
dependency_hash "$path" "$(dirname "$path")/Make.sh" "$external_inputs" "$source_prefix/share/source.json" "$source_dir/CMakeLists.txt" ${cross_cache:+"$cross_cache"}

set -e; set -o xtrace

cmake_dir="$TARGET_TEMP_DIR/CMake"
install_dir="$TARGET_TEMP_DIR/Install"

mkdir -p "$cmake_dir"; cd "$cmake_dir"
if [ -e Makefile -a -f .cmakehash ] && [ "$(cat '.cmakehash')" = "$hash" ]; then
    exit 0
fi

if [ -e ".cmakeenv" ]; then
    echo "Rebuilding.."
    cat '.cmakeenv'
    echo "$env"
fi

command -v cmake >/dev/null 2>&1 || { echo >&2 "error: building $TARGET_NAME requires CMake. Please install CMake. Aborting."; exit 1; }
command -v pkg-config >/dev/null 2>&1 || { echo >&2 "error: building $TARGET_NAME requires pkg-config. Please install pkg-config. Aborting."; exit 1; }

mv "$cmake_dir" "$cmake_dir.tmp"
[ -d "$install_dir" ] && mv "$install_dir" "$install_dir.tmp"
rm -Rf "$cmake_dir.tmp" "$install_dir.tmp"
mkdir -p "$cmake_dir"

export CC=clang
export CXX=clang

args=("$source_dir")
# An x86_64 slice built on Apple Silicon: a cross configure; see dependency-hash.sh.
if [ -n "$cross_cache" ]; then args+=(-C "$cross_cache"); fi
cfs=($OTHER_CFLAGS)
cxxfs=($OTHER_CPLUSPLUSFLAGS)

args+=(-DCMAKE_POLICY_VERSION_MINIMUM=3.5)
# OpenJPEG's decoder is C; CXX flags alone leave even Release unoptimized.
args+=(-DCMAKE_BUILD_TYPE="$CONFIGURATION")
args+=(-DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET")
args+=(-DCMAKE_OSX_ARCHITECTURES="$ARCHS")

args+=(-DCMAKE_INSTALL_PREFIX="$TARGET_TEMP_DIR/Install")
args+=(-DCMAKE_INSTALL_INCLUDEDIR="include")
args+=(-DCMAKE_INSTALL_LIBDIR="lib")

args+=(-DBUILD_DOC=OFF)
args+=(-DBUILD_SHARED_LIBS=OFF)
args+=(-DBUILD_STATIC_LIBS=ON)
args+=(-DBUILD_TESTING=OFF)
args+=(-DBUILD_CODEC=OFF)
args+=(-DBUILD_THIRDPARTY=OFF)

# Only the library is built: with BUILD_CODEC=OFF the thirdparty/ directory,
# the one place that looks for TIFF, PNG, LCMS or zlib, is never read, so no
# Homebrew path is passed.
args+=(-DCMAKE_IGNORE_PATH="/opt/local/include;/opt/local/lib")

if [ ! -z "$CLANG_CXX_LIBRARY" ] && [ "$CLANG_CXX_LIBRARY" != 'compiler-default' ]; then
    cxxfs+=(-stdlib="$CLANG_CXX_LIBRARY")
fi

if [ ! -z "$CLANG_CXX_LANGUAGE_STANDARD" ]; then
    cxxfs+=(-std="$CLANG_CXX_LANGUAGE_STANDARD")
fi

if [ ${#cfs[@]} -ne 0 ]; then
    cfss="${cfs[@]}"
    args+=(-DCMAKE_C_FLAGS="$cfss")
fi
if [ ${#cxxfs[@]} -ne 0 ]; then
    cxxfss="${cxxfs[@]}"
    args+=(-DCMAKE_CXX_FLAGS="$cxxfss")
fi

cd "$cmake_dir"
cmake "${args[@]}"

echo "$hash" > "$cmake_dir/.cmakehash"
echo "$env" > "$cmake_dir/.cmakeenv"

exit 0
