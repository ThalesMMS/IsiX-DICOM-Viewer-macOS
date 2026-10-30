"""Build a probe linked with a ROI, as the application compiled it.

A ROI is characterized by running the same Objective-C probe against two
builds of it: the revision before a change, read from git, and this checkout.
Each harness links the probe with:

* the ROI. An Objective-C ROI.m (the revision's, or this checkout's while it
  has one) is compiled with the command the application's build logged for an
  Objective-C file of the app; a ROI written in Swift is linked as the objects
  the application's build produced for it, with the Swift objects they need.
* DCMPix.m of the same revision, compiled the same way, for the statistics.
* the Swift the ROI draws and labels with (the canvas, the text overlay, the
  label layout), as the application's build produced it, for both harnesses.
* the internal module IsiXROI: the application's build of it for this
  checkout, the revision's sources compiled for an earlier revision.

A revision's ROI.m and DCMPix.m are compiled against the revision's ROI.h and
DCMPix.h, through a file-system overlay; the generated Horos-Swift.h is used
without the classes those headers declare, which a Swift ROI adds to it.

Project classes the objects name and none of them defines are empty stubs:
any message to them answers zero.
"""
from pathlib import Path
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import object_probe  # noqa: E402
sys.path.insert(0, str(ROOT / 'tests'))
import isix_modules  # noqa: E402
import horos_reader  # noqa: E402

SKIPPED = 2
WORKTREE = 'WORKTREE'
ROI_SOURCE = 'Horos/Sources/ROI.m'
PIX_SOURCE = 'Horos/Sources/DCMPix.m'
MODULE = 'IsiXROI'
# The headers a revision's own sources are compiled against.
OVERLAID_HEADERS = ('Horos/Sources/ROI.h', 'Horos/Sources/DCMPix.h')
# What a ROI draws and labels with: the Swift objects of the application, by file.
SUPPORT = ('HorosObjCException', 'AnnotationLevel', 'AnnotationOverlay', 'AnnotationPresentation', 'BrushLabelAnchor', 'ROILabelPresentation',
           'LengthPresentation', 'ROICanvas', 'ROILabelContrast', 'MyPoint')
# The Objective-C files whose logged command compiles any Objective-C file of the app.
COMMAND_SOURCES = (ROI_SOURCE, PIX_SOURCE, 'Horos/Sources/DCMPix+CAPI.m', 'Horos/Sources/DCMView+CAPI.m', 'Horos/Sources/ViewerController.m',
                   'Horos/Sources/ViewerController+CAPI.m')


# What a probe that sets a DCMPix's state directly reads and writes it with:
# the Objective-C class kept it in instance variables of these names, the Swift
# one keeps it under horos_ and the same names. PIX_IVAR(object, type, name) is
# the variable, of the type the Objective-C declared; PIX_ORIENTATION(object)
# the nine cosines, an array in the Objective-C class and the first pointer of
# the Swift class's fixed arrays (horos_arrays); PIX_KERNEL(object) the 25
# convolution weights, the second.
PIX_IVARS = r'''
#import <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
static void *ProbePixIvar( id object, const char *name)
{
    Ivar ivar = class_getInstanceVariable( [object class], name);
    if( ivar == NULL)
    {
        char prefixed[ 256];
        snprintf( prefixed, sizeof prefixed, "horos_%s", name);
        ivar = class_getInstanceVariable( [object class], prefixed);
    }
    if( ivar == NULL) { fprintf( stderr, "no instance variable %s\n", name); exit( 3); }
    return (char*) (__bridge void*) object + ivar_getOffset( ivar);
}
static void *ProbePixArray( id object, const char *name, int index)
{
    if( class_getInstanceVariable( [object class], name)) return ProbePixIvar( object, name);
    return ((void**) ProbePixIvar( object, "arrays"))[ index];
}
#define PIX_IVAR( object, type, name) (*(type*) ProbePixIvar( object, #name))
#define PIX_ORIENTATION( object) ((double*) ProbePixArray( object, "orientation", 0))
#define PIX_KERNEL( object) ((float*) ProbePixArray( object, "kernel", 1))
'''


