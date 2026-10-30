#!/usr/bin/env python3
"""The media scan's and the web portal's rules decide what their Objective-C++ did.

The scan of a medium (DicomDatabase+Scan.mm) and the browser's DCMTK category
(BrowserControllerDCMTKCategory.mm) became Swift extensions, with the decisions
that read no file in IsiXDatabase (MediaScanRules) and IsiXDICOMFile
(TransferSyntaxServing). This cuts those decisions out of the Objective-C++ of
the last revision that has it (history_reference; the tree or HEAD while they
still have it), compiles them, compiles the module sources with swiftc, gives
both the same synthetic inputs and compares what they print:

* which files the scan leaves unopened (extensions, Weasis, hidden files,
  applications) and which DICOM files it takes for a DICOMDIR;
* the DICOMDIR of a medium, and the listed file a wrong reference means;
* whether an entry is the only one of its series;
* a record's file path and its MAXPATHLEN check, its file type, and its series
  UID and series ID (multi-frame files, series numbers that are not numbers);
* whether a stored file serves a transfer syntax asked of it as it is (with
  DCMTK's transfer syntax table, from the Debug build: exit 2 without it).

    python3 tests/test-media-scan-rules-equivalence.py [--reference REV]
"""
import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import history_reference  # noqa: E402
from dcmtk_build import dcmtk_flags  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SCAN = 'Horos/Sources/DicomDatabase+Scan.mm'
BROWSER = 'Horos/Sources/BrowserControllerDCMTKCategory.mm'
RULES = [ROOT / 'Modules/IsiXDatabase/Sources/MediaScanRules.swift',
         ROOT / 'Modules/IsiXDICOMFile/Sources/TransferSyntaxServing.swift']

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--reference')
args = parser.parse_args()


def text_at(path):
    """The Objective-C++ of `path`: in the tree, at HEAD, or before its removal."""
    reference = args.reference
    if reference is None:
        if (ROOT / path).exists():
            return (ROOT / path).read_bytes().decode('latin1')
        head = subprocess.run(['git', '-C', str(ROOT), 'show', 'HEAD:' + path], capture_output=True)
        if head.returncode == 0:
            return head.stdout.decode('latin1')
        reference = history_reference.before_removal(path)
    if reference is None:
        print('skipped: needs the history that has ' + path)
        raise SystemExit(2)
    return history_reference.show(reference, path).decode('latin1')


scan, browser = text_at(SCAN), text_at(BROWSER)
flags = dcmtk_flags()
for rule in RULES:
    if not rule.exists():
        raise SystemExit('FAIL: no ' + str(rule.relative_to(ROOT)))


def between(source, start, end, include_end=False):
    at = source.index(start)
    stop = source.index(end, at)
    return source[at:stop + (len(end) if include_end else 0)]


def method(source, signature):
    at = source.index(signature)
    opening = source.index('{', at)
    depth = 0
    for index in range(opening, len(source)):
        depth += (source[index] == '{') - (source[index] == '}')
        if depth == 0:
            return source[at:index + 1]
    raise SystemExit('FAIL: unbalanced ' + signature)


skip_block = between(scan, '                    NSString *extension = path.pathExtension.lowercaseString;', '                    examined++;')
dicomdir_name = between(scan, '[path.lastPathComponent.lowercaseString rangeOfString:@"dicomdir"].length == 0', ')')
find_dicomdir = method(scan, '+(NSString*)_findDicomdirIn:(NSArray*)allpaths')
fixed_path = method(scan, '-(NSString*)_fixedPathForPath:(NSString*)path withPaths:(NSArray*)allpaths')
only_entry = method(scan, '+(BOOL)_item:(NSDictionary*)item isOnlyEntryForItsSeriesInItems:(NSArray*)items')
path_block = between(scan, '\t\tNSString* path = [elementReferencedFileID stringValue];', '        if( path.length < MAXPATHLEN)')
file_type = between(scan, '            NSString *dicomdirTransferSyntax =', '            [item conditionallySetObject:[NSNumber numberWithBool:YES]')
series_block = between(scan, '            [item conditionallySetObject:[[elements objectForKeyRemove: @"0028,0008"] integerNumberValue] forKey:@"numberOfFrames"];',
                       'forKey:@"seriesNumber"];', include_end=True)
