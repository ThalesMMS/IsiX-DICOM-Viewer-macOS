#!/usr/bin/env python3
"""The ITK adapter turns ITK's exceptions and other C++ exceptions into NSError.

Horos/Sources/Adapters/ITK holds the Objective-C++ through which the app's
Swift reaches ITK: IsiXITKVolume (a series' voxels as ITK's import filter
sees them), IsiXITKRegionGrowing (connected threshold, neighborhood connected
and confidence connected from a seed, cast to a byte mask) and
IsiXITKResampler (an affine transform onto a grid). Their headers carry no C++
type. Swift cannot catch a C++ exception, so every call into ITK runs inside a
guard (IsiXITKGuard) that turns an itk::ExceptionObject into an NSError of
IsiXITKErrorDomain with ITK's description, location, file and line, and any
other C++ exception into one with its what().

The adapter's files are compiled here against the ITK the Debug build
installed, with only the adapter's folder on the include path (exit 2 without
that build), with a driver that:
- grows a region with each filter in a small volume and checks the mask;
- resamples through the identity onto the volume's own grid and gets the
  voxels back, and through a shift;
- provokes ITK exceptions: a volume with a spacing of 0, which ITK refuses when
  the filter brings it up to date, for the region growing and the resampling,
  and an output grid of spacing 0; each is an NSError of
  IsiXITKErrorCodeLibrary with ITK's message and location, not a terminated
  process;
- runs the guard on a std::runtime_error and on a thrown int: each is an
  NSError of IsiXITKErrorCodeException;
- refuses arguments before calling ITK: no voxels, a negative size, an output
  too small, a filter that does not exist (IsiXITKErrorCodeInvalidArgument).
"""
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402

ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / 'Horos/Sources/Adapters/ITK'
INSTALL = next((base / 'Intermediates.noindex/Horos.build/Debug/ITK.build/Install'
                for base in (ROOT / 'build', ROOT / 'build/Build')
                if (base / 'Intermediates.noindex/Horos.build/Debug/ITK.build/Install/wlib/libITK.a').is_file()), None)
if INSTALL is None:
    print('skipped: needs the ITK of a Debug build from script/build_and_run.sh --verify')
    sys.exit(2)

