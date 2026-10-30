#!/usr/bin/env python3
"""The 2D viewer's operations on its series do what their Objective-C did.

The reslice of the viewer's series (its worker threads and -processReslice::),
the flips, rotations and square pixels of the data set, the orientation tool,
the gantry tilt correction, -replaceSeriesWith:::, the volumic checks
(-isDataVolumicIn4D… and their correction of a first or last slice),
-computeOriginalOrientation, +loadImageData: and -copyViewerWindow moved from
ViewerController.m to Swift extensions of the class, with the geometry
(reslice dimensions and orientations, flips, rotations, the gantry tilt
matrix, the slice extrapolation) and the pixel loops in the IsiXImaging
module. This runs the same synthetic volumes through both and compares
everything they produce:

* reslice: X and Y reslices of volumes small enough to be squared, whose
  square is abandoned, too large to square, of odd sizes, oblique and with a
  negative interval, of one and two time points, in this viewer and in a new
  one, then -replaceSeriesWith::: and -copyViewerWindow;
* transforms: the vertical and horizontal flips, the three rotations and the
  square pixels of volumes of one and two time points;
* orientation: every change of the orientation tool from every orientation,
  from the orientation matrix and directly, with key images displayed,
  blending, a fusion (activated or not), brushes, non volumic data, then
  -computeOriginalOrientation and +orientation: over the slice orientations;
* volumic: the checks of loading, matrix and orientation, the correction of
  a first or last slice of another matrix or orientation (grey and RGB), in
  the current time point and in all of them;
* gantry: the correction of a tilted series, of slices of another
  orientation, of a slice the transform cannot reorient, and an exception;
* loading: +loadImageData: of plain and compressed series, of a CD, with the
  content bounds asked for, cancelled before it starts, with an exception.

The pixels of each slice are compared by a checksum of their bytes, the
geometry to the last bit.

The reference is the Objective-C of ViewerController.m in the last revision
that has it (history_reference), compiled with clang as Xcode compiles it
(manual retain and release); the other side is the current tree: the Swift
files with IsiXImaging, compiled with swiftc, with what ViewerController.m
still holds of these methods (-copyViewerWindow), or the Objective-C again if
the tree still has it (which is how this test ran, and passed, before the
conversion). Both run over the same stand-ins of the viewer, its image view,
slices, transform and panels, which record what they are given; the two
records must be identical.

    python3 tests/test-viewer-series-operations-equivalence.py [--reference REV] [--current REV] [--dump DIR]
"""
import argparse
import difflib
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs
import history_reference  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
VC = 'Horos/Sources/ViewerController.m'
MARK = '-(BOOL) processReslice:(long) directionm :(BOOL) newViewer'
SWIFT_FILES = ['ViewerController+%s.swift' % name for name in
               ('Reslice', 'SeriesTransforms', 'Orientation', 'GantryTilt', 'VolumeCheck', 'ImageLoading')]
# IsiXLogging first: the others that log write through it.
MODULES = ['IsiXLogging', 'IsiXImaging']
SCENARIOS = ['reslice', 'transforms', 'orientation', 'volumic', 'gantry', 'loading']

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--reference')
parser.add_argument('--current')
parser.add_argument('--dump', type=Path, help='write the programs and the records of both to this folder')
args = parser.parse_args()

HEADER = r'''#pragma clang diagnostic ignored "-Wnullability-completeness"
#import <Cocoa/Cocoa.h>
#import <Accelerate/Accelerate.h>
#import "HorosObjCException.h"

// The stand-ins of the viewer, its image view, slices, files and panels, and
// of the classes the series operations talk to (the transform, the brushes,
// the gantry tilt policy, the alerts), declared as the app's headers declare
// them (with the Swift names of the app's Swift classes), so that the
// Objective-C and the Swift compile against them alike. They record what
// they are given (Record) and answer from their fields.

#define MAX4D 8
#define ORIENTATION_SENSIBILITY 0.001

void Record(NSString *line);
NSString *Name(id object);
void Register(id object, NSString *name);

void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *where);
#define N2LogException(e) _N2LogExceptionImpl(e, NO, __PRETTY_FUNCTION__)
#define N2LogExceptionWithStackTrace(e) _N2LogExceptionImpl(e, YES, __PRETTY_FUNCTION__)

typedef struct { double x, y, z; } XYZ;
XYZ ArbitraryRotate(XYZ p, double theta, XYZ r);

enum { eSagittalPos = 0, eSagittalNeg, eCoronalPos, eCoronalNeg, eAxialPos, eAxialNeg };

NSInteger HorosRunAlertPanel(NSString *title, NSString *format, NSString *defaultButton, NSString *alternateButton, NSString *otherButton, ...);
NSInteger HorosRunInformationalAlertPanel(NSString *title, NSString *format, NSString *defaultButton, NSString *alternateButton, NSString *otherButton, ...);
NSInteger HorosRunCriticalAlertPanel(NSString *title, NSString *format, NSString *defaultButton, NSString *alternateButton, NSString *otherButton, ...);

@interface HorosAlertPanel : NSObject
+ (NSInteger)runWithTitle:(NSString *)title message:(NSString *)message defaultButton:(NSString *)defaultButton
          alternateButton:(NSString *)alternateButton otherButton:(NSString *)otherButton
    NS_SWIFT_NAME(run(title:message:defaultButton:alternateButton:otherButton:));
+ (NSInteger)runInformationalWithTitle:(NSString *)title message:(NSString *)message defaultButton:(NSString *)defaultButton
                       alternateButton:(NSString *)alternateButton otherButton:(NSString *)otherButton
    NS_SWIFT_NAME(runInformational(title:message:defaultButton:alternateButton:otherButton:));
+ (NSInteger)runCriticalWithTitle:(NSString *)title message:(NSString *)message defaultButton:(NSString *)defaultButton
                  alternateButton:(NSString *)alternateButton otherButton:(NSString *)otherButton
    NS_SWIFT_NAME(runCritical(title:message:defaultButton:alternateButton:otherButton:));
@end

// The status and progress of a thread (NSThread+N2), which the app's Swift
// declares as properties.
@interface NSThread (N2)
@property(retain) NSString *status;
@property CGFloat progress;
@end

@class ViewerController;

/// A slice: its pixels, geometry and PET values, as DCMPix.h declares them.
@interface DCMPix : NSObject <NSCopying> {
@public
    double orientationValues[9], originValues[3];
    BOOL loadRaises;
}
@property long pwidth, pheight;
@property(setter=setfImage:) float *fImage;
@property(nonatomic, setter=setRGB:) BOOL isRGB;
@property double pixelSpacingX, pixelSpacingY;
@property(nonatomic) double pixelRatio;
@property double sliceInterval, sliceThickness, sliceLocation;
@property long frameNo;
@property(setter=setID:) long ID;
@property(getter=Tot, setter=setTot:) long Tot;
@property BOOL displaySUVValue, SUVConverted;
@property(nonatomic) float minValueOfSeries, maxValueOfSeries, factorPET2SUV;
@property float patientsWeight, radionuclideTotalDose, radionuclideTotalDoseCorrected, decayFactor;
@property(retain) NSDate *acquisitionTime, *radiopharmaceuticalStartTime;
@property(retain) NSString *units, *decayCorrection;
@property(retain) NSString *srcFile;
@property(readonly) double originX, originY, originZ;
- (void)orientationDouble:(double*)c;
- (void)setOrientationDouble:(double*)c;
- (void)orientation:(float*)c;
- (void)setOrientation:(float*)c;
- (void)origin:(float*)o;
- (void)setOrigin:(float*)o;
- (void)setOriginDouble:(double*)o;
- (void)convertPixDoubleX:(double)x pixY:(double)y toDICOMCoords:(double*)d pixelCenter:(BOOL)pixelCenter;
- (void)computeSliceLocation;
- (void)computePixMinPixMax;
- (void)kill8bitsImage;
- (void)CheckLoadFromThread:(NSThread*)thread;
@end

@interface ITKTransform : NSObject
+ (float*) reorient2Dimage:(double*)theParameters firstObject:(DCMPix*)firstObject firstObjectOriginal:(DCMPix*)firstObjectOriginal length:(long*)length;
@end

NS_SWIFT_NAME(BrushReslice)
@interface HorosBrushReslice : NSObject
+ (HorosBrushReslice*) captureFromViewer:(ViewerController*)viewer NS_SWIFT_NAME(capture(from:));
- (void) applyToViewer:(ViewerController*)viewer NS_SWIFT_NAME(apply(to:));
- (void) applyLaterToViewer:(ViewerController*)viewer NS_SWIFT_NAME(applyLater(to:));
@end

NS_SWIFT_NAME(GantryTiltPolicy)
@interface HorosGantryTiltPolicy : NSObject
+ (void) setCorrectedDegrees:(float)degrees forViewer:(id)viewer NS_SWIFT_NAME(setCorrected(degrees:for:));
@end

@interface DicomFile : NSObject
+ (BOOL) isDICOMFile:(NSString *)file compressed:(BOOL*)compressed;
@end

@interface BrowserController : NSObject
+ (BOOL) isItCD:(NSString*)path;
@end

@interface DCMView : NSView
@property(nonatomic) float scaleValue;
@property BOOL drawing;
- (void) setIndex:(NSInteger) index;
- (void) sendSyncMessage:(NSInteger) inc;
- (void) scaleToFit;
- (void) stopROIEditingForce:(BOOL)force;
- (void) getWLWW:(float*)wl :(float*)ww;
- (void) setWLWW:(float)wl :(float)ww;
@end

/// A volume length measure of the viewer: copying it names the copy.
@interface HarnessLength : NSObject <NSCopying>
@property(copy) NSString *label;
@end

@interface ViewerController : NSWindowController {
@public
    NSMutableArray *fileList[MAX4D];
    NSMutableArray<DCMPix *> *pixList[MAX4D];
    NSData *volumeData[MAX4D];
    short curMovieIndex, maxMovieIndex, orientationVector, currentOrientationTool, originalOrientation;
    BOOL postprocessed, displayOnlyKeyImages;
    DCMView *imageView;
    NSConditionLock *processorsLock;
    int isDataVolumicIn4DLevel;
    float titledGantryDegrees;
    NSPopUpButton *popFusion, *keyImagePopUpButton;
    NSButton *activatedFusion;
    NSSlider *sliderFusion;
    NSTextField *stacksFusion;
    NSMatrix *orientationMatrix;
    NSThread *loadingThread;
    ViewerController *blendingController;
    NSString *curCLUTMenu, *curOpacityMenu;
    NSWindow *harnessWindow;
}
@property(retain) NSArray *harnessLengths;
@property BOOL harnessCopyFails;
- (void) changeImageData:(NSMutableArray*)f :(NSMutableArray*)d :(id)v :(BOOL)newViewerWindow;
- (ViewerController*) newWindow:(NSMutableArray*)pixList :(NSMutableArray*)fileList :(id)volumeData;
- (void) addMovieSerie:(NSMutableArray*)f :(NSMutableArray*)d :(id)v;
- (void) setImageIndex:(long)i;
- (float) computeInterval;
- (void) setWindowTitle:(id)sender;
- (void) adjustSlider;
- (id) startWaitProgressWindow:(NSString*)message :(long)max;
- (void) waitIncrementBy:(id)waitWindow :(long)val;
- (void) endWaitWindow:(id)waitWindow;
- (NSArray<HarnessLength *> *) volumeLengthROIsForMovieIndex:(long)movieIndex;
- (NSMutableDictionary *) volumeLengthStateForMovieIndex:(long)movieIndex create:(BOOL)create;
- (void) restoreVolumeLengthSnapshot:(NSDictionary *)snapshot movieIndex:(long)movieIndex;
- (void) ApplyCLUTString:(NSString*)str;
- (void) ApplyOpacityString:(NSString*)str;
- (void) setPostprocessed:(BOOL)v;
- (IBAction) updateImage:(id)sender;
- (void) needsDisplayUpdate;
- (void) refresh;
- (void) checkEverythingLoaded;
- (void) displayWarningIfGantryTitled;
- (void) displayAWarningIfNonTrueVolumicData;
- (IBAction) keyImageDisplayButton:(id)sender;
- (void) ActivateBlending:(ViewerController*)bC;
- (void) setFusionMode:(long)m;
- (void) propagateSettings;
- (BOOL) resampleDataWithXFactor:(float)xFactor yFactor:(float)yFactor zFactor:(float)zFactor;
- (void) copyVolumeData:(NSData**)vD andDCMPix:(NSMutableArray **)newPixList forMovieIndex:(int)v;
- (NSMutableArray*) fileList:(long)timePoint;
- (short) maxMovieIndex;
- (NSMutableArray*) pixList NS_SWIFT_NONISOLATED;
- (DCMView*) imageView;
- (IBAction) roiDeleteAll:(id)sender;
- (void) finishLoadImageData:(NSDictionary*)dict;
// The lists as an object: the Swift of the app takes the NSArray itself.
+ (NSDictionary*) openingContentBoundsForPixLists:(id)lists loadThread:(NSThread*)thread NS_SWIFT_NAME(openingContentBounds(forPixLists:load:)) NS_SWIFT_NONISOLATED;
IVAR_ACCESSORS
@end

/// A pop-up of the toolbar, whose item selections are recorded.
@interface HarnessPopUp : NSPopUpButton
@end

/// The window of a viewer, which never reaches the window server.
@interface HarnessWindow : NSWindow
@end

#ifndef HARNESS_SWIFT
// The methods under test, as the Objective-C of the driver calls them.
@interface ViewerController (SeriesOperations)
+ (void) correctGangtryTilt:(ViewerController*)viewerController;
- (void) replaceSeriesWith:(NSMutableArray*)newPixList :(NSMutableArray*)newDcmList :(NSData*)newData;
- (BOOL) waitForAProcessor;
- (void) resliceThread:(NSDictionary*)dict;
- (BOOL) processReslice:(long)directionm :(BOOL)newViewer;
+ (int) orientation:(double*)vectors;
- (IBAction) vertFlipDataSet:(id)sender;
- (IBAction) horzFlipDataSet:(id)sender;
- (void) rotateDataSet:(int)constant;
- (IBAction) squareDataSet:(id)sender;
- (IBAction) setOrientationTool:(id)sender;
- (BOOL) setOrientation:(int)newOrientationTool;
- (BOOL) isDataVolumic;
- (BOOL) isDataVolumicIn4D:(BOOL)check4D checkEverythingLoaded:(BOOL)c;
- (BOOL) isDataVolumicIn4D:(BOOL)check4D checkEverythingLoaded:(BOOL)c tryToCorrect:(BOOL)tryToCorrect;
- (BOOL) isDataVolumicIn4D:(BOOL)check4D;
- (ViewerController*) copyViewerWindow;
- (double) computeOriginalOrientation;
+ (void) loadImageData:(id)dict;
@end
#endif

#ifndef HARNESS_SWIFT
// The Swift body of -copyViewerWindow, which ViewerController.m keeps.
@interface ViewerController (HarnessDuplicate)
- (ViewerController*) horosDuplicatedViewerWindow;
@end
#endif

extern BOOL harnessReorientFails, harnessReorientRaises, harnessBrushes, harnessCompressed, harnessCD, harnessDICOMRaises;
extern long harnessReorientFailsAt, harnessReorientCalls;
extern ViewerController *harnessNewest;
extern BOOL harnessDelivered;
'''

