#!/usr/bin/env python3
"""A DCMPix does not show the file of another image as the image of its row.

An image's row of the database names its file by a number of the data folder.
In a database where a row came to name the file of another image - another
study's, another patient's - the viewer showed that image under the row's own
names. The row keeps the SOP Instance UID of its image and the file states its
own: the load of a DICOM file that states another UID than the row's is
refused, and the frame stays empty under the sentence of a frame that could
not be read.

The probe is linked with the DCMPix of this checkout's build and a stand-in
for the DICOM parser, which hands each file the attributes its case names, and
drives -CheckLoad:

- the row's own file is loaded, and a file whose UID is padded;
- the file of another image is refused: nothing of it is read into the object
  (no SOP class) nor written to the row (its size), it is not tried as
  another format, the frame is empty and says it could not be read, and its
  annotations are built without the file, as those of a file no format reads
  (the view draws the sentence with them); it is refused again after -revert,
  in a copy of the object, and in a frame that is a slice of a volume, which
  keeps the size the row recorded;
- what cannot be told apart is loaded: a row that keeps no UID, a row of no
  model class, a frame of a multi-frame object, an object without a row, a
  file that states no UID or one a row cannot keep as written;
- a file that is not DICOM never reaches the parser, whatever its row keeps.

It needs the Debug build of this checkout; without it the test reports itself
skipped (exit 2).
"""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import private_tmpdir  # noqa: E402,F401  - its own TMPDIR for the tools it runs
import roi_harness  # noqa: E402

SKIPPED = 2
APP_SWIFT = ('MissingPixelsReason',)

