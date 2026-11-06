#!/usr/bin/env python3
"""An autorouting rule that cannot say where a study goes does not send it.

A rule stores its destination as the node's display name, and the routing queue
looked it up by walking the stored nodes and taking the first activated one whose
name matched. Two nodes sharing a name therefore sent the study to whichever the
list happened to hold first, and reordering the list changed the answer; a
renamed or deleted node made the rule match nothing, and the files already queued
for it were dropped with one N2LogError line and nothing shown to anyone.

The resolver and the gate that remembers what was reported are
IsiXDICOMNetwork's (RoutingDestination, RoutingProblemGate) and are compiled and
run here. The queue that uses them (RoutingQueue) and the alert the app shows
(DatabaseRoutingDelivery) are checked in source.
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

func node(_ name: String, _ port: String, activated: Any? = nil) -> DICOMNode {
    var server: [String: Any] = ["Description": name, "AETitle": "AE" + port,
                                 "Address": "127.0.0.1", "Port": port]
    if let activated = activated { server["Activated"] = activated }
    return DICOMNode(propertyList: server)!
}

// The ordinary case: one node of that name.
let one = [node("PACS", "104"), node("ARCHIVE", "105")]
let good = RoutingDestination.resolve(named: "PACS", in: one, ruleName: "nightly")
emit("good.resolved", good.isResolved ? "yes" : "no")
emit("good.port", good.node?["Port"]?.stringValue ?? "none")
emit("good.problem", good.problem ?? "none")

// A node with no Activated key is activated, as it is everywhere else.
let implicit = [DICOMNode(propertyList: ["Description": "PACS", "AETitle": "AE", "Address": "127.0.0.1", "Port": "104"])!]
emit("implicit.resolved",
     RoutingDestination.resolve(named: "PACS", in: implicit, ruleName: nil).isResolved ? "yes" : "no")

// Two nodes called the same thing: sending to the first would be a guess.
let ambiguous = [node("PACS", "104"), node("PACS", "11112")]
let two = RoutingDestination.resolve(named: "PACS", in: ambiguous, ruleName: "nightly")
emit("ambiguous.resolved", two.isResolved ? "yes" : "no")
emit("ambiguous.permanent", two.isPermanent ? "yes" : "no")
emit("ambiguous.problem", two.problem ?? "none")

// Renamed or removed.
let missing = RoutingDestination.resolve(named: "PACS", in: [node("ARCHIVE", "105")], ruleName: "nightly")
emit("missing.resolved", missing.isResolved ? "yes" : "no")
emit("missing.problem", missing.problem ?? "none")

// There, but switched off.
let off = RoutingDestination.resolve(named: "PACS", in: [node("PACS", "104", activated: false)], ruleName: "nightly")
emit("off.resolved", off.isResolved ? "yes" : "no")
emit("off.problem", off.problem ?? "none")

// A rule with no destination at all.
emit("empty.problem", RoutingDestination.resolve(named: "", in: one, ruleName: nil).problem ?? "none")

// The suspension remembers the first report and forgets it once fixed.
var gate = RoutingProblemGate()
emit("suspend.first", gate.suspend(rule: "nightly", because: "gone") ? "yes" : "no")
emit("suspend.again", gate.suspend(rule: "nightly", because: "gone") ? "yes" : "no")
emit("suspend.changed", gate.suspend(rule: "nightly", because: "ambiguous") ? "yes" : "no")
emit("suspend.problem", gate.problem(forRule: "nightly") ?? "none")
gate.resume(rule: "nightly")
emit("suspend.afterResume", gate.problem(forRule: "nightly") ?? "none")
emit("suspend.reportsAgain", gate.suspend(rule: "nightly", because: "gone") ? "yes" : "no")
'''

# --- the resolver, compiled and run ------------------------------------------
results = {}
swiftc = subprocess.run(['xcrun', '--sdk', 'macosx', '-f', 'swiftc'], capture_output=True, text=True)
if swiftc.returncode != 0:
    failures.append('no swiftc here: %s' % (swiftc.stderr or '').strip())
else:
    with tempfile.TemporaryDirectory(prefix='horos-routing-') as directory:
        try:
            binary = isix_modules.module_driver('IsiXDICOMNetwork', DRIVER, Path(directory) / 'routing')
        except subprocess.CalledProcessError as error:
            failures.append('the resolver does not compile:\n%s' % (error.stderr or '')[-1500:])
        else:
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
            if run.returncode != 0:
                failures.append('the resolver driver failed: %s' % run.stderr[-800:])
            for line in run.stdout.splitlines():
                key, _, value = line.partition('\t')
                results[key] = value

if results:
    expected = {
        'good.resolved': 'yes', 'good.port': '104', 'good.problem': 'none',
        'implicit.resolved': 'yes',
        # Two of the same name: nothing is sent, and asking again will not help.
        'ambiguous.resolved': 'no', 'ambiguous.permanent': 'yes',
        'missing.resolved': 'no',
        'off.resolved': 'no',
        # The first report goes out, the repeat does not, a different problem does.
        'suspend.first': 'yes', 'suspend.again': 'no', 'suspend.changed': 'yes',
        'suspend.problem': 'ambiguous',
        'suspend.afterResume': 'none', 'suspend.reportsAgain': 'yes',
    }
    for key, value in expected.items():
        if results.get(key) != value:
            failures.append('%s is %r, expected %r' % (key, results.get(key), value))
    for key, fragments in (
            ('ambiguous.problem', ('2 DICOM nodes are called that', 'AE104@127.0.0.1:104',
                                   'AE11112@127.0.0.1:11112', 'Nothing was sent')),
            ('missing.problem', ('there is no DICOM node of that name', 'renamed or removed',
                                 'nightly')),
            ('off.problem', ('exists but is not activated',)),
            ('empty.problem', ('names no destination',))):
        for fragment in fragments:
            if fragment not in results.get(key, ''):
                failures.append('%s does not say %r: %r' % (key, fragment, results.get(key)))

# --- the queue ----------------------------------------------------------------
# The drain is RoutingQueue.drain(through:); the C-FIND test of a rule still
# looks its node up by name, as it always did, and is not the queue.
at = queue_source.find('public func drain(through delivery: some RoutingDelivery)')
drain = queue_source[at:queue_source.find('\n    }\n', at)] if at >= 0 else ''
if not drain:
    failures.append('the queue (RoutingQueue.drain) is gone')
for expected, missing in (
        ('destination(of: order, in: nodes)', 'the destination is not resolved'),
        ('gate.suspend(rule:', 'a rule that cannot resolve is not suspended'),
        ('gate.resume(rule:', 'a rule fixed in the preferences stays suspended'),
        ('delivery.reportUnresolvedDestination(', 'nothing is shown when the destination cannot be told')):
    if expected not in drain:
        failures.append(missing)
if 'RoutingDestination.resolve(named:' not in queue_source:
    failures.append('the queue does not resolve destinations with RoutingDestination')

# The progress total has to count what will actually be sent, or the bar lies.
total = drain[drain.find('var total = 0'):][:300]
if 'destination(of: order, in: nodes).isResolved' not in total:
    failures.append('the total counts orders whose destination does not resolve')

# And the problem reaches the user, not only the log.
alert = delivery[delivery.find('func reportUnresolvedDestination('):]
alert = alert[:alert.find('\n    }')]
if 'NSLog' not in alert or 'showAlert(problem)' not in alert:
    failures.append('the destination problem is not logged and shown')
shown = delivery[delivery.find('private func showAlert('):]
if 'NSAlert()' not in shown or 'informativeText = text' not in shown:
    failures.append('the alert does not show the problem')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: a rule resolves to exactly one activated node or sends nothing, and says which of '
      'renamed, removed, deactivated or duplicated happened')
