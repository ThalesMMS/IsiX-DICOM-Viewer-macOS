#!/usr/bin/env python3
"""Compile prior-study policy and exercise durable, concurrent admission limits.

The policy is IsiXDICOMNetwork's (PreviousRoutingStudies), compiled and run here
in a fresh process and a second one that reads what the first recorded. The
selection that uses it (RoutingSelection) and the database read behind it
(DatabaseRoutingCatalog) are checked in source.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import isix_modules  # noqa: E402

DRIVER = r'''
import Foundation
let directory = CommandLine.arguments[1]
let now = Date(timeIntervalSince1970: 200000)
let server = DICOMNode(propertyList: ["Address": "localhost", "Port": 11330, "AETitle": "ONE"])!
if CommandLine.arguments.count > 2 {
    // A fresh executable invocation reads the persisted history too.
    precondition(!PreviousRoutingStudies.reserve(study: "concurrent", node: server, databasePath: directory, now: now))
    exit(0)
}
let current = RoutedStudy(id: "c", studyName: "CURRENT", modality: "CT\\MR", date: now)
func prior(_ mod: String = "CT", _ name: String = "CURRENT", _ seconds: Double = -1) -> RoutedStudy {
    RoutedStudy(id: "p", studyName: name, modality: mod, date: now.addingTimeInterval(seconds))
}
func check(_ study: RoutedStudy, _ mod: Bool, _ desc: Bool) -> Bool {
    PreviousRoutingStudies.matches(study, currentStudy: current, modality: mod, description: desc)
}
precondition(check(prior(), true, true))
precondition(check(prior("US", "OTHER"), false, false))
precondition(!check(prior("US"), true, false))
precondition(!check(prior("CT", "OTHER"), false, true))
precondition(!check(prior("CT", "CURRENT", 0), false, false))
precondition(!check(prior("CT", "CURRENT", 1), false, false))
precondition(!check(RoutedStudy(id: "x"), false, false))
precondition(!check(prior("", ""), true, true))
func node(_ entry: [String: Any]) -> DICOMNode { DICOMNode(propertyList: entry)! }
func reserve(_ uid: String, _ time: Date = now, _ target: DICOMNode = server) -> Bool {
    PreviousRoutingStudies.reserve(study: uid, node: target, databasePath: directory, now: time)
}
precondition(reserve("study"))
precondition(!reserve("study"))
precondition(!reserve("study", now.addingTimeInterval(10799)))
precondition(reserve("study", now.addingTimeInterval(10800)))
precondition(reserve("study", now, node(["Address": "localhost", "Port": "11331", "AETitle": "ONE"])))
precondition(!reserve("study", now, node(["Address": "LOCALHOST", "Port": 11331, "AETitle": "ONE", "Description": "renamed"])))
precondition(reserve("study", now, node(["Address": "localhost", "Port": 11330, "AETitle": "TWO"])))
let mutex = NSLock()
nonisolated(unsafe) var accepted = 0
DispatchQueue.concurrentPerform(iterations: 32) { _ in
    if reserve("concurrent") { mutex.lock(); accepted += 1; mutex.unlock() }
}
precondition(accepted == 1)
let child = Process()
child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
child.arguments = [directory, "child"]
try child.run()
child.waitUntilExit()
precondition(child.terminationStatus == 0)
let file = URL(fileURLWithPath: directory).appendingPathComponent("PreviousRoutingStudies.json")
try Data("invalid".utf8).write(to: file)
precondition(!reserve("new"))
precondition(!PreviousRoutingStudies.reserve(study: "x", node: server, databasePath: directory + "/absent", now: now))
print("ok: date/filter policy, expiry, destination identity, concurrent claims, restart and persistence failure")
'''

with tempfile.TemporaryDirectory(prefix='horos-prior-routing-') as d:
    binary = isix_modules.module_driver('IsiXDICOMNetwork', DRIVER, Path(d) / 'build' / 'prior')
    history = Path(d) / 'history'
    history.mkdir()
    subprocess.run([str(binary), str(history)], check=True, timeout=20)

selection = (root / 'Modules/IsiXDICOMNetwork/Sources/RoutingSelection.swift').read_text()
catalog = (root / 'Horos/Sources/DatabaseRoutingCatalog.swift').read_text()
assert 'patientUID == %@' in catalog, 'the earlier studies are not found by patient UID'
assert 'PreviousRoutingStudies.reserve(' in selection, 'an earlier study is queued without being recorded'
assert 'currentIDs.contains(prior.id)' in selection, 'a current study is taken for an earlier one'
assert 'priorFiles.filter(\\.isImageStorage)' in selection, 'images only does not apply to earlier studies'
