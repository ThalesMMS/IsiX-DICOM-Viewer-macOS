#!/usr/bin/env python3
"""The 2D viewer's 3D block and key images do what their Objective-C did.

ViewerController's "4.5.3 3D" block (the volume data, the volume of the ROIs,
the checks before a reconstruction and the opening of the VR, SR, orthogonal
MPR, endoscopy, MPR, CPR and region growing viewers) and its key image blocks
moved from ViewerController.m to Swift extensions of the class, with their
arithmetic and rules in the IsiXImaging and IsiXROI modules. This runs the
same synthetic scenarios through both and compares everything they produce:

* the ROI volume: the volume, the error, the contour points in patient
  coordinates (with the floor and ceiling points and the thinning of a large
  contour), the statistics of the values under the ROIs, the ROIs morphed into
  missing slices and their notifications, for valid, invalid, zero-area,
  single and brush ROIs; the volume buffers of each frame, the release of the
  8-bit images and the refresh after a volume changed;
* the checks: why 4D frames, or a fused series, cannot be reconstructed, and
  the opening decision of an MPR for regular, mixed, oblique, irregular,
  empty and unmeasured series;
* the 3D viewers: every message each action sends to the viewer, the 3D
  viewer it brings forward or creates (with which slices, files, volume and
  fused series), the window level, colour and opacity tables it hands over,
  where it places the window and the title it gives it, the alerts, for CT,
  PET (in SUV or not), NM, RGB, 4D, fused and refused series;
* the key images: the check box, the shortcut, all, none and the images with
  ROIs (local and remote database), the state of the controls, the next and
  previous buttons within and across series (flipped or not), and showing only
  the key images.

The reference is the Objective-C of ViewerController.m in the last revision
that has it (history_reference), compiled with clang as Xcode compiles it; the
other side is the current tree: the Swift files with the modules, compiled
with swiftc, or the Objective-C again if the tree still has it (which is how
this test ran, and passed, before the conversion). Both run over the same
stand-ins of the viewer, its views, slices, ROIs and files, the browser and
its database, AppController and the 3D viewers, which record what they are
given, and over the app's own Swift classes for the 4D, MPR opening and ROI
volume rules; the two records must be identical.

    python3 tests/test-viewer-reconstruction-equivalence.py [--reference REV] [--current REV] [--dump DIR]
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
MARK = '- (IBAction) findNextPreviousKeyImage:(id)sender'
SWIFT_FILES = ['ViewerController+%s.swift' % name for name in
               ('ImagePipelineSupport', 'VolumeData', 'ROIVolume', 'ReconstructionChecks', 'ThreeDViewers', 'KeyImages')]
HELPERS = ['FourDSeriesGuard.swift', 'MPROpenGeometry.swift', 'ROIVolumeGeometry.swift', 'ROIIntersliceGeometry.swift']
# IsiXLogging first: the others that log write through it.
MODULES = ['IsiXLogging', 'IsiXImaging', 'IsiXROI']
SCENARIOS = ['volume', 'fourd', 'open3d', 'keyimages']

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--reference')
parser.add_argument('--current')
parser.add_argument('--dump', type=Path, help='write the records of both programs to this folder')
args = parser.parse_args()

HEADER = r'''#pragma clang diagnostic ignored "-Wnullability-completeness"
#import <Cocoa/Cocoa.h>
#import <CoreData/CoreData.h>
#import "HorosObjCException.h"

// The stand-ins of the viewer, its views, slices, files and ROIs, and of the
// classes the 3D and key image blocks talk to (the browser, its database,
// AppController, the 3D viewers), declared as the app's headers declare them,
// so that the Objective-C and the Swift compile against them alike. They
// record what they are given (Record) and answer from their fields. The 4D,
// MPR opening and ROI volume rules are the app's own Swift classes, compiled
// with them.

#define MAX4D 500
typedef NS_ENUM(short, ToolMode) { tWL = 0, tROI = 6, tOval = 9, t2DPoint = 19, tPlain = 20 };

extern NSString* const OsirixAddROINotification;
extern NSString* const OsirixDCMUpdateCurrentImageNotification;

void Record(NSString *line);
NSString *Name(id object);
void Register(id object, NSString *name);
extern NSMutableArray *openControllers;

FOUNDATION_EXPORT NSInteger HorosRunAlertPanel(NSString * _Nullable title, NSString *format,
    NSString * _Nullable defaultButton, NSString * _Nullable alternateButton, NSString * _Nullable otherButton, ...);
FOUNDATION_EXPORT NSInteger HorosRunInformationalAlertPanel(NSString * _Nullable title, NSString *format,
    NSString * _Nullable defaultButton, NSString * _Nullable alternateButton, NSString * _Nullable otherButton, ...);
FOUNDATION_EXPORT NSInteger HorosRunCriticalAlertPanel(NSString * _Nullable title, NSString *format,
    NSString * _Nullable defaultButton, NSString * _Nullable alternateButton, NSString * _Nullable otherButton, ...);
enum {
    HorosAlertDefaultResponse = 1,
    HorosAlertAlternateResponse = 0,
    HorosAlertOtherResponse = -1
};
extern NSInteger informationalResponse;

@interface HorosAlertPanel : NSObject
+ (NSInteger)runWithTitle:(nullable NSString *)title message:(NSString *)message defaultButton:(nullable NSString *)defaultButton
          alternateButton:(nullable NSString *)alternateButton otherButton:(nullable NSString *)otherButton
    NS_SWIFT_NAME(run(title:message:defaultButton:alternateButton:otherButton:));
+ (NSInteger)runInformationalWithTitle:(nullable NSString *)title message:(NSString *)message defaultButton:(nullable NSString *)defaultButton
                       alternateButton:(nullable NSString *)alternateButton otherButton:(nullable NSString *)otherButton
    NS_SWIFT_NAME(runInformational(title:message:defaultButton:alternateButton:otherButton:));
+ (NSInteger)runCriticalWithTitle:(nullable NSString *)title message:(NSString *)message defaultButton:(nullable NSString *)defaultButton
                  alternateButton:(nullable NSString *)alternateButton otherButton:(nullable NSString *)otherButton
    NS_SWIFT_NAME(runCritical(title:message:defaultButton:alternateButton:otherButton:));
@end

@interface NSUserDefaults (HarnessDates)
+ (NSDateFormatter*) dateTimeFormatter;
+ (NSString*) formatDateTime:(NSDate*) date;
@end

@class ViewerController, DCMPix, DCMView, ROI;

@interface MyPoint : NSObject
@property float x, y;
- (void) move:(float) x :(float) y;
@end

@interface DCMPix : NSObject {
@public
    double ox, oy, oz, spacing, sx, sy;
    float vectors[9];
    float values[8];
    long valueCount;
    BOOL rgb, suv;
    float maxValue;
}
@property(nonatomic) long pwidth, pheight;
@property(readonly) double originX, originY, originZ;
@property(readonly) double pixelSpacingX, pixelSpacingY;
@property(readonly) double spacingBetweenSlices;
@property(nonatomic) float minValueOfSeries, maxValueOfSeries;
@property(readonly) BOOL isRGB;
@property BOOL SUVConverted;
- (void) orientation:(float*) c;
- (void) kill8bitsImage;
- (void) changeWLWW:(float)newWL :(float)newWW;
- (float*) getROIValue :(long*) numberOfValues :(ROI*) roi :(float**) locations;
- (void) convertPixX: (float) x pixY: (float) y toDICOMCoords: (float*) d pixelCenter: (BOOL) pixelCenter;
+ (double) skewness: (float*) data length: (long) length mean: (double) mean;
+ (double) kurtosis: (float*) data length: (long) length mean: (double) mean;
@end

@interface ROI : NSObject {
@public
    float area;
    BOOL valid;
    NSMutableArray *spline;
    unsigned char *mask;
    int textureWidth, textureHeight, textureUpLeftCornerX, textureUpLeftCornerY;
    NSPoint centroidValue;
}
@property(retain) NSString *name, *comments;
@property ToolMode type;
@property(nonatomic, retain) DCMPix *pix;
@property(readonly) int textureWidth, textureHeight, textureUpLeftCornerX, textureUpLeftCornerY;
@property(readonly) unsigned char *textureBuffer;
- (BOOL) isValidForVolume;
- (float) roiArea;
- (NSPoint) centroid;
- (NSMutableArray*) splinePoints;
- (void) recompute;
@end

@interface ITKSegmentation3D : NSObject
+ (NSMutableArray*) extractContour:(unsigned char*) map width:(long) width height:(long) height numPoints:(long) numPoints largestRegion:(BOOL) largestRegion;
@end

@interface DicomSeries : NSManagedObject {
@public
    NSMutableSet *keys;
    NSManagedObject *studyValue;
    NSArray *images;
}
- (NSSet*) keyImages;
@end

@interface FileStub : NSManagedObject {
@public
    NSMutableDictionary *values;
}
@end

@interface DCMView : NSView {
@public
    NSInteger curImageValue;
    NSMutableArray *pixListValue;
    float wl, ww;
    DicomSeries *series;
}
@property(readonly) NSInteger curImage;
@property(readonly, retain) DCMPix *curDCM;
@property BOOL flippedData;
@property(readonly) float curWW, curWL;
+ (float) angleBetweenVector: (float*) v1 andVector: (float*) v2;
- (void) setIndex:(NSInteger) index;
- (void) sendSyncMessage:(NSInteger) inc;
- (void) getWLWW:(float*) wl :(float*) ww;
- (void) setWLWW:(float) wl :(float) ww;
- (void) roiSet:(ROI*) roi;
- (DicomSeries *)seriesObj;
@end

@interface ScreenProbe : NSScreen
@property NSRect probeFrame, probeVisibleFrame;
@end

@interface WindowProbe : NSWindow
@property(retain) NSString *probeName;
@property(retain) NSScreen *probeScreen;
@end

@interface OSIWindowController : NSWindowController {
@public
    WindowProbe *probeWindow;
    NSString *nibName;
}
- (NSMutableArray*) pixList;
@end

@interface Window3DController : OSIWindowController {
@public
    NSMutableArray *pixListValue;
    BOOL closing;
}
- (BOOL) windowWillClose;
@end

@interface VRController : Window3DController {
@public
    NSString *styleValue, *modeValue;
}
- (id) initWithPix:(NSMutableArray*) pix :(NSArray*) f :(NSData*) vData :(ViewerController*) bC :(ViewerController*) vC style:(NSString*) m mode:(NSString*) renderingMode;
- (void) addMoviePixList:(NSMutableArray*) pix :(NSData*) vData;
- (void) setMovieFrame: (long) l;
- (void) setWLWW:(float) iwl :(float) iww;
- (void) ApplyCLUTString:(NSString*) str;
- (void) ApplyOpacityString:(NSString*) str;
- (void) load3DState;
- (NSString*) style;
- (NSString *)renderingMode;
- (IBAction) setModeIndex:(long) val;
@end

@interface SRController : Window3DController
- (id) initWithPix:(NSMutableArray*) pix :(NSArray*) f :(NSData*) vData :(ViewerController*) bC :(ViewerController*) vC;
- (void) ChangeSettings:(id) sender;
@end

@interface OrthogonalMPRView : NSView
@end

@interface OrthogonalMPRPETCTView : OrthogonalMPRView
- (void) setCurCLUTMenu:(NSString*) clut;
- (void) setCurOpacityMenu:(NSString*) o;
@end

@interface OrthogonalMPRPETCTController : NSObject {
@public
    NSString *label;
    OrthogonalMPRPETCTView *views[3];
}
- (void) ApplyCLUTString:(NSString*) str;
- (void) ApplyOpacityString:(NSString*) str;
- (void) setWLWW:(float) iwl :(float) iww;
- (OrthogonalMPRView*) originalView;
- (OrthogonalMPRView*) xReslicedView;
- (OrthogonalMPRView*) yReslicedView;
@end

// The Swift classes of the app, with the parameter types their Swift
// declarations give them.
@interface OrthogonalMPRViewer : Window3DController
- (id) initWithPixList:(NSMutableArray*) pix :(NSMutableArray*) files :(id) vData :(ViewerController*) vC :(ViewerController*) bC;
- (void) ApplyCLUTString:(NSString*) str;
- (void) ApplyOpacityString:(NSString*) str;
- (void) setWLWW:(float) iwl :(float) iww;
@end

@interface OrthogonalMPRPETCTViewer : Window3DController
- (id) initWithPixList:(NSMutableArray*) pix :(NSMutableArray*) files :(id) vData :(ViewerController*) vC :(ViewerController*) bC;
@property(readonly) OrthogonalMPRPETCTController *CTController NS_SWIFT_NAME(CTController);
@property(readonly) OrthogonalMPRPETCTController *PETController NS_SWIFT_NAME(PETController);
@property(readonly) OrthogonalMPRPETCTController *PETCTController NS_SWIFT_NAME(PETCTController);
- (void) setBlendingMode:(NSInteger) m;
@end

@interface EndoscopyViewer : Window3DController
- (id) initWithPixList:(NSMutableArray*) pix :(NSMutableArray*) files :(id) vData :(ViewerController*) bC :(ViewerController*) vC;
@end

@interface MPRController : Window3DController
- (nullable id) initWithDCMPixList:(NSMutableArray*) pix filesList:(NSMutableArray*) files volumeData:(id) volume viewerController:(ViewerController*) viewer fusedViewerController:(ViewerController*) fusedViewer;
- (void) addMoviePixList:(NSMutableArray*) pix :(id) vData;
@end

@interface CPRController : Window3DController
- (nullable id) initWithDCMPixList:(NSMutableArray*) pix filesList:(NSMutableArray*) files volumeData:(id) volume viewerController:(ViewerController*) viewer fusedViewerController:(ViewerController*) fusedViewer;
- (void) addMoviePixList:(NSMutableArray*) pix :(id) vData;
@end

@interface ITKSegmentation3DController : NSWindowController
// The window a viewer already has; the stand-in never has one, as its
// -initWithViewer:, which the Objective-C viewer called alone, never reused one.
+ (nullable ITKSegmentation3DController*) segmentationControllerForViewer:(ViewerController*) v;
// Not optional, as the Swift class's initializer.
- (nonnull id) initWithViewer:(ViewerController*) v;
@end

@interface AppController : NSObject
+ (AppController*) sharedAppController NS_SWIFT_NAME(shared());
- (id) FindViewer :(NSString*) nib :(id) pixList NS_SWIFT_NAME(FindViewer(_:_:));
- (NSArray*) FindRelatedViewers:(id) pixList NS_SWIFT_NAME(FindRelatedViewers(_:));
@end

@interface DicomDatabase : NSObject
- (BOOL) save:(NSError**) err NS_SWIFT_NOTHROW;
@end

@interface RemoteDicomDatabase : DicomDatabase
- (void) object:(NSManagedObject*) object setValue:(id) value forKey:(NSString*) key;
@end

@interface BrowserController : NSObject {
@public
    BOOL bonjour;
    NSArray *seriesOfStudy;
}
+ (BrowserController*) currentBrowser;
@property(readonly) BOOL isCurrentDatabaseBonjour;
@property(readonly, retain) DicomDatabase *database;
- (NSArray*) childrenArray: (id) item;
- (ViewerController*) loadSeries :(NSManagedObject *)curFile :(ViewerController*) viewer :(BOOL) firstViewer keyImagesOnly:(BOOL) keyImages;
- (ViewerController*) openViewerFromImages:(NSArray*) toOpenArray movie:(BOOL) movieViewer viewer:(ViewerController*) viewer keyImagesOnly:(BOOL) keyImages;
@end

NS_SWIFT_UI_ACTOR
@interface ViewerController : OSIWindowController {
@public
    NSString *nameValue, *modalityValue;
    DCMView *imageView;
    NSMutableArray *pixList[MAX4D], *fileList[MAX4D], *roiList[MAX4D];
    NSData *volumeData[MAX4D];
    short curMovieIndex, maxMovieIndex;
    ViewerController *blendingController;
    NSString *curConvMenu, *curCLUTMenu, *backCurCLUTMenu, *curOpacityMenu;
    BOOL postprocessed, displayOnlyKeyImages, volumic, volumicWithoutTime;
    float interval;
    NSButton *keyImageCheck;
    NSPopUpButton *keyImagePopUpButton;
    NSMutableArray *morphs;
}
@property(readonly) NSButton *keyImageCheck;
- (DCMView*) imageView;
- (NSString*) modality;
- (NSString*) curCLUTMenu;
- (NSString*) curOpacityMenu;
- (ViewerController*) blendingController NS_SWIFT_NAME(blending());
- (short) maxMovieIndex;
- (short) curMovieIndex;
- (void) setMovieIndex: (short) i;
- (void) checkEverythingLoaded;
- (BOOL) isDataVolumicIn4D:(BOOL) check4D;
- (float) computeInterval;
- (IBAction) SetThicknessInterval:(id) sender NS_SWIFT_NAME(setThicknessInterval(_:));
- (void) displayAWarningIfNonTrueVolumicData;
- (void) displayWarningIfGantryTitled;
- (IBAction) MovieStop:(id) sender NS_SWIFT_NAME(movieStop(_:));
- (IBAction) applyConvolutionOnSource:(id) sender;
- (IBAction) updateImage:(id) sender;
- (void) roiDeleteGeneratedROIsForName:(NSString*) name;
- (ROI*) roiMorphingBetween:(ROI*) a and:(ROI*) b ratio:(float) ratio;
- (void) adjustSlider;
- (void) showCurrentThumbnail:(id) sender;
- (void) updateNavigator;
- (void) buildMatrixPreview: (BOOL) showSelected;
- (id) startWaitWindow :(NSString*) message;
- (void) endWaitWindow:(id) waitWindow;
// The accessors of ViewerController+SwiftIvars.h, on the same instance variables.
@property(retain, nullable) DCMView* horos_imageView;
@property(assign) short horos_curMovieIndex NS_SWIFT_NONISOLATED;
@property(assign) short horos_maxMovieIndex NS_SWIFT_NONISOLATED;
- (nullable NSMutableArray<DCMPix *>*)horos_pixListAt:(NSInteger)index NS_SWIFT_NONISOLATED;
- (nullable NSMutableArray*)horos_fileListAt:(NSInteger)index NS_SWIFT_NONISOLATED;
- (nullable NSMutableArray<NSMutableArray<ROI *> *>*)horos_roiListAt:(NSInteger)index;
- (nullable NSObject*)horos_volumeDataAt:(NSInteger)index;
@property(retain, nullable) ViewerController* horos_blendingController;
@property(retain, nullable) NSString* horos_curConvMenu;
@property(retain, nullable) NSString* horos_curCLUTMenu;
@property(retain, nullable) NSString* horos_backCurCLUTMenu;
@property(retain, nullable) NSString* horos_curOpacityMenu;
@property(assign) BOOL horos_postprocessed;
@property(assign) BOOL horos_displayOnlyKeyImages;
@property(readonly, nullable) NSPopUpButton* horos_keyImagePopUpButton;
@end
'''

RECONSTRUCTION = r'''// The blocks under test, as the Objective-C of the class declared them.
@interface ViewerController (Reconstruction)
- (float*) volumePtr;
- (float*) volumePtr: (long) i;
- (NSData*)volumeData;
- (NSData*)volumeData:(long) i;
- (void) clear8bitRepresentations;
- (void) updateVolumeData: (NSNotification*) note;
- (float) computeVolume:(ROI*) selectedRoi points:(NSMutableArray**) pts error:(NSString**) error;
- (float) computeVolume:(ROI*) selectedRoi points:(NSMutableArray**) pts generateMissingROIs:(BOOL) generateMissingROIs error:(NSString**) error;
- (float) computeVolume:(ROI*) selectedRoi points:(NSMutableArray**) pts generateMissingROIs:(BOOL) generateMissingROIs generatedROIs:(NSMutableArray*) generatedROIs computeData:(NSMutableDictionary*) data error:(NSString**) error;
- (NSString *)fourDReconstructionRefusalReason;
- (BOOL) refuseFourDReconstructionWithTitle: (NSString *) title;
- (NSString *)fourDFusionRefusalReasonForOverlay: (ViewerController *) overlay;
- (NSString *)fourDFusionRefusalReason;
- (BOOL) refuseFourDFusionWithTitle: (NSString *) title;
- (id) reconstructionOpeningDecision;
- (NSScreen*) get3DViewerScreen: (ViewerController*) v;
- (void) place3DViewerWindow:(NSWindowController*) viewer;
- (IBAction) Panel3D:(id) sender;
- (IBAction) segmentationTest:(id) sender;
- (VRController *)openVRViewerForMode:(NSString *)mode;
- (IBAction) VRViewer:(id) sender;
- (SRController *)openSRViewer;
- (IBAction) SRViewer:(id) sender;
- (OrthogonalMPRViewer *)openOrthogonalMPRViewer;
- (OrthogonalMPRPETCTViewer *)openOrthogonalMPRPETCTViewer;
- (IBAction) orthogonalMPRViewer:(id) sender;
- (EndoscopyViewer *)openEndoscopyViewer;
- (IBAction) endoscopyViewer:(id) sender;
- (MPRController *)openMPRViewer;
- (IBAction)mprViewer:(id)sender;
- (id)openCPRViewer;
- (IBAction)cprViewer:(id)sender;
- (IBAction) keyImageCheckBox:(id) sender;
- (IBAction) findNextPreviousKeyImage:(id)sender;
- (IBAction) keyImageDisplayButton:(id) sender;
- (IBAction) setROIsImagesKeyImages:(id)sender;
- (IBAction) setAllNonKeyImages:(id)sender;
- (IBAction) setAllKeyImages:(id)sender;
- (IBAction) setKeyImage:(id)sender;
- (void) adjustKeyImage;
- (BOOL)isKeyImage:(int)index;
- (BOOL)displayOnlyKeyImages;
@end
'''

STUBS = r'''#import "Harness.h"

NSString* const OsirixAddROINotification = @"OsirixAddROINotification";
NSString* const OsirixDCMUpdateCurrentImageNotification = @"OsirixDCMUpdateCurrentImageNotification";
NSInteger informationalResponse = HorosAlertDefaultResponse;

static NSMapTable *names;
NSMutableArray *openControllers;
static BrowserController *theBrowser;
static AppController *theApp;

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
    if ([object isKindOfClass: [NSArray class]]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (id item in object) [parts addObject: Name(item)];
        return [NSString stringWithFormat: @"[%@]", [parts componentsJoinedByString: @","]];
    }
    return [NSString stringWithFormat: @"<%@>", NSStringFromClass([object class])];
}

void Record(NSString *line) {
    printf("%s\n", line.UTF8String);
}

static NSString *F(double x) { return [NSString stringWithFormat: @"%a", x]; }

void NSBeep(void) { Record(@"beep"); }

NSInteger HorosRunAlertPanel(NSString *title, NSString *format, NSString *d, NSString *a, NSString *o, ...) {
    va_list arguments; va_start(arguments, o);
    NSString *message = [[[NSString alloc] initWithFormat: format arguments: arguments] autorelease];
    va_end(arguments);
    return [HorosAlertPanel runWithTitle: title message: message defaultButton: d alternateButton: a otherButton: o];
}
NSInteger HorosRunInformationalAlertPanel(NSString *title, NSString *format, NSString *d, NSString *a, NSString *o, ...) {
    va_list arguments; va_start(arguments, o);
    NSString *message = [[[NSString alloc] initWithFormat: format arguments: arguments] autorelease];
    va_end(arguments);
    return [HorosAlertPanel runInformationalWithTitle: title message: message defaultButton: d alternateButton: a otherButton: o];
}
NSInteger HorosRunCriticalAlertPanel(NSString *title, NSString *format, NSString *d, NSString *a, NSString *o, ...) {
    va_list arguments; va_start(arguments, o);
    NSString *message = [[[NSString alloc] initWithFormat: format arguments: arguments] autorelease];
    va_end(arguments);
    return [HorosAlertPanel runCriticalWithTitle: title message: message defaultButton: d alternateButton: a otherButton: o];
}

@implementation HorosAlertPanel
+ (NSInteger)runWithTitle:(NSString *)title message:(NSString *)message defaultButton:(NSString *)d alternateButton:(NSString *)a otherButton:(NSString *)o {
    Record([NSString stringWithFormat: @"alert: %@ | %@ | %@ %@ %@", title, message, d, a, o]); return HorosAlertDefaultResponse;
}
+ (NSInteger)runInformationalWithTitle:(NSString *)title message:(NSString *)message defaultButton:(NSString *)d alternateButton:(NSString *)a otherButton:(NSString *)o {
    Record([NSString stringWithFormat: @"informational alert: %@ | %@ | %@ %@ %@ -> %ld", title, message, d, a, o, (long)informationalResponse]);
    return informationalResponse;
}
+ (NSInteger)runCriticalWithTitle:(NSString *)title message:(NSString *)message defaultButton:(NSString *)d alternateButton:(NSString *)a otherButton:(NSString *)o {
    Record([NSString stringWithFormat: @"critical alert: %@ | %@ | %@ %@ %@", title, message, d, a, o]); return HorosAlertDefaultResponse;
}
@end

@implementation NSUserDefaults (HarnessDates)
+ (NSDateFormatter*) dateTimeFormatter {
    NSDateFormatter *formatter = [[NSDateFormatter new] autorelease];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm"; formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT: 0];
    return formatter;
}
+ (NSString*) formatDateTime:(NSDate*) date { return date ? [NSString stringWithFormat: @"formatted %@", [[self dateTimeFormatter] stringFromDate: date]] : nil; }
@end

@implementation MyPoint
- (void) move:(float) x :(float) y { self.x += x; self.y += y; }
@end

@implementation DCMPix
@synthesize pwidth, pheight, minValueOfSeries, maxValueOfSeries, SUVConverted;
- (double) originX { return ox; }
- (double) originY { return oy; }
- (double) originZ { return oz; }
- (double) pixelSpacingX { return sx; }
- (double) pixelSpacingY { return sy; }
- (double) spacingBetweenSlices { return spacing; }
- (BOOL) isRGB { return rgb; }
- (void) orientation:(float*) c { for (int i = 0; i < 9; i++) c[i] = vectors[i]; }
- (void) kill8bitsImage { Record([NSString stringWithFormat: @"%@ kill8bitsImage", Name(self)]); }
- (void) changeWLWW:(float) newWL :(float) newWW { Record([NSString stringWithFormat: @"%@ changeWLWW %@ %@", Name(self), F(newWL), F(newWW)]); }
- (float*) getROIValue :(long*) numberOfValues :(ROI*) roi :(float**) locations {
    Record([NSString stringWithFormat: @"%@ getROIValue %@", Name(self), Name(roi)]);
    if (valueCount == 0) { *numberOfValues = 0; return NULL; }
    float *copy = malloc(valueCount * sizeof(float));
    for (long i = 0; i < valueCount; i++) copy[i] = values[i] + roi->area;
    *numberOfValues = valueCount;
    return copy;
}
- (void) convertPixX: (float) x pixY: (float) y toDICOMCoords: (float*) d pixelCenter: (BOOL) pixelCenter {
    d[0] = ox + x * sx + (pixelCenter ? 0.25 : 0); d[1] = oy + y * sy; d[2] = oz + x * 0.125f;
}
+ (double) skewness: (float*) data length: (long) length mean: (double) mean {
    double s = 0; for (long i = 0; i < length; i++) s += (data[i] - mean) * (data[i] - mean) * (data[i] - mean); return s / length;
}
+ (double) kurtosis: (float*) data length: (long) length mean: (double) mean {
    double s = 0; for (long i = 0; i < length; i++) s += pow(data[i] - mean, 4); return s / length;
}
@end

@implementation ROI
@synthesize name, comments, type, pix, textureWidth, textureHeight, textureUpLeftCornerX, textureUpLeftCornerY;
- (unsigned char*) textureBuffer { return mask; }
- (BOOL) isValidForVolume { return valid; }
- (float) roiArea { return area; }
- (NSPoint) centroid { return centroidValue; }
- (NSMutableArray*) splinePoints { return spline; }
- (void) recompute { Record([NSString stringWithFormat: @"%@ recompute", Name(self)]); }
- (void) setPix:(DCMPix *)p { [pix release]; pix = [p retain]; Record([NSString stringWithFormat: @"%@ setPix %@", Name(self), Name(p)]); }
- (void) setComments:(NSString *)c { [comments release]; comments = [c retain]; Record([NSString stringWithFormat: @"%@ setComments %@", Name(self), c]); }
- (void) setName:(NSString *)n { [name release]; name = [n retain]; Record([NSString stringWithFormat: @"%@ setName %@", Name(self), n]); }
@end

@implementation ITKSegmentation3D
+ (NSMutableArray*) extractContour:(unsigned char*) map width:(long) width height:(long) height numPoints:(long) numPoints largestRegion:(BOOL) largestRegion {
    NSMutableArray *points = [NSMutableArray array];
    for (long i = 0; i < width * height; i++) if (map[i]) {
        MyPoint *p = [[MyPoint new] autorelease]; p.x = i % width; p.y = i / width; [points addObject: p];
    }
    return points;
}
@end

@implementation DicomSeries
- (NSSet*) keyImages { return keys; }
- (id) valueForKey:(NSString *)key {
    if ([key isEqualToString: @"study"]) return studyValue;
    if ([key isEqualToString: @"images"]) return images;
    return [super valueForKey: key];
}
@end

@implementation FileStub
- (id) valueForKey:(NSString *) key { return values[key]; }
- (id) valueForKeyPath:(NSString *) key { return values[key]; }
- (void) setValue:(id) value forKey:(NSString *) key {
    Record([NSString stringWithFormat: @"%@ %@ = %@", Name(self), key, Name(value)]);
    if (value) values[key] = value; else [values removeObjectForKey: key];
}
@end

@implementation DCMView
@synthesize flippedData;
- (NSInteger) curImage { return curImageValue; }
- (DCMPix*) curDCM { return curImageValue >= 0 && curImageValue < (long)pixListValue.count ? pixListValue[curImageValue] : nil; }
- (float) curWW { return ww; }
- (float) curWL { return wl; }
+ (float) angleBetweenVector: (float*) a andVector: (float*) b {
    float d = a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
    return acosf(fmaxf(-1, fminf(1, d))) * 180 / M_PI;
}
- (void) setIndex:(NSInteger) index { curImageValue = index; Record([NSString stringWithFormat: @"%@ setIndex %ld", Name(self), (long)index]); }
- (void) sendSyncMessage:(NSInteger) inc { Record([NSString stringWithFormat: @"%@ sendSyncMessage %ld", Name(self), (long)inc]); }
- (void) displayIfNeeded { Record([NSString stringWithFormat: @"%@ displayIfNeeded", Name(self)]); }
- (void) setNeedsDisplay:(BOOL) flag { Record([NSString stringWithFormat: @"%@ setNeedsDisplay %d", Name(self), flag]); }
- (void) getWLWW:(float*) l :(float*) w { *l = wl; *w = ww; }
- (void) setWLWW:(float) l :(float) w { wl = l; ww = w; Record([NSString stringWithFormat: @"%@ setWLWW %@ %@", Name(self), F(l), F(w)]); }
- (void) roiSet:(ROI*) roi { Record([NSString stringWithFormat: @"%@ roiSet %@", Name(self), Name(roi)]); }
- (DicomSeries *)seriesObj { return series; }
@end

@implementation ScreenProbe
@synthesize probeFrame, probeVisibleFrame;
- (NSRect) frame { return probeFrame; }
- (NSRect) visibleFrame { return probeVisibleFrame; }
@end

@implementation WindowProbe
@synthesize probeName, probeScreen;
- (void) setTitle:(NSString *) title { [super setTitle: title]; Record([NSString stringWithFormat: @"%@ title \"%@\"", probeName, title]); }
- (void) makeKeyAndOrderFront:(id) sender { Record([NSString stringWithFormat: @"%@ makeKeyAndOrderFront %@", probeName, Name(sender)]); }
- (void) display { Record([NSString stringWithFormat: @"%@ display", probeName]); }
- (void) setFrame:(NSRect) r display:(BOOL) flag {
    Record([NSString stringWithFormat: @"%@ setFrame %@ display %d", probeName, NSStringFromRect(r), flag]);
}
- (void) setFrameOrigin:(NSPoint) p { Record([NSString stringWithFormat: @"%@ setFrameOrigin %@", probeName, NSStringFromPoint(p)]); }
- (NSRect) frame { return NSMakeRect(11, 22, 333, 444); }
- (NSScreen*) screen { return probeScreen; }
@end

static WindowProbe *Window(NSString *name) {
    WindowProbe *w = [[WindowProbe alloc] initWithContentRect: NSMakeRect(0, 0, 100, 100) styleMask: NSWindowStyleMaskTitled
                                                       backing: NSBackingStoreBuffered defer: YES];
    w.releasedWhenClosed = NO;
    w.probeName = name;
    [w setTitle: name];
    return w;
}

@implementation OSIWindowController
- (NSWindow*) window { return probeWindow; }
- (NSString*) windowNibName { return nibName; }
- (void) showWindow:(id) sender { Record([NSString stringWithFormat: @"%@ showWindow %@", Name(self), Name(sender)]); }
- (NSMutableArray*) pixList { return nil; }
@end

static NSString *Args(NSArray *items) {
    NSMutableArray *parts = [NSMutableArray array];
    for (id item in items) [parts addObject: item == [NSNull null] ? @"nil" : Name(item)];
    return [parts componentsJoinedByString: @" "];
}
#define N(x) ((x) ? (id)(x) : (id)[NSNull null])

static int created;

@implementation Window3DController
- (id) initKind:(NSString *) kind nib:(NSString *) nib pix:(NSMutableArray *) pix {
    self = [super initWithWindow: nil];
    created++;
    NSString *name = [NSString stringWithFormat: @"%@#%d", kind, created];
    Register(self, name);
    nibName = [nib retain];
    probeWindow = Window([name stringByAppendingString: @".window"]);
    pixListValue = [pix retain];
    [openControllers addObject: self];
    return self;
}
- (BOOL) windowWillClose { return closing; }
- (NSMutableArray*) pixList { return pixListValue; }
@end

@implementation VRController
- (id) initWithPix:(NSMutableArray*) pix :(NSArray*) f :(NSData*) vData :(ViewerController*) bC :(ViewerController*) vC style:(NSString*) m mode:(NSString*) mode {
    self = [self initKind: @"VR" nib: @"VR" pix: pix];
    styleValue = [m retain]; modeValue = [mode retain];
    Record([NSString stringWithFormat: @"%@ init %@ style %@ mode %@", Name(self), Args(@[N(pix), N(f), N(vData), N(bC), N(vC)]), m, mode]);
    return self;
}
- (void) addMoviePixList:(NSMutableArray*) pix :(NSData*) vData { Record([NSString stringWithFormat: @"%@ addMoviePixList %@ %@", Name(self), Name(pix), Name(vData)]); }
- (void) setMovieFrame: (long) l { Record([NSString stringWithFormat: @"%@ setMovieFrame %ld", Name(self), l]); }
- (void) setWLWW:(float) l :(float) w { Record([NSString stringWithFormat: @"%@ setWLWW %@ %@", Name(self), F(l), F(w)]); }
- (void) ApplyCLUTString:(NSString*) str { Record([NSString stringWithFormat: @"%@ ApplyCLUTString %@", Name(self), str]); }
- (void) ApplyOpacityString:(NSString*) str { Record([NSString stringWithFormat: @"%@ ApplyOpacityString %@", Name(self), str]); }
- (void) load3DState { Record([NSString stringWithFormat: @"%@ load3DState", Name(self)]); }
- (NSString*) style { return styleValue; }
- (NSString*) renderingMode { return modeValue; }
- (IBAction) setModeIndex:(long) val { Record([NSString stringWithFormat: @"%@ setModeIndex %ld", Name(self), val]); }
@end

@implementation SRController
- (id) initWithPix:(NSMutableArray*) pix :(NSArray*) f :(NSData*) vData :(ViewerController*) bC :(ViewerController*) vC {
    self = [self initKind: @"SR" nib: @"SR" pix: pix];
    Record([NSString stringWithFormat: @"%@ init %@", Name(self), Args(@[N(pix), N(f), N(vData), N(bC), N(vC)])]);
    return self;
}
- (void) ChangeSettings:(id) sender { Record([NSString stringWithFormat: @"%@ ChangeSettings %@", Name(self), Name(sender)]); }
@end

@implementation OrthogonalMPRView
@end

@implementation OrthogonalMPRPETCTView
- (void) setCurCLUTMenu:(NSString*) clut { Record([NSString stringWithFormat: @"%@ setCurCLUTMenu %@", Name(self), clut]); }
- (void) setCurOpacityMenu:(NSString*) o { Record([NSString stringWithFormat: @"%@ setCurOpacityMenu %@", Name(self), o]); }
@end

@implementation OrthogonalMPRPETCTController
- (id) initWithLabel:(NSString *) l {
    self = [super init];
    label = [l retain];
    Register(self, l);
    NSArray *viewNames = @[@"original", @"x", @"y"];
    for (int i = 0; i < 3; i++) {
        views[i] = [[OrthogonalMPRPETCTView alloc] initWithFrame: NSZeroRect];
        Register(views[i], [NSString stringWithFormat: @"%@.%@", l, viewNames[i]]);
    }
    return self;
}
- (void) ApplyCLUTString:(NSString*) str { Record([NSString stringWithFormat: @"%@ ApplyCLUTString %@", label, str]); }
- (void) ApplyOpacityString:(NSString*) str { Record([NSString stringWithFormat: @"%@ ApplyOpacityString %@", label, str]); }
- (void) setWLWW:(float) l :(float) w { Record([NSString stringWithFormat: @"%@ setWLWW %@ %@", label, F(l), F(w)]); }
- (OrthogonalMPRView*) originalView { return views[0]; }
- (OrthogonalMPRView*) xReslicedView { return views[1]; }
- (OrthogonalMPRView*) yReslicedView { return views[2]; }
@end

@implementation OrthogonalMPRViewer
- (id) initWithPixList:(NSMutableArray*) pix :(NSMutableArray*) files :(id) vData :(ViewerController*) vC :(ViewerController*) bC {
    self = [self initKind: @"OrthogonalMPR" nib: @"OrthogonalMPR" pix: pix];
    Record([NSString stringWithFormat: @"%@ init %@", Name(self), Args(@[N(pix), N(files), N(vData), N(vC), N(bC)])]);
    return self;
}
- (void) ApplyCLUTString:(NSString*) str { Record([NSString stringWithFormat: @"%@ ApplyCLUTString %@", Name(self), str]); }
- (void) ApplyOpacityString:(NSString*) str { Record([NSString stringWithFormat: @"%@ ApplyOpacityString %@", Name(self), str]); }
- (void) setWLWW:(float) l :(float) w { Record([NSString stringWithFormat: @"%@ setWLWW %@ %@", Name(self), F(l), F(w)]); }
@end

@implementation OrthogonalMPRPETCTViewer {
    OrthogonalMPRPETCTController *controllers[3];
}
- (id) initWithPixList:(NSMutableArray*) pix :(NSMutableArray*) files :(id) vData :(ViewerController*) vC :(ViewerController*) bC {
    self = [self initKind: @"PETCT" nib: @"PETCT" pix: pix];
    Record([NSString stringWithFormat: @"%@ init %@", Name(self), Args(@[N(pix), N(files), N(vData), N(vC), N(bC)])]);
    NSArray *labels = @[@"CT", @"PET", @"PETCT"];
    for (int i = 0; i < 3; i++) controllers[i] = [[OrthogonalMPRPETCTController alloc] initWithLabel: [NSString stringWithFormat: @"%@.%@", Name(self), labels[i]]];
    return self;
}
- (OrthogonalMPRPETCTController*) CTController { return controllers[0]; }
- (OrthogonalMPRPETCTController*) PETController { return controllers[1]; }
- (OrthogonalMPRPETCTController*) PETCTController { return controllers[2]; }
- (void) setBlendingMode:(NSInteger) m { Record([NSString stringWithFormat: @"%@ setBlendingMode %ld", Name(self), (long)m]); }
@end

@implementation EndoscopyViewer
- (id) initWithPixList:(NSMutableArray*) pix :(NSMutableArray*) files :(id) vData :(ViewerController*) bC :(ViewerController*) vC {
    self = [self initKind: @"Endoscopy" nib: @"Endoscopy" pix: pix];
    Record([NSString stringWithFormat: @"%@ init %@", Name(self), Args(@[N(pix), N(files), N(vData), N(bC), N(vC)])]);
    return self;
}
@end

@implementation MPRController
- (id) initWithDCMPixList:(NSMutableArray*) pix filesList:(NSMutableArray*) files volumeData:(id) volume viewerController:(ViewerController*) viewer fusedViewerController:(ViewerController*) fused {
    self = [self initKind: @"MPR" nib: @"MPR" pix: pix];
    Record([NSString stringWithFormat: @"%@ init %@", Name(self), Args(@[N(pix), N(files), N(volume), N(viewer), N(fused)])]);
    return self;
}
- (void) addMoviePixList:(NSMutableArray*) pix :(id) vData { Record([NSString stringWithFormat: @"%@ addMoviePixList %@ %@", Name(self), Name(pix), Name(vData)]); }
@end

@implementation CPRController
- (id) initWithDCMPixList:(NSMutableArray*) pix filesList:(NSMutableArray*) files volumeData:(id) volume viewerController:(ViewerController*) viewer fusedViewerController:(ViewerController*) fused {
    self = [self initKind: @"CPR" nib: @"CPR" pix: pix];
    Record([NSString stringWithFormat: @"%@ init %@", Name(self), Args(@[N(pix), N(files), N(volume), N(viewer), N(fused)])]);
    return self;
}
- (void) addMoviePixList:(NSMutableArray*) pix :(id) vData { Record([NSString stringWithFormat: @"%@ addMoviePixList %@ %@", Name(self), Name(pix), Name(vData)]); }
@end

@implementation ITKSegmentation3DController {
    WindowProbe *probe;
}
+ (ITKSegmentation3DController*) segmentationControllerForViewer:(ViewerController*) v { return nil; }
- (id) initWithViewer:(ViewerController*) v {
    self = [super initWithWindow: nil];
    Register(self, @"ITKSegmentation");
    probe = Window(@"ITKSegmentation.window");
    Record([NSString stringWithFormat: @"ITKSegmentation init %@", Name(v)]);
    return self;
}
- (NSWindow*) window { return probe; }
- (void) showWindow:(id) sender { Record([NSString stringWithFormat: @"ITKSegmentation showWindow %@", Name(sender)]); }
@end

@implementation AppController
+ (AppController*) sharedAppController { if (!theApp) theApp = [AppController new]; return theApp; }
- (id) FindViewer :(NSString*) nib :(id) pixList {
    for (Window3DController *c in openControllers)
        if ([c.windowNibName isEqualToString: nib] && c.pixList == pixList && !c->closing) return c;
    return nil;
}
- (NSArray*) FindRelatedViewers:(id) pixList {
    NSMutableArray *found = [NSMutableArray array];
    for (Window3DController *c in openControllers) if (c.pixList == pixList) [found addObject: c];
    return found;
}
@end

@implementation DicomDatabase
- (BOOL) save:(NSError**) err { Record(@"database save"); return YES; }
@end

@implementation RemoteDicomDatabase
- (void) object:(NSManagedObject*) object setValue:(id) value forKey:(NSString*) key {
    Record([NSString stringWithFormat: @"remote %@ %@ = %@", Name(object), key, Name(value)]);
}
@end

@implementation BrowserController {
    DicomDatabase *local, *remote;
}
+ (BrowserController*) currentBrowser {
    if (!theBrowser) {
        theBrowser = [BrowserController new];
        theBrowser->local = [DicomDatabase new];
        theBrowser->remote = [RemoteDicomDatabase new];
    }
    return theBrowser;
}
- (BOOL) isCurrentDatabaseBonjour { return bonjour; }
- (DicomDatabase*) database { return bonjour ? remote : local; }
- (NSArray*) childrenArray: (id) item {
    Record([NSString stringWithFormat: @"browser childrenArray %@", Name(item)]);
    if ([item isKindOfClass: [DicomSeries class]]) return [item valueForKey: @"images"];
    return seriesOfStudy;
}
@end

'''

DRIVER = r'''#import "Harness.h"


static NSString *F(double x) { return [NSString stringWithFormat: @"%a", x]; }
static NSEntityDescription *imageEntity, *seriesEntity;
static NSMutableDictionary *seriesContent;

// ---------------------------------------------------------------- viewer

@implementation ViewerController
@synthesize keyImageCheck;
- (id) initNamed:(NSString *) name {
    self = [super initWithWindow: nil];
    nameValue = [name retain];
    modalityValue = @"CT";
    Register(self, name);
    probeWindow = [[WindowProbe alloc] initWithContentRect: NSMakeRect(0, 0, 100, 100) styleMask: NSWindowStyleMaskTitled backing: NSBackingStoreBuffered defer: YES];
    probeWindow.releasedWhenClosed = NO;
    probeWindow.probeName = [name stringByAppendingString: @".window"];
    [probeWindow setTitle: [name stringByAppendingString: @" title"]];
    ScreenProbe *screen = [ScreenProbe alloc];
    screen.probeFrame = NSMakeRect(0, 0, 1000, 800); screen.probeVisibleFrame = NSMakeRect(0, 25, 1000, 750);
    probeWindow.probeScreen = screen;
    imageView = [[DCMView alloc] initWithFrame: NSMakeRect(0, 0, 10, 10)];
    Register(imageView, [name stringByAppendingString: @".view"]);
    curConvMenu = @"No Filter"; curCLUTMenu = @"No CLUT"; curOpacityMenu = @"Linear Table";
    volumic = YES; volumicWithoutTime = YES; interval = 1.5f;
    keyImageCheck = [[NSButton alloc] initWithFrame: NSZeroRect];
    [keyImageCheck setButtonType: NSButtonTypeSwitch];
    Register(keyImageCheck, [name stringByAppendingString: @".keyImageCheck"]);
    keyImagePopUpButton = [[NSPopUpButton alloc] initWithFrame: NSZeroRect pullsDown: NO];
    [keyImagePopUpButton addItemsWithTitles: @[@"All images", @"Key images"]];
    return self;
}
- (DCMView*) imageView { return imageView; }
- (NSString*) modality { return modalityValue; }
- (NSString*) curCLUTMenu { return curCLUTMenu; }
- (NSString*) curOpacityMenu { return curOpacityMenu; }
- (ViewerController*) blendingController { return blendingController; }
- (short) maxMovieIndex { return maxMovieIndex; }
- (short) curMovieIndex { return curMovieIndex; }
- (void) setMovieIndex: (short) i { curMovieIndex = i; Record([NSString stringWithFormat: @"%@ setMovieIndex %d", Name(self), i]); }
- (NSMutableArray*) pixList { return pixList[curMovieIndex]; }
- (void) checkEverythingLoaded { Record([NSString stringWithFormat: @"%@ checkEverythingLoaded", Name(self)]); }
- (BOOL) isDataVolumicIn4D:(BOOL) check4D {
    Record([NSString stringWithFormat: @"%@ isDataVolumicIn4D %d", Name(self), check4D]);
    return check4D ? volumic : volumicWithoutTime;
}
- (float) computeInterval { Record([NSString stringWithFormat: @"%@ computeInterval", Name(self)]); return interval; }
- (IBAction) SetThicknessInterval:(id) sender { Record([NSString stringWithFormat: @"%@ SetThicknessInterval %@", Name(self), Name(sender)]); }
- (void) displayAWarningIfNonTrueVolumicData { Record([NSString stringWithFormat: @"%@ displayAWarningIfNonTrueVolumicData", Name(self)]); }
- (void) displayWarningIfGantryTitled { Record([NSString stringWithFormat: @"%@ displayWarningIfGantryTitled", Name(self)]); }
- (IBAction) MovieStop:(id) sender { Record([NSString stringWithFormat: @"%@ MovieStop %@", Name(self), Name(sender)]); }
- (IBAction) applyConvolutionOnSource:(id) sender { Record([NSString stringWithFormat: @"%@ applyConvolutionOnSource %@", Name(self), Name(sender)]); }
- (IBAction) updateImage:(id) sender { Record([NSString stringWithFormat: @"%@ updateImage %@", Name(self), Name(sender)]); }
- (void) roiDeleteGeneratedROIsForName:(NSString*) name { Record([NSString stringWithFormat: @"%@ roiDeleteGeneratedROIsForName %@", Name(self), name]); }
- (ROI*) roiMorphingBetween:(ROI*) a and:(ROI*) b ratio:(float) ratio {
    Record([NSString stringWithFormat: @"%@ roiMorphingBetween %@ %@ %@", Name(self), Name(a), Name(b), F(ratio)]);
    if (ratio > 0.7f && [a.name hasPrefix: @"NoMorph"]) return nil;
    ROI *m = [[ROI new] autorelease];
    Register(m, [NSString stringWithFormat: @"morph(%@,%@,%@)", Name(a), Name(b), F(ratio)]);
    m->area = a->area + (b->area - a->area) * ratio; m->valid = YES; m.type = a.type;
    m->spline = [[NSMutableArray array] retain];
    [morphs addObject: m];
    return m;
}
- (void) adjustSlider { Record([NSString stringWithFormat: @"%@ adjustSlider", Name(self)]); }
- (void) showCurrentThumbnail:(id) sender { Record([NSString stringWithFormat: @"%@ showCurrentThumbnail", Name(self)]); }
- (void) updateNavigator { Record([NSString stringWithFormat: @"%@ updateNavigator", Name(self)]); }
- (void) buildMatrixPreview: (BOOL) showSelected { Record([NSString stringWithFormat: @"%@ buildMatrixPreview %d", Name(self), showSelected]); }
- (id) startWaitWindow :(NSString*) message {
    Record([NSString stringWithFormat: @"%@ startWaitWindow %@", Name(self), message]);
    NSObject *wait = [[NSObject new] autorelease]; Register(wait, @"waitWindow"); return wait;
}
- (void) endWaitWindow:(id) waitWindow { Record([NSString stringWithFormat: @"%@ endWaitWindow %@", Name(self), Name(waitWindow)]); }
- (void) willChangeValueForKey:(NSString *) key { Record([NSString stringWithFormat: @"%@ willChange %@", Name(self), key]); }
- (void) didChangeValueForKey:(NSString *) key { Record([NSString stringWithFormat: @"%@ didChange %@", Name(self), key]); }
// The accessors of ViewerController+SwiftIvars.h.
- (DCMView*) horos_imageView { return imageView; }
- (void) setHoros_imageView:(DCMView*) v { imageView = v; }
- (short) horos_curMovieIndex { return curMovieIndex; }
- (void) setHoros_curMovieIndex:(short) v { curMovieIndex = v; }
- (short) horos_maxMovieIndex { return maxMovieIndex; }
- (void) setHoros_maxMovieIndex:(short) v { maxMovieIndex = v; }
- (NSMutableArray*) horos_pixListAt:(NSInteger) i { return pixList[i]; }
- (NSMutableArray*) horos_fileListAt:(NSInteger) i { return fileList[i]; }
- (NSMutableArray*) horos_roiListAt:(NSInteger) i { return roiList[i]; }
- (NSObject*) horos_volumeDataAt:(NSInteger) i { return volumeData[i]; }
- (ViewerController*) horos_blendingController { return blendingController; }
- (void) setHoros_blendingController:(ViewerController*) v { blendingController = v; }
- (NSString*) horos_curConvMenu { return curConvMenu; }
- (void) setHoros_curConvMenu:(NSString*) v { curConvMenu = v; }
- (NSString*) horos_curCLUTMenu { return curCLUTMenu; }
- (void) setHoros_curCLUTMenu:(NSString*) v { curCLUTMenu = v; }
- (NSString*) horos_backCurCLUTMenu { return backCurCLUTMenu; }
- (void) setHoros_backCurCLUTMenu:(NSString*) v { backCurCLUTMenu = v; }
- (NSString*) horos_curOpacityMenu { return curOpacityMenu; }
- (void) setHoros_curOpacityMenu:(NSString*) v { curOpacityMenu = v; }
- (BOOL) horos_postprocessed { return postprocessed; }
- (void) setHoros_postprocessed:(BOOL) v { postprocessed = v; }
- (BOOL) horos_displayOnlyKeyImages { return displayOnlyKeyImages; }
- (void) setHoros_displayOnlyKeyImages:(BOOL) v { displayOnlyKeyImages = v; }
- (NSPopUpButton*) horos_keyImagePopUpButton { return keyImagePopUpButton; }
@end

@implementation BrowserController (Loading)
- (ViewerController*) loadSeries :(NSManagedObject *) series :(ViewerController*) viewer :(BOOL) firstViewer keyImagesOnly:(BOOL) keyImages {
    Record([NSString stringWithFormat: @"browser loadSeries %@ %@ %d keyImagesOnly %d", Name(series), Name(viewer), firstViewer, keyImages]);
    NSArray *content = seriesContent[Name(series)];
    viewer->pixList[0] = content[0]; viewer->fileList[0] = content[1]; viewer->roiList[0] = content[2];
    viewer->imageView->pixListValue = content[0]; viewer->imageView->curImageValue = 0;
    viewer->imageView->series = (DicomSeries *)series;
    return viewer;
}
- (ViewerController*) openViewerFromImages:(NSArray*) toOpenArray movie:(BOOL) movieViewer viewer:(ViewerController*) viewer keyImagesOnly:(BOOL) keyImages {
    Record([NSString stringWithFormat: @"browser openViewerFromImages %@ movie %d viewer %@ keyImagesOnly %d", Name(toOpenArray), movieViewer, Name(viewer), keyImages]);
    return viewer;
}
@end

// ---------------------------------------------------------------- data

static DCMPix *P(ViewerController *v, int m, int i) { return v->pixList[m][i]; }

static const float axial[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
static const float tilted[9] = {1, 0, 0, 0, 0.8f, 0.6f, 0, -0.6f, 0.8f};

static DCMPix *Pix(NSString *name, int w, int h, double ox, double oy, double oz, const float *v) {
    DCMPix *pix = [[DCMPix new] autorelease];
    Register(pix, name);
    pix.pwidth = w; pix.pheight = h;
    pix->ox = ox; pix->oy = oy; pix->oz = oz; pix->sx = 0.5; pix->sy = 0.75; pix->spacing = 2.5;
    for (int i = 0; i < 9; i++) pix->vectors[i] = v[i];
    pix.maxValueOfSeries = 1000;
    return pix;
}

static FileStub *File(NSString *name, BOOL key) {
    FileStub *file = [[[FileStub alloc] initWithEntity: imageEntity insertIntoManagedObjectContext: nil] autorelease];
    file->values = [@{@"isKeyImage": @(key), @"series.study.date": [NSDate dateWithTimeIntervalSince1970: 1700000000]} mutableCopy];
    Register(file, name);
    return file;
}

static NSData *Volume(NSString *name, int floats) {
    NSMutableData *data = [NSMutableData dataWithLength: floats * sizeof(float)];
    for (int i = 0; i < floats; i++) ((float *)data.mutableBytes)[i] = i * 0.5f;
    NSData *volume = [NSData dataWithData: data];
    Register(volume, name);
    return volume;
}

// A viewer of `movies` frames of `count` slices, `w`×`h`, spaced `step` mm.
static ViewerController *Viewer(NSString *name, int movies, int count, int w, int h, double step) {
    ViewerController *v = [[ViewerController alloc] initNamed: name];
    for (int m = 0; m < movies; m++) {
        NSMutableArray *pixes = [NSMutableArray array], *files = [NSMutableArray array], *rois = [NSMutableArray array];
        for (int i = 0; i < count; i++) {
            [pixes addObject: Pix([NSString stringWithFormat: @"%@.m%d.pix%d", name, m, i], w, h, 10, -20, i * step, axial)];
            [files addObject: File([NSString stringWithFormat: @"%@.m%d.file%d", name, m, i], i % 3 == 1)];
            [rois addObject: [NSMutableArray array]];
        }
        v->pixList[m] = [pixes retain]; v->fileList[m] = [files retain]; v->roiList[m] = [rois retain];
        Register(pixes, [NSString stringWithFormat: @"%@.pixList%d", name, m]);
        Register(files, [NSString stringWithFormat: @"%@.fileList%d", name, m]);
        Register(rois, [NSString stringWithFormat: @"%@.roiList%d", name, m]);
        v->volumeData[m] = [Volume([NSString stringWithFormat: @"%@.volume%d", name, m], w * h * count) retain];
    }
    v->maxMovieIndex = movies;
    v->imageView->pixListValue = v->pixList[0];
    v->imageView->wl = 40; v->imageView->ww = 400;
    v->morphs = [[NSMutableArray array] retain];
    return v;
}

static ROI *Roi(NSString *name, NSString *label, float area, BOOL valid, ToolMode type) {
    ROI *roi = [[ROI new] autorelease];
    Register(roi, label);
    roi.name = name; roi->area = area; roi->valid = valid; roi.type = type;
    roi->spline = [[NSMutableArray array] retain];
    for (int i = 0; i < 3; i++) {
        MyPoint *p = [[MyPoint new] autorelease]; p.x = 2 + i * 1.25f + area; p.y = 3 - i * 0.5f; [roi->spline addObject: p];
    }
    roi->centroidValue = NSMakePoint(3.25 + area, 4.5);
    return roi;
}

static void Run(void) { [[NSRunLoop mainRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 0.02]]; }

static void Try(NSString *label, void (^block)(void)) {
    Record([@"== " stringByAppendingString: label]);
    @try { block(); }
    @catch (NSException *e) { Record([NSString stringWithFormat: @"exception %@", e.name]); }
    Run();
}

static void Defaults(NSDictionary *values) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    for (NSString *key in @[@"ROIComputeSkewnessAndKurtosis", @"ThreeDViewerOnAnotherScreen", @"PET Clut Mode", @"PET Default CLUT",
                            @"clutNM", @"PARALLELPLANETOLERANCE", @"DEFAULTPETFUSION", @"growingRegionType"])
        [d removeObjectForKey: key];
    for (NSString *key in values) [d setObject: values[key] forKey: key];
}

static NSString *Points(NSMutableArray *points) {
    if (points == nil) return @"nil";
    NSMutableArray *lines = [NSMutableArray array];
    for (NSArray *p in points) [lines addObject: [NSString stringWithFormat: @"%@,%@,%@", F([p[0] floatValue]), F([p[1] floatValue]), F([p[2] floatValue])]];
    if (lines.count > 40) {
        NSUInteger hash = 0;
        for (NSString *line in lines) hash = hash * 31 + line.hash;
        return [NSString stringWithFormat: @"%lu points, first %@ last %@ hash %lx", (unsigned long)lines.count, lines.firstObject, lines.lastObject, (unsigned long)hash];
    }
    // The contours are gathered concurrently: their order is not part of the result.
    [lines sortUsingSelector: @selector(compare:)];
    return [NSString stringWithFormat: @"%lu points %@", (unsigned long)lines.count, [lines componentsJoinedByString: @" "]];
}

static NSString *Data(NSDictionary *data) {
    if (data == nil) return @"nil";
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *key in [[data allKeys] sortedArrayUsingSelector: @selector(compare:)]) {
        id value = data[key];
        [parts addObject: [NSString stringWithFormat: @"%@=%@", key, [value isKindOfClass: [NSNumber class]] ? F([value doubleValue]) : Name(value)]];
    }
    return [parts componentsJoinedByString: @" "];
}

// ---------------------------------------------------------------- scenarios

static void Volume3D(ViewerController *v, ROI *selected, BOOL points, BOOL generate, NSMutableArray *generated, BOOL data) {
    NSMutableArray *pts = nil; NSString *error = nil;
    NSMutableDictionary *computed = data ? [NSMutableDictionary dictionary] : nil;
    float volume = [v computeVolume: selected points: points ? &pts : nil generateMissingROIs: generate generatedROIs: generated computeData: computed error: &error];
    Run();
    Record([NSString stringWithFormat: @"volume %@ error %@", F(volume), error]);
    Record([NSString stringWithFormat: @"points %@", Points(pts)]);
    Record([NSString stringWithFormat: @"data %@", Data(computed)]);
    if (generated) Record([NSString stringWithFormat: @"generated %@", Name(generated)]);
}

static void volumeScenario(void) {
    ViewerController *v = Viewer(@"V", 2, 6, 4, 4, 2.0);
    for (int i = 0; i < 6; i++) { P(v, 0, i)->values[0] = 10 + i; P(v, 0, i)->values[1] = 3.5f * i; P(v, 0, i)->valueCount = 2; }
    ROI *a = Roi(@"Liver", @"A1", 2.5f, YES, tROI), *b = Roi(@"Liver", @"A2", 3.0f, YES, tROI), *c = Roi(@"Liver", @"A4", 2.0f, YES, tROI);
    ROI *other = Roi(@"Other", @"O2", 9, YES, tROI), *invalid = Roi(@"Liver", @"I3", 4, NO, tROI);
    ROI *brush = Roi(@"Liver", @"B5", 1.5f, YES, tPlain);
    brush->textureWidth = 3; brush->textureHeight = 2; brush->textureUpLeftCornerX = 5; brush->textureUpLeftCornerY = 7;
    brush->mask = calloc(6, 1); brush->mask[1] = 1; brush->mask[4] = 1;
    [v->roiList[0][1] addObject: a]; [v->roiList[0][2] addObject: other]; [v->roiList[0][2] addObject: b];
    [v->roiList[0][3] addObject: invalid]; [v->roiList[0][4] addObject: c];
    [[NSNotificationCenter defaultCenter] addObserverForName: OsirixAddROINotification object: nil queue: nil usingBlock: ^(NSNotification *note) {
        Record([NSString stringWithFormat: @"notification add ROI %@ slice %@ object %@", Name(note.userInfo[@"ROI"]), note.userInfo[@"sliceNumber"], Name(note.object)]);
    }];

    Defaults(@{});
    Try(@"volume, points, data", ^{ Volume3D(v, a, YES, NO, nil, YES); });
    Try(@"volume only", ^{ Volume3D(v, a, NO, NO, nil, NO); });
    Try(@"two-argument forms", ^{
        NSMutableArray *pts = nil; NSString *error = nil;
        Record(F([v computeVolume: b points: &pts error: &error])); Record(Points(pts));
        Record(F([v computeVolume: b points: nil generateMissingROIs: NO error: nil]));
    });
    Try(@"missing slice and data", ^{
        [v->roiList[0][4] removeObject: c]; [v->roiList[0][5] addObject: c];
        Volume3D(v, a, YES, NO, nil, YES);
        [v->roiList[0][5] removeObject: c]; [v->roiList[0][4] addObject: c];
    });
    Try(@"contiguous slices, data", ^{
        [v->roiList[0][4] removeObject: c];
        Volume3D(v, a, YES, NO, nil, YES);
        [v->roiList[0][4] addObject: c];
    });
    Defaults(@{@"ROIComputeSkewnessAndKurtosis": @YES});
    Try(@"skewness and kurtosis", ^{
        [v->roiList[0][4] removeObject: c];
        Volume3D(v, a, NO, NO, nil, YES);
        P(v, 0, 2)->valueCount = 0;
        Volume3D(v, a, NO, NO, nil, YES);
        P(v, 0, 1)->valueCount = 0;
        Volume3D(v, a, NO, NO, nil, YES);
        P(v, 0, 1)->valueCount = 2; P(v, 0, 2)->valueCount = 2;
        [v->roiList[0][4] addObject: c];
    });
    Defaults(@{});
    Try(@"generate missing into a list", ^{
        NSMutableArray *generated = [NSMutableArray array]; Register(generated, @"generated");
        [v->roiList[0][4] removeObject: c]; [v->roiList[0][5] addObject: c];
        Volume3D(v, a, YES, YES, generated, YES);
        for (NSMutableArray *slice in v->roiList[0]) Record([NSString stringWithFormat: @"slice %@", Name(slice)]);
    });
    Try(@"generate missing, generated ROIs deleted first", ^{ Volume3D(v, a, NO, YES, nil, NO); });
    Try(@"brush ROI contour", ^{
        [v->roiList[0][3] addObject: brush];
        Volume3D(v, brush, YES, NO, nil, YES);
        [v->roiList[0][3] removeObject: brush];
    });
    Try(@"zero area", ^{
        ROI *zero = Roi(@"Liver", @"Z0", 0, YES, tROI);
        [v->roiList[0][0] addObject: zero];
        Volume3D(v, a, YES, NO, nil, YES);
        [v->roiList[0][0] removeObject: zero];
    });
    Try(@"one ROI", ^{ Volume3D(v, other, YES, NO, nil, YES); });
    Try(@"no ROI of that name", ^{ Volume3D(v, Roi(@"Nothing", @"N", 1, YES, tROI), YES, NO, nil, YES); });
    Try(@"many points thinned", ^{
        ViewerController *w = Viewer(@"W", 1, 3, 4, 4, 1.0);
        ROI *big = Roi(@"Big", @"Big0", 5, YES, tROI), *small = Roi(@"Big", @"Big2", 6, YES, tROI);
        for (int i = 0; i < 15001; i++) { MyPoint *p = [[MyPoint new] autorelease]; p.x = i * 0.01f; p.y = i % 7; [big->spline addObject: p]; }
        [small->spline removeAllObjects];
        [w->roiList[0][0] addObject: big]; [w->roiList[0][2] addObject: small];
        Volume3D(w, big, YES, NO, nil, NO);
    });
    Try(@"second frame", ^{
        v->curMovieIndex = 1;
        ROI *x = Roi(@"Liver", @"X1", 1, YES, tROI), *y = Roi(@"Liver", @"X2", 1.5f, YES, tROI);
        [v->roiList[1][1] addObject: x]; [v->roiList[1][2] addObject: y];
        Volume3D(v, x, YES, NO, nil, NO);
        v->curMovieIndex = 0;
    });

    Try(@"volume data", ^{
        Record([NSString stringWithFormat: @"volumePtr %d %d %d", [v volumePtr] == (float *)v->volumeData[0].bytes,
                [v volumePtr: 1] == (float *)v->volumeData[1].bytes, [v volumePtr: 3] == (float *)v->volumeData[1].bytes]);
        Record([NSString stringWithFormat: @"volumeData %@ %@ %@ %@", Name([v volumeData]), Name([v volumeData: 0]), Name([v volumeData: -1]), Name([v volumeData: 2])]);
        ViewerController *empty = [[ViewerController alloc] initNamed: @"E"];
        empty->maxMovieIndex = 1;
        Record([NSString stringWithFormat: @"empty %d %@", [empty volumePtr] == NULL, Name([empty volumeData])]);
    });
    Try(@"clear 8-bit", ^{ v->imageView->curImageValue = 2; [v clear8bitRepresentations]; });
    Try(@"update volume data", ^{
        [v->roiList[0][1] addObject: Roi(@"Liver", @"R1", 1, YES, tROI)];
        [v updateVolumeData: [NSNotification notificationWithName: @"x" object: v->pixList[1]]];
        [v updateVolumeData: [NSNotification notificationWithName: @"x" object: v->pixList[0]]];
        Record([NSString stringWithFormat: @"wl %@ %@", F(v->imageView->wl), F(v->imageView->ww)]);
        ViewerController *none = [[ViewerController alloc] initNamed: @"Nil"];
        none->maxMovieIndex = 1;
        [none updateVolumeData: [NSNotification notificationWithName: @"x" object: nil]];
    });
}

static void fourdScenario(void) {
    Try(@"one frame", ^{
        ViewerController *v = Viewer(@"F", 1, 4, 8, 8, 1.0);
        Record([NSString stringWithFormat: @"reason %@", [v fourDReconstructionRefusalReason]]);
        Record([NSString stringWithFormat: @"refuse %d", [v refuseFourDReconstructionWithTitle: @"MPR"]]);
        Record([NSString stringWithFormat: @"fusion %@ %d", [v fourDFusionRefusalReason], [v refuseFourDFusionWithTitle: @"PET-CT Fusion"]]);
    });
    Try(@"no frame", ^{
        ViewerController *v = Viewer(@"F0", 1, 4, 8, 8, 1.0); v->maxMovieIndex = 0;
        Record([NSString stringWithFormat: @"reason %@", [v fourDReconstructionRefusalReason]]);
    });
    Try(@"frames that differ", ^{
        ViewerController *v = Viewer(@"F3", 3, 4, 8, 8, 1.0);
        Record([NSString stringWithFormat: @"same %@", [v fourDReconstructionRefusalReason]]);
        P(v, 2, 1).pwidth = 16;
        Record([NSString stringWithFormat: @"inconsistent %@", [v fourDReconstructionRefusalReason]]);
        P(v, 2, 1).pwidth = 8;
        [v->pixList[1] removeLastObject];
        Record([NSString stringWithFormat: @"fewer slices %@", [v fourDReconstructionRefusalReason]]);
        Record([NSString stringWithFormat: @"refuse %d", [v refuseFourDReconstructionWithTitle: @"Volume Rendering"]]);
        P(v, 0, 0).pwidth = 4;
        Record([NSString stringWithFormat: @"first frame %@", [v fourDReconstructionRefusalReason]]);
    });
    Try(@"fusion", ^{
        ViewerController *host = Viewer(@"H", 3, 4, 8, 8, 1.0), *overlay = Viewer(@"P", 2, 4, 8, 8, 1.0), *bad = Viewer(@"Q", 2, 4, 8, 8, 1.0);
        P(bad, 1, 2).pheight = 2;
        Record([NSString stringWithFormat: @"%@ | %@ | %@", [host fourDFusionRefusalReasonForOverlay: overlay], [host fourDFusionRefusalReasonForOverlay: bad], [host fourDFusionRefusalReasonForOverlay: nil]]);
        host->blendingController = overlay;
        Record([NSString stringWithFormat: @"%@ %d", [host fourDFusionRefusalReason], [host refuseFourDFusionWithTitle: @"PET-CT Fusion"]]);
        overlay->maxMovieIndex = 3;
        Record([NSString stringWithFormat: @"%@ %d", [host fourDFusionRefusalReason], [host refuseFourDFusionWithTitle: @"PET-CT Fusion"]]);
    });
    void (^decide)(ViewerController *) = ^(ViewerController *v) {
        id d = [v reconstructionOpeningDecision];
        Record([NSString stringWithFormat: @"decision accepted %d phase %@ diagnosis %@", [[d valueForKey: @"accepted"] boolValue], [d valueForKey: @"phase"], [d valueForKey: @"diagnosis"]]);
    };
    Try(@"opening: regular", ^{ decide(Viewer(@"G", 1, 5, 8, 8, 1.25)); });
    Try(@"opening: one slice", ^{ decide(Viewer(@"G1", 1, 1, 8, 8, 1.25)); });
    Try(@"opening: mixed matrices", ^{ ViewerController *v = Viewer(@"G2", 1, 5, 8, 8, 1.25); P(v, 0, 3).pheight = 9; decide(v); });
    Try(@"opening: mixed orientation", ^{
        ViewerController *v = Viewer(@"G3", 1, 5, 8, 8, 1.25);
        for (int i = 0; i < 9; i++) P(v, 0, 4)->vectors[i] = tilted[i];
        P(v, 0, 2)->vectors[4] = 1.0005f;
        decide(v);
    });
    Try(@"opening: irregular steps", ^{
        ViewerController *v = Viewer(@"G4", 1, 5, 8, 8, 1.25);
        P(v, 0, 3)->oz = 3.2; P(v, 0, 1)->ox = 10.3; P(v, 0, 2)->oy = -19.6;
        decide(v);
    });
    Try(@"opening: no interval", ^{ ViewerController *v = Viewer(@"G5", 1, 5, 8, 8, 1.25); v->interval = 0; decide(v); });
    Try(@"opening: not a number", ^{ ViewerController *v = Viewer(@"G6", 1, 5, 8, 8, 1.25); v->interval = NAN; decide(v); });
    Try(@"opening: with ROIs", ^{
        ViewerController *v = Viewer(@"G7", 2, 5, 8, 8, 1.25); v->curMovieIndex = 1;
        [v->roiList[1][2] addObject: Roi(@"a", @"ra", 1, YES, tROI)]; [v->roiList[1][3] addObject: Roi(@"b", @"rb", 1, YES, tROI)];
        decide(v);
    });
    Try(@"opening: empty list", ^{ ViewerController *v = Viewer(@"G8", 1, 5, 8, 8, 1.25); [v->pixList[0] removeAllObjects]; decide(v); });
    Try(@"opening: no list", ^{ ViewerController *v = Viewer(@"G9", 1, 5, 8, 8, 1.25); v->pixList[0] = nil; decide(v); });
}

static void Screen(ViewerController *v) {
    NSScreen *s = [v get3DViewerScreen: v];
    Record([NSString stringWithFormat: @"screen %@", s ? NSStringFromRect(s.frame) : @"nil"]);
}

static void open3dScenario(void) {
    Defaults(@{@"PARALLELPLANETOLERANCE": @5, @"DEFAULTPETFUSION": @2, @"PET Default CLUT": @"Hot Iron"});
    Try(@"screens", ^{
        ViewerController *v = Viewer(@"S", 1, 4, 8, 8, 1.0);
        Screen(v);
        Defaults(@{@"ThreeDViewerOnAnotherScreen": @YES});
        Screen(v);
        ((ScreenProbe *)v->probeWindow.probeScreen).probeFrame = NSScreen.screens.firstObject.frame;
        Screen(v);
        v->probeWindow.probeScreen = nil;
        Screen(v);
        Screen(nil);
        Defaults(@{@"PARALLELPLANETOLERANCE": @5, @"DEFAULTPETFUSION": @2, @"PET Default CLUT": @"Hot Iron"});
    });

    ViewerController *v = Viewer(@"T", 3, 6, 8, 8, 1.0);
    v->curMovieIndex = 1;
    Try(@"panel: not volumic", ^{ v->volumic = NO; [v Panel3D: v]; v->volumic = YES; });
    Try(@"panel: no interval", ^{ v->interval = 0; [v Panel3D: v]; v->interval = 1.5f; });
    Try(@"panel: frames refused", ^{ [v->pixList[2] removeLastObject]; [v Panel3D: v]; });
    [v->pixList[2] addObject: Pix(@"T.m2.pix5again", 8, 8, 10, -20, 5, axial)];
    Try(@"panel: opens", ^{ [v Panel3D: v]; });
    Try(@"panel: found", ^{ [v Panel3D: v]; });
    Try(@"VR: tag 0", ^{ NSButton *b = [[NSButton new] autorelease]; b.tag = 0; Register(b, @"button0"); [v VRViewer: b]; });
    Try(@"VR: found, tag 3", ^{ NSButton *b = [[NSButton new] autorelease]; b.tag = 3; Register(b, @"button3"); [v VRViewer: b]; });
    Try(@"VR mode: found", ^{ Record(Name([v openVRViewerForMode: @"MIP"])); });

    ViewerController *p = Viewer(@"PT", 2, 6, 8, 8, 1.0);
    p->modalityValue = @"PT"; p->curConvMenu = @"Basic Smooth"; p->backCurCLUTMenu = @"Back CLUT";
    Try(@"VR: PET, convolution kept, MIP", ^{
        informationalResponse = HorosAlertAlternateResponse;
        NSButton *b = [[NSButton new] autorelease]; b.tag = 3; Register(b, @"pbutton3"); [p VRViewer: b];
    });
    Try(@"panel: PET", ^{ [p Panel3D: p]; });
    Try(@"VR mode: PET in SUV", ^{
        ViewerController *q = Viewer(@"PS", 1, 4, 8, 8, 1.0); q->modalityValue = @"PT"; P(q, 0, 0).SUVConverted = YES;
        Defaults(@{@"PARALLELPLANETOLERANCE": @5, @"PET Clut Mode": @"B/W Inverse"});
        Record(Name([q openVRViewerForMode: nil]));
        [q Panel3D: q];
        Defaults(@{@"PARALLELPLANETOLERANCE": @5, @"DEFAULTPETFUSION": @2, @"PET Default CLUT": @"Hot Iron"});
    });
    Try(@"VR: convolution applied", ^{
        ViewerController *r = Viewer(@"CV", 1, 4, 8, 8, 1.0); r->curConvMenu = @"Basic Smooth"; r->curCLUTMenu = nil;
        informationalResponse = HorosAlertDefaultResponse;
        [r VRViewer: nil];
    });
    Try(@"VR mode: refused", ^{ ViewerController *r = Viewer(@"RF", 2, 4, 8, 8, 1.0); [r->pixList[1] removeLastObject]; Record(Name([r openVRViewerForMode: @"VR"])); });
    Try(@"VR: RGB panel", ^{
        ViewerController *r = Viewer(@"RGB", 1, 4, 8, 8, 1.0); r->modalityValue = @"PT"; P(r, 0, 0)->rgb = YES;
        [r Panel3D: r];
    });

    Try(@"SR: opens", ^{ [v SRViewer: v]; });
    Try(@"SR: found", ^{ [v SRViewer: v]; Record(Name([v openSRViewer])); });
    Try(@"SR: not volumic", ^{ ViewerController *r = Viewer(@"SN", 1, 4, 8, 8, 1.0); r->volumic = NO; [r SRViewer: nil]; });
    Try(@"SR: frame missing", ^{ ViewerController *r = Viewer(@"SM", 2, 4, 8, 8, 1.0); r->curMovieIndex = 3; r->maxMovieIndex = 2; r->volumeData[1] = nil; Record(Name([r openSRViewer])); });

    Try(@"orthogonal: no interval", ^{ v->interval = 0; [v orthogonalMPRViewer: nil]; v->interval = 1.5f; });
    Try(@"orthogonal: not volumic", ^{ v->volumic = NO; [v orthogonalMPRViewer: nil]; v->volumic = YES; });
    Try(@"orthogonal: geometry refused", ^{ ViewerController *r = Viewer(@"OG", 1, 4, 8, 8, 1.0); P(r, 0, 2).pwidth = 3; [r orthogonalMPRViewer: nil]; });
    Try(@"orthogonal: opens", ^{ [v orthogonalMPRViewer: v]; });
    Try(@"orthogonal: found", ^{ [v orthogonalMPRViewer: v]; Record(Name([v openOrthogonalMPRViewer])); });
    Try(@"orthogonal: NM table", ^{
        ViewerController *r = Viewer(@"NM", 1, 4, 8, 8, 1.0); r->modalityValue = @"NM";
        Defaults(@{@"PARALLELPLANETOLERANCE": @5, @"clutNM": @YES, @"PET Default CLUT": @"Hot Iron"});
        Record(Name([r openOrthogonalMPRViewer]));
        ViewerController *s = Viewer(@"NMRGB", 1, 4, 8, 8, 1.0); s->modalityValue = @"NM"; P(s, 0, 0)->rgb = YES; s->backCurCLUTMenu = @"Back";
        Record(Name([s openOrthogonalMPRViewer]));
        Defaults(@{@"PARALLELPLANETOLERANCE": @5, @"DEFAULTPETFUSION": @2, @"PET Default CLUT": @"Hot Iron"});
    });
    Try(@"orthogonal PET-CT: opens", ^{
        ViewerController *ct = Viewer(@"CT", 3, 6, 8, 8, 1.0), *pet = Viewer(@"PET", 2, 6, 8, 8, 1.0);
        ct->blendingController = pet; ct->curMovieIndex = 2; pet->curCLUTMenu = @"PET CLUT"; pet->curOpacityMenu = @"PET Opacity";
        pet->imageView->wl = 3; pet->imageView->ww = 7;
        [ct orthogonalMPRViewer: ct];
        [ct orthogonalMPRViewer: ct];
        Record(Name([ct openOrthogonalMPRViewer]));
        Record(Name([ct openOrthogonalMPRPETCTViewer]));
    });
    Try(@"orthogonal PET-CT: planes apart", ^{
        ViewerController *ct = Viewer(@"CT2", 1, 6, 8, 8, 1.0), *pet = Viewer(@"PET2", 1, 6, 8, 8, 1.0);
        for (int i = 0; i < 9; i++) P(pet, 0, 0)->vectors[i] = tilted[i];
        ct->blendingController = pet;
        [ct orthogonalMPRViewer: nil];
        Record(Name([ct openOrthogonalMPRPETCTViewer]));
        ct->blendingController = nil;
        Record(Name([ct openOrthogonalMPRPETCTViewer]));
    });
    Try(@"orthogonal PET-CT: fusion refused", ^{
        ViewerController *ct = Viewer(@"CT3", 2, 6, 8, 8, 1.0), *pet = Viewer(@"PET3", 3, 6, 8, 8, 1.0);
        ct->blendingController = pet;
        [ct orthogonalMPRViewer: nil];
    });

    Try(@"endoscopy: opens and found", ^{ [v endoscopyViewer: v]; [v endoscopyViewer: v]; Record(Name([v openEndoscopyViewer])); });
    Try(@"endoscopy: refused", ^{ ViewerController *r = Viewer(@"EN", 2, 4, 8, 8, 1.0); [r->pixList[1] removeLastObject]; [r endoscopyViewer: nil]; r->volumic = NO; [r endoscopyViewer: nil]; });

    Try(@"MPR: calibrate", ^{ ViewerController *r = Viewer(@"MC", 1, 4, 8, 8, 1.0); P(r, 0, 0)->sx = 0; [r mprViewer: nil]; });
    Try(@"MPR: refused geometry", ^{ ViewerController *r = Viewer(@"MG", 1, 4, 8, 8, 1.0); P(r, 0, 1).pheight = 2; [r mprViewer: nil]; });
    Try(@"MPR: not volumic", ^{ ViewerController *r = Viewer(@"MV", 1, 4, 8, 8, 1.0); r->volumic = NO; [r mprViewer: nil]; });
    Try(@"MPR: opens", ^{ [v mprViewer: v]; });
    Try(@"MPR: found", ^{ [v mprViewer: v]; Record(Name([v openMPRViewer])); });
    Try(@"MPR: replaces a Series Selection MPR", ^{
        ViewerController *r = Viewer(@"MR", 1, 4, 8, 8, 1.0);
        MPRController *old = [r openMPRViewer];
        Record(Name(old));
        [old->probeWindow setTitle: @"old MPR"];
        ViewerController *s = Viewer(@"MS", 1, 4, 8, 8, 1.0);
        [s mprViewer: old];
        [s mprViewer: old];
        [r mprViewer: old];
        MPRController *other = [Viewer(@"MO", 1, 4, 8, 8, 1.0) openMPRViewer];
        [s mprViewer: other];
    });
    Try(@"MPR: refused frames", ^{ ViewerController *r = Viewer(@"MF", 2, 4, 8, 8, 1.0); [r->pixList[1] removeLastObject]; Record(Name([r openMPRViewer])); [r mprViewer: nil]; });

    Try(@"CPR: RGB", ^{ ViewerController *r = Viewer(@"CR", 1, 4, 8, 8, 1.0); P(r, 0, 0)->rgb = YES; [r cprViewer: nil]; });
    Try(@"CPR: no interval", ^{ ViewerController *r = Viewer(@"CI", 1, 4, 8, 8, 1.0); r->interval = 0; [r cprViewer: nil]; });
    Try(@"CPR: refused geometry", ^{ ViewerController *r = Viewer(@"CG", 1, 4, 8, 8, 1.0); P(r, 0, 1).pwidth = 2; [r cprViewer: nil]; });
    Try(@"CPR: opens and found", ^{ [v cprViewer: v]; [v cprViewer: v]; Record(Name([v openCPRViewer])); });
    Try(@"CPR: refused frames", ^{ ViewerController *r = Viewer(@"CF", 2, 4, 8, 8, 1.0); [r->pixList[1] removeLastObject]; Record(Name([r openCPRViewer])); [r cprViewer: nil]; });

    Try(@"region growing: volumic", ^{ [v segmentationTest: v]; });
    Try(@"region growing: 2D", ^{
        ViewerController *r = Viewer(@"RG", 1, 1, 8, 8, 1.0); r->volumicWithoutTime = NO; r->interval = 0;
        [r segmentationTest: nil];
        Record([NSString stringWithFormat: @"growingRegionType %@", [[NSUserDefaults standardUserDefaults] objectForKey: @"growingRegionType"]]);
        P(r, 0, 0)->sy = 0;
        [r segmentationTest: nil];
    });
    Try(@"region growing: no interval", ^{ ViewerController *r = Viewer(@"RI", 1, 4, 8, 8, 1.0); r->interval = 0; [r segmentationTest: nil]; });

    Try(@"closing viewer not found", ^{
        for (Window3DController *c in openControllers) if ([c.windowNibName isEqual: @"VR"]) c->closing = YES;
        [v Panel3D: v];
        [v VRViewer: nil];
    });
}

static NSManagedObject *study;

static DicomSeries *Series(NSString *name, ViewerController *v, BOOL keys, int count, BOOL keyOnFirst) {
    DicomSeries *s = [[DicomSeries alloc] initWithEntity: seriesEntity insertIntoManagedObjectContext: nil];
    Register(s, name);
    s->studyValue = study;
    s->keys = [[NSMutableSet set] retain];
    NSMutableArray *pixes = [NSMutableArray array], *files = [NSMutableArray array], *rois = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        BOOL key = keys && (keyOnFirst ? (i == 0 || i == count - 2) : i == count - 2);
        FileStub *f = File([NSString stringWithFormat: @"%@.file%d", name, i], key);
        [files addObject: f]; [pixes addObject: Pix([NSString stringWithFormat: @"%@.pix%d", name, i], 8, 8, 0, 0, i, axial)];
        [rois addObject: [NSMutableArray array]];
        if (key) [s->keys addObject: f];
    }
    Register(files, [name stringByAppendingString: @".files"]);
    s->images = [files retain];
    seriesContent[name] = @[pixes, files, rois];
    return s;
}

static void Keys(ViewerController *v) {
    NSMutableArray *flags = [NSMutableArray array];
    for (int m = 0; m < v->maxMovieIndex; m++) for (FileStub *f in v->fileList[m]) [flags addObject: [f->values[@"isKeyImage"] boolValue] ? @"1" : @"0"];
    Record([NSString stringWithFormat: @"%@ keys %@ check %ld enabled %d popup %d/%ld only %d image %d", Name(v), [flags componentsJoinedByString: @""],
            (long)v->keyImageCheck.state, v->keyImageCheck.isEnabled, v->keyImagePopUpButton.isEnabled, (long)v->keyImagePopUpButton.indexOfSelectedItem,
            [v displayOnlyKeyImages], v->imageView->curImageValue]);
}

static void keyImagesScenario(void) {
    BrowserController *browser = [BrowserController currentBrowser];
    ViewerController *v = Viewer(@"K", 2, 6, 8, 8, 1.0);
    v->imageView->curImageValue = 2;
    NSButton *on = [[NSButton new] autorelease]; [on setButtonType: NSButtonTypeSwitch]; on.state = NSControlStateValueOn; Register(on, @"on");
    NSButton *off = [[NSButton new] autorelease]; [off setButtonType: NSButtonTypeSwitch]; off.state = NSControlStateValueOff; Register(off, @"off");
    Try(@"check box", ^{ [v keyImageCheckBox: on]; Keys(v); [v keyImageCheckBox: off]; Keys(v); [v keyImageCheckBox: nil]; Keys(v); });
    Try(@"check box, remote database", ^{ browser->bonjour = YES; [v keyImageCheckBox: on]; browser->bonjour = NO; Keys(v); });
    Try(@"shortcut", ^{ [v setKeyImage: nil]; Keys(v); [v setKeyImage: nil]; Keys(v); v->keyImageCheck.allowsMixedState = YES; v->keyImageCheck.state = NSControlStateValueMixed; [v setKeyImage: nil]; Keys(v); });
    Try(@"shortcut without a check box", ^{ NSButton *keep = v->keyImageCheck; v->keyImageCheck = nil; [v setKeyImage: nil]; v->keyImageCheck = keep; Keys(v); });
    Try(@"all", ^{ [v setAllKeyImages: nil]; Keys(v); browser->bonjour = YES; [v setAllNonKeyImages: nil]; browser->bonjour = NO; Keys(v); });
    Try(@"images with ROIs", ^{
        [v->roiList[0][1] addObject: Roi(@"a", @"k1", 1, YES, tROI)]; [v->roiList[1][4] addObject: Roi(@"b", @"k2", 1, YES, tROI)];
        [v setROIsImagesKeyImages: nil]; Keys(v);
        browser->bonjour = YES; [v setROIsImagesKeyImages: nil]; browser->bonjour = NO;
    });
    Try(@"state", ^{
        for (int i = -1; i < 3; i++) Record([NSString stringWithFormat: @"isKeyImage %d %d", i < 0 ? 0 : i, [v isKeyImage: i < 0 ? 0 : i]]);
        v->imageView->curImageValue = -1; [v adjustKeyImage]; Keys(v); v->imageView->curImageValue = 1; [v adjustKeyImage]; Keys(v);
    });
    Try(@"post processed", ^{
        v->postprocessed = YES;
        [v keyImageCheckBox: on]; [v findNextPreviousKeyImage: nil]; [v keyImageDisplayButton: nil]; [v setROIsImagesKeyImages: nil];
        [v setAllNonKeyImages: nil]; [v setAllKeyImages: nil]; [v setKeyImage: nil]; [v adjustKeyImage];
        Record([NSString stringWithFormat: @"isKeyImage %d", [v isKeyImage: 1]]); Keys(v);
        v->postprocessed = NO; [v adjustKeyImage]; Keys(v);
    });

    // A study of four series; the viewer shows the second one.
    study = [[NSObject new] retain]; Register(study, @"study");
    DicomSeries *s0 = Series(@"S0", v, YES, 4, NO), *s1 = Series(@"S1", v, NO, 5, NO), *s2 = Series(@"S2", v, NO, 3, NO), *s3 = Series(@"S3", v, YES, 4, YES);
    browser->seriesOfStudy = [@[s0, s1, s2, s3] retain];
    void (^show)(DicomSeries *, int, BOOL) = ^(DicomSeries *s, int image, BOOL flipped) {
        [browser loadSeries: s : v : YES keyImagesOnly: NO];
        v->maxMovieIndex = 1; v->curMovieIndex = 0;
        v->imageView->curImageValue = image; v->imageView.flippedData = flipped;
    };
    NSButton *next = [[NSButton new] autorelease]; next.tag = 0; Register(next, @"next");
    NSButton *previous = [[NSButton new] autorelease]; previous.tag = 1; Register(previous, @"previous");
    NSButton *other = [[NSButton new] autorelease]; other.tag = 256; Register(other, @"tag256");
    Try(@"next in series", ^{ show(s0, 0, NO); [v findNextPreviousKeyImage: next]; Keys(v); });
    Try(@"previous in series", ^{ show(s0, 3, NO); [v findNextPreviousKeyImage: previous]; Keys(v); });
    Try(@"next in flipped series", ^{ show(s0, 3, YES); [v findNextPreviousKeyImage: next]; Keys(v); });
    Try(@"next series", ^{ show(s1, 1, NO); [v findNextPreviousKeyImage: next]; Keys(v); });
    Try(@"next series, flipped", ^{ show(s1, 1, YES); [v findNextPreviousKeyImage: next]; Keys(v); });
    Try(@"next series from the last", ^{ show(s3, 3, NO); [v findNextPreviousKeyImage: next]; Keys(v); });
    Try(@"previous series", ^{ show(s1, 1, NO); [v findNextPreviousKeyImage: previous]; Keys(v); });
    Try(@"previous series, flipped", ^{ show(s1, 1, YES); [v findNextPreviousKeyImage: previous]; Keys(v); });
    Try(@"previous series walking on", ^{ show(s2, 1, NO); [v findNextPreviousKeyImage: previous]; Keys(v); });
    Try(@"previous from the first", ^{ show(s0, 0, NO); [v findNextPreviousKeyImage: previous]; Keys(v); });
    // Going back: the key images are only in a later series, or in none.
    browser->seriesOfStudy = [@[s1, s2, s3] retain];
    Try(@"previous series, key images only later", ^{ show(s2, 1, NO); [v findNextPreviousKeyImage: previous]; Keys(v); });
    browser->seriesOfStudy = [@[s1, s2] retain];
    Try(@"previous series, no key images", ^{ show(s2, 1, NO); [v findNextPreviousKeyImage: previous]; Keys(v); });
    Try(@"previous series, no key images, flipped", ^{ show(s2, 1, YES); [v findNextPreviousKeyImage: previous]; Keys(v); });
    browser->seriesOfStudy = [@[s0, s1, s2, s3] retain];
    Try(@"other tag", ^{ show(s1, 1, NO); [v findNextPreviousKeyImage: other]; Keys(v); });
    Try(@"no series", ^{ show(s1, 1, NO); v->imageView->series = nil; [v findNextPreviousKeyImage: next]; Keys(v); });

    Try(@"display all", ^{ show(s0, 1, NO); [v->keyImagePopUpButton selectItemAtIndex: 0]; [v keyImageDisplayButton: nil]; Keys(v); });
    Try(@"display key images", ^{ show(s0, 1, NO); [v->keyImagePopUpButton selectItemAtIndex: 1]; [v keyImageDisplayButton: nil]; Keys(v); });
    Try(@"display key images, none", ^{ show(s2, 1, NO); [v->keyImagePopUpButton selectItemAtIndex: 1]; [v keyImageDisplayButton: nil]; Keys(v); });
    Try(@"display without a series", ^{
        show(s0, 1, NO); [(FileStub *)v->fileList[0][1] setValue: nil forKey: @"series"];
        [v->keyImagePopUpButton selectItemAtIndex: 1]; [v keyImageDisplayButton: nil]; Keys(v);
    });
}

int main(int argc, const char **argv) { @autoreleasepool {
    [NSApplication sharedApplication];
    openControllers = [NSMutableArray new];
    seriesContent = [NSMutableDictionary new];
    NSEntityDescription *image = [NSEntityDescription new];
    image.name = @"Image"; image.managedObjectClassName = @"FileStub";
    NSEntityDescription *series = [NSEntityDescription new];
    series.name = @"Series"; series.managedObjectClassName = @"DicomSeries";
    NSManagedObjectModel *model = [NSManagedObjectModel new]; model.entities = @[image, series];
    imageEntity = image; seriesEntity = series;
    NSString *scenario = argc > 1 ? @(argv[1]) : @"all";
    if ([scenario isEqual: @"all"] || [scenario isEqual: @"volume"]) volumeScenario();
    if ([scenario isEqual: @"all"] || [scenario isEqual: @"fourd"]) fourdScenario();
    if ([scenario isEqual: @"all"] || [scenario isEqual: @"open3d"]) open3dScenario();
    if ([scenario isEqual: @"all"] || [scenario isEqual: @"keyimages"]) keyImagesScenario();
    fflush(stdout);
    _exit(0);
} }
'''


def git(*command):
    return subprocess.run(['git', '-C', str(ROOT), *command], capture_output=True)


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


def method(text, signature):
    """The Objective-C method that starts with `signature`, to its closing brace."""
    start = text.index(signature)
    return text[start:text.index('\n}\n', start) + 3]


def objc_blocks(text):
    """The 3D, key image and Key Objects blocks of ViewerController.m (without
    -viewerControllerInit), in a category of the stand-in."""
    a = text.index('#pragma mark 4.5.3 3D')
    b = text.index('#pragma mark-\n#pragma mark 4.5.4 Study navigation', a)
    three_d = text[a:b]
    init = '- (void) viewerControllerInit\n{'
    if init in three_d:
        three_d = three_d.replace(method(three_d, init), '')
    c = text.index('#pragma mark key image')
    d = text.index('#pragma mark-\n\n- (IBAction) endSetComments:(id) sender', c)
    return ('#import "Harness.h"\n#import "Reconstruction.h"\n#import "Helpers-Swift.h"\n#define ORIENTATION_SENSIBILITY 0.001\n'
            '@implementation ViewerController (Reconstruction)\n'
            + three_d + text[c:d] + method(text, '- (BOOL)displayOnlyKeyImages\n{') + '@end\n')


reference = args.reference
if reference is None:
    head = read('HEAD', VC)
    reference = 'HEAD' if head and MARK.encode() in head else history_reference.before_text_removed(VC, MARK)
if reference is None:
    print('skipped: needs the history that has the Objective-C ViewerController.m (a shallow clone does not)')
    sys.exit(2)
reference_vc = read(reference, VC)
if reference_vc is None or MARK.encode() not in reference_vc:
    sys.exit('FAIL: %s has no Objective-C key image block in %s' % (reference, VC))
reference_vc = reference_vc.decode('latin1')
current_vc = (read(args.current, VC) or b'').decode('latin1')  # empty once ViewerController.m is gone
current_is_objc = MARK in current_vc
# The Objective-C walked the earlier series with i++ when it looked for a key
# image back in the study: it looked at later series, or ran past the end of
# the list. The Swift walks them backwards; the reference is corrected the
# same way, so that the rest is still compared as it was.
WRONG_WALK, RIGHT_WALK = 'for( int i = indexOfObject-1; i >= 0; i++)', 'for( int i = indexOfObject-1; i >= 0; i--)'
if reference_vc.count(WRONG_WALK) != 1:
    sys.exit('FAIL: the reference %s does not walk the earlier series as expected' % reference)
reference_vc = reference_vc.replace(WRONG_WALK, RIGHT_WALK)
if current_is_objc:
    current_vc = current_vc.replace(WRONG_WALK, RIGHT_WALK)
# -openVRViewerForMode: handed back a new volume rendering window without what
# the 3D Viewer menu did to it next (this viewer's colour table and window
# level, the placement, the saved 3D state): a caller other than the menu got
# a window whose camera framed nothing. The Swift does that inside the method,
# for a new window only, in the same order; the reference is moved the same
# way, so that the menu's messages are still compared one by one.
MENU_PREPARATION = ('\n            \n            NSString *c;\n            \n            if( backCurCLUTMenu) c = backCurCLUTMenu;\n'
                    '            else c = curCLUTMenu;\n            \n            [viewer ApplyCLUTString: c];\n'
                    '            float   iwl, iww;\n            [imageView getWLWW:&iwl :&iww];\n            [viewer setWLWW:iwl :iww];\n'
                    '            [self place3DViewerWindow: viewer];\n            [viewer load3DState];')
MENU_CALL = 'viewer = [self openVRViewerForMode:mode];'
NEW_VR_END = '            [viewer setWLWW:iwl :iww];\n        }\n    }\n    return viewer;\n}'
if reference_vc.count(MENU_CALL + MENU_PREPARATION) != 1 or reference_vc.count(NEW_VR_END) != 1:
    sys.exit('FAIL: the reference %s does not open the volume rendering window as expected' % reference)
reference_vc = reference_vc.replace(MENU_CALL + MENU_PREPARATION, MENU_CALL)
reference_vc = reference_vc.replace(NEW_VR_END, NEW_VR_END.replace('        }\n    }\n', '        }\n' + MENU_PREPARATION.replace('\n            ', '\n        ') + '\n    }\n'))


def run(command, what, cwd=None):
    built = subprocess.run(command, capture_output=True, text=True, cwd=cwd)
    if built.returncode:
        sys.exit('FAIL: %s:\n%s' % (what, (built.stdout + built.stderr)[-6000:]))


def helpers(folder, revision):
    """The app's 4D, MPR opening and ROI volume classes at `revision`, copied to `folder`."""
    folder.mkdir()
    paths = []
    for name in HELPERS:
        text = read(revision, 'Horos/Sources/' + name)
        if text is None:
            sys.exit('FAIL: no Horos/Sources/%s at %s' % (name, revision or 'the tree'))
        (folder / name).write_bytes(text)
        paths.append(str(folder / name))
    return paths


