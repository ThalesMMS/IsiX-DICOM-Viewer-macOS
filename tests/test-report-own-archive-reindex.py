#!/usr/bin/env python3
"""Indexing the app's own report SR keeps the study on the file being edited.

When the app becomes active it archives each changed report as a DICOM SR and
indexes that SR. The importer compares the attached report with the SR's
contents and, when they differ, moves the study to a new file extracted from
the SR. Pages saves the document when it loses focus, which is the moment the
app becomes active, so the save can land between the copy and the comparison:
the study then moved to an older copy, the document still open in Pages was no
longer its report, and every report command opened another copy.

Compiles the production report branch of the importer from DicomDatabase.mm,
with the production HorosReportsHaveSameContents and ReportArchiveIndexing,
and checks that:

- an SR the study archived itself, indexed while registered, keeps the attached
  file even though the file changed during the archive;
- a report SR from elsewhere, with other contents, is still attached as a new
  file, and the previous report is not overwritten;
- the registration covers the same file reached through /tmp or /private/tmp,
  ends with the indexing, and the archive registers its SR around the indexing.

`<git revision>` as an optional argument reads the importer and the archive from
that revision, the negative control.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def read(path):
    if revision:
        result = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], capture_output=True)
        return result.stdout.decode('utf-8', 'replace') if result.returncode == 0 else None
    file = root / path
    return file.read_text(encoding='utf-8', errors='replace') if file.exists() else None


def block(text, opening_line):
    at = text.find(opening_line)
    if at < 0:
        return None
    opening = text.index('{', at + len(opening_line))
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[at:index + 1]
    return None


database = read('Horos/Sources/DicomDatabase.mm') or ''
study = read('Horos/Sources/DicomStudy.swift') or ''
project = read('Horos.xcodeproj/project.pbxproj') or ''
registry = (root / 'Horos/Sources/ReportArchiveIndexing.swift')

branch = block(database, 'if (DICOMSR && [[curDict valueForKey:@"seriesDescription"] isEqualToString: @"OsiriX Report SR"])')
archive = block(study, 'public dynamic func archiveReportAsDICOMSR()') or ''
if branch is None:
    failures.append('the report branch of the importer was not found in DicomDatabase.mm')
if 'ReportArchiveIndexing.indexing(dstPath)' not in archive or \
        archive.find('ReportArchiveIndexing.indexing(dstPath)') > archive.find('dicomStudyAddGeneratedFiles(idb'):
    failures.append('archiveReportAsDICOMSR does not register its SR around the indexing')
if 'ReportArchiveIndexing.swift in Sources' not in project:
    failures.append('ReportArchiveIndexing.swift is not compiled into the app')
if not registry.exists():
    failures.append('ReportArchiveIndexing.swift does not exist')

header = r'''
#import <Foundation/Foundation.h>
#ifdef __cplusplus
extern "C"
#endif
NSString *HarnessImport(NSString *srPath, NSString *attachedReport, NSString *extracted, NSString *reportsDirectory);
'''

harness = r'''
#import "harness.h"
#import "HorosReportFileReplacement.h"

@interface HorosReportArchiveIndexing : NSObject
+ (BOOL)isIndexingOwnArchiveAtPath:(NSString *)path;
@end

typedef NSObject N2ManagedObjectContext;
typedef NSObject DicomImage;

// Production names the new file this way; the transaction around it is not
// what is tested here.
static NSString *HorosPrepareImportedReport(N2ManagedObjectContext *context, NSString *extractedPath,
                                            NSString *reportsDirectory, NSError **error)
{
    NSString *filename = [NSString stringWithFormat:@"%@-%@", NSUUID.UUID.UUIDString, extractedPath.lastPathComponent];
    NSString *destination = [reportsDirectory stringByAppendingPathComponent:filename];
    return [NSFileManager.defaultManager moveItemAtPath:extractedPath toPath:destination error:error] ? destination : nil;
}

@interface Study : NSObject
@property (strong) NSMutableDictionary *values;
@property (strong) DicomImage *image;
@end
@implementation Study
- (NSString *)reportURL { return self.values[@"reportURL"]; }
- (DicomImage *)reportImage { return self.image; }
- (void)setPrimitiveValue:(id)value forKey:(NSString *)key
{
    if (value) self.values[key] = value; else [self.values removeObjectForKey:key];
}
@end

@interface Importer : NSObject
@property (strong) id managedObjectContext;
@end
@implementation Importer
- (NSString *)import:(NSString *)newFile study:(Study *)study extracted:(NSString *)preparedReportPath
           directory:(NSString *)reportsDirPath
{
    BOOL DICOMSR = YES;
    NSDictionary *curDict = @{@"seriesDescription": @"OsiriX Report SR", @"patientName": @"SYNTHETIC^REPORT"};
    DicomImage *image = study.image;
    BRANCH
    return [study reportURL];
}
@end

NSString *HarnessImport(NSString *srPath, NSString *attachedReport, NSString *extracted, NSString *reportsDirectory)
{
    Study *study = [Study new];
    study.values = [NSMutableDictionary dictionaryWithObject:attachedReport forKey:@"reportURL"];
    study.image = [NSObject new];
    return [[Importer new] import:srPath study:study extracted:extracted directory:reportsDirectory];
}
'''

driver = r'''
import Foundation

let directory = CommandLine.arguments[1]
let manager = FileManager.default
let reports = (directory as NSString).appendingPathComponent("REPORTS")
let attached = (reports as NSString).appendingPathComponent("SYNTHETIC-1.pages")
let sr = (directory as NSString).appendingPathComponent("sr.dcm")
var failures: [String] = []

func write(_ text: String, _ path: String) {
    try! manager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: URL(fileURLWithPath: path))
}
func contents(_ path: String) -> String? {
    return (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { String(data: $0, encoding: .utf8) }
}
func copies() -> [String] {
    return ((try? manager.contentsOfDirectory(atPath: reports)) ?? []).filter { $0 != "SYNTHETIC-1.pages" }
}
/// The report as the SR carries it: the version before the editor's last save.
func extracted() -> String {
    let path = (directory as NSString).appendingPathComponent("extracted-\(UUID().uuidString)/SYNTHETIC-1.pages")
    write("first draft", path)
    return path
}

write("archived", sr)
write("first draft and the last sentence", attached)

// Own archive: the editor saved between the copy and the comparison.
var result: String? = nil
ReportArchiveIndexing.indexing(sr) {
    result = HarnessImport(sr, attached, extracted(), reports)
}
if result != attached { failures.append("the study's own SR moved it to \(result ?? "no report")") }
if !copies().isEmpty { failures.append("the study's own SR left copies in REPORTS: \(copies())") }
if contents(attached) != "first draft and the last sentence" { failures.append("the edited report changed") }

// The same SR reached through a symbolic link, as /tmp is to /private/tmp.
let link = (directory as NSString).appendingPathComponent("link")
try! manager.createSymbolicLink(atPath: link, withDestinationPath: directory)
let other = (link as NSString).appendingPathComponent("sr.dcm")
var seen = false
ReportArchiveIndexing.indexing(other) { seen = ReportArchiveIndexing.isIndexingOwnArchive(atPath: sr) }
if !seen { failures.append("\(other) and \(sr) were not the same SR") }
var nested = false
ReportArchiveIndexing.indexing(sr) {
    ReportArchiveIndexing.indexing(sr) {}
    nested = ReportArchiveIndexing.isIndexingOwnArchive(atPath: sr)
}
if !nested { failures.append("an inner indexing of the same SR ended the outer registration") }
if ReportArchiveIndexing.isIndexingOwnArchive(atPath: sr) { failures.append("the registration outlived the indexing") }
if ReportArchiveIndexing.isIndexingOwnArchive(atPath: nil) || ReportArchiveIndexing.isIndexingOwnArchive(atPath: "") {
    failures.append("an empty path counted as registered")
}
var ran = false
ReportArchiveIndexing.indexing(nil) { ran = true }
if !ran { failures.append("indexing without a path did not run its body") }

// A report SR from elsewhere, with other contents, is attached as a new file.
result = HarnessImport(sr, attached, extracted(), reports)
let received = copies()
if result == attached || received.count != 1 {
    failures.append("a received report SR was not attached: \(result ?? "no report"), copies \(received)")
} else if contents((reports as NSString).appendingPathComponent(received[0])) != "first draft" {
    failures.append("the received report does not hold the SR's contents")
}
if contents(attached) != "first draft and the last sentence" { failures.append("a received report overwrote the previous one") }

for failure in failures { print("FAIL: \(failure)") }
exit(failures.isEmpty ? 0 : 1)
'''

if branch is not None and registry.exists():
    with tempfile.TemporaryDirectory(prefix='horos-own-report-archive-') as directory:
        work = Path(directory)
        (work / 'harness.h').write_text(header)
        (work / 'harness.mm').write_text(harness.replace('BRANCH', branch))
        (work / 'main.swift').write_text(driver)
        compile_objc = subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', '-x', 'objective-c++',
                                       '-I', str(root / 'Horos/Sources'), '-I', str(work),
                                       str(work / 'harness.mm'), '-o', str(work / 'harness.o')],
                                      capture_output=True, text=True)
        if compile_objc.returncode != 0:
            failures.append('the importer branch does not compile:\n' + compile_objc.stderr[-3000:])
        else:
            link = subprocess.run(['xcrun', 'swiftc', '-import-objc-header', str(work / 'harness.h'),
                                   str(registry), str(work / 'main.swift'), str(work / 'harness.o'),
                                   '-lc++', '-o', str(work / 'driver')], capture_output=True, text=True)
            if link.returncode != 0:
                failures.append('the driver does not build:\n' + link.stderr[-3000:])
            else:
                data = work / 'data'
                data.mkdir()
                run = subprocess.run([str(work / 'driver'), str(data)], capture_output=True, text=True)
                failures += [line[len('FAIL: '):] for line in run.stdout.splitlines() if line.startswith('FAIL: ')]
                if run.returncode != 0 and not run.stdout.strip():
                    failures.append('the driver failed:\n' + run.stderr[-3000:])

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: indexing the study\'s own report SR keeps the file being edited; received reports are still attached')
