#!/usr/bin/env python3
"""Execute #680 controller methods with in-memory viewer/database dependencies.

The registration, aliasing, undo/redo, reslice snapshot, load, and save/merge
implementations are extracted verbatim from ViewerController.m and compiled.
ROI, database, and SR doubles provide storage without loading AppKit, DCMTK, a
private database, or patient data. The SR double writes real NSArchiver bytes
and only indexes their paths when addFilesAtPaths is called, as the host does.
Pixel resampling, DICOM SR encoding, and native event delivery remain app checks.

-deleteROI:, -loadROI:, -saveROI: and +areROIsArraysIdentical:with: are Swift
since #832, in ViewerController+ROI.swift. They are taken from there as they
stand, with the file's own objcTry/objcIsKind/objcROI/objcIntegerValue/objcAdd/
objcSetKeyed/objcIsEqualToString/objcIsEqualToData/objcPost, and compiled with
swiftc as an extension of the Objective-C double of ViewerController, beside
the real HorosObjCException. The rest (the volume-length helpers, undo/redo,
the reslice snapshot, HorosVolumeLengthReadArchive and the
+horos_volumeLengthReadArchive: that hands it to Swift) stays in
ViewerController.m and is compiled with clang as before. The double reaches its
instance variables through accessors spelled as in
ViewerController+SwiftIvars.h, and the doubles of ROI, DicomImage, DicomStudy,
DicomDatabase, SRAnnotation and the restricted unarchiver keep the
declarations Swift reads in the app's headers.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs (#803)
import sources
import harness_defaults  # the harness's preferences stay in its own process (#923)

root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/ViewerController.m').read_text(encoding='latin1')
swift = sources.source_text('ViewerController+ROI')
if shutil.which('xcrun') is None:
    print('needs xcrun and the macOS Foundation framework', file=sys.stderr)
    raise SystemExit(2)


def body(signature):
    """Read a definition, not its declaration, preserving its complete body."""
    match = re.search(re.escape(signature) + r'\s*\n\{', source)
    assert match, f'missing implementation: {signature}'
    start = match.start()
    brace = source.index('{', match.start())
    depth = 0
    # These methods have no braces inside string literals; comments and literal
    # dictionaries are balanced. Keep extraction strict if the source changes.
    for end in range(brace, len(source)):
        depth += (source[end] == '{') - (source[end] == '}')
        if depth == 0:
            return source[start:end + 1]
    raise AssertionError(f'unterminated implementation: {signature}')


def swift_method(selector, following):
    """The Swift method from @objc(selector) up to the next method's @objc(following)."""
    marker = '    @objc(' + selector + ')\n'
    assert marker in swift, f'missing implementation: {marker.strip()}'
    start = swift.index(marker)
    return swift[start:swift.index('    @objc(' + following + ')\n', start)]


def swift_helper(name):
    return re.search(r'(?:@inline\(__always\)\n)?fileprivate func ' + name + r'\b.*?\n}\n', swift, re.S).group(0)


signatures = [
    '- (NSMutableDictionary *)volumeLengthStateForMovieIndex:(long)movieIndex create:(BOOL)create',
    '- (NSArray<HorosVolumeLengthROI *> *)volumeLengthROIsForMovieIndex:(long)movieIndex',
    '- (void)registerVolumeLengthROI:(HorosVolumeLengthROI *)roi movieIndex:(long)movieIndex anchor:(DicomImage *)anchor',
    '- (void)attachVolumeLengthROI:(HorosVolumeLengthROI *)roi movieIndex:(long)movieIndex',
    '- (void)addVolumeLengthROI:(HorosVolumeLengthROI *)roi',
    '- (void)addVolumeLengthROI:(HorosVolumeLengthROI *)roi movieIndex:(long)movieIndex',
    '- (void)restoreVolumeLengthSnapshot:(NSDictionary *)snapshot movieIndex:(long)movieIndex',
    '- (void)saveVolumeLengthROIs:(long)movieIndex writtenPaths:(NSMutableArray *)paths anchorPaths:(NSDictionary *)anchorPaths',
    '- (id) prepareObjectForUndo:(NSString*) string',
    '- (void) executeUndo:(NSMutableArray*) u',
    '- (IBAction) undo:(id) sender',
    '- (IBAction) redo:(id) sender',
    '+ (NSArray *)horos_volumeLengthReadArchive:(NSString *)path',
]
methods = '\n\n'.join(body(signature) for signature in signatures)
# The Swift methods (each up to the @objc( line of the method after it).
swift_methods = [
    ('deleteROI:', 'deleteSeriesROIwithName:'),
    ('loadROI:', 'areROIsArraysIdentical:with:'),
    ('saveROI:', 'containsROI:'),
    ('areROIsArraysIdentical:with:', 'flipROIHorizontally:'),
]
extension = ('import Foundation\n\n'
             '// NSManagedObject is the double of the Objective-C side (see Harness.h).\n'
             'typealias NSManagedObject = ProbeManagedObject\n\n'
             + ''.join(swift_helper(name) + '\n' for name in (
                 'objcTry', 'objcIsEqualToString', 'objcAdd', 'objcSetKeyed', 'objcROI', 'objcIsKind',
                 'objcIntegerValue', 'objcIsEqualToData', 'objcPost'))
             + 'extension ViewerController {\n' + ''.join(swift_method(*pair) for pair in swift_methods) + '}\n')
