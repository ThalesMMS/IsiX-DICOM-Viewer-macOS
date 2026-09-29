#!/usr/bin/env python3
"""Upgrading an index of an older model closes what it opened and survives a study without a name (#862).

-upgradeSqlFileFromModelVersion: copies Database.sql, opened with the former
model, into Database3.sql, opened with the current one, and then renames
Database.sql to Database-Old-PreviousVersion.sql and Database3.sql to
Database.sql.

1. The models, coordinators and contexts it created were never released (the
   Objective-C declared them twice, and released the outer, nil, ones), so both
   stores stayed open while their files were renamed: the index the database
   then opened as Database.sql was still held by a coordinator of the upgrade,
   and what Core Data kept in Database3.sql's write-ahead log was left behind
   under the old name. The stores are now closed before the rename, and again
   after the upgrade whether or not it finished, before a rebuild moves the
   index.
2. A study that could not be copied was listed by its name, and one without a
   name made -addObject: raise nil inside the handler: the whole upgrade
   stopped and the index was rebuilt from the files. It is now listed under a
   name that is never nil.

The helpers run compiled from the source with xcrun swiftc, against a real
SQLite store; the upgrade method itself needs the application around it, so
where it calls them is read from the source. `<git revision>` as an optional
argument reads the sources of that revision, the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []
SOURCE = 'Horos/Sources/DicomDatabase+Other.swift'


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('utf-8')
    return (root / path).read_text()


def private_function(text, name):
    match = re.search(r'^private func %s\(.*?^}\n' % re.escape(name), text, re.S | re.M)
    return match.group(0) if match else None


text = read(SOURCE)
start = text.find('@objc(upgradeSqlFileFromModelVersion:)')
end = text.find('@objc(', start + 1)
upgrade = text[start:end] if start >= 0 and end > start else ''
if not upgrade:
    failures.append('-upgradeSqlFileFromModelVersion: is not in %s' % SOURCE)

# --- 1. what the upgrade opens is closed before the files move ----------------
close = private_function(text, 'closeUpgradeStores')
if 'passRetained' in upgrade or re.search(r'\bleak\(', upgrade):
    failures.append('the upgrade still keeps its models, coordinators and contexts alive for good')
if close is None:
    failures.append('there is nothing that closes the stores the upgrade opened')
if upgrade:
    rename = upgrade.find('moveUpgradedIndex(self.sqlFilePath')
    before = upgrade.rfind('closeUpgradeStores(', 0, rename)
    if rename < 0:
        failures.append('the upgrade no longer renames the index; this test needs a new look')
    elif before < 0 or upgrade.find('try? newContext.save()', before) >= 0:
        failures.append('Database.sql and Database3.sql are renamed while their stores are still open')
    handler = upgrade.find('if let e = exception')
    after = upgrade.rfind('closeUpgradeStores(', 0, handler)
    attempt_end = upgrade.rfind('\n        }\n', 0, handler)
    if handler < 0 or after < 0 or after < attempt_end:
        failures.append('when the upgrade stops, its stores stay open while the index is rebuilt')
    for owned in ('openedContexts = [oldContext, newContext]',
                  'openedCoordinators = [oldPersistentStoreCoordinator, newPersistentStoreCoordinator]'):
        if owned not in upgrade:
            failures.append('the cleanup does not hold what the upgrade opened: %s' % owned)
    options = re.search(r'"Database3\.sql"\)!\), options: (.*)\)\n', upgrade)
    new_store_options = options.group(1) if options else 'nil'

# --- 2. a study without a name ------------------------------------------------
name = private_function(text, 'upgradeProblemName')
if re.search(r'add\(studyName, to: upgradeProblems\)', upgrade):
    failures.append('a study without a name still adds nil to the upgrade problems, which raises')
if name is None or 'upgradeProblems.add(upgradeProblemName(studyName))' not in upgrade:
    failures.append('a study that could not be copied is not listed under a name that is never nil')

DOUBLES = '''
import CoreData
import Foundation

enum DicomDatabaseObjC {
    static func attempt(_ body: () -> Void) -> NSException? { body(); return nil }
    static func log(_ exception: NSException, stack: Bool, _ function: String) { print("logged\\t\\(exception)") }
    static func logError(_ message: String?, _ function: String) { print("logged\\t\\(message ?? "")") }
}
'''

DRIVER = '''
import CoreData
import Foundation

func emit(_ key: String, _ value: String) { print("\\(key)\\t\\(value)") }

emit("name.nil", upgradeProblemName(nil))
emit("name.empty", upgradeProblemName(""))
emit("name.named", upgradeProblemName("DOE^JANE"))

let study = NSEntityDescription()
study.name = "Study"
let attribute = NSAttributeDescription()
attribute.name = "name"
attribute.attributeType = .stringAttributeType
attribute.isOptional = true
study.properties = [attribute]
let model = NSManagedObjectModel()
model.entities = [study]

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let database3 = folder.appendingPathComponent("Database3.sql")
let database = folder.appendingPathComponent("Database.sql")

let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
let context = NSManagedObjectContext()
context.persistentStoreCoordinator = coordinator
context.undoManager = nil
try! coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: database3, options: NEW_STORE_OPTIONS)
for n in 0..<250 {
    NSEntityDescription.insertNewObject(forEntityName: "Study", into: context).setValue("study \\(n)", forKey: "name")
}
try! context.save()

closeUpgradeStores([context], [coordinator])
emit("stores.left", "\\(coordinator.persistentStores.count)")
emit("context.objects", "\\(context.registeredObjects.count)")
closeUpgradeStores([context], [coordinator]) // after the upgrade, again
emit("stores.again", "\\(coordinator.persistentStores.count)")

// The rename of the upgrade: only Database3.sql moves.
try! FileManager.default.moveItem(at: database3, to: database)

let reopened = NSPersistentStoreCoordinator(managedObjectModel: model)
try! reopened.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: database,
                                 options: [NSSQLitePragmasOption: ["journal_mode": "delete"]])
let check = NSManagedObjectContext()
check.persistentStoreCoordinator = reopened
let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Study")
emit("renamed.studies", "\\((try? check.count(for: request)) ?? -1)")
'''

results = {}
if close is not None and name is not None and upgrade:
    with tempfile.TemporaryDirectory(prefix='horos-upgrade-stores-') as directory:
        directory = Path(directory)
        (directory / 'doubles.swift').write_text(DOUBLES)
        # File-private in the app; the driver is another file.
        helpers = (close + '\n' + name).replace('private func ', 'func ')
        (directory / 'helpers.swift').write_text('import CoreData\nimport Foundation\n\n' + helpers)
        (directory / 'main.swift').write_text(DRIVER.replace('NEW_STORE_OPTIONS', new_store_options))
        binary = directory / 'upgrade-stores'
        built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-o', str(binary),
                                str(directory / 'doubles.swift'), str(directory / 'helpers.swift'),
                                str(directory / 'main.swift')], capture_output=True, text=True)
        if built.returncode != 0:
            failures.append('the upgrade helpers do not compile:\n%s' % built.stderr[-1500:])
        else:
            store = directory / 'store'
            store.mkdir()
            run = subprocess.run([str(binary), str(store)], capture_output=True, text=True)
            if run.returncode != 0:
                failures.append('the driver failed: %s' % run.stderr[-800:])
            for line in run.stdout.splitlines():
                key, _, value = line.partition('\t')
                results[key] = value
            if results.get('logged') is not None:
                failures.append('closing the stores logged a failure: %s' % results['logged'])

if results:
    for key in ('name.nil', 'name.empty'):
        if not results.get(key):
            failures.append('%s: a study without a name is listed as %r' % (key, results.get(key)))
    expected = {'name.named': 'DOE^JANE', 'stores.left': '0', 'context.objects': '0',
                'stores.again': '0', 'renamed.studies': '250'}
    for key, want in expected.items():
        if results.get(key) != want:
            failures.append('%s: %r, expected %r' % (key, results.get(key), want))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the upgrade closes both stores before renaming their files and after it stops, '
      'and lists a study without a name without raising')
