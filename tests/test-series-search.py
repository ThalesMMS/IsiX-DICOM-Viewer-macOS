#!/usr/bin/env python3
"""Exercise the production study predicate against a temporary SQLite Core Data store.

-createFilterPredicate is Swift, in BrowserController+Plugins.swift.
The method is compiled as it is, with xcrun swiftc, inside a double of the
browser that holds the search string and type, and run over a store of studies
and series built in the driver.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import subprocess,sys,tempfile
sys.path.insert(0,str(Path(__file__).resolve().parent))
from sources import source_text  # noqa: E402
s=source_text('BrowserController+Plugins')
a=s.index('    @objc(createFilterPredicate)');method=s[a:s.index('    @objc(databaseSelection)',a)]
code=r'''
import CoreData
func check(_ c: Bool, _ what: String, line: Int = #line) { precondition(c, "failed: \(what) (line \(line))") }
final class BrowserFixture: NSObject {
 var horos_searchString: String?
 var horos_searchType = 0
 func patientsnamePredicate(_ s: String!) -> NSPredicate! { return NSPredicate(value: true) }
METHOD
}
func attribute(_ name: String) -> NSAttributeDescription { let a=NSAttributeDescription();a.name=name;a.attributeType = .stringAttributeType;a.isOptional=true;return a }
let study=NSEntityDescription();study.name="Study";study.managedObjectClassName="NSManagedObject"
let series=NSEntityDescription();series.name="Series";series.managedObjectClassName="NSManagedObject"
let children=NSRelationshipDescription();children.name="series";children.destinationEntity=series;children.minCount=0;children.maxCount=0;children.isOptional=true
let parent=NSRelationshipDescription();parent.name="study";parent.destinationEntity=study;parent.maxCount=1;parent.isOptional=true;children.inverseRelationship=parent;parent.inverseRelationship=children
study.properties=[attribute("uid"),children];series.properties=[attribute("uid"),attribute("name"),parent]
let model=NSManagedObjectModel();model.entities=[study,series]
let psc=NSPersistentStoreCoordinator(managedObjectModel:model)
check((try? psc.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:URL(fileURLWithPath:CommandLine.arguments[1]),options:nil)) != nil, "store")
let ctx=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);ctx.persistentStoreCoordinator=psc
var original:[NSManagedObject]=[]
for i in 0..<2 {
 let st=NSEntityDescription.insertNewObject(forEntityName:"Study",into:ctx);st.setValue(i==1 ? "other" : "target",forKey:"uid")
 for name in (i==1 ? ["Unrelated"] : ["Localízador","T2 Axial","T1 Sagital"]) {
  let se=NSEntityDescription.insertNewObject(forEntityName:"Series",into:ctx);se.setValue(name,forKey:"name");se.setValue(name,forKey:"uid");se.setValue(st,forKey:"study");original.append(se)
 }
}
check((try? ctx.save()) != nil, "save");let ids=original.map{$0.objectID}
let browser=BrowserFixture();browser.horos_searchType=11
for term in ["LOCALIZADOR","localíz","t2 axial","Sagital","absent","","' OR 1=1"] {
 browser.horos_searchString=term;let request=NSFetchRequest<NSManagedObject>(entityName:"Study");request.predicate=browser.createFilterPredicate()
 let result=try! ctx.fetch(request)
 let expected=term.isEmpty ? 2 : (term=="absent"||term=="' OR 1=1" ? 0 : 1);check(result.count==expected, "\(result.count) studies for \(term), \(expected) expected")
 if expected==1 {check(result[0].value(forKey:"uid") as? String=="target", "the target study");check((result[0].value(forKey:"series") as? NSSet)?.count==3, "all its series")}
 check(!ctx.hasChanges, "no changes");check(original.map{$0.objectID}==ids, "stable identities")
}
print("PASS: case/diacritics, empty/missing/literal terms, complete study context, stable series identities and no mutations")
'''.replace('METHOD',method)
with tempfile.TemporaryDirectory(prefix='horos-series-search-') as tmp:
 p=Path(tmp);(p/'main.swift').write_text(code)
 subprocess.run(['xcrun','swiftc',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(p/'test.sql')],check=True)
