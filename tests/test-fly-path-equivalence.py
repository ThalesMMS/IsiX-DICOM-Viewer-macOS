#!/usr/bin/env python3
"""The fly-path assistant of IsiXVolumeRendering finds what FlyAssistant.mm found,
on the lumen's axis.

FlyAssistant.mm, FlyAssistant+Histo.mm and Quaternion.mm (the endoscopy's path
assistant: the lumen's thresholds from the volume's histogram, the distance
transform, the centerline between two points, the navigator's steps, the view
direction) became FlyPathAssistant, its Histogram and Centerline extensions and
FlyQuaternion in IsiXVolumeRendering; FlyAssistant.swift keeps the app's class
and selectors over it. This compiles, from the last revision that has the
Objective-C++ files, read from git, FlyAssistant.mm with its category,
Quaternion.mm, N3Geometry.m, Point3D and OSIVoxel, and the module's sources
from the tree, each with a driver that runs the same plan on the same
generated volumes.

The contract is FlyAssistant.mm's arithmetic, bit for bit, but where it put a
centerline up to a voxel off the lumen's axis or short of its end; there the
module's points lie within half a resampled voxel of the original's. Eight of
the ten corrections below choose another path (another lumen, another meeting
voxel, other thresholds, another grid, other seeds): the reference driver
applies all ten to FlyAssistant.mm's own code, so that everything after them still compares bit
for bit, and the half voxel holds between the module's points and the
original's on the same path. How far a corrected path lies from the
uncorrected original's is not bounded here: on these volumes the lumen's
sampling alone moves points by one to three voxels, by design. The ten
corrections:

- the threshold image: a resampled voxel takes the input's value at its
  centre, interpolated (trilinear, one fma a step) between the 8 voxels
  around it; the original took the brightest of the 8 voxels from its
  corner on, which widened a bright lumen by a voxel. The driver's
  -thresholdImage replaces the original's;
- the closing of the threshold image along the depth runs along the slices:
  the original gave vImage the volume's memory as rows of as many values as
  there are slices, which lie along x and across the rows, and a voxel of
  lumen was added where such a run started or ended beside the lumen. The
  closing of each slice is the original's. In the driver's -thresholdImage;
- the seeds of the two searches are planted within the volume along each
  axis: the original checked the linear index alone, so a point of the first
  or last column, row or slice planted neighbours at the other end of the
  row or of the slice before, and the path jumped across the volume. One
  condition in FlyAssistant.mm's search, patched in its text;
- the thresholds of a centerline and of a step are looked for from the lower
  median of the voxels around the points, where the original took their
  mean: beside a wall the mean lies on the ramp of its partial volume, and
  the thresholds taken there let the lumen out into the tissue. One function
  and its call before each of the two computations, inserted in the text;
- the centerline's points: the centres of the resampled voxels, where the
  original gave their corners, half a voxel off along each axis; the first
  and the last points are the two points given (held to the volume), each
  in the voxel it stands for. The original's corners are printed too, and
  every point of the module's path must lie within half a voxel, along each
  axis, of the centre of the original's voxel: exactly half a voxel from its
  corner between the ends;
- the two searches meet on a voxel the other one has settled: the original
  stopped at one it had only reached, often beside the axis, and the path
  stepped a voxel aside there. One condition in FlyAssistant.mm's search,
  patched in its text;
- the thinning keeps the last point: when the original dropped it (closer to
  the last point kept than their radii, up to a radius before the second
  point given), it takes the place of the last point kept but the first;
- the thresholds of a centerline and of a step before the transform sample
  the input around the voxel nearest to each point, where the voxel (i, j, k)
  lies at (i, j, k); the original converted each coordinate toward zero, up
  to a voxel aside. Three conversions in FlyAssistant.mm, patched in its text;
- the interval of those thresholds holds that value give or take three
  median absolute deviations of the voxels (about two
  standard deviations of the noise), but no more than the interval's own
  width, when the mean lies in it or that close to it: on the flat top of a
  bright lumen's peak the histogram's interval starts at the mean, and the
  lumen's values at the voxels' centres fall half out of it (the 'contrast'
  volume); beside a blurred wall the voxels' deviation is the wall's ramp,
  and the width keeps the tissue out (the module's tests). Two functions and
  a call after each of the two computations of the thresholds, inserted in
  FlyAssistant.mm's text;
- an axis of the resampled volume a thousandth of a voxel or less short of a
  whole number of voxels has that number: the original truncated the
  quotient, and 40 slices 0.59999996 mm apart at 0.6 mm made 39 resampled
  slices (the 'sliced' volume). Three lines in FlyAssistant.mm, patched in
  its text.

A module that is FlyAssistant.mm bit for bit fails it: its distance maps are
those of the brightest voxels, and its centerlines run through the corners.

Plan:

- the input's histogram (every bin) and its range, and the thresholds the
  histogram gives for values in the lumen, the wall and between, inside the
  range (outside it FlyAssistant+Histo.mm read outside its histogram);
- the navigator's steps before the distance transform (thresholds from the
  voxels around the point, on a voxel and between voxels) and after it;
- the distance map (every voxel) after the transform at a threshold;
- centerlines between points, as the search gives them, thinned by the
  lumen's radius, as they are and smoothed (the smoothing's spline is a
  stand-in in both, the nearest of its points; VTK's spline is the VTK
  adapter's test), and points between voxels, outside the volume or the same
  point twice;
- the next center point, the radius and the mean radius along a centerline,
  the view direction from each point toward one further on (the quaternion
  rotations) and the trace of a line.

Every number is printed in hexadecimal; the outputs must be the same, in
Debug (-O0 / -Onone) and Release (-Os / -O). The module's Debug driver runs
under AddressSanitizer, so a read outside the volume (points A and B are
clamped to its corners in one search), the distance map or the histogram
stops it. Exits 2 when the history does
not reach a revision with FlyAssistant.mm.

    python3 tests/test-fly-path-equivalence.py
"""
import math
import os
import random
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs
import history_reference  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
FLY = 'Horos/Sources/FlyAssistant.mm'
MODULE = ROOT / 'Modules/IsiXVolumeRendering/Sources'
MODULE_FILES = ['FlyQuaternion.swift', 'FlyPathAssistant.swift', 'FlyPathAssistant+Histogram.swift',
                'FlyPathAssistant+Centerline.swift']

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, clang)', file=sys.stderr)
    raise SystemExit(2)
