#!/usr/bin/env python3
"""The browser's network and file rules decide what their Objective-C did.

The network, file, import and autorouting functions of BrowserController moved
from BrowserController.m to Swift extensions of the class, with their rules in
the IsiXDatabase module. This compiles the Objective-C of those rules, cut out
of BrowserController.m in the last revision that has it (history_reference; the
tree itself while it still has it), and the module with swiftc, gives both the
same synthetic inputs and compares what they produce:

* +compressionForModality:quality:resolution: for modalities (SR, a missing
  one, substrings, none matching) against Compression preferences with and
  without "same as default", low-resolution rows and missing values;
* the raw data import: the layout of every pixel type, whether the file holds
  the slices, and the bytes of each slice (big endian swapped) of a synthetic
  file;
* the delete queue: the files it deletes, the folders it collects, and which
  of them it removes afterwards, in a synthetic tree of old, new, hidden-only,
  ROIs and nested folders;
* "Add Studies to User": which studies are linked again for a user.

    python3 tests/test-browser-files-equivalence.py [--reference REV]
"""
import argparse
import difflib
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402
import history_reference  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
BC = 'Horos/Sources/BrowserController.m'
MARK = '+ (int) compressionForModality: (NSString*) mod quality:(int*) quality resolution: (int) resolution'
RULES = ROOT / 'Modules/IsiXDatabase/Sources/FileRules.swift'

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
    print('skipped: needs the history that has the Objective-C file functions of BrowserController.m')
    sys.exit(2)
if reference == 'tree':
    text = (ROOT / BC).read_bytes().decode('latin1')
else:
    shown = git('show', '%s:%s' % (reference, BC))
    if shown.returncode:
        sys.exit('FAIL: no %s at %s' % (BC, reference))
    text = shown.stdout.decode('latin1')
if MARK not in text:
    sys.exit('FAIL: %s has no Objective-C compression choice in %s' % (reference, BC))
if not RULES.exists():
    sys.exit('FAIL: no FileRules.swift in IsiXDatabase')


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


def between(start_text, end_text, within):
    at = within.index(start_text)
    return within[at:within.index(end_text, at)]


compression = method(MARK)
raw = method('- (IBAction)importRawData:(id)sender')
layout = between('NSUInteger spp;', 'if ([data length] >=', raw)
swap = raw[raw.index('if (isLittleEndian == NO)'):matching(raw, raw.index('{', raw.index('if (isLittleEndian == NO)')))]
empty = method('- (void) emptyDeleteQueueThread')
walk = between('long f = 0;', '[NSThread currentThread].progress = (float) f /', empty) + '[lastFolder release];\n'
cleanup = empty[empty.index('@try', empty.index('Cleaning database folders')):]
cleanup = cleanup[:cleanup.index('NSLog(@"delete Queue end");')]
users = method('- (IBAction) addStudiesToUser: (id) sender')
at = users.index('if( [studiesArrayStudyInstanceUID indexOfObject:')
end = users.index('== NSNotFound)', users.index('indexOfObjectPassingTest', at)) + len('== NSNotFound')
link = users[at + len('if('):end].strip()
assert link.count('NSNotFound') == 2, link

