#!/usr/bin/env python3
"""The import rules of IsiXDatabase decide what DicomDatabase.mm decided.

DicomDatabase.mm became Swift, and the rules of its import that need no
database went to IsiXDatabase (DatabaseImportRules.swift). This compiles, from
the last revision that has DicomDatabase.mm, read from git:

- availablePathInDirectory(), whole: a free name in a folder;
- the arithmetic of -isFileSystemFreeSizeLimitReached that says the volume is
  too full;
- the clamp of maxNumberOfFilesForCheckIncoming of the incoming scan;
- the tests of the scan on a name: .DS_Store, __MACOSX, a hidden entry;
- the condition of the scan that sends a DICOM image to the conversion queue,
  with the order in which it asks +fileNeedsDecompression:;
- the choice of the queue the compressed files of a scan join;
- HorosIncomingLooksLikeCloudReport(), whole, on a stand-in of
  DCMAbstractSyntaxUID;
- the WADO-RS multipart split, whole, writing nothing: each part it would
  have written is recorded, and an exception it raises is reported,

and runs them on the same generated cases as a Swift driver that calls
AvailablePath, StorageFreeSpace, IncomingScanRules, CloudReportCandidate and
WADORSMultipart as DicomDatabase does. Both print every decision; the outputs
must be the same, in Debug (-O0 / -Onone) and Release (-Os / -O).

Exits 2 when the history does not reach a revision with DicomDatabase.mm.
"""
import random
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs
import history_reference  # noqa: E402
import isix_modules  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SOURCE = 'Horos/Sources/DicomDatabase.mm'

reference = history_reference.before_removal(SOURCE)
if reference is None and subprocess.run(['git', '-C', str(ROOT), 'cat-file', '-e', f'HEAD:{SOURCE}'],
                                        capture_output=True).returncode == 0:
    reference = 'HEAD'
if reference is None:
    print('skipped: no revision of this history has ' + SOURCE, file=sys.stderr)
    raise SystemExit(2)

old = history_reference.show(reference, SOURCE).decode('latin1')
failures = []


def between(text, start, end, include_end=True):
    at = text.index(start)
    stop = text.index(end, at + len(start))
    return text[at:stop + (len(end) if include_end else 0)]


def braced(text, start):
    """The statement starting at `start` through its closing brace."""
    at = text.index(start)
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[at:index + 1]
    raise ValueError(start)


# --- the Objective-C, as it was ----------------------------------------------
available = braced(old, 'static NSString *availablePathInDirectory( NSString *directory, NSString *name)\n')
free_space = between(old, 'unsigned long long sizeBytes = [dataBasePathSize unsignedLongLongValue]',
                     '_isFileSystemFreeSizeLimitReached = freeMegaBytes < thresholdMegaBytes;')
clamp = between(old, 'int maxNumberOfFiles = [[NSUserDefaults standardUserDefaults] integerForKey:@"maxNumberOfFilesForCheckIncoming"];',
                'if (maxNumberOfFiles > 30000) maxNumberOfFiles = 30000;')
clamp = clamp.replace('[[NSUserDefaults standardUserDefaults] integerForKey:@"maxNumberOfFilesForCheckIncoming"]', 'preference')
litter = [line for line in ('if ([[lastPathComponent uppercaseString] isEqualToString:@".DS_STORE"])',
                            'if ([[lastPathComponent uppercaseString] isEqualToString:@"__MACOSX"])',
                            "if ([lastPathComponent length] > 0 && [lastPathComponent characterAtIndex: 0] == '.')")]
for line in litter:
    if line not in old:
        failures.append('the scan test is not in the reference: ' + line)
transcode = between(old, 'if (mayTranscode && ((isJPEGCompressed == YES && listenerCompressionSettings == 1)',
                    '\n                                {', include_end=False)
decompress_queue = 'if (listenerCompressionSettings == 1 || listenerCompressionSettings == 0)'
compress_queue = 'else if (listenerCompressionSettings == 2)'
for line in (decompress_queue, compress_queue):
    if line not in old:
        failures.append('the choice of queue is not in the reference: ' + line)
cloud = braced(old, 'static BOOL HorosIncomingLooksLikeCloudReport(NSDictionary *dict)\n')
multipart = braced(old, 'if( data.length >= WADORSSIZE)')
written = ('dicomFileCreated=[[data subdataWithRange:NSMakeRange(datasetOffset,boundaryRange.location - 2 - datasetOffset)]'
           'writeToFile:[self.incomingDirPath stringByAppendingPathComponent:[[NSUUID UUID]UUIDString]] atomically:NO];')
