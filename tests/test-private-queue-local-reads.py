#!/usr/bin/env python3
"""The query window's local reads run on a private-queue context.

QueryController and the retrieve paths of DCMTKQueryNode chose the UI context
on the main thread and a new confined context elsewhere, then used the objects
from whichever they got. They now ask HorosLocalQueryReader, which reads on a
context of its own private queue, created by -[N2ManagedDatabase
privateQueueContext], and hands back values and object IDs.

This compiles the real N2ManagedDatabase, HorosObjCException.m and
HorosLocalQueryReader.swift against small stand-ins for the entities and for
what else N2ManagedDatabase uses, fills a SQLite store and reads it
back from the main thread and from a background thread, with Core Data's
multithreading assertions on: an access outside the context's queue ends the
process. A background read while the main thread waits for it shows that the
read never needs the main thread. A database without a store, and a Core Data
exception inside a read, come back as errors.
"""
from pathlib import Path
import shutil
import sys

root = Path(__file__).resolve().parents[1]
failures = []

sources = {
    'managed': root / 'Nitrogen/Sources/N2ManagedDatabase.swift',
    'managed_h': root / 'Nitrogen/Sources/N2ManagedDatabase.h',
    'exception': root / 'Horos/Sources/HorosObjCException.m',
    'exception_h': root / 'Horos/Sources/HorosObjCException.h',
    'reader': root / 'Horos/Sources/HorosLocalQueryReader.swift',
}


def read(path):
    return path.read_bytes().decode('latin1')


# --- the consumers read through the reader -----------------------------------
# The query node and the Query window are Swift, split by responsibility into
# DCMTKQueryNode+*.swift and QueryController+*.swift.
sys.path.insert(0, str(root / 'tests'))
from sources import class_text  # noqa: E402
query = class_text('QueryController')
node = class_text('DCMTKQueryNode')


def method(text, signature):
    at = text.find(signature)
    if at < 0:
        return ''
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[opening:index + 1]
    return ''


compute = method(query, 'nonisolated func computeStudyArrayInstanceUID(')
if 'HorosLocalQueryReader.studyIndex(of: database)' not in compute:
    failures.append('the study index is not read through the private-queue reader')
if 'independentContext' in compute or 'managedObjectContext' in compute:
    failures.append('the study index still picks a context by thread')
count = method(query, 'nonisolated func localFileCount(forItem item: Any?) -> Int')
series_adapter = (root / 'Horos/Sources/LocalDatabaseStudyReader+Series.swift').read_text(encoding='utf-8')
if 'localSeries.fileCount(ofStudy:' not in count or 'HorosLocalQueryReader.fileCount(ofStudyAt:' not in series_adapter:
    failures.append('the local file count is not read through LocalSeriesReading and the private-queue reader')
for signature in ('func retrieve(_ sender: Any?, onlyIfNotAvailable: Bool, forViewing: Bool, items: [Any]!, showGUI: Bool)',):
    body = method(query, signature)
    if not body:
        failures.append('%s is gone' % signature)
    elif 'independentContext' in body or 'rawNoFiles' in body:
        failures.append('%s still reads objects of a thread-chosen context' % signature)
    elif 'localFileCount(forItem:' not in body:
        failures.append('%s does not decide on the private-queue count' % signature)
# The automatic retrieve decides in IsiXDICOMNetwork on what LocalStudyReading
# reports, which the app reads through the reader.
adapter = (root / 'Horos/Sources/LocalDatabaseStudyReader.swift').read_text(encoding='utf-8')
ports = (root / 'Horos/Sources/QueryWindowAutoQueryPorts.swift').read_text(encoding='utf-8')
if 'HorosLocalQueryReader.studySnapshots(ofStudyInstanceUIDs:' not in adapter:
    failures.append('the automatic retrieve does not count the local files through the private-queue reader')
# The process graph makes the reader, over the active local database.
graph_source = (root / 'Horos/Sources/ProcessGraph.swift').read_text(encoding='utf-8')
if 'localStudyReader(reading: .activeLocal)' not in query or 'LocalDatabaseStudyReader {' not in graph_source:
    failures.append('the automatic query does not read what is here through LocalDatabaseStudyReader')
if 'independentContext' in ports + adapter or 'rawNoFiles' in ports + adapter:
    failures.append('the automatic retrieve still reads objects of a thread-chosen context')
snapshots = method(read(sources['reader']), 'static func studySnapshots(')
if 'database.performPrivateRead' not in snapshots:
    failures.append('the study snapshots are not read on the private-queue context')
if 'independentContext' in query:
    failures.append('QueryController still creates independent contexts')
