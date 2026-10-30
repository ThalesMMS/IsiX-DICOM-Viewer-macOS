#!/usr/bin/env python3
"""The 2D viewer's menu enablement, presets and contextual menus and the
presentation of its image do what their Objective-C did.

The validation of the viewer's menu items (-validateMenuItem:), the presets
menus of its popups (window level, convolution, opacity) with the sheet that
names a window level preset, its contextual menus (a click on the image, on
a ROI, the comments menu) with their actions, and the presentation of the
image with the convenience accessors (flips, rotation, font size, LUT, image
tiling, the current study, series and image) moved from ViewerController.m
to Swift extensions of the class, with the rules of the tiling tags, the
presets' order and check marks and the composed comment in the IsiXImaging
module. This runs the same synthetic scenarios through both and compares
everything they produce:

* validate: every action the validation knows (and one it does not), each
  item's enablement, check mark, key equivalent, modifier mask and image,
  over viewers that close, show no database image, show grey, RGB and
  post-processed series, with and without ROIs of every kind, selected,
  locked, grouped, generated, with the presets, tiling, sync, key image and
  crosshair in different states, and without an image view;
* presets: the three presets menus built, copied into the popups, rebuilt
  when the presets change and left alone otherwise, the refresh of the four
  popups, the naming sheet opened and closed with and without OK;
* contextual: the menu of a click on the image (with the tools, the ROI
  tools, the crosshair, the main menu's submenus, the hanging protocols and
  the workspace menu), its notification and pruning, the menu of a ROI of
  each kind, Remove, a hanging protocol applied, the comments menu;
* presentation: the flips, font sizes, rotations, overlays, LUT and VOI LUT,
  the refresh of the display, the image tiling from its menu and the rows
  and columns asked for, the accessors of the current image view, study,
  series and image, and the post-processed flag.

The reference is the Objective-C of ViewerController.m in the last revision
that has it (history_reference), compiled with clang as Xcode compiles it
(manual retain and release); the other side is the current tree: the Swift
files with IsiXImaging, compiled with swiftc, or the Objective-C again if the
tree still has it (which is how this test ran, and passed, before the
conversion). Both run over the same stand-ins of the viewer, its views,
slices, files and ROIs, the application's menus, the browser and the
panels, which record what they are given; the two records must be identical.

    python3 tests/test-viewer-menus-equivalence.py [--reference REV] [--current REV] [--dump DIR]
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
MARK = '- (BOOL)validateMenuItem:(NSMenuItem *)item'
SWIFT_FILES = ['ViewerController+%s.swift' % name for name in
               ('MenuValidation', 'PresetMenus', 'ContextualMenus', 'Presentation')]
# IsiXLogging first: the others that log write through it.
MODULES = ['IsiXLogging', 'IsiXImaging']
SCENARIOS = ['validate', 'presets', 'contextual', 'presentation']

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--reference')
parser.add_argument('--current')
parser.add_argument('--dump', type=Path, help='write the programs and the records of both to this folder')
args = parser.parse_args()

# The tool modes, as DCMView.h declares them.
TOOL_MODES = re.search(r'typedef NS_ENUM\(short, ToolMode\)\s*\{.*?\};',
                       (ROOT / 'Horos/Sources/DCMView.h').read_bytes().decode('latin1'), re.S).group(0)

HEADER = r'''#pragma clang diagnostic ignored "-Wnullability-completeness"
#import <Cocoa/Cocoa.h>
#import <CoreData/CoreData.h>
#import "HorosObjCException.h"

// The stand-ins of the viewer, its views, slices, files and ROIs, and of the
// classes the menu blocks talk to (the application's menus, the browser, the
// crosshair, the panels), declared as the app's headers declare them (with
// the Swift names of the app's Swift classes), so that the Objective-C and
// the Swift compile against them alike. They record what they are given
// (Record) and answer from their fields.

#define MAX4D 8
#define ToolsMenuIconSize NSMakeSize(28.0, 28.0)

void Record(NSString *line);
NSString *Name(id object);
void Register(id object, NSString *name);

extern BOOL HarnessSYNCSERIES;
extern NSNotificationName const OsirixUpdateWLWWMenuNotification, OsirixUpdateCLUTMenuNotification, OsirixUpdateConvolutionMenuNotification,
    OsirixUpdateOpacityMenuNotification, OsirixPopulatedContextualMenuNotification, OsirixRemoveROINotification;

TOOL_MODES

@class ViewerController, DCMView, DCMPix, ROI, DicomStudy, DicomSeries, DicomImage, SeriesView;

@interface NSWindow (HarnessSheets)
- (void) orderOutAndEndSheetWithReturnCode:(NSModalResponse) code NS_SWIFT_NAME(orderOutAndEndSheet(returnCode:));
@end

/// A window that never reaches the window server: its sheets are recorded.
@interface HarnessWindow : NSWindow
@end

/// A managed object (inserted in a context without a store) whose keys are
/// a dictionary; the keys it is given are recorded.
@interface KVCStub : NSManagedObject {
@public
    NSMutableDictionary *values;
}
+ (instancetype) stub;
@end

@interface DicomStudy : KVCStub
- (NSSet*) keyImages;
- (NSArray*) imageSeries;
@end

@interface DicomSeries : KVCStub
@end

@interface DicomImage : KVCStub
@end

@interface DCMPix : NSObject
@property BOOL hasSUV, isRGB, VOILUTApplied;
@property unsigned int *VOILUT_table;
@property float savedWL, savedWW;
+ (void) checkUserDefaults:(BOOL) update;
- (void) changeWLWW:(float) wl :(float) ww;
@end

@interface ROI : NSObject
@property ToolMode type;
@property(retain) NSMutableArray *points;
@property BOOL locked, selectable;
@property NSTimeInterval groupID;
@property(retain) NSString *comments;
@property(copy) NSString *name;
@property(assign) DCMView *curView;
@end

@interface DCMView : NSView
@property NSInteger curImage;
@property(retain) DCMPix *curDCM;
@property NSInteger rows, columns;
@property(nonatomic) ToolMode currentTool;
@property(nonatomic) float rotation, scaleValue;
@property(nonatomic) NSPoint origin;
@property(nonatomic) BOOL xFlipped, yFlipped;
@property float curWW, curWL;
@property(retain) DicomSeries *harnessSeries;
@property(retain) DicomImage *harnessImage;
@property(readonly) NSMutableArray *curRoiList;
+ (NSMutableDictionary*) hotKeyDictionary;
+ (BOOL) labelFontSizeMenuItemIsEnabled:(NSMenuItem*) item;
- (DicomSeries*) seriesObj;
- (DicomImage*) imageObj;
- (DicomStudy*) studyObj;
- (IBAction) flipVertical:(id) sender;
- (IBAction) flipHorizontal:(id) sender;
- (void) increaseFontSize:(id) sender;
- (void) decreaseFontSize:(id) sender;
- (void) getWLWW:(float*) wl :(float*) ww;
- (void) setWLWW:(float) wl :(float) ww;
- (void) updateImage;
- (void) updateTilingViews;
- (IBAction) resizeWindow:(id) sender;
- (IBAction) actualSize:(id) sender;
- (IBAction) realSize:(id) sender;
- (IBAction) scaleToFit:(id) sender;
@end

@interface SeriesView : NSView
@property(retain) NSArray *harnessImageViews;
- (NSMutableArray*) imageViews;
- (void) setImageViewMatrixForRows:(int) rows columns:(int) columns rescale:(BOOL) rescale NS_SWIFT_NAME(setImageViewMatrix(forRows:columns:rescale:));
@end

/// The superclass of the viewer windows, which answers the current objects.
@interface OSIWindowController : NSWindowController
- (DicomStudy*) currentStudy;
- (DicomSeries*) currentSeries;
- (DicomImage*) currentImage;
- (float) curWW;
- (float) curWL;
@end

@interface ViewerController : OSIWindowController {
@public
    BOOL windowWillClose, postprocessed;
    NSMutableArray *fileList[MAX4D], *pixList[MAX4D], *roiList[MAX4D];
    short curMovieIndex, maxMovieIndex;
    DCMView *imageView;
    SeriesView *seriesView;
    NSString *curConvMenu, *curWLWWMenu, *curCLUTMenu, *curOpacityMenu;
    NSButton *keyImageCheck;
    NSPopUpButton *popupRoi, *wlwwPopup, *convPopup, *clutPopup, *OpacityPopup;
    NSMenuItem *seriesPopupContextualMenu;
    BOOL convPopupSet, wlwwPopupSet, OpacityPopupSet;
    NSWindow *addWLWWWindow, *CommentsWindow;
    NSTextField *wl, *ww, *newName, *CommentsEditField;
    NSButton *CommentsField;
}
@property(readonly) NSButton *keyImageCheck;
@property(retain) ROI *harnessSelectedROI;
@property(retain) NSMutableArray *harnessSelectedROIs;
@property BOOL harnessVolumic, harnessInterslice, harnessShowsOnAll;
+ (int) numberOf2DViewer;
+ (NSArray*) getDisplayedStudies;
+ (int) getHotKeyEquivalentToTool:(ToolMode) h;
- (void) buildSeriesPopup;
- (BOOL) isDataVolumicIn4D:(BOOL) check4D;
- (ROI*) selectedROI;
- (NSMutableArray*) selectedROIs;
- (BOOL) horosPickInterslicePreferred:(ROI*) preferred first:(NSDictionary**) first second:(NSDictionary**) second;
- (BOOL) canShowSelectedROIsOnAllImagesOfSeries;
- (NSImage*) imageForROI:(ToolMode) i;
- (void) horosLoadViewerPanels;
- (void) propagateSettings;
- (void) revertSeries:(id) sender;
- (void) buildMatrixPreview:(BOOL) showSelected;
- (void) updateNavigator;
- (IBAction) saveWindowsState:(id) sender;
- (IBAction) saveWindowsStateAsDICOMSR:(id) sender;
// Actions the blocks name by #selector, as the app's headers and Swift declare them.
- (IBAction) navigator:(id) sender;
- (IBAction) threeDPanel:(id) sender;
- (IBAction) morphoSelectedBrushROI:(id) sender;
- (IBAction) mergeBrushROI:(id) sender;
- (IBAction) generateGeometryFromSelectedLine:(id) sender;
- (IBAction) measureBetweenSelectedSlices:(id) sender;
- (IBAction) roiDeleteAll:(id) sender;
- (IBAction) setDefaultTool:(id) sender;
- (IBAction) roiDeleteAll:(id) sender;
- (void) ApplyCLUT:(id) sender NS_SWIFT_NAME(applyCLUT(_:));
- (void) ApplyOpacity:(id) sender NS_SWIFT_NAME(applyOpacity(_:));
- (void) ApplyWLWW:(id) sender NS_SWIFT_NAME(applyWLWW(_:));
- (IBAction) SetWLWW:(id) sender NS_SWIFT_NAME(setWLWW(_:));
@end

// The accessors of ViewerController (SwiftIvars) the Swift blocks read.
@interface ViewerController (SwiftIvars)
IVAR_ACCESSORS
+ (BOOL)horos_SYNCSERIES;
@end

NS_SWIFT_NAME(PatientCrosshairController)
@interface HorosPatientCrosshairController : NSObject
@property(class, readonly) HorosPatientCrosshairController *shared;
@property(readonly) BOOL isVisible;
@property(readonly, nullable) id currentPoint;
@end

NS_SWIFT_NAME(ROIMenuEnablement)
@interface HorosROIMenuEnablement : NSObject
+ (BOOL) mayMergeBrushROIsWithTypes:(NSArray<NSNumber*>*) types NS_SWIFT_NAME(mayMergeBrushROIs(types:));
@end

NS_SWIFT_NAME(ContextMenuPruning)
@interface HorosContextMenuPruning : NSObject
+ (void) hideUnavailableItemsIn:(NSMenu*) menu groups:(NSArray<NSMenu*>*) groups defaultTarget:(NSObject*) target NS_SWIFT_NAME(hideUnavailableItems(in:groups:defaultTarget:));
@end

NS_SWIFT_NAME(WindowLevelText)
@interface HorosWindowLevelText : NSObject
+ (NSString*) stringForValue:(double) value NS_SWIFT_NAME(string(for:));
+ (double) valueFromString:(NSString*) text fallback:(double) fallback NS_SWIFT_NAME(value(from:fallback:));
+ (double) widthFromString:(NSString*) text fallback:(double) fallback NS_SWIFT_NAME(width(from:fallback:));
@end

@interface AppController : NSObject
@property(retain) NSMenu *windowsTilingMenuRows, *windowsTilingMenuColumns;
+ (AppController*) sharedAppController NS_SWIFT_NAME(shared());
- (IBAction) closeAllViewers:(id) sender;
- (NSMenu*) wlwwMenu;
- (NSMenu*) orientationMenu;
- (NSMenu*) imageTilingMenu;
- (NSMenu*) exportMenu;
- (NSMenu*) workspaceMenu;
@end

@interface RemoteDicomDatabase : NSObject
- (void) object:(NSManagedObject*) object setValue:(id) value forKey:(NSString*) key NS_SWIFT_NAME(object(_:setValue:forKey:));
@end

@interface BrowserController : NSObject
@property(readonly) NSOutlineView *databaseOutline;
@property(readonly) id database;
@property(readonly) BOOL isCurrentDatabaseBonjour;
+ (BrowserController*) currentBrowser;
- (void) databaseOpenStudy:(DicomStudy*) study withProtocol:(NSDictionary*) protocol NS_SWIFT_NAME(databaseOpen(_:withProtocol:));
@end

@interface WindowLayoutManager : NSObject
+ (NSArray*) hangingProtocolsForModality:(NSString*) modality NS_SWIFT_NAME(hangingProtocols(forModality:));
@end

@interface NavigatorWindowController : NSWindowController
+ (NavigatorWindowController*) navigatorWindowController NS_SWIFT_NAME(navigatorWindowController());
- (void) initView;
@end

#ifndef HARNESS_SWIFT
// What the blocks implement (Objective-C category or Swift extension), for
// the driver; Swift sees them in the extensions.
@interface ViewerController (Menus)
- (BOOL) validateMenuItem:(NSMenuItem*) item;
- (void) refreshMenus;
- (void) refresh;
- (BOOL) isPostprocessed;
- (void) setPostprocessed:(BOOL) v;
- (BOOL) postprocessed;
- (void) contextualDictionaryPath:(NSString*) path;
- (NSString*) contextualDictionaryPath;
- (void) computeContextualMenu;
- (void) computeContextualMenuForROI:(ROI*) roi;
- (NSMenu*) contextualMenuForROI:(ROI*) roi;
- (void) roiContextualMenuActionRemove:(NSMenuItem*) source;
- (void) applyWindowProtocol:(id) sender;
- (NSMenu*) contextualMenu;
- (IBAction) updateImage:(id) sender;
- (void) needsDisplayUpdate;
- (void) UpdateConvolutionMenu:(NSNotification*) note;
- (void) UpdateWLWWMenu:(NSNotification*) note;
- (void) AddCurrentWLWW:(id) sender;
- (IBAction) endNameWLWW:(id) sender;
- (void) renderButton:(id) sender;
- (void) UpdateOpacityMenu:(NSNotification*) note;
- (DCMView*) imageView;
- (NSArray*) imageViews;
- (NSString*) modality;
- (void) contextualMenuEvent:(id) sender;
- (void) flipVertical:(id) sender;
- (void) flipHorizontal:(id) sender;
- (void) increaseFontSize:(id) sender;
- (void) decreaseFontSize:(id) sender;
- (void) rotate0:(id) sender;
- (void) rotate90:(id) sender;
- (void) rotate180:(id) sender;
- (void) displayDICOMOverlays:(id) sender;
- (void) applyLUT:(id) sender;
- (void) useVOILUT:(id) sender;
- (DicomStudy*) currentStudy;
- (DicomSeries*) currentSeries;
- (DicomImage*) currentImage;
- (float) curWW;
- (float) curWL;
- (void) setWL:(float) wl WW:(float) ww;
- (BOOL) xFlipped;
- (BOOL) yFlipped;
- (float) rotation;
- (void) setRotation:(float) rotation;
- (void) setOrigin:(NSPoint) o;
- (float) scaleValue;
- (void) setScaleValue:(float) scaleValue;
- (void) setYFlipped:(BOOL) v;
- (void) setXFlipped:(BOOL) v;
- (SeriesView*) seriesView;
- (void) setImageRows:(int) rows columns:(int) columns;
- (void) setImageRows:(int) rows columns:(int) columns rescale:(BOOL) rescale;
- (IBAction) setImageTiling:(id) sender;
@end
#endif

// What the driver changes between the cases.
extern BOOL harnessCrosshairVisible, harnessBonjour;
extern id harnessCrosshairPoint;
extern int harnessViewers;
extern NSArray *harnessDisplayedStudies, *harnessProtocols;
extern NSMenu *harnessWorkspaceMenu;
extern NavigatorWindowController *harnessNavigator;
'''

IVARS = [
    # (kind, type, name)
    ('scalar', 'BOOL', 'windowWillClose'), ('scalar', 'BOOL', 'postprocessed'),
    ('scalar', 'short', 'curMovieIndex'), ('scalar', 'short', 'maxMovieIndex'),
    ('object', 'DCMView*', 'imageView'), ('object', 'SeriesView*', 'seriesView'),
    ('object', 'NSString*', 'curConvMenu'), ('object', 'NSString*', 'curWLWWMenu'),
    ('object', 'NSString*', 'curCLUTMenu'), ('object', 'NSString*', 'curOpacityMenu'),
    ('outlet', 'NSPopUpButton*', 'popupRoi'), ('outlet', 'NSPopUpButton*', 'wlwwPopup'), ('outlet', 'NSPopUpButton*', 'convPopup'),
    ('outlet', 'NSPopUpButton*', 'clutPopup'), ('outlet', 'NSPopUpButton*', 'OpacityPopup'),
    ('object', 'NSMenuItem*', 'seriesPopupContextualMenu'),
    ('scalar', 'BOOL', 'convPopupSet'), ('scalar', 'BOOL', 'wlwwPopupSet'), ('scalar', 'BOOL', 'OpacityPopupSet'),
    ('outlet', 'NSWindow*', 'addWLWWWindow'), ('outlet', 'NSWindow*', 'CommentsWindow'),
    ('outlet', 'NSTextField*', 'wl'), ('outlet', 'NSTextField*', 'ww'), ('outlet', 'NSTextField*', 'newName'),
    ('outlet', 'NSTextField*', 'CommentsEditField'), ('outlet', 'NSButton*', 'CommentsField'),
]
NONISOLATED = {'curMovieIndex', 'maxMovieIndex', 'imageView', 'seriesView', 'postprocessed'}


def accessors():
    """The declarations and implementations of ViewerController (SwiftIvars), as the app's."""
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
    declared += ['- (nullable NSMutableArray*)horos_fileListAt:(NSInteger)index NS_SWIFT_NONISOLATED;',
                 '- (nullable NSMutableArray*)horos_pixListAt:(NSInteger)index NS_SWIFT_NONISOLATED;',
                 '- (nullable NSMutableArray*)horos_roiListAt:(NSInteger)index;']
    implemented += ['- (NSMutableArray*)horos_fileListAt:(NSInteger)index { return fileList[index]; }',
                    '- (NSMutableArray*)horos_pixListAt:(NSInteger)index { return pixList[index]; }',
                    '- (NSMutableArray*)horos_roiListAt:(NSInteger)index { return roiList[index]; }',
                    '+ (BOOL)horos_SYNCSERIES { return HarnessSYNCSERIES; }']
    return '\n'.join(declared), '\n'.join(implemented)


