#!/usr/bin/env python3
"""The browser's export rules decide what their Objective-C did.

The export and sending functions of BrowserController moved from
BrowserController.m to Swift extensions of the class, with their rules in the
IsiXDatabase module (ExportRules.swift). This compiles the Objective-C of
those rules, cut out of BrowserController.m in the last revision that has it
(history_reference; the tree itself while it still has it), and the module
with swiftc, gives both the same synthetic inputs and compares what they
produce:

* +replaceNotAdmitted:preserveHyphens: on names with punctuation, accents,
  combining marks, wide and non-Latin characters;
* the patient, study and series folders of a DICOM export, with and without
  DICOMDIR (ISO 9660 components);
* the name of each exported file when the name is taken, and the renames done
  afterwards;
* where a movie export records its files (+setPath:relativeTo:...);
* the arguments given to /usr/bin/zip, and when nothing is archived;
* the private SR series an export leaves out.

    python3 tests/test-browser-export-equivalence.py [--reference REV]
"""
import argparse
import difflib
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402
import history_reference  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
BC = 'Horos/Sources/BrowserController.m'
MARK = '+ (NSMutableString*) replaceNotAdmitted:(NSString*)name preserveHyphens:(BOOL)preserveHyphens'
RULES = ROOT / 'Modules/IsiXDatabase/Sources/ExportRules.swift'

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--reference')
parser.add_argument('--dump', type=Path, help='write the records of both programs to this folder')
args = parser.parse_args()


def git(*command):
    return subprocess.run(['git', '-C', str(ROOT), *command], capture_output=True)


reference = args.reference
if reference is None:
    head = git('show', 'HEAD:' + BC)
    if (ROOT / BC).exists() and MARK in (ROOT / BC).read_bytes().decode('latin1'):
        reference = 'tree'
    elif head.returncode == 0 and MARK in head.stdout.decode('latin1'):
        reference = 'HEAD'
    else:
        reference = history_reference.before_text_removed(BC, MARK)
if reference is None:
    print('skipped: needs the history that has the Objective-C export functions of BrowserController.m')
    sys.exit(2)
if reference == 'tree':
    text = (ROOT / BC).read_bytes().decode('latin1')
else:
    shown = git('show', '%s:%s' % (reference, BC))
    if shown.returncode:
        sys.exit('FAIL: no %s at %s' % (BC, reference))
    text = shown.stdout.decode('latin1')
if MARK not in text:
    sys.exit('FAIL: %s has no Objective-C replaceNotAdmitted in %s' % (reference, BC))
if not RULES.exists():
    sys.exit('FAIL: no ExportRules.swift in IsiXDatabase')


def matching(source, start):
    depth, i = 0, start
    while i < len(source):
        c = source[i]
        if source.startswith('//', i):
            i = source.index('\n', i)
            continue
        if source.startswith('/*', i):
            i = source.index('*/', i) + 2
            continue
        if c in '"\'':
            j = i + 1
            while source[j] != c:
                j += 2 if source[j] == '\\' else 1
            i = j + 1
            continue
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise SystemExit('FAIL: unbalanced braces')


def method(signature, source=text):
    at = source.index(signature)
    while ';' in source[at:source.index('{', at)]:
        at = source.index(signature, at + 1)
    return source[at:matching(source, source.index('{', at))]


def between(start_text, end_text, within, after=0):
    at = within.index(start_text, after)
    return within[at:within.index(end_text, at)]


