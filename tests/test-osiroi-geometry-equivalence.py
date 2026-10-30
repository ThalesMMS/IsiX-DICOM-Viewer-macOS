#!/usr/bin/env python3
"""The Swift OSI ROIs keep the geometry, the masks and the metrics of the
Objective-C classes they replaced.

The reference is the last revision that has OSIPlanarPathROI.m, read from git.
Its code is compiled as it was, method by method, into a program that runs it
on stand-ins for what it calls (the 2D ROI and its points, the float volume,
the mask, the CPR generator, which record what they are given), with
the revision's Nitrogen N3BezierPath and OSIGeometry.m. This checkout's
OSIGeometry.swift and OSIROIVolumeGeometry.swift, with IsiXROI and the Swift
N3 geometry, are compiled into a Swift program that runs the same cases the way the Swift classes do.
Both print one record per case, which must be the same:

- the slab of OSIGeometry: containment of points and planes, transforms,
  equality, the dictionary round trip, the string and the NSValue encoding;
- the outline a planar path ROI makes from each tool (measure, open and closed
  polygons, ovals and the degenerate one, pencil, traced, empty, other) and the
  path ROI's, element by element, and their convex hulls;
- their masks in volumes of several geometries (scaled, translated, flipped,
  turned in the plane, the slice out of the volume, outlines past the edges):
  every run, in order;
- an extrusion of each outline through slabs of several thicknesses: its hull
  and its runs;
- a brush ROI: its hull, its texture as intensities, the volume's transform,
  and the resampling it asks the CPR generator for;
- a coalesced ROI: the box its sources are merged in, the merged intensities,
  and the slab picture it asks the generator for;
- the metrics: names, labels, units, the label that lists them, the volume,
  and the stroke thickness the 2D ROIs share.

Each side runs as Debug and as Release compiled it: the Objective-C at -O0,
then at -O3 with -ffast-math (the revision's N3 geometry at -O3, without it,
as the app compiled Nitrogen); the Swift at -Onone, then at -O.

`<git revision>` as an optional argument is the reference revision instead.
"""
import private_tmpdir  # noqa: F401  (swiftc leaves folders in TMPDIR)
from pathlib import Path
import json
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import history_reference  # noqa: E402
import isix_modules  # noqa: E402
import n3_geometry_harness  # noqa: E402

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
MARKER = 'Horos/Sources/OSIPlanarPathROI.m'

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, clang)', file=sys.stderr)
    sys.exit(SKIPPED)
if len(sys.argv) > 1:
    reference = sys.argv[1]
elif (root / MARKER).is_file() or subprocess.run(['git', '-C', str(root), 'cat-file', '-e', 'HEAD:' + MARKER],
                                                  capture_output=True).returncode == 0:
    # Not yet removed from this history (the change is not committed).
    reference = 'HEAD'
else:
    reference = history_reference.before_removal(MARKER)
if reference is None:
    print('skipped: the history does not reach the Objective-C OSI ROIs', file=sys.stderr)
    sys.exit(SKIPPED)


def old(path):
    return history_reference.show(reference, 'Horos/Sources/' + path).decode('utf-8')


def body(text, signature):
    """The braces of the method whose declaration starts with `signature`."""
    at = text.index(signature)
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[opening:index + 1]
    raise ValueError(signature)


planar = old('OSIPlanarPathROI.m')
path_roi = old('OSIPathROI.m')
extrusion = old('OSIPathExtrusionROI.m')
brush = old('OSIPlanarBrushROI.m')
coalesced = old('OSICoalescedPlanarROI.m')
base = old('OSIROI.m')
INIT = '- (id)initWithOsiriXROI:(ROI *)roi pixToDICOMTransfrom:(N3AffineTransform)pixToDICOMTransfrom'
MASK = '- (OSIROIMask *)ROIMaskForFloatVolumeData:(OSIFloatVolumeData *)floatVolume'
HULL = '- (NSArray *)convexHull'
# The value of OSIROIMaskRunZero, which the masks start their runs from.
zero = re.search(r'const OSIROIMaskRun OSIROIMaskRunZero = (\{[^;]*\});',
                 (root / 'Horos/Sources/OSIROIMask+CAPI.m').read_text(encoding='utf-8')).group(1)

# ---------------------------------------------------------------------------
# The cases, the same for both sides.

# Volumes: name, size, and the transform from patient space to their indexes
# as (scale x, y, z, translation x, y, z, turn in the plane in degrees, flip y).
VOLUMES = [
    ('plain', 64, 48, 12, (1 / 0.7, 1 / 0.7, 0.5, 10, 4, -1, 0, False)),
    ('shifted', 40, 40, 6, (2, 2, 1, -7.25, 3.5, 2, 0, False)),
    ('flipped', 50, 30, 8, (1.3, 1.3, 1 / 3, 5, 25, 0, 0, True)),
    ('turned', 64, 64, 10, (1.1, 1.1, 0.8, 30, -2, 1, 30, False)),
    ('narrow', 7, 64, 3, (1, 1, 1, 0, 0, 0, 0, False)),
]
# The slice a ROI is drawn on: pix space to patient space, as
# (spacing x, y, origin x, y, z, turn in the plane in degrees).
SLICES = [
    (0.7, 0.7, -3, 2, 7, 0),
    (0.5, 0.5, 1, 1, 2.5, 0),
    (0.9, 0.9, -40, -30, 20, 0),
    (0.7, 0.7, 4, -1, 3, 15),
]
# 2D ROIs: name, tool value (ToolMode), points in pix space.
oval = [(30 + 12 * __import__('math').cos(a / 18 * 3.141592653589793), 20 + 9 * __import__('math').sin(a / 18 * 3.141592653589793)) for a in range(36)]
ROIS = [
    ('measure', 5, [(3.5, 4.25), (40.75, 30.5), (2, 2)]),
    ('measure one point', 5, [(3, 4)]),
    ('open polygon', 10, [(5, 5), (30, 8), (34, 26), (12, 30), (8.5, 14.5)]),
    ('closed concave', 11, [(10, 10), (50, 10), (50, 40), (30, 20), (10, 40)]),
    ('closed star', 11, [(30, 2), (36, 40), (4, 14), (56, 14), (24, 40)]),
    ('closed two points', 11, [(4, 4), (20, 9)]),
    ('oval', 9, oval),
    ('oval degenerate', 9, [(17, 11), (17, 11), (40, 40)]),
    ('pencil', 15, [(2, 3), (60, 4), (63, 44), (1, 47), (-8, 20)]),
    ('traced', 6, [(12, 12), (13, 12), (14, 13), (14, 14), (13, 15), (12, 15), (11, 14), (11, 13)]),
    ('traced empty', 6, []),
    ('beyond the edges', 11, [(-20, -10), (90, -5), (95, 70), (-15, 66)]),
    ('angle', 12, [(1, 1), (5, 5), (9, 1)]),
]
THICKNESSES = [0, 1.5, 4.2, 100]
BRUSHES = [
    # left, top, right, bottom, width, height
    (3, 5, 8, 9, 5, 4),
    (0, 0, 3, 2, 3, 2),
    (10, 2, 19, 13, 9, 11),
]
# Coalesced groups: hull points in patient space, and runs of their masks in
# the merged volume (location, length, row, slice, intensity).
GROUPS = [
    ([(1, 2, 3), (10.5, 2.2, 3), (4, 14.7, 5.5)], [(1, 4, 2, 1, 1.0), (2, 3, 2, 1, 0.5), (0, 2, 5, 3, 0.25)]),
    ([(-6, -6, 0), (6, 6, 0.5)], [(3, 6, 3, 0, 1.0), (4, 8, 4, 1, 0.75)]),
]
PICTURES = [
    # dicomToPix as (scale x, y, translation x, y, turn), slab thickness
    ((1.4, 1.4, 12, 8, 0), 0),
    ((0.9, 1.1, -5, 20, 10), 3.5),
]
METRIC_VALUES = [(12.5, 300.0, -4.0, 0.875), (0.1, 1e-05, 1e20, 123456.789)]
VOXELS = [(0, 0.7, 0.7, 2.0), (1234, 0.7, 0.7, 2.0), (99, 1.2, 0.3, 0.125)]
THICKNESS_LISTS = [[2, 2, 2], [2, 3], [0, 3, 3], [], [1.5, 0, 2], [4]]
POINTS = [(0, 0, 0), (1, 2, 0.4), (3, 3, 0.5), (3, 3, -0.6), (5, 5, 2.0000001), (9, 1, -1e-300)]

