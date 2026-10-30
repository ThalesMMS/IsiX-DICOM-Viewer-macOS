#!/usr/bin/env python3
"""The query nodes ask for exactly what the Objective-C++ nodes asked for.

The identifiers the query nodes send were built in DCMTKQueryNode.mm and its
level subclasses with insertEmptyElement and putAndInsertString. The nodes
are Swift now: IsiXDICOMNetwork's QueryIdentifiers builds each identifier, and
the DCMTK adapter (IsiXDCMTKDataset) turns it into the dataset the association
carries. This compares the two, from the revision that still has the
Objective-C++ nodes:

- the bodies of the old -queryPrototype and -moveDataset of every level, and
  the datasets the old node built inline (the walk of a study's series and
  instances, the relational fallbacks, the listing of a retrieve inventory and
  of a DICOMweb retrieve, the IMAGE-level retrieves and their second pass),
  are compiled as they were against the Debug build's DCMTK, with each
  preference both on and off;
- the module's identifiers for the same inputs go through the adapter;
- both datasets are encoded in Explicit VR Little Endian and must be the same
  bytes.

Also from that revision: the filter keys of the Query window and the attribute
each one set (and whether as a date range), the WADO-URI transfer syntax of
each setting with its image quality, and the services' abstract syntaxes
against DCMTK's UIDs.

Exits 2 without the Debug build's DCMTK, or when the history does not reach a
revision with the Objective-C++ nodes (a shallow clone).
"""
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dcmtk_build import INSTALL, ROOT, dcmtk_flags  # noqa: E402
import history_reference  # noqa: E402

NODE = 'Horos/Sources/DCMTKQueryNode.mm'
reference = history_reference.before_removal(NODE)
if reference is None and subprocess.run(['git', '-C', str(ROOT), 'cat-file', '-e', 'HEAD:' + NODE],
                                        capture_output=True).returncode == 0:
    reference = 'HEAD'
if reference is None:
    print('skipped: the history does not reach a revision with ' + NODE)
    sys.exit(2)


def old(path):
    return history_reference.show(reference, path).decode('latin1')


flags = dcmtk_flags('dcmnet')
failures = []


def method(text, signature):
    """The body of the method whose signature starts with `signature`, braces included."""
    at = text.index(signature)
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[opening:index + 1]
    raise ValueError(signature)


def snippet(body, variable, occurrence=0):
    """The statements that fill the dataset `variable` declared in `body`, up to its use."""
    declarations = [match.end() for match in re.finditer(r'DcmDataset %s;' % variable, body)]
    rest = body[declarations[occurrence]:]
    statements = []
    for line in rest.splitlines():
        if 'queryWithValues' in line or 'setupNetworkWithSyntax' in line:
            break
        if re.match(r'\s*%s\.(putAndInsertString|putAndInsertOFStringArray|insertEmptyElement)\(' % variable, line):
            statements.append(line.strip())
    if not statements:
        raise ValueError(variable)
    return statements


# --- the old datasets, as the Objective-C++ nodes built them ------------------
node = old(NODE)
levels = {name: old('Horos/Sources/DCMTK%sQueryNode.mm' % name) for name in ('Root', 'Study', 'Series', 'Image')}
PROTOTYPES = {
    'studies': method(levels['Root'], '- (DcmDataset *)queryPrototype'),
    'series': method(levels['Study'], '- (DcmDataset *)queryPrototype'),
    'images': method(levels['Series'], '- (DcmDataset *)queryPrototype'),
    'retrieveStudy': method(levels['Study'], '- (DcmDataset *)moveDataset'),
    'retrieveSeries': method(levels['Series'], '- (DcmDataset *)moveDataset'),
    'retrieveImage': method(levels['Image'], '- (DcmDataset *)moveDataset'),
}
walk = method(node, '- (BOOL) queryImagesHierarchicallyForStudy:')
parallel = method(node, '- (BOOL) queryDICOMwebImagesOfSeries:')
move = method(node, '- (void) move:(NSDictionary*) dict retrieveMode:')
SNIPPETS = {
    'nodeOfStudy': snippet(parallel, 'identifier'),
    'parallelInstanceListing': snippet(parallel, 'dataset'),
    'seriesListing': snippet(walk, 'seriesDataset'),
    'instanceListing': snippet(walk, 'dataset'),
    'relationalWADO': snippet(method(node, '- (void) WADOCFindThread'), 'dataset'),
    'relationalCFind': snippet(method(node, '- (void) CFINDThread'), 'dataset'),
    'inventoryListing': snippet(method(node, '- (void)beginRetrieveInventoryForCGET:'), 'identifier'),
    'dicomwebListing': snippet(method(node, '- (BOOL)retrieveDICOMweb'), 'query'),
    'retry': snippet(method(node, '- (void)retryMissingDIMSEInstances:'), 'dataset'),
    'imageLevelBySeries': snippet(move, 'dataset', 0),
    'imageLevelWithoutSeries': snippet(move, 'dataset', 1),
}
# The statements read these; each is given the value the Swift side is given.
for name, statements in SNIPPETS.items():
    SNIPPETS[name] = [line.replace('[self inventoryStudyUID]', 'inventoryStudyUID')
                      .replace('[self inventorySeriesUID]', 'inventorySeriesUID') for line in statements]

