#!/usr/bin/env python3
"""Time the query window's local reads before and after #964, for tools/ab_protocol.py.

`build` compiles one probe from the real N2ManagedDatabase.mm, HorosObjCException.m
and HorosLocalQueryReader.swift, with stand-ins for the entities (the same ones
tests/test-private-queue-local-reads.py uses), at Debug or Release optimisation.
The probe holds both reads:

* `baseline`: what QueryController and DCMTKQueryNode did off the main thread
  before #964, copied as it was - a confined context from -independentContext,
  locked, fetching Study objects and reading them with valueForKey:, a new
  context for every row count;
* `candidate`: HorosLocalQueryReader, on a private-queue context.

Run it as `probe <baseline|candidate> <store>`; it fills the store the first
time, reads it from a background thread and prints one JSON object with the
median of 20 repetitions of each metric: index_ms, count_us and sop_ms.

    python3 tools/probe-private-queue-reads.py build --configuration Release --out probe
    python3 tools/ab_protocol.py run --out ab.json --rounds 30 \\
        --variant 'A=probe baseline store/Database.sql' --variant 'B=probe candidate store/Database.sql'
"""
import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

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
- (NSNumber*)rawNoFiles { [self.managedObjectContext lock]; NSNumber *n = @(self.images.count); [self.managedObjectContext unlock]; return n; }
@end
@implementation DicomStudy
@dynamic series;
- (NSNumber*)rawNoFiles { NSInteger n = 0; [self.managedObjectContext lock]; for (DicomSeries *s in self.series) n += s.rawNoFiles.integerValue; [self.managedObjectContext unlock]; return @(n); }
@end
''',
    # The reads as QueryController.mm and DCMTKQueryNode.mm made them before #964,
    # on the context -independentContext returned off the main thread.
    'Baseline.h': '''
#import <CoreData/CoreData.h>
@class N2ManagedDatabase;
@interface Baseline : NSObject
+ (NSArray*)studyIndexOfDatabase:(N2ManagedDatabase*)database;
+ (NSInteger)fileCountOfStudy:(NSManagedObjectID*)studyID inDatabase:(N2ManagedDatabase*)database;
+ (NSArray*)SOPInstanceUIDsOfStudy:(NSString*)uid inDatabase:(N2ManagedDatabase*)database;
@end
''',
    'Baseline.m': '''
#import "Baseline.h"
#import "N2ManagedDatabase.h"
#import "Entities.h"
@implementation Baseline
+ (NSArray*)studyIndexOfDatabase:(N2ManagedDatabase*)database {
    NSArray *local_studyArrayID = nil, *local_studyArrayInstanceUID = nil;
    NSManagedObjectContext *independentContext = [database independentContext];
    if( independentContext)
    {
        [independentContext lock];
        @try
        {
            NSError *error = nil;
            NSFetchRequest *request = [[NSFetchRequest alloc] init];
            request.entity = [NSEntityDescription entityForName: @"Study" inManagedObjectContext: independentContext];
            request.predicate = [NSPredicate predicateWithValue: YES];
            NSArray *result = [independentContext executeFetchRequest:request error: &error];
            local_studyArrayID = [result valueForKey: @"objectID"];
            local_studyArrayInstanceUID = [result valueForKey:@"studyInstanceUID"];
        }
        @finally { [independentContext unlock]; }
    }
    return @[local_studyArrayID ?: @[], local_studyArrayInstanceUID ?: @[]];
}
+ (NSInteger)fileCountOfStudy:(NSManagedObjectID*)studyID inDatabase:(N2ManagedDatabase*)database {
    NSManagedObjectContext *context = [database independentContext];
    DicomStudy *s = (DicomStudy*) [context existingObjectWithID: studyID error:NULL];
    return [[s valueForKey: @"rawNoFiles"] integerValue];
}
+ (NSArray*)SOPInstanceUIDsOfStudy:(NSString*)uid inDatabase:(N2ManagedDatabase*)database {
    NSMutableArray *localObjectUIDs = [NSMutableArray array];
    NSError *error = nil;
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName: @"Study"];
    [request setPredicate: [NSPredicate predicateWithFormat: @"studyInstanceUID == %@", uid]];
    NSManagedObjectContext *context = [database independentContext];
    DicomStudy *localStudy = [[context executeFetchRequest: request error: &error] lastObject];
    for( DicomSeries *s in [localStudy valueForKey: @"series"])
        [localObjectUIDs addObjectsFromArray: [[[s images] valueForKey: @"sopInstanceUID"] allObjects]];
    return localObjectUIDs;
}
@end
''',
    'Bridge.h': '#import "N2ManagedDatabase.h"\n#import "HorosObjCException.h"\n#import "Entities.h"\n#import "Baseline.h"\n',
}

DRIVER = r'''
import CoreData
import Foundation

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
    let studyUID = attribute("studyInstanceUID"); studyUID.isIndexed = true
    study.properties = [studyUID, studySeries]
    series.properties = [attribute("seriesDICOMUID"), seriesStudy, seriesImages]
    image.properties = [attribute("sopInstanceUID"), imageSeries]
    let m = NSManagedObjectModel(); m.entities = [study, series, image]; return m
}
let sharedModel = model()
final class ProbeDatabase: N2ManagedDatabase {
    override var managedObjectModel: NSManagedObjectModel! { sharedModel }
    override func saveModel() -> Bool { false }
}