CASES = {
    'volumes': [list(v[:4]) + [list(v[4][:7]), v[4][7]] for v in VOLUMES],
    'slices': [list(s) for s in SLICES],
    'rois': [[name, tool, [list(p) for p in points]] for name, tool, points in ROIS],
    'thicknesses': THICKNESSES,
    'brushes': [list(b) for b in BRUSHES],
    'groups': [[[list(p) for p in hull], [list(r) for r in runs]] for hull, runs in GROUPS],
    'pictures': [[list(t), s] for t, s in PICTURES],
    'metrics': [list(m) for m in METRIC_VALUES],
    'voxels': [list(v) for v in VOXELS],
    'thicknessLists': THICKNESS_LISTS,
    'points': [list(p) for p in POINTS],
}

# ---------------------------------------------------------------------------
# The Objective-C reference.

REFERENCE = r'''
#import <Cocoa/Cocoa.h>
#import "N3Geometry.h"
#import "N3BezierPath.h"
#import "OSIGeometry.h"

enum { tMesure = 5, tROI = 6, tOval = 9, tOPolygon = 10, tCPolygon = 11, tPencil = 15, tPlain = 20 };

typedef struct { NSRange widthRange; NSUInteger heightIndex; NSUInteger depthIndex; float intensity; } OSIROIMaskRun;
static const OSIROIMaskRun OSIROIMaskRunZero = ZERO;
@interface NSValue (Runs)
+ (NSValue *)valueWithOSIROIMaskRun:(OSIROIMaskRun)run;
- (OSIROIMaskRun)OSIROIMaskRunValue;
@end
@implementation NSValue (Runs)
+ (NSValue *)valueWithOSIROIMaskRun:(OSIROIMaskRun)run { return [NSValue valueWithBytes:&run objCType:@encode(OSIROIMaskRun)]; }
- (OSIROIMaskRun)OSIROIMaskRunValue { OSIROIMaskRun run; [self getValue:&run]; return run; }
@end

static NSString *num(double v) { return [NSString stringWithFormat:@"%.17g", v]; }
static NSArray *vec(N3Vector v) { return @[num(v.x), num(v.y), num(v.z)]; }
static NSArray *xform(N3AffineTransform t) {
    return @[num(t.m11), num(t.m12), num(t.m13), num(t.m14), num(t.m21), num(t.m22), num(t.m23), num(t.m24),
             num(t.m31), num(t.m32), num(t.m33), num(t.m34), num(t.m41), num(t.m42), num(t.m43), num(t.m44)];
}
static NSArray *runList(NSArray *runs) {
    NSMutableArray *list = [NSMutableArray array];
    for (NSValue *value in runs) {
        OSIROIMaskRun r = [value OSIROIMaskRunValue];
        [list addObject:@[@(r.widthRange.location), @(r.widthRange.length), @(r.heightIndex), @(r.depthIndex), num(r.intensity)]];
    }
    return list;
}
static NSArray *elements(N3BezierPath *path) {
    NSMutableArray *list = [NSMutableArray array];
    for (NSInteger i = 0; i < [path elementCount]; i++) {
        N3Vector c1 = N3VectorZero, c2 = N3VectorZero, end = N3VectorZero;
        N3BezierPathElement type = [path elementAtIndex:i control1:&c1 control2:&c2 endpoint:&end];
        // The controls are only a curve's.
        [list addObject:type == N3CurveToBezierPathElement ? @[@(type), vec(c1), vec(c2), vec(end)] : @[@(type), vec(end)]];
    }
    return list;
}
static NSArray *hullList(NSArray *hull) {
    NSMutableArray *list = [NSMutableArray array];
    for (NSValue *value in hull) [list addObject:vec([value N3VectorValue])];
    return list;
}

@interface MyPoint : NSObject
@property NSPoint point;
+ (MyPoint *)point:(NSPoint)p;
- (BOOL)isEqualToPoint:(NSPoint)p;
@end
@implementation MyPoint
+ (MyPoint *)point:(NSPoint)p { MyPoint *m = [[[MyPoint alloc] init] autorelease]; m.point = p; return m; }
- (BOOL)isEqualToPoint:(NSPoint)p { return p.x == self.point.x && p.y == self.point.y; }
@end

@interface ROI : NSObject
@property int type;
@property (retain) NSMutableArray *points;
@property int textureUpLeftCornerX, textureUpLeftCornerY, textureDownRightCornerX, textureDownRightCornerY, textureWidth, textureHeight;
@property unsigned char *textureBuffer;
@property float thickness;
- (NSPoint)pointAtIndex:(long)i;
@end
@implementation ROI
- (NSPoint)pointAtIndex:(long)i { return [[self.points objectAtIndex:i] point]; }
@end

@class OSIROIMask;
@interface OSIFloatVolumeData : NSObject
@property N3AffineTransform volumeTransform;
@property NSUInteger pixelsWide, pixelsHigh, pixelsDeep;
@property CGFloat pixelSpacingX, pixelSpacingY, pixelSpacingZ;
@property float *bytes;
- (id)initWithFloatBytesNoCopy:(const float *)bytes pixelsWide:(NSUInteger)w pixelsHigh:(NSUInteger)h pixelsDeep:(NSUInteger)d
               volumeTransform:(N3AffineTransform)t outOfBoundsValue:(float)o freeWhenDone:(BOOL)f;
- (BOOL)checkDebugROIMask:(OSIROIMask *)mask;
@end
@implementation OSIFloatVolumeData
- (id)initWithFloatBytesNoCopy:(const float *)bytes pixelsWide:(NSUInteger)w pixelsHigh:(NSUInteger)h pixelsDeep:(NSUInteger)d
               volumeTransform:(N3AffineTransform)t outOfBoundsValue:(float)o freeWhenDone:(BOOL)f {
    if ((self = [super init])) { self.bytes = (float *)bytes; self.pixelsWide = w; self.pixelsHigh = h; self.pixelsDeep = d; self.volumeTransform = t; }
    return self;
}
- (BOOL)checkDebugROIMask:(OSIROIMask *)mask { return YES; }
@end
typedef OSIFloatVolumeData CPRVolumeData;

static NSMutableDictionary *lastRequest;
@interface OSIROIMask : NSObject
@property (retain) NSArray *runs;
@property (retain) NSData *runData;
@property NSUInteger indexCount;
- (id)initWithMaskRuns:(NSArray *)runs;
- (id)initWithMaskRunData:(NSData *)data;
+ (OSIROIMask *)ROIMaskFromVolumeData:(OSIFloatVolumeData *)volume;
- (OSIROIMask *)ROIMaskByTranslatingByX:(NSInteger)x Y:(NSInteger)y Z:(NSInteger)z;
- (NSArray *)maskRuns;
- (NSData *)maskRunsData;
- (NSUInteger)maskIndexCount;
@end
@implementation OSIROIMask
- (id)initWithMaskRuns:(NSArray *)runs { if ((self = [super init])) self.runs = runs; return self; }
- (id)initWithMaskRunData:(NSData *)data {
    NSMutableArray *runs = [NSMutableArray array];
    const OSIROIMaskRun *r = [data bytes];
    for (NSUInteger i = 0; i < [data length] / sizeof(OSIROIMaskRun); i++) [runs addObject:[NSValue valueWithOSIROIMaskRun:r[i]]];
    if ((self = [super init])) self.runs = runs;
    return self;
}
+ (OSIROIMask *)ROIMaskFromVolumeData:(OSIFloatVolumeData *)volume { [lastRequest setObject:@"resampled" forKey:@"mask"]; return [[[OSIROIMask alloc] initWithMaskRuns:@[]] autorelease]; }
- (OSIROIMask *)ROIMaskByTranslatingByX:(NSInteger)x Y:(NSInteger)y Z:(NSInteger)z { [lastRequest setObject:@[@(x), @(y), @(z)] forKey:@"translation"]; return self; }
- (NSArray *)maskRuns { return self.runs; }
- (NSData *)maskRunsData { return [NSData data]; }
- (NSUInteger)maskIndexCount { return self.indexCount; }
@end

enum { CPRInterpolationModeLinear, CPRInterpolationModeNearestNeighbor };
enum { CPRProjectionModeVR, CPRProjectionModeMIP, CPRProjectionModeMinIP, CPRProjectionModeMean, CPRProjectionModeNone = 0xFFFFFF };
@interface CPRObliqueSliceGeneratorRequest : NSObject
@property NSUInteger pixelsWide, pixelsHigh;
@property CGFloat slabWidth, slabSampleDistance;
@property NSInteger interpolationMode, projectionMode;
@property N3AffineTransform sliceToDicomTransform;
@end
@implementation CPRObliqueSliceGeneratorRequest
- (id)init { if ((self = [super init])) self.projectionMode = CPRProjectionModeNone; return self; }
@end
@interface CPRGenerator : NSObject
+ (CPRVolumeData *)synchronousRequestVolume:(CPRObliqueSliceGeneratorRequest *)request volumeData:(CPRVolumeData *)volume;
@end
@implementation CPRGenerator
+ (CPRVolumeData *)synchronousRequestVolume:(CPRObliqueSliceGeneratorRequest *)request volumeData:(CPRVolumeData *)volume {
    [lastRequest addEntriesFromDictionary:@{@"pixelsWide": @(request.pixelsWide), @"pixelsHigh": @(request.pixelsHigh),
        @"slabWidth": num(request.slabWidth), @"interpolation": @(request.interpolationMode), @"projection": @(request.projectionMode),
        @"sliceToDicom": xform(request.sliceToDicomTransform), @"source": @(volume != nil)}];
    return nil;
}
@end

// The classes, with the revision's methods.
@interface OSIROI : NSObject { OSIFloatVolumeData *_homeFloatVolumeData; }
- (void)setHomeFloatVolumeData:(OSIFloatVolumeData *)v;
- (OSIFloatVolumeData *)homeFloatVolumeData;
- (NSArray *)convexHull;
- (OSIROIMask *)ROIMaskForFloatVolumeData:(OSIFloatVolumeData *)v;
@end
@implementation OSIROI
- (void)setHomeFloatVolumeData:(OSIFloatVolumeData *)v { _homeFloatVolumeData = v; }
- (OSIFloatVolumeData *)homeFloatVolumeData { return _homeFloatVolumeData; }
@end

@interface OSIPlanarPathROI : OSIROI { ROI *_osiriXROI; N3MutableBezierPath *_bezierPath; N3Plane _plane; }
@end
@implementation OSIPlanarPathROI
- (id)initWithOsiriXROI:(ROI *)roi pixToDICOMTransfrom:(N3AffineTransform)pixToDICOMTransfrom homeFloatVolumeData:(OSIFloatVolumeData *)floatVolumeData
PLANAR_INIT
- (N3BezierPath *)bezierPath { return _bezierPath; }
- (NSArray *)convexHull
PLANAR_HULL
- (OSIROIMask *)ROIMaskForFloatVolumeData:(OSIFloatVolumeData *)floatVolume
PLANAR_MASK
@end

@interface OSIPathROI : OSIROI { ROI *_osiriXROI; N3MutableBezierPath *_bezierPath; }
@end
@implementation OSIPathROI
- (id)initWithOsiriXROI:(ROI *)roi pixToDICOMTransfrom:(N3AffineTransform)pixToDICOMTransfrom
PATH_INIT
- (N3BezierPath *)bezierPath { return _bezierPath; }
- (NSArray *)convexHull
PATH_HULL
@end

@interface OSIPathExtrusionROI : OSIROI
@property (retain) N3BezierPath *path;
@property OSISlab slab;
@end
@implementation OSIPathExtrusionROI
- (NSArray *)convexHull
EXTRUSION_HULL
- (OSIROIMask *)ROIMaskForFloatVolumeData:(OSIFloatVolumeData *)floatVolume
EXTRUSION_MASK
@end

@interface OSIPlanarBrushROI : OSIROI { ROI *_osiriXROI; OSIFloatVolumeData *_brushMask; N3Plane _plane; NSArray *_convexHull; }
@end
@implementation OSIPlanarBrushROI
- (id)initWithOsiriXROI:(ROI *)roi pixToDICOMTransfrom:(N3AffineTransform)pixToDICOMTransfrom homeFloatVolumeData:(OSIFloatVolumeData *)floatVolumeData
BRUSH_INIT
- (NSArray *)convexHull { return _convexHull; }
- (OSIFloatVolumeData *)brushMask { return _brushMask; }
- (OSIROIMask *)ROIMaskForFloatVolumeData:(OSIFloatVolumeData *)floatVolume
BRUSH_MASK
@end

@interface Source : OSIROI
@property (retain) NSArray *hull;
@property (retain) NSArray *runs;
@end
@implementation Source
- (NSArray *)convexHull { return self.hull; }
- (OSIROIMask *)ROIMaskForFloatVolumeData:(OSIFloatVolumeData *)v { return [[[OSIROIMask alloc] initWithMaskRuns:self.runs] autorelease]; }
@end

@interface OSICoalescedPlanarROI : OSIROI { NSArray *_sourceROIs; OSIFloatVolumeData *_coalescedROIMaskVolumeData; }
- (NSData *)_maskRunsDataForSlab:(OSISlab)slab dicomToPixTransform:(N3AffineTransform)dicomToPixTransform minCorner:(N3VectorPointer)minCornerPtr;
@end
@implementation OSICoalescedPlanarROI
- (id)initWithSources:(NSArray *)sources home:(OSIFloatVolumeData *)home { if ((self = [super init])) { _sourceROIs = [sources retain]; _homeFloatVolumeData = home; } return self; }
- (OSIFloatVolumeData *)coalescedROIMaskVolumeData
COALESCED_VOLUME
- (NSData *)_maskRunsDataForSlab:(OSISlab)slab dicomToPixTransform:(N3AffineTransform)dicomToPixTransform minCorner:(N3VectorPointer)minCornerPtr
COALESCED_PICTURE
@end

@interface Metrics : OSIROI
@property (retain) NSArray *values;
@property (retain) NSSet *rois;
@property NSUInteger voxels;
@end
@implementation Metrics
- (CGFloat)intensityMeanWithFloatVolumeData:(OSIFloatVolumeData *)v { return [[self.values objectAtIndex:0] doubleValue]; }
- (CGFloat)intensityMaxWithFloatVolumeData:(OSIFloatVolumeData *)v { return [[self.values objectAtIndex:1] doubleValue]; }
- (CGFloat)intensityMinWithFloatVolumeData:(OSIFloatVolumeData *)v { return [[self.values objectAtIndex:2] doubleValue]; }
- (OSIROIMask *)ROIMaskForFloatVolumeData:(OSIFloatVolumeData *)v { OSIROIMask *m = [[[OSIROIMask alloc] init] autorelease]; m.indexCount = self.voxels; return m; }
- (NSSet *)osiriXROIs { return self.rois; }
- (NSString *)label
METRIC_LABEL
- (NSArray *)metricNames
METRIC_NAMES
- (NSString *)labelForMetric:(NSString *)metric
METRIC_LABEL_FOR
- (NSString *)unitForMetric:(NSString *)metric
METRIC_UNIT
- (id)valueForMetric:(NSString *)metric
METRIC_VALUE
- (CGFloat)volume
METRIC_VOLUME
- (CGFloat)strokeThickness
METRIC_THICKNESS
@end
'''
REFERENCE = REFERENCE.replace('ZERO', zero)
for key, value in {
    'PLANAR_INIT': body(planar, INIT + ' homeFloatVolumeData:'),
    'PLANAR_HULL': body(planar, HULL),
    'PLANAR_MASK': body(planar, MASK),
    'PATH_INIT': body(path_roi, INIT),
    'PATH_HULL': body(path_roi, HULL),
    'EXTRUSION_HULL': body(extrusion, HULL),
    'EXTRUSION_MASK': body(extrusion, MASK),
    'BRUSH_INIT': body(brush, INIT + ' homeFloatVolumeData:'),
    'BRUSH_MASK': body(brush, MASK),
    'COALESCED_VOLUME': body(coalesced, '- (OSIFloatVolumeData *)coalescedROIMaskVolumeData\n'),
    'COALESCED_PICTURE': body(coalesced, '- (NSData *)_maskRunsDataForSlab:(OSISlab)slab dicomToPixTransform:(N3AffineTransform)dicomToPixTransform minCorner:(N3VectorPointer)minCornerPtr;\n{'),
    'METRIC_LABEL': body(base, '- (NSString *)label\n'),
    'METRIC_NAMES': body(base, '- (NSArray *)metricNames'),
    'METRIC_LABEL_FOR': body(base, '- (NSString *)labelForMetric:(NSString *)metric'),
    'METRIC_UNIT': body(base, '- (NSString *)unitForMetric:(NSString *)metric'),
    'METRIC_VALUE': body(base, '- (id)valueForMetric:(NSString *)metric'),
    'METRIC_VOLUME': body(base, '- (CGFloat)volume'),
    'METRIC_THICKNESS': body(base, '- (CGFloat)strokeThickness'),
}.items():
    REFERENCE = REFERENCE.replace(key + '\n', value + '\n')

