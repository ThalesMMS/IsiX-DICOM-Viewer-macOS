#!/usr/bin/env python3
"""Execute the viewer's real per-export directory creation block twice.

The image export of the 2D viewer is ViewerImageExporter.swift: the block is
copied out of its endImageSheet and compiled with xcrun swiftc against a
stand-in process graph, browser database and alert panel, as it was with clang.
"""
import private_tmpdir  # noqa: F401  (swiftc leaves folders in TMPDIR)
from pathlib import Path
import subprocess,tempfile
import sources
s=sources.source_text('ViewerImageExporter')
m=s.index('    func endImageSheet(');e=s.index('\n    }\n',m)
a=s.index('        let sharedExportRoot = ',m);b=s.index('        var mailExportFiles: [String] = []',a)
assert b<e,'the directory block is no longer in endImageSheet'
code=r'''
import Foundation
var testRoot = ""
let created = NSMutableArray()
final class BrowserController: NSObject {
    var database: BrowserController? { return self }
    func tempDirPath() -> String! { return testRoot }
}
final class ProcessGraph {
    var currentBrowser: BrowserController? { return BrowserController() }
}
let processGraph = ProcessGraph()
enum HorosAlertPanel {
    @discardableResult static func run(title: String, message: String, defaultButton: String, alternateButton: String?, otherButton: String?) -> Int { return 1 }
}
func prepare() {
BODY
    created.add(sharedExportRoot)
}
testRoot = CommandLine.arguments[1]
prepare()
let first = ((created[0] as! NSString).appendingPathComponent("0001.jpg"))
try? "first draft bytes".write(toFile: first, atomically: true, encoding: .utf8)
prepare()
if created.count != 2 || (created[0] as! NSString).isEqual(created[1]) { exit(1) }
if (try? String(contentsOfFile: first, encoding: .utf8)) != "first draft bytes" { exit(2) }
for case let path as String in created {
    let mode = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber
    if mode?.intValue != 0o700 { exit(3) }
}
print("PASS: independent private export directories preserve earlier draft bytes")
'''.replace('BODY',s[a:b])
with tempfile.TemporaryDirectory(prefix='horos-export-directory-') as d:
 p=Path(d);(p/'main.swift').write_text(code)
 subprocess.run(['xcrun','swiftc','-sanitize=address',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),d],check=True)
