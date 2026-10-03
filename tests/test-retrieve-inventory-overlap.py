#!/usr/bin/env python3
"""A DICOMweb retrieve lists the node's instances beside its transfer.

The inventory of such a retrieve begins empty, its listing "in progress", and
receives the listing when it ends: confirmed, failed or cancelled. Modelled on
RetrieveInventory itself:
- while the listing runs, nothing is complete and the summary says so;
- a confirmed listing keeps what the attempt received and names, by series,
  only what neither arrived nor is in the index, leaving out what the peer
  declared it cannot send;
- a failed or cancelled listing leaves completeness unknown and names nothing,
  whatever arrived or the peer counted.

And in the sources: the move does not list a DICOMweb study before its
transfer; retrieveDICOMweb starts the listing thread first, asks for the whole
study or series at once when nothing of it is local, otherwise for each listed
series' missing instances as their listing ends, falls back to everything when
the listing fails, and asks for what a confirmed listing names that did not
arrive; a DICOMweb node lists the instances of several series in parallel, a
few at a time, while a DIMSE peer keeps one series after the other; the
listing asks only for the SOP Instance and Class UIDs; WADO-URI asks for the
instances the operation has just listed instead of listing the study again.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


driver = r'''
import Foundation
import CoreData
let directory=CommandLine.arguments[1]
func check(_ ok:Bool,_ what:String){ if !ok { print("FAIL: "+what); exit(1) } }
let m=RetrieveInventory.begin(study:"1.1",series:"",endpoint:"node",database:directory,instances:[],confirmed:false,reported:5,seriesReported:[:])
m.markDiscovery("in progress")
check(!m.inventoryConfirmed && !m.isComplete && m.discoveryState=="in progress","the listing runs")
check(m.summary.contains("still in progress") && m.summary.contains("cannot be established"),"summary while listing: "+m.summary)
check(m.unreceivedSeries.isEmpty,"nothing named before the listing ends")
m.updateImportedUIDs([])
for uid in ["1.2.1","1.2.2","1.2.3"] { m.record(uid:uid,status:0) }
let listed=[["uid":"1.2.1","series":"A"],["uid":"1.2.2","series":"A"],["uid":"1.2.3","series":"A"],
            ["uid":"1.2.4","series":"B","sopClass":"1.2.840.10008.5.1.4.1.1.2"],["uid":"1.2.5","series":"B"],["uid":"1.2.6","series":"B"]]
m.confirm(instances:listed,confirmed:true,reported:6,seriesReported:["A":3,"B":3],discovery:"confirmed")
check(m.inventoryConfirmed && m.discoveryState=="confirmed" && m.expectedCount==6 && m.expectedInstances["1.2.4"]=="B","confirmed listing")
check(m.unreceivedSeries==["B":["1.2.4","1.2.5","1.2.6"]],"what did not arrive, by series: \(m.unreceivedSeries)")
m.updateImportedUIDs(["1.2.1","1.2.2","1.2.3","1.2.4"])
m.recordPeerFailedUID("1.2.6")
check(m.unreceivedSeries==["B":["1.2.5"]],"imported and unsendable left out: \(m.unreceivedSeries)")
check(!m.isComplete,"two missing")
m.updateImportedUIDs(["1.2.1","1.2.2","1.2.3","1.2.4","1.2.5","1.2.6"])
check(m.isComplete && m.unreceivedSeries.isEmpty,"complete by UIDs")
m.finish()
for state in ["failed","cancelled"] {
 let f=RetrieveInventory.begin(study:"2.\(state)",series:"",endpoint:"node",database:directory,instances:[],confirmed:false,reported:4,seriesReported:[:])
 f.markDiscovery("in progress")
 f.record(uid:"2.1",status:0)
 f.confirm(instances:[["uid":"2.1","series":"S"]],confirmed:false,reported:4,seriesReported:[:],discovery:state)
 check(!f.inventoryConfirmed && !f.isComplete && f.unreceivedSeries.isEmpty && f.discoveryState==state,state+": unknown completeness")
 check(f.summary.contains(state=="failed" ? "listing of the server's instances failed" : "was cancelled"),state+" summary: "+f.summary)
 f.finish()
}
print("PASS: inventory in progress, confirmed after the transfer started, unreceived by series, failed and cancelled listings")
'''

with tempfile.TemporaryDirectory(prefix='horos-inventory-overlap-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(driver)
    (p / 'db').mkdir()
    subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', str(root / 'Horos/Sources/RetrieveInventory.swift'),
                    str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    run = subprocess.run([str(p / 'test'), str(p / 'db')], capture_output=True, text=True, timeout=60)
    print((run.stdout + run.stderr).strip())
    check(run.returncode == 0, 'the inventory model check failed')

node = (root / 'Horos/Sources/DCMTKQueryNode.mm').read_text()


def block(name):
    start = node.index(name)
    return node[start:node.index('\n}\n', start)]


move = block('- (void) move:(NSDictionary*) dict retrieveMode: (int) retrieveMode')
check('if (localRetrieve && !dicomweb) [self beginRetrieveInventoryForCGET:' in move,
      'the move does not list a DICOMweb study before its transfer')
retrieve = block('- (BOOL)retrieveDICOMweb')
check(retrieve.index('[listing start];') < retrieve.index('if (whole && !perSeries) enqueue(base, nil, nil);'),
      'the listing starts before the transfer')
check('BOOL whole = localUIDs.count == 0;' in retrieve, 'nothing local: the whole study or series at once')
check('[_retrieveInventory markDiscovery:@"in progress"];' in retrieve, 'the inventory is in progress during the transfer')
loop = retrieve[retrieve.index('while (YES) {'):retrieve.index('while (!listing.isFinished)')]
check('[collector drainChildren]' in loop and 'enqueue([NSString stringWithFormat:@"studies/%@/series/%@/instances/%@"' in loop,
      'each listed series asks for its missing instances while the listing goes on')
after = retrieve[retrieve.index('while (!listing.isFinished)'):]
check(after.index('confirmInstances:instances') < after.index('_retrieveInventory.unreceivedSeries'),
      'the listing is given to the inventory before the second pass')
check('if (!succeeded && !whole && !excluded.count) enqueue(base, nil, nil);' in after, 'a failed listing falls back to everything')
check('thread.isCancelled ? @"cancelled" : succeeded ? @"confirmed" : @"failed"' in after, 'the listing states')
hierarchy = block('- (BOOL) queryImagesHierarchicallyForStudy:(NSString*) studyInstanceUID')
check('[HorosDICOMwebSources isDICOMwebServer: _extraParameters] && seriesInstanceUIDs.count > 1' in hierarchy and
      'queryDICOMwebImagesOfSeries:' in hierarchy and 'for( NSString *seriesInstanceUID in seriesInstanceUIDs)' in hierarchy,
      'parallel listing for DICOMweb only; DIMSE keeps the series loop')
parallel = block('- (BOOL) queryDICOMwebImagesOfSeries:(NSArray*) seriesInstanceUIDs study:(NSString*) studyInstanceUID')
check('MIN( (NSUInteger) 4, seriesInstanceUIDs.count)' in parallel and '[worker cancel]' in parallel,
      'at most four listings at once, cancelled with the thread')
asked = [line.split('DCM_')[1].split(',')[0] for line in parallel.splitlines() if 'insertEmptyElement' in line]
check(asked == ['SOPInstanceUID', 'SOPClassUID', 'InstanceNumber'],
      f'the listing asks only for the instance and class UIDs and the Instance Number: {asked}')
wado = block('- (void) WADORetrieve: (DCMTKStudyQueryNode*) study listing: (NSDictionary*) listing')
reuse = wado[wado.index('if( listing.count)'):wado.index('return;')]
check('WADOCFindThread' not in reuse and 'queryWithValues' not in reuse, 'WADO-URI uses the listing without listing again')
check('_retrieveInventory.inventoryConfirmed ? _retrieveInventory.expectedInstances : nil' in move,
      'only a confirmed listing of this operation is reused')

for failure in failures:
    print('FAIL:', failure)
sys.exit(1 if failures else 0)
