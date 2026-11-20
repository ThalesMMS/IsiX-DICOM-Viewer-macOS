#!/usr/bin/env python3
"""A save of the index and the main thread do not wait for each other during an import.

Two reports of the same day showed an import that stopped for good, the
application at 0% CPU. Two threads waited for each other:

- the import, on the queue of its own context, inside -[DicomDatabase save:].
  After every save the version of the model was written to the preferences,
  the same value each time. A write tells the observers of the preferences
  before it returns, and for those that answer on the main operation queue the
  notification centre keeps the writer until the main thread has run them;
- the main thread, answering the notice of the images the import had added.
  The indexer posts that notice on the main thread with the managed objects of
  the import's context in it, and the main database entered that context's
  queue to read their IDs: the queue the import held.

Either half alone is a stall; together they never end. Both are gone:

- the preference is written only when it names another model, and never from a
  context's queue off the main thread: the write is left to the main queue;
- the main thread is handed the notice with IDs in place of the objects, read
  from the import's queue when whoever holds it lets go, and waits for nothing.

This compiles the real N2ManagedDatabase (tests/n2_database_harness.py) with
the real -save:, DatabaseVersionRecord, -observeIndependentDatabaseNotification:
and IndependentDatabaseNotice, a stand-in for the rest of DicomDatabase, and
preferences that are a UserDefaults of the test's own, so that a write posts as
the application's does. One observer of the preferences answers on the main
queue, as a plugin's may: the application's own no longer do
(Modules/IsiXPreferences, PreferenceChangeNotice). Each scenario is a run of
the driver, which a watchdog ends when the threads stop:

- same-value: a thread saves on the import's queue while the main thread waits
  for that queue, the preference already naming the current model;
- other-value: the same with a preference that names a former model, which
  the main queue then records;
- notice-on-main: the notice of added images is posted on the main thread
  while a thread holds the import's queue, as an import indexing its next
  batch does. The main thread goes on at once, and the main database's own
  notice comes with the objects of its context once the queue is free;
- notice-off-main: the notice posted by the thread that holds the queue and
  then waits for the main thread, as a disc scan does.

`<git revision>` as an optional argument reads the sources of that revision,
the negative control: before the change the first two scenarios hang and in
the third the main thread waits until the queue is let go.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs
import n2_database_harness as harness  # noqa: E402

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []
INSTANCE = 'Horos/Sources/DicomDatabase+Instance.swift'
NOTICE = 'Horos/Sources/IndependentDatabaseNotice.swift'


def read(path, optional=False):
    if revision:
        shown = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], capture_output=True)
        if shown.returncode != 0:
            if optional:
                return ''
            raise SystemExit('FAIL: %s is not in %s' % (path, revision))
        return shown.stdout.decode('utf-8')
    return (root / path).read_text()


def between(source, start, end):
    at, to = source.find(start), source.find(end)
    if at < 0 or to < at:
        raise SystemExit('FAIL: %s is not where this test reads it' % start.strip())
    return source[at:to]


def database_slices():
    """-save: and the answer to an independent database's notice, as they are."""
    instance = read(INSTANCE)
    save = re.search(r'    @objc\(save:\)\n.*?^    }\n', instance, re.S | re.M)
    if not save:
        raise SystemExit('FAIL: -save: is not where this test reads it')
    notice = between(instance, '    @objc(observeIndependentDatabaseNotification:)', '    @objc(isLocal)')
    return save.group(0) + notice


def version_record():
    found = re.search(r'^enum DatabaseVersionRecord \{\n.*?^}\n', read(INSTANCE), re.S | re.M)
    if not found:
        raise SystemExit('FAIL: DatabaseVersionRecord is not where this test reads it')
    return '\n' + found.group(0)


