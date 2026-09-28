#!/usr/bin/env python3
"""A study counts as complete when only its expected absences are missing (#790).

OsiriX counts an instance in a series whose IMAGE level lists none, so its study
reports one more instance than the hierarchical query lists. The inventory was
left unconfirmed by that count, and the auto-query retrieved the study again on
every cycle. The inventory is now what the walk listed, with the peer's counts
recorded beside it per series. What the peer counts without listing, and what it
declared it cannot send (#692), are expected absences: they do not keep the study
incomplete, do not warn twice and are not asked for again while the count stays
the same. A new count queries the inventory again, and Retrieve with Option still
asks for everything.

Modelled with a peer that reports 8 instances in the study, lists 7 at the IMAGE
level (series C counts 1 and lists none), and does not send one it lists.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        try:
            return subprocess.check_output(['git', '-C', str(root), 'show', revision + ':' + path],
                                           stderr=subprocess.DEVNULL)
        except subprocess.CalledProcessError:
            return b''
    return (root / path).read_bytes()


def block(text, start):
    at = text.find(start)
    if at < 0:
        return ''
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[opening:index + 1]
    return ''


failures = []
node = read('Horos/Sources/DCMTKQueryNode.mm').decode('utf-8', 'replace')
begin = block(node, '- (void)beginRetrieveInventory')
if '_numberImages.unsignedIntegerValue && unique.count != _numberImages.unsignedIntegerValue' in begin or \
        'unique.count != _numberImages' in begin:
    failures.append('the inventory is still unconfirmed when the listed UIDs do not add up to the reported count')
if 'reported:_numberImages.integerValue seriesReported:' not in begin:
    failures.append('the inventory does not record the count the peer reports')
walk = block(node, '- (BOOL) queryImagesHierarchicallyForStudy:')
if 'DCM_NumberOfSeriesRelatedInstances' not in walk or '_seriesInstanceCounts setObject:' not in walk:
    failures.append('the walk does not ask for, or keep, what each series says it holds')
query = read('Horos/Sources/QueryController.mm').decode('latin-1')
retrieve = block(query, '-(void) retrieve:(id)sender onlyIfNotAvailable:(BOOL) onlyIfNotAvailable')
if '!inventory.isSatisfied' not in retrieve:
    failures.append('the auto-query still retrieves a study whose only gaps are expected absences')
if 'if (inventory.isSatisfied) localFiles = totalFiles;' not in block(query, '- (void) addStudyIfNotAvailable:'):
    failures.append('the automatic retrieve of new studies still fetches a satisfied one again')
column = block(query, '- (HorosLocalCompleteness*) localCompletenessForItem:')
if 'inventory.reportedCount' not in column or 'completeButExpectedAbsences' not in column:
    failures.append('the Local column does not show local instances against the reported count, complete but for expected absences')

driver = r'''
import Foundation
let directory = CommandLine.arguments[1]
// Series A holds 4, B 3; C counts 1 and lists none. The peer reports 8.
let rows = (1...4).map { ["uid": "A.\($0)", "series": "A"] } + (1...3).map { ["uid": "B.\($0)", "series": "B"] }
let counts: [String: NSNumber] = ["A": 4, "B": 3, "C": 1]
func begin(_ study: String, reported: Int = 8) -> RetrieveInventory {
    RetrieveInventory.begin(study: study, series: "", endpoint: "OSIRIX@peer:11112", database: directory, instances: rows,
                            confirmed: true, reported: reported, seriesReported: counts)
}
let listed = rows.map { $0["uid"]! }
let sent = listed.filter { $0 != "B.3" }

// The first retrieve: B.3 is not sent, one failed sub-operation.
let first = begin("1.1")
first.updateImportedUIDs([])
for uid in sent { first.record(uid: uid, status: 0) }
first.recordUnsent(requested: [], series: "", status: 0xB000, failed: 1, remaining: 0)
first.updateImportedUIDs(sent)
precondition(first.inventoryConfirmed && first.expectedCount == 7 && first.reportedCount == 8)
precondition(first.unlistedCount == 1 && first.emptySeries == ["C"], "\(first.emptySeries)")
precondition(first.unsendableUIDs == ["B.3"] && first.expectedAbsenceCount == 2)
precondition(first.isSatisfied && !first.isComplete, "only expected absences are missing")
precondition(first.needsAttention, "the attempt that found the refusal says so")
precondition(first.matchesReportedCount(8) && first.matchesReportedCount(0) && !first.matchesReportedCount(9),
             "the inventory stands while the count stays the same, and only then")
precondition(first.summary.hasPrefix("Complete but for expected absences: 6 of 7"), first.summary)
precondition(first.summary.contains("The server reports 8: 1 it counts but does not list (1 series with no instances listed)."), first.summary)
first.finish()

// The next cycle: nothing to ask, nothing to report.
let second = begin("1.1")
second.updateImportedUIDs(sent)
precondition(second.isSatisfied && !second.needsAttention && second.nothingLeftToAsk)
second.finish()

// Retrieve with Option asks for everything again.
let forced = begin("1.1")
forced.forgetPeerFailures()
forced.updateImportedUIDs(sent)
precondition(!forced.isSatisfied && forced.needsAttention)
forced.finish()

// A listed instance that is simply missing is not an expected absence.
let missing = begin("2.1")
missing.updateImportedUIDs(Array(sent.dropLast()))
precondition(!missing.isSatisfied && !missing.isComplete)
missing.finish()

// An inventory the query could not confirm proves nothing.
let unconfirmed = RetrieveInventory.begin(study: "3.1", series: "", endpoint: "OSIRIX@peer:11112", database: directory,
                                          instances: rows, confirmed: false, reported: 8, seriesReported: counts)
unconfirmed.updateImportedUIDs(listed)
precondition(!unconfirmed.isSatisfied && !unconfirmed.matchesReportedCount(8))
unconfirmed.finish()

// A manifest without the reported count stands only when what it listed matches.
let old = RetrieveInventory.begin(study: "4.1", series: "", endpoint: "OSIRIX@peer:11112", database: directory,
                                  instances: rows, confirmed: true)
precondition(old.matchesReportedCount(7) && !old.matchesReportedCount(8) && old.unlistedCount == 0)
old.finish()

// The Local column: 6 of the 8 reported, complete; the detail says why.
let value = LocalCompleteness(localCount: 6, remoteCount: 8)
value.unsendableCount = 1
precondition(!value.isComplete && value.text == "75% (6/8) · 1 not sendable", value.text)
value.completeButExpectedAbsences = true
precondition(value.isComplete && value.fraction == 1 && value.sortValue == 1 && value.text == "100% (6/8)", value.text)
print(first.path)
'''

with tempfile.TemporaryDirectory(prefix='horos-expected-absence-') as directory:
    work = Path(directory)
    sources = []
    for name in ('RetrieveInventory.swift', 'LocalCompleteness.swift'):
        (work / name).write_bytes(read('Horos/Sources/' + name))
        sources.append(str(work / name))
    (work / 'main.swift').write_text(driver)
    build = subprocess.run(['xcrun', 'swiftc'] + sources + [str(work / 'main.swift'), '-o', str(work / 'check')],
                           capture_output=True, text=True)
    if build.returncode:
        failures.append('the inventory does not build with the driver: ' + build.stderr.strip().splitlines()[-1]
                        if build.stderr.strip() else 'the inventory does not build with the driver')
    else:
        run = subprocess.run([str(work / 'check'), directory], capture_output=True, text=True, timeout=30)
        if run.returncode:
            failures.append('the model peer: ' + (run.stderr.strip().splitlines() or ['failed'])[-1])
        else:
            manifest = json.loads(Path(run.stdout.strip()).read_text())
            if manifest.get('seriesReported') != {'A': 4, 'B': 3, 'C': 1} or manifest.get('seriesListed') != {'A': 4, 'B': 3} \
                    or manifest.get('reported') != 8 or manifest.get('emptySeries') != ['C'] or manifest.get('unlistedCount') != 1:
                failures.append('the manifest does not record what each series reported and listed: %s'
                                % {k: manifest.get(k) for k in ('reported', 'seriesReported', 'seriesListed', 'emptySeries', 'unlistedCount')})

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: the inventory is what the peer lists, its counts are recorded per series, and a study missing only '
      'what the peer counts without listing or cannot send is complete, not retrieved again while its count stays the same')