IVARS = [
    # (kind, type, name)
    ('scalar', 'short', 'curMovieIndex'), ('scalar', 'short', 'maxMovieIndex'),
    ('scalar', 'short', 'orientationVector'), ('scalar', 'short', 'currentOrientationTool'),
    ('scalar', 'short', 'originalOrientation'), ('scalar', 'BOOL', 'postprocessed'),
    ('scalar', 'BOOL', 'displayOnlyKeyImages'), ('scalar', 'int', 'isDataVolumicIn4DLevel'),
    ('scalar', 'float', 'titledGantryDegrees'),
    ('object', 'DCMView*', 'imageView'), ('object', 'NSThread*', 'loadingThread'),
    ('object', 'ViewerController*', 'blendingController'),
    ('object', 'NSString*', 'curCLUTMenu'), ('object', 'NSString*', 'curOpacityMenu'),
    ('readonly', 'NSConditionLock*', 'processorsLock'),
    ('outlet', 'NSPopUpButton*', 'popFusion'), ('outlet', 'NSPopUpButton*', 'keyImagePopUpButton'),
    ('outlet', 'NSButton*', 'activatedFusion'), ('outlet', 'NSSlider*', 'sliderFusion'),
    ('outlet', 'NSTextField*', 'stacksFusion'), ('outlet', 'NSMatrix*', 'orientationMatrix'),
]
NONISOLATED = {'curMovieIndex', 'maxMovieIndex', 'imageView', 'postprocessed', 'loadingThread', 'processorsLock'}


def accessors():
    """The declarations and implementations of ViewerController (SwiftIvars), as the app's."""
    declared, implemented = [], []
    for kind, type_, name in IVARS:
        tail = ' NS_SWIFT_NONISOLATED' if name in NONISOLATED else ''
        if kind in ('outlet', 'readonly'):
            declared.append('@property(readonly, nullable) %s horos_%s%s;' % (type_, name, tail))
            implemented.append('- (%s)horos_%s { return %s; }' % (type_, name, name))
        elif kind == 'object':
            declared.append('@property(retain, nullable) %s horos_%s%s;' % (type_, name, tail))
            implemented.append('- (%s)horos_%s { return %s; }' % (type_, name, name))
            implemented.append('- (void)setHoros_%s:(%s)value { [value retain]; [%s release]; %s = value; }' % (name, type_, name, name))
        else:
            declared.append('@property(assign) %s horos_%s%s;' % (type_, name, tail))
            implemented.append('- (%s)horos_%s { return %s; }' % (type_, name, name))
            implemented.append('- (void)setHoros_%s:(%s)value { %s = value; }' % (name, type_, name))
    declared += ['- (nullable NSMutableArray*)horos_fileListAt:(NSInteger)index NS_SWIFT_NONISOLATED;',
                 '- (nullable NSMutableArray<DCMPix *>*)horos_pixListAt:(NSInteger)index NS_SWIFT_NONISOLATED;']
    implemented += ['- (NSMutableArray*)horos_fileListAt:(NSInteger)index { return fileList[index]; }',
                    '- (NSMutableArray*)horos_pixListAt:(NSInteger)index { return pixList[index]; }']
    return '\n'.join(declared), '\n'.join(implemented)


DECLARED, IMPLEMENTED = accessors()
HEADER = HEADER.replace('IVAR_ACCESSORS', DECLARED)