# Each case: the old function, and the Swift expression of the module.
SWIFT = {
    'studies': 'QueryIdentifiers.studies(options: options)',
    'series': 'QueryIdentifiers.series(ofStudy: uid, options: options)',
    'images': 'QueryIdentifiers.images(ofSeries: uid, study: studyUID, options: options)',
    'retrieveStudy': 'QueryIdentifiers.retrieve(study: uid)',
    'retrieveSeries': 'QueryIdentifiers.retrieve(series: uid, study: studyUID)',
    'retrieveImage': 'QueryIdentifiers.retrieve(image: uid)',
    'nodeOfStudy': 'QueryIdentifiers.node(study: study)',
    'parallelInstanceListing': 'QueryIdentifiers.instanceListing(series: series, study: study)',
    'seriesListing': 'QueryIdentifiers.seriesListing(study: study)',
    'instanceListing': 'QueryIdentifiers.instanceListing(series: series, study: study)',
    'relationalWADO': 'QueryIdentifiers.relationalInstanceListing(study: uid)',
    'relationalCFind': 'QueryIdentifiers.relationalInstanceListing(study: study)',
    'inventoryListing': 'QueryIdentifiers.instanceListing(series: series, study: study, instanceNumbers: false)',
    'dicomwebListing': 'QueryIdentifiers.instanceListing(series: series, study: study)',
    'retry': 'QueryIdentifiers.retrieve(instances: uids, series: series, study: study)',
    'imageLevelBySeries': 'QueryIdentifiers.retrieve(instances: uids, series: series, study: study)',
    'imageLevelWithoutSeries': 'QueryIdentifiers.retrieve(instances: uids, series: nil, study: study)',
}
assert set(SWIFT) == set(PROTOTYPES) | set(SNIPPETS)
STUDY, SERIES, IMAGE = '1.2.826.0.1.3680043.10.1125.7', '1.2.826.0.1.3680043.10.1125.7.1', '1.2.826.0.1.3680043.10.1125.7.1.3'
UIDS = [IMAGE, '1.2.826.0.1.3680043.10.1125.7.1.4', '1.2.826.0.1.3680043.10.1125.7.1.5']
# A query node's own UID is its study, series or image, by level.
OWN = {'series': STUDY, 'retrieveStudy': STUDY, 'relationalWADO': STUDY, 'images': SERIES, 'retrieveSeries': SERIES,
       'retrieveImage': IMAGE}

# --- the filter keys, the WADO-URI syntaxes and the services, of that revision
keys_body = method(node, '- (void) queryWithValues:(NSArray *)values dataset:(DcmDataset*) dataset')
OLD_KEYS = {}
for key, branch in re.findall(r'\[key isEqualToString:@"(\w+)"\]\)\s*\{(.*?)\}', keys_body, re.S):
    tag = re.search(r'putAndInsertString\(DCM_(\w+)', branch).group(1)
    OLD_KEYS.setdefault(key, ('dateRange' if 'queryString' in branch else 'text', tag))
dictionary = (INSTALL / 'include/dcmtk/dcmdata/dcdeftag.h').read_text()


# The names the old node used, some of them the former DCMTK names Horos kept.
aliases = dict(re.findall(r'#define DCM_(\w+)\s+DCM_(\w+)', old('Horos/Sources/HorosDCMTKCompatibility.h')))


def tag_of(name):
    name = aliases.get(name, name)
    found = re.search(r'#define DCM_%s\s+DcmTagKey\(0x([0-9a-fA-F]{4}), 0x([0-9a-fA-F]{4})\)' % name, dictionary)
    return int(found.group(1) + found.group(2), 16)


