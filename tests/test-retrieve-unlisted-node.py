#!/usr/bin/env python3
"""A retrieve that arrived whole from a node that lists no series or instances
is not reported incomplete, and is not fetched again.

A node need not answer a C-FIND at the SERIES or IMAGE level to send a study:
some answer the STUDY level alone, and refuse the others or answer them with
no match. The listing a DIMSE retrieve makes before its transfer then names no
instance, the inventory stays unconfirmed, and every retrieve ended in

    Retrieve Incomplete
    Inventory unconfirmed: 1267 local unique instances; 0 UIDs announced.
    Completeness cannot be established.

with the whole study in the database, and with no reason given: the DIMSE
listing did not say how it had ended. The inventory being unconfirmed for good,
a retrieve of what is missing (Retrieve and View, the space bar) also brought
the whole study again each time.

The inventory now keeps how the listing ended (confirmed, failed, not
implemented, empty or cancelled). When it named nothing because the node
refused it or answered it empty, the node's own counters judge the retrieve:
every C-MOVE or C-GET ended in success with nothing failed, with a warning or
left, they completed something, as many stores arrived here as the node
counted, none was refused, and everything that arrived is in the index. That
is logged with its reason and written in the manifest, no notice is raised,
and while the node reports the same count and what arrived is still here the
study is not asked for again. A listing that failed, sub-operations that
failed or warned, and an instance that arrived and is not in the index keep
the notice.

The source checks name where the application does it; the compiled driver
runs retrieves as DCMTKQueryNode.move judges them, over IsiXDICOMNetwork's
inventory, with the stores posted as the listener posts them.
"""
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import retrieve_inventory_harness  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Horos/Sources'
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def block(text, signature):
    """The body of the declaration that starts with `signature`; empty when it is gone."""
    at = text.find(signature)
    if at < 0:
        return ''
    opening = text.index('{', at)
    depth, index = 0, opening
    while index < len(text):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                return text[opening:index + 1]
        index += 1
    return ''


def read(name):
    return (SOURCES / name).read_text(encoding='utf-8')


# --- the listing says how it ended --------------------------------------------------
network = read('DCMTKQueryNode+Network.swift')
find = block(network, 'private func findSCU(on association: IsiXDCMTKAssociation, identifier: IsiXDCMTKDataset)')
check('lastQueryStatus = result.status' in find
      and 'lastQueryNotImplementedValue = RetrieveListing.refuses(findStatus: result.status)' in find,
      'a C-FIND the node refuses is not told apart from one that failed')
quiet = find.find('if listsForRetrieve && lastQueryNotImplementedValue {')
check(0 <= quiet < find.find('Self.postNotice(NSLocalizedString("Query Failed (2)"') and quiet < find.find('Self.applicationNotices.notify('),
      'a retrieve\'s listing still raises a notice for a C-FIND the node refuses')
check('NSLog("---- retrieve listing: the node refused the C-FIND at the %@ level with status %@' in find,
      'the refusal of a retrieve\'s listing is not logged')

query = read('DCMTKQueryNode+Query.swift')
search = block(query, 'func query(withValues values: [Any]?, identifier given: DICOMQueryIdentifier?)')
check('lastQueryStatus = nil' in search, 'a search keeps the status of the one before it')
walk = block(query, 'func queryImagesHierarchically(forStudy studyInstanceUID: String?) -> Bool')
check('listingRefusalStatus = nil' in walk and 'subQuery.listsForRetrieve = listsForRetrieve' in walk
      and walk.count('noteFailedListing(notImplemented: subQuery.lastQueryNotImplemented, status: subQuery.lastQueryStatus)') == 2,
      'the walk does not sort the refusal of its series and instance listings, with its status')

inventory_source = read('DCMTKQueryNode+RetrieveInventory.swift')
begin = block(inventory_source, 'func beginRetrieveInventory(forCGET cget: Bool)')
check('collector.listsForRetrieve = true' in begin, 'the retrieve\'s listing is not marked as one')
check('refused = !confirmed && collector.lastQueryNotImplemented' in begin and 'refused = collector.listingNotImplemented' in begin
      and 'failedOtherwise = collector.listingFailedOtherwise' in begin,
      'the retrieve does not read how its listing ended, for a series and for a study')
check('RetrieveListing.beforeTransfer(listed: instances.count, confirmed: confirmed, refused: refused,' in begin
      and 'listing: listing, listingStatus: refusalStatus))' in begin,
      'the inventory is not told how the listing ended')
check('NSLog("---- retrieve listing of %@: %@, %ld instances named%@"' in begin, 'a listing that is not confirmed is not logged with how it ended')