# The Objective-C a probe of the ROI starts with: a view that answers what a
# ROI asks DCMView, its window and image (an ultrasound one too), the frame the
# view would show, and setUp(), which puts the preferences in the argument
# domain and makes the window. A probe adds its own main().
PRELUDE = r'''
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import "ROI.h"
#import "DCMPix.h"
#import "MyPoint.h"
#import "Horos-Swift.h"

// Declared in ROI.h or not, these are what the viewer and the tools send.
@interface ROI (InteractionCharacterization)
- (void) drawTextualData;
- (BOOL) mouseRoiDown:(NSPoint) pt :(int) slice :(float) scale;
- (void) setTextBoxOffset:(NSPoint) o;
- (NSRect) textualDataContourRect;
@end

// What a call answers, or the exception it raised.
#define ATTEMPT(expr) ({ id _r = nil; @try { _r = (expr); } @catch( NSException *e) { _r = [@"exception " stringByAppendingString: e.name]; } _r; })
#define ATTEMPT_VOID(statement) ({ id _r = nil; @try { statement; } @catch( NSException *e) { _r = [@"exception " stringByAppendingString: e.name]; } _r; })

static NSPoint gMouse;          // where the window says the pointer is, in its own coordinates
static float gScale = 6;        // the view's zoom: image pixels to backing pixels
static const int kSide = 64;    // the image
static const int kFrame = 512;  // the view's backing pixels
static CGFloat gBacking = 2;     // the window's backing scale factor

@interface ProbeWindow : NSWindow
@end
@implementation ProbeWindow
- (CGFloat) backingScaleFactor { return gBacking; }
- (NSColorSpace*) colorSpace { return [NSColorSpace sRGBColorSpace]; }
- (NSPoint) mouseLocationOutsideOfEventStream { return gMouse; }
@end

// The state of a DCMPix the probe sets as the class keeps it.
PIX_IVARS

@interface ProbePix : DCMPix
@end
@implementation ProbePix
- (void) CheckLoad {}
- (void) applyShutter {}
- (BOOL) thickSlabVRActivated { return NO; }
- (float*) computefImageForMeasurement { return PIX_IVAR( self, float*, fImage); }
- (BOOL) hasUSRegions { return NO; }
+ (ProbePix*) pixWithSpacing:(double) spacing originZ:(double) z
{
    ProbePix *pix = [[[self alloc] init] autorelease];
    PIX_IVAR( pix, long, width) = kSide; PIX_IVAR( pix, long, height) = kSide; PIX_IVAR( pix, BOOL, isRGB) = NO;
    float *pixels = (float*) calloc( kSide * kSide, sizeof( float));
    PIX_IVAR( pix, float*, fImage) = pixels;
    PIX_IVAR( pix, NSArray*, pixArray) = [[NSArray arrayWithObject: [NSNull null]] retain];
    PIX_IVAR( pix, double, pixelSpacingX) = spacing; PIX_IVAR( pix, double, pixelSpacingY) = spacing * 1.25;
    PIX_IVAR( pix, double, pixelRatio) = 1.25;
    PIX_IVAR( pix, double, sliceThickness) = 2.5; PIX_IVAR( pix, double, sliceInterval) = 2.0;
    PIX_IVAR( pix, double, originX) = -30.5; PIX_IVAR( pix, double, originY) = 12.25; PIX_IVAR( pix, double, originZ) = z;
    double cosines[ 6] = { 1, 0, 0, 0, 1, 0};
    [pix setOrientationDouble: cosines];
    pix.frameofReferenceUID = @"1.2.826.0.1.3680043.2.1125.1";
    pix.rescaleType = @"HU";
    for( int y = 0; y < kSide; y++)
        for( int x = 0; x < kSide; x++)
            pixels[ y * kSide + x] = (float)( x * 3.25 - y * 7.5) + ((x / 8 + y / 8) % 2 ? 1200.75f : -17.125f);
    return pix;
}
@end

/// An ultrasound region: the class of the internal module IsiXImaging, as
/// DCMPix keeps one. The Swift ROI reads its properties directly, which only
/// an object of that class answers; an Objective-C ROI reads them by message.
/// The module's generated interface declares it when the build has one, as the
/// application's headers import it; the probe declares what it sets otherwise.
#if __has_include("IsiXImaging-Swift.h")
#import "IsiXImaging-Swift.h"
#else
@interface IsiXUSRegion : NSObject
@property int regionSpatialFormat, regionLocationMinX0, regionLocationMinY0, regionLocationMaxX1, regionLocationMaxY1;
@property int referencePixelX0, referencePixelY0, physicalUnitsXDirection, physicalUnitsYDirection;
@property double refPixelPhysicalValueX, refPixelPhysicalValueY, physicalDeltaX, physicalDeltaY;
@property BOOL isReferencePixelX0Present, isReferencePixelY0Present;
@end
#endif
@compatibility_alias ProbeUSRegion IsiXUSRegion;
@interface IsiXUSRegion (Probe)
+ (ProbeUSRegion*) format:(int) f x0:(int) x0 y0:(int) y0 x1:(int) x1 y1:(int) y1 unitsX:(int) ux unitsY:(int) uy;
@end
@implementation IsiXUSRegion (Probe)
+ (ProbeUSRegion*) format:(int) f x0:(int) x0 y0:(int) y0 x1:(int) x1 y1:(int) y1 unitsX:(int) ux unitsY:(int) uy
{
    ProbeUSRegion *r = [[[IsiXUSRegion alloc] init] autorelease];
    r.regionSpatialFormat = f; r.regionLocationMinX0 = x0; r.regionLocationMinY0 = y0; r.regionLocationMaxX1 = x1; r.regionLocationMaxY1 = y1;
    r.physicalUnitsXDirection = ux; r.physicalUnitsYDirection = uy; r.physicalDeltaX = 0.0125; r.physicalDeltaY = -1.5;
    r.referencePixelX0 = 3; r.referencePixelY0 = 5; r.refPixelPhysicalValueX = 0.25; r.refPixelPhysicalValueY = -2;
    r.isReferencePixelX0Present = YES; r.isReferencePixelY0Present = YES;
    return r;
}
@end

/// An ultrasound image: its regions say what its pixels measure.
@interface ProbeUSPix : ProbePix
@property(retain) NSArray *regions;
@end
@implementation ProbeUSPix
- (BOOL) hasUSRegions { return YES; }
- (NSArray*) usRegions { return self.regions; }
@end

/// The DCMView a ROI asks: its image, zoom, conversions and label bookkeeping.
@interface ProbeView : NSView
@property(retain) DCMPix *curDCM;
@property(retain) NSMutableArray *curRoiList, *rectArray, *dcmPixList;
@property float rotation;
@property NSPoint origin;
@property BOOL xFlipped, yFlipped, eraserFlag, suppressLabels, is2DViewer, flippedData;
@property NSInteger curImage;
@property ToolMode currentTool;
@end
@implementation ProbeView
- (NSRect) drawingFrameRect { return NSMakeRect( 0, 0, kFrame, kFrame); }
- (DCMView*) blendingView { return nil; }
- (float) scaleValue { return gScale; }
// As DCMView converts with no rotation: image pixels to the view's backing
// pixels from its centre, y down, and back.
- (NSPoint) ConvertFromGL2View:(NSPoint) a
{
    float ratio = self.curDCM.pixelRatio;
    return NSMakePoint( (a.x - kSide / 2.) * gScale + self.origin.x, (a.y - kSide / 2.) * ratio * gScale - self.origin.y);
}
- (NSPoint) ConvertFromView2GL:(NSPoint) a
{
    float ratio = self.curDCM.pixelRatio;
    return NSMakePoint( (a.x - self.origin.x) / gScale + kSide / 2., (a.y + self.origin.y) / (gScale * ratio) + kSide / 2.);
}
- (NSPoint) ConvertFromNSView2GL:(NSPoint) a { return [self ConvertFromView2GL: NSMakePoint( a.x * 2 - kFrame / 2., kFrame / 2. - a.y * 2)]; }
- (NSPoint) ConvertFromGL2GL:(NSPoint) a toView:(id) v { return a; }
// As DCMView's.
- (void) applyImageTransformation
{
    HorosROICanvas *canvas = [HorosROICanvas current];
    [canvas loadIdentity];
    [canvas scaleX: 2.0f / (self.xFlipped ? -kFrame : kFrame) y: -2.0f / (self.yFlipped ? -kFrame : kFrame) z: 1];
    [canvas rotate: self.rotation];
    [canvas translateX: self.origin.x y: -self.origin.y z: 0];
    [canvas scaleX: 1 y: self.curDCM.pixelRatio z: 1];
}
@end

static ProbeView *view;
static NSMutableArray *notes;
static NSString *dumpFolder;

static NSString *F( double v) { return [NSString stringWithFormat: @"%a", v]; }
static NSString *P( NSPoint p) { return [NSString stringWithFormat: @"%a,%a", p.x, p.y]; }
static NSString *R( NSRect r) { return [NSString stringWithFormat: @"%a,%a,%a,%a", r.origin.x, r.origin.y, r.size.width, r.size.height]; }

static NSArray *pointsOf( NSArray *points)
{
    NSMutableArray *a = [NSMutableArray array];
    for( MyPoint *p in points) [a addObject: P( p.point)];
    return a;
}

static NSMutableArray *myPoints( double *xy, int count)
{
    NSMutableArray *a = [NSMutableArray array];
    for( int i = 0; i < count; i++) [a addObject: [MyPoint point: NSMakePoint( xy[ 2*i], xy[ 2*i+1])]];
    return a;
}

static unsigned long long hashBytes( const unsigned char *b, size_t n)
{
    unsigned long long h = 1469598103934665603ULL;
    for( size_t i = 0; i < n; i++) { h ^= b[ i]; h *= 1099511628211ULL; }
    return h;
}

static void observe( NSNotification *n)
{
    ROI *roi = n.object;
    NSString *action = [n.userInfo objectForKey: @"action"];
    [notes addObject: [NSString stringWithFormat: @"%@ %@%@", n.name, roi.name, action ? [@" " stringByAppendingString: action] : @""]];
}

/// The frame the view would show: every ROI of its list drawn, then labelled.
static NSDictionary *picture( NSString *label, BOOL highlight)
{
    HorosAnnotationOverlay *overlay = [HorosAnnotationOverlay overlayForView: view];
    [overlay beginFrameWidth: kFrame height: kFrame];
    HorosROICanvas *canvas = [HorosROICanvas current];
    [canvas setModelview: CGAffineTransformIdentity viewport: NSMakeRect( 0, 0, kFrame, kFrame)];
    [canvas resetFrameState];
    [view applyImageTransformation];
    for( ROI *r in [view.curRoiList reverseObjectEnumerator])
    {
        [r setCurView: (DCMView*) view];
        [r drawROIWithScaleValue: gScale offsetX: kSide / 2. offsetY: kSide / 2. pixelSpacingX: r.pixelSpacingX pixelSpacingY: r.pixelSpacingY
             highlightIfSelected: highlight thickness: r.thickness prepareTextualData: YES];
        [view applyImageTransformation];
    }
    view.rectArray = [NSMutableArray array];
    BOOL drawing = NO;
    for( ROI *r in view.curRoiList) if( r.ROImode == ROI_drawing) drawing = YES;
    if( !drawing)
        for( ROI *r in view.curRoiList) { [r drawTextualData]; [view applyImageTransformation]; }
    NSMutableArray *rects = [NSMutableArray array];
    for( NSValue *v in view.rectArray) [rects addObject: R( v.rectValue)];
    [overlay commitInverted: NO scale: 2];
    unsigned char *rgb = calloc( kFrame * kFrame * 3, 1);
    [overlay compositeOntoRGB: rgb width: kFrame height: kFrame originX: 0 originY: 0];
    long lit = 0, minX = kFrame, minY = kFrame, maxX = -1, maxY = -1;
    for( long y = 0; y < kFrame; y++) for( long x = 0; x < kFrame; x++)
    {
        unsigned char *p = rgb + (y * kFrame + x) * 3;
        if( p[0] | p[1] | p[2]) { lit++; if( x < minX) minX = x; if( x > maxX) maxX = x; if( y < minY) minY = y; if( y > maxY) maxY = y; }
    }
    NSString *hash = [NSString stringWithFormat: @"%016llx", hashBytes( rgb, kFrame * kFrame * 3)];
    if( dumpFolder)
    {
        NSMutableData *ppm = [NSMutableData dataWithData: [[NSString stringWithFormat: @"P6\n%d %d\n255\n", kFrame, kFrame] dataUsingEncoding: NSASCIIStringEncoding]];
        [ppm appendBytes: rgb length: kFrame * kFrame * 3];
        NSString *file = [[label stringByReplacingOccurrencesOfString: @"/" withString: @"-"] stringByAppendingString: @".ppm"];
        [ppm writeToFile: [dumpFolder stringByAppendingPathComponent: file] atomically: NO];
    }
    free( rgb);
    return @{@"hash": hash, @"lit": @(lit), @"bounds": [NSString stringWithFormat: @"%ld,%ld,%ld,%ld", minX, minY, maxX, maxY],
             @"labelRects": rects, @"overlayItems": @(overlay.itemCount)};
}

/// The preferences in the argument domain (nothing is saved), and a window
/// with the view, its image and the notifications observed.
static ProbeWindow *setUp( NSDictionary *preferences)
{
    [[NSUserDefaults standardUserDefaults] setVolatileDomain: preferences forName: NSArgumentDomain];
    [ROI loadDefaultSettings];
    [ROI setFontHeight: 15];

    [NSApplication sharedApplication];
    ProbeWindow *window = [[ProbeWindow alloc] initWithContentRect: NSMakeRect( 0, 0, kFrame / 2, kFrame / 2) styleMask: NSWindowStyleMaskBorderless
                                                          backing: NSBackingStoreBuffered defer: YES];
    view = [[ProbeView alloc] initWithFrame: NSMakeRect( 0, 0, kFrame / 2, kFrame / 2)];
    window.contentView = view;
    view.curDCM = [ProbePix pixWithSpacing: 0.5 originZ: 7];
    view.currentTool = tWL;
    notes = [NSMutableArray array];
    [[NSNotificationCenter defaultCenter] addObserverForName: OsirixROIChangeNotification object: nil queue: nil usingBlock: ^(NSNotification *n) { observe( n); }];
    [[NSNotificationCenter defaultCenter] addObserverForName: OsirixRemoveROINotification object: nil queue: nil usingBlock: ^(NSNotification *n) { observe( n); }];
    return window;
}

/// A ROI of `type`, spaced and placed as the view's image is.
static ROI *newROI( ToolMode type)
{
    return [[[ROI alloc] initWithType: type : 0.5 : 0.625 : NSMakePoint( -30.5, 12.25)] autorelease];
}

/// The ROI in the view's list alone, on its image.
static void showAlone( ROI *roi)
{
    [roi setCurView: (DCMView*) view];
    roi.pix = view.curDCM;
    view.curRoiList = [NSMutableArray arrayWithObject: roi];
    [notes removeAllObjects];
}
'''.replace('\nPIX_IVARS\n', PIX_IVARS)