DRIVER = r'''
#import <Foundation/Foundation.h>
#import "IsiXITKInternal.hpp"
#import "IsiXITKRegionGrowing.h"
#import "IsiXITKResampler.h"
#include <cstdio>
#include <stdexcept>
#include <vector>

static int failures = 0;
static void check(bool condition, const char *what)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", what);
    if (!condition) failures++;
}

static bool isError(NSError *error, NSInteger code)
{
    return [error.domain isEqualToString:IsiXITKErrorDomain] && error.code == code && [error.userInfo[IsiXITKOperationKey] length] > 0;
}

static long count(IsiXITKMask *mask, uint8_t value)
{
    long n = 0;
    for (long i = 0; i < mask.width * mask.height * mask.depth; i++) n += mask.bytes[i] == value;
    return n;
}

int main()
{
    @autoreleasepool {
        // 12 x 10 x 6: 0 everywhere, a 4 x 4 x 3 block of 100 and, apart from it, a voxel of 100.
        const long W = 12, H = 10, D = 6;
        std::vector<float> voxels(W * H * D, 0);
        for (long z = 1; z < 4; z++)
            for (long y = 2; y < 6; y++)
                for (long x = 3; x < 7; x++) voxels[(z * H + y) * W + x] = 100;
        voxels[(4 * H + 8) * W + 10] = 100;
        const double origin[3] = {-1.5, 2, 3.25}, spacing[3] = {0.5, 0.75, 2};

        NSError *error = nil;
        IsiXITKVolume *volume = [[IsiXITKVolume alloc] initWithVoxels:voxels.data() width:W height:H depth:D origin:origin
                                                              spacing:spacing owner:nil error:&error];
        double read[3];
        [volume getSpacing:read];
        check(volume != nil && error == nil && volume.width == W && volume.height == H && volume.depth == D && read[1] == 0.75, "a volume imports with its size and spacing");

        IsiXITKRegionGrowingParameters threshold = {IsiXITKRegionGrowingFilterConnectedThreshold, 50, 150, 0, 0, 0};
        IsiXITKMask *mask = [IsiXITKRegionGrowing growVolume:volume seedX:4 y:3 z:2 parameters:threshold error:&error];
        check(mask && mask.width == W && mask.height == H && mask.depth == D && count(mask, 255) == 48 && count(mask, 0) == W * H * D - 48,
              "connected threshold grows the block and not the voxel apart");
        IsiXITKRegionGrowingParameters neighborhood = {IsiXITKRegionGrowingFilterNeighborhoodConnected, 50, 150, 1, 0, 0};
        mask = [IsiXITKRegionGrowing growVolume:volume seedX:4 y:3 z:2 parameters:neighborhood error:&error];
        check(mask && count(mask, 255) == 4, "neighborhood connected keeps the voxels whose whole neighbourhood is inside");
        IsiXITKRegionGrowingParameters confidence = {IsiXITKRegionGrowingFilterConfidenceConnected, 0, 0, 1, 2.5f, 2};
        mask = [IsiXITKRegionGrowing growVolume:volume seedX:4 y:3 z:2 parameters:confidence error:&error];
        check(mask && count(mask, 255) > 0, "confidence connected grows from the seed");

        double identity[12] = {1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0};
        NSInteger size[3] = {W, H, D};
        std::vector<float> resampled(W * H * D, -1);
        BOOL resampledOK = [IsiXITKResampler resampleVolume:volume parameters:identity origin:origin spacing:spacing size:size
                                               defaultValue:-7 into:resampled.data() length:resampled.size() * sizeof(float) error:&error];
        check(resampledOK && resampled == voxels, "the identity onto the volume's own grid gives the voxels back");
        double shift[12] = {1, 0, 0, 0, 1, 0, 0, 0, 1, 0.5, 0, 0};
        resampledOK = [IsiXITKResampler resampleVolume:volume parameters:shift origin:origin spacing:spacing size:size
                                          defaultValue:-7 into:resampled.data() length:resampled.size() * sizeof(float) error:&error];
        check(resampledOK && resampled[(2 * H + 3) * W + 2] == 100 && resampled[W - 1] == -7,
              "a shift of one voxel moves the block, and the edge falls outside");

        // ITK refuses a spacing of 0 when the filter brings the volume up to date.
        const double flat[3] = {0.5, 0, 2};
        IsiXITKVolume *broken = [[IsiXITKVolume alloc] initWithVoxels:voxels.data() width:W height:H depth:D origin:origin
                                                              spacing:flat owner:nil error:&error];
        check(broken != nil, "a volume of spacing 0 imports (ITK only reads the spacing when it runs)");
        error = nil;
        mask = [IsiXITKRegionGrowing growVolume:broken seedX:4 y:3 z:2 parameters:threshold error:&error];
        check(mask == nil && isError(error, IsiXITKErrorCodeLibrary) && [error.userInfo[IsiXITKMessageKey] length] > 0 &&
              [error.userInfo[IsiXITKLocationKey] length] > 0 && [error.userInfo[IsiXITKLineKey] integerValue] > 0,
              "an ITK exception in the region growing is an NSError with ITK's message, location and line");
        printf("  %s\n", error.localizedDescription.UTF8String);
        error = nil;
        resampledOK = [IsiXITKResampler resampleVolume:broken parameters:identity origin:origin spacing:spacing size:size
                                          defaultValue:0 into:resampled.data() length:resampled.size() * sizeof(float) error:&error];
        check(!resampledOK && isError(error, IsiXITKErrorCodeLibrary), "an ITK exception in the resampling is an NSError");
        error = nil;
        resampledOK = [IsiXITKResampler resampleVolume:volume parameters:identity origin:origin spacing:flat size:size
                                          defaultValue:0 into:resampled.data() length:resampled.size() * sizeof(float) error:&error];
        check(!resampledOK && isError(error, IsiXITKErrorCodeLibrary), "an output grid of spacing 0 is an NSError");
        printf("  %s\n", error.localizedDescription.UTF8String);

        // Other C++ exceptions inside the guard.
        error = nil;
        BOOL guarded = IsiXITKGuard(&error, "probe", [&]() -> NSError * { throw std::runtime_error("the mask does not fit"); });
        check(!guarded && isError(error, IsiXITKErrorCodeException) &&
              [error.userInfo[IsiXITKMessageKey] isEqualToString:@"the mask does not fit"], "a std::exception is an NSError with its what()");
        error = nil;
        guarded = IsiXITKGuard(&error, "probe", [&]() -> NSError * { throw 42; });
        check(!guarded && isError(error, IsiXITKErrorCodeException), "any other thrown value is an NSError");
        error = nil;
        guarded = IsiXITKGuard(&error, "probe", [&]() -> NSError * { itkGenericExceptionMacro("raised by the probe"); });
        check(!guarded && isError(error, IsiXITKErrorCodeLibrary) && [error.userInfo[IsiXITKMessageKey] containsString:@"raised by the probe"],
              "an itk::ExceptionObject thrown in the guard is an NSError of ITK");

        // What the adapter refuses before calling ITK.
        error = nil;
        check([[IsiXITKVolume alloc] initWithVoxels:nullptr width:W height:H depth:D origin:origin spacing:spacing owner:nil
                                              error:&error] == nil && isError(error, IsiXITKErrorCodeInvalidArgument),
              "no voxels is IsiXITKErrorCodeInvalidArgument");
        error = nil;
        check([[IsiXITKVolume alloc] initWithVoxels:voxels.data() width:-1 height:H depth:D origin:origin spacing:spacing owner:nil
                                              error:&error] == nil && isError(error, IsiXITKErrorCodeInvalidArgument),
              "a negative size is IsiXITKErrorCodeInvalidArgument");
        error = nil;
        IsiXITKRegionGrowingParameters none = {(IsiXITKRegionGrowingFilter)9, 0, 0, 0, 0, 0};
        check([IsiXITKRegionGrowing growVolume:volume seedX:0 y:0 z:0 parameters:none error:&error] == nil &&
              isError(error, IsiXITKErrorCodeInvalidArgument), "a filter that does not exist is IsiXITKErrorCodeInvalidArgument");
        error = nil;
        check(![IsiXITKResampler resampleVolume:volume parameters:identity origin:origin spacing:spacing size:size defaultValue:0
                                           into:resampled.data() length:(resampled.size() + 1) * sizeof(float) error:&error] &&
              isError(error, IsiXITKErrorCodeEmptyResult), "asking for more bytes than the result has is refused");
    }
    printf("%d failure(s)\n", failures);
    return failures ? 1 : 0;
}
'''