OBJC = r'''
#import <Foundation/Foundation.h>
#include <unistd.h>
enum { compression_sameAsDefault = 0, compression_none = 1, compression_JPEG = 2, compression_JPEG2000 = 3, compression_JPEGLS = 4 };
#define N2LogExceptionWithStackTrace(e) NSLog(@"%@", e)
#define N2LocalizedSingularPluralCount(c, s, p) [NSString stringWithFormat:@"%ld", (long)(c)]
@interface NSThread (Status)
@property float progress;
@property(copy) NSString *status;
@end
@implementation NSThread (Status)
- (float)progress { return 0; }
- (void)setProgress:(float)p {}
- (NSString *)status { return nil; }
- (void)setStatus:(NSString *)s {}
@end
@interface Ref : NSObject @end
@implementation Ref
COMPRESSION
@end
static NSMutableArray *records;
static void record(NSString *format, ...) {
    va_list list; va_start(list, format);
    [records addObject:[[[NSString alloc] initWithFormat:format arguments:list] autorelease]];
    va_end(list);
}
static void rawData(int pixelType, NSNumber *rows, NSNumber *columns, NSNumber *slices, NSNumber *offset, NSData *data) {
LAYOUT
    BOOL enough = [data length] >= subDataLength * [slices unsignedIntegerValue]  + [offset unsignedIntegerValue];
    NSString *vr = numberBytes < 2 ? @"OB" : @"OW";
    record(@"raw %d %@x%@x%@+%@: spp %lu bytes %lu high %lu bits %lu signed %d little %d %@ %@ enough %d",
           pixelType, rows, columns, slices, offset, (unsigned long)spp, (unsigned long)numberBytes, (unsigned long)highBit,
           (unsigned long)bitsAllocated, isSigned, isLittleEndian, photometricInterpretation, vr, enough);
    if (!enough) return;
    for (NSUInteger i = 0; i < [slices unsignedIntegerValue]; i++) {
        NSRange range = NSMakeRange([offset unsignedIntegerValue] + subDataLength * i, subDataLength);
        NSMutableData *subdata = [NSMutableData dataWithData:[data subdataWithRange:range]];
SWAP
        record(@"raw %d slice %lu: %@", pixelType, (unsigned long)i, [subdata base64EncodedStringWithOptions:0]);
    }
}
static NSArray *deleteQueue(NSArray *copyArray) {
    NSMutableArray *folders = [NSMutableArray array];
WALK
    return folders;
}
static void cleanFolders(NSArray *folders) {
CLEANUP
}
static BOOL needsLink(NSArray *studiesArrayStudyInstanceUID, NSArray *studiesArrayPatientUID, NSDictionary *study) {
    return LINK;
}
int main(int argc, char **argv) { @autoreleasepool {
    records = [NSMutableArray array];
    NSString *root = @(argv[1]);
    NSArray *cases = [NSPropertyListSerialization propertyListWithData:[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"cases.plist"]] options:0 format:NULL error:NULL];
    for (NSDictionary *c in cases[0]) {
        [[NSUserDefaults standardUserDefaults] setVolatileDomain:c[@"defaults"] forName:NSArgumentDomain];
        for (NSString *modality in c[@"modalities"]) {
            id mod = [modality isEqual:@"<nil>"] ? nil : modality;
            int quality = -7;
            int chosen = [Ref compressionForModality:mod quality:&quality resolution:[c[@"resolution"] intValue]];
            record(@"compression %@ %@ %@: %d quality %d", c[@"name"], c[@"resolution"], modality, chosen, quality);
        }
    }
    NSData *data = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"raw.bin"]];
    for (NSArray *r in cases[1])
        rawData([r[0] intValue], r[1], r[2], r[3], r[4], data);
    for (NSString *tree in cases[2]) {
        NSString *base = [root stringByAppendingPathComponent:[@"objc-" stringByAppendingString:tree]];
        NSArray *files = [[NSString stringWithContentsOfFile:[base stringByAppendingPathComponent:@"queue.txt"] encoding:NSUTF8StringEncoding error:NULL] componentsSeparatedByString:@"\n"];
        NSMutableArray *absolute = [NSMutableArray array];
        for (NSString *f in files) if (f.length) [absolute addObject:[base stringByAppendingPathComponent:f]];
        NSArray *folders = deleteQueue(absolute);
        NSMutableArray *relative = [NSMutableArray array];
        for (NSString *f in folders) [relative addObject:[f substringFromIndex:base.length]];
        record(@"delete %@ folders: %@", tree, [relative componentsJoinedByString:@" "]);
        cleanFolders(folders);
        NSMutableArray *left = [NSMutableArray array];
        for (NSString *p in [[[NSFileManager defaultManager] subpathsOfDirectoryAtPath:base error:NULL] sortedArrayUsingSelector:@selector(compare:)])
            [left addObject:p];
        record(@"delete %@ left: %@", tree, [left componentsJoinedByString:@" "]);
    }
    for (NSDictionary *c in cases[3])
        record(@"link %@: %d", c[@"name"], needsLink(c[@"uids"], c[@"patients"], c[@"study"]));
    printf("%s\n", [[records componentsJoinedByString:@"\n"] UTF8String]);
}}
'''.replace('COMPRESSION', compression).replace('LAYOUT', layout).replace('SWAP', swap) \
   .replace('WALK', walk).replace('CLEANUP', cleanup).replace('LINK', link)