STUBS = r'''#import "Harness.h"
#include <stdatomic.h>

static NSMapTable *names;
static NSLock *recordLock;

void Register(id object, NSString *name) {
    if (!names) names = [[NSMapTable mapTableWithKeyOptions: NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsStrongMemory
                                                valueOptions: NSPointerFunctionsStrongMemory] retain];
    [names setObject: name forKey: object];
}

NSString *Name(id object) {
    if (object == nil) return @"nil";
    NSString *name = [names objectForKey: object];
    if (name) return name;
    if ([object isKindOfClass: [NSString class]]) return [NSString stringWithFormat: @"\"%@\"", object];
    if ([object isKindOfClass: [NSNumber class]]) return [object stringValue];
    if ([object isKindOfClass: [NSArray class]] || [object isKindOfClass: [NSSet class]]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (id item in object) [parts addObject: Name(item)];
        return [NSString stringWithFormat: @"[%@]", [parts componentsJoinedByString: @","]];
    }
    if ([object isKindOfClass: [NSDictionary class]]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (id key in [[object allKeys] sortedArrayUsingSelector: @selector(compare:)]) [parts addObject: [NSString stringWithFormat: @"%@=%@", key, Name([object objectForKey: key])]];
        return [NSString stringWithFormat: @"{%@}", [parts componentsJoinedByString: @","]];
    }
    if ([object isKindOfClass: [HarnessLength class]]) return [NSString stringWithFormat: @"length %@", [object label]];
    return [NSString stringWithFormat: @"<%@>", NSStringFromClass([object class])];
}

void Record(NSString *line) {
    if (!recordLock) recordLock = [NSLock new];
    [recordLock lock];
    printf("%s\n", line.UTF8String);
    fflush(stdout);
    [recordLock unlock];
}

void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *where) {
    // The category of the reference's blocks is not part of the name.
    NSString *function = [@(where) stringByReplacingOccurrencesOfString: @"(SeriesOperations)" withString: @""];
    Record([NSString stringWithFormat: @"exception %@ %@ stack %d in %@", e.name, e.reason, logStack, function]);
}

// ArbitraryRotate and Normalise, as DCMView.m had them.
static void Normalise(XYZ *p) {
    double length;
    length = sqrt(p->x * p->x + p->y * p->y + p->z * p->z);
    if (length != 0) {
        p->x /= length;
        p->y /= length;
        p->z /= length;
    } else {
        p->x = 0;
        p->y = 0;
        p->z = 0;
    }
}

XYZ ArbitraryRotate(XYZ p, double theta, XYZ r) {
    XYZ q = {0.0,0.0,0.0};
    double costheta,sintheta;
    Normalise(&r);
    costheta = cos(theta);
    sintheta = sin(theta);
    q.x += (costheta + (1.0 - costheta) * r.x * r.x) * p.x;
    q.x += ((1.0 - costheta) * r.x * r.y - r.z * sintheta) * p.y;
    q.x += ((1.0 - costheta) * r.x * r.z + r.y * sintheta) * p.z;
    q.y += ((1.0 - costheta) * r.x * r.y + r.z * sintheta) * p.x;
    q.y += (costheta + (1.0 - costheta) * r.y * r.y) * p.y;
    q.y += ((1.0 - costheta) * r.y * r.z - r.x * sintheta) * p.z;
    q.z += ((1.0 - costheta) * r.x * r.z - r.y * sintheta) * p.x;
    q.z += ((1.0 - costheta) * r.y * r.z + r.x * sintheta) * p.y;
    q.z += (costheta + (1.0 - costheta) * r.z * r.z) * p.z;
    return(q);
}

static NSInteger Alert(NSString *kind, NSString *title, NSString *message, NSString *a, NSString *b, NSString *c) {
    Record([NSString stringWithFormat: @"alert %@ %@ / %@ [%@|%@|%@]", kind, Name(title), Name(message), Name(a), Name(b), Name(c)]);
    return 1;
}

NSInteger HorosRunAlertPanel(NSString *title, NSString *format, NSString *a, NSString *b, NSString *c, ...) {
    va_list list; va_start(list, c);
    NSString *message = [[[NSString alloc] initWithFormat: format arguments: list] autorelease];
    va_end(list);
    return Alert(@"plain", title, message, a, b, c);
}
NSInteger HorosRunInformationalAlertPanel(NSString *title, NSString *format, NSString *a, NSString *b, NSString *c, ...) {
    va_list list; va_start(list, c);
    NSString *message = [[[NSString alloc] initWithFormat: format arguments: list] autorelease];
    va_end(list);
    return Alert(@"informational", title, message, a, b, c);
}
NSInteger HorosRunCriticalAlertPanel(NSString *title, NSString *format, NSString *a, NSString *b, NSString *c, ...) {
    va_list list; va_start(list, c);
    NSString *message = [[[NSString alloc] initWithFormat: format arguments: list] autorelease];
    va_end(list);
    return Alert(@"critical", title, message, a, b, c);
}

@implementation HorosAlertPanel
+ (NSInteger)runWithTitle:(NSString *)t message:(NSString *)m defaultButton:(NSString *)a alternateButton:(NSString *)b otherButton:(NSString *)c { return Alert(@"plain", t, m, a, b, c); }
+ (NSInteger)runInformationalWithTitle:(NSString *)t message:(NSString *)m defaultButton:(NSString *)a alternateButton:(NSString *)b otherButton:(NSString *)c { return Alert(@"informational", t, m, a, b, c); }
+ (NSInteger)runCriticalWithTitle:(NSString *)t message:(NSString *)m defaultButton:(NSString *)a alternateButton:(NSString *)b otherButton:(NSString *)c { return Alert(@"critical", t, m, a, b, c); }
@end

@implementation NSThread (N2)
- (NSString*)status { return self.threadDictionary[@"harnessStatus"]; }
- (void)setStatus:(NSString*)status { Record([NSString stringWithFormat: @"thread status %@", Name(status)]); self.threadDictionary[@"harnessStatus"] = status; }
- (CGFloat)progress { return [self.threadDictionary[@"harnessProgress"] doubleValue]; }
- (void)setProgress:(CGFloat)progress { Record([NSString stringWithFormat: @"thread progress %g", progress]); self.threadDictionary[@"harnessProgress"] = @(progress); }
@end

BOOL harnessReorientFails = NO, harnessReorientRaises = NO, harnessBrushes = NO, harnessCompressed = NO, harnessCD = NO, harnessDICOMRaises = NO;
long harnessReorientFailsAt = -1, harnessReorientCalls = 0;
static atomic_long loads;

long HarnessLoads(void) { return atomic_load(&loads); }

@implementation DCMPix
- (id) copyWithZone:(NSZone*) zone {
    DCMPix *p = [[DCMPix allocWithZone: zone] init];
    memcpy(p->orientationValues, orientationValues, sizeof(orientationValues));
    memcpy(p->originValues, originValues, sizeof(originValues));
    p.pwidth = self.pwidth; p.pheight = self.pheight; p.fImage = self.fImage; p.isRGB = self.isRGB;
    p.pixelSpacingX = self.pixelSpacingX; p.pixelSpacingY = self.pixelSpacingY; p.pixelRatio = self.pixelRatio;
    p.sliceInterval = self.sliceInterval; p.sliceThickness = self.sliceThickness; p.sliceLocation = self.sliceLocation;
    p.frameNo = self.frameNo; p.ID = self.ID; p.Tot = self.Tot;
    p.minValueOfSeries = self.minValueOfSeries; p.maxValueOfSeries = self.maxValueOfSeries;
    p.srcFile = self.srcFile; p.units = @"copied"; p.decayCorrection = @"copied";
    return p;
}
- (double) originX { return originValues[0]; }
- (double) originY { return originValues[1]; }
- (double) originZ { return originValues[2]; }
static void Normal(double *o) {
    o[6] = o[1]*o[5] - o[2]*o[4];
    o[7] = o[2]*o[3] - o[0]*o[5];
    o[8] = o[0]*o[4] - o[1]*o[3];
}
- (void)orientationDouble:(double*)c { memcpy(c, orientationValues, sizeof(orientationValues)); }
- (void)setOrientationDouble:(double*)c { memcpy(orientationValues, c, 6 * sizeof(double)); Normal(orientationValues); }
- (void)orientation:(float*)c { for (int i = 0; i < 9; i++) c[i] = orientationValues[i]; }
- (void)setOrientation:(float*)c { for (int i = 0; i < 6; i++) orientationValues[i] = c[i]; Normal(orientationValues); }
- (void)origin:(float*)o { for (int i = 0; i < 3; i++) o[i] = originValues[i]; }
- (void)setOrigin:(float*)o { for (int i = 0; i < 3; i++) originValues[i] = o[i]; }
- (void)setOriginDouble:(double*)o { memcpy(originValues, o, sizeof(originValues)); }
- (void)convertPixDoubleX:(double)x pixY:(double)y toDICOMCoords:(double*)d pixelCenter:(BOOL)pixelCenter {
    if (pixelCenter) { x -= 0.5; y -= 0.5; }
    for (int i = 0; i < 3; i++) d[i] = originValues[i] + y*orientationValues[3+i]*self.pixelSpacingY + x*orientationValues[i]*self.pixelSpacingX;
}
- (void)computeSliceLocation { self.sliceLocation = originValues[0]*orientationValues[6] + originValues[1]*orientationValues[7] + originValues[2]*orientationValues[8]; }
- (void)computePixMinPixMax { Record([NSString stringWithFormat: @"%@ computePixMinPixMax", Name(self)]); }
- (void)kill8bitsImage { Record([NSString stringWithFormat: @"%@ kill8bitsImage", Name(self)]); }
- (float)extreme:(BOOL)maximum {
    float m = maximum ? -FLT_MAX : FLT_MAX;
    long n = self.pwidth * self.pheight;
    for (long i = 0; i < n; i++) m = maximum ? MAX(m, self.fImage[i]) : MIN(m, self.fImage[i]);
    return m;
}
- (float)minValueOfSeries { if (_minValueOfSeries == 0 && !self.isRGB) _minValueOfSeries = [self extreme: NO]; return _minValueOfSeries; }
- (float)maxValueOfSeries { if (_maxValueOfSeries == 0 && !self.isRGB) _maxValueOfSeries = [self extreme: YES]; return _maxValueOfSeries; }
- (void)CheckLoadFromThread:(NSThread*)thread { atomic_fetch_add(&loads, 1); }
@end

@implementation ITKTransform
+ (float*) reorient2Dimage:(double*)p firstObject:(DCMPix*)first firstObjectOriginal:(DCMPix*)original length:(long*)length {
    NSMutableString *line = [NSMutableString stringWithFormat: @"reorient %@ onto %@:", Name(original), Name(first)];
    for (int i = 0; i < 12; i++) [line appendFormat: @" %a", p[i]];
    Record(line);
    if (harnessReorientRaises) [NSException raise: @"HarnessReorient" format: @"cannot reorient %@", Name(original)];
    if (harnessReorientFails && harnessReorientCalls++ == harnessReorientFailsAt) return NULL;
    long n = first.pwidth * first.pheight;
    *length = n * sizeof(float);
    float *result = malloc(*length);
    for (long i = 0; i < n; i++) result[i] = original.fImage[(n - 1 - i)] * 0.5f + (float)(p[0] + p[4] + p[8]);
    return result;
}
@end

@implementation HorosBrushReslice
+ (HorosBrushReslice*) captureFromViewer:(ViewerController*)viewer {
    Record([NSString stringWithFormat: @"brushes captured from %@ (%d)", Name(viewer), harnessBrushes]);
    if (!harnessBrushes) return nil;
    HorosBrushReslice *b = [[HorosBrushReslice new] autorelease];
    Register(b, [NSString stringWithFormat: @"brushes of %@", Name(viewer)]);
    return b;
}
- (void) applyToViewer:(ViewerController*)viewer { Record([NSString stringWithFormat: @"%@ applied to %@", Name(self), Name(viewer)]); }
- (void) applyLaterToViewer:(ViewerController*)viewer { Record([NSString stringWithFormat: @"%@ applied later to %@", Name(self), Name(viewer)]); }
@end

@implementation HorosGantryTiltPolicy
+ (void) setCorrectedDegrees:(float)degrees forViewer:(id)viewer { Record([NSString stringWithFormat: @"gantry corrected %a for %@", degrees, Name(viewer)]); }
@end

@implementation DicomFile
+ (BOOL) isDICOMFile:(NSString *)file compressed:(BOOL*)compressed {
    Record([NSString stringWithFormat: @"isDICOMFile %@", Name(file)]);
    if (harnessDICOMRaises) [NSException raise: @"HarnessDICOM" format: @"cannot read %@", file];
    *compressed = harnessCompressed;
    return YES;
}
@end

@implementation BrowserController
+ (BOOL) isItCD:(NSString*)path { Record([NSString stringWithFormat: @"isItCD %@", Name(path)]); return harnessCD; }
@end

@implementation DCMView
- (void) setIndex:(NSInteger) index { Record([NSString stringWithFormat: @"%@ setIndex %ld", Name(self), (long)index]); }
- (void) sendSyncMessage:(NSInteger) inc { Record([NSString stringWithFormat: @"%@ sendSyncMessage %ld", Name(self), (long)inc]); }
- (void) scaleToFit { Record([NSString stringWithFormat: @"%@ scaleToFit", Name(self)]); }
- (void) stopROIEditingForce:(BOOL)force { Record([NSString stringWithFormat: @"%@ stopROIEditingForce %d", Name(self), force]); }
- (void) getWLWW:(float*)wl :(float*)ww { *wl = 40; *ww = 400; Record([NSString stringWithFormat: @"%@ getWLWW", Name(self)]); }
- (void) setWLWW:(float)wl :(float)ww { Record([NSString stringWithFormat: @"%@ setWLWW %g %g", Name(self), wl, ww]); }
- (void) setScaleValue:(float)value { Record([NSString stringWithFormat: @"%@ scaleValue %a", Name(self), value]); _scaleValue = value; }
- (void) setDrawing:(BOOL)value { Record([NSString stringWithFormat: @"%@ drawing %d", Name(self), value]); _drawing = value; }
- (void) setNeedsDisplay:(BOOL)flag { Record([NSString stringWithFormat: @"%@ needsDisplay %d", Name(self), flag]); }
@end

@implementation HarnessLength
- (id) copyWithZone:(NSZone*)zone { HarnessLength *l = [[HarnessLength allocWithZone: zone] init]; l.label = [self.label stringByAppendingString: @"'"]; return l; }
@end

@implementation HarnessPopUp
- (void) selectItemAtIndex:(NSInteger)index { Record([NSString stringWithFormat: @"%@ selectItemAtIndex %ld", Name(self), (long)index]); [super selectItemAtIndex: index]; }
- (BOOL) selectItemWithTag:(NSInteger)tag { Record([NSString stringWithFormat: @"%@ selectItemWithTag %ld", Name(self), (long)tag]); return [super selectItemWithTag: tag]; }
@end

@implementation HarnessWindow
- (void) makeKeyAndOrderFront:(id)sender { Record([NSString stringWithFormat: @"%@ makeKeyAndOrderFront %@", Name(self), Name(sender)]); }
@end

static int viewers = 0;
ViewerController *harnessNewest = nil;
BOOL harnessDelivered = NO;

@implementation ViewerController
IVAR_IMPLEMENTATIONS
- (instancetype) init {
    if ((self = [super initWithWindow: nil])) {
        processorsLock = [[NSConditionLock alloc] initWithCondition: 1];
        imageView = [[DCMView alloc] initWithFrame: NSMakeRect(0, 0, 64, 64)];
        Register(self, [NSString stringWithFormat: @"viewer%d", ++viewers]);
        Register(imageView, [NSString stringWithFormat: @"view of viewer%d", viewers]);
        maxMovieIndex = 1;
        originalOrientation = -1;
        curCLUTMenu = [@"CLUT A" retain];
        curOpacityMenu = [@"Opacity B" retain];
    }
    return self;
}
- (NSWindow*) window {
    if (!harnessWindow) {
        harnessWindow = [[HarnessWindow alloc] initWithContentRect: NSMakeRect(0, 0, 10, 10) styleMask: NSWindowStyleMaskBorderless backing: NSBackingStoreBuffered defer: YES];
        Register(harnessWindow, [NSString stringWithFormat: @"window of %@", Name(self)]);
    }
    return harnessWindow;
}
- (void) install:(NSMutableArray*)f :(NSMutableArray*)d :(NSData*)v at:(int)i {
    [pixList[i] release]; pixList[i] = [f retain];
    [fileList[i] release]; fileList[i] = [d retain];
    [volumeData[i] release]; volumeData[i] = [v retain];
}
- (void) changeImageData:(NSMutableArray*)f :(NSMutableArray*)d :(id)v :(BOOL)newViewerWindow {
    Record([NSString stringWithFormat: @"%@ changeImageData %lu slices %lu files %lu bytes %d", Name(self), (unsigned long)f.count, (unsigned long)d.count, (unsigned long)[v length], newViewerWindow]);
    [self install: f :d :v at: 0];
    maxMovieIndex = 1; curMovieIndex = 0;
}
- (ViewerController*) newWindow:(NSMutableArray*)f :(NSMutableArray*)d :(id)v {
    ViewerController *viewer = [[[ViewerController alloc] init] autorelease];
    Record([NSString stringWithFormat: @"%@ newWindow %@ %lu slices %lu files %lu bytes", Name(self), Name(viewer), (unsigned long)f.count, (unsigned long)d.count, (unsigned long)[v length]]);
    [viewer install: f :d :v at: 0];
    [viewer retain];
    harnessNewest = viewer;
    return viewer;
}
- (void) addMovieSerie:(NSMutableArray*)f :(NSMutableArray*)d :(id)v {
    Record([NSString stringWithFormat: @"%@ addMovieSerie %lu slices %lu files %lu bytes", Name(self), (unsigned long)f.count, (unsigned long)d.count, (unsigned long)[v length]]);
    [self install: f :d :v at: maxMovieIndex];
    maxMovieIndex++;
}
- (void) setImageIndex:(long)i { Record([NSString stringWithFormat: @"%@ setImageIndex %ld", Name(self), i]); }
- (float) computeInterval { Record([NSString stringWithFormat: @"%@ computeInterval", Name(self)]); return 1; }
- (void) setWindowTitle:(id)sender { Record([NSString stringWithFormat: @"%@ setWindowTitle %@", Name(self), Name(sender)]); }
- (void) adjustSlider { Record([NSString stringWithFormat: @"%@ adjustSlider", Name(self)]); }
- (id) startWaitProgressWindow:(NSString*)message :(long)max {
    Record([NSString stringWithFormat: @"%@ startWaitProgressWindow %@ %ld", Name(self), Name(message), max]);
    id w = [[NSObject new] autorelease];
    Register(w, [NSString stringWithFormat: @"wait %@", message]);
    return w;
}
- (void) waitIncrementBy:(id)waitWindow :(long)val { Record([NSString stringWithFormat: @"%@ waitIncrementBy %@ %ld", Name(self), Name(waitWindow), val]); }
- (void) endWaitWindow:(id)waitWindow { Record([NSString stringWithFormat: @"%@ endWaitWindow %@", Name(self), Name(waitWindow)]); }
- (NSArray<HarnessLength *> *) volumeLengthROIsForMovieIndex:(long)movieIndex {
    Record([NSString stringWithFormat: @"%@ volumeLengthROIsForMovieIndex %ld", Name(self), movieIndex]);
    NSMutableArray *result = [NSMutableArray array];
    for (HarnessLength *l in self.harnessLengths) if ([l.label hasPrefix: [NSString stringWithFormat: @"m%ld", movieIndex]]) [result addObject: l];
    return result;
}
- (NSMutableDictionary *) volumeLengthStateForMovieIndex:(long)movieIndex create:(BOOL)create {
    Record([NSString stringWithFormat: @"%@ volumeLengthStateForMovieIndex %ld create %d", Name(self), movieIndex, create]);
    return [NSMutableDictionary dictionaryWithObjectsAndKeys: @(movieIndex), @"movie", [NSMutableDictionary dictionary], @"anchors", nil];
}
- (void) restoreVolumeLengthSnapshot:(NSDictionary *)snapshot movieIndex:(long)movieIndex {
    Record([NSString stringWithFormat: @"%@ restoreVolumeLengthSnapshot %@ movie %ld (state %@, mutable %d)", Name(self), Name(snapshot[@"rois"]), movieIndex,
            Name(snapshot[@"state"]), [snapshot[@"state"] isKindOfClass: [NSMutableDictionary class]]]);
}
- (void) ApplyCLUTString:(NSString*)str { Record([NSString stringWithFormat: @"%@ ApplyCLUTString %@", Name(self), Name(str)]); }
- (void) ApplyOpacityString:(NSString*)str { Record([NSString stringWithFormat: @"%@ ApplyOpacityString %@", Name(self), Name(str)]); }
- (void) setPostprocessed:(BOOL)v { Record([NSString stringWithFormat: @"%@ setPostprocessed %d", Name(self), v]); postprocessed = v; }
- (IBAction) updateImage:(id)sender { Record([NSString stringWithFormat: @"%@ updateImage %@", Name(self), Name(sender)]); }
- (void) needsDisplayUpdate { Record([NSString stringWithFormat: @"%@ needsDisplayUpdate", Name(self)]); }
- (void) refresh { Record([NSString stringWithFormat: @"%@ refresh", Name(self)]); }
- (void) checkEverythingLoaded { Record([NSString stringWithFormat: @"%@ checkEverythingLoaded", Name(self)]); }
- (void) displayWarningIfGantryTitled { Record([NSString stringWithFormat: @"%@ displayWarningIfGantryTitled", Name(self)]); }
- (void) displayAWarningIfNonTrueVolumicData { Record([NSString stringWithFormat: @"%@ displayAWarningIfNonTrueVolumicData", Name(self)]); }
- (IBAction) keyImageDisplayButton:(id)sender { Record([NSString stringWithFormat: @"%@ keyImageDisplayButton %@", Name(self), Name(sender)]); displayOnlyKeyImages = NO; }
- (void) ActivateBlending:(ViewerController*)bC { Record([NSString stringWithFormat: @"%@ ActivateBlending %@", Name(self), Name(bC)]); [blendingController release]; blendingController = [bC retain]; }
- (void) setFusionMode:(long)m { Record([NSString stringWithFormat: @"%@ setFusionMode %ld", Name(self), m]); }
- (void) propagateSettings { Record([NSString stringWithFormat: @"%@ propagateSettings", Name(self)]); }
- (BOOL) resampleDataWithXFactor:(float)x yFactor:(float)y zFactor:(float)z { Record([NSString stringWithFormat: @"%@ resample %a %a %a", Name(self), x, y, z]); return YES; }
- (void) copyVolumeData:(NSData**)vD andDCMPix:(NSMutableArray **)newPixList forMovieIndex:(int)v {
    Record([NSString stringWithFormat: @"%@ copyVolumeData %d", Name(self), v]);
    *vD = nil; *newPixList = nil;
    if (self.harnessCopyFails && v == 1) return;
    NSUInteger bytes = 0;
    for (DCMPix *p in pixList[v]) bytes += p.pwidth * p.pheight * 4;
    NSMutableData *data = [NSMutableData dataWithLength: bytes];
    NSMutableArray *copies = [NSMutableArray array];
    float *at = data.mutableBytes;
    for (DCMPix *p in pixList[v]) {
        DCMPix *c = [[p copy] autorelease];
        memcpy(at, p.fImage, p.pwidth * p.pheight * 4);
        c.fImage = at; at += p.pwidth * p.pheight;
        [copies addObject: c];
    }
    *vD = data; *newPixList = copies;
}
- (NSMutableArray*) fileList:(long)timePoint { return fileList[timePoint]; }
- (short) maxMovieIndex { return maxMovieIndex; }
- (NSMutableArray*) pixList { return pixList[curMovieIndex]; }
- (DCMView*) imageView { return imageView; }
- (IBAction) roiDeleteAll:(id)sender { Record([NSString stringWithFormat: @"%@ roiDeleteAll %@", Name(self), Name(sender)]); }
- (void) finishLoadImageData:(NSDictionary*)dict {
    NSMutableDictionary *seen = [[dict mutableCopy] autorelease];
    NSThread *thread = seen[@"loadThread"];
    [seen removeObjectForKey: @"loadThread"];
    Record([NSString stringWithFormat: @"%@ finishLoadImageData %@ thread %@ (%@) loads %ld", Name(self), [[[seen allKeys] sortedArrayUsingSelector: @selector(compare:)] componentsJoinedByString: @","],
            thread.name, Name(seen[@"openingContentBounds"]), HarnessLoads()]);
    harnessDelivered = YES;
}
+ (NSDictionary*) openingContentBoundsForPixLists:(id)lists loadThread:(NSThread*)thread {
    Record([NSString stringWithFormat: @"openingContentBoundsForPixLists %lu lists, %@", (unsigned long)[lists count], thread.name]);
    return @{@"bounds": @([lists count])};
}
@end
'''

