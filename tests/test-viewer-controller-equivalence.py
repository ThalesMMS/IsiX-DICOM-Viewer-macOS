#!/usr/bin/env python3
"""The 2D viewer's own life and the methods ViewerController.m kept do what
their Objective-C did.

ViewerController.m kept, after the earlier steps moved its blocks to Swift
extensions, the life of the viewer as an object and a few methods; the class
is now Swift, and these went to ViewerController+Lifecycle.swift,
+DatabaseRefresh, +ViewerNotifications, +HotKeys and NSString+Truncate.swift
(with IsiXImaging's DatabaseRefreshPlan and TextTruncation). This runs the
same synthetic scenarios through both and compares everything they produce:

* lifecycle: the initializer after the window controller exists (the
  database, the magnetic window, the toolbar, the locks and queues, the data,
  the series lock across studies, the fusion asked by the preferences, the
  12-bit timer, the plugins' environment, the toolbar panel),
  -viewerControllerInit (the register, the toolbar panel replacing the
  toolbars, the default menus, every notification observed, the dragged
  types, the PET colour and opacity tables, the 12-bit display, the tool
  menus' images, the status and comment, the series list's visibility and its
  observations), the nib's awakening (the cine controls' accessibility, the
  inverted display, the split view made when the nib has none, the
  comparatives button and binding, ViewerPanels.nib's second awakening) and
  what -dealloc gave back (observers, delegates, the split view, the database
  shown when no window is left, the fusion, the series loading, every object
  released, the floating lists, the other viewers' lists, the pending
  performs), with the retain counts of what is kept and released;
* refresh: -refreshDatabase: (reentry, a drag in progress, no list, images of
  the open series, of its patient, of another patient, a viewer that shows
  nothing, the coalescer's delay, the image restored by SOP instance and
  frame, the retrieve count, an exception) and -comparativeRefresh:;
* notifications: -CloseViewerNotification:, -updateImageView: (with the
  retain counts of the views) and the volume data notifications;
* hotkeys: +getToolEquivalentToHotKey: and +getHotKeyEquivalentToTool: (the
  tool right after the table, which the Objective-C read out of the table's
  bounds, left out);
* truncate: NSString (Truncate) in the three directions, too short lengths
  (the exceptions they raise) and another direction.

The reference is the Objective-C of ViewerController.m in the last revision
that has it (history_reference), compiled with clang as Xcode compiles it
(manual retain and release); the other side is the current tree: the Swift
files with IsiXImaging, compiled with swiftc, or the Objective-C again if the
tree still has it (which is how this test ran, and passed, before the
conversion). Both run over the same stand-ins of the viewer (its instance
variables, outlets and the methods of its other blocks), its window and
views, the application, the defaults, the notification centre, the browser,
the database objects and the panels, which record what they are given; the
two records must be identical.

    python3 tests/test-viewer-controller-equivalence.py [--reference REV] [--current REV] [--dump DIR]
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
SWIFT_FILES = ['NSString+Truncate.swift', 'ViewerController+HotKeys.swift', 'ViewerController+ViewerNotifications.swift',
               'ViewerController+DatabaseRefresh.swift', 'ViewerController+Lifecycle.swift']
# IsiXLogging first: the others that log write through it.
MODULES = ['IsiXLogging', 'IsiXImaging']
SCENARIOS = ['lifecycle', 'refresh', 'notifications', 'hotkeys', 'truncate']

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


# ---------------------------------------------------------------------------
# The ivars of the stand-in, as ViewerController.h declared them, and the
# accessors the Swift reads them through, as ViewerController+SwiftIvars.h
# declared them (the Swift names of the class's state).
#   kind: 'outlet' (readonly accessor), 'object' (retain accessor), 'scalar'.
IVARS = [
    ('scalar', 'BOOL', 'openingScaleToFitRequested'), ('object', 'NSDictionary*', 'openingContentBoundsByPixels'),
    ('object', 'NSRecursiveLock*', 'roiLock'), ('object', 'NSConditionLock*', 'flipDataThread'), ('object', 'NSConditionLock*', 'convThread'),
    ('object', 'ToolbarPanelController*', 'toolbarPanel'), ('object', 'SeriesView*', 'seriesView'), ('object', 'DCMView*', 'imageView'),
    ('scalar', 'short', 'originalOrientation'), ('object', 'NSMenuItem*', 'seriesPopupContextualMenu'),
    ('scalar', 'long', 'subCtrlMaskID'), ('object', 'NSDate*', 'editedRadiopharmaceuticalStartTime'), ('object', 'NSDate*', 'editedAcquisitionTime'),
    ('object', 'NSDate*', 'injectionDateTime'), ('object', 'ViewerController*', 'blendingController'),
    ('object', 'NSString*', 'curConvMenu'), ('object', 'NSString*', 'curWLWWMenu'), ('object', 'NSString*', 'curCLUTMenu'),
    ('object', 'NSString*', 'backCurCLUTMenu'), ('object', 'NSString*', 'curOpacityMenu'),
    ('scalar', 'short', 'curMovieIndex'), ('scalar', 'short', 'maxMovieIndex'), ('object', 'NSToolbar*', 'toolbar'),
    ('scalar', 'float', 'direction'), ('scalar', 'float', 'factorPET2SUV'), ('object', 'NSMutableArray*', 'ROINamesArray'),
    ('object', 'DICOMExport*', 'exportDCM'), ('scalar', 'BOOL', 'displayOnlyKeyImages'), ('object', 'NSConditionLock*', 'processorsLock'),
    ('object', 'NSMutableArray*', 'undoQueue'), ('object', 'NSMutableArray*', 'redoQueue'), ('scalar', 'float', 'resampleRatio'),
    ('object', 'ViewerController*', 'blendedWindow'), ('object', 'NSMutableArray*', 'retainedToolbarItems'), ('object', 'NSTimer*', 't12BitTimer'),
    ('scalar', 'BOOL', 'splitViewAllocated'), ('object', 'NSNumber*', 'flagListPODComparatives'),
    ('outlet', 'NSPopUpButton*', 'OpacityPopup'), ('outlet', 'NSPopUpButton*', 'wlwwPopup'), ('outlet', 'NSPopUpButton*', 'convPopup'),
    ('outlet', 'NSMatrix*', 'display12bitToolbarItemMatrix'), ('outlet', 'NSPopUpButton*', 'popupRoi'),
    ('outlet', 'NSPopUpButton*', 'ReconstructionRoi'), ('outlet', 'NSPopUpButton*', 'StatusPopup'), ('outlet', 'NSButton*', 'CommentsField'),
    ('outlet', 'NSScrollView*', 'previewMatrixScrollView'), ('outlet', 'NSMatrix*', 'orientationMatrix'), ('outlet', 'NSSlider*', 'speedSlider'),
    ('outlet', 'NSTextField*', 'speedText'), ('outlet', 'NSSlider*', 'movieRateSlider'), ('outlet', 'NSTextField*', 'movieTextSlide'),
    ('outlet', 'NSButton*', 'moviePlayStop'), ('outlet', 'NSSlider*', 'moviePosSlider'), ('outlet', 'NSSplitView*', 'splitView'),
    ('outlet', 'NSMatrix*', 'previewMatrix'), ('outlet', 'NSButton*', 'comparativesButton'),
]
# The flags and objects the Swift reads off the main thread.
NONISOLATED = {'imageView', 'seriesView', 'roiLock', 'processorsLock', 'curMovieIndex', 'maxMovieIndex'}
# Properties the class declared, which @synthesize implemented over the ivars.
PROPERTIES = {'injectionDateTime', 'blendedWindow', 'toolbarPanel', 'speedSlider', 'speedText', 'movieRateSlider', 'movieTextSlide'}


def accessors():
    declared, implemented = [], []
    for kind, type_, name in IVARS:
        tail = ' NS_SWIFT_NONISOLATED' if name in NONISOLATED else ''
        if kind == 'outlet':
            declared.append('@property(readonly, nullable) %s horos_%s;' % (type_, name))
            implemented.append('- (%s)horos_%s { return %s; }' % (type_, name, name))
        elif kind == 'object':
            declared.append('@property(retain, nullable) %s horos_%s%s;' % (type_, name, tail))
            implemented.append('- (%s)horos_%s { return %s; }' % (type_, name, name))
            implemented.append('- (void)setHoros_%s:(%s)value { [value retain]; [%s release]; %s = value; }' % (name, type_, name, name))
        else:
            declared.append('@property(assign) %s horos_%s%s;' % (type_, name, tail))
            implemented.append('- (%s)horos_%s { return %s; }' % (type_, name, name))
            implemented.append('- (void)setHoros_%s:(%s)value { %s = value; }' % (name, type_, name))
    declared += ['- (void)horos_assignSplitView:(nullable NSSplitView*)value NS_SWIFT_NAME(horos_assignSplitView(_:));',
                 '- (nullable NSMutableArray*)horos_fileListAt:(NSInteger)index NS_SWIFT_NONISOLATED;',
                 '- (nullable NSMutableArray*)horos_pixListAt:(NSInteger)index NS_SWIFT_NONISOLATED;',
                 '- (nullable NSMutableArray*)horos_roiListAt:(NSInteger)index;',
                 '- (nullable NSObject*)horos_volumeDataAt:(NSInteger)index;']
    implemented += ['- (void)horos_assignSplitView:(NSSplitView*)value { splitView = value; }',
                    '- (NSMutableArray*)horos_fileListAt:(NSInteger)index { return fileList[index]; }',
                    '- (NSMutableArray*)horos_pixListAt:(NSInteger)index { return pixList[index]; }',
                    '- (NSMutableArray*)horos_roiListAt:(NSInteger)index { return roiList[index]; }',
                    '- (NSObject*)horos_volumeDataAt:(NSInteger)index { return volumeData[index]; }']
    return '\n'.join(declared), '\n'.join(implemented)


def ivar_block():
    lines = []
    for kind, type_, name in IVARS:
        lines.append('    %s%s %s;' % ('IBOutlet ' if kind == 'outlet' else '', type_, name))
    return '\n'.join(lines)


def dump_lines():
    """What the driver prints of the stand-in's state: every ivar."""
    out = []
    for kind, type_, name in IVARS:
        if type_.endswith('*'):
            out.append('    Record([NSString stringWithFormat: @"  %s %%@ rc %%lu", Name(v->%s), Rc(v->%s)]);' % (name, name, name))
        elif type_ in ('float',):
            out.append('    Record([NSString stringWithFormat: @"  %s %%a", (double)v->%s]);' % (name, name))
        else:
            out.append('    Record([NSString stringWithFormat: @"  %s %%ld", (long)v->%s]);' % (name, name))
    return '\n'.join(out)


DECLARED, IMPLEMENTED = accessors()

