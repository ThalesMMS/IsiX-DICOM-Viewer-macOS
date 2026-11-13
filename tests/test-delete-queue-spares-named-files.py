#!/usr/bin/env python3
"""The delete queue leaves on the disk a file that a record of the index still names.

A record that leaves the index queues its file, and the queue unlinked whatever
it held. Several records can name one file: the frames of a multiframe file, the
series of a file that is not DICOM, and, in an index where an import was once
given the number of a file that was gone, a record of another image, of another
study. Deleting the old study there deleted the file of the new one, whose
images were lost without a word.

The queue now asks the index, once for each batch and after the save that took
the records out, which of its files records still name, and those stay.

- queue: DatabaseDeleteQueue.swift, compiled as it is with IsiXDatabase, over a
  SQLite store of the application's data model (compiled with momc) and files
  of its own. A batch deletes what no record names and leaves what one does: by
  number, by name in the data folder, by path outside it. The file goes once
  its last record has. A batch of three thousand files asks the store once for
  the numbers and once for the other names. With no database open for the
  folder the queue deletes as it did.
- text: an image queues its file after the save of the deletion went well, so
  the index the queue asks no longer has its record.

`<git revision>` as an optional argument reads the queue from that revision,
the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from isix_modules import module_flags  # noqa: E402

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
QUEUE = 'Horos/Sources/DatabaseDeleteQueue.swift'
IMAGE = 'Horos/Sources/DicomImage.swift'
MODEL = root / 'Horos/Models/OsiriXDB_DataModel.xcdatamodeld'


def source(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode()
    return (root / path).read_text(encoding='utf-8')


def fail(message):
    print('FAIL:', message)
    sys.exit(1)


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, momc)', file=sys.stderr)
    sys.exit(SKIPPED)

DOUBLES = r'''
import CoreData
import Foundation

// What DatabaseDeleteQueue.swift reaches in the application.
enum ActivityThread {
    static func startListed(name: String, configure: (Thread) -> Void, _ body: @escaping @Sendable () -> Void) {}
}
enum BrowserObjC {
    static func singularPlural(_ count: Int, _ singular: String, _ plural: String) -> String { return "\(count) \(count == 1 ? singular : plural)" }
}
extension Thread {
    var status: String? { get { return nil } set {} }
    var progress: CGFloat { get { return 0 } set {} }
}

/// The databases that are open, by their folders.
final class DicomDatabase {
    nonisolated(unsafe) static var open: [String: DicomDatabase] = [:]
    static func existingDatabase(atPath path: String!) -> DicomDatabase! { return open[path] }
    let folder: String
    var managedObjectContext: NSManagedObjectContext?
    init(folder: String) { self.folder = folder }
    func dataDirPath() -> String! { return (folder as NSString).appendingPathComponent("DATABASE.noindex") }
}
'''

DRIVER = r'''
import CoreData
import Foundation

var failures: [String] = []
@MainActor func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }

let files = FileManager.default
let base = CommandLine.arguments[1]
let model = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))!.copy() as! NSManagedObjectModel
// The classes of the application are not here: the records are plain managed objects.
for entity in model.entities { entity.managedObjectClassName = "NSManagedObject" }
let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
_ = try! coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                        at: URL(fileURLWithPath: (base as NSString).appendingPathComponent("Database.sql")), options: nil)
let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
context.persistentStoreCoordinator = coordinator
let database = DicomDatabase(folder: base)
database.managedObjectContext = context
DicomDatabase.open[base] = database
let data = database.dataDirPath()! as NSString
let outside = (base as NSString).appendingPathComponent("elsewhere") as NSString

@MainActor func numbered(_ number: Int) -> String { return data.appendingPathComponent("10000/\(number).dcm") }
@MainActor func write(_ path: String) {
    try! files.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    files.createFile(atPath: path, contents: Data("synthetic".utf8))
}

/// A record of an image, naming its file by a number or by a string.
@discardableResult
@MainActor func record(number: Int? = nil, string: String? = nil) -> NSManagedObject {
    return try! context.performAndWait { () throws -> NSManagedObject in
        let made = NSEntityDescription.insertNewObject(forEntityName: "Image", into: context)
        if let number { made.setValue(NSNumber(value: number), forKey: "pathNumber") }
        if let string { made.setValue(string, forKey: "pathString") }
        try context.save()
        return made
    }
}

/// As the application does: the record leaves the index, the save goes well, and then its file is queued.
@MainActor func delete(_ records: [NSManagedObject], queueing paths: [String], in queue: DatabaseDeleteQueue) {
    try! context.performAndWait { () throws -> Void in
        records.forEach(context.delete)
        try context.save()
    }
    paths.forEach(queue.add)
}

let queue = DatabaseDeleteQueue()
nonisolated(unsafe) var reported: [String] = []
@MainActor func run(_ folder: String? = base) { queue.deleteQueued(in: folder) { failures in reported += failures.map(\.path) } }

// Number 5 is named by the record of an old image, whose own file is gone, and by
// the record of the image the file is of. 6 has one record. 7 is a multiframe
// file of three frames. 8.tif holds two series. Two files are linked from outside.
let old = record(number: 5), new = record(number: 5), alone = record(number: 6)
let frames = [record(number: 7), record(number: 7), record(number: 7)]
let seriesOne = record(string: "8.tif"), seriesTwo = record(string: "8.tif")
let linked = outside.appendingPathComponent("linked.dcm"), free = outside.appendingPathComponent("free.dcm")
let linkedOne = record(string: linked), linkedTwo = record(string: linked), freeOne = record(string: free)
let tif = data.appendingPathComponent("10000/8.tif")
([5, 6, 7].map(numbered) + [tif, linked, free]).forEach(write)

delete([old, alone, frames[0], seriesOne, linkedOne, freeOne], queueing: [numbered(5), numbered(6), numbered(7), tif, linked, free], in: queue)
run()
check(files.fileExists(atPath: numbered(5)), "the file of an image was deleted with the record of another image that named it")
check(!files.fileExists(atPath: numbered(6)), "a file no record names any more stayed on the disk")
check(files.fileExists(atPath: numbered(7)), "a multiframe file was deleted while records of its other frames stay")
check(files.fileExists(atPath: tif), "a file of two series, named by its name, was deleted while the record of the other series stays")
check(files.fileExists(atPath: linked), "a file outside the database was deleted while another record names it")
check(!files.fileExists(atPath: free), "a file outside the database that no record names any more stayed on the disk")
check(queue.count == 0, "the files that stay were left in the queue")

// Each file goes once its last record has.
delete([new, frames[1], frames[2], seriesTwo, linkedTwo], queueing: [numbered(5), numbered(7), numbered(7), tif, linked], in: queue)
run()
for path in [numbered(5), numbered(7), tif, linked] {
    check(!files.fileExists(atPath: path), "\((path as NSString).lastPathComponent) stayed on the disk once no record named it")
}

// A batch of three thousand files, a few of which records still name.
let many = (1000..<4000).map(numbered) + (0..<300).map { data.appendingPathComponent("10000/\($0).jpg") }
many.forEach(write)
let kept = [1000, 2500, 3999]
kept.forEach { record(number: $0) }
record(string: "150.jpg")
many.forEach(queue.add)
FileHandle.standardError.write(Data("BATCH BEGINS\n".utf8))
run()
FileHandle.standardError.write(Data("BATCH ENDS\n".utf8))
let left = many.filter { files.fileExists(atPath: $0) }.map { ($0 as NSString).lastPathComponent }.sorted()
check(left == ["1000.dcm", "150.jpg", "2500.dcm", "3999.dcm"], "of a batch of 3300 files, those left on the disk are \(left.count): \(left.prefix(8))")

// No database is open for the folder: the queue deletes as it did.
DicomDatabase.open = [:]
record(number: 9)
write(numbered(9))
queue.add(numbered(9))
run()
check(!files.fileExists(atPath: numbered(9)), "with no index to ask, the queue kept its files")
check(reported.isEmpty, "the queue reported files it could not delete: \(reported)")

for failure in failures { print("FAIL: \(failure)") }
exit(failures.isEmpty ? 0 : 1)
'''

with tempfile.TemporaryDirectory(prefix='horos-delete-queue-named-') as tmp:
    tmp = Path(tmp)
    compiled = subprocess.run(['xcrun', 'momc', str(MODEL), str(tmp)], capture_output=True, text=True)
    momd = tmp / 'OsiriXDB_DataModel.momd'
    if compiled.returncode != 0 or not momd.exists():
        fail('the data model does not compile with momc: ' + compiled.stderr[-1500:])
    (tmp / 'DatabaseDeleteQueue.swift').write_text(source(QUEUE))
    (tmp / 'doubles.swift').write_text(DOUBLES)
    (tmp / 'main.swift').write_text(DRIVER)
    flags = module_flags('IsiXDatabase', tmp / 'modules', ['-target', 'arm64-apple-macos15.0'])
    built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-swift-version', '6', '-target', 'arm64-apple-macos15.0', *flags,
                            str(tmp / 'DatabaseDeleteQueue.swift'), str(tmp / 'doubles.swift'), str(tmp / 'main.swift'), '-o', str(tmp / 'queue')],
                           capture_output=True, text=True, timeout=600)
    if built.returncode != 0:
        fail('the queue does not build: ' + built.stderr[-3000:])
    folder = tmp / 'database'
    folder.mkdir()
    # Core Data writes each statement it sends to the store on stderr.
    ran = subprocess.run([str(tmp / 'queue'), str(folder), str(momd), '-com.apple.CoreData.SQLDebug', '1'], capture_output=True, text=True, timeout=300)
    if ran.returncode != 0:
        fail('; '.join(line[len('FAIL: '):] for line in ran.stdout.splitlines() if line.startswith('FAIL:'))
             or f'exit {ran.returncode}: {(ran.stdout + ran.stderr)[-1500:]}')
    if not revision:
        batch = ran.stderr[ran.stderr.index('BATCH BEGINS'):ran.stderr.index('BATCH ENDS')]
        asked = [line for line in batch.splitlines() if 'SELECT' in line and 'ZIMAGE' in line]
        if len(asked) != 2 or sum('ZPATHNUMBER' in line for line in asked) != 1 or sum('ZPATHSTRING' in line for line in asked) != 1:
            fail('a batch of 3300 files asked the store %d times, not once for the numbers and once for the other names: %s'
                 % (len(asked), [line[-160:] for line in asked[:4]]))
print('ok: queue - a batch deletes what no record of the index names and leaves what one still names, asking the store once for each kind of name')

# ---------------------------------------------------------------- text

image = '\n'.join(line for line in source(IMAGE).splitlines() if not line.strip().startswith('//'))
start = image.find('    public override func validateForDelete() throws {')
if start < 0:
    fail('validateForDelete not found in ' + IMAGE)
deleting = image[start:image.index('\n    }\n', start)]
queued = deleting.find('queueForDeletion(path)')
after_save = deleting.find('context.perform(afterSuccessfulSave: {')
if queued < 0 or after_save < 0 or after_save > queued:
    fail('an image no longer queues its file after the save of its deletion went well: the index the queue asks could still have its record')
if deleting.count('queueForDeletion(') != 2:
    fail('an image queues its file somewhere else than after the save')
print('ok: text - an image queues its file once the save that took its record out went well')
print('PASS: the delete queue leaves on the disk a file that a record of the index still names')
