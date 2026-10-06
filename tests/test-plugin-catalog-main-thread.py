#!/usr/bin/env python3
"""Run production catalog getters to ensure failed preloads are not retried by UI callbacks."""
from pathlib import Path
import re
import subprocess
import tempfile
from sources import source_text
root=Path(__file__).resolve().parent.parent
# PluginManagerController is Swift: the getters are compiled from its source.
source=source_text('PluginManagerController')
methods=[]
for kind in ['OsiriX','Horos']:
 # nonisolated: the catalog preload thread calls them.
 start=re.search(rf'    @objc\(available{kind}Plugins\)\n    (?:nonisolated )?public (?:nonisolated )?func available{kind}Plugins\(\) -> NSArray! \{{', source).start()
 end=source.index('\n    }\n',start)+7
 methods.append(source[start:end].replace('HorosLoadPluginCatalog(', 'FixtureLoad('))
program=r'''
import Foundation
import Synchronization
let pluginCatalogLock = NSLock()
var CachedOsiriXPluginsList: NSArray? = nil, CachedHorosPluginsList: NSArray? = nil
var CachedOsiriXPluginsListDate: Date? = nil, CachedHorosPluginsListDate: Date? = nil
var calls = 0
var empty = false
let finished = DispatchSemaphore(value: 0)
func check(_ condition: Bool, _ message: String) { if !condition { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) } }
func sortPluginArrayByName(_ a: Any, _ b: Any, _ c: UnsafeMutableRawPointer?) -> Int { return ((a as! NSDictionary)["name"] as! NSString).compare((b as! NSDictionary)["name"] as! String).rawValue }
final class FixtureTransport: NSObject {
 static func arrayWithContentsOfURL(_ url: URL?) -> NSArray? { calls += 1; return empty ? NSArray() : nil }
}
func FixtureLoad(_ url: URL!, _ timeout: TimeInterval, _ error: NSErrorPointer) -> [Any]! { return FixtureTransport.arrayWithContentsOfURL(url) as? [Any] }
final class Controller: NSObject {
 var osirixPluginListURLs: [String] = ["http://127.0.0.1/first", "http://127.0.0.1/second"]
 var horosPluginListURLs: [String] = ["http://127.0.0.1/first", "http://127.0.0.1/second"]
 // As the controller keeps them: under a Mutex, for the preload thread.
 let catalogErrors = Mutex<(osirix: NSError?, horos: NSError?)>((nil, nil))
 @objc func preload() { autoreleasepool { check(!Thread.isMainThread, "Expected worker"); _ = availableOsiriXPlugins(); _ = availableHorosPlugins(); finished.signal() } }
METHODS
}
check(Thread.isMainThread, "Expected main thread"); let controller = Controller()
Thread.detachNewThreadSelector(#selector(Controller.preload), toTarget: controller, with: nil)
finished.wait()
check(calls == 4, "Worker tries two fallback endpoints per catalog")
for _ in 0..<4 { check(controller.availableOsiriXPlugins() == nil, "Failure remains nil"); check(controller.availableHorosPlugins() == nil, "Failure remains nil") }
check(calls == 4, "UI retried failed network requests")
empty = true
Thread.detachNewThreadSelector(#selector(Controller.preload), toTarget: controller, with: nil)
finished.wait()
check(calls == 6, "Worker loads one valid empty catalog per type")
check(controller.availableOsiriXPlugins() != nil && controller.availableHorosPlugins() != nil, "Valid empty cache is distinct from failure")
check(calls == 6, "UI must use cache")
print("PASS: failed worker preload is never retried on main; valid empty cache remains available without network calls")
'''.replace('METHODS','\n'.join(methods))
with tempfile.TemporaryDirectory(prefix='horos-catalog-thread-') as directory:
 p=Path(directory);(p/'main.swift').write_text(program)
 subprocess.run(['xcrun','swiftc','-swift-version','5','-module-cache-path',str(p/'ModuleCache'),str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True,timeout=10)