HEADER = r'''#pragma clang diagnostic ignored "-Wnullability-completeness"
#import <Cocoa/Cocoa.h>
#import <CoreData/CoreData.h>
#import "HorosObjCException.h"
#import "Notifications.h"

// The stand-ins of the viewer, its window and views, the application, the
// defaults, the browser, the database objects and the panels, declared with
// the selectors and the Swift names the app gives them, so that the
// Objective-C and the Swift compile against them alike. They record what
// they are given (Record) and answer from their fields.

#define MAX4D 8
#define MAXSCREENS 10
#define ToolsMenuIconSize NSMakeSize(28.0, 28.0)

void Record(NSString *line);
NSString *Name(id object);
void Register(id object, NSString *name);
void RegisterViewer(id object, NSString *name);
BOOL Registered(id object);
unsigned long Rc(id o);

void HarnessLogException(NSException *e);
#define N2LogException(e) HarnessLogException(e)
#define N2LogStackTrace(format, ...) Record([@"stack " stringByAppendingString: [NSString stringWithFormat: format, ##__VA_ARGS__]])
void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *function);
void ViewerControllerLogStackTrace(NSString *message);
void N2LogStackTraceMessage(NSString *message);

TOOLMODE

HOTKEYS

extern NS_SWIFT_UI_ACTOR BOOL SyncButtonBehaviorIsBetweenStudies;

@class ViewerController, DCMView, SeriesView, DCMPix, DicomStudy, DicomSeries, DicomImage, ThumbnailsListPanel, ToolbarPanelController, DICOMExport;

extern ThumbnailsListPanel *thumbnailsListPanel[MAXSCREENS];
ThumbnailsListPanel * _Nullable AppControllerCAPIThumbnailsListPanel(NSInteger index);

/// A window that never reaches the window server: its calls are recorded.
@interface HarnessWindow : NSWindow
@property(assign) id harnessController;
@property BOOL harnessMain, harnessKey;
@property(retain) NSToolbar *harnessToolbar;
@end

@interface HarnessApplication : NSApplication
@property(retain) NSArray *harnessWindows;
@end

@interface HarnessDefaults : NSUserDefaults
@property(retain) NSMutableDictionary *values;
@end

@interface NSImage (HarnessToolbar)
+ (NSImage*) toolbarImageNamed:(NSString*) name;
@end

@interface DicomDatabase : NSObject
+ (DicomDatabase*) databaseForContext:(NSManagedObjectContext*) c;
@end

@interface DicomStudy : NSObject
@property(retain) NSString *patientUID;
@property(retain) NSNumber *stateText;
@property(retain) NSDate *date;
@property(retain) NSString *studyInstanceUID;
@end

@interface DicomSeries : NSObject
@property(retain) DicomStudy *study;
@property(retain) NSObject *objectID;
@property(retain) NSString *comment;
@property(retain) NSString *seriesDICOMUID;
@end

@interface DicomImage : NSObject
@property(retain) DicomSeries *series;
@property(retain) NSManagedObjectContext *managedObjectContext;
@property(retain) NSString *harnessSOP;
@property(retain) NSNumber *frameID;
- (NSString*) sopInstanceUID;
@end

@interface DCMPix : NSObject
@property BOOL isRGB;
@end

@interface ROI : NSObject
+ (void) loadDefaultSettings;
@end

@interface DCMView : NSView
@property BOOL drawing;
@property(nonatomic) float syncRelativeDiff;
@property long syncSeriesIndex;
@property NSInteger harnessCurImage;
@property BOOL harnessDragging;
@property NSInteger rows, columns;
@property(retain) DicomStudy *studyObj;
@property(assign) NSWindow *harnessWindow;
@property(readonly) NSInteger curImage;
@property(readonly) BOOL mouseDragging;
+ (NSArray*) PasteboardTypes NS_SWIFT_NAME(pasteboardTypes());
+ (NSArray*) PluginPasteboardTypes NS_SWIFT_NAME(pluginPasteboardTypes());
- (void) setIndex:(NSInteger) index;
- (void) updateTilingViews;
- (void) setIsLUT12Bit:(BOOL) b;
@end

@interface SeriesView : NSView
- (void) setPixels:(NSMutableArray*)pixels files:(NSMutableArray*)files rois:(NSMutableArray*)rois firstImage:(NSInteger)firstImage level:(char)level reset:(BOOL)reset;
@end

@interface ThumbnailsListPanel : NSObject
- (void) thumbnailsListWillClose:(NSView*) view;
@end

@interface ToolbarPanelController : NSObject
- (instancetype) initForViewer:(ViewerController*) v withToolbar:(NSToolbar*) t NS_SWIFT_NAME(init(forViewer:withToolbar:));
@end

@interface DICOMExport : NSObject
@end

@interface AppController : NSObject
+ (BOOL) canDisplay12Bit;
+ (BOOL) USETOOLBARPANEL NS_SWIFT_NAME(usetoolbarpanel());
+ (void) setUSETOOLBARPANEL:(BOOL) b;
@end

@interface OSIEnvironment : NSObject
+ (OSIEnvironment*) sharedEnvironment NS_SWIFT_NAME(shared());
- (void) addViewerController:(ViewerController*) viewer NS_SWIFT_NAME(addViewerController(_:));
@end

@interface BrowserController : NSObject
+ (BrowserController*) currentBrowser;
+ (NSArray*) DatabaseObjectXIDsPasteboardTypes NS_SWIFT_NAME(databaseObjectXIDsPasteboardTypes());
- (NSArray*) childrenArray:(id) item;
- (ViewerController*) openViewerFromImages:(NSArray*) toOpenArray movie:(BOOL) movieViewer viewer:(ViewerController*) viewer keyImagesOnly:(BOOL) keyImages tryToFlipData:(BOOL) tryToFlipData;
- (void) showDatabase:(id) sender;
@end

NS_SWIFT_NAME(ExcludedSeries)
@interface HorosExcludedSeries : NSObject
@property(class, readonly) NSNotificationName didChangeNotification;
@end

NS_SWIFT_NAME(SeriesListIdentification)
@interface HorosSeriesListIdentification : NSObject
@property(class, readonly) NSString *defaultsKey;
@end

NS_SWIFT_NAME(SeriesListLayout)
@interface HorosSeriesListLayout : NSObject
@property(class, readonly) NSString *placementDidChangeNotification;
@end

NS_SWIFT_NAME(RefreshCoalescer)
@interface HorosRefreshCoalescer : NSObject
@property NSTimeInterval harnessWait;
- (NSTimeInterval) requestAt:(NSTimeInterval) now NS_SWIFT_NAME(request(at:));
- (void) appliedAt:(NSTimeInterval) now NS_SWIFT_NAME(applied(at:));
@end

NS_SWIFT_NAME(RetrieveViewing)
@interface HorosRetrieveViewing : NSObject
@property(class, readonly) HorosRetrieveViewing *shared;
+ (NSInteger) indexOfSOPInstanceUID:(NSString*) sop frame:(NSInteger) frame inSOPInstanceUIDs:(NSArray<NSString*>*) sops frames:(NSArray<NSNumber*>*) frames fallback:(NSInteger) fallback
    NS_SWIFT_NAME(index(ofSOPInstanceUID:frame:inSOPInstanceUIDs:frames:fallback:));
- (void) localCountChangedForStudyUID:(NSString*) study seriesUID:(NSString*) series localCount:(NSInteger) count
    NS_SWIFT_NAME(localCountChanged(studyUID:seriesUID:localCount:));
+ (NSInteger) uniqueInstanceCountOfImages:(NSArray<NSObject*>*) images NS_SWIFT_NAME(uniqueInstanceCount(ofImages:));
@end

@interface HarnessSeriesLoad : NSObject
- (void) cancel;
@end

@interface OSIWindowController : NSWindowController
@property(retain) DicomDatabase *database;
- (void) setMagnetic:(BOOL) a;
- (void) refreshDatabase:(NSArray*) newImages;
- (void) ApplyCLUTString:(NSString*) str;
- (void) ApplyOpacityString:(NSString*) str;
@end

@interface ViewerController : OSIWindowController <NSWindowDelegate, NSSplitViewDelegate> {
@public
IVAR_BLOCK
    NSMutableArray *fileList[MAX4D], *pixList[MAX4D], *roiList[MAX4D];
    NSData *volumeData[MAX4D];
    NSString *windowsStateName;
    NSWindow *harnessWindow;
    BOOL harnessPanelsLoaded;
    NSString *harnessStudyUID, *harnessModality;
    NSToolbarItem *harnessSyncButton;
    HorosRefreshCoalescer *harnessCoalescer;
    HarnessSeriesLoad *harnessSeriesLoad;
    DicomStudy *harnessStudy;
    DicomSeries *harnessSeries;
    BOOL harnessRecurse, harnessRaise;
    NSWindow *harnessViewWindow;
}
@property(retain) NSDate *injectionDateTime;
@property(retain) NSString *windowsStateName;
@property(retain) NSNumber *flagListPODComparatives;
@property(nonatomic, retain) ViewerController *blendedWindow;
@property(readonly) ToolbarPanelController *toolbarPanel;
@property(readonly, nonnull) HarnessSeriesLoad *horosSeriesLoad;
@property(readonly) BOOL horosViewerPanelsLoaded;
+ (BOOL) horos_SYNCSERIES;
+ (void) horos_setSYNCSERIES:(BOOL) value;
+ (BOOL) horos_DisplayUseInvertedPolarity;
+ (void) horos_setDisplayUseInvertedPolarity:(BOOL) value;
+ (void) horos_register2DViewer:(ViewerController*) viewer;
+ (int) numberOf2DViewer;
+ (NSMutableArray*) getDisplayed2DViewers;
+ (void) clearFrontMost2DViewerCache;
- (DCMView*) imageView;
- (NSString*) studyInstanceUID;
- (NSString*) modality;
- (DicomStudy*) currentStudy;
- (DicomSeries*) currentSeries;
- (void) setupToolbar;
// NSObject: Swift would bridge an NSData parameter to Data (a copy); the app declares it in Swift.
- (void) changeImageData:(NSMutableArray*)f :(NSMutableArray*)d :(NSObject*)v :(BOOL)newViewerWindow;
- (void) SetSyncButtonBehavior:(id) sender NS_SWIFT_NAME(setSyncButtonBehavior(_:));
- (void) turnOffSyncSeriesBetweenStudies:(id) sender;
- (id) findSyncSeriesButton;
- (void) blendWindows:(id) sender;
- (void) verify12Bit:(NSTimer*) timer;
- (NSImage*) imageForROI:(ToolMode) i;
- (void) setMatrixVisible:(BOOL) visible;
- (void) updateSeriesListMode;
- (void) observeScrollerStyleDidChangeNotification:(NSNotification*) n NS_SWIFT_NAME(observeScrollerStyleDidChangeNotification(_:));
- (void) discardPrintSpoolDirectory;
- (void) ActivateBlending:(ViewerController*) bC;
- (void) buildMatrixPreview:(BOOL) showSelected;
- (HorosRefreshCoalescer*) horosRefreshCoalescer;
- (void) adjustSlider;
- (void) refreshToolbar;
- (void) applicationDidResignActive:(NSNotification*) n;
- (void) UpdateWLWWMenu:(NSNotification*) n;
- (void) ViewFrameDidChange:(NSNotification*) n NS_SWIFT_NAME(ViewFrameDidChange(_:));
- (void) ViewBoundsDidChange:(NSNotification*) n NS_SWIFT_NAME(ViewBoundsDidChange(_:));
- (void) revertSeriesNotification:(NSNotification*) n;
- (void) updateVolumeData:(NSNotification*) n;
- (void) retrieveViewingStateChanged:(NSNotification*) n;
- (void) excludedSeriesDidChange:(NSNotification*) n;
- (void) roiChange:(NSNotification*) n;
- (void) OpacityChanged:(NSNotification*) n;
- (void) defaultToolModified:(NSNotification*) n;
- (void) defaultRightToolModified:(NSNotification*) n;
- (void) defaultMiddleToolModified:(NSNotification*) n;
- (void) UpdateConvolutionMenu:(NSNotification*) n;
- (void) CLUTChanged:(NSNotification*) n;
- (void) UpdateCLUTMenu:(NSNotification*) n;
- (void) UpdateOpacityMenu:(NSNotification*) n;
- (void) recomputeROI:(NSNotification*) n;
- (void) notificationStopPlaying:(NSNotification*) n;
- (void) notificationSyncSeries:(NSNotification*) n;
- (void) exportTextFieldDidChange:(NSNotification*) n;
- (void) updateReportToolbarIcon:(NSNotification*) n;
- (void) reportToolbarItemWillPopUp:(NSNotification*) n;
#ifdef HARNESS_SWIFT
- (void) horosFinishInitializationWithPix:(NSMutableArray*)f files:(NSMutableArray*)d volume:(NSData*)v;
- (void) horosTearDown;
#else
- (id) initWithPix:(NSMutableArray*)f withFiles:(NSMutableArray*)d withVolume:(NSData*)v;
#endif
- (void) viewerControllerInit;
- (void) comparativeRefresh:(NSString*) patientUID;
- (void) CloseViewerNotification:(NSNotification*) note;
- (void) updateImageView:(NSNotification*) note;
- (void) sendWillFreeVolumeDataNotificationWithVolumeData:(NSData*) volumeData movieIndex:(NSInteger) movieIndex;
- (void) sendDidAllocateVolumeDataNotificationWithVolumeData:(NSData*) volumeData movieIndex:(NSInteger) movieIndex;
+ (ToolMode) getToolEquivalentToHotKey:(int) h;
+ (int) getHotKeyEquivalentToTool:(ToolMode) h;
@end

// The accessors of ViewerController (SwiftIvars) the Swift reads.
@interface ViewerController (SwiftIvars)
IVAR_ACCESSORS
@end

@interface NSString (Truncate)
- (NSString *)stringWithTruncatingToLength:(unsigned)length;
- (NSString *)stringTruncatedToLength:(unsigned int)length direction:(unsigned)truncateFrom;
- (NSString *)stringTruncatedToLength:(unsigned int)length direction:(unsigned)truncateFrom withEllipsisString:(NSString *)ellipsis;
@end

extern int harnessNumberOf2DViewers;
extern BOOL harnessCanDisplay12Bit;
extern NSMutableArray *harnessDisplayedViewers;
'''.replace('IVAR_ACCESSORS', DECLARED).replace('IVAR_BLOCK', ivar_block())