def configuration():
    return os.environ.get('HOROS_TEST_CONFIGURATION', 'Debug')


def objc_command(config=None):
    """The clang command xcodebuild logged for an Objective-C file of the app.

    Every Objective-C file of the target shares its options (a response file
    and the prefix header); -c and -o are the caller's.
    """
    config = config or configuration()
    errors = []
    for source in COMMAND_SOURCES:
        if not (ROOT / source).is_file() and not (ROOT / 'build/logs/compile-commands' / config /
                                                  (source.replace('/', '__') + '.txt')).is_file():
            continue
        try:
            return object_probe.compile_command(source, configuration=config)
        except LookupError as error:
            errors.append(str(error))
    raise LookupError('; '.join(errors) or f'no compile command logged for an Objective-C file; build {config} first')


def objects_dir(config=None):
    config = config or configuration()
    found = [ROOT / layout.format(configuration=config) for layout in object_probe.INTERMEDIATES]
    found = [path for path in found if path.is_dir()]
    if not found:
        raise LookupError(f'no {config} objects; build {config} first')
    return max(found, key=lambda path: path.stat().st_mtime)


def generated_headers(config=None):
    """The generated Horos-Swift.h files of the build, as clang may find them."""
    config = config or configuration()
    folder = objects_dir(config)
    return [path for path in (folder / 'Horos-Swift.h', folder.parent.parent / 'DerivedSources' / 'Horos-Swift.h')
            if path.is_file()]