DRIVER = r'''#import "Harness.h"

extern long HarnessLoads(void);

static NSMutableArray *volumes;

static uint64_t Checksum(const void *bytes, size_t length) {
    uint64_t h = 1469598103934665603ULL;
    const unsigned char *p = bytes;
    for (size_t i = 0; i < length; i++) { h ^= p[i]; h *= 1099511628211ULL; }
    return h;
}

/// A volume of `count` slices of `w`×`h` for each of `movies` time points,
/// stacked along the normal of `orientation` (row, column) by `interval`.
static ViewerController *Volume(long w, long h, long count, int movies, const double (*rows)[3], double sx, double sy, double interval, BOOL rgb) {
    const double *row = rows[0], *column = rows[1];
    ViewerController *v = [[ViewerController alloc] init];
    v->maxMovieIndex = movies;
    for (int m = 0; m < movies; m++) {
        NSMutableData *data = [NSMutableData dataWithLength: w * h * count * sizeof(float)];
        [volumes addObject: data];
        float *f = data.mutableBytes;
        NSMutableArray *pixes = [NSMutableArray array], *files = [NSMutableArray array];
        for (long z = 0; z < count; z++) {
            DCMPix *p = [[DCMPix new] autorelease];
            Register(p, [NSString stringWithFormat: @"%@ m%d s%ld", Name(v), m, z]);
            p.pwidth = w; p.pheight = h; p.fImage = f + w * h * z; p.isRGB = rgb;
            for (long i = 0; i < w * h; i++) {
                long x = i % w, y = i / w;
                if (rgb) ((unsigned int*)p.fImage)[i] = (unsigned int)(0xff000000u | (x * 9 + y * 5 + z * 3 + m) * 2654435761u);
                else p.fImage[i] = (float)((x * 7 + y * 13 + z * 29 + m * 101) % 251) + 0.25f * (float)(x % 3) - (float)z / 7.0f;
            }
            double o[9] = {row[0], row[1], row[2], column[0], column[1], column[2], 0, 0, 0};
            [p setOrientationDouble: o];
            double origin[3];
            // Positions that are not round, so that the order of the operations shows.
            for (int i = 0; i < 3; i++) origin[i] = -10.5 + i * 3.25 + z * interval * p->orientationValues[6 + i] + z * 0.0123 * (i + 1) / 3.0;
            [p setOriginDouble: origin];
            p.pixelSpacingX = sx; p.pixelSpacingY = sy; p.pixelRatio = sy / sx;
            p.sliceInterval = interval; p.sliceThickness = fabs(interval);
            p.frameNo = z; p.ID = z; p.Tot = count;
            p.displaySUVValue = m % 2; p.SUVConverted = YES; p.factorPET2SUV = 1.5f + m; p.patientsWeight = 70.25f;
            p.radionuclideTotalDose = 300.5f; p.radionuclideTotalDoseCorrected = 280.75f; p.decayFactor = 1.125f;
            p.acquisitionTime = [NSDate dateWithTimeIntervalSinceReferenceDate: 1000 + z];
            p.radiopharmaceuticalStartTime = [NSDate dateWithTimeIntervalSinceReferenceDate: 500];
            p.units = @"BQML"; p.decayCorrection = @"START";
            p.srcFile = [NSString stringWithFormat: @"/series/m%d/s%ld.dcm", m, z];
            [pixes addObject: p];
            [files addObject: [NSMutableDictionary dictionaryWithObjectsAndKeys: @(w), @"width", @(h), @"height", [NSString stringWithFormat: @"file m%d s%ld", m, z], @"name", nil]];
            Register(files.lastObject, [NSString stringWithFormat: @"file m%d s%ld of %@", m, z, Name(v)]);
        }
        v->pixList[m] = [pixes retain];
        v->fileList[m] = [files retain];
        v->volumeData[m] = [data retain];
    }
    return v;
}

static const double Axial[2][3] = {{1, 0, 0}, {0, 1, 0}};
static const double Coronal[2][3] = {{1, 0, 0}, {0, 0, -1}};
static const double Sagittal[2][3] = {{0, 1, 0}, {0, 0, -1}};
static const double Oblique[2][3] = {{0.9659258262890683, 0.25881904510252074, 0}, {-0.17101007166283436, 0.6382393291801974, -0.7505553499465136}};

static void DumpPix(NSString *label, DCMPix *p) {
    double o[9]; [p orientationDouble: o];
    NSMutableString *line = [NSMutableString stringWithFormat: @"  %@: %ldx%ld rgb %d sx %a sy %a ratio %a interval %a thickness %a location %a frame %ld id %ld tot %ld orientation",
                             label, p.pwidth, p.pheight, p.isRGB, p.pixelSpacingX, p.pixelSpacingY, p.pixelRatio, p.sliceInterval, p.sliceThickness, p.sliceLocation, p.frameNo, p.ID, p.Tot];
    for (int i = 0; i < 9; i++) [line appendFormat: @" %a", o[i]];
    [line appendFormat: @" origin %a %a %a", p.originX, p.originY, p.originZ];
    [line appendFormat: @" suv %d %d %a %a %a %a %a %@ %@ %@ %@", p.displaySUVValue, p.SUVConverted, p.factorPET2SUV, p.patientsWeight, p.radionuclideTotalDose,
        p.radionuclideTotalDoseCorrected, p.decayFactor, p.acquisitionTime, p.radiopharmaceuticalStartTime, p.units, p.decayCorrection];
    [line appendFormat: @" min %a max %a pixels %016llx", p.minValueOfSeries, p.maxValueOfSeries, Checksum(p.fImage, p.pwidth * p.pheight * 4)];
    Record(line);
}

static void Dump(ViewerController *v) {
    Record([NSString stringWithFormat: @"%@: movie %d/%d postprocessed %d orientation tool %d original %d vector %d level %d key images %d blending %@ matrix %ld fusion %ld/%ld slab %ld/%ld",
            Name(v), v->curMovieIndex, v->maxMovieIndex, v->postprocessed, v->currentOrientationTool, v->originalOrientation, v->orientationVector,
            v->isDataVolumicIn4DLevel, v->displayOnlyKeyImages, Name(v->blendingController), (long)[v->orientationMatrix selectedTag],
            (long)[v->popFusion selectedTag], (long)v->activatedFusion.state, (long)v->sliderFusion.integerValue, (long)v->stacksFusion.integerValue]);
    for (int m = 0; m < v->maxMovieIndex; m++) {
        Record([NSString stringWithFormat: @" movie %d: %lu slices, files %@, data %lu bytes", m, (unsigned long)v->pixList[m].count, Name(v->fileList[m]), (unsigned long)v->volumeData[m].length]);
        long s = 0;
        for (DCMPix *p in v->pixList[m]) DumpPix([NSString stringWithFormat: @"s%ld", s++], p);
    }
}

static void Panels(ViewerController *v) {
    v->orientationMatrix = [[NSMatrix alloc] initWithFrame: NSMakeRect(0, 0, 90, 30) mode: NSRadioModeMatrix cellClass: [NSButtonCell class] numberOfRows: 1 numberOfColumns: 3];
    for (int i = 0; i < 3; i++) [[v->orientationMatrix cellAtRow: 0 column: i] setTag: i];
    Register(v->orientationMatrix, @"orientation matrix");
    v->popFusion = [[HarnessPopUp alloc] initWithFrame: NSZeroRect pullsDown: NO];
    for (int i = 0; i < 4; i++) { [v->popFusion addItemWithTitle: [NSString stringWithFormat: @"fusion %d", i]]; [[v->popFusion lastItem] setTag: i]; }
    Register(v->popFusion, @"fusion popup");
    v->keyImagePopUpButton = [[HarnessPopUp alloc] initWithFrame: NSZeroRect pullsDown: NO];
    [v->keyImagePopUpButton addItemsWithTitles: @[@"All images", @"Key images"]];
    Register(v->keyImagePopUpButton, @"key image popup");
    v->activatedFusion = [[NSButton alloc] initWithFrame: NSZeroRect];
    [v->activatedFusion setButtonType: NSButtonTypeSwitch];
    v->sliderFusion = [[NSSlider alloc] initWithFrame: NSZeroRect];
    v->sliderFusion.minValue = 2; v->sliderFusion.maxValue = 20;
    v->stacksFusion = [[NSTextField alloc] initWithFrame: NSZeroRect];
}

// After the step's pool: who keeps the viewer it opened (it releases itself
// when its window closes, so the +1 of its alloc stays).
static void Kept(void) {
    if (harnessNewest) Record([NSString stringWithFormat: @"%@ kept, retain count %lu", Name(harnessNewest), (unsigned long)[harnessNewest retainCount]]);
    harnessNewest = nil;
}

#define RUN(title, ...) do { Record(@"== " title); @autoreleasepool { __VA_ARGS__ } Kept(); } while (0)

static void Reslice(void) {
    struct { const char *name; long w, h, count; int movies; const double (*o)[3]; double sx, sy, interval; } cases[] = {
        {"square", 24, 20, 12, 1, Axial, 0.8, 0.6, 2.5},
        {"square abandoned", 24, 20, 12, 1, Axial, 0.8, 0.6, 0.5},
        {"too wide", 300, 10, 6, 1, Axial, 0.7, 0.7, 1.25},
        {"odd sizes", 25, 21, 13, 1, Coronal, 0.75, 0.5, 1.5},
        {"oblique, negative interval", 18, 16, 10, 1, Oblique, 0.9, 0.9, -3.0},
        {"two time points", 16, 14, 8, 2, Sagittal, 1.0, 0.8, 2.0},
        {"many slices", 12, 10, 102, 1, Axial, 0.5, 0.5, 0.75},
        {"square as tall as the stack", 24, 20, 12, 1, Axial, 1.0, 1.0, 1.05},
    };
    for (size_t c = 0; c < sizeof(cases) / sizeof(cases[0]); c++) {
        for (int direction = 0; direction < 2; direction++) {
            for (int newViewer = 0; newViewer < 2; newViewer++) {
                Record([NSString stringWithFormat: @"== %s, direction %d, new viewer %d", cases[c].name, direction, newViewer]);
                @autoreleasepool {
                    harnessBrushes = (c + direction) % 2;
                    ViewerController *v = Volume(cases[c].w, cases[c].h, cases[c].count, cases[c].movies, cases[c].o, cases[c].sx, cases[c].sy, cases[c].interval, NO);
                    HarnessLength *a = [[HarnessLength new] autorelease], *b = [[HarnessLength new] autorelease];
                    a.label = @"m0 a"; b.label = @"m1 b";
                    v.harnessLengths = @[a, b];
                    BOOL done = [v processReslice: direction :newViewer];
                    Record([NSString stringWithFormat: @"processReslice -> %d", done]);
                    Dump(v);
                    if (newViewer && done) Dump(harnessNewest);
                }
                Kept();
            }
        }
    }
    RUN("replaceSeriesWith", {
        ViewerController *v = Volume(10, 8, 6, 1, Axial, 1, 1, 1, NO);
        ViewerController *w = Volume(6, 4, 5, 1, Coronal, 1, 1, 1, NO);
        [v replaceSeriesWith: w->pixList[0] :w->fileList[0] :w->volumeData[0]];
        Dump(v);
    });
    RUN("copyViewerWindow", {
        ViewerController *v = Volume(10, 8, 6, 2, Sagittal, 0.5, 0.5, 1, NO);
        ViewerController *copy = [v copyViewerWindow];
        Record([NSString stringWithFormat: @"copy %@", Name(copy)]);
        Dump(copy);
    });
    RUN("copyViewerWindow without the second time point", {
        ViewerController *v = Volume(10, 8, 6, 3, Axial, 0.5, 0.5, 1, NO);
        v.harnessCopyFails = YES;
        ViewerController *copy = [v copyViewerWindow];
        Dump(copy);
    });
    RUN("copyViewerWindow of nothing", {
        ViewerController *v = Volume(10, 8, 6, 1, Axial, 0.5, 0.5, 1, NO);
        v->maxMovieIndex = 0;
        Record([NSString stringWithFormat: @"copy %@", Name([v copyViewerWindow])]);
    });
}

static void Transforms(void) {
    const char *names[] = {"vertical flip", "horizontal flip", "rotate 90", "rotate 180", "rotate 270", "square"};
    for (int t = 0; t < 6; t++) {
        for (int c = 0; c < 3; c++) {
            Record([NSString stringWithFormat: @"== %s, volume %d", names[t], c]);
            @autoreleasepool {
                ViewerController *v = c == 0 ? Volume(14, 10, 5, 1, Axial, 0.7, 0.45, 1.5, NO)
                                    : c == 1 ? Volume(9, 12, 4, 2, Oblique, 1.25, 1.25, -2.0, NO)
                                             : Volume(11, 7, 3, 1, Coronal, 0.3, 0.9, 2.5, NO);
                switch (t) {
                    case 0: [v vertFlipDataSet: v]; break;
                    case 1: [v horzFlipDataSet: nil]; break;
                    case 2: [v rotateDataSet: kRotate90DegreesClockwise]; break;
                    case 3: [v rotateDataSet: kRotate180DegreesClockwise]; break;
                    case 4: [v rotateDataSet: kRotate270DegreesClockwise]; break;
                    case 5: [v squareDataSet: nil]; break;
                }
                Dump(v);
            }
        }
    }
    RUN("rotations in a row", {
        ViewerController *v = Volume(13, 9, 4, 1, Oblique, 0.35, 0.8, 1.1, NO);
        [v rotateDataSet: kRotate90DegreesClockwise];
        [v rotateDataSet: kRotate270DegreesClockwise];
        [v horzFlipDataSet: v];
        [v rotateDataSet: kRotate180DegreesClockwise];
        [v vertFlipDataSet: v];
        Dump(v);
    });
}

static void Orientation(void) {
    for (int from = 0; from < 3; from++) {
        for (int to = 0; to < 3; to++) {
            for (int variant = 0; variant < 4; variant++) {
                Record([NSString stringWithFormat: @"== orientation %d to %d, variant %d", from, to, variant]);
                @autoreleasepool {
                    const double (*o)[3] = from == 0 ? Axial : from == 1 ? Coronal : Sagittal;
                    ViewerController *v = Volume(16, 12, 10, variant == 3 ? 2 : 1, o, 0.75, 0.75, 1.5, NO);
                    Panels(v);
                    v->currentOrientationTool = from;
                    [v->orientationMatrix selectCellWithTag: from];
                    [v->imageView setScaleValue: 1.5f];
                    harnessBrushes = variant % 2;
                    if (variant == 1) { v->displayOnlyKeyImages = YES; v->blendingController = [Volume(4, 4, 5, 1, Axial, 1, 1, 1, NO) retain]; }
                    if (variant >= 2) {
                        [v->popFusion selectItemWithTag: 2];
                        v->activatedFusion.state = variant == 2 ? NSControlStateValueOn : NSControlStateValueOff;
                        v->sliderFusion.integerValue = 7;
                    }
                    if (variant == 0) {
                        [v->orientationMatrix selectCellWithTag: to];
                        [v setOrientationTool: v->orientationMatrix];
                    } else {
                        BOOL done = [v setOrientation: to];
                        Record([NSString stringWithFormat: @"setOrientation -> %d", done]);
                    }
                    Dump(v);
                }
            }
        }
    }
    RUN("orientation of non volumic data", {
        ViewerController *v = Volume(16, 12, 10, 1, Axial, 0.75, 0.75, 1.5, NO);
        Panels(v);
        double odd[9] = {0, 1, 0, 0, 0, 1, 0, 0, 0};
        [v->pixList[0][5] setOrientationDouble: odd];
        [v->pixList[0][6] setOrientationDouble: odd];
        [v->orientationMatrix selectCellWithTag: 2];
        [v setOrientationTool: v->orientationMatrix];
        Record([NSString stringWithFormat: @"setOrientation -> %d", [v setOrientation: 1]]);
        Dump(v);
    });
    RUN("orientation tool from a sender without a matrix", {
        ViewerController *v = Volume(16, 12, 10, 1, Axial, 0.75, 0.75, 1.5, NO);
        Panels(v);
        [v setOrientationTool: nil];
        Dump(v);
    });
    RUN("orientation while loading", {
        ViewerController *v = Volume(16, 12, 10, 1, Axial, 0.75, 0.75, 1.5, NO);
        Panels(v);
        v->loadingThread = [NSThread new];
        [v->orientationMatrix selectCellWithTag: 1];
        [v setOrientationTool: v->orientationMatrix];
        Dump(v);
    });
    const double (*orientations[])[3] = {Axial, Coronal, Sagittal, Oblique};
    for (int i = 0; i < 4; i++) {
        for (int sign = 0; sign < 2; sign++) {
            Record([NSString stringWithFormat: @"== computeOriginalOrientation %d, sign %d", i, sign]);
            @autoreleasepool {
                ViewerController *v = Volume(6, 6, 4, 1, orientations[i], 1, 1, sign ? -2.0 : 2.0, NO);
                if (sign) {
                    double o[9]; [v->pixList[0][1] orientationDouble: o];
                    for (int k = 0; k < 3; k++) { o[k] = -o[k]; }
                    for (DCMPix *p in v->pixList[0]) [p setOrientationDouble: o];
                }
                v->originalOrientation = sign ? 1 : -1;
                Record([NSString stringWithFormat: @"interval %a", [v computeOriginalOrientation]]);
                Dump(v);
                double o[9]; [v->pixList[0][2] orientationDouble: o];
                Record([NSString stringWithFormat: @"+orientation: %d", [ViewerController orientation: o]]);
            }
        }
    }
    RUN("computeOriginalOrientation of a tie, of different and of no orientations, of two slices", {
        ViewerController *v = Volume(6, 6, 4, 1, Axial, 1, 1, 2, NO);
        double tie[9] = {0.6, 0.8, 0, -0.8, 0.6, 0, 0, 0, 0};
        double tied[9] = {1, 0, 0, 0, 0.7071067811865476, 0.7071067811865476, 0, 0, 0};
        for (DCMPix *p in v->pixList[0]) [p setOrientationDouble: tied];
        Record([NSString stringWithFormat: @"tie interval %a", [v computeOriginalOrientation]]);
        Dump(v);
        [v->pixList[0][2] setOrientationDouble: tie];
        Record([NSString stringWithFormat: @"different interval %a", [v computeOriginalOrientation]]);
        double zero[9] = {0};
        for (DCMPix *p in v->pixList[0]) { [p setOrientationDouble: zero]; memset(p->orientationValues, 0, sizeof(p->orientationValues)); }
        Record([NSString stringWithFormat: @"zero interval %a", [v computeOriginalOrientation]]);
        [v->pixList[0] removeObjectsInRange: NSMakeRange(0, 2)];
        Record([NSString stringWithFormat: @"two slices interval %a", [v computeOriginalOrientation]]);
        Dump(v);
        double vectors[][9] = {{0,0,0, 0,0,0, 0.1,0.1,0.1}, {0,0,0, 0,0,0, -0.9,0.5,0.1}, {0,0,0, 0,0,0, 0.2,-0.95,0.1}, {0,0,0, 0,0,0, 0.2,0.3,-0.4}, {0,0,0, 0,0,0, 0.5,0.5,-0.4}};
        for (int k = 0; k < 5; k++) Record([NSString stringWithFormat: @"+orientation: %d", [ViewerController orientation: vectors[k]]]);
    });
}

static void Volumic(void) {
    for (int c = 0; c < 20; c++) {
        for (int movie = 0; movie < 2; movie++) {
            Record([NSString stringWithFormat: @"== volumic case %d, movie %d", c, movie]);
            @autoreleasepool {
                BOOL rgb = c == 9 || c == 10;
                ViewerController *v = Volume(8, 6, c == 1 ? 4 : 7, 2, c == 15 ? Oblique : Axial, 0.5, 0.5, 1.5, rgb);
                v->curMovieIndex = movie;
                NSMutableArray *files = v->fileList[movie];
                NSMutableArray *pixes = v->pixList[movie];
                double odd[9] = {0, 1, 0, 0, 0, 1, 0, 0, 0};
                BOOL result = NO, all = NO;
                switch (c) {
                    case 0: break;
                    case 1: break;
                    case 2: files[3][@"width"] = @9; files[4][@"height"] = @5; break;
                    case 3: files[0][@"width"] = @9; break;
                    case 4: files[6][@"height"] = @9; break;
                    case 5: files[6][@"height"] = @9; break;
                    case 6: [pixes[0] setOrientationDouble: odd]; break;
                    case 7: [pixes[6] setOrientationDouble: odd]; break;
                    case 8: [pixes[0] setOrientationDouble: odd]; [pixes[3] setOrientationDouble: odd]; break;
                    case 9: [pixes[0] setOrientationDouble: odd]; break;
                    case 10: [pixes[6] setOrientationDouble: odd]; break;
                    case 11: [v->pixList[1 - movie][0] setOrientationDouble: odd]; all = YES; break;
                    case 12: [pixes[0] setOrientationDouble: odd]; [pixes[6] setOrientationDouble: odd]; break;
                    case 13: v->loadingThread = [NSThread new]; break;
                    case 14: v->loadingThread = [NSThread new]; break;
                    case 15: [pixes[6] setOrientationDouble: odd]; break;
                    case 16: v->isDataVolumicIn4DLevel = 3; [pixes[0] setOrientationDouble: odd]; break;
                    // Just over and just under the tolerance of an orientation value.
                    case 17: { double o[9]; [pixes[3] orientationDouble: o]; o[4] -= 0.005; [pixes[3] setOrientationDouble: o]; break; }
                    case 18: { double o[9]; [pixes[3] orientationDouble: o]; o[4] -= 0.0005; [pixes[3] setOrientationDouble: o]; break; }
                    // A scout before slices far apart: the step to the first is not exact.
                    case 19: {
                        double a[3] = {0.3, 1.1, 0.123}, b[3] = {77.7, 1000.7, 456.789};
                        [pixes[1] setOriginDouble: a]; [pixes[2] setOriginDouble: b]; [pixes[0] setOrientationDouble: odd];
                        break;
                    }
                }
                switch (c) {
                    case 4: result = [v isDataVolumicIn4D: all checkEverythingLoaded: YES tryToCorrect: NO]; break;
                    case 11: result = [v isDataVolumicIn4D: YES]; break;
                    case 12: result = [v isDataVolumic]; break;
                    case 13: result = [v isDataVolumicIn4D: NO checkEverythingLoaded: NO]; break;
                    case 14: result = [v isDataVolumicIn4D: NO checkEverythingLoaded: YES]; break;
                    default: result = [v isDataVolumicIn4D: all]; break;
                }
                Record([NSString stringWithFormat: @"volumic -> %d", result]);
                Dump(v);
            }
        }
    }
}

static void Gantry(void) {
    for (int c = 0; c < 7; c++) {
        Record([NSString stringWithFormat: @"== gantry case %d", c]);
        @autoreleasepool {
            ViewerController *v = Volume(10, 8, c == 5 ? 1 : 7, 1, c == 3 || c == 6 ? Oblique : Axial, 0.6, 0.6, 2.0, NO);
            v->titledGantryDegrees = 12.5f + c;
            harnessReorientFails = c == 2; harnessReorientFailsAt = 2; harnessReorientCalls = 0;
            harnessReorientRaises = c == 4;
            // A tilted gantry: each slice slides along y as it goes along z.
            long z = 0;
            for (DCMPix *p in v->pixList[0]) {
                double origin[3] = {p.originX, p.originY + z * 0.75, p.originZ};
                // Case 6: positions off the tilt, by amounts that are not round.
                if (c == 6) for (int i = 0; i < 3; i++) origin[i] += sin(z * 1.7 + i) * 0.731;
                [p setOriginDouble: origin];
                z++;
            }
            if (c == 1) {
                double odd[9] = {1, 0, 0, 0, 0.9998, 0.02, 0, 0, 0};
                [v->pixList[0][4] setOrientationDouble: odd];
            }
            [ViewerController correctGangtryTilt: v];
            Dump(v);
        }
    }
}

static void Loading(void) {
    for (int c = 0; c < 6; c++) {
        Record([NSString stringWithFormat: @"== loading case %d", c]);
        @autoreleasepool {
            harnessCompressed = c == 1 || c == 2 || c == 3;
            harnessCD = c == 2;
            harnessDICOMRaises = c == 5;
            ViewerController *v = Volume(6, 6, 9, 2, Axial, 1, 1, 1, NO);
            long before = HarnessLoads();
            NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithObjectsAndKeys: v, @"viewerController",
                                         @[v->pixList[0], v->pixList[1]], @"pixListArray", @[v->volumeData[0], v->volumeData[1]], @"volumeDataArray", nil];
            if (c == 3) dict[@"computeOpeningContentBounds"] = @YES;
            NSThread *thread = [[[NSThread alloc] initWithTarget: [ViewerController class] selector: @selector(loadImageData:) object: dict] autorelease];
            if (c == 4) [thread cancel];
            [thread start];
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow: 20];
            harnessDelivered = NO;
            while ((c == 4 ? !thread.isFinished : !harnessDelivered) && deadline.timeIntervalSinceNow > 0)
                if (![[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.05]])
                    [NSThread sleepForTimeInterval: 0.005];
            while (!thread.isFinished && deadline.timeIntervalSinceNow > 0) [NSThread sleepForTimeInterval: 0.01];
            [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 0.05]];
            Record([NSString stringWithFormat: @"finished %d, name %@, loads %ld", thread.isFinished, thread.name, HarnessLoads() - before]);
        }
    }
}

int main(int argc, const char **argv) { @autoreleasepool {
    if (argc != 2) return 2;
    [NSApplication sharedApplication];
    volumes = [NSMutableArray new];
    NSString *scenario = @(argv[1]);
    if ([scenario isEqualToString: @"reslice"]) Reslice();
    else if ([scenario isEqualToString: @"transforms"]) Transforms();
    else if ([scenario isEqualToString: @"orientation"]) Orientation();
    else if ([scenario isEqualToString: @"volumic"]) Volumic();
    else if ([scenario isEqualToString: @"gantry"]) Gantry();
    else if ([scenario isEqualToString: @"loading"]) Loading();
    else return 3;
} return 0; }
'''