STUBS = r'''#import "Harness.h"
#import <objc/runtime.h>

static NSMapTable *names;

void Register(id object, NSString *name) {
    if (!names) names = [[NSMapTable mapTableWithKeyOptions: NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsStrongMemory
                                                valueOptions: NSPointerFunctionsStrongMemory] retain];
    [names setObject: name forKey: object];
}

// The viewers are named without being retained: they must be able to go.
static NSMapTable *viewerNames;

void RegisterViewer(id object, NSString *name) {
    if (!viewerNames) viewerNames = [[NSMapTable mapTableWithKeyOptions: NSPointerFunctionsOpaquePersonality | NSPointerFunctionsOpaqueMemory
                                                      valueOptions: NSPointerFunctionsStrongMemory] retain];
    [viewerNames setObject: name forKey: object];
}

BOOL Registered(id object) { return object && ([names objectForKey: object] != nil || [viewerNames objectForKey: object] != nil); }

/// The retain count of an object whose count means something (not a string,
/// number or date, which constants and tagged pointers make arbitrary).
unsigned long Rc(id o) {
    if (!o || [o isKindOfClass: [NSString class]] || [o isKindOfClass: [NSNumber class]] || [o isKindOfClass: [NSDate class]]) return 0;
    return [o retainCount];
}

NSString *Name(id object) {
    if (object == nil) return @"nil";
    NSString *name = [viewerNames objectForKey: object] ?: [names objectForKey: object];
    if (name) return name;
    if ([object isKindOfClass: [NSString class]]) return [NSString stringWithFormat: @"\"%@\"", object];
    if ([object isKindOfClass: [NSNumber class]]) return [object stringValue];
    if ([object isKindOfClass: [NSDate class]]) return [NSString stringWithFormat: @"date %a", [object timeIntervalSinceReferenceDate]];
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

#ifdef HARNESS_SWIFT
// ViewerController+CAPI.m defines it in the app.
BOOL SyncButtonBehaviorIsBetweenStudies = NO;
static BOOL harnessSYNCSERIES, harnessInverted;
#endif
ThumbnailsListPanel *thumbnailsListPanel[MAXSCREENS];
ThumbnailsListPanel *AppControllerCAPIThumbnailsListPanel(NSInteger index) { return index >= 0 && index < MAXSCREENS ? thumbnailsListPanel[index] : nil; }

int harnessNumberOf2DViewers = 1;
BOOL harnessCanDisplay12Bit = NO;
NSMutableArray *harnessDisplayedViewers;

static NSString *R(NSRect r) { return [NSString stringWithFormat: @"%a %a %a %a", r.origin.x, r.origin.y, r.size.width, r.size.height]; }

// The notification centre and the run loop's performs, recorded for the
// harness's objects.
static void (*addObserverIMP)(id, SEL, id, SEL, NSNotificationName, id);
static void (*removeObserverIMP)(id, SEL, id);
static void (*postIMP)(id, SEL, NSNotification*);
static void (*cancelIMP)(id, SEL, id);
static void (*cancelSelectorIMP)(id, SEL, id, SEL, id);

static void HarnessAddObserver(id self, SEL _cmd, id observer, SEL selector, NSNotificationName name, id object) {
    if (Registered(observer)) Record([NSString stringWithFormat: @"observe %@ %@ -> %@ object %@", Name(observer), name, NSStringFromSelector(selector), Name(object)]);
    addObserverIMP(self, _cmd, observer, selector, name, object);
}
static void HarnessRemoveObserver(id self, SEL _cmd, id observer) {
    if (Registered(observer)) Record([NSString stringWithFormat: @"remove observer %@", Name(observer)]);
    removeObserverIMP(self, _cmd, observer);
}
static void HarnessPost(id self, SEL _cmd, NSNotification *note) {
    if (Registered(note.object) || [note.name hasPrefix: @"Osirix"] || [note.name rangeOfString: @"Menu"].location != NSNotFound
        || [note.name hasPrefix: @"Default"] || [note.name hasPrefix: @"Horos"])
        Record([NSString stringWithFormat: @"post %@ object %@ userInfo %@", note.name, Name(note.object), Name(note.userInfo)]);
    postIMP(self, _cmd, note);
}
static void HarnessCancel(id self, SEL _cmd, id target) {
    if (Registered(target)) Record([NSString stringWithFormat: @"cancel performs of %@", Name(target)]);
    cancelIMP(self, _cmd, target);
}
static void HarnessCancelSelector(id self, SEL _cmd, id target, SEL selector, id object) {
    if (Registered(target)) Record([NSString stringWithFormat: @"cancel %@ of %@ with %@", NSStringFromSelector(selector), Name(target), Name(object)]);
    cancelSelectorIMP(self, _cmd, target, selector, object);
}

static HarnessDefaults *harnessDefaults;
static HarnessDefaults *HarnessStandardDefaults(id self, SEL _cmd) { return harnessDefaults; }

void HarnessInstall(void) {
    Class center = [NSNotificationCenter class];
    Method m = class_getInstanceMethod(center, @selector(addObserver:selector:name:object:));
    addObserverIMP = (void *)method_setImplementation(m, (IMP)HarnessAddObserver);
    m = class_getInstanceMethod(center, @selector(removeObserver:));
    removeObserverIMP = (void *)method_setImplementation(m, (IMP)HarnessRemoveObserver);
    m = class_getInstanceMethod(center, @selector(postNotification:));
    postIMP = (void *)method_setImplementation(m, (IMP)HarnessPost);
    Class meta = object_getClass([NSObject class]);
    m = class_getInstanceMethod(meta, @selector(cancelPreviousPerformRequestsWithTarget:));
    cancelIMP = (void *)method_setImplementation(m, (IMP)HarnessCancel);
    m = class_getInstanceMethod(meta, @selector(cancelPreviousPerformRequestsWithTarget:selector:object:));
    cancelSelectorIMP = (void *)method_setImplementation(m, (IMP)HarnessCancelSelector);
    harnessDefaults = [[HarnessDefaults alloc] initWithSuiteName: @"harness.viewer.controller.equivalence"];
    harnessDefaults.values = [NSMutableDictionary dictionary];
    method_setImplementation(class_getClassMethod([NSUserDefaults class], @selector(standardUserDefaults)), (IMP)HarnessStandardDefaults);
}

@implementation HarnessDefaults
- (id) objectForKey:(NSString*) key { return [self.values objectForKey: key]; }
- (void) setObject:(id) value forKey:(NSString*) key {
    Record([NSString stringWithFormat: @"defaults set %@ = %@", key, Name(value)]);
    if (value) [self.values setObject: value forKey: key]; else [self.values removeObjectForKey: key];
}
- (void) removeObjectForKey:(NSString*) key { [self setObject: nil forKey: key]; }
- (BOOL) boolForKey:(NSString*) key { return [[self.values objectForKey: key] boolValue]; }
- (NSInteger) integerForKey:(NSString*) key { return [[self.values objectForKey: key] integerValue]; }
- (NSString*) stringForKey:(NSString*) key { id v = [self.values objectForKey: key]; return [v isKindOfClass: [NSString class]] ? v : nil; }
- (NSDictionary*) persistentDomainForName:(NSString*) name { return [self.values objectForKey: [@"domain " stringByAppendingString: name]]; }
- (void) addObserver:(NSObject*) observer forKeyPath:(NSString*) keyPath options:(NSKeyValueObservingOptions) options context:(void*) context {
    Record([NSString stringWithFormat: @"defaults observed by %@ for %@ options %lu", Name(observer), keyPath, (unsigned long)options]);
}
- (void) removeObserver:(NSObject*) observer forKeyPath:(NSString*) keyPath {
    Record([NSString stringWithFormat: @"defaults no longer observed by %@ for %@", Name(observer), keyPath]);
    if ([[self.values objectForKey: @"harness raise on removal"] boolValue]) [NSException raise: NSRangeException format: @"not an observer"];
}
@end

@implementation HarnessWindow
- (void) zoom:(id) sender { Record([NSString stringWithFormat: @"%@ zoom %@", Name(self), Name(sender)]); }
- (void) center { Record([NSString stringWithFormat: @"%@ center", Name(self)]); }
- (void) setDelegate:(id) delegate { Record([NSString stringWithFormat: @"%@ delegate %@", Name(self), Name(delegate)]); }
- (void) registerForDraggedTypes:(NSArray*) types { Record([NSString stringWithFormat: @"%@ dragged types %@", Name(self), Name(types)]); }
- (void) setInitialFirstResponder:(NSView*) view { Record([NSString stringWithFormat: @"%@ first responder %@", Name(self), Name(view)]); }
- (id) windowController { return self.harnessController; }
- (NSToolbar*) toolbar { return self.harnessToolbar; }
- (void) setToolbar:(NSToolbar*) toolbar { Record([NSString stringWithFormat: @"%@ toolbar %@", Name(self), Name(toolbar)]); self.harnessToolbar = toolbar; }
- (BOOL) isMainWindow { return self.harnessMain; }
- (BOOL) isKeyWindow { return self.harnessKey; }
@end

@implementation HarnessApplication
- (NSArray*) windows { return self.harnessWindows ?: @[]; }
@end

@implementation NSImage (HarnessToolbar)
+ (NSImage*) toolbarImageNamed:(NSString*) name {
    NSImage *image = [[[NSImage alloc] initWithSize: NSMakeSize(16, 16)] autorelease];
    Register(image, [@"toolbar image " stringByAppendingString: name]);
    return image;
}
@end

@implementation DicomDatabase
+ (DicomDatabase*) databaseForContext:(NSManagedObjectContext*) c {
    DicomDatabase *db = [[DicomDatabase new] autorelease];
    Register(db, [NSString stringWithFormat: @"database of %@", Name(c)]);
    return db;
}
@end

@implementation DicomStudy
@end
@implementation DicomSeries
@end
@implementation DicomImage
- (NSString*) sopInstanceUID { return self.harnessSOP; }
@end
@implementation DCMPix
@end
@implementation ROI
+ (void) loadDefaultSettings { Record(@"ROI loadDefaultSettings"); }
@end

@implementation DCMView
+ (NSArray*) PasteboardTypes { return @[@"dcm pasteboard"]; }
+ (NSArray*) PluginPasteboardTypes { return @[@"plugin pasteboard"]; }
- (NSInteger) curImage { return self.harnessCurImage; }
- (BOOL) mouseDragging { return self.harnessDragging; }
- (NSWindow*) window { return self.harnessWindow; }
- (void) setDrawing:(BOOL) d { Record([NSString stringWithFormat: @"%@ drawing %d", Name(self), d]); _drawing = d; }
- (void) setSyncRelativeDiff:(float) d { Record([NSString stringWithFormat: @"%@ syncRelativeDiff %a", Name(self), d]); _syncRelativeDiff = d; }
- (void) setSyncSeriesIndex:(long) i { Record([NSString stringWithFormat: @"%@ syncSeriesIndex %ld", Name(self), i]); _syncSeriesIndex = i; }
- (void) setIndex:(NSInteger) index { Record([NSString stringWithFormat: @"%@ setIndex %ld", Name(self), (long)index]); self.harnessCurImage = index; }
- (void) updateTilingViews { Record([NSString stringWithFormat: @"%@ updateTilingViews", Name(self)]); }
- (void) setIsLUT12Bit:(BOOL) b { Record([NSString stringWithFormat: @"%@ isLUT12Bit %d", Name(self), b]); }
@end

@implementation SeriesView
- (void) setPixels:(NSMutableArray*)pixels files:(NSMutableArray*)files rois:(NSMutableArray*)rois firstImage:(NSInteger)firstImage level:(char)level reset:(BOOL)reset {
    Record([NSString stringWithFormat: @"%@ setPixels %@ files %@ rois %@ first %ld level %c reset %d", Name(self), Name(pixels), Name(files), Name(rois), (long)firstImage, level, reset]);
}
@end

@implementation ThumbnailsListPanel
- (void) thumbnailsListWillClose:(NSView*) view { Record([NSString stringWithFormat: @"%@ thumbnailsListWillClose %@", Name(self), Name(view)]); }
@end

@implementation ToolbarPanelController
- (instancetype) initForViewer:(ViewerController*) v withToolbar:(NSToolbar*) t {
    self = [super init];
    Record([NSString stringWithFormat: @"toolbar panel for %@ with %@", Name(v), Name(t)]);
    Register(self, @"toolbarPanel");
    return self;
}
- (void) dealloc { Record(@"toolbar panel dealloc"); [super dealloc]; }
@end

@implementation DICOMExport
@end

@implementation AppController
static BOOL useToolbarPanel;
+ (BOOL) canDisplay12Bit { return harnessCanDisplay12Bit; }
+ (BOOL) USETOOLBARPANEL { return useToolbarPanel; }
+ (void) setUSETOOLBARPANEL:(BOOL) b { Record([NSString stringWithFormat: @"USETOOLBARPANEL %d", b]); useToolbarPanel = b; }
@end

@implementation OSIEnvironment
+ (OSIEnvironment*) sharedEnvironment {
    static OSIEnvironment *environment;
    if (!environment) { environment = [OSIEnvironment new]; Register(environment, @"environment"); }
    return environment;
}
- (void) addViewerController:(ViewerController*) viewer { Record([NSString stringWithFormat: @"environment add %@", Name(viewer)]); }
@end

@implementation BrowserController
+ (BrowserController*) currentBrowser {
    static BrowserController *browser;
    if (!browser) { browser = [BrowserController new]; Register(browser, @"browser"); }
    return browser;
}
+ (NSArray*) DatabaseObjectXIDsPasteboardTypes { return @[@"xid pasteboard"]; }
- (NSArray*) childrenArray:(id) item { Record([NSString stringWithFormat: @"childrenArray %@", Name(item)]); return @[Name(item)]; }
- (ViewerController*) openViewerFromImages:(NSArray*) toOpenArray movie:(BOOL) movieViewer viewer:(ViewerController*) viewer keyImagesOnly:(BOOL) keyImages tryToFlipData:(BOOL) tryToFlipData {
    Record([NSString stringWithFormat: @"openViewerFromImages %@ movie %d viewer %@ key %d flip %d", Name(toOpenArray), movieViewer, Name(viewer), keyImages, tryToFlipData]);
    // The reload reorders the series: the image shown moves.
    NSMutableArray *files = viewer->fileList[viewer->curMovieIndex];
    if (files.count > 1) [files exchangeObjectAtIndex: 0 withObjectAtIndex: files.count - 1];
    return viewer;
}
- (void) showDatabase:(id) sender { Record([NSString stringWithFormat: @"showDatabase %@", Name(sender)]); }
@end

@implementation HorosExcludedSeries
+ (NSNotificationName) didChangeNotification { return @"HorosExcludedSeriesDidChange"; }
@end
@implementation HorosSeriesListIdentification
+ (NSString*) defaultsKey { return @"SeriesListIdentificationMode"; }
@end
@implementation HorosSeriesListLayout
+ (NSString*) placementDidChangeNotification { return @"HorosSeriesListPlacementDidChange"; }
@end

@implementation HorosRefreshCoalescer
- (NSTimeInterval) requestAt:(NSTimeInterval) now { Record([NSString stringWithFormat: @"coalescer request -> %a", self.harnessWait]); return self.harnessWait; }
- (void) appliedAt:(NSTimeInterval) now { Record(@"coalescer applied"); }
@end

@implementation HorosRetrieveViewing
+ (HorosRetrieveViewing*) shared {
    static HorosRetrieveViewing *shared;
    if (!shared) { shared = [HorosRetrieveViewing new]; Register(shared, @"retrieveViewing"); }
    return shared;
}
+ (NSInteger) indexOfSOPInstanceUID:(NSString*) sop frame:(NSInteger) frame inSOPInstanceUIDs:(NSArray<NSString*>*) sops frames:(NSArray<NSNumber*>*) frames fallback:(NSInteger) fallback {
    Record([NSString stringWithFormat: @"index of %@ frame %ld in %@ frames %@ fallback %ld", sop, (long)frame, Name(sops), Name(frames), (long)fallback]);
    NSUInteger i = [sops indexOfObject: sop];
    return i == NSNotFound ? fallback : (NSInteger)i;
}
- (void) localCountChangedForStudyUID:(NSString*) study seriesUID:(NSString*) series localCount:(NSInteger) count {
    Record([NSString stringWithFormat: @"local count %@ %@ %ld", study, series, (long)count]);
}
+ (NSInteger) uniqueInstanceCountOfImages:(NSArray<NSObject*>*) images { return images.count * 10 + 1; }
@end

@implementation HarnessSeriesLoad
- (void) cancel { Record(@"series load cancel"); }
@end

@implementation OSIWindowController
@synthesize database = _database;
- (instancetype) initWithWindowNibName:(NSString*) name {
    if (![name isEqualToString: @"Viewer"]) Record([NSString stringWithFormat: @"nib %@", name]);
    return [super initWithWindow: nil];
}
- (void) setDatabase:(DicomDatabase*) database { Record([NSString stringWithFormat: @"database %@", Name(database)]); [database retain]; [_database release]; _database = database; }
- (void) setMagnetic:(BOOL) a { Record([NSString stringWithFormat: @"magnetic %d", a]); }
- (void) refreshDatabase:(NSArray*) newImages { Record([NSString stringWithFormat: @"OSIWindowController refreshDatabase %@", Name(newImages)]); }
- (void) ApplyCLUTString:(NSString*) str { Record([NSString stringWithFormat: @"ApplyCLUTString %@", Name(str)]); }
- (void) ApplyOpacityString:(NSString*) str { Record([NSString stringWithFormat: @"ApplyOpacityString %@", Name(str)]); }
- (void) dealloc { Record(@"OSIWindowController dealloc"); [_database release]; [super dealloc]; }
@end

@implementation ViewerController
@synthesize injectionDateTime, windowsStateName, flagListPODComparatives, blendedWindow, toolbarPanel;
- (void) setWindowsStateName:(NSString*) name { Record([NSString stringWithFormat: @"windowsStateName %@", Name(name)]); [name retain]; [windowsStateName release]; windowsStateName = name; }
- (void) setFlagListPODComparatives:(NSNumber*) value { Record([NSString stringWithFormat: @"flagListPODComparatives %@", Name(value)]); [value retain]; [flagListPODComparatives release]; flagListPODComparatives = value; }
- (void) setBlendedWindow:(ViewerController*) value { Record([NSString stringWithFormat: @"blendedWindow %@", Name(value)]); [value retain]; [blendedWindow release]; blendedWindow = value; }
- (void) setInjectionDateTime:(NSDate*) value { Record([NSString stringWithFormat: @"injectionDateTime %@", Name(value)]); [value retain]; [injectionDateTime release]; injectionDateTime = value; }
- (NSWindow*) window {
    if (!harnessWindow) {
        harnessWindow = [[HarnessWindow alloc] initWithContentRect: NSMakeRect(0, 0, 400, 300) styleMask: NSWindowStyleMaskTitled backing: NSBackingStoreBuffered defer: YES];
        harnessWindow.releasedWhenClosed = NO;
        ((HarnessWindow*)harnessWindow).harnessController = self;
        Register(harnessWindow, [Name(self) stringByAppendingString: @".window"]);
        Record([NSString stringWithFormat: @"%@ window loaded", Name(self)]);
    }
    return harnessWindow;
}
- (HarnessSeriesLoad*) horosSeriesLoad { return harnessSeriesLoad; }
- (BOOL) horosViewerPanelsLoaded { return harnessPanelsLoaded; }
+ (void) horos_register2DViewer:(ViewerController*) viewer { Record([NSString stringWithFormat: @"register %@", Name(viewer)]); }
+ (int) numberOf2DViewer { return harnessNumberOf2DViewers; }
+ (NSMutableArray*) getDisplayed2DViewers { return harnessDisplayedViewers; }
+ (void) clearFrontMost2DViewerCache { Record(@"clearFrontMost2DViewerCache"); }
- (DCMView*) imageView { return imageView; }
- (NSString*) studyInstanceUID { return harnessStudyUID; }
- (NSString*) modality { return harnessModality; }
- (DicomStudy*) currentStudy { return harnessStudy; }
- (DicomSeries*) currentSeries { return harnessSeries; }
- (void) setupToolbar { Record([NSString stringWithFormat: @"%@ setupToolbar", Name(self)]); }
- (void) changeImageData:(NSMutableArray*)f :(NSMutableArray*)d :(NSObject*)v :(BOOL)newViewerWindow {
    Record([NSString stringWithFormat: @"%@ changeImageData %@ %@ %@ %d", Name(self), Name(f), Name(d), Name(v), newViewerWindow]);
    [f retain]; [pixList[0] release]; pixList[0] = f;
    [d retain]; [fileList[0] release]; fileList[0] = d;
    [roiList[0] release]; roiList[0] = [[NSMutableArray alloc] init];
    Register(roiList[0], [Name(self) stringByAppendingString: @".rois"]);
    volumeData[0] = (NSData*)v;
}
- (void) SetSyncButtonBehavior:(id) sender { Record([NSString stringWithFormat: @"%@ SetSyncButtonBehavior %@", Name(self), Name(sender)]); }
- (void) turnOffSyncSeriesBetweenStudies:(id) sender { Record([NSString stringWithFormat: @"%@ turnOffSyncSeriesBetweenStudies %@", Name(self), Name(sender)]); }
- (id) findSyncSeriesButton { return harnessSyncButton; }
- (void) blendWindows:(id) sender { Record([NSString stringWithFormat: @"%@ blendWindows %@", Name(self), Name(sender)]); }
- (void) verify12Bit:(NSTimer*) timer { Record(@"verify12Bit"); }
- (NSImage*) imageForROI:(ToolMode) i {
    NSImage *image = [[[NSImage alloc] initWithSize: NSMakeSize(40, 40)] autorelease];
    Register(image, [NSString stringWithFormat: @"roi image %d", i]);
    return image;
}
- (void) setMatrixVisible:(BOOL) visible { Record([NSString stringWithFormat: @"%@ setMatrixVisible %d", Name(self), visible]); }
- (void) updateSeriesListMode { Record([NSString stringWithFormat: @"%@ updateSeriesListMode", Name(self)]); }
- (void) observeScrollerStyleDidChangeNotification:(NSNotification*) n { Record([NSString stringWithFormat: @"%@ observeScrollerStyle %@", Name(self), Name(n)]); }
- (void) discardPrintSpoolDirectory { Record([NSString stringWithFormat: @"%@ discardPrintSpoolDirectory", Name(self)]); }
- (void) ActivateBlending:(ViewerController*) bC { Record([NSString stringWithFormat: @"%@ ActivateBlending %@", Name(self), Name(bC)]); }
- (void) buildMatrixPreview:(BOOL) showSelected {
    Record([NSString stringWithFormat: @"%@ buildMatrixPreview %d", Name(self), showSelected]);
    if (harnessRecurse) { harnessRecurse = NO; [self refreshDatabase: nil]; }
    if (harnessRaise) { harnessRaise = NO; [NSException raise: NSInternalInconsistencyException format: @"list failed"]; }
}
- (HorosRefreshCoalescer*) horosRefreshCoalescer { return harnessCoalescer; }
- (void) adjustSlider { Record([NSString stringWithFormat: @"%@ adjustSlider", Name(self)]); }
- (void) refreshToolbar { Record([NSString stringWithFormat: @"%@ refreshToolbar", Name(self)]); }
- (void) performSelector:(SEL) selector withObject:(id) object afterDelay:(NSTimeInterval) delay {
    Record([NSString stringWithFormat: @"%@ perform %@ with %@ after %a", Name(self), NSStringFromSelector(selector), Name(object), delay]);
}
- (void) bind:(NSBindingName) binding toObject:(id) observable withKeyPath:(NSString*) keyPath options:(NSDictionary*) options {
    Record([NSString stringWithFormat: @"%@ bind %@ to %@ %@", Name(self), binding, NSStringFromClass([observable class]), keyPath]);
}
- (void) unbind:(NSBindingName) binding { Record([NSString stringWithFormat: @"%@ unbind %@", Name(self), binding]); }
#define HANDLER(handled) - (void) handled:(NSNotification*) n { if (n.object == nil || Registered(n.object)) Record([NSString stringWithFormat: @"%@ " #handled " %@ %@", Name(self), n.name, Name(n.object)]); }
HANDLER(applicationDidResignActive)
HANDLER(UpdateWLWWMenu)
HANDLER(ViewFrameDidChange)
HANDLER(ViewBoundsDidChange)
HANDLER(revertSeriesNotification)
HANDLER(updateVolumeData)
HANDLER(retrieveViewingStateChanged)
HANDLER(excludedSeriesDidChange)
HANDLER(roiChange)
HANDLER(OpacityChanged)
HANDLER(defaultToolModified)
HANDLER(defaultRightToolModified)
HANDLER(defaultMiddleToolModified)
HANDLER(UpdateConvolutionMenu)
HANDLER(CLUTChanged)
HANDLER(UpdateCLUTMenu)
HANDLER(UpdateOpacityMenu)
HANDLER(recomputeROI)
HANDLER(notificationStopPlaying)
HANDLER(notificationSyncSeries)
HANDLER(exportTextFieldDidChange)
HANDLER(updateReportToolbarIcon)
HANDLER(reportToolbarItemWillPopUp)
#ifdef HARNESS_SWIFT
// The class's statics (ViewerController.swift in the app) and what deinit runs.
+ (BOOL) horos_SYNCSERIES { return harnessSYNCSERIES; }
+ (void) horos_setSYNCSERIES:(BOOL) value { harnessSYNCSERIES = value; }
+ (BOOL) horos_DisplayUseInvertedPolarity { return harnessInverted; }
+ (void) horos_setDisplayUseInvertedPolarity:(BOOL) value { harnessInverted = value; }
- (void) dealloc {
    [self horosTearDown];
    [super dealloc];
}
#endif
@end

@implementation ViewerController (SwiftIvars)
IVAR_IMPLEMENTATIONS
@end
'''.replace('IVAR_IMPLEMENTATIONS', IMPLEMENTED)