reference = history_reference.before_removal(FLY)
if reference is None and subprocess.run(['git', '-C', str(ROOT), 'cat-file', '-e', f'HEAD:{FLY}'],
                                        capture_output=True).returncode == 0:
    reference = 'HEAD'
if reference is None:
    print('skipped: no revision of this history has ' + FLY, file=sys.stderr)
    raise SystemExit(2)

OLD_SWIFT = ['Horos/Sources/Point3D.swift', 'Horos/Sources/OSIVoxel.swift']
OLD_HEADERS = ['Horos/Sources/Point3D.h', 'Horos/Sources/OSIVoxel.h', 'Horos/Sources/Quaternion.h',
               'Horos/Sources/FlyAssistant.h', 'Horos/Sources/FlyAssistant+Histo.h', 'Nitrogen/Sources/N3Geometry.h']
OLD_OBJC = [('N3Geometry.m', 'objective-c', 'Nitrogen/Sources/N3Geometry.m'),
            ('Quaternion.mm', 'objective-c++', 'Horos/Sources/Quaternion.mm'),
            ('FlyAssistant+Histo.mm', 'objective-c++', 'Horos/Sources/FlyAssistant+Histo.mm'),
            ('FlyAssistant.mm', 'objective-c++', FLY)]

# --- the volumes and the plan -----------------------------------------------------------
rng = random.Random(1491)


def volume(width, height, depth, inside, value, wall, noise):
    data = []
    for z in range(depth):
        for y in range(height):
            for x in range(width):
                v = value(x, y, z) if inside(x, y, z) else wall(x, y, z)
                data.append(v + rng.uniform(-noise, noise))
    return struct.pack('<%df' % len(data), *data)


def tube(x, y, z):
    return 6 <= x < 14 and 6 <= y < 14 and 4 <= z < 124


def curve_center(z):
    return 24 + 9 * math.sin(z / 9.0), 20 + 7 * math.cos(z / 13.0)


def curved(x, y, z):
    cx, cy = curve_center(z)
    return (x - cx) ** 2 + (y - cy) ** 2 <= 30 and 3 <= z < 57


def bright(x, y, z):
    return (x - 8) ** 2 + (y - 32) ** 2 + (z - 30) ** 2 <= 16


def contrast_vessel():
    """A contrast-filled vessel (350 HU, radius 4 voxels, its axis at x = y = 11.5) in soft tissue (40 HU), with
    Gaussian noise of 10 HU in whole units, as a CT gives them, and a column of air in a corner, which stretches the
    histogram as the rest of a CT does. Its own generator: the histogram's interval from the mean of the voxels
    around the plan's points starts at that mean ([351, 371]), and without the interval's correction the path
    zig-zags up to 3 voxels off the axis."""
    noise = random.Random(1)
    data = []
    for z in range(40):
        for y in range(24):
            for x in range(24):
                mean = -900 if x < 2 and y < 2 else 350 if (x - 11.5) ** 2 + (y - 11.5) ** 2 <= 16 else 40
                data.append(float(round(mean + noise.gauss(0, 10))))
    return struct.pack('<%df' % len(data), *data)


VOLUMES = {
    'straight': (20, 20, 128, (0.5, 0.5, 0.5), 1.0,
                 volume(20, 20, 128, tube, lambda *p: 1000, lambda *p: 0, 40)),
    'curved': (48, 40, 60, (0.7, 0.8, 1.25), 1.0,
               volume(48, 40, 60, curved, lambda *p: 300, lambda x, y, z: 1500 if bright(x, y, z) else -900, 60)),
    # A brighter column keeps the lumen's peak inside the histogram: past its
    # end FlyAssistant+Histo.mm read memory outside it.
    'short': (16, 16, 20, (1.0, 1.0, 1.0), 1.5,
              volume(16, 16, 20, lambda x, y, z: 5 <= x < 11 and 5 <= y < 11, lambda *p: 200,
                     lambda x, y, z: 450 if x < 2 and y < 2 else -200, 20)),
    'contrast': (24, 24, 40, (0.6, 0.6, 0.6), 0.6, contrast_vessel()),
    # Slices 0.59999996 mm apart, as a slice interval measured between two positions of 0.6 mm slices comes out
    # in float, resampled at 0.6 mm: 40 slices, where the original's truncated quotient made 39.
    'sliced': (16, 16, 40, (0.6, 0.6, 0.59999996), 0.6,
               volume(16, 16, 40, lambda x, y, z: 5 <= x < 11 and 5 <= y < 11 and 2 <= z < 38, lambda *p: -900,
                      lambda *p: 40, 10)),
}


def point(p):
    return ' '.join('%r' % float(v) for v in p)