REFERENCE_MAIN = r'''
static N3AffineTransform volumeTransform(NSArray *v) {
    NSArray *s = [v objectAtIndex:4];
    N3AffineTransform t = N3AffineTransformMakeScale([[s objectAtIndex:0] doubleValue], [[s objectAtIndex:1] doubleValue], [[s objectAtIndex:2] doubleValue]);
    if ([[v objectAtIndex:5] boolValue]) t = N3AffineTransformConcat(t, N3AffineTransformMakeScale(1, -1, 1));
    t = N3AffineTransformConcat(N3AffineTransformMakeRotation([[s objectAtIndex:6] doubleValue] * M_PI / 180, 0, 0, 1), t);
    return N3AffineTransformConcat(t, N3AffineTransformMakeTranslation([[s objectAtIndex:3] doubleValue], [[s objectAtIndex:4] doubleValue], [[s objectAtIndex:5] doubleValue]));
}
static OSIFloatVolumeData *volume(NSArray *v) {
    OSIFloatVolumeData *data = [[[OSIFloatVolumeData alloc] init] autorelease];
    data.pixelsWide = [[v objectAtIndex:1] unsignedIntegerValue]; data.pixelsHigh = [[v objectAtIndex:2] unsignedIntegerValue];
    data.pixelsDeep = [[v objectAtIndex:3] unsignedIntegerValue]; data.volumeTransform = volumeTransform(v);
    return data;
}
static N3AffineTransform pixToDICOM(NSArray *s) {
    N3AffineTransform t = N3AffineTransformMakeScale([[s objectAtIndex:0] doubleValue], [[s objectAtIndex:1] doubleValue], 1);
    t = N3AffineTransformConcat(t, N3AffineTransformMakeRotation([[s objectAtIndex:5] doubleValue] * M_PI / 180, 0, 0, 1));
    return N3AffineTransformConcat(t, N3AffineTransformMakeTranslation([[s objectAtIndex:2] doubleValue], [[s objectAtIndex:3] doubleValue], [[s objectAtIndex:4] doubleValue]));
}
static ROI *roiOf(NSArray *r) {
    ROI *roi = [[[ROI alloc] init] autorelease];
    roi.type = [[r objectAtIndex:1] intValue];
    roi.points = [NSMutableArray array];
    for (NSArray *p in [r objectAtIndex:2]) [roi.points addObject:[MyPoint point:NSMakePoint([[p objectAtIndex:0] doubleValue], [[p objectAtIndex:1] doubleValue])]];
    return roi;
}
static void emit(NSString *key, id value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[key, value] options:0 error:NULL];
    printf("%s\n", [[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] UTF8String]);
}
static void emitMask(NSString *key, OSIROIMask *mask) { emit(key, mask ? runList([mask maskRuns]) : @"nil"); }

int main(int argc, const char **argv) { @autoreleasepool {
    NSDictionary *cases = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]] options:0 error:NULL];
    NSArray *volumes = cases[@"volumes"];

    // The slab.
    for (NSArray *s in cases[@"slices"]) {
        N3Plane plane = N3PlaneApplyTransform(N3PlaneZZero, pixToDICOM(s));
        for (NSNumber *thickness in cases[@"thicknesses"]) {
            OSISlab slab = OSISlabMake(plane, [thickness doubleValue]);
            NSString *key = [NSString stringWithFormat:@"slab %@ %@", s, thickness];
            NSMutableArray *contains = [NSMutableArray array];
            for (NSArray *p in cases[@"points"]) {
                N3Vector v = N3VectorApplyTransform(N3VectorMake([p[0] doubleValue], [p[1] doubleValue], [p[2] doubleValue]), pixToDICOM(s));
                [contains addObject:@(OSISlabContainsVector(slab, v))];
            }
            for (NSArray *t in cases[@"slices"]) [contains addObject:@(OSISlabContainsPlane(slab, N3PlaneApplyTransform(N3PlaneZZero, pixToDICOM(t))))];
            emit([key stringByAppendingString:@" contains"], contains);
            for (NSArray *v in volumes) {
                OSISlab moved = OSISlabApplyTransform(slab, volumeTransform(v));
                emit([key stringByAppendingFormat:@" in %@", v[0]], @[vec(moved.plane.point), vec(moved.plane.normal), num(moved.thickness)]);
            }
            OSISlab copy = slab, other = OSISlabMake(N3PlaneMake(N3VectorAdd(plane.point, plane.normal), plane.normal), [thickness doubleValue]);
            emit([key stringByAppendingString:@" equal"], @[@(OSISlabEqualTo(slab, copy)), @(OSISlabEqualTo(slab, other)),
                                                           @(OSISlabIsCoincidentToSlab(slab, other)), @(OSISlabIsCoincidentToSlab(slab, copy))]);
            CFDictionaryRef dict = OSISlabCreateDictionaryRepresentation(slab);
            OSISlab back; bool made = OSISlabMakeWithDictionaryRepresentation(dict, &back);
            emit([key stringByAppendingString:@" dictionary"], @[@(made), vec(back.plane.point), vec(back.plane.normal), num(back.thickness),
                                                                @(OSISlabMakeWithDictionaryRepresentation(NULL, &back)),
                                                                @(OSISlabMakeWithDictionaryRepresentation((CFDictionaryRef)@{@"plane": @1}, &back))]);
            CFRelease(dict);
            emit([key stringByAppendingString:@" string"], NSStringFromOSISlab(slab));
            NSValue *value = [NSValue valueWithOSISlab:slab];
            OSISlab unboxed = [value OSISlabValue];
            emit([key stringByAppendingString:@" value"], @[[NSString stringWithUTF8String:[value objCType]], num(unboxed.thickness), vec(unboxed.plane.point)]);
        }
    }

    // Outlines, hulls, masks and extrusions.
    for (NSArray *r in cases[@"rois"]) {
        for (NSArray *s in cases[@"slices"]) {
            NSString *key = [NSString stringWithFormat:@"%@ on %@", r[0], s];
            OSIPlanarPathROI *roi = [[[OSIPlanarPathROI alloc] initWithOsiriXROI:roiOf(r) pixToDICOMTransfrom:pixToDICOM(s) homeFloatVolumeData:nil] autorelease];
            emit([key stringByAppendingString:@" outline"], roi ? elements([roi bezierPath]) : @"nil");
            if (roi) emit([key stringByAppendingString:@" hull"], hullList([roi convexHull]));
            int tool = [r[1] intValue];
            if ((tool == tMesure && [r[2] count] > 1) || tool == tOPolygon || tool == tCPolygon) {
                OSIPathROI *pathROI = [[[OSIPathROI alloc] initWithOsiriXROI:roiOf(r) pixToDICOMTransfrom:pixToDICOM(s)] autorelease];
                emit([key stringByAppendingString:@" path outline"], elements([pathROI bezierPath]));
                emit([key stringByAppendingString:@" path hull"], hullList([pathROI convexHull]));
            }
            if (!roi) continue;
            for (NSArray *v in volumes) emitMask([key stringByAppendingFormat:@" mask in %@", v[0]], [roi ROIMaskForFloatVolumeData:volume(v)]);
            N3Plane plane = N3PlaneApplyTransform(N3PlaneZZero, pixToDICOM(s));
            for (NSNumber *thickness in cases[@"thicknesses"]) {
                OSIPathExtrusionROI *extruded = [[[OSIPathExtrusionROI alloc] init] autorelease];
                extruded.path = [roi bezierPath];
                extruded.slab = OSISlabMake(plane, [thickness doubleValue]);
                NSString *extrusionKey = [key stringByAppendingFormat:@" extruded %@", thickness];
                emit([extrusionKey stringByAppendingString:@" hull"], hullList([extruded convexHull]));
                for (NSArray *v in volumes) emitMask([extrusionKey stringByAppendingFormat:@" mask in %@", v[0]], [extruded ROIMaskForFloatVolumeData:volume(v)]);
            }
        }
    }

    // Brushes.
    for (NSArray *b in cases[@"brushes"]) {
        for (NSArray *s in cases[@"slices"]) {
            ROI *roi = [[[ROI alloc] init] autorelease];
            roi.type = tPlain;
            roi.textureUpLeftCornerX = [b[0] intValue]; roi.textureUpLeftCornerY = [b[1] intValue];
            roi.textureDownRightCornerX = [b[2] intValue]; roi.textureDownRightCornerY = [b[3] intValue];
            roi.textureWidth = [b[4] intValue]; roi.textureHeight = [b[5] intValue];
            unsigned char *texture = malloc(roi.textureWidth * roi.textureHeight);
            for (int i = 0; i < roi.textureWidth * roi.textureHeight; i++) texture[i] = (unsigned char)((i * 37 + 11) % 256);
            roi.textureBuffer = texture;
            OSIPlanarBrushROI *brush = [[[OSIPlanarBrushROI alloc] initWithOsiriXROI:roi pixToDICOMTransfrom:pixToDICOM(s) homeFloatVolumeData:nil] autorelease];
            NSString *key = [NSString stringWithFormat:@"brush %@ on %@", b, s];
            NSMutableArray *intensities = [NSMutableArray array];
            for (int i = 0; i < roi.textureWidth * roi.textureHeight; i++) [intensities addObject:num([brush brushMask].bytes[i])];
            emit(key, @[hullList([brush convexHull]), intensities, xform([brush brushMask].volumeTransform),
                        @([brush brushMask].pixelsWide), @([brush brushMask].pixelsHigh), @([brush brushMask].pixelsDeep)]);
            for (NSArray *v in volumes) {
                lastRequest = [NSMutableDictionary dictionary];
                [brush ROIMaskForFloatVolumeData:volume(v)];
                emit([key stringByAppendingFormat:@" mask in %@", v[0]], lastRequest);
            }
            free(texture);
        }
    }

    // Coalesced groups.
    for (NSArray *g in cases[@"groups"]) {
        for (NSArray *v in volumes) {
            NSMutableArray *sources = [NSMutableArray array];
            Source *source = [[[Source alloc] init] autorelease];
            NSMutableArray *hull = [NSMutableArray array];
            for (NSArray *p in g[0]) [hull addObject:[NSValue valueWithN3Vector:N3VectorMake([p[0] doubleValue], [p[1] doubleValue], [p[2] doubleValue])]];
            source.hull = hull;
            NSMutableArray *runs = [NSMutableArray array];
            for (NSArray *r in g[1]) {
                OSIROIMaskRun run = OSIROIMaskRunZero;
                run.widthRange = NSMakeRange([r[0] unsignedIntegerValue], [r[1] unsignedIntegerValue]);
                run.heightIndex = [r[2] unsignedIntegerValue]; run.depthIndex = [r[3] unsignedIntegerValue]; run.intensity = [r[4] floatValue];
                [runs addObject:[NSValue valueWithOSIROIMaskRun:run]];
            }
            source.runs = runs;
            [sources addObject:source];
            OSICoalescedPlanarROI *roi = [[[OSICoalescedPlanarROI alloc] initWithSources:sources home:volume(v)] autorelease];
            OSIFloatVolumeData *merged = [roi coalescedROIMaskVolumeData];
            NSMutableArray *values = [NSMutableArray array];
            for (NSUInteger i = 0; i < merged.pixelsWide * merged.pixelsHigh * merged.pixelsDeep; i++) [values addObject:num(merged.bytes[i])];
            NSString *key = [NSString stringWithFormat:@"group %@ in %@", g, v[0]];
            emit(key, @[xform(merged.volumeTransform), @(merged.pixelsWide), @(merged.pixelsHigh), @(merged.pixelsDeep), values]);
            for (NSArray *p in cases[@"pictures"]) {
                NSArray *t = p[0];
                N3AffineTransform dicomToPix = N3AffineTransformConcat(N3AffineTransformMakeScale([t[0] doubleValue], [t[1] doubleValue], 1),
                                                                      N3AffineTransformMakeRotation([t[4] doubleValue] * M_PI / 180, 0, 0, 1));
                dicomToPix = N3AffineTransformConcat(dicomToPix, N3AffineTransformMakeTranslation([t[2] doubleValue], [t[3] doubleValue], 0));
                lastRequest = [NSMutableDictionary dictionary];
                N3Vector minCorner;
                OSISlab slab = OSISlabMake(N3PlaneZZero, [p[1] doubleValue]);
                [roi _maskRunsDataForSlab:slab dicomToPixTransform:dicomToPix minCorner:&minCorner];
                lastRequest[@"minCorner"] = vec(minCorner);
                emit([key stringByAppendingFormat:@" picture %@", p], lastRequest);
            }
        }
    }

    // Metrics.
    Metrics *metrics = [[[Metrics alloc] init] autorelease];
    for (NSArray *m in cases[@"metrics"]) {
        metrics.values = m;
        metrics.voxels = 1000;
        OSIFloatVolumeData *home = [[[OSIFloatVolumeData alloc] init] autorelease];
        home.pixelSpacingX = 0.5; home.pixelSpacingY = 0.5; home.pixelSpacingZ = [m[3] doubleValue];
        [metrics setHomeFloatVolumeData:home];
        emit([NSString stringWithFormat:@"label %@", m], [metrics label]);
    }
    NSMutableArray *names = [NSMutableArray arrayWithArray:[metrics metricNames]];
    [names addObject:@"area"];
    NSMutableArray *described = [NSMutableArray array];
    for (NSString *name in names) [described addObject:@[[metrics labelForMetric:name] ?: @"nil", [metrics unitForMetric:name] ?: @"nil"]];
    [described addObject:@[[metrics labelForMetric:nil] ?: @"nil", [metrics unitForMetric:nil] ?: @"nil"]];
    emit(@"metric names", @[[metrics metricNames], described]);
    for (NSArray *v in cases[@"voxels"]) {
        metrics.voxels = [v[0] unsignedIntegerValue];
        OSIFloatVolumeData *home = [[[OSIFloatVolumeData alloc] init] autorelease];
        home.pixelSpacingX = [v[1] doubleValue]; home.pixelSpacingY = [v[2] doubleValue]; home.pixelSpacingZ = [v[3] doubleValue];
        [metrics setHomeFloatVolumeData:home];
        emit([NSString stringWithFormat:@"volume %@", v], num([metrics volume]));
    }
    for (NSArray *list in cases[@"thicknessLists"]) {
        NSMutableArray *rois = [NSMutableArray array];
        for (NSNumber *t in list) { ROI *roi = [[[ROI alloc] init] autorelease]; roi.thickness = [t floatValue]; [rois addObject:roi]; }
        metrics.rois = (NSSet *)rois;
        emit([NSString stringWithFormat:@"thickness %@", list], num([metrics strokeThickness]));
    }
    return 0;
}}
'''