replace_one = method('+ (NSMutableString*) replaceNotAdmitted: (NSString*)name')
replace_two = method(MARK)
patient = method('+ (NSString*) dicomExportPatientFolderName:(NSString*) name addDICOMDIR:(BOOL) addDICOMDIR')
set_path = method('+(void)setPath:(NSString*)path relativeTo:(NSString*)dirPath forSeriesId:(int)seriesId kind:(NSString*)kind toSeriesPaths:(NSMutableDictionary*)seriesPaths')
export = method('- (NSArray*) exportDICOMFileInt: (NSMutableDictionary*) parameters')
study = between('NSString *name = [curImage valueForKeyPath: @"series.study.studyName"];', 'if (customFolderNaming)', export)
series = between('NSString *sname = [curImage valueForKeyPath: @"series.name"];', 'if (customFolderNaming)', export)
names = between('if (!addDICOMDIR)\n                    dest = [NSString stringWithFormat:@"%@/IM-', 'NSError *error = nil;', export)
renames = between('if( t != 2)', 'if( [[curImage valueForKey: @"fileType"] hasPrefix:@"DICOM"])', export)
menu = method('- (void) exportDICOMFile: (id)sender')
filter_text = between('NSPredicate *predicate = nil;', 'filesToExport = [[[dicomFiles2Export valueForKey: @"completePath"]', menu)
folders = method('+ (BOOL) encryptFilesOrFolders: (NSArray*) srcItems inZIPFile:')
# Up to the command, inside "if( names.count) {": the brace is closed here.
zip_args = between('NSString *parent = [srcFolder stringByDeletingLastPathComponent];', '[t setArguments: args];', folders) + '}\n'
flat = method('+ (void) encryptFiles: (NSArray*) srcFiles inZIPFile:')
flat_args = between('if( [password length] > 0)\n                    args = [NSArray arrayWithObjects: @"-q", @"-j"', '[t setArguments: args];', flat)

