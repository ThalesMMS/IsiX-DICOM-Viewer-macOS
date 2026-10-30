#!/usr/bin/env python3
"""The listener fetches with exactly the conditions the Objective-C++ listener built.

The listener's C-FIND, C-MOVE and C-GET turned their identifier into the
conditions of a Core Data fetch in -[OsiriXSCPDataHandler
predicateForDataset:compressedSOPInstancePredicate:seriesLevelPredicate:].
They are IsiXDICOMNetwork's SCPQueryMatching now, given the identifier's
attributes as the DCMTK adapter reads them (IsiXDCMTKDataset) and the
application's dates, character sets and patient name search through the
listener's ListenerMatchingEnvironment. This compares the two, from the
revision that still has the Objective-C++ handler:

- the old method and its helpers are compiled as they were, against the
  Debug build's DCMTK and the DCMCalendarDate of the last revision that has
  DCM.framework (the date type the old handler read dates with);
- the new side is the module, the adapter's IsiXDCMTKDataset and the
  listener's own environment and attribute reading, cut from
  SCPDatabaseSession+Find.swift and SCPDatabaseSession.swift;
- the browser's patient name search and the string decoding are the same
  stand-ins on both sides;
- for every identifier below - each key of each level, with values, empty
  and absent, wildcards, date and time ranges, lists, unknown keys and
  unknown levels - the three conditions (the fetch, the series of an IMAGE
  request and its instances) must print the same.

Exits 2 without the Debug build, or when the history does not reach a
revision with the Objective-C++ handler (a shallow clone).
"""
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dcmtk_build import BUILD, ROOT, dcmtk_flags  # noqa: E402
import history_reference  # noqa: E402
import isix_modules  # noqa: E402

HANDLER = 'Horos/Sources/OsiriXSCPDataHandler.mm'
reference = history_reference.before_removal(HANDLER)
if reference is None and subprocess.run(['git', '-C', str(ROOT), 'cat-file', '-e', 'HEAD:' + HANDLER],
                                        capture_output=True).returncode == 0:
    reference = 'HEAD'
if reference is None:
    print('skipped: the history does not reach a revision with ' + HANDLER)
    sys.exit(2)
if not (BUILD / 'DCMTK.build/Install/lib/libdcmnet.a').is_file():
    print('skipped: needs the Debug build\'s DCMTK from script/build_and_run.sh --verify')
    sys.exit(2)
# The former DCMCalendarDate, from the last revision that has DCM.framework.
CALENDAR = 'DCM Framework/DCMCalendarDate.m'
calendar_revision = 'HEAD' if subprocess.run(['git', '-C', str(ROOT), 'cat-file', '-e', 'HEAD:' + CALENDAR],
                                             capture_output=True).returncode == 0 else history_reference.before_removal(CALENDAR)
if calendar_revision is None:
    print('skipped: the history does not reach a revision with ' + CALENDAR)
    sys.exit(2)

old = subprocess.run(['git', '-C', str(ROOT), 'show', f'{reference}:{HANDLER}'], capture_output=True, check=True).stdout.decode('latin1')


def method(source, signature):
    at = source.index(signature)
    opening = source.index('{', at)
    depth, index = 0, opening
    while True:
        depth += (source[index] == '{') - (source[index] == '}')
        index += 1
        if depth == 0:
            return source[at:index]


OLD_METHODS = '\n'.join(method(old, signature) for signature in (
    '-(NSTimeInterval) endOfDay:(DCMCalendarDate *)day', '-(NSTimeInterval) startOfDay:(DCMCalendarDate *)day',
    '- (NSPredicate*) predicateWithString: (NSString*) s forField: (NSString*) f any: (BOOL) any',
    '- (NSPredicate*) predicateWithString: (NSString*) s forField: (NSString*) f\n',
    '- (NSPredicate *)predicateForDataset:(DcmDataset *)dataset'))

