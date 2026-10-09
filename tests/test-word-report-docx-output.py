#!/usr/bin/env python3
"""A Word report keeps the format of its template: .docx gives .docx, .doc gives .doc.

The destination of a Word report used to be built with a fixed `doc`
extension, so the merge script was always told to save Word 97-2003, even from
a .docx template. The production methods are compiled here with stand-ins for
Word and the study: the destination chosen for each template, and the format
argument the merge script receives, are checked. Word itself is not launched.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text

root = Path(__file__).resolve().parents[1]
reports = source_text('Reports')
failures = []

case = reports[reports.index('        case 0:'):reports.index('        case 1:')]
if 'wordReportDestination(inDirectory:' not in case or '"doc"' in case:
    failures.append('the Word destination is not chosen from the template')

start = reports.index('    @objc(createNewWordReportForStudy:toDestinationPath:)')
method = reports[start:reports.index('\n    // MARK: -\n    // MARK: OpenDocument', start)]
if 'func pathForWordTemplate' not in method or 'func wordReportDestination' not in method:
    failures.append('the template lookup and the destination are not beside the merge')
prelude = reports[reports.index('/// What `%@` prints'):reports.index('/** \\brief reports */')]
bridge = r'''
#import <Foundation/Foundation.h>
#import "HorosObjCException.h"
#import "HorosReportFileReplacement.h"
'''
program = r'''
import Foundation
typealias NSManagedObject = NSMutableDictionary
var templates = "", formats: [String] = [], outputs: [String] = []
enum HorosAlertPanel {
    static func runCritical(title: String?, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int { 0 }
}
enum WordReportAutomation { static func consentErrorWithoutPrompt() -> NSError? { nil } }
final class NSWorkspace {
    static let shared = NSWorkspace()
    @discardableResult func openDocument(atPath path: String, applicationIdentifiers: [String]) -> Bool { true }
}
PRELUDE
final class Reports: NSObject {
    let templateNameStorage = NSMutableString(string: "")
    func setTemplateName(_ name: String) { templateNameStorage.setString(name) }
    class func wordTemplatesList() -> NSMutableArray! {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: templates)) ?? []).sorted()
        return NSMutableArray(array: names)
    }
    class func resolvedDatabaseWordTemplatesDirPath() -> String! { templates }
    // Word, as far as the report sees it: the merge writes the output it is given.
    class func _runAppleScript(_ source: String!, withArguments args: NSArray!) -> Any! {
        let arguments = args as! [String]
        precondition(source.contains("file format format document add to recent files false"), "docx branch")
        precondition(source.contains("file format format document97 add to recent files false"), "doc branch")
        formats.append(arguments[3])
        outputs.append(arguments[1])
        precondition((try? "merged \(arguments[3])".write(toFile: arguments[1], atomically: true, encoding: .utf8)) != nil)
        return NSNumber(value: true)
    }
    func generateWordReportMergeData(forStudy study: NSManagedObject!, toPath path: String!) -> String! { path }
METHOD
}
func check(_ value: Bool, _ what: String, line: Int = #line) {
    if !value { print("FAIL: \(what) (line \(line))"); exit(1) }
}
let dir = CommandLine.arguments[1]
templates = (dir as NSString).appendingPathComponent("templates")
let reportsDir = (dir as NSString).appendingPathComponent("reports") + "/"
for folder in [templates, reportsDir] {
    check((try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)) != nil, "folders")
}
for name in ["Basic Report Template.doc", "Basic Report Template.docx", "Modern.docx", "Old.doc", "Upper.DOCX"] {
    check(FileManager.default.createFile(atPath: (templates as NSString).appendingPathComponent(name), contents: Data(name.utf8)), name)
}
func make(_ template: String, _ unique: String) -> String {
    let report = Reports()
    report.setTemplateName(template)
    let destination = report.wordReportDestination(inDirectory: reportsDir, uniqueFilename: unique)
    check(report.createNewWordReport(forStudy: NSMutableDictionary(), toDestinationPath: destination), "created from \(template)")
    check(FileManager.default.fileExists(atPath: destination), "published \(destination)")
    return destination
}
check(make("Modern.docx", "a").hasSuffix("/reports/a.docx") && formats.last == "docx", "docx template, docx report")
check(outputs.last!.hasSuffix("-merged.docx"), "Word saves a .docx")
check(make("Old.doc", "b").hasSuffix("/reports/b.doc") && formats.last == "doc", "doc template, doc report")
check(outputs.last!.hasSuffix("-merged.doc"), "Word saves a .doc")
check(make("Upper.DOCX", "c").hasSuffix("/reports/c.docx") && formats.last == "docx", "the extension is read without case")
// Both defaults side by side: the menu title names one, extension included.
check(make("Basic Report Template.docx", "d").hasSuffix(".docx") && formats.last == "docx", "new default")
check(make("Basic Report Template.doc", "e").hasSuffix(".doc") && formats.last == "doc", "former default")
// No name given: the first template listed, and its format.
check(make("", "f").hasSuffix("/reports/f.doc") && formats.last == "doc", "first listed is the .doc")
for name in ["Basic Report Template.doc", "Old.doc"] {
    try? FileManager.default.removeItem(atPath: (templates as NSString).appendingPathComponent(name))
}
check(make("", "g").hasSuffix("/reports/g.docx") && formats.last == "docx", "first listed is a .docx")
check((try? String(contentsOfFile: reportsDir + "g.docx", encoding: .utf8)) == "merged docx", "the merged file is the report")
print("PASS: a .docx template gives a .docx report that Word is told to save as docx; a .doc template still gives .doc")
'''.replace('METHOD', method).replace('PRELUDE', prelude)
with tempfile.TemporaryDirectory(prefix='horos-word-docx-') as folder:
    p = Path(folder)
    (p / 'bridge.h').write_text(bridge)
    (p / 'main.swift').write_text(program)
    compiled = subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-I', str(root / 'Horos/Sources'), '-c',
                               str(root / 'Horos/Sources/HorosObjCException.m'), '-o', str(p / 'exception.o')]).returncode == 0
    compiled = compiled and subprocess.run(['xcrun', 'swiftc', '-import-objc-header', str(p / 'bridge.h'),
                                            '-Xcc', '-I', '-Xcc', str(root / 'Horos/Sources'), str(p / 'main.swift'), str(root / 'Horos/Sources/ReportTemplateMenu.swift'),
                                            str(p / 'exception.o'), '-o', str(p / 'test')]).returncode == 0
    if not compiled:
        failures.append('the production Word methods did not compile')
    elif subprocess.run([str(p / 'test'), str(p)]).returncode:
        failures.append('a Word report does not keep the format of its template')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the Word report format follows the template')
