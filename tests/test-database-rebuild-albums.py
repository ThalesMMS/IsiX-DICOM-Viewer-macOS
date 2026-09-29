#!/usr/bin/env python3
"""A rebuild started by an upgrade that failed keeps the albums (#913).

-upgradeSqlFileFromModelVersion: runs from -contextAtPath: while the database
opens its index, before it has a managed object context. When it failed it
called -rebuild:YES, which saved the albums from that nil context: the albums
file was never written, and the rebuilt index had no album at all, not even the
default ones (-addDefaultAlbums only runs for a new file). The verified copy
the rebuild keeps in Index Backups/<uuid>/Database.sql still had them.

Now, with no context, the rebuild reads the albums from that copy, opened
read-only with the model its store is of, and restores them as before; when
they cannot be read it creates the default albums again and says where the
copy is. The upgrade that finds no model for the index no longer deletes it
before the rebuild, so that the rebuild keeps a copy of it too.

The reader runs compiled from the source with xcrun swiftc, against real
SQLite stores of the current model (compiled with momc from the
.xcdatamodeld) and of the former model 2.4 the application carries; -rebuild:
needs the application around it, so where it calls the reader is read from the
source. `<git revision>` as an optional argument reads the sources of that
revision, the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []
ALBUMS = 'Horos/Sources/DicomDatabase+Albums.swift'
OTHER = 'Horos/Sources/DicomDatabase+Other.swift'
MODEL = root / 'Horos/Models/OsiriXDB_DataModel.xcdatamodeld'
FORMER = root / 'Binaries/DB_Previous_Models/OsiriXDB_Previous_DataModel2.4.mom'


def read(path):
    if revision:
        result = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], capture_output=True)
        return result.stdout.decode('utf-8') if result.returncode == 0 else ''
    return (root / path).read_text()


def block(source, start):
    """From `start` to the brace that closes the first brace after it."""
    opening = source.find('{', start)
    if start < 0 or opening < 0:
        return ''
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    return ''


albums = read(ALBUMS)
other = read(OTHER)

# --- where -rebuild: and the upgrade use the reader ---------------------------
rebuild = block(other, other.find('@objc(rebuild:)'))
if not rebuild:
    failures.append('-rebuild: is not in %s' % OTHER)
else:
    save = rebuild.find('self.saveAlbums(toPath: savedAlbumsPath)')
    reader = rebuild.find('albumsFileEntries(ofIndexAtPath:', save)
    if save < 0 or reader < 0:
        failures.append('-rebuild: does not read the albums from the verified copy when it saves them')
    else:
        window = rebuild[save:reader]
        if 'self.managedObjectContext == nil' not in window:
            failures.append('-rebuild: does not read the copy when there is no context to save the albums from')
        if 'lastPathComponent' not in window or 'recoveryFolder' not in window:
            failures.append('-rebuild: does not read the albums from the copy in its recovery folder')
        moved = rebuild.find('self.managedObjectContext = nil')
        if moved >= 0 and moved < reader:
            failures.append('-rebuild: reads the copy after it has let go of the context')
    restore = rebuild.find('//Restore albums')
    defaults = re.search(r'if albumsLost \{\s*self\.addDefaultAlbums\(\)\s*\}', rebuild[restore:] if restore >= 0 else '')
    if restore < 0 or not defaults:
        failures.append('-rebuild: does not create the default albums again when those of the index are lost')
    told = re.search(r'if albumsLost, let recoveryFolder \{(.*?)\n            \}', rebuild, re.S)
    if not told or 'presentError' not in told.group(1) or 'recoveryFolder' not in told.group(1):
        failures.append('-rebuild: does not tell the person where the copy is when the albums are lost')

upgrade = block(other, other.find('@objc(upgradeSqlFileFromModelVersion:)'))
unknown = upgrade.find('cannot understand the model')
unknown_rebuild = upgrade.find('self.rebuild(true)', unknown)
if unknown < 0 or unknown_rebuild < 0:
    failures.append('the upgrade that finds no model for the index no longer rebuilds it; this test needs a new look')
elif 'removeItem(atPath: path)' in upgrade[unknown:unknown_rebuild].replace(
        'if let path = self.loadingFilePath() { try? FileManager.default.removeItem(atPath: path) }', ''):
    failures.append('the upgrade that finds no model still deletes the index before the rebuild, which then keeps no copy')

# --- the reader, against real stores ------------------------------------------
entry = block(albums, albums.find('private func albumsFileEntry('))
reader = block(albums, albums.find('func albumsFileEntries(ofIndexAtPath'))
if not reader:
    failures.append('there is nothing that reads the albums of an index the database has not opened')
if not entry:
    failures.append('the albums file entry is not a function of the album alone')

DOUBLES = '''
import CoreData
import Foundation

enum DicomDatabaseObjC {
    static func attempt(_ body: () -> Void) -> NSException? { body(); return nil }
    static func log(_ exception: NSException, stack: Bool, _ function: String) { print("logged\\t\\(exception)") }
    static func set(_ object: AnyObject?, _ key: String) -> NSSet? { return object?.value(forKey: key) as? NSSet }
}
'''

DRIVER = r'''
import CoreData
import Foundation

func emit(_ key: String, _ value: String) { print("\(key)\t\(value)") }

let arguments = CommandLine.arguments
let current = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: arguments[1]))!
let former = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: arguments[2]))!
let folder = URL(fileURLWithPath: arguments[3])

func has(_ object: NSManagedObject, _ key: String) -> Bool { return object.entity.propertiesByName[key] != nil }

/// An index of `model` with the albums a person could have.
func makeIndex(_ name: String, _ model: NSManagedObjectModel) -> String {
    let url = folder.appendingPathComponent(name).appendingPathComponent("Database.sql")
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    let store = try! coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url,
                                                    options: [NSSQLitePragmasOption: ["journal_mode": "delete"]])
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    context.performAndWait {
        func study(_ uid: String, _ patient: String) -> NSManagedObject {
            let s = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
            s.setValue(uid, forKey: "studyInstanceUID")
            s.setValue(patient, forKey: "name")
            if has(s, "modality") { s.setValue("CT", forKey: "modality") }
            return s
        }
        let a = study("1.2.3.1", "SYNTHETIC^A"), b = study("1.2.3.2", "SYNTHETIC^B"), _ = study("1.2.3.3", "SYNTHETIC^C")
        let teaching = NSEntityDescription.insertNewObject(forEntityName: "Album", into: context)
        teaching.setValue("Teaching", forKey: "name")
        teaching.setValue(false, forKey: "smartAlbum")
        teaching.mutableSetValue(forKey: "studies").addObjects(from: [a, b])
        let smart = NSEntityDescription.insertNewObject(forEntityName: "Album", into: context)
        smart.setValue("Today CT", forKey: "name")
        smart.setValue(true, forKey: "smartAlbum")
        smart.setValue("(modality CONTAINS[cd] 'CT') AND (date >= $NSDATE_TODAY)", forKey: "predicateString")
        let empty = NSEntityDescription.insertNewObject(forEntityName: "Album", into: context)
        empty.setValue("Interesting Cases", forKey: "name")
        empty.setValue(false, forKey: "smartAlbum")
        let second = NSEntityDescription.insertNewObject(forEntityName: "Album", into: context)
        second.setValue("Follow-up", forKey: "name")
        second.setValue(false, forKey: "smartAlbum")
        second.mutableSetValue(forKey: "studies").add(a)
        try! context.save()
    }
    try! coordinator.remove(store)
    return url.path
}

func describe(_ entries: NSArray?) -> String {
    guard let entries else { return "nil" }
    return entries.map { item -> String in
        let d = item as! NSDictionary
        let name = d["name"] as? String ?? "<none>"
        if (d["smartAlbum"] as? NSNumber)?.boolValue ?? false { return "\(name)*\(d["predicateString"] as? String ?? "")" }
        let studies = ((d["studies"] as? [NSDictionary]) ?? []).map { "\($0["studyInstanceUID"] as? String ?? "?")/\($0["patientName"] as? String ?? "?")" }.sorted()
        return "\(name)\(studies)"
    }.sorted().joined(separator: " ")
}

func listing(_ path: String) -> String {
    let directory = (path as NSString).deletingLastPathComponent
    return ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted().joined(separator: ",")
}

let now = makeIndex("current", current)
emit("current.before", listing(now))
let bytes = try! Data(contentsOf: URL(fileURLWithPath: now))
let read = albumsFileEntries(ofIndexAtPath: now, models: [current, former])
emit("current.albums", describe(read))
emit("current.after", listing(now))
emit("current.unchanged", "\(bytes == (try? Data(contentsOf: URL(fileURLWithPath: now))))")
// What -loadAlbumsFromPath: reads: the file written by the rebuild.
let file = folder.appendingPathComponent("Albums.plist").path
emit("current.written", read?.write(toFile: file, atomically: true) == true ? describe(NSArray(contentsOfFile: file)) : "unwritten")

let old = makeIndex("former", former)
emit("former.albums", describe(albumsFileEntries(ofIndexAtPath: old, models: [current, former])))
emit("former.after", listing(old))
emit("former.unknown", describe(albumsFileEntries(ofIndexAtPath: old, models: [current])))

let corrupt = folder.appendingPathComponent("corrupt.sql").path
try! "not a SQLite database".write(toFile: corrupt, atomically: true, encoding: .utf8)
emit("corrupt", describe(albumsFileEntries(ofIndexAtPath: corrupt, models: [current, former])))
emit("missing", describe(albumsFileEntries(ofIndexAtPath: folder.appendingPathComponent("missing.sql").path, models: [current])))
'''

results = {}
if reader and entry:
    with tempfile.TemporaryDirectory(prefix='horos-rebuild-albums-') as directory:
        directory = Path(directory)
        compiled = subprocess.run(['xcrun', 'momc', str(MODEL), str(directory)], capture_output=True, text=True)
        momd = directory / 'OsiriXDB_DataModel.momd'
        if compiled.returncode != 0 or not momd.exists():
            failures.append('the data model does not compile with momc:\n%s' % compiled.stderr[-1500:])
        else:
            (directory / 'doubles.swift').write_text(DOUBLES)
            # File-private in the app; the driver is another file.
            (directory / 'reader.swift').write_text('import CoreData\nimport Foundation\n\n' + entry.replace('private func ', 'func ', 1)
                                                    + '\n\n' + reader + '\n')
            (directory / 'main.swift').write_text(DRIVER)
            binary = directory / 'rebuild-albums'
            built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-o', str(binary), str(directory / 'doubles.swift'),
                                    str(directory / 'reader.swift'), str(directory / 'main.swift')],
                                   capture_output=True, text=True)
            if built.returncode != 0:
                failures.append('the reader does not compile:\n%s' % built.stderr[-1500:])
            else:
                stores = directory / 'stores'
                stores.mkdir()
                run = subprocess.run([str(binary), str(momd), str(FORMER), str(stores)], capture_output=True, text=True)
                if run.returncode != 0:
                    failures.append('the driver failed: %s' % run.stderr[-800:])
                for line in run.stdout.splitlines():
                    key, _, value = line.partition('\t')
                    results[key] = value
                if 'logged' in results:
                    failures.append('reading the albums logged an exception: %s' % results['logged'])

if results:
    teaching = "Teaching['1.2.3.1/SYNTHETIC^A', '1.2.3.2/SYNTHETIC^B']".replace("'", '"')
    albums_expected = ' '.join(sorted(['Follow-up["1.2.3.1/SYNTHETIC^A"]', 'Interesting Cases[]', teaching,
                                       "Today CT*(modality CONTAINS[cd] 'CT') AND (date >= $NSDATE_TODAY)"]))
    expected = {
        'current.albums': albums_expected,
        'current.written': albums_expected,
        'current.after': results.get('current.before'),
        'current.before': 'Database.sql',
        'current.unchanged': 'true',
        'former.albums': albums_expected,
        'former.after': 'Database.sql',
        'former.unknown': 'nil',
        'corrupt': 'nil',
        'missing': 'nil',
    }
    for key, want in expected.items():
        if results.get(key) != want:
            failures.append('%s: %r, expected %r' % (key, results.get(key), want))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: a rebuild with no context reads the albums from its verified copy of the index, read-only, '
      'and creates the default albums again, saying where the copy is, when it cannot')
