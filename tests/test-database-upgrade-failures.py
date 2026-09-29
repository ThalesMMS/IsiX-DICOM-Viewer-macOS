#!/usr/bin/env python3
"""Upgrading an index of an older model neither replaces it with an incomplete copy nor loses studies in silence (#871).

-upgradeSqlFileFromModelVersion: copies Database.sql, opened with the former
model, into Database3.sql, and renames Database3.sql to Database.sql.

1. When the former index did not open, the error was only logged: the fetches
   returned nothing, and an empty index replaced Database.sql without a word.
   A store that does not open, a fetch of the former index that fails and a
   save of the albums that fails now stop the upgrade before the rename, and
   its error path warns the user.
2. The studies were saved a hundred at a time with try?: a study that did not
   validate made the save of its batch fail, and the reset that followed threw
   the whole batch away. A batch that does not save is now copied again one
   study at a time, each saved on its own, and only the studies that still do
   not save are listed, once each. A study whose copy raised no longer stays
   half copied in the context.
3. A Database3.sql-wal or -shm left by an upgrade that did not finish is removed
   with Database3.sql and its journal before the upgrade starts.
4. The studies were fetched again after each hundred and cut into the next
   hundred only when there were more than 100 of them: with exactly 100, the
   same 100 were copied again without end (#875). They are now walked once, by
   object identifier, a hundred at a time.
5. The final renames used try?: when Database.sql became
   Database-Old-PreviousVersion.sql and Database3.sql then did not become
   Database.sql, no index was left (#875). The former index is now put back and
   the upgrade stops on its error path.
6. The albums of the new index were fetched with try?: a fetch that failed left
   the studies out of their albums without a word (#878). It now stops the
   upgrade on its error path. An album of a study whose name was not found in
   the new index raised, and the study's other albums were skipped: it is now
   logged, and the study is added to the others.
7. The album of the new index was found by name, and the first of two albums of
   the same name took the studies of both while the second stayed empty (#880).
   Each copy is now found by the identity of the former album, through object
   identifiers that stay valid when the contexts are reset between hundreds.

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


def catch_after(text, marker):
    """The body of the catch that follows `marker`, or None."""
    at = text.find(marker)
    if at < 0:
        return None
    match = re.search(r'\} catch \{\n(.*?)\n( *)\}\n', text[at:], re.S)
    return match.group(1) if match else None


text = read(SOURCE)
start = text.find('@objc(upgradeSqlFileFromModelVersion:)')
end = text.find('@objc(', start + 1)
upgrade = text[start:end] if start >= 0 and end > start else ''
if not upgrade:
    failures.append('-upgradeSqlFileFromModelVersion: is not in %s' % SOURCE)

# --- 1. what cannot be read or written stops the upgrade ----------------------
if upgrade:
    rename = upgrade.find('moveUpgradedIndex(self.sqlFilePath')
    if rename < 0:
        failures.append('the upgrade no longer renames the index; this test needs a new look')
    for store, marker in (('the former index', 'try oldPersistentStoreCoordinator.addPersistentStore('),
                          ('Database3.sql', 'try newPersistentStoreCoordinator.addPersistentStore(')):
        handler = catch_after(upgrade, marker)
        if handler is None:
            failures.append('%s is no longer opened in a do/catch; this test needs a new look' % store)
        elif '.raise()' not in handler:
            failures.append('when %s does not open, the upgrade goes on and replaces the index' % store)
    if re.search(r'try\? oldContext\.fetch\(', upgrade):
        failures.append('a fetch of the former index that fails still reads as no albums or no studies')
    if 'try? newContext.save()' in upgrade:
        failures.append('a save of the new index still fails in silence')
    albums = upgrade.find('// STUDIES')
    album_save = catch_after(upgrade[:albums], 'try newContext.save()') if albums >= 0 else None
    if album_save is None or '.raise()' not in album_save:
        failures.append('albums that do not save do not stop the upgrade')
    handler = upgrade.find('if let e = exception')
    tail = upgrade[handler:]
    if handler < 0 or 'HorosAlertPanel.run(' not in tail or 'self.rebuild(true)' not in tail:
        failures.append('the error path of the upgrade no longer warns and rebuilds; this test needs a new look')

failure = private_function(text, 'upgradeFailure')
if failure is None or 'raise' in failure:
    failures.append('there is no exception for a failed upgrade to stop with')

# --- 2. a batch that does not save --------------------------------------------
batch = private_function(text, 'saveUpgradeBatch')
name = private_function(text, 'upgradeProblemName')
if batch is None:
    failures.append('a batch of studies that does not save is not handled')
if upgrade:
    saves = upgrade.count('saveBatch()')
    if saves < 2 or 'saveUpgradeBatch(newContext, batch' not in upgrade:
        failures.append('the upgrade does not save its batches, and the last one, through saveUpgradeBatch')
    study_handler = upgrade.find('NSLog("STUDY LEVEL: Problems during updating')
    if study_handler < 0 or 'for object in inserted { newContext.delete(object) }' not in upgrade[study_handler:study_handler + 800]:
        failures.append('a study whose copy raised stays half copied in the context')

# --- 3. leftovers of an upgrade that did not finish ---------------------------
leftovers = private_function(text, 'removeLeftoverUpgradeIndex')
if leftovers is None:
    failures.append('nothing removes what an earlier upgrade left of Database3.sql')
elif upgrade:
    remove = upgrade.find('removeLeftoverUpgradeIndex(self.baseDirPath)')
    opened = upgrade.find('try newPersistentStoreCoordinator.addPersistentStore(')
    if remove < 0 or opened < 0 or remove > opened:
        failures.append('the leftovers of Database3.sql are not removed before it is opened')

# --- 4. each study once, a hundred at a time ---------------------------------
identifiers = private_function(text, 'upgradeStudyIdentifiers')
walk = private_function(text, 'forEachUpgradeStudy')
if identifiers is None or walk is None:
    failures.append('the studies are not walked once each, a hundred at a time')
if upgrade:
    if 'sortedChunk(' in upgrade or 'studies.count > 100' in upgrade:
        failures.append('the upgrade still fetches the studies again and cuts them only past 100')
    walked = upgrade.find('forEachUpgradeStudy(studyIdentifiers, in: oldContext')
    if 'upgradeStudyIdentifiers(fetchOld(dbRequest))' not in upgrade or walked < 0:
        failures.append('the upgrade does not copy the studies through forEachUpgradeStudy')
    else:
        between = upgrade.find('betweenChunks: {', walked)
        body = upgrade[between:upgrade.find('\n            })\n', between)] if between >= 0 else ''
        for step in ('saveBatch()', 'newContext.reset()', 'oldContext.reset()', 'newAlbums = nil'):
            if step not in body:
                failures.append('a hundred studies are not saved and forgotten before the next: %s' % step)

# --- 5. the final renames -----------------------------------------------------
move = private_function(text, 'moveUpgradedIndex')
if move is None:
    failures.append('nothing puts the former index back when the upgraded one cannot take its place')
if upgrade:
    if re.search(r'try\? FileManager\.default\.moveItem\(', upgrade):
        failures.append('a rename of the index still fails in silence')
    moved = catch_after(upgrade, 'try moveUpgradedIndex(')
    if moved is None or '.raise()' not in moved:
        failures.append('a rename that fails does not stop the upgrade on its error path')

# --- 6. and 7. the albums of the new index -----------------------------------
add_to_albums = private_function(text, 'addUpgradedStudy')
copy_albums = private_function(text, 'copyUpgradeAlbums')
if add_to_albums is None:
    failures.append('a study is not added to its albums by a helper that skips an album it cannot find')
elif 'index(of:' in add_to_albums or 'names' in add_to_albums:
    failures.append('the album of a study is still found by its name, which two albums may share')
if copy_albums is None:
    failures.append('the albums are not copied by a helper that keeps the copy of each former album')
if upgrade:
    if re.search(r'try\? newContext\.fetch\(', upgrade):
        failures.append('a fetch of the albums of the new index that fails still reads as no albums')
    fetched = catch_after(upgrade, 'try newContext.fetch(')
    if fetched is None or '.raise()' not in fetched:
        failures.append('a fetch of the albums of the new index that fails does not stop the upgrade')
    copy_start = upgrade.find('func copyStudy(')
    study_try = upgrade.find('if let e = DicomDatabaseObjC.attempt({', copy_start)
    fetch_call = upgrade.find('fetchNewAlbums()', copy_start)
    if copy_start < 0 or study_try < 0 or fetch_call < 0 or fetch_call > study_try:
        failures.append('the albums of the new index are fetched inside the study\'s @try, whose handler only lists the study')
    if 'addUpgradedStudy(newStudyTable, toCopiesOf: storedInAlbums, copies: albumCopies' not in upgrade:
        failures.append('the upgrade does not add the studies to the copies of their albums through addUpgradedStudy')
    albums_saved = upgrade.find('// STUDIES')
    copied = upgrade.find('albumCopies = try copyUpgradeAlbums(')
    if copied < 0 or albums_saved < 0 or copied > albums_saved:
        failures.append('the upgrade does not copy the albums through copyUpgradeAlbums before the studies')
    elif '.raise()' not in (catch_after(upgrade[copied:albums_saved], 'try newContext.save()') or ''):
        failures.append('albums that cannot be copied do not stop the upgrade')
    if 'var albumCopies: [NSManagedObjectID: NSManagedObjectID]' not in upgrade:
        failures.append('the copies of the albums are not kept by object identifier, which outlives the reset of the contexts')

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

func studyModel(uidRequired: Bool) -> NSManagedObjectModel {
    let study = NSEntityDescription()
    study.name = "Study"
    let name = NSAttributeDescription()
    name.name = "name"
    name.attributeType = .stringAttributeType
    name.isOptional = true
    let uid = NSAttributeDescription()
    uid.name = "studyInstanceUID"
    uid.attributeType = .stringAttributeType
    uid.isOptional = !uidRequired
    study.properties = [name, uid]
    let model = NSManagedObjectModel()
    model.entities = [study]
    return model
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])

// The former index: the identifier was optional there.
let oldCoordinator = NSPersistentStoreCoordinator(managedObjectModel: studyModel(uidRequired: false))
try! oldCoordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil, options: nil)
let oldContext = NSManagedObjectContext()
oldContext.persistentStoreCoordinator = oldCoordinator
var oldStudies: [NSManagedObject] = []
for (n, uid) in [("A", "1.1"), ("B", "1.2"), ("BAD", nil), ("C", "1.3"), ("RAISES", "1.4"), ("D", "1.5")] as [(String, String?)] {
    let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: oldContext)
    study.setValue(n, forKey: "name")
    study.setValue(uid, forKey: "studyInstanceUID")
    oldStudies.append(study)
}
try! oldContext.save()

func run(_ label: String, _ studies: [NSManagedObject], raisingOnRetry: Set<String>) {
    let url = folder.appendingPathComponent("\\(label).sql")
    let model = studyModel(uidRequired: true)
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    try! coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url,
                                        options: [NSSQLitePragmasOption: ["journal_mode": "delete"]])
    let context = NSManagedObjectContext()
    context.persistentStoreCoordinator = coordinator
    context.undoManager = nil

    let problems = NSMutableArray()
    var pass = 0
    func copy(_ old: NSManagedObject) -> Bool {
        let name = old.value(forKey: "name") as! String
        if pass > 0 && raisingOnRetry.contains(name) {
            problems.add(upgradeProblemName(name)) // what the upgrade does when a copy raises
            return false
        }
        let new = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
        new.setValue(name, forKey: "name")
        new.setValue(old.value(forKey: "studyInstanceUID"), forKey: "studyInstanceUID")
        return true
    }
    for study in studies { _ = copy(study) }
    pass = 1
    saveUpgradeBatch(context, studies, problems: problems, copy: copy,
                     name: { upgradeProblemName($0.value(forKey: "name")) })
    emit("\\(label).problems", (problems as! [String]).joined(separator: ","))
    emit("\\(label).pending", "\\(context.insertedObjects.count)")

    let check = NSManagedObjectContext()
    check.persistentStoreCoordinator = coordinator
    let request = NSFetchRequest<NSManagedObject>(entityName: "Study")
    request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
    let saved = ((try? check.fetch(request)) ?? []).map { $0.value(forKey: "name") as! String }
    emit("\\(label).saved", saved.joined(separator: ","))
}

let valid = oldStudies.filter { ($0.value(forKey: "name") as! String) != "BAD" }
run("valid", valid, raisingOnRetry: ["RAISES"])
run("invalid", oldStudies, raisingOnRetry: ["RAISES"])

// Leftovers of an upgrade that did not finish, next to the index.
let base = folder.appendingPathComponent("base")
try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
for file in ["Database.sql", "Database3.sql", "Database3.sql-journal", "Database3.sql-wal", "Database3.sql-shm"] {
    try! Data("x".utf8).write(to: base.appendingPathComponent(file))
}
removeLeftoverUpgradeIndex(base.path)
emit("leftovers", (try! FileManager.default.contentsOfDirectory(atPath: base.path)).sorted().joined(separator: ","))
'''

results = {}
logged = []
if batch is not None and name is not None and leftovers is not None:
    with tempfile.TemporaryDirectory(prefix='horos-upgrade-failures-') as directory:
        directory = Path(directory)
        (directory / 'doubles.swift').write_text(DOUBLES)
        # File-private in the app; the driver is another file.
        helpers = (batch + '\n' + name + '\n' + leftovers).replace('private func ', 'func ')
        (directory / 'helpers.swift').write_text('import CoreData\nimport Foundation\n\n' + helpers)
        (directory / 'main.swift').write_text(DRIVER)
        binary = directory / 'upgrade-failures'
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
                if key == 'logged':
                    logged.append(value)
                else:
                    results[key] = value

PAGING_DRIVER = '''
import CoreData
import Foundation

func emit(_ key: String, _ value: String) { print("\\(key)\\t\\(value)") }

let folder = URL(fileURLWithPath: CommandLine.arguments[1])

let study = NSEntityDescription()
study.name = "Study"
var properties: [NSAttributeDescription] = []
for key in ["name", "patientUID"] {
    let attribute = NSAttributeDescription()
    attribute.name = key
    attribute.attributeType = .stringAttributeType
    attribute.isOptional = true
    properties.append(attribute)
}
study.properties = properties
let model = NSManagedObjectModel()
model.entities = [study]

// A former index of n studies, several of them per patient, walked as the upgrade
// walks it: the context is reset between hundreds, as the upgrade resets it.
for n in [1, 99, 100, 101, 200, 250] {
    let url = folder.appendingPathComponent("former-\\(n).sql")
    let writer = NSPersistentStoreCoordinator(managedObjectModel: model)
    try! writer.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: nil)
    let written = NSManagedObjectContext()
    written.persistentStoreCoordinator = writer
    for i in 0..<n {
        let row = NSEntityDescription.insertNewObject(forEntityName: "Study", into: written)
        row.setValue("study \\(i)", forKey: "name")
        row.setValue("P\\(i % 7)", forKey: "patientUID")
    }
    try! written.save()
    for store in writer.persistentStores { try! writer.remove(store) }

    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    try! coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: nil)
    let context = NSManagedObjectContext()
    context.persistentStoreCoordinator = coordinator

    let request = NSFetchRequest<NSFetchRequestResult>()
    request.entity = model.entitiesByName["Study"]
    request.predicate = NSPredicate(value: true)
    let ids = upgradeStudyIdentifiers(try! context.fetch(request))

    var copied: [String] = []
    var chunks: [[String]] = [[]]
    forEachUpgradeStudy(ids, in: context, copy: { old in
        copied.append(old.value(forKey: "name") as! String)
        chunks[chunks.count - 1].append(old.value(forKey: "patientUID") as! String)
        if copied.count > 3 * n {
            emit("\\(n).endless", "yes")
            exit(3)
        }
    }, betweenChunks: {
        chunks.append([])
        context.reset()
    })

    let expected = Set((0..<n).map { "study \\($0)" })
    emit("\\(n).copies", "\\(copied.count)")
    emit("\\(n).each-once", Set(copied) == expected && copied.count == n ? "yes" : "no")
    emit("\\(n).chunks", chunks.map { "\\($0.count)" }.joined(separator: ","))
    var sorted = true
    for (a, b) in zip(chunks, chunks.dropFirst()) where (a.max() ?? "") > (b.min() ?? "~") { sorted = false }
    emit("\\(n).sorted", sorted ? "yes" : "no")
}

// The final renames.
func files(_ base: URL) -> String {
    let names = (try! FileManager.default.contentsOfDirectory(atPath: base.path)).sorted()
    return names.map { "\\($0)=" + (try! String(contentsOf: base.appendingPathComponent($0), encoding: .utf8)) }.joined(separator: ",")
}
for (label, upgraded) in [("moved", true), ("missing", false)] {
    let base = folder.appendingPathComponent(label)
    try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try! "former".write(to: base.appendingPathComponent("Database.sql"), atomically: false, encoding: .utf8)
    try! "stale".write(to: base.appendingPathComponent("Database-Old-PreviousVersion.sql"), atomically: false, encoding: .utf8)
    if upgraded {
        try! "upgraded".write(to: base.appendingPathComponent("Database3.sql"), atomically: false, encoding: .utf8)
    }
    var thrown = "no"
    do {
        try moveUpgradedIndex(base.appendingPathComponent("Database.sql").path,
                              upgraded: base.appendingPathComponent("Database3.sql").path,
                              previous: base.appendingPathComponent("Database-Old-PreviousVersion.sql").path)
    } catch {
        thrown = "yes"
    }
    emit("\\(label).thrown", thrown)
    emit("\\(label).files", files(base))
}
'''

paging = {}
if identifiers is not None and walk is not None and move is not None:
    with tempfile.TemporaryDirectory(prefix='horos-upgrade-paging-') as directory:
        directory = Path(directory)
        (directory / 'doubles.swift').write_text(DOUBLES)
        # File-private in the app; the driver is another file.
        helpers = (identifiers + '\n' + walk + '\n' + move).replace('private func ', 'func ')
        (directory / 'helpers.swift').write_text('import CoreData\nimport Foundation\n\n' + helpers)
        (directory / 'main.swift').write_text(PAGING_DRIVER)
        binary = directory / 'upgrade-paging'
        built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-o', str(binary),
                                str(directory / 'doubles.swift'), str(directory / 'helpers.swift'),
                                str(directory / 'main.swift')], capture_output=True, text=True)
        if built.returncode != 0:
            failures.append('the paging and rename helpers do not compile:\n%s' % built.stderr[-1500:])
        else:
            store = directory / 'store'
            store.mkdir()
            try:
                run = subprocess.run([str(binary), str(store)], capture_output=True, text=True, timeout=120)
            except subprocess.TimeoutExpired:
                run = None
                failures.append('walking the studies did not end')
            if run is not None:
                for line in run.stdout.splitlines():
                    key, _, value = line.partition('\t')
                    if key != 'logged':
                        paging[key] = value
                if run.returncode != 0:
                    failures.append('the paging driver failed (%d): %s' % (run.returncode, run.stderr[-800:]))

if paging:
    for n, sizes in {1: '1', 99: '99', 100: '100', 101: '100,1', 200: '100,100', 250: '100,100,50'}.items():
        if paging.get('%d.endless' % n):
            failures.append('%d studies are copied again without end' % n)
        for key, want in (('copies', str(n)), ('each-once', 'yes'), ('chunks', sizes), ('sorted', 'yes')):
            got = paging.get('%d.%s' % (n, key))
            if got != want:
                failures.append('%d studies, %s: %r, expected %r' % (n, key, got, want))
    expected = {
        # Database3.sql takes the place of Database.sql, which is kept aside.
        'moved.thrown': 'no',
        'moved.files': 'Database-Old-PreviousVersion.sql=former,Database.sql=upgraded',
        # Database3.sql cannot move: Database.sql comes back as it was.
        'missing.thrown': 'yes',
        'missing.files': 'Database.sql=former',
    }
    for key, want in expected.items():
        if paging.get(key) != want:
            failures.append('%s: %r, expected %r' % (key, paging.get(key), want))

if results:
    expected = {
        # A batch that saves is saved whole, and nothing is copied twice.
        'valid.problems': '', 'valid.pending': '0', 'valid.saved': 'A,B,C,D,RAISES',
        # One study that does not validate: the others are kept, it alone is
        # listed, and a study whose copy raises on the retry is listed once.
        'invalid.problems': 'BAD,RAISES', 'invalid.pending': '0', 'invalid.saved': 'A,B,C,D',
        'leftovers': 'Database.sql',
    }
    for key, want in expected.items():
        if results.get(key) != want:
            failures.append('%s: %r, expected %r' % (key, results.get(key), want))
    if not logged:
        failures.append('the save that failed was not logged')

ALBUM_DRIVER = '''
import CoreData
import Foundation

func emit(_ key: String, _ value: String) { print("\\(key)\\t\\(value)") }

func attribute(_ name: String) -> NSAttributeDescription {
    let attribute = NSAttributeDescription()
    attribute.name = name
    attribute.attributeType = .stringAttributeType
    attribute.isOptional = true
    return attribute
}

let album = NSEntityDescription()
album.name = "Album"
let study = NSEntityDescription()
study.name = "Study"
let studies = NSRelationshipDescription()
studies.name = "studies"
studies.destinationEntity = study
studies.minCount = 0
studies.maxCount = 0
studies.isOptional = true
let albums = NSRelationshipDescription()
albums.name = "albums"
albums.destinationEntity = album
albums.minCount = 0
albums.maxCount = 0
albums.isOptional = true
studies.inverseRelationship = albums
albums.inverseRelationship = studies
album.properties = [attribute("name"), studies]
study.properties = [attribute("name"), albums]
let model = NSManagedObjectModel()
model.entities = [album, study]

func context(_ url: URL) -> NSManagedObjectContext {
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    try! coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: nil)
    let context = NSManagedObjectContext()
    context.persistentStoreCoordinator = coordinator
    context.undoManager = nil
    return context
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])

// The former index: S is in three albums, the second of which does not reach
// the new index; T and U are each in one of two albums named Same, and U also
// in Third; Empty has no study.
let old = context(folder.appendingPathComponent("former.sql"))
var formerStudies: [String: NSManagedObject] = [:]
for name in ["S", "T", "U"] {
    let row = NSEntityDescription.insertNewObject(forEntityName: "Study", into: old)
    row.setValue(name, forKey: "name")
    formerStudies[name] = row
}
for (name, members) in [("First", ["S"]), ("Lost", ["S"]), ("Third", ["S", "U"]), ("Same", ["T"]), ("Same", ["U"]), ("Empty", [])] {
    let row = NSEntityDescription.insertNewObject(forEntityName: "Album", into: old)
    row.setValue(name, forKey: "name")
    for member in members { row.mutableSetValue(forKey: "studies").add(formerStudies[member]!) }
}
try! old.save()
let studyIDs = ["S", "T", "U"].map { formerStudies[$0]!.objectID }
old.reset()

// The albums copied as the upgrade copies them, then saved.
let new = context(folder.appendingPathComponent("upgraded.sql"))
let formerAlbums = try! old.fetch(NSFetchRequest<NSFetchRequestResult>(entityName: "Album"))
let copies = try! copyUpgradeAlbums(formerAlbums, attributes: ["name"], into: new)
emit("copies", "\\(copies.count)")
emit("temporary", copies.values.contains { $0.isTemporaryID } ? "yes" : "no")
try! new.save()
// The copy of Lost is not in the new index.
for case let row as NSManagedObject in try! new.fetch(NSFetchRequest<NSFetchRequestResult>(entityName: "Album"))
    where row.value(forKey: "name") as? String == "Lost" {
    new.delete(row)
}
try! new.save()

// Each study in its own batch: the contexts are reset between them, as the
// upgrade resets them between hundreds, and the albums fetched again.
for identifier in studyIDs {
    new.reset()
    old.reset()
    let fetched = try! new.fetch(NSFetchRequest<NSFetchRequestResult>(entityName: "Album")).compactMap { $0 as? NSManagedObject }
    let albums = Dictionary(fetched.map { ($0.objectID, $0) }, uniquingKeysWith: { first, _ in first })
    let formerStudy = old.object(with: identifier)
    let newStudy = NSEntityDescription.insertNewObject(forEntityName: "Study", into: new)
    newStudy.setValue(formerStudy.value(forKey: "name"), forKey: "name")
    addUpgradedStudy(newStudy, toCopiesOf: (formerStudy.value(forKey: "albums") as! NSSet).allObjects,
                     copies: copies, albums: albums)
    try! new.save()
}

let check = context(folder.appendingPathComponent("upgraded.sql"))
let saved = try! check.fetch(NSFetchRequest<NSManagedObject>(entityName: "Album"))
emit("albums", saved.map { album in
    let members = (album.value(forKey: "studies") as! Set<NSManagedObject>).map { $0.value(forKey: "name") as! String }.sorted()
    return "\\(album.value(forKey: "name")!)=" + members.joined(separator: "+")
}.sorted().joined(separator: ","))
'''

albums_results = {}
albums_logged = []
if add_to_albums is not None and copy_albums is not None:
    with tempfile.TemporaryDirectory(prefix='horos-upgrade-albums-') as directory:
        directory = Path(directory)
        (directory / 'doubles.swift').write_text(DOUBLES + '''
extension DicomDatabaseObjC {
    static func arg(_ object: Any?) -> CVarArg {
        if let object = object as? NSObject { return object }
        return "(null)" as NSString
    }
}
''')
        # File-private in the app; the driver is another file.
        helpers = (copy_albums + '\n' + add_to_albums).replace('private func ', 'func ')
        (directory / 'helpers.swift').write_text('import CoreData\nimport Foundation\n\n' + helpers)
        (directory / 'main.swift').write_text(ALBUM_DRIVER)
        binary = directory / 'upgrade-albums'
        built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-o', str(binary),
                                str(directory / 'doubles.swift'), str(directory / 'helpers.swift'),
                                str(directory / 'main.swift')], capture_output=True, text=True)
        if built.returncode != 0:
            failures.append('the album helpers do not compile:\n%s' % built.stderr[-1500:])
        else:
            store = directory / 'store'
            store.mkdir()
            run = subprocess.run([str(binary), str(store)], capture_output=True, text=True)
            if run.returncode != 0:
                failures.append('the album driver failed: %s' % run.stderr[-800:])
            for line in run.stdout.splitlines():
                key, _, value = line.partition('\t')
                if key == 'logged':
                    albums_logged.append(value)
                else:
                    albums_results[key] = value

if albums_results or (add_to_albums is not None and copy_albums is not None):
    expected = {
        'copies': '6',
        # Kept across the reset of the contexts, the copies are identified for good.
        'temporary': 'no',
        # Lost is not found and skipped: S stays in the other two. Each album
        # named Same keeps its own study, and Third both of its own.
        'albums': 'Empty=,First=S,Same=T,Same=U,Third=S+U',
    }
    for key, want in expected.items():
        if albums_results.get(key) != want:
            failures.append('albums, %s: %r, expected %r' % (key, albums_results.get(key), want))
    if not any('Lost' in line for line in albums_logged):
        failures.append('the album that was not found in the new index was not logged')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: an index that cannot be read or written stops the upgrade before the rename, a batch that '
      'does not save is saved study by study with the others kept, the leftovers of Database3.sql go, '
      'each study is copied once a hundred at a time, a rename that fails puts Database.sql back, '
      'and a study keeps the copies of its own albums, found by identity even when two share a name, '
      'while an album not found is logged')