let variant = CommandLine.arguments[1], path = CommandLine.arguments[2]
let fresh = !FileManager.default.fileExists(atPath: path)
let database = ProbeDatabase(path: path)!
if fresh {
    let context = database.managedObjectContext!
    for s in 0..<2000 {
        let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
        study.setValue("1.2.\(s)", forKey: "studyInstanceUID")
        for r in 0..<2 {
            let series = NSEntityDescription.insertNewObject(forEntityName: "Series", into: context)
            series.setValue("1.2.\(s).\(r)", forKey: "seriesDICOMUID"); series.setValue(study, forKey: "study")
            for i in 0..<5 {
                let image = NSEntityDescription.insertNewObject(forEntityName: "Image", into: context)
                image.setValue("1.2.\(s).\(r).\(i)", forKey: "sopInstanceUID"); image.setValue(series, forKey: "series")
            }
        }
    }
    _ = database.save()
}

func median(_ values: [Double]) -> Double { let v = values.sorted(); return v[v.count / 2] }
// The pool is drained inside the timed interval: the confined contexts of the
// baseline are autoreleased, and would otherwise go away after it.
func time(_ body: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try autoreleasepool { try body() }
    return Double(DispatchTime.now().uptimeNanoseconds - start)
}

var output = ""
let done = DispatchSemaphore(value: 0)
Thread {
    autoreleasepool {
        let candidate = variant == "candidate"
        var index: [Double] = [], count: [Double] = [], sop: [Double] = []
        var ids: [NSManagedObjectID] = []
        do {
            for _ in 0..<20 {
                try autoreleasepool {
                    index.append(try time {
                        if candidate { ids = try HorosLocalQueryReader.studyIndex(of: database).objectIDs }
                        else { ids = (Baseline.studyIndex(of: database)[0] as! [NSManagedObjectID]) }
                    } / 1e6)
                }
            }
            precondition(ids.count == 2000)
            for n in 0..<20 {
                let id = ids[(n * 97) % ids.count]
                try autoreleasepool {
                    var files = 0
                    count.append(try time {
                        files = candidate ? try HorosLocalQueryReader.fileCount(ofStudy: id, seriesInstanceUID: nil, in: database).intValue
                            : Baseline.fileCount(ofStudy: id, in: database)
                    } / 1e3)
                    precondition(files == 10)
                    var uids = 0
                    sop.append(try time {
                        uids = candidate ? try HorosLocalQueryReader.sopInstanceUIDs(ofStudyInstanceUID: "1.2.\((n * 97) % 2000)", seriesInstanceUID: nil, in: database).count
                            : Baseline.sopInstanceUIDs(ofStudy: "1.2.\((n * 97) % 2000)", in: database).count
                    } / 1e6)
                    precondition(uids == 10)
                }
            }
            output = "{\"index_ms\": \(median(index)), \"count_us\": \(median(count)), \"sop_ms\": \(median(sop))}"
        } catch { output = "{\"error\": \"\(error)\"}" }
    }
    done.signal()
}.start()
done.wait()
print(output)
'''


def build(configuration, out):
    sdk = subprocess.run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], capture_output=True, text=True).stdout.strip()
    clang_opt = '-O0' if configuration == 'Debug' else '-Os'
    swift_opt = '-Onone' if configuration == 'Debug' else '-O'
    work = Path(tempfile.mkdtemp(prefix='horos-private-read-probe-'))
    try:
        for name, text in STUBS.items():
            (work / name).write_text(text)
        for source in ('Nitrogen/Sources/N2ManagedDatabase.mm', 'Nitrogen/Sources/N2ManagedDatabase.h',
                       'Horos/Sources/HorosObjCException.m', 'Horos/Sources/HorosObjCException.h'):
            shutil.copy(ROOT / source, work / Path(source).name)
        (work / 'main.swift').write_text(DRIVER)
        objects = []
        for source, arc in (('N2ManagedDatabase.mm', False), ('HorosObjCException.m', True), ('stubs.m', True),
                            ('Entities.m', True), ('Baseline.m', True)):
            obj = work / (source + '.o')
            subprocess.run(['xcrun', 'clang', '-c', clang_opt, '-isysroot', sdk, '-I', str(work), '-w',
                            '-fobjc-arc' if arc else '-fno-objc-arc', str(work / source), '-o', str(obj)], check=True)
            objects.append(str(obj))
        subprocess.run(['xcrun', 'swiftc', swift_opt, '-sdk', sdk, '-import-objc-header', str(work / 'Bridge.h'),
                        '-I', str(work), str(ROOT / 'Horos/Sources/HorosLocalQueryReader.swift'), str(work / 'main.swift')]
                       + objects + ['-framework', 'CoreData', '-framework', 'AppKit', '-lc++', '-o', str(out)], check=True)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    b = sub.add_parser('build')
    b.add_argument('--configuration', choices=('Debug', 'Release'), required=True)
    b.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    build(args.configuration, args.out)
    print(args.out)


if __name__ == '__main__':
    sys.exit(main())
