#!/usr/bin/env python3
"""A plugin built for Horos or OsiriX sends the application the selectors of
that SDK, and they answer.

dyld checks the symbols a plugin looks up when it loads; nothing checks its
selectors until it sends one, and an absent one raises "unrecognized selector"
in the middle of the plugin's work, which on a background thread ends the
application. tests/test-legacy-plugin-abi.py reads the selectors in the
metadata of the bundle; this test sends them.

QALegacySelectors.osirixplugin is built here the way those plugins were:
Objective-C without ARC, a bundle linked with -undefined dynamic_lookup, its
principal class a subclass of PluginFilter, and no header of the application.
The development bundle is launched isolated (tools/native_app.py), with a
database of its own in a temporary folder, and loads it with --LoadPlugin. Two
seconds after it is loaded, on the main thread, the plugin:

- asks each class whether its instances, or the class, answer each selector of
  the list below, and for a selector the application adds to a class of the
  system, whether the method that answers is the application's (dladdr on its
  implementation), since a private framework can have a method of the same
  name that does something else;
- writes a DICOM file with DICOMExport and sends the browser
  -getNewFileDatabasePath:, -getNewFileDatabasePath:dbFolder:,
  -addFilesToDatabase: and the other ways into the database, on the main
  thread and again on a background thread, and -checkIncoming:;
- shuffles an array with -shuffle and -shuffledArray, sizes a file and a
  folder with -sizeAtPath:, asks -findSystemFolderOfType:forDomain: for the
  user's Application Support and -destinationOfAliasAtPath: for a file that is
  no alias, and reads, writes and binds a preference by its values key;
- finds the study and the series it added by their UIDs, on the main thread
  and on a background thread, builds an error with the variadic constructors,
  compares SOP class UIDs with the standard's, and sends the application's
  controller, the browser, the fly-through assistant and the segmentation
  class the other selectors of the SDK they answer again, a NULL where the
  SDK took an optional pointer;
- uses the bar of a wait panel as a progress indicator and as a level
  indicator, the two classes the headers of the SDKs declared for it, makes
  the panel indeterminate and determinate again, and sends it the selectors
  only some of those headers declare.

For each selector of tests/fixtures/former-sdk-selector-types.json the plugin
also writes the type encoding of the method that answers, and the test
compares it, without the frame offsets, with the one the compiler gives for
the SDK's declaration: a facade with another argument or return type would
read its caller's registers wrongly.

It writes what it found as JSON to the path of QA_LEGACY_SELECTORS_REPORT and
the test stops the application. A check that is not "ok" fails the test with
what the plugin saw.

    python3 tests/test-legacy-plugin-selectors.py [--app BUNDLE]

--app is a development bundle (by default build/Development/HorosDevelopment.app,
which script/build_and_run.sh --verify leaves): one with the development
identifier, which the isolation needs, signed so that it loads a plugin signed
ad hoc. A copy of it whose executable has one of these selectors renamed in
its method names must fail with that selector. Exit status 2 without the
bundle or the compiler, or with a bundle of an earlier build than the built
product. The test opens the application: it needs the graphic
session, and no other development instance of this checkout running.
"""
import argparse
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import native_app  # noqa: E402

TYPES = json.loads((ROOT / 'tests/fixtures/former-sdk-selector-types.json').read_text())['types']
# The classes of the system the application adds selectors of the SDK to.
SYSTEM_CLASSES = {'NSMutableArray', 'NSArray', 'NSFileManager', 'NSObject', 'NSUserDefaultsController', 'NSError',
                  'NSInvocation', 'NSManagedObject', 'NSString', 'NSDictionary', 'NSMutableDictionary', 'NSBitmapImageRep',
                  'NSBezierPath'}

# (class, '-' or '+', selector, whether the class is the system's).
SELECTORS = [
    ('BrowserController', '-', 'getNewFileDatabasePath:', False),
    ('BrowserController', '-', 'getNewFileDatabasePath:dbFolder:', False),
    ('BrowserController', '-', 'addFilesToDatabase:', False),
    ('BrowserController', '-', 'addFilesToDatabase:onlyDICOM:produceAddedFiles:', False),
    ('BrowserController', '-', 'addFilesToDatabase:onlyDICOM:produceAddedFiles:parseExistingObject:', False),
    ('BrowserController', '-', 'addFilesToDatabase:onlyDICOM:produceAddedFiles:parseExistingObject:context:dbFolder:', False),
    ('BrowserController', '-', 'addFilesToDatabase:onlyDICOM:safeRebuild:produceAddedFiles:', False),
    ('BrowserController', '+', 'addFiles:toContext:onlyDICOM:notifyAddedFiles:parseExistingObject:dbFolder:', False),
    ('BrowserController', '+', 'addFiles:toContext:toDatabase:onlyDICOM:notifyAddedFiles:parseExistingObject:dbFolder:', False),
    ('BrowserController', '+', 'addFiles:toContext:toDatabase:onlyDICOM:notifyAddedFiles:parseExistingObject:dbFolder:generatedByOsiriX:', False),
    ('BrowserController', '+', 'addFiles:toContext:toDatabase:onlyDICOM:notifyAddedFiles:parseExistingObject:dbFolder:generatedByOsiriX:mountedVolume:', False),
    ('BrowserController', '-', 'checkIncoming:', False),
    ('BrowserController', '-', 'checkIncomingNow:', False),
    ('BrowserController', '-', 'checkIncomingThread:', False),
    ('DCMTKQueryNode', '-', 'moveDataset', False),
    ('DCMTKQueryNode', '-', 'setupNetworkWithSyntax:dataset:', False),
    ('DCMTKQueryNode', '-', 'setupNetworkWithSyntax:dataset:destination:', False),
    ('NSMutableArray', '-', 'shuffle', True),
    ('NSArray', '-', 'shuffledArray', True),
    ('NSFileManager', '-', 'sizeAtPath:', True),
    ('NSFileManager', '-', 'sizeAtFSRef:', True),
    ('NSFileManager', '-', 'findSystemFolderOfType:forDomain:', True),
    ('NSFileManager', '-', 'destinationOfAliasAtPath:', True),
    ('NSObject', '-', 'valueForValuesKey:', True),
    ('NSObject', '-', 'setValue:forValuesKey:', True),
    ('NSObject', '-', 'bind:toObject:withValuesKey:options:', True),
]
SELECTORS += [(key.split(' ', 1)[0], key.split(' ', 1)[1][0], key.split(' ', 1)[1][1:], key.split(' ', 1)[0] in SYSTEM_CLASSES)
              for key in sorted(TYPES) if tuple(key.replace(' -', ' - ', 1).replace(' +', ' + ', 1).split(' ', 2)) not in
              {(cls, kind, selector) for cls, kind, selector, _ in SELECTORS}]