PLAN = []
for name, (w, h, d, spacing, vsize, _) in VOLUMES.items():
    PLAN.append(f'volume {name}.raw {w} {h} {d} {point(spacing)} {vsize!r}')
    # Values inside the volume's range: FlyAssistant+Histo.mm read outside its
    # histogram for the others (undefined; the module's bins there are empty).
    # It reads the bins 10 on either side of the value's, so a value is also
    # kept 10 bins from either end: the peaks of 'sliced' (-900 and 40, with
    # noise of 10) are the ends of its histogram, and its values are taken at
    # their inner edges, where the search goes inward.
    PLAN.append('thresholds ' + {'straight': '1000 0 500 12.5 980 30', 'curved': '300 -900 0 1200 600 -500',
                                 'short': '200 -200 0 100 -150', 'contrast': '350 352.5 40 -500 200',
                                 'sliced': '-890 30 -400'}[name])
    if name == 'straight':
        PLAN.append('unfinished 10 10 60 0 0 1 6')
        PLAN.append('step 1.5')
        PLAN.append('centerline 10 10 12 10 10 115 0')
        PLAN += ['radii', 'views 3', 'center 5 5 30 0 0 1 2', 'center 5 5 30 0 1 1 3']
        PLAN.append('centerline 10 10 12 10 10 115 1')
        PLAN.append('centerline -4 30 -9 19 19 200 0')
        PLAN.append('centerline 9.3 10.6 12.2 10.4 9.7 114.8 0')
        PLAN.append('centerline 10 10 12 10 10 12 0')
        PLAN += ['steps 10 10 20 0 0 1 25', 'steps 1 10 60 1 0 0 3', 'trace 5 5 30 0 0 1', 'trace 5 5 30 1 0 0']
        PLAN.append('transform 500')
    elif name == 'curved':
        cz, cy = curve_center(5), curve_center(54)
        PLAN.append('unfinished %r %r 5 0 0 1 4' % (round(cz[0]), round(cz[1])))
        PLAN.append('step 2')
        PLAN.append('centerline %r %r 5 %r %r 54 0' % (round(cz[0]), round(cz[1]), round(cy[0]), round(cy[1])))
        PLAN += ['radii', 'views 2', 'views 5']
        PLAN.append('centerline %r %r 5 %r %r 54 1' % (round(cz[0]), round(cz[1]), round(cy[0]), round(cy[1])))
        PLAN += ['steps %r %r 8 0.25 0 1 30' % (round(cz[0]), round(cz[1])), 'trace 17 16 20 1 1 0.5']
        PLAN.append('transform -300')
    elif name == 'short':
        PLAN.append('step 1')
        # Between voxels, beside the lumen's edge: the voxel nearest to it is the wall's, the one toward zero the lumen's.
        PLAN.append('unfinished 10.6 8.4 9.5 0 0 1 3')
        PLAN.append('centerline 8 8 1 8 8 18 0')
        PLAN += ['radii', 'views 1']
        PLAN.append('centerline 8 8 1 8 8 18 1')
        PLAN += ['steps 8 8 2 0 0 1 10', 'center 5 5 6 0 0 1 1.5']
    elif name == 'contrast':
        # On the vessel's axis: the histogram's interval from the voxels' mean starts at that mean.
        PLAN.append('step 3')
        PLAN.append('unfinished 11.5 11.5 8 0 0 1 3')
        PLAN.append('centerline 11.5 11.5 3 11.8 11.2 36 0')
        PLAN += ['radii', 'views 3']
        PLAN.append('centerline 11.5 11.5 3 11.8 11.2 36 1')
    else:
        PLAN.append('step 1')
        PLAN.append('centerline 8 8 4 8 8 35 0')
        PLAN += ['radii', 'steps 8 8 6 0 0 1 4']

# --- the reference: FlyAssistant.mm and its spline stand-in -------------------------------
SPLINE_STAND_IN = '''#import <Cocoa/Cocoa.h>
#import "Point3D.h"
#include <iostream>
@interface Spline3D : NSObject
- (void) addPoint:(float)t :(Point3D*)p;
- (Point3D*) evaluateAt:(float)t;
@end
'''