# Here, where the ROIs are doubles, the restricted unarchiver is the NSUnarchiver
# it wraps, answering nil where it refuses, with the Swift signatures of
# RestrictedUnarchiver.swift.
DOUBLES = r'''
import Foundation

@objc(HorosRestrictedUnarchiver)
final class RestrictedUnarchiver: NSObject {
    @objc(unarchiveROIsWithData:)
    static func unarchiveROIs(with data: Data?) -> NSArray? {
        guard let data, data.count != 0 else { return nil }
        var rois: Any?
        do { try HorosObjCException.perform { rois = NSUnarchiver.unarchiveObject(with: data) } } catch { return nil }
        return rois as? NSArray
    }

    @objc(unarchiveROIsWithFile:)
    static func unarchiveROIs(withFile path: String?) -> NSArray? {
        return unarchiveROIs(with: path.flatMap { FileManager.default.contents(atPath: $0) })
    }
}
'''
snapshot_start = source.index('        NSMutableArray *volumeSnapshots = [NSMutableArray arrayWithCapacity:mx];')
snapshot_end = source.index('        ViewerController *reslicedViewer = self;', snapshot_start)
snapshot = source[snapshot_start:snapshot_end]
archive_reader = body('static NSArray *HorosVolumeLengthReadArchive(NSString *path)')

