#!/usr/bin/env python3
"""The query window's local reads run on a private-queue context.

QueryController and the retrieve paths of DCMTKQueryNode chose the UI context
on the main thread and a new confined context elsewhere, then used the objects
from whichever they got. They now ask HorosLocalQueryReader, which reads on a
context of its own private queue, created by -[N2ManagedDatabase
privateQueueContext], and hands back values and object IDs.

This compiles the real N2ManagedDatabase.mm, HorosObjCException.m and
HorosLocalQueryReader.swift against small stand-ins for the entities and for
what else N2ManagedDatabase.mm imports, fills a SQLite store and reads it
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
    'managed': root / 'Nitrogen/Sources/N2ManagedDatabase.mm',
    'managed_h': root / 'Nitrogen/Sources/N2ManagedDatabase.h',
    'exception': root / 'Horos/Sources/HorosObjCException.m',
    'exception_h': root / 'Horos/Sources/HorosObjCException.h',
    'reader': root / 'Horos/Sources/HorosLocalQueryReader.swift',
}


def read(path):
    return path.read_bytes().decode('latin1')


# --- the consumers read through the reader -----------------------------------
query = read(root / 'Horos/Sources/QueryController.mm')
node = read(root / 'Horos/Sources/DCMTKQueryNode.mm')


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


compute = method(query, '- (void) computeStudyArrayInstanceUID:')
if 'HorosLocalQueryReader studyIndexOfDatabase:' not in compute:
    failures.append('the study index is not read through the private-queue reader')
if 'independentContext' in compute or 'managedObjectContext' in compute:
    failures.append('the study index still picks a context by thread')
count = method(query, '- (NSInteger) localFileCountForItem:')
if 'HorosLocalQueryReader fileCountOfStudy:' not in count:
    failures.append('the local file count is not read through the private-queue reader')
for signature in ('- (void) addStudyIfNotAvailable:', '- (void) autoRetrieveThread:',
                  '-(void) retrieve:(id)sender onlyIfNotAvailable:(BOOL) onlyIfNotAvailable forViewing: (BOOL) forViewing items:'):
    body = method(query, signature)
    if not body:
        failures.append('%s is gone' % signature)
    elif 'independentContext' in body or 'rawNoFiles' in body:
        failures.append('%s still reads objects of a thread-chosen context' % signature)
    elif signature != '- (void) autoRetrieveThread:' and 'localFileCountForItem:' not in body:
        failures.append('%s does not decide on the private-queue count' % signature)
if 'independentContext' in query:
    failures.append('QueryController still creates independent contexts')
for signature in ('- (void) WADORetrieve:', '- (BOOL)refreshRetrieveInventory', '- (void) move:(NSDictionary*) dict retrieveMode:'):
    body = method(node, signature)
    if not body:
        failures.append('DCMTKQueryNode %s is gone' % signature)
    elif 'independentContext' in body or 'executeFetchRequest' in body:
        failures.append('DCMTKQueryNode %s still fetches on a thread-chosen context' % signature)
if node.count('HorosLocalQueryReader SOPInstanceUIDsOfStudyInstanceUID:') < 2:
    failures.append('DCMTKQueryNode does not read the local instances through the reader')

factory = method(read(sources['managed']), '- (N2ManagedObjectContext *)privateQueueContext')
if 'NSPrivateQueueConcurrencyType' not in factory:
    failures.append('the private-queue factory does not create a private-queue context')

# --- the real code, run --------------------------------------------------------
sys.path.insert(0, str(Path(__file__).resolve().parent))
import n2_database_harness as harness  # noqa: E402

DRIVER = r'''
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
        emit(label + ".sop.study", "\(try HorosLocalQueryReader.sopInstanceUIDs(ofStudyInstanceUID: "1.2.3", seriesInstanceUID: nil, in: database).sorted())")
        emit(label + ".sop.series", "\(try HorosLocalQueryReader.sopInstanceUIDs(ofStudyInstanceUID: "1.2.3", seriesInstanceUID: "1.2.3.0", in: database).sorted())")
        emit(label + ".sop.emptyseries", "\(try HorosLocalQueryReader.sopInstanceUIDs(ofStudyInstanceUID: "1.2.3", seriesInstanceUID: "", in: database).count)")
        emit(label + ".sop.none", "\(try HorosLocalQueryReader.sopInstanceUIDs(ofStudyInstanceUID: "4.5", seriesInstanceUID: nil, in: database).count)")
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
    })

missing = [name for name, path in sources.items() if not path.exists()]
if missing:
    failures.append('missing sources: %s' % ', '.join(missing))
else:
    binary, work, error = harness.build(DRIVER, ['Horos/Sources/HorosLocalQueryReader.swift'])
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
print('ok: the study index, file counts and local instances are read on a private queue, from any thread')