with tempfile.TemporaryDirectory() as folder:
    folder = Path(folder)
    (folder / 'driver.mm').write_text(DRIVER)
    sources = [folder / 'driver.mm', ADAPTER / 'IsiXITKError.mm', ADAPTER / 'IsiXITKVolume.mm', ADAPTER / 'IsiXITKRegionGrowing.mm',
               ADAPTER / 'IsiXITKResampler.mm']
    objects = []
    for index, source in enumerate(sources):
        output = folder / f'{index}.o'
        # Only the adapter's own folder is on the path: it includes nothing of the app.
        compiled = subprocess.run(['xcrun', 'clang++', '-std=c++17', '-x', 'objective-c++', '-fobjc-arc', '-c',
                                   '-I' + str(INSTALL / 'include'), '-I' + str(ADAPTER), str(source), '-o', str(output)],
                                  capture_output=True, text=True)
        if compiled.returncode != 0:
            print(compiled.stderr[-4000:], file=sys.stderr)
            print('FAIL: ' + source.name + ' does not compile on its own against ITK', file=sys.stderr)
            sys.exit(1)
        objects.append(str(output))
    linked = subprocess.run(['xcrun', 'clang++', *objects, str(INSTALL / 'wlib/libITK.a'), '-framework', 'Foundation',
                             '-o', str(folder / 'driver')], capture_output=True, text=True)
    if linked.returncode != 0:
        print(linked.stderr[-4000:], file=sys.stderr)
        sys.exit(1)
    try:
        run = subprocess.run([str(folder / 'driver')], capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        print('FAIL: the driver did not finish within 60 s', file=sys.stderr)
        sys.exit(1)
    print(run.stdout, end='')
    if run.returncode != 0:
        print(run.stderr[-2000:], file=sys.stderr)
        sys.exit(1)