# The doubles, as Swift and the Objective-C see them. What Swift reads is
# spelled as in ROI.h, DicomImage.swift, DicomStudy.swift, DicomDatabase.h,
# BrowserController.h, SRAnnotation.h, DCMView.h, N2Debug.h, Notifications.h,
# ViewerController.h and ViewerController+SwiftIvars.h.
HEADER = r'''
#pragma clang diagnostic ignored "-Wnullability-completeness"
#import <Foundation/Foundation.h>
#import "HorosObjCException.h"

#define MAX4D 500
extern NSString * const OsirixAddROINotification;
extern NSString * const OsirixRemoveROINotification;
extern NSString * const OsirixROIChangeNotification;
extern void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf);

@interface ProbeContext : NSObject
- (void)lock;
- (void)unlock;
@end

void N2ManagedObjectContextPerformAndWait(ProbeContext *context, void (NS_NOESCAPE ^block)(void));

@class DCMPix;
@interface ROI : NSObject <NSCopying, NSCoding>
@property(copy) NSString *name;
@property BOOL isAliased;
@property int originalIndexForAlias;
@property(assign) id curView;
@property(retain) DCMPix *pix;
@property(readonly) NSData *data;
@end

@interface HorosVolumeLengthROI : ROI
@property(copy) NSDictionary *volumeLength;
@property(readonly) NSString *volumeIdentifier;
@end

@class DicomStudy, DicomSeries, DicomImage;
@interface ProbeManagedObject : NSObject
@property(retain) ProbeContext *managedObjectContext;
@end
@interface DicomImage : ProbeManagedObject
@property(copy) NSString *objectID, *sopInstanceUID;
@property(retain) NSNumber *frameID;
@property(retain) DicomSeries *series;
- (NSString *)SRPath;
@end
@interface DicomSeries : NSObject
@property(retain) DicomStudy *study;
@property(retain) NSString *seriesDICOMUID;
@property(retain) NSSet *images;
@end
// DicomStudy is Swift in the app (DicomStudy.swift): its Swift names are
// spelled here, and the array it takes as NSArray is an id.
@interface DicomStudy : NSObject
@property(retain) NSMutableDictionary *paths;
- (NSString *)roiPathForImage:(DicomImage *)image NS_SWIFT_NAME(roiPath(forImage:));
- (NSString *)roiPathForImage:(DicomImage *)image inArray:(id)images NS_SWIFT_NAME(roiPath(forImage:inArray:));
- (DicomSeries *)roiSRSeries;
@end

@interface DCMPix : NSObject
@property BOOL generated;
@end

@interface DicomDatabase : NSObject
@property(copy) NSString *directory;
@property(retain) ProbeContext *managedObjectContext;
@property NSUInteger nextPath, writes, indexed;
+ (DicomDatabase *)databaseForContext:(ProbeContext *)context;
- (NSString *)uniquePathForNewDataFileWithExtension:(NSString *)extension;
- (void)addFilesAtPaths:(NSArray *)paths postNotifications:(BOOL)a dicomOnly:(BOOL)b rereadExistingItems:(BOOL)c generatedByOsiriX:(BOOL)d;
- (void)lock;
- (void)unlock;
@end
@interface BrowserController : NSObject
+ (BrowserController *)currentBrowser;
@property(retain, nonatomic) DicomDatabase *database;
@end

@interface SRAnnotation : NSObject
@property(retain) NSArray *rois;
@property(retain) DicomImage *image;
+ (NSData *)roiFromDICOM:(NSString *)path;
+ (NSString *)archiveROIsAsDICOM:(NSArray *)rois toPath:(NSString *)path forImage:(id)image;
- (id)initWithROIs:(NSArray *)rois path:(NSString *)path forImage:(DicomImage *)image;
- (void)setSeriesInstanceUID:(NSString *)uid;
- (BOOL)writeToFileAtPath:(NSString *)path;
@end

@interface ProbeView : NSObject
@property NSInteger index, cancellations;
- (NSInteger)curImage;
- (void)cancelLengthPlacement;
- (void)stopROIEditing;
- (void)stopROIEditingForce:(BOOL)force;
- (void)roiSet:(ROI *)roi;
- (void)setNeedsDisplay:(BOOL)needed;
@end

@interface ViewerController : NSObject {
@public
    NSMutableArray *roiList[MAX4D], *fileList[MAX4D], *pixList[MAX4D], *copyRoiList[MAX4D];
    NSInteger maxMovieIndex, curMovieIndex;
    ProbeView *imageView;
    NSMutableArray *undoQueue, *redoQueue;
}
__METHOD_DECLARATIONS__
- (NSArray *)probeSnapshotsForNewViewer:(BOOL)newViewer;
- (nullable NSMutableArray*)horos_fileListAt:(NSInteger)index;
- (nullable NSMutableArray<DCMPix *>*)horos_pixListAt:(NSInteger)index;
- (nullable NSMutableArray<NSMutableArray<ROI *> *>*)horos_roiListAt:(NSInteger)index;
- (nullable NSMutableArray<NSData *>*)horos_copyRoiListAt:(NSInteger)index;
@property(assign) short horos_curMovieIndex;
@property(retain, nullable) ProbeView* horos_imageView;
@end
'''

