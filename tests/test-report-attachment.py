#!/usr/bin/env python3
"""Run production attachment transaction against Core Data and real files."""
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET
root=Path(__file__).resolve().parent.parent
# The attachment is Swift (BrowserController+ReportImport.swift); it runs here
# against a stand-in database with the real context helper, exception bridge
# and file replacement.
source=(root/'Horos/Sources/BrowserController+ReportImport.swift').read_text()
start=source.index('    @objc(importReport:UID:error:)')
method=source[start:source.index('\n    /// The study selected alone in the list',start)]
support=(root/'Horos/Sources/BrowserController+DatabaseSupport.swift').read_text()
attempt_start=support.index('    /// Runs `body` as an @try block')
attempt=support[attempt_start:support.index('\n    /// `@synchronized',attempt_start)]
context_source=(root/'Nitrogen/Sources/N2ManagedDatabase+CAPI.m').read_text()
queue_helper=context_source[context_source.index('void N2ManagedObjectContextPerformAndWait'):context_source.index('@implementation N2ManagedObjectContext (CAPI)')]
bridge=r"""
#import <CoreData/CoreData.h>
#import "HorosObjCException.h"
#import "HorosReportFileReplacement.h"
void N2ManagedObjectContextPerformAndWait(NSManagedObjectContext *context, void (NS_NOESCAPE ^block)(void));
"""
helpers='#import <CoreData/CoreData.h>\n#define NDEBUG 1\n'+queue_helper
program=r"""
import CoreData
enum BrowserObjC {
ATTEMPT
}
final class TestContext: NSManagedObjectContext, @unchecked Sendable {
 var failSave=false
 override func save() throws { if failSave { throw NSError(domain:"Test",code:1) }; try super.save() }
}
final class Database: NSObject {
 var local=true
 func isLocal() -> Bool { local }
 var isReadOnly=false
 var managedObjectContext: TestContext?
 var managedObjectModel: NSManagedObjectModel?
 var reportsDir=""
 func reportsDirPath() -> String? { reportsDir }
}
final class Browser: NSObject {
 var database: Database?
METHOD
}
func check(_ ok: Bool, _ line: Int = #line) { if !ok { print("FAIL: check at line \(line)"); exit(1) } }
func fails(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
let dir=CommandLine.arguments[1]
let model=NSManagedObjectModel()
let entity=NSEntityDescription();entity.name="Study";entity.managedObjectClassName="NSManagedObject"
entity.properties=["studyInstanceUID","reportURL","lockedStudy"].map { name in
 let a=NSAttributeDescription();a.name=name;a.attributeType=name=="lockedStudy" ? .booleanAttributeType : .stringAttributeType;a.isOptional=true;return a }
model.entities=[entity]
let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
check((try? coordinator.addPersistentStore(ofType:NSInMemoryStoreType,configurationName:nil,at:nil,options:nil)) != nil)
let context=TestContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
let db=Database();db.managedObjectContext=context;db.managedObjectModel=model
db.reportsDir=(dir as NSString).appendingPathComponent("reports")
check((try? FileManager.default.createDirectory(atPath:db.reportsDir,withIntermediateDirectories:true)) != nil)
let browser=Browser();browser.database=db
func add(_ uid: String) -> NSManagedObject {
 let study=NSEntityDescription.insertNewObject(forEntityName:"Study",into:context);study.setValue(uid,forKey:"studyInstanceUID");return study }
let source=(dir as NSString).appendingPathComponent("external.rtf")
let bytes=Data("{\\rtf1 Synthetic attached report, no template text.}".utf8);check(FileManager.default.createFile(atPath:source,contents:bytes))
let study=add("1.2.3"), other=add("1.2.4")
let old=(db.reportsDir as NSString).appendingPathComponent("old.rtf")
let oldBytes=Data("old document".utf8);check(FileManager.default.createFile(atPath:old,contents:oldBytes));study.setValue(old,forKey:"reportURL")
check((try? context.save()) != nil)
func contents(_ path: String) -> Data? { FileManager.default.contents(atPath:path) }
check(fails { try browser.attachReport(atPath:"/missing/source",toStudyWithUID:"1.2.3") })
check(study.value(forKey:"reportURL") as? String==old);check(contents(old)==oldBytes)
context.failSave=true
check(fails { try browser.attachReport(atPath:source,toStudyWithUID:"1.2.3") })
check(study.value(forKey:"reportURL") as? String==old);check((try? FileManager.default.contentsOfDirectory(atPath:db.reportsDir))?.count==1)
context.failSave=false
check(!fails { try browser.attachReport(atPath:source,toStudyWithUID:"1.2.3") })
let attached=study.value(forKey:"reportURL") as! String;check(attached != source)
check(contents(attached)==bytes);check(contents(source)==bytes);check(contents(old)==oldBytes);check(other.value(forKey:"reportURL")==nil)
// Importing an already-owned file must not delete it or copy onto itself.
check(!fails { try browser.attachReport(atPath:attached,toStudyWithUID:"1.2.3") });check(contents(attached)==bytes)
let latest=study.value(forKey:"reportURL") as? String
db.isReadOnly=true;check(fails { try browser.attachReport(atPath:source,toStudyWithUID:"1.2.3") });db.isReadOnly=false
db.local=false;check(fails { try browser.attachReport(atPath:source,toStudyWithUID:"1.2.3") });db.local=true
study.setValue(true,forKey:"lockedStudy");check(fails { try browser.attachReport(atPath:source,toStudyWithUID:"1.2.3") });study.setValue(false,forKey:"lockedStudy")
check(fails { try browser.attachReport(atPath:source,toStudyWithUID:"missing") })
_ = add("1.2.3");check(fails { try browser.attachReport(atPath:source,toStudyWithUID:"1.2.3") });check(study.value(forKey:"reportURL") as? String==latest)
print("PASS: byte-preserving report attachment; correct study; copy/save failure rollback; old/source files retained; self-import; ambiguous/missing/locked/remote/read-only rejection")
""".replace('METHOD',method).replace('ATTEMPT',attempt)
with tempfile.TemporaryDirectory(prefix='horos-report-attach-') as directory:
 p=Path(directory)
 (p/'Bridge.h').write_text(bridge);(p/'helpers.m').write_text(helpers);(p/'main.swift').write_text(program)
 objects=[]
 for name,path,arc in (('helpers.m',p/'helpers.m',False),('HorosObjCException.m',root/'Horos/Sources/HorosObjCException.m',True)):
  out=p/(name+'.o')
  subprocess.run(['xcrun','clang','-c','-fblocks','-w','-fobjc-arc' if arc else '-fno-objc-arc','-I',str(root/'Horos/Sources'),str(path),'-o',str(out)],check=True)
  objects.append(str(out))
 subprocess.run(['xcrun','swiftc','-import-objc-header',str(p/'Bridge.h'),'-I',str(root/'Horos/Sources'),str(p/'main.swift')]+objects
                +['-framework','CoreData','-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(p),'-com.apple.CoreData.ConcurrencyDebug','1'],check=True)
menus=list((root/'Horos/Resources').glob('*.lproj/MainMenu.xib'))
for menu in menus:
 tree=ET.parse(menu)
 report=tree.find('.//menu[@id="12354"]')
 if report is not None:
  actions=report.findall('.//action[@selector="attachExistingReport:"]')
  assert len(actions)==1 and actions[0].attrib['target']=='898',menu
print('PASS: report menus expose one attachment action in every localized main menu')