PROBE = r'''
#import <Cocoa/Cocoa.h>
#import <CoreData/CoreData.h>
#import <objc/runtime.h>
#import "DCMPix.h"
#import "ROI.h"
#import "IsiXDCMTKDictionary.h"

static NSString *gFolder = nil;
static NSMutableArray *gParses = nil;          // the files the parser was asked for, in order
static NSMutableDictionary *gParsed = nil;     // file name -> DCMObject
static NSMutableDictionary *gRows = nil;       // object ID -> row

// ---- What the application's helpers do, reduced to what the probe needs.
void _N2LogExceptionImpl( NSException *e, BOOL logStack, const char *pf) { NSLog( @"exception %@: %@", e.name, e.reason); }
void N2LogStackTrace( NSString *format, ...) { NSLog( @"stack trace: %@", format); }
void N2ManagedObjectContextPerformAndWait( NSManagedObjectContext *context, void (^block)(void)) { block(); }

@implementation NSFileManager (ProbeN2)
- (NSString*) tmpDirPath { return [gFolder stringByAppendingPathComponent: @"tmp"]; }
- (NSString*) confirmDirectoryAtPath:(NSString*) path { [self createDirectoryAtPath: path withIntermediateDirectories: YES attributes: nil error: nil]; return path; }
@end

// ---- The database rows: key-value objects. A row of no model class answers
// its keys and nothing else; an image's row answers the UID it keeps.
@interface ProbeRow : NSObject { @public NSMutableDictionary *values; }
+ (instancetype) row:(NSDictionary*) values;
@end
@implementation ProbeRow
+ (instancetype) row:(NSDictionary*) v { ProbeRow *r = [[[self alloc] init] autorelease]; r->values = [v mutableCopy]; return r; }
- (id) valueForUndefinedKey:(NSString*) key { id value = [values objectForKey: key]; return value == [NSNull null] ? nil : value; }
- (void) setValue:(id) value forUndefinedKey:(NSString*) key { [values setValue: value forKey: key]; }
- (void) setValuesForKeysWithDictionary:(NSDictionary*) d { [values addEntriesFromDictionary: d]; }
- (id) objectID { return [values objectForKey: @"objectID"]; }
- (NSManagedObjectContext*) managedObjectContext { return nil; }
- (id) series { return [self valueForUndefinedKey: @"series"]; }
- (id) study { return [self valueForUndefinedKey: @"study"]; }
@end

@interface ProbeImageRow : ProbeRow
@end
@implementation ProbeImageRow
- (NSString*) sopInstanceUID { return [self valueForUndefinedKey: @"uid"]; }
@end

// The probe's object IDs are strings, of no store: the database is the browser's.
@interface NSString (ProbeObjectID)
@end
@implementation NSString (ProbeObjectID)
- (id) persistentStore { return nil; }
@end

@interface ProbeContext : NSObject
@end
@implementation ProbeContext
- (NSArray*) executeFetchRequest:(NSFetchRequest*) request error:(NSError**) error { return @[]; }
- (id) existingObjectWithID:(id) objectID error:(NSError**) error { return [gRows objectForKey: objectID]; }
@end

@interface ProbeDatabase : NSObject
@end
@implementation ProbeDatabase
- (id) managedObjectContext { static ProbeContext *c = nil; if( c == nil) c = [[ProbeContext alloc] init]; return c; }
- (id) privateQueueIndependentDatabase { return self; }
- (BOOL) isLocal { return YES; }
- (void) performBlockAndWait:(void (^)(void)) block { block(); }
- (id) objectWithID:(id) objectID { return [gRows objectForKey: objectID]; }
- (BOOL) save:(NSError**) error { return YES; }
- (BOOL) save { return YES; }
@end

@implementation BrowserController
+ (id) currentBrowser { static BrowserController *b = nil; if( b == nil) b = [[BrowserController alloc] init]; return b; }
- (id) database { static ProbeDatabase *d = nil; if( d == nil) d = [[ProbeDatabase alloc] init]; return d; }
- (BOOL) isCurrentDatabaseBonjour { return NO; }
@end

// ---- The parsed DICOM objects: the dataset model DCMPix's Swift reads, made
// from the attributes each case names and handed out by file name.
static NSMutableDictionary *gTags = nil, *gNames = nil;
@implementation HorosDICOMDictionaries
+ (NSDictionary*) tagDictionary { return gTags; }
+ (NSDictionary*) tagForNameDictionary { return gNames; }
@end

static DCMAttribute *attr( NSString *name, int group, int element, NSString *vr, NSArray *values)
{
    if( gTags == nil) { gTags = [[NSMutableDictionary alloc] init]; gNames = [[NSMutableDictionary alloc] init]; }
    NSString *key = [NSString stringWithFormat: @"%04X,%04X", group, element];
    [gNames setObject: key forKey: name];
    [gTags setObject: @{@"Description": name, @"VR": vr, @"VM": @"1"} forKey: key];
    return [[[DCMAttribute alloc] initWithAttributeTag: [DCMAttributeTag tagWithTagString: key] vr: vr
                                                    values: [[values mutableCopy] autorelease]] autorelease];
}

@interface HorosDCMTKObject : NSObject <IsiXDCMReading>
@end
@implementation HorosDCMTKObject
+ (DCMObject*) objectWithContentsOfFile:(NSString*) path decodingPixelData:(BOOL) decode lastGroup:(unsigned short) lastGroup
{
    [gParses addObject: [path lastPathComponent]];
    return [gParsed objectForKey: [path lastPathComponent]];
}
+ (DCMObject*) objectWithData:(NSData*) data transferSyntax:(NSString*) syntax decodingPixelData:(BOOL) decode lastGroup:(unsigned short) lastGroup
{
    return nil;
}
@end

@implementation DicomFile
+ (BOOL) isDICOMFile:(NSString*) file { return [[file pathExtension] isEqualToString: @"dcm"]; }
+ (BOOL) isFVTiffFile:(NSString*) file { return NO; }
@end

// The object under test, which counts the times a file is tried as another
// format than DICOM, and the times its annotations are built with the parsed
// file and without it.
static int gOtherFormats = 0, gAnnotatedWithFile = 0, gAnnotatedWithoutFile = 0;
@interface DCMPix (ProbeLoading)
- (void) loadNonDICOMImage;
- (void) loadCustomImageAnnotationsPapyLink:(int) fileNb DCMLink:(DCMObject*) dcmObject;
@end
@interface ProbePix : DCMPix
@end
@implementation ProbePix
- (void) loadNonDICOMImage { gOtherFormats++; [super loadNonDICOMImage]; }
- (void) loadCustomImageAnnotationsPapyLink:(int) fileNb DCMLink:(DCMObject*) dcmObject
{
    if( dcmObject) gAnnotatedWithFile++; else gAnnotatedWithoutFile++;
    [super loadCustomImageAnnotationsPapyLink: fileNb DCMLink: dcmObject];
}
@end

// A CT image of 4 rows and 5 columns without Pixel Data that states `uid` (nil:
// none): loaded, it is an empty frame that says the object carries no image
// data, its SOP class is read and its size is written to its row.
static void file( NSString *name, NSString *uid)
{
    DCMObject *o = [[[DCMObject alloc] init] autorelease];
    [o setAttribute: attr( @"SOPClassUID", 0x8, 0x16, @"UI", @[@"1.2.840.10008.5.1.4.1.1.2"])];
    [o setAttribute: attr( @"Modality", 0x8, 0x60, @"CS", @[@"CT"])];
    [o setAttribute: attr( @"Rows", 0x28, 0x10, @"US", @[@4])];
    [o setAttribute: attr( @"Columns", 0x28, 0x11, @"US", @[@5])];
    if( uid) [o setAttribute: attr( @"SOPInstanceUID", 0x8, 0x18, @"UI", @[uid])];
    [gParsed setObject: o forKey: name];
}

static id imageRow( Class cls, NSString *identifier, id uid, int frames, NSString *fileType)
{
    ProbeRow *study = [ProbeRow row: @{@"dateOfBirth": [NSNull null], @"date": [NSNull null]}];
    ProbeRow *series = [ProbeRow row: @{@"study": study, @"modality": @"CT"}];
    ProbeRow *image = [cls row: @{@"series": series, @"objectID": identifier, @"uid": uid ?: [NSNull null], @"numberOfFrames": @(frames),
                                  @"fileType": fileType, @"height": @16, @"width": @32}];
    [gRows setObject: image forKey: identifier];
    return image;
}

static NSMutableDictionary *gRecords = nil;
static void record( NSString *name, DCMPix *pix, float *buffer)
{
    ProbeRow *row = [gRows objectForKey: [(NSObject*) pix valueForKey: @"imageObjectID"] ?: @""];
    [gParses removeAllObjects];
    gOtherFormats = gAnnotatedWithFile = gAnnotatedWithoutFile = 0;
    [pix CheckLoad];
    long w = [pix pwidth], h = [pix pheight], lit = 0;
    float *f = [pix fImage];
    for( long i = 0; f && i < w * h; i++) lit += f[ i] != 0;
    [gRecords setObject: @{@"refused": @([pix notAbleToLoadImage]), @"sentence": [pix missingPixelsReason] ?: @"",
                           @"sop class": [pix SOPClassUID] ?: @"", @"size": @[@(w), @(h)], @"lit": @(lit), @"frame": @(f != NULL),
                           @"in the volume": @(f != NULL && f == buffer), @"parsed": [[gParses copy] autorelease], @"other formats tried": @(gOtherFormats),
                           @"annotations built": @[@(gAnnotatedWithFile), @(gAnnotatedWithoutFile)], @"counted": @([pix isKindOfClass: [ProbePix class]]),
                           @"row size": row ? @[[row valueForKey: @"width"], [row valueForKey: @"height"]] : @[]} forKey: name];
}

static DCMPix *pixOf( NSString *fileName, id row, float *buffer)
{
    return [[[ProbePix alloc] initWithPath: [gFolder stringByAppendingPathComponent: fileName] :0 :1 :buffer :0 :0 isBonjour: NO imageObj: row] autorelease];
}

int main( int argc, const char *argv[])
{
    @autoreleasepool
    {
        if( argc > 1 && strcmp( argv[ 1], "--probe-link") == 0) return 0;
        [NSApplication sharedApplication];
        gFolder = [@(argv[ 1]) retain];
        gParses = [[NSMutableArray alloc] init];
        gParsed = [[NSMutableDictionary alloc] init];
        gRows = [[NSMutableDictionary alloc] init];
        gRecords = [[NSMutableDictionary alloc] init];
        Class image = [ProbeImageRow class];
        NSString *own = @"1.2.826.0.1.3680043.8.498.7000.1", *other = @"1.2.826.0.1.3680043.8.498.7000.2";

        file( @"own.dcm", own);
        file( @"padded.dcm", [own stringByAppendingString: @" "]);
        file( @"other.dcm", other);
        file( @"none.dcm", nil);
        file( @"letters.dcm", @"1.2.826.0.1.3680043.8.498.7000.A2");

        record( @"own file", pixOf( @"own.dcm", imageRow( image, @"row-1", own, 1, @"DICOM"), NULL), NULL);
        record( @"own file, padded", pixOf( @"padded.dcm", imageRow( image, @"row-2", own, 1, @"DICOM"), NULL), NULL);

        DCMPix *refused = pixOf( @"other.dcm", imageRow( image, @"row-3", own, 1, @"DICOM"), NULL);
        DCMPix *copy = [[refused copy] autorelease];
        record( @"file of another image", refused, NULL);
        [refused revert: NO];
        record( @"file of another image, reverted", refused, NULL);
        record( @"file of another image, a copy", copy, NULL);
        float *volume = calloc( 32 * 16, sizeof( float));
        for( int i = 0; i < 32 * 16; i++) volume[ i] = 7;
        record( @"file of another image, in a volume", pixOf( @"other.dcm", imageRow( image, @"row-4", own, 1, @"DICOM"), volume), volume);
        record( @"file of another image, row that counts no frame", pixOf( @"other.dcm", imageRow( image, @"row-5", own, 0, @"DICOM"), NULL), NULL);

        record( @"row without UID", pixOf( @"other.dcm", imageRow( image, @"row-6", nil, 1, @"DICOM"), NULL), NULL);
        record( @"row with an empty UID", pixOf( @"other.dcm", imageRow( image, @"row-7", @"", 1, @"DICOM"), NULL), NULL);
        record( @"row of no model class", pixOf( @"other.dcm", imageRow( [ProbeRow class], @"row-8", own, 1, @"DICOM"), NULL), NULL);
        record( @"multi-frame", pixOf( @"other.dcm", imageRow( image, @"row-9", own, 3, @"DICOM"), NULL), NULL);
        record( @"no row", pixOf( @"other.dcm", nil, NULL), NULL);
        record( @"file without UID", pixOf( @"none.dcm", imageRow( image, @"row-10", own, 1, @"DICOM"), NULL), NULL);
        record( @"file whose UID a row cannot keep", pixOf( @"letters.dcm", imageRow( image, @"row-11", own, 1, @"DICOM"), NULL), NULL);

        record( @"not DICOM", pixOf( @"picture.png", imageRow( image, @"row-12", own, 1, @"PNG"), NULL), NULL);

        NSData *json = [NSJSONSerialization dataWithJSONObject: gRecords options: NSJSONWritingSortedKeys error: nil];
        printf( "%s\n", [[[[NSString alloc] initWithData: json encoding: NSUTF8StringEncoding] autorelease] UTF8String]);
    }
    return 0;
}
'''