syntax = method(node, '+ (NSString*) syntaxStringFor:')
codes = re.search(r'enum TransferSyntaxCodes\s*\{.*?\};', old('Horos/Sources/SendController.h'), re.S).group(0)
SERVICES = {'verification': 'UID_VerificationSOPClass', 'findStudyRoot': 'UID_FINDStudyRootQueryRetrieveInformationModel',
            'moveStudyRoot': 'UID_MOVEStudyRootQueryRetrieveInformationModel',
            'getStudyRoot': 'UID_GETStudyRootQueryRetrieveInformationModel',
            'getPatientRoot': 'UID_GETPatientRootQueryRetrieveInformationModel',
            'getPatientStudyOnly': 'UID_GETPatientStudyOnlyQueryRetrieveInformationModel'}
SETTINGS = range(-1, 18)


def objc_string(text):
    return '@"%s"' % text


OLD_PROGRAM = r'''
#import <Foundation/Foundation.h>
#import "IsiXDCMTKDataset.h"
#include "IsiXDCMTKInternal.hpp"
#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dctk.h>
#include <dcmtk/dcmdata/dcostrmb.h>
#include <cstdio>
#include <string>

CODES

static NSString *_uid, *_studyInstanceUID, *studyInstanceUID, *seriesInstanceUID, *studyUID, *study, *series, *seriesUID,
    *inventoryStudyUID, *inventorySeriesUID;
static NSArray *uids, *subArray;
static NSDictionary *seriesUIDsToRetrieve;

PROTOTYPES
SNIPPETS

@interface Old : NSObject
+ (NSString*)syntaxStringFor:(int)ts imageQuality:(int*)q;
@end
@implementation Old
SYNTAX
@end

// The bytes a dataset goes out as, and a readable form of it for a failure.
static std::string encoded(DcmDataset *dataset)
{
    dataset->chooseRepresentation(EXS_LittleEndianExplicit, NULL);
    Uint32 size = 65536;
    char *buffer = new char[size];
    DcmOutputBufferStream stream(buffer, size);
    dataset->transferInit();
    dataset->write(stream, EXS_LittleEndianExplicit, EET_ExplicitLength, NULL);
    dataset->transferEnd();
    void *written = NULL;
    offile_off_t length = 0;
    stream.flushBuffer(written, length);
    std::string bytes(buffer, (size_t)length);
    delete[] buffer;
    return bytes;
}

static std::string readable(DcmDataset *dataset)
{
    std::string text;
    for (unsigned long i = 0; i < dataset->card(); i++) {
        DcmElement *element = dataset->getElement(i);
        OFString value;
        element->getOFStringArray(value);
        char tag[16];
        snprintf(tag, sizeof tag, "(%04x,%04x)", element->getGTag(), element->getETag());
        text += std::string(tag) + "=" + value.c_str() + " ";
    }
    return text;
}

static int failures = 0;

int main(int argc, char **argv)
{
    @autoreleasepool {
        NSDictionary *swift = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:NULL];
        study = studyInstanceUID = studyUID = inventoryStudyUID = _studyInstanceUID = STUDY_UID;
        series = seriesInstanceUID = seriesUID = inventorySeriesUID = SERIES_UID;
        uids = subArray = UIDS;
        seriesUIDsToRetrieve = @{ SERIES_UID: UIDS };
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        unsigned compared = 0;
        for (NSDictionary *run in swift[@"runs"]) {
            [defaults registerDefaults:run[@"preferences"]];
            NSDictionary *own = OWN;
            for (NSString *name in CASES) {
                _uid = own[name] ?: STUDY_UID;
                DcmDataset *mine = build(name);
                IsiXDCMTKDataset *theirs = [[IsiXDCMTKDataset alloc] init];
                for (NSArray *element in run[@"cases"][name]) {
                    uint32_t tag = [element[0] unsignedIntValue];
                    NSString *value = element[1];
                    NSError *error = nil;
                    BOOL done = value.length ? [theirs putValue:[value dataUsingEncoding:NSUTF8StringEncoding] forTag:tag error:&error]
                                             : [theirs insertEmptyElementWithTag:tag error:&error];
                    if (!done) printf("FAIL: %s: the adapter refused (%08x): %s\n", name.UTF8String, tag, error.description.UTF8String);
                }
                DcmDataset *adapted = IsiXDCMTKDatasetStorage(theirs);
                if (encoded(mine) != encoded(adapted)) {
                    printf("FAIL: %s with %s\n  before: %s\n  now:    %s\n", name.UTF8String, [run[@"label"] UTF8String],
                           readable(mine).c_str(), readable(adapted).c_str());
                    failures++;
                }
                compared++;
                delete mine;
            }
        }
        printf("COMPARED %u\n", compared);
        for (int setting = -1; setting < 18; setting++) {
            int quality = -1;
            NSString *query = [Old syntaxStringFor:setting imageQuality:&quality];
            printf("WADO %d %s %d\n", setting, query.UTF8String, quality);
        }
SERVICES
    }
    return failures ? 1 : 0;
}
'''