if written not in multipart:
    failures.append('the write of a multipart part is not in the reference')
multipart = multipart.replace(written, 'dicomFileCreated=record(data, datasetOffset, boundaryRange.location - 2 - datasetOffset);')

PDF = '1.2.840.10008.5.1.4.1.1.104.1'
SR = '1.2.840.10008.5.1.4.1.1.88.11'

OBJC = r'''
#import <Foundation/Foundation.h>
#define WADORSSIZE 0x500
static NSString *field(NSString *value) { return [value isEqualToString:@"<nil>"] ? nil : value; }

@interface DCMAbstractSyntaxUID : NSObject
+ (BOOL)isPDF:(NSString *)uid;
+ (BOOL)isStructuredReport:(NSString *)uid;
@end
@implementation DCMAbstractSyntaxUID
+ (BOOL)isPDF:(NSString *)uid { return [uid isEqualToString:@"PDF_UID"]; }
+ (BOOL)isStructuredReport:(NSString *)uid { return [uid isEqualToString:@"SR_UID"]; }
@end

static BOOL needs;
static int asked;
@interface DicomDatabase : NSObject
+ (BOOL)fileNeedsDecompression:(NSString *)path;
@end
@implementation DicomDatabase
+ (BOOL)fileNeedsDecompression:(NSString *)path { asked++; return needs; }
@end

AVAILABLE

static BOOL oldBelowLimit(unsigned long long size, unsigned long long free)
{
    NSNumber *dataBasePathSize = @(size), *dataBasePathFreeSize = @(free);
    (void)dataBasePathFreeSize;
    BOOL _isFileSystemFreeSizeLimitReached;
    FREE
    return _isFileSystemFreeSizeLimitReached;
}

static int oldMaximum(NSInteger preference)
{
    CLAMP
    return maxNumberOfFiles;
}

static NSString *oldEntry(NSString *lastPathComponent)
{
    LITTER0 return @"litter";
    LITTER1 return @"litter";
    LITTER2 return @"hidden";
    return @"candidate";
}

static BOOL oldTranscodes(BOOL mayTranscode, BOOL isJPEGCompressed, int listenerCompressionSettings, NSString *srcPath)
{
    TRANSCODE
    return YES;
    return NO;
}

static NSString *oldQueue(int listenerCompressionSettings)
{
    DECOMPRESS return @"decompress";
    COMPRESS return @"compress";
    return @"none";
}

CLOUD

static NSMutableArray *recorded;
static BOOL record(NSData *data, NSUInteger offset, NSUInteger length)
{
    NSData *part = [data subdataWithRange:NSMakeRange(offset, length)];
    [recorded addObject:[NSString stringWithFormat:@"%lu-%lu", (unsigned long)offset, (unsigned long)(offset + part.length)]];
    return YES;
}

static NSString *oldMultipart(NSString *path)
{
    recorded = [NSMutableArray array];
    BOOL dicomFileCreated = NO;
    // As the scan read it: the first WADORSSIZE bytes, and the rest from the file.
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];
    NSMutableData *data = [NSMutableData data];
    [data appendData:[file readDataOfLength:WADORSSIZE]];
    NSString *raised = @"0";
    BOOL announced = NO;
    @try {
        if (data.length >= WADORSSIZE && [data rangeOfData:[@"application/dicom;" dataUsingEncoding:NSASCIIStringEncoding] options:0 range:NSMakeRange(0, WADORSSIZE)].location != NSNotFound)
            announced = YES;
        MULTIPART
    } @catch (NSException *e) { raised = @"1"; }
    [file closeFile];
    (void)dicomFileCreated;
    return [NSString stringWithFormat:@"%d %@ %@", announced, [recorded componentsJoinedByString:@","], raised];
}

int main(int argc, char **argv) { @autoreleasepool {
    NSString *manifest = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]] encoding:NSUTF8StringEncoding error:NULL];
    for (NSString *line in [manifest componentsSeparatedByString:@"\n"]) {
        if (line.length == 0) continue;
        NSArray *f = [line componentsSeparatedByString:@"\t"];
        NSString *kind = f[0], *out = nil;
        if ([kind isEqualToString:@"available"]) out = availablePathInDirectory(f[1], f[2]);
        else if ([kind isEqualToString:@"free"]) out = oldBelowLimit(strtoull([f[1] UTF8String], NULL, 10), strtoull([f[2] UTF8String], NULL, 10)) ? @"1" : @"0";
        else if ([kind isEqualToString:@"max"]) out = [NSString stringWithFormat:@"%d", oldMaximum((NSInteger)strtoll([f[1] UTF8String], NULL, 10))];
        else if ([kind isEqualToString:@"entry"]) out = oldEntry(f[1]);
        else if ([kind isEqualToString:@"transcode"]) {
            needs = [f[4] intValue]; asked = 0;
            BOOL decided = oldTranscodes([f[1] intValue], [f[2] intValue], [f[3] intValue], @"file.dcm");
            out = [NSString stringWithFormat:@"%d asked %d", decided, asked];
        }
        else if ([kind isEqualToString:@"queue"]) out = oldQueue([f[1] intValue]);
        else if ([kind isEqualToString:@"cloud"]) {
            NSMutableDictionary *dict = [NSMutableDictionary dictionary];
            NSArray *keys = @[@"SOPClassUID", @"modality", @"seriesDescription", @"manufacturer"];
            for (NSUInteger k = 0; k < keys.count; k++) if (field(f[k + 1])) dict[keys[k]] = field(f[k + 1]);
            out = HorosIncomingLooksLikeCloudReport(dict) ? @"1" : @"0";
        }
        else if ([kind isEqualToString:@"multipart"]) out = oldMultipart(f[1]);
        printf("%s\t%s\n", [line UTF8String], [out UTF8String]);
    }
} return 0; }
'''
for name, text in (('AVAILABLE', available), ('FREE', free_space), ('CLAMP', clamp), ('LITTER0', litter[0]),
                   ('LITTER1', litter[1]), ('LITTER2', litter[2]), ('TRANSCODE', transcode),
                   ('DECOMPRESS', decompress_queue), ('COMPRESS', compress_queue), ('CLOUD', cloud),
                   ('MULTIPART', multipart)):
    OBJC = OBJC.replace(name, text)

