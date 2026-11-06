#!/usr/bin/env python3
"""Generating DICOM PDFs for a selection indexes each file once.

`-[BrowserController convertReportToDICOMSR:]` - the menu item that writes the
selected studies' reports as DICOM PDFs - called `-addFilesAtPaths:…` inside its
loop, always with the whole list accumulated so far. For N studies the first file
was indexed N times, the second N-1, and so on: N(N+1)/2 additions, each one
rereading a file already indexed (`rereadExistingItems:YES`).

The shipped method, StudyReports.convertSelectionToDICOMPDF (StudyReports.swift),
to which the browser's action forwards, is compiled here with xcrun swiftc (with
the guards of HorosObjCException, and studies that raise
from Objective-C) over four studies, one of whose reports cannot be converted:

* one addition, with the three files that were written;
* the study that failed is named to the user and its file is not indexed;
* nothing is indexed when no report could be converted.

    python3 tests/test-report-dicom-pdf-batch.py [<git revision>]
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import shutil
import subprocess
import sys
sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))
import objc_exception_guards
import tempfile

root = Path(__file__).resolve().parents[1]
# The report actions of BrowserController are StudyReports'.
path = 'Horos/Sources/StudyReports.swift'


def read(path):
    return (subprocess.check_output(['git', '-C', str(root), 'show', sys.argv[1] + ':' + path])
            if len(sys.argv) > 1 else (root / path).read_bytes()).decode('utf-8')


source = read(path)
support = read('Horos/Sources/BrowserController+DatabaseSupport.swift')


def member(text, signature):
    """The member of `text` that starts with `signature`, from its line to its closing brace."""
    begin = text.rindex('\n', 0, text.index(signature)) + 1
    depth, at = 0, text.index('{', begin)
    while True:
        depth += {'{': 1, '}': -1}.get(text[at], 0)
        at += 1
        if depth == 0:
            return text[begin:at] + '\n'


method = member(source, 'func convertSelectionToDICOMPDF()')
helpers = member(source, 'private static func study(of item: Any?)') + member(source, 'private func reportError(')
attempt = objc_exception_guards.between('BrowserObjC')

# The studies raise from Objective-C, as the app's DicomStudy does.
header = r'''
#import <Foundation/Foundation.h>
#import "HorosObjCException.h"
@interface DicomStudy : NSObject
@property(copy) NSString *name;
@property BOOL failing;
- (void)saveReportAsDicomAtPath:(NSString*)path;
@end
'''

studies = r'''
#import "harness.h"
@implementation DicomStudy
- (void)saveReportAsDicomAtPath:(NSString*)path {
    if (self.failing)
        [NSException raise:NSGenericException format:@"The report could not be converted to PDF."];
    [[NSData dataWithBytes:"DICM" length:4] writeToFile:path atomically:YES];
}
@end
'''

code = r'''
import AppKit

var additions = 0, indexed = 0, alerts = 0
var alerted: [String] = []

enum HorosAlertPanel {
    @discardableResult
    static func run(title: String, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int {
        alerts += 1
        alerted.append(message)
        return 1
    }
}

final class Database: NSObject {
    var directory = ""
    var number = 0
    func uniquePathForNewDataFile(withExtension ext: String!) -> String! {
        number += 1
        return (directory as NSString).appendingPathComponent("report-\(number).\(ext!)")
    }
    func addFiles(atPaths paths: [Any]?, postNotifications: Bool, dicomOnly: Bool, rereadExistingItems: Bool, generatedByOsiriX: Bool) {
        additions += 1
        indexed += paths?.count ?? 0
    }
}

// As the real one: the indexing of what was generated, on the database's own method.
enum IngestPreset { case generated }
struct DatabaseIngest {
    static let process = DatabaseIngest()
    func index(_ paths: [Any]?, preset: IngestPreset, in database: Database) {
        database.addFiles(atPaths: paths, postNotifications: true, dicomOnly: true, rereadExistingItems: true, generatedByOsiriX: true)
    }
}

extension NSException {
    @discardableResult func printStackTrace() -> String { return callStackSymbols.joined(separator: "\n") }
}

enum BrowserObjC {
ATTEMPT
}

final class DicomSeries: NSObject {
    var study: DicomStudy!
}

final class BrowserController: NSObject {
    var database: Database? = Database()
    var selection: [Any] = []
    func databaseSelection() -> [Any]! { return selection }
}

final class StudyReports {
    let browser = BrowserController()
    var toolbarUpdates = 0
    func updateToolbarIconSoon() { toolbarUpdates += 1 }
HELPERS
METHOD
}

func study(_ name: String, _ failing: Bool) -> DicomStudy {
    let s = DicomStudy()
    s.name = name
    s.failing = failing
    return s
}

@main
struct Main {
    static func main() {
        let reports = StudyReports()
        let browser = reports.browser
        browser.database?.directory = CommandLine.arguments[1]
        var failed = 0

        // A series stands for its study, which is converted once.
        let series = DicomSeries()
        let c = study("C", false)
        series.study = c
        browser.selection = [study("A", false), study("B", true), c, series, study("D", false)]
        reports.convertSelectionToDICOMPDF()
        if additions != 1 { print("FAIL: \(additions) additions for four studies, one expected"); failed += 1 }
        if indexed != 3 { print("FAIL: \(indexed) files indexed, the three that were written expected"); failed += 1 }
        if alerts != 1 || !(alerted.last?.contains("B") ?? false) {
            print("FAIL: the study whose report failed is not named: \(alerts) alerts, \(alerted)")
            failed += 1
        }

        additions = 0; indexed = 0; alerts = 0
        alerted.removeAll()
        browser.selection = [study("E", true)]
        reports.convertSelectionToDICOMPDF()
        if additions != 0 || indexed != 0 { print("FAIL: \(additions) additions with nothing written"); failed += 1 }
        if alerts != 1 { print("FAIL: nothing was said about the only report, which failed"); failed += 1 }
        if reports.toolbarUpdates != 2 { print("FAIL: the report toolbar item is not updated after each conversion"); failed += 1 }

        if failed > 0 { exit(1) }
        print("ok")
    }
}
'''.replace('HELPERS', helpers).replace('METHOD', method).replace('ATTEMPT', attempt)

with tempfile.TemporaryDirectory(prefix='horos-pdf-batch-') as temporary:
    work = Path(temporary)
    for name in ('HorosObjCException.h', 'HorosObjCException.m'):
        shutil.copy(root / 'Horos/Sources' / name, work / name)
    (work / 'harness.h').write_text(header)
    (work / 'studies.m').write_text(studies)
    (work / 'main.swift').write_text(code)
    files = work / 'files'
    files.mkdir()
    objects = []
    for name in ('HorosObjCException', 'studies'):
        built = subprocess.run(['xcrun', 'clang', '-x', 'objective-c', '-fobjc-arc', '-fobjc-exceptions', '-iquote', str(work),
                                '-c', str(work / (name + '.m')), '-o', str(work / (name + '.o'))], capture_output=True, text=True)
        if built.returncode != 0:
            print('FAIL: the doubles do not build: ' + built.stderr[-2000:])
            raise SystemExit(1)
        objects.append(str(work / (name + '.o')))
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                            '-import-objc-header', str(work / 'harness.h'), '-Xcc', '-iquote', '-Xcc', str(work),
                            str(work / 'main.swift'), *objects, '-framework', 'AppKit', '-o', str(work / 'probe')],
                           capture_output=True, text=True)
    if built.returncode != 0:
        print('FAIL: the method does not build: ' + built.stderr[-2000:])
        raise SystemExit(1)
    run = subprocess.run([str(work / 'probe'), str(files)], capture_output=True, text=True, timeout=60)
    if run.returncode != 0:
        print((run.stdout + run.stderr).strip() or f'FAIL: exit {run.returncode}')
        raise SystemExit(1)
print('DICOM PDF batch: one indexing of the files written, and the failed report named')