DECLARED, IMPLEMENTED = accessors()
HEADER = HEADER.replace('TOOL_MODES', TOOL_MODES).replace('IVAR_ACCESSORS', DECLARED)

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
    return [NSString stringWithFormat: @"<%@>", NSStringFromClass([object class])];
}

void Record(NSString *line) {
    printf("%s\n", line.UTF8String);
    fflush(stdout);
}

BOOL HarnessSYNCSERIES = NO;
BOOL harnessCrosshairVisible = NO, harnessBonjour = NO;
id harnessCrosshairPoint = nil;
int harnessViewers = 1;
NSArray *harnessDisplayedStudies = nil, *harnessProtocols = nil;
NSMenu *harnessWorkspaceMenu = nil;
NavigatorWindowController *harnessNavigator = nil;

NSNotificationName const OsirixUpdateWLWWMenuNotification = @"OsirixUpdateWLWWMenuNotification";
NSNotificationName const OsirixUpdateCLUTMenuNotification = @"OsirixUpdateCLUTMenuNotification";
NSNotificationName const OsirixUpdateConvolutionMenuNotification = @"OsirixUpdateConvolutionMenuNotification";
NSNotificationName const OsirixUpdateOpacityMenuNotification = @"OsirixUpdateOpacityMenuNotification";
NSNotificationName const OsirixPopulatedContextualMenuNotification = @"OsirixPopulatedContextualMenuNotification";
NSNotificationName const OsirixRemoveROINotification = @"OsirixRemoveROINotification";

