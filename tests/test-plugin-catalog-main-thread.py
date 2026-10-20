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
# nonisolated: the catalog preload thread calls it.
start=re.search(r'    @objc\(availableHorosPlugins\)\n    (?:nonisolated )?public (?:nonisolated )?func availableHorosPlugins\(\) -> NSArray! \{', source).start()
end=source.index('\n    }\n',start)+7
methods.append(source[start:end].replace('HorosLoadPluginCatalog(', 'FixtureLoad('))
# The OsiriX catalog is no longer browsed: the window loads only the Horos one.
assert 'availableOsiriXPlugins' not in source and 'OSIRIX_PLUGIN_LIST' not in source
program=r'''
import Foundation
import Synchronization
let pluginCatalogLock = NSLock()
var CachedHorosPluginsList: NSArray? = nil
var CachedHorosPluginsListDate: Date? = nil
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
 var horosPluginListURLs: [String] = ["http://127.0.0.1/first", "http://127.0.0.1/second"]
 // As the controller keeps them: under a Mutex, for the preload thread.
 let catalogError = Mutex<NSError?>(nil)
 @objc func preload() { autoreleasepool { check(!Thread.isMainThread, "Expected worker"); _ = availableHorosPlugins(); finished.signal() } }
METHODS
}
check(Thread.isMainThread, "Expected main thread"); let controller = Controller()
Thread.detachNewThreadSelector(#selector(Controller.preload), toTarget: controller, with: nil)
finished.wait()
check(calls == 2, "Worker tries two fallback endpoints")
for _ in 0..<4 { check(controller.availableHorosPlugins() == nil, "Failure remains nil") }
check(calls == 2, "UI retried failed network requests")
empty = true
Thread.detachNewThreadSelector(#selector(Controller.preload), toTarget: controller, with: nil)
finished.wait()
check(calls == 3, "Worker loads one valid empty catalog")
check(controller.availableHorosPlugins() != nil, "Valid empty cache is distinct from failure")
check(calls == 3, "UI must use cache")
print("PASS: failed worker preload is never retried on main; valid empty cache remains available without network calls")
'''.replace('METHODS','\n'.join(methods))
with tempfile.TemporaryDirectory(prefix='horos-catalog-thread-') as directory:
 p=Path(directory);(p/'main.swift').write_text(program)
 subprocess.run(['xcrun','swiftc','-swift-version','5','-module-cache-path',str(p/'ModuleCache'),str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True,timeout=10)
