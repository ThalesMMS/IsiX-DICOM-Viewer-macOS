#!/usr/bin/env python3
"""The 2D viewer's image pipeline gives what its former Objective-C gave.

ViewerController's "DICOM pipeline" (filters, resampling, mask subtraction,
window level and slice interval, colour and opacity tables) and "Composition of
various images" (thick slab) blocks moved from ViewerController.m to Swift
extensions of the class, with their arithmetic in the IsiXImaging module. This
runs the same scenarios through both and compares everything they produce:

* the resampled series: every new slice's size, numbering, pixel spacing,
  thickness, ratio and origin (bit for bit), the file each takes, and the bytes
  of the new volume (float and RGB, XY and Z passes, oblique stacks);
* the slice interval: +computeIntervalForDCMPix:And:, -computeIntervalFlipNow:
  over ascending, descending (reversed: the volume's bytes, the slices', files'
  and ROIs' order), tilted, unpositioned, mixed-size and 4D stacks, the
  orientation and its tool, -flipData:::: on both of its paths, the slice
  interval sheet and its normal;
* the mask subtraction: the mask each image gets, the range, the pixel shift
  and its indicator, the sliders, the stack sum and the sharpen filter;
* the window level: the presets, the "Set WL/WW" sheet, the RGB and black and
  white conversions;
* the colour tables: the bytes of every CLUT handed to the view and the thick
  slab, the black index of each slice, the PET blending case, the stored
  presets (the persisted dictionary) of the CLUT and opacity editors, and the
  opacity tables of the slices;
* the thick slab: the fusion mode and slices handed to every view and slice,
  the volume rendering's ThickSlabController, the steps of the scroll wheel.

The reference is the Objective-C of ViewerController.m in the last revision
that has it (history_reference), compiled with clang as Xcode compiles it; the
other side is the current tree: the Swift files with the IsiXImaging module,
compiled with swiftc, or the Objective-C again if the tree still has it (which
is how this test ran, and passed, before the conversion). Both run over the
same stand-ins of DCMPix, DCMView and the viewer's controls, which record what
they are given; the two records must be identical.

    python3 tests/test-viewer-image-pipeline-equivalence.py [--reference REV] [--current REV]

--current REV takes the other side from a revision instead of the tree (a
revision with the Objective-C, before the conversion, gives an Objective-C
against Objective-C run).
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
MARK = '+ (BOOL)resampleDataFromPixArray:'
SWIFT_FILES = ['ViewerController+%s.swift' % name for name in
               ('ImagePipelineSupport', 'Resampling', 'MaskSubtraction', 'WindowLevel', 'SliceInterval', 'ColorTables', 'ThickSlab')]

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--reference')
parser.add_argument('--current')
parser.add_argument('--dump', type=Path, help='write the records of both programs to this folder')
args = parser.parse_args()


def git(*command):
    return subprocess.run(['git', '-C', str(ROOT), *command], capture_output=True)


def read(revision, path):
    """`path` at `revision`, or in the tree for None; None when it is not there."""
    if revision is None:
        file = ROOT / path
        return file.read_bytes() if file.is_file() else None
    shown = git('show', '%s:%s' % (revision, path))
    return shown.stdout if shown.returncode == 0 else None


def module_sources(revision, name='IsiXImaging'):
    """The Swift sources of module `name` at `revision` (None: the tree)."""
    base = 'Modules/%s/Sources' % name
    if revision is None:
        return {p.name: p.read_bytes() for p in sorted((ROOT / base).rglob('*.swift'))}
    listed = git('ls-tree', '-r', '--name-only', revision, base).stdout.decode().split()
    return {Path(p).name: read(revision, p) for p in listed if p.endswith('.swift')}


reference = args.reference
if reference is None:
    head = read('HEAD', VC)
    reference = 'HEAD' if head and MARK.encode() in head else history_reference.before_text_removed(VC, MARK)
if reference is None:
    print('skipped: needs the history that has the Objective-C ViewerController.m (a shallow clone does not)')
    sys.exit(2)
reference_vc = read(reference, VC)
if reference_vc is None or MARK.encode() not in reference_vc:
    sys.exit('FAIL: %s has no Objective-C image pipeline in %s' % (reference, VC))
reference_vc = reference_vc.decode('latin1')
current_vc = (read(args.current, VC) or b'').decode('latin1')  # empty once ViewerController.m is gone
current_is_objc = MARK in current_vc


def region(text):
    """The DICOM pipeline and composition blocks of ViewerController.m."""
    start = text.index('#pragma mark 4.1.1. DICOM pipeline')
    return text[start:text.index('#pragma mark 4.1.3 Anchored graphical layer')]


def function(text, signature):
    start = text.index(signature)
    return text[start:text.index('\n}\n', start) + 3]


# What the Swift extensions read of the viewer: the accessors of
# ViewerController+SwiftIvars.h, declared on the stand-in as the header
# declares them, over instance variables of the same names.
# A revision from before the conversion lacks some of them: the tree's header
# completes it (the Objective-C reads the instance variables only).
# Since the class is Swift the header is gone: the accessors keep its Swift
# names and semantics, so its last revision describes them.
IVARS_PATH = 'Horos/Sources/ViewerController+SwiftIvars.h'
last_ivars = read(history_reference.before_removal(IVARS_PATH), IVARS_PATH) if not (ROOT / IVARS_PATH).exists() else None
ivars_header = (read(args.current, IVARS_PATH) or last_ivars or b'').decode('utf-8') + '\n' + \
    ((ROOT / IVARS_PATH).read_bytes() if (ROOT / IVARS_PATH).exists() else last_ivars or b'').decode('utf-8')
IVARS = '''imageView seriesView curMovieIndex maxMovieIndex orientationVector currentOrientationTool originalOrientation
postprocessed resampleRatio enableSubtraction subCtrlOnOff subCtrlView subCtrlMaskID subCtrlMinMax subCtrlMaskText
subCtrlOffset sc1 sc2 sc3 sc4 sc5 sc6 sc7 sc8 sc9 subCtrlSum subCtrlPercent subCtrlSharpenButton stacksFusion
sliderFusion activatedFusion popFusion curWLWWMenu curCLUTMenu backCurCLUTMenu curOpacityMenu wlwwPopup clutPopup
OpacityPopup windowWillClose titledGantry titledGantryDegrees orientationMatrix blendingController blendedWindow
nonVolumicDataWarningDisplayed computeInterval ThickIntervalWindow customInterval customXSpacing customYSpacing
customVectors customOrigin setWLWWWindow wlset wwset fromset toset addCLUTWindow clutName clutView addOpacityWindow
OpacityName OpacityView thickSlab'''.split()
declarations, ivar_lines, implementations = [], [], []
for name in IVARS:
    found = re.search(r'^@property\(([^)]*)\)\s*(.+?)\s*\bhoros_%s(?: NS_SWIFT_NONISOLATED)?;$' % re.escape(name), ivars_header, re.M)
    if not found:
        sys.exit('FAIL: ViewerController+SwiftIvars.h declares no horos_%s' % name)
    attributes, kind = found.group(1), found.group(2).strip()
    declarations.append(found.group(0))
    ivar_lines.append('    %s %s;' % (kind, name))
    implementations.append('- (%s)horos_%s { return %s; }' % (kind, name, name))
    if 'readonly' not in attributes:
        setter = 'setHoros_%s' % name
        if 'retain' in attributes:
            implementations.append('- (void)%s:(%s)value { [value retain]; [%s release]; %s = value; }' % (setter, kind, name, name))
            assign = 'horos_assign%s%s' % (name[0].upper(), name[1:])
            found = re.search(r'^- \(void\)%s:\(nullable [^)]*\)value;$' % assign, ivars_header, re.M)
            if found:
                declarations.append(found.group(0))
                implementations.append('- (void)%s:(%s)value { %s = value; }' % (assign, kind, name))
        else:
            implementations.append('- (void)%s:(%s)value { %s = value; }' % (setter, kind, name))
for name in ('fileList', 'pixList', 'roiList'):
    found = re.search(r'^- \((nullable [^)]*)\)horos_%sAt:\(NSInteger\)index(?: NS_SWIFT_NONISOLATED)?;$' % name, ivars_header, re.M)
    declarations.append(found.group(0))
    implementations.append('- (%s)horos_%sAt:(NSInteger)index { return %s[index]; }' % (found.group(1).replace('nullable ', ''), name, name))

STUBS_H = r'''
#pragma clang diagnostic ignored "-Wnullability-completeness"
#import <Cocoa/Cocoa.h>
#import <Accelerate/Accelerate.h>
#import "HorosObjCException.h"
#import "HorosAlertPanel.h"
#import "HorosCalibration.h"

#define MAX4D 500
#define ORIENTATION_SENSIBILITY 0.001
enum { eSagittalPos = 0, eSagittalNeg, eCoronalPos, eCoronalNeg, eAxialPos, eAxialNeg };

extern NSString* const OsirixRecomputeROINotification;
extern NSString* const OsirixUpdateWLWWMenuNotification;
extern NSString* const OsirixUpdateCLUTMenuNotification;
extern NSString* const OsirixUpdateOpacityMenuNotification;
extern NSString* const OsirixDCMUpdateCurrentImageNotification;

void RecordLine(NSString *line);
NSString *BitsF(float value);
NSString *BitsD(double value);
NSString *HashBytes(const void *bytes, long length);
NSString *DescribePointer(const void *pointer);
NSString *ListName(id list);
void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf);
#define N2LogExceptionWithStackTrace(e, ...) _N2LogExceptionImpl(e, YES, __PRETTY_FUNCTION__)

@class ViewerController, DCMPix, ThickSlabController, OpacityTransferView;

@interface ROI : NSObject <NSCopying>
@property(copy) NSString *name;
- (void) setOriginAndSpacing :(float) ipixelSpacingx :(float) ipixelSpacingy :(NSPoint) iimageOrigin;
@end

@interface DCMPix : NSObject <NSCopying> {
@public
    long pwidth, pheight, Tot, frameNo, ID, maskIDValue;
    float *fImage;
    BOOL isRGB;
    double sliceInterval, sliceThickness, spacingBetweenSlices, sliceLocation, originX, originY, originZ, pixelSpacingX, pixelSpacingY, pixelRatio;
    float orientationValues[9], savedWL, savedWW, fImageTimeValue, maskTimeValue;
    NSPoint subPixOffset;
}
@property(copy) NSString *name;
@property (nonatomic) long pwidth, pheight;
@property(setter=setfImage:) float* fImage;
@property(nonatomic, setter=setRGB:) BOOL isRGB;
@property(nonatomic) double pixelRatio;
@property double pixelSpacingX, pixelSpacingY;
@property double sliceThickness;
@property double sliceInterval;
@property double spacingBetweenSlices;
@property(readonly) double originX, originY, originZ;
@property(nonatomic) NSPoint subPixOffset;
@property(getter=Tot, setter=setTot:) long Tot;
@property long frameNo;
@property(setter=setID:) long ID;
@property(nonatomic) float savedWW, savedWL;
@property(nonatomic, retain) NSData *transferFunction;
- (void)orientation:(float*) c;
- (void)setOrientation:(float*) c;
- (void)orientationDouble:(double*) c;
- (void)setOrigin :(float*) o;
- (void) computeSliceLocation;
- (void) setArrayPix :(NSArray*) array :(NSInteger) i;
+ (NSPoint) originCorrectedAccordingToOrientation: (DCMPix*) pix1;
- (void) setBlackIndex:(int) i;
- (void) setThickSlabController:( ThickSlabController*) ts;
- (void) setFusion:(short) m :(short) s :(short) direction;
- (void) setSubtractedfImage:(float*)mask :(NSPoint)smm;
- (NSPoint) subMinMax:(float*)input :(float*)subfImage;
- (void) fImageTime:(float)newTime;
- (float) fImageTime;
- (void) maskID:(long)newID;
- (long) maskID;
- (void) maskTime:(float)newMaskTime;
- (float) maskTime;
- (void) setSubSlidersPercent: (float) p;
- (void) ConvertToBW:(long) mode;
- (void) ConvertToRGB:(long) mode :(long) cwl :(long) cww;
@end

@interface DCMView : NSView {
@public
    NSMutableArray *dcmPixList;
    NSInteger curImage;
    float wl, ww, scaleValue, rotation;
    unsigned char clutRed[256], clutGreen[256], clutBlue[256];
    BOOL hasCLUT;
    short fusionStacks;
}
@property BOOL flippedData;
@property(nonatomic) BOOL whiteBackground;
@property(readonly) NSMutableArray *dcmPixList;
@property(readonly) NSInteger curImage;
@property(nonatomic) float scaleValue, rotation;
@property(readonly, strong) DCMPix *curDCM;
@property BOOL drawing;
@property NSPoint origin;
- (void) setIndex:(NSInteger) index;
- (void) setWLWW:(float) wl :(float) ww;
- (void) getWLWW:(float*) wl :(float*) ww;
- (void) setFusion:(short) mode :(short) stacks;
- (void) setCLUT:(unsigned char*) r :(unsigned char*) g :(unsigned char*) b;
- (void) getCLUT:(unsigned char**) r :(unsigned char**) g :(unsigned char**) b;
- (void) loadTextures;
- (void) scaleToFit;
- (void) updateTilingViews;
- (void) roiSet;
- (void) stopROIEditingForce:(BOOL) force;
- (void) sendSyncMessage:(NSInteger) inc;
- (void) getThickSlabThickness:(float*) thickness location:(float*) location;
+ (double) angleBetweenVectorD:(double*) v1 andVectorD:(double*) v2;
+ (void) computePETBlendingCLUT;
@end

@interface SeriesView : NSView
- (NSMutableArray*) imageViews;
- (void) setFlippedData:(BOOL) value;
@end

@interface ColorTransferView : NSView
- (NSMutableArray*) getPoints;
- (NSMutableArray*) getColors;
- (void) ConvertCLUT:(unsigned char*) red :(unsigned char*) green :(unsigned char*) blue NS_SWIFT_NAME(convertCLUT(_:_:_:));
@end

@interface PluginManager : NSObject
+ (NSMutableDictionary*) plugins;
+ (void) startProtectForCrashWithFilter:(id) filter;
+ (void) endProtectForCrash;
@end

@interface AppController : NSObject
+ (BOOL) willExecutePlugin:(id) filter;
@end

NS_SWIFT_NAME(WindowLevelText)
@interface HorosWindowLevelText : NSObject
+ (NSString*) stringForValue:(double) value NS_SWIFT_NAME(string(for:));
+ (double) valueFromString:(NSString*) text fallback:(double) fallback NS_SWIFT_NAME(value(from:fallback:));
+ (double) widthFromString:(NSString*) text fallback:(double) fallback NS_SWIFT_NAME(width(from:fallback:));
@end

NS_SWIFT_NAME(GantryTiltPolicy)
@interface HorosGantryTiltPolicy : NSObject
+ (BOOL) shouldCorrectTiltOfDegrees:(float) degrees NS_SWIFT_NAME(shouldCorrect(degrees:));
@end

NS_SWIFT_NAME(SliceIntervalRegularity)
@interface HorosSliceIntervalRegularity : NSObject
@property(readonly) double minimumInterval, maximumInterval;
@property(readonly) BOOL isIrregular;
+ (HorosSliceIntervalRegularity* _Nonnull) regularityOfOrigins:(NSArray<NSNumber*>* _Nonnull) origins normal:(NSArray<NSNumber*>* _Nonnull) normal pixelSpacing:(double) spacing NS_SWIFT_NAME(regularity(origins:normal:pixelSpacing:));
@end

@interface NSObject (HarnessFilter)
- (long) prepareFilter:(id) viewer;
- (long) filterImage:(NSString*) name;
@end

@interface NSWindow (HarnessSheet)
- (void) orderOutAndEndSheetWithReturnCode:(NSModalResponse) code NS_SWIFT_NAME(orderOutAndEndSheet(returnCode:));
@end

@interface ViewerController : NSWindowController {
@public
IVARS
    NSMutableArray *fileList[MAX4D];
    NSMutableArray<DCMPix *> *pixList[MAX4D];
    NSMutableArray<NSMutableArray<ROI *> *> *roiList[MAX4D];
    NSConditionLock *flipDataThread;
}
- (void) checkEverythingLoaded;
- (BOOL) isEverythingLoaded;
- (void) computeSubCtrlMinMax;
- (NSString *) subtractionUnavailableReason;
- (void)checkView:(NSView *)aView :(BOOL) OnOff;
- (void) setWindowTitle:(id) sender;
- (void) adjustSlider;
- (void) propagateSettings;
- (IBAction) updateImage:(id) sender;
- (void) selectFirstTilingView;
- (void) setUpdateTilingViewsValue:(BOOL) v;
- (BOOL) isDataVolumicIn4D:(BOOL) check4D;
- (void) changeImageData:(NSMutableArray*)f :(NSMutableArray*)d :(NSData*) v :(BOOL) applyTransition;
- (void) addMovieSerie:(NSMutableArray*)f :(NSMutableArray*)d :(NSData*) v;
- (void) setPostprocessed:(BOOL) v;
- (id) startWaitWindow :(NSString*) message;
- (void) endWaitWindow:(id) waitWindow;
- (void) horosLoadViewerPanels;
- (void) ApplyConvString:(NSString*) str;
- (NSMutableArray*) pixList: (long) i;
- (NSMutableArray*) fileList: (long) i;
+ (NSMutableArray*) getDisplayed2DViewers;
+ (void) correctGangtryTilt: (ViewerController*) viewerController;
- (IBAction) mprViewer:(id) sender;
- (IBAction) cprViewer:(id) sender;
- (IBAction) orthogonalMPRViewer:(id) sender;
- (IBAction) VRViewer:(id) sender;
- (IBAction) SRViewer:(id) sender;
- (IBAction) endoscopyViewer:(id) sender;
@end

@interface ViewerController (SwiftIvars)
DECLARATIONS
@end
'''.replace('IVARS', '\n'.join(ivar_lines)).replace('DECLARATIONS', '\n'.join(declarations))

STUBS_M = r'''
#import "stubs.h"
#include <stdarg.h>

NSString* const OsirixRecomputeROINotification = @"OsirixRecomputeROINotification";
NSString* const OsirixUpdateWLWWMenuNotification = @"OsirixUpdateWLWWMenuNotification";
NSString* const OsirixUpdateCLUTMenuNotification = @"OsirixUpdateCLUTMenuNotification";
NSString* const OsirixUpdateOpacityMenuNotification = @"OsirixUpdateOpacityMenuNotification";
NSString* const OsirixDCMUpdateCurrentImageNotification = @"OsirixDCMUpdateCurrentImageNotification";

static NSMutableArray *buffers;   // [name, base, length in bytes]

void RecordLine(NSString *line) { printf("%s\n", line.UTF8String); }
NSString *BitsF(float value) { return [NSString stringWithFormat:@"%a", value]; }
NSString *BitsD(double value) { return [NSString stringWithFormat:@"%a", value]; }
NSString *HashBytes(const void *bytes, long length)
{
    if (!bytes) return @"null";
    uint64_t h = 1469598103934665603ULL;
    for (long i = 0; i < length; i++) { h ^= ((const unsigned char *)bytes)[i]; h *= 1099511628211ULL; }
    return [NSString stringWithFormat:@"%016llx/%ld", h, length];
}
void RegisterBuffer(NSString *name, const void *base, long length)
{
    if (!buffers) buffers = [NSMutableArray new];
    [buffers addObject:@[name, [NSValue valueWithPointer:base], @(length)]];
}
NSString *DescribePointer(const void *pointer)
{
    if (!pointer) return @"null";
    for (NSArray *b in buffers.reverseObjectEnumerator) {
        const char *base = [b[1] pointerValue];
        if ((const char *)pointer >= base && (const char *)pointer < base + [b[2] longValue])
            return [NSString stringWithFormat:@"%@+%ld", b[0], (long)(((const char *)pointer - base) / 4)];
    }
    return @"unknown";
}
NSString *ListName(id list)
{
    // An array by identity, named in the order it is first seen: the same in
    // both programs when they hand the same arrays around. Kept, so that no
    // later array takes the address of one seen before.
    static NSMutableArray *seen;
    if (!list) return @"nil";
    if (!seen) seen = [NSMutableArray new];
    for (NSUInteger i = 0; i < seen.count; i++) if (seen[i] == list) return [NSString stringWithFormat:@"list%lu", (unsigned long)i];
    [seen addObject:list];
    return [NSString stringWithFormat:@"list%lu", (unsigned long)(seen.count - 1)];
}
void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf) { RecordLine([NSString stringWithFormat:@"exception %@", e.name]); }

static NSString *Alert(NSString *kind, NSString *title, NSString *message)
{
    RecordLine([NSString stringWithFormat:@"alert %@ [%@] %@", kind, title, message]);
    return nil;
}
NSInteger HorosRunAlertPanel(NSString *title, NSString *format, NSString *d, NSString *a, NSString *o, ...)
{ va_list v; va_start(v, o); NSString *m = [[[NSString alloc] initWithFormat:format arguments:v] autorelease]; va_end(v); Alert(@"run", title, m); return 1; }
NSInteger HorosRunInformationalAlertPanel(NSString *title, NSString *format, NSString *d, NSString *a, NSString *o, ...)
{ va_list v; va_start(v, o); NSString *m = [[[NSString alloc] initWithFormat:format arguments:v] autorelease]; va_end(v); Alert(@"informational", title, m); return 1; }
NSInteger HorosRunCriticalAlertPanel(NSString *title, NSString *format, NSString *d, NSString *a, NSString *o, ...)
{ va_list v; va_start(v, o); NSString *m = [[[NSString alloc] initWithFormat:format arguments:v] autorelease]; va_end(v); Alert(@"critical", title, m); return 1; }

@implementation HorosAlertPanel
+ (NSInteger)runWithTitle:(NSString *)title message:(NSString *)message defaultButton:(NSString *)d alternateButton:(NSString *)a otherButton:(NSString *)o
{ Alert(@"run", title, message); return 1; }
+ (NSInteger)runInformationalWithTitle:(NSString *)title message:(NSString *)message defaultButton:(NSString *)d alternateButton:(NSString *)a otherButton:(NSString *)o
{ Alert(@"informational", title, message); return 1; }
+ (NSInteger)runCriticalWithTitle:(NSString *)title message:(NSString *)message defaultButton:(NSString *)d alternateButton:(NSString *)a otherButton:(NSString *)o
{ Alert(@"critical", title, message); return 1; }
+ (void)beginWithTitle:(NSString *)title message:(NSString *)message defaultButton:(NSString *)d alternateButton:(NSString *)a otherButton:(NSString *)o modalForWindow:(NSWindow *)window completionHandler:(void (^)(NSInteger))completion
{ Alert(@"sheet", title, message); if (completion) completion(1); }
@end

CALIBRATION

@implementation ROI
- (id)copyWithZone:(NSZone *)zone { ROI *r = [ROI new]; r.name = self.name; return r; }
- (void) setOriginAndSpacing :(float) x :(float) y :(NSPoint) o
{ RecordLine([NSString stringWithFormat:@"roi %@ spacing %@ %@ origin %@ %@", self.name, BitsF(x), BitsF(y), BitsD(o.x), BitsD(o.y)]); }
- (void)dealloc { [_name release]; [super dealloc]; }
@end

@implementation DCMPix
@synthesize pwidth, pheight, fImage, isRGB, pixelRatio, pixelSpacingX, pixelSpacingY, sliceThickness, sliceInterval, spacingBetweenSlices;
@synthesize originX, originY, originZ, subPixOffset, Tot, frameNo, ID, savedWW, savedWL;
- (id)copyWithZone:(NSZone *)zone
{
    DCMPix *p = [DCMPix new];
    p.name = self.name;
    p->pwidth = pwidth; p->pheight = pheight; p->fImage = fImage; p->isRGB = isRGB;
    p->sliceInterval = sliceInterval; p->sliceThickness = sliceThickness; p->spacingBetweenSlices = spacingBetweenSlices;
    p->originX = originX; p->originY = originY; p->originZ = originZ;
    p->pixelSpacingX = pixelSpacingX; p->pixelSpacingY = pixelSpacingY; p->pixelRatio = pixelRatio;
    memcpy(p->orientationValues, orientationValues, sizeof orientationValues);
    p->Tot = Tot; p->frameNo = frameNo; p->ID = ID; p->savedWL = savedWL; p->savedWW = savedWW;
    return p;
}
- (void)dealloc { [_name release]; [_transferFunction release]; [super dealloc]; }
- (void)orientation:(float*) c { memcpy(c, orientationValues, sizeof orientationValues); }
- (void)orientationDouble:(double*) c { for (int i = 0; i < 9; i++) c[i] = orientationValues[i]; }
- (void)setOrientation:(float*) c
{ memcpy(orientationValues, c, sizeof orientationValues);
  NSMutableString *s = [NSMutableString string]; for (int i = 0; i < 9; i++) [s appendFormat:@" %@", BitsF(c[i])];
  RecordLine([NSString stringWithFormat:@"pix %@ setOrientation%@", self.name, s]); }
- (void)setOrigin:(float*) o
{ originX = o[0]; originY = o[1]; originZ = o[2];
  RecordLine([NSString stringWithFormat:@"pix %@ setOrigin %@ %@ %@", self.name, BitsF(o[0]), BitsF(o[1]), BitsF(o[2])]); }
- (void) computeSliceLocation { sliceLocation = originZ; RecordLine([NSString stringWithFormat:@"pix %@ computeSliceLocation", self.name]); }
- (void) setArrayPix :(NSArray*) array :(NSInteger) i
{ RecordLine([NSString stringWithFormat:@"pix %@ setArrayPix %@ %ld", self.name, ListName(array), (long)i]); }
+ (NSPoint) originCorrectedAccordingToOrientation: (DCMPix*) p { return NSMakePoint(p.originX, p.originY); }
- (void) setBlackIndex:(int) i { RecordLine([NSString stringWithFormat:@"pix %@ setBlackIndex %d", self.name, i]); }
- (void) setThickSlabController:(ThickSlabController*) ts { RecordLine([NSString stringWithFormat:@"pix %@ setThickSlabController %@", self.name, ts ? @"set" : @"nil"]); }
- (void) setFusion:(short) m :(short) s :(short) d { RecordLine([NSString stringWithFormat:@"pix %@ setFusion %d %d %d", self.name, m, s, d]); }
- (void) setSubtractedfImage:(float*)mask :(NSPoint)smm
{ RecordLine([NSString stringWithFormat:@"pix %@ setSubtractedfImage %@ %@ %@", self.name, DescribePointer(mask), BitsD(smm.x), BitsD(smm.y)]); }
- (NSPoint) subMinMax:(float*)input :(float*)sub
{
    float lo = INFINITY, hi = -INFINITY;
    for (long i = 0; i < pwidth * pheight; i++) { float d = input[i] - sub[i]; if (d < lo) lo = d; if (d > hi) hi = d; }
    return NSMakePoint(lo, hi);
}
- (void) fImageTime:(float)t { fImageTimeValue = t; }
- (float) fImageTime { return fImageTimeValue; }
- (void) maskID:(long)i { maskIDValue = i; RecordLine([NSString stringWithFormat:@"pix %@ maskID %ld", self.name, i]); }
- (long) maskID { return maskIDValue; }
- (void) maskTime:(float)t { maskTimeValue = t; RecordLine([NSString stringWithFormat:@"pix %@ maskTime %@", self.name, BitsF(t)]); }
- (float) maskTime { return maskTimeValue; }
- (void) setSubPixOffset:(NSPoint)o { subPixOffset = o; RecordLine([NSString stringWithFormat:@"pix %@ setSubPixOffset %@ %@", self.name, BitsD(o.x), BitsD(o.y)]); }
- (void) setSubSlidersPercent: (float) p { RecordLine([NSString stringWithFormat:@"pix %@ setSubSlidersPercent %@", self.name, BitsF(p)]); }
- (void) ConvertToBW:(long) mode { isRGB = NO; RecordLine([NSString stringWithFormat:@"pix %@ ConvertToBW %ld", self.name, mode]); }
- (void) ConvertToRGB:(long) mode :(long) cwl :(long) cww { isRGB = YES; RecordLine([NSString stringWithFormat:@"pix %@ ConvertToRGB %ld %ld %ld", self.name, mode, cwl, cww]); }
- (void) setTransferFunction:(NSData *)tf
{ [tf retain]; [_transferFunction release]; _transferFunction = tf;
  RecordLine([NSString stringWithFormat:@"pix %@ setTransferFunction %@", self.name, HashBytes(tf.bytes, tf.length)]); }
- (void) setSliceInterval:(double)v { sliceInterval = v; RecordLine([NSString stringWithFormat:@"pix %@ setSliceInterval %@", self.name, BitsD(v)]); }
- (void) setfImage:(float *)p { fImage = p; RecordLine([NSString stringWithFormat:@"pix %@ setfImage %@", self.name, DescribePointer(p)]); }
@end

@implementation DCMView
@synthesize flippedData = _flippedData, whiteBackground = _whiteBackground, drawing = _drawing, origin = _origin, curDCM = _curDCM;
- (NSMutableArray*) dcmPixList { return dcmPixList; }
- (NSInteger) curImage { return curImage; }
- (float) scaleValue { return scaleValue; }
- (void) setScaleValue:(float)v { scaleValue = v; RecordLine([NSString stringWithFormat:@"view setScaleValue %@", BitsF(v)]); }
- (float) rotation { return rotation; }
- (void) setRotation:(float)v { rotation = v; RecordLine([NSString stringWithFormat:@"view setRotation %@", BitsF(v)]); }
- (void) setOrigin:(NSPoint)o { _origin = o; RecordLine([NSString stringWithFormat:@"view setOrigin %@ %@", BitsD(o.x), BitsD(o.y)]); }
- (void) setWhiteBackground:(BOOL)b { _whiteBackground = b; RecordLine([NSString stringWithFormat:@"view whiteBackground %d", b]); }
- (void) setDrawing:(BOOL)b { _drawing = b; RecordLine([NSString stringWithFormat:@"view drawing %d", b]); }
- (void) setIndex:(NSInteger) index { curImage = index; RecordLine([NSString stringWithFormat:@"view setIndex %ld", (long)index]); }
- (void) setWLWW:(float) l :(float) w { wl = l; ww = w; RecordLine([NSString stringWithFormat:@"view setWLWW %@ %@", BitsF(l), BitsF(w)]); }
- (void) getWLWW:(float*) l :(float*) w { if (l) *l = wl; if (w) *w = ww; }
- (void) setFusion:(short) mode :(short) stacks { fusionStacks = stacks; RecordLine([NSString stringWithFormat:@"view setFusion %d %d", mode, stacks]); }
- (void) setCLUT:(unsigned char*) r :(unsigned char*) g :(unsigned char*) b
{
    hasCLUT = r != NULL;
    if (r) { memcpy(clutRed, r, 256); memcpy(clutGreen, g, 256); memcpy(clutBlue, b, 256); }
    RecordLine([NSString stringWithFormat:@"view setCLUT %@ %@ %@", HashBytes(r, 256), HashBytes(g, 256), HashBytes(b, 256)]);
}
- (void) getCLUT:(unsigned char**) r :(unsigned char**) g :(unsigned char**) b
{ *r = hasCLUT ? clutRed : NULL; *g = hasCLUT ? clutGreen : NULL; *b = hasCLUT ? clutBlue : NULL; }
- (void) loadTextures { RecordLine(@"view loadTextures"); }
- (void) setNeedsDisplay:(BOOL)b { RecordLine([NSString stringWithFormat:@"view setNeedsDisplay %d", b]); }
- (void) scaleToFit { RecordLine(@"view scaleToFit"); }
- (void) updateTilingViews { RecordLine(@"view updateTilingViews"); }
- (void) roiSet { RecordLine(@"view roiSet"); }
- (void) stopROIEditingForce:(BOOL) force { RecordLine(@"view stopROIEditing"); }
- (void) sendSyncMessage:(NSInteger) inc { RecordLine([NSString stringWithFormat:@"view sendSyncMessage %ld", (long)inc]); }
- (void) getThickSlabThickness:(float*) thickness location:(float*) location { *thickness = fusionStacks * 1.25f; *location = 0; }
+ (double) angleBetweenVectorD:(double*) a andVectorD:(double*) b
{
    double dot = a[0]*b[0] + a[1]*b[1] + a[2]*b[2];
    double la = sqrt(a[0]*a[0] + a[1]*a[1] + a[2]*a[2]), lb = sqrt(b[0]*b[0] + b[1]*b[1] + b[2]*b[2]);
    if (la == 0 || lb == 0) return 0;
    double c = dot / (la * lb); if (c > 1) c = 1; if (c < -1) c = -1;
    return acos(c);
}
+ (void) computePETBlendingCLUT { RecordLine([NSString stringWithFormat:@"DCMView computePETBlendingCLUT %@", [[NSUserDefaults standardUserDefaults] stringForKey:@"PET Blending CLUT"]]); }
@end

@implementation SeriesView
- (NSMutableArray*) imageViews { return [[self.subviews mutableCopy] autorelease]; }
- (void) setFlippedData:(BOOL) value { RecordLine([NSString stringWithFormat:@"seriesView setFlippedData %d", value]);
    for (DCMView *v in self.subviews) v.flippedData = value; }
@end

@implementation ColorTransferView { NSMutableArray *points, *colors; }
- (NSMutableArray*) getPoints { if (!points) points = [NSMutableArray new]; return points; }
- (NSMutableArray*) getColors { if (!colors) colors = [NSMutableArray new]; return colors; }
- (void) ConvertCLUT:(unsigned char*) r :(unsigned char*) g :(unsigned char*) b
{ for (int i = 0; i < 256; i++) { r[i] = (unsigned char)(i * 7); g[i] = (unsigned char)(255 - i); b[i] = (unsigned char)(i / 3 + 20); } }
@end

@implementation PluginManager
+ (NSMutableDictionary*) plugins { return nil; }
+ (void) startProtectForCrashWithFilter:(id) filter {}
+ (void) endProtectForCrash {}
@end

@implementation AppController
+ (BOOL) willExecutePlugin:(id) filter { return YES; }
@end

@implementation HorosWindowLevelText
+ (NSString*) stringForValue:(double) value { return [NSString stringWithFormat:@"%.4f", value]; }
+ (double) valueFromString:(NSString*) text fallback:(double) fallback { return text.length ? text.doubleValue : fallback; }
+ (double) widthFromString:(NSString*) text fallback:(double) fallback { double v = text.doubleValue; return text.length && v >= 1 ? v : fallback; }
@end

@implementation HorosGantryTiltPolicy
+ (BOOL) shouldCorrectTiltOfDegrees:(float) degrees { RecordLine([NSString stringWithFormat:@"gantry policy asked %@", BitsF(degrees)]); return YES; }
@end

@implementation HorosSliceIntervalRegularity
@synthesize minimumInterval = _minimumInterval, maximumInterval = _maximumInterval, isIrregular = _isIrregular;
+ (HorosSliceIntervalRegularity*) regularityOfOrigins:(NSArray<NSNumber*>*) origins normal:(NSArray<NSNumber*>*) normal pixelSpacing:(double) spacing
{
    HorosSliceIntervalRegularity *r = [[HorosSliceIntervalRegularity new] autorelease];
    r->_minimumInterval = 1; r->_maximumInterval = origins.count; r->_isIrregular = origins.count % 2 == 0;
    RecordLine([NSString stringWithFormat:@"regularity %lu %@ %@", (unsigned long)origins.count, normal, BitsD(spacing)]);
    return r;
}
@end

@implementation NSWindow (HarnessSheet)
- (void) orderOutAndEndSheetWithReturnCode:(NSModalResponse) code { RecordLine([NSString stringWithFormat:@"sheet end %ld", (long)code]); }
@end

@implementation ViewerController
- (void) checkEverythingLoaded { RecordLine(@"viewer checkEverythingLoaded"); }
- (BOOL) isEverythingLoaded { return YES; }
- (void) computeSubCtrlMinMax { RecordLine(@"viewer computeSubCtrlMinMax"); }
- (NSString *) subtractionUnavailableReason { return @"Synthetic reason"; }
- (void)checkView:(NSView *)aView :(BOOL) on { RecordLine([NSString stringWithFormat:@"viewer checkView %d", on]); }
- (void) setWindowTitle:(id) sender { RecordLine(@"viewer setWindowTitle"); }
- (void) adjustSlider { RecordLine(@"viewer adjustSlider"); }
- (void) propagateSettings { RecordLine(@"viewer propagateSettings"); }
- (IBAction) updateImage:(id) sender { RecordLine(@"viewer updateImage"); }
- (void) selectFirstTilingView { RecordLine(@"viewer selectFirstTilingView"); }
- (void) setUpdateTilingViewsValue:(BOOL) v { RecordLine([NSString stringWithFormat:@"viewer setUpdateTilingViewsValue %d", v]); }
- (BOOL) isDataVolumicIn4D:(BOOL) check4D { return YES; }
- (void) changeImageData:(NSMutableArray*)f :(NSMutableArray*)d :(NSData*) v :(BOOL) t { RecordLine(@"viewer changeImageData"); }
- (void) addMovieSerie:(NSMutableArray*)f :(NSMutableArray*)d :(NSData*) v { RecordLine(@"viewer addMovieSerie"); }
- (void) setPostprocessed:(BOOL) v { postprocessed = v; }
- (id) startWaitWindow :(NSString*) message { return nil; }
- (void) endWaitWindow:(id) waitWindow {}
- (void) horosLoadViewerPanels {}
- (void) ApplyConvString:(NSString*) str { RecordLine([NSString stringWithFormat:@"viewer ApplyConvString %@", str]); }
- (NSMutableArray*) pixList: (long) i { return pixList[i]; }
- (NSMutableArray*) fileList: (long) i { return fileList[i]; }
+ (NSMutableArray*) getDisplayed2DViewers { return [NSMutableArray array]; }
+ (void) correctGangtryTilt: (ViewerController*) v { RecordLine(@"viewer correctGangtryTilt"); }
- (IBAction) mprViewer:(id) sender { RecordLine(@"viewer mprViewer"); }
- (IBAction) cprViewer:(id) sender { RecordLine(@"viewer cprViewer"); }
- (IBAction) orthogonalMPRViewer:(id) sender { RecordLine(@"viewer orthogonalMPRViewer"); }
- (IBAction) VRViewer:(id) sender { RecordLine(@"viewer VRViewer"); }
- (IBAction) SRViewer:(id) sender { RecordLine(@"viewer SRViewer"); }
- (IBAction) endoscopyViewer:(id) sender { RecordLine(@"viewer endoscopyViewer"); }
@end

@implementation ViewerController (SwiftIvars)
IMPLEMENTATIONS
@end
'''.replace('IMPLEMENTATIONS', '\n'.join(implementations)).replace(
    'CALIBRATION', function(current_vc if 'BOOL HorosCalibrationFloat(' in current_vc else reference_vc, 'BOOL HorosCalibrationFloat('))
# The calibration parser the Objective-C calls: in ViewerController.m until it
# moved to IsiXImaging (CalibrationNumber), declared as HorosCalibration.h did.
CALIBRATION_H = '''#pragma once
#import <Foundation/Foundation.h>
#include <math.h>
#include <float.h>
FOUNDATION_EXPORT BOOL HorosCalibrationFloat(NSString *text, NSLocale *locale, float *value);
'''

# The classes the app implements in Swift with parameters Objective-C would
# import otherwise (NSArray, NSData): stand-ins in Swift too, in both programs.
GLUE = r'''
import AppKit

@objc(ThickSlabController)
public final class ThickSlabController: NSObject {
    @objc public override init() { super.init(); RecordLine("thickSlab init") }
    @objc(setImageData:::::::)
    public func setImageData(_ w: Int, _ h: Int, _ c: Int, _ sX: Float, _ sY: Float, _ t: Float, _ flip: Bool) {
        RecordLine("thickSlab setImageData \(w) \(h) \(c) \(BitsF(sX)!) \(BitsF(sY)!) \(BitsF(t)!) \(flip)")
    }
    @objc(setCLUT:::)
    public func setCLUT(_ r: UnsafeMutablePointer<UInt8>?, _ g: UnsafeMutablePointer<UInt8>?, _ b: UnsafeMutablePointer<UInt8>?) {
        RecordLine("thickSlab setCLUT \(HashBytes(r, 256)!) \(HashBytes(g, 256)!) \(HashBytes(b, 256)!)")
    }
    @objc(setFlip:)
    public func setFlip(_ f: Bool) { RecordLine("thickSlab setFlip \(f)") }
    @objc(setOpacity:)
    public func setOpacity(_ array: NSArray?) { RecordLine("thickSlab setOpacity \(array.map { "\($0)" } ?? "nil")") }
}

@objc(OpacityTransferView)
public final class OpacityTransferView: NSView {
    let points = NSMutableArray()
    @objc public func getPoints() -> NSMutableArray? { return points }
    @objc(setCurrentCLUT:::)
    public func setCurrentCLUT(_ r: UnsafeMutablePointer<UInt8>?, _ g: UnsafeMutablePointer<UInt8>?, _ b: UnsafeMutablePointer<UInt8>?) {
        RecordLine("opacityView setCurrentCLUT \(HashBytes(r, 256)!) \(HashBytes(g, 256)!) \(HashBytes(b, 256)!)")
    }
    @objc(tableWith4096Entries:)
    public class func tableWith4096Entries(_ pointsArray: NSArray?) -> NSData {
        let count = Float((pointsArray?.count ?? 0) + 1)
        let values = (0..<4096).map { Float($0 % 97) / count }
        return values.withUnsafeBufferPointer { NSData(bytes: $0.baseAddress, length: 4096 * 4) }
    }
}

extension DCMView {
    @objc(cleanedOutDcmPixArray:)
    public class func cleanedOutDcmPixArray(_ input: NSArray!) -> NSArray! { return input }
}
'''

PIPELINE_H = r'''
#import "stubs.h"
@interface ViewerController (Pipeline)
+ (BOOL)resampleDataFromPixArray:(NSArray *)originalPixlist fileArray:(NSArray*)originalFileList inPixArray:(NSMutableArray*)aPixList fileArray:(NSMutableArray*)aFileList data:(NSData**)aData withXFactor:(float)xFactor yFactor:(float)yFactor zFactor:(float)zFactor;
+ (float) computeIntervalForDCMPix: (DCMPix*) p1 And: (DCMPix*) p2;
- (float) computeIntervalFlipNow: (NSNumber*) flipNowNumber;
- (float) computeInterval;
- (short) orthogonalOrientation;
- (short) orientationVector;
- (BOOL) isGantryTitled;
- (void) flipData:(char*) ptr :(long) no :(long) x :(long) y;
- (IBAction) endThicknessInterval:(id) sender;
- (IBAction) updateZVector:(id) sender;
- (IBAction) setAxialOrientation:(id) sender;
- (IBAction) subCtrlOnOff:(id) sender;
- (IBAction) subCtrlNewMask:(id) sender;
- (IBAction) subCtrlOffset:(id) sender;
- (IBAction) subCtrlSliders:(id) sender;
- (int) threeTestsFivePosibilities: (int) f;
- (void) offsetMatrixSetting: (int) twentyFiveCodes;
- (IBAction) subSumSlider:(id) sender;
- (IBAction) subSharpen:(id) sender;
- (void) setCurWLWWMenu:(NSString*)s;
- (NSString*) curWLWWMenu;
- (IBAction) ConvertToRGBMenu:(id) sender;
- (IBAction) ConvertToBWMenu:(id) sender;
- (void) ApplyWLWW:(id) sender;
- (IBAction) updateSetWLWW:(id) sender;
- (IBAction) endSetWLWW:(id) sender;
- (IBAction) SetWLWW:(id) sender;
- (IBAction) resetImage:(id) sender;
- (void) ApplyCLUTString:(NSString*) str;
- (void) CLUTChanged: (NSNotification*) note;
- (void) ApplyCLUT:(id) sender;
- (IBAction) endCLUT:(id) sender;
- (NSString*) curCLUTMenu;
- (void) OpacityChanged: (NSNotification*) note;
- (void) ApplyOpacityString:(NSString*) str;
- (IBAction) endOpacity:(id) sender;
- (NSString*) curOpacityMenu;
- (NSSlider*) sliderFusion;
- (ThickSlabController*) thickSlabController;
- (NSString *) thicknessInMm;
- (void) setFusionMode:(long) m;
- (void) adjustThickSlabBySteps:(NSInteger)steps;
- (void) activateFusion:(id) sender;
- (void) popFusionAction:(id) sender;
- (void) sliderFusionAction:(id) sender;
@end
@interface NSObject (HarnessPoints)
- (NSMutableArray*) getPoints;
@end
'''

DRIVER = r'''
#import "pipeline.h"
void RegisterBuffer(NSString *name, const void *base, long length);

#define R(...) RecordLine([NSString stringWithFormat:__VA_ARGS__])

static const float AXIAL[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
static const float SAGITTAL[9] = {0, 1, 0, 0, 0, -1, 1, 0, 0};
static const float CORONAL[9] = {1, 0, 0, 0, 0, -1, 0, -1, 0};
static float OBLIQUE[9];

static DCMPix *Pix(NSString *name, long w, long h, float *image, const float *orientation, double x, double y, double z)
{
    DCMPix *p = [[DCMPix new] autorelease];
    p.name = name;
    p->pwidth = w; p->pheight = h; p->fImage = image;
    memcpy(p->orientationValues, orientation, 9 * sizeof(float));
    p->originX = x; p->originY = y; p->originZ = z;
    p->pixelSpacingX = 0.7; p->pixelSpacingY = 0.9; p->pixelRatio = 0.9 / 0.7; p->sliceThickness = 1.25;
    p->savedWL = 40; p->savedWW = 400;
    return p;
}

// A stack of `count` slices of w x h along the normal of `orientation`, `step` apart,
// in one buffer (named), slice i shifted by `shear` along x (a tilted gantry).
static NSMutableArray *Stack(NSString *name, long count, long w, long h, const float *orientation, double step, double shear, BOOL rgb, float **volume)
{
    float *buffer = malloc(sizeof(float) * count * w * h + 64);
    RegisterBuffer(name, buffer, sizeof(float) * count * w * h);
    for (long k = 0; k < count * w * h; k++) {
        long i = k / (w * h), x = k % w, y = (k / w) % h;
        if (rgb) { unsigned char *c = (unsigned char *)(buffer + k); c[0] = 255; c[1] = (unsigned char)(x * 17 + i); c[2] = (unsigned char)(y * 29); c[3] = (unsigned char)(i * 41 + x); }
        else buffer[k] = (float)((x * 13 + y * 7 + i * 31) % 97) - 20.5f + 0.25f * x * y;
    }
    NSMutableArray *list = [NSMutableArray array];
    for (long i = 0; i < count; i++) {
        double d = step * i;
        DCMPix *p = Pix([NSString stringWithFormat:@"%@%ld", name, i], w, h, buffer + i * w * h, orientation,
                        -50 + orientation[6] * d + shear * i, 20.5 + orientation[7] * d, 7.25 + orientation[8] * d);
        p->isRGB = rgb;
        [list addObject:p];
    }
    if (volume) *volume = buffer;
    return list;
}

static void Resample(NSString *title, long count, long w, long h, const float *orientation, double step, BOOL rgb, double sliceInterval, float fx, float fy, float fz)
{
    R(@"== resample %@", title);
    NSMutableArray *pix = Stack(title, count, w, h, orientation, step, 0, rgb, NULL);
    ((DCMPix *)pix[0])->sliceInterval = sliceInterval;
    NSMutableArray *files = [NSMutableArray array];
    for (long i = 0; i < count; i++) [files addObject:[NSString stringWithFormat:@"file%ld", i]];
    NSMutableArray *outPix = [NSMutableArray array], *outFiles = [NSMutableArray array];
    NSData *data = nil;
    BOOL done = [ViewerController resampleDataFromPixArray:pix fileArray:files inPixArray:outPix fileArray:outFiles data:&data withXFactor:fx yFactor:fy zFactor:fz];
    R(@"result %d slices %lu files %@ data %lu list %@", done, (unsigned long)outPix.count, [outFiles componentsJoinedByString:@","], (unsigned long)data.length, ListName(outPix));
    if (data) RegisterBuffer(@"out", data.bytes, data.length);
    for (DCMPix *p in outPix)
        R(@"slice %@ %ldx%ld tot %ld frame %ld id %ld spacing %@ %@ thickness %@ ratio %@ origin %@ %@ %@ interval %@ image %@",
          p.name, p.pwidth, p.pheight, p.Tot, p.frameNo, p.ID, BitsD(p.pixelSpacingX), BitsD(p.pixelSpacingY), BitsD(p.sliceThickness),
          BitsD(p.pixelRatio), BitsD(p.originX), BitsD(p.originY), BitsD(p.originZ), BitsD(p.sliceInterval), DescribePointer(p.fImage));
    R(@"volume %@", HashBytes(data.bytes, data.length));
}

static ViewerController *Viewer(NSArray *movies, NSArray *fileLists)
{
    ViewerController *v = [[ViewerController alloc] initWithWindow:nil];
    v->maxMovieIndex = (short)movies.count;
    for (NSUInteger m = 0; m < movies.count; m++) {
        v->pixList[m] = [movies[m] retain];
        v->fileList[m] = [(fileLists ? fileLists[m] : [NSMutableArray array]) retain];
        v->roiList[m] = [[NSMutableArray array] retain];
        for (NSUInteger i = 0; i < [movies[m] count]; i++) {
            ROI *roi = [[ROI new] autorelease]; roi.name = [NSString stringWithFormat:@"roi%lu.%lu", (unsigned long)m, (unsigned long)i];
            [v->roiList[m] addObject:[NSMutableArray arrayWithObject:roi]];
            DCMPix *p = movies[m][i];
            if (!fileLists) [v->fileList[m] addObject:@{@"name": [NSString stringWithFormat:@"file%lu.%lu", (unsigned long)m, (unsigned long)i],
                                                         @"width": @(p.pwidth), @"height": @(p.pheight)}];
        }
    }
    DCMView *view = [[DCMView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    view->dcmPixList = [movies.firstObject retain];
    view->curImage = 1;
    view->wl = 40.7f; view->ww = 400.6f;
    v->imageView = view;
    v->seriesView = [[SeriesView alloc] initWithFrame:NSZeroRect];
    [v->seriesView addSubview:view];
    v->originalOrientation = -1;
    v->orientationMatrix = [[NSMatrix alloc] initWithFrame:NSMakeRect(0, 0, 90, 30) mode:NSRadioModeMatrix cellClass:[NSButtonCell class] numberOfRows:1 numberOfColumns:3];
    for (int i = 0; i < 3; i++) [[v->orientationMatrix cellAtRow:0 column:i] setTag:i];
    [v->orientationMatrix setEnabled:NO];
    v->activatedFusion = [[NSButton alloc] init];
    v->sliderFusion = [[NSSlider alloc] init]; v->sliderFusion.minValue = 1; v->sliderFusion.maxValue = 40; v->sliderFusion.intValue = 3;
    v->stacksFusion = [[NSTextField alloc] init];
    v->popFusion = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (int i = 0; i < 6; i++) { [v->popFusion addItemWithTitle:[NSString stringWithFormat:@"mode %d", i]]; [[v->popFusion lastItem] setTag:i]; }
    [v->popFusion selectItemWithTag:2];
    return v;
}

static void State(ViewerController *v, NSString *title)
{
    R(@"-- state %@: orientationVector %d tool %d original %d matrix %ld enabled %d gantry %d %@ mask %ld", title, v->orientationVector,
      v->currentOrientationTool, v->originalOrientation, (long)[[v->orientationMatrix selectedCell] tag], [v->orientationMatrix isEnabled],
      v->titledGantry, BitsF(v->titledGantryDegrees), v->subCtrlMaskID);
    for (int m = 0; m < v->maxMovieIndex; m++) {
        NSMutableString *s = [NSMutableString string];
        for (NSUInteger i = 0; i < v->pixList[m].count; i++) {
            DCMPix *p = v->pixList[m][i];
            [s appendFormat:@" %@[%@ %@ %@ %@ id%ld]", p.name, DescribePointer(p.fImage), BitsD(p.sliceInterval), BitsD(p.originZ), BitsD(p.originX), p.ID];
        }
        R(@"movie %d:%@", m, s);
        R(@"files %d: %@", m, [[v->fileList[m] valueForKey:@"name"] componentsJoinedByString:@","]);
        NSMutableArray *names = [NSMutableArray array];
        for (NSArray *slice in v->roiList[m]) [names addObject:[slice.firstObject name] ?: @"-"];
        R(@"rois %d: %@", m, [names componentsJoinedByString:@","]);
    }
}

static void Intervals(void)
{
    R(@"== intervals");
    NSArray *orientations = @[[NSValue valueWithPointer:AXIAL], [NSValue valueWithPointer:SAGITTAL], [NSValue valueWithPointer:CORONAL], [NSValue valueWithPointer:OBLIQUE]];
    for (NSValue *o in orientations)
        for (NSNumber *step in @[@2.5, @-1.75]) {
            NSArray *s = Stack(@"pair", 2, 2, 2, o.pointerValue, step.doubleValue, 0, NO, NULL);
            R(@"pair %@ %@", BitsF([ViewerController computeIntervalForDCMPix:s[0] And:s[1]]), BitsF([ViewerController computeIntervalForDCMPix:s[1] And:s[0]]));
        }
    NSArray *mixed = @[Stack(@"m", 1, 2, 2, AXIAL, 1, 0, NO, NULL)[0], Stack(@"n", 1, 2, 2, SAGITTAL, 1, 0, NO, NULL)[0]];
    R(@"mixed %@", BitsF([ViewerController computeIntervalForDCMPix:mixed[0] And:mixed[1]]));
    float zero[9] = {0};
    NSArray *none = Stack(@"z", 2, 2, 2, zero, 1, 0, NO, NULL);
    R(@"none %@", BitsF([ViewerController computeIntervalForDCMPix:none[0] And:none[1]]));

    struct { NSString *title; long count; const float *orientation; double step, shear; int movies; BOOL flip; } cases[] = {
        {@"ascending", 6, AXIAL, 2.5, 0, 1, YES},
        {@"descending4D", 7, AXIAL, -1.5, 0, 2, YES},
        {@"descendingNoFlip", 5, CORONAL, -2, 0, 1, NO},
        {@"sagittal", 5, SAGITTAL, 3, 0, 1, YES},
        {@"tilted", 6, OBLIQUE, 1.3, 0.45, 1, YES},
        {@"tiltedDescending", 6, OBLIQUE, -1.1, 0.3, 1, YES},
        {@"long", 61, AXIAL, -0.8, 0, 1, YES},
    };
    for (unsigned c = 0; c < sizeof cases / sizeof cases[0]; c++) {
        R(@"== interval %@", cases[c].title);
        NSMutableArray *movies = [NSMutableArray array];
        for (int m = 0; m < cases[c].movies; m++)
            [movies addObject:Stack([NSString stringWithFormat:@"%@.%d.", cases[c].title, m], cases[c].count, 3, 2, cases[c].orientation, cases[c].step, cases[c].shear, NO, NULL)];
        ViewerController *v = Viewer(movies, nil);
        v->subCtrlMaskID = 1;
        R(@"interval %@", BitsF([v computeIntervalFlipNow:@(cases[c].flip)]));
        State(v, cases[c].title);
        float *volume = [v->pixList[0][0] fImage];
        R(@"volume %@", HashBytes(volume, sizeof(float) * cases[c].count * 6));
        R(@"orthogonal %d vector %d", [v orthogonalOrientation], [v orientationVector]);
    }

    R(@"== interval unpositioned");
    float zeros[9] = {0};
    NSMutableArray *flat = Stack(@"flat", 4, 3, 2, zeros, 0, 0, NO, NULL);
    for (DCMPix *p in flat) { p->originX = p->originY = p->originZ = 0; p->spacingBetweenSlices = 2.5; }
    memcpy(((DCMPix *)flat[1])->orientationValues, AXIAL, sizeof AXIAL); memcpy(((DCMPix *)flat[2])->orientationValues, AXIAL, sizeof AXIAL);
    ViewerController *v = Viewer(@[flat], nil);
    R(@"interval %@", BitsF([v computeInterval]));
    State(v, @"unpositioned");

    R(@"== interval mixed sizes");
    NSMutableArray *sizes = Stack(@"sizes", 5, 3, 2, AXIAL, -2, 0, NO, NULL);
    ((DCMPix *)sizes[3])->pwidth = 2;
    v = Viewer(@[sizes], nil);
    R(@"interval %@", BitsF([v computeInterval]));
    State(v, @"mixed sizes");

    R(@"== interval kept");
    NSMutableArray *kept = Stack(@"kept", 4, 3, 2, AXIAL, 2, 0, NO, NULL);
    ((DCMPix *)kept[0])->sliceInterval = 1.5;
    v = Viewer(@[kept], nil);
    R(@"interval %@", BitsF([v computeIntervalFlipNow:@NO]));
    State(v, @"kept");

    for (NSNumber *n in @[@7, @55]) {
        R(@"== flipData %@", n);
        float *volume = NULL;
        Stack(@"flip", n.longValue, 5, 3, AXIAL, 1, 0, NO, &volume);
        [v flipData:(char *)volume :n.longValue :5 :3];
        R(@"volume %@", HashBytes(volume, sizeof(float) * n.longValue * 15));
    }
}

static NSTextField *Field(NSString *text) { NSTextField *f = [[NSTextField alloc] init]; f.stringValue = text; return f; }
static NSMatrix *Cells(int count)
{
    NSMatrix *m = [[NSMatrix alloc] initWithFrame:NSMakeRect(0, 0, 90, 90) mode:NSTrackModeMatrix cellClass:[NSTextFieldCell class] numberOfRows:1 numberOfColumns:count];
    for (int i = 0; i < count; i++) [[m cellAtRow:0 column:i] setTag:i];
    return m;
}
static NSButton *Sender(NSInteger tag) { NSButton *b = [[[NSButton alloc] init] autorelease]; b.tag = tag; return b; }

static void ThicknessSheet(void)
{
    R(@"== thickness sheet");
    ViewerController *v = Viewer(@[Stack(@"sheet", 4, 3, 2, AXIAL, 1, 0, NO, NULL), Stack(@"sheet4D", 4, 3, 2, AXIAL, 1, 0, NO, NULL)], nil);
    v->customInterval = Field(@"2.75"); v->customXSpacing = Field(@"0.6"); v->customYSpacing = Field(@"0.8");
    v->customVectors = Cells(9); v->customOrigin = Cells(3);
    const char *vectors[9] = {"0.8", "0.6", "0", "-0.36", "0.48", "0.8", "0", "0", "0"};
    for (int i = 0; i < 9; i++) [[v->customVectors cellWithTag:i] setStringValue:@(vectors[i])];
    const char *origin[3] = {"-12.5", "4.25", "100.125"};
    for (int i = 0; i < 3; i++) [[v->customOrigin cellWithTag:i] setStringValue:@(origin[i])];
    [v updateZVector:nil];
    R(@"normal %@ %@ %@", BitsF([[v->customVectors cellWithTag:6] floatValue]), BitsF([[v->customVectors cellWithTag:7] floatValue]), BitsF([[v->customVectors cellWithTag:8] floatValue]));
    [v endThicknessInterval:Sender(1)];
    State(v, @"thickness");
    v->customXSpacing = Field(@"-1");
    [v endThicknessInterval:Sender(1)];
    [v setAxialOrientation:nil];
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < 9; i++) [s appendFormat:@" %@", [[v->customVectors cellWithTag:i] stringValue]];
    R(@"axial%@", s);
}

static void Subtraction(void)
{
    R(@"== subtraction");
    float *volume = NULL;
    NSMutableArray *pix = Stack(@"xa", 5, 6, 5, AXIAL, 1, 0, NO, &volume);
    ((DCMPix *)pix[3])->pwidth = 4;
    for (NSUInteger i = 0; i < pix.count; i++) [pix[i] fImageTime:1.5f * i];
    ViewerController *v = Viewer(@[pix, Stack(@"xb", 5, 6, 5, AXIAL, 1, 0, NO, NULL)], nil);
    v->enableSubtraction = YES;
    v->subCtrlOnOff = Sender(15); [v->subCtrlOnOff setButtonType:NSButtonTypePushOnPushOff];
    v->subCtrlMaskText = Field(@"");
    NSButton **sc[9] = {&v->sc1, &v->sc2, &v->sc3, &v->sc4, &v->sc5, &v->sc6, &v->sc7, &v->sc8, &v->sc9};
    for (int i = 0; i < 9; i++) { *sc[i] = [[NSButton alloc] init]; [*sc[i] setButtonType:NSButtonTypePushOnPushOff]; }
    NSArray *indicator = @[v->sc1, v->sc2, v->sc3, v->sc4, v->sc5, v->sc6, v->sc7, v->sc8, v->sc9];
    v->subCtrlSum = [[NSSlider alloc] init]; v->subCtrlSum.minValue = 1; v->subCtrlSum.maxValue = 10; v->subCtrlSum.floatValue = 1;
    v->subCtrlPercent = [[NSSlider alloc] init]; v->subCtrlPercent.maxValue = 100; v->subCtrlPercent.floatValue = 37.5f;
    v->subCtrlSharpenButton = [[NSButton alloc] init]; [v->subCtrlSharpenButton setButtonType:NSButtonTypePushOnPushOff];
    void (^states)(NSString *) = ^(NSString *title) {
        NSMutableString *s = [NSMutableString string];
        for (NSButton *button in indicator) [s appendFormat:@"%ld", (long)button.state];
        R(@"%@: offset %@ %@ minmax %@ %@ mask %ld text %@ on %ld sum %@ stacks %@ slider %d active %ld sharpen %ld indicator %@", title,
          BitsD(v->subCtrlOffset.x), BitsD(v->subCtrlOffset.y), BitsD(v->subCtrlMinMax.x), BitsD(v->subCtrlMinMax.y), v->subCtrlMaskID,
          v->subCtrlMaskText.stringValue, (long)v->subCtrlOnOff.state, BitsF(v->subCtrlSum.floatValue), v->stacksFusion.stringValue,
          v->sliderFusion.intValue, (long)v->activatedFusion.state, (long)v->subCtrlSharpenButton.state, s);
    };
    [v subCtrlNewMask:nil];
    states(@"new mask");
    for (NSNumber *tag in @[@9, @9, @6, @1, @7, @5, @8, @8, @3, @2, @4, @0])
    { [v subCtrlOffset:Sender(tag.integerValue)]; states([NSString stringWithFormat:@"offset %@", tag]); }
    for (NSNumber *tag in @[@37, @38, @39, @34, @35, @36, @1])
    { [v subCtrlSliders:Sender(tag.integerValue)]; states([NSString stringWithFormat:@"slider %@", tag]); }
    for (NSNumber *tag in @[@33, @33, @31, @32, @0])
    { [v subSumSlider:Sender(tag.integerValue)]; states([NSString stringWithFormat:@"sum %@", tag]); }
    [v subSharpen:Sender(30)]; [v subSharpen:Sender(30)]; [v subSharpen:Sender(0)];
    states(@"sharpen");
    [v subCtrlOnOff:Sender(0)];
    states(@"menu off");
    [v subCtrlOnOff:Sender(0)];
    states(@"menu on");
    v->imageView.flippedData = YES;
    v->imageView->curImage = 0;
    [v subCtrlNewMask:nil];
    states(@"flipped mask");
    for (int f = -4; f <= 4; f++) R(@"index %d %d", f, [v threeTestsFivePosibilities:f]);
    for (int code = -1; code <= 26; code++) { [v offsetMatrixSetting:code]; states([NSString stringWithFormat:@"code %d", code]); }
    v->enableSubtraction = NO;
    [v subCtrlOnOff:Sender(15)];
    states(@"disabled");
}

static void WindowLevel(void)
{
    R(@"== window level");
    ViewerController *v = Viewer(@[Stack(@"wl", 3, 3, 2, AXIAL, 1, 0, NO, NULL), Stack(@"wl4D", 3, 3, 2, AXIAL, 1, 0, NO, NULL)], nil);
    v->wlset = Field(@""); v->wwset = Field(@""); v->fromset = Field(@""); v->toset = Field(@"");
    v->wlwwPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    [v->wlwwPopup addItemWithTitle:@"title"]; [v->wlwwPopup addItemWithTitle:@"Default WL & WW"];
    void (^fields)(NSString *) = ^(NSString *title) {
        R(@"%@: wl %@ ww %@ from %@ to %@ view %@ %@ menu %@ popup %@", title, v->wlset.stringValue, v->wwset.stringValue, v->fromset.stringValue,
          v->toset.stringValue, BitsF(v->imageView->wl), BitsF(v->imageView->ww), [v curWLWWMenu], [[v->wlwwPopup itemAtIndex:0] title]);
    };
    [v SetWLWW:nil]; fields(@"set");
    v->wlset.stringValue = @"40"; v->wwset.stringValue = @"0.5"; [v updateSetWLWW:Sender(0)]; fields(@"update level");
    v->fromset.stringValue = @"-100.5"; v->toset.stringValue = @"300.25"; [v updateSetWLWW:Sender(1)]; fields(@"update range");
    [v endSetWLWW:Sender(1)]; fields(@"ok");
    [v SetWLWW:nil]; v->wlset.stringValue = @"77"; [v endSetWLWW:Sender(0)]; fields(@"cancel");
    for (NSString *title in @[@"Default WL & WW", @"Full dynamic", @"Other", @"1 - Brain", @"2 - Missing", @"3 - Short"]) {
        NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""] autorelease];
        [v ApplyWLWW:item]; fields(title);
    }
    [v setCurWLWWMenu:@"Abdomen"]; fields(@"menu Abdomen");
    [v setCurWLWWMenu:@"Abdomen"]; fields(@"menu again");
    [v resetImage:nil];
    [v ConvertToRGBMenu:Sender(2)];
    [v ConvertToRGBMenu:Sender(2)];
    [v ConvertToBWMenu:Sender(1)];
    [v ConvertToBWMenu:Sender(1)];
}

static NSArray *Channel(int kind)
{
    NSMutableArray *a = [NSMutableArray array];
    for (int i = 0; i < 256; i++) {
        switch (kind) {
            case 0: [a addObject:@(i)]; break;
            case 1: [a addObject:@(255 - i)]; break;
            case 2: [a addObject:@((i * 37) % 300 - 20)]; break;
            default: [a addObject:@(i / 2.0 + 0.75)]; break;
        }
    }
    return a;
}

static void ColorTables(void)
{
    R(@"== color tables");
    NSString *domain = [[NSProcessInfo processInfo] processName];
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:domain];
    NSDictionary *cluts = @{
        @"Ramp": @{@"Red": Channel(0), @"Green": Channel(1), @"Blue": Channel(2), @"Points": @[@1, @2], @"Colors": @[@"c1", @"c2"]},
        @"Odd": @{@"Red": Channel(3), @"Green": Channel(2), @"Blue": Channel(0)},
        @"B/W Inverse": @{@"Red": Channel(1), @"Green": Channel(1), @"Blue": Channel(1)},
    };
    NSDictionary *opacities = @{@"Op": @{@"Points": @[@"p1", @"p2", @"p3"]}, @"Empty": @{@"Points": @[]}};
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"CLUT": cluts, @"OPACITY": opacities,
        @"WLWW3": @{@"Brain": @[@40, @80]}, @"PET Clut Mode": @"B/W Inverse", @"PET Blending CLUT": @"Before"}];

    ViewerController *v = Viewer(@[Stack(@"ct", 3, 3, 2, AXIAL, 1, 0, NO, NULL), Stack(@"ct4D", 3, 3, 2, AXIAL, 1, 0, NO, NULL)], nil);
    v->clutPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES]; [v->clutPopup addItemWithTitle:@"title"];
    v->OpacityPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES]; [v->OpacityPopup addItemWithTitle:@"title"];
    NSObject *observer = [[NSObject new] autorelease];
    for (NSString *name in @[OsirixUpdateCLUTMenuNotification, OsirixUpdateOpacityMenuNotification, OsirixUpdateWLWWMenuNotification,
                             OsirixDCMUpdateCurrentImageNotification, OsirixRecomputeROINotification])
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            R(@"notification %@ %@ %@", note.name, [note.object isKindOfClass:[NSString class]] ? note.object : (note.object ? NSStringFromClass([note.object class]) : @"nil"), note.userInfo);
        }];
    (void)observer;
    void (^menus)(NSString *) = ^(NSString *title) {
        R(@"%@: clut %@ back %@ opacity %@ white %d popup %@ %@", title, v->curCLUTMenu, [v curCLUTMenu], [v curOpacityMenu],
          v->imageView.whiteBackground, [[v->clutPopup itemAtIndex:0] title], [[v->OpacityPopup itemAtIndex:0] title]);
    };
    for (NSString *name in @[@"Ramp", @"Odd", @"No CLUT", @"Missing", @"B/W Inverse"]) { [v ApplyCLUTString:name]; menus(name); }
    [v setFusionMode:4];
    [v ApplyCLUTString:@"Ramp"]; menus(@"Ramp with thick slab");
    [v ApplyCLUTString:@"No CLUT"]; menus(@"No CLUT with thick slab");
    v->backCurCLUTMenu = @"Back"; menus(@"back"); v->backCurCLUTMenu = nil;
    NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:@"Odd" action:nil keyEquivalent:@""] autorelease];
    [v ApplyCLUT:item]; menus(@"menu Odd");

    ViewerController *pet = Viewer(@[Stack(@"pt", 2, 3, 2, AXIAL, 1, 0, NO, NULL)], nil);
    v->blendingController = pet;
    [v ApplyCLUTString:@"Ramp"]; menus(@"PET blending");
    R(@"blending clut after %@", [[NSUserDefaults standardUserDefaults] stringForKey:@"PET Blending CLUT"]);
    v->blendingController = nil;

    v->clutView = [[ColorTransferView alloc] initWithFrame:NSZeroRect];
    [[v->clutView getPoints] addObjectsFromArray:@[@"a", @"b"]]; [[v->clutView getColors] addObjectsFromArray:@[@"red"]];
    [v CLUTChanged:[NSNotification notificationWithName:@"x" object:v->clutView]];
    v->clutName = Field(@"Saved");
    [v endCLUT:Sender(1)]; menus(@"end CLUT");
    NSDictionary *saved = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"CLUT"] objectForKey:@"Saved"];
    NSData *plist = [NSPropertyListSerialization dataWithPropertyList:saved format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    R(@"stored CLUT %@ keys %@", HashBytes(plist.bytes, plist.length), [[saved allKeys] sortedArrayUsingSelector:@selector(compare:)]);
    [v endCLUT:Sender(0)]; menus(@"cancel CLUT");

    NSView *opacityView = [[[NSClassFromString(@"OpacityTransferView") alloc] initWithFrame:NSZeroRect] autorelease];
    v->OpacityView = (id)[opacityView retain];
    for (NSString *name in @[@"Op", @"Linear Table", @"Empty", @"Missing"]) { [v ApplyOpacityString:name]; menus(name); }
    [[opacityView getPoints] addObjectsFromArray:@[@"q1", @"q2"]];
    [v OpacityChanged:[NSNotification notificationWithName:@"x" object:opacityView]];
    v->OpacityName = Field(@"SavedOp");
    [v endOpacity:Sender(1)]; menus(@"end opacity");
    saved = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"OPACITY"] objectForKey:@"SavedOp"];
    plist = [NSPropertyListSerialization dataWithPropertyList:saved format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    R(@"stored opacity %@", HashBytes(plist.bytes, plist.length));
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:domain];
}

static void ThickSlab(void)
{
    R(@"== thick slab");
    NSMutableArray *files = [NSMutableArray array];
    for (int i = 0; i < 4; i++) [files addObject:@{@"name": @"f", @"width": @3, @"height": @2}];
    ViewerController *v = Viewer(@[Stack(@"ts", 4, 3, 2, AXIAL, 1, 0, NO, NULL), Stack(@"ts4D", 4, 3, 2, AXIAL, 1, 0, NO, NULL)],
                                 @[files, [[files mutableCopy] autorelease]]);
    void (^state)(NSString *) = ^(NSString *title) {
        R(@"%@: active %ld slider %d enabled %d stacks %@ thickness %@ slab %d default %ld", title, (long)v->activatedFusion.state, v->sliderFusion.intValue,
          v->sliderFusion.isEnabled, v->stacksFusion.stringValue, [v thicknessInMm], v->thickSlab != nil,
          (long)[[NSUserDefaults standardUserDefaults] integerForKey:@"stackThickness"]);
    };
    for (NSNumber *mode in @[@1, @0, @2, @4, @5, @3]) { [v setFusionMode:mode.longValue]; state([NSString stringWithFormat:@"mode %@", mode]); }
    R(@"getters %d %d", [v sliderFusion] == v->sliderFusion, [v thickSlabController] == v->thickSlab);
    v->sliderFusion.intValue = 5; [v sliderFusionAction:v->sliderFusion]; state(@"slider");
    [v popFusionAction:v->popFusion]; state(@"popup");
    NSButton *off = Sender(0); off.state = NSControlStateValueOff; [v activateFusion:off]; state(@"off");
    NSButton *on = Sender(0); on.state = NSControlStateValueOn; [v activateFusion:on]; state(@"on");
    for (NSNumber *steps in @[@0, @3, @-1, @200, @-300, @2, @-1, @-1]) { [v adjustThickSlabBySteps:steps.integerValue]; state([NSString stringWithFormat:@"steps %@", steps]); }
    [v->fileList[0] replaceObjectAtIndex:2 withObject:@{@"name": @"f", @"width": @4, @"height": @2}];
    [v setFusionMode:1]; state(@"mixed sizes");
    [v->fileList[0] removeAllObjects];
    [v setFusionMode:1]; state(@"no files");
}

int main(int argc, char **argv) { @autoreleasepool {
    [NSApplication sharedApplication];
    double c = cos(0.35), s = sin(0.35);
    float oblique[9] = {1, 0, 0, 0, (float)c, (float)s, 0, (float)-s, (float)c};
    memcpy(OBLIQUE, oblique, sizeof oblique);
    if (argc < 2 || !strcmp(argv[1], "resample")) {
        Resample(@"xyz", 9, 13, 11, AXIAL, 1.5, NO, 1.5, 2, 2, 2);
        Resample(@"z", 6, 8, 8, AXIAL, 2, NO, 2, 1, 1, 0.5f);
        Resample(@"xy", 5, 9, 7, AXIAL, 1, NO, 1, 0.5f, 0.5f, 1);
        Resample(@"flat", 6, 8, 6, AXIAL, 1, NO, 0, 2, 2, 2);
        Resample(@"rgb", 4, 10, 10, AXIAL, 1, YES, 1, 2, 2, 2);
        Resample(@"oblique", 7, 12, 9, OBLIQUE, 1.3, NO, 1.3, 1.5f, 1.25f, 0.75f);
        Resample(@"sagittal", 5, 6, 8, SAGITTAL, -2.2, NO, 2.2, 0.75f, 2, 1.5f);
    }
    if (argc < 2 || !strcmp(argv[1], "interval")) { Intervals(); ThicknessSheet(); }
    if (argc < 2 || !strcmp(argv[1], "subtraction")) Subtraction();
    if (argc < 2 || !strcmp(argv[1], "window")) WindowLevel();
    if (argc < 2 || !strcmp(argv[1], "color")) ColorTables();
    if (argc < 2 || !strcmp(argv[1], "slab")) ThickSlab();
    R(@"== end");
} return 0; }
'''

REFERENCE_PREFIX = r'''
#import "pipeline.h"
#import "Harness-Swift.h"
static float deg2rad = M_PI/180.0;
@implementation ViewerController (Pipeline)
'''

SCENARIOS = ('resample', 'interval', 'subtraction', 'window', 'color', 'slab')
COMMON_FLAGS = ['-fno-objc-arc', '-fobjc-exceptions', '-w', '-I', '.', '-iquote', '.']


def run(command, cwd):
    built = subprocess.run(command, cwd=cwd, capture_output=True, text=True)
    if built.returncode:
        sys.exit('FAIL: %s\n%s' % (' '.join(map(str, command[:3])), (built.stdout + built.stderr)[-6000:]))


def build(folder, name, objc_region, swift_sources, module):
    """The program `name` in `folder`: the stand-ins, the driver, and either the
    Objective-C region or the Swift sources with the IsiXImaging module."""
    folder = Path(folder) / name
    folder.mkdir()
    for header in ('HorosObjCException.h', 'HorosObjCException.m', 'HorosAlertPanel.h'):
        (folder / header).write_bytes((ROOT / 'Horos/Sources' / header).read_bytes())
    (folder / 'HorosCalibration.h').write_text(CALIBRATION_H)
    (folder / 'stubs.h').write_text(STUBS_H)
    (folder / 'stubs.m').write_text(STUBS_M)
    (folder / 'pipeline.h').write_text(PIPELINE_H)
    (folder / 'driver.m').write_text(DRIVER)
    (folder / 'glue.swift').write_text(GLUE)
    objects = []
    for source in ('HorosObjCException.m', 'stubs.m', 'driver.m'):
        run(['xcrun', 'clang', '-c', *COMMON_FLAGS, source, '-o', source + '.o'], folder)
        objects.append(source + '.o')
    swift = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-module-name', 'Harness',
             '-import-objc-header', 'stubs.h', '-Xcc', '-w', '-suppress-warnings']
    if objc_region is not None:
        run([*swift, '-c', 'glue.swift', '-emit-objc-header', '-emit-objc-header-path', 'Harness-Swift.h', '-o', 'glue.o'], folder)
        (folder / 'reference.m').write_text(REFERENCE_PREFIX + objc_region + '\n@end\n', encoding='latin1')
        run(['xcrun', 'clang', '-c', *COMMON_FLAGS, 'reference.m', '-o', 'reference.o'], folder)
        run([*swift, 'glue.o', 'reference.o', *objects, '-framework', 'AppKit', '-framework', 'Accelerate', '-o', name], folder)
    else:
        # IsiXLogging, which IsiXImaging writes its log through, when the revision has it.
        logging = module_sources(args.current, 'IsiXLogging')
        linked = ['-lIsiXLogging'] if logging else []
        if logging:
            (folder / 'IsiXLogging').mkdir()
            for file_name, text in logging.items():
                (folder / 'IsiXLogging' / file_name).write_bytes(text)
            run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-module-name', 'IsiXLogging', '-emit-library',
                 '-static', '-emit-module', '-emit-module-path', 'IsiXLogging.swiftmodule', '-o', 'libIsiXLogging.a',
                 *sorted(str(p) for p in (folder / 'IsiXLogging').iterdir())], folder)
        modules = folder / 'IsiXImaging'
        modules.mkdir()
        for file_name, text in module.items():
            (modules / file_name).write_bytes(text)
        run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-module-name', 'IsiXImaging', '-I', '.', '-emit-library', '-static',
             '-emit-module', '-emit-module-path', 'IsiXImaging.swiftmodule', '-o', 'libIsiXImaging.a',
             *sorted(str(p) for p in modules.iterdir())], folder)
        for file_name, text in swift_sources.items():
            (folder / file_name).write_bytes(text)
        run([*swift, '-I', '.', '-L', '.', '-lIsiXImaging', *linked, 'glue.swift', *swift_sources, *objects,
             '-framework', 'AppKit', '-framework', 'Accelerate', '-o', name], folder)
    return folder / name


failures = []
with tempfile.TemporaryDirectory(prefix='horos-pipeline-equivalence-') as work:
    reference_program = build(work, 'pipeline-reference', region(reference_vc), None, None)
    if current_is_objc:
        current_program = build(work, 'pipeline-current', region(current_vc), None, None)
        kind = 'Objective-C'
    else:
        sources = {}
        for name in SWIFT_FILES:
            text = read(args.current, 'Horos/Sources/' + name)
            if text is None:
                sys.exit('FAIL: Horos/Sources/%s is missing' % name)
            sources[name] = text
        current_program = build(work, 'pipeline-current', None, sources, module_sources(args.current))
        kind = 'Swift'
    for scenario in SCENARIOS:
        outputs = []
        for program in (reference_program, current_program):
            ran = subprocess.run([str(program), scenario], capture_output=True, text=True, timeout=300)
            if ran.returncode:
                failures.append('%s %s: exit %d\n%s' % (program.name, scenario, ran.returncode, (ran.stdout + ran.stderr)[-3000:]))
            outputs.append(ran.stdout.splitlines())
        reference_lines, current_lines = outputs
        if args.dump:
            args.dump.mkdir(parents=True, exist_ok=True)
            for program, lines in zip((reference_program, current_program), outputs):
                (args.dump / ('%s-%s.txt' % (program.name, scenario))).write_text('\n'.join(lines) + '\n')
        if not reference_lines or reference_lines[-1] != '== end':
            failures.append('%s: the reference did not finish' % scenario)
        if any(failure.startswith(tuple('%s %s:' % (p.name, scenario) for p in (reference_program, current_program))) for failure in failures):
            continue
        if reference_lines != current_lines:
            diff = list(difflib.unified_diff(reference_lines, current_lines, 'Objective-C (%s)' % reference, kind, lineterm='', n=2))
            failures.append('%s: the %s differs from the Objective-C:\n%s' % (scenario, kind, '\n'.join(diff[:60])))
        else:
            print('%s: %d records identical (%s against the Objective-C of %s)' % (scenario, len(reference_lines), kind, reference))
        # The records say something: the scenario produced what it is about.
        expected = {'resample': 'volume ', 'interval': 'setSliceInterval', 'subtraction': 'setSubtractedfImage',
                    'window': 'view setWLWW', 'color': 'view setCLUT', 'slab': 'view setFusion'}[scenario]
        if not any(expected in line for line in reference_lines):
            failures.append('%s: no "%s" in the records' % (scenario, expected))

if failures:
    print('FAIL:\n' + '\n\n'.join(failures))
    sys.exit(1)
print('PASS: the image pipeline is identical to the Objective-C in every scenario')
