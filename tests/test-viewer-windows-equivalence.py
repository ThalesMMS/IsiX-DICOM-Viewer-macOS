#!/usr/bin/env python3
"""The 2D viewer's register, saved layout, window life, tiling and full screen
do what their Objective-C did.

The register of the 2D viewers (+get2DViewers, +getDisplayed2DViewers, the
front viewer, the displayed studies and series with their colours and
numbers, +studyColors), the saved layout ("windows state"), the life of the
window (loaded, titled, main, miniaturized, closed, +closeAllWindows, the wait
windows), the tiling and frames of the windows (+newWindow:::,
-SetWindowsTiling:, the zoom button, -setWindowFrame...) and the full screen
moved from ViewerController.m to Swift extensions of the class, with the
arithmetic of the frames and the rules of a saved layout in the IsiXImaging
module. This runs the same synthetic scenarios through both and compares
everything they produce:

* registry: the viewers registered and displayed (closing and full screen
  windows left out), the front viewer of the key, main and ordered windows on
  a screen or any, the studies and series shown, their window colours and
  numbers, the study colours;
* state: the property list saved into each study (as the XML written, the
  date left out), for whole and partial layouts of two patients, 4D frames of
  several series, raster series, flipped and SUV images, the sync settings,
  and a layout that cannot be saved; the archive as DICOM SR, the reset, the
  load and the naming sheet;
* lifecycle: the window loaded, the title in every case, the wait windows,
  the close refused or turned into closing all, miniaturized, main and screen
  changes, the close itself (what stops, what is released, the register, the
  tiling) and +closeAllWindows, with the retain counts of what is released;
* layout: +newWindow::: (given the viewer's own volume), the tiling menu
  closing and opening viewers, the zoom button's frame and -setWindowFrame...;
* fullscreen: entering and leaving, with the image tiling, the zoom fit, the
  settings propagation and the toolbar panel, and leaving when the
  application is left.

The reference is the Objective-C of ViewerController.m in the last revision
that has it (history_reference), compiled with clang as Xcode compiles it
(manual retain and release); the other side is the current tree: the Swift
files with IsiXImaging, compiled with swiftc, or the Objective-C again if the
tree still has it (which is how this test ran, and passed, before the
conversion). Both run over the same stand-ins of the viewer, its windows and
views, the application (its windows and event), AppController, the browser
and the panels, which record what they are given; the two records must be
identical.

    python3 tests/test-viewer-windows-equivalence.py [--reference REV] [--current REV] [--dump DIR]
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
MARK = '+ (NSMutableArray*) getDisplayed2DViewers'
SWIFT_FILES = ['ViewerController+%s.swift' % name for name in
               ('ViewerRegistry', 'WindowsState', 'WindowLifecycle', 'WindowLayout', 'FullScreen')]
# IsiXLogging first: the others that log write through it.
MODULES = ['IsiXLogging', 'IsiXImaging']
SCENARIOS = ['registry', 'state', 'lifecycle', 'layout', 'fullscreen']

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--reference')
parser.add_argument('--current')
parser.add_argument('--dump', type=Path, help='write the records of both programs to this folder')
args = parser.parse_args()

HEADER = r'''#pragma clang diagnostic ignored "-Wnullability-completeness"
#import <Cocoa/Cocoa.h>
#import <CoreData/CoreData.h>
#import "HorosObjCException.h"

// The stand-ins of the viewer, its windows, views, slices and files, and of
// the classes the window blocks talk to (the application, AppController, the
// browser, the panels, the window colours and policies), declared as the
// app's headers declare them (with the Swift names of the app's Swift
// classes), so that the Objective-C and the Swift compile against them alike.
// They record what they are given (Record) and answer from their fields.

#define MAX4D 8
#define MAXSCREENS 10

void Record(NSString *line);
NSString *Name(id object);
void Register(id object, NSString *name);

void HarnessLogException(NSException *e);
#define N2LogExceptionWithStackTrace(e) HarnessLogException(e)
#define N2LogStackTrace(format, ...) Record([@"stack " stringByAppendingString: [NSString stringWithFormat: format, ##__VA_ARGS__]])
void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *function);
void ViewerControllerLogStackTrace(NSString *message);
void N2LogStackTraceMessage(NSString *message);
void HorosDetachAutounbinder(id owner);

extern NS_SWIFT_UI_ACTOR int delayedTileWindows;
extern NS_SWIFT_UI_ACTOR BOOL SyncButtonBehaviorIsBetweenStudies;
extern BOOL HarnessSYNCSERIES;
extern NSString* const OsirixCloseViewerNotification;

enum { syncroOFF = 0, syncroABS = 1, syncroREL = 2, syncroLOC = 3, syncroRatio = 4};

@class ViewerController, DCMView, DCMPix, DicomSeries, DicomStudy, ThumbnailsListPanel;

extern ThumbnailsListPanel *thumbnailsListPanel[MAXSCREENS];
ThumbnailsListPanel * _Nullable AppControllerCAPIThumbnailsListPanel(NSInteger index);

@interface NSUserDefaults (HarnessDates)
+ (NSDateFormatter*) dateFormatter;
+ (NSString*) formatDateTime:(NSDate*) date;
@end

@interface NSWindow (HarnessSheets)
- (void) orderOutAndEndSheetWithReturnCode:(NSModalResponse) code NS_SWIFT_NAME(orderOutAndEndSheet(returnCode:));
@end

/// A window that never reaches the window server: shown, ordered, closed,
/// framed and titled in its own fields, each call recorded.
@interface HarnessWindow : NSWindow
@property BOOL harnessVisible;
@property(retain) NSScreen *harnessScreen;
@property(retain) id nextMain;
@end

@interface NSFullScreenWindow : HarnessWindow
@end

/// The application: its windows, their order, the key and main ones, and the
/// modifier keys of the current event.
@interface HarnessApplication : NSApplication
@property(retain) NSArray *harnessWindows, *harnessOrdered;
@property(retain) NSWindow *harnessKey, *harnessMain;
@property NSEventModifierFlags harnessFlags;
@end

@interface HarnessPopUp : NSPopUpButton
@property NSInteger harnessTag;
@end

/// A managed object (inserted in a context without a store, so that it has
/// an object ID) whose keys are a dictionary.
@interface KVCStub : NSManagedObject {
@public
    NSMutableDictionary *values;
}
+ (instancetype) stub;
@end

@interface DicomStudy : KVCStub
@property(retain) NSArray *series;
- (NSArray*) imageSeriesContainingPixels:(BOOL) pixels;
- (void) archiveWindowsStateAsDICOMSR;
@end

@interface DicomSeries : KVCStub
@end

@interface FileStub : KVCStub
@end

@interface DCMPix : NSObject
@property BOOL SUVConverted;
@property BOOL generated;
@property(retain) NSString *generatedName;
@property(retain) NSString *srcFile;
@property(retain) DicomSeries *series;
- (float) storedWindowLevelForCalibratedLevel:(float) level;
- (DicomSeries*) seriesObj;
@end

@interface DCMView : NSView
@property(readonly) NSInteger curImage;
@property(retain) DCMPix *curDCM;
@property float curWW, curWL;
@property NSInteger rows, columns;
@property BOOL flippedData;
@property(nonatomic) float scaleValue, rotation;
@property(nonatomic) NSPoint origin;
@property(nonatomic) BOOL xFlipped, yFlipped;
@property(nonatomic) float syncRelativeDiff;
@property BOOL drawing;
@property BOOL scaledFit;
@property(retain) DicomSeries *series;
+ (short) syncro;
+ (void) setHarnessSyncro:(short) value;
- (void) setIndex:(NSInteger) index;
- (void) sendSyncMessage:(NSInteger) inc;
- (void) stopROIEditingForce:(BOOL) force;
- (void) setWLWW:(float) wl :(float) ww;
- (void) checkCursor;
- (BOOL) isScaledFit;
- (void) scaleToFit;
- (DicomSeries *)seriesObj;
@end

@interface SeriesView : NSView
@property(retain) NSArray *harnessImageViews;
- (NSMutableArray*) imageViews;
- (DCMView*) firstView;
@end

@interface StudyView : NSView
@property(retain) NSArray *harnessSeriesViews;
- (NSMutableArray*) seriesViews;
@end

@interface ThumbnailsListPanel : NSWindowController
@property(readonly, retain) NSView *thumbnailsView;
- (void) setThumbnailsView:(NSView*) view viewer:(ViewerController*) viewer;
- (void) thumbnailsListWillClose:(NSView*) view;
- (void) harnessLend:(NSView*) view;
@end

@interface ToolbarPanelController : NSWindowController
+ (void) checkForValidToolbar;
@end

@interface HarnessSeriesLoad : NSObject
@property(retain) NSString *owner;
- (void) requestCancel;
- (void) close;
@end

@interface OSIWindowController : NSWindowController
+ (void) setDontEnterMagneticFunctions:(BOOL) a;
+ (BOOL) dontWindowDidChangeScreen;
+ (void) setHarnessDontWindowDidChangeScreen:(BOOL) a;
@end

@interface ViewerController : OSIWindowController {
@public
    DCMView *imageView;
    SeriesView *seriesView;
    StudyView *studyView;
    NSView *subCtrlView;
    NSButton *subCtrlOnOff;
    NSPopUpButton *keyImagePopUpButton;
    BOOL displayOnlyKeyImages;
    BOOL windowWillClose;
    NSThread *loadingThread;
    NSMutableArray *fileList[MAX4D], *pixList[MAX4D];
    short curMovieIndex, maxMovieIndex;
    NSWindow *saveWindowsStateWindow;
    NSToolbar *toolbar;
    ToolbarPanelController *toolbarPanel;
    BOOL FullScreenOn;
    NSWindow *FullScreenWindow, *StartingWindow;
    NSView *contentView;
    NSRect previousFrameRect, standardRect;
    int previousFullscreenColumns, previousFullscreenRows, previousFullscreenCurImage, previousFullscreenViewIndex, previousPropagate, previousScaledFit;
    CGFloat previousSliderStripHeight;
    NSTimer *highLightedTimer, *movieTimer, *timer, *t12BitTimer;
    ViewerController *blendingController;
    NSSlider *slider;
    NSMatrix *previewMatrix;
    NSScrollView *previewMatrixScrollView;
    NSSplitView *splitView;
    float factorPET2SUV;
    NSString *studyUID;
    DicomStudy *study;
    HarnessSeriesLoad *seriesLoad;
}
@property(retain) NSString *windowsStateName;
@property(retain) NSNumber *flagListPODComparatives;
@property(readonly) ToolbarPanelController *toolbarPanel;
@property(readonly, nonnull) HarnessSeriesLoad *horosSeriesLoad;
- (id) initWithPix:(NSMutableArray*)f withFiles:(NSMutableArray*)d withVolume:(NSData*) v;
- (DCMView*) imageView;
- (SeriesView*) seriesView;
- (ViewerController*) blendingController;
- (DicomStudy*) currentStudy;
- (DicomSeries*) currentSeries;
- (NSString*) studyInstanceUID;
- (NSInteger) getNumberOfImages;
- (short) maxMovieIndex;
- (NSMutableArray*) pixList:(long) i;
- (float) factorPET2SUV;
- (void) horosLoadViewerPanels;
- (void) checkView:(NSView *)aView :(BOOL) OnOff;
- (void) refreshToolbar;
- (void) redrawToolbar;
- (void) autoHideMatrix;
- (void) updateNavigator;
- (IBAction) SyncSeries:(id) sender NS_SWIFT_NAME(syncSeries(_:));
- (void) finalizeSeriesViewing;
- (void) cancelOpeningScaleToFit;
- (void) showWindowTransition;
- (void) startLoadImageThread;
- (void) setUpdateTilingViewsValue:(BOOL) v;
- (void) selectFirstTilingView;
- (void) setImageRows:(int)rows columns:(int)columns rescale:(BOOL) rescale;
- (void) showCurrentThumbnail:(id) sender;
@end

// The accessors of ViewerController (SwiftIvars) the Swift blocks read.
@interface ViewerController (SwiftIvars)
IVAR_ACCESSORS
+ (BOOL)horos_SYNCSERIES;
@end

@interface AppController : NSObject
+ (AppController*) sharedAppController NS_SWIFT_NAME(shared());
+ (NSRect) usefullRectForScreen:(NSScreen*) screen NS_SWIFT_NAME(usefullRect(for:));
+ (void) resizeWindowWithAnimation:(NSWindow*) window newSize:(NSRect) frame NS_SWIFT_NAME(resizeWindow(withAnimation:newSize:));
+ (BOOL) USETOOLBARPANEL NS_SWIFT_NAME(usetoolbarpanel());
+ (void) setUSETOOLBARPANEL:(BOOL) b;
- (IBAction) tileWindows:(id) sender;
- (void) checkAllWindowsAreVisible:(id) sender makeKey:(BOOL) makeKey;
- (NSArray*) viewerScreens;
- (IBAction) closeAllViewers:(id) sender;
@end

@interface BrowserController : NSObject
+ (BrowserController*) currentBrowser;
- (void) databaseOpenStudy:(DicomStudy*) item NS_SWIFT_NAME(databaseOpenStudy(_:));
- (void) displayWaitWindowIfNecessary;
- (void) closeWaitWindowIfNecessary;
- (ViewerController*) loadSeries:(id) series :(ViewerController*) viewer :(BOOL) firstViewer keyImagesOnly:(BOOL) keyImages;
- (void) selectDatabaseOutline;
@end

@interface WindowLayoutManager : NSObject
+ (WindowLayoutManager*) sharedWindowLayoutManager NS_SWIFT_NAME(shared());
- (void) setCurrentHangingProtocolForModality:(NSString*) modality description:(NSString*) description;
@end

NS_SWIFT_NAME(ViewerWindowColors)
@interface HorosViewerWindowColors : NSObject
+ (NSColor*) colorForViewer:(id) viewer NS_SWIFT_NAME(color(for:));
+ (NSInteger) numberForViewer:(id) viewer NS_SWIFT_NAME(number(for:));
+ (void) releaseViewer:(id) viewer NS_SWIFT_NAME(release(_:));
+ (NSArray*) viewersInColorOrder:(NSArray*) viewers NS_SWIFT_NAME(viewersInColorOrder(_:));
@end

NS_SWIFT_NAME(SeriesListIdentification)
@interface HorosSeriesListIdentification : NSObject
+ (BOOL) showsColorsIn:(NSUserDefaults*) defaults NS_SWIFT_NAME(showsColors(in:));
+ (BOOL) showsNumbersIn:(NSUserDefaults*) defaults NS_SWIFT_NAME(showsNumbers(in:));
+ (nonnull NSString*) windowLabelForNumber:(NSInteger) number NS_SWIFT_NAME(windowLabel(number:));
@end

NS_SWIFT_NAME(ToolbarPolicy)
@interface HorosToolbarPolicy : NSObject
+ (BOOL) shouldKeepDetachedToolbarVisibleWhenFullScreen:(BOOL) fullScreen NS_SWIFT_NAME(shouldKeepDetachedToolbarVisible(whenFullScreen:));
+ (CGFloat) setStripAboveImage:(NSView*) strip collapsed:(BOOL) collapsed restoringHeight:(CGFloat) height NS_SWIFT_NAME(setStrip(aboveImage:collapsed:restoringHeight:));
+ (NSRect) fullscreenContentRectOnScreen:(NSRect) frame NS_SWIFT_NAME(fullscreenContentRect(on:));
@end

NS_SWIFT_NAME(AnnotationLevel)
@interface HorosAnnotationLevel : NSObject
@property(class, readonly) BOOL currentLevelShowsPatientName;
@end

NS_SWIFT_NAME(FullScreenWindowSupport)
@interface HorosFullScreenWindowSupport : NSObject
+ (void) declineNativeFullScreen:(NSWindow*) window;
@end

NS_SWIFT_NAME(ViewerBindingTeardown)
@interface HorosViewerBindingTeardown : NSObject
+ (void) unbindFileOwnerBindingsOn:(id) owner NS_SWIFT_NAME(unbindFileOwnerBindings(on:));
@end

@interface OSIEnvironment : NSObject
+ (OSIEnvironment*) sharedEnvironment NS_SWIFT_NAME(shared());
- (void) removeViewerController:(ViewerController*) viewer NS_SWIFT_NAME(removeViewerController(_:));
@end

@interface Wait : NSWindowController
- (id) initWithString:(NSString*) message;
- (NSProgressIndicator*) progress;
- (void) incrementBy:(double) delta NS_SWIFT_NAME(increment(by:));
@end

@interface WaitRendering : NSWindowController
- (id) init:(NSString*) message;
@end

#ifndef HARNESS_SWIFT
// What the blocks implement (Objective-C category or Swift extension), for
// the driver; Swift sees them in the extensions.
@interface ViewerController (Windows)
+ (void) horos_register2DViewer:(ViewerController*) viewer;
+ (int) numberOf2DViewer;
+ (NSMutableArray*) get2DViewers;
+ (NSMutableArray*) getDisplayed2DViewers;
+ (NSArray*) getDisplayedStudies;
+ (NSArray*) getDisplayedSeries;
+ (NSArray*) displayed2DViewerForScreen:(NSScreen*) screen;
+ (void) clearFrontMost2DViewerCache;
+ (ViewerController*) frontMostDisplayed2DViewerForScreen:(NSScreen*) screen;
+ (ViewerController*) frontMostDisplayed2DViewer;
+ (BOOL) isFrontMost2DViewer:(NSWindow*) window;
+ (NSMapTable*) horosSeriesWindowColors;
+ (NSMapTable*) horosSeriesWindowNumbers;
+ (NSArray*) studyColors;
- (BOOL) is2DViewer;
- (BOOL) windowWillClose;
- (IBAction) resetWindowsState:(id) sender;
- (IBAction) loadWindowsState:(id) sender;
- (IBAction) saveWindowsState:(id) sender;
- (IBAction) saveWindowsStateAsDICOMSR:(id) sender;
- (IBAction) endSaveWindowsStateAsDICOMSR:(id) sender;
+ (void) saveWindowsState;
+ (void) saveWindowsStateWithDICOMSR:(BOOL) DICOMSR name:(NSString*) name;
- (void) setWindowTitle:(id) sender;
- (id) startWaitProgressWindow:(NSString*) message :(long) max;
- (void) waitIncrementBy:(id) waitWindow :(long) val;
- (id) startWaitWindow:(NSString*) message;
- (void) endWaitWindow:(id) waitWindow;
- (BOOL) windowShouldClose:(id) sender;
- (void) windowWillClose:(NSNotification*) notification;
- (void) windowDidMiniaturize:(NSNotification*) notification;
- (void) windowDidDeminiaturize:(NSNotification*) notification;
- (void) windowDidResignMain:(NSNotification*) notification;
- (void) windowDidChangeScreen:(NSNotification*) notification;
- (void) windowDidBecomeMain:(NSNotification*) notification;
+ (void) closeAllWindows;
+ (ViewerController*) newWindow:(NSMutableArray*) f :(NSMutableArray*) d :(NSData*) v frame:(NSRect) frame;
+ (ViewerController*) newWindow:(NSMutableArray*) f :(NSMutableArray*) d :(NSData*) v;
- (ViewerController*) newWindow:(NSMutableArray*) f :(NSMutableArray*) d :(NSData*) v;
- (void) tileWindows;
- (IBAction) SetWindowsTiling:(id) menu;
- (NSRect) windowWillUseStandardFrame:(NSWindow*) sender defaultFrame:(NSRect) frame;
- (void) setStandardRect:(NSRect) rect;
- (void) setWindowFrame:(NSRect) rect showWindow:(BOOL) show animate:(BOOL) animate;
- (void) setWindowFrame:(NSRect) rect showWindow:(BOOL) show;
- (void) setWindowFrame:(NSRect) rect;
- (void) applicationDidResignActive:(NSNotification*) notification;
- (IBAction) fullScreenMenu:(id) sender;
- (BOOL) FullScreenON;
- (void) offFullScreen;
@end
#endif

// What the driver changes between the cases.
extern BOOL harnessShowsColors, harnessShowsNumbers, harnessShowsPatientName, harnessKeepToolbar, harnessUseToolbarPanel;
extern NSInteger harnessViewerScreens;
extern NSMutableArray *harnessLoadedViewers;
ViewerController *MakeViewer(NSString *name, DicomStudy *study, NSArray *seriesOfFrames, int slices);
'''

IVARS = [
    # (kind, type, name, nonisolated)
    ('object', 'DCMView*', 'imageView'), ('object', 'SeriesView*', 'seriesView'), ('outlet', 'StudyView*', 'studyView'),
    ('outlet', 'NSView*', 'subCtrlView'), ('outlet', 'NSButton*', 'subCtrlOnOff'), ('outlet', 'NSPopUpButton*', 'keyImagePopUpButton'),
    ('scalar', 'BOOL', 'displayOnlyKeyImages'), ('scalar', 'BOOL', 'windowWillClose'), ('object', 'NSThread*', 'loadingThread'),
    ('scalar', 'short', 'curMovieIndex'), ('outlet', 'NSWindow*', 'saveWindowsStateWindow'), ('object', 'NSToolbar*', 'toolbar'),
    ('object', 'ToolbarPanelController*', 'toolbarPanel'), ('scalar', 'BOOL', 'FullScreenOn'), ('object', 'NSWindow*', 'FullScreenWindow'),
    ('object', 'NSWindow*', 'StartingWindow'), ('object', 'NSView*', 'contentView'), ('scalar', 'NSRect', 'previousFrameRect'),
    ('scalar', 'NSRect', 'standardRect'), ('scalar', 'int', 'previousFullscreenColumns'), ('scalar', 'int', 'previousFullscreenRows'),
    ('scalar', 'int', 'previousFullscreenCurImage'), ('scalar', 'int', 'previousFullscreenViewIndex'), ('scalar', 'int', 'previousPropagate'),
    ('scalar', 'int', 'previousScaledFit'), ('scalar', 'CGFloat', 'previousSliderStripHeight'), ('object', 'NSTimer*', 'highLightedTimer'),
    ('object', 'NSTimer*', 'movieTimer'), ('object', 'NSTimer*', 'timer'), ('object', 'NSTimer*', 't12BitTimer'),
    ('outlet', 'NSSlider*', 'slider'), ('outlet', 'NSMatrix*', 'previewMatrix'), ('outlet', 'NSScrollView*', 'previewMatrixScrollView'),
    ('outlet', 'NSSplitView*', 'splitView'),
]
NONISOLATED = {'windowWillClose', 'loadingThread', 'curMovieIndex'}


def accessors():
    """The declarations and implementations of ViewerController (SwiftIvars), as the app's."""
    declared, implemented = [], []
    for kind, type_, name in IVARS:
        tail = ' NS_SWIFT_NONISOLATED' if name in NONISOLATED else ''
        cap = name[0].upper() + name[1:]
        if kind == 'outlet':
            declared.append('@property(readonly, nullable) %s horos_%s;' % (type_, name))
            implemented.append('- (%s)horos_%s { return %s; }' % (type_, name, name))
        elif kind == 'object':
            declared.append('@property(retain, nullable) %s horos_%s%s;' % (type_, name, tail))
            declared.append('- (void)horos_assign%s:(nullable %s)value;' % (cap, type_))
            implemented.append('- (%s)horos_%s { return %s; }' % (type_, name, name))
            implemented.append('- (void)setHoros_%s:(%s)value { [value retain]; [%s release]; %s = value; }' % (name, type_, name, name))
            implemented.append('- (void)horos_assign%s:(%s)value { %s = value; }' % (cap, type_, name))
        else:
            declared.append('@property(assign) %s horos_%s%s;' % (type_, name, tail))
            implemented.append('- (%s)horos_%s { return %s; }' % (type_, name, name))
            implemented.append('- (void)setHoros_%s:(%s)value { %s = value; }' % (name, type_, name))
    declared += ['@property(retain, nullable) ViewerController* horos_blending;',
                 '- (nullable NSMutableArray*)horos_fileListAt:(NSInteger)index NS_SWIFT_NONISOLATED;',
                 '- (nullable NSMutableArray*)horos_pixListAt:(NSInteger)index NS_SWIFT_NONISOLATED;']
    implemented += ['- (ViewerController*)horos_blending { return blendingController; }',
                    '- (void)setHoros_blending:(ViewerController*)value { [value retain]; [blendingController release]; blendingController = value; }',
                    '- (NSMutableArray*)horos_fileListAt:(NSInteger)index { return fileList[index]; }',
                    '- (NSMutableArray*)horos_pixListAt:(NSInteger)index { return pixList[index]; }',
                    '+ (BOOL)horos_SYNCSERIES { return HarnessSYNCSERIES; }']
    return '\n'.join(declared), '\n'.join(implemented)