SWIFT = r'''
import Foundation
import IsiXDatabase

func field(_ value: String) -> String? { value == "<nil>" ? nil : value }

let manifest = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
for line in manifest.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
    let f = line.components(separatedBy: "\t")
    var out = ""
    switch f[0] {
    case "available":
        out = AvailablePath.inDirectory(f[1], name: f[2])
    case "free":
        out = StorageFreeSpace.isBelowLimit(sizeBytes: UInt64(f[1])!, freeBytes: UInt64(f[2])!) ? "1" : "0"
    case "max":
        out = String(IncomingScanRules.maximumFiles(preference: Int(f[1])!))
    case "entry":
        switch IncomingScanRules.entry(named: f[1]) {
        case .systemLitter: out = "litter"
        case .hidden: out = "hidden"
        case .candidate: out = "candidate"
        }
    case "transcode":
        var asked = 0
        let decided = IncomingScanRules.queuesForConversion(mayTranscode: f[1] == "1", isCompressed: f[2] == "1",
                                                            listenerCompressionSettings: Int(f[3])!,
                                                            needsCompression: { asked += 1; return f[4] == "1" })
        out = "\(decided ? 1 : 0) asked \(asked)"
    case "queue":
        switch IncomingScanRules.queue(forListenerCompressionSettings: Int(f[1])!) {
        case .decompress: out = "decompress"
        case .compress: out = "compress"
        case .none: out = "none"
        }
    case "cloud":
        // As DicomDatabase+Import.swift asks: the SOP Class first, then the rest.
        let sop = field(f[1])
        out = CloudReportCandidate.looksLikeReport(isPDFOrStructuredReport: sop == "PDF_UID" || sop == "SR_UID",
                                                   modality: field(f[2]), seriesDescription: field(f[3]),
                                                   manufacturer: field(f[4])) ? "1" : "0"
    case "multipart":
        let data = FileManager.default.contents(atPath: f[1]) ?? Data()
        let announced = WADORSMultipart.announcesDICOMParts(data.prefix(WADORSMultipart.probeLength))
        if announced {
            let cut = WADORSMultipart.dicomParts(in: data)
            out = "1 " + cut.parts.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ",") + " " + (cut.malformed ? "1" : "0")
        } else {
            out = "0  0"
        }
    default:
        out = "?"
    }
    print("\(line)\t\(out)")
}
'''

# --- the cases ---------------------------------------------------------------
rng = random.Random(1480)