find = (ROOT / 'Horos/Sources/SCPDatabaseSession+Find.swift').read_text()
ENVIRONMENT = find[find.index('struct ListenerMatchingEnvironment: SCPMatchingEnvironment {'):]
ENVIRONMENT = ENVIRONMENT[:ENVIRONMENT.index('\n}\n') + 3]
session = (ROOT / 'Horos/Sources/SCPDatabaseSession.swift').read_text()
ELEMENTS = method(session, '    static func elements(of identifier: IsiXDCMTKDataset) -> [SCPIdentifierElement] {')
FETCH = method(find, '    func fetchPredicates(_ identifier: IsiXDCMTKDataset, elements: [SCPIdentifierElement], level: String?) -> SCPFetchPredicates {')
for needle in ('let characterSet = SCPQueryMatching.characterSet(ofSpecificCharacterSet: declared)',
               'return SCPQueryMatching.predicates(level: level, elements: elements, characterSet: characterSet,',
               'environment: ListenerMatchingEnvironment())'):
    if needle not in FETCH:
        print('FAIL: the listener no longer matches through SCPQueryMatching as this test expects: ' + needle)
        sys.exit(1)

# The application's stand-ins, the same for both sides.
HEADER = r'''
#import <Foundation/Foundation.h>
#import <DCM/DCMCalendarDate.h>
#import "IsiXDCMTKDataset.h"
NS_ASSUME_NONNULL_BEGIN
@interface BrowserController : NSObject
+ (nullable BrowserController *)currentBrowser;
- (nullable NSPredicate *)patientsnamePredicate:(nullable NSString *)name soundex:(BOOL)soundex;
@end
@interface NSString (HorosTest)
// As the application's DICOMToNSString.swift declares it.
+ (nullable NSString *)stringWithUTF8String:(const char * _Null_unspecified)bytes DICOMEncoding:(nullable NSString *)encoding
    NS_SWIFT_NAME(string(withUTF8String:dicomEncoding:));
+ (NSStringEncoding)encodingForDICOMCharacterSet:(NSString *)name;
@end
@interface DicomImage : NSObject
+ (NSData *)sopInstanceUIDEncodeString:(NSString *)uid;
@end
#ifdef __cplusplus
extern "C" {
#endif
/// The identifier of `pairs` ([tag, value or NSNull]) as the adapter holds it.
IsiXDCMTKDataset *HorosTestIdentifier(NSArray *pairs);
/// The old handler's three conditions of it, printed; "nil" for none.
NSArray<NSString *> *HorosTestOldPredicates(IsiXDCMTKDataset *identifier);
#ifdef __cplusplus
}
#endif
NS_ASSUME_NONNULL_END
'''

OLD_PROGRAM = r'''
#include "HorosDCMTKCompatibility.h"
#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dctk.h>
#import "harness.h"
#include "IsiXDCMTKInternal.hpp"
#define N2LogExceptionWithStackTrace(e) NSLog(@"%@", e)

@implementation BrowserController
+ (BrowserController *)currentBrowser { static BrowserController *browser; if (!browser) browser = [BrowserController new]; return browser; }
- (NSPredicate *)patientsnamePredicate:(NSString *)name soundex:(BOOL)soundex
{
    // The browser's search: universal for "*", a condition otherwise.
    if ([[name stringByReplacingOccurrencesOfString:@"*" withString:@""] length] == 0)
        return [NSCompoundPredicate andPredicateWithSubpredicates:@[]];
    return [NSPredicate predicateWithFormat:@"name LIKE[cd] %@", name];
}
@end
@implementation NSString (HorosTest)
+ (NSString *)stringWithUTF8String:(const char *)bytes DICOMEncoding:(NSString *)encoding
{
    NSString *text = [NSString stringWithCString:bytes encoding:NSUTF8StringEncoding];
    if (!text) text = [NSString stringWithCString:bytes encoding:NSISOLatin1StringEncoding];
    return [encoding isEqualToString:@"ISO_IR 101"] ? [@"L2:" stringByAppendingString:text] : text;
}
+ (NSStringEncoding)encodingForDICOMCharacterSet:(NSString *)name { return NSISOLatin1StringEncoding; }
@end
@implementation DicomImage
+ (NSData *)sopInstanceUIDEncodeString:(NSString *)uid { return [uid dataUsingEncoding:NSUTF8StringEncoding]; }
@end

@interface OsiriXSCPDataHandler : NSObject
{
    NSString *specificCharacterSet;
    NSStringEncoding encoding;
}
@end
@implementation OsiriXSCPDataHandler
METHODS
@end

IsiXDCMTKDataset *HorosTestIdentifier(NSArray *pairs)
{
    DcmDataset *dataset = new DcmDataset();
    for (NSArray *pair in pairs) {
        unsigned tag = [pair[0] unsignedIntValue];
        DcmTagKey key(tag >> 16, tag & 0xffff);
        if ([pair[1] isKindOfClass:[NSNull class]]) dataset->insertEmptyElement(key, OFTrue);
        else dataset->putAndInsertString(key, [pair[1] UTF8String], OFTrue);
    }
    return IsiXDCMTKDatasetTakingOwnership(dataset);
}

NSArray<NSString *> *HorosTestOldPredicates(IsiXDCMTKDataset *identifier)
{
    OsiriXSCPDataHandler *handler = [[OsiriXSCPDataHandler alloc] init];
    NSPredicate *instances = nil, *series = nil;
    NSPredicate *fetch = [handler predicateForDataset:IsiXDCMTKDatasetStorage(identifier)
                       compressedSOPInstancePredicate:&instances seriesLevelPredicate:&series];
    NSArray *printed = @[fetch ? fetch.predicateFormat : @"nil", series ? series.predicateFormat : @"nil",
                         instances ? instances.predicateFormat : @"nil"];
    [handler release];
    return printed;
}
'''.replace('METHODS', OLD_METHODS)

