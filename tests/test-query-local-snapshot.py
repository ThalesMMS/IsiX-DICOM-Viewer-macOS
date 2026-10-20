#!/usr/bin/env python3
"""The query window marks local studies from a snapshot read off the main thread.

A study already here showed no mark when the node did not report how many
instances it holds, because only a proportion was drawn. Painting also looked
every row up in the database on the main thread, several times per repaint, and
counted its files by loading every image. Now:

- HorosLocalQueryReader reads the local side of the results once, on its
  private queue: files, State and Comment of each study and series. This runs
  the real reader against a SQLite store and checks the values.
- The cell, tooltip, column and sort paths read only that snapshot or a
  manifest already found, never the database or the disk.
- A study here with an unknown total gets its own mark; a known total keeps
  the pie.
- The footer says how many of the studies found are in the database.
"""
from pathlib import Path
import shutil
import sys

root = Path(__file__).resolve().parents[1]
failures = []


def read(path):
    return (root / path).read_bytes().decode('latin1')


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


query = read('Horos/Sources/QueryController.mm')
node = read('Horos/Sources/DCMTKQueryNode.mm')
pie = read('Horos/Sources/PieChartImage.swift')

painting = {
    'cell': method(query, '- (void)outlineView:(NSOutlineView *)oV willDisplayCell:'),
    'tooltip': method(query, '- (NSString *)outlineView:(NSOutlineView *)ov toolTipForCell:'),
    'value': method(query, '- (id)outlineView:(NSOutlineView *)outlineView objectValueForTableColumn:'),
    'displayed': method(query, '- (HorosLocalCompleteness*) displayedCompletenessForItem:'),
    'state': method(query, '- (HorosLocalRowState*) localStateForItem:'),
    'footer': method(query, '- (void) updateStudyCountLabel'),
}
for name, body in painting.items():
    if not body:
        failures.append('%s: method not found' % name)
        continue
    for forbidden in ('localStudy:', 'localSeries:', 'rawNoFiles', 'localCompletenessForItem:', 'executeFetchRequest',
                      'localStudyObjectIDForItem:', 'retrieveInventory]'):
        if forbidden in body and not (name == 'displayed' and forbidden == 'localCompletenessForItem:'):
            failures.append('%s still reads %s while painting' % (name, forbidden))
displayed = painting['displayed']
if 'isMainThread] == NO' not in displayed.split('localCompletenessForItem:')[0]:
    failures.append('the painted completeness falls back to the database read on the main thread')
if 'retrieveInventoryForDisplay' not in displayed:
    failures.append('painting does not use the display inventory, which remembers a missing manifest')
cell = painting['cell']
if 'localPresenceImage' not in cell or 'remoteCountIsKnown ?' not in cell or 'pieChartImageWithPercentage' not in cell:
    failures.append('the cell does not choose between the pie and the presence mark')
if 'remoteCountIsKnown)' in cell:
    failures.append('the cell still draws nothing when the total is unknown')
if 'countOfStudiesHereAmong:' not in painting['footer'] or '%@, %ld in database' not in painting['footer']:
    failures.append('the footer does not say how many are in the database')
sort = method(query, '- (NSArray*) sortArray')
if 'displayedCompletenessForItem:' not in sort:
    failures.append('the Local sort does not read the snapshot')
read_snapshot = method(query, '- (void) readLocalSnapshot')
if 'dispatch_async' not in read_snapshot or 'snapshotOfStudyInstanceUIDs:' not in read_snapshot \
        or 'generation != localSnapshotGeneration' not in read_snapshot:
    failures.append('the snapshot is not read off the main thread, or an overtaken read is applied')
refresh_list = method(query, '- (void) refreshList:')
if 'scheduleLocalSnapshot' not in refresh_list or 'updateStudyCountLabel' not in refresh_list:
    failures.append('a new result list does not read the snapshot nor update the footer')
if 'readLocalSnapshot' not in method(query, '- (void) executeRefresh:'):
    failures.append('an import does not read a new snapshot')
if 'NSDeletedObjectsKey' not in method(query, '- (void) observeDatabaseSave:'):
    failures.append('deleting studies does not refresh the marks')
if 'OsirixActiveLocalDatabaseDidChangeNotification' not in query:
    failures.append('switching the database does not refresh the marks')
lookup = method(query, '- (NSManagedObjectID*) localStudyObjectIDForItem:')
if 'indexOfObject' in lookup or 'objectForKey:' not in lookup:
    failures.append('the local study lookup still scans every local study')
display_inventory = method(node, '- (HorosRetrieveInventory*)retrieveInventoryForDisplay')
if '_retrieveInventoryMissGeneration' not in display_inventory:
    failures.append('a missing manifest is looked for again on every repaint')
if 'retrieveInventoryMissGeneration++' not in method(node, '+ (void)forgetMissingRetrieveInventories'):
    failures.append('missing manifests are never looked for again')