for signature in ('func wadoRetrieve(study: DCMTKQueryNode?, listing:', 'func refreshRetrieveInventory() -> Bool',
                  'func move(_ dictionary: [AnyHashable: Any]!, retrieveMode: Int32)', 'func localSOPInstanceUIDs(ofStudy'):
    body = method(node, signature)
    if not body:
        failures.append('DCMTKQueryNode %s is gone' % signature)
    elif 'independentContext' in body or 'executeFetchRequest' in body or '.fetch(' in body:
        failures.append('DCMTKQueryNode %s still fetches on a thread-chosen context' % signature)
# The node reads what is here through LocalSeriesReading: the inventory's
# refresh, and the instances an IMAGE level retrieve leaves out.
if 'inventory.refreshImported(from: Self.localSeries)' not in method(node, 'func refreshRetrieveInventory() -> Bool') \
        or 'Self.localSeries.sopInstanceUIDs(ofStudyInstanceUID:' not in method(node, 'func localSOPInstanceUIDs(ofStudy') \
        or 'HorosLocalQueryReader.seriesSnapshots(ofStudyInstanceUID:' not in series_adapter:
    failures.append('DCMTKQueryNode does not read the local instances through LocalSeriesReading and the reader')
if 'database.performPrivateRead' not in method(read(sources['reader']), 'static func seriesSnapshots('):
    failures.append('the series snapshots are not read on the private-queue context')

factory = method(read(sources['managed']), 'func privateQueueContext() -> N2ManagedObjectContext!')
if 'queue: .privateQueue' not in factory:
    failures.append('the private-queue factory does not create a private-queue context')

# --- the real code, run --------------------------------------------------------
sys.path.insert(0, str(Path(__file__).resolve().parent))
import n2_database_harness as harness  # noqa: E402

DRIVER = r'''
import IsiXContracts
let path = CommandLine.arguments[1]
let database = TestDatabase(path: path)!
let main = database.managedObjectContext!
func insert(_ entity: String) -> NSManagedObject { NSEntityDescription.insertNewObject(forEntityName: entity, into: main) }
let first = insert("Study"); first.setValue("1.2.3", forKey: "studyInstanceUID")
for s in 0..<2 {
    let series = insert("Series"); series.setValue("1.2.3.\(s)", forKey: "seriesDICOMUID"); series.setValue(first, forKey: "study")
    for i in 0..<3 { let image = insert("Image"); image.setValue("1.2.3.\(s).\(i)", forKey: "sopInstanceUID"); image.setValue(series, forKey: "series") }
}
let second = insert("Study")
let gone = insert("Study"); gone.setValue("9.9", forKey: "studyInstanceUID")
emit("saved", database.save() ? "yes" : "no")
let firstID = first.objectID, goneID = gone.objectID
main.delete(gone); _ = database.save()

func run(_ label: String) {
    do {
        let index = try HorosLocalQueryReader.studyIndex(of: database)
        emit(label + ".index.count", "\(index.objectIDs.count)")
        emit(label + ".index.uids", index.studyInstanceUIDs.map { ($0 as? String) ?? "<null>" }.sorted().joined(separator: ","))
        emit(label + ".index.first", index.objectIDs.contains(firstID) ? "yes" : "no")
        emit(label + ".count.study", "\(try HorosLocalQueryReader.fileCount(ofStudy: firstID, seriesInstanceUID: nil, in: database))")
        emit(label + ".count.series", "\(try HorosLocalQueryReader.fileCount(ofStudy: firstID, seriesInstanceUID: "1.2.3.1", in: database))")
        emit(label + ".count.noseries", "\(try HorosLocalQueryReader.fileCount(ofStudy: firstID, seriesInstanceUID: "7", in: database))")
        emit(label + ".count.gone", "\(try HorosLocalQueryReader.fileCount(ofStudy: goneID, seriesInstanceUID: nil, in: database))")
        // What LocalSeriesReading answers, through the app's adapter.
        let series = LocalDatabaseStudyReader { database }
        emit(label + ".sop.study", "\(try series.sopInstanceUIDs(ofStudyInstanceUID: "1.2.3", seriesInstanceUID: nil).sorted())")
        emit(label + ".sop.series", "\(try series.sopInstanceUIDs(ofStudyInstanceUID: "1.2.3", seriesInstanceUID: "1.2.3.0").sorted())")
        emit(label + ".sop.emptyseries", "\(try series.sopInstanceUIDs(ofStudyInstanceUID: "1.2.3", seriesInstanceUID: "").count)")
        emit(label + ".sop.none", "\(try series.sopInstanceUIDs(ofStudyInstanceUID: "4.5", seriesInstanceUID: nil).count)")
        emit(label + ".port.count.study", "\(try series.fileCount(ofStudy: LocalRecordIdentifier(uri: firstID.uriRepresentation()), seriesInstanceUID: nil))")
        emit(label + ".port.count.series", "\(try series.fileCount(ofStudy: LocalRecordIdentifier(uri: firstID.uriRepresentation()), seriesInstanceUID: "1.2.3.1"))")
        emit(label + ".port.count.gone", "\(try series.fileCount(ofStudy: LocalRecordIdentifier(uri: goneID.uriRepresentation()), seriesInstanceUID: nil))")
        // What LocalStudyReading answers: the studies here among those UIDs,
        // with their files and the URI of their object ID.
        let snapshots = try HorosLocalQueryReader.studySnapshots(ofStudyInstanceUIDs: ["1.2.3", "9.9", "4.5", ""], in: database)
        emit(label + ".snapshots", snapshots.map { "\($0.studyInstanceUID)=\($0.fileCount)" }.joined(separator: ","))
        emit(label + ".snapshot.record", snapshots.first?.identifier.uri == firstID.uriRepresentation() ? "yes" : "no")
    } catch {
        emit(label + ".error", "\(error)")
    }
}

run("main")
// The main thread waits here without running its run loop: a read that needed
// the main thread would never finish.
let done = DispatchSemaphore(value: 0)
Thread { run("background"); done.signal() }.start()
emit("background.finished", done.wait(timeout: .now() + 20) == .success ? "yes" : "no")

// The read context is kept, but each read sees what is committed at that time.
let third = insert("Study"); third.setValue("7.7", forKey: "studyInstanceUID"); _ = database.save()
emit("later.index.count", "\((try? HorosLocalQueryReader.studyIndex(of: database).objectIDs.count) ?? -1)")
// A database given a new coordinator (a rebuild does that) reads the new store.
database.managedObjectContext = database.context(atPath: path + "-rebuilt.sql")
emit("rebuilt.index.count", "\((try? HorosLocalQueryReader.studyIndex(of: database).objectIDs.count) ?? -1)")

// No store: an error, not a crash.
let bare = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
let storeless = TestDatabase(path: path + "-none", context: bare)!
do { _ = try HorosLocalQueryReader.studyIndex(of: storeless); emit("storeless", "read") }
catch { emit("storeless", (error as NSError).domain) }

// A Core Data exception inside the read: an error, not a crash.
do {
    _ = try database.performPrivateRead { context in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Nope")) }
    emit("exception", "read")
} catch { emit("exception", (error as NSError).domain) }
emit("after.exception", "\((try? HorosLocalQueryReader.studyIndex(of: database).objectIDs.count) ?? -1)")
emit("end", "yes")
'''