DECLARATIONS = r'''
#import "Harness.h"
#import <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(condition, message) do { if (!(condition)) { fprintf(stderr, "FAIL: %s (line %d)\n", message, __LINE__); exit(1); } } while(0)
static void N2LogException(NSException *e) { NSLog(@"Probe caught: %@", e.name); }
static void N2LogExceptionWithStackTrace(NSException *e) { N2LogException(e); }
void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf) { N2LogException(e); }
static void NSBeep(void) {}
NSString * const OsirixAddROINotification = @"add";
NSString * const OsirixRemoveROINotification = @"remove";
NSString * const OsirixROIChangeNotification = @"change";
static char HorosVolumeLengthStateKey;
static NSUInteger volumeCopyCount;

// The Swift methods, as the Objective-C of the app sees them.
@interface ViewerController (ROI)
- (void) deleteROI: (ROI*) roi;
- (void) loadROI:(long) mIndex;
- (void) saveROI:(long) mIndex;
+ (BOOL) areROIsArraysIdentical: (NSArray*) copy with: (NSArray*) roisArray;
@end

static NSUInteger contextQueueUnits;
void N2ManagedObjectContextPerformAndWait(ProbeContext *context, void (NS_NOESCAPE ^block)(void)) {
    contextQueueUnits++;
    block();
}

@implementation ProbeContext
- (void)lock {}
- (void)unlock {}
@end

// Dependency doubles, deliberately separate from the extracted controller.
@implementation ROI
- (id)copyWithZone:(NSZone *)zone {
    ROI *copy = [[[self class] allocWithZone:zone] init];
    copy.name = self.name; copy.isAliased = self.isAliased;
    return copy;
}
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.name]; [coder encodeObject:@(self.isAliased)];
}
- (id)initWithCoder:(NSCoder *)coder {
    if ((self = [super init])) { self.name = [coder decodeObject]; self.isAliased = [[coder decodeObject] boolValue]; }
    return self;
}
- (NSData *)data { return [NSArchiver archivedDataWithRootObject:self]; }
- (void)dealloc { [_name release]; [_pix release]; [super dealloc]; }
@end

@implementation HorosVolumeLengthROI
- (NSString *)volumeIdentifier { return self.volumeLength[@"id"]; }
- (id)copyWithZone:(NSZone *)zone {
    volumeCopyCount++;
    HorosVolumeLengthROI *copy = [super copyWithZone:zone]; copy.volumeLength = self.volumeLength;
    return copy;
}
- (void)encodeWithCoder:(NSCoder *)coder { [super encodeWithCoder:coder]; [coder encodeObject:self.volumeLength]; }
- (id)initWithCoder:(NSCoder *)coder { if ((self = [super initWithCoder:coder])) self.volumeLength = [coder decodeObject]; return self; }
- (void)dealloc { [_volumeLength release]; [super dealloc]; }
@end

@implementation ProbeManagedObject @end
// Foundation can load CoreData transitively; avoid defining its runtime class.
// The production controller still uses its exact NSManagedObject type checks.
#define NSManagedObject ProbeManagedObject
@implementation DicomImage
- (NSString *)SRPath { return nil; }
@end
@implementation DicomSeries @end
@implementation DicomStudy
- (id)init { if ((self = [super init])) self.paths = [NSMutableDictionary dictionary]; return self; }
- (NSString *)roiPathForImage:(DicomImage *)image { return self.paths[image.objectID]; }
- (NSString *)roiPathForImage:(DicomImage *)image inArray:(id)images { return [self roiPathForImage:image]; }
- (DicomSeries *)roiSRSeries {
    static DicomSeries *series;
    if (!series) { series = [DicomSeries new]; series.seriesDICOMUID = @"synthetic-sr-series"; series.images = [NSSet set]; }
    return series;
}
@end

@implementation DCMPix @end

static NSMutableDictionary *writtenImages;
static DicomDatabase *database;
@implementation DicomDatabase
+ (DicomDatabase *)databaseForContext:(id)context { return database; }
- (NSString *)uniquePathForNewDataFileWithExtension:(NSString *)extension {
    return [self.directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%lu.%@", (unsigned long)++_nextPath, extension]];
}
- (void)addFilesAtPaths:(NSArray *)paths postNotifications:(BOOL)a dicomOnly:(BOOL)b rereadExistingItems:(BOOL)c generatedByOsiriX:(BOOL)d {
    for (NSString *path in paths) {
        DicomImage *image = writtenImages[path];
        CHECK(image != nil, "index only a successfully written archive");
        image.series.study.paths[image.objectID] = path; self.indexed++;
    }
}
- (void)lock {}
- (void)unlock {}
@end
@implementation BrowserController
+ (BrowserController *)currentBrowser { static BrowserController *browser; if (!browser) browser = [self new]; return browser; }
- (DicomDatabase *)database { return database; }
- (void)setDatabase:(DicomDatabase *)value {}
@end

// The ROI archives are decoded through the restricted unarchiver (#816), which
// test-roi-archive-class-restriction.py checks. It is Swift in the app
// (RestrictedUnarchiver.swift); its double is Swift too (Doubles.swift).
@interface HorosRestrictedUnarchiver : NSObject
+ (NSArray *)unarchiveROIsWithData:(NSData *)data;
+ (NSArray *)unarchiveROIsWithFile:(NSString *)path;
@end

@implementation SRAnnotation
+ (NSData *)roiFromDICOM:(NSString *)path { return path ? [NSData dataWithContentsOfFile:path] : nil; }
+ (NSString *)archiveROIsAsDICOM:(NSArray *)rois toPath:(NSString *)path forImage:(id)image {
    SRAnnotation *sr = [[[self alloc] initWithROIs:rois path:path forImage:image] autorelease];
    [sr writeToFileAtPath:path]; return nil;
}
- (id)initWithROIs:(NSArray *)rois path:(NSString *)path forImage:(DicomImage *)image {
    if ((self = [super init])) { self.rois = rois; self.image = image; } return self;
}
- (void)setSeriesInstanceUID:(NSString *)uid {}
- (BOOL)writeToFileAtPath:(NSString *)path {
    BOOL ok = [[NSArchiver archivedDataWithRootObject:self.rois] writeToFile:path atomically:YES];
    if (ok) { writtenImages[path] = self.image; database.writes++; } return ok;
}
@end

@implementation ProbeView
- (NSInteger)curImage { return self.index; }
- (void)cancelLengthPlacement { self.cancellations++; }
- (void)stopROIEditing {}
- (void)stopROIEditingForce:(BOOL)force {}
- (void)roiSet:(ROI *)roi { roi.curView = self; }
- (void)setNeedsDisplay:(BOOL)needed {}
@end

__ARCHIVE_READER__
@implementation ViewerController
@synthesize horos_imageView = imageView;
- (NSMutableArray *)horos_fileListAt:(NSInteger)index { return fileList[index]; }
- (NSMutableArray *)horos_pixListAt:(NSInteger)index { return pixList[index]; }
- (NSMutableArray *)horos_roiListAt:(NSInteger)index { return roiList[index]; }
- (NSMutableArray *)horos_copyRoiListAt:(NSInteger)index { return copyRoiList[index]; }
- (short)horos_curMovieIndex { return curMovieIndex; }
- (void)setHoros_curMovieIndex:(short)value { curMovieIndex = value; }
__METHODS__
- (NSArray *)probeSnapshotsForNewViewer:(BOOL)newViewer {
    int mx = (int)maxMovieIndex;
__SNAPSHOT__
    return volumeSnapshots;
}
@end
'''