DECLARED, IMPLEMENTED = accessors()
HEADER = HEADER.replace('IVAR_ACCESSORS', DECLARED)

STUBS = r'''#import "Harness.h"

static NSMapTable *names;

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
    if ([object isKindOfClass: [NSDictionary class]]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (id key in [[object allKeys] sortedArrayUsingSelector: @selector(compare:)]) [parts addObject: [NSString stringWithFormat: @"%@=%@", key, Name([object objectForKey: key])]];
        return [NSString stringWithFormat: @"{%@}", [parts componentsJoinedByString: @","]];
    }
    return [NSString stringWithFormat: @"<%@>", NSStringFromClass([object class])];
}

void Record(NSString *line) {
    printf("%s\n", line.UTF8String);
    fflush(stdout);
}

void HarnessLogException(NSException *e) { Record([NSString stringWithFormat: @"exception %@ %@", e.name, e.reason]); }
void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *function) { HarnessLogException(e); }
void ViewerControllerLogStackTrace(NSString *message) { Record([@"stack " stringByAppendingString: message]); }
void N2LogStackTraceMessage(NSString *message) { Record([@"stack " stringByAppendingString: message]); }
void HorosDetachAutounbinder(id owner) { Record([NSString stringWithFormat: @"detach autounbinder %@", Name(owner)]); }

int delayedTileWindows = 0;
BOOL SyncButtonBehaviorIsBetweenStudies = NO;
BOOL HarnessSYNCSERIES = NO;
NSString* const OsirixCloseViewerNotification = @"OsirixCloseViewerNotification";
ThumbnailsListPanel *thumbnailsListPanel[MAXSCREENS];
ThumbnailsListPanel *AppControllerCAPIThumbnailsListPanel(NSInteger index) { return index >= 0 && index < MAXSCREENS ? thumbnailsListPanel[index] : nil; }

BOOL harnessShowsColors = YES, harnessShowsNumbers = NO, harnessShowsPatientName = YES, harnessKeepToolbar = YES, harnessUseToolbarPanel = NO;
NSInteger harnessViewerScreens = 1;
NSMutableArray *harnessLoadedViewers;

static NSString *R(NSRect r) { return [NSString stringWithFormat: @"%a %a %a %a", r.origin.x, r.origin.y, r.size.width, r.size.height]; }

@implementation NSUserDefaults (HarnessDates)
+ (NSDateFormatter*) dateFormatter {
    static NSDateFormatter *formatter;
    if (!formatter) {
        formatter = [NSDateFormatter new];
        formatter.dateFormat = @"yyyy-MM-dd";
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT: 0];
    }
    return formatter;
}
+ (NSString*) formatDateTime:(NSDate*) date { return @"NOW"; }
@end

@implementation NSWindow (HarnessSheets)
- (void) orderOutAndEndSheetWithReturnCode:(NSModalResponse) code { Record([NSString stringWithFormat: @"%@ orderOutAndEndSheet %ld", Name(self), (long)code]); }
@end

@implementation HarnessWindow
- (BOOL) isVisible { return self.harnessVisible; }
- (NSScreen*) screen { return self.harnessScreen; }
- (void) orderFront:(id) sender { Record([NSString stringWithFormat: @"%@ orderFront", Name(self)]); self.harnessVisible = YES; }
- (void) orderBack:(id) sender { Record([NSString stringWithFormat: @"%@ orderBack", Name(self)]); self.harnessVisible = YES; }
- (void) orderOut:(id) sender { Record([NSString stringWithFormat: @"%@ orderOut", Name(self)]); self.harnessVisible = NO; }
- (void) makeKeyAndOrderFront:(id) sender { Record([NSString stringWithFormat: @"%@ makeKeyAndOrderFront", Name(self)]); self.harnessVisible = YES; }
- (void) close {
    Record([NSString stringWithFormat: @"%@ close", Name(self)]);
    self.harnessVisible = NO;
    if ([self.delegate respondsToSelector: @selector(windowWillClose:)])
        [(id)self.delegate windowWillClose: [NSNotification notificationWithName: NSWindowWillCloseNotification object: self]];
    if (self.nextMain) [self.nextMain windowDidBecomeMain: nil];
}
- (void) setFrame:(NSRect) frame display:(BOOL) display {
    Record([NSString stringWithFormat: @"%@ setFrame %@ display %d", Name(self), R(frame), display]);
    [super setFrame: frame display: NO];
}
- (void) setTitle:(NSString*) title { Record([NSString stringWithFormat: @"%@ title %@", Name(self), title]); [super setTitle: title]; }
- (void) setRepresentedFilename:(NSString*) name { Record([NSString stringWithFormat: @"%@ representedFilename %@", Name(self), name]); }
- (BOOL) makeFirstResponder:(NSResponder*) responder { Record([NSString stringWithFormat: @"%@ makeFirstResponder %@", Name(self), Name(responder)]); return YES; }
- (void) setAcceptsMouseMovedEvents:(BOOL) flag { Record([NSString stringWithFormat: @"%@ acceptsMouseMovedEvents %d", Name(self), flag]); }
- (void) setInitialFirstResponder:(NSView*) view { Record([NSString stringWithFormat: @"%@ initialFirstResponder %@", Name(self), Name(view)]); }
- (void) beginSheet:(NSWindow*) sheet completionHandler:(void (^)(NSModalResponse)) handler { Record([NSString stringWithFormat: @"%@ beginSheet %@ handler %d", Name(self), Name(sheet), handler != nil]); }
- (void) setContentView:(NSView*) view { Record([NSString stringWithFormat: @"%@ contentView %@", Name(self), Name(view)]); [super setContentView: view]; }
- (void) setDelegate:(id) delegate { if ([self isKindOfClass: [NSFullScreenWindow class]]) Record([NSString stringWithFormat: @"%@ delegate %@", Name(self), Name(delegate)]); [super setDelegate: delegate]; }
- (void) setWindowController:(NSWindowController*) controller { Record([NSString stringWithFormat: @"%@ windowController %@", Name(self), Name(controller)]); [super setWindowController: controller]; }
- (void) setLevel:(NSWindowLevel) level { Record([NSString stringWithFormat: @"%@ level %ld", Name(self), (long)level]); }
- (void) setReleasedWhenClosed:(BOOL) flag { Record([NSString stringWithFormat: @"%@ releasedWhenClosed %d", Name(self), flag]); [super setReleasedWhenClosed: flag]; }
- (void) setBackgroundColor:(NSColor*) color { Record([NSString stringWithFormat: @"%@ background %@", Name(self), color]); }
@end

@implementation NSFullScreenWindow
- (instancetype) initWithContentRect:(NSRect) rect styleMask:(NSWindowStyleMask) style backing:(NSBackingStoreType) backing defer:(BOOL) flag {
    Record([NSString stringWithFormat: @"full screen window %@ style %lu backing %lu defer %d", R(rect), (unsigned long)style, (unsigned long)backing, flag]);
    self = [super initWithContentRect: rect styleMask: style backing: backing defer: YES];
    Register(self, @"fullScreenWindow");
    return self;
}
- (void) dealloc { Record(@"full screen window dealloc"); [super dealloc]; }
@end

@implementation HarnessApplication
- (NSArray*) windows { return self.harnessWindows ?: @[]; }
- (NSArray*) orderedWindows { return self.harnessOrdered ?: @[]; }
- (NSWindow*) keyWindow { return self.harnessKey; }
- (NSWindow*) mainWindow { return self.harnessMain; }
- (NSEvent*) currentEvent {
    return [NSEvent keyEventWithType: NSEventTypeKeyDown location: NSZeroPoint modifierFlags: self.harnessFlags timestamp: 0 windowNumber: 0
                             context: nil characters: @"x" charactersIgnoringModifiers: @"x" isARepeat: NO keyCode: 7];
}
- (BOOL) sendAction:(SEL) action to:(id) target from:(id) sender {
    Record([NSString stringWithFormat: @"NSApp sendAction %@ to %@ from %@", NSStringFromSelector(action), Name(target), Name(sender)]);
    return YES;
}
@end

@implementation HarnessPopUp
- (NSInteger) selectedTag { return self.harnessTag; }
@end

static NSManagedObjectContext *stubContext;

@implementation KVCStub
+ (instancetype) stub {
    if (!stubContext) {
        NSMutableArray *entities = [NSMutableArray array];
        for (NSString *name in @[@"DicomStudy", @"DicomSeries", @"FileStub"]) {
            NSEntityDescription *entity = [[NSEntityDescription new] autorelease];
            entity.name = name; entity.managedObjectClassName = name;
            [entities addObject: entity];
        }
        NSManagedObjectModel *model = [[NSManagedObjectModel new] autorelease];
        model.entities = entities;
        stubContext = [[NSManagedObjectContext alloc] initWithConcurrencyType: NSMainQueueConcurrencyType];
        stubContext.persistentStoreCoordinator = [[[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel: model] autorelease];
    }
    return [[self alloc] initWithEntity: [NSEntityDescription entityForName: NSStringFromClass(self) inManagedObjectContext: stubContext]
         insertIntoManagedObjectContext: stubContext];
}
- (id) valueForUndefinedKey:(NSString*) key { return [values objectForKey: key]; }
- (void) setValue:(id) value forUndefinedKey:(NSString*) key {
    if (!values) values = [NSMutableDictionary new];
    if ([key isEqualToString: @"windowsState"])
        Record([NSString stringWithFormat: @"%@ windowsState %@", Name(self), value ? [NSString stringWithFormat: @"%lu bytes", (unsigned long)[value length]] : @"nil"]);
    if (value) [values setObject: value forKey: key]; else [values removeObjectForKey: key];
}
@end

@implementation DicomStudy
@synthesize series;
- (NSArray*) imageSeriesContainingPixels:(BOOL) pixels { Record([NSString stringWithFormat: @"%@ imageSeriesContainingPixels %d", Name(self), pixels]); return self.series; }
- (void) archiveWindowsStateAsDICOMSR { Record([NSString stringWithFormat: @"%@ archiveWindowsStateAsDICOMSR", Name(self)]); }
@end

@implementation DicomSeries
@end

@implementation FileStub
@end

@implementation DCMPix
- (float) storedWindowLevelForCalibratedLevel:(float) level { return level * 2.0f + 0.5f; }
- (DicomSeries*) seriesObj { return self.series; }
@end

static short harnessSyncro = syncroLOC;

@implementation DCMView {
    NSInteger current;
}
+ (short) syncro { return harnessSyncro; }
+ (void) setHarnessSyncro:(short) value { harnessSyncro = value; }
- (NSInteger) curImage { return current; }
- (void) setIndex:(NSInteger) index { Record([NSString stringWithFormat: @"%@ setIndex %ld", Name(self), (long)index]); current = index; }
- (void) sendSyncMessage:(NSInteger) inc { Record([NSString stringWithFormat: @"%@ sendSyncMessage %ld", Name(self), (long)inc]); }
- (void) stopROIEditingForce:(BOOL) force { Record([NSString stringWithFormat: @"%@ stopROIEditingForce %d", Name(self), force]); }
- (void) setWLWW:(float) wl :(float) ww { Record([NSString stringWithFormat: @"%@ setWLWW %a %a", Name(self), wl, ww]); }
- (void) checkCursor { Record([NSString stringWithFormat: @"%@ checkCursor", Name(self)]); }
- (BOOL) isScaledFit { return self.scaledFit; }
- (void) scaleToFit { Record([NSString stringWithFormat: @"%@ scaleToFit", Name(self)]); }
- (DicomSeries*) seriesObj { return self.series; }
- (void) setDrawing:(BOOL) drawing { Record([NSString stringWithFormat: @"%@ drawing %d", Name(self), drawing]); _drawing = drawing; }
- (void) setNeedsDisplay:(BOOL) flag { Record([NSString stringWithFormat: @"%@ needsDisplay %d", Name(self), flag]); }
- (void) display { Record([NSString stringWithFormat: @"%@ display", Name(self)]); }
- (void) performSelector:(SEL) selector withObject:(id) object afterDelay:(NSTimeInterval) delay {
    Record([NSString stringWithFormat: @"%@ perform %@ after %a", Name(self), NSStringFromSelector(selector), delay]);
}
@end

@implementation SeriesView
- (NSMutableArray*) imageViews { return [[self.harnessImageViews mutableCopy] autorelease]; }
- (DCMView*) firstView { return self.harnessImageViews.firstObject; }
@end

@implementation StudyView
- (NSMutableArray*) seriesViews { return [[self.harnessSeriesViews mutableCopy] autorelease]; }
@end

@implementation ThumbnailsListPanel {
    NSView *lent;
}
- (NSView*) thumbnailsView { return lent; }
- (void) harnessLend:(NSView*) view { lent = view; }
- (void) setThumbnailsView:(NSView*) view viewer:(ViewerController*) viewer { Record([NSString stringWithFormat: @"%@ setThumbnailsView %@ viewer %@", Name(self), Name(view), Name(viewer)]); lent = view; }
- (void) thumbnailsListWillClose:(NSView*) view { Record([NSString stringWithFormat: @"%@ thumbnailsListWillClose %@", Name(self), Name(view)]); }
@end

@implementation ToolbarPanelController
+ (void) checkForValidToolbar { Record(@"checkForValidToolbar"); }
- (void) close { Record([NSString stringWithFormat: @"%@ close", Name(self)]); }
@end

@implementation HarnessSeriesLoad
- (void) requestCancel { Record([NSString stringWithFormat: @"%@ load requestCancel", self.owner]); }
- (void) close { Record([NSString stringWithFormat: @"%@ load close", self.owner]); }
@end

static BOOL dontWindowDidChangeScreenValue = NO;

@implementation OSIWindowController
+ (void) setDontEnterMagneticFunctions:(BOOL) a { Record([NSString stringWithFormat: @"magnetic functions off %d", a]); }
+ (BOOL) dontWindowDidChangeScreen { return dontWindowDidChangeScreenValue; }
+ (void) setHarnessDontWindowDidChangeScreen:(BOOL) a { dontWindowDidChangeScreenValue = a; }
@end

@implementation ViewerController
- (id) initWithPix:(NSMutableArray*)f withFiles:(NSMutableArray*)d withVolume:(NSData*) v {
    Record([NSString stringWithFormat: @"initWithPix %@ withFiles %@ withVolume %@", Name(f), Name(d), Name(v)]);
    HarnessWindow *w = [[[HarnessWindow alloc] initWithContentRect: NSMakeRect(0, 0, 300, 200) styleMask: NSWindowStyleMaskTitled backing: NSBackingStoreBuffered defer: YES] autorelease];
    w.releasedWhenClosed = NO;
    Register(w, @"newWindow.window");
    self = [super initWithWindow: w];
    Register(self, @"newViewer");
    return self;
}
- (DCMView*) imageView { return imageView; }
- (SeriesView*) seriesView { return seriesView; }
- (ViewerController*) blendingController { return blendingController; }
- (DicomStudy*) currentStudy { return study; }
- (DicomSeries*) currentSeries { return imageView.series; }
- (NSString*) studyInstanceUID { return studyUID; }
- (NSInteger) getNumberOfImages { return [pixList[curMovieIndex] count]; }
- (short) maxMovieIndex { return maxMovieIndex; }
- (NSMutableArray*) pixList:(long) i { return pixList[i]; }
- (float) factorPET2SUV { return factorPET2SUV; }
- (HarnessSeriesLoad*) horosSeriesLoad { return seriesLoad; }
- (void) horosLoadViewerPanels { Record([NSString stringWithFormat: @"%@ horosLoadViewerPanels", Name(self)]); }
- (void) checkView:(NSView *)aView :(BOOL) OnOff { Record([NSString stringWithFormat: @"%@ checkView %@ %d", Name(self), Name(aView), OnOff]); }
- (void) refreshToolbar { Record([NSString stringWithFormat: @"%@ refreshToolbar", Name(self)]); }
- (void) redrawToolbar { Record([NSString stringWithFormat: @"%@ redrawToolbar", Name(self)]); }
- (void) autoHideMatrix { Record([NSString stringWithFormat: @"%@ autoHideMatrix", Name(self)]); }
- (void) updateNavigator { Record([NSString stringWithFormat: @"%@ updateNavigator", Name(self)]); }
- (IBAction) SyncSeries:(id) sender { Record([NSString stringWithFormat: @"%@ SyncSeries %@", Name(self), Name(sender)]); }
- (void) finalizeSeriesViewing { Record([NSString stringWithFormat: @"%@ finalizeSeriesViewing", Name(self)]); }
- (void) cancelOpeningScaleToFit { Record([NSString stringWithFormat: @"%@ cancelOpeningScaleToFit", Name(self)]); }
- (void) showWindowTransition { Record([NSString stringWithFormat: @"%@ showWindowTransition", Name(self)]); }
- (void) startLoadImageThread { Record([NSString stringWithFormat: @"%@ startLoadImageThread", Name(self)]); }
- (void) setUpdateTilingViewsValue:(BOOL) v { Record([NSString stringWithFormat: @"%@ updateTilingViews %d", Name(self), v]); }
- (void) selectFirstTilingView { Record([NSString stringWithFormat: @"%@ selectFirstTilingView", Name(self)]); }
- (void) setImageRows:(int)rows columns:(int)columns rescale:(BOOL) rescale {
    Record([NSString stringWithFormat: @"%@ setImageRows %d columns %d rescale %d", Name(self), rows, columns, rescale]);
    imageView = seriesView.firstView;   // the tiling is remade: the first view is the image view
    imageView.rows = rows; imageView.columns = columns;
}
- (void) showCurrentThumbnail:(id) sender { Record([NSString stringWithFormat: @"%@ showCurrentThumbnail %@", Name(self), Name(sender)]); }
- (void) unbind:(NSBindingName) binding { Record([NSString stringWithFormat: @"%@ unbind %@", Name(self), binding]); }
- (void) setFlagListPODComparatives:(NSNumber*) value { Record([NSString stringWithFormat: @"%@ flagListPODComparatives %@", Name(self), Name(value)]); [_flagListPODComparatives release]; _flagListPODComparatives = [value retain]; }
@end

@implementation ViewerController (SwiftIvars)
IVAR_IMPLEMENTATIONS
@end

static AppController *sharedApp;
static BOOL useToolbarPanel;

@implementation AppController
+ (AppController*) sharedAppController { if (!sharedApp) { sharedApp = [AppController new]; Register(sharedApp, @"AppController"); } return sharedApp; }
+ (NSRect) usefullRectForScreen:(NSScreen*) screen { return screen ? NSMakeRect(0, 22, 1000, 800) : NSMakeRect(0, 0, 640, 480); }
+ (void) resizeWindowWithAnimation:(NSWindow*) window newSize:(NSRect) frame { Record([NSString stringWithFormat: @"resizeWindowWithAnimation %@ %@", Name(window), R(frame)]); }
+ (BOOL) USETOOLBARPANEL { return useToolbarPanel; }
+ (void) setUSETOOLBARPANEL:(BOOL) b { Record([NSString stringWithFormat: @"USETOOLBARPANEL %d", b]); useToolbarPanel = b; }
- (IBAction) tileWindows:(id) sender { Record([NSString stringWithFormat: @"tileWindows %@", Name(sender)]); }
- (void) checkAllWindowsAreVisible:(id) sender makeKey:(BOOL) makeKey { Record([NSString stringWithFormat: @"checkAllWindowsAreVisible %@ makeKey %d", Name(sender), makeKey]); }
- (NSArray*) viewerScreens { NSMutableArray *a = [NSMutableArray array]; for (NSInteger i = 0; i < harnessViewerScreens; i++) [a addObject: @(i)]; return a; }
- (IBAction) closeAllViewers:(id) sender { Record(@"closeAllViewers"); }
- (void) performSelector:(SEL) selector withObject:(id) object afterDelay:(NSTimeInterval) delay {
    Record([NSString stringWithFormat: @"AppController perform %@ with %@ after %a", NSStringFromSelector(selector), Name(object), delay]);
}
@end

static BrowserController *browser;

@implementation BrowserController
+ (BrowserController*) currentBrowser { if (!browser) { browser = [BrowserController new]; Register(browser, @"browser"); } return browser; }
- (void) databaseOpenStudy:(DicomStudy*) item {
    Record([NSString stringWithFormat: @"databaseOpenStudy %@ automatic %d", Name(item), [[NSUserDefaults standardUserDefaults] boolForKey: @"automaticWorkspaceLoad"]]);
}
- (void) displayWaitWindowIfNecessary { Record(@"displayWaitWindowIfNecessary"); }
- (void) closeWaitWindowIfNecessary { Record(@"closeWaitWindowIfNecessary"); }
- (ViewerController*) loadSeries:(id) series :(ViewerController*) viewer :(BOOL) firstViewer keyImagesOnly:(BOOL) keyImages {
    Record([NSString stringWithFormat: @"loadSeries %@ viewer %@ first %d key %d", Name(series), Name(viewer), firstViewer, keyImages]);
    ViewerController *v = MakeViewer([NSString stringWithFormat: @"loaded%lu", (unsigned long)harnessLoadedViewers.count], nil, @[series], 3);
    [harnessLoadedViewers addObject: v];
    [ViewerController horos_register2DViewer: v];
    ((HarnessWindow*)v.window).harnessVisible = YES;
    return v;
}
- (void) selectDatabaseOutline { Record(@"selectDatabaseOutline"); }
@end

@implementation WindowLayoutManager
+ (WindowLayoutManager*) sharedWindowLayoutManager { static WindowLayoutManager *m; if (!m) { m = [WindowLayoutManager new]; Register(m, @"layoutManager"); } return m; }
- (void) setCurrentHangingProtocolForModality:(NSString*) modality description:(NSString*) description {
    Record([NSString stringWithFormat: @"hanging protocol %@ %@", Name(modality), Name(description)]);
}
@end

@implementation HorosViewerWindowColors
+ (NSColor*) colorForViewer:(id) viewer { Record([NSString stringWithFormat: @"colorForViewer %@", Name(viewer)]); return [NSColor colorWithDeviceWhite: [Name(viewer) length] / 10.0 alpha: 1]; }
+ (NSInteger) numberForViewer:(id) viewer { return [Name(viewer) length]; }
+ (void) releaseViewer:(id) viewer { Record([NSString stringWithFormat: @"releaseViewer %@", Name(viewer)]); }
+ (NSArray*) viewersInColorOrder:(NSArray*) viewers { return [[viewers reverseObjectEnumerator] allObjects]; }
@end

@implementation HorosSeriesListIdentification
+ (BOOL) showsColorsIn:(NSUserDefaults*) defaults { return harnessShowsColors; }
+ (BOOL) showsNumbersIn:(NSUserDefaults*) defaults { return harnessShowsNumbers; }
+ (NSString*) windowLabelForNumber:(NSInteger) number { return [NSString stringWithFormat: @"#%ld", (long)number]; }
@end

@implementation HorosToolbarPolicy
+ (BOOL) shouldKeepDetachedToolbarVisibleWhenFullScreen:(BOOL) fullScreen { return harnessKeepToolbar && !fullScreen; }
+ (CGFloat) setStripAboveImage:(NSView*) strip collapsed:(BOOL) collapsed restoringHeight:(CGFloat) height {
    Record([NSString stringWithFormat: @"strip %@ collapsed %d height %a", Name(strip), collapsed, height]);
    return collapsed ? 31.5 : height;
}
+ (NSRect) fullscreenContentRectOnScreen:(NSRect) frame { return NSInsetRect(frame, -1, -1); }
@end

@implementation HorosAnnotationLevel
+ (BOOL) currentLevelShowsPatientName { return harnessShowsPatientName; }
@end

@implementation HorosFullScreenWindowSupport
+ (void) declineNativeFullScreen:(NSWindow*) window { Record([NSString stringWithFormat: @"declineNativeFullScreen %@", Name(window)]); }
@end

@implementation HorosViewerBindingTeardown
+ (void) unbindFileOwnerBindingsOn:(id) owner { Record([NSString stringWithFormat: @"unbindFileOwnerBindings %@", Name(owner)]); }
@end

@implementation OSIEnvironment
+ (OSIEnvironment*) sharedEnvironment { static OSIEnvironment *e; if (!e) e = [OSIEnvironment new]; return e; }
- (void) removeViewerController:(ViewerController*) viewer { Record([NSString stringWithFormat: @"environment remove %@", Name(viewer)]); }
@end

@implementation Wait {
    NSProgressIndicator *indicator;
}
- (id) initWithString:(NSString*) message {
    self = [super initWithWindow: nil];
    Record([NSString stringWithFormat: @"Wait %@", message]);
    indicator = [NSProgressIndicator new];
    Register(self, @"wait");
    return self;
}
- (NSProgressIndicator*) progress { return indicator; }
- (void) incrementBy:(double) delta { Record([NSString stringWithFormat: @"wait incrementBy %a max %a", delta, indicator.maxValue]); }
- (void) showWindow:(id) sender { Record([NSString stringWithFormat: @"%@ showWindow %@", Name(self), Name(sender)]); }
- (void) close { Record([NSString stringWithFormat: @"%@ close", Name(self)]); }
@end

@implementation WaitRendering
- (id) init:(NSString*) message {
    self = [super initWithWindow: nil];
    Record([NSString stringWithFormat: @"WaitRendering %@", message]);
    Register(self, @"waitRendering");
    return self;
}
- (void) showWindow:(id) sender { Record([NSString stringWithFormat: @"%@ showWindow %@", Name(self), Name(sender)]); }
- (void) close { Record([NSString stringWithFormat: @"%@ close", Name(self)]); }
@end

static NSScreen *firstScreen(void) { return [NSScreen screens].firstObject; }

ViewerController *MakeViewer(NSString *name, DicomStudy *study, NSArray *seriesOfFrames, int slices) {
    HarnessWindow *w = [[HarnessWindow alloc] initWithContentRect: NSMakeRect(100, 100, 400, 300) styleMask: NSWindowStyleMaskTitled backing: NSBackingStoreBuffered defer: YES];
    [w setReleasedWhenClosed: NO];
    w.harnessScreen = firstScreen();
    Register(w, [name stringByAppendingString: @".window"]);
    Register(w.contentView, [name stringByAppendingString: @".content"]);
    ViewerController *v = [[ViewerController alloc] initWithWindow: w];
    [w release];
    w.delegate = (id)v;
    Register(v, name);
    v->seriesLoad = [HarnessSeriesLoad new]; v->seriesLoad.owner = name;
    DCMView *first = [[DCMView alloc] initWithFrame: NSMakeRect(0, 0, 100, 100)], *second = [[DCMView alloc] initWithFrame: NSMakeRect(0, 0, 100, 100)];
    Register(first, [name stringByAppendingString: @".view0"]); Register(second, [name stringByAppendingString: @".view1"]);
    first.rows = second.rows = 1; first.columns = second.columns = 2;
    SeriesView *seriesView = [[SeriesView alloc] initWithFrame: NSZeroRect]; seriesView.harnessImageViews = @[first, second];
    Register(seriesView, [name stringByAppendingString: @".seriesView"]);
    StudyView *studyView = [[StudyView alloc] initWithFrame: NSZeroRect]; studyView.harnessSeriesViews = @[seriesView];
    Register(studyView, [name stringByAppendingString: @".studyView"]);
    v->imageView = first; v->seriesView = seriesView; v->studyView = studyView;
    v->study = [study retain];
    v->studyUID = study ? [[study valueForKey: @"studyInstanceUID"] retain] : nil;
    v->maxMovieIndex = seriesOfFrames.count;
    for (NSUInteger f = 0; f < seriesOfFrames.count; f++) {
        DicomSeries *series = seriesOfFrames[f];
        v->pixList[f] = [NSMutableArray new]; v->fileList[f] = [NSMutableArray new];
        Register(v->pixList[f], [NSString stringWithFormat: @"%@.pix%lu", name, (unsigned long)f]);
        Register(v->fileList[f], [NSString stringWithFormat: @"%@.files%lu", name, (unsigned long)f]);
        for (int s = 0; s < slices; s++) {
            DCMPix *pix = [[DCMPix new] autorelease]; pix.series = series;
            [v->pixList[f] addObject: pix];
            FileStub *file = [[FileStub stub] autorelease];
            [file setValue: [NSString stringWithFormat: @"/data/%@-%d.dcm", name, s] forKey: @"completePath"];
            [file setValue: series forKey: @"series"];
            [v->fileList[f] addObject: file];
        }
    }
    first.series = second.series = seriesOfFrames.firstObject;
    first.curDCM = second.curDCM = [v->pixList[0] firstObject];
    first.curWL = 40; first.curWW = 400;
    v->subCtrlView = [[NSView alloc] initWithFrame: NSZeroRect]; Register(v->subCtrlView, [name stringByAppendingString: @".subCtrlView"]);
    v->subCtrlOnOff = [[NSButton alloc] initWithFrame: NSZeroRect];
    v->keyImagePopUpButton = [[NSPopUpButton alloc] initWithFrame: NSZeroRect pullsDown: NO];
    [v->keyImagePopUpButton addItemsWithTitles: @[@"All", @"Key"]];
    v->previewMatrixScrollView = [[NSScrollView alloc] initWithFrame: NSZeroRect]; Register(v->previewMatrixScrollView, [name stringByAppendingString: @".thumbnails"]);
    v->previewMatrix = [[NSMatrix alloc] initWithFrame: NSZeroRect]; Register(v->previewMatrix, [name stringByAppendingString: @".matrix"]);
    v->splitView = [[NSSplitView alloc] initWithFrame: NSZeroRect];
    NSView *left = [[[NSView alloc] initWithFrame: NSZeroRect] autorelease];
    [v->splitView addSubview: left];
    v->slider = [[NSSlider alloc] initWithFrame: NSZeroRect];
    NSView *strip = [[[NSView alloc] initWithFrame: NSZeroRect] autorelease];
    [strip addSubview: v->slider]; Register(strip, [name stringByAppendingString: @".strip"]);
    v->toolbar = [[NSToolbar alloc] initWithIdentifier: name];
    v->factorPET2SUV = 0.5f;
    return v;
}
'''.replace('IVAR_IMPLEMENTATIONS', IMPLEMENTED)