def function(name, body):
    return 'static DcmDataset *old_%s()\n%s\n' % (name, body)


def inline(name, variable, statements):
    lines = '\n    '.join(statement.replace(variable + '.', 'dataset->') for statement in statements)
    return 'static DcmDataset *old_%s()\n{\n    DcmDataset *dataset = new DcmDataset();\n    %s\n    return dataset;\n}\n' % (
        name, lines)


VARIABLES = {'nodeOfStudy': 'identifier', 'parallelInstanceListing': 'dataset', 'seriesListing': 'seriesDataset',
             'instanceListing': 'dataset', 'relationalWADO': 'dataset', 'relationalCFind': 'dataset',
             'inventoryListing': 'identifier', 'dicomwebListing': 'query', 'retry': 'dataset',
             'imageLevelBySeries': 'dataset', 'imageLevelWithoutSeries': 'dataset'}
prototypes = ''.join(function(name, body) for name, body in PROTOTYPES.items())
snippets = ''.join(inline(name, VARIABLES[name], statements) for name, statements in SNIPPETS.items())
cases = list(SWIFT)
builder = 'static DcmDataset *build(NSString *name)\n{\n' + ''.join(
    '    if ([name isEqualToString:@"%s"]) return old_%s();\n' % (name, name) for name in cases) + '    return NULL;\n}\n'
services = ''.join('        printf("SERVICE %s %%s\\n", %s);\n' % (name, uid) for name, uid in SERVICES.items())
program = (OLD_PROGRAM.replace('CODES', codes)
           .replace('PROTOTYPES', prototypes)
           .replace('SNIPPETS', snippets + builder)
           .replace('SYNTAX', '+ (NSString*)syntaxStringFor:(int)ts imageQuality:(int*)q\n' + syntax + '\n')
           .replace('SERVICES', services)
           .replace('STUDY_UID', objc_string(STUDY)).replace('SERIES_UID', objc_string(SERIES))
           .replace('UIDS', '@[' + ', '.join(objc_string(uid) for uid in UIDS) + ']')
           .replace('OWN', '@{' + ', '.join('@"%s": @"%s"' % item for item in OWN.items()) + '}')
           .replace('CASES', '@[' + ', '.join(objc_string(name) for name in cases) + ']'))

# --- the same, from the module ------------------------------------------------
swift_cases = '\n'.join('        "%s": %s,' % (name, expression) for name, expression in SWIFT.items())
DRIVER = r'''
import Foundation
let study = "%(study)s", series = "%(series)s"
let uids = [%(uids)s]
let own: [String: String] = [%(own)s]
func elements(_ identifier: DICOMQueryIdentifier) -> [[Any]] {
    identifier.elements.map { [NSNumber(value: $0.tag.rawValue), String(decoding: $0.value, as: UTF8.self)] }
}
var runs: [[String: Any]] = []
for mask in 0..<8 {
    let options = QueryReturnKeyOptions(bodyPartExamined: mask & 1 != 0, commentsAndStatus: mask & 2 != 0,
                                        modalitiesInStudy: mask & 4 != 0)
    var cases: [String: [[Any]]] = [:]
    for name in [%(names)s] {
        let uid = own[name] ?? study
        let studyUID = study
        let identifiers: [String: DICOMQueryIdentifier] = [
%(cases)s
        ]
        cases[name] = elements(identifiers[name]!)
    }
    runs.append(["label": "preferences \(mask)", "cases": cases,
                 "preferences": ["CFINDBodyPartExaminedSupport": mask & 1 != 0, "CFINDCommentsAndStatusSupport": mask & 2 != 0,
                                 "SupportQRModalitiesinStudy": mask & 4 != 0]])
}
var keys: [String: [Any]] = [:]
for key in [%(keys)s] {
    switch QueryFilterAttribute.named(key) {
    case .text(let tag)?: keys[key] = ["text", NSNumber(value: tag.rawValue)]
    case .dateRange(let tag)?: keys[key] = ["dateRange", NSNumber(value: tag.rawValue)]
    case nil: keys[key] = ["none", 0]
    }
}
var wado: [String: [Any]] = [:]
for setting in -1..<18 {
    let (parameter, quality) = WADOURITransferSyntax.parameter(forSetting: setting)
    wado[String(setting)] = [parameter, quality]
}
var services: [String: String] = [:]
for service in QueryRetrieveService.allCases { services["\(service)"] = service.rawValue }
let out = try! JSONSerialization.data(withJSONObject: ["runs": runs, "keys": keys, "wado": wado, "services": services])
FileManager.default.createFile(atPath: CommandLine.arguments[1], contents: out)
''' % {'study': STUDY, 'series': SERIES, 'uids': ', '.join('"%s"' % uid for uid in UIDS),
       'own': ', '.join('"%s": "%s"' % item for item in OWN.items()), 'names': ', '.join('"%s"' % name for name in cases),
       'cases': swift_cases, 'keys': ', '.join('"%s"' % key for key in OLD_KEYS)}

