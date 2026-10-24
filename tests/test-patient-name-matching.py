#!/usr/bin/env python3
"""A patient is found by name whatever the case and the diacritics typed.

Locally, a diacritic-insensitive comparison does not fold letters without a
decomposition (Ł, Ø, Đ, ı), so "zolw" never found "Żółw": the name predicate
now also matches a pattern in which l, o, d and i stand for them too. Remotely,
a PACS compares the name as it is sent, and many keep names in capitals without
diacritics: a search that found nothing is asked again in capitals, then in
capitals without diacritics, in the forms the query's character set can carry.

HorosPatientNameMatching is compiled from the source and run, its pattern
against a real SQLite Core Data store; the wiring is checked in the sources.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
failures = []
helper = root / 'Horos/Sources/PatientNameMatching.swift'
browser = (root / 'Horos/Sources/BrowserController+Plugins.swift').read_text()
query = (root / 'Horos/Sources/QueryController.mm').read_bytes().decode('latin1')
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()

DRIVER = r'''
import CoreData
func emit(_ key: String, _ value: String) { print("\(key)\t\(value)") }
let M = PatientNameMatching.self
emit("pattern-first", M.undecomposedPattern(component: "zolw", anchored: true) ?? "nil")
emit("pattern-later", M.undecomposedPattern(component: "Jan", anchored: false) ?? "nil")
emit("pattern-typed", M.undecomposedPattern(component: "Łuk", anchored: true) ?? "nil")
emit("pattern-none", M.undecomposedPattern(component: "smh", anchored: true) ?? "nil")
emit("pattern-escaped", M.undecomposedPattern(component: "o.", anchored: true) ?? "nil")
emit("folded", M.folded("Żółw Łukasz Øster"))
let utf8 = String.Encoding.utf8.rawValue, latin1 = String.Encoding.isoLatin1.rawValue
emit("alt-lower", M.alternativeRemoteTerms(for: "żółw", encoding: utf8).joined(separator: ","))
emit("alt-capital", M.alternativeRemoteTerms(for: "Żółw", encoding: utf8).joined(separator: ","))
emit("alt-latin1", M.alternativeRemoteTerms(for: "Żółw", encoding: latin1).joined(separator: ","))
emit("alt-plain", M.alternativeRemoteTerms(for: "zolw", encoding: latin1).joined(separator: ","))
emit("alt-same", M.alternativeRemoteTerms(for: "ZOLW", encoding: utf8).joined(separator: ","))

// The predicate the database search builds for a first name component.
let model = NSManagedObjectModel()
let entity = NSEntityDescription(); entity.name = "Study"; entity.managedObjectClassName = "NSManagedObject"
let attribute = NSAttributeDescription(); attribute.name = "name"; attribute.attributeType = .stringAttributeType; attribute.isOptional = true
entity.properties = [attribute]; model.entities = [entity]
let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
_ = try! coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                        at: URL(fileURLWithPath: CommandLine.arguments[1]), options: nil)
let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
context.persistentStoreCoordinator = coordinator
for name in ["Żółw Jan", "ZOLW ADAM", "Łukasz Nowak", "Smith John", "Zielinski Ola"] {
    NSManagedObject(entity: entity, insertInto: context).setValue(name, forKey: "name")
}
try! context.save(); context.reset()
for typed in ["zolw", "Zolw", "żółw", "Żółw", "ŻÓŁW", "lukasz", "smith"] {
    var predicate = NSPredicate(format: "name BEGINSWITH[cd] %@", typed)
    if let pattern = M.undecomposedPattern(component: typed, anchored: true) {
        predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [predicate, NSPredicate(format: "name MATCHES[cd] %@", pattern)])
    }
    let request = NSFetchRequest<NSManagedObject>(entityName: "Study"); request.predicate = predicate
    let found = (try! context.fetch(request)).compactMap { $0.value(forKey: "name") as? String }.sorted()
    emit("db-" + typed, found.joined(separator: ","))
}
'''

results = {}
with tempfile.TemporaryDirectory(prefix='horos-name-matching-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(DRIVER)
    built = subprocess.run(['xcrun', 'swiftc', '-o', str(work / 'check'), str(helper), str(work / 'main.swift')],
                           capture_output=True, text=True)
    if built.returncode:
        failures.append('the name matching does not compile:\n' + built.stderr[-1500:])
    else:
        run = subprocess.run([str(work / 'check'), str(work / 'names.sqlite')], capture_output=True, text=True, timeout=120)
        if run.returncode:
            failures.append('the driver failed: ' + run.stderr[-800:])
        for line in run.stdout.splitlines():
            key, _, value = line.partition('\t')
            results[key] = value

expected = {
    'pattern-first': 'z[oø][lł]w.*',
    # "Jan" has no l, o, d or i: the plain comparison is enough.
    'pattern-later': 'nil',
    'pattern-typed': '[lł]uk.*',
    'pattern-none': 'nil',
    'pattern-escaped': '[oø]\\..*',
    'folded': 'Zolw Lukasz Oster',
    'alt-lower': 'ŻÓŁW,ZOLW',
    'alt-capital': 'ŻÓŁW,ZOLW',
    # ISO_IR 100 cannot carry Ż or Ł: only the form without diacritics is sent.
    'alt-latin1': 'ZOLW',
    'alt-plain': 'ZOLW',
    'alt-same': '',
    'db-zolw': 'ZOLW ADAM,Żółw Jan',
    'db-Zolw': 'ZOLW ADAM,Żółw Jan',
    'db-żółw': 'ZOLW ADAM,Żółw Jan',
    'db-Żółw': 'ZOLW ADAM,Żółw Jan',
    'db-ŻÓŁW': 'ZOLW ADAM,Żółw Jan',
    'db-lukasz': 'Łukasz Nowak',
    'db-smith': 'Smith John',
}
if results:
    for key, want in expected.items():
        if results.get(key) != want:
            failures.append('%s: %r, expected %r' % (key, results.get(key), want))
# --- the wiring --------------------------------------------------------------
names = browser[browser.index('func patientsnamePredicate(_ s: String!, soundex: Bool)'):]
names = names[:names.index('return NSCompoundPredicate(andPredicateWithSubpredicates')]
if 'PatientNameMatching.undecomposedPattern(component:' not in names or 'name MATCHES[cd] %@' not in names:
    failures.append('the database name search does not also match the undecomposed letters')
if '!component.contains("*")' not in names:
    failures.append('a wildcard component would be turned into a pattern too')
at = query.index('[self performQuery: [NSNumber numberWithBool: showError]];')
retry = query[at:at + 1200]
if 'for( NSString *alternative in nameAlternatives)' not in retry or '[[queryManager queries] count]' not in retry \
        or 'forDescription:PatientName' not in retry:
    failures.append('a remote search that found nothing is not asked again with the other forms of the name')
if 'alternativeRemoteTermsFor:filterValue encoding:' not in query:
    failures.append('the other forms of the name are not worked out for the query character set')
if project.count('PatientNameMatching.swift in Sources') != 2:
    failures.append('PatientNameMatching.swift is not built into the application')

if failures:
    print('FAIL')
    for failure in failures:
        print(' -', failure)
    sys.exit(1)
print('PASS: names are found whatever the case and diacritics, in the database and on a PACS that keeps capitals')