DRIVER = r'''#import "Harness.h"

static HarnessApplication *app;
static NSMutableArray *keep;

static NSString *F(double x) { return [NSString stringWithFormat: @"%a", x]; }
static NSString *R(NSRect r) { return [NSString stringWithFormat: @"%a %a %a %a", r.origin.x, r.origin.y, r.size.width, r.size.height]; }

static DicomStudy *Study(NSString *name, NSString *patient, NSString *uid) {
    DicomStudy *s = [DicomStudy stub];
    Register(s, name);
    [s setValue: patient forKey: @"patientUID"];
    [s setValue: uid forKey: @"studyInstanceUID"];
    [keep addObject: s];
    return s;
}

static DicomSeries *Series(NSString *name, DicomStudy *study, NSString *uid, NSString *dicomUID) {
    DicomSeries *s = [DicomSeries stub];
    Register(s, name);
    [s setValue: study forKey: @"study"];
    [s setValue: uid forKey: @"seriesInstanceUID"];
    if (dicomUID) [s setValue: dicomUID forKey: @"seriesDICOMUID"];
    [s setValue: name forKey: @"name"];
    [keep addObject: s];
    return s;
}

static ViewerController *Viewer(NSString *name, DicomStudy *study, NSArray *series, int slices) {
    ViewerController *v = MakeViewer(name, study, series, slices);
    [keep addObject: v];
    [v release];
    ((HarnessWindow*)v.window).harnessVisible = YES;
    return v;
}

static void Defaults(NSDictionary *values) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    for (NSString *key in @[@"COPYSETTINGS", @"LastWindowsTilingRowsColumns", @"alwaysArchiveWindowsStateAsDICOMSR", @"automaticWorkspaceLoad",
                            @"AUTOTILING", @"UseFloatingThumbnailsList", @"automaticWorkspaceSave", @"DontResetListPODComparativesIn2DViewer",
                            @"listPODComparativesIn2DViewer", @"NoImageTilingInFullscreen", @"AlwaysScaleToFit"])
        [d removeObjectForKey: key];
    [d setBool: YES forKey: @"COPYSETTINGS"];
    for (NSString *key in values) [d setObject: values[key] forKey: key];
}

static void Viewers(NSString *label) {
    Record([NSString stringWithFormat: @"%@: number %d registered %@ displayed %@", label, [ViewerController numberOf2DViewer],
            Name([ViewerController get2DViewers]), Name([ViewerController getDisplayed2DViewers])]);
}

static void Retain(NSString *label, id object) {
    Record([NSString stringWithFormat: @"%@ retainCount %lu", label, (unsigned long)[object retainCount]]);
}

static void Ivars(ViewerController *v) {
    Record([NSString stringWithFormat: @"%@ full %d window %@ starting %@ content %@ previous %@ standard %@ propagate %d fit %d columns %d rows %d image %d viewIndex %d strip %@ imageView %@",
            Name(v), v->FullScreenOn, Name(v->FullScreenWindow), Name(v->StartingWindow), Name(v->contentView), R(v->previousFrameRect), R(v->standardRect),
            v->previousPropagate, v->previousScaledFit, v->previousFullscreenColumns, v->previousFullscreenRows, v->previousFullscreenCurImage,
            v->previousFullscreenViewIndex, F(v->previousSliderStripHeight), Name(v->imageView)]);
}

static void SavedState(DicomStudy *study) {
    NSData *data = [study valueForKey: @"windowsState"];
    if (!data) { Record([NSString stringWithFormat: @"%@ state nil", Name(study)]); return; }
    NSString *xml = [[[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding] autorelease];
    NSRegularExpression *date = [NSRegularExpression regularExpressionWithPattern: @"<date>[^<]*</date>" options: 0 error: nil];
    xml = [date stringByReplacingMatchesInString: xml options: 0 range: NSMakeRange(0, xml.length) withTemplate: @"<date>(now)</date>"];
    for (NSString *line in [xml componentsSeparatedByString: @"\n"]) Record([NSString stringWithFormat: @"%@ | %@", Name(study), line]);
}

static void Registry(void) {
    Viewers(@"empty");
    DicomStudy *s1 = Study(@"s1", @"P1", @"1.1"), *s2 = Study(@"s2", @"P2", @"1.2");
    DicomSeries *a = Series(@"a", s1, @"1.1.1", @"1.1.1"), *b = Series(@"b", s1, @"1.1.2", @"1.1.2"), *c = Series(@"c", s2, @"1.2.1", @"1.2.1");
    ViewerController *v1 = Viewer(@"v1", s1, @[a], 3), *v2 = Viewer(@"v2", s1, @[a], 3), *v3 = Viewer(@"v3", s1, @[b], 3);
    ViewerController *v4 = Viewer(@"v4", s2, @[c], 3), *v5 = Viewer(@"v5", s2, @[c], 3), *v6 = Viewer(@"v6", s1, @[b], 3);
    // v3 is shown full screen: its window is the full screen one.
    NSFullScreenWindow *fs = [[NSFullScreenWindow alloc] initWithContentRect: NSMakeRect(0, 0, 10, 10) styleMask: 0 backing: NSBackingStoreBuffered defer: YES];
    Register(fs, @"v3.fullScreen"); fs.harnessVisible = YES; fs.harnessScreen = [NSScreen screens].firstObject;
    [v3 setWindow: fs];
    v4->windowWillClose = YES;
    ((HarnessWindow*)v5.window).harnessVisible = NO;
    ((HarnessWindow*)v6.window).harnessScreen = nil;
    v6->imageView.series = nil;
    for (ViewerController *v in @[v1, v2, v3, v4, v5, v6]) [ViewerController horos_register2DViewer: v];
    Viewers(@"six");
    Record([NSString stringWithFormat: @"studies %@ series %@", Name([ViewerController getDisplayedStudies]), Name([ViewerController getDisplayedSeries])]);
    NSWindow *other = [[[HarnessWindow alloc] initWithContentRect: NSZeroRect styleMask: 0 backing: NSBackingStoreBuffered defer: YES] autorelease];
    Register(other, @"other"); ((HarnessWindow*)other).harnessVisible = YES;
    app.harnessOrdered = @[other, v4.window, v2.window, v6.window, v5.window, v1.window, fs];
    NSScreen *screen = [NSScreen screens].firstObject;
    for (NSArray *keyMain in @[@[[NSNull null], [NSNull null]], @[v1.window, [NSNull null]], @[v4.window, v6.window], @[other, v5.window]]) {
        app.harnessKey = keyMain[0] == [NSNull null] ? nil : keyMain[0];
        app.harnessMain = keyMain[1] == [NSNull null] ? nil : keyMain[1];
        Record([NSString stringWithFormat: @"key %@ main %@: front %@ front on screen %@ displayed %@ on screen %@ isFront v1 %d v2 %d nil %d",
                Name(app.harnessKey), Name(app.harnessMain), Name([ViewerController frontMostDisplayed2DViewer]),
                Name([ViewerController frontMostDisplayed2DViewerForScreen: screen]), Name([ViewerController displayed2DViewerForScreen: nil]),
                Name([ViewerController displayed2DViewerForScreen: screen]), [ViewerController isFrontMost2DViewer: v1.window],
                [ViewerController isFrontMost2DViewer: v2.window], [ViewerController isFrontMost2DViewer: nil]]);
    }
    [ViewerController clearFrontMost2DViewerCache];
    for (int shows = 0; shows < 4; shows++) {
        harnessShowsColors = shows & 1; harnessShowsNumbers = (shows >> 1) & 1;
        NSMapTable *colors = [ViewerController horosSeriesWindowColors], *numbers = [ViewerController horosSeriesWindowNumbers];
        NSMutableArray *parts = [NSMutableArray array];
        for (id key in colors) [parts addObject: [NSString stringWithFormat: @"%@=%@", Name(key), [colors objectForKey: key]]];
        for (id key in numbers) [parts addObject: [NSString stringWithFormat: @"%@#%@", Name(key), [numbers objectForKey: key]]];
        [parts sortUsingSelector: @selector(compare:)];
        Record([NSString stringWithFormat: @"colors %d numbers %d: %@ (%@ %@)", harnessShowsColors, harnessShowsNumbers, [parts componentsJoinedByString: @" "],
                NSStringFromClass([colors class]), NSStringFromClass([numbers class])]);
    }
    // One displayed viewer: no colours.
    for (ViewerController *v in @[v2, v3, v6]) v->windowWillClose = YES;
    harnessShowsColors = YES;
    Record([NSString stringWithFormat: @"one viewer: colors %lu", (unsigned long)[[ViewerController horosSeriesWindowColors] count]]);
    NSArray *colors = [ViewerController studyColors];
    Record([NSString stringWithFormat: @"study colours %lu same %d", (unsigned long)colors.count, colors == [ViewerController studyColors]]);
    for (NSColor *color in colors) {
        CGFloat r, g, b, alpha; [color getRed: &r green: &g blue: &b alpha: &alpha];
        Record([NSString stringWithFormat: @"  %@ %@ %@ %@ %@", color.colorSpaceName, F(r), F(g), F(b), F(alpha)]);
    }
    Record([NSString stringWithFormat: @"is2DViewer %d", [v1 is2DViewer]]);
    Record([NSString stringWithFormat: @"get2DViewers class %@ copy %d", NSStringFromClass([[ViewerController get2DViewers] class]), [ViewerController get2DViewers] != [ViewerController get2DViewers]]);
    Record([NSString stringWithFormat: @"windowWillClose v1 %d v4 %d", [v1 windowWillClose], [v4 windowWillClose]]);
    // Any thread may ask.
    __block NSString *fromThread = nil;
    NSThread *thread = [[[NSThread alloc] initWithBlock: ^{ fromThread = [Name([ViewerController getDisplayed2DViewers]) retain]; }] autorelease];
    [thread start];
    while (!thread.isFinished) usleep(1000);
    Record([NSString stringWithFormat: @"from a thread %@ number %d", fromThread, [ViewerController numberOf2DViewer]]);
}

static void State(void) {
    DicomStudy *s1 = Study(@"s1", @"P1", @"1.1"), *s2 = Study(@"s2", @"p\u00ef1", @"1.2"), *s3 = Study(@"s3", @"P2", @"1.3");
    DicomSeries *a = Series(@"a", s1, @"1.1.1", @"1.1.1"), *b = Series(@"b", s2, @"1.2.1", @"1.2.1"), *b2 = Series(@"b2", s2, @"1.2.2", @"1.2.2");
    DicomSeries *raster = Series(@"raster", s3, @"raster-uid", nil);
    ViewerController *v1 = Viewer(@"v1", s1, @[a], 4), *v2 = Viewer(@"v2", s2, @[b, b, b2], 5), *v3 = Viewer(@"v3", s3, @[raster], 2);
    for (ViewerController *v in @[v1, v2, v3]) [ViewerController horos_register2DViewer: v];
    ((HarnessWindow*)v2.window).harnessScreen = nil;
    [v1.window setFrame: NSMakeRect(10.5, 20, 300.25, 200) display: NO];
    v2->imageView.flippedData = YES; [v2->imageView setIndex: 1]; [v2->seriesView.firstView setIndex: 1];
    v2->imageView.curDCM.SUVConverted = YES; v2->imageView.curWL = 3; v2->imageView.curWW = 7;
    v1->imageView.scaleValue = 1.25f; v1->imageView.origin = NSMakePoint(3.5, -2); v1->imageView.rotation = 90; v1->imageView.xFlipped = YES;
    v1->imageView.syncRelativeDiff = 2.5f;
    Defaults(@{@"LastWindowsTilingRowsColumns": @"12"});
    [DCMView setHarnessSyncro: syncroLOC]; SyncButtonBehaviorIsBetweenStudies = NO; HarnessSYNCSERIES = YES;
    [ViewerController saveWindowsStateWithDICOMSR: YES name: @"layout"];
    for (DicomStudy *s in @[s1, s2, s3]) SavedState(s);
    // P1 and its decomposed form are the same patient; P2 keeps only its own, without the layout keys.
    [DCMView setHarnessSyncro: syncroOFF]; SyncButtonBehaviorIsBetweenStudies = YES; HarnessSYNCSERIES = NO;
    Defaults(@{});
    [ViewerController saveWindowsStateWithDICOMSR: NO name: nil];
    for (DicomStudy *s in @[s1, s3]) SavedState(s);
    [DCMView setHarnessSyncro: syncroREL];
    v3->imageView.curDCM.generated = YES;
    [ViewerController saveWindowsStateWithDICOMSR: NO name: @""];
    SavedState(s3); SavedState(s2);
    // A viewer that cannot be described: nothing is saved.
    [s1 setValue: nil forKey: @"windowsState"];
    NSString *uid = v1->studyUID; v1->studyUID = nil;
    [ViewerController saveWindowsStateWithDICOMSR: YES name: @"partial"];
    SavedState(s1);
    v1->studyUID = uid;
    // A missing COPYSETTINGS raised.
    [[NSUserDefaults standardUserDefaults] removeObjectForKey: @"COPYSETTINGS"];
    [ViewerController saveWindowsStateWithDICOMSR: YES name: @"no settings"];
    SavedState(s1);
    Defaults(@{@"alwaysArchiveWindowsStateAsDICOMSR": @YES});
    [ViewerController saveWindowsState];
    [v1 saveWindowsState: nil];
    Defaults(@{});
    [v2 saveWindowsState: nil];
    [v1 resetWindowsState: nil];
    for (DicomStudy *s in @[s1, s2, s3]) SavedState(s);
    [v2 loadWindowsState: nil];
    Defaults(@{@"automaticWorkspaceLoad": @YES});
    [v2 loadWindowsState: nil];
    Record([NSString stringWithFormat: @"automatic after %d", [[NSUserDefaults standardUserDefaults] boolForKey: @"automaticWorkspaceLoad"]]);
    Defaults(@{});
    [v1 loadWindowsState: nil];
    Record([NSString stringWithFormat: @"automatic after %d", [[NSUserDefaults standardUserDefaults] boolForKey: @"automaticWorkspaceLoad"]]);
    [v1 saveWindowsStateAsDICOMSR: nil];
    Record([NSString stringWithFormat: @"name %@", v1.windowsStateName]);
    v1->saveWindowsStateWindow = [[HarnessWindow alloc] initWithContentRect: NSZeroRect styleMask: 0 backing: NSBackingStoreBuffered defer: YES];
    Register(v1->saveWindowsStateWindow, @"nameSheet");
    v1.windowsStateName = @"old";
    [v1 saveWindowsStateAsDICOMSR: nil];
    Record([NSString stringWithFormat: @"name %@", v1.windowsStateName]);
    v1.windowsStateName = @"named";
    for (NSInteger tag = 0; tag < 2; tag++) {
        NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle: @"" action: nil keyEquivalent: @""] autorelease]; item.tag = tag;
        [v1 endSaveWindowsStateAsDICOMSR: item];
        SavedState(s1);
    }
}

static void Lifecycle(void) {
    DicomStudy *s1 = Study(@"s1", @"P1", @"1.1");
    DicomSeries *a = Series(@"a", s1, @"1.1.1", @"1.1.1");
    [a setValue: @7 forKey: @"id"];
    [s1 setValue: @"DOE^JOHN" forKey: @"name"];
    [s1 setValue: [NSDate dateWithTimeIntervalSince1970: 0] forKey: @"dateOfBirth"];
    [s1 setValue: @"56 y" forKey: @"yearOld"];
    ViewerController *v1 = Viewer(@"v1", s1, @[a], 3), *v2 = Viewer(@"v2", s1, @[a], 3), *v3 = Viewer(@"v3", s1, @[a], 3);
    for (ViewerController *v in @[v1, v2, v3]) [ViewerController horos_register2DViewer: v];
    app.harnessWindows = @[v1.window, v2.window, v3.window];
    // Loaded.
    v1->displayOnlyKeyImages = YES;
    DCMView *outlet = v1->imageView; SeriesView *outletSeries = v1->seriesView;
    // Nothing sets the image and series views before the window loads (no
    // nib outlet does): -windowDidLoad gives them their first values.
    v1->imageView = nil; v1->seriesView = nil;
    [v1 windowDidLoad];
    Record([NSString stringWithFormat: @"loaded: popup %ld seriesView %@ imageView %@", (long)v1->keyImagePopUpButton.indexOfSelectedItem, Name(v1->seriesView), Name(v1->imageView)]);
    Retain(@"seriesView", outletSeries); Retain(@"imageView", outlet);
    v1->imageView = outlet;
    // Titles.
    v1->windowWillClose = YES; [v1 setWindowTitle: nil]; v1->windowWillClose = NO;
    for (int c = 0; c < 6; c++) {
        harnessShowsPatientName = c != 1; harnessShowsNumbers = c == 2;
        [s1 setValue: c == 3 ? nil : [NSDate dateWithTimeIntervalSince1970: 0] forKey: @"dateOfBirth"];
        DCMPix *pix = v1->pixList[0][0];
        pix.generated = c == 4; pix.generatedName = @"MIP";
        v1->imageView.curDCM.SUVConverted = c == 5;
        v1->imageView.curDCM.srcFile = c == 5 ? @"/bin/ls" : @"/nonexistent/file";
        [v1 setWindowTitle: nil];
    }
    NSThread *loading = [[[NSThread alloc] initWithBlock: ^{ sleep(30); }] autorelease];
    [loading.threadDictionary setObject: @0.425f forKey: @"loadingPercentage"];
    v1->loadingThread = [loading retain];
    [loading start];
    [v1 setWindowTitle: nil];
    [loading.threadDictionary setObject: @1.0f forKey: @"loadingPercentage"];
    [v1 setWindowTitle: nil];
    [loading cancel];
    [v1->fileList[0][0] setValue: @"/data/Empty.tif" forKey: @"completePath"];
    [v1 setWindowTitle: nil];
    [v1->fileList[0] removeAllObjects];
    [v1 setWindowTitle: nil];
    // Wait windows.
    id wait, rendering;
    @autoreleasepool { wait = [v1 startWaitProgressWindow: @"Working" : 12]; }
    Retain(@"wait", wait);
    [v1 waitIncrementBy: wait : 3];
    [wait retain];
    @autoreleasepool { [v1 endWaitWindow: wait]; }
    Retain(@"wait ended", wait);
    [wait release];
    @autoreleasepool { rendering = [v1 startWaitWindow: @"Rendering"]; }
    Retain(@"rendering", rendering);
    @autoreleasepool { [v1 endWaitWindow: rendering]; }
    [v1 endWaitWindow: nil];
    // Asked to close.
    NSToolbar *customizing = v1->toolbar;
    Record([NSString stringWithFormat: @"should close plain %d", [(id)v1 windowShouldClose: v1.window]]);
    app.harnessFlags = NSEventModifierFlagOption;
    Record([NSString stringWithFormat: @"should close option %d", [(id)v1 windowShouldClose: v1.window]]);
    app.harnessFlags = NSEventModifierFlagShift;
    Record([NSString stringWithFormat: @"should close shift %d", [(id)v1 windowShouldClose: v1.window]]);
    app.harnessFlags = 0;
    (void)customizing;
    // Miniaturized, main, screen.
    ToolbarPanelController *panel = [[ToolbarPanelController alloc] initWithWindow: [[[HarnessWindow alloc] initWithContentRect: NSZeroRect styleMask: 0 backing: NSBackingStoreBuffered defer: YES] autorelease]];
    Register(panel, @"toolbarPanel"); Register(panel.window, @"toolbarPanel.window");
    v1->toolbarPanel = panel;
    for (int i = 0; i < 2; i++) {
        thumbnailsListPanel[i] = [[ThumbnailsListPanel alloc] initWithWindow: [[[HarnessWindow alloc] initWithContentRect: NSZeroRect styleMask: 0 backing: NSBackingStoreBuffered defer: YES] autorelease]];
        Register(thumbnailsListPanel[i], [NSString stringWithFormat: @"panel%d", i]); Register(thumbnailsListPanel[i].window, [NSString stringWithFormat: @"panel%d.window", i]);
    }
    [thumbnailsListPanel[0] harnessLend: v1->previewMatrixScrollView];
    for (int c = 0; c < 4; c++) {
        Defaults(@{@"AUTOTILING": @(c & 1), @"UseFloatingThumbnailsList": @((c >> 1) & 1)});
        [AppController setUSETOOLBARPANEL: c >= 2]; harnessKeepToolbar = c != 3;
        [(id)v1 windowDidMiniaturize: nil];
        [(id)v1 windowDidDeminiaturize: nil];
        [(id)v1 windowDidResignMain: nil];
    }
    [OSIWindowController setHarnessDontWindowDidChangeScreen: YES];
    [(id)v1 windowDidChangeScreen: nil];
    [OSIWindowController setHarnessDontWindowDidChangeScreen: NO];
    [(id)v1 windowDidChangeScreen: nil];
    v1->windowWillClose = YES; [(id)v1 windowDidChangeScreen: nil]; v1->windowWillClose = NO;
    [(id)v1 windowDidBecomeMain: nil];
    // Closed: v1 with every timer, the panel, the sync on and a fused viewer.
    Defaults(@{@"AUTOTILING": @YES, @"UseFloatingThumbnailsList": @YES});
    [AppController setUSETOOLBARPANEL: YES];
    HarnessSYNCSERIES = YES;
    v1->blendingController = [v3 retain];
    v1->subCtrlOnOff.state = NSControlStateValueOn;
    NSTimer *timers[4];
    for (int i = 0; i < 4; i++) {
        timers[i] = [NSTimer timerWithTimeInterval: 100 repeats: NO block: ^(NSTimer *t) {}];
        Register(timers[i], [NSString stringWithFormat: @"timer%d", i]);
    }
    v1->highLightedTimer = [timers[0] retain]; v1->movieTimer = [timers[1] retain]; v1->timer = [timers[2] retain]; v1->t12BitTimer = [timers[3] retain];
    [panel retain];
    id observer = [[NSNotificationCenter defaultCenter] addObserverForName: OsirixCloseViewerNotification object: nil queue: nil usingBlock: ^(NSNotification *note) {
        Record([NSString stringWithFormat: @"notified close %@", Name(note.object)]);
    }];
    delayedTileWindows = 1;
    Retain(@"v1 before close", v1);
    Retain(@"panel before close", panel);
    @autoreleasepool { [v1.window close]; }
    Retain(@"v1 after close", v1);
    Retain(@"panel after close", panel);
    for (int i = 0; i < 4; i++) Record([NSString stringWithFormat: @"timer%d valid %d", i, timers[i].isValid]);
    Record([NSString stringWithFormat: @"v1 closing %d timers %@ %@ %@ %@ panel %@ delayed %d", v1->windowWillClose, Name(v1->highLightedTimer), Name(v1->movieTimer),
            Name(v1->timer), Name(v1->t12BitTimer), Name(v1->toolbarPanel), delayedTileWindows]);
    Viewers(@"after v1");
    // The last one but one: the sync is turned off; the last: the panels go.
    HarnessSYNCSERIES = YES;
    app.harnessWindows = @[v2.window, v3.window];
    Defaults(@{});
    @autoreleasepool { [v2.window close]; }
    app.harnessWindows = @[v3.window];
    @autoreleasepool { [v3.window close]; }
    Viewers(@"after all");
    [[NSNotificationCenter defaultCenter] removeObserver: observer];
    // +closeAllWindows.
    ViewerController *w1 = Viewer(@"w1", s1, @[a], 2), *w2 = Viewer(@"w2", s1, @[a], 2), *w3 = Viewer(@"w3", s1, @[a], 2);
    for (ViewerController *v in @[w1, w2, w3]) [ViewerController horos_register2DViewer: v];
    __block BOOL done = NO;
    NSThread *other = [[[NSThread alloc] initWithBlock: ^{ [ViewerController closeAllWindows]; done = YES; }] autorelease];
    [other start];
    while (!done) usleep(1000);
    Viewers(@"after a thread");
    w2->FullScreenOn = YES;
    w2->StartingWindow = w2.window; w2->contentView = w2.window.contentView;
    w2->FullScreenWindow = [[NSFullScreenWindow alloc] initWithContentRect: NSZeroRect styleMask: 0 backing: NSBackingStoreBuffered defer: YES];
    w3->windowWillClose = YES;
    ((HarnessWindow*)w1.window).nextMain = w2;
    Defaults(@{@"automaticWorkspaceSave": @YES, @"listPODComparativesIn2DViewer": @NO});
    delayedTileWindows = 1;
    @autoreleasepool { [ViewerController closeAllWindows]; }
    Record([NSString stringWithFormat: @"listPOD %d delayed %d", [[NSUserDefaults standardUserDefaults] boolForKey: @"listPODComparativesIn2DViewer"], delayedTileWindows]);
    Viewers(@"after closeAllWindows");
    w3->windowWillClose = NO;
    Defaults(@{@"DontResetListPODComparativesIn2DViewer": @YES, @"listPODComparativesIn2DViewer": @NO});
    @autoreleasepool { [ViewerController closeAllWindows]; }
    Record([NSString stringWithFormat: @"listPOD %d", [[NSUserDefaults standardUserDefaults] boolForKey: @"listPODComparativesIn2DViewer"]]);
    Viewers(@"at the end");
}

static void Layout(void) {
    DicomStudy *s1 = Study(@"s1", @"P1", @"1.1");
    NSMutableArray *series = [NSMutableArray array];
    for (int i = 0; i < 5; i++) [series addObject: Series([NSString stringWithFormat: @"sr%d", i], s1, [NSString stringWithFormat: @"1.1.%d", i], nil)];
    s1.series = series;
    // +newWindow:::
    NSMutableArray *pix = [NSMutableArray array], *files = [NSMutableArray array];
    NSMutableData *volume = [NSMutableData dataWithLength: 16];
    Register(pix, @"pix"); Register(files, @"files"); Register(volume, @"volume");
    for (int autoTiling = 0; autoTiling < 2; autoTiling++) {
        Defaults(@{@"AUTOTILING": @(autoTiling)});
        ViewerController *made;
        @autoreleasepool { made = [ViewerController newWindow: pix : files : volume frame: autoTiling ? NSMakeRect(5, 6, 700, 500) : NSZeroRect]; }
        Retain(@"made", made);
        Record([NSString stringWithFormat: @"made %@ frame %@", Name(made), R(made.window.frame)]);
        @autoreleasepool { made = [ViewerController newWindow: pix : files : volume]; }
        Retain(@"made", made);
        @autoreleasepool { made = [made newWindow: pix : files : volume]; }
        Retain(@"made", made);
    }
    ViewerController *v1 = Viewer(@"v1", s1, @[series[0]], 3), *v2 = Viewer(@"v2", s1, @[series[1]], 3), *v3 = Viewer(@"v3", s1, @[series[2]], 3);
    for (ViewerController *v in @[v1, v2, v3]) [ViewerController horos_register2DViewer: v];
    [v1 tileWindows];
    // The tiling menu: fewer places than viewers, then more.
    for (int i = 0; i < 2; i++) {
        thumbnailsListPanel[i] = [[ThumbnailsListPanel alloc] initWithWindow: nil];
        Register(thumbnailsListPanel[i], [NSString stringWithFormat: @"panel%d", i]);
    }
    HarnessPopUp *menu = [[[HarnessPopUp alloc] initWithFrame: NSZeroRect pullsDown: NO] autorelease];
    Defaults(@{@"AUTOTILING": @YES});
    menu.harnessTag = 11; delayedTileWindows = 1;
    [v2 SetWindowsTiling: menu];
    Viewers(@"11");
    Record([NSString stringWithFormat: @"AUTOTILING %d delayed %d", [[NSUserDefaults standardUserDefaults] boolForKey: @"AUTOTILING"], delayedTileWindows]);
    harnessViewerScreens = 2; menu.harnessTag = 12; delayedTileWindows = 0;
    [v2 SetWindowsTiling: menu];
    Viewers(@"12 on two screens");
    harnessViewerScreens = 1; menu.harnessTag = 13;
    [v2 SetWindowsTiling: menu];
    Viewers(@"13");
    v2->study = nil;
    menu.harnessTag = 22;
    [v2 SetWindowsTiling: menu];
    Viewers(@"22 without a study");
    // The zoom button.
    NSWindow *window = v1.window;
    [window setFrame: NSMakeRect(10, 10, 400, 300) display: NO];
    for (NSValue *frame in @[[NSValue valueWithRect: NSMakeRect(10, 10, 400, 300)], [NSValue valueWithRect: NSMakeRect(0, 22, 985, 785)],
                             [NSValue valueWithRect: NSMakeRect(0, 22, 975, 785)]]) {
        [window setFrame: frame.rectValue display: NO];
        NSRect zoom = [(id)v1 windowWillUseStandardFrame: window defaultFrame: NSZeroRect];
        Record([NSString stringWithFormat: @"zoom %@ standard %@", R(zoom), R(v1->standardRect)]);
    }
    ((HarnessWindow*)window).harnessScreen = nil;
    Record([NSString stringWithFormat: @"zoom no screen %@", R([(id)v1 windowWillUseStandardFrame: window defaultFrame: NSZeroRect])]);
    [v1 setStandardRect: NSZeroRect];
    // -setWindowFrame...
    NSRect frames[] = { NSMakeRect(10.4, 10.6, 400.2, 299.5), NSMakeRect(13, 10, 400, 300), NSMakeRect(40.5, 50, 800, 600), NSMakeRect(40.4, 50, 800, 600) };
    for (int visible = 0; visible < 2; visible++)
        for (int i = 0; i < 4; i++)
            for (int options = 0; options < 4; options++) {
                [window setFrame: NSMakeRect(10, 10, 400, 300) display: NO];
                ((HarnessWindow*)window).harnessVisible = visible;
                Record([NSString stringWithFormat: @"setWindowFrame %@ visible %d show %d animate %d", R(frames[i]), visible, options & 1, options >> 1]);
                [v1 setWindowFrame: frames[i] showWindow: options & 1 animate: options >> 1];
                Record([NSString stringWithFormat: @"  -> %@ standard %@", R(window.frame), R(v1->standardRect)]);
            }
    [v1 setWindowFrame: NSMakeRect(1, 2, 3, 4) showWindow: NO];
    [v1 setWindowFrame: NSMakeRect(5, 6, 7, 8)];
}

static void FullScreen(void) {
    DicomStudy *s1 = Study(@"s1", @"P1", @"1.1");
    DicomSeries *a = Series(@"a", s1, @"1.1.1", @"1.1.1");
    ViewerController *v1 = Viewer(@"v1", s1, @[a], 6), *v2 = Viewer(@"v2", s1, @[a], 6);
    for (ViewerController *v in @[v1, v2]) [ViewerController horos_register2DViewer: v];
    ToolbarPanelController *panel = [[ToolbarPanelController alloc] initWithWindow: [[[HarnessWindow alloc] initWithContentRect: NSZeroRect styleMask: 0 backing: NSBackingStoreBuffered defer: YES] autorelease]];
    Register(panel, @"toolbarPanel"); Register(panel.window, @"toolbarPanel.window");
    v1->toolbarPanel = panel;
    [v1.window setFrame: NSMakeRect(30, 40, 500, 400) display: NO];
    v1->imageView = v1->seriesView.harnessImageViews[1];
    [v1->imageView setIndex: 4];
    v1->imageView.scaledFit = YES;
    v1->previousSliderStripHeight = 24;
    for (int c = 0; c < 4; c++) {
        Record([NSString stringWithFormat: @"case %d", c]);
        Defaults(@{@"NoImageTilingInFullscreen": @(c != 1), @"AlwaysScaleToFit": @(c == 2), @"COPYSETTINGS": @(c != 3)});
        [AppController setUSETOOLBARPANEL: c != 2];
        if (c == 1) v1->blendingController = [v2 retain];
        if (c == 3) { ((HarnessWindow*)v1.window).harnessScreen = nil; v1->imageView.scaledFit = NO; v1->imageView.rows = 1; v1->imageView.columns = 1; }
        Record([NSString stringWithFormat: @"FullScreenON %d", [v1 FullScreenON]]);
        @autoreleasepool { [v1 fullScreenMenu: nil]; }
        Ivars(v1);
        Record([NSString stringWithFormat: @"FullScreenON %d COPYSETTINGS %d", [v1 FullScreenON], [[NSUserDefaults standardUserDefaults] boolForKey: @"COPYSETTINGS"]]);
        Retain(@"full screen window", v1->FullScreenWindow);
        [v1->imageView setIndex: 2];
        @autoreleasepool {
            if (c == 0) [v1 fullScreenMenu: nil];
            else if (c == 1) [v1 offFullScreen];
            else [(id)v1 applicationDidResignActive: nil];
        }
        Ivars(v1);
        Record([NSString stringWithFormat: @"FullScreenON %d COPYSETTINGS %d", [v1 FullScreenON], [[NSUserDefaults standardUserDefaults] boolForKey: @"COPYSETTINGS"]]);
        v1->imageView = v1->seriesView.harnessImageViews[1];
    }
    [v1 offFullScreen];
    [(id)v1 applicationDidResignActive: nil];
}

int main(int argc, const char **argv) { @autoreleasepool {
    app = (HarnessApplication*)[HarnessApplication sharedApplication];
    keep = [NSMutableArray new];
    harnessLoadedViewers = [NSMutableArray new];
    Register(app, @"NSApp");
    NSString *scenario = [NSString stringWithUTF8String: argv[1]];
    if ([scenario isEqualToString: @"registry"]) Registry();
    else if ([scenario isEqualToString: @"state"]) State();
    else if ([scenario isEqualToString: @"lifecycle"]) Lifecycle();
    else if ([scenario isEqualToString: @"layout"]) Layout();
    else if ([scenario isEqualToString: @"fullscreen"]) FullScreen();
    else return 3;
    Defaults(@{});
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName: [[NSBundle mainBundle] bundleIdentifier] ?: [[NSProcessInfo processInfo] processName]];
} return 0; }
'''

