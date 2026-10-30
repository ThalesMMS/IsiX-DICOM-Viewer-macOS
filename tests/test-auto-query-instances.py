#!/usr/bin/env python3
"""Each instance of the automatic query keeps its own interval and its own
filters, and a save writes all of them.

The automatic Query window holds several instances, each a preset with a name,
an interval and the results of its last query. Once a second the timer counts
every instance down and starts the query of each one whose time has come. That
loop used to read the first instance on every turn and step by two: the
instances of odd index never counted, and those of even index queried with the
first one's filters. The save, for its part, stripped the results from the
mutable instances only, so an instance read from the preferences, immutable
until it is shown, went to the preferences with its results; and a query of
such an instance, which the query keeps through a cast to a mutable dictionary,
lost its results.

This compiles the production -autoQueryTimerFunction:, -saveSettings, the
countdown display and the keeping of a query's results, taken from the Swift of the Query window, with the window's
filters, the thread manager, the notifications and the preferences substituted,
and runs them without a network: the workers record what they were given.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/QueryController+AutoQuery.swift').read_text(encoding='utf-8')
failures = []

if not shutil.which('xcrun'):
    print('skipped: no xcrun here')
    sys.exit(2)


def body_end(at):
    opening = source.index('{', at)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return index + 1
    raise ValueError('unbalanced braces')


def member(signature):
    """The declaration of `signature`, with the attributes above it."""
    at = source.find(signature)
    if at < 0:
        failures.append('%s is gone' % signature)
        return ''
    line = source.rfind('\n', 0, at) + 1
    while line > 0:
        previous = source.rfind('\n', 0, line - 1) + 1
        if not source[previous:line].strip().startswith('@'):
            break
        line = previous
    return source[line:body_end(at)]


methods = '\n'.join(member(signature) for signature in (
    'public func saveSettings()',
    'public func autoQueryTimerFunction(_ t: Timer?)',
    'private func showRemainingTime()',
    'nonisolated func keepResults(_ results: NSArray, inInstanceAt index: Int) -> Bool',
))

HARNESS = r'''
import AppKit

// What the production methods use of the rest of the app. The preferences are
// a dictionary here, so the test writes none of the real ones; the thread
// manager runs the worker's entry point on the spot, and the worker records
// what it was given instead of querying.
final class UserDefaults {
    nonisolated(unsafe) static let standard = UserDefaults()
    var values: [String: Any] = [:]
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
enum HorosObjCException {
    static func perform(_ body: () -> Void) throws { body() }
}
final class AppController: NSObject {
    static func shared() -> AppController? { AppController() }
    func notificationTitle(_ title: String, description: String, name: String) {}
}
final class ThreadsManager: NSObject {
    nonisolated(unsafe) static let shared = ThreadsManager()
    static func `default`() -> ThreadsManager? { shared }
    var names: [String] = []
    func addThreadAndStart(_ thread: Thread) { names.append(thread.name ?? ""); thread.main() }
}
extension Thread {
    var supportsCancel: Bool { get { false } set {} }
}

@MainActor public final class QueryController: NSObject {
    nonisolated static let maximumInstances = 40
    nonisolated(unsafe) var autoQueryValue = true
    nonisolated(unsafe) var queryButtonPressed = false
    nonisolated(unsafe) var DatabaseIsEdited = false
    nonisolated(unsafe) var autoQRInstances: NSMutableArray?
    nonisolated(unsafe) var currentAutoQRValue: Int32 = 0
    nonisolated(unsafe) var autoQueryRemainingSecs = [Int](repeating: 0, count: QueryController.maximumInstances)
    nonisolated let autoQueryLock = NSRecursiveLock()
    nonisolated(unsafe) var autoRefreshQueryResults = 0
    var autoQueryCounter: NSTextField! = NSTextField()
    nonisolated(unsafe) var errors: [String] = []
    /// What each worker was given.
    nonisolated(unsafe) var started: [NSDictionary] = []
    /// The filters of the window, which the instance shown takes on save.
    func savePresetInDictionary(withDICOMNodes includeDICOMNodes: Bool) -> NSMutableDictionary! {
        return NSMutableDictionary(dictionary: ["windowFilter": "shown"])
    }
    func captureWindowState() {}
    @objc(autoQueryThread:)
    public nonisolated func autoQueryThread(_ dictionary: NSDictionary!) { started.append(dictionary) }

    nonisolated static func int32(_ value: Any?) -> Int32 {
        if let number = value as? NSNumber { return number.int32Value }
        if let string = value as? NSString { return string.intValue }
        return 0
    }
    nonisolated static func synchronized<T>(_ object: AnyObject?, _ body: () throws -> T) rethrows -> T {
        guard let object else { return try body() }
        objc_sync_enter(object)
        defer { objc_sync_exit(object) }
        return try body()
    }
    nonisolated static func log(_ error: Error, _ function: String) { print("logged: \(function) \(error)") }
}

extension QueryController {
METHODS
}
'''

DRIVER = r'''
import AppKit

@MainActor func check(_ condition: Bool, _ what: String) { if !condition { print("FAIL: " + what); exit(1) } }

/// An instance as the preferences give it back: immutable.
func stored(_ name: String, _ refresh: Int, _ modality: String, results: [String]? = nil) -> NSDictionary {
    var values: [String: Any] = ["instanceName": name, "autoRefreshQueryResults": refresh, "modality": modality]
    if let results { values["resultArray"] = results }
    return NSDictionary(dictionary: values)
}

MainActor.assumeIsolated {
    // --- the countdown of each instance -------------------------------------
    // Negative intervals are seconds. The second instance is shown; the third
    // does not refresh.
    let c = QueryController()
    let instances = NSMutableArray(array: [stored("A", -3, "CT"), stored("B", -5, "MR"), stored("C", 0, "US"), stored("D", -2, "CR")])
    c.autoQRInstances = instances
    c.currentAutoQRValue = 1
    for i in 0..<instances.count {
        let refresh = Int(QueryController.int32((instances[i] as AnyObject).value(forKey: "autoRefreshQueryResults")))
        c.autoQueryRemainingSecs[i] = refresh >= 0 ? 60 * refresh : -refresh
    }
    var launches: [String] = []
    for second in 1...6 {
        c.started.removeAll()
        c.autoQueryTimerFunction(nil)
        for work in c.started {
            let index = Int(QueryController.int32(work.object(forKey: "index")))
            let instance = work.object(forKey: "instance") as? NSDictionary
            let name = instance?.object(forKey: "instanceName") as? String ?? "?"
            let own = instances[index] as? NSDictionary
            check(own?.object(forKey: "instanceName") as? String == name,
                  "instance \(index) queries with the filters of \(name)")
            check(instance?.object(forKey: "modality") as? String == own?.object(forKey: "modality") as? String,
                  "instance \(name) queries with another modality")
            launches.append("\(second):\(name)")
        }
    }
    let expected = ["2:D", "3:A", "4:D", "5:B", "6:A", "6:D"]
    check(launches == expected, "the instances started \(launches), expected \(expected)")
    check(ThreadsManager.shared.names.allSatisfy { $0.contains("(") }, "a worker is not named after its instance: \(ThreadsManager.shared.names)")
    check(ThreadsManager.shared.names.contains { $0.contains("(B)") }, "the worker of B is not named after it")
    // The instance shown took the window's filters when its time came.
    check((instances[1] as? NSDictionary)?.object(forKey: "windowFilter") as? String == "shown", "the instance shown was not saved before its query")
    check((instances[0] as? NSDictionary)?.object(forKey: "windowFilter") == nil, "an instance not shown took the window's filters")
    print("PASS: each instance counts its own interval and queries with its own filters")

    // --- the save -----------------------------------------------------------
    let s = QueryController()
    let shown = NSMutableDictionary(dictionary: ["instanceName": "A", "autoRefreshQueryResults": 1, "resultArray": ["a1", "a2"]])
    let saving = NSMutableArray(array: [shown, stored("B", 2, "MR", results: ["b1"]), stored("C", 3, "US"),
                                        NSMutableDictionary(dictionary: ["instanceName": "D", "resultArray": ["d1"]])])
    s.autoQRInstances = saving
    s.currentAutoQRValue = 0
    for pass in 1...2 {
        UserDefaults.standard.values = [:]
        s.saveSettings()
        let written = UserDefaults.standard.values["savedAutoDICOMQuerySettingsArray"] as? [NSDictionary] ?? []
        check(written.map { $0.object(forKey: "instanceName") as? String ?? "?" } == ["A", "B", "C", "D"],
              "save \(pass) wrote \(written.map { $0.object(forKey: "instanceName") ?? "?" })")
        check(written.allSatisfy { $0.object(forKey: "resultArray") == nil }, "save \(pass) wrote results to the preferences")
        check(written.first?.object(forKey: "windowFilter") as? String == "shown", "save \(pass) did not keep the filters shown")
        let results = (0..<saving.count).map { (saving[$0] as? NSDictionary)?.object(forKey: "resultArray") as? [String] }
        check(results == [["a1", "a2"], ["b1"], nil, ["d1"]], "save \(pass) lost results: \(results)")
        check((0..<saving.count).allSatisfy { saving[$0] is NSMutableDictionary }, "save \(pass) left an immutable instance")
    }
    // An instance that was immutable keeps the next results given to it.
    (saving[2] as? NSMutableDictionary)?.setObject(["c1"], forKey: "resultArray" as NSString)
    check((saving[2] as? NSDictionary)?.object(forKey: "resultArray") as? [String] == ["c1"], "a former stored instance cannot keep results")
    print("PASS: a save writes every instance without results and keeps the results in them")

    // --- the results of a query ---------------------------------------------
    // An instance read from the preferences and never saved since is immutable;
    // the results of its query are kept in a mutable copy put in its place.
    let k = QueryController()
    let first = NSMutableDictionary(dictionary: ["instanceName": "A", "resultArray": ["a1"]])
    let kept = NSMutableArray(array: [first, stored("B", 2, "MR"), stored("C", 3, "US")])
    k.autoQRInstances = kept
    check(k.keepResults(["b1", "b2"] as NSArray, inInstanceAt: 1), "an instance in range was refused")
    check((kept[1] as? NSDictionary)?.object(forKey: "resultArray") as? [String] == ["b1", "b2"],
          "the results of an immutable instance were lost")
    check(kept[1] is NSMutableDictionary, "the immutable instance was not replaced by a mutable copy")
    check((kept[1] as? NSDictionary)?.object(forKey: "modality") as? String == "MR", "the copy lost the instance's filters")
    check(k.keepResults(["a2"] as NSArray, inInstanceAt: 0), "a mutable instance was refused")
    check(kept[0] as AnyObject === first, "a mutable instance was replaced")
    check(first.object(forKey: "resultArray") as? [String] == ["a2"], "a mutable instance did not take its results")
    check((kept[2] as? NSDictionary)?.object(forKey: "resultArray") == nil && !(kept[2] is NSMutableDictionary),
          "another instance changed")
    check(!k.keepResults(["x"] as NSArray, inInstanceAt: 3) && !k.keepResults(["x"] as NSArray, inInstanceAt: -1),
          "an index out of range was accepted")
    print("PASS: a query keeps its results in its instance, immutable or not")
}
'''

harness = HARNESS.replace('METHODS', methods)
if not failures:
    with tempfile.TemporaryDirectory(prefix='horos-auto-query-') as directory:
        path = Path(directory)
        (path / 'Harness.swift').write_text(harness)
        (path / 'main.swift').write_text(DRIVER)
        built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-swift-version', '6',
                                str(path / 'Harness.swift'), str(path / 'main.swift'), '-o', str(path / 'test')],
                               capture_output=True, text=True, timeout=300)
        if built.returncode:
            failures.append('the Swift automatic query methods do not compile in the harness:\n' + built.stderr[-4000:])
        else:
            try:
                run = subprocess.run([str(path / 'test')], capture_output=True, text=True, timeout=60)
                if run.returncode:
                    failures.append('the harness says: ' + (run.stdout + run.stderr).strip()[-2000:])
                else:
                    print(run.stdout.strip())
            except subprocess.TimeoutExpired:
                failures.append('the automatic query harness did not finish within 60 s')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: every instance of the automatic query keeps its own interval, filters and results, and every one is saved')