DRIVER = r'''
static ROI *planar(NSString *name) { ROI *roi = [ROI new]; roi.name = name; return [roi autorelease]; }
static HorosVolumeLengthROI *length(NSString *identifier, NSInteger phase, double end) {
    HorosVolumeLengthROI *roi = [HorosVolumeLengthROI new]; roi.name = identifier; roi.isAliased = YES;
    roi.volumeLength = @{@"id":identifier, @"temporalIndex":@(phase), @"a":@[@0, @0, @0], @"b":@[@3, @4, @(end)]};
    return [roi autorelease];
}
static void moveEnd(HorosVolumeLengthROI *roi, double end) {
    NSMutableDictionary *payload = [[roi.volumeLength mutableCopy] autorelease];
    payload[@"b"] = @[@3, @4, @(end)]; roi.volumeLength = payload;
}
static DicomImage *makeImage(DicomSeries *series, NSInteger phase, NSInteger slice) {
    DicomImage *image = [DicomImage new];
    image.objectID = [NSString stringWithFormat:@"image-%ld-%ld", (long)phase, (long)slice];
    image.sopInstanceUID = [NSString stringWithFormat:@"synthetic-sop-%ld", (long)phase];
    image.frameID = @(slice); image.series = series; image.managedObjectContext = database.managedObjectContext;
    return [image autorelease];
}
static void phase(ViewerController *viewer, NSInteger movie, NSInteger slices, DicomSeries *series, DicomImage *source) {
    viewer->roiList[movie] = [NSMutableArray new]; viewer->pixList[movie] = [NSMutableArray new];
    viewer->fileList[movie] = [NSMutableArray new]; viewer->copyRoiList[movie] = [NSMutableArray new];
    for (NSInteger slice = 0; slice < slices; slice++) {
        [viewer->roiList[movie] addObject:[NSMutableArray array]];
        [viewer->copyRoiList[movie] addObject:[NSData data]];
        DCMPix *pix = [[[DCMPix alloc] init] autorelease]; pix.generated = source != nil;
        [viewer->pixList[movie] addObject:pix];
        [viewer->fileList[movie] addObject:source ?: makeImage(series, movie, slice)];
    }
}
static ViewerController *viewer(void) {
    ViewerController *v = [ViewerController new]; v->maxMovieIndex = 2;
    v->imageView = [ProbeView new]; v->undoQueue = [NSMutableArray new]; v->redoQueue = [NSMutableArray new];
    return [v autorelease];
}
static void uniqueAliases(ViewerController *v, NSInteger phase, NSString *identifier, NSUInteger expected) {
    HorosVolumeLengthROI *first = nil; NSUInteger count = 0;
    for (NSArray *slice in v->roiList[phase]) {
        NSUInteger perSlice = 0;
        for (ROI *roi in slice) if ([roi isKindOfClass:[HorosVolumeLengthROI class]] &&
                                   [[(HorosVolumeLengthROI *)roi volumeIdentifier] isEqual:identifier]) {
            if (!first) first = (id)roi;
            CHECK(first == roi, "all aliases of a UUID point to the same object");
            perSlice++; count++;
        }
        CHECK(perSlice <= 1, "each slice contains at most one alias for a UUID");
    }
    CHECK(count == expected, "alias coverage matches the phase's slice count");
}
static HorosVolumeLengthROI *onlyVolume(ViewerController *v, NSInteger phase) {
    NSArray *rois = [v volumeLengthROIsForMovieIndex:phase];
    CHECK(rois.count == 1, "one canonical volume in phase"); return rois[0];
}
static NSUInteger countNamed(NSArray *rois, NSString *name) {
    NSUInteger count = 0; for (ROI *roi in rois) if ([roi.name isEqual:name]) count++; return count;
}
static NSArray *stored(DicomImage *image) { return HorosVolumeLengthReadArchive([image.series.study roiPathForImage:image]); }

int main(int argc, char **argv) { @autoreleasepool {
    CHECK(argc == 2, "temporary directory supplied");
    database = [DicomDatabase new]; database.directory = [NSString stringWithUTF8String:argv[1]];
    database.managedObjectContext = [ProbeContext new]; writtenImages = [NSMutableDictionary new];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"SAVEROIS"];
    DicomSeries *series = [DicomSeries new]; series.study = [DicomStudy new];
    ViewerController *v = viewer(); phase(v, 0, 3, series, nil); phase(v, 1, 2, series, nil);
    DicomImage *anchor0 = v->fileList[0][0], *anchor1 = v->fileList[1][0];
    [v->roiList[0][0] addObject:planar(@"source 2D")];
    [v->roiList[0][1] addObject:planar(@"another slice 2D")];
    HorosVolumeLengthROI *a = length(@"length-A", 0, 12), *b = length(@"length-B", 1, 20);
    [v addVolumeLengthROI:a]; [v addVolumeLengthROI:b movieIndex:1];
    [v addVolumeLengthROI:a];
    uniqueAliases(v, 0, @"length-A", 3); uniqueAliases(v, 1, @"length-B", 2);
    uniqueAliases(v, 0, @"length-B", 0); uniqueAliases(v, 1, @"length-A", 0);
    CHECK(v->undoQueue.count == 0, "registration does not create an undo operation");
    CHECK([a.volumeLength[@"storageSOPInstanceUID"] isEqual:anchor0.sopInstanceUID], "original storage SOP recorded");
    CHECK([a.volumeLength[@"storageFrame"] isEqual:anchor0.frameID], "original frame recorded");
    [v addVolumeLengthROI:length(@"invalid", 9, 8) movieIndex:9];
    CHECK([v volumeLengthROIsForMovieIndex:9].count == 0, "unavailable phase is not populated");

    // The real undo serializer must copy each volume once, not once per slice.
    volumeCopyCount = 0;
    NSDictionary *beforeEdit = [v prepareObjectForUndo:@"roi"];
    CHECK(volumeCopyCount == 2, "undo copies two volume UUIDs exactly twice");
    NSArray *snapshotPhases = beforeEdit[@"rois"];
    CHECK(snapshotPhases[0][0][1] == snapshotPhases[0][1][1], "undo preserves shared alias references");
    CHECK(snapshotPhases[0][0][1] != a, "undo data is independent from current objects");
    [v->undoQueue addObject:beforeEdit]; moveEnd(a, 30);
    v->curMovieIndex = 1; [v deleteROI:b]; v->curMovieIndex = 0;
    [v undo:nil];
    uniqueAliases(v, 0, @"length-A", 3); uniqueAliases(v, 1, @"length-B", 2);
    CHECK([onlyVolume(v, 0).volumeLength[@"b"][2] doubleValue] == 12, "undo restores physical endpoints");
    CHECK(v->imageView.cancellations == 1, "undo cancels an incomplete placement");
    [v redo:nil];
    CHECK([onlyVolume(v, 0).volumeLength[@"b"][2] doubleValue] == 30, "redo restores edited endpoint");
    CHECK([v volumeLengthROIsForMovieIndex:1].count == 0, "redo restores deletion in the other phase");
    [v undo:nil];

    // A fresh 2D archive and its new volume are saved in the same operation.
    // The database cannot find the fresh path until saveROI finally indexes it.
    [v saveROI:0]; [v saveROI:1];
    CHECK(series.study.paths.count == 3, "one indexed SR per source image, with no parallel volume archive");
    CHECK(countNamed(stored(anchor0), @"source 2D") == 1, "save preserves the planar ROI at the anchor");
    CHECK(countNamed(stored(anchor0), @"length-A") == 1, "save persists the volume exactly once");
    CHECK(countNamed(stored(anchor1), @"length-B") == 1, "second phase uses its own source anchor");

    ViewerController *reopened = viewer();
    phase(reopened, 0, 3, series, nil); phase(reopened, 1, 2, series, nil);
    [reopened loadROI:0]; [reopened loadROI:1];
    uniqueAliases(reopened, 0, @"length-A", 3); uniqueAliases(reopened, 1, @"length-B", 2);
    CHECK(countNamed(reopened->roiList[0][0], @"source 2D") == 1, "reopening retains original planar ROI");

    // An archive that holds something else than ROIs (the restricted
    // unarchiver accepts strings) loads its ROIs, and the next images still
    // load (#866): the string went into the slice, and the -isAliased sent to
    // it ended the load.
    DicomSeries *strayed = [[DicomSeries new] autorelease]; strayed.study = [[DicomStudy new] autorelease];
    ViewerController *mixed = viewer(); phase(mixed, 0, 2, strayed, nil);
    NSString *strayPath = [database.directory stringByAppendingPathComponent:@"stray.roi"];
    NSString *nextPath = [database.directory stringByAppendingPathComponent:@"next.roi"];
    NSArray *strayArchive = @[@"stray", planar(@"after stray")];
    CHECK([[NSArchiver archivedDataWithRootObject:strayArchive] writeToFile:strayPath atomically:YES], "stray archive written");
    CHECK([[NSArchiver archivedDataWithRootObject:@[planar(@"next image")]] writeToFile:nextPath atomically:YES], "next archive written");
    strayed.study.paths[[mixed->fileList[0][0] objectID]] = strayPath;
    strayed.study.paths[[mixed->fileList[0][1] objectID]] = nextPath;
    [mixed loadROI:0];
    for (id object in mixed->roiList[0][0]) CHECK([object isKindOfClass:[ROI class]], "only ROIs reach the slice");
    CHECK([mixed->roiList[0][0] count] == 1 && countNamed(mixed->roiList[0][0], @"after stray") == 1, "the ROI beside the string loads");
    CHECK([[mixed->roiList[0][0] firstObject] curView] == mixed->imageView, "the loaded ROI is set on the view");
    CHECK(countNamed(mixed->roiList[0][1], @"next image") == 1, "the next image still loads");

    // Run the actual inlined reslice snapshot block, then restore into generated
    // slice arrays. Pixel resampling itself is deliberately outside this test.
    NSArray *snapshots = [reopened probeSnapshotsForNewViewer:YES];
    ViewerController *resliced = viewer();
    phase(resliced, 0, 5, series, anchor0); phase(resliced, 1, 4, series, anchor1);
    [resliced loadROI:0]; [resliced loadROI:1];
    CHECK(countNamed(resliced->roiList[0][0], @"source 2D") == 0, "generated planes do not load source planar ROIs");
    [resliced restoreVolumeLengthSnapshot:snapshots[0] movieIndex:0];
    [resliced restoreVolumeLengthSnapshot:snapshots[1] movieIndex:1];
    uniqueAliases(resliced, 0, @"length-A", 5); uniqueAliases(resliced, 1, @"length-B", 4);
    CHECK(onlyVolume(resliced, 0) != onlyVolume(reopened, 0), "new reslice window owns a separate mutable object");
    moveEnd(onlyVolume(resliced, 0), 42);
    CHECK([onlyVolume(reopened, 0).volumeLength[@"b"][2] doubleValue] == 12, "reslice window does not mutate source window endpoints");

    // Simulate another window saving a new UUID after this viewer loaded: the
    // merge must preserve that unknown UUID, as well as the source 2D record.
    NSString *path0 = [series.study roiPathForImage:anchor0];
    NSMutableArray *withForeign = [NSMutableArray arrayWithArray:stored(anchor0)];
    [withForeign addObject:length(@"foreign-length", 0, 7)];
    [SRAnnotation archiveROIsAsDICOM:withForeign toPath:path0 forImage:anchor0];
    [resliced saveROI:0];
    NSArray *afterEdit = stored(anchor0);
    CHECK(countNamed(afterEdit, @"source 2D") == 1, "generated save preserves source planar geometry");
    CHECK(countNamed(afterEdit, @"foreign-length") == 1, "merge preserves UUIDs owned by another writer");
    CHECK(countNamed(afterEdit, @"length-A") == 1, "generated save replaces, rather than duplicates, canonical UUID");
    for (ROI *roi in afterEdit) if ([roi.name isEqual:@"length-A"])
        CHECK([[(HorosVolumeLengthROI *)roi volumeLength][@"b"][2] doubleValue] == 42, "generated edit reaches original archive");
    [resliced deleteROI:onlyVolume(resliced, 0)]; [resliced saveROI:0];
    CHECK(countNamed(stored(anchor0), @"length-A") == 0, "known deleted UUID is removed from persistent archive");
    CHECK(countNamed(stored(anchor0), @"source 2D") == 1, "deleting volume retains source planar ROI");
    CHECK(countNamed(stored(anchor0), @"foreign-length") == 1, "deletion leaves unrelated persistent UUID intact");
    CHECK(countNamed(stored(anchor1), @"length-B") == 1, "saving/deleting phase zero leaves phase one intact");

    // Restoring an empty snapshot (after undoing creation) must remove aliases
    // that loadROI may have just recovered from disk before a reslice.
    NSMutableDictionary *empty = [[snapshots[1] mutableCopy] autorelease]; empty[@"rois"] = @[];
    [resliced restoreVolumeLengthSnapshot:empty movieIndex:1];
    CHECK([resliced volumeLengthROIsForMovieIndex:1].count == 0, "empty snapshot does not resurrect disk aliases");

    // An unreadable source archive is not an empty collection to overwrite.
    NSData *corrupt = [@"not an ROI archive" dataUsingEncoding:NSUTF8StringEncoding];
    [corrupt writeToFile:path0 atomically:YES]; NSUInteger writesBefore = database.writes;
    [resliced saveROI:0];
    CHECK([[NSData dataWithContentsOfFile:path0] isEqual:corrupt], "unreadable original is preserved byte for byte");
    CHECK(database.writes == writesBefore, "failed read never triggers archive replacement");
    CHECK(contextQueueUnits >= 10, "load/save persistence runs through the context queue adapter");
    puts("PASS: real controller registration, alias identity, undo/redo, phases, reslice snapshots, original/generated persistence and merge deletion");
    return 0;
}}
'''

