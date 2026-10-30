"""Build a probe that runs the app's ITK code, before and after its adapter.

The region growing, the resampling by a transform and the brush ROI filters
were Objective-C++ classes over ITK (ITK.mm, ITKSegmentation3D.mm,
ITKTransform.mm, ITKBrushROIFilter.mm). They are now Swift classes of the same
Objective-C names (ITKSegmentation3D, ITKTransform, ITKBrushROIFilter, with
ITKVolumeImport), the rules in IsiXSegmentation, and ITK and VTK behind the
adapters in Horos/Sources/Adapters/ITK and Adapters/VTK.

A probe is an Objective-C driver linked either with
- `old`: the Objective-C++ classes read from a revision of this history that
  still has them (ITKSegmentation3D.mm and ITK.mm whole; the resampling
  methods of ITKTransform.mm; ITKBrushROIFilter.mm whole), or
- `new`: this checkout's Swift classes, its adapters and IsiXSegmentation,

both against the ITK and VTK the Debug build installed, and both on the same
stand-ins for the app's classes (ViewerController, DCMView, DCMPix, ROI,
MyPoint, WaitRendering), which record what is done to them. The driver sees
`OLD_ITK` defined for the former.

`installs()` is None without a Debug build (the test then exits 2).
"""
from pathlib import Path
import re
import subprocess

import history_reference
import isix_modules

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Horos/Sources'
ADAPTERS = SOURCES / 'Adapters'
OLD_FILES = ('ITK.h', 'ITK.mm', 'ITKSegmentation3D.h', 'ITKSegmentation3D.mm', 'ITKTransform.h', 'ITKTransform.mm',
             'ITKBrushROIFilter.h', 'ITKBrushROIFilter.mm')
SWIFT_FILES = ('ITKVolumeImport.swift', 'ITKSegmentation3D.swift', 'ITKSegmentation3D+RegionGrowing.swift',
               'ITKSegmentation3D+Results.swift', 'ITKTransform.swift', 'ITKBrushROIFilter.swift')
ADAPTER_FILES = ('ITK/IsiXITKError.mm', 'ITK/IsiXITKVolume.mm', 'ITK/IsiXITKRegionGrowing.mm', 'ITK/IsiXITKResampler.mm',
                 'VTK/IsiXVTKError.mm', 'VTK/IsiXVTKContour.mm')


def installs(configuration='Debug'):
    """(ITK install, VTK install) of a build of `configuration`, or None."""
    for base in (ROOT / 'build', ROOT / 'build/Build'):
        folder = base / 'Intermediates.noindex/Horos.build' / configuration
        itk, vtk = folder / 'ITK.build/Install', folder / 'VTK.build/Install'
        if (itk / 'wlib/libITK.a').is_file() and (vtk / 'wlib/libVTK.a').is_file():
            return itk, vtk
    return None


def old_revision():
    """The last revision with the Objective-C++ classes, or None."""
    path = 'Horos/Sources/ITKSegmentation3D.mm'
    revision = history_reference.before_removal(path)
    if revision is None and subprocess.run(['git', '-C', str(ROOT), 'cat-file', '-e', 'HEAD:' + path],
                                           capture_output=True).returncode == 0:
        revision = 'HEAD'
    return revision


