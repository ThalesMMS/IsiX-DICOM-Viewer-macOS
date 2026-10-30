#!/usr/bin/env python3
"""The DCMView frame draws what it drew before its frame cycle, pixel for pixel.

Compiles -drawFrame: twice - as it was before the frame cycle (read from git) and as it
is now, with HorosPlanarFrameCycle and HorosPlanarFrameGraphics - each as a
method of the same Objective-C double of DCMView, over the real
HorosAnnotationOverlay, HorosROICanvas and HorosPlanarPerformanceTrace. The
double records every hook the frame calls (text, cross lines, markers,
subclass hooks, the picture) and the canvas keeps every graphic. For each case
- viewer highlight, CLUT bars of the image and of a fused series, key-view
border, overflow marks, mosaic borders, flips, rotation and pan, patient
crosshair, reference lines with and without the 3D point, the ruler in both
scales and on a capture rectangle, the notice, the picture drawn or cleared,
inverted colours - the two frames must leave the same canvas bytes and the same
record, in the same order.

One drawing changed on purpose since: with several 2D windows, the red border
of the frontmost key view became a frame in each window's own colour, thick
on the frontmost key view and thin on the others. In those two cases the
calls are still the same; the canvas must differ from the former one, and
the frontmost key view's frame from the other windows'.

The graphics now ask HorosAnnotationLevel (compiled in) which elements the
level shows; None, Graphic and Full draw as before, and a Custom level that
shows every element draws what the former frame drew for it.

Since the drawing moved to Swift (DCMView+Drawing.swift), the frame of now is
that Swift: -drawFrame: and the methods it draws with (CLUT bars, reference
lines, ROI labels), compiled with DrawingGeometry as an extension of the same
double, whose ivars it reaches through the horos_ accessors of the app.

`--before <revision>` names the revision that holds the former -drawFrame:
(default: the parent of the commit that moved it).
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--before', default=None)
args = parser.parse_args()


def git(*command):
    return subprocess.check_output(['git', '-C', str(root), *command], stderr=subprocess.DEVNULL)


def frame_methods(text):
    """-drawFrame: and the methods that follow it, up to -setFrame: (or
    -reshape, which followed it, since -setFrame: is Swift)."""
    start = text.index('- (void) drawFrame:(NSRect)aRect\n{')
    ends = [text.find(marker, start) for marker in ('\n- (void) setFrame:(NSRect)frameRect', '\n- (void) reshape')]
    return text[start:min(e for e in ends if e >= 0)]


before = args.before
if before is None:
    # The commit that brought the frame cycle in, not the later one that took
    # -drawFrame: out of DCMView.m with it.
    moved = git('log', '--reverse', '--format=%H', '-S', 'HorosPlanarFrameCycle beginInView', '--',
                'Horos/Sources/DCMView.m').decode().split('\n')[0].strip()
    if not moved:
        print('skipped: the frame cycle is not in the history', file=sys.stderr)
        sys.exit(2)
    before = moved + '^'
old = frame_methods(git('show', before + ':Horos/Sources/DCMView.m').decode('latin1'))
drawing_swift = root / 'Horos/Sources/DCMView+Drawing.swift'


def swift_frame(text):
    """The file-scope helpers of DCMView+Drawing.swift and its frame: the
    reference lines' hook, the CLUT bars, the ROI labels and -drawFrame:."""
    helpers = text[text.index('// The OpenGL enumerants'):text.index('extension DCMView {')]
    frame = text[text.index('    /// -drawCrossLines:perpendicular: on a float[2][3] line'):text.index('    // MARK: - Fonts')]
    return 'import Cocoa\nimport QuartzCore\n\n' + helpers + 'extension DCMView {\n' + frame + '}\n'


if drawing_swift.exists():
    new = None
    new_swift = swift_frame(drawing_swift.read_text())
else:
    new = frame_methods((root / 'Horos/Sources/DCMView.m').read_bytes().decode('latin1'))
    new_swift = None