@implementation NSWindow (HarnessSheets)
- (void) orderOutAndEndSheetWithReturnCode:(NSModalResponse) code { Record([NSString stringWithFormat: @"%@ orderOutAndEndSheet %ld", Name(self), (long)code]); }
@end

@implementation HarnessWindow
- (void) beginSheet:(NSWindow*) sheet completionHandler:(void (^)(NSModalResponse)) handler { Record([NSString stringWithFormat: @"%@ beginSheet %@ handler %d", Name(self), Name(sheet), handler != nil]); }
@end

static NSManagedObjectContext *stubContext;

@implementation KVCStub
+ (instancetype) stub {
    if (!stubContext) {
        NSMutableArray *entities = [NSMutableArray array];
        for (NSString *name in @[@"DicomStudy", @"DicomSeries", @"DicomImage"]) {
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
    Record([NSString stringWithFormat: @"%@ %@ = %@", Name(self), key, Name(value)]);
    if (value) [values setObject: value forKey: key]; else [values removeObjectForKey: key];
}
@end

@implementation DicomStudy
- (NSSet*) keyImages { return [values objectForKey: @"harnessKeyImages"]; }
- (NSArray*) imageSeries { return [values objectForKey: @"harnessImageSeries"]; }
@end

@implementation DicomSeries
@end

@implementation DicomImage
@end

@implementation DCMPix
+ (void) checkUserDefaults:(BOOL) update { Record([NSString stringWithFormat: @"DCMPix checkUserDefaults %d", update]); }
- (void) changeWLWW:(float) wl :(float) ww { Record([NSString stringWithFormat: @"%@ changeWLWW %g %g", Name(self), wl, ww]); }
@end

@implementation ROI
@end

@implementation DCMView {
    NSMutableArray *rois;
}
+ (NSMutableDictionary*) hotKeyDictionary {
    // Not an NSDictionary in the declaration: Swift keeps it an object, as the app's own Swift declaration does.
    return [[@{@"a": @0, @"b": @5, @"c": @6, @"d": @"6", @"e": @19} mutableCopy] autorelease];
}
+ (BOOL) labelFontSizeMenuItemIsEnabled:(NSMenuItem*) item {
    Record([NSString stringWithFormat: @"labelFontSizeMenuItemIsEnabled %@", NSStringFromSelector(item.action)]);
    return item.action == @selector(increaseFontSize:);
}
- (NSMutableArray*) curRoiList { if (!rois) rois = [NSMutableArray new]; return rois; }
- (DicomSeries*) seriesObj { return self.harnessSeries; }
- (DicomImage*) imageObj { return self.harnessImage; }
- (DicomStudy*) studyObj { return [self.harnessSeries valueForKey: @"study"]; }
- (IBAction) flipVertical:(id) sender { Record([NSString stringWithFormat: @"%@ flipVertical %@", Name(self), Name(sender)]); }
- (IBAction) flipHorizontal:(id) sender { Record([NSString stringWithFormat: @"%@ flipHorizontal %@", Name(self), Name(sender)]); }
- (void) increaseFontSize:(id) sender { Record([NSString stringWithFormat: @"%@ increaseFontSize %@", Name(self), Name(sender)]); }
- (void) decreaseFontSize:(id) sender { Record([NSString stringWithFormat: @"%@ decreaseFontSize %@", Name(self), Name(sender)]); }
- (void) getWLWW:(float*) wl :(float*) ww { *wl = self.curWL; *ww = self.curWW; }
- (void) setWLWW:(float) wl :(float) ww { Record([NSString stringWithFormat: @"%@ setWLWW %g %g", Name(self), wl, ww]); self.curWL = wl; self.curWW = ww; }
- (void) updateImage { Record([NSString stringWithFormat: @"%@ updateImage", Name(self)]); }
- (void) updateTilingViews { Record([NSString stringWithFormat: @"%@ updateTilingViews", Name(self)]); }
- (IBAction) resizeWindow:(id) sender {}
- (IBAction) actualSize:(id) sender {}
- (IBAction) realSize:(id) sender {}
- (IBAction) scaleToFit:(id) sender {}
- (void) setRotation:(float) rotation { Record([NSString stringWithFormat: @"%@ rotation %g", Name(self), rotation]); _rotation = rotation; }
- (void) setScaleValue:(float) value { Record([NSString stringWithFormat: @"%@ scaleValue %g", Name(self), value]); _scaleValue = value; }
- (void) setOrigin:(NSPoint) o { Record([NSString stringWithFormat: @"%@ origin %g %g", Name(self), o.x, o.y]); _origin = o; }
- (void) setXFlipped:(BOOL) v { Record([NSString stringWithFormat: @"%@ xFlipped %d", Name(self), v]); _xFlipped = v; }
- (void) setYFlipped:(BOOL) v { Record([NSString stringWithFormat: @"%@ yFlipped %d", Name(self), v]); _yFlipped = v; }
- (void) setNeedsDisplay:(BOOL) flag { Record([NSString stringWithFormat: @"%@ needsDisplay %d", Name(self), flag]); }
- (void) setMenu:(NSMenu*) menu {
    Record([NSString stringWithFormat: @"%@ menu %@", Name(self), menu ? [NSString stringWithFormat: @"%ld items, first %@", (long)menu.numberOfItems, menu.numberOfItems ? [menu itemAtIndex: 0].title : @""] : @"nil"]);
    [super setMenu: menu];
}
@end

@implementation SeriesView
- (NSMutableArray*) imageViews { return [[self.harnessImageViews mutableCopy] autorelease]; }
- (void) setImageViewMatrixForRows:(int) rows columns:(int) columns rescale:(BOOL) rescale {
    Record([NSString stringWithFormat: @"%@ matrix %d x %d rescale %d", Name(self), rows, columns, rescale]);
}
@end

@implementation OSIWindowController
- (DicomStudy*) currentStudy { return nil; }
- (DicomSeries*) currentSeries { return nil; }
- (DicomImage*) currentImage { return nil; }
- (float) curWW { return 0; }
- (float) curWL { return 0; }
@end

@implementation ViewerController
@synthesize keyImageCheck;
+ (int) numberOf2DViewer { return harnessViewers; }
+ (NSArray*) getDisplayedStudies { return harnessDisplayedStudies; }
+ (int) getHotKeyEquivalentToTool:(ToolMode) h { return h == tWL ? 0 : h == tMesure ? 5 : h == tROI ? 6 : h == t2DPoint ? 19 : -1; }
- (void) buildSeriesPopup { Record(@"buildSeriesPopup"); }
- (BOOL) isDataVolumicIn4D:(BOOL) check4D { Record([NSString stringWithFormat: @"isDataVolumicIn4D %d", check4D]); return self.harnessVolumic; }
- (ROI*) selectedROI { return self.harnessSelectedROI; }
- (NSMutableArray*) selectedROIs { return self.harnessSelectedROIs; }
- (BOOL) horosPickInterslicePreferred:(ROI*) preferred first:(NSDictionary**) first second:(NSDictionary**) second {
    Record([NSString stringWithFormat: @"horosPickInterslicePreferred %@ %d %d", Name(preferred), first != NULL, second != NULL]);
    return self.harnessInterslice;
}
- (BOOL) canShowSelectedROIsOnAllImagesOfSeries { return self.harnessShowsOnAll; }
- (NSImage*) imageForROI:(ToolMode) i {
    NSImage *image = [[[NSImage alloc] initWithSize: NSMakeSize(16, 16)] autorelease];
    Register(image, [NSString stringWithFormat: @"image%d", (int)i]);
    return image;
}
- (void) horosLoadViewerPanels { Record(@"horosLoadViewerPanels"); }
- (void) propagateSettings { Record(@"propagateSettings"); }
- (void) revertSeries:(id) sender { Record([NSString stringWithFormat: @"revertSeries %@", Name(sender)]); }
- (void) buildMatrixPreview:(BOOL) showSelected { Record([NSString stringWithFormat: @"buildMatrixPreview %d", showSelected]); }
- (void) updateNavigator { Record(@"updateNavigator"); }
- (IBAction) saveWindowsState:(id) sender {}
- (IBAction) saveWindowsStateAsDICOMSR:(id) sender {}
- (IBAction) navigator:(id) sender {}
- (IBAction) threeDPanel:(id) sender {}
- (IBAction) morphoSelectedBrushROI:(id) sender {}
- (IBAction) mergeBrushROI:(id) sender {}
- (IBAction) generateGeometryFromSelectedLine:(id) sender {}
- (IBAction) measureBetweenSelectedSlices:(id) sender {}
- (IBAction) roiDeleteAll:(id) sender {}
- (IBAction) setDefaultTool:(id) sender {}
- (void) ApplyCLUT:(id) sender {}
- (void) ApplyOpacity:(id) sender {}
- (void) ApplyWLWW:(id) sender {}
- (IBAction) SetWLWW:(id) sender {}
@end

@implementation ViewerController (SwiftIvars)
IVAR_IMPLEMENTATIONS
@end

@implementation HorosPatientCrosshairController
+ (HorosPatientCrosshairController*) shared { static HorosPatientCrosshairController *shared; if (!shared) shared = [self new]; return shared; }
- (BOOL) isVisible { return harnessCrosshairVisible; }
- (id) currentPoint { return harnessCrosshairPoint; }
@end

@implementation HorosROIMenuEnablement
+ (BOOL) mayMergeBrushROIsWithTypes:(NSArray<NSNumber*>*) types {
    Record([NSString stringWithFormat: @"mayMergeBrushROIsWithTypes %@", Name(types)]);
    if (types.count == 0) return NO;
    for (NSNumber *t in types) if (t.intValue != tPlain) return NO;
    return YES;
}
@end

@implementation HorosContextMenuPruning
+ (void) hideUnavailableItemsIn:(NSMenu*) menu groups:(NSArray<NSMenu*>*) groups defaultTarget:(NSObject*) target {
    Record([NSString stringWithFormat: @"prune %ld items, %ld groups, target %@", (long)menu.numberOfItems, (long)groups.count, Name(target)]);
}
@end

@implementation HorosWindowLevelText
+ (NSString*) stringForValue:(double) value { return [NSString stringWithFormat: @"%g", value]; }
+ (double) valueFromString:(NSString*) text fallback:(double) fallback { return text.length ? text.doubleValue : fallback; }
+ (double) widthFromString:(NSString*) text fallback:(double) fallback { return text.doubleValue > 0 ? text.doubleValue : fallback; }
@end

static NSMenu *SmallMenu(NSString *title, NSArray *items) {
    NSMenu *menu = [[[NSMenu alloc] initWithTitle: title] autorelease];
    for (NSString *item in items) [menu addItemWithTitle: item action: NSSelectorFromString([item stringByAppendingString: @":"]) keyEquivalent: @""];
    return menu;
}

@implementation AppController
+ (AppController*) sharedAppController {
    static AppController *shared;
    if (!shared) {
        shared = [self new];
        shared.windowsTilingMenuRows = SmallMenu(@"Rows", @[@"rows1", @"rows2"]);
        shared.windowsTilingMenuColumns = SmallMenu(@"Columns", @[@"columns1"]);
    }
    return shared;
}
- (IBAction) closeAllViewers:(id) sender { Record([NSString stringWithFormat: @"closeAllViewers %@", Name(sender)]); }
- (NSMenu*) wlwwMenu { return SmallMenu(@"WLWW", @[@"ApplyWLWW", @"SetWLWW"]); }
- (NSMenu*) orientationMenu { return SmallMenu(@"Orientation", @[@"axial", @"sagittal"]); }
- (NSMenu*) imageTilingMenu { return SmallMenu(@"Tiling", @[@"setImageTiling"]); }
- (NSMenu*) exportMenu { return SmallMenu(@"Export", @[@"exportJPEG"]); }
- (NSMenu*) workspaceMenu { return harnessWorkspaceMenu; }
@end

@implementation RemoteDicomDatabase
- (void) object:(NSManagedObject*) object setValue:(id) value forKey:(NSString*) key { Record([NSString stringWithFormat: @"remote %@ %@ = %@", Name(object), key, Name(value)]); }
@end

@interface HarnessOutline : NSOutlineView
@end
@implementation HarnessOutline
- (void) reloadData { Record(@"databaseOutline reloadData"); }
@end

@implementation BrowserController
+ (BrowserController*) currentBrowser { static BrowserController *browser; if (!browser) browser = [self new]; return browser; }
- (NSOutlineView*) databaseOutline { static HarnessOutline *outline; if (!outline) outline = [HarnessOutline new]; return outline; }
- (id) database { static RemoteDicomDatabase *database; if (!database) database = [RemoteDicomDatabase new]; return database; }
- (BOOL) isCurrentDatabaseBonjour { return harnessBonjour; }
// The protocol by its content: the app's browser takes a Swift dictionary, which is not the item's object.
- (void) databaseOpenStudy:(DicomStudy*) study withProtocol:(NSDictionary*) protocol {
    Record([NSString stringWithFormat: @"databaseOpenStudy %@ protocol %@", Name(study), protocol ? Name([NSDictionary dictionaryWithDictionary: protocol]) : @"nil"]);
}
@end

@implementation WindowLayoutManager
+ (NSArray*) hangingProtocolsForModality:(NSString*) modality { Record([NSString stringWithFormat: @"hangingProtocolsForModality %@", Name(modality)]); return harnessProtocols; }
@end

@implementation NavigatorWindowController
+ (NavigatorWindowController*) navigatorWindowController { return harnessNavigator; }
- (void) initView { Record(@"navigator initView"); }
@end
'''.replace('IVAR_IMPLEMENTATIONS', IMPLEMENTED)

DRIVER = r'''#import "Harness.h"

static NSMutableArray *keep;

static void Keep(id object) { [keep addObject: object]; }

/// A menu, item by item, with its submenus.
static void Dump(NSMenu *menu, NSString *indent) {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.isSeparatorItem) { Record([indent stringByAppendingString: @"---"]); continue; }
        Record([NSString stringWithFormat: @"%@%@ action %@ tag %ld target %@ object %@ image %@ %@ state %ld key \"%@\" mask %lu%@",
                indent, item.title, item.action ? NSStringFromSelector(item.action) : @"nil", (long)item.tag, Name(item.target), Name(item.representedObject),
                Name(item.image), item.image ? NSStringFromSize(item.image.size) : @"", (long)item.state, item.keyEquivalent,
                (unsigned long)item.keyEquivalentModifierMask, item.isHidden ? @" hidden" : @""]);
        if (item.submenu) {
            Record([NSString stringWithFormat: @"%@  [%@]", indent, item.submenu.title]);
            Dump(item.submenu, [indent stringByAppendingString: @"    "]);
        }
    }
}