# The app's classes the ITK code talks to, reduced to what it reads and what
# it does to them, which they record (StubRecord). Their Swift names are those
# of the app's classes.
STUBS_H = r'''
#import <Cocoa/Cocoa.h>

typedef NS_ENUM(short, ToolMode) { tWL = 0, tCPolygon = 11, tPlain = 20 };
enum { ROI_sleep = 0, ROI_drawing = 1, ROI_selected = 2, ROI_selectedModify = 3 };

extern NSString* const OsirixAddROINotification;
extern NSString* const OsirixROIChangeNotification;
extern NSString* const OsirixROISelectedNotification;

void StubRecord(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
NSString *StubHash(const void *bytes, size_t length);

@interface MyPoint : NSObject
- (instancetype)initWithPoint:(NSPoint)a;
+ (MyPoint *)point:(NSPoint)a NS_SWIFT_UNAVAILABLE("init(point:)");
@property NSPoint point;
@end

@interface DCMPix : NSObject <NSCopying>
@property long pwidth, pheight;
@property double originX, originY, originZ, pixelSpacingX, pixelSpacingY, sliceInterval, sliceThickness;
@property float minValueOfSeries;
@property float *fImage;
@property (readonly) double *orientation;
- (void)orientationDouble:(double *)c;
- (float)getPixelValueX:(long)x Y:(long)y NS_SWIFT_NAME(getPixelValueX(_:y:));
+ (NSPoint)originCorrectedAccordingToOrientation:(DCMPix *)pix NS_SWIFT_NAME(originCorrected(accordingToOrientation:));
@end

@interface ROI : NSObject
- (id)initWithTexture:(unsigned char *)tBuff textWidth:(int)tWidth textHeight:(int)tHeight textName:(NSString *)tName
            positionX:(int)posX positionY:(int)posY spacingX:(float)ipixelSpacingx spacingY:(float)ipixelSpacingy
          imageOrigin:(NSPoint)iimageOrigin;
- (id)initWithType:(long)type;
@property (readonly) int textureWidth, textureHeight;
@property (readonly) unsigned char *textureBuffer;
@property (readonly) int textureUpLeftCornerX, textureUpLeftCornerY;
- (BOOL)reduceTextureIfPossible;
- (void)addMarginToBuffer:(int)margin;
- (void)textureBufferHasChanged;
@property (nonatomic, copy) NSString *name;
@property (retain) NSString *comments;
@property (nonatomic, setter=setROIMode:) long ROImode;
@property (nonatomic, setter=setColor:) RGBColor rgbcolor;
@property double sliceThickness;
@property (retain) NSMutableArray *points;
@property (readonly) long type;
- (NSString *)describe;
@end

@interface DCMView : NSObject
@property NSInteger curImage;
@property (retain) DCMPix *curDCM;
- (void)setIndex:(NSInteger)index;
- (void)sendSyncMessage:(NSInteger)inc;
- (void)roiSet;
- (void)selectAll:(id)sender;
@end

@interface ViewerController : NSObject
@property (retain) NSMutableArray *pixArray, *roiArray;
@property float *volume;
@property (retain) DCMView *view;
- (NSMutableArray *)pixList;
- (float *)volumePtr;
- (NSMutableArray *)roiList;
- (DCMView *)imageView;
- (void)needsDisplayUpdate;
- (void)adjustSlider;
- (IBAction)mergeBrushROI:(id)sender ROIs:(NSArray *)s ROIList:(NSMutableArray *)roiList NS_SWIFT_NAME(mergeBrushROI(_:rois:roiList:));
- (IBAction)mergeBrushROI:(id)sender;
- (ROI *)newROI:(ToolMode)type NS_SWIFT_UNAVAILABLE("ownership");
- (ROI *)horosMakeROI:(ToolMode)type;
- (MyPoint *)newPoint:(float)x :(float)y NS_SWIFT_UNAVAILABLE("ownership");
@end

@interface WaitRendering : NSObject
- (id)init:(NSString *)message;
- (void)showWindow:(id)sender;
- (void)setString:(NSString *)string;
- (void)close;
@end

static inline void HorosRunAlertPanel(NSString *a, NSString *b, NSString *c, NSString *d, NSString *e) { StubRecord(@"alert %@", a); }
static inline void HorosRunCriticalAlertPanel(NSString *a, NSString *b, NSString *c, NSString *d, NSString *e) { StubRecord(@"alert %@", a); }
'''

