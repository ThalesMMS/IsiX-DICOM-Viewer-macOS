#!/usr/bin/env python3
"""The region growing, the resampling and the brush filters give what the
Objective-C++ classes gave, now that ITK is behind its adapter.

ITK.mm, ITKSegmentation3D.mm, ITKTransform.mm and ITKBrushROIFilter.mm became
Swift classes of the same Objective-C names, their rules went to
IsiXSegmentation, and ITK and VTK are reached through Horos/Sources/Adapters
(IsiXITKVolume, IsiXITKRegionGrowing, IsiXITKResampler, IsiXVTKContour). This
builds one probe with the former classes, read from the last revision of this
history that has them, and one with this checkout's (tests/itk_harness.py),
both against the ITK and VTK of the Debug build and the same stand-ins for the
viewer, its view, its slices and ROIs, and runs the same driver on a synthetic
CT phantom (64 x 64 x 24: air, a body, a vessel, a separate nodule and a
spine, with deterministic noise):

- region growing with each algorithm of the region growing window (interval,
  threshold, neighborhood, confidence), in 3D and in one slice, into a new
  series (the region set to a value, or copied from the source), as brush ROIs
  (named, the preview, merged) and as polygons (resolution 1 and 3): the
  series' voxels, every ROI (texture, points, name, colour, comments, mode,
  thickness), the notifications, the merges and the view's calls;
- the outline of masks (marching squares), largest region or all, at several
  point counts;
- the volume ITK is handed (size, origin, spacing) for the whole volume, the
  tilt correction's pair, one slice, the halved volume and a series of one
  slice;
- resampling by an affine transform onto other series (other spacings, a
  coronal reference, an oblique moving series), rescaled or not, and the
  reorientation of one slice: the bytes of the result;
- erosion, dilation, opening and closing of brush ROIs of radius 1 to 5: the
  texture after each.

Both print every result; the outputs must be the same line for line.
Exits 2 without a Debug build or without a revision that has the former classes.

    python3 tests/test-itk-segmentation-equivalence.py
"""
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs
import itk_harness  # noqa: E402

if itk_harness.installs() is None:
    print('skipped: needs the ITK and VTK of a Debug build from script/build_and_run.sh --verify')
    sys.exit(2)
if itk_harness.old_revision() is None:
    print('skipped: no revision of this history has Horos/Sources/ITKSegmentation3D.mm')
    sys.exit(2)