# --- the retrieve is judged by the node's counters ----------------------------------
retrieve = read('DCMTKQueryNode+Retrieve.swift')
move = block(retrieve, 'func move(_ dictionary: [AnyHashable: Any]!, retrieveMode: Int32)')
judge = move.find('if !dicomweb && receivedIndexed && !Thread.current.isCancelled && inventory.judgeByPeerCounters() {')
check(judge >= 0, 'the move does not judge by the node\'s counters a retrieve whose listing named nothing')
if judge >= 0:
    check(move.index('waitForReceivedImports(refreshing:') < judge < move.index('inventory.finish()'),
          'the counters judge before what arrived was waited for, or after the inventory ended')
    check(judge < move.index('incomplete = inventory.needsAttention || !receivedIndexed || dicomwebShort'),
          'the retrieve is reported before the counters judged it')
    check('NSLog("---- retrieve complete by the node\'s counters: %@", inventory.summary)' in move[judge:judge + 400],
          'a retrieve judged by the node\'s counters is not logged with its reason')

# --- and not fetched again ----------------------------------------------------------
window = read('QueryController+Retrieve.swift')
asked = block(window, 'func retrieve(_ sender: Any?, onlyIfNotAvailable: Bool, forViewing: Bool, items: [Any]!, showGUI: Bool)')
stands = asked.find('if let inventory, inventory.standsByPeerCounters(reported: Int(reported)) {')
check(0 <= stands < asked.find('wanted = !inventory.matchesReportedCount(Int(reported)) || !inventory.isSatisfied || listingShort')
      and 'wanted = false' in asked[stands:stands + 700],
      'a retrieve of what is missing still asks for a study the node\'s counters judged complete')
ports = read('QueryWindowAutoQueryPorts.swift')
answer = block(ports, 'func retrieveInventory(of study: AutoQueryStudy) async -> AutoQueryRetrieveInventory?')
check('if inventory.judgedByPeerCounters {' in answer and 'AutoQueryRetrieveInventory.judgedByPeerCounters(inventory, reported: reported)' in answer,
      'the automatic query does not hear of a study the node\'s counters judged complete')
results = read('QueryController+Results.swift')
column = block(results, 'nonisolated func inventoryCompleteness(forItem item: Any?, inventory: RetrieveInventory)')
check('let judged = !current && inventory.standsByPeerCounters(reported: reported)' in column
      and 'value.completeButExpectedAbsences = (current && inventory.isSatisfied) || judged' in column,
      'the Local column shows an unknown total for a study the node\'s counters judged complete')