DRIVER = r'''#import "Harness.h"
#import <objc/runtime.h>

void HarnessInstall(void);

static HarnessApplication *app;
static NSMutableArray *keep;

static NSMutableDictionary *Values(void) { return ((HarnessDefaults*)[NSUserDefaults standardUserDefaults]).values; }

static id Keep(id object, NSString *name) {
    [keep addObject: object];
    Register(object, name);
    return object;
}

static NSPopUpButton *Popup(NSString *name, NSArray *items) {
    NSPopUpButton *popup = Keep([[[NSPopUpButton alloc] initWithFrame: NSMakeRect(0, 0, 100, 20) pullsDown: NO] autorelease], name);
    for (NSArray *item in items) {
        [popup addItemWithTitle: item[0]];
        popup.lastItem.tag = [item[1] integerValue];
        if (item.count > 2) { NSImage *image = Keep([[[NSImage alloc] initWithSize: NSMakeSize(8, 8)] autorelease], item[2]); popup.lastItem.image = image; }
    }
    return popup;
}

static NSString *ItemsOf(NSPopUpButton *popup) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSMenuItem *item in popup.itemArray)
        [parts addObject: [NSString stringWithFormat: @"%@/%ld/%@/%@", item.title, (long)item.tag, Name(item.image), item.image ? NSStringFromSize(item.image.size) : @"-"]];
    return [NSString stringWithFormat: @"%@ selected %ld title %@", [parts componentsJoinedByString: @" "], (long)popup.indexOfSelectedItem, popup.titleOfSelectedItem];
}

static void Dump(ViewerController *v, NSString *when) {
    Record([NSString stringWithFormat: @"-- state %@", when]);
DUMP_LINES
    Record([NSString stringWithFormat: @"  windowsStateName %@ flagListPOD %@ injection %@ blended %@ toolbarPanel %@", Name(v.windowsStateName), Name(v.flagListPODComparatives), Name(v.injectionDateTime), Name(v.blendedWindow), Name(v.toolbarPanel)]);
    Record([NSString stringWithFormat: @"  pix %@ files %@ rois %@", Name(v->pixList[0]), Name(v->fileList[0]), Name(v->roiList[0])]);
    Record([NSString stringWithFormat: @"  inverted %d SYNCSERIES %d", [ViewerController horos_DisplayUseInvertedPolarity], [ViewerController horos_SYNCSERIES]]);
    if (v->t12BitTimer) Record([NSString stringWithFormat: @"  timer interval %a repeats %d target %@ selector %@", v->t12BitTimer.timeInterval, ![v->t12BitTimer isKindOfClass: [NSNull class]],
                                  Name([v->t12BitTimer.userInfo self]), @"-"]);
    if (v->wlwwPopup) Record([@"  wlwwPopup " stringByAppendingString: ItemsOf(v->wlwwPopup)]);
    if (v->convPopup) Record([@"  convPopup " stringByAppendingString: ItemsOf(v->convPopup)]);
    if (v->OpacityPopup) Record([NSString stringWithFormat: @"  OpacityPopup enabled %d", v->OpacityPopup.enabled]);
    if (v->popupRoi) Record([@"  popupRoi " stringByAppendingString: ItemsOf(v->popupRoi)]);
    if (v->ReconstructionRoi) Record([@"  ReconstructionRoi " stringByAppendingString: ItemsOf(v->ReconstructionRoi)]);
    if (v->StatusPopup) Record([@"  StatusPopup " stringByAppendingString: ItemsOf(v->StatusPopup)]);
    if (v->CommentsField) Record([NSString stringWithFormat: @"  CommentsField %@", v->CommentsField.title]);
    if (v->display12bitToolbarItemMatrix) Record([NSString stringWithFormat: @"  12bit matrix selected %ld", (long)v->display12bitToolbarItemMatrix.selectedTag]);
    if (v->orientationMatrix) Record([NSString stringWithFormat: @"  orientationMatrix enabled %d", v->orientationMatrix.enabled]);
    if (v->previewMatrixScrollView) Record([NSString stringWithFormat: @"  scroll view posts frame %d", v->previewMatrixScrollView.postsFrameChangedNotifications]);
    for (NSControl *c in @[v->speedSlider ?: (id)[NSNull null], v->speedText ?: (id)[NSNull null], v->movieRateSlider ?: (id)[NSNull null], v->movieTextSlide ?: (id)[NSNull null], v->moviePlayStop ?: (id)[NSNull null], v->moviePosSlider ?: (id)[NSNull null]]) {
        if ([c isKindOfClass: [NSNull class]]) continue;
        Record([NSString stringWithFormat: @"  %@ label %@ help %@ tip %@", Name(c), c.accessibilityLabel, c.accessibilityHelp, c.toolTip]);
    }
    if (v->splitView) {
        NSMutableArray *subs = [NSMutableArray array];
        for (NSView *s in v->splitView.subviews) [subs addObject: [NSString stringWithFormat: @"%@ %@", Name(s), NSStringFromRect(s.frame)]];
        Record([NSString stringWithFormat: @"  splitView vertical %d mask %lu delegate %@ tamic %d superview %@ subviews %@", v->splitView.vertical, (unsigned long)v->splitView.autoresizingMask,
                Name(v->splitView.delegate), v->splitView.translatesAutoresizingMaskIntoConstraints, Name(v->splitView.superview), subs]);
    }
    if (v->previewMatrix) Record([NSString stringWithFormat: @"  previewMatrix spacing %@ tamic %d", NSStringFromSize(v->previewMatrix.intercellSpacing), v->previewMatrix.translatesAutoresizingMaskIntoConstraints]);
    if (v->comparativesButton) Record([NSString stringWithFormat: @"  comparativesButton frame %@", NSStringFromRect(v->comparativesButton.frame)]);
}

/// A viewer as the browser opens it: its outlets as the nib connects them
/// (not retained), its views, its window's other viewers.
static ViewerController *MakeViewer(NSString *name, NSDictionary *options) {
    ViewerController *v = [ViewerController alloc];
    RegisterViewer(v, name);
    v->harnessStudyUID = [options[@"study"] ?: @"1.2.3" retain];
    v->harnessModality = [options[@"modality"] ?: @"CT" retain];
    v->harnessSeriesLoad = [HarnessSeriesLoad new];
    Register(v->harnessSeriesLoad, [name stringByAppendingString: @".seriesLoad"]);
    if (options[@"coalescer"]) { v->harnessCoalescer = [HorosRefreshCoalescer new]; v->harnessCoalescer.harnessWait = [options[@"coalescer"] doubleValue]; Register(v->harnessCoalescer, @"coalescer"); }
    if (![options[@"noButton"] boolValue]) { v->harnessSyncButton = [[NSToolbarItem alloc] initWithItemIdentifier: @"Sync"]; Register(v->harnessSyncButton, [name stringByAppendingString: @".syncButton"]); }
    return v;
}

static void Outlets(ViewerController *v, NSString *name, NSDictionary *options) {
    v->wlwwPopup = Popup([name stringByAppendingString: @".wlwwPopup"], @[@[@"x", @0]]);
    v->convPopup = Popup([name stringByAppendingString: @".convPopup"], @[@[@"y", @0]]);
    v->OpacityPopup = Popup([name stringByAppendingString: @".OpacityPopup"], @[]);
    v->OpacityPopup.enabled = NO;
    v->popupRoi = Popup([name stringByAppendingString: @".popupRoi"], @[@[@"Length", @5], @[@"Oval", @9, @"oval image"], @[@"Text", @13]]);
    v->ReconstructionRoi = Popup([name stringByAppendingString: @".ReconstructionRoi"], @[@[@"MPR", @1], @[@"3D MPR", @2, @"kept image"], @[@"MIP", @3], @[@"VR", @4],
        @[@"SR", @5], @[@"VRPRO", @7], @[@"VR2", @6], @[@"Ortho", @8], @[@"Endo", @9], @[@"CPR", @10], @[@"other", @11]]);
    v->StatusPopup = Popup([name stringByAppendingString: @".StatusPopup"], @[@[@"empty", @0], @[@"unread", @1], @[@"read", @3]]);
    v->CommentsField = Keep([[[NSButton alloc] initWithFrame: NSZeroRect] autorelease], [name stringByAppendingString: @".CommentsField"]);
    v->display12bitToolbarItemMatrix = Keep([[[NSMatrix alloc] initWithFrame: NSMakeRect(0, 0, 40, 20) mode: NSRadioModeMatrix cellClass: [NSButtonCell class] numberOfRows: 1 numberOfColumns: 2] autorelease],
                                           [name stringByAppendingString: @".12bit"]);
    [[v->display12bitToolbarItemMatrix cellAtRow: 0 column: 0] setTag: 0];
    [[v->display12bitToolbarItemMatrix cellAtRow: 0 column: 1] setTag: 1];
    [v->display12bitToolbarItemMatrix selectCellWithTag: 1];
    v->orientationMatrix = Keep([[[NSMatrix alloc] initWithFrame: NSZeroRect] autorelease], [name stringByAppendingString: @".orientationMatrix"]);
    v->previewMatrixScrollView = Keep([[[NSScrollView alloc] initWithFrame: NSMakeRect(0, 0, 60, 200)] autorelease], [name stringByAppendingString: @".scrollView"]);
    v->speedSlider = Keep([[[NSSlider alloc] initWithFrame: NSZeroRect] autorelease], [name stringByAppendingString: @".speedSlider"]);
    v->speedText = Keep([[[NSTextField alloc] initWithFrame: NSZeroRect] autorelease], [name stringByAppendingString: @".speedText"]);
    v->movieRateSlider = Keep([[[NSSlider alloc] initWithFrame: NSZeroRect] autorelease], [name stringByAppendingString: @".movieRateSlider"]);
    v->movieTextSlide = Keep([[[NSTextField alloc] initWithFrame: NSZeroRect] autorelease], [name stringByAppendingString: @".movieTextSlide"]);
    v->moviePlayStop = Keep([[[NSButton alloc] initWithFrame: NSZeroRect] autorelease], [name stringByAppendingString: @".moviePlayStop"]);
    v->moviePosSlider = Keep([[[NSSlider alloc] initWithFrame: NSZeroRect] autorelease], [name stringByAppendingString: @".moviePosSlider"]);
    if (![options[@"noSplitView"] boolValue]) v->splitView = Keep([[[NSSplitView alloc] initWithFrame: NSMakeRect(0, 0, 400, 300)] autorelease], [name stringByAppendingString: @".splitView"]);
    v->previewMatrix = Keep([[[NSMatrix alloc] initWithFrame: NSZeroRect] autorelease], [name stringByAppendingString: @".previewMatrix"]);
    v->comparativesButton = Keep([[[NSButton alloc] initWithFrame: NSMakeRect(10, 20, 80, 30)] autorelease], [name stringByAppendingString: @".comparativesButton"]);
}

/// The views -windowDidLoad gives the viewer: retained, as it retained them.
static void Views(ViewerController *v, NSString *name) {
    SeriesView *sv = Keep([[[SeriesView alloc] initWithFrame: NSZeroRect] autorelease], [name stringByAppendingString: @".seriesView"]);
    DCMView *iv = Keep([[[DCMView alloc] initWithFrame: NSZeroRect] autorelease], [name stringByAppendingString: @".imageView"]);
    iv.rows = 1; iv.columns = 1;
    iv.harnessWindow = [v window];
    iv.syncRelativeDiff = 0;
    v->seriesView = [sv retain];
    v->imageView = [iv retain];
}

static NSMutableArray *Series(NSString *name, NSUInteger count, DicomSeries *series, BOOL rgb) {
    NSMutableArray *pix = Keep([NSMutableArray array], [name stringByAppendingString: @".pix"]);
    NSMutableArray *files = Keep([NSMutableArray array], [name stringByAppendingString: @".files"]);
    for (NSUInteger i = 0; i < count; i++) {
        DCMPix *p = Keep([[DCMPix new] autorelease], [NSString stringWithFormat: @"%@.pix%lu", name, (unsigned long)i]);
        p.isRGB = rgb;
        [pix addObject: p];
        DicomImage *image = Keep([[DicomImage new] autorelease], [NSString stringWithFormat: @"%@.image%lu", name, (unsigned long)i]);
        image.series = series;
        image.harnessSOP = [NSString stringWithFormat: @"sop%lu", (unsigned long)i];
        image.frameID = @(i % 2);
        image.managedObjectContext = Keep([[[NSManagedObjectContext alloc] initWithConcurrencyType: NSMainQueueConcurrencyType] autorelease], [name stringByAppendingString: @".context"]);
        [files addObject: image];
    }
    [keep addObject: pix]; [keep addObject: files];
    return pix;
}

static DicomSeries *MakeSeries(NSString *name, NSString *patient, NSNumber *state, NSString *comment) {
    DicomStudy *study = Keep([[DicomStudy new] autorelease], [name stringByAppendingString: @".study"]);
    study.patientUID = patient;
    study.stateText = state;
    study.studyInstanceUID = [name stringByAppendingString: @"-study-uid"];
    study.date = [NSDate dateWithTimeIntervalSinceReferenceDate: 1000];
    DicomSeries *series = Keep([[DicomSeries new] autorelease], name);
    series.study = study;
    series.comment = comment;
    series.seriesDICOMUID = [name stringByAppendingString: @"-series-uid"];
    series.objectID = Keep([[NSObject new] autorelease], [name stringByAppendingString: @".objectID"]);
    return series;
}

/// A viewer opened with `options` (the defaults set first), its state
/// dumped; then closed (its timer invalidated, as -windowWillClose does) and
/// released, with what it held.
static ViewerController *Open(NSString *name, NSDictionary *defaults, NSDictionary *options) {
    for (NSString *key in defaults) [Values() setObject: defaults[key] forKey: key];
    Record([NSString stringWithFormat: @"=== open %@ %@ %@", name, Name(defaults), Name(options)]);
    DicomSeries *series = MakeSeries([name stringByAppendingString: @".series"], options[@"patient"] ?: @"P1", options[@"state"], options[@"comment"]);
    NSMutableArray *pix = Series(name, 3, series, [options[@"rgb"] boolValue]);
    NSMutableArray *files = [keep objectAtIndex: keep.count - 1];
    NSData *volume = Keep([NSData dataWithBytes: "abcd" length: 4], [name stringByAppendingString: @".volume"]);
    ViewerController *v = MakeViewer(name, options);
    // A viewer opened again over its own window is already among the
    // displayed ones: it must not take itself for the same study's viewer.
    if ([options[@"listedFirst"] boolValue]) [harnessDisplayedViewers insertObject: v atIndex: 0];
    @autoreleasepool {
    Outlets(v, name, options);
    // The window loads (-windowDidLoad gives the views) at the first -window.
    [v window];
    Views(v, name);
    if ([options[@"panels"] boolValue]) v->harnessPanelsLoaded = YES;
    // The files of a viewer the browser fills again: -viewerControllerInit
    // reads the status and comment of the shown image's series.
    if (![options[@"empty"] boolValue]) { v->fileList[0] = [files retain]; v->imageView.harnessCurImage = 1; }
#ifdef HARNESS_SWIFT
    v = [v initWithWindowNibName: @"Viewer"];
    [v horosFinishInitializationWithPix: pix files: files volume: volume];
#else
    v = [v initWithPix: pix withFiles: files withVolume: volume];
#endif
    }
    Dump(v, @"after init");
    return v;
}

static void Awake(ViewerController *v, NSString *name, BOOL withoutSplit) {
    Record([NSString stringWithFormat: @"=== awake %@", name]);
    if (withoutSplit) {
        NSView *content = [[v window] contentView];
        NSView *pane = Keep([[[NSView alloc] initWithFrame: NSMakeRect(0, 0, 300, 300)] autorelease], [name stringByAppendingString: @".imagePane"]);
        [content addSubview: pane];
        Register(content, [name stringByAppendingString: @".contentView"]);
    }
    @autoreleasepool { [v awakeFromNib]; }
    if (v->splitView && !Registered(v->splitView)) {
        Register(v->splitView, [name stringByAppendingString: @".madeSplitView"]);
        for (NSView *s in v->splitView.subviews) if (!Registered(s)) Register(s, [name stringByAppendingString: @".dockPane"]);
    }
    Dump(v, @"after awake");
}

static void Close(ViewerController *v, NSString *name) {
    Record([NSString stringWithFormat: @"=== close %@", name]);
    [v->t12BitTimer invalidate];
    // What the viewer held, kept to read its retain counts after.
    NSDictionary *roles = @{@"roiLock": v->roiLock ?: (id)[NSNull null], @"processorsLock": v->processorsLock ?: (id)[NSNull null],
                            @"undoQueue": v->undoQueue ?: (id)[NSNull null], @"redoQueue": v->redoQueue ?: (id)[NSNull null],
                            @"retainedToolbarItems": v->retainedToolbarItems ?: (id)[NSNull null], @"imageView": v->imageView ?: (id)[NSNull null],
                            @"seriesView": v->seriesView ?: (id)[NSNull null], @"splitView": v->splitView ?: (id)[NSNull null],
                            @"t12BitTimer": v->t12BitTimer ?: (id)[NSNull null], @"roiList": v->roiList[0] ?: (id)[NSNull null],
                            @"pixList": v->pixList[0] ?: (id)[NSNull null], @"fileList": v->fileList[0] ?: (id)[NSNull null]};
    NSMutableArray *held = [NSMutableArray array];
    for (NSString *role in [[roles allKeys] sortedArrayUsingSelector: @selector(compare:)]) {
        id o = roles[role];
        if ([o isKindOfClass: [NSNull class]]) continue;
        if (!Registered(o)) Register(o, [NSString stringWithFormat: @"%@.%@", name, role]);
        [held addObject: o];
    }
    NSMutableArray *counts = [NSMutableArray array];
    for (id o in held) [counts addObject: [NSString stringWithFormat: @"%@ %lu", Name(o), Rc(o)]];
    Record([NSString stringWithFormat: @"held before %@", [counts componentsJoinedByString: @", "]]);
    @autoreleasepool { [v release]; }
    [counts removeAllObjects];
    for (id o in held) [counts addObject: [NSString stringWithFormat: @"%@ %lu", Name(o), Rc(o)]];
    Record([NSString stringWithFormat: @"held after %@", [counts componentsJoinedByString: @", "]]);
}

static void Lifecycle(void) {
    NSScreen *screen = [NSScreen mainScreen];
    (void)screen;
    // A plain CT viewer, the only one.
    harnessNumberOf2DViewers = 1;
    harnessDisplayedViewers = [[NSMutableArray alloc] init];
    ViewerController *v1, *v2, *v3, *v4, *v5;
    HarnessWindow *other, *plain;
    // What AppKit retains and autoreleases (a notification's observers) is
    // given back before the viewers close.
    @autoreleasepool {
    v1 = Open(@"v1", @{@"SeriesListVisible": @YES}, @{@"state": @3, @"comment": @"A comment"});
    [harnessDisplayedViewers addObject: v1];
    Awake(v1, @"v1", NO);
    // ViewerPanels.nib's awakening does nothing more.
    v1->harnessPanelsLoaded = YES;
    [v1 awakeFromNib];
    v1->harnessPanelsLoaded = NO;
    Record(@"panels awake done");

    // A second PET viewer of the same study, its series synchronized: the
    // toolbar panel replaces the toolbars, the PET tables are applied, the
    // 12-bit timer runs, the left tool is restored and the fusion asked.
    harnessNumberOf2DViewers = 2;
    harnessCanDisplay12Bit = YES;
    [ViewerController horos_setSYNCSERIES: YES];
    v1->imageView.syncRelativeDiff = 2.5;
    other = Keep([[[HarnessWindow alloc] initWithContentRect: NSMakeRect(0, 0, 10, 10) styleMask: NSWindowStyleMaskTitled backing: NSBackingStoreBuffered defer: YES] autorelease], @"otherWindow");
    other.harnessController = v1;
    other.harnessToolbar = Keep([[[NSToolbar alloc] initWithIdentifier: @"t"] autorelease], @"otherToolbar");
    plain = Keep([[[HarnessWindow alloc] initWithContentRect: NSMakeRect(0, 0, 10, 10) styleMask: NSWindowStyleMaskTitled backing: NSBackingStoreBuffered defer: YES] autorelease], @"plainWindow");
    plain.harnessToolbar = Keep([[[NSToolbar alloc] initWithIdentifier: @"p"] autorelease], @"plainToolbar");
    app.harnessWindows = @[other, plain];
    v2 = Open(@"v2", @{@"RestoreLeftMouseTool": @YES, @"DEFAULTLEFTTOOL": @5, @"AUTOMATIC FUSE": @YES, @"PET Clut Mode": @"B/W Inverse",
                                        @"PETOpacityTable": @YES, @"PET Default Opacity Table": @"Logarithmic", @"USEALWAYSTOOLBARPANEL2": @YES,
                                        @"UseFloatingThumbnailsList": @YES, @"domain com.apple.CoreGraphics": @{@"DisplayUseInvertedPolarity": @YES}},
                                @{@"modality": @"PT", @"comment": @"", @"noSplitView": @YES});
    [harnessDisplayedViewers addObject: v2];
    Awake(v2, @"v2", YES);

    // An NM viewer of another study (the lock is not kept), its CLUT and
    // opacity from the NM preferences; then a CR viewer on a 12-bit display.
    v3 = Open(@"v3", @{@"clutNM": @YES, @"PET Clut Mode": @"Other", @"PET Default CLUT": @"Hot", @"OpacityTableNM": @YES, @"PETOpacityTable": @NO,
                                        @"UseFloatingThumbnailsList": @NO, @"AUTOHIDEMATRIX": @NO, @"AUTOMATIC FUSE": @NO, @"RestoreLeftMouseTool": @NO},
                                @{@"modality": @"NM", @"study": @"9.9.9", @"noButton": @YES, @"state": @1, @"listedFirst": @YES});
    [harnessDisplayedViewers removeObject: v3];
    v4 = Open(@"v4", @{@"automatic12BitTotoku": @YES}, @{@"modality": @"CR", @"study": @"8.8.8"});
    harnessCanDisplay12Bit = NO;
    v5 = Open(@"v5", @{@"AUTOHIDEMATRIX": @YES}, @{@"modality": @"MG", @"rgb": @YES, @"study": @"7.7.7", @"empty": @YES});
    [ViewerController horos_setSYNCSERIES: NO];
    }

    // The closing: the floating lists told, the other viewers' lists built
    // again, the database shown when fewer than two windows remain.
    thumbnailsListPanel[0] = Keep([[ThumbnailsListPanel new] autorelease], @"thumbnailsPanel0");
    app.harnessWindows = @[other];
    [Values() setObject: @YES forKey: @"UseFloatingThumbnailsList"];
    [harnessDisplayedViewers removeObject: v2];
    Close(v2, @"v2");
    [Values() setObject: @NO forKey: @"UseFloatingThumbnailsList"];
    app.harnessWindows = @[other, plain];
    [Values() setObject: @YES forKey: @"harness raise on removal"];
    Close(v3, @"v3");
    [Values() setObject: @NO forKey: @"harness raise on removal"];
    Close(v4, @"v4");
    Close(v5, @"v5");
    [harnessDisplayedViewers removeObject: v1];
    Close(v1, @"v1");
}

static void Refresh(void) {
    harnessDisplayedViewers = [[NSMutableArray alloc] init];
    ViewerController *v = Open(@"r1", @{}, @{@"coalescer": @0, @"patient": @"Patient One"});
    DicomSeries *open = ((DicomImage*)v->fileList[0][0]).series;
    DicomSeries *samePatient = MakeSeries(@"samePatient", @"Patient One", nil, nil);
    DicomSeries *otherPatient = MakeSeries(@"otherPatient", @"Patient Two", nil, nil);
    DicomImage *ofOpen = Keep([[DicomImage new] autorelease], @"newOfOpen"); ofOpen.series = open;
    DicomImage *ofSame = Keep([[DicomImage new] autorelease], @"newOfSamePatient"); ofSame.series = samePatient;
    DicomImage *ofOther = Keep([[DicomImage new] autorelease], @"newOfOtherPatient"); ofOther.series = otherPatient;
    DicomImage *orphan = Keep([[DicomImage new] autorelease], @"newWithoutSeries");
    v->harnessStudy = MakeSeries(@"current", @"Patient One", nil, nil).study;
    v->harnessSeries = open;

    Record(@"=== no list"); [v refreshDatabase: nil];
    Record(@"=== other patient"); [v refreshDatabase: @[ofOther, orphan]];
    Record(@"=== same patient"); [v refreshDatabase: @[ofSame, ofOther]];
    Record(@"=== open series, image 2 shown"); v->imageView.harnessCurImage = 2; [v refreshDatabase: @[ofOther, ofOpen, ofSame, ofOpen]];
    Record(@"=== open series, delayed"); v->harnessCoalescer.harnessWait = 0.25; [v refreshDatabase: @[ofOpen]];
    v->harnessCoalescer.harnessWait = 0;
    Record(@"=== open series, image out of range"); v->imageView.harnessCurImage = -1; [v refreshDatabase: @[ofOpen]];
    Record(@"=== open series, no coalescer"); [v->harnessCoalescer release]; v->harnessCoalescer = nil; v->imageView.harnessCurImage = 1; [v refreshDatabase: @[ofOpen]];
    Record(@"=== dragging"); v->imageView.harnessDragging = YES; [v refreshDatabase: @[ofOpen]]; v->imageView.harnessDragging = NO;
    Record(@"=== reentry"); v->harnessRecurse = YES; [v refreshDatabase: nil];
    Record(@"=== exception"); v->harnessRaise = YES; [v refreshDatabase: nil];
    Record(@"=== after the exception"); [v refreshDatabase: @[ofSame]];
    Record(@"=== comparatives");
    for (NSString *patient in @[@"Patient One", @"patient ONE", @"Pátient One", @"Patient Two", @""]) { Record(Name(patient)); [v comparativeRefresh: patient]; }
    Record(@"nil"); [v comparativeRefresh: nil];
    // A viewer that shows nothing.
    [v->fileList[0] removeAllObjects];
    Record(@"=== empty: other patient"); [v refreshDatabase: @[ofOther]];
    Record(@"=== empty: comparatives"); [v comparativeRefresh: @"Patient One"]; [v comparativeRefresh: nil];
    [v->t12BitTimer invalidate];
}

static void Notifications(void) {
    harnessDisplayedViewers = [[NSMutableArray alloc] init];
    ViewerController *v = Open(@"n1", @{}, @{});
    ViewerController *fused = MakeViewer(@"fused", @{});
    Record(@"=== close: nothing fused, nil object"); [v CloseViewerNotification: [NSNotification notificationWithName: @"x" object: nil]];
    Record(@"=== close: another viewer"); [v CloseViewerNotification: [NSNotification notificationWithName: @"x" object: fused]];
    v->blendingController = fused;
    Record(@"=== close: the fused viewer"); [v CloseViewerNotification: [NSNotification notificationWithName: @"x" object: fused]];
    ((HarnessWindow*)[v window]).harnessMain = YES;
    Record(@"=== close: main window"); [v CloseViewerNotification: [NSNotification notificationWithName: @"x" object: nil]];
    ((HarnessWindow*)[v window]).harnessMain = NO; ((HarnessWindow*)[v window]).harnessKey = YES;
    Record(@"=== close: key window"); [v CloseViewerNotification: [NSNotification notificationWithName: @"x" object: v]];
    v->blendingController = nil;

    DCMView *first = v->imageView;
    DCMView *tile = Keep([[[DCMView alloc] initWithFrame: NSZeroRect] autorelease], @"tile");
    tile.harnessWindow = [v window]; tile.rows = 1; tile.columns = 1;
    DCMView *elsewhere = Keep([[[DCMView alloc] initWithFrame: NSZeroRect] autorelease], @"elsewhere");
    elsewhere.harnessWindow = Keep([[[HarnessWindow alloc] initWithContentRect: NSMakeRect(0, 0, 10, 10) styleMask: NSWindowStyleMaskTitled backing: NSBackingStoreBuffered defer: YES] autorelease], @"elsewhereWindow");
    DCMView *tiled = Keep([[[DCMView alloc] initWithFrame: NSZeroRect] autorelease], @"tiled");
    tiled.harnessWindow = [v window]; tiled.rows = 2; tiled.columns = 1;
    for (DCMView *view in @[elsewhere, tile, tiled]) {
        Record([NSString stringWithFormat: @"=== updateImageView %@ (first %lu, it %lu)", Name(view), (unsigned long)[first retainCount], (unsigned long)[view retainCount]]);
        [v updateImageView: [NSNotification notificationWithName: @"x" object: view]];
        Record([NSString stringWithFormat: @"imageView %@ first %lu it %lu", Name(v->imageView), (unsigned long)[first retainCount], (unsigned long)[view retainCount]]);
    }
    Record(@"=== volume notifications");
    NSData *volume = Keep([NSData dataWithBytes: "z" length: 1], @"volume");
    [v sendWillFreeVolumeDataNotificationWithVolumeData: volume movieIndex: 3];
    [v sendDidAllocateVolumeDataNotificationWithVolumeData: volume movieIndex: 0];
    [v sendWillFreeVolumeDataNotificationWithVolumeData: nil movieIndex: 1];
    [v sendDidAllocateVolumeDataNotificationWithVolumeData: nil movieIndex: 1];
    [v->t12BitTimer invalidate];
}

static void HotKeys(void) {
    for (int tool = -1; tool < 30; tool++) Record([NSString stringWithFormat: @"tool %d -> hot key %d", tool, [ViewerController getHotKeyEquivalentToTool: (ToolMode)tool]]);
    Record([NSString stringWithFormat: @"tool 31 -> hot key %d", [ViewerController getHotKeyEquivalentToTool: (ToolMode)31]]);
    for (int key = -2; key < 80; key++) Record([NSString stringWithFormat: @"hot key %d -> tool %d", key, [ViewerController getToolEquivalentToHotKey: key]]);
}

static void Truncate(void) {
    NSArray *texts = @[@"", @"short", @"exactly ten", @"A study comment that is much longer than the list allows", @"Étude à l'hôpital Saint-Éloi, série dynamique",
                       @"emoji \U0001F600 in the middle of a long comment text"];
    for (NSString *text in texts) {
        for (unsigned length = 0; length <= 40; length += (length < 6 ? 1 : 7)) {
            NSMutableArray *parts = [NSMutableArray array];
            for (unsigned direction = 0; direction <= 3; direction++) {
                for (NSString *ellipsis in @[@"…", @"..."]) {
                    @try { [parts addObject: [NSString stringWithFormat: @"%@", [text stringTruncatedToLength: length direction: direction withEllipsisString: ellipsis]]]; }
                    @catch (NSException *e) { [parts addObject: [@"raises " stringByAppendingString: e.name]]; }
                }
            }
            @try { [parts addObject: [text stringWithTruncatingToLength: length]]; } @catch (NSException *e) { [parts addObject: [@"raises " stringByAppendingString: e.name]]; }
            @try { [parts addObject: [text stringTruncatedToLength: length direction: 2]]; } @catch (NSException *e) { [parts addObject: [@"raises " stringByAppendingString: e.name]]; }
            Record([NSString stringWithFormat: @"%@ %u: %@", Name(text), length, [parts componentsJoinedByString: @" | "]]);
        }
    }
    NSString *same = @"same";
    Record([NSString stringWithFormat: @"not truncated is the string itself: %d", [same stringWithTruncatingToLength: 10] == same || [[same stringWithTruncatingToLength: 10] isEqualToString: same]]);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        HarnessInstall();
        keep = [[NSMutableArray alloc] init];
        app = (HarnessApplication*)[HarnessApplication sharedApplication];
        NSString *scenario = [NSString stringWithUTF8String: argv[1]];
        if ([scenario isEqualToString: @"lifecycle"]) Lifecycle();
        else if ([scenario isEqualToString: @"refresh"]) Refresh();
        else if ([scenario isEqualToString: @"notifications"]) Notifications();
        else if ([scenario isEqualToString: @"hotkeys"]) HotKeys();
        else if ([scenario isEqualToString: @"truncate"]) Truncate();
        else return 2;
    }
    return 0;
}
'''.replace('DUMP_LINES', dump_lines())