# The reference's statics and the registration -viewerControllerInit made,
# as ViewerController.m had them.
REFERENCE_PRELUDE = r'''#import "Harness.h"
#define SYNCSERIES HarnessSYNCSERIES
static int numberOf2DViewer = 0;
static NSMutableArray *arrayOf2DViewers = nil;
static BOOL recursiveCloseWindowsProtected = NO;
'''

REFERENCE_REGISTER = r'''
+ (void) horos_register2DViewer:(ViewerController*) viewer
{
    numberOf2DViewer++;
    @synchronized( arrayOf2DViewers)
    {
        if( arrayOf2DViewers == nil)
            arrayOf2DViewers = [[NSMutableArray alloc] init];
        [arrayOf2DViewers addObject: viewer];
    }
}
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
    ('+ (NSArray*) displayed2DViewerForScreen: (NSScreen*) screen', '+ (NSMapTable*) horosSeriesWindowNumbers'),
    ('+ (NSArray*) studyColors\n', '+ (NSArray*) studyColors\n'),
    ('- (IBAction) resetWindowsState:(id)sender', '+ (void) saveWindowsStateWithDICOMSR: (BOOL) DICOMSR name: (NSString*) name'),
    ('- (void) setWindowTitle:(id) sender', '- (void) endWaitWindow:(id) waitWindow'),
    ('- (void)windowDidLoad\n', '-(BOOL) windowWillClose\n'),
    ('- (BOOL)windowShouldClose:(id)sender', '- (void)windowDidChangeScreen:(NSNotification *)aNotification'),
    ('- (void) windowDidBecomeMain:(NSNotification *)aNotification', '- (BOOL) is2DViewer'),
    ('+ (void)closeAllWindows', '-(void) offFullScreen\n'),
    ('+ (int) numberOf2DViewer\n', '+ (int) numberOf2DViewer\n'),
    ('- (void)setStandardRect:(NSRect)rect\n', '- (void)setStandardRect:(NSRect)rect\n'),
]


def objc_blocks(text):
    """The register, layout, window life, tiling and full screen blocks of
    ViewerController.m, in a category of the stand-in."""
    parts = []
    for first, last in GROUPS:
        a = text.index(first)
        b = method_end(text, text.index(last, a))
        parts.append(text[a:b])
    return REFERENCE_PRELUDE + '@implementation ViewerController (Windows)\n' + '\n'.join(parts) + REFERENCE_REGISTER + '@end\n'


reference = args.reference
if reference is None:
    head = read('HEAD', VC)
    reference = 'HEAD' if head and MARK.encode() in head else history_reference.before_text_removed(VC, MARK)
if reference is None:
    print('skipped: needs the history that has the Objective-C ViewerController.m (a shallow clone does not)')
    sys.exit(2)
reference_vc = read(reference, VC)
if reference_vc is None or MARK.encode() not in reference_vc:
    sys.exit('FAIL: %s has no Objective-C viewer register in %s' % (reference, VC))
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


with tempfile.TemporaryDirectory(prefix='horos-viewer-windows-') as tmp:
    folder = Path(tmp)
    (folder / 'Harness.h').write_text(HEADER)
    (folder / 'Stubs.m').write_text(STUBS)
    (folder / 'Driver.m').write_text(DRIVER)
    for name in ('HorosObjCException.h', 'HorosObjCException.m'):
        (folder / name).write_bytes((ROOT / 'Horos/Sources' / name).read_bytes())
    frameworks = ['-framework', 'Cocoa', '-framework', 'CoreData']

    def clang(source, arc=False):
        target = folder / (Path(source).stem + '.o')
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
        sources = []
        for name in SWIFT_FILES:
            text = read(args.current, 'Horos/Sources/' + name)
            if text is None:
                sys.exit('FAIL: no Horos/Sources/%s' % name)
            (swift / name).write_bytes(text)
            sources.append(str(swift / name))
        # [sender tag] as the blocks send it.
        support = read(args.current, 'Horos/Sources/ViewerController+ImagePipelineSupport.swift').decode('utf-8')
        sender = re.search(r'\nenum ViewerSender \{.*?\n}\n', support, re.S).group(0)
        (swift / 'Helpers.swift').write_text('import AppKit\n' + sender)
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
             *sources, *common, *frameworks, '-o', str(current_program)],
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
            result = subprocess.run([str(program), scenario], capture_output=True, text=True, timeout=60)
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
    print('PASS: the viewer register, saved layout, window life, tiling and full screen are identical to the Objective-C in every scenario')