# Selectors the former SDK declares as answering nothing and later headers of
# the SDK declare with an answer, which the application gives: a caller of the
# former declaration ignores it. Each answer here comes back in registers on
# arm64 and x86_64 (no hidden pointer to the result is passed), so the
# arguments a caller of the former declaration passes are where the method
# reads them. The arguments must still be the ones the former SDK declared.
LATER_ANSWERS = {
    'DCMView -makeTextureFromImage:forTexture:buffer:textureUnit:': '{CGSize=dd}',
}


def answers_as_declared(key, answered, declared):
    """Whether `answered` has the types `declared`, or those of a later answer
    of LATER_ANSWERS in place of the nothing the former SDK declared."""
    if answered == declared:
        return True
    later = LATER_ANSWERS.get(key)
    return bool(later) and declared.startswith('v') and answered == later + declared[1:]


def without_offsets(encoding):
    """A method's type encoding without its frame offsets; the sizes of its C arrays stay."""
    return re.sub(r'\[\d+|\d+', lambda found: found.group(0) if found.group(0).startswith('[') else '', encoding)


PLUGIN = r'''
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// What the plugin uses of the SDK, declared here as its headers declared it.
@interface PluginFilter : NSObject
- (void)initPlugin;
- (long)filterImage:(NSString *)menuName;
@end
@interface BrowserController : NSWindowController
+ (BrowserController *)currentBrowser;
- (id)database;
- (NSString *)getNewFileDatabasePath:(NSString *)extension;
- (NSString *)getNewFileDatabasePath:(NSString *)extension dbFolder:(NSString *)dbFolder;
- (NSArray *)addFilesToDatabase:(NSArray *)newFilesArray;
- (NSArray *)addFilesToDatabase:(NSArray *)newFilesArray onlyDICOM:(BOOL)onlyDICOM produceAddedFiles:(BOOL)produceAddedFiles;
- (NSArray *)addFilesToDatabase:(NSArray *)newFilesArray onlyDICOM:(BOOL)onlyDICOM produceAddedFiles:(BOOL)produceAddedFiles parseExistingObject:(BOOL)parseExistingObject;
+ (NSArray *)addFiles:(NSArray *)newFilesArray toContext:(NSManagedObjectContext *)context toDatabase:(BrowserController *)browserController onlyDICOM:(BOOL)onlyDICOM notifyAddedFiles:(BOOL)notifyAddedFiles parseExistingObject:(BOOL)parseExistingObject dbFolder:(NSString *)dbFolder generatedByOsiriX:(BOOL)generatedByOsiriX;
- (void)checkIncoming:(id)sender;
- (NSManagedObject *)findStudyUID:(NSString *)uid;
- (NSManagedObject *)findSeriesUID:(NSString *)uid;
- (NSString *)localDatabasePath;
- (const char *)cfixedDocumentsDirectory;
- (int)findDBPath:(NSString *)path dbFolder:(NSString *)folder;
- (NSArray *)distantStudiesForSmartAlbum:(NSString *)albumName;
- (NSArray *)ROIsAndKeyImages:(id)sender sameSeries:(BOOL *)sameSeries;
- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar;
- (void)decompressArrayOfFiles:(NSArray *)array work:(NSNumber *)work;
@end
@interface NSObject (QAFormerSDKApplication)
- (NSScreen *)dbScreen;
- (void)osirix64bit:(id)sender;
- (void)runPreferencesUpdateCheck:(NSTimer *)timer;
@end
@interface NSError (QAFormerSDK)
+ (NSError *)osirixErrorWithCode:(NSInteger)code localizedDescriptionFormat:(NSString *)format, ...;
+ (NSError *)osirixErrorWithCode:(NSInteger)code underlyingError:(NSError *)underlyingError localizedDescriptionFormat:(NSString *)format, ...;
@end
@interface NSUserDefaultsController (QAFormerSDK)
+ (BOOL)IsBonjourSharingActive;
+ (NSString *)BonjourSharingName;
@end
@interface NSString (QAFormerSDKStrings)
+ (NSString *)dateString:(NSTimeInterval)date;
- (NSString *)markedString;
- (NSString *)urlEncodedString;
- (NSString *)xmlUnescapedString;
@end
@interface NSDictionary (QAFormerSDKCollections)
- (id)deepMutableCopy;
- (id)objectForKey:(id)key ofClass:(Class)cl;
@end
@interface NSMutableDictionary (QAFormerSDKCollections)
- (void)removeObject:(id)obj;
- (void)setBool:(BOOL)b forKey:(NSString *)key;
@end
@interface NSBezierPath (QAFormerSDK)
+ (NSBezierPath *)bezierPathWithRoundedRect:(NSRect)rect cornerRadius:(float)radius;
@end
@interface NSBitmapImageRep (QAFormerSDK)
- (NSBitmapImageRep *)repUsingColorSpaceName:(NSString *)colorSpaceName;
- (NSBitmapImageRep *)smoothen:(NSUInteger)kernelSize;
- (void)ATMask:(float)level;
@end
@interface NSObject (QAFormerSDKSwizzle)
+ (BOOL)jr_swizzleMethod:(SEL)origSel withMethod:(SEL)altSel error:(NSError **)error;
@end
@interface QASwizzled : NSObject
- (NSString *)first;
- (NSString *)second;
@end
@implementation QASwizzled
- (NSString *)first { return @"first"; }
- (NSString *)second { return @"second"; }
@end
@interface QAAbstractSyntaxUID : NSObject
+ (NSString *)CTImageStorage;
+ (NSString *)MRImageStorage;
+ (NSString *)enhancedCTImageStorage;
+ (BOOL)isImageStorage:(NSString *)uid;
- (id)initWithUID:(NSString *)uid name:(NSString *)name type:(NSString *)type;
- (NSString *)uid;
- (BOOL)isImageStorage;
@end
@interface QAFlyAssistant : NSObject
- (id)initWithVolume:(float *)data WidthDimension:(int *)dim Spacing:(float *)spacing ResampleVoxelSize:(float)vsize;
- (int)input3DCoords2LineCoords:(const int)x :(const int)y :(const int)z;
- (void)getInputMinMaxValues;
- (void)computeHistogram;
- (void)smoothHistogramWith:(const unsigned int)window;
- (void)computeIntervalThresholdsFrom:(float)pixValue;
- (void)autoComputeThresholdFromValue:(float)v;
- (void)thresholdImage;
@end
@interface QASegmentation : NSObject
+ (NSArray *)fastGrowingRegionWithVolume:(float *)volume width:(long)w height:(long)h depth:(long)depth seedPoint:(long *)seed from:(float)from pixList:(NSArray *)pixList;
@end
// The wait panel as the headers of the SDKs declared it, all of them together;
// -progress is a progress indicator in some and a level indicator in others.
@interface QAWait : NSWindowController
@property (nonatomic) int maxProgress;
+ (QAWait *)showWithString:(NSString *)str maxProgress:(int)maxValue showCancel:(BOOL)showCancel;
- (id)initWithString:(NSString *)str :(BOOL)useSession;
- (void)setProgressValue:(double)v;
- (void)incrementBy:(double)delta;
- (void)increment;
- (id)progress;
- (NSProgressIndicator *)indeterminateIndicator;
- (void)setIndeterminate:(BOOL)v;
- (void)setString:(NSString *)str;
- (NSTextField *)text;
- (NSButton *)abort;
@end
@interface QAShell : NSObject
+ (NSString *)ip;
+ (NSString *)mac;
+ (int)userId;
@end
@interface QAHoros : NSObject
+ (id)dateWithYear:(NSInteger)year month:(NSUInteger)month day:(NSUInteger)day hour:(NSUInteger)hour minute:(NSUInteger)minute second:(NSUInteger)second timeZone:(NSTimeZone *)timeZone;
@end
@interface DICOMExport : NSObject
- (long)setPixelData:(unsigned char *)data samplesPerPixel:(int)samplesPerPixel bitsPerSample:(int)bitsPerSample width:(long)width height:(long)height;
- (void)setSeriesDescription:(NSString *)desc;
- (void)setSeriesNumber:(long)no;
- (NSString *)writeDCMFile:(NSString *)dstPath;
@end
@interface NSMutableArray (QAFormerSDK)
- (id)shuffle;
@end
@interface NSArray (QAFormerSDK)
- (NSArray *)shuffledArray;
@end
@interface NSFileManager (QAFormerSDK)
- (NSUInteger)sizeAtPath:(NSString *)path;
- (NSString *)findSystemFolderOfType:(int)folderType forDomain:(int)domain;
- (NSString *)destinationOfAliasAtPath:(NSString *)path;
@end
@interface NSObject (QAFormerSDK)
- (id)valueForValuesKey:(NSString *)keyPath;
- (void)setValue:(id)value forValuesKey:(NSString *)keyPath;
- (void)bind:(NSString *)binding toObject:(id)observable withValuesKey:(NSString *)key options:(NSDictionary *)options;
@end

@interface QALegacySelectors : PluginFilter
@end

static NSMutableDictionary *report;
static NSMutableDictionary *types;

static void note(NSString *check, NSString *problem) {
    @synchronized (report) { [report setObject:(problem ?: @"ok") forKey:check]; }
}

// Whether `path` is under `folder`, /private/var and /var being the same place.
static BOOL isUnder(NSString *path, NSString *folder) {
    if ([path hasPrefix:@"/private/"]) path = [path substringFromIndex:8];
    if ([folder hasPrefix:@"/private/"]) folder = [folder substringFromIndex:8];
    return path.length && [path hasPrefix:folder];
}

static NSString *imageOf(IMP implementation) {
    Dl_info info;
    return (implementation && dladdr((void *)implementation, &info) && info.dli_fname) ? [NSString stringWithUTF8String:info.dli_fname] : @"";
}

static NSString *writeImage(NSString *folder, int number) {
    DICOMExport *exporter = [[[NSClassFromString(@"DICOMExport") alloc] init] autorelease];
    unsigned char *pixels = calloc(16 * 16, 2);
    for (int i = 0; i < 16 * 16; i++) pixels[2 * i] = (unsigned char)(i + number);
    [exporter setPixelData:pixels samplesPerPixel:1 bitsPerSample:16 width:16 height:16];
    [exporter setSeriesDescription:@"QA legacy selectors"];
    [exporter setSeriesNumber:9000 + number];
    NSString *path = [exporter writeDCMFile:[folder stringByAppendingPathComponent:[NSString stringWithFormat:@"qa-%d.dcm", number]]];
    free(pixels);
    return path;
}

static NSString *added(NSArray *objects, NSUInteger count) {
    if (![objects isKindOfClass:[NSArray class]]) return [NSString stringWithFormat:@"answered %@", objects];
    if (objects.count != count) return [NSString stringWithFormat:@"answered %lu objects for %lu files", (unsigned long)objects.count, (unsigned long)count];
    for (id object in objects)
        if (![object isKindOfClass:NSClassFromString(@"DicomImage")]) return [NSString stringWithFormat:@"answered a %@", [object class]];
    return nil;
}

@implementation QALegacySelectors

- (void)initPlugin {
    [self performSelector:@selector(run) withObject:nil afterDelay:2.0];
}

- (long)filterImage:(NSString *)menuName { return 0; }

- (void)run {
    report = [[NSMutableDictionary alloc] init];
    types = [[NSMutableDictionary alloc] init];
    NSString *executable = [[NSBundle mainBundle] executablePath];
    NSString *work = [NSString stringWithUTF8String:getenv("QA_LEGACY_SELECTORS_WORK")];
    @try {
        NSArray *selectors = [NSArray arrayWithContentsOfFile:[NSString stringWithUTF8String:getenv("QA_LEGACY_SELECTORS_LIST")]];
        for (NSArray *entry in selectors) {
            Class cls = NSClassFromString([entry objectAtIndex:0]);
            BOOL ofClass = [[entry objectAtIndex:1] isEqualToString:@"+"];
            SEL selector = NSSelectorFromString([entry objectAtIndex:2]);
            NSString *check = [NSString stringWithFormat:@"%@ %@%@", [entry objectAtIndex:0], [entry objectAtIndex:1], [entry objectAtIndex:2]];
            Method method = cls ? (ofClass ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector)) : NULL;
            if (!cls) note(check, @"the class is missing");
            else if (!method) note(check, @"unrecognized selector");
            else if ([[entry objectAtIndex:3] boolValue] && ![imageOf(method_getImplementation(method)) isEqualToString:executable])
                note(check, [@"answered by " stringByAppendingString:imageOf(method_getImplementation(method))]);
            else note(check, nil);
            if (method && method_getTypeEncoding(method)) [types setObject:[NSString stringWithUTF8String:method_getTypeEncoding(method)] forKey:check];
        }

        BrowserController *browser = [NSClassFromString(@"BrowserController") currentBrowser];
        if (!browser || ![browser database]) {
            note(@"the browser and its database", @"none two seconds after the plugin was loaded");
        } else {
            NSString *first = [browser getNewFileDatabasePath:@"dcm"], *second = [browser getNewFileDatabasePath:@"dcm"];
            NSString *data = [NSString stringWithUTF8String:getenv("QA_LEGACY_SELECTORS_DATABASE")];
            note(@"-getNewFileDatabasePath: answers a new path in the database each time",
                 (first.length && second.length && ![first isEqualToString:second] && [[first stringByResolvingSymlinksInPath] hasPrefix:data]
                  && [first.pathExtension isEqualToString:@"dcm"]) ? nil : [NSString stringWithFormat:@"%@ then %@", first, second]);
            NSString *inFolder = [browser getNewFileDatabasePath:@"dcm" dbFolder:data];
            note(@"-getNewFileDatabasePath:dbFolder: answers a path in that database",
                 [[inFolder stringByResolvingSymlinksInPath] hasPrefix:data] ? nil : [NSString stringWithFormat:@"%@", inFolder]);

            NSString *one = writeImage(work, 1), *two = writeImage(work, 2), *three = writeImage(work, 3), *four = writeImage(work, 4);
            note(@"DICOMExport writes the files", (one && two && three && four) ? nil : @"-writeDCMFile: answered nil");
            NSArray *firstAdded = [browser addFilesToDatabase:[NSArray arrayWithObject:one]];
            note(@"-addFilesToDatabase: answers the images added", added(firstAdded, 1));
            note(@"-addFilesToDatabase:onlyDICOM:produceAddedFiles: answers the images added",
                 added([browser addFilesToDatabase:[NSArray arrayWithObject:two] onlyDICOM:YES produceAddedFiles:YES], 1));
            note(@"+addFiles:toContext:toDatabase:...generatedByOsiriX: answers the images added",
                 added([NSClassFromString(@"BrowserController") addFiles:[NSArray arrayWithObject:three] toContext:nil toDatabase:browser onlyDICOM:YES
                                                        notifyAddedFiles:YES parseExistingObject:NO dbFolder:nil generatedByOsiriX:YES], 1));
            [browser checkIncoming:self];
            note(@"-checkIncoming: returns", nil);

            id image = [firstAdded lastObject];
            id series = [image valueForKey:@"series"], study = [series valueForKey:@"study"];
            NSString *studyUID = [study valueForKey:@"studyInstanceUID"], *seriesUID = [series valueForKey:@"seriesDICOMUID"];
            note(@"-findStudyUID: finds the study added", (study && [browser findStudyUID:studyUID] == study) ? nil
                 : [NSString stringWithFormat:@"%@ for %@", [browser findStudyUID:studyUID], studyUID]);
            note(@"-findSeriesUID: finds the series added", (series && [browser findSeriesUID:seriesUID] == series) ? nil
                 : [NSString stringWithFormat:@"%@ for %@", [browser findSeriesUID:seriesUID], seriesUID]);
            note(@"-findStudyUID: answers nil for a UID the database does not have", [browser findStudyUID:@"1.2.3.999"] ? @"answered an object" : nil);
            note(@"-localDatabasePath answers the index of the database",
                 isUnder([browser localDatabasePath], data) ? nil : [NSString stringWithFormat:@"%@", [browser localDatabasePath]]);
            const char *documents = [browser cfixedDocumentsDirectory];
            note(@"-cfixedDocumentsDirectory answers the database folder as a C string",
                 (documents && isUnder([NSString stringWithUTF8String:documents], data)) ? nil
                 : [NSString stringWithFormat:@"%s", documents ? documents : "NULL"]);
            note(@"-findDBPath:dbFolder: answers -1 for a folder that is no source", [browser findDBPath:@"/nowhere/qa" dbFolder:@"/nowhere/qa"] == -1 ? nil : @"answered a row");
            note(@"-distantStudiesForSmartAlbum: answers without asking a node when the albums do not",
                 [[browser distantStudiesForSmartAlbum:@"QA no album"] count] == 0 ? nil : @"answered studies");
            note(@"-ROIsAndKeyImages:sameSeries: accepts NULL", [[browser ROIsAndKeyImages:nil sameSeries:NULL] isKindOfClass:[NSArray class]] ? nil : @"did not answer an array");
            BOOL sameSeries = YES;
            [browser ROIsAndKeyImages:nil sameSeries:&sameSeries];
            note(@"-ROIsAndKeyImages:sameSeries: writes its flag", nil);
            note(@"-toolbarDefaultItemIdentifiers: answers the toolbar's items", [[browser toolbarDefaultItemIdentifiers:nil] count] > 0 ? nil : @"none");
            [browser decompressArrayOfFiles:[NSArray array] work:[NSNumber numberWithChar:'D']];
            note(@"-decompressArrayOfFiles:work: returns for no file", nil);

            id application = [NSApp delegate];
            NSScreen *reserved = [application dbScreen];
            note(@"-dbScreen answers a screen or nil", (!reserved || [reserved isKindOfClass:[NSScreen class]]) ? nil : @"answered another object");
            [application osirix64bit:nil];
            [application runPreferencesUpdateCheck:nil];
            note(@"-osirix64bit: and -runPreferencesUpdateCheck: return", nil);

            // The same from a background thread, as a plugin's own thread sends them.
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                @autoreleasepool {
                    @try {
                        NSString *path = [browser getNewFileDatabasePath:@"dcm"];
                        note(@"-getNewFileDatabasePath: on a background thread", path.length ? nil : @"answered nil");
                        note(@"-addFilesToDatabase: on a background thread", added([browser addFilesToDatabase:[NSArray arrayWithObject:four]], 1));
                        note(@"-findStudyUID: and -findSeriesUID: on a background thread",
                             ([browser findStudyUID:studyUID] && [browser findSeriesUID:seriesUID]) ? nil : @"answered nil");
                        [NSClassFromString(@"NSUserDefaultsController") IsBonjourSharingActive];
                        note(@"+IsBonjourSharingActive and +BonjourSharingName on a background thread",
                             [[NSClassFromString(@"NSUserDefaultsController") BonjourSharingName] isKindOfClass:[NSString class]] ? nil : @"no name");
                        note(@"+addFiles:...generatedByOsiriX: on a background thread, for a file already there",
                             [[NSClassFromString(@"BrowserController") addFiles:[NSArray arrayWithObject:one] toContext:nil toDatabase:browser onlyDICOM:YES
                                                               notifyAddedFiles:NO parseExistingObject:NO dbFolder:nil generatedByOsiriX:NO] isKindOfClass:[NSArray class]]
                             ? nil : @"did not answer an array");
                    } @catch (NSException *exception) {
                        note(@"the background thread", [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]);
                    }
                }
                dispatch_semaphore_signal(done);
            });
            // The main thread goes on serving its run loop while the other thread works.
            NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:60];
            while (dispatch_semaphore_wait(done, DISPATCH_TIME_NOW) != 0 && [limit timeIntervalSinceNow] > 0)
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            if ([limit timeIntervalSinceNow] <= 0) note(@"the background thread", @"did not finish in 60 seconds");
        }

        NSError *underlying = [NSError errorWithDomain:@"qa" code:3 userInfo:nil];
        NSError *made = [NSError osirixErrorWithCode:7 localizedDescriptionFormat:@"%@ and %d", @"one", 2];
        NSError *wrapped = [NSError osirixErrorWithCode:8 underlyingError:underlying localizedDescriptionFormat:@"%d files", 5];
        note(@"+osirixErrorWithCode:localizedDescriptionFormat: formats its message",
             (made.code == 7 && [made.localizedDescription isEqualToString:@"one and 2"]) ? nil : [NSString stringWithFormat:@"%@", made]);
        note(@"+osirixErrorWithCode:underlyingError:localizedDescriptionFormat: keeps the underlying error",
             (wrapped.code == 8 && [wrapped.localizedDescription isEqualToString:@"5 files"] && [wrapped.userInfo objectForKey:NSUnderlyingErrorKey] == underlying)
             ? nil : [NSString stringWithFormat:@"%@", wrapped]);

        Class syntax = NSClassFromString(@"DCMAbstractSyntaxUID");
        note(@"DCMAbstractSyntaxUID answers the standard's UIDs",
             ([[syntax CTImageStorage] isEqualToString:@"1.2.840.10008.5.1.4.1.1.2"] && [[syntax MRImageStorage] isEqualToString:@"1.2.840.10008.5.1.4.1.1.4"]
              && [[syntax enhancedCTImageStorage] isEqualToString:@"1.2.840.10008.5.1.4.1.1.2.1"]) ? nil
             : [NSString stringWithFormat:@"%@ %@ %@", [syntax CTImageStorage], [syntax MRImageStorage], [syntax enhancedCTImageStorage]]);
        id anInstance = [[[syntax alloc] initWithUID:@"1.2.840.10008.5.1.4.1.1.2" name:@"CT" type:@"ImageStorage"] autorelease];
        note(@"a DCMAbstractSyntaxUID made with -initWithUID:name:type: keeps its UID and its type",
             ([[anInstance uid] isEqualToString:@"1.2.840.10008.5.1.4.1.1.2"] && [anInstance isImageStorage]) ? nil : [NSString stringWithFormat:@"%@", [anInstance uid]]);

        int dimensions[3] = {8, 8, 8};
        float spacing[3] = {1, 1, 1};
        float *volume = calloc(8 * 8 * 8, sizeof(float));
        for (int i = 0; i < 8 * 8 * 8; i++) volume[i] = (float)(i % 200);
        id fly = [[[NSClassFromString(@"FlyAssistant") alloc] initWithVolume:volume WidthDimension:dimensions Spacing:spacing ResampleVoxelSize:1] autorelease];
        int line = [fly input3DCoords2LineCoords:3 :2 :1];
        [fly getInputMinMaxValues];
        [fly computeHistogram];
        [fly smoothHistogramWith:5];
        [fly computeIntervalThresholdsFrom:100];
        [fly autoComputeThresholdFromValue:100];
        [fly thresholdImage];
        note(@"FlyAssistant answers the steps the SDK named", (fly && line == 3 + 2 * 8 + 1 * 64) ? nil : [NSString stringWithFormat:@"%@, index %d", fly, line]);

        long seed[3] = {4, 4, 4};
        NSArray *grown = [NSClassFromString(@"ITKSegmentation3D") fastGrowingRegionWithVolume:volume width:8 height:8 depth:8 seedPoint:seed from:1000 pixList:[NSArray array]];
        note(@"+fastGrowingRegionWithVolume:... answers no ROI without images", ([grown isKindOfClass:[NSArray class]] && grown.count == 0) ? nil : @"did not answer an empty array");
        free(volume);

        QAWait *wait = [[[NSClassFromString(@"Wait") alloc] initWithString:@"QA wait" :NO] autorelease];
        NSProgressIndicator *bar = [wait progress];
        NSLevelIndicator *level = [wait progress];
        [bar setUsesThreadedAnimation:YES];
        [bar startAnimation:nil];
        [bar stopAnimation:nil];
        [bar setIndeterminate:NO];
        [wait incrementBy:10];
        note(@"-[Wait progress] answers a plugin that takes it for a progress indicator",
             ([bar isKindOfClass:[NSProgressIndicator class]] && bar.window == wait.window && bar.doubleValue == 10 && !bar.isIndeterminate) ? nil
             : [NSString stringWithFormat:@"a %@ at %g", [bar class], bar.doubleValue]);
        level.warningValue = 70;
        level.criticalValue = 90;
        level.numberOfTickMarks = 5;
        level.fillColor = [NSColor blueColor];
        level.intValue = 30;
        note(@"-[Wait progress] answers a plugin that takes it for a level indicator",
             (level.warningValue == 70 && level.criticalValue == 90 && level.numberOfTickMarks == 5 && [level.fillColor isEqual:[NSColor blueColor]]
              && bar.doubleValue == 30 && level.maxValue == 100) ? nil
             : [NSString stringWithFormat:@"warning %g, critical %g, value %g", level.warningValue, level.criticalValue, bar.doubleValue]);
        NSProgressIndicator *sweeping = [wait indeterminateIndicator];
        BOOL hiddenBefore = sweeping.isHidden && !bar.isHidden;
        [wait setIndeterminate:YES];
        BOOL sweeps = bar.isHidden && !sweeping.isHidden && sweeping.isIndeterminate && !bar.isIndeterminate;
        [wait incrementBy:5];
        [wait setIndeterminate:NO];
        note(@"-[Wait setIndeterminate:] shows a second bar that sweeps and then the determinate one, which kept its value",
             (sweeping != bar && sweeping.superview == bar.superview && hiddenBefore && sweeps && !bar.isHidden && sweeping.isHidden
              && !bar.isIndeterminate && bar.doubleValue == 35) ? nil
             : [NSString stringWithFormat:@"before %d, sweeping %d, after: determinate hidden %d, the other hidden %d, value %g",
                hiddenBefore, sweeps, bar.isHidden, sweeping.isHidden, bar.doubleValue]);
        wait.maxProgress = 250;
        [wait setProgressValue:40];
        [wait increment];
        [wait setString:@"QA another message"];
        note(@"-[Wait setMaxProgress:], -setProgressValue:, -increment and -setString: do what they name",
             (wait.maxProgress == 250 && bar.maxValue == 250 && bar.doubleValue == 41 && [[wait text].stringValue isEqualToString:@"QA another message"]) ? nil
             : [NSString stringWithFormat:@"maximum %d, value %g, message %@", wait.maxProgress, bar.doubleValue, [wait text].stringValue]);
        [wait close];
        QAWait *shown = [NSClassFromString(@"Wait") showWithString:@"QA shown" maxProgress:7 showCancel:YES];
        note(@"+[Wait showWithString:maxProgress:showCancel:] answers a panel on screen",
             (shown.window.isVisible && shown.maxProgress == 7 && ![shown abort].isHidden && [[shown text].stringValue isEqualToString:@"QA shown"]) ? nil
             : [NSString stringWithFormat:@"%@, visible %d, maximum %d", shown, shown.window.isVisible, shown.maxProgress]);
        [shown close];

        Class shell = NSClassFromString(@"N2Shell");
        note(@"+[N2Shell ip], +mac and +userId answer", ([[shell ip] isKindOfClass:[NSString class]] && [[shell mac] isKindOfClass:[NSString class]] && [shell userId] == (int)getuid())
             ? nil : [NSString stringWithFormat:@"%@ %@ %d", [shell ip], [shell mac], [shell userId]]);
        id date = [NSClassFromString(@"Horos") dateWithYear:2020 month:2 day:29 hour:13 minute:14 second:15 timeZone:[NSTimeZone timeZoneWithName:@"UTC"]];
        note(@"+[Horos dateWithYear:...] answers that date", ([date isKindOfClass:[NSDate class]] && fabs([date timeIntervalSince1970] - 1582982055.0) < 1) ? nil
             : [NSString stringWithFormat:@"%@", date]);

        note(@"-markedString, -urlEncodedString and -xmlUnescapedString answer as they did",
             ([[@"a\tb\n" markedString] isEqualToString:@"a\\tb\\n"] && [[@"a/b?c=d&e 100%" urlEncodedString] isEqualToString:@"a%2Fb%3Fc%3Dd%26e 100%"]
              && [[@"&lt;a&gt; &amp; &quot;b&quot;" xmlUnescapedString] isEqualToString:@"<a> & \"b\""]) ? nil
             : [NSString stringWithFormat:@"%@ | %@ | %@", [@"a\tb\n" markedString], [@"a/b?c=d&e 100%" urlEncodedString], [@"&lt;a&gt; &amp; &quot;b&quot;" xmlUnescapedString]]);
        note(@"+dateString: writes the date", [[NSString dateString:0] hasPrefix:@"le "] ? nil : [NSString dateString:0]);
        NSDictionary *nested = [NSDictionary dictionaryWithObjectsAndKeys:[NSArray arrayWithObject:[NSDictionary dictionaryWithObject:@"v" forKey:@"k"]], @"list", @"text", @"name", nil];
        NSMutableDictionary *deep = [nested deepMutableCopy];
        [[[deep objectForKey:@"list"] objectAtIndex:0] setObject:@"changed" forKey:@"k"];
        [[deep objectForKey:@"list"] addObject:@"more"];
        note(@"-deepMutableCopy answers mutable containers at every depth and leaves the original alone",
             ([[[[nested objectForKey:@"list"] objectAtIndex:0] objectForKey:@"k"] isEqualToString:@"v"] && [[deep objectForKey:@"list"] count] == 2) ? nil : @"the original changed");
        [deep release];   // the SDK's method answered an object its caller owns
        note(@"-objectForKey:ofClass: answers the object of that class", [nested objectForKey:@"name" ofClass:[NSString class]] == [nested objectForKey:@"name"] ? nil : @"another object");
        BOOL raised = NO;
        @try { [nested objectForKey:@"name" ofClass:[NSNumber class]]; } @catch (NSException *expected) { raised = YES; }
        note(@"-objectForKey:ofClass: raises for an object of another class", raised ? nil : @"did not raise");
        NSString *shared = @"shared";
        NSMutableDictionary *keyed = [NSMutableDictionary dictionaryWithObjectsAndKeys:shared, @"a", shared, @"b", @"other", @"c", nil];
        [keyed removeObject:shared];
        [keyed setBool:YES forKey:@"flag"];
        note(@"-removeObject: removes every key of the object and -setBool:forKey: writes a number",
             (keyed.count == 2 && [[keyed objectForKey:@"flag"] boolValue] && [keyed objectForKey:@"c"]) ? nil : [NSString stringWithFormat:@"%@", keyed]);
        NSBezierPath *rounded = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, 40, 20) cornerRadius:4];
        note(@"+bezierPathWithRoundedRect:cornerRadius: answers a path of that rectangle", (fabs(NSMinX([rounded bounds])) < 0.001 && fabs(NSMinY([rounded bounds])) < 0.001 && fabs(NSWidth([rounded bounds]) - 40) < 0.001
              && fabs(NSHeight([rounded bounds]) - 20) < 0.001) ? nil : NSStringFromRect([rounded bounds]));
        NSBitmapImageRep *bitmap = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:8 pixelsHigh:8 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
                                                                                 isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0] autorelease];
        memset([bitmap bitmapData], 0, [bitmap bytesPerRow] * 8);
        [bitmap bitmapData][3 * [bitmap bytesPerRow] + 3 * 4 + 3] = 10;
        [bitmap ATMask:200];
        // The copy keeps the receiver's number of samples, so it is made for a colour space with as many.
        NSBitmapImageRep *device = [bitmap repUsingColorSpaceName:NSDeviceRGBColorSpace];
        note(@"-ATMask:, -repUsingColorSpaceName: and -smoothen: answer",
             ([bitmap bitmapData][3 * [bitmap bytesPerRow] + 3 * 4 + 3] == 200 && [bitmap bitmapData][3] == 0 && device != bitmap && [device samplesPerPixel] == 4
              && [[device colorSpaceName] isEqualToString:NSDeviceRGBColorSpace]
              && [bitmap repUsingColorSpaceName:NSCalibratedRGBColorSpace] == bitmap && [bitmap smoothen:3] == bitmap) ? nil
             : [NSString stringWithFormat:@"alpha %d and %d, %ld samples", [bitmap bitmapData][3 * [bitmap bytesPerRow] + 15], [bitmap bitmapData][3], (long)[device samplesPerPixel]]);
        NSError *swizzleError = nil;
        BOOL swizzled = [QASwizzled jr_swizzleMethod:@selector(first) withMethod:@selector(second) error:&swizzleError];
        QASwizzled *object = [[[QASwizzled alloc] init] autorelease];
        BOOL refused = [QASwizzled jr_swizzleMethod:@selector(first) withMethod:NSSelectorFromString(@"qaNoSuchMethod") error:&swizzleError];
        note(@"+jr_swizzleMethod:withMethod:error: exchanges two methods and refuses one that is missing",
             (swizzled && [[object first] isEqualToString:@"second"] && [[object second] isEqualToString:@"first"] && !refused && swizzleError) ? nil
             : [NSString stringWithFormat:@"%d %@ %@ %d %@", swizzled, [object first], [object second], refused, swizzleError]);

        NSMutableArray *numbers = [NSMutableArray array];
        for (int i = 0; i < 64; i++) [numbers addObject:[NSNumber numberWithInt:i]];
        NSArray *before = [[numbers copy] autorelease];
        id answer = [numbers shuffle];
        note(@"-shuffle shuffles the array in place and answers it",
             (answer == numbers && ![numbers isEqualToArray:before] && [[NSSet setWithArray:numbers] isEqualToSet:[NSSet setWithArray:before]] && numbers.count == 64)
             ? nil : [NSString stringWithFormat:@"answered %p for %p, the order %@", answer, numbers, [numbers isEqualToArray:before] ? @"unchanged" : @"changed"]);
        NSArray *copy = [before shuffledArray];
        note(@"-shuffledArray answers a shuffled copy",
             (copy != before && copy.count == 64 && ![copy isEqualToArray:before] && [[NSSet setWithArray:copy] isEqualToSet:[NSSet setWithArray:before]])
             ? nil : [NSString stringWithFormat:@"%lu objects", (unsigned long)copy.count]);

        NSFileManager *files = [NSFileManager defaultManager];
        NSString *folder = [work stringByAppendingPathComponent:@"sized"];
        [files createDirectoryAtPath:[folder stringByAppendingPathComponent:@"inner"] withIntermediateDirectories:YES attributes:nil error:NULL];
        [[NSMutableData dataWithLength:12345] writeToFile:[folder stringByAppendingPathComponent:@"a"] atomically:YES];
        [[NSMutableData dataWithLength:700] writeToFile:[folder stringByAppendingPathComponent:@"inner/b"] atomically:YES];
        NSUInteger ofFile = [files sizeAtPath:[folder stringByAppendingPathComponent:@"a"]], ofFolder = [files sizeAtPath:folder];
        note(@"-sizeAtPath: sums the files", (ofFile == 12345 && ofFolder == 13045) ? nil
             : [NSString stringWithFormat:@"%lu for the file, %lu for the folder", (unsigned long)ofFile, (unsigned long)ofFolder]);
        NSString *support = [files findSystemFolderOfType:kApplicationSupportFolderType forDomain:kUserDomain];
        note(@"-findSystemFolderOfType:forDomain: answers the user's Application Support",
             [support hasSuffix:@"Library/Application Support"] ? nil : [NSString stringWithFormat:@"%@", support]);
        NSString *destination = [files destinationOfAliasAtPath:[folder stringByAppendingPathComponent:@"a"]];
        note(@"-destinationOfAliasAtPath: answers nil for a file that is no alias", destination ? destination : nil);

        NSUserDefaultsController *defaults = [NSUserDefaultsController sharedUserDefaultsController];
        [defaults setValue:@"qa value" forValuesKey:@"QALegacySelectorsKey"];
        note(@"-setValue:forValuesKey: and -valueForValuesKey: write and read the preference",
             [[defaults valueForValuesKey:@"QALegacySelectorsKey"] isEqual:@"qa value"]
             && [[[NSUserDefaults standardUserDefaults] stringForKey:@"QALegacySelectorsKey"] isEqual:@"qa value"] ? nil : @"the value did not come back");
        NSTextField *field = [[[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 100, 20)] autorelease];
        [field bind:@"value" toObject:defaults withValuesKey:@"QALegacySelectorsKey" options:nil];
        note(@"-bind:toObject:withValuesKey:options: binds to the preference", [field.stringValue isEqual:@"qa value"] ? nil : field.stringValue);
        [field unbind:@"value"];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"QALegacySelectorsKey"];
    } @catch (NSException *exception) {
        note(@"the checks", [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]);
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:NULL];
    [[NSJSONSerialization dataWithJSONObject:types options:NSJSONWritingSortedKeys error:NULL]
        writeToFile:[NSString stringWithUTF8String:getenv("QA_LEGACY_SELECTORS_TYPES")] atomically:YES];
    [json writeToFile:[NSString stringWithUTF8String:getenv("QA_LEGACY_SELECTORS_REPORT")] atomically:YES];
}

@end
'''