# Each case: a level (None: no Query/Retrieve Level), then [tag, value or None].
T = {
    'SpecificCharacterSet': 0x00080005, 'QueryRetrieveLevel': 0x00080052, 'PatientName': 0x00100010,
    'PatientID': 0x00100020, 'AccessionNumber': 0x00080050, 'StudyInstanceUID': 0x0020000D, 'StudyID': 0x00200010,
    'StudyDescription': 0x00081030, 'InterpretationStatusID': 0x4008010C, 'ImageComments': 0x00204000,
    'StudyComments': 0x00324000, 'InstitutionName': 0x00080080, 'ReferringPhysicianName': 0x00080090,
    'PerformingPhysicianName': 0x00081050, 'ModalitiesInStudy': 0x00080061, 'Modality': 0x00080060,
    'PatientBirthDate': 0x00100030, 'StudyDate': 0x00080020, 'StudyTime': 0x00080030,
    'NumberOfStudyRelatedInstances': 0x00201208, 'SeriesInstanceUID': 0x0020000E, 'SeriesDescription': 0x0008103E,
    'SeriesNumber': 0x00200011, 'SeriesDate': 0x00080021, 'SeriesTime': 0x00080031, 'SOPInstanceUID': 0x00080018,
    'InstanceNumber': 0x00200013, 'NumberOfFrames': 0x00280008, 'PatientSex': 0x00100040, 'Private': 0x00091010,
}
STUDY_KEYS = ['PatientName', 'PatientID', 'AccessionNumber', 'StudyInstanceUID', 'StudyID', 'StudyDescription',
              'InterpretationStatusID', 'ImageComments', 'StudyComments', 'InstitutionName', 'ReferringPhysicianName',
              'PerformingPhysicianName', 'ModalitiesInStudy', 'Modality', 'PatientBirthDate', 'StudyDate', 'StudyTime',
              'NumberOfStudyRelatedInstances', 'PatientSex', 'SeriesInstanceUID', 'Private']
SERIES_KEYS = ['StudyInstanceUID', 'SeriesInstanceUID', 'SeriesDescription', 'SeriesNumber', 'Modality', 'SeriesDate',
               'SeriesTime', 'PatientName', 'Private']
IMAGE_KEYS = ['StudyInstanceUID', 'SeriesInstanceUID', 'SOPInstanceUID', 'InstanceNumber', 'NumberOfFrames', 'Modality',
              'Private']