def multipart_body(parts, boundary, payload_sizes, closing=True, noise=b''):
    body = bytearray(noise)
    for size in payload_sizes[:parts]:
        body += b'\r\n' + boundary + b'\r\nContent-Type: application/dicom; transfer-syntax=*\r\n\r\n'
        body += bytes(rng.choice(b'abcdefghij') for _ in range(128)) + b'DICM'
        body += bytes(rng.choice(b'0123456789ABCDEFxyz') for _ in range(size))
    if closing:
        body += b'\r\n' + boundary + b'--\r\n'
    return bytes(body)


def cases(folder):
    lines = []
    # A folder whose names are partly taken.
    taken = folder / 'taken'
    taken.mkdir()
    for name in ('IM1', 'IM1-1', 'IM1-2', 'readme.txt', 'readme-1.txt', 'a.b.dcm', 'a.b-1.dcm', '.hidden', 'x.', 'x-1.'):
        (taken / name).write_bytes(b'')
    crowded = folder / 'crowded'
    crowded.mkdir()
    (crowded / 'f.dcm').write_bytes(b'')
    for k in range(1, 1000):
        (crowded / ('f-%d.dcm' % k)).write_bytes(b'')
    for name in ('IM1', 'IM2', 'readme.txt', 'a.b.dcm', '.hidden', 'x.', 'new.dcm', 'IM1-1', 'tar.gz.zip', 'noext'):
        lines.append('available\t%s\t%s' % (taken, name))
    lines.append('available\t%s\tf.dcm' % crowded)
    lines.append('available\t%s\tg.dcm' % crowded)
    lines.append('available\t%s\tIM1' % (folder / 'missing-folder'))

    mb = 1024 * 1024
    sizes = [0, 1, mb - 1, mb, 99 * mb, 100 * mb, 101 * mb, 30000 * mb - 1, 30000 * mb, 30001 * mb, 2 ** 40, 2 ** 63, 2 ** 64 - 1]
    for size in sizes:
        for free in {0, 1, mb, 2 * mb, 299 * mb, 300 * mb - 1, 300 * mb, 301 * mb, size // 100, size // 100 + mb, size}:
            lines.append('free\t%d\t%d' % (size, free))
    for _ in range(300):
        lines.append('free\t%d\t%d' % (rng.randrange(0, 2 ** 45), rng.randrange(0, 2 ** 40)))

    for preference in (-(2 ** 63), -(2 ** 31) - 1, -1, 0, 99, 100, 101, 5000, 29999, 30000, 30001,
                       2 ** 31 - 1, 2 ** 31, 2 ** 31 + 50, 2 ** 32 + 150, 2 ** 63 - 1):
        lines.append('max\t%d' % preference)
    for _ in range(100):
        lines.append('max\t%d' % rng.randrange(-(2 ** 40), 2 ** 40))

    for name in ('.DS_Store', '.ds_store', '.DS_STORE', '__MACOSX', '__macosx', '_MACOSX', '.', '..', '.horos-extract-1',
                 'IM1', 'a.dcm', 'DS_Store', ' .hidden', '\u00e9t\u00e9', '.\u00e9', 'x' * 300):
        lines.append('entry\t%s' % name)

    for may in (0, 1):
        for compressed in (0, 1):
            for settings in (-1, 0, 1, 2, 3):
                for needs in (0, 1):
                    lines.append('transcode\t%d\t%d\t%d\t%d' % (may, compressed, settings, needs))
    for settings in (-2, -1, 0, 1, 2, 3, 4):
        lines.append('queue\t%d' % settings)

    values = {
        'sop': ['<nil>', 'PDF_UID', 'SR_UID', '1.2.840.10008.5.1.4.1.1.2', ''],
        'modality': ['<nil>', '', 'DOC', 'doc', 'Doc', 'DOCS', 'CT', ' DOC'],
        'text': ['<nil>', '', 'Cloud', 'cloud report', 'iCLOUDy', 'Clou', 'CT HEAD', 'Report'],
    }
    for sop in values['sop']:
        for modality in values['modality']:
            for description in values['text']:
                manufacturer = rng.choice(values['text'])
                lines.append('cloud\t%s\t%s\t%s\t%s' % (sop, modality, description, manufacturer))

    bodies = folder / 'bodies'
    bodies.mkdir()
    made = []
    for index in range(60):
        boundary = b'--' + bytes(rng.choice(b'0123456789abcdef') for _ in range(rng.choice((8, 16, 32, 60, 72, 80))))
        parts = rng.randrange(0, 5)
        payloads = [rng.randrange(0, 3000) for _ in range(5)]
        body = multipart_body(parts, boundary, payloads, closing=rng.random() < 0.8,
                              noise=b'' if rng.random() < 0.7 else bytes(rng.choice(b'pq \r\n') for _ in range(rng.randrange(0, 200))))
        made.append(body)
        made.append(body[:rng.randrange(0, len(body) + 1)])
        mutated = bytearray(body)
        for _ in range(rng.randrange(1, 6)):
            if mutated:
                mutated[rng.randrange(len(mutated))] = rng.choice(b'-\r\nDICM')
        made.append(bytes(mutated))
    made += [b'', b'--', b'application/dicom;' * 100, b'--x\r\n' + b'application/dicom;' * 80 + b'DICM' * 3,
             b'a' * 0x4ff + b'application/dicom;', b'--b\r\napplication/dicom;' + b'z' * 0x500]
    for index, body in enumerate(made):
        path = bodies / ('body-%03d' % index)
        path.write_bytes(body)
        lines.append('multipart\t%s' % path)
    return lines


with tempfile.TemporaryDirectory(prefix='horos-database-rules-') as directory:
    work = Path(directory)
    (work / 'cases').mkdir()
    manifest = work / 'manifest.txt'
    manifest.write_text('\n'.join(cases(work / 'cases')) + '\n', encoding='utf-8')
    (work / 'old.m').write_text(OBJC, encoding='utf-8')
    (work / 'main.swift').write_text(SWIFT, encoding='utf-8')
    modules = isix_modules.module_flags('IsiXDatabase', work / 'IsiXDatabase')
    outputs = {}
    for label, clang_opt, swift_opt in (('Debug', '-O0', '-Onone'), ('Release', '-Os', '-O')):
        old_binary, new_binary = work / ('old-' + label), work / ('new-' + label)
        built = subprocess.run(['xcrun', 'clang', clang_opt, '-fobjc-arc', '-framework', 'Foundation', str(work / 'old.m'),
                                '-o', str(old_binary)], capture_output=True, text=True, timeout=300)
        if built.returncode != 0:
            failures.append('the reference does not compile (%s):\n%s' % (label, built.stderr[-3000:]))
            continue
        built = subprocess.run(['xcrun', 'swiftc', swift_opt, *modules, str(work / 'main.swift'), '-o', str(new_binary)],
                               capture_output=True, text=True, timeout=300)
        if built.returncode != 0:
            failures.append('the Swift driver does not compile (%s):\n%s' % (label, built.stderr[-3000:]))
            continue
        for side, binary in (('old', old_binary), ('new', new_binary)):
            run = subprocess.run([str(binary), str(manifest)], capture_output=True, text=True, timeout=60)
            if run.returncode != 0:
                failures.append('%s %s failed: %s' % (side, label, run.stderr[-1500:]))
            outputs[(side, label)] = run.stdout.splitlines()

    reference_lines = outputs.get(('old', 'Debug'))
    if reference_lines is not None:
        kinds = {}
        for line in reference_lines:
            kinds[line.split('\t', 1)[0]] = kinds.get(line.split('\t', 1)[0], 0) + 1
        for key, lines in outputs.items():
            if key == ('old', 'Debug'):
                continue
            if len(lines) != len(reference_lines):
                failures.append('%s %s printed %d decisions, the reference %d' % (key[0], key[1], len(lines), len(reference_lines)))
                continue
            differing = [(want, got) for want, got in zip(reference_lines, lines) if want != got]
            for want, got in differing[:10]:
                failures.append('%s %s:\n    reference %s\n    got       %s' % (key[0], key[1], want[-300:], got[-300:]))
            if len(differing) > 10:
                failures.append('%s %s: %d more differences' % (key[0], key[1], len(differing) - 10))
        produced = sum(1 for line in reference_lines if line.startswith('multipart') and line.split('\t')[-1].split(' ')[1])
        raised = sum(1 for line in reference_lines if line.startswith('multipart') and line.endswith(' 1'))
        if produced < 20 or raised < 3:
            failures.append('the multipart cases are too thin: %d bodies cut, %d raised' % (produced, raised))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('PASS: %d decisions (%s) of DicomDatabase.mm at %s match IsiXDatabase in Debug and Release'
      % (len(reference_lines), ', '.join('%s %d' % item for item in sorted(kinds.items())), reference[:12]))