STUBS_M = r'''
#import "Stubs.h"
#include <CommonCrypto/CommonDigest.h>

NSString* const OsirixAddROINotification = @"OsirixAddROINotification";
NSString* const OsirixROIChangeNotification = @"OsirixROIChangeNotification";
NSString* const OsirixROISelectedNotification = @"OsirixROISelectedNotification";

void StubRecord(NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    NSString *line = [[[NSString alloc] initWithFormat:format arguments:arguments] autorelease];
    va_end(arguments);
    printf("%s\n", line.UTF8String);
}

NSString *StubHash(const void *bytes, size_t length)
{
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes, (CC_LONG)length, digest);
    NSMutableString *text = [NSMutableString string];
    for (int i = 0; i < 8; i++) [text appendFormat:@"%02x", digest[i]];
    return text;
}

@implementation MyPoint
- (instancetype)initWithPoint:(NSPoint)a { if ((self = [super init])) _point = a; return self; }
+ (MyPoint *)point:(NSPoint)a { return [[[MyPoint alloc] initWithPoint:a] autorelease]; }
@end

@implementation DCMPix {
    double _orientation[9];
}
- (instancetype)init
{
    if ((self = [super init])) { _orientation[0] = _orientation[4] = _orientation[8] = 1; }
    return self;
}
- (double *)orientation { return _orientation; }
- (void)orientationDouble:(double *)c { for (int i = 0; i < 9; i++) c[i] = _orientation[i]; }
- (float)getPixelValueX:(long)x Y:(long)y { return _fImage[y * _pwidth + x]; }
+ (NSPoint)originCorrectedAccordingToOrientation:(DCMPix *)pix { return NSMakePoint(pix.originX, pix.originY); }
- (id)copyWithZone:(NSZone *)zone
{
    DCMPix *copy = [[DCMPix alloc] init];
    copy.pwidth = _pwidth; copy.pheight = _pheight; copy.originX = _originX; copy.originY = _originY; copy.originZ = _originZ;
    copy.pixelSpacingX = _pixelSpacingX; copy.pixelSpacingY = _pixelSpacingY; copy.sliceInterval = _sliceInterval;
    copy.sliceThickness = _sliceThickness; copy.minValueOfSeries = _minValueOfSeries; copy.fImage = _fImage;
    [self orientationDouble:copy.orientation];
    return copy;
}
@end

@implementation ROI {
    unsigned char *_buffer;
    int _width, _height, _x, _y;
}
- (id)initWithTexture:(unsigned char *)tBuff textWidth:(int)tWidth textHeight:(int)tHeight textName:(NSString *)tName
            positionX:(int)posX positionY:(int)posY spacingX:(float)sx spacingY:(float)sy imageOrigin:(NSPoint)o
{
    if ((self = [super init])) {
        _type = tPlain;
        _width = tWidth; _height = tHeight; _x = posX; _y = posY;
        _buffer = (unsigned char *)malloc((size_t)tWidth * tHeight + 1);
        if (tBuff) memcpy(_buffer, tBuff, (size_t)tWidth * tHeight);
        self.name = tName;
        _points = [[NSMutableArray alloc] init];
        StubRecord(@"ROI texture %@ %dx%d at %d,%d spacing %.9g %.9g origin %.9g %.9g bytes %@", tName, tWidth, tHeight, posX, posY,
                   sx, sy, o.x, o.y, StubHash(_buffer, (size_t)tWidth * tHeight));
    }
    return self;
}
- (id)initWithType:(long)type
{
    if ((self = [super init])) { _type = type; _points = [[NSMutableArray alloc] init]; }
    return self;
}
- (void)dealloc { free(_buffer); [_points release]; [_name release]; [_comments release]; [super dealloc]; }
- (int)textureWidth { return _width; }
- (int)textureHeight { return _height; }
- (unsigned char *)textureBuffer { return _buffer; }
- (int)textureUpLeftCornerX { return _x; }
- (int)textureUpLeftCornerY { return _y; }
- (void)textureBufferHasChanged { StubRecord(@"ROI %@ texture changed", _name); }
// The bounding box of the set bytes, as the app's ROI reduces its texture; YES when there is none.
- (BOOL)reduceTextureIfPossible
{
    int minX = _width, minY = _height, maxX = -1, maxY = -1;
    for (int y = 0; y < _height; y++)
        for (int x = 0; x < _width; x++)
            if (_buffer[y * _width + x]) {
                if (x < minX) minX = x;
                if (x > maxX) maxX = x;
                if (y < minY) minY = y;
                if (y > maxY) maxY = y;
            }
    if (maxX < 0) return YES;
    int w = maxX - minX + 1, h = maxY - minY + 1;
    unsigned char *reduced = (unsigned char *)malloc((size_t)w * h + 1);
    for (int y = 0; y < h; y++) memcpy(reduced + y * w, _buffer + (y + minY) * _width + minX, w);
    free(_buffer);
    _buffer = reduced; _width = w; _height = h; _x += minX; _y += minY;
    return NO;
}
- (void)addMarginToBuffer:(int)margin
{
    int w = _width + 2 * margin, h = _height + 2 * margin;
    unsigned char *grown = (unsigned char *)calloc((size_t)w * h + 1, 1);
    for (int y = 0; y < _height; y++) memcpy(grown + (y + margin) * w + margin, _buffer + y * _width, _width);
    free(_buffer);
    _buffer = grown; _width = w; _height = h; _x -= margin; _y -= margin;
}
- (void)setROIMode:(long)mode { _ROImode = mode; StubRecord(@"ROI %@ mode %ld", _name, mode); }
- (void)setColor:(RGBColor)colour { _rgbcolor = colour; StubRecord(@"ROI %@ colour %u %u %u", _name, colour.red, colour.green, colour.blue); }
- (void)setComments:(NSString *)comments { [_comments release]; _comments = [comments copy]; StubRecord(@"ROI %@ comments %@", _name, comments); }
- (void)setSliceThickness:(double)thickness { _sliceThickness = thickness; StubRecord(@"ROI %@ thickness %.9g", _name, thickness); }
- (NSString *)describe
{
    NSMutableString *text = [NSMutableString stringWithFormat:@"%@ type %ld mode %ld", _name, _type, _ROImode];
    if (_buffer) [text appendFormat:@" texture %dx%d at %d,%d %@", _width, _height, _x, _y, StubHash(_buffer, (size_t)_width * _height)];
    if (_points.count) {
        [text appendFormat:@" %lu points", (unsigned long)_points.count];
        for (MyPoint *p in _points) [text appendFormat:@" %.9g,%.9g", p.point.x, p.point.y];
    }
    return text;
}
@end

@implementation DCMView
- (void)setIndex:(NSInteger)index { _curImage = index; StubRecord(@"view setIndex %ld", (long)index); }
- (void)sendSyncMessage:(NSInteger)inc { StubRecord(@"view sendSyncMessage %ld", (long)inc); }
- (void)roiSet { StubRecord(@"view roiSet"); }
- (void)selectAll:(id)sender { StubRecord(@"view selectAll"); }
@end

@implementation ViewerController
- (NSMutableArray *)pixList { return _pixArray; }
- (float *)volumePtr { return _volume; }
- (NSMutableArray *)roiList { return _roiArray; }
- (DCMView *)imageView { return _view; }
- (void)needsDisplayUpdate { StubRecord(@"viewer needsDisplayUpdate"); }
- (void)adjustSlider { StubRecord(@"viewer adjustSlider"); }
- (IBAction)mergeBrushROI:(id)sender ROIs:(NSArray *)s ROIList:(NSMutableArray *)roiList
{
    StubRecord(@"viewer mergeBrushROI %lu ROIs", (unsigned long)s.count);
}
- (IBAction)mergeBrushROI:(id)sender { StubRecord(@"viewer mergeBrushROI"); }
- (ROI *)horosMakeROI:(ToolMode)type
{
    ROI *roi = [[[ROI alloc] initWithType:type] autorelease];
    [_view roiSet];
    return roi;
}
- (ROI *)newROI:(ToolMode)type { return [self horosMakeROI:type]; }
- (MyPoint *)newPoint:(float)x :(float)y { return [MyPoint point:NSMakePoint(x, y)]; }
@end

@implementation WaitRendering
- (id)init:(NSString *)message { if ((self = [super init])) StubRecord(@"wait %@", message); return self; }
- (void)showWindow:(id)sender { StubRecord(@"wait shown"); }
- (void)setString:(NSString *)string { StubRecord(@"wait %@", string); }
- (void)close { StubRecord(@"wait closed"); }
@end
'''