serving = between(browser, '\t\tif( filexfer.getXfer() == xfer.getXfer())', '\t\t// ------')
assert serving.count('return [NSData dataWithContentsOfFile: file];') == 5, serving

OBJC = r'''
#import <Foundation/Foundation.h>
#include <sys/param.h>
#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dcxfer.h>
#define N2LogException(e) NSLog(@"%@", e)
#define N2LogStackTrace(...) NSLog(__VA_ARGS__)

// The element of a DICOMDIR record, as the scan read it: its text, and the
// number in it.
@interface Element : NSObject
@property (copy) NSString *stringValue;
@end
@implementation Element
- (NSInteger)integerValue { return [self.stringValue integerValue]; }
- (NSNumber *)integerNumberValue { return [NSNumber numberWithInteger:[self integerValue]]; }
- (NSString *)stringValueWithEncodings:(void *)encodings { return self.stringValue; }
@end
@interface NSMutableDictionary (Scan)
- (id)objectForKeyRemove:(id)key;
- (void)conditionallySetObject:(id)obj forKey:(id)key;
@end
@implementation NSMutableDictionary (Scan)
- (id)objectForKeyRemove:(id)key { id temp = [[self objectForKey:key] retain]; [self removeObjectForKey:key]; return [temp autorelease]; }
- (void)conditionallySetObject:(id)obj forKey:(id)key { if (obj) [self setObject:obj forKey:key]; }
@end

@interface Reference : NSObject @end
@implementation Reference
FIND_DICOMDIR
FIXED_PATH
ONLY_ENTRY
@end

static BOOL skips(NSString *path)
{
    for (int once = 0; once < 1; once++) {
SKIP_BLOCK
        return NO;
    }
    return YES;
}

static NSString *show(id value) { return value ? [value description] : @"<nil>"; }
static NSString *nilIfDash(NSString *s) { return [s isEqualToString:@"-"] ? nil : s; }

static NSString *filePath(NSString *fileID, NSString *basepath)
{
    Element *elementReferencedFileID = [Element new];
    elementReferencedFileID.stringValue = fileID;
PATH_BLOCK
    return [NSString stringWithFormat:@"%@\t%d", path, (int)(path.length < MAXPATHLEN)];
}

static NSString *fileType(NSString *syntax)
{
    NSMutableDictionary *elements = [NSMutableDictionary dictionary];
    if (syntax) { Element *e = [Element new]; e.stringValue = syntax; elements[@"0004,1512"] = e; }
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
FILE_TYPE
    return item[@"fileType"];
}

static NSString *series(NSString *frames, NSString *seriesUID, NSString *sop, NSString *number)
{
    NSMutableDictionary *elements = [NSMutableDictionary dictionary];
    NSArray *pairs = @[@[@"0028,0008", frames ?: [NSNull null]], @[@"0020,000E", seriesUID ?: [NSNull null]],
                       @[@"0020,0011", number ?: [NSNull null]]];
    for (NSArray *pair in pairs)
        if (pair[1] != [NSNull null]) { Element *e = [Element new]; e.stringValue = pair[1]; elements[pair[0]] = e; }
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    if (sop) item[@"SOPUID"] = sop;
    void *encodings = NULL;
SERIES_BLOCK
    return [NSString stringWithFormat:@"%@\t%@", show(item[@"seriesDICOMUID"]), show(item[@"seriesID"])];
}

static BOOL serves(const char *original, const char *requested)
{
    DcmXfer filexfer(original);
    DcmXfer xfer(requested);
SERVING
    return NO;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        NSString *all = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]] encoding:NSUTF8StringEncoding error:nil];
        for (NSString *line in [all componentsSeparatedByString:@"\n"]) {
            if (!line.length) continue;
            NSArray *f = [line componentsSeparatedByString:@"\t"];
            NSString *kind = f[0];
            NSString *answer = nil;
            if ([kind isEqualToString:@"skip"]) {
                NSString *path = f[1];
                answer = [NSString stringWithFormat:@"%d\t%d", skips(path), (int)!(DICOMDIR_NAME)];
            } else if ([kind isEqualToString:@"dicomdir"]) {
                answer = show([Reference _findDicomdirIn:[f subarrayWithRange:NSMakeRange(1, f.count - 1)]]);
            } else if ([kind isEqualToString:@"fixed"]) {
                answer = show([[Reference new] _fixedPathForPath:f[1] withPaths:[f subarrayWithRange:NSMakeRange(2, f.count - 2)]]);
            } else if ([kind isEqualToString:@"only"]) {
                NSMutableArray *items = [NSMutableArray array];
                for (NSString *s in [f subarrayWithRange:NSMakeRange(2, f.count - 2)])
                    [items addObject:[s isEqualToString:@"-"] ? [NSMutableDictionary dictionary] : [@{@"seriesID": s} mutableCopy]];
                answer = [NSString stringWithFormat:@"%d", [Reference _item:items[[f[1] intValue]] isOnlyEntryForItsSeriesInItems:items]];
            } else if ([kind isEqualToString:@"path"]) {
                answer = filePath(f[1], f[2]);
            } else if ([kind isEqualToString:@"type"]) {
                answer = fileType(nilIfDash(f[1]));
            } else if ([kind isEqualToString:@"series"]) {
                answer = series(nilIfDash(f[1]), nilIfDash(f[2]), nilIfDash(f[3]), nilIfDash(f[4]));
            } else if ([kind isEqualToString:@"serves"]) {
                answer = [NSString stringWithFormat:@"%d", serves([f[1] UTF8String], [f[2] UTF8String])];
            }
            printf("%s\t%s\n", line.UTF8String, show(answer).UTF8String);
        }
    }
    return 0;
}
'''
OBJC = (OBJC.replace('FIND_DICOMDIR', find_dicomdir).replace('FIXED_PATH', fixed_path).replace('ONLY_ENTRY', only_entry)
        .replace('SKIP_BLOCK', skip_block).replace('DICOMDIR_NAME', dicomdir_name).replace('PATH_BLOCK', path_block)
        .replace('FILE_TYPE', file_type).replace('SERIES_BLOCK', series_block)
        .replace('SERVING', serving.replace('return [NSData dataWithContentsOfFile: file];', 'return YES;')))