static void Try(NSString *what, void (^block)(void)) {
    @try { block(); }
    @catch (NSException *e) { Record([NSString stringWithFormat: @"%@ raised %@ %@", what, e.name, e.reason]); }
}

static ROI *MakeROI(NSString *name, ToolMode type, int points, BOOL locked) {
    ROI *roi = [[ROI new] autorelease];
    roi.name = name; roi.type = type; roi.selectable = YES; roi.locked = locked;
    roi.points = [NSMutableArray array];
    for (int i = 0; i < points; i++) [roi.points addObject: @(i)];
    Register(roi, name);
    Keep(roi);
    return roi;
}

static DicomStudy *study;
static DicomSeries *series;

/// A viewer of `frames` movie frames of `slices` images each, its views
/// named after `name`.
static ViewerController *MakeViewer(NSString *name, int frames, int slices) {
    ViewerController *v = [[ViewerController alloc] initWithWindow: nil];
    Keep(v);
    Register(v, name);
    HarnessWindow *window = [[[HarnessWindow alloc] initWithContentRect: NSMakeRect(0, 0, 100, 100) styleMask: NSWindowStyleMaskTitled backing: NSBackingStoreBuffered defer: YES] autorelease];
    Register(window, [name stringByAppendingString: @".window"]);
    v.window = window;
    v->imageView = [[DCMView alloc] initWithFrame: NSMakeRect(0, 0, 10, 10)];
    Register(v->imageView, [name stringByAppendingString: @".view"]);
    v->imageView.harnessSeries = series;
    DicomImage *image = [DicomImage stub];
    Register(image, [name stringByAppendingString: @".image"]);
    v->imageView.harnessImage = image;
    v->imageView.rows = 1; v->imageView.columns = 1;
    v->imageView.curWL = 40; v->imageView.curWW = 400;
    v->seriesView = [[SeriesView alloc] initWithFrame: NSZeroRect];
    Register(v->seriesView, [name stringByAppendingString: @".seriesView"]);
    DCMView *second = [[[DCMView alloc] initWithFrame: NSZeroRect] autorelease];
    Register(second, [name stringByAppendingString: @".view2"]);
    v->seriesView.harnessImageViews = @[v->imageView, second];
    v->maxMovieIndex = frames;
    for (int f = 0; f < frames; f++) {
        v->fileList[f] = [NSMutableArray new];
        v->pixList[f] = [NSMutableArray new];
        v->roiList[f] = [NSMutableArray new];
        for (int s = 0; s < slices; s++) {
            DicomImage *file = [DicomImage stub];
            Register(file, [NSString stringWithFormat: @"%@.file%d.%d", name, f, s]);
            file->values = [@{@"isKeyImage": @(s == 1), @"series": series} mutableCopy];
            [v->fileList[f] addObject: file];
            DCMPix *pix = [[DCMPix new] autorelease];
            Register(pix, [NSString stringWithFormat: @"%@.pix%d.%d", name, f, s]);
            pix.savedWL = 50; pix.savedWW = 350;
            [v->pixList[f] addObject: pix];
            [v->roiList[f] addObject: [NSMutableArray array]];
        }
    }
    v->imageView.curDCM = v->pixList[0].firstObject;
    v->curWLWWMenu = [@"Other" retain];
    v->curCLUTMenu = [@"No CLUT" retain];
    v->curConvMenu = [@"No Filter" retain];
    v->curOpacityMenu = [@"Linear Table" retain];
    v->keyImageCheck = [[NSButton alloc] initWithFrame: NSZeroRect];
    v->popupRoi = [[NSPopUpButton alloc] initWithFrame: NSZeroRect pullsDown: YES];
    [v->popupRoi addItemsWithTitles: @[@"ROI tools", @"Oval", @"-", @"Polygon"]];
    [v->popupRoi itemAtIndex: 1].tag = tOval;
    [v->popupRoi itemAtIndex: 3].tag = tCPolygon;
    for (NSString *popup in @[@"wlww", @"conv", @"clut", @"opacity"]) {
        NSPopUpButton *button = [[NSPopUpButton alloc] initWithFrame: NSZeroRect pullsDown: NO];
        Register(button, [NSString stringWithFormat: @"%@.%@Popup", name, popup]);
        if ([popup isEqualToString: @"wlww"]) v->wlwwPopup = button;
        else if ([popup isEqualToString: @"conv"]) v->convPopup = button;
        else if ([popup isEqualToString: @"clut"]) v->clutPopup = button;
        else v->OpacityPopup = button;
    }
    v->seriesPopupContextualMenu = [[NSMenuItem alloc] initWithTitle: @"Series" action: nil keyEquivalent: @""];
    v->seriesPopupContextualMenu.submenu = [[[NSMenu alloc] initWithTitle: @"Series list"] autorelease];
    v->addWLWWWindow = [[HarnessWindow alloc] initWithContentRect: NSZeroRect styleMask: 0 backing: NSBackingStoreBuffered defer: YES];
    Register(v->addWLWWWindow, [name stringByAppendingString: @".addWLWWWindow"]);
    v->CommentsWindow = [[HarnessWindow alloc] initWithContentRect: NSZeroRect styleMask: 0 backing: NSBackingStoreBuffered defer: YES];
    Register(v->CommentsWindow, [name stringByAppendingString: @".CommentsWindow"]);
    v->wl = [[NSTextField alloc] initWithFrame: NSZeroRect];
    v->ww = [[NSTextField alloc] initWithFrame: NSZeroRect];
    v->newName = [[NSTextField alloc] initWithFrame: NSZeroRect];
    v->CommentsEditField = [[NSTextField alloc] initWithFrame: NSZeroRect];
    v->CommentsEditField.stringValue = @"typed";
    v->CommentsField = [[NSButton alloc] initWithFrame: NSZeroRect];
    v.harnessSelectedROIs = [NSMutableArray array];
    return v;
}