VALUES = {
    'PatientName': ['DOE^JANE', '*', 'DO*', ''], 'PatientID': ['P1', 'P*', '*1', '*1*', 'P*1X', '*', ''],
    'AccessionNumber': ['A1', 'A*'], 'StudyInstanceUID': ['1.2.3'], 'StudyID': ['7'], 'StudyDescription': ['BRAIN*', 'CT HEAD'],
    'InterpretationStatusID': ['READ'], 'ImageComments': ['*NOTE*', 'NOTE'], 'StudyComments': ['NOTE'],
    'InstitutionName': ['ISIX*'], 'ReferringPhysicianName': ['SMITH*'], 'PerformingPhysicianName': ['*JONES'],
    'ModalitiesInStudy': ['CT', 'CT\\MR', 'CT\\MR\\SR'], 'Modality': ['CT', 'CT\\MR'],
    'PatientBirthDate': ['19800102', '19800102-19900102', '-19900102', '19800102-'],
    'StudyDate': ['20260102', '20260102-20260105', '-20260105', '20260102-', '20260102-20260105-20260107'],
    'StudyTime': ['101500', '080000-170000', '-120000', '120000-'],
    'NumberOfStudyRelatedInstances': ['4'], 'PatientSex': ['F'], 'SeriesInstanceUID': ['1.2.3.4'], 'Private': ['X'],
    'SeriesDescription': ['AX*', 'AXIAL'], 'SeriesNumber': ['3'], 'SeriesDate': ['20260102', '20260102-20260103', '-20260103'],
    'SeriesTime': ['101500', '080000-090000', '090000-'], 'SOPInstanceUID': ['1.2.3.4.5', '1.2.3.4.5\\1.2.3.4.6'],
    'InstanceNumber': ['12', 'x'], 'NumberOfFrames': ['3'],
}
CASES = []
for level, keys in (('STUDY', STUDY_KEYS), ('SERIES', SERIES_KEYS), ('IMAGE', IMAGE_KEYS)):
    CASES.append((level, []))
    for key in keys:
        CASES.append((level, [[T[key], None]]))
        for value in VALUES[key]:
            CASES.append((level, [[T[key], value]]))
    CASES.append((level, [[T[key], VALUES[key][0]] for key in keys]))
    CASES.append((level, [[T['SpecificCharacterSet'], 'ISO_IR 101'], *[[T[key], VALUES[key][-1]] for key in keys]]))
# Dates and times of one request bound one range together.
CASES += [('STUDY', [[T['StudyDate'], '20260102-20260105'], [T['StudyTime'], '080000-170000']]),
          ('STUDY', [[T['StudyDate'], '20260102-'], [T['StudyTime'], '120000-']]),
          ('STUDY', [[T['StudyDate'], '-20260105'], [T['StudyTime'], '-120000']]),
          ('SERIES', [[T['SeriesDate'], '20260102-20260103'], [T['SeriesTime'], '080000-090000']]),
          ('STUDY', [[T['SpecificCharacterSet'], 'ISO_IR 192\\ISO 2022 IR 87'], [T['StudyDescription'], 'CT*']]),
          ('PATIENT', [[T['PatientID'], 'P1']]), ('study', [[T['PatientID'], 'P1']])]
# A request without a level, or with an empty one, is refused before it is matched (SCPRequestCheck).


DRIVER = r'''
import Foundation
import IsiXDICOMNetwork
import IsiXDICOMFile

ENVIRONMENT
enum Session {
ELEMENTS
}
let cases = try! JSONSerialization.jsonObject(with: Data(CommandLine.arguments[1].utf8)) as! [[Any]]
var differences = 0
for (index, item) in cases.enumerated() {
    let level = item[0] as? String
    var pairs: [[Any]] = []
    if let level { pairs.append([NSNumber(value: 0x00080052), level]) }
    pairs += (item[1] as! [[Any]]).map { [$0[0], $0[1] is NSNull ? NSNull() : $0[1]] }
    let identifier = HorosTestIdentifier(pairs)
    let old = HorosTestOldPredicates(identifier)
    let elements = Session.elements(of: identifier)
    let declared = identifier.rawValue(forTag: DICOMTag.specificCharacterSet.rawValue).map { Array($0) }
    let raw = identifier.rawValue(forTag: DICOMTag.queryRetrieveLevel.rawValue).map { String(decoding: $0, as: UTF8.self) }
    let new = SCPQueryMatching.predicates(level: raw, elements: elements,
                                          characterSet: SCPQueryMatching.characterSet(ofSpecificCharacterSet: declared),
                                          environment: ListenerMatchingEnvironment())
    let printed: [String] = [new.predicate?.predicateFormat ?? "nil", new.seriesLevel?.predicateFormat ?? "nil",
                   new.compressedSOPInstance?.predicateFormat ?? "nil"]
    if printed != old {
        differences += 1
        print("DIFFERENT case \(index) \(item): old \(old) new \(printed)")
    }
}
print("compared \(cases.count) identifiers, \(differences) different")
exit(differences == 0 ? 0 : 1)
'''.replace('ENVIRONMENT', ENVIRONMENT).replace('ELEMENTS', ELEMENTS)

