#!/usr/bin/env python3
"""Default report templates: current formats, installed beside what is there.

The defaults the app installs are a .docx for Word and a Pages document in the
current format. A new database gets them; a database that already has templates
- the Pages '09 "Horos Basic Report.pages", the "Basic Report Template.doc" -
keeps every one of them and gets the new ones beside, never over a file of the
same name. And a template Pages saved with "Save as Template" (.template) is
listed and found like a .pages.

The production methods are compiled with stand-ins for the database and the
browser; the shipped templates are the resources they copy. The resources
themselves are checked too: current formats, and nothing but placeholders.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile
sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text

root = Path(__file__).resolve().parents[1]
reports = source_text('Reports')
failures = []

# The resources: a .docx with the merge fields, and a Pages document Pages 5 or
# later wrote - IWA, no index.xml.
docx = root / 'Horos/Resources/ReportTemplate.docx'
pages = root / 'Horos/Resources/ReportTemplate.pages'
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
for resource in (docx, pages):
    if not resource.is_file():
        failures.append(f'{resource.name} is missing')
    elif f'{resource.name} in Resources' not in project:
        failures.append(f'{resource.name} is not copied into the app')
for former in ('ReportTemplate.doc in Resources', 'Horos Report.pages in Resources'):
    if former in project:
        failures.append(f'the former default is still shipped: {former}')
if docx.is_file():
    document = zipfile.ZipFile(docx).read('word/document.xml').decode()
    for field in ('referringPhysician', 'name', 'patientID', 'dateOfBirth', 'accessionNumber', 'modality',
                  'studyName', 'date', 'performingPhysician', 'institutionName', 'numberOfImages'):
        if f' MERGEFIELD {field} ' not in document:
            failures.append(f'the Word template lacks the merge field {field}')
if pages.is_file():
    names = zipfile.ZipFile(pages).namelist()
    if 'Index/Document.iwa' not in names or 'index.xml' in names:
        failures.append('the Pages template is not in the current Pages format')

def between(start, end):
    first = reports.index(start)
    return reports[first:reports.index(end, first)]

methods = '\n'.join([
    between('    @objc public class func checkForWordTemplates() {', '    @objc public class func databaseWordTemplatesDirPath()'),
    between('    @objc public class func checkForPagesTemplate() {', '    @objc(Pages5orHigher)'),
    between('    @objc(pathForPagesTemplate:)', '    @objc(copyPages4templatesToPages5:)'),
    between('    /// A document or a template Pages saved', '    @objc public func templateName()'),
])
prelude = reports[reports.index('/// What `%@` prints'):reports.index('/** \\brief reports */')]
bridge = r'''
#import <Foundation/Foundation.h>
#import "HorosObjCException.h"
'''
program = r'''
import Foundation
import Synchronization
var base = ""
final class Database { var baseDirPath: String? { base } }
final class BrowserController {
    static func currentBrowser() -> BrowserController? { nil }
    var database: Database? { Database() }
}
enum DicomDatabase { static func defaultBaseDirPath() -> String { base } }
func _N2LogExceptionImpl(_ exception: NSException, _ fatal: Bool, _ context: String) {}
PRELUDE
final class Reports: NSObject {
    private static let pagesTemplatesFirstTime = Atomic<Bool>(false)
    class func databaseWordTemplatesDirPath() -> String! { folder("WORD TEMPLATES") }
    class func databasePagesTemplatesDirPath() -> String! { folder("PAGES TEMPLATES") }
    class func pages5orHigher() -> Int32 { 1 }
    class func copyPages4templatesToPages5(_ directory: String!) {}
    class func folder(_ name: String) -> String {
        let path = (base as NSString).appendingPathComponent(name)
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
METHODS
}
func check(_ value: Bool, _ what: String, line: Int = #line) {
    if !value { print("FAIL: \(what) (line \(line))"); exit(1) }
}
func contents(_ folder: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: (base as NSString).appendingPathComponent(folder))) ?? []).sorted()
}
func bytes(_ folder: String, _ name: String) -> Data? {
    FileManager.default.contents(atPath: ((base as NSString).appendingPathComponent(folder) as NSString).appendingPathComponent(name))
}
let resources = Bundle.main.resourcePath!
let shippedDocx = FileManager.default.contents(atPath: (resources as NSString).appendingPathComponent("ReportTemplate.docx"))
let shippedPages = FileManager.default.contents(atPath: (resources as NSString).appendingPathComponent("ReportTemplate.pages"))
check(shippedDocx != nil && shippedPages != nil, "resources beside the test")

// A new database: the two new defaults, and nothing else.
base = CommandLine.arguments[1] + "/new"
Reports.checkForWordTemplates()
Reports.checkForPagesTemplate()
check(contents("WORD TEMPLATES") == ["Basic Report Template.docx"], "new Word default: \(contents("WORD TEMPLATES"))")
check(contents("PAGES TEMPLATES") == ["IsiX Basic Report.pages"], "new Pages default: \(contents("PAGES TEMPLATES"))")
check(bytes("WORD TEMPLATES", "Basic Report Template.docx") == shippedDocx, "Word default copied")
check(bytes("PAGES TEMPLATES", "IsiX Basic Report.pages") == shippedPages, "Pages default copied")
check(Reports.pagesTemplatesList() as! [String] == ["IsiX Basic Report.pages"], "listed")

// A database that already has templates, the former defaults among them and a
// file that already carries the new default's name.
base = CommandLine.arguments[1] + "/existing"
let existing: [(String, String)] = [
    ("WORD TEMPLATES", "Basic Report Template.doc"), ("WORD TEMPLATES", "Mine.docx"),
    ("PAGES TEMPLATES", "Horos Basic Report.pages"), ("PAGES TEMPLATES", "IsiX Basic Report.pages"),
]
for (folder, name) in existing {
    check(FileManager.default.createFile(atPath: (Reports.folder(folder) as NSString).appendingPathComponent(name),
                                         contents: Data("user \(name)".utf8)), name)
}
Reports.checkForWordTemplates()
Reports.checkForPagesTemplate()
check(contents("WORD TEMPLATES") == ["Basic Report Template.doc", "Basic Report Template.docx", "Mine.docx"], "Word beside")
check(contents("PAGES TEMPLATES") == ["Horos Basic Report.pages", "IsiX Basic Report.pages"], "Pages beside")
for (folder, name) in existing {
    check(bytes(folder, name) == Data("user \(name)".utf8), "\(name) untouched")
}
check(bytes("WORD TEMPLATES", "Basic Report Template.docx") == shippedDocx, "new Word default added")
// Run again: still nothing replaced, nothing duplicated.
Reports.checkForWordTemplates()
Reports.checkForPagesTemplate()
check(contents("WORD TEMPLATES").count == 3 && contents("PAGES TEMPLATES").count == 2, "idempotent")

// The template the very first versions kept in the database folder still moves
// into WORD TEMPLATES when that folder has none.
base = CommandLine.arguments[1] + "/legacy"
try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
check(FileManager.default.createFile(atPath: base + "/ReportTemplate.doc", contents: Data("legacy".utf8)), "legacy")
Reports.checkForWordTemplates()
check(contents("WORD TEMPLATES") == ["Basic Report Template.docx", "ReportTemplate.doc"], "legacy moved: \(contents("WORD TEMPLATES"))")
check(bytes("WORD TEMPLATES", "ReportTemplate.doc") == Data("legacy".utf8), "legacy bytes")

// A .template is listed beside the .pages, and each menu title finds its file.
base = CommandLine.arguments[1] + "/templates"
for name in ["A.pages", "A.template", "B.template", "C.TEMPLATE", "notes.txt", "D.docx"] {
    check(FileManager.default.createFile(atPath: (Reports.folder("PAGES TEMPLATES") as NSString).appendingPathComponent(name),
                                         contents: Data(name.utf8)), name)
}
check(Reports.pagesTemplatesList() as! [String] == ["A.pages", "A.template", "B.template", "C.TEMPLATE"],
      "listed: \(Reports.pagesTemplatesList()!)")
func found(_ name: String) -> String? { (Reports.pathForPagesTemplate(name) as NSString?)?.lastPathComponent }
check(found("A.template") == "A.template", "the exact .template")
check(found("A.pages") == "A.pages", "the exact .pages")
check(found("A") == "A.pages", "a bare name prefers the .pages")
check(found("B") == "B.template", "a bare name finds a .template")
check(found("B.pages") == "B.template", "same stem")
check(found("C.TEMPLATE") == "C.TEMPLATE", "any case")
check(found("notes") == nil && found("D") == nil, "not a Pages file")
check(found("") == "A.pages", "no name: the first listed")
print("PASS: new databases get the .docx and current-format Pages defaults; existing templates are kept and the new ones go beside; .template files are listed and found")
'''.replace('METHODS', methods).replace('PRELUDE', prelude)
with tempfile.TemporaryDirectory(prefix='horos-report-defaults-') as folder:
    p = Path(folder)
    (p / 'bridge.h').write_text(bridge)
    (p / 'main.swift').write_text(program)
    for resource in (docx, pages):
        if resource.is_file():
            shutil.copy(resource, p / resource.name)
    compiled = subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-I', str(root / 'Horos/Sources'), '-c',
                               str(root / 'Horos/Sources/HorosObjCException.m'), '-o', str(p / 'exception.o')]).returncode == 0
    compiled = compiled and subprocess.run(['xcrun', 'swiftc', '-import-objc-header', str(p / 'bridge.h'),
                                            '-Xcc', '-I', '-Xcc', str(root / 'Horos/Sources'), str(p / 'main.swift'),
                                            str(p / 'exception.o'), '-o', str(p / 'test')]).returncode == 0
    (p / 'run').mkdir()
    if not compiled:
        failures.append('the production template methods did not compile')
    elif subprocess.run([str(p / 'test'), str(p / 'run')]).returncode:
        failures.append('the default templates are not installed as they should be')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: default report templates in current formats, installed beside existing ones')