SWIFT = r'''
import Foundation

func show(_ value: Any?) -> String { value.map { "\($0)" } ?? "<nil>" }
func nilIfDash(_ s: String) -> String? { s == "-" ? nil : s }

let all = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
for line in all.components(separatedBy: "\n") where !line.isEmpty {
    let f = line.components(separatedBy: "\t")
    var answer: String? = nil
    switch f[0] {
    case "skip":
        answer = "\(MediaScanRules.skipsWhenScanning(f[1]) ? 1 : 0)\t\(MediaScanRules.isDicomdirName(f[1]) ? 1 : 0)"
    case "dicomdir":
        answer = show(MediaScanRules.dicomdir(in: Array(f[1...])))
    case "fixed":
        answer = show(MediaScanRules.listedPath(matching: f[1], in: Array(f[2...])))
    case "only":
        answer = "\(MediaScanRules.isOnlyEntryOfItsSeries(at: Int(f[1])!, seriesIDs: f[2...].map(nilIfDash)) ? 1 : 0)"
    case "path":
        let path = MediaScanRules.referencedFilePath(f[1], basePath: f[2])
        answer = "\(path)\t\(MediaScanRules.acceptsReferencedFilePath(path) ? 1 : 0)"
    case "type":
        answer = MediaScanRules.fileType(forTransferSyntax: nilIfDash(f[1]))
    case "series":
        let frames = nilIfDash(f[1]).map { ($0 as NSString).integerValue } ?? 0
        let uid = MediaScanRules.seriesDICOMUID(seriesInstanceUID: nilIfDash(f[2]), sopInstanceUID: nilIfDash(f[3]), numberOfFrames: frames)
        answer = "\(show(uid))\t\(show(MediaScanRules.seriesID(seriesNumber: nilIfDash(f[4]), seriesDICOMUID: uid)))"
    case "serves":
        answer = "\(TransferSyntaxServing.servesOriginal(original: f[1], requested: f[2]) ? 1 : 0)"
    default:
        break
    }
    print("\(line)\t\(show(answer))")
}
'''


