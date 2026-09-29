#!/usr/bin/env python3
"""Defects of the 2D viewer's ROI block kept by its translation to Swift (#866, #879, #882).

The Swift methods are taken as they stand from ViewerController+ROI.swift and
ViewerController+ROI+Editing.swift, with the files' own helpers, and compiled
with swiftc as an extension of an Objective-C double of ViewerController, with
doubles of ROI and MyPoint, beside the real HorosObjCException:

- -sendToBackROI: moves an ungrouped ROI to the end of its slice, where it
  removed it, and keeps the order of a group, which it reversed;
- -roiMorphingBetween:and:ratio: leaves its input ROIs as they were: it turned
  an oval or a length of the series into a polygon;
- -setRoiList:array: stores the array through the setter that retains it
  before releasing the one it holds (a source check: the run, under
  NSZombieEnabled, keeps the array alive before and after the fix);
- -generateROINamesArray skips a ROI without a name, where adding the nil name
  raised;
- the range of -roiPropagate: reaches the first image for a destination before
  it, where nothing was propagated, and reaches the image the panel names ("up
  to image number:", counted from 1 as the viewer shows it, from the other end
  when the data is flipped) in both directions, where it was left out after the
  current image and one more image was taken before it (#879);
- the range of -roiPropagateSlab: is the thick slab the viewer shows, the
  current image and the next stack - 1, or the previous stack - 1 when the data
  is flipped, where flipped data took the stack images before the current one,
  one past the slab (#882); ThickSlabRange.swift is compiled with it;
- -roiList: and -setRoiList:array: stay inside the C array when the viewer has
  no movie frame, where maxMovieIndex - 1 made the index -1 (#879);
- -roiLoadFromFiles: gives each file to the importer of its own extension, where
  the last file's extension chose the importer for all;
- -createLayerROIFromROI: takes its bounds from the finite points, where a NaN
  first point made the bitmap nil and the loop wrote through NULL, and gives up
  when the bitmap has no buffer.

-loadROI: with an archive holding something else than ROIs is checked by
test-roi-volume-persistence.py, which runs it with its database doubles.
`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs (#803)

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
if shutil.which('xcrun') is None:
    print('needs xcrun and the macOS SDK', file=sys.stderr)
    raise SystemExit(2)


def read(name):
    path = f'Horos/Sources/{name}'
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('utf-8')
    return (root / path).read_text(encoding='utf-8')


editing = read('ViewerController+ROI+Editing.swift')
first_half = read('ViewerController+ROI.swift')
failures = []


def method(source, selector):
    """The Swift method from @objc(selector) up to the next @objc( or the end of the extension."""
    marker = '    @objc(' + selector + ')\n'
    assert marker in source, f'missing implementation: {marker.strip()}'
    start = source.index(marker)
    ends = [i for i in (source.find('\n    @objc(', start + 1), source.find('\n}\n', start)) if i != -1]
    return source[start:min(ends) + 1]


# What stands for a helper the sources lack (an older revision): it answers
# nothing useful, so its checks fail while the other methods still run.
STUBS = {
    'roi2PropagationImages': 'fileprivate func roi2PropagationImages(_ pos: Int, _ imageNumber: Int, _ count: Int, flipped: Bool) -> (start: Int, upTo: Int) { return (-1, -1) }\n',
    'roi2SlabImages': 'fileprivate func roi2SlabImages(_ pos: Int, _ stack: Int, _ count: Int, flipped: Bool) -> (start: Int, upTo: Int) { return (-1, -1) }\n',
    'roi2MovieIndex': 'fileprivate func roi2MovieIndex(_ i: Int, _ maxMovieIndex: Int) -> Int { return i }\n',
    'roiImportGroups': 'fileprivate func roiImportGroups(_ urls: [URL]) -> (json: [String], xml: [String], series: [String], roi: [String]) { return ([], [], [], []) }\n',
    'roiLayerBounds': 'fileprivate func roiLayerBounds(_ locations: UnsafePointer<Float>, _ count: Int) -> (Float, Float, Float, Float)? { return nil }\n',
}


def helper(source, name):
    match = re.search(r'(?:@inline\(__always\)\n)?fileprivate func ' + name + r'\b.*?\n}\n', source, re.S)
    if match is None:
        failures.append(f'missing helper {name}')
        return STUBS[name]
    return match.group(0)


def member(source, name):
    match = re.search(r'    func ' + name + r'\(.*?\n    }\n', source, re.S)
    assert match, f'missing {name}'
    return match.group(0)


# Source checks where the method cannot run without the app (a panel, a DCMPix).
load_files = method(first_half, 'roiLoadFromFiles:')
if 'lastURL' in load_files or 'roiLoadFiles(panel.urls)' not in load_files:
    failures.append('-roiLoadFromFiles: must give every chosen file to the importer of its extension')
dispatch = re.search(r'fileprivate func roiLoadFiles\(.*?\n    }\n', first_half, re.S)
if dispatch is None or 'roiImportGroups(urls)' not in dispatch.group(0):
    failures.append('the chosen files must be grouped by roiImportGroups')
layer = method(first_half, 'createLayerROIFromROI:')
if 'roiLayerBounds(locations, dataSize)' not in layer:
    failures.append('-createLayerROIFromROI: must take its bounds from the finite points')
if 'guard let bitmap, let imageBuffer = bitmap.bitmapData else' not in layer:
    failures.append('-createLayerROIFromROI: must not write when the bitmap has no buffer')
propagate = method(editing, 'roiPropagate:')
if not re.search(r'roi2PropagationImages\(self\.roi2CurImage\(\), Int\(imageNumber\), self\.roi2PixCount\(cur\),\s*'
                 r'flipped: self\.horos_imageView\?\.flippedData \?\? false\)', propagate) \
        or 'cInt32(self.horos_roiPropaDest?.floatValue ?? 0)' not in propagate:
    failures.append('-roiPropagate: must take its range from the typed image number with roi2PropagationImages')
propagate_slab = method(editing, 'roiPropagateSlab:')
if not re.search(r'\(startImage, upToImage\) = roi2SlabImages\(self\.roi2CurImage\(\), '
                 r'Int\(self\.roi2Pix\(cur, self\.roi2CurImage\(\)\)\?\.stack \?\? 0\),\s*'
                 r'self\.roi2PixCount\(cur\), flipped: self\.horos_imageView\?\.flippedData \?\? false\)', propagate_slab):
    failures.append('-roiPropagateSlab: must take its range from the slab the viewer shows with roi2SlabImages')

# -setRoiList:array: stores the array through the retaining setter, which
# retains the new array before it releases the old one. Released first, the
# array given back was freed when the controller alone held it; in the Swift
# translation a local strong reference happens to keep it alive, which the
# optimizer may drop, so the run below cannot show the defect by itself.
set_roi_list = method(editing, 'setRoiList:array:')
if 'self.horos_setRoiList(a, at: i)' not in set_roi_list or 'release()' in set_roi_list:
    failures.append('-setRoiList:array: must store the array through horos_setRoiList')
ivars = (root / 'Horos/Sources/ViewerController+SwiftIvars.m').read_text(encoding='latin1') if not revision else \
    subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:Horos/Sources/ViewerController+SwiftIvars.m']).decode('latin1')
setter = re.search(r'- \(void\)horos_setRoiList:.*?\n}', ivars, re.S)
if setter is None or not re.search(r'\[value retain\];\s*\[roiList\[index\] release\];', setter.group(0)):
    failures.append('horos_setRoiList:at: must retain the new array before releasing the old one')

editing_swift = ('import AppKit\n\n'
                 + ''.join(helper(editing, name) + '\n' for name in (
                     'objcCast', 'objcObject', 'objcRaiseNilInsertion', 'objcAdd', 'objcInsert', 'objcRemove',
                     'roi2PropagationImages', 'roi2SlabImages', 'roi2MovieIndex'))
                 + 'fileprivate extension ViewerController {\n'
                 + ''.join(member(editing, name) for name in ('roi2CurImage', 'roi2Slice', 'roi2CurrentSlice'))
                 + '}\n\npublic extension ViewerController {\n'
                 + ''.join(method(editing, selector) for selector in (
                     'roiList:', 'setRoiList:array:', 'isoContourROI:numberOfPoints:', 'roiMorphingBetween:and:ratio:',
                     'bringToFrontROI:', 'sendToBackROI:'))
                 + '}\n' + r'''
@_cdecl("probe_propagation_range")
func probePropagationRange(_ pos: Int, _ imageNumber: Int, _ count: Int, _ flipped: Bool,
                           _ start: UnsafeMutablePointer<Int>, _ upTo: UnsafeMutablePointer<Int>) {
    let range = roi2PropagationImages(pos, imageNumber, count, flipped: flipped)
    start.pointee = range.start
    upTo.pointee = range.upTo
}

@_cdecl("probe_slab_range")
func probeSlabRange(_ pos: Int, _ stack: Int, _ count: Int, _ flipped: Bool,
                    _ start: UnsafeMutablePointer<Int>, _ upTo: UnsafeMutablePointer<Int>) {
    let range = roi2SlabImages(pos, stack, count, flipped: flipped)
    start.pointee = range.start
    upTo.pointee = range.upTo
}
''')

first_half_swift = ('import AppKit\n\nfileprivate var DefaultROINames: NSArray? = ["Liver"]\n\n'
                    + ''.join(helper(first_half, name) + '\n' for name in (
                        'objcTry', 'objcROI', 'objcAdd', 'roiImportGroups', 'roiLayerBounds'))
                    + 'public extension ViewerController {\n' + method(first_half, 'generateROINamesArray') + '}\n' + r'''
@_cdecl("probe_first_half_helpers")
func probeFirstHalfHelpers() -> Int32 {
    var failures: Int32 = 0
    func check(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL: \(message)"); failures += 1 }
    }

    let urls = ["/a/one.json", "/a/two.xml", "/a/three.rois_series", "/a/four.roi", "/a/five.rois_series",
                "/a/six.ROI", "/a/seven.XML"].map { URL(fileURLWithPath: $0) }
    let groups = roiImportGroups(urls)
    check(groups.json == ["/a/one.json"], "the JSON file goes to the interchange importer")
    check(groups.xml == ["/a/two.xml", "/a/seven.XML"], "the XML files go to the XML importer")
    check(groups.series == ["/a/three.rois_series", "/a/five.rois_series"], "every .rois_series file is read")
    check(groups.roi == ["/a/four.roi", "/a/six.ROI"], "the .roi files go to the .roi importer")

    var nanFirst: [Float] = [.nan, .nan, 2, 3, 5, 7, .infinity, 1]
    let bounds = roiLayerBounds(&nanFirst, 4)
    check(bounds != nil && bounds!.0 == 2 && bounds!.1 == 3 && bounds!.2 == 5 && bounds!.3 == 7,
          "the bounds come from the finite points")
    var allNaN: [Float] = [.nan, 1, 2, .nan]
    check(roiLayerBounds(&allNaN, 2) == nil, "no finite point gives no bounds")
    var plain: [Float] = [4, 1, 2, 6, 3, 3]
    let plainBounds = roiLayerBounds(&plain, 3)
    check(plainBounds != nil && plainBounds!.0 == 2 && plainBounds!.1 == 1 && plainBounds!.2 == 4 && plainBounds!.3 == 6,
          "finite points keep their bounds")
    return failures
}
''')

HEADER = r'''
#pragma clang diagnostic ignored "-Wnullability-completeness"
#import <Cocoa/Cocoa.h>
#import "HorosObjCException.h"

// Spelled as in DCMView.h and ROI.h.
typedef NS_ENUM(short, ToolMode) {
    tWL = 0, tTranslate, tZoom, tRotate, tNext, tMesure, tROI, t3DRotate, tCross, tOval, tOPolygon, tCPolygon,
    tAngle, tText, tArrow, tPencil, t3Dpoint, t3DCut, tCamera3D, t2DPoint, tPlain
};
enum { ROI_sleep = 0, ROI_drawing = 1, ROI_selected = 2, ROI_selectedModify = 3 };

@interface MyPoint : NSObject <NSCopying>
@property(assign) NSPoint point;
+ (MyPoint*)point:(NSPoint)a NS_SWIFT_NAME(point(_:)); // MyPoint is Swift in the app (MyPoint.swift)
- (id)initWithPoint:(NSPoint)a;
@end

@interface ROI : NSObject <NSCopying>
@property ToolMode type;
@property(copy) NSString *name;
@property NSTimeInterval groupID;
@property(retain) NSMutableArray *points;
@property(nonatomic, setter=setColor:) RGBColor rgbcolor;
@property(nonatomic) float opacity;
@property(nonatomic) float thickness;
@property(assign) BOOL isSpline;
@property BOOL isAliased;
@property NSRect rect;
- (NSPoint)pointAtIndex:(NSUInteger)index;
- (void)addPoint:(NSPoint)point;
- (NSMutableArray*)splinePoints;
+ (NSPoint)pointBetweenPoint:(NSPoint)a and:(NSPoint)b ratio:(float)r;
+ (NSMutableArray*)resamplePoints:(NSArray*)points number:(int)no;
@end

@interface ProbeView : NSObject
@property short curImage;
@end

@interface ViewerController : NSObject
- (nullable NSMutableArray*)horos_pixListAt:(NSInteger)index;
- (nullable NSMutableArray*)horos_roiListAt:(NSInteger)index;
- (void)horos_setRoiList:(nullable NSMutableArray*)value at:(NSInteger)index;
- (void)horos_assignRoiList:(nullable NSMutableArray*)value at:(NSInteger)index;
@property(assign) short horos_curMovieIndex;
@property(assign) short horos_maxMovieIndex;
@property(retain, nullable) ProbeView* horos_imageView;
@property(retain, nullable) NSMutableArray* horos_ROINamesArray;
- (ROI*)horos_unretainedNewROI:(ToolMode)type;
- (ROI*)convertBrushROItoPolygon:(ROI*)selectedROI numPoints:(int)numPoints;
- (ROI*)convertPolygonROItoBrush:(ROI*)selectedROI;
@end
'''

DRIVER = r'''
#import "Harness.h"
#include <stdio.h>
#include <stdlib.h>

static int failures;
#define CHECK(condition, message) do { if (!(condition)) { fprintf(stderr, "FAIL: %s (line %d)\n", message, __LINE__); failures++; } } while(0)

extern void probe_propagation_range(NSInteger pos, NSInteger imageNumber, NSInteger count, BOOL flipped,
                                    NSInteger *start, NSInteger *upTo);
extern void probe_slab_range(NSInteger pos, NSInteger stack, NSInteger count, BOOL flipped,
                             NSInteger *start, NSInteger *upTo);
extern int probe_first_half_helpers(void);

// The Swift methods, as the Objective-C of the app sees them.
@interface ViewerController (ROI)
- (NSMutableArray*)roiList:(long)i;
- (void)setRoiList:(long)i array:(NSMutableArray*)a;
- (ROI*)roiMorphingBetween:(ROI*)a and:(ROI*)b ratio:(float)ratio;
- (void)bringToFrontROI:(ROI*)roi;
- (void)sendToBackROI:(ROI*)roi;
- (NSMutableArray*)generateROINamesArray;
@end

@implementation MyPoint
+ (MyPoint*)point:(NSPoint)a { return [[[self alloc] initWithPoint:a] autorelease]; }
- (id)initWithPoint:(NSPoint)a { if ((self = [super init])) self.point = a; return self; }
- (id)copyWithZone:(NSZone *)zone { return [[MyPoint point:self.point] retain]; }
@end

// The parts of ROI.m these methods rely on: a rectangle and an oval compute
// their points from their rect, and ignore -setPoints:; a copy copies the
// points.
@implementation ROI {
    NSMutableArray *_points;
}
- (id)init { if ((self = [super init])) _points = [NSMutableArray new]; return self; }
- (void)dealloc { [_points release]; [_name release]; [super dealloc]; }
- (NSMutableArray*)points {
    if (self.type == tROI || self.type == tOval) {
        NSMutableArray *a = [NSMutableArray array];
        for (int i = 0; i < 8; i++) {
            double angle = i * 2 * M_PI / 8;
            [a addObject:[MyPoint point:NSMakePoint(self.rect.origin.x + self.rect.size.width * cos(angle),
                                                    self.rect.origin.y + self.rect.size.height * sin(angle))]];
        }
        return a;
    }
    return _points;
}
- (void)setPoints:(NSMutableArray*)pts {
    if (self.type == tROI || self.type == tOval || self.type == t2DPoint) return;
    NSArray *copy = [[pts copy] autorelease];
    [_points removeAllObjects]; [_points addObjectsFromArray:copy];
}
- (NSPoint)pointAtIndex:(NSUInteger)index { return [[self.points objectAtIndex:index] point]; }
- (void)addPoint:(NSPoint)point { [_points addObject:[MyPoint point:point]]; }
- (NSMutableArray*)splinePoints { return self.points; }
+ (NSPoint)pointBetweenPoint:(NSPoint)a and:(NSPoint)b ratio:(float)r {
    return NSMakePoint(a.x + (b.x - a.x) * r, a.y + (b.y - a.y) * r);
}
+ (NSMutableArray*)resamplePoints:(NSArray*)points number:(int)no {
    NSMutableArray *a = [NSMutableArray array];
    for (int i = 0; i < no && points.count; i++) [a addObject:[[points[i * points.count / no] copy] autorelease]];
    return a;
}
- (id)copyWithZone:(NSZone *)zone {
    ROI *c = [ROI new];
    c.type = self.type; c.name = self.name; c.rect = self.rect; c.groupID = self.groupID;
    c.rgbcolor = self.rgbcolor; c.opacity = self.opacity; c.thickness = self.thickness;
    c.isSpline = self.isSpline; c.isAliased = self.isAliased;
    for (MyPoint *p in _points) [c->_points addObject:[[p copy] autorelease]];
    return c;
}
@end

@implementation ProbeView @end

// Indexes of roiList outside its slots, which the app's C array does not check.
static int outsideRoiList;

@implementation ViewerController {
    NSMutableArray *roiList[4], *pixList[4];
}
@synthesize horos_curMovieIndex, horos_maxMovieIndex, horos_imageView, horos_ROINamesArray;
- (NSMutableArray*)horos_pixListAt:(NSInteger)index { return pixList[index]; }
- (NSMutableArray*)horos_roiListAt:(NSInteger)index {
    if (index < 0 || index >= 4) { outsideRoiList++; return nil; }
    return roiList[index];
}
// As ViewerController+SwiftIvars.m does it.
- (void)horos_setRoiList:(NSMutableArray*)value at:(NSInteger)index {
    if (index < 0 || index >= 4) { outsideRoiList++; return; }
    [value retain]; [roiList[index] release]; roiList[index] = value;
}
- (void)horos_assignRoiList:(NSMutableArray*)value at:(NSInteger)index { roiList[index] = value; }
- (void)probeSetPixList:(NSMutableArray*)value at:(NSInteger)index { [pixList[index] release]; pixList[index] = [value retain]; }
- (ROI*)horos_unretainedNewROI:(ToolMode)type { ROI *r = [[ROI new] autorelease]; r.type = type; return r; }
- (ROI*)convertBrushROItoPolygon:(ROI*)selectedROI numPoints:(int)numPoints { return nil; }
- (ROI*)convertPolygonROItoBrush:(ROI*)selectedROI { return selectedROI; }
@end

static ROI *roi(NSString *name, ToolMode type, NSTimeInterval group) {
    ROI *r = [[ROI new] autorelease]; r.name = name; r.type = type; r.groupID = group;
    return r;
}

static NSString *names(NSArray *rois) {
    NSMutableArray *a = [NSMutableArray array];
    for (ROI *r in rois) [a addObject:r.name];
    return [a componentsJoinedByString:@" "];
}

static ViewerController *viewer(NSArray *slice) {
    ViewerController *v = [[ViewerController new] autorelease];
    v.horos_maxMovieIndex = 1; v.horos_imageView = [[ProbeView new] autorelease];
    [v horos_setRoiList:[NSMutableArray arrayWithObject:[[slice mutableCopy] autorelease]] at:0];
    [v probeSetPixList:[NSMutableArray arrayWithObject:@"pix"] at:0];
    return v;
}

int main(void) { @autoreleasepool {
    // -sendToBackROI: and -bringToFrontROI:
    ROI *a = roi(@"a", tOval, 0), *b = roi(@"b", tOval, 0), *c = roi(@"c", tOval, 0);
    ViewerController *v = viewer(@[a, b, c]);
    [v sendToBackROI:a];
    CHECK([names([v roiList:0][0]) isEqual:@"b c a"], "an ungrouped ROI sent to back stays, at the end");
    [v bringToFrontROI:a];
    CHECK([names([v roiList:0][0]) isEqual:@"a b c"], "an ungrouped ROI brought to front goes first");
    ROI *g1 = roi(@"g1", tOval, 7), *g2 = roi(@"g2", tOval, 7), *x = roi(@"x", tOval, 0), *g3 = roi(@"g3", tOval, 7);
    v = viewer(@[g1, x, g2, g3]);
    [v sendToBackROI:g2];
    CHECK([names([v roiList:0][0]) isEqual:@"x g1 g2 g3"], "a group sent to back keeps its order");
    [v bringToFrontROI:g2];
    CHECK([names([v roiList:0][0]) isEqual:@"g1 g2 g3 x"], "a group brought to front keeps its order");

    // -roiMorphingBetween:and:ratio: leaves its inputs as they were.
    ROI *oval = roi(@"oval", tOval, 0); oval.rect = NSMakeRect(10, 10, 4, 4); oval.isSpline = YES;
    ROI *rect = roi(@"rect", tROI, 0); rect.rect = NSMakeRect(20, 20, 6, 6); rect.isSpline = YES;
    ROI *morphed = [v roiMorphingBetween:oval and:rect ratio:0.5];
    CHECK(morphed != nil && morphed.type == tCPolygon, "the morphed ROI is a closed polygon");
    CHECK(oval.type == tOval && oval.points.count == 8, "the first input stays an oval");
    CHECK(rect.type == tROI && rect.isSpline, "the second input stays a rectangle with its spline setting");
    ROI *length = roi(@"length", tMesure, 0);
    [length.points addObject:[MyPoint point:NSMakePoint(0, 0)]]; [length.points addObject:[MyPoint point:NSMakePoint(10, 0)]];
    ROI *polygon = roi(@"polygon", tCPolygon, 0);
    for (int i = 0; i < 3; i++) [polygon.points addObject:[MyPoint point:NSMakePoint(i, i * i)]];
    morphed = [v roiMorphingBetween:length and:polygon ratio:0.25];
    CHECK(morphed != nil && morphed.type == tOPolygon, "a length morphs as an open polygon");
    CHECK(length.type == tMesure && length.points.count == 2, "the length stays a length of two points");
    CHECK(polygon.points.count == 3, "the polygon keeps its points");

    // -setRoiList:array: with the array it already holds.
    ViewerController *owner = [ViewerController new];
    owner.horos_maxMovieIndex = 1;
    @autoreleasepool { [owner horos_setRoiList:[[[NSMutableArray alloc] initWithObjects:@"slice", nil] autorelease] at:0]; }
    NSMutableArray *held = [owner horos_roiListAt:0];
    CHECK([held retainCount] == 1, "the controller alone holds the array");
    [owner setRoiList:0 array:held];
    CHECK([[owner horos_roiListAt:0] retainCount] == 1 && [[owner horos_roiListAt:0][0] isEqual:@"slice"],
          "the array given back is kept, once");
    NSMutableArray *other = [[NSMutableArray alloc] initWithObjects:@"other", nil];
    [owner setRoiList:0 array:other];
    CHECK([owner horos_roiListAt:0] == other && [other retainCount] == 2, "a new array is retained");
    [other release];
    [owner release];

    // -roiList: and -setRoiList:array: before the viewer has a movie frame.
    ViewerController *empty = [[ViewerController new] autorelease];
    empty.horos_maxMovieIndex = 0;
    outsideRoiList = 0;
    CHECK([empty roiList:0] == nil && [empty roiList:3] == nil, "no frame lists no ROIs");
    NSMutableArray *first = [NSMutableArray arrayWithObject:@"first"];
    [empty setRoiList:2 array:first];
    CHECK(outsideRoiList == 0, "with maxMovieIndex 0 the index stays inside the array");
    CHECK([empty horos_roiListAt:0] == first, "with maxMovieIndex 0 the array goes to the first slot");
    [empty horos_setRoiList:nil at:0];
    empty.horos_maxMovieIndex = 3;
    outsideRoiList = 0;
    [empty setRoiList:7 array:first];
    CHECK(outsideRoiList == 0 && [empty horos_roiListAt:2] == first && [empty roiList:-4] == nil && [empty roiList:9] == first,
          "an index past the frames is clamped to the last frame, a negative one to the first");
    [empty horos_setRoiList:nil at:2];

    // -generateROINamesArray with a ROI without a name.
    v = viewer(@[roi(@"Kidney", tOval, 0), roi(nil, tOval, 0), roi(@"Liver", tOval, 0), roi(@"Spleen", tOval, 0)]);
    NSMutableArray *list = nil;
    @try { list = [v generateROINamesArray]; }
    @catch (NSException *e) { fprintf(stderr, "raised %s\n", e.reason.UTF8String); }
    CHECK([[list componentsJoinedByString:@","] isEqual:@"Liver,-,Kidney,Spleen"], "a ROI without a name is skipped");
    CHECK(v.horos_ROINamesArray == list, "the names are published");

    // The range of -roiPropagate:, from the current index (5 of 10) to the
    // image number typed in the panel, as the viewer shows it: "Im: 6/10", or
    // "Im: 5/10" when the data is flipped.
    NSInteger start = -1, upTo = -1;
    probe_propagation_range(5, -3, 10, NO, &start, &upTo);
    CHECK(start == 0 && upTo == 6, "a destination before the first image propagates from the first image");
    probe_propagation_range(5, 0, 10, NO, &start, &upTo);
    CHECK(start == 0 && upTo == 6, "image number 0 stops at the first image");
    probe_propagation_range(5, 3, 10, NO, &start, &upTo);
    CHECK(start == 2 && upTo == 6, "a destination before the current image is included (Im 3 is index 2)");
    probe_propagation_range(5, 9, 10, NO, &start, &upTo);
    CHECK(start == 5 && upTo == 9, "a destination after the current image is included (Im 9 is index 8)");
    NSInteger after = upTo - start;
    probe_propagation_range(5, 3, 10, NO, &start, &upTo);
    CHECK(upTo - start == after, "three images before and three images after cover as many images");
    probe_propagation_range(5, 40, 10, NO, &start, &upTo);
    CHECK(start == 5 && upTo == 10, "a destination after the last image stops at the last image");
    probe_propagation_range(5, 8, 10, YES, &start, &upTo);
    CHECK(start == 2 && upTo == 6, "flipped, Im 8 is index 2 and is included");
    probe_propagation_range(5, 2, 10, YES, &start, &upTo);
    CHECK(start == 5 && upTo == 9, "flipped, Im 2 is index 8 and is included");
    probe_propagation_range(5, 40, 10, YES, &start, &upTo);
    CHECK(start == 0 && upTo == 6, "flipped, a number past the series stops at index 0");
    probe_propagation_range(5, -3, 10, YES, &start, &upTo);
    CHECK(start == 5 && upTo == 10, "flipped, a number before the series stops at the last index");
    probe_propagation_range(0, 1, 0, NO, &start, &upTo);
    CHECK(start == upTo, "an empty series propagates nowhere");

    // The range of -roiPropagateSlab:, the slab DCMPix draws at index 5 of 10:
    // 5 ... 5 + (stack - 1), or 5 - (stack - 1) ... 5 when the data is flipped.
    probe_slab_range(5, 3, 10, NO, &start, &upTo);
    CHECK(start == 5 && upTo == 8, "a slab of 3 covers the current image and the next 2");
    probe_slab_range(5, 3, 10, YES, &start, &upTo);
    CHECK(start == 3 && upTo == 6, "flipped, a slab of 3 covers the current image and the previous 2");
    NSInteger slab = upTo - start;
    probe_slab_range(5, 3, 10, NO, &start, &upTo);
    CHECK(upTo - start == slab && slab == 3, "both orientations cover the stack images of the slab");
    probe_slab_range(8, 5, 10, NO, &start, &upTo);
    CHECK(start == 8 && upTo == 10, "a slab past the last image stops at the last image");
    probe_slab_range(1, 5, 10, YES, &start, &upTo);
    CHECK(start == 0 && upTo == 2, "flipped, a slab past the first image stops at the first image");
    probe_slab_range(0, 4, 10, YES, &start, &upTo);
    CHECK(start == 0 && upTo == 1, "flipped, at the first image the slab is the first image");
    probe_slab_range(5, 1, 10, YES, &start, &upTo);
    CHECK(start == upTo, "without a slab nothing is propagated");

    failures += probe_first_half_helpers();
    if (failures) return 1;
    puts("PASS: sendToBack/bringToFront, morphing inputs, setRoiList with its own array, roiList without a frame, nameless ROI names, propagation range, slab range, import groups, layer bounds");
    return 0;
}}
'''

for failure in failures:
    print('FAIL:', failure)

with tempfile.TemporaryDirectory(prefix='horos-viewer-roi-defects-') as directory:
    folder = Path(directory)
    (folder / 'Harness.h').write_text(HEADER)
    (folder / 'test.m').write_text(DRIVER)
    (folder / 'Editing.swift').write_text(editing_swift)
    (folder / 'FirstHalf.swift').write_text(first_half_swift)
    (folder / 'ThickSlabRange.swift').write_text(read('ThickSlabRange.swift'))
    include = ['-I', str(folder), '-I', str(root / 'Horos/Sources')]
    try:
        subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-Wno-deprecated-declarations', *include,
                        str(folder / 'test.m'), '-o', str(folder / 'test.o')], check=True)
        subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', *include, str(root / 'Horos/Sources/HorosObjCException.m'),
                        '-o', str(folder / 'HorosObjCException.o')], check=True)
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', *include,
                        '-import-objc-header', str(folder / 'Harness.h'),
                        str(folder / 'Editing.swift'), str(folder / 'FirstHalf.swift'), str(folder / 'ThickSlabRange.swift'),
                        str(folder / 'test.o'), str(folder / 'HorosObjCException.o'),
                        '-framework', 'Cocoa', '-o', str(folder / 'test')], check=True)
    except subprocess.CalledProcessError:
        print('FAIL: the extracted methods do not compile')
        raise SystemExit(1)
    run = subprocess.run([str(folder / 'test')], env={**os.environ, 'NSZombieEnabled': 'YES'})
    if run.returncode != 0:
        print(f'FAIL: the probe exited with {run.returncode}')
        raise SystemExit(1)

raise SystemExit(1 if failures else 0)