def module_object(config=None):
    config = config or configuration()
    for products in (ROOT / 'build/Build/Products' / config, ROOT / 'build/Products' / config):
        if (products / f'{MODULE}.o').is_file():
            return products / f'{MODULE}.o'
    return None


def git_files(revision, prefix):
    return subprocess.run(['git', '-C', str(ROOT), 'ls-tree', '-r', '--name-only', revision, '--', prefix],
                          capture_output=True, text=True).stdout.split()


def has_objc_roi(revision):
    if revision == WORKTREE:
        return (ROOT / ROI_SOURCE).is_file()
    return ROI_SOURCE in git_files(revision, ROI_SOURCE)


def swift_roi_files():
    """The app's Swift files that define the ROI class or extend it."""
    names = []
    for path in sorted((ROOT / 'Horos/Sources').glob('*.swift')):
        text = path.read_text(encoding='utf-8', errors='replace')
        if re.search(r'@objc\((ROI|HorosVolumeLengthROI)\)|^extension ROI\b', text, re.M):
            names.append(path.stem)
    return names


def swift_dcmpix_files():
    """The app's Swift of DCMPix, linked for this checkout: DCMPix.swift, the
    class itself once it is Swift, its DCMPix+<area>.swift extensions and
    DCMPixSettings.swift."""
    return [path.stem for path in sorted((ROOT / 'Horos/Sources').glob('DCMPix*.swift'))
            if re.fullmatch(r'DCMPix(\+\w+|Settings)?', path.stem)]


# The Objective-C of the app that DCMPix's Swift calls: the accessors of the
# Objective-C class's instance variables while it had them, and what the Swift
# class keeps in Objective-C (its exported names, the 12-bit fill, the slab's
# rendering). The parser's attribute source is the IsiXDICOMDataset module's.
DCMPIX_OBJC = ('Horos/Sources/DCMPix+SwiftIvars.m', 'Horos/Sources/DCMPix+CAPI.m')


# The Swift classes a probe stands in for: the image view a ROI is drawn in,
# the viewer that owns it, the database browser, the database, the import's
# file reader (DicomFile, whose format dispatch asks the plugin manager), and
# the report and image writers (SRAnnotation, DICOMExport), which probes
# record calls to. Their objects, which reach most of the application, are not
# linked; a reference to the class answers its empty stub (see stubs()), or the
# probe's own. Each is an Objective-C class of the same name: an @objc Swift
# class, or, for DicomDatabase, DicomFile, SRAnnotation and DICOMExport, the
# class of their header that Swift implements (@objc @implementation), which
# Swift names by the metadata accessor of an imported class.
# ITKSegmentation3D: its Swift contour tracing calls the VTK adapter, which the
# probes do not link; they stand in for its +extractContour:width:height:.
# N2Debug: the probes define the logging functions they record, as they did
# when N2Debug was Objective-C and never part of the Swift closure.
BOUNDARY = ('DCMView', 'ViewerController', 'BrowserController', 'DicomDatabase', 'DicomFile', 'SRAnnotation',
            'DICOMExport', 'ITKSegmentation3D', 'N2Debug')


