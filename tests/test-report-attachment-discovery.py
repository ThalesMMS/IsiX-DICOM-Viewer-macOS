#!/usr/bin/env python3
from pathlib import Path
import subprocess
import sys
import tempfile
root=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(root/'tests'))
from sources import source_text
# -checkForExistingReportForStudy: is in the Swift extension of DicomDatabase
# since #833: the method and the helpers it calls are compiled with swiftc,
# against the same stand-ins, with the same checks.
source=source_text('DicomDatabase+Other')
start=source.index('@objc(checkForExistingReportForStudy:)')
method=source[start:source.index('\n    @objc(allowAutoroutingWithPostNotifications:rereadExistingItems:)',start)]
helpers=source_text('DicomDatabase+Instance')
start=helpers.index('enum DicomDatabaseObjC {')
helpers=helpers[start:helpers.index('\n}\n',start)+3]
program=r'''
import Foundation
import CoreData
// Stand-ins for what the helpers reach: an exception ends the test, as
// N2LogExceptionWithStackTrace did.
enum HorosObjCException { static func perform(_ block: () -> Void) throws { block() } }
let HorosObjCExceptionKey = "HorosObjCException"
func _N2LogExceptionImpl(_ e: NSException, _ stack: Bool, _ function: UnsafePointer<CChar>) { abort() }
func DicomDatabaseLogStackTrace(_ message: String) { abort() }
func DicomDatabaseLogError(_ function: UnsafePointer<CChar>, _ file: UnsafePointer<CChar>, _ line: Int32, _ message: String) { abort() }
final class N2Debug { static func isActive() -> Bool { return false } }
typealias N2DirectoryEnumerator = NSEnumerator
extension FileManager { func enumerator(atPath path: String, filesOnly: Bool, recursive: Bool) -> NSEnumerator { return NSArray().objectEnumerator() } }
HELPERS
final class Reports {
    class func getUniqueFilename(_ study: Any!) -> String! { return "legacy" }
    class func getOldUniqueFilename(_ study: NSManagedObject!) -> String! { return "older" }
}
final class Database: NSObject {
    var reportsDir: String = ""
    func reportsDirPath() -> String! { return reportsDir }
}
extension Database {
METHOD
}
func check(_ value: Bool, _ what: String) { if !value { print("failed: \(what)"); exit(1) } }
let attribute = NSAttributeDescription()
attribute.name = "reportURL"
attribute.attributeType = .stringAttributeType
attribute.isOptional = true
let entity = NSEntityDescription()
entity.name = "Study"
entity.properties = [attribute]
let db = Database()
db.reportsDir = CommandLine.arguments[1]
let legacy = (db.reportsDir as NSString).appendingPathComponent("legacy.rtf")
let attached = (db.reportsDir as NSString).appendingPathComponent("Attached-QA.rtf")
check((try? "legacy template".write(toFile: legacy, atomically: true, encoding: .utf8)) != nil, "legacy written")
check((try? "imported report".write(toFile: attached, atomically: true, encoding: .utf8)) != nil, "attached written")
let study = NSManagedObject(entity: entity, insertInto: nil)
func reportURL() -> String? { return study.value(forKey: "reportURL") as? String }
study.setValue(attached, forKey: "reportURL"); db.checkForExistingReport(forStudy: study); check(reportURL() == attached, "attached kept")
study.setValue("https://example.invalid/report", forKey: "reportURL"); db.checkForExistingReport(forStudy: study); check(reportURL()?.hasPrefix("https://") ?? false, "remote kept")
study.setValue("/missing/report", forKey: "reportURL"); db.checkForExistingReport(forStudy: study); check(reportURL() == legacy, "missing replaced by legacy")
study.setValue(nil, forKey: "reportURL"); db.checkForExistingReport(forStudy: study); check(reportURL() == legacy, "nil replaced by legacy")
NSLog("PASS: database report discovery preserves explicit local/remote association and still recovers missing legacy reports")
'''.replace('HELPERS',helpers).replace('METHOD',method)
with tempfile.TemporaryDirectory(prefix='horos-report-discovery-') as directory:
 p=Path(directory);(p/'test.swift').write_text(program)
 subprocess.run(['xcrun','swiftc','-sanitize=address','-framework','Foundation','-framework','CoreData',str(p/'test.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(p)],check=True)
