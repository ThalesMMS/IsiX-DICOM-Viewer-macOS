#!/usr/bin/env python3
"""Exercise the production Pages creation method with controlled app launching."""
from pathlib import Path
import subprocess
import tempfile
from sources import source_text
root = Path(__file__).resolve().parent.parent
# Reports is Swift: the method is compiled into a stand-in class with
# the file-level helpers it calls.
source = source_text('Reports')
start = source.index('    @objc(createNewPagesReportForStudy:toDestinationPath:)')
method = source[start:source.index('    @objc(pathForPagesTemplate:)', start)]
prelude = source[source.index('/// What `%@` prints'):source.index('/** \\brief reports */')]
bridge = r'''
#import <Foundation/Foundation.h>
#import "HorosReportFileReplacement.h"
#import "HorosReportFields.h"
'''
program = r'''
import Foundation
typealias NSManagedObject = NSMutableDictionary
var model: String? = nil, alert: String? = nil
var installed = false, launchSuccess = false, legacyArchive = false, fillSucceeds = false
var launches = 0, fills = 0, filledPaths: [String] = []
// Which kind of template this is, read out of the archive by the real one.
func HorosPagesArchiveHasIndexXML(_ data: Data?) -> Bool { legacyArchive }
enum HorosAlertPanel {
    static func runCritical(title: String?, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int {
        alert = message
        return 0
    }
}
enum DispatchQueue {
    static let main = Queue()
    struct Queue { func async(execute: () -> Void) { execute() } }
}
final class NSWorkspace {
    static let shared = NSWorkspace()
    func openDocument(atPath path: String, applicationURLs: [URL], completion: (Bool) -> Void) -> Bool {
        launches += 1
        precondition(applicationURLs.map(\.path) == ["/Applications/Pages.app"], "resolved app")
        completion(launchSuccess)
        return true
    }
}
// Where Pages is, asked for as the production code asks for it: one lookup that
// tries both bundle identifiers and then the Pages document type.
enum PagesApplication {
    static func url() -> URL? { installed ? URL(fileURLWithPath: "/Applications/Pages.app") : nil }
}
// The header and footer, filled in the file before Pages is handed it.
var headerFills: [String] = []
enum PagesHeaderFooterFill {
    @discardableResult
    static func fill(documentAt path: String, substitute: (String) -> String) -> Bool {
        headerFills.append(path)
        precondition(fills == headerFills.count - 1, "the header is filled in before Pages opens the copy")
        precondition(substitute("\u{ab}name\u{bb}") == "Synthetic", "a placeholder alone is substituted")
        return true
    }
}
// Pages filling in a template it alone can edit.
enum PagesDocumentFill {
    static func fill(documentAt path: String, substitute: (String) -> String) -> Bool {
        fills += 1
        filledPaths.append(path)
        // Pages is handed a document, by the name it opens it under.
        precondition(path.hasSuffix("/report.pages") && FileManager.default.fileExists(atPath: path), "a .pages copy")
        // The block is what fills a line in; exercise it so a broken one is caught.
        precondition(substitute("name: \u{ab}name\u{bb}") == "name: Synthetic", "substitute")
        return fillSucceeds
    }
}
PRELUDE
final class Reports: NSObject {
    let templateNameStorage = NSMutableString(string: "")
    class func pathForPagesTemplate(_ name: String!) -> String! { model }
    func decompressPagesFileIfNecessary(_ path: String!) -> Bool { true }
    func reportFieldValues(forStudy study: NSManagedObject!) -> NSDictionary! { ["name": "Synthetic"] }
    func firstSeriesImagePaths(_ study: NSManagedObject!) -> [Any]? { [] }
    func dicomValue(from paths: [Any]?) -> (String?) -> String? { { _ in "" } }
    func searchAndReplaceFields(fromStudy study: NSManagedObject!, in xml: NSMutableString!) {
        xml.replaceOccurrences(of: "PATIENT", with: "Synthetic", options: [], range: NSRange(location: 0, length: xml.length))
    }
METHOD
}
func check(_ value: Bool, _ what: String, line: Int = #line) { precondition(value, "failed: \(what) (line \(line))") }
func text(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
let dir = CommandLine.arguments[1]
let dest = (dir as NSString).appendingPathComponent("report.pages")
let old = Data("previous".utf8)
check((try? old.write(to: URL(fileURLWithPath: dest))) != nil, "previous report")
let study = NSMutableDictionary(dictionary: ["reportURL": "old association"])
let reports = Reports()
check(!reports.createNewPagesReport(forStudy: study, toDestinationPath: dest), "no Pages")
check(alert?.contains("not installed") == true && launches == 0, "not installed")
installed = true
check(!reports.createNewPagesReport(forStudy: study, toDestinationPath: dest), "no template")
check(alert?.contains("template could not be found") == true, "template not found")
model = (dir as NSString).appendingPathComponent("model.pages")
check((try? FileManager.default.createDirectory(atPath: model!, withIntermediateDirectories: true)) != nil, "model")
// A template with no index.xml is one Pages 5 or later wrote, and Pages fills
// it in. When it cannot, what was there is preserved and the reason is said.
check(!reports.createNewPagesReport(forStudy: study, toDestinationPath: dest), "fill fails")
check(fills == 1 && alert?.contains("allowed to control Pages") == true, "fill failure said")
check(FileManager.default.contents(atPath: dest) == old, "previous bytes")
check(study["reportURL"] as? String == "old association" && launches == 0, "association kept")
// And when Pages does fill it in, the report is published and opened.
fillSucceeds = true
check(reports.createNewPagesReport(forStudy: study, toDestinationPath: dest), "created report, launch submitted")
check(fills == 2 && launches == 1 && alert?.contains("could not open") == true, "launch failure said")
check(study["reportURL"] as? String == dest, "associated")
fillSucceeds = false
launches = 0
// A template that does carry index.xml is filled in here, and Pages is not
// asked to do anything until the report is opened.
let index = (model! as NSString).appendingPathComponent("index.xml")
check((try? "<text>PATIENT</text>".write(toFile: index, atomically: true, encoding: .utf8)) != nil, "index")
check(reports.createNewPagesReport(forStudy: study, toDestinationPath: dest), "created legacy report, launch submitted")
check(alert?.contains("could not open") == true && launches == 1 && fills == 2, "legacy not handed to Pages")
check(study["reportURL"] as? String == dest, "associated")
check(text((dest as NSString).appendingPathComponent("index.xml")) == "<text>Synthetic</text>", "filled here")
launchSuccess = true
check(reports.createNewPagesReport(forStudy: study, toDestinationPath: dest) && launches == 2 && fills == 2, "opened")
check(text(index) == "<text>PATIENT</text>", "template untouched")
// A template saved with "Save as Template" is a .template file. Pages opens one
// of those as a new untitled document, so the copy is handed to it as a .pages,
// and the report is a .pages with what Pages filled in.
legacyArchive = false; fillSucceeds = true; launchSuccess = true
let saved = (dir as NSString).appendingPathComponent("Saved.template")
let templateBytes = Data("modern template".utf8)
check((try? templateBytes.write(to: URL(fileURLWithPath: saved))) != nil, "saved template")
model = saved
let fromTemplate = (dir as NSString).appendingPathComponent("from-template.pages")
check(reports.createNewPagesReport(forStudy: study, toDestinationPath: fromTemplate), "created from a .template")
check(fills == 3 && filledPaths.last!.hasSuffix("/report.pages"), "filled as a .pages")
check(FileManager.default.contents(atPath: fromTemplate) == templateBytes, "published")
check(FileManager.default.contents(atPath: saved) == templateBytes, "template untouched")
check(study["reportURL"] as? String == fromTemplate, "associated")
// When Pages cannot fill it, nothing is published and the template stays.
fillSucceeds = false
let failed = (dir as NSString).appendingPathComponent("failed.pages")
check(!reports.createNewPagesReport(forStudy: study, toDestinationPath: failed), "fill fails")
check(!FileManager.default.fileExists(atPath: failed) && FileManager.default.contents(atPath: saved) == templateBytes, "nothing published")
check(headerFills == filledPaths, "every copy Pages fills had its header and footer filled first")
print("PASS: missing Pages and missing template preserve the existing report; a template Pages must fill is handed to Pages and its failure preserves what was there; a template with index.xml is filled in here and Pages is not asked to; a .template is filled as a .pages copy; the template is never modified")
'''.replace('METHOD', method).replace('PRELUDE', prelude)
with tempfile.TemporaryDirectory(prefix='horos-pages-create-') as directory:
    p=Path(directory)
    (p/'bridge.h').write_text(bridge)
    (p/'main.swift').write_text(program)
    subprocess.run(['xcrun','swiftc','-sanitize=address','-import-objc-header',str(p/'bridge.h'),
                    '-Xcc','-I','-Xcc',str(root/'Horos/Sources'),str(p/'main.swift'),'-o',str(p/'test')],check=True)
    subprocess.run([str(p/'test'),str(p)],check=True)
