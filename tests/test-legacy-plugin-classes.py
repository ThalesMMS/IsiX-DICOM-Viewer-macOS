#!/usr/bin/env python3
"""A plugin built for Horos or OsiriX names the classes of that SDK, inherits
from them and uses them, and the application has them.

A plugin's binary binds _OBJC_CLASS_$_<Name> for every class it sends a message
to, inherits from or extends; dyld resolves the bind when the bundle is loaded
and refuses the bundle when the application has no such class. Fifty-one
classes of the SDK had left the application; they are back, each with the
superclass the SDK gave it, and eleven classes that had lost their superclass
have it again. tests/test-legacy-plugin-abi.py reads the class list of the
built executable; this test loads a plugin that needs them.

QALegacyClasses.horosplugin is built here the way those plugins were:
Objective-C without ARC, a bundle linked with -undefined dynamic_lookup, its
principal class a subclass of PluginFilter, and no header of the application.
It names each of the 51 classes, so that it does not load if one is missing,
and has subclasses of its own of HTTPConnection, VTKView, Interpolation3D and
N2SingletonObject. The development bundle is launched isolated
(tools/native_app.py) and loads it with --LoadPlugin. Two seconds later the
plugin:

- compares the superclass of each class with the one tests/legacy-plugin-abi.json
  records, and checks the ancestry of the classes that descend from them
  (VRView and the scene views from VTKView, the portal's server, connection
  and response from the HTTP classes, the query nodes from
  DCMTKServiceClassUser, and the others);
- asks each class for every selector the registry lists for it and does not
  excuse as missing;
- uses them: a CSV line, the default preferences, the list of DICOM nodes with
  a node it adds to the preferences, a DCMObject written into a
  DCMDataContainer and read back from one, a file compressed and decompressed
  by DicomCompressor on a thread of its own, an object that is never released, a pair, the parts of
  a URL, JSON written and parsed, an ISO 8601 date, the moves under way, the
  wait for the listener's associations, and an HTTPServer that serves, through
  the plugin's own subclass of HTTPConnection, a response the subclass makes.

    python3 tests/test-legacy-plugin-classes.py [--app PATH]

Exit status 2 means skipped: no development bundle, one that is of an earlier
build than the built product, or an instance of it is running. The test launches the application: it needs a logged-in graphical
session, and no other development instance of this checkout running.
"""
import argparse
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import native_app  # noqa: E402

REGISTRY = json.loads((ROOT / 'tests/legacy-plugin-abi.json').read_text())

RESTORED = '''DicomCompressor HTTPServer HTTPConnection HTTPDataResponse HTTPFileResponse AsyncSocket DDKeychain SBJsonBase SBJSON
SBJsonParser SBJsonWriter ISO8601DateFormatter N2Task N2CSV N2Pair N2SingletonObject N2URLParts N2Connection
N2ConnectionListener N2OpenGLViewWithSplitsWindow VTKView VTKStereoVRView VTKStereoSRView GLString StringTexture
OpenGLScreenReader ITK Interpolation3D DefaultsOsiriX MoveManager OsiriXSCPDataHandler ContextCleaner DCMTKServiceClassUser
DCMTKPrintSCU DCMObject DCMObjectDBImport DCMObjectPixelDataImport DCMUSRegion DCMWaveform DCMWaveformSequence
DCMWaveformChannelDefinition DCMCodeSequenceMacro DCMSOPInstanceReferenceMacro DCMWaveformChannelSource
DCMWaveformChannelSourceModifier DCMWaveformSourceWaveform DCMWaveformChannelSensitivityUnit DCMCalendarScript
DCMDataContainer DCMLimitedObject DCMNetServiceDelegate DCMValueRepresentation'''.split()
# DCMObject is there for its subclasses; it never left.
NAMED = [name for name in RESTORED if name != 'DCMObject']

# The classes that had lost a superclass of the SDK, and those that inherit it from them.
ANCESTRY = [('VRView', 'VTKView'), ('EndoscopyVRView', 'VTKView'), ('VRPresetPreview', 'VTKView'), ('SRView', 'VTKView'),
            ('ROIVolumeView', 'VTKView'), ('HorosSceneView', 'VTKView'), ('SRView', 'HorosSceneView'),
            ('ROIVolumeView', 'HorosSceneView'), ('VTKView', 'NSView'), ('Spline3D', 'Interpolation3D'),
            ('Piecewise3D', 'Interpolation3D'), ('DCMTKQueryNode', 'DCMTKServiceClassUser'),
            ('DCMTKRootQueryNode', 'DCMTKServiceClassUser'), ('DCMTKStudyQueryNode', 'DCMTKServiceClassUser'),
            ('DCMTKSeriesQueryNode', 'DCMTKServiceClassUser'), ('DCMTKImageQueryNode', 'DCMTKServiceClassUser'),
            ('WebPortalServer', 'HTTPServer'), ('WebPortalConnection', 'HTTPConnection'),
            ('WebPortalResponse', 'HTTPDataResponse'), ('N2XMLRPCConnection', 'N2Connection'),
            ('OSIWindow', 'N2OpenGLViewWithSplitsWindow'), ('N2OpenGLViewWithSplitsWindow', 'NSWindow')]


