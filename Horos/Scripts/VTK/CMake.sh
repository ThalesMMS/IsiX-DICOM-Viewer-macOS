#!/bin/sh

export PATH="$PATH:/opt/local/bin:/opt/local/sbin:/opt/homebrew/bin/"

path="$( cd "$(dirname "${BASH_SOURCE[0]}")" && pwd )/$(basename "${BASH_SOURCE[0]}")"
external_inputs="$(dirname "$path")/../external-inputs.sh"
external_inputs_lock="$(dirname "$path")/../external-inputs.lock"
host_build="$(dirname "$path")/HostBuild.cmake"
make_script="$(dirname "$path")/Make.sh"
freetype_adapter="$(dirname "$path")/adapt-freetype.py"
freetype_pin="$(dirname "$path")/freetype-source.json"
set -e
source_prefix="$TARGET_TEMP_DIR/Source"
source_dir="$(sh "$external_inputs" --source VTK "$source_prefix" \
    "${EXTERNAL_SOURCES_DOWNLOADS:-$PROJECT_TEMP_DIR/ExternalSources.downloads}")"
python3 "$freetype_adapter" --verify-source "$source_dir/ThirdParty/freetype/vtkfreetype"

# One narrow hash for every dependency; see Horos/Scripts/dependency-hash.sh.
# Resolve the verified original source before considering a configure hit.
# Only this source's selected record is hashed, so an unrelated dependency's
# declaration or an app source edit cannot silently change its installed ABI.
. "$(dirname "$path")/../dependency-hash.sh"
dependency_hash "$path" "$host_build" "$make_script" "$freetype_adapter" "$freetype_pin" "$external_inputs" "$external_inputs_lock" "$source_prefix/share/source.json" "$source_dir/CMake/vtkVersion.cmake" \
    "$source_dir/Common/Core/CMakeLists.txt"

set -e; set -o xtrace

# PNG and TIFF come from the pinned inputs in external-inputs.lock, staged in a
# directory of this build and never from the Homebrew of this Mac; see
# Horos/Scripts/external-inputs.sh. Resolved before the stamp is checked, so the
# app always finds them, and checked on every build.
external_prefix="$CONFIGURATION_TEMP_DIR/ExternalInputs.build/Install"
sh "$external_inputs" "$external_prefix" "$PROJECT_TEMP_DIR/ExternalInputs.downloads" || {
    status=$?
    printf 'error: VTK external input resolution exited with status %s (prefix: %s, downloads: %s)\n' \
        "$status" "$external_prefix" "$PROJECT_TEMP_DIR/ExternalInputs.downloads" >&2
    exit "$status"
}

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
cfs=( -fvisibility=default )
cxxfs=( -fvisibility=default )