static NSArray *ValidatedActions(void) {
    return @[@"togglePatientCrosshair:", @"clearPatientCrosshair:", @"seriesPopupSelect:", @"displaySUV:", @"flipDataSeries:", @"navigator:",
             @"threeDPanel:", @"useVOILUT:", @"resetWindowsState:", @"setAllKeyImages:", @"setAllNonKeyImages:", @"findNextPreviousKeyImage:",
             @"loadWindowsState:", @"roiDeleteAllROIsWithSameName:", @"blendWindows:", @"roiGetInfo:", @"roiHistogram:", @"roiVolume:",
             @"roiVolumeEraseRestore:", @"createLayerROIFromSelectedROI:", @"generateGeometryFromSelectedLine:", @"measureBetweenSelectedSlices:",
             @"groupSelectedROIs:", @"ungroupSelectedROIs:", @"lockSelectedROIs:", @"unlockSelectedROIs:", @"makeSelectedROIsUnselectable:",
             @"makeAllROIsSelectable:", @"morphoSelectedBrushROI:", @"convertBrushPolygon:", @"mergeBrushROI:", @"roiPropagateSetup:",
             @"showSelectedROIsOnAllImagesOfSeries:", @"roiDeleteGeneratedROIs:", @"roiSaveSeries:", @"roiSelectDeselectAll:", @"roiDeleteAll:",
             @"roiRename:", @"setROIsImagesKeyImages:", @"roiPropagateSlab:", @"applyConvolutionOnSource:", @"ConvertToBWMenu:", @"ConvertToRGBMenu:",
             @"SyncSeries:", @"setKeyImage:", @"increaseFontSize:", @"decreaseFontSize:", @"copy:"];
}

