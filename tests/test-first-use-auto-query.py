#!/usr/bin/env python3
"""Saved auto-query must wait until the first-use DICOM database is open.

Compile the production Swift browser startup/completion methods and query-log
controller. Exercise deferred AppKit fetches with an in-memory LogEntry store,
without network access, user preferences or a patient database.
Optional source paths let the original implementations serve as negative controls.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

import isix_modules

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--browser-source', type=Path, default=root / 'Horos/Sources/BrowserController+Window.swift')
parser.add_argument('--log-source', type=Path, default=root / 'Horos/Sources/QueryLogController.swift')
parser.add_argument('--restoration-source', type=Path, default=root / 'Horos/Sources/AutoQueryRestoration.swift')
args = parser.parse_args()
source = args.browser_source.read_text()


def method(signature):
    start = source.index(signature)
    return source[start:source.index('\n    }\n', start) + 6]


wire = source.index('    private func wireWindow()')
start = source.index('        refreshMatrix(self)', wire)
start = source.index('\n', start) + 1
startup = source[start:source.index('        window?.animationBehavior', start)]
completion = method('    func completeFirstUseDatabaseSetup()')
signature = '    private func restoreAutoQueryAndRetrieve()'
restore = method(signature) if signature in source else ''
# Compiled beside the mocks, in their module, with their database and preferences.
restoration = (args.restoration_source.read_text()
               .replace('DicomDatabase?', 'TestDatabase?').replace('defaults: UserDefaults', 'defaults: TestDefaults'))

mocks = r'''
import Cocoa
import IsiXPreferences

@MainActor
final class TestDatabase: NSObject {
    let managedObjectContext: NSManagedObjectContext
    init(context: NSManagedObjectContext) { managedObjectContext = context }
}
/// The preferences, as a store of the catalog's keys reads them; used on the main thread only.
final class TestDefaults: PreferenceStore, @unchecked Sendable {
    static let standard = TestDefaults()
    var values: [String: Any] = [:]
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func isGivenAsLaunchArgument(_ key: String) -> Bool { false }
}
@MainActor
enum DatabaseFirstUse { static var hasPendingChoice = true }
@MainActor
final class AppController {
    static func shared() -> AppController? { nil }
    func notificationTitle(_ title: String, description: String, name: String) {}
}
@MainActor
final class WaitRendering {
    init?(_ title: String) {}
    func showWindow(_ sender: Any) {}
    func close() {}
}
@MainActor
final class QueryController {
    static var current: QueryController?
    static var creations = 0
    let logs: QueryLogController
    static func currentAuto() -> QueryController? { current }
    init?(autoQuery: Bool) {
        logs = QueryLogController()
        QueryController.current = self
        QueryController.creations += 1
        logs.entityName = "LogEntry"
        logs.automaticallyPreparesContent = true
        logs.awakeFromNib()
    }
    func switchAutoRetrieving(_ sender: Any) {}
}
@MainActor
enum ICloudDriveDetector { static func performStartupICloudDriveTasks(_ browser: Any) {} }
@MainActor
enum O2HMigrationAssistant { static func performStartupO2HTasks(_ browser: Any) {} }
@MainActor
final class BrowserController: NSObject {
    static var current: BrowserController?
    @objc var database: TestDatabase?
    var chosenDatabase: TestDatabase?
    static func currentBrowser() -> BrowserController? { current }
    static func setCurrentForTest(_ browser: BrowserController) { current = browser }
    func awakeSources() {}
    func resetToLocalDatabase() { database = chosenDatabase }
    func startWindow() {
STARTUP
    }
RESTORE
COMPLETION
}
// The graph of the database window, through which the query log reads the
// database the browser shows, and the process graph that hands it out.
@MainActor
final class BrowserWindowGraph {
    let browser: BrowserController
    init(browser: BrowserController) { self.browser = browser }
    var database: TestDatabase? { browser.database }
}
final class ProcessGraph: Sendable {
    static let process = ProcessGraph()
    @MainActor var browserWindow: BrowserWindowGraph? { BrowserController.current.map(BrowserWindowGraph.init) }
}
struct PreferencesSource: Sendable {
    let processGraph: ProcessGraph
    static let process = PreferencesSource(processGraph: .process)
}
@MainActor
func ConfigureDefaults(_ restart: Bool, _ saved: Bool, _ retrieving: Bool) {
    TestDefaults.standard.values = ["restartAutoQueryAndRetrieve": restart, "autoRetrieving": retrieving]
    if saved { TestDefaults.standard.values["savedAutoDICOMQuerySettingsArray"] = [[:]] }
}
@MainActor
func RetrievalPreference() -> Bool { TestDefaults.standard.bool(forKey: "autoRetrieving") }
@MainActor
func SetPendingChoice(_ pending: Bool) { DatabaseFirstUse.hasPendingChoice = pending }
@MainActor
func ClearQuery() { QueryController.current = nil }
@MainActor
func QueryCreations() -> Int { QueryController.creations }
@MainActor
func CurrentQueryLog() -> NSArrayController? { QueryController.current?.logs }
'''

scenario = r'''
import Cocoa
func require(_ condition: Bool, _ reason: String) {
    if !condition { print("FAIL: \(reason)"); exit(1) }
}
func drainEvents(_ scenario: String) {
    do {
        try HorosObjCException.perform {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
        }
    } catch {
        let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
        print("FAIL: \(scenario): \(exception?.reason ?? error.localizedDescription)")
        exit(1)
    }
}
_ = NSApplication.shared
let model = NSManagedObjectModel()
let entry = NSEntityDescription()
entry.name = "LogEntry"
entry.managedObjectClassName = "NSManagedObject"
let time = NSAttributeDescription()
time.name = "startTime"
time.attributeType = .dateAttributeType
entry.properties = [time]
model.entities = [entry]
let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
context.persistentStoreCoordinator = coordinator
NSEntityDescription.insertNewObject(forEntityName: "LogEntry", into: context).setValue(Date(), forKey: "startTime")
try context.save()
let database = TestDatabase(context: context)
let browser = BrowserController()
BrowserController.setCurrentForTest(browser)
browser.chosenDatabase = database
ConfigureDefaults(true, true, true)
SetPendingChoice(true)
browser.startWindow()
drainEvents("location choice still pending")
require(QueryCreations() == 0, "auto-query started before choosing a database")
require(RetrievalPreference(), "pending setup changed the retrieval preference")
SetPendingChoice(false)
browser.completeFirstUseDatabaseSetup()
drainEvents("database chosen")
require(QueryCreations() == 1, "saved auto-query did not resume after setup")
require(CurrentQueryLog()?.managedObjectContext === context, "query log uses the wrong context")
require((CurrentQueryLog()?.arrangedObjects as? NSArray)?.count == 1, "query log did not fetch the real store")
browser.completeFirstUseDatabaseSetup()
require(QueryCreations() == 1, "setup resumed auto-query twice")
ClearQuery()
browser.startWindow()
drainEvents("existing installation")
require(QueryCreations() == 2, "ordinary startup no longer restores auto-query")
ClearQuery()
browser.database = nil
browser.startWindow()
drainEvents("database failed to open")
require(QueryCreations() == 2, "auto-query started without a database")
let earlyLog = QueryLogController()
earlyLog.entityName = "LogEntry"
earlyLog.automaticallyPreparesContent = true
earlyLog.awakeFromNib()
drainEvents("log loaded before database")
require(!earlyLog.automaticallyPreparesContent, "early log still schedules a fetch")
browser.database = database
ConfigureDefaults(false, true, true)
browser.startWindow()
require(!RetrievalPreference(), "disabled restore still enables retrieval")
ConfigureDefaults(true, false, true)
browser.startWindow()
require(!RetrievalPreference(), "missing saved settings still enable retrieval")
print("PASS: auto-query waits for first-use completion, resumes once with a usable log, and preserves ordinary startup")
'''

scenario = scenario.replace('_ = NSApplication.shared', 'try MainActor.assumeIsolated {\n_ = NSApplication.shared', 1) + '\n}\n'
code = mocks.replace('STARTUP', startup).replace('RESTORE', restore).replace('COMPLETION', completion)
# Only the preferences dependency is replaced; the methods under test stay intact.
code = code.replace('UserDefaults.standard', 'TestDefaults.standard') + scenario

with tempfile.TemporaryDirectory(prefix='isix-first-use-auto-query-') as directory:
    folder = Path(directory)
    (folder / 'bridge.h').write_text('#import "HorosObjCException.h"\n')
    (folder / 'main.swift').write_text(code)
    (folder / 'AutoQueryRestoration.swift').write_text(restoration)
    subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-I', str(root / 'Horos/Sources'),
                    str(root / 'Horos/Sources/HorosObjCException.m'), '-o', str(folder / 'exception.o')],
                   check=True, timeout=120)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-import-objc-header', str(folder / 'bridge.h'),
                    '-Xcc', '-I' + str(root / 'Horos/Sources'), str(args.log_source),
                    str(root / 'Horos/Sources/MainActorCallbacks.swift'), str(folder / 'AutoQueryRestoration.swift'),
                    str(folder / 'main.swift'), *isix_modules.module_flags('IsiXPreferences', folder / 'modules'),
                    str(folder / 'exception.o'), '-o', str(folder / 'test')], check=True, timeout=300)
    subprocess.run([str(folder / 'test')], check=True, timeout=60)