OLD_DRIVER = r'''
#import <Cocoa/Cocoa.h>
#import "FlyAssistant.h"
#import "FlyAssistant+Histo.h"
#import "Spline3D.h"
#include <algorithm>
#include <vector>
#include <cmath>
#include <cstdio>
#include <cstring>

// The nearest of the points given, the first of equals: no arithmetic of its own.
@implementation Spline3D {
    std::vector<float> ts, xs, ys, zs;
}
- (void) addPoint:(float)t :(Point3D*)p { ts.push_back(t); xs.push_back(p.x); ys.push_back(p.y); zs.push_back(p.z); }
- (Point3D*) evaluateAt:(float)t {
    size_t best = 0;
    for (size_t i = 1; i < ts.size(); i++) if (fabsf(t - ts[i]) < fabsf(t - ts[best])) best = i;
    return ts.empty() ? [Point3D point] : [Point3D pointWithX:xs[best] y:ys[best] z:zs[best]];
}
@end

static void pr(const char *label, float x, float y, float z) { printf("%s %a %a %a", label, (double)x, (double)y, (double)z); }

// Along one axis, for each resampled voxel, the input voxels on either side of
// its centre, (i + 0.5) / scale, held to the input's first and last, and the
// weight of the second: FlyPathAssistant.centreSamples.
static void centreSamples(int count, float scale, int inputCount, std::vector<int> &lower, std::vector<int> &upper,
                          std::vector<float> &fraction) {
    int lastIndex = std::max(inputCount - 1, 0);
    float last = (float)lastIndex;
    lower.assign(std::max(count, 0), 0); upper.assign(std::max(count, 0), 0); fraction.assign(std::max(count, 0), 0.f);
    for (int i = 0; i < count; i++) {
        float centre = ((float)i + 0.5f) / scale;
        float held = std::isnan(centre) ? 0.f : std::min(std::max(centre, 0.f), last);
        int low = (int)held;
        lower[i] = low; upper[i] = std::min(low + 1, lastIndex); fraction[i] = held - (float)low;
    }
}

@interface FlyProbe : FlyAssistant {
    BOOL capture;
    float endA[3], endB[3];
}
@end
@implementation FlyProbe
// The corrected threshold image: each resampled voxel takes the input's value at
// its centre, along x, then y, then z, one fma a step, as the module computes it;
// then the original's closing, in place.
- (void) thresholdImage {
    std::vector<int> xl, xu, yl, yu, zl, zu;
    std::vector<float> xf, yf, zf;
    centreSamples(distmapWidth, resampleScale_x, inputWidth, xl, xu, xf);
    centreSamples(distmapHeight, resampleScale_y, inputHeight, yl, yu, yf);
    centreSamples(distmapDepth, resampleScale_z, inputDepth, zl, zu, zf);
    for (int z = 0; z < distmapDepth; z++) {
        long z0 = zl[z] * (long)inputImageSize, z1 = zu[z] * (long)inputImageSize;
        float fz = zf[z];
        for (int y = 0; y < distmapHeight; y++) {
            long y0 = yl[y] * (long)inputWidth, y1 = yu[y] * (long)inputWidth;
            float fy = yf[y];
            long r00 = z0 + y0, r10 = z0 + y1, r01 = z1 + y0, r11 = z1 + y1;
            for (int x = 0; x < distmapWidth; x++) {
                int x0 = xl[x], x1 = xu[x];
                float fx = xf[x];
                float a00 = input[r00 + x0], a10 = input[r10 + x0], a01 = input[r01 + x0], a11 = input[r11 + x0];
                float c00 = fmaf(input[r00 + x1] - a00, fx, a00);
                float c10 = fmaf(input[r10 + x1] - a10, fx, a10);
                float c01 = fmaf(input[r01 + x1] - a01, fx, a01);
                float c11 = fmaf(input[r11 + x1] - a11, fx, a11);
                float c0 = fmaf(c10 - c00, fy, c00), c1 = fmaf(c11 - c01, fy, c01);
                float value = fmaf(c1 - c0, fz, c0);
                distmap[z*distmapImageSize + y*distmapWidth + x] = (value >= thresholdA && value <= thresholdB) ? 3.4e+38 : 0;
            }
        }
    }
    vImage_Buffer buffer;
    buffer.height = distmapHeight;
    buffer.width = distmapWidth;
    buffer.rowBytes = distmapWidth * sizeof(float);
    for (int i = 0; i < distmapDepth; ++i) {
        buffer.data = &distmap[i*distmapImageSize];
        [self mmClosing:&buffer:3:3];
    }
    // Along the slices: the volume as an image whose rows are its slices, closed down its columns. The
    // original read the memory in runs of distmapDepth values, which lie along x and across the rows.
    buffer.data = distmap;
    buffer.height = distmapDepth;
    buffer.width = distmapImageSize;
    buffer.rowBytes = distmapImageSize * sizeof(float);
    [self mmClosing:&buffer:3:1];
}
// The points the next -createCenterline: is given, held to the volume as it holds them.
- (void) captureEndsA:(Point3D*)a B:(Point3D*)b {
    float dims[3] = {(float)inputWidth, (float)inputHeight, (float)inputDepth};
    float given[2][3] = {{a.x, a.y, a.z}, {b.x, b.y, b.z}};
    for (int axis = 0; axis < 3; axis++) {
        for (int end = 0; end < 2; end++) {
            float v = given[end][axis];
            if (v < 0) v = 0;
            if (v >= dims[axis]) v = dims[axis] - 1;
            (end == 0 ? endA : endB)[axis] = v;
        }
    }
    capture = YES;
}
// -createCenterline: thins its points here: the original's corners are printed,
// then the corrected points (the voxels' centres, the two points given at the
// ends) are thinned by the original's code, and the last point is kept.
- (void) downSampleCenterlineWithLocalRadius:(NSMutableArray*)centerline {
    if (capture && centerline.count > 0) {
        capture = NO;
        printf("corners %lu\n", (unsigned long)centerline.count);
        for (OSIVoxel *v in centerline) { pr("corner", v.x, v.y, v.z); printf("\n"); }
        for (OSIVoxel *v in centerline) {
            v.x = ((float)lroundf(v.x * resampleScale_x) + 0.5f) / resampleScale_x;
            v.y = ((float)lroundf(v.y * resampleScale_y) + 0.5f) / resampleScale_y;
            v.z = ((float)lroundf(v.z * resampleScale_z) + 0.5f) / resampleScale_z;
        }
        OSIVoxel *first = centerline.firstObject, *last = centerline.lastObject;
        first.x = endA[0]; first.y = endA[1]; first.z = endA[2];
        last.x = endB[0]; last.y = endB[1]; last.z = endB[2];
        printf("raw %lu\n", (unsigned long)centerline.count);
        for (OSIVoxel *v in centerline) { pr(" ", v.x, v.y, v.z); printf("\n"); }
    }
    id last = centerline.lastObject;
    [super downSampleCenterlineWithLocalRadius:centerline];
    if (last && centerline.lastObject != last) {
        if (centerline.count > 1) [centerline replaceObjectAtIndex:centerline.count - 1 withObject:last];
        else [centerline addObject:last];
    }
}
- (void) printState {
    printf("range %a %a bins %u", (double)inputMinValue, (double)inputMaxValue, histoSize);
    unsigned long long hash = 1469598103934665603ULL;
    for (unsigned i = 0; i < histoSize; i++) { hash ^= (unsigned long long)inputHisto[i]; hash *= 1099511628211ULL; }
    printf(" histogram %016llx\n", hash);
    printf("resampled %d %d %d scale %a %a %a\n", distmapWidth, distmapHeight, distmapDepth,
           (double)resampleScale_x, (double)resampleScale_y, (double)resampleScale_z);
}
- (void) printThresholds { printf(" -> %a %a\n", (double)thresholdA, (double)thresholdB); }
- (void) printDistmap {
    unsigned long long hash = 1469598103934665603ULL;
    long far = 0;
    for (int i = 0; i < distmapVolumeSize; i++) {
        unsigned bits; memcpy(&bits, &distmap[i], 4);
        hash ^= bits; hash *= 1099511628211ULL;
        if (distmap[i] > 1e30) far++;
    }
    printf("distmap %016llx far %ld finished %d threshold %a\n", hash, far, isDistanceTransformFinished ? 1 : 0, (double)threshold);
}
@end

int main(int argc, char **argv) { @autoreleasepool {
    FILE *plan = fopen(argv[1], "r");
    char line[512], name[256];
    FlyProbe *assistant = nil;
    std::vector<float> volume;
    NSMutableArray *centerline = [NSMutableArray array];
    while (fgets(line, sizeof line, plan)) {
        int w, h, d, n, smooth;
        float a[8];
        if (sscanf(line, "volume %255s %d %d %d %f %f %f %f", name, &w, &h, &d, &a[0], &a[1], &a[2], &a[3]) == 8) {
            [assistant release];
            volume.assign((size_t)w * h * d, 0);
            FILE *raw = fopen([[[NSString stringWithUTF8String:argv[1]] stringByDeletingLastPathComponent]
                               stringByAppendingPathComponent:[NSString stringWithUTF8String:name]].fileSystemRepresentation, "rb");
            fread(volume.data(), 4, volume.size(), raw);
            fclose(raw);
            int dim[3] = {w, h, d};
            float spacing[3] = {a[0], a[1], a[2]};
            assistant = [[FlyProbe alloc] initWithVolume:volume.data() WidthDimension:dim Spacing:spacing ResampleVoxelSize:a[3]];
            printf("volume %s\n", name);
            [assistant printState];
        } else if (!strncmp(line, "thresholds", 10)) {
            char *cursor = line + 10;
            float v; int used;
            while (sscanf(cursor, "%f%n", &v, &used) == 1) {
                cursor += used;
                [assistant computeIntervalThresholdsFrom:v];
                printf("thresholds from %a", (double)v); [assistant printThresholds];
            }
        } else if (sscanf(line, "step %f", &a[0]) == 1) {
            assistant.centerlineResampleStepLength = a[0];
        } else if (sscanf(line, "unfinished %f %f %f %f %f %f %d", &a[0], &a[1], &a[2], &a[3], &a[4], &a[5], &n) == 7 ||
                   sscanf(line, "steps %f %f %f %f %f %f %d", &a[0], &a[1], &a[2], &a[3], &a[4], &a[5], &n) == 7) {
            Point3D *pt = [Point3D pointWithX:a[0] y:a[1] z:a[2]], *dir = [Point3D pointWithX:a[3] y:a[4] z:a[5]];
            for (int i = 0; i < n; i++) {
                int err = [assistant caculateNextPositionFrom:pt Towards:dir];
                printf("step %d", err); pr(" at", pt.x, pt.y, pt.z); pr(" toward", dir.x, dir.y, dir.z); [assistant printThresholds];
            }
        } else if (sscanf(line, "centerline %f %f %f %f %f %f %d", &a[0], &a[1], &a[2], &a[3], &a[4], &a[5], &smooth) == 7) {
            [centerline removeAllObjects];
            Point3D *pa = [Point3D pointWithX:a[0] y:a[1] z:a[2]], *pb = [Point3D pointWithX:a[3] y:a[4] z:a[5]];
            [assistant captureEndsA:pa B:pb];
            int err = [assistant createCenterline:centerline FromPointA:pa ToPointB:pb withSmoothing:smooth];
            printf("centerline %d points %lu", err, (unsigned long)centerline.count); [assistant printThresholds];
            for (OSIVoxel *v in centerline) { pr(" ", v.x, v.y, v.z); printf("\n"); }
            [assistant printDistmap];
        } else if (!strncmp(line, "radii", 5)) {
            for (NSUInteger i = 0; i < centerline.count; i++)
                printf("radius %a mean %a %a\n", (double)[assistant radiusAtPoint:centerline[i]],
                       (double)[assistant averageRadiusAt:(int)i On:centerline InRange:2],
                       (double)[assistant averageRadiusAt:(int)i On:centerline InRange:5]);
        } else if (sscanf(line, "views %d", &n) == 1) {
            NSUInteger count = centerline.count, stride = count / 12 > 0 ? count / 12 : 1;
            for (NSUInteger i = 0; i + n < count; i += stride) {
                OSIVoxel *view = [assistant computeMaximizingViewDirectionFrom:centerline[i] LookingAt:centerline[i + n]];
                pr("view", view.x, view.y, view.z); printf("\n");
            }
        } else if (sscanf(line, "center %f %f %f %f %f %f %f", &a[0], &a[1], &a[2], &a[3], &a[4], &a[5], &a[6]) == 7) {
            Point3D *c = [assistant caculateNextCenterPointFrom:[Point3D pointWithX:a[0] y:a[1] z:a[2]]
                                                        Towards:[Point3D pointWithX:a[3] y:a[4] z:a[5]] WithStepLength:a[6]];
            if (c) { pr("center", c.x, c.y, c.z); printf("\n"); } else printf("center none\n");
        } else if (sscanf(line, "trace %f %f %f %f %f %f", &a[0], &a[1], &a[2], &a[3], &a[4], &a[5]) == 6) {
            printf("trace %u\n", [assistant traceLineFrom:[Point3D pointWithX:a[0] y:a[1] z:a[2]]
                                             accordingTo:[Point3D pointWithX:a[3] y:a[4] z:a[5]]]);
        } else if (sscanf(line, "transform %f", &a[0]) == 1) {
            [assistant setThreshold:a[0] Asynchronous:NO];
            [assistant printDistmap];
        }
    }
    [assistant release];
    return 0;
} }
'''

