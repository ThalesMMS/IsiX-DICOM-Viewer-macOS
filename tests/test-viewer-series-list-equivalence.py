#!/usr/bin/env python3
"""The 2D viewer's series list, series menu, drops and keys do what their Objective-C did.

The series menu (-buildSeriesPopup and the selection of a series), the series
list with its thumbnails (-buildMatrixPreview: and the clicks on its cells),
its dock (its thickness, visibility, automatic hiding and the split view's
delegate), what a drop on the window does (-performDragOperation: and the
fusion sheet it opens), the keys, the highlight and the movie export
positions moved from ViewerController.m to Swift extensions of the class,
with their pure rules (which studies the list shows, their numbers, colours
and titles, the comparatives button, what a series cell counts, the size of
the pictures, the divider's snap, where the mouse keeps the list shown, the
keys' commands) in the IsiXImaging module. This runs the same synthetic
viewers through both and compares everything they produce:

* popup: the series menu of a patient's studies (local, comparatives on a
  PACS with and without a local copy, listed or not, from the browser's
  history or the database), its series (thumbnails stored, made, missing,
  failing; window colours; inverted display), and the contextual menu;
* matrix: the list's cells for the same studies, hidden studies, the
  placeholders of excluded series, the four picture sizes, a list not shown,
  the comparatives button in every state;
* selection: a series chosen from the menu or the list (another window, a
  time point, the current one, with Command, Shift or a right click), a
  study's series hidden or shown, a PACS study retrieved, the window's file
  and the DICOM fields window;
* dock: the list's thickness, mode and visibility, the KVO of its
  preferences, the automatic hiding, the split view's delegate, the
  scrolling kept in step with the other viewers;
* drag: the fusion sheet, the drops of a viewer's image, of a plug-in, of a
  series of the database and of files (ROIs, ROIs of a series, pictures);
  then, on the current tree only, rows of the database as the browser drags
  them (one pasteboard item per row, which the Objective-C could not read):
  the dropped series loads as the reference loads the series of its drop;
* keys: every key the window answers, the highlight and its timer, the
  movie export positions.

Floats are compared to the last bit, pictures by a checksum of their pixels.

The reference is the Objective-C of ViewerController.m in the last revision
that has it (history_reference), compiled with clang as Xcode compiles it
(manual retain and release); the other side is the current tree: the Swift
files with IsiXImaging, compiled with swiftc, or the Objective-C again if the
tree still has it. Both run over the same stand-ins of the viewer, its
window, list, split view, cells and menus and of the classes they call,
which record what they are given; the two records must be identical.

    python3 tests/test-viewer-series-list-equivalence.py [--reference REV] [--current REV] [--dump DIR]
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
MARK = '- (void) buildMatrixPreview: (BOOL) showSelected\n{'
SWIFT_FILES = ['ViewerController+%s.swift' % name for name in
               ('SeriesPopup', 'SeriesThumbnails', 'SeriesListDock', 'DragAndDrop', 'Keyboard')]
# IsiXLogging first: the others that log write through it.
MODULES = ['IsiXLogging', 'IsiXImaging']
SCENARIOS = ['popup', 'matrix', 'selection', 'dock', 'drag', 'keys']

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--reference')
parser.add_argument('--current')
parser.add_argument('--dump', type=Path, help='write the programs and the records of both to this folder')
args = parser.parse_args()

HEADER = r'''#pragma clang diagnostic ignored "-Wnullability-completeness"
#import <Cocoa/Cocoa.h>
#import <CoreData/CoreData.h>
#import "HorosObjCException.h"

// The stand-ins of the viewer, its window, list, split view, cells and menus,
// and of the classes the series list talks to, declared as the app's headers
// declare them (with the Swift names of the app's Swift classes), so that the
// Objective-C and the Swift compile against them alike. They record what they
// are given and answer from their fields.

#define MAX4D 8
#define MAXSCREENS 10

void Record(NSString *line);
NSString *Name(id object);
void Register(id object, NSString *name);

void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *where);
#define N2LogException(e) _N2LogExceptionImpl(e, NO, __PRETTY_FUNCTION__)
#define N2LogExceptionWithStackTrace(e) _N2LogExceptionImpl(e, YES, __PRETTY_FUNCTION__)
void N2LogStackTrace(NSString *format, ...);
void ViewerControllerLogStackTrace(NSString *message);
void N2LogStackTraceMessage(NSString *message);
#define N2SingularPluralCount(c, s, p) [NSString stringWithFormat:@"%d %@", (int)c, (c == 1? s : p)]
#define N2LocalizedSingularPluralCount(c, s, p) [NSString stringWithFormat:@"%@ %@", [NSNumberFormatter localizedStringFromNumber:[NSNumber numberWithInteger:(NSInteger)c] numberStyle:NSNumberFormatterDecimalStyle], (c == 1? s : p)]

extern NSString* const OsirixPerformDragOperationNotification;

enum dbObjectSelection {oAny, oMiddle, oFirstForFirst};

/// The application: its windows are the harness's, its current event has
/// the harness's modifier flags.
@interface HarnessApplication : NSApplication
@end
extern NSMutableArray *harnessWindows;
extern NSString *harnessTemporary;
/// Set while the driver builds its viewers and studies: nothing is recorded.
extern BOOL harnessSilent;
extern NSEventModifierFlags harnessModifiers;
extern BOOL harnessInverted;

/// A window that never reaches the window server.
@interface HarnessWindow : NSWindow
@property BOOL harnessVisible, harnessKey;
@property NSPoint harnessMouse;
- (void) disableUpdatesUntilFlush;
@end
/// A new window named `name` (+1).
HarnessWindow *NewWindow(NSString *name);

@class ViewerController, DCMView, ROI, DicomStudy, DicomSeries, DicomImage;

// Nitrogen's -stringByTruncatingToLength:, which its Swift returns as an NSString
// (the Swift side reaches it through HarnessTruncate).
#ifndef HARNESS_SWIFT
@interface NSString (N2)
- (NSString *)stringByTruncatingToLength:(NSInteger)theWidth;
@end
#endif
NSString *HarnessTruncate(NSString *string, NSInteger width);

@interface NSString (Truncate)
- (NSString *)stringWithTruncatingToLength:(unsigned)length;
- (NSString *)stringTruncatedToLength:(unsigned int)length direction:(unsigned)truncateFrom;
- (NSString *)stringTruncatedToLength:(unsigned int)length direction:(unsigned)truncateFrom withEllipsisString:(NSString *)ellipsis;
@end

@interface NSImage (N2)
- (NSImage *)imageInverted NS_SWIFT_NAME(imageInverted());
- (NSImage *)imageByScalingProportionallyUsingNSImage:(float)ratio NS_SWIFT_NAME(imageByScalingProportionallyUsingNSImage(_:));
- (NSImage *)imageByScalingProportionallyToSizeUsingNSImage:(NSSize)targetSize NS_SWIFT_NAME(imageByScalingProportionallyToSizeUsingNSImage(_:));
@end

@interface NSUserDefaults (OsiriX)
+ (NSDateFormatter*)dateTimeFormatter;
+ (NSString*)formatDateTime:(NSDate*)date;
+ (NSString*)formatDate:(NSDate*)date;
@end

@interface NSManagedObject (N2)
+ (id)UidForXid:(NSString*)xid NS_SWIFT_NAME(uid(forXid:));
@end

/// The database objects, managed objects of entities of no attributes.
@interface DicomStudy : NSManagedObject
@property(retain) NSString *patientUID, *name, *studyInstanceUID, *studyName, *comment, *modality;
@property(retain) NSDate *date, *dateOfBirth;
@property(retain) NSNumber *stateText;
@property(retain) NSArray *harnessSeries, *harnessImages, *harnessExcluded;
@property BOOL harnessHidden, harnessRaises;
- (BOOL) isHidden;
- (void) setHidden:(BOOL)hidden;
- (NSArray*) imageSeriesContainingPixels:(BOOL)pixels;
- (NSArray*) imageSeries;
@end

@interface DicomSeries : NSManagedObject
@property(retain) NSString *name;
@property(retain) NSSet *images;
@property(retain, nonatomic) NSData *thumbnail;
@property(retain) NSData *harnessThumbnail;
@property(retain) NSNumber *noFiles, *rawNoFiles, *harnessID;
@property(retain) NSDate *displayDate;
@property(assign) DicomStudy *study;
@property BOOL harnessExternal;
@end

@interface DicomImage : NSManagedObject
@property(retain) NSString *completePath;
@property(retain) NSNumber *numberOfFrames;
@property(assign) DicomSeries *series;
@end

DicomStudy *NewStudy(NSString *name);
DicomSeries *NewSeries(NSString *name, DicomStudy *study);
DicomImage *NewImage(NSString *name, DicomSeries *series);

@interface DicomDatabase : NSObject
@property BOOL isReadOnlyValue, isLocalValue;
@property(retain) NSArray *harnessStudies;
@property(retain) NSMutableDictionary *harnessLocalCopies, *harnessObjects;
- (NSEntityDescription*) studyEntity;
- (NSArray*) objectsForEntity:(NSEntityDescription*)entity predicate:(NSPredicate*)predicate;
@property(readonly, retain) NSString *dataBaseDirPath;
- (id) objectWithID:(id)objectID;
@property(readonly) BOOL isReadOnly;
- (BOOL) isLocal;
@end

@interface DCMTKQueryNode : NSObject
@property(retain) NSString *harnessUID, *harnessPatientID, *name, *studyName, *modality;
@property(retain) NSDate *harnessDate, *dateOfBirth;
- (NSString*) studyInstanceUID;
- (NSString*) patientID;
- (NSDate*) date;
+ (void) retrieveExcludedSeries:(id)object;
@end

@interface DCMTKStudyQueryNode : DCMTKQueryNode
@end

/// A placeholder of a series a DICOMweb node left out.
NS_SWIFT_NAME(ExcludedSeries)
@interface HorosExcludedSeries : NSObject
- (NSString* _Nonnull) titleWithStudyDate:(NSDate* _Nullable)date NS_SWIFT_NAME(title(studyDate:));
- (NSImage* _Nonnull) imageOfSize:(NSSize)size NS_SWIFT_NAME(image(size:));
@end

@interface O2ViewerThumbnailsMatrixRepresentedObject : NSObject
@property(retain) id object;
@property(retain) NSArray *children;
+ (O2ViewerThumbnailsMatrixRepresentedObject*) object:(id)object NS_SWIFT_NAME(object(_:));
// children: an NSArray? in the app's Swift class, not bridged to [Any].
+ (O2ViewerThumbnailsMatrixRepresentedObject*) object:(id)object children:(id)children NS_SWIFT_NAME(object(_:children:));
@end

@interface ThumbnailCell : NSButtonCell
@property(readonly) BOOL rightClick;
@property BOOL harnessRightClick;
@property(retain, nonatomic) NSColor *frameColor;
@property(nonatomic) NSInteger windowNumber;
+ (float) thumbnailCellWidth;
@end

typedef NS_ENUM(NSInteger, HorosSeriesListPlacement) {
    HorosSeriesListPlacementLeft = 0, HorosSeriesListPlacementRight, HorosSeriesListPlacementTop, HorosSeriesListPlacementBottom
} NS_SWIFT_NAME(SeriesListPlacement);

NS_SWIFT_NAME(SeriesListLayout)
@interface HorosSeriesListLayout : NSObject
+ (HorosSeriesListPlacement) storedPlacementIn:(NSUserDefaults*)defaults NS_SWIFT_NAME(storedPlacement(in:));
+ (void) placeScrollView:(NSScrollView*)scrollView inSplitView:(NSSplitView*)splitView floating:(BOOL)floating visible:(BOOL)visible
          thumbnailWidth:(CGFloat)width placement:(HorosSeriesListPlacement)placement NS_SWIFT_NAME(place(_:in:floating:visible:thumbnailWidth:placement:));
+ (void) layOutMatrix:(NSMatrix*)matrix count:(NSInteger)count placement:(HorosSeriesListPlacement)placement floating:(BOOL)floating
    NS_SWIFT_NAME(layOut(_:count:placement:floating:));
+ (NSCell*) cellOfMatrix:(NSMatrix*)matrix atIndex:(NSInteger)index NS_SWIFT_NAME(cell(of:at:));
+ (void) scrollMatrix:(NSMatrix*)matrix toCellAtIndex:(NSInteger)index NS_SWIFT_NAME(scroll(_:toCellAt:));
+ (CGFloat) thicknessForPlacement:(HorosSeriesListPlacement)placement thumbnailWidth:(CGFloat)width thumbnailHeight:(CGFloat)height
    NS_SWIFT_NAME(thickness(for:thumbnailWidth:thumbnailHeight:));
+ (NSView*) imagePaneOfSplitView:(NSSplitView*)splitView placement:(HorosSeriesListPlacement)placement NS_SWIFT_NAME(imagePane(of:placement:));
+ (CGFloat) listThicknessForDividerPosition:(CGFloat)position inSplitView:(NSSplitView*)splitView placement:(HorosSeriesListPlacement)placement
    NS_SWIFT_NAME(listThickness(forDividerPosition:in:placement:));
+ (CGFloat) dividerPositionForListThickness:(CGFloat)thickness inSplitView:(NSSplitView*)splitView placement:(HorosSeriesListPlacement)placement
    NS_SWIFT_NAME(dividerPosition(forListThickness:in:placement:));
+ (void) setListVisible:(BOOL)visible inSplitView:(NSSplitView*)splitView placement:(HorosSeriesListPlacement)placement thickness:(CGFloat)thickness
    NS_SWIFT_NAME(setListVisible(_:in:placement:thickness:));
+ (void) resizeSubviewsOfSplitView:(NSSplitView*)splitView placement:(HorosSeriesListPlacement)placement thickness:(CGFloat)thickness
    NS_SWIFT_NAME(resizeSubviews(of:placement:thickness:));
+ (BOOL) isListVisibleInSplitView:(NSSplitView*)splitView placement:(HorosSeriesListPlacement)placement thickness:(CGFloat)thickness
    NS_SWIFT_NAME(isListVisible(in:placement:thickness:));
@end
/// What the stand-in layout answers.
extern BOOL harnessListVisible;
extern NSView *harnessImagePane;

NS_SWIFT_NAME(SeriesListIdentification)
@interface HorosSeriesListIdentification : NSObject
@property(class, readonly) NSString *defaultsKey;
+ (BOOL) showsColorsIn:(NSUserDefaults*)defaults NS_SWIFT_NAME(showsColors(in:));
@end

NS_SWIFT_NAME(SeriesListColors)
@interface HorosSeriesListColors : NSObject
@property(class, readonly) NSColor *shown, *fused, *otherStudy;
@end

NS_SWIFT_NAME(AnnotationLevel)
@interface HorosAnnotationLevel : NSObject
@property(class, readonly) BOOL currentLevelShowsPatientName;
@end
extern BOOL harnessShowsPatientName;

@interface ThumbnailsListPanel : NSObject
- (void) setThumbnailsView:(NSScrollView*)view viewer:(ViewerController*)viewer;
@end
extern ThumbnailsListPanel *thumbnailsListPanel[MAXSCREENS];
ThumbnailsListPanel *AppControllerCAPIThumbnailsListPanel(NSInteger index);

@interface XMLController : NSWindowController
+ (XMLController*) windowForViewer:(ViewerController*)viewer NS_SWIFT_NAME(window(for:));
- (nullable instancetype) initWithImage:(DicomImage*)image windowName:(NSString*)name viewer:(ViewerController*)viewer;
@end
extern XMLController *harnessXML;
extern NSInteger harnessXMLCreated;

@interface AppController : NSObject
+ (AppController*) sharedAppController NS_SWIFT_NAME(shared());
- (void) checkAllWindowsAreVisible:(id)sender makeKey:(BOOL)makeKey;
- (IBAction) tileWindows:(id)sender;
@end

@interface PluginManager : NSObject
+ (NSMenu*) fusionPluginsMenu;
@end

@interface BrowserController : NSObject
+ (BrowserController*) currentBrowser;
+ (NSArray*) statesArray;
+ (NSData*) produceJPEGThumbnail:(NSImage*)image;
+ (NSArray<HorosExcludedSeries*>* _Nonnull) horosExcludedSeriesOfLocalStudy:(DicomStudy* _Nonnull)study database:(NSString* _Nonnull)database
    NS_SWIFT_NAME(horosExcludedSeries(ofLocalStudy:database:));
+ (int) _scrollerStyle:(NSScroller*)scroller;
+ (NSArray*) comparativeServers;
+ (NSArray<NSString*>*) DatabaseObjectXIDsPasteboardTypes NS_SWIFT_NAME(databaseObjectXIDsPasteboardTypes());
@property(retain) DicomDatabase *database;
@property(retain) NSString *comparativePatientUID;
@property(retain) NSArray *comparativeStudies;
@property BOOL harnessSelects, isCurrentDatabaseBonjour;
- (BOOL) selectThisStudy:(id)study;
- (NSArray*) childrenArray:(id)item;
- (NSArray*) imagesArray:(id)item preferredObject:(int)preferredObject;
- (BOOL) isUsingExternalViewer:(NSManagedObject*)item NS_SWIFT_NAME(is(usingExternalViewer:));
- (ViewerController*) loadSeries:(NSManagedObject*)curFile :(ViewerController*)viewer :(BOOL)firstViewer keyImagesOnly:(BOOL)keyImages;
- (void) loadNextSeries:(NSManagedObject*)curImage :(long)direction :(ViewerController*)viewer :(BOOL)firstViewer keyImagesOnly:(BOOL)keyImages;
- (void) retrieveComparativeStudy:(DCMTKStudyQueryNode*)study select:(BOOL)select open:(BOOL)open showGUI:(BOOL)showGUI viewer:(ViewerController*)viewer;
- (void) retrieveComparativeStudy:(DCMTKStudyQueryNode*)study select:(BOOL)select open:(BOOL)open;
- (float) fontSize:(NSString*)type;
- (void) databaseOpenStudy:(NSManagedObject*)item;
- (NSString*) getLocalDCMPath:(NSManagedObject*)obj :(long)no;
@end
extern BrowserController *harnessBrowser;
extern BOOL harnessNoBrowser;

/// A slice: its size and whether it loads, as DCMPix.h declares it.
@interface DCMPix : NSObject
@property long pwidth, pheight;
@property BOOL isRGB, notAbleToLoadImage;
@property double pixelSpacingX, pixelSpacingY;
@property(retain) NSString *harnessPath;
- (id) initWithPath:(NSString*)s :(long)pos :(long)tot :(float*)ptr :(long)f :(long)ss isBonjour:(BOOL)hello imageObj:(NSManagedObject*)iO;
- (void) CheckLoad NS_SWIFT_NAME(checkLoad());
- (NSImage*) generateThumbnailImageWithWW:(float)ww WL:(float)wl NS_SWIFT_NAME(generateThumbnailImage(withWW:wl:));
@end

@interface MyPoint : NSObject
@property NSPoint point;
+ (MyPoint*) point:(NSPoint)a NS_SWIFT_NAME(point(_:));
- (void) move:(float)x :(float)y;
@end

@interface ROI : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic) BOOL isLayerOpacityConstant, canColorizeLayer, canResizeLayer;
@property(retain) NSMutableArray *points;
- (NSPoint) centroid;
@end

@interface DCMView : NSView
@property(retain) DCMPix *curDCM;
@property NSInteger curImage;
@property BOOL flippedData;
@property(nonatomic) float scaleValue;
@property(nonatomic) NSPoint origin;
@property(assign) DicomSeries *harnessSeries;
- (DicomSeries*) seriesObj;
- (void) computeColor;
- (NSPoint) ConvertFromNSView2GL:(NSPoint)a NS_SWIFT_NAME(convert(fromNSView2GL:));
+ (NSArray*) PasteboardTypes NS_SWIFT_NAME(pasteboardTypes());
+ (NSArray*) PluginPasteboardTypes NS_SWIFT_NAME(pluginPasteboardTypes());
@end

@interface SeriesView : NSView
@property(retain) NSArray *harnessViews;
- (NSArray*) imageViews;
@end

/// The list's matrix, its scroll view and clip view, the split view.
@interface HarnessClip : NSClipView
@property NSRect harnessBounds;
@end
@interface HarnessMatrix : NSMatrix
@property(retain) NSMutableArray *harnessCells;
@property(retain) HarnessClip *harnessSuperview;
@property NSSize harnessCellSize;
@property(retain) NSCell *harnessSelected;
@end
@interface HarnessScrollView : NSScrollView
@property(retain) HarnessClip *harnessClip;
@property(retain) NSScroller *harnessScroller;
@property BOOL harnessHasScroller;
@end
@interface HarnessSplitView : NSSplitView
@property NSRect harnessFrame;
@property(retain) NSArray *harnessSubviews;
@end

/// What the viewer and its window controller base answer.
@interface HarnessWindowController : NSWindowController
@end

@interface ViewerController : HarnessWindowController {
@public
    BOOL needsToBuildSeriesPopupMenu, needsToBuildSeriesMatrix, matrixPreviewBuilt, windowWillClose, FullScreenOn, displayOnlyKeyImages;
    NSPopUpButton *seriesPopupMenu;
    NSMenuItem *seriesPopupContextualMenu;
    NSMutableArray *fileList[MAX4D], *pixList[MAX4D];
    short maxMovieIndex, curMovieIndex;
    HarnessMatrix *previewMatrix;
    HarnessScrollView *previewMatrixScrollView;
    NSView *previewRootView;
    HarnessSplitView *splitView;
    NSButton *comparativesButton;
    NSWindow *FullScreenWindow;
    SeriesView *seriesView;
    DCMView *imageView;
    NSWindow *blendingTypeWindow;
    NSButton *blendingTypeMultiply, *blendingTypeSubtract, *blendingResample;
    NSSegmentedControl *blendingTypeRGB;
    NSPopUpButton *blendingPlugins;
    ViewerController *blendedWindow;
    float highLighted, direction;
    NSTimer *highLightedTimer, *timer;
    NSSlider *speedSlider, *dcmFrom, *dcmTo, *dcmInterval, *quicktimeFrom, *quicktimeTo, *quicktimeInterval;
    NSNumber *flagListPODComparatives;
}
@property(retain) NSNumber *flagListPODComparatives;
@property(retain) DicomDatabase *database;
@property(retain) DicomSeries *harnessCurrentSeries;
@property(retain) DicomStudy *harnessCurrentStudy;
@property(retain) NSString *harnessStudyUID;
@property(assign) ViewerController *harnessBlending;
@property BOOL harnessFullScreen, harnessImportFails;
@property(readonly) NSButton *blendingTypeMultiply, *blendingTypeSubtract, *blendingResample;
@property(readonly) NSSegmentedControl *blendingTypeRGB;
@property(readonly) NSPopUpButton *blendingPlugins;
+ (NSArray*) studyColors NS_SWIFT_NONISOLATED;
+ (NSMapTable*) horosSeriesWindowColors;
+ (NSMapTable*) horosSeriesWindowNumbers;
+ (NSMutableArray*) getDisplayed2DViewers NS_SWIFT_NONISOLATED;
+ (NSMutableArray*) get2DViewers NS_SWIFT_NONISOLATED;
+ (BOOL) horos_DisplayUseInvertedPolarity;
- (DicomSeries*) currentSeries;
- (DicomStudy*) currentStudy;
- (NSString*) studyInstanceUID;
- (NSArray*) imageViews;
- (DCMView*) imageView;
// -blendingController, and blending(), the Swift name ViewerController+Blending.swift
// gives it. Swift sees -blendingController only on another class, as an AnyObject
// call finds it in the app.
#ifndef HARNESS_SWIFT
- (ViewerController*) blendingController;
#endif
- (ViewerController*) blending;
- (void) refreshToolbar;
- (void) updateNavigator;
- (void) setMovieIndex:(short)i;
- (void) propagateSettings;
- (BOOL) FullScreenON NS_SWIFT_NAME(fullScreenON());
- (void) checkEverythingLoaded;
- (void) setWindowTitle:(id)sender;
- (BOOL) is2DViewer;
- (IBAction) PlayStop:(id)sender NS_SWIFT_NAME(playStop(_:));
- (id) findPlayStopButton;
- (IBAction) speedSliderAction:(id)sender;
- (void) ActivateBlending:(ViewerController*)bC NS_SWIFT_NAME(activateBlending(_:));
- (void) roiLoadFromSeries:(NSString*)filename;
- (ROI*) addLayerRoiToCurrentSliceWithImage:(NSImage*)image referenceFilePath:(NSString*)path layerPixelSpacingX:(float)x layerPixelSpacingY:(float)y;
- (void) selectROI:(ROI*)roi deselectingOther:(BOOL)deselectOther NS_SWIFT_NAME(select(_:deselectingOther:));
- (BOOL) importROIFiles:(NSArray<NSString*>*)paths error:(NSError**)error;
- (void) presentROIImportErrorForPath:(NSString*)path error:(NSError*)error;
- (void) blendingSheetDidEnd:(NSWindow*)sheet returnCode:(int)returnCode contextInfo:(void*)contextInfo;
- (IBAction) endBlendingType:(id)sender;
- (void) horosLoadViewerPanels;
- (NSMutableArray*) pixList;
@end
ViewerController *NewViewer(NSString *name);
/// The viewer the browser opens for a series: one with its list, made by the driver.
extern ViewerController *(*harnessOpenViewer)(NSString *name);

#ifndef HARNESS_SWIFT
// The methods of the blocks, as the former header declared them.
@interface ViewerController (SeriesList)
- (void) buildSeriesPopup;
- (void) loadSelectedSeries:(id)series rightClick:(BOOL)rightClick;
- (IBAction) seriesPopupSelect:(NSMenuItem *)sender;
- (void) matrixPreviewLoadAllSeries:(id)sender;
- (void) excludedSeriesDidChange:(NSNotification*)note;
- (void) matrixPreviewRetrieveExcludedSeries:(id)sender;
- (void) matrixPreviewPressed:(id)sender;
- (BOOL) checkFrameSize;
- (CGFloat) horosSeriesListThickness;
- (void) updateSeriesListMode;
- (void) setMatrixVisible:(BOOL)visible;
- (BOOL) matrixIsVisible;
- (void) autoHideMatrix;
- (NSScrollView*) previewMatrixScrollView;
- (NSView*) previewRootView;
- (void) syncThumbnails;
- (void) ViewBoundsDidChange:(NSNotification*)note;
- (void) ViewFrameDidChange:(NSNotification*)note;
- (NSRect) splitView:(NSSplitView *)s effectiveRect:(NSRect)proposedEffectiveRect forDrawnRect:(NSRect)drawnRect ofDividerAtIndex:(NSInteger)dividerIndex;
- (void) splitViewDidResizeSubviews:(NSNotification *)notification;
- (void) splitViewWillResizeSubviews:(NSNotification *)notification;
- (BOOL) splitView:(NSSplitView *)sender canCollapseSubview:(NSView *)subview;
- (CGFloat) splitView:(NSSplitView *)sender constrainSplitPosition:(CGFloat)proposedPosition ofSubviewAt:(NSInteger)offset;
- (void) splitView:(NSSplitView*)sender resizeSubviewsWithOldSize:(NSSize)oldSize;
- (void) observeScrollerStyleDidChangeNotification:(NSNotification*)n;
- (void) matrixPreviewSwitchHidden:(id)sender;
- (void) checkBuiltMatrixPreview;
- (void) buildMatrixPreview:(BOOL)showSelected;
- (void) buildMatrixPreview;
- (void) matrixPreviewSelectCurrentSeries;
- (void) showCurrentThumbnail:(id)sender;
- (void) updateRepresentedFileName;
- (BOOL) window:(NSWindow *)sender shouldPopUpDocumentPathMenu:(NSMenu *)titleMenu;
- (void) viewXML:(id)sender;
- (void) completeDragOperation:(ViewerController*)vc;
- (BOOL) performDragOperation:(id <NSDraggingInfo>)sender;
- (NSDragOperation) draggingEntered:(id <NSDraggingInfo>)sender;
- (void) draggingExited:(id <NSDraggingInfo>)sender;
- (NSDragOperation) draggingUpdated:(id <NSDraggingInfo>)sender;
- (void) draggingEnded:(id <NSDraggingInfo>)sender;
- (BOOL) prepareForDragOperation:(id <NSDraggingInfo>)sender;
- (float) highLighted;
- (void) highLightTimerFunction:(NSTimer*)theTimer;
- (void) setHighLighted:(float)b;
- (void) mouseMoved;
- (IBAction) setCurrentPosition:(id)sender;
+ (ViewerController *) draggedController;
+ (void) setDraggedController:(ViewerController *)controller;
+ (NSColor*) _selectedItemColor;
+ (NSColor*) _openItemColor;
@end
#endif

// The instance variables, as ViewerController+SwiftIvars.h declares them.
@interface ViewerController (SwiftIvars)
@property(assign) BOOL horos_needsToBuildSeriesPopupMenu, horos_needsToBuildSeriesMatrix, horos_matrixPreviewBuilt, horos_FullScreenOn;
@property(assign) BOOL horos_windowWillClose NS_SWIFT_NONISOLATED;
@property(assign) BOOL horos_displayOnlyKeyImages;
@property(assign) float horos_highLighted, horos_direction;
@property(readonly, nullable) NSPopUpButton* horos_seriesPopupMenu;
@property(retain, nullable) NSMenuItem* horos_seriesPopupContextualMenu;
@property(readonly, nullable) NSButton* horos_comparativesButton;
@property(readonly, nullable) NSView* horos_previewRootView;
@property(readonly, nullable) NSMatrix* horos_previewMatrix;
@property(readonly, nullable) NSScrollView* horos_previewMatrixScrollView;
@property(readonly, nullable) NSSplitView* horos_splitView;
@property(retain, nullable) NSWindow* horos_FullScreenWindow;
@property(retain, nullable) SeriesView* horos_seriesView NS_SWIFT_NONISOLATED;
@property(retain, nullable) DCMView* horos_imageView NS_SWIFT_NONISOLATED;
@property(readonly, nullable) NSWindow* horos_blendingTypeWindow;
@property(retain, nullable) ViewerController* horos_blendedWindow;
@property(retain, nullable) NSTimer* horos_highLightedTimer;
@property(retain, nullable) NSTimer* horos_timer;
@property(readonly, nullable) NSSlider *horos_speedSlider, *horos_dcmFrom, *horos_dcmTo, *horos_dcmInterval, *horos_quicktimeFrom, *horos_quicktimeTo, *horos_quicktimeInterval;
@property(assign) short horos_curMovieIndex NS_SWIFT_NONISOLATED;
@property(assign) short horos_maxMovieIndex NS_SWIFT_NONISOLATED;
- (nullable NSMutableArray*)horos_fileListAt:(NSInteger)index NS_SWIFT_NAME(horos_fileList(at:)) NS_SWIFT_NONISOLATED;
- (nullable NSMutableArray<DCMPix *>*)horos_pixListAt:(NSInteger)index NS_SWIFT_NAME(horos_pixList(at:)) NS_SWIFT_NONISOLATED;
@end

@interface HarnessBlendingOwner : NSObject
- (ViewerController*) blendingController;
@end

/// A drag: its pasteboard, source and the operations the source offers.
@interface HarnessDrag : NSObject <NSDraggingInfo>
@property(retain) NSPasteboard *harnessPasteboard;
@property(retain) id harnessSource;
@property NSDragOperation harnessMask;
@end

/// A plug-in that performs its own drag.
@interface HarnessPluginSource : NSObject
- (BOOL) performPluginDragOperation:(id <NSDraggingInfo>)sender destination:(ViewerController*)destination;
@end
'''

STUBS = r'''#import "Harness.h"
#import <objc/runtime.h>

NSString* const OsirixPerformDragOperationNotification = @"OsirixPerformDragOperationNotification";

static NSMapTable *names;
NSString *harnessTemporary;
NSMutableArray *harnessWindows = nil;
NSEventModifierFlags harnessModifiers = 0;
BOOL harnessInverted = NO, harnessListVisible = YES, harnessShowsPatientName = YES, harnessNoBrowser = NO;
NSView *harnessImagePane = nil;
BrowserController *harnessBrowser = nil;
XMLController *harnessXML = nil;
NSInteger harnessXMLCreated = 0;
ThumbnailsListPanel *thumbnailsListPanel[MAXSCREENS];

void Register(id object, NSString *name) {
    if (!names) names = [[NSMapTable mapTableWithKeyOptions: NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsStrongMemory
                                                valueOptions: NSPointerFunctionsStrongMemory] retain];
    [names setObject: name forKey: object];
}

static uint64_t Checksum(const void *bytes, size_t length) {
    uint64_t h = 1469598103934665603ULL;
    const unsigned char *p = bytes;
    for (size_t i = 0; i < length; i++) { h ^= p[i]; h *= 1099511628211ULL; }
    return h;
}

static NSString *ColorName(NSColor *color) {
    NSColor *rgb = [color colorUsingColorSpace: [NSColorSpace genericRGBColorSpace]];
    if (!rgb) return [NSString stringWithFormat: @"color(%@)", color.colorSpaceName];
    return [NSString stringWithFormat: @"rgba(%a,%a,%a,%a)", rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent];
}

static NSString *ImageName(NSImage *image) {
    // A picture made here is named by its size and a checksum of its pixels.
    NSInteger w = (NSInteger) image.size.width, h = (NSInteger) image.size.height;
    if (w <= 0 || h <= 0 || w > 400 || h > 400) return [NSString stringWithFormat: @"image(%gx%g)", image.size.width, image.size.height];
    NSBitmapImageRep *rep = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes: NULL pixelsWide: w pixelsHigh: h bitsPerSample: 8 samplesPerPixel: 4
                                                                      hasAlpha: YES isPlanar: NO colorSpaceName: NSDeviceRGBColorSpace bytesPerRow: w * 4 bitsPerPixel: 32] autorelease];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext: [NSGraphicsContext graphicsContextWithBitmapImageRep: rep]];
    [image drawInRect: NSMakeRect(0, 0, w, h) fromRect: NSZeroRect operation: NSCompositingOperationCopy fraction: 1];
    [NSGraphicsContext restoreGraphicsState];
    return [NSString stringWithFormat: @"image(%gx%g %016llx)", image.size.width, image.size.height, Checksum(rep.bitmapData, w * h * 4)];
}

static NSString *AttributesName(NSDictionary *attributes) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *key in [[attributes allKeys] sortedArrayUsingSelector: @selector(compare:)]) {
        id value = [attributes objectForKey: key];
        NSString *v;
        if ([value isKindOfClass: [NSParagraphStyle class]]) v = [NSString stringWithFormat: @"align %ld", (long)[value alignment]];
        else v = Name(value);
        [parts addObject: [NSString stringWithFormat: @"%@:%@", key, v]];
    }
    return [parts componentsJoinedByString: @" "];
}

NSString *Name(id object) {
    if (object == nil) return @"nil";
    if (object == [NSNull null]) return @"null";
    NSString *name = [names objectForKey: object];
    if (name) return name;
    if ([object isKindOfClass: [NSString class]]) {
        NSString *text = [object stringByReplacingOccurrencesOfString: @"\r" withString: @"\\r"];
        if (harnessTemporary) text = [text stringByReplacingOccurrencesOfString: harnessTemporary withString: @"$TMP"];
        return [NSString stringWithFormat: @"\"%@\"", text];
    }
    if ([object isKindOfClass: [NSAttributedString class]]) {
        NSAttributedString *a = object;
        NSMutableArray *runs = [NSMutableArray array];
        [a enumerateAttributesInRange: NSMakeRange(0, a.length) options: 0 usingBlock: ^(NSDictionary *attrs, NSRange range, BOOL *stop) {
            [runs addObject: [NSString stringWithFormat: @"[%lu+%lu %@]", (unsigned long)range.location, (unsigned long)range.length, AttributesName(attrs)]];
        }];
        return [NSString stringWithFormat: @"%@ %@", Name(a.string), [runs componentsJoinedByString: @""]];
    }
    if ([object isKindOfClass: [NSNumber class]]) return [object stringValue];
    if ([object isKindOfClass: [NSDate class]]) return [NSString stringWithFormat: @"date %a", [object timeIntervalSinceReferenceDate]];
    if ([object isKindOfClass: [NSColor class]]) return ColorName(object);
    if ([object isKindOfClass: [NSFont class]]) return [NSString stringWithFormat: @"font(%@ %a)", [object fontName], [object pointSize]];
    if ([object isKindOfClass: [NSImage class]]) return ImageName(object);
    if ([object isKindOfClass: [NSPredicate class]]) return [NSString stringWithFormat: @"predicate(%@)", [object predicateFormat]];
    if ([object isKindOfClass: [O2ViewerThumbnailsMatrixRepresentedObject class]])
        return [NSString stringWithFormat: @"rep(%@ %@)", Name([object object]), Name([object children])];
    if ([object isKindOfClass: [NSArray class]] || [object isKindOfClass: [NSSet class]]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (id item in object) [parts addObject: Name(item)];
        if ([object isKindOfClass: [NSSet class]]) [parts sortUsingSelector: @selector(compare:)];
        return [NSString stringWithFormat: @"[%@]", [parts componentsJoinedByString: @","]];
    }
    if ([object isKindOfClass: [NSDictionary class]]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (id key in [[object allKeys] sortedArrayUsingComparator: ^(id a, id b) { return [Name(a) compare: Name(b)]; }])
            [parts addObject: [NSString stringWithFormat: @"%@=%@", Name(key), Name([object objectForKey: key])]];
        return [NSString stringWithFormat: @"{%@}", [parts componentsJoinedByString: @","]];
    }
    if ([object isKindOfClass: [NSError class]]) return [NSString stringWithFormat: @"error(%@ %ld)", [object domain], (long)[object code]];
    return [NSString stringWithFormat: @"<%@>", NSStringFromClass([object class])];
}

BOOL harnessSilent = NO;
void Record(NSString *line) {
    if (harnessSilent) return;
    printf("%s\n", line.UTF8String);
    fflush(stdout);
}

void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *where) {
    // The category of the reference's blocks is not part of the name.
    NSString *function = [@(where) stringByReplacingOccurrencesOfString: @"(SeriesList)" withString: @""];
    Record([NSString stringWithFormat: @"exception %@ %@ stack %d in %@", e.name, e.reason, logStack, function]);
}

void N2LogStackTrace(NSString *format, ...) {
    va_list list; va_start(list, format);
    NSString *message = [[[NSString alloc] initWithFormat: format arguments: list] autorelease];
    va_end(list);
    Record([NSString stringWithFormat: @"stack trace %@", message]);
}

void ViewerControllerLogStackTrace(NSString *message) { N2LogStackTrace(@"%@", message); }
void N2LogStackTraceMessage(NSString *message) { N2LogStackTrace(@"%@", message); }

@implementation HarnessApplication
- (NSArray*) windows { return harnessWindows; }
- (NSEvent*) currentEvent {
    return [NSEvent keyEventWithType: NSEventTypeKeyDown location: NSZeroPoint modifierFlags: harnessModifiers timestamp: 0 windowNumber: 0
                             context: nil characters: @"x" charactersIgnoringModifiers: @"x" isARepeat: NO keyCode: 7];
}
- (BOOL) sendAction:(SEL)action to:(id)target from:(id)sender {
    Record([NSString stringWithFormat: @"sendAction %@ to %@ from %@", NSStringFromSelector(action), Name(target), Name(sender)]);
    return YES;
}
@end

@implementation HarnessWindow
- (BOOL) isVisible { return self.harnessVisible; }
- (BOOL) isKeyWindow { return self.harnessKey; }
- (NSPoint) mouseLocationOutsideOfEventStream { return self.harnessMouse; }
- (void) makeKeyAndOrderFront:(id)sender { Record([NSString stringWithFormat: @"%@ makeKeyAndOrderFront %@", Name(self), Name(sender)]); }
- (void) setRepresentedFilename:(NSString*)path { Record([NSString stringWithFormat: @"%@ representedFilename %@", Name(self), Name(path)]); }
- (void) setAlphaValue:(CGFloat)alpha { Record([NSString stringWithFormat: @"%@ alpha %a", Name(self), alpha]); }
- (void) disableUpdatesUntilFlush { Record([NSString stringWithFormat: @"%@ disableUpdatesUntilFlush", Name(self)]); }
- (NSRect) convertRectFromScreen:(NSRect)rect { return NSMakeRect(40, 30, 0, 0); }
- (void) beginSheet:(NSWindow*)sheet completionHandler:(void (^)(NSModalResponse))handler {
    Record([NSString stringWithFormat: @"%@ beginSheet %@", Name(self), Name(sheet)]);
    if (handler) handler(NSModalResponseOK);
}
@end

HarnessWindow *NewWindow(NSString *name) {
    HarnessWindow *w = [[HarnessWindow alloc] initWithContentRect: NSMakeRect(0, 0, 10, 10) styleMask: NSWindowStyleMaskBorderless backing: NSBackingStoreBuffered defer: YES];
    w.releasedWhenClosed = NO;
    w.title = name;
    Register(w, name);
    return w;
}

@interface NSString (N2)
- (NSString *)stringByTruncatingToLength:(NSInteger)theWidth;
@end
@implementation NSString (N2)
- (NSString *)stringByTruncatingToLength:(NSInteger)theWidth {
    if ((NSInteger) self.length <= theWidth) return self;
    return [[self substringToIndex: theWidth - 3] stringByAppendingString: @"..."];
}
@end
NSString *HarnessTruncate(NSString *string, NSInteger width) { return [string stringByTruncatingToLength: width]; }

TRUNCATE_IMPLEMENTATION

@implementation NSImage (N2)
static NSImage *Derived(NSImage *image, NSString *name, NSSize size) {
    NSImage *d = [[[NSImage alloc] initWithSize: size] autorelease];
    Register(d, name);
    return d;
}
- (NSImage *)imageInverted { return Derived(self, [NSString stringWithFormat: @"inverted(%@)", Name(self)], self.size); }
- (NSImage *)imageByScalingProportionallyUsingNSImage:(float)ratio {
    return Derived(self, [NSString stringWithFormat: @"scaled(%@ %a)", Name(self), ratio], self.size);
}
- (NSImage *)imageByScalingProportionallyToSizeUsingNSImage:(NSSize)targetSize {
    return Derived(self, [NSString stringWithFormat: @"sized(%@ %gx%g)", Name(self), targetSize.width, targetSize.height], targetSize);
}
@end

static NSMutableDictionary *namedImages;
static NSImage *HarnessImageNamed(id self, SEL _cmd, NSString *name) {
    if (!namedImages) namedImages = [NSMutableDictionary new];
    NSImage *image = [namedImages objectForKey: name];
    if (!image) {
        image = [[[NSImage alloc] initWithSize: NSMakeSize(12, 12)] autorelease];
        Register(image, [NSString stringWithFormat: @"named(%@)", name]);
        [namedImages setObject: image forKey: name];
    }
    return image;
}

@implementation NSUserDefaults (OsiriX)
+ (NSDateFormatter*)dateTimeFormatter {
    static NSDateFormatter *formatter;
    if (!formatter) {
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier: @"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT: 0];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm";
    }
    return formatter;
}
+ (NSString*)formatDateTime:(NSDate*)date { return date ? [@"dt " stringByAppendingString: [[self dateTimeFormatter] stringFromDate: date]] : nil; }
+ (NSString*)formatDate:(NSDate*)date { return date ? [@"d " stringByAppendingString: [[self dateTimeFormatter] stringFromDate: date]] : nil; }
@end

@implementation NSManagedObject (N2)
+ (id)UidForXid:(NSString*)xid { return [@"uid:" stringByAppendingString: xid]; }
@end

static NSManagedObjectModel *model;
static NSEntityDescription *Entity(NSString *name, Class class) {
    if (!model) {
        // The model is made whole before its first use: a used model cannot change.
        model = [NSManagedObjectModel new];
        NSMutableArray *entities = [NSMutableArray array];
        for (NSArray *pair in @[@[@"Study", @"DicomStudy"], @[@"Series", @"DicomSeries"], @[@"Image", @"DicomImage"]]) {
            NSEntityDescription *e = [[NSEntityDescription new] autorelease];
            e.name = pair[0];
            e.managedObjectClassName = pair[1];
            [entities addObject: e];
        }
        model.entities = entities;
    }
    return [model.entitiesByName objectForKey: name];
}

@implementation DicomStudy
@synthesize patientUID, name, studyInstanceUID, studyName, comment, modality, date, dateOfBirth, stateText;
@synthesize harnessSeries, harnessImages, harnessExcluded, harnessHidden, harnessRaises;
- (BOOL) isHidden { return harnessHidden; }
- (void) setHidden:(BOOL)hidden { Record([NSString stringWithFormat: @"%@ setHidden %d", Name(self), hidden]); harnessHidden = hidden; }
- (NSArray*) imageSeriesContainingPixels:(BOOL)pixels { Record([NSString stringWithFormat: @"%@ imageSeriesContainingPixels %d", Name(self), pixels]); return harnessSeries; }
- (NSArray*) imageSeries { Record([NSString stringWithFormat: @"%@ imageSeries", Name(self)]); return harnessSeries; }
@end

@implementation DicomSeries
@synthesize name, images, thumbnail, harnessThumbnail, noFiles, rawNoFiles, harnessID, displayDate, study, harnessExternal;
- (void) setThumbnail:(NSData*)value { Record([NSString stringWithFormat: @"%@ thumbnail %@", Name(self), Name([[[NSString alloc] initWithData: value encoding: NSUTF8StringEncoding] autorelease])]); [value retain]; [thumbnail release]; thumbnail = value; }
- (id) primitiveValueForKey:(NSString*)key { return [key isEqualToString: @"thumbnail"] ? harnessThumbnail : nil; }
- (id) valueForUndefinedKey:(NSString*)key { if ([key isEqualToString: @"id"]) return harnessID; return [super valueForUndefinedKey: key]; }
@end

@implementation DicomImage
@synthesize completePath, numberOfFrames, series;
@end

DicomStudy *NewStudy(NSString *name) {
    DicomStudy *s = [[[DicomStudy alloc] initWithEntity: Entity(@"Study", [DicomStudy class]) insertIntoManagedObjectContext: nil] autorelease];
    Register(s, name);
    return s;
}
DicomSeries *NewSeries(NSString *name, DicomStudy *study) {
    DicomSeries *s = [[[DicomSeries alloc] initWithEntity: Entity(@"Series", [DicomSeries class]) insertIntoManagedObjectContext: nil] autorelease];
    Register(s, name);
    s.study = study;
    return s;
}
DicomImage *NewImage(NSString *name, DicomSeries *series) {
    DicomImage *i = [[[DicomImage alloc] initWithEntity: Entity(@"Image", [DicomImage class]) insertIntoManagedObjectContext: nil] autorelease];
    Register(i, name);
    i.series = series;
    return i;
}

@implementation DicomDatabase
- (NSEntityDescription*) studyEntity { return nil; }
- (NSArray*) objectsForEntity:(NSEntityDescription*)entity predicate:(NSPredicate*)predicate {
    Record([NSString stringWithFormat: @"%@ objectsForEntity %@", Name(self), Name(predicate)]);
    NSString *format = [predicate predicateFormat];
    if ([format hasPrefix: @"studyInstanceUID"]) {
        for (NSString *uid in self.harnessLocalCopies) if ([format rangeOfString: uid].location != NSNotFound) return [self.harnessLocalCopies objectForKey: uid];
        return @[];
    }
    return self.harnessStudies;
}
- (NSString*) dataBaseDirPath { return @"/harness/db"; }
- (id) objectWithID:(id)objectID { Record([NSString stringWithFormat: @"%@ objectWithID %@", Name(self), Name(objectID)]); return [self.harnessObjects objectForKey: objectID]; }
- (BOOL) isReadOnly { return self.isReadOnlyValue; }
- (BOOL) isLocal { return self.isLocalValue; }
@end

@implementation DCMTKQueryNode
- (NSString*) studyInstanceUID { return self.harnessUID; }
- (NSString*) patientID { return self.harnessPatientID; }
- (NSDate*) date { return self.harnessDate; }
+ (void) retrieveExcludedSeries:(id)object { Record([NSString stringWithFormat: @"retrieveExcludedSeries %@", Name(object)]); }
@end

@implementation DCMTKStudyQueryNode
@end

@implementation HorosExcludedSeries
- (NSString*) titleWithStudyDate:(NSDate*)date { return [NSString stringWithFormat: @"%@ of %@", Name(self), Name(date)]; }
- (NSImage*) imageOfSize:(NSSize)size {
    NSImage *image = [[[NSImage alloc] initWithSize: size] autorelease];
    Register(image, [NSString stringWithFormat: @"placeholder(%@ %gx%g)", Name(self), size.width, size.height]);
    return image;
}
@end

@implementation O2ViewerThumbnailsMatrixRepresentedObject
+ (O2ViewerThumbnailsMatrixRepresentedObject*) object:(id)object { return [self object: object children: nil]; }
+ (O2ViewerThumbnailsMatrixRepresentedObject*) object:(id)object children:(id)children {
    O2ViewerThumbnailsMatrixRepresentedObject *o = [[self new] autorelease];
    o.object = object;
    o.children = [[children copy] autorelease];
    return o;
}
@end

#define CELL_SETTER(sel, type, fmt, ...) - (void) sel (type) v { Record([NSString stringWithFormat: @"%@ " #sel " " fmt, Name(self), __VA_ARGS__]); [super sel v]; }
@implementation ThumbnailCell
- (BOOL) rightClick { return self.harnessRightClick; }
+ (float) thumbnailCellWidth { return 104; }
- (void) setFrameColor:(NSColor*)c { Record([NSString stringWithFormat: @"%@ frameColor %@", Name(self), Name(c)]); [c retain]; [_frameColor release]; _frameColor = c; }
- (void) setWindowNumber:(NSInteger)n { Record([NSString stringWithFormat: @"%@ windowNumber %ld", Name(self), (long)n]); _windowNumber = n; }
CELL_SETTER(setLineBreakMode:, NSLineBreakMode, @"%ld", (long)v)
CELL_SETTER(setFont:, NSFont*, @"%@", Name(v))
CELL_SETTER(setBackgroundColor:, NSColor*, @"%@", Name(v))
CELL_SETTER(setRepresentedObject:, id, @"%@", Name(v))
CELL_SETTER(setImagePosition:, NSCellImagePosition, @"%ld", (long)v)
CELL_SETTER(setTransparent:, BOOL, @"%d", v)
CELL_SETTER(setEnabled:, BOOL, @"%d", v)
CELL_SETTER(setButtonType:, NSButtonType, @"%ld", (long)v)
CELL_SETTER(setBezelStyle:, NSBezelStyle, @"%ld", (long)v)
CELL_SETTER(setHighlightsBy:, NSCellStyleMask, @"%ld", (long)v)
CELL_SETTER(setImageScaling:, NSImageScaling, @"%ld", (long)v)
CELL_SETTER(setBordered:, BOOL, @"%d", v)
CELL_SETTER(setTitle:, NSString*, @"%@", Name(v))
CELL_SETTER(setAttributedTitle:, NSAttributedString*, @"%@", Name(v))
CELL_SETTER(setImage:, NSImage*, @"%@", Name(v))
CELL_SETTER(setAlternateImage:, NSImage*, @"%@", Name(v))
CELL_SETTER(setTarget:, id, @"%@", Name(v))
- (void) setAction:(SEL)a { Record([NSString stringWithFormat: @"%@ action %@", Name(self), NSStringFromSelector(a)]); [super setAction: a]; }
@end

BOOL harnessListVisible;
static long harnessCells = 0;

@implementation HorosSeriesListLayout
+ (HorosSeriesListPlacement) storedPlacementIn:(NSUserDefaults*)defaults { return [defaults integerForKey: @"HorosSeriesListPlacement"]; }
+ (void) placeScrollView:(NSScrollView*)scrollView inSplitView:(NSSplitView*)splitView floating:(BOOL)floating visible:(BOOL)visible
          thumbnailWidth:(CGFloat)width placement:(HorosSeriesListPlacement)placement {
    Record([NSString stringWithFormat: @"layout place %@ in %@ floating %d visible %d width %a placement %ld", Name(scrollView), Name(splitView), floating, visible, width, (long)placement]);
}
+ (void) layOutMatrix:(HarnessMatrix*)matrix count:(NSInteger)count placement:(HorosSeriesListPlacement)placement floating:(BOOL)floating {
    Record([NSString stringWithFormat: @"layout layOut %@ count %ld placement %ld floating %d", Name(matrix), (long)count, (long)placement, floating]);
    if (![matrix isKindOfClass: [HarnessMatrix class]]) return;
    while ((NSInteger) matrix.harnessCells.count < count) {
        ThumbnailCell *cell = [[ThumbnailCell new] autorelease];
        Register(cell, [NSString stringWithFormat: @"cell%ld", harnessCells++]);
        [matrix.harnessCells addObject: cell];
    }
    while ((NSInteger) matrix.harnessCells.count > count) [matrix.harnessCells removeLastObject];
}
+ (NSCell*) cellOfMatrix:(HarnessMatrix*)matrix atIndex:(NSInteger)index {
    return index >= 0 && index < (NSInteger) matrix.harnessCells.count ? [matrix.harnessCells objectAtIndex: index] : nil;
}
+ (void) scrollMatrix:(NSMatrix*)matrix toCellAtIndex:(NSInteger)index { Record([NSString stringWithFormat: @"layout scroll %@ to %ld", Name(matrix), (long)index]); }
+ (CGFloat) thicknessForPlacement:(HorosSeriesListPlacement)placement thumbnailWidth:(CGFloat)width thumbnailHeight:(CGFloat)height {
    Record([NSString stringWithFormat: @"layout thickness placement %ld width %a height %a", (long)placement, width, height]);
    return placement >= HorosSeriesListPlacementTop ? height + 8 : width + 6;
}
+ (NSView*) imagePaneOfSplitView:(NSSplitView*)splitView placement:(HorosSeriesListPlacement)placement { return harnessImagePane; }
+ (CGFloat) listThicknessForDividerPosition:(CGFloat)position inSplitView:(NSSplitView*)splitView placement:(HorosSeriesListPlacement)placement {
    Record([NSString stringWithFormat: @"layout listThickness %a placement %ld", position, (long)placement]);
    return placement == HorosSeriesListPlacementRight || placement == HorosSeriesListPlacementBottom ? 600 - position - 1 : position;
}
+ (CGFloat) dividerPositionForListThickness:(CGFloat)thickness inSplitView:(NSSplitView*)splitView placement:(HorosSeriesListPlacement)placement {
    Record([NSString stringWithFormat: @"layout dividerPosition %a placement %ld", thickness, (long)placement]);
    return placement == HorosSeriesListPlacementRight || placement == HorosSeriesListPlacementBottom ? 600 - thickness - 1 : thickness;
}
+ (void) setListVisible:(BOOL)visible inSplitView:(NSSplitView*)splitView placement:(HorosSeriesListPlacement)placement thickness:(CGFloat)thickness {
    Record([NSString stringWithFormat: @"layout setListVisible %d in %@ placement %ld thickness %a", visible, Name(splitView), (long)placement, thickness]);
    harnessListVisible = visible;
}
+ (void) resizeSubviewsOfSplitView:(NSSplitView*)splitView placement:(HorosSeriesListPlacement)placement thickness:(CGFloat)thickness {
    Record([NSString stringWithFormat: @"layout resizeSubviews %@ placement %ld thickness %a", Name(splitView), (long)placement, thickness]);
}
+ (BOOL) isListVisibleInSplitView:(NSSplitView*)splitView placement:(HorosSeriesListPlacement)placement thickness:(CGFloat)thickness {
    return harnessListVisible;
}
@end

@implementation HorosSeriesListIdentification
+ (NSString*) defaultsKey { return @"SeriesListIdentificationMode"; }
+ (BOOL) showsColorsIn:(NSUserDefaults*)defaults { return [defaults integerForKey: @"SeriesListIdentificationMode"] == 0; }
@end

@implementation HorosSeriesListColors
static NSColor *Named(NSString *name, CGFloat r, CGFloat g, CGFloat b) {
    static NSMutableDictionary *colors;
    if (!colors) colors = [NSMutableDictionary new];
    NSColor *c = [colors objectForKey: name];
    if (!c) { c = [NSColor colorWithCalibratedRed: r green: g blue: b alpha: 1]; Register(c, name); [colors setObject: c forKey: name]; }
    return c;
}
+ (NSColor*) shown { return Named(@"shown", 0.9, 0.6, 0.5); }
+ (NSColor*) fused { return Named(@"fused", 0.7, 0.9, 0.5); }
+ (NSColor*) otherStudy { return Named(@"otherStudy", 0.5, 0.5, 0.5); }
@end

@implementation HorosAnnotationLevel
+ (BOOL) currentLevelShowsPatientName { return harnessShowsPatientName; }
@end

@implementation ThumbnailsListPanel
- (void) setThumbnailsView:(NSScrollView*)view viewer:(ViewerController*)viewer { Record([NSString stringWithFormat: @"%@ setThumbnailsView %@ viewer %@", Name(self), Name(view), Name(viewer)]); }
@end
ThumbnailsListPanel *AppControllerCAPIThumbnailsListPanel(NSInteger index) { return thumbnailsListPanel[index]; }

@implementation XMLController
+ (XMLController*) windowForViewer:(ViewerController*)viewer { return harnessXML; }
- (instancetype) initWithImage:(DicomImage*)image windowName:(NSString*)name viewer:(ViewerController*)viewer {
    HarnessWindow *w = NewWindow([NSString stringWithFormat: @"xml window %ld", (long)++harnessXMLCreated]);
    if ((self = [super initWithWindow: w])) Register(self, [NSString stringWithFormat: @"xml %ld", (long)harnessXMLCreated]);
    [w release];
    Record([NSString stringWithFormat: @"XMLController %@ image %@ name %@ viewer %@", Name(self), Name(image), Name(name), Name(viewer)]);
    return self;
}
- (void) dealloc { Record([NSString stringWithFormat: @"%@ dealloc", Name(self)]); [super dealloc]; }
@end

@implementation AppController
+ (AppController*) sharedAppController { static AppController *c; if (!c) { c = [AppController new]; Register(c, @"app"); } return c; }
- (void) checkAllWindowsAreVisible:(id)sender makeKey:(BOOL)makeKey { Record([NSString stringWithFormat: @"checkAllWindowsAreVisible %@ %d", Name(sender), makeKey]); }
- (IBAction) tileWindows:(id)sender { Record([NSString stringWithFormat: @"tileWindows %@", Name(sender)]); }
@end

static NSMenu *fusionMenu;
@implementation PluginManager
+ (NSMenu*) fusionPluginsMenu { return fusionMenu; }
@end

BrowserController *harnessBrowser;
@implementation BrowserController
+ (BrowserController*) currentBrowser { return harnessNoBrowser ? nil : harnessBrowser; }
+ (NSArray*) statesArray { return @[@"empty", @"To Read", @"Read", @"Reported"]; }
+ (NSData*) produceJPEGThumbnail:(NSImage*)image { Record([NSString stringWithFormat: @"produceJPEGThumbnail %@", Name(image)]); return [@"jpeg" dataUsingEncoding: NSUTF8StringEncoding]; }
+ (NSArray<HorosExcludedSeries*>* _Nonnull) horosExcludedSeriesOfLocalStudy:(DicomStudy* _Nonnull)study database:(NSString* _Nonnull)database {
    Record([NSString stringWithFormat: @"horosExcludedSeries %@ %@", Name(study), Name(database)]);
    return study.harnessExcluded ?: @[];
}
static int harnessScrollerStyle = 1;
+ (int) _scrollerStyle:(NSScroller*)scroller { return harnessScrollerStyle; }
+ (NSArray*) comparativeServers { Record(@"comparativeServers"); return @[@"pacs"]; }
+ (NSArray<NSString*>*) DatabaseObjectXIDsPasteboardTypes { return @[@"harness.xids"]; }
- (BOOL) selectThisStudy:(id)study { Record([NSString stringWithFormat: @"selectThisStudy %@", Name(study)]); return self.harnessSelects; }
- (NSArray*) childrenArray:(DicomStudy*)item { Record([NSString stringWithFormat: @"childrenArray %@", Name(item)]); return item.harnessSeries; }
- (NSArray*) imagesArray:(DicomStudy*)item preferredObject:(int)preferredObject {
    Record([NSString stringWithFormat: @"imagesArray %@ %d", Name(item), preferredObject]);
    if (item.harnessRaises) [NSException raise: @"HarnessImages" format: @"images of %@", Name(item)];
    return item.harnessImages;
}
- (BOOL) isUsingExternalViewer:(DicomSeries*)item { Record([NSString stringWithFormat: @"isUsingExternalViewer %@", Name(item)]); return [item isKindOfClass: [DicomSeries class]] && item.harnessExternal; }
static long loadedViewers = 0;
- (ViewerController*) loadSeries:(NSManagedObject*)curFile :(ViewerController*)viewer :(BOOL)firstViewer keyImagesOnly:(BOOL)keyImages {
    Record([NSString stringWithFormat: @"loadSeries %@ viewer %@ first %d keyImages %d", Name(curFile), Name(viewer), firstViewer, keyImages]);
    if (viewer) return viewer;
    return harnessOpenViewer([NSString stringWithFormat: @"loaded viewer %ld", ++loadedViewers]);
}
- (void) loadNextSeries:(NSManagedObject*)curImage :(long)direction :(ViewerController*)viewer :(BOOL)firstViewer keyImagesOnly:(BOOL)keyImages {
    Record([NSString stringWithFormat: @"loadNextSeries %@ %ld viewer %@ first %d keyImages %d", Name(curImage), direction, Name(viewer), firstViewer, keyImages]);
}
- (void) retrieveComparativeStudy:(DCMTKStudyQueryNode*)study select:(BOOL)select open:(BOOL)open showGUI:(BOOL)showGUI viewer:(ViewerController*)viewer {
    Record([NSString stringWithFormat: @"retrieveComparativeStudy %@ select %d open %d showGUI %d viewer %@", Name(study), select, open, showGUI, Name(viewer)]);
}
- (void) retrieveComparativeStudy:(DCMTKStudyQueryNode*)study select:(BOOL)select open:(BOOL)open {
    Record([NSString stringWithFormat: @"retrieveComparativeStudy %@ select %d open %d", Name(study), select, open]);
}
- (float) fontSize:(NSString*)type {
    if ([type isEqualToString: @"dbSmallMatrixFont"]) return 10.5f;
    if ([type isEqualToString: @"viewerNumberFont"]) return 14.25f;
    if ([type isEqualToString: @"viewerSmallCellFont"]) return 9.75f;
    return 12;
}
- (void) databaseOpenStudy:(NSManagedObject*)item { Record([NSString stringWithFormat: @"databaseOpenStudy %@", Name(item)]); }
- (NSString*) getLocalDCMPath:(NSManagedObject*)obj :(long)no {
    Record([NSString stringWithFormat: @"getLocalDCMPath %@ %ld", Name(obj), no]);
    return obj ? [NSString stringWithFormat: @"/path/of/%@", Name(obj)] : nil;
}
@end

@implementation DCMPix
- (id) initWithPath:(NSString*)s :(long)pos :(long)tot :(float*)ptr :(long)f :(long)ss isBonjour:(BOOL)hello imageObj:(NSManagedObject*)iO {
    Record([NSString stringWithFormat: @"DCMPix %@ %ld %ld %d %ld %ld bonjour %d image %@", Name(s), pos, tot, ptr != NULL, f, ss, hello, Name(iO)]);
    if ([s hasSuffix: @"raise"]) [NSException raise: @"HarnessPix" format: @"cannot read %@", s];
    if ([s hasSuffix: @"none"]) { [self release]; return nil; }
    if ((self = [super init])) {
        self.harnessPath = s;
        self.notAbleToLoadImage = [s hasSuffix: @"broken"];
    }
    return self;
}
- (void) CheckLoad { Record([NSString stringWithFormat: @"CheckLoad %@", Name(self.harnessPath)]); }
- (NSImage*) generateThumbnailImageWithWW:(float)ww WL:(float)wl {
    Record([NSString stringWithFormat: @"generateThumbnail %@ %a %a", Name(self.harnessPath), ww, wl]);
    if ([self.harnessPath hasSuffix: @"blank"]) return nil;
    NSImage *image = [[[NSImage alloc] initWithSize: NSMakeSize(64, 64)] autorelease];
    Register(image, [NSString stringWithFormat: @"thumbnail(%@)", self.harnessPath]);
    return image;
}
@end

@implementation MyPoint
+ (MyPoint*) point:(NSPoint)a { MyPoint *p = [[MyPoint new] autorelease]; p.point = a; return p; }
- (void) move:(float)x :(float)y { NSPoint p = self.point; p.x += x; p.y += y; self.point = p; Record([NSString stringWithFormat: @"point move %a %a -> (%a,%a)", x, y, p.x, p.y]); }
@end

@implementation ROI
- (void) setName:(NSString*)n { Record([NSString stringWithFormat: @"%@ name %@", Name(self), Name(n)]); [_name release]; _name = [n copy]; }
- (void) setIsLayerOpacityConstant:(BOOL)v { Record([NSString stringWithFormat: @"%@ isLayerOpacityConstant %d", Name(self), v]); _isLayerOpacityConstant = v; }
- (void) setCanColorizeLayer:(BOOL)v { Record([NSString stringWithFormat: @"%@ canColorizeLayer %d", Name(self), v]); _canColorizeLayer = v; }
- (void) setCanResizeLayer:(BOOL)v { Record([NSString stringWithFormat: @"%@ canResizeLayer %d", Name(self), v]); _canResizeLayer = v; }
- (NSPoint) centroid { return NSMakePoint(3.5, 2.25); }
@end

@implementation DCMView
- (DicomSeries*) seriesObj { return self.harnessSeries; }
- (void) computeColor { Record([NSString stringWithFormat: @"%@ computeColor", Name(self)]); }
- (void) setNeedsDisplay:(BOOL)flag { Record([NSString stringWithFormat: @"%@ needsDisplay %d", Name(self), flag]); }
- (void) displayIfNeeded { Record([NSString stringWithFormat: @"%@ displayIfNeeded", Name(self)]); }
- (void) setScaleValue:(float)v { Record([NSString stringWithFormat: @"%@ scaleValue %a", Name(self), v]); _scaleValue = v; }
- (void) setOrigin:(NSPoint)p { Record([NSString stringWithFormat: @"%@ origin (%a,%a)", Name(self), p.x, p.y]); _origin = p; }
- (NSPoint) ConvertFromNSView2GL:(NSPoint)a { Record([NSString stringWithFormat: @"%@ ConvertFromNSView2GL (%a,%a)", Name(self), a.x, a.y]); return NSMakePoint(a.x * 2, a.y * 2); }
- (NSPoint) convertPoint:(NSPoint)p fromView:(NSView*)view { return NSMakePoint(p.x + 1, p.y + 2); }
+ (NSArray*) PasteboardTypes { return @[@"harness.view"]; }
+ (NSArray*) PluginPasteboardTypes { return @[@"harness.plugin"]; }
@end

@implementation SeriesView
- (NSArray*) imageViews { return self.harnessViews; }
@end

@implementation HarnessClip
- (NSRect) bounds { return self.harnessBounds; }
- (void) scrollToPoint:(NSPoint)p { Record([NSString stringWithFormat: @"%@ scrollToPoint (%a,%a)", Name(self), p.x, p.y]); }
- (NSRect) constrainBoundsRect:(NSRect)r { Record([NSString stringWithFormat: @"%@ constrainBoundsRect %@", Name(self), NSStringFromRect(r)]); return NSOffsetRect(r, 0, 1); }
@end

@implementation HarnessMatrix
- (NSArray*) cells { return self.harnessCells; }
- (NSSize) cellSize { return self.harnessCellSize; }
- (NSView*) superview { return self.harnessSuperview; }
- (NSCell*) selectedCell { return self.harnessSelected; }
- (void) sizeToCells { Record([NSString stringWithFormat: @"%@ sizeToCells", Name(self)]); }
- (void) renewRows:(NSInteger)r columns:(NSInteger)c { Record([NSString stringWithFormat: @"%@ renewRows %ld %ld", Name(self), (long)r, (long)c]); [self.harnessCells removeAllObjects]; }
- (void) setCellClass:(Class)c { Record([NSString stringWithFormat: @"%@ cellClass %@", Name(self), NSStringFromClass(c)]); }
- (void) setNeedsDisplay:(BOOL)flag { Record([NSString stringWithFormat: @"%@ needsDisplay %d", Name(self), flag]); }
@end

@implementation HarnessScrollView
- (NSClipView*) contentView { return self.harnessClip; }
- (NSScroller*) verticalScroller { return self.harnessScroller; }
- (BOOL) hasVerticalScroller { return self.harnessHasScroller; }
- (void) reflectScrolledClipView:(NSClipView*)clip { Record([NSString stringWithFormat: @"%@ reflectScrolledClipView %@", Name(self), Name(clip)]); }
- (void) setPostsBoundsChangedNotifications:(BOOL)flag { Record([NSString stringWithFormat: @"%@ postsBoundsChangedNotifications %d", Name(self), flag]); }
@end

@implementation HarnessSplitView
- (NSRect) frame { return self.harnessFrame; }
- (NSRect) bounds { return NSMakeRect(0, 0, self.harnessFrame.size.width, self.harnessFrame.size.height); }
- (NSArray*) subviews { return self.harnessSubviews; }
- (void) resizeSubviewsWithOldSize:(NSSize)size { Record([NSString stringWithFormat: @"%@ resizeSubviewsWithOldSize %@", Name(self), NSStringFromSize(size)]); }
@end

@implementation HarnessWindowController
- (void) keyDown:(NSEvent*)event { Record([NSString stringWithFormat: @"%@ super keyDown %@", Name(self), Name(event.characters)]); }
- (void) mouseMoved:(NSEvent*)event { Record([NSString stringWithFormat: @"%@ super mouseMoved", Name(self)]); }
@end

static NSMutableArray *viewers;
NSMutableArray *harnessDisplayed;
static NSMapTable *windowColors, *windowNumbers;

@implementation ViewerController
@synthesize flagListPODComparatives, blendingTypeMultiply, blendingTypeSubtract, blendingResample, blendingTypeRGB, blendingPlugins;
+ (NSArray*) studyColors {
    static NSArray *colors;
    if (!colors) {
        NSColor *a = [NSColor colorWithCalibratedRed: 1 green: 0.5 blue: 0.25 alpha: 1], *b = [NSColor colorWithCalibratedRed: 0.25 green: 0.5 blue: 1 alpha: 0.75];
        Register(a, @"study colour 0"); Register(b, @"study colour 1");
        colors = [@[a, b] retain];
    }
    return colors;
}
+ (NSMapTable*) horosSeriesWindowColors { return windowColors; }
+ (NSMapTable*) horosSeriesWindowNumbers { return windowNumbers; }
+ (NSMutableArray*) getDisplayed2DViewers { return harnessDisplayed; }
+ (NSMutableArray*) get2DViewers { return viewers; }
+ (BOOL) horos_DisplayUseInvertedPolarity { return harnessInverted; }
- (DicomSeries*) currentSeries { return self.harnessCurrentSeries; }
- (DicomStudy*) currentStudy { return self.harnessCurrentStudy; }
- (NSString*) studyInstanceUID { return self.harnessStudyUID; }
- (NSArray*) imageViews { return [seriesView imageViews]; }
- (DCMView*) imageView { return imageView; }
- (ViewerController*) blendingController { return self.harnessBlending; }
- (ViewerController*) blending { return self.harnessBlending; }
- (void) refreshToolbar { Record([NSString stringWithFormat: @"%@ refreshToolbar", Name(self)]); }
- (void) updateNavigator { Record([NSString stringWithFormat: @"%@ updateNavigator", Name(self)]); }
- (void) setMovieIndex:(short)i { Record([NSString stringWithFormat: @"%@ setMovieIndex %d (ivar %d)", Name(self), i, curMovieIndex]); curMovieIndex = i; }
- (void) propagateSettings { Record([NSString stringWithFormat: @"%@ propagateSettings", Name(self)]); }
- (BOOL) FullScreenON { return self.harnessFullScreen; }
- (void) checkEverythingLoaded { Record([NSString stringWithFormat: @"%@ checkEverythingLoaded", Name(self)]); }
- (void) setWindowTitle:(id)sender { Record([NSString stringWithFormat: @"%@ setWindowTitle %@", Name(self), Name(sender)]); }
- (BOOL) is2DViewer { return YES; }
- (IBAction) PlayStop:(id)sender { Record([NSString stringWithFormat: @"%@ PlayStop %@", Name(self), Name(sender)]); }
- (id) findPlayStopButton { static NSButton *b; if (!b) { b = [NSButton new]; Register(b, @"play button"); } return b; }
- (IBAction) speedSliderAction:(id)sender { Record([NSString stringWithFormat: @"%@ speedSliderAction %@ speed %a direction %a", Name(self), Name(sender), speedSlider.floatValue, direction]); }
- (void) ActivateBlending:(ViewerController*)bC { Record([NSString stringWithFormat: @"%@ ActivateBlending %@", Name(self), Name(bC)]); }
- (void) roiLoadFromSeries:(NSString*)filename { Record([NSString stringWithFormat: @"%@ roiLoadFromSeries %@", Name(self), Name(filename)]); }
static long layerROIs = 0;
- (ROI*) addLayerRoiToCurrentSliceWithImage:(NSImage*)image referenceFilePath:(NSString*)path layerPixelSpacingX:(float)x layerPixelSpacingY:(float)y {
    ROI *roi = [[ROI new] autorelease];
    Register(roi, [NSString stringWithFormat: @"layer roi %ld", ++layerROIs]);
    roi.points = [NSMutableArray arrayWithObjects: [MyPoint point: NSMakePoint(1, 2)], [MyPoint point: NSMakePoint(5.5, 7)], nil];
    Record([NSString stringWithFormat: @"%@ addLayerRoi %@ size %gx%g path %@ spacing %a %a", Name(self), Name(roi), image.size.width, image.size.height, Name(path), x, y]);
    return roi;
}
- (void) selectROI:(ROI*)roi deselectingOther:(BOOL)deselectOther { Record([NSString stringWithFormat: @"%@ selectROI %@ %d", Name(self), Name(roi), deselectOther]); }
- (BOOL) importROIFiles:(NSArray<NSString*>*)paths error:(NSError**)error {
    Record([NSString stringWithFormat: @"%@ importROIFiles %@", Name(self), Name(paths)]);
    if (self.harnessImportFails) { if (error) *error = [NSError errorWithDomain: @"harness.roi" code: 7 userInfo: nil]; return NO; }
    return YES;
}
- (void) presentROIImportErrorForPath:(NSString*)path error:(NSError*)error { Record([NSString stringWithFormat: @"%@ presentROIImportError %@ %@", Name(self), Name(path), Name(error)]); }
- (void) blendingSheetDidEnd:(NSWindow*)sheet returnCode:(int)returnCode contextInfo:(void*)contextInfo {
    Record([NSString stringWithFormat: @"%@ blendingSheetDidEnd %@ %d", Name(self), Name(sheet), returnCode]);
}
- (IBAction) endBlendingType:(id)sender { Record([NSString stringWithFormat: @"%@ endBlendingType %@", Name(self), Name(sender)]); }
- (void) horosLoadViewerPanels { Record([NSString stringWithFormat: @"%@ horosLoadViewerPanels", Name(self)]); }
- (NSMutableArray*) pixList { return pixList[curMovieIndex]; }

IVAR_IMPLEMENTATIONS
@end

ViewerController *(*harnessOpenViewer)(NSString *name) = NewViewer;

ViewerController *NewViewer(NSString *name) {
    HarnessWindow *w = NewWindow([name stringByAppendingString: @" window"]);
    w.harnessVisible = YES;
    ViewerController *v = [[[ViewerController alloc] initWithWindow: w] autorelease];
    [w release];
    Register(v, name);
    [viewers addObject: v];
    return v;
}

@implementation HarnessDrag
- (NSPasteboard*) draggingPasteboard { return self.harnessPasteboard; }
- (id) draggingSource { return self.harnessSource; }
- (NSDragOperation) draggingSourceOperationMask { return self.harnessMask; }
@end

@implementation HarnessPluginSource
- (BOOL) performPluginDragOperation:(id <NSDraggingInfo>)sender destination:(ViewerController*)destination {
    Record([NSString stringWithFormat: @"plugin performPluginDragOperation %@ destination %@", Name(sender), Name(destination)]);
    return NO;
}
@end

void HarnessSetUp(void) {
    viewers = [NSMutableArray new];
    harnessDisplayed = [NSMutableArray new];
    windowColors = [[NSMapTable strongToStrongObjectsMapTable] retain];
    windowNumbers = [[NSMapTable strongToStrongObjectsMapTable] retain];
    Method m = class_getClassMethod([NSImage class], @selector(imageNamed:));
    method_setImplementation(m, (IMP) HarnessImageNamed);
    for (int i = 0; i < MAXSCREENS; i++) {
        thumbnailsListPanel[i] = [ThumbnailsListPanel new];
        Register(thumbnailsListPanel[i], [NSString stringWithFormat: @"panel %d", i]);
    }
    fusionMenu = [[NSMenu alloc] initWithTitle: @"fusion"];
    [fusionMenu addItemWithTitle: @"Plug A" action: nil keyEquivalent: @""];
    NSMenuItem *group = [fusionMenu addItemWithTitle: @"Group" action: nil keyEquivalent: @""];
    NSMenu *sub = [[[NSMenu alloc] initWithTitle: @"sub"] autorelease];
    [sub addItemWithTitle: @"Plug B" action: nil keyEquivalent: @""];
    [sub addItemWithTitle: @"Plug C" action: nil keyEquivalent: @""];
    group.submenu = sub;
    [fusionMenu addItemWithTitle: @"Plug D" action: nil keyEquivalent: @""];
}

NSMapTable *HarnessWindowColors(void) { return windowColors; }
NSMapTable *HarnessWindowNumbers(void) { return windowNumbers; }
void HarnessSetScrollerStyle(int style) { harnessScrollerStyle = style; }
'''


def accessors():
    """ViewerController (SwiftIvars), implemented over the stand-in's instance variables."""
    implemented = []
    for kind, type_, name in [
            ('assign', 'BOOL', 'needsToBuildSeriesPopupMenu'), ('assign', 'BOOL', 'needsToBuildSeriesMatrix'),
            ('assign', 'BOOL', 'matrixPreviewBuilt'), ('assign', 'BOOL', 'FullScreenOn'), ('assign', 'BOOL', 'windowWillClose'),
            ('assign', 'BOOL', 'displayOnlyKeyImages'), ('assign', 'float', 'highLighted'), ('assign', 'float', 'direction'),
            ('readonly', 'NSPopUpButton*', 'seriesPopupMenu'), ('object', 'NSMenuItem*', 'seriesPopupContextualMenu'),
            ('readonly', 'NSButton*', 'comparativesButton'), ('readonly', 'NSView*', 'previewRootView'),
            ('readonly', 'NSMatrix*', 'previewMatrix'), ('readonly', 'NSScrollView*', 'previewMatrixScrollView'),
            ('readonly', 'NSSplitView*', 'splitView'), ('object', 'NSWindow*', 'FullScreenWindow'), ('object', 'SeriesView*', 'seriesView'),
            ('object', 'DCMView*', 'imageView'), ('readonly', 'NSWindow*', 'blendingTypeWindow'), ('object', 'ViewerController*', 'blendedWindow'),
            ('object', 'NSTimer*', 'highLightedTimer'), ('object', 'NSTimer*', 'timer'), ('readonly', 'NSSlider*', 'speedSlider'),
            ('readonly', 'NSSlider*', 'dcmFrom'), ('readonly', 'NSSlider*', 'dcmTo'), ('readonly', 'NSSlider*', 'dcmInterval'),
            ('readonly', 'NSSlider*', 'quicktimeFrom'), ('readonly', 'NSSlider*', 'quicktimeTo'), ('readonly', 'NSSlider*', 'quicktimeInterval'),
            ('assign', 'short', 'curMovieIndex'), ('assign', 'short', 'maxMovieIndex')]:
        implemented.append('- (%s)horos_%s { return %s; }' % (type_, name, name))
        if kind == 'object':
            implemented.append('- (void)setHoros_%s:(%s)value { [value retain]; [%s release]; %s = value; }' % (name, type_, name, name))
        elif kind == 'assign':
            implemented.append('- (void)setHoros_%s:(%s)value { %s = value; }' % (name, type_, name))
    implemented += ['- (NSMutableArray*)horos_fileListAt:(NSInteger)index { return fileList[index]; }',
                    '- (NSMutableArray*)horos_pixListAt:(NSInteger)index { return pixList[index]; }']
    return '\n'.join(implemented)


