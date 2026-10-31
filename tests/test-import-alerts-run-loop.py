#!/usr/bin/env python3
"""With an alert of an import open, the main queue and the main actor go on serving.

alertRejectedReports and alertIncompleteImport (ImportFeedback.swift)
tell what an import or a rebuild could not take. They ran their modal inside a
block of the main queue, which then served neither that queue nor the main actor
until someone answered: on a Mac with nobody at it, the whole application waited
for a click. They now open from the main run loop.

The two methods are cut from the source and compiled with the real
MainActorCallbacks.swift. The modal is a stand-in that does what a modal does to
the main thread: it turns the run loop until it is answered. While it is open it
asks the main queue and the main actor for a block each, and answers when both
came, or after two seconds. So a method that goes back into a block of the queue
shows here as what it does in the application.

`<git revision>` as an optional argument reads the source of that revision, the
negative control.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
SOURCE = 'Horos/Sources/ImportFeedback.swift'
failures = []


def read():
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{SOURCE}']).decode('utf-8')
    return (root / SOURCE).read_text()


def method(source, name):
    found = re.search(r'    func %s\(.*?^    }\n' % name, source, re.S | re.M)
    if not found:
        raise SystemExit('FAIL: %s is not where this test reads it' % name)
    return found.group(0)


DOUBLES = r"""
import Foundation

func emit(_ key: String, _ value: String) { print("\(key)\t\(value)") }

nonisolated(unsafe) var opened = 0

enum HorosAlertPanel {
    static func run(title: String?, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int {
        let label = title ?? ""
        opened += 1
        emit("\(label).message", message)
        emit("\(label).main thread", Thread.isMainThread ? "yes" : "no")

        nonisolated(unsafe) var queueServed = false
        nonisolated(unsafe) var actorServed = false
        DispatchQueue.main.async { queueServed = true }
        Task { @MainActor in actorServed = true }

        // What a modal does on the main thread, until someone answers.
        let deadline = Date(timeIntervalSinceNow: 2)
        while !(queueServed && actorServed) && Date() < deadline {
            _ = CFRunLoopRunInMode(.defaultMode, 0.02, false)
        }
        emit("\(label).queue", queueServed ? "served" : "stopped")
        emit("\(label).actor", actorServed ? "served" : "stopped")
        return 1
    }
}

final class DicomDatabase: @unchecked Sendable {
SLICES
}
"""

# Since the alerts are ImportFeedback's, which is given who shows them: the
# application gives the alert panel from the main actor.
FEEDBACK = """
struct ImportFeedback: Sendable {
    typealias Alerter = @MainActor @Sendable (_ title: String, _ message: String) -> Void
    let alerter: Alerter = { title, message in
        _ = HorosAlertPanel.run(title: title, message: message, defaultButton: "OK", alternateButton: nil, otherButton: nil)
    }
SLICES
}
typealias DicomDatabase = ImportFeedback
"""

DRIVER = r"""
import Foundation

func turnUntil(_ alerts: Int) {
    let deadline = Date(timeIntervalSinceNow: 10)
    while opened < alerts && Date() < deadline {
        _ = CFRunLoopRunInMode(.defaultMode, 0.02, false)
    }
}

let database = DicomDatabase()

// As a rebuild and a copy from a medium do, off the main thread.
DispatchQueue.global().async { database.alertRejectedReports(3) }
turnUntil(1)
DispatchQueue.global().async { database.alertIncompleteImport("less than it was given") }
turnUntil(2)

// Called on the main thread, it waits for the run loop too: the caller goes on.
database.alertIncompleteImport("again")
emit("waits for the run loop", opened == 2 ? "yes" : "no")
turnUntil(3)
emit("opened", "\(opened)")
"""

source = read()
slices = method(source, 'alertRejectedReports') + method(source, 'alertIncompleteImport')
with tempfile.TemporaryDirectory(prefix='horos-import-alerts-') as directory:
    directory = Path(directory)
    doubles = DOUBLES.split('final class DicomDatabase')[0] + FEEDBACK if 'struct ImportFeedback' in source else DOUBLES
    (directory / 'doubles.swift').write_text(doubles.replace('SLICES', slices))
    (directory / 'main.swift').write_text(DRIVER)
    binary = directory / 'import-alerts'
    built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-suppress-warnings', '-o', str(binary),
                            str(directory / 'doubles.swift'), str(directory / 'main.swift'),
                            str(root / 'Horos/Sources/MainActorCallbacks.swift')], capture_output=True, text=True)
    if built.returncode != 0:
        raise SystemExit('FAIL: the alerts do not compile:\n%s' % built.stderr[-2500:])
    run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
    if run.returncode != 0:
        failures.append('the driver failed: %s' % run.stderr[-800:])
    results = dict(line.split('\t', 1) for line in run.stdout.splitlines() if '\t' in line)

expected = {'opened': '3', 'waits for the run loop': 'yes'}
for title in ('Report import', 'Import incomplete'):
    expected.update({'%s.main thread' % title: 'yes', '%s.queue' % title: 'served', '%s.actor' % title: 'served'})
for key, want in expected.items():
    if results.get(key) != want:
        failures.append('%s: %r, expected %r' % (key, results.get(key), want))
if '3 report(s) could not be imported' not in results.get('Report import.message', ''):
    failures.append('Report import.message: %r' % results.get('Report import.message'))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the two alerts of an import open on the main thread from its run loop, and with them open the main queue and the main actor go on serving')