# What the former classes imported, each now the stand-ins.
STUB_HEADERS = ('ViewerController.h', 'ViewerController+CAPI.h', 'DCMPix.h', 'DCMView.h', 'ROI.h', 'MyPoint.h', 'WaitRendering.h',
                'Notifications.h', 'HorosAlertPanel.h', 'options.h', 'OSIVoxel.h', 'AppController.h', 'N2Debug.h')

# The Swift of ITKTransform+Viewer.swift opens a viewer; the probe has none.
SWIFT_NO_VIEWER = r'''
import Cocoa
extension ITKTransform {
    @objc(createNewViewerWithBuffer:length:resampleOnViewer:rescale:)
    public func createNewViewer(withBuffer fVolumePtr: UnsafeMutablePointer<Float>?, length: Int,
                                resampleOnViewer referenceViewer: ViewerController!, rescale: Bool) -> ViewerController! {
        free(fVolumePtr)
        return nil
    }
}
'''


def _run(command, what):
    done = subprocess.run(command, capture_output=True, text=True)
    if done.returncode != 0:
        raise RuntimeError('%s failed:\n%s' % (what, (done.stderr or done.stdout)[-6000:]))
    return done


def _write_stubs(folder):
    (folder / 'Stubs.h').write_text(STUBS_H)
    (folder / 'Stubs.m').write_text(STUBS_M)
    for name in STUB_HEADERS:
        (folder / name).write_text('#import "Stubs.h"\n')


def _method(text, signature):
    """The method whose declaration starts with `signature`, braces included."""
    at = text.index(signature)
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[at:index + 1]
    raise ValueError(signature)