# ---------------------------------------------------------------------------
# This checkout's Swift.

BRIDGING = r'''
#define HOROS_BRIDGING_HEADER 1
#import <Cocoa/Cocoa.h>
#import "N3Geometry.h"
#import "N3BezierPath.h"
#import "OSIGeometry.h"
#import "OSIROIMask.h"
'''

DRIVER = r'''
import Cocoa
import IsiXROI

func num(_ v: Double) -> String { String(format: "%.17g", v) }
func vec(_ v: N3Vector) -> [String] { [num(Double(v.x)), num(Double(v.y)), num(Double(v.z))] }
func xform(_ t: N3AffineTransform) -> [String] {
    [t.m11, t.m12, t.m13, t.m14, t.m21, t.m22, t.m23, t.m24, t.m31, t.m32, t.m33, t.m34, t.m41, t.m42, t.m43, t.m44].map { num(Double($0)) }
}
func runList(_ runs: [OSIROIMaskRun]?) -> Any {
    guard let runs else { return "nil" }
    return runs.map { [$0.widthRange.location, $0.widthRange.length, Int($0.heightIndex), Int($0.depthIndex), num(Double($0.intensity))] as [Any] }
}
func elements(_ path: N3BezierPath?) -> Any {
    guard let path else { return "nil" }
    return (0..<path.elementCount()).map { i -> [Any] in
        var c1 = N3VectorZero, c2 = N3VectorZero, end = N3VectorZero
        let type = path.element(at: i, control1: &c1, control2: &c2, endpoint: &end)
        return type == Int(N3CurveToBezierPathElement.rawValue) ? [type, vec(c1), vec(c2), vec(end)] : [type, vec(end)]
    }
}
func hullList(_ hull: [N3Vector]) -> [[String]] { hull.map(vec) }
func emit(_ key: String, _ value: Any) {
    let data = try! JSONSerialization.data(withJSONObject: [key, value])
    print(String(data: data, encoding: .utf8)!)
}
func describe(_ value: Any) -> String { (value as AnyObject).description }

let cases = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
let volumes = cases["volumes"] as! [[Any]]
func d(_ any: Any) -> Double { (any as! NSNumber).doubleValue }
func i(_ any: Any) -> Int { (any as! NSNumber).intValue }
func volumeTransform(_ v: [Any]) -> N3AffineTransform {
    let s = v[4] as! [Any]
    var t = N3AffineTransformMakeScale(CGFloat(d(s[0])), CGFloat(d(s[1])), CGFloat(d(s[2])))
    if (v[5] as! NSNumber).boolValue { t = N3AffineTransformConcat(t, N3AffineTransformMakeScale(1, -1, 1)) }
    t = N3AffineTransformConcat(N3AffineTransformMakeRotation(CGFloat(d(s[6]) * Double.pi / 180), 0, 0, 1), t)
    return N3AffineTransformConcat(t, N3AffineTransformMakeTranslation(CGFloat(d(s[3])), CGFloat(d(s[4])), CGFloat(d(s[5]))))
}
func pixToDICOM(_ s: [Any]) -> N3AffineTransform {
    var t = N3AffineTransformMakeScale(CGFloat(d(s[0])), CGFloat(d(s[1])), 1)
    t = N3AffineTransformConcat(t, N3AffineTransformMakeRotation(CGFloat(d(s[5]) * Double.pi / 180), 0, 0, 1))
    return N3AffineTransformConcat(t, N3AffineTransformMakeTranslation(CGFloat(d(s[2])), CGFloat(d(s[3])), CGFloat(d(s[4]))))
}
func roiKey(_ s: Any) -> String { (s as AnyObject).description }
let slices = cases["slices"] as! [[Any]]
let thicknesses = cases["thicknesses"] as! [Any]

// The slab.
for s in slices {
    let plane = N3PlaneApplyTransform(N3PlaneZZero, pixToDICOM(s))
    for thickness in thicknesses {
        let slab = OSISlabMake(plane, CGFloat(d(thickness)))
        let key = "slab \(roiKey(s)) \(roiKey(thickness))"
        var contains: [Bool] = []
        for p in cases["points"] as! [[Any]] {
            let v = N3VectorApplyTransform(N3VectorMake(CGFloat(d(p[0])), CGFloat(d(p[1])), CGFloat(d(p[2]))), pixToDICOM(s))
            contains.append(OSISlabContainsVector(slab, v))
        }
        for t in slices { contains.append(OSISlabContainsPlane(slab, N3PlaneApplyTransform(N3PlaneZZero, pixToDICOM(t)))) }
        emit(key + " contains", contains)
        for v in volumes {
            let moved = OSISlabApplyTransform(slab, volumeTransform(v))
            emit(key + " in \(v[0])", [vec(moved.plane.point), vec(moved.plane.normal), num(Double(moved.thickness))] as [Any])
        }
        let copy = slab, other = OSISlabMake(N3PlaneMake(N3VectorAdd(plane.point, plane.normal), plane.normal), CGFloat(d(thickness)))
        emit(key + " equal", [OSISlabEqualTo(slab, copy), OSISlabEqualTo(slab, other), OSISlabIsCoincidentToSlab(slab, other), OSISlabIsCoincidentToSlab(slab, copy)])
        let dict = OSISlabCreateDictionaryRepresentation(slab)
        var back = OSISlab()
        let made = OSISlabMakeWithDictionaryRepresentation(dict, &back)
        emit(key + " dictionary", [made, vec(back.plane.point), vec(back.plane.normal), num(Double(back.thickness)),
                                   OSISlabMakeWithDictionaryRepresentation(nil, &back),
                                   OSISlabMakeWithDictionaryRepresentation(["plane": 1] as NSDictionary as CFDictionary, &back)] as [Any])
        emit(key + " string", NSStringFromOSISlab(slab))
        let value = NSValue.value(withOSISlab: slab)
        let unboxed = value.osiSlabValue()
        emit(key + " value", [String(cString: value.objCType), num(Double(unboxed.thickness)), vec(unboxed.plane.point)] as [Any])
    }
}

// Outlines, hulls, masks and extrusions, as the classes make them.
func kind(_ tool: Int) -> VolumeROIOutline.Kind {
    switch tool {
    case 5: return .measure
    case 10: return .openPolygon
    case 11: return .closedPolygon
    case 9: return .oval
    case 15: return .pencil
    case 6: return .traced
    default: return .other
    }
}
func mask(_ path: N3BezierPath?, _ v: [Any]) -> Any {
    let runs = OSIROIVolumeGeometry.planarRuns(of: path, volumeTransform: volumeTransform(v), pixelsWide: i(v[1]), pixelsHigh: i(v[2]), pixelsDeep: i(v[3]))
    return runList(runs ?? [])
}
for r in cases["rois"] as! [[Any]] {
    let points = (r[2] as! [[Any]]).map { NSPoint(x: d($0[0]), y: d($0[1])) }
    let tool = i(r[1])
    for s in slices {
        let key = "\(r[0]) on \(roiKey(s))"
        let k = kind(tool)
        let coincide = k == .oval && points.count >= 2 && points[0] == points[1]
        let outline = OSIROIVolumeGeometry.planarOutline(kind: k, points: points, firstTwoCoincide: coincide, pixToDICOM: pixToDICOM(s))
        emit(key + " outline", elements(outline))
        if outline != nil { emit(key + " hull", hullList(OSIROIVolumeGeometry.hull(of: outline))) }
        if (tool == 5 && points.count > 1) || tool == 10 || tool == 11 {
            let pathOutline = OSIROIVolumeGeometry.pathOutline(kind: tool == 5 ? .measure : tool == 10 ? .openPolygon : .closedPolygon,
                                                               points: tool == 5 ? [points[0], points[1]] : points, pixToDICOM: pixToDICOM(s))
            emit(key + " path outline", elements(pathOutline))
            emit(key + " path hull", hullList(OSIROIVolumeGeometry.hull(of: pathOutline)))
        }
        guard let outline else { continue }
        for v in volumes { emit(key + " mask in \(v[0])", mask(outline, v)) }
        let plane = OSIROIVolumeGeometry.roiPlane(pixToDICOM: pixToDICOM(s))
        for thickness in thicknesses {
            let slab = OSISlabMake(plane, CGFloat(d(thickness)))
            let extrusionKey = key + " extruded \(roiKey(thickness))"
            emit(extrusionKey + " hull", hullList(OSIROIVolumeGeometry.extrusionHull(of: outline, normal: slab.plane.normal)))
            for v in volumes {
                let runs = OSIROIVolumeGeometry.extrudedRuns(of: outline, slab: slab, volumeTransform: volumeTransform(v),
                                                             pixelsWide: i(v[1]), pixelsHigh: i(v[2]), pixelsDeep: i(v[3]))
                emit(extrusionKey + " mask in \(v[0])", runList(runs ?? []))
            }
        }
    }
}

// Brushes, as OSIPlanarBrushROI makes and resamples them.
for b in cases["brushes"] as! [[Any]] {
    for s in slices {
        let left = Int32(i(b[0])), top = Int32(i(b[1])), right = Int32(i(b[2])), bottom = Int32(i(b[3]))
        let width = i(b[4]), height = i(b[5])
        let texture = (0..<(width * height)).map { UInt8(($0 * 37 + 11) % 256) }
        let intensities = UnsafeMutablePointer<Float>.allocate(capacity: max(width * height, 1))
        intensities.initialize(repeating: 0, count: max(width * height, 1))
        texture.withUnsafeBufferPointer { VolumeROIMaskVolume.brushIntensities($0.baseAddress, width: width, height: height, into: intensities) }
        let hull = OSIROIVolumeGeometry.brushHull(left: left, top: top, right: right, bottom: bottom, pixToDICOM: pixToDICOM(s))
        let transform = OSIROIVolumeGeometry.brushVolumeTransform(left: left, top: top, pixToDICOM: pixToDICOM(s))
        let key = "brush \(roiKey(b)) on \(roiKey(s))"
        emit(key, [hullList(hull), (0..<(width * height)).map { num(Double(intensities[$0])) }, xform(transform), width, height, 1] as [Any])
        let plane = OSIROIVolumeGeometry.roiPlane(pixToDICOM: pixToDICOM(s))
        for v in volumes {
            let slice = OSIROIVolumeGeometry.planeSlice(plane, volumeTransform: volumeTransform(v))
            emit(key + " mask in \(v[0])", ["pixelsWide": i(v[1]), "pixelsHigh": i(v[2]), "slabWidth": num(0), "interpolation": 1,
                                            "projection": 0xFFFFFF, "sliceToDicom": xform(slice.sliceToDicomTransform), "source": true,
                                            "mask": "resampled", "translation": [0, 0, volumeROIIndex(Double(slice.planePixelPoint.z).rounded())]] as [String: Any])
        }
        intensities.deallocate()
    }
}

// Coalesced groups, as OSICoalescedPlanarROI merges and resamples them.
for g in cases["groups"] as! [[Any]] {
    for v in volumes {
        let hull = (g[0] as! [[Any]]).map { N3VectorMake(CGFloat(d($0[0])), CGFloat(d($0[1])), CGFloat(d($0[2]))) }
        let runs = (g[1] as! [[Any]]).map { (location: i($0[0]), length: i($0[1]), row: i($0[2]), slice: i($0[3]), intensity: Float(d($0[4]))) }
        let box = OSIROIVolumeGeometry.coalescedVolume(hull: hull, volumeTransform: volumeTransform(v))
        let count = box.width * box.height * box.depth
        var bytes = [Float](repeating: 0, count: count)
        bytes.withUnsafeMutableBufferPointer {
            VolumeROIMaskVolume.mergeMaximum(runs, into: $0.baseAddress!, width: box.width, height: box.height, count: count)
        }
        let key = "group \(roiKey(g)) in \(v[0])"
        emit(key, [xform(box.volumeTransform), box.width, box.height, box.depth, bytes.map { num(Double($0)) }] as [Any])
        for p in cases["pictures"] as! [[Any]] {
            let t = p[0] as! [Any]
            var dicomToPix = N3AffineTransformConcat(N3AffineTransformMakeScale(CGFloat(d(t[0])), CGFloat(d(t[1])), 1),
                                                     N3AffineTransformMakeRotation(CGFloat(d(t[4]) * Double.pi / 180), 0, 0, 1))
            dicomToPix = N3AffineTransformConcat(dicomToPix, N3AffineTransformMakeTranslation(CGFloat(d(t[2])), CGFloat(d(t[3])), 0))
            let picture = OSIROIVolumeGeometry.slabPicture(volumeTransform: box.volumeTransform, width: box.width, height: box.height,
                                                           depth: box.depth, dicomToPixTransform: dicomToPix)
            emit(key + " picture \(roiKey(p))", ["pixelsWide": UInt(bitPattern: picture.width), "pixelsHigh": UInt(bitPattern: picture.height),
                                                  "slabWidth": num(d(p[1])), "interpolation": 0, "projection": 1,
                                                  "sliceToDicom": xform(picture.sliceToDicomTransform), "source": true, "mask": "resampled",
                                                  "minCorner": vec(picture.minCorner)] as [String: Any])
        }
    }
}

// Metrics, as OSIROI and OSIROI+Style answer them.
for m in cases["metrics"] as! [[Any]] {
    let values = m.map { NSNumber(value: d($0)) }
    let volume = VolumeROIMetrics.volume(voxelCount: 1000, spacingX: 0.5, spacingY: 0.5, spacingZ: d(m[3]))
    let entries = VolumeROIMetrics.names.map { name -> (label: String?, value: String?, unit: String?) in
        let value: NSNumber? = name == "intensityMean" ? values[0] : name == "intensityMax" ? values[1] : name == "intensityMin" ? values[2] : NSNumber(value: volume)
        return (VolumeROIMetrics.label(for: name), value.map(describe), VolumeROIMetrics.unit(for: name))
    }
    emit("label \(roiKey(m))", VolumeROIMetrics.summary(entries))
}
let names: [String?] = VolumeROIMetrics.names + ["area", nil]
emit("metric names", [VolumeROIMetrics.names, names.map { [VolumeROIMetrics.label(for: $0) ?? "nil", VolumeROIMetrics.unit(for: $0) ?? "nil"] }] as [Any])
for v in cases["voxels"] as! [[Any]] {
    emit("volume \(roiKey(v))", num(VolumeROIMetrics.volume(voxelCount: UInt(i(v[0])), spacingX: d(v[1]), spacingY: d(v[2]), spacingZ: d(v[3]))))
}
for list in cases["thicknessLists"] as! [[Any]] {
    emit("thickness \(roiKey(list))", num(VolumeROIMetrics.commonThickness(list.map { Double(Float(d($0))) })))
}
'''

