#!/usr/bin/env python3
"""The 2D viewer's ROI tools do what their Objective-C did.

The ROI undo and redo, the volumetric lengths (their state, registration,
attachment, snapshot and saving), the parallel, perpendicular and midpoint
of a line and the measure between two points on different slices, the brush
filters and conversions, the SUV of PET series, the calibration warning and
the number it reads, the brush palette and the calcium scoring window moved
from ViewerController.m to Swift extensions of the class, with their pure
rules (the size rule of the undo queue, the pair a measure between slices
joins, the brush filter of a menu item and the resampling of a brush
contour, the SUV conversion, the calibration number) in the IsiXROI and
IsiXImaging modules. This runs the same synthetic viewers through both and
compares everything they produce:

* undo: states of ROIs shared by every slice (aliases, volume lengths),
  undo, redo, the size of the queue and its preferences, an empty queue, a
  state of another kind, a ROI that cannot be copied;
* volumelength: the state of each time point, registration with and
  without an anchor, attachment, addition, snapshots, the ROI archives that
  saving merges (read, identical, unreadable, missing, failing);
* geometry: the constructions of a selected line, of a menu's line, of a
  locked or short line, and the measures between points of this viewer, of
  a blended and of a registered viewer, preferred, selected or not;
* brush: the filters (in parallel), their sheet and radius, the conversions
  of ovals, polygons and brushes, the merge, -convertBrushPolygon:, and the
  operations of pixel fills;
* suv: the SUV sheet, its values, the injection time sheet, the conversion
  of the pixels and of the window in every case, the end of the sheet;
* tools: the brush palette and the calcium scoring window (open, closing),
  the calibration warning, -newROI:, -newPoint::, -roiLock, and the
  calibration number of many entries in several locales.

Floats are compared to the last bit, pixels by a checksum of their bytes.

The reference is the Objective-C of ViewerController.m in the last revision
that has it (history_reference), compiled with clang as Xcode compiles it
(manual retain and release); the other side is the current tree: the Swift
files with IsiXROI and IsiXImaging, compiled with swiftc, with what
ViewerController.m still holds of these methods (-newROI:, -newPoint::), or
the Objective-C again if the tree still has it. Both run over the same
stand-ins of the viewer, its image view, slices, ROIs, panels and the
classes they call, which record what they are given; the two records must be
identical.

    python3 tests/test-viewer-roi-tools-equivalence.py [--reference REV] [--current REV] [--dump DIR]
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
MARK = '- (void) convertPETtoSUV\n{'
SWIFT_FILES = ['ViewerController+%s.swift' % name for name in
               ('UndoQueue', 'VolumeLength', 'ROIGeometry', 'BrushROI', 'ROITools', 'SUV')]
# IsiXLogging first: the others that log write through it.
MODULES = ['IsiXLogging', 'IsiXROI', 'IsiXImaging']
SCENARIOS = ['undo', 'volumelength', 'geometry', 'brush', 'suv', 'tools']

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--reference')
parser.add_argument('--current')
parser.add_argument('--dump', type=Path, help='write the programs and the records of both to this folder')
args = parser.parse_args()

HEADER = r'''#pragma clang diagnostic ignored "-Wnullability-completeness"
#import <Cocoa/Cocoa.h>
#import "HorosObjCException.h"

// The stand-ins of the viewer, its image view, slices, ROIs and panels, and
// of the classes the ROI tools talk to, declared as the app's headers
// declare them (with the Swift names of the app's Swift classes), so that
// the Objective-C and the Swift compile against them alike. They record
// what they are given (Record; Buffer for the operation threads, sorted by
// Flush) and answer from their fields.

#define MAX4D 8

void Record(NSString *line);
void Buffer(NSString *line);
void Flush(void);
NSString *Name(id object);
void Register(id object, NSString *name);

void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *where);
#define N2LogException(e) _N2LogExceptionImpl(e, NO, __PRETTY_FUNCTION__)
#define N2LogExceptionWithStackTrace(e) _N2LogExceptionImpl(e, YES, __PRETTY_FUNCTION__)

extern NSString* const OsirixROIChangeNotification;
extern NSString* const OsirixRemoveROINotification;
extern NSString* const OsirixAddROINotification;
extern NSString* const OsirixUpdateVolumeDataNotification;
extern NSString* const OsirixRecomputeROINotification;

typedef NS_ENUM(short, ToolMode) {
    tWL = 0, tTranslate, tZoom, tRotate, tNext, tMesure, tROI, t3DRotate, tCross, tOval, tOPolygon, tCPolygon,
    tAngle, tText, tArrow, tPencil, t3Dpoint, t3DCut, tCamera3D, t2DPoint, tPlain
};

enum { ROI_sleep = 0, ROI_drawing = 1, ROI_selected = 2, ROI_selectedModify = 3 };

NSInteger HorosRunAlertPanel(NSString *title, NSString *format, NSString *defaultButton, NSString *alternateButton, NSString *otherButton, ...);
NSInteger HorosRunInformationalAlertPanel(NSString *title, NSString *format, NSString *defaultButton, NSString *alternateButton, NSString *otherButton, ...);
NSInteger HorosRunCriticalAlertPanel(NSString *title, NSString *format, NSString *defaultButton, NSString *alternateButton, NSString *otherButton, ...);
enum { HorosAlertDefaultResponse = 1, HorosAlertAlternateResponse = 0, HorosAlertOtherResponse = -1 };

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

/// The response of the next alerts.
extern NSInteger harnessAlertResponse;

@interface NSWindow (N2)
- (void) orderOutAndEndSheet;
- (void) orderOutAndEndSheetWithReturnCode:(NSModalResponse)code NS_SWIFT_NAME(orderOutAndEndSheet(returnCode:));
@end

/// The application: its windows are the harness's, its modal sessions run
/// harnessModal.
@interface HarnessApplication : NSApplication
@end
extern void (^harnessModal)(void);
extern NSMutableArray *harnessWindows;

/// A window that never reaches the window server, whose sheets are recorded.
@interface HarnessWindow : NSWindow
@property(assign) NSWindow *harnessParent;
@end
/// A new window named `name` (+1).
HarnessWindow *NewWindow(NSString *name);

@class ViewerController, DCMView, ROI;

/// A slice: its geometry and PET values, as DCMPix.h declares them.
@interface DCMPix : NSObject {
@public
    float orientationValues[9];
    double originValues[3];
    float philipsFactorValue;
    BOOL hasSUVValue;
}
@property long pwidth, pheight;
@property(setter=setfImage:) float *fImage;
@property(nonatomic, setter=setRGB:) BOOL isRGB;
@property double pixelSpacingX, pixelSpacingY;
@property(readonly) double originX, originY, originZ;
@property(readonly) float philipsFactor;
@property(readonly) BOOL hasSUV;
@property(nonatomic) float patientsWeight, halflife, radionuclideTotalDose, radionuclideTotalDoseCorrected, decayFactor;
@property(nonatomic) float minValueOfSeries, maxValueOfSeries, factorPET2SUV, savedWL, savedWW;
@property(nonatomic, retain) NSDate *acquisitionTime, *radiopharmaceuticalStartTime;
@property(nonatomic) BOOL SUVConverted, displaySUVValue;
@property(retain) NSString *units;
- (void) orientation:(float*)c;
- (void) computePixMinPixMax;
- (void) computeTotalDoseCorrected;
- (void) fillROI:(ROI*)roi newVal:(float)newVal minValue:(float)minValue maxValue:(float)maxValue outside:(BOOL)outside
    orientationStack:(long)orientationStack stackNo:(long)stackNo restore:(BOOL)restore addition:(BOOL)addition
    NS_SWIFT_NAME(fillROI(_:newVal:minValue:maxValue:outside:orientationStack:stackNo:restore:addition:));
+ (NSPoint) originCorrectedAccordingToOrientation:(DCMPix*)pix;
+ (unsigned char*) getMapFromPolygonROI:(ROI*)roi size:(NSSize*)size origin:(NSPoint*)origin NS_SWIFT_NAME(mapFromPolygonROI(_:size:origin:));
@end

@interface MyPoint : NSObject
@property NSPoint point;
+ (MyPoint*) point:(NSPoint)a NS_SWIFT_NAME(point(_:));
- (void) move:(float)x :(float)y;
@end

@interface DCMView : NSView
@property(retain) DCMPix *curDCM;
@property NSInteger curImage;
- (void) roiSet:(ROI*)roi;
- (void) cancelLengthPlacement;
- (void) stopROIEditing;
- (void) stopROIEditingForce:(BOOL)force;
- (void) setIndex:(NSInteger) index;
- (void) getWLWW:(float*)wl :(float*)ww;
- (void) setWLWW:(float)wl :(float)ww;
- (void) updatePresentationStateFromSeries;
@end

/// A ROI, as the app's ROI declares itself to Objective-C.
@interface ROI : NSObject <NSCopying> {
@public
    unsigned char *texture;
    int textureWidthValue, textureHeightValue, cornerX, cornerY;
}
@property(nonatomic) ToolMode type;
@property(nonatomic, retain) NSMutableArray *points;
@property(nonatomic, retain, getter=name, setter=setName:) NSString *nameString;
@property(nonatomic, retain, getter=comments, setter=setComments:) NSString *commentsString;
@property(nonatomic, getter=ROImode, setter=setROIMode:) NSInteger roImode;
@property(nonatomic) BOOL locked, isAliased, isSpline;
@property(nonatomic) NSTimeInterval groupID;
@property(nonatomic) float thickness, opacity;
@property(nonatomic, getter=rgbcolor, setter=setColor:) RGBColor rgbcolor;
@property(nonatomic, assign) DCMView *curView;
@property(nonatomic, setter=setROIRect:) NSRect rect;
@property(nonatomic) double pixelSpacingX, pixelSpacingY;
@property(readonly) unsigned char *textureBuffer;
@property(readonly) int textureWidth, textureHeight, textureUpLeftCornerX, textureUpLeftCornerY;
@property(copy) NSString *label;
@property BOOL harnessCopyFails, harnessReduceEmpty, harnessNoMap;
@property long harnessContour;
- (instancetype) initWithType:(ToolMode)type :(float)sx :(float)sy :(NSPoint)origin;
- (instancetype) initWithTexture:(unsigned char*)t textWidth:(int)w textHeight:(int)h textName:(NSString*)name
    positionX:(int)x positionY:(int)y spacingX:(float)sx spacingY:(float)sy imageOrigin:(NSPoint)o;
- (NSPoint) pointAtIndex:(NSUInteger)index NS_SWIFT_NAME(point(at:));
- (void) addPoint:(NSPoint)point NS_SWIFT_NAME(addPoint(_:));
- (void) mergeWithTexture:(ROI*)r NS_SWIFT_NAME(merge(withTexture:));
- (BOOL) reduceTextureIfPossible;
+ (NSPoint) pointBetweenPoint:(NSPoint)a and:(NSPoint)b ratio:(float)r NS_SWIFT_NAME(pointBetweenPoint(_:and:ratio:));
@end

@interface HorosVolumeLengthROI : ROI
@property(nonatomic, copy) NSDictionary *volumeLength;
@property(readonly) NSString *volumeIdentifier;
@end

@class DicomSeries, DicomStudy;

@interface DicomImage : NSObject {
@public
    NSString *sop;
}
@property(retain) NSNumber *frameID;
@property(retain) DicomSeries *series;
@property(retain) NSObject *objectID;
@property(retain) NSManagedObjectContext *managedObjectContext;
- (NSString*) sopInstanceUID;
@end

@interface DicomSeries : NSObject
@property(retain) DicomStudy *study;
@property(copy) NSString *seriesDICOMUID;
@end

@interface DicomStudy : NSObject
@property(retain) NSMutableDictionary *harnessPaths;
@property(retain) DicomSeries *harnessSRSeries;
- (NSString*) roiPathForImage:(DicomImage*)image NS_SWIFT_NAME(roiPath(forImage:));
- (DicomSeries*) roiSRSeries;
@end

@interface DicomDatabase : NSObject
+ (DicomDatabase*) databaseForContext:(NSManagedObjectContext*)context;
- (NSString*) uniquePathForNewDataFileWithExtension:(NSString*)extension;
@end

@interface SRAnnotation : NSObject
+ (NSData*) roiFromDICOM:(NSString*)path;
- (id) initWithROIs:(NSArray*)rois path:(NSString*)path forImage:(id)image NS_SWIFT_NAME(init(rois:path:forImage:));
- (void) setSeriesInstanceUID:(NSString*)uid;
- (BOOL) writeToFileAtPath:(NSString*)path;
@end

NS_SWIFT_NAME(RestrictedUnarchiver)
@interface HorosRestrictedUnarchiver : NSObject
+ (nullable NSArray*) unarchiveROIsWithData:(nullable NSData*)data NS_SWIFT_NAME(unarchiveROIs(with:));
+ (nullable NSArray*) unarchiveROIsWithFile:(nullable NSString*)path NS_SWIFT_NAME(unarchiveROIs(withFile:));
@end
/// The archives: path -> ROIs, or a string for an archive that cannot be read.
extern NSMutableDictionary *harnessArchives;

NS_SWIFT_NAME(ROILineConstruction)
@interface HorosROILineConstruction : NSObject
@property NSPoint midpoint, parallelA, parallelB, perpendicularA, perpendicularB;
@end

NS_SWIFT_NAME(ROILineGeometry)
@interface HorosROILineGeometry : NSObject
+ (nullable HorosROILineConstruction*) constructionFromLineA:(NSPoint)a b:(NSPoint)b spacingX:(CGFloat)sx spacingY:(CGFloat)sy
    NS_SWIFT_NAME(construction(from:b:spacingX:spacingY:));
@end

NS_SWIFT_NAME(ROISlicePoint)
@interface HorosROISlicePoint : NSObject
@property double pixelX, pixelY, originX, originY, originZ;
- (instancetype) initWithPixelX:(double)pixelX pixelY:(double)pixelY originX:(double)originX originY:(double)originY originZ:(double)originZ
    rowX:(double)rowX rowY:(double)rowY rowZ:(double)rowZ colX:(double)colX colY:(double)colY colZ:(double)colZ
    normalX:(double)normalX normalY:(double)normalY normalZ:(double)normalZ spacingX:(double)spacingX spacingY:(double)spacingY
    pixelCenter:(BOOL)pixelCenter;
@end

NS_SWIFT_NAME(ROIIntersliceMeasure)
@interface HorosROIIntersliceMeasure : NSObject
@property double distance3D, projectedDistance;
@property(copy) NSString *orientation, *summary;
@end

NS_SWIFT_NAME(ROIIntersliceGeometry)
@interface HorosROIIntersliceGeometry : NSObject
+ (nullable HorosROIIntersliceMeasure*) measureFrom:(HorosROISlicePoint*)first to:(HorosROISlicePoint*)second NS_SWIFT_NAME(measure(from:to:));
@end

@interface ITKBrushROIFilter : NSObject
- (void) erode:(ROI*)aROI withStructuringElementRadius:(int)radius;
- (void) dilate:(ROI*)aROI withStructuringElementRadius:(int)radius;
- (void) close:(ROI*)aROI withStructuringElementRadius:(int)radius;
- (void) open:(ROI*)aROI withStructuringElementRadius:(int)radius;
@end

@interface ITKSegmentation3D : NSObject
+ (NSMutableArray*) extractContour:(unsigned char*)map width:(long)width height:(long)height numPoints:(long)numPoints;
@end

@interface WaitRendering : NSWindowController
- (id) init:(NSString*)string;
@end

@interface PaletteController : NSWindowController
@property BOOL windowWillClose;
- (id) initWithViewer:(ViewerController*)viewer;
@end

@interface CalciumScoringWindowController : NSWindowController
@property BOOL windowWillClose;
// Not optional, as the Swift class's initializer.
- (nonnull id) initWithViewer:(ViewerController*)viewer;
@end

@interface HorosFormField : NSTextField
@end

@interface HorosFormView : NSView
@property(retain) NSArray *harnessCells;
- (HorosFormField*) cellAtIndex:(NSInteger)index NS_SWIFT_NAME(cell(at:));
@end

/// The superclass of the viewers, which declares their undo.
@interface OSIWindowController : NSWindowController
- (void) addToUndoQueue:(NSString*)what;
- (IBAction) redo:(id)sender;
- (IBAction) undo:(id)sender;
@end

@interface ViewerController : OSIWindowController {
@public
    NSMutableArray *fileList[MAX4D];
    NSMutableArray *pixList[MAX4D];
    NSMutableArray *roiList[MAX4D];
    short curMovieIndex, maxMovieIndex;
    DCMView *imageView;
    NSMutableArray *undoQueue, *redoQueue;
    NSRecursiveLock *roiLock;
    NSString *morphoFunction;
    NSSlider *structuringElementRadiusSlider;
    NSTextField *structuringElementRadiusTextField;
    NSWindow *brushROIFilterOptionsWindow;
    NSButton *brushROIFilterOptionsAllWithSameName;
    NSDate *injectionDateTime, *editedRadiopharmaceuticalStartTime, *editedAcquisitionTime;
    NSWindow *displaySUVWindow, *injectionTimeWindow;
    HorosFormView *suvForm;
    NSMatrix *suvConversion;
    float factorPET2SUV;
    ViewerController *blendingController, *registeredViewer;
    NSWindow *harnessWindow;
}
@property(nonatomic, retain) NSDate *injectionDateTime;
@property(retain) ViewerController *blendedWindow;
@property(retain) NSMutableArray *harnessSelected, *harnessApply;
- (NSMutableArray*) selectedROIs;
- (ROI*) selectedROI;
- (NSArray*) roisWithName:(NSString*)name in4D:(BOOL)in4D NS_SWIFT_NAME(rois(withName:in4D:));
- (void) saveROI:(long)movieIndex;
- (NSArray*) roiApplyWindow:(id)sender;
- (IBAction) revertSeries:(id)sender;
- (void) setWindowTitle:(id)sender;
- (float) computeInterval;
- (IBAction) SetThicknessInterval:(id)sender NS_SWIFT_NAME(setThicknessInterval(_:));
- (void) horosLoadViewerPanels;
- (ViewerController*) blendingController NS_SWIFT_NAME(blending());
- (ViewerController*) registeredViewer;
- (NSMutableArray*) roiList;
- (NSMutableArray*) pixList;
- (DCMView*) imageView;
- (short) maxMovieIndex;
+ (BOOL) areROIsArraysIdentical:(id)a with:(id)b;
- (ROI*) newROI:(ToolMode)type;
- (MyPoint*) newPoint:(float)x :(float)y;
IVAR_ACCESSORS
@end

#ifndef HARNESS_SWIFT
// The methods under test, as the Objective-C of the driver calls them.
@interface ViewerController (ROITools)
- (NSMutableDictionary *) volumeLengthStateForMovieIndex:(long)movieIndex create:(BOOL)create;
- (NSArray *) volumeLengthROIsForMovieIndex:(long)movieIndex;
- (void) registerVolumeLengthROI:(HorosVolumeLengthROI *)roi movieIndex:(long)movieIndex anchor:(DicomImage *)anchor;
- (void) attachVolumeLengthROI:(HorosVolumeLengthROI *)roi movieIndex:(long)movieIndex;
- (void) addVolumeLengthROI:(HorosVolumeLengthROI *)roi;
- (void) addVolumeLengthROI:(HorosVolumeLengthROI *)roi movieIndex:(long)movieIndex;
- (void) restoreVolumeLengthSnapshot:(NSDictionary *)snapshot movieIndex:(long)movieIndex;
- (void) saveVolumeLengthROIs:(long)movieIndex writtenPaths:(NSMutableArray *)paths anchorPaths:(NSDictionary *)anchorPaths;
- (void) executeUndo:(NSMutableArray*)u;
- (IBAction) redo:(id)sender;
- (IBAction) undo:(id)sender;
- (id) prepareObjectForUndo:(NSString*)string;
- (void) removeLastItemFromUndoQueue;
- (void) addToUndoQueue:(NSString*)string;
- (IBAction) generateGeometryFromSelectedLine:(id)sender;
- (NSArray *) horosInterslicePointRecords;
- (BOOL) horosPickInterslicePreferred:(ROI *)preferred first:(NSDictionary **)first second:(NSDictionary **)second;
- (IBAction) measureBetweenSelectedSlices:(id)sender;
- (IBAction) calibrate:(id)sender;
- (void) brushTool:(id)sender;
- (NSRecursiveLock*) roiLock;
- (void) applyMorphology:(NSArray*)rois action:(NSString*)action radius:(long)radius sendNotification:(BOOL)sendNotification;
- (IBAction) setStructuringElementRadius:(id)sender;
- (IBAction) morphoSelectedBrushROIWithRadius:(id)sender;
- (IBAction) morphoSelectedBrushROI:(id)sender;
- (ROI*) convertPolygonROItoBrush:(ROI*)selectedROI;
- (ROI*) convertBrushROItoPolygon:(ROI*)selectedROI numPoints:(int)numPoints;
- (int) imageIndexOfROI:(ROI*)c;
- (IBAction) mergeBrushROI:(id)sender ROIs:(NSArray*)s ROIList:(NSMutableArray*)roiListContained;
- (IBAction) mergeBrushROI:(id)sender;
- (IBAction) convertBrushPolygon:(id)sender;
- (IBAction) cancel:(id)sender;
- (IBAction) ok:(id)sender;
- (IBAction) editSUVinjectionTime:(id)sender;
- (float) factorPET2SUV;
- (void) recomputePixMinMax;
- (void) convertPETtoSUV;
- (void) restoreConvertPETtoSUVautomaticallyValue:(NSNumber*)valueToRestore;
- (IBAction) endDisplaySUV:(id)sender;
- (IBAction) updateSUVValues:(id)sender;
- (void) displaySUV:(id)sender;
- (IBAction) calciumScoring:(id)sender;
// The Swift of -newROI:, which ViewerController.m keeps.
- (ROI*) horosMakeROI:(ToolMode)type;
@end

@interface NSObject (HarnessOperation)
- (id) initWithController:(ViewerController*)c dict:(NSDictionary*)d;
@end

BOOL HorosCalibrationFloat(NSString *text, NSLocale *locale, float *value);
#endif
'''

IVARS = [
    # (kind, type, name)
    ('scalar', 'short', 'curMovieIndex'), ('scalar', 'short', 'maxMovieIndex'), ('scalar', 'float', 'factorPET2SUV'),
    ('object', 'DCMView*', 'imageView'), ('object', 'NSMutableArray*', 'undoQueue'), ('object', 'NSMutableArray*', 'redoQueue'),
    ('object', 'NSRecursiveLock*', 'roiLock'), ('object', 'NSString*', 'morphoFunction'),
    ('object', 'NSDate*', 'editedRadiopharmaceuticalStartTime'), ('object', 'NSDate*', 'editedAcquisitionTime'),
    ('outlet', 'NSSlider*', 'structuringElementRadiusSlider'), ('outlet', 'NSTextField*', 'structuringElementRadiusTextField'),
    ('outlet', 'NSWindow*', 'brushROIFilterOptionsWindow'), ('outlet', 'NSButton*', 'brushROIFilterOptionsAllWithSameName'),
    ('outlet', 'NSWindow*', 'displaySUVWindow'), ('outlet', 'NSWindow*', 'injectionTimeWindow'),
    ('outlet', 'HorosFormView*', 'suvForm'), ('outlet', 'NSMatrix*', 'suvConversion'),
]
NONISOLATED = {'curMovieIndex', 'maxMovieIndex', 'imageView', 'roiLock'}


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
                 '- (nullable NSMutableArray<DCMPix *>*)horos_pixListAt:(NSInteger)index NS_SWIFT_NONISOLATED;',
                 '- (nullable NSMutableArray<NSMutableArray<ROI *> *>*)horos_roiListAt:(NSInteger)index;']
    implemented += ['- (NSMutableArray*)horos_fileListAt:(NSInteger)index { return fileList[index]; }',
                    '- (NSMutableArray*)horos_pixListAt:(NSInteger)index { return pixList[index]; }',
                    '- (NSMutableArray*)horos_roiListAt:(NSInteger)index { return roiList[index]; }']
    return '\n'.join(declared), '\n'.join(implemented)


DECLARED, IMPLEMENTED = accessors()
HEADER = HEADER.replace('IVAR_ACCESSORS', DECLARED)

STUBS = r'''#import "Harness.h"

NSString* const OsirixROIChangeNotification = @"OsirixROIChangeNotification";
NSString* const OsirixRemoveROINotification = @"OsirixRemoveROINotification";
NSString* const OsirixAddROINotification = @"OsirixAddROINotification";
NSString* const OsirixUpdateVolumeDataNotification = @"OsirixUpdateVolumeDataNotification";
NSString* const OsirixRecomputeROINotification = @"OsirixRecomputeROINotification";

static NSMapTable *names;
static NSLock *recordLock;
static NSMutableArray *buffered;
NSString *harnessTemporary;

void Register(id object, NSString *name) {
    if (!names) names = [[NSMapTable mapTableWithKeyOptions: NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsStrongMemory
                                                valueOptions: NSPointerFunctionsStrongMemory] retain];
    [names setObject: name forKey: object];
}

static NSString *Number(double value) {
    // A time from now (a new group identifier) is not the same in two runs.
    if (value > 5e8) return @"<now>";
    return [NSString stringWithFormat: @"%a", value];
}

NSString *Name(id object) {
    if (object == nil) return @"nil";
    if (object == [NSNull null]) return @"null";
    NSString *name = [names objectForKey: object];
    if (name) return name;
    if ([object isKindOfClass: [ROI class]]) return [NSString stringWithFormat: @"roi(%@)", [object label]];
    if ([object isKindOfClass: [NSString class]]) {
        NSString *text = object;
        if (harnessTemporary) text = [text stringByReplacingOccurrencesOfString: harnessTemporary withString: @"$TMP"];
        return [NSString stringWithFormat: @"\"%@\"", text];
    }
    if ([object isKindOfClass: [NSNumber class]]) return [object stringValue];
    if ([object isKindOfClass: [NSDate class]]) return [NSString stringWithFormat: @"date %a", [object timeIntervalSinceReferenceDate]];
    if ([object isKindOfClass: [MyPoint class]]) return [NSString stringWithFormat: @"(%a,%a)", [object point].x, [object point].y];
    if ([object isKindOfClass: [NSArray class]] || [object isKindOfClass: [NSSet class]]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (id item in object) [parts addObject: Name(item)];
        return [NSString stringWithFormat: @"[%@]", [parts componentsJoinedByString: @","]];
    }
    if ([object isKindOfClass: [NSDictionary class]]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (id key in [[object allKeys] sortedArrayUsingComparator: ^(id a, id b) { return [Name(a) compare: Name(b)]; }])
            [parts addObject: [NSString stringWithFormat: @"%@=%@", Name(key), Name([object objectForKey: key])]];
        return [NSString stringWithFormat: @"{%@}", [parts componentsJoinedByString: @","]];
    }
    if ([object isKindOfClass: [HorosROISlicePoint class]]) return [NSString stringWithFormat: @"slice point %a %a", [object pixelX], [object pixelY]];
    return [NSString stringWithFormat: @"<%@>", NSStringFromClass([object class])];
}

void Record(NSString *line) {
    if (!recordLock) recordLock = [NSLock new];
    [recordLock lock];
    printf("%s\n", line.UTF8String);
    fflush(stdout);
    [recordLock unlock];
}

void Buffer(NSString *line) {
    [recordLock lock];
    if (!buffered) buffered = [NSMutableArray new];
    [buffered addObject: line];
    [recordLock unlock];
}

void Flush(void) {
    [recordLock lock];
    NSArray *lines = [[buffered sortedArrayUsingSelector: @selector(compare:)] retain];
    [buffered removeAllObjects];
    [recordLock unlock];
    for (NSString *line in lines) Record([@"  (op) " stringByAppendingString: line]);
    [lines release];
}

void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *where) {
    // The category of the reference's blocks is not part of the name.
    NSString *function = [@(where) stringByReplacingOccurrencesOfString: @"(ROITools)" withString: @""];
    Record([NSString stringWithFormat: @"exception %@ %@ stack %d in %@", e.name, e.reason, logStack, function]);
}

NSInteger harnessAlertResponse = 1;

static NSInteger Alert(NSString *kind, NSString *title, NSString *message, NSString *a, NSString *b, NSString *c) {
    Record([NSString stringWithFormat: @"alert %@ %@ / %@ [%@|%@|%@] -> %ld", kind, Name(title), Name(message), Name(a), Name(b), Name(c), (long)harnessAlertResponse]);
    return harnessAlertResponse;
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

@implementation NSWindow (N2)
- (void) orderOutAndEndSheet { Record([NSString stringWithFormat: @"%@ orderOutAndEndSheet", Name(self)]); }
- (void) orderOutAndEndSheetWithReturnCode:(NSModalResponse)code { Record([NSString stringWithFormat: @"%@ orderOutAndEndSheet %ld", Name(self), (long)code]); }
@end

void (^harnessModal)(void) = nil;
NSMutableArray *harnessWindows = nil;

@implementation HarnessApplication
- (NSArray*) windows { return harnessWindows; }
- (NSModalResponse) runModalForWindow:(NSWindow*)window {
    Record([NSString stringWithFormat: @"runModal %@", Name(window)]);
    if (harnessModal) harnessModal();
    return NSModalResponseStop;
}
- (void) stopModal { Record(@"stopModal"); }
@end

@implementation HarnessWindow
- (void) beginSheet:(NSWindow*)sheet completionHandler:(void (^)(NSModalResponse))handler {
    Record([NSString stringWithFormat: @"%@ beginSheet %@", Name(self), Name(sheet)]);
    if ([sheet isKindOfClass: [HarnessWindow class]]) ((HarnessWindow*)sheet).harnessParent = self;
}
- (void) endSheet:(NSWindow*)sheet { Record([NSString stringWithFormat: @"%@ endSheet %@", Name(self), Name(sheet)]); }
- (NSWindow*) sheetParent { return self.harnessParent; }
- (void) orderOut:(id)sender { Record([NSString stringWithFormat: @"%@ orderOut %@", Name(self), Name(sender)]); }
@end

HarnessWindow *NewWindow(NSString *name) {
    HarnessWindow *w = [[HarnessWindow alloc] initWithContentRect: NSMakeRect(0, 0, 10, 10) styleMask: NSWindowStyleMaskBorderless backing: NSBackingStoreBuffered defer: YES];
    w.releasedWhenClosed = NO;
    Register(w, name);
    return w;
}

@implementation DCMPix
@synthesize patientsWeight = _patientsWeight, radionuclideTotalDose = _radionuclideTotalDose, minValueOfSeries = _minValueOfSeries;
@synthesize maxValueOfSeries = _maxValueOfSeries, factorPET2SUV = _factorPET2SUV, savedWL = _savedWL, savedWW = _savedWW;
@synthesize acquisitionTime = _acquisitionTime, radiopharmaceuticalStartTime = _radiopharmaceuticalStartTime;
@synthesize SUVConverted = _SUVConverted, displaySUVValue = _displaySUVValue;
- (double) originX { return originValues[0]; }
- (double) originY { return originValues[1]; }
- (double) originZ { return originValues[2]; }
- (float) philipsFactor { return philipsFactorValue; }
- (BOOL) hasSUV { return hasSUVValue; }
- (void) orientation:(float*)c { memcpy(c, orientationValues, sizeof(orientationValues)); }
- (void) setPatientsWeight:(float)v { Record([NSString stringWithFormat: @"%@ patientsWeight %a", Name(self), v]); _patientsWeight = v; }
- (void) setRadionuclideTotalDose:(float)v { Record([NSString stringWithFormat: @"%@ radionuclideTotalDose %a", Name(self), v]); _radionuclideTotalDose = v; }
- (void) setMinValueOfSeries:(float)v { Record([NSString stringWithFormat: @"%@ minValueOfSeries %a", Name(self), v]); _minValueOfSeries = v; }
- (void) setMaxValueOfSeries:(float)v { Record([NSString stringWithFormat: @"%@ maxValueOfSeries %a", Name(self), v]); _maxValueOfSeries = v; }
- (void) setFactorPET2SUV:(float)v { Record([NSString stringWithFormat: @"%@ factorPET2SUV %a", Name(self), v]); _factorPET2SUV = v; }
- (void) setSavedWL:(float)v { Record([NSString stringWithFormat: @"%@ savedWL %a", Name(self), v]); _savedWL = v; }
- (void) setSavedWW:(float)v { Record([NSString stringWithFormat: @"%@ savedWW %a", Name(self), v]); _savedWW = v; }
- (void) setAcquisitionTime:(NSDate*)v { Record([NSString stringWithFormat: @"%@ acquisitionTime %@", Name(self), Name(v)]); [v retain]; [_acquisitionTime release]; _acquisitionTime = v; }
- (void) setRadiopharmaceuticalStartTime:(NSDate*)v { Record([NSString stringWithFormat: @"%@ radiopharmaceuticalStartTime %@", Name(self), Name(v)]); [v retain]; [_radiopharmaceuticalStartTime release]; _radiopharmaceuticalStartTime = v; }
- (void) setSUVConverted:(BOOL)v { Record([NSString stringWithFormat: @"%@ SUVConverted %d", Name(self), v]); _SUVConverted = v; }
- (void) setDisplaySUVValue:(BOOL)v { Record([NSString stringWithFormat: @"%@ displaySUVValue %d", Name(self), v]); _displaySUVValue = v; }
- (void) computePixMinPixMax { Record([NSString stringWithFormat: @"%@ computePixMinPixMax", Name(self)]); }
- (void) computeTotalDoseCorrected {
    self.radionuclideTotalDoseCorrected = _radionuclideTotalDose * 0.8125f;
    Record([NSString stringWithFormat: @"%@ computeTotalDoseCorrected %a", Name(self), self.radionuclideTotalDoseCorrected]);
}
- (void) fillROI:(ROI*)roi newVal:(float)newVal minValue:(float)minValue maxValue:(float)maxValue outside:(BOOL)outside
    orientationStack:(long)orientationStack stackNo:(long)stackNo restore:(BOOL)restore addition:(BOOL)addition {
    Buffer([NSString stringWithFormat: @"%@ fillROI %@ %a %a %a %d %ld %ld %d %d", Name(self), Name(roi), newVal, minValue, maxValue, outside, orientationStack, stackNo, restore, addition]);
}
+ (NSPoint) originCorrectedAccordingToOrientation:(DCMPix*)pix {
    Record([NSString stringWithFormat: @"originCorrected %@", Name(pix)]);
    return NSMakePoint(pix.originX + 0.5, pix.originY - 0.25);
}
+ (unsigned char*) getMapFromPolygonROI:(ROI*)roi size:(NSSize*)size origin:(NSPoint*)origin {
    Record([NSString stringWithFormat: @"getMapFromPolygonROI %@ type %d points %@", Name(roi), roi.type, Name(roi.points)]);
    if (roi.harnessNoMap) return NULL;
    size->width = 5; size->height = 3; origin->x = 7.75; origin->y = 2.5;
    unsigned char *map = malloc(15);
    for (int i = 0; i < 15; i++) map[i] = (unsigned char)((i * 37 + roi.points.count) & 0xff);
    return map;
}
@end

@implementation MyPoint
+ (MyPoint*) point:(NSPoint)a { MyPoint *p = [[MyPoint new] autorelease]; p.point = a; return p; }
- (void) move:(float)x :(float)y { NSPoint p = self.point; p.x += x; p.y += y; self.point = p; }
@end

@implementation DCMView
- (void) roiSet:(ROI*)roi { Record([NSString stringWithFormat: @"%@ roiSet %@", Name(self), Name(roi)]); }
- (void) cancelLengthPlacement { Record([NSString stringWithFormat: @"%@ cancelLengthPlacement", Name(self)]); }
- (void) stopROIEditing { Record([NSString stringWithFormat: @"%@ stopROIEditing", Name(self)]); }
- (void) stopROIEditingForce:(BOOL)force { Record([NSString stringWithFormat: @"%@ stopROIEditingForce %d", Name(self), force]); }
- (void) setIndex:(NSInteger) index { Record([NSString stringWithFormat: @"%@ setIndex %ld", Name(self), (long)index]); }
- (void) getWLWW:(float*)wl :(float*)ww { *wl = 40.25f; *ww = 400.5f; Record([NSString stringWithFormat: @"%@ getWLWW", Name(self)]); }
- (void) setWLWW:(float)wl :(float)ww { Record([NSString stringWithFormat: @"%@ setWLWW %a %a", Name(self), wl, ww]); }
- (void) updatePresentationStateFromSeries { Record([NSString stringWithFormat: @"%@ updatePresentationStateFromSeries", Name(self)]); }
- (void) setNeedsDisplay:(BOOL)flag { Record([NSString stringWithFormat: @"%@ needsDisplay %d", Name(self), flag]); }
@end

static long newROIs = 0, copies = 0;

static NSString *Points(NSArray *points) {
    NSMutableArray *parts = [NSMutableArray array];
    for (MyPoint *p in points) [parts addObject: [NSString stringWithFormat: @"(%a,%a)", p.point.x, p.point.y]];
    return [parts componentsJoinedByString: @" "];
}

@implementation ROI
- (instancetype) initWithType:(ToolMode)type :(float)sx :(float)sy :(NSPoint)origin {
    if ((self = [super init])) {
        _type = type; _pixelSpacingX = sx; _pixelSpacingY = sy; _points = [NSMutableArray new];
        _label = [[NSString stringWithFormat: @"new%ld", ++newROIs] copy];
        Record([NSString stringWithFormat: @"%@ initWithType %d %a %a (%a,%a)", Name(self), type, sx, sy, origin.x, origin.y]);
    }
    return self;
}
- (instancetype) initWithTexture:(unsigned char*)t textWidth:(int)w textHeight:(int)h textName:(NSString*)name
    positionX:(int)x positionY:(int)y spacingX:(float)sx spacingY:(float)sy imageOrigin:(NSPoint)o {
    if ((self = [super init])) {
        _type = tPlain; _points = [NSMutableArray new];
        texture = malloc(w * h); memcpy(texture, t, w * h);
        textureWidthValue = w; textureHeightValue = h; cornerX = x; cornerY = y;
        _label = [[NSString stringWithFormat: @"brush%ld", ++newROIs] copy];
        unsigned sum = 0;
        for (int i = 0; i < w * h; i++) sum = sum * 31 + t[i];
        Record([NSString stringWithFormat: @"%@ initWithTexture %dx%d %u %@ at %d,%d %a %a (%a,%a)", Name(self), w, h, sum, Name(name), x, y, sx, sy, o.x, o.y]);
    }
    return self;
}
- (id) copyWithZone:(NSZone*)zone {
    Record([NSString stringWithFormat: @"copy %@", Name(self)]);
    if (self.harnessCopyFails) return nil;
    ROI *r = [[[self class] allocWithZone: zone] init];
    r->_type = _type; r->_points = [_points mutableCopy]; r->_isAliased = _isAliased; r->_groupID = _groupID;
    r.label = [NSString stringWithFormat: @"%@'%ld", _label, ++copies];
    if ([self isKindOfClass: [HorosVolumeLengthROI class]]) ((HorosVolumeLengthROI*)r).volumeLength = ((HorosVolumeLengthROI*)self).volumeLength;
    return r;
}
- (unsigned char*) textureBuffer { return texture; }
- (int) textureWidth { return textureWidthValue; }
- (int) textureHeight { return textureHeightValue; }
- (int) textureUpLeftCornerX { return cornerX; }
- (int) textureUpLeftCornerY { return cornerY; }
- (void) setType:(ToolMode)t { Record([NSString stringWithFormat: @"%@ type %d", Name(self), t]); _type = t; }
- (void) setPoints:(NSMutableArray*)p { Record([NSString stringWithFormat: @"%@ points %@", Name(self), Points(p)]); [p retain]; [_points release]; _points = p; }
- (void) setName:(NSString*)n { Record([NSString stringWithFormat: @"%@ name %@", Name(self), Name(n)]); [n retain]; [_nameString release]; _nameString = n; }
- (void) setComments:(NSString*)n { Record([NSString stringWithFormat: @"%@ comments %@", Name(self), Name(n)]); [n retain]; [_commentsString release]; _commentsString = n; }
- (void) setRoImode:(NSInteger)m { Record([NSString stringWithFormat: @"%@ ROImode %ld", Name(self), (long)m]); _roImode = m; }
- (void) setIsAliased:(BOOL)v { Record([NSString stringWithFormat: @"%@ isAliased %d", Name(self), v]); _isAliased = v; }
- (void) setIsSpline:(BOOL)v { Record([NSString stringWithFormat: @"%@ isSpline %d", Name(self), v]); _isSpline = v; }
- (void) setGroupID:(NSTimeInterval)v { Record([NSString stringWithFormat: @"%@ groupID %@", Name(self), Number(v)]); _groupID = v; }
- (void) setThickness:(float)v { Record([NSString stringWithFormat: @"%@ thickness %a", Name(self), v]); _thickness = v; }
- (void) setOpacity:(float)v { Record([NSString stringWithFormat: @"%@ opacity %a", Name(self), v]); _opacity = v; }
- (void) setRgbcolor:(RGBColor)c { Record([NSString stringWithFormat: @"%@ color %d %d %d", Name(self), c.red, c.green, c.blue]); _rgbcolor = c; }
- (void) setCurView:(DCMView*)v { Record([NSString stringWithFormat: @"%@ curView %@", Name(self), Name(v)]); _curView = v; }
- (void) setROIRect:(NSRect)r { Record([NSString stringWithFormat: @"%@ rect %a %a %a %a", Name(self), r.origin.x, r.origin.y, r.size.width, r.size.height]); _rect = r; }
- (NSPoint) pointAtIndex:(NSUInteger)index { return [[_points objectAtIndex: index] point]; }
- (void) addPoint:(NSPoint)point { Record([NSString stringWithFormat: @"%@ addPoint (%a,%a)", Name(self), point.x, point.y]); [_points addObject: [MyPoint point: point]]; }
- (void) mergeWithTexture:(ROI*)r { Record([NSString stringWithFormat: @"%@ mergeWithTexture %@", Name(self), Name(r)]); }
- (BOOL) reduceTextureIfPossible { Record([NSString stringWithFormat: @"%@ reduceTextureIfPossible", Name(self)]); return self.harnessReduceEmpty; }
+ (NSPoint) pointBetweenPoint:(NSPoint)a and:(NSPoint)b ratio:(float)r { return NSMakePoint(a.x + (b.x - a.x) * r, a.y + (b.y - a.y) * r); }
@end

@implementation HorosVolumeLengthROI
- (void) setVolumeLength:(NSDictionary*)v { Record([NSString stringWithFormat: @"%@ volumeLength %@", Name(self), Name(v)]); v = [v copy]; [_volumeLength release]; _volumeLength = v; }
- (NSString*) volumeIdentifier { return _volumeLength[@"id"]; }
@end

@implementation DicomImage
- (NSString*) sopInstanceUID { return sop; }
@end

@implementation DicomSeries
@end

@implementation DicomStudy
- (NSString*) roiPathForImage:(DicomImage*)image { Record([NSString stringWithFormat: @"roiPathForImage %@", Name(image)]); return self.harnessPaths[Name(image)]; }
- (DicomSeries*) roiSRSeries { return self.harnessSRSeries; }
@end

static long uniquePaths = 0;

@implementation DicomDatabase
+ (DicomDatabase*) databaseForContext:(NSManagedObjectContext*)context {
    static DicomDatabase *database;
    if (!database) { database = [DicomDatabase new]; Register(database, @"database"); }
    Record([NSString stringWithFormat: @"databaseForContext %@", Name(context)]);
    return database;
}
- (NSString*) uniquePathForNewDataFileWithExtension:(NSString*)extension {
    NSString *path = [harnessTemporary stringByAppendingPathComponent: [NSString stringWithFormat: @"unique-%ld.%@", ++uniquePaths, extension]];
    Record([NSString stringWithFormat: @"uniquePath %@", Name(path)]);
    return path;
}
@end

NSMutableDictionary *harnessArchives = nil;

@implementation SRAnnotation {
    NSArray *rois;
}
+ (NSData*) roiFromDICOM:(NSString*)path {
    Record([NSString stringWithFormat: @"roiFromDICOM %@", Name(path)]);
    return [path hasSuffix: @".dcm"] ? [path dataUsingEncoding: NSUTF8StringEncoding] : nil;
}
- (id) initWithROIs:(NSArray*)r path:(NSString*)path forImage:(id)image {
    Record([NSString stringWithFormat: @"SRAnnotation %@ at %@ for %@", Name(r), Name(path), Name(image)]);
    if ((self = [super init])) rois = [r copy];
    return self;
}
- (void) setSeriesInstanceUID:(NSString*)uid { Record([NSString stringWithFormat: @"SRAnnotation series %@", Name(uid)]); }
- (BOOL) writeToFileAtPath:(NSString*)path {
    Record([NSString stringWithFormat: @"SRAnnotation write %@", Name(path)]);
    if ([path containsString: @"fails"]) return NO;
    harnessArchives[path] = rois;
    return YES;
}
@end

@implementation HorosRestrictedUnarchiver
static NSArray *Archive(NSString *path) {
    id rois = harnessArchives[path];
    return [rois isKindOfClass: [NSArray class]] ? rois : nil;
}
+ (NSArray*) unarchiveROIsWithData:(NSData*)data {
    NSString *path = [[[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding] autorelease];
    Record([NSString stringWithFormat: @"unarchiveROIsWithData %@", Name(path)]);
    return Archive(path);
}
+ (NSArray*) unarchiveROIsWithFile:(NSString*)path {
    Record([NSString stringWithFormat: @"unarchiveROIsWithFile %@", Name(path)]);
    return Archive(path);
}
@end

@implementation HorosROILineConstruction
@end

@implementation HorosROILineGeometry
+ (HorosROILineConstruction*) constructionFromLineA:(NSPoint)a b:(NSPoint)b spacingX:(CGFloat)sx spacingY:(CGFloat)sy {
    Record([NSString stringWithFormat: @"construction (%a,%a) (%a,%a) %a %a", a.x, a.y, b.x, b.y, sx, sy]);
    if (sx == 0) return nil;
    HorosROILineConstruction *c = [[HorosROILineConstruction new] autorelease];
    c.midpoint = NSMakePoint((a.x + b.x) / 2, (a.y + b.y) / 2);
    c.parallelA = NSMakePoint(a.x + sy, a.y - sx); c.parallelB = NSMakePoint(b.x + sy, b.y - sx);
    c.perpendicularA = NSMakePoint(c.midpoint.x - (b.y - a.y), c.midpoint.y + (b.x - a.x));
    c.perpendicularB = NSMakePoint(c.midpoint.x + (b.y - a.y), c.midpoint.y - (b.x - a.x));
    return c;
}
@end

@implementation HorosROISlicePoint
- (instancetype) initWithPixelX:(double)pixelX pixelY:(double)pixelY originX:(double)originX originY:(double)originY originZ:(double)originZ
    rowX:(double)rowX rowY:(double)rowY rowZ:(double)rowZ colX:(double)colX colY:(double)colY colZ:(double)colZ
    normalX:(double)normalX normalY:(double)normalY normalZ:(double)normalZ spacingX:(double)spacingX spacingY:(double)spacingY
    pixelCenter:(BOOL)pixelCenter {
    if ((self = [super init])) {
        _pixelX = pixelX; _pixelY = pixelY; _originX = originX; _originY = originY; _originZ = originZ;
        Record([NSString stringWithFormat: @"slice point %a %a origin %a %a %a row %a %a %a col %a %a %a normal %a %a %a spacing %a %a centre %d",
                pixelX, pixelY, originX, originY, originZ, rowX, rowY, rowZ, colX, colY, colZ, normalX, normalY, normalZ, spacingX, spacingY, pixelCenter]);
    }
    return self;
}
@end

@implementation HorosROIIntersliceMeasure
@end

@implementation HorosROIIntersliceGeometry
+ (HorosROIIntersliceMeasure*) measureFrom:(HorosROISlicePoint*)first to:(HorosROISlicePoint*)second {
    Record([NSString stringWithFormat: @"measure %@ to %@", Name(first), Name(second)]);
    if (first.pixelX == 999) return nil;
    HorosROIIntersliceMeasure *m = [[HorosROIIntersliceMeasure new] autorelease];
    m.projectedDistance = fabs(second.pixelX - first.pixelX) + 0.125;
    m.distance3D = fabs(second.originZ - first.originZ) + m.projectedDistance;
    m.orientation = first.originZ < second.originZ ? @"cranial" : @"caudal";
    m.summary = [NSString stringWithFormat: @"summary %g", m.distance3D];
    return m;
}
@end

@implementation ITKBrushROIFilter
- (void) erode:(ROI*)r withStructuringElementRadius:(int)radius { Buffer([NSString stringWithFormat: @"erode %@ %d", Name(r), radius]); }
- (void) dilate:(ROI*)r withStructuringElementRadius:(int)radius { Buffer([NSString stringWithFormat: @"dilate %@ %d", Name(r), radius]); }
- (void) close:(ROI*)r withStructuringElementRadius:(int)radius { Buffer([NSString stringWithFormat: @"close %@ %d", Name(r), radius]); }
- (void) open:(ROI*)r withStructuringElementRadius:(int)radius { Buffer([NSString stringWithFormat: @"open %@ %d", Name(r), radius]); }
@end

@implementation ITKSegmentation3D
+ (NSMutableArray*) extractContour:(unsigned char*)map width:(long)width height:(long)height numPoints:(long)numPoints {
    // The contour's size is the first byte of the map: one of the test's.
    long count = map ? map[0] : 0;
    Record([NSString stringWithFormat: @"extractContour %ldx%ld numPoints %ld -> %ld points", width, height, numPoints, count]);
    NSMutableArray *points = [NSMutableArray array];
    for (long i = 0; i < count; i++) [points addObject: [MyPoint point: NSMakePoint(i * 1.5 + 0.25, (i % 5) * 2.75 - i / 3.0)]];
    return points;
}
@end

@implementation WaitRendering
- (id) init:(NSString*)string { Record([NSString stringWithFormat: @"WaitRendering %@", Name(string)]); return [super initWithWindow: nil]; }
- (void) showWindow:(id)sender { Record(@"WaitRendering show"); }
- (void) close { Record(@"WaitRendering close"); }
@end

static long palettes = 0, calciums = 0;

@implementation PaletteController
- (id) initWithViewer:(ViewerController*)viewer {
    HarnessWindow *w = NewWindow([NSString stringWithFormat: @"palette window %ld", ++palettes]);
    [harnessWindows addObject: w];
    Record([NSString stringWithFormat: @"PaletteController %ld for %@", palettes, Name(viewer)]);
    if ((self = [super initWithWindow: w])) Register(self, [NSString stringWithFormat: @"palette %ld", palettes]);
    [w release];
    return self;
}
- (NSNibName) windowNibName { return @"PaletteBrush"; }
- (void) dealloc { Record([NSString stringWithFormat: @"%@ dealloc", Name(self)]); [super dealloc]; }
@end

@implementation CalciumScoringWindowController
- (id) initWithViewer:(ViewerController*)viewer {
    HarnessWindow *w = NewWindow([NSString stringWithFormat: @"calcium window %ld", ++calciums]);
    [harnessWindows addObject: w];
    Record([NSString stringWithFormat: @"CalciumScoringWindowController %ld for %@", calciums, Name(viewer)]);
    if ((self = [super initWithWindow: w])) Register(self, [NSString stringWithFormat: @"calcium %ld", calciums]);
    [w release];
    return self;
}
- (NSNibName) windowNibName { return @"CalciumScoring"; }
- (void) showWindow:(id)sender { Record([NSString stringWithFormat: @"%@ showWindow %@", Name(self), Name(sender)]); }
- (void) dealloc { Record([NSString stringWithFormat: @"%@ dealloc", Name(self)]); [super dealloc]; }
@end

@implementation HorosFormField {
    id object;
}
- (void) setStringValue:(NSString*)s { Record([NSString stringWithFormat: @"%@ stringValue %@", Name(self), Name(s)]); [super setStringValue: s]; }
// The form's date cells have a date formatter: their object is the date.
- (void) setObjectValue:(id)o { Record([NSString stringWithFormat: @"%@ objectValue %@", Name(self), Name(o)]); [o retain]; [object release]; object = o; }
- (id) objectValue { return object; }
@end

@implementation HorosFormView
- (HorosFormField*) cellAtIndex:(NSInteger)index { return index < (NSInteger)self.harnessCells.count ? self.harnessCells[index] : nil; }
@end

@implementation OSIWindowController
- (void) addToUndoQueue:(NSString*)what { Record(@"OSIWindowController addToUndoQueue"); }
- (IBAction) redo:(id)sender { Record(@"OSIWindowController redo"); }
- (IBAction) undo:(id)sender { Record(@"OSIWindowController undo"); }
@end

static long viewers = 0;

@implementation ViewerController
@synthesize injectionDateTime;
IVAR_IMPLEMENTATIONS
- (instancetype) init {
    if ((self = [super initWithWindow: nil])) {
        Register(self, [NSString stringWithFormat: @"viewer%ld", ++viewers]);
        roiLock = [NSRecursiveLock new];
        undoQueue = [NSMutableArray new];
        redoQueue = [NSMutableArray new];
    }
    return self;
}
- (NSWindow*) window {
    if (!harnessWindow) harnessWindow = NewWindow([NSString stringWithFormat: @"%@ window", Name(self)]);
    return harnessWindow;
}
- (void) setInjectionDateTime:(NSDate*)date { Record([NSString stringWithFormat: @"injectionDateTime %@", Name(date)]); [date retain]; [injectionDateTime release]; injectionDateTime = date; }
- (NSMutableArray*) selectedROIs { return self.harnessSelected; }
- (ROI*) selectedROI { return self.harnessSelected.firstObject; }
- (NSArray*) roisWithName:(NSString*)name in4D:(BOOL)in4D {
    Record([NSString stringWithFormat: @"roisWithName %@ in4D %d", Name(name), in4D]);
    NSMutableArray *found = [NSMutableArray array];
    for (int m = 0; m < maxMovieIndex; m++)
        for (NSArray *slice in roiList[m])
            for (ROI *r in slice) if ([r.name isEqualToString: name] && ![found containsObject: r]) [found addObject: r];
    return found;
}
- (void) saveROI:(long)movieIndex { Record([NSString stringWithFormat: @"saveROI %ld", movieIndex]); }
- (NSArray*) roiApplyWindow:(id)sender { Record([NSString stringWithFormat: @"roiApplyWindow %@", Name(sender)]); return self.harnessApply; }
- (IBAction) revertSeries:(id)sender {
    Record([NSString stringWithFormat: @"revertSeries %@", Name(sender)]);
    for (int m = 0; m < maxMovieIndex; m++) for (DCMPix *p in pixList[m]) p.SUVConverted = NO;
}
- (void) setWindowTitle:(id)sender { Record([NSString stringWithFormat: @"setWindowTitle %@", Name(sender)]); }
- (float) computeInterval { Record(@"computeInterval"); return 1.5f; }
- (IBAction) SetThicknessInterval:(id)sender { Record([NSString stringWithFormat: @"SetThicknessInterval %@", Name(sender)]); }
- (void) horosLoadViewerPanels { Record(@"horosLoadViewerPanels"); }
- (ViewerController*) blendingController { return blendingController; }
- (ViewerController*) registeredViewer { return registeredViewer; }
- (NSMutableArray*) roiList { return roiList[curMovieIndex]; }
- (NSMutableArray*) pixList { return pixList[curMovieIndex]; }
- (DCMView*) imageView { return imageView; }
- (short) maxMovieIndex { return maxMovieIndex; }
+ (BOOL) areROIsArraysIdentical:(id)a with:(id)b {
    BOOL same = [a count] == [b count];
    for (NSUInteger i = 0; same && i < [a count]; i++) same = [a objectAtIndex: i] == [b objectAtIndex: i];
    Record([NSString stringWithFormat: @"areROIsArraysIdentical %@ %@ -> %d", Name(a), Name(b), same]);
    return same;
}
@end
'''

DRIVER = r'''#import "Harness.h"

extern NSString *harnessTemporary;

static uint64_t Checksum(const void *bytes, size_t length) {
    uint64_t h = 1469598103934665603ULL;
    const unsigned char *p = bytes;
    for (size_t i = 0; i < length; i++) { h ^= p[i]; h *= 1099511628211ULL; }
    return h;
}

static ROI *R(ToolMode type, NSString *label) {
    ROI *r = [[[ROI alloc] init] autorelease];
    [r setValue: @(type) forKey: @"_type"];
    [r setValue: [NSMutableArray array] forKey: @"_points"];
    r.label = label;
    return r;
}

static void Quiet(ROI *r, NSString *name, NSInteger mode, NSTimeInterval group) {
    [r setValue: name forKey: @"_nameString"];
    [r setValue: @(mode) forKey: @"_roImode"];
    [r setValue: @(group) forKey: @"_groupID"];
}

static HorosVolumeLengthROI *L(NSString *label, NSString *identifier) {
    HorosVolumeLengthROI *r = [[[HorosVolumeLengthROI alloc] init] autorelease];
    [r setValue: @(tMesure) forKey: @"_type"];
    r.label = label;
    [r setValue: identifier ? @{@"id": identifier, @"a": @[@1, @2, @3]} : @{@"a": @[@0]} forKey: @"_volumeLength"];
    return r;
}

static DCMPix *Pix(NSString *name, long z) {
    DCMPix *p = [[DCMPix new] autorelease];
    Register(p, name);
    float o[9] = {1, 0, 0, 0, 0.8f, -0.6f, 0, 0.6f, 0.8f};
    memcpy(p->orientationValues, o, sizeof(o));
    p->originValues[0] = -12.5 + z * 0.25; p->originValues[1] = 3.75 - z * 0.125; p->originValues[2] = z * 2.5 + 0.0625;
    p.pixelSpacingX = 0.625 + z * 0.001; p.pixelSpacingY = 0.75;
    return p;
}

/// A viewer of `movies` time points of `slices` slices, with no ROIs.
static ViewerController *Viewer(int movies, int slices) {
    ViewerController *v = [[[ViewerController alloc] init] autorelease];
    v->maxMovieIndex = movies;
    v->imageView = [DCMView new];
    Register(v->imageView, [NSString stringWithFormat: @"%@ view", Name(v)]);
    for (int m = 0; m < movies; m++) {
        v->pixList[m] = [NSMutableArray new];
        v->fileList[m] = [NSMutableArray new];
        v->roiList[m] = [NSMutableArray new];
        for (int z = 0; z < slices; z++) {
            [v->pixList[m] addObject: Pix([NSString stringWithFormat: @"%@ m%d s%d", Name(v), m, z], z)];
            DicomImage *image = [[DicomImage new] autorelease];
            Register(image, [NSString stringWithFormat: @"%@ image m%d s%d", Name(v), m, z]);
            image->sop = [[NSString stringWithFormat: @"1.2.%d.%d", m, z] retain];
            image.frameID = z % 2 ? @(z) : nil;
            image.objectID = [NSString stringWithFormat: @"oid %@ m%d s%d", Name(v), m, z];
            image.managedObjectContext = (id)@"context";
            [v->fileList[m] addObject: image];
            [v->roiList[m] addObject: [NSMutableArray array]];
        }
    }
    v->imageView.curDCM = v->pixList[0][0];
    v.harnessSelected = [NSMutableArray array];
    return v;
}

static void DumpROIs(ViewerController *v) {
    for (int m = 0; m < v->maxMovieIndex; m++) {
        NSMutableArray *slices = [NSMutableArray array];
        for (NSArray *slice in v->roiList[m]) [slices addObject: Name(slice)];
        Record([NSString stringWithFormat: @" rois m%d: %@", m, [slices componentsJoinedByString: @" | "]]);
    }
    // Which slices hold the same object.
    for (int m = 0; m < v->maxMovieIndex; m++) {
        NSMapTable *seen = [NSMapTable strongToStrongObjectsMapTable];
        for (NSArray *slice in v->roiList[m]) for (ROI *r in slice) {
            NSNumber *n = [seen objectForKey: r];
            [seen setObject: @(n.intValue + 1) forKey: r];
        }
        NSMutableArray *lines = [NSMutableArray array];
        for (ROI *r in seen) if ([[seen objectForKey: r] intValue] > 1) [lines addObject: [NSString stringWithFormat: @" shared m%d %@ on %@ slices", m, Name(r), [seen objectForKey: r]]];
        for (NSString *line in [lines sortedArrayUsingSelector: @selector(compare:)]) Record(line);
    }
}

static void Queues(ViewerController *v) {
    Record([NSString stringWithFormat: @" undo %lu redo %lu", (unsigned long)v->undoQueue.count, (unsigned long)v->redoQueue.count]);
    for (NSDictionary *state in v->undoQueue) Record([NSString stringWithFormat: @"  undo state %@ %@", Name(state[@"type"]), Name(state[@"rois"])]);
    for (NSDictionary *state in v->redoQueue) Record([NSString stringWithFormat: @"  redo state %@ %@", Name(state[@"type"]), Name(state[@"rois"])]);
}

@interface Observer : NSObject
@end
@implementation Observer
- (void) note:(NSNotification*)n {
    Record([NSString stringWithFormat: @"notification %@ %@ %@", n.name, Name(n.object), n.userInfo ? Name(n.userInfo) : @""]);
}
@end

@interface Sender : NSObject
@property NSInteger tag;
@end
@implementation Sender
@end

static Sender *Tag(NSInteger tag) { Sender *s = [[Sender new] autorelease]; s.tag = tag; Register(s, [NSString stringWithFormat: @"sender %ld", (long)tag]); return s; }

static NSMenuItem *Item(id represented) { NSMenuItem *i = [[NSMenuItem new] autorelease]; i.representedObject = represented; Register(i, @"menu item"); return i; }

static NSUserDefaults *defaults;

#define RUN(title, ...) do { Record(@"== " title); @autoreleasepool { @try { __VA_ARGS__ } @catch (NSException *e) { Record([NSString stringWithFormat: @"raised %@ %@", e.name, e.reason]); } Flush(); } Flush(); } while (0)

static void Undo(void) {
    RUN("undo and redo of shared ROIs", {
        [defaults setInteger: 3 forKey: @"UndoQueueSize"];
        [defaults setBool: NO forKey: @"DontUseUndoQueueForROIs"];
        ViewerController *v = Viewer(2, 3);
        ROI *a = R(tOval, @"A"), *b = R(t2DPoint, @"B"), *c = R(tROI, @"C"), *d = R(tText, @"D");
        [b setValue: @YES forKey: @"_isAliased"];
        HorosVolumeLengthROI *l = L(@"L", @"V1");
        [v->roiList[0][0] addObjectsFromArray: @[a, b, l]];
        [v->roiList[0][1] addObjectsFromArray: @[b, c, l]];
        [v->roiList[0][2] addObjectsFromArray: @[b, l]];
        [v->roiList[1][0] addObject: d];
        [v addToUndoQueue: @"roi"];
        Queues(v);
        [v->roiList[0][1] removeObject: c];
        [v->roiList[0][2] addObject: R(tText, @"E")];
        [v addToUndoQueue: @"roi"];
        [v->roiList[0][0] removeAllObjects];
        [v undo: nil];
        DumpROIs(v); Queues(v);
        [v redo: nil];
        DumpROIs(v); Queues(v);
        [v undo: nil]; [v undo: nil];
        DumpROIs(v); Queues(v);
        [v undo: nil];
        [v redo: nil]; [v redo: nil]; [v redo: nil];
        DumpROIs(v); Queues(v);
    });
    RUN("the size of the queue", {
        [defaults setInteger: 2 forKey: @"UndoQueueSize"];
        ViewerController *v = Viewer(1, 2);
        [v->roiList[0][0] addObject: R(tOval, @"A")];
        for (int i = 0; i < 4; i++) [v addToUndoQueue: @"roi"];
        Queues(v);
        [v removeLastItemFromUndoQueue]; Queues(v);
        [v removeLastItemFromUndoQueue]; [v removeLastItemFromUndoQueue]; Queues(v);
        [defaults setBool: YES forKey: @"DontUseUndoQueueForROIs"];
        [v addToUndoQueue: @"roi"]; Queues(v);
        [defaults setBool: NO forKey: @"DontUseUndoQueueForROIs"];
        [defaults setInteger: 0 forKey: @"UndoQueueSize"];
        [v addToUndoQueue: @"roi"]; Queues(v);
        [defaults setInteger: -1 forKey: @"UndoQueueSize"];
        [v addToUndoQueue: @"roi"]; Queues(v);
        [defaults setInteger: 1 forKey: @"UndoQueueSize"];
        [v addToUndoQueue: @"roi"]; [v addToUndoQueue: @"roi"]; Queues(v);
    });
    RUN("a state of another kind", {
        [defaults setInteger: 5 forKey: @"UndoQueueSize"];
        ViewerController *v = Viewer(1, 1);
        Record([NSString stringWithFormat: @"prepare other %@", Name([v prepareObjectForUndo: @"other"])]);
        Record([NSString stringWithFormat: @"prepare nil %@", Name([v prepareObjectForUndo: nil])]);
        [v->undoQueue addObject: @{@"type": @"other"}];
        [v executeUndo: v->undoQueue];
        Queues(v);
        [v executeUndo: [NSMutableArray array]];
        [v->undoQueue removeAllObjects];
        [v undo: nil]; [v redo: nil];
        Queues(v);
    });
    RUN("a ROI that cannot be copied", {
        [defaults setInteger: 5 forKey: @"UndoQueueSize"];
        ViewerController *v = Viewer(1, 2);
        ROI *bad = R(tOval, @"bad");
        bad.harnessCopyFails = YES;
        [v->roiList[0][1] addObjectsFromArray: @[R(tROI, @"ok"), bad]];
        Record([NSString stringWithFormat: @"prepare %@", Name([v prepareObjectForUndo: @"roi"])]);
        [v addToUndoQueue: @"roi"];
    });
    RUN("undo with a volume length of another time point", {
        [defaults setInteger: 5 forKey: @"UndoQueueSize"];
        ViewerController *v = Viewer(2, 2);
        HorosVolumeLengthROI *l = L(@"L2", @"V2");
        [v->roiList[1][0] addObject: l]; [v->roiList[1][1] addObject: l];
        [v addToUndoQueue: @"roi"];
        [v undo: nil];
        DumpROIs(v);
        Record([NSString stringWithFormat: @"state m1 %@", Name([v volumeLengthStateForMovieIndex: 1 create: NO])]);
    });
}

static NSString *Touch(NSString *name) {
    NSString *path = [harnessTemporary stringByAppendingPathComponent: name];
    [[NSData data] writeToFile: path atomically: NO];
    return path;
}

static void VolumeLength(void) {
    RUN("states, registration and attachment", {
        ViewerController *v = Viewer(2, 3);
        v->curMovieIndex = 0; v->imageView.curImage = 2;
        Record([NSString stringWithFormat: @"state none %@", Name([v volumeLengthStateForMovieIndex: 0 create: NO])]);
        Record([NSString stringWithFormat: @"state -1 %@ 8 %@", Name([v volumeLengthStateForMovieIndex: -1 create: YES]), Name([v volumeLengthStateForMovieIndex: 8 create: YES])]);
        Record([NSString stringWithFormat: @"state 0 %@", Name([v volumeLengthStateForMovieIndex: 0 create: YES])]);
        HorosVolumeLengthROI *l1 = L(@"L1", @"V1");
        [v addVolumeLengthROI: l1];
        DumpROIs(v);
        HorosVolumeLengthROI *l2 = L(@"L2", @"V2");
        [v addVolumeLengthROI: l2 movieIndex: 1];
        [v addVolumeLengthROI: L(@"L3", @"V3") movieIndex: 2];
        [v addVolumeLengthROI: L(@"L4", nil) movieIndex: 0];
        [v addVolumeLengthROI: L(@"L5", @"") movieIndex: 0];
        HorosVolumeLengthROI *l1b = L(@"L1b", @"V1");
        [v addVolumeLengthROI: l1b];
        DumpROIs(v);
        DicomImage *third = v->fileList[0][2];
        HorosVolumeLengthROI *l6 = L(@"L6", @"V6");
        [v registerVolumeLengthROI: l6 movieIndex: 0 anchor: third];
        [v registerVolumeLengthROI: l6 movieIndex: 0 anchor: nil];
        [v attachVolumeLengthROI: l6 movieIndex: 0];
        [v attachVolumeLengthROI: l6 movieIndex: 9];
        [v registerVolumeLengthROI: L(@"L7", nil) movieIndex: 0 anchor: third];
        Record([NSString stringWithFormat: @"state 0 %@", Name([v volumeLengthStateForMovieIndex: 0 create: NO])]);
        Record([NSString stringWithFormat: @"state 1 %@", Name([v volumeLengthStateForMovieIndex: 1 create: NO])]);
        Record([NSString stringWithFormat: @"lengths 0 %@ 1 %@ 7 %@ 9 %@", Name([v volumeLengthROIsForMovieIndex: 0]), Name([v volumeLengthROIsForMovieIndex: 1]),
                Name([v volumeLengthROIsForMovieIndex: 7]), Name([v volumeLengthROIsForMovieIndex: 9])]);
        // A time point whose first file is not an image.
        ViewerController *w = Viewer(1, 2);
        [w->fileList[0] replaceObjectAtIndex: 0 withObject: @"not an image"];
        [w addVolumeLengthROI: L(@"L8", @"V8")];
        Record([NSString stringWithFormat: @"state w %@", Name([w volumeLengthStateForMovieIndex: 0 create: NO])]);
    });
    RUN("snapshots", {
        ViewerController *v = Viewer(1, 3);
        [v addVolumeLengthROI: L(@"L1", @"V1")];
        [v->roiList[0][1] addObject: R(tOval, @"O")];
        DicomImage *second = v->fileList[0][1];
        NSDictionary *snapshot = @{@"state": @{@"anchors": @{@"V9": second}, @"anchor": second, @"extra": @"kept"},
                                   @"rois": @[L(@"L9", @"V9"), L(@"L10", @"V10")]};
        [v restoreVolumeLengthSnapshot: snapshot movieIndex: 0];
        DumpROIs(v);
        Record([NSString stringWithFormat: @"state %@", Name([v volumeLengthStateForMovieIndex: 0 create: NO])]);
        [v restoreVolumeLengthSnapshot: @{} movieIndex: 0];
        DumpROIs(v);
        Record([NSString stringWithFormat: @"state %@", Name([v volumeLengthStateForMovieIndex: 0 create: NO])]);
        [v restoreVolumeLengthSnapshot: snapshot movieIndex: 8];
    });
    RUN("saving", {
        ViewerController *v = Viewer(1, 3);
        DicomImage *first = v->fileList[0][0], *second = v->fileList[0][1], *third = v->fileList[0][2];
        DicomStudy *study = [[DicomStudy new] autorelease];
        DicomSeries *series = [[DicomSeries new] autorelease], *sr = [[DicomSeries new] autorelease];
        series.study = study; sr.seriesDICOMUID = @"1.2.840.sr";
        study.harnessSRSeries = sr;
        first.series = series; second.series = series; third.series = series;
        NSString *archive = Touch(@"first.dcm");
        study.harnessPaths = [NSMutableDictionary dictionaryWithDictionary: @{Name(first): archive, Name(third): [harnessTemporary stringByAppendingPathComponent: @"missing.dcm"]}];
        HorosVolumeLengthROI *old = L(@"old", @"V1"), *other = L(@"other", @"V2");
        ROI *plain = R(tOval, @"plain");
        harnessArchives[archive] = @[old, other, plain];
        HorosVolumeLengthROI *l1 = L(@"L1", @"V1"), *l2 = L(@"L2", @"V2"), *l3 = L(@"L3", @"V3");
        [v addVolumeLengthROI: l1];
        [v registerVolumeLengthROI: l2 movieIndex: 0 anchor: second];
        [v attachVolumeLengthROI: l2 movieIndex: 0];
        [v registerVolumeLengthROI: l3 movieIndex: 0 anchor: third];
        [v attachVolumeLengthROI: l3 movieIndex: 0];
        NSMutableArray *paths = [NSMutableArray array];
        NSString *secondPath = Touch(@"second.roi");
        harnessArchives[secondPath] = @[];
        [v saveVolumeLengthROIs: 0 writtenPaths: paths anchorPaths: @{second.objectID: secondPath}];
        Record([NSString stringWithFormat: @"written %@", Name(paths)]);
        // Again: what the archives hold now is what would be written.
        [v saveVolumeLengthROIs: 0 writtenPaths: paths anchorPaths: @{second.objectID: secondPath}];
        Record([NSString stringWithFormat: @"written %@", Name(paths)]);
        // A path that fails, and no SR series.
        study.harnessSRSeries = nil;
        NSString *fails = Touch(@"fails.dcm");
        harnessArchives[fails] = @[];
        [v saveVolumeLengthROIs: 0 writtenPaths: paths anchorPaths: @{first.objectID: fails}];
        Record([NSString stringWithFormat: @"written %@", Name(paths)]);
        [v saveVolumeLengthROIs: 0 writtenPaths: nil anchorPaths: nil];
        // An archive that cannot be read.
        NSString *broken = Touch(@"broken.dcm");
        harnessArchives[broken] = @"unreadable";
        [v saveVolumeLengthROIs: 0 writtenPaths: paths anchorPaths: @{first.objectID: broken}];
    });
    RUN("saving without lengths", {
        ViewerController *v = Viewer(1, 1);
        [v saveVolumeLengthROIs: 0 writtenPaths: [NSMutableArray array] anchorPaths: nil];
        [v volumeLengthStateForMovieIndex: 0 create: YES];
        [v saveVolumeLengthROIs: 0 writtenPaths: [NSMutableArray array] anchorPaths: nil];
    });
}

static void Line(ROI *r, NSPoint a, NSPoint b) {
    [[r valueForKey: @"_points"] addObject: [MyPoint point: a]];
    [[r valueForKey: @"_points"] addObject: [MyPoint point: b]];
    r.pixelSpacingX = 0.5; r.pixelSpacingY = 0.75;
    [r setValue: @2.5f forKey: @"_thickness"]; [r setValue: @0.75f forKey: @"_opacity"];
    RGBColor c = {100, 2000, 65535};
    [r setValue: [NSValue valueWithBytes: &c objCType: @encode(RGBColor)] forKey: @"_rgbcolor"];
}

static ROI *At(ViewerController *v, ROI *r, int slice, NSPoint p) {
    [r setValue: [NSValue valueWithRect: NSMakeRect(p.x, p.y, 0, 0)] forKey: @"_rect"];
    [v->roiList[0][slice] addObject: r];
    return r;
}

static void Pick(ViewerController *v, ROI *preferred) {
    NSDictionary *first = nil, *second = nil;
    BOOL found = [v horosPickInterslicePreferred: preferred first: &first second: &second];
    Record([NSString stringWithFormat: @"pick %@ -> %d %@ %@ / %@ %@", Name(preferred), found, Name(first[@"roi"]), Name(first[@"slice"]), Name(second[@"roi"]), Name(second[@"slice"])]);
}

static void Geometry(void) {
    RUN("constructions of a line", {
        [defaults setInteger: 5 forKey: @"UndoQueueSize"];
        ViewerController *v = Viewer(1, 2);
        v->imageView.curImage = 1;
        ROI *text = R(tText, @"text"), *line = R(tMesure, @"line"), *other = R(tMesure, @"menu line");
        Line(line, NSMakePoint(10.25, 4), NSMakePoint(20.5, 30.125));
        Line(other, NSMakePoint(-3, 2), NSMakePoint(8, -6.5));
        Quiet(line, @"l", ROI_selected, 7);
        [v.harnessSelected addObjectsFromArray: @[text, line]];
        [v generateGeometryFromSelectedLine: nil];
        DumpROIs(v);
        [v generateGeometryFromSelectedLine: Item(other)];
        [v generateGeometryFromSelectedLine: Item(@"not a ROI")];
        other.locked = YES;
        [v generateGeometryFromSelectedLine: Item(other)];
        ROI *shortLine = R(tMesure, @"short");
        [[shortLine valueForKey: @"_points"] addObject: [MyPoint point: NSMakePoint(1, 1)]];
        [v generateGeometryFromSelectedLine: Item(shortLine)];
        [v generateGeometryFromSelectedLine: Item(text)];
        ROI *flat = R(tMesure, @"flat");
        Line(flat, NSMakePoint(1, 1), NSMakePoint(2, 2));
        flat.pixelSpacingX = 0;
        [v generateGeometryFromSelectedLine: Item(flat)];
        [v.harnessSelected removeAllObjects];
        [v generateGeometryFromSelectedLine: nil];
        Queues(v);
    });
    RUN("measures between slices", {
        [defaults setInteger: 5 forKey: @"UndoQueueSize"];
        ViewerController *v = Viewer(1, 4), *blended = Viewer(1, 2), *registered = Viewer(1, 2);
        v->imageView.curImage = 2;
        ROI *p1 = At(v, R(t2DPoint, @"P1"), 0, NSMakePoint(3.5, 4.25));
        ROI *p2 = At(v, R(t2DPoint, @"P2"), 2, NSMakePoint(7, 1.5));
        ROI *p3 = At(v, R(t2DPoint, @"P3"), 2, NSMakePoint(9.25, 2));
        ROI *p4 = At(v, R(t2DPoint, @"P4"), 3, NSMakePoint(1, 1));
        p4.locked = YES;
        ROI *alias = R(t2DPoint, @"alias");
        At(v, alias, 1, NSMakePoint(5, 5)); At(v, alias, 3, NSMakePoint(5, 5));
        At(v, R(tOval, @"oval"), 1, NSMakePoint(2, 2));
        ROI *q = R(t2DPoint, @"Q");
        [q setValue: [NSValue valueWithRect: NSMakeRect(6, 6.5, 0, 0)] forKey: @"_rect"];
        [blended->roiList[0][1] addObject: q];
        Quiet(p1, @"p1", ROI_sleep, 0); Quiet(p2, @"p2", ROI_sleep, 0); Quiet(p3, @"p3", ROI_sleep, 0);
        Pick(v, nil);
        Pick(v, p2); Pick(v, p3); Pick(v, alias); Pick(v, p4);
        Quiet(p2, @"p2", ROI_selected, 0); Quiet(p3, @"p3", ROI_selectedModify, 0);
        Pick(v, nil);
        Pick(v, p1);
        Quiet(p3, @"p3", ROI_sleep, 0);
        Pick(v, nil);
        Quiet(p1, @"p1", ROI_drawing, 0);
        Pick(v, nil);
        v.blendedWindow = blended;
        Pick(v, q);
        v->blendingController = blended;
        Pick(v, nil);
        v->blendingController = v;
        v->registeredViewer = registered;
        ROI *r1 = R(t2DPoint, @"R1");
        [r1 setValue: [NSValue valueWithRect: NSMakeRect(1.25, 2.5, 0, 0)] forKey: @"_rect"];
        [registered->roiList[0][0] addObject: r1];
        Pick(v, r1);
        [v measureBetweenSelectedSlices: nil];
        [v measureBetweenSelectedSlices: Item(p3)];
        [v measureBetweenSelectedSlices: Item(r1)];
        Quiet(p2, @"p2", ROI_selected, 4); Quiet(p3, @"p3", ROI_selected, 0);
        [v measureBetweenSelectedSlices: Item(p1)];
        DumpROIs(v);
        // The measure cannot be made.
        [p2 setValue: [NSValue valueWithRect: NSMakeRect(999, 1, 0, 0)] forKey: @"_rect"];
        [v measureBetweenSelectedSlices: Item(p2)];
        Queues(v);
    });
    RUN("no two points", {
        ViewerController *v = Viewer(1, 2);
        At(v, R(t2DPoint, @"lone"), 0, NSMakePoint(1, 1));
        Pick(v, nil);
        [v measureBetweenSelectedSlices: nil];
        ViewerController *w = Viewer(1, 2);
        ROI *both = R(t2DPoint, @"both");
        At(w, both, 0, NSMakePoint(1, 1)); At(w, both, 1, NSMakePoint(1, 1));
        Pick(w, both);
        Record([NSString stringWithFormat: @"records %@", Name([v horosInterslicePointRecords])]);
    });
}

static ROI *Brush(NSString *label, int contour) {
    ROI *r = [[[ROI alloc] initWithTexture: (unsigned char[]){(unsigned char)contour, 9, 8, 7, 6, 5} textWidth: 3 textHeight: 2 textName: label
                                  positionX: 4 positionY: -2 spacingX: 0.5f spacingY: 0.25f imageOrigin: NSMakePoint(1, 2)] autorelease];
    r.label = label;
    return r;
}

static void Brushes(void) {
    RUN("filters", {
        [defaults setInteger: 5 forKey: @"UndoQueueSize"];
        ViewerController *v = Viewer(2, 2);
        ROI *b1 = Brush(@"B1", 4), *b2 = Brush(@"B2", 4), *b3 = Brush(@"B3", 4);
        Quiet(b1, @"tumour", ROI_selected, 0); Quiet(b2, @"tumour", ROI_sleep, 0);
        [v->roiList[0][0] addObject: b1]; [v->roiList[1][1] addObject: b2]; [v->roiList[0][1] addObject: b3];
        [v applyMorphology: @[b1, b2, b3] action: @"dilate" radius: 4 sendNotification: YES]; Flush();
        [v applyMorphology: @[b1] action: @"open" radius: 5000000000L sendNotification: NO]; Flush();
        [v applyMorphology: @[b2, b3] action: nil radius: 2 sendNotification: NO]; Flush();
        [v applyMorphology: @[] action: @"close" radius: 2 sendNotification: YES]; Flush();
        [v applyMorphology: @[b1] action: @"unknown" radius: 2 sendNotification: NO]; Flush();
        NSSlider *slider = [[[NSSlider alloc] init] autorelease];
        slider.minValue = 0; slider.maxValue = 20; slider.intValue = 7;
        v->structuringElementRadiusSlider = slider;
        NSTextField *field = [[[HorosFormField alloc] init] autorelease];
        Register(field, @"radius field");
        v->structuringElementRadiusTextField = field;
        [v setStructuringElementRadius: nil];
        v->brushROIFilterOptionsWindow = [NewWindow(@"filter sheet") autorelease];
        NSButton *same = [[[NSButton alloc] init] autorelease];
        [same setButtonType: NSButtonTypeSwitch];
        v->brushROIFilterOptionsAllWithSameName = same;
        [v.harnessSelected addObject: b1];
        for (int tag = 0; tag < 4; tag++) {
            [v morphoSelectedBrushROI: Tag(tag)];
            Record([NSString stringWithFormat: @"morpho %@", Name(v->morphoFunction)]);
            [v morphoSelectedBrushROIWithRadius: Tag(tag % 2)]; Flush();
        }
        same.state = NSControlStateValueOn;
        [v morphoSelectedBrushROIWithRadius: Tag(1)]; Flush();
        [v.harnessSelected removeAllObjects];
        [v.harnessSelected addObject: R(tOval, @"oval")];
        [v morphoSelectedBrushROI: Tag(2)];
        [v.harnessSelected removeAllObjects];
        [v morphoSelectedBrushROI: Tag(1)];
        Queues(v);
    });
    RUN("conversions", {
        ViewerController *v = Viewer(1, 3);
        v->imageView.curDCM = v->pixList[0][1];
        ROI *oval = R(tOval, @"oval");
        [[oval valueForKey: @"_points"] addObject: [MyPoint point: NSMakePoint(1, 2)]];
        Record([NSString stringWithFormat: @"oval -> %@", Name([v convertPolygonROItoBrush: oval])]);
        ROI *empty = R(tCPolygon, @"empty");
        empty.harnessReduceEmpty = YES;
        Record([NSString stringWithFormat: @"empty -> %@", Name([v convertPolygonROItoBrush: empty])]);
        ROI *nomap = R(tOPolygon, @"no map");
        nomap.harnessNoMap = YES;
        Record([NSString stringWithFormat: @"no map -> %@", Name([v convertPolygonROItoBrush: nomap])]);
        Record([NSString stringWithFormat: @"pencil -> %@", Name([v convertPolygonROItoBrush: R(tPencil, @"pencil")])]);
        Record([NSString stringWithFormat: @"text -> %@", Name([v convertPolygonROItoBrush: R(tText, @"text")])]);
        int contours[] = {7, 1, 3, 250, 100};
        int counts[] = {100, 3, 0, 7, 100};
        for (int i = 0; i < 5; i++) {
            ROI *brush = Brush([NSString stringWithFormat: @"brush %d", i], contours[i]);
            Record([NSString stringWithFormat: @"brush %d -> %@", i, Name([v convertBrushROItoPolygon: brush numPoints: counts[i]])]);
        }
        Record([NSString stringWithFormat: @"oval -> %@", Name([v convertBrushROItoPolygon: R(tOval, @"oval 2") numPoints: 10])]);
    });
    RUN("merge, index and conversion of the applied ROIs", {
        [defaults setInteger: 5 forKey: @"UndoQueueSize"];
        ViewerController *v = Viewer(1, 3);
        v->imageView.curImage = 1;
        ROI *b1 = Brush(@"B1", 5), *b2 = Brush(@"B2", 6), *b3 = Brush(@"B3", 7), *poly = R(tCPolygon, @"poly"), *text = R(tText, @"text");
        Quiet(b1, @"b1", 0, 0); Quiet(poly, @"poly", 0, 0);
        poly.commentsString = @"comment";
        poly.curView = v->imageView;
        b1.curView = v->imageView;
        [v->roiList[0][1] addObjectsFromArray: @[b1, poly, b2, text]];
        [v->roiList[0][2] addObjectsFromArray: @[b3]];
        Record([NSString stringWithFormat: @"index %d %d %d", [v imageIndexOfROI: b3], [v imageIndexOfROI: text], [v imageIndexOfROI: Brush(@"nowhere", 1)]]);
        [v mergeBrushROI: nil ROIs: @[b1, poly, b2] ROIList: v->roiList[0][1]];
        DumpROIs(v);
        [v mergeBrushROI: nil ROIs: @[] ROIList: v->roiList[0][1]];
        [v mergeBrushROI: nil ROIs: @[text] ROIList: v->roiList[0][1]];
        [v.harnessSelected addObjectsFromArray: @[b2, b1]];
        [v->roiList[0][1] addObject: b1];
        [v mergeBrushROI: nil];
        DumpROIs(v);
        v.harnessApply = [NSMutableArray arrayWithArray: @[b1, poly, Brush(@"elsewhere", 3), text, b2]];
        [v convertBrushPolygon: nil];
        DumpROIs(v);
        Queues(v);
    });
    RUN("pixel fill operations", {
        ViewerController *v = Viewer(1, 1);
        DCMPix *pix = v->pixList[0][0];
        ROI *roi = R(tOval, @"filled");
        NSDictionary *dicts[] = {
            @{@"action": @"setPixel", @"curPix": pix, @"newValue": @12.5, @"minValue": @-3, @"maxValue": @1e6, @"outside": @YES, @"stackNo": @4, @"revert": @NO, @"addition": @YES},
            @{@"action": @"setPixelRoi", @"curPix": pix, @"roi": roi, @"newValue": @-1, @"minValue": @0.25, @"maxValue": @2, @"outside": @NO, @"stackNo": @-1, @"revert": @YES},
            @{@"action": @"setPixelRoi", @"roi": roi},
            @{@"action": @"erode", @"roi": roi, @"radius": @3, @"filter": [[ITKBrushROIFilter new] autorelease]},
            @{@"action": @"open", @"roi": roi, @"radius": @2},
            @{@"curPix": pix},
        };
        for (int i = 0; i < 6; i++) {
            NSOperation *op = [[(id)[NSClassFromString(@"ViewerControllerOperation") alloc] initWithController: v dict: dicts[i]] autorelease];
            [op main];
            Flush();
        }
        NSOperation *op = [[(id)[NSClassFromString(@"ViewerControllerOperation") alloc] initWithController: nil dict: nil] autorelease];
        [op main];
        Record([NSString stringWithFormat: @"operation class %@ of %@", NSStringFromClass([op class]), NSStringFromClass([op superclass])]);
    });
}

static DCMPix *PET(DCMPix *p, int i) {
    p.pwidth = 4; p.pheight = 3;
    float *pixels = malloc(12 * sizeof(float));
    for (int k = 0; k < 12; k++) pixels[k] = (float)((k * 37 + i * 11) % 97) * 1.37f - 3.0f;
    p.fImage = pixels;
    [p setValue: @"BQML" forKey: @"units"];
    p->hasSUVValue = YES;
    [p setValue: @(70.5f + i) forKey: @"_patientsWeight"];
    [p setValue: @(3.7e8f) forKey: @"_radionuclideTotalDose"];
    p.radionuclideTotalDoseCorrected = 3.1e8f - i * 1e6f;
    p.decayFactor = 1.0625f + i * 0.01f;
    p.halflife = 6586.2f;
    [p setValue: @(40.25f + i) forKey: @"_savedWL"];
    [p setValue: @(380.5f) forKey: @"_savedWW"];
    [p setValue: [NSDate dateWithTimeIntervalSinceReferenceDate: 1000 + i] forKey: @"_acquisitionTime"];
    [p setValue: [NSDate dateWithTimeIntervalSinceReferenceDate: 400] forKey: @"_radiopharmaceuticalStartTime"];
    return p;
}

static ViewerController *PETViewer(void) {
    ViewerController *v = Viewer(2, 2);
    int i = 0;
    for (int m = 0; m < 2; m++) for (DCMPix *p in v->pixList[m]) PET(p, i++);
    return v;
}

static void Pixels(ViewerController *v) {
    for (int m = 0; m < v->maxMovieIndex; m++) for (DCMPix *p in v->pixList[m])
        Record([NSString stringWithFormat: @" %@ pixels %016llx converted %d factor %a wl %a ww %a", Name(p), Checksum(p.fImage, 48), p.SUVConverted, p.factorPET2SUV, p.savedWL, p.savedWW]);
    Record([NSString stringWithFormat: @" factorPET2SUV %a", [v factorPET2SUV]]);
}

static void Panels(ViewerController *v) {
    v->displaySUVWindow = NewWindow(@"SUV sheet");
    v->injectionTimeWindow = NewWindow(@"injection sheet");
    v->suvForm = [[HorosFormView alloc] init];
    NSMutableArray *cells = [NSMutableArray array];
    for (int i = 0; i < 6; i++) {
        HorosFormField *f = [[[HorosFormField alloc] init] autorelease];
        Register(f, [NSString stringWithFormat: @"cell %d", i]);
        [cells addObject: f];
    }
    v->suvForm.harnessCells = cells;
    v->suvConversion = [[NSMatrix alloc] initWithFrame: NSMakeRect(0, 0, 90, 30) mode: NSRadioModeMatrix cellClass: [NSButtonCell class] numberOfRows: 1 numberOfColumns: 3];
    for (int i = 0; i < 3; i++) [[v->suvConversion cellAtRow: 0 column: i] setTag: i];
    [v->suvConversion selectCellWithTag: 1];
}

static void SUV(void) {
    RUN("conversions", {
        [defaults setInteger: 0 forKey: @"DEFAULTPETWLWW"];
        for (int c = 0; c < 9; c++) {
            Record([NSString stringWithFormat: @"-- case %d", c]);
            ViewerController *v = PETViewer();
            DCMPix *cur = v->pixList[0][0];
            if (c == 1) cur.isRGB = YES;
            if (c == 2) { cur.units = @"CNTS"; cur->philipsFactorValue = 0.00125f; cur.radionuclideTotalDoseCorrected = 0; }
            if (c == 3) { cur.units = @"CNTS"; cur.radionuclideTotalDoseCorrected = 0; }
            if (c == 4) [cur setValue: @0.0f forKey: @"_patientsWeight"];
            if (c == 5) cur->hasSUVValue = NO;
            if (c == 6) { [v->pixList[1][0] setValue: @YES forKey: @"_SUVConverted"]; ((DCMPix*)v->pixList[0][1]).units = @"CNTS"; ((DCMPix*)v->pixList[0][1])->philipsFactorValue = 2.5f; }
            if (c == 7) [defaults setInteger: 1 forKey: @"DEFAULTPETWLWW"];
            if (c == 8) { cur.units = @"CNTS"; cur->philipsFactorValue = 0.75f; cur.radionuclideTotalDoseCorrected = -1; }
            [v convertPETtoSUV];
            [defaults setInteger: 0 forKey: @"DEFAULTPETWLWW"];
            Pixels(v);
            [v recomputePixMinMax];
        }
    });
    RUN("the SUV sheet", {
        [defaults setInteger: 2 forKey: @"SUVCONVERSION"];
        ViewerController *v = PETViewer();
        Panels(v);
        ((DCMPix*)v->pixList[0][0])->hasSUVValue = NO;
        [v displaySUV: nil];
        ((DCMPix*)v->pixList[0][0])->hasSUVValue = YES;
        [v displaySUV: nil];
        [v->pixList[0][0] setValue: nil forKey: @"_acquisitionTime"];
        [v->pixList[0][0] setValue: nil forKey: @"_radiopharmaceuticalStartTime"];
        [v displaySUV: nil];
        Record([NSString stringWithFormat: @"selected %ld", (long)[v->suvConversion selectedTag]]);
    });
    RUN("the values of the sheet", {
        ViewerController *v = PETViewer();
        Panels(v);
        DCMPix *cur = v->pixList[0][0];
        [v->suvForm cellAtIndex: 1].stringValue = @"412.5";
        [v->suvForm cellAtIndex: 3].objectValue = [NSDate dateWithTimeIntervalSinceReferenceDate: 1500];
        [v updateSUVValues: nil];
        [v->suvForm cellAtIndex: 3].objectValue = [NSDate dateWithTimeIntervalSinceReferenceDate: 600.5];
        [v updateSUVValues: nil];
        [cur setValue: nil forKey: @"_radiopharmaceuticalStartTime"];
        [v->suvForm cellAtIndex: 3].objectValue = [NSDate dateWithTimeIntervalSinceReferenceDate: 1000];
        [v updateSUVValues: nil];
        [v->suvForm cellAtIndex: 3].objectValue = nil;
        [v updateSUVValues: nil];
        [cur setValue: nil forKey: @"_acquisitionTime"];
        [v->suvForm cellAtIndex: 3].objectValue = [NSDate dateWithTimeIntervalSinceReferenceDate: 600.5];
        [v updateSUVValues: nil];
    });
    RUN("the injection time sheet", {
        ViewerController *v = PETViewer();
        Panels(v);
        [v->displaySUVWindow beginSheet: v->injectionTimeWindow completionHandler: nil];
        harnessModal = ^{ [v ok: nil]; };
        [v editSUVinjectionTime: Tag(0)];
        harnessModal = ^{ v.injectionDateTime = [NSDate dateWithTimeIntervalSinceReferenceDate: 777.25]; [v ok: nil]; };
        [v editSUVinjectionTime: Tag(1)];
        harnessModal = ^{ [v cancel: nil]; };
        [v editSUVinjectionTime: Tag(0)];
        harnessModal = ^{ [v ok: nil]; };
        [v editSUVinjectionTime: Tag(2)];
        harnessModal = nil;
        Record([NSString stringWithFormat: @"edited %@ %@ injection %@", Name(v->editedRadiopharmaceuticalStartTime), Name(v->editedAcquisitionTime), Name(v.injectionDateTime)]);
    });
    RUN("the end of the sheet", {
        [defaults setBool: YES forKey: @"ConvertPETtoSUVautomatically"];
        for (int c = 0; c < 6; c++) {
            Record([NSString stringWithFormat: @"-- case %d", c]);
            ViewerController *v = PETViewer();
            Panels(v);
            [v->suvForm cellAtIndex: 0].stringValue = c == 1 ? @"0" : @"68.25";
            [v->suvForm cellAtIndex: 1].stringValue = @"350.75";
            [v->suvForm cellAtIndex: 3].objectValue = [NSDate dateWithTimeIntervalSinceReferenceDate: 450];
            [v->suvConversion selectCellWithTag: c == 2 ? 2 : c == 3 ? 0 : 1];
            if (c == 4) {
                for (int m = 0; m < 2; m++) for (DCMPix *p in v->pixList[m]) [p setValue: @YES forKey: @"_SUVConverted"];
                v->editedAcquisitionTime = [[NSDate dateWithTimeIntervalSinceReferenceDate: 1200] retain];
                v->editedRadiopharmaceuticalStartTime = [[NSDate dateWithTimeIntervalSinceReferenceDate: 300] retain];
            }
            if (c == 5) { [v->suvConversion selectCellWithTag: 2]; [[v->suvConversion selectedCell] setTag: 7]; }
            [v endDisplaySUV: Tag(c == 0 ? 0 : 1)];
            Record([NSString stringWithFormat: @"ConvertPETtoSUVautomatically %d SUVCONVERSION %ld", [defaults boolForKey: @"ConvertPETtoSUVautomatically"], (long)[defaults integerForKey: @"SUVCONVERSION"]]);
            Pixels(v);
        }
        [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 2.3]];
        Record([NSString stringWithFormat: @"after 2 s ConvertPETtoSUVautomatically %d", [defaults boolForKey: @"ConvertPETtoSUVautomatically"]]);
    });
    RUN("cancel and ok", {
        ViewerController *v = Viewer(1, 1);
        v.injectionDateTime = [NSDate dateWithTimeIntervalSinceReferenceDate: 5];
        [v ok: nil];
        Record([NSString stringWithFormat: @"injection %@", Name(v.injectionDateTime)]);
        [v cancel: nil];
        Record([NSString stringWithFormat: @"injection %@", Name(v.injectionDateTime)]);
        [v restoreConvertPETtoSUVautomaticallyValue: @NO];
        Record([NSString stringWithFormat: @"ConvertPETtoSUVautomatically %d", [defaults boolForKey: @"ConvertPETtoSUVautomatically"]]);
    });
}

static void ControllerRetains(void) {
    for (NSWindow *w in harnessWindows) {
        NSWindowController *c = [w windowController];
        if ([c isKindOfClass: [PaletteController class]] || [c isKindOfClass: [CalciumScoringWindowController class]])
            Record([NSString stringWithFormat: @"%@ retained %lu", Name(c), (unsigned long)[c retainCount]]);
    }
}

static void Tools(void) {
    RUN("brush palette", {
        ViewerController *v = Viewer(1, 1);
        [v brushTool: nil];
        [v brushTool: nil];
        PaletteController *palette = (PaletteController*)[[harnessWindows lastObject] windowController];
        palette.windowWillClose = YES;
        [v brushTool: nil];
        NSWindow *other = NewWindow(@"plain window");
        [harnessWindows addObject: other];
        [v brushTool: nil];
    });
    // The palettes and calcium windows own themselves until they close: the
    // viewer leaves them the +1 it created them with.
    ControllerRetains();
    RUN("calcium scoring", {
        ViewerController *v = Viewer(1, 1);
        [v calciumScoring: nil];
        [v calciumScoring: nil];
        CalciumScoringWindowController *c = (CalciumScoringWindowController*)[[harnessWindows lastObject] windowController];
        c.windowWillClose = YES;
        [v calciumScoring: Tag(3)];
    });
    ControllerRetains();
    Record([NSString stringWithFormat: @"windows %@", Name(harnessWindows)]);
    RUN("calibration warning", {
        ViewerController *v = Viewer(1, 1);
        harnessAlertResponse = 1;
        [v calibrate: Tag(4)];
        harnessAlertResponse = 0;
        [v calibrate: Tag(4)];
        harnessAlertResponse = -1;
        [v calibrate: nil];
        harnessAlertResponse = 1;
    });
    RUN("new ROIs and points, the lock", {
        ViewerController *v = Viewer(1, 2);
        v->imageView.curDCM = v->pixList[0][1];
        ROI *r = [v newROI: tOval];
        Record([NSString stringWithFormat: @"newROI %@ type %d retain %lu", Name(r), r.type, (unsigned long)[r retainCount]]);
        v->imageView.curDCM = nil;
        r = [v newROI: tText];
        Record([NSString stringWithFormat: @"newROI %@ retain %lu", Name(r), (unsigned long)[r retainCount]]);
        MyPoint *p = [v newPoint: 1.5f : -2.25f];
        Record([NSString stringWithFormat: @"newPoint %@", Name(p)]);
        Record([NSString stringWithFormat: @"lock %d", [v roiLock] == v->roiLock]);
    });
    RUN("calibration numbers", {
        NSArray *entries = @[@"1.5", @"1,5", @" 2.25 ", @"", @"  ", @"\n4\t", @"abc", @"1e39", @"-1e39", @"1e-50", @"1e-45", @"-0", @"0", @"0.0",
                             @"1.5x", @"x1.5", @"inf", @"nan", @"-inf", @"3.4028235e38", @"3.4028236e38", @"1,234.5", @"1.234,5", @"1 234,5",
                             @"0x10", @"+7", @"-3.25", @".5", @"5.", @"1e", @"1e+", @"\uFF11\uFF12", @"\u0661\u0662", @"1\u00A0000", @"12,", @",5",
                             @"7.0e2", @"1E3", @"--1", @"1..2", @"1,2,3", @"0.1", @"16777217", @"123456789012345678901234567890"];
        NSArray *locales = @[@"en_US", @"fr_FR", @"de_DE", @"pt_BR", @"ar_EG", @"en_US_POSIX"];
        for (NSString *identifier in locales) {
            NSLocale *locale = [NSLocale localeWithLocaleIdentifier: identifier];
            NSMutableArray *parts = [NSMutableArray array];
            for (NSString *entry in entries) {
                float value = -12345.0f;
                BOOL ok = HorosCalibrationFloat(entry, locale, &value);
                [parts addObject: [NSString stringWithFormat: @"%d:%a", ok, value]];
            }
            Record([NSString stringWithFormat: @"calibration %@ %@", identifier, [parts componentsJoinedByString: @" "]]);
        }
    });
}

int main(int argc, const char **argv) { @autoreleasepool {
    if (argc != 2) return 2;
    [HarnessApplication sharedApplication];
    harnessWindows = [NSMutableArray new];
    harnessArchives = [NSMutableDictionary new];
    defaults = [NSUserDefaults standardUserDefaults];
    NSString *domain = [[NSProcessInfo processInfo] processName];
    [defaults removePersistentDomainForName: domain];
    harnessTemporary = [[NSTemporaryDirectory() stringByAppendingPathComponent: [NSString stringWithFormat: @"roi-tools-%d", getpid()]] retain];
    [[NSFileManager defaultManager] createDirectoryAtPath: harnessTemporary withIntermediateDirectories: YES attributes: nil error: NULL];
    Observer *observer = [Observer new];
    for (NSString *name in @[OsirixROIChangeNotification, OsirixRemoveROINotification, OsirixAddROINotification,
                             OsirixUpdateVolumeDataNotification, OsirixRecomputeROINotification])
        [[NSNotificationCenter defaultCenter] addObserver: observer selector: @selector(note:) name: name object: nil];
    NSString *scenario = @(argv[1]);
    int status = 0;
    if ([scenario isEqualToString: @"undo"]) Undo();
    else if ([scenario isEqualToString: @"volumelength"]) VolumeLength();
    else if ([scenario isEqualToString: @"geometry"]) Geometry();
    else if ([scenario isEqualToString: @"brush"]) Brushes();
    else if ([scenario isEqualToString: @"suv"]) SUV();
    else if ([scenario isEqualToString: @"tools"]) Tools();
    else status = 3;
    [[NSFileManager defaultManager] removeItemAtPath: harnessTemporary error: NULL];
    [defaults removePersistentDomainForName: domain];
    return status;
} }
'''

# The reference's file-scope declarations, as ViewerController.m had them.
REFERENCE_PRELUDE = '#import "Harness.h"\n#import <objc/runtime.h>\n'


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
    """The index after the closing brace of the method or function at `start` (braces counted)."""
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


# File-scope pieces: the operation class, the volume length archive and its
# key, the calibration number.
PRELUDE_GROUPS = [
    ('@interface ViewerControllerOperation: NSOperation', None),
    ('static char HorosVolumeLengthStateKey;', 'static NSArray *HorosVolumeLengthReadArchive(NSString *path)'),
    ('BOOL HorosCalibrationFloat(NSString *text, NSLocale *locale, float *value)', 'BOOL HorosCalibrationFloat(NSString *text, NSLocale *locale, float *value)'),
]
GROUPS = [
    ('- (NSMutableDictionary *)volumeLengthStateForMovieIndex:(long)movieIndex create:(BOOL)create\n{', '- (void) addToUndoQueue:(NSString*) string'),
    ('- (IBAction) generateGeometryFromSelectedLine:(id) sender', '- (IBAction) measureBetweenSelectedSlices:(id) sender'),
    ('-(IBAction) calibrate:(id) sender', '-(IBAction) calibrate:(id) sender'),
    ('- (ROI*) newROI: (ToolMode) type', '- (IBAction) convertBrushPolygon: (id) sender'),
    ('- (IBAction) cancel:(id)sender', '- (void) displaySUV:(id) sender'),
    ('- (IBAction)calciumScoring:(id)sender', '- (IBAction)calciumScoring:(id)sender'),
]
SHIMS = ['- (ROI*) newROI: (ToolMode) type', '- (MyPoint*) newPoint: (float) x :(float) y']


def objc_blocks(text):
    """The ROI tools of ViewerController.m, in a category of the stand-in."""
    prelude = []
    for first, last in PRELUDE_GROUPS:
        a = text.index(first)
        if last is None:
            implementation = text.index('@implementation ViewerControllerOperation', a)
            b = text.index('\n@end\n', implementation) + len('\n@end\n')
        else:
            b = method_end(text, text.index(last, a))
        prelude.append(text[a:b])
    parts = []
    for first, last in GROUPS:
        a = text.index(first)
        b = method_end(text, text.index(last, a))
        parts.append(text[a:b])
    # #ifndef OSIRIX_LIGHT … #endif inside the groups stay balanced.
    return REFERENCE_PRELUDE + '\n'.join(prelude) + '\n@implementation ViewerController (ROITools)\n' + '\n'.join(parts) + '\n@end\n'


def objc_shim(text):
    """What ViewerController.m keeps of these methods once they are in Swift."""
    parts = []
    for first in SHIMS:
        a = text.index(first)
        parts.append(text[a:method_end(text, a)])
    return '#import "Harness.h"\n@implementation ViewerController (ROITools)\n' + '\n'.join(parts) + '\n@end\n'


# The String forms of a ROI's name and comments, as the app's ROI has them
# beside their NSString forms (name, comments in Objective-C).
ROI_STRINGS = '''
extension ROI {
    var name: String! {
        get { nameString }
        set { nameString = newValue }
    }
    var comments: String! {
        get { commentsString }
        set { commentsString = newValue }
    }
}
'''

# The calibration number of the Swift side, as the C function the driver calls.
CALIBRATION = '''import Foundation
import IsiXImaging

@_cdecl("HorosCalibrationFloat")
func harnessCalibrationFloat(_ text: NSString?, _ locale: NSLocale, _ value: UnsafeMutablePointer<Float>) -> ObjCBool {
    guard let text, let parsed = CalibrationNumber.parse(text as String, locale: locale as Locale) else { return false }
    value.pointee = parsed
    return true
}
'''

reference = args.reference
if reference is None:
    head = read('HEAD', VC)
    reference = 'HEAD' if head and MARK.encode() in head else history_reference.before_text_removed(VC, MARK)
if reference is None:
    print('skipped: needs the history that has the Objective-C ViewerController.m (a shallow clone does not)')
    sys.exit(2)
reference_vc = read(reference, VC)
if reference_vc is None or MARK.encode() not in reference_vc:
    sys.exit('FAIL: %s has no Objective-C ROI tools in %s' % (reference, VC))
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


with tempfile.TemporaryDirectory(prefix='horos-viewer-roi-tools-') as tmp:
    folder = Path(tmp)
    (folder / 'Harness.h').write_text(HEADER)
    (folder / 'Stubs.m').write_text(STUBS.replace('IVAR_IMPLEMENTATIONS', IMPLEMENTED))
    (folder / 'Driver.m').write_text(DRIVER)
    for name in ('HorosObjCException.h', 'HorosObjCException.m'):
        (folder / name).write_bytes((ROOT / 'Horos/Sources' / name).read_bytes())
    frameworks = ['-framework', 'Cocoa']

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
        # [sender tag] as the blocks send it, the @try of the blocks, the closing
        # window controllers.
        support = read(args.current, 'Horos/Sources/ViewerController+ImagePipelineSupport.swift').decode('utf-8')
        sender = re.search(r'\nenum ViewerSender \{.*?\n}\n', support, re.S).group(0)
        attempt = re.search(r'\n/// Runs `body` as an @try block.*?\nfunc viewerObjCTry.*?\n}\n', support, re.S).group(0)
        roi_support = read(args.current, 'Horos/Sources/ViewerController+ROI.swift').decode('utf-8')
        closing = re.search(r'\nfunc horosWindowControllerIsClosing\(.*?\n}\n', roi_support, re.S).group(0)
        (swift / 'Helpers.swift').write_text('import AppKit\n' + sender + attempt + closing + ROI_STRINGS)
        (swift / 'Calibration.swift').write_text(CALIBRATION)
        sources += [str(swift / 'Helpers.swift'), str(swift / 'Calibration.swift')]
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
    print('PASS: the ROI undo, volume lengths, line constructions and measures between slices, brush filters and conversions, SUV, '
          'calibration and tool windows are identical to the Objective-C in every scenario')