SWIFT = r'''
import Foundation
var records: [String] = []
let root = CommandLine.arguments[1]
let cases = try! PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: root + "/cases.plist")), format: nil) as! [Any]
for c in cases[0] as! [NSDictionary] {
    let defaults = c["defaults"] as! NSDictionary
    let resolution = (c["resolution"] as! NSNumber).intValue
    for modality in c["modalities"] as! [String] {
        let mod: String? = modality == "<nil>" ? nil : modality
        let choice = CompressionChoice.choice(forModality: mod, resolution: resolution,
                                              resolutionLimit: (defaults["CompressionResolutionLimit"] as? NSNumber)?.intValue ?? 0,
                                              settings: defaults["CompressionSettings"] as? [Any],
                                              lowResolutionSettings: defaults["CompressionSettingsLowRes"] as? [Any])
        records.append("compression \(c["name"]!) \(resolution) \(modality): \(choice.compression) quality \(choice.quality.map { Int($0) } ?? -7)")
    }
}
let data = try! Data(contentsOf: URL(fileURLWithPath: root + "/raw.bin"))
for r in cases[1] as! [[NSNumber]] {
    let type = r[0].intValue
    let (rows, columns, slices, offset) = (r[1].uintValue, r[2].uintValue, r[3].uintValue, r[4].uintValue)
    let layout = RawDataLayout(pixelType: type)
    let enough = layout.fileHoldsSlices(length: UInt(data.count), rows: rows, columns: columns, slices: slices, offset: offset)
    records.append("raw \(type) \(r[1])x\(r[2])x\(r[3])+\(r[4]): spp \(layout.samplesPerPixel) bytes \(layout.bytesPerSample) high \(layout.highBit) bits \(layout.bitsAllocated) signed \(layout.isSigned ? 1 : 0) little \(layout.isLittleEndian ? 1 : 0) \(layout.photometricInterpretation) \(layout.pixelDataVR) enough \(enough ? 1 : 0)")
    if !enough { continue }
    for i in 0 ..< slices {
        records.append("raw \(type) slice \(i): \(layout.slice(i, of: data, rows: rows, columns: columns, offset: offset).base64EncodedString())")
    }
}
for tree in cases[2] as! [String] {
    let base = root + "/swift-" + tree
    let files = (try! String(contentsOfFile: base + "/queue.txt", encoding: .utf8)).components(separatedBy: "\n").filter { !$0.isEmpty }.map { base + "/" + $0 }
    for file in files { unlink(file) }
    let folders = DeleteQueueRules.parentFolders(of: files)
    records.append("delete \(tree) folders: " + folders.map { String($0.dropFirst(base.count)) }.joined(separator: " "))
    DeleteQueueRules.removeEmptyFolders(folders)
    let left = ((try? FileManager.default.subpathsOfDirectory(atPath: base)) ?? []).sorted { ($0 as NSString).compare($1) == .orderedAscending }
    records.append("delete \(tree) left: " + left.joined(separator: " "))
}
for c in cases[3] as! [NSDictionary] {
    let study = c["study"] as! NSDictionary
    let needs = WebPortalStudyLink.needsLink(studyUID: study["studyInstanceUID"] as? String, patientUID: study["patientUID"] as? String,
                                             linkedStudyUIDs: c["uids"] as! [Any], linkedPatientUIDs: c["patients"] as! [Any])
    records.append("link \(c["name"]!): \(needs ? 1 : 0)")
}
print(records.joined(separator: "\n"))
'''


def compression_cases():
    full = [{'modality': 'CT', 'compression': 3, 'quality': 2}, {'modality': 'MR', 'compression': 0, 'quality': 5},
            {'modality': 'US', 'compression': 2, 'quality': 9}, {'modality': 'PT', 'compression': 4, 'quality': 1},
            {'modality': 'XA', 'compression': '3', 'quality': '4'}, {'modality': 'DX', 'compression': 1}]
    default_first = [{'modality': 'Default', 'compression': 4, 'quality': 3}] + full
    low = [{'modality': 'CT', 'compression': 1, 'quality': 0}, {'modality': 'MG', 'compression': 3, 'quality': 7}]
    modalities = ['CT', 'MR', 'US', 'PT', 'XA', 'DX', 'SR', 'SC', '<nil>', 'PT\\CT', 'ct', 'MRI', '']
    cases = []
    for name, settings, lowres, limit in (('full', full, low, 300), ('default', default_first, [], 0),
                                          ('empty', [], [], 0), ('lowres', full, low, 2048), ('nolow', full, None, 2048)):
        defaults = {'CompressionSettings': settings, 'CompressionResolutionLimit': limit}
        if lowres is not None:
            defaults['CompressionSettingsLowRes'] = lowres
        for resolution in (256, 4096):
            cases.append({'name': name, 'defaults': defaults, 'resolution': resolution, 'modalities': modalities})
    return cases


def raw_cases():
    rows = []
    for pixel in range(-1, 9):
        rows += [[pixel, 4, 3, 2, 0], [pixel, 2, 5, 3, 7], [pixel, 64, 64, 64, 0], [pixel, 3, 3, 1, 1], [pixel, 512, 512, 20, 0]]
    return rows


