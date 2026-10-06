#!/usr/bin/env python3
"""Execute the viewer's real per-export directory creation block twice.

-endExportImage: is Swift (ViewerController+Export.swift): the block
is copied out of that method and compiled with xcrun swiftc against a stand-in
browser database and alert panel, as it was with clang.
"""
import private_tmpdir  # noqa: F401  (swiftc leaves folders in TMPDIR)
from pathlib import Path
import subprocess,tempfile
import sources
s=sources.source_text('ViewerController+Export')
m=s.index('@objc(endExportImage:)');e=s.index('@objc(',m+len('@objc(endExportImage:)'))
a=s.index('                let sharedExportRoot = ',m);b=s.index('                let mailExportFiles = NSMutableArray()',a)
assert b<e,'the directory block is no longer in -endExportImage:'
code=r'''
import Foundation
var testRoot = ""
let created = NSMutableArray()
final class BrowserController: NSObject {
    static func currentBrowser() -> BrowserController? { return BrowserController() }
    var database: BrowserController? { return self }
    func tempDirPath() -> String! { return testRoot }
}
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