OBJC = r'''
#import <Foundation/Foundation.h>
#define N2LogExceptionWithStackTrace(e) NSLog(@"%@", e)
@interface NSString (Range)
@property(readonly) NSRange range;
@end
@implementation NSString (Range)
- (NSRange)range { return NSMakeRange(0, self.length); }
@end
@interface BrowserController : NSObject @end
@implementation BrowserController
@@REPLACE_ONE@@
@@REPLACE_TWO@@
@@PATIENT@@
@@SET_PATH@@
@end
@interface Archive : NSObject
@property(copy) NSString *archivePath;
@end
@implementation Archive
@end
static NSMutableArray *records;
static void record(NSString *format, ...) {
    va_list list; va_start(list, format);
    [records addObject:[[[NSString alloc] initWithFormat:format arguments:list] autorelease]];
    va_end(list);
}
static id orNil(id value) { return [value isEqual:@"<nil>"] ? nil : value; }
static NSString *studyFolder(id curImage, BOOL addDICOMDIR) {
    NSString *tempPath = @"";
@@STUDY@@
    return tempPath;
}
static NSString *seriesFolder(id curImage, BOOL addDICOMDIR) {
    NSString *tempPath = @"";
@@SERIES@@
    return tempPath;
}
static void fileName(NSString *tempPath, long serieCount, long imageNo, NSString *extension, BOOL addDICOMDIR, NSString *label) {
    NSString *dest = nil;
    NSMutableArray *renameArray = [NSMutableArray array];
@@NAMES@@
    [[NSData data] writeToFile:dest atomically:NO];
@@RENAMES@@
    record(@"file %@: %@ renames [%@]", label, [dest lastPathComponent], [[[renameArray valueForKey:@"newName"] valueForKey:@"lastPathComponent"] componentsJoinedByString:@","]);
}
static void zipArguments(NSArray *srcItems, NSString *password, NSString *archivePath, NSString *label) {
    NSString *srcFolder = srcItems.firstObject;
    Archive *archive = [[Archive new] autorelease];
    archive.archivePath = archivePath;
    NSTask *t = [[NSTask new] autorelease];
    NSArray *args = nil;
@@ZIP_ARGS@@
    record(@"zip %@: %@ in %@", label, args ? [args componentsJoinedByString:@"|"] : @"<none>", args ? [[t currentDirectoryPath] lastPathComponent] : @"-");
}
static void flatArguments(NSArray *subArray, NSString *password, NSString *destFile, NSString *label) {
    NSArray *args = nil;
@@FLAT_ARGS@@
    record(@"flat %@: %@", label, [args componentsJoinedByString:@"|"]);
}
int main(int argc, char **argv) { @autoreleasepool {
    records = [NSMutableArray array];
    NSString *root = @(argv[1]);
    NSArray *cases = [NSPropertyListSerialization propertyListWithData:[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"cases.plist"]] options:0 format:NULL error:NULL];
    for (NSString *name in cases[0]) {
        for (int hyphens = 0; hyphens < 2; hyphens++)
            record(@"replace %d [%@] -> [%@]", hyphens, name, [BrowserController replaceNotAdmitted:[[name copy] autorelease] preserveHyphens:hyphens]);
        for (int dicomdir = 0; dicomdir < 2; dicomdir++)
            record(@"patient %d [%@] -> [%@]", dicomdir, name, [BrowserController dicomExportPatientFolderName:orNil(name) addDICOMDIR:dicomdir]);
    }
    for (NSDictionary *c in cases[1]) {
        NSMutableDictionary *studyValues = [NSMutableDictionary dictionary], *seriesValues = [NSMutableDictionary dictionary];
        if (orNil(c[@"studyName"])) studyValues[@"studyName"] = c[@"studyName"];
        if (orNil(c[@"studyID"])) studyValues[@"id"] = c[@"studyID"];
        if (orNil(c[@"seriesName"])) seriesValues[@"name"] = c[@"seriesName"];
        if (c[@"seriesNumber"]) seriesValues[@"id"] = c[@"seriesNumber"];
        seriesValues[@"study"] = studyValues;
        NSDictionary *curImage = @{@"series": seriesValues};
        for (int dicomdir = 0; dicomdir < 2; dicomdir++)
            record(@"folders %d %@: [%@] [%@]", dicomdir, c[@"label"], studyFolder(curImage, dicomdir), seriesFolder(curImage, dicomdir));
    }
    for (NSDictionary *c in cases[2]) {
        NSString *folder = [root stringByAppendingPathComponent:[@"objc-" stringByAppendingString:c[@"label"]]];
        [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
        for (NSString *existing in c[@"existing"])
            [[NSData data] writeToFile:[folder stringByAppendingPathComponent:existing] atomically:NO];
        fileName(folder, [c[@"series"] longValue], [c[@"image"] longValue], c[@"extension"], [c[@"dicomdir"] boolValue], c[@"label"]);
    }
    for (NSDictionary *c in cases[3]) {
        NSMutableDictionary *paths = [NSMutableDictionary dictionary];
        for (NSArray *entry in c[@"entries"])
            [BrowserController setPath:entry[0] relativeTo:c[@"directory"] forSeriesId:[entry[1] intValue] kind:entry[2] toSeriesPaths:paths];
        NSMutableArray *lines = [NSMutableArray array];
        for (NSNumber *key in [[paths allKeys] sortedArrayUsingSelector:@selector(compare:)])
            for (NSString *kind in [[paths[key] allKeys] sortedArrayUsingSelector:@selector(compare:)])
                [lines addObject:[NSString stringWithFormat:@"%@/%@=%@", key, kind, paths[key][kind]]];
        record(@"movie %@: %@", c[@"label"], [lines componentsJoinedByString:@" "]);
    }
    for (NSDictionary *c in cases[4]) {
        NSMutableArray *items = [NSMutableArray array];
        for (NSString *item in c[@"items"]) [items addObject:[root stringByAppendingPathComponent:item]];
        zipArguments(items, c[@"password"], @"/archive.zip", c[@"label"]);
        flatArguments(c[@"items"], c[@"password"], @"/flat.zip", c[@"label"]);
    }
    NSMutableArray *dicomFiles2Export = [NSMutableArray array];
    for (NSDictionary *c in cases[5]) [dicomFiles2Export addObject:@{@"series": c, @"completePath": c[@"label"]}];
@@FILTER@@
    record(@"filter: %@", [[dicomFiles2Export valueForKey:@"completePath"] componentsJoinedByString:@" "]);
    printf("%s\n", [[records componentsJoinedByString:@"\n"] UTF8String]);
}}
'''
for key, value in (('REPLACE_ONE', replace_one), ('REPLACE_TWO', replace_two), ('PATIENT', patient), ('SET_PATH', set_path),
                   ('STUDY', study), ('SERIES', series), ('NAMES', names), ('RENAMES', renames), ('ZIP_ARGS', zip_args),
                   ('FLAT_ARGS', flat_args), ('FILTER', filter_text)):
    OBJC = OBJC.replace('@@%s@@' % key, value)

