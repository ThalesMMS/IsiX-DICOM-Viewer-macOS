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

- every import of the folder passes HorosIncomingImportGate; once stopped, the
  gate admits no import, cancels the threads inside and lets quitting wait for
  them, whether or not ThreadsManager lists them;
- finishTermination stops the gate before it waits for the background threads,
  and waits for the gate before NSApp.terminate;
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
from sources import source_text  # noqa: E402
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


database = source_text('DicomDatabase')
wrapper = body(database, '-(NSInteger)importFilesFromIncomingDir: (NSNumber*) showGUI\n           listenerCompressionSettings:')
check(wrapper, 'importFilesFromIncomingDir:listenerCompressionSettings: not found')
check(re.search(r'if \(!\[\[HorosIncomingImportGate shared\] enter\]\)\s*return 0;', wrapper),
      'the import does not ask the gate before it starts')
check(re.search(r'@finally\s*\{\s*\[\[HorosIncomingImportGate shared\] leave\];', wrapper),
      'the import does not leave the gate whatever happens')
check('importAdmittedFilesFromIncomingDir:' in wrapper, 'the gate does not wrap the import itself')
check(database.count('-(NSInteger)importFilesFromIncomingDir: (NSNumber*) showGUI\n           listenerCompressionSettings:') == 1,
      'more than one implementation of the import that takes the compression settings')
initiate = body(database, '-(void)initiateImportFilesFromIncomingDirUnlessAlreadyImporting')
check(re.search(r'\[\[HorosIncomingImportGate shared\] isStopped\]\)\s*return;', initiate),
      'the import timer still starts imports once quitting has begun')

controller = source_text('AppController')
finish = body(controller, 'func finishTermination(_ sender: Any!)')
check(finish, 'finishTermination not found')
stop = finish.find('IncomingImportGate.shared.stop()')
listeners = finish.find('AppController.stopListeners(before:')
loop = finish.find('while Date.timeIntervalSinceReferenceDate - t < 10')
wait = finish.find('IncomingImportGate.shared.waitUntilIdle(before:')
terminate = finish.find('NSApp.terminate(sender)')
check(-1 < stop < listeners, 'finishTermination does not stop the incoming import first')
check(-1 < loop < wait < terminate, 'finishTermination does not wait for the incoming import after the threads and before NSApp.terminate')
waiting = finish[loop:wait]
check(waiting.find('cleanupFinishedThreads(nil)') > -1
      and waiting.find('cleanupFinishedThreads(nil)') < waiting.find('threads()?.count ?? 0) == 0 { break }'),
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
// thread's cancellation between files. No ThreadsManager anywhere.
final class Importer: @unchecked Sendable {
    let gate: IncomingImportGate
    let ignoresCancel: Bool
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _sawCancel = false
    private var _files = 0
    var sawCancel: Bool { lock.withLock { _sawCancel } }
    var files: Int { lock.withLock { _files } }
    init(gate: IncomingImportGate, ignoresCancel: Bool = false) { self.gate = gate; self.ignoresCancel = ignoresCancel }
    func start(for seconds: TimeInterval = 30) {
        let thread = Thread { [self] in
            guard gate.enter() else { started.signal(); finished.signal(); return }
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
            gate.leave()
            finished.signal()
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
    expect(!gate.enter(), "the stopped gate admitted the main thread")
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
    expect(gate.enter() && gate.enter(), "the gate refused a nested import")
    gate.leave()
    expect(!gate.waitUntilIdle(before: Date(timeIntervalSinceNow: 0.05)), "the outer import counted as gone")
    gate.leave()
    expect(gate.waitUntilIdle(before: Date(timeIntervalSinceNow: 0.05)), "the gate is not idle after both left")
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

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: quitting stops, cancels and waits for the incoming import, listed or not; the wait drops finished threads')
