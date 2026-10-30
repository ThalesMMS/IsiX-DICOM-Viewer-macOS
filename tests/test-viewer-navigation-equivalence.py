#!/usr/bin/env python3
"""The 2D viewer's synchronization and navigation do what their Objective-C did.

ViewerController's "Multi viewport series synchronization" and "Registration"
blocks, its series, 4D and study navigation, and the comparatives list moved
from ViewerController.m to Swift extensions of the class, with their
arithmetic and rules in the IsiXImaging module. This runs the same synthetic
scenarios through both and compares everything they produce:

* synchronization: the window level, zoom, pan, rotation and 4D frame one
  viewer hands on to others under every combination of the "propagate
  settings" preferences, images of different kinds (RGB, colour table,
  subtraction, CR, NM, PET in SUV, modalities without propagation, registered
  series, images apart, undefined origins), oblique planes and fusions; the
  "Sync" button within a study and across studies, its toolbar image, the lock
  offsets and the notifications; "Re-sync origin" of a fusion (every slice's
  spacing and origin, bit for bit);
* navigation: the image shown for a requested index, flipped or not, the strip
  slider and its slab, the "Browse" player's steps (looping, bouncing,
  flipped), its toolbar item and the speed sliders handed to other viewers;
* 4D: the frames added (slices, files, volumes, ROI lists, transfer function,
  slider), the frame shown (wrapped, flipped, grid), the 4D player's steps,
  its button and its wait while the series loads;
* study navigation: the next and previous series and patient handed to the
  browser and the image they open on, the series menu, the loaded state, the
  revert and the comparatives list;
* registration: the point ROIs, their pairing by name, the points and the
  transform handed to the registration and the resampling, the refusals.

The reference is the Objective-C of ViewerController.m in the last revision
that has it (history_reference), compiled with clang as Xcode compiles it; the
other side is the current tree: the Swift files with the IsiXImaging module,
compiled with swiftc, or the Objective-C again if the tree still has it (which
is how this test ran, and passed, before the conversion). Both run over the
same stand-ins of the viewer, its views, slices, files, toolbar and the
browser, which record what they are given; the two records must be identical.

    python3 tests/test-viewer-navigation-equivalence.py [--reference REV] [--current REV] [--dump DIR]
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
MARK = '- (void) propagateSettingsToViewer: (ViewerController*) vC'
SWIFT_FILES = ['ViewerController+%s.swift' % name for name in
               ('ImagePipelineSupport', 'Synchronization', 'Registration', 'SeriesNavigation', 'FourDNavigation', 'StudyNavigation')]
SCENARIOS = ['sync', 'resync', 'navigation', '4d', 'study', 'registration']

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--reference')
parser.add_argument('--current')
parser.add_argument('--dump', type=Path, help='write the records of both programs to this folder')
args = parser.parse_args()

HEADER = r'''
#pragma clang diagnostic ignored "-Wnullability-completeness"
#import <Cocoa/Cocoa.h>
#import <CoreData/CoreData.h>
#import "HorosObjCException.h"

// The stand-ins of the viewer, its views, slices, files and the classes the
// synchronization and navigation blocks talk to, spelled as the app's headers
// spell them, so that the same Objective-C and Swift compile against them.
// They record what they are given (Record) and answer from their fields.

#define MAX4D 500
typedef NS_ENUM(short, ToolMode) { tWL = 0, tTranslate, tZoom, tRotate, tNext, tMesure, tROI, t2DPoint = 19 };
enum { syncroOFF = 0, syncroABS = 1, syncroREL = 2, syncroLOC = 3, syncroRatio = 4 };

extern NSString* const OsirixUpdateVolumeDataNotification;
extern NSString* const OsirixStopPlayingNotification;
extern NSString* const OsirixSyncSeriesNotification;
extern NSString* const OsirixDCMUpdateCurrentImageNotification;

extern NS_SWIFT_UI_ACTOR BOOL SyncButtonBehaviorIsBetweenStudies;
extern NS_SWIFT_UI_ACTOR int delayedTileWindows;

void Record(NSString *line);
NSString *Name(id object);

FOUNDATION_EXPORT NSInteger HorosRunAlertPanel(NSString * _Nullable title, NSString *format,
    NSString * _Nullable defaultButton, NSString * _Nullable alternateButton, NSString * _Nullable otherButton, ...);
FOUNDATION_EXPORT NSInteger HorosRunCriticalAlertPanel(NSString * _Nullable title, NSString *format,
    NSString * _Nullable defaultButton, NSString * _Nullable alternateButton, NSString * _Nullable otherButton, ...);

@interface HorosAlertPanel : NSObject
+ (NSInteger)runWithTitle:(nullable NSString *)title message:(NSString *)message defaultButton:(nullable NSString *)defaultButton
          alternateButton:(nullable NSString *)alternateButton otherButton:(nullable NSString *)otherButton
    NS_SWIFT_NAME(run(title:message:defaultButton:alternateButton:otherButton:));
+ (NSInteger)runCriticalWithTitle:(nullable NSString *)title message:(NSString *)message defaultButton:(nullable NSString *)defaultButton
                  alternateButton:(nullable NSString *)alternateButton otherButton:(nullable NSString *)otherButton
    NS_SWIFT_NAME(runCritical(title:message:defaultButton:alternateButton:otherButton:));
@end

@interface NSImage (HarnessToolbar)
+ (NSImage*) toolbarImageNamed: (NSString*) name;
@end

@class ViewerController, DCMPix, DCMView;

@interface DCMPix : NSObject {
@public
    double ox, oy, oz;
    float vectors[9];
    short stackValue;
    BOOL originDefined, loaded;
}
@property(nonatomic) long pwidth, pheight;
@property double pixelSpacingX, pixelSpacingY;
@property double sliceLocation;
@property(nonatomic, setter=setRGB:) BOOL isRGB;
@property BOOL SUVConverted;
@property(nonatomic, retain) NSData *transferFunction;
@property(readonly) double originX, originY, originZ;
@property(readonly) BOOL isOriginDefined;
@property(readonly) short stack;
- (void) orientation:(float*) c;
- (void) orientationDouble:(double*) c;
- (void) setOrigin :(float*) o;
- (void) computeSliceLocation;
- (NSRect) rectCoordinates;
+ (NSPoint) originDeltaBetween:(DCMPix*) pix1 And:(DCMPix*) pix2;
- (BOOL) isLoaded;
- (void) revert;
- (void) setArrayPix: (NSArray*) array :(NSInteger) i;
- (void) convertPixX: (float) x pixY: (float) y toDICOMCoords: (float*) d pixelCenter: (BOOL) pixelCenter;
@end

@interface DCMView : NSView {
@public
    NSInteger curImageValue;
    NSMutableArray *pixListValue;
    double spacing, spacingX, spacingY;
    float wl, ww;
    short syncroValue;
    BOOL propagates;
}
@property(readonly) NSMutableArray *dcmPixList;
@property(readonly) NSInteger curImage;
@property(readonly, retain) DCMPix *curDCM;
@property BOOL flippedData;
@property(nonatomic) float syncRelativeDiff;
@property long syncSeriesIndex;
@property(nonatomic) float scaleValue, rotation;
@property(nonatomic) NSPoint origin;
@property(readonly) double pixelSpacing, pixelSpacingX, pixelSpacingY;
@property NSInteger rows, columns;
+ (float) angleBetweenVector: (float*) v1 andVector: (float*) v2;
+ (BOOL) noPropagateSettingsInSeriesForModality: (NSString*) m;
- (void) setIndex:(NSInteger) index;
- (void) sendSyncMessage:(NSInteger) inc;
- (short) syncro;
- (void) setSyncro:(short) s;
- (void) becomeMainWindow;
- (void) getWLWW:(float*) wl :(float*) ww;
- (void) setWLWW:(float) wl :(float) ww;
- (BOOL) shouldPropagate;
- (void) updatePresentationStateFromSeries;
@end

@interface MyPoint : NSObject
@property float x, y;
@end

@interface ROI : NSObject
@property(retain) NSString *name;
@property ToolMode type;
@property(nonatomic, retain) DCMPix *pix;
@property(retain) NSMutableArray *points;
@end

@interface FileStub : NSManagedObject {
@public
    NSMutableDictionary *values;
}
@end

@interface SeriesView : NSObject
- (void)setPixels:(NSMutableArray*)pixels files:(NSMutableArray*)files rois:(NSMutableArray*)rois firstImage:(NSInteger)firstImage level:(char)level reset:(BOOL)reset;
@end

NS_SWIFT_NAME(ImageNavigationSlider)
@interface HorosImageNavigationSlider : NSSlider
@property NSInteger slabImageCount;
@end

NS_SWIFT_NAME(FourDSeriesGuard)
@interface HorosFourDSeriesGuard : NSObject
+ (NSInteger)wrappedIndex:(NSInteger)current count:(NSInteger)count;
+ (NSInteger)nextIndex:(NSInteger)current count:(NSInteger)count;
+ (BOOL)canStoreTimeAt:(NSInteger)index capacity:(NSInteger)capacity;
@end

@interface NavigatorView : NSObject
- (void)removeNotificationObserver;
- (void)addNotificationObserver;
@end

@interface NavigatorWindowController : NSObject
+ (nullable NavigatorWindowController*) navigatorWindowController NS_SWIFT_NAME(navigatorWindowController());
@property(readonly, nullable) NavigatorView *navigatorView;
@end

@interface AppController : NSObject
+ (AppController*) sharedAppController;
- (IBAction) tileWindows:(id)sender;
@end

@interface BrowserController : NSObject
+ (BrowserController*) currentBrowser;
- (void) loadNextPatient:(NSManagedObject *) curImage :(long) direction :(ViewerController*) viewer :(BOOL) firstViewer keyImagesOnly:(BOOL) keyImages;
- (void) loadNextSeries:(NSManagedObject *) curImage :(long) direction :(ViewerController*) viewer :(BOOL) firstViewer keyImagesOnly:(BOOL) keyImages;
- (ViewerController*) loadSeries :(NSManagedObject *)curFile :(ViewerController*) viewer :(BOOL) firstViewer keyImagesOnly:(BOOL) keyImages;
@end

@interface Wait : NSObject
- (id)initWithString:(NSString*)s;
- (void)showWindow:(id)sender;
- (void)incrementBy:(double)value;
- (void)close;
@end

@interface ITKTransform : NSObject
- (id) initWithViewer: (ViewerController *) viewer;
- (ViewerController*) computeAffineTransformWithParameters: (double*)theParameters resampleOnViewer:(ViewerController*)referenceViewer;
- (ViewerController*) computeAffineTransformWithParameters: (double*)theParameters resampleOnViewer:(ViewerController*)referenceViewer rescale: (BOOL) rescale;
@end

@interface HornRegistration : NSObject
- (void) addModelPointX: (double) x Y: (double) y Z: (double) z;
- (void) addSensorPointX: (double) x Y: (double) y Z: (double) z;
- (void) computeVTK:(double*) matrixResult;
@end

@interface WindowProbe : NSObject
@property(getter=isKeyWindow) BOOL keyWindow;
- (void)display;
@end

@interface VRController : NSWindowController
- (ViewerController*) blendingController;
- (void) updateBlendingImage;
@end

@interface OSIWindowController : NSObject
- (NSMutableArray*) pixList;
@end

NS_SWIFT_UI_ACTOR
@interface ViewerController : OSIWindowController {
@public
    NSString *nameValue, *modalityValue, *clutValue;
    DCMView *imageView;
    SeriesView *seriesView;
    NSMutableArray *pixList[MAX4D], *fileList[MAX4D], *roiList[MAX4D], *copyRoiList[MAX4D];
    NSData *volumeData[MAX4D];
    short curMovieIndex, maxMovieIndex;
    ViewerController *blendingController, *registeredViewer;
    NSToolbar *toolbar;
    NSToolbarItem *playItem;
    NSSlider *slider, *speedSlider, *movieRateSlider, *moviePosSlider;
    NSTextField *speedText, *movieTextSlide;
    NSButton *moviePlayStop, *loopButton;
    NSTimer *timer, *movieTimer;
    NSTimeInterval lastTime, lastTimeFrame, lastMovieTime;
    long speedometer;
    float direction, interval;
    NSThread *loadingThread;
    BOOL windowWillClose, requestLoadingCancel, checkEverythingLoaded, postprocessed, displayOnlyKeyImages, subtraction, volumic;
}
@property(retain) WindowProbe *window;
@property(readonly) NSSlider *speedSlider, *movieRateSlider;
@property(readonly) NSTextField *speedText, *movieTextSlide;
+ (NSMutableArray*) getDisplayed2DViewers;
+ (NSMutableArray*) get2DViewers NS_SWIFT_NONISOLATED;
- (DCMView*) imageView;
- (NSString*) modality;
- (NSString*) curCLUTMenu;
- (BOOL) subtractionActivated;
- (void) refresh;
- (ViewerController*) blendingController NS_SWIFT_NAME(blending());
- (short) maxMovieIndex NS_SWIFT_NONISOLATED;
- (NSMutableArray*) roiList;
- (NSInteger) getNumberOfImages;
- (void) adjustKeyImage;
- (void) showCurrentThumbnail:(id) sender;
- (void) setWindowTitle:(id) sender;
- (IBAction) flipDataSeries: (id) sender;
- (void) loadROI:(long) mIndex;
- (id) findPlayStopButton;
- (void) startLoadImageThread;
- (float) computeInterval;
- (BOOL) isDataVolumicIn4D:(BOOL) check4D;
- (void) displayWarningIfGantryTitled;
- (void) buildMatrixPreview: (BOOL) showSelected;
- (void) sendDidAllocateVolumeDataNotificationWithVolumeData:(NSData *)volumeData movieIndex:(NSInteger)movieIndex;
// The accessors of ViewerController+SwiftIvars.h, on the same instance variables.
@property(retain, nullable) DCMView* horos_imageView;
@property(retain, nullable) SeriesView* horos_seriesView;
@property(assign) short horos_curMovieIndex NS_SWIFT_NONISOLATED;
@property(assign) short horos_maxMovieIndex NS_SWIFT_NONISOLATED;
- (nullable NSMutableArray<DCMPix *>*)horos_pixListAt:(NSInteger)index NS_SWIFT_NONISOLATED;
- (nullable NSMutableArray*)horos_fileListAt:(NSInteger)index NS_SWIFT_NONISOLATED;
- (nullable NSMutableArray*)horos_roiListAt:(NSInteger)index;
- (void)horos_setPixList:(nullable NSMutableArray<DCMPix *>*)value at:(NSInteger)index;
- (void)horos_assignPixList:(nullable NSMutableArray<DCMPix *>*)value at:(NSInteger)index;
- (void)horos_assignFileList:(nullable NSMutableArray*)value at:(NSInteger)index;
- (void)horos_assignRoiList:(nullable NSMutableArray*)value at:(NSInteger)index;
- (void)horos_assignCopyRoiList:(nullable NSMutableArray*)value at:(NSInteger)index;
- (void)horos_assignVolumeData:(nullable NSObject*)value at:(NSInteger)index;
- (void)horos_sendDidAllocateVolumeDataNotificationForMovieIndex:(NSInteger)movieIndex;
@property(retain, nullable) ViewerController* horos_blendingController;
@property(retain, nullable) ViewerController* horos_registeredViewer;
- (void)horos_assignRegisteredViewer:(nullable ViewerController*)value;
@property(retain, nullable) NSToolbar* horos_toolbar;
@property(readonly, nullable) NSSlider* horos_slider;
@property(readonly, nullable) NSSlider* horos_speedSlider;
@property(readonly, nullable) NSSlider* horos_movieRateSlider;
@property(readonly, nullable) NSSlider* horos_moviePosSlider;
@property(readonly, nullable) NSTextField* horos_speedText;
@property(readonly, nullable) NSTextField* horos_movieTextSlide;
@property(readonly, nullable) NSButton* horos_moviePlayStop;
@property(readonly, nullable) NSButton* horos_loopButton;
@property(retain, nullable) NSTimer* horos_timer;
@property(retain, nullable) NSTimer* horos_movieTimer;
@property(assign) NSTimeInterval horos_lastTime;
@property(assign) NSTimeInterval horos_lastTimeFrame;
@property(assign) NSTimeInterval horos_lastMovieTime;
@property(assign) long horos_speedometer;
@property(assign) float horos_direction;
@property(retain, nullable) NSThread* horos_loadingThread NS_SWIFT_NONISOLATED;
@property(assign) BOOL horos_windowWillClose;
@property(assign) BOOL horos_requestLoadingCancel;
@property(assign) BOOL horos_checkEverythingLoadedFlag;
@property(assign) BOOL horos_postprocessed;
@property(assign) BOOL horos_displayOnlyKeyImages;
+ (BOOL)horos_SYNCSERIES;
+ (void)horos_setSYNCSERIES:(BOOL)value;
@end
'''

NAVIGATION = r'''// The blocks under test, as the Objective-C of the class declared them.
@interface ViewerController (Navigation)
- (id) findSyncSeriesButton;
- (void) notificationSyncSeries:(NSNotification*)note;
- (void) turnOffSyncSeriesBetweenStudies:(id) sender;
+ (void) activateSYNCSERIESBetweenStudies;
- (void) SyncSeries:(id) sender;
- (NSString*) studyInstanceUID;
- (void) SetSyncButtonBehavior:(id) sender;
- (IBAction) reSyncOrigin:(id) sender;
- (void) propagateSettingsToViewer: (ViewerController*) vC;
- (void) propagateSettings;
- (ViewerController*) registeredViewer;
- (void) setRegisteredViewer: (ViewerController*) viewer;
- (NSMutableArray*) point2DList;
- (ViewerController*) resampleSeries:(ViewerController*) movingViewer;
- (ViewerController*) resampleSeries:(ViewerController*) movingViewer rescale: (BOOL) rescale;
- (void) computeRegistrationWithMovingViewer:(ViewerController*) movingViewer;
- (NSMutableArray*) pixList: (long) i;
- (NSMutableArray*) fileList;
- (NSMutableArray*) fileList: (long) i;
- (void) addMovieSerie:(NSMutableArray*)f :(NSMutableArray*)d :(NSData*) v;
- (float) frameRate;
- (float) movieRate;
- (void) speedSliderAction:(id) sender;
- (void) movieRateSliderAction:(id) sender;
- (NSSlider*) moviePosSlider;
- (void) setMovieIndex: (short) i;
- (void) moviePosSliderAction:(id) sender;
- (void) adjustSlider;
- (short) curMovieIndex;
- (void) performMovieAnimation:(id) sender;
- (long) imageIndex;
- (void) setImageIndex:(long) i;
- (void) setImage:(NSManagedObject*) image;
- (void) performAnimation:(id) sender;
- (void) MovieStop:(id) sender;
- (void) MoviePlayStop:(id) sender;
- (BOOL) isPlaying4D;
- (void) notificationStopPlaying:(NSNotification*)note;
- (void) PlayStop:(id) sender;
- (float) frame4DRate;
- (IBAction) loadPatient:(id) sender;
- (void) loadSeries:(NSNumber*) t;
- (void) loadSeriesUp;
- (void) loadSeriesDown;
- (IBAction) loadSerie:(id) sender;
- (BOOL) isEverythingLoaded;
- (void) checkEverythingLoaded;
- (void) executeRevert;
- (void) revertSeries:(id) sender;
- (void) revertSeriesNotification:(id) note;
- (IBAction) toggleComparativesVisibility:(id) sender;
@end
'''

STUBS = r'''
#import "Harness.h"
#include <math.h>

NSString* const OsirixUpdateVolumeDataNotification = @"OsirixUpdateVolumeDataNotification";
NSString* const OsirixStopPlayingNotification = @"OsirixStopPlayingNotification";
NSString* const OsirixSyncSeriesNotification = @"OsirixSyncSeriesNotification";
NSString* const OsirixDCMUpdateCurrentImageNotification = @"OsirixDCMUpdateCurrentImageNotification";
BOOL SyncButtonBehaviorIsBetweenStudies = NO;
int delayedTileWindows = 0;
BOOL SYNCSERIES = NO;

static NSMutableArray *records;
static NSMapTable *names;
NSMutableArray *viewers2D;

void Record(NSString *line) { if (!records) records = [NSMutableArray new]; [records addObject: line]; }
void Register(id object, NSString *name) {
    if (!names) names = [[NSMapTable alloc] initWithKeyOptions: NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality
                                                   valueOptions: NSPointerFunctionsStrongMemory capacity: 64];
    if (object) { [object retain]; [names setObject: name forKey: object]; }
}
NSString *Name(id object) {
    if (object == nil) return @"nil";
    NSString *name = [names objectForKey: object];
    return name ? name : [NSString stringWithFormat: @"<%@>", NSStringFromClass([object class])];
}
NSArray *Records(void) { return records; }

static NSString *AlertText(NSString *kind, NSString *title, NSString *message, NSString *d, NSString *a, NSString *o) {
    return [NSString stringWithFormat: @"%@ alert: %@ | %@ | %@ %@ %@", kind, title, message, d, a, o];
}
NSInteger HorosRunAlertPanel(NSString *title, NSString *format, NSString *d, NSString *a, NSString *o, ...) {
    va_list args; va_start(args, o);
    NSString *message = [[[NSString alloc] initWithFormat: format arguments: args] autorelease];
    va_end(args);
    Record(AlertText(@"plain", title, message, d, a, o)); return 1;
}
NSInteger HorosRunCriticalAlertPanel(NSString *title, NSString *format, NSString *d, NSString *a, NSString *o, ...) {
    va_list args; va_start(args, o);
    NSString *message = [[[NSString alloc] initWithFormat: format arguments: args] autorelease];
    va_end(args);
    Record(AlertText(@"critical", title, message, d, a, o)); return 1;
}
@implementation HorosAlertPanel
+ (NSInteger)runWithTitle:(NSString *)title message:(NSString *)message defaultButton:(NSString *)d alternateButton:(NSString *)a otherButton:(NSString *)o
{ Record(AlertText(@"plain", title, message, d, a, o)); return 1; }
+ (NSInteger)runCriticalWithTitle:(NSString *)title message:(NSString *)message defaultButton:(NSString *)d alternateButton:(NSString *)a otherButton:(NSString *)o
{ Record(AlertText(@"critical", title, message, d, a, o)); return 1; }
@end

@implementation NSImage (HarnessToolbar)
+ (NSImage*) toolbarImageNamed: (NSString*) name {
    NSImage *image = [[[NSImage alloc] initWithSize: NSMakeSize(1, 1)] autorelease];
    Register(image, [@"image " stringByAppendingString: name]);
    return image;
}
@end

@implementation DCMPix
@synthesize pwidth, pheight, pixelSpacingX, pixelSpacingY, sliceLocation, isRGB, SUVConverted, transferFunction;
- (double) originX { return ox; }
- (double) originY { return oy; }
- (double) originZ { return oz; }
- (BOOL) isOriginDefined { return originDefined; }
- (short) stack { return stackValue; }
- (void) orientation:(float*) c { for (int i = 0; i < 9; i++) c[i] = vectors[i]; }
- (void) orientationDouble:(double*) c { for (int i = 0; i < 9; i++) c[i] = vectors[i]; }
- (void) setOrigin :(float*) o {
    ox = o[0]; oy = o[1]; oz = o[2];
    Record([NSString stringWithFormat: @"%@ setOrigin %a %a %a", Name(self), o[0], o[1], o[2]]);
}
- (void) computeSliceLocation { self.sliceLocation = ox * vectors[6] + oy * vectors[7] + oz * vectors[8]; }
- (NSRect) rectCoordinates { return NSMakeRect(ox, oy, pwidth * pixelSpacingX, pheight * pixelSpacingY); }
+ (NSPoint) originDeltaBetween:(DCMPix*) pix1 And:(DCMPix*) pix2 { return NSMakePoint(pix1->ox - pix2->ox, pix1->oy - pix2->oy); }
- (BOOL) isLoaded { return loaded; }
- (void) revert { Record([NSString stringWithFormat: @"%@ revert", Name(self)]); }
- (void) setArrayPix: (NSArray*) array :(NSInteger) i { Record([NSString stringWithFormat: @"%@ setArrayPix %@ %ld", Name(self), Name(array), (long)i]); }
- (void) convertPixX: (float) x pixY: (float) y toDICOMCoords: (float*) d pixelCenter: (BOOL) pixelCenter {
    for (int k = 0; k < 3; k++) d[k] = (float)((k == 0 ? ox : k == 1 ? oy : oz) + x * pixelSpacingX * vectors[k] + y * pixelSpacingY * vectors[3 + k]);
}
@end

@implementation DCMView
@synthesize flippedData, syncRelativeDiff, syncSeriesIndex, scaleValue, rotation, origin, rows, columns;
- (NSMutableArray*) dcmPixList { return pixListValue; }
- (NSInteger) curImage { return curImageValue; }
- (DCMPix*) curDCM { return curImageValue >= 0 && curImageValue < (NSInteger)pixListValue.count ? [pixListValue objectAtIndex: curImageValue] : nil; }
- (double) pixelSpacing { return spacing; }
- (double) pixelSpacingX { return spacingX; }
- (double) pixelSpacingY { return spacingY; }
+ (float) angleBetweenVector: (float*) a andVector: (float*) b {
    float d = a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
    if (d > 1) d = 1;
    if (d < -1) d = -1;
    return acosf(d) * 180.0f / (float) M_PI;
}
+ (BOOL) noPropagateSettingsInSeriesForModality: (NSString*) m { return [m isEqualToString: @"MG"] || [m isEqualToString: @"DX"]; }
- (void) setIndex:(NSInteger) index { curImageValue = index; Record([NSString stringWithFormat: @"%@ setIndex %ld", Name(self), (long)index]); }
- (void) sendSyncMessage:(NSInteger) inc { Record([NSString stringWithFormat: @"%@ sendSyncMessage %ld", Name(self), (long)inc]); }
- (short) syncro { return syncroValue; }
- (void) setSyncro:(short) s { syncroValue = s; Record([NSString stringWithFormat: @"%@ setSyncro %d", Name(self), s]); }
- (void) becomeMainWindow { Record([NSString stringWithFormat: @"%@ becomeMainWindow", Name(self)]); }
- (void) getWLWW:(float*) l :(float*) w { if (l) *l = wl; if (w) *w = ww; }
- (void) setWLWW:(float) l :(float) w { wl = l; ww = w; Record([NSString stringWithFormat: @"%@ setWLWW %a %a", Name(self), l, w]); }
- (BOOL) shouldPropagate { return propagates; }
- (void) updatePresentationStateFromSeries { Record([NSString stringWithFormat: @"%@ updatePresentationStateFromSeries", Name(self)]); }
- (void) displayIfNeeded { Record([NSString stringWithFormat: @"%@ displayIfNeeded", Name(self)]); }
- (void) setNeedsDisplay:(BOOL) flag { Record([NSString stringWithFormat: @"%@ setNeedsDisplay %d", Name(self), flag]); }
@end

@implementation MyPoint
@synthesize x, y;
@end
@implementation ROI
@synthesize name, type, pix, points;
- (void) setPix:(DCMPix*) value { [value retain]; [pix release]; pix = value; Record([NSString stringWithFormat: @"%@ setPix %@", name, Name(value)]); }
@end

@implementation FileStub
- (id) valueForKey: (NSString*) key { return [values objectForKey: key]; }
- (id) valueForKeyPath: (NSString*) key { return [values objectForKey: key]; }
@end

@implementation SeriesView
- (void)setPixels:(NSMutableArray*)p files:(NSMutableArray*)f rois:(NSMutableArray*)r firstImage:(NSInteger)i level:(char)l reset:(BOOL)reset {
    Record([NSString stringWithFormat: @"seriesView setPixels %@ %@ %@ %ld %c %d", Name(p), Name(f), Name(r), (long)i, l, reset]);
}
@end

@implementation HorosImageNavigationSlider
@synthesize slabImageCount;
@end

@implementation HorosFourDSeriesGuard
+ (NSInteger)wrappedIndex:(NSInteger)current count:(NSInteger)count {
    if (count <= 0) return 0;
    if (current >= 0 && current < count) return current;
    if (current == NSIntegerMin) return 0;
    NSInteger r = current % count;
    return r >= 0 ? r : r + count;
}
+ (NSInteger)nextIndex:(NSInteger)current count:(NSInteger)count {
    if (count <= 0) return 0;
    if (current == NSIntegerMax) return 0;
    return [self wrappedIndex: current + 1 count: count];
}
+ (BOOL)canStoreTimeAt:(NSInteger)index capacity:(NSInteger)capacity { return index >= 0 && index < capacity; }
@end

@implementation NavigatorView
- (void)removeNotificationObserver {}
- (void)addNotificationObserver {}
@end
@implementation NavigatorWindowController
+ (NavigatorWindowController*) navigatorWindowController { return nil; }
- (NavigatorView*) navigatorView { return nil; }
@end

@implementation AppController
+ (AppController*) sharedAppController { static AppController *shared; if (!shared) shared = [AppController new]; return shared; }
- (IBAction) tileWindows:(id)sender { Record(@"AppController tileWindows"); }
- (void) willChangeValueForKey:(NSString *)key { Record([@"AppController willChange " stringByAppendingString: key]); }
- (void) didChangeValueForKey:(NSString *)key { Record([@"AppController didChange " stringByAppendingString: key]); }
@end

@implementation BrowserController
+ (BrowserController*) currentBrowser { static BrowserController *shared; if (!shared) shared = [BrowserController new]; return shared; }
- (void) loadNextPatient:(NSManagedObject *) image :(long) direction :(ViewerController*) viewer :(BOOL) first keyImagesOnly:(BOOL) key {
    Record([NSString stringWithFormat: @"browser loadNextPatient %@ %ld %@ %d %d", Name(image), direction, Name(viewer), first, key]);
}
- (void) loadNextSeries:(NSManagedObject *) image :(long) direction :(ViewerController*) viewer :(BOOL) first keyImagesOnly:(BOOL) key {
    Record([NSString stringWithFormat: @"browser loadNextSeries %@ %ld %@ %d %d next-to-all %d", Name(image), direction, Name(viewer), first, key,
            [[NSUserDefaults standardUserDefaults] boolForKey: @"nextSeriesToAllViewers"]]);
}
- (ViewerController*) loadSeries :(NSManagedObject *) series :(ViewerController*) viewer :(BOOL) first keyImagesOnly:(BOOL) key {
    Record([NSString stringWithFormat: @"browser loadSeries %@ %@ %d %d", Name(series), Name(viewer), first, key]);
    return nil;
}
@end

@implementation Wait
- (id)initWithString:(NSString*)s { if ((self = [super init])) Record([@"wait " stringByAppendingString: s]); return self; }
- (void)showWindow:(id)sender { Record(@"wait show"); }
- (void)incrementBy:(double)value {}
- (void)close { Record(@"wait close"); }
@end

@implementation ITKTransform
- (id) initWithViewer: (ViewerController *) viewer { if ((self = [super init])) Record([@"itk viewer " stringByAppendingString: Name(viewer)]); return self; }
- (ViewerController*) computeAffineTransformWithParameters: (double*) p resampleOnViewer:(ViewerController*) v {
    NSMutableString *line = [NSMutableString stringWithFormat: @"itk transform on %@:", Name(v)];
    for (int i = 0; i < 16; i++) [line appendFormat: @" %a", p[i]];
    Record(line); return nil;
}
- (ViewerController*) computeAffineTransformWithParameters: (double*) p resampleOnViewer:(ViewerController*) v rescale: (BOOL) rescale {
    NSMutableString *line = [NSMutableString stringWithFormat: @"itk transform on %@ rescale %d:", Name(v), rescale];
    for (int i = 0; i < 12; i++) [line appendFormat: @" %a", p[i]];
    Record(line); return nil;
}
@end

@implementation HornRegistration {
    double sum;
}
- (void) addModelPointX: (double) x Y: (double) y Z: (double) z { sum += x + 2 * y + 3 * z; Record([NSString stringWithFormat: @"horn model %a %a %a", x, y, z]); }
- (void) addSensorPointX: (double) x Y: (double) y Z: (double) z { sum -= x + 2 * y + 3 * z; Record([NSString stringWithFormat: @"horn sensor %a %a %a", x, y, z]); }
- (void) computeVTK:(double*) m { for (int i = 0; i < 16; i++) m[i] = sum * (i + 1); }
@end

@implementation WindowProbe
@synthesize keyWindow;
- (void)display { Record(@"window display"); }
@end

@implementation VRController
- (ViewerController*) blendingController { return nil; }
- (void) updateBlendingImage {}
@end

@implementation OSIWindowController
- (NSMutableArray*) pixList { return nil; }
@end

@implementation ViewerController
@synthesize window, speedSlider, movieRateSlider, speedText, movieTextSlide;
+ (NSMutableArray*) getDisplayed2DViewers { return [[viewers2D mutableCopy] autorelease]; }
+ (NSMutableArray*) get2DViewers { return [[viewers2D mutableCopy] autorelease]; }
- (DCMView*) imageView { return imageView; }
- (NSString*) modality { return modalityValue; }
- (NSString*) curCLUTMenu { return clutValue; }
- (BOOL) subtractionActivated { return subtraction; }
- (void) refresh { Record([nameValue stringByAppendingString: @" refresh"]); }
- (ViewerController*) blendingController { return blendingController; }
- (short) maxMovieIndex { return maxMovieIndex; }
- (NSMutableArray*) roiList { return roiList[curMovieIndex]; }
- (NSInteger) getNumberOfImages { return [pixList[curMovieIndex] count]; }
- (void) adjustKeyImage { Record([nameValue stringByAppendingString: @" adjustKeyImage"]); }
- (void) showCurrentThumbnail:(id) sender { Record([nameValue stringByAppendingString: @" showCurrentThumbnail"]); }
- (void) setWindowTitle:(id) sender { Record([nameValue stringByAppendingString: @" setWindowTitle"]); }
- (IBAction) flipDataSeries: (id) sender { imageView.flippedData = !imageView.flippedData; Record([nameValue stringByAppendingString: @" flipDataSeries"]); }
- (void) loadROI:(long) i { Record([NSString stringWithFormat: @"%@ loadROI %ld", nameValue, i]); }
- (id) findPlayStopButton { return playItem; }
- (void) startLoadImageThread { Record([nameValue stringByAppendingString: @" startLoadImageThread"]); }
- (float) computeInterval { Record([nameValue stringByAppendingString: @" computeInterval"]); return interval; }
- (BOOL) isDataVolumicIn4D:(BOOL) check4D { Record([NSString stringWithFormat: @"%@ isDataVolumicIn4D %d", nameValue, check4D]); return volumic; }
- (void) displayWarningIfGantryTitled { Record([nameValue stringByAppendingString: @" displayWarningIfGantryTitled"]); }
- (void) buildMatrixPreview: (BOOL) showSelected { Record([NSString stringWithFormat: @"%@ buildMatrixPreview %d", nameValue, showSelected]); }
- (void) sendDidAllocateVolumeDataNotificationWithVolumeData:(NSData *)data movieIndex:(NSInteger)i {
    Record([NSString stringWithFormat: @"%@ didAllocateVolumeData %@ %ld", nameValue, Name(data), (long)i]);
}
- (void)horos_sendDidAllocateVolumeDataNotificationForMovieIndex:(NSInteger)i {
    [self sendDidAllocateVolumeDataNotificationWithVolumeData: volumeData[i] movieIndex: i];
}
- (DCMView*) horos_imageView { return imageView; }
- (void) setHoros_imageView:(DCMView*) v { imageView = v; }
- (SeriesView*) horos_seriesView { return seriesView; }
- (void) setHoros_seriesView:(SeriesView*) v { seriesView = v; }
- (short) horos_curMovieIndex { return curMovieIndex; }
- (void) setHoros_curMovieIndex:(short) v { curMovieIndex = v; }
- (short) horos_maxMovieIndex { return maxMovieIndex; }
- (void) setHoros_maxMovieIndex:(short) v { maxMovieIndex = v; }
- (NSMutableArray*) horos_pixListAt:(NSInteger) i { return pixList[i]; }
- (NSMutableArray*) horos_fileListAt:(NSInteger) i { return fileList[i]; }
- (NSMutableArray*) horos_roiListAt:(NSInteger) i { return roiList[i]; }
- (void) horos_setPixList:(NSMutableArray*) v at:(NSInteger) i { [v retain]; [pixList[i] release]; pixList[i] = v; }
- (void) horos_assignPixList:(NSMutableArray*) v at:(NSInteger) i { pixList[i] = v; }
- (void) horos_assignFileList:(NSMutableArray*) v at:(NSInteger) i { fileList[i] = v; }
- (void) horos_assignRoiList:(NSMutableArray*) v at:(NSInteger) i { roiList[i] = v; }
- (void) horos_assignCopyRoiList:(NSMutableArray*) v at:(NSInteger) i { copyRoiList[i] = v; }
- (void) horos_assignVolumeData:(NSObject*) v at:(NSInteger) i { volumeData[i] = (NSData*) v; }
- (ViewerController*) horos_blendingController { return blendingController; }
- (void) setHoros_blendingController:(ViewerController*) v { blendingController = v; }
- (ViewerController*) horos_registeredViewer { return registeredViewer; }
- (void) setHoros_registeredViewer:(ViewerController*) v { [v retain]; [registeredViewer release]; registeredViewer = v; }
- (void) horos_assignRegisteredViewer:(ViewerController*) v { registeredViewer = v; }
- (NSToolbar*) horos_toolbar { return toolbar; }
- (void) setHoros_toolbar:(NSToolbar*) v { toolbar = v; }
- (NSSlider*) horos_slider { return slider; }
- (NSSlider*) horos_speedSlider { return speedSlider; }
- (NSSlider*) horos_movieRateSlider { return movieRateSlider; }
- (NSSlider*) horos_moviePosSlider { return moviePosSlider; }
- (NSTextField*) horos_speedText { return speedText; }
- (NSTextField*) horos_movieTextSlide { return movieTextSlide; }
- (NSButton*) horos_moviePlayStop { return moviePlayStop; }
- (NSButton*) horos_loopButton { return loopButton; }
- (NSTimer*) horos_timer { return timer; }
- (void) setHoros_timer:(NSTimer*) v { [v retain]; [timer release]; timer = v; }
- (NSTimer*) horos_movieTimer { return movieTimer; }
- (void) setHoros_movieTimer:(NSTimer*) v { [v retain]; [movieTimer release]; movieTimer = v; }
- (NSTimeInterval) horos_lastTime { return lastTime; }
- (void) setHoros_lastTime:(NSTimeInterval) v { lastTime = v; }
- (NSTimeInterval) horos_lastTimeFrame { return lastTimeFrame; }
- (void) setHoros_lastTimeFrame:(NSTimeInterval) v { lastTimeFrame = v; }
- (NSTimeInterval) horos_lastMovieTime { return lastMovieTime; }
- (void) setHoros_lastMovieTime:(NSTimeInterval) v { lastMovieTime = v; }
- (long) horos_speedometer { return speedometer; }
- (void) setHoros_speedometer:(long) v { speedometer = v; }
- (float) horos_direction { return direction; }
- (void) setHoros_direction:(float) v { direction = v; }
- (NSThread*) horos_loadingThread { return loadingThread; }
- (void) setHoros_loadingThread:(NSThread*) v { [v retain]; [loadingThread release]; loadingThread = v; }
- (BOOL) horos_windowWillClose { return windowWillClose; }
- (void) setHoros_windowWillClose:(BOOL) v { windowWillClose = v; }
- (BOOL) horos_requestLoadingCancel { return requestLoadingCancel; }
- (void) setHoros_requestLoadingCancel:(BOOL) v { requestLoadingCancel = v; }
- (BOOL) horos_checkEverythingLoadedFlag { return checkEverythingLoaded; }
- (void) setHoros_checkEverythingLoadedFlag:(BOOL) v { checkEverythingLoaded = v; }
- (BOOL) horos_postprocessed { return postprocessed; }
- (void) setHoros_postprocessed:(BOOL) v { postprocessed = v; }
- (BOOL) horos_displayOnlyKeyImages { return displayOnlyKeyImages; }
- (void) setHoros_displayOnlyKeyImages:(BOOL) v { displayOnlyKeyImages = v; }
+ (BOOL) horos_SYNCSERIES { return SYNCSERIES; }
+ (void) horos_setSYNCSERIES:(BOOL) v { SYNCSERIES = v; }
@end
'''

DRIVER = r'''
#import "Harness.h"
#include <math.h>

extern NSMutableArray *viewers2D;
extern BOOL SYNCSERIES;
void Register(id object, NSString *name);
NSArray *Records(void);


static NSEntityDescription *imageEntity;

static FileStub *File(NSString *name, NSString *study) {
    FileStub *file = [[FileStub alloc] initWithEntity: imageEntity insertIntoManagedObjectContext: nil];
    file->values = [@{@"series.study.studyInstanceUID": study, @"completePath": [NSString stringWithFormat: @"/data/%@.dcm", name]} mutableCopy];
    Register(file, name);
    return file;
}

static DCMPix *Pix(NSString *name, int i, const float *v, double ox, double oy, double oz, double spacing) {
    DCMPix *pix = [DCMPix new];
    for (int k = 0; k < 9; k++) pix->vectors[k] = v[k];
    pix->ox = ox + i * v[6] * 1.25; pix->oy = oy + i * v[7] * 1.25; pix->oz = oz + i * v[8] * 1.25;
    pix->originDefined = YES; pix->loaded = YES;
    pix->stackValue = 1;
    pix.pwidth = 64; pix.pheight = 48;
    pix.pixelSpacingX = spacing; pix.pixelSpacingY = spacing * 1.1;
    [pix computeSliceLocation];
    Register(pix, [NSString stringWithFormat: @"%@.pix%d", name, i]);
    return pix;
}

static const float axial[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
static const float oblique[9] = {0.8f, 0.6f, 0, -0.6f, 0.8f, 0, 0, 0, 1};
static const float tilted[9] = {1, 0, 0, 0, 0.6f, 0.8f, 0, -0.8f, 0.6f};

static NSMutableArray *Series(NSString *name, int movie, int count, const float *v, double ox, double oy, double oz, double spacing) {
    NSMutableArray *slices = [NSMutableArray array];
    for (int i = 0; i < count; i++) [slices addObject: Pix([NSString stringWithFormat: @"%@.m%d", name, movie], i, v, ox, oy, oz + movie * 0.5, spacing)];
    Register(slices, [NSString stringWithFormat: @"%@.pixList%d", name, movie]);
    return slices;
}

@interface ToolbarSource : NSObject <NSToolbarDelegate>
@end
@implementation ToolbarSource
- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)identifier willBeInsertedIntoToolbar:(BOOL)flag {
    return [[[NSToolbarItem alloc] initWithItemIdentifier: identifier] autorelease];
}
- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar { return @[@"Sync.pdf", @"Play.pdf"]; }
- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar { return @[@"Sync.pdf", @"Play.pdf"]; }
@end

static ViewerController *Viewer(NSString *name, NSString *study, NSString *modality, int movies, int count, const float *v, double oz, double spacing) {
    ViewerController *viewer = [ViewerController new];
    viewer->nameValue = [name retain]; viewer->modalityValue = [modality retain]; viewer->clutValue = [@"No CLUT" retain];
    Register(viewer, name);
    for (int m = 0; m < movies; m++) {
        viewer->pixList[m] = [Series(name, m, count, v, 10, -20, oz, spacing) retain];
        NSMutableArray *files = [NSMutableArray array], *rois = [NSMutableArray array], *copies = [NSMutableArray array];
        for (int i = 0; i < count; i++) {
            [files addObject: File([NSString stringWithFormat: @"%@.m%d.file%d", name, m, i], study)];
            [rois addObject: [NSMutableArray array]];
            [copies addObject: [NSData data]];
        }
        viewer->fileList[m] = [files retain]; viewer->roiList[m] = [rois retain]; viewer->copyRoiList[m] = [copies retain];
        Register(files, [NSString stringWithFormat: @"%@.fileList%d", name, m]);
        Register(rois, [NSString stringWithFormat: @"%@.roiList%d", name, m]);
        viewer->volumeData[m] = [[NSData dataWithBytes: "v" length: 1] retain];
        Register(viewer->volumeData[m], [NSString stringWithFormat: @"%@.volume%d", name, m]);
    }
    viewer->maxMovieIndex = movies;
    DCMView *view = [[DCMView alloc] initWithFrame: NSMakeRect(0, 0, 100, 100)];
    view->pixListValue = [viewer->pixList[0] retain];
    view->spacing = spacing; view->spacingX = spacing; view->spacingY = spacing * 1.1;
    view->propagates = YES; view.scaleValue = 1; view.rows = 1; view.columns = 1;
    Register(view, [name stringByAppendingString: @".view"]);
    viewer->imageView = view;
    viewer->seriesView = [SeriesView new];
    HorosImageNavigationSlider *strip = [HorosImageNavigationSlider new];
    viewer->slider = strip;
    viewer->speedSlider = [NSSlider new]; viewer->speedSlider.maxValue = 100; viewer->speedSlider.floatValue = 60;
    viewer->movieRateSlider = [NSSlider new]; viewer->movieRateSlider.maxValue = 100; viewer->movieRateSlider.floatValue = 60;
    viewer->moviePosSlider = [NSSlider new]; viewer->moviePosSlider.maxValue = 100;
    viewer->speedText = [NSTextField new]; viewer->movieTextSlide = [NSTextField new];
    viewer->moviePlayStop = [NSButton new]; viewer->loopButton = [NSButton new];
    [viewer->loopButton setButtonType: NSButtonTypePushOnPushOff];
    viewer->direction = 1; viewer->interval = 1.25f; viewer->volumic = YES;
    viewer.window = [[WindowProbe new] autorelease];
    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier: [@"toolbar." stringByAppendingString: name]];
    ToolbarSource *source = [ToolbarSource new];
    toolbar.delegate = source;
    [toolbar insertItemWithItemIdentifier: @"Sync.pdf" atIndex: 0];
    [toolbar insertItemWithItemIdentifier: @"Play.pdf" atIndex: 1];
    viewer->toolbar = toolbar;
    for (NSToolbarItem *item in toolbar.items) {
        Register(item, [NSString stringWithFormat: @"%@.item.%@", name, item.itemIdentifier]);
        if ([item.itemIdentifier isEqualToString: @"Play.pdf"]) viewer->playItem = [item retain];
    }
    return viewer;
}

static NSString *F(double x) { return [NSString stringWithFormat: @"%a", x]; }

static void State(ViewerController *v) {
    DCMView *view = v->imageView;
    float wl, ww; [view getWLWW: &wl :&ww];
    Record([NSString stringWithFormat: @"%@ state: image %d flipped %d movie %d/%d wl %@ ww %@ scale %@ origin %@ %@ rotation %@ syncro %d syncIndex %ld diff %@ slider %d slab %ld movieSlider %d max %@ ticks %ld enabled %d/%d/%d registered %@ fusion %@ SYNCSERIES %d between %d",
            Name(v), view.curImage, view.flippedData, v->curMovieIndex, v->maxMovieIndex, F(wl), F(ww), F(view.scaleValue),
            F(view.origin.x), F(view.origin.y), F(view.rotation), [view syncro], view.syncSeriesIndex, F(view.syncRelativeDiff),
            v->slider.intValue, (long)((HorosImageNavigationSlider*) v->slider).slabImageCount, v->moviePosSlider.intValue,
            F(v->moviePosSlider.maxValue), (long)v->moviePosSlider.numberOfTickMarks, v->movieRateSlider.isEnabled, v->moviePosSlider.isEnabled,
            v->moviePlayStop.isEnabled, Name(v->registeredViewer), Name(v->blendingController), SYNCSERIES, SyncButtonBehaviorIsBetweenStudies]);
    for (NSToolbarItem *item in v->toolbar.items)
        Record([NSString stringWithFormat: @"%@ item %@ image %@ label %@ palette %@ tip %@", Name(v), item.itemIdentifier, Name(item.image), item.label, item.paletteLabel, item.toolTip]);
}

static void Slices(ViewerController *v, int movie) {
    for (DCMPix *pix in v->pixList[movie])
        Record([NSString stringWithFormat: @"%@ origin %@ %@ %@ spacing %@ %@ location %@ tf %@", Name(pix), F(pix.originX), F(pix.originY), F(pix.originZ),
                F(pix.pixelSpacingX), F(pix.pixelSpacingY), F(pix.sliceLocation), Name(pix.transferFunction)]);
}

static void Defaults(NSDictionary *values) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    for (NSString *key in @[@"COPYSETTINGS", @"DONTCOPYWLWWSETTINGS", @"DONTCOPYZOOMSETTINGS", @"DONTCOPYPANSETTINGS", @"DONTCOPYROTATIONSETTINGS",
                            @"AlwaysPropagateScaleLevel", @"PARALLELPLANETOLERANCE", @"nextSeriesToAllViewers", @"listPODComparativesIn2DViewer",
                            @"defaultFrameRate", @"defaultMovieRate"])
        [d removeObjectForKey: key];
    [d setFloat: 5 forKey: @"PARALLELPLANETOLERANCE"];
    for (NSString *key in values) [d setObject: values[key] forKey: key];
}

static void ResetView(ViewerController *v, float wl, float ww, float scale, NSPoint origin, float rotation) {
    v->imageView->wl = wl; v->imageView->ww = ww; v->imageView.scaleValue = scale; v->imageView.origin = origin; v->imageView.rotation = rotation;
}

static void syncScenario(void) {
    ViewerController *a = Viewer(@"A", @"1.2.1", @"CT", 1, 6, axial, 0, 0.7);
    ViewerController *b = Viewer(@"B", @"1.2.1", @"CT", 1, 6, axial, 0.5, 0.9);
    ViewerController *c = Viewer(@"C", @"1.2.9", @"MR", 1, 6, axial, 3, 1.3);
    ViewerController *o = Viewer(@"O", @"1.2.1", @"CT", 1, 6, oblique, 0, 0.7);
    // B's images lie a little apart in the plane, so the pan it receives moves.
    for (DCMPix *pix in b->pixList[0]) { pix->ox += 2.5; pix->oy -= 1.25; }
    viewers2D = [@[a, b, c, o] mutableCopy];
    NSArray *configs = @[@{@"COPYSETTINGS": @YES}, @{@"COPYSETTINGS": @NO}, @{@"COPYSETTINGS": @YES, @"DONTCOPYWLWWSETTINGS": @YES},
                         @{@"COPYSETTINGS": @YES, @"DONTCOPYZOOMSETTINGS": @YES}, @{@"COPYSETTINGS": @YES, @"DONTCOPYPANSETTINGS": @YES},
                         @{@"COPYSETTINGS": @YES, @"DONTCOPYROTATIONSETTINGS": @YES}, @{@"COPYSETTINGS": @YES, @"AlwaysPropagateScaleLevel": @YES},
                         @{@"COPYSETTINGS": @YES, @"PARALLELPLANETOLERANCE": @45}];
    for (NSDictionary *config in configs) {
        Defaults(config);
        Record([@"config " stringByAppendingString: [[config description] stringByReplacingOccurrencesOfString: @"\n" withString: @" "]]);
        ResetView(a, 40, 400, 1.75f, NSMakePoint(3.5, -2.25), 30);
        for (ViewerController *v in @[b, c, o]) ResetView(v, 10, 100, 1, NSMakePoint(0, 0), 0);
        [a propagateSettings];
        for (ViewerController *v in @[b, c, o]) State(v);
    }
    // What decides the window level: the kind of images, the colour table, the subtraction, SUV.
    Defaults(@{@"COPYSETTINGS": @YES});
    NSArray *kinds = @[@"rgb", @"clut", @"subtraction", @"CR", @"NM", @"PT", @"PT-SUV", @"MG", @"no-propagate", @"registered", @"apart", @"undefined", @"empty"];
    for (NSString *kind in kinds) {
        ViewerController *d = Viewer([@"D-" stringByAppendingString: kind], [kind isEqual: @"registered"] ? @"1.2.7" : @"1.2.1", @"CT", 1, 6, axial, 0, 0.5);
        if ([kind isEqual: @"rgb"]) d->imageView.curDCM.isRGB = YES;
        if ([kind isEqual: @"clut"]) { [d->clutValue release]; d->clutValue = [@"Hot Iron" retain]; }
        if ([kind isEqual: @"subtraction"]) d->subtraction = YES;
        if ([kind hasPrefix: @"PT"]) { a->modalityValue = @"PT"; d->modalityValue = @"PT"; }
        if ([kind isEqual: @"PT-SUV"]) d->imageView.curDCM.SUVConverted = YES;
        if ([kind isEqual: @"CR"] || [kind isEqual: @"NM"] || [kind isEqual: @"MG"]) d->modalityValue = [kind retain];
        if ([kind isEqual: @"no-propagate"]) { a->modalityValue = @"MG"; d->modalityValue = @"DX"; }
        if ([kind isEqual: @"registered"]) [a setRegisteredViewer: d];
        if ([kind isEqual: @"apart"]) d->imageView.curDCM->ox = 5000;
        if ([kind isEqual: @"undefined"]) d->imageView.curDCM->originDefined = NO;
        if ([kind isEqual: @"empty"]) { [d->fileList[0] release]; d->fileList[0] = nil; }
        ResetView(a, 40, 400, 1.75f, NSMakePoint(3.5, -2.25), 30);
        ResetView(d, 10, 100, 1, NSMakePoint(0, 0), 0);
        d->imageView->propagates = ![kind isEqual: @"empty"];
        [a propagateSettingsToViewer: d];
        State(d);
        a->modalityValue = @"CT";
        [a setRegisteredViewer: nil];
    }
    // A fused viewer passes the settings on to its fusion; a fusion back to the viewer refreshes.
    b->blendingController = c;
    ResetView(c, 10, 100, 1, NSMakePoint(0, 0), 0);
    [a propagateSettingsToViewer: b];
    State(c);
    b->blendingController = a;
    [a propagateSettingsToViewer: b];
    b->blendingController = nil;
    // 4D: the other viewer goes to the same frame.
    ViewerController *f1 = Viewer(@"F1", @"1.2.1", @"CT", 3, 4, axial, 0, 0.7), *f2 = Viewer(@"F2", @"1.2.1", @"CT", 3, 4, axial, 0, 0.7);
    f1->curMovieIndex = 2;
    [f1 propagateSettingsToViewer: f2];
    State(f2);
    // The "Sync" button within a study and across studies.
    Defaults(@{});
    viewers2D = [@[a, b] mutableCopy];
    [a SetSyncButtonBehavior: nil];
    State(a); State(b);
    [a SyncSeries: nil]; State(a);
    [a SyncSeries: nil]; State(a);
    [a notificationSyncSeries: [NSNotification notificationWithName: OsirixSyncSeriesNotification object: a userInfo: @{@"sliceLocation": @1.5f}]];
    State(a);
    a->imageView->syncroValue = syncroLOC;
    [a notificationSyncSeries: nil];
    State(a);
    viewers2D = [@[a, b, c] mutableCopy];
    [a SetSyncButtonBehavior: nil];
    State(a); State(b); State(c);
    [a->imageView setIndex: 3];
    [a SyncSeries: nil];
    State(a);
    [b notificationSyncSeries: [NSNotification notificationWithName: OsirixSyncSeriesNotification object: a userInfo: @{@"sliceLocation": @2.75f}]];
    State(b);
    [a SyncSeries: nil];
    [b notificationSyncSeries: [NSNotification notificationWithName: OsirixSyncSeriesNotification object: a userInfo: @{@"sliceLocation": @2.75f}]];
    State(b);
    [ViewerController activateSYNCSERIESBetweenStudies];
    State(a); State(b); State(c);
    [c turnOffSyncSeriesBetweenStudies: nil];
    State(c);
    [c SetSyncButtonBehavior: nil];
    State(c);
    SyncButtonBehaviorIsBetweenStudies = NO;
    [ViewerController activateSYNCSERIESBetweenStudies];
    Record([NSString stringWithFormat: @"studies %@ %@ %@ button %@", [a studyInstanceUID], [c studyInstanceUID], [f1 studyInstanceUID], Name([a findSyncSeriesButton])]);
}

static void resync(void) {
    ViewerController *a = Viewer(@"R", @"1.3.1", @"PT", 2, 5, tilted, 4, 2.5);
    ViewerController *b = Viewer(@"S", @"1.3.1", @"CT", 1, 7, tilted, -3, 0.75);
    viewers2D = [@[a, b] mutableCopy];
    Defaults(@{});
    [a reSyncOrigin: nil];
    a->blendingController = b;
    ResetView(a, 1, 2, 1.3f, NSMakePoint(12.5, -7.25), 0);
    ResetView(b, 1, 2, 2.6f, NSMakePoint(-4.125, 3.5), 0);
    [a->imageView setIndex: 2]; [b->imageView setIndex: 4];
    [a reSyncOrigin: nil];
    Slices(a, 0); Slices(a, 1); State(a);
    Defaults(@{@"COPYSETTINGS": @YES});
    a->imageView->syncroValue = syncroLOC;
    [a reSyncOrigin: nil];
    a->blendingController = nil;
}

static void navigation(void) {
    Defaults(@{});
    ViewerController *n = Viewer(@"N", @"1.4.1", @"CT", 2, 5, axial, 0, 1);
    viewers2D = [@[n] mutableCopy];
    for (DCMPix *pix in n->pixList[0]) pix->stackValue = 3;
    for (NSNumber *flip in @[@NO, @YES]) {
        n->imageView.flippedData = flip.boolValue;
        for (NSNumber *i in @[@-5, @0, @3, @4, @9]) {
            [n setImageIndex: i.longValue];
            Record([NSString stringWithFormat: @"index %@ flipped %@ -> image %d index %ld", i, flip, n->imageView.curImage, [n imageIndex]]);
            State(n);
        }
    }
    n->imageView.flippedData = NO;
    [n setImage: n->fileList[1][3]];
    State(n);
    [n setImage: File(@"stranger", @"0")];
    // The "Browse" player: a step per tick, looping or bouncing.
    for (NSNumber *loops in @[@YES, @NO]) {
        for (NSNumber *flip in @[@NO, @YES]) {
            n->loopButton.state = loops.boolValue ? NSControlStateValueOn : NSControlStateValueOff;
            n->imageView.flippedData = flip.boolValue;
            n->direction = 1; [n->imageView setIndex: 3];
            for (int step = 0; step < 9; step++) {
                n->lastTime = 0; n->lastTimeFrame = 1e15;
                [n performAnimation: nil];
                Record([NSString stringWithFormat: @"browse loops %@ flipped %@ step %d -> image %d direction %@ speedometer %ld", loops, flip, step,
                        n->imageView.curImage, F(n->direction), n->speedometer]);
            }
        }
    }
    n->imageView.flippedData = NO;
    n->windowWillClose = YES; [n performAnimation: nil]; n->windowWillClose = NO;
    NSMutableArray *one = [n->pixList[0] retain];
    n->pixList[0] = [@[one[0]] mutableCopy]; n->lastTime = 0; [n performAnimation: nil];
    n->pixList[0] = one;
    State(n);
    // Start and stop the player from its toolbar item.
    n->speedSlider.floatValue = 12; n->direction = -1;
    [n PlayStop: n->playItem];
    Record([NSString stringWithFormat: @"playing %d", n->timer != nil]);
    State(n);
    [n notificationStopPlaying: nil];
    Record([NSString stringWithFormat: @"playing %d speed %@", n->timer != nil, n->speedText.stringValue]);
    State(n);
    [n PlayStop: n->playItem]; [n PlayStop: n->playItem];
    Record([NSString stringWithFormat: @"playing %d frameRate %@", n->timer != nil, F([n frameRate])]);
    // The speed sliders, handed to the other viewers at the default speed.
    ViewerController *m = Viewer(@"M", @"1.4.1", @"CT", 1, 3, axial, 0, 1);
    viewers2D = [@[n, m] mutableCopy];
    Defaults(@{@"defaultFrameRate": @60, @"defaultMovieRate": @60});
    n.window.keyWindow = YES; n->speedSlider.floatValue = 25; m->direction = -1;
    [n speedSliderAction: nil];
    n->movieRateSlider.floatValue = 7;
    [n movieRateSliderAction: nil];
    Record([NSString stringWithFormat: @"rates %@ %@ %@ %@ texts %@ %@ %@ %@ defaults %@ %@", F([m frameRate]), F([m movieRate]), F([m frame4DRate]), F([n movieRate]),
            n->speedText.stringValue, m->speedText.stringValue, n->movieTextSlide.stringValue, m->movieTextSlide.stringValue,
            [[NSUserDefaults standardUserDefaults] objectForKey: @"defaultFrameRate"], [[NSUserDefaults standardUserDefaults] objectForKey: @"defaultMovieRate"]]);
    n->imageView.flippedData = YES; [n->imageView setIndex: 1];
    [n adjustSlider];
    State(n);
    Record([NSString stringWithFormat: @"lists %@ %@ %@ %@ %@ %@", Name([n pixList]), Name([n pixList: 1]), Name([n pixList: 7]), Name([n fileList]), Name([n fileList: -1]), Name([n fileList: 1])]);
}

static void fourD(void) {
    Defaults(@{});
    ViewerController *t = Viewer(@"T", @"1.5.1", @"CT", 1, 4, axial, 0, 1);
    viewers2D = [@[t] mutableCopy];
    NSData *tf = [NSData dataWithBytes: "tf" length: 2]; Register(tf, @"tf");
    for (DCMPix *pix in t->pixList[0]) pix.transferFunction = tf;
    for (int m = 1; m < 3; m++) {
        NSMutableArray *slices = Series(@"T", m, 4, axial, 10, -20, 0, 1), *files = [NSMutableArray array];
        for (int i = 0; i < 4; i++) [files addObject: File([NSString stringWithFormat: @"T.m%d.file%d", m, i], @"1.5.1")];
        Register(files, [NSString stringWithFormat: @"T.fileList%d", m]);
        NSData *volume = [NSData dataWithBytes: "w" length: 1]; Register(volume, [NSString stringWithFormat: @"T.volume%d", m]);
        [t addMovieSerie: slices :files :volume];
        Record([NSString stringWithFormat: @"added %d: lists %@ %@ volume %@ rois %lu copies %lu", m, Name(t->pixList[m]), Name(t->fileList[m]), Name(t->volumeData[m]),
                (unsigned long)[t->roiList[m] count], (unsigned long)[t->copyRoiList[m] count]]);
        Slices(t, m);
        State(t);
    }
    short saved = t->maxMovieIndex;
    t->maxMovieIndex = MAX4D;
    [t addMovieSerie: [NSMutableArray array] :[NSMutableArray array] :[NSData data]];
    t->maxMovieIndex = saved;
    for (NSNumber *flip in @[@NO, @YES]) {
        for (NSNumber *grid in @[@1, @2]) {
            t->imageView.flippedData = flip.boolValue; t->imageView.columns = grid.integerValue;
            for (NSNumber *i in @[@1, @5, @-1, @0]) {
                [t->imageView setIndex: 2];
                [t setMovieIndex: i.shortValue];
                State(t);
            }
            [t->imageView setIndex: 0];
            [t setMovieIndex: 1];
            State(t);
        }
    }
    t->imageView.flippedData = NO; t->imageView.columns = 1;
    t->moviePosSlider.intValue = 2;
    [t moviePosSliderAction: nil];
    State(t);
    for (int step = 0; step < 4; step++) {
        t->lastMovieTime = 0;
        [t performMovieAnimation: nil];
        Record([NSString stringWithFormat: @"4D step %d -> movie %d (%d)", step, t->curMovieIndex, [t curMovieIndex]]);
    }
    NSThread *loading = [[NSThread alloc] initWithTarget: t selector: @selector(description) object: nil];
    [loading.threadDictionary setObject: @0.2f forKey: @"loadingPercentage"];
    t->loadingThread = loading; t->lastMovieTime = 0;
    [t performMovieAnimation: nil];
    Record([NSString stringWithFormat: @"4D while loading -> movie %d", t->curMovieIndex]);
    t->loadingThread = nil;
    ViewerController *other = Viewer(@"U", @"1.5.1", @"CT", 1, 2, axial, 0, 1);
    viewers2D = [@[t, other] mutableCopy];
    [t MoviePlayStop: nil];
    Record([NSString stringWithFormat: @"4D playing %d title %@", [t isPlaying4D], t->moviePlayStop.title]);
    [t MoviePlayStop: nil];
    Record([NSString stringWithFormat: @"4D playing %d title %@ text %@", [t isPlaying4D], t->moviePlayStop.title, t->movieTextSlide.stringValue]);
    [t MovieStop: nil];
    Record([NSString stringWithFormat: @"4D playing %d title %@ slider %@", [t isPlaying4D], t->moviePlayStop.title, Name([t moviePosSlider]) ]);
}

@interface Represented : NSObject
@property(retain) id object;
@end
@implementation Represented
@synthesize object;
@end

static void study(void) {
    ViewerController *s = Viewer(@"P", @"1.6.1", @"CT", 2, 5, axial, 0, 1);
    viewers2D = [@[s] mutableCopy];
    for (NSNumber *all in @[@NO, @YES]) {
        for (NSNumber *flip in @[@NO, @YES]) {
            Defaults(@{@"nextSeriesToAllViewers": all});
            s->imageView.flippedData = flip.boolValue;
            [s loadSeries: @1]; [s loadSeries: @-1];
            [s loadSeriesUp]; [s loadSeriesDown];
            Record([NSString stringWithFormat: @"next to all after %d", [[NSUserDefaults standardUserDefaults] boolForKey: @"nextSeriesToAllViewers"]]);
        }
    }
    s->imageView.flippedData = NO;
    delayedTileWindows = 1;
    NSButton *next = [NSButton new]; next.tag = 1; NSButton *previous = [NSButton new]; previous.tag = -1;
    [s loadPatient: next];
    Record([NSString stringWithFormat: @"delayed %d", delayedTileWindows]);
    [s loadPatient: previous];
    s->displayOnlyKeyImages = YES;
    delayedTileWindows = 1;
    [s loadSerie: next]; [s loadSerie: previous];
    NSPopUpButton *menu = [[NSPopUpButton alloc] initWithFrame: NSZeroRect pullsDown: NO];
    menu.tag = 3; [menu addItemWithTitle: @"series"];
    Represented *represented = [Represented new]; represented.object = File(@"chosen-series", @"1.6.1");
    menu.selectedItem.representedObject = represented;
    menu.selectedItem.image = [NSImage toolbarImageNamed: @"thumb"];
    [s loadSerie: menu];
    Record([NSString stringWithFormat: @"menu image %@", Name(menu.selectedItem.image)]);
    s->windowWillClose = YES;
    [s loadSeries: @1]; [s loadSerie: next]; [s loadPatient: next]; [s loadSeriesUp];
    s->windowWillClose = NO;
    // Loaded or not.
    Record([NSString stringWithFormat: @"loaded %d", [s isEverythingLoaded]]);
    ((DCMPix*) s->pixList[0][2])->loaded = NO;
    Record([NSString stringWithFormat: @"loaded %d", [s isEverythingLoaded]]);
    NSThread *thread = [[NSThread alloc] initWithTarget: s selector: @selector(description) object: nil];
    s->loadingThread = thread;
    Record([NSString stringWithFormat: @"loaded %d", [s isEverythingLoaded]]);
    s->requestLoadingCancel = YES;
    [s checkEverythingLoaded];
    s->requestLoadingCancel = NO; s->loadingThread = nil;
    [s checkEverythingLoaded];
    s->windowWillClose = YES; [s checkEverythingLoaded]; s->windowWillClose = NO;
    // Revert.
    [s executeRevert];
    s->postprocessed = YES; [s revertSeries: nil]; s->postprocessed = NO;
    [s revertSeriesNotification: [NSNotification notificationWithName: @"revert" object: s->pixList[1]]];
    [s revertSeriesNotification: [NSNotification notificationWithName: @"revert" object: [NSMutableArray array]]];
    // Comparatives.
    ViewerController *q = Viewer(@"Q", @"1.6.2", @"CT", 1, 2, axial, 0, 1);
    viewers2D = [@[s, q] mutableCopy];
    Defaults(@{});
    [s toggleComparativesVisibility: nil];
    [s toggleComparativesVisibility: nil];
    Record([NSString stringWithFormat: @"comparatives %d", [[NSUserDefaults standardUserDefaults] boolForKey: @"listPODComparativesIn2DViewer"]]);
    State(s);
}

static ROI *PointROI(NSString *name, ToolMode type, float x, float y) {
    ROI *roi = [ROI new]; roi.name = name; roi.type = type;
    MyPoint *point = [MyPoint new]; point.x = x; point.y = y;
    roi.points = [NSMutableArray arrayWithObject: point];
    return roi;
}

static void registration(void) {
    Defaults(@{});
    ViewerController *fixed = Viewer(@"G", @"1.7.1", @"CT", 1, 4, axial, 0, 0.8);
    ViewerController *moving = Viewer(@"H", @"1.7.2", @"MR", 1, 4, tilted, 5, 1.1);
    ViewerController *same = Viewer(@"K", @"1.7.1", @"CT", 1, 4, oblique, 2, 0.9);
    viewers2D = [@[fixed, moving, same] mutableCopy];
    [fixed setRegisteredViewer: moving];
    Record([NSString stringWithFormat: @"registered %@", Name([fixed registeredViewer])]);
    [fixed setRegisteredViewer: nil];
    NSArray *cases = @[@[@"Point 10", @"Point 2", @"Point 1"], @[@"Point 1", @"Point 2"], @[@"A", @"B", @"C"], @[@"A", @"A", @"A"], @[@"X", @"Y", @"Z", @"W"]];
    NSArray *other = @[@[@"Point 1", @"Point 10", @"Point 2"], @[@"Point 1", @"Point 2"], @[@"A", @"B", @"D"], @[@"A", @"A", @"A"], @[@"W", @"X", @"Y"]];
    for (NSUInteger k = 0; k < cases.count; k++) {
        for (ViewerController *v in @[fixed, moving]) {
            NSArray *names = v == fixed ? cases[k] : other[k];
            for (NSUInteger s = 0; s < 4; s++) [v->roiList[0][s] removeAllObjects];
            for (NSUInteger i = 0; i < names.count; i++) {
                [v->roiList[0][i % 4] addObject: PointROI(names[i], t2DPoint, 3.5f + i * 7, 9.25f - i * 2)];
                [v->roiList[0][(i + 1) % 4] addObject: PointROI([names[i] stringByAppendingString: @" area"], tROI, 1, 1)];
            }
        }
        NSMutableArray *list = [fixed point2DList];
        NSMutableString *line = [NSMutableString stringWithString: @"points:"];
        for (ROI *roi in list) [line appendFormat: @" %@@%@", roi.name, Name(roi.pix)];
        Record(line);
        [fixed computeRegistrationWithMovingViewer: moving];
    }
    moving->volumic = NO;
    [fixed computeRegistrationWithMovingViewer: moving];
    moving->volumic = YES; moving->interval = 0;
    [fixed computeRegistrationWithMovingViewer: moving];
    moving->interval = 1;
    // Same study: by orientation alone.
    [fixed resampleSeries: same];
    [fixed resampleSeries: same rescale: NO];
    [fixed resampleSeries: moving];
    same->volumic = NO; [fixed resampleSeries: same]; same->volumic = YES;
    // A single slice: volumic only with an orientation.
    ViewerController *single = Viewer(@"L", @"1.7.1", @"CT", 1, 1, axial, 0, 1);
    [fixed resampleSeries: single];
    for (int k = 6; k < 9; k++) ((DCMPix*) single->pixList[0][0])->vectors[k] = 0;
    [fixed resampleSeries: single];
    Record([NSString stringWithFormat: @"resample in new orientation %@", Name([fixed performSelector: @selector(resampleSeriesInNewOrientation)])]);
}

int main(int argc, const char **argv) { @autoreleasepool {
    [NSApplication sharedApplication];
    NSEntityDescription *entity = [NSEntityDescription new];
    entity.name = @"Image"; entity.managedObjectClassName = @"FileStub";
    NSManagedObjectModel *model = [NSManagedObjectModel new]; model.entities = @[entity];
    imageEntity = entity;
    for (NSString *name in @[OsirixSyncSeriesNotification, OsirixStopPlayingNotification, OsirixUpdateVolumeDataNotification, OsirixDCMUpdateCurrentImageNotification])
        [[NSNotificationCenter defaultCenter] addObserverForName: name object: nil queue: nil usingBlock: ^(NSNotification *note) {
            NSMutableArray *info = [NSMutableArray array];
            for (NSString *key in [[note.userInfo allKeys] sortedArrayUsingSelector: @selector(compare:)]) {
                id value = note.userInfo[key];
                [info addObject: [NSString stringWithFormat: @"%@=%@", key, [value isKindOfClass: [NSNumber class]] ? F([value doubleValue]) : Name(value)]];
            }
            Record([NSString stringWithFormat: @"notification %@ object %@ %@", note.name, Name(note.object), [info componentsJoinedByString: @","]]);
        }];
    NSString *scenario = argc > 1 ? @(argv[1]) : @"all";
    if ([scenario isEqual: @"all"] || [scenario isEqual: @"sync"]) { Record(@"== sync"); syncScenario(); }
    if ([scenario isEqual: @"all"] || [scenario isEqual: @"resync"]) { Record(@"== resync"); resync(); }
    if ([scenario isEqual: @"all"] || [scenario isEqual: @"navigation"]) { Record(@"== navigation"); navigation(); }
    if ([scenario isEqual: @"all"] || [scenario isEqual: @"4d"]) { Record(@"== 4d"); fourD(); }
    if ([scenario isEqual: @"all"] || [scenario isEqual: @"study"]) { Record(@"== study"); study(); }
    if ([scenario isEqual: @"all"] || [scenario isEqual: @"registration"]) { Record(@"== registration"); registration(); }
    for (NSString *line in Records()) printf("%s\n", line.UTF8String);
} return 0; }
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


def module_sources(revision, name='IsiXImaging'):
    """The Swift sources of module `name` at `revision` (None: the tree)."""
    base = 'Modules/%s/Sources' % name
    if revision is None:
        return {str(p.relative_to(ROOT / base)): p.read_bytes() for p in sorted((ROOT / base).rglob('*.swift'))}
    listed = git('ls-tree', '-r', '--name-only', revision, base).stdout.decode().split()
    return {p[len(base) + 1:]: read(revision, p) for p in listed if p.endswith('.swift')}


def objc_blocks(text):
    """The synchronization, registration, navigation and comparatives blocks of
    ViewerController.m, in a category of the stand-in, with the function and
    the statics of the file they use."""
    a = text.index('#pragma mark 4.3 Multi viewport series synchronization')
    b = text.index('#pragma mark-\n#pragma mark 4.5 External functions', a)
    c = text.index('#pragma mark 4.5.4 Study navigation')
    d = text.index('#pragma mark key image', c)
    e = text.index('- (IBAction)toggleComparativesVisibility:(id)sender {')
    f = text.index('\n}\n', e) + 3
    s = text.index('NSInteger sortROIByName(id roi1, id roi2, void *context)')
    t = text.index('\n}\n', s) + 3
    return ('#import "Harness.h"\n#import "Navigation.h"\nextern BOOL SYNCSERIES;\n'
            'static NSString* PlayToolbarItemIdentifier = @"Play.pdf";\n'
            'static NSString* PauseToolbarItemIdentifier = @"Pause.pdf";\n'
            'static NSString* SyncSeriesToolbarItemIdentifier = @"Sync.pdf";\n'
            + text[s:t] + '\n@implementation ViewerController (Navigation)\n'
            + text[a:b] + text[c:d] + text[e:f] + '@end\n')


reference = args.reference
if reference is None:
    head = read('HEAD', VC)
    reference = 'HEAD' if head and MARK.encode() in head else history_reference.before_text_removed(VC, MARK)
if reference is None:
    print('skipped: needs the history that has the Objective-C ViewerController.m (a shallow clone does not)')
    sys.exit(2)
reference_vc = read(reference, VC)
if reference_vc is None or MARK.encode() not in reference_vc:
    sys.exit('FAIL: %s has no Objective-C synchronization block in %s' % (reference, VC))
reference_vc = reference_vc.decode('latin1')
current_vc = (read(args.current, VC) or b'').decode('latin1')  # empty once ViewerController.m is gone
current_is_objc = MARK in current_vc


def compile_objc(folder, sources, output, extra=()):
    objects = []
    for source in sources:
        target = folder / (Path(source).stem + '.o')
        built = subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-fblocks', '-w', '-I', str(folder), *extra,
                                str(source), '-o', str(target)], capture_output=True, text=True)
        if built.returncode:
            sys.exit('FAIL: %s does not compile:\n%s' % (Path(source).name, built.stderr[-3000:]))
        objects.append(str(target))
    return objects


def run(program):
    result = subprocess.run([str(program)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        sys.exit('FAIL: %s stopped (%d):\n%s' % (program.name, result.returncode, (result.stdout + result.stderr)[-3000:]))
    return result.stdout.splitlines()


with tempfile.TemporaryDirectory(prefix='horos-viewer-navigation-') as tmp:
    folder = Path(tmp)
    (folder / 'Harness.h').write_text(HEADER)
    (folder / 'Navigation.h').write_text('#import "Harness.h"\n' + NAVIGATION)
    (folder / 'Stubs.m').write_text(STUBS)
    (folder / 'Driver.m').write_text('#import "Navigation.h"\n' + DRIVER)
    for name in ('HorosObjCException.h', 'HorosObjCException.m'):
        (folder / name).write_bytes((ROOT / 'Horos/Sources' / name).read_bytes())
    frameworks = ['-framework', 'Cocoa', '-framework', 'CoreData']
    common = compile_objc(folder, [folder / 'Stubs.m', folder / 'Driver.m'], folder)

    def objc_program(name, vc_text):
        source = folder / ('%s-Blocks.m' % name)
        source.write_text(objc_blocks(vc_text))
        objects = compile_objc(folder, [source], folder)
        program = folder / name
        linked = subprocess.run(['xcrun', 'clang', *common, *objects, *frameworks, '-o', str(program)], capture_output=True, text=True)
        if linked.returncode:
            sys.exit('FAIL: %s does not link:\n%s' % (name, linked.stderr[-3000:]))
        return program

    reference_program = objc_program('reference', reference_vc)
    if current_is_objc:
        current_program = objc_program('current', current_vc)
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
        # The NSString comparison the blocks share with the window level block.
        level = read(args.current, 'Horos/Sources/ViewerController+WindowLevel.swift').decode('utf-8')
        helper = re.search(r'func viewerIsEqualToString\(.*?\n}\n', level, re.S).group(0)
        (swift / 'Helpers.swift').write_text('import Foundation\n\n' + helper)
        sources.append(str(swift / 'Helpers.swift'))
        module = folder / 'module'
        module.mkdir()
        # IsiXLogging, which IsiXImaging writes its log through, when the revision has it.
        logging = folder / 'logging'
        logging.mkdir()
        for relative, text in module_sources(args.current, 'IsiXLogging').items():
            (logging / relative.replace('/', '_')).write_bytes(text)
        linked = []
        if list(logging.glob('*.swift')):
            built = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-module-name', 'IsiXLogging',
                                    '-emit-library', '-static', '-emit-module', '-emit-module-path', str(logging / 'IsiXLogging.swiftmodule'),
                                    '-o', str(logging / 'libIsiXLogging.a'), *map(str, sorted(logging.glob('*.swift')))],
                                   capture_output=True, text=True, cwd=logging)
            if built.returncode:
                sys.exit('FAIL: IsiXLogging does not compile:\n%s' % built.stderr[-3000:])
            linked = ['-I', str(logging), '-L', str(logging), '-lIsiXLogging']
        for relative, text in module_sources(args.current).items():
            target = module / relative.replace('/', '_')
            target.write_bytes(text)
        built = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-module-name', 'IsiXImaging', *linked,
                                '-emit-library', '-static', '-emit-module', '-emit-module-path', str(module / 'IsiXImaging.swiftmodule'),
                                '-o', str(module / 'libIsiXImaging.a'), *map(str, sorted(module.glob('*.swift')))],
                               capture_output=True, text=True, cwd=module)
        if built.returncode:
            sys.exit('FAIL: IsiXImaging does not compile:\n%s' % built.stderr[-3000:])
        exception = subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', '-I', str(folder), str(folder / 'HorosObjCException.m'),
                                    '-o', str(folder / 'HorosObjCException.o')], capture_output=True, text=True)
        if exception.returncode:
            sys.exit('FAIL: HorosObjCException.m:\n%s' % exception.stderr[-2000:])
        current_program = folder / 'current'
        built = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-I', str(module), '-L', str(module), '-lIsiXImaging', *linked,
                                '-import-objc-header', str(folder / 'Harness.h'), *sources, *common, str(folder / 'HorosObjCException.o'),
                                *frameworks, '-o', str(current_program)], capture_output=True, text=True)
        if built.returncode:
            sys.exit('FAIL: the Swift blocks do not compile against the stand-ins:\n%s' % built.stderr[-6000:])
        current_label = 'Swift of %s' % (args.current or 'the tree')

    failures = 0
    for scenario in SCENARIOS:
        expected = run_scenario = None
        result_reference = subprocess.run([str(reference_program), scenario], capture_output=True, text=True, timeout=300)
        result_current = subprocess.run([str(current_program), scenario], capture_output=True, text=True, timeout=300)
        for label, result in (('reference', result_reference), ('current', result_current)):
            if result.returncode:
                sys.exit('FAIL: %s %s stopped (%d):\n%s' % (label, scenario, result.returncode, (result.stdout + result.stderr)[-3000:]))
        expected, got = result_reference.stdout.splitlines(), result_current.stdout.splitlines()
        if args.dump:
            args.dump.mkdir(parents=True, exist_ok=True)
            (args.dump / ('%s-reference.txt' % scenario)).write_text(result_reference.stdout)
            (args.dump / ('%s-current.txt' % scenario)).write_text(result_current.stdout)
        if expected == got:
            print('%s: %d records identical (%s against the Objective-C of %s)' % (scenario, len(expected), current_label, reference))
        else:
            failures += 1
            print('FAIL: %s differs (%s against the Objective-C of %s):' % (scenario, current_label, reference))
            for line in list(difflib.unified_diff(expected, got, 'reference', 'current', lineterm='', n=1))[:60]:
                print('  ' + line)
    if failures:
        sys.exit(1)
    print('PASS: synchronization, registration, series, 4D and study navigation are identical to the Objective-C in every scenario')