def is_boundary(stem):
    """An object of a class the probes stand in for: Name.o, its Name+Part.o extensions, NameSettings.o."""
    return any(stem in (name, name + 'Settings') or stem.startswith(name + '+') for name in BOUNDARY)


def swift_closure(folder, names):
    """`names` and every Swift object of the app they need, by the symbols they
    define, without crossing into the BOUNDARY classes' objects."""
    swift = {p.stem for p in folder.glob('*.swiftdeps')} | set(names)
    swift = {stem for stem in swift if stem in names or not is_boundary(stem)}
    index = {}
    for obj in folder.glob('*.o'):
        if obj.stem not in swift:
            continue
        listing = subprocess.run(['nm', '-g', '--defined-only', '-j', str(obj)], capture_output=True, text=True).stdout
        for symbol in listing.split():
            index.setdefault(symbol, obj.stem)
    todo, seen = list(names), set(names)
    while todo:
        name = todo.pop()
        listing = subprocess.run(['nm', '-u', '-j', str(folder / f'{name}.o')], capture_output=True, text=True).stdout
        for symbol in listing.split():
            owner = index.get(symbol)
            if owner and owner not in seen:
                seen.add(owner)
                todo.append(owner)
    return [folder / f'{name}.o' for name in sorted(seen)]


def project_class_names():
    """Objective-C class names the project's own sources define."""
    names = set()
    # The parser's classes too: DCMPix.m adds a category to DCMObject, which the
    # runtime attaches to the class when the probe loads.
    for path in [*(ROOT / 'Horos/Sources').iterdir(), *(ROOT / 'Horos/Sources/Adapters/DCMTK').iterdir()]:
        if path.suffix in ('.h', '.m', '.mm', '.swift'):
            text = path.read_bytes().decode('latin1')
            names.update(re.findall(r'@interface\s+(\w+)\s*:', text))
            names.update(re.findall(r'@objc\((\w+)\)', text))
            names.update(re.findall(r'\bclass\s+(\w+)\s*:\s*NS\w+', text))
    return names


def defined_classes(objects):
    names = set()
    for obj in objects:
        listing = subprocess.run(['nm', '-g', '--defined-only', '-j', str(obj)], capture_output=True, text=True).stdout
        names.update(re.findall(r'_OBJC_CLASS_\$_(\w+)', listing))
    return names


def stubs(objects, defined, former=()):
    """Empty classes for the project classes the objects name and none of them
    defines: any message to them answers zero (nil, NO, 0, NSZeroRect).
    `former` names more project classes: those of a revision's headers that
    this checkout no longer declares (see former_headers())."""
    project = project_class_names() | set(former)
    names = {n for obj in objects for n in object_probe.undefined_project_classes(obj)} & project - set(defined)
    # A BOUNDARY class the Swift objects name by its metadata accessor: the
    # accessor answers the Objective-C class of that name, the stub or the
    # probe's own stand-in, as the class object it would answer.
    accessors = {}
    provided = set()
    for obj in objects:
        provided.update(subprocess.run(['nm', '-g', '--defined-only', '-j', str(obj)], capture_output=True, text=True).stdout.split())
    imported = {}
    for obj in objects:
        listing = subprocess.run(['nm', '-u', '-j', str(obj)], capture_output=True, text=True).stdout
        for name in BOUNDARY:
            symbol = '_$s5Horos%d%sCMa' % (len(name), name)
            if symbol in listing.split() and symbol not in provided:
                accessors[name] = symbol
                if name not in defined:
                    names.add(name)
            # An Objective-C class Swift imports: its accessor answers the
            # metadata that wraps the class.
            symbol = '_$sSo%d%sCMa' % (len(name), name)
            if symbol in listing.split() and symbol not in provided:
                imported[name] = symbol
                if name not in defined:
                    names.add(name)
    names = sorted(names)
    accessor_source = ''.join(
        'typedef struct { Class metadata; long state; } ProbeMetadataResponse%s;\n'
        'ProbeMetadataResponse%s ProbeMetadataAccessor%s(long request) __asm__("%s");\n'
        'ProbeMetadataResponse%s ProbeMetadataAccessor%s(long request) { return (ProbeMetadataResponse%s){ objc_getClass("%s"), 0 }; }\n'
        % (n, n, n, s, n, n, n, n) for n, s in sorted(accessors.items()))
    if imported:
        accessor_source += 'extern const void *swift_getObjCClassMetadata(const void *);\n'
    accessor_source += ''.join(
        'typedef struct { const void *metadata; long state; } ProbeImportedMetadataResponse%s;\n'
        'ProbeImportedMetadataResponse%s ProbeImportedMetadataAccessor%s(long request) __asm__("%s");\n'
        'ProbeImportedMetadataResponse%s ProbeImportedMetadataAccessor%s(long request) '
        '{ return (ProbeImportedMetadataResponse%s){ swift_getObjCClassMetadata((const void *)objc_getClass("%s")), 0 }; }\n'
        % (n, n, n, s, n, n, n, n) for n, s in sorted(imported.items()))
    methods = {'ITKSegmentation3D': '+ (NSMutableArray*)extractContour:(unsigned char*)b width:(long)w height:(long)h { return [NSMutableArray array]; }'}
    return ('#import <Cocoa/Cocoa.h>\n#import <objc/runtime.h>\n'
            'NSString * const OsirixROIChangeNotification = @"OsirixROIChangeNotification";\n'
            'NSString * const OsirixRemoveROINotification = @"OsirixRemoveROINotification";\n'
            '// Zero in every return register, integer and floating point alike.\n'
            '__attribute__((naked)) static void StubZero(void) {\n'
            '    __asm__("mov x0, #0\\n mov x1, #0\\n movi d0, #0\\n movi d1, #0\\n movi d2, #0\\n movi d3, #0\\n ret");\n}\n'
            '@interface ProbeStub : NSObject @end\n@implementation ProbeStub\n'
            '+ (BOOL)resolveClassMethod:(SEL)s { class_addMethod(object_getClass(self), s, (IMP) StubZero, "v@:"); return YES; }\n'
            '+ (BOOL)resolveInstanceMethod:(SEL)s { class_addMethod(self, s, (IMP) StubZero, "v@:"); return YES; }\n@end\n' +
            ''.join('@interface %s : ProbeStub @end\n@implementation %s\n%s\n@end\n' % (n, n, methods.get(n, ''))
                    for n in names) + accessor_source)