# --- retrieves, as the move judges them ---------------------------------------------
DRIVER = r'''
import Foundation

let directory = CommandLine.arguments[1]
let endpoint = "PACS@peer:11112"
let uids = (1...6).map { "8.2.\($0)" }
var report: [String: Any] = [:]

struct Response {
    var status: UInt = 0
    var completed: UInt
    var failed: UInt = 0
    var warnings: UInt = 0
    var remaining: UInt = 0
}

/// One retrieve of `study`, as DCMTKQueryNode.move runs it: the listing made
/// before the transfer, the stores the listener completes, the node's final
/// response, the wait for what arrived to be in the index, which catches up
/// at the second look, and the judgement. Answers whether a notice is raised.
func retrieve(_ study: String, listing: RetrieveListing?, status: UInt16? = nil, rows: [RetrieveListedInstance] = [],
              reported: Int = 6, arriving: [String], response: Response?, indexed: [String]) -> (notice: Bool, inventory: RetrieveInventory) {
    let inventory = retrieveInventories.begin(study: study, series: "", endpoint: endpoint, database: directory, instances: rows,
                                              confirmed: listing == .confirmed, reported: reported, listing: listing, listingStatus: status)
    inventory.updateImportedUIDs([])
    for uid in arriving {
        NotificationCenter.default.post(name: Notification.Name("HorosDICOMStoreCompleted"), object: nil,
                                        userInfo: ["uid": uid, "study": study, "series": "8.3", "status": 0])
    }
    if let response {
        inventory.record(operation: "C-MOVE", status: response.status, completed: response.completed, failed: response.failed,
                         warnings: response.warnings, remaining: response.remaining)
    }
    var looks = 0
    let receivedIndexed = inventory.waitForReceivedImports(refreshing: {
        looks += 1
        if looks >= 2 { inventory.updateImportedUIDs(indexed) }
    }, patience: 0.4, cancelled: { false })
    inventory.updateImportedUIDs(indexed)
    if receivedIndexed && inventory.judgeByPeerCounters() { print("log: retrieve complete by the node's counters: \(inventory.summary)") }
    inventory.finish()
    return (inventory.needsAttention || !receivedIndexed, inventory)
}

func expect(_ condition: Bool, _ message: String) {
    if !condition {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

// The node refuses the listing of its series or instances and sends the whole study.
let refused = retrieve("8.1.1", listing: .notImplemented, status: 0xA900, arriving: uids, response: Response(completed: 6), indexed: uids)
expect(!refused.notice, "a study that arrived whole from a node that refuses the listing is reported incomplete: \(refused.inventory.summary)")
expect(!refused.inventory.inventoryConfirmed && refused.inventory.expectedCount == 0 && refused.inventory.judgedByPeerCounters,
       "the inventory of a node that refuses the listing is not judged by its counters")
expect(refused.inventory.summary == "Inventory unconfirmed: 6 local unique instances; 0 UIDs announced. The server refused the listing of its series or instances (C-FIND status 0xA900). Completeness was judged by the server's counters, not by an inventory: 6 sub-operations completed, none failed, with a warning or left; 6 instances arrived, all of them in the index.",
       "the reason is not the one expected: \(refused.inventory.summary)")
report["refused"] = refused.inventory.path

// The node answers every level in success and names nothing.
let empty = retrieve("8.1.2", listing: .empty, arriving: uids, response: Response(completed: 6), indexed: uids)
expect(!empty.notice && empty.inventory.summary.contains("answered the listing of its series or instances without naming any. Completeness was judged by the server's counters"),
       "a study that arrived whole from a node that lists nothing is reported incomplete: \(empty.inventory.summary)")
report["empty"] = empty.inventory.path

// The listing failed: the node may well list its instances, and was not heard.
for (name, listing) in [("failed", RetrieveListing.failed), ("cancelled", .cancelled)] {
    let failed = retrieve("8.1.3." + name, listing: listing, arriving: uids, response: Response(completed: 6), indexed: uids)
    expect(failed.notice && !failed.inventory.judgedByPeerCounters, "a listing that \(name) no longer reports the retrieve")
    expect(failed.inventory.summary.hasSuffix("Completeness cannot be established."), "a listing that \(name): \(failed.inventory.summary)")
    report[name] = failed.inventory.path
}
let failedSummary = retrieve("8.1.3", listing: .failed, arriving: uids, response: Response(completed: 6), indexed: uids).inventory.summary
expect(failedSummary == "Inventory unconfirmed: 6 local unique instances; 0 UIDs announced. The listing of the server's instances failed. Completeness cannot be established.",
       "the notice of a failed listing does not say that it failed: \(failedSummary)")

// Sub-operations that failed, warned or were left, without a listing.
let partial = retrieve("8.1.4", listing: .notImplemented, status: 0xA900, arriving: Array(uids.prefix(4)),
                       response: Response(status: 0xB000, completed: 4, failed: 2), indexed: Array(uids.prefix(4)))
expect(partial.notice && !partial.inventory.judgedByPeerCounters, "failed sub-operations no longer report a retrieve without a listing")
let warned = retrieve("8.1.5", listing: .empty, arriving: uids, response: Response(completed: 5, warnings: 1), indexed: uids)
expect(warned.notice, "a sub-operation that ended in a warning no longer reports the retrieve")
let left = retrieve("8.1.6", listing: .empty, arriving: Array(uids.prefix(5)), response: Response(completed: 5, remaining: 1),
                    indexed: Array(uids.prefix(5)))
expect(left.notice, "a sub-operation left no longer reports the retrieve")
// The node counted six and nothing arrived here: it sent them elsewhere.
let elsewhere = retrieve("8.1.7", listing: .empty, arriving: [], response: Response(completed: 6), indexed: [])
expect(elsewhere.notice, "a retrieve that brought nothing here is not reported")
// And with a listing: the inventory says what is missing.
let rows = uids.map { RetrieveListedInstance(sopInstanceUID: $0, seriesInstanceUID: "8.3") }
let listed = retrieve("8.1.8", listing: .confirmed, rows: rows, arriving: Array(uids.prefix(4)),
                      response: Response(status: 0xB000, completed: 4, failed: 2), indexed: Array(uids.prefix(4)))
expect(listed.notice && listed.inventory.missingUIDs == ["8.2.5", "8.2.6"] && !listed.inventory.judgedByPeerCounters,
       "failed sub-operations no longer report a retrieve with a listing")
let whole = retrieve("8.1.9", listing: .confirmed, rows: rows, arriving: uids, response: Response(completed: 6), indexed: uids)
expect(!whole.notice && whole.inventory.isComplete && !whole.inventory.judgedByPeerCounters, "a listed study that arrived whole is reported")

// An instance arrived and is not in the index once the wait has given up.
let unindexed = retrieve("8.1.10", listing: .notImplemented, status: 0xC000, arriving: uids, response: Response(completed: 6),
                         indexed: Array(uids.prefix(5)))
expect(unindexed.notice && !unindexed.inventory.judgedByPeerCounters && unindexed.inventory.receivedAwaitingImportCount == 1,
       "an instance that arrived and is not in the index no longer reports the retrieve")

// What follows: the study the counters judged complete is not asked for again
// while the node reports the same count, by a retrieve of what is missing or
// by the automatic query; a manifest written before, which does not say how
// its listing ended, is.
expect(refused.inventory.standsByPeerCounters(reported: 6) && !refused.inventory.standsByPeerCounters(reported: 7),
       "the verdict does not follow the count the node reports")
expect(AutoQueryRetrieveInventory.judgedByPeerCounters(refused.inventory, reported: 6)
       == AutoQueryRetrieveInventory(expected: 6, imported: 6, isSatisfied: true), "the automatic query is not told the study is here")
let before = retrieve("8.1.11", listing: nil, arriving: uids, response: Response(completed: 6), indexed: uids)
expect(before.notice && !before.inventory.standsByPeerCounters(reported: 6) && before.inventory.discoveryState.isEmpty,
       "an inventory that does not say how its listing ended is judged by counters")
// A second retrieve of the same study is judged anew, and can fail.
let again = retrieve("8.1.1", listing: .notImplemented, status: 0xA900, arriving: Array(uids.prefix(3)),
                     response: Response(status: 0xB000, completed: 3, failed: 3), indexed: uids)
expect(again.inventory === refused.inventory && again.notice && !again.inventory.standsByPeerCounters(reported: 6),
       "a retrieve that failed keeps the verdict of the one before it")
report["again"] = again.inventory.path
print("json: " + String(decoding: try JSONSerialization.data(withJSONObject: report), as: UTF8.self))
'''

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(2)

