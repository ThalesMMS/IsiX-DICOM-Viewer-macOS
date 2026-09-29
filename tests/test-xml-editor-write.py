#!/usr/bin/env python3
"""The metadata window writes the same bytes as before it moved to Swift (#828).

XMLController edits a file's DICOM attributes: a changed value, an element
inside a sequence item, a deleted element, a deleted private element and an
added one. It turns the rows of its outline into addresses and values, and
XMLControllerDCMTKCategory writes them with GDCM.

The driver runs that path twice, on two disposable copies of one synthetic
file: once with XMLController.swift and once with the former XMLController.m
(and the XMLController.h and XMLControllerDCMTKCategory.mm of its revision),
each linked with the production writer, GDCM, DCMTK and the host DICOM reader
that DCM.framework forwards to. The window is loaded from XMLViewer.xib, the
edits go through the same messages the outline and the Add sheet send, and the
alerts answer their default button. The written files have to be identical to
each other, and to a second run of the former code, and differ from the
original. The database, the viewer and the browser are stand-ins; the file is
the application's only output here.

The values of a multi-valued element are edited in a run of their own (#856):
ImageType is ORIGINAL, PRIMARY, AXIAL; with value [1] changed to SECONDARY and
value [0] deleted it has to read SECONDARY, AXIAL. The former code wrote the
element with the edited value alone and deleted it for one deleted value, so
this run is not compared with it; what it wrote is printed.

A multi-valued element whose first value is empty keeps it (#873):
OtherPatientIDs is (empty), B, C. The window has to show it as \\B\\C, not
B\\C, and with value [2] changed to D and value [1] deleted it has to read \\D.
The values the edit and the Delete key split from the element's row lost the
empty one, and the index of the last value went past them: the edit raised.
That run is the Swift code's alone.

Usage: python test-xml-editor-write.py [--former REVISION] [--products DIR] [--keep DIR]
The former revision defaults to c5a5afd73, the last one with XMLController.m.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs
from dcmtk_build import BUILD, ROOT, dcmtk_flags  # noqa: E402
import horos_reader  # noqa: E402

SKIPPED = 2
parser = argparse.ArgumentParser()
parser.add_argument('--former', default='c5a5afd73')
parser.add_argument('--products', default=str(ROOT / 'build/Build/Products' / BUILD.name))
parser.add_argument('--keep', help='copy the fixture and the written files into this folder')
args = parser.parse_args()

reason = horos_reader.missing(args.products)
gdcm = BUILD / 'GDCM.build/Install'
if reason is None and not (gdcm / 'lib/libgdcmMSFF.a').is_file():
    reason = 'no GDCM in the build'
if reason:
    print('skipped: %s: --products DIR' % reason, file=sys.stderr)
    raise SystemExit(SKIPPED)
if subprocess.run(['git', '-C', str(ROOT), 'cat-file', '-e', args.former + ':Horos/Sources/XMLController.m'],
                  capture_output=True).returncode:
    print('skipped: %s has no XMLController.m: --former REVISION' % args.former, file=sys.stderr)
    raise SystemExit(SKIPPED)
SOURCES = ROOT / 'Horos/Sources'


def former(path):
    return subprocess.run(['git', '-C', str(ROOT), 'show', '%s:%s' % (args.former, path)],
                          check=True, capture_output=True).stdout


# The application's classes the window reaches, reduced to what it uses. Both
# builds read these under the headers' own names.
STUBS_H = r'''
#import <Cocoa/Cocoa.h>
#import <CoreData/CoreData.h>

@class DicomSeries, DicomStudy;

@interface OSIWindowController : NSWindowController
- (void) setMagnetic:(BOOL) a;
@end

@interface DicomStudy : NSManagedObject
@property(nonatomic, retain) NSString *name, *studyName, *patientID;
@end
@interface DicomSeries : NSManagedObject
@property(nonatomic, retain) DicomStudy *study;
@end
@interface DicomImage : NSManagedObject
@property(nonatomic, retain) DicomSeries *series;
@property(nonatomic, retain) NSString *pathString;
- (NSString*) completePath;
@end

@interface DicomDatabase : NSObject
@property(readonly) NSManagedObjectModel *managedObjectModel;
@property(readonly) NSManagedObjectContext *managedObjectContext;
- (NSArray*) addFilesAtPaths:(NSArray*) paths postNotifications:(BOOL) a dicomOnly:(BOOL) b rereadExistingItems:(BOOL) c generatedByOsiriX:(BOOL) d importedFiles:(BOOL) e returnArray:(BOOL) f;
- (NSArray*) objectsWithIDs:(NSArray*) ids;
@end

@interface BrowserController : NSObject
+ (BrowserController*) currentBrowser;
@property(readonly) DicomDatabase *database;
- (NSArray*) childrenArray: (id) item;
- (void) proceedDeleteObjects: (NSArray*) objectsToDelete;
@end

@interface ViewerController : NSWindowController
- (void) checkEverythingLoaded;
- (DicomImage *) currentImage;
- (BOOL) sortSeriesByDICOMGroup: (int) gr element: (int) el;
@end

@interface DCMView : NSView
- (BOOL) is2DViewer;
- (id) windowController;
@end

@interface DCMPix : NSObject
+ (void) purgeCachedDictionaries;
@end

@interface AppController : NSObject
+ (void) resizeWindowWithAnimation:(NSWindow*) window newSize: (NSRect) newWindowFrame;
@end

@interface PluginManager : NSObject
+ (NSMutableDictionary*) plugins;
@end

@interface PluginFilter : NSObject
- (NSArray*) toolbarAllowedIdentifiersForViewer:(id) controller;
- (NSToolbarItem*) toolbarItemForItemIdentifier:(NSString*) identifier forViewer:(id) controller;
@end

@interface DicomFile : NSObject
+ (BOOL) isDICOMFile:(NSString *) file;
+ (BOOL) isFVTiffFile:(NSString *) file;
+ (BOOL) isNIfTIFile:(NSString *) file;
+ (NSXMLDocument *) getNIfTIXML : (NSString *) file;
+ (NSArray*) getEncodingArrayForFile: (NSString*) file;
@end

@interface NSString (DICOMToNSString)
+ (NSStringEncoding) encodingForDICOMCharacterSet:(NSString *) characterSet;
@end

@interface WaitRendering : NSWindowController
- (id) init:(NSString*) s;
@end

extern NSString* const OsirixCloseViewerNotification;
extern NSString* const OsirixDCMViewIndexChangedNotification;

#ifndef N2LogExceptionWithStackTrace
#ifdef __cplusplus
extern "C"
#endif
void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf);
#define N2LogException(e, ...) _N2LogExceptionImpl(e, NO, __PRETTY_FUNCTION__)
#define N2LogExceptionWithStackTrace(e, ...) _N2LogExceptionImpl(e, YES, __PRETTY_FUNCTION__)
#endif
'''

STUBS_M = r'''
#import "stubs.h"
#import "HorosAlertPanel.h"
#include <stdarg.h>

NSString* const OsirixCloseViewerNotification = @"OsirixCloseViewerNotification";
NSString* const OsirixDCMViewIndexChangedNotification = @"OsirixDCMViewIndexChangedNotification";

void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf) { NSLog(@"%s: %@", pf, e); }
NSXMLDocument* XML_from_FVTiff(NSString* srcFile) { return nil; }

@implementation OSIWindowController
- (void) setMagnetic:(BOOL) a {}
@end

@implementation DicomStudy
@dynamic name, studyName, patientID;
@end
@implementation DicomSeries
@dynamic study;
@end
@implementation DicomImage
@dynamic series, pathString;
- (NSString*) completePath { return self.pathString; }
@end

static NSManagedObjectContext *harnessContext;
static NSManagedObjectModel *harnessModel;

@implementation DicomDatabase
- (NSManagedObjectModel *) managedObjectModel { return harnessModel; }
- (NSManagedObjectContext *) managedObjectContext { return harnessContext; }
// The file is reread into the same image, as the database does for a file it has.
- (NSArray*) addFilesAtPaths:(NSArray*) paths postNotifications:(BOOL) a dicomOnly:(BOOL) b rereadExistingItems:(BOOL) c generatedByOsiriX:(BOOL) d importedFiles:(BOOL) e returnArray:(BOOL) f
{
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName: @"Image"];
    return [[harnessContext executeFetchRequest: request error: NULL] valueForKey: @"objectID"];
}
- (NSArray*) objectsWithIDs:(NSArray*) ids
{
    NSMutableArray *objects = [NSMutableArray array];
    for (NSManagedObjectID *i in ids) [objects addObject: [harnessContext objectWithID: i]];
    return objects;
}
@end

@implementation BrowserController
+ (BrowserController*) currentBrowser { static BrowserController *b; if (!b) b = [[BrowserController alloc] init]; return b; }
- (DicomDatabase *) database { static DicomDatabase *d; if (!d) d = [[DicomDatabase alloc] init]; return d; }
- (NSArray*) childrenArray: (id) item { return @[]; }
- (void) proceedDeleteObjects: (NSArray*) objectsToDelete { printf("unexpected: the edit deleted database objects\n"); exit(1); }
@end

@implementation ViewerController
- (void) checkEverythingLoaded {}
- (DicomImage *) currentImage { return nil; }
- (BOOL) sortSeriesByDICOMGroup: (int) gr element: (int) el { return NO; }
@end

@implementation DCMView
- (BOOL) is2DViewer { return NO; }
- (id) windowController { return nil; }
@end

@implementation DCMPix
+ (void) purgeCachedDictionaries {}
@end

@implementation AppController
+ (void) resizeWindowWithAnimation:(NSWindow*) window newSize: (NSRect) newWindowFrame {}
@end

@implementation PluginManager
+ (NSMutableDictionary*) plugins { return [NSMutableDictionary dictionary]; }
@end

@implementation PluginFilter
- (NSArray*) toolbarAllowedIdentifiersForViewer:(id) controller { return nil; }
- (NSToolbarItem*) toolbarItemForItemIdentifier:(NSString*) identifier forViewer:(id) controller { return nil; }
@end

@implementation DicomFile
+ (BOOL) isDICOMFile:(NSString *) file { return [[file pathExtension] isEqualToString: @"dcm"]; }
+ (BOOL) isFVTiffFile:(NSString *) file { return NO; }
+ (BOOL) isNIfTIFile:(NSString *) file { return NO; }
+ (NSXMLDocument *) getNIfTIXML : (NSString *) file { return nil; }
@end

@implementation NSString (DICOMToNSString)
+ (NSStringEncoding) encodingForDICOMCharacterSet:(NSString *) characterSet
{
    if ([characterSet isEqualToString: @"ISO_IR 100"]) return NSISOLatin1StringEncoding;
    if ([characterSet isEqualToString: @"ISO_IR 192"]) return NSUTF8StringEncoding;
    return NSASCIIStringEncoding;
}
@end

@implementation WaitRendering
- (id) init:(NSString*) s { return [super initWithWindow: nil]; }
@end

// The alerts answer their default button; the question is printed.
static NSInteger Answer(NSString *title, NSString *message)
{
    printf("alert: %s: %s\n", title.UTF8String, message.UTF8String);
    return NSAlertDefaultReturn;
}

@implementation HorosAlertPanel
+ (NSInteger)runWithTitle:(NSString *)title message:(NSString *)message defaultButton:(NSString *)defaultButton alternateButton:(NSString *)alternateButton otherButton:(NSString *)otherButton { return Answer(title, message); }
+ (NSInteger)runInformationalWithTitle:(NSString *)title message:(NSString *)message defaultButton:(NSString *)defaultButton alternateButton:(NSString *)alternateButton otherButton:(NSString *)otherButton { return Answer(title, message); }
+ (NSInteger)runCriticalWithTitle:(NSString *)title message:(NSString *)message defaultButton:(NSString *)defaultButton alternateButton:(NSString *)alternateButton otherButton:(NSString *)otherButton { return Answer(title, message); }
@end

// The former code called AppKit's panels; its build renames them to these.
NSInteger HarnessRunAlertPanel(NSString *title, NSString *msgFormat, NSString *defaultButton, NSString *alternateButton, NSString *otherButton, ...)
{
    va_list args; va_start(args, otherButton);
    NSString *message = [[[NSString alloc] initWithFormat: msgFormat arguments: args] autorelease];
    va_end(args);
    return Answer(title, message);
}
NSInteger HarnessRunInformationalAlertPanel(NSString *title, NSString *msgFormat, NSString *defaultButton, NSString *alternateButton, NSString *otherButton, ...)
{
    va_list args; va_start(args, otherButton);
    NSString *message = [[[NSString alloc] initWithFormat: msgFormat arguments: args] autorelease];
    va_end(args);
    return Answer(title, message);
}
NSInteger HarnessRunCriticalAlertPanel(NSString *title, NSString *msgFormat, NSString *defaultButton, NSString *alternateButton, NSString *otherButton, ...)
{
    va_list args; va_start(args, otherButton);
    NSString *message = [[[NSString alloc] initWithFormat: msgFormat arguments: args] autorelease];
    va_end(args);
    return Answer(title, message);
}

// The model of the three entities the window reads.
void HarnessMakeDatabase(void)
{
    NSEntityDescription *study = [[[NSEntityDescription alloc] init] autorelease];
    study.name = @"Study"; study.managedObjectClassName = @"DicomStudy";
    NSEntityDescription *series = [[[NSEntityDescription alloc] init] autorelease];
    series.name = @"Series"; series.managedObjectClassName = @"DicomSeries";
    NSEntityDescription *image = [[[NSEntityDescription alloc] init] autorelease];
    image.name = @"Image"; image.managedObjectClassName = @"DicomImage";
    NSMutableArray *studyProperties = [NSMutableArray array];
    for (NSString *name in @[@"name", @"studyName", @"patientID"]) {
        NSAttributeDescription *a = [[[NSAttributeDescription alloc] init] autorelease];
        a.name = name; a.attributeType = NSStringAttributeType; a.optional = YES;
        [studyProperties addObject: a];
    }
    NSAttributeDescription *path = [[[NSAttributeDescription alloc] init] autorelease];
    path.name = @"pathString"; path.attributeType = NSStringAttributeType; path.optional = YES;
    NSRelationshipDescription *seriesStudy = [[[NSRelationshipDescription alloc] init] autorelease];
    seriesStudy.name = @"study"; seriesStudy.destinationEntity = study; seriesStudy.maxCount = 1; seriesStudy.optional = YES;
    NSRelationshipDescription *imageSeries = [[[NSRelationshipDescription alloc] init] autorelease];
    imageSeries.name = @"series"; imageSeries.destinationEntity = series; imageSeries.maxCount = 1; imageSeries.optional = YES;
    study.properties = studyProperties;
    series.properties = @[seriesStudy];
    image.properties = @[path, imageSeries];
    harnessModel = [[NSManagedObjectModel alloc] init];
    harnessModel.entities = @[study, series, image];
    NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel: harnessModel];
    [coordinator addPersistentStoreWithType: NSInMemoryStoreType configuration: nil URL: nil options: nil error: NULL];
    harnessContext = [[NSManagedObjectContext alloc] initWithConcurrencyType: NSMainQueueConcurrencyType];
    harnessContext.persistentStoreCoordinator = coordinator;
}

DicomImage *HarnessMakeImage(NSString *path)
{
    DicomStudy *study = [NSEntityDescription insertNewObjectForEntityForName: @"Study" inManagedObjectContext: harnessContext];
    study.name = @"HARNESS^828"; study.studyName = @"XML editor"; study.patientID = @"PID-828";
    DicomSeries *series = [NSEntityDescription insertNewObjectForEntityForName: @"Series" inManagedObjectContext: harnessContext];
    series.study = study;
    DicomImage *image = [NSEntityDescription insertNewObjectForEntityForName: @"Image" inManagedObjectContext: harnessContext];
    image.series = series; image.pathString = path;
    [harnessContext save: NULL];
    return image;
}
'''

# Only the members XMLController.swift sends; its toolbar is not what is tested.
TOOLBAR_SWIFT = r'''
import AppKit

@objc(HorosToolbarPolicy)
public final class ToolbarPolicy: NSObject {
    @objc public static let spaceItemIdentifier = "HorosToolbarSpaceItem"
    @objc(prepareItem:) public static func prepare(_ item: NSToolbarItem?) {}
    @objc(spaceItemForIdentifier:) public static func spaceItem(for identifier: String) -> NSToolbarItem? { return nil }
    @objc(adoptToolbar:inWindow:) public static func adopt(toolbar: NSToolbar?, in window: NSWindow?) {}
}
'''

FVTIFF_H = '''#import <Foundation/Foundation.h>
NSXMLDocument* XML_from_FVTiff(NSString* srcFile);
'''

# The headers the former XMLController.m, the category and the +CAPI.m import
# by name, which are the stand-ins above here.
STUB_NAMES = ['WaitRendering.h', 'DicomFile.h', 'DicomFileDCMTKCategory.h', 'BrowserController.h',
              'ViewerController.h', 'AppController.h', 'DCMPix.h', 'MutableArrayCategory.h', 'Notifications.h',
              'DICOMToNSString.h', 'N2Debug.h', 'DicomStudy.h', 'DicomSeries.h', 'DicomImage.h',
              'DicomDatabase.h', 'PluginManager.h', 'OSIWindowController.h']

DRIVER = r'''
#import "stubs.h"
#import "XMLController.h"
#import "XMLControllerDCMTKCategory.h"
#import "HorosDCMTKObject.h"
#import "HorosDICOMWriter.h"
#import <DCM/DCM.h>
#import <DCM/DCMAbstractSyntaxUID.h>
#undef verify
#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dcfilefo.h>
#include <dcmtk/dcmdata/dcdeftag.h>

// -[DicomFile getEncodingArrayForFile:] of DicomFileDCMTKCategory.mm, whose
// fallback, for a file that states no character set, is Latin-1 here.
@implementation DicomFile (HarnessEncoding)
+ (NSArray*) getEncodingArrayForFile: (NSString*) file
{
    DcmFileFormat fileformat;
    NSArray *encodingArray = nil;
    fileformat.loadFile( [file UTF8String], EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect);
    DcmDataset *dataset = fileformat.getDataset();
    const char *string = NULL;
    if( dataset && dataset->findAndGetString(DCM_SpecificCharacterSet, string, OFFalse).good() && string != NULL)
        encodingArray = [[NSString stringWithCString:string encoding: NSISOLatin1StringEncoding] componentsSeparatedByString:@"\\"];
    if( encodingArray == nil)
        encodingArray = [NSArray arrayWithObject: @"ISO_IR 100"];
    return encodingArray;
}
@end

extern "C" void HorosTestRegisterDecoders(void);
extern "C" void HarnessMakeDatabase(void);
extern "C" DicomImage *HarnessMakeImage(NSString *path);

static void fail(const char *what) { printf("FAIL: %s\n", what); fflush(stdout); exit(1); }

// The synthetic file: a name, a multi-valued element, a description, a sequence
// with one item, a private creator and element, in Latin-1.
static void MakeFixture(NSString *path)
{
    NSString *source = [path stringByAppendingString: @".source"];
    HorosDICOMWriter *writer = [[[HorosDICOMWriter alloc] init] autorelease];
    [writer setValues: @[[DCMAbstractSyntaxUID secondaryCaptureImageStorage]] forName: @"SOPClassUID"];
    [writer setValues: @[@"1.2.826.0.1.3680043.2.1125.828.1"] forName: @"SOPInstanceUID"];
    [writer setValues: @[@"1.2.826.0.1.3680043.2.1125.828.2"] forName: @"StudyInstanceUID"];
    [writer setValues: @[@"1.2.826.0.1.3680043.2.1125.828.3"] forName: @"SeriesInstanceUID"];
    [writer setValues: @[@"ISO_IR 100"] forName: @"SpecificCharacterSet"];
    [writer setValues: @[@"HARNESS^828"] forName: @"PatientsName"];
    [writer setValues: @[@"PID-828"] forName: @"PatientID"];
    [writer setValues: @[@"Study to delete"] forName: @"StudyDescription"];
    [writer setValues: @[@"ORIGINAL", @"PRIMARY", @"AXIAL"] forName: @"ImageType"];
    [writer setValues: @[@"", @"B", @"C"] forName: @"OtherPatientIDs"];
    [writer setValues: @[@"OT"] forName: @"Modality"];
    [writer setValues: @[@4] forName: @"Rows"];
    [writer setValues: @[@4] forName: @"Columns"];
    [writer setValues: @[@1] forName: @"SamplesperPixel"];
    [writer setValues: @[@"MONOCHROME2"] forName: @"PhotometricInterpretation"];
    [writer setValues: @[@16] forName: @"BitsAllocated"];
    [writer setValues: @[@16] forName: @"BitsStored"];
    [writer setValues: @[@15] forName: @"HighBit"];
    [writer setValues: @[@0] forName: @"PixelRepresentation"];
    [writer setData: [NSMutableData dataWithLength: 32] forName: @"PixelData" vr: @"OW"];
    if (![writer writeToFile: source transferSyntax: @"1.2.840.10008.1.2.1"]) fail("the source was not written");

    DCMObject *object = [DCMObject objectWithContentsOfFile: source decodingPixelData: NO];
    DCMSequenceAttribute *references = [DCMSequenceAttribute sequenceAttributeWithName: @"ReferencedImageSequence"];
    DCMObject *item = [DCMObject dcmObject];
    [item setAttributeValues: [NSMutableArray arrayWithObject: @"1.2.840.10008.5.1.4.1.1.7"] forName: @"ReferencedSOPClassUID"];
    [item setAttributeValues: [NSMutableArray arrayWithObject: @"1.2.826.0.1.3680043.2.1125.828.9"] forName: @"ReferencedSOPInstanceUID"];
    [references addItem: item];
    [object setAttribute: references];
    [object setAttributeValues: [NSMutableArray arrayWithObject: @"ISO_IR 100"] forName: @"SpecificCharacterSet"];
    [object setAttribute: [DCMAttribute attributeWithAttributeTag: [DCMAttributeTag tagWithGroup: 0x0009 element: 0x0010] vr: @"LO" values: [NSMutableArray arrayWithObject: @"HOROS 828"]]];
    DCMAttributeTag *privateTag = [DCMAttributeTag tagWithGroup: 0x0009 element: 0x1001];
    privateTag.vr = @"LO";
    [object setAttribute: [DCMAttribute attributeWithAttributeTag: privateTag vr: @"LO" values: [NSMutableArray arrayWithObject: @"private value"]]];
    if (![object writeToFile: path withTransferSyntax: [DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax] quality: DCMLosslessQuality AET: @"HARNESS828" atomically: YES])
        fail("the fixture was not written");
}

static NSXMLElement *Row(NSOutlineView *table, NSString *path, id controller)
{
    for (NSInteger i = 0; i < table.numberOfRows; i++) {
        id item = [table itemAtRow: i];
        if ([[controller getPath: item] isEqualToString: path]) return item;
    }
    printf("FAIL: no row %s\n", path.UTF8String);
    exit(1);
}

static void Spin(void) { [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 0.05]]; }

// As the outline sends an edited cell. The edit is recorded on the next turn of
// the run loop, which a loaded machine can take longer than one Spin to reach:
// the row shows the new value once it is.
static void Edit(id controller, NSOutlineView *table, NSString *path, NSString *value)
{
    NSTableColumn *column = [table tableColumnWithIdentifier: @"stringValue"];
    NSXMLElement *row = Row(table, path, controller);
    [controller outlineView: table setObjectValue: value forTableColumn: column byItem: row];
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow: 10];
    do Spin();
    while (![[controller outlineView: table objectValueForTableColumn: column byItem: row] isEqual: value] && limit.timeIntervalSinceNow > 0);
    printf("edited %s\n", path.UTF8String);
}

// As the Delete key does on the selected row.
static void Delete(id controller, NSOutlineView *table, NSString *path)
{
    NSInteger row = [table rowForItem: Row(table, path, controller)];
    [table selectRowIndexes: [NSIndexSet indexSetWithIndex: row] byExtendingSelection: NO];
    NSEvent *event = [NSEvent keyEventWithType: NSEventTypeKeyDown location: NSZeroPoint modifierFlags: 0 timestamp: 0
                                  windowNumber: 0 context: nil characters: @"\x7f" charactersIgnoringModifiers: @"\x7f"
                                     isARepeat: NO keyCode: 51];
    [controller keyDown: event];
    printf("deleted %s\n", path.UTF8String);
}

int main(int argc, char **argv) { @autoreleasepool {
    [NSApplication sharedApplication];
    HorosTestRegisterDecoders();
    HarnessMakeDatabase();
    NSString *fixture = @(argv[1]), *work = @(argv[2]);
    if (argc > 3 && strcmp(argv[3], "make") == 0) { MakeFixture(fixture); printf("fixture written\n"); return 0; }
    BOOL values = argc > 3 && strcmp(argv[3], "values") == 0;
    BOOL empty = argc > 3 && strcmp(argv[3], "empty") == 0;
    if (argc > 3 && strcmp(argv[3], "dump") == 0) {
        // What a reader finds in the written file.
        DCMObject *o = [DCMObject objectWithContentsOfFile: work decodingPixelData: NO];
        NSArray *items = [(DCMSequenceAttribute *) [o attributeWithName: @"ReferencedImageSequence"] sequence];
        printf("PatientsName=%s\n", [[o attributeValueWithName: @"PatientsName"] description].UTF8String);
        printf("ImageType=%s\n", [[[o attributeWithName: @"ImageType"] values] componentsJoinedByString: @"\\"].UTF8String);
        printf("OtherPatientIDs=%s\n", [[[o attributeWithName: @"OtherPatientIDs"] values] componentsJoinedByString: @"\\"].UTF8String);
        printf("ReferencedSOPInstanceUID=%s\n", [[items.firstObject attributeValueWithName: @"ReferencedSOPInstanceUID"] description].UTF8String);
        printf("StudyDescription=%s\n", [[o attributeValueWithName: @"StudyDescription"] description].UTF8String);
        printf("SeriesDescription=%s\n", [[o attributeValueWithName: @"SeriesDescription"] description].UTF8String);
        printf("Private=%s\n", [[[o attributeForTag: [DCMAttributeTag tagWithGroup: 0x0009 element: 0x1001]] value] description].UTF8String);
        return 0;
    }
    [[NSUserDefaults standardUserDefaults] setVolatileDomain: @{@"ALLOWDICOMEDITING": @YES, @"DICOM Editing Warning": @YES, @"editingLevel": @0}
                                                     forName: NSArgumentDomain];

    DicomImage *image = HarnessMakeImage(work);
    id controller = [[XMLController alloc] initWithImage: image windowName: @"harness" viewer: nil];
    NSOutlineView *table = [controller valueForKey: @"table"];
    if (table == nil) fail("XMLViewer.nib did not connect the outline");
    [controller switchEditing: nil];
    if (![[controller valueForKey: @"editingActivated"] boolValue]) fail("editing is not active");
    [controller deepExpandAllItems: nil];

    if (empty) {
        // The element's row lists its values, the empty first one included.
        printf("shown=%s\n", [[controller performSelector: @selector(stringsSeparatedForNode:) withObject: Row(table, @"(0010,1000)", controller)] UTF8String]);
        Edit(controller, table, @"(0010,1000)[2]", @"D");
        Delete(controller, table, @"(0010,1000)[1]");
    } else if (values) {
        // Two values of one element; the rows keep the indexes of the file as read.
        Edit(controller, table, @"(0008,0008)[1]", @"SECONDARY");
        Delete(controller, table, @"(0008,0008)[0]");
    } else {
        Edit(controller, table, @"(0010,0010)", @"Müller^José");
        Edit(controller, table, @"(0008,1140)[0].(0008,1155)", @"1.2.826.0.1.3680043.2.1125.828.10");
        Delete(controller, table, @"(0008,1030)");
        Delete(controller, table, @"(0009,1001)");

        // The Add sheet, as its OK button (tag 1) sends it.
        [[controller valueForKey: @"addGroup"] setStringValue: @"0x0008"];
        [[controller valueForKey: @"addElement"] setStringValue: @"0x103e"];
        [[controller valueForKey: @"addValue"] setStringValue: @"Added by the harness"];
        NSButton *ok = [[[NSButton alloc] init] autorelease];
        ok.tag = 1;
        [controller executeAdd: ok];
        printf("added (0008,103E)\n");
    }

    if (![[controller valueForKey: @"modificationsToApply"] boolValue]) fail("no modification to apply");
    [controller applyModifications: nil];
    if ([[controller valueForKey: @"modificationsToApply"] boolValue]) fail("modifications left after applying");
    printf("applied\n");
    [[controller window] close];
    Spin();
    return 0;
} }
'''


def run(command, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, **kwargs)
    if result.returncode:
        print('FAIL: %s\n%s%s' % (' '.join(map(str, command[:3])), result.stdout[-4000:], result.stderr[-4000:]))
        sys.exit(1)
    return result


with tempfile.TemporaryDirectory(prefix='horos-xml-editor-') as tmp:
    tmp = Path(tmp)
    products = Path(args.products).resolve()
    (tmp / 'Frameworks').symlink_to(products)
    flags = dcmtk_flags('dcmjpeg', 'horosdcmjpls', 'dcmimage', 'dcmimgle', 'ijg8', 'ijg12', 'ijg16')
    includes, archives = flags[:2], flags[2:]
    openjpeg = BUILD / 'OpenJPEG.build/Install'
    gdcm_archives = [str(gdcm / 'lib' / name) for name in (
        'libgdcmMSFF.a', 'libgdcmIOD.a', 'libgdcmDSED.a', 'libgdcmDICT.a', 'libgdcmCommon.a', 'libgdcmMEXD.a',
        'libgdcmjpeg8.a', 'libgdcmjpeg12.a', 'libgdcmjpeg16.a', 'libgdcmcharls.a', 'libgdcmexpat.a',
        'libgdcmuuid.a', 'libgdcmzlib.a', 'libsocketxx.a')]
    host = tmp / 'host'
    host.mkdir()
    (host / 'setup.mm').write_text(horos_reader.SETUP)
    common_cxx = ['xcrun', 'clang++', '-std=c++17', '-fno-objc-arc', '-w', '-g', '-F', str(products),
                  '-I', str(products / 'DCM.framework/Headers'), '-I', str(openjpeg / 'include'),
                  '-I', str(gdcm / 'include'), *includes]
    host_objects = []
    for name, language in (('setup.mm', 'objective-c++'), (SOURCES / 'HorosDCMTKObject.mm', 'objective-c++'),
                           (SOURCES / 'HorosDICOMServices.mm', 'objective-c++'),
                           (SOURCES / 'HorosDICOMWriter.mm', 'objective-c++'),
                           (SOURCES / 'HorosJPEG2000Codec.cpp', 'c++'), (SOURCES / 'mdfconen.cc', 'c++'),
                           (SOURCES / 'mdfdsman.cc', 'c++')):
        path = host / name if isinstance(name, str) else name
        obj = host / (Path(path).stem + '.o')
        run([*common_cxx, *(['-fmodules', '-fcxx-modules'] if language == 'objective-c++' else []),
             '-x', language, '-c', str(path), '-o', str(obj)])
        host_objects.append(str(obj))
    dictionaries = host / 'dictionaries.o'
    run(['xcrun', 'clang++', '-std=c++17', '-fobjc-arc', '-w', *includes, '-c',
         str(SOURCES / 'DICOMDataDictionary.mm'), '-o', str(dictionaries)])
    host_objects.append(str(dictionaries))
    exception = host / 'exception.o'
    run(['xcrun', 'clang', '-fobjc-arc', '-c', str(SOURCES / 'HorosObjCException.m'), '-I', str(SOURCES),
         '-o', str(exception)])
    host_objects.append(str(exception))

    # The Swift classes both builds use: the tag path the writer parses, and
    # the helpers of XMLController.
    helpers = [SOURCES / 'DICOMTagPath.swift', SOURCES / 'HorosArchitectureAudit.swift',
               SOURCES / 'MutableArrayCategory.swift']

    nib = tmp / 'XMLViewer.nib'
    run(['xcrun', 'ibtool', '--compile', str(nib), str(ROOT / 'Horos/Resources/en.lproj/XMLViewer.xib')])

    def build(side):
        work = tmp / side
        work.mkdir()
        (work / 'stubs.h').write_text(STUBS_H)
        (work / 'stubs.m').write_text(STUBS_M)
        (work / 'FVTiff.h').write_text(FVTIFF_H)
        (work / 'ToolbarPolicy.swift').write_text(TOOLBAR_SWIFT)
        (work / 'main.mm').write_text(DRIVER)
        for name in STUB_NAMES:
            (work / name).write_text('#import "stubs.h"\n')
        category = 'Horos/Sources/XMLControllerDCMTKCategory.mm'
        if side == 'former':
            (work / 'XMLController.h').write_bytes(former('Horos/Sources/XMLController.h'))
            (work / 'XMLController.m').write_bytes(former('Horos/Sources/XMLController.m'))
            (work / 'XMLControllerDCMTKCategory.mm').write_bytes(former(category))
            (work / 'XMLControllerDCMTKCategory.h').write_bytes(former('Horos/Sources/XMLControllerDCMTKCategory.h'))
            swift = [*helpers, work / 'ToolbarPolicy.swift']
            (work / 'bridge.h').write_text('#define HOROS_BRIDGING_HEADER 1\n#import <Foundation/Foundation.h>\n')
        else:
            for name in ('XMLController.h', 'XMLController+CAPI.m', 'XMLControllerDCMTKCategory.mm',
                         'XMLControllerDCMTKCategory.h'):
                shutil.copy(SOURCES / name, work / name)
            swift = [SOURCES / 'XMLController.swift', *helpers, work / 'ToolbarPolicy.swift']
            (work / 'bridge.h').write_text('#define HOROS_BRIDGING_HEADER 1\n#import "stubs.h"\n'
                                           '#import "HorosObjCException.h"\n#import "HorosBoundedTask.h"\n'
                                           '#import "HorosAlertPanel.h"\n#import "DCMObject.h"\n'
                                           '#import "DCMAttribute.h"\n#import "DCMAttributeTag.h"\n'
                                           '#import "XMLController.h"\n')
        search = ['-I', str(work), '-I', str(products / 'DCM.framework/Headers'), '-I', str(SOURCES)]
        objects = [*host_objects]
        run(['xcrun', 'swiftc', '-parse-as-library', '-wmo', '-module-name', 'Horos', '-Onone', '-g',
             '-import-objc-header', str(work / 'bridge.h'), *[x for s in search for x in ('-Xcc', s)],
             '-Xcc', '-F' + str(products),
             '-emit-objc-header', '-emit-objc-header-path', str(work / 'Horos-Swift.h'),
             '-c', *map(str, swift), '-o', str(work / 'swift.o')])
        objects.append(str(work / 'swift.o'))
        panels = ['-DNSRunAlertPanel=HarnessRunAlertPanel', '-DNSRunInformationalAlertPanel=HarnessRunInformationalAlertPanel',
                  '-DNSRunCriticalAlertPanel=HarnessRunCriticalAlertPanel']
        objc = ['xcrun', 'clang', '-fno-objc-arc', '-w', '-g', '-F', str(products), *search]
        units = [('stubs.m', 'objective-c', []), ('main.mm', 'objective-c++', ['-std=c++17', *includes]),
                 ('XMLControllerDCMTKCategory.mm', 'objective-c++', ['-std=c++17', '-I', str(gdcm / 'include'), *includes])]
        units.append(('XMLController.m', 'objective-c', panels) if side == 'former' else ('XMLController+CAPI.m', 'objective-c', []))
        for name, language, extra in units:
            obj = work / (Path(name).stem + '.o')
            run([*objc, *extra, '-x', language, '-c', str(work / name), '-o', str(obj)])
            objects.append(str(obj))
        binary = tmp / 'bin' / ('horos-xml-editor-harness-' + side)
        binary.parent.mkdir(exist_ok=True)
        run(['xcrun', 'swiftc', '-o', str(binary), *objects, '-F', str(products), '-framework', 'DCM',
             '-framework', 'Cocoa', '-framework', 'CoreData', str(openjpeg / 'lib/libopenjp2.a'), *archives,
             *gdcm_archives, '-lc++', '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks'])
        if nib.is_dir():
            shutil.copytree(nib, binary.parent / 'XMLViewer.nib', dirs_exist_ok=True)
        else:
            shutil.copy(nib, binary.parent / 'XMLViewer.nib')
        return binary

    binaries = {side: build(side) for side in ('former', 'swift')}
    dictionary = BUILD.parent.parent.parent / 'Products' / BUILD.name / 'DCMTK/dicom.dic'
    if dictionary.is_file():
        shutil.copy(dictionary, tmp / 'bin' / 'dicom.dic')
    fixture = tmp / 'fixture.dcm'
    run([str(binaries['swift']), str(fixture), '', 'make'])
    original = fixture.read_bytes()

    def dump(path):
        return dict(line.split('=', 1) for line in run([str(binaries['swift']), str(fixture), str(path), 'dump'],
                                                       cwd=str(tmp / 'bin')).stdout.splitlines() if '=' in line)

    written = {}
    runs = (('former', 'former', []), ('former again', 'former', []), ('swift', 'swift', []),
            ('former values', 'former', ['values']), ('swift values', 'swift', ['values']),
            ('swift empty', 'swift', ['empty']))
    shown = None
    for label, side, mode in runs:
        copy = tmp / ('%s.dcm' % label.replace(' ', '-'))
        shutil.copy(fixture, copy)
        result = run([str(binaries[side]), str(fixture), str(copy), *mode], cwd=str(tmp / 'bin'))
        print('%s: %s' % (label, ', '.join(line for line in result.stdout.splitlines() if not line.startswith('alert'))))
        if label == 'swift empty':
            shown = next((line.split('=', 1)[1] for line in result.stdout.splitlines() if line.startswith('shown=')), None)
        written[label] = copy.read_bytes()
    for side in binaries:
        subprocess.run(['defaults', 'delete', 'horos-xml-editor-harness-' + side], capture_output=True)
    read_back = dump(tmp / 'swift.dcm')
    print('written: %s' % ', '.join('%s=%s' % item for item in read_back.items()))
    values_read_back = dump(tmp / 'swift-values.dcm')
    print('values written: %s' % ', '.join('%s=%s' % item for item in values_read_back.items()))
    print('the former code wrote ImageType=%s for the same two value edits' % dump(tmp / 'former-values.dcm').get('ImageType'))
    empty_read_back = dump(tmp / 'swift-empty.dcm')
    print('empty first value written: %s' % ', '.join('%s=%s' % item for item in empty_read_back.items()))

    if args.keep:
        Path(args.keep).mkdir(parents=True, exist_ok=True)
        for name in ('fixture.dcm', 'former.dcm', 'former-again.dcm', 'swift.dcm', 'former-values.dcm', 'swift-values.dcm',
                     'swift-empty.dcm'):
            shutil.copy(tmp / name, Path(args.keep) / name)
    failures = []
    if written['former'] == original:
        failures.append('the former code did not change the file')
    if written['former'] != written['former again']:
        failures.append('the former code writes different bytes on two runs: the comparison cannot hold')
    # Each edit reached the file, and the untouched multi-valued element kept its values.
    if dump(fixture).get('OtherPatientIDs') != '\\B\\C':
        failures.append('the fixture has OtherPatientIDs=%r, not \\B\\C: the empty first value cannot be tested'
                        % dump(fixture).get('OtherPatientIDs'))
    expected = {'PatientsName': 'M\u00fcller^Jos\u00e9', 'ImageType': 'ORIGINAL\\PRIMARY\\AXIAL',
                'OtherPatientIDs': '\\B\\C',
                'ReferencedSOPInstanceUID': '1.2.826.0.1.3680043.2.1125.828.10',
                'StudyDescription': '(null)', 'SeriesDescription': 'Added by the harness', 'Private': '(null)'}
    for key, value in expected.items():
        if read_back.get(key) != value:
            failures.append('%s reads %r after the edit, expected %r' % (key, read_back.get(key), value))
    # Value [1] replaced and value [0] deleted: the element is written whole,
    # with the value that was neither, and nothing else changed (#856).
    expected_values = {'PatientsName': 'HARNESS^828', 'ImageType': 'SECONDARY\\AXIAL', 'OtherPatientIDs': '\\B\\C',
                       'ReferencedSOPInstanceUID': '1.2.826.0.1.3680043.2.1125.828.9',
                       'StudyDescription': 'Study to delete', 'SeriesDescription': '(null)', 'Private': 'private value'}
    for key, value in expected_values.items():
        if values_read_back.get(key) != value:
            failures.append('%s reads %r after editing ImageType[1] and deleting ImageType[0], expected %r'
                            % (key, values_read_back.get(key), value))
    # An empty first value is shown and kept: value [2] replaced and value [1]
    # deleted leave the empty one and D (#873).
    if shown != '\\B\\C':
        failures.append('the row of OtherPatientIDs shows %r, expected %r: the empty first value is lost' % (shown, '\\B\\C'))
    expected_empty = {'PatientsName': 'HARNESS^828', 'ImageType': 'ORIGINAL\\PRIMARY\\AXIAL', 'OtherPatientIDs': '\\D',
                      'StudyDescription': 'Study to delete', 'Private': 'private value'}
    for key, value in expected_empty.items():
        if empty_read_back.get(key) != value:
            failures.append('%s reads %r after editing OtherPatientIDs[2] and deleting OtherPatientIDs[1], expected %r'
                            % (key, empty_read_back.get(key), value))
    if written['swift'] != written['former']:
        failures.append('the Swift XMLController writes %d bytes, the former one %d, and they differ'
                        % (len(written['swift']), len(written['former'])))
    for failure in failures:
        print('FAIL:', failure)
    if failures:
        sys.exit(1)
    print('PASS: the Swift XMLController writes the same %d bytes as the former one, for five edits of a synthetic file,'
          ' and writes a multi-valued element whole when one of its values is edited or deleted,'
          ' an empty first value included' % len(written['swift']))