DRIVER = r'''
#import <Cocoa/Cocoa.h>
#import "Stubs.h"
#include <math.h>
#include <vector>

#if OLD_ITK
#include <itkImage.h>
#include <itkImportImageFilter.h>
#import "ITK.h"
#endif

// The selectors of the classes under test, as the app's callers send them.
@interface NSObject (ITKProbe)
- (id)initWith:(NSMutableArray *)pix :(float *)volumeData :(long)slice;
- (void)regionGrowing3D:(ViewerController *)src :(ViewerController *)dst :(long)slice :(NSPoint)point :(int)algorithm
                       :(NSArray *)parameters :(BOOL)setIn :(float)inValue :(BOOL)setOut :(float)outValue :(ToolMode)roiType
                       :(long)roiResolution :(NSString *)name :(BOOL)merge;
+ (NSMutableArray *)extractContour:(unsigned char *)map width:(long)width height:(long)height numPoints:(long)numPoints
                     largestRegion:(BOOL)largestRegion;
+ (NSMutableArray *)extractContour:(unsigned char *)map width:(long)width height:(long)height;
+ (float *)resampleWithParameters:(double *)parameters firstObject:(DCMPix *)firstObject firstObjectOriginal:(DCMPix *)original
                       noOfImages:(int)count length:(long *)length itkImage:(id)volume rescale:(BOOL)rescale;
+ (float *)reorient2Dimage:(double *)parameters firstObject:(DCMPix *)firstObject firstObjectOriginal:(DCMPix *)original
                    length:(long *)length;
- (void)erode:(ROI *)roi withStructuringElementRadius:(int)radius;
- (void)dilate:(ROI *)roi withStructuringElementRadius:(int)radius;
- (void)open:(ROI *)roi withStructuringElementRadius:(int)radius;
- (void)close:(ROI *)roi withStructuringElementRadius:(int)radius;
+ (id)volumeWithPix:(NSArray *)pix voxels:(float *)voxels slice:(long)slice resampleData:(BOOL)resample;
- (void)getOrigin:(double *)origin;
- (void)getSpacing:(double *)spacing;
@end

static unsigned int seedState = 12345;
static float noise() { seedState = seedState * 1103515245u + 12345u; return (float)((seedState >> 16) % 31) - 15.0f; }

enum { W = 64, H = 64, D = 24 };

// The phantom: air, an elliptic body, a vessel drifting across the slices, a
// nodule that does not touch it, a spine.
static std::vector<float> phantom()
{
    std::vector<float> v((size_t)W * H * D);
    for (int z = 0; z < D; z++)
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++) {
                float value = -1000;
                double bx = (x - 32) / 26.0, by = (y - 34) / 22.0;
                if (bx * bx + by * by <= 1) value = 40 + noise();
                double vx = x - (22 + z * 0.3), vy = y - 30;
                if (vx * vx + vy * vy <= 16) value = 300 + noise();
                double nx = x - 44, ny = y - 24;
                if (z >= 5 && z <= 15 && nx * nx + ny * ny <= 9) value = 310 + noise();
                double sx = x - 34, sy = y - 48;
                if (sx * sx + sy * sy <= 36) value = 1000 + noise() * 4;
                v[((size_t)z * H + y) * W + x] = value;
            }
    return v;
}

static NSMutableArray *slicesOver(float *volume, int width, int height, int depth, const double origin[3], double spacingX,
                                  double spacingY, double interval, const double *orientation)
{
    NSMutableArray *list = [NSMutableArray array];
    double normal[3] = {0, 0, 1};
    if (orientation) {
        normal[0] = orientation[6]; normal[1] = orientation[7]; normal[2] = orientation[8];
    }
    for (int k = 0; k < depth; k++) {
        DCMPix *pix = [[[DCMPix alloc] init] autorelease];
        pix.pwidth = width; pix.pheight = height;
        pix.originX = origin[0] + k * interval * normal[0];
        pix.originY = origin[1] + k * interval * normal[1];
        pix.originZ = origin[2] + k * interval * normal[2];
        pix.pixelSpacingX = spacingX; pix.pixelSpacingY = spacingY;
        pix.sliceInterval = interval; pix.sliceThickness = interval * 1.5;
        pix.minValueOfSeries = -1024;
        pix.fImage = volume ? volume + (size_t)k * width * height : NULL;
        if (orientation) for (int i = 0; i < 9; i++) pix.orientation[i] = orientation[i];
        [list addObject:pix];
    }
    return list;
}

static ViewerController *viewerOver(float *volume, NSMutableArray *pix, NSInteger current)
{
    ViewerController *viewer = [[[ViewerController alloc] init] autorelease];
    viewer.pixArray = pix;
    viewer.volume = volume;
    NSMutableArray *rois = [NSMutableArray array];
    for (NSUInteger i = 0; i < pix.count; i++) [rois addObject:[NSMutableArray array]];
    viewer.roiArray = rois;
    DCMView *view = [[[DCMView alloc] init] autorelease];
    view.curImage = current;
    view.curDCM = pix[current];
    viewer.view = view;
    return viewer;
}

static void dumpROIs(ViewerController *viewer)
{
    for (NSUInteger i = 0; i < viewer.roiArray.count; i++)
        for (ROI *roi in viewer.roiArray[i]) StubRecord(@"  slice %lu: %@", (unsigned long)i, [roi describe]);
}

static void regionGrowing(std::vector<float> &volume)
{
    const double origin[3] = {-20.3, 11.7, -4.1};
    Class segmentation = NSClassFromString(@"ITKSegmentation3D");
    NSArray *algorithms = @[@[@100], @[@200, @2000], @[@200, @2000, @1], @[@2.5, @5, @2]];
    for (int algorithm = 0; algorithm < 4; algorithm++)
        for (long slice : {-1L, 12L}) {
            NSPoint seed = NSMakePoint(25.7, 30.4);
            // A new series: the region set to a value, then copied from the source.
            for (int setIn = 1; setIn >= 0; setIn--) {
                StubRecord(@"== algorithm %d slice %ld new series setIn %d", algorithm, slice, setIn);
                NSMutableArray *pix = slicesOver(volume.data(), W, H, D, origin, 0.7, 0.7, 1.5, NULL);
                ViewerController *source = viewerOver(volume.data(), pix, 12);
                std::vector<float> copy(volume.size(), -7);
                ViewerController *destination = viewerOver(copy.data(), slicesOver(copy.data(), W, H, D, origin, 0.7, 0.7, 1.5, NULL), 12);
                id grower = [[[segmentation alloc] initWith:pix :volume.data() :slice] autorelease];
                [grower regionGrowing3D:source :destination :slice :seed :algorithm :algorithms[algorithm] :setIn :1 :NO :0
                                       :(ToolMode)0 :1 :@"Grown" :NO];
                long inside = 0;
                for (float value : copy) inside += value != -7;
                StubRecord(@"  series %@ changed %ld", StubHash(copy.data(), copy.size() * sizeof(float)), inside);
            }
            // Brush ROIs: named, the preview, merged; polygons at two resolutions.
            struct { ToolMode type; const char *name; BOOL merge; long resolution; } outputs[] = {
                {(ToolMode)0, "Grown", NO, 1}, {(ToolMode)0, "Segmentation Preview", YES, 1}, {(ToolMode)0, "Grown", YES, 1},
                {tCPolygon, "Outline", NO, 1}, {tCPolygon, "Outline", NO, 3},
            };
            for (auto &output : outputs) {
                StubRecord(@"== algorithm %d slice %ld type %d name %s merge %d resolution %ld", algorithm, slice, (int)output.type,
                           output.name, output.merge, output.resolution);
                NSMutableArray *pix = slicesOver(volume.data(), W, H, D, origin, 0.7, 0.7, 1.5, NULL);
                ViewerController *viewer = viewerOver(volume.data(), pix, 12);
                id grower = [[[segmentation alloc] initWith:pix :volume.data() :slice] autorelease];
                [grower regionGrowing3D:viewer :nil :slice :seed :algorithm :algorithms[algorithm] :NO :0 :NO :0 :output.type
                                       :output.resolution :@(output.name) :output.merge];
                dumpROIs(viewer);
            }
        }
    // A seed outside the body, and an algorithm the window does not have.
    StubRecord(@"== air seed");
    NSMutableArray *pix = slicesOver(volume.data(), W, H, D, origin, 0.7, 0.7, 1.5, NULL);
    ViewerController *viewer = viewerOver(volume.data(), pix, 3);
    id grower = [[[segmentation alloc] initWith:pix :volume.data() :-1] autorelease];
    [grower regionGrowing3D:viewer :nil :-1 :NSMakePoint(1, 1) :0 :@[@50] :NO :0 :NO :0 :(ToolMode)0 :1 :@"Air" :NO];
    dumpROIs(viewer);
    StubRecord(@"== no such algorithm");
    [grower regionGrowing3D:viewer :nil :-1 :NSMakePoint(25, 30) :7 :@[@50] :NO :0 :NO :0 :(ToolMode)0 :1 :@"None" :NO];
    dumpROIs(viewer);
}

static void contours(std::vector<float> &volume)
{
    Class segmentation = NSClassFromString(@"ITKSegmentation3D");
    std::vector<unsigned char> masks[3];
    masks[0].assign(W * H, 0);
    for (int i = 0; i < W * H; i++) masks[0][i] = volume[12 * W * H + i] > 200 ? 255 : 0;
    masks[1].assign(30 * 20, 0);
    for (int y = 3; y < 17; y++)
        for (int x = 4; x < 26; x++)
            if (!(x >= 9 && x < 20 && y >= 7 && y < 13)) masks[1][y * 30 + x] = 255;
    masks[2].assign(16 * 16, 0);
    int widths[3] = {W, 30, 16}, heights[3] = {H, 20, 16};
    for (int m = 0; m < 3; m++)
        for (long numPoints : {100L, 20L, 7L, 0L, -5L})
            for (BOOL largest : {YES, NO}) {
                NSArray *points = [segmentation extractContour:masks[m].data() width:widths[m] height:heights[m] numPoints:numPoints
                                                largestRegion:largest];
                NSMutableString *text = [NSMutableString stringWithFormat:@"contour mask %d points %ld largest %d: %lu", m, numPoints,
                                         largest, (unsigned long)points.count];
                for (MyPoint *p in points) [text appendFormat:@" %.9g,%.9g", p.point.x, p.point.y];
                StubRecord(@"%@", text);
            }
    NSArray *points = [segmentation extractContour:masks[0].data() width:W height:H];
    StubRecord(@"contour default %lu", (unsigned long)points.count);
}

static void importGeometry(std::vector<float> &volume)
{
    const double origin[3] = {-20.3, 11.7, -4.1};
    struct { long slice; BOOL resample; int depth; double interval; } cases[] = {
        {-1, NO, D, 1.5}, {-2, NO, 2, 1.5}, {5, NO, D, 1.5}, {-1, YES, D, 1.5}, {-1, NO, 1, 1.5}, {-1, NO, D, 0}, {3, YES, D, 0.37},
    };
    for (auto &c : cases) {
        NSMutableArray *pix = slicesOver(volume.data(), W, H, c.depth, origin, 0.7, 0.9, c.interval, NULL);
        long size[3];
        double o[3], s[3];
#if OLD_ITK
        ITK *itk = [[ITK alloc] initWithPix:pix volume:volume.data() sliceCount:c.slice resampleData:c.resample];
        ImportFilterType::Pointer importer = [itk itkImporter];
        for (int a = 0; a < 3; a++) {
            size[a] = (long)importer->GetRegion().GetSize()[a];
            o[a] = importer->GetOrigin()[a];
            s[a] = importer->GetSpacing()[a];
        }
        [itk release];
#else
        id itk = [NSClassFromString(@"ITKVolumeImport") volumeWithPix:pix voxels:volume.data() slice:c.slice resampleData:c.resample];
        // Other classes declare -width and -height as CGFloat: send them as the volume's NSInteger.
        size[0] = ((long (*)(id, SEL))objc_msgSend)(itk, @selector(width));
        size[1] = ((long (*)(id, SEL))objc_msgSend)(itk, @selector(height));
        size[2] = ((long (*)(id, SEL))objc_msgSend)(itk, @selector(depth));
        [itk getOrigin:o];
        [itk getSpacing:s];
#endif
        StubRecord(@"import slice %ld resample %d depth %d interval %.9g: size %ld %ld %ld origin %.17g %.17g %.17g spacing %.17g %.17g %.17g",
                   c.slice, c.resample, c.depth, c.interval, size[0], size[1], size[2], o[0], o[1], o[2], s[0], s[1], s[2]);
    }
}

static void unit(double *v) { double l = sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]); for (int i = 0; i < 3; i++) v[i] /= l; }

static void frame(double *o, const double row[3], const double column[3])
{
    for (int i = 0; i < 3; i++) { o[i] = row[i]; o[3 + i] = column[i]; }
    unit(o); unit(o + 3);
    o[6] = o[1] * o[5] - o[2] * o[4];
    o[7] = o[2] * o[3] - o[0] * o[5];
    o[8] = o[0] * o[4] - o[1] * o[3];
}

// -[ViewerController resampleSeries:rescale:]: the rotation from the reference's frame to the moving series'.
static void rotation(DCMPix *moving, DCMPix *reference, double *matrix, double shift)
{
    double s[9], m[9];
    [moving orientationDouble:s];
    [reference orientationDouble:m];
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 3; c++) matrix[3 * r + c] = s[3 * r] * m[3 * c] + s[3 * r + 1] * m[3 * c + 1] + s[3 * r + 2] * m[3 * c + 2];
    matrix[9] = shift; matrix[10] = -shift / 2; matrix[11] = shift / 3;
}

static id importVolume(NSMutableArray *pix, float *voxels, long slice)
{
#if OLD_ITK
    return [[[ITK alloc] initWith:pix :voxels :slice] autorelease];
#else
    return [NSClassFromString(@"ITKVolumeImport") volumeWithPix:pix voxels:voxels slice:slice resampleData:NO];
#endif
}

static void resampling(std::vector<float> &volume)
{
    Class transform = NSClassFromString(@"ITKTransform");
    const double x[3] = {1, 0, 0}, y[3] = {0, 1, 0}, minusZ[3] = {0, 0, -1};
    const double obliqueRow[3] = {cos(0.5), sin(0.5), 0}, obliqueColumn[3] = {-sin(0.5) * cos(0.3), cos(0.5) * cos(0.3), sin(0.3)};
    double axial[9], coronal[9], oblique[9];
    frame(axial, x, y);
    frame(coronal, x, minusZ);
    frame(oblique, obliqueRow, obliqueColumn);
    const double movingOrigin[3] = {-20.3, 11.7, -4.1}, referenceOrigin[3] = {-18, 9, -2}, coronalOrigin[3] = {-20, 30, 20};
    struct { const char *name; const double *movingFrame, *referenceFrame, *referenceOrigin; double spacing, interval;
             int width, height, slices; double shift; } cases[] = {
        {"onto finer", axial, axial, referenceOrigin, 0.5, 1.0, 80, 72, 20, 0},
        {"onto coarser", axial, axial, referenceOrigin, 1.3, 3.0, 40, 40, 8, 1.7},
        {"onto coronal", axial, coronal, coronalOrigin, 0.9, 1.25, 48, 30, 12, 0},
        {"oblique onto axial", oblique, axial, referenceOrigin, 0.6, 1.7, 56, 56, 10, -2.3},
        {"one slice", axial, axial, referenceOrigin, 0.7, 0, 64, 64, 1, 0.4},
    };
    for (auto &c : cases)
        for (BOOL rescale : {YES, NO}) {
            NSMutableArray *moving = slicesOver(volume.data(), W, H, D, movingOrigin, 0.7, 0.8, 1.5, c.movingFrame);
            NSMutableArray *reference = slicesOver(NULL, c.width, c.height, c.slices, c.referenceOrigin, c.spacing, c.spacing * 1.1,
                                                   c.interval, c.referenceFrame);
            double matrix[12];
            rotation(moving[0], reference[0], matrix, c.shift);
            id itk = importVolume(moving, volume.data(), -1);
            long length = -1;
            float *out = [transform resampleWithParameters:matrix firstObject:reference[0] firstObjectOriginal:moving[0]
                                                noOfImages:c.slices length:&length itkImage:itk rescale:rescale];
            StubRecord(@"resample %s rescale %d: length %ld %@", c.name, rescale, length, out ? StubHash(out, length) : @"none");
            free(out);
        }
    // The gantry tilt correction: one slice onto the plane of another, tilted.
    const double tiltedColumn[3] = {0, cos(0.2), sin(0.2)};
    double tilted[9];
    frame(tilted, x, tiltedColumn);
    NSMutableArray *model = slicesOver(volume.data() + 12 * W * H, W, H, 1, movingOrigin, 0.7, 0.7, 1.5, axial);
    NSMutableArray *sensor = slicesOver(volume.data() + 13 * W * H, W, H, 1, movingOrigin, 0.7, 0.7, 1.5, tilted);
    double matrix[12];
    rotation(sensor[0], model[0], matrix, 0.8);
    long length = -1;
    float *out = [transform reorient2Dimage:matrix firstObject:model[0] firstObjectOriginal:sensor[0] length:&length];
    StubRecord(@"reorient: length %ld %@", length, out ? StubHash(out, length) : @"none");
    free(out);
}

static ROI *brush(const std::vector<unsigned char> &mask, int width, int height)
{
    std::vector<unsigned char> copy(mask);
    return [[[ROI alloc] initWithTexture:copy.data() textWidth:width textHeight:height textName:@"Brush" positionX:10 positionY:20
                                spacingX:0.7 spacingY:0.7 imageOrigin:NSZeroPoint] autorelease];
}

static void morphology(std::vector<float> &volume)
{
    Class filterClass = NSClassFromString(@"ITKBrushROIFilter");
    std::vector<unsigned char> masks[3];
    int widths[3] = {W, 16, 24}, heights[3] = {H, 16, 18};
    masks[0].assign(W * H, 0);
    for (int i = 0; i < W * H; i++) masks[0][i] = volume[12 * W * H + i] > 200 ? 255 : 0;
    masks[1].assign(16 * 16, 0);
    for (int yy = 0; yy < 10; yy++)
        for (int xx = 0; xx < 10; xx++)
            if (!(xx >= 3 && xx <= 6 && yy >= 3 && yy <= 6)) masks[1][(yy + 3) * 16 + xx + 3] = 255;
    masks[2].assign(24 * 18, 0);
    for (int i = 0; i < 24 * 18; i++) masks[2][i] = (volume[7 * W * H + 2000 + i] > 30) ? 255 : 0;
    for (int m = 0; m < 3; m++)
        for (NSString *operation in @[@"erode", @"dilate", @"open", @"close"])
            for (int radius = 1; radius <= 5; radius++) {
                ROI *roi = brush(masks[m], widths[m], heights[m]);
                id filter = [[[filterClass alloc] init] autorelease];
                SEL selector = NSSelectorFromString([operation stringByAppendingString:@":withStructuringElementRadius:"]);
                ((void (*)(id, SEL, ROI *, int))objc_msgSend)(filter, selector, roi, radius);
                StubRecord(@"brush mask %d %@ radius %d: %@", m, operation, radius, [roi describe]);
            }
}

int main()
{
    @autoreleasepool {
        NSArray *names = @[OsirixAddROINotification, OsirixROIChangeNotification, OsirixROISelectedNotification];
        for (NSString *name in names)
            [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
                id object = note.object;
                StubRecord(@"notification %@ object %@ ROI %@ slice %@", note.name,
                           [object isKindOfClass:[ROI class]] ? [object name] : NSStringFromClass([object class]),
                           [note.userInfo[@"ROI"] name], note.userInfo[@"sliceNumber"]);
            }];
        std::vector<float> volume = phantom();
        importGeometry(volume);
        regionGrowing(volume);
        contours(volume);
        resampling(volume);
        morphology(volume);
        StubRecord(@"done");
    }
    return 0;
}
'''

