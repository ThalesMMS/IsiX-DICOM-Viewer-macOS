#!/usr/bin/env python3
"""The Fly Assistant's view search covers +-45 degrees about the forward
direction, on a square grid, from a fixed origin, in one coordinate
system, one resampled voxel a step.

-[FlyAssistant computeMaximizingViewDirectionFrom:LookingAt:] turns the
direction to the next centerline point 45 degrees back about each of two
axes of the plane normal to it, then traces rays over a 31 x 31 grid
counted in steps of 3 degrees, keeping the direction that sees farthest.
Each step turned the direction by 1 degree only, so the grid covered the
30-degree corner from (-45, -45) to (-15, -15): it never traced the
forward direction, nor anything to the other side of it. And each ray was
turned from the previous one, about the same two fixed axes: such turns do
not add up, so even at 3 degrees a step the rays drifted off the grid
(looking along +x they reached only 21 degrees downward, and missed a
lumen 40 degrees down by 25).

Then: -traceLineFrom:accordingTo: walked the origin it was given, so
each ray started where the previous one had hit the wall, and the view
returned (ray + origin) carried that drift. The origin was converted to
resample coordinates and the direction was not, and the view went back to
the caller, who works in input voxels, in resample coordinates. The two
axes of the grid were not orthogonal (about 32 degrees apart looking along
(1, 2, 3)), so the grid was skewed. And each ray stepped the distance to the
next centerline point, stepping over walls thinner than that.

The methods are taken verbatim from FlyAssistant.mm (the scan, the trace,
the volume test and both coordinate conversions) and compiled with the real
Quaternion.mm, N3Geometry.m, Point3D.swift and OSIVoxel.swift into a probe
class with FlyAssistant's own instance variables. For the scan cases a
subclass's -traceLineFrom:accordingTo: records each direction traced and
answers the farthest view toward a chosen target, with a resample scale of
1:

- coverage: looking along +x, where the two axes are y and z, the 961 rays
  traced are the grid from -45 to 45 degrees by 3 in azimuth and in
  elevation, within 0.1 degree, so they reach 45 degrees on both sides of the
  forward direction and one is the forward direction.
- oblique: looking along (1, 2, 3), one direction traced passes within 1
  degree of the forward direction, and the scan reaches at least 44 degrees
  from it on both sides of each of its axes.
- square: looking along (1, 2, 3), (0, 0, 1) and (0, -5, 0.01), the rays make
  the same angles with the forward direction as looking along +x, within 0.1
  degree: the grid is square whichever way the path runs.
- best-view: with the open lumen straight ahead, 40 degrees to either side
  in azimuth or elevation, or 30 degrees on both, the view returned is the
  traced direction nearest to it, within 2.5 degrees (the grid is 3).

The other cases run the real trace on a synthetic distance map of 64 x 64 x
128 resampled voxels, all wall but for the lumen each case carves, with a
resample scale of (0.5, 0.5, 2):

- fixed-origin: every ray the scan traces starts at the centerline point in
  resample coordinates, and the trace leaves the origin it was given where
  it was.
- coordinates: the path runs 45 degrees up in the patient, (1, 0, 1) in
  resample coordinates and (2, 0, 0.5) in input voxels, and the only lumen
  is a thin tube 30 degrees farther up. The view returned, in input voxels,
  lies along that tube, within 2.5 degrees once in resample coordinates, as
  far from the centerline point as the next point is.
- ray-length: along a lumen with a 1-voxel wall 12 voxels ahead, the trace
  stops at the wall after 12 steps whatever the length of the direction
  given, 7 voxels or half a voxel.
- degenerate: a zero direction traces nothing and returns at once, and a
  next centerline point on the current one is returned as the view.

`<git revision>` as an optional argument reads the sources from that
revision, the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import re
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
           'Nitrogen/Sources/N3Geometry.h']
OBJC = [('N3Geometry.m', 'objective-c', 'Nitrogen/Sources/N3Geometry.m'),
        ('Quaternion.mm', 'objective-c++', 'Horos/Sources/Quaternion.mm')]

fly = source('Horos/Sources/FlyAssistant.mm')
METHODS = b''
for name in [rb'converPoint2ResampleCoordinate:', rb'converPoint2InputCoordinate:',
             rb'computeMaximizingViewDirectionFrom:', rb'traceLineFrom:', rb'point:\(Point3D \*\)p InVolumeX:']:
    found = re.search(rb'^- \([^)]*\) *' + name + rb'.*?(?=^- \(|^@end)', fly, re.S | re.M)
    if not found:
        print(f'FAIL: -{name.decode()} not found in FlyAssistant.mm')
        sys.exit(1)
    METHODS += found.group(0)

MAIN_HEAD = rb'''
#import <Cocoa/Cocoa.h>
#import "Point3D.h"
#import "OSIVoxel.h"
#import "Quaternion.h"
#include <math.h>
#include <string.h>
#include <algorithm>
#include <vector>

static int failures = 0;
#define CHECK(c, ...) do { if (!(c)) { printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); failures++; } } while (0)

static N3Vector unit(N3Vector v) { return N3VectorNormalize(v); }
static double degrees(N3Vector a, N3Vector b) {
    double c = N3VectorDotProduct(unit(a), unit(b));
    return acos(fmax(-1.0, fmin(1.0, c))) * 180.0 / M_PI;
}

// FlyAssistant's view search: its own instance variables, and its methods verbatim.
@interface FlyProbe : NSObject {
@public
    float* distmap;
    int distmapWidth,distmapHeight,distmapDepth;
    int distmapImageSize;
    float resampleScale_x;
    float resampleScale_y;
    float resampleScale_z;
}
- (void) converPoint2ResampleCoordinate:(Point3D*)pt;
- (void) converPoint2InputCoordinate:(Point3D*)pt;
- (OSIVoxel*) computeMaximizingViewDirectionFrom:(OSIVoxel*) center LookingAt:(OSIVoxel*) direction;
- (unsigned int) traceLineFrom:(Point3D *) center accordingTo:(Point3D *) direction;
- (BOOL) point:(Point3D *)p InVolumeX:(int)x Y:(int)y Z:(int)z;
@end

@implementation FlyProbe
- (id) init {
    self = [super init];
    resampleScale_x = resampleScale_y = resampleScale_z = 1;
    return self;
}
- (void) dealloc { free(distmap); [super dealloc]; }
'''

MAIN_TAIL = rb'''
@end

// The scan with the volume replaced by a target direction.
@interface FlyScanProbe : FlyProbe {
@public
    std::vector<N3Vector> traced;
    N3Vector target;
}
@end

@implementation FlyScanProbe
- (unsigned int) traceLineFrom:(Point3D *) center accordingTo:(Point3D *) direction
{
    N3Vector d = N3VectorMake(direction.x, direction.y, direction.z);
    traced.push_back(d);
    // Farther the nearer the direction is to the target, and always > 0.
    return (unsigned int) llround(1e6 * (2.0 + N3VectorDotProduct(unit(d), unit(target))));
}
@end

// The real trace, recording where each ray starts and whether the trace moves it.
@interface FlyTraceProbe : FlyProbe {
@public
    std::vector<N3Vector> starts;
    int moved;
}
@end

@implementation FlyTraceProbe
- (unsigned int) traceLineFrom:(Point3D *) center accordingTo:(Point3D *) direction
{
    N3Vector before = N3VectorMake(center.x, center.y, center.z);
    starts.push_back(before);
    unsigned int d = [super traceLineFrom:center accordingTo:direction];
    if (N3VectorDistance(before, N3VectorMake(center.x, center.y, center.z)) > 1e-4) moved++;
    return d;
}
@end

static N3Vector rotated(N3Vector v, N3Vector axis, double deg) {
    double r = deg * M_PI / 180, c = cos(r), s = sin(r);
    N3Vector k = unit(axis);
    N3Vector kxv = N3VectorCrossProduct(k, v);
    double kv = N3VectorDotProduct(k, v);
    return N3VectorMake(v.x * c + kxv.x * s + k.x * kv * (1 - c),
                        v.y * c + kxv.y * s + k.y * kv * (1 - c),
                        v.z * c + kxv.z * s + k.z * kv * (1 - c));
}

static OSIVoxel *C;

static FlyScanProbe *scan(N3Vector forward, N3Vector target, N3Vector *view) {
    FlyScanProbe *probe = [[[FlyScanProbe alloc] init] autorelease];
    probe->target = target;
    OSIVoxel *next = [[[OSIVoxel alloc] initWithX:C.x + forward.x y:C.y + forward.y z:C.z + forward.z value:nil] autorelease];
    OSIVoxel *best = [probe computeMaximizingViewDirectionFrom:C LookingAt:next];
    if (view) *view = N3VectorMake(best.x - C.x, best.y - C.y, best.z - C.z);
    return probe;
}

// Signed angle of v from forward, about axis (right-handed), in the plane normal to axis.
static double about(N3Vector v, N3Vector forward, N3Vector axis) {
    N3Vector k = unit(axis);
    N3Vector f = N3VectorSubtract(forward, N3VectorScalarMultiply(k, N3VectorDotProduct(forward, k)));
    N3Vector p = N3VectorSubtract(v, N3VectorScalarMultiply(k, N3VectorDotProduct(v, k)));
    f = unit(f); p = unit(p);
    return atan2(N3VectorDotProduct(k, N3VectorCrossProduct(f, p)), N3VectorDotProduct(f, p)) * 180 / M_PI;
}

static void extent(FlyScanProbe *probe, N3Vector forward, N3Vector axis, const char *name) {
    double lo = 1e9, hi = -1e9;
    for (const N3Vector &v : probe->traced) { double a = about(v, forward, axis); lo = fmin(lo, a); hi = fmax(hi, a); }
    CHECK(lo <= -44 && hi >= 44, "about %s the scan covers %.1f to %.1f degrees, not -45 to 45", name, lo, hi);
    printf("about %s: %.1f to %.1f degrees\n", name, lo, hi);
}

static double nearest(FlyScanProbe *probe, N3Vector forward) {
    double m = 1e9;
    for (const N3Vector &v : probe->traced) m = fmin(m, degrees(v, forward));
    return m;
}

static void coverage(void) {
    N3Vector forward = N3VectorMake(7, 0, 0);
    FlyScanProbe *probe = scan(forward, forward, NULL);
    CHECK(probe->traced.size() == 31 * 31, "%zu rays traced, not 961", probe->traced.size());
    // The two axes FlyAssistant picks for +x are y and z.
    extent(probe, forward, N3VectorMake(0, 0, 1), "z (azimuth)");
    extent(probe, forward, N3VectorMake(0, 1, 0), "y (elevation)");
    double m = nearest(probe, forward);
    CHECK(m < 1, "the nearest ray is %.1f degrees from the forward direction", m);
    // Every node of the grid, -45 to 45 by 3 in azimuth and in elevation, has its ray.
    int missing = 0, first[2] = {0, 0};
    for (int el = -45; el <= 45; el += 3) for (int az = -45; az <= 45; az += 3) {
        BOOL hit = NO;
        for (const N3Vector &v : probe->traced) {
            N3Vector u = unit(v);
            double a = atan2(u.y, u.x) * 180 / M_PI, e = asin(u.z) * 180 / M_PI;
            if (fabs(a - az) < 0.1 && fabs(e - el) < 0.1) { hit = YES; break; }
        }
        if (!hit && !missing++) { first[0] = az; first[1] = el; }
    }
    CHECK(missing == 0, "%d of the 961 grid nodes have no ray, the first at azimuth %d, elevation %d",
          missing, first[0], first[1]);
    printf("%zu rays, %d grid nodes missing, nearest %.2f degrees from forward\n", probe->traced.size(), missing, m);
}

static void oblique(void) {
    N3Vector forward = N3VectorMake(1, 2, 3);
    FlyScanProbe *probe = scan(forward, forward, NULL);
    CHECK(probe->traced.size() == 31 * 31, "%zu rays traced, not 961", probe->traced.size());
    // (-2, 1, 0) is normal to (1, 2, 3), and so is its cross product with (1, 2, 3).
    N3Vector a = N3VectorMake(-2, 1, 0);
    extent(probe, forward, a, "(-2, 1, 0)");
    extent(probe, forward, N3VectorCrossProduct(forward, a), "(1, 2, 3) x (-2, 1, 0)");
    double m = nearest(probe, forward);
    CHECK(m < 1, "the nearest ray is %.1f degrees from the forward direction", m);
    printf("nearest %.2f degrees from forward\n", m);
}

static std::vector<double> anglesFrom(FlyScanProbe *probe, N3Vector forward) {
    std::vector<double> angles;
    for (const N3Vector &v : probe->traced) angles.push_back(degrees(v, forward));
    std::sort(angles.begin(), angles.end());
    return angles;
}

static void square(void) {
    N3Vector x = N3VectorMake(7, 0, 0);
    std::vector<double> reference = anglesFrom(scan(x, x, NULL), x);
    N3Vector forwards[] = { N3VectorMake(1, 2, 3), N3VectorMake(0, 0, 1), N3VectorMake(0, -5, 0.01) };
    for (const N3Vector &forward : forwards) {
        std::vector<double> angles = anglesFrom(scan(forward, forward, NULL), forward);
        double worst = angles.size() == reference.size() ? 0 : 1e9;
        for (size_t i = 0; i < angles.size() && i < reference.size(); i++) worst = fmax(worst, fabs(angles[i] - reference[i]));
        CHECK(worst < 0.1, "looking along (%g, %g, %g) the rays' angles with it are up to %.1f degrees off those "
              "looking along +x (farthest ray %.1f degrees out, against %.1f)", forward.x, forward.y, forward.z, worst,
              angles.empty() ? 0.0 : angles.back(), reference.back());
        printf("(%g, %g, %g): %zu rays, at most %.3f degrees off the square grid\n",
               forward.x, forward.y, forward.z, angles.size(), worst);
    }
}

static void bestView(void) {
    N3Vector forward = N3VectorMake(7, 0, 0), y = N3VectorMake(0, 1, 0), z = N3VectorMake(0, 0, 1);
    struct { const char *name; N3Vector target; } cases[] = {
        { "ahead", forward },
        { "40 left", rotated(forward, z, 40) },
        { "40 right", rotated(forward, z, -40) },
        { "40 up", rotated(forward, y, -40) },
        { "40 down", rotated(forward, y, 40) },
        { "30 left and up", rotated(rotated(forward, y, -30), z, 30) },
    };
    for (auto &c : cases) {
        N3Vector view;
        FlyScanProbe *probe = scan(forward, c.target, &view);
        double off = degrees(view, c.target), grid = nearest(probe, c.target);
        CHECK(off < 2.5, "%s: the view returned is %.1f degrees from the open lumen (nearest ray %.1f)", c.name, off, grid);
        printf("%s: %.2f degrees off\n", c.name, off);
    }
}

// A distance map of 64 x 64 x 128 resampled voxels, all wall, for input voxels twice as fine in x and y and
// twice as coarse in z.
static const int W = 64, H = 64, D = 128;
static const N3Vector SCALE = {0.5, 0.5, 2};

static void volume(FlyProbe *probe) {
    probe->distmapWidth = W; probe->distmapHeight = H; probe->distmapDepth = D;
    probe->distmapImageSize = W * H;
    probe->distmap = (float *) calloc(W * H * D, sizeof(float));
    probe->resampleScale_x = SCALE.x; probe->resampleScale_y = SCALE.y; probe->resampleScale_z = SCALE.z;
}

static void carve(FlyProbe *probe, int x, int y, int z) {
    if (x >= 0 && x < W && y >= 0 && y < H && z >= 0 && z < D) probe->distmap[x + W * y + W * H * z] = 1;
}

static void room(FlyProbe *probe) {
    for (int z = 4; z < 14; z++) for (int y = 28; y < 38; y++) for (int x = 28; x < 38; x++) carve(probe, x, y, z);
}

// Opens every voxel whose centre is within radius of the half-line from o along d (resample coordinates).
static void tube(FlyProbe *probe, N3Vector o, N3Vector d, double radius) {
    d = unit(d);
    for (int z = 0; z < D; z++) for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
        N3Vector p = N3VectorSubtract(N3VectorMake(x + 0.5, y + 0.5, z + 0.5), o);
        double t = N3VectorDotProduct(p, d);
        if (t < -radius) continue;
        N3Vector off = N3VectorSubtract(p, N3VectorScalarMultiply(d, fmax(t, 0)));
        if (N3VectorLength(off) <= radius) carve(probe, x, y, z);
    }
}

static N3Vector toInput(N3Vector v) { return N3VectorMake(v.x / SCALE.x, v.y / SCALE.y, v.z / SCALE.z); }
static N3Vector toResample(N3Vector v) { return N3VectorMake(v.x * SCALE.x, v.y * SCALE.y, v.z * SCALE.z); }

// The centerline point, in resample coordinates.
static const N3Vector ORIGIN = {32.5, 32.5, 8.5};

static OSIVoxel *voxel(N3Vector v) { return [[[OSIVoxel alloc] initWithX:v.x y:v.y z:v.z value:nil] autorelease]; }

static void fixedOrigin(void) {
    FlyTraceProbe *probe = [[[FlyTraceProbe alloc] init] autorelease];
    volume(probe);
    room(probe);
    tube(probe, ORIGIN, N3VectorMake(0, 0, 1), 1);
    N3Vector c = toInput(ORIGIN);
    OSIVoxel *center = voxel(c);
    [probe computeMaximizingViewDirectionFrom:center LookingAt:voxel(N3VectorAdd(c, toInput(N3VectorMake(3, 0, 3))))];
    int off = 0; double worst = 0;
    for (const N3Vector &s : probe->starts) {
        double d = N3VectorDistance(s, ORIGIN);
        worst = fmax(worst, d);
        if (d > 1e-3) off++;
    }
    CHECK(probe->starts.size() == 31 * 31, "%zu rays traced, not 961", probe->starts.size());
    CHECK(off == 0, "%d of %zu rays start off the centerline point, up to %.1f resampled voxels away",
          off, probe->starts.size(), worst);
    CHECK(probe->moved == 0, "the trace moved the origin it was given %d times", probe->moved);
    CHECK(center.x == (float) c.x && center.y == (float) c.y && center.z == (float) c.z,
          "the centerline point moved to (%g, %g, %g)", center.x, center.y, center.z);
    printf("%zu rays, %d off the origin (at most %.4f voxels), origin moved %d times\n",
           probe->starts.size(), off, worst, probe->moved);
}

static void coordinates(void) {
    FlyProbe *probe = [[[FlyProbe alloc] init] autorelease];
    volume(probe);
    // The path runs 45 degrees up in resample coordinates, the only lumen 75 degrees up.
    N3Vector forward = N3VectorMake(5, 0, 5);
    N3Vector lumen = N3VectorMake(cos(75 * M_PI / 180), 0, sin(75 * M_PI / 180));
    tube(probe, ORIGIN, lumen, 1);
    N3Vector c = toInput(ORIGIN);
    OSIVoxel *best = [probe computeMaximizingViewDirectionFrom:voxel(c) LookingAt:voxel(N3VectorAdd(c, toInput(forward)))];
    N3Vector view = toResample(N3VectorMake(best.x - c.x, best.y - c.y, best.z - c.z));
    double off = degrees(view, lumen);
    CHECK(off < 2.5, "the view returned, (%.1f, %.1f, %.1f) in input voxels from (%.1f, %.1f, %.1f), is %.1f degrees "
          "from the lumen in resample coordinates", best.x, best.y, best.z, c.x, c.y, c.z, off);
    double length = N3VectorLength(view), expected = N3VectorLength(forward);
    CHECK(fabs(length - expected) < 0.05 * expected, "the view returned is %.2f resampled voxels from the centerline "
          "point, the next point %.2f", length, expected);
    printf("view (%.2f, %.2f, %.2f) in input voxels from (%.2f, %.2f, %.2f): %.2f degrees off the lumen, "
           "%.2f resampled voxels out (next point %.2f)\n", best.x, best.y, best.z, c.x, c.y, c.z, off, length, expected);
}

static void rayLength(void) {
    FlyProbe *probe = [[[FlyProbe alloc] init] autorelease];
    volume(probe);
    // Open along +x from x = 11 to 40, but for a wall at x = 22.
    for (int x = 11; x <= 40; x++) if (x != 22) carve(probe, x, 32, 8);
    float lengths[] = {7, 0.5, 1};
    for (float l : lengths) {
        Point3D *origin = [[[Point3D alloc] initWithValues:10.5 :32.5 :8.5] autorelease];
        Point3D *d = [[[Point3D alloc] initWithValues:l :0 :0] autorelease];
        unsigned int steps = [probe traceLineFrom:origin accordingTo:d];
        CHECK(steps == 12, "along (%g, 0, 0) the trace stops after %u steps, not at the wall 12 voxels ahead", l, steps);
        CHECK(origin.x == 10.5f && origin.y == 32.5f && origin.z == 8.5f, "the trace moved its origin to (%g, %g, %g)",
              origin.x, origin.y, origin.z);
        CHECK(d.x == l && d.y == 0 && d.z == 0, "the trace changed its direction to (%g, %g, %g)", d.x, d.y, d.z);
        printf("along (%g, 0, 0): %u steps\n", l, steps);
    }
}

static void degenerate(void) {
    FlyProbe *probe = [[[FlyProbe alloc] init] autorelease];
    volume(probe);
    room(probe);
    Point3D *origin = [[[Point3D alloc] initWithValues:ORIGIN.x :ORIGIN.y :ORIGIN.z] autorelease];
    unsigned int steps = [probe traceLineFrom:origin accordingTo:[[[Point3D alloc] init] autorelease]];
    CHECK(steps == 0, "a zero direction traces %u steps", steps);
    N3Vector c = toInput(ORIGIN);
    OSIVoxel *same = voxel(c);
    OSIVoxel *best = [probe computeMaximizingViewDirectionFrom:voxel(c) LookingAt:same];
    CHECK(isfinite(best.x) && isfinite(best.y) && isfinite(best.z) && best.x == same.x && best.y == same.y && best.z == same.z,
          "with the next point on the current one the view is (%g, %g, %g), not (%g, %g, %g)",
          best.x, best.y, best.z, same.x, same.y, same.z);
    printf("zero direction: %u steps; repeated point: view (%g, %g, %g)\n", steps, best.x, best.y, best.z);
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 2) return 64;
    C = [[OSIVoxel alloc] initWithX:10 y:20 z:30 value:nil];
    if (!strcmp(argv[1], "coverage")) coverage();
    else if (!strcmp(argv[1], "oblique")) oblique();
    else if (!strcmp(argv[1], "square")) square();
    else if (!strcmp(argv[1], "best-view")) bestView();
    else if (!strcmp(argv[1], "fixed-origin")) fixedOrigin();
    else if (!strcmp(argv[1], "coordinates")) coordinates();
    else if (!strcmp(argv[1], "ray-length")) rayLength();
    else if (!strcmp(argv[1], "degenerate")) degenerate();
    else { printf("FAIL: unknown case %s\n", argv[1]); return 64; }
    return failures ? 1 : 0;
} }
'''

CASES = [
    ('coverage', 'looking along +x the scan covers +-45 degrees in azimuth and elevation, through the forward direction'),
    ('oblique', 'looking along (1, 2, 3) the scan covers +-45 degrees about both axes, through the forward direction'),
    ('square', 'the grid is square looking along (1, 2, 3), along z and nearly along -y, as it is along +x'),
    ('best-view', 'the view returned turns to an open lumen ahead, 40 degrees aside or 30 on both axes'),
    ('fixed-origin', 'every ray starts at the centerline point, and the trace leaves its origin where it was'),
    ('coordinates', 'on an anisotropic volume the view returned, in input voxels, lies along the only lumen'),
    ('ray-length', 'the trace steps one resampled voxel at a time, whatever the length of the direction'),
    ('degenerate', 'a zero direction traces nothing, and a repeated centerline point is its own view'),
]


def run(command):
    return subprocess.run(command, check=True, capture_output=True)


failures = []
with tempfile.TemporaryDirectory(prefix='horos-fly-scan-810-') as tmp:
    tmp = Path(tmp)
    for path in SWIFT + HEADERS + [p for _, _, p in OBJC]:
        (tmp / Path(path).name).write_bytes(source(path))
    (tmp / 'bridging.h').write_text('#define HOROS_BRIDGING_HEADER 1\n#import <Cocoa/Cocoa.h>\n'
                                    '#import "Point3D.h"\n#import "OSIVoxel.h"\n')
    (tmp / 'main.mm').write_bytes(MAIN_HEAD + METHODS + MAIN_TAIL)
    try:
        run(['xcrun', 'swiftc', '-swift-version', '5', '-module-name', 'Horos', '-parse-as-library', '-wmo', '-g',
             '-import-objc-header', str(tmp / 'bridging.h'), '-Xcc', '-I' + str(tmp),
             '-emit-objc-header-path', str(tmp / 'Horos-Swift.h'),
             '-c', *[str(tmp / Path(p).name) for p in SWIFT], '-o', str(tmp / 'swift.o')])
        objects = [str(tmp / 'swift.o')]
        for name, language, _ in OBJC + [('main.mm', 'objective-c++', None)]:
            obj = tmp / (Path(name).stem + '.o')
            std = ['-std=c++17'] if language == 'objective-c++' else []
            run(['xcrun', 'clang', '-x', language, *std, '-fno-objc-arc', '-g', '-Wno-deprecated-declarations',
                 '-include', 'Cocoa/Cocoa.h', '-I', str(tmp), '-c', str(tmp / name), '-o', str(obj)])
            objects.append(str(obj))
        run(['xcrun', 'swiftc', *objects, '-lc++', '-framework', 'Cocoa', '-framework', 'Accelerate', '-o', str(tmp / 'harness')])
    except subprocess.CalledProcessError as e:
        print('FAIL: the harness did not build:', (e.stderr or b'').decode(errors='replace')[-3000:])
        sys.exit(1)

    for case, claim in CASES:
        try:
            result = subprocess.run([str(tmp / 'harness'), case], capture_output=True, text=True, timeout=30)
        except subprocess.TimeoutExpired:
            failures.append(f'{claim}: timed out')
            continue
        lines = [line for line in (result.stdout + result.stderr).splitlines() if line.strip()]
        if result.returncode == 0:
            print('ok:', claim, '-', '; '.join(lines) if lines else 'exit 0')
        else:
            detail = '; '.join(line[len('FAIL: '):] for line in lines if line.startswith('FAIL:')) or \
                (lines[-1] if lines else f'exit {result.returncode}')
            failures.append(f'{claim}: {detail}')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: the Fly Assistant scan covers +-45 degrees on a square grid through the forward direction, '
      'traces from a fixed origin one resampled voxel a step, and returns the view toward the open lumen '
      'in input voxels')
