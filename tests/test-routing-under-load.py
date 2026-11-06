#!/usr/bin/env python3
"""A destination that is down does not fill the screen with alerts.

Every failed send raised a modal alert on the main thread. A destination that is
down fails every batch, so a queue of forty batches was forty alerts to dismiss
before the application could be used again - which is what "the interface froze
while routing" turns out to be from the user's side.

The first failure of a destination is now shown and the repeats are logged. The
gate is IsiXDICOMNetwork's (RoutingProblemGate) and is compiled and run here; the
send that uses it (RoutingQueue) and the alert (DatabaseRoutingDelivery) are
checked in source. The load itself is tools/measure-routing-load.sh; see the
validation document for what it measured.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import isix_modules  # noqa: E402

failures = []
queue_source = (root / 'Modules/IsiXDICOMNetwork/Sources/RoutingQueue.swift').read_text()
delivery = (root / 'Horos/Sources/DatabaseRoutingDelivery.swift').read_text()

DRIVER = r'''
import Foundation

func emit(_ key: String, _ value: String) { print(key + "\t" + value) }
func yn(_ value: Bool) -> String { return value ? "yes" : "no" }

var gate = RoutingProblemGate()
let down = "PACSB@127.0.0.1:11182"
emit("first", yn(gate.shouldReport(problem: "refused", forDestination: down)))
emit("again", yn(gate.shouldReport(problem: "refused", forDestination: down)))
emit("third", yn(gate.shouldReport(problem: "refused", forDestination: down)))
// A different failure of the same destination is news.
emit("different", yn(gate.shouldReport(problem: "timed out", forDestination: down)))
// Another destination is not silenced by the first.
emit("other", yn(gate.shouldReport(problem: "refused", forDestination: "PACSA@127.0.0.1:11181")))
// It answered, so the next failure is news again.
gate.clearProblems(forDestination: down)
emit("afterSuccess", yn(gate.shouldReport(problem: "refused", forDestination: down)))
// And a rule name cannot silence a destination that happens to share it.
gate.resumeAll()
gate.suspend(rule: down, because: "refused")
emit("noCollision", yn(gate.shouldReport(problem: "refused", forDestination: down)))
'''

results = {}
swiftc = subprocess.run(['xcrun', '--sdk', 'macosx', '-f', 'swiftc'], capture_output=True, text=True)
if swiftc.returncode != 0:
    failures.append('no swiftc here: %s' % (swiftc.stderr or '').strip())
else:
    with tempfile.TemporaryDirectory(prefix='horos-load-') as directory:
        try:
            binary = isix_modules.module_driver('IsiXDICOMNetwork', DRIVER, Path(directory) / 'gate')
        except subprocess.CalledProcessError as error:
            failures.append('the gate does not compile:\n%s' % (error.stderr or '')[-1500:])
        else:
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
            if run.returncode != 0:
                failures.append('the gate driver failed: %s' % run.stderr[-800:])
            for line in run.stdout.splitlines():
                key, _, value = line.partition('\t')
                results[key] = value

if results:
    expected = {'first': 'yes', 'again': 'no', 'third': 'no', 'different': 'yes',
                'other': 'yes', 'afterSuccess': 'yes', 'noCollision': 'yes'}
    for key, value in expected.items():
        if results.get(key) != value:
            failures.append('%s is %r, expected %r' % (key, results.get(key), value))

# --- the send ------------------------------------------------------------------
at = queue_source.find('private func send(_ batch: [RoutedFile]')
body = queue_source[at:at + 3000] if at >= 0 else ''
if not body:
    failures.append('RoutingQueue.send(_:to:for:through:) is gone')
else:
    if 'gate.shouldReport(problem:' not in body:
        failures.append('every failure still raises an alert')
    if 'gate.clearProblems(forDestination:' not in body:
        failures.append('a destination that answers again never reports its next failure')
    # The alert must be gated, not merely logged beside the gate.
    gated = re.search(r'if gate\.shouldReport\(problem:[^\n]*\{\s*\n\s*await delivery\.reportFailedSend\(', body)
    if not gated:
        failures.append('the alert is not the thing the gate controls')
    if 'Autorouting FAILED' not in body:
        failures.append('a failed send is no longer logged')

# The report is logged whether or not it is shown, so a run can be counted.
alert = delivery[delivery.find('func reportFailedSend('):]
alert = alert[:alert.find('\n    }')]
logged = alert.find('NSLog')
suppressed = alert.find('showsErrors')
if logged < 0 or suppressed < 0 or logged > suppressed:
    failures.append('an alert that is suppressed leaves no trace, so alerts cannot be counted')
gate_preferences = delivery[delivery.find('private var showsErrors'):][:400]
# The catalog's keys of ShowErrorMessagesForAutorouting and hideListenerError.
catalog = (root / 'Modules/IsiXPreferences/Sources/NetworkPreferences.swift').read_text()
if 'NetworkPreferences.showErrorMessagesForAutorouting' not in gate_preferences \
        or 'NetworkPreferences.hidesListenerErrors' not in gate_preferences \
        or 'showErrorMessagesForAutorouting = PreferenceKey<Bool>("ShowErrorMessagesForAutorouting"' not in catalog \
        or 'hidesListenerErrors = PreferenceKey<Bool>("hideListenerError")' not in catalog:
    failures.append('the alerts no longer follow ShowErrorMessagesForAutorouting and hideListenerError')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: a destination that keeps failing is reported once, another destination is not '
      'silenced with it, and one that answers again reports its next failure')