NEW_DRIVER = r'''
import Foundation

// The nearest of the points given, the first of equals: no arithmetic of its own.
final class NearestSpline: FlyPathSpline {
    var ts: [Float] = [], points: [SIMD3<Float>] = []
    func addPoint(_ t: Float, _ point: SIMD3<Float>) { ts.append(t); points.append(point) }
    func evaluate(_ t: Float) -> SIMD3<Float> {
        guard !ts.isEmpty else { return .zero }
        var best = 0
        for i in 1..<ts.count where abs(t - ts[i]) < abs(t - ts[best]) { best = i }
        return points[best]
    }
}

func h(_ v: Float) -> String { String(format: "%a", Double(v)) }
func p(_ label: String, _ v: SIMD3<Float>) -> String { "\(label) \(h(v.x)) \(h(v.y)) \(h(v.z))" }
nonisolated(unsafe) var out = ""
func emit(_ s: String) { out += s }

let planPath = CommandLine.arguments[1]
let folder = (planPath as NSString).deletingLastPathComponent
var assistant: FlyPathAssistant?
var volume: UnsafeMutablePointer<Float>?
var centerline: [SIMD3<Float>] = []

func thresholds(_ a: FlyPathAssistant) -> String { " -> \(h(a.thresholdA)) \(h(a.thresholdB))\n" }
func distmapLine(_ a: FlyPathAssistant) -> String {
    var hash: UInt64 = 1469598103934665603
    var far = 0
    for i in 0..<a.distmapVolumeSize {
        let v = a.distmap![i]
        hash ^= UInt64(v.bitPattern); hash = hash &* 1099511628211
        if v > 1e30 { far += 1 }
    }
    return "distmap \(String(format: "%016llx", hash)) far \(far) finished \(a.isDistanceTransformFinished ? 1 : 0) threshold \(h(a.threshold))\n"
}

for raw in try! String(contentsOfFile: planPath, encoding: .utf8).split(separator: "\n") {
    let words = raw.split(separator: " ").map(String.init)
    let f = words.dropFirst().compactMap { Float($0) }
    switch words[0] {
    case "volume":
        assistant = nil
        volume?.deallocate()
        let (w, hh, d) = (Int(words[2])!, Int(words[3])!, Int(words[4])!)
        let data = FileManager.default.contents(atPath: (folder as NSString).appendingPathComponent(words[1]))!
        volume = .allocate(capacity: w * hh * d)
        _ = data.withUnsafeBytes { memcpy(volume!, $0.baseAddress!, w * hh * d * 4) }
        let a = FlyPathAssistant(volume: volume!, width: w, height: hh, depth: d,
                                 spacing: SIMD3(Float(words[5])!, Float(words[6])!, Float(words[7])!),
                                 resampleVoxelSize: Float(words[8])!)!
        assistant = a
        emit("volume \(words[1])\n")
        var hash: UInt64 = 1469598103934665603
        for i in 0..<Int(a.histogramSize) { hash ^= UInt64(a.inputHistogram![i]); hash = hash &* 1099511628211 }
        emit("range \(h(a.inputMinValue)) \(h(a.inputMaxValue)) bins \(a.histogramSize) histogram \(String(format: "%016llx", hash))\n")
        emit("resampled \(a.distmapWidth) \(a.distmapHeight) \(a.distmapDepth) scale \(h(a.resampleScale.x)) \(h(a.resampleScale.y)) \(h(a.resampleScale.z))\n")
    case "thresholds":
        for v in f {
            assistant!.computeIntervalThresholds(from: v)
            emit("thresholds from \(h(v))" + thresholds(assistant!))
        }
    case "step":
        assistant!.centerlineResampleStepLength = f[0]
    case "unfinished", "steps":
        var pt = SIMD3(f[0], f[1], f[2]), dir = SIMD3(f[3], f[4], f[5])
        for _ in 0..<Int(words[7])! {
            let err = assistant!.nextPosition(from: &pt, towards: &dir)
            emit("step \(err)" + p(" at", pt) + p(" toward", dir) + thresholds(assistant!))
        }
    case "centerline":
        // What FlyAssistant.swift does: the points, thinned, then smoothed.
        let a = assistant!
        let (err, points) = a.centerline(from: SIMD3(f[0], f[1], f[2]), to: SIMD3(f[3], f[4], f[5]))
        if err == 0 {
            emit("raw \(points.count)\n")
            for v in points { emit(p(" ", v) + "\n") }
        }
        centerline = err == 0 ? points : []
        if err == 0 && centerline.count > 2 {
            centerline = a.thinnedCenterlineIndices(centerline).map { centerline[$0] }
        }
        if err == 0 && words[7] == "1", let smoothed = FlyPathAssistant.smoothedCenterline(centerline, stepLength: a.centerlineResampleStepLength,
                                                                                         spline: NearestSpline()) {
            centerline = smoothed
        }
        emit("centerline \(err) points \(centerline.count)" + thresholds(a))
        for v in centerline { emit(p(" ", v) + "\n") }
        emit(distmapLine(a))
    case "radii":
        for i in centerline.indices {
            emit("radius \(h(assistant!.radius(at: centerline[i]))) mean \(h(assistant!.averageRadius(at: i, on: centerline, range: 2))) \(h(assistant!.averageRadius(at: i, on: centerline, range: 5)))\n")
        }
    case "views":
        let n = Int(words[1])!, count = centerline.count, stride = count / 12 > 0 ? count / 12 : 1
        var i = 0
        while i + n < count {
            emit(p("view", assistant!.maximizingViewDirection(from: centerline[i], lookingAt: centerline[i + n])) + "\n")
            i += stride
        }
    case "center":
        if let c = assistant!.nextCenterPoint(from: SIMD3(f[0], f[1], f[2]), towards: SIMD3(f[3], f[4], f[5]), stepLength: f[6]) {
            emit(p("center", c) + "\n")
        } else {
            emit("center none\n")
        }
    case "trace":
        emit("trace \(assistant!.traceLine(from: SIMD3(f[0], f[1], f[2]), along: SIMD3(f[3], f[4], f[5])))\n")
    case "transform":
        assistant!.threshold = f[0]
        assistant!.distanceTransform()
        emit(distmapLine(assistant!))
    default:
        break
    }
}
FileHandle.standardOutput.write(out.data(using: .utf8)!)
'''