def cases():
    lines = []
    for path in ['/Volumes/CD/IMAGES/IM000001', '/Volumes/CD/a.JPG', '/Volumes/CD/b.jpeg', '/Volumes/CD/c.TIF',
                 '/Volumes/CD/d.tiff', '/Volumes/CD/e.mp4', '/Volumes/CD/f.MOV', '/Volumes/CD/g.avi', '/Volumes/CD/h.html',
                 '/Volumes/CD/i.doc', '/Volumes/CD/j.DOCX', '/Volumes/CD/k.txt', '/Volumes/CD/l.exe', '/Volumes/CD/m.jpg2',
                 '/Volumes/CD/WEASIS/x', '/Volumes/CD/weasis.dcm', '/Volumes/CD/.Trashes/1', '/Volumes/CD/a./b',
                 '/Volumes/CD/Viewer.app/Contents/MacOS/x', '/Volumes/CD/APPS/x.App', '/Volumes/CD/DICOMDIR',
                 '/Volumes/CD/sub/dicomdir.bak', '/Volumes/CD/DicomDirs/IM1', '/Volumes/CD/İMAGE.TXT', '/Volumes/CD/ﬁle.txt',
                 '/Volumes/CD/noext', '/Volumes/CD/x.tar.gz', '/Volumes/CD/Ä/1.dcm', '/v/.', '']:
        lines.append('skip\t' + path)
    for group in [['/V/DICOMDIR'], ['/V/sub/DICOMDIR', '/V/dicomdir.'], ['/V/a/DICOMDIR', '/V/b/DICOMDIR'],
                  ['/V/DICOMDIR.BAK', '/V/x'], ['/V/x/DicomDir', '/V/DICOMDIR'], ['/V/dicomdir', '/V/DICOMDIR'],
                  ['/V/ı/DICOMDIR'], ['']]:
        lines.append('dicomdir\t' + '\t'.join(group))
    listed = ['/V/IMAGES/IM0001.DCM', '/V/IMAGES/IM0002', '/V/images/IM0003.x.y', '/V/Ä/A1']
    for wanted in ['/V/images/im0001', '/V/IMAGES/IM0002.dcm', '/V/IMAGES/IM0004', '/V/IMAGES/IM0003.x',
                   '/V/ä/a1', '/V/A\u0308/A1', '']:
        lines.append('fixed\t' + wanted + '\t' + '\t'.join(listed))
    for index, ids in [(0, ['a', 'b', '-']), (0, ['a', 'b', 'a']), (2, ['-', '-', '-']), (1, ['a', 'a']),
                       (0, ['é', 'e\u0301']), (1, ['x'] * 3), (0, ['x'])]:
        lines.append('only\t%d\t%s' % (index, '\t'.join(ids)))
    for file_id, base in [('IMAGES\\IM1', '/V'), ('IMAGES/IM1', '/V/'), ('A\\B\\C', '/V/sub'), ('', '/V'),
                          ('X' * 1020, '/V'), ('X' * 1021, '/V'), ('\\ROOT', '/V'), ('A\\\\B', '/V')]:
        lines.append('path\t%s\t%s' % (file_id, base))
    for syntax in ['-', '1.2.840.10008.1.2.4.100', '1.2.840.10008.1.2.4.101', '1.2.840.10008.1.2.4.102',
                   '1.2.840.10008.1.2.1', '', '1.2.840.10008.1.2.4.100 ']:
        lines.append('type\t' + syntax)
    for frames in ['-', '0', '1', '2', 'x', '10abc']:
        for uid, sop in [('1.2.3', '1.2.3.4'), ('-', '1.2.3.4'), ('1.2.3', '-'), ('-', '-')]:
            for number in ['-', '7', '0', '-1', 'abc', '12abc', ' 3', '', '99999999999']:
                lines.append('series\t%s\t%s\t%s\t%s' % (frames, uid, sop, number))
    syntaxes = ['1.2.840.10008.1.2', '1.2.840.10008.1.2.1', '1.2.840.10008.1.2.2', '1.2.840.10008.1.2.4.50',
                '1.2.840.10008.1.2.4.57', '1.2.840.10008.1.2.4.70', '1.2.840.10008.1.2.4.80', '1.2.840.10008.1.2.4.81',
                '1.2.840.10008.1.2.4.90', '1.2.840.10008.1.2.4.91', '1.2.840.10008.1.2.5', '1.2.3.4', '']
    for original in syntaxes[:-2]:
        for requested in syntaxes:
            lines.append('serves\t%s\t%s' % (original, requested))
    return lines