DRIVER = DRIVER.replace('#import <Cocoa/Cocoa.h>', '#import <Cocoa/Cocoa.h>\n#import <objc/message.h>', 1)

failures = 0
with tempfile.TemporaryDirectory() as folder:
    outputs = {}
    for kind in ('old', 'new'):
        try:
            probe = itk_harness.build(kind, folder, DRIVER)
        except RuntimeError as error:
            print('FAIL: the %s probe does not build: %s' % (kind, error), file=sys.stderr)
            sys.exit(1)
        try:
            run = subprocess.run([str(probe)], capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            print('FAIL: the %s probe did not finish within 120 s' % kind, file=sys.stderr)
            sys.exit(1)
        if run.returncode != 0:
            print(run.stdout[-3000:])
            print(run.stderr[-3000:], file=sys.stderr)
            print('FAIL: the %s probe exited with %d' % (kind, run.returncode), file=sys.stderr)
            sys.exit(1)
        outputs[kind] = run.stdout.splitlines()

    old, new = outputs['old'], outputs['new']
    if not old or old[-1] != 'done':
        print('FAIL: the former classes did not run to the end', file=sys.stderr)
        sys.exit(1)
    differing = [(index, a, b) for index, (a, b) in enumerate(zip(old, new)) if a != b]
    if len(old) != len(new):
        differing.append((min(len(old), len(new)), '%d lines' % len(old), '%d lines' % len(new)))
    for index, a, b in differing[:20]:
        print('FAIL line %d:\n  before: %s\n  now:    %s' % (index + 1, a[:400], b[:400]))
    if differing:
        print('FAIL: %d of %d lines differ' % (len(differing), len(old)))
        sys.exit(1)

    def count(prefix):
        return sum(1 for line in old if line.startswith(prefix))

    print('PASS: %d lines the same: %d region growing cases, %d contours, %d volume imports, %d resamplings, %d brush filters'
          % (len(old), count('== '), count('contour '), count('import '), count('resample ') + count('reorient'), count('brush ')))
