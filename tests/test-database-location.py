#!/usr/bin/env python3
"""A database that moved is opened, not shadowed by an empty one beside it.

Measured before the change on the development build, a database of one study and
three images copied into a folder called "Moved Backup" and opened four ways:

  - the folder holding `Horos Data`         -> the study, 3 images
  - `Horos Data` itself                     -> the study, 3 images
  - `Horos Data/Database.sql`               -> the study, 3 images
  - the same folder renamed `Renamed Data`  -> **an empty database created at
    `Renamed Data/Horos Data/Database.sql`**, the real one beside it ignored
  - `Renamed Data/Database.sql`             -> `NSGenericException (in
    +[AppController initialize]): Cannot create directory: an existing file
    occupies ...` before the application finished starting

A backup is usually renamed to say what it is, so those last two are the ordinary
cases, not the exotic ones.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
failures = []
location = root / 'Horos/Sources/DatabaseLocation.swift'
database = (root / 'Horos/Sources/DicomDatabase.mm').read_bytes().decode('latin1')

DRIVER = '''
import Foundation

func emit(_ key: String, _ value: String) { print("\\(key)\\t\\(value)") }

let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("horos-location-" + UUID().uuidString)
let manager = FileManager.default

func directory(_ path: URL) -> URL {
    try? manager.createDirectory(at: path, withIntermediateDirectories: true)
    return path
}
func index(in path: URL) {
    manager.createFile(atPath: path.appendingPathComponent("Database.sql").path, contents: Data("x".utf8))
}

// A database where it was made: <holder>/Horos Data/Database.sql
let holder = directory(root.appendingPathComponent("Moved Backup"))
let data = directory(holder.appendingPathComponent("Horos Data"))
index(in: data)

// The same database in a folder that was renamed.
let renamedHolder = directory(root.appendingPathComponent("Other Backup"))
let renamed = directory(renamedHolder.appendingPathComponent("Renamed Data"))
index(in: renamed)

// And a folder with nothing in it, where a new database should go.
let empty = directory(root.appendingPathComponent("Empty"))

// A database made under the current name: <holder>/IsiX Data.
let currentHolder = directory(root.appendingPathComponent("Current"))
let current = directory(currentHolder.appendingPathComponent("IsiX Data"))
index(in: current)

// A database made under the name new databases had just before:
// <holder>/IsiX DICOM Viewer Data. It is opened where it is.
let previousHolder = directory(root.appendingPathComponent("Previous"))
let previous = directory(previousHolder.appendingPathComponent("IsiX DICOM Viewer Data"))
index(in: previous)
// That one beside a Horos database, and nothing else: the newer is opened.
let olderPairHolder = directory(root.appendingPathComponent("Older Pair"))
index(in: directory(olderPairHolder.appendingPathComponent("IsiX DICOM Viewer Data")))
index(in: directory(olderPairHolder.appendingPathComponent("Horos Data")))

// A database made under the previous name: <holder>/Isis DICOM Viewer Data.
// It is opened where it is; nothing beside it is created.
let isisHolder = directory(root.appendingPathComponent("Isis Install"))
let isis = directory(isisHolder.appendingPathComponent("Isis DICOM Viewer Data"))
index(in: isis)

// Both directories in one folder. The one with an index is the database...
let mixedHolder = directory(root.appendingPathComponent("Mixed"))
_ = directory(mixedHolder.appendingPathComponent("IsiX Data"))
index(in: directory(mixedHolder.appendingPathComponent("Horos Data")))
// ...and with an index in each, the current name is the one opened.
let twoHolder = directory(root.appendingPathComponent("Two"))
index(in: directory(twoHolder.appendingPathComponent("IsiX Data")))
index(in: directory(twoHolder.appendingPathComponent("Horos Data")))
// An empty current-name directory beside an Isis database with an index.
let newerEmptyHolder = directory(root.appendingPathComponent("Newer Empty"))
_ = directory(newerEmptyHolder.appendingPathComponent("IsiX Data"))
index(in: directory(newerEmptyHolder.appendingPathComponent("Isis DICOM Viewer Data")))
// Both earlier names, each with an index: the newer one is opened.
let earlierHolder = directory(root.appendingPathComponent("Earlier"))
index(in: directory(earlierHolder.appendingPathComponent("Isis DICOM Viewer Data")))
index(in: directory(earlierHolder.appendingPathComponent("Horos Data")))

func resolve(_ path: String?) -> String {
    return (DatabaseLocation.baseDirectory(forPath: path) ?? "nil")
        .replacingOccurrences(of: root.path + "/", with: "")
}

emit("holder", resolve(holder.path))
emit("data", resolve(data.path))
emit("index", resolve(data.appendingPathComponent("Database.sql").path))
emit("below", resolve(data.appendingPathComponent("DATABASE.noindex/1/2.dcm").path))
emit("renamed", resolve(renamed.path))
emit("renamed-index", resolve(renamed.appendingPathComponent("Database.sql").path))
emit("empty", resolve(empty.path))
emit("current", resolve(currentHolder.path))
emit("current-data", resolve(current.path))
emit("current-index", resolve(current.appendingPathComponent("Database.sql").path))
emit("isis", resolve(isisHolder.path))
emit("isis-data", resolve(isis.path))
emit("isis-index", resolve(isis.appendingPathComponent("Database.sql").path))
emit("previous", resolve(previousHolder.path))
emit("previous-data", resolve(previous.path))
emit("previous-index", resolve(previous.appendingPathComponent("Database.sql").path))
emit("older-pair", resolve(olderPairHolder.path))
// Resolving only reads: no directory under the new name appears beside them.
let created = [isisHolder, previousHolder, olderPairHolder, holder].filter {
    manager.fileExists(atPath: $0.appendingPathComponent(DatabaseLocation.dataDirectoryName).path)
}
emit("created-beside", created.isEmpty ? "none" : created.map { $0.lastPathComponent }.joined(separator: ","))
emit("isis-holds", DatabaseLocation.pathHoldsExistingDatabase(DatabaseLocation.baseDirectory(forPath: isisHolder.path)) ? "yes" : "no")
emit("newer-empty", resolve(newerEmptyHolder.path))
emit("earlier", resolve(earlierHolder.path))
emit("mixed", resolve(mixedHolder.path))
emit("two", resolve(twoHolder.path))
emit("names", "\(DatabaseLocation.isDataDirectoryName("Horos Data")) \(DatabaseLocation.isDataDirectoryName("Isis DICOM Viewer Data")) \(DatabaseLocation.isDataDirectoryName("IsiX DICOM Viewer Data")) \(DatabaseLocation.isDataDirectoryName("IsiX Data")) \(DatabaseLocation.isDataDirectoryName("Data")) \(DatabaseLocation.isDataDirectoryName(nil))")
emit("absent", resolve(root.appendingPathComponent("Nowhere").path))

emit("holds-data", DatabaseLocation.pathHoldsExistingDatabase(data.path) ? "yes" : "no")
emit("holds-renamed", DatabaseLocation.pathHoldsExistingDatabase(renamed.path) ? "yes" : "no")
emit("holds-empty", DatabaseLocation.pathHoldsExistingDatabase(empty.path) ? "yes" : "no")
// A location whose volume is not mounted arrives here as nil, and has to leave
// as nil: the caller has its own answer for that and must not be handed a path
// under the root of the boot volume instead.
emit("nil-in", resolve(nil))
emit("holds-nil", DatabaseLocation.pathHoldsExistingDatabase(nil) ? "yes" : "no")

try? manager.removeItem(at: root)
'''

results = {}
if not location.exists():
    failures.append('there is no database location resolver')
else:
    swiftc = subprocess.run(['xcrun', '--sdk', 'macosx', '-f', 'swiftc'], capture_output=True, text=True)
    if swiftc.returncode != 0:
        failures.append('no swiftc here: %s' % (swiftc.stderr or '').strip())
    else:
        with tempfile.TemporaryDirectory(prefix='horos-location-') as directory:
            # Top-level statements are only allowed in a file called main.swift.
            (Path(directory) / 'main.swift').write_text(DRIVER)
            binary = Path(directory) / 'location'
            built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-o', str(binary),
                                    str(location), str(Path(directory) / 'main.swift')],
                                   capture_output=True, text=True)
            if built.returncode != 0:
                failures.append('the location resolver does not compile:\n%s' % built.stderr[-1500:])
            else:
                run = subprocess.run([str(binary)], capture_output=True, text=True)
                if run.returncode != 0:
                    failures.append('the driver failed: %s' % run.stderr[-800:])
                for line in run.stdout.splitlines():
                    key, _, value = line.partition('\t')
                    results[key] = value

if results:
    expected = {
        # unchanged
        'holder': 'Moved Backup/Horos Data',
        'data': 'Moved Backup/Horos Data',
        'index': 'Moved Backup/Horos Data',
        'below': 'Moved Backup/Horos Data',
        # a new database gets the current name; one made before keeps its own
        'empty': 'Empty/IsiX Data',
        'absent': 'Nowhere/IsiX Data',
        'current': 'Current/IsiX Data',
        'current-data': 'Current/IsiX Data',
        'current-index': 'Current/IsiX Data',
        'previous': 'Previous/IsiX DICOM Viewer Data',
        'previous-data': 'Previous/IsiX DICOM Viewer Data',
        'previous-index': 'Previous/IsiX DICOM Viewer Data',
        'older-pair': 'Older Pair/IsiX DICOM Viewer Data',
        'created-beside': 'none',
        'isis': 'Isis Install/Isis DICOM Viewer Data',
        'isis-data': 'Isis Install/Isis DICOM Viewer Data',
        'isis-index': 'Isis Install/Isis DICOM Viewer Data',
        'isis-holds': 'yes',
        'newer-empty': 'Newer Empty/Isis DICOM Viewer Data',
        'earlier': 'Earlier/Isis DICOM Viewer Data',
        'mixed': 'Mixed/Horos Data',
        'two': 'Two/IsiX Data',
        'names': 'true true true true false false',
        # the two that used to build an empty database, or throw
        'renamed': 'Other Backup/Renamed Data',
        'renamed-index': 'Other Backup/Renamed Data',
        'nil-in': 'nil', 'holds-nil': 'no',
        'holds-data': 'yes',
        'holds-renamed': 'yes',
        'holds-empty': 'no',
    }
    for key, want in expected.items():
        got = results.get(key)
        if got != want:
            failures.append('%s: %r, expected %r' % (key, got, want))

# --- and the database has to ask it, rather than keeping its own rule ---------
if 'HorosDatabaseLocation' not in database:
    failures.append('DicomDatabase still resolves the path itself, so the two answers can differ')

# --- the folder chosen is not always the one used: say which, and which event -
at = database.find('+(NSString*)baseDirPathForMode:')
window = database[at:at + 2600] if at >= 0 else ''
if 'database location:' not in window:
    failures.append('nothing says which directory was opened, so a database created beside the '
                    'one that was meant looks identical to one that was reopened')
if 'pathHoldsExistingDatabase' not in window:
    failures.append('opening an existing database and creating a new one are reported the same')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: a renamed database folder and the index inside it both resolve to the database that '
      'is there, and an empty folder still gets a new one')
