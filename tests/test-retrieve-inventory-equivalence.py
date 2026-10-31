#!/usr/bin/env python3
"""The retrieve inventory decides as it did before it moved to IsiXDICOMNetwork,
and the retrieve finds the same instances and files here through
LocalSeriesReading as through the direct reads it replaced.

The inventory was a class of the app, Horos/Sources/RetrieveInventory.swift,
with its state behind one recursive lock; it is now RetrieveInventory,
RetrieveInventoryState and RetrieveInventoryStore of IsiXDICOMNetwork, with
the state a value behind a mutex. What a retrieve asks for again, and how it is
judged, come from it: the missing instances, the series a second pass asks for,
what the peer cannot send, what is complete or satisfied, the summary and the
manifest it writes.

One driver, written against the inventory's former interface (rows of a
listing as dictionaries, the peer's counts as numbers, and the notifications
the store observes), is compiled twice:
- with RetrieveInventory.swift of the revision before the move, read from git;
- with IsiXDICOMNetwork of this tree and the prelude of
  tests/retrieve_inventory_harness.py, which gives the module that interface.
It runs a few hundred seeded scenarios: listings with instances missing their
UID or series, duplicates, SOP classes, Instance Numbers and classes not
offered; then stores that arrive, warn or fail, copies under new UIDs named by
their source or matched by series, class and number, refusals counted from a
C-GET's failed sub-operations, forced retrieves, what is here changing,
series left out by rule, listings confirmed, failed or cancelled after the
transfer began, retrieves that finish and begin again, and inventories read
back from their manifest once no one holds them. After each step it prints
every answer of the inventory and the manifest it wrote, without its dates and
with the sets in order. The two outputs must be the same, line for line.

The reads: DCMTKQueryNode read the SOP Instance UIDs here through
HorosLocalQueryReader.sopInstanceUIDs, and the Query window the files of a row
through HorosLocalQueryReader.fileCount(ofStudy:) with the study's object ID;
both now ask LocalSeriesReading, which LocalDatabaseStudyReader answers. Over
the real N2ManagedDatabase and the same seeded SQLite index (studies that
share a UID, series without one, images without a SOP Instance UID or with the
same one twice, a study deleted), the reference revision's static reads and the
port must give the same instances (as a multiset) and the same counts, for
every study, with no series, an empty one, each of its series and one that is
not there.

Exits 2 when the history does not reach the revision before the move, or when
this tree still has the app's inventory.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import history_reference  # noqa: E402
import n2_database_harness as harness  # noqa: E402
import retrieve_inventory_harness  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
FORMER = 'Horos/Sources/RetrieveInventory.swift'
SKIPPED = 2

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)
if (ROOT / FORMER).exists():
    print('skipped: this tree still has the app\'s retrieve inventory', file=sys.stderr)
    sys.exit(SKIPPED)
try:
    history_reference.show('HEAD', FORMER)
    reference = 'HEAD'
except subprocess.CalledProcessError:
    reference = history_reference.before_removal(FORMER)
if reference is None:
    print('skipped: the history does not reach the revision before the inventory moved', file=sys.stderr)
    sys.exit(SKIPPED)

failures = []

# --- the inventory ---------------------------------------------------------------
DRIVER = r'''
import CoreData
import Foundation

let directory = CommandLine.arguments[1]
var seed: UInt64 = 0x9E3779B97F4A7C15
func next(_ bound: Int) -> Int {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Int((seed >> 33) % UInt64(max(bound, 1)))
}
func chance(_ percent: Int) -> Bool { next(100) < percent }
func pick<T>(_ values: [T]) -> T { values[next(values.count)] }

func text(_ value: Any) -> String {
    if let list = value as? [String] { return "[" + list.joined(separator: ",") + "]" }
    if let map = value as? [String: [String]] {
        return "{" + map.keys.sorted().map { "\($0):" + text(map[$0]!.sorted()) }.joined(separator: ";") + "}"
    }
    if let map = value as? [String: String] { return "{" + map.keys.sorted().map { "\($0)=\(map[$0]!)" }.joined(separator: ";") + "}" }
    if let map = value as? [String: Int] { return "{" + map.keys.sorted().map { "\($0)=\(map[$0]!)" }.joined(separator: ";") + "}" }
    return "\(value)"
}

/// The manifest as written, without its dates, its sets in order.
func manifest(_ path: String) -> String {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "none" }
    object["updated"] = nil
    object["queried"] = nil
    for key in ["imported", "httpRejected", "peerFailed", "unoffered", "duplicateInventory"] {
        if let list = object[key] as? [String] { object[key] = list.sorted() }
    }
    guard let out = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "?" }
    return String(decoding: out, as: UTF8.self)
}

func dump(_ label: String, _ m: RetrieveInventory, uids: [String], series: [String]) {
    var lines: [String] = []
    lines.append("file=\((m.path as NSString).lastPathComponent)")
    lines.append("confirmed=\(m.inventoryConfirmed) expected=\(m.expectedCount) local=\(m.localUniqueCount) imported=\(m.importedCount)")
    lines.append("attention=\(m.needsAttention) complete=\(m.isComplete) satisfied=\(m.isSatisfied) nothingLeft=\(m.nothingLeftToAsk)")
    lines.append("missing=\(text(m.missingUIDs)) duplicate=\(text(m.duplicateUIDs)) rejected=\(text(m.rejectedUIDs)) unexpected=\(text(m.unexpectedUIDs))")
    lines.append("unsendable=\(text(m.unsendableUIDs)) classes=\(text(m.unsendableClasses)) absences=\(m.expectedAbsenceCount)")
    lines.append("reported=\(m.reportedCount) unlisted=\(m.unlistedCount) empty=\(text(m.emptySeries))")
    lines.append("matches=" + [-1, 0, 1, 3, 5, 8, 12].map { "\(m.matchesReportedCount($0))" }.joined(separator: ","))
    for round in -1...2 {
        lines.append("retry\(round)=\(text(m.retrySeries(afterRound: round, cancelled: false))) cancelled=\(text(m.retrySeries(afterRound: round, cancelled: true)))")
    }
    lines.append("missingSeries=\(text(m.missingSeries)) unreceived=\(text(m.unreceivedSeries)) excluded=\(text(m.excludedSeries))")
    lines.append("scope=\(m.scopeExpectedCount)/\(m.scopeImportedCount) awaiting=\(m.receivedAwaitingImportCount) discovery=\(m.discoveryState)")
    lines.append("expectedInstances=\(text(m.expectedInstances))")
    lines.append("sources=\(text(m.sourceUIDs(ofDerived: uids + ["n.1", "n.2", "n.3"])))")
    lines.append("arrivals=" + ([("", "")] + series.map { ("", $0) } + [(uids.prefix(3).joined(separator: "|"), ""), ("x.9", "")]).map { pair in
        "\(m.arrivals(requested: pair.0.isEmpty ? [] : pair.0.components(separatedBy: "|"), series: pair.1))"
    }.joined(separator: ","))
    lines.append("summary=\(m.summary)")
    lines.append("manifest=\(manifest(m.path))")
    print("\(label)\n  " + lines.joined(separator: "\n  "))
}

let statuses = [0, 0, 0, 0xB000, 0xB007, 0xA700, 0xA900, 0xC000]
for scenario in 0..<240 {
    let study = "9.\(scenario)"
    let seriesUIDs = ["\(study).1", "\(study).2", "\(study).3"]
    let classes = ["1.2.840.10008.5.1.4.1.1.2", "1.2.840.10008.5.1.4.1.1.4", "1.3.12.2.1107.5.99.3.10"]
    func listing() -> [[String: String]] {
        var rows: [[String: String]] = []
        for i in 0..<next(9) {
            var row: [String: String] = [:]
            if !chance(4) { row["uid"] = chance(5) ? "" : "\(study).0.\(chance(8) ? max(i - 1, 0) : i)" }
            if !chance(4) { row["series"] = pick(seriesUIDs) }
            if chance(70) { row["sopClass"] = pick(classes) }
            if chance(60) { row["number"] = pick(["1", " 2", "3 ", "x", "\(i)"]) }
            if chance(12) { row["offered"] = "NO" }
            rows.append(row)
        }
        return rows
    }
    func counts() -> [String: NSNumber] {
        var counts: [String: NSNumber] = [:]
        for uid in seriesUIDs where chance(40) { counts[uid] = NSNumber(value: next(5)) }
        return counts
    }
    let seriesScope = chance(25) ? pick(seriesUIDs) : ""
    let endpoint = pick(["PACS@host:104", "OSIRIX@peer:11112"])
    var rows = listing()
    var uids = rows.compactMap { $0["uid"] }.filter { !$0.isEmpty }
    var inventory: RetrieveInventory? = RetrieveInventory.begin(study: study, series: seriesScope, endpoint: endpoint, database: directory,
                                                               instances: rows, confirmed: chance(80), reported: next(12) - 1,
                                                               seriesReported: counts())
    var holders = 1
    dump("s\(scenario) begin", inventory!, uids: uids, series: seriesUIDs)
    for step in 0..<22 {
        guard let m = inventory else { break }
        let any = uids.isEmpty ? "\(study).0.0" : pick(uids)
        var what = ""
        switch next(19) {
        case 0, 1, 2:
            let status = pick(statuses)
            m.record(uid: chance(85) ? any : "\(study).x.\(next(3))", status: status); what = "record \(status)"
        case 3:
            let copy = "n.\(next(3) + 1)"
            m.record(uid: copy, status: pick(statuses), sources: chance(80) ? [any] : ["", copy, "o.1"]); what = "record copy"
        case 4:
            let copy = "n.\(next(3) + 1)"
            let row = rows.isEmpty ? [:] : pick(rows)
            m.record(uid: copy, status: 0, series: chance(80) ? (row["series"] ?? "") : "", sopClass: row["sopClass"] ?? pick(classes),
                     instanceNumber: chance(85) ? (row["number"] ?? "") : "7"); what = "record unreferenced"
        case 5:
            m.recordPeerFailedUID(any); what = "peer failed"
        case 6:
            let requested = chance(30) ? [] : Array(Set((0..<next(4)).map { _ in any } + (chance(20) ? [""] : [])))
            let unsent = m.recordUnsent(requested: requested.sorted(), series: chance(30) ? pick(seriesUIDs) : "",
                                        status: UInt(pick([0, 0xB000, 0xA702, 0xC000])), failed: UInt(next(4)), remaining: UInt(chance(80) ? 0 : 1))
            what = "unsent \(unsent)"
        case 7:
            if chance(30) { m.forgetPeerFailures(); what = "forced" } else { m.recordHTTPRejectedUID(any); what = "http rejected" }
        case 8:
            m.recordTLSUntrustedUID(any, reason: "untrusted"); what = "tls"
        case 9:
            m.record(operation: pick(["C-MOVE", "C-GET"]), status: UInt(pick(statuses)), completed: UInt(next(5)), failed: UInt(next(3)),
                     warnings: UInt(next(2)), remaining: UInt(next(2))); what = "operation"
        case 10, 11, 12:
            let here = Array(Set(uids.filter { _ in chance(60) } + (chance(20) ? ["z.\(next(3))"] : []) + (chance(15) ? ["n.\(next(3) + 1)"] : [])
                                 + (chance(5) ? [""] : [])))
            let changed = m.updateImportedUIDs(here.sorted()); what = "here \(changed)"
        case 13:
            var excluded: [String: [String]] = [:]
            for uid in seriesUIDs where chance(30) { excluded[uid] = ["Scout \(uid)", "rule"] }
            m.exclude(series: excluded); what = "exclude"
        case 14:
            rows = listing()
            uids = rows.compactMap { $0["uid"] }.filter { !$0.isEmpty }
            let state = pick(["confirmed", "failed", "cancelled"])
            m.confirm(instances: rows, confirmed: state == "confirmed" && chance(90), reported: next(12) - 1, seriesReported: counts(), discovery: state)
            what = "confirm \(state)"
        case 15:
            m.markDiscovery(pick(["in progress", "not supported"])); what = "discovery"
        case 16:
            if chance(50) { NotificationCenter.default.post(name: .NSManagedObjectContextDidSave, object: nil) }
            if chance(30) { m.invalidateImportRefresh() }
            what = "refresh \(m.beginImportRefresh()) \(m.beginImportRefresh())"
        case 17:
            let status = pick(statuses)
            NotificationCenter.default.post(name: Notification.Name("HorosDICOMStoreCompleted"), object: nil, userInfo: [
                "uid": chance(85) ? any : "\(study).x.1", "status": NSNumber(value: status),
                "study": pick([study, "", "8.8"]), "series": pick(seriesUIDs + [""])])
            what = "store \(status)"
        default:
            if holders > 0 && chance(60) {
                m.finish(); holders -= 1; what = "finish"
            } else if chance(50) {
                rows = listing()
                uids = rows.compactMap { $0["uid"] }.filter { !$0.isEmpty }
                let again = RetrieveInventory.begin(study: study, series: seriesScope, endpoint: endpoint, database: directory,
                                                    instances: rows, confirmed: chance(80), reported: next(12) - 1, seriesReported: counts())
                holders += 1
                what = "begin again shared=\(again === m)"
            } else {
                // No one holds it: read back from its manifest.
                while holders > 0 { m.finish(); holders -= 1 }
                inventory = nil
                inventory = RetrieveInventory.load(study: study, series: seriesScope, endpoint: endpoint, database: directory)
                what = "reloaded \(inventory != nil)"
            }
        }
        if let m = inventory { dump("s\(scenario).\(step) \(what)", m, uids: uids, series: seriesUIDs) } else { print("s\(scenario).\(step) \(what)") }
    }
    while holders > 0, let m = inventory { m.finish(); holders -= 1 }
}
print("end")
'''


def run_driver(folder, sources):
    """Compile the driver with `sources` (swiftc arguments) and run it; its output."""
    (folder / 'main.swift').write_text(DRIVER)
    (folder / 'manifests').mkdir()
    build = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-module-cache-path', str(folder / 'module-cache'),
                            *sources, str(folder / 'main.swift'), '-o', str(folder / 'driver')],
                           capture_output=True, text=True, timeout=600)
    if build.returncode != 0:
        failures.append('the driver does not compile with %s:\n%s' % (folder.name, build.stderr[-3000:]))
        return None
    run = subprocess.run([str(folder / 'driver'), str(folder / 'manifests')], capture_output=True, text=True, timeout=120,
                         env=dict(os.environ, SWIFT_DETERMINISTIC_HASHING='1'))
    if run.returncode != 0:
        failures.append('the driver failed with %s (status %d):\n%s' % (folder.name, run.returncode, run.stderr[-2000:]))
        return None
    return run.stdout


def compare(what, before, after):
    if before is None or after is None:
        return
    old, new = before.splitlines(), after.splitlines()
    if old[-1:] != ['end'] or new[-1:] != ['end']:
        failures.append('%s: a run did not reach its end' % what)
    for number, (a, b) in enumerate(zip(old, new), 1):
        if a != b:
            label = next((line for line in reversed(old[:number]) if not line.startswith('  ')), '')
            failures.append('%s differs at line %d (%s):\n  before: %s\n  after:  %s' % (what, number, label.strip(), a.strip(), b.strip()))
            break
    else:
        if len(old) != len(new):
            failures.append('%s: %d lines before, %d after' % (what, len(old), len(new)))
    return len(old)


with tempfile.TemporaryDirectory(prefix='horos-inventory-equivalence-') as directory:
    work = Path(directory)
    before, after = work / 'before', work / 'after'
    before.mkdir()
    after.mkdir()
    (before / 'RetrieveInventory.swift').write_bytes(history_reference.show(reference, FORMER))
    old = run_driver(before, [str(before / 'RetrieveInventory.swift')])
    new = run_driver(after, retrieve_inventory_harness.swiftc_arguments(after / 'harness'))
    lines = compare('the inventory', old, new)

# --- the reads ---------------------------------------------------------------------
READS = r'''
import IsiXContracts

var seed: UInt64 = 0x2545F4914F6CDD1D
func next(_ bound: Int) -> Int {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Int((seed >> 33) % UInt64(max(bound, 1)))
}
let path = CommandLine.arguments[1]
let database = TestDatabase(path: path)!
let main = database.managedObjectContext!
func insert(_ entity: String) -> NSManagedObject { NSEntityDescription.insertNewObject(forEntityName: entity, into: main) }
var studies: [(String, NSManagedObject, [String])] = []
for s in 0..<40 {
    let uid = "1.\(next(25))"
    let study = insert("Study"); study.setValue(uid, forKey: "studyInstanceUID")
    var seriesUIDs: [String] = []
    for r in 0..<next(4) {
        let series = insert("Series"); series.setValue(study, forKey: "study")
        // Unique within the study: of two series with one UID, which is
        // first is the order of a set, which differs from run to run.
        let seriesUID = next(8) == 0 ? nil : "\(uid).\(r)"
        if let seriesUID { series.setValue(seriesUID, forKey: "seriesDICOMUID"); seriesUIDs.append(seriesUID) }
        for i in 0..<next(5) {
            let image = insert("Image"); image.setValue(series, forKey: "series")
            switch next(10) {
            case 0: break
            case 1: image.setValue("", forKey: "sopInstanceUID")
            case 2: image.setValue("\(uid).dup", forKey: "sopInstanceUID")
            default: image.setValue("\(uid).\(s).\(r).\(i)", forKey: "sopInstanceUID")
            }
        }
    }
    studies.append((uid, study, seriesUIDs))
}
_ = database.save()
let gone = studies.remove(at: 3)
main.delete(gone.1); _ = database.save()
let goneID = gone.1.objectID

func uids(_ study: String, _ series: String?) -> String {
    do { return READ_UIDS.sorted().joined(separator: ",") } catch { return "error \((error as NSError).domain)" }
}
func files(_ id: NSManagedObjectID, _ series: String?) -> String {
    do { return "\(READ_FILES)" } catch { return "error \((error as NSError).domain)" }
}
for (index, (uid, study, seriesUIDs)) in (studies + [gone]).enumerated() {
    let id = index == studies.count ? goneID : study.objectID
    let filters: [String?] = [nil, "", "9.9"] + seriesUIDs.map { Optional($0) }
    for series in filters {
        print("\(index) \(uid) \(series ?? "-") uids=\(uids(uid, series))")
        print("\(index) \(uid) \(series ?? "-") files=\(files(id, series))")
    }
}
print("end")
'''
FORMER_READS = READS.replace('READ_UIDS', 'try HorosLocalQueryReader.sopInstanceUIDs(ofStudyInstanceUID: study, seriesInstanceUID: series, in: database)') \
    .replace('READ_FILES', 'try HorosLocalQueryReader.fileCount(ofStudy: id, seriesInstanceUID: series, in: database).intValue') \
    .replace('import IsiXContracts\n', '')
PORT_READS = READS.replace('READ_UIDS', 'try LocalDatabaseStudyReader { database }.sopInstanceUIDs(ofStudyInstanceUID: study, seriesInstanceUID: series)') \
    .replace('READ_FILES', 'try LocalDatabaseStudyReader { database }.fileCount(ofStudy: LocalRecordIdentifier(uri: id.uriRepresentation()), seriesInstanceUID: series)')


def reads(label, driver, sources):
    folder = Path(tempfile.mkdtemp(prefix='horos-series-reads-%s-' % label))
    for name, text in sources.items():
        (folder / name).write_text(text)
    binary, work, error = harness.build(driver, [str(folder / name) for name in sources], work=folder / 'work')
    try:
        if error:
            failures.append('the %s reads do not compile: %s' % (label, error))
            return None
        status, _, stdout, stderr = harness.run(binary, [str(work / 'store' / 'Database.sql')])
        if status != 0:
            failures.append('the %s reads failed (status %d):\n%s' % (label, status, stderr[-2000:]))
            return None
        return stdout
    finally:
        shutil.rmtree(folder, ignore_errors=True)


former_reader = history_reference.show(reference, 'Horos/Sources/HorosLocalQueryReader.swift').decode('utf-8')
old_reads = reads('former', FORMER_READS, {'HorosLocalQueryReader.swift': former_reader})
new_reads = reads('port', PORT_READS, {name: (ROOT / 'Horos/Sources' / name).read_text(encoding='utf-8') for name in
                                       ('HorosLocalQueryReader.swift', 'LocalDatabaseStudyReader.swift',
                                        'LocalDatabaseStudyReader+Series.swift')})
read_lines = compare('the reads', old_reads, new_reads)

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: the inventory of %s answers as the app\'s did over %d lines of 240 scenarios, and LocalSeriesReading reads '
      'the same instances and files as the direct reads over %d lines' % (reference[:9], lines, read_lines))