HEADER = r'''
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
typedef enum {DCMViewTextAlignLeft, DCMViewTextAlignCenter, DCMViewTextAlignRight} DCMViewTextAlign;
typedef enum {DCMViewMainFont, DCMViewLabelFont} DCMViewFontKind;
enum { annotNone = 0, annotGraphics, annotBase, annotFull };
enum { barHide = 0, barOrigin, barFused, barBoth };
enum { ROI_sleep = 0, ROI_drawing = 1 };
@class HorosPlanarPerformanceTrace, HorosAnnotationBox, DCMView;

@interface WaitRendering : NSObject
- (instancetype)init:(NSString *)message;
- (void)start; - (void)end; - (void)close;
@end

@interface DCMPix : NSObject
@property BOOL displayInverted;
@property double pixelRatio, pixelSpacingX, pixelSpacingY;
@property long pwidth, pheight;
- (NSRect)usefulRectWithRotation:(float)r scale:(float)s xFlipped:(BOOL)x yFlipped:(BOOL)y;
+ (NSPoint)rotatePoint:(NSPoint)p aroundPoint:(NSPoint)c angle:(float)a;
@end

@interface ROI : NSObject
@property long ROImode NS_SWIFT_NAME(roImode);
@property(assign) DCMView *curView;
- (void)recompute;
- (void)drawTextualData;
- (void)drawROI:(float)scale :(float)offsetx :(float)offsety :(float)spacingX :(float)spacingY NS_SWIFT_NAME(draw(_:_:_:_:_:));
@end

@interface ViewerController : NSObject
+ (long)numberOf2DViewer;
+ (ViewerController *)frontMostDisplayed2DViewerForScreen:(NSScreen *)screen;
- (float)highLighted;
- (BOOL)FullScreenON;
- (NSRecursiveLock *)roiLock;
@end

@interface Controller : ViewerController
@property float highLighted;
@property BOOL FullScreenON;
@property(retain) NSRecursiveLock *roiLock;
@end

NS_SWIFT_NAME(ViewerWindowColors)
@interface HorosViewerWindowColors : NSObject
+ (NSColor *)colorForViewer:(id)viewer NS_SWIFT_NAME(color(for:));
@end

NS_SWIFT_NAME(SeriesListIdentification)
@interface HorosSeriesListIdentification : NSObject
+ (BOOL)showsColorsIn:(NSUserDefaults *)defaults;
@end

@interface OSIEnvironment : NSObject
+ (instancetype)sharedEnvironment NS_SWIFT_NAME(shared());
- (void)drawDCMView:(DCMView *)dcmView NS_SWIFT_NAME(drawDCMView(_:));
@end

@interface DCMView : NSView {
@public
    BOOL firstTimeDisplay, noScale, whiteBackground, isKeyView, syncOnLocationImpossible, xFlipped, yFlipped;
    BOOL suppress_labels, lensActive, showDescriptionInLarge, recordAnnotationRects, is2D, planar;
    NSRecursiveLock *drawLock;
    NSString *stringID;
    NSArray *dcmPixList;
    NSInteger curImage;
    int annotationType;
    float scaleValue, rotation, curWW, curWL, repulsorRadius, sliceFromToThickness;
    NSPoint origin, ROISelectorStartPoint, ROISelectorEndPoint;
    NSRect drawingFrameRect, screenCaptureRect;
    unsigned char redTable[256], greenTable[256], blueTable[256];
    long _imageColumns, _imageRows;
    float sliceFromTo[2][3], sliceFromToS[2][3], sliceFromToE[2][3], sliceFromTo2[2][3], sliceVector[3], slicePoint3D[3];
    NSMutableArray *curRoiList, *rectArray;
    ROI *lengthPendingMarker;
    HorosAnnotationBox *showDescriptionInLargeText;
    DCMView *blendingView;
    DCMPix *curDCM;
    Controller *controller;
    NSString *notice, *fallback;
    BOOL crosshair; float cross[3];
    unsigned char *fusedRed;
    float fusedWL, fusedWW;
    CAMetalLayer *picture;
@public
    NSMutableArray *record;
}
@property float scaleValue;
@property(readonly) DCMPix *curDCM;
@property(readonly) DCMView *blendingView;
@property(readonly) BOOL whiteBackground, showDescriptionInLarge;
@property(readonly) NSString *stringID;
+ (void)computePETBlendingCLUT;
- (id)windowController;
- (BOOL)is2DViewer;
- (void)updatePresentationStateFromSeries;
- (void)setOriginX:(float)x Y:(float)y;
@property(readonly) NSPoint origin;
- (CAMetalLayer *)horosPictureLayer;
- (BOOL)horosDrawPlanarInLayer:(CAMetalLayer *)layer inverted:(BOOL)inverted;
- (void)horosClearLayer:(CAMetalLayer *)layer white:(BOOL)white inverted:(BOOL)inverted NS_SWIFT_NAME(horosClear(_:white:inverted:));
- (HorosPlanarPerformanceTrace *)horosPlanarPerformanceTrace;
- (double)horosPlanarLastCommandMilliseconds;
- (NSString *)horosEngineNotice;
- (NSString *)horosPlanarFallbackReason;
- (void)DrawNSStringGL:(NSString *)str :(DCMViewFontKind)fontL :(long)x :(long)y;
- (void)DrawNSStringGL:(NSString *)str :(DCMViewFontKind)fontL :(long)x :(long)y rightAlignment:(BOOL)right useStringTexture:(BOOL)stringTex;
- (void)DrawNSStringGL:(NSString *)str :(DCMViewFontKind)fontL :(long)x :(long)y align:(DCMViewTextAlign)align useStringTexture:(BOOL)stringTex;
- (void)getCLUT:(unsigned char **)r :(unsigned char **)g :(unsigned char **)b;
- (void)getWLWW:(float *)wl :(float *)ww;
- (void)draw2DPointMarker;
- (void)drawPendingLength;
- (void)subDrawRect:(NSRect)r;
- (void)drawRectAnyway:(NSRect)r;
- (BOOL)getPatientCrosshairSliceCoordinates:(float *)c;
- (void)drawCrossLines:(float[2][3])sft perpendicular:(BOOL)perpendicular;
- (void)drawTextualData:(NSRect)size :(long)annotations;
- (void)drawRepulsorToolArea;
- (void)drawROISelectorRegion;
- (void)drawMagnifyingLens;
- (void)horosDrawMeasurementMagnifier;
- (BOOL)_checkHasChanged:(BOOL)flag;
OBJC_FRAME@end

// What the Swift frame reaches: the app's accessors of the ivars and statics.
@interface DCMView (SwiftIvars)
@property int horos_annotationType;
@property BOOL horos_firstTimeDisplay, horos_noScale, horos_isKeyView, horos_syncOnLocationImpossible, horos_xFlipped, horos_yFlipped;
@property BOOL horos_suppress_labels, horos_recordAnnotationRects, horos_lensActive;
@property NSRect horos_drawingFrameRect, horos_screenCaptureRect;
@property(nonatomic, assign) NSMutableArray *horos_dcmPixList, *horos_curRoiList;
@property(nonatomic, retain) NSMutableArray *horos_rectArray;
@property NSInteger horos_curImage;
@property(readonly) DCMView *horos_blending;
@property float horos_rotation, horos_scaleValue, horos_curWW, horos_curWL;
@property NSPoint horos_origin, horos_ROISelectorStartPoint, horos_ROISelectorEndPoint;
@property NSInteger horos_imageColumns, horos_imageRows;
@property int horos_repulsorRadius;
@property(nonatomic, assign) ROI *horos_lengthPendingMarker;
@property(nonatomic, retain) HorosAnnotationBox *horos_showDescriptionInLargeText;
@property(readonly) unsigned char *horos_redTable, *horos_greenTable, *horos_blueTable;
@property(readonly) float *horos_sliceFromTo, *horos_sliceFromToS, *horos_sliceFromToE, *horos_sliceFromTo2, *horos_sliceVector, *horos_slicePoint3D;
@end

@interface DCMView (SwiftStatics)
@property(class, readonly) double horos_static_deg2rad;
@property(class) unsigned char *horos_static_PETredTable, *horos_static_PETgreenTable, *horos_static_PETblueTable;
@property(class, nonatomic, assign) NSRecursiveLock *horos_static_drawLock;
@property(class, readonly) BOOL horos_static_gInvertColors, horos_static_OVERFLOWLINES;
@end

extern int CLUTBARS, DISPLAYCROSSREFERENCELINES;
extern NSNotificationName const HorosDrawObjectsCanvasNotification;
void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *pf);
#import "HorosObjCException.h"
'''