def _old_transform(text):
    """The resampling methods of the former ITKTransform.mm, as a class."""
    head = text[:text.index('@implementation ITKTransform')]
    methods = [_method(text, '+ (float*) resampleWithParameters: (double*)theParameters firstObject: (DCMPix*) firstObject '
                             'firstObjectOriginal: (DCMPix*)  firstObjectOriginal noOfImages: (int) noOfImages length: (long*) length '
                             'itkImage: (ITK*) itkImage\n'),
               _method(text, '+ (float*) resampleWithParameters: (double*)theParameters firstObject: (DCMPix*) firstObject '
                             'firstObjectOriginal: (DCMPix*)  firstObjectOriginal noOfImages: (int) noOfImages length: (long*) length '
                             'itkImage: (ITK*) itkImage rescale: (BOOL) rescale'),
               _method(text, '+ (float*) reorient2Dimage:')]
    return (head + '\n#define N2LogException(e) NSLog(@"exception %@", e)\n#define N2LogStackTrace(...) NSLog(__VA_ARGS__)\n'
            '@implementation ITKTransform\n' + '\n\n'.join(methods) + '\n@end\n')


def build(kind, folder, driver, configuration='Debug'):
    """The probe `kind` ('old' or 'new') with the Objective-C `driver`, in `folder`. Its path."""
    itk, vtk = installs(configuration) or installs('Debug')
    folder = Path(folder) / kind
    folder.mkdir(parents=True, exist_ok=True)
    _write_stubs(folder)
    (folder / 'driver.mm').write_text(driver)
    optimise = '-O0' if configuration == 'Debug' else '-Os'
    includes = ['-I', str(folder), '-I', str(itk / 'include'), '-I', str(vtk / 'include')]
    common = ['xcrun', 'clang++', '-std=c++17', '-x', 'objective-c++', optimise, '-w', '-c']
    objects = []

    def compile_mm(source, arc, extra=()):
        output = folder / (Path(source).stem + '.o')
        _run(common + (['-fobjc-arc'] if arc else ['-fno-objc-arc']) + list(extra) + includes + [str(source), '-o', str(output)],
             'compiling ' + Path(source).name)
        objects.append(str(output))

    compile_mm(folder / 'Stubs.m', False)
    if kind == 'old':
        revision = old_revision()
        for name in OLD_FILES:
            (folder / name).write_bytes(history_reference.show(revision, 'Horos/Sources/' + name))
        transform = (folder / 'ITKTransform.mm').read_bytes().decode('latin1')
        (folder / 'ITKTransformResample.mm').write_text(_old_transform(transform), encoding='latin1')
        for name in ('ITK.mm', 'ITKSegmentation3D.mm', 'ITKTransformResample.mm', 'ITKBrushROIFilter.mm'):
            compile_mm(folder / name, False)
        compile_mm(folder / 'driver.mm', False, ['-DOLD_ITK=1'])
        executable = folder / 'probe'
        _run(['xcrun', 'clang++', *objects, str(itk / 'wlib/libITK.a'), str(vtk / 'wlib/libVTK.a'), '-lz',
              '-framework', 'Cocoa', '-framework', 'Accelerate', '-o', str(executable)], 'linking the former classes')
        return executable

    for name in ADAPTER_FILES:
        source = ADAPTERS / name
        output = folder / (source.stem + '.o')
        _run(common + ['-fobjc-arc', '-I', str(source.parent)] + includes + [str(source), '-o', str(output)], 'compiling ' + name)
        objects.append(str(output))
    bridging = folder / 'Bridging.h'
    bridging.write_text('#import "Stubs.h"\n' + ''.join('#import "%s"\n' % (ADAPTERS / name)
                                                        for name in ('ITK/IsiXITKError.h', 'ITK/IsiXITKVolume.h',
                                                                     'ITK/IsiXITKRegionGrowing.h', 'ITK/IsiXITKResampler.h',
                                                                     'VTK/IsiXVTKContour.h')))
    (folder / 'NoViewer.swift').write_text(SWIFT_NO_VIEWER)
    modules = isix_modules.module_flags('IsiXSegmentation', folder / 'modules',
                                        ['-Onone'] if configuration == 'Debug' else ['-O'])
    swift_object = folder / 'swift.o'
    _run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-module-name', 'Harness', '-wmo',
          '-Onone' if configuration == 'Debug' else '-O', '-import-objc-header', str(bridging), *modules,
          '-c', '-o', str(swift_object), *[str(SOURCES / name) for name in SWIFT_FILES], str(folder / 'NoViewer.swift')],
         'compiling the Swift classes')
    compile_mm(folder / 'driver.mm', False)
    executable = folder / 'probe'
    _run(['xcrun', 'swiftc', '-o', str(executable), str(swift_object), *objects, *modules,
          str(itk / 'wlib/libITK.a'), str(vtk / 'wlib/libVTK.a'), '-lz', '-lc++',
          '-framework', 'Cocoa', '-framework', 'Accelerate'], 'linking the Swift classes')
    return executable