DOUBLES = r"""
import AppKit
import CoreData
import Foundation
import IsiXDatabase
import IsiXPreferences

/// Preferences of the test's own that post their changes as the application's do.
let suiteName = CommandLine.arguments[3]
nonisolated(unsafe) let harnessDefaults = UserDefaults(suiteName: suiteName)!

struct PreferencesSource {
    static let process = PreferencesSource()
    var preferences: UserDefaults { harnessDefaults }
}

enum DicomDatabaseObjC {
    static func log(_ exception: NSException, stack: Bool, _ function: String) { emit("exception", "\(function): \(exception)") }
    static func logStackTrace(_ message: String) {}
    static func setObject(_ dictionary: NSMutableDictionary, _ object: Any?, _ key: Any) {
        if let object { dictionary.setObject(object, forKey: (key as AnyObject) as! NSCopying) }
    }
    static func objectForKey(_ object: Any?, _ key: String) -> Any? {
        return (object as? NSDictionary)?.object(forKey: key)
    }
}

let CurrentDatabaseVersion = "2.6"
let OsirixAddToDBNotificationImagesArray = "OsiriXAddToDBArray"
let OsirixAddToDBNotificationImagesPerAETDictionary = "PerAETDictionary"

class DicomDatabase: N2ManagedDatabase {
    override var managedObjectModel: NSManagedObjectModel! { sharedModel }
    override func saveModel() -> Bool { false }
    func modelVersionFilePath() -> String! {
        return ((sqlFilePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("DB_VERSION")
    }

SLICES}
"""

