#!/usr/bin/env python3
"""-[FlyAssistant createCenterline:FromPointA:ToPointB:withSmoothing:] leaves
the caller's points where they were.

The method clamped pta and ptb to the volume and converted them to resample
coordinates in place, with -converPoint2ResampleCoordinate:, and nothing
converted them back. The endoscopy's Path Assistant keeps its point A from
one search to the next (only B is set again at each click), so with a
resample scale other than 1 the second search started from an A scaled twice,
away from the point marked.

The harness compiles the real FlyAssistant.mm, FlyAssistant+Histo.mm,
Quaternion.mm, N3Geometry.m, Point3D.swift and OSIVoxel.swift, with a
subclass whose -computeIntervalThresholdsFrom: sets fixed thresholds (the
histogram search is not what is tested). Spline3D, which needs VTK and only
smooths a centerline found, is a stand-in that the searches, run without
smoothing, never call. The volume is 20 x 20 x 128 voxels of 0.5 mm,
resampled at 1 mm (a scale of 0.5 on each axis), all wall but for a straight
tube along z. (The distance transform works on blocks of 32 resampled
slices, so the volume has 64 of them.)

- same-start: two searches in a row from the same A and B leave A and B as
  they were given, and find the same centerline, whose ends lie near A and B.

The distance transform's -distanceTransformWithThreshold: ran
dispatch_apply(distmapDepth/SLICES1BLOCK, ...), whole blocks only, so the
slices after the last full block of 32 kept the 3.4e38 of -thresholdImage,
and a volume of fewer than 32 resampled slices had no transform at all.
And -caculateNextPositionFrom:Towards: left pt and dir in resample
coordinates when it returned ERROR_CANNOTFINDPATH, where its other returns
give them back in input coordinates.

- distance-transform: in volumes of 20 (fewer than 32), 44 (a block and 12)
  and 64 (two blocks) resampled slices, no voxel inside the volume's border
  keeps 3.4e38, and the tube's center has the same distance near its far end
  as in its middle.
- short-centerline: in the volume of 20 resampled slices, a search from A to
  B finds a centerline of more than one point, from near A to near B.
- cannot-find-path: -caculateNextPositionFrom:Towards: from a point in the
  wall, looking into the wall, returns ERROR_CANNOTFINDPATH and leaves the
  point and the direction as they were given.

-[FlyAssistant createCenterline:...] set its thresholds from the mean of the
voxels around A and B, but its triple loop added each offset to posA and posB
without going back to A and B, so it sampled voxels up to 9 columns, 3 rows
and a slice away, and read before the volume when A or B lay near its start;
-caculateNextPositionFrom:Towards:, before the distance transform was done,
did the same around pt, and indexed the input with pt already in resample
coordinates. The probe records the value the thresholds are computed
from, and the harness is built with AddressSanitizer, so a read outside the
volume stops the case.

- threshold-samples: with A and B in the tube, whose voxels around them are
  all 1000, the thresholds come from 1000.
- threshold-border: in a volume all 1000, with A and B in opposite corners,
  the thresholds come from 1000 (the mean of the voxels inside the volume)
  and no read falls outside it.
- unfinished-transform-samples: -caculateNextPositionFrom:Towards: before the
  distance transform, from a point in the tube given in input coordinates,
  takes its thresholds from 1000.

`<git revision>` as an optional argument reads the sources from that
revision, the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def source(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'])
    return (root / path).read_bytes()


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, clang)', file=sys.stderr)
    sys.exit(SKIPPED)

SWIFT = ['Horos/Sources/Point3D.swift', 'Horos/Sources/OSIVoxel.swift']
HEADERS = ['Horos/Sources/Point3D.h', 'Horos/Sources/OSIVoxel.h', 'Horos/Sources/Quaternion.h',
           'Horos/Sources/FlyAssistant.h', 'Horos/Sources/FlyAssistant+Histo.h', 'Nitrogen/Sources/N3Geometry.h']
OBJC = [('N3Geometry.m', 'objective-c', 'Nitrogen/Sources/N3Geometry.m'),
        ('Quaternion.mm', 'objective-c++', 'Horos/Sources/Quaternion.mm'),
        ('FlyAssistant+Histo.mm', 'objective-c++', 'Horos/Sources/FlyAssistant+Histo.mm'),
        ('FlyAssistant.mm', 'objective-c++', 'Horos/Sources/FlyAssistant.mm')]

# The smoothing's spline, with the selectors FlyAssistant.mm calls; the harness
# does not smooth, so its methods fail the case if they run. The real header
# brings <iostream> in through VTK, and FlyAssistant.mm writes to std::cout.
SPLINE_STAND_IN = '''#import <Cocoa/Cocoa.h>
#import "Point3D.h"
#include <iostream>
@interface Spline3D : NSObject
- (void) addPoint:(float)t :(Point3D*)p;
- (Point3D*) evaluateAt:(float)t;
@end
'''

MAIN = rb'''
#import <Cocoa/Cocoa.h>
#import "FlyAssistant.h"
#import "Spline3D.h"
#include <math.h>

static int failures = 0;
#define CHECK(c, ...) do { if (!(c)) { printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); failures++; } } while (0)

enum { W = 20, H = 20, D = 128 };

@implementation Spline3D
- (void) addPoint:(float)t :(Point3D*)p { CHECK(NO, "the centerline was smoothed"); }
- (Point3D*) evaluateAt:(float)t { CHECK(NO, "the centerline was smoothed"); return [Point3D point]; }
@end

// The tube is 1000, the wall 0; the thresholds take the tube. The value the
// assistant computes them from is kept, the first one in firstPixValue.
static float firstPixValue = NAN, lastPixValue = NAN;
@interface FlyCenterlineProbe : FlyAssistant
@end
@implementation FlyCenterlineProbe
- (void) computeIntervalThresholdsFrom:(float)pixValue {
    if (isnan(firstPixValue)) firstPixValue = pixValue;
    lastPixValue = pixValue;
    thresholdA = 500; thresholdB = 1500;
}
- (int) width { return distmapWidth; }
- (int) height { return distmapHeight; }
- (int) depth { return distmapDepth; }
- (float) distanceAtX:(int)x y:(int)y z:(int)z { return distmap[z*distmapImageSize + y*distmapWidth + x]; }
@end

static BOOL same(Point3D *p, float x, float y, float z) { return p.x == x && p.y == y && p.z == z; }
static float distance(OSIVoxel *v, Point3D *p) {
    return sqrtf((v.x-p.x)*(v.x-p.x) + (v.y-p.y)*(v.y-p.y) + (v.z-p.z)*(v.z-p.z));
}

// W x H x depth voxels of 0.5 mm, all wall but for a tube along z (or all tube,
// if uniform), resampled at 1 mm; the caller frees *volume after releasing the
// assistant.
static FlyCenterlineProbe *makeAssistant(int depth, float **volume, BOOL uniform = NO) {
    float *v = (float *)malloc(sizeof(float) * W * H * depth);
    for (int z = 0; z < depth; z++)
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++)
                v[(z*H + y)*W + x] = (uniform || (x >= 6 && x < 14 && y >= 6 && y < 14 && z >= 4 && z < depth-4)) ? 1000 : 0;
    *volume = v;
    int dim[3] = {W, H, depth};
    float spacing[3] = {0.5, 0.5, 0.5};
    FlyCenterlineProbe *assistant = [[FlyCenterlineProbe alloc] initWithVolume:v WidthDimension:dim Spacing:spacing ResampleVoxelSize:1];
    CHECK(assistant != nil, "the assistant of %d slices did not initialize", depth);
    return assistant;
}

static void sameStart() {
    float *volume;
    FlyCenterlineProbe *assistant = makeAssistant(D, &volume);
    if (!assistant) { free(volume); return; }

    Point3D *a = [Point3D pointWithX:10 y:10 z:12];
    Point3D *b = [Point3D pointWithX:10 y:10 z:115];
    NSMutableArray *first = [NSMutableArray array], *second = [NSMutableArray array];

    int err1 = [assistant createCenterline:first FromPointA:a ToPointB:b withSmoothing:NO];
    CHECK(err1 == 0, "the first search returned %d", err1);
    CHECK(same(a, 10, 10, 12), "after the first search A is (%g, %g, %g), not (10, 10, 12)", a.x, a.y, a.z);
    CHECK(same(b, 10, 10, 115), "after the first search B is (%g, %g, %g), not (10, 10, 115)", b.x, b.y, b.z);

    int err2 = [assistant createCenterline:second FromPointA:a ToPointB:b withSmoothing:NO];
    CHECK(err2 == 0, "the second search returned %d", err2);
    CHECK(same(a, 10, 10, 12), "after the second search A is (%g, %g, %g), not (10, 10, 12)", a.x, a.y, a.z);

    CHECK(first.count > 1 && first.count == second.count, "the searches found %lu and %lu points",
          (unsigned long)first.count, (unsigned long)second.count);
    if (first.count > 1 && first.count == second.count) {
        for (NSUInteger i = 0; i < first.count; i++) {
            OSIVoxel *p = first[i], *q = second[i];
            if (p.x != q.x || p.y != q.y || p.z != q.z) {
                CHECK(NO, "point %lu is (%g, %g, %g) in the first search and (%g, %g, %g) in the second",
                      (unsigned long)i, p.x, p.y, p.z, q.x, q.y, q.z);
                break;
            }
        }
        OSIVoxel *head = first.firstObject, *tail = first.lastObject;
        float ends = fminf(distance(head, a) + distance(tail, b), distance(head, b) + distance(tail, a));
        CHECK(ends < 6, "the centerline runs from (%g, %g, %g) to (%g, %g, %g), not from A to B",
              head.x, head.y, head.z, tail.x, tail.y, tail.z);
        printf("%lu points from (%g, %g, %g) to (%g, %g, %g) in both searches; A (%g, %g, %g)\n",
               (unsigned long)first.count, head.x, head.y, head.z, tail.x, tail.y, tail.z, a.x, a.y, a.z);
    }
    [assistant release];
    free(volume);
}

static void distanceTransform() {
    int depths[3] = {40, 88, D};   // 20, 44 and 64 resampled slices
    for (int n = 0; n < 3; n++) {
        float *volume;
        FlyCenterlineProbe *assistant = makeAssistant(depths[n], &volume);
        if (!assistant) { free(volume); continue; }
        [assistant computeIntervalThresholdsFrom:1000];
        [assistant distanceTransformWithThreshold:nil];
        int w = [assistant width], h = [assistant height], d = [assistant depth];
        long untouched = 0; int firstZ = -1;
        for (int z = 1; z < d-1; z++)
            for (int y = 1; y < h-1; y++)
                for (int x = 1; x < w-1; x++)
                    if ([assistant distanceAtX:x y:y z:z] > 1e30) { untouched++; if (firstZ < 0) firstZ = z; }
        CHECK(untouched == 0, "%d resampled slices: %ld voxels kept 3.4e38, the first in slice %d", d, untouched, firstZ);
        // The tube runs from resampled slice 2 to d-3; its center 4 slices from
        // the far end is as deep in the tube as in the middle.
        float middle = [assistant distanceAtX:w/2 y:h/2 z:d/2], end = [assistant distanceAtX:w/2 y:h/2 z:d-7];
        CHECK(middle > 0 && middle < 1e30 && middle == end,
              "%d resampled slices: the tube's center is at %g in slice %d and %g in slice %d", d, middle, d/2, end, d-7);
        printf("%d resampled slices: none left at 3.4e38; the tube's center at %g\n", d, middle);
        [assistant release];
        free(volume);
    }
}

static void shortCenterline() {
    float *volume;
    FlyCenterlineProbe *assistant = makeAssistant(40, &volume);
    if (!assistant) { free(volume); return; }
    Point3D *a = [Point3D pointWithX:10 y:10 z:10];
    Point3D *b = [Point3D pointWithX:10 y:10 z:30];
    NSMutableArray *line = [NSMutableArray array];
    int err = [assistant createCenterline:line FromPointA:a ToPointB:b withSmoothing:NO];
    CHECK(err == 0, "the search returned %d", err);
    CHECK(line.count > 1, "the search found %lu points", (unsigned long)line.count);
    if (line.count > 1) {
        OSIVoxel *head = line.firstObject, *tail = line.lastObject;
        float ends = fminf(distance(head, a) + distance(tail, b), distance(head, b) + distance(tail, a));
        CHECK(ends < 6, "the centerline runs from (%g, %g, %g) to (%g, %g, %g), not from A to B",
              head.x, head.y, head.z, tail.x, tail.y, tail.z);
        printf("%lu points from (%g, %g, %g) to (%g, %g, %g)\n", (unsigned long)line.count,
               head.x, head.y, head.z, tail.x, tail.y, tail.z);
    }
    [assistant release];
    free(volume);
}

static void cannotFindPath() {
    float *volume;
    FlyCenterlineProbe *assistant = makeAssistant(D, &volume);
    if (!assistant) { free(volume); return; }
    [assistant computeIntervalThresholdsFrom:1000];
    [assistant distanceTransformWithThreshold:nil];
    // In the wall beside the tube, looking across x: the cross-section there is
    // all wall.
    Point3D *pt = [Point3D pointWithX:1 y:10 z:60];
    Point3D *dir = [Point3D pointWithX:1 y:0 z:0];
    int err = [assistant caculateNextPositionFrom:pt Towards:dir];
    CHECK(err == ERROR_CANNOTFINDPATH, "the step returned %d, not ERROR_CANNOTFINDPATH", err);
    CHECK(same(pt, 1, 10, 60), "the point came back as (%g, %g, %g), not (1, 10, 60)", pt.x, pt.y, pt.z);
    CHECK(same(dir, 1, 0, 0), "the direction came back as (%g, %g, %g), not (1, 0, 0)", dir.x, dir.y, dir.z);
    printf("returned %d with the point at (%g, %g, %g) and the direction (%g, %g, %g)\n",
           err, pt.x, pt.y, pt.z, dir.x, dir.y, dir.z);
    [assistant release];
    free(volume);
}

// The thresholds of a search from A to B come from the voxels around them.
static void thresholdSamples(BOOL border) {
    float *volume;
    FlyCenterlineProbe *assistant = makeAssistant(D, &volume, border);
    if (!assistant) { free(volume); return; }
    Point3D *a = border ? [Point3D pointWithX:0 y:0 z:0] : [Point3D pointWithX:10 y:10 z:12];
    Point3D *b = border ? [Point3D pointWithX:W-1 y:H-1 z:D-1] : [Point3D pointWithX:10 y:10 z:115];
    NSMutableArray *line = [NSMutableArray array];
    firstPixValue = lastPixValue = NAN;
    int err = [assistant createCenterline:line FromPointA:a ToPointB:b withSmoothing:NO];
    CHECK(firstPixValue == 1000, "the thresholds came from %g, not from the 1000 around A and B", firstPixValue);
    printf("thresholds from %g around A (%g, %g, %g) and B (%g, %g, %g); the search returned %d\n",
           firstPixValue, a.x, a.y, a.z, b.x, b.y, b.z, err);
    [assistant release];
    free(volume);
}

// Before the distance transform, a step takes its thresholds from the voxels
// around its point, given in input coordinates.
static void unfinishedTransformSamples() {
    float *volume;
    FlyCenterlineProbe *assistant = makeAssistant(D, &volume);
    if (!assistant) { free(volume); return; }
    Point3D *pt = [Point3D pointWithX:10 y:10 z:60];
    Point3D *dir = [Point3D pointWithX:0 y:0 z:1];
    firstPixValue = lastPixValue = NAN;
    int err = [assistant caculateNextPositionFrom:pt Towards:dir];
    CHECK(firstPixValue == 1000, "the thresholds came from %g, not from the 1000 around (10, 10, 60)", firstPixValue);
    printf("thresholds from %g around (10, 10, 60); the step returned %d\n", firstPixValue, err);
    [assistant release];
    free(volume);
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 2) return 64;
    if (!strcmp(argv[1], "same-start")) sameStart();
    else if (!strcmp(argv[1], "distance-transform")) distanceTransform();
    else if (!strcmp(argv[1], "short-centerline")) shortCenterline();
    else if (!strcmp(argv[1], "cannot-find-path")) cannotFindPath();
    else if (!strcmp(argv[1], "threshold-samples")) thresholdSamples(NO);
    else if (!strcmp(argv[1], "threshold-border")) thresholdSamples(YES);
    else if (!strcmp(argv[1], "unfinished-transform-samples")) unfinishedTransformSamples();
    else { printf("FAIL: unknown case %s\n", argv[1]); return 64; }
    return failures ? 1 : 0;
} }
'''

CASES = [
    ('same-start', 'two searches from the same A and B leave them where they were and find the same centerline'),
    ('distance-transform', 'the distance transform reaches the slices after the last full block of 32'),
    ('short-centerline', 'a volume of fewer than 32 resampled slices gets a centerline from A to B'),
    ('cannot-find-path', 'caculateNextPositionFrom gives the point and direction back as they were on '
                         'ERROR_CANNOTFINDPATH'),
    ('threshold-samples', 'createCenterline takes its thresholds from the voxels around A and B'),
    ('threshold-border', 'createCenterline takes its thresholds from the voxels around A and B that lie in the '
                         'volume, with A and B in its corners, and reads none outside it'),
    ('unfinished-transform-samples', 'caculateNextPositionFrom, before the distance transform, takes its thresholds '
                                     'from the voxels around its point in input coordinates'),
]
# AddressSanitizer stops a case that reads outside the volume.
ASAN = ['-fsanitize=address']


def run(command):
    return subprocess.run(command, check=True, capture_output=True)


failures = []
with tempfile.TemporaryDirectory(prefix='horos-fly-centerline-915-') as tmp:
    tmp = Path(tmp)
    for path in SWIFT + HEADERS + [p for _, _, p in OBJC]:
        (tmp / Path(path).name).write_bytes(source(path))
    (tmp / 'bridging.h').write_text('#define HOROS_BRIDGING_HEADER 1\n#import <Cocoa/Cocoa.h>\n'
                                    '#import "Point3D.h"\n#import "OSIVoxel.h"\n')
    (tmp / 'Spline3D.h').write_text(SPLINE_STAND_IN)
    (tmp / 'main.mm').write_bytes(MAIN)
    try:
        run(['xcrun', 'swiftc', '-swift-version', '5', '-module-name', 'Horos', '-parse-as-library', '-wmo', '-g',
             '-sanitize=address',
             '-import-objc-header', str(tmp / 'bridging.h'), '-Xcc', '-I' + str(tmp),
             '-emit-objc-header-path', str(tmp / 'Horos-Swift.h'),
             '-c', *[str(tmp / Path(p).name) for p in SWIFT], '-o', str(tmp / 'swift.o')])
        objects = [str(tmp / 'swift.o')]
        for name, language, _ in OBJC + [('main.mm', 'objective-c++', None)]:
            obj = tmp / (Path(name).stem + '.o')
            std = ['-std=c++17'] if language == 'objective-c++' else []
            run(['xcrun', 'clang', '-x', language, *std, '-fno-objc-arc', '-g', '-Wno-deprecated-declarations', *ASAN,
                 '-include', 'Cocoa/Cocoa.h', '-I', str(tmp), '-c', str(tmp / name), '-o', str(obj)])
            objects.append(str(obj))
        run(['xcrun', 'swiftc', '-sanitize=address', *objects, '-lc++', '-framework', 'Cocoa', '-framework', 'Accelerate',
             '-framework', 'QuartzCore', '-o', str(tmp / 'harness')])
    except subprocess.CalledProcessError as e:
        print('FAIL: the harness did not build:', (e.stderr or b'').decode(errors='replace')[-3000:])
        sys.exit(1)

    for case, claim in CASES:
        try:
            result = subprocess.run([str(tmp / 'harness'), case], capture_output=True, text=True, timeout=120,
                                    env={**os.environ, 'ASAN_OPTIONS': 'detect_leaks=0:abort_on_error=0'})
        except subprocess.TimeoutExpired:
            failures.append(f'{claim}: timed out')
            continue
        lines = [line for line in result.stdout.splitlines() if line.strip()]
        asan = [line for line in result.stderr.splitlines() if 'AddressSanitizer' in line]
        if result.returncode == 0:
            print('ok:', claim, '-', '; '.join(line for line in lines if not line.startswith('x=')) or 'exit 0')
        else:
            detail = '; '.join(line[len('FAIL: '):] for line in lines if line.startswith('FAIL:')) or \
                (asan[0].strip() if asan else '') or (lines[-1] if lines else f'exit {result.returncode}')
            failures.append(f'{claim}: {detail}')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: createCenterline leaves the caller\'s A and B where they were, and two searches from them find '
      'the same centerline; the distance transform covers every slice; caculateNextPositionFrom gives its points '
      'back in input coordinates on every return; the thresholds come from the voxels around A, B or the step\'s '
      'point, inside the volume')