args+=(-DBUILD_SHARED_LIBS=OFF)
args+=(-DVTK_BUILD_TESTING=OFF)
args+=(-DVTK_BUILD_EXAMPLES=OFF)
args+=(-DVTK_BUILD_DOCUMENTATION=OFF)
args+=(-DVTK_WRAP_PYTHON=OFF -DVTK_WRAP_JAVA=OFF)
# No wrapping tools either: they serve only the language wrappers, and their
# header parser is a flex scanner with global yy* functions. In libVTK.a these
# took the place of DCMTK's VR scanner's own (dcmdata's vrscanl.c) at link time.
args+=(-DVTK_ENABLE_WRAPPING=OFF)
# Upstream sets hidden visibility after project(). The host hook adjusts the
# completed targets so plugins can reach VTK through the app's static library,
# including the published vtkHoros* headers and the views' renderers.
# DEFER requires CMake 3.19; external-inputs.lock already requires 3.23.
args+=(-DCMAKE_PROJECT_VTK_INCLUDE="$host_build")
args+=(-DCMAKE_CXX_VISIBILITY_PRESET=default -DCMAKE_VISIBILITY_INLINES_HIDDEN=OFF)
args+=(-DVTK_ENABLE_REMOTE_MODULES=OFF)
args+=(-DVTK_SMP_IMPLEMENTATION_TYPE=Sequential)
args+=(-DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET")
args+=(-DCMAKE_OSX_ARCHITECTURES="$ARCHS")
args+=(-DCMAKE_BUILD_TYPE="$CONFIGURATION")
[ "$CONFIGURATION" == 'Release' ] && args+=( -DCMAKE_CXX_FLAGS_RELEASE=-O3 )

# Only the modules asked for below, with what they depend on. No group is
# wanted: Rendering would bring RenderingOpenGL2 and a window system.
args+=(-DVTK_BUILD_ALL_MODULES=OFF)
for group in StandAlone Rendering Imaging MPI Qt Views Web; do
    args+=(-DVTK_GROUP_ENABLE_$group=DONT_WANT)
done
# The app presents VTK scenes with Metal (VRPresentation.mm), and its own object
# factory (SceneFactory.cxx) gives the classes VTK makes only through a
# rendering backend. No backend is built, so VTK links no OpenGL.
for module in RenderingOpenGL2 RenderingVolumeOpenGL2 RenderingContextOpenGL2 \
              RenderingUI RenderingWebGPU RenderingGL2PSOpenGL2 IOExportGL2PS \
              IOExportPDF RenderingOpenXR RenderingOpenVR RenderingAnari; do
    args+=(-DVTK_MODULE_ENABLE_VTK_$module=NO)
done
# The modules whose headers the app includes; the rest come as dependencies.
for module in CommonComputationalGeometry CommonSystem CommonTransforms \
              FiltersCore FiltersExtraction FiltersGeneral FiltersGeometry \
              FiltersModeling FiltersSources FiltersTexture \
              ImagingCore ImagingHybrid ImagingMorphological ImagingStencil \
              IOImage IOGeometry IOExport \
              InteractionStyle InteractionWidgets \
              RenderingAnnotation RenderingCore RenderingFreeType RenderingVolume; do
    args+=(-DVTK_MODULE_ENABLE_VTK_$module=YES)
done

args+=(-DCMAKE_INSTALL_PREFIX="$install_dir")
args+=(-DVTK_INSTALL_SDK=ON)

# zlib and Expat from the macOS SDK; PNG and TIFF from the pinned inputs.
for library in zlib png tiff expat; do
    args+=(-DVTK_MODULE_USE_EXTERNAL_VTK_$library=ON)
done
args+=(-DCMAKE_IGNORE_PATH="/opt/local/include;/opt/local/lib")
# Nothing is looked up in a package manager's prefix, including the one CMake
# itself was installed from; pkg-config sees no .pc file at all.
args+=(-DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/opt/local;/usr/local")
export PKG_CONFIG_LIBDIR="$external_prefix/lib/pkgconfig"
args+=(-DTIFF_INCLUDE_DIR="$external_prefix/include" -DTIFF_LIBRARY="$external_prefix/lib/libtiff.dylib")
args+=(-DPNG_PNG_INCLUDE_DIR="$external_prefix/include" -DPNG_LIBRARY="$external_prefix/lib/libpng.dylib")

if [ ! -z "$CLANG_CXX_LIBRARY" ] && [ "$CLANG_CXX_LIBRARY" != 'compiler-default' ]; then
    cxxfs+=(-stdlib="$CLANG_CXX_LIBRARY")
fi
# VTK 9 sets C++17 itself (CMAKE_CXX_STANDARD); the project default of the
# dependency targets (c++0x) would come after it and lower the standard.

cxxfss="${cxxfs[@]}"
args+=(-DCMAKE_CXX_FLAGS="$cxxfss")
cfss="${cfs[@]}"
args+=(-DCMAKE_C_FLAGS="$cfss")

cmake "${args[@]}"

echo "$hash" > "$cmake_dir/.cmakehash"
echo "$env" > "$cmake_dir/.cmakeenv"

exit 0