MODULE = ROOT / 'Modules/IsiXDICOMNetwork/Sources'
ADAPTERS = ROOT / 'Horos/Sources/Adapters/DCMTK'
with tempfile.TemporaryDirectory(prefix='isix-query-identifiers-') as temporary:
    folder = Path(temporary)
    (folder / 'main.swift').write_text(DRIVER)
    built = subprocess.run(['xcrun', 'swiftc', *map(str, sorted(MODULE.glob('*.swift'))), str(folder / 'main.swift'),
                            '-o', str(folder / 'module')], capture_output=True, text=True)
    if built.returncode:
        print(built.stderr[-3000:])
        print('FAIL: the module does not compile with the driver')
        sys.exit(1)
    subprocess.run([str(folder / 'module'), str(folder / 'module.json')], check=True, timeout=60)
    module = json.loads((folder / 'module.json').read_text())

    (folder / 'old.mm').write_text(program)
    built = subprocess.run(['xcrun', 'clang++', '-std=gnu++17', '-fobjc-arc', '-w', '-I' + str(ADAPTERS),
                            str(ADAPTERS / 'IsiXDCMTKError.mm'), str(ADAPTERS / 'IsiXDCMTKDataset.mm'), str(folder / 'old.mm'),
                            *flags, '-framework', 'Foundation', '-o', str(folder / 'old')], capture_output=True, text=True)
    if built.returncode:
        print(built.stderr[-4000:])
        print('FAIL: the old datasets do not compile against the build\'s DCMTK')
        sys.exit(1)
    run = subprocess.run([str(folder / 'old'), str(folder / 'module.json')], capture_output=True, text=True, timeout=60)
    lines = run.stdout.splitlines()
    failures += [line[len('FAIL: '):] for line in lines if line.startswith('FAIL: ')]
    failures += [line for line in lines if line.startswith('  ')]
    if run.returncode and not failures:
        failures.append('the comparison did not run: ' + run.stderr[-800:])
    compared = next((int(line.split()[1]) for line in lines if line.startswith('COMPARED ')), 0)
    if compared != len(cases) * 8:
        failures.append('%d datasets compared, not %d' % (compared, len(cases) * 8))

    for line in lines:
        if line.startswith('WADO '):
            _, setting, query, quality = line.split(' ')
            if module['wado'][setting] != [query, int(quality)]:
                failures.append('WADO-URI setting %s: %s quality %s before, %s now' % (setting, query, quality, module['wado'][setting]))
        if line.startswith('SERVICE '):
            _, name, uid = line.split(' ')
            if module['services'].get(name) != uid:
                failures.append('the %s service is %s, not %s' % (name, module['services'].get(name), uid))
    if sum(line.startswith('WADO ') for line in lines) != len(SETTINGS) or len(module['services']) != len(SERVICES):
        failures.append('not every WADO-URI setting or service was compared')

for key, (kind, name) in OLD_KEYS.items():
    if module['keys'][key] != [kind, tag_of(name)]:
        failures.append('the filter %s set %s %s, now %s' % (key, kind, name, module['keys'][key]))
if len(OLD_KEYS) != 16:
    failures.append('only %d filter keys were read from the old node' % len(OLD_KEYS))

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: %d identifiers in 8 preference sets, %d filter keys, %d WADO-URI settings and %d services as the Objective-C++ '
      'nodes of %s had them' % (len(cases), len(OLD_KEYS), len(SETTINGS), len(SERVICES), reference[:12]))
