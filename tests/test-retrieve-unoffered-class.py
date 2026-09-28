#!/usr/bin/env python3
"""Instances of a class the C-GET does not offer to receive are expected absences (#789).

Siemens studies processed on syngo.via carry one Siemens CT MR Volume
(1.3.12.2.1107.5.99.3.10) per series beside the classic slices. A C-GET offers
to receive only the standard storage classes, and OsiriX refuses that class even
when it is offered, so those volumes never arrive. The IMAGE level now gives each
instance's SOP class; one of a class the C-GET does not offer is an expected
absence from the start. It is not asked for, and its failed sub-operation raises
neither «Get Failed» nor «Retrieve Incomplete», not even the first time. The
detail counts what the server does not send by SOP class. Retrieve with Option
still asks for it, and the presentation contexts are unchanged.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
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
walk = block(node, '- (BOOL) queryImagesHierarchicallyForStudy:')
if 'DCM_SOPClassUID' not in walk:
    failures.append('the IMAGE level is not asked for each instance\'s SOP class')
if 'DCM_SOPClassUID' not in read('Horos/Sources/DCMTKImageQueryNode.mm').decode('utf-8', 'replace'):
    failures.append('the image node does not keep the SOP class it was answered with')
begin = block(node, '- (void)beginRetrieveInventoryForCGET:')
if 'storageClassesOfferedByCGET' not in begin or '@"offered"' not in begin:
    failures.append('the inventory does not mark instances of classes the C-GET does not offer')
get = node[node.find('- (OFCondition)getSCU:'):]
get = get[:get.find('\n}\n')]
if 'completion.everythingArrived == NO && onlyUnoffered' not in get:
    failures.append('a C-GET whose only failures are classes it does not offer still says «Get Failed»')
contexts = block(node, '- (OFCondition) addPresentationContext:')
if '1.3.12.2.1107.5.99.3.10' in contexts or contexts.count('ASC_addPresentationContext(') != 2:
    failures.append('the C-GET presentation contexts changed')

driver = r'''
import Foundation
let directory = CommandLine.arguments[1]
let ct = "1.2.840.10008.5.1.4.1.1.2", volume = "1.3.12.2.1107.5.99.3.10"
let rows = (1...4).map { ["uid": "CT.\($0)", "series": "S", "sopClass": ct] }
    + [["uid": "VOL.1", "series": "S", "sopClass": volume, "offered": "NO"]]
let slices = (1...4).map { "CT.\($0)" }
func begin(_ study: String) -> RetrieveInventory {
    RetrieveInventory.begin(study: study, series: "", endpoint: "OSIRIX@peer:11112", database: directory, instances: rows,
                            confirmed: true, reported: 5, seriesReported: ["S": 5])
}

// The first retrieve, at STUDY level: the four slices arrive, the volume fails.
let first = begin("1.1")
first.updateImportedUIDs([])
for uid in slices { first.record(uid: uid, status: 0) }
precondition(first.recordUnsent(requested: [], series: "", status: 0xB000, failed: 1, remaining: 0),
             "the only failure is the class the C-GET does not offer")
first.updateImportedUIDs(slices)
precondition(first.isSatisfied && !first.isComplete)
precondition(!first.needsAttention, "an instance that could not arrive is no reason to warn, not even the first time")
precondition(first.unsendableUIDs == ["VOL.1"] && first.unsendableClasses == [volume: 1], "\(first.unsendableClasses)")
precondition(first.summary.contains("Not sent by the server: 1 of \(volume), a class this retrieve does not offer to receive."), first.summary)
first.finish()

// With nothing local yet, a smart retrieve has nothing to ask for it.
let fresh = begin("2.1")
fresh.updateImportedUIDs(slices)
precondition(fresh.nothingLeftToAsk && fresh.isSatisfied && !fresh.needsAttention)
fresh.finish()

// A slice the peer fails beside it is a real failure, reported.
let mixed = begin("3.1")
mixed.updateImportedUIDs([])
for uid in slices.dropLast() { mixed.record(uid: uid, status: 0) }
precondition(!mixed.recordUnsent(requested: [], series: "", status: 0xB000, failed: 2, remaining: 0))
mixed.updateImportedUIDs(Array(slices.dropLast()))
precondition(mixed.needsAttention, "a slice the peer did not send is still reported")
mixed.finish()

// Retrieve with Option asks for everything again.
let forced = begin("1.1")
forced.forgetPeerFailures()
forced.updateImportedUIDs(slices)
precondition(!forced.isSatisfied && !forced.nothingLeftToAsk && forced.unsendableUIDs.isEmpty)
forced.finish()
print("ok")
'''

with tempfile.TemporaryDirectory(prefix='horos-unoffered-') as directory:
    work = Path(directory)
    (work / 'RetrieveInventory.swift').write_bytes(read('Horos/Sources/RetrieveInventory.swift'))
    (work / 'main.swift').write_text(driver)
    build = subprocess.run(['xcrun', 'swiftc', str(work / 'RetrieveInventory.swift'), str(work / 'main.swift'),
                            '-o', str(work / 'check')], capture_output=True, text=True)
    if build.returncode:
        lines = build.stderr.strip().splitlines()
        failures.append('the inventory does not build with the driver: ' + (lines[0] if lines else ''))
    else:
        run = subprocess.run([str(work / 'check'), directory], capture_output=True, text=True, timeout=30)
        if run.returncode:
            failures.append('the model: ' + (run.stderr.strip().splitlines() or ['failed'])[-1])

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: instances of a class the C-GET does not offer are expected absences from the start, without a warning, '
      'counted by class in the detail, asked for again only by Retrieve with Option, with the contexts unchanged')