# The instance variable a subclass of the SDK's singleton reads in its -init.
IVARS = {'N2SingletonObject': ' {\n@protected\n    BOOL _hasInited;\n}'}


def superclasses():
    """The superclass the registry records for each of the 51 classes."""
    return {name: REGISTRY['classes'][name] for name in NAMED}


def selectors():
    """[class, '+' or '-', selector] for what the registry lists for the 51 classes and does not excuse."""
    missing = REGISTRY['missing']
    listed = []
    for key in sorted(REGISTRY['selectors']):
        name, selector = key.split(' ', 1)
        if name in NAMED and f'selectors {key}' not in missing:
            listed.append([name, selector[0], selector[1:]])
    return listed


def interfaces():
    """The classes as the plugin declares them, a superclass before its subclasses, and the function that names them."""
    parents = dict(superclasses(), DCMObject='NSObject')
    declared, lines = set(), []

    def declare(name):
        if name in declared or name not in parents:
            return
        declare(parents[name])
        declared.add(name)
        lines.append(f'@interface {name} : {parents[name]}{IVARS.get(name, "")}\n@end')
    for name in RESTORED:
        declare(name)
    lines.append('static NSArray *namedClasses(void) {\n    return [NSArray arrayWithObjects:'
                 + ', '.join(f'[{name} class]' for name in NAMED) + ', nil];\n}')
    return '\n'.join(lines)


