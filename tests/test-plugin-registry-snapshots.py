#!/usr/bin/env python3
"""A plugin collection that has been handed out is never changed again.

PluginManager's accessors hand out the registry's collections themselves,
typed mutable, as the SDK always did, and import, network and web portal
threads enumerate them without a lock. Loading a plugin after launch changed
those same collections on the main thread. Now a change is made on a copy that
replaces the published one under a lock.

The Registry is compiled out of the production source and driven: a reader's
collection is unchanged by a later change, the change is published, a nil body
keeps nil, and readers enumerating on other threads while the main thread
changes the registry thousands of times neither crash nor see a collection
mutated under them. The loader's writes are checked to go through it.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/PluginManager.swift').read_text()
failures = []

start = source.find('fileprivate enum Registry {')
end = source.find('\n}\n', start)
if start < 0 or end < 0:
    print('FAIL: PluginManager.swift no longer has its Registry')
    sys.exit(1)
registry = source[start:end + 3].replace('fileprivate enum Registry', 'enum Registry')

# Every write to a published collection goes through a copy.
for pattern, what in ((r'ObjC\.(set|add)\(Registry\.', 'an ObjC.set/add on a published collection'),
                      (r'Registry\.(plugins|pluginsDict|fileFormatPlugins|reportPlugins|pluginsBundleDictionnary|'
                       r'preProcessPlugins|fusionPlugins|pluginsNames)[?!]?\.(set|add|remove|insert|replace)',
                       'a published collection changed in place'),
                      (r'Registry\.[A-Za-z]+ = ', 'a registry variable assigned without the lock')):
    for match in re.finditer(pattern, source):
        line = source.count('\n', 0, match.start()) + 1
        failures.append('%s at PluginManager.swift:%d' % (what, line))
if re.search(r'^\s*static var \w+: NSMutable\S* = ', registry, re.M):
    failures.append('the registry still has unguarded static collections')

DRIVER = r'''
import Foundation
import AppKit

func check(_ condition: Bool, _ message: String) { if !condition { print("FAIL: " + message) } }

Registry.set(\.plugins, NSMutableDictionary())
Registry.set(\.preProcessPlugins, NSMutableArray())
let held = Registry.plugins!
let heldArray = Registry.preProcessPlugins!
Registry.change(\.plugins) { $0?.setObject("filter", forKey: "Menu Title" as NSString) }
Registry.change(\.preProcessPlugins) { $0?.add("pre") }
check(held.count == 0, "a reader's dictionary was changed under it")
check(heldArray.count == 0, "a reader's array was changed under it")
check(Registry.plugins?.object(forKey: "Menu Title") as? String == "filter", "the change was not published")
check(Registry.preProcessPlugins?.count == 1, "the array change was not published")
check(held !== Registry.plugins!, "the published dictionary is still the one handed out")
Registry.change(\.fileFormatPlugins) { $0?.setObject("x", forKey: "y" as NSString) }
check(Registry.fileFormatPlugins == nil, "a change before launch made a collection out of nothing")

// Readers on other threads enumerate while the main thread keeps changing.
let group = DispatchGroup()
let stop = NSLock(); var done = false
var enumerated = 0
for _ in 0..<4 {
    group.enter()
    Thread.detachNewThread {
        var local = 0
        while true {
            stop.lock(); let finished = done; stop.unlock()
            if finished { break }
            if let plugins = Registry.plugins {
                for (_, value) in plugins { _ = value; local += 1 }
            }
            if let array = Registry.preProcessPlugins {
                for value in array { _ = value; local += 1 }
            }
        }
        stop.lock(); enumerated += local; stop.unlock()
        group.leave()
    }
}
for i in 0..<5000 {
    Registry.change(\.plugins) { $0?.setObject(i, forKey: "k\(i % 64)" as NSString) }
    Registry.change(\.preProcessPlugins) { (array: NSMutableArray?) in
        array?.add(i)
        if (array?.count ?? 0) > 64 { array?.removeObject(at: 0) }
    }
}
stop.lock(); done = true; stop.unlock()
group.wait()
check(enumerated > 0, "the readers never saw a collection")
print("done \(enumerated)")
'''

with tempfile.TemporaryDirectory(prefix='horos-plugin-registry-') as directory:
    folder = Path(directory)
    (folder / 'Registry.swift').write_text('import Foundation\nimport AppKit\n\n' + registry)
    (folder / 'main.swift').write_text(DRIVER)
    built = subprocess.run(['xcrun', 'swiftc', '-O', str(folder / 'Registry.swift'), str(folder / 'main.swift'),
                            '-o', str(folder / 'driver')], capture_output=True, text=True)
    if built.returncode != 0:
        failures.append('the Registry does not compile on its own:\n%s' % built.stderr[-1500:])
    else:
        run = subprocess.run([str(folder / 'driver')], capture_output=True, text=True, timeout=300)
        if run.returncode != 0:
            failures.append('the driver crashed (%d): %s' % (run.returncode, run.stderr[-600:]))
        failures += [line[6:] for line in run.stdout.splitlines() if line.startswith('FAIL: ')]
        if 'done' not in run.stdout:
            failures.append('the driver did not finish: %r' % run.stdout[-300:])

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: plugin collections are published as snapshots; readers on other threads never see one change')