/// Every action once, then the items whose tag or title matter in several
/// versions.
static NSArray *Items(void) {
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *action in ValidatedActions()) {
        NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle: action action: NSSelectorFromString(action) keyEquivalent: @""] autorelease];
        [items addObject: item];
    }
    NSMenuItem *nilAction = [[[NSMenuItem alloc] initWithTitle: @"no action" action: nil keyEquivalent: @""] autorelease];
    [items addObject: nilAction];
    for (NSNumber *tag in @[@0, @1, @4, @5, @6, @9, @15, @16, @-1]) {
        NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle: @"tiling" action: @selector(setImageTiling:) keyEquivalent: @""] autorelease];
        item.tag = tag.integerValue;
        [items addObject: item];
    }
    for (NSString *action in @[@"setROITool:", @"setDefaultTool:", @"setDefaultToolMenu:"]) {
        for (NSNumber *tag in @[@0, @5, @6, @8, @19, @65541]) {
            NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle: @"tool" action: NSSelectorFromString(action) keyEquivalent: @"z"] autorelease];
            item.tag = tag.integerValue;
            item.keyEquivalentModifierMask = NSEventModifierFlagCommand;
            if (tag.intValue == 8) { item.image = [[[NSImage alloc] initWithSize: NSMakeSize(3, 3)] autorelease]; Register(item.image, @"ownImage"); }
            [items addObject: item];
        }
    }
    for (NSString *action in @[@"ApplyCLUT:", @"ApplyConv:", @"ApplyOpacity:", @"ApplyWLWW:"]) {
        for (NSString *title in @[@"No CLUT", @"No Filter", @"Linear Table", @"Other", @"1 - Brain", @"Brain", @"12 - Lung", @"abc", @"", @"Caf\u00e9", @"Cafe\u0301"]) {
            NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle: title action: NSSelectorFromString(action) keyEquivalent: @""] autorelease];
            [items addObject: item];
        }
    }
    return items;
}

static void Validate(ViewerController *v, NSString *label) {
    Record([NSString stringWithFormat: @"== %@", label]);
    for (NSMenuItem *item in Items()) {
        __block BOOL valid = NO;
        Try(@"validateMenuItem", ^{ valid = [v validateMenuItem: item]; });
        Record([NSString stringWithFormat: @"%@ %@ tag %ld -> %d state %ld key \"%@\" mask %lu image %@ %@", item.action ? NSStringFromSelector(item.action) : @"nil",
                item.title, (long)item.tag, valid, (long)item.state, item.keyEquivalent, (unsigned long)item.keyEquivalentModifierMask,
                Name(item.image), item.image ? NSStringFromSize(item.image.size) : @""]);
    }
}

static void ValidateScenario(void) {
    ViewerController *v = MakeViewer(@"v", 2, 3);
    v->imageView.curImage = 1;

    v->windowWillClose = YES;
    Validate(v, @"closing");
    v->windowWillClose = NO;

    [v->fileList[0] addObject: @"not a file"];
    Validate(v, @"no database image");
    [v->fileList[0] removeLastObject];

    // Grey, two frames, no ROIs.
    Validate(v, @"plain");

    // ROIs of every kind on the image shown and elsewhere, selected.
    ROI *oval = MakeROI(@"oval", tOval, 4, NO);
    ROI *line = MakeROI(@"line", tMesure, 2, NO);
    ROI *shortLine = MakeROI(@"shortLine", tMesure, 1, NO);
    ROI *locked = MakeROI(@"locked", tCPolygon, 5, YES);
    ROI *grouped = MakeROI(@"grouped", tOval, 4, NO);
    grouped.groupID = 12.5;
    ROI *generated = MakeROI(@"generated", tPlain, 0, NO);
    generated.comments = @"morphing generated";
    ROI *unselectable = MakeROI(@"unselectable", tText, 0, NO);
    unselectable.selectable = NO;
    ROI *brush = MakeROI(@"brush", tPlain, 0, NO);
    ROI *brush2 = MakeROI(@"brush2", tPlain, 0, NO);
    ROI *point = MakeROI(@"point", t2DPoint, 1, NO);
    [v->roiList[0][1] addObjectsFromArray: @[oval, line]];
    [v->roiList[1][2] addObject: generated];
    v.harnessSelectedROI = oval;
    [v.harnessSelectedROIs setArray: @[brush, brush2]];
    v.harnessVolumic = YES;
    v.harnessInterslice = YES;
    v.harnessShowsOnAll = YES;
    v->imageView.rows = 2; v->imageView.columns = 3;
    v->imageView.currentTool = tROI;
    v->curWLWWMenu = [@"Brain" retain];
    v->curConvMenu = [@"Sharpen" retain];
    v->curCLUTMenu = [@"abc" retain];
    v->curOpacityMenu = [@"Caf\u00e9" retain];
    v->keyImageCheck.state = NSControlStateValueOn;
    HarnessSYNCSERIES = YES;
    harnessCrosshairVisible = YES;
    harnessCrosshairPoint = @"point";
    harnessViewers = 2;
    [study setValue: [NSData data] forKey: @"windowsState"];
    harnessDisplayedStudies = @[study];
    study->values[@"harnessKeyImages"] = [NSSet setWithObject: @"key"];
    ((DCMPix*)v->pixList[0][0]).hasSUV = YES;
    static unsigned int table[4];
    ((DCMPix*)v->pixList[0][0]).VOILUT_table = table;
    [[NSUserDefaults standardUserDefaults] setBool: YES forKey: @"UseVOILUT"];
    Validate(v, @"rois");

    // The same with other selections and states.
    [v->roiList[0][1] addObjectsFromArray: @[locked, grouped, unselectable]];
    v.harnessSelectedROI = unselectable;
    [v.harnessSelectedROIs setArray: @[line, brush]];
    v.harnessVolumic = NO;
    v.harnessInterslice = NO;
    v.harnessShowsOnAll = NO;
    v->postprocessed = YES;
    v->imageView.rows = 4; v->imageView.columns = 4;
    v->imageView.currentTool = t2DPoint;
    [v->curWLWWMenu release]; v->curWLWWMenu = nil;
    [v->curConvMenu release]; v->curConvMenu = nil;
    [v->curCLUTMenu release]; v->curCLUTMenu = [@"Cafe\u0301" retain];
    v->keyImageCheck.state = NSControlStateValueMixed;
    HarnessSYNCSERIES = NO;
    harnessCrosshairVisible = NO;
    harnessCrosshairPoint = nil;
    harnessViewers = 1;
    [study setValue: nil forKey: @"windowsState"];
    ((DCMPix*)v->pixList[0][0]).VOILUTApplied = YES;
    ((DCMPix*)v->pixList[0][0]).VOILUT_table = NULL;
    ((DCMPix*)v->pixList[0][0]).isRGB = YES;
    Validate(v, @"rois locked, post-processed, RGB");

    // A line selected among others; a point; only key images; one frame.
    [v.harnessSelectedROIs setArray: @[shortLine, MakeROI(@"lockedLine", tMesure, 2, YES), line]];
    v.harnessSelectedROI = point;
    v->postprocessed = NO;
    v.harnessVolumic = YES;
    ((DCMPix*)v->pixList[0][0]).VOILUTApplied = NO;
    [[NSUserDefaults standardUserDefaults] setBool: NO forKey: @"UseVOILUT"];
    for (int f = 0; f < 2; f++) for (DicomImage *file in v->fileList[f]) file->values[@"isKeyImage"] = @YES;
    v->maxMovieIndex = 1;
    v->curMovieIndex = 0;
    [v->roiList[0][1] removeAllObjects];
    study->values[@"harnessKeyImages"] = [NSSet set];
    Validate(v, @"line among others, key images only");

    // An arrow selected.
    v.harnessSelectedROI = MakeROI(@"arrow", tArrow, 2, NO);
    Validate(v, @"arrow");

    // No image view, an empty frame shown.
    [v->imageView release];
    v->imageView = nil;
    [v->pixList[0] removeAllObjects];
    Validate(v, @"no image view, no slices");
}

