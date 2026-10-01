"""Build a driver against the real N2ManagedDatabase.mm (#964, #965).

The tests of the Core Data queue migration compile Nitrogen/Sources/N2ManagedDatabase.mm
and Horos/Sources/HorosObjCException.m as they are, with small stand-ins for the
entities and for what else N2ManagedDatabase.mm imports, and link them with a
Swift driver. `MODEL` gives the driver a Study/Series/Image model and
`TestDatabase`, an N2ManagedDatabase subclass over it.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

STUBS = {
    'Horos-Swift.h': '''
#import <Foundation/Foundation.h>
@interface HorosIndexRecovery : NSObject
+ (NSString*)diagnosisForError:(NSError*)e path:(NSString*)p;
+ (NSInteger)recoverableFileCountBesideIndexAtPath:(NSString*)p;
+ (BOOL)indexCanBeSetAsideForError:(NSError*)e;
+ (NSString*)preservedPathForIndexAtPath:(NSString*)p;
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
    'DCMTKQueryNode.h': '#import <Foundation/Foundation.h>\n@interface DCMTKQueryNode : NSObject\n@end\n',
    'stubs.m': '''
#import <AppKit/AppKit.h>
#import "Horos-Swift.h"
#import "NSFileManager+N2.h"
#import "NSException+N2.h"
#import "DCMTKQueryNode.h"
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
    'Bridge.h': '#import "N2ManagedDatabase.h"\n#import "HorosObjCException.h"\n#import "Entities.h"\n',
}

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
    study.properties = [attribute("studyInstanceUID"), studySeries]
    series.properties = [attribute("seriesDICOMUID"), seriesStudy, seriesImages]
    image.properties = [attribute("sopInstanceUID"), imageSeries]
    let m = NSManagedObjectModel(); m.entities = [study, series, image]; return m
}
let sharedModel = model()

final class TestDatabase: N2ManagedDatabase {
    override var managedObjectModel: NSManagedObjectModel! { sharedModel }
    override func saveModel() -> Bool { false }
}
'''


def build(driver, swift_sources=(), work=None):
    """Compile the driver (MODEL is prepended) with the real sources.

    Returns (binary, work directory, error text or None). The caller removes the
    work directory."""
    work = Path(work or tempfile.mkdtemp(prefix='horos-n2-harness-'))
    work.mkdir(parents=True, exist_ok=True)
    for name, text in STUBS.items():
        (work / name).write_text(text)
    for source in ('Nitrogen/Sources/N2ManagedDatabase.mm', 'Nitrogen/Sources/N2ManagedDatabase.h',
                   'Horos/Sources/HorosObjCException.m', 'Horos/Sources/HorosObjCException.h',
                   'Horos/Sources/HorosAlertPanel.m', 'Horos/Sources/HorosAlertPanel.h'):
        shutil.copy(ROOT / source, work / Path(source).name)
    (work / 'main.swift').write_text(MODEL + driver)
    sdk = subprocess.run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], capture_output=True, text=True).stdout.strip()
    objects = []
    for source, arc in (('N2ManagedDatabase.mm', False), ('HorosObjCException.m', True), ('HorosAlertPanel.m', False),
                        ('stubs.m', True), ('Entities.m', True)):
        out = work / (source + '.o')
        result = subprocess.run(['xcrun', 'clang', '-c', '-isysroot', sdk, '-I', str(work), '-w',
                                 '-fobjc-arc' if arc else '-fno-objc-arc', str(work / source), '-o', str(out)],
                                capture_output=True, text=True)
        if result.returncode != 0:
            return None, work, '%s did not compile:\n%s' % (source, result.stderr[-3000:])
        objects.append(str(out))
    binary = work / 'driver'
    result = subprocess.run(['xcrun', 'swiftc', '-sdk', sdk, '-import-objc-header', str(work / 'Bridge.h'), '-I', str(work)]
                            + [str(ROOT / source) for source in swift_sources] + [str(work / 'main.swift')] + objects
                            + ['-framework', 'CoreData', '-framework', 'AppKit', '-lc++', '-o', str(binary)],
                            capture_output=True, text=True)
    if result.returncode != 0:
        return None, work, 'the driver did not compile:\n%s' % result.stderr[-4000:]
    return binary, work, None


def run(binary, arguments, timeout=120):
    """Run with Core Data's multithreading assertions on; (status, results, stderr)."""
    result = subprocess.run([str(binary)] + list(arguments) + ['-com.apple.CoreData.ConcurrencyDebug', '1'],
                            capture_output=True, text=True, timeout=timeout)
    results = dict(line.split('\t', 1) for line in result.stdout.splitlines() if '\t' in line)
    return result.returncode, results, result.stdout, result.stderr