STUB = r'''
#import "Stub.h"
#import "Horos-Swift.h"
#import "ROICanvasGL.h"
#define N2LogExceptionWithStackTrace(e) NSLog(@"%@", e)
#define OSIRIX_LIGHT 1
static double deg2rad = M_PI / 180.0;
static unsigned char *PETredTable = nil, *PETgreenTable = nil, *PETblueTable = nil;
BOOL gInvertColors = NO, OVERFLOWLINES = NO;
int CLUTBARS = 0, DISPLAYCROSSREFERENCELINES = YES;
long viewerCount = 1; id frontViewer = nil;
NSString * const HorosDrawObjectsCanvasNotification = @"HorosDrawObjectsCanvasNotification";

@implementation WaitRendering
- (instancetype)init:(NSString *)message { return [super init]; }
- (void)start {} - (void)end {} - (void)close {}
@end
@implementation DCMPix
- (NSRect)usefulRectWithRotation:(float)r scale:(float)s xFlipped:(BOOL)x yFlipped:(BOOL)y {
    return NSMakeRect(0, 0, self.pwidth * s, self.pheight * s * self.pixelRatio);
}
+ (NSPoint)rotatePoint:(NSPoint)p aroundPoint:(NSPoint)c angle:(float)a {
    return NSMakePoint(c.x + (p.x - c.x) * cos(a) - (p.y - c.y) * sin(a), c.y + (p.x - c.x) * sin(a) + (p.y - c.y) * cos(a));
}
@end
@implementation ROI
@synthesize curView;
- (void)recompute {} - (void)drawTextualData {}
- (void)drawROI:(float)scale :(float)offsetx :(float)offsety :(float)spacingX :(float)spacingY {}
@end
@implementation ViewerController
+ (long)numberOf2DViewer { return viewerCount; }
+ (ViewerController *)frontMostDisplayed2DViewerForScreen:(NSScreen *)screen { return frontViewer; }
- (float)highLighted { return 0; } - (BOOL)FullScreenON { return NO; } - (NSRecursiveLock *)roiLock { return nil; }
@end
@implementation Controller
@synthesize highLighted, FullScreenON, roiLock;
@end
@implementation OSIEnvironment
+ (instancetype)sharedEnvironment { return nil; }
- (void)drawDCMView:(DCMView *)dcmView {}
@end
void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *pf) { NSLog(@"%s %@", pf, e); }
@implementation HorosViewerWindowColors
+ (NSColor *)colorForViewer:(id)viewer { return [NSColor colorWithCalibratedRed:0.25 green:0.55 blue:1 alpha:1]; }
@end
@implementation HorosSeriesListIdentification
+ (BOOL)showsColorsIn:(NSUserDefaults *)defaults { return YES; }
@end

@implementation DCMView
- (float)scaleValue { return scaleValue; }
- (void)setScaleValue:(float)v { scaleValue = v; }
- (DCMPix *)curDCM { return curDCM; }
- (DCMView *)blendingView { return blendingView; }
- (id)windowController { return controller; }
- (BOOL)is2DViewer { return is2D; }
- (void)updatePresentationStateFromSeries { [record addObject:@"presentation"]; }
- (void)setOriginX:(float)x Y:(float)y { origin = NSMakePoint(x, y); }
- (NSPoint)origin { return origin; }
- (BOOL)whiteBackground { return whiteBackground; }
- (BOOL)showDescriptionInLarge { return showDescriptionInLarge; }
- (NSString *)stringID { return stringID; }
+ (void)computePETBlendingCLUT {}
- (CAMetalLayer *)horosPictureLayer { if (!picture) picture = [[CAMetalLayer layer] retain]; return picture; }
- (BOOL)horosDrawPlanarInLayer:(CAMetalLayer *)layer inverted:(BOOL)inverted {
    [record addObject:[NSString stringWithFormat:@"picture inverted=%d", inverted]]; return planar;
}
- (void)horosClearLayer:(CAMetalLayer *)layer white:(BOOL)white inverted:(BOOL)inverted {
    [record addObject:[NSString stringWithFormat:@"clear white=%d inverted=%d", white, inverted]];
}
- (HorosPlanarPerformanceTrace *)horosPlanarPerformanceTrace { return nil; }
- (double)horosPlanarLastCommandMilliseconds { return -1; }
- (NSString *)horosEngineNotice { return notice; }
- (NSString *)horosPlanarFallbackReason { return fallback ?: notice; }
- (void)DrawNSStringGL:(NSString *)str :(DCMViewFontKind)fontL :(long)x :(long)y {
    [record addObject:[NSString stringWithFormat:@"text %@ %d %ld %ld", str, fontL, x, y]];
}
- (void)DrawNSStringGL:(NSString *)str :(DCMViewFontKind)fontL :(long)x :(long)y rightAlignment:(BOOL)right useStringTexture:(BOOL)stringTex {
    [record addObject:[NSString stringWithFormat:@"text %@ %d %ld %ld right=%d tex=%d", str, fontL, x, y, right, stringTex]];
}
- (void)DrawNSStringGL:(NSString *)str :(DCMViewFontKind)fontL :(long)x :(long)y align:(DCMViewTextAlign)align useStringTexture:(BOOL)stringTex {
    [record addObject:[NSString stringWithFormat:@"text %@ %d %ld %ld align=%d tex=%d", str, fontL, x, y, align, stringTex]];
}
- (void)getCLUT:(unsigned char **)r :(unsigned char **)g :(unsigned char **)b { *r = fusedRed; *g = fusedRed ? fusedRed + 256 : nil; *b = fusedRed ? fusedRed + 512 : nil; }
- (void)getWLWW:(float *)wl :(float *)ww { *wl = fusedWL; *ww = fusedWW; }
- (void)draw2DPointMarker { [record addObject:@"point marker"]; }
- (void)drawPendingLength { [record addObject:@"pending length"]; }
- (void)subDrawRect:(NSRect)r { [record addObject:@"subDrawRect"]; }
- (void)drawRectAnyway:(NSRect)r { [record addObject:@"drawRectAnyway"]; }
- (BOOL)getPatientCrosshairSliceCoordinates:(float *)c { if (crosshair) { c[0] = cross[0]; c[1] = cross[1]; c[2] = cross[2]; } return crosshair; }
- (void)drawCrossLines:(float[2][3])sft perpendicular:(BOOL)perpendicular {
    [record addObject:[NSString stringWithFormat:@"cross %g %g %g %g perpendicular=%d", sft[0][0], sft[0][1], sft[1][0], sft[1][1], perpendicular]];
}
- (void)drawTextualData:(NSRect)size :(long)annotations { [record addObject:[NSString stringWithFormat:@"textual %ld labels=%d", annotations, recordAnnotationRects]]; }
- (void)drawRepulsorToolArea { [record addObject:@"repulsor"]; }
- (void)drawROISelectorRegion { [record addObject:@"selector"]; }
- (void)drawMagnifyingLens { [record addObject:@"lens"]; }
- (void)horosDrawMeasurementMagnifier {}
- (BOOL)_checkHasChanged:(BOOL)flag { [record addObject:@"checked"]; return NO; }
FRAME
@end

static NSRecursiveLock *staticDrawLock = nil;
@implementation DCMView (SwiftIvars)
- (int)horos_annotationType { return annotationType; } - (void)setHoros_annotationType:(int)v { annotationType = v; }
- (BOOL)horos_firstTimeDisplay { return firstTimeDisplay; } - (void)setHoros_firstTimeDisplay:(BOOL)v { firstTimeDisplay = v; }
- (BOOL)horos_noScale { return noScale; } - (void)setHoros_noScale:(BOOL)v { noScale = v; }
- (BOOL)horos_isKeyView { return isKeyView; } - (void)setHoros_isKeyView:(BOOL)v { isKeyView = v; }
- (BOOL)horos_syncOnLocationImpossible { return syncOnLocationImpossible; } - (void)setHoros_syncOnLocationImpossible:(BOOL)v { syncOnLocationImpossible = v; }
- (BOOL)horos_xFlipped { return xFlipped; } - (void)setHoros_xFlipped:(BOOL)v { xFlipped = v; }
- (BOOL)horos_yFlipped { return yFlipped; } - (void)setHoros_yFlipped:(BOOL)v { yFlipped = v; }
- (BOOL)horos_suppress_labels { return suppress_labels; } - (void)setHoros_suppress_labels:(BOOL)v { suppress_labels = v; }
- (BOOL)horos_recordAnnotationRects { return recordAnnotationRects; } - (void)setHoros_recordAnnotationRects:(BOOL)v { recordAnnotationRects = v; }
- (BOOL)horos_lensActive { return lensActive; } - (void)setHoros_lensActive:(BOOL)v { lensActive = v; }
- (NSRect)horos_drawingFrameRect { return drawingFrameRect; } - (void)setHoros_drawingFrameRect:(NSRect)v { drawingFrameRect = v; }
- (NSRect)horos_screenCaptureRect { return screenCaptureRect; } - (void)setHoros_screenCaptureRect:(NSRect)v { screenCaptureRect = v; }
- (NSMutableArray *)horos_dcmPixList { return (NSMutableArray *)dcmPixList; } - (void)setHoros_dcmPixList:(NSMutableArray *)v { dcmPixList = v; }
- (NSMutableArray *)horos_curRoiList { return curRoiList; } - (void)setHoros_curRoiList:(NSMutableArray *)v { curRoiList = v; }
- (NSMutableArray *)horos_rectArray { return rectArray; } - (void)setHoros_rectArray:(NSMutableArray *)v { [v retain]; [rectArray release]; rectArray = v; }
- (NSInteger)horos_curImage { return curImage; } - (void)setHoros_curImage:(NSInteger)v { curImage = v; }
- (DCMView *)horos_blending { return blendingView; }
- (float)horos_rotation { return rotation; } - (void)setHoros_rotation:(float)v { rotation = v; }
- (float)horos_scaleValue { return scaleValue; } - (void)setHoros_scaleValue:(float)v { scaleValue = v; }
- (float)horos_curWW { return curWW; } - (void)setHoros_curWW:(float)v { curWW = v; }
- (float)horos_curWL { return curWL; } - (void)setHoros_curWL:(float)v { curWL = v; }
- (NSPoint)horos_origin { return origin; } - (void)setHoros_origin:(NSPoint)v { origin = v; }
- (NSPoint)horos_ROISelectorStartPoint { return ROISelectorStartPoint; } - (void)setHoros_ROISelectorStartPoint:(NSPoint)v { ROISelectorStartPoint = v; }
- (NSPoint)horos_ROISelectorEndPoint { return ROISelectorEndPoint; } - (void)setHoros_ROISelectorEndPoint:(NSPoint)v { ROISelectorEndPoint = v; }
- (NSInteger)horos_imageColumns { return _imageColumns; } - (void)setHoros_imageColumns:(NSInteger)v { _imageColumns = v; }
- (NSInteger)horos_imageRows { return _imageRows; } - (void)setHoros_imageRows:(NSInteger)v { _imageRows = v; }
- (int)horos_repulsorRadius { return repulsorRadius; } - (void)setHoros_repulsorRadius:(int)v { repulsorRadius = v; }
- (ROI *)horos_lengthPendingMarker { return lengthPendingMarker; } - (void)setHoros_lengthPendingMarker:(ROI *)v { lengthPendingMarker = v; }
- (HorosAnnotationBox *)horos_showDescriptionInLargeText { return showDescriptionInLargeText; }
- (void)setHoros_showDescriptionInLargeText:(HorosAnnotationBox *)v { [v retain]; [showDescriptionInLargeText release]; showDescriptionInLargeText = v; }
- (unsigned char *)horos_redTable { return redTable; } - (unsigned char *)horos_greenTable { return greenTable; } - (unsigned char *)horos_blueTable { return blueTable; }
- (float *)horos_sliceFromTo { return &sliceFromTo[0][0]; } - (float *)horos_sliceFromToS { return &sliceFromToS[0][0]; }
- (float *)horos_sliceFromToE { return &sliceFromToE[0][0]; } - (float *)horos_sliceFromTo2 { return &sliceFromTo2[0][0]; }
- (float *)horos_sliceVector { return sliceVector; } - (float *)horos_slicePoint3D { return slicePoint3D; }
@end
@implementation DCMView (SwiftStatics)
+ (double)horos_static_deg2rad { return deg2rad; }
+ (unsigned char *)horos_static_PETredTable { return PETredTable; } + (void)setHoros_static_PETredTable:(unsigned char *)v { PETredTable = v; }
+ (unsigned char *)horos_static_PETgreenTable { return PETgreenTable; } + (void)setHoros_static_PETgreenTable:(unsigned char *)v { PETgreenTable = v; }
+ (unsigned char *)horos_static_PETblueTable { return PETblueTable; } + (void)setHoros_static_PETblueTable:(unsigned char *)v { PETblueTable = v; }
+ (NSRecursiveLock *)horos_static_drawLock { return staticDrawLock; } + (void)setHoros_static_drawLock:(NSRecursiveLock *)v { staticDrawLock = v; }
+ (BOOL)horos_static_gInvertColors { return gInvertColors; }
+ (BOOL)horos_static_OVERFLOWLINES { return OVERFLOWLINES; }
@end

static unsigned char table[768];
int main(int argc, char **argv) { @autoreleasepool {
    [NSApplication sharedApplication];
    NSArray *cases = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:nil];
    NSMutableArray *results = [NSMutableArray array];
    for (int i = 0; i < 256; ++i) { table[i] = i; table[256 + i] = 255 - i; table[512 + i] = (i * 7) % 256; }
    for (NSDictionary *c in cases) {
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300) styleMask:NSWindowStyleMaskBorderless
                                                         backing:NSBackingStoreBuffered defer:NO];
        DCMView *view = [[DCMView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
        view.wantsLayer = YES;
        [window setContentView:view];
        view->record = [NSMutableArray array];
        view->is2D = [c[@"is2D"] boolValue]; view->planar = [c[@"planar"] boolValue];
        view->dcmPixList = [c[@"image"] boolValue] ? @[@1] : nil; view->curImage = [c[@"image"] boolValue] ? 0 : -1;
        view->annotationType = [c[@"annotations"] intValue]; CLUTBARS = [c[@"clutBars"] intValue];
        view->scaleValue = [c[@"scale"] floatValue]; view->rotation = [c[@"rotation"] floatValue];
        view->origin = NSMakePoint([c[@"origin"][0] floatValue], [c[@"origin"][1] floatValue]);
        view->xFlipped = [c[@"xFlipped"] boolValue]; view->yFlipped = [c[@"yFlipped"] boolValue];
        view->curWW = [c[@"ww"] floatValue]; view->curWL = [c[@"wl"] floatValue];
        view->isKeyView = [c[@"keyView"] boolValue]; view->whiteBackground = [c[@"white"] boolValue];
        view->_imageColumns = [c[@"columns"] intValue] ?: 1; view->_imageRows = 1;
        view->curRoiList = [NSMutableArray array];
        for (int i = 0; i < 256; ++i) { view->redTable[i] = i; view->greenTable[i] = (i * 3) % 256; view->blueTable[i] = 255 - i; }
        DCMPix *pix = [[DCMPix alloc] init];
        pix.pwidth = 256; pix.pheight = 200; pix.pixelRatio = [c[@"ratio"] doubleValue] ?: 1;
        pix.pixelSpacingX = [c[@"spacingX"] doubleValue]; pix.pixelSpacingY = [c[@"spacingY"] doubleValue];
        pix.displayInverted = [c[@"displayInverted"] boolValue];
        view->curDCM = pix;
        view->controller = [[Controller alloc] init]; view->controller.highLighted = [c[@"highlight"] floatValue];
        view->controller.roiLock = [[NSRecursiveLock alloc] init];
        gInvertColors = [c[@"invert"] boolValue]; OVERFLOWLINES = [c[@"overflow"] boolValue];
        viewerCount = [c[@"viewers"] intValue] ?: 1; frontViewer = [c[@"front"] boolValue] ? view->controller : nil;
        view->notice = c[@"notice"]; view->fallback = c[@"fallback"];
        if ([c[@"fused"] boolValue]) {
            DCMView *fused = [[DCMView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
            fused->record = view->record; fused->fusedRed = table; fused->fusedWL = 120; fused->fusedWW = [c[@"fusedWW"] floatValue];
            DCMPix *fusedPix = [[DCMPix alloc] init]; fusedPix.displayInverted = [c[@"fusedInverted"] boolValue]; fused->curDCM = fusedPix;
            view->blendingView = fused;
        }
        if ([c[@"crosshair"] boolValue]) { view->crosshair = YES; view->cross[0] = 40; view->cross[1] = 70; }
        for (int i = 0; i < 2; ++i) for (int j = 0; j < 3; ++j) {
            view->sliceFromTo[i][j] = view->sliceFromToS[i][j] = view->sliceFromToE[i][j] = view->sliceFromTo2[i][j] = HUGE_VALF;
        }
        view->slicePoint3D[0] = HUGE_VALF;
        NSArray *line = c[@"line"];
        if (line) {
            view->sliceFromTo[0][0] = [line[0] floatValue]; view->sliceFromTo[0][1] = [line[1] floatValue];
            view->sliceFromTo[1][0] = [line[2] floatValue]; view->sliceFromTo[1][1] = [line[3] floatValue];
            if ([c[@"slab"] boolValue]) { memcpy(view->sliceFromToS, view->sliceFromTo, sizeof(view->sliceFromTo)); memcpy(view->sliceFromToE, view->sliceFromTo, sizeof(view->sliceFromTo)); }
            view->sliceVector[0] = [c[@"vector"] boolValue] ? 1 : 0;
        }
        if (c[@"point"]) { view->slicePoint3D[0] = [c[@"point"][0] floatValue]; view->slicePoint3D[1] = [c[@"point"][1] floatValue]; }
        if (c[@"capture"]) view->screenCaptureRect = NSMakeRect([c[@"capture"][0] floatValue], [c[@"capture"][1] floatValue], [c[@"capture"][2] floatValue], [c[@"capture"][3] floatValue]);
        NSRect frame = NSMakeRect(0, 0, 800, 600);
        [view drawFrame:frame];
        HorosROICanvas *canvas = [HorosAnnotationOverlay overlayForView:view].canvas;
        NSData *bytes = [NSData dataWithBytes:canvas.pixels length:canvas.pixelWidth * canvas.pixelHeight * 4];
        [results addObject:@{ @"name": c[@"name"], @"record": view->record, @"pixels": [bytes base64EncodedStringWithOptions:0],
                              @"size": @[@(canvas.pixelWidth), @(canvas.pixelHeight)] }];
    }
    [[NSJSONSerialization dataWithJSONObject:results options:0 error:nil] writeToFile:@(argv[2]) atomically:YES];
} return 0; }
'''