def swift_roi_link(folder, config=None, own=(), defined=()):
    """What links a driver with the build's Swift ROI: the objects of the ROI
    and of the app Swift they need, except the files `own` the driver compiles
    from source itself (as module Horos, so that their symbols are the
    app's); the flags of the internal modules; and the Objective-C of stubs
    for the other project classes they name, `defined` aside."""
    config = config or configuration()
    objects_folder = objects_dir(config)
    objects = [o for o in swift_closure(objects_folder, swift_roi_files()) if o.stem not in own]
    module = module_object(config)
    folder = Path(folder)
    flags = [str(module)] if module else isix_modules.module_flags(MODULE, folder / MODULE)
    names = defined_classes(objects + ([module] if module else [])) | isix_modules.objc_class_names(MODULE) | set(defined)
    for name in own:
        source = ROOT / 'Horos/Sources' / f'{name}.swift'
        if source.is_file():
            text = source.read_text(encoding='utf-8', errors='replace')
            names |= set(re.findall(r'@objc\((\w+)\)', text)) | set(re.findall(r'\bclass\s+(\w+)\s*:\s*NS\w+', text))
    referenced = {n for obj in objects for n in object_probe.undefined_project_classes(obj)}
    for name in isix_modules.module_names():
        classes = isix_modules.objc_class_names(name)
        if name != MODULE and classes & referenced:
            flags += isix_modules.module_flags(name, folder / name)
            names |= classes
    return objects, flags, stubs(objects, names)


def run(argv, **kwargs):
    done = subprocess.run(argv, capture_output=True, **kwargs)
    if done.returncode:
        error = done.stderr.decode('utf-8', 'replace') if isinstance(done.stderr, bytes) else done.stderr
        raise RuntimeError(f'{Path(argv[0]).name} failed ({done.returncode}): ' + '\n'.join(
            line for line in error.splitlines() if 'error' in line or 'Error' in line)[-3000:])
    return done


def revision_overlay(revision, folder, config, former=()):
    """clang flags that compile a revision's sources against its own headers;
    `former` names the classes of the revision's headers written beside the
    sources (see former_headers())."""
    overlay = folder / 'overlay'
    overlay.mkdir(parents=True, exist_ok=True)
    entries, classes = [], set(former)
    for header in OVERLAID_HEADERS:
        if header not in git_files(revision, header):
            continue
        copy = object_probe.revision_source(header, revision, overlay / Path(header).name)
        text = copy.read_bytes().decode('latin1')
        # A header that imports the generated interface declares its classes
        # itself only for a target without Swift (the Decompress helper):
        # those stay in the generated header.
        swift_part = re.search(r'^#elif __has_include\("Horos-Swift\.h"\)\n#import "Horos-Swift\.h"\n#else\n(.*?)^#endif',
                               text, re.M | re.S)
        if swift_part:
            text = text[:swift_part.start(1)] + text[swift_part.end(1):]
        classes.update(re.findall(r'^@interface\s+(\w+)\s*:', text, re.M))
        entries.append((ROOT / header, copy))
    # The revision's categories of DCMPix implemented in Swift: their headers
    # leave the declarations to the generated interface inside the bridging
    # header, and that interface's DCMPix parts are taken out below; the
    # revision's sources see the categories' own declarations instead.
    for header in git_files(revision, 'Horos/Sources'):
        if re.fullmatch(r'Horos/Sources/DCMPix\+\w+\.h', header):
            copy = object_probe.revision_source(header, revision, overlay / Path(header).name)
            text = copy.read_bytes().decode('latin1').replace('#ifndef HOROS_BRIDGING_HEADER', '#if 1')
            copy.write_bytes(text.encode('latin1'))
            entries.append((ROOT / header, copy))
    for generated in generated_headers(config):
        text = generated.read_text(encoding='utf-8', errors='replace')
        # The generated declarations of the classes the revision's headers declare.
        for name in classes:
            text = re.sub(r'(?:^SWIFT_CLASS(?:_NAMED)?\("[^"]*"\)\n)?^@interface %s\b.*?^@end\n' % re.escape(name), '',
                          text, flags=re.M | re.S)
        copy = overlay / f'Horos-Swift-{len(entries)}.h'
        copy.write_text(text, encoding='utf-8')
        entries.append((generated, copy))
    if not entries:
        return []
    roots = ''.join('    {"type": "file", "name": "%s", "external-contents": "%s"},\n' % (str(real), str(copy))
                    for real, copy in entries)
    yaml = overlay / 'overlay.yaml'
    yaml.write_text('{"version": 0, "case-sensitive": "false", "roots": [\n' + roots.rstrip(',\n') + '\n]}\n')
    return ['-ivfsoverlay', str(yaml)]


