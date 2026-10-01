#!/usr/bin/env python3
"""A C-FIND PatientName of `*` matches every study, as an empty one does (#1014).

The listener's STUDY level builds its PatientName condition with the browser's
-patientsnamePredicate:soundex:. That method stripped the `*` around each name
component and then asked for `name CONTAINS[cd] ""`, which never matches in the
SQLite store: `*`, which PS3.4 C.2.2.2.3 makes universal matching, returned no
study, and so did `SMITH^*`. A `*` or `?` inside a component was compared
literally.

The method is compiled as it is, with xcrun swiftc, and its predicates fetched
from a temporary SQLite Core Data store, next to the SCP's own conjunction with
`hasDICOM`. The control fetch `name CONTAINS[cd] ""` must still find nothing in
that store: it is what the old method produced for `*`. The SCP side is read
from OsiriXSCPDataHandler.mm: a predicate with no condition is dropped, and the
`hasDICOM` condition no longer vanishes when it is the only one.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs (#803)
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text  # noqa: E402

failures = []
plugins = source_text('BrowserController+Plugins')
start = plugins.index('    @objc(patientsnamePredicate:soundex:)')
method = plugins[start:plugins.index('    @objc(federatedSourceCatalog)', start)]
if 'nonisolated func patientsnamePredicate' not in method:
    failures.append('patientsnamePredicate:soundex: is not nonisolated: the listener calls it off the main thread')

code = r'''
import CoreData
func check(_ c: Bool, _ what: String, line: Int = #line) { if !c { print("FAIL: \(what) (line \(line))"); exit(1) } }
func objcTry(_ body: () -> Void) -> NSException? { body(); return nil }
func objcPredicate(_ format: String, _ arguments: Any?...) -> NSPredicate {
    NSPredicate(format: format, argumentArray: arguments.map { $0 ?? NSNull() })
}
func _N2LogExceptionImpl(_ e: NSException, _ b: Bool, _ s: String) {}
enum DicomStudy { static func soundex(_ s: String) -> String { String(s.uppercased().prefix(1)) + "000" } }
@MainActor final class BrowserFixture: NSObject {
METHOD
}
func attribute(_ name: String, _ type: NSAttributeType = .stringAttributeType) -> NSAttributeDescription {
    let a = NSAttributeDescription(); a.name = name; a.attributeType = type; a.isOptional = true; return a
}
let study = NSEntityDescription(); study.name = "Study"; study.managedObjectClassName = "NSManagedObject"
study.properties = [attribute("name"), attribute("soundex"), attribute("hasDICOM", .booleanAttributeType)]
let model = NSManagedObjectModel(); model.entities = [study]
let psc = NSPersistentStoreCoordinator(managedObjectModel: model)
check((try? psc.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                   at: URL(fileURLWithPath: CommandLine.arguments[1]), options: nil)) != nil, "store")
let ctx = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType); ctx.persistentStoreCoordinator = psc
let names = ["QA^Isolation01", "QA^Isolation02", "QA^Isolation03", "SMITH^JOHN", "O'BRIEN^ANNA", "NOT^DICOM"]
ctx.performAndWait {
    for n in names {
        let s = NSEntityDescription.insertNewObject(forEntityName: "Study", into: ctx)
        s.setValue(n, forKey: "name"); s.setValue(n != "NOT^DICOM", forKey: "hasDICOM")
    }
    check((try? ctx.save()) != nil, "save")
}
func fetch(_ p: NSPredicate) -> [String] {
    var result: [String] = []
    ctx.performAndWait {
        let r = NSFetchRequest<NSManagedObject>(entityName: "Study"); r.predicate = p
        result = ((try? ctx.fetch(r)) ?? []).compactMap { $0.value(forKey: "name") as? String }.sorted()
    }
    return result
}
let browser = MainActor.assumeIsolated { BrowserFixture() }
let dicom = NSPredicate(format: "hasDICOM == %d", true)
let all = names.filter { $0 != "NOT^DICOM" }.sorted()
// Control: what the old method asked for "*" finds nothing in this store.
check(fetch(NSPredicate(format: "name CONTAINS[cd] %@", "")).isEmpty, "control: CONTAINS \"\" matches nothing")
let cases: [(String, [String])] = [
    ("", all), ("*", all), ("**", all), ("* *", all), ("^", all),
    ("SMITH^*", ["SMITH^JOHN"]), ("smith", ["SMITH^JOHN"]), ("*JOHN", ["SMITH^JOHN"]),
    ("QA^Isolation02", ["QA^Isolation02"]), ("QA*02", ["QA^Isolation02"]),
    ("QA^Isolation0?", ["QA^Isolation01", "QA^Isolation02", "QA^Isolation03"]),
    ("*solation*", ["QA^Isolation01", "QA^Isolation02", "QA^Isolation03"]),
    ("O'BRIEN", ["O'BRIEN^ANNA"]),
    // Negative controls: a real value must still narrow the set.
    ("Nobody", []), ("Nobody*", []), ("*Nobody*", []), ("QA^Isolation04", []), ("?MITHX", []), ("JOHN^SMITH", []),
]
for (value, expected) in cases {
    // Through the main actor, so the pre-#1014 method, isolated to it, compiles in this driver too.
    let p = MainActor.assumeIsolated { browser.patientsnamePredicate(value, soundex: false)! }
    let got = fetch(NSCompoundPredicate(andPredicateWithSubpredicates: [p, dicom]))
    check(got == expected, "PatientName '\(value)': \(got), expected \(expected)")
    if value.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: CharacterSet(charactersIn: " ^")).isEmpty {
        check((p as? NSCompoundPredicate)?.subpredicates.isEmpty == true, "'\(value)' carries no condition")
    }
}
// The SCP's conjunction when PatientName is its only key: hasDICOM alone.
check(fetch(dicom) == all, "hasDICOM alone")
print("PASS: universal '', '*', wildcard components, case, negative controls, hasDICOM conjunction")
'''.replace('METHOD', method)

with tempfile.TemporaryDirectory(prefix='horos-cfind-pn-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(code)
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(p / 'main.swift'), '-o', str(p / 'test')],
                           capture_output=True, text=True)
    if built.returncode:
        failures.append('swiftc failed:\n' + built.stderr[-3000:])
    else:
        run = subprocess.run([str(p / 'test'), str(p / 'test.sql')], capture_output=True, text=True)
        print(run.stdout.strip())
        if run.returncode:
            failures.append('driver failed: ' + (run.stdout + run.stderr)[-2000:])

scp = source_text('OsiriXSCPDataHandler')
body = scp[scp.index('- (NSPredicate *)predicateForDataset:'):scp.index('- (const char*) encodeString:')]
name = body[body.index('if (key == DCM_PatientsName)'):body.index('else if (key == DCM_PatientID)')]
if not re.search(r'patientsnamePredicate: patientNameString soundex: NO\];.*?subpredicates\] count\] == 0\)\s*predicate = nil;',
                 name, re.S):
    failures.append('the STUDY level keeps a PatientName predicate with no condition')
dicom = body[body.index('predicate = [NSPredicate predicateWithFormat:@"hasDICOM == %d", YES];'):]
dicom = dicom[:dicom.index('NSTimeInterval startDate')]
if not re.search(r'if \(predicate && compoundPredicate\)\s*compoundPredicate = \[NSCompoundPredicate andPredicateWithSubpredicates:'
                 r'.*?else if \(predicate\)\s*compoundPredicate = predicate;', dicom, re.S):
    failures.append('hasDICOM is still dropped when compoundPredicate is nil')

for failure in failures:
    print('FAIL:', failure)
sys.exit(1 if failures else 0)