base = dict(name='', is2D=True, planar=True, image=True, annotations=3, clutBars=0, scale=1.5, rotation=0, origin=[0, 0],
            ww=400, wl=40, keyView=True, spacingX=0.7, spacingY=0.7)
CASES = [
    dict(base, name='plain 2D, full annotations'),
    dict(base, name='no annotations', annotations=0),
    dict(base, name='custom, every element shown', annotations=5),
    dict(base, name='graphics only, flipped, rotated, panned', annotations=1, xFlipped=True, yFlipped=True, rotation=33, origin=[40, -25]),
    dict(base, name='highlight', highlight=0.4),
    dict(base, name='highlight inverted', highlight=0.6, invert=True),
    dict(base, name='image CLUT bar, narrow window', clutBars=1, ww=20.5, wl=3.25, displayInverted=True),
    dict(base, name='both CLUT bars', clutBars=3, fused=True, fusedWW=300),
    dict(base, name='fused CLUT bar without table', clutBars=2, fused=True, fusedWW=80, fusedInverted=True),
    dict(base, name='key view of several viewers', viewers=3, front=True),
    dict(base, name='key view, not frontmost', viewers=3, front=False),
    dict(base, name='overflow', overflow=True, scale=4.0, origin=[120, 90], rotation=20),
    dict(base, name='mosaic tile, key', columns=2, front=True),
    dict(base, name='mosaic tile, not key', columns=2, keyView=False),
    dict(base, name='patient crosshair', crosshair=True, ratio=1.25),
    dict(base, name='reference lines and slab', line=[-30, -20, 50, 40], slab=True, is2D=True),
    dict(base, name='3D point on a line', line=[-30, -20, 50, 40], vector=True, point=[33.3, 41.7]),
    dict(base, name='3D point, no line', point=[12.5, 80.25]),
    dict(base, name='ruler, microscopic spacing', spacingX=0.0004, spacingY=0.0005, ratio=1.5),
    dict(base, name='ruler on a capture rectangle', capture=[100, 80, 500, 300]),
    dict(base, name='picture not drawn, notice', planar=False, fallback='This image cannot be displayed.'),
    dict(base, name='MPR notice over a drawn plane', notice='Metal declined the plane.'),
    dict(base, name='no image, white background', image=False, white=True, planar=False),
    dict(base, name='not a 2D viewer', is2D=False, clutBars=3, highlight=0.5, viewers=3, front=True, crosshair=True, line=[0, 0, 10, 10]),
]


