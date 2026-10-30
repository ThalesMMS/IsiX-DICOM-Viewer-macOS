#!/usr/bin/env python3
"""Bounded IMAGE-level recovery uses only confirmed missing identities."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
import sys
sys.path.insert(0, str(ROOT / 'tests'))
from sources import class_text  # noqa: E402
node = class_text('DCMTKQueryNode')
recovery = node[node.index('private func retryMissingDIMSEInstances('):node.index('// MARK: Series left out by a rule')]
assert 'Thread.isMainThread' in recovery
assert 'waitForReceivedImports(refreshing:' in recovery
assert 'retrySeries(afterRound: round' in recovery and 'for round in 0..<2' in recovery
assert 'QueryIdentifiers.retrieve(instances: uids, series: seriesUID, study: inventoryStudyUID)' in recovery
identifiers = (ROOT / 'Modules/IsiXDICOMNetwork/Sources/QueryIdentifier.swift').read_text()
instances = identifiers[identifiers.index('public static func retrieve(instances'):]
instances = instances[:instances.index('return identifier')]
assert '.studyInstanceUID' in instances and '.seriesInstanceUID' in instances and '.sopInstanceUID' in instances
assert 'get ? .getStudyRoot : .moveStudyRoot' in recovery
assert 'if Thread.current.isCancelled { return }' in recovery
assert 'identifier: request, destination: destination) { return }' in recovery
assert 'result.status == 0xb000 || result.status == 0xa702' in node
assert '!Thread.current.isCancelled && !recoverablePartial' in node
assert 'localRetrieve && !dicomweb && Int(retrieveMode) != WADORetrieveMode && !Thread.current.isCancelled' in node

driver = r'''
import Foundation
let database = CommandLine.arguments[1]
let rows = [["uid":"1","series":"A"],["uid":"2","series":"A"],
            ["uid":"3","series":"B"],["uid":"4","series":"B"],
            ["uid":"5","series":"C","offered":"NO"]]
func begin(_ study: String, confirmed: Bool = true) -> RetrieveInventory {
    RetrieveInventory.begin(study:study,series:"",endpoint:"PACS@127.0.0.1:104",database:database,
                            instances:rows,confirmed:confirmed)
}
let inventory = begin("1")
inventory.updateImportedUIDs(["1"])
inventory.record(uid:"2",status:0) // received, not indexed: never resend it
assert(inventory.retrySeries(afterRound:0,cancelled:false) == ["B":["3","4"]])
assert(inventory.retrySeries(afterRound:1,cancelled:false) == ["B":["3","4"]])
assert(inventory.retrySeries(afterRound:2,cancelled:false).isEmpty)
assert(inventory.retrySeries(afterRound:-1,cancelled:false).isEmpty)
assert(inventory.retrySeries(afterRound:0,cancelled:true).isEmpty)
// A partial retry imports one UID; the next round asks only for the other.
inventory.record(uid:"3",status:0)
inventory.updateImportedUIDs(["1","2","3"])
assert(inventory.retrySeries(afterRound:1,cancelled:false) == ["B":["4"]])
assert(inventory.needsAttention)
inventory.record(uid:"4",status:0)
inventory.updateImportedUIDs(["1","2","3","4"])
assert(inventory.retrySeries(afterRound:1,cancelled:false).isEmpty)
inventory.finish()
let unknown = begin("2",confirmed:false)
assert(unknown.retrySeries(afterRound:0,cancelled:false).isEmpty)
unknown.finish()
let refused = begin("3")
refused.updateImportedUIDs(["1","2","3"])
refused.recordUnsent(requested:["4"],series:"B",status:0xA702,failed:1,remaining:0)
assert(refused.retrySeries(afterRound:0,cancelled:false) == ["B":["4"]])
assert(refused.retrySeries(afterRound:1,cancelled:false) == ["B":["4"]])
assert(refused.retrySeries(afterRound:2,cancelled:false).isEmpty)
assert(refused.needsAttention) // persistent refusal is reported after the recovery budget
refused.finish()
let historical = begin("3")
historical.updateImportedUIDs(["1","2","3"])
assert(historical.retrySeries(afterRound:0,cancelled:false).isEmpty)
historical.finish()
let transient = begin("5")
transient.updateImportedUIDs(["1","2","3"])
transient.recordUnsent(requested:["4"],series:"B",status:0xB000,failed:1,remaining:0)
assert(transient.retrySeries(afterRound:0,cancelled:false) == ["B":["4"]])
transient.record(uid:"4",status:0)
transient.updateImportedUIDs(["1","2","3","4"])
assert(transient.retrySeries(afterRound:1,cancelled:false).isEmpty && !transient.needsAttention)
transient.finish()
// Multiple series are separated, and nothing local is included.
let multiple = begin("4")
multiple.updateImportedUIDs(["1"])
assert(multiple.retrySeries(afterRound:0,cancelled:false) == ["A":["2"],"B":["3","4"]])
multiple.finish()
print("ok: two bounded selective rounds, pending imports, cancellation, unknown inventory and unavailable classes")
'''
with tempfile.TemporaryDirectory(prefix='dimse-retry-') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(driver)
    subprocess.run(['xcrun','swiftc',str(ROOT / 'Horos/Sources/RetrieveInventory.swift'),str(folder / 'main.swift'),
                    '-o',str(folder / 'test')],check=True)
    subprocess.run([str(folder / 'test'),directory],check=True,timeout=20)
