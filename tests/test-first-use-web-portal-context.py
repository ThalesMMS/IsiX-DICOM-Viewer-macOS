#!/usr/bin/env python3
"""First-use modal events must not fetch portal users through a nil context.

Compile the actual AppController accessor with a configurable portal double.
Exercise its context through a real NSArrayController, including missing portal,
database and context, an Objective-C exception, and recovery to a live store.
A minimal User model is archived at runtime so Command Line Tools suffice.
Pass --source <AppController.swift> to check an earlier copy as a negative control.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, default=root / 'Horos/Sources/AppController.swift')
args = parser.parse_args()
source = args.source.read_text()
start = source.index('    @objc nonisolated func defaultWebPortalManagedObjectContext()')
method = source[start:source.index('\n    @objc nonisolated public func defaultWebPortal()', start)]

code = r'''
import Cocoa

final class PortalDatabase: NSObject {
    var managedObjectContext: NSManagedObjectContext?
}
final class WebPortal: NSObject {
    static var instance: WebPortal?
    static var raises = false
    var database: PortalDatabase?
    static func `default`() -> WebPortal? {
        if raises {
            NSException(name: .internalInconsistencyException, reason: "Portal unavailable").raise()
        }
        return instance
    }
}
enum ObjC {
    static func exception(_ error: Error) -> NSException? {
        (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    static func arg(_ exception: NSException?) -> CVarArg {
        exception?.reason ?? "unknown exception"
    }
}
final class AppController: NSObject {
    enum State {
        static let fakeContextLock = NSLock()
        static var fakeContext: NSManagedObjectContext?
    }
METHOD
}

func require(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
}

// Supply the resource the real accessor loads, without depending on an
// installed IsiX, momc, user preferences, or a patient database.
let model = NSManagedObjectModel()
let user = NSEntityDescription()
user.name = "User"
user.managedObjectClassName = "NSManagedObject"
let name = NSAttributeDescription()
name.name = "name"
name.attributeType = .stringAttributeType
name.isOptional = true
user.properties = [name]
model.entities = [user]
let directory = URL(fileURLWithPath: Bundle.main.resourcePath!).appendingPathComponent("WebPortalDB.momd")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
try NSKeyedArchiver.archivedData(withRootObject: model, requiringSecureCoding: false)
    .write(to: directory.appendingPathComponent("WebPortalDB.mom"))
let versions: [String: Any] = [
    "NSManagedObjectModel_CurrentVersionName": "WebPortalDB",
    "NSManagedObjectModel_VersionHashes": ["WebPortalDB": model.entityVersionHashesByName]
]
try PropertyListSerialization.data(fromPropertyList: versions, format: .xml, options: 0)
    .write(to: directory.appendingPathComponent("VersionInfo.plist"))

_ = NSApplication.shared
let app = AppController()

func fetchUsers(_ context: NSManagedObjectContext?, expected: Int, scenario: String) {
    let controller = NSArrayController()
    controller.entityName = "User"
    controller.managedObjectContext = context
    do {
        try HorosObjCException.perform {
            // This is the same AppKit path that failed inside runModal().
            let request = controller.defaultFetchRequest()
            require(request.entity?.name == "User", "\(scenario): User entity missing")
            do {
                _ = try controller.fetch(with: request, merge: false)
            } catch {
                require(false, "\(scenario): fetch failed: \(error)")
            }
        }
    } catch {
        print("FAIL: \(scenario): \(ObjC.exception(error)?.reason ?? error.localizedDescription)")
        exit(1)
    }
    require(context != nil, "\(scenario): nil context")
    require((controller.arrangedObjects as? NSArray)?.count == expected,
            "\(scenario): unexpected users")
}

let fallback = app.defaultWebPortalManagedObjectContext()
fetchUsers(fallback, expected: 0, scenario: "portal not initialized")
require(fallback?.concurrencyType == .mainQueueConcurrencyType, "fallback must belong to the UI queue")
require(fallback?.persistentStoreCoordinator?.persistentStores.isEmpty == true,
        "fallback must not open a store")

WebPortal.instance = WebPortal()
fetchUsers(app.defaultWebPortalManagedObjectContext(), expected: 0, scenario: "database unavailable")
WebPortal.instance?.database = PortalDatabase()
fetchUsers(app.defaultWebPortalManagedObjectContext(), expected: 0, scenario: "context unavailable")
require(app.defaultWebPortalManagedObjectContext() === fallback, "fallback must be reused")

WebPortal.raises = true
fetchUsers(app.defaultWebPortalManagedObjectContext(), expected: 0, scenario: "portal raises an exception")
require(app.defaultWebPortalManagedObjectContext() === fallback, "exception must reuse fallback")
WebPortal.raises = false

let live = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
live.persistentStoreCoordinator = coordinator
NSEntityDescription.insertNewObject(forEntityName: "User", into: live).setValue("fixture", forKey: "name")
try live.save()
WebPortal.instance?.database?.managedObjectContext = live
require(app.defaultWebPortalManagedObjectContext() === live, "ready portal must provide its real context")
fetchUsers(app.defaultWebPortalManagedObjectContext(), expected: 1, scenario: "live portal after setup")

print("PASS: first-use bindings can fetch with missing portal/database/context or exceptions; live context remains usable")
'''.replace('METHOD', method)

with tempfile.TemporaryDirectory(prefix='isix-first-use-context-') as folder:
    path = Path(folder)
    (path / 'bridge.h').write_text('#import "HorosObjCException.h"\n')
    subprocess.run([
        'xcrun', 'clang', '-c', '-fno-objc-arc', '-I', str(root / 'Horos/Sources'),
        str(root / 'Horos/Sources/HorosObjCException.m'), '-o', str(path / 'exception.o'),
    ], check=True, timeout=120)
    (path / 'main.swift').write_text(code)
    subprocess.run([
        'xcrun', 'swiftc', '-swift-version', '5', '-import-objc-header', str(path / 'bridge.h'),
        '-Xcc', '-I' + str(root / 'Horos/Sources'), str(path / 'main.swift'),
        str(path / 'exception.o'), '-o', str(path / 'test'),
    ], check=True, timeout=300)
    subprocess.run([str(path / 'test')], check=True, timeout=60)