def build(work, name, methods, swift_sources, frame_swift=None):
    """`methods`: the Objective-C frame, or None when `frame_swift`, the
    Swift one, is compiled instead."""
    folder = work / name
    folder.mkdir()
    host = '#import "PlanarHostMessages.h"\n' if (root / 'Horos/Sources/PlanarHostMessages.h').exists() else ''
    (folder / 'Stub.h').write_text(host + HEADER.replace('OBJC_FRAME', '' if methods is None else '- (void)drawFrame:(NSRect)aRect;\n'))
    (folder / 'Stub.m').write_text(STUB.replace('FRAME', methods or ''))
    (folder / 'HorosObjCException.h').write_text((root / 'Horos/Sources/HorosObjCException.h').read_text())
    sources = [str(root / 'Horos/Sources' / s) for s in swift_sources]
    view_swift = root / 'Horos/Sources/DCMView.swift'
    protocol = re.search(r'@objc protocol DCMViewArrayMessages \{.*?\n\}\n', view_swift.read_text(), re.S) if view_swift.exists() else None
    if protocol:
        # The frame reaches the float[2][3] selectors through DCMView's
        # protocol view (DCMView.swift), and the planar host's methods
        # (DCMView+PlanarHost.swift) directly; the double answers both itself.
        (folder / 'Host.swift').write_text('import Cocoa\n\nextension DCMView {\n'
            '    final var arrayMessages: DCMViewArrayMessages { unsafeBitCast(self, to: DCMViewArrayMessages.self) }\n'
            '}\n\n' + protocol.group(0))
        sources.append(str(folder / 'Host.swift'))
    if frame_swift is not None:
        (folder / 'DrawingFrame.swift').write_text(frame_swift)
        sources += [str(folder / 'DrawingFrame.swift'), str(root / 'Modules/IsiXImaging/Sources/ViewDrawing/DrawingGeometry.swift')]
    subprocess.run(['xcrun', 'swiftc', '-c', '-parse-as-library', '-suppress-warnings', '-module-name', 'Horos',
                    '-import-objc-header', str(folder / 'Stub.h'), '-emit-objc-header-path', str(folder / 'Horos-Swift.h'),
                    *sources, '-o', str(folder / 'swift.o'), '-wmo'], check=True, cwd=folder)
    subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-w', '-I', str(folder), '-I', str(root / 'Horos/Sources'),
                    str(folder / 'Stub.m'), '-o', str(folder / 'stub.o')], check=True)
    subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-w', '-I', str(folder),
                    str(root / 'Horos/Sources/HorosObjCException.m'), '-o', str(folder / 'exception.o')], check=True)
    subprocess.run(['xcrun', 'swiftc', str(folder / 'swift.o'), str(folder / 'stub.o'), str(folder / 'exception.o'), '-framework', 'Cocoa',
                    '-framework', 'QuartzCore', '-framework', 'Metal', '-o', str(folder / 'frame')], check=True)
    return folder / 'frame'