REFERENCE_STATICS = [
    r'static\s+BOOL SYNCSERIES = NO;',
    r'static NSString\*\s+PlayToolbarItemIdentifier\s*=\s*@"Play\.pdf";',
    r'static BOOL DisplayUseInvertedPolarity = NO;',
    r'BOOL SyncButtonBehaviorIsBetweenStudies = NO;',
]
REFERENCE_METHODS = [
    '+ (ToolMode) getToolEquivalentToHotKey', '+ (int) getHotKeyEquivalentToTool',
    '- (void)sendWillFreeVolumeDataNotificationWithVolumeData', '- (void)sendDidAllocateVolumeDataNotificationWithVolumeData',
    '- (id) initWithPix:', '- (void) viewerControllerInit', '-(void)awakeFromNib', '-(void)comparativeRefresh:',
    '-(void)refreshDatabase:', '- (void) dealloc', '- (void) CloseViewerNotification:', '- (void)updateImageView:',
]


def objc_blocks(text):
    """The methods ViewerController.m kept, in a category of the stand-in."""
    statics = []
    for pattern in REFERENCE_STATICS:
        statics.append(re.search(pattern, text).group(0))
    truncate = text[text.index('enum\n{\n    NSTruncateStart'):]
    truncate = truncate[:truncate.index('@end', truncate.index('@implementation NSString (Truncate)')) + 4]
    table = text[text.index('static int hotKeyToolCrossTable[]'):]
    table = table[:table.index('};') + 2]
    parts = []
    for signature in REFERENCE_METHODS:
        # The definition, not a declaration: no ';' before its body.
        start = text.index(signature)
        while ';' in text[start:text.index('\n{', start)]:
            start = text.index(signature, start + 1)
        parts.append(text[start:method_end(text, start)])
    reentry = re.search(r'static int avoidReentryRefreshDatabase = 0;', text).group(0)
    statics_category = text[text.index('@implementation ViewerController (SwiftStatics)'):]
    statics_category = statics_category[:statics_category.index('@end') + 4]
    return ('#import "Harness.h"\n' + '\n'.join(statics) + '\n' + truncate + '\n' + table + '\n' + reentry + '\n'
            + '@implementation ViewerController (Reference)\n' + '\n'.join(parts) + '\n@end\n' + statics_category + '\n')