def former_headers(revision, sources, folder):
    """The app headers that a revision's `sources` import and that no longer
    declare here the classes they declared then: the header is gone (its class
    moved to an internal module under another name), or a class of it became a
    protocol. A class that became Swift keeps its header, which declares it
    through the generated interface, and is not one of these. The revision's copies are
    written beside the sources, where a quoted import finds them first, with
    the headers those import in turn. Answers the Objective-C classes they
    declare: project classes of the revision, stubbed as the others."""
    present = set(git_files(revision, 'Horos/Sources'))
    todo, seen, classes = list(sources), set(), set()
    while todo:
        text = Path(todo.pop()).read_bytes().decode('latin1')
        for name in re.findall(r'^\s*#\s*(?:import|include)\s+"([^"/]+\.h)"', text, re.M):
            header = f'Horos/Sources/{name}'
            if name in seen or header not in present:
                continue
            seen.add(name)
            then = subprocess.run(['git', '-C', str(ROOT), 'show', f'{revision}:{header}'], capture_output=True,
                                  check=True).stdout.decode('latin1')
            declared = set(re.findall(r'^@interface\s+(\w+)\s*:', then, re.M))
            # A header that moved to a subfolder (an adapter) still declares its classes.
            current = ROOT / header
            if not current.is_file():
                current = next((ROOT / 'Horos/Sources').rglob(name), current)
            if current.is_file():
                protocols = set(re.findall(r'^@protocol\s+(\w+)\s*<', current.read_bytes().decode('latin1'), re.M))
                if not declared & protocols:
                    continue
            copy = object_probe.revision_source(header, revision, folder / name)
            classes |= declared
            todo.append(copy)
    return classes


def build(revision, folder, probe_source, *, config=None, pix_flags=(), extra_swift=(), app_swift=(), log=None,
          dcmpix_swift=None):
    """The probe linked with the ROI and DCMPix of `revision` (WORKTREE for this checkout).

    `pix_flags` are added to DCMPix.m's command; `extra_swift` are Swift sources
    compiled into the harness, for a revision whose code calls app Swift that
    this checkout's build no longer has; `app_swift` names more Swift files of
    the app whose built objects the probe needs (classes DCMPix.m names, which
    would otherwise be stubs). For this checkout, the Swift extensions of DCMPix
    and the Objective-C accessors they read DCMPix's instance variables with are
    linked as well; `dcmpix_swift` names the extensions to link instead, for
    any revision: a revision's DCMPix.m that already calls some of them (the
    parts that left it before) gets this checkout's, with the accessors.
    """
    config = config or configuration()
    optimization = ['-O'] if config == 'Release' else []
    # Absolute: the module is compiled from inside its own folder.
    folder = Path(folder).resolve()
    folder.mkdir(parents=True)
    command = objc_command(config)
    objects_folder = objects_dir(config)

    sources = []
    dcmpix = list(dcmpix_swift) if dcmpix_swift is not None else swift_dcmpix_files() if revision == WORKTREE else []
    ivars = tuple(source for source in DCMPIX_OBJC if (ROOT / source).is_file()) if dcmpix else ()
    for source in ((ROI_SOURCE,) if has_objc_roi(revision) else ()) + (PIX_SOURCE,) + ivars:
        target = folder / Path(source).name
        if revision == WORKTREE or source in ivars:
            if not (ROOT / source).is_file():
                continue
            shutil.copyfile(ROOT / source, target)
        else:
            if source not in git_files(revision, source):
                continue
            object_probe.revision_source(source, revision, target)
        sources.append(target)
    former = set() if revision == WORKTREE else former_headers(revision, sources, folder)
    overlay = [] if revision == WORKTREE else revision_overlay(revision, folder, config, former)
    if revision != WORKTREE:
        # A revision of the DCM.framework era imports <DCM/...>: the former
        # names answer with the dataset model (horos_reader.former_names).
        overlay += ['-I' + str(horos_reader.former_names(folder / 'dcm-headers'))]
    (folder / 'probe.m').write_text(probe_source)
    objects = []
    for source in sources + [folder / 'probe.m']:
        obj = folder / (source.stem + '.o')
        flags = list(pix_flags) if source.name == Path(PIX_SOURCE).name else []
        run(command + overlay + flags + ['-w', '-c', str(source), '-o', str(obj)])
        objects.append(obj)

    app_swift = list(SUPPORT) + ([] if has_objc_roi(revision) else swift_roi_files()) + list(app_swift) + dcmpix
    swift_objects = swift_closure(objects_folder, [name for name in app_swift if (objects_folder / f'{name}.o').is_file()])
    missing = [name for name in app_swift if not (objects_folder / f'{name}.o').is_file()]
    if missing:
        raise LookupError(f'no {config} objects for {", ".join(missing)}; build {config} first')

    link = []
    module_sources = git_files('HEAD' if revision == WORKTREE else revision, f'Modules/{MODULE}/Sources')
    if revision == WORKTREE and module_object(config):
        link.append(str(module_object(config)))
    elif module_sources:
        source_folder = folder / 'module-sources'
        for path in module_sources:
            if revision == WORKTREE:
                source_folder.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / path, source_folder / Path(path).name)
            else:
                object_probe.revision_source(path, revision, source_folder / Path(path).name)
        module_folder = folder / 'module'
        module_folder.mkdir()
        run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-module-name', MODULE, *optimization,
             '-emit-library', '-static', '-o', str(module_folder / f'lib{MODULE}.a'),
             *map(str, sorted(source_folder.glob('*.swift')))], cwd=module_folder)
        link += ['-L', str(module_folder), f'-l{MODULE}']

    linked = objects + swift_objects + ([Path(link[0])] if link and not link[0].startswith('-') else [])
    defined = defined_classes(linked) | set(re.findall(r'@objc\((\w+)\)', ''.join(
        Path(p).read_text() for p in extra_swift))) | {n for n in re.findall(r'@objc\((IsiXROI\w+)\)', ''.join(
        p.read_text() for p in (ROOT / 'Modules' / MODULE / 'Sources').glob('*.swift')))}
    # The other internal modules the objects refer to (DCMPix.m reads its
    # attributes through IsiXImaging), built from this checkout.
    undefined = ''.join(subprocess.run(['nm', '-u', str(obj)], capture_output=True, text=True, check=True).stdout
                        for obj in objects + swift_objects)
    referenced = {n for obj in objects + swift_objects for n in object_probe.undefined_project_classes(obj)} | set(
        re.findall(r'_OBJC_CLASS_\$_(\w+)', undefined))
    for name in isix_modules.module_names():
        classes = isix_modules.objc_class_names(name)
        # A module the Swift calls by its Swift symbols, $s<length><name>...
        called = f'$s{len(name)}{name}' in undefined
        if name != MODULE and (classes & referenced or called):
            # One folder for all of them: a module built with its dependencies
            # beside it, and those again in folders of their own, would give
            # the compiler two module maps for one module.
            link += isix_modules.module_flags(name, folder / 'other-modules', optimization)
            defined |= classes
    (folder / 'stubs.m').write_text(stubs(objects + swift_objects, defined, former))
    run(['xcrun', 'clang', '-fno-objc-arc', '-w', '-c', str(folder / 'stubs.m'), '-o', str(folder / 'stubs.o')])

    placeholders = set()
    for _ in range(300):
        assembly = ''.join('.globl %s\n%s: .quad 0\n' % (s, s) for s in sorted(placeholders))
        (folder / 'placeholders.s').write_text('.data\n' + assembly)
        run(['xcrun', 'clang', '-c', str(folder / 'placeholders.s'), '-o', str(folder / 'placeholders.o')])
        run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-module-name', 'Probe', '-suppress-warnings',
             *optimization, *map(str, extra_swift), *map(str, objects + swift_objects), str(folder / 'stubs.o'), str(folder / 'placeholders.o'),
             *link, '-Xlinker', '-undefined', '-Xlinker', 'dynamic_lookup', '-lc++',
             '-framework', 'Cocoa', '-framework', 'Accelerate', '-framework', 'AVFoundation', '-framework', 'CoreMedia',
             '-framework', 'QuartzCore', '-o', str(folder / 'harness')])
        probe = subprocess.run([str(folder / 'harness'), '--probe-link'], capture_output=True, text=True, timeout=60)
        missing = re.search(r"symbol not found in flat namespace '([^']+)'", probe.stderr)
        if not missing:
            if log is not None:
                log.append(f'{revision}: {len(objects)} compiled, {len(swift_objects)} app Swift objects, '
                           f'{len(placeholders)} placeholders')
            return folder / 'harness'
        if missing.group(1) in placeholders:
            raise RuntimeError('cannot satisfy %s' % missing.group(1))
        placeholders.add(missing.group(1))
    raise RuntimeError('too many unresolved symbols for %s' % revision)