def run(command, **kw):
    return subprocess.run(command, capture_output=True, text=True, **kw)


# FlyPathAssistant.computeLumenThresholds after the histogram's interval: the voxels around the points given
# (inputNeighborhood, a value that is not a number left out), their lower median and the lower median of their
# deviations from it; the margin, three deviations but no more than the interval's width; the interval, when pixVal
# lies in it or within the margin of it, widened to hold pixVal give or take the margin. Each operation on its own
# line, as the module rounds it (std::min, as Swift's min, gives the first value unless the second is smaller).
LUMEN_THRESHOLDS = r'''#include <algorithm>
#include <vector>
static void appendInputNeighborhood(const float *input, int width, int height, int depth, int x, int y, int z,
                                    std::vector<float> &values)
{
    for (int i = -1; i < 2; ++i) {
        for (int j = -1; j < 2; ++j) {
            for (int k = -1; k < 2; ++k) {
                long vx = (long)x + i, vy = (long)y + j, vz = (long)z + k;
                if (vx < 0 || vx >= width || vy < 0 || vy >= height || vz < 0 || vz >= depth)
                    continue;
                float value = input[(vz * height + vy) * width + vx];
                if (value == value)
                    values.push_back(value);
            }
        }
    }
}

static float lumenValue(std::vector<float> values, float mean)
{
    if (values.empty())
        return mean;
    std::sort(values.begin(), values.end());
    return values[(values.size() - 1) / 2];
}

static void holdLumenThresholds(float pixVal, std::vector<float> values, float &thresholdA, float &thresholdB)
{
    if (values.empty())
        return;
    std::sort(values.begin(), values.end());
    float median = values[(values.size() - 1) / 2];
    std::vector<float> deviations;
    for (float value : values)
        deviations.push_back(fabsf(value - median));
    std::sort(deviations.begin(), deviations.end());
    float spread = 3.0f * deviations[(deviations.size() - 1) / 2];
    float width = thresholdB - thresholdA;
    float margin = std::min(spread, width);
    float below = thresholdA - margin;
    float above = thresholdB + margin;
    if (!(below <= pixVal && pixVal <= above))
        return;
    float low = pixVal - margin;
    float high = pixVal + margin;
    if (low < thresholdA)
        thresholdA = low;
    if (high > thresholdB)
        thresholdB = high;
}

'''