with tempfile.TemporaryDirectory(prefix='horos-viewer-reconstruction-') as tmp:
    folder = Path(tmp)
    (folder / 'Harness.h').write_text(HEADER)
    (folder / 'Reconstruction.h').write_text('#import "Harness.h"\n' + RECONSTRUCTION)
    (folder / 'Stubs.m').write_text(STUBS)
    (folder / 'Driver.m').write_text('#import "Reconstruction.h"\n' + DRIVER)
    for name in ('HorosObjCException.h', 'HorosObjCException.m'):
        (folder / name).write_bytes((ROOT / 'Horos/Sources' / name).read_bytes())
    frameworks = ['-framework', 'Cocoa', '-framework', 'CoreData']

    def clang(source, extra=()):
        target = folder / (Path(source).stem + '.o')
        run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-fblocks', '-fmodules', '-w', '-I', str(folder), *extra, str(source), '-o', str(target)],
            '%s does not compile' % Path(source).name)
        return str(target)

    common = [clang(folder / 'Stubs.m'), clang(folder / 'Driver.m')]

    def objc_program(name, vc_text, revision):
        work = folder / name
        work.mkdir()
        # The reference's helpers, as an Objective-C-visible library.
        sources = helpers(work / 'helpers', revision)
        run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-module-name', 'HarnessHelpers', '-emit-library', '-static',
             '-emit-objc-header', '-emit-objc-header-path', str(folder / 'Helpers-Swift.h'), '-o', str(work / 'libHelpers.a'), *sources],
            'the helpers of %s do not compile' % name, cwd=work)
        source = work / 'Blocks.m'
        source.write_text(objc_blocks(vc_text))
        blocks = clang(source)
        program = folder / ('%s-program' % name)
        run(['xcrun', 'swiftc', *common, blocks, str(work / 'libHelpers.a'), *frameworks, '-o', str(program)], '%s does not link' % name)
        return program

    reference_program = objc_program('reference', reference_vc, reference)
    if current_is_objc:
        current_program = objc_program('current', current_vc, args.current)
        current_label = 'Objective-C of %s' % (args.current or 'the tree')
    else:
        swift = folder / 'swift'
        swift.mkdir()
        sources = []
        for name in SWIFT_FILES:
            text = read(args.current, 'Horos/Sources/' + name)
            if text is None:
                sys.exit('FAIL: no Horos/Sources/%s' % name)
            (swift / name).write_bytes(text)
            sources.append(str(swift / name))
        sources += helpers(swift / 'helpers', args.current)
        # The NSString comparison the blocks share with the window level block.
        level = read(args.current, 'Horos/Sources/ViewerController+WindowLevel.swift').decode('utf-8')
        helper = re.search(r'func viewerIsEqualToString\(.*?\n}\n', level, re.S).group(0)
        # NSSound.beep() of the AppKit overlay calls AppKit's NSBeep from its own
        # library, past the stand-in that records the Objective-C's NSBeep():
        # the harness's own NSSound.beep() records it the same way.
        (swift / 'Helpers.swift').write_text('import AppKit\n\n' + helper
                                             + '\nextension NSSound {\n    static func beep() { Record("beep") }\n}\n')
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
        run(['xcrun', 'clang', '-c', '-fobjc-arc', '-I', str(folder), str(folder / 'HorosObjCException.m'), '-o', str(folder / 'HorosObjCException.o')],
            'HorosObjCException.m does not compile')
        current_program = folder / 'current-program'
        run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', *libraries, '-import-objc-header', str(folder / 'Harness.h'),
             *sources, *common, str(folder / 'HorosObjCException.o'), *frameworks, '-o', str(current_program)],
            'the Swift blocks do not compile against the stand-ins')
        current_label = 'Swift of %s' % (args.current or 'the tree')

    failures = 0
    for scenario in SCENARIOS:
        results = {}
        for label, program in (('reference', reference_program), ('current', current_program)):
            result = subprocess.run([str(program), scenario], capture_output=True, text=True, timeout=300)
            if result.returncode:
                sys.exit('FAIL: %s %s stopped (%d):\n%s' % (label, scenario, result.returncode, (result.stdout + result.stderr)[-3000:]))
            results[label] = result.stdout
        if args.dump:
            args.dump.mkdir(parents=True, exist_ok=True)
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
    print('PASS: the volume data, ROI volume, reconstruction checks, 3D viewers and key images are identical to the Objective-C in every scenario')