static void Presets(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject: @{@"Brain": @[@40, @80], @"abdomen": @[@60, @400], @"Abdomen": @[@50, @350], @"lung": @[@-600, @1500]} forKey: @"WLWW3"];
    [defaults setObject: @{@"Sharpen": @{}, @"blur": @{}, @"Edge": @{}} forKey: @"Convolution"];
    [defaults setObject: @{@"Log": @{}, @"exp": @{}} forKey: @"OPACITY"];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    for (NSString *name in @[OsirixUpdateWLWWMenuNotification, OsirixUpdateCLUTMenuNotification, OsirixUpdateConvolutionMenuNotification, OsirixUpdateOpacityMenuNotification])
        [center addObserverForName: name object: nil queue: nil usingBlock: ^(NSNotification *note) {
            Record([NSString stringWithFormat: @"notification %@ object %@ userInfo %@", note.name, Name(note.object), Name(note.userInfo)]);
        }];

    ViewerController *v1 = MakeViewer(@"v1", 1, 2), *v2 = MakeViewer(@"v2", 1, 2);
    NSNotification *changed = [NSNotification notificationWithName: @"x" object: nil userInfo: @{}];
    NSNotification *unchanged = [NSNotification notificationWithName: @"x" object: nil userInfo: nil];

    void (^dumpPopups)(ViewerController*) = ^(ViewerController *v) {
        for (NSPopUpButton *popup in @[v->wlwwPopup, v->convPopup, v->OpacityPopup, v->clutPopup]) {
            Record([NSString stringWithFormat: @"%@ title \"%@\" selected %ld menu %@", Name(popup), popup.title, (long)popup.indexOfSelectedItem, Name(popup.menu)]);
            Dump(popup.menu, @"  ");
        }
    };

    v1->windowWillClose = YES;
    Try(@"closing", ^{ [v1 UpdateWLWWMenu: nil]; [v1 UpdateConvolutionMenu: nil]; [v1 UpdateOpacityMenu: nil]; });
    v1->windowWillClose = NO;
    dumpPopups(v1);

    Try(@"first", ^{ [v1 UpdateWLWWMenu: nil]; [v1 UpdateConvolutionMenu: nil]; [v1 UpdateOpacityMenu: nil]; });
    dumpPopups(v1);
    Record([NSString stringWithFormat: @"set %d %d %d", v1->wlwwPopupSet, v1->convPopupSet, v1->OpacityPopupSet]);

    [defaults setObject: @{@"Brain": @[@40, @80], @"Bone": @[@300, @2000]} forKey: @"WLWW3"];
    [defaults setObject: @{@"Sharpen": @{}} forKey: @"Convolution"];
    [defaults setObject: @{@"exp": @{}} forKey: @"OPACITY"];
    Try(@"unchanged", ^{ [v1 UpdateWLWWMenu: unchanged]; [v1 UpdateConvolutionMenu: unchanged]; [v1 UpdateOpacityMenu: unchanged]; });
    dumpPopups(v1);
    // The other viewer takes the shared menus as they were built.
    Try(@"second viewer", ^{ [v2 UpdateWLWWMenu: unchanged]; [v2 UpdateConvolutionMenu: nil]; [v2 UpdateOpacityMenu: unchanged]; });
    dumpPopups(v2);
    Try(@"changed", ^{ [v2 UpdateWLWWMenu: changed]; [v2 UpdateConvolutionMenu: changed]; [v2 UpdateOpacityMenu: changed]; });
    dumpPopups(v2);
    v2->curConvMenu = [@"Sharpen" retain];
    v2->curWLWWMenu = [@"2 - Brain" retain];
    Try(@"refreshMenus", ^{ [v2 refreshMenus]; });
    dumpPopups(v2);

    // The naming sheet.
    Try(@"AddCurrentWLWW", ^{ [v1 AddCurrentWLWW: nil]; });
    Record([NSString stringWithFormat: @"wl \"%@\" ww \"%@\" name \"%@\"", v1->wl.stringValue, v1->ww.stringValue, v1->newName.stringValue]);
    v1->wl.stringValue = @"40.5"; v1->ww.stringValue = @"0.25"; v1->newName.stringValue = @"Mine";
    NSButton *cancel = [[[NSButton alloc] initWithFrame: NSZeroRect] autorelease];
    NSButton *ok = [[[NSButton alloc] initWithFrame: NSZeroRect] autorelease];
    ok.tag = 1;
    Try(@"endNameWLWW cancel", ^{ [v1 endNameWLWW: cancel]; });
    Record([NSString stringWithFormat: @"WLWW3 %@ cur %@", Name([defaults objectForKey: @"WLWW3"]), Name(v1->curWLWWMenu)]);
    Try(@"endNameWLWW ok", ^{ [v1 endNameWLWW: ok]; });
    Record([NSString stringWithFormat: @"WLWW3 %@ cur %@", Name([defaults objectForKey: @"WLWW3"]), Name(v1->curWLWWMenu)]);
    v1->ww.stringValue = @"abc"; v1->wl.stringValue = @"";
    [defaults removeObjectForKey: @"WLWW3"];
    Try(@"endNameWLWW ok without presets", ^{ [v1 endNameWLWW: ok]; });
    Record([NSString stringWithFormat: @"WLWW3 %@ cur %@", Name([defaults objectForKey: @"WLWW3"]), Name(v1->curWLWWMenu)]);
    Try(@"renderButton", ^{ [v1 renderButton: nil]; });
}

static void Contextual(void) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserverForName: OsirixPopulatedContextualMenuNotification object: nil queue: nil usingBlock: ^(NSNotification *note) {
        Record([NSString stringWithFormat: @"populated %@ items, userInfo %@", note.object ? @([note.object numberOfItems]) : @"nil", Name(note.userInfo)]);
    }];
    [center addObserverForName: OsirixRemoveROINotification object: nil queue: nil usingBlock: ^(NSNotification *note) {
        Record([NSString stringWithFormat: @"remove ROI %@", Name(note.object)]);
    }];

    ViewerController *v = MakeViewer(@"v", 1, 3);
    [series setValue: @"CT" forKey: @"modality"];
    NSDictionary *head = @{@"Study Description": @"Head"}, *empty = @{};
    Register(head, @"headProtocol"); Register(empty, @"emptyProtocol");
    harnessProtocols = @[head, empty];

    for (int c = 0; c < 3; c++) {
        Record([NSString stringWithFormat: @"== contextual menu %d", c]);
        v->imageView.currentTool = c == 0 ? tWL : c == 1 ? tROI : tMesure;
        harnessWorkspaceMenu = c == 1 ? [[[NSMenu alloc] initWithTitle: @"Workspaces"] autorelease] : nil;
        // Each in its own pool, as each click is in the application's.
        @autoreleasepool {
            __block NSMenu *menu = nil;
            Try(@"contextualMenu", ^{ menu = [v contextualMenu]; });
            Dump(menu, @"  ");
        }
        @autoreleasepool {
            Try(@"computeContextualMenu", ^{ [v computeContextualMenu]; });
            Record([NSString stringWithFormat: @"view menu %ld items", (long)v->imageView.menu.numberOfItems]);
        }
    }
    Record([NSString stringWithFormat: @"contextualDictionaryPath %@", [v contextualDictionaryPath]]);
    [v contextualDictionaryPath: @"/x"];

    Record(@"== ROI menus");
    ROI *line = MakeROI(@"line", tMesure, 2, NO), *point = MakeROI(@"point", t2DPoint, 1, NO), *oval = MakeROI(@"oval", tOval, 4, NO),
        *locked = MakeROI(@"locked", tMesure, 2, YES), *shortLine = MakeROI(@"shortLine", tMesure, 1, NO);
    for (ROI *roi in @[line, point, oval, locked, shortLine]) {
        Record([NSString stringWithFormat: @"menu of %@", Name(roi)]);
        Dump([v contextualMenuForROI: roi], @"  ");
    }
    Record(@"menu of no ROI");
    Try(@"nil ROI", ^{ Dump([v contextualMenuForROI: nil], @"  "); });
    Try(@"computeContextualMenuForROI", ^{ [v computeContextualMenuForROI: point]; });
    Try(@"computeContextualMenuForROI nil", ^{ [v computeContextualMenuForROI: nil]; });

    oval.curView = v->imageView;
    [v->imageView.curRoiList addObjectsFromArray: @[line, oval]];
    NSMenuItem *remove = [[v contextualMenuForROI: oval] itemAtIndex: 2];
    Try(@"remove", ^{ [v roiContextualMenuActionRemove: remove]; });
    Record([NSString stringWithFormat: @"rois left %@", Name(v->imageView.curRoiList)]);

    Record(@"== hanging protocol");
    DicomSeries *other = [DicomSeries stub];
    Register(other, @"otherSeries");
    study->values[@"harnessImageSeries"] = @[series, other];
    NSMenuItem *protocolItem = [[[NSMenuItem alloc] initWithTitle: @"CT - Head" action: @selector(applyWindowProtocol:) keyEquivalent: @""] autorelease];
    protocolItem.representedObject = head;
    Try(@"applyWindowProtocol", ^{ [v applyWindowProtocol: protocolItem]; });

    Record(@"== comments menu");
    NSMenu *root = [[[NSMenu alloc] initWithTitle: @"Root"] autorelease];
    NSMenu *findings = [[[NSMenu alloc] initWithTitle: @"Findings"] autorelease];
    NSMenu *lung = [[[NSMenu alloc] initWithTitle: @"Lung"] autorelease];
    [root addItemWithTitle: @"Findings" action: nil keyEquivalent: @""].submenu = findings;
    [findings addItemWithTitle: @"Lung" action: nil keyEquivalent: @""].submenu = lung;
    NSMenuItem *nodule = [lung addItemWithTitle: @"Nodule" action: @selector(contextualMenuEvent:) keyEquivalent: @""];
    NSMenuItem *question = [root addItemWithTitle: @"?" action: @selector(contextualMenuEvent:) keyEquivalent: @""];
    NSMenuItem *alone = [[[NSMenuItem alloc] initWithTitle: @"Alone" action: @selector(contextualMenuEvent:) keyEquivalent: @""] autorelease];
    v->imageView.curImage = 2;
    Try(@"comment nodule", ^{ [v contextualMenuEvent: nodule]; });
    Record([NSString stringWithFormat: @"comments field \"%@\"", v->CommentsField.title]);
    harnessBonjour = YES;
    Try(@"comment alone", ^{ [v contextualMenuEvent: alone]; });
    Record([NSString stringWithFormat: @"comments field \"%@\"", v->CommentsField.title]);
    harnessBonjour = NO;
    Try(@"comment question", ^{ [v contextualMenuEvent: question]; });
}

