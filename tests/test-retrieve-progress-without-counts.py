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
"""
import subprocess
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

move = (root / 'Horos/Sources/HorosDIMSEMove.mm').read_bytes().decode('latin1')
loop = move[move.index('while (cond == EC_Normal && status == STATUS_Pending)'):]
turn = loop.find('if (readable != 1 && callback)')
check(0 < turn < loop.find('switch (readable)') and 'callback(callbackData, request, responseCount, NULL);' in loop[turn:turn + 120],
      'the C-MOVE wait does not tell the caller of a turn without a response')

get = (root / 'Horos/Sources/HorosDIMSEGet.mm').read_bytes().decode('latin1')
store = get[get.index('case DIMSE_C_STORE_RQ:'):]
check('callback(callbackData, request, responseCount, NULL);' in store[:store.index('break;')],
      'the C-GET wait does not tell the caller of an arrival')

node = (root / 'Horos/Sources/DCMTKQueryNode.mm').read_bytes().decode('latin1')
start = node.index('static void reportRetrieveProgress(')
report = node[start:node.index('\nstatic void\nmoveCallback', start)]
check('info->peerCounts = YES' in report and 'else if( !info->peerCounts)' in report,
      'a peer that counts does not keep the bar to itself')
check('inventory.inventoryConfirmed ?' in report and 'arrivalsOfRequested: info->requested' in report,
      'the fraction does not come from a confirmed listing of what was asked for')
check('if( received && asked)' in report, 'the listing moves the bar before anything has arrived')
check('if( !counted && !accounted)\n        return;' in report, 'a turn without a response and without a listing touches the bar')
check('if( info->listingShown && fraction < info->shown)\n        return;' in report, 'the bar can step back')
for name in ('moveCallback', 'getCallback'):
    at = node.index('\n' + name + '(void *callbackData')
    body = node[at:node.index('\n}\n', at)]
    check('if( response == NULL)' in body and 'reportRetrieveProgress( (MyCallbackInfo*) callbackData, NO, 0, 0);' in body
          and 'reportRetrieveProgress( (MyCallbackInfo*) callbackData, YES, accounted, finished);' in body,
          name + ' does not tell a response from a turn without one')
after = node[node.index('cond = HorosDIMSEMoveUser(assoc'):]
check('if( callbackData.listingShown)\n\t\t\treportRetrieveProgress( &callbackData, NO, 0, 0);' in after[:600],
      'a C-MOVE that followed the listing does not show its last arrivals')
check(node.count('callbackData = {};') == 3 and 'MyCallbackInfo      callbackData;' not in node,
      'callback data is not zeroed')
check(node.count('callbackData.requested = requestedInstances(dataset, &callbackData.series);') == 2,
      'the C-MOVE and the C-GET do not tell the callback what they asked for')

if failures:
    raise SystemExit('FAIL: ' + '; '.join(failures))
print('PASS: a retrieve whose peer counts nothing follows the listing')