STUBS = STUBS.replace('IVAR_IMPLEMENTATIONS', accessors())

DRIVER = r'''#import "Harness.h"

void HarnessSetUp(void);
NSMapTable *HarnessWindowColors(void);
NSMapTable *HarnessWindowNumbers(void);
void HarnessSetScrollerStyle(int style);
extern NSMutableArray *harnessDisplayed;

static NSUserDefaults *defaults;

#define RUN(title, ...) do { Record(@"== " title); @autoreleasepool { @try { __VA_ARGS__ } @catch (NSException *e) { Record([NSString stringWithFormat: @"raised %@ %@", e.name, e.reason]); } } } while (0)

static NSDate *Date(double days) { return [NSDate dateWithTimeIntervalSinceReferenceDate: 800000000 + days * 86400]; }

static NSData *PNG(int seed) {
    NSBitmapImageRep *rep = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes: NULL pixelsWide: 6 pixelsHigh: 5 bitsPerSample: 8 samplesPerPixel: 4
                                                                      hasAlpha: YES isPlanar: NO colorSpaceName: NSDeviceRGBColorSpace bytesPerRow: 24 bitsPerPixel: 32] autorelease];
    for (int i = 0; i < 120; i++) rep.bitmapData[i] = (unsigned char)(i * 7 + seed * 31);
    return [rep representationUsingType: NSBitmapImageFileTypePNG properties: @{}];
}

static void DumpMenu(NSMenu *menu, NSString *indent) {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.isSeparatorItem) { Record([indent stringByAppendingString: @"---"]); continue; }
        Record([NSString stringWithFormat: @"%@item %@ attributed %@ image %@ action %@ target %@ rep %@ state %ld tag %ld", indent, Name(item.title),
                Name(item.attributedTitle), Name(item.image), item.action ? NSStringFromSelector(item.action) : @"nil", Name(item.target),
                Name(item.representedObject), (long)item.state, (long)item.tag]);
        if (item.submenu) DumpMenu(item.submenu, [indent stringByAppendingString: @"  "]);
    }
}

static void DumpViewer(ViewerController *v) {
    NSPopUpButton *popup = v->seriesPopupMenu;
    Record([NSString stringWithFormat: @"%@ popup selected %ld needs popup %d matrix %d built %d", Name(v), (long)popup.indexOfSelectedItem,
            v->needsToBuildSeriesPopupMenu, v->needsToBuildSeriesMatrix, v->matrixPreviewBuilt]);
    DumpMenu(popup.menu, @"  ");
    NSMenuItem *contextual = v->seriesPopupContextualMenu;
    if (contextual) {
        Record([NSString stringWithFormat: @"  contextual %@ image %@", Name(contextual.title), Name(contextual.image)]);
        if (contextual.submenu) DumpMenu(contextual.submenu, @"    ");
    }
    NSButton *b = v->comparativesButton;
    Record([NSString stringWithFormat: @"  comparatives enabled %d title %@ attributed %@ tip %@", b.isEnabled, Name(b.title), Name(b.attributedTitle), Name(b.toolTip)]);
    Record([NSString stringWithFormat: @"  defaults SeriesListVisible %d", [defaults boolForKey: @"SeriesListVisible"]]);
}

static ViewerController *Viewer(NSString *name, DicomSeries *series, int times) {
    harnessSilent = YES;
    ViewerController *v = NewViewer(name);
    v->maxMovieIndex = times;
    for (int t = 0; t < times; t++) {
        NSMutableArray *files = [NSMutableArray array];
        for (int i = 0; i < 3; i++) [files addObject: NewImage([NSString stringWithFormat: @"%@ image %d.%d", name, t, i], series)];
        v->fileList[t] = [files retain];
        NSMutableArray *pixes = [NSMutableArray array];
        for (int i = 0; i < 3; i++) { DCMPix *p = [[DCMPix new] autorelease]; Register(p, [NSString stringWithFormat: @"%@ pix %d.%d", name, t, i]); p.pwidth = 64; p.pheight = 48; [pixes addObject: p]; }
        v->pixList[t] = [pixes retain];
    }
    v->seriesPopupMenu = [[NSPopUpButton alloc] initWithFrame: NSMakeRect(0, 0, 50, 20) pullsDown: NO];
    v->comparativesButton = [[NSButton alloc] initWithFrame: NSMakeRect(0, 0, 50, 20)];
    v->comparativesButton.title = @"Comparatives";
    v->previewMatrix = [[HarnessMatrix alloc] initWithFrame: NSMakeRect(0, 0, 100, 400)];
    Register(v->previewMatrix, [name stringByAppendingString: @" matrix"]);
    v->previewMatrix.harnessCells = [NSMutableArray array];
    v->previewMatrix.harnessCellSize = NSMakeSize(102, 118);
    v->previewMatrix.harnessSuperview = [[HarnessClip alloc] initWithFrame: NSMakeRect(0, 0, 100, 400)];
    Register(v->previewMatrix.harnessSuperview, [name stringByAppendingString: @" matrix clip"]);
    v->previewMatrix.harnessSuperview.harnessBounds = NSMakeRect(0, 37.5, 100, 400);
    v->previewMatrixScrollView = [[HarnessScrollView alloc] initWithFrame: NSMakeRect(0, 0, 100, 400)];
    Register(v->previewMatrixScrollView, [name stringByAppendingString: @" scroll view"]);
    v->previewMatrixScrollView.harnessClip = [[HarnessClip alloc] initWithFrame: NSMakeRect(0, 0, 100, 400)];
    Register(v->previewMatrixScrollView.harnessClip, [name stringByAppendingString: @" clip"]);
    v->previewMatrixScrollView.harnessClip.harnessBounds = NSMakeRect(0, 12, 100, 400);
    v->splitView = [[HarnessSplitView alloc] initWithFrame: NSMakeRect(0, 0, 600, 400)];
    Register(v->splitView, [name stringByAppendingString: @" split"]);
    v->splitView.harnessFrame = NSMakeRect(0, 0, 600, 400);
    NSView *dock = [[[NSView alloc] initWithFrame: NSZeroRect] autorelease], *pane = [[[NSView alloc] initWithFrame: NSZeroRect] autorelease];
    Register(dock, [name stringByAppendingString: @" dock"]); Register(pane, [name stringByAppendingString: @" image pane"]);
    v->splitView.harnessSubviews = @[dock, pane];
    v->previewRootView = [[NSView alloc] initWithFrame: NSZeroRect];
    Register(v->previewRootView, [name stringByAppendingString: @" root view"]);
    v->seriesView = [[SeriesView alloc] initWithFrame: NSZeroRect];
    NSMutableArray *views = [NSMutableArray array];
    for (int i = 0; i < 2; i++) {
        DCMView *view = [[[DCMView alloc] initWithFrame: NSZeroRect] autorelease];
        Register(view, [NSString stringWithFormat: @"%@ view %d", name, i]);
        view.scaleValue = 1.25f + i;
        view.origin = NSMakePoint(3.5 * i, -2);
        view.curDCM = [v->pixList[0] objectAtIndex: 0];
        view.curImage = 1;
        view.harnessSeries = series;
        [views addObject: view];
    }
    v->seriesView.harnessViews = views;
    v->imageView = [[views objectAtIndex: 0] retain];
    v.harnessCurrentSeries = series;
    v.harnessCurrentStudy = series.study;
    v.harnessStudyUID = series.study.studyInstanceUID;
    v->speedSlider = [NSSlider new]; Register(v->speedSlider, @"speed slider");
    for (NSString *n in @[@"dcmFrom", @"dcmTo", @"dcmInterval", @"quicktimeFrom", @"quicktimeTo", @"quicktimeInterval"]) {
        NSSlider *s = [[NSSlider new] autorelease];
        s.minValue = -100; s.maxValue = 100; s.target = nil;
        Register(s, n);
        if ([n isEqualToString: @"dcmFrom"]) v->dcmFrom = [s retain];
        if ([n isEqualToString: @"dcmTo"]) v->dcmTo = [s retain];
        if ([n isEqualToString: @"dcmInterval"]) v->dcmInterval = [s retain];
        if ([n isEqualToString: @"quicktimeFrom"]) v->quicktimeFrom = [s retain];
        if ([n isEqualToString: @"quicktimeTo"]) v->quicktimeTo = [s retain];
        if ([n isEqualToString: @"quicktimeInterval"]) v->quicktimeInterval = [s retain];
    }
    DicomDatabase *db = [[DicomDatabase new] autorelease];
    Register(db, [name stringByAppendingString: @" database"]);
    db.isLocalValue = YES;
    v.database = db;
    [harnessWindows addObject: v.window];
    harnessSilent = NO;
    return v;
}

static ViewerController *OpenedViewer(NSString *name) {
    BOOL silent = harnessSilent;
    ViewerController *v = Viewer(name, nil, 1);
    harnessSilent = silent;
    return v;
}

/// The patient: the viewer's study, an older local study, a newer PACS
/// study, an older PACS study with a local copy, an older one without.
typedef struct { DicomStudy *current, *older, *copy; DCMTKStudyQueryNode *newer, *withCopy, *without, *currentNode; NSArray *currentSeries, *olderSeries; } Patient;

static Patient MakePatient(DicomDatabase *db) {
    Patient p;
    harnessSilent = YES;
    p.current = NewStudy(@"study current");
    p.current.patientUID = @"PAT1"; p.current.name = @"DOE^JANE"; p.current.studyInstanceUID = @"1.2.3"; p.current.studyName = @"CT head and neck with contrast, arterial and venous phases";
    p.current.date = Date(10); p.current.dateOfBirth = Date(-9000); p.current.modality = @"CT"; p.current.comment = @"Follow-up of the nodule seen on the previous examination two years ago";
    p.current.stateText = @2;
    NSMutableArray *series = [NSMutableArray array], *images = [NSMutableArray array];
    NSArray *names = @[@"Axial", @"Coronal reconstruction of the arterial phase", @"Scout", @"Dose report", @"Sagittal reformat 1", @"Multiframe"];
    for (int i = 0; i < (int) names.count; i++) {
        DicomSeries *s = NewSeries([NSString stringWithFormat: @"series %@", names[i]], p.current);
        s.name = names[i];
        s.noFiles = @[@24, @1, @1, @0, @12, @1][i];
        s.rawNoFiles = @[@24, @1, @1, @1, @12, @1][i];
        s.harnessID = @(100 + i);
        s.displayDate = i % 2 ? Date(10.25) : nil;
        DicomImage *image = NewImage([NSString stringWithFormat: @"first image of %@", names[i]], s);
        image.completePath = @[@"/data/axial", @"/data/coronal.broken", @"/data/scout.blank", @"/data/dose.raise", @"/data/sagittal", @"/data/multi"][i];
        image.numberOfFrames = @[@1, @1, @1, @5, @1, @40][i];
        s.images = [NSSet setWithObject: image];
        if (i == 0) s.harnessThumbnail = PNG(1);
        if (i == 4) s.harnessThumbnail = [@"not a picture" dataUsingEncoding: NSUTF8StringEncoding];
        [series addObject: s];
        [images addObject: image];
    }
    p.current.harnessSeries = series;
    p.current.harnessImages = images;
    HorosExcludedSeries *excluded = [[HorosExcludedSeries new] autorelease];
    Register(excluded, @"excluded MR");
    p.current.harnessExcluded = @[excluded];
    p.currentSeries = series;

    p.older = NewStudy(@"study older");
    p.older.patientUID = @"PAT1"; p.older.name = @"DOE^JANE^M"; p.older.studyInstanceUID = @"1.2.1"; p.older.studyName = nil;
    p.older.date = Date(-300); p.older.dateOfBirth = Date(-9000); p.older.modality = nil; p.older.stateText = @9;
    DicomSeries *o1 = NewSeries(@"series older 1", p.older), *o2 = NewSeries(@"series older 2", p.older);
    o1.name = @"Old axial"; o1.noFiles = @2; o1.harnessThumbnail = PNG(2); o1.harnessID = @7;
    o2.name = nil; o2.noFiles = @1; o2.harnessThumbnail = PNG(3); o2.harnessID = @8;
    DicomImage *oi1 = NewImage(@"older image 1", o1), *oi2 = NewImage(@"older image 2", o2);
    o1.images = [NSSet setWithObject: oi1]; o2.images = [NSSet setWithObject: oi2];
    oi2.numberOfFrames = @3;
    p.older.harnessSeries = @[o1, o2];
    p.older.harnessImages = @[oi1];
    p.olderSeries = p.older.harnessSeries;

    p.copy = NewStudy(@"study local copy");
    p.copy.patientUID = @"PAT1"; p.copy.name = @"DOE^JANE"; p.copy.studyInstanceUID = @"1.2.0"; p.copy.date = Date(-500); p.copy.modality = @"MR";
    DicomSeries *c1 = NewSeries(@"series copy", p.copy);
    c1.name = @"Copy T1"; c1.noFiles = @5; c1.harnessThumbnail = PNG(4);
    p.copy.harnessSeries = @[c1];
    p.copy.harnessImages = @[NewImage(@"copy image", c1)];

    p.newer = [[DCMTKStudyQueryNode new] autorelease]; Register(p.newer, @"node newer");
    p.newer.harnessUID = @"1.2.9"; p.newer.harnessPatientID = @"P1"; p.newer.name = @"DOE^JANE"; p.newer.studyName = @"PET whole body"; p.newer.modality = nil;
    p.newer.harnessDate = Date(20); p.newer.dateOfBirth = Date(-9000);
    p.withCopy = [[DCMTKStudyQueryNode new] autorelease]; Register(p.withCopy, @"node with copy");
    p.withCopy.harnessUID = @"1.2.0"; p.withCopy.harnessPatientID = @"P1"; p.withCopy.name = @"SMITH^J"; p.withCopy.studyName = @"MR knee"; p.withCopy.modality = @"MR";
    p.withCopy.harnessDate = Date(-500); p.withCopy.dateOfBirth = Date(-8000);
    p.without = [[DCMTKStudyQueryNode new] autorelease]; Register(p.without, @"node without");
    p.without.harnessUID = @"1.2.5"; p.without.harnessPatientID = @"P1"; p.without.name = @"SMITH^J"; p.without.studyName = nil; p.without.modality = @"US";
    p.without.harnessDate = nil; p.without.dateOfBirth = nil;
    p.currentNode = [[DCMTKStudyQueryNode new] autorelease]; Register(p.currentNode, @"node current");
    p.currentNode.harnessUID = @"1.2.3"; p.currentNode.harnessPatientID = @"P1"; p.currentNode.name = @"DOE^JANE";
    db.harnessLocalCopies = [NSMutableDictionary dictionaryWithObject: @[p.copy] forKey: @"1.2.0"];
    db.harnessStudies = @[p.current, p.older];
    harnessSilent = NO;
    return p;
}

static void SetUpWindows(Patient p, ViewerController *v) {
    NSColor *red = [NSColor colorWithCalibratedRed: 0.8 green: 0.1 blue: 0.1 alpha: 1];
    Register(red, @"window colour red");
    [HarnessWindowColors() setObject: red forKey: p.currentSeries[4]];
    [HarnessWindowNumbers() setObject: @2 forKey: p.currentSeries[4]];
    [HarnessWindowNumbers() setObject: @3 forKey: p.olderSeries[1]];
}

static void Popup(void) {
    RUN("series menu from the database", {
        ViewerController *v0 = Viewer(@"viewer", nil, 1);
        Patient p = MakePatient(v0.database);
        ViewerController *v = Viewer(@"viewer one", p.currentSeries[0], 2);
        harnessBrowser.database = v.database = v0.database;
        [v->fileList[1] replaceObjectAtIndex: 0 withObject: NewImage(@"time 2 image", p.currentSeries[4])];
        SetUpWindows(p, v);
        ViewerController *fused = Viewer(@"fused", p.currentSeries[2], 1);
        v.harnessBlending = fused;
        harnessBrowser.harnessSelects = NO;
        v->needsToBuildSeriesPopupMenu = NO;
        [v buildSeriesPopup];
        DumpViewer(v);
        v->needsToBuildSeriesPopupMenu = YES;
        [v buildSeriesPopup];
        DumpViewer(v);
        // Numbers instead of colours, inverted display, hidden names.
        [defaults setInteger: 1 forKey: @"SeriesListIdentificationMode"];
        [defaults setBool: YES forKey: @"StoreThumbnailsInDB"];
        harnessInverted = YES;
        harnessShowsPatientName = NO;
        p.current.harnessRaises = YES;
        v->needsToBuildSeriesPopupMenu = YES;
        [v buildSeriesPopup];
        DumpViewer(v);
        harnessInverted = NO; harnessShowsPatientName = YES; p.current.harnessRaises = NO;
        [defaults removeObjectForKey: @"SeriesListIdentificationMode"];
        [defaults removeObjectForKey: @"StoreThumbnailsInDB"];
    });
    RUN("series menu from the browser's history of comparatives", {
        ViewerController *v0 = Viewer(@"viewer", nil, 1);
        Patient p = MakePatient(v0.database);
        ViewerController *v = Viewer(@"viewer two", p.currentSeries[1], 1);
        harnessBrowser.database = v.database = v0.database;
        harnessBrowser.comparativePatientUID = @"pat1";
        harnessBrowser.comparativeStudies = @[p.newer, p.currentNode, p.older, p.withCopy, p.without];
        v->needsToBuildSeriesPopupMenu = YES;
        [v buildSeriesPopup];
        DumpViewer(v);
        v.flagListPODComparatives = @YES;
        v->needsToBuildSeriesPopupMenu = YES;
        [v buildSeriesPopup];
        DumpViewer(v);
        // Another patient's history: the database, and the browser selects the study.
        harnessBrowser.comparativePatientUID = @"PAT2";
        harnessBrowser.harnessSelects = YES;
        v->needsToBuildSeriesPopupMenu = YES;
        [v buildSeriesPopup];
        DumpViewer(v);
        // No history patient, the history kept.
        harnessBrowser.comparativePatientUID = nil;
        v->needsToBuildSeriesPopupMenu = YES;
        [v buildSeriesPopup];
        DumpViewer(v);
        harnessBrowser.comparativeStudies = nil;
    });
    RUN("series menu of a study found by name, of no study, of no browser", {
        ViewerController *v0 = Viewer(@"viewer", nil, 1);
        Patient p = MakePatient(v0.database);
        p.current.patientUID = @"0";
        ViewerController *v = Viewer(@"viewer three", p.currentSeries[0], 1);
        harnessBrowser.database = v.database = v0.database;
        v->needsToBuildSeriesPopupMenu = YES;
        [v buildSeriesPopup];
        DumpViewer(v);
        p.current.patientUID = nil;
        p.current.name = nil;
        v->needsToBuildSeriesPopupMenu = YES;
        [v buildSeriesPopup];
        DumpViewer(v);
        ViewerController *lone = Viewer(@"viewer of no study", NewSeries(@"series of no study", nil), 1);
        lone->needsToBuildSeriesPopupMenu = YES;
        [lone buildSeriesPopup];
        DumpViewer(lone);
        harnessNoBrowser = YES;
        v->needsToBuildSeriesPopupMenu = YES;
        [v buildSeriesPopup];
        DumpViewer(v);
        harnessNoBrowser = NO;
    });
}

static void Matrix(void) {
    RUN("series list", {
        ViewerController *v0 = Viewer(@"viewer", nil, 1);
        Patient p = MakePatient(v0.database);
        ViewerController *v = Viewer(@"viewer one", p.currentSeries[0], 2);
        harnessBrowser.database = v.database = v0.database;
        [v->fileList[1] replaceObjectAtIndex: 0 withObject: NewImage(@"time 2 image", p.currentSeries[4])];
        SetUpWindows(p, v);
        v.harnessBlending = Viewer(@"fused", p.olderSeries[0], 1);
        harnessBrowser.comparativePatientUID = @"PAT1";
        harnessBrowser.comparativeStudies = @[p.newer, p.currentNode, p.older, p.withCopy, p.without];
        harnessListVisible = YES;
        // Not shown, then closing.
        ((HarnessWindow*) v.window).harnessVisible = NO;
        [v buildMatrixPreview: YES];
        ((HarnessWindow*) v.window).harnessVisible = YES;
        v->windowWillClose = YES;
        [v buildMatrixPreview: YES];
        v->windowWillClose = NO;
        // The list hidden: only the menu's first item.
        harnessListVisible = NO;
        [v buildMatrixPreview: YES];
        DumpViewer(v);
        harnessListVisible = YES;
        for (int size = -1; size <= 2; size++) {
            Record([NSString stringWithFormat: @"-- dbFontSize %d", size]);
            [defaults setInteger: size forKey: @"dbFontSize"];
            [v buildMatrixPreview: size % 2 == 0];
            DumpViewer(v);
        }
        [defaults removeObjectForKey: @"dbFontSize"];
        // The older study's series hidden; the window colours on its cell.
        p.older.harnessHidden = YES;
        v.harnessBlending = Viewer(@"fused older", p.olderSeries[1], 1);
        [v buildMatrixPreview: NO];
        DumpViewer(v);
        [defaults setInteger: 1 forKey: @"SeriesListIdentificationMode"];
        [v buildMatrixPreview: NO];
        [defaults removeObjectForKey: @"SeriesListIdentificationMode"];
        p.current.harnessHidden = YES;
        [v buildMatrixPreview: NO];
        p.current.harnessHidden = NO;
        p.older.harnessHidden = NO;
        // Listing the comparatives, a read-only database, an inverted display.
        v.flagListPODComparatives = @YES;
        harnessInverted = YES;
        [defaults setBool: YES forKey: @"searchForComparativeStudiesOnDICOMNodes"];
        [v buildMatrixPreview: YES];
        DumpViewer(v);
        v.database.isReadOnlyValue = YES;
        [v buildMatrixPreview: YES];
        harnessInverted = NO;
        [defaults removeObjectForKey: @"searchForComparativeStudiesOnDICOMNodes"];
        // A study of no state.
        p.older.stateText = @0;
        [v buildMatrixPreview: NO];
        p.older.stateText = @9;
        // Only local studies: no comparatives.
        harnessBrowser.comparativeStudies = @[p.current, p.older];
        v.flagListPODComparatives = @NO;
        [v buildMatrixPreview: YES];
        DumpViewer(v);
        // A newer comparative only after a loaded study.
        harnessBrowser.comparativeStudies = @[p.current, p.newer];
        [v buildMatrixPreview: YES];
        DumpViewer(v);
        // An exception in a study's cell, a list shown while building and not after.
        p.current.harnessRaises = YES;
        [v buildMatrixPreview: YES];
        p.current.harnessRaises = NO;
        // The floating list.
        [defaults setBool: YES forKey: @"UseFloatingThumbnailsList"];
        [defaults setInteger: 3 forKey: @"HorosSeriesListPlacement"];
        [v buildMatrixPreview: YES];
        [defaults removeObjectForKey: @"UseFloatingThumbnailsList"];
        [defaults removeObjectForKey: @"HorosSeriesListPlacement"];
        harnessBrowser.comparativeStudies = nil;
        harnessBrowser.comparativePatientUID = nil;
    });
    RUN("series list of no study, a single study, an empty database", {
        ViewerController *lone = Viewer(@"viewer of no study", NewSeries(@"series of no study", nil), 1);
        [lone buildMatrixPreview: YES];
        DumpViewer(lone);
        ViewerController *v0 = Viewer(@"viewer", nil, 1);
        Patient p = MakePatient(v0.database);
        ViewerController *v = Viewer(@"viewer two", p.currentSeries[3], 1);
        harnessBrowser.database = v.database = v0.database;
        v0.database.harnessStudies = @[p.current];
        [v buildMatrixPreview: YES];
        DumpViewer(v);
        v0.database.harnessStudies = @[];
        [v buildMatrixPreview: NO];
        DumpViewer(v);
        [v buildMatrixPreview];
        [v checkBuiltMatrixPreview];
        v->matrixPreviewBuilt = NO;
        ((HarnessWindow*) v.window).harnessKey = YES;
        [v checkBuiltMatrixPreview];
        ((HarnessWindow*) v.window).harnessKey = NO;
        v->matrixPreviewBuilt = NO;
        [v checkBuiltMatrixPreview];
        Record([NSString stringWithFormat: @"colours %@ %@", Name([ViewerController _selectedItemColor]), Name([ViewerController _openItemColor])]);
    });
}

static void Selection(void) {
    RUN("a series chosen", {
        ViewerController *v0 = Viewer(@"viewer", nil, 1);
        Patient p = MakePatient(v0.database);
        harnessBrowser.database = v0.database;
        ViewerController *v = Viewer(@"viewer one", p.currentSeries[0], 2);
        [v->fileList[1] replaceObjectAtIndex: 0 withObject: NewImage(@"time 2 image", p.currentSeries[4])];
        ViewerController *other = Viewer(@"viewer other", p.currentSeries[2], 1);
        [harnessDisplayed addObjectsFromArray: @[v, other]];
        // The current series, another time point, another series.
        [v loadSelectedSeries: p.currentSeries[0] rightClick: NO];
        [v loadSelectedSeries: p.currentSeries[4] rightClick: NO];
        v->curMovieIndex = 0;
        [v loadSelectedSeries: p.currentSeries[1] rightClick: NO];
        // Shown in another window: that window, with the preference or Shift.
        [defaults setBool: YES forKey: @"showWindowInsteadOfSwitching"];
        [v loadSelectedSeries: p.currentSeries[2] rightClick: NO];
        harnessModifiers = NSEventModifierFlagShift;
        [v loadSelectedSeries: p.currentSeries[2] rightClick: NO];
        [defaults removeObjectForKey: @"showWindowInsteadOfSwitching"];
        [v loadSelectedSeries: p.currentSeries[2] rightClick: NO];
        harnessModifiers = 0;
        // An external viewer.
        ((DicomSeries*) p.currentSeries[5]).harnessExternal = YES;
        [v loadSelectedSeries: p.currentSeries[5] rightClick: NO];
        // A study: its first series; a study of none.
        [v loadSelectedSeries: p.older rightClick: NO];
        p.copy.harnessSeries = @[];
        [v loadSelectedSeries: p.copy rightClick: NO];
        // A right click or Command: a new viewer.
        [defaults setBool: YES forKey: @"syncPreviewList"];
        [v loadSelectedSeries: p.currentSeries[1] rightClick: YES];
        Record([NSString stringWithFormat: @"syncPreviewList %d", [defaults boolForKey: @"syncPreviewList"]]);
        [defaults setBool: YES forKey: @"AUTOTILING"];
        [defaults setBool: YES forKey: @"UseFloatingThumbnailsList"];
        harnessModifiers = NSEventModifierFlagCommand;
        [v loadSelectedSeries: p.currentSeries[2] rightClick: NO];
        harnessModifiers = NSEventModifierFlagCommand | NSEventModifierFlagShift;
        [v loadSelectedSeries: p.currentSeries[5] rightClick: NO];
        harnessModifiers = 0;
        [v loadSelectedSeries: p.currentSeries[5] rightClick: YES];
        v->FullScreenOn = YES;
        [v loadSelectedSeries: p.currentSeries[3] rightClick: YES];
        v->FullScreenOn = NO;
        [defaults removeObjectForKey: @"AUTOTILING"];
        [defaults removeObjectForKey: @"UseFloatingThumbnailsList"];
        [defaults removeObjectForKey: @"syncPreviewList"];
        Record([NSString stringWithFormat: @"AUTOHIDEMATRIX %d", [defaults boolForKey: @"AUTOHIDEMATRIX"]]);
    });
    RUN("the menu and the list clicked", {
        ViewerController *v0 = Viewer(@"viewer", nil, 1);
        Patient p = MakePatient(v0.database);
        harnessBrowser.database = v0.database;
        ViewerController *v = Viewer(@"viewer two", p.currentSeries[0], 1);
        [harnessDisplayed addObject: v];
        v->needsToBuildSeriesPopupMenu = YES;
        [v buildSeriesPopup];
        NSMenuItem *item = [[NSMenuItem new] autorelease];
        item.representedObject = [O2ViewerThumbnailsMatrixRepresentedObject object: p.older];
        [v seriesPopupSelect: item];
        item.representedObject = [O2ViewerThumbnailsMatrixRepresentedObject object: p.newer];
        [v seriesPopupSelect: item];
        item.representedObject = [O2ViewerThumbnailsMatrixRepresentedObject object: p.currentSeries[1]];
        [v seriesPopupSelect: item];
        item.representedObject = [O2ViewerThumbnailsMatrixRepresentedObject object: p.current];
        [v seriesPopupSelect: item];
        DumpViewer(v);
        [v matrixPreviewLoadAllSeries: nil];
        // The list's cells.
        ThumbnailCell *cell = [[ThumbnailCell new] autorelease];
        Register(cell, @"clicked cell");
        cell.representedObject = [O2ViewerThumbnailsMatrixRepresentedObject object: p.currentSeries[2]];
        v->previewMatrix.harnessSelected = cell;
        [v matrixPreviewPressed: v->previewMatrix];
        cell.harnessRightClick = YES;
        [v matrixPreviewPressed: v->previewMatrix];
        ViewerController *same = Viewer(@"viewer same study", p.currentSeries[1], 1);
        ViewerController *otherStudy = Viewer(@"viewer other study", p.olderSeries[0], 1);
        same.harnessStudyUID = @"1.2.3";
        [harnessDisplayed addObjectsFromArray: @[same, otherStudy]];
        cell.representedObject = [O2ViewerThumbnailsMatrixRepresentedObject object: p.older];
        [v matrixPreviewSwitchHidden: v->previewMatrix];
        [v matrixPreviewSwitchHidden: v->previewMatrix];
        harnessModifiers = NSEventModifierFlagCommand;
        [v matrixPreviewSwitchHidden: v->previewMatrix];
        harnessModifiers = 0;
        cell.representedObject = [O2ViewerThumbnailsMatrixRepresentedObject object: p.without];
        [v matrixPreviewSwitchHidden: v->previewMatrix];
        cell.representedObject = [O2ViewerThumbnailsMatrixRepresentedObject object: p.currentSeries[0]];
        [v matrixPreviewSwitchHidden: v->previewMatrix];
        HorosExcludedSeries *excluded = p.current.harnessExcluded[0];
        cell.representedObject = [O2ViewerThumbnailsMatrixRepresentedObject object: excluded];
        [v matrixPreviewRetrieveExcludedSeries: v->previewMatrix];
        cell.representedObject = [O2ViewerThumbnailsMatrixRepresentedObject object: p.currentSeries[0]];
        [v matrixPreviewRetrieveExcludedSeries: v->previewMatrix];
        harnessListVisible = NO;
        [v excludedSeriesDidChange: nil];
        harnessListVisible = YES;
        v->windowWillClose = YES;
        [v excludedSeriesDidChange: nil];
        v->windowWillClose = NO;
        [v excludedSeriesDidChange: nil];
        // The current thumbnail.
        [v showCurrentThumbnail: nil];
        [v matrixPreviewSelectCurrentSeries];
        [v->previewMatrix.harnessCells removeAllObjects];
        [v showCurrentThumbnail: nil];
    });
    RUN("the window's file and the DICOM fields", {
        ViewerController *v0 = Viewer(@"viewer", nil, 1);
        Patient p = MakePatient(v0.database);
        harnessBrowser.database = v0.database;
        ViewerController *v = Viewer(@"viewer three", p.currentSeries[0], 1);
        v->imageView.curImage = 2;
        [v updateRepresentedFileName];
        Record([NSString stringWithFormat: @"shouldPopUp %d", [v window: v.window shouldPopUpDocumentPathMenu: [[NSMenu new] autorelease]]]);
        [v viewXML: nil];
        XMLController *made = [XMLController windowForViewer: v];
        Record([NSString stringWithFormat: @"made %@", Name(made)]);
        harnessXML = [[XMLController alloc] initWithImage: nil windowName: @"open" viewer: v];
        [v viewXML: nil];
        harnessXML = nil;
    });
    Record([NSString stringWithFormat: @"xml created %ld", (long)harnessXMLCreated]);
}

static void Dock(void) {
    RUN("thickness, mode and visibility", {
        ViewerController *v0 = Viewer(@"viewer", nil, 1);
        Patient p = MakePatient(v0.database);
        harnessBrowser.database = v0.database;
        ViewerController *v = Viewer(@"viewer one", p.currentSeries[0], 1);
        ViewerController *w = Viewer(@"viewer two", p.currentSeries[1], 1);
        [harnessDisplayed addObjectsFromArray: @[v, w]];
        harnessImagePane = v->splitView.harnessSubviews[1];
        for (int placement = 0; placement < 4; placement++) {
            [defaults setInteger: placement forKey: @"HorosSeriesListPlacement"];
            Record([NSString stringWithFormat: @"thickness %a", [v horosSeriesListThickness]]);
        }
        v->previewMatrix.harnessCellSize = NSMakeSize(90, 0.5);
        Record([NSString stringWithFormat: @"thickness %a", [v horosSeriesListThickness]]);
        v->previewMatrix.harnessCellSize = NSMakeSize(102, 118);
        [defaults setInteger: 1 forKey: @"HorosSeriesListPlacement"];
        harnessListVisible = YES;
        [defaults setBool: YES forKey: @"SeriesListVisible"];
        v->needsToBuildSeriesMatrix = YES;
        [v updateSeriesListMode];
        [v updateSeriesListMode];
        [defaults setBool: YES forKey: @"UseFloatingThumbnailsList"];
        [v updateSeriesListMode];
        [defaults setBool: NO forKey: @"UseFloatingThumbnailsList"];
        [defaults setBool: NO forKey: @"SeriesListVisible"];
        [v updateSeriesListMode];
        v->windowWillClose = YES;
        [v updateSeriesListMode];
        [v setMatrixVisible: YES];
        v->windowWillClose = NO;
        harnessListVisible = NO;
        v->needsToBuildSeriesMatrix = YES;
        [v setMatrixVisible: YES];
        DumpViewer(v);
        [v setMatrixVisible: YES];
        [v setMatrixVisible: NO];
        DumpViewer(v);
        Record([NSString stringWithFormat: @"checkFrameSize %d visible %d", [v checkFrameSize], [v matrixIsVisible]]);
        [defaults setBool: YES forKey: @"UseFloatingThumbnailsList"];
        Record([NSString stringWithFormat: @"floating visible %d", [v matrixIsVisible]]);
        [defaults setBool: NO forKey: @"UseFloatingThumbnailsList"];
        Record([NSString stringWithFormat: @"views %@ %@", Name([v previewMatrixScrollView]), Name([v previewRootView])]);
        // The KVO of the preferences.
        [v observeValueForKeyPath: @"SeriesListIdentificationMode" ofObject: defaults change: @{} context: NULL];
        [v observeValueForKeyPath: @"SeriesListVisible" ofObject: defaults change: @{NSKeyValueChangeNewKey: @1} context: NULL];
        [v observeValueForKeyPath: @"SeriesListVisible" ofObject: defaults change: @{NSKeyValueChangeNewKey: @256} context: NULL];
        [v observeValueForKeyPath: @"Other" ofObject: defaults change: @{NSKeyValueChangeNewKey: @1} context: NULL];
        [defaults setBool: YES forKey: @"UseFloatingThumbnailsList"];
        [v observeValueForKeyPath: @"SeriesListVisible" ofObject: defaults change: @{NSKeyValueChangeNewKey: @0} context: NULL];
        [defaults setBool: NO forKey: @"UseFloatingThumbnailsList"];
        [v observeScrollerStyleDidChangeNotification: nil];
    });
    RUN("the list hidden away from the mouse", {
        ViewerController *v0 = Viewer(@"viewer", nil, 1);
        Patient p = MakePatient(v0.database);
        harnessBrowser.database = v0.database;
        ViewerController *v = Viewer(@"viewer one", p.currentSeries[0], 1);
        HarnessWindow *window = (HarnessWindow*) v.window;
        [v autoHideMatrix];
        [defaults setBool: YES forKey: @"AUTOHIDEMATRIX"];
        NSPoint points[] = {{50, 10}, {115, 10}, {116, 10}, {50, 385}, {50, 395}, {-1, 10}};
        for (int key = 0; key < 2; key++) for (int shown = 0; shown < 2; shown++) for (int i = 0; i < 6; i++) {
            window.harnessKey = key; harnessListVisible = shown; window.harnessMouse = points[i];
            Record([NSString stringWithFormat: @"-- key %d shown %d mouse (%g,%g)", key, shown, points[i].x, points[i].y]);
            [v mouseMoved];
        }
        v.harnessFullScreen = YES;
        HarnessWindow *full = NewWindow(@"full screen window");
        full.harnessMouse = NSMakePoint(400, 10);
        v->FullScreenWindow = full;
        window.harnessVisible = NO;
        harnessListVisible = YES;
        [v mouseMoved];
        v.harnessFullScreen = NO;
        [v mouseMoved];
        window.harnessVisible = YES;
        v->windowWillClose = YES;
        [v mouseMoved];
        [v autoHideMatrix];
        v->windowWillClose = NO;
        [defaults setBool: YES forKey: @"UseFloatingThumbnailsList"];
        [v autoHideMatrix];
        [defaults removeObjectForKey: @"UseFloatingThumbnailsList"];
        [defaults removeObjectForKey: @"AUTOHIDEMATRIX"];
        NSEvent *event = [NSEvent mouseEventWithType: NSEventTypeMouseMoved location: NSZeroPoint modifierFlags: 0 timestamp: 0 windowNumber: 0
                                             context: nil eventNumber: 0 clickCount: 0 pressure: 0];
        [defaults setBool: YES forKey: @"AUTOHIDEMATRIX"];
        harnessListVisible = YES;
        window.harnessKey = NO;
        [v mouseMoved: event];
        [defaults removeObjectForKey: @"AUTOHIDEMATRIX"];
    });
    RUN("the split view's delegate", {
        ViewerController *v0 = Viewer(@"viewer", nil, 1);
        Patient p = MakePatient(v0.database);
        harnessBrowser.database = v0.database;
        ViewerController *v = Viewer(@"viewer one", p.currentSeries[0], 1);
        ViewerController *w = Viewer(@"viewer two", p.currentSeries[1], 1);
        harnessImagePane = v->splitView.harnessSubviews[1];
        NSSplitView *foreign = [[[NSSplitView alloc] initWithFrame: NSZeroRect] autorelease];
        Register(foreign, @"another split view");
        NSNotification *own = [NSNotification notificationWithName: NSSplitViewDidResizeSubviewsNotification object: v->splitView];
        NSNotification *other = [NSNotification notificationWithName: NSSplitViewDidResizeSubviewsNotification object: foreign];
        Record([NSString stringWithFormat: @"effective %@ %@", NSStringFromRect([v splitView: v->splitView effectiveRect: NSMakeRect(1, 2, 3, 4) forDrawnRect: NSZeroRect ofDividerAtIndex: 0]),
                NSStringFromRect([v splitView: foreign effectiveRect: NSMakeRect(1, 2, 3, 4) forDrawnRect: NSZeroRect ofDividerAtIndex: 0])]);
        [defaults setBool: YES forKey: @"UseFloatingThumbnailsList"];
        Record([NSString stringWithFormat: @"effective floating %@", NSStringFromRect([v splitView: v->splitView effectiveRect: NSMakeRect(1, 2, 3, 4) forDrawnRect: NSZeroRect ofDividerAtIndex: 0])]);
        [v splitViewWillResizeSubviews: own];
        [defaults setBool: NO forKey: @"UseFloatingThumbnailsList"];
        [v splitViewWillResizeSubviews: own];
        [v splitViewWillResizeSubviews: other];
        // Resized: the other viewers follow, unless Option, the automatic
        // hiding, the full screen or a resize already in progress.
        harnessListVisible = YES;
        v->needsToBuildSeriesMatrix = YES;
        [v splitViewDidResizeSubviews: own];
        harnessModifiers = NSEventModifierFlagOption;
        [v splitViewDidResizeSubviews: own];
        harnessModifiers = 0;
        [defaults setBool: YES forKey: @"AUTOHIDEMATRIX"];
        [v splitViewDidResizeSubviews: own];
        [defaults removeObjectForKey: @"AUTOHIDEMATRIX"];
        v->FullScreenOn = YES;
        [v splitViewDidResizeSubviews: own];
        v->FullScreenOn = NO;
        [v splitViewDidResizeSubviews: other];
        v->windowWillClose = YES;
        [v splitViewDidResizeSubviews: own];
        [v splitViewWillResizeSubviews: own];
        Record([NSString stringWithFormat: @"constrain closing %a", [v splitView: v->splitView constrainSplitPosition: 77.5 ofSubviewAt: 0]]);
        [v splitView: v->splitView resizeSubviewsWithOldSize: NSMakeSize(1, 1)];
        v->windowWillClose = NO;
        Record([NSString stringWithFormat: @"collapse %d %d %d", [v splitView: v->splitView canCollapseSubview: harnessImagePane],
                [v splitView: v->splitView canCollapseSubview: v->splitView.harnessSubviews[0]], [v splitView: foreign canCollapseSubview: harnessImagePane]]);
        // The divider's snap on every edge, with the scrollers.
        NSScroller *scroller = [[[NSScroller alloc] initWithFrame: NSMakeRect(0, 0, 15, 100)] autorelease];
        v->previewMatrixScrollView.harnessScroller = scroller;
        CGFloat positions[] = {0, 40, 56, 63, 80, 108, 130, 300, 536, 590, -20};
        for (int placement = 0; placement < 4; placement++) for (int style = 0; style < 3; style++) {
            [defaults setInteger: placement forKey: @"HorosSeriesListPlacement"];
            HarnessSetScrollerStyle(style == 0 ? 1 : 0);
            v->previewMatrixScrollView.harnessHasScroller = style != 2;
            scroller.hidden = style == 2;
            for (int i = 0; i < 11; i++)
                Record([NSString stringWithFormat: @"constrain placement %d style %d %a -> %a", placement, style, positions[i],
                        [v splitView: v->splitView constrainSplitPosition: positions[i] ofSubviewAt: 0]]);
        }
        HarnessSetScrollerStyle(1);
        Record([NSString stringWithFormat: @"constrain foreign %a", [v splitView: foreign constrainSplitPosition: 77.5 ofSubviewAt: 0]]);
        [defaults setBool: YES forKey: @"UseFloatingThumbnailsList"];
        Record([NSString stringWithFormat: @"constrain floating %a", [v splitView: v->splitView constrainSplitPosition: 77.5 ofSubviewAt: 0]]);
        [defaults setBool: NO forKey: @"UseFloatingThumbnailsList"];
        for (int placement = 0; placement < 4; placement++) {
            [defaults setInteger: placement forKey: @"HorosSeriesListPlacement"];
            harnessListVisible = placement % 2;
            [v splitView: v->splitView resizeSubviewsWithOldSize: NSMakeSize(1, 1)];
        }
        [v splitView: foreign resizeSubviewsWithOldSize: NSMakeSize(1, 1)];
        v->splitView.harnessFrame = NSMakeRect(0, 0, NAN, 400);
        [v splitView: v->splitView resizeSubviewsWithOldSize: NSMakeSize(1, 1)];
        v->splitView.harnessFrame = NSMakeRect(0, 0, 600, -1);
        [v splitView: v->splitView resizeSubviewsWithOldSize: NSMakeSize(1, 1)];
        v->splitView.harnessFrame = NSMakeRect(0, 0, 600, 400);
        [defaults removeObjectForKey: @"HorosSeriesListPlacement"];
        (void) w;
    });
    RUN("the lists scrolled together", {
        ViewerController *v0 = Viewer(@"viewer", nil, 1);
        Patient p = MakePatient(v0.database);
        harnessBrowser.database = v0.database;
        ViewerController *v = Viewer(@"viewer one", p.currentSeries[0], 1);
        ViewerController *same = Viewer(@"viewer same study", p.currentSeries[1], 1);
        ViewerController *older = Viewer(@"viewer older study", p.olderSeries[0], 1);
        [harnessDisplayed addObjectsFromArray: @[v, same, older]];
        [v syncThumbnails];
        [defaults setBool: YES forKey: @"SyncSeriesListForAllComparativeStudies"];
        [v syncThumbnails];
        [defaults removeObjectForKey: @"SyncSeriesListForAllComparativeStudies"];
        NSNotification *own = [NSNotification notificationWithName: NSViewBoundsDidChangeNotification object: v->previewMatrixScrollView.harnessClip];
        NSNotification *other = [NSNotification notificationWithName: NSViewBoundsDidChangeNotification object: same->previewMatrixScrollView.harnessClip];
        [v ViewBoundsDidChange: other];
        [v ViewBoundsDidChange: own];
        [defaults setBool: YES forKey: @"syncPreviewList"];
        [v ViewBoundsDidChange: own];
        harnessModifiers = NSEventModifierFlagCommand;
        [v ViewBoundsDidChange: own];
        [defaults removeObjectForKey: @"syncPreviewList"];
        [v ViewBoundsDidChange: own];
        harnessModifiers = 0;
        [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 0.3]];
        // The frame of the list's pane.
        NSNotification *pane = [NSNotification notificationWithName: NSViewFrameDidChangeNotification object: v->splitView.harnessSubviews[1]];
        NSNotification *dock = [NSNotification notificationWithName: NSViewFrameDidChangeNotification object: v->splitView.harnessSubviews[0]];
        harnessListVisible = YES;
        v->matrixPreviewBuilt = NO;
        [v ViewFrameDidChange: dock];
        [v ViewFrameDidChange: pane];
        [v ViewFrameDidChange: pane];
        v->matrixPreviewBuilt = NO;
        harnessListVisible = NO;
        [v ViewFrameDidChange: pane];
        v->windowWillClose = YES;
        [v ViewFrameDidChange: pane];
        v->windowWillClose = NO;
        v->splitView.harnessSubviews = @[v->splitView.harnessSubviews[0]];
        [v ViewFrameDidChange: pane];
    });
}

static NSPasteboard *Pasteboard(NSString *type, id value) {
    NSPasteboard *pb = [NSPasteboard pasteboardWithUniqueName];
    [pb declareTypes: @[type] owner: nil];
    // The browser writes the XIDs' plist data as a property list.
    if (value) [pb setPropertyList: value forType: type];
    return pb;
}

static HarnessDrag *Drag(NSPasteboard *pb, id source, NSDragOperation mask) {
    HarnessDrag *d = [[HarnessDrag new] autorelease];
    d.harnessPasteboard = pb;
    d.harnessSource = source;
    d.harnessMask = mask;
    Register(d, @"drag");
    return d;
}

@interface DragObserver : NSObject
@end
@implementation DragObserver
- (void) note:(NSNotification*)n { Record([NSString stringWithFormat: @"notification %@ %@ %@", n.name, Name(n.object), Name(n.userInfo)]); }
@end

static void DragAndDrop(void) {
    RUN("the fusion sheet", {
        ViewerController *v0 = Viewer(@"viewer", nil, 1);
        Patient p = MakePatient(v0.database);
        ViewerController *v = Viewer(@"viewer one", p.currentSeries[0], 1);
        ViewerController *same = Viewer(@"viewer same study", p.currentSeries[1], 1);
        ViewerController *older = Viewer(@"viewer older study", p.olderSeries[0], 1);
        HarnessWindow *sheet = NewWindow(@"blending sheet");
        v->blendingTypeWindow = sheet;
        NSButton *b1 = [[NSButton new] autorelease], *b2 = [[NSButton new] autorelease];
        NSTextField *label = [[NSTextField new] autorelease];
        b1.enabled = NO; b2.enabled = NO;
        Register(b1, @"sheet button 1"); Register(b2, @"sheet button 2"); Register(label, @"sheet label");
        [sheet.contentView addSubview: b1]; [sheet.contentView addSubview: label]; [sheet.contentView addSubview: b2];
        v->blendingTypeMultiply = b1; v->blendingTypeSubtract = b2;
        v->blendingResample = [NSButton new]; Register(v->blendingResample, @"resample");
        v->blendingTypeRGB = [NSSegmentedControl new]; Register(v->blendingTypeRGB, @"rgb");
        v->blendingPlugins = [[NSPopUpButton alloc] initWithFrame: NSZeroRect pullsDown: NO]; Register(v->blendingPlugins, @"plugins");
        NSArray *cases = @[same, older];
        int widths[] = {64, 64, 80, 80, 64, 80}, rgb[] = {0, 0, 0, 0, 1, 1};
        for (int i = 0; i < 6; i++) {
            ViewerController *dropped = cases[i % 2];
            DCMPix *pix = [dropped->pixList[0] objectAtIndex: 0];
            dropped->imageView.curDCM = pix;
            pix.pwidth = widths[i];
            pix.isRGB = rgb[i];
            for (NSControl *c in @[b1, b2, v->blendingResample, v->blendingTypeRGB]) c.enabled = YES;
            [v completeDragOperation: dropped];
            Record([NSString stringWithFormat: @"enabled %d %d %d %d %d blended %@ dragged %@", b1.isEnabled, b2.isEnabled, v->blendingResample.isEnabled,
                    v->blendingTypeRGB.isEnabled, label.isEnabled, Name(v->blendedWindow), Name([ViewerController draggedController])]);
        }
        DumpMenu(v->blendingPlugins.menu, @"  ");
        [ViewerController setDraggedController: v];
        Record([NSString stringWithFormat: @"dragged %@", Name([ViewerController draggedController])]);
        [ViewerController setDraggedController: nil];
    });
    RUN("drops", {
        ViewerController *v0 = Viewer(@"viewer", nil, 1);
        Patient p = MakePatient(v0.database);
        harnessBrowser.database = v0.database;
        ViewerController *v = Viewer(@"viewer one", p.currentSeries[0], 1);
        ViewerController *other = Viewer(@"viewer other", p.currentSeries[1], 1);
        v->blendingTypeWindow = NewWindow(@"blending sheet");
        DragObserver *observer = [[DragObserver new] autorelease];
        [[NSNotificationCenter defaultCenter] addObserver: observer selector: @selector(note:) name: OsirixPerformDragOperationNotification object: nil];
        // An image of another viewer, of a viewer fused with this one, of this one.
        DCMView *source = other->imageView;
        [other.window.contentView addSubview: source];
        Record([NSString stringWithFormat: @"drop view %d", [v performDragOperation: Drag(Pasteboard(@"harness.view", [NSData data]), source, NSDragOperationGeneric)]]);
        other.harnessBlending = v;
        Record([NSString stringWithFormat: @"drop fused view %d", [v performDragOperation: Drag(Pasteboard(@"harness.view", [NSData data]), source, NSDragOperationGeneric)]]);
        other.harnessBlending = nil;
        [v.window.contentView addSubview: v->imageView];
        Record([NSString stringWithFormat: @"drop own view %d", [v performDragOperation: Drag(Pasteboard(@"harness.view", [NSData data]), v->imageView, NSDragOperationGeneric)]]);
        // A plug-in's drag.
        HarnessPluginSource *plugin = [[HarnessPluginSource new] autorelease];
        Register(plugin, @"plugin source");
        Record([NSString stringWithFormat: @"drop plugin %d", [v performDragOperation: Drag(Pasteboard(@"harness.plugin", [NSData data]), plugin, NSDragOperationGeneric)]]);
        Record([NSString stringWithFormat: @"drop plugin of no source %d", [v performDragOperation: Drag(Pasteboard(@"harness.plugin", [NSData data]), nil, NSDragOperationGeneric)]]);
        // A series of the database, a study.
        v0.database.harnessObjects = [NSMutableDictionary dictionaryWithObjectsAndKeys: p.currentSeries[2], @"uid:x1", p.older, @"uid:x2", nil];
        NSData *xids = [NSPropertyListSerialization dataWithPropertyList: @[@"x2", @"x1"] format: NSPropertyListBinaryFormat_v1_0 options: 0 error: NULL];
        Record([NSString stringWithFormat: @"drop series %d", [v performDragOperation: Drag(Pasteboard(@"harness.xids", xids), nil, NSDragOperationGeneric)]]);
        xids = [NSPropertyListSerialization dataWithPropertyList: @[@"x1", @"x2"] format: NSPropertyListBinaryFormat_v1_0 options: 0 error: NULL];
        Record([NSString stringWithFormat: @"drop study %d", [v performDragOperation: Drag(Pasteboard(@"harness.xids", xids), nil, NSDragOperationGeneric)]]);
        // Nothing known.
        Record([NSString stringWithFormat: @"drop text %d", [v performDragOperation: Drag(Pasteboard(NSPasteboardTypeString, @"text"), nil, NSDragOperationGeneric)]]);
        // Files: the viewer the drag came from fuses; this one cancels a fusion.
        NSString *picture = [harnessTemporary stringByAppendingPathComponent: @"picture.png"];
        [PNG(5) writeToFile: picture atomically: YES];
        NSArray *files = @[@"/tmp/a.roi", @"/tmp/b.ROIS_SERIES", @"/tmp/c.json", picture, @"/tmp/not a picture.txt", @"/tmp/d.roi"];
        [ViewerController setDraggedController: other];
        Record([NSString stringWithFormat: @"drop files from other %d", [v performDragOperation: Drag(Pasteboard(@"NSFilenamesPboardType", files), nil, NSDragOperationGeneric)]]);
        Record([NSString stringWithFormat: @"dragged %@", Name([ViewerController draggedController])]);
        [ViewerController setDraggedController: v];
        Record([NSString stringWithFormat: @"drop files from self %d", [v performDragOperation: Drag(Pasteboard(@"NSFilenamesPboardType", files), nil, NSDragOperationGeneric)]]);
        v.harnessImportFails = YES;
        Record([NSString stringWithFormat: @"drop files %d", [v performDragOperation: Drag(Pasteboard(@"NSFilenamesPboardType", @[@"/tmp/e.roi", @"/tmp/f.Roi"]), nil, NSDragOperationGeneric)]]);
        Record([NSString stringWithFormat: @"drop no files %d", [v performDragOperation: Drag(Pasteboard(@"NSFilenamesPboardType", @[]), nil, NSDragOperationGeneric)]]);
        [[NSNotificationCenter defaultCenter] removeObserver: observer];
        // Entered, updated, exited, ended.
        [ViewerController setDraggedController: nil];
        Record([NSString stringWithFormat: @"entered %lu dragged %@", (unsigned long)[v draggingEntered: Drag(nil, nil, NSDragOperationCopy | NSDragOperationGeneric)], Name([ViewerController draggedController])]);
        Record([NSString stringWithFormat: @"entered %lu dragged %@", (unsigned long)[other draggingEntered: Drag(nil, nil, NSDragOperationCopy)], Name([ViewerController draggedController])]);
        Record([NSString stringWithFormat: @"updated %lu %lu", (unsigned long)[v draggingUpdated: Drag(nil, nil, NSDragOperationEvery)], (unsigned long)[v draggingUpdated: Drag(nil, nil, NSDragOperationMove)]]);
        [v draggingExited: nil];
        [v draggingEnded: nil];
        Record([NSString stringWithFormat: @"prepare %d", [v prepareForDragOperation: nil]]);
        [ViewerController setDraggedController: nil];
        // An object the database no longer has: -addObject: of nil raises.
        NSData *missing = [NSPropertyListSerialization dataWithPropertyList: @[@"x3"] format: NSPropertyListBinaryFormat_v1_0 options: 0 error: NULL];
        Record([NSString stringWithFormat: @"drop missing %d", [v performDragOperation: Drag(Pasteboard(@"harness.xids", missing), nil, NSDragOperationGeneric)]]);
    });
}

/// A pasteboard as the database's rows leave it: one item per row, each
/// holding its identifiers' property list as raw data, which the pasteboard
/// hands back as an array.
static NSPasteboard *RowsPasteboard(NSArray<NSArray<NSString*>*> *rows) {
    NSPasteboard *pb = [NSPasteboard pasteboardWithUniqueName];
    [pb clearContents];
    NSMutableArray *items = [NSMutableArray array];
    for (NSArray *row in rows) {
        NSPasteboardItem *item = [[NSPasteboardItem new] autorelease];
        [item setData: [NSPropertyListSerialization dataWithPropertyList: row format: NSPropertyListBinaryFormat_v1_0 options: 0 error: NULL] forType: @"harness.xids"];
        [items addObject: item];
    }
    [pb writeObjects: items];
    return pb;
}

/// Drops of database rows, as the browser writes them. The Objective-C read
/// the pasteboard's first property list as data and raised on the array; this
/// scenario runs on the current tree only, against what it must do.
static void BrowserDrops(void) {
    RUN("browser drops", {
        ViewerController *v0 = Viewer(@"viewer", nil, 1);
        Patient p = MakePatient(v0.database);
        harnessBrowser.database = v0.database;
        ViewerController *v = Viewer(@"viewer one", p.currentSeries[0], 1);
        v0.database.harnessObjects = [NSMutableDictionary dictionaryWithObjectsAndKeys: p.currentSeries[2], @"uid:x1", p.older, @"uid:x2", nil];
        Record([NSString stringWithFormat: @"drop series row %d", [v performDragOperation: Drag(RowsPasteboard(@[@[@"x1"]]), nil, NSDragOperationGeneric)]]);
        Record([NSString stringWithFormat: @"drop study and series rows %d", [v performDragOperation: Drag(RowsPasteboard(@[@[@"x2"], @[@"x1"]]), nil, NSDragOperationGeneric)]]);
        Record([NSString stringWithFormat: @"drop series and study rows %d", [v performDragOperation: Drag(RowsPasteboard(@[@[@"x1"], @[@"x2"]]), nil, NSDragOperationGeneric)]]);
    });
}

static NSEvent *Key(NSString *characters, NSEventModifierFlags flags) {
    return [NSEvent keyEventWithType: NSEventTypeKeyDown location: NSZeroPoint modifierFlags: flags timestamp: 0 windowNumber: 0 context: nil
                          characters: characters charactersIgnoringModifiers: characters isARepeat: NO keyCode: 0];
}

static void Keys(void) {
    RUN("keys", {
        ViewerController *v0 = Viewer(@"viewer", nil, 1);
        Patient p = MakePatient(v0.database);
        harnessBrowser.database = v0.database;
        ViewerController *v = Viewer(@"viewer one", p.currentSeries[0], 3);
        unichar up = NSUpArrowFunctionKey, down = NSDownArrowFunctionKey, left = NSLeftArrowFunctionKey, right = NSRightArrowFunctionKey;
        NSArray *keys = @[@"", @"\r", @" ", @"\x03", @"1", @"4", @"7", @"a", @"d", @"g", @"8", @"h", @"0", @"z",
                          [NSString stringWithCharacters: &up length: 1], [NSString stringWithCharacters: &down length: 1],
                          [NSString stringWithCharacters: &left length: 1], [NSString stringWithCharacters: &right length: 1]];
        for (int timer = 0; timer < 2; timer++) for (NSString *k in keys) {
            v->timer = timer ? [[NSTimer timerWithTimeInterval: 1 repeats: NO block: ^(NSTimer *t) {}] retain] : nil;
            Record([NSString stringWithFormat: @"-- key %@ timer %d time %d", Name(k), timer, v->curMovieIndex]);
            [v keyDown: Key(k, 0)];
            [v keyDown: Key(k, NSEventModifierFlagCommand)];
        }
        v->timer = nil;
        for (int i = 0; i < 4; i++) [v keyDown: Key([NSString stringWithCharacters: &up length: 1], 0)];
        for (int i = 0; i < 4; i++) [v keyDown: Key([NSString stringWithCharacters: &down length: 1], 0)];
        v->maxMovieIndex = 2;
        [v keyDown: Key([NSString stringWithCharacters: &up length: 1], 0)];
        [v keyDown: Key([NSString stringWithCharacters: &down length: 1], 0)];
        v->maxMovieIndex = 1;
        [v keyDown: Key([NSString stringWithCharacters: &up length: 1], 0)];
        [v keyDown: Key([NSString stringWithCharacters: &down length: 1], 0)];
        Record([NSString stringWithFormat: @"speed %a direction %a", v->speedSlider.floatValue, v->direction]);
    });
    RUN("highlight", {
        ViewerController *v0 = Viewer(@"viewer", nil, 1);
        Patient p = MakePatient(v0.database);
        ViewerController *v = Viewer(@"viewer one", p.currentSeries[0], 1);
        Record([NSString stringWithFormat: @"highlighted %a", [v highLighted]]);
        [v setHighLighted: 0.5f];
        [v setHighLighted: 0.5f];
        [v highLightTimerFunction: nil];
        Record([NSString stringWithFormat: @"highlighted %a timer %d", [v highLighted], v->highLightedTimer != nil]);
        [v setHighLighted: 1.0f];
        Record([NSString stringWithFormat: @"timer %d interval %a repeats %d", v->highLightedTimer != nil, v->highLightedTimer.timeInterval, v->highLightedTimer.isValid]);
        // The timer's firings, one by one (fired by hand: the run loop's timing is not the test's).
        for (int i = 0; i < 100 && v->highLightedTimer; i++) {
            NSTimer *t = [v->highLightedTimer retain];
            [t fire];
            Record([NSString stringWithFormat: @"highlighted %a valid %d", [v highLighted], t.isValid]);
            [t release];
        }
        Record([NSString stringWithFormat: @"timer %d", v->highLightedTimer != nil]);
        v->highLighted = 0.02f;
        [v highLightTimerFunction: nil];
        Record([NSString stringWithFormat: @"highlighted %a timer %d", [v highLighted], v->highLightedTimer != nil]);
    });
    RUN("movie export positions", {
        ViewerController *v0 = Viewer(@"viewer", nil, 1);
        Patient p = MakePatient(v0.database);
        ViewerController *v = Viewer(@"viewer one", p.currentSeries[0], 1);
        NSButton *from = [[NSButton new] autorelease], *to = [[NSButton new] autorelease], *other = [[NSButton new] autorelease];
        to.tag = 1;
        other.tag = 2;
        for (int flipped = 0; flipped < 2; flipped++) for (int image = 0; image < 5; image += 2) {
            v->imageView.flippedData = flipped;
            v->imageView.curImage = image;
            [v setCurrentPosition: from];
            [v setCurrentPosition: to];
            [v setCurrentPosition: nil];
            Record([NSString stringWithFormat: @"flipped %d image %d: %d %d %d %d", flipped, image, v->dcmFrom.intValue, v->quicktimeFrom.intValue, v->dcmTo.intValue, v->quicktimeTo.intValue]);
            // A sender of another tag sets the end.
            for (NSSlider *field in @[v->dcmFrom, v->quicktimeFrom, v->dcmTo, v->quicktimeTo]) field.intValue = -7;
            [v setCurrentPosition: other];
            Record([NSString stringWithFormat: @"flipped %d image %d: %d %d %d %d", flipped, image, v->dcmFrom.intValue, v->quicktimeFrom.intValue, v->dcmTo.intValue, v->quicktimeTo.intValue]);
        }
    });
}

int main(int argc, const char **argv) { @autoreleasepool {
    if (argc != 2) return 2;
    [HarnessApplication sharedApplication];
    harnessWindows = [NSMutableArray new];
    defaults = [NSUserDefaults standardUserDefaults];
    NSString *domain = [[NSProcessInfo processInfo] processName];
    [defaults removePersistentDomainForName: domain];
    harnessTemporary = [[NSTemporaryDirectory() stringByAppendingPathComponent: [NSString stringWithFormat: @"series-list-%d", getpid()]] retain];
    [[NSFileManager defaultManager] createDirectoryAtPath: harnessTemporary withIntermediateDirectories: YES attributes: nil error: NULL];
    HarnessSetUp();
    harnessOpenViewer = OpenedViewer;
    harnessBrowser = [BrowserController new];
    Register(harnessBrowser, @"browser");
    NSString *scenario = @(argv[1]);
    int status = 0;
    if ([scenario isEqualToString: @"popup"]) Popup();
    else if ([scenario isEqualToString: @"matrix"]) Matrix();
    else if ([scenario isEqualToString: @"selection"]) Selection();
    else if ([scenario isEqualToString: @"dock"]) Dock();
    else if ([scenario isEqualToString: @"drag"]) DragAndDrop();
    else if ([scenario isEqualToString: @"keys"]) Keys();
    else if ([scenario isEqualToString: @"browserdrop"]) BrowserDrops();
    else status = 3;
    [[NSFileManager defaultManager] removeItemAtPath: harnessTemporary error: NULL];
    [defaults removePersistentDomainForName: domain];
    return status;
} }
'''