SWIFT = r'''
import Foundation
var records: [String] = []
let root = CommandLine.arguments[1]
let cases = try! PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: root + "/cases.plist")), format: nil) as! [Any]
func orNil(_ value: String?) -> String? { value == "<nil>" ? nil : value }
for name in cases[0] as! [String] {
    for hyphens in [false, true] {
        records.append("replace \(hyphens ? 1 : 0) [\(name)] -> [\(ExportNaming.replacingNotAdmitted(name, preserveHyphens: hyphens))]")
    }
    for dicomdir in [false, true] {
        records.append("patient \(dicomdir ? 1 : 0) [\(name)] -> [\(ExportNaming.patientFolder(name: orNil(name), addDICOMDIR: dicomdir))]")
    }
}
for c in cases[1] as! [NSDictionary] {
    let number = (c["seriesNumber"] as? NSNumber) ?? NSNumber(value: 0)
    for dicomdir in [false, true] {
        let study = ExportNaming.studyFolder(name: orNil(c["studyName"] as? String), id: orNil(c["studyID"] as? String), addDICOMDIR: dicomdir)
        let series = ExportNaming.seriesFolder(name: orNil(c["seriesName"] as? String), number: number.stringValue, addDICOMDIR: dicomdir)
        records.append("folders \(dicomdir ? 1 : 0) \(c["label"]!): [\(study)] [\(series)]")
    }
}
for c in cases[2] as! [NSDictionary] {
    let folder = root + "/swift-" + (c["label"] as! String)
    try! FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    for existing in c["existing"] as! [String] { FileManager.default.createFile(atPath: folder + "/" + existing, contents: Data()) }
    let series = (c["series"] as! NSNumber).int32Value, image = (c["image"] as! NSNumber).int32Value
    let ext = c["extension"] as! String, dicomdir = (c["dicomdir"] as! NSNumber).boolValue
    var dest = ExportNaming.imageFile(folder: folder, seriesCount: series, imageNumber: image, pathExtension: ext, addDICOMDIR: dicomdir)
    var attempt: Int32 = 2
    while FileManager.default.fileExists(atPath: dest) {
        dest = ExportNaming.imageFile(folder: folder, seriesCount: series, imageNumber: image, pathExtension: ext, addDICOMDIR: dicomdir, attempt: attempt)
        attempt += 1
    }
    FileManager.default.createFile(atPath: dest, contents: Data())
    let renames = attempt != 2 ? [(ExportNaming.imageFile(folder: folder, seriesCount: series, imageNumber: image, pathExtension: ext, addDICOMDIR: dicomdir, attempt: 1) as NSString).lastPathComponent] : []
    records.append("file \(c["label"]!): \((dest as NSString).lastPathComponent) renames [\(renames.joined(separator: ","))]")
}
for c in cases[3] as! [NSDictionary] {
    let paths = NSMutableDictionary()
    for entry in c["entries"] as! [[Any]] {
        MovieExportPaths.record(entry[0] as! String, relativeTo: c["directory"] as! String, seriesID: (entry[1] as! NSNumber).int32Value,
                                kind: entry[2] as! String, in: paths)
    }
    var lines: [String] = []
    for key in (paths.allKeys as! [NSNumber]).sorted(by: { $0.compare($1) == .orderedAscending }) {
        let kinds = paths[key] as! NSDictionary
        for kind in (kinds.allKeys as! [String]).sorted(by: { ($0 as NSString).compare($1) == .orderedAscending }) {
            lines.append("\(key)/\(kind)=\(kinds[kind]!)")
        }
    }
    records.append("movie \(c["label"]!): " + lines.joined(separator: " "))
}
for c in cases[4] as! [NSDictionary] {
    let items = (c["items"] as! [String]).map { root + "/" + $0 }
    let password = c["password"] as? String
    if let names = ZipCommand.entryNames(items, exists: { FileManager.default.fileExists(atPath: $0) }), !names.isEmpty {
        let args = ZipCommand.recursiveArguments(password: password, archive: "/archive.zip", names: names)
        records.append("zip \(c["label"]!): \(args.joined(separator: "|")) in \(((items[0] as NSString).deletingLastPathComponent as NSString).lastPathComponent)")
    } else {
        records.append("zip \(c["label"]!): <none> in -")
    }
    records.append("flat \(c["label"]!): " + ZipCommand.flatArguments(password: password, archive: "/flat.zip", files: c["items"] as! [String]).joined(separator: "|"))
}
var kept: NSArray = (cases[5] as! [NSDictionary]).map { ["series": $0, "completePath": $0["label"]!] as NSDictionary } as NSArray
for predicate in ExportSeriesFilter.predicates() { kept = kept.filtered(using: predicate) as NSArray }
records.append("filter: " + (kept.value(forKey: "completePath") as! [String]).joined(separator: " "))
print(records.joined(separator: "\n"))
'''

