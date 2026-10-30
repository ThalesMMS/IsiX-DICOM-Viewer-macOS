#!/usr/bin/env python3
"""A C-MOVE or C-GET from a node that counts no sub-operations still gets a bar.

The bar of a DIMSE retrieve moved on the node's pending responses alone, by the
sub-operation counts they carry. Both are optional: a node that answers with
its final response only left the bar indeterminate to the end, though the
retrieve's inventory lists what is expected and hears every arrival.

Modelled on RetrieveInventory itself: of what one operation asks for (named
instances, a series, or all that is listed, less the series left out), how many
this attempt has received.

And in the sources:
- both waits tell the caller of a turn that brought no response: the C-MOVE
  wait each time nothing or a sub-association was readable, the C-GET wait
  after each store on its association;
- until the peer counts, a confirmed listing gives the fraction, once
  something has arrived; a peer that counts keeps moving the bar as before;
- having followed the listing, the bar never steps back;
- each operation tells the callback what it asked for, from zeroed data.

The bar's rule is RetrieveProgress (IsiXDICOMNetwork), run here as it ships.
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
func arrive(_ uid:String,_ series:String,status:Int=0){
    NotificationCenter.default.post(name:Notification.Name("HorosDICOMStoreCompleted"),object:nil,
        userInfo:["uid":uid,"status":NSNumber(value:status),"study":"1.1","series":series])
}
let listing=(1...6).map{["uid":"1.1.1.\($0)","series":$0<=4 ? "1.1.1":"1.1.2"]}
let m=RetrieveInventory.begin(study:"1.1",series:"",endpoint:"node",database:directory,instances:listing,confirmed:true,reported:6,seriesReported:[:])
check(m.arrivals(requested:[],series:"")==[0,6],"nothing has arrived: \(m.arrivals(requested:[],series:""))")
arrive("1.1.1.1","1.1.1"); arrive("1.1.1.5","1.1.2")
check(m.arrivals(requested:[],series:"")==[2,6],"two of the study")
check(m.arrivals(requested:[],series:"1.1.1")==[1,4],"one of the first series")
check(m.arrivals(requested:["1.1.1.5","1.1.1.6"],series:"1.1.2")==[1,2],"one of the two instances named")
arrive("1.1.1.1","1.1.1")
check(m.arrivals(requested:[],series:"")==[2,6],"an instance sent twice is one arrival")
arrive("1.1.1.2","1.1.1",status:0xC000)
check(m.arrivals(requested:[],series:"")==[2,6],"a refused store is no arrival")
arrive("9.9","1.1.1")
check(m.arrivals(requested:[],series:"")==[2,6],"an unlisted instance is not counted")
m.exclude(series:["1.1.2":["rule"]])
check(m.arrivals(requested:[],series:"")==[1,4],"a series left out is not asked for: \(m.arrivals(requested:[],series:""))")
for n in 2...4 { arrive("1.1.1.\(n)","1.1.1") }
check(m.arrivals(requested:[],series:"")==[4,4],"all that was asked for")
print("PASS: arrivals of a study, a series and named instances")
'''

with tempfile.TemporaryDirectory(prefix='horos-retrieve-progress-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(driver)
    (p / 'db').mkdir()
    subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', str(root / 'Horos/Sources/RetrieveInventory.swift'),
                    str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    run = subprocess.run([str(p / 'test'), str(p / 'db')], capture_output=True, text=True, timeout=60)
    print((run.stdout + run.stderr).strip())
    check(run.returncode == 0, 'the inventory model check failed')

move = (root / 'Horos/Sources/Adapters/DCMTK/IsiXDCMTKMoveUser.mm').read_bytes().decode('latin1')
loop = move[move.index('while (cond == EC_Normal && status == STATUS_Pending)'):]
turn = loop.find('if (readable != 1 && callback)')
check(0 < turn < loop.find('switch (readable)') and 'callback(callbackData, request, responseCount, NULL);' in loop[turn:turn + 120],
      'the C-MOVE wait does not tell the caller of a turn without a response')

get = (root / 'Horos/Sources/Adapters/DCMTK/IsiXDCMTKGetUser.mm').read_bytes().decode('latin1')
store = get[get.index('case DIMSE_C_STORE_RQ:'):]
check('callback(callbackData, request, responseCount, NULL);' in store[:store.index('break;')],
      'the C-GET wait does not tell the caller of an arrival')

# The bar's rule is RetrieveProgress, in IsiXDICOMNetwork; the node feeds it
# what the adapter's DIMSE callbacks report, and the inventory's arrivals.
progress = r'''
var bar = RetrieveProgress()
var arrived: (received: UInt, asked: UInt)? = nil
func show(_ counted: Bool, _ accounted: UInt, _ finished: UInt) -> String {
    guard let shown = bar.update(counted: counted, accounted: accounted, finished: finished, arrivals: { arrived }) else { return "-" }
    return "\(shown.finished)/\(shown.accounted)"
}
var out: [String] = []
out.append(show(false, 0, 0))   // a turn without a response and without a listing
arrived = (0, 6)
out.append(show(false, 0, 0))   // a listing, nothing arrived yet
arrived = (2, 6)
out.append(show(false, 0, 0))   // the listing moves the bar
arrived = (1, 6)
out.append(show(false, 0, 0))   // and it never steps back
arrived = (9, 6)
out.append(show(true, 0, 0))    // a final response without counts: no more than asked
var counting = RetrieveProgress()
arrived = (3, 6)
_ = counting.update(counted: true, accounted: 10, finished: 1, arrivals: { arrived })
let peer = counting.update(counted: false, accounted: 0, finished: 0, arrivals: { arrived })
out.append(peer.map { "\($0.finished)/\($0.accounted)" } ?? "-")  // a peer that counts keeps the bar
out.append(String(RetrieveProgress.fraction(accounted: 0, finished: 0)))
print(out.joined(separator: " "))
'''
with tempfile.TemporaryDirectory(prefix='horos-retrieve-progress-rule-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(progress)
    subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', str(root / 'Modules/IsiXDICOMNetwork/Sources/RetrieveRules.swift'),
                    str(p / 'main.swift'), '-o', str(p / 'rule')], check=True)
    run = subprocess.run([str(p / 'rule')], capture_output=True, text=True, timeout=60)
    check(run.returncode == 0 and run.stdout.split() == ['-', '-', '2/6', '-', '6/6', '-', '0.0'],
          'the bar does not follow the listing until the peer counts, or steps back: ' + (run.stdout + run.stderr).strip())

sys.path.insert(0, str(root / 'tests'))
from sources import class_text  # noqa: E402
node = class_text('DCMTKQueryNode')
start = node.index('private func reportRetrieveProgress(')
report = node[start:node.index('\n    }\n', start)]
check('progress.update(counted: counted, accounted: accounted, finished: finished)' in report,
      'the node does not leave the bar to RetrieveProgress')
check('inventory.inventoryConfirmed else { return nil }' in report
      and 'inventory.arrivals(requested: requested.instances ?? [], series: requested.series)' in report,
      'the fraction does not come from a confirmed listing of what was asked for')
adapter = (root / 'Horos/Sources/Adapters/DCMTK/IsiXDCMTKQueryRetrieveSCU.mm').read_text()
at = adapter.index('static void IsiXDCMTKReportProgress(')
callback = adapter[at:adapter.index('\n}\n', at)]
check('if (response == NULL) { context->progress(NO, 0, 0); return; }' in callback
      and 'context->progress(YES, finished + response->NumberOfRemainingSubOperations, finished);' in callback,
      'the DIMSE callbacks do not tell a response from a turn without one')
for name in ('Move', 'Get'):
    at = adapter.index('static void IsiXDCMTK%sCallback(' % name)
    check('IsiXDCMTKReportProgress(data, response)' in adapter[at:adapter.index('\n}\n', at)],
          'the C-%s callback does not report its progress' % name.upper())
move = node[node.index('private func moveSCU('):]
check('if progress.listingShown { reportRetrieveProgress(&progress, requested: requested, counted: false, accounted: 0, finished: 0) }'
      in move[:move.index('countOfSuboperations')],
      'a C-MOVE that followed the listing does not show its last arrivals')
check(node.count('var progress = RetrieveProgress()') == 2,
      'each operation does not start its bar from zeroed data')
check(node.count('let requested = Self.requestedInstances(identifier)') == 2,
      'the C-MOVE and the C-GET do not tell the callback what they asked for')

if failures:
    raise SystemExit('FAIL: ' + '; '.join(failures))
print('PASS: a retrieve whose peer counts nothing follows the listing')