with tempfile.TemporaryDirectory(prefix='horos-unlisted-node-') as directory:
    work = Path(directory)
    database = work / 'database'
    database.mkdir()
    built = None
    try:
        sources = retrieve_inventory_harness.swiftc_arguments(work / 'harness')
        (work / 'main.swift').write_text(DRIVER)
        built = subprocess.run(['xcrun', 'swiftc'] + sources + [str(work / 'main.swift'), '-o', str(work / 'check')],
                               capture_output=True, text=True, timeout=900)
    except subprocess.CalledProcessError as error:
        failures.append('IsiXDICOMNetwork does not build: %s' % ((error.stderr or error.stdout or str(error)).strip().splitlines() or ['?'])[-1])
    if built is not None and built.returncode:
        errors = [line for line in built.stderr.splitlines() if ' error: ' in line]
        failures.append('the inventory does not build with the driver: ' + (errors or built.stderr.strip().splitlines() or ['?'])[0])
    elif built is not None:
        run = subprocess.run([str(work / 'check'), str(database)], capture_output=True, text=True, timeout=120)
        if run.returncode:
            failures.append('the retrieves: ' + (run.stderr.strip().splitlines() or ['failed'])[-1])
        else:
            logged = [line for line in run.stdout.splitlines() if line.startswith('log: ')]
            check(len(logged) == 2 and all('Completeness was judged by the server\'s counters' in line for line in logged),
                  'only the two clean retrieves without a listing are logged as judged by the counters: %d' % len(logged))
            paths = json.loads(next(line for line in run.stdout.splitlines() if line.startswith('json: '))[6:])
            manifest = {name: json.loads(Path(path).read_text()) for name, path in paths.items()}
            # Read after the second, failed retrieve of the same study: the verdict is gone.
            check(manifest['again'].get('completeness') is None and manifest['again'].get('discovery') == 'not implemented'
                  and manifest['again'].get('listingStatus') == 0xA900,
                  'a retrieve that failed after one the counters judged keeps its verdict in the manifest')
            verdict = manifest['empty'].get('completeness') or {}
            check(manifest['empty'].get('discovery') == 'empty' and manifest['empty'].get('inventoryConfirmed') is False
                  and manifest['empty'].get('listingStatus') is None,
                  'the manifest does not say the listing was empty: %s' % manifest['empty'].get('discovery'))
            check(verdict == {'judgedBy': 'peer counters', 'operations': 1, 'completed': 6, 'received': 6, 'indexed': 6, 'reported': 6},
                  'the manifest does not say completeness was judged by the node\'s counters: %s' % verdict)
            check(any(response.get('operation') == 'C-MOVE' and response.get('completed') == '6' and response.get('failed') == '0'
                      for response in manifest['empty'].get('peerResponses') or []),
                  'the manifest does not keep the counters it was judged by')
            for name in ('failed', 'cancelled'):
                check(manifest[name].get('discovery') == name and manifest[name].get('completeness') is None,
                      'the manifest of a listing that %s: %s' % (name, manifest[name].get('discovery')))

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: a DIMSE retrieve keeps how its listing ended; a study that arrived whole from a node that refuses the listing, or '
      'answers it empty, is judged by the node\'s counters, logged and written in the manifest without a notice, and not asked for '
      'again; a listing that failed, sub-operations that failed, warned or were left, and an instance not in the index keep the notice')
