#!/usr/bin/env python3
"""Each autorouting rule is applied once per trigger, and the log says why.

-applyRoutingRules:toImages: walked the rules and, for every activated one,
handed -__applyRoutingRules: the whole list. Two rules therefore applied every
rule twice; five applied every rule five times. A rule carrying a schedule did it
again when its delay elapsed, for every other rule too.

The send queue de-duplicates against what is currently queued, so the repeats
were invisible while the first copy was still there — and the routing timer
drains that queue every ten seconds, after which the same images are queued again
and sent again.

The partition is IsiXDICOMNetwork's (RoutingSchedule) and is compiled and run
here. The logging that names the trigger, the rule and the counts is checked in
source: the import (DicomDatabase), the browser's menu, the selection
(RoutingSelection) and the queue (RoutingQueue).
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import isix_modules  # noqa: E402
import sources as dicom_database_sources  # noqa: E402

failures = []
MODULE = root / 'Modules/IsiXDICOMNetwork/Sources'
routing = (root / 'Horos/Sources/DatabaseRouting.swift').read_text()
selection = (MODULE / 'RoutingSelection.swift').read_text()
queue_source = (MODULE / 'RoutingQueue.swift').read_text()
# DicomDatabase is Swift (DicomDatabase.swift and its DicomDatabase+*.swift
# extensions); the assertions read its Swift spelling.
database = dicom_database_sources.class_text('DicomDatabase')
# The browser's manual routing (BrowserController+Autorouting.swift) is
# SourceCopyJob's routing by hand.
browser = (root / 'Horos/Sources/SourceCopyJob.swift').read_text()

DRIVER = r'''
import Foundation

func emit(_ key: String, _ value: String) { print(key + "\t" + value) }
func names(_ rules: [RoutingRule]) -> String {
    return rules.map { $0.name ?? "?" }.joined(separator: ",")
}
func rule(_ entry: [String: Any]) -> RoutingRule { RoutingRule(propertyList: entry)! }

let rules = RoutingRule.rules(fromPropertyList: [
    ["name": "plain"],                                        // no keys at all
    ["name": "off", "activated": false],
    ["name": "on", "activated": true, "scheduleType": 0],
    ["name": "delayed", "activated": true, "scheduleType": 1, "delayTime": 2],
    ["name": "window", "activated": true, "scheduleType": 2,
     "fromTime": "Monday, 01 January 2001 08:00:00 GMT", "toTime": "Monday, 01 January 2001 18:00:00 GMT"],
    // A window with no times cannot be worked out; the routing runs it now.
    ["name": "windowless", "activated": true, "scheduleType": 2],
    // Something newer than this code knows about: run it rather than drop it.
    ["name": "unknown", "activated": true, "scheduleType": 9],
    ["name": "offString", "activated": "0"],
] as [Any])

emit("immediate", names(RoutingSchedule.immediateRules(in: rules)))
emit("scheduled", names(RoutingSchedule.scheduledRules(in: rules)))
emit("counted", String(RoutingSchedule.immediateRules(in: rules).count
                       + RoutingSchedule.scheduledRules(in: rules).count))
emit("activatedByDefault", rule(["name": "plain"]).isActivated ? "yes" : "no")
emit("activatedByString", rule(["activated": "1"]).isActivated ? "yes" : "no")
emit("deactivatedByString", rule(["activated": "0"]).isActivated ? "yes" : "no")
emit("typeMissing", String(rule(["name": "plain"]).scheduleType))
emit("typeNumber", String(rule(["scheduleType": 2]).scheduleType))
'''

# --- the partition, compiled and run -----------------------------------------
results = {}
swiftc = subprocess.run(['xcrun', '--sdk', 'macosx', '-f', 'swiftc'], capture_output=True, text=True)
if swiftc.returncode != 0:
    failures.append('no swiftc here: %s' % (swiftc.stderr or '').strip())
else:
    with tempfile.TemporaryDirectory(prefix='horos-schedule-') as directory:
        try:
            binary = isix_modules.module_driver('IsiXDICOMNetwork', DRIVER, Path(directory) / 'schedule')
        except subprocess.CalledProcessError as error:
            failures.append('the schedule does not compile:\n%s' % (error.stderr or '')[-1500:])
        else:
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
            if run.returncode != 0:
                failures.append('the schedule driver failed: %s' % run.stderr[-800:])
            for line in run.stdout.splitlines():
                key, _, value = line.partition('\t')
                results[key] = value

if results:
    expected = {
        'immediate': 'plain,on,windowless,unknown',
        'scheduled': 'delayed,window',
        # Six activated rules, each in exactly one of the two lists.
        'counted': '6',
        'activatedByDefault': 'yes', 'activatedByString': 'yes', 'deactivatedByString': 'no',
        'typeMissing': '0', 'typeNumber': '2',
    }
    for key, value in expected.items():
        if results.get(key) != value:
            failures.append('%s is %r, expected %r' % (key, results.get(key), value))


def body(text, signature):
    """The braces of the declaration that starts with `signature`."""
    at = text.find(signature)
    if at < 0:
        return None
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
    return None


# --- the loop that used to apply every rule once per rule --------------------
apply = body(routing, 'func apply(_ propertyLists: [Any]?, to images: [DicomImage], in database: DicomDatabase)')
if apply is None:
    failures.append('DatabaseRouting.apply(_:to:in:) is gone')
else:
    applications = re.findall(r'applyNow\(\s*(\w+)', apply)
    # A scheduled rule goes through schedule(_:for:after:), which applies
    # that one rule, from its images' IDs, when its time comes.
    scheduling = re.findall(r'schedule\(\s*(\w+)\s*,', apply)
    if 'rules' in applications or 'rules' in scheduling:
        failures.append('the whole rule list is applied again per rule')
    if scheduling != ['rule'] or not re.search(r'for rule in RoutingSchedule\.scheduledRules\(in:', apply):
        failures.append('a scheduled rule does not apply only itself: %r' % scheduling)
    if applications != ['immediate']:
        failures.append('the unscheduled rules are not applied together, once: %r' % applications)
    if 'RoutingSchedule.immediateRules(in:' not in apply:
        failures.append('the immediate rules are not partitioned by the schedule')
scheduled = body(routing, 'private func schedule(_ rule: RoutingRule')
if scheduled is None or 'self.applyNow([rule]' not in scheduled:
    failures.append('a scheduled rule is not applied by itself when its time comes')

# --- the log identifies the trigger ------------------------------------------
if 'Autorouting trigger:' not in database:
    failures.append('an import does not say it triggered the routing')
if 're-read from disk' not in database:
    failures.append('an import does not distinguish a re-read from a new file')
if browser.count('Autorouting trigger:') != 2:
    failures.append('applying a rule by hand does not say so')
for text, expected, missing in (
        (selection, 'Autorouting rule \\"%@\\" -> %@: %d of %d image(s) matched',
         'the log does not say which rule matched which images'),
        (queue_source, 'already queued for it, not queued again',
         'the log does not say when images were left out as already queued'),
        (queue_source, 'list: rule \\"%@\\" -> %@, %d item(s)',
         'the queue does not name the rule each list belongs to')):
    if expected not in text:
        failures.append(missing)

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: every activated rule is applied exactly once per trigger, a scheduled one by itself '
      'when its time comes, and the log names the trigger, the rule and the counts')