NAMES = ['Silva^Ana', 'SILVA, ANA B.', 'Müller^José', 'Ｗｉｄｅ^Name', 'école', 'O\'Neill-Smith', '山田^太郎', 'a/b\\c|d',
         '.:*?<>#%', '-', '', '<nil>', 'Very Long Patient Name Beyond Eight', 'ABCDEFGH', 'ABCDEFGHI', 'ß straße', 'x.́y',
         '😀 emoji', 'tab\there', 'ÆØÅ', 'Ünïcödé^Ñame', '12345678', '1.2.840.113619']
FOLDERS = [
    {'label': 'plain', 'studyName': 'Chest CT', 'studyID': '1234', 'seriesName': 'Axial 2.5mm', 'seriesNumber': 3},
    {'label': 'missing', 'studyName': '<nil>', 'studyID': '<nil>', 'seriesName': '<nil>'},
    {'label': 'empty', 'studyName': '', 'studyID': '', 'seriesName': '', 'seriesNumber': 0},
    {'label': 'cleaned away', 'studyName': '...', 'studyID': '--', 'seriesName': '#%', 'seriesNumber': 7},
    {'label': 'long', 'studyName': 'Estudo com acentuação', 'studyID': 'ACC-2026-000123', 'seriesName': 'T1 pós-contraste',
     'seriesNumber': 123456},
    {'label': 'unicode', 'studyName': '胸部CT', 'studyID': 'ÉCHO-1', 'seriesName': 'Série ①', 'seriesNumber': 5002},
    {'label': 'negative', 'studyName': 'x', 'studyID': '9', 'seriesName': 'y', 'seriesNumber': -4},
]
FILES = [
    {'label': 'free', 'series': 1, 'image': 2, 'extension': 'dcm', 'dicomdir': False, 'existing': []},
    {'label': 'taken', 'series': 1, 'image': 2, 'extension': 'dcm', 'dicomdir': False, 'existing': ['IM-0001-0002.dcm']},
    {'label': 'taken twice', 'series': 3, 'image': 10, 'extension': 'dcm', 'dicomdir': False,
     'existing': ['IM-0003-0010.dcm', 'IM-0003-0010-0002.dcm']},
    {'label': 'dicomdir free', 'series': 12, 'image': 345, 'extension': 'dcm', 'dicomdir': True, 'existing': []},
    {'label': 'dicomdir taken', 'series': 1, 'image': 2, 'extension': 'dcm', 'dicomdir': True, 'existing': ['00010002', '00022']},
    {'label': 'wide numbers', 'series': 123456, 'image': 98765, 'extension': 'hdr', 'dicomdir': False, 'existing': []},
    {'label': 'negative', 'series': 1, 'image': -3, 'extension': 'dcm', 'dicomdir': False, 'existing': []},
]
MOVIES = [
    {'label': 'two series', 'directory': '/out', 'entries': [['/out/P/S/a_1_1.mp4', 4, 'mp4'], ['/out/P/S/a_1_thumb.jpg', 4, 'thumb'],
                                                            ['/out/P/S/b_2_2.jpg', 5, 'jpg'], ['/out/P/S/b_2_2.pdf', 5, 'pdf']]},
    {'label': 'trailing slash', 'directory': '/out/', 'entries': [['/out/P/x.mp4', 1, 'mp4']]},
    {'label': 'unknown series', 'directory': '/o', 'entries': [['/o/z.jpg', -1, 'jpg']]},
]
ZIPS = [
    {'label': 'one folder', 'items': ['zip/A'], 'password': ''},
    {'label': 'two folders encrypted', 'items': ['zip/A', 'zip/B'], 'password': 'secret pass'},
    {'label': 'other parent', 'items': ['zip/A', 'other/C'], 'password': ''},
    {'label': 'missing', 'items': ['zip/A', 'zip/none'], 'password': 'x'},
]
SERIES = [{'label': name.replace(' ', '_') + '-' + str(number), 'name': name, 'id': number}
          for name in ('CT', 'OsiriX ROI SR', 'osirix report sr', 'Prefix OsiriX Annotations SR', 'OsiriX No Autodeletion',
                       'OsiriX WindowsState SR', 'MR')
          for number in (1, 5002, 5003, 5004, 5005, 5006)]

