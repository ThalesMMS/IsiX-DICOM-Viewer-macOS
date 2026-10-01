#!/bin/sh

export PATH="$PATH:/opt/local/bin:/opt/local/sbin:/opt/homebrew/bin/"

path="$( cd "$(dirname "${BASH_SOURCE[0]}")" && pwd )/$(basename "${BASH_SOURCE[0]}")"
external_inputs="$(dirname "$path")/../external-inputs.sh"
external_inputs_lock="$(dirname "$path")/../external-inputs.lock"
make_script="$(dirname "$path")/Make.sh"
set -e
# ITK is the official release archive declared in external-sources.json,
# extracted read-only for this configuration and compiled as it is.
source_prefix="$TARGET_TEMP_DIR/Source"
source_dir="$(sh "$external_inputs" --source ITK "$source_prefix" \
    "${EXTERNAL_SOURCES_DOWNLOADS:-$PROJECT_TEMP_DIR/ExternalSources.downloads}")"

# One narrow hash for every dependency; see Horos/Scripts/dependency-hash.sh.
# The verified source is resolved before a configure hit is considered, and
# only its own selected record is hashed.
. "$(dirname "$path")/../dependency-hash.sh"
dependency_hash "$path" "$make_script" "$external_inputs" "$external_inputs_lock" "$source_prefix/share/source.json" "$source_dir/CMake/itkVersion.cmake" \
    "$source_dir/CMakeLists.txt"

set -e; set -o xtrace

# Shared app inputs come from external-inputs.lock, staged in this build.
# Resolve them before checking the stamp so consumers always find them.
# The selected ITK modules use system zlib and none of the staged codecs.
external_prefix="$CONFIGURATION_TEMP_DIR/ExternalInputs.build/Install"
sh "$external_inputs" "$external_prefix" "$PROJECT_TEMP_DIR/ExternalInputs.downloads"

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
mkdir -p "$cmake_dir"; cd "$cmake_dir"

args=("$source_dir")
cxxfs=( -fvisibility=default )
lfs=() # linker flags
args+=(-DITK_USE_64BITS_IDS=ON)
args+=(-DBUILD_DOCUMENTATION=OFF)
args+=(-DBUILD_EXAMPLES=OFF)
args+=(-DBUILD_SHARED_LIBS=OFF)
args+=(-DBUILD_TESTING=OFF)
args+=(-DCMAKE_POLICY_VERSION_MINIMUM=3.5)
args+=(-DITK_USE_SYSTEM_ZLIB=ON)
args+=(-DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET")
args+=(-DCMAKE_OSX_ARCHITECTURES="$ARCHS")

# Core defaults to ON independently of ITK_BUILD_DEFAULT_MODULES and pulls
# TestKernel plus image/mesh readers and codecs the app does not consume.
# Build only the explicit roots below and their transitive dependencies.
args+=(-DITK_BUILD_DEFAULT_MODULES=OFF)
args+=(-DITKGroup_Core=OFF)
args+=(-DModule_ITKIOImageBase=ON)
args+=(-DModule_ITKStatistics=ON)
args+=(-DModule_ITKTransform=ON)
args+=(-DModule_ITKVTK=ON)
args+=(-DModule_ITKNrrdIO=ON)
args+=(-DModule_ITKRegionGrowing=ON)
args+=(-DModule_ITKCurvatureFlow=ON)
args+=(-DModule_ITKLevelSets=ON)
# Headers the app includes directly (ITKBrushROIFilter.mm, ITKTransform.mm,
# ITKSegmentation3D.mm). The modules above already pull them in; naming them
# keeps them when an ITK release changes its module dependencies.
args+=(-DModule_ITKBinaryMathematicalMorphology=ON)
args+=(-DModule_ITKMathematicalMorphology=ON)
args+=(-DModule_ITKImageGrid=ON)
args+=(-DModule_ITKMesh=ON)

args+=(-DCMAKE_INSTALL_PREFIX="$install_dir")
args+=(-DITK_INSTALL_INCLUDE_DIR="include")

args+=(-DCMAKE_IGNORE_PATH="/opt/local/include;/opt/local/lib")
# Nothing is looked up in a package manager's prefix, including the one CMake
# itself was installed from; pkg-config sees no .pc file at all.
args+=(-DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/opt/local;/usr/local")
export PKG_CONFIG_LIBDIR="$external_prefix/lib/pkgconfig"

cfs+=( -I"$external_prefix/include" )
cxxfs+=( -I"$external_prefix/include" )

if [ ! -z "$CLANG_CXX_LIBRARY" ] && [ "$CLANG_CXX_LIBRARY" != 'compiler-default' ]; then
#    args+=(-DCMAKE_XCODE_ATTRIBUTE_CLANG_CXX_LIBRARY="$CLANG_CXX_LIBRARY")
    cxxfs+=(-stdlib="$CLANG_CXX_LIBRARY")
fi
if [ ! -z "$CLANG_CXX_LANGUAGE_STANDARD" ]; then
#    args+=(-DCMAKE_XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD="$CLANG_CXX_LANGUAGE_STANDARD")
    cxxfs+=(-std="$CLANG_CXX_LANGUAGE_STANDARD")
fi

if [ ${#cxxfs[@]} -ne 0 ]; then
    cxxfss="${cxxfs[@]}"
    args+=(-DCMAKE_CXX_FLAGS="$cxxfss")
fi

if [ ${#lfs[@]} -ne 0 ]; then
    lfss="${lfs[@]}"
    args+=(-DCMAKE_EXE_LINKER_FLAGS="$lfss")
fi

#args+=(-DCMAKE_VERBOSE_MAKEFILE:BOOL=ON)

cmake "${args[@]}"

echo "$hash" > "$cmake_dir/.cmakehash"
echo "$env" > "$cmake_dir/.cmakeenv"

exit 0
