#!/usr/bin/env python3
"""Each instance of the automatic query keeps its own interval and its own
filters, and a save writes all of them.

The automatic Query window holds several instances, each a preset with a name,
an interval and the answers of its last query. Once a second every instance
counts down, and the query of each one whose time has come starts. That loop
used to read the first instance on every turn and step by two: the instances
of odd index never counted, and those of even index queried with the first
one's filters. The save, for its part, wrote the results of an instance read
from the preferences into the preferences.

The countdown, the queue of runs and the instances now live in
IsiXDICOMNetwork (AutoQueryScheduler, AutoQueryInstance), with their module
tests; the window keeps the instances and hands them over. This compiles the
module with a driver that replays the old case through stand-ins of the ports
- four instances, one that does not refresh - and the save of instances read
from the preferences, and checks that the window hands every change over and
saves through the module, with no thread or timer of its own left.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import isix_modules  # noqa: E402

failures = []

if not shutil.which('xcrun'):
    print('skipped: no xcrun here')
    sys.exit(2)

# --- the window hands its instances over ---------------------------------------
auto = (root / 'Horos/Sources/QueryController+AutoQuery.swift').read_text(encoding='utf-8')
window = (root / 'Horos/Sources/QueryController.swift').read_text(encoding='utf-8')
for pattern in ('Thread(target:', 'perform(#selector', 'Timer.scheduledTimer', 'autoQueryRemainingSecs', 'synchronized(',
                'NSMutableArray'):
    if pattern in auto:
        failures.append('the automatic query still uses %s' % pattern)
if 'var autoQRInstances: [AutoQueryInstance]' not in window or 'didSet { autoQueryInstancesDidChange() }' not in window:
    failures.append('the instances are not typed, or a change of them is not handed to the scheduler')
loaded = window.find('AutoQueryInstanceStore.load(from: NodePreferences(processGraph: processGraph)')
if loaded < 0:
    failures.append('the instances are not read from the preferences through AutoQueryInstanceStore')
# An initializer does not run didSet: the instances read there are handed over
# explicitly, or the scheduler would count none of them.
elif 'autoQueryInstancesDidChange()' not in window[loaded:window.find('didChangeValue(forKey: "instancesMenuList")', loaded)]:
    failures.append('the instances read when the window is made are not handed to the scheduler')
if 'AutoQueryInstanceStore.save(autoQRInstances, to: NodePreferences(processGraph: processGraph))' not in auto:
    failures.append('the save does not write every instance through AutoQueryInstanceStore')
if 'await $0.setInstances(instances)' not in auto:
    failures.append('the window does not hand its instances to the scheduler')
if 'autoQRInstances.first(where: { $0.id == instance.id })' not in auto:
    failures.append('a run does not query with the settings of its own instance')

# --- the scheduler, run --------------------------------------------------------
DRIVER = r'''
import Foundation
import IsiXContracts

func check(_ condition: Bool, _ what: String) { if !condition { print("FAIL: " + what); exit(1) } }

actor Queries: AutoQueryRunning {
    var runs: [AutoQueryInstance] = []
    func runQuery(of instance: AutoQueryInstance) async throws -> [AutoQueryStudy] { runs.append(instance); return [] }
    func studies(ofPatientID patientID: String) async -> [AutoQueryStudy] { [] }
}
struct NoRetrieve: AutoRetrieveStarting {
    func mayStartRetrieve() async -> Bool { false }
    func retrieveInventory(of study: AutoQueryStudy) async -> AutoQueryRetrieveInventory? { nil }
    func claimTransfer(of study: AutoQueryStudy, expectedFiles: Int) async -> Bool { false }
    func startRetrieve(of studies: [AutoQueryStudy], for instance: AutoQueryInstance) async {}
}
struct Nothing: LocalStudyReading {
    func studies(withInstanceUIDs studyInstanceUIDs: Set<String>) async throws -> [LocalStudySnapshot] { [] }
}

/// An instance as the preferences give it back.
func stored(_ name: String, _ refresh: Int, _ modality: String, results: [String]? = nil) -> [String: Any] {
    var values: [String: Any] = ["instanceName": name, "autoRefreshQueryResults": refresh, "modalityStrings": [modality]]
    if let results { values["resultArray"] = results }
    return values
}

let queries = Queries()
let scheduler = AutoQueryScheduler(querying: queries, retrieving: NoRetrieve(), localStudies: Nothing(),
                                   rules: { AutoRetrieveRules() })
// Negative intervals are seconds. The third does not refresh.
let instances = [stored("A", -3, "CT"), stored("B", -5, "MR"), stored("C", 0, "US"), stored("D", -2, "CR")]
    .compactMap { AutoQueryInstance(propertyList: $0) }
await scheduler.setInstances(instances)
var launches: [String] = []
for second in 1...6 {
    let before = await queries.runs.count
    await scheduler.tick()
    for _ in 0..<5000 where await !scheduler.pending.isEmpty { await Task.yield() }
    for run in await queries.runs[before...] {
        let own = instances.first { $0.id == run.id }
        check(own?.name == run.name && own?.modalities == run.modalities, "\(run.name ?? "?") queried with another instance's filters")
        launches.append("\(second):\(run.name ?? "?")")
    }
}
check(launches == ["2:D", "3:A", "4:D", "5:B", "6:A", "6:D"], "the instances started \(launches)")
print("PASS: each instance counts its own interval and queries with its own filters")

// The save: every instance, those read from the preferences included, goes
// back without results, with its own values.
/// Preferences in memory: the driver touches no preferences domain.
final class Memory: DICOMNodePreferences, @unchecked Sendable {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func bool(forKey key: String) -> Bool { (values[key] as? NSNumber)?.boolValue ?? false }
    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func isGivenAsLaunchArgument(_ key: String) -> Bool { false }
}
let defaults = Memory()
let read = [stored("A", 1, "CT", results: ["a1"]), stored("B", 2, "MR", results: ["b1"])].compactMap { AutoQueryInstance(propertyList: $0) }
var shown = read
shown[0] = shown[0].adding(["windowFilter": "shown", "resultArray": ["x"]])
AutoQueryInstanceStore.save(shown, to: defaults)
let written = defaults.object(forKey: "savedAutoDICOMQuerySettingsArray") as? [[String: Any]] ?? []
check(written.count == 2 && written.allSatisfy { $0["resultArray"] == nil }, "a saved instance kept its results: \(written)")
check(written.map { $0["instanceName"] as? String } == ["A", "B"], "the instances were not all saved, in order")
check(written[0]["windowFilter"] as? String == "shown" && written[1]["windowFilter"] == nil, "the window's filters went to the wrong instance")
check((written[1]["modalityStrings"] as? [String]) == ["MR"], "an instance not shown lost its own filters")
print("PASS: a save writes every instance, without results")
'''

with tempfile.TemporaryDirectory(prefix='horos-auto-query-') as folder:
    try:
        binary = isix_modules.module_driver('IsiXDICOMNetwork', DRIVER, Path(folder) / 'driver')
    except subprocess.CalledProcessError as error:
        failures.append('the driver did not compile:\n%s' % (error.stderr or '')[-3000:])
    else:
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=120)
        print(result.stdout, end='')
        if result.returncode != 0:
            failures.append('the scheduler or the save failed (status %d): %s' % (result.returncode, result.stderr[-2000:]))

if failures:
    print('FAIL')
    for failure in failures:
        print(' -', failure)
    sys.exit(1)
print('ok: each instance of the automatic query keeps its own interval and filters, and a save writes all of them')