CT = '1.2.840.10008.5.1.4.1.1.2'
UNREADABLE = 'This image could not be read'
NO_PIXELS = 'This object carries no image data'
REFUSED = ('file of another image', 'file of another image, reverted', 'file of another image, a copy',
           'file of another image, in a volume', 'file of another image, row that counts no frame')
LOADED = {'own file': 'own.dcm', 'own file, padded': 'padded.dcm', 'row without UID': 'other.dcm', 'row with an empty UID': 'other.dcm',
          'row of no model class': 'other.dcm', 'multi-frame': 'other.dcm', 'no row': 'other.dcm', 'file without UID': 'none.dcm',
          'file whose UID a row cannot keep': 'letters.dcm'}


def png(path):
    """An 8 by 6 grey picture, written by the system's own encoder."""
    script = ('import AppKit\n'
              'let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 6, bitsPerSample: 8, samplesPerPixel: 1, '
              'hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite, bytesPerRow: 8, bitsPerPixel: 8)!\n'
              'for i in 0..<48 { rep.bitmapData![i] = UInt8(60 + i) }\n'
              'try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))\n')
    source = path.with_suffix('.swift')
    source.write_text(script)
    subprocess.run(['xcrun', 'swift', str(source), str(path)], check=True, capture_output=True, timeout=300)