if '@objc(localPresenceImage)' not in pie:
    failures.append('there is no presence image')

# --- the real reader, run -----------------------------------------------------
sys.path.insert(0, str(Path(__file__).resolve().parent))
import n2_database_harness as harness  # noqa: E402

DRIVER = r'''
let path = CommandLine.arguments[1]
let database = TestDatabase(path: path)!
let main = database.managedObjectContext!
func insert(_ entity: String) -> NSManagedObject { NSEntityDescription.insertNewObject(forEntityName: entity, into: main) }
func study(_ uid: String, series: [(String, Int)], state: String? = nil, comment: String? = nil) {
    let s = insert("Study"); s.setValue(uid, forKey: "studyInstanceUID"); s.setValue(state, forKey: "stateText"); s.setValue(comment, forKey: "comment")
    for (seriesUID, images) in series {
        let one = insert("Series"); one.setValue(seriesUID, forKey: "seriesDICOMUID"); one.setValue(s, forKey: "study")
        one.setValue("series " + seriesUID, forKey: "comment")
        for i in 0..<images { let image = insert("Image"); image.setValue("\(seriesUID).\(i)", forKey: "sopInstanceUID"); image.setValue(one, forKey: "series") }
    }
}
study("1.1", series: [("1.1.1", 3), ("1.1.2", 2)], state: "2", comment: "read")
study("2.2", series: [("2.2.1", 4)])
study("2.2", series: [("2.2.1", 1), ("2.2.9", 2)])   // the same UID twice counts together
study("3.3", series: [])                              // a study without files
study("4.4", series: [("4.4.1", 7)])                  // here, not among the results
emit("saved", database.save() ? "yes" : "no")

func run(_ label: String) {
    do {
        let results = ["1.1", "2.2", "3.3", "5.5", ""] + (0..<1200).map { "9.\($0)" }
        let snapshot = try HorosLocalQueryReader.snapshot(ofStudyInstanceUIDs: results, in: database)
        emit(label + ".study.1", "\(snapshot.state(ofStudy: "1.1")?.fileCount ?? -1)")
        emit(label + ".study.1.state", "\(snapshot.state(ofStudy: "1.1")?.stateText ?? "nil")")
        emit(label + ".study.1.comment", snapshot.state(ofStudy: "1.1")?.comment ?? "nil")
        emit(label + ".series.1.2", "\(snapshot.state(ofStudy: "1.1", series: "1.1.2")?.fileCount ?? -1)")
        emit(label + ".series.1.2.comment", snapshot.state(ofStudy: "1.1", series: "1.1.2")?.comment ?? "nil")
        emit(label + ".study.2", "\(snapshot.state(ofStudy: "2.2")?.fileCount ?? -1)")
        emit(label + ".series.2.1", "\(snapshot.state(ofStudy: "2.2", series: "2.2.1")?.fileCount ?? -1)")
        emit(label + ".study.3", "\(snapshot.state(ofStudy: "3.3")?.fileCount ?? -1)")
        emit(label + ".study.4", snapshot.state(ofStudy: "4.4") == nil ? "absent" : "present")
        emit(label + ".study.5", snapshot.state(ofStudy: "5.5") == nil ? "absent" : "present")
        emit(label + ".here", "\(snapshot.countOfStudiesHere(among: results))")
        let empty = try HorosLocalQueryReader.snapshot(ofStudyInstanceUIDs: [], in: database)
        emit(label + ".empty", "\(empty.countOfStudiesHere(among: ["1.1"]))")
    } catch {
        emit(label + ".error", "\(error)")
    }
}
run("main")
let done = DispatchSemaphore(value: 0)
Thread { run("background"); done.signal() }.start()
emit("background.finished", done.wait(timeout: .now() + 20) == .success ? "yes" : "no")
emit("end", "yes")
'''

EXPECTED = {'saved': 'yes', 'background.finished': 'yes', 'end': 'yes'}
for label in ('main', 'background'):
    EXPECTED.update({
        label + '.study.1': '5', label + '.study.1.state': '2', label + '.study.1.comment': 'read',
        label + '.series.1.2': '2', label + '.series.1.2.comment': 'series 1.1.2',
        label + '.study.2': '7', label + '.series.2.1': '5',
        label + '.study.3': '0', label + '.study.4': 'absent', label + '.study.5': 'absent',
        label + '.here': '2', label + '.empty': '0',
    })

binary, work, error = harness.build(DRIVER, ['Horos/Sources/HorosLocalQueryReader.swift'])
try:
    if error:
        failures.append(error)
    else:
        status, results, stdout, stderr = harness.run(binary, [str(work / 'store' / 'Database.sql')])
        if status != 0:
            failures.append('the reads ended the process (status %d):\n%s' % (status, stderr[-2000:]))
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
print('PASS: the query window paints its local marks and footer from a snapshot read off the main thread')