translation_unit = DECLARATIONS.replace('__ARCHIVE_READER__', archive_reader).replace('__METHODS__', methods).replace(
    '__SNAPSHOT__', snapshot
) + DRIVER
header = HEADER.replace('__METHOD_DECLARATIONS__', '\n'.join(signature + ';' for signature in signatures))

with tempfile.TemporaryDirectory(prefix='horos-volume-persistence-') as directory:
    folder = Path(directory)
    (folder / 'Harness.h').write_text(header)
    (folder / 'test.m').write_text(translation_unit + harness_defaults.OBJC)
    (folder / 'ROI.swift').write_text(extension)
    (folder / 'Doubles.swift').write_text(DOUBLES)
    include = ['-I', str(folder), '-I', str(root / 'Horos/Sources')]
    subprocess.run([
        'xcrun', 'clang', '-c', '-fno-objc-arc', '-fsanitize=undefined',
        '-Wno-deprecated-declarations', *include,
        str(folder / 'test.m'), '-o', str(folder / 'test.o'),
    ], check=True)
    subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', *include, str(root / 'Horos/Sources/HorosObjCException.m'),
                    '-o', str(folder / 'HorosObjCException.o')], check=True)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-sanitize=undefined', *include,
                    '-import-objc-header', str(folder / 'Harness.h'), str(folder / 'ROI.swift'), str(folder / 'Doubles.swift'),
                    str(folder / 'test.o'), str(folder / 'HorosObjCException.o'),
                    '-framework', 'Foundation', '-o', str(folder / 'test')], check=True)
    subprocess.run([str(folder / 'test'), str(folder)], check=True)