# The reference's statics, as ViewerController.m had them.
REFERENCE_PRELUDE = r'''#import "Harness.h"
static float deg2rad = M_PI/180.0;
'''


def git(*arguments):
    return subprocess.run(['git', '-C', str(ROOT), *arguments], capture_output=True)


def read(revision, path):
    """`path` at `revision`, or in the tree for None; None when it is not there."""
    if revision is None:
        file = ROOT / path
        return file.read_bytes() if file.is_file() else None
    shown = git('show', '%s:%s' % (revision, path))
    return shown.stdout if shown.returncode == 0 else None


def module_sources(revision, module):
    """The Swift sources of `module` at `revision` (None: the tree)."""
    base = 'Modules/%s/Sources' % module
    if revision is None:
        return {str(p.relative_to(ROOT / base)): p.read_bytes() for p in sorted((ROOT / base).rglob('*.swift'))}
    listed = git('ls-tree', '-r', '--name-only', revision, base).stdout.decode().split()
    return {p[len(base) + 1:]: read(revision, p) for p in listed if p.endswith('.swift')}


def method_end(text, start):
    """The index after the closing brace of the method at `start` (braces counted)."""
    i = text.index('\n{', start) + 1
    depth = 0
    while True:
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1


GROUPS = [
    ('+ (void) correctGangtryTilt: (ViewerController*) viewerController', MARK),
    ('+ (int) orientation:(double*) vectors', '- (BOOL) setOrientation: (int) newOrientationTool'),
    ('- (BOOL) isDataVolumic\n', '- (BOOL) isDataVolumicIn4D: (BOOL) check4D\n'),
    ('- (ViewerController*) copyViewerWindow', '+ (void) loadImageData:(id) dict'),
]
SHIM = '- (ViewerController*) copyViewerWindow'


