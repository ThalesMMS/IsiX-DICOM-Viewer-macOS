#!/usr/bin/env python3
"""A source selection queued before setup must not clear the chosen database.

-completeFirstUseDatabaseSetup is BrowserController+Window.swift; it is
compiled here in a stand-in browser with the same members.
"""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
s = (root / 'Horos/Sources/BrowserController+Window.swift').read_text()
a = s.index('    func completeFirstUseDatabaseSetup()')
method = s[a:s.index('\n    }\n', a) + 6]
code = r'''
import Cocoa
enum ICloudDriveDetector { static func performStartupICloudDriveTasks(_ browser: Any) {} }
enum O2HMigrationAssistant { static func performStartupO2HTasks(_ browser: Any) {} }
typealias BrowserController = Browser
final class Browser: NSObject {
    @objc var database: Any?
    func awakeSources() {}
    func resetToLocalDatabase() { database = "chosen database" }
METHOD
}
let browser = Browser()
browser.perform(#selector(setter: Browser.database), with: nil, afterDelay: 0.01)
browser.completeFirstUseDatabaseSetup()
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
guard (browser.database as? String) == "chosen database" else { print("Queued nil selection cleared the chosen database"); exit(1) }
print("PASS: setup cancels stale queued nil source selection")
'''.replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='horos-first-use-selection-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-o', str(p / 'test'), str(p / 'main.swift')], check=True, timeout=300)
    subprocess.run([str(p / 'test')], check=True, timeout=60)
