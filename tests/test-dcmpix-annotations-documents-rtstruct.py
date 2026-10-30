#!/usr/bin/env python3
"""DCMPix's database links, custom annotations, encapsulated documents and RT STRUCT ROIs.

What this compares, between this checkout and the last revision of DCMPix.m that
did it in Objective-C, running the same probe against both:

* the database links: -imageObj, -seriesObj and -studyObj, and the size written
  back to an image's row;
* the custom annotations: the database fields read at -initWithPath:...imageObj:,
  the lines -loadCustomImageAnnotationsPapyLink:DCMLink: builds for a modality
  (its own template, the default one, "same as default"), DICOM fields of each
  kind (strings, DS, FD, FL, numbers, dates, times, date-times, several values,
  the repetition and echo times, the transfer syntax, the patient's name),
  database fields at the image, series and study levels, special and manual
  fields, -getDICOMFieldValueForGroup:element:DCMLink:, the annotation accessors
  and -reloadAnnotations;
* the encapsulated documents -CheckLoad reads: PDF (two pages), CDA, a
  structured report with its rendering already made and one without, and an
  object that is not an image;
* RT STRUCT: the ROIs -createROIsFromRTSTRUCT:inDatabase: makes of a structure
  set (closed, interpolated and point contours, contours referring to an image,
  to a frame of reference, unsupported, malformed, an oblique plane, slices of
  no thickness), as polygons and as brushes, and what it writes and adds to the
  database; the errors it logs; the refusal for a Bonjour database.

The parsed DICOM objects, the database and the browser are stand-ins the probe
defines; the ROI, its points and the DCMPix Swift the revision already calls are
the application's. Records are compared field by field, floating point as
hexadecimal; log lines without their time stamps.

    python3 tests/test-dcmpix-annotations-documents-rtstruct.py [REFERENCE_REVISION]

Once DCMPix itself is Swift, no revision of DCMPix.m links with this checkout's
Swift: the reference is then what the probe answered against the last
Objective-C class, kept for each configuration in
tests/fixtures/dcmpix-annotations-documents-rtstruct-records.json (HOROS_RECORD_GOLDEN=1 on a checkout
of that class writes them).

HOROS_TEST_CONFIGURATION=Release compares the Release builds.
"""
from pathlib import Path
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import roi_harness  # noqa: E402
from history_reference import before_text_removed, show  # noqa: E402

PIX = 'Horos/Sources/DCMPix.m'
# The records of the last Objective-C class, in tests/fixtures.
GOLDEN = 'dcmpix-annotations-documents-rtstruct'
# What DCMPix.m defines while it still makes the RT STRUCT ROIs itself.
OBJC_MARKER = '- (void)createROIsFromRTSTRUCT: (NSDictionary*)dict inDatabase: (DicomDatabase*) database'
# The Swift extensions of DCMPix that took these parts out of DCMPix.m.
MOVED = ('DCMPix+Database', 'DCMPix+Annotations', 'DCMPix+EncapsulatedDocuments', 'DCMPix+RTStruct')
# Application Swift both harnesses link, so that neither runs a stand-in where
# the other runs the class.
APP_SWIFT = ('MissingPixelsReason',)
SKIPPED = 2
configuration = roi_harness.configuration()


def pdf(path, pages):
    """A PDF of `pages` pages, each a filled rectangle of its own grey."""
    objects = ['<< /Type /Catalog /Pages 2 0 R >>',
               '<< /Type /Pages /Kids [%s] /Count %d >>' % (' '.join('%d 0 R' % (3 + 2 * i) for i in range(pages)), pages)]
    for i in range(pages):
        content = '%.2f g 4 4 %d %d re f' % (0.2 + 0.3 * i, 40 - 8 * i, 28 - 4 * i)
        objects.append('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 48 36] /Contents %d 0 R >>' % (4 + 2 * i))
        objects.append('<< /Length %d >>\nstream\n%s\nendstream' % (len(content), content))
    out, offsets = '%PDF-1.4\n', []
    for number, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += '%d 0 obj\n%s\nendobj\n' % (number, body)
    xref = len(out)
    out += 'xref\n0 %d\n0000000000 65535 f \n' % (len(objects) + 1) + ''.join('%010d 00000 n \n' % o for o in offsets)
    out += 'trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' % (len(objects) + 1, xref)
    path.write_bytes(out.encode('latin1'))


def fixtures(folder):
    """The files the probe opens: their content is the stand-in parser's (keyed by name)."""
    for name in ('image', 'pdf', 'cda', 'sr-rendered', 'sr-missing', 'nonimage', 'struct', 'ct1', 'ct2', 'ct3', 'ct4', 'obl'):
        (folder / f'{name}.dcm').write_bytes(b'\0' * 128 + b'DICM')
    pdf(folder / 'document.pdf', 2)
    tmp = folder / 'tmp' / 'dicomsr_osirix'
    tmp.mkdir(parents=True)
    (tmp / 'sr-rendered.dcm.xml').write_text('<report/>')
    pdf(tmp / 'sr-rendered.dcm.xml.pdf', 1)