def build_plugin(folder):
    """QALegacySelectors.osirixplugin in `folder`, built as a plugin of the former SDK was."""
    bundle = folder / 'QALegacySelectors.osirixplugin'
    (bundle / 'Contents/MacOS').mkdir(parents=True)
    with open(bundle / 'Contents/Info.plist', 'wb') as handle:
        plistlib.dump({'CFBundleExecutable': 'QALegacySelectors', 'CFBundleIdentifier': 'qa.legacy.selectors',
                       'CFBundleName': 'QALegacySelectors', 'CFBundlePackageType': 'BNDL', 'CFBundleVersion': '1',
                       'NSPrincipalClass': 'QALegacySelectors', 'pluginType': 'Database',
                       'MenuTitles': ['QA Legacy Selectors']}, handle)
    source = folder / 'QALegacySelectors.m'
    source.write_text(PLUGIN)
    built = subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-bundle', '-undefined', 'dynamic_lookup', '-arch', 'arm64',
                            '-arch', 'x86_64', '-mmacosx-version-min=11.0', '-Wno-deprecated-declarations',
                            '-framework', 'Cocoa', '-framework', 'CoreServices', str(source),
                            '-o', str(bundle / 'Contents/MacOS/QALegacySelectors')], capture_output=True, text=True)
    if built.returncode:
        raise SystemExit('FAIL: the plugin does not build: ' + built.stderr[-2000:])
    subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], capture_output=True, check=True)
    return bundle


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--app', type=Path, default=native_app.DEVELOPMENT_APP)
    args = parser.parse_args()
    if shutil.which('xcrun') is None or not (args.app / 'Contents/MacOS/IsiX DICOM Viewer').is_file():
        print(f'skipped: needs xcrun and a development bundle (script/build_and_run.sh --verify): --app {args.app}',
              file=sys.stderr)
        return 2
    outdated = native_app.outdated_bundle(args.app)
    if outdated:
        print(f'skipped: {outdated}', file=sys.stderr)
        return 2
    if native_app.running_development_pids(args.app):
        print(f'skipped: a development instance of {args.app} is running', file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory(prefix='isix-legacy-selectors-') as folder:
        folder = Path(folder).resolve()
        bundle = build_plugin(folder)
        test_root, work, report, types = folder / 'root', folder / 'work', folder / 'report.json', folder / 'types.json'
        work.mkdir()
        selectors = folder / 'selectors.plist'
        with open(selectors, 'wb') as handle:
            plistlib.dump([[cls, kind, selector, system] for cls, kind, selector, system in SELECTORS], handle)
        log = folder / 'app.log'
        process = native_app.launch(test_root, log, ['--LoadPlugin', str(bundle)], app=args.app, environment={
            'QA_LEGACY_SELECTORS_REPORT': str(report), 'QA_LEGACY_SELECTORS_TYPES': str(types),
            'QA_LEGACY_SELECTORS_WORK': str(work),
            'QA_LEGACY_SELECTORS_LIST': str(selectors), 'QA_LEGACY_SELECTORS_DATABASE': str(test_root)})
        try:
            deadline = time.monotonic() + 180
            while not report.is_file() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.5)
            time.sleep(1)
        finally:
            native_app.stop(process)
        text = log.read_text(errors='replace')
        if not report.is_file():
            lines = [line for line in text.splitlines() if 'QALegacySelectors' in line or 'Plugin' in line
                     or 'unrecognized selector' in line or 'xception' in line]
            print('FAIL: the plugin wrote no report; the application said:\n  ' + '\n  '.join(lines[-12:])[-3000:])
            return 1
        found = json.loads(report.read_text())
        answered = json.loads(types.read_text()) if types.is_file() else {}
    failures = [f'{check}: {result}' for check, result in sorted(found.items()) if result != 'ok']
    expected = {f'{cls} {kind}{selector}' for cls, kind, selector, _ in SELECTORS}
    failures += [f'{check}: not checked' for check in sorted(expected - set(found))]
    compared = 0
    for key, declared in sorted(TYPES.items()):
        if declared is None or key not in answered:
            continue
        compared += 1
        if not answers_as_declared(key, without_offsets(answered[key]), declared):
            failures.append(f'{key}: answers with the types {without_offsets(answered[key])}, the SDK declared {declared}')
    if 'unrecognized selector' in text:
        failures.append('the application logged an unrecognized selector')
    for failure in failures:
        print('FAIL: ' + failure)
    if failures:
        return 1
    print(f'PASS: a plugin built as for Horos and OsiriX is answered by the {len(SELECTORS)} selectors it asks for, {compared} of '
          f'them with the argument and return types the SDK declared, and by the {len(found) - len(SELECTORS)} uses it makes of '
          f'them, on the main thread and on a background thread')
    return 0


if __name__ == '__main__':
    sys.exit(main())
