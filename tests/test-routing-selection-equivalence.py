#!/usr/bin/env python3
"""The autorouting queues and sends the same files to the same nodes as before.

DicomDatabase+Routing.swift applied the rules itself: it filtered the imported
images with each rule's smart-album filter, its filter type and "images only",
added the earlier studies of the patient, left out the studies the destination
already had (its C-FIND test), queued the images by object ID merged with those
already queued for the rule, and every ten seconds sent the queue one patient
at a time, queueing a failed batch again while the rule allowed. The rules are
now typed values (RoutingRule), the choice and the queue are IsiXDICOMNetwork's
(RoutingSelection, RoutingQueue), and the app hands them values read from the
database (DatabaseRoutingCatalog) and sends through the send queue
(DatabaseRoutingDelivery).

The same driver is compiled with DicomDatabase+Routing.swift, RoutingSchedule,
RoutingDestination and PreviousRoutingStudies of the revision before that
change, and with this tree's routing, over the doubles of routing_harness.py,
and every case must record the same lines: what is queued for each rule (its
destination name, its tries left and its files), each association (calling and
called AE titles, host, port, transfer syntax, compression, its files and the
TLS settings it reads), in order, and each C-FIND of a destination.

- modality: two rules by modality, to two nodes, given as the menu gives one;
- preferences: the rules of the preferences, as the pane writes them (numbers
  as text, no "activated" or "version" key), deactivated by a Boolean and by
  text, filter types 1 and 2, a filter hidden by an earlier version, images
  only, and a TLS node with its syntax as text and its port as a number;
- dedupe: a rule applied twice and the images a plugin queues for it, merged
  without the images already queued, and another rule apart;
- unresolved: a rule to two nodes of one name, to a deactivated node, to no
  node, without a destination, and to a node without an "Activated" key;
- priors: earlier studies of the patient by modality and by description, with
  images only, recorded so that they are not queued twice;
- cfind: the destination already has a study, not all of another, two answers
  for a third; a node asked is the first with "Activated" set;
- bad-filter: a filter that cannot be read and one that cannot be evaluated
  queue nothing, and the other rule still does;
- scheduled: a delay of 0 hours and an open time window are applied by
  themselves after the run loop turns, an unreadable window now;
- failure: a batch that fails is queued again with one try fewer, reported
  once, and dropped when its tries are spent; the next patient is sent;
- missing-gone: a file not on disk and an image deleted after queueing are not
  sent, and a patient without an ID is a batch per image.

Exits 2 when the history does not reach the revision before the routing moved.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import history_reference  # noqa: E402
import routing_harness as harness  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
ROUTING = 'Horos/Sources/DicomDatabase+Routing.swift'
MARK = 'private func __applyRoutingRules('
OLD_HELPERS = ('Horos/Sources/RoutingSchedule.swift', 'Horos/Sources/RoutingDestination.swift',
               'Horos/Sources/PreviousRoutingStudies.swift')
reference = ('HEAD' if MARK in history_reference.show('HEAD', ROUTING).decode('utf-8')
             else history_reference.before_text_removed(ROUTING, MARK))
if reference is None:
    print('skipped: the history does not reach the revision before the routing moved to IsiXDICOMNetwork')
    sys.exit(2)
if MARK in (ROOT / ROUTING).read_text(encoding='utf-8'):
    print('skipped: this tree still applies the rules in DicomDatabase+Routing.swift')
    sys.exit(2)

old_sources = {Path(path).name: history_reference.show(reference, path).decode('utf-8')
               for path in (ROUTING, *OLD_HELPERS)}
new_sources = {Path(path).name: (ROOT / path).read_text(encoding='utf-8')
               for path in (ROUTING, 'Horos/Sources/DatabaseRouting.swift', 'Horos/Sources/DatabaseRoutingCatalog.swift',
                            'Horos/Sources/DatabaseRoutingDelivery.swift')}

DRIVER = harness.DRIVER_PRELUDE + r'''
UserDefaults.standard.register(defaults: [
    "SERVERS": servers,
    "ShowErrorMessagesForAutorouting": false,
    "MaximumSendGlobalControllerConcurrentThreads": 4,
])
database.initRouting()

func rule(_ name: String, _ server: String?, _ filter: String = "", _ extra: [String: Any] = [:]) -> [String: Any] {
    var entry: [String: Any] = ["name": name, "activated": true, "filter": filter, "filterType": 0, "version": 1,
                                "failureRetry": 0, "scheduleType": 0]
    entry["server"] = server
    for (key, value) in extra { entry[key] = value }
    return entry
}

let ct = study("P1", "1.2.1", "CT", "CHEST CT", days: 0,
               files: [("p1-ct-1", image: true, generated: false, imported: false),
                       ("p1-ct-2", image: true, generated: false, imported: false),
                       ("p1-ct-sr", image: false, generated: false, imported: false)])
let mr = study("P2", "1.2.2", "MR", "BRAIN MR", days: 0,
               files: [("p2-mr-1", image: true, generated: false, imported: false),
                       ("p2-mr-gen", image: true, generated: true, imported: false),
                       ("p2-mr-imp", image: true, generated: false, imported: true)])
let us = study(nil, "1.2.3", "US", "ABDOMEN", days: 0, files: plain("nopid-us-1", "nopid-us-2"))
let imported = ct + mr + us

switch CommandLine.arguments[1] {
case "modality":
    apply([rule("ct", "PACS", "series.study.modality == \"CT\""), rule("mr", "ARCHIVE", "series.study.modality == \"MR\"")],
          imported)
case "preferences":
    UserDefaults.standard.register(defaults: [RoutingRuleKey: [
        ["name": "new route", "description": "", "filter": "(series.study.modality contains[c] \"CT\")", "server": "PACS",
         "failureRetry": "20", "filterType": "0", "imagesOnly": false, "scheduleType": "0", "delayTime": "2",
         "fromTime": "21:00", "toTime": "06:00"],
        rule("off", "PACS", "", ["activated": false]),
        rule("offText", "PACS", "", ["activated": "0"]),
        rule("generated", "ARCHIVE", "", ["filterType": NSNumber(value: Int32(1))]),
        rule("imported", "PACS", "series.study.modality == \"MR\"", ["filterType": "2", "imagesOnly": NSNumber(value: Int32(1))]),
        rule("old", "ARCHIVE", "series.study.modality == \"XX\"", ["filterType": 2, "version": 0]),
        rule("secure", "SECURE", "", ["imagesOnly": true]),
    ]])
    apply(nil, imported)
case "dedupe":
    let all = rule("all", "PACS", "", ["failureRetry": "3"])
    apply([all], Array(imported.prefix(4)))
    apply([all], imported)
    queueForRule([ct[0], mr[0]], all)
    queueForRule([ct[0]], rule("other", "ARCHIVE"))
case "unresolved":
    apply([rule("twin", "TWIN"), rule("off", "OFF"), rule("gone", "MISSING"), rule("nowhere", nil),
           rule("nokey", "NOKEY", "series.study.modality == \"CT\"")], imported)
case "priors":
    study("P1", "1.1.1", "CT", "CHEST CT", days: 30, files: plain("p1-prior-ct-1", "p1-prior-ct-2"))
    study("P1", "1.1.2", "CT", "CHEST", days: 60, files: plain("p1-prior-ct2-1"))
    study("P1", "1.1.3", "MR", "KNEE", days: 10,
          files: [("p1-prior-mr-1", image: true, generated: false, imported: false),
                  ("p1-prior-mr-sr", image: false, generated: false, imported: false)])
    study("P1", "1.1.4", "CT", "CHEST CT", days: -5, files: plain("p1-later-ct-1"))
    study("P9", "1.1.5", "CT", "CHEST CT", days: 20, files: plain("p9-other-ct-1"), patientUID: "P1x")
    apply([rule("byModality", "PACS", "", ["previousStudies": 2, "previousModality": true]),
           rule("byDescription", "ARCHIVE", "", ["previousStudies": "1", "previousDescription": true, "imagesOnly": true]),
           rule("any", "SECURE", "", ["previousStudies": 5])], ct)
    // Recorded: the same earlier studies are not queued again for the same node.
    apply([rule("byModality", "PACS", "", ["previousStudies": 2, "previousModality": true])], ct)
case "cfind":
    remoteCounts = ["1.2.1": [3], "1.2.2": [1], "1.2.3": [5, 2]]
    apply([rule("asks", "ARCHIVE", "", ["cfindTest": true]), rule("nothing", "PACS", "", ["cfindTest": NSNumber(value: true)]),
           rule("nokey", "NOKEY", "", ["cfindTest": "1"])], imported)
case "bad-filter":
    apply([rule("unreadable", "PACS", "modality == "), rule("unknownKey", "PACS", "series.study.nonexistent == 1"),
           rule("good", "ARCHIVE", "series.study.modality == \"US\"")], imported)
case "scheduled":
    UserDefaults.standard.register(defaults: [RoutingRuleKey: [
        rule("later", "PACS", "series.study.modality == \"CT\"", ["scheduleType": 1, "delayTime": "0"]),
        rule("window", "ARCHIVE", "series.study.modality == \"MR\"", ["scheduleType": "2", "fromTime": "00:00", "toTime": "23:59"]),
        rule("unreadable", "PACS", "series.study.modality == \"US\"", ["scheduleType": 2, "fromTime": "soon", "toTime": "later"]),
        rule("now", "SECURE", "series.study.modality == \"CT\""),
    ]])
    apply(nil, imported)
    spin(1)
case "failure":
    let failing = study("P4", "1.2.4", "CT", "FAIL", days: 0, files: plain("p4-fail-1", "p4-fail-2"))
    apply([rule("retried", "PACS", "", ["failureRetry": "1"])], ct + failing)
case "missing-gone":
    let missing = study("P5", "1.2.5", "CR", "HAND", days: 0, files: plain("p5-missing-1", "p5-ok-1"))
    apply([rule("all", "ARCHIVE")], imported + missing)
    recordQueue()
    deleteImage(ct[1])
default:
    print("unknown case")
    exit(1)
}

recordQueue()
drain()
recordQueue()
if CommandLine.arguments[1] == "failure" {
    drain()
    recordQueue()
}
''' + harness.DRIVER_END

CASES = ('modality', 'preferences', 'dedupe', 'unresolved', 'priors', 'cfind', 'bad-filter', 'scheduled', 'failure',
         'missing-gone')


def comparable(lines):
    """The records in order; the C-FIND lines as a set, asked in any order."""
    records = [line for line in lines if not line.startswith('cfind ')]
    return records + sorted(line for line in lines if line.startswith('cfind '))


failures = []
with tempfile.TemporaryDirectory(prefix='horos-routing-equivalence-') as directory:
    folder = Path(directory)
    builds = {}
    for side, sources, actor in (('old', old_sources, False), ('new', new_sources, True)):
        driver = DRIVER.replace('RoutingRuleKey', '"AUTOROUTINGDICTIONARY"')
        try:
            builds[side] = harness.build(folder, sources, driver, f'routing-{side}', actor)
        except subprocess.CalledProcessError as error:
            output = error.stderr.decode(errors='replace') if isinstance(error.stderr, bytes) else str(error.stderr)
            print(f'FAIL: the {side} routing does not build with the driver:\n' + output[-4000:])
            sys.exit(1)
    for case in CASES:
        outputs = {}
        for side in builds:
            data = folder / f'data-{side}-{case}'
            data.mkdir()
            result = harness.run(builds[side], case, data)
            lines = result.stdout.strip().splitlines()
            if result.returncode != 0 or not lines or lines[0] != 'finished':
                failures.append(f'{case}: the {side} routing did not finish (exit {result.returncode}): '
                                f'{(result.stdout + result.stderr)[-1200:]}')
            outputs[side] = comparable(lines[1:])
        if any(failure.startswith(case + ':') for failure in failures):
            continue
        if outputs['old'] != outputs['new']:
            failures.append(f'{case}: the routing differs\n  before: {outputs["old"]}\n  now:    {outputs["new"]}')
        elif not outputs['new']:
            failures.append(f'{case}: nothing was recorded')
        else:
            print(f'ok: {case} ({len(outputs["new"])} records)')
            if '--verbose' in sys.argv:
                print('\n'.join('    ' + line for line in outputs['new']))

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print(f'PASS: {len(CASES)} cases queue the same files for the same rules and destinations, with the same tries, '
      'and send the same batches to the same nodes with the same syntax, compression and TLS, '
      f'as {reference[:9]} did')
