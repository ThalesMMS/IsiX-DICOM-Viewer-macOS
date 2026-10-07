# Initial cache (cmake -C) for configuring a dependency's x86_64 slice on an
# Apple Silicon Mac. The CMake scripts of ITK, VTK, DCMTK and OpenJPEG pass it
# only when the build's ARCHS is not the architecture of the Mac building it.
#
# Naming the system makes the configure a cross build: CMake then runs no test
# program of the x86_64 slice on this Mac. Without Rosetta such a program
# cannot run at all, and the check would silently take the failure as its
# answer; with Rosetta it would still measure the translation, not the target.
# A check that runs a program needs its answer below; one that has none stops
# the configure and is listed in TryRunResults.cmake of the build directory,
# instead of being decided by this Mac.
#
# The answers are those of macOS on x86_64: LP64, little-endian, IEEE 754
# arithmetic in SSE2 registers. Where the program measures the system library
# or the toolchain rather than the processor, the answer is the one the arm64
# configure of the same SDK measured.

set(CMAKE_SYSTEM_NAME Darwin CACHE STRING "")
set(CMAKE_SYSTEM_PROCESSOR x86_64 CACHE STRING "")

# ITK, double-conversion: 89255.0/1e22 is exact without x87 extended precision,
# so no correction is needed (the program returns 1).
set(DOUBLE_CONVERSION_CORRECT_DOUBLE_OPERATIONS 1 CACHE INTERNAL "")

# ITK, VXL introspection: 64-bit file offsets, and SSE2 present on every x86_64.
set(VCL_HAS_LFS 1 CACHE INTERNAL "")
set(VXL_HAS_SSE2_HARDWARE_SUPPORT 1 CACHE INTERNAL "")

# ITK, VNL: the libc++ version decides only whether a VNL test is skipped
# (versions below 1102), and the tests are not built. The _LIBCPP_VERSION of
# the SDK this was written with; every supported SDK is far above 1102.
set(_libcxx_run_result 0 CACHE STRING "")
set(_libcxx_run_result__TRYRUN_OUTPUT "220106" CACHE STRING "")

# ITK, NrrdIO: the 22nd bit of a 32-bit quiet NaN is set on x86.
set(QNANHIBIT_VALUE 1 CACHE INTERNAL "")
set(HAVE_QNANHIBIT_VALUE TRUE CACHE INTERNAL "")

# VTK: the large file support program compiles and runs with 64-bit offsets.
set(VTK_REQUIRE_LARGE_FILE_SUPPORT 1 CACHE INTERNAL "")

# DCMTK's own switch for cross builds, with the result of the iconv program.
# The value describes the macOS iconv, not the processor; it is what the arm64
# configure printed.
set(DCMTK_NO_TRY_RUN TRUE CACHE BOOL "")
set(DCMTK_ICONV_FLAGS_ANALYZED TRUE CACHE INTERNAL "")
set(DCMTK_FIXED_ICONV_CONVERSION_FLAGS "AbortTranscodingOnIllegalSequence" CACHE INTERNAL "")