failures = []
with tempfile.TemporaryDirectory(prefix='horos-browser-export-') as tmp:
    tmp = Path(tmp)
    for folder in ('zip/A', 'zip/B', 'other/C'):
        (tmp / folder).mkdir(parents=True)
    (tmp / 'cases.plist').write_bytes(plistlib.dumps([NAMES, FOLDERS, FILES, MOVIES, ZIPS, SERIES]))
    (tmp / 'reference.m').write_text(OBJC)
    built = subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-Wno-format', '-framework', 'Foundation', str(tmp / 'reference.m'),
                            '-o', str(tmp / 'reference')], capture_output=True, text=True)
    if built.returncode:
        sys.exit('FAIL: the Objective-C reference does not compile:\n' + built.stderr[-3000:])
    (tmp / 'main.swift').write_text(SWIFT)
    built = subprocess.run(['xcrun', 'swiftc', '-o', str(tmp / 'current'), str(RULES), str(tmp / 'main.swift')],
                           capture_output=True, text=True)
    if built.returncode:
        sys.exit('FAIL: the module does not compile:\n' + built.stderr[-3000:])
    objc = subprocess.run([str(tmp / 'reference'), str(tmp)], capture_output=True, text=True, timeout=120)
    swift = subprocess.run([str(tmp / 'current'), str(tmp)], capture_output=True, text=True, timeout=120)
    if objc.returncode or swift.returncode:
        sys.exit('FAIL: a driver failed:\n' + objc.stderr[-1500:] + swift.stderr[-1500:])
    a, b = objc.stdout.splitlines(), swift.stdout.splitlines()
    if args.dump:
        args.dump.mkdir(parents=True, exist_ok=True)
        (args.dump / 'reference.txt').write_text(objc.stdout)
        (args.dump / 'current.txt').write_text(swift.stdout)
    if a != b:
        diff = list(difflib.unified_diff(a, b, 'Objective-C', 'IsiXDatabase', lineterm='', n=0))
        failures.append('records differ:\n' + '\n'.join(diff[:60]))

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
kinds = {}
for line in a:
    kinds[line.split()[0]] = kinds.get(line.split()[0], 0) + 1
print('ok: the export rules of %s and IsiXDatabase agree on %d records (%s)'
      % (reference, sum(kinds.values()), ', '.join('%s %d' % kv for kv in sorted(kinds.items()))))