def main():
    common = ['AnnotationOverlay.swift', 'ROICanvas.swift', 'PlanarPerformanceTrace.swift']
    with tempfile.TemporaryDirectory(prefix='horos-frame-equivalence-') as tmp:
        work = Path(tmp)
        (work / 'cases.json').write_text(json.dumps(CASES))
        outputs = {}
        for name, methods, swift, frame_swift in (('before', old, common, None),
                                                  ('after', new, common + ['PlanarFramePresenter.swift', 'AnnotationLevel.swift'], new_swift)):
            binary = build(work, name, methods, swift, frame_swift)
            subprocess.run([str(binary), str(work / 'cases.json'), str(work / (name + '.json'))], check=True, timeout=120)
            outputs[name] = json.loads((work / (name + '.json')).read_text())
    failures = []
    drawn = 0
    window_frames = {'key view of several viewers', 'key view, not frontmost'}
    after = {b['name']: b for b in outputs['after']}
    for a, b in zip(outputs['before'], outputs['after']):
        if a['record'] != b['record']:
            failures.append('%s: the calls differ\n  before %s\n  after  %s' % (a['name'], a['record'], b['record']))
        if a['name'] in window_frames:
            if a['pixels'] == b['pixels'] or b['pixels'] == outputs['after'][0]['pixels']:
                failures.append('%s: no window frame in its colour' % a['name'])
        elif a['pixels'] != b['pixels']:
            failures.append('%s: the canvas differs (%s vs %s)' % (a['name'], hashlib.sha256(a['pixels'].encode()).hexdigest()[:12],
                                                                   hashlib.sha256(b['pixels'].encode()).hexdigest()[:12]))
        drawn += a['pixels'] != outputs['before'][1]['pixels']
    if all(name in after for name in window_frames) and \
            after['key view of several viewers']['pixels'] == after['key view, not frontmost']['pixels']:
        failures.append('the frontmost key view is framed like the other windows')
    if len(outputs['before']) != len(CASES) or len(outputs['after']) != len(CASES):
        failures.append('a case did not run')
    if failures:
        for failure in failures:
            print('FAIL:', failure)
        return 1
    print('frame equivalence: %d cases, the same canvas bytes and the same calls before the frame cycle and now%s '
          '(%d cases draw more than the plain frame)' % (len(CASES), ', in Swift' if new_swift else '', drawn))
    return 0


if __name__ == '__main__':
    sys.exit(main())