static void Presentation(void) {
    ViewerController *v = MakeViewer(@"v", 2, 3);
    NSButton *sender = [[[NSButton alloc] initWithFrame: NSZeroRect] autorelease];
    Register(sender, @"sender");

    Try(@"flips", ^{ [v flipVertical: sender]; [v flipHorizontal: nil]; [v increaseFontSize: sender]; [v decreaseFontSize: nil]; });
    Try(@"rotations", ^{ [v rotate0: sender]; [v rotate90: sender]; [v rotate180: nil]; });
    Try(@"overlays", ^{ [v displayDICOMOverlays: sender]; });
    v->imageView.curDCM = v->pixList[0][1];
    Try(@"applyLUT", ^{ [v applyLUT: sender]; });
    [[NSUserDefaults standardUserDefaults] setBool: NO forKey: @"UseVOILUT"];
    Try(@"useVOILUT", ^{ [v useVOILUT: sender]; });
    Record([NSString stringWithFormat: @"UseVOILUT %d", [[NSUserDefaults standardUserDefaults] boolForKey: @"UseVOILUT"]]);
    [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 0.5]];
    Record(@"after the delay");
    Try(@"updateImage", ^{ [v updateImage: nil]; });
    Try(@"needsDisplayUpdate", ^{ [v needsDisplayUpdate]; });
    Try(@"refresh", ^{ [v refresh]; });

    Record(@"== tiling");
    for (NSArray *rc in @[@[@0, @0], @[@3, @2], @[@9, @12], @[@-2, @8]]) {
        int r = [rc[0] intValue], c = [rc[1] intValue];
        Try(@"setImageRows", ^{ [v setImageRows: r columns: c]; [v setImageRows: r columns: c rescale: NO]; });
    }
    NSMenu *tiling = [[[NSMenu alloc] initWithTitle: @"Tiling"] autorelease];
    for (int t = 0; t < 4; t++) [tiling addItemWithTitle: [NSString stringWithFormat: @"t%d", t] action: @selector(setImageTiling:) keyEquivalent: @""].state = NSControlStateValueOn;
    for (NSNumber *tag in @[@0, @5, @15, @16, @-1, @-5, @4294967297]) {
        NSMenuItem *item = [tiling itemAtIndex: 1];
        item.tag = tag.integerValue;
        [tiling itemAtIndex: 0].state = NSControlStateValueOn;
        Try(@"setImageTiling", ^{ [v setImageTiling: item]; });
        Record([NSString stringWithFormat: @"states %ld %ld %ld %ld", (long)[tiling itemAtIndex: 0].state, (long)[tiling itemAtIndex: 1].state, (long)[tiling itemAtIndex: 2].state, (long)[tiling itemAtIndex: 3].state]);
    }
    Try(@"setImageTiling button", ^{ [v setImageTiling: sender]; });
    Try(@"setImageTiling nil", ^{ [v setImageTiling: nil]; });

    Record(@"== accessors");
    void (^accessors)(void) = ^{
        Record([NSString stringWithFormat: @"imageView %@ imageViews %@ seriesView %@ modality %@", Name([v imageView]), Name([v imageViews]), Name([v seriesView]), Name([v modality])]);
        Record([NSString stringWithFormat: @"study %@ series %@ image %@", Name([v currentStudy]), Name([v currentSeries]), Name([v currentImage])]);
        Record([NSString stringWithFormat: @"ww %g wl %g x %d y %d rotation %g scale %g", [v curWW], [v curWL], [v xFlipped], [v yFlipped], [v rotation], [v scaleValue]]);
        Record([NSString stringWithFormat: @"postprocessed %d %d", [v postprocessed], [v isPostprocessed]]);
    };
    [series setValue: @"MR" forKey: @"modality"];
    accessors();
    Try(@"setters", ^{ [v setWL: 12 WW: 34]; [v setRotation: 45]; [v setOrigin: NSMakePoint(1, 2)]; [v setScaleValue: 1.5]; [v setXFlipped: YES]; [v setYFlipped: YES]; });
    accessors();
    for (NSNumber *image in @[@2, @3, @-1]) {
        v->imageView.curImage = image.integerValue;
        Record([NSString stringWithFormat: @"curImage %@ modality %@", image, Name([v modality])]);
    }
    Try(@"setPostprocessed", ^{ [v setPostprocessed: YES]; });
    harnessNavigator = [[NavigatorWindowController alloc] initWithWindow: nil];
    Try(@"setPostprocessed with navigator", ^{ [v setPostprocessed: NO]; });
    accessors();
    [v->imageView release];
    v->imageView = nil;
    accessors();
    // Not -needsDisplayUpdate: without an image view the Objective-C gave the
    // slices a window it never read (uninitialized), and the Swift gives them 0.
    Try(@"no image view", ^{ [v rotate90: nil]; [v applyLUT: nil]; [v refresh]; [v updateImage: nil]; [v setImageRows: 2 columns: 2]; });
}

int main(int argc, const char **argv) { @autoreleasepool {
    [NSApplication sharedApplication];
    keep = [NSMutableArray new];
    study = [[DicomStudy stub] retain];
    Register(study, @"study");
    series = [[DicomSeries stub] retain];
    Register(series, @"series");
    series->values = [@{@"study": study} mutableCopy];
    NSString *domain = [[NSProcessInfo processInfo] processName];
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName: domain];
    NSString *scenario = [NSString stringWithUTF8String: argv[1]];
    if ([scenario isEqualToString: @"validate"]) ValidateScenario();
    else if ([scenario isEqualToString: @"presets"]) Presets();
    else if ([scenario isEqualToString: @"contextual"]) Contextual();
    else if ([scenario isEqualToString: @"presentation"]) Presentation();
    else return 3;
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName: domain];
} return 0; }
'''

# The reference's statics, as ViewerController.m had them.
REFERENCE_PRELUDE = r'''#import "Harness.h"
#define SYNCSERIES HarnessSYNCSERIES
static NSMenu *wlwwPresetsMenu = nil;
static NSMenu *contextualMenu = nil;
static NSMenu *convolutionPresetsMenu = nil;
static NSMenu *opacityPresetsMenu = nil;
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
    ('- (BOOL)validateMenuItem:(NSMenuItem *)item', '- (BOOL)validateMenuItem:(NSMenuItem *)item'),
    ('- (void) refreshMenus\n', '- (BOOL) postprocessed\n'),
    ('- (void)contextualDictionaryPath:(NSString *)newContextualDictionaryPath', '-(NSMenu*)contextualMenuForROI:(ROI*)roi\n'),
    ('-(void)roiContextualMenuActionRemove:(NSMenuItem*)source', '- (NSMenu*) contextualMenu\n'),
    ('-(IBAction) updateImage:(id) sender', '-(void) needsDisplayUpdate'),
    ('-(void) UpdateConvolutionMenu: (NSNotification*) note', '-(NSString*) modality'),
    ('- (void) contextualMenuEvent:(id)sender', '- (void) contextualMenuEvent:(id)sender'),
    ('- (void) flipVertical:(id) sender', '- (void)useVOILUT: (id)sender'),
    ('- (DicomStudy *)currentStudy', '- (IBAction)setImageTiling: (id)sender'),
]


def objc_blocks(text):
    """The menu validation, presets, contextual menus and presentation blocks
    of ViewerController.m, in a category of the stand-in."""
    parts = []
    for first, last in GROUPS:
        a = text.index(first)
        b = method_end(text, text.index(last, a))
        parts.append(text[a:b])
    return REFERENCE_PRELUDE + '@implementation ViewerController (Menus)\n' + '\n'.join(parts) + '\n@end\n'


reference = args.reference
if reference is None:
    head = read('HEAD', VC)
    reference = 'HEAD' if head and MARK.encode() in head else history_reference.before_text_removed(VC, MARK)
if reference is None:
    print('skipped: needs the history that has the Objective-C ViewerController.m (a shallow clone does not)')
    sys.exit(2)
reference_vc = read(reference, VC)
if reference_vc is None or MARK.encode() not in reference_vc:
    sys.exit('FAIL: %s has no Objective-C menu validation in %s' % (reference, VC))
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


with tempfile.TemporaryDirectory(prefix='horos-viewer-menus-') as tmp:
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
    print('PASS: the menu enablement, presets and contextual menus and the presentation of the image are identical to the Objective-C in every scenario')