# The reference's file-scope declarations, as ViewerController.m had them.
REFERENCE_PRELUDE = '''#import "Harness.h"
#import <objc/runtime.h>
#define DisplayUseInvertedPolarity harnessInverted
@compatibility_alias OSIWindow HarnessWindow;
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
    """The index after the closing brace of the function at `start` (braces counted)."""
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


def objc_blocks(text):
    """Sections 2 and 3 of ViewerController.m, in a category of the stand-in."""
    prelude = []
    for name in ('static void HorosSetThumbnailFrame( NSCell *cell, NSColor *color)', 'static void HorosSetThumbnailWindowNumber( NSCell *cell, NSNumber *number)'):
        a = text.index(name)
        prelude.append(text[a:method_end(text, a)])
    a = text.index('#pragma mark 2. window subdivision')
    b = text.index('#pragma mark-\n#pragma mark 4. toolbox space')
    statics = 'static BOOL ViewBoundsDidChangeProtect = NO;\nstatic NSImage* retrieveImage = nil;\n'
    return (REFERENCE_PRELUDE + statics + '\n'.join(prelude) + '\n@implementation ViewerController (SeriesList)\n' + text[a:b] + '\n@end\n')


def truncate_implementation(text):
    """NSString (Truncate) of ViewerController.m, which the series list calls."""
    a = text.index('@implementation NSString (Truncate)')
    b = text.index('@end', a) + len('@end')
    return 'enum { NSTruncateStart, NSTruncateMiddle, NSTruncateEnd };\n' + text[a:b]


reference = args.reference
if reference is None:
    head = read('HEAD', VC)
    reference = 'HEAD' if head and MARK.encode() in head else history_reference.before_text_removed(VC, MARK)
if reference is None:
    print('skipped: needs the history that has the Objective-C ViewerController.m (a shallow clone does not)')
    sys.exit(2)
reference_vc = read(reference, VC)
if reference_vc is None or MARK.encode() not in reference_vc:
    sys.exit('FAIL: %s has no Objective-C series list in %s' % (reference, VC))
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


with tempfile.TemporaryDirectory(prefix='horos-viewer-series-list-') as tmp:
    folder = Path(tmp)
    (folder / 'Harness.h').write_text(HEADER)
    # NSString (Truncate) is Swift once ViewerController.m is gone (its
    # equivalence is test-viewer-controller-equivalence's): the reference's stands in.
    (folder / 'Stubs.m').write_bytes(STUBS.replace('TRUNCATE_IMPLEMENTATION', truncate_implementation(current_vc if '@implementation NSString (Truncate)' in current_vc else reference_vc)).encode('latin1'))
    (folder / 'Driver.m').write_text(DRIVER)
    for name in ('HorosObjCException.h', 'HorosObjCException.m'):
        (folder / name).write_bytes((ROOT / 'Horos/Sources' / name).read_bytes())
    frameworks = ['-framework', 'Cocoa', '-framework', 'CoreData']

    def clang(source, arc=False, defines=()):
        target = folder / (Path(source).parent.name + '-' + Path(source).stem + '.o')
        run(['xcrun', 'clang', '-c', '-fobjc-arc' if arc else '-fno-objc-arc', '-fblocks', '-fmodules', '-w', *defines, '-I', str(folder),
             str(source), '-o', str(target)], '%s does not compile' % Path(source).name)
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
        # [sender tag] and [sender intValue] as the blocks send them, the @try
        # of the blocks, -addObject: of a nil object, the main actor.
        support = read(args.current, 'Horos/Sources/ViewerController+ImagePipelineSupport.swift').decode('utf-8')
        sender = re.search(r'\nenum ViewerSender \{.*?\n}\n', support, re.S).group(0)
        attempt = re.search(r'\n/// Runs `body` as an @try block.*?\nfunc viewerObjCTry.*?\n}\n', support, re.S).group(0)
        undo = read(args.current, 'Horos/Sources/ViewerController+UndoQueue.swift').decode('utf-8')
        add = re.search(r'\nfunc viewerArrayAdd\(.*?\n}\n', undo, re.S).group(0)
        actors = read(args.current, 'Horos/Sources/MainActorCallbacks.swift').decode('utf-8')
        main_actor = re.search(r'\nfunc onMainActor\(.*?\n}\n', actors, re.S).group(0)
        truncate = ('extension NSString {\n    func stringByTruncating(toLength width: Int) -> NSString {\n'
                    '        HarnessTruncate(self as String, width) as NSString\n    }\n}\n')
        # How a drop reads the database identifiers on a pasteboard, as the
        # app has it (the tree's, once the drop reads them through it).
        drag_export = (read(args.current, 'Horos/Sources/DatabaseDragExport.swift') or b'').decode('utf-8')
        identifiers = re.search(r'\n@objc\(HorosPasteboardObjectIdentifiers\)\npublic final class PasteboardObjectIdentifiers: NSObject \{.*?\n}\n',
                                drag_export, re.S)
        identifiers = identifiers.group(0) if identifiers else ''
        (swift / 'Helpers.swift').write_text('import AppKit\n' + sender + attempt + add + main_actor + truncate + identifiers)
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

    # The retrieve arrow the blocks look for in the main bundle: the programs'
    # folder.
    pdf = subprocess.run(['xcrun', 'clang', '-x', 'objective-c', '-fobjc-arc', '-framework', 'Cocoa', '-o', str(folder / 'make-pdf'), '-'],
                         input='''#import <Cocoa/Cocoa.h>