DRIVER = r"""
import IsiXPreferences

let scenario = CommandLine.arguments[1]
let folder = CommandLine.arguments[2]
let key = DatabasePreferences.databaseVersion.name
let added = Notification.Name("OsirixAddToDBNotification")

/// Ends the run when the threads stop: what the scenario is about.
func watchdog(_ seconds: Double) {
    Thread.detachNewThread {
        Thread.sleep(forTimeInterval: seconds)
        // Nothing of the preferences from here: a write would wait for the
        // main thread too.
        emit("\(scenario).ended", "hung")
        exit(4)
    }
}

/// The main run loop, which serves the main queue and what was sent to the
/// main thread, until `done` or `seconds`.
func turn(_ seconds: Double, until done: () -> Bool = { false }) {
    let limit = Date(timeIntervalSinceNow: seconds)
    while !done(), Date() < limit {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
}

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

let main = DicomDatabase(path: (folder as NSString).appendingPathComponent("Database.sql"))!
let worker = main.privateQueueIndependentDatabase() as! DicomDatabase
nonisolated(unsafe) let workerContext = worker.managedObjectContext!
// As DicomDatabase's init does for an independent database.
for name in [added, Notification.Name("OsirixAddToDBCompleteNotification")] {
    NotificationCenter.default.addObserver(main, selector: #selector(DicomDatabase.observeIndependentDatabaseNotification(_:)), name: name, object: worker)
}

/// A study of three images in the import's context, saved; the images, as the
/// indexer hands them over.
nonisolated(unsafe) var images: [NSManagedObject] = []
harnessDefaults.set(CurrentDatabaseVersion, forKey: key)
N2ManagedObjectContextPerformAndWait(workerContext) {
    let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: workerContext)
    study.setValue("1.2.826.0.1", forKey: "studyInstanceUID")
    let series = NSEntityDescription.insertNewObject(forEntityName: "Series", into: workerContext)
    series.setValue(study, forKey: "study")
    for index in 0..<3 {
        let image = NSEntityDescription.insertNewObject(forEntityName: "Image", into: workerContext)
        image.setValue("1.2.826.0.1.\(index)", forKey: "sopInstanceUID")
        image.setValue(series, forKey: "series")
        images.append(image)
    }
    emit("setup.saved", worker.save(nil) ? "yes" : "no")
}
turn(0.2)

/// An observer of the preferences that answers on the main queue.
let told = Box(0)
let observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: harnessDefaults, queue: .main) { _ in
    told.value += 1
}

/// A thread saves on the import's queue while the main thread waits for it.
func saveWhileTheMainThreadWaits() {
    let held = DispatchSemaphore(value: 0)
    let saved = Box(false)
    Thread.detachNewThread {
        N2ManagedObjectContextPerformAndWait(workerContext) {
            held.signal()
            // Until the main thread waits for this queue.
            Thread.sleep(forTimeInterval: 0.4)
            let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: workerContext)
            study.setValue("1.2.826.0.2", forKey: "studyInstanceUID")
            saved.value = worker.save(nil)
        }
    }
    held.wait()
    N2ManagedObjectContextPerformAndWait(workerContext) {}
    emit("\(scenario).ended", saved.value ? "saved" : "not saved")
}

/// What the main database posts in its turn: how many images, of whose context.
final class Received: @unchecked Sendable {
    var count = -1
    var perAET = -1
    var context = "none"
}
let received = Received()
let reposted = NotificationCenter.default.addObserver(forName: added, object: main, queue: nil) { notification in
    let objects = notification.userInfo?[OsirixAddToDBNotificationImagesArray] as? [Any] ?? []
    received.count = objects.count
    received.perAET = ((notification.userInfo?[OsirixAddToDBNotificationImagesPerAETDictionary] as? [String: Any])?["AET"] as? [Any])?.count ?? -1
    let own = objects.allSatisfy { ($0 as? NSManagedObject)?.managedObjectContext === main.managedObjectContext }
    received.context = !Thread.isMainThread ? "off the main thread" : own ? "the main database's" : "another"
}
func reportReceived() {
    emit("\(scenario).images", "\(received.count)")
    emit("\(scenario).per-aet", "\(received.perAET)")
    emit("\(scenario).context", received.context)
}
nonisolated(unsafe) let notice: [AnyHashable: Any] = [OsirixAddToDBNotificationImagesArray: images as NSArray,
                                                      OsirixAddToDBNotificationImagesPerAETDictionary: ["AET": images as NSArray] as NSDictionary]

watchdog(20)
switch scenario {
case "same-value":
    saveWhileTheMainThreadWaits()
    turn(0.3)
    emit("same-value.told", "\(told.value)")
    emit("same-value.preference", harnessDefaults.string(forKey: key) ?? "none")

case "other-value":
    harnessDefaults.set("2.4", forKey: key)
    turn(0.2)
    told.value = 0
    saveWhileTheMainThreadWaits()
    emit("other-value.preference-before-the-main-queue", harnessDefaults.string(forKey: key) ?? "none")
    turn(2) { harnessDefaults.string(forKey: key) == CurrentDatabaseVersion }
    turn(0.2)
    emit("other-value.preference", harnessDefaults.string(forKey: key) ?? "none")
    emit("other-value.told", "\(told.value)")

case "notice-on-main":
    let held = DispatchSemaphore(value: 0), free = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        N2ManagedObjectContextPerformAndWait(workerContext) {
            held.signal()
            // An import indexing its next batch; three seconds when nobody says so.
            _ = free.wait(timeout: .now() + 3)
        }
    }
    held.wait()
    let start = Date()
    NotificationCenter.default.post(name: added, object: worker, userInfo: notice)
    let waited = Date().timeIntervalSince(start)
    emit("notice-on-main.main-thread", waited < 1 ? "went on" : "waited for the import's queue")
    turn(0.3)
    emit("notice-on-main.before-the-queue-is-free", "\(received.count)")
    free.signal()
    turn(3) { received.count >= 0 }
    reportReceived()

case "notice-off-main":
    let arrived = DispatchSemaphore(value: 0)
    let inTime = Box(false)
    let ended = Box(false)
    Thread.detachNewThread {
        N2ManagedObjectContextPerformAndWait(workerContext) {
            NotificationCenter.default.post(name: added, object: worker, userInfo: notice)
            // A disc scan asking what to do with the disc: it waits for the main thread.
            inTime.value = arrived.wait(timeout: .now() + 3) == .success
        }
        ended.value = true
    }
    turn(5) { received.count >= 0 }
    arrived.signal()
    turn(5) { ended.value }
    emit("notice-off-main.main-thread", inTime.value ? "answered while the queue was held" : "waited for the poster's queue")
    reportReceived()

default:
    emit("scenario", "unknown")
}
NotificationCenter.default.removeObserver(observer)
NotificationCenter.default.removeObserver(reposted)
harnessDefaults.removePersistentDomain(forName: suiteName)
emit("\(scenario).end", "reached")
exit(0)
"""