def objc_blocks(text):
    """The series operations of ViewerController.m, in a category of the stand-in."""
    parts = []
    for first, last in GROUPS:
        a = text.index(first)
        b = method_end(text, text.index(last, a))
        parts.append(text[a:b])
    return REFERENCE_PRELUDE + '@implementation ViewerController (SeriesOperations)\n' + '\n'.join(parts) + '\n@end\n'


def objc_shim(text):
    """What ViewerController.m keeps of these methods once they are in Swift."""
    a = text.index(SHIM)
    return '#import "Harness.h"\n@implementation ViewerController (SeriesOperations)\n' + text[a:method_end(text, a)] + '\n@end\n'


reference = args.reference
if reference is None:
    head = read('HEAD', VC)
    reference = 'HEAD' if head and MARK.encode() in head else history_reference.before_text_removed(VC, MARK)
if reference is None:
    print('skipped: needs the history that has the Objective-C ViewerController.m (a shallow clone does not)')
    sys.exit(2)
reference_vc = read(reference, VC)
if reference_vc is None or MARK.encode() not in reference_vc:
    sys.exit('FAIL: %s has no Objective-C reslice in %s' % (reference, VC))
reference_vc = reference_vc.decode('latin1')
current_vc = (read(args.current, VC) or b'').decode('latin1')  # empty once ViewerController.m is gone
current_is_objc = MARK in current_vc