@interface Arrow : NSView
@end
@implementation Arrow
- (void) drawRect:(NSRect)r { [[NSColor grayColor] set]; NSRectFill(NSMakeRect(2, 2, 20, 30)); }
@end
int main(int argc, const char **argv) { @autoreleasepool {
    Arrow *a = [[Arrow alloc] initWithFrame: NSMakeRect(0, 0, 24, 36)];
    return [[a dataWithPDFInsideRect: a.bounds] writeToFile: @(argv[1]) atomically: YES] ? 0 : 1;
} }
''', capture_output=True, text=True)
    if pdf.returncode or subprocess.run([str(folder / 'make-pdf'), str(folder / 'DownArrowGreyRev.pdf')]).returncode:
        sys.exit('FAIL: the retrieve arrow cannot be made:\n' + pdf.stderr[-2000:])

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
        # While the split view resizes, the Objective-C asked the viewers'
        # former window class to redraw the window (-disableUpdatesUntilFlush);
        # the windows are plain NSWindows now, and the Swift marks the content
        # view itself, which is checked in its source below.
        dock = (ROOT / 'Horos/Sources/ViewerController+SeriesListDock.swift').read_text()
        if 'disableUpdatesUntilFlush' not in dock:
            expected = [line for line in expected if not line.endswith(' disableUpdatesUntilFlush')]
            if scenario == 'dock' and 'self.window?.contentView?.needsDisplay = true' not in dock:
                failures += 1
                print('FAIL: the series list no longer redraws its window while its split view resizes')
        if expected == got:
            print('%s: %d records identical (%s against the Objective-C of %s)' % (scenario, len(expected), current_label, reference))
        else:
            failures += 1
            print('FAIL: %s differs (%s against the Objective-C of %s):' % (scenario, current_label, reference))
            for line in list(difflib.unified_diff(expected, got, 'reference', 'current', lineterm='', n=1))[:60]:
                print('  ' + line)
        if scenario == 'drag':
            reference_drag = results['reference'].splitlines()

    # Rows dropped from the database, as the browser writes them: one
    # pasteboard item per row, which the Objective-C could not read. The
    # series must load as the reference loads the series of its own drop.
    if not current_is_objc:
        result = subprocess.run([str(current_program), 'browserdrop'], capture_output=True, text=True, timeout=60)
        lines = result.stdout.splitlines()
        if args.dump:
            (args.dump / 'browserdrop-current.txt').write_text(result.stdout)
        drop = reference_drag.index('drop series 1')
        expected_load = [line for line in reference_drag[reference_drag.index('== drops'):drop] if line.startswith('loadSeries ')][-1:]

        def block(record):
            if record not in lines:
                return None
            end = lines.index(record)
            start = max(i for i in range(end) if lines[i].startswith('== ') or lines[i].startswith('drop '))
            return lines[start + 1:end]

        problems = []
        if result.returncode or any(line.startswith('raised ') for line in lines):
            problems.append('the drops raised or stopped:\n' + (result.stdout + result.stderr)[-2000:])
        for record, loads in (('drop series row 1', True), ('drop study and series rows 1', True), ('drop series and study rows 1', False)):
            got = block(record)
            if got is None:
                problems.append('no "%s"' % record)
            elif loads and [line for line in got if line.startswith('loadSeries ')] != expected_load:
                problems.append('"%s" does not load the dropped series as %s: %s' % (record, expected_load, got))
            elif not loads and any(line.startswith('loadSeries ') for line in got):
                problems.append('"%s" loads a series although the last row is a study: %s' % (record, got))
        if problems:
            failures += 1
            for problem in problems:
                print('FAIL: browser drops: ' + problem)
        else:
            print('browser drops: the rows of the database load the dropped series, read from every pasteboard item')

    if failures:
        sys.exit(1)
    print('PASS: the series menu, the series list and its dock, the drops, the keys and the highlight are identical to the Objective-C in every scenario')
