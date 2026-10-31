#!/usr/bin/env python3
"""Quitting stops the INCOMING import before exit() destroys DCMTK.

Quitting during a WADO retrieve crashed: the main thread was in exit(),
destroying DCMTK's data dictionary and loggers, while the thread "Adding
incoming files..." was still reading a DICOM file and read the freed logger.
finishTermination cancelled and waited only for the threads ThreadsManager
listed, and an import is listed late: once it has a file and sees another,
and only after the main thread runs the message that adds it, which it no
longer does while quitting. The import checks its cancellation between files;
the one that crashed had never been cancelled.

The same wait never saw its count fall: finished threads leave the list on the
main run loop, which the wait does not run, so quitting always froze the full
ten seconds once the "Background Operations" alert had been shown.

What must stay true:

- every import of the folder passes HorosIncomingImportGate, with an admission
  that names the thread to cancel; once stopped, the gate admits no import,
  cancels those inside and lets quitting wait for them, whether or not
  ThreadsManager lists them, and whichever thread gives the admission back;
- finishTermination stops the gate, through DatabaseIngest, which also stops the
  scheduler of the passes, before it waits for the background threads, and waits
  for the gate before NSApp.terminate;
- the copy and the scan of a medium pass the gate too, and each batch of the
  copy as a part of it, on its own thread: never refused, so that what was
  copied before quitting is not left out, and waited for;
- the wait drops finished threads on each pass.

The gate itself is compiled and run.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text, class_text  # noqa: E402
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def body(source, signature):
    at = source.find(signature)
    if at < 0:
        return ''
    opening = source.index('{', at)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[opening:index + 1]
    return ''


# DicomDatabase is Swift: the scan of the incoming folder is
# IncomingAdmission.swift. The @finally that leaves the gate is the
# code after the attempt, before the exception it caught goes on.
database = class_text('DicomDatabase')
admission = source_text('IncomingAdmission')
signature = 'func importFolder(showGUI: NSNumber!, listenerCompressionSettings: Int32) -> Int {'
wrapper = body(admission, signature)
check(wrapper, 'importFilesFromIncomingDir:listenerCompressionSettings: not found')
check(re.search(r'guard let admission = IncomingImportGate\.shared\.admit\(cancelling: Thread\.current\) else \{\s*return 0\s*\}', wrapper),
      'the import does not ask the gate before it starts, naming the thread to cancel')
check(re.search(r'let raised = HorosObjCException\.caught \{[^}]*\}\s*IncomingImportGate\.shared\.leave\(admission\)\s*if let raised \{ raised\.raise\(\) \}', wrapper),
      'the import does not leave the gate whatever happens')
check('importAdmittedFilesFromIncomingDir(' in wrapper, 'the gate does not wrap the import itself')
check(admission.count(signature) == 1,
      'more than one implementation of the import that takes the compression settings')
ingest = source_text('DatabaseIngest')
initiate = body(admission, 'func initiateImportFilesFromIncomingDirUnlessAlreadyImporting() {')
check('schedulePass(over: self)' in initiate, 'the dynamic method no longer reaches the scheduler')
schedule = body(ingest, 'func schedulePass(over database: DicomDatabase) {')
check(re.search(r'if IncomingImportGate\.shared\.isStopped \{\s*return\s*\}', schedule),
      'the import timer still starts imports once quitting has begun')
check('onMainRunLoop' in schedule and 'yieldsToViewers' in schedule[schedule.index('onMainRunLoop'):],
      'a request no longer asks about the viewers on the main run loop')
scan = body(admission, 'private func importAdmittedFilesFromIncomingDir(')
check(re.search(r'if !scanFailed, enumer\.nextObject\(\) != nil', scan) and 'scanFailed = true' in scan,
      'a scan that raised asks for the next pass at once, and the passes never end')
ready = body(ingest, 'func isReadyForPass() -> Bool {')
check('IncomingImportGate.shared.isStopped' in ready, 'a request waiting in the scheduler still starts a pass once quitting has begun')
quit = body(ingest, 'func stop() {')
check(-1 < quit.find('IncomingImportGate.shared.stop()') < quit.find('scheduler.stop()'),
      'quitting does not close the gate at once, before it tells the scheduler')

controller = class_text('AppController')
# The rest of quitting is ApplicationLifecycle's.
finish = body(controller, 'func finishTermination(_ sender: Any?)')
check(finish, 'finishTermination not found')
stop = finish.find('processGraph.databaseIngest.stop()')
listeners = finish.find('dicomListener.stopListeners(before:')
loop = finish.find('while Date.timeIntervalSinceReferenceDate - start < 10')
wait = finish.find('IncomingImportGate.shared.waitUntilIdle(before:')
terminate = finish.find('NSApp.terminate(sender)')
check(-1 < stop < listeners, 'finishTermination does not stop the incoming import first')
check(-1 < loop < wait < terminate, 'finishTermination does not wait for the incoming import after the threads and before NSApp.terminate')
waiting = finish[loop:wait]
check(waiting.find('cleanupFinishedThreads(nil)') > -1
      and waiting.find('cleanupFinishedThreads(nil)') < waiting.find('if threads.isEmpty { break }'),
      'the wait does not drop finished threads before it counts them')

project = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='latin1')
check('IncomingImportGate.swift in Sources' in project, 'IncomingImportGate.swift is not in the application target')

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(2)

driver = r'''
import Foundation

func expect(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message) }
}
func elapsed(_ start: Date) -> TimeInterval { Date().timeIntervalSince(start) }

// An import reading file after file, as -addFilesAtPaths: does, checking its
// thread's cancellation between files. No ThreadsManager anywhere. The
// admission is handed back from another thread when `leavesElsewhere` says so.
final class Importer: @unchecked Sendable {
    let gate: IncomingImportGate
    let ignoresCancel: Bool
    let leavesElsewhere: Bool
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _sawCancel = false
    private var _files = 0
    var sawCancel: Bool { lock.withLock { _sawCancel } }
    var files: Int { lock.withLock { _files } }
    init(gate: IncomingImportGate, ignoresCancel: Bool = false, leavesElsewhere: Bool = false) {
        self.gate = gate; self.ignoresCancel = ignoresCancel; self.leavesElsewhere = leavesElsewhere
    }
    func start(for seconds: TimeInterval = 30) {
        let thread = Thread { [self] in
            guard let admission = gate.admit(cancelling: Thread.current) else { started.signal(); finished.signal(); return }
            started.signal()
            let end = Date(timeIntervalSinceNow: seconds)
            while Date() < end {
                Thread.sleep(forTimeInterval: 0.01)
                lock.withLock { _files += 1 }
                if Thread.current.isCancelled {
                    lock.withLock { _sawCancel = true }
                    if !ignoresCancel { break }
                }
            }
            if leavesElsewhere {
                let gate = gate, finished = finished
                Thread.detachNewThread { gate.leave(admission); finished.signal() }
            } else {
                gate.leave(admission)
                finished.signal()
            }
        }
        thread.start()
        started.wait()
    }
}

do { // nothing importing: the wait returns at once
    let gate = IncomingImportGate()
    let start = Date()
    expect(gate.waitUntilIdle(before: Date(timeIntervalSinceNow: 5)), "an idle gate is not idle")
    expect(elapsed(start) < 0.5, "an idle gate made quitting wait")
}

do { // an import no manager lists is cancelled and waited for
    let gate = IncomingImportGate()
    let importer = Importer(gate: gate)
    importer.start()
    Thread.sleep(forTimeInterval: 0.1)
    expect(!gate.isStopped, "the gate is stopped before quitting")
    gate.stop()
    expect(gate.isStopped, "the gate is not stopped after stop()")
    let start = Date()
    expect(gate.waitUntilIdle(before: Date(timeIntervalSinceNow: 5)), "the cancelled import was still inside after 5 s")
    expect(elapsed(start) < 1, "waiting for a cancelled import took \(elapsed(start)) s")
    expect(importer.sawCancel, "the import was never cancelled")
    let files = importer.files
    Thread.sleep(forTimeInterval: 0.1)
    expect(importer.files == files, "the import went on reading after the wait returned")
}

do { // an import started after the stop never starts
    let gate = IncomingImportGate()
    gate.stop()
    let importer = Importer(gate: gate)
    importer.start()
    expect(importer.finished.wait(timeout: .now() + 1) == .success, "a refused import did not return")
    expect(importer.files == 0, "an import read files after quitting began")
    expect(gate.admit(cancelling: .current) == nil, "the stopped gate admitted the main thread")
}

do { // an import that does not stop: the deadline holds
    let gate = IncomingImportGate()
    let importer = Importer(gate: gate, ignoresCancel: true)
    importer.start(for: 3)
    gate.stop()
    let start = Date()
    expect(!gate.waitUntilIdle(before: Date(timeIntervalSinceNow: 0.3)), "an import still running counted as gone")
    expect(elapsed(start) >= 0.29 && elapsed(start) < 1.5, "the deadline was not kept: \(elapsed(start)) s")
    _ = importer.finished.wait(timeout: .now() + 5)
}

do { // a thread importing from inside an import is inside until it leaves both
    let gate = IncomingImportGate()
    guard let outer = gate.admit(cancelling: .current), let inner = gate.admit(cancelling: .current) else {
        expect(false, "the gate refused a nested import")
        exit(0)
    }
    expect(outer != inner, "two imports share an admission")
    gate.leave(inner)
    expect(!gate.waitUntilIdle(before: Date(timeIntervalSinceNow: 0.05)), "the outer import counted as gone")
    gate.leave(outer)
    expect(gate.waitUntilIdle(before: Date(timeIntervalSinceNow: 0.05)), "the gate is not idle after both left")
}

do { // an import may end on another thread than the one that entered
    let gate = IncomingImportGate()
    let importer = Importer(gate: gate, leavesElsewhere: true)
    importer.start()
    gate.stop()
    expect(gate.waitUntilIdle(before: Date(timeIntervalSinceNow: 5)), "an admission given back from another thread still counted as inside")
    expect(importer.sawCancel, "the import was not cancelled through its admission")
}
do { // a part of an import inside: never refused, waited for, and cancelled only by a stop that comes after it
    let gate = IncomingImportGate()
    guard let whole = gate.admit(cancelling: .current) else {
        expect(false, "the gate refused the import")
        exit(0)
    }
    let before = Thread { }
    let early = gate.admitPart(cancelling: before)
    gate.stop()
    expect(before.isCancelled, "the stop did not cancel a part already inside")
    let after = Thread { }
    let late = gate.admitPart(cancelling: after)
    expect(!after.isCancelled, "a part that came after the stop was cancelled: what was copied would be left out")
    gate.leave(early)
    gate.leave(whole)
    expect(!gate.waitUntilIdle(before: Date(timeIntervalSinceNow: 0.05)), "a part counted as gone")
    gate.leave(late)
    expect(gate.waitUntilIdle(before: Date(timeIntervalSinceNow: 0.05)), "the gate is not idle after the parts left")
}
print("done")
'''
with tempfile.TemporaryDirectory() as folder:
    folder = Path(folder)
    (folder / 'main.swift').write_text(driver)
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', str(root / 'Horos/Sources/IncomingImportGate.swift'),
                            str(folder / 'main.swift'), '-o', str(folder / 'check')], capture_output=True, text=True)
    check(build.returncode == 0, 'IncomingImportGate.swift and its driver compile\n' + build.stderr[-3000:])
    if build.returncode == 0:
        run = subprocess.run([str(folder / 'check')], capture_output=True, text=True, timeout=60)
        check(run.returncode == 0 and run.stdout.strip().endswith('done'), 'the driver runs\n' + run.stdout + run.stderr[-2000:])
        failures.extend(line[len('FAIL: '):] for line in run.stdout.splitlines() if line.startswith('FAIL: '))

# The copy and the scan of a medium read files as the folder's import does, so
# they hold admissions too: the scan, the copy, and each batch on its own thread,
# which the copy's cancellation does not reach. And an exception leaves the gate.
ingest = source_text('DatabaseIngest')
admitted = body(ingest, 'func whileAdmitted<Result>(')
check('IncomingImportGate.shared.admit(cancelling: Thread.current)' in admitted, 'the single entry does not admit the calling thread')
check(admitted.find('HorosObjCException.caught') < admitted.find('.leave(admission)') < admitted.find('exception?.raise()'),
      'an exception of what is admitted never gives the admission back')
scan = source_text('MediaVolumeScan')
check('ingest.whileAdmitted { scanned() } ?? false' in scan, 'the scan of a medium passes no gate')
job = source_text('MediaImportJob')
check('ingest.whileAdmitted { importing() } ?? MediaImportOutcome(stopped: true)' in job, 'the copy passes no gate')
check('ingest.asPartOfAdmittedImport {' in body(job, 'func index(_ batch: MediaImportBatch)'), 'a batch of the copy passes no gate')
part = body(ingest, 'func asPartOfAdmittedImport(')
check('admitPart(cancelling: Thread.current)' in part and part.find('HorosObjCException.caught') < part.find('.leave(admission)') < part.find('exception?.raise()'),
      'a part of an import does not give its admission back when it raises')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: quitting stops, cancels and waits for the incoming import, the copy and the scan of a medium, listed or not; '
      'the wait drops finished threads')