def header_parts(revision):
    """ToolMode (DCMView.h) and the hot key actions (DefaultsOsiriX.h) at `revision`."""
    dcmview = read(revision, 'Horos/Sources/DCMView.h')
    if dcmview is None or b'typedef NS_ENUM(short, ToolMode)' not in dcmview:
        dcmview = read(reference, 'Horos/Sources/DCMView.h')
    dcmview = dcmview.decode('latin1')
    tool = dcmview[dcmview.index('typedef NS_ENUM(short, ToolMode)'):]
    tool = tool[:tool.index('};') + 2]
    defaults = read(revision, 'Horos/Sources/DefaultsOsiriX.h').decode('latin1')
    keys = defaults[defaults.index('enum HotKeyActions'):]
    keys = keys[:keys.index('};') + 2]
    return tool, keys


reference = args.reference
if reference is None:
    head = read('HEAD', VC)
    reference = 'HEAD' if head else history_reference.before_removal(VC)
if reference is None:
    print('skipped: needs the history that has the Objective-C ViewerController.m (a shallow clone does not)')
    sys.exit(2)
reference_vc = read(reference, VC)
if reference_vc is None or b'- (id) initWithPix:' not in reference_vc:
    sys.exit('FAIL: %s has no Objective-C ViewerController initializer in %s' % (reference, VC))