SCENARIOS = ('same-value', 'other-value', 'notice-on-main', 'notice-off-main')


def run_scenarios(directory):
    work = directory / 'work'
    work.mkdir()
    sources = work / 'sources'
    sources.mkdir()
    (sources / 'doubles.swift').write_text(DOUBLES.replace('SLICES', database_slices()) + version_record())
    swift = [str(sources / 'doubles.swift'), 'Horos/Sources/MainActorCallbacks.swift']
    notice = read(NOTICE, optional=True)
    if notice:
        (sources / 'notice.swift').write_text(notice)
        swift.append(str(sources / 'notice.swift'))
    binary, work, error = harness.build(DRIVER, swift_sources=swift, work=work, swift_flags=['-suppress-warnings'])
    if error:
        failures.append(error)
        return {}
    results = {}
    for scenario in SCENARIOS:
        store = directory / scenario
        store.mkdir()
        # Named by a path, the domain is that file, which goes with the folder
        # (tests/harness_defaults.py): a run the watchdog ended removes nothing itself.
        suite = str(store / 'preferences')
        try:
            status, found, _, stderr = harness.run(binary, [scenario, str(store), suite], timeout=60)
        except subprocess.TimeoutExpired:
            failures.append('%s: the driver did not end' % scenario)
            continue
        results.update(found)
        if status == 4:
            failures.append('%s: the threads waited for each other' % scenario)
        elif status != 0:
            failures.append('%s: the driver failed (%d): %s' % (scenario, status, stderr[-1500:]))
    return results


with tempfile.TemporaryDirectory(prefix='horos-save-main-thread-wait-') as directory:
    results = run_scenarios(Path(directory))

if results:
    expected = {
        # The save ends with the main thread waiting for its queue, and tells nobody.
        'same-value.ended': 'saved', 'same-value.told': '0', 'same-value.preference': '2.6', 'same-value.end': 'reached',
        # A former model: the save ends as well, and the main queue records the current one, once.
        'other-value.ended': 'saved', 'other-value.preference-before-the-main-queue': '2.4',
        'other-value.preference': '2.6', 'other-value.told': '1', 'other-value.end': 'reached',
        # The main thread goes on with the import's queue held, and answers once it is free.
        'notice-on-main.main-thread': 'went on', 'notice-on-main.before-the-queue-is-free': '-1',
        'notice-on-main.images': '3', 'notice-on-main.per-aet': '3', 'notice-on-main.context': "the main database's",
        'notice-on-main.end': 'reached',
        # The poster holds its queue and waits for the main thread, which answers.
        'notice-off-main.main-thread': 'answered while the queue was held',
        'notice-off-main.images': '3', 'notice-off-main.per-aet': '3', 'notice-off-main.context': "the main database's",
        'notice-off-main.end': 'reached',
    }
    for key, want in expected.items():
        if results.get(key) != want:
            failures.append('%s: %r, expected %r' % (key, results.get(key), want))
    if 'exception' in results:
        failures.append('an exception: %s' % results['exception'])

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: a save on the queue of an import ends while the main thread waits for that queue, with the preference of the model '
      'written only when it names another and then from the main queue; the notice of added images posted on the main thread '
      'leaves it free while the import holds its queue, and the main database answers with the objects of its own context')
