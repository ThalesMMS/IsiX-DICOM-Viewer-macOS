"""Build a driver against the real N2ManagedDatabase.

The tests of the Core Data queue migration compile N2ManagedDatabase as it is:
its Swift implementation (Nitrogen/Sources/N2ManagedDatabase*.swift and
N2ManagedObjectContext.swift), the Objective-C it keeps
(N2ManagedDatabase+CAPI.m), Horos/Sources/HorosObjCException.m and
HorosAlertPanel.m, the index recovery policy (IndexRecovery.swift) and the
module IsiXDatabase, with small stand-ins for the entities and for what else
it uses, and link them with a Swift driver. `MODEL` gives the driver a
Study/Series/Image model and `TestDatabase`, an N2ManagedDatabase subclass
over it.

`build(driver, revision=...)` builds the same driver against the Objective-C++
N2ManagedDatabase.mm of an earlier revision, read from git, for the tests that
compare the two.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import isix_modules  # noqa: E402

SWIFT = ('Nitrogen/Sources/N2ManagedDatabase.swift', 'Nitrogen/Sources/N2ManagedDatabase+Store.swift',
         'Nitrogen/Sources/N2ManagedDatabase+Objects.swift', 'Nitrogen/Sources/N2ManagedObjectContext.swift',
         'Horos/Sources/IndexRecovery.swift')
OBJC = ('Nitrogen/Sources/N2ManagedDatabase+CAPI.m',)
SHARED = ('Horos/Sources/HorosObjCException.m', 'Horos/Sources/HorosObjCException.h',
          'Horos/Sources/HorosAlertPanel.m', 'Horos/Sources/HorosAlertPanel.h')

ENTITIES = {
    'Entities.h': '''
#import <CoreData/CoreData.h>
@interface DicomImage : NSManagedObject
- (NSString*)sopInstanceUID;
@end
@interface DicomSeries : NSManagedObject
@property (nonatomic, retain) NSSet *images;
- (NSNumber*)rawNoFiles;
@end
@interface DicomStudy : NSManagedObject
@property (nonatomic, retain) NSSet *series;
- (NSNumber*)rawNoFiles;
@end
''',
    'Entities.m': '''
#import "Entities.h"
@implementation DicomImage
- (NSString*)sopInstanceUID { [self willAccessValueForKey:@"sopInstanceUID"]; id v = [self primitiveValueForKey:@"sopInstanceUID"]; [self didAccessValueForKey:@"sopInstanceUID"]; return v; }
@end
@implementation DicomSeries
@dynamic images;
- (NSNumber*)rawNoFiles { return @(self.images.count); }
@end
@implementation DicomStudy
@dynamic series;
- (NSNumber*)rawNoFiles { NSInteger n = 0; for (DicomSeries *s in self.series) n += s.rawNoFiles.integerValue; return @(n); }
@end
''',
}

# What the Swift implementation uses from the rest of the application.
STUBS = dict(ENTITIES, **{
    'N2Debug.h': '''
#import <Foundation/Foundation.h>
#define N2LogStackTrace(...) NSLog(__VA_ARGS__)
#define N2LogExceptionWithStackTrace(e, ...) NSLog(@"%@", e)
#define N2LogException(e, ...) NSLog(@"%@", e)
void N2LogStackTraceMessage(NSString* message);
void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf);
''',
    'NSFileManager+N2.h': '''
#import <Foundation/Foundation.h>
@interface NSFileManager (N2)
- (NSString*)confirmDirectoryAtPath:(NSString*)p;
@end
''',
    'NSException+N2.h': '#import <Foundation/Foundation.h>\nextern NSString* const N2ErrorDomain;\n',
    'stubs.m': '''
#import <AppKit/AppKit.h>
#import "N2Debug.h"
#import "NSFileManager+N2.h"
#import "NSException+N2.h"
NSString* const N2ErrorDomain = @"N2";
void N2LogStackTraceMessage(NSString* message) { NSLog(@"%@", message); }
void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf) { NSLog(@"%s: %@", pf, e); }
@implementation NSFileManager (N2)
- (NSString*)confirmDirectoryAtPath:(NSString*)p { [self createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:NULL]; return p; }
@end
''',
    'Stubs.swift': '''
import Foundation
// The query node is Swift in the application; -objectWithID: answers one as it is.
@objc(DCMTKQueryNode) class DCMTKQueryNode: NSObject {}
''',
    'Bridge.h': '#import "N2ManagedDatabase.h"\n#import "HorosObjCException.h"\n#import "HorosAlertPanel.h"\n'
                '#import "N2Debug.h"\n#import "NSFileManager+N2.h"\n#import "NSException+N2.h"\n#import "Entities.h"\n',
})

# What N2ManagedDatabase.mm of an earlier revision imports.
LEGACY_STUBS = dict(ENTITIES, **{
    'Horos-Swift.h': '''
#import <Foundation/Foundation.h>
@interface HorosIndexRecovery : NSObject
+ (NSString*)diagnosisForError:(NSError*)e path:(NSString*)p;
+ (NSInteger)recoverableFileCountBesideIndexAtPath:(NSString*)p;
+ (BOOL)indexCanBeSetAsideForError:(NSError*)e;
+ (NSString*)preservedPathForIndexAtPath:(NSString*)p;
@end
// The query node is Swift: N2ManagedDatabase.mm finds it in the generated header.
@interface DCMTKQueryNode : NSObject
@end
''',
    'N2Debug.h': '''
#import <Foundation/Foundation.h>
#define N2LogStackTrace(...) NSLog(__VA_ARGS__)
#define N2LogExceptionWithStackTrace(e, ...) NSLog(@"%@", e)
#define N2LogException(e, ...) NSLog(@"%@", e)
''',
    'NSFileManager+N2.h': '''
#import <Foundation/Foundation.h>
@interface NSFileManager (N2)
- (void)confirmDirectoryAtPath:(NSString*)p;
@end
''',
    'NSException+N2.h': '#import <Foundation/Foundation.h>\nextern NSString* const N2ErrorDomain;\n',
    'stubs.m': '''
#import <AppKit/AppKit.h>
#import "Horos-Swift.h"
#import "NSFileManager+N2.h"
#import "NSException+N2.h"
NSString* const N2ErrorDomain = @"N2";
@implementation HorosIndexRecovery
+ (NSString*)diagnosisForError:(NSError*)e path:(NSString*)p { return @""; }
+ (NSInteger)recoverableFileCountBesideIndexAtPath:(NSString*)p { return -1; }
+ (BOOL)indexCanBeSetAsideForError:(NSError*)e { return NO; }
+ (NSString*)preservedPathForIndexAtPath:(NSString*)p { return p; }
@end
@implementation NSFileManager (N2)
- (void)confirmDirectoryAtPath:(NSString*)p { [self createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:NULL]; }
@end
@implementation DCMTKQueryNode
@end
''',
    'Bridge.h': '#import "N2ManagedDatabase.h"\n#import "HorosObjCException.h"\n#import "Entities.h"\n',
})

MODEL = r'''
import CoreData
import Foundation

func emit(_ key: String, _ value: String) { print("\(key)\t\(value)"); fflush(stdout) }

func attribute(_ name: String) -> NSAttributeDescription {
    let a = NSAttributeDescription(); a.name = name; a.attributeType = .stringAttributeType; a.isOptional = true; return a
}
func model() -> NSManagedObjectModel {
    let study = NSEntityDescription(); study.name = "Study"; study.managedObjectClassName = "DicomStudy"
    let series = NSEntityDescription(); series.name = "Series"; series.managedObjectClassName = "DicomSeries"
    let image = NSEntityDescription(); image.name = "Image"; image.managedObjectClassName = "DicomImage"
    func relation(_ name: String, _ to: NSEntityDescription, many: Bool) -> NSRelationshipDescription {
        let r = NSRelationshipDescription(); r.name = name; r.destinationEntity = to; r.isOptional = true
        r.minCount = 0; r.maxCount = many ? 0 : 1; r.deleteRule = many ? .cascadeDeleteRule : .nullifyDeleteRule; return r
    }
    let studySeries = relation("series", series, many: true), seriesStudy = relation("study", study, many: false)
    studySeries.inverseRelationship = seriesStudy; seriesStudy.inverseRelationship = studySeries
    let seriesImages = relation("images", image, many: true), imageSeries = relation("series", series, many: false)
    seriesImages.inverseRelationship = imageSeries; imageSeries.inverseRelationship = seriesImages
    study.properties = [attribute("studyInstanceUID"), attribute("stateText"), attribute("comment"), studySeries]
    series.properties = [attribute("seriesDICOMUID"), attribute("stateText"), attribute("comment"), seriesStudy, seriesImages]
    image.properties = [attribute("sopInstanceUID"), imageSeries]
    let m = NSManagedObjectModel(); m.entities = [study, series, image]; return m
}
let sharedModel = model()

final class TestDatabase: N2ManagedDatabase {
    override var managedObjectModel: NSManagedObjectModel! { sharedModel }
    override func saveModel() -> Bool { false }
}
'''


def git_text(revision, relative):
    """The file at an earlier revision, read from git."""
    return subprocess.run(['git', '-C', str(ROOT), 'show', '%s:%s' % (revision, relative)],
                          capture_output=True, text=True, check=True).stdout


def compile_objc(work, sdk, sources, flags=()):
    """Objects of (file name, ARC) pairs in `work`; (objects, error text or None)."""
    objects = []
    for source, arc in sources:
        out = work / (source + '.o')
        result = subprocess.run(['xcrun', 'clang', '-c', '-isysroot', sdk, '-I', str(work), '-w', *flags,
                                 '-fobjc-arc' if arc else '-fno-objc-arc', str(work / source), '-o', str(out)],
                                capture_output=True, text=True)
        if result.returncode != 0:
            return None, '%s did not compile:\n%s' % (source, result.stderr[-3000:])
        objects.append(str(out))
    return objects, None


def prepare(work, revision=None):
    """Write the stand-ins and the real sources into `work`. Returns the
    Objective-C files to compile there as (name, ARC) pairs, the Swift files and
    the swiftc flags that import IsiXDatabase. With `revision`, N2ManagedDatabase
    is the Objective-C++ .mm/.h of that revision, read from git."""
    for source in SHARED:
        shutil.copy(ROOT / source, work / Path(source).name)
    if revision:
        for name, text in LEGACY_STUBS.items():
            (work / name).write_text(text)
        for source in ('Nitrogen/Sources/N2ManagedDatabase.mm', 'Nitrogen/Sources/N2ManagedDatabase.h'):
            (work / Path(source).name).write_text(git_text(revision, source))
        objc = [('N2ManagedDatabase.mm', False)]
        return objc + [('HorosObjCException.m', True), ('HorosAlertPanel.m', False), ('stubs.m', True)], [], []
    for name, text in STUBS.items():
        (work / name).write_text(text)
    for source in OBJC + ('Nitrogen/Sources/N2ManagedDatabase.h',):
        shutil.copy(ROOT / source, work / Path(source).name)
    objc = [(Path(source).name, False) for source in OBJC]
    swift = [str(ROOT / source) for source in SWIFT] + [str(work / 'Stubs.swift')]
    module = isix_modules.module_flags('IsiXDatabase', work / 'modules')
    return objc + [('HorosObjCException.m', True), ('HorosAlertPanel.m', False), ('stubs.m', True)], swift, module


def build(driver, swift_sources=(), work=None, revision=None, swift_flags=(), objc_flags=()):
    """Compile the driver (MODEL is prepended) with the real sources: those of
    the checkout, or N2ManagedDatabase.mm/.h of `revision` read from git.

    Returns (binary, work directory, error text or None). The caller removes the
    work directory."""
    work = Path(work or tempfile.mkdtemp(prefix='horos-n2-harness-')).resolve()
    work.mkdir(parents=True, exist_ok=True)
    sdk = subprocess.run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], capture_output=True, text=True).stdout.strip()
    try:
        objc, swift, module = prepare(work, revision)
    except subprocess.CalledProcessError as error:
        return None, work, 'IsiXDatabase did not compile: %s' % error
    (work / 'main.swift').write_text(MODEL + driver)
    swift += [str(ROOT / source) for source in swift_sources] + [str(work / 'main.swift')]
    objects, error = compile_objc(work, sdk, objc + [('Entities.m', True)], objc_flags)
    if error:
        return None, work, error
    binary = work / 'driver'
    result = subprocess.run(['xcrun', 'swiftc', '-sdk', sdk, '-import-objc-header', str(work / 'Bridge.h'),
                             '-I', str(work)] + module + list(swift_flags) + swift + objects
                            + ['-framework', 'CoreData', '-framework', 'AppKit', '-lc++', '-o', str(binary)],
                            capture_output=True, text=True)
    if result.returncode != 0:
        return None, work, 'the driver did not compile:\n%s' % result.stderr[-4000:]
    return binary, work, None


def library(work):
    """The real N2ManagedDatabase of the checkout, for a test that brings its own
    entities and doubles: a static library in `work` of its Swift, its +CAPI.m,
    HorosObjCException.m, HorosAlertPanel.m and the stand-ins (their C functions
    are weak, so a test may define its own), built as Release (NDEBUG, no DEBUG).
    Returns (folder holding N2ManagedDatabase.h and the headers it needs, the
    archives to link). The test does not compile HorosObjCException.m itself."""
    work = Path(work).resolve()
    work.mkdir(parents=True, exist_ok=True)
    sdk = subprocess.run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], capture_output=True, text=True).stdout.strip()
    objc, swift, module = prepare(work)
    stubs = (work / 'stubs.m').read_text()
    for symbol in ('NSString* const N2ErrorDomain', 'void N2LogStackTraceMessage', 'void _N2LogExceptionImpl'):
        stubs = stubs.replace(symbol, '__attribute__((weak)) ' + symbol, 1)
    (work / 'stubs.m').write_text(stubs)
    (work / 'Library.h').write_text('#import "N2ManagedDatabase.h"\n#import "HorosObjCException.h"\n#import "HorosAlertPanel.h"\n'
                                    '#import "N2Debug.h"\n#import "NSFileManager+N2.h"\n#import "NSException+N2.h"\n')
    objects, error = compile_objc(work, sdk, objc, ['-DNDEBUG', '-Os'])
    if error:
        raise RuntimeError(error)
    swift_library = work / 'libN2ManagedDatabaseSwift.a'
    subprocess.run(['xcrun', 'swiftc', '-sdk', sdk, '-O', '-parse-as-library', '-emit-library', '-static',
                    '-module-name', 'N2ManagedDatabaseHarness', '-import-objc-header', str(work / 'Library.h'),
                    '-I', str(work)] + module + swift + ['-o', str(swift_library)], check=True, capture_output=True)
    objc_library = work / 'libN2ManagedDatabaseObjC.a'
    subprocess.run(['xcrun', 'libtool', '-static', '-o', str(objc_library)] + objects, check=True, capture_output=True)
    modules = work / 'modules'
    return work, [str(swift_library), str(objc_library)] + [str(modules / ('lib%s.a' % name)) for name in
                                                            ['IsiXDatabase'] + isix_modules.dependencies('IsiXDatabase')]


def run(binary, arguments, timeout=120):
    """Run with Core Data's multithreading assertions on; (status, results, stderr)."""
    result = subprocess.run([str(binary)] + list(arguments) + ['-com.apple.CoreData.ConcurrencyDebug', '1'],
                            capture_output=True, text=True, timeout=timeout)
    results = dict(line.split('\t', 1) for line in result.stdout.splitlines() if '\t' in line)
    return result.returncode, results, result.stdout, result.stderr