def run(command, what, cwd=None, keep_errors=False):
    built = subprocess.run(command, capture_output=True, text=True, cwd=cwd)
    if built.returncode:
        output = built.stdout + built.stderr
        if keep_errors:
            output = '\n'.join(line for line in output.splitlines() if ' error: ' in line) or output
        sys.exit('FAIL: %s:\n%s' % (what, output[-6000:]))


with tempfile.TemporaryDirectory(prefix='horos-viewer-series-') as tmp:
    folder = Path(tmp)
    (folder / 'Harness.h').write_text(HEADER)
    (folder / 'Stubs.m').write_text(STUBS.replace('IVAR_IMPLEMENTATIONS', IMPLEMENTED))
    (folder / 'Driver.m').write_text(DRIVER)
    for name in ('HorosObjCException.h', 'HorosObjCException.m'):
        (folder / name).write_bytes((ROOT / 'Horos/Sources' / name).read_bytes())
    frameworks = ['-framework', 'Cocoa', '-framework', 'Accelerate']

    def clang(source, arc=False):
        target = folder / (Path(source).parent.name + '-' + Path(source).stem + '.o')
        run(['xcrun', 'clang', '-c', '-fobjc-arc' if arc else '-fno-objc-arc', '-fblocks', '-fmodules', '-w', '-I', str(folder), str(source), '-o', str(target)],
            '%s does not compile' % Path(source).name)
        return str(target)

    common = [clang(folder / 'Stubs.m'), clang(folder / 'Driver.m'), clang(folder / 'HorosObjCException.m', arc=True)]

    def objc_program(name, vc_text):
        work = folder / name
        work.mkdir()
        source = work / 'Blocks.m'
        # ViewerController.m is read as Latin-1: its bytes are written back as they were.
        source.write_bytes(objc_blocks(vc_text).encode('latin1'))
        blocks = clang(source)
        program = folder / ('%s-program' % name)
        run(['xcrun', 'clang', *common, blocks, *frameworks, '-o', str(program)], '%s does not link' % name)
        return program

    reference_program = objc_program('reference', reference_vc)
    if current_is_objc:
        current_program = objc_program('current', current_vc)
        current_label = 'Objective-C of %s' % (args.current or 'the tree')
    else:
        swift = folder / 'swift'
        swift.mkdir()
        shim = swift / 'Shim.m'
        # Once ViewerController.m is gone, the shim's methods are in ViewerController+CAPI.m.
        shim_source = current_vc or (read(args.current, 'Horos/Sources/ViewerController+CAPI.m') or b'').decode('latin1')
        shim.write_bytes(objc_shim(shim_source).encode('latin1'))
        sources = []
        for name in SWIFT_FILES:
            text = read(args.current, 'Horos/Sources/' + name)
            if text is None:
                sys.exit('FAIL: no Horos/Sources/%s' % name)
            (swift / name).write_bytes(text)
            sources.append(str(swift / name))
        # [sender tag] as the blocks send it, and the @try of the blocks.
        support = read(args.current, 'Horos/Sources/ViewerController+ImagePipelineSupport.swift').decode('utf-8')
        sender = re.search(r'\nenum ViewerSender \{.*?\n}\n', support, re.S).group(0)
        attempt = re.search(r'\n/// Runs `body` as an @try block.*?\nfunc viewerObjCTry.*?\n}\n', support, re.S).group(0)
        (swift / 'Helpers.swift').write_text('import AppKit\n' + sender + attempt)
        sources.append(str(swift / 'Helpers.swift'))
        libraries = []
        for module in MODULES:
            directory = folder / module
            found = module_sources(args.current, module)
            if not found:
                continue  # a module the revision does not have yet
            directory.mkdir()
            for relative, text in found.items():
                (directory / relative.replace('/', '_')).write_bytes(text)
            run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-module-name', module, *libraries,
                 '-emit-library', '-static', '-emit-module', '-emit-module-path', str(directory / (module + '.swiftmodule')),
                 '-o', str(directory / ('lib%s.a' % module)), *map(str, sorted(directory.glob('*.swift')))],
                '%s does not compile' % module, cwd=directory)
            libraries += ['-I', str(directory), '-L', str(directory), '-l' + module]
        current_program = folder / 'current-program'
        run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', *libraries, '-Xcc', '-DHARNESS_SWIFT', '-import-objc-header', str(folder / 'Harness.h'),
             *sources, clang(shim), *common, *frameworks, '-o', str(current_program)],
            'the Swift blocks do not compile against the stand-ins', keep_errors=True)
        current_label = 'Swift of %s' % (args.current or 'the tree')

    if args.dump:
        args.dump.mkdir(parents=True, exist_ok=True)
        for program in (reference_program, current_program):
            (args.dump / program.name).write_bytes(program.read_bytes())
            (args.dump / program.name).chmod(0o755)
    failures = 0
    for scenario in SCENARIOS:
        results = {}
        for label, program in (('reference', reference_program), ('current', current_program)):
            try:
                result = subprocess.run([str(program), scenario], capture_output=True, text=True, timeout=60)
            except subprocess.TimeoutExpired:
                sys.exit('FAIL: %s %s did not end in 60 s' % (label, scenario))
            if result.returncode:
                sys.exit('FAIL: %s %s stopped (%d):\n%s' % (label, scenario, result.returncode, (result.stdout + result.stderr)[-3000:]))
            results[label] = result.stdout
        if args.dump:
            for label, text in results.items():
                (args.dump / ('%s-%s.txt' % (scenario, label))).write_text(text)
        expected, got = results['reference'].splitlines(), results['current'].splitlines()
        if expected == got:
            print('%s: %d records identical (%s against the Objective-C of %s)' % (scenario, len(expected), current_label, reference))
        else:
            failures += 1
            print('FAIL: %s differs (%s against the Objective-C of %s):' % (scenario, current_label, reference))
            for line in list(difflib.unified_diff(expected, got, 'reference', 'current', lineterm='', n=1))[:60]:
                print('  ' + line)
    if failures:
        sys.exit(1)
    print('PASS: the reslice, flips, rotations, orientation tool, gantry tilt correction, volumic checks and loading of the series are identical to the Objective-C in every scenario')