def run_probe(main_source, *, config=None, args=(), timeout=300):
    """PRELUDE and `main_source` linked with this checkout's ROI, run with
    `args`: the completed process. Without a build, the test is skipped.

    The probe's main() answers 0 at once to `--probe-link`, which build() runs
    to find the symbols it lacks."""
    try:
        objc_command(config)
        objects_dir(config)
    except LookupError as error:
        print(f'skipped: {error}', file=sys.stderr)
        sys.exit(SKIPPED)
    with tempfile.TemporaryDirectory(prefix='horos-roi-probe-') as folder:
        harness = build(WORKTREE, Path(folder) / 'probe', PRELUDE + main_source, config=config)
        return subprocess.run([str(harness), *args], capture_output=True, text=True, timeout=timeout)


def objc_class():
    """Whether DCMPix is still DCMPix.m. Once it is Swift, no revision of DCMPix.m
    links with this checkout's Swift, and a test that compared this checkout with
    a revision of the Objective-C compares it with golden() instead."""
    return (ROOT / PIX_SOURCE).is_file()


# The records were made on a display of backing scale 2, the scale AppKit
# rasterizes an NSImage without a context at (cgImage(forProposedRect:context:
# nil hints:nil)): a PDF page or an image drawn with -lockFocus has twice its
# point size in pixels there, and only its point size on a display of scale 1.
# A probe whose records hold such pixels includes RECORDED_BACKING_SCALE, which
# makes every screen answer that scale before AppKit first asks, so that its
# images are those of the records, pixel for pixel, whatever this Mac's display.
RECORDED_BACKING_SCALE = r'''
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
static CGFloat ProbeRecordedBackingScale( id self, SEL _cmd) { return 2.0; }
__attribute__((constructor)) static void ProbePinBackingScale( void)
{
    method_setImplementation( class_getInstanceMethod( [NSScreen class], @selector( backingScaleFactor)), (IMP) ProbeRecordedBackingScale);
}
'''


def golden(name, config, records=None):
    """What a probe answered against the last Objective-C DCMPix, in `config`,
    kept in tests/fixtures/<name>-records.json. With `records`, writes them;
    only the Objective-C class writes them (HOROS_RECORD_GOLDEN=1 on a
    checkout of it, with this test). LookupError when there are none."""
    import json
    path = ROOT / 'tests/fixtures' / f'{name}-records.json'
    stored = json.loads(path.read_text()) if path.is_file() else {}
    if records is None:
        if config not in stored:
            raise LookupError(f'{path.relative_to(ROOT)} has no {config} records of the Objective-C class')
        return stored[config]
    if not objc_class():
        raise RuntimeError('the records are written from the Objective-C class only')
    stored[config] = records
    path.write_text(json.dumps(stored, indent=1, sort_keys=True) + '\n')


def recording_golden():
    return os.environ.get('HOROS_RECORD_GOLDEN') == '1'


def diff(a, b, path=''):
    """The first places where two JSON values differ."""
    if isinstance(a, dict) and isinstance(b, dict):
        out = []
        for key in sorted(set(a) | set(b)):
            out += diff(a.get(key, '<missing>'), b.get(key, '<missing>'), f'{path}/{key}')
        return out
    if isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        out = []
        for i, (x, y) in enumerate(zip(a, b)):
            out += diff(x, y, f'{path}[{i}]')
        return out
    return [] if a == b else [f'{path}: {str(a)[:160]} != {str(b)[:160]}']