failures = []
with tempfile.TemporaryDirectory(prefix='isix-media-scan-rules-') as directory:
    work = Path(directory)
    manifest = work / 'cases.txt'
    manifest.write_text('\n'.join(cases()) + '\n', encoding='utf-8')
    (work / 'old.mm').write_text(OBJC, encoding='utf-8')
    (work / 'main.swift').write_text(SWIFT, encoding='utf-8')
    outputs = {}
    for label, clang_opt, swift_opt in (('Debug', '-O0', '-Onone'), ('Release', '-Os', '-O')):
        old, new = work / ('old-' + label), work / ('new-' + label)
        built = subprocess.run(['xcrun', 'clang++', clang_opt, '-std=c++17', '-fno-objc-arc', '-x', 'objective-c++',
                                str(work / 'old.mm'), '-x', 'none', *flags, '-framework', 'Foundation', '-o', str(old)],
                               capture_output=True, text=True, timeout=300)
        if built.returncode:
            failures.append('the reference does not compile (%s):\n%s' % (label, built.stderr[-3000:]))
            continue
        built = subprocess.run(['xcrun', 'swiftc', swift_opt, *map(str, RULES), str(work / 'main.swift'), '-o', str(new)],
                               capture_output=True, text=True, timeout=300)
        if built.returncode:
            failures.append('the module rules do not compile (%s):\n%s' % (label, built.stderr[-3000:]))
            continue
        for side, binary in (('old', old), ('new', new)):
            run = subprocess.run([str(binary), str(manifest)], capture_output=True, text=True, timeout=60)
            if run.returncode:
                failures.append('%s %s failed: %s' % (side, label, run.stderr[-1500:]))
            outputs[(side, label)] = run.stdout.splitlines()
    reference = outputs.get(('old', 'Debug'))
    if reference is not None:
        for key, lines in outputs.items():
            if len(lines) != len(reference):
                failures.append('%s %s printed %d answers, the reference %d' % (key[0], key[1], len(lines), len(reference)))
                continue
            for want, got in [(w, g) for w, g in zip(reference, lines) if w != g][:10]:
                failures.append('%s %s:\n    reference %s\n    got       %s' % (key[0], key[1], want[-300:], got[-300:]))
        counts = {}
        for line in reference:
            counts[line.split('\t', 1)[0]] = counts.get(line.split('\t', 1)[0], 0) + 1

if failures:
    print('FAIL:\n' + '\n'.join(failures))
    raise SystemExit(1)
print('PASS: the media scan and WADO serving rules answer as their Objective-C++ did, Debug and Release: %s'
      % ', '.join('%d %s' % (n, k) for k, n in sorted(counts.items())))