def link_cases():
    return [
        {'name': 'new', 'uids': [], 'patients': [], 'study': {'studyInstanceUID': '1.2', 'patientUID': 'SILVA ANA-1-'}},
        {'name': 'same', 'uids': ['1.2'], 'patients': ['SILVA ANA-1-'], 'study': {'studyInstanceUID': '1.2', 'patientUID': 'SILVA ANA-1-'}},
        {'name': 'case and accents', 'uids': ['1.2'], 'patients': ['silva ána-1-'], 'study': {'studyInstanceUID': '1.2', 'patientUID': 'SILVA ANA-1-'}},
        {'name': 'width', 'uids': ['1.2'], 'patients': ['ＳＩＬＶＡ ANA-1-'], 'study': {'studyInstanceUID': '1.2', 'patientUID': 'SILVA ANA-1-'}},
        {'name': 'other patient', 'uids': ['1.2'], 'patients': ['SOUZA-2-'], 'study': {'studyInstanceUID': '1.2', 'patientUID': 'SILVA ANA-1-'}},
        {'name': 'other study', 'uids': ['1.3'], 'patients': ['SILVA ANA-1-'], 'study': {'studyInstanceUID': '1.2', 'patientUID': 'SILVA ANA-1-'}},
        {'name': 'uid case', 'uids': ['1.2A'], 'patients': ['P'], 'study': {'studyInstanceUID': '1.2a', 'patientUID': 'P'}},
        {'name': 'several', 'uids': ['1.1', '1.2', '1.3'], 'patients': ['A', 'B', 'P'], 'study': {'studyInstanceUID': '1.3', 'patientUID': 'p'}},
    ]


TREES = {
    # relative path -> 'old' | 'new' (folder ages) ; files listed in the queue
    'flat': (['a/1.dcm', 'a/2.dcm', 'b/1.dcm', 'a/3.dcm', 'c/1.dcm', 'c/2.dcm'],
             {'a': 'old', 'b': 'old', 'c': 'new'}, ['c/keep.dcm', 'b/.DS_Store']),
    'kinds': (['ROIs/1.dcm', 'kept/1.dcm', 'nested/1.dcm', 'hidden/1.dcm', 'deep/x/1.dcm', 'deep/x/2.dcm'],
              {'ROIs': 'old', 'kept': 'old', 'nested': 'old', 'nested/s1': 'old', 'nested/s2': 'old', 'hidden': 'old',
               'deep': 'old', 'deep/x': 'old'}, ['kept/stay.dcm', 'hidden/.hidden']),
    'repeat': (['a/1.dcm', 'b/1.dcm', 'a/2.dcm', 'b/2.dcm', 'a/3.dcm'], {'a': 'old', 'b': 'old'}, []),
}


def make_tree(base, tree):
    queued, ages, extra = TREES[tree]
    for path in queued + extra:
        target = base / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b'synthetic')
    for folder in ages:
        (base / folder).mkdir(parents=True, exist_ok=True)
    (base / 'queue.txt').write_text('\n'.join(queued))
    # Folder ages: creation dates are set by the drivers' file manager.
    return ages


def set_ages(base, ages):
    import plistlib
    old = [str(base / f) for f, age in ages.items() if age == 'old']
    script = 'import Foundation\nfor p in CommandLine.arguments.dropFirst() { try! FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: p) }\n'
    return old, script


failures = []
with tempfile.TemporaryDirectory(prefix='horos-browser-files-') as tmp:
    tmp = Path(tmp)
    import plistlib
    trees = sorted(TREES)
    (tmp / 'cases.plist').write_bytes(plistlib.dumps([compression_cases(), raw_cases(), trees, link_cases()]))
    (tmp / 'raw.bin').write_bytes(bytes((i * 37 + 11) % 256 for i in range(3 * 64 * 64 * 64 * 4 + 64)))
    old_paths = []
    for tree in trees:
        for side in ('objc', 'swift'):
            ages = make_tree(tmp / ('%s-%s' % (side, tree)), tree)
            old_paths += [str(tmp / ('%s-%s' % (side, tree)) / f) for f, age in ages.items() if age == 'old']
    (tmp / 'ages.swift').write_text('import Foundation\nfor p in CommandLine.arguments.dropFirst() { try! FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: p) }\n')
    subprocess.run(['xcrun', 'swiftc', '-o', str(tmp / 'ages'), str(tmp / 'ages.swift')], check=True)
    subprocess.run([str(tmp / 'ages'), *old_paths], check=True)
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
print('ok: the network and file rules of %s and IsiXDatabase agree on %d records (%s)'
      % (reference, len(a), ', '.join('%s %d' % kv for kv in sorted(kinds.items()))))