reference_vc = reference_vc.decode('utf-8')
current_vc = read(args.current, VC)
current_is_objc = current_vc is not None and b'- (id) initWithPix:' in current_vc
tool_mode, hot_keys = header_parts(args.current)


def run(command, what, cwd=None, keep_errors=False):
    built = subprocess.run(command, capture_output=True, text=True, cwd=cwd)
    if built.returncode:
        output = built.stdout + built.stderr
        if keep_errors:
            output = '\n'.join(line for line in output.splitlines() if ' error: ' in line) or output
        sys.exit('FAIL: %s:\n%s' % (what, output[-6000:]))


with tempfile.TemporaryDirectory(prefix='horos-viewer-controller-') as tmp:
    folder = Path(tmp)
    for name in ('HorosObjCException.h', 'HorosObjCException.m', 'Notifications.h', 'Notifications.m'):
        (folder / name).write_bytes(read(args.current, 'Horos/Sources/' + name) or (ROOT / 'Horos/Sources' / name).read_bytes())
    frameworks = ['-framework', 'Cocoa', '-framework', 'CoreData']

    def clang(source, defines=(), arc=False, label=None):
        target = folder / ((label or Path(source).stem) + '.o')
        run(['xcrun', 'clang', '-c', '-fobjc-arc' if arc else '-fno-objc-arc', '-fblocks', '-fmodules', '-w', *defines, '-I', str(folder), str(source), '-o', str(target)],
            '%s does not compile' % Path(source).name)
        return str(target)

    def write_header(swift):
        text = HEADER.replace('TOOLMODE', tool_mode).replace('HOTKEYS', hot_keys)
        (folder / 'Harness.h').write_text(text)

    def common(side, defines):
        work = folder / side
        work.mkdir(exist_ok=True)
        (work / 'Stubs.m').write_text(STUBS)
        (work / 'Driver.m').write_text(DRIVER)
        return [clang(work / 'Stubs.m', defines, label=side + '-Stubs'), clang(work / 'Driver.m', defines, label=side + '-Driver'),
                clang(folder / 'HorosObjCException.m', arc=True, label=side + '-HorosObjCException'),
                clang(folder / 'Notifications.m', label=side + '-Notifications')]

    write_header(False)

    def objc_program(name, vc_text):
        objects = common(name, ())
        source = folder / name / 'Blocks.m'
        source.write_text(objc_blocks(vc_text))
        blocks = clang(source, label=name + '-Blocks')
        program = folder / ('%s-program' % name)
        run(['xcrun', 'clang', *objects, blocks, *frameworks, '-o', str(program)], '%s does not link' % name)
        return program

    reference_program = objc_program('reference', reference_vc)
    if current_is_objc:
        current_program = objc_program('current', current_vc.decode('utf-8'))
        current_label = 'Objective-C of %s' % (args.current or 'the tree')
    else:
        objects = common('swift', ('-DHARNESS_SWIFT',))
        swift = folder / 'swift'
        sources = []
        for name in SWIFT_FILES:
            text = read(args.current, 'Horos/Sources/' + name)
            if text is None:
                sys.exit('FAIL: no Horos/Sources/%s' % name)
            (swift / name).write_bytes(text)
            sources.append(str(swift / name))
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
             *sources, *objects, *frameworks, '-o', str(current_program)],
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
            for label, text in results.items():
                (args.dump / ('%s-%s.txt' % (scenario, label))).write_text(text)
        expected, got = results['reference'].splitlines(), results['current'].splitlines()
        if not expected:
            sys.exit('FAIL: %s recorded nothing' % scenario)
        if expected == got:
            print('%s: %d records identical (%s against the Objective-C of %s)' % (scenario, len(expected), current_label, reference))
        else:
            failures += 1
            print('FAIL: %s differs (%s against the Objective-C of %s):' % (scenario, current_label, reference))
            for line in list(difflib.unified_diff(expected, got, 'reference', 'current', lineterm='', n=1))[:80]:
                print('  ' + line)
    if failures:
        sys.exit(1)
    print("PASS: the viewer's life, its refresh of the database, its notifications, hot keys and truncation are identical to the Objective-C in every scenario")