# The changes made in FlyAssistant.mm's text, each found there once: what it is, the original, the correction.
TEXT_CORRECTIONS = [
    # The searches meet on a voxel the other one has settled (labelled and optimized), not on one it has only reached.
    ('the searches\' meeting condition',
     'if ((labelmap[neighborindex]&LABELBITSMASK) && (labelmap[neighborindex]&LABELBITSMASK)!=currentlabel) {',
     'if ((labelmap[neighborindex]&LABELBITSMASK) && (labelmap[neighborindex]&LABELBITSMASK)!=currentlabel'
     ' && (labelmap[neighborindex]&OPTIMIZED)) {'),
    # The thresholds sample the input around the voxel nearest to each point (lroundf, as Swift's rounded()).
    ('the voxel of a step\'s thresholds',
     'int inputX = pt.x, inputY = pt.y, inputZ = pt.z;',
     'int inputX = (int)lroundf(pt.x), inputY = (int)lroundf(pt.y), inputZ = (int)lroundf(pt.z);'),
    ('the voxel of A\'s thresholds',
     'addInputNeighborhood(input, inputWidth, inputHeight, inputDepth, pta.x, pta.y, pta.z, pixVal, count);',
     'addInputNeighborhood(input, inputWidth, inputHeight, inputDepth, (int)lroundf(pta.x), (int)lroundf(pta.y), '
     '(int)lroundf(pta.z), pixVal, count);'),
    ('the voxel of B\'s thresholds',
     'addInputNeighborhood(input, inputWidth, inputHeight, inputDepth, ptb.x, ptb.y, ptb.z, pixVal, count);',
     'addInputNeighborhood(input, inputWidth, inputHeight, inputDepth, (int)lroundf(ptb.x), (int)lroundf(ptb.y), '
     '(int)lroundf(ptb.z), pixVal, count);'),
    # The interval holds pixVal give or take three median absolute deviations of the voxels around the points, no
    # more than its width: the functions, then a call after each of the two computations of the thresholds.
    ('the voxels\' neighbourhood',
     'static void addInputNeighborhood(const float *input, int width, int height, int depth, int x, int y, int z,',
     LUMEN_THRESHOLDS +
     'static void addInputNeighborhood(const float *input, int width, int height, int depth, int x, int y, int z,'),
    ('the thresholds of a step',
     'pixVal /= count;\n        [self computeIntervalThresholdsFrom:pixVal];',
     'pixVal /= count;\n'
     '        { std::vector<float> values;\n'
     '          appendInputNeighborhood(input, inputWidth, inputHeight, inputDepth, inputX, inputY, inputZ, values);\n'
     '          if (count) pixVal = lumenValue(values, pixVal);\n'
     '          [self computeIntervalThresholdsFrom:pixVal];\n'
     '          holdLumenThresholds(pixVal, values, thresholdA, thresholdB); }'),
    ('the thresholds of a centerline',
     '[self computeIntervalThresholdsFrom:pixVal];\n    NSLog(@"Opt. thresholds',
     '{ std::vector<float> values;\n'
     '      appendInputNeighborhood(input, inputWidth, inputHeight, inputDepth, (int)lroundf(pta.x), (int)lroundf(pta.y), '
     '(int)lroundf(pta.z), values);\n'
     '      appendInputNeighborhood(input, inputWidth, inputHeight, inputDepth, (int)lroundf(ptb.x), (int)lroundf(ptb.y), '
     '(int)lroundf(ptb.z), values);\n'
     '      pixVal = lumenValue(values, pixVal);\n'
     '      [self computeIntervalThresholdsFrom:pixVal];\n'
     '      holdLumenThresholds(pixVal, values, thresholdA, thresholdB); }\n'
     '    NSLog(@"Opt. thresholds'),
    # The seeds are planted within the volume along each axis, as the search goes on: the linear index alone let a
    # point of a face plant its neighbours at the other end of the row, of the slice or of the volume before.
    ('the seeds\' neighbours',
     'if( neighborindex < distmapVolumeSize && neighborindex >= 0)',
     'if( x+dx >= 0 && x+dx < distmapWidth && y+dy >= 0 && y+dy < distmapHeight && z+dz >= 0 && z+dz < distmapDepth)'),
] + [
    # The resampled voxels an axis holds, a quotient within a thousandth of a whole number counting as that number.
    (f'the resampled {axis}',
     f'\tdistmap{name} = (float)input{name}*inputSpacing_{axis}/vsize;',
     f'\tdistmap{name} = (float)input{name}*inputSpacing_{axis}/vsize + 0.001f;')
    for name, axis in (('Width', 'x'), ('Height', 'y'), ('Depth', 'z'))
]


def corrected_reference(text):
    """FlyAssistant.mm with the corrections made in its text."""
    for what, original, corrected in TEXT_CORRECTIONS:
        if text.count(original) != 1:
            print('FAIL: FlyAssistant.mm at ' + reference[:12] + ' does not have ' + what + ' once')
            raise SystemExit(1)
        text = text.replace(original, corrected)
    return text


def build_old(tmp, optimization):
    swift_opt, c_opt = ('-Onone', '-O0') if optimization == 'debug' else ('-O', '-Os')
    out = tmp / f'old-{optimization}'
    out.mkdir()
    for path in OLD_SWIFT + OLD_HEADERS + [p for _, _, p in OLD_OBJC]:
        source = history_reference.show(reference, path)
        if path == FLY:
            source = corrected_reference(source.decode('utf-8', 'surrogateescape')).encode('utf-8', 'surrogateescape')
        (out / Path(path).name).write_bytes(source)
    (out / 'bridging.h').write_text('#define HOROS_BRIDGING_HEADER 1\n#import <Cocoa/Cocoa.h>\n'
                                    '#import "Point3D.h"\n#import "OSIVoxel.h"\n')
    (out / 'Spline3D.h').write_text(SPLINE_STAND_IN)
    (out / 'driver.mm').write_text(OLD_DRIVER)
    steps = [['xcrun', 'swiftc', '-swift-version', '5', '-module-name', 'Horos', '-parse-as-library', '-wmo', swift_opt,
              '-import-objc-header', str(out / 'bridging.h'), '-Xcc', '-I' + str(out),
              '-emit-objc-header-path', str(out / 'Horos-Swift.h'),
              '-c', *[str(out / Path(p).name) for p in OLD_SWIFT], '-o', str(out / 'swift.o')]]
    objects = [str(out / 'swift.o')]
    for name, language, _ in OLD_OBJC + [('driver.mm', 'objective-c++', None)]:
        obj = out / (Path(name).stem + '.o')
        std = ['-std=c++17'] if language == 'objective-c++' else []
        steps.append(['xcrun', 'clang', '-x', language, *std, '-fno-objc-arc', c_opt, '-w',
                      '-include', 'Cocoa/Cocoa.h', '-I', str(out), '-c', str(out / name), '-o', str(obj)])
        objects.append(str(obj))
    steps.append(['xcrun', 'swiftc', *objects, '-lc++', '-framework', 'Cocoa', '-framework', 'Accelerate',
                  '-framework', 'QuartzCore', '-o', str(out / 'driver')])
    for step in steps:
        built = run(step, timeout=600)
        if built.returncode:
            print('FAIL: the reference does not build:\n' + built.stderr[-3000:])
            raise SystemExit(1)
    return out / 'driver'