def run(argv, **kwargs):
    done = subprocess.run(argv, capture_output=True, text=True, timeout=600, **kwargs)
    if done.returncode:
        raise RuntimeError(' '.join(map(str, argv[:3])) + ' failed:\n' + done.stderr[-4000:])
    return done.stdout


def records(text):
    found = {}
    for line in text.splitlines():
        key, value = json.loads(line)
        found[key] = value
    return found


failures = []
with tempfile.TemporaryDirectory(prefix='horos-osiroi-equivalence-') as folder:
    folder = Path(folder)
    (folder / 'cases.json').write_text(json.dumps(CASES))
    old_headers = folder / 'old-headers'
    old_headers.mkdir()
    (old_headers / 'OSIGeometry.h').write_bytes(history_reference.show(reference, 'Horos/Sources/OSIGeometry.h'))
    (folder / 'OSIGeometry.m').write_bytes(history_reference.show(reference, 'Horos/Sources/OSIGeometry.m'))
    (folder / 'reference.m').write_text(REFERENCE + REFERENCE_MAIN)
    (folder / 'bridging.h').write_text(BRIDGING)
    (folder / 'zero.m').write_text('#import <Foundation/Foundation.h>\n#import "N3Geometry.h"\n'
                                   'typedef struct { NSRange widthRange; NSUInteger heightIndex; NSUInteger depthIndex; float intensity; } OSIROIMaskRun;\n'
                                   'const OSIROIMaskRun OSIROIMaskRunZero = %s;\n' % zero)
    (folder / 'main.swift').write_text(DRIVER)
    module = isix_modules.module_flags('IsiXROI', folder / 'module')

    results = {}
    for configuration, objc_flags, swift_flags in (('Debug', ['-O0'], ['-Onone']),
                                                   ('Release', ['-O3', '-ffast-math'], ['-O'])):
        build = folder / configuration
        build.mkdir()
        n3_reference_include, n3_reference = n3_geometry_harness.build_reference(build / 'n3-reference', reference, configuration.lower())
        n3_include, _ = n3_geometry_harness.build(build / 'n3', configuration.lower())
        objects = list(n3_reference[:len(n3_geometry_harness.NAMES)])
        for source in [folder / 'OSIGeometry.m', folder / 'reference.m']:
            obj = build / (source.stem + '.o')
            run(['xcrun', 'clang', '-x', 'objective-c', '-include', 'Cocoa/Cocoa.h', '-c', '-fno-objc-arc', '-w', *objc_flags, '-I', str(old_headers),
                 *n3_reference_include, str(source), '-o', str(obj)])
            objects.append(obj)
        run(['xcrun', 'clang', *map(str, objects), '-framework', 'Cocoa', '-framework', 'QuartzCore', '-framework', 'Accelerate', '-o', str(build / 'reference')])
        swift_objects = n3_geometry_harness.libraries(build / 'n3')
        for source in [folder / 'zero.m']:
            obj = build / ('new-' + source.stem + '.o')
            run(['xcrun', 'clang', '-x', 'objective-c', '-include', 'Cocoa/Cocoa.h', '-c', '-fno-objc-arc', '-w', *objc_flags, *n3_include, str(source), '-o', str(obj)])
            swift_objects.append(obj)
        run(['xcrun', 'swiftc', '-swift-version', '6', '-suppress-warnings', *swift_flags, '-module-name', 'Equivalence',
             '-import-objc-header', str(folder / 'bridging.h'), '-Xcc', '-I' + str(root / 'Horos/Sources'), '-Xcc', '-I' + n3_include[1],
             *module, str(root / 'Horos/Sources/OSIGeometry.swift'), str(root / 'Horos/Sources/OSIROIVolumeGeometry.swift'),
             str(folder / 'main.swift'), *map(str, swift_objects), '-framework', 'Cocoa', '-framework', 'QuartzCore', '-framework', 'Accelerate',
             '-o', str(build / 'swift')])
        old_records = records(run([str(build / 'reference'), str(folder / 'cases.json')]))
        new_records = records(run([str(build / 'swift'), str(folder / 'cases.json')]))
        if set(old_records) != set(new_records):
            failures.append(f'{configuration}: cases only in the reference: {sorted(set(old_records) - set(new_records))[:5]}; '
                            f'only in Swift: {sorted(set(new_records) - set(old_records))[:5]}')
        differing = [key for key in old_records if key in new_records and old_records[key] != new_records[key]]
        for key in differing[:10]:
            failures.append(f'{configuration}: {key}: reference {json.dumps(old_records[key])[:400]} / Swift {json.dumps(new_records[key])[:400]}')
        if len(differing) > 10:
            failures.append(f'{configuration}: {len(differing) - 10} more cases differ')
        masks = [key for key in old_records if ' mask in ' in key and isinstance(old_records[key], list)]
        runs = sum(len(old_records[key]) for key in masks)
        results[configuration] = (len(old_records), len(masks), runs)

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print(f'PASS: the Swift OSI ROIs give the records of {reference}:',
      '; '.join(f'{c}: {n} cases, {m} masks of {r} runs' for c, (n, m, r) in results.items()))