PLUGIN = r'''
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

// What the plugin uses of the SDK, declared here as its headers declared it.
@interface PluginFilter : NSObject
- (void)initPlugin;
- (long)filterImage:(NSString *)menuName;
@end
@interface DICOMExport : NSObject
- (long)setPixelData:(unsigned char *)data samplesPerPixel:(int)samplesPerPixel bitsPerSample:(int)bitsPerSample width:(long)width height:(long)height;
- (NSString *)writeDCMFile:(NSString *)dstPath;
@end
@interface DCMTransferSyntax : NSObject
+ (id)ExplicitVRLittleEndianTransferSyntax;
+ (id)JPEGLSLosslessTransferSyntax;
- (BOOL)isEncapsulated;
- (NSString *)transferSyntax;
@end
typedef struct { float x, y, z; } QAPoint3D;
INTERFACES
@interface DCMObject (QAFormerSDK)
+ (id)objectWithContentsOfFile:(NSString *)file decodingPixelData:(BOOL)decodePixelData;
- (id)initWithDataContainer:(DCMDataContainer *)data lengthToRead:(int)lengthToRead byteOffset:(int *)byteOffset characterSet:(id)characterSet decodingPixelData:(BOOL)decodePixelData;
- (id)attributeValueWithName:(NSString *)name;
- (DCMTransferSyntax *)transferSyntax;
- (BOOL)writeToFile:(NSString *)path withTransferSyntax:(DCMTransferSyntax *)ts quality:(int)quality atomically:(BOOL)flag;
- (BOOL)writeToDataContainer:(DCMDataContainer *)container withTransferSyntax:(DCMTransferSyntax *)ts asDICOM3:(BOOL)flag;
- (BOOL)writeToDataContainer:(DCMDataContainer *)container withTransferSyntax:(DCMTransferSyntax *)ts quality:(int)quality asDICOM3:(BOOL)flag strippingGroupLengthLength:(BOOL)strip;
@end
@interface DCMDataContainer (QAFormerSDK)
+ (id)dataContainer;
+ (id)dataContainerWithData:(NSData *)data;
- (NSMutableData *)dicomData;
- (int)offset;
@end
@interface DicomCompressor (QAFormerSDK)
+ (void)decompressFiles:(NSArray *)filePaths toDirectory:(NSString *)dirPath;
+ (void)compressFiles:(NSArray *)filePaths toDirectory:(NSString *)dirPath;
@end
@interface N2CSV (QAFormerSDK)
+ (NSString *)quote:(NSString *)str;
+ (NSString *)stringFromArray:(NSArray *)array;
@end
@interface DefaultsOsiriX (QAFormerSDK)
+ (NSMutableDictionary *)getDefaults;
+ (long)vramSize;
@end
@interface DCMNetServiceDelegate (QAFormerSDK)
+ (NSArray *)DICOMServersList;
+ (NSArray *)DICOMServersListSendOnly:(BOOL)send QROnly:(BOOL)QR;
+ (NSArray *)DICOMServersListSendOnly:(BOOL)send QROnly:(BOOL)QR cached:(BOOL)cached;
+ (id)sharedNetServiceDelegate;
- (NSArray *)dicomServices;
@end
@interface Interpolation3D (QAFormerSDK)
- (void)addPoint:(float)t :(QAPoint3D *)p;
- (QAPoint3D *)evaluateAt:(float)t;
@end
@interface N2Pair (QAFormerSDK)
- (id)initWith:(id)first and:(id)second;
- (id)first;
- (id)second;
@end
@interface N2URLParts (QAFormerSDK)
- (NSString *)protocol;
- (NSString *)address;
- (NSString *)port;
- (NSString *)path;
- (NSString *)params;
- (NSString *)pathAndParams;
@end
@interface NSURL (QAFormerSDK)
- (N2URLParts *)parts;
+ (NSURL *)URLWithParts:(N2URLParts *)parts;
@end
@interface SBJsonBase (QAFormerSDK)
- (NSArray *)errorTrace;
@end
@interface SBJsonWriter (QAFormerSDK)
- (void)setSortKeys:(BOOL)flag;
- (NSString *)stringWithObject:(id)value;
@end
@interface SBJsonParser (QAFormerSDK)
- (id)objectWithString:(NSString *)repr;
@end
@interface ISO8601DateFormatter (QAFormerSDK)
- (NSDate *)dateFromString:(NSString *)string;
- (NSString *)stringFromDate:(NSDate *)date;
@end
@interface MoveManager (QAFormerSDK)
+ (id)sharedManager;
- (void)addMove:(id)move;
- (void)removeMove:(id)move;
- (BOOL)containsMove:(id)move;
@end
@interface ContextCleaner (QAFormerSDK)
+ (void)waitForHandledAssociations;
@end
@interface DCMTKServiceClassUser (QAFormerSDK)
- (id)initWithCallingAET:(NSString *)myAET calledAET:(NSString *)theirAET hostname:(NSString *)hostname port:(int)port transferSyntax:(int)transferSyntax compression:(float)compression extraParameters:(NSDictionary *)extraParameters;
- (NSString *)callingAET;
- (NSString *)calledAET;
- (NSDictionary *)extraParameters;
@end
@interface VTKView (QAFormerSDK)
+ (unsigned long)VRAMSizeForDisplayID:(CGDirectDisplayID)displayID;
- (void *)renderer;
- (void)removeAllActors;
@end
@interface HTTPServer (QAFormerSDK)
- (void)setConnectionClass:(Class)value;
- (Class)connectionClass;
- (void)setDocumentRoot:(NSURL *)value;
- (void)setPort:(UInt16)value;
- (UInt16)port;
- (BOOL)start:(NSError **)errPtr;
- (BOOL)stop;
@end
@interface HTTPConnection (QAFormerSDK)
- (BOOL)supportsMethod:(NSString *)method atPath:(NSString *)path;
- (NSObject *)httpResponseForMethod:(NSString *)method URI:(NSString *)path;
@end
@interface HTTPDataResponse (QAFormerSDK)
- (id)initWithData:(NSData *)data;
- (UInt64)contentLength;
@end

// The plugin's own subclasses of classes of the SDK.
@interface QAConnection : HTTPConnection
@end
@implementation QAConnection
- (NSObject *)httpResponseForMethod:(NSString *)method URI:(NSString *)path {
    if ([path hasPrefix:@"/qa-made"])
        return [[[HTTPDataResponse alloc] initWithData:[@"made by the plugin's connection" dataUsingEncoding:NSUTF8StringEncoding]] autorelease];
    return [super httpResponseForMethod:method URI:path];
}
@end
@interface QAView : VTKView
@end
@implementation QAView
@end
@interface QACurve : Interpolation3D
@end
@implementation QACurve
- (void)addPoint:(float)t :(QAPoint3D *)p { [super addPoint:t :p]; }
@end
static int singletonInits = 0;
@interface QASingleton : N2SingletonObject
@end
@implementation QASingleton
- (id)init {
    BOOL already = _hasInited;
    if ((self = [super init]) && !already) singletonInits++;
    return self;
}
@end

@interface QALegacyClasses : PluginFilter {
    NSMutableDictionary *report;
    NSString *work;
}
@end

static NSString *writeImage(NSString *folder) {
    DICOMExport *exporter = [[[NSClassFromString(@"DICOMExport") alloc] init] autorelease];
    unsigned char *pixels = calloc(64 * 64, 2);
    for (int i = 0; i < 64 * 64; i++) pixels[2 * i] = (unsigned char)(i / 64);
    [exporter setPixelData:pixels samplesPerPixel:1 bitsPerSample:16 width:64 height:64];
    NSString *path = [exporter writeDCMFile:[folder stringByAppendingPathComponent:@"qa.dcm"]];
    free(pixels);
    return path;
}

@implementation QALegacyClasses

- (void)initPlugin {
    [self performSelector:@selector(run) withObject:nil afterDelay:2.0];
}

- (long)filterImage:(NSString *)menuName { return 0; }

- (void)note:(NSString *)check :(NSString *)failure {
    @synchronized (report) { [report setObject:(failure ? failure : @"ok") forKey:check]; }
}

- (void)run {
    report = [[NSMutableDictionary alloc] init];
    work = [[NSString alloc] initWithUTF8String:getenv("QA_LEGACY_CLASSES_WORK")];
    @try {
        NSArray *named = namedClasses();
        [self note:@"the plugin names the classes" :(named.count == NAMED_COUNT ? nil : [NSString stringWithFormat:@"%lu classes", (unsigned long)named.count])];

        NSDictionary *expected = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithUTF8String:getenv("QA_LEGACY_CLASSES_SUPERCLASSES")]];
        for (NSString *name in expected) {
            Class found = NSClassFromString(name);
            NSString *parent = found ? NSStringFromClass(class_getSuperclass(found)) : @"no such class";
            [self note:[NSString stringWithFormat:@"%@ : %@", name, [expected objectForKey:name]] :([parent isEqual:[expected objectForKey:name]] ? nil : parent)];
        }
        for (NSArray *pair in [NSArray arrayWithContentsOfFile:[NSString stringWithUTF8String:getenv("QA_LEGACY_CLASSES_ANCESTRY")]]) {
            Class sub = NSClassFromString([pair objectAtIndex:0]), ancestor = NSClassFromString([pair objectAtIndex:1]);
            [self note:[NSString stringWithFormat:@"%@ descends from %@", [pair objectAtIndex:0], [pair objectAtIndex:1]]
                      :(sub && ancestor && [sub isSubclassOfClass:ancestor] ? nil
                        : [NSString stringWithFormat:@"its superclass is %@", sub ? NSStringFromClass(class_getSuperclass(sub)) : @"absent"])];
        }
        for (NSArray *entry in [NSArray arrayWithContentsOfFile:[NSString stringWithUTF8String:getenv("QA_LEGACY_CLASSES_SELECTORS")]]) {
            Class cls = NSClassFromString([entry objectAtIndex:0]);
            SEL selector = NSSelectorFromString([entry objectAtIndex:2]);
            BOOL answers = [[entry objectAtIndex:1] isEqual:@"+"] ? [cls respondsToSelector:selector] : [cls instancesRespondToSelector:selector];
            [self note:[NSString stringWithFormat:@"%@ %@%@", [entry objectAtIndex:0], [entry objectAtIndex:1], [entry objectAtIndex:2]] :(answers ? nil : @"does not answer")];
        }

        // A CSV line, as the SDK quoted it.
        NSString *line = [N2CSV stringFromArray:[NSArray arrayWithObjects:@"plain", @"with,comma", @"with \"quotes\"", @" padded ", nil]];
        [self note:@"+[N2CSV stringFromArray:] quotes what needs it"
                  :([line isEqual:@"plain,\"with,comma\",\"with \"\"quotes\"\"\",\" padded \""] && [[N2CSV quote:@"plain"] isEqual:@"plain"] ? nil : line)];

        NSMutableDictionary *defaults = [DefaultsOsiriX getDefaults];
        [self note:@"+[DefaultsOsiriX getDefaults] answers the default preferences, a new dictionary each time"
                  :([defaults isKindOfClass:[NSMutableDictionary class]] && defaults.count > 100 && [DefaultsOsiriX getDefaults] != defaults && [DefaultsOsiriX vramSize] >= 0
                    ? nil : [NSString stringWithFormat:@"%lu entries", (unsigned long)defaults.count])];

        // The list of DICOM nodes, with one the plugin adds to the preferences.
        NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
        NSArray *before = [preferences arrayForKey:@"SERVERS"];
        NSDictionary *node = [NSDictionary dictionaryWithObjectsAndKeys:@"QANODE", @"AETitle", @"127.0.0.1", @"Address", @"11112", @"Port",
                              @"QA node", @"Description", [NSNumber numberWithBool:YES], @"QR", [NSNumber numberWithBool:YES], @"Send",
                              [NSNumber numberWithBool:YES], @"Activated", [NSNumber numberWithInt:0], @"TransferSyntax", nil];
        [preferences setObject:[(before ? before : [NSArray array]) arrayByAddingObject:node] forKey:@"SERVERS"];
        NSArray *nodes = [DCMNetServiceDelegate DICOMServersListSendOnly:NO QROnly:NO];
        BOOL listed = NO;
        for (id each in nodes) if ([each isKindOfClass:[NSDictionary class]] && [[each objectForKey:@"AETitle"] isEqual:@"QANODE"]) listed = YES;
        [self note:@"+[DCMNetServiceDelegate DICOMServersListSendOnly:QROnly:] lists the nodes of the preferences"
                  :([nodes isKindOfClass:[NSArray class]] && listed ? nil : [NSString stringWithFormat:@"%lu nodes, none QANODE", (unsigned long)nodes.count])];
        [self note:@"the other lists of DCMNetServiceDelegate answer"
                  :([[DCMNetServiceDelegate DICOMServersList] isKindOfClass:[NSArray class]]
                    && [[DCMNetServiceDelegate DICOMServersListSendOnly:YES QROnly:NO cached:YES] isKindOfClass:[NSArray class]]
                    && [[[DCMNetServiceDelegate sharedNetServiceDelegate] dicomServices] isKindOfClass:[NSArray class]] ? nil : @"one is not an array")];
        if (before) [preferences setObject:before forKey:@"SERVERS"]; else [preferences removeObjectForKey:@"SERVERS"];

        // A DCMObject in a container of bytes, and back.
        NSString *image = writeImage(work);
        DCMObject *object = image ? [DCMObject objectWithContentsOfFile:image decodingPixelData:NO] : nil;
        [self note:@"DICOMExport writes a file that DCMObject reads" :([[object attributeValueWithName:@"Rows"] intValue] == 64 ? nil : [NSString stringWithFormat:@"%@", image])];
        DCMDataContainer *container = [DCMDataContainer dataContainer];
        BOOL wrote = [object writeToDataContainer:container withTransferSyntax:[DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax] asDICOM3:YES];
        NSData *stream = [container dicomData];
        [self note:@"-writeToDataContainer:withTransferSyntax:asDICOM3: gives a Part 10 stream"
                  :(wrote && stream.length > 4096 && memcmp((const char *)stream.bytes + 128, "DICM", 4) == 0 ? nil
                    : [NSString stringWithFormat:@"answered %d, %lu bytes", wrote, (unsigned long)stream.length])];
        DCMDataContainer *bare = [DCMDataContainer dataContainer];
        wrote = [object writeToDataContainer:bare withTransferSyntax:[DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax] quality:0 asDICOM3:NO strippingGroupLengthLength:YES];
        NSUInteger bareLength = [[bare dicomData] length];
        [self note:@"-writeToDataContainer:withTransferSyntax:quality:asDICOM3:strippingGroupLengthLength: gives the dataset alone"
                  :(wrote && bareLength > 4096 && bareLength < stream.length ? nil : [NSString stringWithFormat:@"answered %d, %lu bytes", wrote, (unsigned long)bareLength])];
        DCMDataContainer *toRead = [DCMDataContainer dataContainerWithData:stream];
        int offset = [toRead offset];
        DCMObject *back = [[[DCMObject alloc] initWithDataContainer:toRead lengthToRead:-1 byteOffset:&offset characterSet:nil decodingPixelData:NO] autorelease];
        [self note:@"-initWithDataContainer:lengthToRead:byteOffset:characterSet:decodingPixelData: reads the stream back"
                  :(offset == (int)stream.length && [[back attributeValueWithName:@"Rows"] intValue] == 64 ? nil
                    : [NSString stringWithFormat:@"offset %d of %lu, Rows %@", offset, (unsigned long)stream.length, [back attributeValueWithName:@"Rows"]])];
        [self note:@"the import subclasses answer their own class"
                  :([[DCMObjectDBImport objectWithContentsOfFile:image decodingPixelData:NO] isMemberOfClass:[DCMObjectDBImport class]]
                    && [[DCMObjectPixelDataImport objectWithContentsOfFile:image decodingPixelData:NO] isMemberOfClass:[DCMObjectPixelDataImport class]] ? nil : @"another class")];

        // The plugin's subclasses.
        QASingleton *single = [[QASingleton alloc] init];
        [single release];
        [single release];
        [self note:@"a subclass of N2SingletonObject is initialized once and is never released"
                  :([single init] == single && singletonInits == 1 && [single retain] == single && [single autorelease] == single && [single retainCount] == UINT_MAX
                    ? nil : [NSString stringWithFormat:@"%d inits, retain count %lu", singletonInits, (unsigned long)[single retainCount]])];
        QACurve *curve = [[[QACurve alloc] init] autorelease];
        QAPoint3D point = {1, 2, 3};
        [curve addPoint:0.5f :&point];
        [self note:@"a subclass of Interpolation3D inherits the two methods, which do nothing" :([curve evaluateAt:0.5f] == NULL ? nil : @"-evaluateAt: answered a point")];
        QAView *view = [[[QAView alloc] initWithFrame:NSMakeRect(0, 0, 32, 32)] autorelease];
        [view removeAllActors];
        [self note:@"a subclass of VTKView is a view without a renderer"
                  :([view isKindOfClass:[NSView class]] && [view isKindOfClass:[VTKView class]] && [view renderer] == NULL ? nil : @"not so")];

        N2Pair *pair = [[[N2Pair alloc] initWith:@"one" and:@"two"] autorelease];
        N2URLParts *parts = [[NSURL URLWithString:@"http://example.org:8080/path/to?a=1"] parts];
        [self note:@"N2Pair keeps its two objects and N2URLParts the parts of a URL"
                  :([[pair first] isEqual:@"one"] && [[pair second] isEqual:@"two"] && [[parts protocol] isEqual:@"http"] && [[parts address] isEqual:@"example.org"]
                    && [[parts port] isEqual:@"8080"] && [[parts path] isEqual:@"/path/to"] && [[parts params] isEqual:@"a=1"]
                    && [[[NSURL URLWithParts:parts] absoluteString] isEqual:@"http://example.org:8080/path/to?a=1"] ? nil
                    : [NSString stringWithFormat:@"%@ %@ %@ %@ %@ -> %@", [parts protocol], [parts address], [parts port], [parts path], [parts params], [NSURL URLWithParts:parts]])];
        SBJsonWriter *writer = [[[SBJsonWriter alloc] init] autorelease];
        [writer setSortKeys:YES];
        NSString *written = [writer stringWithObject:[NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:1], @"b", [NSArray arrayWithObject:@"x"], @"a", nil]];
        id parsed = [[[[SBJsonParser alloc] init] autorelease] objectWithString:@"{\"k\":[1,2,{\"n\":null}]}"];
        [self note:@"SBJsonWriter writes and SBJsonParser parses"
                  :([written isEqual:@"{\"a\":[\"x\"],\"b\":1}"] && [[[parsed objectForKey:@"k"] objectAtIndex:1] intValue] == 2
                    && [[[[[SBJSON alloc] init] autorelease] errorTrace] count] == 0 ? nil : [NSString stringWithFormat:@"%@ and %@", written, parsed])];
        ISO8601DateFormatter *formatter = [[[ISO8601DateFormatter alloc] init] autorelease];
        NSDate *date = [formatter dateFromString:@"2026-11-17"];
        [self note:@"ISO8601DateFormatter reads a calendar date and writes it"
                  :(date && [[formatter stringFromDate:date] hasPrefix:@"2026-11-17"] ? nil : [NSString stringWithFormat:@"%@ -> %@", date, [formatter stringFromDate:date]])];
        MoveManager *moves = [[[MoveManager alloc] init] autorelease];
        NSObject *move = [[[NSObject alloc] init] autorelease];
        [moves addMove:move];
        BOOL contained = [moves containsMove:move];
        [moves removeMove:move];
        [self note:@"MoveManager keeps the moves under way"
                  :(contained && ![moves containsMove:move] && [MoveManager sharedManager] && ![[MoveManager sharedManager] containsMove:move] ? nil : @"not so")];
        DCMTKServiceClassUser *user = [[[DCMTKServiceClassUser alloc] initWithCallingAET:@"QA" calledAET:@"THEM" hostname:@"127.0.0.1" port:11112
                                                                             transferSyntax:0 compression:0 extraParameters:[NSDictionary dictionaryWithObject:@"v" forKey:@"k"]] autorelease];
        [self note:@"DCMTKServiceClassUser keeps what it is initialized with"
                  :([[user callingAET] isEqual:@"QA"] && [[user calledAET] isEqual:@"THEM"] && [[[user extraParameters] objectForKey:@"k"] isEqual:@"v"] ? nil : @"not so")];
    } @catch (NSException *exception) {
        [self note:@"the checks on the main thread" :[NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]];
    }
    [NSThread detachNewThreadSelector:@selector(runInBackground) toTarget:self withObject:nil];
}

// What a plugin does on a thread of its own: file conversion, the wait for the listener, a server.
- (void)runInBackground {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    @try {
        NSFileManager *files = [NSFileManager defaultManager];
        NSString *image = [work stringByAppendingPathComponent:@"qa.dcm"];
        NSString *encoded = [work stringByAppendingPathComponent:@"encoded/qa.dcm"], *decoded = [work stringByAppendingPathComponent:@"decoded"],
                 *compressed = [work stringByAppendingPathComponent:@"compressed"];
        for (NSString *folder in [NSArray arrayWithObjects:[encoded stringByDeletingLastPathComponent], decoded, compressed, nil])
            [files createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
        DCMObject *object = [DCMObject objectWithContentsOfFile:image decodingPixelData:NO];
        BOOL wrote = [object writeToFile:encoded withTransferSyntax:[DCMTransferSyntax JPEGLSLosslessTransferSyntax] quality:0 atomically:YES];
        BOOL isEncoded = [[[DCMObject objectWithContentsOfFile:encoded decodingPixelData:NO] transferSyntax] isEncapsulated];
        [self note:@"a JPEG-LS file to decompress is written" :(wrote && isEncoded ? nil : [NSString stringWithFormat:@"wrote %d, encapsulated %d", wrote, isEncoded])];
        [DicomCompressor decompressFiles:[NSArray arrayWithObject:encoded] toDirectory:decoded];
        DCMObject *plain = [DCMObject objectWithContentsOfFile:[decoded stringByAppendingPathComponent:@"qa.dcm"] decodingPixelData:NO];
        [self note:@"+[DicomCompressor decompressFiles:toDirectory:] writes the file decompressed in the directory"
                  :(plain && ![[plain transferSyntax] isEncapsulated] && [[plain attributeValueWithName:@"Rows"] intValue] == 64 ? nil
                    : [NSString stringWithFormat:@"%@ in %@", [[plain transferSyntax] transferSyntax], [files contentsOfDirectoryAtPath:decoded error:NULL]])];
        [DicomCompressor compressFiles:[NSArray arrayWithObject:image] toDirectory:compressed];
        DCMObject *packed = [DCMObject objectWithContentsOfFile:[compressed stringByAppendingPathComponent:@"qa.dcm"] decodingPixelData:NO];
        [self note:@"+[DicomCompressor compressFiles:toDirectory:] writes the file in the directory"
                  :([[packed attributeValueWithName:@"Rows"] intValue] == 64 ? nil : [NSString stringWithFormat:@"%@", [files contentsOfDirectoryAtPath:compressed error:NULL]])];

        NSDate *start = [NSDate date];
        [ContextCleaner waitForHandledAssociations];
        [self note:@"+[ContextCleaner waitForHandledAssociations] returns when no association is under way"
                  :(-[start timeIntervalSinceNow] < 5 ? nil : [NSString stringWithFormat:@"after %.1f s", -[start timeIntervalSinceNow]])];

        // A server of the SDK with the plugin's connection class: one response the subclass makes, one file the base serves.
        NSString *root = [work stringByAppendingPathComponent:@"root"];
        [files createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];
        [@"a file under the document root" writeToFile:[root stringByAppendingPathComponent:@"file.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        HTTPServer *server = [[[HTTPServer alloc] init] autorelease];
        [server setConnectionClass:[QAConnection class]];
        [server setDocumentRoot:[NSURL fileURLWithPath:root]];
        [server setPort:0];
        NSError *error = nil;
        BOOL started = [server start:&error];
        UInt16 port = [server port];
        [self note:@"an HTTPServer of the plugin starts" :(started && port ? nil : [NSString stringWithFormat:@"%@, port %d", error, port])];
        if (started && port) {
            NSString *made = [NSString stringWithContentsOfURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/qa-made", port]] encoding:NSUTF8StringEncoding error:&error];
            [self note:@"the plugin's subclass of HTTPConnection makes the response" :([made isEqual:@"made by the plugin's connection"] ? nil : [NSString stringWithFormat:@"%@ %@", made, error])];
            NSString *served = [NSString stringWithContentsOfURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/file.txt", port]] encoding:NSUTF8StringEncoding error:&error];
            [self note:@"HTTPConnection serves a file under the document root" :([served isEqual:@"a file under the document root"] ? nil : [NSString stringWithFormat:@"%@ %@", served, error])];
            [self note:@"the server stops" :([server stop] ? nil : @"-stop answered NO")];
        }
    } @catch (NSException *exception) {
        [self note:@"the checks on the plugin's thread" :[NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]];
    }
    @synchronized (report) {
        [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:NULL]
            writeToFile:[NSString stringWithUTF8String:getenv("QA_LEGACY_CLASSES_REPORT")] atomically:YES];
    }
    [pool release];
}

@end
'''


