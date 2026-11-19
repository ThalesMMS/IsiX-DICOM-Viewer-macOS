#!/usr/bin/env python3
"""A patient is found by name whatever the case and the diacritics typed.

Locally, a diacritic-insensitive comparison does not fold letters without a
decomposition (Ł, Ø, Đ, ı), so "zolw" never found "Żółw": the name predicate
now also matches a pattern in which l, o, d and i stand for them too. Remotely,
a PACS compares the name as it is sent, and many keep names in capitals without
diacritics: a search that found nothing is asked again in capitals, then in
capitals without diacritics, in the forms the query's character set can carry.

A name is also found whatever the order of its words, when the preferences
say so (PatientNameAnyWordOrder): in the database, the first word matches from
the start of any word of the name, so that «Jan Kowalski» finds KOWALSKI^JAN,
for the browser's search field and the patient-list album, while the
listener's C-FIND and the web portal keep the order; remotely, the Query
window asks the steps of PatientNameQueryForms (IsiXContracts), whose module
tests cover the forms, and merges the answers of a step.

HorosPatientNameMatching is compiled from the source and run, its pattern
against a real SQLite Core Data store; the wiring is checked in the sources.

    python3 tests/test-patient-name-matching.py [REVISION]

reads the sources of REVISION instead of the checkout's (HEAD before a change
shows what the change brings).
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def read(path):
    if revision:
        return subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], capture_output=True, check=True).stdout.decode('utf-8')
    return (root / path).read_text(encoding='utf-8')


helper_text = read('Horos/Sources/PatientNameMatching.swift')
browser = read('Horos/Sources/BrowserController+Plugins.swift')
query = read('Horos/Sources/QueryController+Query.swift')
network = read('Horos/Sources/QueryController+Network.swift')
distant = read('Horos/Sources/QueryControllerDistantStudies.swift')
project = read('Horos.xcodeproj/project.pbxproj')

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

// The database's name search, in order and in any order, against names stored
// as a DICOM file holds them (components separated by "^") and with a
// stand-in Soundex code of each word, after a space as DicomStudy writes it.
func code(_ word: String) -> String? { word.isEmpty ? nil : " " + String(word.uppercased().prefix(2)) }
let named = NSEntityDescription(); named.name = "Named"; named.managedObjectClassName = "NSManagedObject"
let nameAttribute = NSAttributeDescription(); nameAttribute.name = "name"; nameAttribute.attributeType = .stringAttributeType; nameAttribute.isOptional = true
let soundAttribute = NSAttributeDescription(); soundAttribute.name = "soundex"; soundAttribute.attributeType = .stringAttributeType; soundAttribute.isOptional = true
named.properties = [nameAttribute, soundAttribute]
let orderModel = NSManagedObjectModel(); orderModel.entities = [named]
let orderCoordinator = NSPersistentStoreCoordinator(managedObjectModel: orderModel)
_ = try! orderCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                             at: URL(fileURLWithPath: CommandLine.arguments[1] + "-order"), options: nil)
let orderContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
orderContext.persistentStoreCoordinator = orderCoordinator
for name in ["KOWALSKI^JAN", "NOWAK^JAN MARIA", "Żółw^Łukasz", "JANKOWSKI^PIOTR", "Smith John"] {
    let object = NSManagedObject(entity: named, insertInto: orderContext)
    object.setValue(name, forKey: "name")
    object.setValue(name.replacingOccurrences(of: "^", with: " ").split(separator: " ").compactMap { code(String($0)) }.joined(), forKey: "soundex")
}
try! orderContext.save(); orderContext.reset()
func fetch(_ predicate: NSPredicate) -> String {
    let request = NSFetchRequest<NSManagedObject>(entityName: "Named"); request.predicate = predicate
    return (try! orderContext.fetch(request)).compactMap { $0.value(forKey: "name") as? String }.sorted().joined(separator: ",")
}
for typed in ["Jan Kowalski", "Kowalski Jan", "kowalski, jan", "Jan^Kowalski", "Maria Nowak", "jan", "kowal*", "J?n Kowalski",
              "lukasz zolw", "John Smith", "*"] {
    emit("any-" + typed, fetch(M.namePredicate(typed, soundex: nil, anyOrder: true)))
    emit("kept-" + typed, fetch(M.namePredicate(typed, soundex: nil)))
}
// With Soundex, the code of the first word is found at the start of any word too.
emit("soundex-any", fetch(M.namePredicate("Jaan Kowalskee", soundex: code, anyOrder: true)))
emit("soundex-kept", fetch(M.namePredicate("Jaan Kowalskee", soundex: code)))
'''

results = {}
with tempfile.TemporaryDirectory(prefix='horos-name-matching-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(DRIVER)
    helper = work / 'PatientNameMatching.swift'
    helper.write_text(helper_text)
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
    # In any order: the first word from the start of any word of the name.
    'any-Jan Kowalski': 'KOWALSKI^JAN',
    'any-Kowalski Jan': 'KOWALSKI^JAN',
    'any-kowalski, jan': 'KOWALSKI^JAN',
    'any-Jan^Kowalski': 'KOWALSKI^JAN',
    'any-Maria Nowak': 'NOWAK^JAN MARIA',
    'any-jan': 'JANKOWSKI^PIOTR,KOWALSKI^JAN,NOWAK^JAN MARIA',
    'any-kowal*': 'KOWALSKI^JAN',
    'any-J?n Kowalski': 'KOWALSKI^JAN',
    'any-lukasz zolw': 'Żółw^Łukasz',
    'any-John Smith': 'Smith John',
    'any-*': 'JANKOWSKI^PIOTR,KOWALSKI^JAN,NOWAK^JAN MARIA,Smith John,Żółw^Łukasz',
    # In order, as the listener's C-FIND and the web portal still match.
    'kept-Jan Kowalski': '',
    'kept-Kowalski Jan': 'KOWALSKI^JAN',
    'kept-kowalski, jan': 'KOWALSKI^JAN',
    'kept-Jan^Kowalski': '',
    'kept-Maria Nowak': '',
    'kept-jan': 'JANKOWSKI^PIOTR',
    'kept-kowal*': 'KOWALSKI^JAN',
    'kept-J?n Kowalski': '',
    'kept-lukasz zolw': '',
    'kept-John Smith': '',
    'kept-*': 'JANKOWSKI^PIOTR,KOWALSKI^JAN,NOWAK^JAN MARIA,Smith John,Żółw^Łukasz',
    'soundex-any': 'KOWALSKI^JAN',
    'soundex-kept': '',
}
if results or not failures:
    for key, want in expected.items():
        if results.get(key) != want:
            failures.append('%s: %r, expected %r' % (key, results.get(key), want))
# --- the wiring --------------------------------------------------------------
# The database's name search is PatientNameMatching's, which the browser's
# -patientsnamePredicate:soundex: hands on.
names = helper_text[helper_text.index('public static func namePredicate(_ name: String?, soundex: ((String) -> String?)?'):]
names = names[:names.index('return NSCompoundPredicate(andPredicateWithSubpredicates')]
if 'undecomposedPattern(component:' not in names or 'name MATCHES[cd] %@' not in names:
    failures.append('the database name search does not also match the undecomposed letters')
delegate = browser[browser.index('func patientsnamePredicate(_ s: String!, soundex: Bool)'):]
method = delegate[:delegate.index('\n    }\n')]
if 'PatientNameMatching.namePredicate(s, soundex: soundex ? { DicomStudy.soundex($0) } : nil,' not in method:
    failures.append('the browser\'s name search is not the database\'s')
if 'anyOrder: PreferencesSource.process.preferences[NetworkPreferences.findsPatientNamesInAnyWordOrder])' not in method:
    failures.append('the browser\'s name search does not find a name in any word order when the preferences say so')
if '!component.contains("*")' not in names:
    failures.append('a wildcard component would be turned into a pattern too')
at = query.find('if let name = filters.patientName {')
retry = query[at:query.find('nodeAnswers = found.studies', at)] if at >= 0 else ''
for needed in ('PatientNameQueryForms.steps(\n                                for: name, spellings: filters.nameAlternatives,',
               'anyWordOrder: self.preferences[NetworkPreferences.findsPatientNamesInAnyWordOrder])',
               'PatientNameQueryForms.answers(of: steps, stops: { Thread.current.isCancelled }',
               'manager.addFilter(term + "*", forDescription: QueryWindowField.patientName.key)',
               'let answered = QueryController.answered(manager)',
               'PatientNameQueryForms.Answer((manager.queries() as? [Any]) ?? [], answered: answered)',
               'QueryController.queryUID(study as AnyObject)'):
    if needed not in retry:
        failures.append('a remote search that found nothing is not asked again in the steps of the name: ' + needed.strip())
# A query that failed or was given up (Escape, Stop) ends the name's forms:
# the node's last query answered only when it succeeded and was not aborted.
at = network.find('nonisolated static func answered(_ manager: QueryArrayController) -> Bool {')
answered = network[at:network.find('\n    }\n', at)] if at >= 0 else ''
if 'manager.rootNode() as? DCMTKQueryNode' not in answered or 'root.lastQuerySucceeded && !root._abortAssociation' not in answered:
    failures.append('a failed or aborted query does not end the forms of the name')
# The browser's distant search asks each node on its own, and a node's query
# says whether it answered.
at = distant.find('searchingEachNode search:')
each = distant[at:distant.find('\n    }\n', at)] if at >= 0 else ''
for needed in ('for server in comparativeServers()', 'await search { filters in',
               'studiesNow(matching: filters, on: server)', 'QueryResultMerge.merge('):
    if needed not in each:
        failures.append('the browser\'s distant search does not ask the forms of the name node by node: ' + needed)
at = distant.find('func studiesNow(matching filters: [String: PropertyListValue], on server: DistantServer)')
one = distant[at:distant.find('\n    }\n', at)] if at >= 0 else ''
if 'server: server.properties' not in one or 'answered: found.answered' not in one:
    failures.append('a node of the distant search does not say whether it answered')
at = network.find('nonisolated class func queryStudies(forFilters filters: [AnyHashable: Any], server: [String: Any],')
node = network[at:network.find('\n    }\n', at)] if at >= 0 else ''
if 'found = (studiesForThisNode as? [Any], answered(qm))' not in node:
    failures.append('the query of one node does not say whether it answered')
if 'Int32(found.queries)' not in retry:
    failures.append('the log does not say how many queries each node was asked for the name')
if 'let answers = nodeAnswers ?? (manager.queries() as? [Any]) ?? []' not in query:
    failures.append('the merged answers of the name\'s forms are not the node\'s answers')
if 'PatientNameMatching.alternativeRemoteTerms(\n            for: name, encoding: NSString.encoding(forDICOMCharacterSet: preferences[NetworkPreferences.queryCharacterSet]))' not in query:
    failures.append('the other forms of the name are not worked out for the query character set')
if project.count('PatientNameMatching.swift in Sources') != 2:
    failures.append('PatientNameMatching.swift is not built into the application')

if failures:
    print('FAIL')
    for failure in failures:
        print(' -', failure)
    sys.exit(1)
print('PASS: names are found whatever the case, diacritics and word order (%d checks), in the database and on a PACS that keeps capitals' % len(results))