def main():
    configuration = roi_harness.configuration()
    with tempfile.TemporaryDirectory(prefix='horos-recorded-instance-') as folder:
        folder = Path(folder)
        files = folder / 'files'
        files.mkdir()
        for name in ('own', 'padded', 'other', 'none', 'letters'):
            (files / f'{name}.dcm').write_bytes(b'\0' * 128 + b'DICM')
        png(files / 'picture.png')
        try:
            harness = roi_harness.build(roi_harness.WORKTREE, folder / 'harness', PROBE, config=configuration, app_swift=APP_SWIFT)
        except LookupError as error:
            print('skipped: %s' % error, file=sys.stderr)
            sys.exit(SKIPPED)
        done = subprocess.run([str(harness), str(files)], capture_output=True, text=True, timeout=120)
        if done.returncode:
            print('FAIL: the probe ended with %d:\n%s' % (done.returncode, done.stderr[-3000:]))
            sys.exit(1)
        records = json.loads(done.stdout.splitlines()[-1])
        log = done.stderr

    failures = []

    def expect(condition, name, what):
        if not condition:
            failures.append('%s: %s: %s' % (name, what, json.dumps(records.get(name), sort_keys=True)))

    for name in REFUSED:
        r = records[name]
        expect(r['refused'] and r['sentence'] == UNREADABLE, name, 'the frame says it could not be read')
        expect(r['sop class'] == '', name, 'nothing of the file is read into the object')
        expect(r['frame'] and r['lit'] == 0, name, 'the frame is there and empty')
        expect(r['parsed'] in ([], ['other.dcm']) and r['other formats tried'] == 0, name, 'the file is not tried as another format')
        expect(r['row size'] == [32, 16], name, 'nothing of the file is written to the row')
        # A copy is of the class itself, which the probe does not count.
        expect(r['annotations built'] == ([0, 1] if r['counted'] else [0, 0]), name,
               'the annotations are built without the file: the view draws the sentence with them')
    expect(records['file of another image']['parsed'] == ['other.dcm'], 'file of another image', 'the file is parsed, to read what it states')
    expect(records['file of another image, in a volume']['in the volume'] and records['file of another image, in a volume']['size'] == [32, 16],
           'file of another image, in a volume', 'the slice of the volume keeps the size its row recorded')
    for name, parsed in LOADED.items():
        r = records[name]
        expect(not r['refused'] and r['sentence'] == NO_PIXELS, name, 'the file is loaded: its frame says what the object lacks')
        expect(r['sop class'] == CT, name, 'the SOP class of the file is read')
        expect(r['parsed'] in ([], [parsed]) and r['other formats tried'] == 0, name, 'the file is read as DICOM')
        expect(r['size'] == [5, 4] and r['row size'] in ([5, 4], []), name, 'the size of the file is the frame\'s and its row\'s')
        expect(r['annotations built'] == [1, 0], name, 'the annotations are built with the file')
    r = records['not DICOM']
    expect(r['parsed'] == [] and r['other formats tried'] == 1, 'not DICOM', 'a file that is not DICOM never reaches the parser')
    expect(not r['refused'] and r['size'] == [8, 6] and r['lit'] > 0, 'not DICOM', 'the picture is loaded')
    if log.count('states another SOP Instance UID than the record that names it') != len(REFUSED):
        failures.append('each refusal is logged once, by the name of the file:\n%s' % log[-2000:])
    if '1.2.826.0.1.3680043.8.498.7000' in log:
        failures.append('the log names no UID:\n%s' % log[-2000:])

    for failure in failures:
        print('FAIL:', failure)
    if failures:
        print('the probe wrote:\n%s' % log[-2500:])
        sys.exit(1)
    print('PASS: the file of another image is refused (%d cases: loaded, reverted, copied, in a volume, a row that counts no frame) '
          'and its frame says it could not be read; %d cases that cannot be told apart are loaded; a file that is not DICOM '
          'never reaches the parser' % (len(REFUSED), len(LOADED)))


if __name__ == '__main__':
    main()
