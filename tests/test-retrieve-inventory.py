#!/usr/bin/env python3
"""Inventory completeness follows imported identities, never transport/frame counts.

A retrieve's inventory is judged once what it received is in the index:
received files are indexed by the importer's timer after the transfer returns,
and judged at once a retrieve that brought every instance was recorded as
incomplete. Modelled here with an index that catches up in steps; the move waits
before its final refresh, and warns about received instances the index never took.
"""
import subprocess,sys,tempfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402
import retrieve_inventory_harness  # noqa: E402
root=Path(__file__).resolve().parents[1]
# The query node is Swift; the move judges its inventory in DCMTKQueryNode+Retrieve.swift,
# and the inventory is IsiXDICOMNetwork's RetrieveInventory.
node=(root/'Horos/Sources/DCMTKQueryNode+Retrieve.swift').read_text()
final=node[node.index("        // How the retrieve ended, once what it received is in the index."):]
final=final[:final.index('Self.postNotice(NSLocalizedString("Retrieve Incomplete"')]
assert 'waitForReceivedImports(refreshing:' in final, 'the move judges its inventory without waiting for the received instances to be indexed'
assert final.index('waitForReceivedImports(refreshing:') < final.index('inventory.finish()'), 'the wait comes after the inventory is finished'
assert 'if !Thread.isMainThread {' in final, 'the wait may block the main thread'
assert '|| !receivedIndexed' in final, 'received instances the index never took do not raise the warning'
assert 'importInProgress: { DatabaseIngest.process.isImporting }' in final
driver=r'''
import Foundation
import CoreData
let directory=CommandLine.arguments[1]
let rows=(1...10).map { ["uid":"1.2.\($0)","series":"1.3"] }
let m=RetrieveInventory.begin(study:"1.1",series:"",endpoint:"PACS@localhost:104",database:directory,instances:rows,confirmed:true)
assert(m.beginImportRefresh() && !m.beginImportRefresh())
NotificationCenter.default.post(name:.NSManagedObjectContextDidSave,object:nil)
assert(m.beginImportRefresh() && !m.beginImportRefresh())
NotificationCenter.default.post(name:.NSManagedObjectContextObjectsDidChange,object:nil)
assert(m.beginImportRefresh())
m.invalidateImportRefresh();assert(m.beginImportRefresh())
m.updateImportedUIDs([])
for i in 1...8 {m.record(uid:"1.2.\(i)",status:0)}
m.record(uid:"1.2.1",status:0);m.record(uid:"1.2.9",status:0xa900)
// Ten local rows, eight expected UIDs: duplicate frames/alien identities cannot fill the gaps.
m.updateImportedUIDs((1...8).map{"1.2.\($0)"}+["9.8","9.9"])
assert(m.matchesReportedCount(10) && m.matchesReportedCount(0) && !m.matchesReportedCount(11))
assert(m.importedCount==8 && m.localUniqueCount==10 && !m.isComplete && m.needsAttention)
assert(m.missingUIDs==["1.2.10","1.2.9"] && m.duplicateUIDs==["1.2.1"] && m.rejectedUIDs==["1.2.9"])
assert(m.unexpectedUIDs==["9.8","9.9"] && Set(m.missingSeries["1.3"]!)==Set(m.missingUIDs))
m.finish()
let snapshot=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:m.path))) as! [String:Any]
assert(snapshot["missingUIDs"] as! [String]==m.missingUIDs)
let retry=RetrieveInventory.begin(study:"1.1",series:"",endpoint:"PACS@localhost:104",database:directory,instances:rows,confirmed:true)
assert(retry === m) // every query window sees the current snapshot
retry.updateImportedUIDs((1...8).map{"1.2.\($0)"})
retry.record(uid:"1.2.9",status:0);retry.record(uid:"1.2.10",status:0)
assert(!retry.needsAttention && !retry.isComplete) // received, but not imported yet
retry.updateImportedUIDs((1...10).map{"1.2.\($0)"})
assert(retry.isComplete && retry.missingUIDs.isEmpty && retry.rejectedUIDs==["1.2.9"])
assert(retry.duplicateUIDs==["1.2.1"])
retry.finish()
let unknown=RetrieveInventory.begin(study:"2.1",series:"",endpoint:"PACS",database:directory,instances:rows,confirmed:false)
unknown.updateImportedUIDs((1...10).map{"1.2.\($0)"})
assert(!unknown.isComplete && unknown.needsAttention && unknown.unexpectedUIDs.isEmpty)
let concurrent=RetrieveInventory.begin(study:"3.1",series:"",endpoint:"PACS",database:directory,instances:rows,confirmed:true)
DispatchQueue.concurrentPerform(iterations:32){_ in
 NotificationCenter.default.post(name:Notification.Name("HorosDICOMStoreCompleted"),object:nil,userInfo:["uid":"1.2.1","study":"3.1","series":"1.3","status":0])
}
assert(concurrent.duplicateUIDs==["1.2.1"])
concurrent.finish();unknown.finish()
let first=RetrieveInventory.begin(study:"5.1",series:"",endpoint:"PACS",database:directory,instances:rows,confirmed:true)
let second=RetrieveInventory.begin(study:"5.1",series:"",endpoint:"PACS",database:directory,instances:rows,confirmed:true)
assert(first === second);first.record(uid:"1.2.1",status:0);first.finish()
NotificationCenter.default.post(name:Notification.Name("HorosDICOMStoreCompleted"),object:nil,userInfo:["uid":"1.2.1","study":"5.1","series":"1.3","status":0])
assert(second.duplicateUIDs==["1.2.1"]);second.finish()
weak var released: RetrieveInventory?
autoreleasepool {
 let temporary=RetrieveInventory.begin(study:"4.1",series:"",endpoint:"PACS",database:directory,instances:rows,confirmed:true)
 released=temporary;temporary.finish()
}
assert(released==nil) // old studies do not retain all their UIDs globally forever
// Every missing instance received, the index catching up in three steps 0.3 s apart.
let delayedRows=(1...30).map { ["uid":"7.2.\($0)","series":"7.3"] }
let delayed=RetrieveInventory.begin(study:"7.1",series:"",endpoint:"PACS",database:directory,instances:delayedRows,confirmed:true)
let index=NSLock()
var indexed=Set((1...30).filter { $0 % 2 == 1 }.map { "7.2.\($0)" })
let refresh: () -> Void = { index.lock(); let uids=Array(indexed); index.unlock(); delayed.updateImportedUIDs(uids) }
refresh()
for i in stride(from:2,through:30,by:2) {
 NotificationCenter.default.post(name:Notification.Name("HorosDICOMStoreCompleted"),object:nil,userInfo:["uid":"7.2.\(i)","study":"7.1","series":"7.3","status":0])
}
refresh()
// Judged at once, the retrieve is incomplete although nothing is missing from the transfer.
assert(!delayed.isComplete && delayed.importedCount==15 && delayed.receivedAwaitingImportCount==15 && !delayed.needsAttention)
Thread { for step in 0..<3 { Thread.sleep(forTimeInterval:0.3); index.lock(); for i in stride(from:2,through:30,by:2) where (i/2)%3==step { indexed.insert("7.2.\(i)") }; index.unlock() } }.start()
var started=Date()
assert(delayed.waitForReceivedImports(refreshing:refresh,patience:2,cancelled:{ false }))
var waited=Date().timeIntervalSince(started)
assert(waited>=0.8 && waited<2.5, "waited \(waited) s for an index that took 0.9 s")
assert(delayed.isComplete && delayed.importedCount==30 && delayed.receivedAwaitingImportCount==0 && !delayed.needsAttention)
delayed.finish()
// A single batch can work longer than the idle timeout without committing a UID.
let busy=RetrieveInventory.begin(study:"7.4",series:"",endpoint:"PACS",database:directory,instances:delayedRows,confirmed:true)
busy.updateImportedUIDs([])
for row in delayedRows { busy.record(uid:row["uid"]!,status:0) }
started=Date()
let busyRefresh: () -> Void = {
 if Date().timeIntervalSince(started)>=1.2 { busy.updateImportedUIDs(delayedRows.map { $0["uid"]! }) }
}
assert(busy.waitForReceivedImports(refreshing:busyRefresh,importInProgress:{ true },patience:0.4,cancelled:{ false }))
assert(Date().timeIntervalSince(started)>=1.2 && busy.isComplete)
busy.finish()
// Really incomplete: one instance never sent. Nothing received is left to wait for, and it still needs attention.
let omitted=RetrieveInventory.begin(study:"8.1",series:"",endpoint:"PACS",database:directory,instances:delayedRows,confirmed:true)
omitted.updateImportedUIDs([])
for i in 1...29 { omitted.record(uid:"7.2.\(i)",status:0) }
omitted.updateImportedUIDs((1...29).map { "7.2.\($0)" })
started=Date()
assert(omitted.waitForReceivedImports(refreshing:{},patience:2,cancelled:{ false }))
assert(Date().timeIntervalSince(started)<0.5 && !omitted.isComplete && omitted.needsAttention && omitted.missingUIDs==["7.2.30"])
omitted.finish()
// Received but never indexed: the wait gives up after its patience, and says so.
let rejected=RetrieveInventory.begin(study:"9.1",series:"",endpoint:"PACS",database:directory,instances:delayedRows,confirmed:true)
rejected.updateImportedUIDs([])
for i in 1...30 { rejected.record(uid:"7.2.\(i)",status:0) }
rejected.updateImportedUIDs((1...28).map { "7.2.\($0)" })
started=Date()
assert(!rejected.waitForReceivedImports(refreshing:{},patience:0.5,cancelled:{ false }))
waited=Date().timeIntervalSince(started)
assert(waited>=0.5 && waited<1.5 && rejected.receivedAwaitingImportCount==2, "gave up after \(waited) s")
// Cancelled: no wait at all.
started=Date()
assert(!rejected.waitForReceivedImports(refreshing:{},patience:5,cancelled:{ true }) && Date().timeIntervalSince(started)<0.5)
// Work ends without indexing the received files: the idle timeout still fires.
started=Date()
assert(!rejected.waitForReceivedImports(refreshing:{},importInProgress:{ Date().timeIntervalSince(started)<0.8 },
                                      patience:0.5,cancelled:{ false }))
waited=Date().timeIntervalSince(started)
assert(waited>=1.1 && waited<2, "busy worker suppressed the idle timeout: \(waited)")
// Cancellation interrupts even a worker that remains busy.
started=Date()
assert(!rejected.waitForReceivedImports(refreshing:{},importInProgress:{ true },patience:5,
                                      cancelled:{ Date().timeIntervalSince(started)>=0.3 }))
assert(Date().timeIntervalSince(started)<0.8)
rejected.finish()
print("ok: exact UID reconciliation, duplicate/rejection history, pending import, unknown inventory, concurrent store events and the wait for received instances to be indexed")
'''
ACTIVITY=r'''
import Foundation
import IsiXContracts
import IsiXDatabase
import Synchronization
// A pass the scheduler runs; it holds the import lock only once it has started.
struct DatabaseIngest {
 nonisolated(unsafe) static var passRunning = false
 func isPassRunning(over database: DicomDatabase) -> Bool { Self.passRunning }
}
final class DicomDatabase: NSObject {
 var importFilesFromIncomingDirLock: NSRecursiveLock? = NSRecursiveLock()
 var processFilesLock: NSRecursiveLock? = NSRecursiveLock()
}
struct Conversion {
 let queue: ConversionQueue
 var isConverting: Bool { queue.isConverting("db") }
}
struct IncomingAdmission {
 let database: DicomDatabase
 let ingest = DatabaseIngest()
 let conversion: Conversion
__ACTIVITY__
}
// A batch stays until the test lets it end, as a conversion stays until the
// last file of its fallback import.
final class Worker: ConversionRunning, @unchecked Sendable {
 let conversionIdentifier = "db"
 let started = DispatchSemaphore(value: 0)
 let finish = DispatchSemaphore(value: 0)
 func filesQueued(_ count: Int) {}
 func run(_ batch: FileConversionBatch) async {
  started.signal()
  await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
   Thread.detachNewThread { [self] in finish.wait(); done.resume() }
  }
 }
}
func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); exit(1) } }
let queue=ConversionQueue()
let database=DicomDatabase()
let db=IncomingAdmission(database: database, conversion: Conversion(queue: queue))
check(!db.isInProgress, "idle database reported busy")
// Between the scheduler starting a pass and the pass taking the lock, and with
// the question asked on the thread that holds that recursive lock.
DatabaseIngest.passRunning = true
check(db.isInProgress, "a pass the scheduler started was missed")
DatabaseIngest.passRunning = false
check(!db.isInProgress, "a finished pass stayed busy")
for lock in [database.importFilesFromIncomingDirLock!, database.processFilesLock!] {
 let locked=DispatchSemaphore(value: 0), release=DispatchSemaphore(value: 0), done=DispatchSemaphore(value: 0)
 Thread.detachNewThread {
  lock.lock(); locked.signal()
  release.wait(); lock.unlock(); done.signal()
 }
 locked.wait()
 check(db.isInProgress, "active import/conversion was missed")
 release.signal(); done.wait()
 check(!db.isInProgress, "completed work stayed busy")
}
// Queued, converting and between two batches, with no pass and no lock: what a
// C-MOVE with the listener's compression sees once the scan has handed its files over.
let worker=Worker()
queue.enqueue(FileConversionBatch(files: ["a.dcm"], mode: .compress, destination: "INCOMING", isFromScan: true), runner: worker)
check(db.isInProgress, "a queued conversion was missed before the queue's actor ran")
queue.enqueue(FileConversionBatch(files: ["b.dcm"], mode: .decompress, destination: "INCOMING", isFromScan: true), runner: worker)
worker.started.wait()
check(db.isInProgress, "a conversion under way was missed")
worker.finish.signal()
worker.started.wait()
check(db.isInProgress, "the second batch of the queue was missed")
worker.finish.signal()
check(queue.waitUntilIdle("db") || !db.isInProgress, "the queue did not end")
check(!db.isInProgress, "a finished conversion stayed busy")
'''
with tempfile.TemporaryDirectory(prefix='horos-inventory-') as d:
 p=Path(d);(p/'main.swift').write_text(driver)
 subprocess.run(['xcrun','swiftc',*retrieve_inventory_harness.swiftc_arguments(p/'harness'),str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),d],check=True,timeout=20)
 # Compile the real activity getter against its locks and the real conversion
 # queue: the getter is IncomingAdmission.swift, and the queue IsiXDatabase's.
 def member(relative, opening):
  text=(root/relative).read_text()
  at=text.index(opening); depth=0
  for i in range(text.index('{',at),len(text)):
   depth+={'{':1,'}':-1}.get(text[i],0)
   if depth==0: return text[at:i+1]
 activity=member('Horos/Sources/IncomingAdmission.swift','var isInProgress: Bool {')
 (p/'activity.swift').write_text(ACTIVITY.replace('__ACTIVITY__',activity))
 modules=isix_modules.module_flags('IsiXDatabase',p/'modules')
 subprocess.run(['xcrun','swiftc','-swift-version','5',*modules,str(p/'activity.swift'),'-o',str(p/'activity')],check=True)
 subprocess.run([str(p/'activity')],check=True,timeout=10)