def build_plugin(folder):
    """QALegacyClasses.horosplugin in `folder`, built as a plugin of the former SDK was."""
    bundle = folder / 'QALegacyClasses.horosplugin'
    (bundle / 'Contents/MacOS').mkdir(parents=True)
    with open(bundle / 'Contents/Info.plist', 'wb') as handle:
        plistlib.dump({'CFBundleExecutable': 'QALegacyClasses', 'CFBundleIdentifier': 'qa.legacy.classes',
                       'CFBundleName': 'QALegacyClasses', 'CFBundlePackageType': 'BNDL', 'CFBundleVersion': '1',
                       'NSPrincipalClass': 'QALegacyClasses', 'pluginType': 'Database',
                       'MenuTitles': ['QA Legacy Classes']}, handle)
    source = folder / 'QALegacyClasses.m'
    source.write_text(PLUGIN.replace('INTERFACES', interfaces()).replace('NAMED_COUNT', str(len(NAMED))))
    binary = bundle / 'Contents/MacOS/QALegacyClasses'
    built = subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-bundle', '-undefined', 'dynamic_lookup', '-arch', 'arm64',
                            '-arch', 'x86_64', '-mmacosx-version-min=11.0', '-Wno-deprecated-declarations',
                            '-Wno-objc-protocol-method-implementation', '-framework', 'Cocoa', str(source), '-o', str(binary)],
                           capture_output=True, text=True)
    if built.returncode:
        raise SystemExit('FAIL: the plugin does not build: ' + built.stderr[-3000:])
    looked_up = subprocess.run(['nm', '-arch', 'arm64', '-u', str(binary)], capture_output=True, text=True, check=True).stdout
    unnamed = [name for name in NAMED if f'_OBJC_CLASS_$_{name}\n' not in looked_up]
    if unnamed:
        raise SystemExit('FAIL: the plugin does not look up the class symbol of ' + ', '.join(unnamed))
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
    asked = selectors()
    with tempfile.TemporaryDirectory(prefix='isix-legacy-classes-') as folder:
        folder = Path(folder).resolve()
        bundle = build_plugin(folder)
        test_root, work, report = folder / 'root', folder / 'work', folder / 'report.json'
        work.mkdir()
        lists = {'SUPERCLASSES': superclasses(), 'ANCESTRY': [list(pair) for pair in ANCESTRY], 'SELECTORS': asked}
        environment = {'QA_LEGACY_CLASSES_REPORT': str(report), 'QA_LEGACY_CLASSES_WORK': str(work)}
        for name, value in lists.items():
            with open(folder / f'{name.lower()}.plist', 'wb') as handle:
                plistlib.dump(value, handle)
            environment[f'QA_LEGACY_CLASSES_{name}'] = str(folder / f'{name.lower()}.plist')
        log = folder / 'app.log'
        process = native_app.launch(test_root, log, ['--LoadPlugin', str(bundle)], app=args.app, environment=environment)
        try:
            deadline = time.monotonic() + 240
            while not report.is_file() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.5)
            time.sleep(1)
        finally:
            native_app.stop(process)
        text = log.read_text(errors='replace')
        if not report.is_file():
            lines = [line for line in text.splitlines() if 'QALegacyClasses' in line or 'Plugin' in line or 'symbol not found' in line
                     or 'unrecognized selector' in line or 'xception' in line]
            print('FAIL: the plugin wrote no report; the application said:\n  ' + '\n  '.join(lines[-12:])[-3000:])
            return 1
        found = json.loads(report.read_text())
    failures = [f'{check}: {result}' for check, result in sorted(found.items()) if result != 'ok']
    expected = ({f'{name} : {parent}' for name, parent in superclasses().items()}
                | {f'{sub} descends from {ancestor}' for sub, ancestor in ANCESTRY}
                | {f'{name} {kind}{selector}' for name, kind, selector in asked})
    failures += [f'{check}: not checked' for check in sorted(expected - set(found))]
    if 'unrecognized selector' in text:
        failures.append('the application logged an unrecognized selector')
    for failure in failures:
        print('FAIL: ' + failure)
    if failures:
        return 1
    print(f'PASS: a plugin built as for Horos and OsiriX loads naming the {len(NAMED)} classes of the SDK that are back, finds '
          f'each with its superclass and the {len(ANCESTRY)} lines of descent, is answered by the {len(asked)} selectors the '
          f'registry lists for them, and by the {len(found) - len(expected)} uses it makes of them, with four subclasses of its own')
    return 0


if __name__ == '__main__':
    sys.exit(main())