PROBE = r'''
#import <Cocoa/Cocoa.h>
#import <CoreData/CoreData.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "DCMPix.h"
#import "ROI.h"
#import "MyPoint.h"

#include <dlfcn.h>

// The size written back to an image's row: +[DCMPix storeSize:inDatabaseForImageID:]
// where the revision has it, else the C function of DCMPix.m before it.
static void storeSizeByFunction( id cls, SEL selector, NSDictionary *size, id imageID)
{
    ((void (*)(id, id)) dlsym( RTLD_DEFAULT, "HorosDCMPixStoreSizeInDatabase"))( imageID, size);
}

// A revision with the C function gets the class method too: the reader Swift
// linked into both harnesses, the worktree's, calls the class method.
static void provideStoreSize( void)
{
    SEL selector = NSSelectorFromString( @"storeSize:inDatabaseForImageID:");
    if( ![DCMPix respondsToSelector: selector])
        class_addMethod( object_getClass( [DCMPix class]), selector, (IMP) storeSizeByFunction, "v@:@@");
}

static void storeSize( id imageID, NSDictionary *size)
{
    SEL selector = NSSelectorFromString( @"storeSize:inDatabaseForImageID:");
    ((void (*)(id, SEL, id, id)) objc_msgSend)( [DCMPix class], selector, size, imageID);
}

static NSString *gFolder = nil;
static NSMutableArray *gEvents = nil;    // what the stand-ins were asked to do, in order
static BOOL gBonjour = NO;

static void event( NSString *what, id detail) { [gEvents addObject: @[what, detail ?: [NSNull null]]]; }

// ---- What the application's helpers do, reduced to what the probe needs.
void _N2LogExceptionImpl( NSException *e, BOOL logStack, const char *pf) { NSLog( @"exception %@: %@", e.name, e.reason); }
void N2LogStackTrace( NSString *format, ...) { NSLog( @"stack trace: %@", format); }
void N2ManagedObjectContextPerformAndWait( NSManagedObjectContext *context, void (^block)(void)) { block(); }

// The thread accessors of NSThread+N2, recorded. Installed over whatever
// NSThread has: the Swift NSThread+N2 is linked when a Swift caller pulls it in.
@implementation NSThread (ProbeN2)
- (CGFloat) probe_progress { return [objc_getAssociatedObject( self, "progress") doubleValue]; }
- (void) probe_setProgress:(CGFloat) p { objc_setAssociatedObject( self, "progress", @(p), OBJC_ASSOCIATION_RETAIN); event( @"progress", [NSString stringWithFormat: @"%a", (double) p]); }
- (NSString*) probe_status { return nil; }
- (void) probe_setStatus:(NSString*) s { event( @"status", s); }
- (BOOL) probe_supportsCancel { return NO; }
- (void) probe_setSupportsCancel:(BOOL) s { }
@end

static void installThreadAccessors( void)
{
    for( NSString *name in @[@"progress", @"setProgress:", @"status", @"setStatus:", @"supportsCancel", @"setSupportsCancel:"])
    {
        Method probe = class_getInstanceMethod( [NSThread class], NSSelectorFromString( [@"probe_" stringByAppendingString: name]));
        class_replaceMethod( [NSThread class], NSSelectorFromString( name), method_getImplementation( probe), method_getTypeEncoding( probe));
    }
}

@implementation NSFileManager (ProbeN2)
- (NSString*) tmpDirPath { return [gFolder stringByAppendingPathComponent: @"tmp"]; }
- (NSString*) confirmDirectoryAtPath:(NSString*) path { [self createDirectoryAtPath: path withIntermediateDirectories: YES attributes: nil error: nil]; return path; }
@end

@implementation NSUserDefaults (ProbeOsiriX)
+ (NSDateFormatter*) dateFormatter
{
    NSDateFormatter *f = [[[NSDateFormatter alloc] init] autorelease];
    f.dateFormat = @"yyyy-MM-dd"; f.timeZone = [NSTimeZone timeZoneForSecondsFromGMT: 0];
    return f;
}
@end

// ---- Key-value objects: the database rows. A key they do not hold raises, as Core Data does.
@interface ProbeRow : NSObject <NSFetchRequestResult> { @public NSMutableDictionary *values; }
+ (instancetype) row:(NSDictionary*) values;
@end
@implementation ProbeRow
+ (instancetype) row:(NSDictionary*) v { ProbeRow *r = [[[self alloc] init] autorelease]; r->values = [v mutableCopy]; return r; }
- (id) valueForUndefinedKey:(NSString*) key
{
    id value = [values objectForKey: key];
    if( value == nil) return [super valueForUndefinedKey: key];
    return value == [NSNull null] ? nil : value;
}
- (void) setValue:(id) value forUndefinedKey:(NSString*) key { event( [@"set " stringByAppendingString: key], value); [values setValue: value forKey: key]; }
- (void) setValuesForKeysWithDictionary:(NSDictionary*) d
{
    if( [[d objectForKey: @"width"] intValue] == 999) [NSException raise: @"ProbeRow" format: @"cannot store %@", d];
    event( @"store size", d);
}
- (id) objectID { return [values objectForKey: @"objectID"] ?: self; }
- (NSManagedObjectContext*) managedObjectContext { return nil; }
- (NSURL*) URIRepresentation { return [NSURL URLWithString: [@"x-coredata://probe/" stringByAppendingString: [values objectForKey: @"tag"] ?: @"row"]]; }
- (id) series { return [self valueForUndefinedKey: @"series"]; }
- (id) study { return [self valueForUndefinedKey: @"study"]; }
- (NSString*) completePath { return [self valueForUndefinedKey: @"path"]; }
- (NSString*) roiPathForImage:(id) image inArray:(NSArray*) array { return [self valueForUndefinedKey: @"roiPath"]; }
- (NSString*) description { return [NSString stringWithFormat: @"row %@", [values objectForKey: @"tag"]]; }
@end

static NSMutableDictionary *gRows = nil;    // object ID -> row

@interface ProbeContext : NSObject
@end
@implementation ProbeContext
- (NSArray*) executeFetchRequest:(NSFetchRequest*) request error:(NSError**) error
{
    event( @"fetch", [NSString stringWithFormat: @"%@ %@", request.entityName, request.predicate]);
    NSMutableArray *found = [NSMutableArray array];
    for( ProbeRow *row in [gRows objectForKey: @"fetch"])
        if( [request.predicate evaluateWithObject: row]) [found addObject: row];
    return found;
}
- (id) existingObjectWithID:(id) objectID error:(NSError**) error { return [gRows objectForKey: objectID]; }
@end

// The database: a class of its own (DicomDatabase's superclass is not linked), messaged as one.
@interface ProbeDatabase : NSObject
@end
@implementation ProbeDatabase
- (id) managedObjectContext { static ProbeContext *c = nil; if( c == nil) c = [[ProbeContext alloc] init]; return c; }
- (id) privateQueueIndependentDatabase { return self; }
- (void) performBlockAndWait:(void (^)(void)) block { event( @"perform", nil); block(); }
- (id) objectWithID:(id) objectID { return [gRows objectForKey: objectID]; }
- (BOOL) save:(NSError**) error { event( @"save", nil); return YES; }
- (BOOL) save { return [self save: nil]; }    // as N2ManagedDatabase
- (NSString*) uniquePathForNewDataFileWithExtension:(NSString*) ext { static int n = 0; return [gFolder stringByAppendingPathComponent: [NSString stringWithFormat: @"new-%d.%@", ++n, ext]]; }
- (NSArray*) addFilesAtPaths:(NSArray*) paths postNotifications:(BOOL) p dicomOnly:(BOOL) d rereadExistingItems:(BOOL) r generatedByOsiriX:(BOOL) g
{
    NSMutableArray *names = [NSMutableArray array];
    for( NSString *path in paths) [names addObject: [path lastPathComponent]];
    event( @"add files", @[names, @(p), @(d), @(r), @(g)]);
    return @[];
}
@end

// The classes below are declared by the application's headers, which the
// probe sees; it implements what DCMPix asks of them.
@implementation BrowserController
+ (id) currentBrowser { static BrowserController *b = nil; if( b == nil) b = [[BrowserController alloc] init]; return b; }
- (id) database { static ProbeDatabase *d = nil; if( d == nil) d = [[ProbeDatabase alloc] init]; return d; }
- (BOOL) isCurrentDatabaseBonjour { return gBonjour; }
+ (NSString*) TimeWithSecondsFormat:(NSDate*) t { return [NSString stringWithFormat: @"time %.0f", t.timeIntervalSince1970]; }
+ (NSString*) DateTimeWithSecondsFormat:(NSDate*) t { return [NSString stringWithFormat: @"datetime %.0f", t.timeIntervalSince1970]; }
+ (NSString*) compressionString:(NSString*) s { return [NSString stringWithFormat: @"syntax(%@)", s]; }
// The selector the Swift browser answers it under.
+ (NSString*) horos_compressionString:(NSString*) s { return [self compressionString: s]; }
@end


static NSString *hexf( double v) { return [NSString stringWithFormat: @"%a", v]; }

static id describe( id value)
{
    if( value == nil) return @"<nil>";
    if( value == [NSNull null]) return @"<null>";
    if( [value isKindOfClass: [NSString class]]) return value;
    if( [value isKindOfClass: [NSNumber class]]) return [NSString stringWithFormat: @"%s:%@", [value objCType], value];
    if( [value isKindOfClass: [NSDate class]]) return [NSString stringWithFormat: @"date %a", [value timeIntervalSince1970]];
    if( [value isKindOfClass: [NSArray class]]) { NSMutableArray *a = [NSMutableArray array]; for( id v in value) [a addObject: describe( v)]; return a; }
    if( [value isKindOfClass: [NSDictionary class]])
    {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for( id key in value) [d setObject: describe( [value objectForKey: key]) forKey: [key description]];
        return d;
    }
    return [NSString stringWithFormat: @"%@ %@", NSStringFromClass( [value class]), value];
}

static NSDictionary *describeROI( ROI *roi)
{
    NSMutableArray *points = [NSMutableArray array];
    for( MyPoint *p in roi.points) [points addObject: @[hexf( p.x), hexf( p.y)]];
    RGBColor c = roi.rgbcolor;
    NSRect r = roi.rect;
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary: @{
        @"name": roi.name ?: @"<nil>", @"type": @(roi.type), @"color": @[@(c.red), @(c.green), @(c.blue)],
        @"points": points, @"rect": @[hexf( r.origin.x), hexf( r.origin.y), hexf( r.size.width), hexf( r.size.height)],
        @"opacity": hexf( roi.opacity), @"thickness": hexf( roi.thickness), @"spline": @(roi.isSpline),
        @"spacing": @[hexf( roi.pixelSpacingX), hexf( roi.pixelSpacingY)],
        @"origin": @[hexf( roi.imageOrigin.x), hexf( roi.imageOrigin.y)]}];
    if( roi.textureBuffer)
    {
        unsigned long long hash = 1469598103934665603ULL;
        for( long i = 0; i < (long) roi.textureWidth * roi.textureHeight; i++) { hash ^= roi.textureBuffer[ i]; hash *= 1099511628211ULL; }
        [d setObject: @[@(roi.textureWidth), @(roi.textureHeight), @(roi.textureUpLeftCornerX), @(roi.textureUpLeftCornerY),
                        [NSString stringWithFormat: @"%016llx", hash]] forKey: @"texture"];
    }
    return d;
}

@implementation SRAnnotation
+ (NSData*) roiFromDICOM:(NSString*) path { event( @"read rois", [path lastPathComponent]); return nil; }
+ (NSString*) archiveROIsAsDICOM:(NSArray*) rois toPath:(NSString*) path forImage:(id) image
{
    NSMutableArray *list = [NSMutableArray array];
    for( ROI *roi in rois) [list addObject: describeROI( roi)];
    event( @"archive", @{@"path": [path lastPathComponent], @"image": [image description], @"rois": list});
    return path;
}
@end

// ---- The parsed DICOM objects: the dataset model of the IsiXDICOMDataset
// module, the one DCMPix's Swift reads, with the tags of IsiXDICOMFile. The
// probe makes them from the attributes each case names; the reader below hands
// them out by file name.

// The tags look their names up in the host's DCMTK dictionaries, found by name
// (HorosDICOMDictionaries). The probe's are filled as the cases name their
// attributes: a name the case gives a tag keeps that tag, and one it gives
// none takes a private tag of its own, so that the model finds every
// attribute by its name and by its tag.
static NSMutableDictionary *gTags = nil, *gNames = nil;
@implementation HorosDICOMDictionaries
+ (NSDictionary*) tagDictionary { return gTags; }
+ (NSDictionary*) tagForNameDictionary { return gNames; }
@end

static IsiXDICOMAttributeTag *tagFor( NSString *name, int group, int element, NSString *vr)
{
    if( gTags == nil) { gTags = [[NSMutableDictionary alloc] init]; gNames = [[NSMutableDictionary alloc] init]; }
    NSString *key = [gNames objectForKey: name];
    if( key == nil)
    {
        key = (group || element) ? [NSString stringWithFormat: @"%04X,%04X", group, element]
                                 : [NSString stringWithFormat: @"7FF1,%04X", (int) gNames.count + 0x1000];
        [gNames setObject: key forKey: name];
        [gTags setObject: @{@"Description": name, @"VR": vr, @"VM": @"1"} forKey: key];
    }
    return [IsiXDICOMAttributeTag tagWithTagString: key];
}

static NSMutableDictionary *gParsed = nil;     // file name -> DCMObject
@interface HorosDCMTKObject : NSObject <IsiXDCMReading>
@end
@implementation HorosDCMTKObject
+ (IsiXDCMObject*) objectWithContentsOfFile:(NSString*) path decodingPixelData:(BOOL) decode lastGroup:(unsigned short) lastGroup
{
    event( @"parse", [path lastPathComponent]);
    return [gParsed objectForKey: [path lastPathComponent]];
}
+ (IsiXDCMObject*) objectWithData:(NSData*) data transferSyntax:(NSString*) syntax decodingPixelData:(BOOL) decode lastGroup:(unsigned short) lastGroup
{
    return nil;
}
@end

@implementation DicomFile
+ (BOOL) isDICOMFile:(NSString*) file { return YES; }
@end

@implementation DCMAbstractSyntaxUID
+ (NSString*) pdfStorageClassUID { return @"1.2.840.10008.5.1.4.1.1.104.1"; }
+ (NSString*) EncapsulatedCDAStorage { return @"1.2.840.10008.5.1.4.1.1.104.2"; }
+ (BOOL) isNonImageStorage:(NSString*) uid { return [uid hasPrefix: @"1.2.840.10008.5.1.4.1.1.481"] || [uid isEqualToString: @"1.2.840.10008.5.1.4.1.1.4.2"]; }
@end

// An attribute: a name, a tag, a value representation and its values.
static IsiXDCMAttribute *attr( NSString *name, int group, int element, NSString *vr, NSArray *values)
{
    return [[[IsiXDCMAttribute alloc] initWithAttributeTag: tagFor( name, group, element, vr) vr: vr
                                                    values: [[values mutableCopy] autorelease]] autorelease];
}
static IsiXDCMSequenceAttribute *seq( NSString *name, NSArray *items)
{
    IsiXDCMSequenceAttribute *a = [[[IsiXDCMSequenceAttribute alloc] initWithAttributeTag: tagFor( name, 0, 0, @"SQ") vr: @"SQ"
                                                                                  values: [[items mutableCopy] autorelease]] autorelease];
    for( id item in items) [a addItem: item];
    return a;
}
static IsiXDCMObject *object( NSArray *attributes)
{
    IsiXDCMObject *o = [[[IsiXDCMObject alloc] init] autorelease];
    for( IsiXDCMAttribute *a in attributes) [o setAttribute: a];
    return o;
}
static IsiXDCMAttribute *named( NSString *name, id value) { return attr( name, 0, 0, @"LO", value ? ([value isKindOfClass: [NSArray class]] ? value : @[value]) : @[]); }

// ---- Cases.
static NSMutableArray *gRecords = nil;
static void begin( NSString *name) { fprintf( stderr, "@@CASE %s\n", name.UTF8String); [gEvents removeAllObjects]; }
static void record( NSString *name, NSDictionary *values)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary: values];
    [d setObject: name forKey: @"name"];
    [d setObject: describe( [[gEvents copy] autorelease]) forKey: @"events"];
    [gRecords addObject: d];
}

static NSDate *day( double days) { return [NSDate dateWithTimeIntervalSince1970: days * 86400]; }

static NSDictionary *templates( void)
{
    NSDictionary *dicom = ^{ return @{}; }();
    (void) dicom;
    NSArray *(^line)(NSArray *) = ^NSArray *(NSArray *fields) { return @[@{@"fullContent": fields}]; };
    NSDictionary *(^D)(int, int) = ^NSDictionary *(int g, int e) { return @{@"type": @"DICOM", @"group": @(g), @"element": @(e)}; };
    NSDictionary *(^DB)(NSString *, NSString *) = ^NSDictionary *(NSString *f, NSString *l) { return @{@"type": @"DB", @"field": f, @"level": l}; };
    NSDictionary *(^S)(NSString *) = ^NSDictionary *(NSString *f) { return @{@"type": @"Special", @"field": f}; };
    NSDictionary *(^M)(NSString *) = ^NSDictionary *(NSString *f) { return f ? @{@"type": @"Manual", @"field": f} : @{@"type": @"Manual"}; };
    NSArray *topLeft = [[[line( @[M( @"Name:"), D( 0x10, 0x10)]) arrayByAddingObjectsFromArray: line( @[DB( @"name", @"study"), DB( @"patientID", @"study")])]
                        arrayByAddingObjectsFromArray: line( @[M( @"TR"), D( 0x18, 0x80), M( @"TE"), D( 0x18, 0x81)])]
                        arrayByAddingObjectsFromArray: line( @[M( @"Only a label"), D( 0x99, 0x99)])];
    NSArray *topRight = [[[[line( @[DB( @"date", @"study"), DB( @"dateOfBirth", @"study")]) arrayByAddingObjectsFromArray: line( @[DB( @"seriesDescription", @"series"), DB( @"instanceNumber", @"image")])]
                         arrayByAddingObjectsFromArray: line( @[DB( @"missingField", @"image"), DB( @"emptyText", @"series"), DB( @"nothing", @"study")])]
                         arrayByAddingObjectsFromArray: line( @[S( @"Patient's Actual Age"), S( @"Patient's Age At Acquisition"), S( @"Something else"), S( @"")])]
                         arrayByAddingObjectsFromArray: line( @[M( @""), M( nil), M( @"kept")])];
    NSArray *lowerLeft = [[[line( @[D( 0x28, 0x30), D( 0x18, 0x50), D( 0x18, 0x9087), D( 0x18, 0x1316)]) arrayByAddingObjectsFromArray: line( @[D( 0x28, 0x10), D( 0x8, 0x20), D( 0x8, 0x30), D( 0x8, 0x2a)])]
                         arrayByAddingObjectsFromArray: line( @[D( 0x2, 0x10), D( 0x8, 0x60)])]
                         arrayByAddingObjectsFromArray: line( @[@{@"type": @"Other"}, D( 0x8, 0x103e)])];
    NSDictionary *ct = @{@"TopLeft": topLeft, @"TopRight": topRight, @"LowerLeft": lowerLeft, @"LowerRight": @[], @"sameAsDefault": @0};
    NSDictionary *def = @{@"TopLeft": line( @[M( @"Default"), D( 0x10, 0x10), DB( @"name", @"study")]),
                          @"MiddleLeft": [line( @[D( 0x18, 0x80), D( 0x18, 0x81)]) arrayByAddingObjectsFromArray: line( @[S( @"Patient's Age At Acquisition")])],
                          @"sameAsDefault": @0};
    NSDictionary *mr = @{@"TopLeft": line( @[M( @"MR only")]), @"sameAsDefault": @1};
    NSDictionary *bad = @{@"TopLeft": @[@{@"fullContent": @[@"not a field"]}, @"not a line"], @"TopRight": @"not a list", @"sameAsDefault": @0};
    return @{@"CT": ct, @"MR": mr, @"Default": def, @"OT": bad};
}

static IsiXDCMObject *annotatedObject( void)
{
    return object( @[
        attr( @"PatientsName", 0x10, 0x10, @"PN", @[@"DOE^JANE"]),
        attr( @"RepetitionTime", 0x18, 0x80, @"DS", @[@"2500.123456"]),
        attr( @"EchoTime", 0x18, 0x81, @"DS", @[@"12.5"]),
        attr( @"PixelSpacing", 0x28, 0x30, @"DS", @[@"0.703125", @"0.70312499"]),
        attr( @"SliceThickness", 0x18, 0x50, @"DS", @[@"5.00000001"]),
        attr( @"ImagingFrequency", 0x18, 0x9087, @"FD", @[@(63.8945678)]),
        attr( @"SAR", 0x18, 0x1316, @"FL", @[@(0.123456789f)]),
        attr( @"Rows", 0x28, 0x10, @"US", @[@512]),
        attr( @"StudyDate", 0x8, 0x20, @"DA", @[day( 18000), day( 18001)]),
        attr( @"StudyTime", 0x8, 0x30, @"TM", @[[NSDate dateWithTimeIntervalSince1970: 3723]]),
        attr( @"AcquisitionDateTime", 0x8, 0x2a, @"DT", @[[NSDate dateWithTimeIntervalSince1970: 1555555555]]),
        attr( @"TransferSyntaxUID", 0x2, 0x10, @"UI", @[@"1.2.840.10008.1.2.4.70"]),
        attr( @"Modality", 0x8, 0x60, @"CS", @[@""]),
        attr( @"SeriesDescription", 0x8, 0x103e, @"LO", @[[NSData data]]),
    ]);
}

static ProbeRow *annotatedRow( NSString *modality, BOOL born)
{
    ProbeRow *study = [ProbeRow row: @{@"name": born ? @"DOE^JANE" : [NSNull null], @"patientID": @"P-17", @"date": day( 18000), @"emptyText": @"",
                                        @"dateOfBirth": born ? day( 4000) : [NSNull null], @"yearOld": @"38 y", @"yearOldAcquisition": @"37 y",
                                        @"nothing": [NSNull null], @"tag": @"study"}];
    ProbeRow *series = [ProbeRow row: @{@"modality": modality, @"study": study, @"seriesDescription": @"AXIAL", @"emptyText": @"",
                                         @"id": @3, @"tag": @"series"}];
    return [ProbeRow row: @{@"series": series, @"fileType": @"DICOM", @"numberOfFrames": @1, @"height": @0, @"width": @0,
                             @"instanceNumber": @7, @"objectID": @"image-id", @"tag": @"image"}];
}

// The templates come from the preferences: +checkUserDefaults: reads them again
// whenever a DCMPix is made after a reset.
static void useTemplates( NSDictionary *templates)
{
    [[NSUserDefaults standardUserDefaults] registerDefaults: @{@"CUSTOM_IMAGE_ANNOTATIONS": templates}];
    [DCMPix checkUserDefaults: YES];
}

static NSDictionary *annotationState( id pix)
{
    return @{@"annotations": describe( [pix annotationsDictionary]), @"databaseFields": describe( [pix annotationsDBFields]),
             @"yearOld": describe( [pix yearOld]), @"yearOldAcquisition": describe( [pix yearOldAcquisition]),
             @"modality": describe( [pix modalityString])};
}

static void annotations( void)
{
    useTemplates( templates());
    NSString *file = [gFolder stringByAppendingPathComponent: @"image.dcm"];
    for( NSString *modality in @[@"CT", @"MR", @"US", @"OT"])
        for( NSNumber *born in @[@YES, @NO])
        {
            NSString *name = [NSString stringWithFormat: @"annotations-%@%@", modality, born.boolValue ? @"" : @"-unborn"];
            begin( name);
            ProbeRow *row = annotatedRow( modality, born.boolValue);
            id pix = [[[DCMPix alloc] initWithPath: file :0 :1 :nil :0 :0 isBonjour: NO imageObj: (id) row] autorelease];
            NSMutableDictionary *state = [NSMutableDictionary dictionaryWithDictionary: @{@"after init": annotationState( pix)}];
            if( [modality isEqualToString: @"MR"])
            {
                [pix setValue: @"3000" forKey: @"repetitiontime"];
                [pix setValue: @"0" forKey: @"echotime"];
            }
            [pix loadCustomImageAnnotationsPapyLink: -1 DCMLink: annotatedObject()];
            [state setObject: annotationState( pix) forKey: @"with the object"];
            [pix reloadAnnotations];
            [state setObject: annotationState( pix) forKey: @"reloaded"];
            [pix loadCustomImageAnnotationsPapyLink: -1 DCMLink: nil];
            [state setObject: annotationState( pix) forKey: @"without an object"];
            [pix loadCustomImageAnnotationsDBFields: (id) row];
            [state setObject: annotationState( pix) forKey: @"database fields again"];
            record( name, state);
        }

    begin( @"annotations-raising-row");
    {
        ProbeRow *row = annotatedRow( @"CT", YES);
        [row->values setObject: @"not a row" forKey: @"series"];
        id pix = [[[DCMPix alloc] initWithPath: file :0 :1 :nil :0 :0 isBonjour: NO imageObj: (id) row] autorelease];
        record( @"annotations-raising-row", annotationState( pix));
    }

    begin( @"annotations-no-templates");
    {
        useTemplates( @{});
        id pix = [[[DCMPix alloc] initWithPath: file :0 :1 :nil :0 :0 isBonjour: NO imageObj: (id) annotatedRow( @"CT", YES)] autorelease];
        [pix loadCustomImageAnnotationsPapyLink: -1 DCMLink: annotatedObject()];
        record( @"annotations-no-templates", annotationState( pix));
        useTemplates( templates());
    }

    begin( @"field-values");
    {
        id pix = [[[DCMPix alloc] initWithPath: file :0 :1 :nil :0 :0 isBonjour: NO imageObj: nil] autorelease];
        IsiXDCMObject *o = annotatedObject();
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        int tags[][2] = {{0x10, 0x10}, {0x18, 0x80}, {0x28, 0x30}, {0x18, 0x9087}, {0x18, 0x1316}, {0x28, 0x10}, {0x8, 0x20},
                         {0x8, 0x30}, {0x8, 0x2a}, {0x2, 0x10}, {0x8, 0x60}, {0x8, 0x103e}, {0x99, 0x99}};
        for( int i = 0; i < sizeof( tags) / sizeof( tags[ 0]); i++)
            [values setObject: describe( [pix getDICOMFieldValueForGroup: tags[ i][ 0] element: tags[ i][ 1] DCMLink: o])
                       forKey: [NSString stringWithFormat: @"%04x,%04x", tags[ i][ 0], tags[ i][ 1]]];
        [values setObject: describe( [pix getDICOMFieldValueForGroup: 0x10 element: 0x10 DCMLink: nil]) forKey: @"no object"];
        record( @"field-values", values);
    }

    begin( @"annotation-accessors");
    {
        id pix = [[[DCMPix alloc] initWithPath: file :0 :1 :nil :0 :0 isBonjour: NO imageObj: nil] autorelease];
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithObject: @[@[@"a"]] forKey: @"TopLeft"];
        [pix setAnnotationsDictionary: d];
        [pix setAnnotationsDBFields: d];
        NSMutableDictionary *got = [pix annotationsDictionary];
        [got setObject: @"changed" forKey: @"TopRight"];
        NSDictionary *values = @{@"same object": @(got == d), @"equal": @([[pix annotationsDictionary] isEqual: d]),
                                 @"fields same object": @([pix annotationsDBFields] == d), @"mutable": @([got isKindOfClass: [NSMutableDictionary class]]),
                                 @"after a change of the copy": describe( [pix annotationsDictionary]),
                                 @"key-value": describe( [pix valueForKey: @"annotationsDictionary"])};
        [pix setAnnotationsDictionary: nil];
        [pix setAnnotationsDBFields: nil];
        NSMutableDictionary *all = [NSMutableDictionary dictionaryWithDictionary: values];
        [all setObject: describe( [pix annotationsDictionary]) forKey: @"cleared"];
        [all setObject: describe( [pix annotationsDBFields]) forKey: @"fields cleared"];
        [pix reloadAnnotations];
        record( @"annotation-accessors", all);
    }
}

static void database( void)
{
    ProbeRow *study = [ProbeRow row: @{@"tag": @"study"}];
    ProbeRow *series = [ProbeRow row: @{@"study": study, @"tag": @"series"}];
    ProbeRow *image = [ProbeRow row: @{@"series": series, @"tag": @"image", @"objectID": @"row-1"}];
    [gRows setObject: image forKey: @"row-1"];
    NSString *file = [gFolder stringByAppendingPathComponent: @"image.dcm"];

    begin( @"database-links");
    id pix = [[[DCMPix alloc] initWithPath: file :0 :1 :nil :0 :0 isBonjour: NO imageObj: nil] autorelease];
    [pix setValue: @"row-1" forKey: @"imageObjectID"];
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    [values setObject: describe( [pix imageObj]) forKey: @"image"];
    [values setObject: describe( [pix seriesObj]) forKey: @"series"];
    [values setObject: describe( [pix studyObj]) forKey: @"study"];
    __block NSArray *background = nil;
    NSThread *thread = [[[NSThread alloc] initWithBlock: ^{
        background = [@[describe( [pix imageObj]), describe( [pix seriesObj]), describe( [pix studyObj])] retain];
    }] autorelease];
    [thread start];
    while( background == nil) [NSThread sleepForTimeInterval: 0.01];
    [values setObject: background forKey: @"on another thread"];
    [pix setValue: @"row-unknown" forKey: @"imageObjectID"];
    [values setObject: describe( [pix imageObj]) forKey: @"unknown image"];
    [values setObject: describe( [pix seriesObj]) forKey: @"unknown series"];
    record( @"database-links", values);

    begin( @"database-sizes");
    storeSize( @"row-1", @{@"width": @640, @"height": @480});
    storeSize( @"row-1", @{});
    storeSize( @"row-1", nil);
    storeSize( nil, @{@"width": @1});
    storeSize( @"row-missing", @{@"width": @2});
    storeSize( @"row-1", @{@"width": @999});
    record( @"database-sizes", @{});
}

static NSString *fnv( float *f, long n)
{
    if( f == NULL) return @"none";
    unsigned long long hash = 1469598103934665603ULL;
    unsigned char *b = (unsigned char*) f;
    for( long i = 0; i < n * 4; i++) { hash ^= b[ i]; hash *= 1099511628211ULL; }
    return [NSString stringWithFormat: @"%016llx", hash];
}

static void documents( void)
{
    useTemplates( templates());
    NSData *pdfData = [NSData dataWithContentsOfFile: [gFolder stringByAppendingPathComponent: @"document.pdf"]];
    NSArray *common = @[attr( @"PatientsName", 0x10, 0x10, @"PN", @[@"DOC^UMENT"]), attr( @"Modality", 0x8, 0x60, @"CS", @[@"CT"])];
    [gParsed setObject: object( [common arrayByAddingObjectsFromArray: @[named( @"SOPClassUID", @"1.2.840.10008.5.1.4.1.1.104.1"),
                                                                        attr( @"EncapsulatedDocument", 0x42, 0x11, @"OB", @[pdfData])]]) forKey: @"pdf.dcm"];
    [gParsed setObject: object( [common arrayByAddingObject: named( @"SOPClassUID", @"1.2.840.10008.5.1.4.1.1.104.2")]) forKey: @"cda.dcm"];
    [gParsed setObject: object( [common arrayByAddingObject: named( @"SOPClassUID", @"1.2.840.10008.5.1.4.1.1.88.11")]) forKey: @"sr-rendered.dcm"];
    [gParsed setObject: object( [common arrayByAddingObject: named( @"SOPClassUID", @"1.2.840.10008.5.1.4.1.1.88.22")]) forKey: @"sr-missing.dcm"];
    [gParsed setObject: object( [common arrayByAddingObject: named( @"SOPClassUID", @"1.2.840.10008.5.1.4.1.1.481.3")]) forKey: @"nonimage.dcm"];
    for( NSArray *c in @[@[@"pdf.dcm", @0], @[@"pdf.dcm", @1], @[@"cda.dcm", @0], @[@"sr-rendered.dcm", @0], @[@"sr-missing.dcm", @0],
                        @[@"nonimage.dcm", @0]])
        for( NSNumber *external in @[@NO, @YES])
        {
            NSString *name = [NSString stringWithFormat: @"document-%@-%@%@", [c[ 0] stringByDeletingPathExtension], c[ 1], external.boolValue ? @"-in-volume" : @""];
            begin( name);
            float *buffer = external.boolValue ? calloc( 512 * 512, sizeof( float)) : NULL;
            id pix = [[[DCMPix alloc] initWithPath: [gFolder stringByAppendingPathComponent: c[ 0]] :0 :1 :buffer :[c[ 1] intValue] :0 isBonjour: NO imageObj: nil] autorelease];
            [pix setValue: @"CT" forKey: @"modalityString"];
            [pix CheckLoad];
            long w = [pix pwidth], h = [pix pheight];
            float *f = [pix fImage];
            record( name, @{@"size": @[@(w), @(h)], @"rgb": @([pix isRGB]), @"pixels": fnv( f, w * h), @"external": @(f == buffer && f != NULL),
                           @"notAbleToLoad": @([pix notAbleToLoadImage]), @"reason": describe( [pix missingPixelsReason]),
                           @"sop": describe( [pix SOPClassUID]), @"annotations": describe( [pix annotationsDictionary])});
        }
}

// ---- RT STRUCT.
static IsiXDCMObject *imageObject( NSString *uid, NSString *frame, NSArray *position, NSArray *orientation, NSArray *spacing, NSString *thickness)
{
    return object( @[named( @"SOPInstanceUID", uid), named( @"FrameofReferenceUID", frame), named( @"ImagePositionPatient", position),
                     named( @"ImageOrientationPatient", orientation), named( @"PixelSpacing", spacing), named( @"SliceThickness", thickness),
                     named( @"Columns", @"64"), named( @"Rows", @"48")]);
}

static IsiXDCMObject *contour( NSString *type, NSArray *points, id count, NSArray *images)
{
    NSMutableArray *attributes = [NSMutableArray arrayWithObjects: named( @"ContourGeometricType", type), named( @"ContourData", points), nil];
    if( count) [attributes addObject: named( @"NumberofContourPoints", count)];
    if( images)
    {
        NSMutableArray *items = [NSMutableArray array];
        for( NSString *uid in images) [items addObject: object( @[named( @"ReferencedSOPInstanceUID", uid)])];
        [attributes addObject: seq( @"ContourImageSequence", items)];
    }
    return object( attributes);
}

static NSArray *square( double x, double y, double z, double s) { return @[@(x), @(y), @(z), @(x + s), @(y), @(z), @(x + s), @(y + s * 0.75), @(z), @(x), @(y + s), @(z), @(x - s * 0.3), @(y + s * 0.5), @(z)]; }

static IsiXDCMObject *structure( void)
{
    NSArray *rois = @[object( @[named( @"ROIName", @"Liver"), named( @"ROINumber", @"1"), named( @"ReferencedFrameofReferenceUID", @"FOR-A")]),
                      object( @[named( @"ROIName", @"Marker"), named( @"ROINumber", @"2"), named( @"ReferencedFrameofReferenceUID", @"")]),
                      object( @[named( @"ROIName", @"Elsewhere"), named( @"ROINumber", @"3"), named( @"ReferencedFrameofReferenceUID", @"FOR-B")])];
    NSArray *liver = @[contour( @"CLOSED_PLANAR", square( -10.25, 20.5, 10.0, 12.7), @"5", nil),
                       contour( @"INTERPOLATED_PLANAR", square( 3.3, -7.1, 12.4, 6.1), @"5", @[@"1.1.2"]),
                       contour( @"CLOSED_PLANAR", square( 3.3, -7.1, 12.4, 6.1), @"5", @[@"1.1.9"]),
                       contour( @"OPEN_PLANAR", square( 0, 0, 10, 5), @"5", nil),
                       contour( @"CLOSED_PLANAR", square( 0, 0, 10, 5), @"4", nil),
                       contour( @"CLOSED_PLANAR", @[@1, @2], @"1", nil),
                       contour( @"CLOSED_PLANAR", square( 0, 0, 10, 5), nil, nil),
                       contour( @"CLOSED_PLANAR", square( 5.5, 6.25, 10.05, 3.3), @"5", nil)];
    NSArray *marker = @[contour( @"POINT", @[@(-1.5), @(2.25), @(12.6)], @"1", nil),
                        contour( @"CLOSED_PLANAR", @[@"7.5", @"-3.25", @"10.0", @"9.5", @"-3.25", @"10.0", @"8.5", @"-1.25", @"10.0"], @"3", nil),
                        contour( @"CLOSED_PLANAR", @[@(1.0), @(1.0), @(31.0), @(2.0), @(1.0), @(30.0), @(2.0), @(3.0), @(29.5)], @"3", nil)];
    NSArray *contours = @[object( @[named( @"ROIDisplayColor", @[@"255", @"64", @"0"]), named( @"ReferencedROINumber", @"1"), seq( @"ContourSequence", liver)]),
                          object( @[named( @"ROIDisplayColor", @[@"0", @"128", @"255"]), named( @"ReferencedROINumber", @"2"), seq( @"ContourSequence", marker)]),
                          object( @[named( @"ROIDisplayColor", @[@"10", @"20", @"30"]), named( @"ReferencedROINumber", @"3"), seq( @"ContourSequence", @[contour( @"CLOSED_PLANAR", square( 0, 0, 10, 5), @"5", nil)])])];
    NSArray *series = @[object( @[named( @"SeriesInstanceUID", @"1.1")]), object( @[named( @"SeriesInstanceUID", @"1.9")])];
    NSArray *frames = @[object( @[seq( @"RTReferencedStudySequence", @[object( @[seq( @"RTReferencedSeriesSequence", series)])])])];
    return object( @[seq( @"ReferencedFrameofReferenceSequence", frames), seq( @"StructureSetROISequence", rois), seq( @"ROIContourSequence", contours)]);
}

static void rtstruct( void)
{
    NSArray *axial = @[@"1", @"0", @"0", @"0", @"1", @"0"];
    NSArray *oblique = @[@"0.8660254", @"0.5", @"0", @"-0.5", @"0.8660254", @"0.1"];
    NSArray *specs = @[@[@"ct1", @"1.1.1", @"FOR-A", @[@"-40.5", @"-30.25", @"10"], axial, @[@"0.8", @"0.75"], @"2.5", @"1.1"],
                       @[@"ct2", @"1.1.2", @"FOR-A", @[@"-40.5", @"-30.25", @"12.5"], axial, @[@"0.8", @"0.75"], @"2.5", @"1.1"],
                       @[@"ct3", @"1.1.3", @"FOR-A", @[@"-40.5", @"-30.25", @"15"], axial, @[@"0.8", @"0"], @"2.5", @"1.1"],
                       @[@"ct4", @"1.9.4", @"FOR-B", @[@"-40.5", @"-30.25", @"30"], axial, @[@"0.5", @"0.5"], @"0", @"1.9"],
                       @[@"obl", @"1.9.5", @"FOR-B", @[@"0", @"0", @"10"], oblique, @[@"0.6", @"0.9"], @"3", @"1.9"]];
    NSMutableArray *rows = [NSMutableArray array];
    for( NSArray *s in specs)
    {
        NSString *path = [gFolder stringByAppendingPathComponent: [s[ 0] stringByAppendingPathExtension: @"dcm"]];
        ProbeRow *study = [ProbeRow row: @{@"roiPath": [s[ 0] isEqualToString: @"ct2"] ? [gFolder stringByAppendingPathComponent: @"existing-roi.dcm"] : [NSNull null], @"tag": @"study"}];
        ProbeRow *series = [ProbeRow row: @{@"seriesDICOMUID": s[ 7], @"study": study, @"tag": @"series"}];
        [rows addObject: [ProbeRow row: @{@"sopInstanceUID": s[ 1], @"path": path, @"series": series, @"tag": s[ 0]}]];
        [gParsed setObject: imageObject( s[ 1], s[ 2], s[ 3], s[ 4], s[ 5], s[ 6]) forKey: [path lastPathComponent]];
    }
    [gRows setObject: rows forKey: @"fetch"];
    id db = [[BrowserController currentBrowser] database];
    NSString *file = [gFolder stringByAppendingPathComponent: @"struct.dcm"];

    for( NSNumber *brush in @[@NO, @YES])
    {
        NSString *name = brush.boolValue ? @"rtstruct-brush" : @"rtstruct";
        begin( name);
        [[NSUserDefaults standardUserDefaults] registerDefaults: @{@"RSTRUCTConvertToBrush": brush}];
        id pix = [[[DCMPix alloc] initWithPath: file :0 :1 :nil :0 :0 isBonjour: NO imageObj: nil] autorelease];
        [pix createROIsFromRTSTRUCT: @{@"dcmObject": structure()} inDatabase: db];
        record( name, @{});
    }
    [[NSUserDefaults standardUserDefaults] registerDefaults: @{@"RSTRUCTConvertToBrush": @NO}];

    begin( @"rtstruct-thread");
    {
        id pix = [[[DCMPix alloc] initWithPath: file :0 :1 :nil :0 :0 isBonjour: NO imageObj: nil] autorelease];
        [pix createROIsFromRTSTRUCTThread: @{@"dcmObject": structure()}];
        record( @"rtstruct-thread", @{});
    }

    begin( @"rtstruct-bonjour");
    {
        gBonjour = YES;
        id pix = [[[DCMPix alloc] initWithPath: file :0 :1 :nil :0 :0 isBonjour: NO imageObj: nil] autorelease];
        [pix createROIsFromRTSTRUCT: structure()];
        gBonjour = NO;
        record( @"rtstruct-bonjour", @{});
    }

    NSDictionary *broken = @{
        @"rtstruct-no-frames": object( @[]),
        @"rtstruct-no-series": object( @[seq( @"ReferencedFrameofReferenceSequence", @[])]),
        @"rtstruct-no-rois": object( @[seq( @"ReferencedFrameofReferenceSequence", [[[structure() attributeWithName: @"ReferencedFrameofReferenceSequence"] values] copy])]),
        @"rtstruct-no-contours": object( @[seq( @"ReferencedFrameofReferenceSequence", [[[structure() attributeWithName: @"ReferencedFrameofReferenceSequence"] values] copy]),
                                           seq( @"StructureSetROISequence", @[])]),
        @"rtstruct-unknown-series": object( @[seq( @"ReferencedFrameofReferenceSequence", @[object( @[seq( @"RTReferencedStudySequence",
                                              @[object( @[seq( @"RTReferencedSeriesSequence", @[object( @[named( @"SeriesInstanceUID", @"7.7")])])])])])])]),
    };
    for( NSString *name in [[broken allKeys] sortedArrayUsingSelector: @selector(compare:)])
    {
        begin( name);
        id pix = [[[DCMPix alloc] initWithPath: file :0 :1 :nil :0 :0 isBonjour: NO imageObj: nil] autorelease];
        [pix createROIsFromRTSTRUCT: @{@"dcmObject": broken[ name]} inDatabase: db];
        record( name, @{});
    }

    begin( @"rtstruct-missing-image");
    {
        [gParsed removeObjectForKey: @"ct3.dcm"];
        id pix = [[[DCMPix alloc] initWithPath: file :0 :1 :nil :0 :0 isBonjour: NO imageObj: nil] autorelease];
        [pix createROIsFromRTSTRUCT: @{@"dcmObject": structure()} inDatabase: db];
        record( @"rtstruct-missing-image", @{});
    }
}

int main( int argc, const char *argv[])
{
    @autoreleasepool
    {
        if( argc > 1 && strcmp( argv[ 1], "--probe-link") == 0) return 0;
        [NSApplication sharedApplication];
        gFolder = [@(argv[ 1]) retain];
        gEvents = [[NSMutableArray alloc] init];
        gRecords = [[NSMutableArray alloc] init];
        gRows = [[NSMutableDictionary alloc] init];
        gParsed = [[NSMutableDictionary alloc] init];
        provideStoreSize();
        installThreadAccessors();
        NSString *part = @(argv[ 2]);
        if( [part isEqualToString: @"annotations"]) annotations();
        if( [part isEqualToString: @"database"]) database();
        if( [part isEqualToString: @"documents"]) documents();
        if( [part isEqualToString: @"rtstruct"]) rtstruct();
        for( NSDictionary *r in gRecords)
        {
            NSData *json = [NSJSONSerialization dataWithJSONObject: r options: NSJSONWritingSortedKeys error: nil];
            printf( "%s\n", [[[[NSString alloc] initWithData: json encoding: NSUTF8StringEncoding] autorelease] UTF8String]);
        }
        fflush( stdout);
    }
    return 0;
}
'''