def build_new(tmp, optimization):
    out = tmp / f'new-{optimization}'
    out.mkdir()
    (out / 'main.swift').write_text(NEW_DRIVER)
    # Debug runs under AddressSanitizer: no read outside the volume, the map or the histogram.
    built = run(['xcrun', 'swiftc', '-swift-version', '6', '-module-name', 'FlyPathDriver',
                 *(['-Onone', '-sanitize=address'] if optimization == 'debug' else ['-O']),
                 *[str(MODULE / name) for name in MODULE_FILES], str(out / 'main.swift'), '-o', str(out / 'driver')],
                timeout=600)
    if built.returncode:
        print('FAIL: the module does not build with the driver:\n' + built.stderr[-3000:])
        raise SystemExit(1)
    return out / 'driver'


def blocks(lines, header):
    """The points after each `header N` line, with the size and the scale of the resampled volume they belong to."""
    found, volume, i = [], None, 0
    while i < len(lines):
        words = lines[i].split()
        if words and words[0] == 'resampled':
            volume = ([int(word) for word in words[1:4]], [float.fromhex(word) for word in words[5:8]])
        elif len(words) == 2 and words[0] == header:
            count = int(words[1])
            found.append((volume, [[float.fromhex(word) for word in line.split()[-3:]]
                                   for line in lines[i + 1:i + 1 + count]]))
            i += count
        i += 1
    return found


def half_voxel_problems(reference_lines, module_lines):
    """Where the module's centerlines, as the search gives them, leave FlyAssistant.mm's by more than half a
    resampled voxel: each point lies within half a voxel, along each axis, of the centre of the voxel whose
    corner the original gave, and the points between the ends at that centre, half a voxel from the corner.
    A search from a point on the volume's edge plants neighbours across the edge, in the next row or slice, as
    the original did; the original's corner for that end, read back from those steps, may then lie outside the
    volume, and that end is left out (the module's end is the point given, which the lines compare)."""
    corners, raws = blocks(reference_lines, 'corners'), blocks(module_lines, 'raw')
    if len(corners) != len(raws):
        return [f'{len(raws)} centerlines for the original\'s {len(corners)}']
    problems = []
    for number, (((size, scale), original), (_, points)) in enumerate(zip(corners, raws), 1):
        if len(original) != len(points):
            problems.append(f'centerline {number}: {len(points)} points for the original\'s {len(original)}')
            continue
        for index, (corner, point) in enumerate(zip(original, points)):
            end = index in (0, len(points) - 1)
            if end and not all(0 <= corner[axis] * scale[axis] < size[axis] for axis in range(3)):
                continue
            for axis in range(3):
                half = 0.5 / scale[axis]
                off = abs(point[axis] - corner[axis] - half)
                if off > (half if end else 0) + 1e-3 * half:
                    problems.append(f'centerline {number}, point {index} of {len(points)}: {point} lies '
                                    f'{off / (2 * half):.3f} voxel along {"xyz"[axis]} from the centre of the '
                                    f'original\'s voxel, whose corner is {corner}')
                    break
            if len(problems) >= 5:
                return problems
    return problems


failures = []
with tempfile.TemporaryDirectory(prefix='isix-fly-path-') as folder:
    tmp = Path(folder)
    for name, (*_, data) in VOLUMES.items():
        (tmp / f'{name}.raw').write_bytes(data)
    (tmp / 'plan.txt').write_text('\n'.join(PLAN) + '\n')
    outputs = {}
    for optimization in ('debug', 'release'):
        for side, build in (('reference', build_old), ('module', build_new)):
            driver = build(tmp, optimization)
            try:
                ran = subprocess.run([str(driver), str(tmp / 'plan.txt')], capture_output=True, text=True, timeout=300,
                                     env={**os.environ, 'ASAN_OPTIONS': 'detect_leaks=0'})
            except subprocess.TimeoutExpired:
                print(f'FAIL: the {side} driver ({optimization}) did not finish within 300 s')
                raise SystemExit(1)
            if ran.returncode:
                print(f'FAIL: the {side} driver ({optimization}) exited with {ran.returncode} after:\n' +
                      '\n'.join(ran.stdout.splitlines()[-4:]) + '\n' + ran.stderr[-1000:])
                raise SystemExit(1)
            # The reference prints A and B on std::cout; only the plan's lines count.
            outputs[side, optimization] = [line for line in ran.stdout.splitlines() if not line.startswith('x= ')]
        # The original's corners are the reference's alone: the module's points are held to them by half a voxel.
        old = [line for line in outputs['reference', optimization] if not line.startswith('corner')]
        new = outputs['module', optimization]
        failures += [f'{optimization}: {problem}'
                     for problem in half_voxel_problems(outputs['reference', optimization], new)]
        if old != new:
            first = next((i for i, (a, b) in enumerate(zip(old, new)) if a != b), min(len(old), len(new)))
            failures.append(f'{optimization}: line {first + 1} differs (of {len(old)} and {len(new)} lines)\n'
                            f'  reference: {old[first] if first < len(old) else "(end)"}\n'
                            f'  module:    {new[first] if first < len(new) else "(end)"}')
        else:
            lines = old
            print(f'ok: {optimization}: {len(lines)} lines the same; '
                  f'{sum(l.startswith("centerline ") for l in lines)} centerlines '
                  f'({sum(int(l.split()[1]) for l in lines if l.startswith("raw "))} points within half a voxel), '
                  f'{sum(l.startswith("thresholds") for l in lines)} thresholds, '
                  f'{sum(l.startswith("step ") for l in lines)} steps, {sum(l.startswith("view") for l in lines)} views, '
                  f'{sum(l.startswith("distmap") for l in lines)} distance maps, '
                  f'{sum(l.startswith("radius") for l in lines)} radii')
    if not failures and outputs['reference', 'debug'] != outputs['reference', 'release']:
        print('note: the reference itself differs between Debug and Release')

for failure in failures:
    print('FAIL:', failure)
if failures:
    raise SystemExit(1)
print('PASS: FlyPathAssistant gives the histogram, thresholds, distance maps, centerlines, steps, radii and view '
      'directions of FlyAssistant.mm (reference ' + reference[:12] + ') with its seven corrections, bit for bit, and '
      'its centerlines within half a voxel of the original\'s points, in Debug and Release')