flags = dcmtk_flags('dcmnet', 'dcmtls')
ADAPTERS = ROOT / 'Horos/Sources/Adapters/DCMTK'
with tempfile.TemporaryDirectory(prefix='horos-scp-matching-') as temporary:
    folder = Path(temporary)
    (folder / 'bin').mkdir()
    (folder / 'DCM').mkdir()
    for name in ('DCMCalendarDate.h', 'DCMCalendarDate.m'):
        (folder / name).write_bytes(history_reference.show(calendar_revision, 'DCM Framework/' + name))
    os.symlink(folder / 'DCMCalendarDate.h', folder / 'DCM/DCMCalendarDate.h')
    (folder / 'DCM.h').write_text('#import <Foundation/Foundation.h>\n#define DCMDEBUG 0\n#import "DCMCalendarDate.h"\n')
    (folder / 'harness.h').write_text(HEADER)
    (folder / 'old.mm').write_text(OLD_PROGRAM)
    (folder / 'driver.swift').write_text(DRIVER)
    includes = ['-I' + str(folder), '-I' + str(ADAPTERS), *[flag for flag in flags if flag.startswith('-I')]]
    objects = []
    calendar = folder / 'DCMCalendarDate.o'
    subprocess.run(['xcrun', 'clang', '-w', '-fno-objc-arc', '-I' + str(folder), '-c', str(folder / 'DCMCalendarDate.m'),
                    '-o', str(calendar)], check=True)
    objects.append(str(calendar))
    for source, arc in ((folder / 'old.mm', '-fno-objc-arc'), (ADAPTERS / 'IsiXDCMTKDataset.mm', '-fobjc-arc'),
                        (ADAPTERS / 'IsiXDCMTKError.mm', '-fobjc-arc')):
        obj = folder / (source.stem + '.o')
        built = subprocess.run(['xcrun', 'clang++', '-std=gnu++17', '-w', arc, '-fobjc-exceptions', *includes, '-c', str(source),
                                '-o', str(obj)], capture_output=True, text=True)
        if built.returncode:
            print(built.stderr[-4000:])
            print('FAIL: %s does not compile' % source.name)
            sys.exit(1)
        objects.append(str(obj))
    modules = isix_modules.module_flags('IsiXDICOMNetwork', folder / 'modules')
    # The listener reads dates with the DICOM date type of IsiXDICOMFile.
    isix_modules.build_module('IsiXImaging', folder / 'modules')
    modules += isix_modules.module_flags('IsiXDICOMFile', folder / 'modules', ['-I', str(folder / 'modules')]) + ['-lIsiXImaging']
    executable = folder / 'bin/check'
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-suppress-warnings', '-module-cache-path', str(folder / 'cache'),
                            '-import-objc-header', str(folder / 'harness.h'), '-Xcc', '-I' + str(ADAPTERS), '-Xcc', '-I' + str(folder),
                            *modules, str(folder / 'driver.swift'), *objects, *[flag for flag in flags if not flag.startswith('-I')],
                            '-lc++', '-framework', 'Foundation', '-o', str(executable)],
                           capture_output=True, text=True)
    if built.returncode:
        print(built.stderr[-4000:])
        print('FAIL: the listener\'s matching does not compile with the old handler')
        sys.exit(1)
    run = subprocess.run([str(executable), json.dumps(CASES)], capture_output=True, text=True, timeout=300)
    print(run.stdout[-6000:], end='')
    if run.returncode:
        print(run.stderr[-2000:])
        print('FAIL: the listener\'s conditions differ from those of %s (exit %d)' % (reference[:12], run.returncode))
        sys.exit(1)
print('PASS: for %d identifiers the listener fetches with the conditions of the Objective-C++ handler of %s'
      % (len(CASES), reference[:12]))