PARTS = ('annotations', 'database', 'documents', 'rtstruct')
MALFORMED = re.compile(r'^CustomImageAnnotations(?: Exception)?: (?:-\[\S+ \S+\]: unrecognized selector sent to instance 0x\?'
                       r'|a line of \w+ is not a list of fields|a field of \w+ is not a field'
                       r'|the annotations of \w+ are not a list of lines)$')
UNREADABLE = re.compile(r'^exception (?:NSInvalidArgumentException: \*\*\* -\[__NSArrayM insertObject:atIndex:\]: object cannot be nil'
                        r'|RTStruct: Error opening referenced image file)$')


def run(harness, folder):
    records = {}
    for part in PARTS:
        try:
            done = subprocess.run([str(harness), str(folder), part], capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired:
            raise RuntimeError(f'the {part} probe did not finish in 60 s')
        if done.returncode:
            raise RuntimeError(f'the {part} probe ended with {done.returncode}:\n{done.stderr[-3000:]}')
        logs, name = {}, None
        for line in done.stderr.splitlines():
            if line.startswith('@@CASE '):
                name = line[len('@@CASE '):]
                logs[name] = []
            elif name and line.strip():
                text = line.split('] ', 1)[1] if line[:4].isdigit() and '] ' in line else line
                # Without the addresses of the objects named.
                text = re.sub(r'0x[0-9a-f]{6,}', '0x?', text.replace(str(folder), '<folder>'))
                # A malformed template entry: the Objective-C logged the exception the
                # wrong type raised, the Swift checks the type and says what it found.
                text = MALFORMED.sub('CustomImageAnnotations: a malformed template entry', text)
                # A referenced image file that does not parse ends the conversion in both:
                # the Objective-C raised adding nil to its list, the Swift says why.
                logs[name].append(UNREADABLE.sub('exception: a referenced image file does not open', text))
        for line in done.stdout.splitlines():
            record = json.loads(line.replace(str(folder), '<folder>'))
            name = record.pop('name')
            record['log'] = logs.get(name, [])
            records[name] = record
    return records


def build(revision, folder):
    if revision == roi_harness.WORKTREE:
        return roi_harness.build(revision, folder, PROBE + roi_harness.RECORDED_BACKING_SCALE, config=configuration, app_swift=APP_SWIFT)
    # The revision's DCMPix.m already calls the Swift that left it before these
    # parts did; it gets this checkout's, without the extensions that took these.
    keep = [name for name in roi_harness.swift_dcmpix_files() if name not in MOVED]
    return roi_harness.build(revision, folder, PROBE + roi_harness.RECORDED_BACKING_SCALE, config=configuration, app_swift=APP_SWIFT, dcmpix_swift=keep)


def main():
    swift_class = not roi_harness.objc_class()
    current_text = '' if swift_class else (ROOT / PIX).read_bytes().decode('latin1')
    delegates = OBJC_MARKER not in current_text
    if swift_class:
        # No revision of DCMPix.m links with the Swift class: the reference is
        # what this test recorded against the last Objective-C class.
        reference = None
    elif len(sys.argv) > 1:
        reference = sys.argv[1]
    elif not delegates:
        reference = 'HEAD'
    elif OBJC_MARKER in show('HEAD', PIX).decode('latin1'):
        reference = 'HEAD'
    else:
        reference = before_text_removed(PIX, OBJC_MARKER)

    failures = []
    outputs = {}
    with tempfile.TemporaryDirectory(prefix='horos-dcmpix-annotations-') as tmp:
        tmp = Path(tmp)
        for label, revision in ((('reference', reference),) if reference else ()) + (('current', roi_harness.WORKTREE),):
            folder = tmp / label / 'files'
            folder.mkdir(parents=True)
            fixtures(folder)
            try:
                harness = build(revision, tmp / label / 'harness')
            except LookupError as error:
                print('skipped: %s' % error, file=sys.stderr)
                sys.exit(SKIPPED)
            except (subprocess.CalledProcessError, RuntimeError) as error:
                print(f'FAIL: the {label} harness ({revision}) did not build: {str(error)[-4000:]}')
                sys.exit(1)
            try:
                outputs[label] = run(harness, folder)
            except RuntimeError as error:
                print(f'FAIL: {label}: {error}')
                sys.exit(1)
        if os.environ.get('HOROS_ANNOTATION_RECORDS'):
            Path(os.environ['HOROS_ANNOTATION_RECORDS']).write_text(json.dumps(outputs, indent=1, sort_keys=True))

    current = outputs['current']
    against = reference[:12] if reference else 'the records of the last Objective-C class'
    try:
        previous = outputs['reference'] if reference else roi_harness.golden(GOLDEN, configuration)
    except LookupError as error:
        print(f'FAIL: {error}')
        sys.exit(1)
    check_expectations(current, failures)
    for problem in roi_harness.diff(previous, current):
        failures.append('differs from the reference: ' + problem)
    for failure in failures:
        print('FAIL:', failure)
    if failures:
        sys.exit(1)
    if roi_harness.recording_golden():
        roi_harness.golden(GOLDEN, configuration, current)
    print(f'PASS: {len(current)} cases (database links and sizes, annotations, encapsulated documents, RT STRUCT ROIs) '
          f'identical to {against} in {configuration}')


def check_expectations(records, failures):
    """What the records must show whatever the revision: each part did its work."""
    ct = records.get('annotations-CT', {}).get('with the object', {}).get('annotations', {})
    if 'TopLeft' not in ct or 'LowerLeft' not in ct:
        failures.append('the CT annotations were not built: %s' % str(ct)[:300])
    archived = [e for e in records.get('rtstruct', {}).get('events', []) if e[0] == 'archive']
    if not archived or not any(event[1]['rois'] for event in archived):
        failures.append('the RT STRUCT made no ROIs')
    pdf_case = records.get('document-pdf-0', {})
    if pdf_case.get('pixels') in (None, 'none'):
        failures.append('the encapsulated PDF was not drawn')
    if records.get('document-pdf-0', {}).get('pixels') == records.get('document-pdf-1', {}).get('pixels'):
        failures.append('the two pages of the PDF are the same image')


if __name__ == '__main__':
    main()