EXPECTED = {
    'saved': 'yes',
    'background.finished': 'yes',
    'storeless': 'HorosPrivateQueueRead',
    'exception': 'HorosObjCExceptionErrorDomain',
    'later.index.count': '3',
    'rebuilt.index.count': '0',
    'after.exception': '0',
    'end': 'yes',
}
for label in ('main', 'background'):
    EXPECTED.update({
        label + '.index.count': '2',
        label + '.index.uids': '1.2.3,<null>',
        label + '.index.first': 'yes',
        label + '.count.study': '6',
        label + '.count.series': '3',
        label + '.count.noseries': '0',
        label + '.count.gone': '0',
        label + '.sop.study': str(['1.2.3.%d.%d' % (s, i) for s in range(2) for i in range(3)]).replace("'", '"'),
        label + '.sop.series': str(['1.2.3.0.%d' % i for i in range(3)]).replace("'", '"'),
        label + '.sop.emptyseries': '6',
        label + '.sop.none': '0',
        label + '.port.count.study': '6',
        label + '.port.count.series': '3',
        label + '.port.count.gone': '0',
        label + '.snapshots': '1.2.3=6',
        label + '.snapshot.record': 'yes',
    })

missing = [name for name, path in sources.items() if not path.exists()]
if missing:
    failures.append('missing sources: %s' % ', '.join(missing))
else:
    binary, work, error = harness.build(DRIVER, ['Horos/Sources/HorosLocalQueryReader.swift',
                                                 'Horos/Sources/LocalDatabaseStudyReader.swift',
                                                 'Horos/Sources/LocalDatabaseStudyReader+Series.swift'])
    try:
        if error:
            failures.append(error)
        else:
            status, results, stdout, stderr = harness.run(binary, [str(work / 'store' / 'Database.sql')])
            if status != 0:
                failures.append('the reads ended the process (status %d), last output %r:\n%s'
                                % (status, stdout.splitlines()[-1:] or '', stderr[-2000:]))
            for key, value in EXPECTED.items():
                if results.get(key) != value:
                    failures.append('%s: expected %r, got %r' % (key, value, results.get(key)))
    finally:
        shutil.rmtree(work, ignore_errors=True)

if failures:
    print('FAIL')
    for failure in failures:
        print(' -', failure)
    sys.exit(1)
print('ok: the study index, file counts and local instances are read on a private queue, from any thread, and through LocalSeriesReading')
