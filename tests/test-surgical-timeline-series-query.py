#!/usr/bin/env python3
"""The surgical timeline finds the same series by one fetch as by walking every study.

Every refresh of the database list asks for the surgical procedure timeline.
It used to fetch every study and compare the description of each of their
series with the surgical series description, code unit by code unit; it now
fetches the series with IsiXDatabase's SurgicalTimelineQuery predicate. This
builds a SQLite store of the app's data model (compiled with momc) with
descriptions that differ only by case, accents, spacing or a prefix, and
compares both ways, saved and then with unsaved changes in the context: a
matching series deleted, one added to a study, one without a study, and one
renamed to match. The browser must use the query.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
MODEL = root / 'Horos/Models/OsiriXDB_DataModel.xcdatamodeld'
RULES = root / 'Modules/IsiXDatabase/Sources/DatabaseMaintenanceRules.swift'
failures = []

DRIVER = r'''
import CoreData
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let wanted = "Horos Surgical Procedure SR"
let model = NSManagedObjectModel(contentsOf: folder.appendingPathComponent("OsiriXDB_DataModel.momd"))!.copy() as! NSManagedObjectModel
for entity in model.entities { entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self) }
let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
try! coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                    at: folder.appendingPathComponent("Database.sql"), options: nil)
let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
context.persistentStoreCoordinator = coordinator

func study(_ uid: String) -> NSManagedObject {
    let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
    study.setValue(uid, forKey: "studyInstanceUID")
    study.setValue(false, forKey: "expanded")
    return study
}
func series(_ description: String?, in study: NSManagedObject?) -> NSManagedObject {
    let series = NSEntityDescription.insertNewObject(forEntityName: "Series", into: context)
    series.setValue(description, forKey: "seriesDescription")
    series.setValue(study, forKey: "study")
    return series
}

// The former walk: every study, its series as DicomStudy's getter gives them
// (deleted ones left out while the context has deletions), the description
// compared with -isEqualToString:.
func walked() -> Set<NSManagedObjectID> {
    let studies = try! context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Study"))
    var found = Set<NSManagedObjectID>()
    for study in studies {
        var all = (study.value(forKey: "series") as? Set<NSManagedObject>) ?? []
        if !context.deletedObjects.isEmpty { all = all.filter { !$0.isDeleted } }
        for one in all where (one.value(forKey: "seriesDescription") as? NSString)?.isEqual(to: wanted) == true {
            found.insert(one.objectID)
        }
    }
    return found
}
func queried() -> Set<NSManagedObjectID> {
    let request = NSFetchRequest<NSManagedObject>(entityName: "Series")
    request.predicate = SurgicalTimelineQuery.seriesPredicate(description: wanted)
    return Set(try! context.fetch(request).map { $0.objectID })
}

var report: [String] = []
func compare(_ stage: String, expected: Int) {
    let a = walked(), b = queried()
    report.append("\(stage): walked \(a.count), queried \(b.count)")
    if a != b || a.count != expected { print("FAIL: \(stage): walked \(a.count), queried \(b.count), expected \(expected)"); exit(1) }
}

let first = study("1.1"), second = study("1.2"), third = study("1.3")
let kept = series(wanted, in: first)
_ = series(wanted, in: second)
let renamed = series("Horos Surgical Procedure", in: second)
for variant in ["horos surgical procedure sr", "Horos Surgical Procedure SR ", " Horos Surgical Procedure SR",
                "Horos Surgical Procédure SR", "Horos Surgical Procedure SR.", "CT", "Horos Surgical Procedure"] {
    _ = series(variant, in: third)
}
_ = series(nil, in: third)
_ = series(wanted, in: third)
try! context.save()
context.reset()
compare("saved", expected: 3)

let firstAgain = try! context.existingObject(with: first.objectID)
let keptAgain = try! context.existingObject(with: kept.objectID)
context.delete(keptAgain)
_ = series(wanted, in: firstAgain)
_ = series(wanted, in: nil)
(try! context.existingObject(with: renamed.objectID)).setValue(wanted, forKey: "seriesDescription")
compare("unsaved changes", expected: 4)
print("ok: " + report.joined(separator: "; "))
'''

with tempfile.TemporaryDirectory(prefix='horos-surgical-timeline-') as directory:
    directory = Path(directory)
    compiled = subprocess.run(['xcrun', 'momc', str(MODEL), str(directory)], capture_output=True, text=True)
    if compiled.returncode != 0:
        failures.append('the data model does not compile with momc:\n' + compiled.stderr[-1500:])
    else:
        (directory / 'main.swift').write_text(DRIVER)
        binary = directory / 'check'
        built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-o', str(binary), str(RULES), str(directory / 'main.swift')],
                               capture_output=True, text=True)
        if built.returncode != 0:
            failures.append('the driver does not compile:\n' + built.stderr[-2500:])
        else:
            run = subprocess.run([str(binary), str(directory)], capture_output=True, text=True, timeout=120)
            print(run.stdout.strip())
            if run.returncode != 0 or not run.stdout.startswith('ok'):
                failures.append((run.stdout + run.stderr).strip()[-1500:])

browser = (root / 'Horos/Sources/BrowserController+DatabaseMaintenance.swift').read_text()
timeline = browser[browser.index('func surgicalProcedureTimelineEvents()'):]
timeline = timeline[:timeline.index('\n    }\n')]
if 'SurgicalTimelineQuery.seriesPredicate(' not in timeline or 'seriesEntity()' not in timeline:
    failures.append('the timeline does not fetch the surgical series with the query')
if 'studyEntity()' in timeline:
    failures.append('the timeline still fetches every study')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('the surgical timeline query finds the series the walk of every study found')
